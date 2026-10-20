# The AV1 2160p HDR profile: UHD Blu-ray remux (HDR10, optionally Dolby
# Vision and HDR10+) to AV1 Main 10-bit HDR10 with SVT-AV1-HDR, plus Dolby
# Vision 10.1 and HDR10+ when the source has them.
# The 2160p HDR profile with another encoder: its source analysis, HDR
# reading, filters, gates, audio and container plans and result checks,
# and here the functions that differ. Sourced by av1-2160p-hdr.sh and
# hevc-farm.sh --codec av1 after the other lib/ files.

# shellcheck source=/dev/null
source "$LIB/profile-2160p-hdr.sh"
# After the profile, whose encoder (x265) this one's names replace.
# shellcheck source=/dev/null
source "$LIB/encoder-svtav1.sh"

PROFILE_TARGET="AV1 Main 10-bit HDR10"

# PRESETS, sampling and VMAF defaults, before section 0.
profile_defaults() {
    PRESETS=${PRESETS:-4:16,18,20,22,24}
    SAMPLE_PERCENT=${SAMPLE_PERCENT:-1.5}
    SAMPLE_DURATION=${SAMPLE_DURATION:-12}
    VMAF_TARGET_MEAN=${VMAF_TARGET_MEAN:-96}
    VMAF_TARGET_LOW=${VMAF_TARGET_LOW:-94}
    VARIANCE_BOOST=${VARIANCE_BOOST:-0}

    # full_ref CAMBI scores only banding the encode adds over the source; eotf=pq
    # judges visibility on the PQ curve instead of BT.1886.
    VMAF_OPTIONS="model=version=vmaf_4k_v0.6.1neg:feature='name=cambi\:full_ref=true\:eotf=pq'"
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
    require_tool dovi_tool --version
    require_tool hdr10plus_tool --version
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

# MASTER_DISPLAY (x265's units: chromaticities in 1/50000, luminance in
# 1/10000 cd/m²) in SvtAv1EncApp's, chromaticities and cd/m² as decimals.
svt_master_display() {
    local GX GY BX BY RX RY WX WY LMAX LMIN
    read -r GX GY BX BY RX RY WX WY LMAX LMIN <<<"$(grep -o '[0-9]\+' <<<"$MASTER_DISPLAY" | tr '\n' ' ')"
    awk -v gx="$GX" -v gy="$GY" -v bx="$BX" -v by="$BY" -v rx="$RX" -v ry="$RY" -v wx="$WX" -v wy="$WY" \
        -v lmax="$LMAX" -v lmin="$LMIN" 'BEGIN {
        c = 50000; l = 10000
        printf "G(%.4f,%.4f)B(%.4f,%.4f)R(%.4f,%.4f)WP(%.4f,%.4f)L(%g,%g)\n",
            gx/c, gy/c, bx/c, by/c, rx/c, ry/c, wx/c, wy/c, lmax/l, lmin/l }'
}

# Section 2: the SVT-AV1 settings, audio and container plans, gates and
# the encode and scoring filters.
profile_settings() {
    ####################
    # SVT-AV1 settings #
    ####################

    # ITU-T H.273 9 = BT.2020, 16 = PQ; SvtAv1EncApp names only these two
    # chroma sitings.
    case $V_CHROMALOC in
        left) SITING=left ;; topleft) SITING=topleft ;; *) SITING=unknown ;;
    esac
    COLOUR="color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:color-range=0:chroma-sample-position=$SITING"
    HDR="${MASTER_DISPLAY:+mastering-display=$(svt_master_display)}"
    HDR+="${MAX_CLL:+${HDR:+:}content-light=$MAX_CLL}"
    GOP="keyint=240"
    TUNE="tune=0"
    AQ=$(svt_variance_boost)
    DETAIL="enable-qm=1:qm-min=6:chroma-qm-min=8:sharpness=1:tf-strength=1:kf-tf-strength=1:ac-bias=1.0"
    LUMA="luminance-qp-bias=20"
    GRAIN="film-grain=6:film-grain-denoise=0:adaptive-film-grain=0"
    # Four tile columns: more threads for a software decoder at 2160p.
    TILES="tile-columns=2"
    SVT_PARAMS="$COLOUR${HDR:+:$HDR}:$GOP:$TUNE:$AQ:$DETAIL:$LUMA:$GRAIN:$TILES"
    ENCODER_PARAMS=$SVT_PARAMS
    mapfile -t SVT_CLI < <(svt_cli_args)
    COLOUR_FLAGS=()
    hdr_tags
    # libdav1d applies the grain by default; exported as side data, it is not.
    DIST_DECODE=(-export_side_data film_grain)

    heading "Video  ${DIM}#$V → AV1 Main 10-bit HDR10${DV_PROFILE:+ + Dolby Vision $DV_TARGET}${HAS_HDR10PLUS:+ + HDR10+}${RESET}"
    item "$(SvtAv1EncApp --version 2>&1 | head -1) · preset and CRF picked in section 3"
    setting "Colour" "$COLOUR"
    setting "HDR10" "${HDR:-none}"
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
    if [[ -n $DV_PROFILE ]]; then
        item "Dolby Vision profile $DV_PROFILE → $DV_TARGET (BL = HDR10, compatibility ID 1)"
        setting "RPU" "${DOVI_EXTRACT[*]}"
        setting "Mux" "mkvmerge (writes the Dolby Vision configuration)"
    fi
    if [[ -n $HAS_HDR10PLUS ]]; then
        item "HDR10+ dynamic metadata copied"
        setting "Metadata" "hdr10plus_tool extract"
    fi
    if [[ -n $DV_PROFILE || -n $HAS_HDR10PLUS ]]; then
        setting "Injection" "${HDR_INJECTION:-SvtAv1EncApp${DV_PROFILE:+ --dolby-vision-rpu}${HAS_HDR10PLUS:+ --hdr10plus-json}}"
    fi

    plan_audio
    ORIGINAL_MEDIA_TYPE="Ultra HD Blu-ray"
    plan_container

    hdr_scoring_settings
    item "Scored with the synthetic grain left unapplied"
    return 0
}

# As the full encode, into Matroska for the metrics.
encode_sample() {
    ffmpeg -nostdin -v error -i "$3" -map 0:v:0 "${VF[@]}" -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
        svt_encode -i stdin -b stdout --preset "$1" --crf "$2" "${SVT_CLI[@]}" |
        ffmpeg -nostdin -v error "${@:5}" -y -f ivf -i - -c copy "$4"
}

# Section 4, last: the mux, with the Matroska Colour elements and HDR10
# metadata. No tool reads the RPU or HDR10+ back from an AV1 stream:
# profile_checks finds them on the output's first frame.
encode_mux() {
    hdr_colour_mkv
    mux_parts "AV1 10-bit HDR10 · CRF $SELECTED_CRF${DV_PROFILE:+ · Dolby Vision $DV_TARGET}${HAS_HDR10PLUS:+ · HDR10+}" "${COLOUR_MKV[@]}"
}
