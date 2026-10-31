#!/usr/bin/env bash
# Run the block codec at every level on every file: Ada and SPARK on one thread, Haskell on all cores. Writes
# results/levels.txt, one line per file and level with the stream bytes, the PCM bytes and the times.
set -euo pipefail
cd "$(dirname "$0")"
hs=haskell/$(cd haskell && stack path --dist-dir)/build/huffman-audio/huffman-audio
pcm() { ffprobe -v error -show_entries stream=channels,duration_ts,bits_per_sample,bits_per_raw_sample -of default=nw=1 "$1" |
        awk -F= '{v[$1] = $2} END {b = v["bits_per_sample"]; if (b == 0) b = v["bits_per_raw_sample"]; print v["channels"] * v["duration_ts"] * int((b + 7) / 8)}'; }
{
  printf 'file\tlevel\tpcm_bytes\tbytes\tbits_per_sample\tada_encode_s\tada_decode_s\thaskell_encode_s\thaskell_decode_s\n'
  for level in 0 1 2 3 4 5; do
    for w in build/wav/*.wav; do
      a=$(ada/obj/codec_main "$w" "$level" | grep 'Block codec')
      h=$("$hs" "$w" --block "$level" | grep 'Block codec')
      grep -q 'round trip OK' <<< "$a$h" || { echo "round trip failed: $w level $level" >&2; exit 1; }
      [ "$(grep -oE 'hash [0-9a-f]+' <<< "$a")" = "$(grep -oE 'hash [0-9a-f]+' <<< "$h")" ] || { echo "streams differ: $w level $level" >&2; exit 1; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$w" .wav)" "$level" "$(pcm "$w")" \
        "$(grep -oE '[0-9]+ bytes' <<< "$a" | cut -d' ' -f1)" "$(awk '{print $6}' <<< "$a")" \
        "$(sed -E 's/.*encode *([0-9.]+) s.*/\1/' <<< "$a")" "$(sed -E 's/.*decode *([0-9.]+) s.*/\1/' <<< "$a")" \
        "$(sed -E 's/.*encode *([0-9.]+) s.*/\1/' <<< "$h")" "$(sed -E 's/.*decode *([0-9.]+) s.*/\1/' <<< "$h")"
    done
  done
} > results/levels.txt
