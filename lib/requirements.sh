# Section 0: checks that every tool is on PATH and can do what the scripts
# ask of it, then exits with status 1 if anything is missing. Sourced by the
# hevc-*.sh entry scripts.

REQUIREMENTS_FAILED=0

# Reports one requirement: ✔ with a detail, or ✖ and a recorded failure.
requirement() {
    local label=$1 met=$2 detail=$3
    if [[ $met == yes ]]; then
        printf '  %s✔%s %-20s %s' "$GREEN" "$RESET" "$label" "$DIM"
        wrap_text 25 "$detail"
        printf '%s' "$RESET"
    else
        printf '  %s✖%s %-20s ' "$RED" "$RESET" "$label"
        wrap_text 25 "$detail"
        REQUIREMENTS_FAILED=1
    fi
}

# Checks a command is on PATH; the detail is the first line of its version
# output (given as the remaining arguments).
require_tool() {
    local tool=$1
    shift
    if command -v "$tool" >/dev/null; then
        requirement "$tool" yes "$("$tool" "$@" 2>&1 | head -1 | sed 's/ Copyright.*//')"
    else
        requirement "$tool" no "not on PATH (try: nix develop path:./nix)"
    fi
}

require_bash() {
    local major=${BASH_VERSINFO[0]} minor=${BASH_VERSINFO[1]}
    # 4.4: declare -g on associative arrays, mapfile, "${empty[@]}" under set -u.
    if (( major > 4 || (major == 4 && minor >= 4) )); then
        requirement "bash" yes "$BASH_VERSION"
    else
        requirement "bash" no "$BASH_VERSION — 4.4 or newer needed"
    fi
}

# Checks the ffmpeg build has every named filter.
require_ffmpeg_filters() {
    local available missing=() f
    available=$(ffmpeg -hide_banner -filters 2>/dev/null | awk 'NF >= 3 { print $2 }')
    for f in "$@"; do
        grep -qx "$f" <<<"$available" || missing+=("$f")
    done
    if (( ${#missing[@]} == 0 )); then
        requirement "ffmpeg filters" yes "$*"
    else
        requirement "ffmpeg filters" no "missing: ${missing[*]} (ffmpeg-full has them)"
    fi
}

# Checks the ffmpeg build has every named encoder.
require_ffmpeg_encoders() {
    local available missing=() e
    available=$(ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 3 { print $2 }')
    for e in "$@"; do
        grep -qx "$e" <<<"$available" || missing+=("$e")
    done
    if (( ${#missing[@]} == 0 )); then
        requirement "ffmpeg encoders" yes "$*"
    else
        requirement "ffmpeg encoders" no "missing: ${missing[*]}"
    fi
}

# Encodes one frame as HEVC Main10 through libx265: a build without the
# 10-bit core fails here.
require_x265_main10() {
    local profile
    profile=$(ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -frames:v 1 -pix_fmt yuv420p10le \
        -c:v libx265 -profile:v main10 -x265-params log-level=error -f hevc - 2>/dev/null |
        ffprobe -v error -show_entries stream=profile -of csv=p=0 - 2>/dev/null || true)
    if [[ $profile == "Main 10" ]]; then
        requirement "libx265 Main10" yes "10-bit encode works"
    else
        requirement "libx265 Main10" no "a test encode did not produce Main 10"
    fi
}

# Scores two short test clips with the libvmaf options the calibration uses
# (model and features). CAMBI fails on very small frames, hence 640×360.
require_vmaf() {
    local options=$1
    if ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=640x360:d=0.1 -f lavfi -i testsrc2=s=640x360:d=0.1 \
        -lavfi "[0:v]format=yuv420p10le[d];[1:v]format=yuv420p10le[r];[d][r]libvmaf=$options" -f null - 2>/dev/null; then
        requirement "libvmaf" yes "$options"
    else
        requirement "libvmaf" no "cannot score with: $options"
    fi
}

# Checks the x265 CLI has the 10-bit core and Dolby Vision RPU injection,
# which only the CLI offers (libx265 through ffmpeg ignores the RPU).
require_x265_cli() {
    local build help
    if ! command -v x265 >/dev/null; then
        requirement "x265" no "not on PATH (try: nix develop path:./nix)"
        return
    fi
    build=$(x265 --version 2>&1 | grep -o 'build info.*' || true)
    help=$(x265 --fullhelp 2>&1 || true)
    if [[ $build == *10bit* ]] && grep -q -- '--dolby-vision-rpu' <<<"$help"; then
        requirement "x265" yes "$(x265 --version 2>&1 | grep -o 'version [^ ]*') · ${build##* } · Dolby Vision RPU"
    else
        requirement "x265" no "needs the 10-bit core and --dolby-vision-rpu (${build:-no build info})"
    fi
}

# Checks the PRESETS environment variable (see parse_presets), then that
# libx265 itself accepts each preset, with a one-frame encode.
require_sampling() {
    local problem
    if problem=$(parse_sampling); then
        requirement "Sampling" yes "$SAMPLE_PERCENT% of the film in $SAMPLE_DURATION s samples"
    else
        requirement "Sampling" no "$problem"
    fi
}

require_presets() {
    local problem i summary="" rejected=()
    if ! problem=$(parse_presets); then
        requirement "PRESETS" no "$problem — e.g. PRESETS=\"medium:16,17,18;slow:16,17,18\""
        return
    fi
    parse_presets
    for i in "${!PRESET_NAMES[@]}"; do
        summary+="${summary:+ · }${PRESET_NAMES[i]}: ${PRESET_CRFS[i]// /,}"
        command -v ffmpeg >/dev/null || continue
        ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -frames:v 1 -pix_fmt yuv420p10le \
            -c:v libx265 -preset "${PRESET_NAMES[i]}" -x265-params log-level=error -f null - 2>/dev/null ||
            rejected+=("${PRESET_NAMES[i]}")
    done
    if (( ${#rejected[@]} == 0 )); then
        requirement "PRESETS" yes "$summary (fastest first)"
    else
        requirement "PRESETS" no "libx265 rejects: ${rejected[*]}"
    fi
}

# Exits with status 1 if any requirement failed.
requirements_verdict() {
    if (( REQUIREMENTS_FAILED )); then
        echo
        die "Requirements not met"
    fi
}
