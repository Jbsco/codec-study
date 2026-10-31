#!/bin/bash
# Test gate: the CRC package against its check value and its bitwise form, a written stream's CRCs against
# flipped bits, and the three implementations against one another on a short file at every level. Needs
# gprbuild and GNAT on the PATH (an Alire toolchain), stack, and flac to decode the corpus file.
exec >&2
cd "$(dirname "$0")" || exit 1
FAIL=0

echo "== 1/3  Build"
(cd ada && gprbuild -q -P huffman_audio.gpr && gprbuild -q -P codec_lib.gpr) || { echo "  Ada build failed"; exit 1; }
(cd haskell && stack build 2>&1 | grep -E "rror" && exit 1; true) || { echo "  Haskell build failed"; exit 1; }
echo "  built"

echo "== 2/3  Checksums"
ada/obj/checksums_test || FAIL=1
mkdir -p build/wav
flac -d -s -f -o build/wav/rec_speech_8k.wav corpus/rec_speech_8k.flac || exit 1
ada/obj/codec_main build/wav/rec_speech_8k.wav 1 --stream build/speech_8k.bin > /dev/null || exit 1
ada/obj/corrupt_test build/speech_8k.bin 40 || FAIL=1

echo "== 3/3  Three implementations, every level"
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

[ "$FAIL" = 0 ] && echo "test: all checks pass"
[ -n "${3:-}" ] && [ "$FAIL" = 0 ] && touch "$3"
exit $FAIL
