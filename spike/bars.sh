# Live progress bars, one per slot. Sourced by spike/*.sh after lib/ui.sh.
# Needs SLOTS (names), FRAMES (total per slot) and STATE (a directory).

# Reads ffmpeg -progress lines on stdin into $STATE/<slot>: "frame fps".
follow() {
    local slot=$1 key value frame=0 fps=0
    while IFS='=' read -r key value; do
        case $key in
            frame) frame=$value ;;
            fps) fps=$value ;;
            progress) echo "$frame $fps" >"$STATE/$slot" ;;
        esac
    done
}

# Status text of a slot, kept short: a wrapped line breaks the redraw.
status() { echo "$2" >"$STATE/status-$1"; }

draw() {
    local slot frame fps st pct eta
    (( ${DRAWN:-0} )) && printf '\e[%dA' "${#SLOTS[@]}"
    for slot in "${SLOTS[@]}"; do
        read -r frame fps 2>/dev/null <"$STATE/$slot" || { frame=0 fps=0; }
        st=$(cat "$STATE/status-$slot" 2>/dev/null || echo "starting")
        read -r pct eta < <(awk -v f="$frame" -v t="$FRAMES" -v r="$fps" 'BEGIN {
            printf "%.0f ", (t > 0 ? f / t * 100 : 0)
            if (r > 0) { e = (t - f) / r; printf "%d:%02d", e / 60, e % 60 } else printf "—" }')
        printf '\r\e[K  %-14s %s %3s%% · %5s fps · ETA %5s · %s\n' "$slot" \
            "$(bar "$(awk -v f="$frame" -v t="$FRAMES" 'BEGIN { print (t > 0 ? f / t : 0) }')" 20)" "$pct" "$fps" "$eta" "$st"
    done
    DRAWN=1
}

# Redraws every second until every slot has $STATE/end-<slot>.
watch_slots() {
    local slot left
    DRAWN=0
    while :; do
        draw
        left=0
        for slot in "${SLOTS[@]}"; do [[ -e $STATE/end-$slot ]] || left=1; done
        (( left )) || break
        sleep 1
    done
    draw
}
