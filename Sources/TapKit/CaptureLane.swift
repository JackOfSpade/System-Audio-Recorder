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
    /// Section 7.5: the lane gave up waiting for its `.fixed` device to
    /// return and finalized itself. The delegate (CaptureEngine) is
    /// responsible for finalizing the whole session and surfacing the
    /// device-wait-timeout notification at the UI layer.
    func captureLaneDidTimeOutWaitingForDevice(_ lane: CaptureLane)
    /// A device-switch/rate-change rebuild or resume-from-waiting failed for
    /// good: the lane has torn itself down and no further audio will be
    /// captured. The delegate must finalize the session (saving whatever was
    /// captured) and surface the error — without this, the engine/UI would
    /// keep reporting "recording" while capturing nothing.
    func captureLane(_ lane: CaptureLane, didFailPermanently message: String)
}

/// One independent capture pipeline: tap + private aggregate device + IOProc
/// + ring buffer + drain thread + segment writer + watchdog (Section 4.2,
/// Section 8.4). Every Core Audio lifecycle call for this lane runs on the
/// `engineQueue` passed at init — the SAME serial queue `CaptureEngine` uses
/// (Section 4.4 serialization rule).
public final class CaptureLane {
    public let slug: String
    public weak var delegate: CaptureLaneDelegate?

    public var effectiveASBD: AudioStreamBasicDescription? {
        segmentWriter.asbd
    }
    /// The session's finished master segment files, in capture order. Read
    /// after `stop()` has completed.
    public var finishedSegments: [SegmentWriter.FinishedSegment] {
        segmentWriter.finishedSegments
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
    /// Owned by the lane (not by any one `DrainLoop`) so meter reads are safe
    /// from any thread at any lifecycle moment — reading a `drainLoop`
    /// property that the engine queue concurrently reassigns during a rebuild
    /// would be a data race. The box itself is internally lock-guarded, and
    /// meters survive rebuilds instead of blinking out.
    private let meterBox = MeterSnapshotBox()

    private var deviceObserver: DeviceObserver?
    private var waitingForDeviceTimeoutTimer: DispatchSourceTimer?
    private var waitForDeviceTimeout: TimeInterval = 300 // 5 minutes, Section 7.5

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
    private var cachedCorroborationErrored = false
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
        slug: String,
        spec: SessionSpec,
        engineQueue: DispatchQueue,
        masterDirectory: URL
    ) {
        self.slug = slug
        self.spec = spec
        self.engineQueue = engineQueue
        self.ownPID = ProcessInfo.processInfo.processIdentifier
        self.segmentWriter = SegmentWriter(directory: masterDirectory)
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
            // nil = the HAL enumeration itself failed. That must surface as
            // `errored` (Section 8.1's stale-or-errored fallback), NOT as
            // "no one is playing" — the latter holds the watchdog in
            // SUSPICIOUS forever, silently disabling Bug-B recovery for as
            // long as the enumeration keeps failing.
            let audioExpected = ProcessCatalog.isAnyRelevantProcessOutputting(excludingPIDs: [self.ownPID])
            self.corroborationCacheLock.lock()
            self.cachedAudioExpected = audioExpected ?? false
            self.cachedCorroborationErrored = (audioExpected == nil)
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
                    guard let self else { return }
                    // A stop() that raced in during the 250ms backoff moved
                    // the lane out of .preparing — retrying now would
                    // resurrect a pipeline the caller believes never started.
                    guard self.state == .preparing else {
                        completion(.failure(CaptureLaneError.canceled))
                        return
                    }
                    self.prepareAndStart(isRetry: true, completion: completion)
                }
            } else {
                Log.error("lane \(slug): start failed after retry: \(error)")
                state = .failed("\(error)")
                completion(.failure(error))
            }
        }
    }

    /// The Section 4.5 recipe end to end: resolve the device, create the
    /// tap+aggregate via TapFactory, allocate the ring/context, register the
    /// IOProc, start it, open the first segment (unless `reuseExistingSegment`
    /// is true and one is already open), and start the drain thread.
    ///
    /// `reuseExistingSegment`: true for watchdog-triggered rebuilds only
    /// (Section 8.1/8.2) — the segment file must stay open across Bug-B
    /// recovery, no rotation. Rotation paths (device switch / rate change)
    /// finalize the open segment first, so a fresh one is opened here.
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
        // Section 5.3 planar framing contract: the drain side parses planar
        // ring content as fixed bufferFrameSize-frame blocks, so the producer
        // must drop any odd-sized planar chunk rather than desync the stream.
        td_context_set_expected_frames(newContext, bufferFrameSize)
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
            framesPerCallback: bufferFrameSize,
            meterBox: meterBox
        )
        loop.delegate = drainDelegateBridge
        drainLoop = loop

        if !reuseExistingSegment || !segmentWriter.hasOpenSegment {
            let asbd = SegmentWriter.canonicalASBD(sampleRate: handle.effectiveFormat.mSampleRate, channels: UInt32(channels))
            let url = try segmentWriter.openNextSegment(asbd: asbd)
            Log.info("lane \(slug): opened segment \(url.lastPathComponent) @ \(Int(asbd.mSampleRate))Hz, \(channels)ch")
        }
        // else: watchdog rebuild — the already-open CAF segment keeps
        // receiving writes across Bug-B recovery (Section 8.1).

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

    // MARK: Teardown (Section 8.2 — STRICT order, canonical)

    /// AudioDeviceStop -> AudioDeviceDestroyIOProcID -> DestroyAggregateDevice
    /// -> DestroyProcessTap -> final drain -> destroy ring/context. Tolerates
    /// non-noErr at every step; always continues (TapFactory.destroy /
    /// IOProcHost already do this).
    private func teardown() {
        stopObservingDevice()
        teardownCoreAudioObjectsOnly()
    }

    /// Same as `teardown()` but leaves `deviceObserver` alone. Used when
    /// entering WAITING_FOR_DEVICE (Section 7.5), where the device-list
    /// listener must stay alive to detect the device's return — tearing it
    /// down (as full `teardown()` does) would leave no mechanism left that
    /// could ever notice the device coming back.
    ///
    /// Ordering matters: the IOProc is stopped BEFORE the drain thread is
    /// asked to finish, so the final drain pass empties everything the
    /// IOProc produced up to the very last callback. Stopping the drain
    /// first (the previous order in stop()/rebuild()) silently discarded
    /// the last IO-cycle-or-two of audio at every stop and rotation.
    private func teardownCoreAudioObjectsOnly() {
        ioProcHost?.stop()
        ioProcHost?.destroyIOProc()
        ioProcHost = nil
        if let handle = tapHandle {
            TapFactory.destroy(handle)
        }
        tapHandle = nil
        // `drainLoop` reads from `ring`/`context`, both destroyed just
        // below — the drain thread must have fully exited before they go.
        // `stopAndDrainFully()` is a safe no-op if this DrainLoop's thread
        // was never started.
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
        // Stale meters must not survive the pipeline (e.g. into
        // WAITING_FOR_DEVICE, where the CLI's silence-stop logic reads them).
        meterBox.publish(.empty)
    }

    /// Full teardown + full recreation (Section 8.2). Never a partial
    /// restart — known-ineffective against Bug B.
    ///
    /// `rotateSegment`: true for device-switch/rate-change rebuilds — the
    /// open segment is finalized (AFTER the final drain, so nothing is lost)
    /// and `buildAndRun` opens a fresh one with the new device's ASBD.
    /// False for watchdog (Bug-B) rebuilds, which keep the segment open.
    private func rebuild(rotateSegment: Bool, completion: @escaping (Bool) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            // A rebuild request that raced a stop()/timeout must not
            // resurrect a lane the owner believes is fully stopped.
            guard self.state == .running || self.state == .rebuilding else {
                completion(false)
                return
            }
            self.state = .rebuilding
            if rotateSegment {
                // The imminent full rebuild supersedes any scheduled watchdog
                // work (a pending backoff rebuild OR a 60s ESCALATED retry) —
                // letting either fire afterward would tear down the freshly
                // rebuilt pipeline or churn guard-rejected phantom attempts.
                // The watchdog resets to NORMAL so zeros on the NEW pipeline
                // re-confirm from scratch. (Not done for watchdog-initiated
                // rebuilds: rebuildCompleted drives that state machine.)
                self.watchdog.resetForExternalRebuild()
            }
            self.teardown()
            if rotateSegment {
                self.finalizeOpenSegment()
            }
            do {
                try self.buildAndRun(reuseExistingSegment: !rotateSegment)
                self.state = .running
                completion(true)
            } catch {
                Log.error("lane \(self.slug): rebuild failed: \(error)")
                self.teardownCoreAudioObjectsOnly()
                if rotateSegment {
                    self.state = .failed("\(error)")
                } else {
                    // Watchdog (Bug-B) rebuild failures are NOT terminal: the
                    // watchdog owns the retry policy (0.5/2/5s backoff, then
                    // 60s ESCALATED retries) and the entry guard above must
                    // let the next attempt back in — a `.failed` state here
                    // would make the first transient failure permanent.
                    self.state = .rebuilding
                }
                completion(false)
            }
        }
    }

    private func finalizeOpenSegment() {
        let result = segmentWriter.finalizeCurrentSegment()
        if result.succeeded {
            Log.info("lane \(slug): finalized segment (\(result.frames) frames)")
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
            // Sticky: from here on the watchdog can neither fire a pending
            // backoff-delayed rebuild nor re-arm one from the final drain
            // passes below — either would resurrect this lane's Core Audio
            // pipeline even though the caller believes the session is fully
            // stopped.
            self.watchdog.invalidate()
            self.teardown()
            self.finalizeOpenSegment()
            self.state = .finalizing
            self.state = .idle
            completion()
        }
    }

    /// Deletes every master segment file this lane produced. For sessions
    /// that failed to start or captured nothing worth keeping.
    public func removeAllSegmentFiles() {
        segmentWriter.removeAllSegmentFiles()
    }

    /// Releases the session-liveness lock once the engine has consumed the
    /// finished segments (exported or attempted). See
    /// `SegmentWriter.releaseSessionLock`.
    public func releaseSessionLock() {
        segmentWriter.releaseSessionLock()
    }

    /// A rotation/resume rebuild failed for good: finish tearing down
    /// (observer, timers, watchdog) so nothing leaks while the lane sits in
    /// `.failed`, finalize whatever was captured, and hand the session back
    /// to the delegate to save and surface.
    private func handlePermanentFailure(_ message: String) {
        Log.error("lane \(slug): \(message)")
        waitingForDeviceTimeoutTimer?.cancel()
        waitingForDeviceTimeoutTimer = nil
        watchdog.invalidate()
        teardown()
        finalizeOpenSegment()
        delegate?.captureLane(self, didFailPermanently: message)
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
        rotateSegmentThenRebuild(reason: "default output device changed")
    }

    fileprivate func handleNominalRateChanged(deviceID: AudioObjectID) {
        guard state == .running else { return }
        rotateSegmentThenRebuild(reason: "device sample rate changed")
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

    private func rotateSegmentThenRebuild(reason: String) {
        Log.info("lane \(slug): \(reason) — rotating segment and rebuilding")
        rebuild(rotateSegment: true) { [weak self] success in
            guard let self, !success else { return }
            self.handlePermanentFailure("Rebuild after \(reason) failed twice; capture cannot continue")
        }
    }

    /// Section 7.5. `teardownCoreAudioObjectsOnly()` (NOT the full
    /// `teardown()`) deliberately leaves the device-list listener running so
    /// `handleDeviceListChanged` can detect the device coming back; a full
    /// teardown would remove the only mechanism left to notice that.
    private func enterWaitingForDevice(deviceUID: String) {
        state = .waitingForDevice
        // No Core Audio pipeline exists to rebuild while waiting for the
        // device to return, so all scheduled watchdog work (backoff rebuild
        // AND 60s ESCALATED retry) must be cancelled and the episode reset.
        // (Not the sticky invalidate — the watchdog must come back to life
        // if the device returns.)
        watchdog.resetForExternalRebuild()
        // IOProc stop -> final drain -> destroy, THEN finalize: the segment
        // gets every frame the (now dead) device delivered before vanishing.
        teardownCoreAudioObjectsOnly()
        finalizeOpenSegment()
        Log.info("lane \(slug): device \(deviceUID) disappeared — waiting up to \(Int(waitForDeviceTimeout))s for it to return")

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
        Log.info("lane \(slug): device returned — resuming capture")
        prepareAndStart(isRetry: false) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.handlePermanentFailure("Device returned but capture could not be rebuilt: \(error)")
        }
    }

    /// Section 7.5 step 4: the device never returned within
    /// `waitForDeviceTimeout` — finalize this lane gracefully and let the
    /// delegate (CaptureEngine) finalize the whole session.
    private func handleWaitingForDeviceTimeout() {
        guard state == .waitingForDevice else { return }
        waitingForDeviceTimeoutTimer = nil
        // The device never came back — nothing left to observe.
        // `enterWaitingForDevice` deliberately left `deviceObserver` alive
        // so it could detect a return; now that we're giving up, it must
        // be torn down too, or its Core Audio property listener stays
        // registered indefinitely even though this lane is about to report
        // itself idle.
        teardown()
        Log.info("lane \(slug): device never returned within \(Int(waitForDeviceTimeout))s — finalizing session")
        state = .finalizing
        state = .idle
        delegate?.captureLaneDidTimeOutWaitingForDevice(self)
    }

    // MARK: Live status (any thread)

    /// Read-only meter snapshot for UI polling at 20 Hz (Section 5.4 step 8).
    /// Safe from any thread: the lane-owned `MeterSnapshotBox` is internally
    /// lock-guarded and survives rebuilds.
    public func currentMeterSnapshot() -> MeterSnapshot {
        meterBox.read()
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
    case canceled
    public var description: String {
        switch self {
        case .allocationFailed(let what): return "Failed to allocate \(what)"
        case .canceled: return "Start was canceled by a concurrent stop"
        }
    }
}

/// Bridges `ZeroWatchdog`'s callbacks (fired on the DrainLoop thread or a
/// backoff timer queue) to the lane's rebuild machinery (which must run on
/// the engine queue).
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
    func drainLoop(_ loop: DrainLoop, didFailWriting error: String) {
        lane?.reportWriteFailureFromDrain(error)
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
        // rotateSegment: false — Bug-B rebuilds never rotate the segment
        // (Section 8.1: "the segment stays open across rebuilds"). Failure
        // is NOT permanent here: the watchdog owns its own retry/escalation
        // policy (backoff schedule, attempt budget, 60s ESCALATED retries).
        rebuild(rotateSegment: false) { [weak self] success in
            self?.watchdog.rebuildCompleted(success: success)
        }
    }

    fileprivate func watchdogDidEscalate() {
        Log.error("lane \(slug): watchdog ESCALATED — Bug-B dropout persists after repeated rebuilds; retrying every 60s")
    }

    fileprivate func watchdogDidDeescalate() {
        Log.info("lane \(slug): watchdog recovered from ESCALATED")
    }

    fileprivate func reportZeroRunFromDrain(_ seconds: Double) {
        watchdog.reportZeroRun(seconds: seconds)
        if watchdog.state != .normal {
            // Cheap lock-guarded read of the 1Hz-cached value — see
            // `startCorroborationPolling()`. `polledAt` is the time of the
            // actual underlying poll, not this read: the watchdog both
            // detects a stalled corroboration feed (Section 8.1 freshness
            // rule) and dedupes re-deliveries of the same poll, so feeding
            // it every ~50ms drain cycle is safe.
            corroborationCacheLock.lock()
            let audioExpected = cachedAudioExpected
            let errored = cachedCorroborationErrored
            let polledAt = cachedCorroborationPolledAt
            corroborationCacheLock.unlock()
            watchdog.updateCorroboration(CorroborationSnapshot(audioExpected: audioExpected, polledAt: polledAt, errored: errored))
        }
    }

    fileprivate func reportOverrunFromDrain(chunks: UInt64, frames: UInt64) {
        Log.error("lane \(slug): ring overrun — dropped \(frames) frames across \(chunks) chunks")
    }

    /// Fired (once per DrainLoop) from the drain thread after ~1 s of
    /// back-to-back segment-write failures — disk full or I/O error. Every
    /// drained sample is being lost, so finalize the session and surface the
    /// failure instead of letting stop() report success on a truncated file.
    fileprivate func reportWriteFailureFromDrain(_ message: String) {
        engineQueue.async { [weak self] in
            guard let self, self.state == .running || self.state == .rebuilding else { return }
            self.handlePermanentFailure("Recording writes are failing (\(message)) — disk full or I/O error")
        }
    }
}
