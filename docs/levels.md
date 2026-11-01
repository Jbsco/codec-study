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
| 0 | 7.490 | 47.09 MB | 9.0 s | 0.97 s | 5.00 s |
| 1 | 7.149 | 42.52 MB | 13.0 s | 1.45 s | 5.35 s |
| 2 | 7.117 | 42.36 MB | 32.7 s | 8.21 s | 5.54 s |
| 3 | 7.085 | 42.08 MB | 86.6 s | 15.68 s | 5.24 s |
| 4 | 7.058 | 41.97 MB | 191.8 s | 68.20 s | 5.47 s |
| 5 | 7.045 | 41.71 MB | 1803.5 s | 921.78 s | 683.94 s |

Level 1 encodes the corpus 15 times faster than level 4 for 1.3 percent more bytes; the one estimated order keeps most of linear prediction's gain. Level 3 comes within 0.3 percent of level 4 in 45 percent of its time. Decoding costs about the same at every level from 0 to 4, 5 to 6 s with the adaptive binary code against 2.3 s before it, because the decoder does one predictor's work per block however the encoder found it; level 5 is the exception, since its adaptive stage runs in the decoder too. These numbers are from the run with the container and the adaptive binary code, from `results/levels.txt`.

Where the encoder's time goes, from a profile of the first linear-prediction encoder on the 48 kHz speech file: the residual pass per candidate order took 53 percent, the Rice parameter search 14 percent, the run-length symbol pass 4 percent. Two fixes with no change to the stream, a bit-length by halving instead of a 64-step loop and a floor shift by logical shifts, took a quarter off the encode time.

## Beyond audio

A level is a search budget over one format. The estimates that make the low levels cheap come from the model itself (the prediction error at each order is a by-product of the recursion that computes the coefficients), and that is the pattern to look for in any codec: an exact search whose cost is a by-product of a cheaper computation can be replaced by a ranking on that by-product, and the format does not know the difference.
