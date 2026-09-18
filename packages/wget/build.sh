#!/bin/sh
# wget recipe. Compiles only: the driver has already fetched, verified and
# unpacked wget, zlib and OpenSSL.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS DEP_PREFIX
#        SRC_zlib SRC_openssl
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

JOBS="$(nproc 2>/dev/null || echo 2)"

# --------------------------------------------------------------------- zlib
# zlib's hand-written configure takes no --host: it reads CC, AR and RANLIB
# from the environment and compiles its probes with them, which is enough to
# cross-build correctly. --static skips the shared object, which would fail to
# link against the non-PIC static CRT anyway.
#
# SRC_zlib and SRC_openssl are exported by the driver for the deps declared in
# meta, which the linter has no way to see.
# shellcheck disable=SC2154
( cd "$SRC_zlib"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" \
	./configure --static --prefix="$DEP_PREFIX" \
	>"$WORK/zlib-configure.log" 2>&1
  make -j"$JOBS" >"$WORK/zlib-make.log" 2>&1
  make install >>"$WORK/zlib-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/zlib-make.log"; sb_dump_log "$WORK/zlib-configure.log"; exit 1; }

# ------------------------------------------------------------------ OpenSSL
# The same three traps as in packages/curl, packages/git and packages/nmap:
# Configure appends --cross-compile-prefix to CC, so CC must be unset here or
# it builds <triple>-<triple>-gcc; no-docs does not exist in 3.0.x; and
# build_libs + install_dev gives the libraries without the openssl application,
# which is not wanted and does not link on MIPS32 anyway.
#
# --openssldir=/etc/ssl is the one thing done differently here, and it is the
# whole CA story for this package. wget asks OpenSSL for its default verify
# paths, and OpenSSL answers with whatever --openssldir said at build time.
# Left at the staging prefix it would answer with a directory on the build
# machine, which no device has, and every https fetch would fail to verify
# until told --ca-certificate by hand. Naming the conventional location means
# a box that has a CA store is simply believed. One that has none still fails,
# but says so clearly, and README-WGET gives the flag.
# shellcheck disable=SC2154
( cd "$SRC_openssl"
  unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  ./Configure linux-generic32 no-shared no-dso no-engine no-tests no-async \
	no-threads \
	--prefix="$DEP_PREFIX" --openssldir=/etc/ssl \
	CC="$CC" AR="$AR" RANLIB="$RANLIB" \
	>"$WORK/openssl-configure.log" 2>&1
  make -j"$JOBS" build_libs >"$WORK/openssl-make.log" 2>&1
  make install_dev >>"$WORK/openssl-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/openssl-make.log"; sb_dump_log "$WORK/openssl-configure.log"; exit 1; }

# --------------------------------------------------------------------- wget
cd "$SRC"

# Everything switched off would need its own cross-build and none of it earns
# that for fetching files onto a set-top box:
#
#   --without-libpsl    public-suffix matching for cookies. A list that goes
#                       stale, a library to build, for a downloader.
#   --without-libuuid   only used to stamp UUIDs into WARC archive files.
#   --without-cares     asynchronous DNS. wget here resolves one host at a
#                       time and musl's resolver is already doing that.
#   --without-metalink  needs libmetalink and gpgme.
#   --disable-pcre*     the regex filters for -A/-R. wget's own globbing
#                       covers what anyone does on a box.
#   --disable-nls       no translations, no libintl to cross-build, and one
#                       locale on the device anyway.
#   --disable-iri       internationalised URLs, via libidn2. This one is not
#                       merely unwanted, it actively breaks the build: wget
#                       asks pkg-config for libidn2 and pkg-config answers for
#                       the *build host*, so configure enables IRI support and
#                       the cross compile then dies on a missing idn2.h. Off is
#                       also what packages/curl does, for the same reason a
#                       non-ASCII domain name is not something these boxes
#                       fetch from.
#
# zlib stays on: it is already built above for nothing extra, and it is what
# lets wget accept a gzip-encoded response rather than refusing it.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -L$DEP_PREFIX/lib" \
	CPPFLAGS="-I$DEP_PREFIX/include" \
	--with-ssl=openssl --with-libssl-prefix="$DEP_PREFIX" \
	--with-zlib \
	--without-libpsl --without-libuuid --without-cares --without-metalink \
	--disable-pcre --disable-pcre2 --disable-nls --disable-iri \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$JOBS" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

BIN='src/wget'
[ -f "$BIN" ] || { printf 'wget binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/wget"
chmod 755 "$OUT/bin/wget"
[ -f COPYING ] && cp COPYING "$OUT/WGET-LICENSE"

{
	printf 'What this has that curl does not: recursion.\n\n'
	printf '  wget -m -k -p https://example.com/       mirror a site\n'
	printf '  wget -c https://example.com/big.iso      resume a partial file\n\n'
	printf 'TLS verification uses the CA store at /etc/ssl, which is where\n'
	printf 'these devices keep one if they keep one at all. When the box has\n'
	printf 'none, wget says it cannot verify and stops. Point it at a bundle:\n\n'
	printf '  wget --ca-certificate=/path/to/ca-bundle.crt https://...\n\n'
	printf 'Turning verification off entirely is --no-check-certificate. That\n'
	printf 'makes https no safer than http, so use it to prove a problem is\n'
	printf 'the CA store and not to live with it.\n'
} > "$OUT/README-WGET"
exit 0
