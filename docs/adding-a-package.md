# Adding a package

Two files. The recipe compiles; nothing else.

## `packages/<name>/meta`

```sh
PKG=socat
VERSION=1.8.0.0
REVISION=1
SOURCE=http://www.dest-unreach.org/socat/download/socat-1.8.0.0.tar.gz
SHA256=<sha256sum of that exact tarball>
TOOLCHAIN=zig          # or bootlin
TARGETS=all            # or a subset: 'mipsel armv7 x86_64'
SMOKE='-V'             # arguments that prove the binary runs
SMOKE_EXPECT='socat'   # text it must print; use when a zero exit is wrong
```

`SHA256` is not optional and the build refuses to start without it. Pin to a
tag or a release tarball, never to a branch: GitHub regenerates branch tarballs
and they are not byte-stable, so no checksum can hold against one.

`REVISION` is for rebuilding the same upstream version after a fix in the
recipe. The release tag is `<pkg>-v<VERSION>-r<REVISION>`.

### When a zero exit is the wrong thing to demand

Plenty of tools print their usage and exit non-zero when run with no arguments.
That is a working binary. `SMOKE_EXPECT` names a string the program must print,
which is what actually proves its own code ran rather than the loader failing
or the CPU trapping. dsvpn uses this: it exits 254 and prints `DSVPN`.

### Multiple binaries

The gate runs on every executable a recipe leaves in `$OUT`, and one
expectation rarely fits them all. `SMOKE_<name>` and `SMOKE_EXPECT_<name>`
override the package-wide values for one binary, with dashes in the name
spelled as underscores:

```sh
SMOKE_EXPECT='Dropbear SSH multi-purpose'
SMOKE_EXPECT_scp='usage: scp'
```

### Per-target backend

A toolchain limitation is usually per (target, package), not per package:

```sh
TOOLCHAIN=zig
TOOLCHAIN_armv5=bootlin
```

Dashes in a target name become underscores: `TOOLCHAIN_armv7_neon`.

The real case this exists for: zig 0.16 cannot link `armv5` for any program
that calls `malloc`, because its own allocator needs `__sync_*_1` and
`__sync_*_4` that compiler-rt does not provide for pre-ARMv6 parts with no
LDREX/STREX. Bootlin's gcc has them, routed through `__kuser_cmpxchg`.

### Variants

A package can declare `VARIANTS='lean full'`. A variant only worth building
somewhere gets `VARIANT_TARGETS_<variant>`:

```sh
VARIANTS='lean full'
VARIANT_TARGETS_full='armv7-neon mipsel x86_64'
```

### Source dependencies

A package that has to cross-build libraries before it can build itself
declares them as deps. nmap's `full` variant does:

```sh
DEPS_full='openssl libssh2'
DEP_SOURCE_openssl=https://.../openssl-3.0.16.tar.gz
DEP_SHA256_openssl=<sha256>
DEP_SOURCE_libssh2=https://.../libssh2-1.11.0.tar.gz
DEP_SHA256_libssh2=<sha256>
```

`DEPS` applies to every build; `DEPS_<variant>` only to that variant. Each is
fetched, checksum-verified and unpacked to `$SRC_<name>`, and `$DEP_PREFIX` is
a staging directory for them to install into. Patches go in
`patches-<name>/`, not in `patches/`.

## `packages/<name>/verify.sh`

Optional, and run after the generic gate passes. It exists for properties the
gate cannot know about.

nmap's is the example worth copying: the gate proves the binary is for the
right architecture and runs, but it cannot know that the `full` variant was
supposed to contain OpenSSL and libssh2 -- and that is exactly what fails
silently, because a full build whose configure quietly failed to find them
still produces a working nmap, just one where every `ssl-*` and `ssh-*` script
is gone.

It gets `TARGET`, `VARIANT` and `OUT`, and is killed after five minutes. Keep
it that way: a hang under `qemu-mipsel-static` has happened twice in this
codebase, both times on code that was correct on real hardware.

## `packages/<name>/build.sh`

Handed, ready to use: `TARGET VARIANT SRC WORK OUT`,
`CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS`, and `SB_HOST_TRIPLE` for
anything with an autoconf `--host`. The source at `$SRC` is
already fetched, checksum-verified, unpacked and patched.

Put the result in `$OUT` (a `bin/` subdirectory is conventional) and exit 0.

Do not fetch, do not strip, do not package, and do not add `-static` or `-Os`
yourself: they are already in `$LDFLAGS` and `$CFLAGS`, and a recipe that sets
its own loses the target's architecture flags along with them.

Watch for build systems that compile and link in one command without ever
mentioning `LDFLAGS` -- dsvpn's Makefile does exactly that, so `-static` has to
travel in its `OPTFLAGS` or the binary comes out dynamic and the gate rejects it.

## Patches

`packages/<name>/patches/*.patch` are applied with `patch -p1` in lexical
order. A patch that does not apply stops the build: a silently skipped patch
produces a binary that is wrong in a way nothing downstream will catch.

## Trying it

```sh
./build <name> --list
./build <name> mipsel
```

The gate runs automatically. If it rejects the binary, read what it says before
changing the recipe -- it is usually right.
