#!/bin/sh
# speedtest-go recipe. Compiles only: the driver has already fetched, verified
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
"$GO" build -trimpath -ldflags '-s -w' -o "$WORK/speedtest" . \
	>"$WORK/build.log" 2>&1 \
	|| { sb_dump_log "$WORK/build.log"; exit 1; }

[ -f "$WORK/speedtest" ] || { printf 'speedtest binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$WORK/speedtest" "$OUT/bin/speedtest"
chmod 755 "$OUT/bin/speedtest"
[ -f LICENSE ] && cp LICENSE "$OUT/SPEEDTEST-LICENSE"
[ -f README.md ] && cp README.md "$OUT/SPEEDTEST-README.md"
exit 0
