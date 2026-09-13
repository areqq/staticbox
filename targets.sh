# targets.sh -- the single source of truth for the target matrix.
#
# Sourced, never executed. Everything that needs to know which architectures
# exist reads this file and nothing else: the build driver, the CI matrix
# generator, detect.sh and the index generator. Adding an architecture is one
# new row here and no edit anywhere else.
#
# Columns, pipe-separated:
#   1  name           canonical target name; the suffix in every release asset
#   2  enabled        0 keeps the row documented but out of every build
#   3  zig_target     -target for `zig cc`
#   4  zig_cpu        -mcpu for `zig cc`, empty for the target's default
#   5  bootlin_tc     Bootlin toolchain slug, without the --musl--stable-VER tail
#   6  bootlin_flags  arch flags for that toolchain's gcc
#   7  qemu           qemu-user binary that can run this target
#   8  qemu_cpu       -cpu model for it, empty for qemu's default
#   9  elf_class      readelf -h "Class"
#   10 elf_data       readelf -h "Data" endianness, LSB or MSB
#   11 elf_machine    substring that must appear in readelf -h "Machine"
#   12 isa_gate       which instruction-set check lib/verify.sh applies
#   13 go_arch        GOARCH for the go backend
#   14 go_env         extra go environment for it (GOARM, GOMIPS, GO386)
#
# Why some values are what they are:
#
#  * armv5, mips and mipsel are soft-float under zig (musleabi, no "hf"). That
#    is the ABI the overwhelming majority of these devices ship, and a float-ABI
#    mismatch does not fail to link -- it dies with an illegal instruction on
#    the device.
#
#    The bootlin columns for mips and mipsel deliberately do NOT say
#    -msoft-float, because Bootlin publishes no soft-float MIPS toolchain: its
#    sysroot crt1.o is hard-float, and asking for soft-float objects against it
#    produces "uses -mhard-float ... uses -msoft-float" and an ABI-mismatched
#    binary. So a MIPS package built on bootlin is hard-float while the same
#    target built on zig is soft-float. Each binary is fully static and
#    self-consistent, so both run; on a part without an FPU the hard-float one
#    pays kernel emulation for floating point, which for a scanner or a
#    downloader is nothing. Worth knowing before moving a package between
#    backends.
#
#  * armv7 is spelled cortex_a9-neon-d32, which is not a typo for a7. The
#    baseline has to be the oldest ARMv7-A hard-float part these tools might
#    land on, and that means VFPv3-D16 with no NEON. Measured, not assumed:
#    cortex_a7 minus neon and d32 still emits Tag_FP_arch VFPv4-D16, which
#    would trap on a Cortex-A9 (VFPv3 only); and subtracting vfp4 as well does
#    not even compile, because musl's own fma.c carries inline asm requiring
#    VFP4 that is selected by the CPU model. cortex_a9 minus neon and d32
#    produces exactly ARMv7-A / VFPv3-D16 / no SIMD.
#
#  * mips/mipsel pin mips32, meaning release 1. BCM7356 (BMIPS5000, the VU+
#    Solo2) traps on r2 instructions, and zig's default for these targets is r2.
#
#  * armv7-aes is disabled, not deleted. For the tools built here the gain from
#    hardware AES is negligible and it would cost a ninth of every CI run.
#    Flip column 2 when a package arrives that genuinely profits from it.

SB_TARGETS='x86_64|1|x86_64-linux-musl||x86-64||qemu-x86_64-static||ELF64|LSB|X86-64|none|amd64|
i686|1|x86-linux-musl|-mcpu=i686|x86-i686||qemu-i386-static||ELF32|LSB|Intel 80386|none|386|GO386=softfloat
armv5|1|arm-linux-musleabi|-mcpu=arm926ej_s|armv5-eabi|-msoft-float|qemu-arm-static|arm926|ELF32|LSB|ARM|none|arm|GOARM=5
armv7|1|arm-linux-musleabihf|-mcpu=cortex_a9-neon-d32|armv7-eabihf|-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard|qemu-arm-static|cortex-a7|ELF32|LSB|ARM|arm-baseline|arm|GOARM=7
armv7-neon|1|arm-linux-musleabihf|-mcpu=cortex_a15|armv7-eabihf|-mcpu=cortex-a15 -mfpu=neon-vfpv4 -mfloat-abi=hard|qemu-arm-static|cortex-a15|ELF32|LSB|ARM|arm-neon|arm|GOARM=7
armv7-aes|0|arm-linux-musleabihf|-mcpu=cortex_a53+aes|armv7-eabihf|-mcpu=cortex-a53+crypto -mfloat-abi=hard|qemu-arm-static|cortex-a53|ELF32|LSB|ARM|arm-aes|arm|GOARM=7
aarch64|1|aarch64-linux-musl||aarch64||qemu-aarch64-static||ELF64|LSB|AArch64|none|arm64|
mips|1|mips-linux-musleabi|-mcpu=mips32|mips32|-march=mips32 -mabi=32|qemu-mips-static|4Kc|ELF32|MSB|MIPS|mips32r1|mips|GOMIPS=softfloat
mipsel|1|mipsel-linux-musleabi|-mcpu=mips32|mips32el|-march=mips32 -mabi=32|qemu-mipsel-static|4Kc|ELF32|LSB|MIPS|mips32r1|mipsle|GOMIPS=softfloat'

SB_TARGET_FIELDS='name enabled zig_target zig_cpu bootlin_tc bootlin_flags qemu qemu_cpu elf_class elf_data elf_machine isa_gate go_arch go_env'

# sb_target_field <target> <field-name> -> value on stdout
sb_target_field() {
	sb__t="$1"; sb__f="$2"
	sb__i=0; sb__n=0
	for sb__c in $SB_TARGET_FIELDS; do
		sb__n=$((sb__n + 1))
		[ "$sb__c" = "$sb__f" ] && sb__i="$sb__n"
	done
	[ "$sb__i" -gt 0 ] || { printf 'targets.sh: no such field: %s\n' "$sb__f" >&2; return 1; }
	sb__row="$(printf '%s\n' "$SB_TARGETS" | awk -F'|' -v t="$sb__t" '$1 == t { print; exit }')"
	[ -n "$sb__row" ] || { printf 'targets.sh: no such target: %s\n' "$sb__t" >&2; return 1; }
	printf '%s\n' "$sb__row" | cut -d'|' -f"$sb__i"
}

sb_targets_all()     { printf '%s\n' "$SB_TARGETS" | cut -d'|' -f1; }
sb_targets_enabled() { printf '%s\n' "$SB_TARGETS" | awk -F'|' '$2 == 1 { print $1 }'; }
sb_target_exists()   { printf '%s\n' "$SB_TARGETS" | awk -F'|' -v t="$1" '$1 == t { found = 1 } END { exit !found }'; }
