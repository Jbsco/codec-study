#!/usr/bin/env bash
# Build the C interface test against include/blockcodec.h and ada/lib/libblockcodec.so, run it, and compare the
# library's exported interface with symbols.txt, so a changed interface shows before a release.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pedantic -I../include api_test.c -L../ada/lib -lblockcodec -lm -o "$work/api_test" \
  2> "$work/build.log" || { echo "  C interface: build FAILED"; sed 's/^/    /' "$work/build.log"; exit 1; }
LD_LIBRARY_PATH=../ada/lib "$work/api_test" || exit 1
nm -D --defined-only ../ada/lib/libblockcodec.so | awk '$2 == "T" {sub(/@.*/, "", $3); if ($3 ~ /^(blkc|block)_/) print $3}' \
  | LC_ALL=C sort > "$work/symbols"
if cmp -s "$work/symbols" symbols.txt; then
  echo "  C interface: exported symbols match symbols.txt"
else
  echo "  C interface: exported symbols differ from symbols.txt:"
  diff symbols.txt "$work/symbols" | sed 's/^/    /'
  exit 1
fi
