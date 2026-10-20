#!/usr/bin/env bash
#
# hevc-1080p-sdr.sh or hevc-2160p-hdr.sh, whichever fits the source, spread
# over several hosts: this one and every --worker. Calibration samples run
# on every slot at once; the video is split at scene cuts into chunks,
# encoded on every slot and joined. The output is then scored against the
# source as with --score, chunk by chunk on the slot that encoded it.
#
# Usage: farm.sh [--dry-run] [--yes] [--start-at <time>]
#                [--stop-at <time>] [--no-local]
#                [--worker alias[=wrapper]]… <input.mkv>
#
#   --worker alias[=wrapper]  an SSH alias to encode on, each job there run
#                             under wrapper (e.g. 'nexus=with-fans 50 --');
#                             once per worker; none encodes on this host only
#   --no-local                leave this host out of the encoding
#   --dry-run                 calibrate, then print the encode plan
#   --yes                     encode without asking, once calibrated
#   --start-at <time>         wait until then to start
#   --stop-at <time>          start no job that would end after then, and
#                             stop there (status 75); run again to go on
#
# Times are anything `date -d` reads; a time of day alone ("07:00") is its
# next occurrence (after --start-at, for --stop-at). Everything for the film
# goes in a folder named after it ("Title (Year)") beside the input: the
# output, the worst sample, the .analysis, and <output stem>.chunks, the
# chunk plan and every chunk returned and checked. A run cut short keeps
# its chunks in <output stem>.partial, and the same command picks them up.
#
# Every host gets one slot per NUMA node. Workers need SSH keys and Nix:
# their tools come from this repository's flake on GitHub, at FARM_REF
# (default: this checkout's commit, which must be pushed). PRESETS,
# SAMPLE_PERCENT, SAMPLE_DURATION, VMAF_TARGET_MEAN, VMAF_TARGET_LOW and
# QCOMP as in the single-host scripts.
# Set NO_COLOR=1 to disable colours.

set -euo pipefail

LIB="$(dirname "$(readlink -f "$0")")/lib"
for lib in ui util requirements probe audio calibrate mux score parts remote farm; do
    # shellcheck source=/dev/null
    source "$LIB/$lib.sh"
done

farm_parse_args "$@"
wait_for_start
SCORE=1
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

HDR_INJECTION=$FARM_HDR
profile_settings

heading "Hosts  ${DIM}${#SLOT_HOST[@]} slots${RESET}"
ENCODE_SLOTS=${#SLOT_HOST[@]}
item "Samples and ≈ $((CHUNK_SECONDS / 60)) min chunks, joined at scene cuts, on every slot; each chunk scored where it was encoded"
for i in "${!SLOT_HOST[@]}"; do
    setting "${SLOT_NAME[i]}" "${WRAP[${SLOT_HOST[i]}]:-no wrapper}$(encoder_slot_note "$i")"
done

###############################################################################
section "3 · Calibration — ${#PRESET_NAMES[@]} preset(s) × $CALIBRATION_SAMPLES samples of $SAMPLE_DURATION s ($SAMPLE_PERCENT%)"
###############################################################################

farm_calibrate
run_calibration
plan_output
cut_worst_sample
load_chunks
confirm_encode

###############################################################################
section "4 · Encode${DRY_RUN:+ — dry run}"
###############################################################################

encode_prepare
# The chunks outlive an interrupted run, for the next to go on from;
# mux_parts removes them with the rest of PARTS.
PARTIAL=""
# The stereo track (one core, decoding the original audio) alongside the
# video's chunks; its report, without the live block, follows them.
encode_stereo >"$WORK/stereo.log" 2>&1 &
STEREO_PID=$!
farm_encode_video
wait "$STEREO_PID" || { cat "$WORK/stereo.log"; die "The stereo track failed"; }
cat "$WORK/stereo.log"
[[ -n $DRY_RUN ]] || cat "$PARTS"/chunk-*.tsv >"$WORK/score.tsv"
encode_mux
report_score "$WORK/score.tsv"
profile_checks
