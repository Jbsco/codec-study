#!/usr/bin/env bash
# Decode the corpus to build/wav, build every implementation, and run every coder on every file.
# Needs flac, GNAT with gprbuild on the PATH, and stack.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/wav results
for f in corpus/*.flac; do flac -d -s -f -o "build/wav/$(basename "${f%.flac}").wav" "$f"; done
cp corpus/*.wav build/wav/

(cd ada && gprbuild -q -P huffman_audio.gpr && gprbuild -q -P codec_lib.gpr)
(cd haskell && stack build)
hs="haskell/$(cd haskell && stack path --dist-dir)/build"
export LD_LIBRARY_PATH=$PWD/ada/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

: > results/ada.txt
: > results/codec_ada.txt
: > results/haskell.txt
: > results/codec_hybrid.txt
for w in build/wav/*.wav; do
  ada/obj/audio_huffman "$w" >> results/ada.txt
  ada/obj/codec_main "$w" >> results/codec_ada.txt
  "$hs/huffman-audio/huffman-audio" "$w" >> results/haskell.txt
  "$hs/huffman-audio-hybrid/huffman-audio-hybrid" "$w" >> results/codec_hybrid.txt
done
ada/obj/checksums_test
ada/obj/codec_main build/wav/rec_speech_8k.wav 1 --stream build/speech_8k.bin > /dev/null
ada/obj/corrupt_test build/speech_8k.bin 40
grep -c 'round trip OK' results/ada.txt results/codec_ada.txt results/haskell.txt results/codec_hybrid.txt
! grep -h 'FAILED' results/ada.txt results/codec_ada.txt results/haskell.txt results/codec_hybrid.txt
