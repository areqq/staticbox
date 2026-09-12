#!/bin/sh
# DSVPN recipe. Compiles only: the driver has already fetched, verified,
# unpacked and patched the source, and set up the compiler.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
set -eu

# Upstream's Makefile probes for -march=native/-mtune=native when CFLAGS is
# empty, which is meaningless and wrong under cross-compilation. Passing CFLAGS
# explicitly is what stops it.
#
# It also compiles and links in a single command that never mentions LDFLAGS,
# so -static has to travel in OPTFLAGS or the binary comes out dynamic.
#
# NO_DEFAULT_ROUTES is upstream's own switch for "do not touch the routing
# table". The patch already removed those commands; the define additionally
# drops the re-detection of the gateway on every reconnect, which would shell
# out to `ip route show default` for a value nothing reads any more.
#
# The Makefile ends in a bare `strip`, which on a cross build runs the host's
# and refuses a foreign binary. A shim directory puts the right one first on
# PATH under that name.
mkdir -p "$WORK/shim"
ln -sf "$STRIP" "$WORK/shim/strip"

( cd "$SRC" && PATH="$WORK/shim:$PATH" make \
	CC="$CC" \
	CFLAGS="$CFLAGS -Wall -DNO_DEFAULT_ROUTES" \
	OPTFLAGS="$LDFLAGS" \
	>"$WORK/make.log" 2>&1 ) \
	|| { tail -20 "$WORK/make.log" >&2; exit 1; }

[ -f "$SRC/dsvpn" ] || { printf 'dsvpn binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$SRC/dsvpn" "$OUT/bin/dsvpn"
chmod 755 "$OUT/bin/dsvpn"
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$OUT/DSVPN-README.md"
[ -f "$SRC/LICENSE" ]   && cp "$SRC/LICENSE"   "$OUT/DSVPN-LICENSE"
exit 0
