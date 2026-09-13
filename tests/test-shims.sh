#!/bin/sh
# The toolchain's shim sources exist and carry their own self-test, which
# lib/toolchain.sh runs under qemu at build time. This checks the wiring: that
# the sources are there, that each has a test beside it, and that the matrix
# targets they compensate for are the ones that need them.
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
SHIMS="$HERE/../lib/shims"

for s in mips-o32-pipe arm-pre-v6-sync; do
	assert_eq "$s source is present" "$(test -f "$SHIMS/$s.c" && echo yes)" 'yes'
	# A shim that silently returns the wrong value links cleanly and fails
	# somewhere else entirely, so each one must carry a test asserting its
	# semantics rather than merely that it compiles.
	assert_eq "$s has a self-test" "$(test -f "$SHIMS/$s-test.c" && echo yes)" 'yes'
done

# The pipe shim is MIPS-only and says so at compile time; the sync shim is for
# pre-ARMv6. Guard against either being wired to the wrong target later.
assert_contains 'the pipe shim refuses non-MIPS' \
	"$(cat "$SHIMS/mips-o32-pipe.c")" '__mips__'
assert_contains 'the sync shim names the ARMv5 case' \
	"$(cat "$SHIMS/arm-pre-v6-sync.c")" 'sync'

# lib/toolchain.sh must apply them to exactly the targets that need them.
TC="$(cat "$HERE/../lib/toolchain.sh")"
assert_contains 'pipe shim is wired to mips and mipsel' "$TC" 'mips|mipsel)'
assert_contains 'sync shim is wired to armv5'           "$TC" 'armv5)'

report test-shims
