#!/bin/sh
# ffmpeg recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_BUILD_TRIPLE
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# ffmpeg wants its own name for the architecture. Taking it from the host
# triple rather than from a case over target names keeps the list of
# architectures in targets.sh and nowhere else: a target added there does not
# silently fall through a default here. ffmpeg normalises mipsel to mips and
# x86 to the 32-bit x86 family itself.
FF_ARCH="${SB_HOST_TRIPLE%%-*}"

# ffmpeg needs an nm to work out the symbol prefix. GNU nm reads foreign ELF
# perfectly well, so the host's does the job; llvm-nm is preferred when it is
# there but is not something a CI runner has by default.
FF_NM="$(command -v llvm-nm 2>/dev/null || command -v nm)"

# ffmpeg takes its flags through --extra-cflags/--extra-ldflags AND reads
# CFLAGS and LDFLAGS from the environment, so passing both puts everything on
# the link line twice. Duplicated -Os is harmless; a duplicated object file is
# not, and the toolchain's shim rides in LDFLAGS -- "duplicate symbol: pipe",
# at the very first compiler test, which reads as "C compiler test failed".
# ffmpeg probes for instruction-set extensions by assembling a .S file, and
# clang's integrated assembler assembles those for the default architecture
# whatever -mcpu says. On armv5 every probe passed and it built rev16 and
# movt into the binary -- ARMv6 and ARMv6T2 instructions that an arm926ej-s
# does not have. Naming the CPU makes ffmpeg set the level instead of asking.
#
# Naming the extensions the part lacks, rather than the CPU: ffmpeg's --cpu
# truncates arm926ej-s at the dash and hands clang an "unknown CPU: arm926ej".
#
# Only the parts whose level the probes get wrong need this. An unknown target
# stops the build rather than falling through to a silent default, because the
# failure mode is a binary that runs everywhere except on the device.
case "$TARGET" in
	armv5)                           FF_EXT='--disable-armv6 --disable-armv6t2 --disable-neon --disable-vfp' ;;
	armv7|armv7-neon|armv7-aes)      FF_EXT='' ;;
	x86_64|i686|aarch64|mips|mipsel) FF_EXT='' ;;
	*) printf 'ffmpeg: no instruction-set decision for target %s\n' "$TARGET" >&2; exit 1 ;;
esac

FF_CFLAGS="$CFLAGS"
FF_LDFLAGS="$LDFLAGS"
unset CFLAGS LDFLAGS

# --pkg-config=false stops configure from finding the build host's libraries
# and enabling features whose headers do not match the target. Without it a
# cross build happily links against whatever the machine happens to have.
#
# ffplay is not built: it needs SDL, which would be another cross-build for a
# player nothing on a headless box would run.
#
# --disable-stripping because ffmpeg ends its link by running `strip`, and on a
# cross build that is the host's, which refuses a foreign binary outright:
# "Unable to recognise the format of the input file". x86_64 passed and every
# other target failed, which is exactly what that looks like. Nothing is lost:
# LDFLAGS carries -Wl,-s, so the linker has already stripped it.
#
# --disable-x86asm because ffmpeg's x86 assembly needs nasm, and requiring a
# host assembler contradicts what this repo promises -- that a clean machine
# needs only curl, tar and make. It costs SIMD speed on x86_64 and i686 only:
# the ARM and MIPS assembly goes through the ordinary assembler, so the targets
# these boxes actually are keep theirs. Anyone who wants the fast x86 build can
# install nasm and drop this line.
# shellcheck disable=SC2086  # $FF_EXT is a list of options, not one word
./configure \
	--enable-cross-compile \
	--arch="$FF_ARCH" \
	$FF_EXT \
	--target-os=linux \
	--cross-prefix='' \
	--cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm="$FF_NM" \
	--extra-cflags="$FF_CFLAGS" \
	--extra-ldflags="$FF_LDFLAGS" \
	--pkg-config=false \
	--prefix=/usr \
	--disable-shared --enable-static \
	--disable-doc --disable-debug --disable-ffplay \
	--disable-stripping \
	--disable-x86asm \
	--disable-autodetect \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

mkdir -p "$OUT/bin"
for b in ffmpeg ffprobe; do
	[ -f "$b" ] || { printf '%s was not produced\n' "$b" >&2; exit 1; }
	cp "$b" "$OUT/bin/$b"
	chmod 755 "$OUT/bin/$b"
done
[ -f COPYING.GPLv2 ] && cp COPYING.GPLv2 "$OUT/FFMPEG-LICENSE"
[ -f LICENSE.md ] && cp LICENSE.md "$OUT/FFMPEG-LICENSE.md"
exit 0
