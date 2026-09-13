#!/bin/sh
# Deep check for nmap: assert what the variant promised.
#
# The generic gate proves the binary is for the right architecture and runs.
# It cannot know that `full` was supposed to contain OpenSSL and libssh2 --
# and that is precisely what fails silently, because a full build whose
# configure quietly failed to find them still produces a working nmap, just
# one where every ssl-* and ssh-* NSE script is missing.
#
# Given: TARGET VARIANT OUT, and the matrix through targets.sh.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$HERE/targets.sh"

BIN="$OUT/bin/nmap"
[ -f "$BIN" ] || { printf 'verify: no nmap at %s\n' "$BIN" >&2; exit 1; }

QEMU="$(sb_target_field "$TARGET" qemu)"
QCPU="$(sb_target_field "$TARGET" qemu_cpu)"
if ! command -v "$QEMU" >/dev/null 2>&1; then
	printf 'verify: %s not installed, skipping the deep check\n' "$QEMU" >&2
	exit 0
fi

if [ -n "$QCPU" ]; then
	VER="$("$QEMU" -cpu "$QCPU" "$BIN" --version 2>&1)"
else
	VER="$("$QEMU" "$BIN" --version 2>&1)"
fi

case "$VARIANT" in
full)
	# "Compiled without:" must be empty. nmap prints the list of things it
	# could not find on that line, so anything after it is a missing library.
	missing="$(printf '%s\n' "$VER" | sed -n 's/^Compiled without: *//p')"
	if [ -n "$missing" ]; then
		printf 'verify: the full variant is missing: %s\n' "$missing" >&2
		exit 1
	fi
	for want in openssl libssh2; do
		printf '%s\n' "$VER" | grep -q "$want" || {
			printf 'verify: the full variant does not report %s\n' "$want" >&2
			exit 1; }
	done
	;;
lean)
	# The mirror image: lean must NOT have dragged in OpenSSL, or it is not
	# lean and the size and the licence story are both wrong.
	printf '%s\n' "$VER" | grep -q '^Compiled without:.*openssl' || {
		printf 'verify: the lean variant reports openssl; it should not have it\n' >&2
		exit 1; }
	;;
esac

# NSE needs its data files beside the binary, and a build that forgot to copy
# them produces a scanner that cannot run a single script.
for f in nmap-services nmap-service-probes nmap-os-db; do
	[ -f "$OUT/share/nmap/$f" ] || {
		printf 'verify: missing data file %s\n' "$f" >&2; exit 1; }
done
[ -d "$OUT/share/nmap/scripts" ] || {
	printf 'verify: missing the NSE script directory\n' >&2; exit 1; }

printf 'verify: nmap %s looks right for %s\n' "${VARIANT:-lean}" "$TARGET"
