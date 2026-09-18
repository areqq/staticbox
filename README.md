# staticbox

Statically linked binaries for embedded Linux boxes: Enigma2 set-top boxes and
OpenWrt routers. Nothing here links against anything on the device.

One recipe per tool, eight architectures, and every binary checked against what
it actually contains before it is released.

| package | what it is |
|---|---|
| `busybox` | 396 applets in one binary -- a working userland on a box whose own is from 2014 |
| `curl` | with TLS, because almost everything worth fetching is https and the busybox wget on these boxes no longer negotiates with anything |
| `dropbear` | SSH client and server plus key tools in one multi-call binary, and `scp` |
| `dsvpn` | a ~100 kB VPN -- a fraction of `openvpn`, but it only talks to another `dsvpn` |
| `ffmpeg` | transcoding on the box, with `ffprobe`; built-in codecs only |
| `git` | clone and push over https and ssh, with its helpers and templates; relocatable |
| `ncat` | netcat with brokering, HTTP/SOCKS proxying, access control and `--lua-exec` |
| `nmap` | the scanner, `lean` without OpenSSL or `full` with it and libssh2 |
| `openvpn` | client and server in one binary, built against mbedTLS rather than OpenSSL |
| `rsync` | transfers only what changed, which is the point on a slow uplink |
| `socat` | relays between anything and anything when nothing else is installed |
| `speedtest` | an Ookla speedtest.net client |
| `wget` | recursive mirroring, which `curl` cannot do, with working TLS |
| `wireguard-go` | the WireGuard daemon in userspace, for a box whose kernel has no module |
| `wireguard-tools` | `wg`, which configures a tunnel -- needed by the above, and by the kernel module |

## Getting a binary onto a device

```sh
wget -qO- https://raw.githubusercontent.com/areqq/staticbox/main/install.sh > /tmp/i.sh
sh /tmp/i.sh
```

It works out what the device is, lists what it can put there, and installs
what you pick into `/tmp/staticbox`:

```
  device : mips  ->  mipsel  (MIPS32 r1, little-endian, soft-float)
  install: /tmp/staticbox

   1) busybox            1.37.0
   2) curl               8.18.0
   3) dropbear           2026.94
   ...

  which? (numbers, "a" for all, empty to quit): 1 3
```

Or skip the asking:

```sh
sh /tmp/i.sh busybox dropbear   # by name
sh /tmp/i.sh --all              # everything for this device
sh /tmp/i.sh --detect           # just print the target name
sh /tmp/i.sh --list             # just show what is available
```

Piping it straight into `sh` shows the list and then explains how to choose:
with the script on stdin there is no way to read an answer from there, and
`/dev/tty` is not always available either.

Release assets are named `<package>-<version>-<target>.tar.gz`, each with a
`.sha256` beside it and a `MANIFEST` inside recording the compiler, the flags
and the source checksum the binary was built from.

## Targets

See [docs/targets.md](docs/targets.md). The short version: `armv7` is a real
baseline (VFPv3-D16, no NEON), `armv7-neon` is for boxes that have it, MIPS is
pinned to release 1 because a BCM7356 traps on r2 instructions, and everything
below ARMv7 is soft-float because that is what those devices ship.

## Building locally

```sh
./build dsvpn              # every enabled target
./build dsvpn mipsel       # one
./build dsvpn --list       # what this package supports, and on which backend
sh tests/run-all.sh        # the suite; no network, builds nothing
```

A few checks compare the gate and the detector against real foreign binaries,
which the suite has no way to conjure. Point it at any static mipsel and 32-bit
ARM binary to run them -- unpacking two of this repo's own release tarballs is
the easy way:

```sh
SB_FIXTURE_MIPSEL=/tmp/m/bin/busybox SB_FIXTURE_ARM=/tmp/a/bin/busybox \
	sh tests/run-all.sh
```

Needs `curl`, `tar`, `make`, `sha256sum`, `readelf` and `qemu-user-static`,
plus `autoconf`, `automake` and `libtool` if you build `openvpn` -- its
libcap-ng dependency ships only a git tag with no generated `configure`. The
cross-compiler downloads itself.

## What went wrong before

[docs/pitfalls.md](docs/pitfalls.md) collects the failures this repo has
actually hit, and why none of them announced its cause.

## Adding a package

See [docs/adding-a-package.md](docs/adding-a-package.md). Two files: a `meta`
declaring what to fetch and how, and a `build.sh` that does nothing but compile.

## Why the verification gate is the way it is

`qemu-arm-static`'s cortex-a7 model has NEON. A binary built with NEON but
labelled as the baseline target therefore runs perfectly under qemu and takes a
SIGILL on the first box that has an A7 without NEON. So on ARM the decisive
check reads the build attributes the compiler recorded in the ELF, not the
behaviour under emulation.

On MIPS it is the other way round: qemu's 4Kc really is a MIPS32 r1 core, so
there running the binary catches the r2 encoding that traps on a BCM7356.

Both of those are failures this code has already hit on real hardware. The gate
exists so they are caught on a runner instead.
