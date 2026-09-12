# lib/verify.sh -- prove a binary is what it claims before it reaches a device.
#
# Sourced, not executed. Requires targets.sh and lib/log.sh.
#
# Four gates, in increasing cost. The interesting one is the third.
#
# Why the ISA gate is not simply "run it under qemu with the right -cpu":
# qemu-arm-static's cortex-a7 model HAS NEON. A binary built with NEON but
# labelled as our baseline armv7 target therefore runs perfectly under qemu and
# takes a SIGILL on the first box that has an A7 without NEON. qemu cannot
# catch that class of mistake on ARM, so the decisive check reads the build
# attributes the compiler recorded in the ELF instead.
#
# On MIPS it is the other way round: qemu's 4Kc really is a MIPS32 r1 core and
# r2 instructions trap under it, so there qemu is a real gate -- which matters,
# because r2 on a BCM7356 is exactly the failure this project has already hit.

# sb_verify_static <binary> -- no PT_INTERP means no dynamic loader is needed.
# Stronger than `file`, which reports on sections rather than on what the
# kernel will actually try to do at exec time.
sb_verify_static() {
	readelf -h "$1" >/dev/null 2>&1 || { warn "$1 is not an ELF file"; return 1; }
	if readelf -l "$1" 2>/dev/null | grep -q 'INTERP'; then
		warn "$1 is dynamically linked (has a PT_INTERP segment)"
		return 1
	fi
	return 0
}

# sb_verify_elf <binary> <target> -- class, endianness and machine must match
# the matrix. Catches a build that silently produced host objects.
sb_verify_elf() {
	sb__bin="$1"; sb__tgt="$2"
	sb__hdr="$(readelf -h "$sb__bin" 2>/dev/null)" || { warn "$sb__bin is not an ELF file"; return 1; }

	sb__want_class="$(sb_target_field "$sb__tgt" elf_class)"     || return 1
	sb__want_data="$(sb_target_field "$sb__tgt" elf_data)"       || return 1
	sb__want_machine="$(sb_target_field "$sb__tgt" elf_machine)" || return 1

	sb__got_class="$(printf '%s\n' "$sb__hdr" | awk -F: '/^ *Class:/ { gsub(/ /,"",$2); print $2 }')"
	[ "$sb__got_class" = "$sb__want_class" ] || {
		warn "$sb__bin: ELF class $sb__got_class, expected $sb__want_class for $sb__tgt"; return 1; }

	# readelf spells this "2's complement, little endian"; the matrix stores
	# LSB/MSB, matching the spelling used by `file` and by the ELF spec.
	case "$(printf '%s\n' "$sb__hdr" | grep '^ *Data:')" in
		*little*) sb__got_data='LSB' ;;
		*big*)    sb__got_data='MSB' ;;
		*)        sb__got_data='?' ;;
	esac
	[ "$sb__got_data" = "$sb__want_data" ] || {
		warn "$sb__bin: endianness $sb__got_data, expected $sb__want_data for $sb__tgt"; return 1; }

	printf '%s\n' "$sb__hdr" | grep '^ *Machine:' | grep -q "$sb__want_machine" || {
		warn "$sb__bin: machine is not $sb__want_machine as $sb__tgt requires"; return 1; }
	return 0
}

# sb_verify_isa <binary> <target> -- the instruction set actually encoded.
sb_verify_isa() {
	sb__bin="$1"; sb__tgt="$2"
	sb__gate="$(sb_target_field "$sb__tgt" isa_gate)" || return 1
	case "$sb__gate" in
	none) return 0 ;;
	arm-baseline)
		sb__attr="$(readelf -A "$sb__bin" 2>/dev/null)"
		# Tag_Advanced_SIMD_arch present at all means NEON was enabled for some
		# translation unit.
		printf '%s\n' "$sb__attr" | grep -q 'Tag_Advanced_SIMD_arch' && {
			warn "$sb__bin: built with NEON, but $sb__tgt is the no-NEON baseline"; return 1; }
		# The floating-point level matters as much as NEON. VFPv4 traps on a
		# Cortex-A9, and plain "VFPv3" (without -D16) means 32 double registers,
		# which parts with a D16 VFP do not have. Only VFPv2 and VFPv3-D16 are
		# safe across everything this target claims to cover.
		sb__fp="$(printf '%s\n' "$sb__attr" | sed -n 's/.*Tag_FP_arch: *//p' | head -1)"
		case "$sb__fp" in
			''|'VFPv2'|'VFPv3-D16') : ;;
			*) warn "$sb__bin: Tag_FP_arch is $sb__fp; $sb__tgt allows at most VFPv3-D16"; return 1 ;;
		esac
		return 0 ;;
	arm-neon)
		readelf -A "$sb__bin" 2>/dev/null | grep -q 'Tag_Advanced_SIMD_arch' || {
			warn "$sb__bin: no NEON attribute, but $sb__tgt is the NEON target"; return 1; }
		return 0 ;;
	arm-aes)
		readelf -A "$sb__bin" 2>/dev/null | grep -q 'Tag_Advanced_SIMD_arch' || {
			warn "$sb__bin: no SIMD attribute, but $sb__tgt targets crypto extensions"; return 1; }
		return 0 ;;
	mips32r1)
		# EF_MIPS_ARCH lives in the header Flags. r2 there means the binary
		# will trap on a BMIPS5000.
		readelf -h "$sb__bin" 2>/dev/null | grep '^ *Flags:' | grep -q 'mips32r2' && {
			warn "$sb__bin: encoded as mips32r2, which traps on BCM7356 -- $sb__tgt needs r1"; return 1; }
		return 0 ;;
	*) warn "unknown isa gate: $sb__gate"; return 1 ;;
	esac
}

# sb_verify_runs <binary> <target> [args...] -- exec it under qemu-user.
#
# Matching on output rather than on the exit status alone: a tool whose only
# argument-free behaviour is to print usage and exit non-zero is still a
# working binary, while a binary that never reached its own code prints what
# qemu says about the signal. SMOKE_EXPECT, when a package sets it, is the
# string that proves the program's own code ran.
sb_verify_runs() {
	sb__bin="$1"; sb__tgt="$2"; shift 2
	sb__qemu="$(sb_target_field "$sb__tgt" qemu)" || return 1
	sb__qcpu="$(sb_target_field "$sb__tgt" qemu_cpu)" || return 1
	command -v "$sb__qemu" >/dev/null 2>&1 || { warn "$sb__qemu is not installed"; return 1; }

	if [ -n "$sb__qcpu" ]; then
		sb__outp="$("$sb__qemu" -cpu "$sb__qcpu" "$sb__bin" "$@" 2>&1 || true)"
	else
		sb__outp="$("$sb__qemu" "$sb__bin" "$@" 2>&1 || true)"
	fi

	case "$sb__outp" in
		*'Illegal instruction'*|*'could not open'*|*'Invalid ELF'*|*'unsupported'*)
			warn "$sb__bin failed under $sb__qemu: $sb__outp"; return 1 ;;
	esac
	if [ -n "${SMOKE_EXPECT:-}" ]; then
		case "$sb__outp" in
			*"$SMOKE_EXPECT"*) : ;;
			*) warn "$sb__bin ran but did not print '$SMOKE_EXPECT'"; return 1 ;;
		esac
	fi
	return 0
}

# sb_verify <binary> <target> [smoke args...] -- all four, cheapest first.
sb_verify() {
	sb__bin="$1"; sb__tgt="$2"; shift 2
	sb_verify_static "$sb__bin" || return 1
	sb_verify_elf    "$sb__bin" "$sb__tgt" || return 1
	sb_verify_isa    "$sb__bin" "$sb__tgt" || return 1
	sb_verify_runs   "$sb__bin" "$sb__tgt" "$@" || return 1
	log "verified $(basename "$sb__bin") for $sb__tgt"
}
