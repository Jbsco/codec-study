# Integrity

## Method

The stream carries a CRC-16 of its header and index, and a CRC-16 of every block beside the block's length in the table at the head of the stream. The CRC is CRC-16/CCITT-FALSE: polynomial 0x1021, most significant bit first, initial value 0xFFFF, no reflection and no final exclusive or. The check value of "123456789" is 0x29B1. It is computed over bytes and knows nothing of audio.

A decoder checks each block's CRC before decoding it. A block with a bad CRC is reported by position; it is still the block's own length, so the blocks after it decode as usual. One damaged block costs one block. The header CRC covers the frame count, the channel layout and the split trees, which the block table's layout depends on, so damage there is found before any block is read.

## Measured

- Cost: 0.003 bits per sample over the corpus (7.095 to 7.098 at level 4), two bytes per block and two for the header.
- `checksums_test`: the check value, the bitwise form against the table form on every prefix of 4096 pseudo-random bytes, one flipped bit changing the result, and two ranges in sequence equalling the whole, 4099 of 4099 checks.
- `corrupt_test` on a written stream: every CRC matches as written; a flipped bit in the header fails the header CRC and no block CRC; a flipped bit in block 0 fails block 0's CRC and leaves block 1's and the header's matching. 6 of 6 checks on a 40-block mono stream and a 470-block stereo stream.
- Proof: the `Checksums` package proves at gnatprove level 2 with the decoder, no check unproved.

## Cost

Software: one table lookup per byte, 512 bytes of table. The same polynomial as one combinational step is 24 exclusive-ors at depth 3 per byte (a measured netlist, checked against the table on all 2^24 state-and-byte pairs), which is the form for fabric where many independent streams are checked at once; for one stream in software the table stays fastest, 1.7 ns per byte against 24 ns for the network as a scalar call.

## Beyond audio

Per-block CRCs are a format decision, not an audio one, and they change the failure mode of any compressed stream: without them, one bad bit corrupts every block after it, because a prefix code loses synchronization; with them, damage is contained and located. For a stream kept in two copies, the decoder can take each block from whichever copy passes its CRC. The block length in the table is what makes this work, and it is the same length that lets blocks decode in parallel.
