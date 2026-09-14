#!/bin/sh
# wireguard-tools recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC/src"

# CFLAGS and LDFLAGS travel in the environment and are deliberately NOT passed
# on the make command line. The Makefile says `CFLAGS ?= -O3` and then appends
# to it: -isystem uapi/linux for the bundled kernel headers, -std=gnu99,
# -D_GNU_SOURCE and -DRUNSTATEDIR. A command-line CFLAGS= would override the
# lot and take those additions with it, and the build would fail on the first
# kernel header it could not find.
#
# The three WITH_* are the opposite case: the Makefile decides them by looking
# at the *build host* -- whether /usr/bin/bash exists, whether a bash-completion
# directory exists, what pkg-config says about systemd. Every one of those
# questions is about this machine and none of them is about the target, so all
# three are answered here rather than discovered.
make -j"$(nproc 2>/dev/null || echo 2)" \
	CC="$CC" \
	WITH_WGQUICK=no WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no \
	PLATFORM=linux \
	>"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f wg ] || { printf 'wg binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp wg "$OUT/bin/wg"
chmod 755 "$OUT/bin/wg"
[ -f "$SRC/COPYING" ] && cp "$SRC/COPYING" "$OUT/WIREGUARD-TOOLS-LICENSE"

{
	printf 'wg configures a tunnel; something else has to carry the packets.\n'
	printf 'It drives the kernel module over netlink where the box has one,\n'
	printf 'and the wireguard-go daemon over its socket where it does not --\n'
	printf 'the same commands either way.\n\n'
	printf 'A tunnel from nothing:\n\n'
	printf '  wg genkey | tee private.key | wg pubkey > public.key\n'
	printf '  wireguard-go wg0                  # or: ip link add wg0 type wireguard\n'
	printf '  wg set wg0 private-key ./private.key \\\n'
	printf '         peer <THEIR_PUBKEY> endpoint <HOST>:51820 \\\n'
	printf '         allowed-ips 10.0.0.0/24 persistent-keepalive 25\n'
	printf '  ip addr add 10.0.0.2/24 dev wg0   # busybox ip will do\n'
	printf '  ip link set up dev wg0\n\n'
	printf 'wg show tells you whether a handshake happened. No handshake and\n'
	printf 'no error usually means UDP is not reaching the endpoint.\n'
} > "$OUT/README-WIREGUARD-TOOLS"
exit 0
