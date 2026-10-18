# Spike helpers: the hosts and how jobs reach them. Sourced by spike/*.sh.
#
# REF pins every host to one commit of this repository's flake.
REF=${REF:-github:matteo-pacini/EncodingCompendium/679e44a4ea8e37d129117660d20843b2cba9ab11?dir=nix}
MASTER=brightfalls
HOSTS=(brightfalls nexus nightsprings)
WORKERS=(nexus nightsprings)
declare -A WRAP=(
    [brightfalls]="nice -n 19"
    [nexus]="with-fans 50 -- nice -n 19"
    [nightsprings]="caffeinate -i nice -n 19"
)
# x265 rejects asm=avx512 on ARM; on x86 without AVX-512 it falls back.
declare -A ASM=(
    [brightfalls]="--asm avx512"
    [nexus]="--asm avx512"
    [nightsprings]=""
)
SPIKE_DIR=spike-run   # under $HOME on every host, the master included

SSH_OPTS=(-o BatchMode=yes -o Compression=no -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/spike-%C" -o ControlPersist=15m)

# Runs the bash script on stdin on host $1, in $HOME/$SPIKE_DIR, inside the
# flake's tools, under the host's wrapper.
on() {
    local host=$1 cmd="mkdir -p $SPIKE_DIR && cd $SPIKE_DIR && ${WRAP[$1]} nix shell --quiet '$REF#tools' --command bash -s"
    if [[ $host == "$MASTER" ]]; then
        (cd "$HOME" && bash -c "$cmd")
    else
        ssh "${SSH_OPTS[@]}" "$host" "$cmd"
    fi
}

# Copies local file $2 to $HOME/$SPIKE_DIR/$3 on host $1.
put() {
    if [[ $1 == "$MASTER" ]]; then
        mkdir -p "$HOME/$SPIKE_DIR" && cp "$2" "$HOME/$SPIKE_DIR/$3"
    else
        ssh "${SSH_OPTS[@]}" "$1" "mkdir -p $SPIKE_DIR && cat > $SPIKE_DIR/$3" <"$2"
    fi
}

# Copies $HOME/$SPIKE_DIR/$2 on host $1 to local file $3.
get() {
    if [[ $1 == "$MASTER" ]]; then
        cp "$HOME/$SPIKE_DIR/$2" "$3"
    else
        ssh "${SSH_OPTS[@]}" "$1" "cat $SPIKE_DIR/$2" >"$3"
    fi
}
