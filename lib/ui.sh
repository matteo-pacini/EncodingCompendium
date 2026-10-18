# Terminal output: colours (off without a terminal or with NO_COLOR), boxed
# sections, key/value lines, a rewritable progress line and the encode
# progress bar. Sourced by the hevc-*.sh entry scripts.

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    RESET=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m'
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' MAGENTA=$'\e[35m' CYAN=$'\e[36m'
else
    RESET='' BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN=''
fi

WIDTH=78

# Repeats $1 $2 times. tr and printf widths are byte-based, so neither can
# handle the multibyte box-drawing characters.
repeat() { local out="" i; for ((i = 0; i < $2; i++)); do out+=$1; done; printf '%s' "$out"; }

rule() { printf '%s%s%s\n' "$DIM" "$(repeat ─ "$WIDTH")" "$RESET"; }

section() {
    local title=$1 bar pad
    (( ${#title} > WIDTH - 4 )) && title="${title:0:WIDTH-5}…"
    bar=$(repeat ─ $((WIDTH - 2)))
    pad=$(repeat ' ' $((WIDTH - 4 - ${#title})))
    echo
    printf '%s%s╭%s╮%s\n' "$BOLD" "$MAGENTA" "$bar" "$RESET"
    printf '%s%s│ %s%s │%s\n' "$BOLD" "$MAGENTA" "$title" "$pad" "$RESET"
    printf '%s%s╰%s╯%s\n' "$BOLD" "$MAGENTA" "$bar" "$RESET"
}

# Centres $2 in $1 columns. Counts characters, not bytes (printf widths count
# bytes, which misaligns "Δ", "—" and the like).
cell() {
    local width=$1 text=$2 left right
    left=$(( (width - ${#text}) / 2 )) right=$(( width - ${#text} - (width - ${#text}) / 2 ))
    (( left < 0 )) && left=0
    (( right < 0 )) && right=0
    printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

heading() { printf '\n%s%s▌ %s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
kv()      { printf '  %s%-22s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }
item()    { printf '  %s%s●%s %s%s%s\n' "$BOLD" "$BLUE" "$RESET" "$BOLD" "$1" "$RESET"; }
setting() { printf '      %s%-20s%s %s%s%s\n' "$DIM" "$1" "$RESET" "$GREEN" "$2" "$RESET"; }
ok()      { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()    { printf '  %s▲%s %s\n' "$YELLOW" "$RESET" "$1"; }
die()     { printf '%s✖ %s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# Rewrites the current terminal line; an empty message just clears it.
progress() {
    [[ -t 1 ]] || return 0
    printf '\r\e[K'
    [[ -z $1 ]] || printf '  %s%s%s' "$DIM" "$1" "$RESET"
}

# Prints a progress bar of $2 cells for the fraction $1 (0–1), with
# eighth-cell resolution.
bar() {
    awk -v p="$1" -v w="$2" 'BEGIN {
        if (p < 0) p = 0; if (p > 1) p = 1
        split("▏ ▎ ▍ ▌ ▋ ▊ ▉", part, " ")
        cells = p * w; full = int(cells); b = ""
        for (i = 0; i < full; i++) b = b "█"
        k = int((cells - full) * 8); if (full < w) { b = b (k > 0 ? part[k] : "·"); full++ }
        for (i = full; i < w; i++) b = b "·"
        printf "▕%s▏", b }'
}

# Draws ffmpeg's -progress key=value stream (on stdin) as one redrawn line
# with a bar, speed, ETA and projected size against TOTAL_FRAMES; without a
# terminal, one line per 5%. When ffmpeg's own output is not the result (it
# feeds another encoder), PROGRESS_SIZE_FILE names the file whose size to
# show instead.
render_progress() {
    local key value frame=0 fps=0 size=0 pct eta projected line rest width step last_step=-1 cols
    while IFS='=' read -r key value; do
        case $key in
            frame) frame=$value ;;
            fps) fps=$value ;;
            total_size) [[ $value =~ ^[0-9]+$ ]] && size=$value ;;
            progress)
                [[ -n ${PROGRESS_SIZE_FILE:-} && -f $PROGRESS_SIZE_FILE ]] && size=$(stat -c %s "$PROGRESS_SIZE_FILE")
                read -r pct eta projected < <(awk -v f="$frame" -v t="$TOTAL_FRAMES" -v r="$fps" -v sz="$size" 'BEGIN {
                    p = (t > 0 ? f / t : 0); if (p > 1) p = 1
                    printf "%.1f %d %.0f\n", p * 100, (r > 0 ? (t - f) / r : -1), (f > 0 ? sz / f * t : 0) }')
                rest=$(printf '%5.1f%% · %s fps · ETA %s · %s → ≈%s' "$pct" "$fps" "$( ((eta >= 0)) && hms "$eta" || echo —)" \
                    "$(human_bytes "$size")" "$(human_bytes "$projected")")
                if [[ -t 1 ]]; then
                    # A line wider than the terminal wraps, and \r then only
                    # returns to the wrapped part: the bar gives up cells
                    # first, then the line is cut.
                    # The terminal itself: here stdin is ffmpeg's pipe, and
                    # tput with stderr silenced finds no tty and says 80.
                    cols=$(stty size </dev/tty 2>/dev/null) && cols=${cols##* } || cols=80
                    width=$(( cols - 17 - ${#rest} ))
                    (( width > 24 )) && width=24
                    (( width < 8 )) && width=8
                    line="Encoding $(bar "$(awk -v p="$pct" 'BEGIN { print p / 100 }')" "$width") $rest"
                    (( ${#line} > cols - 3 )) && line="${line:0:cols-4}…"
                    printf '\r\e[K  %s' "$line"
                else
                    line="Encoding $(bar "$(awk -v p="$pct" 'BEGIN { print p / 100 }')" 24) $rest"
                    step=$(awk -v p="$pct" 'BEGIN { print int(p / 5) }')
                    (( step > last_step )) && { echo "  $line"; last_step=$step; }
                fi
                [[ $value == end ]] && { [[ -t 1 ]] && echo; return 0; }
                ;;
        esac
    done
}
