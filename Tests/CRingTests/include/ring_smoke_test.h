/*
 * ring_smoke_test.h — pure-C smoke test for SystemAudioRecorderRT's ring buffer,
 * exercised directly (no Swift/C interop layer in between) as a
 * cross-check against Tests/TapKitTests/RingBufferTests.swift, which
 * covers the same cases through Swift.
 */

#ifndef RING_SMOKE_TEST_H
#define RING_SMOKE_TEST_H

/* Runs every check and returns 0 if all passed, or the count of failed
 * checks otherwise. Never aborts the process — safe to call from an
 * XCTest case. Prints PASS/FAIL lines to stdout/stderr as it goes. */
int td_ring_smoke_test_run(void);

#endif
