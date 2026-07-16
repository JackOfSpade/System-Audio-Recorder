import AudioToolbox
import CoreAudio
import Foundation

public enum EngineStatus: Sendable {
    case idle
    case recording
    case error(String)
}

/// Top-level orchestrator (Section 4.2). Accepts a `SessionSpec`,
/// computes the lane plan (Section 4.6), creates and owns the `CaptureLane` instances,
/// and runs the session lifecycle. Owns the **engine queue** — every Core Audio
/// hardware call in the process is serialized on it (Section 4.4).
public final class CaptureEngine {
    private let engineQueue = DispatchQueue(label: "com.systemaudiorecorder.engine", qos: .userInitiated)
    public let sessionStore: SessionStore

    private var lanes: [CaptureLane] = []
    private var laneDelegates: [ManifestUpdatingDelegate] = []
    private var currentSpec: SessionSpec?
    private var currentNamingTemplate: String?
    private(set) public var status: EngineStatus = .idle

    public var onStatusChanged: ((EngineStatus) -> Void)?
    public var onMeterUpdate: (() -> [MeterSnapshot])?

    public init(recordingsRoot: URL) {
        self.sessionStore = SessionStore(recordingsRoot: recordingsRoot)
    }

    /// One entry per lane, in the SAME order as `watchdogStates()` — `nil`
    /// for a lane with no `drainLoop` yet (e.g. still preparing, or
    /// currently `.waitingForDevice`).
    public func meterSnapshots() -> [MeterSnapshot?] {
        lanes.map { $0.currentMeterSnapshot() }
    }

    /// Read-only per-lane watchdog states, in the same order as `meterSnapshots()`.
    public func watchdogStates() -> [WatchdogState] {
        lanes.map { $0.watchdogState }
    }

    /// Runs the TCC capture-permission probe (Section 9.4) serialized on the
    /// same engine queue as every other Core Audio hardware call (Section
    /// 4.4).
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

    /// Starts a full session in memory. I/O buffer size is resolved by the
    /// lane itself, per device, from `CalibrationService`'s shared
    /// per-device store (Section 8.3; 512 if never calibrated) — the same
    /// shared store both the GUI and the CLI write to and read from, so a
    /// calibration run in either process is honored by both, and re-resolved
    /// on every rebuild in case a device switch changes which store entry
    /// applies (Section 7.3).
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
        guard lanes.isEmpty else {
            completion(.failure(CaptureEngineError.alreadyRecording))
            return
        }

        self.currentSpec = spec
        self.currentNamingTemplate = namingTemplate

        let lane = CaptureLane(
            index: 0,
            slug: "mix",
            spec: spec,
            engineQueue: engineQueue
        )
        let laneDelegate = ManifestUpdatingDelegate(engine: self)
        lane.delegate = laneDelegate
        lanes = [lane]
        laneDelegates = [laneDelegate]

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
                let stopGroup = DispatchGroup()
                for lane in self.lanes {
                    stopGroup.enter()
                    lane.stop { stopGroup.leave() }
                }
                stopGroup.notify(queue: self.engineQueue) {
                    self.lanes = []
                    self.laneDelegates = []
                    self.currentSpec = nil
                    self.currentNamingTemplate = nil
                    self.status = .error("\(firstError)")
                    self.onStatusChanged?(self.status)
                    completion(.failure(firstError))
                }
            } else {
                self.status = .recording
                self.onStatusChanged?(self.status)
                completion(.success(()))
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

    /// Graceful stop: every lane drains fully, then exports the in-memory Float32 PCM directly to the target destination.
    public func stop(completion: @escaping (URL?) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            let group = DispatchGroup()
            for lane in self.lanes {
                group.enter()
                lane.stop { group.leave() }
            }
            group.notify(queue: self.engineQueue) {
                guard let lane = self.lanes.first,
                      let spec = self.currentSpec,
                      let namingTemplate = self.currentNamingTemplate,
                      let asbd = lane.effectiveASBD else {
                    self.finishStop(fileURL: nil, completion: completion)
                    return
                }

                let sourceLabel = "System Audio"
                let deviceName = try? AudioDeviceDirectory.deviceName(try self.resolveDeviceID(spec.device))
                let resolvedDeviceName = deviceName ?? "Unknown Device"

                let title = SessionStore.expand(
                    template: namingTemplate,
                    context: SessionStore.NamingContext(source: sourceLabel, app: sourceLabel, device: resolvedDeviceName, rateHz: asbd.mSampleRate)
                )
                let sanitizedTitle = SessionStore.sanitize(title)

                let ext: String
                switch spec.format {
                case .wav32: ext = "wav"
                case .caf32: ext = "caf"
                }

                let filename = "\(sanitizedTitle).\(ext)"
                let finalURL = self.sessionStore.recordingsRoot.appendingPathComponent(filename)

                let tempURL = self.sessionStore.recordingsRoot.appendingPathComponent(".temp_capture_\(UUID().uuidString).caf")
                do {
                    try self.writeTemporaryCAF(url: tempURL, data: lane.recordedData, asbd: asbd)

                    _ = try ExportService.export(
                        masterURL: tempURL,
                        to: finalURL,
                        format: spec.format,
                        gainCompensationDB: nil
                    )

                    try? FileManager.default.removeItem(at: tempURL)
                    self.finishStop(fileURL: finalURL, completion: completion)
                } catch {
                    FileHandle.standardError.write("System Audio Recorder: failed to export: \(error)\n".data(using: .utf8)!)
                    try? FileManager.default.removeItem(at: tempURL)
                    self.finishStop(fileURL: nil, completion: completion)
                }
            }
        }
    }

    private func writeTemporaryCAF(url: URL, data: Data, asbd: AudioStreamBasicDescription) throws {
        var fileASBD = asbd
        var audioFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &audioFile
        )
        guard createStatus == noErr, let file = audioFile else {
            throw CoreAudioError(status: createStatus, context: "ExtAudioFileCreateWithURL")
        }
        defer { ExtAudioFileDispose(file) }

        var clientASBD = asbd
        let setStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard setStatus == noErr else {
            throw CoreAudioError(status: setStatus, context: "ExtAudioFileSetProperty(ClientDataFormat)")
        }

        let status = data.withUnsafeBytes { raw -> OSStatus in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: asbd.mChannelsPerFrame,
                    mDataByteSize: UInt32(raw.count),
                    mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)
                )
            )
            let frameCount = UInt32(raw.count) / asbd.mBytesPerFrame
            return ExtAudioFileWrite(file, frameCount, &bufferList)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "ExtAudioFileWrite")
        }
    }

    private func finishStop(fileURL: URL?, completion: @escaping (URL?) -> Void) {
        self.lanes = []
        self.laneDelegates = []
        self.currentSpec = nil
        self.currentNamingTemplate = nil
        self.status = .idle
        self.onStatusChanged?(.idle)
        completion(fileURL)
    }

    // MARK: Manifest mutation from lane callbacks (engine queue only)

    fileprivate func updateManifest(_ mutate: @escaping (inout SessionManifest) -> Void) {
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
