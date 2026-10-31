#!/usr/bin/env bash
# Code a four-channel file, two stereo recordings merged, at level 4 with and without channel pairs, and the two
# recordings on their own, to show what pairing the channels of a multichannel file saves. Writes
# results/multichannel.txt.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/wav
ffmpeg -v error -y -i corpus/rec_orchestra.flac -i corpus/rec_room.flac -filter_complex "[0:a][1:a]amerge=inputs=2" \
  -c:a pcm_s24le build/four_48k.wav
line() { grep 'Block codec' | sed -E 's/^ +//'; }
{
  echo "four_48k = rec_orchestra (channels 1 and 2) + rec_room (channels 3 and 4), 48 kHz, 24-bit, 20 s, level 4"
  echo "pairs:     $(ada/obj/codec_main build/four_48k.wav 4 | line)"
  echo "no pairs:  $(ada/obj/codec_main build/four_48k.wav 4 --no-pairs | line)"
  echo "orchestra: $(ada/obj/codec_main build/wav/rec_orchestra.wav 4 | line)"
  echo "room:      $(ada/obj/codec_main build/wav/rec_room.wav 4 | line)"
} | tee results/multichannel.txt
