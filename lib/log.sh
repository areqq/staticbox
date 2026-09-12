# Shared output helpers. Sourced, not executed.
# SB_PROG is set by whoever sources this; it prefixes every diagnostic so a
# failure in a nested build names the layer it came from.
: "${SB_PROG:=staticbox}"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '%s: %s\n' "$SB_PROG" "$*" >&2; }
die()  { printf '%s: %s\n' "$SB_PROG" "$*" >&2; exit 1; }
