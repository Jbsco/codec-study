# Test vectors

Streams in format version 2, as [docs/spec.md](../docs/spec.md) defines it, with what a decoder writes from each. `MANIFEST.tsv` lists every vector: its name, the exit status of `blkc-decode`, the MD5 of the file it writes, and what the vector covers. For intact vectors that includes the block kinds and stereo modes `codec_main` reported when the vector was written.

- Intact vectors decode with status 0 to their input file, byte for byte.
- Damaged vectors are copies of `split_tree.blkc` with one change each. Status 1 means damage was found and decoded around, with lost frames written as zeros. Status 2 means the stream was refused.
- Regression vectors are streams the fuzzer found that crashed an earlier decoder, kept as found.

To check a decoder that takes a stream and an output file:

    vectors/check.sh [decoder]      # ada/obj/blkc-decode when none is named

`make_vectors.sh` wrote the vectors from generated signals and short corpus excerpts, and checked that each intact vector decodes to its input. The committed streams are the reference: an encoder that searches differently writes other streams that decode to the same audio.
