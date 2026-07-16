import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Owns all master-file I/O for one `CaptureLane` (Section 6.2). Audio is
/// streamed to disk as it is drained — CAF segment files in the recordings
/// folder, hidden behind a `.capture_` prefix until `CaptureEngine.stop()`
/// promotes them to their final names — so a crash never loses more than the
/// last unflushed buffer, recordings are never bounded by RAM, and a
/// mid-session sample-rate change simply rotates to a new segment file with
/// its own correct ASBD instead of corrupting a single-rate master.
///
/// The one iron rule: client and file ASBDs are byte-identical, so
/// `ExtAudioFile` never engages an `AudioConverter` — there is no code path
/// on which SRC, dither, bit-depth change, or the float→Int32 WAV truncation
/// bug can occur.
///
/// Thread contract: `write` runs on the lane's `DrainLoop` thread;
/// `openNextSegment`/`finalizeCurrentSegment` run on the engine queue. An
/// internal lock serializes them — the lane's teardown ordering (drain thread
/// stopped before finalize) means the lock is contended only in pathological
/// interleavings, but a torn `current` read must be impossible either way.
public final class SegmentWriter {
    /// A fully-written, closed segment file awaiting export/promotion.
    public struct FinishedSegment: Sendable {
        public let url: URL
        public let asbd: AudioStreamBasicDescription
        public let frames: Int64
    }

    private struct OpenSegment {
        let url: URL
        let asbd: AudioStreamBasicDescription
        let file: ExtAudioFileRef
        var framesWritten: Int64 = 0
    }

    private let directory: URL
    /// One token per writer (= per session): segment files are
    /// ".capture_<token>-<index>.caf" so concurrent sessions in the GUI and
    /// CLI can never collide, and the crash sweep can find strays by prefix.
    private let sessionToken = UUID().uuidString
    private var segmentIndex = 0

    private let lock = NSLock()
    private var current: OpenSegment?
    private var _finished: [FinishedSegment] = []
    private var lastOpenedASBD: AudioStreamBasicDescription?

    /// Prefix shared with `SessionStore.sweepPartialCaptures()`.
    public static let partialFilePrefix = ".capture_"

    /// The session-liveness lock file for a given session token — held
    /// exclusively (flock) by the owning SegmentWriter for its lifetime, so
    /// another process' launch sweep can distinguish "finalized segment of a
    /// LIVE session" (rotated part 1, or parked in waiting-for-device, both
    /// of which sit with frozen mtimes for hours) from a genuine crash
    /// leftover. flock releases automatically if the owner crashes.
    public static func sessionLockURL(directory: URL, token: String) -> URL {
        directory.appendingPathComponent("\(partialFilePrefix)\(token).live")
    }

    private var sessionLockFD: Int32 = -1
    private var sessionLockURLIfHeld: URL?

    public init(directory: URL) {
        self.directory = directory
        let lockURL = Self.sessionLockURL(directory: directory, token: sessionToken)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
            sessionLockFD = fd
            sessionLockURLIfHeld = lockURL
        } else {
            // Degrade to mtime-only sweep protection rather than failing the
            // session — the token is a fresh UUID, so contention here means
            // something exotic (e.g. an unwritable folder caught later by
            // openNextSegment).
            if fd >= 0 { close(fd) }
        }
    }

    deinit {
        // Graceful owners call releaseSessionLock() after consuming the
        // segments; this is only the safety net (fd would close with the
        // process anyway — a crash is exactly when the sweep SHOULD see the
        // lock released and rescue the files).
        if sessionLockFD >= 0 { close(sessionLockFD) }
    }

    /// Releases the session-liveness lock and removes its lock file. Called
    /// once the session's segment files have been consumed (exported,
    /// attempted, or deleted) — from that point any leftover `.capture_`
    /// file of this session is genuinely orphaned and the sweep may take it.
    public func releaseSessionLock() {
        lock.lock(); defer { lock.unlock() }
        guard sessionLockFD >= 0 else { return }
        flock(sessionLockFD, LOCK_UN)
        close(sessionLockFD)
        sessionLockFD = -1
        if let url = sessionLockURLIfHeld {
            try? FileManager.default.removeItem(at: url)
        }
        sessionLockURLIfHeld = nil
    }

    /// Segments finalized so far, in capture order. Engine queue only
    /// (after the lane has stopped, this is the complete session).
    public var finishedSegments: [FinishedSegment] {
        lock.lock(); defer { lock.unlock() }
        return _finished
    }

    /// The ASBD of the currently open segment, or — once finalized — the
    /// last segment that was open. Nil only if no segment was ever opened.
    public var asbd: AudioStreamBasicDescription? {
        lock.lock(); defer { lock.unlock() }
        return current?.asbd ?? lastOpenedASBD
    }

    public var hasOpenSegment: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
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

    /// Creates the next on-disk CAF segment. Any previously open segment must
    /// have been finalized first (the lane's rotation paths guarantee this).
    @discardableResult
    public func openNextSegment(asbd: AudioStreamBasicDescription) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let stale = current {
            // Defensive: never leak an open ExtAudioFile. Finalize in place.
            Log.error("openNextSegment called with a segment already open (\(stale.url.lastPathComponent)); finalizing it first")
            finalizeLocked()
        }
        segmentIndex += 1
        let url = directory.appendingPathComponent("\(Self.partialFilePrefix)\(sessionToken)-\(segmentIndex).caf")

        var fileASBD = asbd
        var audioFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &audioFile
        )
        guard createStatus == noErr, let file = audioFile else {
            throw CoreAudioError(status: createStatus, context: "ExtAudioFileCreateWithURL(segment)")
        }
        var clientASBD = asbd
        let setStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw CoreAudioError(status: setStatus, context: "ExtAudioFileSetProperty(ClientDataFormat)")
        }

        current = OpenSegment(url: url, asbd: asbd, file: file)
        lastOpenedASBD = asbd
        return url
    }

    /// Synchronous write of `frameCount` interleaved frames starting at
    /// `bytes` into the open segment file. DrainLoop thread.
    public func write(bytes: UnsafeRawPointer, byteCount: Int, frameCount: UInt32) throws {
        lock.lock(); defer { lock.unlock() }
        guard var segment = current else { throw SegmentWriterError.noOpenSegment }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: segment.asbd.mChannelsPerFrame,
                mDataByteSize: UInt32(byteCount),
                mData: UnsafeMutableRawPointer(mutating: bytes)
            )
        )
        let status = ExtAudioFileWrite(segment.file, frameCount, &bufferList)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "ExtAudioFileWrite(segment)")
        }
        segment.framesWritten += Int64(frameCount)
        current = segment
    }

    /// Result of `finalizeCurrentSegment()`: the frame count written, and
    /// whether a segment was actually open to finalize.
    public struct FinalizeResult {
        public let frames: Int64
        public let succeeded: Bool
    }

    /// Closes the open segment file (finalizing its CAF header) and records
    /// it in `finishedSegments`. Safe no-op when nothing is open — stop after
    /// a rotation, waiting-for-device, or a failed start all legitimately
    /// arrive here with no open segment.
    @discardableResult
    public func finalizeCurrentSegment() -> FinalizeResult {
        lock.lock(); defer { lock.unlock() }
        guard current != nil else {
            return FinalizeResult(frames: 0, succeeded: false)
        }
        let frames = finalizeLocked()
        return FinalizeResult(frames: frames, succeeded: true)
    }

    /// Removes every finished segment file from disk. Used when a session
    /// start fails (nothing worth keeping) or captured no audio at all.
    public func removeAllSegmentFiles() {
        lock.lock()
        if current != nil { finalizeLocked() }
        for segment in _finished {
            try? FileManager.default.removeItem(at: segment.url)
        }
        _finished.removeAll()
        lock.unlock()
        releaseSessionLock()
    }

    @discardableResult
    private func finalizeLocked() -> Int64 {
        guard let segment = current else { return 0 }
        ExtAudioFileDispose(segment.file)
        _finished.append(FinishedSegment(url: segment.url, asbd: segment.asbd, frames: segment.framesWritten))
        current = nil
        return segment.framesWritten
    }

    /// Section 6.2's mandatory bit-exact write/read-back self-check. Called
    /// at launch by both entry points: the CLI's `record` verb refuses to
    /// record on failure; the GUI warns with a critical alert. Also covered
    /// by `SegmentWriterTests`.
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
