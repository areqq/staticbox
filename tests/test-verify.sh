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

# Fixtures: real statically linked binaries for foreign architectures, built by
# the systems this repo replaces. Skipped when absent so the suite still runs
# on a clean checkout.
FIX_MIPSEL="${SB_FIXTURE_MIPSEL:-/home/q/ssh/out/nmap-mipsel}"
FIX_ARM="${SB_FIXTURE_ARM:-/home/q/ssh/out/nmap-noneon}"

if [ -f "$FIX_MIPSEL" ]; then
	assert_ok sb_verify_static "$FIX_MIPSEL"
	assert_ok sb_verify_elf "$FIX_MIPSEL" mipsel
	assert_fails sb_verify_elf "$FIX_MIPSEL" mips      # wrong endianness
	assert_fails sb_verify_elf "$FIX_MIPSEL" armv7     # wrong machine
	assert_fails sb_verify_elf "$FIX_MIPSEL" aarch64   # wrong class
else
	printf '  skip mipsel fixture (%s absent)\n' "$FIX_MIPSEL"
fi

if [ -f "$FIX_ARM" ]; then
	assert_ok sb_verify_static "$FIX_ARM"
	assert_ok sb_verify_elf "$FIX_ARM" armv7
	# Built without NEON, so it must satisfy the baseline gate and fail the
	# NEON one. This pair is the whole point of the ISA gate.
	assert_ok    sb_verify_isa "$FIX_ARM" armv7
	assert_fails sb_verify_isa "$FIX_ARM" armv7-neon
else
	printf '  skip arm fixture (%s absent)\n' "$FIX_ARM"
fi

# SMOKE_EXPECT is read by sb_verify_runs, not by this file.
# shellcheck disable=SC2034
if [ -f "$FIX_ARM" ] && command -v qemu-arm-static >/dev/null 2>&1; then
	SMOKE_EXPECT='Nmap'
	assert_ok sb_verify_runs "$FIX_ARM" armv7 --version
	SMOKE_EXPECT='ThisStringWillNeverAppear'
	assert_fails sb_verify_runs "$FIX_ARM" armv7 --version
	unset SMOKE_EXPECT
fi

report test-verify
