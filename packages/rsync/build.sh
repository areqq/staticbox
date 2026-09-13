#!/bin/sh
# rsync recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE
set -eu

cd "$SRC"

# Everything optional is off. rsync can link zlib, xxhash, zstd, lz4, openssl
# and acl/xattr support, and none of them is present as a static library here;
# left enabled, configure finds the build host's shared copies and the link
# fails or -- worse -- succeeds against headers that do not match the target.
#
# --disable-simd and --disable-asm: rsync's x86_64 checksum path calls
# __builtin_cpu_supports, whose runtime support (__cpu_model,
# __cpu_indicator_init) lives in libgcc and has no counterpart in zig's
# compiler-rt. What it costs is checksum speed on x86_64 and nothing at all on
# the architectures these boxes actually are.
#
# --with-included-zlib=yes keeps rsync's own bundled zlib, which is what the
# protocol's own compression needs and is built for the target along with
# everything else.
./configure --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--with-included-zlib=yes \
	--disable-simd --disable-asm \
	--disable-xxhash --disable-zstd --disable-lz4 \
	--disable-openssl --disable-md2man \
	--disable-acl-support --disable-xattr-support \
	>"$WORK/configure.log" 2>&1 \
	|| { tail -n 25 "$WORK/configure.log" >&2; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { grep -iE 'error|undefined' "$WORK/make.log" | head -20 >&2; exit 1; }

[ -f rsync ] || { printf 'rsync binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp rsync "$OUT/bin/rsync"
chmod 755 "$OUT/bin/rsync"
[ -f COPYING ] && cp COPYING "$OUT/RSYNC-LICENSE"
exit 0
