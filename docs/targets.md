# Targets

Generated from `targets.sh` by `ci/targets-doc.sh`. Do not edit by hand.

| target | status | ABI | CPU | endianness | qemu |
|---|---|---|---|---|---|
| `x86_64` | active | `x86_64-linux-musl` |  | LSB | `qemu-x86_64-static` |
| `i686` | active | `x86-linux-musl` | `-mcpu=i686` | LSB | `qemu-i386-static` |
| `armv5` | active | `arm-linux-musleabi` | `-mcpu=arm926ej_s` | LSB | `qemu-arm-static` |
| `armv7` | active | `arm-linux-musleabihf` | `-mcpu=cortex_a9-neon-d32` | LSB | `qemu-arm-static` |
| `armv7-neon` | active | `arm-linux-musleabihf` | `-mcpu=cortex_a15` | LSB | `qemu-arm-static` |
| `armv7-aes` | disabled | `arm-linux-musleabihf` | `-mcpu=cortex_a53+aes` | LSB | `qemu-arm-static` |
| `aarch64` | active | `aarch64-linux-musl` |  | LSB | `qemu-aarch64-static` |
| `mips` | active | `mips-linux-musleabi` | `-mcpu=mips32` | MSB | `qemu-mips-static` |
| `mipsel` | active | `mipsel-linux-musleabi` | `-mcpu=mips32` | LSB | `qemu-mipsel-static` |
