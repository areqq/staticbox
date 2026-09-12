# staticbox — Etap 0: szkielet i pakiet pilotażowy

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować kompletny rurociąg — macierz targetów, warstwę wspólną, driver, detektor i CI — i udowodnić go na `dsvpn`, najmniejszym pakiecie.

**Architecture:** Jedna tabela targetów w `targets.sh` jest jedynym źródłem prawdy; `lib/` robi wszystko poza kompilacją (pobranie, weryfikacja sum, bramka ELF, pakowanie); przepis pakietu dostaje gotowy zestaw zmiennych i nie wie, który toolchain go kompiluje.

**Tech Stack:** POSIX `sh` (cel: busybox ash z ok. 2014), `zig cc` 0.16.0, toolchainy Bootlin `stable-2025.08-1`, `qemu-user-static`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-13-static-binaries-design.md`

## Global Constraints

- **Każdy skrypt to POSIX `sh`**, nie bash. Bez tablic, `[[`, `local` (poza `lib/`, gdzie i tak nie), bez `${var,,}`. `detect.sh` i `get.sh` dodatkowo: bez `mktemp`, `id`, `diff`, `cmp`, `find -maxdepth`; `command -v` zawsze z fallbackiem na `which`.
- **Język repo: angielski** — kod, komentarze, nazwy, README, `docs/`. Spec i plany po polsku.
- **Nazwy targetów**: `x86_64 i686 armv5 armv7 armv7-neon armv7-aes aarch64 mips mipsel`. Dokładnie te ciągi w nazwach assetów, wyjściu `detect.sh` i kluczach indeksu.
- **`armv7-aes` ma `enabled=0`** — osiem aktywnych targetów.
- **`mips`/`mipsel` to `mips32` r1**, nie r2. **`armv5`, `mips`, `mipsel` są soft-float** (`musleabi`). **`armv7*` jest hard-float** (`musleabihf`).
- **`armv7` to baseline bez NEON i bez d32.** Sam `-mcpu=cortex_a7` w Zigu włącza oba — musi być jawnie odjęte.
- **Zig 0.16.0, suma przypięta**: host x86_64 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`, host aarch64 `ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17`.
- **Każde pobierane źródło ma przypiętą sumę SHA-256.** Brak sumy = build się nie uruchamia.
- **Testy to POSIX `sh`** w `tests/`, w stylu `sshd-tunnel/tests/` (`lib.sh` z asercjami, `run-all.sh` jako runner).
- **Commity po angielsku**, tryb rozkazujący, bez prefiksów typu `feat:`.

---

## Struktura plików

| plik | odpowiedzialność |
|---|---|
| `targets.sh` | tabela macierzy + akcesory. Jedyne miejsce z listą architektur. |
| `lib/toolchain.sh` | `zig`\|`bootlin` → `CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS`. Pobiera i cache'uje toolchain. |
| `lib/fetch.sh` | pobranie źródła, weryfikacja `SHA256`, rozpakowanie, nałożenie patchy. |
| `lib/verify.sh` | bramka: brak `PT_INTERP`, zgodność `readelf -h`, bramka ISA, uruchomienie pod qemu. |
| `lib/pack.sh` | `strip`, `MANIFEST`, `tar.gz`, `.sha256`. |
| `lib/log.sh` | `log`/`die`/`warn` — wspólne dla wszystkich powyższych. |
| `build` | driver: parsowanie argumentów, wczytanie `meta`, pętla po targetach, wywołanie `lib/` i przepisu. |
| `detect.sh` | detekcja targetu na urządzeniu docelowym. Zero zależności od `lib/`. |
| `packages/dsvpn/meta` | deklaracja pakietu. |
| `packages/dsvpn/build.sh` | przepis: tylko kompilacja. |
| `packages/dsvpn/patches/0001-no-system-changes.patch` | patch przeniesiony z `sshd-tunnel`. |
| `tests/lib.sh` | asercje i liczniki. |
| `tests/run-all.sh` | runner. |
| `tests/test-*.sh` | jeden plik na moduł. |
| `.github/workflows/build.yml` | `prepare` → `build` → `verify-deep` → `release`. |

---

## Task 1: `targets.sh` — macierz jako jedyne źródło prawdy

**Files:**
- Create: `targets.sh`
- Create: `tests/lib.sh`
- Create: `tests/run-all.sh`
- Test: `tests/test-targets.sh`

**Interfaces:**
- Consumes: nic
- Produces:
  - `SB_TARGETS` — wielolinijkowy ciąg, wiersze rozdzielone `\n`, pola `|`
  - `sb_target_field <name> <field_name>` → wypisuje wartość pola na stdout, exit 1 gdy target nieznany
  - `sb_targets_all` → nazwy wszystkich targetów, po jednej w wierszu
  - `sb_targets_enabled` → jw., tylko te z `enabled=1`
  - `sb_target_exists <name>` → exit 0/1
  - nazwy pól: `name enabled zig_target zig_cpu bootlin_tc bootlin_flags qemu qemu_cpu elf_class elf_data elf_machine isa_gate`

- [ ] **Step 1: Write the test harness**

Create `tests/lib.sh`:

```sh
# Shared assertions for the staticbox test suite. Sourced, not executed.
CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else
		fail "$1"; printf '       expected: %s\n       actual:   %s\n' "$3" "$2"
	fi
}

assert_ok() {
	if "$@" >/dev/null 2>&1; then pass "$1 exits 0"; else fail "$1 exits 0"; fi
}

assert_fails() {
	if "$@" >/dev/null 2>&1; then fail "$1 exits non-zero"; else pass "$1 exits non-zero"; fi
}

assert_contains() {
	case "$2" in
		*"$3"*) pass "$1" ;;
		*) fail "$1"; printf '       %s does not contain %s\n' "$2" "$3" ;;
	esac
}

report() {
	printf '%s: %d checks, %d failures\n' "$1" "$CHECKS" "$FAILURES"
	[ "$FAILURES" -eq 0 ]
}
```

Create `tests/run-all.sh`:

```sh
#!/bin/sh
# Run every test-*.sh in this directory. Exits non-zero if any fails.
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
	[ -f "$t" ] || continue
	printf '\n== %s\n' "$(basename "$t")"
	sh "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 2: Write the failing test**

Create `tests/test-targets.sh`:

```sh
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
assert_eq 'armv7 subtracts neon/d32'  "$(sb_target_field armv7 zig_cpu)" '-mcpu=cortex_a7-neon-d32'
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
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `sh tests/test-targets.sh`
Expected: FAIL — `targets.sh: No such file or directory`

- [ ] **Step 4: Write `targets.sh`**

```sh
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
#    hardware AES is negligible and it would cost an ninth of every CI run.
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh tests/test-targets.sh`
Expected: `test-targets: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 6: Commit**

```bash
chmod +x tests/run-all.sh
git add targets.sh tests/lib.sh tests/run-all.sh tests/test-targets.sh
git commit -m "Add the target matrix as the single source of truth

Nine targets, eight enabled. Every value that differs from a compiler's
default is there because a device made it necessary: soft-float on armv5 and
MIPS, mips32 r1 for BCM7356, and an armv7 baseline with NEON and d32
explicitly subtracted so it is actually a baseline."
```

---

## Task 2: `lib/log.sh` i `lib/toolchain.sh` — kontrakt kompilatora

**Files:**
- Create: `lib/log.sh`
- Create: `lib/toolchain.sh`
- Test: `tests/test-toolchain.sh`

**Interfaces:**
- Consumes: `targets.sh` (`sb_target_field`)
- Produces:
  - `log <msg>`, `warn <msg>`, `die <msg>` (z `lib/log.sh`)
  - `sb_tc_flags <target> <backend>` → wypisuje `CFLAGS` dla tej pary; **czysta funkcja, bez sieci** — to ona jest testowana
  - `sb_tc_setup <target> <backend> <cache_dir>` → pobiera toolchain jeśli trzeba i eksportuje `CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS SB_TARGET SB_BACKEND`
  - `backend` ∈ `zig` `bootlin`

Rozbicie na `sb_tc_flags` (czystą) i `sb_tc_setup` (pobierającą) jest celowe: flagi to miejsce, gdzie mieszka cała wiedza o architekturach i gdzie pojawi się błąd, a testowanie ich nie może wymagać ściągania 55 MB.

- [ ] **Step 1: Write the failing test**

Create `tests/test-toolchain.sh`:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../targets.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/toolchain.sh"

# Size and static linking are not per-package choices: every target gets them.
for t in $(sb_targets_enabled); do
	f="$(sb_tc_flags "$t" zig)"
	assert_contains "$t/zig optimises for size"  "$f" '-Os'
	assert_contains "$t/zig splits functions"    "$f" '-ffunction-sections'
	assert_contains "$t/zig splits data"         "$f" '-fdata-sections'
done

assert_contains 'armv7/zig subtracts neon' "$(sb_tc_flags armv7 zig)" '-mcpu=cortex_a7-neon-d32'
assert_contains 'armv7-neon/zig takes a15' "$(sb_tc_flags armv7-neon zig)" '-mcpu=cortex_a15'
assert_contains 'mipsel/zig pins mips32'   "$(sb_tc_flags mipsel zig)" '-mcpu=mips32'

# The bootlin backend uses gcc spellings, which differ from zig's.
assert_contains 'mipsel/bootlin uses -march' "$(sb_tc_flags mipsel bootlin)" '-march=mips32'
assert_contains 'mipsel/bootlin is softfp'   "$(sb_tc_flags mipsel bootlin)" '-msoft-float'
assert_contains 'armv7/bootlin caps the fpu' "$(sb_tc_flags armv7 bootlin)" '-mfpu=vfpv3-d16'

assert_fails sb_tc_flags mipsel nosuchbackend
assert_fails sb_tc_flags nosucharch zig

report test-toolchain
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-toolchain.sh`
Expected: FAIL — `lib/log.sh: No such file or directory`

- [ ] **Step 3: Write `lib/log.sh`**

```sh
# Shared output helpers. Sourced, not executed.
# SB_PROG is set by whoever sources this; it prefixes every diagnostic so a
# failure in a nested build names the layer it came from.
: "${SB_PROG:=staticbox}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '%s: %s\n' "$SB_PROG" "$*" >&2; }
die()  { printf '%s: %s\n' "$SB_PROG" "$*" >&2; exit 1; }
```

- [ ] **Step 4: Write `lib/toolchain.sh`**

```sh
# lib/toolchain.sh -- turn (target, backend) into a working compiler.
#
# Sourced, not executed. Requires targets.sh and lib/log.sh to be sourced first.
#
# Two backends, and the split is deliberate. `zig cc` is the default: one 55 MB
# download covers every target and builds musl per target into a cache, instead
# of a 75 MB toolchain per architecture. `bootlin` exists because some packages
# are already proven against it -- nmap with OpenSSL and libssh2 is the case
# this was kept for -- and porting a working build to a new compiler is a task
# of its own, not a precondition for this repo.
#
# A recipe never learns which of the two compiled it. That is the whole point:
# moving a package between backends is one line in its `meta`.

SB_ZIG_VER="${SB_ZIG_VER:-0.16.0}"
SB_TC_VER="${SB_TC_VER:-2025.08-1}"
SB_BOOTLIN_BASE='https://toolchains.bootlin.com/downloads/releases/toolchains'

# Pinned from https://ziglang.org/download/index.json. A new zig release needs
# its sums added here; an unpinned download is not accepted.
sb__zig_sha() {
	case "$SB_ZIG_VER::$1" in
		0.16.0::x86_64)  printf '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00\n' ;;
		0.16.0::aarch64) printf 'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17\n' ;;
		*) return 1 ;;
	esac
}

# Flags that every target gets, whatever the backend. -Os plus section
# splitting plus --gc-sections is what keeps these binaries small enough to
# hand to a device with a few megabytes of flash.
SB_COMMON_CFLAGS='-Os -ffunction-sections -fdata-sections'
SB_COMMON_LDFLAGS='-static -Wl,--gc-sections'

# sb_tc_flags <target> <backend> -> the CFLAGS for that pair, on stdout.
# Pure: touches no network and no filesystem, so it can be tested directly.
sb_tc_flags() {
	sb__tgt="$1"; sb__be="$2"
	sb_target_exists "$sb__tgt" || { warn "no such target: $sb__tgt"; return 1; }
	case "$sb__be" in
		zig)     sb__arch="$(sb_target_field "$sb__tgt" zig_cpu)" ;;
		bootlin) sb__arch="$(sb_target_field "$sb__tgt" bootlin_flags)" ;;
		*) warn "no such backend: $sb__be"; return 1 ;;
	esac
	printf '%s %s\n' "$SB_COMMON_CFLAGS" "$sb__arch" | sed 's/  */ /g; s/ $//'
}

# sb__zig_fetch <cache_dir> -> path to the zig binary, downloading if needed.
sb__zig_fetch() {
	sb__cache="$1"
	sb__host="$(uname -m)"
	sb__sha="$(sb__zig_sha "$sb__host")" \
		|| die "no pinned zig $SB_ZIG_VER checksum for build host $sb__host"
	sb__name="zig-$sb__host-linux-$SB_ZIG_VER"
	sb__dir="$sb__cache/$sb__name"
	if [ ! -x "$sb__dir/zig" ]; then
		log "fetching $sb__name"
		mkdir -p "$sb__cache"
		curl -fsSL -o "$sb__cache/$sb__name.tar.xz" \
			"https://ziglang.org/download/$SB_ZIG_VER/$sb__name.tar.xz" \
			|| die 'zig download failed'
		printf '%s  %s\n' "$sb__sha" "$sb__cache/$sb__name.tar.xz" | sha256sum -c --quiet - \
			|| die 'zig tarball checksum mismatch'
		tar xf "$sb__cache/$sb__name.tar.xz" -C "$sb__cache"
		rm -f "$sb__cache/$sb__name.tar.xz"
	fi
	[ -x "$sb__dir/zig" ] || die "zig not found at $sb__dir/zig after unpacking"
	printf '%s\n' "$sb__dir/zig"
}

# sb__bootlin_fetch <cache_dir> <target> -> toolchain bin/ prefix, downloading
# if needed. Bootlin publishes no checksum file per tarball, so integrity rests
# on HTTPS plus the pinned release version.
sb__bootlin_fetch() {
	sb__cache="$1"; sb__tgt="$2"
	sb__slug="$(sb_target_field "$sb__tgt" bootlin_tc)"
	sb__name="$sb__slug--musl--stable-$SB_TC_VER"
	sb__dir="$sb__cache/$sb__name"
	if [ ! -d "$sb__dir" ]; then
		log "fetching toolchain $sb__name"
		mkdir -p "$sb__cache"
		curl -fsSL -o "$sb__cache/$sb__name.tar.xz" \
			"$SB_BOOTLIN_BASE/$sb__slug/tarballs/$sb__name.tar.xz" \
			|| die 'toolchain download failed'
		tar xf "$sb__cache/$sb__name.tar.xz" -C "$sb__cache"
		rm -f "$sb__cache/$sb__name.tar.xz"
	fi
	sb__gcc="$(ls "$sb__dir/bin/"*-linux*-gcc 2>/dev/null | head -1)"
	[ -n "$sb__gcc" ] || die "no gcc found in $sb__dir/bin"
	printf '%s\n' "${sb__gcc%-gcc}"
}

# sb_tc_setup <target> <backend> <cache_dir>
# Exports the full compiler contract a recipe is handed.
sb_tc_setup() {
	SB_TARGET="$1"; SB_BACKEND="$2"; sb__cache="$3"
	sb_target_exists "$SB_TARGET" || die "no such target: $SB_TARGET"
	CFLAGS="$(sb_tc_flags "$SB_TARGET" "$SB_BACKEND")" || die "cannot build flags for $SB_TARGET/$SB_BACKEND"
	CXXFLAGS="$CFLAGS"
	LDFLAGS="$SB_COMMON_LDFLAGS"

	case "$SB_BACKEND" in
	zig)
		sb__zig="$(sb__zig_fetch "$sb__cache/zig")"
		# musl and compiler-rt are compiled per target on first use; keeping
		# that beside the toolchain lets CI cache the pair as one entry.
		ZIG_GLOBAL_CACHE_DIR="$sb__cache/zig/zig-cache"
		export ZIG_GLOBAL_CACHE_DIR
		sb__zt="$(sb_target_field "$SB_TARGET" zig_target)"
		# Wrappers, not bare variables: the -target must reach every single
		# object, including ones built by a configure script that rewrites
		# CFLAGS. Putting it in CFLAGS alone has silently produced host
		# objects before.
		mkdir -p "$sb__cache/wrap/$SB_TARGET"
		sb__w="$sb__cache/wrap/$SB_TARGET"
		printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "$sb__zig" "$sb__zt" > "$sb__w/cc"
		printf '#!/bin/sh\nexec "%s" c++ -target %s "$@"\n' "$sb__zig" "$sb__zt" > "$sb__w/cxx"
		printf '#!/bin/sh\nexec "%s" ar "$@"\n'     "$sb__zig" > "$sb__w/ar"
		printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$sb__zig" > "$sb__w/ranlib"
		chmod 755 "$sb__w/cc" "$sb__w/cxx" "$sb__w/ar" "$sb__w/ranlib"
		CC="$sb__w/cc"; CXX="$sb__w/cxx"; AR="$sb__w/ar"; RANLIB="$sb__w/ranlib"
		# zig has no `strip`; llvm-strip from the host is arch-agnostic and
		# `zig cc` already emits no debug info under -Os. Fall back to the
		# host strip only for the host target.
		STRIP="$(command -v llvm-strip 2>/dev/null || command -v strip)"
		;;
	bootlin)
		sb__pfx="$(sb__bootlin_fetch "$sb__cache/bootlin" "$SB_TARGET")"
		CC="$sb__pfx-gcc"; CXX="$sb__pfx-g++"
		AR="$sb__pfx-ar"; RANLIB="$sb__pfx-ranlib"; STRIP="$sb__pfx-strip"
		;;
	*) die "no such backend: $SB_BACKEND" ;;
	esac

	export CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS SB_TARGET SB_BACKEND
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh tests/test-toolchain.sh`
Expected: `test-toolchain: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 6: Prove the zig backend really produces a foreign binary**

This one downloads, so it is not part of the default suite. Run it by hand:

```sh
sh -c '
set -eu
. ./targets.sh; . ./lib/log.sh; . ./lib/toolchain.sh
sb_tc_setup mipsel zig /tmp/sb-cache
echo "int main(void){return 0;}" > /tmp/h.c
"$CC" $CFLAGS $LDFLAGS -o /tmp/h /tmp/h.c
readelf -h /tmp/h | grep -E "Class|Data|Machine"
'
```
Expected: `ELF32`, `2's complement, little endian`, `MIPS R3000`

- [ ] **Step 7: Commit**

```bash
git add lib/log.sh lib/toolchain.sh tests/test-toolchain.sh
git commit -m "Turn (target, backend) into a compiler

Recipes are handed CC/CFLAGS/LDFLAGS and never learn which backend produced
them, so moving a package from bootlin to zig is one line in its meta.

The -target reaches the compiler through a wrapper script rather than CFLAGS:
a configure script that rewrites CFLAGS would otherwise silently produce host
objects, which links fine and dies on the device."
```

---

## Task 3: `lib/fetch.sh` — źródło z przypiętą sumą

**Files:**
- Create: `lib/fetch.sh`
- Test: `tests/test-fetch.sh`

**Interfaces:**
- Consumes: `lib/log.sh`
- Produces: `sb_fetch <url> <sha256> <cache_dir> <dest_dir> [patch_dir]` — pobiera (lub bierze z cache), weryfikuje sumę, rozpakowuje do `dest_dir` ze `--strip-components=1`, nakłada `patch_dir/*.patch` leksykalnie. Niezgodna suma → `die`, a plik z cache jest usuwany.

- [ ] **Step 1: Write the failing test**

Create `tests/test-fetch.sh`. Używa `file://`, więc nie dotyka sieci:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/fetch.sh"

TMP="${TMPDIR:-/tmp}/sb-fetch-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/src/inner" "$TMP/cache" "$TMP/patches"
printf 'original\n' > "$TMP/src/inner/hello.txt"
( cd "$TMP/src" && tar czf "$TMP/pkg.tar.gz" inner )
SHA="$(sha256sum "$TMP/pkg.tar.gz" | cut -d' ' -f1)"
URL="file://$TMP/pkg.tar.gz"

sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-good" >/dev/null 2>&1
assert_eq 'strip-components lands content at the top' \
	"$(cat "$TMP/out-good/hello.txt" 2>/dev/null)" 'original'

assert_fails sb_fetch "$URL" '0000000000000000000000000000000000000000000000000000000000000000' \
	"$TMP/cache-bad" "$TMP/out-bad"
assert_eq 'a bad checksum leaves nothing cached' \
	"$(ls "$TMP/cache-bad" 2>/dev/null | wc -l | tr -d ' ')" '0'

cat > "$TMP/patches/0001-change.patch" <<'EOF'
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-original
+patched
EOF
sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-patched" "$TMP/patches" >/dev/null 2>&1
assert_eq 'patches are applied' "$(cat "$TMP/out-patched/hello.txt" 2>/dev/null)" 'patched'

# A patch that does not apply must stop the build, not warn and continue: a
# silently skipped patch produces a binary that is wrong in a way nothing else
# will catch.
printf 'bad patch\n' > "$TMP/patches/0002-broken.patch"
assert_fails sb_fetch "$URL" "$SHA" "$TMP/cache" "$TMP/out-broken" "$TMP/patches"

rm -rf "$TMP"
report test-fetch
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-fetch.sh`
Expected: FAIL — `lib/fetch.sh: No such file or directory`

- [ ] **Step 3: Write `lib/fetch.sh`**

```sh
# lib/fetch.sh -- get a package's source, verified, unpacked and patched.
#
# Sourced, not executed. Requires lib/log.sh.
#
# Every source is pinned by SHA-256. There is no mode that skips the check:
# these binaries are handed to devices that cannot be inspected afterwards, so
# "which bytes did this come from" has to have an answer.

# sb_fetch <url> <sha256> <cache_dir> <dest_dir> [patch_dir]
sb_fetch() {
	sb__url="$1"; sb__sha="$2"; sb__cache="$3"; sb__dest="$4"; sb__patches="${5:-}"

	case "$sb__sha" in
		[0-9a-f][0-9a-f]*) : ;;
		*) die "source checksum is missing or malformed: '$sb__sha'" ;;
	esac
	[ "${#sb__sha}" -eq 64 ] || die "source checksum is not 64 hex digits: '$sb__sha'"

	sb__file="$sb__cache/$(basename "$sb__url")"
	mkdir -p "$sb__cache"
	if [ ! -f "$sb__file" ]; then
		log "fetching $(basename "$sb__url")"
		curl -fsSL -o "$sb__file" "$sb__url" || { rm -f "$sb__file"; die "download failed: $sb__url"; }
	fi

	# On a mismatch the cached file is removed. Leaving it there turns one bad
	# download into a permanently poisoned cache that fails identically on
	# every later run, which is a miserable thing to debug.
	if ! printf '%s  %s\n' "$sb__sha" "$sb__file" | sha256sum -c --quiet - 2>/dev/null; then
		rm -f "$sb__file"
		die "checksum mismatch for $(basename "$sb__url") -- expected $sb__sha"
	fi

	rm -rf "$sb__dest"
	mkdir -p "$sb__dest"
	tar xf "$sb__file" -C "$sb__dest" --strip-components=1 \
		|| die "cannot unpack $(basename "$sb__url")"

	[ -n "$sb__patches" ] || return 0
	[ -d "$sb__patches" ] || return 0
	for sb__p in "$sb__patches"/*.patch; do
		[ -f "$sb__p" ] || continue
		log "applying $(basename "$sb__p")"
		patch -p1 -d "$sb__dest" < "$sb__p" >/dev/null \
			|| die "patch failed to apply: $(basename "$sb__p")"
	done
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test-fetch.sh`
Expected: `test-fetch: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 5: Commit**

```bash
git add lib/fetch.sh tests/test-fetch.sh
git commit -m "Fetch sources against a pinned checksum

There is no mode that skips the check. A mismatch also deletes the cached
file: leaving it turns one bad download into a cache that fails identically
on every later run."
```

---

## Task 4: `lib/verify.sh` — bramka, która łapie SIGILL przed wysyłką

**Files:**
- Create: `lib/verify.sh`
- Test: `tests/test-verify.sh`

**Interfaces:**
- Consumes: `targets.sh`, `lib/log.sh`
- Produces:
  - `sb_verify_static <binary>` — brak `PT_INTERP`
  - `sb_verify_elf <binary> <target>` — `Class`/`Data`/`Machine` zgodne z macierzą
  - `sb_verify_isa <binary> <target>` — bramka zestawu instrukcji wg kolumny `isa_gate`
  - `sb_verify_runs <binary> <target> <args…>` — uruchomienie pod qemu
  - `sb_verify <binary> <target> <smoke_args…>` — wszystkie cztery po kolei

To jest miejsce, w którym repo zarabia na siebie. Uzasadnienie doboru bramek — dlaczego dla ARM decyduje `readelf -A`, a nie qemu — jest w spec §5.1 i musi trafić do komentarza w pliku.

- [ ] **Step 1: Write the failing test**

Create `tests/test-verify.sh`. Zamiast budować cokolwiek, używa binarek, które w tym systemie już istnieją — plus binarki hosta jako przypadku negatywnego:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../targets.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/verify.sh"

# /bin/sh on the build host is dynamically linked. If the static gate cannot
# reject it, the gate does nothing.
assert_fails sb_verify_static /bin/sh

# Fixtures: real statically linked binaries for foreign architectures, built by
# the systems this repo replaces. Skipped when absent so the suite still runs
# on a clean checkout.
FIX_MIPSEL="${SB_FIXTURE_MIPSEL:-/home/q/ssh/out/nmap-mipsel}"
FIX_ARM="${SB_FIXTURE_ARM:-/home/q/ssh/out/nmap-noneon}"

if [ -f "$FIX_MIPSEL" ]; then
	assert_ok sb_verify_static "$FIX_MIPSEL"
	assert_ok sb_verify_elf "$FIX_MIPSEL" mipsel
	assert_fails sb_verify_elf "$FIX_MIPSEL" mips      # wrong endianness
	assert_fails sb_verify_elf "$FIX_MIPSEL" armv7     # wrong machine
	assert_fails sb_verify_elf "$FIX_MIPSEL" aarch64   # wrong class
else
	printf '  skip mipsel fixture (%s absent)\n' "$FIX_MIPSEL"
fi

if [ -f "$FIX_ARM" ]; then
	assert_ok sb_verify_static "$FIX_ARM"
	assert_ok sb_verify_elf "$FIX_ARM" armv7
	# Built without NEON, so it must satisfy the baseline gate and fail the
	# NEON one. This pair is the whole point of the ISA gate.
	assert_ok    sb_verify_isa "$FIX_ARM" armv7
	assert_fails sb_verify_isa "$FIX_ARM" armv7-neon
else
	printf '  skip arm fixture (%s absent)\n' "$FIX_ARM"
fi

report test-verify
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-verify.sh`
Expected: FAIL — `lib/verify.sh: No such file or directory`

- [ ] **Step 3: Write `lib/verify.sh`**

```sh
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
	readelf -l "$1" 2>/dev/null | grep -q 'INTERP' && {
		warn "$1 is dynamically linked (has a PT_INTERP segment)"
		return 1
	}
	readelf -h "$1" >/dev/null 2>&1 || { warn "$1 is not an ELF file"; return 1; }
	return 0
}

# sb_verify_elf <binary> <target> -- class, endianness and machine must match
# the matrix. Catches a build that silently produced host objects.
sb_verify_elf() {
	sb__bin="$1"; sb__tgt="$2"
	sb__hdr="$(readelf -h "$sb__bin" 2>/dev/null)" || { warn "$sb__bin is not an ELF file"; return 1; }

	sb__want_class="$(sb_target_field "$sb__tgt" elf_class)"   || return 1
	sb__want_data="$(sb_target_field "$sb__tgt" elf_data)"     || return 1
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
		# ARM build attributes (readelf -A). Tag_Advanced_SIMD_arch present at
		# all means NEON was enabled for some translation unit.
		readelf -A "$sb__bin" 2>/dev/null | grep -q 'Tag_Advanced_SIMD_arch' && {
			warn "$sb__bin: built with NEON, but $sb__tgt is the no-NEON baseline"; return 1; }
		readelf -A "$sb__bin" 2>/dev/null | grep 'Tag_FP_arch' | grep -qE 'VFPv4|NEON' && {
			warn "$sb__bin: FP arch exceeds VFPv3-D16, which $sb__tgt does not allow"; return 1; }
		return 0 ;;
	arm-neon)
		readelf -A "$sb__bin" 2>/dev/null | grep -q 'Tag_Advanced_SIMD_arch' || {
			warn "$sb__bin: no NEON attribute, but $sb__tgt is the NEON target"; return 1; }
		return 0 ;;
	arm-aes)
		readelf -A "$sb__bin" 2>/dev/null | grep -qE 'Tag_(DSP_extension|Advanced_SIMD_arch)' || {
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
sb_verify_runs() {
	sb__bin="$1"; sb__tgt="$2"; shift 2
	sb__qemu="$(sb_target_field "$sb__tgt" qemu)" || return 1
	sb__qcpu="$(sb_target_field "$sb__tgt" qemu_cpu)" || return 1
	command -v "$sb__qemu" >/dev/null 2>&1 || { warn "$sb__qemu is not installed"; return 1; }
	if [ -n "$sb__qcpu" ]; then
		"$sb__qemu" -cpu "$sb__qcpu" "$sb__bin" "$@" >/dev/null 2>&1
	else
		"$sb__qemu" "$sb__bin" "$@" >/dev/null 2>&1
	fi || { warn "$sb__bin did not run under $sb__qemu"; return 1; }
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test-verify.sh`
Expected: `test-verify: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures** (mniej, jeśli fixture'y nieobecne)

- [ ] **Step 5: Commit**

```bash
git add lib/verify.sh tests/test-verify.sh
git commit -m "Gate every binary on what it actually contains

The ARM check reads build attributes rather than running the binary, because
qemu-arm-static's cortex-a7 model has NEON: a NEON binary mislabelled as the
baseline target passes under qemu and SIGILLs on the first box without it.
On MIPS the reverse holds -- qemu's 4Kc is a real r1 core -- so there the run
gate catches the r2 encoding that traps on a BCM7356."
```

---

## Task 5: `lib/pack.sh` — tarball, który mówi, skąd pochodzi

**Files:**
- Create: `lib/pack.sh`
- Test: `tests/test-pack.sh`

**Interfaces:**
- Consumes: `lib/log.sh`
- Produces: `sb_pack <stage_dir> <out_dir> <pkg> <version> <revision> <target> <variant>` → tworzy `<out_dir>/<pkg>-<version>-<target>[-<variant>].tar.gz` i `.sha256`, po uprzednim wpisaniu `MANIFEST` do `stage_dir`. Wypisuje ścieżkę tarballa na stdout.

- [ ] **Step 1: Write the failing test**

Create `tests/test-pack.sh`:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../lib/log.sh"
. "$HERE/../lib/pack.sh"

TMP="${TMPDIR:-/tmp}/sb-pack-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/stage/bin" "$TMP/out"
printf 'fake\n' > "$TMP/stage/bin/dsvpn"
export CFLAGS='-Os -mcpu=mips32' LDFLAGS='-static' SB_BACKEND='zig' SB_SOURCE_SHA='abc123'

TB="$(sb_pack "$TMP/stage" "$TMP/out" dsvpn 0.1.4 1 mipsel '')"
assert_eq 'tarball is named from pkg, version and target' \
	"$(basename "$TB")" 'dsvpn-0.1.4-mipsel.tar.gz'
assert_eq 'a checksum file sits beside it' \
	"$(test -f "$TB.sha256" && echo yes)" 'yes'
assert_eq 'the checksum matches the tarball' \
	"$(cd "$TMP/out" && sha256sum -c --quiet "$(basename "$TB").sha256" >/dev/null 2>&1 && echo ok)" 'ok'

MAN="$(tar xzf "$TB" -O './MANIFEST' 2>/dev/null || tar xzf "$TB" -O 'MANIFEST')"
assert_contains 'manifest records the target'   "$MAN" 'target: mipsel'
assert_contains 'manifest records the backend'  "$MAN" 'toolchain: zig'
assert_contains 'manifest records the cflags'   "$MAN" '-mcpu=mips32'
assert_contains 'manifest records source sha'   "$MAN" 'abc123'

TBV="$(sb_pack "$TMP/stage" "$TMP/out" nmap 7.95 1 mipsel full)"
assert_eq 'a variant becomes a name suffix' \
	"$(basename "$TBV")" 'nmap-7.95-mipsel-full.tar.gz'

rm -rf "$TMP"
report test-pack
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-pack.sh`
Expected: FAIL — `lib/pack.sh: No such file or directory`

- [ ] **Step 3: Write `lib/pack.sh`**

```sh
# lib/pack.sh -- package a built staging directory for release.
#
# Sourced, not executed. Requires lib/log.sh.
#
# Every tarball carries a MANIFEST. The reason is concrete: the directories
# this repo replaces are full of binaries named things like `nmap-noneon` that
# carry no record of which compiler, which flags or which source produced
# them. A binary found on a box a year from now has to be reproducible, and
# that means the answer travels with the binary rather than living in a build
# log that was thrown away.

# sb_pack <stage_dir> <out_dir> <pkg> <version> <revision> <target> <variant>
sb_pack() {
	sb__stage="$1"; sb__out="$2"; sb__pkg="$3"; sb__ver="$4"
	sb__rev="$5"; sb__tgt="$6"; sb__var="$7"

	[ -d "$sb__stage" ] || die "nothing staged at $sb__stage"

	sb__name="$sb__pkg-$sb__ver-$sb__tgt"
	[ -n "$sb__var" ] && sb__name="$sb__name-$sb__var"

	{
		printf 'package: %s\n'    "$sb__pkg"
		printf 'version: %s\n'    "$sb__ver"
		printf 'revision: %s\n'   "$sb__rev"
		printf 'target: %s\n'     "$sb__tgt"
		printf 'variant: %s\n'    "${sb__var:--}"
		printf 'toolchain: %s\n'  "${SB_BACKEND:-unknown}"
		printf 'cflags: %s\n'     "${CFLAGS:-}"
		printf 'ldflags: %s\n'    "${LDFLAGS:-}"
		printf 'source_sha256: %s\n' "${SB_SOURCE_SHA:-unknown}"
		printf 'built: %s\n'      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'staticbox_commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
	} > "$sb__stage/MANIFEST"

	mkdir -p "$sb__out"
	sb__tarball="$sb__out/$sb__name.tar.gz"
	rm -f "$sb__tarball"
	# Packed from inside the staging directory so the archive has no leading
	# path component of its own; get.sh unpacks into a directory it chose.
	tar czf "$sb__tarball" -C "$sb__stage" . || die "cannot create $sb__tarball"
	( cd "$sb__out" && sha256sum "$sb__name.tar.gz" > "$sb__name.tar.gz.sha256" )

	printf '%s\n' "$sb__tarball"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test-pack.sh`
Expected: `test-pack: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 5: Commit**

```bash
git add lib/pack.sh tests/test-pack.sh
git commit -m "Package builds with a manifest that travels with them

The directories this replaces are full of binaries named nmap-noneon with no
record of the compiler, flags or source behind them. A binary found on a box
a year from now should still be reproducible."
```

---

## Task 6: `build` — driver

**Files:**
- Create: `build`
- Test: `tests/test-build-driver.sh`

**Interfaces:**
- Consumes: całe `lib/`, `targets.sh`
- Produces: CLI `./build <pkg> [target…] [--variant V] [--all-targets] [--list]`. Bez targetów buduje wszystkie włączone, które pakiet obsługuje. Przepis dostaje `TARGET VARIANT SRC WORK OUT` plus kontrakt kompilatora.

- [ ] **Step 1: Write the failing test**

Create `tests/test-build-driver.sh`. Testuje samą logikę doboru targetów i walidację, przez pakiet-atrapę — bez kompilowania czegokolwiek:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

TMP="${TMPDIR:-/tmp}/sb-driver-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP/packages/fake"
cat > "$TMP/packages/fake/meta" <<'EOF'
PKG=fake
VERSION=1.0
REVISION=1
SOURCE=file:///dev/null
SHA256=0000000000000000000000000000000000000000000000000000000000000000
TARGETS='mipsel armv7'
SMOKE='--version'
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/packages/fake/build.sh"
chmod +x "$TMP/packages/fake/build.sh"

OUT="$(SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake --list 2>&1)"
assert_contains 'lists the targets the package declares' "$OUT" 'mipsel'
assert_contains 'lists both of them'                     "$OUT" 'armv7'
assert_eq 'lists exactly two' "$(printf '%s\n' "$OUT" | grep -c '^  ')" '2'

assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" nosuchpkg --list
assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake nosucharch
# aarch64 is a real target but not one this package declares.
assert_fails env SB_PACKAGES_DIR="$TMP/packages" sh "$ROOT/build" fake aarch64

rm -rf "$TMP"
report test-build-driver
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-build-driver.sh`
Expected: FAIL — `build: No such file or directory`

- [ ] **Step 3: Write `build`**

```sh
#!/bin/sh
# build -- compile one package for one or more targets.
#
#   ./build <package> [target...] [--variant V] [--list]
#
# With no target, builds every enabled target the package declares. The
# package's own build.sh is handed a ready compiler and a verified, unpacked
# source tree, and is responsible for nothing but producing files in $OUT.
#
# Environment:
#   SB_PACKAGES_DIR  where packages live      (default: ./packages)
#   SB_CACHE_DIR     toolchains and sources   (default: ./.cache)
#   SB_OUT_DIR       where tarballs land      (default: ./out)
#   SB_WORK_DIR      scratch                  (default: ./.build)

set -eu

SB_PROG='build'
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

. "$HERE/targets.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/toolchain.sh"
. "$HERE/lib/fetch.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/pack.sh"

PACKAGES_DIR="${SB_PACKAGES_DIR:-$HERE/packages}"
CACHE_DIR="${SB_CACHE_DIR:-$HERE/.cache}"
OUT_DIR="${SB_OUT_DIR:-$HERE/out}"
WORK_DIR="${SB_WORK_DIR:-$HERE/.build}"

usage() {
	printf 'usage: build <package> [target...] [--variant V] [--list]\n' >&2
	exit 2
}

[ $# -ge 1 ] || usage
PKG_NAME="$1"; shift

WANT_VARIANT=''
LIST_ONLY=0
REQUESTED=''
while [ $# -gt 0 ]; do
	case "$1" in
		--variant) shift; [ $# -gt 0 ] || usage; WANT_VARIANT="$1" ;;
		--list)    LIST_ONLY=1 ;;
		-*)        usage ;;
		*)         REQUESTED="$REQUESTED $1" ;;
	esac
	shift
done

PKG_DIR="$PACKAGES_DIR/$PKG_NAME"
[ -f "$PKG_DIR/meta" ]     || die "no such package: $PKG_NAME"
[ -x "$PKG_DIR/build.sh" ] || die "$PKG_NAME has no executable build.sh"

# Defaults a meta may leave unset, cleared first so a previous package in the
# same shell cannot leak into this one.
TOOLCHAIN='zig'; TARGETS='all'; VARIANTS=''; SMOKE=''; SMOKE_EXPECT=''; REVISION='1'
# shellcheck disable=SC1090
. "$PKG_DIR/meta"

for v in PKG VERSION SOURCE SHA256; do
	eval "val=\${$v:-}"
	[ -n "$val" ] || die "$PKG_NAME/meta is missing $v"
done

# Which targets this package can be built for: its own list, intersected with
# the matrix's enabled set. A package naming a disabled target is not an error
# -- the target is simply skipped -- but naming a target that does not exist is.
pkg_targets() {
	if [ "$TARGETS" = 'all' ]; then
		sb_targets_enabled
	else
		for t in $TARGETS; do
			sb_target_exists "$t" || die "$PKG_NAME/meta names an unknown target: $t"
			[ "$(sb_target_field "$t" enabled)" = '1' ] && printf '%s\n' "$t"
		done
	fi
}

AVAILABLE="$(pkg_targets)"

if [ "$LIST_ONLY" = '1' ]; then
	printf '%s %s-%s (toolchain: %s)\n' "$PKG" "$VERSION" "$REVISION" "$TOOLCHAIN"
	for t in $AVAILABLE; do printf '  %s\n' "$t"; done
	exit 0
fi

if [ -n "$REQUESTED" ]; then
	BUILD_TARGETS=''
	for t in $REQUESTED; do
		sb_target_exists "$t" || die "no such target: $t"
		printf '%s\n' "$AVAILABLE" | grep -qx "$t" \
			|| die "$PKG_NAME does not build for $t"
		BUILD_TARGETS="$BUILD_TARGETS $t"
	done
else
	BUILD_TARGETS="$AVAILABLE"
fi

# A package with variants and none requested builds every variant; one without
# variants builds a single unnamed build.
if [ -n "$WANT_VARIANT" ]; then
	BUILD_VARIANTS="$WANT_VARIANT"
elif [ -n "$VARIANTS" ]; then
	BUILD_VARIANTS="$VARIANTS"
else
	BUILD_VARIANTS="''"
fi

SB_SOURCE_SHA="$SHA256"
export SB_SOURCE_SHA

for TARGET in $BUILD_TARGETS; do
	for VARIANT in $BUILD_VARIANTS; do
		[ "$VARIANT" = "''" ] && VARIANT=''

		# A variant may be restricted to a subset of targets, declared in meta
		# as VARIANT_TARGETS_<variant>. nmap's `full` uses this: it pulls in
		# OpenSSL and libssh2 and is only worth building where it is used.
		if [ -n "$VARIANT" ]; then
			eval "vt=\${VARIANT_TARGETS_$VARIANT:-}"
			if [ -n "$vt" ] && ! printf '%s\n' $vt | grep -qx "$TARGET"; then
				log "skipping $TARGET/$VARIANT (not in VARIANT_TARGETS_$VARIANT)"
				continue
			fi
		fi

		label="$TARGET${VARIANT:+/$VARIANT}"
		log "building $PKG $VERSION for $label"

		sb_tc_setup "$TARGET" "$TOOLCHAIN" "$CACHE_DIR"

		SRC="$WORK_DIR/$PKG/$label/src"
		WORK="$WORK_DIR/$PKG/$label"
		OUT="$WORK/stage"
		rm -rf "$OUT"; mkdir -p "$OUT"
		export TARGET VARIANT SRC WORK OUT

		sb_fetch "$SOURCE" "$SHA256" "$CACHE_DIR/src" "$SRC" "$PKG_DIR/patches"

		"$PKG_DIR/build.sh" || die "$PKG_NAME build.sh failed for $label"

		# Every executable the recipe produced goes through the gate. A recipe
		# that shipped a stray host binary is caught here rather than on a box.
		found=0
		for bin in "$OUT"/* "$OUT"/bin/*; do
			[ -f "$bin" ] && [ -x "$bin" ] || continue
			found=1
			sb_verify "$bin" "$TARGET" $SMOKE || die "verification failed for $bin"
		done
		[ "$found" = '1' ] || die "$PKG_NAME build.sh produced no executable in $OUT"

		tarball="$(sb_pack "$OUT" "$OUT_DIR" "$PKG" "$VERSION" "$REVISION" "$TARGET" "$VARIANT")"
		log "done: $tarball ($(du -h "$tarball" | cut -f1))"
	done
done
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x build && sh tests/test-build-driver.sh`
Expected: `test-build-driver: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 5: Commit**

```bash
chmod +x build
git add build tests/test-build-driver.sh
git commit -m "Add the build driver

Everything except compilation happens here: resolving targets, fetching and
verifying the source, setting up the compiler, gating the result and
packaging it. The recipe's only job is to put files in \$OUT."
```

---

## Task 7: `packages/dsvpn` — pakiet pilotażowy

**Files:**
- Create: `packages/dsvpn/meta`
- Create: `packages/dsvpn/build.sh`
- Create: `packages/dsvpn/patches/0001-no-system-changes.patch`

**Interfaces:**
- Consumes: kontrakt z Tasku 6 (`TARGET VARIANT SRC WORK OUT CC CFLAGS LDFLAGS STRIP`)
- Produces: `out/dsvpn-<version>-<target>.tar.gz` dla ośmiu włączonych targetów

**Dwie rzeczy różnią ten pakiet od dotychczasowego `vpn-client/build.sh`:**

1. Tamten ciągnie tarball gałęzi `master`, **bez przypiętej sumy**. Nowy kontrakt tego zabrania — źródło musi być przypięte do tagu z sumą.
2. Tamten buduje `armv7` jako `-mcpu=cortex-a7 -mfpu=neon-vfpv4`, czyli **z NEON-em pod nazwą, która teraz znaczy baseline**. Po tej zmianie ten sam box dostanie `armv7-neon`, a `armv7` będzie naprawdę bez NEON-u. To nie jest regresja — to naprawa, którą bramka ISA z Tasku 4 właśnie wymusza.

- [ ] **Step 1: Pin the source and record its checksum**

DSVPN wydania: https://github.com/jedisct1/dsvpn/tags. Wybierz najnowszy tag i zdobądź sumę:

```sh
DSVPN_TAG=0.1.4   # sprawdź na liście tagów, czy jest nowszy
curl -fsSL -o /tmp/dsvpn.tar.gz \
  "https://github.com/jedisct1/dsvpn/archive/refs/tags/$DSVPN_TAG.tar.gz"
sha256sum /tmp/dsvpn.tar.gz
```

Wynik wstaw jako `SHA256` w kroku 2. Tarballe tagów z GitHuba są stabilne bajt w bajt — tarballe gałęzi nie są, i dlatego nie wolno użyć `master`.

- [ ] **Step 2: Write `packages/dsvpn/meta`**

```sh
# DSVPN: ~1500 lines of C with its own Xoodoo-based crypto and no external
# dependencies, so it cross-compiles static into ~100-150 kB. That size is why
# it is here: it is small enough to hand to a device that has nothing, which is
# the situation on plenty of routers with no openvpn binary.
#
# Pinned to a tag, not a branch: GitHub's branch tarballs are regenerated and
# are not byte-stable, so they cannot carry a meaningful checksum.
PKG=dsvpn
VERSION=0.1.4
REVISION=1
SOURCE=https://github.com/jedisct1/dsvpn/archive/refs/tags/0.1.4.tar.gz
SHA256=<wstaw sumę z kroku 1>
TOOLCHAIN=zig
TARGETS=all
SMOKE=''
```

`SMOKE` jest pusty: uruchomiony bez argumentów dsvpn wypisuje sposób użycia i **kończy się kodem 1**, więc `--version` nie istnieje, a samo uruchomienie nie jest testem wyjścia zerowego. Bramka dla tego pakietu to `sb_verify_static`, `sb_verify_elf` i `sb_verify_isa`; brak `SMOKE` sprawia, że `sb_verify_runs` wywoła binarkę bez argumentów, więc krok 5 pokazuje, jak to obsłużyć.

- [ ] **Step 3: Copy the patch**

```bash
mkdir -p packages/dsvpn/patches
cp /home/q/sshd-tunnel/vpn-client/patches/no-system-changes.patch \
   packages/dsvpn/patches/0001-no-system-changes.patch
```

Patch usuwa przebudowę całej konfiguracji systemu, którą upstream robi przy połączeniu (sysctl, iptables, przejęcie trasy domyślnej). Powód jest praktyczny: połowy tych poleceń nie ma na tych urządzeniach, a jedno nieudane przerywa `dsvpn` w całości.

- [ ] **Step 4: Write `packages/dsvpn/build.sh`**

```sh
#!/bin/sh
# DSVPN recipe. Compiles only: the driver has already fetched, verified,
# unpacked and patched the source, and set up the compiler.
#
# Given: TARGET VARIANT SRC WORK OUT CC CFLAGS LDFLAGS STRIP
set -eu

# Upstream's Makefile probes for -march=native/-mtune=native when CFLAGS is
# empty, which is meaningless and wrong under cross-compilation. Passing CFLAGS
# explicitly is what stops it.
#
# NO_DEFAULT_ROUTES is upstream's own switch for "do not touch the routing
# table". The patch already removed those commands; the define additionally
# drops the re-detection of the gateway on every reconnect, which would shell
# out to `ip route show default` for a value nothing reads any more.
#
# The Makefile ends in a bare `strip`, which on a cross build runs the host's
# and refuses a foreign binary. A shim directory puts the right one first on
# PATH under that name.
mkdir -p "$WORK/shim"
ln -sf "$STRIP" "$WORK/shim/strip"

( cd "$SRC" && PATH="$WORK/shim:$PATH" make \
	CC="$CC" \
	CFLAGS="$CFLAGS -Wall -DNO_DEFAULT_ROUTES" \
	LDFLAGS="$LDFLAGS" \
	>"$WORK/make.log" 2>&1 ) \
	|| { tail -20 "$WORK/make.log" >&2; exit 1; }

[ -f "$SRC/dsvpn" ] || { printf 'dsvpn binary was not produced\n' >&2; exit 1; }

mkdir -p "$OUT/bin"
cp "$SRC/dsvpn" "$OUT/bin/dsvpn"
chmod 755 "$OUT/bin/dsvpn"
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$OUT/DSVPN-README.md"
[ -f "$SRC/LICENSE" ]   && cp "$SRC/LICENSE"   "$OUT/DSVPN-LICENSE"
exit 0
```

- [ ] **Step 5: Teach the driver that a usage-exit is not a failure**

`dsvpn` bez argumentów wypisuje sposób użycia i kończy się kodem 1, więc `sb_verify_runs` uznałoby to za błąd. Rozwiązaniem jest deklaracja w `meta` — dodaj do `packages/dsvpn/meta`:

```sh
# dsvpn prints usage and exits 1 when run with no arguments, so a zero exit is
# the wrong thing to demand. What matters is that it got far enough to print.
SMOKE_EXPECT='Usage'
```

i w `lib/verify.sh` rozszerz `sb_verify_runs` o sprawdzanie wyjścia, zamiast wyłącznie kodu powrotu:

```sh
# Replace the body of sb_verify_runs' invocation block with:
	if [ -n "$sb__qcpu" ]; then
		sb__outp="$("$sb__qemu" -cpu "$sb__qcpu" "$sb__bin" "$@" 2>&1 || true)"
	else
		sb__outp="$("$sb__qemu" "$sb__bin" "$@" 2>&1 || true)"
	fi
	# A binary that never reached its own code prints nothing recognisable:
	# qemu reports the signal instead. Matching on expected output catches
	# SIGILL and a failed exec alike, and works for tools whose only
	# argument-free behaviour is to print usage and exit non-zero.
	case "$sb__outp" in
		*"Illegal instruction"*|*"could not open"*|*"Invalid ELF"*)
			warn "$sb__bin failed under $sb__qemu: $sb__outp"; return 1 ;;
	esac
	if [ -n "${SMOKE_EXPECT:-}" ]; then
		case "$sb__outp" in
			*"$SMOKE_EXPECT"*) : ;;
			*) warn "$sb__bin ran but did not print '$SMOKE_EXPECT'"; return 1 ;;
		esac
	fi
	return 0
```

Dopisz do `tests/test-verify.sh`, przed `report`:

```sh
FIX_ARM_SMOKE="${SB_FIXTURE_ARM:-/home/q/ssh/out/nmap-noneon}"
if [ -f "$FIX_ARM_SMOKE" ] && command -v qemu-arm-static >/dev/null 2>&1; then
	SMOKE_EXPECT='Nmap'
	assert_ok sb_verify_runs "$FIX_ARM_SMOKE" armv7 --version
	SMOKE_EXPECT='ThisStringWillNeverAppear'
	assert_fails sb_verify_runs "$FIX_ARM_SMOKE" armv7 --version
	unset SMOKE_EXPECT
fi
```

- [ ] **Step 6: Build it for one target and check the gate holds**

```bash
sudo apt-get install -y qemu-user-static
./build dsvpn mipsel
ls -l out/
```
Expected: `out/dsvpn-0.1.4-mipsel.tar.gz` plus `.sha256`, and a `verified dsvpn for mipsel` line.

- [ ] **Step 7: Prove the ISA gate is not decorative**

Zbuduj celowo źle — `armv7` z flagami NEON-owymi — i sprawdź, że bramka odrzuca:

```bash
SB_TEST_BAD=1 sh -c '
. ./targets.sh; . ./lib/log.sh; . ./lib/toolchain.sh; . ./lib/verify.sh
sb_tc_setup armv7-neon zig .cache
echo "int main(void){return 0;}" > /tmp/n.c
"$CC" $CFLAGS $LDFLAGS -o /tmp/n /tmp/n.c
sb_verify_isa /tmp/n armv7 && echo "GATE IS BROKEN" || echo "gate rejected it, correctly"
'
```
Expected: `gate rejected it, correctly`

Jeśli wypisze `GATE IS BROKEN`, oznacza to, że `zig cc` nie emituje atrybutów budowy ARM w formie, na którą liczy bramka. Wtedy **zatrzymaj się i zgłoś to** — bramka ISA jest powodem istnienia tej warstwy i cicha zamiana jej na `qemu -cpu` nie jest równoważna (spec §5.1).

- [ ] **Step 8: Build every target**

```bash
./build dsvpn
ls -l out/
```
Expected: osiem tarballi plus osiem plików `.sha256`.

- [ ] **Step 9: Commit**

```bash
git add packages/dsvpn lib/verify.sh tests/test-verify.sh
git commit -m "Add dsvpn, the pilot package

Two things change against the build this replaces. The source is pinned to a
tag with a checksum instead of a branch tarball, which is not byte-stable and
cannot carry one. And armv7 now means what it says: the old build compiled it
with -mfpu=neon-vfpv4 under that name, so boxes with an A7 and no NEON were
being handed a binary that could SIGILL. Those boxes now get armv7-neon or
the real baseline, decided by detection rather than by a name."
```

---

## Task 8: `detect.sh` — jeden detektor zamiast dwóch

**Files:**
- Create: `detect.sh`
- Test: `tests/test-detect.sh`

**Interfaces:**
- Consumes: nic (świadomie samodzielny — musi działać na urządzeniu, gdzie nie ma repo)
- Produces: `./detect.sh [--probe <elf>] [--cpuinfo <file>]` → nazwa targetu na stdout, exit 0; nieznana architektura → exit 2. Flagi `--probe`/`--cpuinfo` istnieją po to, żeby dało się to testować bez ośmiu fizycznych boxów.

Scala `sshd-tunnel/client/install.sh` i `zig-player/scripts/pick-binary.sh`. Każdy zna trik, którego nie zna drugi — zestawienie w spec §7.

- [ ] **Step 1: Write the failing test**

Create `tests/test-detect.sh`. Fixture'ami są prawdziwe binarki obcych architektur — czyta z nich nagłówki dokładnie tak, jak `detect.sh` czytałby `/bin/sh` na boxie:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
DETECT="$HERE/../detect.sh"

TMP="${TMPDIR:-/tmp}/sb-detect-test.$$"
rm -rf "$TMP"; mkdir -p "$TMP"

# uname -m reports plain "mips" on little-endian boxes too, which is exactly
# the lie this detector exists to see through: the answer comes from the ELF
# header of a binary that is certainly native, not from uname.
mk_cpuinfo() { printf 'Features\t: %s\n' "$1" > "$TMP/cpuinfo"; }

FIX_MIPSEL="${SB_FIXTURE_MIPSEL:-/home/q/ssh/out/nmap-mipsel}"
FIX_ARM="${SB_FIXTURE_ARM:-/home/q/ssh/out/nmap-noneon}"

if [ -f "$FIX_MIPSEL" ]; then
	mk_cpuinfo ''
	assert_eq 'little-endian MIPS is mipsel despite uname' \
		"$(SB_FAKE_UNAME=mips sh "$DETECT" --probe "$FIX_MIPSEL" --cpuinfo "$TMP/cpuinfo")" 'mipsel'
fi

if [ -f "$FIX_ARM" ]; then
	mk_cpuinfo 'half thumb fastmult vfp edsp'
	assert_eq 'ARM without NEON falls to the baseline' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7'
	mk_cpuinfo 'half thumb fastmult vfp edsp neon vfpv3'
	assert_eq 'NEON promotes to armv7-neon' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7-neon'
	# armv7-aes is disabled in the matrix, so a box with AES must still be
	# given a target that actually has builds.
	mk_cpuinfo 'half thumb neon vfpv4 aes pmull'
	assert_eq 'AES does not select a disabled target' \
		"$(SB_FAKE_UNAME=armv7l sh "$DETECT" --probe "$FIX_ARM" --cpuinfo "$TMP/cpuinfo")" 'armv7-neon'
fi

mk_cpuinfo ''
assert_eq 'x86_64 host' "$(SB_FAKE_UNAME=x86_64 sh "$DETECT" --probe /bin/sh --cpuinfo "$TMP/cpuinfo")" 'x86_64'
assert_fails env SB_FAKE_UNAME=vax sh "$DETECT" --probe /bin/sh --cpuinfo "$TMP/cpuinfo"

rm -rf "$TMP"
report test-detect
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-detect.sh`
Expected: FAIL — `detect.sh: No such file or directory`

- [ ] **Step 3: Write `detect.sh`**

```sh
#!/bin/sh
# detect.sh -- print the staticbox target name that suits THIS device.
#
#   ./detect.sh                 -> e.g. armv7-neon
#   ./detect.sh --probe <elf>   -> read the ELF header from this file instead
#   ./detect.sh --cpuinfo <f>   -> read CPU features from this file instead
#
# The two override flags exist so this can be tested against binaries from
# eight architectures without owning eight boxes.
#
# Target environment: busybox ash on a device from around 2014, and
# deliberately poorer. Only sh, cat, grep, od and uname are assumed. No python,
# no mktemp, no id, no find -maxdepth. Every one of those is missing on at
# least one device this has to work on.
#
# This replaces two detectors that were written independently and each knew
# something the other did not.
set -u

PROBE=''
CPUINFO='/proc/cpuinfo'
FALLBACK=''
while [ $# -gt 0 ]; do
	case "$1" in
		--probe)    shift; PROBE="${1:-}" ;;
		--cpuinfo)  shift; CPUINFO="${1:-}" ;;
		--fallback) FALLBACK=1 ;;
		*) printf 'detect.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
	shift
done

# `command -v` is POSIX, but at least one router in the wild (ASUSWRT-Merlin's
# busybox ash) does not have it and reports "command: not found".
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

arch="${SB_FAKE_UNAME:-$(uname -m 2>/dev/null || echo unknown)}"

# Pick a binary that is certainly native to this device and read its ELF
# header. uname -m cannot tell big- from little-endian MIPS: every MIPS device
# tested reports plain "mips" either way.
probe_file() {
	[ -n "$PROBE" ] && { printf '%s\n' "$PROBE"; return; }
	for p in /bin/sh /bin/busybox /bin/cat /bin/true; do
		[ -r "$p" ] && { printf '%s\n' "$p"; return; }
	done
	printf '\n'
}

# byte 4 = EI_CLASS (1 = 32-bit, 2 = 64-bit), byte 5 = EI_DATA (1 = LE, 2 = BE)
elf_byte() {
	have od || return 1
	od -An -tu1 -j"$1" -N1 "$2" 2>/dev/null | tr -d ' \n'
}

PF="$(probe_file)"
elf_class=''
elf_data=''
if [ -n "$PF" ] && [ -r "$PF" ]; then
	elf_class="$(elf_byte 4 "$PF")"
	elf_data="$(elf_byte 5 "$PF")"
fi

# ARM feature flags live in /proc/cpuinfo "Features:". An aarch64 kernel running
# a 32-bit userland still lists them there, which is why the userland's ELF
# class decides the architecture and cpuinfo only decides the variant.
has_feature() {
	grep -qiE "^(Features|flags)[[:space:]]*:.*[[:space:]]$1([[:space:]]|\$)" "$CPUINFO" 2>/dev/null
}

# armv7-aes is present in the matrix but disabled, so no package has builds for
# it. Selecting it would hand the device a URL that 404s. Until it is enabled,
# a box with crypto extensions gets the NEON build, which is correct, just not
# the fastest possible.
arm_variant() {
	if has_feature neon; then printf 'armv7-neon\n'
	else printf 'armv7\n'; fi
}

case "$arch" in
	aarch64 | arm64)
		# A 64-bit kernel may run a 32-bit userland. Trust the userland: it is
		# what has to load our binary.
		if [ "$elf_class" = '2' ]; then printf 'aarch64\n'
		else arm_variant; fi
		;;
	armv7l | armv7 | armv8l | armv6l | arm)
		case "$arch" in
			armv6l) printf 'armv5\n' ;;
			*) arm_variant ;;
		esac
		;;
	armv5* | armv4*)
		printf 'armv5\n'
		;;
	mips | mipsel | mips64 | mips64el)
		if [ "$elf_data" = '2' ]; then printf 'mips\n'
		else printf 'mipsel\n'; fi
		;;
	x86_64 | amd64)
		# A 64-bit kernel with a 32-bit userland happens on small x86 boxes too.
		if [ "$elf_class" = '1' ]; then printf 'i686\n'
		else printf 'x86_64\n'; fi
		;;
	i386 | i486 | i586 | i686)
		printf 'i686\n'
		;;
	*)
		printf 'detect.sh: unsupported architecture: %s\n' "$arch" >&2
		exit 2
		;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x detect.sh && sh tests/test-detect.sh`
Expected: `test-detect: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 5: Check it against the real thing**

```bash
./detect.sh
```
Expected: `x86_64` na maszynie deweloperskiej.

- [ ] **Step 6: Commit**

```bash
chmod +x detect.sh
git add detect.sh tests/test-detect.sh
git commit -m "Merge two architecture detectors into one

sshd-tunnel's installer and zigplayer's picker were written independently and
each knew something the other did not: one read EI_DATA from /bin/sh because
uname lies on MIPS, the other distinguished NEON from crypto extensions, and
only one had a fallback for the busybox ash that lacks command -v. This keeps
all of it.

The --probe and --cpuinfo overrides exist so the thing can be tested against
eight architectures without owning eight boxes."
```

---

## Task 9: CI z dynamiczną macierzą

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `.github/workflows/test.yml`
- Create: `ci/matrix.sh`
- Test: `tests/test-ci-matrix.sh`

**Interfaces:**
- Consumes: `targets.sh`, `packages/*/meta`
- Produces: `ci/matrix.sh [pkg…]` → jednolinijkowy JSON `{"include":[{"package":…,"target":…,"variant":…}, …]}`

- [ ] **Step 1: Write the failing test**

Create `tests/test-ci-matrix.sh`:

```sh
#!/bin/sh
set -u
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

J="$(sh "$ROOT/ci/matrix.sh" dsvpn)"
assert_contains 'matrix is an include list' "$J" '"include"'
assert_contains 'names the package'         "$J" '"package":"dsvpn"'
assert_contains 'covers mipsel'             "$J" '"target":"mipsel"'
assert_contains 'covers the arm baseline'   "$J" '"target":"armv7"'
assert_contains 'covers the neon target'    "$J" '"target":"armv7-neon"'

# armv7-aes is disabled: it must never reach CI, or every run pays for a
# ninth of the matrix that ships to nobody.
case "$J" in
	*armv7-aes*) fail 'disabled target leaked into the matrix' ;;
	*) pass 'disabled target stays out of the matrix' ;;
esac

# It has to be one line: GitHub Actions reads it through $GITHUB_OUTPUT, which
# is line-based, and a pretty-printed JSON silently truncates there.
assert_eq 'matrix is a single line' "$(printf '%s' "$J" | wc -l | tr -d ' ')" '0'

report test-ci-matrix
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/test-ci-matrix.sh`
Expected: FAIL — `ci/matrix.sh: No such file or directory`

- [ ] **Step 3: Write `ci/matrix.sh`**

```sh
#!/bin/sh
# ci/matrix.sh -- emit the GitHub Actions build matrix as one line of JSON.
#
#   ci/matrix.sh [package...]     with none, every package
#
# A static workflow file per package was the alternative and was rejected: at
# nine targets and a growing package list it is N YAML files to keep in sync by
# hand every time the matrix changes, which is precisely the class of drift
# this repo exists to end.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$HERE/targets.sh"

PACKAGES="${*:-}"
if [ -z "$PACKAGES" ]; then
	for d in "$HERE"/packages/*/; do
		[ -f "$d/meta" ] && PACKAGES="$PACKAGES $(basename "$d")"
	done
fi

first=1
printf '{"include":['
for pkg in $PACKAGES; do
	[ -f "$HERE/packages/$pkg/meta" ] || continue
	TOOLCHAIN='zig'; TARGETS='all'; VARIANTS=''; VARIANT_TARGETS_full=''
	# shellcheck disable=SC1090
	. "$HERE/packages/$pkg/meta"

	if [ "$TARGETS" = 'all' ]; then
		tlist="$(sb_targets_enabled)"
	else
		tlist=''
		for t in $TARGETS; do
			[ "$(sb_target_field "$t" enabled 2>/dev/null)" = '1' ] && tlist="$tlist $t"
		done
	fi

	vlist="${VARIANTS:-_}"
	for t in $tlist; do
		for v in $vlist; do
			[ "$v" = '_' ] && v=''
			if [ -n "$v" ]; then
				eval "vt=\${VARIANT_TARGETS_$v:-}"
				if [ -n "$vt" ] && ! printf '%s\n' $vt | grep -qx "$t"; then continue; fi
			fi
			[ "$first" = '1' ] || printf ','
			first=0
			printf '{"package":"%s","target":"%s","variant":"%s"}' "$pkg" "$t" "$v"
		done
	done
done
printf ']}'
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x ci/matrix.sh && sh tests/test-ci-matrix.sh`
Expected: `test-ci-matrix: N checks, 0 failures` — liczba kontroli zależy od obecnych fixtureów; znaczenie ma **0 failures**

- [ ] **Step 5: Write `.github/workflows/test.yml`**

```yaml
name: test

# The shell test suite touches no network and builds nothing, so it runs on
# every push and pull request. The build matrix below is the expensive one.
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  suite:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install qemu-user-static
        run: sudo apt-get update -qq && sudo apt-get install -y -qq qemu-user-static >/dev/null
      - name: Run the suite
        run: sh tests/run-all.sh
      - name: Lint every shell script
        run: |
          sudo apt-get install -y -qq shellcheck >/dev/null
          shellcheck -s sh build detect.sh ci/matrix.sh lib/*.sh targets.sh \
            packages/*/build.sh tests/*.sh
```

- [ ] **Step 6: Write `.github/workflows/build.yml`**

```yaml
name: build

# One workflow for every package. The matrix is computed at run time from
# targets.sh and packages/*/meta, so adding a target or a package needs no edit
# here.
on:
  push:
    branches: [main]
    paths: ['packages/**', 'lib/**', 'targets.sh', 'build', '.github/workflows/build.yml']
    tags: ['*-v*']
  pull_request:
    paths: ['packages/**', 'lib/**', 'targets.sh', 'build']
  workflow_dispatch:
    inputs:
      package:
        description: 'Package to build (empty = all)'
        required: false

permissions:
  contents: read

jobs:
  prepare:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.gen.outputs.matrix }}
      package: ${{ steps.gen.outputs.package }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 2 }

      - id: gen
        name: Compute the build matrix
        run: |
          set -eu
          # A tag is always a release of exactly one package: <pkg>-v<version>.
          case "$GITHUB_REF" in
            refs/tags/*)
              pkg="${GITHUB_REF#refs/tags/}"
              pkg="${pkg%%-v*}"
              ;;
            *)
              pkg="${{ github.event.inputs.package }}"
              ;;
          esac
          echo "package=$pkg" >> "$GITHUB_OUTPUT"
          echo "matrix=$(sh ci/matrix.sh $pkg)" >> "$GITHUB_OUTPUT"

  build:
    needs: prepare
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}
    name: ${{ matrix.package }} ${{ matrix.target }}${{ matrix.variant && format('/{0}', matrix.variant) }}
    steps:
      - uses: actions/checkout@v4

      - name: Install host build tools
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq build-essential bzip2 xz-utils file \
            binutils-multiarch qemu-user-static >/dev/null

      # Only the compiled musl and compiler-rt for this target are worth
      # caching (~100 MB). The zig release itself is a 55 MB download that
      # takes seconds and unpacks to 400 MB, which would cost more to cache
      # than it saves.
      - name: Cache the compiled musl for this target
        uses: actions/cache@v4
        with:
          path: .cache/zig/zig-cache
          key: zig-0.16.0-musl-${{ matrix.target }}

      - name: Cache the Bootlin toolchain for this target
        uses: actions/cache@v4
        with:
          path: .cache/bootlin
          key: bootlin-2025.08-1-${{ matrix.target }}

      - name: Cache sources
        uses: actions/cache@v4
        with:
          path: .cache/src
          key: src-${{ matrix.package }}-${{ hashFiles(format('packages/{0}/meta', matrix.package)) }}

      - name: Build
        run: |
          if [ -n "${{ matrix.variant }}" ]; then
            ./build ${{ matrix.package }} ${{ matrix.target }} --variant ${{ matrix.variant }}
          else
            ./build ${{ matrix.package }} ${{ matrix.target }}
          fi

      # build already runs the gate; this makes what it checked visible in the
      # log, which is what anyone debugging a device actually wants to read.
      - name: Show what was produced
        run: |
          ls -l out/
          for f in out/*.tar.gz; do
            echo "== $f"
            tar xzf "$f" -O ./MANIFEST 2>/dev/null || tar xzf "$f" -O MANIFEST
          done

      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.package }}-${{ matrix.target }}${{ matrix.variant && format('-{0}', matrix.variant) }}
          path: |
            out/*.tar.gz
            out/*.sha256
          if-no-files-found: error
          retention-days: 14

  release:
    needs: [prepare, build]
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { path: artifacts }
      - name: Collect release assets
        run: |
          mkdir -p release
          find artifacts -type f \( -name '*.tar.gz' -o -name '*.sha256' \) \
            -exec cp {} release/ \;
          cp detect.sh release/
          ls -l release/
      - name: Create the release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            --title "$GITHUB_REF_NAME" \
            --generate-notes \
            release/*
```

- [ ] **Step 7: Verify the matrix generator against the real package**

```bash
sh ci/matrix.sh dsvpn | tr ',' '\n' | head -20
sh tests/run-all.sh
```
Expected: osiem wpisów, żadnego `armv7-aes`; cała sucha zielona.

- [ ] **Step 8: Commit and push, then watch CI**

```bash
chmod +x ci/matrix.sh
git add ci/matrix.sh .github/workflows/
git commit -m "Build every package from one workflow

The matrix is computed at run time from targets.sh and packages/*/meta, so
adding a target or a package needs no edit to any YAML. A workflow file per
package was the alternative: at nine targets and a growing package list that
is N files to keep in sync by hand, which is the drift this repo exists to end."
git push
gh run watch
```

- [ ] **Step 9: Tag the first release once CI is green**

```bash
git tag dsvpn-v0.1.4-r1
git push origin dsvpn-v0.1.4-r1
gh run watch
gh release view dsvpn-v0.1.4-r1
```
Expected: Release z ośmioma tarballami, ośmioma `.sha256` i `detect.sh`.

---

## Task 10: README i dokumentacja targetów

**Files:**
- Create: `README.md`
- Create: `docs/targets.md`
- Create: `docs/adding-a-package.md`

- [ ] **Step 1: Generate `docs/targets.md` from the matrix**

Dokumentacja targetów **nie może** być przepisywana ręcznie — rozjedzie się z `targets.sh` przy pierwszej zmianie. Utwórz `ci/targets-doc.sh`:

```sh
#!/bin/sh
# Render docs/targets.md from targets.sh, so the two cannot drift apart.
set -eu
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
. "$HERE/targets.sh"

printf '# Targets\n\n'
printf 'Generated from `targets.sh` by `ci/targets-doc.sh`. Do not edit by hand.\n\n'
printf '| target | status | ABI | CPU | endianness | qemu |\n'
printf '|---|---|---|---|---|---|\n'
for t in $(sb_targets_all); do
	en="$(sb_target_field "$t" enabled)"
	[ "$en" = '1' ] && st='active' || st='disabled'
	printf '| `%s` | %s | `%s` | `%s` | %s | `%s` |\n' \
		"$t" "$st" \
		"$(sb_target_field "$t" zig_target)" \
		"$(sb_target_field "$t" zig_cpu)" \
		"$(sb_target_field "$t" elf_data)" \
		"$(sb_target_field "$t" qemu)"
done
```

Run: `chmod +x ci/targets-doc.sh && ./ci/targets-doc.sh > docs/targets.md`

- [ ] **Step 2: Add a CI check that the generated doc is current**

Dopisz do `.github/workflows/test.yml`, w job `suite`, po kroku z suchą:

```yaml
      - name: docs/targets.md matches targets.sh
        run: |
          ./ci/targets-doc.sh > /tmp/targets.md
          if ! cmp -s /tmp/targets.md docs/targets.md; then
            echo "docs/targets.md is stale -- run ./ci/targets-doc.sh > docs/targets.md"
            diff -u docs/targets.md /tmp/targets.md || true
            exit 1
          fi
```

- [ ] **Step 3: Write `README.md`**

```markdown
# staticbox

Statically linked binaries for embedded Linux boxes: Enigma2 set-top boxes and
OpenWrt routers. Nothing here links against anything on the device.

One recipe per tool, eight architectures, every binary checked against what it
actually contains before it is released.

## Getting a binary onto a device

```sh
wget -qO- https://raw.githubusercontent.com/areqq/staticbox/main/detect.sh | sh
```

prints the target name for that device. Releases are named
`<package>-<version>-<target>.tar.gz`.

## Targets

See [docs/targets.md](docs/targets.md). The short version: `armv7` is a real
baseline with no NEON, `armv7-neon` is for boxes that have it, MIPS is pinned
to release 1 because a BCM7356 traps on r2, and everything below ARMv7 is
soft-float because that is what those devices ship.

## Building locally

```sh
./build dsvpn              # every enabled target
./build dsvpn mipsel       # one
./build dsvpn --list       # what this package supports
sh tests/run-all.sh        # the suite; no network, builds nothing
```

Needs `curl`, `tar`, `make`, `sha256sum` and `qemu-user-static`. The
cross-compiler downloads itself.

## Adding a package

See [docs/adding-a-package.md](docs/adding-a-package.md).

## Why the verification gate is the way it is

`qemu-arm-static`'s cortex-a7 model has NEON. A binary built with NEON but
labelled as the baseline target therefore runs perfectly under qemu and takes a
SIGILL on the first box that has an A7 without NEON. So on ARM the decisive
check reads the build attributes the compiler recorded in the ELF, not the
behaviour under emulation. On MIPS it is the other way round: qemu's 4Kc really
is a MIPS32 r1 core, so there running it catches the r2 encoding that traps on
a BCM7356.
```

- [ ] **Step 4: Write `docs/adding-a-package.md`**

```markdown
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

`SHA256` is not optional. Pin releases to a tag or a release tarball, never to
a branch: GitHub regenerates branch tarballs and they are not byte-stable, so
no checksum can hold.

### Variants

A package can declare `VARIANTS='lean full'`. A variant that is only worth
building somewhere gets `VARIANT_TARGETS_<variant>`:

```sh
VARIANTS='lean full'
VARIANT_TARGETS_full='armv7-neon mipsel x86_64'
```

## `packages/<name>/build.sh`

Handed, ready to use: `TARGET VARIANT SRC WORK OUT` and
`CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS`. The source at `$SRC` is
already fetched, checksum-verified, unpacked and patched.

Put the result in `$OUT` (a `bin/` subdirectory is conventional) and exit 0.
Do not fetch, do not strip, do not package, and do not add `-static` or `-Os`
yourself -- they are already in `$LDFLAGS` and `$CFLAGS`, and a recipe that
sets its own loses the target's architecture flags with them.

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
```

- [ ] **Step 5: Commit**

```bash
chmod +x ci/targets-doc.sh
./ci/targets-doc.sh > docs/targets.md
git add README.md docs/targets.md docs/adding-a-package.md ci/targets-doc.sh .github/workflows/test.yml
git commit -m "Document the matrix, the recipe contract and the gate

docs/targets.md is generated from targets.sh and CI fails if it is stale:
a hand-maintained copy of the matrix would drift on the first change, which
is the failure mode this repo was built to end."
git push
```

---

## Definicja ukończenia etapu 0

- [ ] `sh tests/run-all.sh` zielone lokalnie i w CI
- [ ] `shellcheck -s sh` czysty na wszystkich skryptach
- [ ] `./build dsvpn` produkuje osiem tarballi, każdy z `MANIFEST` i `.sha256`
- [ ] bramka ISA udowodniona: binarka z NEON-em odrzucona jako `armv7` (Task 7, krok 7)
- [ ] `detect.sh` zwraca poprawny target dla fixture'ów mipsel i ARM
- [ ] Release `dsvpn-v0.1.4-r1` opublikowany z ośmioma tarballami
- [ ] `docs/targets.md` generowany, nie pisany ręcznie
