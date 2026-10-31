#!/usr/bin/env bash
# Time the block codec over the corpus in each implementation: Ada and SPARK on one thread, Haskell and
# Haskell + SPARK at several core counts. Prints the total encode and decode seconds and whether every
# stream matches the Ada and SPARK stream byte for byte (by hash).
set -euo pipefail
cd "$(dirname "$0")"
hs=haskell/$(cd haskell && stack path --dist-dir)/build
export LD_LIBRARY_PATH=$PWD/ada/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

total() { awk '/Block codec/ { for (i = 1; i <= NF; i++) { if ($i == "encode") e += $(i + 1); if ($i == "decode") d += $(i + 1) } }
               END { printf "encode %6.2f s, decode %6.2f s", e, d }'; }
hashes() { grep 'Block codec' | grep -oE 'hash [0-9a-f]+'; }
same() { cmp -s <(hashes <<< "$1") <(hashes <<< "$2") && echo ", all 40 streams equal to Ada's" || echo ", STREAMS DIFFER"; }

ada=$(for w in build/wav/*.wav; do ada/obj/codec_main "$w"; done)
echo "Ada and SPARK, 1 thread: $(total <<< "$ada")"
for n in 1 2 4 8 16; do
  pure=$(for w in build/wav/*.wav; do "$hs/huffman-audio/huffman-audio" "$w" --block +RTS -N$n -RTS; done)
  hybrid=$(for w in build/wav/*.wav; do "$hs/huffman-audio-hybrid/huffman-audio-hybrid" "$w" +RTS -N$n -RTS; done)
  echo "Haskell, $n capabilities: $(total <<< "$pure")$(same "$ada" "$pure")"
  echo "Haskell + SPARK, $n capabilities: $(total <<< "$hybrid")$(same "$ada" "$hybrid")"
done
