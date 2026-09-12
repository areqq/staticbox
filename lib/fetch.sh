# lib/fetch.sh -- get a package's source, verified, unpacked and patched.
#
# Sourced, not executed. Requires lib/log.sh.
#
# Every source is pinned by SHA-256. There is no mode that skips the check:
# these binaries are handed to devices that cannot be inspected afterwards, so
# "which bytes did this come from" has to have an answer.

# sb_fetch <url> <sha256> <cache_dir> <dest_dir> [patch_dir]
sb_fetch() {
	sb__url="$1"; sb__sha="$2"; sb__cache="$3"; sb__dest="$4"; sb__patches="${5:-}"

	case "$sb__sha" in
		*[!0-9a-f]*|'') die "source checksum is missing or not lowercase hex: '$sb__sha'" ;;
	esac
	[ "$(printf '%s' "$sb__sha" | wc -c | tr -d ' ')" -eq 64 ] \
		|| die "source checksum is not 64 hex digits: '$sb__sha'"

	sb__file="$sb__cache/$(basename "$sb__url")"
	mkdir -p "$sb__cache"
	if [ ! -f "$sb__file" ]; then
		log "fetching $(basename "$sb__url")"
		curl -fsSL -o "$sb__file" "$sb__url" || { rm -f "$sb__file"; die "download failed: $sb__url"; }
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
