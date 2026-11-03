#!/usr/bin/env bash
# Write the format version 2 test vectors into vectors/: streams that together use every block kind, residual code,
# stereo mode, depth, float mode, container and metadata block, and damaged copies of one stream. Regression streams
# the fuzzer found stay as found. MANIFEST.tsv lists each stream with the exit status and the MD5 of the file that
# ada/obj/blkc-decode writes from it, and the block kinds codec_main reports for the intact ones. Sources are
# generated signals and short corpus excerpts. Needs the Ada programs built, ffmpeg and python3. The vectors are kept
# as written: rerun this only to add vectors.
set -euo pipefail
cd "$(dirname "$0")/.."
out=vectors
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
enc=ada/obj/blkc-encode
dec=ada/obj/blkc-decode
mkdir -p "$out"
find "$out" -name '*.blkc' ! -name 'regression_*' -delete
manifest=$out/MANIFEST.tsv
printf 'vector\tstatus\tdecoded_md5\tcontent\n' > "$manifest"

# A short excerpt of a corpus file: excerpt <name> <seconds> <ffmpeg output options...>
excerpt() { local name=$1 secs=$2; shift 2; ffmpeg -v error -y -i "corpus/$name" -t "$secs" "$@"; }

# Generated signals, CC0: write_signal <out.wav> <kind> <rate> <frames>
write_signal() {
  python3 -I - "$@" <<'EOF'
import math, random, struct, sys, wave
path, kind, rate, frames = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rng = random.Random(20261102)
if kind == 'constant':
    xs = [0] * 4096 + [1000] * 4096 + [-3] * (frames - 8192)
elif kind == 'period':
    xs = [int(12000 * math.sin(2 * math.pi * i / 100)) for i in range(frames)]
elif kind == 'history':
    pattern = [rng.randint(-8000, 8000) for _ in range(6000)]
    xs = [pattern[i % 6000] for i in range(frames)]
elif kind == 'sparse':
    xs = [(8000 if (i // 50) % 2 else -8000) + (3000 if i % 997 == 0 else 0) for i in range(frames)]
xs = [max(-32768, min(32767, v)) for v in xs[:frames]]
with wave.open(path, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(b''.join(struct.pack('<h', v) for v in xs))
EOF
}

# Code one input: vector <name> <input> <content> <level> <encoder options...>
vector() {
  local name=$1 input=$2 content=$3 level=$4; shift 4
  "$enc" --level "$level" "$@" "$input" "$out/$name.blkc" 2> /dev/null
  "$dec" "$out/$name.blkc" "$work/check.wav" 2> /dev/null
  cmp -s "$input" "$work/check.wav" || { echo "vectors: $name does not decode to its input" >&2; exit 1; }
  local kinds
  kinds=$(ada/obj/codec_main "$input" "$level" "$@" | grep -E 'blocks:|stereo' | tr -s ' ' | tr '\n' ' ' | sed 's/ *$//')
  record "$name" "$content; $kinds"
}

# Decode a written vector and add it to the manifest: record <name> <content>
record() {
  local name=$1 content=$2 status=0
  "$dec" "$out/$name.blkc" "$work/d.wav" 2> /dev/null || status=$?
  local md5=-
  [ -s "$work/d.wav" ] && md5=$(md5sum < "$work/d.wav" | cut -c1-32)
  rm -f "$work/d.wav"
  printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$md5" "$content" >> "$manifest"
}

# Block kinds and residual codes.
write_signal "$work/constant.wav" constant 44100 12000
vector constant "$work/constant.wav" "constant blocks, generated" 0
ffmpeg -v error -y -i corpus/signal_white.flac -i corpus/signal_brown.flac -i corpus/signal_sweep.flac \
  -i corpus/signal_chord.flac -i corpus/signal_fm.flac -filter_complex \
  "[0:a]atrim=end_sample=4096[a];[1:a]atrim=end_sample=4096[b];[2:a]atrim=end_sample=4096[c];[3:a]atrim=end_sample=4096[d];[4:a]atrim=end_sample=4096[e];[a][b][c][d][e]concat=n=5:v=0:a=1" \
  -c:a pcm_s16le "$work/polynomial.wav"
vector polynomial "$work/polynomial.wav" "polynomial orders 0 to 4, a group each from five generated signals" 0
write_signal "$work/period.wav" period 44100 8192
vector delay_in_block "$work/period.wav" "delay within a block, generated" 0
write_signal "$work/history.wav" history 44100 20000
vector delay_in_history "$work/history.wav" "delay into earlier samples, generated" 0
excerpt signal_pink.flac 0.3 "$work/pink.wav"
vector tiers "$work/pink.wav" "tiers, pink noise excerpt" 0
excerpt rec_piano.flac 0.4 "$work/piano.wav"
vector lpc_rice "$work/piano.wav" "linear prediction with Rice codes, piano excerpt" 1
write_signal "$work/sparse.wav" sparse 44100 12000
vector run_length "$work/sparse.wav" "run-length Huffman, generated" 1
excerpt rec_speech.flac 0.4 "$work/speech.wav"
vector adaptive_code "$work/speech.wav" "adaptive binary code, speech excerpt" 2
excerpt rec_piano.flac 1.0 "$work/piano1.wav"
vector adaptive_stage "$work/piano1.wav" "adaptive stage, piano excerpt" 5
excerpt rec_electronic.flac 0.5 "$work/electronic.wav"
vector stereo_modes "$work/electronic.wav" "stereo modes and split blocks, electronic excerpt" 4
excerpt rec_speech_8k.flac 1.5 "$work/speech8k.wav"
vector split_tree "$work/speech8k.wav" "blocks of 512 to 4096 frames, 8 kHz speech excerpt" 4

# Channels, depths and float input.
# Interleave the channels of 16-bit WAV files at one rate: interleave <out.wav> <frames> <in.wav>...
interleave() {
  python3 -I - "$@" <<'EOF2'
import sys, wave
out, frames, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ins = [wave.open(p, 'rb') for p in paths]
rate = ins[0].getframerate()
assert all(w.getsampwidth() == 2 and w.getframerate() == rate for w in ins)
data = [(w.readframes(frames), w.getnchannels()) for w in ins]
assert all(len(d) == 2 * n * frames for d, n in data)
frame = bytearray()
for i in range(frames):
    for d, n in data:
        frame += d[2 * n * i:2 * n * (i + 1)]
with wave.open(out, 'wb') as w:
    w.setnchannels(sum(n for _, n in data)); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frame))
EOF2
}
for f in electronic piano speech; do ffmpeg -v error -y -i "corpus/rec_$f.flac" -t 0.5 -ar 44100 -c:a pcm_s16le "$work/s_$f.wav"; done
ffmpeg -v error -y -i corpus/rec_speech_8k.flac -t 1.5 -ar 44100 -c:a pcm_s16le "$work/s_speech8k.wav"
ffmpeg -v error -y -i corpus/signal_pink.flac -t 0.5 -ac 2 -c:a pcm_s16le "$work/s_pink.wav"
interleave "$work/three.wav" 13230 "$work/s_electronic.wav" "$work/s_speech8k.wav"
vector three_channels "$work/three.wav" "three channels, one coded alone" 2
interleave "$work/eight.wav" 11025 "$work/s_electronic.wav" "$work/s_piano.wav" "$work/s_speech.wav" "$work/s_pink.wav"
vector eight_channels "$work/eight.wav" "eight channels in four pairs" 1
excerpt depth_pink_8.flac 0.3 -c:a pcm_u8 "$work/d8.wav"
vector depth_8 "$work/d8.wav" "8-bit WAV" 1
excerpt depth_pink_24.flac 0.3 -c:a pcm_s24le "$work/d24.wav"
vector depth_24 "$work/d24.wav" "24-bit WAV" 1
excerpt depth_pink_32.flac 0.3 -c:a pcm_s32le "$work/d32.wav"
vector depth_32 "$work/d32.wav" "32-bit WAV" 1
excerpt depth_sine_12in16.flac 0.3 -c:a pcm_s16le "$work/d12.wav"
vector depth_12_in_16 "$work/d12.wav" "12 significant bits in 16-bit samples, shared low bits" 1
excerpt rec_orchestra_f32.wav 0.3 -c:a pcm_f32le "$work/f32.wav"
vector float_integers "$work/f32.wav" "32-bit float of integer samples, float mode 1" 1
excerpt depth_pink_32f.wav 0.3 -c:a pcm_f32le "$work/f32p.wav"
vector float_patterns "$work/f32p.wav" "32-bit float, float mode 2" 1
excerpt depth_pink_32f.wav 0.3 -c:a pcm_f64le "$work/f64.wav"
vector float_64 "$work/f64.wav" "64-bit float of 32-bit values" 1

# Containers and metadata.
excerpt rec_speech_16k.flac 0.4 -rf64 always -c:a pcm_s16le "$work/rf64.wav"
vector rf64 "$work/rf64.wav" "RF64 container" 1
excerpt rec_speech_16k.flac 0.4 -c:a pcm_s16le -f w64 "$work/w64.w64"
vector wave64 "$work/w64.w64" "Wave64 container" 1
excerpt rec_speech_16k.flac 0.4 -c:a pcm_s16be -f aiff "$work/aiff.aiff"
vector aiff "$work/aiff.aiff" "AIFF container" 1
excerpt rec_speech_16k.flac 0.4 -c:a pcm_s16le -f aiff "$work/sowt.aifc"
vector aifc_sowt "$work/sowt.aifc" "AIFF-C sowt, little-endian samples" 1
excerpt depth_pink_32f.wav 0.3 -c:a pcm_f32be -f aiff "$work/fl32.aifc"
vector aifc_fl32 "$work/fl32.aifc" "AIFF-C fl32" 1
excerpt rec_speech_16k.flac 0.4 -c:a pcm_s16le -f wav - > "$work/piped.wav"
vector piped_wav "$work/piped.wav" "WAV written to a pipe, unknown sizes" 1
vector tags_seek_table "$work/speech8k.wav" "tags and a seek point every second" 1 --tag title=vector \
  --tag artist=codec --seek-every 1
vector independent "$work/speech8k.wav" "every group a segment, no seek table" 1 --independent --seek-every 0
vector single_channel_pairs "$work/electronic.wav" "stereo with every channel coded alone" 1 --no-pairs

# Damaged copies of split_tree, the 8 kHz speech excerpt: three groups at level 4.
damage() {
  python3 -I - "$out/split_tree.blkc" "$out/$1.blkc" "$2" <<'EOF'
import sys
src, dst, how = sys.argv[1], sys.argv[2], sys.argv[3]
b = bytearray(open(src, 'rb').read())
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
header_end = pos + 2
groups, g = [], header_end
while g + 13 <= len(b):
    groups.append(g)
    g += int.from_bytes(b[g + 2:g + 5], 'big')
assert len(groups) >= 3, groups
if how == 'header_crc':
    b[10] ^= 0x01
elif how == 'audio_md5':
    b[26] ^= 0x01
    b[pos:pos + 2] = crc16(b[:pos]).to_bytes(2, 'big')
elif how == 'group_sync':
    b[groups[1]] ^= 0xFF
elif how == 'group_length':
    b[groups[1] + 3] ^= 0x10
elif how == 'block_table':
    b[groups[1] + 12] ^= 0x01
elif how == 'block_bit':
    b[groups[2] - 40] ^= 0x04
elif how == 'truncated':
    b = b[:groups[2] + 100]
elif how == 'garbage':
    junk = bytes([0xB1, 0xC5, 0x00, 0x00, 0x20, 0x00, 0x00, 0x10, 0x00]) * 4 + bytes(range(7))
    b = b[:groups[1]] + junk + b[groups[1]:]
open(dst, 'wb').write(b)
EOF
  record "$1" "$3"
}
damage damaged_header_crc header_crc "header field changed, header CRC fails: refused"
damage damaged_audio_md5 audio_md5 "recorded audio MD5 changed, header CRC recomputed: audio reported as different"
damage damaged_group_sync group_sync "second group's sync word broken: group lost, frames written as zeros"
damage damaged_group_length group_length "second group's length changed: group CRC fails, group lost"
damage damaged_block_table block_table "second group's block table changed: group CRC fails, group lost"
damage damaged_block_bit block_bit "bit flipped in the second group's last block: block CRC fails, decoded anyway"
damage damaged_truncated truncated "stream cut inside the third group: decoded to the last whole group"
damage damaged_garbage garbage "false sync words between the first and second groups: next group found again"
head -c 3000 "$work/speech8k.wav" > "$out/not_a_stream.blkc"
record not_a_stream "WAV bytes, not a stream: refused"

# Streams the fuzzer found, kept as found.
record regression_out_of_depth "found by fuzzing: damaged blocks rebuild a channel outside its depth, zeroed and counted"
record regression_resync_first_frame "found by fuzzing: after a damaged group, the next good group starts at frame 0"
echo "vectors: $(($(wc -l < "$manifest") - 1)) written to $out" >&2
