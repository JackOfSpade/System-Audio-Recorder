import CoreAudio
import SystemAudioRecorderRT
import Foundation

public enum LaneState: Equatable, Sendable {
    case idle
    case preparing
    case running
    case rebuilding
    case waitingForDevice
    case stopping
    case finalizing
    case failed(String)
}

public protocol CaptureLaneDelegate: AnyObject {
    func captureLane(_ lane: CaptureLane, didChangeState state: LaneState)
    func captureLane(_ lane: CaptureLane, didAppendEvent event: EventEntry)
    func captureLane(_ lane: CaptureLane, didOpenSegment segment: SegmentEntry)
    func captureLane(_ lane: CaptureLane, didFinalizeSegment segment: SegmentEntry)
    /// Section 7.5: the lane gave up waiting for its `.fixed` device to
    /// return and finalized itself. The delegate (CaptureEngine) is
    /// responsible for finalizing the whole session and surfacing the
    /// device-wait-timeout notification at the UI layer.
    func captureLaneDidTimeOutWaitingForDevice(_ lane: CaptureLane)
}

/// One independent capture pipeline: tap + private aggregate device + IOProc
/// + ring buffer + drain thread + segment writer + watchdog (Section 4.2,
/// Section 8.4). Every Core Audio lifecycle call for this lane runs on the
/// `engineQueue` passed at init — the SAME serial queue `CaptureEngine` uses
/// for every lane, satisfying the Section 4.4 serialization rule.
public final class CaptureLane {
    public let index: Int
    public let slug: String
    public weak var delegate: CaptureLaneDelegate?

    public var recordedData: Data {
        segmentWriter.data
    }
    public var effectiveASBD: AudioStreamBasicDescription? {
        segmentWriter.asbd
    }

    private let engineQueue: DispatchQueue
    private let spec: SessionSpec
    private let ownPID: pid_t

    public private(set) var state: LaneState = .idle {
        didSet { delegate?.captureLane(self, didChangeState: state) }
    }

    private var tapHandle: TapHandle?
    private var ioProcHost: IOProcHost?
    private var ring: OpaquePointer?
    private var context: OpaquePointer?
    private var drainLoop: DrainLoop?
    private let segmentWriter: SegmentWriter
    private let watchdog: ZeroWatchdog

    private var deviceObserver: DeviceObserver?
    private var waitingForDeviceUID: String?
    private var waitingForDeviceDeadline: Date?
    private var waitingForDeviceTimeoutTimer: DispatchSourceTimer?
    private var waitForDeviceTimeout: TimeInterval = 300 // 5 minutes, Section 7.5

    private var currentSegment: SegmentEntry?
    private var pendingEvents: [EventEntry] = []
    private var pendingSegments: [SegmentEntry] = []

    // Corroboration (Section 8.1) is documented as a 1Hz signal, but the
    // drain thread previously called the underlying HAL enumeration
    // (ProcessCatalog.isAnyRelevantProcessOutputting — a multi-round-trip,
    // unbounded-latency Core Audio property read across every audio-capable
    // process) directly and synchronously on every ~50ms drain cycle. That
    // could stall the drain thread — responsible for keeping the ring
    // buffer drained before it overflows — for however long the HAL call
    // happened to take. A dedicated 1Hz timer on the engine queue (never
    // real-time-adjacent) does the actual HAL call instead and caches the
    // result; the drain thread only ever does a cheap lock-guarded read.
    private let corroborationCacheLock = NSLock()
    private var cachedAudioExpected = false
    private var cachedCorroborationPolledAt = Date.distantPast
    private var corroborationTimer: DispatchSourceTimer?

    // Delegate bridges: each target's `delegate` property is `weak`, so these
    // need a real strong owner for the lane's lifetime — that owner is the
    // lane itself, via these `lazy var`s (safe to reference `self` in a lazy
    // initializer; it only runs on first access, after `init` completes).
    private lazy var watchdogBridge: WatchdogBridge = WatchdogBridge(lane: self)
    private lazy var drainDelegateBridge: DrainDelegateBridge = DrainDelegateBridge(lane: self)
    private lazy var deviceObserverBridge: DeviceObserverBridge = DeviceObserverBridge(lane: self)

    public init(
        index: Int,
        slug: String,
        spec: SessionSpec,
        engineQueue: DispatchQueue
    ) {
        self.index = index
        self.slug = slug
        self.spec = spec
        self.engineQueue = engineQueue
        self.ownPID = ProcessInfo.processInfo.processIdentifier
        self.segmentWriter = SegmentWriter()
        self.watchdog = ZeroWatchdog()
        self.watchdog.delegate = watchdogBridge
        startCorroborationPolling()
    }

    /// Runs for the lane's whole lifetime (independent of `.running`/`.idle`
    /// state — it's cheap, and simpler than starting/stopping it in lockstep
    /// with every rebuild/waitingForDevice transition).
    private func startCorroborationPolling() {
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let audioExpected = ProcessCatalog.isAnyRelevantProcessOutputting(excludingPIDs: [self.ownPID])
            self.corroborationCacheLock.lock()
            self.cachedAudioExpected = audioExpected
            self.cachedCorroborationPolledAt = Date()
            self.corroborationCacheLock.unlock()
        }
        timer.resume()
        corroborationTimer = timer
    }

    // MARK: Lifecycle (Section 8.4)

    /// PREPARING: resolve device + rate -> create tap -> aggregate -> IOProc
    /// -> start (Section 4.5). On any OSStatus error: retry once after 250ms,
    /// then FAILED with the OSStatus surfaced.
    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        engineQueue.async { [weak self] in
            self?.prepareAndStart(isRetry: false, completion: completion)
        }
    }

    private func prepareAndStart(isRetry: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        state = .preparing
        do {
            try buildAndRun(reuseExistingSegment: false)
            state = .running
            completion(.success(()))
        } catch {
            // Tear down whatever was partially created before retrying or
            // giving up (Section 8.4) — buildAndRun assigns tapHandle/ring/
            // context/ioProcHost to self as each step succeeds, so a
            // mid-sequence failure can leave real Core Audio objects (and
            // native ring/context memory) allocated with no other reference
            // to them once we retry.
            teardownCoreAudioObjectsOnly()
            if !isRetry {
                Log.error("lane \(slug): start attempt failed, retrying once in 250ms: \(error)")
                engineQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.prepareAndStart(isRetry: true, completion: completion)
                }
            } else {
                Log.error("lane \(slug): start failed after retry: \(error)")
                state = .failed("\(error)")
                completion(.failure(error))
            }
        }
    }

    /// The Section 4.5 recipe end to end: resolve process ids for this
    /// lane's apps, create the tap+aggregate via TapFactory, allocate the
    /// ring/context, register the IOProc, start it, open the first segment
    /// (unless `reuseExistingSegment` is true), and start the drain thread.
    ///
    /// `reuseExistingSegment`: true for watchdog-triggered rebuilds only
    /// (Section 8.1/8.2) — the segment file must stay open across Bug-B
    /// recovery, no rotation. The caller is responsible for having already
    /// finalized `currentSegment` when it wants a NEW segment opened (device
    /// switch / rate change rebuilds do this before calling rebuild()).
    private func buildAndRun(reuseExistingSegment: Bool) throws {
        let excludeIDs = resolveExcludeProcessObjectIDs()

        // Resolved once per call (initial build AND every rebuild) and
        // reused below for both the calibration lookup and TapFactory.create
        // — never cached across the lane's lifetime (a `.followSystemDefault`
        // rebuild can land on a physically different device, Section 7.3),
        // and never re-resolved a second time within one call (which could
        // in principle answer differently if the OS flips the default
        // output device in the interim).
        let deviceID = try AudioDeviceDirectory.resolveDevice(for: spec.device)
        let requestedBufferFrameSize = CalibrationService.effectiveBufferFrameSize(forResolvedDevice: deviceID)
        let (handle, bufferFrameSize) = try buildTapHandle(
            excludeIDs: excludeIDs, deviceID: deviceID, requestedBufferFrameSize: requestedBufferFrameSize
        )
        tapHandle = handle

        let isInterleaved = (handle.effectiveFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channels = Int(handle.effectiveFormat.mChannelsPerFrame)
        let bytesPerFrame = UInt32(4 * channels)

        let ringCapacity = Self.ringCapacityBytes(sampleRate: handle.effectiveFormat.mSampleRate, channels: channels)
        guard let newRing = td_ring_create(ringCapacity) else {
            throw CaptureLaneError.allocationFailed("ring")
        }
        guard let newContext = td_context_create(newRing, bytesPerFrame) else {
            td_ring_destroy(newRing)
            throw CaptureLaneError.allocationFailed("context")
        }
        ring = newRing
        context = newContext
        td_context_arm_first_host_time(newContext)

        let host = try IOProcHost(aggregateID: handle.aggregateID, context: newContext, interleaved: isInterleaved)
        ioProcHost = host

        let loop = DrainLoop(
            ring: newRing,
            context: newContext,
            bytesPerFrame: bytesPerFrame,
            channels: channels,
            sampleRate: handle.effectiveFormat.mSampleRate,
            planar: !isInterleaved,
            segmentWriter: segmentWriter,
            framesPerCallback: bufferFrameSize
        )
        loop.delegate = drainDelegateBridge
        drainLoop = loop

        if !reuseExistingSegment || currentSegment == nil {
            let asbd = SegmentWriter.canonicalASBD(sampleRate: handle.effectiveFormat.mSampleRate, channels: UInt32(channels))
            let segment = try segmentWriter.openNextSegment(asbd: asbd)
            currentSegment = makeSegmentEntry(from: segment)
            delegate?.captureLane(self, didOpenSegment: currentSegment!)
        }
        // else: watchdog rebuild — `segmentWriter.current`/`currentSegment`
        // were never touched by teardown(), so writes continue landing in
        // the same already-open CAF segment (Section 8.1).

        try host.start()
        loop.start()

        startObservingDeviceForThisLane(handle: handle)
    }

    /// Builds the tap+aggregate at `requestedBufferFrameSize` against the
    /// already-resolved `deviceID`. If — and only if — the device rejects
    /// that exact value at the buffer-size property write itself (a stale
    /// calibration entry: the device's real range narrowed since
    /// calibration ran, e.g. a sample-rate renegotiation, or a rebuild that
    /// landed on a different physical device than the one calibration
    /// measured), retries once, clamped into that device's own *live*
    /// `kAudioDevicePropertyBufferFrameSizeRange`, rather than letting a
    /// fixable buffer-size mismatch abandon the whole recording. Any other
    /// failure (permission, tap/aggregate creation) is NOT buffer-size
    /// related and must propagate unmodified, not trigger a pointless
    /// second attempt. A clamped retry is only ever used for this one
    /// session — it is deliberately NOT persisted back to the shared
    /// calibration store: a successful `AudioObjectSetPropertyData` is
    /// weaker evidence than `recommendBufferFrameSize`'s real probe, which
    /// also registers and starts an IOProc before trusting a candidate.
    private func buildTapHandle(
        excludeIDs: [AudioObjectID], deviceID: AudioObjectID, requestedBufferFrameSize: UInt32
    ) throws -> (TapHandle, UInt32) {
        do {
            let handle = try TapFactory.create(
                spec: spec, laneSlug: slug, excludeProcessIDs: excludeIDs,
                bufferFrameSize: requestedBufferFrameSize, resolvedDeviceID: deviceID
            )
            return (handle, requestedBufferFrameSize)
        } catch {
            guard (error as? CoreAudioError)?.context == "setBufferFrameSize",
                  let liveRange = try? AudioDeviceDirectory.bufferFrameSizeRange(deviceID) else {
                throw error
            }
            let clamped = min(max(requestedBufferFrameSize, liveRange.lowerBound), liveRange.upperBound)
            guard clamped != requestedBufferFrameSize else { throw error }
            let handle = try TapFactory.create(
                spec: spec, laneSlug: slug, excludeProcessIDs: excludeIDs,
                bufferFrameSize: clamped, resolvedDeviceID: deviceID
            )
            return (handle, clamped)
        }
    }

    private static func ringCapacityBytes(sampleRate: Float64, channels: Int) -> Int {
        // Section 5.3 sizing: next power of two >= 8 seconds of audio.
        let bytesPerSecond = Int(sampleRate) * channels * 4
        return bytesPerSecond * 8
    }

    private func resolveExcludeProcessObjectIDs() -> [AudioObjectID] {
        var ids: [AudioObjectID] = []
        if let ownObjectID = try? ProcessCatalog.translatePIDToProcessObject(ownPID) {
            ids.append(ownObjectID)
        }
        for bundleID in spec.excludeBundleIDs {
            if let id = ProcessCatalog.resolveBundleID(bundleID) {
                ids.append(id)
            }
        }
        return ids
    }

    private func makeSegmentEntry(from segment: SegmentWriter.OpenSegment) -> SegmentEntry {
        var ts = td_timestamps_t()
        if let context {
            td_context_read_timestamps(context, &ts)
        }
        return SegmentEntry(
            index: segment.index,
            file: "\(slug)/\(segment.url.lastPathComponent)",
            startWallTime: ManifestTimestamp.now(),
            startHostTime: "\(ts.first_host_time)",
            sampleRate: segment.asbd.mSampleRate,
            channels: Int(segment.asbd.mChannelsPerFrame),
            frames: nil,
            finalized: false
        )
    }

    // MARK: Teardown (Section 8.2 — STRICT order, canonical)

    /// AudioDeviceStop -> AudioDeviceDestroyIOProcID -> DestroyAggregateDevice
    /// -> DestroyProcessTap. Tolerates non-noErr at every step; always
    /// continues (TapFactory.destroy / IOProcHost already do this).
    private func teardown() {
        stopObservingDevice()
        teardownCoreAudioObjectsOnly()
    }

    /// Same as `teardown()` but leaves `deviceObserver` alone. Used when
    /// entering WAITING_FOR_DEVICE (Section 7.5), where the device-list
    /// listener must stay alive to detect the device's return — tearing it
    /// down (as full `teardown()` does) would leave no mechanism left that
    /// could ever notice the device coming back.
    private func teardownCoreAudioObjectsOnly() {
        ioProcHost?.stop()
        ioProcHost?.destroyIOProc()
        ioProcHost = nil
        if let handle = tapHandle {
            TapFactory.destroy(handle)
        }
        tapHandle = nil
        // `drainLoop` reads from `ring`/`context`, both destroyed just
        // below. `buildAndRun()` assigns a new DrainLoop to `self.drainLoop`
        // well before it could still throw later (e.g. opening the segment
        // file) — every caller of `teardownCoreAudioObjectsOnly()` on a
        // throw path used to leave that stale DrainLoop in place, pointing
        // at already-destroyed C objects. `stopAndDrainFully()` is a safe,
        // instant no-op if this particular DrainLoop's thread was never
        // started (the common case here) or was already stopped by the
        // caller.
        drainLoop?.stopAndDrainFully()
        drainLoop = nil
        if let context {
            td_context_destroy(context)
        }
        context = nil
        if let ring {
            td_ring_destroy(ring)
        }
        ring = nil
    }

    /// Full teardown + full recreation (Section 8.2). Never a partial
    /// restart — known-ineffective against Bug B. `reuseExistingSegment`
    /// is threaded straight through to `buildAndRun`.
    private func rebuild(reuseExistingSegment: Bool, completion: @escaping (Bool) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.state = .rebuilding
            self.drainLoop?.stopAndDrainFully()
            self.teardown()
            do {
                try self.buildAndRun(reuseExistingSegment: reuseExistingSegment)
                self.state = .running
                completion(true)
            } catch {
                self.teardownCoreAudioObjectsOnly()
                self.state = .failed("\(error)")
                completion(false)
            }
        }
    }

    // MARK: Stop / finalize

    public func stop(completion: @escaping () -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { completion(); return }
            self.state = .stopping
            self.waitingForDeviceTimeoutTimer?.cancel()
            self.waitingForDeviceTimeoutTimer = nil
            self.corroborationTimer?.cancel()
            self.corroborationTimer = nil
            // A backoff-delayed watchdog rebuild request scheduled just
            // before stop() was called would otherwise still fire
            // afterward and resurrect this lane's Core Audio pipeline even
            // though the caller believes the session is fully stopped.
            self.watchdog.invalidate()
            self.drainLoop?.stopAndDrainFully()
            self.teardown()
            if var segment = self.currentSegment {
                let result = self.segmentWriter.finalizeCurrentSegment()
                segment.frames = Int(result.frames)
                segment.finalized = result.succeeded
                self.currentSegment = nil
                self.delegate?.captureLane(self, didFinalizeSegment: segment)
            }
            self.state = .finalizing
            self.state = .idle
            completion()
        }
    }

    // MARK: Device switch / rate change (Section 7.3/7.4/7.5)

    private func startObservingDeviceForThisLane(handle: TapHandle) {
        let observer = DeviceObserver(engineQueue: engineQueue)
        observer.delegate = deviceObserverBridge
        switch spec.device {
        case .followSystemDefault:
            observer.startObservingDefaultOutput()
        case .fixed:
            observer.startObservingDeviceList()
        }
        observer.startObservingNominalRate(for: handle.targetDeviceID)
        deviceObserver = observer
    }

    private func stopObservingDevice() {
        deviceObserver?.stopObservingDefaultOutput()
        deviceObserver?.stopObservingNominalRate()
        deviceObserver?.stopObservingDeviceList()
        deviceObserver = nil
    }

    fileprivate func handleDefaultOutputChanged() {
        guard state == .running else { return }
        rotateSegmentThenRebuild(eventType: .deviceSwitch)
    }

    fileprivate func handleNominalRateChanged(deviceID: AudioObjectID) {
        guard state == .running else { return }
        rotateSegmentThenRebuild(eventType: .rateChange)
    }

    fileprivate func handleDeviceListChanged() {
        guard case .fixed(let uid) = spec.device else { return }
        if state == .running {
            // The device might have disappeared.
            guard let tapHandle, (try? AudioDeviceDirectory.deviceUID(tapHandle.targetDeviceID)) == nil else { return }
            enterWaitingForDevice(deviceUID: uid)
        } else if state == .waitingForDevice {
            // The device might have returned.
            guard (try? AudioDeviceDirectory.findDevice(byUID: uid)) != nil else { return }
            resumeFromWaitingForDevice()
        }
    }

    private func rotateSegmentThenRebuild(eventType: EventType) {
        if var segment = currentSegment {
            let result = segmentWriter.finalizeCurrentSegment()
            segment.frames = Int(result.frames)
            segment.finalized = result.succeeded
            currentSegment = nil
            delegate?.captureLane(self, didFinalizeSegment: segment)
        }
        rebuild(reuseExistingSegment: false) { [weak self] success in
            guard let self, success else { return }
            let event = EventEntry(
                type: eventType, atWallTime: ManifestTimestamp.now(),
                framePosition: 0, gapMs: nil, details: .object([:])
            )
            self.delegate?.captureLane(self, didAppendEvent: event)
        }
    }

    /// Section 7.5. `teardownCoreAudioObjectsOnly()` (NOT the full
    /// `teardown()`) deliberately leaves the device-list listener running so
    /// `handleDeviceListChanged` can detect the device coming back; a full
    /// teardown would remove the only mechanism left to notice that.
    private func enterWaitingForDevice(deviceUID: String) {
        state = .waitingForDevice
        // Same reasoning as `stop()`: no Core Audio pipeline exists to
        // rebuild while waiting for the device to return, so a pending
        // backoff-delayed rebuild request must not be allowed to fire here.
        watchdog.invalidate()
        if var segment = currentSegment {
            let result = segmentWriter.finalizeCurrentSegment()
            segment.frames = Int(result.frames)
            segment.finalized = result.succeeded
            currentSegment = nil
            delegate?.captureLane(self, didFinalizeSegment: segment)
        }
        // Stop the drain thread BEFORE destroying the ring/context it reads
        // from — otherwise a still-running drain thread would use-after-free
        // the ring on the next td_ring_read once teardownCoreAudioObjectsOnly
        // destroys it.
        drainLoop?.stopAndDrainFully()
        drainLoop = nil
        teardownCoreAudioObjectsOnly()
        waitingForDeviceUID = deviceUID
        waitingForDeviceDeadline = Date().addingTimeInterval(waitForDeviceTimeout)
        let event = EventEntry(
            type: .waitingForDevice, atWallTime: ManifestTimestamp.now(),
            framePosition: 0, gapMs: nil, details: .object(["resumed": .bool(false)])
        )
        delegate?.captureLane(self, didAppendEvent: event)

        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + waitForDeviceTimeout)
        timer.setEventHandler { [weak self] in
            self?.handleWaitingForDeviceTimeout()
        }
        timer.resume()
        waitingForDeviceTimeoutTimer = timer
    }

    /// Device returned within the timeout: full rebuild against it, new
    /// segment, resume RUNNING (Section 7.5 step 3).
    private func resumeFromWaitingForDevice() {
        waitingForDeviceTimeoutTimer?.cancel()
        waitingForDeviceTimeoutTimer = nil
        waitingForDeviceUID = nil
        waitingForDeviceDeadline = nil
        prepareAndStart(isRetry: false) { [weak self] result in
            guard let self, case .success = result else { return }
            let event = EventEntry(
                type: .waitingForDevice, atWallTime: ManifestTimestamp.now(),
                framePosition: 0, gapMs: nil, details: .object(["resumed": .bool(true)])
            )
            self.delegate?.captureLane(self, didAppendEvent: event)
        }
    }

    /// Section 7.5 step 4: the device never returned within
    /// `waitForDeviceTimeout` — finalize this lane gracefully and let the
    /// delegate (CaptureEngine) finalize the whole session.
    private func handleWaitingForDeviceTimeout() {
        guard state == .waitingForDevice else { return }
        waitingForDeviceTimeoutTimer = nil
        waitingForDeviceUID = nil
        waitingForDeviceDeadline = nil
        // The device never came back — nothing left to observe.
        // `enterWaitingForDevice` deliberately left `deviceObserver` alive
        // so it could detect a return; now that we're giving up, it must
        // be torn down too, or its Core Audio property listener stays
        // registered indefinitely even though this lane is about to report
        // itself idle.
        teardown()
        state = .finalizing
        state = .idle
        delegate?.captureLaneDidTimeOutWaitingForDevice(self)
    }

    // MARK: Watchdog corroboration input (Section 8.1)

    public func updateCorroboration(_ snapshot: CorroborationSnapshot) {
        watchdog.updateCorroboration(snapshot)
    }

    /// Read-only meter snapshot for UI polling at 20 Hz (Section 5.4 step 8).
    /// Safe from any thread: `MeterSnapshotBox` is internally lock-guarded.
    public func currentMeterSnapshot() -> MeterSnapshot? {
        drainLoop?.meterBox.read()
    }

    /// Read-only watchdog state, e.g. for `--max-silence-stop` to distinguish
    /// genuine silence from an active Bug-B recovery. Safe from any thread:
    /// `ZeroWatchdog.state` is internally lock-guarded.
    public var watchdogState: WatchdogState {
        watchdog.state
    }
}

public enum CaptureLaneError: Error, CustomStringConvertible {
    case allocationFailed(String)
    public var description: String {
        switch self {
        case .allocationFailed(let what): return "Failed to allocate \(what)"
        }
    }
}

/// Bridges `ZeroWatchdog`'s callbacks (fired on the DrainLoop thread) to the
/// lane's rebuild machinery (which must run on the engine queue).
private final class WatchdogBridge: ZeroWatchdogDelegate {
    weak var lane: CaptureLane?
    init(lane: CaptureLane) { self.lane = lane }

    func zeroWatchdogRequestsRebuild(_ watchdog: ZeroWatchdog, attempt: Int) {
        guard let lane else { return }
        lane.rebuildFromWatchdog(attempt: attempt)
    }
    func zeroWatchdogDidEscalate(_ watchdog: ZeroWatchdog) {
        lane?.watchdogDidEscalate()
    }
    func zeroWatchdogDidDeescalate(_ watchdog: ZeroWatchdog) {
        lane?.watchdogDidDeescalate()
    }
}

private final class DrainDelegateBridge: DrainLoopDelegate {
    weak var lane: CaptureLane?
    init(lane: CaptureLane) { self.lane = lane }

    func drainLoop(_ loop: DrainLoop, zeroRunSeconds: Double) {
        lane?.reportZeroRunFromDrain(zeroRunSeconds)
    }
    func drainLoop(_ loop: DrainLoop, overrunDroppedChunks: UInt64, droppedFrames: UInt64) {
        lane?.reportOverrunFromDrain(chunks: overrunDroppedChunks, frames: droppedFrames)
    }
}

private final class DeviceObserverBridge: DeviceObserverDelegate {
    weak var lane: CaptureLane?
    init(lane: CaptureLane) { self.lane = lane }

    func deviceObserverDefaultOutputChanged(_ observer: DeviceObserver) {
        lane?.handleDefaultOutputChanged()
    }
    func deviceObserverNominalRateChanged(_ observer: DeviceObserver, deviceID: AudioObjectID) {
        lane?.handleNominalRateChanged(deviceID: deviceID)
    }
    func deviceObserverDeviceListChanged(_ observer: DeviceObserver) {
        lane?.handleDeviceListChanged()
    }
}

extension CaptureLane {
    fileprivate func rebuildFromWatchdog(attempt: Int) {
        // reuseExistingSegment: true — Bug-B rebuilds never rotate the
        // segment (Section 8.1: "the segment stays open across rebuilds").
        rebuild(reuseExistingSegment: true) { [weak self] success in
            self?.watchdog.rebuildCompleted(success: success)
        }
    }

    fileprivate func watchdogDidEscalate() {
        let event = EventEntry(
            type: .error, atWallTime: ManifestTimestamp.now(), framePosition: 0,
            gapMs: nil, details: .object(["osStatus": .integer(0), "context": .string("watchdog escalated")])
        )
        delegate?.captureLane(self, didAppendEvent: event)
    }

    fileprivate func watchdogDidDeescalate() {
        // Health chip / notification withdrawal is a GUI-layer concern.
    }

    fileprivate func reportZeroRunFromDrain(_ seconds: Double) {
        watchdog.reportZeroRun(seconds: seconds)
        if watchdog.state != .normal {
            // Cheap lock-guarded read of the 1Hz-cached value — see
            // `startCorroborationPolling()`. `polledAt` is the time of the
            // actual underlying poll, not this read, so the watchdog's own
            // staleness check (Section 8.1) still correctly detects a
            // stalled corroboration feed instead of always looking "fresh."
            corroborationCacheLock.lock()
            let audioExpected = cachedAudioExpected
            let polledAt = cachedCorroborationPolledAt
            corroborationCacheLock.unlock()
            watchdog.updateCorroboration(CorroborationSnapshot(audioExpected: audioExpected, polledAt: polledAt))
        }
    }

    fileprivate func reportOverrunFromDrain(chunks: UInt64, frames: UInt64) {
        let event = EventEntry(
            type: .overrunGap, atWallTime: ManifestTimestamp.now(), framePosition: 0,
            gapMs: nil, details: .object(["framesLost": .integer(Int(frames)), "chunks": .integer(Int(chunks))])
        )
        delegate?.captureLane(self, didAppendEvent: event)
    }
}
