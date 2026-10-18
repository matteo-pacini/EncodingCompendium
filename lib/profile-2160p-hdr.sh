# The 2160p HDR profile: UHD Blu-ray remux (HDR10, optionally Dolby Vision)
# to HEVC Main10 HDR10, plus Dolby Vision 8.1, for the Shield on an LG CX.
# Sourced by hevc-2160p-hdr.sh after the other lib/ files; each function
# is one section's profile-specific part.

PROFILE_TARGET="NVIDIA Shield TV Pro + LG CX direct play"

# PRESETS, sampling and VMAF defaults, before section 0.
profile_defaults() {
    PRESETS=${PRESETS:-slow:16,17,18,19,20}
    SAMPLE_PERCENT=${SAMPLE_PERCENT:-1.5}
    SAMPLE_DURATION=${SAMPLE_DURATION:-12}

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
    require_x265_cli
    require_tool sha256sum --version
    require_tool pgrep -V
    if command -v ffmpeg >/dev/null; then
        require_ffmpeg_filters libvmaf xpsnr cropdetect ebur128 setparams pan crop
        require_ffmpeg_encoders libx265 aac
        require_x265_main10
        require_vmaf "$VMAF_OPTIONS"
    fi
    return 0
}

# Reads the HDR signalling: static HDR10 metadata and HDR10+ from the first
# frame, Dolby Vision from the stream's configuration record. Sets
# MASTER_DISPLAY and MAX_CLL in x265's syntax, HAS_HDR10PLUS, and DV_PROFILE,
# DV_EL, DV_COMPAT (empty without Dolby Vision).
read_hdr() {
    local frame
    frame=$(ffprobe -v error -select_streams "$V" -read_intervals "%+#1" -show_frames \
        -show_entries frame=side_data_list -of json "$INPUT")
    # x265 wants chromaticities in 1/50000 and luminance in 1/10000 cd/m²;
    # ffprobe prints them as fractions, which may be reduced.
    MASTER_DISPLAY=$(jq -r '
        def u(scale): split("/") | (.[0] | tonumber) * scale / (.[1] | tonumber) | round;
        [.frames[0].side_data_list[]? | select(.side_data_type == "Mastering display metadata")][0] // empty
        | "G(\(.green_x | u(50000)),\(.green_y | u(50000)))B(\(.blue_x | u(50000)),\(.blue_y | u(50000)))"
          + "R(\(.red_x | u(50000)),\(.red_y | u(50000)))WP(\(.white_point_x | u(50000)),\(.white_point_y | u(50000)))"
          + "L(\(.max_luminance | u(10000)),\(.min_luminance | u(10000)))"' <<<"$frame")
    MAX_CLL=$(jq -r '[.frames[0].side_data_list[]? | select(.side_data_type == "Content light level metadata")][0] // empty
        | "\(.max_content),\(.max_average)"' <<<"$frame")
    HAS_HDR10PLUS=$(jq -r 'if any(.frames[0].side_data_list[]?; .side_data_type | test("2094-40")) then 1 else empty end' <<<"$frame")
    DV_PROFILE=$(probe "[.streams[$V].side_data_list[]? | select(.side_data_type == \"DOVI configuration record\")][0].dv_profile")
    DV_EL=$(probe "[.streams[$V].side_data_list[]? | select(.side_data_type == \"DOVI configuration record\")][0].el_present_flag")
    DV_COMPAT=$(probe "[.streams[$V].side_data_list[]? | select(.side_data_type == \"DOVI configuration record\")][0].dv_bl_signal_compatibility_id")
    DV_LAYERS="BL+RPU"
    [[ $DV_EL == 1 ]] && DV_LAYERS="BL+EL+RPU (dual layer)"
    return 0
}

report_hdr() {
    local max_nits min_nits
    heading "HDR"
    if [[ -n $MASTER_DISPLAY ]]; then
        max_nits=$(sed -E 's/.*L\(([0-9]+),.*/\1/' <<<"$MASTER_DISPLAY")
        min_nits=$(sed -E 's/.*L\([0-9]+,([0-9]+)\).*/\1/' <<<"$MASTER_DISPLAY")
        kv "Mastering display" "$(awk -v a="$max_nits" -v b="$min_nits" 'BEGIN { printf "%g–%g nits", b / 10000, a / 10000 }') · $MASTER_DISPLAY"
    else
        kv "Mastering display" "none"
    fi
    if [[ -n $MAX_CLL ]]; then
        kv "Light level" "MaxCLL ${MAX_CLL%,*} · MaxFALL ${MAX_CLL#*,} nits"
    else
        kv "Light level" "none"
    fi
    if [[ -n $DV_PROFILE ]]; then
        kv "Dolby Vision" "profile $DV_PROFILE · $DV_LAYERS · compatibility ID $DV_COMPAT"
    else
        kv "Dolby Vision" "none"
    fi
    if [[ -n $HAS_HDR10PLUS ]]; then
        kv "HDR10+" "present"
    else
        kv "HDR10+" "none"
    fi
}

# Dolby Vision's L5 metadata is the disc author's own active area for the
# shot: when a sample's RPU carries it, it outranks cropdetect.
crop_hint() {
    local offsets top bottom left right
    [[ -n $DV_PROFILE ]] || return 0
    ffmpeg -nostdin -v error -ss "$1" -i "$INPUT" -t 2 -map 0:"$V" -c copy -bsf:v hevc_mp4toannexb -f hevc - 2>/dev/null |
        dovi_tool extract-rpu - -o "$WORK/hint.rpu" >/dev/null 2>&1 || return 0
    offsets=$(dovi_tool info -i "$WORK/hint.rpu" --summary 2>/dev/null |
        sed -n 's/.*L5 offsets: top=\([0-9]*\), bottom=\([0-9]*\), left=\([0-9]*\), right=\([0-9]*\)$/\1 \2 \3 \4/p')
    [[ -n $offsets ]] || return 0
    read -r top bottom left right <<<"$offsets"
    echo "crop=$((V_WIDTH - left - right)):$((V_HEIGHT - top - bottom)):$left:$top"
}

# Section 1 after load_probe: reports the source and its HDR signalling,
# and stops on one this profile cannot convert.
profile_analysis() {
    report_container
    report_video
    read_hdr
    report_hdr

    detect_crop
    report_audio
    report_subtitles
    report_chapters

    [[ -n $HAS_HDR10PLUS ]] && WARNINGS+=("HDR10+ is dropped: neither the Shield nor the LG CX supports it, and an HDR10+-only file would make Jellyfin transcode.")
    [[ $DV_EL == 1 ]] && WARNINGS+=("Dual-layer Dolby Vision (profile $DV_PROFILE): the enhancement layer is discarded when converting to profile 8.1 — usually invisible, but a full enhancement layer (FEL) can carry real picture data.")
    [[ -n $DV_PROFILE && -z $MASTER_DISPLAY ]] && WARNINGS+=("Dolby Vision without mastering display metadata: x265 needs it for profile 8.1.")
    [[ -z $DV_PROFILE && -z $MASTER_DISPLAY ]] && WARNINGS+=("No mastering display metadata: the HDR10 encode will carry none either.")
    report_observations

    [[ $V_TRANSFER == arib-std-b67 ]] && die "HLG source — this script only handles PQ (HDR10 / Dolby Vision)"
    [[ $V_TRANSFER == smpte2084 ]] || die "SDR source — use hevc-1080p-sdr.sh"
    (( V_HEIGHT > 1080 )) || die "Source is ${V_HEIGHT}p — this script handles 2160p; use hevc-1080p-sdr.sh"
    [[ $DV_PROFILE == 5 ]] && die "Dolby Vision profile 5 has no HDR10 base layer to re-encode"
    [[ -n $DV_PROFILE && -z $MASTER_DISPLAY ]] && die "Dolby Vision 8.1 needs mastering display metadata, and the source has none"
    return 0
}

# HDR10+ does not survive the encode, so the name must not promise it.
rename_stem() { sed -E 's/HDR10(Plus|\+)/HDR10/g' <<<"$1"; }

# Section 2: the x265 settings, Dolby Vision plan, audio and container
# plans, gates and the encode and scoring filters.
profile_settings() {
    #################
    # x265 settings #
    #################

    # PRESETS defaults to CRF 16–20: HDR needs a lower CRF than SDR for the same
    # look (doom9: about 2 lower with hdr10-opt).
    # Level 5.1 High tier, which the Shield's decoder advertises; Jellyfin
    # transcodes anything above the advertised level. The VBV keeps peaks within
    # the level's 160 Mb/s, and Dolby Vision requires a VBV anyway.
    LEVEL="level-idc=51:high-tier=1:vbv-maxrate=160000:vbv-bufsize=160000"
    # x265's chromaloc numbering for ffprobe's chroma_location names.
    case $V_CHROMALOC in
        left) CHROMALOC=0 ;; center) CHROMALOC=1 ;; topleft) CHROMALOC=2 ;;
        top) CHROMALOC=3 ;; bottomleft) CHROMALOC=4 ;; bottom) CHROMALOC=5 ;;
        *) CHROMALOC=2 ;;
    esac
    COLOUR="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:chromaloc=$CHROMALOC"
    # Static HDR10 metadata copied from the source; hdr10-opt adapts the block
    # QPs to PQ.
    HDR="hdr10=1:hdr10-opt=1:repeat-headers=1${MASTER_DISPLAY:+:master-display=$MASTER_DISPLAY}${MAX_CLL:+:max-cll=$MAX_CLL}"
    AQ="aq-mode=3:aq-strength=0.8"
    # x265's default from preset slow up; pinned so faster presets keep grain.
    PSY="psy-rdoq=1.0"
    DETAIL="no-sao=1:no-strong-intra-smoothing=1:deblock=-2,-2"
    RC="qcomp=0.7:rc-lookahead=60:bframes=8:ref=5"
    GOP="keyint=240:min-keyint=24"
    # x265 only uses its AVX-512 kernels when asked; without AVX-512 it warns and
    # falls back to what it detects.
    ASM="asm=avx512"
    X265_PARAMS="$COLOUR:$HDR:$LEVEL:$AQ:$PSY:$DETAIL:$RC:$GOP:$ASM"
    # x265-params only writes the HEVC VUI; these set the Matroska Colour elements.
    COLOUR_FLAGS=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv -chroma_sample_location "${V_CHROMALOC:-topleft}")

    # Dolby Vision: the source RPU, converted to profile 8.1 (-m 2 removes the
    # dual-layer mapping) and, after a crop, with zeroed letterbox offsets (L5).
    DOVI_EXTRACT=(dovi_tool -m 2 ${CROP:+--crop} extract-rpu)

    heading "Video  ${DIM}#$V → HEVC Main10 HDR10${DV_PROFILE:+ + Dolby Vision 8.1}${RESET}"
    item "libx265 · preset and CRF picked in section 3 · yuv420p10le"
    setting "Level / VBV" "$LEVEL"
    setting "Colour" "$COLOUR"
    setting "HDR10" "$HDR"
    setting "Adaptive quant." "$AQ"
    setting "Psycho-visual" "$PSY"
    setting "Detail" "$DETAIL"
    setting "Rate control" "$RC"
    setting "GOP" "$GOP"
    setting "Assembly" "$ASM"
    if [[ -n $CROP ]]; then
        setting "Crop" "$CROP"
    fi
    if [[ -n $DV_PROFILE ]]; then
        item "Dolby Vision profile $DV_PROFILE → 8.1 (BL = HDR10, compatibility ID 1)"
        setting "RPU" "${DOVI_EXTRACT[*]}"
        setting "Injection" "ffmpeg (decode${CROP:+, crop}) | x265 CLI --dolby-vision-profile 8.1"
        setting "Mux" "mkvmerge (writes the Dolby Vision configuration)"
    fi
    [[ -n $HAS_HDR10PLUS ]] && item "HDR10+ dropped"

    plan_audio
    ORIGINAL_MEDIA_TYPE="Ultra HD Blu-ray"
    plan_container

    EXTRA_TAGS=(
        "HDR_FORMAT=${DV_PROFILE:+Dolby Vision 8.1 + }HDR10"
        "HDR_MASTERING_DISPLAY=${MASTER_DISPLAY:-none}"
        "HDR_MAX_CLL=${MAX_CLL:-none}"
    )
    [[ -n $DV_PROFILE ]] && EXTRA_TAGS+=(
        "DOVI_SOURCE_PROFILE=$DV_PROFILE $DV_LAYERS"
        "DOVI_CONVERSION=${DOVI_EXTRACT[*]}"
    )

    ###########################
    # Calibration and scoring #
    ###########################

    VMAF_TARGET_MEAN=95
    VMAF_TARGET_LOW=90
    # Worst half second, as at 1080p: on a test film, eotf=pq scored within
    # ~30% of eotf=bt1886, so the same limit applies.
    CAMBI_MAX=2.5
    # A CRF step costing this many times the previous step's XPSNR is a knee.
    KNEE_RATIO=1.5
    # Fewer, shorter samples than at 1080p: each 2160p frame costs about 4×.
    CALIBRATION_SAMPLES=$(sample_count)

    plan_gates

    # Restating the PQ tags (already on a well-formed source) keeps the encode
    # and both scoring inputs identically tagged, so ffmpeg never colour-converts
    # one of them; a mistagged remux gets the tags its transfer check promised.
    TAG_PQ="setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv"
    VF=(-vf "${CROP:+$CROP,}$TAG_PQ")
    # libvmaf pairs frames by timestamp, and the millisecond Matroska timestamps
    # of source and encode round differently. Renumbering both from the frame
    # index makes the pairing exact.
    RETIME="settb=AVTB,setpts=N/FRAME_RATE/TB"
    REF_FILTER="${CROP:+$CROP,}$TAG_PQ,$RETIME,format=yuv420p10le"
    DIST_FILTER="$TAG_PQ,$RETIME,format=yuv420p10le"
    return 0
}

# Calibration encodes without Dolby Vision: the RPU does not change the
# pictures the metrics compare, so libx265 through ffmpeg is enough.
encode_sample() {
    ffmpeg -nostdin -v error "${@:5}" -y -i "$3" -map 0:v:0 "${VF[@]}" -c:v libx265 -preset "$1" -crf "$2" \
        -pix_fmt yuv420p10le -profile:v main10 "${COLOUR_FLAGS[@]}" -x265-params "$X265_PARAMS:log-level=error" "$4"
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

# Frame count of an RPU file.
rpu_frames() { dovi_tool info -i "$1" --summary 2>/dev/null | awk '$1 == "Frames:" { print $2 }'; }

# Section 4, first: the intermediates' directory and its free space, the
# x265 CLI options and, with Dolby Vision, the source RPU.
encode_prepare() {
    prepare_output
    # Intermediates live next to the output, on the filesystem whose free space
    # is checked below, not in WORK (which may be a small /tmp).
    PARTS="${OUTPUT%.mkv}.partial"
    VIDEO_HEVC="$PARTS/video.hevc"
    STEREO_MKA="$PARTS/stereo.mka"
    RPU="$PARTS/rpu.bin"
    PARTIAL_FILE="$PARTS/muxed.mkv"
    if [[ -z $DRY_RUN ]]; then
        mkdir -p "$PARTS"
        PARTIAL=$PARTS
    fi

    # The raw video and the muxed file coexist until the end.
    NEED_BYTES=$(awk -v s="$SELECTED_SIZE" 'BEGIN { printf "%.0f", s * 2.2 }')
    FREE_BYTES=$(df --output=avail -B1 "$(dirname "$OUTPUT")" | tail -1)
    if (( FREE_BYTES < NEED_BYTES )); then
        [[ -n $DRY_RUN ]] || die "Needs ≈ $(human_bytes "$NEED_BYTES") free next to the output, $(human_bytes "$FREE_BYTES") available"
        warn "Needs ≈ $(human_bytes "$NEED_BYTES") free next to the output, $(human_bytes "$FREE_BYTES") available"
    fi

    mapfile -t X265_CLI < <(x265_cli_args)
    DV_ARGS=()
    [[ -n $DV_PROFILE ]] && DV_ARGS=(--dolby-vision-profile 8.1 --dolby-vision-rpu "$RPU")

    if [[ -n $DV_PROFILE ]]; then
        heading "Dolby Vision RPU"
        run "${DOVI_EXTRACT[@]}" -i "$INPUT" -o "$RPU"
        if [[ -z $DRY_RUN ]]; then
            SOURCE_RPU_FRAMES=$(rpu_frames "$RPU")
            # x265 only warns when RPU and frame counts differ, and then writes
            # garbage metadata for the frames that are off.
            check_near "RPU frames ($SOURCE_RPU_FRAMES)" "$TOTAL_FRAMES" "$SOURCE_RPU_FRAMES" 2
            awk -v e="$TOTAL_FRAMES" -v a="$SOURCE_RPU_FRAMES" 'BEGIN { d = e - a; exit !((d < 0 ? -d : d) <= 2) }' ||
                die "The RPU does not match the video's frame count"
        fi
    fi
    return 0
}

# Section 4: the stereo track, from the whole film's original audio.
encode_stereo() {
    heading "Stereo track"
    STEREO_ARGS=(-y -i "$INPUT" -map 0:"$A" -vn -af "$STEREO_FILTER" -c:a aac -b:a "$STEREO_BITRATE" "$STEREO_MKA")
    if [[ -n $DRY_RUN ]]; then
        run ffmpeg -nostdin -hide_banner -v error "${STEREO_ARGS[@]}"
    else
        STEP_NAMES=("encode")
        BLOCK_CRF=""
        begin_sample "AAC $STEREO_BITRATE · $(hms "$DURATION")"
        run_time_step 0 "$DURATION" ffmpeg -nostdin -hide_banner -v error -nostats -progress pipe:1 "${STEREO_ARGS[@]}"
        clear_block
        ok "$(human_bytes "$(stat -c %s "$STEREO_MKA")")"
    fi
    return 0
}

# Section 4: the video, ffmpeg decoding into the x265 CLI.
encode_video() {
    heading "Video"
    # passthrough: y4m is constant rate, and on millisecond Matroska timestamps
    # ffmpeg would duplicate frames to keep it, putting the RPU out of step.
    DECODE_ARGS=(-i "$INPUT" -map 0:"$V" "${VF[@]}" -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe -)
    ENCODE=(x265 --input - --y4m --preset "$PRESET" --crf "$SELECTED_CRF" --output-depth 10 --profile main10
        "${X265_CLI[@]}" "${DV_ARGS[@]}" --log-level error --no-progress -o "$VIDEO_HEVC")
    if [[ -n $DRY_RUN ]]; then
        printf '\n  %s$%s' "$CYAN" "$RESET"
        printf ' %q' ffmpeg -nostdin -hide_banner -v error -stats "${DECODE_ARGS[@]}"
        printf ' \\\n    |'
        printf ' %q' "${ENCODE[@]}"
        printf '\n'
    else
        video_pipe() {
            # ffmpeg's stdout carries the pictures, so its progress goes to fd 3;
            # render_progress draws on fd 4, the terminal, as its inherited stdout
            # is that same pipe into x265.
            { ffmpeg -nostdin -hide_banner -v error -nostats -progress pipe:3 "${DECODE_ARGS[@]}" 3> >(render_progress >&4) |
                "${ENCODE[@]}"; } 4>&1
            # Lets the progress line finish drawing; whether $! names the process
            # substitution depends on the bash version, so a failed wait is fine.
            wait $! 2>/dev/null || true
        }
        [[ -t 1 ]] && printf '  %sCtrl+Z pauses (fg resumes) · Ctrl+C aborts%s\n' "$DIM" "$RESET"
        ENCODE_START=$SECONDS
        PROGRESS_SIZE_FILE=$VIDEO_HEVC
        background video_pipe
        ENCODE_SECONDS=$((SECONDS - ENCODE_START))
        unset PROGRESS_SIZE_FILE
    fi
    return 0
}

# Section 4, last: checks the encoded RPU, muxes and finalizes.
encode_mux() {
    if [[ -n $DV_PROFILE && -z $DRY_RUN ]]; then
        dovi_tool extract-rpu -i "$VIDEO_HEVC" -o "$PARTS/encoded-rpu.bin" >/dev/null
        check "Dolby Vision RPU in the encode" "$SOURCE_RPU_FRAMES" "$(rpu_frames "$PARTS/encoded-rpu.bin")"
    fi

    heading "Mux"
    # Matroska colour elements: mkvmerge does not derive them from a raw HEVC
    # stream. Numbers per ITU-T H.273; chroma siting per Matroska
    # (1 = collocated, 2 = half).
    case $V_CHROMALOC in
        topleft) SITING=1,1 ;; left) SITING=1,2 ;; center) SITING=2,2 ;; top) SITING=2,1 ;; *) SITING=0,0 ;;
    esac
    COLOUR_MKV=(--colour-matrix-coefficients 0:9 --colour-range 0:1 --colour-transfer-characteristics 0:16
        --colour-primaries 0:9 --chroma-siting "0:$SITING")
    if [[ -n $MASTER_DISPLAY ]]; then
        # A here-string ends in a newline; without one read fails, and set -e
        # with it.
        read -r GX GY BX BY RX RY WX WY LMAX LMIN <<<"$(grep -o '[0-9]\+' <<<"$MASTER_DISPLAY" | tr '\n' ' ')"
        COLOUR_MKV+=(
            --chromaticity-coordinates "0:$(awk -v a="$RX" -v b="$RY" -v c="$GX" -v d="$GY" -v e="$BX" -v f="$BY" 'BEGIN { printf "%g,%g,%g,%g,%g,%g", a/50000, b/50000, c/50000, d/50000, e/50000, f/50000 }')"
            --white-colour-coordinates "0:$(awk -v a="$WX" -v b="$WY" 'BEGIN { printf "%g,%g", a/50000, b/50000 }')"
            --max-luminance "0:$(awk -v a="$LMAX" 'BEGIN { printf "%g", a/10000 }')"
            --min-luminance "0:$(awk -v a="$LMIN" 'BEGIN { printf "%g", a/10000 }')"
        )
    fi
    [[ -n $MAX_CLL ]] && COLOUR_MKV+=(--max-content-light "0:${MAX_CLL%,*}" --max-frame-light "0:${MAX_CLL#*,}")

    # From the source: the original audio (not default), every subtitle (default
    # cleared, forced kept by mkvmerge), chapters and attachments (cover art);
    # none of its tags. Track IDs are the source's, as ffprobe numbers them.
    SOURCE_OPTS=(--no-video --no-global-tags --no-track-tags --audio-tracks "$A"
        --language "$A:$A_LANG" --track-name "$A:$A_TITLE" --default-track-flag "$A:no")
    if (( ${#SUB_STREAMS[@]} > 0 )); then
        SOURCE_OPTS+=(--subtitle-tracks "$(IFS=,; echo "${SUB_STREAMS[*]}")")
        for s in "${SUB_STREAMS[@]}"; do SOURCE_OPTS+=(--default-track-flag "$s:no"); done
    else
        SOURCE_OPTS+=(--no-subtitles)
    fi
    # mkvmerge exits 1 for warnings only. The stereo file brings only its
    # audio: ffmpeg copied the source's chapters into it as well.
    run mkvmerge -q -o "$PARTIAL_FILE" --title "$MOVIE_TITLE" \
        --language "0:$V_OUT_LANG" --track-name "0:HEVC Main10 · CRF $SELECTED_CRF${DV_PROFILE:+ · Dolby Vision 8.1}" \
        --default-track-flag 0:yes --default-duration "0:${V_FPS}p" "${COLOUR_MKV[@]}" "$VIDEO_HEVC" \
        --language "0:$A_LANG" --track-name "0:Stereo · AAC $STEREO_BITRATE" --default-track-flag 0:yes \
        --no-chapters --no-global-tags --no-track-tags "$STEREO_MKA" \
        "${SOURCE_OPTS[@]}" "$INPUT" || [[ $? == 1 ]]

    finalize_output
    rm -rf "$PARTS"
    return 0
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
    check "Colour" "bt2020 smpte2084 bt2020nc tv" "$(out_probe '.streams[0] | "\(.color_primaries) \(.color_transfer) \(.color_space) \(.color_range)"')"
    FIRST_FRAME=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_frames -show_entries frame=side_data_list -of json "$OUTPUT")
    check "HDR10 metadata" "yes yes" "$(jq -r '[.frames[0].side_data_list[]?.side_data_type] | "\(if index("Mastering display metadata") then "yes" else "no" end) \(if index("Content light level metadata") then "yes" else "no" end)"' <<<"$FIRST_FRAME")"
    if [[ -n $DV_PROFILE ]]; then
        check "Dolby Vision" "8 1" "$(out_probe '[.streams[0].side_data_list[]? | select(.side_data_type == "DOVI configuration record")][0] | "\(.dv_profile) \(.dv_bl_signal_compatibility_id)"')"
    fi
    return 0
}
