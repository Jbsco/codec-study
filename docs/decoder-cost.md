# Decoder cost

## Code size

Cortex-M4 Thumb-2, GNAT 16.1, `-Os`, light runtime:

| Unit | Bytes |
|---|---|
| Block decoder with adaptive stage, CRC and adaptive binary code, run-time checks on | 10,048 code |
| Same, `-gnatp`, checks the proof makes redundant removed | 7,668 code |
| Block decoder before the adaptive binary code, `-gnatp` | 6,316 code (8,396 with checks on) |
| Block decoder before the adaptive stage and CRC, `-gnatp` | 4,426 code, 354 read-only data |
| Block encoder with the adaptive binary code, `-gnatp`, plus libgcc's software double precision for analysis | 11,328 code |

The first codec's decoder, without linear prediction, was 3,370 bytes with checks off. Linear prediction added about 1.1 KB, the adaptive stage and CRC together about 1.6 KB, and the adaptive binary code 1.35 KB: range decoder, reader and logarithm.

Rows are sums of decoder function sections of the five units (`-ffunction-sections`), built with GNAT 16.1 for `arm-eabi` and the `light-cortex-m4` runtime. The Cortex-M4 has a single-precision FPU, so the encoder's 64-bit floating-point analysis runs in libgcc software routines. The decoder uses no floating point at all.

## Memory

A block decoder keeps residuals, samples and a second tier buffer, 4096 64-bit words each, about 96 KB at the widest sample type, plus a run-length table of up to 1024 symbols. A decoder that serves blocks with history references or the adaptive stage also keeps the last 16,384 samples of each signal, 16,384 by 33 bits, about 528 Kbit per signal.

Blocks that use neither need nothing from earlier blocks and can go to separate decoder lanes, given the lengths in each group's table. The Haskell decoder does this: every such block in parallel first, the rest in order.

## Operations per sample

| Block kind | Decoder work per sample |
|---|---|
| Constant | none |
| Polynomial, tiers, delay | a few additions and shifts |
| Linear prediction, order p | p multiply-accumulates: at order 32 and 192 kHz stereo, 12.3 million per second |
| Adaptive stage, t taps | t multiply-accumulates and t weight updates, 256 each at the largest setting |

Rice decoding is a count of leading zeros and a shift. Canonical Huffman decoding compares the next 32 bits against the first code of each length.

## Proof

gnatprove 15.1 at level 2 proves the block decoder, canonical decoder, CRC, range decoder and bit reader free of run-time errors for any input content, given preconditions on buffer bounds and the range of earlier samples. 629 checks: 73 by flow analysis (55 initializations, 18 terminations) and 556 by the provers (425 run-time checks, 51 assertions, 79 contracts, 1 termination), none unproved.

The provers bound the sum of 32 products of a 16-bit coefficient and a 33-bit sample, and of 256 products of a 16-bit weight and a 38-bit residual, without help beyond loop invariants. Malformed input returns `Truncated_Input` or `Bad_Data`; nothing is thrown and nothing is allocated.

## Beyond audio

This accounting is the one to repeat for any decoder meant for a small core or fabric: bytes of code, words of state, operations per output, and what the proof covers. Parts that transfer unchanged are the bit reader, canonical decoder, Rice reader and CRC, which know nothing of the signal. Prediction and the adaptive stage are the audio-specific part and the only part with multipliers.
