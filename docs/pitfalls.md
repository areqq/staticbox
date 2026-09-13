# Pitfalls

Every entry here is a failure this repo actually hit. They are written down
because none of them announces its cause: each one either looks like a bug in
the thing being built, or does not fail at all until the binary reaches a
device.

## Flags must reach every object, not just the ones you compile

Putting `-mcpu` in `CFLAGS` is not enough. A bundled library with its own build
rules never sees them. Dropbear bundles libtomcrypt and libtommath: with
`-mcpu=mips32` only in `CFLAGS`, their objects came out at the toolchain's
default ISA, and the linked binary was encoded `mips32r2` -- an illegal
instruction on a BCM7356.

The compiler wrapper carries the target and the CPU, so every invocation gets
them whatever build system produced it. sshd-tunnel learned this from a SIGILL
on real hardware; here the ISA gate caught it on a runner.

The same applies to anything that builds its own compiler name.
`--cross-compile-prefix` in OpenSSL constructs `<triple>-gcc` and runs it
directly, bypassing the wrapper entirely; it is configured through `CC` instead.

## qemu's binfmt handlers make autoconf think it is not cross-compiling

Given only `--host`, autoconf sets `cross_compiling=maybe` and settles the
question by running a test binary. With `qemu-user-static` installed its
binfmt_misc handlers are registered in the kernel, so that *succeeds* — and
autoconf concludes it is a native build and starts running its probes under
emulation.

curl's DNS probe hung there for an hour. The hang was the visible half; the
other half is that every run-test was answering for the emulator rather than
for the device.

Passing `--build` as well as `--host` settles it outright. Every autoconf
recipe here does.

## libtool removes `-static` from the link it generates

`-static` is one of libtool's own options, so it consumes it and does not pass
it to the compiler. `-all-static` is a no-op when no shared libtool libraries
are in the link. curl came out dynamically linked, which the gate caught and a
device would simply have refused to run.

`-XCClinker -static` is the escape hatch: pass the next flag straight to the
linking compiler. It cannot go in `configure`, where libtool is not yet in play
and the compiler sees it raw -- the first check then fails with "C compiler
cannot create executables".

## The host's `strip` refuses a foreign binary

`strip: Unable to recognise the format of the input file`. This is why a build
passes on x86_64 and fails on every other target: the host's strip handles its
own architecture and nothing else.

Stripping happens at link time instead, through `-Wl,-s` in `LDFLAGS`, which
needs nothing installed and keeps `.ARM.attributes` -- the section the ISA gate
reads. Build systems that run `strip` themselves are told not to
(`--disable-stripping` for ffmpeg), or given a shim that succeeds having done
nothing, because the linker already did it.

## Shim objects and build systems that link more than once

The toolchain adds objects to `LDFLAGS` to fix defects in zig's C runtime. A
build system that links in several passes then includes them twice:

- **kbuild** (busybox) computes partial-link flags as
  `filter-out -Wl,%, $(LDFLAGS)`, which keeps a bare object path. The shim is
  folded into `built-in.o` and handed to the final link as well -- "duplicate
  symbol" for everything it defines. Its `LDLIBS` is no better: `trylink`
  rewrites every entry not starting with a dash into `-l<entry>`, so an
  absolute path becomes an absolute system library. busybox compiles the shim
  as one of its own objects instead.
- **ffmpeg** takes `--extra-ldflags` *and* reads `LDFLAGS` from the
  environment. The recipe unsets the environment copy.

The two spellings that would dodge kbuild's filter, `-Wl,<object>` and
`-Wl,--start-lib`, are both rejected by zig's lld as unsupported linker args.

## One float ABI per target, or none

Bootlin publishes no soft-float MIPS toolchain. Its `mips32el` sysroot is
hard-float, so asking for `-msoft-float` objects against it produces an
ABI-mismatched binary, and building honestly hard-float produces one that takes
SIGILL on a MIPS part with no FPU. There is no third option there, which is why
everything MIPS is built with zig, whose `mipsel-linux-musleabi` is soft-float.

A binary is self-consistent or it is broken; two packages for the same target
disagreeing about the ABI is a trap for whoever debugs it later.

## clang assembles `.S` probes for the default architecture

ffmpeg decides which instruction-set extensions it may use by assembling a
small `.S` file. clang's integrated assembler assembles those for the default
architecture whatever `-mcpu` says, so every probe passed on armv5 and it
compiled `rev16` and `movt` into the binary -- ARMv6 and ARMv6T2 instructions
an arm926ej-s does not have.

Where the probes are unreliable, the answer is given rather than asked.

## zig's C runtime has two defects on these targets

Both are compensated in `lib/toolchain.sh`, so no recipe knows about them.

- **MIPS o32 `pipe()`**. The ABI returns both descriptors in registers, not
  through the pointer; zig's uses the ordinary convention. Measured:
  `pipe(fd)` yields 3 instead of 0. Code testing `< 0` survives, code testing
  `!= 0` does not, and the damage is quiet -- a session that opens,
  authenticates and produces no output.
- **ARMv5 atomics**. No LDREX/STREX, so clang emits the legacy `__sync_*`
  libcalls that compiler-rt does not implement, while zig's own allocator calls
  three of them. The shim covers word, byte and eight-byte operations; the
  eight-byte ones go through one global lock, because `__kuser_cmpxchg`
  exchanges a word and `__kuser_cmpxchg64` needs Linux 3.1, newer than these
  parts run.

Each shim carries a self-test that runs under qemu at build time. That matters
more than usual: a wrong result from either links cleanly and fails somewhere
else entirely.

## Upstream hosts are not always reachable from CI

dropbear's own host answers GitHub runners with a Cloudflare 525 while serving
a developer machine perfectly well. Every dropbear job failed in CI and none
failed locally.

`SOURCE` takes a list of URLs. A mirror costs nothing in trust: the checksum
decides whether the bytes are right, so where they came from does not matter.

## GitHub Actions ignores a push of more than three tags

Pushing nine release tags at once triggered no workflow at all. They have to go
one at a time.

## Grepping a build log for "error" hides the error

ffmpeg has `error.c` and `error_resilience.c`, so the filter matched twenty
compile lines and pushed the real message out of view -- CI showed nothing but
`make: Error 1` for six failing jobs. `sb_dump_log` shows genuine diagnostic
lines and then the tail, where a failing make puts the reason.
