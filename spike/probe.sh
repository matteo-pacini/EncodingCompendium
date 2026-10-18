#!/usr/bin/env bash
# Spike step 1: bootstraps the flake's tools on every worker (timed) and
# prints what each host runs. Usage: spike/probe.sh
set -uo pipefail
source "$(dirname "$0")/hosts.sh"

probe_script='
echo "host      $(hostname -s) · $(uname -sm)"
echo "cpu       $( (lscpu 2>/dev/null | sed -n "s/^Model name: *//p" | head -1) || sysctl -n machdep.cpu.brand_string)"
echo "threads   $(getconf _NPROCESSORS_ONLN)"
echo "x265      $(x265 --version 2>&1 | grep -o "version [^ ]*" | head -1) · $(x265 --version 2>&1 | grep -o "using cpu capabilities: .*" | head -1)"
echo "x265 path $(readlink -f "$(command -v x265)")"
echo "ffmpeg    $(readlink -f "$(command -v ffmpeg)")"
echo "filters   $(for f in libvmaf xpsnr cropdetect setparams; do ffmpeg -hide_banner -filters 2>/dev/null | grep -qw "$f" && printf "%s " "$f"; done)"
echo "free      $(df -h "$HOME" | awk "NR == 2 { print \$4 }") in \$HOME"
'
for host in "${WORKERS[@]}"; do
    (
        start=$(date +%s)
        out=$(on "$host" <<<"$probe_script" 2>&1)
        echo "== $host (wrapper: ${WRAP[$host]}) · bootstrap + probe $(( $(date +%s) - start )) s"
        echo "$out" | sed 's/^/  /'
    ) &
done
wait
