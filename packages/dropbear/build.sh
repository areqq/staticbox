#!/bin/sh
# Dropbear recipe. Compiles only: the driver has already fetched, verified,
# unpacked and patched the source, and set up the compiler.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# localoptions.h is only honoured in the build directory: the Makefile adds
# -DLOCALOPTIONS_H_EXISTS for ./localoptions.h and nowhere else.
cp "$HERE/localoptions.h" "$SRC/localoptions.h"

cd "$SRC"

# Everything disabled here is absent on these devices or absent from musl:
# there is no PAM, no shadow, no utmp/wtmp implementation, and no zlib to link
# against in a static binary that must not depend on the image.
./configure --host="$SB_HOST_TRIPLE" \
	CC="$CC" AR="$AR" RANLIB="$RANLIB" \
	CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--enable-static --disable-zlib --disable-pam --disable-shadow \
	--disable-lastlog --disable-utmp --disable-utmpx \
	--disable-wtmp --disable-wtmpx \
	--disable-loginfunc --disable-pututline --disable-pututxline \
	>"$WORK/configure.log" 2>&1 \
	|| { tail -25 "$WORK/configure.log" >&2; exit 1; }

JOBS="$(nproc 2>/dev/null || echo 2)"
PROGS='dbclient dropbear dropbearkey dropbearconvert'

make -j"$JOBS" PROGRAMS="$PROGS" MULTI=1 >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }
[ -f dropbearmulti ] || { printf 'dropbearmulti was not produced\n' >&2; exit 1; }

# scp is not part of the multi-call binary upstream, so it is built on its own.
make -j"$JOBS" scp >"$WORK/make-scp.log" 2>&1 \
	|| { sb_dump_log "$WORK/make-scp.log"; exit 1; }

mkdir -p "$OUT/bin"
cp dropbearmulti "$OUT/bin/dropbearmulti"
cp scp "$OUT/bin/scp"
chmod 755 "$OUT/bin/dropbearmulti" "$OUT/bin/scp"

# The applet names the multi-call binary answers to, so whoever unpacks this
# knows to symlink them rather than guess.
{
	printf 'dropbearmulti dispatches on argv[0]. Symlink these to it:\n'
	for p in $PROGS; do printf '  %s\n' "$p"; done
} > "$OUT/APPLETS"

[ -f LICENSE ] && cp LICENSE "$OUT/DROPBEAR-LICENSE"
exit 0
