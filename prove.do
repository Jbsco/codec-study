#!/bin/bash
# SPARK proof gate over the decoder units. Counts unproved checks and pragma Assume occurrences on every run, so a
# weakened claim is visible immediately. Needs gnatprove on the PATH, or alr to supply it.
exec >&2
cd "$(dirname "$0")/ada" || exit 1
export TMPDIR="${TMPDIR:-/var/tmp}"
UNITS="bit_streams.adb canonical_decoding.adb checksums.adb range_coding.adb block_codec.adb"
if command -v gnatprove >/dev/null 2>&1; then
    RUN=gnatprove
elif command -v alr >/dev/null 2>&1; then
    RUN="alr -n exec -- gnatprove"
else
    echo "prove: gnatprove not found - skipping SPARK proofs"
    [ -n "${3:-}" ] && touch "../$3"
    exit 0
fi
echo "Running SPARK proofs on: $UNITS"
UNIT_ARGS=""
for unit in $UNITS; do UNIT_ARGS="$UNIT_ARGS -u $unit"; done
# The substitution exits with the status of gnatprove, not of tee.
PROVE_OUT=$($RUN -P huffman_audio.gpr -j"${PROVE_JOBS:-0}" -f --level=2 ${PROVE_SWITCHES:-} $UNIT_ARGS --output=oneline --output-header 2>&1 | tee >(cat >&2); exit "${PIPESTATUS[0]}")
EXIT_CODE=$?
# A unit that fails to compile is dropped from the analysis without a nonzero exit, so any error line fails the gate.
if [ $EXIT_CODE -eq 0 ] && printf '%s\n' "$PROVE_OUT" | grep -q ': error: '; then
    EXIT_CODE=1
fi
if [ $EXIT_CODE -ne 0 ]; then
    echo "=========================================="
    echo "SPARK proofs: gnatprove FAILED (exit $EXIT_CODE)"
    echo "=========================================="
    exit $EXIT_CODE
fi
SUMMARY=$(printf '%s\n' "$PROVE_OUT" | sed -n 's/^Summary logged in //p' | tail -1)
[ -z "$SUMMARY" ] && SUMMARY=obj/gnatprove/gnatprove.out
echo "=========================================="
if [ -f "$SUMMARY" ]; then
    TOTAL=$(awk '/^Total/ {print $2; exit}' "$SUMMARY")
    UNPROVED=$(awk '/^Total/ {print ($NF == "." ? 0 : $(NF - 1)); exit}' "$SUMMARY")
    ANALYZED=$(grep -c "flow analyzed" "$SUMMARY")
    if [ "$UNPROVED" = "0" ] && [ "$ANALYZED" -gt 0 ]; then
        echo "SPARK proofs: decoder 100% proved (${TOTAL:-?} checks, $ANALYZED subprograms analyzed)"
    else
        echo "SPARK proofs: $UNPROVED of ${TOTAL:-?} checks UNPROVED"
        exit 1
    fi
    ASSUMES=$(grep -h "pragma Assume" ./*.adb ./*.ads 2>/dev/null | wc -l)
    JUSTIFIED=$(grep -h "pragma Annotate (GNATprove" ./*.adb ./*.ads 2>/dev/null | wc -l)
    echo "  ($ASSUMES pragma Assume, $JUSTIFIED justified check(s))"
else
    echo "Summary file not found: $SUMMARY"
    exit 1
fi
echo "=========================================="
[ -n "${3:-}" ] && touch "../$3"
exit 0
