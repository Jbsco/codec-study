#!/usr/bin/env bash
# Decode the corpus to build/wav, build both implementations, and run every coder on every file.
# Needs flac, GNAT with gprbuild on the PATH, and stack.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/wav results
for f in corpus/*.flac; do flac -d -s -f -o "build/wav/$(basename "${f%.flac}").wav" "$f"; done
cp corpus/*.wav build/wav/

(cd ada && gprbuild -q -P huffman_audio.gpr)
(cd haskell && stack build)
hs="haskell/$(cd haskell && stack path --dist-dir)/build/huffman-audio/huffman-audio"

: > results/ada.txt
: > results/haskell.txt
for w in build/wav/*.wav; do
  ada/obj/audio_huffman "$w" >> results/ada.txt
  "$hs" "$w" >> results/haskell.txt
done
grep -c 'round trip OK' results/ada.txt results/haskell.txt
! grep -h 'FAILED' results/ada.txt results/haskell.txt
