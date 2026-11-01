# Compression topics

One page per aspect of the block codec, each with the method, its measured effect on the 40-file corpus, what it costs in the encoder and the decoder, and how it transfers to data that is not audio. Numbers come from `results/` as the top-level README describes them; a page names the run it reads from.

| Page | Topic | Effect on the corpus |
|---|---|---|
| [format.md](format.md) | every field of a block: predictors, residual codes, the encoder's choice | the format every level writes |
| [entropy-coding.md](entropy-coding.md) | Rice codes, run-length Huffman codes, the prefix-code floor, the parameter search | base of every block; silence 1.00 to 0.01 bits per sample with constant blocks |
| [prediction.md](prediction.md) | polynomial, tiered, linear (per-block order) and adaptive prediction | 7.98 to 7.60 bits per sample from linear prediction alone |
| [repetition.md](repetition.md) | exact repeats within a block and in earlier samples, shared low bits, constant blocks | periodic signals 1.2 to 4.2 bits per sample down to 0.02 to 0.11 |
| [blocks-and-windows.md](blocks-and-windows.md) | block length, split trees, the index, what a window buys | 7.14 to 7.10; speech gains most |
| [stereo.md](stereo.md) | left, right, mid and side modes per block, channel pairs beyond stereo | 1.11 bits per sample on the electronic track, 0.19 on speech |
| [side-information.md](side-information.md) | headers, coefficients, warm-up, tables, lengths; what entropy-coding them would save | 1.3 percent of all bits; coding the coefficients saves 0.02 percent |
| [levels.md](levels.md) | the search levels, estimates that replace exhaustive search, time against size | level 1 within 2.2 percent of level 4 at 19 times the speed; levels 0 and 1 decode in under 3 s |
| [integrity.md](integrity.md) | CRC-16 per block, per group and of the header, what damage it finds, finding the next group again | 0.003 bits per sample |
| [container.md](container.md) | the header, metadata, framed groups, seek points and segments; what framing and seeking cost | 15 bytes per group, 0.28 percent at level 4 |
| [float.md](float.md) | float samples as integers or as ordered bit patterns | float orchestra costs what the integer file costs |
| [decoder-cost.md](decoder-cost.md) | code size, memory, operations per sample, proof, parallel decoding | decoder 7.7 KB on a Cortex-M4; 629 proved checks |
| [learned-decisions.md](learned-decisions.md) | a gate network for an encoder decision, and why a rule won | the split decision is 4.9 percent of roots; a 2-bit spread rule matches the network |
