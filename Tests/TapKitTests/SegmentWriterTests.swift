import XCTest
@testable import TapKit

final class SegmentWriterTests: XCTestCase {
    /// Section 6.2's mandatory bit-exact write/read-back self-check.
    func testBitExactSelfCheckPasses() {
        let ok = SegmentWriter.runBitExactSelfCheck(scratchDirectory: FileManager.default.temporaryDirectory)
        XCTAssertTrue(ok, "SegmentWriter must round-trip Float32 samples bit-exactly, including >1.0 and -0.0")
    }
}
