# Huffman coding of PCM audio

Lossless audio coders built on canonical Huffman codes, measured on generated signals and on public-domain and CC0 recordings. The work has two parts:

- **Experiment** in Ada: Huffman coding of raw samples, of differences, and of a tiered scheme in which the first sample of each group forms the next, coarser tier, against FLAC-style fixed predictors with Rice codes.
- **Block codec** that adds techniques from embedded and audio coders: constant blocks, shared low bits removed, exact repeats found within a block or before it, and tiers as one predictor among others. It chooses linear prediction of order 1 to 32 per block, codes residuals with Rice, run-length Huffman or adaptive binary codes, decorrelates stereo, and picks block lengths from 512 to 4096 frames per region. It is written three times, in Ada with a SPARK decoder, in Haskell, and as Haskell around the SPARK library, and all three write the same bytes.

Every coded stream is decoded again and compared sample for sample.

## Files

- `ada/block_codec.ads`, `.adb`: block codec. SPARK decoder with no heap and no exceptions; malformed input returns `Truncated_Input` or `Bad_Data`. Encoder with no heap and no shared state; linear prediction analysis in 64-bit floating point.
- `ada/canonical_decoding`, `bit_streams`, `checksums`, `range_coding`: canonical Huffman decoding, bit access, CRC-16 and the binary range coder, in SPARK. `ada/checksums_test.adb` tests the CRC; `ada/corrupt_test.adb` walks a written stream and checks its framing and every CRC against flipped bits. `ada/fuzz_decode.adb` decodes changed copies of the test vectors and fails on any exception.
- `ada/codec_main.adb`: stream of split trees and stereo modes around the block codec, run on a WAV file. `ada/stream_reading` and `ada/stream_format`: header, groups and damage handling, read from a stream's own bytes. `ada/stream_writing` with `ada/stream_encode.adb`: audio file to stream. `ada/stream_decode.adb`: stream to audio file, group by group. `ada/byte_files`: files and pipes. `ada/block_codec_ffi` and `ada/codec_lib.gpr`: block codec as a C library, `ada/lib/libblockcodec.so`.
- `ada/codec_api` with `include/blockcodec.h`: the library's C interface for streams; `capi/` tests it.
- `ada/wav_files`: input from WAV, RF64, Wave64 and AIFF, WAV output. `ada/audio_huffman.adb` with `huffman_codes`, `predictors` and `residual_coders`: experiment coders.
- `haskell/src/BlockCodec.hs`, `Stream.hs`, `Checksum.hs`, `RangeCoder.hs`: block codec, stream, CRC-16 and range coder in Haskell, groups coded in parallel. `haskell/hybrid/`: same stream around the SPARK library. `haskell/src/Blocks.hs`, `Tiers.hs`: parallel versions of experiment schemes.
- `corpus/`: test files, `make_corpus.sh` and `SHA256SUMS`.
- `extra.sh`: the codec on the wider corpus in `corpus/extra/`, results in `results/extra.tsv`.
- `run.sh`, `compare.sh`, `bench.sh`, `tool_timing.sh`, `levels.sh`, `segments.sh`, `multichannel.sh`, `sizes.sh`, `tables.sh`: every coder, common lossless tools, timing, timing against FLAC and WavPack, encoder levels, segment lengths, a four-channel file, tool sizes and tables. Output in `results/`.
- `vectors/`: format version 2 test streams, intact and damaged, with a manifest of decoded MD5s and `check.sh` to test a decoder.
- `docs/`: one page per compression topic with method, measured effect, decoder cost and where it applies beyond audio; `docs/format.md` lists every field of a block, and `docs/spec.md` defines format version 2 for a decoder.

## Corpus

44,883,000 samples over 630 s. Integer files are FLAC, float files WAV, none over 8 MB.

| Group | Files | Content |
|---|---|---|
| Generated, 16-bit 44.1 kHz mono, 20 s | `signal_*` | silence; dither (white noise of about ±2 LSB); white, pink and brown noise at -6 dBFS; 1 kHz sine, square, triangle and sawtooth at -6 dBFS; 10 Hz impulse train; 20 Hz to 20 kHz log sweep; FM tone, 440 Hz carrier, 110 Hz modulator, index 3; A major chord |
| Sample rates, 16-bit mono, 10 s | `rate_*` | sine and pink noise at 8, 16, 96 and 192 kHz |
| Bit depths, 44.1 kHz mono, 10 s | `depth_*` | sine and pink noise at 8, 24 and 32-bit integer and 32-bit float; sine at 12 bits in a 16-bit container |
| Recordings, 20 s, native format | `rec_*` | piano, orchestra, electronic, room noise, speech, 96 kHz piano, 192 kHz vinyl, and derived files |

Generated signals come from ffmpeg's `anoisesrc` and `aevalsrc` with the expressions in `make_corpus.sh`, for example `0.5*sin(2*PI*440*t+3*sin(2*PI*110*t))` for the FM tone. `rec_speech_16k` (16-bit mono) and `rec_speech_8k` (8-bit mono) are `rec_speech` resampled by ffmpeg, and `rec_orchestra_f32` is `rec_orchestra` as 32-bit float. Full downloads go to `corpus/source/`, which git ignores.

<details>
<summary><b>Recording sources</b> (7 rows)</summary>

| File | Recording | Source | License | Format |
|---|---|---|---|---|
| `rec_piano` | Bach, Goldberg Variations, Aria, Shelley Katz, 0:20 to 0:40 | [Musopen Collection as FLAC](https://archive.org/details/MusopenCollectionAsFlac) | Public Domain Mark 1.0 | 24-bit 44.1 kHz |
| `rec_orchestra` | Mozart, Symphony No. 40, I, Czech National Symphony Orchestra, 0:00 to 0:20 | same | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_electronic` | DJ Saint-Hubert, "EZ Money HD", 0:20 to 0:40 | [misc vol 1](https://archive.org/details/dj-saint-hubert-misc-vol-1_202605) | CC0 1.0 | 24-bit 44.1 kHz |
| `rec_room` | Brussels, Hôtel des Monnaies metro station, its quietest 20 s, 0:07 to 0:27 | [radio aporee](https://archive.org/details/aporee_73504_85910) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_speech` | NASA, STS-31 Highlights narration, 0:00 to 0:20 | [Internet Archive](https://archive.org/details/Sts-31Highlights) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `rec_piano_96k` | "Somewhere in Time", front right microphone, 0:10 to 0:30 | [Internet Archive](https://archive.org/details/PCMD1_piano_1119013_Somewhere_In_Time_front_right_120127_9624) | CC0 1.0 | 24-bit 96 kHz |
| `rec_vinyl_192k` | Sangam, "You Forget This", vinyl rip, 0:20 to 0:40 | [Internet Archive](https://archive.org/details/you-forget-this) | CC0 1.0 | 24-bit 192 kHz |

</details>

`corpus/extra/` contains six more 20 s recordings, kept apart so every result below stays comparable: a string quartet, birds, rain and thunder decoded from an MP3 original, a rocket launch, a church choir and an organ. `corpus/make_extra.sh` fetches and cuts them, and `extra.sh` checks the codec on them.

<details>
<summary><b>Wider corpus sources</b> (6 rows)</summary>

| File | Recording | Source | License | Format |
|---|---|---|---|---|
| `extra_quartet` | Haydn, String Quartet Op. 64 No. 5 "Lark", IV, 0:15 to 0:35 | [Musopen Collection as FLAC](https://archive.org/details/MusopenCollectionAsFlac) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `extra_birds` | Bobiri Butterfly Sanctuary, Ghana, birds, insects and wind, 0:10 to 0:30 | [radio aporee](https://archive.org/details/aporee_70008_81545) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `extra_rain_mp3` | Logone Oriental, Chad, rain and thunder, from the MP3 original, 0:05 to 0:25 | [radio aporee](https://archive.org/details/aporee_73575_85987) | Public Domain Mark 1.0 | 16-bit 48 kHz |
| `extra_launch` | NASA, STS-87 launch, 0:20 to 0:40 | [NASA Launch Audio](https://archive.org/details/NasaLaunchAudio) | Public Domain Mark 1.0 | 16-bit 44.1 kHz |
| `extra_choir` | Église de Villebrumier, France, choir singing Thoinot Arbeau's Pavane, 0:10 to 0:30 | [radio aporee](https://archive.org/details/aporee_60543_69571) | Public Domain Mark 1.0 | 24-bit 48 kHz |
| `extra_organ` | Janice Faythe Bennett, "Easy Listening Organ Music", 0:30 to 0:50 | [Internet Archive](https://archive.org/details/EasyListeningOrganMusic) | CC0 1.0 | 16-bit 44.1 kHz |

</details>

## Block codec

A block codes 1 to 4096 samples of one signal, as one constant value or as a predictor and a residual code. Shared low bits are removed first. `docs/format.md` lists every field, and `docs/spec.md` gives every decoding rule.

- Predictors: polynomial order 0 to 4, tiers of pairs, and a delay to an exact repeat of the block's first 32 samples, within the block or in the 16,384 samples before it. Linear prediction runs at order 1 to 32 and a coefficient precision of 5 to 15 bits, with an adaptive sign-sign LMS stage after it at level 5.
- Residual codes: Rice; run-length Huffman after JPEG's AC symbols, with a canonical code table per block; an adaptive binary code through LZMA's range coder, with a probability per context, tried from level 2 up.
- Encoder: computes the exact size of every predictor and code and writes the shortest. Linear prediction analysis runs Levinson-Durbin to order 32 over a windowed block with the same floating-point operations in Ada and Haskell, so both choose the same coefficients.

A stream is a header and groups of 4096 frames. The header contains the magic `BLKC`, format fields, an MD5 of the input samples in FLAC's layout, metadata with tags and a seek table, and a CRC-16. Each group is framed by a sync word, its byte length, its first frame, a split tree with a stereo mode per channel pair, a byte length and a CRC-16 per block, and a CRC-16 over that framing.

Blocks read earlier samples only within their segment, so a decoder can start at any seek point and a damaged group costs at most the rest of its segment. `docs/container.md` and `docs/integrity.md` have the layout, its cost and the damage tests.

Float input becomes integers: exact integers over one power of two when every sample allows it (mode 1), as float made from 24-bit audio does, and otherwise float bit patterns through an order-keeping map (mode 2). `docs/float.md` measures both.

## Results

### Bits per sample

Level 4, with tables, parameters and headers included; every stream decodes back to its input. "Best general-purpose" is the best of `gzip`, `bzip2`, `xz`, `zstd`, `lz4` and `brotli` over 10 modes. "Best audio codec" is the best of FLAC (`-0`, `-5`, `-8`), WavPack (four modes), and ALAC and TTA through ffmpeg. Tiers and "Fixed, Rice" columns are the Ada experiment. Every method on every file is in `results/tables.md`.

<details>
<summary><b>Every file</b> (40 rows)</summary>

| File | PCM | Best general-purpose | Best audio codec | Tiers, 16 from start | Tiers, pairs, mean | Fixed, Rice | Block codec | Block codec choices |
|---|---|---|---|---|---|---|---|---|
| signal_silence | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.02 (`wavpack -f`) | 1.00 | 1.00 | 1.00 | 0.04 | constant 216 |
| signal_dither | 16 44.1k mono | 1.83 (`xz -9e`) | 2.11 (`flac -5`) | 2.35 | 2.12 | 2.01 | 1.78 | order 0 216 |
| signal_white | 16 44.1k mono | 15.38 (`brotli -q 11`) | 15.21 (`wavpack -hh -x4`) | 15.97 | 16.16 | 15.50 | 15.06 | order 0 216 |
| signal_pink | 16 44.1k mono | 13.28 (`brotli -q 11`) | 12.84 (`wavpack -hh -x4`) | 13.62 | 13.03 | 13.08 | 12.87 | tiers 112, LPC 117 |
| signal_brown | 16 44.1k mono | 12.29 (`bzip2 -9`) | 11.35 (`wavpack -hh -x4`) | 12.99 | 11.52 | 11.64 | 11.42 | order 1 54, LPC 162 |
| signal_sine | 16 44.1k mono | 0.01 (`xz -6`) | 3.54 (`flac -5`) | 11.79 | 8.33 | 4.70 | 0.05 | delay 220, LPC 2 |
| signal_square | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.89 (`wavpack -f`) | 1.37 | 1.23 | 13.43 | 0.13 | delay 221 |
| signal_triangle | 16 44.1k mono | 0.01 (`xz -6`) | 5.53 (`wavpack -hh -x4`) | 7.32 | 3.11 | 10.01 | 0.05 | order 2 2, delay 220 |
| signal_sawtooth | 16 44.1k mono | 0.01 (`xz -6`) | 7.53 (`wavpack -f`) | 5.37 | 1.47 | 12.71 | 0.05 | order 2 2, delay 224 |
| signal_impulses | 16 44.1k mono | 0.00 (`bzip2 -9`) | 0.03 (`wavpack -f`) | 1.00 | 1.00 | 4.72 | 0.06 | constant 18, order 0 43, delay 1, tiers 156 |
| signal_sweep | 16 44.1k mono | 12.11 (`xz -6`) | 3.50 (`flac -8`) | 15.37 | 11.76 | 6.78 | 1.52 | order 2 10, LPC 233 |
| signal_fm | 16 44.1k mono | 0.07 (`brotli -q 11`) | 3.19 (`flac -8`) | 13.70 | 8.11 | 3.57 | 0.07 | delay 218, LPC 4 |
| signal_chord | 16 44.1k mono | 12.01 (`bzip2 -9`) | 2.82 (`flac -5`) | 13.45 | 6.56 | 2.71 | 1.40 | LPC 216 |
| rate_sine_8000 | 16 8k mono | 0.01 (`zstd -3`) | 0.03 (`wavpack -hh -x4`) | 2.19 | 1.25 | 14.00 | 0.06 | delay 20 |
| rate_sine_16000 | 16 16k mono | 0.00 (`brotli -q 11`) | 0.04 (`wavpack -hh -x4`) | 3.00 | 1.75 | 10.50 | 0.06 | delay 40 |
| rate_sine_96000 | 16 96k mono | 0.00 (`zstd -3`) | 3.46 (`flac -5`) | 6.02 | 3.81 | 3.36 | 0.05 | delay 235 |
| rate_sine_192000 | 16 192k mono | 0.00 (`xz -6`) | 2.32 (`flac -5`) | 7.34 | 3.98 | 2.25 | 0.05 | delay 471, LPC 1 |
| rate_pink_8000 | 16 8k mono | 13.40 (`brotli -q 11`) | 12.83 (`wavpack -hh -x4`) | 14.01 | 13.59 | 13.08 | 12.88 | tiers 10, LPC 10 |
| rate_pink_16000 | 16 16k mono | 13.35 (`brotli -q 11`) | 12.83 (`wavpack -hh -x4`) | 13.81 | 13.35 | 13.08 | 12.86 | tiers 17, LPC 23 |
| rate_pink_96000 | 16 96k mono | 13.29 (`brotli -q 11`) | 12.82 (`wavpack -hh -x4`) | 13.61 | 13.02 | 13.08 | 12.87 | tiers 121, LPC 130 |
| rate_pink_192000 | 16 192k mono | 13.28 (`brotli -q 11`) | 12.82 (`wavpack -hh -x4`) | 13.58 | 12.95 | 13.08 | 12.87 | tiers 224, LPC 275 |
| depth_sine_8 | 8 44.1k mono | 0.01 (`xz -6`) | 1.94 (`ffmpeg tta`) | 7.67 | 3.09 | 2.42 | 0.05 | delay 110, LPC 1 |
| depth_sine_12in16 | 16 44.1k mono | 0.02 (`xz -6`) | 2.47 (`flac -5`) | 11.08 | 6.65 | 7.61 | 0.07 | delay 110, LPC 1 |
| depth_sine_24 | 24 44.1k mono | 0.03 (`xz -6`) | 7.60 (`wavpack -hh -x4`) | 12.21 | 9.12 | 12.60 | 0.06 | delay 110, LPC 1 |
| depth_sine_32 | 32 44.1k mono | 0.05 (`xz -6`) | 14.53 (`wavpack -hh -x4`) | 12.54 | 9.31 | 20.60 | 0.11 | delay 110, LPC 1 |
| depth_sine_32f | 32 f 44.1k mono | 0.11 (`xz -6`) | 9.44 (`wavpack -hh -x4`) | 12.50 | 9.48 | 29.36 | 0.36 | order 4 1, delay 122, LPC 6 |
| depth_pink_8 | 8 44.1k mono | 4.98 (`bzip2 -9`) | 4.85 (`wavpack -hh -x4`) | 5.54 | 4.86 | 5.09 | 4.90 | tiers 58, LPC 51 |
| depth_pink_24 | 24 44.1k mono | 22.29 (`brotli -q 11`) | 20.84 (`wavpack -hh -x4`) | 24.12 | 24.11 | 21.08 | 20.87 | tiers 57, LPC 54 |
| depth_pink_32 | 32 44.1k mono | 31.06 (`brotli -q 11`) | 28.85 (`wavpack -hh -x4`) | 39.06 | 39.32 | 29.08 | 28.90 | tiers 58, LPC 53 |
| depth_pink_32f | 32 f 44.1k mono | 28.88 (`brotli -q 11`) | 25.63 (`wavpack -hh -x4`) | 34.30 | 36.01 | 31.49 | 27.65 | order 1 109 |
| rec_speech_8k | 8 8k mono | 3.96 (`bzip2 -9`) | 3.29 (`ffmpeg tta`) | 5.55 | 4.00 | 4.02 | 3.25 | order 1 24, order 2 1, tiers 5, LPC 114 |
| rec_speech_16k | 16 16k mono | 11.87 (`brotli -q 11`) | 9.03 (`wavpack -hh -x4`) | 13.39 | 11.10 | 10.50 | 9.10 | order 1 1, LPC 186 |
| rec_speech | 24 48k stereo | 19.92 (`brotli -q 11`) | 15.52 (`wavpack -hh -x4`) | 22.16 | 18.10 | 16.31 | 15.55 | LPC 540 |
| rec_piano | 24 44.1k stereo | 9.11 (`xz -9e`) | 3.79 (`flac -8`) | 10.85 | 6.88 | 12.22 | 3.67 | LPC 446 |
| rec_piano_96k | 24 96k stereo | 13.96 (`xz -6`) | 6.32 (`wavpack -hh -x4`) | 14.07 | 9.03 | 12.82 | 6.31 | LPC 940 |
| rec_orchestra | 24 48k stereo | 19.95 (`brotli -q 11`) | 13.81 (`wavpack -hh -x4`) | 21.27 | 17.07 | 14.32 | 13.82 | LPC 478 |
| rec_orchestra_f32 | 32 f 48k stereo | 21.11 (`xz -6`) | 13.81 (`wavpack -hh -x4`) | 31.98 | 28.13 | 29.04 | 13.82 | LPC 478 |
| rec_electronic | 24 44.1k stereo | 23.18 (`brotli -q 11`) | 18.60 (`wavpack -hh -x4`) | 23.75 | 22.75 | 20.10 | 18.54 | order 1 6, order 2 9, tiers 2, LPC 541 |
| rec_room | 24 48k stereo | 17.54 (`xz -6`) | 13.37 (`wavpack -hh -x4`) | 16.93 | 14.63 | 13.95 | 13.39 | LPC 482 |
| rec_vinyl_192k | 24 192k stereo | 18.30 (`xz -6`) | 6.24 (`wavpack -hh -x4`) | 17.96 | 12.36 | 9.04 | 5.75 | LPC 1876 |

</details>

- Silence costs 1 bit per sample under any Huffman or Rice code, because a prefix code spends at least one bit on every symbol. Constant blocks bring it to 0.04, 0.03 of it group framing.
- Exact repeats: 1 kHz waveforms and sines at every rate and integer depth cost 0.05 to 0.13 bits per sample through the delay into earlier samples, 0.03 of it group framing. General-purpose compressors stay smaller by 0.04 on the sine, triangle and sawtooth, and by 0.13 and 0.06 on the square wave and the impulse train.
- `rec_piano` contains 16-bit audio in 24-bit samples. With shared low bits removed and linear prediction it costs 3.67, against 3.79 for `flac -8` and 12.22 for fixed predictors with Rice codes, which keep the low bits.
- `rec_orchestra_f32` converts exactly to integers over 2^23 and costs what the integer file costs, 13.82. The float sine does not convert; its bit patterns repeat, and the delay takes it to 0.36, against 9.44 for WavPack, the only audio codec here that accepts float.
- Pink noise splits its blocks between tiers and linear prediction at every rate and integer depth, 12.87 bits against 13.08 for fixed predictors. Pink noise has the same spectral slope at every time scale and each tier predicts at one scale, which seems the likely reason.
- Tiers alone, as first described, cost 1.5 to 7.9 bits more than first differences on every recording. Offsets grow with distance from the group start, and coarser tiers hold samples further apart in time.
- Linear prediction wins most blocks of every recording. The block codec is smaller than every tool on 8 kHz speech, both piano recordings, the electronic track and the 192 kHz vinyl rip, and 0.01 to 0.07 bits above the best audio codec on the other five. WavPack `-hh -x4` adapts its prediction sample by sample where the block codec fixes one predictor per block, which seems the likely source of that gap.
- Stereo modes take 1.11 bits off the electronic track and 0.19 off speech. Split blocks take 0.28 bits off 8 kHz speech and 0.98 off the float sine.
- Level 5's adaptive stage takes the piano from 3.67 to 3.52 bits per sample and the corpus from 7.059 to 7.046. It is kept only where it saves one bit per 64 samples, because the decoder pays its taps on every sample of such a block. The 192 kHz vinyl then decodes in 162 s in Ada against 0.94 s at level 4.
- Dither and white noise are smallest under the block codec, 1.78 and 15.06 bits per sample.

### Gain per part

Mean bits per sample over each group of files, measured on the whole corpus as each part joined the block codec. The base contains constant blocks, shared low bits, polynomial orders 0 to 4, the delay within a block, tiers, and Rice and run-length codes, in blocks of 4096 samples with 32-bit byte lengths.

| Block codec | Generated signals | Sample-rate sweep | Bit-depth sweep | Recordings | Whole corpus |
|---|---|---|---|---|---|
| Base | 4.48 | 6.62 | 10.51 | 11.36 | 7.98 |
| and linear prediction | 3.95 | 6.62 | 10.45 | 10.55 | 7.60 |
| and the delay into earlier samples | 3.48 | 6.51 | 9.35 | 10.55 | 7.17 |
| and stereo modes | 3.48 | 6.51 | 9.35 | 10.41 | 7.14 |
| and split blocks, with 16-bit byte lengths | 3.47 | 6.51 | 9.24 | 10.35 | 7.10 |

### Levels

The encoder searches at six levels, and every level writes the same format, so one decoder reads them all.

Two estimates replace exhaustive search at the low levels. The order estimate picks the order whose Levinson-Durbin prediction error implies the fewest bits, 0.5 (n - p) log2(error) + 15p for order p over n samples. The stereo estimate picks the mode whose summed absolute second differences have the least summed logarithm. Ada and Haskell compute that logarithm from the exponent and a fixed polynomial in the fraction, so they choose the same orders and modes.

| Level | Search | Mean bits per sample | Coded corpus | Of PCM | Encode, Ada, 1 thread | Decode, Ada | Encode, Haskell, 16 threads | Decode, Haskell |
|---|---|---|---|---|---|---|---|---|
| 0 | 4096-frame blocks; polynomial, delay and tiers; left and right | 7.551 | 47.50 MB | 40.3% | 7.3 s | 2.42 s | 5.24 s | 1.17 s |
| 1 | and 1 estimated order of linear prediction at 15 bits; stereo mode estimated | 7.212 | 42.88 MB | 36.4% | 11.2 s | 2.78 s | 2.47 s | 0.75 s |
| 2 | and 2 orders, precisions 12 to 15; blocks down to 2048; the adaptive binary code | 7.118 | 42.37 MB | 36.0% | 33.7 s | 6.12 s | 6.13 s | 1.89 s |
| 3 | and 4 orders, precisions 9 to 15; blocks down to 1024; every stereo mode coded | 7.086 | 42.08 MB | 35.7% | 101.4 s | 6.71 s | 24.11 s | 2.74 s |
| 4 | and every order and precision 5 to 15; blocks down to 512 | 7.059 | 41.97 MB | 35.6% | 181.3 s | 5.68 s | 63.13 s | 1.83 s |
| 5 | and the adaptive stage after linear prediction, every tap count and warm-up | 7.046 | 41.71 MB | 35.4% | 1876.7 s | 546.53 s | 994.24 s | 38.08 s |

Level 1 encodes the corpus 16 times faster than level 4 in Ada, 11.2 s against 181.3 s, for 2.2% more bytes. Level 3 comes within 0.3% of level 4 in 56% of its time.

Levels 0 and 1 leave the adaptive binary code out, so their streams decode in 2.4 and 2.8 s in Ada. From level 2 the encoder takes it wherever it is shorter, and the decoder pays 5.7 to 6.7 s for the corpus, a range decoder step per modeled bit. Level 5 takes 0.6% of the bytes off level 4 and multiplies the decoder's time by about 96 in Ada and 21 in Haskell, where only blocks that train on earlier samples wait for one another.

Times are single runs on a typical workstation (AMD Ryzen 7 7700X). `levels.sh` produces the table and `results/levels.txt`, every file at every level, and checks that Ada and Haskell write the same bytes.

### Side information

Bits of the level-4 streams by role, from the `bits:` line of `codec_main`. Side information takes 1.5% of all bits, 0.4% of it group framing, which `docs/container.md` measures against the previous layout. Coding LPC coefficients in Rice or Exp-Golomb codes, with a parameter per block, would save 0.02% of all bits and loses on speech. Coding the LPC warm-up from samples before the block, at the block's residual rate, would save 0.26%, and 0.36% on recordings.

| Files | Headers | LPC coefficients | LPC warm-up | Code tables | Framing | Residuals |
|---|---|---|---|---|---|---|
| Generated signals | 0.16% | 0.30% | 0.28% | 0.22% | 1.07% | 97.97% |
| Sample-rate sweep | 0.09% | 0.03% | 0.07% | 0.04% | 0.57% | 99.19% |
| Bit-depth sweep | 0.06% | 0.01% | 0.06% | 0.10% | 0.41% | 99.36% |
| Recordings | 0.07% | 0.64% | 0.77% | 0.02% | 0.24% | 98.26% |
| Whole corpus | 0.08% | 0.46% | 0.55% | 0.05% | 0.40% | 98.45% |

### Timing

Whole corpus, 44,883,000 samples, at level 4 with per-block CRCs, on an AMD Ryzen 7 7700X with 8 cores and 16 threads. Each stream is hashed, and every implementation at every thread count writes all 40 streams byte for byte the same as Ada. `bench.sh` produces the table.

<details>
<summary><b>Encode and decode times by implementation and thread count</b> (9 rows)</summary>

| Implementation | Threads | Encode | Decode |
|---|---|---|---|
| Ada and SPARK (`codec_main`, assertions on) | 1 | 186.09 s | 5.90 s |
| Haskell | 1 | 266.93 s | 7.96 s |
| Haskell | 4 | 89.72 s | 2.94 s |
| Haskell | 8 | 57.32 s | 1.66 s |
| Haskell | 16 | 52.77 s | 1.81 s |
| Haskell + SPARK library | 1 | 226.43 s | 4.31 s |
| Haskell + SPARK library | 4 | 62.39 s | 1.49 s |
| Haskell + SPARK library | 8 | 52.32 s | 1.25 s |
| Haskell + SPARK library | 16 | 36.04 s | 0.91 s |

</details>

The encoder codes every node of each group's split tree, up to 15 blocks per group per signal, and tries every predictor, 32 orders of linear prediction and 11 coefficient precisions on each block. In the run that added it, the adaptive binary code cost the Ada encoder 11% and the Ada decoder 2.3 s, 2.70 s to 5.03 s. The decoder runs a range decoder step per modeled bit against a count of leading zeros per value.

Haskell decodes every block that does not reach back before itself in parallel. Pure Haskell times at 16 threads vary between runs, 59.56 s and 40.57 s in two runs of an earlier build, while Ada moved by 0.3 s.

`tool_timing.sh` times `flac`, `wavpack` and the release build of `stream_encode` and `stream_decode`, on one thread, one file at a time. Each tool's decoder writes a WAV file, and its samples are checked against the input's. FLAC does not code 32-bit float, so the table sums every file but the three float ones.

<details>
<summary><b>Size and time against FLAC and WavPack</b> (13 rows)</summary>

| Method | Bytes | Encode | Decode |
|---|---|---|---|
| `flac -0` | 50,031,889 | 0.42 s | 0.46 s |
| `flac -5` | 45,629,256 | 0.67 s | 0.48 s |
| `flac -8` | 44,873,757 | 1.45 s | 0.48 s |
| `wavpack -f` | 52,969,614 | 0.59 s | 0.32 s |
| `wavpack` | 52,446,880 | 0.72 s | 0.37 s |
| `wavpack -hh` | 52,082,680 | 1.10 s | 0.57 s |
| `wavpack -hh -x4` | 43,358,134 | 12.26 s | 0.65 s |
| `stream_encode --level 0` | 42,436,904 | 2.78 s | 1.23 s |
| `stream_encode --level 1` | 37,914,752 | 4.72 s | 1.42 s |
| `stream_encode --level 2` | 37,462,799 | 15.54 s | 2.32 s |
| `stream_encode --level 4` | 37,109,813 | 110.49 s | 2.58 s |
| `stream_encode --level 4`, every processor | 37,109,813 | 15.98 s | 2.34 s |
| `stream_encode --level 5`, every processor | 36,886,433 | 96.32 s | 9.48 s |

</details>

Level 0 is smaller than every FLAC and WavPack mode and encodes in 2.78 s, against 1.45 s for `flac -8` and 12.26 s for `wavpack -hh -x4`. Its decoder takes 1.23 s, against 0.48 s for `flac -d` on `flac -8` streams. From level 2 the range decoder doubles that.

Coding groups on all 16 threads, level 4 encodes in 15.98 s against 110.49 s on one, to the same bytes. Level 5 is 0.6% smaller than level 4 and decodes in 9.48 s, about four times as long, since its adaptive filter does up to 256 multiply-adds per sample where it is kept. WavPack without `-x` is larger than `flac -0` here: the 192 kHz recording alone costs 4.9 MB more than with `-x4`.

The release build leaves out run-time checks and assertions and inlines across units at `-O3`. Its streams and decoded files are identical to the checked build's. Over the whole corpus at level 0 on one thread, best of three runs, release `stream_encode` takes 2.51 s against 3.54 s for the checked build, and `stream_decode` 1.32 s against 1.88 s.

Haskell uses unboxed vectors whose loops fuse, strict unpacked writer state, `countLeadingZeros` for unary and bit-length codes, and decoding from a 32-bit peek. Parallelism comes from sparks over pure functions, so output cannot depend on scheduling. Executables run with `-N -A4m`; a 4 MB allocation area measured faster than 64 MB.

### Sizes

Installed sizes of the tools compared, and this work's binaries. Decoder rows cover `Block_Codec.Decode`, `Canonical_Decoding.Decode`, `Checksums`, `Range_Coding` and the bit reader, built with GNAT 16.1 for `arm-eabi` and the `light-cortex-m4` runtime, each unit with `-ffunction-sections` and sections summed by subprogram role. Tool rows include encoders, containers and front ends. `docs/decoder-cost.md` has the method and what each part added; `sizes.sh` produces the tool table.

<details>
<summary><b>Tools</b> (9 rows)</summary>

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

</details>

<details>
<summary><b>This work</b> (10 rows)</summary>

| Binary | Bytes |
|---|---|
| Block decoder with CRC and adaptive code, Cortex-M4 Thumb-2, `-Os`, run-time checks on | 10,048 code |
| Same, `-Os -gnatp` (checks the proof makes redundant) | 7,668 code |
| Block decoder before the adaptive code, measured the same way, `-Os -gnatp` | 6,316 code (8,396 with checks on) |
| Block encoder with the adaptive code, Cortex-M4 Thumb-2, `-Os -gnatp` | 11,328 code, plus libgcc's software double precision |
| Read-only data of the five units, `-Os -gnatp` | 521 (637 with checks on) |
| `libblockcodec.so`, x86-64, stripped, Ada runtime included, blocks and streams | 777,816 |
| `codec_main`, x86-64, stripped, needs only libc | 777,984 |
| `stream_decode`, x86-64, stripped, needs only libc | 670,528 |
| `huffman-audio`, Haskell, x86-64, stripped, needs libgmp | 6,543,248 |
| `huffman-audio-hybrid`, x86-64, stripped, needs `libblockcodec.so` and libgmp | 6,495,776 |

</details>

### Wider corpus

`extra.sh` codes each file of `corpus/extra/` at levels 0, 2 and 4 with the release programs, decodes it and compares the file byte for byte. It also checks that Ada, Haskell and the hybrid write one stream at level 4. Every file came back byte for byte, and the three implementations agreed on each.

Level 4 is smaller than `flac -8` on every file. It is smaller than `wavpack -hh -x4` on the quartet, birds, organ and rain, and larger by 0.02 bits per sample on the choir and the launch. Over all six, level 4 codes 16,240,064 bytes against 16,530,608 for `flac -8` and 16,380,392 for `wavpack -hh -x4`.

<details>
<summary><b>Bits per sample on the wider corpus</b> (6 rows)</summary>

| File | Format | Level 0 | Level 2 | Level 4 | `flac -8` | `wavpack -hh -x4` |
|---|---|---|---|---|---|---|
| `extra_birds` | 24 48k stereo | 19.69 | 17.81 | 17.79 | 17.99 | 18.02 |
| `extra_choir` | 24 48k stereo | 17.17 | 16.45 | 16.43 | 16.50 | 16.41 |
| `extra_launch` | 16 44.1k stereo | 6.00 | 5.55 | 5.52 | 5.60 | 5.50 |
| `extra_organ` | 16 44.1k stereo | 7.63 | 7.15 | 7.10 | 7.27 | 7.23 |
| `extra_quartet` | 24 48k stereo | 16.08 | 12.68 | 12.47 | 12.62 | 12.49 |
| `extra_rain_mp3` | 16 48k stereo | 10.71 | 9.39 | 9.39 | 9.94 | 9.64 |

</details>

### Proof

gnatprove 15.1 at level 2 proves the block decoder, `Canonical_Decoding`, `Checksums`, `Range_Coding` and `Bit_Streams` free of run-time errors for any input content, given preconditions on buffer bounds and the range of earlier samples. Every check is proved.

The provers bound the sum of 32 products of a 16-bit coefficient and a 33-bit sample, and of 256 products of a 16-bit weight and a 38-bit residual, from loop invariants alone. The range decoder's product of a 20-bit step and a 12-bit probability is bounded by a chain of assertions in signed arithmetic. The encoder is outside SPARK. `docs/decoder-cost.md` lists the checks by kind.

## Hardware notes

- Blocks decode with no table from an earlier block, so blocks that do not reach back before themselves can go to separate decoder lanes, given the byte lengths in the group table. A block that reaches back needs the 16,384 samples before it, a window of 16,384 by 33 bits, about 528 Kbit, as an LZ77 decoder keeps its last output.
- Decoder state: residuals, samples and a tier buffer, 4096 64-bit words each, about 96 KB, plus a run-length table of up to 1024 symbols. Smaller blocks shrink this in proportion.
- Canonical decoding keeps the first code and count of each length and no tree: one bit per step, or the next 32 bits compared against the first code of each length in parallel, in one step.
- Constant check, shared-low-bit removal and delay search are comparisons and shifts; Rice decoding is a count of leading zeros and a shift; polynomial, delay and tier predictors need additions and shifts. Linear prediction needs one multiply-accumulate per coefficient per sample, 12.3 million per second for order 32 on 192 kHz stereo (32 × 192,000 × 2).
- CCSDS 121.0-B-3 standardizes Rice coding of this kind for spacecraft data, with a zero-block option for long runs of zeros.

## Build and run

GNAT 15.2 and gprbuild 25.0.1 (for example from Alire's toolchains) on the PATH, stack with the `lts-21.25` resolver, gnatprove 15.1, flac and ffmpeg:

    corpus/make_corpus.sh          # rebuilds corpus/ from source (the committed files are the reference)
    ./run.sh                       # builds everything, runs every coder, writes results/
    ./compare.sh && ./bench.sh     # common lossless tools, and the timing of the three implementations
    ./levels.sh                    # every file at every encoder level, in Ada and Haskell
    (cd ada && gprbuild -P huffman_audio.gpr -XBUILD=release)   # programs without run-time checks, in ada/obj-release
    ./tool_timing.sh               # flac, wavpack and the release programs on one thread
    ./tables.sh > results/tables.md
    cd ada && gnatprove -P huffman_audio.gpr --level=2 -u bit_streams.adb canonical_decoding.adb checksums.adb range_coding.adb block_codec.adb

Input is WAV, RF64, Wave64 or AIFF, 8 to 32-bit integer, 32-bit float, or 64-bit float whose samples are exactly 32-bit floats. `codec_main <file.wav> <level>`, `huffman-audio <file.wav> --block <level>` and `huffman-audio-hybrid <file.wav> <level>` take the level, 4 when left out. The hybrid executable finds the SPARK library through `LD_LIBRARY_PATH=ada/lib`, which `run.sh` and `bench.sh` set. `codec_main` also takes:

| Option | Effect |
|---|---|
| `--stream <out.bin>` | write the stream to a file |
| `--tag <key=value>` | add a metadata tag |
| `--seek-every <seconds>` | seek point and segment length, 10 when left out, 0 for one segment |
| `--independent` | make every group a segment |
| `--seek <frame>` | decode again from that frame's seek point after the full decode |
| `--flip <group> <byte>` | damage one bit before decoding |
| `--no-pairs` | code every channel alone |
| `--features <out.tsv>` | write each group's features and whether the search split its root |

`stream_encode [--level <0 to 5>] [--tag <key=value>] [--seek-every <seconds>] [--independent] [--no-pairs] [--threads <n>] [--verify] <in.wav> <out.bin>` codes a file into a stream, byte for byte the stream `codec_main --stream` writes. It codes groups on every processor, or on `--threads` of them, and the stream is the same for any count. Either program takes `-` for standard input or output. With `--verify` it decodes the stream before writing it and checks every frame against the audio MD5. On a mismatch it writes nothing and exits with status 1.

`stream_decode <stream.bin> <out.wav>` reads a stream from its own bytes and writes the input file back, container, chunks and samples byte for byte (`docs/container.md`). It decodes group by group and keeps only the history later blocks may read, so its memory does not grow with the audio's length.

Exit status 0 means the stream was intact. Status 1 means damage: frames of unreadable groups, and blocks that did not decode, are written as zeros and counted on stderr. Status 2 means the file is not a readable stream.

### C interface

`include/blockcodec.h` declares the library's C interface, API version 1. `blkc_encode` codes interleaved integer samples into a stream, `blkc_read_info` reads a stream's header, and `blkc_decode` decodes a stream with a damage report. `block_encode` and `block_decode` code one block, as the Haskell hybrid calls them. Every call is independent, so calls may run on many threads at once.

    (cd ada && gprbuild -P codec_lib.gpr)      # ada/lib/libblockcodec.so, Ada runtime included
    cc -Iinclude app.c -Lada/lib -lblockcodec

Float streams decode with status `BLKC_UNSUPPORTED` in API version 1. `capi/check.sh` builds `capi/api_test.c` against the header and checks the library's exported functions against `capi/symbols.txt`, so a changed interface fails the tests before it reaches a release.

## References

- RFC 1951, DEFLATE: canonical Huffman codes, section 3.2.2. https://www.rfc-editor.org/rfc/rfc1951
- puff.c in zlib: canonical decoding from the counts of each length. https://github.com/madler/zlib/blob/develop/contrib/puff/puff.c
- RFC 9639, FLAC: fixed predictors, Rice codes, and wasted bits. https://www.rfc-editor.org/rfc/rfc9639
- ITU-T T.81 (JPEG), section F.1.2.2: run-length and size symbols for AC coefficients.
- CCSDS 121.0-B-3, Lossless Data Compression, 2020.
- D. A. Huffman, "A Method for the Construction of Minimum-Redundancy Codes", Proceedings of the IRE 40(9), 1952.

## License

Code, documentation and corpus are licensed separately: code under MIT, documentation and `results/` tables under CC BY 4.0, generated test signals under CC0 1.0, and recording excerpts under their sources' public-domain or CC0 status, listed in the corpus table above. `LICENSING.md` states this with its reasoning; `LICENSE` contains the MIT text and `LICENSES/` the other two.
