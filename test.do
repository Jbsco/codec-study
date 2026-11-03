#!/bin/bash
# Test gate: the CRC package against its check value and its bitwise form, the float conversions on every 32-bit
# pattern, a written stream's framing and CRCs against flipped bits, a seek and a damaged group on one stream, the
# stream decoder on whole, truncated and foreign files, the release programs against the checked ones, the audio MD5
# against FLAC's and against a changed digest, RF64, Wave64, AIFF and 64-bit float input, the three implementations
# against one another on a short file at every level, on a four-channel file, the test vectors, changed copies of
# them through the fuzzer, the C interface, and the release package. Needs gprbuild and GNAT on the PATH (an Alire toolchain), stack, flac
# with metaflac, ffmpeg, python3, a C compiler and nm.
exec >&2
cd "$(dirname "$0")" || exit 1
FAIL=0

echo "== 1/10  Build"
(cd ada && gprbuild -q -P huffman_audio.gpr && gprbuild -q -P codec_lib.gpr) || { echo "  Ada build failed"; exit 1; }
(cd ada && gprbuild -q -P huffman_audio.gpr -XBUILD=release stream_encode stream_decode) \
  || { echo "  Ada release build failed"; exit 1; }
(cd haskell && stack build 2>&1 | grep -E "rror" && exit 1; true) || { echo "  Haskell build failed"; exit 1; }
echo "  built"

echo "== 2/10  Checksums, framing, seek, damage"
ada/obj/checksums_test || FAIL=1
ada/obj/float_bits_test || FAIL=1
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

echo "== 3/10  Stream decoder"
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
ada/obj/stream_encode --level 1 --tag title=speech build/wav/rec_speech_8k.wav build/speech_8k_tool.bin 2> /dev/null
cmp -s build/speech_8k.bin build/speech_8k_tool.bin && echo "  stream_encode writes codec_main's stream" \
  || { echo "  stream_encode: FAILED"; FAIL=1; }
# The release programs, built without run-time checks, write the same stream and the same file, and --verify passes.
ada/obj-release/stream_encode --level 4 --verify build/wav/rec_speech_8k.wav build/speech_8k_release.bin 2> /dev/null \
  && ada/obj/stream_encode --level 4 build/wav/rec_speech_8k.wav build/speech_8k_checked.bin 2> /dev/null \
  && cmp -s build/speech_8k_release.bin build/speech_8k_checked.bin \
  && ada/obj-release/stream_decode build/speech_8k_release.bin build/speech_8k_release.wav 2> /dev/null \
  && cmp -s build/wav/rec_speech_8k.wav build/speech_8k_release.wav \
  && echo "  release programs: same stream, verified, byte-identical file" \
  || { echo "  release programs: FAILED"; FAIL=1; }
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

echo "== 4/10  Input containers"
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
# 64-bit float made from 32-bit float comes back byte for byte in WAV and AIFF-C; a 64-bit file with more precision
# than a 32-bit float carries is refused.
ffmpeg -v error -y -i corpus/depth_pink_32f.wav -c:a pcm_f64le build/pink_64f.wav || exit 1
ffmpeg -v error -y -i corpus/depth_pink_32f.wav -c:a pcm_f64be -f aiff build/pink_64f.aifc || exit 1
for file in build/pink_64f.wav build/pink_64f.aifc; do
  name=$(basename "$file")
  if ada/obj/codec_main "$file" 0 --stream build/float64.bin | grep -q 'round trip OK' \
     && ada/obj/stream_decode build/float64.bin "build/back_$name" 2> /dev/null && cmp -s "$file" "build/back_$name"; then
    echo "  $name: 64-bit float, byte-identical after decoding"
  else
    echo "  $name: FAILED"; FAIL=1
  fi
done
python3 -I - build/double_sine.wav <<'EOF'
import math, struct, sys
n = 1000
data = b''.join(struct.pack('<d', math.sin(i / 7) / 3) for i in range(n))
fmt = struct.pack('<HHIIHH', 3, 1, 48000, 48000 * 8, 8, 64)
body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
open(sys.argv[1], 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
EOF
if ada/obj/codec_main build/double_sine.wav 0 2>&1 | grep -q 'not exactly 32-bit float'; then
  echo "  64-bit float beyond 32-bit precision: refused"
else
  echo "  64-bit float beyond 32-bit precision: not refused"; FAIL=1
fi
stream_hash() { ada/obj/codec_main "$1" 0 | grep -oE 'round trip OK, hash [0-9a-f]+'; }
hs=haskell/$(cd haskell && stack path --dist-dir)/build
h=$("$hs/huffman-audio/huffman-audio" build/pink_64f.aifc --block 0 | grep -oE 'round trip OK, hash [0-9a-f]+')
[ "$h" = "$(stream_hash build/pink_64f.aifc)" ] && echo "  Haskell reads 64-bit float AIFF-C as Ada does" || { echo "  Haskell 64-bit float: FAILED"; FAIL=1; }
h=$("$hs/huffman-audio/huffman-audio" build/speech_8k.aiff --block 0 | grep -oE 'round trip OK, hash [0-9a-f]+')
[ "$h" = "$(stream_hash build/speech_8k.aiff)" ] && echo "  Haskell reads AIFF as Ada does" || { echo "  Haskell AIFF: FAILED"; FAIL=1; }

echo "== 5/10  Three implementations, every level"
export LD_LIBRARY_PATH=$PWD/ada/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# Float samples that are integers over a power of two, but for a negative zero and a NaN in the second channel: one
# channel codes as integers, the other as bit patterns, and the adaptive code's trials meet residuals far above their
# parameter.
python3 -I - build/float_edges.wav <<'EOF'
import struct, sys
values = [((i * 37) % 65536 - 32768) / 32768.0 for i in range(24000)]
values[11] = -0.0
values[21] = float('nan')
data = b''.join(struct.pack('<f', v) for v in values)
fmt = struct.pack('<IHHIIHH', 16, 3, 2, 48000, 384000, 8, 32)
open(sys.argv[1], 'wb').write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE' + b'fmt ' + fmt + b'data'
                              + struct.pack('<I', len(data)) + data)
EOF
a=$(ada/obj/codec_main build/float_edges.wav 2 | grep -oE 'round trip OK, hash [0-9a-f]+')
h=$("$hs/huffman-audio/huffman-audio" build/float_edges.wav --block 2 | grep -oE 'round trip OK, hash [0-9a-f]+')
y=$("$hs/huffman-audio-hybrid/huffman-audio-hybrid" build/float_edges.wav 2 | grep -oE 'round trip OK, hash [0-9a-f]+')
if [ -n "$a" ] && [ "$a" = "$h" ] && [ "$a" = "$y" ]; then
  echo "  float with negative zero and NaN: three round trips, one stream"
else
  echo "  float with negative zero and NaN: FAILED ($a / $h / $y)"; FAIL=1
fi
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

echo "== 6/10  Four channels"
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
  ada/obj/stream_encode --level 1 - - < build/four_48k.wav 2> /dev/null | ada/obj/stream_decode - - 2> /dev/null > build/four_piped.wav
  cmp -s build/four_48k.wav build/four_piped.wav && echo "  through pipes: four channels byte-identical" \
    || { echo "  through pipes: FAILED"; FAIL=1; }
  ada/obj/stream_encode --level 2 --threads 1 build/four_48k.wav build/four_t1.bin 2> /dev/null
  ada/obj/stream_encode --level 2 --threads 3 build/four_48k.wav build/four_t3.bin 2> /dev/null
  cmp -s build/four_t1.bin build/four_t3.bin && echo "  one thread and three: same stream" \
    || { echo "  one thread and three: FAILED"; FAIL=1; }
else
  echo "  four channels: FAILED (round trips $ok, hashes $ha $hh $hy)"
  FAIL=1
fi

echo "== 7/10  Test vectors"
vectors/check.sh ada/obj/stream_decode || FAIL=1
vectors/check.sh ada/obj-release/stream_decode > /dev/null || { echo "  test vectors: release decoder FAILED"; FAIL=1; }

echo "== 8/10  Fuzzing"
# Changed copies of every vector through the decoder with checks on; a failing stream is kept as build/fuzz_failure.blkc.
(cd build && ../ada/obj/fuzz_decode 2000 1 ../vectors/*.blkc | sed 's/^/  /') || FAIL=1

echo "== 9/10  C interface"
capi/check.sh || FAIL=1

echo "== 10/10  Release package"
# The package release.sh writes: its files, and programs that report the version git describe gives.
rm -rf build/dist
tarball=$(bash release.sh build/dist 2> /dev/null | tail -1)
version=$(git describe --tags --match 'v*' --abbrev=8 --always --dirty)
mkdir -p build/dist/unpacked && tar -xzf "$tarball" -C build/dist/unpacked
root=$(echo build/dist/unpacked/*)
if [ -x "$root/bin/stream_encode" ] && [ -f "$root/lib/libblockcodec.so" ] && [ -f "$root/include/blockcodec.h" ] \
   && [ -f "$root/share/doc/codec-study/spec.md" ] && (cd build/dist && sha256sum -c --quiet ./*.sha256) \
   && "$root/bin/stream_decode" --version | grep -q "^stream_decode $version, format version 2, C API version 1$"; then
  echo "  release package: programs, library, header and documents, version $version"
else
  echo "  release package: FAILED"; FAIL=1
fi

[ "$FAIL" = 0 ] && echo "test: all checks pass"
[ -n "${3:-}" ] && [ "$FAIL" = 0 ] && touch "$3"
exit $FAIL
