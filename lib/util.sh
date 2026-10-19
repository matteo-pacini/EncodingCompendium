# Formatting helpers, argument parsing, dry-run execution and the work
# directory with its cleanup. Sourced by the hevc-*.sh entry scripts.

hms() { awk -v s="$1" 'BEGIN { printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 }'; }
human_bytes() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.2f %s", b, u[i] }'; }
kbps() { awk -v b="$1" 'BEGIN { if (b == "" || b == "null") print "unknown"; else printf "%.0f kb/s", b / 1000 }'; }

# Parses `[--dry-run] [--score] <input.mkv>` into DRY_RUN, SCORE and INPUT.
parse_args() {
    DRY_RUN="" SCORE=""
    while (($#)); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --score) SCORE=1 ;;
            -*) die "Unknown option $1" ;;
            *) break ;;
        esac
        shift
    done
    (($# == 1)) || die "Usage: $(basename "$0") [--dry-run] [--score] <input.mkv>"
    INPUT=$1
    [[ -f $INPUT ]] || die "No such file: $INPUT"
}

# x265's presets, fastest first.
X265_PRESETS=(ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)

# Position of a preset in X265_PRESETS (0 = fastest), or nothing if unknown.
preset_rank() {
    local i
    for i in "${!X265_PRESETS[@]}"; do
        [[ ${X265_PRESETS[i]} == "$1" ]] && { echo "$i"; return 0; }
    done
}

# Checks SAMPLE_PERCENT (share of the film to calibrate on, above 0 and at
# most 90) and SAMPLE_DURATION (seconds per sample, a whole number from 5).
# On a malformed value, prints what is wrong and returns 1.
parse_sampling() {
    [[ $SAMPLE_PERCENT =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
        awk -v p="$SAMPLE_PERCENT" 'BEGIN { exit !(p > 0 && p <= 90) }' ||
        { echo "SAMPLE_PERCENT '$SAMPLE_PERCENT' is not a number above 0 and at most 90"; return 1; }
    # Shorter samples mostly measure x265 starting up (60-frame lookahead,
    # 10 s keyframe interval).
    [[ $SAMPLE_DURATION =~ ^[0-9]+$ ]] && (( SAMPLE_DURATION >= 5 )) ||
        { echo "SAMPLE_DURATION '$SAMPLE_DURATION' is not a whole number of seconds from 5"; return 1; }
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
        if [[ ! $entry =~ ^([a-z]+):([0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*)$ ]]; then
            echo "'$entry' is not preset:crf,crf,… (entries separated by ;)"
            return 1
        fi
        name=${BASH_REMATCH[1]}
        rank=$(preset_rank "$name")
        [[ -n $rank ]] || { echo "'$name' is not an x265 preset (${X265_PRESETS[*]})"; return 1; }
        [[ $seen == *" $name "* ]] && { echo "preset '$name' is given twice"; return 1; }
        seen+="$name "
        IFS=',' read -r -a crfs <<<"${BASH_REMATCH[2]}"
        prev=-1
        for crf in "${crfs[@]}"; do
            awk -v c="$crf" 'BEGIN { exit !(c >= 0 && c <= 51) }' || { echo "$name: CRF $crf is outside 0–51"; return 1; }
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
    kill_tree $$
    # A script with work elsewhere (hevc-farm.sh's workers) cleans it up here.
    if declare -F cleanup_hook >/dev/null; then cleanup_hook; fi
    rm -rf "$WORK"
    # An interrupted encode cannot be resumed.
    [[ -z $PARTIAL ]] || rm -rf "$PARTIAL"
}
