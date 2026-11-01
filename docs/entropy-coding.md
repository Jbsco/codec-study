# Entropy coding

## Method

Every block ends in one of three codes for its residuals, chosen by exact bit count: a flag of 0 names the Rice code, 10 the run-length code, 11 the adaptive binary code. [format.md](format.md) lists their fields.

- Rice codes: a parameter K in 6 bits, then each residual in zigzag order as its high part in unary and its low K bits. Cost is convex in K, so the encoder starts at the bit length of the mean code value and walks to the minimum. A Rice code is a Golomb code with a power-of-two divisor, and a Golomb code is the optimal prefix code for a geometric distribution. Audio prediction residuals are close to Laplacian, which the geometric shape fits well.
- Run-length Huffman codes, after JPEG's AC coefficient coding (ITU-T T.81, F.1.2.2): each symbol is a run of up to 15 zeros and the next value's bit length, with a symbol for sixteen zeros and one for end of block. Codes are canonical (RFC 1951, 3.2.2), so the table is the symbol list and a 5-bit length per symbol. A value's sign and its bits below the leading one follow the code.
- Adaptive binary code: each zigzag value's quotient by 2^K in unary and its remainder's top bit go through a binary range coder, LZMA's, each bit with a 12-bit probability that moves toward the coded bit by a 32nd of the distance. One probability per context of K and position in the unary part; remaining K - 1 bits cost one bit each. K starts from a 6-bit field and then follows the bit length of a running mean with a window of 16.

The adaptive model restarts at every block, so blocks still decode on their own and in parallel. The encoder runs this code on residuals the search chose and keeps it when shorter than the chosen Rice or run-length code. The decoder reads exactly the bytes the encoder wrote.

## Measured effect

- Silence costs 1.00 bits per sample under any Huffman or Rice code, because a prefix code spends at least one bit per symbol. Constant blocks bring silence to 0.01, and runs of zeros inside a block are what the run-length code is for: the impulse train costs 0.04 bits per sample.
- Rice wins most blocks of the recordings: 611 of 638 blocks of 48 kHz speech at level 4. The run-length code wins sparse ones: 216 of 216 blocks of the square wave, where almost every residual is zero.
- Starting the Rice walk at the mean code value's bit length instead of zero changed no stream and took the first codec's Ada encode from 11.26 s to 9.48 s.
- Code tables cost 0.13 percent of all bits over the corpus, 0.55 percent on generated signals, where the run-length code is chosen most.
- Adaptive binary code, measured before it was built on the prototype's level-4 LPC residuals against a per-block Rice code: an ideal adaptive binary coder was 3.8 percent under Rice, 3.5 percent with the 12-bit shift-by-5 estimator a real coder uses. Adaptive Rice with a running-mean parameter lost 1.2 percent and adaptive Golomb gained nothing, so only the arithmetic coder was built.
- Built, it takes 0.84 percent off the level-4 corpus (42,323,212 to 41,966,578 bytes). The encoder compares it with the shorter of Rice and run-length Huffman, and the Huffman code already wins every block of white noise, dither and float pink noise, where the Rice-only estimate had promised 3 percent.
- Where Rice was the code, the gain holds: pink noise 1.2 percent at every rate, speech at 8 kHz 2.9 percent, recordings 0.3 to 0.8 percent. Periodic signals whose residuals are mostly zeros and ones, which no prefix code can take under one bit, gain 12 to 23 percent: square wave, sweep, chord. Lesson for the measurement step: count against the format's best existing code, not against one of its codes.

## Cost

Rice decoding is a count of leading zeros and a shift per sample. Canonical decoding keeps the first code and the count of each length and no tree. It reads one bit per step, or compares the next 32 bits against the first code of each length in one step. A table of up to 1024 symbols is the largest state a block needs.

The adaptive binary code decodes one range-coder step per unary bit and per modeled remainder bit: a multiply, a compare and a conditional subtraction each, plus a byte shift when the range falls under 2^24, and K - 1 direct bits per value. Its state is 216 probabilities of 12 bits and the running mean. On the 8 kHz speech file the level-4 decode took 0.01 s before and after. The range decoder and reader are in SPARK and proved with the rest of the decoder: 629 checks, 112 of them new.

## Beyond audio

Rice codes fit any residual stream whose values cluster near zero with a geometric tail: sensor deltas, counters, image prediction residuals. CCSDS 121.0-B-3 standardizes exactly this for spacecraft data, with a zero-block option for long runs of zeros. The run-length code fits sparse residuals, where most values are zero and a few are not. Neither fits data whose symbol distribution is far from geometric, such as text or machine code. There a Huffman code over actual symbol frequencies, or an arithmetic coder, is the right tool, and a back-reference stage (LZ77, LZSS) comes first.
