#!/bin/sh
# wireguard-go recipe. Compiles only: the driver has already fetched, verified
# and unpacked the source, and set up the Go toolchain.
#
# Given: TARGET VARIANT SRC WORK OUT GO GOROOT GOPATH GOCACHE GOOS GOARCH
#        CGO_ENABLED, plus GOARM/GOMIPS/GO386 where the target needs them.
#
# No C compiler is involved at all: CC and friends are deliberately empty for
# this backend.
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# -trimpath keeps the build reproducible by stripping the sandbox paths out of
# the binary; -s -w drop the symbol table and DWARF, which is most of the size.
# Dependencies come down verified against the module's own go.sum.
"$GO" build -trimpath -ldflags '-s -w' -o "$WORK/wireguard-go" . \
	>"$WORK/build.log" 2>&1 \
	|| { sb_dump_log "$WORK/build.log"; exit 1; }

[ -f "$WORK/wireguard-go" ] || { printf 'wireguard-go binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$WORK/wireguard-go" "$OUT/bin/wireguard-go"
chmod 755 "$OUT/bin/wireguard-go"
[ -f LICENSE ] && cp LICENSE "$OUT/WIREGUARD-GO-LICENSE"

{
	printf 'wireguard-go moves the packets; it does not configure anything.\n'
	printf 'Bring a tunnel up with it and the wg tool from the\n'
	printf 'wireguard-tools package:\n\n'
	printf '  wireguard-go wg0                 # creates the interface\n'
	printf '  wg setconf wg0 /path/to/wg0.conf # keys, peers, endpoint\n'
	printf '  ip addr add 10.0.0.2/24 dev wg0  # busybox ip will do\n'
	printf '  ip link set up dev wg0\n\n'
	printf 'It needs /dev/net/tun. If that is missing the daemon exits with\n'
	printf 'an error about creating the TUN device. No binary can fix that:\n'
	printf 'the tun driver has to be in the kernel.\n\n'
	printf 'It daemonises by default. Use -f to keep it in the foreground,\n'
	printf 'which is what you want while finding out whether it works.\n'
} > "$OUT/README-WIREGUARD-GO"
exit 0
