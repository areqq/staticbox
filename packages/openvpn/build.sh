#!/bin/sh
# OpenVPN recipe. Compiles only: the driver has already fetched, verified and
# unpacked OpenVPN and mbedTLS.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS DEP_PREFIX
#        SRC_mbedtls
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

JOBS="$(nproc 2>/dev/null || echo 2)"

# ------------------------------------------------------------------- mbedTLS
# `make lib`, not `make install`. The install target depends on no_test, which
# depends on programs, so asking for it would cross-compile ssl_client2 and
# every other sample -- minutes of work for files nothing here installs. lib
# builds the three archives and stops; the headers are copied by hand below.
#
# CFLAGS travels in the environment rather than on the command line. The
# library Makefile says `CFLAGS ?= -O2` and keeps its own LOCAL_CFLAGS beside
# it, and an environment value leaves that arrangement intact.
#
# SRC_mbedtls is exported by the driver for the dep declared in meta, which the
# linter has no way to see.
# shellcheck disable=SC2154
( cd "$SRC_mbedtls"
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	make -j"$JOBS" lib CC="$CC" AR="$AR" >"$WORK/mbedtls-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/mbedtls-make.log"; exit 1; }

mkdir -p "$DEP_PREFIX/include" "$DEP_PREFIX/lib"
cp -r "$SRC_mbedtls/include/mbedtls" "$DEP_PREFIX/include/"
cp -r "$SRC_mbedtls/include/psa"     "$DEP_PREFIX/include/"
for a in libmbedtls.a libmbedx509.a libmbedcrypto.a; do
	[ -f "$SRC_mbedtls/library/$a" ] || {
		printf 'mbedTLS did not produce %s\n' "$a" >&2; exit 1; }
	cp "$SRC_mbedtls/library/$a" "$DEP_PREFIX/lib/"
done

# ----------------------------------------------------------------- libcap-ng
# The only recipe here that runs autotools. Upstream stopped publishing dist
# tarballs after 0.8.5, so a git tag is all there is and it carries no
# generated configure -- see the note in meta for why 0.8.5 was not taken
# instead.
#
# Only src/ is built. The rest of the tree is pscap, netcap, filecap and
# cap-audit, which need BPF and libcap and are of no use to a linked library.
#
# SRC_libcapng is exported by the driver for the dep declared in meta.
# shellcheck disable=SC2154
( cd "$SRC_libcapng"
  ./autogen.sh >"$WORK/libcapng-autogen.log" 2>&1
  ./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--prefix="$DEP_PREFIX" --disable-shared --enable-static \
	--without-python --without-python3 --disable-cap-audit \
	>"$WORK/libcapng-configure.log" 2>&1
  make -j"$JOBS" -C src >"$WORK/libcapng-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/libcapng-make.log"
	     sb_dump_log "$WORK/libcapng-configure.log"
	     sb_dump_log "$WORK/libcapng-autogen.log"; exit 1; }

[ -f "$SRC_libcapng/src/.libs/libcap-ng.a" ] || {
	printf 'libcap-ng did not produce libcap-ng.a\n' >&2; exit 1; }
cp "$SRC_libcapng/src/.libs/libcap-ng.a" "$DEP_PREFIX/lib/"
cp "$SRC_libcapng/src/cap-ng.h"          "$DEP_PREFIX/include/"

# ------------------------------------------------------------------- OpenVPN
cd "$SRC"

# The four *_CFLAGS/*_LIBS are named explicitly so that configure's
# PKG_CHECK_MODULES short-circuits. Neither library was installed anywhere a
# pkg-config could find it, and for libcap-ng that is not a convenience but the
# only way through: OpenVPN 2.7 errors out of configure when the module is
# missing and offers no --disable. For mbedTLS it also fixes the link order --
# tls needs x509 needs crypto, a static link resolves left to right, and the
# fallback path would have chosen its own order.
#
# Everything disabled is disabled because it would need a library that is not
# here, or a kernel feature these boxes do not have:
#
#   --disable-dco      data channel offload wants the ovpn-dco kernel module
#                      and libnl. Plain SITNL netlink, which needs no library
#                      at all, is what remains and is what OpenVPN uses by
#                      default on Linux.
#   --disable-lzo      compression is off. Not only to avoid two more
#   --disable-lz4      cross-builds: compressing before encrypting is what
#                      VORACLE exploits, upstream has deprecated it, and
#                      current configs do not use it. A peer whose config
#                      still says `comp-lzo yes` will not negotiate with this
#                      binary -- that is the one thing given up here.
#   --disable-plugins  the plugin ABI dlopens shared objects. In a static
#   --disable-plugin-* binary there is nothing to dlopen into.
#   --disable-unit-tests  they are built to run on the build host and cannot,
#                      being compiled for the target.
#
# Management is left on: it is self-contained, and it is how anything ever
# asks a running openvpn what it is doing.
# OpenVPN stamps a git revision into its version banner when it finds itself
# inside a work tree. Unpacked under .build, it finds *this* repository and the
# binary then claims to be "git:main/<a staticbox commit>" -- provenance that
# is not merely useless but false, and it lands in the one string a person
# reads when reporting a bug. GIT_CEILING_DIRECTORIES stops git walking out of
# the source directory, so configure concludes there is no checkout and the
# banner carries the release version alone.
GIT_CEILING_DIRECTORIES="$WORK"
export GIT_CEILING_DIRECTORIES

# -Wno-error=date-time for the same reason packages/socat needs it: OpenVPN
# stamps __DATE__ into its version string, and zig cc promotes that warning to
# an error in the name of reproducible builds. Silencing only the promotion
# keeps the diagnostic visible without failing the build.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS -Wno-error=date-time" LDFLAGS="$LDFLAGS" \
	MBEDTLS_CFLAGS="-I$DEP_PREFIX/include" \
	MBEDTLS_LIBS="-L$DEP_PREFIX/lib -lmbedtls -lmbedx509 -lmbedcrypto" \
	LIBCAPNG_CFLAGS="-I$DEP_PREFIX/include" \
	LIBCAPNG_LIBS="-L$DEP_PREFIX/lib -lcap-ng" \
	--with-crypto-library=mbedtls \
	--disable-dco --disable-lzo --disable-lz4 \
	--disable-plugins --disable-plugin-auth-pam --disable-plugin-down-root \
	--disable-systemd --disable-selinux --disable-unit-tests \
	--enable-static --disable-shared \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$JOBS" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

BIN='src/openvpn/openvpn'
[ -f "$BIN" ] || { printf 'openvpn binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/openvpn"
chmod 755 "$OUT/bin/openvpn"
[ -f COPYING ] && cp COPYING "$OUT/OPENVPN-LICENSE"

{
	printf 'One binary, both roles: the config file decides. It needs\n'
	printf '/dev/net/tun, and no binary can supply that -- the tun driver\n'
	printf 'has to be in the kernel.\n\n'
	printf 'Built against mbedTLS, so three things differ from an OpenSSL\n'
	printf 'build. PKCS#12 is not supported: unpack a .p12 on a PC first\n'
	printf 'with "openssl pkcs12 -in x.p12 -out x.pem -nodes". --capath is\n'
	printf 'not supported; --ca with one file is. An X.509 username must be\n'
	printf 'the CN. Inline <ca>, <cert>, <key> and <tls-crypt> blocks, which\n'
	printf 'is what almost every .ovpn actually holds, work unchanged.\n\n'
	printf 'Compression is compiled out. A peer whose config says\n'
	printf '"comp-lzo yes" will not negotiate; drop that line on both ends.\n\n'
	printf 'For a server, make the CA and the certificates on a PC with\n'
	printf 'easy-rsa and copy them over -- nothing here generates them, and\n'
	printf 'a set-top box is the wrong place to keep a CA key. What this\n'
	printf 'binary can generate is the shared key:\n\n'
	printf '  openvpn --genkey tls-crypt /etc/openvpn/tc.key\n'
} > "$OUT/README-OPENVPN"
exit 0
