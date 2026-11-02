# Block format

Every field of a block, as the three implementations write it. Fields are most significant bit first, and each block ends on a byte boundary. Stream layout around the blocks, header, groups, split trees and stereo modes, is in [container.md](container.md); CRCs are in [integrity.md](integrity.md); float input is in [float.md](float.md).

## Layout

A block codes 1 to 4096 samples of one signal.

- `0`, then one value in the sample width: a constant block.
- `1`, then 5 bits of shared low bits, 3 bits naming the predictor, the predictor's fields, a flag naming the residual code, and the residuals.

Shared low bits are low bits equal in every sample of the block. They are removed before prediction and put back after decoding.

## Predictors

- 0 to 4: polynomial order; first samples of the block use lower orders.
- 5: delay. A `0` and a 12-bit distance to the first exact repeat of its first 32 samples within the block, where samples before that distance are coded as first differences. Or a `1` and a 15-bit distance back into the 16,384 samples before the block, scaled down by the shared low bits. Only the second kind needs earlier samples to decode.
- 6: tiers of pairs. Final tier first, then each tier's offsets from coarse to fine. Each pair's second sample is its offset from the mean of first samples of its pair and the next.
- 7: linear prediction. Order less one in 5 bits, coefficient precision less one in 4 bits, coefficient shift in 5 bits, coefficients in two's complement, then a flag.

With the flag clear, the first samples, as many as its order, are second differences in their own Rice code. Each later sample is predicted as the sum of coefficient times earlier sample, shifted right by that shift. With the flag set, an adaptive stage follows, and the block needs earlier samples to decode.

## Adaptive stage

A tap count code in 2 bits (16, 32, 64 or 256 taps) and a warm-up code in 2 bits (0, 256, 1024 or 4096 samples). Every sample of the block is predicted by the coefficients, across the block's start, from samples before it.

A sign-sign LMS filter over those residuals predicts each residual from the last taps residuals: 16-bit weights move by 2 toward the error's sign times each input's sign, and the prediction is shifted right by 14. The filter is trained first on residuals of warm-up samples before the block, with the block's own coefficients.

## Residual codes

A flag names the code: `0` Rice, `10` run-length Huffman, `11` adaptive binary code.

- Rice: a 6-bit parameter K, then each zigzag value shifted right by K in unary and its low K bits.
- Run-length Huffman, after JPEG's AC coefficient symbols: each symbol is a run of up to 15 zeros and the next value's bit length, with one symbol for sixteen zeros and one for end of block. Its table is a symbol count in 11 bits, then each symbol as an Elias gamma code of its step from the one before, with its code length in 5 bits. Codes are canonical, as in RFC 1951. A value's code is followed by its sign and the bits below its leading one.
- Adaptive binary code: a 6-bit first parameter K, then range coder bytes, below.

### Adaptive binary code

Each zigzag value's quotient by 2^K is coded in unary, then its remainder's top bit, each bit with an adapting probability. There is one probability per context of K (capped at 23) and position in the unary part (capped at 7, one more slot for the remainder bit). Remaining K - 1 bits are coded direct. Probabilities start at one half in 4096ths and move toward each coded bit by a 32nd of the distance. After each value, K becomes the bit length of a running mean with a window of 16.

The coder is LZMA's: a 32-bit range, a 33-bit low with its carry held in a cache byte, five bytes flushed at the end. The decoder reads exactly the bytes the encoder wrote, so a block's byte length stays exact.

## Encoder choice

The encoder computes the exact size of every predictor and code and writes the shortest, the first on a tie. The adaptive binary code is tried last, on residuals the search chose, and kept when shorter than the chosen Rice or run-length code.

For linear prediction the encoder weights the block with a window whose first and last quarters rise as a smoothstep, runs Levinson-Durbin to order 32, and picks the order of least Rice cost at 15-bit precision. It then picks the precision, 5 to 15 bits, and the residual code. Each coefficient is rounded with the rounding error of earlier ones carried forward. Ada and Haskell perform the same floating-point operations in the same order, so they choose the same coefficients.
