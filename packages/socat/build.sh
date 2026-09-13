#!/bin/sh
# socat recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# -Wno-error=date-time: socat stamps __DATE__ into its version string and the
# build promotes that warning to an error. The stamp is what it is -- silencing
# only the promotion keeps the diagnostic visible without failing the build.
#
# OpenSSL and readline are off: neither is worth the size here, and socat's
# value on these boxes is plain relaying rather than TLS termination.
#
# The ac_cv_* answers are for checks socat runs by compiling and *executing* a
# probe, which cannot work when the probe is for another architecture. Left to
# fail they are simply treated as absent, which silently drops working
# features -- so each one is answered with what these targets actually have.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS -Wno-error=date-time" LDFLAGS="$LDFLAGS" \
	--disable-openssl --disable-readline \
	sc_cv_sys_crdly_shift=12 \
	sc_cv_sys_tabdly_shift=10 \
	sc_cv_sys_csize_shift=4 \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f socat ] || { printf 'socat binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
for b in socat filan procan; do
	[ -f "$b" ] && { cp "$b" "$OUT/bin/$b"; chmod 755 "$OUT/bin/$b"; }
done
[ -f COPYING ] && cp COPYING "$OUT/SOCAT-LICENSE"
exit 0
