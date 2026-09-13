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

# Set by whoever sources this, because $0 in a sourced file names the sourcing
# script rather than this one. The shim sources live beside it, and a recipe
# has usually changed directory by the time they are needed.
: "${SB_LIB_DIR:?SB_LIB_DIR must be set to the directory holding lib/toolchain.sh}"

SB_ZIG_VER="${SB_ZIG_VER:-0.16.0}"
SB_GO_VER="${SB_GO_VER:-1.27.1}"
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

# Pinned from https://go.dev/dl/?mode=json, same rule as zig: a new Go release
# needs its sums added here before it can be used.
sb__go_sha() {
	case "$SB_GO_VER::$1" in
		1.27.1::amd64) printf '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445\n' ;;
		1.27.1::arm64) printf '3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec\n' ;;
		*) return 1 ;;
	esac
}

# Flags that every target gets, whatever the backend. -Os plus section
# splitting plus --gc-sections is what keeps these binaries small enough to
# hand to a device with a few megabytes of flash.
SB_COMMON_CFLAGS='-Os -ffunction-sections -fdata-sections'
# -Wl,-s strips at link time. That is not merely a convenience: zig ships no
# `strip`, and its objcopy --strip-all is unimplemented in 0.16, so there is no
# cross-capable stripper guaranteed to exist on a build host. Doing it in the
# linker removes the need for one. It keeps .ARM.attributes, which the ISA gate
# reads, because those are non-alloc sections that -s does not touch.
SB_COMMON_LDFLAGS='-static -Wl,--gc-sections -Wl,-s'

# sb_tc_flags <target> <backend> -> the CFLAGS for that pair, on stdout.
# Pure: touches no network and no filesystem, so it can be tested directly.
sb_tc_flags() {
	sb__tgt="$1"; sb__be="$2"
	sb_target_exists "$sb__tgt" || { warn "no such target: $sb__tgt"; return 1; }
	case "$sb__be" in
		zig)     sb__arch="$(sb_target_field "$sb__tgt" zig_cpu)" ;;
		bootlin) sb__arch="$(sb_target_field "$sb__tgt" bootlin_flags)" ;;
		# Go has no CFLAGS: the target is chosen entirely by GOARCH and friends,
		# and CGO is off, so there is no C compiler in the picture at all.
		go)      sb__arch='' ;;
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

# sb__go_fetch <cache_dir> -> path to the go binary, downloading if needed.
sb__go_fetch() {
	sb__cache="$1"
	case "$(uname -m)" in
		x86_64)  sb__ghost='amd64' ;;
		aarch64) sb__ghost='arm64' ;;
		*) die "no pinned Go $SB_GO_VER tarball for build host $(uname -m)" ;;
	esac
	sb__sha="$(sb__go_sha "$sb__ghost")" || die "no pinned Go $SB_GO_VER checksum for $sb__ghost"
	sb__dir="$sb__cache/go-$SB_GO_VER-$sb__ghost"
	if [ ! -x "$sb__dir/go/bin/go" ]; then
		log "fetching go$SB_GO_VER.linux-$sb__ghost"
		mkdir -p "$sb__dir"
		curl -fsSL -o "$sb__cache/go.tar.gz" \
			"https://go.dev/dl/go$SB_GO_VER.linux-$sb__ghost.tar.gz" \
			|| die 'go download failed'
		printf '%s  %s\n' "$sb__sha" "$sb__cache/go.tar.gz" | sha256sum -c --quiet - \
			|| die 'go tarball checksum mismatch'
		tar xf "$sb__cache/go.tar.gz" -C "$sb__dir"
		rm -f "$sb__cache/go.tar.gz"
	fi
	[ -x "$sb__dir/go/bin/go" ] || die "go not found at $sb__dir/go/bin/go after unpacking"
	printf '%s\n' "$sb__dir/go"
}

# sb__shim_object <cache_dir> <target> <name> <cc> <cflags> -> path to a
# compiled shim object, building it once per target and caching it.
#
# Each shim has a companion <name>-test.c asserting the semantics directly.
# That matters more than usual here: a wrong result from either of these links
# cleanly and fails later, somewhere else, in a way that looks like a bug in
# whatever was being built. The test runs under qemu at build time when qemu is
# installed, and is skipped with a note when it is not.
sb__shim_object() {
	sb__sc="$1"; sb__st="$2"; sb__sn="$3"; sb__scc="$4"; sb__scf="$5"
	sb__sdir="$sb__sc/shims/$sb__st"
	sb__sobj="$sb__sdir/$sb__sn.o"
	sb__ssrc="$SB_LIB_DIR/shims/$sb__sn.c"
	[ -f "$sb__ssrc" ] || die "missing shim source: $sb__ssrc"

	if [ ! -f "$sb__sobj" ]; then
		mkdir -p "$sb__sdir"
		log "building the $sb__sn shim for $sb__st"
		# shellcheck disable=SC2086  # $sb__scf is a flag list on purpose
		"$sb__scc" -c $sb__scf -o "$sb__sobj" "$sb__ssrc" \
			|| die "$sb__sn shim failed to compile for $sb__st"

		sb__stest="$SB_LIB_DIR/shims/$sb__sn-test.c"
		sb__sqemu="$(sb_target_field "$sb__st" qemu)"
		sb__sqcpu="$(sb_target_field "$sb__st" qemu_cpu)"
		if [ -f "$sb__stest" ] && command -v "$sb__sqemu" >/dev/null 2>&1; then
			# shellcheck disable=SC2086
			"$sb__scc" $sb__scf -static -o "$sb__sdir/$sb__sn-test" \
				"$sb__stest" "$sb__ssrc" \
				|| die "$sb__sn shim test failed to build for $sb__st"
			if [ -n "$sb__sqcpu" ]; then
				"$sb__sqemu" -cpu "$sb__sqcpu" "$sb__sdir/$sb__sn-test" >/dev/null 2>&1
			else
				"$sb__sqemu" "$sb__sdir/$sb__sn-test" >/dev/null 2>&1
			fi || { rm -f "$sb__sobj"; die "$sb__sn shim test failed for $sb__st"; }
		elif [ -f "$sb__stest" ]; then
			log "$sb__sqemu not installed: skipping the $sb__sn shim test"
		fi
	fi
	printf '%s\n' "$sb__sobj"
}

# sb_tc_setup <target> <backend> <cache_dir>
# Exports the full compiler contract a recipe is handed.
sb_tc_setup() {
	SB_TARGET="$1"; SB_BACKEND="$2"; sb__cache="$3"
	sb_target_exists "$SB_TARGET" || die "no such target: $SB_TARGET"
	# Absolute from here on. Go refuses a relative GOPATH outright, and a
	# recipe that changes directory -- most do -- would otherwise resolve a
	# relative compiler path against the wrong place.
	mkdir -p "$sb__cache"
	sb__cache="$(CDPATH='' cd -- "$sb__cache" && pwd)"
	SB_SHIM_OBJECTS=''; SB_SHIM_SOURCES=''; SB_HOST_TRIPLE=''
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
		# Wrappers, not bare variables. Both the target and the CPU have to
		# reach every single object, including ones built by a bundled library
		# with its own rules that never sees our CFLAGS.
		#
		# The CPU half is not theoretical. Dropbear bundles libtomcrypt and
		# libtommath, which compile with their own flags: with -mcpu only in
		# CFLAGS the resulting binary came out encoded as mips32r2 -- caught
		# here by the ISA gate, and on a BCM7356 it would have been an illegal
		# instruction on real silicon. The same mistake cost sshd-tunnel a
		# SIGILL on MIPS before the flag was moved into the wrapper there.
		#
		# It stays in CFLAGS as well, so what a recipe sees and what the
		# MANIFEST records is the truth; a repeated -mcpu with the same value
		# is harmless.
		mkdir -p "$sb__cache/wrap/$SB_TARGET"
		sb__w="$sb__cache/wrap/$SB_TARGET"
		sb__zc="$(sb_target_field "$SB_TARGET" zig_cpu)"
		printf '#!/bin/sh\nexec "%s" cc -target %s %s "$@"\n' "$sb__zig" "$sb__zt" "$sb__zc" > "$sb__w/cc"
		printf '#!/bin/sh\nexec "%s" c++ -target %s %s "$@"\n' "$sb__zig" "$sb__zt" "$sb__zc" > "$sb__w/cxx"
		printf '#!/bin/sh\nexec "%s" ar "$@"\n'     "$sb__zig" > "$sb__w/ar"
		printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$sb__zig" > "$sb__w/ranlib"
		chmod 755 "$sb__w/cc" "$sb__w/cxx" "$sb__w/ar" "$sb__w/ranlib"
		CC="$sb__w/cc"; CXX="$sb__w/cxx"; AR="$sb__w/ar"; RANLIB="$sb__w/ranlib"

		# What autoconf's --host wants. Not the same string as zig's -target:
		# config.sub has never heard of zig's "x86", so i686 has to be spelled
		# the way the GNU world spells it.
		SB_HOST_TRIPLE="$sb__zt"
		case "$sb__zt" in
			x86-linux-*) SB_HOST_TRIPLE="i686-linux-${sb__zt#x86-linux-}" ;;
		esac

		# Defects in zig's own C runtime, compensated here so that no recipe
		# has to know about them. Both are linked as loose objects rather than
		# an archive: LDFLAGS lands before the object files on most link lines,
		# and an archive there is only scanned for what is already undefined at
		# that point -- an ordering an object does not depend on.
		sb__shims=''
		case "$SB_TARGET" in
		mips|mipsel)
			# zig 0.16 supplies a pipe() that uses the ordinary pointer
			# convention. MIPS o32 is the odd syscall out: it returns both
			# descriptors in registers, so zig's returns the read descriptor
			# where the status code belongs. Measured: pipe(fd) yields 3, not
			# 0. Code testing `< 0` survives; code testing `!= 0` does not, and
			# the damage is quiet -- a session that opens, authenticates and
			# produces no output.
			sb__shims="$(sb__shim_object "$sb__cache" "$SB_TARGET" mips-o32-pipe "$CC" "$CFLAGS")"
			;;
		armv5)
			# ARMv5 has no LDREX/STREX, so clang emits calls to the legacy
			# __sync_* libcalls, which zig's compiler-rt does not implement --
			# while zig's own allocator, which backs malloc, calls three of
			# them. Without these the link simply fails.
			sb__shims="$(sb__shim_object "$sb__cache" "$SB_TARGET" arm-pre-v6-sync "$CC" "$CFLAGS -fno-builtin")"
			;;
		esac
		# Appended to LDFLAGS, which is right for build systems that use it
		# once. SB_SHIM_OBJECTS carries the same list separately so a recipe
		# whose build system links in more than one pass can move it: kbuild
		# computes its partial-link flags as `filter-out -Wl,%, $(LDFLAGS)`,
		# which keeps a bare object path, so the shim would land in both the
		# `ld -r` step and the final link and every symbol would come out
		# duplicated. See packages/busybox/build.sh.
		#
		# -Wl,<object> would dodge that filter but lld rejects it outright
		# ("unsupported linker arg"): -Wl, means linker option, not input file.
		SB_SHIM_OBJECTS="$sb__shims"
		if [ -n "$sb__shims" ]; then
			LDFLAGS="$LDFLAGS $sb__shims"
			# The sources as well. A build system that links in more than one
			# pass cannot take a prebuilt object through any flag variable --
			# see packages/busybox/build.sh -- and its only clean route is to
			# compile the shim as one of its own objects.
			SB_SHIM_SOURCES=''
			for sb__o in $sb__shims; do
				SB_SHIM_SOURCES="$SB_SHIM_SOURCES $SB_LIB_DIR/shims/$(basename "${sb__o%.o}").c"
			done
		fi
		# A cross-capable strip, or a documented no-op. The host's GNU strip is
		# emphatically not an option: it refuses a foreign binary outright
		# ("Unable to recognise the format of the input file"), which is how
		# this first failed on a runner while passing on a developer machine
		# that happened to have llvm-strip installed.
		printf '%s\n' \
			'#!/bin/sh' \
			'# Cross strip for the zig backend.' \
			'#' \
			'# zig has no strip of its own and its objcopy --strip-all is' \
			'# unimplemented in 0.16, so llvm-strip is used when the host has it.' \
			'# When it does not, this is a no-op that succeeds: LDFLAGS carries' \
			'# -Wl,-s, so the binary was already stripped at link time and a' \
			'# recipe whose Makefile ends in a bare `strip` has nothing left to' \
			'# do. Failing here instead would break those recipes for no gain.' \
			'if command -v llvm-strip >/dev/null 2>&1; then exec llvm-strip "$@"; fi' \
			'exit 0' \
			> "$sb__w/strip"
		chmod 755 "$sb__w/strip"
		STRIP="$sb__w/strip"
		;;
	bootlin)
		sb__pfx="$(sb__bootlin_fetch "$sb__cache/bootlin" "$SB_TARGET")"
		CC="$sb__pfx-gcc"; CXX="$sb__pfx-g++"
		AR="$sb__pfx-ar"; RANLIB="$sb__pfx-ranlib"; STRIP="$sb__pfx-strip"
		# Bootlin names its tools <triple>-<tool>, so the prefix is the triple.
		SB_HOST_TRIPLE="$(basename "$sb__pfx")"
		;;
	go)
		# Go cross-compiles itself: one toolchain, every target, no C compiler
		# and no per-architecture download. CGO stays off, which is what makes
		# the result static without asking for it.
		GOROOT="$(sb__go_fetch "$sb__cache/go")"
		GOPATH="$sb__cache/gopath"
		GOCACHE="$sb__cache/gocache"
		GO="$GOROOT/bin/go"
		GOOS='linux'
		GOARCH="$(sb_target_field "$SB_TARGET" go_arch)"
		[ -n "$GOARCH" ] || die "$SB_TARGET has no GOARCH in the matrix"
		CGO_ENABLED='0'
		# GOARM / GOMIPS / GO386 for this target, exported by name.
		for sb__kv in $(sb_target_field "$SB_TARGET" go_env); do
			export "${sb__kv?}"
		done
		export GOROOT GOPATH GOCACHE GO GOOS GOARCH CGO_ENABLED
		# Nothing C-shaped is meaningful here, and leaving stale values around
		# would let a recipe pick up a compiler that cannot build for this target.
		CC=''; CXX=''; AR=''; RANLIB=''; STRIP=''
		;;
	*) die "no such backend: $SB_BACKEND" ;;
	esac

	export CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS SB_TARGET SB_BACKEND
	export SB_SHIM_OBJECTS SB_SHIM_SOURCES SB_HOST_TRIPLE
}
