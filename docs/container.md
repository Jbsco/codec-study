# Container

The stream is a header, then self-delimited groups of 4096 frames. A reader finds every part from the header alone, starts at any seek point without the groups before it, and finds the next group again after a damaged one.

## Layout

Header, in order:

| Field | Bits | Content |
|---|---|---|
| magic | 32 | `BLKC` |
| version | 8 | 2 |
| flags | 8 | bit 0: every group is a segment |
| rate | 32 | samples per second, 0 when unknown |
| frames | 64 | frames in the stream, 0 when unknown |
| channels, depth, valid bits, float | 8 each | channel count, bits per sample of the container, bits that carry audio with zeros below them, 1 for float input |
| channel mask | 32 | speaker positions as in WAV's extensible format, 0 when none was given |
| audio MD5 | 128 | MD5 of the input samples in FLAC's layout, zero when not recorded |
| mode, scale | 8 each, per channel, float input only | float samples as integers over 2^scale (mode 1) or as ordered bit patterns (mode 2) |
| metadata count | 8 | blocks that follow |
| metadata block | 8 + 24 + bytes | type, byte length, bytes: 1 tags, each a 16-bit length and a `key=value` string; 2 a seek table, each entry a 32-bit first frame and a 64-bit byte offset from the stream's start; 3 the source description below |
| CRC-16 | 16 | of every header byte before it |

Each group, in order:

| Field | Bits | Content |
|---|---|---|
| sync | 16 | `B1C5` |
| length | 24 | bytes from the sync word through the group's last block |
| first frame | 32 | index of the group's first frame |
| frames | 16 | frames in the group, up to 4096 |
| tree | padded to a byte | split tree in pre-order: a split bit on every node that has its own second half, then on each leaf a 2-bit stereo mode per channel pair |
| block table | 32 per block | a 16-bit byte length and a CRC-16 per block, leaf by leaf and channel by channel |
| CRC-16 | 16 | of the group from its sync word through its block table |
| blocks | | coded blocks in the table's order |

A segment is the span a block may read earlier samples from: one group when flag bit 0 is set, otherwise from one seek point to the next. The encoder writes a seek point every 10 s by default (`--seek-every <seconds>`, 0 for one segment and no table), and `--independent` makes every group a segment. The decoder needs no knowledge of segments: it hands every block the samples before it, and the encoder never referenced further back than the segment's start.

## Source file

Metadata block 3 describes the input file so a decoder can write it back byte for byte. It names the container in 8 bits: 1 RIFF WAV, 2 RF64, 3 BW64, 4 Wave64, 5 AIFF, 6 AIFF-C. The container's own size field follows in 64 bits, then a 16-bit count of chunks and every chunk in file order. Each chunk is its role and identifier length in 8 bits each, its identifier, the value of its own length field in 64 bits, its body length in 32 bits and its body.

| Role | Chunk | Body kept |
|---|---|---|
| 0 | any other chunk: LIST, bext, cue, iXML and the rest | whole |
| 1 | format: `fmt ` or `COMM` | whole |
| 2 | audio: `data` or `SSND` | what precedes the samples, AIFF's offset and block size |
| 3 | RF64's `ds64` size table | whole, its sizes rewritten on decode |

`stream_decode` writes the container and chunks back in order, the samples into the audio chunk, and every size field computed again. A size field that held 0 or all ones, as a program writing to a pipe leaves it, is written back as it was, so a file piped from ffmpeg also comes back byte for byte.

The decoder writes plain WAV when the stream has no description, or when the format chunk does not describe the decoded samples. Chunks other than format, audio and the size table are left out when all of them would not fit one 16 MB metadata block, and `codec_main` reports that.

## Audio MD5

The MD5 covers the samples as the input file held them, frames in order with channels interleaved. Each integer sample is shifted down to its valid bits and written little-endian in as many bytes as those bits need. Each float sample is its 32-bit pattern. This is FLAC's layout, so a FLAC file of the same audio records the same digest. `metaflac --show-md5sum` gives the stream's digest for every FLAC file of the corpus, and for a 20-bit file in 24-bit words.

Per-block CRCs show that coded bytes arrived intact. The MD5 shows that the decoder rebuilt the input: `stream_decode` checks the decoded audio against it and exits with status 1 on a difference.

Readers take version 2 only. Version 1 had a 32-bit frame count and no valid bits, channel mask or MD5. The header is 25 bytes longer for them.

## Seeking

A seek to frame F starts at the last seek point at or before F and decodes groups until the one holding F. With every group a segment, the decoder skips group by group, reading each group's length, to the group holding F and decodes only that one. `codec_main <file> <level> --seek <frame>` does this after the full decode and compares the samples from F to the end of that group with the input.

## Damage

A decoder reads the header's CRC, then each group's. A group whose sync word, fields or CRC are wrong is skipped. The decoder scans forward for the next sync word whose group header passes its CRC, resumes at that group's first frame, and counts the frames between as lost. A block whose CRC fails is counted and decoded anyway.

`stream_decode <stream.bin> <out.wav>` decodes this way from the stream's bytes alone, writes lost frames as zeros and exits with status 1 when anything was lost. A truncated stream decodes up to its last whole group. `codec_main <file> <level> --flip <group> <byte>` flips one bit of the written stream before decoding and reports what was lost. `corrupt_test <stream.bin>` checks the same on a written stream, with the group found again after a damaged length.

Within a segment, blocks after a lost group that read the lost samples decode to wrong values without a CRC failure. The next segment is exact again. With every group a segment, damage is contained to the lost group.

## Cost

Framing was measured at level 4 on the corpus before the adaptive binary code, against the previous layout with one index and one block table at the head of the stream. It added 116,233 bytes over 7,755 groups, 15.0 bytes per group, 0.28 percent of the coded corpus. Of the 15 bytes, 11 are the group's fixed fields, 2 its CRC, and the rest tree bits padded to a byte per group instead of once per stream, plus 12 bytes per seek point.

The cost falls on short and small files: the 8 kHz pink noise gains 304 bytes and the 192 kHz vinyl 12,819. The silent file goes from 1,548 bytes to 4,584, because its 216 groups each contain a frame the stream coded in 7 bytes before. Framing is the price of a stream that can be read from the middle, written without knowing its length, and resynchronized after damage. A format for archives that are always read whole would keep the index at the head.

Seeking costs the decoder at most one segment: 10 s of audio at the default seek interval, 108 groups at 44.1 kHz, decoded and discarded before the frame asked for. With every group a segment the decoder skips to the group itself, reading each skipped group's header, and decodes one group. A seek to frame 100000 of the 8 kHz speech file skipped 4 groups from the nearest seek point and decoded 1.

The decoder keeps one group's split tree and block table at a time, under 300 bytes for eight channels, where the previous layout held the whole index and table before decoding anything. The Haskell decoder still reads the whole stream into memory and decodes history-free blocks of every group in parallel.

Segments, measured by `segments.sh` at level 4 on the corpus, where a block may read earlier samples only within its segment:

| Segment | Bytes | Against one segment |
|---|---|---|
| one segment, no seek table (`--seek-every 0`) | 41,964,961 | |
| a seek point every 10 s, the default | 41,967,578 | +2,617, 0.006 percent |
| a seek point every 1 s | 42,038,486 | +73,525, 0.18 percent |
| every group a segment (`--independent`) | 42,732,273 | +767,312, 1.83 percent |

A seek point every 10 s costs nothing worth measuring, because few blocks reach more than 16,384 samples back and fewer start a segment. Every group its own segment costs 1.8 percent, which is what the history buys: the delay predictor's reach into earlier samples and the adaptive stage's warm-up, both lost by the first blocks of every segment. A stream for random access or for links that drop data chooses between these by how much it must be able to lose at once.
