import CoreAudio
import SystemAudioRecorderRT
import Foundation

/// Registers the IOProc via `AudioDeviceCreateIOProcIDWithBlock` with a NULL
/// dispatch queue so the callback fires on the HAL real-time thread
/// (Section 4.2 / Section 5). This is the ONLY place in TapKit that touches
/// the real-time boundary.
///
/// The Section 5.2 contract, honored exactly: the block captures nothing but
/// an `OpaquePointer` (a plain value — no ARC traffic) to the lane's
/// preallocated `td_context_t`, and its entire body is bounds-checking plus
/// one call into a `SystemAudioRecorderRT` C function. No Swift object is retained by the
/// closure; no allocation, lock, log call, or syscall happens in the body.
public final class IOProcHost {
    private var procID: AudioDeviceIOProcID?
    private let aggregateID: AudioObjectID
    private let contextPointer: OpaquePointer

    /// `interleaved` is decided once at registration time from the tap's
    /// effective format (Section 5.3) and captured as a plain `Bool` value —
    /// still no ARC-managed capture.
    public init(aggregateID: AudioObjectID, context: OpaquePointer, interleaved: Bool) throws {
        self.aggregateID = aggregateID
        self.contextPointer = context

        var newProcID: AudioDeviceIOProcID?
        let ctxRaw = UnsafeMutableRawPointer(context)
        let isInterleaved = interleaved

        let block: AudioDeviceIOBlock = { _, inInputData, inInputTime, _, _ in
            let ctxPtr = OpaquePointer(ctxRaw)
            let hostTime = inInputTime.pointee.mHostTime
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

            if isInterleaved {
                // Expected case: one buffer, interleaved Float32 (Section 5.3).
                guard abl.count >= 1 else { return }
                let buffer = abl[0]
                guard let data = buffer.mData else { return }
                let byteCount = Int(buffer.mDataByteSize)
                let frameCount = buffer.mNumberChannels > 0
                    ? UInt32(byteCount) / (buffer.mNumberChannels * 4)
                    : 0
                td_context_on_io(ctxPtr, data, byteCount, hostTime, frameCount)
            } else {
                // Planar: one buffer per channel plane, concatenated
                // back-to-back by the C side. Not expected in practice — the
                // tap is always a global stereo mixdown, which reports
                // interleaved Float32 (Section 5.3) — but handled defensively
                // in case that assumption is ever wrong on some device/OS.
                // Uses a stack-allocated fixed buffer (withUnsafeTemporaryAllocation),
                // NOT a Swift Array — a dynamically-grown Array here would
                // malloc/free on this real-time thread every callback.
                guard abl.count >= 1 else { return }
                // All channel planes are expected to carry the same frame
                // count for a given callback (one shared I/O cycle) — take
                // the first buffer's size, then verify every other plane
                // actually matches it. Silently keeping "whichever buffer
                // was iterated last" (the previous approach) would pass a
                // wrong size into the C side's memcpy for every plane if
                // just one plane ever disagreed, reading past that plane's
                // real buffer. If they disagree, drop this callback outright
                // rather than risk an out-of-bounds read — real-time safe
                // (integer comparisons only, no allocation).
                let planeBytes = Int(abl[0].mDataByteSize)
                guard planeBytes > 0 else { return }
                for buffer in abl where Int(buffer.mDataByteSize) != planeBytes {
                    return
                }
                let frameCount = UInt32(planeBytes) / 4
                let maxPlanes = 32 // must match TD_MAX_PLANES in td_ring.h
                withUnsafeTemporaryAllocation(of: UnsafeRawPointer?.self, capacity: maxPlanes) { buffer in
                    let fillCount = min(abl.count, maxPlanes)
                    for i in 0..<fillCount {
                        buffer[i] = abl[i].mData.map { UnsafeRawPointer($0) }
                    }
                    // Pass the TRUE abl.count (which may exceed maxPlanes) so
                    // the C side's own plane_count > TD_MAX_PLANES check can
                    // correctly detect and drop an over-wide buffer list
                    // instead of silently truncating to the first 32 planes.
                    td_context_on_io_planar(ctxPtr, buffer.baseAddress, abl.count, planeBytes, hostTime, frameCount)
                }
            }
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil, block)
        guard status == noErr, let created = newProcID else {
            throw CoreAudioError(status: status, context: "AudioDeviceCreateIOProcIDWithBlock")
        }
        self.procID = created
    }

    /// Section 4.5 step 7. Engine queue only.
    public func start() throws {
        guard let procID else { return }
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "AudioDeviceStart")
        }
    }

    /// Section 8.2 teardown step 1. Engine queue only. Tolerates non-noErr.
    public func stop() {
        guard let procID else { return }
        let status = AudioDeviceStop(aggregateID, procID)
        if status != noErr {
            Log.error("AudioDeviceStop returned \(status); continuing teardown.")
        }
    }

    /// Section 8.2 teardown step 2. Engine queue only. Tolerates non-noErr.
    public func destroyIOProc() {
        guard let procID else { return }
        let status = AudioDeviceDestroyIOProcID(aggregateID, procID)
        if status != noErr {
            Log.error("AudioDeviceDestroyIOProcID returned \(status); continuing teardown.")
        }
        self.procID = nil
    }
}
