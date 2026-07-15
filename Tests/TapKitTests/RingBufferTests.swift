import XCTest
import TapDeckRT

/// Swift-side coverage of the `TapDeckRT` C ring buffer, complementing the
/// pure-C smoke test in Tests/CRingTests (which exercises the same API
/// without the Swift/C interop layer in between).
final class RingBufferTests: XCTestCase {
    func testWraparoundIsByteExact() {
        let bytesPerFrame: UInt32 = 8 // stereo Float32
        guard let ring = td_ring_create(64) else { return XCTFail("allocation failed") }
        defer { td_ring_destroy(ring) }
        XCTAssertEqual(td_ring_capacity(ring), 64)

        // 16 evenly divides the ring's 64-byte capacity, so a chunk size of
        // 16 (the previous choice) always lands back on a multiple of 16 —
        // 0, 16, 32, 48, 0, ... — never straddling the buffer's physical
        // end, so every write took the single-memcpy path and the
        // two-memcpy wraparound logic this test claims to cover was never
        // actually exercised. 24 is NOT a divisor of 64 (still a multiple
        // of bytesPerFrame, satisfying td_ring_write's whole-frame
        // contract), so the write position cycles through 0, 24, 48, 8,
        // 32, 56, 16, 40 before repeating — guaranteed to straddle the end
        // at pos 48 and 56.
        let chunkBytes = 24
        var sawWraparound = false
        let capacity = Int(td_ring_capacity(ring))

        for iter in 0..<20 {
            var src = [UInt8](repeating: 0, count: chunkBytes)
            for i in 0..<chunkBytes { src[i] = UInt8((iter * chunkBytes + i) % 256) }
            let wrote = src.withUnsafeBytes { td_ring_write(ring, $0.baseAddress, chunkBytes, bytesPerFrame) }
            XCTAssertTrue(wrote)

            var dst = [UInt8](repeating: 0, count: chunkBytes)
            let read = dst.withUnsafeMutableBytes { td_ring_read(ring, $0.baseAddress, chunkBytes, bytesPerFrame) }
            XCTAssertEqual(read, chunkBytes)
            XCTAssertEqual(dst, src, "wraparound iteration \(iter) must be byte-exact")

            let writePos = (iter * chunkBytes) % capacity
            if writePos + chunkBytes > capacity { sawWraparound = true }
        }

        XCTAssertTrue(sawWraparound, "test setup must actually exercise the two-memcpy wraparound path at least once, or this test isn't testing what its name claims")
    }

    func testOverflowDropsWholeChunkAndCountsIt() {
        let bytesPerFrame: UInt32 = 8
        guard let ring = td_ring_create(32) else { return XCTFail("allocation failed") }
        defer { td_ring_destroy(ring) }

        let big = [UInt8](repeating: 0xAA, count: 40)
        let filled = big.withUnsafeBytes { td_ring_write(ring, $0.baseAddress, 32, bytesPerFrame) }
        XCTAssertTrue(filled)

        let before = td_ring_available_frames(ring, bytesPerFrame)
        let overflowed = big.withUnsafeBytes { td_ring_write(ring, $0.baseAddress, 8, bytesPerFrame) }
        XCTAssertFalse(overflowed)
        XCTAssertEqual(td_ring_available_frames(ring, bytesPerFrame), before, "a dropped write must not partially land")

        var droppedChunks: UInt64 = 0
        var droppedFrames: UInt64 = 0
        td_ring_take_dropped_deltas(ring, &droppedChunks, &droppedFrames)
        XCTAssertEqual(droppedChunks, 1)
        XCTAssertEqual(droppedFrames, 1)
    }

    func testContextTimestampLatchAndRollingSemantics() {
        let bytesPerFrame: UInt32 = 8
        guard let ring = td_ring_create(1024) else { return XCTFail("allocation failed") }
        defer { td_ring_destroy(ring) }
        guard let ctx = td_context_create(ring, bytesPerFrame) else { return XCTFail("allocation failed") }
        defer { td_context_destroy(ctx) }
        td_context_arm_first_host_time(ctx)

        let frame: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        frame.withUnsafeBytes { td_context_on_io(ctx, $0.baseAddress, 8, 1000, 1) }
        frame.withUnsafeBytes { td_context_on_io(ctx, $0.baseAddress, 8, 1512, 1) }

        var ts = td_timestamps_t()
        td_context_read_timestamps(ctx, &ts)
        XCTAssertTrue(ts.first_host_time_set)
        XCTAssertEqual(ts.first_host_time, 1000, "first_host_time latches on the FIRST callback only")
        XCTAssertEqual(ts.last_host_time, 1512, "last_host_time updates every callback")
        XCTAssertEqual(ts.total_frames_captured, 2)
    }
}
