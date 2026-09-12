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
#
# Why some values are what they are:
#
#  * armv5, mips and mipsel are soft-float (musleabi, no "hf"). That is the ABI
#    the overwhelming majority of these devices ship, and a float-ABI mismatch
#    does not fail to link -- it dies with an illegal instruction on the device.
#
#  * armv7 explicitly subtracts neon and d32. Plain -mcpu=cortex_a7 turns both
#    on in zig, and a box with an A7 that has no NEON then takes a SIGILL. The
#    baseline target has to actually be the baseline.
#
#  * mips/mipsel pin mips32, meaning release 1. BCM7356 (BMIPS5000, the VU+
#    Solo2) traps on r2 instructions, and zig's default for these targets is r2.
#
#  * armv7-aes is disabled, not deleted. For the tools built here the gain from
#    hardware AES is negligible and it would cost a ninth of every CI run.
#    Flip column 2 when a package arrives that genuinely profits from it.

SB_TARGETS='x86_64|1|x86_64-linux-musl||x86-64||qemu-x86_64-static||ELF64|LSB|X86-64|none
i686|1|x86-linux-musl|-mcpu=i686|x86-i686||qemu-i386-static||ELF32|LSB|Intel 80386|none
armv5|1|arm-linux-musleabi|-mcpu=arm926ej_s|armv5-eabi|-msoft-float|qemu-arm-static|arm926|ELF32|LSB|ARM|none
armv7|1|arm-linux-musleabihf|-mcpu=cortex_a7-neon-d32|armv7-eabihf|-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard|qemu-arm-static|cortex-a7|ELF32|LSB|ARM|arm-baseline
armv7-neon|1|arm-linux-musleabihf|-mcpu=cortex_a15|armv7-eabihf|-mcpu=cortex-a15 -mfpu=neon-vfpv4 -mfloat-abi=hard|qemu-arm-static|cortex-a15|ELF32|LSB|ARM|arm-neon
armv7-aes|0|arm-linux-musleabihf|-mcpu=cortex_a53+aes|armv7-eabihf|-mcpu=cortex-a53+crypto -mfloat-abi=hard|qemu-arm-static|cortex-a53|ELF32|LSB|ARM|arm-aes
aarch64|1|aarch64-linux-musl||aarch64||qemu-aarch64-static||ELF64|LSB|AArch64|none
mips|1|mips-linux-musleabi|-mcpu=mips32|mips32|-march=mips32 -mabi=32 -msoft-float|qemu-mips-static|4Kc|ELF32|MSB|MIPS|mips32r1
mipsel|1|mipsel-linux-musleabi|-mcpu=mips32|mips32el|-march=mips32 -mabi=32 -msoft-float|qemu-mipsel-static|4Kc|ELF32|LSB|MIPS|mips32r1'

SB_TARGET_FIELDS='name enabled zig_target zig_cpu bootlin_tc bootlin_flags qemu qemu_cpu elf_class elf_data elf_machine isa_gate'

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
