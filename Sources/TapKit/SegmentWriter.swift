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
    }

    private(set) public var current: OpenSegment?
    public private(set) var data = Data()

    /// The ASBD of the currently open segment, or nil if no segment is open.
    public var asbd: AudioStreamBasicDescription? {
        current?.asbd
    }

    public init() {
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

    /// Prepares the in-memory buffer.
    @discardableResult
    public func openNextSegment(asbd: AudioStreamBasicDescription) throws -> OpenSegment {
        let url = URL(fileURLWithPath: "/dummy/segment.caf")
        let segment = OpenSegment(url: url, index: 1, asbd: asbd, framesWritten: 0)
        current = segment
        data = Data()
        return segment
    }

    /// Synchronous write of `frameCount` interleaved frames starting at `bytes`
    /// into the in-memory buffer.
    public func write(bytes: UnsafeRawPointer, byteCount: Int, frameCount: UInt32, channels: UInt32) throws {
        guard var segment = current else { throw SegmentWriterError.noOpenSegment }
        data.append(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: byteCount))
        segment.framesWritten += Int64(frameCount)
        current = segment
    }

    /// Result of `finalizeCurrentSegment()`: the frame count written, and
    /// whether finalization succeeded.
    public struct FinalizeResult {
        public let frames: Int64
        public let succeeded: Bool
    }

    /// Finalization: returns the final frame count.
    @discardableResult
    public func finalizeCurrentSegment() -> FinalizeResult {
        guard let segment = current else {
            FileHandle.standardError.write("System Audio Recorder: finalizeCurrentSegment called with no open segment\n".data(using: .utf8)!)
            return FinalizeResult(frames: 0, succeeded: false)
        }
        let frames = segment.framesWritten
        current = nil
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

        let url = scratchDirectory.appendingPathComponent("systemaudiorecorder_selfcheck_\(UUID().uuidString).caf")
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
