#!/bin/sh
# git recipe. Compiles only: the driver has already fetched, verified and
# unpacked git, zlib, OpenSSL and curl.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS
#        LDFLAGS SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS DEP_PREFIX
#        SRC_zlib SRC_openssl SRC_curl
#
# Built in dependency order: zlib, then OpenSSL, then curl against both, then
# git against all three.
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

JOBS="$(nproc 2>/dev/null || echo 2)"

# --------------------------------------------------------------------- zlib
# zlib has a hand-written configure that takes no --host: it reads CC, AR and
# RANLIB from the environment and compiles its probes with them, which is
# enough to cross-build correctly. --static skips the shared object, which
# would fail to link against the non-PIC static CRT anyway.
#
# SRC_zlib, SRC_openssl and SRC_curl are exported by the driver for the deps
# declared in meta, which the linter has no way to see.
# shellcheck disable=SC2154
( cd "$SRC_zlib"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS" \
	./configure --static --prefix="$DEP_PREFIX" \
	>"$WORK/zlib-configure.log" 2>&1
  make -j"$JOBS" >"$WORK/zlib-make.log" 2>&1
  make install >>"$WORK/zlib-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/zlib-make.log"; sb_dump_log "$WORK/zlib-configure.log"; exit 1; }

# ------------------------------------------------------------------ OpenSSL
# The same three traps as in packages/curl/build.sh and packages/nmap/build.sh,
# and for the same reasons: Configure appends --cross-compile-prefix to CC, so
# CC must be unset here or it builds <triple>-<triple>-gcc; no-docs does not
# exist in 3.0.x and makes Configure stop with "Unsupported options"; and
# build_libs + install_dev gives the libraries without the openssl application,
# which is not wanted and does not link on MIPS32 anyway.
#
# Configured through CC rather than --cross-compile-prefix: the prefix option
# builds its own "<triple>-gcc" and calls it directly, bypassing our compiler
# wrapper and leaving OpenSSL's objects at the toolchain's default ISA -- on
# MIPS that default is r2, which is an illegal instruction on the r1 parts this
# targets. Naming CC keeps every object on one compiler.
#
# no-threads because OpenSSL's threading layer calls __atomic_is_lock_free and
# __atomic_fetch_or_8, which on MIPS32 live in libatomic. git drives curl
# synchronously from one thread, so the threading layer buys it nothing.
# shellcheck disable=SC2154
( cd "$SRC_openssl"
  unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  ./Configure linux-generic32 no-shared no-dso no-engine no-tests no-async \
	no-threads \
	--prefix="$DEP_PREFIX" --openssldir="$DEP_PREFIX/ssl" \
	CC="$CC" AR="$AR" RANLIB="$RANLIB" \
	>"$WORK/openssl-configure.log" 2>&1
  make -j"$JOBS" build_libs >"$WORK/openssl-make.log" 2>&1
  make install_dev >>"$WORK/openssl-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/openssl-make.log"; sb_dump_log "$WORK/openssl-configure.log"; exit 1; }

# --------------------------------------------------------------------- curl
# Only libcurl is wanted, but the whole thing is built the way packages/curl
# builds it, -XCClinker and all. That flag is libtool's escape hatch: pass the
# next option straight to the linking compiler. Without it libtool swallows a
# plain -static as one of its own options and leaves it out of the command it
# generates, and the curl program comes out dynamic.
#
# Everything that would pull in another library is off, exactly as in
# packages/curl: none of libidn2, libpsl, zstd, brotli or nghttp2 earns its own
# cross-build for fetching a repository onto a set-top box.
#
# The CA paths are compiled in because the alternative is worse: with only
# --with-ca-fallback, curl falls back to OpenSSL's built-in default, which is
# $DEP_PREFIX/ssl -- a directory on the build machine that will never exist on
# a device. Naming the conventional locations gives git somewhere real to look
# first. When a box has neither, the failure is the same clear "unable to get
# local issuer certificate" as before, and README-GIT says which knob fixes it.
# shellcheck disable=SC2154
( cd "$SRC_curl"
  ./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS -L$DEP_PREFIX/lib" \
	CPPFLAGS="-I$DEP_PREFIX/include" \
	--prefix="$DEP_PREFIX" \
	--with-openssl="$DEP_PREFIX" --with-zlib="$DEP_PREFIX" \
	--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
	--with-ca-path=/etc/ssl/certs --with-ca-fallback \
	--disable-shared --enable-static \
	--without-libidn2 --without-libpsl --without-nghttp2 \
	--without-zstd --without-brotli --without-librtmp \
	--disable-ldap --disable-ldaps \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/curl-configure.log" 2>&1
  make -j"$JOBS" LDFLAGS="$LDFLAGS -XCClinker -static -L$DEP_PREFIX/lib" \
	>"$WORK/curl-make.log" 2>&1
  make install >>"$WORK/curl-make.log" 2>&1 ) \
	|| { sb_dump_log "$WORK/curl-make.log"; sb_dump_log "$WORK/curl-configure.log"; exit 1; }

# ---------------------------------------------------------------------- git
cd "$SRC"

# Two programs are dropped before the build, not after it, so the time to
# compile and link them is saved too.
#
#  git-http-fetch  the client for the *dumb* HTTP protocol -- a repository
#                  served as a plain directory of files by a web server with no
#                  git backend. Smart HTTP replaced it in 2010 and `git clone
#                  https://...` never invokes it. Dumb HTTP still works
#                  regardless: git-remote-http links http-walker.o itself, so
#                  the fallback lives there and not in this program.
#  git-imap-send   puts a patch series into an IMAP Drafts folder so a mail
#                  client can send it. A kernel-list workflow, on a set-top box.
#
# They are not small. Each links its own copy of libcurl and OpenSSL, which on
# armv5 is 4.4 MB apiece -- 8.8 MB of a 21 MB install for two things nobody
# will run on one of these devices.
#
# PROGRAMS is derived from PROGRAM_OBJS, so deleting these two lines removes
# them from the build and from the install alike. EXCLUDED_PROGRAMS would not:
# it only feeds generate-cmdlist.sh, which is why it is also set in config.mak
# -- otherwise `git help -a` would still list two commands that are not there.
sed -i '/^PROGRAM_OBJS += imap-send\.o$/d'   Makefile
sed -i '/^	PROGRAM_OBJS += http-fetch\.o$/d' Makefile
grep -q 'PROGRAM_OBJS += imap-send\.o' Makefile && {
	printf 'imap-send.o was not removed from PROGRAM_OBJS\n' >&2; exit 1; }
grep -q 'PROGRAM_OBJS += http-fetch\.o' Makefile && {
	printf 'http-fetch.o was not removed from PROGRAM_OBJS\n' >&2; exit 1; }

# git's own configuration mechanism, read after config.mak.uname and before
# everything that acts on these variables. Used rather than a make command line
# so that `EXTLIBS +=` appends to the platform defaults instead of replacing
# them: config.mak.uname adds -ldl there for Linux, and an override would drop
# it.
#
# Each setting, and why:
#
#  NO_REGEX            musl's regex.h has no REG_STARTEND, and git's grep needs
#                      it to match inside a buffer it does not own. Neither
#                      zig's musl nor Bootlin's has it, so git uses the compat
#                      regex it carries for exactly this case. "NeedsStartEnd"
#                      is the value upstream uses; the Makefile only tests
#                      whether it is defined.
#  RUNTIME_PREFIX      decisive here. git otherwise compiles its exec-path and
#                      template directory in as absolute paths under $prefix,
#                      and install.sh unpacks this tarball wherever the device
#                      has room -- usually /tmp/staticbox/git. With
#                      RUNTIME_PREFIX git resolves them relative to its own
#                      binary through /proc/self/exe, which is what makes
#                      git-remote-https findable after the move. Without it
#                      every https URL fails with "Unable to find remote helper
#                      for 'https'" on a binary that links libcurl perfectly.
#  NO_GETTEXT          no translations, no msgfmt on the build host, and no
#                      libintl to cross-build for a box that has one locale.
#  NO_PERL/PYTHON/TCLTK  drops git-svn, git-send-email, gitk and git-gui --
#                      every part of git that is a script needing an
#                      interpreter these devices do not have.
#  NO_EXPAT            drops git-http-push, which speaks the dumb WebDAV
#                      protocol. Pushing over https uses git-remote-https and
#                      the smart protocol, which needs no XML parser.
#  NO_OPENSSL          git's own use of OpenSSL is SHA-1 and imap-send. Turning
#                      it off leaves git on sha1collisiondetection, upstream's
#                      default. TLS still happens -- inside libcurl.
#  NO_RUST             2.55 builds part of libgit as a Rust staticlib and needs
#                      cargo to do it. Cross-compiling that would mean a rustup
#                      toolchain plus a std for every musl target in the
#                      matrix, next to the zig and Bootlin backends already
#                      here -- a third toolchain for a subsystem whose C
#                      equivalent is still in the tree and still the default.
#                      Upstream says Rust becomes mandatory in git 3.0, so this
#                      line is what has to be solved before this package can
#                      follow git past 2.x.
#  LINK_FUZZ_PROGRAMS  cleared, not set. config.mak.uname turns it on for every
#                      Linux build, which makes `make all` also link the
#                      oss-fuzz harnesses -- with --allow-multiple-definition,
#                      an argument zig's linker refuses outright. They are
#                      fuzzing scaffolding that is never installed, so the
#                      whole group is dropped rather than argued with.
#  CURL_*              set explicitly rather than left to curl-config, so the
#                      static link order is ours: -lcurl before the libraries
#                      it needs, or the symbols resolve nowhere.
{
	printf 'CC = %s\n'      "$CC"
	printf 'AR = %s\n'      "$AR"
	printf 'RANLIB = %s\n'  "$RANLIB"
	printf 'CFLAGS = %s\n'  "$CFLAGS"
	printf 'LDFLAGS = %s\n' "$LDFLAGS"

	printf 'NO_REGEX = NeedsStartEnd\n'
	printf 'RUNTIME_PREFIX = YesPlease\n'
	printf 'NO_GETTEXT = YesPlease\n'
	printf 'NO_PERL = YesPlease\n'
	printf 'NO_PYTHON = YesPlease\n'
	printf 'NO_TCLTK = YesPlease\n'
	printf 'NO_EXPAT = YesPlease\n'
	printf 'NO_OPENSSL = YesPlease\n'
	printf 'NO_RUST = YesPlease\n'
	printf 'LINK_FUZZ_PROGRAMS =\n'
	printf 'EXCLUDED_PROGRAMS += git-http-fetch git-imap-send\n'

	printf 'ZLIB_PATH = %s\n' "$DEP_PREFIX"
	printf 'CURL_CONFIG = %s/bin/curl-config\n' "$DEP_PREFIX"
	printf 'CURL_CFLAGS = -I%s/include\n' "$DEP_PREFIX"
	printf 'CURL_LDFLAGS = -L%s/lib -lcurl -lssl -lcrypto -lz\n' "$DEP_PREFIX"

	# MIPS32's missing 64-bit atomics come from the toolchain as
	# SB_TARGET_LIBS (-latomic there). It has to land after the objects, and
	# EXTLIBS is the only variable git places there.
	[ -n "$SB_TARGET_LIBS" ] && printf 'EXTLIBS += %s\n' "$SB_TARGET_LIBS"
} > config.mak

# Cross-compiling, so nothing built here can be executed to answer a question.
# These are the answers for the targets in this matrix -- all Linux, all musl.
#
#  uname_S is the host's, and both host and target are Linux, so the platform
#  block in config.mak.uname is already the right one and is left alone.
make -j"$JOBS" \
	prefix=/ \
	gitexecdir=libexec/git-core \
	template_dir=share/git-core/templates \
	>"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

[ -f git ] || { printf 'git binary was not produced\n' >&2; exit 1; }

# NO_INSTALL_HARDLINKS is deliberately not set, so git installs its ~150
# commands as hard links to one binary rather than as symlinks. The worry that
# stopped this the first time -- that busybox tar would not restore a hard link
# and would leave a silently broken tree -- turned out to be wrong when checked
# against the busybox this repo builds: the link comes back with a link count
# of 2 and the right contents. It is worth checking, because git also copies
# bin/git and bin/git-shell into libexec: measured on armv5, 21.7 MB installed
# with hard links against 27.1 MB with symlinks, on a device whose /tmp is
# usually RAM.
make install DESTDIR="$OUT" \
	prefix=/ \
	gitexecdir=libexec/git-core \
	template_dir=share/git-core/templates \
	>"$WORK/install.log" 2>&1 \
	|| { sb_dump_log "$WORK/install.log"; exit 1; }

# git-cvsserver is Perl, so under NO_PERL what install puts in bin/ is the
# stub that prints "git was built without support for git-cvsserver". bin/ is
# what goes on the device's PATH and what the installer lists, and a shell
# script announcing a missing feature does not belong there -- the gate is
# right to refuse a non-ELF file in bin/. The copy in libexec/git-core stays,
# so `git cvsserver` still explains itself instead of saying "not a git
# command".
rm -f "$OUT/bin/git-cvsserver"

[ -f COPYING ] && cp COPYING "$OUT/GIT-LICENSE"

{
	printf 'git resolves its helpers relative to its own binary, so this\n'
	printf 'tree can live anywhere as long as it stays whole:\n\n'
	printf '  bin/git, libexec/git-core/ and share/git-core/ together.\n\n'
	printf 'https works out of the box. If the box has no CA store, git will\n'
	printf 'say so on the first fetch; point it at one:\n\n'
	printf '  git config --global http.sslCAInfo /path/to/ca-bundle.crt\n\n'
	printf 'ssh:// runs whatever GIT_SSH names, and dropbear is fine:\n\n'
	printf '  GIT_SSH=/path/to/dbclient git clone ssh://user@host/repo.git\n\n'
	printf 'git probes an unknown ssh with -G, dbclient refuses it, and git\n'
	printf 'falls back to passing nothing but -p and the host -- which is what\n'
	printf 'dbclient wants. Force it with ssh.variant=simple if it ever guesses\n'
	printf 'otherwise.\n'
} > "$OUT/README-GIT"
exit 0
