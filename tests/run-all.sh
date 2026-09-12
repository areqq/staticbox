#!/bin/sh
# Run every test-*.sh in this directory. Exits non-zero if any fails.
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
	[ -f "$t" ] || continue
	printf '\n== %s\n' "$(basename "$t")"
	sh "$t" || rc=1
done
exit "$rc"
