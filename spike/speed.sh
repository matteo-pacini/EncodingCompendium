#!/usr/bin/env bash
# Spike steps 2–3: every host encodes the same segment with the 2160p
# script's John Wick settings at once (one progress bar per host), then the
# master compares speed, output bytes and scores, and every host scores the
# master's encode to compare the metrics themselves.
#
# Usage: spike/speed.sh <source.mkv> [start seconds] [length seconds]
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/util.sh
source spike/hosts.sh
# The master runs the same pinned tools as the workers.
command -v x265 >/dev/null || exec nix shell --quiet "$REF#tools" --command "$0" "$@"

SRC=$1 START=${2:-2646} LENGTH=${3:-60}
[[ -f $SRC ]] || die "No such file: $SRC"
LOCAL="$HOME/$SPIKE_DIR"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/spike-speed.XXXXXX")
mkdir -p "$LOCAL"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$STATE"' EXIT
trap 'exit 130' INT

CROP="crop=3836:1600:2:280"
TAG="setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv"
RETIME="settb=AVTB,setpts=N/FRAME_RATE/TB"
X265=(--preset slow --crf 17 --output-depth 10 --profile main10 --colorprim bt2020 --transfer smpte2084
    --colormatrix bt2020nc --range limited --chromaloc 2 --hdr10 --hdr10-opt --repeat-headers
    --master-display "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,0)" --max-cll 1000,169
    --level-idc 51 --high-tier --vbv-maxrate 160000 --vbv-bufsize 160000 --aq-mode 3 --aq-strength 0.8
    --psy-rdoq 1.0 --no-sao --no-strong-intra-smoothing --deblock -2,-2 --qcomp 0.7 --rc-lookahead 60
    --bframes 8 --ref 5 --keyint 240 --min-keyint 24)
VMAF="model=version=vmaf_4k_v0.6.1neg:feature='name=cambi\:full_ref=true\:eotf=pq'"

###############################################################################
section "Spike · same segment on every host"
###############################################################################

heading "Segment"
ffmpeg -nostdin -v error -n -ss "$START" -i "$SRC" -t "$LENGTH" -map 0:v:0 -c copy "$LOCAL/seg.mkv" ||
    [[ -f $LOCAL/seg.mkv ]] || die "Could not cut the segment"
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$LOCAL/seg.mkv")
SEG_BYTES=$(stat -c %s "$LOCAL/seg.mkv")
kv "Source" "$(basename "$SRC") from $(hms "$START") · $LENGTH s"
kv "Segment" "$FRAMES frames · $(human_bytes "$SEG_BYTES")"
kv "Encode" "x265 slow CRF 17, John Wick's settings, $CROP"

heading "Push"
for host in "${WORKERS[@]}"; do
    (
        t=$(date +%s.%N)
        put "$host" "$LOCAL/seg.mkv" seg.mkv
        awk -v b="$SEG_BYTES" -v s="$t" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f %.1f\n", e - s, b / (e - s) / 1048576 }' >"$STATE/push-$host"
    ) &
done
wait
for host in "${WORKERS[@]}"; do
    read -r secs rate <"$STATE/push-$host"
    kv "$host" "$secs s · $rate MiB/s"
done

# The job: ffmpeg decodes and crops, x265 encodes from the y4m pipe, as in
# hevc-2160p-hdr.sh. Its stdout carries only ffmpeg's -progress lines.
job() {
    cat <<EOF
set -euo pipefail
rm -f out.hevc
{ ffmpeg -nostdin -v error -nostats -progress pipe:3 -i seg.mkv -map 0:v:0 -vf "$CROP,$TAG" -fps_mode passthrough \\
    -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m $(printf '%q ' "${X265[@]}") $1 --log-level error --no-progress -o out.hevc; } 4>&1
EOF
}

# Reads -progress lines into $STATE/<host>: "frame fps".
follow() {
    local host=$1 key value frame=0 fps=0
    while IFS='=' read -r key value; do
        case $key in
            frame) frame=$value ;;
            fps) fps=$value ;;
            progress) echo "$frame $fps" >"$STATE/$host" ;;
        esac
    done
}

draw() {
    local host frame fps status pct eta
    (( ${DRAWN:-0} )) && printf '\e[%dA' "${#HOSTS[@]}"
    for host in "${HOSTS[@]}"; do
        read -r frame fps 2>/dev/null <"$STATE/$host" || { frame=0 fps=0; }
        status=$(cat "$STATE/status-$host" 2>/dev/null || echo "starting")
        read -r pct eta < <(awk -v f="$frame" -v t="$FRAMES" -v r="$fps" 'BEGIN {
            printf "%.0f ", (t > 0 ? f / t * 100 : 0)
            if (r > 0) { e = (t - f) / r; printf "%d:%02d", e / 60, e % 60 } else printf "—" }')
        printf '\r\e[K  %-13s %s %3s%% · %6s fps · ETA %5s · %s\n' "$host" \
            "$(bar "$(awk -v f="$frame" -v t="$FRAMES" 'BEGIN { print (t > 0 ? f / t : 0) }')" 20)" "$pct" "$fps" "$eta" "$status"
    done
    DRAWN=1
}

heading "Encode"
for host in "${HOSTS[@]}"; do
    (
        echo "encoding · ${WRAP[$host]}" >"$STATE/status-$host"
        t=$(date +%s.%N)
        if job "${ASM[$host]}" | on "$host" 2>"$STATE/err-$host" > >(follow "$host"); then
            awk -v s="$t" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f\n", e - s }' >"$STATE/secs-$host"
            echo "${GREEN}done${RESET}" >"$STATE/status-$host"
        else
            echo "${RED}failed${RESET} (see below)" >"$STATE/status-$host"
        fi
        touch "$STATE/end-$host"
    ) &
done
DRAWN=0
while :; do
    draw
    left=0
    for host in "${HOSTS[@]}"; do [[ -e $STATE/end-$host ]] || left=1; done
    (( left )) || break
    sleep 1
done
draw
for host in "${HOSTS[@]}"; do
    [[ -s $STATE/err-$host ]] && { warn "$host stderr:"; sed 's/^/      /' "$STATE/err-$host" | tail -5; }
done

heading "Results"
for host in "${HOSTS[@]}"; do
    [[ -e $STATE/secs-$host ]] || continue
    get "$host" out.hevc "$LOCAL/out-$host.hevc"
done
# Raw HEVC carries no frame rate: give it the segment's, so the scoring
# graph's retiming pairs the same frames.
RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$LOCAL/seg.mkv")
score() { # <host to run on> <encode path there> <segment path there> → "neg low cambi xpsnr"
    on "$1" <<EOF
set -euo pipefail
ffmpeg -nostdin -v error -framerate $RATE -i "$2" -i "$3" -lavfi "[0:v]$TAG,$RETIME,format=yuv420p10le[d];[1:v]$CROP,$TAG,$RETIME,format=yuv420p10le[r];[d][r]libvmaf=$VMAF:n_threads=\$(getconf _NPROCESSORS_ONLN):log_fmt=json:log_path=vmaf.json" -f null -
x=\$(ffmpeg -nostdin -hide_banner -nostats -framerate $RATE -i "$2" -i "$3" -lavfi "[0:v]$TAG,$RETIME,format=yuv420p10le,pad=ceil((iw+1)/64)*64:ih[d];[1:v]$CROP,$TAG,$RETIME,format=yuv420p10le,pad=ceil((iw+1)/64)*64:ih[r];[d][r]xpsnr" -f null - 2>&1 | grep -o 'XPSNR  y: *[0-9.]*' | tail -1 | grep -o '[0-9.]*\$')
jq -r --arg x "\$x" '([.frames[].metrics.vmaf] | sort) as \$s | "\(.pooled_metrics.vmaf.mean) \(\$s[(\$s | length) / 100 | floor]) \(.pooled_metrics.cambi_full_reference.max) \(\$x)"' vmaf.json
EOF
}
printf '  %-13s %7s %6s %10s %12s %7s %7s %6s %7s  %s\n' host secs fps size md5 frames NEG 1% CAMBI "XPSNR"
for host in "${HOSTS[@]}"; do
    f="$LOCAL/out-$host.hevc"
    [[ -s $f ]] || { printf '  %-13s %s\n' "$host" "no output"; continue; }
    secs=$(cat "$STATE/secs-$host")
    frames=$(ffprobe -v error -count_frames -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$f")
    progress "Scoring $host's encode on $MASTER…"
    read -r neg low cambi xpsnr < <(score "$MASTER" "$f" "$LOCAL/seg.mkv")
    progress ""
    printf '  %-13s %7s %6.2f %10s %12s %7s %7.3f %6.2f %7.3f  %s\n' "$host" "$secs" \
        "$(awk -v f="$FRAMES" -v s="$secs" 'BEGIN { print f / s }')" "$(human_bytes "$(stat -c %s "$f")")" \
        "$(md5sum "$f" | cut -c1-12)" "$frames" "$neg" "$low" "$cambi" "$xpsnr"
done

heading "Metrics on each host (the $MASTER encode)"
for host in "${WORKERS[@]}"; do put "$host" "$LOCAL/out-$MASTER.hevc" ref-encode.hevc; done
printf '  %-13s %7s %6s %7s  %s\n' host NEG 1% CAMBI XPSNR
for host in "${HOSTS[@]}"; do
    if [[ $host == "$MASTER" ]]; then path="$LOCAL/out-$MASTER.hevc"; else path=ref-encode.hevc; fi
    progress "Scoring on $host…"
    read -r neg low cambi xpsnr < <(score "$host" "$path" seg.mkv 2>/dev/null)
    progress ""
    printf '  %-13s %7.3f %6.2f %7.3f  %s\n' "$host" "$neg" "$low" "$cambi" "$xpsnr"
done
