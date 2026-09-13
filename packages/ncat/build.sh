#!/bin/sh
# ncat recipe. Compiles only: the driver has already fetched, verified and
# unpacked the nmap tarball ncat ships inside.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

JOBS="$(nproc 2>/dev/null || echo 2)"

cd "$SRC"

# MIPS32's missing 64-bit atomics come from the toolchain as SB_TARGET_LIBS
# (-latomic there), passed as LIBS so autoconf places it after the objects.
export LIBS="$SB_TARGET_LIBS"

# libpcap's configure probes the *running* kernel's version, which says nothing
# about the target's. ac_cv_linux_vers=2 skips that test. ncat itself does not
# capture packets, but nsock links against libpcap, so it is still built.
export ac_cv_linux_vers=2

# This is nmap's top-level configure, so it is told about all of nmap even
# though only ncat is built from it. --without-zenmap and friends stop it
# preparing the parts this package never compiles, and every --with-*=included
# keeps it from answering with a host library: there is no cross-compiled copy
# of any of these for the target, and a configure that found the build
# machine's would record it and fail at link.
#
# Of those, ncat genuinely links three: nbase and nsock, and libpcap, which it
# does not use itself but which nsock's link line pulls in. The bundled Lua is
# the fourth, and it is what makes --lua-exec work.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	--without-openssl --without-libssh2 \
	--without-zenmap --without-ndiff --without-nping \
	--with-libpcap=included --with-liblua=included \
	--with-libpcre=included --with-libdnet=included --with-libz=included \
	--without-subversion \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

# The bundled libpcap builds a shared object as well as the archive, and under
# -static that shared link fails on the non-PIC static CRT:
#   crtbeginT.o: dangerous relocation ... recompile with -fPIC
# ncat links the archive, so the shared target is simply dropped. This is the
# same edit packages/nmap/build.sh makes, and for the same reason.
sed -i 's/^all: libpcap.a shared/all: libpcap.a/' libpcap/Makefile

# build-ncat, not all: the scanner, its OS database and NSE are not wanted
# here and take an order of magnitude longer to compile.
make -j"$JOBS" build-ncat >"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f ncat/ncat ] || { printf 'ncat binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp ncat/ncat "$OUT/bin/ncat"
chmod 755 "$OUT/bin/ncat"
[ -f LICENSE ] && cp LICENSE "$OUT/NCAT-LICENSE"
exit 0
