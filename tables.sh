#!/usr/bin/env bash
# Merge results/ada.txt, results/haskell.txt and results/compare.tsv into Markdown tables of bits per sample.
set -euo pipefail
cd "$(dirname "$0")"

order="signal_silence signal_dither signal_white signal_pink signal_brown signal_sine signal_square signal_triangle
signal_sawtooth signal_impulses signal_sweep signal_fm signal_chord rate_sine_8000 rate_sine_16000 rate_sine_96000
rate_sine_192000 rate_pink_8000 rate_pink_16000 rate_pink_96000 rate_pink_192000 depth_sine_8 depth_sine_12in16
depth_sine_24 depth_sine_32 depth_sine_32f depth_pink_8 depth_pink_24 depth_pink_32 depth_pink_32f rec_speech_8k
rec_speech_16k rec_speech rec_piano rec_piano_96k rec_orchestra rec_orchestra_f32 rec_electronic rec_room rec_vinyl_192k"

awk -v order="$order" '
  function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
  function put(key, line, width,    rest) {
    rest = substr(line, 3 + width); split(rest, f, " ")
    v[file, key] = (index(line, "round trip OK") ? f[1] : "failed")
    if (!(key in seen)) { seen[key] = 1; keys[++nk] = key }
  }
  FILENAME ~ /compare.tsv$/ {
    split($0, f, "\t"); key = "tool:" f[2]
    v[f[1], key] = (f[5] == "ok") ? sprintf("%.2f", f[3] * 8 / f[4]) : "n/a"
    if (!(key in seen)) { seen[key] = 1; keys[++nk] = key }
    next
  }
  /^build\/wav\// { file = $0; sub(/^build\/wav\//, "", file); sub(/\.wav$/, "", file); next }
  /^ [0-9]/ {
    if (FILENAME ~ /ada.txt$/) {
      fmt[file] = ($0 ~ /float/) ? "f32" : $1; sub(/-bit,?/, "", fmt[file])
      rate[file] = $0; sub(/^[^,]*, */, "", rate[file]); sub(/ Hz.*/, "", rate[file])
      ch[file] = $0; sub(/^.* Hz, */, "", ch[file]); sub(/ channels.*/, "", ch[file])
    }
    next
  }
  /^  / && FILENAME ~ /ada.txt$/ { put("ada:" trim(substr($0, 3, 48)), $0, 48); next }
  /^  / && FILENAME ~ /haskell.txt$/ { put("hs:" trim(substr($0, 3, 52)), $0, 52); next }
  END {
    n = split(order, files, /[ \n]+/)
    printf "| File | PCM | Best general-purpose | Best audio codec | Ada tiers, 16 from start | Ada tiers, pairs, mean | Ada fixed, Rice | Ada fixed, bit-length | Haskell fixed, shorter | Haskell tiers |\n"
    printf "|---|---|---|---|---|---|---|---|---|---|\n"
    for (i = 1; i <= n; i++) {
      x = files[i]; bg = ""; ba = ""; bgv = 1e9; bav = 1e9
      for (k = 1; k <= nk; k++) {
        key = keys[k]; if (key !~ /^tool:/ || v[x, key] == "n/a" || v[x, key] == "") continue
        name = substr(key, 6); val = v[x, key] + 0
        if (name ~ /^(gzip|bzip2|xz|zstd|lz4|brotli)/) { if (val < bgv) { bgv = val; bg = name } }
        else if (val < bav) { bav = val; ba = name }
      }
      printf "| %s | %s %s %s | %.2f %s | %.2f %s | %s | %s | %s | %s | %s | %s |\n", x,
        (fmt[x] == "f32" ? "32 f" : fmt[x]), rate[x] / 1000 "k", (ch[x] == 1 ? "mono" : "stereo"),
        bgv, "(`" bg "`)", bav, "(`" ba "`)",
        v[x, "ada:Tiers, groups of 16, offset from group start"], v[x, "ada:Tiers, pairs, offset from mean of both anchors"],
        v[x, "ada:Fixed predictor, Rice per block"], v[x, "ada:Fixed predictor, bit-length Huffman per block"],
        v[x, "hs:Fixed predictor, shorter of the two per block"], v[x, "hs:Tiers, pairs, offset from mean, bit-length per chunk"]
    }
    printf "\n| Method |"
    for (i = 1; i <= n; i++) printf " %s |", files[i]
    printf "\n|---|"
    for (i = 1; i <= n; i++) printf "---|"
    printf "\n"
    for (k = 1; k <= nk; k++) {
      printf "| %s |", keys[k]
      for (i = 1; i <= n; i++) printf " %s |", v[files[i], keys[k]]
      printf "\n"
    }
  }
' results/ada.txt results/haskell.txt results/compare.tsv
