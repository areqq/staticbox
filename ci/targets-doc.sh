#!/bin/sh
# Render docs/targets.md from targets.sh, so the two cannot drift apart.
# CI fails if the checked-in copy is stale.
set -eu
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$HERE/targets.sh"

printf '# Targets\n\n'
printf 'Generated from `targets.sh` by `ci/targets-doc.sh`. Do not edit by hand.\n\n'
printf '| target | status | ABI | CPU | endianness | qemu |\n'
printf '|---|---|---|---|---|---|\n'
for t in $(sb_targets_all); do
	if [ "$(sb_target_field "$t" enabled)" = '1' ]; then st='active'; else st='disabled'; fi
	cpu="$(sb_target_field "$t" zig_cpu)"
	printf '| `%s` | %s | `%s` | %s | %s | `%s` |\n' \
		"$t" "$st" \
		"$(sb_target_field "$t" zig_target)" \
		"${cpu:+\`$cpu\`}" \
		"$(sb_target_field "$t" elf_data)" \
		"$(sb_target_field "$t" qemu)"
done
