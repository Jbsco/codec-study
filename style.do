#!/bin/bash
# Style and hygiene gate: Ada warnings from a fresh compile under -gnatwa, Haskell warnings under -Wall -Werror,
# no local paths or private material in the tracked text, and prose that stays readable.
exec >&2
cd "$(dirname "$0")" || exit 1
FAIL=0

echo "== 1/4  Ada warnings"
if command -v gprbuild >/dev/null 2>&1; then
    OUT=$(cd ada && { gprbuild -f -P huffman_audio.gpr; gprbuild -f -P codec_lib.gpr; } 2>&1 | grep -v "sframe")
    N=$(printf '%s\n' "$OUT" | grep -c 'warning:')
    if [ "$N" != "0" ]; then
        echo "  $N warning(s):"
        printf '%s\n' "$OUT" | grep 'warning:' | sed 's/^/    /'
        FAIL=1
    else
        echo "  clean"
    fi
else
    echo "  gprbuild not found - skipped"
fi

echo "== 2/4  Haskell warnings"
if command -v stack >/dev/null 2>&1; then
    if (cd haskell && stack build --force-dirty 2>&1 | grep -E "arning|rror" | grep -v "ld-options"); then
        FAIL=1
    else
        echo "  clean"
    fi
else
    echo "  stack not found - skipped"
fi

echo "== 3/4  Tracked text"
HITS=$(git grep -n -E '/home/[a-z]|/var/tmp/claude' -- ':!corpus/*.flac' ':!corpus/*.wav' ':!style.do' | head)
if [ -n "$HITS" ]; then
    echo "  local paths in tracked files:"
    printf '%s\n' "$HITS" | sed 's/^/    /'
    FAIL=1
else
    echo "  no local paths"
fi

echo "== 4/4  Prose"
if python3 tools/prose_check.py README.md docs/*.md; then
    echo "  clean"
else
    FAIL=1
fi

[ "$FAIL" = 0 ] && echo "style: all checks clean"
[ -n "${3:-}" ] && [ "$FAIL" = 0 ] && touch "$3"
exit $FAIL
