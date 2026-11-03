#!/usr/bin/env bash
# Check the block codec on the wider corpus in corpus/extra: each file must come back byte for byte from
# stream_encode and stream_decode at levels 0, 2 and 4, and the Ada, Haskell and hybrid programs must write one
# stream at level 4. Writes results/extra.tsv with each file's coded bytes beside flac -8 and wavpack -hh -x4. Needs
# the Ada release programs, the Ada and Haskell builds of run.sh, flac, wavpack and ffprobe.
set -uo pipefail
cd "$(dirname "$0")"
hs="haskell/$(cd haskell && stack path --dist-dir)/build"
export LD_LIBRARY_PATH=$PWD/ada/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p build/extra results
out=results/extra.tsv
printf 'file\tformat\tpcm_bytes\tlevel_0\tlevel_2\tlevel_4\tflac_8\twavpack_hh_x4\tthree_implementations\n' > "$out"
fail=0
for f in corpus/extra/*.flac; do
  name=$(basename "$f" .flac)
  wav=build/extra/$name.wav
  flac -d -s -f -o "$wav" "$f"
  eval "$(ffprobe -v error -show_entries stream=sample_rate,channels,bits_per_sample,duration_ts -of default=nw=1 "$wav")"
  format="$bits_per_sample $((sample_rate / 1000))k $channels ch"
  pcm=$((duration_ts * channels * ((bits_per_sample + 7) / 8)))
  sizes=()
  for level in 0 2 4; do
    ada/obj-release/stream_encode --level $level "$wav" "$work/s.bin" 2> /dev/null
    if ada/obj-release/stream_decode "$work/s.bin" "$work/d.wav" 2> /dev/null && cmp -s "$wav" "$work/d.wav"; then
      sizes+=("$(stat -c %s "$work/s.bin")")
    else
      echo "extra: $name level $level does not come back byte for byte" >&2
      sizes+=(FAILED); fail=1
    fi
  done
  a=$(ada/obj/codec_main "$wav" 4 | grep -oE 'hash [0-9a-f]+')
  h=$("$hs/huffman-audio/huffman-audio" "$wav" --block 4 | grep -oE 'hash [0-9a-f]+')
  y=$("$hs/huffman-audio-hybrid/huffman-audio-hybrid" "$wav" 4 | grep -oE 'hash [0-9a-f]+')
  if [ -n "$a" ] && [ "$a" = "$h" ] && [ "$a" = "$y" ]; then same=yes; else same=no; fail=1; fi
  flac -8 -s -f -o "$work/c.flac" "$wav"
  wavpack -q -y -hh -x4 "$wav" -o "$work/c.wv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$format" "$pcm" "${sizes[@]}" "$(stat -c %s "$work/c.flac")" \
    "$(stat -c %s "$work/c.wv")" "$same" >> "$out"
  echo "$name done" >&2
done
column -t -s $'\t' "$out"
exit $fail
