# lib/toolchain.sh -- turn (target, backend) into a working compiler.
#
# Sourced, not executed. Requires targets.sh and lib/log.sh to be sourced first.
#
# Two backends, and the split is deliberate. `zig cc` is the default: one 55 MB
# download covers every target and builds musl per target into a cache, instead
# of a 75 MB toolchain per architecture. `bootlin` exists because some packages
# are already proven against it -- nmap with OpenSSL and libssh2 is the case
# this was kept for -- and porting a working build to a new compiler is a task
# of its own, not a precondition for this repo.
#
# A recipe never learns which of the two compiled it. That is the whole point:
# moving a package between backends is one line in its `meta`.

SB_ZIG_VER="${SB_ZIG_VER:-0.16.0}"
SB_TC_VER="${SB_TC_VER:-2025.08-1}"
SB_BOOTLIN_BASE='https://toolchains.bootlin.com/downloads/releases/toolchains'

# Pinned from https://ziglang.org/download/index.json. A new zig release needs
# its sums added here; an unpinned download is not accepted.
sb__zig_sha() {
	case "$SB_ZIG_VER::$1" in
		0.16.0::x86_64)  printf '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00\n' ;;
		0.16.0::aarch64) printf 'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17\n' ;;
		*) return 1 ;;
	esac
}

# Flags that every target gets, whatever the backend. -Os plus section
# splitting plus --gc-sections is what keeps these binaries small enough to
# hand to a device with a few megabytes of flash.
SB_COMMON_CFLAGS='-Os -ffunction-sections -fdata-sections'
SB_COMMON_LDFLAGS='-static -Wl,--gc-sections'

# sb_tc_flags <target> <backend> -> the CFLAGS for that pair, on stdout.
# Pure: touches no network and no filesystem, so it can be tested directly.
sb_tc_flags() {
	sb__tgt="$1"; sb__be="$2"
	sb_target_exists "$sb__tgt" || { warn "no such target: $sb__tgt"; return 1; }
	case "$sb__be" in
		zig)     sb__arch="$(sb_target_field "$sb__tgt" zig_cpu)" ;;
		bootlin) sb__arch="$(sb_target_field "$sb__tgt" bootlin_flags)" ;;
		*) warn "no such backend: $sb__be"; return 1 ;;
	esac
	printf '%s %s\n' "$SB_COMMON_CFLAGS" "$sb__arch" | sed 's/  */ /g; s/ $//'
}

# sb__zig_fetch <cache_dir> -> path to the zig binary, downloading if needed.
sb__zig_fetch() {
	sb__cache="$1"
	sb__host="$(uname -m)"
	sb__sha="$(sb__zig_sha "$sb__host")" \
		|| die "no pinned zig $SB_ZIG_VER checksum for build host $sb__host"
	sb__name="zig-$sb__host-linux-$SB_ZIG_VER"
	sb__dir="$sb__cache/$sb__name"
	if [ ! -x "$sb__dir/zig" ]; then
		log "fetching $sb__name"
		mkdir -p "$sb__cache"
		curl -fsSL -o "$sb__cache/$sb__name.tar.xz" \
			"https://ziglang.org/download/$SB_ZIG_VER/$sb__name.tar.xz" \
			|| die 'zig download failed'
		printf '%s  %s\n' "$sb__sha" "$sb__cache/$sb__name.tar.xz" | sha256sum -c --quiet - \
			|| die 'zig tarball checksum mismatch'
		tar xf "$sb__cache/$sb__name.tar.xz" -C "$sb__cache"
		rm -f "$sb__cache/$sb__name.tar.xz"
	fi
	[ -x "$sb__dir/zig" ] || die "zig not found at $sb__dir/zig after unpacking"
	printf '%s\n' "$sb__dir/zig"
}

# sb__bootlin_fetch <cache_dir> <target> -> toolchain bin/ prefix, downloading
# if needed. Bootlin publishes no checksum file per tarball, so integrity rests
# on HTTPS plus the pinned release version.
sb__bootlin_fetch() {
	sb__cache="$1"; sb__tgt="$2"
	sb__slug="$(sb_target_field "$sb__tgt" bootlin_tc)"
	sb__name="$sb__slug--musl--stable-$SB_TC_VER"
	sb__dir="$sb__cache/$sb__name"
	if [ ! -d "$sb__dir" ]; then
		log "fetching toolchain $sb__name"
		mkdir -p "$sb__cache"
		curl -fsSL -o "$sb__cache/$sb__name.tar.xz" \
			"$SB_BOOTLIN_BASE/$sb__slug/tarballs/$sb__name.tar.xz" \
			|| die 'toolchain download failed'
		tar xf "$sb__cache/$sb__name.tar.xz" -C "$sb__cache"
		rm -f "$sb__cache/$sb__name.tar.xz"
	fi
	sb__gcc="$(ls "$sb__dir/bin/"*-linux*-gcc 2>/dev/null | head -1)"
	[ -n "$sb__gcc" ] || die "no gcc found in $sb__dir/bin"
	printf '%s\n' "${sb__gcc%-gcc}"
}

# sb_tc_setup <target> <backend> <cache_dir>
# Exports the full compiler contract a recipe is handed.
sb_tc_setup() {
	SB_TARGET="$1"; SB_BACKEND="$2"; sb__cache="$3"
	sb_target_exists "$SB_TARGET" || die "no such target: $SB_TARGET"
	CFLAGS="$(sb_tc_flags "$SB_TARGET" "$SB_BACKEND")" || die "cannot build flags for $SB_TARGET/$SB_BACKEND"
	CXXFLAGS="$CFLAGS"
	LDFLAGS="$SB_COMMON_LDFLAGS"

	case "$SB_BACKEND" in
	zig)
		sb__zig="$(sb__zig_fetch "$sb__cache/zig")"
		# musl and compiler-rt are compiled per target on first use; keeping
		# that beside the toolchain lets CI cache the pair as one entry.
		ZIG_GLOBAL_CACHE_DIR="$sb__cache/zig/zig-cache"
		export ZIG_GLOBAL_CACHE_DIR
		sb__zt="$(sb_target_field "$SB_TARGET" zig_target)"
		# Wrappers, not bare variables: the -target must reach every single
		# object, including ones built by a configure script that rewrites
		# CFLAGS. Putting it in CFLAGS alone has silently produced host
		# objects before.
		mkdir -p "$sb__cache/wrap/$SB_TARGET"
		sb__w="$sb__cache/wrap/$SB_TARGET"
		printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "$sb__zig" "$sb__zt" > "$sb__w/cc"
		printf '#!/bin/sh\nexec "%s" c++ -target %s "$@"\n' "$sb__zig" "$sb__zt" > "$sb__w/cxx"
		printf '#!/bin/sh\nexec "%s" ar "$@"\n'     "$sb__zig" > "$sb__w/ar"
		printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$sb__zig" > "$sb__w/ranlib"
		chmod 755 "$sb__w/cc" "$sb__w/cxx" "$sb__w/ar" "$sb__w/ranlib"
		CC="$sb__w/cc"; CXX="$sb__w/cxx"; AR="$sb__w/ar"; RANLIB="$sb__w/ranlib"
		# zig has no `strip`; llvm-strip is arch-agnostic and `zig cc` already
		# emits no debug info under -Os.
		STRIP="$(command -v llvm-strip 2>/dev/null || command -v strip)"
		;;
	bootlin)
		sb__pfx="$(sb__bootlin_fetch "$sb__cache/bootlin" "$SB_TARGET")"
		CC="$sb__pfx-gcc"; CXX="$sb__pfx-g++"
		AR="$sb__pfx-ar"; RANLIB="$sb__pfx-ranlib"; STRIP="$sb__pfx-strip"
		;;
	*) die "no such backend: $SB_BACKEND" ;;
	esac

	export CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS SB_TARGET SB_BACKEND
}
