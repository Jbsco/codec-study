# Floating-point samples

## Method

Float samples become integers before any block is coded. When every sample in a channel equals an integer over one power of two up to 2^31, those integers are coded and the stream records the power (mode 1). This is the case for float files made from integer audio, which is most float audio. Otherwise the 32-bit patterns are mapped to integers that keep their order, by inverting the magnitude bits of negative values, and those are coded (mode 2). Both maps are exact, so the stream is lossless in either mode.

64-bit float input is read when every sample is exactly a 32-bit float, as it is in 64-bit files made from 32-bit float or from integer audio up to 24 bits. Each sample is coded through its 32-bit pattern, the header records 64 bits, and the decoder widens every sample back, which is exact. A file whose samples need more than a 32-bit float's precision is refused with a message.

## Measured

- `rec_orchestra_f32`, the 24-bit orchestra as float, converts exactly to integers over 2^23 and costs what the integer file costs, 13.82 bits per sample. WavPack, the one audio codec in the comparison that accepts float, reaches 13.81.
- `depth_sine_32f`, the generated float sine, does not convert exactly, because its values are not integers over one power of two. Its bit patterns repeat, and the delay to an exact repeat in earlier samples takes it to 0.36 bits per sample, against 9.44 for WavPack and 0.11 for `xz -6`.
- Float pink noise, which neither converts nor repeats, costs 27.62 bits per sample as ordered bit patterns under polynomial order 1, against 25.63 for WavPack, which codes float by splitting the exponent and the mantissa.

## Beyond audio

Mode 1 is the general rule for float data that was integer once, such as sensor readings scaled into float: detect the common power of two and code integers. Mode 2 is the fallback for real float data, where the order-keeping map lets a numeric predictor work on bit patterns, but the mantissa's low bits are close to random and dominate the cost. For real float data a split of sign, exponent and mantissa into separate streams, each predicted on its own, is the better form, which is what the WavPack result shows.
