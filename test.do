#!/bin/bash
# Test gate: the CRC package against its check value and its bitwise form, a written stream's framing and CRCs against
# flipped bits, a seek and a damaged group on one stream, the stream decoder on whole, truncated and foreign files,
# the audio MD5 against FLAC's and against a changed digest, RF64, Wave64 and AIFF input, the three implementations
# against one another on a short file at every level, and on a four-channel file. Needs gprbuild and GNAT on the PATH
# (an Alire toolchain), stack, flac with metaflac, ffmpeg and python3.
exec >&2
cd "$(dirname "$0")" || exit 1
FAIL=0

echo "== 1/6  Build"
(cd ada && gprbuild -q -P huffman_audio.gpr && gprbuild -q -P codec_lib.gpr) || { echo "  Ada build failed"; exit 1; }
(cd haskell && stack build 2>&1 | grep -E "rror" && exit 1; true) || { echo "  Haskell build failed"; exit 1; }
echo "  built"

echo "== 2/6  Checksums, framing, seek, damage"
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

echo "== 3/6  Stream decoder"
# The decoder writes the source file back, container and chunks included, byte for byte.
ada/obj/codec_main corpus/depth_pink_32f.wav 1 --stream build/pink_32f.bin > /dev/null || exit 1
for s in speech_8k:build/wav/rec_speech_8k.wav pink_32f:corpus/depth_pink_32f.wav; do
  name=${s%%:*}; wav=${s#*:}
  if ada/obj/stream_decode "build/$name.bin" "build/${name}_decoded.wav" 2>&1 | grep -q "audio MD5 matches" \
     && cmp -s "$wav" "build/${name}_decoded.wav"; then
    echo "  $name: decoded from the stream alone, byte-identical file, audio MD5 checked"
  else
    echo "  $name: stream_decode FAILED"; FAIL=1
  fi
done
ours=$(ada/obj/codec_main build/wav/rec_speech_8k.wav 0 | grep -oE 'audio MD5 [0-9a-f]+' | awk '{print $3}')
[ "$ours" = "$(metaflac --show-md5sum corpus/rec_speech_8k.flac)" ] && echo "  audio MD5 equal to FLAC's" \
  || { echo "  audio MD5 differs from FLAC's"; FAIL=1; }
# One byte of the recorded MD5 changed and the header CRC recomputed: the decoder must report the audio as wrong.
python3 -I - build/speech_8k.bin build/wrong_md5.bin <<'EOF'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
def crc16(data):
    r = 0xFFFF
    for x in data:
        r ^= x << 8
        for _ in range(8):
            r = ((r << 1) ^ 0x1021 if r & 0x8000 else r << 1) & 0xFFFF
    return r
pos = 42 + (2 * b[18] if b[21] == 1 else 0)
count, pos = b[pos], pos + 1
for _ in range(count):
    pos += 4 + int.from_bytes(b[pos + 1:pos + 4], 'big')
b[26] ^= 1
b[pos:pos + 2] = crc16(b[:pos]).to_bytes(2, 'big')
open(sys.argv[2], 'wb').write(b)
EOF
out=$(ada/obj/stream_decode build/wrong_md5.bin build/wrong_md5.wav 2>&1); st=$?
[ $st = 1 ] && grep -q "AUDIO MD5 DIFFERS" <<< "$out" && echo "  changed audio MD5: reported" \
  || { echo "  changed audio MD5: not reported"; FAIL=1; }
head -c 60000 build/speech_8k.bin > build/truncated.bin
ada/obj/stream_decode build/truncated.bin build/truncated.wav 2> /dev/null
[ $? = 1 ] && echo "  truncated stream: damage status" || { echo "  truncated stream: wrong status"; FAIL=1; }
head -c 3000 build/wav/rec_speech_8k.wav > build/not_a_stream.bin
ada/obj/stream_decode build/not_a_stream.bin build/not_a_stream.wav 2> /dev/null
[ $? = 2 ] && echo "  foreign file: refused" || { echo "  foreign file: wrong status"; FAIL=1; }

echo "== 4/6  Input containers"
# The same samples in RF64, Wave64, AIFF and AIFF-C, and in a WAV written to a pipe with its sizes unknown, give their
# WAV's audio MD5, and each file comes back from its stream byte for byte, container and chunks included; the Haskell reader agrees with the Ada reader on AIFF.
ffmpeg -v error -y -i build/wav/rec_speech_8k.wav -c:a pcm_u8 -rf64 always build/speech_8k_rf64.wav || exit 1
ffmpeg -v error -y -i build/wav/rec_speech_8k.wav -c:a pcm_u8 build/speech_8k.w64 || exit 1
ffmpeg -v error -y -i build/wav/rec_speech_8k.wav -c:a pcm_s8 build/speech_8k.aiff || exit 1
flac -d -s -f -o build/wav/rec_speech_16k.wav corpus/rec_speech_16k.flac || exit 1
ffmpeg -v error -y -i build/wav/rec_speech_16k.wav -c:a pcm_s16le -f aiff build/speech_16k_sowt.aifc || exit 1
ffmpeg -v error -y -i corpus/depth_pink_32f.wav -c:a pcm_f32be -f aiff build/pink_32f.aifc || exit 1
ffmpeg -v error -i build/wav/rec_speech_8k.wav -c:a pcm_u8 -f wav - | cat > build/speech_8k_piped.wav || exit 1
audio_md5() { ada/obj/codec_main "$1" 0 --stream "$2" | grep -oE 'audio MD5 [0-9a-f]+'; }
for s in build/wav/rec_speech_8k.wav:build/speech_8k_rf64.wav build/wav/rec_speech_8k.wav:build/speech_8k.w64 \
         build/wav/rec_speech_8k.wav:build/speech_8k.aiff build/wav/rec_speech_16k.wav:build/speech_16k_sowt.aifc \
         corpus/depth_pink_32f.wav:build/pink_32f.aifc build/wav/rec_speech_8k.wav:build/speech_8k_piped.wav; do
  wav=${s%%:*}; file=${s#*:}; name=$(basename "$file")
  a=$(audio_md5 "$wav" build/source.bin); b=$(audio_md5 "$file" build/container.bin)
  if [ -n "$a" ] && [ "$a" = "$b" ] && ada/obj/stream_decode build/container.bin "build/back_$name" 2> /dev/null \
     && cmp -s "$file" "build/back_$name"; then
    echo "  $name: WAV's audio MD5, byte-identical after decoding"
  else
    echo "  $name: FAILED"; FAIL=1
  fi
done
stream_hash() { ada/obj/codec_main "$1" 0 | grep -oE 'round trip OK, hash [0-9a-f]+'; }
hs=haskell/$(cd haskell && stack path --dist-dir)/build
h=$("$hs/huffman-audio/huffman-audio" build/speech_8k.aiff --block 0 | grep -oE 'round trip OK, hash [0-9a-f]+')
[ "$h" = "$(stream_hash build/speech_8k.aiff)" ] && echo "  Haskell reads AIFF as Ada does" || { echo "  Haskell AIFF: FAILED"; FAIL=1; }

echo "== 5/6  Three implementations, every level"
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

echo "== 6/6  Four channels"
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
  ada/obj/codec_main build/four_48k.wav 1 --stream build/four_48k.bin > /dev/null
  if ada/obj/stream_decode build/four_48k.bin build/four_decoded.wav 2> /dev/null && cmp -s build/four_48k.wav build/four_decoded.wav; then
    echo "  four channels: decoded from the stream alone, byte-identical file"
  else
    echo "  four channels: stream_decode FAILED"; FAIL=1
  fi
else
  echo "  four channels: FAILED (round trips $ok, hashes $ha $hh $hy)"
  FAIL=1
fi

[ "$FAIL" = 0 ] && echo "test: all checks pass"
[ -n "${3:-}" ] && [ "$FAIL" = 0 ] && touch "$3"
exit $FAIL
