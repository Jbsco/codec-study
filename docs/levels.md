# Levels

## Method

The encoder searches at six levels, and every level writes the same format, so one decoder reads them all. A level sets how deep it splits, how it picks a stereo mode, how many linear prediction orders it codes in full, its lowest coefficient precision, whether it tries the adaptive binary code, and whether it tries the adaptive stage.

| Level | Search |
|---|---|
| 0 | 4096-frame blocks; polynomial, delay and tiers; left and right |
| 1 | and 1 estimated order of linear prediction at 15 bits; stereo mode estimated |
| 2 | and 2 orders, precisions 12 to 15; blocks down to 2048; the adaptive binary code |
| 3 | and 4 orders, precisions 9 to 15; blocks down to 1024; every stereo mode coded |
| 4 | and every order and precision 5 to 15; blocks down to 512 |
| 5 | and the adaptive stage, every tap count and warm-up |

Two estimates replace exhaustive search at the lower levels. The order estimate is the bits the Levinson-Durbin prediction error implies, 0.5 (n - p) log2(error) + 15 p for order p over n samples, which the recursion gives for free at every order. The stereo estimate is the pair of signals whose summed absolute second differences have the smallest summed logarithm. Both use a base-2 logarithm computed from the exponent and a fixed polynomial in the fraction, so Ada and Haskell choose the same orders and modes and write the same bytes.

## Measured

Whole corpus, single runs on a typical workstation (AMD Ryzen 7 7700X):

| Level | Mean bits per sample | Coded corpus | Encode, Ada, 1 thread | Encode, Haskell, 16 threads | Decode, Ada |
|---|---|---|---|---|---|
| 0 | 7.551 | 47.49 MB | 5.6 s | 1.34 s | 1.77 s |
| 1 | 7.211 | 42.87 MB | 9.9 s | 1.72 s | 2.47 s |
| 2 | 7.117 | 42.36 MB | 30.8 s | 4.77 s | 5.85 s |
| 3 | 7.086 | 42.08 MB | 85.1 s | 15.25 s | 5.76 s |
| 4 | 7.059 | 41.97 MB | 181.1 s | 54.47 s | 5.73 s |
| 5 | 7.045 | 41.71 MB | 2061.6 s | 1162.54 s | 573.26 s |

Level 1 encodes the corpus 18 times faster than level 4 for 2.2 percent more bytes; one estimated order keeps most of linear prediction's gain. Level 3 comes within 0.3 percent of level 4 in 47 percent of its time.

Decoding costs 1.8 and 2.5 s at levels 0 and 1, which leave the adaptive binary code out. From level 2 it costs 5.7 to 5.9 s, since the encoder takes that code wherever it is shorter and the decoder runs a range decoder step per modeled bit. Otherwise a decoder does one predictor's work per block, no matter how the encoder found it. Level 5 adds its adaptive stage on top. These numbers come from the run with the adaptive binary code left to levels 2 and up, in `results/levels.txt`.

Where encoder time goes, from a profile of the first linear-prediction encoder on the 48 kHz speech file: residual pass per candidate order 53 percent, Rice parameter search 14 percent, run-length symbol pass 4 percent. Two fixes with no change to the stream, a bit length by halving instead of a 64-step loop and a floor shift by logical shifts, took a quarter off encode time.

## Beyond audio

A level is a search budget over one format. Estimates that make low levels cheap come from the model itself: prediction error at each order is a by-product of the recursion that computes the coefficients. That is the pattern to look for in any codec: an exact search whose cost is a by-product of a cheaper computation can be replaced by a ranking on that by-product, and the format does not know the difference.
