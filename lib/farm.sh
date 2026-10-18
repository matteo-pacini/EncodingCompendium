# hevc-farm.sh's distributed work: a job scheduler over the slots that
# lib/remote.sh found, with one progress bar per slot, then calibration and
# the 2160p video encode split into jobs. Sourced after the other lib/ files.
#
# A job is an id "<kind>:<args…>"; farm_job_<kind> <slot> <args…> runs it on
# a slot (copy inputs, run, fetch and check outputs) and returns 0 once its
# outputs are home and verified. A job that fails is queued again, on any
# slot, until it succeeds; a host that cannot be reached loses its slots.

# A job failing this many times stops the run: the fault is the job's.
FARM_ATTEMPTS=3
# Whether the progress block is on screen, to be redrawn over.
FARM_DRAWN=0

# Reads a job's stdout into the slot's state: "step=<name>" lines name the
# step, ffmpeg -progress lines count its frames, "result=<line>" is kept as
# the job's result.
farm_follow() {
    local i=$1 id=$2 key value frame=0 fps=0 step=""
    while IFS='=' read -r key value; do
        case $key in
            step) step=$value frame=0 ;;
            frame) frame=$value ;;
            fps) fps=$value ;;
            progress) echo "$frame $fps $step" >"$FARM/slot-$i.state" ;;
            result) echo "$value" >"$FARM/jobs/${id//[:\/]/_}.result" ;;
        esac
    done
}

# The progress block: one line per slot, then a total line from FARM_TOTAL
# (a function printing it).
farm_draw() {
    [[ -t 1 ]] || return 0
    local i cols frame fps step total label pct eta line
    cols=$(stty size </dev/tty 2>/dev/null) && cols=${cols##* } || cols=100
    (( cols > 40 )) || cols=100
    (( FARM_DRAWN )) && printf '\e[%dA' $(( ${#SLOT_HOST[@]} + 1 ))
    for i in "${!SLOT_HOST[@]}"; do
        read -r frame fps step 2>/dev/null <"$FARM/slot-$i.state" || { frame=0 fps=0 step=""; }
        total=$(cat "$FARM/slot-$i.total" 2>/dev/null || echo 0)
        label=$(cat "$FARM/slot-$i.label" 2>/dev/null || echo idle)
        if [[ -n ${SLOT_DOWN[i]:-} ]]; then
            line=$(printf '%-14s %soffline%s' "${SLOT_NAME[i]}" "$RED" "$RESET")
        elif [[ -z ${SLOT_JOB[i]:-} ]]; then
            line=$(printf '%-14s %s%s%s' "${SLOT_NAME[i]}" "$DIM" "idle" "$RESET")
        else
            read -r pct eta < <(awk -v f="$frame" -v t="$total" -v r="$fps" 'BEGIN {
                printf "%.0f ", (t > 0 ? f / t * 100 : 0)
                if (r > 0 && t > f) { e = (t - f) / r; printf "%d:%02d\n", e / 60, e % 60 } else print "—" }')
            line=$(printf '%-14s %s %3s%% · %5s fps · ETA %5s · %s%s' "${SLOT_NAME[i]}" \
                "$(bar "$(awk -v f="$frame" -v t="$total" 'BEGIN { print (t > 0 ? f / t : 0) }')" 16)" \
                "$pct" "$fps" "$eta" "$label" "${step:+ · $step}")
        fi
        # Cut by characters: a wrapped line breaks the redraw.
        (( ${#line} > cols - 4 )) && line="${line:0:cols-5}…"
        printf '\r\e[K  %s\n' "$line"
    done
    line=$($FARM_TOTAL)
    (( ${#line} > cols - 4 )) && line="${line:0:cols-5}…"
    printf '\r\e[K  %s%s%s\n' "$BOLD" "$line" "$RESET"
    FARM_DRAWN=1
}

# Prints a line above the progress block.
farm_event() {
    if [[ -t 1 ]] && (( FARM_DRAWN )); then
        printf '\e[%dA\e[J' $(( ${#SLOT_HOST[@]} + 1 ))
        FARM_DRAWN=0
    fi
    printf '  %s\n' "$*"
}

# Runs every job in FARM_QUEUE to success. FARM_TOTAL names the function
# printing the total line; FARM_DONE counts the finished jobs.
farm_schedule() {
    local i id rc pending=("${FARM_QUEUE[@]}") busy alive key err
    declare -gA FARM_TRIES=()
    declare -ga SLOT_JOB=()
    FARM_DONE=0 FARM_DRAWN=0
    mkdir -p "$FARM/jobs"
    while :; do
        for i in "${!SLOT_HOST[@]}"; do
            id=${SLOT_JOB[i]:-}
            key=${id//[:\/]/_}
            [[ -n $id && -e $FARM/jobs/$key.rc ]] || continue
            rc=$(<"$FARM/jobs/$key.rc")
            rm -f "$FARM/jobs/$key.rc" "$FARM/slot-$i.state" "$FARM/slot-$i.label"
            SLOT_JOB[i]=""
            if (( rc == 0 )); then
                FARM_DONE=$((FARM_DONE + 1))
                continue
            fi
            FARM_TRIES[$id]=$(( ${FARM_TRIES[$id]:-0} + 1 ))
            err=$(grep -v 'AVX512 is not supported' "$FARM/jobs/$key.err" 2>/dev/null | tail -1)
            if (( rc == 255 )); then
                # Every slot of the host: one unreachable slot means all are.
                local j
                for j in "${!SLOT_HOST[@]}"; do [[ ${SLOT_HOST[j]} == "${SLOT_HOST[i]}" ]] && SLOT_DOWN[j]=1; done
                farm_event "$YELLOW▲$RESET ${SLOT_HOST[i]} unreachable — its slots are dropped; ${id} goes back in the queue"
            else
                farm_event "$YELLOW▲$RESET ${SLOT_NAME[i]}: ${id} failed (status $rc${err:+: $err}) — queued again"
            fi
            (( FARM_TRIES[$id] < FARM_ATTEMPTS )) || die "${id} failed $FARM_ATTEMPTS times — see $FARM/jobs/$key.err"
            pending=("$id" "${pending[@]}")
        done
        alive=0
        for i in "${!SLOT_HOST[@]}"; do
            [[ -n ${SLOT_DOWN[i]:-} ]] && continue
            alive=1
            [[ -z ${SLOT_JOB[i]:-} && ${#pending[@]} -gt 0 ]] || continue
            id=${pending[0]}
            pending=("${pending[@]:1}")
            SLOT_JOB[i]=$id
            key=${id//[:\/]/_}
            # The EXIT trap reports the status even when the job aborts
            # (set -e, set -u), or the slot would wait for it forever.
            (
                trap 'echo $? >"$FARM/jobs/$key.rc"' EXIT
                IFS=: read -r -a args <<<"$id"
                "farm_job_${args[0]}" "$i" "${args[@]:1}" 2>"$FARM/jobs/$key.err"
            ) &
        done
        (( alive )) || die "No slot left: every worker is unreachable"
        busy=0
        for i in "${!SLOT_HOST[@]}"; do [[ -n ${SLOT_JOB[i]:-} ]] && busy=1; done
        (( busy || ${#pending[@]} > 0 )) || break
        farm_draw
        sleep 1
    done
    farm_draw
    return 0
}

# Sets slot $1's bar: label $2, $3 frames per step.
farm_label() { echo "$2" >"$FARM/slot-$1.label"; echo "$3" >"$FARM/slot-$1.total"; }

# X265_PARAMS for slot $1: without asm on ARM, with the slot's NUMA pool.
slot_params() {
    local params=$X265_PARAMS
    [[ -n ${SLOT_ARM[$1]} ]] && params=${params//:asm=avx512/}
    [[ -n ${SLOT_POOLS[$1]} ]] && params+=":pools=${SLOT_POOLS[$1]}"
    echo "$params"
}

###############################################################################
# Calibration
###############################################################################

# One calibration sample (`farm_job_sample <slot> <preset> <crf> <n>`): the
# commands measure_crf runs, through the same functions, on the slot; its
# VMAF log and result line come home as aggregate_crf reads them.
farm_job_sample() {
    local i=$1 preset=$2 crf=$3 n=$4 id="sample:$2:$3:$4" key
    key=${id//[:\/]/_}
    farm_label "$i" "$preset CRF $crf · sample $((n + 1))/$CALIBRATION_SAMPLES" "${SAMPLE_FRAMES[n]}"
    slot_put "$i" "$WORK/ref$n.mkv" "ref$n.mkv" || return
    {
        printf 'set -euo pipefail\n'
        declare -p VF COLOUR_FLAGS DIST_FILTER REF_FILTER VMAF_OPTIONS
        printf 'X265_PARAMS=%q\n' "$(slot_params "$i")"
        declare -f encode_sample score_vmaf score_xpsnr xpsnr_y
        cat <<EOF
enc=enc-$preset-$crf-$n.mkv log=vmaf-$preset-$crf-$n.json
echo step=encode
start=\$(date +%s.%N)
encode_sample $preset $crf ref$n.mkv "\$enc" -nostats -progress pipe:1
end=\$(date +%s.%N)
frames=\$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "\$enc")
echo step=VMAF+CAMBI
score_vmaf "\$enc" ref$n.mkv "\$log" -nostats -progress pipe:1
echo step=XPSNR
score_xpsnr "\$enc" ref$n.mkv -nostats -progress pipe:1 2>xpsnr-$preset-$crf-$n.log
echo "result=\$frames \$(stat -c %s "\$enc") \$(awk -v s="\$start" -v e="\$end" 'BEGIN { printf "%f", e - s }') \$(xpsnr_y <xpsnr-$preset-$crf-$n.log)"
rm -f "\$enc" xpsnr-$preset-$crf-$n.log
EOF
    } >"$FARM/jobs/$key.sh"
    slot_run "$i" "$(<"$FARM/jobs/$key.sh")" | farm_follow "$i" "$id"
    (( PIPESTATUS[0] == 0 )) || return "${PIPESTATUS[0]}"
    [[ -s $FARM/jobs/$key.result ]] || { echo "no result line" >&2; return 1; }
    slot_get "$i" "vmaf-$preset-$crf-$n.json" "$WORK/vmaf-$preset-$crf-$n.json" || return
    cp "$FARM/jobs/$key.result" "$WORK/result-$preset-$crf-$n"
}

calibration_total() {
    printf 'Calibration · %d/%d samples' "$FARM_DONE" "${#FARM_QUEUE[@]}"
}

# Measures, on every slot at once, what walk_preset will need: each round
# takes every preset's next unmeasured CRF, all their samples queued
# together; a CRF failing a gate ends its preset's walk, as in walk_preset.
# run_calibration then finds everything stored.
farm_calibrate() {
    local i preset crf p rounds=0 created neg neg_low scene_low scene_at cambi xpsnr step failed
    declare -A next=() stopped=() prev_xpsnr=() prev_step=()
    ANALYSIS="${INPUT%.*}.analysis"
    load_analysis
    for i in "${!PRESET_NAMES[@]}"; do check_fingerprint "${PRESET_NAMES[i]}"; done
    save_analysis
    while :; do
        local round=()
        FARM_QUEUE=()
        for i in "${!PRESET_NAMES[@]}"; do
            preset=${PRESET_NAMES[i]}
            [[ -n ${stopped[$preset]:-} ]] && continue
            local crfs=(${PRESET_CRFS[i]})
            while (( ${next[$preset]:-0} < ${#crfs[@]} )); do
                crf=${crfs[${next[$preset]:-0}]}
                if [[ -z ${CACHE[$preset@$crf]:-} ]]; then
                    round+=("$preset@$crf")
                    break
                fi
                # Stored: judged now, exactly as walk_preset will.
                IFS=$'\t' read -r created neg neg_low scene_low scene_at cambi xpsnr _ <<<"${CACHE[$preset@$crf]}"
                step=$( [[ -n ${prev_xpsnr[$preset]:-} ]] && awk -v p="${prev_xpsnr[$preset]}" -v x="$xpsnr" 'BEGIN { printf "%.2f", p - x }' || true)
                failed=$(crf_verdict "$neg" "$neg_low" "$scene_low" "$cambi" "$step" "${prev_step[$preset]:-}")
                prev_xpsnr[$preset]=$xpsnr prev_step[$preset]=$step
                next[$preset]=$(( ${next[$preset]:-0} + 1 ))
                [[ -n $failed ]] && { stopped[$preset]=$crf; break; }
            done
        done
        (( ${#round[@]} > 0 )) || break
        if (( rounds == 0 )); then
            heading "Calibration on ${#SLOT_HOST[@]} slots"
            cut_samples
        fi
        rounds=$((rounds + 1))
        for p in "${round[@]}"; do
            for ((i = 0; i < CALIBRATION_SAMPLES; i++)); do FARM_QUEUE+=("sample:${p%@*}:${p#*@}:$i"); done
        done
        farm_event "${BOLD}Round $rounds${RESET} · $(printf '%s ' "${round[@]//@/ CRF }")· ${#FARM_QUEUE[@]} samples"
        FARM_TOTAL=calibration_total
        farm_schedule
        for p in "${round[@]}"; do
            aggregate_crf "${p%@*}" "${p#*@}"
            farm_event "$GREEN✔$RESET ${p%@*} CRF ${p#*@} measured"
        done
        save_analysis
    done
    (( rounds > 0 )) || return 0
    farm_event "$DIM(the tables below are read back from $(basename "$ANALYSIS"))$RESET"
}

###############################################################################
# 2160p video
###############################################################################

# Seconds of film per chunk: short enough to keep every slot busy to the
# end, long enough that the joins are few.
CHUNK_SECONDS=180
# How far from its target a join may move to land on a scene cut.
CHUNK_WINDOW=15

# Plans the chunks: CHUNK_START (first frame of each, then the frame count)
# and CHUNK_TIME (each join's timestamp), every join on a source keyframe,
# on a scene cut when one is within CHUNK_WINDOW s of the target. A chunk
# opening mid-scene starts from a cold keyframe the continuous encode does
# not have, which can band on dark gradients.
plan_chunks() {
    local packets="$WORK/packets" targets k t from scores best kind mid=0
    progress "Reading the video's packet index…"
    # "pts|pts_time|flags" per frame, in presentation order.
    ffprobe -v error -select_streams "$V" -show_entries packet=pts,pts_time,flags -of compact=p=0:nk=1 "$INPUT" |
        sort -t'|' -k1,1n >"$packets"
    CHUNK_FRAMES_TOTAL=$(wc -l <"$packets")
    progress ""
    CHUNK_START=(0) CHUNK_TIME=() CHUNK_KIND=()
    targets=$(awk -v d="$DURATION" -v c="$CHUNK_SECONDS" 'BEGIN { n = int(d / c + 0.5); for (k = 1; k < n; k++) print d * k / n }')
    k=0
    for t in $targets; do
        k=$((k + 1))
        progress "Finding a scene cut near join $k/$(wc -w <<<"$targets") ($(hms "${t%.*}"))…"
        from=$(awk -v t="$t" -v w="$CHUNK_WINDOW" 'BEGIN { s = t - w; print (s > 0 ? s : 0) }')
        # scdet's score for each decoded frame, by pts (copyts keeps the
        # source's; pts_time is printed to 6 significant digits only). Above
        # 5, not its default 10, which misses most cuts in dark films.
        scores=$(ffmpeg -nostdin -hide_banner -copyts -ss "$from" -t $((2 * CHUNK_WINDOW)) -i "$INPUT" -map 0:"$V" \
            -vf "scale=960:-2,scdet=threshold=0,metadata=print:key=lavfi.scd.score" -f null - 2>&1 |
            awk '/ pts:/ { sub(/.* pts:/, ""); p = $1 } /lavfi.scd.score=/ { sub(/.*=/, ""); print p, $1 }')
        read -r best kind < <(awk -F'|' -v t="$t" -v w="$CHUNK_WINDOW" -v prev="${CHUNK_START[-1]}" -v sc="$scores" '
            BEGIN { n = split(sc, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, " "); score[f[1]] = f[2] } }
            $3 ~ /K/ && NR - 1 > prev && $2 >= t - w && $2 <= t + w {
                d = ($2 - t) * ($2 - t)
                if (score[$1] > 5 && (cut == "" || d < cd)) { cut = NR - 1; cd = d }
                if (key == "" || d < kd) { key = NR - 1; kd = d }
            }
            END { if (cut != "") print cut, "cut"; else if (key != "") print key, "mid"; else print "", "" }' "$packets")
        [[ -n $best ]] || continue
        [[ $kind == mid ]] && mid=$((mid + 1))
        CHUNK_START+=("$best")
        CHUNK_TIME+=("$(sed -n "$((best + 1))p" "$packets" | cut -d'|' -f2)")
        CHUNK_KIND+=("$kind")
    done
    progress ""
    CHUNK_START+=("$CHUNK_FRAMES_TOTAL")
    CHUNKS=$(( ${#CHUNK_START[@]} - 1 ))
    kv "Chunks" "$CHUNKS of ≈ $(hms "$CHUNK_SECONDS") · $CHUNK_FRAMES_TOTAL frames"
    if (( mid == 0 )); then
        ok "Every join on a scene cut"
    else
        warn "$mid of $(( CHUNKS - 1 )) joins mid-scene (no cut within ${CHUNK_WINDOW} s): check them by eye"
    fi
}

# Splits the video at the planned joins into $PARTS/chunk-<k>.mkv and
# checks each has its planned frames.
split_chunks() {
    local k got
    progress "Splitting the video into $CHUNKS chunks…"
    ffmpeg -nostdin -v error -i "$INPUT" -map 0:"$V" -c copy -f segment -segment_times "$(IFS=,; echo "${CHUNK_TIME[*]}")" \
        -reset_timestamps 1 "$PARTS/chunk-%03d.mkv"
    for ((k = 0; k < CHUNKS; k++)); do
        progress "Checking chunk $((k + 1))/$CHUNKS…"
        got=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$(printf '%s/chunk-%03d.mkv' "$PARTS" "$k")" | wc -l)
        (( got == CHUNK_START[k + 1] - CHUNK_START[k] )) ||
            die "chunk $k has $got frames, planned $(( CHUNK_START[k + 1] - CHUNK_START[k] ))"
    done
    progress ""
    ok "Split at source keyframes; every chunk has its planned frames"
}

# One chunk (`farm_job_chunk <slot> <k>`): the 2160p video command on the
# slot, with the chunk's frame count; all but the last chunk end with the
# VBV buffer back at 90%, the fullness the next one starts from. Without
# the RPU: Dolby Vision goes in once the chunks are joined.
farm_job_chunk() {
    local i=$1 k=$2 name frames cli=() arg skip="" end="" got
    name=$(printf 'chunk-%03d' "$k")
    frames=$(( CHUNK_START[k + 1] - CHUNK_START[k] ))
    farm_label "$i" "chunk $((k + 1))/$CHUNKS" "$frames"
    # X265_CLI without "--asm avx512" on ARM, where x265 rejects it.
    for arg in "${X265_CLI[@]}"; do
        if [[ -n $skip ]]; then skip=""; continue; fi
        [[ -n ${SLOT_ARM[i]} && $arg == --asm ]] && { skip=1; continue; }
        cli+=("$arg")
    done
    [[ -n ${SLOT_POOLS[i]} ]] && cli+=(--pools "${SLOT_POOLS[i]}")
    (( k < CHUNKS - 1 )) && end="--vbv-end 0.9"
    slot_put "$i" "$PARTS/$name.mkv" "$name.mkv" || return
    slot_run "$i" "$(cat <<EOF
set -euo pipefail
echo step=encode
{ ffmpeg -nostdin -v error -nostats -progress pipe:3 -i $name.mkv -map 0:v:0 $(printf '%q ' "${VF[@]}") -fps_mode passthrough \\
    -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m --preset $PRESET --crf $SELECTED_CRF --output-depth 10 --profile main10 $(printf '%q ' "${cli[@]}") \\
        --frames $frames $end --log-level error --no-progress -o $name.hevc; } 4>&1
rm -f $name.mkv
EOF
)" | farm_follow "$i" "chunk:$k"
    (( PIPESTATUS[0] == 0 )) || return "${PIPESTATUS[0]}"
    slot_get "$i" "$name.hevc" "$PARTS/$name.hevc" || return
    slot_rm "$i" "$name.mkv"
    got=$(ffprobe -v error -show_entries packet=size -of csv=p=0 "$PARTS/$name.hevc" | wc -l)
    (( got == frames )) || { rm -f "$PARTS/$name.hevc"; echo "$name.hevc has $got frames, not $frames" >&2; return 1; }
    echo "$frames" >>"$FARM/video-done"
}

video_total() {
    local i frames=0 frame _ elapsed=$(( SECONDS - FARM_VIDEO_START ))
    for i in "${!SLOT_HOST[@]}"; do
        [[ -n ${SLOT_JOB[i]:-} ]] && read -r frame _ 2>/dev/null <"$FARM/slot-$i.state" && frames=$((frames + frame))
    done
    frames=$(( frames + $(awk '{ s += $1 } END { print s + 0 }' "$FARM/video-done" 2>/dev/null || echo 0) ))
    awk -v f="$frames" -v t="$CHUNK_FRAMES_TOTAL" -v e="$elapsed" -v d="$FARM_DONE" -v n="$CHUNKS" 'BEGIN {
        r = (e > 0 ? f / e : 0)
        printf "Video · %d/%d chunks · %.1f%% · %.2f fps · ETA ", d, n, f / t * 100, r
        if (r > 0) { s = (t - f) / r; printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 } else printf "—" }'
}

# Section 4's video step on every slot: plan, split, encode the chunks, join
# them into VIDEO_HEVC and, with Dolby Vision, put the source RPU in.
farm_encode_video() {
    local k
    heading "Video on ${#SLOT_HOST[@]} slots"
    if [[ -n $DRY_RUN ]]; then
        item "Chunks of ≈ $(hms "$CHUNK_SECONDS") joined at scene cuts, one x265 per slot:"
        for i in "${!SLOT_HOST[@]}"; do setting "${SLOT_NAME[i]}" "x265 $PRESET CRF $SELECTED_CRF ${SLOT_POOLS[i]:+--pools ${SLOT_POOLS[i]} }${SLOT_ARM[i]:+(no asm) }${WRAP[${SLOT_HOST[i]}]:+under ${WRAP[${SLOT_HOST[i]}]}}"; done
        [[ -n $DV_PROFILE ]] && setting "Dolby Vision" "dovi_tool inject-rpu on the joined stream"
        return 0
    fi
    plan_chunks
    # The split video beside the intermediates the single-host encode needs.
    local need free
    need=$(awk -v v="$(stream_bps "$V")" -v d="$DURATION" -v s="$SELECTED_SIZE" 'BEGIN { printf "%.0f", v * d / 8 + s * 2.2 }')
    free=$(df --output=avail -B1 "$PARTS" | tail -1)
    (( free >= need )) || die "Needs ≈ $(human_bytes "$need") free beside the output for the chunks, $(human_bytes "$free") available"
    split_chunks
    FARM_QUEUE=()
    for ((k = 0; k < CHUNKS; k++)); do FARM_QUEUE+=("chunk:$k"); done
    FARM_TOTAL=video_total FARM_VIDEO_START=$SECONDS
    ENCODE_START=$SECONDS
    farm_schedule
    ENCODE_SECONDS=$((SECONDS - ENCODE_START))
    ok "$CHUNKS chunks in $(hms "$ENCODE_SECONDS") · $(awk -v f="$CHUNK_FRAMES_TOTAL" -v s="$ENCODE_SECONDS" 'BEGIN { printf "%.2f", f / s }') fps"
    progress "Joining the chunks…"
    : >"$VIDEO_HEVC"
    for ((k = 0; k < CHUNKS; k++)); do
        cat "$(printf '%s/chunk-%03d.hevc' "$PARTS" "$k")" >>"$VIDEO_HEVC"
        rm -f "$(printf '%s/chunk-%03d' "$PARTS" "$k")".{hevc,mkv}
    done
    progress ""
    if [[ -n $DV_PROFILE ]]; then
        progress "Putting the Dolby Vision RPU in…"
        dovi_tool inject-rpu -i "$VIDEO_HEVC" --rpu-in "$RPU" -o "$VIDEO_HEVC.dv" >/dev/null && mv -f "$VIDEO_HEVC.dv" "$VIDEO_HEVC"
        progress ""
    fi
}
