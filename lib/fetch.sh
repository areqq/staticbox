# lib/fetch.sh -- get a package's source, verified, unpacked and patched.
#
# Sourced, not executed. Requires lib/log.sh.
#
# Every source is pinned by SHA-256. There is no mode that skips the check:
# these binaries are handed to devices that cannot be inspected afterwards, so
# "which bytes did this come from" has to have an answer.

# sb_fetch <url...> <sha256> <cache_dir> <dest_dir> [patch_dir]
#
# The url argument may be a space-separated list, tried in order until one
# downloads. A mirror costs nothing in trust here: the checksum decides whether
# the bytes are right, so where they came from does not matter. This is not
# hypothetical -- dropbear's own host answers GitHub runners with a Cloudflare
# 525 while serving a developer machine perfectly well, and a build that works
# locally and never in CI is worse than one that fails everywhere.
sb_fetch() {
	sb__urls="$1"; sb__sha="$2"; sb__cache="$3"; sb__dest="$4"; sb__patches="${5:-}"
	# The cache filename comes from the first URL, so a fallback does not
	# produce a second copy of identical bytes under a different name.
	sb__url="${sb__urls%% *}"

	case "$sb__sha" in
		*[!0-9a-f]*|'') die "source checksum is missing or not lowercase hex: '$sb__sha'" ;;
	esac
	[ "$(printf '%s' "$sb__sha" | wc -c | tr -d ' ')" -eq 64 ] \
		|| die "source checksum is not 64 hex digits: '$sb__sha'"

	sb__file="$sb__cache/$(basename "$sb__url")"
	mkdir -p "$sb__cache"
	if [ ! -f "$sb__file" ]; then
		log "fetching $(basename "$sb__url")"
		sb__got=0
		for sb__u in $sb__urls; do
			if curl -fsSL -o "$sb__file" "$sb__u"; then sb__got=1; break; fi
			rm -f "$sb__file"
			warn "download failed, trying the next source: $sb__u"
		done
		[ "$sb__got" = '1' ] || die "every source failed for $(basename "$sb__url")"
	fi

	# On a mismatch the cached file is removed. Leaving it there turns one bad
	# download into a permanently poisoned cache that fails identically on
	# every later run, which is a miserable thing to debug.
	if ! printf '%s  %s\n' "$sb__sha" "$sb__file" | sha256sum -c --quiet - 2>/dev/null; then
		rm -f "$sb__file"
		die "checksum mismatch for $(basename "$sb__url") -- expected $sb__sha"
	fi

	rm -rf "$sb__dest"
	mkdir -p "$sb__dest"
	tar xf "$sb__file" -C "$sb__dest" --strip-components=1 \
		|| die "cannot unpack $(basename "$sb__url")"

	[ -n "$sb__patches" ] || return 0
	[ -d "$sb__patches" ] || return 0
	for sb__p in "$sb__patches"/*.patch; do
		[ -f "$sb__p" ] || continue
		log "applying $(basename "$sb__p")"
		patch -p1 -d "$sb__dest" < "$sb__p" >/dev/null \
			|| die "patch failed to apply: $(basename "$sb__p")"
	done
}
