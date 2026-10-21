# Formatting helpers, argument parsing, dry-run execution and the work
# directory with its cleanup. Sourced by the entry scripts.

hms() { awk -v s="$1" 'BEGIN { printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 }'; }
human_bytes() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.2f %s", b, u[i] }'; }
kbps() { awk -v b="$1" 'BEGIN { if (b == "" || b == "null") print "unknown"; else printf "%.0f kb/s", b / 1000 }'; }

# Parses `[--dry-run] [--score] [--yes] [--start-at <time>] <input.mkv>`
# into DRY_RUN, SCORE, YES ("--yes" when given), START_AT (epoch seconds)
# and INPUT.
parse_args() {
    local start=""
    DRY_RUN="" SCORE="" YES="" START_AT=""
    while (($#)); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --score) SCORE=1 ;;
            --yes) YES=--yes ;;
            --start-at) (($# >= 2)) || die "--start-at needs a time"; start=$2; shift ;;
            -*) die "Unknown option $1" ;;
            *) break ;;
        esac
        shift
    done
    (($# == 1)) || die "Usage: $(basename "$0") [--dry-run] [--score] [--yes] [--start-at <time>] <input.mkv>"
    INPUT=$1
    [[ -f $INPUT ]] || die "No such file: $INPUT"
    [[ -z $start ]] || START_AT=$(parse_when --start-at "$start" "$EPOCHSECONDS") || exit 1
}

# Epoch seconds of time $2 (anything `date -d` reads) for option $1. A time
# of day alone ("07:00") is its first occurrence after epoch $3.
parse_when() {
    local t
    t=$(date -d "$2" +%s 2>/dev/null) || die "$1: '$2' is not a date or time"
    if [[ $2 =~ ^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
        # By calendar day, not 86400 s: a day with a clock change is longer
        # or shorter.
        while (( t <= $3 )); do t=$(date -d "$(date -d "@$t" +%F) $2 + 1 day" +%s); done
    fi
    echo "$t"
}

# Before section 0: waits until START_AT (epoch seconds), if set and still
# ahead, showing the time left.
wait_for_start() {
    [[ -n ${START_AT:-} ]] && (( START_AT > EPOCHSECONDS )) || return 0
    printf '  Waiting until %s%s%s · Ctrl+C to cancel\n' "$BOLD" "$(date -d "@$START_AT" '+%a %d %b %H:%M:%S')" "$RESET"
    while (( START_AT > EPOCHSECONDS )); do
        progress "starts in $(hms $((START_AT - EPOCHSECONDS)))"
        sleep 1
    done
    progress ""
}

# Position of a preset in the encoder's ENCODER_PRESETS (0 = fastest), or
# nothing if unknown.
preset_rank() {
    local i
    for i in "${!ENCODER_PRESETS[@]}"; do
        [[ ${ENCODER_PRESETS[i]} == "$1" ]] && { echo "$i"; return 0; }
    done
}

# Checks SAMPLE_PERCENT (share of the film to calibrate on, above 0 and at
# most 90) and SAMPLE_DURATION (seconds per sample, a whole number from 5).
# On a malformed value, prints what is wrong and returns 1.
parse_sampling() {
    [[ $SAMPLE_PERCENT =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
        awk -v p="$SAMPLE_PERCENT" 'BEGIN { exit !(p > 0 && p <= 90) }' ||
        { echo "SAMPLE_PERCENT '$SAMPLE_PERCENT' is not a number above 0 and at most 90"; return 1; }
    # Shorter samples mostly measure the encoder starting up (lookahead,
    # 10 s keyframe interval).
    [[ $SAMPLE_DURATION =~ ^[0-9]+$ ]] && (( SAMPLE_DURATION >= 5 )) ||
        { echo "SAMPLE_DURATION '$SAMPLE_DURATION' is not a whole number of seconds from 5"; return 1; }
}

# Checks VMAF_TARGET_MEAN and VMAF_TARGET_LOW (the VMAF NEG gates: pooled
# mean, and the 1%-low pooled and per scene): numbers from 0 to 100, the
# 1%-low no higher than the mean. On a malformed value, prints what is
# wrong and returns 1.
parse_vmaf_targets() {
    local name
    for name in VMAF_TARGET_MEAN VMAF_TARGET_LOW; do
        [[ ${!name} =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="${!name}" 'BEGIN { exit !(v <= 100) }' ||
            { echo "$name '${!name}' is not a number from 0 to 100"; return 1; }
    done
    awk -v m="$VMAF_TARGET_MEAN" -v l="$VMAF_TARGET_LOW" 'BEGIN { exit !(l <= m) }' ||
        { echo "VMAF_TARGET_LOW $VMAF_TARGET_LOW is above VMAF_TARGET_MEAN $VMAF_TARGET_MEAN"; return 1; }
}

# Checks QCOMP: a number from 0.5 to 1.0, the range x265 accepts. On a
# malformed value, prints what is wrong and returns 1.
parse_qcomp() {
    [[ $QCOMP =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v q="$QCOMP" 'BEGIN { exit !(q >= 0.5 && q <= 1) }' ||
        { echo "QCOMP '$QCOMP' is not a number from 0.5 to 1.0"; return 1; }
}

# Parses PRESETS ("preset:crf,crf,…;preset:crf,…") into PRESET_NAMES and
# PRESET_CRFS (each a space-separated CRF list), ordered fastest preset
# first whatever the order given. On a malformed value, prints what is wrong
# and returns 1.
parse_presets() {
    local entries entry name crf prev crfs i rank seen=" "
    local -a by_rank_name=() by_rank_crfs=()
    PRESET_NAMES=() PRESET_CRFS=()
    [[ -n ${PRESETS:-} ]] || { echo "PRESETS is empty"; return 1; }
    IFS=';' read -r -a entries <<<"$PRESETS"
    for entry in "${entries[@]}"; do
        if [[ ! $entry =~ ^([a-z0-9]+):([0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*)$ ]]; then
            echo "'$entry' is not preset:crf,crf,… (entries separated by ;)"
            return 1
        fi
        name=${BASH_REMATCH[1]}
        rank=$(preset_rank "$name")
        [[ -n $rank ]] || { echo "'$name' is not an $ENCODER_LABEL preset (${ENCODER_PRESETS[*]})"; return 1; }
        [[ $seen == *" $name "* ]] && { echo "preset '$name' is given twice"; return 1; }
        seen+="$name "
        IFS=',' read -r -a crfs <<<"${BASH_REMATCH[2]}"
        prev=-1
        for crf in "${crfs[@]}"; do
            awk -v c="$crf" -v m="$ENCODER_CRF_MAX" 'BEGIN { exit !(c >= 0 && c <= m) }' || { echo "$name: CRF $crf is outside 0–$ENCODER_CRF_MAX"; return 1; }
            # The walk goes up from the lowest CRF and stops at the first failure.
            awk -v c="$crf" -v p="$prev" 'BEGIN { exit !(c > p) }' || { echo "$name: CRFs must be in ascending order"; return 1; }
            prev=$crf
        done
        by_rank_name[rank]=$name
        by_rank_crfs[rank]="${crfs[*]}"
    done
    for i in "${!by_rank_name[@]}"; do
        PRESET_NAMES+=("${by_rank_name[i]}")
        PRESET_CRFS+=("${by_rank_crfs[i]}")
    done
}

# Runs a command (via background, so Ctrl+C is immediate), or only prints it
# (shell-quoted) under --dry-run.
run() {
    if [[ -n $DRY_RUN ]]; then
        printf '\n  %s$%s' "$CYAN" "$RESET"
        printf ' %q' "$@"
        printf '\n'
    else
        background "$@"
    fi
}

# Sends signal $1 to process $2 and all its descendants.
signal_tree() {
    local child
    for child in $(pgrep -P "$2"); do
        signal_tree "$1" "$child"
    done
    kill -"$1" "$2" 2>/dev/null || true
}

# Runs a command in the background and waits for it. bash holds traps while
# a foreground command runs, and ffmpeg 9 can take a minute to exit on
# SIGINT; `wait` returns to the traps at once.
background() {
    "$@" &
    wait $!
}

# bash runs the EXIT trap on Ctrl+C and on kill too, but leaves the running
# ffmpeg orphaned, still encoding. SIGKILL, not SIGTERM: ffmpeg would first
# flush the encoder for output that is deleted anyway.
kill_tree() {
    local child
    for child in $(pgrep -P "$1"); do
        kill_tree "$child"
        kill -KILL "$child" 2>/dev/null || true
    done
}

# Creates WORK, removed on exit together with PARTIAL (an unfinished output
# file or directory of intermediates) when set.
setup_workdir() {
    # Named, so a run killed with SIGKILL (untrappable) leaves an identifiable
    # directory behind.
    WORK=$(mktemp -d -t "$(basename "$0" .sh).XXXXXX")
    PARTIAL=""
    trap cleanup EXIT
    # Exit at once (through cleanup) rather than wait for the command at hand.
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

cleanup() {
    # Out of the job table, or bash reports each job killed below as Killed.
    disown -a
    kill_tree $$
    # A script with work elsewhere (farm.sh's workers) cleans it up here.
    if declare -F cleanup_hook >/dev/null; then cleanup_hook; fi
    rm -rf "$WORK"
    # An interrupted encode cannot be resumed.
    [[ -z $PARTIAL ]] || rm -rf "$PARTIAL"
}
