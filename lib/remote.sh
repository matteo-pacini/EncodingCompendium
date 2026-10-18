# Worker hosts for hevc-farm.sh: the --worker options, running a job on a
# slot, moving files, and probing every host into slots in section 0.
# Sourced by hevc-farm.sh after util.sh and ui.sh.
#
# A job is a bash script the master writes; a worker needs only SSH keys
# (the alias in ~/.ssh/config), Nix and this repository's flake, which it
# fetches as FARM_REF. Each host works in its own scratch directory, removed
# at exit: $HOME/hevc-farm/<run> on a worker, $WORK/farm on this host.
#
# Slots, one per NUMA node of each host (indexed together): SLOT_HOST,
# SLOT_NAME, SLOT_CPUS (a CPU list to pin to, or empty), SLOT_POOLS (x265
# --pools for that node, or empty) and SLOT_ARM (1 when x265 must not be
# given asm=avx512).

FARM_LOCAL=$(hostname -s)
FARM_RDIR="hevc-farm/$FARM_LOCAL-$$"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o Compression=no -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/hevc-farm-%C" -o ControlPersist=60)

# Parses `[--dry-run] [--no-local] [--worker alias[=wrapper]]… <input.mkv>`
# into DRY_RUN, NO_LOCAL, INPUT, WORKERS and WRAP (alias → wrapper command,
# which every job on that host runs under).
farm_parse_args() {
    DRY_RUN="" NO_LOCAL="" WORKERS=()
    declare -gA WRAP=()
    while (($#)); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --no-local) NO_LOCAL=1 ;;
            --worker) (($# >= 2)) || die "--worker needs alias[=wrapper]"; add_worker "$2"; shift ;;
            --worker=*) add_worker "${1#--worker=}" ;;
            -*) die "Unknown option $1" ;;
            *) break ;;
        esac
        shift
    done
    (($# == 1)) || die "Usage: $(basename "$0") [--dry-run] [--no-local] [--worker alias[=wrapper]]… <input.mkv>"
    INPUT=$1
    [[ -f $INPUT ]] || die "No such file: $INPUT"
    [[ ${#WORKERS[@]} -gt 0 || -z $NO_LOCAL ]] || die "--no-local needs at least one --worker"
}

add_worker() {
    local alias=${1%%=*}
    [[ $alias =~ ^[A-Za-z0-9._-]+$ ]] || die "'$alias' is not an SSH alias"
    [[ " ${WORKERS[*]} " == *" $alias "* ]] && die "Worker '$alias' is given twice"
    [[ $alias == "$FARM_LOCAL" ]] && die "'$alias' is this host, which takes part unless --no-local"
    WORKERS+=("$alias")
    [[ $1 == *=* ]] && WRAP[$alias]=${1#*=}
    return 0
}

# Sets FARM_REF, the flake workers take their tools from: as given, or this
# checkout's commit on GitHub. Prints why not and fails when neither works.
farm_ref() {
    local root rev url
    [[ -n ${FARM_REF:-} ]] && return 0
    root=$(git -C "$LIB" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git checkout: set FARM_REF"; return 1; }
    rev=$(git -C "$root" rev-parse HEAD)
    git -C "$root" diff --quiet HEAD -- nix || { echo "nix/ has uncommitted changes: commit and push them"; return 1; }
    [[ -n $(git -C "$root" branch -r --contains "$rev" 2>/dev/null) ]] || { echo "commit ${rev:0:7} is not pushed: workers fetch it from GitHub"; return 1; }
    url=$(git -C "$root" remote get-url origin)
    [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || { echo "origin is not on GitHub: set FARM_REF"; return 1; }
    FARM_REF="github:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}/$rev?dir=nix"
}

require_farm_ref() {
    local problem
    if problem=$(farm_ref) && farm_ref; then
        requirement "Worker tools" yes "$FARM_REF#tools"
    else
        requirement "Worker tools" no "$problem"
    fi
}

# Prepended to a worker's job: on EOF on stdin, which stays open as long as
# the master's ssh does, kills the job's process group. ssh dying does not
# stop a remote command by itself. stdin moves to fd 3 first: bash gives a
# background command /dev/null as its stdin.
FARM_WATCHDOG='exec 3<&0 0</dev/null
( while IFS= read -r -t 2 -u 3 _ || (( $? > 128 )); do :; done; kill -TERM 0 ) >/dev/null 2>&1 &
FARM_WATCHDOG_PID=$!
trap "kill $FARM_WATCHDOG_PID 2>/dev/null" EXIT
'

# Runs job script $3 on host $1 in its scratch directory, pinned to CPU
# list $2 when not empty; the job's stdout and stderr are this function's.
# Returns the job's status; 255 means the host could not be reached.
host_run() {
    local host=$1 cpus=$2 b64 cmd keep keep_pid rc
    if [[ $host == "$FARM_LOCAL" ]]; then
        mkdir -p "$WORK/farm"
        (cd "$WORK/farm" && ${cpus:+taskset -c "$cpus"} bash -c "$3")
        return
    fi
    b64=$(base64 -w0 <<<"$FARM_WATCHDOG$3")
    cmd="mkdir -p $FARM_RDIR && cd $FARM_RDIR && ${WRAP[$host]:-} nix shell --quiet '$FARM_REF#tools' --command"
    cmd+=" ${cpus:+taskset -c $cpus }bash -c 'eval \"\$(printf %s $b64 | base64 -d)\"'"
    exec {keep}< <(exec sleep infinity)
    keep_pid=$!
    ssh "${SSH_OPTS[@]}" "$host" "$cmd" <&"$keep"
    rc=$?
    kill "$keep_pid" 2>/dev/null
    exec {keep}<&-
    return $rc
}

# Runs job script $2 on slot $1, as host_run.
slot_run() { host_run "${SLOT_HOST[$1]}" "${SLOT_CPUS[$1]}" "$2"; }

# Copies local file $2 to the scratch directory of slot $1's host as $3,
# once per host (linked, on this host).
slot_put() {
    local host=${SLOT_HOST[$1]} mark="$WORK/farm-has/${SLOT_HOST[$1]}/$3"
    [[ -e $mark ]] && return 0
    if [[ $host == "$FARM_LOCAL" ]]; then
        mkdir -p "$WORK/farm" && ln -sf "$(readlink -f "$2")" "$WORK/farm/$3"
    else
        # A temporary name per copy: both of a host's slots may send the same file.
        ssh "${SSH_OPTS[@]}" "$host" "mkdir -p $FARM_RDIR && cat > $FARM_RDIR/$3.$BASHPID && mv $FARM_RDIR/$3.$BASHPID $FARM_RDIR/$3" <"$2" ||
            return
    fi
    mkdir -p "${mark%/*}" && touch "$mark"
}

# Moves $2 from the scratch directory of slot $1's host to local file $3.
slot_get() {
    if [[ ${SLOT_HOST[$1]} == "$FARM_LOCAL" ]]; then
        mv -f "$WORK/farm/$2" "$3"
    else
        ssh "${SSH_OPTS[@]}" "${SLOT_HOST[$1]}" "cat $FARM_RDIR/$2" >"$3.part" && mv -f "$3.part" "$3" &&
            ssh "${SSH_OPTS[@]}" "${SLOT_HOST[$1]}" "rm -f $FARM_RDIR/$2"
    fi
}

# Deletes files $2… from the scratch directory of slot $1's host.
slot_rm() {
    local i=$1 host=${SLOT_HOST[$1]} name
    shift
    if [[ $host == "$FARM_LOCAL" ]]; then
        for name; do rm -f "$WORK/farm/$name" "$WORK/farm-has/$host/$name"; done
    else
        ssh "${SSH_OPTS[@]}" "$host" "cd $FARM_RDIR && rm -f $*" || return
        for name; do rm -f "$WORK/farm-has/$host/$name"; done
    fi
}

# What a host runs and has, as key=value lines. Run inside the tools.
probe_script() {
    cat <<'EOF'
set -uo pipefail
os=$(uname -s) arch=$(uname -m)
echo "system=$arch-$os"
if [[ $os == Linux ]]; then
    echo "cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    for n in /sys/devices/system/node/node[0-9]*; do [[ -d $n ]] && echo "node=${n##*node} $(cat "$n/cpulist")"; done
else
    echo "cpu=$(sysctl -n machdep.cpu.brand_string)"
fi
echo "threads=$(getconf _NPROCESSORS_ONLN)"
echo "x265=$(readlink -f "$(command -v x265)")"
echo "ffmpeg=$(readlink -f "$(command -v ffmpeg)")"
echo "x265_version=$(x265 --version 2>&1 | grep -o 'version [^ ]*' | head -1)"
echo "ffmpeg_version=$(ffmpeg -version | head -1 | cut -d' ' -f3)"
echo "free=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 * 1024 }')"
asm=""; [[ $arch == x86_64 ]] && asm="--asm avx512"
echo "simd=$(ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
    x265 --input - --y4m --preset ultrafast --output-depth 10 $asm --log-level info -o /dev/null 2>&1 |
    sed -n 's/.*using cpu capabilities: //p' | head -1)"
# Listed once and searched after: grep -q quitting early would end ffmpeg on
# SIGPIPE, which pipefail reports as a failure.
missing="" filters=$(ffmpeg -hide_banner -filters 2>/dev/null) encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for f in libvmaf xpsnr setparams crop pad scale; do grep -qw "$f" <<<"$filters" || missing+="$f "; done
grep -qw libx265 <<<"$encoders" || missing+="libx265 "
echo "missing=$missing"
EOF
}

# Probes this host and every worker, prints one requirement line per host
# and fills the slot arrays. A worker that is unreachable, has no Nix, lacks
# a filter or runs other tool builds than this host fails its line.
require_workers() {
    local host out rc key value system cpu threads x265 ffmpeg x265v ffmpegv free simd missing nodes n k problem slots
    local local_system local_x265 local_ffmpeg
    declare -gA PROBE=()
    SLOT_HOST=() SLOT_NAME=() SLOT_CPUS=() SLOT_POOLS=() SLOT_ARM=() SLOT_DOWN=()
    for host in "$FARM_LOCAL" "${WORKERS[@]}"; do
        progress "Probing $host…"
        out=$(host_run "$host" "" "$(probe_script)" 2>&1) && rc=0 || rc=$?
        progress ""
        system="" cpu="" threads="" x265="" ffmpeg="" x265v="" ffmpegv="" free="" simd="" missing="" nodes=()
        while IFS='=' read -r key value; do
            case $key in
                system) system=$value ;; cpu) cpu=$value ;; threads) threads=$value ;;
                x265) x265=$value ;; ffmpeg) ffmpeg=$value ;; x265_version) x265v=$value ;;
                ffmpeg_version) ffmpegv=$value ;; free) free=$value ;; simd) simd=$value ;;
                missing) missing=$value ;; node) nodes+=("$value") ;;
            esac
        done <<<"$out"
        problem=""
        if [[ -z $system ]]; then
            if (( rc == 255 )); then problem="unreachable over SSH"
            elif grep -q 'nix: .*not found\|command not found: nix' <<<"$out"; then problem="no nix"
            else problem="probe failed: $(tail -1 <<<"$out")"; fi
        elif [[ -n ${missing// /} ]]; then
            problem="ffmpeg lacks: $missing"
        fi
        if [[ $host == "$FARM_LOCAL" ]]; then
            local_system=$system local_x265=$x265 local_ffmpeg=$ffmpeg
        elif [[ -z $problem && $system == "$local_system" && ( $x265 != "$local_x265" || $ffmpeg != "$local_ffmpeg" ) ]]; then
            problem="runs other builds than this host (x265 $x265, ffmpeg $ffmpeg)"
        fi
        if [[ -n $problem ]]; then
            requirement "$host" no "$problem"
            continue
        fi
        [[ $host == "$FARM_LOCAL" && -n $NO_LOCAL ]] && continue
        # One slot per NUMA node, each pinned to its node: one x265 cannot
        # use two sockets' worth of threads at 4K.
        if (( ${#nodes[@]} > 1 )); then
            for n in "${nodes[@]}"; do
                SLOT_HOST+=("$host") SLOT_NAME+=("$host node ${n%% *}") SLOT_CPUS+=("${n#* }")
                SLOT_POOLS+=("$(for ((k = 0; k < ${#nodes[@]}; k++)); do printf '%s' "$( ((k > 0)) && echo ,)$( [[ ${nodes[k]%% *} == "${n%% *}" ]] && echo + || echo -)"; done)")
                SLOT_ARM+=("$( [[ $system == x86_64-* ]] || echo 1)")
            done
            slots="${#nodes[@]} slots (NUMA)"
        else
            SLOT_HOST+=("$host") SLOT_NAME+=("$host") SLOT_CPUS+=("") SLOT_POOLS+=("")
            SLOT_ARM+=("$( [[ $system == x86_64-* ]] || echo 1)")
            slots="1 slot"
        fi
        # Model names trimmed to the model.
        cpu=$(sed -E 's/\((R|TM)\)//g; s/ CPU//; s/ @ .*//; s/ w\/ .*//; s/^(Intel|AMD) //' <<<"${cpu:-?}")
        requirement "$host" yes "$system · $cpu · $threads threads · ${simd##* } · $slots · $(human_bytes "$free") free$(
            [[ $host == "$FARM_LOCAL" ]] && echo " · this host" || {
                [[ $system == "$local_system" ]] && echo " · same builds" || echo " · x265 ${x265v#version } · ffmpeg $ffmpegv"; }
            )${WRAP[$host]:+ · under ${WRAP[$host]}}"
    done
    (( ${#SLOT_HOST[@]} > 0 )) || requirement "Slots" no "no host left to encode on"
    return 0
}

# Run by cleanup: jobs still running on workers die with their ssh (the
# watchdog), then every worker's scratch directory goes.
cleanup_hook() {
    local host
    for host in "${WORKERS[@]}"; do
        timeout 30 ssh "${SSH_OPTS[@]}" "$host" "sleep 3; rm -rf $FARM_RDIR" >/dev/null 2>&1 &
    done
    wait
}
