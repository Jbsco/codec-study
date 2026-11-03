#!/usr/bin/env bash
# Decode every test vector with a decoder (ada/obj/blkc-decode when none is named) and compare its exit status and
# the MD5 of the file it writes with MANIFEST.tsv. The decoder takes <stream> <out.wav>. Exit status 1 on any
# difference.
set -uo pipefail
dec=$(realpath "${1:-$(dirname "$0")/../ada/obj/blkc-decode}")
cd "$(dirname "$0")" || exit 1
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
fail=0 n=0
while IFS=$'\t' read -r name status md5 _; do
  [ "$name" = vector ] && continue
  n=$((n + 1))
  got=0
  "$dec" "$name.blkc" "$work/d.wav" 2> /dev/null || got=$?
  sum=-
  [ -s "$work/d.wav" ] && sum=$(md5sum < "$work/d.wav" | cut -c1-32)
  rm -f "$work/d.wav"
  if [ "$got" != "$status" ] || { [ "$md5" != - ] && [ "$sum" != "$md5" ]; }; then
    echo "  $name: status $got, MD5 $sum; expected status $status, MD5 $md5"
    fail=1
  fi
done < MANIFEST.tsv
[ "$fail" = 0 ] && echo "  test vectors: every vector decodes as recorded"
exit $fail
