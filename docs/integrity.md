# Integrity

## Method

The stream carries a CRC-16 of its header, a CRC-16 of each group's framing (its sync word, length, first frame, frame count, split tree and block table) and a CRC-16 of every block beside the block's length in its group's table. The CRC is CRC-16/CCITT-FALSE: polynomial 0x1021, most significant bit first, initial value 0xFFFF, no reflection and no final exclusive or. The check value of "123456789" is 0x29B1. It is computed over bytes and knows nothing of audio.

A decoder checks each block's CRC before decoding it. A block with a bad CRC is reported by position; it is still the block's own length, so the blocks after it decode as usual. One damaged block costs one block. A group whose framing fails its CRC is skipped: the decoder scans forward for the next sync word whose framing passes, reads that group's first frame, and counts the frames between as lost. One damaged length or tree costs one group. Blocks later in the same segment that read the lost samples decode to wrong values without a CRC failure; the next seek point starts a segment that reads nothing before it, so it is exact again, and with every group a segment (`--independent`) the damage stops at the lost group. The header CRC covers the frame count, the channel layout and the seek table, so damage there is found before any group is read.

## Measured

- Cost: 0.003 bits per sample over the corpus (7.095 to 7.098 at level 4) for the two bytes per block and two for the header; the group CRC is two of the 15 bytes per group that framing costs (`container.md`).
- `checksums_test`: the check value, the bitwise form against the table form on every prefix of 4096 pseudo-random bytes, one flipped bit changing the result, and two ranges in sequence equalling the whole, 4099 of 4099 checks.
- `corrupt_test` on a written stream: every CRC matches as written, the groups are contiguous and end at the file's end, and every seek point names a group; a flipped bit in the header fails the header CRC; a flipped bit in group 0's length fails that group's CRC and group 1 is found again by its sync word and CRC at its own offset; a flipped bit in block 0 fails block 0's CRC and leaves block 1's and group 0's matching. 12 of 12 checks on a 40-group mono stream.
- `codec_main rec_speech_8k.wav 1 --independent --flip 3 2` (a bit of group 3's length): 1 group failed, 4096 frames lost, 0 samples wrong outside them, and a seek to frame 100000 after the damage still matches. Without `--independent` the groups after it in the same 10 s segment read the lost samples and decode wrong until the next seek point.
- Proof: the `Checksums` package proves at gnatprove level 2 with the decoder, no check unproved.

## Cost

Software: one table lookup per byte, 512 bytes of table. The same polynomial as one combinational step is 24 exclusive-ors at depth 3 per byte (a measured netlist, checked against the table on all 2^24 state-and-byte pairs), which is the form for fabric where many independent streams are checked at once; for one stream in software the table stays fastest, 1.7 ns per byte against 24 ns for the network as a scalar call.

## Beyond audio

Per-block CRCs are a format decision, not an audio one, and they change the failure mode of any compressed stream: without them, one bad bit corrupts every block after it, because a prefix code loses synchronization; with them, damage is contained and located. For a stream kept in two copies, the decoder can take each block from whichever copy passes its CRC. The block length in the table is what makes this work, and it is the same length that lets blocks decode in parallel. The sync word and the group CRC add the next level: a damaged length, which would otherwise lose everything after it, loses one group, because the decoder can find the next group without trusting the one before it. What a lost group costs beyond itself is set by how far later blocks may read back, which is the segment length; a stream that must survive damage chooses it on purpose.
