#!/bin/sh
# staticbox installer -- work out what this device is, show what can be put on
# it, and put the chosen things in /tmp.
#
#   wget -qO- https://raw.githubusercontent.com/areqq/staticbox/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/areqq/staticbox/main/install.sh | sh
#
#   ./install.sh                 pick from a numbered list
#   ./install.sh busybox curl    install these, no questions
#   ./install.sh --all           install everything for this device
#   ./install.sh --detect        print the best target name and exit
#   ./install.sh --targets       print every target this device can run, best first
#   ./install.sh --list          print what is available and exit
#
# Options:
#   --dir DIR        where to install      (default: /tmp/staticbox)
#   --repo OWNER/NAME  where to fetch from (default: areqq/staticbox)
#   --target NAME    override the detection
#   --probe FILE     read the ELF header from this file instead of /bin/sh
#   --cpuinfo FILE   read CPU features from this file instead of /proc/cpuinfo
#
# Target environment: busybox ash on a device from around 2014, and
# deliberately poorer. Only sh, grep, sed, od, uname and one of wget/curl are
# assumed. No python, no mktemp, no id, no find -maxdepth, no arrays, no
# `local`. Every one of those is missing on at least one device this has to
# work on.
set -u

REPO='areqq/staticbox'
DEST='/tmp/staticbox'
PROBE=''
CPUINFO='/proc/cpuinfo'
FORCE_TARGET=''
MODE='interactive'
WANTED=''

while [ $# -gt 0 ]; do
	case "$1" in
		--detect)  MODE='detect' ;;
		--targets) MODE='targets' ;;
		--list)    MODE='list' ;;
		--all)     MODE='all' ;;
		--dir)     shift; DEST="${1:-$DEST}" ;;
		--repo)    shift; REPO="${1:-$REPO}" ;;
		--target)  shift; FORCE_TARGET="${1:-}" ;;
		--probe)   shift; PROBE="${1:-}" ;;
		--cpuinfo) shift; CPUINFO="${1:-}" ;;
		-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)        printf 'install.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
		*)         WANTED="$WANTED $1"; MODE='named' ;;
	esac
	shift
done

say()  { printf '%s\n' "$*"; }
# Everything a person reads goes to stderr. choose() runs inside a command
# substitution, so its stdout is the list of chosen numbers and nothing else --
# a prompt written there would be swallowed instead of shown.
tell() { printf '%s\n' "$*" >&2; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# `command -v` is POSIX, but at least one router in the wild (ASUSWRT-Merlin's
# busybox ash) does not have it and reports "command: not found".
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------ detection
#
# This is the only architecture detector in the project. There were two once,
# written independently, and they had drifted apart -- which is a large part of
# why this repo exists. There is not going to be a second one again.

arch="${SB_FAKE_UNAME:-$(uname -m 2>/dev/null || echo unknown)}"

# Pick a binary that is certainly native to this device and read its ELF
# header. uname -m cannot tell big- from little-endian MIPS: every MIPS device
# tested reports plain "mips" either way.
probe_file() {
	[ -n "$PROBE" ] && { printf '%s\n' "$PROBE"; return; }
	for p in /bin/sh /bin/busybox /bin/cat /bin/true; do
		[ -r "$p" ] && { printf '%s\n' "$p"; return; }
	done
	printf '\n'
}

# byte 4 = EI_CLASS (1 = 32-bit, 2 = 64-bit), byte 5 = EI_DATA (1 = LE, 2 = BE)
elf_byte() {
	have od || return 1
	od -An -tu1 -j"$1" -N1 "$2" 2>/dev/null | tr -d ' \n'
}

PF="$(probe_file)"
elf_class=''
elf_data=''
if [ -n "$PF" ] && [ -r "$PF" ]; then
	elf_class="$(elf_byte 4 "$PF")"
	elf_data="$(elf_byte 5 "$PF")"
fi

# ARM feature flags live in /proc/cpuinfo "Features:". An aarch64 kernel running
# a 32-bit userland still lists them there, which is why the userland's ELF
# class decides the architecture and cpuinfo only decides the variant.
has_feature() {
	grep -qiE "^(Features|flags)[[:space:]]*:.*[[:space:]]$1([[:space:]]|\$)" "$CPUINFO" 2>/dev/null
}

# Best first. A package may not publish every target -- a Go package has no
# NEON variant to offer, for instance -- so the installer walks this list and
# takes the first build that actually exists.
arm_targets() {
	if has_feature neon; then printf 'armv7-neon\narmv7\n'
	else printf 'armv7\n'; fi
}

detect_targets() {
	[ -n "$FORCE_TARGET" ] && { printf '%s\n' "$FORCE_TARGET"; return 0; }
	case "$arch" in
		aarch64 | arm64)
			# A 64-bit kernel may run a 32-bit userland. Trust the userland: it
			# is what has to load our binary.
			if [ "$elf_class" = '2' ]; then printf 'aarch64\n'; else arm_targets; fi ;;
		armv7l | armv7 | armv8l | arm)  arm_targets ;;
		armv6l | armv5* | armv4*)       printf 'armv5\n' ;;
		mips | mipsel | mips64 | mips64el)
			if [ "$elf_data" = '2' ]; then printf 'mips\n'; else printf 'mipsel\n'; fi ;;
		x86_64 | amd64)
			if [ "$elf_class" = '1' ]; then printf 'i686\n'; else printf 'x86_64\n'; fi ;;
		i386 | i486 | i586 | i686)      printf 'i686\n' ;;
		*) return 2 ;;
	esac
}

TARGETS="$(detect_targets)" || die "unsupported architecture: $arch"
TARGET="$(printf '%s\n' "$TARGETS" | sed -n 1p)"

describe_target() {
	case "$1" in
		x86_64)     say 'x86-64' ;;
		i686)       say '32-bit x86' ;;
		armv5)      say 'ARMv5TE, soft-float' ;;
		armv7)      say 'ARMv7-A, VFPv3-D16, no NEON' ;;
		armv7-neon) say 'ARMv7-A with NEON' ;;
		aarch64)    say 'ARM 64-bit' ;;
		mips)       say 'MIPS32 r1, big-endian, soft-float' ;;
		mipsel)     say 'MIPS32 r1, little-endian, soft-float' ;;
		*)          say "$1" ;;
	esac
}

if [ "$MODE" = 'detect' ]; then
	printf '%s\n' "$TARGET"
	exit 0
fi

# Every target this device can run, best first. Packages do not all cover the
# same targets -- a Go package has no NEON variant to offer -- so a NEON box has
# to be willing to take the plain armv7 build. The installer walks this list
# when building its catalogue; printing it is what makes that testable.
if [ "$MODE" = 'targets' ]; then
	printf '%s\n' "$TARGETS"
	exit 0
fi

# ------------------------------------------------------------------ downloads
#
# curl first, wget second. On an old box the wget is usually busybox's, which
# on some images cannot do HTTPS at all -- worth saying plainly rather than
# failing with an empty file.
if have curl; then
	fetch()    { curl -fsSL -o "$2" "$1"; }
	fetch_out() { curl -fsSL "$1"; }
elif have wget; then
	fetch()    { wget -q -O "$2" "$1"; }
	fetch_out() { wget -q -O - "$1"; }
else
	die 'neither curl nor wget is installed; cannot fetch anything'
fi

API="https://api.github.com/repos/$REPO/releases"

# One call, then everything is read out of it. GitHub's JSON puts each asset
# URL on its own "browser_download_url" field, which is regular enough to pull
# out with sed -- and sed is all a box of this vintage can be relied on to have.
say "staticbox -- fetching the package list"
ASSETS="$(fetch_out "$API?per_page=100" 2>/dev/null \
	| sed -n 's/.*"browser_download_url": *"\([^"]*\.tar\.gz\)".*/\1/p')"

[ -n "$ASSETS" ] || die "could not read the release list from $API (no network, or no TLS in this wget)"

# Which of the detected targets actually has builds, per package. A line here
# is: <package> <version> <variant-or-dash> <url>
CATALOGUE=''
for url in $ASSETS; do
	file="${url##*/}"
	stem="${file%.tar.gz}"
	for t in $TARGETS; do
		# <pkg>-<version>-<target>[-<variant>]
		case "$stem" in
			*-"$t")   pkg_ver="${stem%-$t}";      variant='-' ;;
			*-"$t"-*) pkg_ver="${stem%%-$t-*}";   variant="${stem##*-$t-}" ;;
			*) continue ;;
		esac
		# Split <pkg>-<version> at the last dash before the version, which
		# always starts with a digit.
		pkg="$(printf '%s\n' "$pkg_ver" | sed -n 's/^\(.*\)-[0-9][^-]*$/\1/p')"
		ver="$(printf '%s\n' "$pkg_ver" | sed -n 's/^.*-\([0-9][^-]*\)$/\1/p')"
		[ -n "$pkg" ] || continue
		# Only the best target that has this package+variant; a later, less
		# preferred target must not add a duplicate entry.
		key="$pkg $variant"
		case "
$CATALOGUE" in *"
$key "*) continue ;; esac
		CATALOGUE="$CATALOGUE$key $ver $url
"
		break
	done
done

[ -n "$CATALOGUE" ] || die "nothing is published for $TARGET yet"

# Sorted so the numbering is stable between runs.
CATALOGUE="$(printf '%s' "$CATALOGUE" | sort)"
COUNT="$(printf '%s\n' "$CATALOGUE" | grep -c .)"

show_list() {
	tell ''
	tell "  device : $arch  ->  $TARGET  ($(describe_target "$TARGET"))"
	tell "  install: $DEST"
	tell ''
	i=0
	printf '%s\n' "$CATALOGUE" | while read -r pkg variant ver url; do
		i=$((i + 1))
		label="$pkg"
		[ "$variant" = '-' ] || label="$pkg ($variant)"
		printf '  %2d) %-18s %s\n' "$i" "$label" "$ver" >&2
	done
	tell ''
}

if [ "$MODE" = 'list' ]; then
	show_list 2>&1
	exit 0
fi

# ------------------------------------------------------------------ selection
#
# Which entries to install, as a list of line numbers.
choose() {
	case "$MODE" in
	all)
		i=0
		while [ "$i" -lt "$COUNT" ]; do i=$((i + 1)); printf '%s\n' "$i"; done
		return 0 ;;
	named)
		for w in $WANTED; do
			n="$(printf '%s\n' "$CATALOGUE" | grep -n "^$w " | sed -n 's/^\([0-9]*\):.*/\1/p' | sed -n 1p)"
			[ -n "$n" ] || { warn "not available for $TARGET: $w"; continue; }
			printf '%s\n' "$n"
		done
		return 0 ;;
	esac

	show_list

	# stdin is the script itself when this is run as `wget -qO- ... | sh`, so
	# reading from it would eat the rest of the program. The terminal is the
	# only safe place to ask.
	#
	# Opening it is the test, not [ -r /dev/tty ]: the path exists and looks
	# readable in a session with no controlling terminal, and the open then
	# fails with "No such device or address" -- which skipped this message and
	# printed a raw shell error instead.
	if ! ( exec < /dev/tty ) 2>/dev/null; then
		tell '  No terminal to ask on -- this was piped into sh.'
		tell '  Re-run naming what you want, for example:'
		tell ''
		tell "    wget -qO- https://raw.githubusercontent.com/$REPO/main/install.sh > /tmp/i.sh"
		tell '    sh /tmp/i.sh busybox curl'
		tell '    sh /tmp/i.sh --all'
		tell ''
		return 1
	fi

	printf '  which? (numbers, "a" for all, empty to quit): ' >&2
	read -r answer < /dev/tty || answer=''
	case "$answer" in
		'')    tell '  nothing chosen'; return 1 ;;
		a|all) i=0; while [ "$i" -lt "$COUNT" ]; do i=$((i + 1)); printf '%s\n' "$i"; done; return 0 ;;
	esac
	for n in $answer; do
		case "$n" in
			''|*[!0-9]*) warn "not a number: $n"; continue ;;
		esac
		[ "$n" -ge 1 ] && [ "$n" -le "$COUNT" ] || { warn "out of range: $n"; continue; }
		printf '%s\n' "$n"
	done
}

PICKED="$(choose)" || exit 1
[ -n "$PICKED" ] || { say '  nothing to do'; exit 0; }

# ------------------------------------------------------------------- install
mkdir -p "$DEST" || die "cannot create $DEST"

INSTALLED=''
FAILED=''
for n in $PICKED; do
	line="$(printf '%s\n' "$CATALOGUE" | sed -n "${n}p")"
	pkg="$(printf '%s\n' "$line" | cut -d' ' -f1)"
	variant="$(printf '%s\n' "$line" | cut -d' ' -f2)"
	url="$(printf '%s\n' "$line" | cut -d' ' -f4)"
	file="${url##*/}"
	label="$pkg"
	[ "$variant" = '-' ] || label="$pkg ($variant)"

	say "  fetching $label"
	if ! fetch "$url" "$DEST/$file"; then
		warn "download failed: $url"; FAILED="$FAILED $pkg"; continue
	fi

	# Check the sum when the box has sha256sum. Plenty of old busybox builds
	# do not, and refusing to install on that basis would be worse than
	# installing: the alternative is no tool at all.
	if have sha256sum && fetch "$url.sha256" "$DEST/$file.sha256"; then
		if ( cd "$DEST" && sha256sum -c "$file.sha256" >/dev/null 2>&1 ); then
			:
		else
			warn "checksum mismatch for $file -- not installing it"
			rm -f "$DEST/$file" "$DEST/$file.sha256"
			FAILED="$FAILED $pkg"; continue
		fi
	fi

	# Guarded: an empty DEST or pkg here would be rm -rf /
	rm -rf "${DEST:?}/${pkg:?}"
	mkdir -p "$DEST/$pkg"
	if ! tar xzf "$DEST/$file" -C "$DEST/$pkg" 2>/dev/null; then
		warn "cannot unpack $file"; FAILED="$FAILED $pkg"; continue
	fi
	rm -f "$DEST/$file" "$DEST/$file.sha256"

	for b in "$DEST/$pkg"/bin/*; do
		[ -f "$b" ] && chmod 755 "$b" 2>/dev/null
	done
	INSTALLED="$INSTALLED $pkg"
done

# --------------------------------------------------------------------- report
say ''
if [ -n "$INSTALLED" ]; then
	say "  installed in $DEST:"
	say ''
	for pkg in $INSTALLED; do
		for b in "$DEST/$pkg"/bin/*; do
			[ -f "$b" ] || continue
			sz="$(wc -c < "$b" 2>/dev/null | tr -d ' ')"
			printf '    %-42s %8s bytes\n' "$b" "${sz:-?}"
		done
		# nmap is useless without its data files and will not find them on its
		# own, so say the one thing its user needs to know.
		[ -d "$DEST/$pkg/share/nmap" ] && \
			printf '    %-42s (pass --datadir %s)\n' '' "$DEST/$pkg/share/nmap"
	done
	say ''
	say "  add them to PATH for this shell:"
	say ''
	printf '    PATH="'
	for pkg in $INSTALLED; do printf '%s/%s/bin:' "$DEST" "$pkg"; done
	printf '$PATH"; export PATH\n'
	say ''
fi
[ -n "$FAILED" ] && say "  failed:$FAILED"
[ -n "$INSTALLED" ] || exit 1
exit 0
