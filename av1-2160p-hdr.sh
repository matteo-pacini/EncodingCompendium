#!/usr/bin/env bash
#
# Analyse a 2160p HDR UHD Blu-ray remux (HDR10, optionally Dolby Vision and
# HDR10+) and convert it to AV1 Main 10-bit HDR10 with SVT-AV1-HDR — plus
# Dolby Vision profile 10.1 and HDR10+ when the source has them. HDR is kept
# as-is: no tone mapping.
#
# Usage: av1-2160p-hdr.sh [--dry-run] [--score] [--yes] [--start-at <time>] <input.mkv>
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
# PRESETS (environment) lists the SVT-AV1 presets (13 fastest, 0 slowest)
# and CRFs to calibrate, as "preset:crf,crf,…;preset:crf,…" (default
# "4:16,18,20,22,24"); section 3 walks each preset's CRFs and keeps the
# fastest preset within 10% of the smallest file.
# VMAF_TARGET_MEAN and VMAF_TARGET_LOW (defaults 96 and 94) are the VMAF NEG
# gates: the pooled mean, and the 1%-low pooled and in every scene.
# VARIANCE_BOOST=1 turns on SVT-AV1's variance boost (default 0, off).
# SAMPLE_PERCENT (default 1.5) is the share of the film it calibrates on, in
# samples of SAMPLE_DURATION seconds (default 12).
#
# Requires ffmpeg-full, jq, mkvtoolnix, dovi_tool, hdr10plus_tool and
# SVT-AV1-HDR's SvtAv1EncApp
# (`nix develop path:./nix`); section 0 checks them and exits with status 1
# if anything is missing.
# Set NO_COLOR=1 to disable colours.

set -euo pipefail

LIB="$(dirname "$(readlink -f "$0")")/lib"
for lib in ui util requirements probe audio calibrate mux score parts profile-av1-2160p-hdr; do
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
