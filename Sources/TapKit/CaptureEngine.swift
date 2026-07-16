import AudioToolbox
import CoreAudio
import Foundation

public enum EngineStatus: Sendable {
    case idle
    case recording
    case error(String)
}

/// Top-level orchestrator (Section 4.2). Accepts a `SessionSpec`, creates and
/// owns the single `CaptureLane`, and runs the session lifecycle. Owns the
/// **engine queue** — every Core Audio hardware call in the process is
/// serialized on it (Section 4.4).
public final class CaptureEngine {
    private let engineQueue = DispatchQueue(label: "com.systemaudiorecorder.engine", qos: .userInitiated)

    /// Guards every member that is read from off the engine queue (the GUI
    /// main thread's 20 Hz meter poll, the CLI's wait loop): `lane`,
    /// `status`, `lastStopOutcome`, `sessionStore`. All writes happen on the
    /// engine queue; the lock makes the cross-thread reads defined behavior.
    private let stateLock = NSLock()
    private var _sessionStore: SessionStore
    private var _lane: CaptureLane?
    private var _status: EngineStatus = .idle
    private var _lastStopOutcome: StopOutcome?

    private var laneDelegate: LaneDelegate?
    private var currentSpec: SessionSpec?
    private var currentNamingTemplate: String?
    /// Engine-queue only. Coalesces overlapping stop() calls (e.g. a
    /// user-initiated stop racing an engine-initiated finalize) onto the one
    /// in-flight stop — a second export pass over the same lane would find
    /// the segment files already moved and clobber a successful outcome
    /// with a spurious exportFailed error.
    private var stopInProgress = false
    private var queuedStopCompletions: [(StopOutcome) -> Void] = []

    public var onStatusChanged: ((EngineStatus) -> Void)?

    /// What a stop produced: the exported file URLs (one per format run —
    /// more than one only if the sample rate changed mid-session), plus the
    /// failure, if any. Also retained as `lastStopOutcome` so a session the
    /// engine finalized on its own (device-wait timeout, permanent lane
    /// failure) is observable by the CLI/GUI after the fact.
    public struct StopOutcome: Sendable {
        public let fileURLs: [URL]
        public let failure: StopFailure?

        public init(fileURLs: [URL], failure: StopFailure?) {
            self.fileURLs = fileURLs
            self.failure = failure
        }
    }

    public enum StopFailure: Sendable {
        case nothingCaptured
        case exportFailed(String)

        public var message: String {
            switch self {
            case .nothingCaptured: return "No audio was captured to save"
            case .exportFailed(let detail): return "Failed to export recording: \(detail)"
            }
        }
    }

    public init(recordingsRoot: URL) {
        self._sessionStore = SessionStore(recordingsRoot: recordingsRoot)
    }

    // MARK: Thread-safe accessors

    public var sessionStore: SessionStore {
        stateLock.lock(); defer { stateLock.unlock() }
        return _sessionStore
    }

    public var status: EngineStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    public var lastStopOutcome: StopOutcome? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastStopOutcome
    }

    private var currentLane: CaptureLane? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lane
    }

    private func setLane(_ lane: CaptureLane?) {
        stateLock.lock(); _lane = lane; stateLock.unlock()
    }

    private func setStatus(_ status: EngineStatus) {
        stateLock.lock(); _status = status; stateLock.unlock()
        onStatusChanged?(status)
    }

    private func setLastStopOutcome(_ outcome: StopOutcome) {
        stateLock.lock(); _lastStopOutcome = outcome; stateLock.unlock()
    }

    /// Points future recordings at a different folder. No-op while a
    /// recording is in progress (the active session keeps its folder).
    public func updateRecordingsRoot(_ url: URL) {
        engineQueue.async { [weak self] in
            guard let self, self.currentLane == nil else { return }
            self.stateLock.lock()
            let changed = self._sessionStore.recordingsRoot.standardizedFileURL != url.standardizedFileURL
            if changed { self._sessionStore = SessionStore(recordingsRoot: url) }
            self.stateLock.unlock()
            if changed { Log.info("recordings folder changed to \(url.path)") }
        }
    }

    /// Live per-channel meters for the active lane; empty when idle. Safe
    /// from any thread (Section 5.4 step 8's 20 Hz UI poll).
    public func meterSnapshots() -> [MeterSnapshot] {
        currentLane.map { [$0.currentMeterSnapshot()] } ?? []
    }

    /// Read-only per-lane watchdog states, index-aligned with `meterSnapshots()`.
    public func watchdogStates() -> [WatchdogState] {
        currentLane.map { [$0.watchdogState] } ?? []
    }

    /// Runs the TCC capture-permission probe (Section 9.4) serialized on the
    /// same engine queue as every other Core Audio hardware call (Section 4.4).
    public func requestCapturePermission(completion: @escaping (PermissionOutcome) -> Void) {
        engineQueue.async {
            let outcome = PermissionBroker.requestCapturePermission()
            completion(outcome)
        }
    }

    /// Runs `CalibrationService.recommendBufferFrameSize` on this engine's
    /// own `engineQueue` (Section 4.4) rather than a caller-owned queue —
    /// the temporary tap/aggregate/IOProc lifecycle calls it makes are
    /// exactly the class of Core Audio HAL call that must never interleave
    /// with a real session's `start`/`stop` on a second, independent queue.
    public func recommendBufferFrameSize(completion: @escaping (Result<BufferCalibrationResult, Error>) -> Void) {
        CalibrationService.recommendBufferFrameSize(engineQueue: engineQueue, completion: completion)
    }

    // MARK: Start

    /// Starts a session. I/O buffer size is resolved by the lane itself, per
    /// device, from `CalibrationService`'s shared per-device store (Section
    /// 8.3; 512 if never calibrated) — the same shared store both the GUI
    /// and the CLI write to and read from, re-resolved on every rebuild in
    /// case a device switch changes which store entry applies (Section 7.3).
    public func start(
        spec: SessionSpec,
        namingTemplate: String = "{date} {time} — {source}",
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.startOnEngineQueue(spec: spec, namingTemplate: namingTemplate, completion: completion)
        }
    }

    private func startOnEngineQueue(spec: SessionSpec, namingTemplate: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard currentLane == nil else {
            completion(.failure(CaptureEngineError.alreadyRecording))
            return
        }

        currentSpec = spec
        currentNamingTemplate = namingTemplate

        let lane = CaptureLane(
            slug: "mix",
            spec: spec,
            engineQueue: engineQueue,
            masterDirectory: sessionStore.recordingsRoot
        )
        let delegate = LaneDelegate(engine: self)
        lane.delegate = delegate
        setLane(lane)
        laneDelegate = delegate

        lane.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Log.info("start(): recording started")
                self.setStatus(.recording)
                completion(.success(()))
            case .failure(let error):
                Log.error("start(): lane failed to start: \(error)")
                lane.stop {
                    lane.removeAllSegmentFiles()
                    self.clearSession()
                    self.setStatus(.error("\(error)"))
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: Stop / export

    /// Graceful stop: the lane drains fully and finalizes its on-disk master
    /// segments, then each segment is promoted/exported to its final name.
    public func stop(completion: @escaping (StopOutcome) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else {
                completion(StopOutcome(fileURLs: [], failure: .nothingCaptured))
                return
            }
            if self.stopInProgress {
                self.queuedStopCompletions.append(completion)
                return
            }
            guard let lane = self.currentLane else {
                // Idle stop: report the last session's outcome if the engine
                // already finalized one on its own (device-wait timeout,
                // permanent lane failure) — don't fabricate a fresh error.
                completion(self.lastStopOutcome ?? StopOutcome(fileURLs: [], failure: .nothingCaptured))
                return
            }
            self.stopInProgress = true
            lane.stop {
                // Lane completion runs on the engine queue.
                let outcome = self.exportSession(lane: lane)
                self.clearSession()
                self.setLastStopOutcome(outcome)
                if let failure = outcome.failure {
                    Log.error("stop(): \(failure.message)")
                    self.setStatus(.error(failure.message))
                } else {
                    self.setStatus(.idle)
                }
                self.stopInProgress = false
                let queued = self.queuedStopCompletions
                self.queuedStopCompletions = []
                completion(outcome)
                queued.forEach { $0(outcome) }
            }
        }
    }

    private func clearSession() {
        setLane(nil)
        laneDelegate = nil
        currentSpec = nil
        currentNamingTemplate = nil
    }

    /// Promotes the lane's finished master segments to their final names.
    /// CAF output is a plain rename of the master (bit-identical, instant);
    /// WAV is transcoded by `ExportService` from the master, with Bug-A gain
    /// compensation applied when a calibration profile exists for the
    /// current device (DESIGN 8.3: default ON — the CAF master itself is
    /// always raw). Multiple segments (a mid-session rate change) become
    /// "title.ext", "title (part 2).ext", ... — each with its own correct
    /// sample rate, never one file with mixed-rate PCM.
    private func exportSession(lane: CaptureLane) -> StopOutcome {
        // Whatever happens below, the session is over: release the liveness
        // lock so any raw file left behind (export failure) is rescuable by
        // the next launch's sweep instead of staying hidden.
        defer { lane.releaseSessionLock() }

        let spec = currentSpec ?? SessionSpec()
        let template = currentNamingTemplate ?? "{date} {time} — {source}"

        let allSegments = lane.finishedSegments
        let segments = allSegments.filter { $0.frames > 0 }
        for empty in allSegments where empty.frames == 0 {
            try? FileManager.default.removeItem(at: empty.url)
        }
        guard !segments.isEmpty else {
            return StopOutcome(fileURLs: [], failure: .nothingCaptured)
        }

        let deviceName = (try? AudioDeviceDirectory.deviceName(AudioDeviceDirectory.resolveDevice(for: spec.device))) ?? "Unknown Device"
        let sourceLabel = "System Audio"
        let namingContext = SessionStore.NamingContext(
            source: sourceLabel, app: sourceLabel, device: deviceName, rateHz: segments[0].asbd.mSampleRate
        )
        var sanitizedTitle = SessionStore.sanitize(SessionStore.expand(template: template, context: namingContext))
        // A degenerate template (empty, whitespace, or all-dots) must never
        // yield an invisible dotfile (".caf") or an empty filename — fall
        // back to the default template.
        while sanitizedTitle.hasPrefix(".") { sanitizedTitle.removeFirst() }
        if sanitizedTitle.isEmpty {
            sanitizedTitle = SessionStore.sanitize(
                SessionStore.expand(template: "{date} {time} — {source}", context: namingContext)
            )
        }

        let ext: String
        switch spec.format {
        case .wav32: ext = "wav"
        case .caf32: ext = "caf"
        }
        let gainDB: Double? = (spec.format == .wav32) ? gainCompensation(for: spec) : nil

        let root = sessionStore.recordingsRoot
        var urls: [URL] = []
        for (index, segment) in segments.enumerated() {
            let baseName = index == 0 ? sanitizedTitle : "\(sanitizedTitle) (part \(index + 1))"
            let destination = SessionStore.uniqueDestinationURL(base: baseName, ext: ext, in: root)
            do {
                switch spec.format {
                case .caf32:
                    try FileManager.default.moveItem(at: segment.url, to: destination)
                case .wav32:
                    _ = try ExportService.export(
                        masterURL: segment.url, to: destination, format: .wav32, gainCompensationDB: gainDB
                    )
                    try? FileManager.default.removeItem(at: segment.url)
                }
                urls.append(destination)
            } catch {
                // Keep the raw master on disk — it is the only copy of the
                // audio; the crash sweep will surface it as "Recovered" on
                // the next launch if the user doesn't rescue it first.
                Log.error("stop(): export of \(segment.url.lastPathComponent) failed: \(error) — raw capture left at \(segment.url.path)")
                return StopOutcome(fileURLs: urls, failure: .exportFailed("\(error)"))
            }
        }

        Log.info("stop(): saved \(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
        return StopOutcome(fileURLs: urls, failure: nil)
    }

    /// The Bug-A gain profile matching the session's device, if any (DESIGN
    /// 8.3: applied to exports by default when a profile exists; the CAF
    /// master is never modified).
    private func gainCompensation(for spec: SessionSpec) -> Double? {
        guard let deviceID = try? AudioDeviceDirectory.resolveDevice(for: spec.device),
              let uid = try? AudioDeviceDirectory.deviceUID(deviceID),
              let channels = try? AudioDeviceDirectory.outputChannelCount(deviceID),
              let profile = CalibrationService.profile(
                  deviceUID: uid,
                  outputChannelCount: channels,
                  macOSBuild: ProcessInfo.processInfo.operatingSystemVersionString
              )
        else { return nil }
        Log.info("stop(): applying \(profile.gainCompensationDB) dB Bug-A gain compensation from calibration profile for \(uid)")
        return profile.gainCompensationDB
    }

    // MARK: Lane-initiated finalization (engine queue)

    /// Section 7.5 step 4: a `.fixed`-device lane gave up waiting for its
    /// device to return. Finalize gracefully — a valid session was produced
    /// (`lastStopOutcome` carries the saved file URLs for the CLI/GUI).
    fileprivate func handleLaneTimedOutWaitingForDevice() {
        Log.info("engine: device-wait timeout — finalizing session")
        stop { _ in }
    }

    /// A mid-session rebuild failed permanently: save whatever was captured,
    /// then surface the failure instead of reporting a phantom "recording".
    fileprivate func handleLaneFailure(_ message: String) {
        stop { [weak self] outcome in
            guard let self else { return }
            let suffix = outcome.fileURLs.isEmpty ? "" : " Partial recording saved."
            self.setStatus(.error("\(message).\(suffix)"))
        }
    }
}

public enum CaptureEngineError: Error, CustomStringConvertible {
    case alreadyRecording

    public var description: String {
        switch self {
        case .alreadyRecording: return "A recording is already in progress"
        }
    }
}

/// The lane's delegate: state changes are UI-layer concerns surfaced through
/// `EngineStatus`; the two terminal callbacks hand the session back to the
/// engine to finalize.
private final class LaneDelegate: CaptureLaneDelegate {
    weak var engine: CaptureEngine?
    init(engine: CaptureEngine) { self.engine = engine }

    func captureLane(_ lane: CaptureLane, didChangeState state: LaneState) {
        // Health-chip / UI concerns are layered on top by the GUI/CLI.
    }

    func captureLaneDidTimeOutWaitingForDevice(_ lane: CaptureLane) {
        engine?.handleLaneTimedOutWaitingForDevice()
    }

    func captureLane(_ lane: CaptureLane, didFailPermanently message: String) {
        engine?.handleLaneFailure(message)
    }
}
