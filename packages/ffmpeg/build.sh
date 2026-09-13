#!/bin/sh
# ffmpeg recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE
set -eu

cd "$SRC"

# ffmpeg wants its own name for the architecture. Taking it from the host
# triple rather than from a case over target names keeps the list of
# architectures in targets.sh and nowhere else: a target added there does not
# silently fall through a default here. ffmpeg normalises mipsel to mips and
# x86 to the 32-bit x86 family itself.
FF_ARCH="${SB_HOST_TRIPLE%%-*}"

# --pkg-config=false stops configure from finding the build host's libraries
# and enabling features whose headers do not match the target. Without it a
# cross build happily links against whatever the machine happens to have.
#
# ffplay is not built: it needs SDL, which would be another cross-build for a
# player nothing on a headless box would run.
./configure \
	--enable-cross-compile \
	--arch="$FF_ARCH" \
	--target-os=linux \
	--cross-prefix='' \
	--cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm='llvm-nm' \
	--extra-cflags="$CFLAGS" \
	--extra-ldflags="$LDFLAGS" \
	--pkg-config=false \
	--prefix=/usr \
	--disable-shared --enable-static \
	--disable-doc --disable-debug --disable-ffplay \
	--disable-autodetect \
	>"$WORK/configure.log" 2>&1 \
	|| { tail -n 30 "$WORK/configure.log" >&2; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { grep -iE 'error|undefined' "$WORK/make.log" | head -20 >&2; exit 1; }

mkdir -p "$OUT/bin"
for b in ffmpeg ffprobe; do
	[ -f "$b" ] || { printf '%s was not produced\n' "$b" >&2; exit 1; }
	cp "$b" "$OUT/bin/$b"
	chmod 755 "$OUT/bin/$b"
done
[ -f COPYING.GPLv2 ] && cp COPYING.GPLv2 "$OUT/FFMPEG-LICENSE"
[ -f LICENSE.md ] && cp LICENSE.md "$OUT/FFMPEG-LICENSE.md"
exit 0
