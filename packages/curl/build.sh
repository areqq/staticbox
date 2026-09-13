#!/bin/sh
# curl recipe. Compiles only: the driver has already fetched, verified and
# unpacked curl and OpenSSL.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_TARGET_LIBS DEP_PREFIX SRC_openssl
set -eu

JOBS="$(nproc 2>/dev/null || echo 2)"

# ------------------------------------------------------------------ OpenSSL
# The same three traps as in packages/nmap/build.sh, and for the same reasons:
# Configure appends --cross-compile-prefix to CC, so CC must be unset or it
# builds <triple>-<triple>-gcc; no-docs does not exist in 3.0.x; and
# build_libs + install_dev gives the libraries without the openssl application,
# which is not wanted and does not link on MIPS32 anyway.
#
# SRC_openssl is exported by the driver for the dep declared in meta.
# shellcheck disable=SC2154
# The architecture flags have to be handed to Configure as trailing
# arguments. Everything else in this repo gets them through the compiler
# wrapper, but --cross-compile-prefix builds its own "<triple>-gcc" and calls
# that directly, so the wrapper is bypassed and OpenSSL's objects come out at
# the toolchain's default ISA. On MIPS that default is r2, which is an illegal
# instruction on the r1 parts this targets -- caught by the gate as a SIGILL
# under qemu, and on a BCM7356 it would have been one on real silicon.
# no-threads: OpenSSL's threading layer calls __atomic_is_lock_free and
# __atomic_fetch_or_8, which on MIPS32 live in libatomic -- a library zig's
# compiler-rt does not carry and whose Bootlin copy cannot be linked here for
# ABI reasons. curl is a single-threaded CLI, so the threading layer buys it
# nothing; dropping it removes the dependency and some size with it.
#
# Configured through CC rather than --cross-compile-prefix. The prefix option
# builds its own "<triple>-gcc" and calls that directly, which works only for a
# toolchain whose tools are named that way and bypasses our compiler wrapper
# even then -- on MIPS that left OpenSSL's objects at the toolchain's default
# ISA. Naming CC keeps every object on the same compiler as the rest of the
# build, zig or not.
OSSL_CC="$CC"
# shellcheck disable=SC2154
( cd "$SRC_openssl"
  unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  ./Configure linux-generic32 no-shared no-dso no-engine no-tests no-async \
	no-threads \
	--prefix="$DEP_PREFIX" --openssldir="$DEP_PREFIX/ssl" \
	CC="$OSSL_CC" AR="$AR" RANLIB="$RANLIB" \
	>"$WORK/openssl-configure.log" 2>&1
  make -j"$JOBS" build_libs >"$WORK/openssl-make.log" 2>&1
  make install_dev >>"$WORK/openssl-make.log" 2>&1 ) \
	|| { tail -n 25 "$WORK/openssl-make.log" "$WORK/openssl-configure.log" >&2; exit 1; }

# --------------------------------------------------------------------- curl
cd "$SRC"

# --with-ca-fallback makes curl fall back to OpenSSL's own default CA path
# rather than hard-failing when no bundle is given. A box usually has some
# store somewhere; when it does not, --cacert is the answer and the binary at
# least says so instead of failing opaquely.
#
# Everything that would pull another library is off: no libidn2, no libpsl, no
# zstd, no brotli, no nghttp2. Each would need its own cross-build, and none
# earns that for fetching a file onto a set-top box.
./configure --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -L$DEP_PREFIX/lib" \
	CPPFLAGS="-I$DEP_PREFIX/include" \
	--with-openssl="$DEP_PREFIX" --with-ca-fallback \
	--disable-shared --enable-static \
	--without-libidn2 --without-libpsl --without-nghttp2 \
	--without-zstd --without-brotli --without-librtmp --without-zlib \
	--disable-ldap --disable-ldaps \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { tail -n 25 "$WORK/configure.log" >&2; exit 1; }

# -XCClinker is libtool's escape hatch: pass the next flag straight to the
# linking compiler. It is needed because libtool eats a plain -static as one of
# its own options and then leaves it out of the command it generates -- the
# link came out with no -static at all and curl was dynamically linked, which
# the gate caught and a box would simply have refused to run. -all-static does
# not help either: with no shared libtool libraries in the link it is a no-op.
#
# It goes here rather than in configure, where libtool is not yet in play and
# the compiler sees the flag raw: the very first check fails with "C compiler
# cannot create executables".
make -j"$JOBS" LDFLAGS="$LDFLAGS -XCClinker -static -L$DEP_PREFIX/lib" \
	>"$WORK/make.log" 2>&1 \
	|| { grep -iE 'error|undefined' "$WORK/make.log" | head -20 >&2; exit 1; }

BIN='src/curl'
[ -f "$BIN" ] || { printf 'curl binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/curl"
chmod 755 "$OUT/bin/curl"
[ -f COPYING ] && cp COPYING "$OUT/CURL-LICENSE"
exit 0
