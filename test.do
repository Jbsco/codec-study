#!/bin/bash
# Test gate: the CRC package against its check value and its bitwise form, a written stream's framing and CRCs
# against flipped bits, a seek and a damaged group on one stream, the three implementations against one another
# on a short file at every level, and on a four-channel file. Needs gprbuild and GNAT on the PATH (an Alire
# toolchain), stack, flac and ffmpeg.
exec >&2
cd "$(dirname "$0")" || exit 1
FAIL=0

echo "== 1/4  Build"
(cd ada && gprbuild -q -P huffman_audio.gpr && gprbuild -q -P codec_lib.gpr) || { echo "  Ada build failed"; exit 1; }
(cd haskell && stack build 2>&1 | grep -E "rror" && exit 1; true) || { echo "  Haskell build failed"; exit 1; }
echo "  built"

echo "== 2/4  Checksums, framing, seek, damage"
ada/obj/checksums_test || FAIL=1
mkdir -p build/wav
flac -d -s -f -o build/wav/rec_speech_8k.wav corpus/rec_speech_8k.flac || exit 1
ada/obj/codec_main build/wav/rec_speech_8k.wav 1 --stream build/speech_8k.bin --tag title=speech > /dev/null || exit 1
ada/obj/corrupt_test build/speech_8k.bin || FAIL=1
out=$(ada/obj/codec_main build/wav/rec_speech_8k.wav 1 --independent --seek 100000 --flip 3 2)
if grep -q "samples match" <<< "$out" && grep -q "damage contained" <<< "$out"; then
  echo "  seek from a seek point and a damaged group contained"
else
  echo "  seek or damage containment FAILED"; FAIL=1
fi

echo "== 3/4  Three implementations, every level"
hs=haskell/$(cd haskell && stack path --dist-dir)/build
export LD_LIBRARY_PATH=$PWD/ada/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
for level in 0 1 2 3 4 5; do
  a=$(ada/obj/codec_main build/wav/rec_speech_8k.wav "$level" | grep 'Block codec')
  h=$("$hs/huffman-audio/huffman-audio" build/wav/rec_speech_8k.wav --block "$level" | grep 'Block codec')
  y=$("$hs/huffman-audio-hybrid/huffman-audio-hybrid" build/wav/rec_speech_8k.wav "$level" | grep 'Block codec')
  ok=$(grep -c 'round trip OK' <<< "$a
$h
$y")
  ha=$(grep -oE 'hash [0-9a-f]+' <<< "$a"); hh=$(grep -oE 'hash [0-9a-f]+' <<< "$h"); hy=$(grep -oE 'hash [0-9a-f]+' <<< "$y")
  if [ "$ok" = 3 ] && [ "$ha" = "$hh" ] && [ "$ha" = "$hy" ]; then
    echo "  level $level: three round trips, one stream ($(awk '{print $6}' <<< "$a") bits per sample)"
  else
    echo "  level $level: FAILED (round trips $ok, hashes $ha $hh $hy)"
    FAIL=1
  fi
done

echo "== 4/4  Four channels"
ffmpeg -v error -y -i corpus/rec_orchestra.flac -i corpus/rec_room.flac -filter_complex "[0:a][1:a]amerge=inputs=2" \
  -c:a pcm_s24le build/four_48k.wav || exit 1
a=$(ada/obj/codec_main build/four_48k.wav 1 | grep 'Block codec')
h=$("$hs/huffman-audio/huffman-audio" build/four_48k.wav --block 1 | grep 'Block codec')
y=$("$hs/huffman-audio-hybrid/huffman-audio-hybrid" build/four_48k.wav 1 | grep 'Block codec')
ok=$(grep -c 'round trip OK' <<< "$a
$h
$y")
ha=$(grep -oE 'hash [0-9a-f]+' <<< "$a"); hh=$(grep -oE 'hash [0-9a-f]+' <<< "$h"); hy=$(grep -oE 'hash [0-9a-f]+' <<< "$y")
if [ "$ok" = 3 ] && [ "$ha" = "$hh" ] && [ "$ha" = "$hy" ]; then
  echo "  four channels, level 1: three round trips, one stream ($(awk '{print $6}' <<< "$a") bits per sample)"
else
  echo "  four channels: FAILED (round trips $ok, hashes $ha $hh $hy)"
  FAIL=1
fi

[ "$FAIL" = 0 ] && echo "test: all checks pass"
[ -n "${3:-}" ] && [ "$FAIL" = 0 ] && touch "$3"
exit $FAIL
