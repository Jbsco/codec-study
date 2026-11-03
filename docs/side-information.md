# Side information

Everything in a stream that is not a coded residual: block headers, linear prediction coefficients and their warm-up samples, run-length code tables, split bits and stereo modes, lengths and CRCs.

## Measured share

Level-4 streams, from the `bits:` line of `codec_main`:

| Files | Headers | LPC coefficients | LPC warm-up | Code tables | Framing | Residuals |
|---|---|---|---|---|---|---|
| Generated signals | 0.16% | 0.30% | 0.28% | 0.22% | 1.06% | 97.99% |
| Sample-rate sweep | 0.09% | 0.03% | 0.07% | 0.04% | 0.56% | 99.20% |
| Bit-depth sweep | 0.06% | 0.01% | 0.06% | 0.10% | 0.40% | 99.37% |
| Recordings | 0.07% | 0.64% | 0.77% | 0.02% | 0.24% | 98.26% |
| Whole corpus | 0.08% | 0.46% | 0.55% | 0.05% | 0.39% | 98.46% |

Side information takes 1.5 percent of all bits; code tables fell from 0.13 to 0.05 percent when the adaptive binary code took most of the run-length code's blocks. The two largest parts are linear prediction coefficients and their warm-up, both on the recordings. Group framing, 15 bytes per group of 4096 frames, is third, and the largest part on generated signals and the sweeps, where blocks themselves are small ([container.md](container.md)).

## Entropy coding the side information

Measured by recoding each stream's fields and counting, without changing the format:

- Coefficients in Rice or Exp-Golomb codes with a parameter per block: 0.02 percent of all bits. On speech it loses, because the parameter costs more than it saves on a few short coefficient lists. At order 32 and 15 bits, coefficients are 480 bits per block, 0.12 bits per sample in a 4096-frame block and 0.94 in a 512-frame block, which is what limits small blocks. The fix for that is the split tree's cost model, not a code on the coefficients.
- Warm-up coded at the block's residual rate, by seeding the predictor from samples before the block: 0.26 percent of all bits, 0.36 percent on the recordings. Level 5's adaptive stage does this seeding as part of its design.

Neither was worth a format change on its own. A tier above the blocks that codes the sequence of per-block choices would address the headers, 0.08 percent.

Measured the same way, after level 5: a Rice parameter per partition of 128, 256, 512 or 1024 samples instead of one per block, chosen per block by a 4-bit field, saves 0.10 percent of residual bits over the corpus. The gain sits in speech, 4.2 percent at 8 kHz and 0.9 percent at 16 kHz, where residual energy changes within a block. On every generated signal and noise file the repeated parameter costs more than it saves.

FLAC's partitioned Rice is this design. It was not built here, because the corpus-wide gain is at the study's threshold and the format change would cost every block its partition field.

## Beyond audio

The share of side information grows as blocks shrink and as the model per block grows, and it is the first thing to measure before adding model parameters to any format. The measurement itself is cheap: the parser that produced the table above walks each block's header and counts, and the same walk gives the estimate of any proposed recoding without implementing it.
