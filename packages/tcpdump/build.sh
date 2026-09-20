#!/bin/sh
# tcpdump recipe. Compiles only: the driver has already fetched, verified and
# unpacked tcpdump and libpcap.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS DEP_PREFIX SRC_libpcap
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

JOBS="$(nproc 2>/dev/null || echo 2)"

# ------------------------------------------------------------------ libpcap
# ac_cv_linux_vers=2 answers a probe that reads the *running* kernel's version,
# which says nothing about the device's. packages/nmap needs the same answer
# for the same probe in its bundled copy.
#
# Every capture backend beyond the plain Linux one is off, and each for a
# concrete reason rather than tidiness: usb, bluetooth, dbus and rdma each
# want a library that is not cross-built here, netmap wants a kernel module
# these boxes do not have, dpdk is a userspace NIC driver framework aimed at
# server hardware, and libnl is what would pull netlink in for mac80211
# monitor mode -- a wireless feature on devices whose wireless, where it
# exists, is a USB dongle in managed mode.
#
# SRC_libpcap is exported by the driver for the dep declared in meta, which the
# linter has no way to see.
# shellcheck disable=SC2154
( cd "$SRC_libpcap"
  ./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--prefix="$DEP_PREFIX" --disable-shared \
	--without-libnl --disable-usb --disable-bluetooth \
	--disable-dbus --disable-rdma --disable-netmap \
	ac_cv_linux_vers=2 \
	>"$WORK/libpcap-configure.log" 2>&1
  make -j"$JOBS" >"$WORK/libpcap-make.log" 2>&1
  make install >>"$WORK/libpcap-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/libpcap-make.log"; sb_dump_log "$WORK/libpcap-configure.log"; exit 1; }

# ------------------------------------------------------------------ tcpdump
cd "$SRC"

# --disable-local-libpcap stops configure looking for a libpcap *source tree*
# beside tcpdump's own, which is how the two are usually built together. The
# one we want is the installed one in the staging prefix, reached through
# CPPFLAGS and LDFLAGS.
#
# --without-crypto drops ESP payload decryption, the only thing tcpdump uses
# libcrypto for. It would mean cross-building OpenSSL -- ten minutes a target --
# so that tcpdump can decrypt IPsec traffic whose keys someone typed on the
# command line, which is not what anyone does on a receiver.
#
# --without-smi drops loading SNMP MIBs from files at runtime.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -L$DEP_PREFIX/lib" \
	CPPFLAGS="-I$DEP_PREFIX/include" \
	--disable-local-libpcap --without-crypto --without-smi \
	ac_cv_linux_vers=2 \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$JOBS" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f tcpdump ] || { printf 'tcpdump binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp tcpdump "$OUT/bin/tcpdump"
chmod 755 "$OUT/bin/tcpdump"
[ -f LICENSE ] && cp LICENSE "$OUT/TCPDUMP-LICENSE"

{
	printf 'Needs root, and a kernel with packet sockets -- every Linux has\n'
	printf 'them, so in practice it is root that is the condition.\n\n'
	printf 'What it is for on a receiver:\n\n'
	printf '  tcpdump -i eth0 -n host <server>      is anything arriving\n'
	printf '  tcpdump -i eth0 -n "udp and multicast"   is the stream there\n'
	printf '  tcpdump -i eth0 -n igmp               is the box asking for it\n'
	printf '  tcpdump -i eth0 -n -w /tmp/c.pcap     capture, read elsewhere\n\n'
	printf 'That last one is usually the right move: write the file on the\n'
	printf 'box and open it in Wireshark on a machine with a screen.\n\n'
	printf 'ESP decryption is not compiled in -- it needs OpenSSL and keys on\n'
	printf 'the command line, which is not what a receiver is doing.\n'
} > "$OUT/README-TCPDUMP"
exit 0
