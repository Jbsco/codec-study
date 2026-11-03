"""Write one WAV file aimed at encoder edge cases, the same for each seed: edge_audio.py <seed> <out.wav>. Integer
or float samples, 1 to 8 channels, odd lengths, extreme values, alternating extremes, constant runs, and for float NaN,
infinities, negative zero and subnormals. Prints the channels, frames and sample kind."""
import random, struct, sys
seed, out = int(sys.argv[1]), sys.argv[2]
r = random.Random(seed)
channels = r.choice([1, 1, 2, 2, 2, 3, 4, 6, 8])
frames = r.choice([1, 2, 31, 32, 33, 511, 4095, 4096, 4097, 9000, r.randint(1, 20000)])
is_float = r.random() < 0.35
depth = 32 if is_float else r.choice([8, 16, 24, 32])
lo, hi = -(1 << (depth - 1)), (1 << (depth - 1)) - 1
def int_value(kind, i, prev):
    if kind == 'extreme': return r.choice([lo, hi, 0, -1, 1])
    if kind == 'alternate': return lo if i % 2 else hi
    if kind == 'walk': return max(lo, min(hi, prev + r.randint(-(1 << (depth - 4)), 1 << (depth - 4))))
    if kind == 'constant': return prev
    return r.randint(lo, hi)
special = [float('nan'), float('inf'), float('-inf'), -0.0, 0.0, 1e-45, -1e-45, 3.4e38, -3.4e38, 1.0, -1.0]
def float_value(kind, i, prev):
    if kind == 'special': return r.choice(special)
    if kind == 'grid': return r.randint(-32768, 32767) / 32768.0
    if kind == 'mixed': return r.choice(special) if r.random() < 0.01 else r.randint(-32768, 32767) / 32768.0
    if kind == 'constant': return prev
    return struct.unpack('<f', struct.pack('<I', r.getrandbits(32)))[0]
data = bytearray()
cols = []
for c in range(channels):
    kinds = ['extreme', 'alternate', 'walk', 'constant', 'random'] if not is_float else ['special', 'grid', 'mixed', 'constant', 'random']
    kind = r.choice(kinds)
    prev = 0 if not is_float else 0.5
    col = []
    for i in range(frames):
        if r.random() < 0.02: kind = r.choice(kinds)
        prev = float_value(kind, i, prev) if is_float else int_value(kind, i, prev)
        col.append(prev)
    cols.append(col)
width = depth // 8
for i in range(frames):
    for c in range(channels):
        v = cols[c][i]
        if is_float: data += struct.pack('<f', v)
        elif depth == 8: data += bytes([v + 128])
        else: data += (v & ((1 << depth) - 1)).to_bytes(width, 'little')
fmt = struct.pack('<IHHIIHH', 16, 3 if is_float else 1, channels, 44100, 44100 * channels * width, channels * width, depth)
open(out, 'wb').write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE' + b'fmt ' + fmt + b'data' + struct.pack('<I', len(data)) + bytes(data))
print(f'{channels} ch, {frames} frames, {"float" if is_float else depth}')
