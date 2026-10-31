# Decoder cost

## Code size, Cortex-M4 Thumb-2, GNAT 16.1, `-Os`, light runtime

| Unit | Bytes |
|---|---|
| Block decoder, run-time checks on, before the adaptive stage | 6,120 code, 386 read-only data |
| Block decoder, `-gnatp`, the checks the proof makes redundant removed | 4,426 code, 354 read-only data |
| Block encoder, `-gnatp`, plus libgcc's software double precision for the analysis | 6,916 code |

The first codec's decoder, without linear prediction, was 3,370 bytes with checks off. Linear prediction added about 1 KB; the adaptive stage adds its two loops, measured in the current README. The Cortex-M4 has a single-precision FPU, so the encoder's 64-bit floating-point analysis runs in libgcc software routines; the decoder uses no floating point at all.

## Memory

A block decoder holds the residuals, the samples and a second tier buffer, 4096 64-bit words each, about 96 KB at the widest sample type, plus the run-length table of up to 1024 symbols. A decoder that serves blocks with history references or the adaptive stage also keeps the last 16,384 samples of each signal, 16,384 by 33 bits, about 528 Kbit per signal. Blocks that use neither need nothing from earlier blocks and can go to separate decoder lanes, given the lengths at the head of the stream; the Haskell decoder does this, decoding every such block in parallel first and the rest in order.

## Operations per sample

| Block kind | Decoder work per sample |
|---|---|
| Constant | none |
| Polynomial, tiers, delay | a few additions and shifts |
| Linear prediction, order p | p multiply-accumulates: at order 32 and 192 kHz stereo, 12.3 million per second |
| Adaptive stage, t taps | t multiply-accumulates and t weight updates, 256 each at the largest setting |

Rice decoding is a count of leading zeros and a shift. Canonical Huffman decoding compares the next 32 bits against the first code of each length.

## Proof

gnatprove 15.1 at level 2 proves the block decoder, the canonical decoder, the CRC and the bit reader free of run-time errors for any input content, given the preconditions on the buffer bounds and the range of earlier samples: 517 checks, 55 by flow analysis and 462 by the provers, none unproved. The provers bound the sum of 32 products of a 16-bit coefficient and a 33-bit sample, and of 256 products of a 16-bit weight and a 38-bit residual, without help beyond the loop invariants. Malformed input returns `Truncated_Input` or `Bad_Data`; nothing is thrown and nothing is allocated.

## Beyond audio

The accounting above is the one to repeat for any decoder meant for a small core or fabric: bytes of code, words of state, operations per output, and what the proof covers. The parts that transfer unchanged are the bit reader, the canonical decoder, the Rice reader and the CRC, which know nothing of the signal; the prediction and the adaptive stage are the audio-specific part and the only part with multipliers.
