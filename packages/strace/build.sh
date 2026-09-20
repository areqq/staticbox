#!/bin/sh
# strace recipe. Compiles only.
#
# Given: TARGET VARIANT SRC WORK OUT CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
#        SB_HOST_TRIPLE SB_BUILD_TRIPLE SB_TARGET_LIBS
set -eu

# Helpers the driver cannot hand over through the environment: a recipe is a
# separate process, so shell functions do not cross into it.
. "$SB_LIB_DIR/log.sh"

cd "$SRC"

# --enable-mpers=no is the one that matters when cross-compiling. "mpers" is
# multiple-personality support: on a 64-bit kernel it lets strace decode the
# structures of a 32-bit process too, and it builds that by compiling parts of
# its own source a second time with -m32 and then reading the DWARF back out.
# That needs a compiler which can target the *other* personality of the host,
# which a cross toolchain aimed at one target is not. Left to `check` it
# either fails the build or silently produces nothing; answered with `no` it
# is simply absent, and every target in this matrix is single-personality
# anyway except aarch64 and x86_64, where the loss is decoding a 32-bit
# process on a 64-bit box.
#
# --enable-stacktrace=no: printing a stack for each call needs libunwind or
# libdw, neither of which is cross-built here. Without it strace still reports
# the calls themselves, which is what anyone is actually after.
#
# --enable-bundled=yes makes strace decode against the kernel headers it
# carries rather than the toolchain's. Left to `check` it takes the
# toolchain's, and 7.2 then fails to compile because it references btrfs
# constants -- BTRFS_FEATURE_INCOMPAT_REMAP_TREE, BTRFS_BLOCK_GROUP_REMAPPED --
# that zig's bundled linux headers are too old to define. The error names a
# btrfs symbol, which is a long way from "the wrong headers were chosen".
#
# Using the bundled set is also simply more correct here: what strace decodes
# is the ABI of the kernel running on the *device*, and the headers that came
# with a cross toolchain say nothing about that either.
# The bundled headers need -I, not the -isystem the build gives them. zig cc
# injects its own system include directories, and they are searched before a
# command-line -isystem, so <linux/btrfs.h> resolved to the toolchain's copy
# even with --enable-bundled=yes -- which is how a build configured to use
# strace's own headers still failed on a constant only strace's own headers
# define. A -I directory is searched before every system directory, so naming
# the bundled uapi tree there settles the order.
#
# It goes in CFLAGS rather than CPPFLAGS because configure overwrites CPPFLAGS
# with its own bundled -isystem pair and drops whatever was handed to it.
# Position on the command line does not matter: clang searches every -I
# directory before every system directory whatever order they arrive in.
./configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" \
	CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--enable-mpers=no --enable-stacktrace=no --enable-bundled=yes \
	--disable-gcc-Werror \
	LIBS="$SB_TARGET_LIBS" \
	>"$WORK/configure.log" 2>&1 \
	|| { sb_dump_log "$WORK/configure.log"; exit 1; }

# The bundled headers are handed to the compiler as a *copy* under a different
# path, and this is the whole trick. Naming the original directory does not
# work: strace already passes it as "-isystem ../bundled/linux/include/uapi",
# clang de-duplicates a directory that appears as both -I and -isystem by
# keeping only the system entry, and zig's own headers are searched earlier in
# the system chain. So the -I is silently demoted and <linux/btrfs_tree.h>
# resolves to zig's copy after all. A second path is a different directory as
# far as clang is concerned, so the -I keeps its priority.
#
# CPPFLAGS is set here rather than handed to configure, which discards what it
# is given and writes its own value; a make command-line variable outranks the
# Makefile's. What it replaces is a broken duplicate anyway: configure emits
# "-isystem ./bundled/..." relative to the top build directory, which resolves
# to nothing from src/ where compilation happens.
mkdir -p "$WORK/kheaders"
cp -r "$SRC/bundled/linux/include/uapi/." "$WORK/kheaders/"

make -j"$(nproc 2>/dev/null || echo 2)" \
	CPPFLAGS="-I$WORK/kheaders" \
	>"$WORK/make.log" 2>&1 \
	|| { sb_dump_log "$WORK/make.log"; exit 1; }

BIN='src/strace'
[ -f "$BIN" ] || BIN='strace'
[ -f "$BIN" ] || { printf 'strace binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/strace"
chmod 755 "$OUT/bin/strace"
[ -f COPYING ] && cp COPYING "$OUT/STRACE-LICENSE"

{
	printf 'The three invocations worth knowing on a box:\n\n'
	printf '  strace -f -e trace=file -p <pid>    which files it looks for\n'
	printf '  strace -f -o /tmp/t.log <command>   follow children into a file\n'
	printf '  strace -c -p <pid>                  where the time goes\n\n'
	printf 'Attaching needs root and a kernel that permits it. If -p fails\n'
	printf 'with "Operation not permitted" while running as root, the kernel\n'
	printf 'has ptrace_scope locked:\n\n'
	printf '  echo 0 > /proc/sys/kernel/yama/ptrace_scope\n\n'
	printf 'Stack traces (-k) are not compiled in: they need libunwind, which\n'
	printf 'is not worth cross-building for a box. The syscalls are there.\n'
} > "$OUT/README-STRACE"
exit 0
