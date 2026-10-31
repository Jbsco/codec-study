#!/usr/bin/env bash
# Print a Markdown table of the comparison tools: package and installed size (pacman), executable bytes, and
# the bytes of the codec libraries the executable loads.
set -uo pipefail

row() {  # tool library-pattern
  local exe pkg ver installed lib
  exe=$(readlink -f "$(command -v "$1")")
  pkg=$(pacman -Qqo "$exe")
  ver=$(pacman -Q "$pkg" | cut -d' ' -f2)
  installed=$(pacman -Qi "$pkg" | awk -F': *' '/^Installed Size/ {print $2}')
  lib=$(ldd "$exe" | awk '{print $3}' | grep -E "$2" | xargs -r readlink -f | xargs -r stat -c %s | paste -sd+ | bc)
  printf '| %s | %s %s | %s | %s | %s |\n' "$1" "$pkg" "$ver" "$installed" "$(stat -c %s "$exe")" "${lib:-in the executable}"
}

printf '| Tool | Package | Installed size | Executable, bytes | Codec libraries, bytes |\n|---|---|---|---|---|\n'
row gzip '^$'
row bzip2 'libbz2'
row xz 'liblzma'
row zstd 'libzstd'
row lz4 'liblz4'
row brotli 'libbrotli'
row flac 'libFLAC'
row wavpack 'libwavpack'
row ffmpeg 'libavcodec|libavformat|libavutil'
