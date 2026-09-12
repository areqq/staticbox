#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../targets.sh"

assert_eq 'nine targets in the matrix' "$(sb_targets_all | wc -l | tr -d ' ')" '9'
assert_eq 'eight are enabled' "$(sb_targets_enabled | wc -l | tr -d ' ')" '8'
assert_eq 'armv7-aes is the disabled one' "$(sb_target_field armv7-aes enabled)" '0'

assert_eq 'mipsel is little-endian'   "$(sb_target_field mipsel elf_data)" 'LSB'
assert_eq 'mips is big-endian'        "$(sb_target_field mips elf_data)"   'MSB'
assert_eq 'mipsel pins mips32 r1'     "$(sb_target_field mipsel zig_cpu)"  '-mcpu=mips32'
assert_eq 'mipsel is soft-float'      "$(sb_target_field mipsel zig_target)" 'mipsel-linux-musleabi'
assert_eq 'armv7 is hard-float'       "$(sb_target_field armv7 zig_target)"  'arm-linux-musleabihf'
assert_eq 'armv7 baseline is a9, not a7'  "$(sb_target_field armv7 zig_cpu)" '-mcpu=cortex_a9-neon-d32'
assert_eq 'armv7 gates on baseline'   "$(sb_target_field armv7 isa_gate)" 'arm-baseline'
assert_eq 'armv7-neon gates on neon'  "$(sb_target_field armv7-neon isa_gate)" 'arm-neon'
assert_eq 'aarch64 has no isa gate'   "$(sb_target_field aarch64 isa_gate)" 'none'
assert_eq 'mipsel gates on r1'        "$(sb_target_field mipsel isa_gate)" 'mips32r1'

assert_ok    sb_target_exists mipsel
assert_fails sb_target_exists nosucharch
assert_fails sb_target_field nosucharch zig_target

# Every enabled target must name a qemu binary, or the verify gate is a lie.
for t in $(sb_targets_enabled); do
	q="$(sb_target_field "$t" qemu)"
	assert_contains "$t names a qemu binary" "$q" 'qemu-'
done

report test-targets
