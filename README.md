# Huffman coding of PCM audio

Lossless audio coders built on canonical Huffman codes, tested on generated signals and on public-domain and CC0 recordings. The work has two parts:

- **An experiment** in Ada that compares Huffman coding of raw samples, of differences, and of a tiered scheme in which the first sample of each group forms the next, coarser tier, against FLAC-style fixed predictors with Rice codes.
- **A block codec** that combines what the experiment showed with techniques from embedded and audio coders: constant blocks, removal of low bits that every sample shares, a delay to an exact repeat within a block or in the samples before it, tiers as one predictor among others, linear prediction of order 1 to 32 chosen per block, run-length Huffman codes, stereo decorrelation, and block lengths from 512 to 4096 frames chosen per region. It is written three times, in Ada with a SPARK decoder, in Haskell, and as Haskell around the SPARK library, and all three write the same bytes.

Every coded stream is decoded again and compared sample for sample.

## Files

- `ada/block_codec.ads`, `.adb`: the block codec. The decoder is SPARK, with no heap and no exceptions; malformed input returns `Truncated_Input` or `Bad_Data`. The encoder uses no heap and no shared state, and its linear prediction analysis uses 64-bit floating point.
- `ada/canonical_decoding.ads`, `.adb`, `ada/bit_streams.ads`, `.adb`: canonical Huffman decoding and bit access, in SPARK.
- `ada/codec_main.adb`: the stream of split trees and stereo modes around the block codec, run on a WAV file. `ada/block_codec_ffi.ads`, `.adb` and `ada/codec_lib.gpr` build the block codec as a C library, `ada/lib/libblockcodec.so`.
- `ada/audio_huffman.adb`, with `huffman_codes`, `predictors`, `residual_coders` and `wav_files`: the experiment.
- `haskell/src/BlockCodec.hs`, `Stream.hs`: the block codec and its stream in Haskell, with groups coded in parallel. `haskell/hybrid/`: the same stream around the SPARK library. `haskell/src/Blocks.hs`, `Tiers.hs`: parallel versions of experiment schemes.
- `corpus/`: the test files, `make_corpus.sh`, which builds them, and `SHA256SUMS`.
- `run.sh`, `compare.sh`, `bench.sh`, `sizes.sh`, `tables.sh`: run every coder, the common lossless tools, the timing, and the tables. Their output is in `results/`.

## Corpus

40 files, 44,883,000 samples, 630 s. Integer files are stored as FLAC and float files as WAV; no file exceeds 8 MB.

| Group | Files | Content |
|---|---|---|
| Generated, 16-bit 44.1 kHz mono, 20 s | `signal_*` | silence; dither (white noise of about ±2 LSB); white, pink and brown noise at -6 dBFS; 1 kHz sine, square, triangle and sawtooth at -6 dBFS; a 10 Hz impulse train; a 20 Hz to 20 kHz log sweep; an FM tone, 440 Hz carrier, 110 Hz modulator, index 3; an A major chord |
| Sample rates, 16-bit mono, 10 s | `rate_*` | the sine and the pink noise at 8, 16, 96 and 192 kHz |
| Bit depths, 44.1 kHz mono, 10 s | `depth_*` | the sine and the pink noise at 8, 24 and 32-bit integer and 32-bit float, and the sine at 12 bits in a 16-bit container |
| Recordings, 20 s, native format | `rec_*` | piano, orchestra, electronic, room noise, speech, 96 kHz piano, 192 kHz vinyl, and derived files listed below |

The generated signals come from ffmpeg's `anoisesrc` and `aevalsrc` with the expressions in `make_corpus.sh`, for example `0.5*sin(2*PI*440*t+3*sin(2*PI*110*t))` for the FM tone.

| File | Recording | Source | License | Format |
|---|---|---|---|---|
| `rec_piano` | Bach, Goldberg Variations, Aria, Shelley Katz, 0:20 to 0:40 | [Musopen Collection as FLAC](https://archive.org/details/MusopenCollectionAsFlac) | Public Domain Mark 1.0 | 24-bit 44.1 kHz |
| `rec_orchestra` | Mozart, Symphony No. 40, I, Czech National Symphony Orchestra, 0:00 to 0:20 | same | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_electronic` | DJ Saint-Hubert, "EZ Money HD", 0:20 to 0:40 | [misc vol 1](https://archive.org/details/dj-saint-hubert-misc-vol-1_202605) | CC0 1.0 | 24-bit 44.1 kHz |
| `rec_room` | Brussels, Hôtel des Monnaies metro station, its quietest 20 s, 0:07 to 0:27 | [radio aporee](https://archive.org/details/aporee_73504_85910) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_speech` | NASA, STS-31 Highlights narration, 0:00 to 0:20 | [Internet Archive](https://archive.org/details/Sts-31Highlights) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_piano_96k` | "Somewhere in Time", front right microphone, 0:10 to 0:30 | [Internet Archive](https://archive.org/details/PCMD1_piano_1119013_Somewhere_In_Time_front_right_120127_9624) | CC0 1.0 | 24-bit 96 kHz |
| `rec_vinyl_192k` | Sangam, "You Forget This", vinyl rip, 0:20 to 0:40 | [Internet Archive](https://archive.org/details/you-forget-this) | CC0 1.0 | 24-bit 192 kHz |

`rec_speech_16k` (16-bit mono) and `rec_speech_8k` (8-bit mono) are `rec_speech` resampled by ffmpeg. `rec_orchestra_f32` is `rec_orchestra` as 32-bit float. The full downloads go to `corpus/source/`, which git ignores; the speech, 96 kHz and 192 kHz files are fetched only as far as the segment needs.

## Block codec

A block is 1 to 4096 samples of one signal. Fields are most significant bit first, and each block ends on a byte boundary.

- `0` then the value in the sample width: a constant block.
- `1`, then 5 bits of low bits shared by every sample, which are removed, then 3 bits naming the predictor:
  - 0 to 4: polynomial order, lower orders for the first samples of the block.
  - 5: a delay. Either a `0` and a 12-bit distance to the first exact repeat of the first 32 samples within the block, where samples before that distance take first differences, or a `1` and a 15-bit distance back into the 16,384 samples before the block, which the shared low bits scale down. Only a block of the second kind needs earlier samples to decode.
  - 6: tiers of pairs, the final tier then each tier's offsets from coarse to fine. Each pair's second sample is stored as its offset from the mean of the first samples of its pair and the next.
  - 7: linear prediction. The order less one in 5 bits, the coefficient precision less one in 4 bits and the coefficient shift in 5 bits, then the coefficients in two's complement. The first samples, as many as the order, are second differences in a Rice code of their own. Each later sample is predicted as the sum of coefficient times earlier sample, shifted right by the coefficient shift.
- Then 1 bit naming the residual code:
  - Rice: a 6-bit parameter K, then each zigzag value shifted right by K in unary and its low K bits.
  - Run-length Huffman, after JPEG's AC coefficient symbols: each symbol is a run of up to 15 zeros and the bit length of the next value, with one symbol for sixteen zeros and one for the end of the block. The table is the number of symbols in 11 bits, then each symbol as an Elias gamma code of its step from the one before, with its code length in 5 bits. Codes are canonical, as in RFC 1951. A value's code is followed by its sign and the bits below its leading one.

The encoder computes the exact size of every predictor and code and writes the shortest, the first on a tie. For linear prediction it weights the block with a window whose first and last quarters rise as a smoothstep, runs the Levinson-Durbin recursion to order 32, and picks the order with the least Rice cost at 15-bit precision. It then picks the precision, from 5 to 15 bits, and the residual code. Each coefficient is rounded with the rounding error of the ones before it carried forward. Ada and Haskell perform the same floating-point operations in the same order, so they choose the same coefficients.

The stream holds the frame count in 32 bits; the channel count, depth and a float flag in 8 bits each; for float input a mode and a scale per channel; the index; a 16-bit byte length for each block; then the blocks. The index holds a split tree for each group of 4096 frames, in pre-order, padded to a byte at the end. A node halves down to 512 frames and carries a split bit when its second half starts before the last frame. Each leaf of a two-channel stream carries a 2-bit stereo mode: left and right, left and side, side and right, or mid and side. The mid is the mean of the two channels rounded down, and the side, left minus right, is coded one bit wider. The encoder codes every node of the tree, and keeps a node whole unless its halves cost fewer bits, index and byte lengths included. Two channels in different float modes stay left and right.

Float input becomes integers first. When every sample equals an integer over one power of two up to 2^31, those integers are coded (mode 1). This is the case for float made from 24-bit audio. Otherwise the float bit patterns are coded through an order-keeping map (mode 2).

## Results

### Bits per sample

Tables, parameters and headers are included, and every stream decodes back to the input. "Best general-purpose" is the best of `gzip`, `bzip2`, `xz`, `zstd`, `lz4` and `brotli` in 10 modes. "Best audio codec" is the best of FLAC (`-0`, `-5`, `-8`), WavPack (four modes), and ALAC and TTA through ffmpeg. The tiers and "Fixed, Rice" columns are the Ada experiment. Every method on every file is in `results/tables.md`.

| File | PCM | Best general-purpose | Best audio codec | Tiers, 16 from start | Tiers, pairs, mean | Fixed, Rice | Block codec | Block codec choices |
|---|---|---|---|---|---|---|---|---|
| signal_silence | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.02 (`wavpack -f`) | 1.00 | 1.00 | 1.00 | 0.01 | constant 216 |
| signal_dither | 16 44.1k mono | 1.83 (`xz -9e`) | 2.11 (`flac -5`) | 2.35 | 2.12 | 2.01 | 1.75 | order 0 216 |
| signal_white | 16 44.1k mono | 15.38 (`brotli -q 11`) | 15.21 (`wavpack -hh -x4`) | 15.97 | 16.16 | 15.50 | 15.03 | order 0 216 |
| signal_pink | 16 44.1k mono | 13.28 (`brotli -q 11`) | 12.84 (`wavpack -hh -x4`) | 13.62 | 13.03 | 13.08 | 12.99 | tiers 111, LPC 105 |
| signal_brown | 16 44.1k mono | 12.29 (`bzip2 -9`) | 11.35 (`wavpack -hh -x4`) | 12.99 | 11.52 | 11.64 | 11.50 | order 1 54, LPC 162 |
| signal_sine | 16 44.1k mono | 0.01 (`xz -6`) | 3.54 (`flac -5`) | 11.79 | 8.33 | 4.70 | 0.02 | delay 218, LPC 1 |
| signal_square | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.89 (`wavpack -f`) | 1.37 | 1.23 | 13.43 | 0.11 | delay 221 |
| signal_triangle | 16 44.1k mono | 0.01 (`xz -6`) | 5.53 (`wavpack -hh -x4`) | 7.32 | 3.11 | 10.01 | 0.02 | order 2 1, delay 218 |
| signal_sawtooth | 16 44.1k mono | 0.01 (`xz -6`) | 7.53 (`wavpack -f`) | 5.37 | 1.47 | 12.71 | 0.02 | order 2 1, delay 222 |
| signal_impulses | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.03 (`wavpack -f`) | 1.00 | 1.00 | 4.72 | 0.03 | constant 75, order 0 57, delay 6, tiers 137 |
| signal_sweep | 16 44.1k mono | 12.11 (`xz -6`) | 3.50 (`flac -8`) | 15.37 | 11.76 | 6.78 | 1.87 | order 2 11, LPC 226 |
| signal_fm | 16 44.1k mono | 0.07 (`brotli -q 11`) | 3.19 (`flac -8`) | 13.70 | 8.11 | 3.57 | 0.03 | delay 217, LPC 2 |
| signal_chord | 16 44.1k mono | 12.01 (`bzip2 -9`) | 2.82 (`flac -5`) | 13.45 | 6.56 | 2.71 | 1.77 | LPC 216 |
| rate_sine_8000 | 16 8k mono | 0.01 (`zstd -3`) | 0.03 (`wavpack -hh -x4`) | 2.19 | 1.25 | 14.00 | 0.02 | delay 20 |
| rate_sine_16000 | 16 16k mono | 0.00 (`brotli -q 11`) | 0.04 (`wavpack -hh -x4`) | 3.00 | 1.75 | 10.50 | 0.02 | delay 40 |
| rate_sine_96000 | 16 96k mono | 0.00 (`zstd -3`) | 3.46 (`flac -5`) | 6.02 | 3.81 | 3.36 | 0.02 | delay 235 |
| rate_sine_192000 | 16 192k mono | 0.00 (`xz -6`) | 2.32 (`flac -5`) | 7.34 | 3.98 | 2.25 | 0.02 | delay 471, LPC 1 |
| rate_pink_8000 | 16 8k mono | 13.40 (`brotli -q 11`) | 12.83 (`wavpack -hh -x4`) | 14.01 | 13.59 | 13.08 | 12.99 | tiers 9, LPC 11 |
| rate_pink_16000 | 16 16k mono | 13.35 (`brotli -q 11`) | 12.83 (`wavpack -hh -x4`) | 13.81 | 13.35 | 13.08 | 12.99 | tiers 16, LPC 24 |
| rate_pink_96000 | 16 96k mono | 13.29 (`brotli -q 11`) | 12.82 (`wavpack -hh -x4`) | 13.61 | 13.02 | 13.08 | 12.99 | tiers 118, LPC 118 |
| rate_pink_192000 | 16 192k mono | 13.28 (`brotli -q 11`) | 12.82 (`wavpack -hh -x4`) | 13.58 | 12.95 | 13.08 | 12.99 | tiers 216, LPC 254 |
| depth_sine_8 | 8 44.1k mono | 0.01 (`xz -6`) | 1.94 (`ffmpeg tta`) | 7.67 | 3.09 | 2.42 | 0.02 | delay 110, LPC 1 |
| depth_sine_12in16 | 16 44.1k mono | 0.02 (`xz -6`) | 2.47 (`flac -5`) | 11.08 | 6.65 | 7.61 | 0.04 | delay 137, LPC 1 |
| depth_sine_24 | 24 44.1k mono | 0.03 (`xz -6`) | 7.60 (`wavpack -hh -x4`) | 12.21 | 9.12 | 12.60 | 0.03 | delay 109, LPC 1 |
| depth_sine_32 | 32 44.1k mono | 0.05 (`xz -6`) | 14.53 (`wavpack -hh -x4`) | 12.54 | 9.31 | 20.60 | 0.11 | delay 114, LPC 1 |
| depth_sine_32f | 32 f 44.1k mono | 0.11 (`xz -6`) | 9.44 (`wavpack -hh -x4`) | 12.50 | 9.48 | 29.36 | 0.33 | order 4 1, delay 122, LPC 6 |
| depth_pink_8 | 8 44.1k mono | 4.98 (`bzip2 -9`) | 4.85 (`wavpack -hh -x4`) | 5.54 | 4.86 | 5.09 | 4.99 | tiers 58, LPC 50 |
| depth_pink_24 | 24 44.1k mono | 22.29 (`brotli -q 11`) | 20.84 (`wavpack -hh -x4`) | 24.12 | 24.11 | 21.08 | 20.99 | tiers 57, LPC 51 |
| depth_pink_32 | 32 44.1k mono | 31.06 (`brotli -q 11`) | 28.85 (`wavpack -hh -x4`) | 39.06 | 39.32 | 29.08 | 28.99 | tiers 57, LPC 51 |
| depth_pink_32f | 32 f 44.1k mono | 28.88 (`brotli -q 11`) | 25.63 (`wavpack -hh -x4`) | 34.30 | 36.01 | 31.49 | 27.62 | order 1 109 |
| rec_speech_8k | 8 8k mono | 3.96 (`bzip2 -9`) | 3.29 (`ffmpeg tta`) | 5.55 | 4.00 | 4.02 | 3.30 | order 0 2, order 1 43, order 2 4, tiers 6, LPC 145 |
| rec_speech_16k | 16 16k mono | 11.87 (`brotli -q 11`) | 9.03 (`wavpack -hh -x4`) | 13.39 | 11.10 | 10.50 | 9.11 | order 1 1, LPC 267 |
| rec_speech | 24 48k stereo | 19.92 (`brotli -q 11`) | 15.52 (`wavpack -hh -x4`) | 22.16 | 18.10 | 16.31 | 15.57 | LPC 638 |
| rec_piano | 24 44.1k stereo | 9.11 (`xz -9e`) | 3.79 (`flac -8`) | 10.85 | 6.88 | 12.22 | 3.68 | LPC 454 |
| rec_piano_96k | 24 96k stereo | 13.96 (`xz -6`) | 6.32 (`wavpack -hh -x4`) | 14.07 | 9.03 | 12.82 | 6.33 | LPC 952 |
| rec_orchestra | 24 48k stereo | 19.95 (`brotli -q 11`) | 13.81 (`wavpack -hh -x4`) | 21.27 | 17.07 | 14.32 | 13.85 | order 1 2, LPC 524 |
| rec_orchestra_f32 | 32 f 48k stereo | 21.11 (`xz -6`) | 13.81 (`wavpack -hh -x4`) | 31.98 | 28.13 | 29.04 | 13.85 | order 1 2, LPC 524 |
| rec_electronic | 24 44.1k stereo | 23.18 (`brotli -q 11`) | 18.60 (`wavpack -hh -x4`) | 23.75 | 22.75 | 20.10 | 18.58 | order 1 14, order 2 11, tiers 2, LPC 671 |
| rec_room | 24 48k stereo | 17.54 (`xz -6`) | 13.37 (`wavpack -hh -x4`) | 16.93 | 14.63 | 13.95 | 13.41 | LPC 550 |
| rec_vinyl_192k | 24 192k stereo | 18.30 (`xz -6`) | 6.24 (`wavpack -hh -x4`) | 17.96 | 12.36 | 9.04 | 5.80 | LPC 1876 |

- Silence costs 1 bit per sample with any Huffman or Rice code, because a prefix code spends at least one bit on every symbol. Constant blocks bring it to 0.01.
- The 1 kHz waveforms and the sines at every rate and depth repeat exactly. The delay that reaches into the 16,384 samples before a block takes them to 0.02 to 0.11 bits per sample. The FM tone repeats every 4410 samples, beyond one group, and costs 0.03, against 0.07 for `brotli -q 11`. General-purpose compressors stay smaller by 0.01 on the 1 kHz sine, triangle and sawtooth, and by 0.11 and 0.03 on the square wave and the impulse train.
- `rec_piano` holds 16-bit audio in a 24-bit container, with 8 low bits zero in every sample, and the 96 kHz piano has 6. With the shared low bits removed and linear prediction, `rec_piano` costs 3.68, against 3.79 for `flac -8` and 12.22 for the fixed predictor with Rice codes, which keeps the low bits.
- `rec_orchestra_f32` converts exactly to integers over 2^23, and costs what the integer file costs, 13.85. The float sine does not convert exactly; its float bit patterns repeat, and the delay into earlier samples takes it to 0.33, against 9.44 for WavPack, the only audio codec that accepts float, and 0.11 for `xz -6`.
- Pink noise splits its blocks between tiers and linear prediction at every sample rate and integer depth, 111 and 105 of the 216 blocks of the 44.1 kHz file, at 12.99 bits against 13.08 for the fixed predictor with Rice codes. This is likely because pink noise has the same spectral slope at every time scale, and each tier predicts from samples at one scale. White noise picks order 0.
- On its own, the tiered scheme as first described (groups of 16, offsets from the group's first sample) costs 1.5 to 7.9 bits more than plain first differences on every recording. Offsets grow with the distance from the group start, and each coarser tier holds samples further apart in time, whose differences cost nearly as much as raw samples.
- Linear prediction wins most blocks of every recording. The block codec is smaller than every tool on the piano, at 3.68 against 3.79 for `flac -8`, on the electronic track, at 18.58 against 18.60 for WavPack `-hh -x4`, and on the 192 kHz vinyl rip, at 5.80 against 6.24. On the other seven recordings it is 0.01 to 0.08 bits above the best audio codec. WavPack `-hh -x4` adapts its prediction sample by sample, where the block codec fixes one predictor per block; that seems the likely source of the remaining gap.
- Stereo modes take 1.11 bits off the electronic track and 0.19 off speech, which codes mid and side in 314 of its 319 blocks. Split blocks take 0.28 bits off 8 kHz speech, where 131 of the 200 blocks are 512 frames, and 0.98 off the float sine.
- The block codec is the best of all methods on dither, at 1.75, and on white noise, at 15.03.

### What each part adds

Mean bits per sample over each group of files, measured on the whole corpus as each part joined the block codec in turn. The base holds constant blocks, shared low bits, polynomial orders 0 to 4, the delay within a block, tiers, and Rice and run-length codes, in blocks of 4096 samples with 32-bit byte lengths.

| Block codec | Generated signals | Sample-rate sweep | Bit-depth sweep | Recordings | All 40 files |
|---|---|---|---|---|---|
| Base | 4.48 | 6.62 | 10.51 | 11.36 | 7.98 |
| and linear prediction | 3.95 | 6.62 | 10.45 | 10.55 | 7.60 |
| and the delay into earlier samples | 3.48 | 6.51 | 9.35 | 10.55 | 7.17 |
| and stereo modes | 3.48 | 6.51 | 9.35 | 10.41 | 7.14 |
| and split blocks, with 16-bit byte lengths | 3.47 | 6.51 | 9.24 | 10.35 | 7.10 |

### Three implementations of the block codec

Times for the whole corpus, 44,883,000 samples, on an AMD Ryzen 7 7700X with 8 cores and 16 threads. Each stream is hashed, and every implementation, at every core count, writes all 40 streams byte for byte the same as Ada.

| Implementation | Threads | Encode | Decode |
|---|---|---|---|
| Ada and SPARK (`codec_main`, assertions on) | 1 | 301.42 s | 1.99 s |
| Haskell | 1 | 295.35 s | 2.05 s |
| Haskell | 4 | 82.18 s | 0.84 s |
| Haskell | 8 | 48.84 s | 0.68 s |
| Haskell | 16 | 45.93 s | 0.51 s |
| Haskell + SPARK library | 1 | 318.00 s | 1.31 s |
| Haskell + SPARK library | 4 | 93.81 s | 0.67 s |
| Haskell + SPARK library | 8 | 61.72 s | 0.47 s |
| Haskell + SPARK library | 16 | 57.70 s | 0.46 s |

The encoder codes every node of each group's split tree, up to 15 blocks per group for each of up to four signals, and tries every predictor, 32 orders of linear prediction and 11 coefficient precisions on each block. Before linear prediction, back-references, stereo modes and split blocks, the Ada encoder took 11.26 s and decoding 1.46 s. The Rice parameter search starts from the bit length of the mean code value and walks to the least cost, which the convexity of the cost allows; it finds the same parameter as a walk from zero, and took that encoder from 11.26 s to 9.48 s. Decoding stays near 2 s: only blocks that reach back before themselves wait for earlier samples, and Haskell decodes all other blocks in parallel first.

The Haskell side uses unboxed vectors, whose loops fuse without intermediate arrays; strict, unpacked writer state; `countLeadingZeros` for unary and bit-length codes; and decoding from a 32-bit peek instead of bit by bit. Ada and Haskell compute the linear prediction analysis with the same 64-bit floating-point operations in the same order. Parallelism comes from sparks over pure functions, so the output cannot depend on scheduling. The executables run with `-N -A4m`; a 4 MB allocation area measured faster than 64 MB. `bench.sh` produces the table.

### Sizes

| Tool | Package | Installed size | Executable, bytes | Codec libraries, bytes |
|---|---|---|---|---|
| gzip | gzip 1.14 | 158.80 KiB | 97,344 | in the executable |
| bzip2 | bzip2 1.0.8 | 145.00 KiB | 39,000 | 74,720 |
| xz | xz 5.8.3 | 2.97 MiB | 96,920 | 215,248 |
| zstd | zstd 1.5.7 | 1,572.61 KiB | 193,792 | 939,976 |
| lz4 | lz4 1.10.0 | 450.16 KiB | 204,928 | in the executable |
| brotli | brotli 1.2.0 | 1,057.18 KiB | 34,832 | 977,200 |
| flac | flac 1.5.0 | 1,167.81 KiB | 185,672 | 296,928 |
| wavpack | wavpack 5.9.0 | 918.18 KiB | 129,120 | 186,536 |
| ffmpeg (ALAC, TTA) | ffmpeg 9.0.1 | 48.45 MiB | 428,296 | 25,467,352 |

| This work | Bytes |
|---|---|
| Block decoder, Cortex-M4 Thumb-2, `-Os`, run-time checks on | 6,120 code, 386 read-only data |
| Block decoder, Cortex-M4 Thumb-2, `-Os -gnatp` (checks the proof makes redundant) | 4,426 code, 354 read-only data |
| Block encoder, Cortex-M4 Thumb-2, `-Os -gnatp` | 6,916 code, and libgcc's software double precision |
| `libblockcodec.so`, x86-64, stripped, Ada runtime included | 251,304 |
| `codec_main`, x86-64, stripped, needs only libc | 675,368 |
| `huffman-audio`, Haskell, x86-64, stripped, needs libgmp | 6,026,288 |
| `huffman-audio-hybrid`, x86-64, stripped, needs `libblockcodec.so` and libgmp | 5,977,440 |

The tool rows hold encoders, container handling and command-line front ends as well as decoders. The decoder rows cover `Block_Codec.Decode` with its Rice, run-length and linear prediction readers, `Canonical_Decoding.Decode` and the bit reader, built with GNAT 16.1 for `arm-eabi` and the `light-cortex-m4` runtime. The encoder's linear prediction analysis works in 64-bit floating point, which the Cortex-M4's single-precision FPU leaves to libgcc. The block rows leave out the stream layer of split trees and stereo modes in `codec_main.adb`. `sizes.sh` produces the tool table.

### Proof

gnatprove 15.1 at level 2 proves the block decoder, `Canonical_Decoding` and `Bit_Streams` free of run-time errors for any input content, given the preconditions on the buffer bounds and the range of the earlier samples: 406 checks, 38 by flow analysis and 368 by the provers (300 run-time checks, 24 assertions, 44 contracts), none unproved. The provers bound the sum of 32 products of a 16-bit coefficient and a 33-bit sample without help. The encoder is outside SPARK.

## Hardware notes

- A block decodes with no table from an earlier block. Blocks that do not reach back before themselves can go to separate decoder lanes, given the byte lengths at the head of the stream. A block that reaches back needs the 16,384 samples of its signal before it, a window of 16,384 by 33 bits, about 528 Kbit, as an LZ77 decoder keeps its last output.
- The decoder holds the residuals, the samples and a second tier buffer, 4096 64-bit words each, about 96 KB, plus the run-length table of up to 1024 symbols. Smaller blocks shrink this in proportion.
- Canonical decoding keeps the first code and count of each length and no tree. It reads a bit per step, or compares the next 32 bits against the first code of each length in parallel to finish in one step.
- The constant check, shared-low-bit removal and delay search are comparisons and shifts. Rice decoding is a count of leading zeros and a shift. The polynomial, delay and tier predictors need only additions and shifts. Linear prediction needs one multiply-accumulate per coefficient per sample: at order 32, a 192 kHz stereo stream needs 12.3 million per second (32 × 192,000 × 2).
- CCSDS 121.0-B-3 standardizes Rice coding of this kind for spacecraft data, with a zero-block option for long runs of zeros.

## Build and run

GNAT 15.2 and gprbuild 25.0.1 (for example from the Alire toolchains) on the PATH, stack with the `lts-21.25` resolver, gnatprove 15.1, flac and ffmpeg:

    corpus/make_corpus.sh          # rebuilds corpus/ from source (the committed files are the reference)
    ./run.sh                       # builds everything, runs every coder, writes results/
    ./compare.sh && ./bench.sh     # common lossless tools, and the timing of the three implementations
    ./tables.sh > results/tables.md
    cd ada && gnatprove -P huffman_audio.gpr --level=2 -u bit_streams.adb canonical_decoding.adb block_codec.adb

The hybrid executable finds the SPARK library through `LD_LIBRARY_PATH=ada/lib`, which `run.sh` and `bench.sh` set.

## References

- RFC 1951, DEFLATE: canonical Huffman codes, section 3.2.2. https://www.rfc-editor.org/rfc/rfc1951
- puff.c in zlib: canonical decoding from the counts of each length. https://github.com/madler/zlib/blob/develop/contrib/puff/puff.c
- RFC 9639, FLAC: fixed predictors, Rice codes, and wasted bits. https://www.rfc-editor.org/rfc/rfc9639
- ITU-T T.81 (JPEG), section F.1.2.2: run-length and size symbols for AC coefficients.
- CCSDS 121.0-B-3, Lossless Data Compression, 2020.
- D. A. Huffman, "A Method for the Construction of Minimum-Redundancy Codes", Proceedings of the IRE 40(9), 1952.
