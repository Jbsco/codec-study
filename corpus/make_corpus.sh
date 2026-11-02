#!/usr/bin/env bash
# Build the test corpus: synthetic signals from their equations, and short segments of public-domain and
# CC0 recordings. Integer PCM is stored as FLAC, 32-bit float as WAV. Needs curl, ffmpeg and flac.
set -euo pipefail
cd "$(dirname "$0")"
src=source
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p "$src"

# Fetch URL to FILE, whole (checked against MD5) or only its first BYTES.
fetch() {  # file url md5|- [bytes]
  [[ -s $1 ]] && return
  mkdir -p "$(dirname "$1")"
  if [[ -n ${4:-} ]]; then curl -sSfL --retry 3 -r "0-$(($4 - 1))" -o "$1" "$2"; else curl -sSfL --retry 3 -o "$1" "$2"; fi
  [[ $3 == - ]] || echo "$3  $1" | md5sum -c --quiet
}

ia=https://archive.org/download
fetch "$src/musopen/goldberg_aria.flac" "$ia/MusopenCollectionAsFlac/Bach_GoldbergVariations/JohannSebastianBach-01-GoldbergVariationsBwv.988-Aria.flac" 853f9f9396946c3842ccbbcecf55a73d
fetch "$src/musopen/mozart_40_i.flac" "$ia/MusopenCollectionAsFlac/Mozart_SymphonyNo.40inGMinor/WolfgangAmadeusMozart-SymphonyNo.40InGMinorK.550-01-MoltoAllegro.flac" 3b38633a660b21573bb6b418a4c80214
fetch "$src/saint-hubert/ez_money_hd.flac" "$ia/dj-saint-hubert-misc-vol-1_202605/DJ%20Saint-Hubert%20-%20misc%20vol%201%20-%2001%20EZ%20Money%20HD%20%28not%20particularly%20finished%29.flac" 58650be277fa63a5099e0ef9584e6cf7
fetch "$src/aporee/metro_hotel_des_monnaies.wav" "$ia/aporee_73504_85910/20260919MtroHdesMIserDPA4060F14ZoomF3MtroHoteldesMonnaies.wav" f01e87dab958ef7da31ba92ca336cbb7
fetch "$src/nasa/sts31_highlights_head.flac" "$ia/Sts-31Highlights/Sts-31Highlights.flac" - 12582912
fetch "$src/pcmd1/somewhere_in_time_head.wav" "$ia/PCMD1_piano_1119013_Somewhere_In_Time_front_right_120127_9624/12012713_front_right_somewhere.WAV" - 26214400
fetch "$src/vinyl/you_forget_this_head.flac" "$ia/you-forget-this/Raw%20FLAC.flac" - 31457280

# Store WAV input as FLAC, or keep it as WAV for float.
store() {  # wav name
  if [[ $(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$1") == pcm_f32le ]]; then cp "$1" "$2.wav"
  else flac -8 -s -f -o "$2.flac" "$1"; fi
}

# A synthetic signal from an ffmpeg source filter, mono.
gen() {  # name seconds rate codec source
  ffmpeg -v error -y -f lavfi -i "$5" -bitexact -t "$2" -ar "$3" -ac 1 -c:a "$4" "$work/$1.wav"
  store "$work/$1.wav" "$1"
}

sine='0.5*sin(2*PI*1000*t)'
for r in 44100; do
  gen signal_silence 20 $r pcm_s16le "anullsrc=r=$r:cl=mono"
  gen signal_dither 20 $r pcm_s16le "anoisesrc=r=$r:c=white:a=0.000046:s=1"
  gen signal_white 20 $r pcm_s16le "anoisesrc=r=$r:c=white:a=0.5:s=2"
  gen signal_pink 20 $r pcm_s16le "anoisesrc=r=$r:c=pink:a=0.5:s=3"
  gen signal_brown 20 $r pcm_s16le "anoisesrc=r=$r:c=brown:a=0.5:s=4"
  gen signal_sine 20 $r pcm_s16le "aevalsrc=$sine:s=$r"
  gen signal_square 20 $r pcm_s16le "aevalsrc=0.5*(2*lt(mod(1000*t\,1)\,0.5)-1):s=$r"
  gen signal_triangle 20 $r pcm_s16le "aevalsrc=0.5*(4*abs(mod(1000*t+0.25\,1)-0.5)-1):s=$r"
  gen signal_sawtooth 20 $r pcm_s16le "aevalsrc=0.5*(2*mod(1000*t\,1)-1):s=$r"
  gen signal_impulses 20 $r pcm_s16le "aevalsrc=0.5*eq(mod(n\,4410)\,0):s=$r"
  gen signal_sweep 20 $r pcm_s16le "aevalsrc=0.5*sin(2*PI*20*20/log(1000)*(exp(t*log(1000)/20)-1)):s=$r"
  gen signal_fm 20 $r pcm_s16le "aevalsrc=0.5*sin(2*PI*440*t+3*sin(2*PI*110*t)):s=$r"
  gen signal_chord 20 $r pcm_s16le "aevalsrc=(sin(2*PI*220*t)+sin(2*PI*277.1826*t)+sin(2*PI*329.6276*t))/6:s=$r"
done
for r in 8000 16000 96000 192000; do
  gen "rate_sine_$r" 10 $r pcm_s16le "aevalsrc=$sine:s=$r"
  gen "rate_pink_$r" 10 $r pcm_s16le "anoisesrc=r=$r:c=pink:a=0.5:s=3"
done
for d in u8:8 s24le:24 s32le:32 f32le:32f; do
  gen "depth_sine_${d#*:}" 10 44100 "pcm_${d%%:*}" "aevalsrc=$sine:s=44100"
  gen "depth_pink_${d#*:}" 10 44100 "pcm_${d%%:*}" "anoisesrc=r=44100:c=pink:a=0.5:s=3"
done
gen depth_sine_12in16 10 44100 pcm_s16le "aevalsrc=floor(2048*$sine)/2048:s=44100"

# A segment of a recording at its own rate and depth.
cut() {  # name source start seconds [ffmpeg output options]
  ffmpeg -v error -y -ss "$3" -t "$4" -i "$2" -bitexact -map_metadata -1 "${@:5}" "$work/$1.wav"
  store "$work/$1.wav" "$1"
}
cut rec_piano "$src/musopen/goldberg_aria.flac" 20 20 -c:a pcm_s24le
cut rec_orchestra "$src/musopen/mozart_40_i.flac" 0 20 -c:a pcm_s24le
cut rec_orchestra_f32 "$src/musopen/mozart_40_i.flac" 0 20 -c:a pcm_f32le
cut rec_electronic "$src/saint-hubert/ez_money_hd.flac" 20 20 -c:a pcm_s24le
cut rec_room "$src/aporee/metro_hotel_des_monnaies.wav" 7 20 -c:a pcm_s24le
cut rec_speech "$src/nasa/sts31_highlights_head.flac" 0 20 -c:a pcm_s24le
cut rec_speech_16k "$src/nasa/sts31_highlights_head.flac" 0 20 -ac 1 -ar 16000 -c:a pcm_s16le
cut rec_speech_8k "$src/nasa/sts31_highlights_head.flac" 0 20 -ac 1 -ar 8000 -c:a pcm_u8
cut rec_piano_96k "$src/pcmd1/somewhere_in_time_head.wav" 10 20 -c:a pcm_s24le
cut rec_vinyl_192k "$src/vinyl/you_forget_this_head.flac" 20 20 -c:a pcm_s24le

sha256sum -- *.flac *.wav > SHA256SUMS
ls -l -- *.flac *.wav | awk '{s += $5} END {printf "%d files, %.1f MB\n", NR, s / 1e6}'
