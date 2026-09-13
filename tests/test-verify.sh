#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../targets.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/verify.sh"

# /bin/sh on the build host is dynamically linked. If the static gate cannot
# reject it, the gate does nothing.
assert_fails sb_verify_static /bin/sh

if [ -f "$FIX_MIPSEL" ]; then
	assert_ok sb_verify_static "$FIX_MIPSEL"
	assert_ok sb_verify_elf "$FIX_MIPSEL" mipsel
	assert_fails sb_verify_elf "$FIX_MIPSEL" mips      # wrong endianness
	assert_fails sb_verify_elf "$FIX_MIPSEL" armv7     # wrong machine
	assert_fails sb_verify_elf "$FIX_MIPSEL" aarch64   # wrong class
else
	note_no_fixture mipsel SB_FIXTURE_MIPSEL
fi

if [ -f "$FIX_ARM" ]; then
	assert_ok sb_verify_static "$FIX_ARM"
	assert_ok sb_verify_elf "$FIX_ARM" armv7
	# Built without NEON, so it must satisfy the baseline gate and fail the
	# NEON one. This pair is the whole point of the ISA gate.
	assert_ok    sb_verify_isa "$FIX_ARM" armv7
	assert_fails sb_verify_isa "$FIX_ARM" armv7-neon
else
	note_no_fixture arm SB_FIXTURE_ARM
fi

# SMOKE_EXPECT is read by sb_verify_runs, not by this file.
# shellcheck disable=SC2034
if [ -f "$FIX_ARM" ] && command -v qemu-arm-static >/dev/null 2>&1; then
	# What this check is about is the matching logic, not any particular
	# string: the fixture is whatever binary the environment pointed at. So
	# ask it what it prints and expect that, then expect something it cannot
	# possibly print. Hardcoding one program's banner here made the test pass
	# only for the fixture it happened to be written against.
	FIX_WORD="$(qemu-arm-static "$FIX_ARM" --version 2>&1 | head -1 | awk '{print $1}')"
	if [ -n "$FIX_WORD" ]; then
		SMOKE_EXPECT="$FIX_WORD"
		assert_ok sb_verify_runs "$FIX_ARM" armv7 --version
	fi
	SMOKE_EXPECT='ThisStringWillNeverAppear'
	assert_fails sb_verify_runs "$FIX_ARM" armv7 --version
	unset SMOKE_EXPECT
fi

report test-verify
