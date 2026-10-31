#!/usr/bin/env bash
# Compress each WAV file in build/wav with common lossless tools, decode every result again, and write
# one line per file and method to results/compare.tsv: file, method, bytes, samples, status.
# Status is ok, or unsupported when the tool rejects the format or does not restore it exactly.
set -uo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p results
out=results/compare.tsv
: > "$out"

# Label, then the compressor and decompressor, both from stdin to stdout.
general=(
  "gzip -1|gzip -1 -c|gzip -d -c"
  "gzip -9|gzip -9 -c|gzip -d -c"
  "bzip2 -9|bzip2 -9 -c|bzip2 -d -c"
  "xz -6|xz -6 -c|xz -d -c"
  "xz -9e|xz -9e -c|xz -d -c"
  "zstd -3|zstd -3 -c|zstd -d -c"
  "zstd -19|zstd -19 -c|zstd -d -c"
  "lz4 -1|lz4 -1 -c|lz4 -d -c"
  "lz4 -12|lz4 -12 -c|lz4 -d -c"
  "brotli -q 11|brotli -q 11 -c|brotli -d -c"
)
audio=("flac -0" "flac -5" "flac -8" "wavpack -f" "wavpack" "wavpack -hh" "wavpack -hh -x4" "ffmpeg alac" "ffmpeg tta")

for wav in build/wav/*.wav; do
  name=$(basename "$wav" .wav)
  eval "$(ffprobe -v error -show_entries stream=codec_name,channels,duration_ts -of default=nw=1 "$wav")"
  samples=$((duration_ts * channels))
  pcm=${codec_name#pcm_}
  ref=$(ffmpeg -v error -i "$wav" -f "$pcm" - | md5sum | cut -c1-32)

  for entry in "${general[@]}"; do
    IFS='|' read -r label enc dec <<< "$entry"
    if $enc < "$wav" > "$work/c" 2>/dev/null && $dec < "$work/c" 2>/dev/null | cmp -s - "$wav"; then
      printf '%s\t%s\t%s\t%s\tok\n' "$name" "$label" "$(stat -c %s "$work/c")" "$samples" >> "$out"
    else
      printf '%s\t%s\t0\t%s\tunsupported\n' "$name" "$label" "$samples" >> "$out"
    fi
  done

  for label in "${audio[@]}"; do
    rm -f "$work"/a.*
    case $label in
      flac*) file="$work/a.flac"; $label -s -f -o "$file" "$wav" 2>/dev/null ;;
      wavpack*) file="$work/a.wv"; $label -q -y "$wav" -o "$file" 2>/dev/null ;;
      "ffmpeg alac") file="$work/a.m4a"; ffmpeg -v error -y -i "$wav" -c:a alac "$file" 2>/dev/null ;;
      "ffmpeg tta") file="$work/a.tta"; ffmpeg -v error -y -i "$wav" -c:a tta "$file" 2>/dev/null ;;
    esac
    if [[ -s $file ]] && [[ $(ffmpeg -v error -i "$file" -f "$pcm" - 2>/dev/null | md5sum | cut -c1-32) == "$ref" ]]; then
      printf '%s\t%s\t%s\t%s\tok\n' "$name" "$label" "$(stat -c %s "$file")" "$samples" >> "$out"
    else
      printf '%s\t%s\t0\t%s\tunsupported\n' "$name" "$label" "$samples" >> "$out"
    fi
  done
  echo "$name done"
done
