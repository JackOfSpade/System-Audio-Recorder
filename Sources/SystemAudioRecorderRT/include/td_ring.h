/*
 * td_ring.h — SystemAudioRecorderRT real-time capture primitives.
 *
 * Everything declared here is safe to call from the HAL real-time IOProc
 * thread: no locks, no heap allocation on the hot path, no Swift/ObjC
 * runtime involvement. Only td_ring_create/destroy and td_context_create/
 * destroy/arm_first_host_time allocate, and those run on the engine queue,
 * never on the IOProc thread.
 *
 * Threading contract:
 *   - td_context_on_io / td_context_on_io_planar: IOProc thread ONLY (producer).
 *   - td_ring_available_frames / td_ring_read / td_ring_take_dropped_deltas /
 *     td_context_read_timestamps: DrainLoop thread ONLY (consumer).
 *   - td_ring_create/destroy, td_context_create/destroy,
 *     td_context_arm_first_host_time: engine queue, before/after the IOProc
 *     is registered/torn down.
 */

#ifndef TD_RING_H
#define TD_RING_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TD_MAX_PLANES 32

/* ---- Ring buffer ---- */

typedef struct td_ring_s td_ring_t;

/* Allocates a ring whose capacity is the next power of two >= min_capacity_bytes.
 * Returns NULL on allocation failure. Engine-queue only. */
td_ring_t *td_ring_create(size_t min_capacity_bytes);

/* Engine-queue only; caller must ensure no producer/consumer is active. */
void td_ring_destroy(td_ring_t *ring);

/* Actual capacity in bytes (the rounded-up power of two). */
size_t td_ring_capacity(const td_ring_t *ring);

/* Producer-side (IOProc thread only). Writes byte_count bytes from src as one
 * all-or-nothing chunk. byte_count MUST be a whole multiple of bytes_per_frame.
 * If the chunk does not fit in the free space, nothing is written and the
 * dropped-chunk/dropped-frame counters are incremented instead.
 * Returns true if written, false if dropped. */
bool td_ring_write(td_ring_t *ring, const void *src, size_t byte_count, uint32_t bytes_per_frame);

/* Consumer-side (DrainLoop thread only). Number of whole frames currently
 * available to read. */
size_t td_ring_available_frames(const td_ring_t *ring, uint32_t bytes_per_frame);

/* Consumer-side. Copies out up to max_bytes (which the caller must pass as a
 * whole multiple of bytes_per_frame) into dst, up to two memcpy segments
 * across the wrap point. Returns the number of bytes actually copied — always
 * a whole multiple of bytes_per_frame, never more than max_bytes, never more
 * than what was available. Advances the read index by the returned amount. */
size_t td_ring_read(td_ring_t *ring, void *dst, size_t max_bytes, uint32_t bytes_per_frame);

/* Consumer-side. Reads the monotonic dropped-chunk/dropped-frame counters and
 * returns the delta since the last call to this function (first call returns
 * the totals accumulated so far). */
void td_ring_take_dropped_deltas(td_ring_t *ring, uint64_t *out_dropped_chunks, uint64_t *out_dropped_frames);

/* Producer-side (IOProc thread only). Records a dropped chunk of
 * `frame_count` frames WITHOUT attempting to write it — for callers that
 * already know a chunk cannot be written (e.g. it doesn't fit a fixed
 * scratch buffer) and would otherwise have no way to surface the drop via
 * td_ring_take_dropped_deltas. Real-time safe: a single atomic increment
 * each, no memcpy, no allocation. */
void td_ring_record_drop(td_ring_t *ring, uint32_t frame_count);

/* ---- Real-time capture context (one per lane) ---- */

typedef struct td_context_s td_context_t;

/* Engine-queue only. Does not take ownership of `ring` (caller destroys it
 * separately once both are torn down). */
td_context_t *td_context_create(td_ring_t *ring, uint32_t bytes_per_frame);

/* Engine-queue only. */
void td_context_destroy(td_context_t *ctx);

/* Engine-queue only, call once immediately before AudioDeviceStart for a
 * (re)build so the next IOProc callback re-latches firstHostTime. */
void td_context_arm_first_host_time(td_context_t *ctx);

/* Engine-queue only, before the IOProc is registered. When nonzero, planar
 * chunks whose frame count differs from this value are dropped whole (with
 * the drop counters incremented) instead of being written — the consumer
 * parses planar ring content as fixed frames_per_callback blocks, and one
 * odd-sized chunk would desync every later plane boundary (Section 5.3). */
void td_context_set_expected_frames(td_context_t *ctx, uint32_t frames_per_callback);

/* IOProc thread ONLY. Interleaved case: data/byte_count describe one
 * contiguous buffer of raw sample bytes (byte_count a whole multiple of
 * bytes_per_frame). Copies into the ring (drop-all-or-nothing on overflow)
 * and publishes host_time + frame_count into the context. */
void td_context_on_io(td_context_t *ctx,
                      const void *data,
                      size_t byte_count,
                      uint64_t host_time,
                      uint32_t frame_count);

/* IOProc thread ONLY. Planar case: writes `plane_count` channel planes
 * back-to-back (channel order) as one all-or-nothing chunk of
 * plane_count * plane_bytes total bytes, then publishes timestamps exactly as
 * td_context_on_io. plane_count must be <= TD_MAX_PLANES. */
void td_context_on_io_planar(td_context_t *ctx,
                              const void * const *planes,
                              size_t plane_count,
                              size_t plane_bytes,
                              uint64_t host_time,
                              uint32_t frame_count);

/* Tear-free snapshot of the rolling timestamp/frame-count state, read via an
 * internal seqlock retry loop. Safe to call from the DrainLoop thread while
 * the IOProc thread is concurrently publishing. */
typedef struct {
    uint64_t first_host_time;       /* 0 if not yet latched since the last arm */
    bool     first_host_time_set;
    uint64_t last_host_time;        /* mHostTime of the most recent callback's buffer */
    uint32_t last_buffer_frames;    /* frame count of that most recent callback */
    uint64_t total_frames_captured; /* cumulative frames delivered since arm */
} td_timestamps_t;

/* DrainLoop thread only. */
void td_context_read_timestamps(const td_context_t *ctx, td_timestamps_t *out);

#ifdef __cplusplus
}
#endif

#endif /* TD_RING_H */
