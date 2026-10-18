#!/usr/bin/env bash
#
# Analyse a 1080p SDR Blu-ray remux and convert it to HEVC Main10 that the
# NVIDIA Shield TV Pro can direct-play (no video or audio transcoding on the
# Shield or on a media server).
#
# Usage: hevc-1080p-sdr.sh [--dry-run] <input.mkv>
#
#   --dry-run  print the encode commands instead of running them
#
# PRESETS (environment) lists the x265 presets and CRFs to calibrate, as
# "preset:crf,crf,…;preset:crf,…" (default "slow:18,19,20"); section 3 walks each
# preset's CRFs and keeps the fastest preset within 10% of the smallest file.
# SAMPLE_PERCENT (default 3) is the share of the film it calibrates on, in
# samples of SAMPLE_DURATION seconds (default 20).
#
# Requires ffmpeg-full, jq and mkvtoolnix (`nix develop path:./nix`); section
# 0 checks them and exits with status 1 if anything is missing.
# Set NO_COLOR=1 to disable colours.

set -euo pipefail

LIB="$(dirname "$(readlink -f "$0")")/lib"
for lib in ui util requirements probe audio calibrate mux profile-1080p-sdr; do
    # shellcheck source=/dev/null
    source "$LIB/$lib.sh"
done

parse_args "$@"
profile_defaults

###############################################################################
section "0 · Requirements"
###############################################################################

profile_requirements
require_presets
require_sampling
requirements_verdict
parse_presets
setup_workdir

load_probe

###############################################################################
section "1 · Source analysis — $(basename "$INPUT")"
###############################################################################

profile_analysis

###############################################################################
section "2 · Proposed conversion — $PROFILE_TARGET"
###############################################################################

profile_settings

###############################################################################
section "3 · Calibration — ${#PRESET_NAMES[@]} preset(s) × $CALIBRATION_SAMPLES samples of $SAMPLE_DURATION s ($SAMPLE_PERCENT%)"
###############################################################################

run_calibration
plan_output
cut_worst_sample
confirm_encode

###############################################################################
section "4 · Encode${DRY_RUN:+ — dry run}"
###############################################################################

profile_encode
profile_checks
