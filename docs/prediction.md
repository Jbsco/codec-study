# Prediction

Each block predicts every sample from samples before it and codes the difference. Four predictors compete per block, by exact bit count.

## Polynomial orders 0 to 4

FLAC's fixed predictors: the sample itself, the previous sample, a line through the two previous samples, and so on, with lower orders for a block's first samples. No side information beyond 3 bits naming the order. White noise picks order 0 at 15.03 bits per sample; brown noise picks order 1.

## Tiers of pairs

The scheme this study began with. Samples at even positions form the next tier, each odd sample is coded as its offset from the mean of its two neighbouring even samples, and the tier repeats until two samples remain. Coded coarse to fine. This is the LeGall 5/3 lifting wavelet's predict step without its update step.

Measured: as first described, with groups of 16 coded as offsets from each group's first sample, the scheme costs 1.5 to 7.9 bits per sample more than first differences on every recording. Offsets grow with distance from the group start, and each coarser tier contains samples further apart in time. The pair form with the mean of two anchors closes most of that gap.

Tiers win where a signal has the same spectral slope at every time scale. Pink noise picks tiers in 111 of 216 blocks and linear prediction in the other 105, at 12.99 bits per sample against 13.08 for the fixed predictor with Rice codes.

## Linear prediction, order chosen per block

The encoder weights the block with a window whose first and last quarters rise as a smoothstep and runs Levinson-Durbin to order 32. It codes the order of least Rice cost at 15-bit precision, then picks the precision from 5 to 15 bits and the residual code. Each coefficient is rounded with the error of earlier ones carried forward, which keeps the quantized filter's gain close to the real one. A block's first samples, as many as the order, are coded as second differences in their own Rice code.

Measured on the whole corpus: 7.98 to 7.60 bits per sample, the largest single gain in the study. On the recordings 11.36 to 10.55. Sweep, chord and FM tone, which polynomial orders could not follow, drop from 6.58, 2.67 and 3.54 to 1.89, 1.78 and 2.19. The vinyl rip at 192 kHz picks linear prediction in all 1876 of its blocks, at 5.80 bits per sample against 6.24 for WavPack `-hh -x4`.

The order search is the encoder's main cost: every order coded in full is 32 residual passes per block. [levels.md](levels.md) shows the estimate that replaces it.

## Adaptive stage after linear prediction

A sign-sign LMS filter of 16, 32, 64 or 256 taps runs over linear prediction residuals. It trains on residuals of 0, 256, 1024 or 4096 samples before the block, with the block's own coefficients applied across the boundary so the residual stream is continuous. Each weight moves by 2 toward the error's sign times its input's sign; weights are 16-bit, and the prediction is shifted down 14 bits. The encoder tries every tap and warm-up pair and keeps the stage where it is smaller.

Measured per block at level 5 against level 4: piano 3.69 to 3.55, chord 1.78 to 1.68, sweep 1.87 to 1.67, electronic 18.59 to 18.46, orchestra 13.85 to 13.71. Noise files gain nothing and would still pay decoder work where the stage is kept for a few bits, so the encoder keeps it only above a threshold. A sample-by-sample adaptive stage is what WavPack and OptimFROG use after their fixed predictors, and it closed most of this codec's gap to WavPack on the recordings.

## Cost

Polynomial and tier predictors need additions and shifts only. Linear prediction needs one multiply-accumulate per coefficient per sample: at order 32 and 192 kHz stereo, 12.3 million per second. The adaptive stage needs one multiply-accumulate per tap per sample plus a weight update, 256 of each at the largest setting, about 16 times linear prediction's work at order 16.

## Beyond audio

Polynomial prediction is the general tool for any sampled quantity that varies smoothly: temperatures, voltages, positions. Linear prediction fits anything with a stable spectrum over a block. Tiers fit 1/f signals. The adaptive stage fits slowly varying statistics where a per-block filter is not enough. None of them fit data without sample-to-sample continuity, such as compiled code or packed records, where prediction residuals are as wide as the data.
