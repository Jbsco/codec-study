# Format version 2

This page defines format version 2 completely enough to write a decoder from it. It is frozen: a stream whose version field is 2 decodes as written here. Any change to a field, its width, its order or its meaning takes a new version number, and a reader refuses versions it does not know. Topic pages such as [format.md](format.md) and [container.md](container.md) explain why each part exists. Where they differ from this page, this page applies.

## Conventions

- Fields are read most significant bit first from a running bit position. Bytes are 8 bits.
- Fields are unsigned unless stated. A signed field of width w means v as written when v < 2^(w-1), else v - 2^w.
- v fits w bits when -2^(w-1) <= v < 2^(w-1).
- floor(v / 2^s) rounds toward minus infinity, as an arithmetic right shift does. trunc(v / 2) rounds toward zero.
- unzigzag(u) is u / 2 for even u and -(u + 1) / 2 for odd u.
- sign(v) is 1, 0 or -1.
- CRC-16 is CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, no reflection, no final exclusive or. Its check value for the ASCII bytes `123456789` is 0x29B1.

## Header

| Field | Bits | Rule |
|---|---|---|
| magic | 32 | bytes `42 4C 4B 43`, ASCII `BLKC` |
| version | 8 | 2 |
| flags | 8 | 0, or 1 when every group is a segment; no other value |
| rate | 32 | samples per second, 0 when unknown |
| frames | 64 | frames in the stream |
| channels | 8 | 1 to 8 |
| depth | 8 | integer input: 8, 16, 24 or 32; float input: 32 or 64 |
| valid bits | 8 | 1 to depth; equal to depth for float input |
| float | 8 | 0 integer, 1 float |
| channel mask | 32 | WAV speaker positions, 0 when none |
| audio MD5 | 128 | MD5 of the input samples in FLAC's layout, all zeros when not recorded |
| mode, scale | 8 + 8 per channel | float input only: mode 1 or 2, scale 0 to 31 |
| metadata count | 8 | number of metadata blocks |
| metadata blocks | 32 + 8 per byte each | type in 8 bits, byte length in 24 bits, bytes |
| CRC-16 | 16 | of every header byte before it |

Metadata types:

- 1, tags: each a 16-bit byte length and that many bytes of `key=value` text.
- 2, seek table: each entry a 32-bit first frame and a 64-bit byte offset from the stream's first byte to a group. Its byte length is a multiple of 12.
- 3, source description: the input file's container and chunks, below.
- Other types are skipped by their length.

A reader refuses a stream whose magic, version, field values or header CRC are wrong. Groups start at the byte after the header CRC.

## Signals

Coded depth D is the depth field for integer input and 32 for float input. Channels pair up in order: pair p, for p from 1 to floor(channels / 2), contains channels 2p - 1 and 2p. A last odd channel is coded alone. Each pair has four signals:

- left: channel 2p - 1, D bits.
- right: channel 2p, D bits.
- mid: floor((left + right) / 2), D bits.
- side: left - right, D + 1 bits.

Each block of a pair codes the two signals its stereo mode names:

| Mode | First block | Second block | Channels |
|---|---|---|---|
| 0 | left | right | as coded |
| 1 | left | side | right = left - side |
| 2 | side | right | left = side + right |
| 3 | mid | side | t = 2 mid + (side mod 2); left = (t + side) / 2; right = (t - side) / 2 |

In mode 3, side mod 2 is 0 or 1 for any sign of side, and both divisions are exact.

## Groups

Groups follow the header in order of first frame. Each covers up to 4096 frames.

| Field | Bits | Rule |
|---|---|---|
| sync | 16 | 0xB1C5 |
| length | 24 | bytes from the sync word through the group's last block, at least 13 |
| first frame | 32 | first frame + frames <= the header's frames |
| frames | 16 | 1 to 4096 |
| tree | padded to a byte | below |
| block table | 32 per block | 16-bit byte length and CRC-16 of each block |
| CRC-16 | 16 | of the group from its sync word through its block table |
| blocks | | in table order |

### Tree

A group splits into leaves of 4096, 2048, 1024 or 512 frames: levels 0 to 3. A node at level l covering frames from f has its second half at f + 4096 / 2^(l+1). A node is whole when l = 3 or its second half starts before the group's end. The tree is read in pre-order from the root, node (f, 0):

1. Nodes that are not whole have no bits. Such a node is its first half, node (f, l + 1).
2. Whole nodes above level 3 have a split bit. A 1 makes the node its two halves, read first then second.
3. Otherwise the node is a leaf. It covers from f to the smaller of its end and the group's end, and it has a 2-bit stereo mode for each pair, pair 1 first.

The tree then pads with zero bits to a byte. A group has at most 8 leaves. The block table lists a block per channel per leaf, leaves in tree order and channels in order. Channel c codes its pair mode's first signal when c is odd and in a pair, the second signal when c is even, and itself when c is the odd last channel.

## History

A block of signal s receives the decoded samples of s just before its first frame, up to 16,384 of them, fewer at the stream's start. Mid and side history is computed from the decoded channels. Frames lost to damage count as zero.

## Block

A block codes n samples, 1 to 4096, of a signal of depth d, and ends on a byte boundary. Its byte length must equal its table entry.

- Constant: a `0` bit, then one d-bit signed value, which every sample equals.
- Predicted: a `1` bit, then a 5-bit shift k with k < d, a 3-bit predictor, the predictor's fields and the residuals. Samples y are decoded in width w = d - k, and each must fit w bits. Output samples are y * 2^k. Where a predictor reads history, it reads each history sample h as floor(h / 2^k).

Residual codes, read where a predictor below calls for them:

- `0`, Rice: a 6-bit parameter K <= w + 5. Each value is q zero bits ended by a 1 bit, then K bits b. u = q * 2^K + b must be below 2^(w+5), and the value is unzigzag(u).
- `10`, run-length Huffman, below.
- `11`, adaptive binary code, below.

### Predictors

Predictor 0 to 4 is a polynomial of order m = min(predictor, i) for sample i, and y_i = r_i + prediction:

| m | prediction |
|---|---|
| 0 | 0 |
| 1 | y_(i-1) |
| 2 | 2 y_(i-1) - y_(i-2) |
| 3 | 3 y_(i-1) - 3 y_(i-2) + y_(i-3) |
| 4 | 4 y_(i-1) - 6 y_(i-2) + 4 y_(i-3) - y_(i-4) |

Predictor 5 is a delay: a flag bit, then a distance g. With the flag 0, g is 12 bits and 1 <= g < n. With the flag 1, g is 15 bits and no more than the history length. Then n residuals follow, and y_i = r_i + prediction:

- y_(i-g) when i >= g.
- Otherwise, with the flag 1: the history sample g - i frames before the block's first frame, scaled by k.
- Otherwise 0 for i = 0, and y_(i-1) after.

Predictor 6 is tiers. Tier lengths are L_0 = n and L_(t+1) = ceil(L_t / 2), down to the first L_T <= 2, with T at most 15. n residuals follow. The first L_T are the samples of tier T. Then, for t from T - 1 down to 0, with G = floor(L_t / 2), the next G residuals rebuild tier t from tier t + 1 (values a_j):

- position 2j is a_j, and position 2j + 1 is r + trunc((a_j + a_(j+1)) / 2), with a_j in place of a_(j+1) for j = G - 1.
- when L_t is odd, its last position is a_G.

Predictor 7 is linear prediction:

1. Order o, 5 bits plus 1; precision P, 4 bits plus 1; coefficient shift s, 5 bits. o < n.
2. o coefficients c_1 to c_o, each a P-bit signed field.
3. Stage flag, 1 bit.
4. With the flag 0: o ramp values in a Rice code with its own parameter, y_i = r_i + the polynomial prediction of order min(2, i) for i < o. Then a residual code and n - o residuals, y_i = r_i + floor((sum of c_j y_(i-j)) / 2^s) for i >= o.
5. With the flag 1: a tap count code in 2 bits, for 16, 32, 64 or 256 taps, and a warm-up code in 2 bits, for 0, 256, 1024 or 4096 samples. The history must hold at least warm-up + o samples. Then a residual code and n residuals, and the adaptive stage below rebuilds all n samples, with history samples scaled by k in place of y at negative positions.

### Adaptive stage

The stage keeps taps weights, all starting at 0, and a list of its last taps inputs, newest first, all starting at 0:

- prediction: floor((sum of weight_j input_j) / 2^14).
- update with error e and input v, both first clamped to -2^37 .. 2^37: when e is not 0, each weight_j becomes weight_j + 2 sign(e) sign(input_j), clamped to -2^15 .. 2^15. Then v enters the list, and its oldest input leaves.

Training runs over the last warm-up samples of the scaled history, h_i, oldest first. For each, res = h_i - floor((sum of c_j h_(i-j)) / 2^s), then an update with error res - prediction and input res. Decoding then takes, for each i from 0, res = r_i + prediction and y_i = res + floor((sum of c_j y_(i-j)) / 2^s), and updates with error r_i and input res.

### Run-length Huffman

1. Symbol count M in 11 bits, 1 to 1024.
2. M entries, symbols in increasing order. Each is an Elias gamma step: z zero bits, at most 10, a 1 bit, then z bits b, step = 2^z + b. The first symbol is step - 1, each later one the symbol before plus step, all below 1024. A 5-bit code length follows, 1 to 31.
3. Codes are canonical, as in RFC 1951: shorter codes first, equal lengths in symbol order.

Values start at zero. Symbols are decoded until n values are placed:

- 0: end of block; the remaining values stay zero.
- 960: sixteen zero values.
- Otherwise run = floor(symbol / 64) and size = symbol mod 64, with 1 <= size <= w + 4. Skip run zero values, then read a sign bit and size - 1 bits b. The value is 2^(size-1) + b, negated when the sign bit is 1.

A symbol that would place values past n is an error.

### Adaptive binary code

A 6-bit first parameter K <= w + 5, then a range decoder over the following bits.

Range decoder:

- start: range = 0xFFFFFFFF, code = 0. Five times, code = (code * 256 + next byte) mod 2^32.
- bytes are 8-bit fields read at the current bit position, which need not be on a byte boundary.
- after each bit: while range < 2^24, range = range * 256 and code = (code * 256 + next byte) mod 2^32.
- modeled bit with probability p, in 4096ths of a zero: bound = floor(range / 2^12) * p. When code < bound: range = bound, the bit is 0, p = p + floor((4096 - p) / 32). Otherwise code = code - bound, range = range - bound, the bit is 1, p = p - floor(p / 32).
- direct bit: range = floor(range / 2), the bit is 1 when code >= range, and then code = code - range.

Model: 24 by 9 probabilities, all starting at 2048, indexed by c = min(K, 23) and a position. A running sum S starts at 2^K * 16. For each of n values:

1. Read modeled bits with position min(q, 7), counting q, until a 0 bit. q must stay below 2^(w+5-K).
2. u = q * 2^K. When K > 0, a modeled bit with position 8 is bit K - 1 of u, and K - 1 direct bits follow, most significant first.
3. u must be below 2^(w+5). The value is unzigzag(u).
4. S = S + u - floor(S / 16), and K = min(floor(log2(floor(S / 16) + 1)), w + 5).

## Float samples

For float input, each channel's decoded integers become 32-bit float patterns:

- mode 1: the integer i is the float i / 2^scale.
- mode 2: the integer v is an ordered pattern. The pattern is v when v >= 0, else 2^31 - 1 - v.

A 64-bit float stream contains only samples that are exactly 32-bit floats, and each widens exactly to 64 bits.

## Audio MD5

The digest covers frames in order with channels interleaved. Each integer sample is shifted down by depth - valid bits and written little-endian in ceil(valid bits / 8) bytes. Each float sample is its 32-bit or 64-bit pattern, little-endian. A digest of all zeros means none was recorded.

## Source description

Metadata block 3 lets a decoder write the input file back byte for byte:

- container in 8 bits: 1 RIFF WAV, 2 RF64, 3 BW64, 4 Wave64, 5 AIFF, 6 AIFF-C.
- container size field as the file held it, in 64 bits, then a 16-bit chunk count.
- each chunk in file order: role in 8 bits, identifier length in 8 bits, identifier, its own length field in 64 bits, body length in 32 bits, body.

Roles are 0 any other chunk, 1 format, 2 audio, whose body is what precedes the samples, and 3 RF64's size table. A writer puts the samples into the audio chunk and computes every size field again, except one that held 0, all ones, or for Wave64 2^63 - 1, which it writes back as found. Samples take the container's layout: little-endian for WAV, RF64, BW64 and Wave64, with 8-bit samples offset by 128, and big-endian for AIFF and AIFF-C, except little-endian for AIFF-C `sowt`.

## Damage

A decoder checks the header CRC, each group's CRC and each block's CRC:

- Groups whose sync word, fields or CRC are wrong are skipped. The decoder finds the next offset holding a sync word and a right group, with a first frame at or after the frames already decoded. Frames between count as lost and decode as zero.
- Blocks whose CRC fails are decoded anyway and counted.
- Blocks that break a rule of this page decode as zeros and are counted. A channel sample that a stereo mode rebuilds outside D bits, which only damaged blocks produce, decodes as zero and is counted. Blocks that decode but whose byte length differs from their table entry keep their samples and are counted.
- Streams that end inside a group decode up to their last whole group.

## Conformance

A conforming decoder refuses streams whose header is wrong, decodes every intact group to the samples this page defines, handles damage as above, and reads no byte outside the stream. [vectors/](../vectors/README.md) contains streams for every block kind, residual code, stereo mode, container and kind of damage, with what a decoder writes from each, and `vectors/check.sh <decoder>` compares a decoder with them. The SPARK decoder in `ada/` is proved free of run-time errors for any input bytes, and the Ada, Haskell and hybrid programs write identical streams at every level.
