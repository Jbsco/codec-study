# Contributing

## Building and testing

Three gates run locally and in CI, each as one script from the repository root:

    bash style.do     # Ada warnings, Haskell warnings, local paths in tracked text, prose rules
    bash test.do      # CRC and container tests, three implementations equal at every level
    bash prove.do     # SPARK proof of the decoder, every check proved

Toolchain: GNAT and gprbuild from Alire (`cd ada && alr -n update && eval "$(alr -n printenv)"`), gnatprove 15.1, stack with the `lts-21.25` resolver, flac and ffmpeg. Green locally means green in CI, since the workflows run the same scripts.

`run.sh`, `bench.sh`, `levels.sh`, `segments.sh`, `multichannel.sh` and `tables.sh` regenerate `results/`. A change to the format or to the encoder search refreshes the results it affects and the numbers quoted in `README.md` and `docs/`.

## History model

`main` is a ladder of merge commits, one per pull request, with each PR's commits stemming from the previous merge. Branch from current `origin/main` and rebase onto it before merging. PRs merge as merge commits only, never squashed or rebased through GitHub. Checks pass on the final commit before a merge. Commits are GPG-signed, and review requests route to the maintainer through `.github/CODEOWNERS`.

## Commit and PR register

- Commit subjects: one line, imperative, capital first letter, no trailing period, no article, no body. A subject that needs "and" is two commits.
- PR bodies: one lead line saying what the change does, bullets of bare nouns for its parts, one verification line naming the gates and measurements run.
- Prose: one idea per paragraph under 100 words, bullets starting with nouns, "the" under 8 per 100 words, no em dashes, no reference to a session or a date in tracked text. `tools/prose_check.py` enforces the measurable part through `style.do`.

## Content rules

- Corpus files come from public-domain or CC0 sources only, stay under 8 MB each, and enter `corpus/make_corpus.sh`, `corpus/SHA256SUMS` and the README's corpus table with source and license. Generated signals are CC0, code is MIT, documentation is CC BY 4.0 (`LICENSING.md`).
- Methods are measured before they are built: exact bit counts on the corpus, against the format's best existing code or predictor per block, with side information counted. A method under 0.1 percent is not built.
- Numbers in `README.md` and `docs/` state their conditions: level, corpus, machine, single run or mean. Encoder time, decoder time and decoder size are reported together with a format change.
- Ada, Haskell and the hybrid write the same bytes on every corpus file at every level; `test.do` and `levels.sh` check this, so a change to one implementation lands with its match in the others.
- No local paths, private material or references to other projects in tracked files.

## Issues

An issue names the file (or a way to make it), the level, the command run, and what was expected against what was observed. For a decode mismatch, the output of `codec_main <file> <level>` with its `round trip` line is enough to start.
