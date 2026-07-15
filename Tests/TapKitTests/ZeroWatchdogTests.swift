import XCTest
@testable import TapKit

final class ZeroWatchdogTests: XCTestCase {
    private final class FakeClock {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { current }
        func advance(_ seconds: Double) { current = current.addingTimeInterval(seconds) }
    }

    private final class RecordingDelegate: ZeroWatchdogDelegate {
        var rebuildRequests = 0
        var escalations = 0
        var deescalations = 0

        func zeroWatchdogRequestsRebuild(_ watchdog: ZeroWatchdog, attempt: Int) { rebuildRequests += 1 }
        func zeroWatchdogDidEscalate(_ watchdog: ZeroWatchdog) { escalations += 1 }
        func zeroWatchdogDidDeescalate(_ watchdog: ZeroWatchdog) { deescalations += 1 }
    }

    /// Section 8.1's core safety property: genuine silence, however long,
    /// must never trigger a rebuild.
    func testTwoHoursOfGenuineSilenceNeverTriggersRebuild() {
        let clock = FakeClock()
        let watchdog = ZeroWatchdog(now: clock.now)
        let delegate = RecordingDelegate()
        watchdog.delegate = delegate

        let cycleSeconds = 0.05
        let totalSeconds = 2 * 60 * 60.0
        var zeroRun = 0.0
        var cyclesUntilPoll = 0.0
        var elapsed = 0.0
        while elapsed < totalSeconds {
            zeroRun += cycleSeconds
            watchdog.reportZeroRun(seconds: zeroRun)
            cyclesUntilPoll += cycleSeconds
            if cyclesUntilPoll >= 1.0 {
                watchdog.updateCorroboration(CorroborationSnapshot(audioExpected: false, polledAt: clock.now()))
                cyclesUntilPoll = 0
            }
            clock.advance(cycleSeconds)
            elapsed += cycleSeconds
        }

        XCTAssertEqual(delegate.rebuildRequests, 0)
        XCTAssertEqual(delegate.escalations, 0)
        XCTAssertEqual(watchdog.state, .suspicious)
    }

    func testCorroboratedDropoutConfirmsAndRequestsRebuild() {
        let clock = FakeClock()
        let watchdog = ZeroWatchdog(now: clock.now)
        let delegate = RecordingDelegate()
        watchdog.delegate = delegate

        var zeroRun = 0.0
        let cycleSeconds = 0.05
        for _ in 0..<Int(12.0 / cycleSeconds) {
            zeroRun += cycleSeconds
            watchdog.reportZeroRun(seconds: zeroRun)
            clock.advance(cycleSeconds)
        }
        XCTAssertEqual(watchdog.state, .suspicious)

        for _ in 0..<4 {
            watchdog.updateCorroboration(CorroborationSnapshot(audioExpected: true, polledAt: clock.now()))
            clock.advance(1.0)
            zeroRun += 1.0
            watchdog.reportZeroRun(seconds: zeroRun)
        }
        XCTAssertEqual(watchdog.state, .rebuilding)

        // The rebuild request itself fires from a real `DispatchQueue.global()
        // .asyncAfter` backoff timer (0.5s for the first attempt) — racing
        // that against a second, independently-scheduled real timer at a
        // fixed offset (the previous approach here) is flaky under load: GCD
        // timer latency easily eats a 200ms margin. Polling the actual
        // condition via NSPredicate removes the race entirely — it succeeds
        // the moment the callback lands, whenever that is, up to the timeout.
        let predicate = NSPredicate { _, _ in delegate.rebuildRequests >= 1 }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: NSObject())
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(delegate.rebuildRequests, 1)
    }

    func testAnyNonzeroSampleResetsToNormalFromAnyState() {
        let watchdog = ZeroWatchdog()
        watchdog.reportZeroRun(seconds: 6.0)
        XCTAssertEqual(watchdog.state, .suspicious)
        watchdog.reportZeroRun(seconds: 0.0)
        XCTAssertEqual(watchdog.state, .normal)

        // The name promises "from any state" — the assertions above only
        // ever exercised the reset from SUSPICIOUS. Section 8.1: "any
        // nonzero sample resets to NORMAL from every state, including
        // ESCALATED." Drive all the way to ESCALATED (confirmed dropout,
        // then 3 failed rebuild attempts exhausting the attempt budget) and
        // verify a nonzero sample resets from there too, firing the
        // deescalate callback.
        let delegate = RecordingDelegate()
        watchdog.delegate = delegate

        var zeroRun = 0.0
        let cycleSeconds = 0.05
        for _ in 0..<Int(12.0 / cycleSeconds) {
            zeroRun += cycleSeconds
            watchdog.reportZeroRun(seconds: zeroRun)
        }
        XCTAssertEqual(watchdog.state, .suspicious)

        for _ in 0..<4 {
            watchdog.updateCorroboration(CorroborationSnapshot(audioExpected: true, polledAt: Date()))
            zeroRun += 1.0
            watchdog.reportZeroRun(seconds: zeroRun)
        }
        XCTAssertEqual(watchdog.state, .rebuilding)

        // Exhaust the 3-attempt budget: the first attempt is already in
        // flight above, so 2 more failures reach the limit and the 3rd
        // failure (having pruned back to exactly 3 timestamps) escalates.
        watchdog.rebuildCompleted(success: false)
        XCTAssertEqual(watchdog.state, .rebuilding)
        watchdog.rebuildCompleted(success: false)
        XCTAssertEqual(watchdog.state, .rebuilding)
        watchdog.rebuildCompleted(success: false)
        XCTAssertEqual(watchdog.state, .escalated)
        XCTAssertEqual(delegate.escalations, 1)

        watchdog.reportZeroRun(seconds: 0.0)
        XCTAssertEqual(watchdog.state, .normal)
        XCTAssertEqual(delegate.deescalations, 1)
    }
}
