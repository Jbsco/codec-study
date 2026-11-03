#!/usr/bin/env bash
# Time seeks through each codec's library: FLAC, WavPack and the block codec's decoder handle, on two files from the
# corpus, 120 s of six 48 kHz recordings joined and the 192 kHz vinyl recording. Each method opens the file once,
# then seeks to 200 frames drawn from one seed and reads 4096 frames from each; the median, 90th percentile and
# largest times go to results/seek_timing.tsv with a check sum that must equal FLAC's. Runs on one pinned processor
# and prints the load average, since a seek competes with the rest of the machine. Needs flac, wavpack, ffmpeg, the
# FLAC and WavPack development headers, the library (gprbuild -P ada/codec_lib.gpr) and the release blkc-encode.
set -uo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p results
out=results/seek_timing.tsv
cc -std=c11 -O2 -Wall -Wextra -Werror -Iinclude capi/seek_bench.c -o "$work/seek_bench" -lFLAC -lwavpack \
  -Lada/lib -lblockcodec -Wl,-rpath,"$PWD/ada/lib" || exit 1
printf "file '%s'\n" "$PWD"/corpus/rec_orchestra.flac "$PWD"/corpus/rec_room.flac "$PWD"/corpus/rec_speech.flac \
  "$PWD"/corpus/extra/extra_birds.flac "$PWD"/corpus/extra/extra_choir.flac "$PWD"/corpus/extra/extra_quartet.flac \
  > "$work/list"
ffmpeg -v error -f concat -safe 0 -i "$work/list" -c:a pcm_s24le "$work/joined_48k.wav" || exit 1
ffmpeg -v error -i corpus/rec_vinyl_192k.flac -c:a pcm_s24le "$work/vinyl_192k.wav" || exit 1
echo "load average: $(cut -d' ' -f1-3 /proc/loadavg)"
printf 'method\tfile\tframes\tmedian_ms\tp90_ms\tmax_ms\tcheck\n' > "$out"
for name in joined_48k vinyl_192k; do
  wav="$work/$name.wav"
  flac -s -f -5 -o "$work/a.flac" "$wav"; flac -s -f -8 -o "$work/b.flac" "$wav"
  wavpack -q -y "$wav" -o "$work/c.wv"; wavpack -q -y -hh "$wav" -o "$work/d.wv"
  for level in 2 4 5; do ada/obj-release/blkc-encode --level "$level" "$wav" "$work/l$level.blkc" 2> /dev/null; done
  reference=
  for m in "flac -5:a.flac" "flac -8:b.flac" "wavpack:c.wv" "wavpack -hh:d.wv" "block level 2:l2.blkc" \
           "block level 4:l4.blkc" "block level 5:l5.blkc"; do
    line=$(taskset -c 1 "$work/seek_bench" "$work/${m#*:}" 200 4096 7) || { echo "  ${m%%:*}, $name: FAILED"; continue; }
    IFS=$'\t' read -r _ frames median p90 max check <<< "$line"
    reference=${reference:-$check}
    [ "$check" = "$reference" ] || echo "  ${m%%:*}, $name: samples differ from FLAC's"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${m%%:*}" "$name" "$frames" "$median" "$p90" "$max" "$check" >> "$out"
    printf '  %-14s %-11s median %8s ms  90th %8s ms  largest %8s ms\n' "${m%%:*}" "$name" "$median" "$p90" "$max"
  done
done
