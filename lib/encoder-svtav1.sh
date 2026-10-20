# The SVT-AV1 encoder, as SVT-AV1-HDR's SvtAv1EncApp: its presets, the
# command that calibration, the full encode and the farm's chunks run, and
# what hevc-farm.sh checks on each host. The same names as
# lib/encoder-x265.sh, which describes them; sourced by the AV1 profile.
#
# The profile sets SVT_PARAMS ("key=value:…", SvtAv1EncApp's long options
# without the dashes) and ENCODER_PARAMS to it.

ENCODER_LABEL=SVT-AV1
ENCODER_NAME=SvtAv1EncApp
# SVT-AV1-HDR also has -1 and -2, research presets far slower than 0.
ENCODER_PRESETS=(13 12 11 10 9 8 7 6 5 4 3 2 1 0)
ENCODER_CRF_MAX=63
# Raw OBUs: chunks joined end to end are one valid stream, as each starts
# with its sequence header and a key frame.
VIDEO_EXT=obu
VIDEO_CODEC="av1 Main"
DV_TARGET=10.1
FARM_HDR="each chunk's slice of the RPU and HDR10+ metadata, into SvtAv1EncApp"

# The output name gives the codec as AV1, not the source's.
rename_stem() { sed -E 's/\[(AVC|h264|x264|VC-1|HEVC|h265|x265)\]/[AV1]/g' <<<"$1"; }

# SvtAv1EncApp with its library logging errors only, and without the
# progress line and summary it writes to stderr whatever --progress says.
# Its status is the pipeline's under pipefail, which every caller sets.
svt_encode() {
    { SVT_LOG=1 SvtAv1EncApp "$@" --progress 0 2>&1 >&3 3>&- | awk '/^SUMMARY/ { s = 1 } !s && !/^Encoding *$/' >&2 3>&-; } 3>&1
}

# A one-frame 10-bit test encode of the testsrc2 pattern at preset $1 into
# file $2 (raw OBUs), with options $3….
svt_test_encode() {
    local preset=$1 out=$2
    shift 2
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -frames:v 1 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
        svt_encode -i stdin -b "$out" --preset "$preset" "$@"
}

# Whether SvtAv1EncApp accepts preset $1, by a one-frame encode.
encoder_preset_ok() {
    local out rc
    out=$(mktemp)
    svt_test_encode "$1" "$out" 2>/dev/null && rc=0 || rc=$?
    rm -f "$out"
    return $rc
}

# SVT_PARAMS as SvtAv1EncApp options.
svt_cli_args() {
    local IFS=: pair
    for pair in $SVT_PARAMS; do
        printf '%s\n' "--${pair%%=*}" "${pair#*=}"
    done
}

# Section 0: SvtAv1EncApp is SVT-AV1-HDR, and its AV1 Main 10-bit with
# film grain decodes through ffmpeg's libdav1d with the grain left
# unapplied (DIST_DECODE).
require_svtav1() {
    local out version stream
    if ! command -v SvtAv1EncApp >/dev/null; then
        requirement "SvtAv1EncApp" no "not on PATH (try: nix develop path:./nix)"
        return
    fi
    version=$(SvtAv1EncApp --version 2>&1 | head -1)
    out=$(mktemp)
    stream=$(svt_test_encode 8 "$out" --film-grain 8 2>/dev/null &&
        ffmpeg -nostdin -v error -export_side_data film_grain -c:v libdav1d -i "$out" -f null - 2>/dev/null &&
        ffprobe -v error -show_entries stream=codec_name,profile,pix_fmt -of csv=p=0 "$out" 2>/dev/null || true)
    rm -f "$out"
    if [[ $version != SVT-AV1-HDR* ]]; then
        requirement "SvtAv1EncApp" no "$version — the settings are SVT-AV1-HDR's"
    elif [[ $stream == av1,Main,yuv420p10le ]]; then
        requirement "SvtAv1EncApp" yes "$version · AV1 Main 10-bit · film grain decodes"
    else
        requirement "SvtAv1EncApp" no "$version — a test encode did not decode as AV1 Main 10-bit"
    fi
}

# Checks VARIANCE_BOOST: 0 or 1.
require_variance_boost() {
    if [[ $VARIANCE_BOOST == [01] ]]; then
        requirement "Variance boost" yes "$( ((VARIANCE_BOOST)) && echo on || echo off)"
    else
        requirement "Variance boost" no "VARIANCE_BOOST '$VARIANCE_BOOST' is not 0 or 1"
    fi
}

# The adaptive quantisation settings for VARIANCE_BOOST. Variance boost
# lifts flat, low-contrast areas (skies, faces, dark gradients) that AQ
# alone starves; octile 6 as in the JET guide.
svt_variance_boost() {
    if ((VARIANCE_BOOST)); then
        echo "enable-variance-boost=1:variance-boost-strength=2:variance-octile=6"
    else
        echo "enable-variance-boost=0"
    fi
}

# Section 4, from prepare_parts. SVT_CLI is set with SVT_PARAMS already.
encoder_prepare() { :; }

# `encoder_command <output> <slot> <frames> <last> [SvtAv1EncApp
# options…]`: sets ENCODE, SvtAv1EncApp reading y4m pictures on stdin and
# writing raw OBUs to <output>. A chunk needs nothing a whole film does
# not: with constant quality and no VBV, no rate control state carries
# from one chunk to the next, so slot, frames and last are not used.
encoder_command() {
    local out=$1
    shift 4
    ENCODE=(svt_encode -i stdin -b "$out" --preset "$PRESET" --crf "$SELECTED_CRF" "${SVT_CLI[@]}" "$@")
}

# The variables and functions encode_sample and ENCODE run with beyond the
# profile's filters, as lines of a job script (slot $1 needs nothing of
# its own).
encoder_job_params() {
    declare -p SVT_CLI
    declare -f svt_encode
}

# The options that put RPU (with Dolby Vision) and HDR10PLUS_JSON (with
# HDR10+) into the stream, one per line.
encoder_hdr_args() {
    [[ -z $DV_PROFILE ]] || printf '%s\n' --dolby-vision-rpu "$RPU"
    [[ -z $HAS_HDR10PLUS ]] || printf '%s\n' --hdr10plus-json "$HDR10PLUS_JSON"
    return 0
}

# `encoder_chunk_hdr <slot> <k> <name>`: sets CHUNK_HDR_ARGS, chunk k's
# HDR options, after putting its slices of RPU and HDR10PLUS_JSON on the
# slot as <name>.rpu and <name>.json (kept in PARTS until the chunk is
# done, as a local slot links to them): SvtAv1EncApp takes the metadata
# from the chunk's first frame on, and a joined AV1 stream has no tool
# to add it afterwards.
encoder_chunk_hdr() {
    local i=$1 k=$2 name=$3 first=${CHUNK_START[$2]} next=${CHUNK_START[$2 + 1]}
    CHUNK_HDR_ARGS=()
    if [[ -n ${DV_PROFILE:-} ]]; then
        hdr_slice "$first" "$next" "$SOURCE_RPU_FRAMES" >"$PARTS/$name.edit.json"
        dovi_tool editor -i "$RPU" -j "$PARTS/$name.edit.json" -o "$PARTS/$name.rpu" >/dev/null || return
        slot_put "$i" "$PARTS/$name.rpu" "$name.rpu" || return
        CHUNK_HDR_ARGS+=(--dolby-vision-rpu "$name.rpu")
    fi
    if [[ -n ${HAS_HDR10PLUS:-} ]]; then
        hdr_slice "$first" "$next" "$SOURCE_HDR10PLUS_FRAMES" >"$PARTS/$name.edit.json"
        hdr10plus_tool editor -i "$HDR10PLUS_JSON" -j "$PARTS/$name.edit.json" -o "$PARTS/$name.json" >/dev/null || return
        slot_put "$i" "$PARTS/$name.json" "$name.json" || return
        CHUNK_HDR_ARGS+=(--hdr10plus-json "$name.json")
    fi
    rm -f "$PARTS/$name.edit.json"
}

# `hdr_slice <first> <next> <count>`: the dovi_tool and hdr10plus_tool
# editor JSON keeping frames first to next - 1 of count. The later range
# goes first: hdr10plus_tool renumbers the frames after each removal.
hdr_slice() {
    local ranges=()
    (( $2 < $3 )) && ranges+=("$2-$(($3 - 1))")
    (( $1 > 0 )) && ranges+=("0-$(($1 - 1))")
    jq -n '{remove: $ARGS.positional}' --args "${ranges[@]}"
}

# SvtAv1EncApp wrote the metadata itself, into the stream or each chunk.
encoder_stream_hdr() { :; }
encoder_join_hdr() { :; }

# Every slot runs the same settings.
encoder_slot_note() { :; }

# See lib/encoder-x265.sh. The SIMD is what the library selects, from its
# info log; libdav1d is needed to score.
encoder_probe_script() {
    cat <<'EOF'
echo "encoder=$(readlink -f "$(command -v SvtAv1EncApp)")"
echo "encoder_version=$(SvtAv1EncApp --version 2>&1 | head -1)"
echo "simd=$(ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:d=0.04 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
    SvtAv1EncApp -i stdin -b /dev/null --preset 12 --progress 0 2>&1 | sed -n 's/.*asm level selected : //p' | tr -d ']' | head -1)"
decoders=$(ffmpeg -hide_banner -decoders 2>/dev/null)
grep -qw libdav1d <<<"$decoders" || missing+="libdav1d "
command -v SvtAv1EncApp >/dev/null || missing+="SvtAv1EncApp "
EOF
}
