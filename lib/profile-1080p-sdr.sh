# The 1080p SDR profile: Blu-ray remux to HEVC Main10 within Level 4.1
# Main tier. Sourced by hevc-1080p-sdr.sh and hevc-farm.sh after the
# other lib/ files; each function is one section's profile-specific part.
# The AV1 profile builds on it: its analysis, filters and gates.

# shellcheck source=/dev/null
source "$LIB/encoder-x265.sh"

PROFILE_TARGET="HEVC Main10 · Level 4.1 Main · 20 Mb/s VBV"

# PRESETS, sampling and VMAF defaults, before section 0.
profile_defaults() {
    PRESETS=${PRESETS:-slow:18,19,20}
    SAMPLE_PERCENT=${SAMPLE_PERCENT:-3}
    SAMPLE_DURATION=${SAMPLE_DURATION:-20}
    VMAF_TARGET_MEAN=${VMAF_TARGET_MEAN:-96}
    VMAF_TARGET_LOW=${VMAF_TARGET_LOW:-94}
    QCOMP=${QCOMP:-0.7}

    # full_ref CAMBI scores only banding the encode adds over the source.
    VMAF_OPTIONS="model=version=vmaf_v0.6.1neg:feature='name=cambi\:full_ref=true'"
    return 0
}

# Section 0: the tools and features this profile needs.
profile_requirements() {
    require_bash
    require_tool ffmpeg -version
    require_tool ffprobe -version
    require_tool jq --version
    require_tool mkvmerge --version
    require_tool mkvpropedit --version
    require_x265_cli
    require_tool sha256sum --version
    require_tool pgrep -V
    if command -v ffmpeg >/dev/null; then
        require_ffmpeg_filters libvmaf xpsnr cropdetect ebur128 setparams pan crop
        require_ffmpeg_encoders libx265 aac
        require_x265_main10
        require_qcomp
        require_vmaf "$VMAF_OPTIONS"
    fi
    return 0
}

# Section 1 after load_probe: reports the source and stops on one this
# profile cannot convert.
profile_analysis() {
    report_container
    report_video
    [[ -z $V_PRIMARIES ]] && WARNINGS+=("Untagged colour: tagged BT.709, as Blu-ray 1080p is.")
    (( V_HEIGHT > 1080 )) && WARNINGS+=("Source is taller than 1080p — this script assumes a 1080p source.")
    detect_crop
    report_audio
    report_subtitles
    report_chapters
    report_observations

    [[ -n $V_IS_HDR ]] && die "HDR source — this script only handles SDR 1080p (see hevc-2160p-hdr.sh)"
    return 0
}

# Section 2: the x265 settings, audio and container plans, gates and the
# encode and scoring filters.
profile_settings() {
    #################
    # x265 settings #
    #################

    # Level 4.1 Main tier caps the bitrate at 20 Mb/s; the VBV keeps peaks inside
    # it so any Level 4.1 decoder can play the stream.
    LEVEL="level-idc=41:vbv-maxrate=20000:vbv-bufsize=20000"
    COLOUR="colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited:chromaloc=0"
    AQ="aq-mode=3:aq-strength=0.8"
    # x265's default from preset slow up; pinned so faster presets keep grain.
    PSY="psy-rdoq=1.0"
    DETAIL="no-sao=1:no-strong-intra-smoothing=1:deblock=-2,-2"
    RC="qcomp=$QCOMP:rc-lookahead=60:bframes=8:ref=5"
    GOP="keyint=240:min-keyint=24"
    # x265 only uses its AVX-512 kernels when asked; without AVX-512 it warns and
    # falls back to what it detects.
    ASM="asm=avx512"
    X265_PARAMS="$COLOUR:$LEVEL:$AQ:$PSY:$DETAIL:$RC:$GOP:$ASM"
    ENCODER_PARAMS=$X265_PARAMS
    # x265-params only writes the HEVC VUI; these set the Matroska Colour elements.
    COLOUR_FLAGS=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv -chroma_sample_location left)

    heading "Video  ${DIM}#$V → HEVC Main10${RESET}"
    item "libx265 · preset and CRF picked in section 3 · yuv420p10le"
    setting "Main10" "10-bit even from an 8-bit source"
    setting "Level / VBV" "$LEVEL"
    setting "Colour" "$COLOUR"
    setting "Adaptive quant." "$AQ"
    setting "Psycho-visual" "$PSY"
    setting "Detail" "$DETAIL"
    setting "Rate control" "$RC"
    setting "GOP" "$GOP"
    setting "Assembly" "$ASM"
    if [[ -n $CROP ]]; then
        setting "Crop" "$CROP"
    fi

    plan_audio
    plan_container
    sdr_scoring_settings
    return 0
}

# Section 2's calibration and scoring: the gates, then the encode and
# scoring filters.
sdr_scoring_settings() {
    # Worst half second. CAMBI ≈ 5 is where Netflix finds banding "slightly
    # annoying"; 2.5 stays clear of it on an OLED in a dark room.
    CAMBI_MAX=2.5
    # A CRF step costing this many times the previous step's XPSNR is a knee.
    KNEE_RATIO=1.5
    CALIBRATION_SAMPLES=$(sample_count)

    plan_gates

    # The source frames are untagged. Told to write BT.709, ffmpeg 9.0.1 then
    # colour-converts them on the way in (a lossless encode is no longer
    # bit-exact) and leaves the Matroska Colour primaries/transfer unset.
    # Declaring the frames BT.709 avoids both.
    TAG_BT709="setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
    VF=(-vf "${CROP:+$CROP,}$TAG_BT709")
    # libvmaf pairs frames by timestamp, and the millisecond Matroska timestamps
    # of source and encode round differently (…, 84 vs 83, …). Renumbering both
    # from the frame index makes the pairing exact.
    RETIME="settb=AVTB,setpts=N/FRAME_RATE/TB"
    # Both sides tagged identically, or the filter graph colour-converts one of
    # them to match the other and the scores measure that conversion.
    REF_FILTER="${CROP:+$CROP,}$TAG_BT709,$RETIME,format=yuv420p10le"
    DIST_FILTER="$TAG_BT709,$RETIME,format=yuv420p10le"

    EXTRA_TAGS=()
    return 0
}

encode_sample() {
    ffmpeg -nostdin -v error "${@:5}" -y -i "$3" -map 0:v:0 "${VF[@]}" -c:v libx265 -preset "$1" -crf "$2" \
        -pix_fmt yuv420p10le -profile:v main10 "${COLOUR_FLAGS[@]}" -x265-params "$X265_PARAMS:log-level=error" "$4"
}

# Section 4, first: the intermediates and the x265 CLI options.
encode_prepare() {
    prepare_output
    prepare_parts
}

# Section 4, last: the mux, with the Matroska Colour elements of
# COLOUR_FLAGS (ITU-T H.273 1 = BT.709; siting 1,2 = left).
encode_mux() {
    mux_parts "HEVC Main10 · CRF $SELECTED_CRF" --colour-matrix-coefficients 0:1 --colour-range 0:1 \
        --colour-transfer-characteristics 0:1 --colour-primaries 0:1 --chroma-siting 0:1,2
}

# Section 4.
profile_encode() {
    encode_prepare
    encode_stereo
    encode_video
    encode_mux
}

# Section 5.
profile_checks() {
    report_result
    check "Colour" "bt709 bt709 bt709 tv" "$(out_probe '.streams[0] | "\(.color_primaries) \(.color_transfer) \(.color_space) \(.color_range)"')"
    return 0
}
