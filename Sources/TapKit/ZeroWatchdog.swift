import Foundation

/// Bug-B all-zero dropout detector + rebuild executor (DESIGN.md Section 8.1).
/// Zero-run accounting and corroboration reporting normally happen from the
/// lane's `DrainLoop` thread, but `rebuildCompleted(success:)` is called from
/// the engine queue (by `CaptureLane`, after a teardown+rebuild finishes) —
/// a second, legitimate caller thread. All public entry points therefore
/// serialize on an internal lock rather than assuming single-thread access.
public enum WatchdogState: Equatable, Sendable {
    case normal
    case suspicious
    case confirmedDropout
    case rebuilding
    case postRebuildVerify
    case escalated
}

/// "Is any relevant process currently outputting audio?" — produced by
/// `ProcessCatalog` at 1 Hz, published with a poll timestamp so the watchdog
/// can apply the Section 8.1 freshness rule.
public struct CorroborationSnapshot: Sendable {
    public let audioExpected: Bool
    public let polledAt: Date
    public let errored: Bool

    public init(audioExpected: Bool, polledAt: Date, errored: Bool = false) {
        self.audioExpected = audioExpected
        self.polledAt = polledAt
        self.errored = errored
    }
}

public protocol ZeroWatchdogDelegate: AnyObject {
    /// Request a full teardown+rebuild (Section 8.2). Called on the drain
    /// thread; the delegate is responsible for hopping to the engine queue.
    func zeroWatchdogRequestsRebuild(_ watchdog: ZeroWatchdog, attempt: Int)
    /// The watchdog entered ESCALATED — post the UserNotifications alert and
    /// set the health chip to ⚠ (Section 8.1).
    func zeroWatchdogDidEscalate(_ watchdog: ZeroWatchdog)
    /// The watchdog left ESCALATED (either recovered or downgraded to
    /// SUSPICIOUS because corroboration says "no one is playing").
    func zeroWatchdogDidDeescalate(_ watchdog: ZeroWatchdog)
}

/// Exact thresholds from Section 8.1 — do not approximate these.
public enum WatchdogThresholds {
    public static let armSeconds: Double = 5
    public static let confirmSeconds: Double = 10
    public static let uncorroboratedFallbackSeconds: Double = 60
    public static let snapshotFreshnessSeconds: TimeInterval = 3
    public static let backoffSeconds: [Double] = [0.5, 2, 5]
    public static let maxAttemptsPerWindow = 3
    public static let attemptWindowSeconds: TimeInterval = 600 // 10 minutes
    public static let escalatedRetrySeconds: TimeInterval = 60
    public static let requiredConsecutiveCorroboratedPolls = 3
    public static let requiredConsecutiveStaleOrErroredPolls = 3
}

/// One instance per `CaptureLane`. All public methods lock internally, so
/// they may be called from either the DrainLoop thread (zero-run/
/// corroboration reporting) or the engine queue (`rebuildCompleted`).
public final class ZeroWatchdog {
    public weak var delegate: ZeroWatchdogDelegate?

    // Recursive, not plain `NSLock`: delegate callbacks below are invoked
    // while the lock is held (restructuring every call site to defer them
    // until after unlock would be a much larger change for a risk that is
    // purely theoretical today — no current delegate implementation calls
    // back into the watchdog synchronously). If one ever did, a plain
    // `NSLock` would self-deadlock the calling thread; a recursive lock
    // lets same-thread reentry proceed instead.
    private let lock = NSRecursiveLock()
    private var _state: WatchdogState = .normal
    public var state: WatchdogState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private var lastCorroboration: CorroborationSnapshot?
    private var consecutiveCorroboratedPolls = 0
    private var consecutiveStaleOrErroredPolls = 0

    /// Wall-clock timestamps of rebuild attempts still inside the sliding
    /// 10-minute window (Section 8.1 "Backoff and attempt budget").
    private var attemptTimestamps: [Date] = []
    private var currentAttemptNumber = 0

    private var zeroRunStartedAt: Date?
    private var rebuildCompletedAt: Date?
    /// Sticky kill switch, set by `invalidate()` when the owning lane is
    /// stopped for good. Every public entry point no-ops afterward — the
    /// final drain passes that run during teardown must not be able to
    /// schedule a new rebuild (or fire one synchronously from ESCALATED)
    /// that would resurrect a lane the caller believes is fully stopped.
    private var isInvalidated = false
    /// True from the moment this dropout episode first enters ESCALATED
    /// until the episode fully resolves (back to NORMAL, or downgraded to
    /// SUSPICIOUS) — tracked separately from `_state` because by the time a
    /// successful rebuild resolves the episode, `_state` has already moved
    /// on to REBUILDING/POST_REBUILD_VERIFY/NORMAL, so checking
    /// `_state == .escalated` at that point would always be false and the
    /// deescalate callback would never fire even though escalation is over.
    private var wasEverEscalatedThisEpisode = false
    /// The scheduled 60 s ESCALATED retry, as its own cancellable work item.
    /// It must NOT be driven by the drain cycle (the previous approach): a
    /// failed rebuild tears the drain thread down, so a drain-driven retry
    /// could never fire in exactly the case ESCALATED exists for.
    private var escalatedRetryWorkItem: DispatchWorkItem?
    /// The currently-scheduled backoff-delayed rebuild request, if any
    /// (Section 8.1's 0.5/2/5s schedule). Cancelling this is what stops a
    /// scheduled-but-not-yet-fired request from resurrecting a lane that's
    /// since been reset to NORMAL or torn down entirely.
    private var pendingRebuildWorkItem: DispatchWorkItem?

    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Permanently silences this watchdog. The owning `CaptureLane` calls
    /// this when it's being torn down for good (Section 8.4) — cancelling any
    /// pending backoff-delayed rebuild AND making every later entry point a
    /// no-op, so the final teardown drain passes can't re-arm anything.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        isInvalidated = true
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
        escalatedRetryWorkItem?.cancel()
        escalatedRetryWorkItem = nil
    }

    /// An external full rebuild (device switch, rate change, or entering
    /// waiting-for-device) supersedes any scheduled watchdog work. Cancels
    /// BOTH work items (the backoff-delayed rebuild AND the 60s ESCALATED
    /// retry — leaving either armed would tear down the fresh pipeline or
    /// churn guard-rejected phantom attempts) and resets the episode to
    /// NORMAL so zeros on the new pipeline re-confirm from scratch. Unlike
    /// `invalidate()`, the watchdog stays alive for the rebuilt pipeline.
    /// Cancelling a mid-flight episode without this reset would otherwise
    /// strand the state machine in `.rebuilding` forever (no
    /// `rebuildCompleted` will ever arrive for a cancelled work item, and
    /// `reportZeroRun` ignores `.rebuilding`).
    public func resetForExternalRebuild() {
        lock.lock(); defer { lock.unlock() }
        guard !isInvalidated else { return }
        reset()
    }

    /// Called by `ProcessCatalog` (relayed through the lane) every time a new
    /// 1 Hz poll snapshot is available. Section 8.1 "The corroboration signal".
    public func updateCorroboration(_ snapshot: CorroborationSnapshot) {
        lock.lock(); defer { lock.unlock() }
        guard !isInvalidated else { return }
        // The drain loop re-delivers the lane's cached 1 Hz snapshot every
        // ~50 ms cycle; Section 8.1's "3 consecutive corroborated polls"
        // means 3 GENUINE polls (~3 s of sustained corroboration), so a
        // snapshot from the same underlying poll must not count twice.
        if let last = lastCorroboration, last.polledAt == snapshot.polledAt {
            return
        }
        lastCorroboration = snapshot
        let isFresh = now().timeIntervalSince(snapshot.polledAt) <= WatchdogThresholds.snapshotFreshnessSeconds
        if !isFresh || snapshot.errored {
            consecutiveStaleOrErroredPolls += 1
            consecutiveCorroboratedPolls = 0
        } else if snapshot.audioExpected {
            consecutiveCorroboratedPolls += 1
            consecutiveStaleOrErroredPolls = 0
        } else {
            consecutiveCorroboratedPolls = 0
            consecutiveStaleOrErroredPolls = 0
        }
        evaluateSuspiciousAndVerifyTransitions()
    }

    /// Called every drain cycle (~50 ms) with the current consecutive
    /// all-zero duration. ANY nonzero sample resets to 0 and returns to
    /// NORMAL from every state, including ESCALATED (Section 8.1).
    public func reportZeroRun(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !isInvalidated else { return }
        if seconds == 0 {
            reset()
            return
        }
        if zeroRunStartedAt == nil {
            zeroRunStartedAt = now().addingTimeInterval(-seconds)
        }
        switch _state {
        case .normal:
            if seconds >= WatchdogThresholds.armSeconds {
                _state = .suspicious
                consecutiveCorroboratedPolls = 0
                consecutiveStaleOrErroredPolls = 0
            }
        case .suspicious:
            evaluateSuspiciousConfirm(zeroRunSeconds: seconds)
        case .postRebuildVerify:
            evaluatePostRebuildVerify(zeroRunSeconds: seconds)
        case .confirmedDropout, .rebuilding, .escalated:
            break // transitions driven by requestRebuild()/rebuildCompleted()
                  // and the scheduled ESCALATED retry, not zero-run polling
        }
    }

    /// Resets to NORMAL on any nonzero sample (Section 8.1). Fires the
    /// deescalate callback if this episode was EVER escalated, regardless of
    /// which state it's in right now (it may have already moved on to
    /// REBUILDING/POST_REBUILD_VERIFY via a successful retry).
    private func reset() {
        let shouldDeescalate = wasEverEscalatedThisEpisode
        // A self-resolved dropout (a nonzero sample arriving on its own)
        // must cancel any backoff-delayed rebuild already scheduled for
        // this episode — otherwise it still fires and tears down/rebuilds
        // a lane that's already healthy again.
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
        escalatedRetryWorkItem?.cancel()
        escalatedRetryWorkItem = nil
        zeroRunStartedAt = nil
        consecutiveCorroboratedPolls = 0
        consecutiveStaleOrErroredPolls = 0
        attemptTimestamps.removeAll()
        currentAttemptNumber = 0
        wasEverEscalatedThisEpisode = false
        _state = .normal
        if shouldDeescalate {
            delegate?.zeroWatchdogDidDeescalate(self)
        }
    }

    private func evaluateSuspiciousAndVerifyTransitions() {
        if _state == .suspicious, let zeroRunStartedAt {
            evaluateSuspiciousConfirm(zeroRunSeconds: now().timeIntervalSince(zeroRunStartedAt))
        } else if _state == .postRebuildVerify, let zeroRunStartedAt {
            evaluatePostRebuildVerify(zeroRunSeconds: now().timeIntervalSince(zeroRunStartedAt))
        }
    }

    private func evaluateSuspiciousConfirm(zeroRunSeconds: Double) {
        guard let corroboration = lastCorroboration else { return }
        if corroboration.audioExpected == false && (now().timeIntervalSince(corroboration.polledAt) <= WatchdogThresholds.snapshotFreshnessSeconds) {
            // "no one is playing" -> hold in SUSPICIOUS indefinitely.
            return
        }
        if zeroRunSeconds >= WatchdogThresholds.confirmSeconds
            && consecutiveCorroboratedPolls >= WatchdogThresholds.requiredConsecutiveCorroboratedPolls {
            transitionToConfirmedDropout()
            return
        }
        if consecutiveStaleOrErroredPolls >= WatchdogThresholds.requiredConsecutiveStaleOrErroredPolls
            && zeroRunSeconds >= WatchdogThresholds.uncorroboratedFallbackSeconds {
            transitionToConfirmedDropout()
        }
    }

    private func evaluatePostRebuildVerify(zeroRunSeconds: Double) {
        guard let corroboration = lastCorroboration else { return }
        if corroboration.audioExpected == false && (now().timeIntervalSince(corroboration.polledAt) <= WatchdogThresholds.snapshotFreshnessSeconds) {
            let shouldDeescalate = wasEverEscalatedThisEpisode
            wasEverEscalatedThisEpisode = false
            _state = .suspicious
            if shouldDeescalate {
                delegate?.zeroWatchdogDidDeescalate(self)
            }
            return
        }
        let secondsSinceRebuild = rebuildCompletedAt.map { now().timeIntervalSince($0) } ?? zeroRunSeconds
        if secondsSinceRebuild >= WatchdogThresholds.confirmSeconds
            && consecutiveCorroboratedPolls >= WatchdogThresholds.requiredConsecutiveCorroboratedPolls {
            attemptRebuildOrEscalate()
            return
        }
        if consecutiveStaleOrErroredPolls >= WatchdogThresholds.requiredConsecutiveStaleOrErroredPolls
            && secondsSinceRebuild >= WatchdogThresholds.uncorroboratedFallbackSeconds {
            attemptRebuildOrEscalate()
        }
    }

    private func transitionToConfirmedDropout() {
        _state = .confirmedDropout
        attemptRebuildOrEscalate()
    }

    private func attemptRebuildOrEscalate() {
        pruneAttemptWindow()
        if attemptTimestamps.count >= WatchdogThresholds.maxAttemptsPerWindow {
            enterEscalated()
            return
        }
        _state = .rebuilding
        currentAttemptNumber = attemptTimestamps.count + 1
        attemptTimestamps.append(now())
        let backoffIndex = min(currentAttemptNumber - 1, WatchdogThresholds.backoffSeconds.count - 1)
        let delay = WatchdogThresholds.backoffSeconds[backoffIndex]
        scheduleRebuildRequest(attempt: currentAttemptNumber, after: delay)
    }

    /// Schedules the backoff-delayed rebuild-request delegate call as a
    /// cancellable `DispatchWorkItem` (not a bare `asyncAfter` closure) so
    /// `reset()`/`invalidate()` can actually stop it from firing — a bare
    /// closure has no handle to cancel, which is exactly how a resolved or
    /// torn-down lane could still get resurrected by a request scheduled
    /// just before that happened.
    private func scheduleRebuildRequest(attempt: Int, after delay: Double) {
        pendingRebuildWorkItem?.cancel()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // cancel() only takes effect before the block starts running —
            // if we're racing invalidate()/reset() (or a newer scheduled
            // request) right at that edge, an identity check confirms
            // we're still the CURRENT pending item before notifying.
            guard self.pendingRebuildWorkItem === workItem else {
                self.lock.unlock()
                return
            }
            self.pendingRebuildWorkItem = nil
            self.lock.unlock()
            self.delegate?.zeroWatchdogRequestsRebuild(self, attempt: attempt)
        }
        pendingRebuildWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func pruneAttemptWindow() {
        let cutoff = now().addingTimeInterval(-WatchdogThresholds.attemptWindowSeconds)
        attemptTimestamps.removeAll { $0 < cutoff }
    }

    /// Called by `CaptureLane` once the full teardown+recreation (Section
    /// 8.2) completes, success or failure.
    public func rebuildCompleted(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !isInvalidated else { return }
        guard success else {
            pruneAttemptWindow()
            if attemptTimestamps.count >= WatchdogThresholds.maxAttemptsPerWindow {
                enterEscalated()
            } else {
                attemptRebuildOrEscalate()
            }
            return
        }
        rebuildCompletedAt = now()
        _state = .postRebuildVerify
        consecutiveCorroboratedPolls = 0
        consecutiveStaleOrErroredPolls = 0
    }

    private func enterEscalated() {
        _state = .escalated
        wasEverEscalatedThisEpisode = true
        delegate?.zeroWatchdogDidEscalate(self)
        scheduleEscalatedRetry()
    }

    /// Schedules the 60 s ESCALATED retry as its own cancellable work item
    /// (cancelled by `reset()`/`invalidate()`). `escalatedRetryFired` always
    /// leaves ESCALATED (to REBUILDING or downgraded to SUSPICIOUS), and any
    /// later re-entry into ESCALATED re-schedules, so no self-reschedule is
    /// needed here.
    private func scheduleEscalatedRetry() {
        escalatedRetryWorkItem?.cancel()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.isInvalidated, self.escalatedRetryWorkItem === workItem else {
                self.lock.unlock()
                return
            }
            self.escalatedRetryWorkItem = nil
            self.escalatedRetryFired()
            self.lock.unlock()
        }
        escalatedRetryWorkItem = workItem
        DispatchQueue.global().asyncAfter(
            deadline: .now() + WatchdogThresholds.escalatedRetrySeconds, execute: workItem
        )
    }

    /// Section 8.1 "The escalated retry decision" — exactly one of three
    /// actions at each 60 s retry point.
    private func escalatedRetryFired() {
        guard _state == .escalated else { return }
        guard let corroboration = lastCorroboration else {
            attemptRebuildOrEscalateFromEscalated()
            return
        }
        let isFresh = now().timeIntervalSince(corroboration.polledAt) <= WatchdogThresholds.snapshotFreshnessSeconds
        if !isFresh || corroboration.errored {
            attemptRebuildOrEscalateFromEscalated()
        } else if corroboration.audioExpected {
            attemptRebuildOrEscalateFromEscalated()
        } else {
            _state = .suspicious
            wasEverEscalatedThisEpisode = false
            delegate?.zeroWatchdogDidDeescalate(self)
        }
    }

    /// Section 8.1: "Escalated retries bypass the 0.5/2/5 s backoff schedule
    /// — the 60 s cadence is itself the throttle." This must NOT re-check
    /// the attempt-count gate before attempting — the 3 timestamps that
    /// caused entry into ESCALATED remain inside the 10-minute window for
    /// most of that window, so a pre-check here would silently block every
    /// retry for up to ~10 minutes. The count is still appended so that IF
    /// this attempt also fails, `rebuildCompleted(success: false)`'s own
    /// (correct) gate can decide whether to re-escalate.
    private func attemptRebuildOrEscalateFromEscalated() {
        pruneAttemptWindow()
        _state = .rebuilding
        currentAttemptNumber = attemptTimestamps.count + 1
        attemptTimestamps.append(now())
        delegate?.zeroWatchdogRequestsRebuild(self, attempt: currentAttemptNumber)
    }
}
