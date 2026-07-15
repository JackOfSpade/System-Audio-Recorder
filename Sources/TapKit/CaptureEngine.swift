import CoreAudio
import Foundation

public enum EngineStatus: Sendable {
    case idle
    case recording(sessionFolder: URL)
    case error(String)
}

/// Top-level orchestrator (Section 4.2). Accepts a `SessionSpec`, asks
/// `SessionStore` to create the session folder + manifest, computes the lane
/// plan (Section 4.6), creates and owns the `CaptureLane` instances, and
/// runs the session lifecycle. Owns the **engine queue** — every Core Audio
/// hardware call in the process is serialized on it (Section 4.4).
public final class CaptureEngine {
    private let engineQueue = DispatchQueue(label: "com.systemaudiorecorder.engine", qos: .userInitiated)
    public let sessionStore: SessionStore

    private var lanes: [CaptureLane] = []
    // Each lane's `delegate` is `weak` (Section 4/8 callback contract), so
    // these bridges need a real strong owner for the session's lifetime.
    private var laneDelegates: [ManifestUpdatingDelegate] = []
    private var manifest: SessionManifest?
    private var sessionFolder: URL?
    private(set) public var status: EngineStatus = .idle

    public var onStatusChanged: ((EngineStatus) -> Void)?
    public var onMeterUpdate: (() -> [MeterSnapshot])?

    public init(recordingsRoot: URL) {
        self.sessionStore = SessionStore(recordingsRoot: recordingsRoot)
    }

    /// One entry per lane, in the SAME order as `watchdogStates()` — `nil`
    /// for a lane with no `drainLoop` yet (e.g. still preparing, or
    /// currently `.waitingForDevice`). This used to `compactMap` out the
    /// `nil`s, which silently shifted every later lane's snapshot into the
    /// wrong position relative to `watchdogStates()`'s per-lane array
    /// (which always keeps one entry per lane) — callers zipping the two
    /// together by index would pair up the wrong lane's meter and watchdog
    /// state whenever any earlier lane lacked a snapshot.
    public func meterSnapshots() -> [MeterSnapshot?] {
        // Read-only, safe from any thread: each DrainLoop's MeterSnapshotBox
        // is internally lock-guarded.
        lanes.map { $0.currentMeterSnapshot() }
    }

    /// Read-only per-lane watchdog states, in the same order as `meterSnapshots()`.
    public func watchdogStates() -> [WatchdogState] {
        lanes.map { $0.watchdogState }
    }

    /// Runs the TCC capture-permission probe (Section 9.4) serialized on the
    /// same engine queue as every other Core Audio hardware call (Section
    /// 4.4). The probe itself calls AudioHardwareCreateProcessTap /
    /// AudioHardwareDestroyProcessTap — running it on an unrelated
    /// `DispatchQueue.global()` would let it race a lane's own tap
    /// lifecycle calls on the HAL.
    public func requestCapturePermission(completion: @escaping (PermissionOutcome) -> Void) {
        engineQueue.async {
            let outcome = PermissionBroker.requestCapturePermission()
            completion(outcome)
        }
    }

    /// Starts a full session: creates the session folder + initial manifest,
    /// then starts the single capture lane. If it fails to start, the
    /// session is torn down and the error surfaced.
    public func start(spec: SessionSpec, namingTemplate: String = "{date} {time} — {source}", completion: @escaping (Result<URL, Error>) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.startOnEngineQueue(spec: spec, namingTemplate: namingTemplate, completion: completion)
        }
    }

    private func startOnEngineQueue(spec: SessionSpec, namingTemplate: String, completion: @escaping (Result<URL, Error>) -> Void) {
        // Without this guard, calling start() again while a session is
        // already recording would unconditionally overwrite `lanes`/
        // `laneDelegates`/`manifest`/`sessionFolder` below — the previous
        // session's `CaptureLane`s would simply be dropped, with nothing
        // ever calling `.stop()` on them, orphaning their live Core Audio
        // taps/aggregate devices/IOProcs and native ring/context memory
        // (CaptureLane has no deinit safety net for this).
        guard lanes.isEmpty else {
            completion(.failure(CaptureEngineError.alreadyRecording))
            return
        }
        let sourceLabel = "System Audio"

        let deviceID = (try? resolveDeviceID(spec.device)) ?? (try? AudioDeviceDirectory.defaultOutputDevice())
        let deviceUID = deviceID.flatMap { try? AudioDeviceDirectory.deviceUID($0) } ?? "unknown"
        let deviceName = deviceID.flatMap { try? AudioDeviceDirectory.deviceName($0) } ?? "Unknown Device"
        let rate = deviceID.flatMap { try? AudioDeviceDirectory.nominalSampleRate($0) } ?? 48000

        let title = SessionStore.expand(
            template: namingTemplate,
            context: SessionStore.NamingContext(source: sourceLabel, app: sourceLabel, device: deviceName, rateHz: rate)
        )

        guard let folder = try? sessionStore.createSessionFolder(title: title) else {
            completion(.failure(CaptureEngineError.couldNotCreateSessionFolder))
            return
        }
        sessionStore.createLockFile(in: folder)
        sessionFolder = folder

        let sessionInfo = SessionInfo(
            id: UUID().uuidString,
            title: title,
            createdAt: ManifestTimestamp.now(),
            finalizedAt: nil,
            recovered: false,
            sourceType: "systemMix",
            device: DeviceRef(uid: deviceUID, name: deviceName),
            deviceHistory: [DeviceHistoryEntry(uid: deviceUID, name: deviceName, fromWallTime: ManifestTimestamp.now())],
            timelinePolicy: spec.timelinePolicy.rawValue
        )

        // Always exactly one lane, slug "mix" — Section 4.6.
        let laneDir = folder.appendingPathComponent("mix")
        let lane = CaptureLane(
            index: 0,
            slug: "mix",
            laneDirectory: laneDir,
            spec: spec,
            engineQueue: engineQueue
        )
        let laneDelegate = ManifestUpdatingDelegate(engine: self)
        lane.delegate = laneDelegate
        lanes = [lane]
        laneDelegates = [laneDelegate]
        let laneEntries = [LaneEntry(
            index: 0, slug: "mix",
            processes: [], calibration: nil, segments: [], events: []
        )]

        let appInfo = AppInfo(name: "System Audio Recorder", version: "0.1.0", build: "1")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osInfo = OSInfo(version: osVersion, build: "unknown")
        let newManifest = SessionManifest(app: appInfo, os: osInfo, session: sessionInfo, lanes: laneEntries)
        manifest = newManifest
        sessionStore.writeManifest(newManifest, to: folder)

        let group = DispatchGroup()
        var firstError: Error?
        for lane in lanes {
            group.enter()
            lane.start { result in
                if case .failure(let error) = result, firstError == nil {
                    firstError = error
                }
                group.leave()
            }
        }
        group.notify(queue: engineQueue) { [weak self] in
            guard let self else { return }
            if let firstError {
                // Don't orphan lanes that DID start successfully just
                // because a sibling lane failed — tear all of them down
                // (live Core Audio hardware + a running DrainLoop thread per
                // lane) before reporting the session as failed.
                let stopGroup = DispatchGroup()
                for lane in self.lanes {
                    stopGroup.enter()
                    lane.stop { stopGroup.leave() }
                }
                stopGroup.notify(queue: self.engineQueue) {
                    // The graceful stop() path removes the lock file; this
                    // failure path previously didn't, leaving `.recording.lock`
                    // behind in a session folder that was never actually
                    // recording — `SessionStore.isLive` would then hold it
                    // "live" forever (its own PID, still running) even
                    // though no lane in it ever started.
                    self.sessionStore.removeLockFile(in: folder)
                    self.lanes = []
                    self.laneDelegates = []
                    self.status = .error("\(firstError)")
                    self.onStatusChanged?(self.status)
                    completion(.failure(firstError))
                }
            } else {
                self.status = .recording(sessionFolder: folder)
                self.onStatusChanged?(self.status)
                completion(.success(folder))
            }
        }
    }

    private func resolveDeviceID(_ policy: DevicePolicy) throws -> AudioObjectID {
        switch policy {
        case .followSystemDefault:
            return try AudioDeviceDirectory.defaultOutputDevice()
        case .fixed(let uid):
            guard let id = try AudioDeviceDirectory.findDevice(byUID: uid) else {
                throw CaptureEngineError.deviceNotFound(uid)
            }
            return id
        }
    }

    /// Graceful stop: every lane drains fully, finalizes its segments, then
    /// session-level finalization writes `finalizedAt`, removes the lock
    /// file, and fires `onSessionFinalize` — exactly once (Section 8.5/8.7).
    public func stop(completion: @escaping (URL?) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            let group = DispatchGroup()
            for lane in self.lanes {
                group.enter()
                lane.stop { group.leave() }
            }
            group.notify(queue: self.engineQueue) {
                guard let folder = self.sessionFolder else { completion(nil); return }
                // The caller (CLI/GUI) may exit or tear down immediately after
                // `completion` fires, so `completion` must not run until the
                // FINAL manifest write has actually landed on disk — writing
                // fire-and-forget here previously let the process exit before
                // `finalizedAt` (and each lane's finalized-segment update) was
                // ever persisted, leaving a stale, unfinalized session.json.
                guard var manifest = self.manifest else {
                    self.finishStop(folder: folder, completion: completion)
                    return
                }
                manifest.session.finalizedAt = ManifestTimestamp.now()
                self.manifest = manifest
                self.sessionStore.writeManifest(manifest, to: folder) {
                    self.sessionStore.removeLockFile(in: folder)
                    self.engineQueue.async {
                        self.finishStop(folder: folder, completion: completion)
                    }
                }
            }
        }
    }

    private func finishStop(folder: URL, completion: @escaping (URL?) -> Void) {
        self.lanes = []
        self.laneDelegates = []
        self.status = .idle
        self.onStatusChanged?(.idle)
        completion(folder)
    }

    // MARK: Manifest mutation from lane callbacks (engine queue only)

    fileprivate func updateManifest(_ mutate: @escaping (inout SessionManifest) -> Void) {
        engineQueue.async { [weak self] in
            guard let self, var manifest = self.manifest, let folder = self.sessionFolder else { return }
            mutate(&manifest)
            self.manifest = manifest
            self.sessionStore.writeManifest(manifest, to: folder)
        }
    }

    /// Section 7.5 step 4: a `.fixed`-device lane gave up waiting for its
    /// device to return. Finalize the whole session gracefully; the UI/CLI
    /// layer is responsible for surfacing the device-wait-timeout notification.
    fileprivate func handleLaneTimedOutWaitingForDevice() {
        stop { _ in }
    }
}

public enum CaptureEngineError: Error, CustomStringConvertible {
    case couldNotCreateSessionFolder
    case deviceNotFound(String)
    case alreadyRecording

    public var description: String {
        switch self {
        case .couldNotCreateSessionFolder: return "Could not create session folder"
        case .deviceNotFound(let uid): return "Device not found: \(uid)"
        case .alreadyRecording: return "A recording is already in progress"
        }
    }
}

/// Wires each lane's callbacks into the session manifest (Section 6.4's
/// write policy: engine-queue code calls SessionStore, never the drain
/// thread directly).
private final class ManifestUpdatingDelegate: CaptureLaneDelegate {
    weak var engine: CaptureEngine?
    init(engine: CaptureEngine) { self.engine = engine }

    func captureLane(_ lane: CaptureLane, didChangeState state: LaneState) {
        // Health-chip / UI concerns are layered on top by the GUI/CLI.
    }

    func captureLane(_ lane: CaptureLane, didAppendEvent event: EventEntry) {
        engine?.updateManifest { manifest in
            guard let idx = manifest.lanes.firstIndex(where: { $0.index == lane.index }) else { return }
            manifest.lanes[idx].events.append(event)
        }
    }

    func captureLane(_ lane: CaptureLane, didOpenSegment segment: SegmentEntry) {
        engine?.updateManifest { manifest in
            guard let idx = manifest.lanes.firstIndex(where: { $0.index == lane.index }) else { return }
            manifest.lanes[idx].segments.append(segment)
        }
    }

    func captureLane(_ lane: CaptureLane, didFinalizeSegment segment: SegmentEntry) {
        engine?.updateManifest { manifest in
            guard let idx = manifest.lanes.firstIndex(where: { $0.index == lane.index }) else { return }
            if let segIdx = manifest.lanes[idx].segments.firstIndex(where: { $0.index == segment.index }) {
                manifest.lanes[idx].segments[segIdx] = segment
            }
        }
    }

    func captureLaneDidTimeOutWaitingForDevice(_ lane: CaptureLane) {
        engine?.handleLaneTimedOutWaitingForDevice()
    }
}
