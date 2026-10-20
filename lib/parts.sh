# Section 4 in parts: the video as a raw stream from the profile's encoder
# (lib/encoder-*.sh) and the stereo track as a file of its own, then one
# mkvmerge mux with the source's audio, subtitles, chapters and
# attachments. Every entry script encodes this way (farm.sh with the
# video in chunks). Sourced before the profile.

# After prepare_output: sets PARTS, the intermediates' directory beside the
# output, and in it VIDEO_STREAM, STEREO_MKA and PARTIAL_FILE; checks the
# free space there; runs encoder_prepare.
prepare_parts() {
    # Intermediates live next to the output, on the filesystem whose free space
    # is checked below, not in WORK (which may be a small /tmp).
    PARTS="${OUTPUT%.mkv}.partial"
    VIDEO_STREAM="$PARTS/video.$VIDEO_EXT"
    STEREO_MKA="$PARTS/stereo.mka"
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

    encoder_prepare
    return 0
}

# The stereo track, from the whole film's original audio.
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

# `encode_video [encoder options…]`: the video into VIDEO_STREAM, ffmpeg
# decoding into the encoder's ENCODE (encoder_command) with the profile's
# own options.
encode_video() {
    heading "Video"
    # passthrough: y4m is constant rate, and on millisecond Matroska timestamps
    # ffmpeg would duplicate frames to keep it, putting a Dolby Vision RPU out
    # of step.
    DECODE_ARGS=(-i "$INPUT" -map 0:"$V" "${VF[@]}" -fps_mode passthrough -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe -)
    encoder_command "$VIDEO_STREAM" "" "" "" "$@"
    if [[ -n $DRY_RUN ]]; then
        printf '\n  %s$%s' "$CYAN" "$RESET"
        printf ' %q' ffmpeg -nostdin -hide_banner -v error -stats "${DECODE_ARGS[@]}"
        printf ' \\\n    |'
        printf ' %q' "${ENCODE[@]}"
        printf '\n'
    else
        # shellcheck disable=SC2329 # run through background, below
        video_pipe() {
            # ffmpeg's stdout carries the pictures, so its progress goes to fd 3;
            # render_progress draws on fd 4, the terminal, as its inherited stdout
            # is that same pipe into the encoder.
            { ffmpeg -nostdin -hide_banner -v error -nostats -progress pipe:3 "${DECODE_ARGS[@]}" 3> >(render_progress >&4) |
                "${ENCODE[@]}"; } 4>&1
            # Lets the progress line finish drawing; whether $! names the process
            # substitution depends on the bash version, so a failed wait is fine.
            wait $! 2>/dev/null || true
        }
        [[ -t 1 ]] && printf '  %sCtrl+Z pauses (fg resumes) · Ctrl+C aborts%s\n' "$DIM" "$RESET"
        ENCODE_START=$SECONDS
        PROGRESS_SIZE_FILE=$VIDEO_STREAM
        background video_pipe
        ENCODE_SECONDS=$((SECONDS - ENCODE_START))
        unset PROGRESS_SIZE_FILE
    fi
    return 0
}

# `mux_parts <video track name> [mkvmerge colour options…]`: muxes
# VIDEO_STREAM, STEREO_MKA and, from the source, the original audio, every
# subtitle, chapters and attachments, then finalizes and removes PARTS.
# mkvmerge does not derive the Matroska Colour elements from a raw video
# stream: the profile passes them.
mux_parts() {
    local name=$1 s
    shift
    heading "Mux"
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
        --language "0:$V_OUT_LANG" --track-name "0:$name" \
        --default-track-flag 0:yes --default-duration "0:${V_FPS}p" "$@" "$VIDEO_STREAM" \
        --language "0:$A_LANG" --track-name "0:Stereo · AAC $STEREO_BITRATE" --default-track-flag 0:yes \
        --no-chapters --no-global-tags --no-track-tags "$STEREO_MKA" \
        "${SOURCE_OPTS[@]}" "$INPUT" || [[ $? == 1 ]]

    finalize_output
    rm -rf "$PARTS"
    return 0
}
