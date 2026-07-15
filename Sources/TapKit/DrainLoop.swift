import Accelerate
import TapDeckRT
import Foundation

/// Per-channel peak+RMS meters plus clip/zero-run state, published to the UI
/// at 20 Hz via an atomic snapshot (Section 5.4 step 8).
public struct MeterSnapshot: Sendable {
    public var peakByChannel: [Float]
    public var rmsByChannel: [Float]
    public var clipped: Bool
    public var zeroRunSeconds: Double
    public var droppedChunksTotal: UInt64
    public var droppedFramesTotal: UInt64
    public var framePosition: Int64

    public static let empty = MeterSnapshot(
        peakByChannel: [], rmsByChannel: [], clipped: false,
        zeroRunSeconds: 0, droppedChunksTotal: 0, droppedFramesTotal: 0, framePosition: 0
    )
}

/// A tear-free single-slot publisher for `MeterSnapshot`, guarded by a
/// seqlock-style version counter (mirrors the C ring's approach, Section
/// 5.4 step 8). The DrainLoop thread is the sole writer; any thread may read.
public final class MeterSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MeterSnapshot = .empty

    public func publish(_ snapshot: MeterSnapshot) {
        lock.lock(); value = snapshot; lock.unlock()
    }

    public func read() -> MeterSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Callback surface the DrainLoop reports to. All calls happen ON the drain
/// thread (Section 8.1 — ZeroWatchdog's state machine runs on this thread).
public protocol DrainLoopDelegate: AnyObject {
    /// Called every cycle with the exact-zero run duration computed so far
    /// and whether the ring produced any bytes this cycle (liveness).
    func drainLoop(_ loop: DrainLoop, zeroRunSeconds: Double)
    /// Called when the dropped-chunk/dropped-frame counters advance.
    func drainLoop(_ loop: DrainLoop, overrunDroppedChunks: UInt64, droppedFrames: UInt64)
}

/// One dedicated `Thread` per lane (QoS `.userInitiated`), polling the ring on
/// a 50 ms cycle (Section 4.2 / Section 5.4). Owns the lane's `SegmentWriter`
/// and publishes the meter snapshot the UI polls at 20 Hz.
public final class DrainLoop {
    public let meterBox = MeterSnapshotBox()
    public weak var delegate: DrainLoopDelegate?

    private let ring: OpaquePointer
    private let context: OpaquePointer
    private let bytesPerFrame: UInt32
    private let channels: Int
    private let sampleRate: Float64
    private let segmentWriter: SegmentWriter
    private let planar: Bool
    /// Frames delivered per IOProc callback (Section 5.3) — the fixed value
    /// the aggregate device's `kAudioDevicePropertyBufferFrameSize` was set
    /// to. For planar taps, the ring holds a concatenation of independent
    /// per-callback plane-major blocks, each exactly this many frames; a
    /// drain read must be truncated to a whole number of these blocks or
    /// there is no way to know where one callback's planes end and the
    /// next begins (Section 5.4 step 2).
    private let framesPerCallback: UInt32
    private let callbackChunkBytes: Int

    private var thread: Thread?
    private let stopFlag = AtomicBool()
    private var zeroRunFrames: Int64 = 0
    private var framePosition: Int64 = 0

    private var scratch: [UInt8]
    private var interleaveScratch: [UInt8]

    public init(
        ring: OpaquePointer,
        context: OpaquePointer,
        bytesPerFrame: UInt32,
        channels: Int,
        sampleRate: Float64,
        planar: Bool,
        segmentWriter: SegmentWriter,
        framesPerCallback: UInt32
    ) {
        self.ring = ring
        self.context = context
        self.bytesPerFrame = bytesPerFrame
        self.channels = channels
        self.sampleRate = sampleRate
        self.planar = planar
        self.segmentWriter = segmentWriter
        self.framesPerCallback = framesPerCallback
        self.callbackChunkBytes = Int(framesPerCallback) * Int(bytesPerFrame)
        // 1 second scratch cap, per Section 5.4 step 2.
        let oneSecondBytes = Int(sampleRate) * Int(bytesPerFrame)
        self.scratch = [UInt8](repeating: 0, count: max(oneSecondBytes, Int(bytesPerFrame)))
        self.interleaveScratch = [UInt8](repeating: 0, count: max(oneSecondBytes, Int(bytesPerFrame)))
    }

    public func start() {
        let t = Thread { [weak self] in self?.runLoop() }
        t.qualityOfService = .userInitiated
        t.name = "com.tapdeck.drainloop"
        thread = t
        t.start()
    }

    /// Section 5.1: "asked to finish (drain-fully, then exit) when the lane
    /// enters STOPPING". Blocks until the drain thread has emptied the ring.
    public func stopAndDrainFully() {
        stopFlag.set(true)
        // The loop itself performs the final drain pass before exiting; give
        // it a moment. Callers on the engine queue should treat this as
        // fire-and-forget-with-join semantics via a completion callback in a
        // fuller implementation; here we busy-wait briefly as a simple join.
        while thread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func runLoop() {
        while true {
            let stopping = stopFlag.get()
            let bytesRead = drainOnce()
            if stopping {
                // "Drain-fully" (Section 5.1) means emptying the ring, not
                // just one more bounded pass — the ring can hold several
                // seconds of backlog, far more than one `drainOnce()` call's
                // 1-second cap. Keep draining back-to-back (no 50ms sleep)
                // until a pass comes back empty.
                if bytesRead == 0 {
                    break
                }
                continue
            }
            Thread.sleep(forTimeInterval: 0.05) // 50 ms cycle
        }
    }

    /// Section 5.4, steps 1–8, in order. Returns the number of bytes
    /// actually drained this cycle (0 if the ring had nothing available),
    /// so `runLoop` can tell a genuinely empty ring apart from "there's
    /// still more to drain."
    @discardableResult
    private func drainOnce() -> Int {
        // Step 1+2: chunked copy-out, at most 1s of frames per chunk. For
        // planar taps the ring holds a concatenation of independent
        // per-callback plane-major blocks (Section 5.3), each exactly
        // `framesPerCallback` frames — the copy-out must be truncated to a
        // whole number of those blocks so a read never lands mid-block.
        let maxBytes = planar
            ? (scratch.count / callbackChunkBytes) * callbackChunkBytes
            : scratch.count
        guard maxBytes > 0 else {
            reportDroppedDeltas()
            return 0
        }
        let bytesRead = scratch.withUnsafeMutableBytes { raw -> Int in
            td_ring_read(ring, raw.baseAddress, maxBytes, bytesPerFrame)
        }
        guard bytesRead > 0 else {
            // Nothing to drain this cycle; still report zero-run continuity
            // and dropped-counter deltas so the watchdog/overrun policy stays
            // live even during genuine silence.
            reportDroppedDeltas()
            return 0
        }
        let frameCount = bytesRead / Int(bytesPerFrame)

        // Step 3: exact-zero scan (vDSP max-magnitude over the whole chunk;
        // layout-agnostic — every float is zero or it isn't, regardless of
        // plane-major vs interleaved ordering).
        let isAllZero = scratch.withUnsafeBytes { raw -> Bool in
            let floatCount = bytesRead / 4
            let floatPtr = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            var maxMagnitude: Float = 0
            vDSP_maxmgv(floatPtr, 1, &maxMagnitude, vDSP_Length(floatCount))
            return maxMagnitude == 0.0
        }
        if isAllZero {
            zeroRunFrames += Int64(frameCount)
        } else {
            zeroRunFrames = 0
        }
        let zeroRunSeconds = Double(zeroRunFrames) / sampleRate
        delegate?.drainLoop(self, zeroRunSeconds: zeroRunSeconds)

        // Step 5: interleave if needed (planar tap formats only) — one
        // callback-chunk at a time, matching the producer's actual layout
        // (a sequence of complete per-callback plane-major blocks), NOT one
        // giant plane-major block spanning the whole read.
        if planar {
            scratch.withUnsafeBytes { source in
                interleaveScratch.withUnsafeMutableBytes { dest in
                    var offset = 0
                    while offset < bytesRead {
                        deinterleaveChunk(
                            source: source.baseAddress!.advanced(by: offset),
                            dest: dest.baseAddress!.advanced(by: offset)
                        )
                        offset += callbackChunkBytes
                    }
                }
            }
        }

        // Step 4: per-channel peak + RMS meters. For planar taps this MUST
        // read from the already-interleaved `interleaveScratch` (populated
        // just above) — an interleaved-stride scan over the raw plane-major
        // ring bytes would read across channel-plane boundaries.
        let (peaks, rmses, clipped) = (planar ? interleaveScratch : scratch).withUnsafeBytes { raw in
            computeMeters(raw: raw, frameCount: frameCount)
        }

        // Step 6: synchronous write.
        do {
            if planar {
                try interleaveScratch.withUnsafeBytes { interleaved in
                    try segmentWriter.write(bytes: interleaved.baseAddress!, byteCount: bytesRead, frameCount: UInt32(frameCount), channels: UInt32(channels))
                }
            } else {
                try scratch.withUnsafeBytes { raw in
                    try segmentWriter.write(bytes: raw.baseAddress!, byteCount: bytesRead, frameCount: UInt32(frameCount), channels: UInt32(channels))
                }
            }
        } catch {
            FileHandle.standardError.write("TapDeck: segment write failed: \(error)\n".data(using: .utf8)!)
        }
        framePosition += Int64(frameCount)

        // Step 8: publish meter snapshot (step 7 — watchdog/gap
        // bookkeeping — happens via reportDroppedDeltas() below and the
        // zero-run delegate call above).
        var snapshot = meterBox.read()
        snapshot.peakByChannel = peaks
        snapshot.rmsByChannel = rmses
        snapshot.clipped = clipped
        snapshot.zeroRunSeconds = zeroRunSeconds
        snapshot.framePosition = framePosition
        meterBox.publish(snapshot)

        reportDroppedDeltas()
        return bytesRead
    }

    private func computeMeters(raw: UnsafeRawBufferPointer, frameCount: Int) -> (peaks: [Float], rmses: [Float], clipped: Bool) {
        let floatPtr = raw.baseAddress!.assumingMemoryBound(to: Float.self)
        var peaks = [Float](repeating: 0, count: channels)
        var rmses = [Float](repeating: 0, count: channels)
        var clipped = false
        for ch in 0..<channels {
            var peak: Float = 0
            var rms: Float = 0
            let chPtr = floatPtr + ch
            vDSP_maxmgv(chPtr, vDSP_Stride(channels), &peak, vDSP_Length(frameCount))
            var meanSquare: Float = 0
            vDSP_measqv(chPtr, vDSP_Stride(channels), &meanSquare, vDSP_Length(frameCount))
            rms = sqrt(meanSquare)
            peaks[ch] = peak
            rmses[ch] = rms
            if peak >= 1.0 { clipped = true }
        }
        return (peaks, rmses, clipped)
    }

    /// Planar de-interleave for a SINGLE callback-chunk: the chunk's
    /// plane-major bytes (Section 5.3) are reordered into interleaved
    /// frames — a pure bit-exact reordering, no arithmetic (Section 5.4
    /// step 5). `source`/`dest` each point at exactly `callbackChunkBytes`
    /// bytes — one complete plane-major block in, one complete interleaved
    /// block out, at the same offset in their respective buffers.
    private func deinterleaveChunk(source: UnsafeRawPointer, dest: UnsafeMutableRawPointer) {
        let samplesPerPlane = Int(framesPerCallback)
        let srcFloats = source.assumingMemoryBound(to: Float.self)
        let dstFloats = dest.assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            let planeStart = ch * samplesPerPlane
            for frame in 0..<samplesPerPlane {
                dstFloats[frame * channels + ch] = srcFloats[planeStart + frame]
            }
        }
    }

    private func reportDroppedDeltas() {
        var chunks: UInt64 = 0
        var frames: UInt64 = 0
        td_ring_take_dropped_deltas(ring, &chunks, &frames)
        if chunks > 0 || frames > 0 {
            var snapshot = meterBox.read()
            snapshot.droppedChunksTotal += chunks
            snapshot.droppedFramesTotal += frames
            meterBox.publish(snapshot)
            delegate?.drainLoop(self, overrunDroppedChunks: chunks, droppedFrames: frames)
        }
    }
}

/// Minimal lock-based atomic boolean (Foundation has no public atomic type
/// pre-Synchronization-framework adoption; this is adequate for a single
/// stop flag read/written across two threads).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
