#!/bin/sh
# iperf3 recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# --without-openssl drops the authentication feature, which is the only thing
# iperf3 uses OpenSSL for -- RSA-encrypted username/password between client and
# server. Ten minutes of cross-building OpenSSL per target to password-protect
# a throughput test is not a trade worth making; the test is between two
# machines you already control.
#
# --without-sctp: SCTP needs kernel support these boxes do not ship, and a
# probe that finds the *build host's* headers would enable a transport the
# device cannot use.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--without-openssl --without-sctp \
	--disable-shared --enable-static \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

BIN='src/iperf3'
[ -f "$BIN" ] || { printf 'iperf3 binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/iperf3"
chmod 755 "$OUT/bin/iperf3"
[ -f LICENSE ] && cp LICENSE "$OUT/IPERF3-LICENSE"

{
	printf 'Both ends are this same binary. On the machine being measured\n'
	printf 'against:\n\n'
	printf '  iperf3 -s\n\n'
	printf 'and on the other:\n\n'
	printf '  iperf3 -c <that-host>          upload\n'
	printf '  iperf3 -c <that-host> -R       download\n'
	printf '  iperf3 -c <that-host> -u -b 50M   UDP, which is what a stream is\n\n'
	printf 'The UDP run is the one that matters for a stuttering picture: it\n'
	printf 'reports jitter and lost datagrams, and TCP throughput can look\n'
	printf 'fine while those do not.\n'
} > "$OUT/README-IPERF3"
exit 0
