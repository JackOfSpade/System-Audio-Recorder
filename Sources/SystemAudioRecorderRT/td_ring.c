/*
 * td_ring.c — lock-free SPSC byte ring + real-time capture context.
 * See td_ring.h for the threading contract.
 */

#include "td_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* ---- Ring buffer ---- */

struct td_ring_s {
    /* Immutable, read-only after creation. _Alignas(64) below on write_idx
     * and read_idx makes the compiler insert padding so each group starts on
     * its own cache line; that is all the false-sharing prevention we need —
     * no manual padding arithmetic. */
    uint8_t  *buffer;
    size_t    capacity;      /* power of two */
    size_t    capacity_mask; /* capacity - 1 */

    /* Producer-owned fields — one cache line. */
    _Alignas(64) _Atomic uint64_t write_idx;      /* free-running byte count */
    _Atomic uint64_t dropped_chunks;
    _Atomic uint64_t dropped_frames;

    /* Consumer-owned field — its own cache line. */
    _Alignas(64) _Atomic uint64_t read_idx;       /* free-running byte count */

    /* Consumer-local bookkeeping for delta reporting (only ever touched by
     * the single consumer thread, so no atomics needed here). */
    uint64_t last_seen_dropped_chunks;
    uint64_t last_seen_dropped_frames;
};

static size_t next_pow2(size_t n) {
    if (n < 1) return 1;
    size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

td_ring_t *td_ring_create(size_t min_capacity_bytes) {
    td_ring_t *ring = (td_ring_t *)calloc(1, sizeof(td_ring_t));
    if (!ring) return NULL;

    size_t capacity = next_pow2(min_capacity_bytes);
    ring->buffer = (uint8_t *)malloc(capacity);
    if (!ring->buffer) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    ring->capacity_mask = capacity - 1;

    atomic_store_explicit(&ring->write_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->read_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->dropped_chunks, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->dropped_frames, 0, memory_order_relaxed);
    ring->last_seen_dropped_chunks = 0;
    ring->last_seen_dropped_frames = 0;

    return ring;
}

void td_ring_destroy(td_ring_t *ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

size_t td_ring_capacity(const td_ring_t *ring) {
    return ring ? ring->capacity : 0;
}

bool td_ring_write(td_ring_t *ring, const void *src, size_t byte_count, uint32_t bytes_per_frame) {
    if (!ring || byte_count == 0) return true;

    /* Hard caller contract (td_ring.h): byte_count MUST be a whole multiple
     * of bytes_per_frame. td_ring_read's truncation math assumes the ring's
     * content is always frame-aligned; a single misaligned write here would
     * silently desync every future frame boundary for the rest of the
     * session. Reject instead of corrupting alignment — real-time safe
     * (one modulo, no allocation, no logging), and reuses the existing
     * drop counters so DrainLoop's overrun-event path still fires. */
    if (bytes_per_frame > 0 && (byte_count % bytes_per_frame) != 0) {
        atomic_fetch_add_explicit(&ring->dropped_chunks, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->dropped_frames, (uint64_t)(byte_count / bytes_per_frame), memory_order_relaxed);
        return false;
    }

    uint64_t write_idx = atomic_load_explicit(&ring->write_idx, memory_order_relaxed);
    uint64_t read_idx = atomic_load_explicit(&ring->read_idx, memory_order_acquire);
    uint64_t used = write_idx - read_idx;
    uint64_t free_space = (uint64_t)ring->capacity - used;

    if (byte_count > free_space) {
        atomic_fetch_add_explicit(&ring->dropped_chunks, 1, memory_order_relaxed);
        uint64_t frames = bytes_per_frame > 0 ? (uint64_t)(byte_count / bytes_per_frame) : 0;
        atomic_fetch_add_explicit(&ring->dropped_frames, frames, memory_order_relaxed);
        return false;
    }

    size_t pos = (size_t)(write_idx & ring->capacity_mask);
    size_t first_run = ring->capacity - pos;
    if (first_run >= byte_count) {
        memcpy(ring->buffer + pos, src, byte_count);
    } else {
        memcpy(ring->buffer + pos, src, first_run);
        memcpy(ring->buffer, (const uint8_t *)src + first_run, byte_count - first_run);
    }

    atomic_store_explicit(&ring->write_idx, write_idx + byte_count, memory_order_release);
    return true;
}

size_t td_ring_available_frames(const td_ring_t *ring, uint32_t bytes_per_frame) {
    if (!ring || bytes_per_frame == 0) return 0;
    uint64_t write_idx = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint64_t read_idx = atomic_load_explicit(&ring->read_idx, memory_order_relaxed);
    uint64_t available_bytes = write_idx - read_idx;
    return (size_t)(available_bytes / bytes_per_frame);
}

size_t td_ring_read(td_ring_t *ring, void *dst, size_t max_bytes, uint32_t bytes_per_frame) {
    if (!ring || max_bytes == 0) return 0;

    uint64_t write_idx = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint64_t read_idx = atomic_load_explicit(&ring->read_idx, memory_order_relaxed);
    uint64_t available = write_idx - read_idx;

    size_t to_copy = max_bytes < available ? max_bytes : (size_t)available;
    if (bytes_per_frame > 0) {
        to_copy -= (to_copy % bytes_per_frame);
    }
    if (to_copy == 0) return 0;

    size_t pos = (size_t)(read_idx & ring->capacity_mask);
    size_t first_run = ring->capacity - pos;
    if (first_run >= to_copy) {
        memcpy(dst, ring->buffer + pos, to_copy);
    } else {
        memcpy(dst, ring->buffer + pos, first_run);
        memcpy((uint8_t *)dst + first_run, ring->buffer, to_copy - first_run);
    }

    atomic_store_explicit(&ring->read_idx, read_idx + to_copy, memory_order_release);
    return to_copy;
}

void td_ring_record_drop(td_ring_t *ring, uint32_t frame_count) {
    if (!ring) return;
    atomic_fetch_add_explicit(&ring->dropped_chunks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->dropped_frames, frame_count, memory_order_relaxed);
}

void td_ring_take_dropped_deltas(td_ring_t *ring, uint64_t *out_dropped_chunks, uint64_t *out_dropped_frames) {
    if (!ring) {
        if (out_dropped_chunks) *out_dropped_chunks = 0;
        if (out_dropped_frames) *out_dropped_frames = 0;
        return;
    }
    uint64_t chunks = atomic_load_explicit(&ring->dropped_chunks, memory_order_relaxed);
    uint64_t frames = atomic_load_explicit(&ring->dropped_frames, memory_order_relaxed);

    if (out_dropped_chunks) *out_dropped_chunks = chunks - ring->last_seen_dropped_chunks;
    if (out_dropped_frames) *out_dropped_frames = frames - ring->last_seen_dropped_frames;

    ring->last_seen_dropped_chunks = chunks;
    ring->last_seen_dropped_frames = frames;
}

/* ---- Real-time capture context ---- */

struct td_context_s {
    td_ring_t *ring;           /* not owned */
    uint32_t   bytes_per_frame;

    /* IOProc-thread-owned scratch for the planar concatenation path, sized
     * generously at create time; TD_MAX_PLANES bounds the loop. Written only
     * by the producer, so no atomics needed for the buffer itself. */
    uint8_t   *planar_scratch;
    size_t     planar_scratch_capacity;

    /* Seqlock-guarded rolling timestamp state. Odd version = write in
     * progress; readers retry until they observe a stable even version. */
    _Atomic uint32_t seq;
    _Atomic uint64_t first_host_time;
    _Atomic bool     first_host_time_set;
    _Atomic uint64_t last_host_time;
    _Atomic uint32_t last_buffer_frames;
    _Atomic uint64_t total_frames_captured;
};

td_context_t *td_context_create(td_ring_t *ring, uint32_t bytes_per_frame) {
    td_context_t *ctx = (td_context_t *)calloc(1, sizeof(td_context_t));
    if (!ctx) return NULL;
    ctx->ring = ring;
    ctx->bytes_per_frame = bytes_per_frame;

    /* Generous fixed scratch: 32 planes * 256KB per plane covers any
     * realistic single HAL callback at any sample rate/channel count. */
    ctx->planar_scratch_capacity = (size_t)TD_MAX_PLANES * 256 * 1024;
    ctx->planar_scratch = (uint8_t *)malloc(ctx->planar_scratch_capacity);

    atomic_store_explicit(&ctx->seq, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->first_host_time, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->first_host_time_set, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_host_time, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_buffer_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->total_frames_captured, 0, memory_order_relaxed);

    return ctx;
}

void td_context_destroy(td_context_t *ctx) {
    if (!ctx) return;
    free(ctx->planar_scratch);
    free(ctx);
}

void td_context_arm_first_host_time(td_context_t *ctx) {
    if (!ctx) return;
    atomic_store_explicit(&ctx->first_host_time_set, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->first_host_time, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->total_frames_captured, 0, memory_order_relaxed);
}

/* Shared tail: publish host_time/frame_count into the context. IOProc thread only. */
static void td_context_publish(td_context_t *ctx, uint64_t host_time, uint32_t frame_count) {
    /* Seqlock: bump to odd (write in progress), write fields, bump to even. */
    uint32_t seq = atomic_load_explicit(&ctx->seq, memory_order_relaxed);
    atomic_store_explicit(&ctx->seq, seq + 1, memory_order_release);

    bool already_set = atomic_load_explicit(&ctx->first_host_time_set, memory_order_relaxed);
    if (!already_set) {
        atomic_store_explicit(&ctx->first_host_time, host_time, memory_order_relaxed);
        atomic_store_explicit(&ctx->first_host_time_set, true, memory_order_relaxed);
    }
    atomic_store_explicit(&ctx->last_host_time, host_time, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_buffer_frames, frame_count, memory_order_relaxed);
    uint64_t total = atomic_load_explicit(&ctx->total_frames_captured, memory_order_relaxed);
    atomic_store_explicit(&ctx->total_frames_captured, total + frame_count, memory_order_relaxed);

    atomic_store_explicit(&ctx->seq, seq + 2, memory_order_release);
}

void td_context_on_io(td_context_t *ctx,
                      const void *data,
                      size_t byte_count,
                      uint64_t host_time,
                      uint32_t frame_count) {
    if (!ctx) return;
    td_ring_write(ctx->ring, data, byte_count, ctx->bytes_per_frame);
    td_context_publish(ctx, host_time, frame_count);
}

void td_context_on_io_planar(td_context_t *ctx,
                              const void * const *planes,
                              size_t plane_count,
                              size_t plane_bytes,
                              uint64_t host_time,
                              uint32_t frame_count) {
    if (!ctx) return;

    size_t total_bytes = plane_count * plane_bytes;
    if (plane_count > TD_MAX_PLANES || total_bytes > ctx->planar_scratch_capacity || !ctx->planar_scratch) {
        /* Cannot safely concatenate: drop the whole chunk, matching the
         * standard drop-all-or-nothing overflow path. Record it through the
         * ring's own dropped-chunk/dropped-frame counters (so DrainLoop's
         * overrun-event path actually fires) and still publish timestamps so
         * liveness tracking stays accurate. */
        td_ring_record_drop(ctx->ring, frame_count);
        td_context_publish(ctx, host_time, frame_count);
        return;
    }

    uint8_t *cursor = ctx->planar_scratch;
    for (size_t p = 0; p < plane_count; p++) {
        memcpy(cursor, planes[p], plane_bytes);
        cursor += plane_bytes;
    }

    td_ring_write(ctx->ring, ctx->planar_scratch, total_bytes, ctx->bytes_per_frame);
    td_context_publish(ctx, host_time, frame_count);
}

void td_context_read_timestamps(const td_context_t *ctx, td_timestamps_t *out) {
    if (!ctx || !out) return;

    td_context_t *mctx = (td_context_t *)ctx; /* seq/read only, no mutation of data fields */
    for (;;) {
        uint32_t seq1 = atomic_load_explicit(&mctx->seq, memory_order_acquire);
        if (seq1 & 1u) continue; /* write in progress, retry */

        uint64_t first_host_time = atomic_load_explicit(&mctx->first_host_time, memory_order_relaxed);
        bool first_host_time_set = atomic_load_explicit(&mctx->first_host_time_set, memory_order_relaxed);
        uint64_t last_host_time = atomic_load_explicit(&mctx->last_host_time, memory_order_relaxed);
        uint32_t last_buffer_frames = atomic_load_explicit(&mctx->last_buffer_frames, memory_order_relaxed);
        uint64_t total_frames_captured = atomic_load_explicit(&mctx->total_frames_captured, memory_order_relaxed);

        /* `memory_order_acquire` on the SECOND load (the previous approach)
         * only orders operations sequenced AFTER it — it does nothing to
         * stop the relaxed payload reads above (sequenced BEFORE it) from
         * being reordered to occur AFTER it on weakly-ordered hardware
         * (e.g. Apple Silicon/ARM64). That would let seq2 be observed equal
         * to seq1 (no writer in between, per this load ordering) while some
         * payload reads above haven't actually completed yet, silently
         * returning a torn mix of pre- and post-write field values. An
         * explicit fence between the payload reads and the second load is
         * the standard, portable way to close that window.
         */
        atomic_thread_fence(memory_order_acquire);
        uint32_t seq2 = atomic_load_explicit(&mctx->seq, memory_order_relaxed);
        if (seq1 == seq2) {
            out->first_host_time = first_host_time;
            out->first_host_time_set = first_host_time_set;
            out->last_host_time = last_host_time;
            out->last_buffer_frames = last_buffer_frames;
            out->total_frames_captured = total_frames_captured;
            return;
        }
        /* torn read, retry */
    }
}
