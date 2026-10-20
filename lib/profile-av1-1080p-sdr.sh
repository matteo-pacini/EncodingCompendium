# The AV1 1080p SDR profile: Blu-ray remux to AV1 Main 10-bit with
# SVT-AV1-HDR.
# The 1080p SDR profile with another encoder: its source analysis, filters,
# gates, audio and container plans and result checks, and here the
# functions that differ. Sourced by av1-1080p-sdr.sh and hevc-farm.sh
# --codec av1 after the other lib/ files.

# shellcheck source=/dev/null
source "$LIB/profile-1080p-sdr.sh"
# After the profile, whose encoder (x265) this one's names replace.
# shellcheck source=/dev/null
source "$LIB/encoder-svtav1.sh"

PROFILE_TARGET="AV1 Main 10-bit"

# PRESETS, sampling and VMAF defaults, before section 0.
profile_defaults() {
    PRESETS=${PRESETS:-4:18,20,22,24,26}
    SAMPLE_PERCENT=${SAMPLE_PERCENT:-3}
    SAMPLE_DURATION=${SAMPLE_DURATION:-20}
    VMAF_TARGET_MEAN=${VMAF_TARGET_MEAN:-96}
    VMAF_TARGET_LOW=${VMAF_TARGET_LOW:-94}
    VARIANCE_BOOST=${VARIANCE_BOOST:-0}

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
    require_tool sha256sum --version
    require_tool pgrep -V
    if command -v ffmpeg >/dev/null; then
        require_svtav1
        require_variance_boost
        require_ffmpeg_filters libvmaf xpsnr cropdetect ebur128 setparams pan crop
        require_ffmpeg_encoders aac
        require_vmaf "$VMAF_OPTIONS"
    fi
    return 0
}

# Section 2: the SVT-AV1 settings, audio and container plans, gates and
# the encode and scoring filters.
profile_settings() {
    ####################
    # SVT-AV1 settings #
    ####################

    # ITU-T H.273 1 = BT.709; "left" is MPEG-2 siting, as Blu-ray's.
    COLOUR="color-primaries=1:transfer-characteristics=1:matrix-coefficients=1:color-range=0:chroma-sample-position=left"
    # Keyframes every 10 s at 24p for seeking; the farm's chunks also start
    # with one, at a scene cut.
    GOP="keyint=240"
    # VQ: tuned for the eye rather than for PSNR, the default.
    TUNE="tune=0"
    AQ=$(svt_variance_boost)
    # SVT-AV1-HDR's defaults, pinned: quantisation matrices with flatter
    # low end, a sharper bias, and temporal filtering weakened (keyframes
    # most) so it neither smears grain nor makes keyframes pulse.
    DETAIL="enable-qm=1:qm-min=6:chroma-qm-min=8:sharpness=1:tf-strength=1:kf-tf-strength=1:ac-bias=1.0"
    # More bits to dark frames, where AV1 bands first.
    LUMA="luminance-qp-bias=20"
    # The real grain is encoded (no denoising) and light synthetic grain is
    # signalled on top, as dither; adaptive grain block size is off for a
    # reported flicker (SVT-AV1 work item 2298). Scores leave it unapplied.
    GRAIN="film-grain=6:film-grain-denoise=0:adaptive-film-grain=0"
    # Two tile columns: more threads for a software decoder.
    TILES="tile-columns=1"
    SVT_PARAMS="$COLOUR:$GOP:$TUNE:$AQ:$DETAIL:$LUMA:$GRAIN:$TILES"
    ENCODER_PARAMS=$SVT_PARAMS
    mapfile -t SVT_CLI < <(svt_cli_args)
    # libdav1d applies the grain by default; exported as side data, it is not.
    DIST_DECODE=(-export_side_data film_grain)

    heading "Video  ${DIM}#$V → AV1 Main 10-bit${RESET}"
    item "$(SvtAv1EncApp --version 2>&1 | head -1) · preset and CRF picked in section 3"
    setting "10-bit" "even from an 8-bit source"
    setting "Colour" "$COLOUR"
    setting "GOP" "$GOP"
    setting "Tune" "$TUNE"
    setting "Adaptive quant." "$AQ"
    setting "Detail" "$DETAIL"
    setting "Dark frames" "$LUMA"
    setting "Film grain" "$GRAIN"
    setting "Tiles" "$TILES"
    if [[ -n $CROP ]]; then
        setting "Crop" "$CROP"
    fi

    plan_audio
    plan_container
    sdr_scoring_settings
    item "Scored with the synthetic grain left unapplied"
    return 0
}

# As the full encode, into Matroska for the metrics.
encode_sample() {
    ffmpeg -nostdin -v error -i "$3" -map 0:v:0 "${VF[@]}" -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
        svt_encode -i stdin -b stdout --preset "$1" --crf "$2" "${SVT_CLI[@]}" |
        ffmpeg -nostdin -v error "${@:5}" -y -f ivf -i - -c copy "$4"
}

# Section 4, last: the mux, with the Matroska Colour elements of COLOUR.
encode_mux() {
    mux_parts "AV1 10-bit · CRF $SELECTED_CRF" --colour-matrix-coefficients 0:1 --colour-range 0:1 \
        --colour-transfer-characteristics 0:1 --colour-primaries 0:1 --chroma-siting 0:1,2
}
