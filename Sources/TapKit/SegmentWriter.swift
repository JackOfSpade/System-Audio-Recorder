import AudioToolbox
import CoreAudio
import Foundation

/// Owns all master-file I/O for one `CaptureLane` (Section 6.2). Runs
/// exclusively on that lane's `DrainLoop` thread — never on the real-time
/// IOProc thread. The one iron rule: client and file ASBDs are byte-identical,
/// so `ExtAudioFile` never engages an `AudioConverter` — there is no code path
/// on which SRC, dither, bit-depth change, or the float→Int32 WAV truncation
/// bug can occur.
public final class SegmentWriter {
    public struct OpenSegment {
        public let url: URL
        public let index: Int
        public let asbd: AudioStreamBasicDescription
        public var framesWritten: Int64 = 0
        fileprivate var file: ExtAudioFileRef
    }

    private let laneDirectory: URL
    private var nextIndex: Int = 1
    private(set) public var current: OpenSegment?

    public init(laneDirectory: URL) {
        self.laneDirectory = laneDirectory
    }

    /// Builds the canonical ASBD (Section 6.2 table): Float32, interleaved,
    /// packed, native-endian, at the given rate/channel count.
    public static func canonicalASBD(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerFrame = 4 * channels
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Opens `segment-<NNN>.caf` (zero-padded to 3 digits, 1-based,
    /// monotonically increasing per lane — Section 6.3) with the given ASBD
    /// used for BOTH the file and client format.
    @discardableResult
    public func openNextSegment(asbd: AudioStreamBasicDescription) throws -> OpenSegment {
        try FileManager.default.createDirectory(at: laneDirectory, withIntermediateDirectories: true)
        let filename = String(format: "segment-%03d.caf", nextIndex)
        let url = laneDirectory.appendingPathComponent(filename)

        var fileASBD = asbd
        var audioFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &audioFile
        )
        guard createStatus == noErr, let file = audioFile else {
            throw CoreAudioError(status: createStatus, context: "ExtAudioFileCreateWithURL")
        }

        var clientASBD = asbd
        let setStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(file)
            throw CoreAudioError(status: setStatus, context: "ExtAudioFileSetProperty(ClientDataFormat)")
        }

        let segment = OpenSegment(url: url, index: nextIndex, asbd: asbd, framesWritten: 0, file: file)
        nextIndex += 1
        current = segment
        return segment
    }

    /// Synchronous write of `frameCount` interleaved frames starting at
    /// `bytes` (Section 5.4 step 6 / Section 6.2 "Write behavior").
    public func write(bytes: UnsafeRawPointer, byteCount: Int, frameCount: UInt32, channels: UInt32) throws {
        guard var segment = current else { throw SegmentWriterError.noOpenSegment }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(byteCount), mData: UnsafeMutableRawPointer(mutating: bytes))
        )
        let status = ExtAudioFileWrite(segment.file, frameCount, &bufferList)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "ExtAudioFileWrite")
        }
        segment.framesWritten += Int64(frameCount)
        current = segment
    }

    /// Result of `finalizeCurrentSegment()`: the frame count written, and
    /// whether `ExtAudioFileDispose` actually succeeded in patching the
    /// file's data-chunk size and frame count. `succeeded == false` means the
    /// on-disk CAF header may still be in its unfinalized (zero/placeholder)
    /// state — the caller must NOT mark the manifest segment `finalized:
    /// true` in that case, or the crash-recovery scan (Section 6.5) will skip
    /// a segment that actually still needs `CAFRecovery.patchUnfinalizedSegment`.
    public struct FinalizeResult {
        public let frames: Int64
        public let succeeded: Bool
    }

    /// Finalization (Section 6.2): flush + `ExtAudioFileDispose` (which
    /// patches the real data-chunk size and frame count), returning the final
    /// frame count for the caller to record in the manifest.
    @discardableResult
    public func finalizeCurrentSegment() -> FinalizeResult {
        guard let segment = current else {
            FileHandle.standardError.write("TapDeck: finalizeCurrentSegment called with no open segment\n".data(using: .utf8)!)
            return FinalizeResult(frames: 0, succeeded: false)
        }
        let status = ExtAudioFileDispose(segment.file)
        let frames = segment.framesWritten
        current = nil
        if status != noErr {
            FileHandle.standardError.write("TapDeck: ExtAudioFileDispose failed with status \(status)\n".data(using: .utf8)!)
            return FinalizeResult(frames: frames, succeeded: false)
        }
        return FinalizeResult(frames: frames, succeeded: true)
    }

    /// Section 6.2's mandatory bit-exact write/read-back self-check. Runs at
    /// every launch (app and CLI), in all builds. Returns true if the file
    /// layer round-trips bit-exactly; false is a fatal configuration
    /// regression the caller must refuse to record on.
    public static func runBitExactSelfCheck(scratchDirectory: URL) -> Bool {
        let sampleRate: Float64 = 48000
        let channels: UInt32 = 2
        let asbd = canonicalASBD(sampleRate: sampleRate, channels: channels)
        let frameCount = 48000 // 1 second
        var pattern = [Float32](repeating: 0, count: frameCount * Int(channels))
        for i in 0..<pattern.count {
            switch i % 6 {
            case 0: pattern[i] = Float32(i) / 1000.0
            case 1: pattern[i] = -Float32(i) / 1000.0
            case 2: pattern[i] = 0.0
            case 3: pattern[i] = -0.0
            case 4: pattern[i] = 1.5 // legally exceeds full scale
            default: pattern[i] = -1.5
            }
        }

        let url = scratchDirectory.appendingPathComponent("tapdeck_selfcheck_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        var fileASBD = asbd
        var audioFile: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &audioFile) == noErr,
              let file = audioFile else { return false }

        var clientASBD = asbd
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD) == noErr else {
            ExtAudioFileDispose(file)
            return false
        }

        let writeOK: Bool = pattern.withUnsafeMutableBytes { raw -> Bool in
            var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileWrite(file, UInt32(frameCount), &bl) == noErr
        }
        ExtAudioFileDispose(file)
        guard writeOK else { return false }

        var readFile: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &readFile) == noErr, let rf = readFile else { return false }
        guard ExtAudioFileSetProperty(rf, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD) == noErr else {
            ExtAudioFileDispose(rf)
            return false
        }

        // ExtAudioFileRead may return fewer frames than requested in a single
        // call (it is not guaranteed to fill the buffer, unlike write) — loop
        // until every frame is read or the file is exhausted/errors.
        var readback = [Float32](repeating: -999, count: pattern.count)
        var framesReadTotal = 0
        var readOK = true
        readLoop: while framesReadTotal < frameCount {
            let framesRemaining = frameCount - framesReadTotal
            var framesThisCall = UInt32(framesRemaining)
            let byteOffset = framesReadTotal * Int(channels) * 4
            let status: OSStatus = readback.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: framesThisCall * channels * 4,
                        mData: raw.baseAddress!.advanced(by: byteOffset)
                    )
                )
                return ExtAudioFileRead(rf, &framesThisCall, &bl)
            }
            guard status == noErr else { readOK = false; break readLoop }
            if framesThisCall == 0 { break readLoop } // EOF
            framesReadTotal += Int(framesThisCall)
        }
        ExtAudioFileDispose(rf)
        guard readOK, framesReadTotal == frameCount else { return false }

        return readback.withUnsafeBytes { rb in
            pattern.withUnsafeBytes { pb in
                memcmp(rb.baseAddress, pb.baseAddress, pb.count) == 0
            }
        }
    }
}

public enum SegmentWriterError: Error {
    case noOpenSegment
}
