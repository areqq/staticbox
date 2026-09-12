# Shared assertions for the staticbox test suite. Sourced, not executed.
CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else
		fail "$1"; printf '       expected: %s\n       actual:   %s\n' "$3" "$2"
	fi
}

assert_ok() {
	if "$@" >/dev/null 2>&1; then pass "$1 exits 0"; else fail "$1 exits 0"; fi
}

assert_fails() {
	if "$@" >/dev/null 2>&1; then fail "$1 exits non-zero"; else pass "$1 exits non-zero"; fi
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
