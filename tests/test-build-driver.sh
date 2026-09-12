#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

TMP="${TMPDIR:-/tmp}/sb-driver-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/packages/fake"
cat > "$TMP/packages/fake/meta" <<'EOF'
PKG=fake
VERSION=1.0
REVISION=1
SOURCE=file:///dev/null
SHA256=0000000000000000000000000000000000000000000000000000000000000000
TARGETS='mipsel armv7'
SMOKE='--version'
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/packages/fake/build.sh"
chmod +x "$TMP/packages/fake/build.sh"

OUT="$(SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake --list 2>&1)"
assert_contains 'lists the targets the package declares' "$OUT" 'mipsel'
assert_contains 'lists both of them'                     "$OUT" 'armv7'
assert_eq 'lists exactly two' "$(printf '%s\n' "$OUT" | grep -c '^  ')" '2'

assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" nosuchpkg --list
assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake nosucharch
# aarch64 is a real target but not one this package declares.
assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake aarch64

rm -rf "$TMP"
report test-build-driver
