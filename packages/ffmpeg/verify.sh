#!/bin/sh
# Deep check for ffmpeg: encode something and read it back.
#
# The generic gate proves the binary is for the right architecture and prints
# its version. It cannot tell a working ffmpeg from one configured into
# uselessness -- a build with no encoders still answers -version perfectly.
#
# Given: TARGET VARIANT OUT, and the matrix through targets.sh.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$HERE/targets.sh"

QEMU="$(sb_target_field "$TARGET" qemu)"
QCPU="$(sb_target_field "$TARGET" qemu_cpu)"
if ! command -v "$QEMU" >/dev/null 2>&1; then
	printf 'verify: %s not installed, skipping the deep check\n' "$QEMU" >&2
	exit 0
fi

run() {
	if [ -n "$QCPU" ]; then "$QEMU" -cpu "$QCPU" "$@"; else "$QEMU" "$@"; fi
}

CLIP="$OUT/.verify-clip.mp4"
rm -f "$CLIP"

# lavfi's testsrc needs no input file, so this exercises the whole chain --
# filter, encoder, muxer -- without shipping a sample. Tiny and short: this
# runs under emulation on eight architectures.
run "$OUT/bin/ffmpeg" -hide_banner -loglevel error \
	-f lavfi -i testsrc=size=128x96:rate=5:duration=1 \
	-c:v mpeg4 -y "$CLIP" >/dev/null 2>&1 \
	|| { printf 'verify: ffmpeg could not encode a test clip\n' >&2; rm -f "$CLIP"; exit 1; }

[ -s "$CLIP" ] || { printf 'verify: ffmpeg produced an empty file\n' >&2; rm -f "$CLIP"; exit 1; }

# And the demuxer/decoder side, on the file just written.
PROBE="$(run "$OUT/bin/ffprobe" -hide_banner -loglevel error \
	-show_entries stream=codec_name,width,height -of default=nw=1 "$CLIP" 2>&1)" \
	|| { printf 'verify: ffprobe could not read the clip back\n' >&2; rm -f "$CLIP"; exit 1; }

rm -f "$CLIP"

for want in 'codec_name=mpeg4' 'width=128' 'height=96'; do
	case "$PROBE" in
		*"$want"*) : ;;
		*) printf 'verify: ffprobe did not report %s\n' "$want" >&2; exit 1 ;;
	esac
done

printf 'verify: ffmpeg encodes and ffprobe reads it back on %s\n' "$TARGET"
