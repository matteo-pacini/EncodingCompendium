#!/usr/bin/env bash
#
# Analyse a 1080p SDR Blu-ray remux and convert it to HEVC Main10 within
# Level 4.1 Main tier (20 Mb/s VBV), so any decoder of that level plays it.
#
# Usage: hevc-1080p-sdr.sh [--dry-run] [--score] [--yes] [--start-at <time>] <input.mkv>
#
#   --dry-run  print the encode commands instead of running them
#   --score    score the whole output against the source after the encode
#              (VMAF NEG, CAMBI, XPSNR) and store the result in its tags
#              and the .analysis
#   --yes      encode without asking, once calibrated
#   --start-at wait until then to start: anything `date -d` reads; a time
#              of day alone ("23:00") is its next occurrence
#
# Everything for the film goes in a folder named after it ("Title (Year)")
# beside the input: the output, the worst sample and the .analysis.
#
# PRESETS (environment) lists the x265 presets and CRFs to calibrate, as
# "preset:crf,crf,…;preset:crf,…" (default "slow:18,19,20"); section 3 walks each
# preset's CRFs and keeps the fastest preset within 10% of the smallest file.
# SAMPLE_PERCENT (default 3) is the share of the film it calibrates on, in
# samples of SAMPLE_DURATION seconds (default 20).
#
# Requires ffmpeg-full, jq, mkvtoolnix and the x265 CLI (`nix develop
# path:./nix`); section 0 checks them and exits with status 1 if anything
# is missing.
# Set NO_COLOR=1 to disable colours.

set -euo pipefail

LIB="$(dirname "$(readlink -f "$0")")/lib"
for lib in ui util requirements probe audio calibrate mux score parts profile-1080p-sdr; do
    # shellcheck source=/dev/null
    source "$LIB/$lib.sh"
done

parse_args "$@"
wait_for_start
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
[[ -z $SCORE ]] || score_output
profile_checks
