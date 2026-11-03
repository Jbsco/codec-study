#!/usr/bin/env bash
# Build the wider corpus in corpus/extra: 20 s segments of six more recordings that are marked public domain or
# dedicated under CC0, kept apart from the study corpus so its results stay comparable. Integer PCM is stored as FLAC.
# Needs curl, ffmpeg and flac.
set -euo pipefail
cd "$(dirname "$0")"
src=source/extra
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p "$src" extra

# Fetch the first BYTES of URL to FILE, or all of it, and check its MD5.
fetch() {  # file url md5 [bytes]
  if [[ ! -s $1 ]]; then
    if [[ -n ${4:-} ]]; then curl -sSfL --retry 3 -r "0-$(($4 - 1))" -o "$1" "$2"; else curl -sSfL --retry 3 -o "$1" "$2"; fi
  fi
  echo "$3  $1" | md5sum -c --quiet
}

ia=https://archive.org/download
fetch "$src/quartet_head.flac" "$ia/MusopenCollectionAsFlac/Haydn_StringQuartetInDMajorOp.64/JosephHaydn-StringQuartetInDOp.645H363Lark-04-FinaleVivace.flac" 6a7bea7fe08010c083f464710903f951 8388608
fetch "$src/birds_head.wav" "$ia/aporee_70008_81545/ActiveBirdsDistantInsectsandCalmWindsatBobiriButterflySanctuaryGhana.wav" 8df3e963aea1a7d04dc70e3b58378ead 16777216
fetch "$src/rain_head.mp3" "$ia/aporee_73575_85987/RainandThunderInChad.mp3" bb86092fcf25966bc2719f1e4275064a 4194304
fetch "$src/launch.wav" "$ia/NasaLaunchAudio/01-Nasa-Sts-87Launch.wav" a35e1632092e544e411a53bc2f4ecf96
fetch "$src/choir_head.wav" "$ia/aporee_60543_69571/PavaneThoinotArbeau.wav" f1ae21bc147c5c81267137de07d13dd9 16777216
fetch "$src/organ_head.wav" "$ia/EasyListeningOrganMusic/EasyListeningOrganMusic.wav" 7d05434385ad8e1536b58e0014b87183 20971520

# A segment of a recording, stored as FLAC.
cut() {  # name source start seconds [ffmpeg output options]
  ffmpeg -v error -y -ss "$3" -t "$4" -i "$2" -bitexact -map_metadata -1 "${@:5}" "$work/$1.wav"
  flac -8 -s -f -o "extra/$1.flac" "$work/$1.wav"
}

cut extra_quartet "$src/quartet_head.flac" 15 20 -c:a pcm_s24le
cut extra_birds "$src/birds_head.wav" 10 20 -c:a pcm_s24le
cut extra_rain_mp3 "$src/rain_head.mp3" 5 20 -c:a pcm_s16le
cut extra_launch "$src/launch.wav" 20 20 -c:a pcm_s16le
cut extra_choir "$src/choir_head.wav" 10 20 -c:a pcm_s24le
cut extra_organ "$src/organ_head.wav" 30 20 -c:a pcm_s16le

(cd extra && sha256sum -- *.flac > SHA256SUMS)
ls -l -- extra/*.flac | awk '{s += $5} END {printf "%d files, %.1f MB\n", NR, s / 1e6}'
