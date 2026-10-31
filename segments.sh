#!/usr/bin/env bash
# Code the corpus at one level with the segment length set four ways: one segment (no seek table), a seek point
# every 10 s and every 1 s, and every group a segment. Blocks read earlier samples only within their segment, so
# shorter segments cost bits and buy seeking and damage containment. Eight files at a time; the bytes do not
# depend on the timing. Writes results/segments.txt. Usage: segments.sh [level, 4 when left out]
set -euo pipefail
cd "$(dirname "$0")"
level=${1:-4}
total() { awk '{ b += $1; s += $2 } END { printf "%d bytes, %.3f bits per sample", b, 8 * b / s }'; }
one() { out=$(ada/obj/codec_main "$1" "$level" $2); bytes=$(grep -oE '[0-9]+ bytes' <<< "$out" | head -1 | cut -d' ' -f1)
        samples=$(ffprobe -v error -show_entries stream=channels,duration_ts -of csv=p=0 "$1" | awk -F, '{print $1 * $2}'); echo "$bytes $samples"; }
export -f one; export level
{
  echo "level $level, 40 files"
  for v in "--seek-every 0" "--seek-every 10" "--seek-every 1" "--independent"; do
    printf '%-18s %s\n' "$v:" "$(ls corpus/*.flac corpus/*.wav | sed 's|corpus/\(.*\)\.[a-z]*|build/wav/\1.wav|' | xargs -P 8 -I{} bash -c 'one "$1" "$2"' _ {} "$v" | total)"
  done
} | tee results/segments.txt
