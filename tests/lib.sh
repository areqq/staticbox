# Shared assertions for the staticbox test suite. Sourced, not executed.
CHECKS=0
FAILURES=0

# Real statically linked binaries for foreign architectures. They exist to
# check the gate and the detector against something this repo did not build in
# the same breath -- a fixture that came out of the same toolchain would agree
# with it for the wrong reasons.
#
# There is deliberately no default path. Point these at any static mipsel and
# 32-bit ARM binary; unpacking one of this repo's own release tarballs is the
# easy way:
#
#   SB_FIXTURE_MIPSEL=/tmp/u/bin/busybox sh tests/run-all.sh
#
# Unset, the checks that need them are skipped -- which is what happens on a
# clean checkout and on a CI runner.
# Read by the test files that source this one, which the linter cannot see.
# shellcheck disable=SC2034
FIX_MIPSEL="${SB_FIXTURE_MIPSEL:-}"
# shellcheck disable=SC2034
FIX_ARM="${SB_FIXTURE_ARM:-}"

note_no_fixture() {
	printf '  skip %s fixture checks; set %s to a static %s binary to run them\n' \
		"$1" "$2" "$1"
}

pass() { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else
		fail "$1"; printf '       expected: %s\n       actual:   %s\n' "$3" "$2"
	fi
}

# Both run the command in a subshell. Library functions call die(), which
# exits, and without the subshell that would take the test run down with it
# instead of registering as a failed assertion.
assert_ok() {
	if ( "$@" ) >/dev/null 2>&1; then pass "$1 exits 0"; else fail "$1 exits 0"; fi
}

assert_fails() {
	if ( "$@" ) >/dev/null 2>&1; then fail "$1 exits non-zero"; else pass "$1 exits non-zero"; fi
}

assert_contains() {
	case "$2" in
		*"$3"*) pass "$1" ;;
		*) fail "$1"; printf '       %s does not contain %s\n' "$2" "$3" ;;
	esac
}

report() {
	printf '%s: %d checks, %d failures\n' "$1" "$CHECKS" "$FAILURES"
	[ "$FAILURES" -eq 0 ]
}
