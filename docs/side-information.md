# Side information

Everything in a stream that is not a coded residual: block headers, the linear prediction coefficients and their warm-up samples, the run-length code tables, the index of split bits and stereo modes, the lengths and CRCs.

## Measured share, level-4 streams, from the `bits:` line of `codec_main`

| Files | Headers | LPC coefficients | LPC warm-up | Code tables | Framing | Residuals |
|---|---|---|---|---|---|---|
| Generated signals | 0.15% | 0.29% | 0.27% | 0.55% | 1.03% | 97.72% |
| Sample-rate sweep | 0.08% | 0.03% | 0.07% | 0.11% | 0.55% | 99.17% |
| Bit-depth sweep | 0.06% | 0.01% | 0.05% | 0.17% | 0.39% | 99.31% |
| Recordings | 0.07% | 0.65% | 0.78% | 0.05% | 0.24% | 98.20% |
| All 40 files | 0.08% | 0.46% | 0.56% | 0.13% | 0.39% | 98.38% |

Side information takes 1.6 percent of all bits. The two largest parts are the linear prediction coefficients and their warm-up, both on the recordings; the framing of the groups, 15 bytes per group of 4096 frames, is third, and the largest part on the generated signals and the sweeps, where the blocks themselves are small (`container.md`).

## What entropy coding the side information would save

Measured by recoding each stream's fields and counting, without changing the format:

- Coefficients in Rice or Exp-Golomb codes with a parameter per block: 0.02 percent of all bits. On speech it loses, because the parameter costs more than it saves on a few short coefficient lists. At order 32 and 15 bits the coefficients are 480 bits per block, 0.12 bits per sample in a 4096-frame block and 0.94 in a 512-frame block, which is what limits small blocks; the fix for that is the split tree's cost model, not a code on the coefficients.
- The warm-up coded at the block's residual rate, by seeding the predictor from the samples before the block: 0.26 percent of all bits, 0.36 percent on the recordings. The adaptive stage of level 5 does this seeding as part of its design.

Neither was worth a format change on its own. A tier above the blocks that codes the sequence of per-block choices would address the headers, 0.08 percent.

Measured the same way, after level 5: a Rice parameter per partition of 128, 256, 512 or 1024 samples instead of one per block, chosen per block by a 4-bit field, saves 0.10 percent of the residual bits over the corpus. The gain sits in speech, 4.2 percent at 8 kHz and 0.9 percent at 16 kHz, where the residual energy changes within a block; on every generated signal and noise file the repeated parameter costs more than it saves. FLAC's partitioned Rice is this design. It was not built here, because the corpus-wide gain is at the study's threshold and the format change would cost every block its partition field.

## Beyond audio

The share of side information grows as blocks shrink and as the model per block grows, and it is the first thing to measure before adding model parameters to any format. The measurement itself is cheap: the parser that produced the table above walks each block's header and counts, and the same walk gives the estimate of any proposed recoding without implementing it.
