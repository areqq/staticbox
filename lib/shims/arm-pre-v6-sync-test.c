/*
 * Semantics test for arm-pre-v6-sync.c, run by build.sh under qemu-arm-static
 * whenever the armv5 target is built (skipped, with a notice, if qemu is not
 * installed). Hand-written atomics are worth a test of their own: a wrong
 * return value from a compare-and-swap would not stop dropbearmulti from
 * linking or from logging in, it would corrupt zig's allocator state under
 * contention.
 *
 * Calls the dbt_-prefixed definitions rather than the __sync_* aliases they
 * publish, because clang refuses to let C code even declare a name it knows as
 * a builtin. Same functions, same code path.
 */
#include <stdio.h>
#include <string.h>
int dbt_sync_val_compare_and_swap_4(volatile int *, int, int);
unsigned char dbt_sync_val_compare_and_swap_1(volatile unsigned char *, unsigned char, unsigned char);
unsigned char dbt_sync_lock_test_and_set_1(volatile unsigned char *, unsigned char);
static int fails;
#define CHECK(what, got, want) do { long g=(long)(got), w=(long)(want); \
  if (g!=w) { printf("FAIL %s: got %ld want %ld\n", what, g, w); fails++; } } while (0)
int main(void) {
	volatile int w = 100;
	CHECK("cas4 success returns old", dbt_sync_val_compare_and_swap_4(&w, 100, 200), 100);
	CHECK("cas4 success stored", w, 200);
	CHECK("cas4 failure returns actual", dbt_sync_val_compare_and_swap_4(&w, 999, 300), 200);
	CHECK("cas4 failure left value", w, 200);
	/* every byte offset in a word, to exercise the shift/mask paths */
	for (int off = 0; off < 4; off++) {
		volatile unsigned char buf[8];
		memset((void *)buf, 0xAA, sizeof buf);
		volatile unsigned char *p = &buf[off];
		CHECK("cas1 success returns old", dbt_sync_val_compare_and_swap_1(p, 0xAA, 0x5B), 0xAA);
		CHECK("cas1 success stored", *p, 0x5B);
		CHECK("cas1 failure returns actual", dbt_sync_val_compare_and_swap_1(p, 0x11, 0x22), 0x5B);
		CHECK("cas1 failure left value", *p, 0x5B);
		CHECK("tas1 returns old", dbt_sync_lock_test_and_set_1(p, 0x7C), 0x5B);
		CHECK("tas1 stored", *p, 0x7C);
		/* neighbours in the same word must be untouched */
		for (unsigned i = 0; i < sizeof buf; i++)
			if (&buf[i] != p) CHECK("neighbour byte intact", buf[i], 0xAA);
	}
	/* The word-sized read-modify-writes. A wrong return value here links
	 * cleanly and corrupts an allocator's bookkeeping later, so check both
	 * halves of the contract: what came back, and what is left in memory. */
	{
		int v = 10;
		CHECK("fetch_and_add returns the old value", __sync_fetch_and_add(&v, 5), 10);
		CHECK("fetch_and_add stored the sum", v, 15);
		CHECK("fetch_and_sub returns the old value", __sync_fetch_and_sub(&v, 3), 15);
		CHECK("fetch_and_sub stored the difference", v, 12);

		v = 0xF0;
		CHECK("fetch_and_and returns the old value", __sync_fetch_and_and(&v, 0x3C), 0xF0);
		CHECK("fetch_and_and stored the conjunction", v, 0x30);
		CHECK("fetch_and_or returns the old value", __sync_fetch_and_or(&v, 0x0F), 0x30);
		CHECK("fetch_and_or stored the disjunction", v, 0x3F);
		CHECK("fetch_and_xor returns the old value", __sync_fetch_and_xor(&v, 0xFF), 0x3F);
		CHECK("fetch_and_xor stored the difference", v, 0xC0);

		v = 7;
		CHECK("lock_test_and_set returns the old value", __sync_lock_test_and_set(&v, 99), 7);
		CHECK("lock_test_and_set stored the new value", v, 99);

		v = 5;
		CHECK("bool_compare_and_swap succeeds on a match", __sync_bool_compare_and_swap(&v, 5, 6), 1);
		CHECK("and stored the new value", v, 6);
		CHECK("bool_compare_and_swap fails on a mismatch", __sync_bool_compare_and_swap(&v, 5, 7), 0);
		CHECK("and left the value alone", v, 6);
	}

	printf(fails ? "FAILURES: %d\n" : "all atomics checks passed\n", fails);
	return fails != 0;
}
