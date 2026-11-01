# Repetition

Three kinds of block exploit exact structure before any prediction runs.

## Constant blocks

A block whose samples are all equal is one bit and the value. Silence costs 0.01 bits per sample instead of the 1.00 a prefix code needs.

## Shared low bits

When every sample in a block has the same number of zero low bits, the encoder removes them, codes the count in 5 bits, and the decoder shifts them back. `rec_piano` contains 16-bit audio in a 24-bit container, 8 zero bits in every sample; the 96 kHz piano has 6. Removing them takes `rec_piano` from 12.22 bits per sample under a fixed predictor with Rice codes to 3.68 with everything else. FLAC calls these wasted bits (RFC 9639).

## Delay to an exact repeat

The encoder looks for the smallest distance at which a block's first 32 samples repeat exactly, within the block or back into the 16,384 samples before it, and codes each sample as its difference from the sample that distance back. Within the block the distance takes 12 bits; into the history, a flag and 15 bits.

Measured: periodic test signals repeat exactly, and within one block the first codec took them to 0.05 to 1.43 bits per sample. General-purpose compressors reached 0.00 to 0.11 on the same files, because their matches span blocks. Reaching into earlier samples took the codec to 0.02 to 0.11: sines at every rate and depth to 0.02, and the FM tone, whose period of 4410 samples is longer than one block, from 3.54 to 0.03. This is the LZ77 idea at sample granularity, with one match per block instead of one per token.

## Cost

Constant check and shared-bit removal are comparisons and shifts. The repeat search compares 32 samples at each of up to 16,384 distances per block in the encoder; the decoder only reads back. A decoder that serves blocks with history references keeps the last 16,384 samples of each signal, 16,384 by 33 bits, about 528 Kbit, the same window an LZ77 decoder keeps.

## Beyond audio

Exact repetition is where general-purpose compressors get most of their gain on structured binary data: compiled code repeats call sequences and prologues, tables repeat row layouts, padding repeats zeros. A back-reference scheme with byte granularity, many matches per block and a window of 4 KB to 64 KB (LZ77, LZSS, LZ4, the first stage of DEFLATE) is the right form there, and the one-match-per-block form of this codec is not.

Window size trades the same way in both: a larger window finds more matches at the cost of decoder memory, and the gain flattens quickly, about one point from 4 KB to 64 KB on machine code in our measurements.
