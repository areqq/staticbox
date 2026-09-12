#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

J="$(sh "$ROOT/ci/matrix.sh" dsvpn)"
assert_contains 'matrix is an include list' "$J" '"include"'
assert_contains 'names the package'         "$J" '"package":"dsvpn"'
assert_contains 'covers mipsel'             "$J" '"target":"mipsel"'
assert_contains 'covers the arm baseline'   "$J" '"target":"armv7"'
assert_contains 'covers the neon target'    "$J" '"target":"armv7-neon"'

# armv7-aes is disabled: it must never reach CI, or every run pays for a
# ninth of the matrix that ships to nobody.
case "$J" in
	*armv7-aes*) fail 'disabled target leaked into the matrix' ;;
	*) pass 'disabled target stays out of the matrix' ;;
esac

# It has to be one line: GitHub Actions reads it through $GITHUB_OUTPUT, which
# is line-based, and a pretty-printed JSON silently truncates there.
assert_eq 'matrix is a single line' "$(printf '%s' "$J" | wc -l | tr -d ' ')" '0'

# It also has to be valid JSON, or fromJSON fails at run time with a message
# that says nothing useful.
if have_py=$(command -v python3); then
	assert_ok "$have_py" -c "import json,sys; json.loads(sys.argv[1])" "$J"
fi

assert_eq 'eight entries for dsvpn' \
	"$(printf '%s' "$J" | tr ',' '\n' | grep -c '"target"')" '8'

report test-ci-matrix
