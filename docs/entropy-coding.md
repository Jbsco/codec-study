# Entropy coding

## Method

Every block ends in one of two codes for its residuals, chosen by exact bit count.

- Rice codes: a parameter K in 6 bits, then each residual in zigzag order as its high part in unary and its low K bits. The cost is convex in K, so the encoder starts at the bit length of the mean code value and walks to the minimum. A Rice code is a Golomb code with a power-of-two divisor, and a Golomb code is the optimal prefix code for a geometric distribution; prediction residuals of audio are close to Laplacian, which the geometric shape fits well.
- Run-length Huffman codes, after the AC coefficient coding of JPEG (ITU-T T.81, F.1.2.2): each symbol is a run of up to 15 zeros and the bit length of the next value, with a symbol for sixteen zeros and a symbol for the end of the block. The code is canonical (RFC 1951, 3.2.2), so the table is the symbol list and a 5-bit length per symbol. The value's sign and its bits below the leading one follow the code.

## Measured effect

- A prefix code spends at least one bit per symbol, so silence costs 1.00 bits per sample under any Huffman or Rice code. The constant-block kind brings silence to 0.01, and runs of zeros inside a block are what the run-length code is for: the impulse train costs 0.04 bits per sample.
- On the recordings, Rice wins most blocks: 611 of 638 blocks of 48 kHz speech at level 4. The run-length code wins the sparse ones: 216 of 216 blocks of the square wave, where almost every residual is zero.
- Starting the Rice walk at the mean code value's bit length instead of zero changed no stream and took the first codec's Ada encode from 11.26 s to 9.48 s.
- The code tables cost 0.13 percent of all bits over the corpus, 0.55 percent on the generated signals, where the run-length code is chosen most.

## Cost

Rice decoding is a count of leading zeros and a shift per sample. Canonical decoding keeps the first code and the count of each length and no tree; it reads one bit per step, or compares the next 32 bits against the first code of each length in one step. The table of up to 1024 symbols is the largest state a block needs.

## Beyond audio

Rice codes fit any residual stream whose values cluster near zero with a geometric tail: sensor deltas, counters, image prediction residuals. CCSDS 121.0-B-3 standardizes exactly this for spacecraft data, with a zero-block option for long runs of zeros. The run-length code fits sparse residuals, where most values are zero and a few are not. Neither fits data whose symbol distribution is far from geometric, such as text or machine code; there a Huffman code over the actual symbol frequencies, or an arithmetic coder, is the right tool, and a back-reference stage (LZ77, LZSS) comes first.
