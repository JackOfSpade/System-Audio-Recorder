#include "ring_smoke_test.h"
#include "td_ring.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* Deliberately NOT `assert()`: assert() compiles to a no-op under -DNDEBUG
 * (release builds), which would silently turn every check below into a
 * skipped no-op instead of a build-breaking test failure. TD_CHECK always
 * evaluates and always reports, in every build configuration. */
#define TD_CHECK(cond) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", #cond, __FILE__, __LINE__); \
            failures++; \
        } \
    } while (0)

int td_ring_smoke_test_run(void) {
    int failures = 0;

    /* Small ring to exercise wraparound quickly. */
    td_ring_t *r = td_ring_create(64); /* rounds to 64 */
    TD_CHECK(td_ring_capacity(r) == 64);

    uint32_t bpf = 8; /* stereo float32 frame = 8 bytes */
    uint8_t chunk[24]; /* 3 frames */
    for (int i = 0; i < 24; i++) chunk[i] = (uint8_t)(i + 1);

    /* Write 3 frames (24 bytes), read them back byte-exact. */
    bool ok = td_ring_write(r, chunk, 24, bpf);
    TD_CHECK(ok);
    TD_CHECK(td_ring_available_frames(r, bpf) == 3);

    uint8_t out[24] = {0};
    size_t got = td_ring_read(r, out, sizeof(out), bpf);
    TD_CHECK(got == 24);
    TD_CHECK(memcmp(out, chunk, 24) == 0);
    TD_CHECK(td_ring_available_frames(r, bpf) == 0);
    printf("PASS: basic write/read byte-exact\n");

    /* Wraparound: write repeatedly to force the physical position past the
     * 64-byte boundary, verify byte-exactness survives the wrap. */
    for (int iter = 0; iter < 20; iter++) {
        uint8_t src[16];
        for (int i = 0; i < 16; i++) src[i] = (uint8_t)(iter * 16 + i);
        ok = td_ring_write(r, src, 16, bpf);
        TD_CHECK(ok);
        uint8_t dst[16] = {0};
        size_t n = td_ring_read(r, dst, sizeof(dst), bpf);
        TD_CHECK(n == 16);
        if (memcmp(dst, src, 16) != 0) {
            fprintf(stderr, "FAIL: wraparound mismatch at iter %d\n", iter);
            failures++;
        }
    }
    printf("PASS: wraparound byte-exactness over 20 iterations\n");

    /* Overflow: fill to capacity, then attempt an oversized write -> dropped,
     * counters increment, no partial write occurs (available stays same). */
    td_ring_destroy(r);
    r = td_ring_create(32); /* capacity 32 */
    uint8_t big[40];
    memset(big, 0xAA, sizeof(big));
    ok = td_ring_write(r, big, 32, bpf); /* exactly fills */
    TD_CHECK(ok);
    size_t before = td_ring_available_frames(r, bpf);
    ok = td_ring_write(r, big, 8, bpf); /* no room left, must drop */
    TD_CHECK(!ok);
    size_t after = td_ring_available_frames(r, bpf);
    TD_CHECK(before == after);
    uint64_t dc = 0, df = 0;
    td_ring_take_dropped_deltas(r, &dc, &df);
    TD_CHECK(dc == 1);
    TD_CHECK(df == 1); /* 8 bytes / 8 bytes-per-frame = 1 frame */
    printf("PASS: overflow drop-all-or-nothing + counters\n");

    /* Context timestamps: arm, publish via on_io, read tear-free. */
    td_context_t *ctx = td_context_create(r, bpf);
    td_context_arm_first_host_time(ctx);
    uint8_t frame[8] = {1,2,3,4,5,6,7,8};
    td_context_on_io(ctx, frame, 8, 1000, 1);
    td_context_on_io(ctx, frame, 8, 1512, 1); /* second callback, later host time */

    td_timestamps_t ts;
    td_context_read_timestamps(ctx, &ts);
    TD_CHECK(ts.first_host_time_set);
    TD_CHECK(ts.first_host_time == 1000); /* latched on FIRST callback only */
    TD_CHECK(ts.last_host_time == 1512);  /* updated every callback */
    TD_CHECK(ts.last_buffer_frames == 1);
    TD_CHECK(ts.total_frames_captured == 2);
    printf("PASS: context timestamp latch/rolling semantics\n");

    td_context_destroy(ctx);
    td_ring_destroy(r);

    if (failures == 0) {
        printf("ALL RING SMOKE TESTS PASSED\n");
    } else {
        fprintf(stderr, "RING SMOKE TEST: %d check(s) FAILED\n", failures);
    }
    return failures;
}
