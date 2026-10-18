#!/usr/bin/env bash
# Spike: failure handling, on the segment spike/speed.sh left on every host.
#   A  Ctrl+C on the master: kill the ssh clients mid-encode, then time how
#      long the remote ffmpeg/x265 live on.
#   B  A worker fails mid-encode: kill nexus's x265, notice, reschedule the
#      segment on nightsprings, verify every frame came back.
#   C  A worker is unreachable: notice within the connect timeout.
#
# Usage: spike/failures.sh [tests, e.g. AC; default ABC]
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/ui.sh
source lib/util.sh
source spike/hosts.sh
source spike/bars.sh
command -v x265 >/dev/null || exec nix shell --quiet "$REF#tools" --command "$0" "$@"

TESTS=${1:-ABC}
LOCAL="$HOME/$SPIKE_DIR"
[[ -f $LOCAL/seg.mkv ]] || die "Run spike/speed.sh first: it cuts the segment"
FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$LOCAL/seg.mkv" | wc -l)
STATE=$(mktemp -d "${TMPDIR:-/tmp}/spike-failures.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$STATE"' EXIT
trap 'exit 130' INT

# A fast encode of the segment into failtest-<tag>.hevc, so the remote
# processes are findable by that name.
job() {
    cat <<JOB
set -euo pipefail
{ ffmpeg -nostdin -v error -nostats -progress pipe:3 -i seg.mkv -map 0:v:0 -fps_mode passthrough \\
    -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 3>&4 |
    x265 --input - --y4m --preset fast --crf 20 --output-depth 10 $2 --log-level error --no-progress -o failtest-$1.hevc; } 4>&1
JOB
}
# The bracket keeps the pattern from matching the remote shell running pgrep.
# pgrep | wc, not pgrep -c: macOS pgrep has no -c.
remote_count() { ssh "${SSH_OPTS[@]}" "$1" "pgrep -f 'failtest-$2[.]hevc' | wc -l" 2>/dev/null | tr -d ' '; }

###############################################################################
section "Spike · failure handling"
###############################################################################

if [[ $TESTS == *A* ]]; then
    heading "A · Ctrl+C on the master (ssh clients killed mid-encode)"
    pids=()
    for host in "${WORKERS[@]}"; do
        job "a-$host" "${ASM[$host]}" | on "$host" >/dev/null 2>&1 &
        pids+=($!)
    done
    progress "Encoding for 20 s…"
    sleep 20
    progress ""
    for host in "${WORKERS[@]}"; do kv "$host before" "$(remote_count "$host" "a-$host") processes"; done
    # What Ctrl+C does to the farm script's ssh clients.
    pkill -INT -f "^ssh .*nix shell --quiet" 2>/dev/null
    t0=$(date +%s)
    for host in "${WORKERS[@]}"; do
        (
            for ((s = 0; s <= 60; s++)); do
                n=$(remote_count "$host" "a-$host")
                [[ ${n:-0} == 0 ]] && { echo "$s" >"$STATE/gone-$host"; exit 0; }
                sleep 1
            done
            echo never >"$STATE/gone-$host"
        ) &
    done
    wait
    for host in "${WORKERS[@]}"; do
        gone=$(cat "$STATE/gone-$host")
        if [[ $gone == never ]]; then
            warn "$host: still running 60 s after the ssh client died — needs an explicit remote cancel"
            ssh "${SSH_OPTS[@]}" "$host" "pkill -f 'failtest-a-$host[.]hevc'" 2>/dev/null
        else
            ok "$host: remote encode gone ${gone} s after the ssh client"
        fi
    done
fi

if [[ $TESTS == *B* ]]; then
    heading "B · nexus fails mid-encode, rescheduled on nightsprings"
    SLOTS=("nexus" "nightsprings (retry)")
    status nexus encoding
    (
        if job b "${ASM[nexus]}" | on nexus 2>"$STATE/err-b" > >(follow nexus); then
            status nexus "${YELLOW}finished?${RESET}"
            echo 0 >"$STATE/rc-b"
        else
            echo $? >"$STATE/rc-b"
            status nexus "${RED}failed${RESET}"
        fi
        touch "$STATE/end-nexus"
    ) &
    (
        sleep 25
        ssh "${SSH_OPTS[@]}" nexus "pkill -KILL -f 'x26[5] .*failtest-b[.]hevc'" 2>/dev/null
    ) &
    (
        while [[ ! -e $STATE/end-nexus ]]; do sleep 1; done
        if [[ $(cat "$STATE/rc-b") != 0 ]]; then
            status "nightsprings (retry)" encoding
            if job b "${ASM[nightsprings]}" | on nightsprings 2>"$STATE/err-retry" > >(follow "nightsprings (retry)"); then
                status "nightsprings (retry)" "${GREEN}done${RESET}"
            else
                status "nightsprings (retry)" "${RED}failed${RESET}"
            fi
        else
            status "nightsprings (retry)" "not needed"
        fi
        touch "$STATE/end-nightsprings (retry)"
    ) &
    watch_slots
    kv "nexus exit status" "$(cat "$STATE/rc-b")$( [[ $(cat "$STATE/rc-b") != 0 ]] && echo " → failure noticed, segment rescheduled")"
    get nightsprings failtest-b.hevc "$LOCAL/failtest-b.hevc"
    got=$(ffprobe -v error -show_entries packet=size -of csv=p=0 "$LOCAL/failtest-b.hevc" | wc -l)
    if [[ $got == "$FRAMES" ]]; then ok "Retried segment complete: $got/$FRAMES frames"; else warn "Retried segment has $got/$FRAMES frames"; fi
    partial=$(ssh "${SSH_OPTS[@]}" nexus "stat -c %s $SPIKE_DIR/failtest-b.hevc 2>/dev/null || echo 0")
    kv "nexus left behind" "$(human_bytes "$partial") of partial output — to verify and delete, never to use"
fi

if [[ $TESTS == *C* ]]; then
    heading "C · Unreachable worker"
    t0=$(date +%s.%N)
    if ssh "${SSH_OPTS[@]}" -o ControlMaster=no 192.0.2.1 true 2>/dev/null; then
        warn "192.0.2.1 answered?"
    else
        ok "Unreachable (exit $?) after $(awk -v s="$t0" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }') s · ConnectTimeout=10"
    fi
fi

for host in "${WORKERS[@]}"; do ssh "${SSH_OPTS[@]}" "$host" "rm -f $SPIKE_DIR/failtest-*.hevc" 2>/dev/null; done
rm -f "$LOCAL/failtest-b.hevc"
