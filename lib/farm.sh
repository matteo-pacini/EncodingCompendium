# hevc-farm.sh's distributed work: a job scheduler over the slots that
# lib/remote.sh found, with one progress bar per slot, then calibration and
# the video encode split into jobs. Sourced after the other lib/ files.
#
# A job is an id "<kind>:<args…>"; farm_job_<kind> <slot> <args…> runs it on
# a slot (copy inputs, run, fetch and check outputs) and returns 0 once its
# outputs are home and verified. A job that fails is queued again, on any
# slot, until it succeeds; a host that cannot be reached loses its slots.
#
# With STOP_AT (--stop-at), no job starts that its slot would not finish by
# then, and the run ends at that time (status 75), jobs still running
# stopped. Measured CRFs are in the .analysis and finished chunks in
# <output stem>.chunks, so the same command run again goes on from there.

# A job failing this many times stops the run: the fault is the job's.
FARM_ATTEMPTS=3
# Lines of the progress block on screen, to be redrawn over.
FARM_DRAWN=0
# farm_schedule's queues.
FARM_QUEUE=() FARM_EXTRA=() FARM_DETAIL=""

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

# The progress block: one line per slot, then the total line from FARM_TOTAL
# and, when FARM_DETAIL is set, its line: both name functions printing them.
farm_draw() {
    [[ -t 1 ]] || return 0
    local i cols frame fps step total label pct eta line lines=()
    cols=$(stty size </dev/tty 2>/dev/null) && cols=${cols##* } || cols=100
    (( cols > 40 )) || cols=100
    (( FARM_DRAWN )) && printf '\e[%dA' "$FARM_DRAWN"
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
                "$(bar "$(awk -v f="$frame" -v t="$total" 'BEGIN { print (t > 0 ? f / t : 0) }')" 12)" \
                "$pct" "$fps" "$eta" "$label" "${step:+ · $step}")
        fi
        lines+=("$line")
    done
    lines+=("$BOLD$($FARM_TOTAL)$RESET")
    [[ -n ${FARM_DETAIL:-} ]] && lines+=("$DIM$($FARM_DETAIL)$RESET")
    for line in "${lines[@]}"; do
        # Cut by characters: a wrapped line breaks the redraw.
        (( ${#line} > cols - 4 )) && line="${line:0:cols-5}…$RESET"
        printf '\r\e[K  %s\n' "$line"
    done
    FARM_DRAWN=${#lines[@]}
}

# Prints a line above the progress block.
farm_event() {
    if [[ -t 1 ]] && (( FARM_DRAWN )); then
        printf '\e[%dA\e[J' "$FARM_DRAWN"
        FARM_DRAWN=0
    fi
    printf '  %s\n' "$*"
}

# Frames a job works through: its size for farm_defer.
job_frames() {
    local args
    IFS=: read -r -a args <<<"$1"
    case ${args[0]} in
        sample) echo "${SAMPLE_FRAMES[${args[3]}]}" ;;
        chunk) echo $(( CHUNK_START[args[1] + 1] - CHUNK_START[args[1]] )) ;;
    esac
}

# Whether free slot $1 should leave job $2 to others: only when, counting
# the job each busy slot still has, at least as many slots as there are
# queued jobs would finish it sooner. It only bites at the end, where a slow
# slot starting the last job would keep every other slot waiting. Speeds
# are frames per second of each slot's finished jobs in this schedule.
farm_defer() {
    local i=$1 size f now sooner=0
    (( ${SLOT_SEC[i]:-0} > 0 )) || return 1
    size=$(job_frames "$2")
    now=$EPOCHREALTIME
    for f in "${!SLOT_HOST[@]}"; do
        (( f != i )) && [[ -z ${SLOT_DOWN[f]:-} ]] && (( ${SLOT_SEC[f]:-0} > 0 )) || continue
        awk -v s="$size" -v fi="${SLOT_FR[i]}" -v si="${SLOT_SEC[i]}" -v ff="${SLOT_FR[f]}" -v sf="${SLOT_SEC[f]}" \
            -v busy="$(job_frames "${SLOT_JOB[f]:-}" 2>/dev/null)" -v start="${SLOT_START[f]:-$now}" -v now="$now" 'BEGIN {
                rf = ff / sf; left = (busy > 0 ? busy / rf - (now - start) : 0); if (left < 0) left = 0
                exit !(left + s / rf < s / (fi / si)) }' && sooner=$((sooner + 1))
    done
    (( sooner >= ${#FARM_PENDING[@]} )) && FARM_HELD=$2
}

# Whether slot $1 would finish job $2 by STOP_AT, at the speed of its jobs
# so far in this schedule or else, for a chunk, the calibrated ENCODE_FPS
# (which leaves scoring out). Yes without STOP_AT or any speed.
farm_fits() {
    local rate
    [[ -n ${STOP_AT:-} ]] || return 0
    if (( ${SLOT_SEC[$1]:-0} > 0 )); then
        rate=$(awk -v f="${SLOT_FR[$1]}" -v s="${SLOT_SEC[$1]}" 'BEGIN { print f / s }')
    elif [[ $2 == chunk:* && -n ${ENCODE_FPS:-} ]]; then
        rate=$ENCODE_FPS
    else
        return 0
    fi
    awk -v n="$(job_frames "$2")" -v r="$rate" -v now="$EPOCHSECONDS" -v stop="$STOP_AT" 'BEGIN { exit !(r > 0 && now + n / r <= stop) }'
}

# Ends the run for STOP_AT: its time has come, or no queued job would finish
# by then. Jobs still running die with the run (cleanup); farm_schedule's
# pending list is in scope, being the caller.
farm_stop() {
    local i running=0
    for i in "${!SLOT_HOST[@]}"; do [[ -n ${SLOT_JOB[i]:-} ]] && running=$((running + 1)); done
    farm_draw
    farm_event "$YELLOW▲$RESET Stop time $(date -d "@$STOP_AT" '+%a %H:%M:%S'): ${#pending[@]} job(s) not started$(
        ((running)) && echo ", $running stopped") · what finished is kept: run the same command again to go on"
    exit 75
}

# Runs every job in FARM_QUEUE to success. A slot with nothing left in it
# takes a job from FARM_EXTRA, work ahead that may be wanted later, until
# FARM_QUEUE's last job is done; extras then running are let finish.
# FARM_TOTAL names the function printing the total line; FARM_DONE and
# FARM_AHEAD count the finished jobs of each queue.
farm_schedule() {
    local i id rc pending=("${FARM_QUEUE[@]}") extra=("${FARM_EXTRA[@]}") busy needed alive key err
    declare -gA FARM_TRIES=() FARM_IS_EXTRA=()
    declare -ga SLOT_JOB=() SLOT_START=() SLOT_FR=() SLOT_SEC=()
    FARM_DONE=0 FARM_AHEAD=0 FARM_DRAWN=0
    for id in "${extra[@]}"; do FARM_IS_EXTRA[$id]=1; done
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
                if [[ -n ${FARM_IS_EXTRA[$id]:-} ]]; then FARM_AHEAD=$((FARM_AHEAD + 1)); else FARM_DONE=$((FARM_DONE + 1)); fi
                # Whole seconds keep the speeds bash arithmetic; jobs last minutes.
                SLOT_FR[i]=$(( ${SLOT_FR[i]:-0} + $(job_frames "$id") ))
                SLOT_SEC[i]=$(( ${SLOT_SEC[i]:-0} + EPOCHSECONDS - ${SLOT_START[i]%.*} ))
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
            if [[ -n ${FARM_IS_EXTRA[$id]:-} ]]; then extra=("$id" "${extra[@]}"); else pending=("$id" "${pending[@]}"); fi
        done
        FARM_HELD=""
        # Whether FARM_QUEUE still has work, queued or running.
        needed=$(( ${#pending[@]} > 0 ))
        for i in "${!SLOT_HOST[@]}"; do
            [[ -n ${SLOT_JOB[i]:-} && -z ${FARM_IS_EXTRA[${SLOT_JOB[i]}]:-} ]] && needed=1
        done
        alive=0
        for i in "${!SLOT_HOST[@]}"; do
            [[ -n ${SLOT_DOWN[i]:-} ]] && continue
            alive=1
            [[ -z ${SLOT_JOB[i]:-} ]] || continue
            if (( ${#pending[@]} > 0 )); then
                FARM_PENDING=("${pending[@]}")
                farm_defer "$i" "${pending[0]}" && continue
                farm_fits "$i" "${pending[0]}" || continue
                id=${pending[0]}
                pending=("${pending[@]:1}")
            elif (( needed && ${#extra[@]} > 0 )); then
                farm_fits "$i" "${extra[0]}" || continue
                id=${extra[0]}
                extra=("${extra[@]:1}")
            else
                continue
            fi
            SLOT_JOB[i]=$id SLOT_START[i]=$EPOCHREALTIME
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
        # Idle with jobs queued: only farm_fits holds jobs back from every slot.
        [[ -n ${STOP_AT:-} ]] && (( EPOCHSECONDS >= STOP_AT || (!busy && ${#pending[@]} > 0) )) && farm_stop
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
    farm_label "$i" "$preset $crf · $((n + 1))/$CALIBRATION_SAMPLES" "${SAMPLE_FRAMES[n]}"
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
echo step=VMAF
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
    echo "$i $preset $crf $n" >>"$FARM/samples-by-slot"
}

calibration_total() {
    local i ahead=0
    for i in "${!SLOT_HOST[@]}"; do
        [[ -n ${SLOT_JOB[i]:-} && -n ${FARM_IS_EXTRA[${SLOT_JOB[i]}]:-} ]] && ahead=$((ahead + 1))
    done
    printf 'Calibration · %d/%d samples' "$FARM_DONE" "${#FARM_QUEUE[@]}"
    (( FARM_AHEAD == 0 )) || printf ' · %d ahead' "$FARM_AHEAD"
    (( FARM_DONE < ${#FARM_QUEUE[@]} || ahead == 0 )) || printf ' · finishing %d ahead' "$ahead"
}

# Per slot, the samples it measured this run and its encode speed per
# preset (frames over encode seconds, scoring left out).
calibration_slots() {
    local i preset line
    [[ -s $FARM/samples-by-slot ]] || return 0
    heading "Slots  ${DIM}calibration encode speed${RESET}"
    printf '  %s%-14s %7s' "$DIM" slot samples
    for preset in "${PRESET_NAMES[@]}"; do printf ' %9s' "$preset"; done
    printf ' %6s%s\n' share "$RESET"
    for i in "${!SLOT_HOST[@]}"; do
        line=$(while read -r s p c n; do
            if [[ $s == "$i" ]]; then echo "$p $(cat "$WORK/result-$p-$c-$n")"; fi
        done <"$FARM/samples-by-slot" | awk -v presets="${PRESET_NAMES[*]}" -v all="$(wc -l <"$FARM/samples-by-slot")" '
            { n++; f[$1] += $2; t[$1] += $4 }
            END {
                printf "%7d", n
                k = split(presets, p, " ")
                for (j = 1; j <= k; j++) printf " %9s", (t[p[j]] > 0 ? sprintf("%.2f fps", f[p[j]] / t[p[j]]) : "—")
                printf " %5.0f%%", (all > 0 ? n / all * 100 : 0)
            }')
        printf '  %-14s %s\n' "${SLOT_NAME[i]}" "$line"
    done
}

# Whether sample $3 of preset $1 at CRF $2 is measured (here or ahead).
sample_done() { [[ -s $WORK/result-$1-$2-$3 && -s $WORK/vmaf-$1-$2-$3.json ]]; }

# Measures, on every slot at once, what walk_preset will need: each round
# takes every preset's next unmeasured CRF, all their samples queued
# together; a CRF failing a gate ends its preset's walk, as in walk_preset.
# Slots left idle at a round's end measure each preset's CRF after that,
# kept for the next round. run_calibration then finds everything stored.
farm_calibrate() {
    local i n preset crf p rounds=0 created neg neg_low scene_low scene_at cambi xpsnr step failed after
    declare -A next=() stopped=() prev_xpsnr=() prev_step=() prev_cambi=()
    locate_analysis
    load_analysis
    for i in "${!PRESET_NAMES[@]}"; do check_fingerprint "${PRESET_NAMES[i]}"; done
    save_analysis
    while :; do
        local round=() ahead=()
        FARM_QUEUE=() FARM_EXTRA=()
        for i in "${!PRESET_NAMES[@]}"; do
            preset=${PRESET_NAMES[i]}
            [[ -n ${stopped[$preset]:-} ]] && continue
            local -a crfs
            read -r -a crfs <<<"${PRESET_CRFS[i]}"
            while (( ${next[$preset]:-0} < ${#crfs[@]} )); do
                crf=${crfs[${next[$preset]:-0}]}
                if [[ -z ${CACHE[$preset@$crf]:-} ]]; then
                    round+=("$preset@$crf")
                    after=${crfs[${next[$preset]:-0} + 1]:-}
                    [[ -n $after && -z ${CACHE[$preset@$after]:-} ]] && ahead+=("$preset@$after")
                    break
                fi
                # Stored: judged now, exactly as walk_preset will.
                IFS=$'\t' read -r created neg neg_low scene_low scene_at cambi xpsnr _ <<<"${CACHE[$preset@$crf]}"
                step=$( [[ -n ${prev_xpsnr[$preset]:-} ]] && awk -v p="${prev_xpsnr[$preset]}" -v x="$xpsnr" 'BEGIN { printf "%.2f", p - x }' || true)
                failed=$(crf_verdict "$neg" "$neg_low" "$scene_low" "$cambi" "${prev_cambi[$preset]:-}" "$step" "${prev_step[$preset]:-}")
                prev_xpsnr[$preset]=$xpsnr prev_step[$preset]=$step prev_cambi[$preset]=$cambi
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
            for ((n = 0; n < CALIBRATION_SAMPLES; n++)); do
                sample_done "${p%@*}" "${p#*@}" "$n" || FARM_QUEUE+=("sample:${p%@*}:${p#*@}:$n")
            done
        done
        for p in "${ahead[@]}"; do
            for ((n = 0; n < CALIBRATION_SAMPLES; n++)); do
                sample_done "${p%@*}" "${p#*@}" "$n" || FARM_EXTRA+=("sample:${p%@*}:${p#*@}:$n")
            done
        done
        farm_event "${BOLD}Round $rounds${RESET} · $(IFS=,; echo "${round[*]//@/ }" | sed 's/,/, /g') · ${#FARM_QUEUE[@]} samples$(
            (( ${#ahead[@]} > 0 )) && echo " · ahead: $(IFS=,; echo "${ahead[*]//@/ }" | sed 's/,/, /g')")"
        FARM_TOTAL=calibration_total
        (( ${#FARM_QUEUE[@]} == 0 )) || farm_schedule
        for p in "${round[@]}"; do
            aggregate_crf "${p%@*}" "${p#*@}"
            farm_event "$GREEN✔$RESET ${p%@*} CRF ${p#*@} measured"
        done
        save_analysis
    done
    (( rounds > 0 )) || return 0
    calibration_slots
    echo
    printf '  %s(the tables below are read back from %s)%s\n' "$DIM" "$(basename "$ANALYSIS")" "$RESET"
}

###############################################################################
# Video
###############################################################################

# Seconds of film per chunk: short enough to keep every slot busy to the
# end, long enough that the joins are few.
CHUNK_SECONDS=180
# How far from its target a join may move to land on a scene cut, tried in
# turn: a wider window costs a longer decode, and a chunk's length matters
# little, as the queue evens the slots out.
CHUNK_WINDOWS=(15 30 60)

# Plans the chunks: CHUNK_START, the first frame of each, then the frame
# count. Every join is a source keyframe on a scene cut within
# CHUNK_WINDOWS of its target; a target with none is dropped, its two
# chunks made one. A chunk opening mid-scene would start from a cold
# keyframe the continuous encode does not have, which can band on dark
# gradients.
plan_chunks() {
    local packets="$WORK/packets" targets k t w from scores best dropped=() lead
    progress "Reading the video's packet index…"
    # "pts|pts_time|flags|packet number" per frame, in presentation order.
    ffprobe -v error -select_streams "$V" -show_entries packet=pts,pts_time,flags -of compact=p=0:nk=1 "$INPUT" |
        awk '{ print $0 "|" NR - 1 }' | sort -t'|' -k1,1n >"$packets"
    # Frames shown before the first keyframe (a stream cut mid-GOP opens
    # with some) do not decode: the first chunk starts after them.
    lead=$(awk -F'|' '$3 ~ /K/ { print NR - 1; exit }' "$packets")
    CHUNK_FRAMES_TOTAL=$(( $(wc -l <"$packets") - lead ))
    progress ""
    CHUNK_START=("$lead")
    targets=$(awk -v d="$DURATION" -v c="$CHUNK_SECONDS" 'BEGIN { n = int(d / c + 0.5); for (k = 1; k < n; k++) print d * k / n }')
    k=0
    for t in $targets; do
        k=$((k + 1))
        for w in "${CHUNK_WINDOWS[@]}"; do
            progress "Finding a scene cut near join $k/$(wc -w <<<"$targets") ($(hms "${t%.*}"), ±$w s)…"
            from=$(awk -v t="$t" -v w="$w" 'BEGIN { s = t - w; print (s > 0 ? s : 0) }')
            # scdet's score for each decoded frame, by pts (copyts keeps the
            # source's; pts_time is printed to 6 significant digits only).
            # Above 5, not its default 10, which misses most cuts in dark films.
            scores=$(ffmpeg -nostdin -hide_banner -copyts -ss "$from" -t $((2 * w)) -i "$INPUT" -map 0:"$V" \
                -vf "scale=960:-2,scdet=threshold=0,metadata=print:key=lavfi.scd.score" -f null - 2>&1 |
                awk '/ pts:/ { sub(/.* pts:/, ""); p = $1 } /lavfi.scd.score=/ { sub(/.*=/, ""); print p, $1 }')
            # Only a keyframe as many packets into the stream as frames into
            # the film, where split_chunks counts packets: an open-GOP one
            # has a leading frame decoded after it, which a split there
            # would cut off from its chunk.
            best=$(awk -F'|' -v t="$t" -v w="$w" -v prev="${CHUNK_START[-1]}" -v sc="$scores" '
                BEGIN { n = split(sc, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, " "); score[f[1]] = f[2] } }
                $3 ~ /K/ && $4 == NR - 1 && NR - 1 > prev && $2 >= t - w && $2 <= t + w && score[$1] > 5 {
                    d = ($2 - t) * ($2 - t)
                    if (cut == "" || d < cd) { cut = NR - 1; cd = d }
                }
                END { print cut }' "$packets")
            [[ -n $best ]] && break
        done
        if [[ -z $best ]]; then
            dropped+=("$(hms "${t%.*}")")
            continue
        fi
        CHUNK_START+=("$best")
    done
    progress ""
    CHUNK_START+=("$((lead + CHUNK_FRAMES_TOTAL))")
    CHUNKS=$(( ${#CHUNK_START[@]} - 1 ))
    kv "Chunks" "$CHUNKS of ≈ $(hms "$CHUNK_SECONDS") · $CHUNK_FRAMES_TOTAL frames"
    ok "Every join on a scene cut"
    (( ${#dropped[@]} == 0 )) ||
        item "No cut within ${CHUNK_WINDOWS[-1]} s of ${dropped[*]}: no join there, longer chunks instead"
}

# What the chunks depend on: the source, the preset, CRF, x265 settings,
# filters, scoring and chunk length, and the code that encodes and scores
# them. The plan itself is read back from CHUNKS_FILE, not made again.
chunks_fingerprint() {
    {
        stat -L -c '%s %Y' "$INPUT"
        printf '%s\n' "$PRESET" "$SELECTED_CRF" "$X265_PARAMS" "${VF[*]}" "$REF_FILTER" "$DIST_FILTER" "$VMAF_OPTIONS" \
            "$CHUNK_SECONDS" "${CHUNK_WINDOWS[*]}"
        declare -f farm_job_chunk score_frames
    } | sha256sum | cut -d' ' -f1
}

# Reads CHUNKS_FILE (<output stem>.chunks, beside the output) when an
# earlier run left one: its plan into CHUNK_START, CHUNKS and
# CHUNK_FRAMES_TOTAL, the chunks it recorded into CHUNK_DONE (chunk →
# "slot\tseconds\tbytes\tsha256"), and YES, the encode being confirmed
# already. Dies when the file is from other settings, rather than join
# chunks of two encodes.
load_chunks() {
    local kind k a b c d fingerprint="" end=""
    CHUNKS_FILE="${OUTPUT%.mkv}.chunks"
    CHUNK_START=()
    declare -gA CHUNK_DONE=()
    [[ -f $CHUNKS_FILE ]] || return 0
    while IFS=$'\t' read -r kind k a b c d; do
        case $kind in
            fingerprint) fingerprint=$k ;;
            plan) CHUNK_START[k]=$a end=$((a + b)) ;;
            encoded) CHUNK_DONE[$k]=$a$'\t'$b$'\t'$c$'\t'$d ;;
        esac
    done <"$CHUNKS_FILE"
    [[ $fingerprint == "$(chunks_fingerprint)" && -n $end ]] ||
        die "$(basename "$CHUNKS_FILE") is from an encode with other settings or code — delete it and $(basename "${OUTPUT%.mkv}").partial to start over"
    CHUNK_START+=("$end")
    CHUNKS=$(( ${#CHUNK_START[@]} - 1 ))
    CHUNK_FRAMES_TOTAL=$(( end - CHUNK_START[0] ))
    YES="resuming"
    heading "Resume"
    kv "Chunks" "${#CHUNK_DONE[@]} of $CHUNKS recorded in $(basename "$CHUNKS_FILE"), checked before the encode"
}

# Writes the plan to CHUNKS_FILE, which farm_job_chunk then adds to.
write_chunks_plan() {
    local k
    {
        echo "# $(basename "$0") chunks of $(basename "$OUTPUT"): the plan, then each chunk once checked — delete with $(basename "$PARTS") to start over"
        printf 'fingerprint\t%s\n' "$(chunks_fingerprint)"
        for ((k = 0; k < CHUNKS; k++)); do
            printf 'plan\t%d\t%d\t%d\n' "$k" "${CHUNK_START[k]}" $(( CHUNK_START[k + 1] - CHUNK_START[k] ))
        done
    } >"$CHUNKS_FILE.tmp"
    mv "$CHUNKS_FILE.tmp" "$CHUNKS_FILE"
}

# Keeps each chunk in CHUNK_DONE whose files are in PARTS as recorded (size,
# SHA-256, a score line per frame), as done by an earlier run; drops the
# others, to encode again.
check_chunks_done() {
    local k slot seconds bytes sha name frames lost=()
    (( ${#CHUNK_DONE[@]} > 0 )) || return 0
    for k in "${!CHUNK_DONE[@]}"; do
        progress "Checking chunk $((k + 1)) from an earlier run…"
        IFS=$'\t' read -r slot seconds bytes sha <<<"${CHUNK_DONE[$k]}"
        name=$(printf 'chunk-%03d' "$k") frames=$(( CHUNK_START[k + 1] - CHUNK_START[k] ))
        if [[ -f $PARTS/$name.hevc && -f $PARTS/$name.tsv ]] && (( $(stat -c %s "$PARTS/$name.hevc") == bytes )) &&
            (( $(wc -l <"$PARTS/$name.tsv") == frames )) && [[ $(sha256sum <"$PARTS/$name.hevc" | cut -d' ' -f1) == "$sha" ]]; then
            echo "$k $frames - $seconds" >>"$FARM/video-done"
        else
            unset "CHUNK_DONE[$k]"
            lost+=($((k + 1)))
        fi
    done
    progress ""
    local kept=()
    for k in "${!CHUNK_DONE[@]}"; do kept+=($((k + 1))); done
    (( ${#kept[@]} == 0 )) || ok "From earlier runs, as recorded: chunk $(ranges "${kept[@]}")"
    (( ${#lost[@]} == 0 )) || warn "Missing or changed since recorded, so encoded again: chunk $(ranges "${lost[@]}")"
}

# Splits the video at the planned joins into $PARTS/chunk-<k>.mkv and
# checks each has its planned frames.
split_chunks() {
    local k got want
    progress "Splitting the video into $CHUNKS chunks…"
    # By packet number, not time: on an H.264 source, -segment_times passed
    # over the planned keyframe to the next one.
    ffmpeg -nostdin -v error -i "$INPUT" -map 0:"$V" -c copy -f segment -segment_frames "$(IFS=,; echo "${CHUNK_START[*]:1:CHUNKS-1}")" \
        -reset_timestamps 1 "$PARTS/chunk-%03d.mkv"
    for ((k = 0; k < CHUNKS; k++)); do
        progress "Checking chunk $((k + 1))/$CHUNKS…"
        got=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$(printf '%s/chunk-%03d.mkv' "$PARTS" "$k")" | wc -l)
        # The first chunk holds the packets of the frames before it too.
        want=$(( CHUNK_START[k + 1] - (k > 0 ? CHUNK_START[k] : 0) ))
        (( got == want )) || die "chunk $k has $got frames, planned $want"
    done
    progress ""
    ok "Split at source keyframes; every chunk has its planned frames"
}

# One chunk (`farm_job_chunk <slot> <k>`): ffmpeg decoding into the x265
# CLI on the slot, with the chunk's frame count; all but the last chunk aim
# to end with the VBV buffer back at 90%, the fullness the next one starts
# from. Without the RPU: Dolby Vision goes in once the chunks are joined.
# The slot then scores the chunk against its source (score_frames) into
# $PARTS/<chunk>.tsv. Checked, the chunk is recorded in CHUNKS_FILE.
# A chunk's first frame has no predecessor for VMAF's motion or XPSNR's
# temporal term: about 1 VMAF lower and XPSNR higher there than in one
# pass over the film, on one frame per chunk.
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
    # Over the last 5 s only: x265 steers toward the end fullness from frame
    # --vbv-end-fr-adj (a fraction of --frames), by default the first, and
    # a whole chunk near the VBV cap then came out 40% smaller.
    (( k < CHUNKS - 1 )) &&
        end="--vbv-end 0.9 --vbv-end-fr-adj $(awk -v n="$frames" -v r="$FPS" 'BEGIN { a = 1 - 5 * r / n; printf "%.3f", (a > 0 ? a : 0) }')"
    slot_put "$i" "$PARTS/$name.mkv" "$name.mkv" || return
    slot_run "$i" "$(
        printf 'set -euo pipefail\n'
        declare -p DIST_FILTER REF_FILTER VMAF_OPTIONS
        declare -f score_frames
        cat <<EOF
echo step=encode
start=\$SECONDS
{ ffmpeg -nostdin -v error -nostats -progress pipe:3 -i $name.mkv -map 0:v:0 $(printf '%q ' "${VF[@]}") -fps_mode passthrough \\
    -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m --preset $PRESET --crf $SELECTED_CRF --output-depth 10 --profile main10 $(printf '%q ' "${cli[@]}") \\
        --frames $frames $end --log-level error --no-progress -o $name.hevc; } 4>&1
echo "result=\$((SECONDS - start))"
echo step=score
# A raw stream has no frame rate of its own: ffmpeg would take 25 fps.
score_frames $name.hevc $name.mkv 0 $name.tsv -nostats -progress pipe:1 -framerate $V_FPS
rm -f $name.mkv
EOF
    )" | farm_follow "$i" "chunk:$k"
    (( PIPESTATUS[0] == 0 )) || return "${PIPESTATUS[0]}"
    slot_get "$i" "$name.hevc" "$PARTS/$name.hevc" || return
    slot_get "$i" "$name.tsv" "$PARTS/$name.tsv" || return
    slot_rm "$i" "$name.mkv"
    got=$(ffprobe -v error -show_entries packet=size -of csv=p=0 "$PARTS/$name.hevc" | wc -l)
    (( got == frames )) || { rm -f "$PARTS/$name.hevc"; echo "$name.hevc has $got frames, not $frames" >&2; return 1; }
    got=$(wc -l <"$PARTS/$name.tsv")
    (( got == frames )) || { rm -f "$PARTS/$name.tsv"; echo "$name.tsv scores $got frames, not $frames" >&2; return 1; }
    rm -f "$PARTS/$name.mkv"
    # One line appended per chunk (jobs run side by side), after every check.
    # Seconds of encoding, the score left out.
    printf 'encoded\t%d\t%s\t%s\t%s\t%s\n' "$k" "${SLOT_NAME[i]}" "$(<"$FARM/jobs/chunk_$k.result")" \
        "$(stat -c %s "$PARTS/$name.hevc")" "$(sha256sum <"$PARTS/$name.hevc" | cut -d' ' -f1)" >>"$CHUNKS_FILE"
    echo "$k $frames $i $(<"$FARM/jobs/chunk_$k.result")" >>"$FARM/video-done"
}

# Per slot, after the encode: its chunks, frames, speed and share.
video_slots() {
    local i chunks
    heading "Slots  ${DIM}chunks encoded${RESET}"
    printf '  %s%-14s %7s %9s %6s  %s%s\n' "$DIM" slot frames speed share chunks "$RESET"
    for i in "${!SLOT_HOST[@]}"; do
        mapfile -t chunks < <(awk -v s="$i" '$3 == s { print $1 + 1 }' "$FARM/video-done")
        awk -v s="$i" -v total="$CHUNK_FRAMES_TOTAL" -v name="${SLOT_NAME[i]}" '
            $3 == s { f += $2; t += $4 }
            END { printf "  %-14s %7d %9s %5.0f%%  ", name, f, (t > 0 ? sprintf("%.2f fps", f / t) : "—"), f / total * 100 }' \
            "$FARM/video-done"
        wrap_text 51 "${chunks[*]:+$(ranges "${chunks[@]}")}"
    done
    mapfile -t chunks < <(awk '$3 == "-" { print $1 + 1 }' "$FARM/video-done")
    (( ${#chunks[@]} == 0 )) || {
        awk -v total="$CHUNK_FRAMES_TOTAL" '$3 == "-" { f += $2 } END { printf "  %-14s %7d %9s %5.0f%%  ", "earlier runs", f, "—", f / total * 100 }' \
            "$FARM/video-done"
        wrap_text 51 "$(ranges "${chunks[@]}")"
    }
}

video_total() {
    local i frames=0 frame _ step elapsed=$(( SECONDS - FARM_VIDEO_START )) finished earlier earlier_chunks
    for i in "${!SLOT_HOST[@]}"; do
        [[ -n ${SLOT_JOB[i]:-} ]] && read -r frame _ step 2>/dev/null <"$FARM/slot-$i.state" || continue
        # A chunk being scored is encoded.
        [[ $step == score ]] && frame=$(<"$FARM/slot-$i.total")
        frames=$((frames + frame))
    done
    # Chunks from earlier runs (slot "-") count as done, not towards the speed.
    read -r finished earlier earlier_chunks < <(awk '{ s += $2 } $3 == "-" { e += $2; n++ } END { print s + 0, e + 0, n + 0 }' \
        "$FARM/video-done" 2>/dev/null || echo 0 0 0)
    frames=$((frames + finished))
    awk -v f="$frames" -v p="$earlier" -v t="$CHUNK_FRAMES_TOTAL" -v e="$elapsed" -v d="$((FARM_DONE + earlier_chunks))" -v n="$CHUNKS" 'BEGIN {
        r = (e > 0 ? (f - p) / e : 0)
        printf "Video · %d/%d chunks · %.1f%% · %.2f fps · ETA ", d, n, f / t * 100, r
        if (r > 0) { s = (t - f) / r; printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 } else printf "—" }'
}

# Numbers $@ (sorted) as ranges: "1–9 12 14–16".
ranges() {
    awk '{ n[NR] = $1 } END {
        for (i = 1; i <= NR; i = j + 1) {
            for (j = i; j < NR && n[j + 1] == n[j] + 1; j++) ;
            printf "%s%s", (i > 1 ? " " : ""), (j > i ? n[i] "–" n[j] : n[i])
        } }' < <(printf '%s\n' "$@" | sort -n)
}

# The chunks in the queue's order, for farm_draw: farm_schedule's pending
# list is in scope, being farm_draw's caller.
video_detail() {
    local i id finished=() running=() retry=() queued=()
    mapfile -t finished < <(awk '{ print $1 + 1 }' "$FARM/video-done" 2>/dev/null)
    for i in "${!SLOT_HOST[@]}"; do
        [[ ${SLOT_JOB[i]:-} == chunk:* ]] && running+=($(( ${SLOT_JOB[i]#chunk:} + 1 )))
    done
    for id in "${pending[@]}"; do
        if (( ${FARM_TRIES[$id]:-0} > 0 )); then retry+=($(( ${id#chunk:} + 1 ))); else queued+=($(( ${id#chunk:} + 1 ))); fi
    done
    printf 'Chunks'
    (( ${#finished[@]} == 0 )) || printf ' · done %s' "$(ranges "${finished[@]}")"
    (( ${#running[@]} == 0 )) || printf ' · encoding %s' "${running[*]}"
    (( ${#retry[@]} == 0 )) || printf ' · retry %s' "${retry[*]}"
    (( ${#queued[@]} == 0 )) || printf ' · next %s' "$(ranges "${queued[@]}")"
    [[ -z ${FARM_HELD:-} ]] || printf ' (%s held for a faster slot)' "$(( ${FARM_HELD#chunk:} + 1 ))"
}

# Section 4's video step on every slot: plan (or, after load_chunks, check
# what earlier runs did), split, encode the chunks still to do, join them
# into VIDEO_HEVC and, with Dolby Vision, put the source RPU in.
farm_encode_video() {
    local k ran frames
    heading "Video on ${#SLOT_HOST[@]} slots"
    if [[ -n $DRY_RUN ]]; then
        item "Chunks of ≈ $(hms "$CHUNK_SECONDS") joined at scene cuts, one x265 per slot:"
        for i in "${!SLOT_HOST[@]}"; do setting "${SLOT_NAME[i]}" "x265 $PRESET CRF $SELECTED_CRF ${SLOT_POOLS[i]:+--pools ${SLOT_POOLS[i]} }${SLOT_ARM[i]:+(no asm) }${WRAP[${SLOT_HOST[i]}]:+under ${WRAP[${SLOT_HOST[i]}]}}"; done
        [[ -n ${DV_PROFILE:-} ]] && setting "Dolby Vision" "dovi_tool inject-rpu on the joined stream"
        return 0
    fi
    : >"$FARM/video-done"
    if (( ${#CHUNK_START[@]} == 0 )); then
        plan_chunks
        write_chunks_plan
    else
        kv "Chunks" "$CHUNKS · $CHUNK_FRAMES_TOTAL frames · planned in an earlier run"
        check_chunks_done
    fi
    FARM_QUEUE=() FARM_EXTRA=()
    for ((k = 0; k < CHUNKS; k++)); do [[ -n ${CHUNK_DONE[$k]:-} ]] || FARM_QUEUE+=("chunk:$k"); done
    ENCODE_SECONDS=0
    if (( ${#FARM_QUEUE[@]} > 0 )); then
        # The split video beside the intermediates the single-host encode needs.
        local need free
        need=$(awk -v v="$(stream_bps "$V")" -v d="$DURATION" -v s="$SELECTED_SIZE" 'BEGIN { printf "%.0f", v * d / 8 + s * 2.2 }')
        free=$(df --output=avail -B1 "$PARTS" | tail -1)
        (( free >= need )) || die "Needs ≈ $(human_bytes "$need") free beside the output for the chunks, $(human_bytes "$free") available"
        split_chunks
        for k in "${!CHUNK_DONE[@]}"; do rm -f "$(printf '%s/chunk-%03d.mkv' "$PARTS" "$k")"; done
        FARM_TOTAL=video_total FARM_DETAIL=video_detail FARM_VIDEO_START=$SECONDS
        ENCODE_START=$SECONDS
        farm_schedule
        ENCODE_SECONDS=$((SECONDS - ENCODE_START))
        read -r ran frames < <(awk '$3 != "-" { n++; f += $2 } END { print n + 0, f + 0 }' "$FARM/video-done")
        ok "$ran chunks in $(hms "$ENCODE_SECONDS") · $(awk -v f="$frames" -v s="$ENCODE_SECONDS" 'BEGIN { printf "%.2f", (s > 0 ? f / s : 0) }') fps"
    fi
    video_slots
    progress "Joining the chunks…"
    # The chunks stay until mux_parts removes PARTS, for a run cut short
    # while joining or muxing to go on from.
    : >"$VIDEO_HEVC"
    for ((k = 0; k < CHUNKS; k++)); do
        cat "$(printf '%s/chunk-%03d.hevc' "$PARTS" "$k")" >>"$VIDEO_HEVC"
    done
    progress ""
    if [[ -n ${DV_PROFILE:-} ]]; then
        progress "Putting the Dolby Vision RPU in…"
        dovi_tool inject-rpu -i "$VIDEO_HEVC" --rpu-in "$RPU" -o "$VIDEO_HEVC.dv" >/dev/null && mv -f "$VIDEO_HEVC.dv" "$VIDEO_HEVC"
        progress ""
    fi
}
