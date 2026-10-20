# Section 3: CRF calibration. For each preset in PRESET_NAMES, encodes
# CALIBRATION_SAMPLES stream-copied cuts at its CRFs (lowest first) through
# the entry script's encode_sample hook, scores them with libvmaf
# (VMAF_OPTIONS) and XPSNR, and keeps the highest CRF before the first failed
# gate. Then picks a preset: the fastest (by the encoder's preset order)
# whose file is within SIZE_TOLERANCE of the smallest. Measurements are
# cached per preset and CRF in the .analysis (locate_analysis), so a new CRF
# list or gate only encodes CRFs never measured. cut_worst_sample then
# encodes the chosen setting's worst scene next to the output, for a look
# before the full encode.
# Sourced by the entry scripts.
#
# The entry script provides: PRESETS (parsed by parse_presets) ENCODER_PARAMS
# VF REF_FILTER DIST_FILTER VMAF_OPTIONS VMAF_TARGET_MEAN VMAF_TARGET_LOW
# CAMBI_MAX KNEE_RATIO SAMPLE_PERCENT SAMPLE_DURATION COLOUR_FLAGS, and
# `encode_sample <preset> <crf> <in>
# <out> [ffmpeg options…]`, which passes the extra options to ffmpeg before
# its input (they request -progress output on stdout).
#
# Sets for the encode: PRESET SELECTED_CRF SELECTED_SIZE STOPPED ENCODE_FPS
# WORST_SCENE_AT WORST_SCENE_LOW ROWS ANALYSIS_CREATED, and the stereo GAIN,
# STEREO_FILTER and SOURCE_SHA256.

# CALIBRATION_SAMPLES: enough samples of SAMPLE_DURATION to cover
# SAMPLE_PERCENT of the film, rounded up.
sample_count() {
    awk -v p="$SAMPLE_PERCENT" -v d="$DURATION" -v l="$SAMPLE_DURATION" 'BEGIN { n = p / 100 * d / l; c = int(n); print (c < n ? c + 1 : c) }'
}

# A slower preset is only worth it for a file this much smaller.
SIZE_TOLERANCE=0.10

# A CRF step that multiplies CAMBI's worst half second by CAMBI_JUMP, to
# CAMBI_JUMP_FROM or more, is where banding sets in: the walk stops there,
# under CAMBI_MAX. The samples miss most of a film's dark gradients, where
# whole-film CAMBI has come out about 3× the calibrated value, so CAMBI_MAX
# alone stops the walk too late.
CAMBI_JUMP=2
CAMBI_JUMP_FROM=1

# Prints the section 2 summary of the gates.
plan_gates() {
    local i
    heading "CRF selection"
    item "Per preset: highest CRF, walking up, that passes every gate"
    for i in "${!PRESET_NAMES[@]}"; do
        setting "Preset ${PRESET_NAMES[i]}" "CRF ${PRESET_CRFS[i]// /, }"
    done
    setting "VMAF NEG" "mean ≥ $VMAF_TARGET_MEAN · 1%-low ≥ $VMAF_TARGET_LOW (pooled)"
    setting "Every scene" "1%-low ≥ $VMAF_TARGET_LOW"
    setting "Banding" "CAMBI (vs source) ≤ $CAMBI_MAX in every half second"
    setting "Banding onset" "stop where a step takes CAMBI ×$CAMBI_JUMP, to ≥ $CAMBI_JUMP_FROM"
    setting "Efficiency" "stop at an XPSNR knee (step > ${KNEE_RATIO}× previous)"
    [[ -z $SCORE ]] || setting "Whole film" "scored after the encode · FULL_* tags"
    (( ${#PRESET_NAMES[@]} == 1 )) ||
        setting "Preset choice" "fastest within $(awk -v t="$SIZE_TOLERANCE" 'BEGIN { print t * 100 }')% of the smallest file"
}

# Prints one row of the CRF table and appends it to CALIBRATED_ROWS.
# Fields: crf neg 1%-low scene-1%-low cambi-worst-half-second xpsnr Δxpsnr Mb/s est-bytes verdict;
# never empty, as reading the tab-separated row back collapses empty fields.
row() {
    local IFS=$'\t'
    CALIBRATED_ROWS+=("$*")
    print_row "$@"
}

# Column widths of the CRF table, shared by header and rows.
TABLE_WIDTHS=(4 6 6 6 6 7 6 6 10)

# Prints cells centred in TABLE_WIDTHS, one space apart.
table_cells() {
    local i out=""
    for ((i = 1; i <= $#; i++)); do
        out+="$(cell "${TABLE_WIDTHS[i - 1]}" "${!i}") "
    done
    printf '%s' "$out"
}

print_row() {
    if [[ ${10} == "not run"* ]]; then
        printf '  %s%s%s%s\n' "$(cell 4 "$1") " "$DIM" "${10}" "$RESET"
        return
    fi
    local colour=$RED verdict=${10/#fail: /✖ }
    [[ ${10} == pass ]] && colour=$GREEN
    printf '  %s %s%s%s\n' "$(table_cells "$1" "$(printf '%.2f' "$2")" "$(printf '%.2f' "$3")" "$(printf '%.2f' "$4")" \
        "$(printf '%.2f' "$5")" "$(printf '%.2f' "$6")" "$7" "$8" "$(human_bytes "$9")")" "$colour" "$verdict" "$RESET"
}

print_table_header() {
    printf '  %s%s verdict%s\n' "$DIM" "$(table_cells CRF NEG "1%" scene CAMBI XPSNR Δ Mb/s "est. size")" "$RESET"
}

print_table_legend() {
    printf '  %sNEG, 1%%: pooled VMAF NEG mean and 1%%-low · scene: worst sample'"'"'s 1%%-low%s\n' "$DIM" "$RESET"
    printf '  %sCAMBI: worst ½ s, banding added vs source · Δ: XPSNR lost vs previous CRF%s\n' "$DIM" "$RESET"
}

# Any change to the source, an encode setting, the encode or scoring filters,
# the VMAF options or the measuring code makes a preset's stored
# measurements stale. CRF lists and gates are not part of it: they only
# judge measurements, so changing them reuses what is stored. Nor is where
# a sample was measured: the functions below are what every host runs, and
# asm only picks x265's SIMD kernels, which are bit-exact with its C code.
preset_fingerprint() {
    {
        stat -L -c '%s %Y' "$INPUT"
        printf '%s\n' "$1" "${ENCODER_PARAMS//:asm=avx512/}" "${COLOUR_FLAGS[*]}" "$CROP" "$CALIBRATION_SAMPLES" \
            "$SAMPLE_DURATION" "${VF[*]}" "$REF_FILTER" "$DIST_FILTER" "$VMAF_OPTIONS" "$A" "$STEREO_BITRATE"
        declare -f cut_samples encode_sample score_vmaf score_xpsnr aggregate_crf
    } | sha256sum | cut -d' ' -f1
}

# The stereo gain and the source hash, shared by every preset.
shared_fingerprint() {
    {
        stat -L -c '%s %Y' "$INPUT"
        printf '%s\n' "$A" "$STEREO_PREFILTER" "$TARGET_PEAK"
        declare -f measure_gain
    } | sha256sum | cut -d' ' -f1
}

# Sets ANALYSIS: <input stem>.analysis in MOVIE_DIR, which it creates. One
# beside the input, where earlier versions kept it, is moved in.
locate_analysis() {
    local old="${INPUT%.*}.analysis"
    ANALYSIS="$MOVIE_DIR/$(basename "$old")"
    mkdir -p "$MOVIE_DIR"
    [[ -e $ANALYSIS || ! -f $old ]] || mv "$old" "$ANALYSIS"
}

# Reads ANALYSIS into CACHE (plain key=value lines — never sourced):
# shared values under their own keys, each preset's fingerprint under
# "<preset>.fingerprint", and one CRF's measurements under "<preset>@<crf>"
# (tab-separated: created neg 1%-low scene-1%-low scene-at cambi xpsnr Mb/s
# est-bytes frames seconds).
load_analysis() {
    local line
    declare -gA CACHE=()
    [[ -f $ANALYSIS ]] || return 0
    while IFS= read -r line; do
        [[ $line == \#* || $line != *=* ]] && continue
        CACHE[${line%%=*}]=${line#*=}
    done <"$ANALYSIS"
}

save_analysis() {
    local key
    {
        echo "# $(basename "$0") calibration of $(basename "$INPUT") — delete to recalibrate"
        for key in fingerprint peak loudness lra gain source_sha256; do
            echo "$key=${CACHE[$key]:-}"
        done
        for key in $(printf '%s\n' "${!CACHE[@]}" | grep -E '\.fingerprint$|@' | sort -V); do
            echo "$key=${CACHE[$key]}"
        done
    } >"$ANALYSIS.tmp"
    mv "$ANALYSIS.tmp" "$ANALYSIS"
}

# The live block drawn under the CRF table while a CRF is calibrated (terminal
# only): a header line, then one line per step of the current sample.
STEP_NAMES=("encode" "VMAF+CAMBI" "XPSNR")
BLOCK_DRAWN=0

draw_block() {
    [[ -t 1 ]] || return 0
    local i
    (( BLOCK_DRAWN )) && printf '\e[%dA' $(( ${#STEP_NAMES[@]} + 1 ))
    printf '\r\e[K  %s %s▸ %s%s\n' "$(cell 4 "$BLOCK_CRF")" "$BOLD" "$BLOCK_HEADER" "$RESET"
    for i in "${!STEP_NAMES[@]}"; do
        printf '\r\e[K          %-11s %s\n' "${STEP_NAMES[i]}" "${STEP_STATUS[i]}"
    done
    BLOCK_DRAWN=1
}

clear_block() {
    [[ -t 1 ]] || return 0
    (( BLOCK_DRAWN )) && printf '\e[%dA\e[J' $(( ${#STEP_NAMES[@]} + 1 ))
    BLOCK_DRAWN=0
}

# Starts a sample in the live block: every step waiting.
begin_sample() {
    local i
    BLOCK_HEADER=$1
    for i in "${!STEP_NAMES[@]}"; do
        STEP_STATUS[i]="$DIM$(bar 0 16)  waiting$RESET"
    done
    draw_block
}

# Runs step $1 of the live block over $2 frames: the remaining arguments are
# a command writing ffmpeg -progress key=value lines to stdout.
run_step() {
    local i=$1 total=$2 start=$SECONDS
    shift 2
    background step_frames "$i" "$total" "$@"
    STEP_STATUS[i]="$GREEN✔$RESET $DIM$((SECONDS - start)) s$RESET"
    draw_block
}

step_frames() {
    local i=$1 total=$2
    shift 2
    "$@" | while IFS='=' read -r key value; do
        case $key in
            frame) frame=$value ;;
            fps) fps=$value ;;
            progress)
                STEP_STATUS[i]="$(bar "$(awk -v f="${frame:-0}" -v t="$total" 'BEGIN { print (t > 0 ? f / t : 0) }')" 16) $(awk -v f="${frame:-0}" -v t="$total" -v r="${fps:-0}" 'BEGIN {
                    printf "%3.0f%% · %s fps · ETA ", (t > 0 ? f / t * 100 : 0), r
                    if (r > 0) { e = (t - f) / r; printf "%d:%02d", e / 60, e % 60 } else printf "—" }')"
                draw_block
                ;;
        esac
    done
}

# As run_step, for a command whose -progress reports time (out_time_us)
# rather than frames: $2 is the total duration in seconds.
run_time_step() {
    local i=$1 total=$2 start=$SECONDS
    shift 2
    background step_time "$i" "$total" "$@"
    STEP_STATUS[i]="$GREEN✔$RESET $DIM$((SECONDS - start)) s$RESET"
    draw_block
}

step_time() {
    local i=$1 total=$2
    shift 2
    "$@" | while IFS='=' read -r key value; do
        case $key in
            out_time_us) [[ $value =~ ^[0-9]+$ ]] && done_s=$(( value / 1000000 )) ;;
            speed) speed=${value%x} ;;
            progress)
                STEP_STATUS[i]="$(bar "$(awk -v d="${done_s:-0}" -v t="$total" 'BEGIN { print d / t }')" 16) $(awk -v d="${done_s:-0}" -v t="$total" -v s="${speed:-0}" 'BEGIN {
                    printf "%3.0f%% · %sx · ETA ", d / t * 100, s
                    if (s > 0) { e = (t - d) / s; printf "%d:%02d", e / 60, e % 60 } else printf "—" }')"
                draw_block
                ;;
        esac
    done
}

# Hashes INPUT into SOURCE_SHA256 as step $1 of the live block, following
# sha256sum's read position in /proc.
hash_step() {
    local i=$1 size pid fd pos=0 start now rate out="$WORK/sha256" target
    size=$(stat -L -c %s "$INPUT")
    target=$(readlink -f "$INPUT")
    start=$(date +%s.%N)
    sha256sum "$INPUT" >"$out" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        for fd in /proc/"$pid"/fd/*; do
            [[ $(readlink "$fd" 2>/dev/null) == "$target" ]] &&
                pos=$(awk '$1 == "pos:" { print $2 }' "/proc/$pid/fdinfo/${fd##*/}" 2>/dev/null || echo "$pos")
        done
        now=$(date +%s.%N)
        rate=$(awk -v p="${pos:-0}" -v s="$start" -v n="$now" 'BEGIN { print (n > s ? p / (n - s) : 0) }')
        STEP_STATUS[i]="$(bar "$(awk -v p="${pos:-0}" -v t="$size" 'BEGIN { print p / t }')" 16) $(awk -v p="${pos:-0}" -v t="$size" -v r="$rate" 'BEGIN {
            printf "%3.0f%% · %.0f MB/s · ETA ", p / t * 100, r / 1e6
            if (r > 0) { e = (t - p) / r; printf "%d:%02d", e / 60, e % 60 } else printf "—" }')"
        draw_block
        sleep 0.5
    done
    wait "$pid"
    SOURCE_SHA256=$(cut -d' ' -f1 "$out")
    STEP_STATUS[i]="$GREEN✔$RESET $DIM$(awk -v s="$start" -v n="$(date +%s.%N)" 'BEGIN { printf "%.0f", n - s }') s$RESET"
    draw_block
}

# Cuts the samples once, for every preset that needs calibrating.
# Stream-copied cuts are both the encoder input and the reference, so the
# two decode exactly the same frames.
cut_samples() {
    local n
    [[ -n ${SAMPLES_CUT:-} ]] && return 0
    SAMPLES_AT=() SAMPLE_FRAMES=()
    for ((n = 0; n < CALIBRATION_SAMPLES; n++)); do
        progress "Cutting sample $((n + 1))/$CALIBRATION_SAMPLES…"
        # Each sample sits in the middle of its share of 5%–95%, so one
        # sample is mid-film.
        SAMPLES_AT[n]=$(awk -v d="$DURATION" -v n="$n" -v t="$CALIBRATION_SAMPLES" 'BEGIN { printf "%.0f", d * (0.05 + 0.90 * (n + 0.5) / t) }')
        ffmpeg -nostdin -v error -y -ss "${SAMPLES_AT[n]}" -i "$INPUT" -t "$SAMPLE_DURATION" -map 0:"$V" -c copy "$WORK/ref$n.mkv"
        SAMPLE_FRAMES[n]=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$WORK/ref$n.mkv")
    done
    progress ""
    SAMPLES_CUT=1
}

# Scores encode $1 against reference $2 with libvmaf (VMAF_OPTIONS),
# writing the per-frame JSON log to $3; further arguments go to ffmpeg
# before its inputs.
score_vmaf() {
    ffmpeg -nostdin -v error "${@:4}" -i "$1" -i "$2" \
        -lavfi "[0:v]${DIST_FILTER}[d];[1:v]${REF_FILTER}[r];[d][r]libvmaf=$VMAF_OPTIONS:n_threads=$(nproc):log_fmt=json:log_path=$3" -f null -
}

# Scores encode $1 against reference $2 with XPSNR, whose summary goes to
# stderr; further arguments go to ffmpeg before its inputs.
# ffmpeg 9.0.1's xpsnr misreads 10-bit rows unless a frame's stride is
# exactly its width (identical inputs score ≈ 10 dB). A crop keeps its
# parent's stride, so both inputs are padded, identically, into new frames a
# multiple of 64 wide.
score_xpsnr() {
    ffmpeg -nostdin -hide_banner "${@:3}" -i "$1" -i "$2" \
        -lavfi "[0:v]$DIST_FILTER,pad=ceil((iw+1)/64)*64:ih[d];[1:v]$REF_FILTER,pad=ceil((iw+1)/64)*64:ih[r];[d][r]xpsnr" \
        -f null -
}

# The Y value from score_xpsnr's summary on stdin.
xpsnr_y() { grep -o 'XPSNR  y: *[0-9.]*' | tail -1 | grep -o '[0-9.]*$'; }

# Encodes and scores every sample at one preset and CRF
# (`measure_crf <preset> <crf>`) under the live block, and stores the
# measurements in CACHE["<preset>@<crf>"].
measure_crf() {
    local preset=$1 crf=$2 n ref enc log start end frames
    cut_samples
    BLOCK_CRF=$crf
    for ((n = 0; n < CALIBRATION_SAMPLES; n++)); do
        ref="$WORK/ref$n.mkv" enc="$WORK/enc-$preset-$crf-$n.mkv" log="$WORK/vmaf-$preset-$crf-$n.json"
        begin_sample "sample $((n + 1))/$CALIBRATION_SAMPLES · $(hms "${SAMPLES_AT[n]}")"
        start=$(date +%s.%N)
        run_step 0 "${SAMPLE_FRAMES[n]}" encode_sample "$preset" "$crf" "$ref" "$enc" -nostats -progress pipe:1
        end=$(date +%s.%N)
        frames=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$enc")
        run_step 1 "$frames" score_vmaf "$enc" "$ref" "$log" -nostats -progress pipe:1
        # XPSNR's summary is on stderr; stdout carries the progress.
        run_step 2 "$frames" score_xpsnr "$enc" "$ref" -nostats -progress pipe:1 2>"$WORK/xpsnr.log"
        echo "$frames $(stat -c %s "$enc") $(awk -v s="$start" -v e="$end" 'BEGIN { printf "%f", e - s }') $(xpsnr_y <"$WORK/xpsnr.log")" \
            >"$WORK/result-$preset-$crf-$n"
    done
    clear_block
    aggregate_crf "$preset" "$crf"
}

# Pools one preset and CRF's samples into CACHE["<preset>@<crf>"]: for each
# sample n, $WORK/result-<preset>-<crf>-<n> ("frames bytes encode-seconds
# xpsnr") and its VMAF log $WORK/vmaf-<preset>-<crf>-<n>.json.
aggregate_crf() {
    local preset=$1 crf=$2 n log frames bytes seconds xpsnr low cambi neg neg_low mbps xpsnr_mean est_bytes
    local enc_bytes=0 frames_total=0 xpsnr_weighted=0 scene_low=101 scene_at="" cambi_max=0 enc_seconds=0 w warnings=()
    local audio_bps=$(( $(stream_bps "$A") + ${STEREO_BITRATE%k} * 1000 ))
    local window
    window=$(awk -v r="$FPS" 'BEGIN { printf "%d", r / 2 + 0.5 }')
    for ((n = 0; n < CALIBRATION_SAMPLES; n++)); do
        log="$WORK/vmaf-$preset-$crf-$n.json"
        read -r frames bytes seconds xpsnr <"$WORK/result-$preset-$crf-$n"
        [[ $frames == "${SAMPLE_FRAMES[n]}" ]] || warnings+=("$preset CRF $crf sample $n: reference has ${SAMPLE_FRAMES[n]} frames, encode has $frames — scores may be misaligned.")
        # CAMBI's worst half second (the highest mean over any run of
        # frames that long), not its mean, which stays low while a dark
        # scene bands visibly, nor its worst frame: a single frame at a
        # scene cut can score 3+ at any CRF, with VMAF near 100 there.
        read -r low cambi < <(jq -r --argjson w "$window" '
            ([.frames[].metrics.vmaf] | sort) as $s
            | [.frames[].metrics.cambi_full_reference] as $c
            | ([range(0; ($c | length) - $w + 1) as $i | $c[$i:$i + $w] | add / $w] | max // ($c | add / length)) as $cw
            | "\($s[($s | length) / 100 | floor]) \($cw)"' "$log")
        if awk -v l="$low" -v w="$scene_low" 'BEGIN { exit !(l < w) }'; then
            scene_low=$low scene_at=$(hms "${SAMPLES_AT[n]}")
        fi
        read -r cambi_max enc_seconds enc_bytes frames_total xpsnr_weighted < <(awk -v c="$cambi" -v cm="$cambi_max" \
            -v t="$enc_seconds" -v s="$seconds" -v b="$enc_bytes" -v sz="$bytes" \
            -v f="$frames_total" -v n="$frames" -v x="$xpsnr_weighted" -v xp="${xpsnr:-0}" \
            'BEGIN { printf "%f %f %d %d %f\n", (c > cm ? c : cm), t + s, b + sz, f + n, x + xp * n }')
    done
    for w in "${warnings[@]}"; do
        warn "$w"
    done

    # Pooled over every sampled frame, not averaged per sample, so a short bad
    # scene weighs as much as it does on screen.
    read -r neg neg_low < <(jq -rs '
        ([.[].frames[].metrics.vmaf] | sort) as $s
        | "\(($s | add) / ($s | length)) \($s[($s | length) / 100 | floor])"' "$WORK"/vmaf-"$preset"-"$crf"-*.json)
    read -r mbps xpsnr_mean est_bytes < <(awk -v b="$enc_bytes" -v f="$frames_total" -v r="$FPS" \
        -v x="$xpsnr_weighted" -v d="$DURATION" -v a="$audio_bps" \
        'BEGIN { v = b * 8 / (f / r); printf "%.1f %.2f %.0f\n", v / 1e6, x / f, d * (v + a) / 8 }')
    CACHE[$preset@$crf]=$(printf '%s\t' "$(date '+%Y-%m-%d %H:%M')" "$neg" "$neg_low" "$scene_low" "$scene_at" \
        "$cambi_max" "$xpsnr_mean" "$mbps" "$est_bytes" "$frames_total" "$enc_seconds")
}

# Prints the first gate a CRF fails (mean, 1%-low, scene, banding, CAMBI
# jump, knee), or nothing when it passes: `crf_verdict <neg> <1%-low>
# <scene 1%-low> <cambi> <previous cambi> <xpsnr step> <previous step>`,
# the previous CRF's values empty for the walk's first CRF.
crf_verdict() {
    awk -v m="$1" -v l="$2" -v sl="$3" -v c="$4" -v pc="$5" -v st="$6" -v ps="$7" \
        -v tm="$VMAF_TARGET_MEAN" -v tl="$VMAF_TARGET_LOW" -v cx="$CAMBI_MAX" -v k="$KNEE_RATIO" \
        -v cj="$CAMBI_JUMP" -v cf="$CAMBI_JUMP_FROM" 'BEGIN {
            if (m < tm) print "mean"; else if (l < tl) print "1%-low"; else if (sl < tl) print "scene"
            else if (c > cx) print "banding"; else if (pc != "" && c >= cf && c >= cj * pc) print "CAMBI ×" cj
            else if (ps != "" && ps > 0 && st > k * ps) print "knee" }'
}

# Walks one preset's CRFs (`walk_preset <preset> <crf list>`), lowest first,
# measuring only CRFs with nothing stored, and judges each against the
# gates; prints the table and sets the RES_* entries for the preset.
walk_preset() {
    local preset=$1 crf created neg neg_low scene_low scene_at cambi xpsnr mbps est_bytes frames seconds
    local step failed verdict prev_xpsnr="" prev_step="" prev_cambi="" stopped="" chosen="" chosen_size="" newest=""
    local best_scene_low=101 best_scene_at="" frames_all=0 seconds_all=0 reused=()
    CALIBRATED_ROWS=()

    for crf in $2; do
        if [[ -n $stopped ]]; then
            row "$crf" - - - - - - - - "not run — CRF $stopped already stopped the walk"
            continue
        fi
        if [[ -n ${CACHE[$preset@$crf]:-} ]]; then
            reused+=("$crf")
        else
            measure_crf "$preset" "$crf"
            save_analysis
        fi
        IFS=$'\t' read -r created neg neg_low scene_low scene_at cambi xpsnr mbps est_bytes frames seconds <<<"${CACHE[$preset@$crf]}"
        [[ $created > $newest ]] && newest=$created
        frames_all=$((frames_all + frames))
        seconds_all=$(awk -v a="$seconds_all" -v b="$seconds" 'BEGIN { print a + b }')
        step=$( [[ -n $prev_xpsnr ]] && awk -v p="$prev_xpsnr" -v x="$xpsnr" 'BEGIN { printf "%.2f", p - x }' || true)

        failed=$(crf_verdict "$neg" "$neg_low" "$scene_low" "$cambi" "$prev_cambi" "$step" "$prev_step")
        if [[ -z $failed ]]; then
            verdict="pass"
            chosen=$crf chosen_size=$est_bytes
            best_scene_low=$scene_low best_scene_at=$scene_at
        else
            verdict="fail: $failed"
            stopped=$crf
        fi
        row "$crf" "$neg" "$neg_low" "$scene_low" "$cambi" "$xpsnr" "${step:-—}" "$mbps" "$est_bytes" "$verdict"
        prev_xpsnr=$xpsnr prev_step=$step prev_cambi=$cambi
    done
    (( ${#reused[@]} == 0 )) ||
        printf '  %sCRF %s from %s%s\n' "$DIM" "$(IFS=,; echo "${reused[*]}" | sed 's/,/, /g')" "$(basename "$ANALYSIS")" "$RESET"

    RES_CRF[$preset]=$chosen
    RES_SIZE[$preset]=$chosen_size
    RES_STOPPED[$preset]=$stopped
    RES_FPS[$preset]=$(awk -v f="$frames_all" -v t="$seconds_all" 'BEGIN { printf "%.1f", (t > 0 ? f / t : 0) }')
    RES_SCENE_AT[$preset]=$best_scene_at
    RES_SCENE_LOW[$preset]=$best_scene_low
    RES_CREATED[$preset]=$newest
    RES_ROWS[$preset]=$(printf '%s\n' "${CALIBRATED_ROWS[@]}")
}

# Slots the full encode runs on at once (farm.sh sets more): each
# sample was measured on one slot, so they add up.
ENCODE_SLOTS=1

# Encode time of the whole film at a preset's measured speed, on
# ENCODE_SLOTS.
full_encode_hours() {
    awk -v fps="$1" -v s="$ENCODE_SLOTS" -v n="$(probe ".streams[$V].tags.NUMBER_OF_FRAMES // empty")" -v d="$DURATION" -v r="$FPS" \
        'BEGIN { total = (n > 0 ? n : d * r); printf "%.1f", total / (fps * s) / 3600 }'
}

# Drops preset $1's stored measurements, with a warning, when they were made
# for other inputs, and records its current fingerprint in CACHE.
check_fingerprint() {
    local preset=$1 fingerprint key
    fingerprint=$(preset_fingerprint "$preset")
    [[ ${CACHE[$preset.fingerprint]:-} == "$fingerprint" ]] && return 0
    if [[ -n ${CACHE[$preset.fingerprint]:-} ]]; then
        warn "Stored $preset measurements are for other inputs (source, settings, filters or measuring code changed) — measuring again"
        for key in "${!CACHE[@]}"; do
            [[ $key == "$preset@"* ]] && unset "CACHE[$key]"
        done
    fi
    CACHE[$preset.fingerprint]=$fingerprint
}

# Walks every preset in PRESETS, measures the stereo gain, saves the
# .analysis, then picks the preset and prints the decision. Exits when no
# preset has a passing CRF.
run_calibration() {
    local i preset fingerprint min_size best="" size
    declare -gA RES_CRF=() RES_SIZE=() RES_STOPPED=() RES_FPS=() RES_SCENE_AT=() RES_SCENE_LOW=() RES_CREATED=() RES_ROWS=()
    locate_analysis
    load_analysis

    for i in "${!PRESET_NAMES[@]}"; do
        preset=${PRESET_NAMES[i]}
        heading "Video · preset $preset"
        check_fingerprint "$preset"
        print_table_header
        walk_preset "$preset" "${PRESET_CRFS[i]}"
    done
    print_table_legend

    heading "Stereo gain"
    fingerprint=$(shared_fingerprint)
    if [[ ${CACHE[fingerprint]:-} == "$fingerprint" && -n ${CACHE[source_sha256]:-} ]]; then
        MEASURED_PEAK=${CACHE[peak]} MEASURED_I=${CACHE[loudness]} MEASURED_LRA=${CACHE[lra]} GAIN=${CACHE[gain]}
        SOURCE_SHA256=${CACHE[source_sha256]}
        set_stereo_filter
    else
        # Dynamic scope: the live block's helpers see these two steps.
        local STEP_NAMES=("downmix" "hash")
        BLOCK_CRF=""
        begin_sample "whole film · $(hms "$DURATION") · $(human_bytes "$(probe .format.size)")"
        measure_gain
        hash_step 1
        clear_block
        CACHE[fingerprint]=$fingerprint CACHE[peak]=$MEASURED_PEAK CACHE[loudness]=$MEASURED_I
        CACHE[lra]=$MEASURED_LRA CACHE[gain]=$GAIN CACHE[source_sha256]=$SOURCE_SHA256
    fi
    save_analysis
    print_gain

    # The fastest preset whose file is within SIZE_TOLERANCE of the smallest.
    # "Fastest" by the encoder's preset order (PRESET_NAMES is sorted on
    # it), not by the measured fps, which varies with machine load.
    min_size=""
    for preset in "${PRESET_NAMES[@]}"; do
        size=${RES_SIZE[$preset]}
        [[ -n $size ]] && { [[ -z $min_size ]] || (( size < min_size )); } && min_size=$size
    done
    for preset in "${PRESET_NAMES[@]}"; do
        size=${RES_SIZE[$preset]}
        [[ -n $size ]] || continue
        if awk -v s="$size" -v m="$min_size" -v t="$SIZE_TOLERANCE" 'BEGIN { exit !(s <= m * (1 + t)) }'; then
            best=$preset
            break
        fi
    done

    # A preset whose walk never failed has an unknown limit: a higher CRF
    # might pass and make it smaller, so comparing it with presets that did
    # reach their limit can pick the wrong one. One that failed at its lowest
    # CRF was never compared at all.
    local unbounded=() floored=() suggestion="" crfs last first
    if (( ${#PRESET_NAMES[@]} > 1 )); then
        heading "Presets"
        for i in "${!PRESET_NAMES[@]}"; do
            preset=${PRESET_NAMES[i]}
            if [[ -n ${RES_SIZE[$preset]} ]]; then
                printf '  %s%-9s CRF %-4s %10s · %5s fps · ≈ %5s h%s%s\n' "$([[ $preset == "$best" ]] && echo "$GREEN▸ " || echo "  ")" \
                    "$preset" "${RES_CRF[$preset]}" "$(human_bytes "${RES_SIZE[$preset]}")" "${RES_FPS[$preset]}" \
                    "$(full_encode_hours "${RES_FPS[$preset]}")" "$RESET" \
                    "$([[ -z ${RES_STOPPED[$preset]} ]] && echo " $YELLOW(limit not reached)$RESET")"
            else
                printf '    %-9s %sno CRF passes%s (CRF %s: %s)\n' "$preset" "$RED" "$RESET" "${RES_STOPPED[$preset]}" \
                    "$(awk -F'\t' -v c="${RES_STOPPED[$preset]}" '$1 == c { sub(/^fail: /, "", $10); print $10 }' <<<"${RES_ROWS[$preset]}")"
            fi
            if [[ -n ${RES_SIZE[$preset]} && -z ${RES_STOPPED[$preset]} ]]; then
                unbounded+=("$preset")
                last=${PRESET_CRFS[i]##* }
                crfs="${PRESET_CRFS[i]// /,},$(awk -v c="$last" 'BEGIN { printf "%g,%g,%g", c + 1, c + 2, c + 3 }')"
            elif [[ -z ${RES_SIZE[$preset]} ]]; then
                # Its lowest CRF already failed: a lower one may pass, and win.
                floored+=("$preset")
                first=${PRESET_CRFS[i]%% *}
                crfs="$(awk -v c="$first" 'BEGIN { for (x = c - 2; x < c; x++) if (x >= 0) printf "%g,", x }')${PRESET_CRFS[i]// /,}"
            else
                crfs=${PRESET_CRFS[i]// /,}
            fi
            suggestion+="${suggestion:+;}$preset:$crfs"
        done
    fi

    heading "Decision"
    if [[ -z $best ]]; then
        warn "${RED}${BOLD}No CRF passes${RESET} for any preset — add lower CRFs to PRESETS and rerun"
        [[ -z $suggestion ]] || printf '      To check (measured CRFs are reused): %sPRESETS="%s"%s\n' "$BOLD" "$suggestion" "$RESET"
        exit 1
    fi
    PRESET=$best
    SELECTED_CRF=${RES_CRF[$best]} SELECTED_SIZE=${RES_SIZE[$best]} STOPPED=${RES_STOPPED[$best]}
    ENCODE_FPS=${RES_FPS[$best]} ANALYSIS_CREATED=${RES_CREATED[$best]}
    WORST_SCENE_AT=${RES_SCENE_AT[$best]} WORST_SCENE_LOW=${RES_SCENE_LOW[$best]}
    mapfile -t ROWS <<<"${RES_ROWS[$best]}"

    ok "${GREEN}${BOLD}$PRESET · CRF $SELECTED_CRF${RESET} · ≈ $(human_bytes "$SELECTED_SIZE") (source $(human_bytes "$(probe .format.size)"))"
    (( ${#unbounded[@]} == 0 )) ||
        warn "Limit not reached for ${unbounded[*]}: every CRF passed, so a higher one may give a smaller file and change this choice."
    (( ${#floored[@]} == 0 )) ||
        warn "No CRF passes for ${floored[*]}: its lowest CRF already failed, so a lower one may pass and change this choice."
    if (( ${#unbounded[@]} + ${#floored[@]} > 0 )); then
        printf '      To check (measured CRFs are reused): %sPRESETS="%s"%s\n' "$BOLD" "$suggestion" "$RESET"
    elif [[ -z $STOPPED ]]; then
        warn "CRF $SELECTED_CRF tops $PRESET's range: a higher one may pass too (extend PRESETS)"
    fi
    kv "Check by eye" "scene at $WORST_SCENE_AT (lowest 1%-low, $(printf '%.2f' "$WORST_SCENE_LOW"))"
    kv "Full encode" "≈ $ENCODE_FPS fps$( ((ENCODE_SLOTS > 1)) && echo " per slot × $ENCODE_SLOTS slots") → $(full_encode_hours "$ENCODE_FPS") h"
}

# Encodes the chosen preset and CRF's worst scene (SAMPLE_DURATION from
# WORST_SCENE_AT) to <output stem>_worst_sample.mkv, to check by eye before
# the full encode. Needs OUTPUT; a sample already made at the same scene,
# preset and CRF is kept.
cut_worst_sample() {
    local file="${OUTPUT%.mkv}_worst_sample.mkv" at title frames
    heading "Worst sample"
    if [[ $WORST_SCENE_AT != *:*:* ]]; then
        warn "Scene time not in $(basename "$ANALYSIS") — no sample"
        return 0
    fi
    at=$(awk -F: '{ print $1 * 3600 + $2 * 60 + $3 }' <<<"$WORST_SCENE_AT")
    title="Worst sample at $WORST_SCENE_AT · $PRESET · CRF $SELECTED_CRF"
    if [[ $(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$file" 2>/dev/null) != "$title" ]]; then
        ffmpeg -nostdin -v error -y -ss "$at" -i "$INPUT" -t "$SAMPLE_DURATION" -map 0:"$V" -c copy "$WORK/worst-ref.mkv"
        frames=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$WORK/worst-ref.mkv")
        # Dynamic scope: the live block's helpers see this one step.
        local STEP_NAMES=("encode")
        BLOCK_CRF=$SELECTED_CRF
        begin_sample "$PRESET · scene at $WORST_SCENE_AT · $SAMPLE_DURATION s"
        run_step 0 "$frames" encode_sample "$PRESET" "$SELECTED_CRF" "$WORK/worst-ref.mkv" "$WORK/worst.mkv" -nostats -progress pipe:1
        clear_block
        # Written in WORK and moved, so an abort leaves no partial sample.
        mkvpropedit -q "$WORK/worst.mkv" --edit info --set "title=$title"
        mv -f "$WORK/worst.mkv" "$file"
    fi
    ok "$(basename "$file") · $(human_bytes "$(stat -c %s "$file")")"
}
