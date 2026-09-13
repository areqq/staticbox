/*
 * The legacy __sync_* atomic builtins for pre-ARMv6 targets (armv5).
 *
 * ARMv5 has no LDREX/STREX, so clang cannot inline an atomic compare-and-swap
 * and emits a call to the legacy __sync_* libcall instead. GCC answers those
 * from libgcc; zig's compiler-rt does not implement them (as of 0.16.0), while
 * zig's own C runtime (libzigc, whose SmpAllocator backs malloc) calls them —
 * so linking dropbearmulti for armv5 fails with three undefined symbols:
 *
 *   __sync_val_compare_and_swap_4
 *   __sync_val_compare_and_swap_1
 *   __sync_lock_test_and_set_1
 *
 * This file supplies exactly those three, the same way libgcc's
 * config/arm/linux-atomic.c does: through the kernel's user-helper page, whose
 * __kuser_cmpxchg is atomic with respect to interrupts and preemption on a CPU
 * that has no atomic instruction of its own. The helper is a fixed address the
 * kernel maps into every process (CONFIG_KUSER_HELPERS, on by default and
 * effectively always present on the ARMv5 kernels these devices run; there is
 * no alternative for that CPU). qemu-arm implements it too, so the CI/qemu
 * runs exercise the real code path.
 *
 * Word-sized cmpxchg maps straight onto the helper. The byte-sized operations
 * are built on it the way libgcc does: read the containing aligned word,
 * splice the new byte in, and cmpxchg the whole word, retrying while another
 * context changes it.
 *
 * Only reached on armv5 — every other architecture this project builds for
 * (armv7, aarch64, mips, mipsel, i686, x86_64) has native atomics, and
 * build.sh links this in for armv5 alone.
 */

#if !defined(__arm__)
#error "arm-pre-v6-sync.c is for ARM targets only"
#endif
#if defined(__ARMEB__)
#error "big-endian ARM is not a target of this project; the byte shifts below assume little-endian"
#endif

/*
 * int __kuser_cmpxchg(int oldval, int newval, volatile int *ptr)
 * Stores newval at *ptr if *ptr still equals oldval. Returns zero when the
 * exchange happened, non-zero when it did not.
 */
typedef int kuser_cmpxchg_t(int oldval, int newval, volatile int *ptr);
#define kuser_cmpxchg (*(kuser_cmpxchg_t *)0xffff0fc0u)

/* __sync_* are specified as full barriers. These CPUs are single-core and in
 * order, so keeping the compiler from moving memory accesses across the call
 * is all that is left to do. */
#define compiler_barrier() __asm__ __volatile__("" ::: "memory")

int
dbt_sync_val_compare_and_swap_4(volatile int *ptr, int oldval, int newval)
{
	compiler_barrier();
	for (;;) {
		int actual = *ptr;
		if (actual != oldval) {
			compiler_barrier();
			return actual;
		}
		if (kuser_cmpxchg(actual, newval, ptr) == 0) {
			compiler_barrier();
			return oldval;
		}
	}
}

/* The aligned word holding *ptr, and the shift of that byte within it. */
#define BYTE_WORD(p)  ((volatile int *)((unsigned long)(p) & ~3UL))
#define BYTE_SHIFT(p) ((unsigned int)(((unsigned long)(p) & 3UL) * 8U))

unsigned char
dbt_sync_val_compare_and_swap_1(volatile unsigned char *ptr, unsigned char oldval,
    unsigned char newval)
{
	volatile int *word = BYTE_WORD(ptr);
	unsigned int shift = BYTE_SHIFT(ptr);
	unsigned int mask = 0xffU << shift;

	compiler_barrier();
	for (;;) {
		unsigned int old_word = (unsigned int)*word;
		unsigned char actual = (unsigned char)((old_word & mask) >> shift);
		unsigned int new_word;

		if (actual != oldval) {
			compiler_barrier();
			return actual;
		}
		new_word = (old_word & ~mask) | ((unsigned int)newval << shift);
		if (kuser_cmpxchg((int)old_word, (int)new_word, word) == 0) {
			compiler_barrier();
			return oldval;
		}
	}
}

unsigned char
dbt_sync_lock_test_and_set_1(volatile unsigned char *ptr, unsigned char newval)
{
	volatile int *word = BYTE_WORD(ptr);
	unsigned int shift = BYTE_SHIFT(ptr);
	unsigned int mask = 0xffU << shift;

	compiler_barrier();
	for (;;) {
		unsigned int old_word = (unsigned int)*word;
		unsigned char actual = (unsigned char)((old_word & mask) >> shift);
		unsigned int new_word =
		    (old_word & ~mask) | ((unsigned int)newval << shift);

		if (kuser_cmpxchg((int)old_word, (int)new_word, word) == 0) {
			compiler_barrier();
			return actual;
		}
	}
}

/*
 * Word-sized read-modify-write, all on the same primitive: read, compute,
 * exchange, retry if someone got there first. Every one returns the value from
 * before the operation, which is what the __sync_fetch_and_* contract says.
 *
 * These were added when nmap arrived: it is C++, and libc++'s own internals
 * reach for __sync_fetch_and_add_4 and __sync_lock_test_and_set_4, which a
 * plain C program never asked for.
 */
#define DBT_FETCH_OP(name, expr)                                    \
	int                                                         \
	dbt_sync_fetch_and_##name##_4(volatile int *ptr, int val)   \
	{                                                           \
		compiler_barrier();                                 \
		for (;;) {                                          \
			int old = *ptr;                             \
			int new = (expr);                           \
			if (kuser_cmpxchg(old, new, ptr) == 0) {    \
				compiler_barrier();                 \
				return old;                         \
			}                                           \
		}                                                   \
	}

DBT_FETCH_OP(add, old + val)
DBT_FETCH_OP(sub, old - val)
DBT_FETCH_OP(and, old & val)
DBT_FETCH_OP(or,  old | val)
DBT_FETCH_OP(xor, old ^ val)

int
dbt_sync_lock_test_and_set_4(volatile int *ptr, int newval)
{
	compiler_barrier();
	for (;;) {
		int old = *ptr;
		if (kuser_cmpxchg(old, newval, ptr) == 0) {
			compiler_barrier();
			return old;
		}
	}
}

int
dbt_sync_bool_compare_and_swap_4(volatile int *ptr, int oldval, int newval)
{
	return dbt_sync_val_compare_and_swap_4(ptr, oldval, newval) == oldval;
}

/*
 * Byte-sized read-modify-write, on the same masked-word approach as the byte
 * compare-and-swap above.
 */
#define DBT_FETCH_OP_1(name, expr)                                            \
	unsigned char                                                         \
	dbt_sync_fetch_and_##name##_1(volatile unsigned char *ptr,            \
	    unsigned char val)                                                \
	{                                                                     \
		volatile int *word = BYTE_WORD(ptr);                          \
		unsigned int shift = BYTE_SHIFT(ptr);                         \
		unsigned int mask = 0xffU << shift;                           \
		compiler_barrier();                                           \
		for (;;) {                                                    \
			unsigned int old_word = (unsigned int)*word;          \
			unsigned char old =                                   \
			    (unsigned char)((old_word & mask) >> shift);       \
			unsigned char new = (unsigned char)(expr);             \
			unsigned int new_word = (old_word & ~mask) |          \
			    ((unsigned int)new << shift);                     \
			if (kuser_cmpxchg((int)old_word, (int)new_word,       \
			    word) == 0) {                                     \
				compiler_barrier();                           \
				return old;                                   \
			}                                                     \
		}                                                             \
	}

DBT_FETCH_OP_1(add, old + val)
DBT_FETCH_OP_1(sub, old - val)
DBT_FETCH_OP_1(and, old & val)
DBT_FETCH_OP_1(or,  old | val)
DBT_FETCH_OP_1(xor, old ^ val)

/*
 * Eight-byte operations, which the kernel helper cannot do: __kuser_cmpxchg
 * exchanges a word. __kuser_cmpxchg64 exists but only since Linux 3.1, and
 * these parts run older kernels than that, so it is not an option here.
 *
 * A single global lock built on the 32-bit exchange is what GCC's own
 * libatomic does for targets in this position, and it carries the same caveat:
 * it is atomic only against other accesses that take the same lock. That holds
 * here because the compiler routes every wide atomic on this target through
 * these calls -- there is no instruction it could emit instead.
 */
static volatile int dbt_wide_lock;

static void
dbt_wide_acquire(void)
{
	while (dbt_sync_lock_test_and_set_4(&dbt_wide_lock, 1) != 0)
		;
	compiler_barrier();
}

static void
dbt_wide_release(void)
{
	compiler_barrier();
	dbt_wide_lock = 0;
}

#define DBT_FETCH_OP_8(name, expr)                                            \
	long long                                                             \
	dbt_sync_fetch_and_##name##_8(volatile long long *ptr, long long val) \
	{                                                                     \
		long long old;                                                \
		dbt_wide_acquire();                                           \
		old = *ptr;                                                   \
		*ptr = (expr);                                                \
		dbt_wide_release();                                           \
		return old;                                                   \
	}

DBT_FETCH_OP_8(add, old + val)
DBT_FETCH_OP_8(sub, old - val)
DBT_FETCH_OP_8(and, old & val)
DBT_FETCH_OP_8(or,  old | val)
DBT_FETCH_OP_8(xor, old ^ val)

long long
dbt_sync_lock_test_and_set_8(volatile long long *ptr, long long newval)
{
	long long old;
	dbt_wide_acquire();
	old = *ptr;
	*ptr = newval;
	dbt_wide_release();
	return old;
}

long long
dbt_sync_val_compare_and_swap_8(volatile long long *ptr, long long oldval,
    long long newval)
{
	long long actual;
	dbt_wide_acquire();
	actual = *ptr;
	if (actual == oldval)
		*ptr = newval;
	dbt_wide_release();
	return actual;
}

int
dbt_sync_bool_compare_and_swap_8(volatile long long *ptr, long long oldval,
    long long newval)
{
	return dbt_sync_val_compare_and_swap_8(ptr, oldval, newval) == oldval;
}

/*
 * The definitions above carry dbt_-prefixed names because clang refuses to let
 * a translation unit define a function it knows as a builtin ("cannot
 * redeclare builtin function", and -fno-builtin does not lift that). The
 * linker only cares about the symbol, so publish the names it is looking for
 * as assembler-level aliases of those definitions.
 */
__asm__(
	".globl __sync_val_compare_and_swap_4\n"
	".set   __sync_val_compare_and_swap_4, dbt_sync_val_compare_and_swap_4\n"
	".globl __sync_val_compare_and_swap_1\n"
	".set   __sync_val_compare_and_swap_1, dbt_sync_val_compare_and_swap_1\n"
	".globl __sync_lock_test_and_set_1\n"
	".set   __sync_lock_test_and_set_1, dbt_sync_lock_test_and_set_1\n"
	".globl __sync_lock_test_and_set_4\n"
	".set   __sync_lock_test_and_set_4, dbt_sync_lock_test_and_set_4\n"
	".globl __sync_bool_compare_and_swap_4\n"
	".set   __sync_bool_compare_and_swap_4, dbt_sync_bool_compare_and_swap_4\n"
	".globl __sync_fetch_and_add_4\n"
	".set   __sync_fetch_and_add_4, dbt_sync_fetch_and_add_4\n"
	".globl __sync_fetch_and_sub_4\n"
	".set   __sync_fetch_and_sub_4, dbt_sync_fetch_and_sub_4\n"
	".globl __sync_fetch_and_and_4\n"
	".set   __sync_fetch_and_and_4, dbt_sync_fetch_and_and_4\n"
	".globl __sync_fetch_and_or_4\n"
	".set   __sync_fetch_and_or_4, dbt_sync_fetch_and_or_4\n"
	".globl __sync_fetch_and_xor_4\n"
	".set   __sync_fetch_and_xor_4, dbt_sync_fetch_and_xor_4\n"
	".globl __sync_fetch_and_add_1\n"
	".set   __sync_fetch_and_add_1, dbt_sync_fetch_and_add_1\n"
	".globl __sync_fetch_and_add_8\n"
	".set   __sync_fetch_and_add_8, dbt_sync_fetch_and_add_8\n"
	".globl __sync_fetch_and_sub_1\n"
	".set   __sync_fetch_and_sub_1, dbt_sync_fetch_and_sub_1\n"
	".globl __sync_fetch_and_sub_8\n"
	".set   __sync_fetch_and_sub_8, dbt_sync_fetch_and_sub_8\n"
	".globl __sync_fetch_and_and_1\n"
	".set   __sync_fetch_and_and_1, dbt_sync_fetch_and_and_1\n"
	".globl __sync_fetch_and_and_8\n"
	".set   __sync_fetch_and_and_8, dbt_sync_fetch_and_and_8\n"
	".globl __sync_fetch_and_or_1\n"
	".set   __sync_fetch_and_or_1, dbt_sync_fetch_and_or_1\n"
	".globl __sync_fetch_and_or_8\n"
	".set   __sync_fetch_and_or_8, dbt_sync_fetch_and_or_8\n"
	".globl __sync_fetch_and_xor_1\n"
	".set   __sync_fetch_and_xor_1, dbt_sync_fetch_and_xor_1\n"
	".globl __sync_fetch_and_xor_8\n"
	".set   __sync_fetch_and_xor_8, dbt_sync_fetch_and_xor_8\n"
	".globl __sync_lock_test_and_set_8\n"
	".set   __sync_lock_test_and_set_8, dbt_sync_lock_test_and_set_8\n"
	".globl __sync_val_compare_and_swap_8\n"
	".set   __sync_val_compare_and_swap_8, dbt_sync_val_compare_and_swap_8\n"
	".globl __sync_bool_compare_and_swap_8\n"
	".set   __sync_bool_compare_and_swap_8, dbt_sync_bool_compare_and_swap_8\n"
);
