#!/bin/sh
# BusyBox recipe. Compiles only: the driver has already fetched, verified and
# unpacked the source, and set up the compiler.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
set -eu

cd "$SRC"

# HOSTCC has to stay the host's compiler: busybox builds several generators
# (usage, applet tables) that run during the build. Only CC crosses.
make defconfig HOSTCC=cc CC="$CC" >"$WORK/config.log" 2>&1

# Config changes, each for a reason that shows up as a build or runtime failure
# rather than a warning:
#
#   STATIC            the entire point; nothing on the box is linked against
#   PIE               off, because a static PIE needs a loader we do not ship
#   SELINUX/PAM       not present on any of these devices, and not in musl
#   FEATURE_UTMP/WTMP musl has no utmp implementation at all
#   TC                uses kernel tc headers that no longer match; dropped
#                     upstream in spirit, still selectable here
#   NOLOGIN/*_LIBCRYPT  musl's crypt() lacks the DES entry points these want
set_cfg() {
	sed -i "s|^# $1 is not set|$1=$2|; s|^$1=.*|$1=$2|" .config
	grep -q "^$1=" .config || printf '%s=%s\n' "$1" "$2" >> .config
}
unset_cfg() {
	sed -i "s|^$1=.*|# $1 is not set|" .config
}

set_cfg CONFIG_STATIC y
set_cfg CONFIG_STATIC_LIBGCC y
unset_cfg CONFIG_PIE
unset_cfg CONFIG_SELINUX
unset_cfg CONFIG_PAM
unset_cfg CONFIG_FEATURE_UTMP
unset_cfg CONFIG_FEATURE_WTMP
unset_cfg CONFIG_TC
unset_cfg CONFIG_USE_BB_CRYPT_SHA
# SHA1/SHA256 hardware acceleration is x86 assembly, but defconfig turns it on
# unconditionally and the guard around it keys off GCC predefines that zig's
# clang does not set the same way. The result is a reference to
# sha1_process_block64_shaNI that exists in no object.
unset_cfg CONFIG_SHA1_HWACCEL
unset_cfg CONFIG_SHA256_HWACCEL

# The architecture flags travel through the config, which is how busybox
# threads them into every object including the ones its own Makefile builds
# with its own rules.
sed -i "s|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS=\"$CFLAGS\"|" .config
sed -i "s|^CONFIG_EXTRA_LDFLAGS=.*|CONFIG_EXTRA_LDFLAGS=\"$LDFLAGS\"|" .config

make oldconfig HOSTCC=cc CC="$CC" >>"$WORK/config.log" 2>&1

make -j"$(nproc 2>/dev/null || echo 2)" HOSTCC=cc CC="$CC" \
	SKIP_STRIP=y busybox >"$WORK/make.log" 2>&1 \
	|| { tail -40 "$WORK/make.log" >&2; exit 1; }

[ -f busybox ] || { printf 'busybox binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp busybox "$OUT/bin/busybox"
chmod 755 "$OUT/bin/busybox"
cp LICENSE "$OUT/BUSYBOX-LICENSE" 2>/dev/null || true
exit 0
