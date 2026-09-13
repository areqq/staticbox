# Shared output helpers. Sourced, not executed.
# SB_PROG is set by whoever sources this; it prefixes every diagnostic so a
# failure in a nested build names the layer it came from.
: "${SB_PROG:=staticbox}"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '%s: %s\n' "$SB_PROG" "$*" >&2; }
die()  { printf '%s: %s\n' "$SB_PROG" "$*" >&2; exit 1; }

# sb_dump_log <file> [lines] -- print a failed build's log to stderr usefully.
#
# Grepping for "error" is what this replaces, and it was worse than useless:
# ffmpeg has files called error.c and error_resilience.c, so the filter matched
# twenty compile lines and pushed the actual message out of view. A failing
# make puts the real reason at the end, so the tail is what gets shown, with
# any line that genuinely looks like a diagnostic pulled out above it.
sb_dump_log() {
	sb__lf="$1"; sb__ln="${2:-30}"
	[ -f "$sb__lf" ] || return 0
	sb__hits="$(grep -nE '(^|[[:space:]])(error|fatal error|undefined reference|undefined symbol):' "$sb__lf" | head -10)"
	if [ -n "$sb__hits" ]; then
		printf -- '--- diagnostics in %s ---\n' "$sb__lf" >&2
		printf '%s\n' "$sb__hits" >&2
	fi
	printf -- '--- last %s lines of %s ---\n' "$sb__ln" "$sb__lf" >&2
	tail -n "$sb__ln" "$sb__lf" >&2
}
