#!/usr/bin/env bash
# Spike: nexus slot layout. Two x265 instances at once, each pinned to one
# NUMA node (x265 --pools, ffmpeg's decoder through taskset), both encoding
# the segment speed.sh left on nexus. Compare their combined fps with the
# single instance's.
#
# Usage: spike/slots.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/util.sh
source spike/hosts.sh
source spike/bars.sh
command -v x265 >/dev/null || exec nix shell --quiet "$REF#tools" --command "$0" "$@"

HOST=nexus
LOCAL="$HOME/$SPIKE_DIR"
[[ -f $LOCAL/seg.mkv ]] || die "Run spike/speed.sh first: it cuts the segment"
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$LOCAL/seg.mkv")
STATE=$(mktemp -d "${TMPDIR:-/tmp}/spike-slots.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$STATE"' EXIT
trap 'exit 130' INT

CROP="crop=3836:1600:2:280"
TAG="setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv"
X265=(--preset slow --crf 17 --output-depth 10 --profile main10 --colorprim bt2020 --transfer smpte2084
    --colormatrix bt2020nc --range limited --chromaloc 2 --hdr10 --hdr10-opt --repeat-headers
    --master-display "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,0)" --max-cll 1000,169
    --level-idc 51 --high-tier --vbv-maxrate 160000 --vbv-bufsize 160000 --aq-mode 3 --aq-strength 0.8
    --psy-rdoq 1.0 --no-sao --no-strong-intra-smoothing --deblock -2,-2 --qcomp 0.7 --rc-lookahead 60
    --bframes 8 --ref 5 --keyint 240 --min-keyint 24 --asm avx512)

# Slot $1 of 2: NUMA node $1 for both the decoder and the encoder.
job() {
    local pools; pools=$( (( $1 == 0 )) && echo "+,-" || echo "-,+")
    cat <<EOF
set -euo pipefail
cpus=\$(cat /sys/devices/system/node/node$1/cpulist)
rm -f out-node$1.hevc
{ taskset -c "\$cpus" ffmpeg -nostdin -v error -nostats -progress pipe:3 -i seg.mkv -map 0:v:0 -vf "$CROP,$TAG" \\
    -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m $(printf '%q ' "${X265[@]}") --pools "$pools" --log-level error --no-progress -o out-node$1.hevc; } 4>&1
EOF
}

###############################################################################
section "Spike · $HOST slot layout — 2 instances, one per NUMA node"
###############################################################################

kv "Segment" "$FRAMES frames each · x265 slow CRF 17, John Wick's settings"
kv "Wrapper" "${WRAP[$HOST]}"
kv "Single instance" "1.88 fps (spike/speed.sh)"

heading "Encode"
SLOTS=("$HOST node 0" "$HOST node 1")
for n in 0 1; do
    (
        slot=${SLOTS[n]}
        status "$slot" encoding
        t=$(date +%s.%N)
        if job "$n" | on "$HOST" 2>"$STATE/err-$n" > >(follow "$slot"); then
            awk -v s="$t" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f\n", e - s }' >"$STATE/secs-$n"
            status "$slot" "${GREEN}done${RESET}"
        else
            status "$slot" "${RED}failed${RESET}"
        fi
        touch "$STATE/end-$slot"
    ) &
done
watch_slots
for n in 0 1; do
    grep -v 'AVX512 is not supported' "$STATE/err-$n" 2>/dev/null | grep -q . &&
        { warn "node $n stderr:"; sed 's/^/      /' "$STATE/err-$n" | tail -5; }
done

heading "Results"
for n in 0 1; do
    [[ -e $STATE/secs-$n ]] || { kv "node $n" "failed"; continue; }
    kv "node $n" "$(cat "$STATE/secs-$n") s · $(awk -v f="$FRAMES" -v s="$(cat "$STATE/secs-$n")" 'BEGIN { printf "%.2f", f / s }') fps"
done
if [[ -e $STATE/secs-0 && -e $STATE/secs-1 ]]; then
    read -r combined gain < <(awk -v f="$FRAMES" -v a="$(cat "$STATE/secs-0")" -v b="$(cat "$STATE/secs-1")" \
        'BEGIN { m = (a > b ? a : b); c = 2 * f / m; printf "%.2f %.2f\n", c, c / 1.88 }')
    ok "Combined ${BOLD}$combined fps${RESET} · ${gain}× the single instance"
fi
