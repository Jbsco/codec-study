# Levels

## Method

The encoder searches at six levels, and every level writes the same format, so one decoder reads them all. A level sets the deepest split level it tries, how it picks a stereo mode, how many linear prediction orders it codes in full, the lowest coefficient precision it tries, and whether it tries the adaptive stage.

| Level | Search |
|---|---|
| 0 | 4096-frame blocks; polynomial, delay and tiers; left and right |
| 1 | and 1 estimated order of linear prediction at 15 bits; stereo mode estimated |
| 2 | and 2 orders, precisions 12 to 15; blocks down to 2048 |
| 3 | and 4 orders, precisions 9 to 15; blocks down to 1024; every stereo mode coded |
| 4 | and every order and precision 5 to 15; blocks down to 512 |
| 5 | and the adaptive stage, every tap count and warm-up |

Two estimates replace exhaustive search at the lower levels. The order estimate is the bits the Levinson-Durbin prediction error implies, 0.5 (n - p) log2(error) + 15 p for order p over n samples, which the recursion gives for free at every order. The stereo estimate is the pair of signals whose summed absolute second differences have the smallest summed logarithm. Both use a base-2 logarithm computed from the exponent and a fixed polynomial in the fraction, so Ada and Haskell choose the same orders and modes and write the same bytes.

## Measured, whole corpus, single runs on an AMD Ryzen 7 7700X

| Level | Mean bits per sample | Coded corpus | Encode, Ada, 1 thread | Encode, Haskell, 16 threads | Decode, Ada |
|---|---|---|---|---|---|
| 0 | 7.519 | 47.35 MB | 4.9 s | 0.59 s | 1.61 s |
| 1 | 7.180 | 42.73 MB | 10.7 s | 1.16 s | 2.08 s |
| 2 | 7.145 | 42.56 MB | 31.0 s | 4.61 s | 2.08 s |
| 3 | 7.111 | 42.26 MB | 99.8 s | 19.68 s | 2.08 s |
| 4 | 7.095 | 42.18 MB | 243.5 s | 52.75 s | 2.00 s |

Level 1 encodes the corpus 23 times faster than level 4 for 1.3 percent more bytes; the one estimated order keeps most of linear prediction's gain. Level 3 comes within 0.2 percent of level 4 in 41 percent of its time. Decoding costs about the same at every level from 1 up, because the decoder does one predictor's work per block however the encoder found it. These numbers predate the CRCs and the level-5 flag bit, which add 0.003 and about 0.01 bits per sample at level 4.

Where the encoder's time goes, from a profile of the first linear-prediction encoder on the 48 kHz speech file: the residual pass per candidate order took 53 percent, the Rice parameter search 14 percent, the run-length symbol pass 4 percent. Two fixes with no change to the stream, a bit-length by halving instead of a 64-step loop and a floor shift by logical shifts, took a quarter off the encode time.

## Beyond audio

A level is a search budget over one format. The estimates that make the low levels cheap come from the model itself (the prediction error at each order is a by-product of the recursion that computes the coefficients), and that is the pattern to look for in any codec: an exact search whose cost is a by-product of a cheaper computation can be replaced by a ranking on that by-product, and the format does not know the difference.
