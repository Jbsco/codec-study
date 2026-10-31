# Blocks and windows

## Method

The stream is coded in groups of 4096 frames. Each group's split tree halves it, down to 512 frames, where the halves cost fewer bits than the whole, index and lengths included. The tree is written in pre-order, one split bit per node that has its own second half, so a leaf costs one bit above its block. Each block has a 16-bit length and a 16-bit CRC in its group's table.

## Measured effect

Uniform block sizes, first codec, bits per sample over the corpus: 256 frames 8.74, 512 8.27, 1024 8.09, 2048 8.02, 4096 7.98. Smaller blocks cost more because every block repeats its header, its code table and its predictor's warm-up. A split only pays where signal statistics change inside the group.

The split tree, chosen per group by exact cost, on the current codec: 7.14 to 7.10 bits per sample. Speech splits most: at 8 kHz, 131 of its 200 blocks are 512 frames, and the file goes from 3.58 to 3.30. Noise files and most generated signals stay at 4096 throughout. The float sine goes from 1.31 to 0.33, because a split lets the repeat predictor cover the repeating part of a group and linear prediction the rest.

Searching the full tree codes 15 nodes per group at level 4. That search is most of the encode-time difference between levels 3 and 4, 100 s against 244 s in Ada over the corpus, for 0.016 bits per sample.

## Windows

Two windows appear in this codec, and they are different things. A block is the unit the decoder can decode on its own, and its length trades header cost against adaptation to local statistics. The history window is how far back a block may reference or train, 16,384 samples, and it trades decoder memory against matches and warm-up it makes possible.

Measurements say the predictor inside a block matters more than either window. Choosing the linear prediction order per block gained 0.38 bits per sample over the corpus. The split tree gained 0.04. The history window gained 0.42, almost all of it on periodic signals.

## Beyond audio

A split tree fits any stream whose statistics change on a scale smaller than the block, with the same header cost argument against going small. For a stream that must survive damage, the block is also the unit of loss: a bad block costs its own length and nothing after it, which is why each block here has its own CRC. On general binary data the history window's equivalent is the LZ window, and the same measurement applies: a larger window gains little past a few tens of kilobytes.
