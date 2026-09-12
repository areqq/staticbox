#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/pack.sh"

TMP="${TMPDIR:-/tmp}/sb-pack-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/stage/bin" "$TMP/out"
printf 'fake\n' > "$TMP/stage/bin/dsvpn"
export CFLAGS='-Os -mcpu=mips32' LDFLAGS='-static' SB_BACKEND='zig' SB_SOURCE_SHA='abc123'

TB="$(sb_pack "$TMP/stage" "$TMP/out" dsvpn 0.1.4 1 mipsel '')"
assert_eq 'tarball is named from pkg, version and target' \
	"$(basename "$TB")" 'dsvpn-0.1.4-mipsel.tar.gz'
assert_eq 'a checksum file sits beside it' \
	"$(test -f "$TB.sha256" && echo yes)" 'yes'
assert_eq 'the checksum matches the tarball' \
	"$(cd "$TMP/out" && sha256sum -c --quiet "$(basename "$TB").sha256" >/dev/null 2>&1 && echo ok)" 'ok'

MAN="$(tar xzf "$TB" -O './MANIFEST' 2>/dev/null || tar xzf "$TB" -O 'MANIFEST')"
assert_contains 'manifest records the target'   "$MAN" 'target: mipsel'
assert_contains 'manifest records the backend'  "$MAN" 'toolchain: zig'
assert_contains 'manifest records the cflags'   "$MAN" '-mcpu=mips32'
assert_contains 'manifest records source sha'   "$MAN" 'abc123'

TBV="$(sb_pack "$TMP/stage" "$TMP/out" nmap 7.95 1 mipsel full)"
assert_eq 'a variant becomes a name suffix' \
	"$(basename "$TBV")" 'nmap-7.95-mipsel-full.tar.gz'

rm -rf "$TMP"
report test-pack
