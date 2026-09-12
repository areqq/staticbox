#!/bin/sh
# detect.sh -- print the staticbox target name that suits THIS device.
#
#   ./detect.sh                 -> e.g. armv7-neon
#   ./detect.sh --probe <elf>   -> read the ELF header from this file instead
#   ./detect.sh --cpuinfo <f>   -> read CPU features from this file instead
#
# The two override flags exist so this can be tested against binaries from
# eight architectures without owning eight boxes.
#
# Target environment: busybox ash on a device from around 2014, and
# deliberately poorer. Only sh, cat, grep, od and uname are assumed. No python,
# no mktemp, no id, no find -maxdepth. Every one of those is missing on at
# least one device this has to work on.
#
# This replaces two detectors that were written independently and each knew
# something the other did not: one read the ELF header because uname lies on
# MIPS, the other told NEON from crypto extensions, and only one had a
# fallback for the busybox ash that lacks `command -v`.
set -u

PROBE=''
CPUINFO='/proc/cpuinfo'
while [ $# -gt 0 ]; do
	case "$1" in
		--probe)    shift; PROBE="${1:-}" ;;
		--cpuinfo)  shift; CPUINFO="${1:-}" ;;
		*) printf 'detect.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
	shift
done

# `command -v` is POSIX, but at least one router in the wild (ASUSWRT-Merlin's
# busybox ash) does not have it and reports "command: not found".
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

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

# armv7-aes is present in the matrix but disabled, so no package has builds for
# it. Selecting it would hand the device a URL that 404s. Until it is enabled,
# a box with crypto extensions gets the NEON build, which is correct -- just
# not the fastest possible.
arm_variant() {
	if has_feature neon; then printf 'armv7-neon\n'
	else printf 'armv7\n'; fi
}

case "$arch" in
	aarch64 | arm64)
		# A 64-bit kernel may run a 32-bit userland. Trust the userland: it is
		# what has to load our binary.
		if [ "$elf_class" = '2' ]; then printf 'aarch64\n'
		else arm_variant; fi
		;;
	armv7l | armv7 | armv8l | arm)
		arm_variant
		;;
	armv6l | armv5* | armv4*)
		printf 'armv5\n'
		;;
	mips | mipsel | mips64 | mips64el)
		if [ "$elf_data" = '2' ]; then printf 'mips\n'
		else printf 'mipsel\n'; fi
		;;
	x86_64 | amd64)
		# A 64-bit kernel with a 32-bit userland happens on small x86 boxes too.
		if [ "$elf_class" = '1' ]; then printf 'i686\n'
		else printf 'x86_64\n'; fi
		;;
	i386 | i486 | i586 | i686)
		printf 'i686\n'
		;;
	*)
		printf 'detect.sh: unsupported architecture: %s\n' "$arch" >&2
		exit 2
		;;
esac
