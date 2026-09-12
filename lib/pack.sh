# lib/pack.sh -- package a built staging directory for release.
#
# Sourced, not executed. Requires lib/log.sh.
#
# Every tarball carries a MANIFEST. The reason is concrete: the directories
# this repo replaces are full of binaries named things like `nmap-noneon` that
# carry no record of which compiler, which flags or which source produced
# them. A binary found on a box a year from now has to be reproducible, and
# that means the answer travels with the binary rather than living in a build
# log that was thrown away.

# sb_pack <stage_dir> <out_dir> <pkg> <version> <revision> <target> <variant>
sb_pack() {
	sb__stage="$1"; sb__out="$2"; sb__pkg="$3"; sb__ver="$4"
	sb__rev="$5"; sb__tgt="$6"; sb__var="$7"

	[ -d "$sb__stage" ] || die "nothing staged at $sb__stage"

	sb__name="$sb__pkg-$sb__ver-$sb__tgt"
	[ -n "$sb__var" ] && sb__name="$sb__name-$sb__var"

	{
		printf 'package: %s\n'    "$sb__pkg"
		printf 'version: %s\n'    "$sb__ver"
		printf 'revision: %s\n'   "$sb__rev"
		printf 'target: %s\n'     "$sb__tgt"
		printf 'variant: %s\n'    "${sb__var:--}"
		printf 'toolchain: %s\n'  "${SB_BACKEND:-unknown}"
		printf 'cflags: %s\n'     "${CFLAGS:-}"
		printf 'ldflags: %s\n'    "${LDFLAGS:-}"
		printf 'source_sha256: %s\n' "${SB_SOURCE_SHA:-unknown}"
		printf 'built: %s\n'      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'staticbox_commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
	} > "$sb__stage/MANIFEST"

	mkdir -p "$sb__out"
	sb__tarball="$sb__out/$sb__name.tar.gz"
	rm -f "$sb__tarball"
	# Packed from inside the staging directory so the archive has no leading
	# path component of its own; get.sh unpacks into a directory it chose.
	tar czf "$sb__tarball" -C "$sb__stage" . || die "cannot create $sb__tarball"
	( cd "$sb__out" && sha256sum "$sb__name.tar.gz" > "$sb__name.tar.gz.sha256" )

	printf '%s\n' "$sb__tarball"
}
