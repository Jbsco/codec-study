# Container

The stream is a header, then self-delimited groups of 4096 frames. A reader finds every part from the header alone, starts at any seek point without the groups before it, and finds the next group again after a damaged one.

## Layout

Header, in order:

| Field | Bits | Content |
|---|---|---|
| magic | 32 | `BLKC` |
| version | 8 | 1 |
| flags | 8 | bit 0: every group is a segment |
| rate | 32 | samples per second, 0 when unknown |
| frames | 32 | frames in the stream, 0 when unknown |
| channels, depth, float | 8 each | channel count, bits per sample, 1 for float input |
| mode, scale | 8 each, per channel, float input only | float samples as integers over 2^scale (mode 1) or as ordered bit patterns (mode 2) |
| metadata count | 8 | blocks that follow |
| metadata block | 8 + 24 + bytes | type, byte length, bytes: 1 tags, each a 16-bit length and a `key=value` string; 2 a seek table, each entry a 32-bit first frame and a 64-bit byte offset from the stream's start |
| CRC-16 | 16 | of every header byte before it |

Each group, in order:

| Field | Bits | Content |
|---|---|---|
| sync | 16 | `B1C5` |
| length | 24 | bytes from the sync word through the group's last block |
| first frame | 32 | the group's first frame |
| frames | 16 | frames in the group, up to 4096 |
| tree | padded to a byte | the split tree in pre-order: a split bit on every node that has its own second half, then on each leaf a 2-bit stereo mode per channel pair |
| block table | 32 per block | a 16-bit byte length and a CRC-16 per block, leaf by leaf and channel by channel |
| CRC-16 | 16 | of the group from its sync word through its block table |
| blocks | | the coded blocks in the table's order |

A segment is the span a block may read earlier samples from: one group when flag bit 0 is set, otherwise from one seek point to the next. The encoder writes a seek point every 10 s by default (`--seek-every <seconds>`, 0 for one segment and no table) and `--independent` makes every group a segment. The decoder needs no knowledge of segments: it hands every block the samples before it, and the encoder never referenced further back than the segment's start.

## Seeking

A seek to frame F starts at the last seek point at or before F and decodes groups until the one holding F. With every group a segment the decoder first skips group by group, reading each group's length, to the group holding F and decodes only that one. `codec_main <file> <level> --seek <frame>` does this after the full decode and compares the samples from F to the end of that group with the input.

## Damage

A decoder reads the header's CRC, then each group's. A group whose sync word, fields or CRC are wrong is skipped: the decoder scans forward for the next sync word whose group header passes its CRC, takes that group's first frame as the next frame it holds, and counts the frames between as lost. A block whose CRC fails is counted and decoded anyway. `codec_main <file> <level> --flip <group> <byte>` flips one bit of the written stream before decoding and reports what was lost, and `corrupt_test <stream.bin>` checks the same on a written stream, with the group found again after a damaged length. Within a segment, blocks after a lost group that read the lost samples decode to wrong values without a CRC failure; the next segment is exact again. With every group a segment the damage is contained to the lost group.

## Cost

Framing, measured at level 4 on the 40 files before the adaptive binary code, against the previous layout, which kept one index and one block table at the head of the stream: 116,233 bytes more over 7,755 groups, 15.0 bytes per group, 0.28 percent of the coded corpus. Of the 15 bytes, 11 are the group's fixed fields, 2 its CRC, and the rest the tree bits padded to a byte per group instead of once per stream, plus 12 bytes per seek point. The cost falls on short and small files: the 8 kHz pink noise gains 304 bytes, the 192 kHz vinyl 12,819, and the silent file goes from 1,548 bytes to 4,584, because its 216 groups each carry a frame that the stream coded in 7 bytes before. Framing is the price of a stream that can be read from the middle, written without knowing its length, and resynchronized after damage; a format for archives that are always read whole would keep the index at the head.

Seeking costs the decoder at most one segment: 10 s of audio at the default seek interval, 108 groups at 44.1 kHz, decoded and discarded before the frame asked for. With every group a segment the decoder skips to the group itself, reading each skipped group's header, and decodes one group: a seek to frame 100000 of the 8 kHz speech file skipped 4 groups from the nearest seek point and decoded 1.

The decoder holds one group's split tree and block table at a time, under 300 bytes for eight channels, where the previous layout held the whole index and table before decoding anything. The Haskell decoder still reads the whole stream into memory and decodes the history-free blocks of every group in parallel.

Segments, measured by `segments.sh` at level 4 on the 40 files, where a block may read earlier samples only within its segment:

| Segment | Bytes | Against one segment |
|---|---|---|
| one segment, no seek table (`--seek-every 0`) | 41,963,961 | |
| a seek point every 10 s, the default | 41,966,578 | +2,617, 0.006 percent |
| a seek point every 1 s | 42,037,486 | +73,525, 0.18 percent |
| every group a segment (`--independent`) | 42,731,273 | +767,312, 1.83 percent |

A seek point every 10 s costs nothing worth measuring, because few blocks reach more than 16,384 samples back and fewer start a segment. Every group its own segment costs 1.8 percent, which is what the history buys: the delay predictor's reach into earlier samples and the adaptive stage's warm-up on them, both of which the first blocks of every segment lose. A stream for random access or for links that drop data chooses between these by how much it must be able to lose at once.
