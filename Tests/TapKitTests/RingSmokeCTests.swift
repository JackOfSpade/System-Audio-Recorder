import XCTest
import CRingSmokeTest

/// Runs the pure-C ring buffer smoke test (Tests/CRingTests/ring_smoke_test.c)
/// as part of the normal test suite. That file exercises SystemAudioRecorderRT's C API
/// directly, with no Swift/C interop layer in between, complementing
/// RingBufferTests.swift's coverage of the same cases through Swift.
final class RingSmokeCTests: XCTestCase {
    func testPureCRingSmokeTestPasses() {
        XCTAssertEqual(td_ring_smoke_test_run(), 0, "pure-C ring smoke test reported failing checks — see stderr output above")
    }
}
