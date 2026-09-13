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
| `dsvpn` | a ~100 kB VPN for devices with no `openvpn` |
| `ffmpeg` | transcoding on the box, with `ffprobe`; built-in codecs only |
| `nmap` | the scanner, `lean` without OpenSSL or `full` with it and libssh2 |
| `rsync` | transfers only what changed, which is the point on a slow uplink |
| `socat` | relays between anything and anything when nothing else is installed |
| `speedtest` | an Ookla speedtest.net client |

## Getting a binary onto a device

```sh
wget -qO- https://raw.githubusercontent.com/areqq/staticbox/main/detect.sh | sh
```

prints the target name for that device. Release assets are named
`<package>-<version>-<target>.tar.gz`, each with a `.sha256` beside it and a
`MANIFEST` inside recording the compiler, the flags and the source checksum
the binary was built from.

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

Needs `curl`, `tar`, `make`, `sha256sum`, `readelf` and `qemu-user-static`. The
cross-compiler downloads itself.

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
