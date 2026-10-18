#!/usr/bin/env bash
#
# hevc-1080p-sdr.sh or hevc-2160p-hdr.sh, whichever fits the source, spread
# over several hosts: this one and every --worker. Calibration samples run
# on every slot at once; a 2160p video is split at scene cuts into chunks,
# encoded on every slot and joined (a 1080p video is encoded on this host).
#
# Usage: hevc-farm.sh [--dry-run] [--no-local] [--worker alias[=wrapper]]… <input.mkv>
#
#   --worker alias[=wrapper]  an SSH alias to encode on, each job there run
#                             under wrapper (e.g. 'nexus=with-fans 50 --');
#                             once per worker
#   --no-local                leave this host out of the encoding
#   --dry-run                 calibrate, then print the encode plan
#
# Every host gets one slot per NUMA node. Workers need SSH keys and Nix:
# their tools come from this repository's flake on GitHub, at FARM_REF
# (default: this checkout's commit, which must be pushed). PRESETS,
# SAMPLE_PERCENT and SAMPLE_DURATION as in the single-host scripts.
# Set NO_COLOR=1 to disable colours.

set -euo pipefail

LIB="$(dirname "$(readlink -f "$0")")/lib"
for lib in ui util requirements probe audio calibrate mux remote farm; do
    # shellcheck source=/dev/null
    source "$LIB/$lib.sh"
done

farm_parse_args "$@"
# PQ or HLG makes it the 2160p HDR profile, which refuses HLG itself.
TRANSFER=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$INPUT" 2>/dev/null || true)
case $TRANSFER in
    smpte2084 | arib-std-b67) PROFILE=2160p-hdr ;;
    *) PROFILE=1080p-sdr ;;
esac
# shellcheck source=/dev/null
source "$LIB/profile-$PROFILE.sh"
profile_defaults

###############################################################################
section "0 · Requirements"
###############################################################################

profile_requirements
require_presets
require_sampling
require_farm_ref
setup_workdir
FARM="$WORK/farm-state"
mkdir -p "$FARM"
heading "Hosts"
require_workers
requirements_verdict
parse_presets

load_probe

###############################################################################
section "1 · Source analysis — $(basename "$INPUT")"
###############################################################################

profile_analysis

###############################################################################
section "2 · Proposed conversion — $PROFILE_TARGET"
###############################################################################

# Chunks are encoded without the RPU, which goes into the joined stream.
DV_INJECTION="dovi_tool inject-rpu into the joined chunks"
profile_settings

heading "Hosts  ${DIM}${#SLOT_HOST[@]} slots${RESET}"
if [[ $PROFILE == 2160p-hdr ]]; then
    ENCODE_SLOTS=${#SLOT_HOST[@]}
    item "Samples and ≈ $((CHUNK_SECONDS / 60)) min chunks, joined at scene cuts, on every slot"
else
    item "Samples on every slot; the video on $FARM_LOCAL"
fi
for i in "${!SLOT_HOST[@]}"; do
    setting "${SLOT_NAME[i]}" "${WRAP[${SLOT_HOST[i]}]:-no wrapper}${SLOT_POOLS[i]:+ · x265 pools ${SLOT_POOLS[i]}}${SLOT_ARM[i]:+ · without asm=avx512 (ARM)}"
done

###############################################################################
section "3 · Calibration — ${#PRESET_NAMES[@]} preset(s) × $CALIBRATION_SAMPLES samples of $SAMPLE_DURATION s ($SAMPLE_PERCENT%)"
###############################################################################

farm_calibrate
run_calibration
plan_output
cut_worst_sample
confirm_encode

###############################################################################
section "4 · Encode${DRY_RUN:+ — dry run}"
###############################################################################

if [[ $PROFILE == 2160p-hdr ]]; then
    encode_prepare
    # The stereo track (one core, decoding the original audio) alongside the
    # video's chunks; its report, without the live block, follows them.
    encode_stereo >"$WORK/stereo.log" 2>&1 &
    STEREO_PID=$!
    farm_encode_video
    wait "$STEREO_PID" || { cat "$WORK/stereo.log"; die "The stereo track failed"; }
    cat "$WORK/stereo.log"
    encode_mux
else
    profile_encode
fi
profile_checks
