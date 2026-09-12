#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
DETECT="$HERE/../detect.sh"

TMP="${TMPDIR:-/tmp}/sb-detect-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP"

# uname -m reports plain "mips" on little-endian boxes too, which is exactly
# the lie this detector exists to see through: the answer comes from the ELF
# header of a binary that is certainly native, not from uname.
mk_cpuinfo() { printf 'Features\t: %s\n' "$1" > "$TMP/cpuinfo"; }

FIX_MIPSEL="${SB_FIXTURE_MIPSEL:-/home/q/ssh/out/nmap-mipsel}"
FIX_ARM="${SB_FIXTURE_ARM:-/home/q/ssh/out/nmap-noneon}"

if [ -f "$FIX_MIPSEL" ]; then
	mk_cpuinfo ''
	assert_eq 'little-endian MIPS is mipsel despite uname' \
		"$(SB_FAKE_UNAME=mips sh "$DETECT" --probe "$FIX_MIPSEL" --cpuinfo "$TMP/cpuinfo")" 'mipsel'
fi

if [ -f "$FIX_ARM" ]; then
	mk_cpuinfo 'half thumb fastmult vfp edsp'
	assert_eq 'ARM without NEON falls to the baseline' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7'
	mk_cpuinfo 'half thumb fastmult vfp edsp neon vfpv3'
	assert_eq 'NEON promotes to armv7-neon' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7-neon'
	# armv7-aes is disabled in the matrix, so a box with AES must still be
	# given a target that actually has builds.
	mk_cpuinfo 'half thumb neon vfpv4 aes pmull'
	assert_eq 'AES does not select a disabled target' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7-neon'
	# A 64-bit kernel under a 32-bit userland: trust the userland.
	mk_cpuinfo 'neon'
	assert_eq 'aarch64 kernel with a 32-bit userland gets an arm build' \
		"$(SB_FAKE_UNAME=aarch64 sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7-neon'
fi

mk_cpuinfo ''
assert_eq 'x86_64 host' "$(SB_FAKE_UNAME=x86_64 sh "$DETECT" --probe /bin/true --cpuinfo "$TMP/cpuinfo")" 'x86_64'
assert_fails env SB_FAKE_UNAME=vax sh "$DETECT" --probe /bin/true --cpuinfo "$TMP/cpuinfo"

# Every name it can print must exist in the matrix, or it hands devices a URL
# that 404s.
. "$HERE/../targets.sh"
for a in x86_64 armv7l aarch64 mips armv5tel i686; do
	n="$(SB_FAKE_UNAME="$a" sh "$DETECT" --probe /bin/true --cpuinfo "$TMP/cpuinfo" 2>/dev/null)" || continue
	assert_ok sb_target_exists "$n"
done

rm -rf "$TMP"
report test-detect
