#!/usr/bin/env bash
# Spike step 4: one excerpt split at source keyframes into one chunk per
# slot (brightfalls, nexus node 0, nexus node 1, nightsprings), sized by
# each slot's measured speed, encoded independently, joined with cat and
# muxed with the excerpt's audio for watching. Then checks the frame count,
# per-frame VMAF NEG and CAMBI around each join against the rest, and the
# decoder buffer across the joins.
#
# Usage: spike/chunks.sh <source.mkv> [start seconds] [length seconds]
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/util.sh
source spike/hosts.sh
source spike/bars.sh
command -v x265 >/dev/null || exec nix shell --quiet "$REF#tools" --command "$0" "$@"

SRC=$1 START=${2:-2400} LENGTH=${3:-600}
[[ -f $SRC ]] || die "No such file: $SRC"
LOCAL="$HOME/$SPIKE_DIR/chunks"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/spike-chunks.XXXXXX")
EXCERPT="$LOCAL/excerpt-$START-$LENGTH.mkv"
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

# Slots: name, host, NUMA node ("" for none), fps measured by speed.sh/slots.sh.
SLOT_HOST=(brightfalls nexus nexus nightsprings)
SLOT_NODE=("" 0 1 "")
SLOT_FPS=(2.54 1.82 1.81 2.98)
SLOTS=("brightfalls" "nexus node 0" "nexus node 1" "nightsprings")
N=${#SLOTS[@]}

###############################################################################
section "Spike · chunked encode across ${N} slots"
###############################################################################

heading "Excerpt"
if [[ ! -s $EXCERPT ]]; then
    progress "Cutting the excerpt…"
    ffmpeg -nostdin -v error -n -ss "$START" -i "$SRC" -t "$LENGTH" -map 0:v:0 -map 0:a:0 -c copy "$EXCERPT" ||
        die "Could not cut the excerpt"
    progress ""
fi
RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$EXCERPT")
# Keyframes and frame count from the packet index: no decode.
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,flags -of compact=p=0:nk=1 "$EXCERPT" |
    sort -t'|' -k1,1n >"$STATE/packets"
FRAMES=$(wc -l <"$STATE/packets")
kv "Source" "$(basename "$SRC") from $(hms "$START") · $LENGTH s"
kv "Excerpt" "$FRAMES frames · $(human_bytes "$(stat -c %s "$EXCERPT")") (video + original audio)"

heading "Plan"
# Scene-change score of every frame (scdet on a downscaled decode), cached.
SCENES="$LOCAL/scenes-$START-$LENGTH.txt"
if [[ ! -s $SCENES ]]; then
    progress "Finding scene cuts…"
    ffmpeg -nostdin -hide_banner -i "$EXCERPT" -map 0:v:0 -vf "scale=960:-2,scdet=threshold=0,metadata=print:key=lavfi.scd.score" \
        -f null - 2>&1 | grep -o 'lavfi.scd.score=[0-9.]*' | awk -F= '{ print NR - 1, $2 }' >"$SCENES.tmp" && mv "$SCENES.tmp" "$SCENES"
    progress ""
fi
# Boundary k: a source keyframe on a scene cut (score > 10), nearest to the
# share of the frames slots 0…k-1 should encode at their speeds. A chunk
# opening mid-scene starts from a cold keyframe the continuous encode does
# not have, which can band on dark gradients. Falls back to the nearest
# keyframe, marked, when the excerpt has no cut to use.
mapfile -t BOUNDS < <(awk -v n="$N" -v fps="${SLOT_FPS[*]}" -v total="$FRAMES" '
    FNR == NR { sc[$1] = $2; next }
    { split($0, a, "|"); f = FNR - 1; t[f] = a[1]
      if (a[2] ~ /K/ && f > 0) { key[++k] = f; if (sc[f] > 10) cut[++c] = f } }
    END {
        split(fps, v, " "); for (i = 1; i <= n; i++) sum += v[i]
        acc = 0
        for (i = 1; i < n; i++) {
            acc += v[i]; want = total * acc / sum; best = ""; kind = "scene cut"
            for (j = 1; j <= c; j++) if (best == "" || (cut[j] - want)^2 < (best - want)^2) best = cut[j]
            if (best == "") { kind = "mid-scene"; for (j = 1; j <= k; j++) if (best == "" || (key[j] - want)^2 < (best - want)^2) best = key[j] }
            printf "%d %s %s %.1f\n", best, t[best], kind, sc[best]
        }
    }' "$SCENES" "$STATE/packets")
starts=(0) times=()
kinds=()
for b in "${BOUNDS[@]}"; do read -r f t kind score <<<"$b"; starts+=("$f"); times+=("$t"); kinds+=("$kind ($score)"); done
starts+=("$FRAMES")
for ((i = 0; i < N; i++)); do
    frames=$((starts[i + 1] - starts[i]))
    echo "$frames" >"$STATE/total-${SLOTS[i]}"
    kv "chunk $i → ${SLOTS[i]}" "frames ${starts[i]}–$((starts[i + 1] - 1)) · $frames frames · $(hms "$(awk -v f="${starts[i]}" -v r="$RATE" 'BEGIN { split(r, p, "/"); print f * p[2] / p[1] }')")$( ((i > 0)) && echo " · opens on a ${kinds[i - 1]}")"
done
rm -f "$LOCAL"/chunk-*.mkv
ffmpeg -nostdin -v error -i "$EXCERPT" -map 0:v:0 -c copy -f segment -segment_times "$(IFS=,; echo "${times[*]}")" \
    -reset_timestamps 1 "$LOCAL/chunk-%d.mkv" || die "Could not split the excerpt"
for ((i = 0; i < N; i++)); do
    got=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$LOCAL/chunk-$i.mkv" | wc -l)
    [[ $got == $((starts[i + 1] - starts[i])) ]] || die "chunk $i has $got frames, planned $((starts[i + 1] - starts[i]))"
done
ok "Split at source keyframes; every chunk has its planned frames"

heading "Push"
for ((i = 0; i < N; i++)); do
    (
        t=$(date +%s.%N)
        put "${SLOT_HOST[i]}" "$LOCAL/chunk-$i.mkv" "chunk-$i.mkv"
        awk -v b="$(stat -c %s "$LOCAL/chunk-$i.mkv")" -v s="$t" -v e="$(date +%s.%N)" \
            'BEGIN { printf "%s · %.1f s · %.1f MiB/s\n", "", e - s, b / (e - s) / 1048576 }' >"$STATE/push-$i"
    ) &
done
wait
for ((i = 0; i < N; i++)); do
    kv "chunk $i → ${SLOT_HOST[i]}" "$(human_bytes "$(stat -c %s "$LOCAL/chunk-$i.mkv")")$(cat "$STATE/push-$i")"
done

# Chunk $1 on its slot: today's ffmpeg | x265 command, pinned to the slot's
# NUMA node if it has one. All but the last chunk end with the VBV buffer
# back at 90%, the fullness the next chunk starts from.
job() {
    local i=$1 node=${SLOT_NODE[$1]} pin="" pools="" frames=$((starts[$1 + 1] - starts[$1])) end=""
    if [[ -n $node ]]; then
        pin='taskset -c "$(cat /sys/devices/system/node/node'$node'/cpulist)"'
        pools="--pools $( ((node == 0)) && echo "+,-" || echo "-,+")"
    fi
    (( i < N - 1 )) && end="--vbv-end 0.9"
    cat <<EOF
set -euo pipefail
rm -f chunk-$i.hevc
{ $pin ffmpeg -nostdin -v error -nostats -progress pipe:3 -i chunk-$i.mkv -map 0:v:0 -vf "$CROP,$TAG" \\
    -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m $(printf '%q ' "${X265[@]}") ${ASM[${SLOT_HOST[i]}]} $pools --frames $frames $end \\
        --log-level error --no-progress -o chunk-$i.hevc; } 4>&1
EOF
}

heading "Encode"
ENCODE_START=$(date +%s)
for ((i = 0; i < N; i++)); do
    (
        slot=${SLOTS[i]}
        status "$slot" encoding
        t=$(date +%s.%N)
        if job "$i" | on "${SLOT_HOST[i]}" 2>"$STATE/err-$i" > >(follow "$slot"); then
            awk -v s="$t" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f\n", e - s }' >"$STATE/secs-$i"
            status "$slot" "${GREEN}done${RESET}"
        else
            status "$slot" "${RED}failed${RESET}"
        fi
        touch "$STATE/end-$slot"
    ) &
done
watch_slots
WALL=$(( $(date +%s) - ENCODE_START ))
failed=0
for ((i = 0; i < N; i++)); do
    grep -v 'AVX512 is not supported' "$STATE/err-$i" 2>/dev/null | grep -q . &&
        { warn "${SLOTS[i]} stderr:"; sed 's/^/      /' "$STATE/err-$i" | tail -5; }
    [[ -e $STATE/secs-$i ]] || failed=1
done
(( failed )) && die "A chunk failed"
for ((i = 0; i < N; i++)); do
    kv "${SLOTS[i]}" "$(cat "$STATE/secs-$i") s · $(awk -v f="$(cat "$STATE/total-${SLOTS[i]}")" -v s="$(cat "$STATE/secs-$i")" 'BEGIN { printf "%.2f", f / s }') fps"
done
ok "Wall time $(hms "$WALL") · ${BOLD}$(awk -v f="$FRAMES" -v w="$WALL" 'BEGIN { printf "%.2f", f / w }') fps${RESET} across the slots"

heading "Join"
for ((i = 0; i < N; i++)); do get "${SLOT_HOST[i]}" "chunk-$i.hevc" "$LOCAL/chunk-$i.hevc"; done
: >"$LOCAL/video.hevc"
for ((i = 0; i < N; i++)); do cat "$LOCAL/chunk-$i.hevc" >>"$LOCAL/video.hevc"; done
rm -f "$LOCAL/qa.mkv"
mkvmerge -q -o "$LOCAL/qa.mkv" --default-duration "0:${RATE}p" "$LOCAL/video.hevc" -D "$EXCERPT" ||
    [[ $? == 1 ]] || die "mkvmerge failed"
got=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$LOCAL/qa.mkv" | wc -l)
if [[ $got == "$FRAMES" ]]; then ok "$got frames, as the excerpt"; else warn "$got frames, the excerpt has $FRAMES"; fi
kv "Size" "$(human_bytes "$(stat -c %s "$LOCAL/video.hevc")") video · $(awk -v b="$(stat -c %s "$LOCAL/video.hevc")" -v l="$LENGTH" 'BEGIN { printf "%.1f", b * 8 / l / 1e6 }') Mb/s"

heading "Decoder buffer (VBV 160 Mb/s, 160 Mb, starts 90% full)"
ffprobe -v error -show_entries packet=size -of csv=p=0 "$LOCAL/video.hevc" |
    awk -v r="$RATE" -v n="$N" -v b="$(IFS=,; echo "${starts[*]:1:$((N - 1))}")" '
    BEGIN { split(r, p, "/"); fps = p[1] / p[2]; R = 160e6; B = 160e6; f = 0.9 * B; lo = B; split(b, cut, ",") }
    { f -= $1 * 8; if (f < lo) { lo = f; at = NR - 1 } if (f < 0) under++; f += R / fps; if (f > B) f = B }
    END { printf "%.1f %d %d\n", lo / B * 100, at, under + 0 }' >"$STATE/vbv"
read -r lowest at under <"$STATE/vbv"
if (( under == 0 )); then ok "No underflow · lowest fullness $lowest% at frame $at"; else warn "$under underflows · lowest $lowest% at frame $at"; fi

heading "Quality around the joins"
# The control for join k: the same frames encoded without a join, as one
# piece from a keyframe about 5 s before it to 5 s after. Comparing the
# ±2 s window of both tells a seam from hard content.
read -r W PRE < <(awk -v r="$RATE" 'BEGIN { split(r, p, "/"); f = p[1] / p[2]; printf "%d %d\n", int(2 * f), int(5 * f) }')
CTRL_SLOTS=()
for ((k = 1; k < N; k++)); do
    cut=${starts[k]}
    # From the last keyframe at least 5 s before the join to the first at
    # least 5 s after it (or the end), split exactly there like the chunks.
    read -r cstart ctime cend etime < <(awk -F'|' -v a=$((cut - PRE)) -v b=$((cut + PRE)) -v n="$FRAMES" '
        $2 ~ /K/ { f = NR - 1; if (f <= a) { s = f; t = $1 } if (f >= b && e == "") { e = f; u = $1 } }
        END { print s + 0, t + 0, (e == "" ? n : e), (u == "" ? 0 : u) }' "$STATE/packets")
    CTRL_START[k]=$cstart CTRL_FRAMES[k]=$((cend - cstart))
    rm -f "$LOCAL"/ctl-*.mkv
    # A split at the first frame would make no piece: then the control is
    # the first piece.
    times_k="" piece=0
    (( cstart > 0 )) && { times_k=$ctime piece=1; }
    [[ $etime != 0 ]] && times_k+="${times_k:+,}$etime"
    if [[ -n $times_k ]]; then
        ffmpeg -nostdin -v error -i "$EXCERPT" -map 0:v:0 -c copy -f segment -segment_times "$times_k" -reset_timestamps 1 "$LOCAL/ctl-%d.mkv"
        mv -f "$LOCAL/ctl-$piece.mkv" "$LOCAL/control-$k.mkv"
    else
        ffmpeg -nostdin -v error -y -i "$EXCERPT" -map 0:v:0 -c copy "$LOCAL/control-$k.mkv"
    fi
    got=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$LOCAL/control-$k.mkv" | wc -l)
    [[ $got == "${CTRL_FRAMES[k]}" ]] || die "control $k has $got frames, planned ${CTRL_FRAMES[k]}"
    slot="control $k · ${SLOTS[k - 1]}"
    CTRL_SLOTS+=("$slot")
    echo "${CTRL_FRAMES[k]}" >"$STATE/total-$slot"
    put "${SLOT_HOST[k - 1]}" "$LOCAL/control-$k.mkv" "control-$k.mkv"
done
# Control k runs on chunk k-1's slot, with the chunk command minus --frames
# and --vbv-end.
control_job() {
    local k=$1 i=$(($1 - 1)) node=${SLOT_NODE[$1 - 1]} pin="" pools=""
    if [[ -n $node ]]; then
        pin='taskset -c "$(cat /sys/devices/system/node/node'$node'/cpulist)"'
        pools="--pools $( ((node == 0)) && echo "+,-" || echo "-,+")"
    fi
    cat <<JOB
set -euo pipefail
{ $pin ffmpeg -nostdin -v error -nostats -progress pipe:3 -i control-$k.mkv -map 0:v:0 -vf "$CROP,$TAG" \\
    -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m $(printf '%q ' "${X265[@]}") ${ASM[${SLOT_HOST[i]}]} $pools \\
        --log-level error --no-progress -o control-$k.hevc; } 4>&1
JOB
}
SLOTS_SAVED=("${SLOTS[@]}")
SLOTS=("${CTRL_SLOTS[@]}")
for ((k = 1; k < N; k++)); do
    (
        slot=${SLOTS[k - 1]}
        status "$slot" encoding
        if control_job "$k" | on "${SLOT_HOST[k - 1]}" 2>"$STATE/cerr-$k" > >(follow "$slot"); then
            status "$slot" "${GREEN}done${RESET}"
        else
            status "$slot" "${RED}failed${RESET}"
        fi
        touch "$STATE/end-$slot"
    ) &
done
watch_slots
SLOTS=("${SLOTS_SAVED[@]}")

progress "Scoring every frame of the joined excerpt (VMAF NEG + CAMBI)…"
ffmpeg -nostdin -v error -i "$LOCAL/qa.mkv" -i "$EXCERPT" -lavfi \
    "[0:v]$TAG,$RETIME,format=yuv420p10le[d];[1:v]$CROP,$TAG,$RETIME,format=yuv420p10le[r];[d][r]libvmaf=$VMAF:n_threads=$(nproc):log_fmt=json:log_path=$LOCAL/vmaf.json" \
    -f null - || die "Scoring failed"
# "<mean> <min> <cambi max>" of the frames in [$2, $3) of VMAF log $1, whose
# frame numbers start at excerpt frame $4.
window() {
    jq -r '.frames[] | "\(.frameNum) \(.metrics.vmaf) \(.metrics.cambi_full_reference)"' "$1" |
        awk -v a="$2" -v b="$3" -v o="$4" '$1 + o >= a && $1 + o < b { s += $2; if (!c++ || $2 < m) m = $2; if ($3 > x) x = $3 }
            END { printf "%.2f %.2f %.3f\n", s / c, m, x }'
}
printf '  %-24s %-19s   %-19s   %s\n' "±2 s around" "chunked" "control (no join)" "Δ mean"
printf '  %-24s %6s %5s %6s   %6s %5s %6s\n' "" mean min CAMBI mean min CAMBI
for ((k = 1; k < N; k++)); do
    get "${SLOT_HOST[k - 1]}" "control-$k.hevc" "$LOCAL/control-$k.hevc"
    progress "Scoring control $k…"
    ffmpeg -nostdin -v error -framerate "$RATE" -i "$LOCAL/control-$k.hevc" -i "$LOCAL/control-$k.mkv" -lavfi \
        "[0:v]$TAG,$RETIME,format=yuv420p10le[d];[1:v]$CROP,$TAG,$RETIME,format=yuv420p10le[r];[d][r]libvmaf=$VMAF:n_threads=$(nproc):log_fmt=json:log_path=$LOCAL/control-$k.json" \
        -f null - || die "Scoring control $k failed"
    progress ""
    cut=${starts[k]}
    read -r cm cn cc < <(window "$LOCAL/vmaf.json" $((cut - W)) $((cut + W)) 0)
    read -r rm rn rc < <(window "$LOCAL/control-$k.json" $((cut - W)) $((cut + W)) "${CTRL_START[k]}")
    printf '  join %d · frame %-8s %6.2f %5.1f %6.3f   %6.2f %5.1f %6.3f   %+.2f\n' "$k" "$cut" "$cm" "$cn" "$cc" "$rm" "$rn" "$rc" \
        "$(awk -v a="$cm" -v b="$rm" 'BEGIN { print a - b }')"
done

heading "Watch it (human QA)"
kv "File" "$LOCAL/qa.mkv"
for t in "${times[@]}"; do
    printf '      %smpv --start=%s %q%s\n' "$CYAN" "$(awk -v t="$t" 'BEGIN { printf "%.1f", (t - 3 > 0 ? t - 3 : 0) }')" "$LOCAL/qa.mkv" "$RESET"
done
kv "Joins at" "$(for t in "${times[@]}"; do printf '%s ' "$(awk -v t="$t" 'BEGIN { printf "%d:%04.1f", t / 60, t - int(t / 60) * 60 }')"; done)(3 s before each in the commands)"
