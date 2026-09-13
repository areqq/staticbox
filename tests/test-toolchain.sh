#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
# Read by lib/toolchain.sh when it looks for the shim sources.
# shellcheck disable=SC2034
SB_LIB_DIR="$HERE/../lib"
. "$HERE/../targets.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/toolchain.sh"

# Size and static linking are not per-package choices: every target gets them.
for t in $(sb_targets_enabled); do
	f="$(sb_tc_flags "$t" zig)"
	assert_contains "$t/zig optimises for size"  "$f" '-Os'
	assert_contains "$t/zig splits functions"    "$f" '-ffunction-sections'
	assert_contains "$t/zig splits data"         "$f" '-fdata-sections'
done

assert_contains 'armv7/zig is the a9 baseline' "$(sb_tc_flags armv7 zig)" '-mcpu=cortex_a9-neon-d32'
assert_contains 'armv7-neon/zig takes a15' "$(sb_tc_flags armv7-neon zig)" '-mcpu=cortex_a15'
assert_contains 'mipsel/zig pins mips32'   "$(sb_tc_flags mipsel zig)" '-mcpu=mips32'

# The bootlin backend uses gcc spellings, which differ from zig's.
assert_contains 'mipsel/bootlin uses -march' "$(sb_tc_flags mipsel bootlin)" '-march=mips32'
# Bootlin's MIPS toolchains are hard-float and publish no soft-float variant,
# so the matrix must NOT ask for soft-float there: an ABI-mismatched binary is
# the result, and there is no way to get a matching soft-float one.
case "$(sb_tc_flags mipsel bootlin)" in
	*-msoft-float*) fail 'mipsel/bootlin must not claim soft-float' ;;
	*) pass 'mipsel/bootlin does not claim soft-float' ;;
esac
assert_contains 'armv5/bootlin is softfp' "$(sb_tc_flags armv5 bootlin)" '-msoft-float'
assert_contains 'armv7/bootlin caps the fpu' "$(sb_tc_flags armv7 bootlin)" '-mfpu=vfpv3-d16'

assert_fails sb_tc_flags mipsel nosuchbackend
assert_fails sb_tc_flags nosucharch zig

report test-toolchain
