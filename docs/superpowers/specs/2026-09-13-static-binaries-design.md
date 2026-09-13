# Projekt: `staticbox` — centralne repo statycznych binarek multi-arch

Data: 2026-09-13
Status: zatwierdzony design, gotowy do rozpisania planu implementacji

## 1. Problem

Statyczne binarki dla set-top-boxów Enigma2 i routerów OpenWrt powstają dziś
w trzech niezależnych miejscach, które nie wiedzą o sobie nawzajem:

| źródło | stan | toolchain | targety | konwencja nazw |
|---|---|---|---|---|
| `sshd-tunnel/client` | repo `areqq/sshd-tunnel`, CI zielone | `zig cc` | 7 | `armv7`, `mipsel`, … |
| `sshd-tunnel/vpn-client` | j.w. | Bootlin | 7 | j.w. |
| `/home/q/ssh` | warsztat lokalny, **bez gita** | Bootlin | 3 | `-noneon`, `-mipsel` |

Skutki, które ten projekt ma usunąć:

1. **Trzy konwencje nazw tego samego sprzętu.** ARM bez NEON to `armv7`
   w jednym miejscu i `noneon` w drugim. Nie da się napisać jednego
   instalatora.
2. **Dwa niezależne detektory architektury** (`client/install.sh`
   i — w osobnym projekcie — `scripts/pick-binary.sh`), które niezależnie
   wymyśliły tę samą sztuczkę z czytaniem `EI_DATA` z `/bin/sh`, bo `uname -m`
   kłamie na MIPS-ie. Każdy zna trik, którego nie zna drugi.
3. **`sshd-tunnel/client` buduje `armv7` jako soft-NEON**, więc na VU+ Uno 4K SE
   nie wykorzystuje NEON-u, który ten box ma.
4. **80% powtórzonego kodu w przepisach.** Każdy skrypt buildu sam pobiera
   źródło, weryfikuje sumę, buduje, strippuje i pakuje.
5. **Wiedza o pułapkach buildów żyje w `CLAUDE.md`** jednego lokalnego,
   niewersjonowanego katalogu.

## 2. Zakres

**Wchodzi do `staticbox`:**
- przepisy buildów przeniesione z `/home/q/ssh` (nmap, speedtest, busybox,
  dropbear-chroot) — **tylko skrypty i wiedza**, patrz §2.1
- buildy przeniesione z `sshd-tunnel`: `client/` (dropbear) i `vpn-client/` (dsvpn)
- kanoniczna macierz targetów, jeden detektor architektury, jeden instalator
- nowe pakiety narzędziowe (socat, tcpdump, rsync, strace, curl…)

**Zostaje poza:**
- `sshd-tunnel` jako repo aplikacyjne: `run`, `rootfs-overlay`, instalator
  serwera, tryby `--vpn`/`--dsvpn`. Po etapie 1 ciągnie klienta z Releases
  `staticbox` zamiast go budować.
- `zigplayer` — osobny projekt, w całości poza tym repo. Służy wyłącznie jako
  źródło wzorców (macierz feature-based, detekcja CPU, bramki qemu w `build.zig`).

### 2.1 Czego NIE przenosić z `/home/q/ssh`

Ten katalog **nie nadaje się do `git init` w miejscu**. Zawiera:

- `keys/` — klucze prywatne
- `codedb.snapshot` — 240 MB lokalnego indeksu
- rozpakowane źródła nmap-7.95, openssl-3.0.16, libssh2-1.11.0 i ich tarballe
- `toolchain/` — 230 MB toolchainów Bootlin
- katalogi `*-build-*` z artefaktami pośrednimi

Do `staticbox` idą wyłącznie: `build.sh`, `build_nmap.sh`, `build_speedtest.sh`,
`make_chroot.sh`, `localoptions.h`, `gen_cred_slots.sh`, `patch-cred`
oraz treść `CLAUDE.md` przepisana do `docs/pitfalls.md`.

## 3. Macierz targetów

Dziewięć targetów, feature-based. Nazwa targetu jest jednocześnie: nazwą
w `targets.sh`, sufiksem assetu w Release, wyjściem `detect.sh` i kluczem
w indeksie.

| target | zig target + cpu | Bootlin toolchain + flagi | co to jest |
|---|---|---|---|
| `x86_64` | `x86_64-linux-musl` | `x86-64--musl` | host, x86 OpenWrt, testy |
| `i686` | `x86-linux-musl` `-mcpu=i686` | `x86-i686--musl` | stare x86 OpenWrt |
| `armv5` | `arm-linux-musleabi` `-mcpu=arm926ej_s` | `armv5-eabi--musl` | Kirkwood, stare routery, DM800 |
| `armv7` | `arm-linux-musleabihf` `-mcpu=cortex_a9-neon-d32` | `armv7-eabihf--musl` `-march=armv7-a -mfpu=vfpv3-d16` | wspólny mianownik ARM |
| `armv7-neon` | `arm-linux-musleabihf` `-mcpu=cortex_a15` | `armv7-eabihf--musl` `-mcpu=cortex-a15 -mfpu=neon-vfpv4` | VU+ Uno 4K SE, nowe STB |
| `armv7-aes` | `arm-linux-musleabihf` `-mcpu=cortex_a53+aes` | `armv7-eabihf--musl` `-mcpu=cortex-a53+crypto` | ARM z AES w sprzęcie, userland 32-bit |
| `aarch64` | `aarch64-linux-musl` | `aarch64--musl` | 64-bit STB/routery |
| `mips` | `mips-linux-musleabi` `-mcpu=mips32` | `mips32--musl` `-march=mips32 -mabi=32` | **big-endian**: ath79, stare OpenWrt |
| `mipsel` | `mipsel-linux-musleabi` `-mcpu=mips32` | `mips32el--musl` `-march=mips32 -mabi=32` | VU+ Solo2 (BCM7356), ramips |

Decyzje i ich uzasadnienia:

- **`mips32` r1, nie r2.** BCM7356/BMIPS5000 wywala illegal instruction na
  instrukcjach r2. Domyślny model CPU Ziga dla `mipsel` to r2 — musi być jawnie
  nadpisany.
- **`armv7` to `cortex_a9` minus NEON i d32, nie `cortex_a7`.** Zmierzone przy
  implementacji: `cortex_a7` minus te dwie cechy nadal emituje `Tag_FP_arch:
  VFPv4-D16`, co trapuje na Cortex-A9 (tylko VFPv3); odjęcie jeszcze `vfp4`
  w ogóle się nie kompiluje, bo `fma.c` musla ma inline asm wymagający VFP4,
  wybierany na podstawie modelu CPU. `cortex_a9` minus NEON i d32 daje dokładnie
  ARMv7-A / VFPv3-D16 / bez SIMD — czyli to, co znaczy wspólny mianownik.
- **`armv5` i MIPS są soft-float** (`musleabi`, bez `hf`) — to ABI, które ma
  przytłaczająca większość tych urządzeń.
- **`armv7-aes` jest na starcie wyłączony.** Wiersz istnieje w `targets.sh`
  z flagą `ENABLED=0`. Dla nmapa, dropbeara czy socata zysk jest znikomy, a to
  1/9 czasu CI. Włączenie = zmiana jednej wartości, gdy pojawi się pakiet,
  któremu sprzętowy AES realnie się opłaca.

### 3.1 `targets.sh` jako jedyne źródło prawdy

Jedna tabela, czytana przez: driver buildu, generator macierzy CI, `detect.sh`
i generator indeksu. Kolumny:

```
name|enabled|zig_target|zig_cpu|bootlin_tc|bootlin_flags|qemu|qemu_cpu|elf_class|elf_data|elf_machine
```

Dodanie targetu = dodanie jednego wiersza. Żaden inny plik nie zawiera listy
architektur.

## 4. Kontrakt przepisu pakietu

Rdzeń projektu: przepis nie wie, skąd wziął się jego kompilator, i nie zajmuje
się niczym poza kompilacją.

### 4.1 `packages/<pkg>/meta`

Deklaratywny, `sh`-owalny:

```sh
PKG=nmap
VERSION=7.95
REVISION=1
SOURCE=https://nmap.org/dist/nmap-7.95.tar.bz2
SHA256=<suma tarballa upstreamu>
TOOLCHAIN=bootlin              # domyślnie: zig
TARGETS=all                    # albo jawna lista
VARIANTS='lean full'           # domyślnie: brak
VARIANT_TARGETS_full='armv7-neon mipsel x86_64'
SMOKE='--version'              # czym sprawdzić, że binarka żyje
```

`REVISION` istnieje, bo ta sama wersja upstreamu bywa przebudowywana po
poprawce w przepisie — tag wydania to `<pkg>-v<VERSION>-r<REVISION>`.

**Backend bywa wybierany per target, nie tylko per pakiet:** `TOOLCHAIN_<target>`,
z myślnikiem zapisanym jako podkreślenie (`TOOLCHAIN_armv7_neon`). Powód wyszedł
przy pierwszym pakiecie: zig 0.16 nie linkuje `armv5` dla żadnego programu, który
woła `malloc` — jego własny alokator potrzebuje `__sync_*_1` i `__sync_*_4`,
których compiler-rt nie dostarcza dla części pre-ARMv6 bez LDREX/STREX. gcc
z Bootlina je ma, przez `__kuser_cmpxchg`. Ograniczenie toolchaina jest więc
własnością pary (target, pakiet), nie samego pakietu.

### 4.2 `packages/<pkg>/build.sh`

Dostaje w środowisku, gotowe do użycia:

| zmienna | znaczenie |
|---|---|
| `TARGET` | nazwa z `targets.sh`, np. `mipsel` |
| `VARIANT` | pusty albo jeden z `VARIANTS` |
| `CC CXX AR RANLIB STRIP` | pełne ścieżki/wrappery |
| `CFLAGS CXXFLAGS LDFLAGS` | z flagami arch, `-Os -ffunction-sections -fdata-sections`, `-static -Wl,--gc-sections` |
| `SRC` | rozpakowane, zweryfikowane źródło |
| `WORK` | katalog roboczy |
| `OUT` | tu mają wylądować gotowe pliki |

Odpowiedzialność `build.sh` kończy się na wyprodukowaniu plików w `$OUT`.
**Nie pobiera, nie weryfikuje sum, nie strippuje, nie pakuje** — to robi `lib/`.
Dzięki temu przeniesienie nmapa z Bootlina na `zig cc` jest zmianą jednej
linijki w `meta`, a nie przepisaniem skryptu.

### 4.3 Warstwa wspólna

- `lib/toolchain.sh` — `zig`|`bootlin` → komplet zmiennych z §4.2. Pobiera
  i cache'uje toolchain przy pierwszym użyciu, z przypiętą sumą SHA-256.
- `lib/fetch.sh` — pobranie źródła do `src-cache/`, weryfikacja `SHA256`,
  rozpakowanie, nałożenie `patches/*.patch` w kolejności leksykalnej.
- `lib/pack.sh` — wygenerowanie `MANIFEST`, `tar.gz`, `.sha256`. Strip **nie**
  jest tu osobnym krokiem: `LDFLAGS` niesie `-Wl,-s`, więc linker robi to sam.
  Powód: zig nie ma własnego `strip`, jego `objcopy --strip-all` jest w 0.16
  niezaimplementowane, a GNU `strip` hosta odmawia obcej binarki wprost — build
  przechodził lokalnie tylko dlatego, że maszyna deweloperska miała `llvm-strip`.
  `-Wl,-s` nie rusza `.ARM.attributes`, więc bramka ISA ma nadal czym działać.
- `lib/verify.sh` — bramka z §5.

## 5. Bramka weryfikacji

Dwa poziomy, oba przechodzone w CI **przed** utworzeniem Release.

### 5.1 smoke — obowiązkowy dla każdej pary (pakiet, target)

1. **Statyczność:** brak segmentu `PT_INTERP` w nagłówkach programowych.
   To twardszy dowód niż `file`, które opisuje tylko to, co widzi w sekcjach.
2. **Zgodność ELF:** `readelf -h` — `Class`, `Data`, `Machine` zgodne
   z kolumnami `elf_*` targetu.
3. **Zgodność zestawu instrukcji** — bramka właściwa, różna per architektura:
   - **ARM:** `readelf -A` (atrybuty budowy). Dla `armv7` wymagany jest **brak**
     `Tag_Advanced_SIMD_arch`, a `Tag_FP_arch` musi być pusty, `VFPv2` albo
     `VFPv3-D16` — nic wyżej: VFPv4 trapuje na Cortex-A9, a samo `VFPv3` (bez
     `-D16`) oznacza 32 rejestry D, których część z VFP D16 nie ma. Dla
     `armv7-neon` `Tag_Advanced_SIMD_arch` musi być obecny.
   - **MIPS:** `readelf -h` — pole `Flags` musi zawierać `mips32`, nie `mips32r2`.
   - Uzasadnienie: **`qemu-arm-static -cpu cortex-a7` ma NEON w modelu QEMU**,
     więc binarka z NEON-em zbudowana jako baseline przejdzie test pod qemu
     i wywali SIGILL dopiero na sprzęcie. Atrybuty ELF są tu jedyną
     wiarygodną bramką. Dla MIPS-a jest odwrotnie: `qemu-mipsel-static -cpu 4Kc`
     to realnie MIPS32 r1 i instrukcje r2 pod nim trapują, więc tam qemu działa.
4. **Uruchomienie:** `qemu-<arch>-static [-cpu <qemu_cpu>] "$bin" $SMOKE` → exit 0.

### 5.2 deep — opcjonalny, `packages/<pkg>/verify.sh`

Przenoszone z istniejących repo bez zmian w logice:
- `dropbear`: żywy login przez `dbclient` + round-trip SFTP, po wcześniejszym
  podmienieniu slotów poświadczeń zarówno przez `patch-cred`, jak i surowym `sed`
- `dsvpn`: postawienie tunelu
- `nmap`: skan `localhost`, sprawdzenie że `Compiled without:` jest puste
  w wariancie `full`

Deep musi mieć twardy `timeout` — hang pod `qemu-mipsel-static` zdarzył się
w tym kodzie dwa razy, przy dwóch niepowiązanych zmianach, obu poprawnych
na prawdziwym sprzęcie.

## 6. Wydanie i dystrybucja

### 6.1 Assety

- Nazwa: `<pkg>-<VERSION>-<target>[-<variant>].tar.gz` plus `.sha256`
- Zawartość: `<pkg>/bin/…` oraz `<pkg>/MANIFEST` z polami: pakiet, wersja,
  rewizja, target, toolchain, użyte `CFLAGS`/`LDFLAGS`, suma źródła, data,
  skrót commita repo
- Release per pakiet, tag `<pkg>-v<VERSION>-r<REVISION>`

`MANIFEST` istnieje po to, żeby binarka znaleziona za rok na boxie dała się
odtworzyć — dziś pliki w `out/` nie niosą żadnej informacji o tym, czym
i z czego powstały.

### 6.2 Indeks

Po każdym wydaniu generowane są dwa pliki, publikowane na branchu `index`:

- **`index.tsv`** — format roboczy dla `get.sh`:
  ```
  nmap	7.95-r1	mipsel	full	https://…	4118820	<sha256>
  ```
- `index.json` — ta sama treść dla ludzi i narzędzi.

TSV jest formatem podstawowym celowo: `get.sh` działa na busybox ash z ok. 2014
roku, gdzie nie ma `jq` ani pythona, a parsowanie JSON-a w POSIX sh jest
kruche. TSV to `grep` plus `cut`.

### 6.3 `get.sh`

Na boxie: `./get.sh nmap` → `detect.sh` zwraca target → `grep` w `index.tsv`
→ pobranie → weryfikacja sumy → rozpakowanie. Bez argumentu wersji bierze
najnowszą. `--variant`, `--version`, `--target` nadpisują.

Ograniczenia środowiska docelowego, dziedziczone z `sshd-tunnel/client/install.sh`:
busybox ash, brak `mktemp`, `id`, `diff`, `cmp`, `find -maxdepth`, brak
bashizmów; `command -v` bywa nieobecne (ASUSWRT-Merlin) — zawsze fallback
na `which`.

## 7. `detect.sh`

Scalenie dwóch istniejących detektorów. Każdy zna trik, którego nie zna drugi:

- **`EI_DATA` z `/bin/sh`** (bajt 5 nagłówka ELF) zamiast `uname -m` dla MIPS-a
  — `uname -m` raportuje `mips` również na little-endian.
- **`EI_CLASS` z `/bin/sh`** (bajt 4) — 64-bitowy kernel bywa pod 32-bitowym
  userlandem; liczy się userland, bo to on ładuje binarkę.
- **`/proc/cpuinfo` `Features:`** — `neon` → `armv7-neon`, `aes` → `armv7-aes`,
  nic → `armv7`. Kernel aarch64 pod 32-bitowym userlandem też je tam wypisuje.
- **fallback `which`** gdy brak `command -v`.

Wyjście: jedna nazwa targetu z `targets.sh`. Flaga `--fallback <pkg>` degraduje
do targetu, który ten pakiet faktycznie ma w indeksie (`armv7-neon` → `armv7`).

## 8. CI

Jeden workflow, `.github/workflows/build.yml`, z **dynamiczną macierzą**:

1. job `prepare` — czyta `targets.sh` i zmienione ścieżki, wypluwa JSON
   `(pakiet × target × wariant)`. Na push do `main`: tylko zmienione pakiety.
   Na tagu `<pkg>-v*` i na `workflow_dispatch`: pełny zestaw dla pakietu.
2. job `build` — `strategy.matrix.include: fromJSON(needs.prepare.outputs.matrix)`,
   `fail-fast: false`. Cache: `zig-cache` per target, `src-cache` per pakiet+wersja,
   toolchainy Bootlin per target.
3. job `verify-deep` — tylko dla pakietów, które mają `verify.sh`.
4. job `release` — warunkowy na tagu; zbiera assety, tworzy Release,
   regeneruje indeks.

Statyczna lista workflowów per pakiet jest odrzucona: przy 9 targetach i rosnącej
liczbie pakietów to N plików YAML do ręcznej synchronizacji za każdą zmianą macierzy.

## 9. Plan migracji

Pięć etapów; każdy zostawia repo w stanie działającym. **Każdy etap dostaje
własny plan implementacji** — ten spec jest wspólną podstawą, nie planem
jednego przebiegu. Pierwszy plan obejmuje wyłącznie etap 0.

| etap | zakres | uzasadnienie kolejności |
|---|---|---|
| 0 | `targets.sh`, `lib/`, driver `build`, `detect.sh`, CI; pakiet pilotażowy **`dsvpn`** | najmniejszy pakiet, zero zależności zewnętrznych, już działa na 7 arch — dowodzi całego rurociągu na czymś, co nie boli |
| 1 | **`dropbear`** z `sshd-tunnel/client` | najtrudniejszy: warianty core/sftp, patche, `patch-cred`, dwa skrypty `verify`. **Punkt bez powrotu** — patrz §9.1 |
| 2 | **`nmap`** (lean/full, `TOOLCHAIN=bootlin`), **`busybox`**, **`speedtest`** z `/home/q/ssh`; `ssh/CLAUDE.md` → `docs/pitfalls.md` | przepisy istnieją i działają, trzeba je tylko rozciąć wg kontraktu z §4 |
| 3 | rozszerzenie macierzy z 7 na 8 aktywnych targetów, `get.sh`, indeks | dopiero gdy wszystkie pakiety są w środku, inaczej indeks jest niepełny |
| 4 | nowe pakiety: `socat`, `tcpdump`, `rsync`, `strace`, `curl` | każdy to już tylko `meta` + `build.sh` |

### 9.1 Etap 1 jest skoordynowanym wydaniem dwóch repo

Po przeniesieniu dropbeara `sshd-tunnel` kasuje `client/build.sh` i przestaje
budować klienta. Wymaga to, w tej kolejności:

1. `staticbox` wydaje `dropbear-v2026.94-r1` ze wszystkimi targetami
2. `sshd-tunnel/client/install.sh` przepięty na indeks `staticbox`, z zachowaniem
   dotychczasowych nazw targetów jako aliasów (`armv7` mapuje się teraz
   na `armv7` lub `armv7-neon` zależnie od detekcji)
3. dopiero potem usunięcie `client/build.sh` i workflow `client.yml`

Istniejące Release'y `client-v*` w `sshd-tunnel` zostają nietknięte — urządzenia
zainstalowane starym instalatorem dalej działają.

## 10. Decyzje przyjęte

- **`armv7-aes` wyłączony na start** (`ENABLED=0` w `targets.sh`). Osiem
  aktywnych targetów. Włączenie to zmiana jednej wartości.
- **`nmap --full` tylko na `armv7-neon`, `mipsel`, `x86_64`.** Wariant `full`
  ciągnie OpenSSL 3 i libssh2, ok. 10 minut na target; pełna macierz to ok. 90
  minut CI na jedno wydanie nmapa. `lean` leci na wszystkie.
- **Repo `areqq/staticbox`, publiczne.** Publiczne daje darmowe CI i działające
  `raw.githubusercontent` w `get.sh`; prywatne wymagałoby tokenu na boxie,
  co przy busyboxowym `wget` jest niepraktyczne.
- **Język repo: angielski** (kod, komentarze, README, `docs/`), spójnie
  z `sshd-tunnel`, bo repo jest publiczne. Ten spec pozostaje po polsku.

## 11. Ryzyka

| ryzyko | ocena | reakcja |
|---|---|---|
| `nmap --full` nigdy nie ruszy pod `zig cc` | średnie | `TOOLCHAIN=bootlin` jest trwałą, wspieraną opcją, nie protezą — kontrakt z §4 to zakłada |
| Rozmiar Release: `nmap-full` mipsel to 7 MB, razy warianty i targety | niskie | GitHub nie limituje sumy Release; pojedynczy asset do 2 GB |
| Bootlin nie wyda toolchainów dla nowszego musl | niskie | wersja przypięta (`stable-2025.08-1`), a `zig` jest ścieżką wyjścia |
| `detect.sh` pomyli się na nieznanym boxie | średnie | `--fallback` degraduje do baseline; `get.sh` przyjmuje jawny `--target` |
| Czas CI przy 8 targetach × N pakietów | średnie | macierz dynamiczna buduje tylko zmienione pakiety; pełny przebieg tylko na tagu |
