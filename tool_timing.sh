#!/usr/bin/env bash
# Time FLAC, WavPack and the block codec's own programs over the corpus in one run, one file at a time on one
# thread, and level 4 once more with groups coded on every processor: encode to a file, decode it with the tool's
# own decoder, and check the decoded samples. Writes
# results/tool_timing.tsv, one line per method and file (bytes, encode and decode seconds, ok or unsupported),
# then prints totals over the files every method codes. Needs flac, wavpack, ffmpeg and the Ada programs built in
# release mode (gprbuild -P ada/huffman_audio.gpr -XBUILD=release).
set -uo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p results
out=results/tool_timing.tsv
printf 'method\tfile\tbytes\tencode_s\tdecode_s\tstatus\n' > "$out"

methods=("flac -0" "flac -5" "flac -8" "wavpack -f" "wavpack" "wavpack -hh" "wavpack -hh -x4"
         "block level 0" "block level 1" "block level 2" "block level 4" "block level 4 parallel")

now() { date +%s.%N; }

for wav in build/wav/*.wav; do
  name=$(basename "$wav" .wav)
  eval "$(ffprobe -v error -show_entries stream=codec_name -of default=nw=1 "$wav")"
  pcm=${codec_name#pcm_}
  ref=$(ffmpeg -v error -i "$wav" -f "$pcm" - | md5sum | cut -c1-32)
  for method in "${methods[@]}"; do
    rm -f "$work"/c.* "$work"/d.wav
    t0=$(now)
    case $method in
      flac*) coded="$work/c.flac"; $method -s -f -o "$coded" "$wav" 2> /dev/null ;;
      wavpack*) coded="$work/c.wv"; $method -q -y "$wav" -o "$coded" 2> /dev/null ;;
      block*parallel) coded="$work/c.bin"; ada/obj-release/stream_encode --level 4 "$wav" "$coded" 2> /dev/null ;;
      block*) coded="$work/c.bin"; ada/obj-release/stream_encode --threads 1 --level "${method##* }" "$wav" "$coded" 2> /dev/null ;;
    esac
    t1=$(now)
    case $method in
      flac*) flac -s -d -f -o "$work/d.wav" "$coded" 2> /dev/null ;;
      wavpack*) wvunpack -q -y "$coded" -o "$work/d.wav" 2> /dev/null ;;
      block*) ada/obj-release/stream_decode "$coded" "$work/d.wav" 2> /dev/null ;;
    esac
    t2=$(now)
    if [[ -s $coded && -s $work/d.wav ]] \
       && [[ $(ffmpeg -v error -i "$work/d.wav" -f "$pcm" - 2> /dev/null | md5sum | cut -c1-32) == "$ref" ]]; then
      status=ok
    else
      status=unsupported
    fi
    awk -v m="$method" -v f="$name" -v b="$(stat -c %s "$coded" 2> /dev/null || echo 0)" -v a="$t0" -v e="$t1" -v d="$t2" \
      -v s="$status" 'BEGIN { printf "%s\t%s\t%s\t%.3f\t%.3f\t%s\n", m, f, b, e - a, d - e, s }' >> "$out"
  done
  echo "$name done" >&2
done

# Totals over the files every method codes.
common='NR > 1 { ok[$2] += ($6 == "ok"); m[$1] = 1 }
  END { methods = 0; for (k in m) methods++; for (f in ok) if (ok[f] == methods) print f }'
awk -F'\t' "$common" "$out" > "$work/common"
echo "Totals over $(wc -l < "$work/common") files every method codes"
awk -F'\t' 'NR == FNR { keep[$1] = 1; next }
  FNR > 1 && ($2 in keep) { b[$1] += $3; e[$1] += $4; d[$1] += $5 }
  END { for (k in b) printf "%-18s %12d bytes  encode %8.2f s  decode %7.2f s\n", k, b[k], e[k], d[k] }' \
  "$work/common" "$out" | sort
