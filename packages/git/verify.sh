#!/bin/sh
# Deep check for git: assert the two things that break silently.
#
# The generic gate proves each binary is for the right architecture and runs.
# It cannot see either of the failures this package actually has:
#
#  1. git's Makefile decides at build time whether libcurl was found. When it
#     was not, the build succeeds, every binary the gate inspects is perfect,
#     and git-remote-https simply does not exist -- so the first `git clone
#     https://...` on the device dies with "Unable to find remote helper for
#     'https'", which is the whole reason this package exists.
#
#  2. RUNTIME_PREFIX is what lets the tarball be unpacked anywhere. Lose it and
#     git looks for its helpers and templates under the prefix it was compiled
#     with, which on a device is a path that does not exist. The binary still
#     runs and still prints its version, so nothing before this notices.
#
# Given: TARGET VARIANT OUT, and the matrix through targets.sh.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$HERE/targets.sh"

BIN="$OUT/bin/git"
[ -f "$BIN" ] || { printf 'verify: no git at %s\n' "$BIN" >&2; exit 1; }

HELPER="$OUT/libexec/git-core/git-remote-https"
[ -f "$HELPER" ] || {
	printf 'verify: no git-remote-https -- this git cannot fetch over https\n' >&2
	exit 1; }

[ -d "$OUT/share/git-core/templates" ] || {
	printf 'verify: no templates directory; git init would produce an empty .git\n' >&2
	exit 1; }

QEMU="$(sb_target_field "$TARGET" qemu)"
QCPU="$(sb_target_field "$TARGET" qemu_cpu)"
if ! command -v "$QEMU" >/dev/null 2>&1; then
	printf 'verify: %s not installed, skipping the deep check\n' "$QEMU" >&2
	exit 0
fi

# Everything below runs one process at a time. git execs its helpers by path,
# and an exec of a foreign binary only works where binfmt_misc has qemu
# registered -- which is not something this check may assume. So each program
# is invoked directly under qemu instead of letting git spawn it.
run() {
	if [ -n "$QCPU" ]; then "$QEMU" -cpu "$QCPU" "$@"; else "$QEMU" "$@"; fi
}

# -- 1. RUNTIME_PREFIX ------------------------------------------------------
# $OUT is not the prefix git was configured with, so an exec-path that lands
# inside it can only have been resolved at run time from /proc/self/exe.
EXECPATH="$(run "$BIN" --exec-path 2>&1 || true)"
case "$EXECPATH" in
	"$OUT"/*) : ;;
	*) printf 'verify: exec-path is %s, outside %s -- RUNTIME_PREFIX did not take\n' \
		"$EXECPATH" "$OUT" >&2; exit 1 ;;
esac

# -- 2. the https helper runs and reaches the transport ---------------------
# Handed a `list` command on stdin it tries to connect, which is as far as a
# check with no server can go -- and far enough: reaching a connection error
# means libcurl is linked, initialised and running, not merely present on disk.
# Port 1 refuses immediately, so this cannot hang.
PROBE="$(printf 'list\n' | run "$HELPER" origin https://127.0.0.1:1/x.git 2>&1 || true)"
case "$PROBE" in
	*'unable to access'*) : ;;
	*) printf 'verify: git-remote-https did not reach the transport: %s\n' "$PROBE" >&2
	   exit 1 ;;
esac

# -- 3. TLS is really in there ----------------------------------------------
# curl fails its own configure when no TLS backend is selected, so a helper
# without OpenSSL is not the likely accident -- but it is the one that would
# turn every https URL into a plaintext refusal on the device, and it costs a
# grep to rule out. These strings come from curl's OpenSSL backend and exist
# only when that backend was compiled in.
if command -v strings >/dev/null 2>&1; then
	strings -a "$HELPER" | grep -q 'OpenSSL' || {
		printf 'verify: git-remote-https carries no OpenSSL; https would not verify\n' >&2
		exit 1; }
fi

# -- 4. the object store works ----------------------------------------------
# git init is a builtin, so this stays one process. It exercises the templates
# found in step 1 and writes a real repository, which is the smallest thing
# that proves more than "the binary starts".
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && HOME="$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
	run "$BIN" init -q r >/dev/null 2>&1 ) || {
	printf 'verify: git init failed\n' >&2; exit 1; }
[ -f "$TMP/r/.git/HEAD" ] || {
	printf 'verify: git init produced no .git/HEAD\n' >&2; exit 1; }

printf 'verify: git can fetch over https and relocates for %s\n' "$TARGET"
