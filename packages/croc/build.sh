#!/bin/sh
# croc recipe. Compiles only: the driver has already fetched, verified and
# unpacked the source, and set up the Go toolchain.
#
# Given: TARGET VARIANT SRC WORK OUT GO GOROOT GOPATH GOCACHE GOOS GOARCH
#        CGO_ENABLED, plus GOARM/GOMIPS/GO386 where the target needs them.
#
# No C compiler is involved at all: CC and friends are deliberately empty for
# this backend.
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# The flags upstream's own Makefile uses, for the reasons that matter here:
#
#   -trimpath        strips the sandbox paths out of the binary.
#   -s -w            drop the symbol table and DWARF, most of the size.
#   -buildvcs=false  there is no VCS in a release tarball, and asking Go to
#                    look for one finds *this* repository instead -- the same
#                    false-provenance trap packages/openvpn hit.
#   netgo,osusergo   pure-Go DNS and user lookup rather than the libc ones.
#                    With CGO off these are already the defaults, but naming
#                    them means the build fails loudly rather than quietly
#                    linking a resolver that a static binary cannot use.
#
# The version is a compile-time constant in src/version, not derived from git,
# so it survives being built from a tarball.
"$GO" build -trimpath -buildvcs=false -tags netgo,osusergo \
	-ldflags '-s -w' -o "$WORK/croc" . \
	>"$WORK/build.log" 2>&1 \
	|| { sb_dump_log "$WORK/build.log"; exit 1; }

[ -f "$WORK/croc" ] || { printf 'croc binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$WORK/croc" "$OUT/bin/croc"
chmod 755 "$OUT/bin/croc"
[ -f LICENSE ] && cp LICENSE "$OUT/CROC-LICENSE"

{
	printf 'On the box:\n\n'
	printf '  croc send /media/hdd/movie/something.ts\n\n'
	printf 'It prints a phrase of a few words. On the other machine:\n\n'
	printf '  croc <that-phrase>\n\n'
	printf 'No port forwarding, no account, no key exchanged in advance: the\n'
	printf 'phrase is the secret, and the two ends derive a session key from\n'
	printf 'it with PAKE. When they cannot reach each other directly the\n'
	printf 'traffic goes through a public relay -- which sees ciphertext, not\n'
	printf 'the file, but it does see that a transfer happened and how big it\n'
	printf 'was. Run croc relay yourself if that matters.\n'
} > "$OUT/README-CROC"
exit 0
