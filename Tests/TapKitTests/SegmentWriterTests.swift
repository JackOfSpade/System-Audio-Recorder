import AudioToolbox
import XCTest
@testable import TapKit

final class SegmentWriterTests: XCTestCase {
    private var scratchDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentWriterTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    /// Section 6.2's mandatory bit-exact write/read-back self-check.
    func testBitExactSelfCheckPasses() {
        let ok = SegmentWriter.runBitExactSelfCheck(scratchDirectory: FileManager.default.temporaryDirectory)
        XCTAssertTrue(ok, "SegmentWriter must round-trip Float32 samples bit-exactly, including >1.0 and -0.0")
    }

    /// The streaming path: open → write in chunks → finalize must produce an
    /// on-disk CAF whose samples read back bit-exactly.
    func testStreamingWriteRoundTripsBitExactly() throws {
        let channels: UInt32 = 2
        let asbd = SegmentWriter.canonicalASBD(sampleRate: 48000, channels: channels)
        let writer = SegmentWriter(directory: scratchDir)
        try writer.openNextSegment(asbd: asbd)

        let frameCount = 4096
        var pattern = [Float32](repeating: 0, count: frameCount * Int(channels))
        for i in 0..<pattern.count {
            pattern[i] = Float32(i % 977) / 488.5 - 1.0
        }
        // Two unequal chunks — the writer must append, not overwrite.
        let splitFrame = 1500
        try pattern.withUnsafeBytes { raw in
            let splitByte = splitFrame * Int(channels) * 4
            try writer.write(bytes: raw.baseAddress!, byteCount: splitByte, frameCount: UInt32(splitFrame))
            try writer.write(
                bytes: raw.baseAddress!.advanced(by: splitByte),
                byteCount: raw.count - splitByte,
                frameCount: UInt32(frameCount - splitFrame)
            )
        }
        let result = writer.finalizeCurrentSegment()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.frames, Int64(frameCount))

        let segments = writer.finishedSegments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].frames, Int64(frameCount))
        XCTAssertTrue(segments[0].url.lastPathComponent.hasPrefix(SegmentWriter.partialFilePrefix))

        let readback = try Self.readAllFrames(url: segments[0].url, asbd: asbd)
        XCTAssertEqual(readback.count, pattern.count)
        XCTAssertEqual(memcmp(readback, pattern, pattern.count * 4), 0, "streamed CAF must be bit-exact")
    }

    /// A mid-session sample-rate change rotates to a NEW segment file with
    /// its own ASBD — never mixed-rate PCM inside one file (the bug class
    /// this design exists to prevent).
    func testRotationProducesPerRateSegments() throws {
        let writer = SegmentWriter(directory: scratchDir)
        let asbd44 = SegmentWriter.canonicalASBD(sampleRate: 44100, channels: 2)
        let asbd48 = SegmentWriter.canonicalASBD(sampleRate: 48000, channels: 2)

        var chunk = [Float32](repeating: 0.25, count: 512 * 2)

        try writer.openNextSegment(asbd: asbd44)
        try chunk.withUnsafeBytes { raw in
            try writer.write(bytes: raw.baseAddress!, byteCount: raw.count, frameCount: 512)
        }
        writer.finalizeCurrentSegment()

        try writer.openNextSegment(asbd: asbd48)
        chunk = [Float32](repeating: -0.5, count: 256 * 2)
        try chunk.withUnsafeBytes { raw in
            try writer.write(bytes: raw.baseAddress!, byteCount: raw.count, frameCount: 256)
        }
        writer.finalizeCurrentSegment()

        let segments = writer.finishedSegments
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].asbd.mSampleRate, 44100)
        XCTAssertEqual(segments[0].frames, 512)
        XCTAssertEqual(segments[1].asbd.mSampleRate, 48000)
        XCTAssertEqual(segments[1].frames, 256)
        XCTAssertNotEqual(segments[0].url, segments[1].url)

        // The files themselves must carry their own rate.
        XCTAssertEqual(try Self.fileSampleRate(url: segments[0].url), 44100)
        XCTAssertEqual(try Self.fileSampleRate(url: segments[1].url), 48000)
    }

    /// Crash recovery: a CAF whose `data` chunk still has the unfinalized -1
    /// size (plus a torn, mid-frame tail) must be patched back to a valid,
    /// fully readable file with whole frames only.
    func testCAFRecoveryPatchesUnfinalizedFile() throws {
        let channels: UInt32 = 2
        let asbd = SegmentWriter.canonicalASBD(sampleRate: 48000, channels: channels)
        let writer = SegmentWriter(directory: scratchDir)
        try writer.openNextSegment(asbd: asbd)
        let frameCount = 1000
        let pattern = [Float32](repeating: 0.125, count: frameCount * Int(channels))
        try pattern.withUnsafeBytes { raw in
            try writer.write(bytes: raw.baseAddress!, byteCount: raw.count, frameCount: UInt32(frameCount))
        }
        writer.finalizeCurrentSegment()
        let url = writer.finishedSegments[0].url

        // Simulate the crash: mark the data chunk unfinalized (-1 size) and
        // append 5 stray bytes (a torn, mid-frame final write).
        let dataChunkOffset = try Self.findChunkOffset(fourCC: "data", url: url)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: dataChunkOffset + 4)
        var minusOne = Int64(-1).bigEndian
        try handle.write(contentsOf: Data(bytes: &minusOne, count: 8))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4, 5]))
        try handle.close()

        // Channel count is recovered from the file's own desc chunk.
        let frames = CAFRecovery.patchUnfinalizedSegment(at: url)
        XCTAssertEqual(frames, frameCount, "recovery must restore exactly the whole frames written")

        let readback = try Self.readAllFrames(url: url, asbd: asbd)
        XCTAssertEqual(readback.count, pattern.count)
        XCTAssertEqual(memcmp(readback, pattern, pattern.count * 4), 0, "recovered CAF must be bit-exact")
    }

    // MARK: helpers

    private static func readAllFrames(url: URL, asbd: AudioStreamBasicDescription) throws -> [Float32] {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let f = file else {
            throw NSError(domain: "test", code: 1)
        }
        defer { ExtAudioFileDispose(f) }
        var clientASBD = asbd
        guard ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD) == noErr else {
            throw NSError(domain: "test", code: 2)
        }
        let channels = Int(asbd.mChannelsPerFrame)
        var all: [Float32] = []
        var buf = [Float32](repeating: 0, count: 4096 * channels)
        while true {
            var frames = UInt32(4096)
            let status = buf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress
                    )
                )
                return ExtAudioFileRead(f, &frames, &bl)
            }
            guard status == noErr else { throw NSError(domain: "test", code: Int(status)) }
            if frames == 0 { break }
            all.append(contentsOf: buf[0..<(Int(frames) * channels)])
        }
        return all
    }

    private static func fileSampleRate(url: URL) throws -> Float64 {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let f = file else {
            throw NSError(domain: "test", code: 1)
        }
        defer { ExtAudioFileDispose(f) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &size, &asbd) == noErr else {
            throw NSError(domain: "test", code: 3)
        }
        return asbd.mSampleRate
    }

    /// Walks the CAF chunk list and returns the byte offset of the chunk
    /// header whose type is `fourCC`.
    private static func findChunkOffset(fourCC: String, url: URL) throws -> UInt64 {
        let data = try Data(contentsOf: url)
        var offset = 8
        while offset + 12 <= data.count {
            let header = [UInt8](data[offset..<(offset + 12)])
            let type = String(decoding: header[0..<4], as: UTF8.self)
            if type == fourCC { return UInt64(offset) }
            let chunkSize = header.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 4, as: Int64.self).bigEndian
            }
            guard chunkSize >= 0 else { break }
            offset += 12 + Int(chunkSize)
        }
        throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "chunk \(fourCC) not found"])
    }
}
