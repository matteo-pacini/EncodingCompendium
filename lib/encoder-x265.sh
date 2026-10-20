# The x265 encoder: its presets, the x265 CLI that the full encode and the
# farm's chunks run, and what farm.sh checks on each host. Sourced by the
# profiles; the rest of lib/ only uses these names:
#
#   ENCODER_LABEL     the encoder as the reports name it
#   ENCODER_NAME      its name in the ENCODER_SETTINGS tag
#   ENCODER_PRESETS   its presets, fastest first
#   ENCODER_CRF_MAX   its highest CRF
#   VIDEO_EXT         extension of the raw stream encoded and joined
#   VIDEO_CODEC       ffprobe's "codec_name profile" for the output's video
#   DV_TARGET         the Dolby Vision profile it writes, at 2160p
#   PRESETS_EXAMPLE   a PRESETS value to show when one is malformed
#   FARM_HDR          how the farm carries Dolby Vision and HDR10+
#   encoder_preset_ok, encoder_prepare, encoder_command, encoder_job_params,
#   encoder_slot_note, encoder_probe_script, encoder_hdr_args,
#   encoder_stream_hdr, encoder_join_hdr (below)
#
# The profile sets ENCODER_PARAMS, the settings the calibration measures.

ENCODER_LABEL=x265
ENCODER_NAME=libx265
ENCODER_PRESETS=(ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)
ENCODER_CRF_MAX=51
VIDEO_EXT=hevc
VIDEO_CODEC="hevc Main 10"
DV_TARGET=8.1
PRESETS_EXAMPLE="medium:16,17,18;slow:16,17,18"
FARM_HDR="dovi_tool and hdr10plus_tool inject into the joined chunks"

# Whether libx265 accepts preset $1, by a one-frame encode.
encoder_preset_ok() {
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -frames:v 1 -pix_fmt yuv420p10le \
        -c:v libx265 -preset "$1" -x265-params log-level=error -f null - 2>/dev/null
}

# X265_PARAMS (what the calibration measured) as x265 CLI options.
x265_cli_args() {
    local IFS=: pair key value
    for pair in $X265_PARAMS; do
        key=${pair%%=*} value=${pair#*=}
        case $key in
            hdr10 | hdr10-opt | repeat-headers | high-tier)
                if [[ $value == 1 ]]; then echo "--$key"; else echo "--no-$key"; fi ;;
            no-*) echo "--$key" ;;
            *) printf '%s\n' "--$key" "$value" ;;
        esac
    done
}

# Section 4, from prepare_parts: sets X265_CLI.
encoder_prepare() {
    mapfile -t X265_CLI < <(x265_cli_args)
}

# `encoder_command <output> <slot> <frames> <last> [x265 options…]`: sets
# ENCODE, the x265 CLI reading y4m pictures on stdin and writing the raw
# stream to <output>. For a farm chunk, <slot> is the slot's index and
# <frames> the chunk's frame count; all but the <last> chunk aim to end
# with the VBV buffer back at 90%, the fullness the next one starts from.
# All three are empty for the single-host encode.
encoder_command() {
    local out=$1 i=$2 frames=$3 last=$4 cli=() arg skip=""
    shift 4
    # X265_CLI without "--asm avx512" on ARM, where x265 rejects it.
    for arg in "${X265_CLI[@]}"; do
        if [[ -n $skip ]]; then skip=""; continue; fi
        [[ -n $i && -n ${SLOT_ARM[i]} && $arg == --asm ]] && { skip=1; continue; }
        cli+=("$arg")
    done
    [[ -n $i && -n ${SLOT_POOLS[i]} ]] && cli+=(--pools "${SLOT_POOLS[i]}")
    [[ -n $frames ]] && cli+=(--frames "$frames")
    # Over the last 5 s only: x265 steers toward the end fullness from frame
    # --vbv-end-fr-adj (a fraction of --frames), by default the first, and
    # a whole chunk near the VBV cap then came out 40% smaller.
    [[ -n $frames && -z $last ]] &&
        cli+=(--vbv-end 0.9 --vbv-end-fr-adj "$(awk -v n="$frames" -v r="$FPS" 'BEGIN { a = 1 - 5 * r / n; printf "%.3f", (a > 0 ? a : 0) }')")
    ENCODE=(x265 --input - --y4m --preset "$PRESET" --crf "$SELECTED_CRF" --output-depth 10 --profile main10
        "${cli[@]}" "$@" --log-level error --no-progress -o "$out")
}

# X265_PARAMS for slot $1: without asm on ARM, with the slot's NUMA pool.
slot_params() {
    local params=$X265_PARAMS
    [[ -n ${SLOT_ARM[$1]} ]] && params=${params//:asm=avx512/}
    [[ -n ${SLOT_POOLS[$1]} ]] && params+=":pools=${SLOT_POOLS[$1]}"
    echo "$params"
}

# The variables encode_sample and ENCODE read beyond the profile's filters,
# as lines of a job script for slot $1.
encoder_job_params() {
    printf 'X265_PARAMS=%q\n' "$(slot_params "$1")"
    declare -p COLOUR_FLAGS
}

# The output name gives the codec as HEVC, not an AVC or VC-1 source's.
rename_stem() { sed -E 's/\[(AVC|VC-1)\]/[HEVC]/g; s/\[(h264|x264)\]/[h265]/g' <<<"$1"; }

# The options that put RPU (with Dolby Vision) into the stream, one per
# line. HDR10+ goes in after the encode (encoder_stream_hdr): nixpkgs
# builds x265 without HDR10_PLUS, and --dhdr10-info then only warns.
encoder_hdr_args() {
    [[ -z $DV_PROFILE ]] || printf '%s\n' --dolby-vision-profile "$DV_TARGET" --dolby-vision-rpu "$RPU"
    return 0
}

# After the encode: HDR10PLUS_JSON (with HDR10+) into VIDEO_STREAM.
encoder_stream_hdr() {
    [[ -n ${HAS_HDR10PLUS:-} ]] || return 0
    heading "HDR10+ metadata into the stream"
    run hdr10plus_tool inject -i "$VIDEO_STREAM" -j "$HDR10PLUS_JSON" -o "$VIDEO_STREAM.hdr10plus"
    run mv -f "$VIDEO_STREAM.hdr10plus" "$VIDEO_STREAM"
}

# The farm, once the chunks are joined: HDR10+ and the Dolby Vision RPU
# into VIDEO_STREAM.
encoder_join_hdr() {
    encoder_stream_hdr
    if [[ -n ${DV_PROFILE:-} ]]; then
        progress "Putting the Dolby Vision RPU in…"
        dovi_tool inject-rpu -i "$VIDEO_STREAM" --rpu-in "$RPU" -o "$VIDEO_STREAM.dv" >/dev/null ||
            die "dovi_tool could not put the RPU in the joined chunks"
        mv -f "$VIDEO_STREAM.dv" "$VIDEO_STREAM"
    fi
    progress ""
}

# What slot $1's encoder runs with beyond the settings, as " · …" parts.
encoder_slot_note() {
    printf '%s' "${SLOT_POOLS[$1]:+ · x265 pools ${SLOT_POOLS[$1]}}${SLOT_ARM[$1]:+ · without asm=avx512 (ARM)}"
}

# Lines of lib/remote.sh's probe script, run on each host inside the tools
# with $arch and $encoders (ffmpeg's encoder list) set: prints the
# encoder's build ("encoder=", compared between hosts of one system), its
# version and the SIMD it uses, and adds what it lacks to $missing.
encoder_probe_script() {
    cat <<'EOF'
echo "encoder=$(readlink -f "$(command -v x265)")"
echo "encoder_version=x265 $(x265 --version 2>&1 | grep -o 'version [^ ]*' | head -1 | cut -d' ' -f2)"
asm=""; [[ $arch == x86_64 ]] && asm="--asm avx512"
echo "simd=$(ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
    x265 --input - --y4m --preset ultrafast --output-depth 10 $asm --log-level info -o /dev/null 2>&1 |
    sed -n 's/.*using cpu capabilities: //p' | head -1)"
grep -qw libx265 <<<"$encoders" || missing+="libx265 "
EOF
}
