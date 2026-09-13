#!/bin/sh
# rsync recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# Everything optional is off. rsync can link zlib, xxhash, zstd, lz4, openssl
# and acl/xattr support, and none of them is present as a static library here;
# left enabled, configure finds the build host's shared copies and the link
# fails or -- worse -- succeeds against headers that do not match the target.
#
# --disable-roll-simd and friends: rsync's x86_64 checksum path calls
# __builtin_cpu_supports, whose runtime support (__cpu_model,
# __cpu_indicator_init) lives in libgcc and has no counterpart in zig's
# compiler-rt. What it costs is checksum speed on x86_64 and nothing at all on
# the architectures these boxes actually are.
#
# The names matter: 3.4 renamed these from --disable-simd/--disable-asm, and
# configure.sh only WARNS about an option it does not recognise rather than
# failing, so the old spelling looked accepted and changed nothing.
#
# --with-included-zlib=yes keeps rsync's own bundled zlib, which is what the
# protocol's own compression needs and is built for the target along with
# everything else.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--with-included-zlib=yes \
	--disable-roll-simd --disable-roll-asm --disable-md5-asm \
	--disable-xxhash --disable-zstd --disable-lz4 \
	--disable-openssl --disable-md2man \
	--disable-acl-support --disable-xattr-support \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f rsync ] || { printf 'rsync binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp rsync "$OUT/bin/rsync"
chmod 755 "$OUT/bin/rsync"
[ -f COPYING ] && cp COPYING "$OUT/RSYNC-LICENSE"
exit 0
