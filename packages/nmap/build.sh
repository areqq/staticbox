#!/bin/sh
# nmap recipe. Compiles only: the driver has already fetched, verified and
# unpacked nmap and, for the full variant, OpenSSL and libssh2.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE DEP_PREFIX SRC_openssl SRC_libssh2
#
# Every workaround below is here because the build failed without it. They are
# spelled out rather than summarised, because each one cost a debugging session
# and the failure mode never names the cause.
set -eu

JOBS="$(nproc 2>/dev/null || echo 2)"

# MIPS32 has no native 64-bit atomics, so the linker asks for __atomic_* from
# libatomic. Only nmap's own link needs it; the libraries below do not.
EXTRA_LIBS=''
case "$TARGET" in
	mips|mipsel) EXTRA_LIBS='-latomic' ;;
esac

CONF_CRYPTO='--without-openssl --without-libssh2'
NMAP_CPPFLAGS=''
NMAP_LDFLAGS="$LDFLAGS"

# SRC_openssl and SRC_libssh2 are exported by the driver for the deps declared
# in meta, which the linter has no way to see.
# shellcheck disable=SC2154
if [ "$VARIANT" = 'full' ]; then
	# ---------------------------------------------------------- OpenSSL
	# linux-generic32: plain C, no assembly, so the cross is unconditional.
	#
	# Three things here are not obvious:
	#
	#  * CC and friends must be unset. Configure appends
	#    --cross-compile-prefix to whatever CC already says, so leaving it set
	#    produces <triple>-<triple>-gcc and a "not found".
	#
	#  * `no-docs` does not exist in 3.0.x. Passing it makes Configure stop
	#    with "Unsupported options".
	#
	#  * build_libs plus install_dev, never install_sw. The openssl application
	#    is not wanted here and on MIPS32 it fails to link over __atomic_*
	#    anyway; install_dev gives the headers, the .a files and the pkgconfig.
	( cd "$SRC_openssl"
	  unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
	  ./Configure linux-generic32 no-shared no-dso no-engine no-tests no-async \
		--prefix="$DEP_PREFIX" --openssldir="$DEP_PREFIX/ssl" \
		--cross-compile-prefix="$SB_HOST_TRIPLE-" \
		>"$WORK/openssl-configure.log" 2>&1
	  make -j"$JOBS" build_libs >"$WORK/openssl-make.log" 2>&1
	  make install_dev >>"$WORK/openssl-make.log" 2>&1 ) \
		|| { tail -n 25 "$WORK/openssl-make.log" "$WORK/openssl-configure.log" >&2; exit 1; }

	# ---------------------------------------------------------- libssh2
	( cd "$SRC_libssh2"
	  ./configure --host="$SB_HOST_TRIPLE" --prefix="$DEP_PREFIX" \
		--disable-shared --enable-static --disable-examples-build \
		--with-crypto=openssl --with-libssl-prefix="$DEP_PREFIX" \
		CC="$CC" CFLAGS="$CFLAGS -I$DEP_PREFIX/include" LDFLAGS="-L$DEP_PREFIX/lib" \
		>"$WORK/libssh2-configure.log" 2>&1
	  make -j"$JOBS" >"$WORK/libssh2-make.log" 2>&1
	  make install >>"$WORK/libssh2-make.log" 2>&1 ) \
		|| { tail -n 25 "$WORK/libssh2-make.log" "$WORK/libssh2-configure.log" >&2; exit 1; }

	CONF_CRYPTO="--with-openssl=$DEP_PREFIX --with-libssh2=$DEP_PREFIX"
	NMAP_CPPFLAGS="-I$DEP_PREFIX/include"
	NMAP_LDFLAGS="$LDFLAGS -L$DEP_PREFIX/lib"
fi

# ------------------------------------------------------------------- nmap
cd "$SRC"

# libpcap's configure probes the running kernel's version, which says nothing
# about the target's. ac_cv_linux_vers=2 skips that test.
export CPPFLAGS="$NMAP_CPPFLAGS"
export LDFLAGS="$NMAP_LDFLAGS"
export LIBS="$EXTRA_LIBS"
export ac_cv_linux_vers=2

# shellcheck disable=SC2086  # $CONF_CRYPTO is two options, not one word
./configure --host="$SB_HOST_TRIPLE" \
	$CONF_CRYPTO \
	--without-zenmap --without-ndiff --without-nping --without-ncat \
	--with-libpcap=included --with-liblua=included --with-libpcre=included \
	--with-libdnet=included --with-libz=included --without-subversion \
	>"$WORK/configure.log" 2>&1 \
	|| { tail -n 25 "$WORK/configure.log" >&2; exit 1; }

# The bundled libz and libpcap build a shared object as well as the archive.
# Under -static that shared link fails on the non-PIC static CRT:
#   crtbeginT.o: dangerous relocation ... recompile with -fPIC
# nmap links the archives, so the shared targets are simply dropped.
sed -i 's/^all: static.*/all: static/'            libz/Makefile
sed -i 's/^all: libpcap.a shared/all: libpcap.a/' libpcap/Makefile

make -j"$JOBS" >"$WORK/make.log" 2>&1 \
	|| { grep -iE 'error|undefined' "$WORK/make.log" | head -25 >&2; exit 1; }

[ -f nmap ] || { printf 'nmap binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp nmap "$OUT/bin/nmap"
chmod 755 "$OUT/bin/nmap"

# nmap is useless without its data files: the service probes, the OS
# fingerprints and the NSE scripts all live outside the binary.
mkdir -p "$OUT/share/nmap"
for f in nmap-services nmap-protocols nmap-rpc nmap-mac-prefixes \
	nmap-os-db nmap-service-probes nmap-payloads; do
	[ -f "$f" ] && cp "$f" "$OUT/share/nmap/"
done
[ -d scripts ] && cp -r scripts "$OUT/share/nmap/"
[ -d nselib ] && cp -r nselib "$OUT/share/nmap/"
[ -f LICENSE ] && cp LICENSE "$OUT/NMAP-LICENSE"

{
	printf 'nmap looks for its data files in a compiled-in prefix.\n'
	printf 'Point it at the bundled copy instead:\n\n'
	printf '  nmap --datadir /path/to/share/nmap ...\n'
} > "$OUT/DATADIR"
exit 0
