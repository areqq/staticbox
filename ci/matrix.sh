#!/bin/sh
# ci/matrix.sh -- emit the GitHub Actions build matrix as one line of JSON.
#
#   ci/matrix.sh [package...]     with none, every package
#
# A static workflow file per package was the alternative and was rejected: at
# nine targets and a growing package list it is N YAML files to keep in sync by
# hand every time the matrix changes, which is precisely the class of drift
# this repo exists to end.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$HERE/targets.sh"

PACKAGES="${*:-}"
if [ -z "$PACKAGES" ]; then
	for d in "$HERE"/packages/*/; do
		[ -f "$d/meta" ] && PACKAGES="$PACKAGES $(basename "$d")"
	done
fi

first=1
printf '{"include":['
for pkg in $PACKAGES; do
	[ -f "$HERE/packages/$pkg/meta" ] || continue
	TARGETS='all'; VARIANTS=''
	# shellcheck disable=SC1090,SC1091
	. "$HERE/packages/$pkg/meta"

	if [ "$TARGETS" = 'all' ]; then
		tlist="$(sb_targets_enabled)"
	else
		tlist=''
		for t in $TARGETS; do
			[ "$(sb_target_field "$t" enabled 2>/dev/null)" = '1' ] && tlist="$tlist $t"
		done
	fi

	vlist="${VARIANTS:-_}"
	for t in $tlist; do
		for v in $vlist; do
			[ "$v" = '_' ] && v=''
			if [ -n "$v" ]; then
				eval "vt=\${VARIANT_TARGETS_$v:-}"
				# shellcheck disable=SC2086  # $vt is a word list on purpose
				if [ -n "$vt" ] && ! printf '%s\n' $vt | grep -qx "$t"; then continue; fi
			fi
			[ "$first" = '1' ] || printf ','
			first=0
			printf '{"package":"%s","target":"%s","variant":"%s"}' "$pkg" "$t" "$v"
		done
	done
done
printf ']}'
