#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/fetch.sh"

TMP="${TMPDIR:-/tmp}/sb-fetch-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/src/inner" "$TMP/cache" "$TMP/patches"
printf 'original\n' > "$TMP/src/inner/hello.txt"
( cd "$TMP/src" && tar czf "$TMP/pkg.tar.gz" inner )
SHA="$(sha256sum "$TMP/pkg.tar.gz" | cut -d' ' -f1)"
URL="file://$TMP/pkg.tar.gz"

sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-good" >/dev/null 2>&1
assert_eq 'strip-components lands content at the top' \
	"$(cat "$TMP/out-good/hello.txt" 2>/dev/null)" 'original'

assert_fails sb_fetch "$URL" '0000000000000000000000000000000000000000000000000000000000000000' \
	"$TMP/cache-bad" "$TMP/out-bad"
assert_eq 'a bad checksum leaves nothing cached' \
	"$(ls "$TMP/cache-bad" 2>/dev/null | wc -l | tr -d ' ')" '0'

cat > "$TMP/patches/0001-change.patch" <<'EOF'
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-original
+patched
EOF
sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-patched" "$TMP/patches" >/dev/null 2>&1
assert_eq 'patches are applied' "$(cat "$TMP/out-patched/hello.txt" 2>/dev/null)" 'patched'

# A patch that does not apply must stop the build, not warn and continue: a
# silently skipped patch produces a binary that is wrong in a way nothing else
# will catch.
printf 'bad patch\n' > "$TMP/patches/0002-broken.patch"
assert_fails sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-broken" "$TMP/patches"

rm -rf "$TMP"
report test-fetch
