# License

This repository licenses code, documentation and corpus separately, because each is a deliverable with a different kind of reuse.

| Part | License | Text |
|---|---|---|
| Code: `ada/`, `haskell/`, scripts at top level and in `corpus/`, build files, workflows | MIT | [`LICENSE`](LICENSE) |
| Documentation: `docs/`, `README.md`, measured tables in `results/` | CC BY 4.0 | [`LICENSES/CC-BY-4.0.txt`](LICENSES/CC-BY-4.0.txt) |
| Generated test signals: `corpus/signal_*`, `corpus/rate_*`, `corpus/depth_*` | CC0 1.0 | [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) |
| Test vectors: `vectors/*.blkc`, `vectors/MANIFEST.tsv` | CC0 1.0 for streams of generated signals; streams of recording excerpts keep their source's status | [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) |
| Recording excerpts: `corpus/rec_*` | each source's status, public domain or CC0 1.0, as listed in the README's corpus table | none added here |

SPDX identifiers: `MIT` for code, `CC-BY-4.0` for documentation, `CC0-1.0` for generated signals.

## Covered

Original work only: block codec and experiment coders in three implementations, contracts and proofs, scripts that build the corpus and run measurements, topic pages, README, and numbers in `results/`.

## Not covered

Recording excerpts in `corpus/rec_*` are 20 s cuts of recordings their archives mark as public domain (Public Domain Mark 1.0) or dedicate under CC0 1.0. Cutting and converting to FLAC adds nothing to license, so this repository adds no terms and claims none. The README's corpus table names each source and its mark, and `corpus/make_corpus.sh` fetches them again. Standards and papers in the README's references keep their own terms.

## Rationale

Code is a component. The SPARK decoder and encoder can go into other tools, on other data, with or without this study. MIT is the simplest permissive license for that, and the Alire crate already declares it.

Documentation is a record. Topic pages say what each method did to this corpus and what it cost. That writing is most useful when it can be quoted, excerpted and built on in other write-ups with provenance kept. CC BY 4.0 asks for attribution and nothing else.

Generated signals are test data. Noise, tones and sweeps made from ffmpeg expressions carry no authorship worth keeping. A CC0 dedication lets anyone put the same files in their own test set without a notice.
