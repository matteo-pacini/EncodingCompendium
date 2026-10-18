# Source probing and the section 1 report: container, video, black bars,
# audio, subtitles, chapters and the collected WARNINGS. Sourced by the
# hevc-*.sh entry scripts.

load_probe() {
    PROBE=$(ffprobe -v error -show_format -show_streams -show_chapters -of json "$INPUT")
    DURATION=$(probe .format.duration)
    WARNINGS=()
}

# Reads a field from the ffprobe JSON.
probe() { jq -r "$1 // empty" <<<"$PROBE"; }

# Per-stream bitrate: mkvmerge's BPS statistics tag first, as Matroska
# streams rarely carry a bit_rate of their own.
stream_bps() { probe ".streams[$1] | (.tags.BPS // .bit_rate)"; }

stream_desc() {
    local i=$1
    local lang title flags
    lang=$(probe ".streams[$i].tags.language")
    title=$(probe ".streams[$i].tags.title")
    flags=$(probe "[.streams[$i].disposition | to_entries[] | select(.value == 1 and (.key | IN(\"default\", \"forced\", \"hearing_impaired\", \"comment\"))) | .key] | join(\", \")")
    printf '%s%s%s' "${lang:-und}" "${title:+  “$title”}" "${flags:+  ${YELLOW}[$flags]${RESET}}"
}

report_container() {
    heading "Container"
    kv "Format"        "$(probe .format.format_long_name)"
    kv "Size"          "$(human_bytes "$(probe .format.size)")"
    kv "Duration"      "$(hms "$DURATION")"
    kv "Overall rate"  "$(kbps "$(probe .format.bit_rate)")"
    kv "Muxed by"      "$(probe '.streams[0].tags._STATISTICS_WRITING_APP // .format.tags.encoder')"
    kv "Chapters"      "$(probe '.chapters | length')"
}

# Picks the main video stream (cover art excluded) into V and its V_*
# properties, FPS as a number, and V_IS_HDR; then reports it.
report_video() {
    V=$(probe '[.streams[] | .codec_type == "video" and .disposition.attached_pic == 0] | index(true)')
    [[ -n $V ]] || die "No video stream found"

    V_WIDTH=$(probe ".streams[$V].width")
    V_HEIGHT=$(probe ".streams[$V].height")
    V_FPS=$(probe ".streams[$V].avg_frame_rate")
    [[ $V_FPS == 0/0 || -z $V_FPS ]] && V_FPS=$(probe ".streams[$V].r_frame_rate")
    [[ $V_FPS == 0/0 || -z $V_FPS ]] && die "Cannot determine the video frame rate"
    FPS=$(awk -v f="$V_FPS" 'BEGIN { split(f, p, "/"); print p[1] / p[2] }')
    V_PIXFMT=$(probe ".streams[$V].pix_fmt")
    V_DEPTH=$(probe ".streams[$V].bits_per_raw_sample")
    # HEVC streams carry no bits_per_raw_sample; the pixel format names it.
    [[ -z $V_DEPTH && $V_PIXFMT =~ p([0-9]+)(le|be)$ ]] && V_DEPTH=${BASH_REMATCH[1]}
    V_PRIMARIES=$(probe ".streams[$V].color_primaries")
    V_TRANSFER=$(probe ".streams[$V].color_transfer")
    V_MATRIX=$(probe ".streams[$V].color_space")
    V_RANGE=$(probe ".streams[$V].color_range")
    V_CHROMALOC=$(probe ".streams[$V].chroma_location")
    V_FRAMES=$(probe ".streams[$V].tags.NUMBER_OF_FRAMES // .streams[$V].nb_frames")
    V_CODEC=$(probe ".streams[$V].codec_name")
    # ffprobe reports H.264 levels ×10 and HEVC levels ×30; -99 means unknown.
    V_LEVEL=$(probe ".streams[$V].level" | awk -v c="$V_CODEC" '$1 > 0 { printf "@L%.1f", $1 / (c == "hevc" ? 30 : 10) }')
    V_HDR=$(probe "[.streams[$V].side_data_list[]? | .side_data_type] | map(select(test(\"Mastering|Light level|DOVI\"))) | join(\", \")")
    V_IS_HDR=""
    [[ -n $V_HDR || $V_TRANSFER == smpte2084 || $V_TRANSFER == arib-std-b67 ]] && V_IS_HDR=1

    heading "Video  ${DIM}#$V${RESET}"
    kv "Codec"         "${V_CODEC^^} · $(probe ".streams[$V].profile")$V_LEVEL"
    kv "Resolution"    "${V_WIDTH}×${V_HEIGHT}  (DAR $(probe ".streams[$V].display_aspect_ratio"), SAR $(probe ".streams[$V].sample_aspect_ratio"))"
    kv "Frame rate"    "$(awk -v f="$V_FPS" 'BEGIN { split(f, p, "/"); printf "%.3f", p[1] / p[2] }') fps ($V_FPS)$(probe ".streams[$V].field_order" | sed 's/^/ · /')"
    kv "Frames"        "${V_FRAMES:-unknown}"
    kv "Pixel format"  "$V_PIXFMT · ${V_DEPTH:-?}-bit · chroma loc ${V_CHROMALOC:-unspecified}"
    # Primaries, transfer, matrix, range.
    kv "Colour"        "${V_PRIMARIES:-untagged} · ${V_TRANSFER:-untagged} · ${V_MATRIX:-untagged} · ${V_RANGE:-untagged}"
    local hdr=${V_HDR:-none (SDR)}
    # Some remuxes carry HDR10 metadata only in the frames, not the stream.
    [[ -z $V_HDR && -n $V_IS_HDR ]] && hdr="none at stream level · $V_TRANSFER"
    kv "HDR metadata"  "$hdr"
    kv "Bitrate"       "$(kbps "$(stream_bps "$V")")"
    kv "Track"         "$(stream_desc "$V")"
}

# Takes `crop_round <samples> <offset>`: one crop vote per sample, spread
# over 5%–95% of the runtime and shifted by <offset> of a step. A vote comes
# from the entry script's `crop_hint <seconds>` when it defines one and
# prints a crop for that point, otherwise from cropdetect.
crop_round() {
    local count=$1 offset=$2 n at c
    for ((n = 0; n < count; n++)); do
        at=$(awk -v d="$DURATION" -v n="$n" -v t="$count" -v o="$offset" 'BEGIN { printf "%.0f", d * (0.05 + 0.90 * (n + o) / (o > 0 ? t : t - 1)) }')
        progress "Detecting black bars… sample $((CROP_SAMPLES + 1)) at $(hms "$at")"
        c=""
        declare -F crop_hint >/dev/null && c=$(crop_hint "$at")
        if [[ -n $c ]]; then
            CROP_HINTED=$((CROP_HINTED + 1))
        else
            # On black frames cropdetect reports negative sizes; the full
            # pattern skips them.
            c=$(ffmpeg -nostdin -hide_banner -nostats -ss "$at" -i "$INPUT" -t 2 -map 0:"$V" \
                -vf cropdetect=round=2:reset=0 -f null - 2>&1 | grep -oE 'crop=[0-9]+:[0-9]+:[0-9]+:[0-9]+' | tail -1 || true)
        fi
        CROP_SAMPLES=$((CROP_SAMPLES + 1))
        [[ -n $c ]] && CROP_VOTES[$c]=$(( ${CROP_VOTES[$c]:-0} + 1 ))
    done
    progress ""
}

crop_area() { local w h; IFS=: read -r w h _ _ <<<"${1#crop=}"; echo $((w * h)); }
crop_aspect() { local w h; IFS=: read -r w h _ _ <<<"${1#crop=}"; awk -v w="$w" -v h="$h" 'BEGIN { printf "%.2f:1", w / h }'; }

# Votes on the active picture into CROP (empty when there are no bars) and
# CROP_W/H/X/Y, then reports them. Ten samples; when they disagree, twenty
# more decide whether the film really changes aspect ratio or a few frames
# fooled cropdetect.
detect_crop() {
    local c voted=0 dominant="" largest="" majors=() shares="" s
    CROP_SAMPLES=0 CROP_HINTED=0
    declare -gA CROP_VOTES=()
    crop_round 10 0
    (( ${#CROP_VOTES[@]} > 1 )) && crop_round 20 0.5

    for c in "${!CROP_VOTES[@]}"; do
        voted=$((voted + CROP_VOTES[$c]))
        [[ -z $dominant ]] || (( CROP_VOTES[$c] > CROP_VOTES[$dominant] )) && dominant=$c
        [[ -z $largest ]] || (( $(crop_area "$c") > $(crop_area "$largest") )) && largest=$c
    done
    # Whatever the verdict, the largest picture wins: a smaller crop would cut
    # picture somewhere, a larger one only keeps a few black lines.
    CROP=${largest:-crop=${V_WIDTH}:${V_HEIGHT}:0:0}
    (( voted < CROP_SAMPLES )) && WARNINGS+=("Black bar detection failed on $((CROP_SAMPLES - voted))/$CROP_SAMPLES samples.")
    IFS=: read -r CROP_W CROP_H CROP_X CROP_Y <<<"${CROP#crop=}"

    heading "Black bars"
    for c in $(for c in "${!CROP_VOTES[@]}"; do echo "${CROP_VOTES[$c]} $c"; done | sort -rn | cut -d' ' -f2); do
        kv "$c" "${CROP_VOTES[$c]}/$CROP_SAMPLES samples · $(crop_aspect "$c")"
        # A crop holding at least 15% of the samples is a real framing, not a stray.
        (( CROP_VOTES[$c] * 100 >= CROP_SAMPLES * 15 )) && majors+=("$c")
    done
    (( CROP_HINTED == 0 )) || kv "Source" "Dolby Vision L5 active area on $CROP_HINTED/$CROP_SAMPLES samples, cropdetect on the rest"

    if (( ${#CROP_VOTES[@]} > 1 )); then
        if (( ${#majors[@]} > 1 )); then
            for c in "${majors[@]}"; do
                shares+="${shares:+ and }$(crop_aspect "$c") in ${CROP_VOTES[$c]}/$CROP_SAMPLES"
            done
            WARNINGS+=("Variable aspect ratio ($shares samples): keeping the largest picture, so the narrower scenes keep their bars.")
            ok "Variable aspect ratio — keeping the largest picture"
        elif [[ $largest != "$dominant" ]]; then
            ok "Stray detections: one is larger than the dominant $(crop_aspect "$dominant"), so keeping it (never cut picture)"
        else
            ok "Stray detections ignored (dark or fading frames)"
        fi
    fi
    if [[ $CROP_W == "$V_WIDTH" && $CROP_H == "$V_HEIGHT" ]]; then
        ok "No black bars to remove"
        CROP=""
    else
        ok "Active picture ${CROP_W}×${CROP_H} ($(crop_aspect "$CROP"))"
    fi
    # Time to read the verdict before the next sections scroll it away.
    if [[ -t 1 ]]; then
        for ((s = 5; s > 0; s--)); do
            progress "Continuing in $s s…"
            sleep 1
        done
        progress ""
    fi
}

# Lists the audio tracks into AUDIO_STREAMS and picks the primary one into A
# and its A_* properties.
report_audio() {
    local a
    mapfile -t AUDIO_STREAMS < <(probe '.streams[] | select(.codec_type == "audio") | .index')
    (( ${#AUDIO_STREAMS[@]} > 0 )) || die "No audio stream found"

    heading "Audio  ${DIM}${#AUDIO_STREAMS[@]} track(s)${RESET}"
    for a in "${AUDIO_STREAMS[@]}"; do
        item "#$a  $(probe ".streams[$a].codec_name" | tr '[:lower:]' '[:upper:]')$(probe ".streams[$a].profile" | sed 's/^/ · /')"
        setting "Channels" "$(probe ".streams[$a].channels") · $(probe ".streams[$a].channel_layout")"
        setting "Sample" "$(probe ".streams[$a].sample_rate") Hz · $(probe ".streams[$a].bits_per_raw_sample // \"?\"")-bit"
        setting "Bitrate" "$(kbps "$(stream_bps "$a")")"
        setting "Track" "$(stream_desc "$a")"
    done

    # The default-flagged track is the one the disc author meant as primary.
    A=$(probe '[.streams[] | select(.codec_type == "audio" and .disposition.default == 1) | .index] | first')
    A=${A:-${AUDIO_STREAMS[0]}}
    A_LAYOUT=$(probe ".streams[$A].channel_layout")
    A_CHANNELS=$(probe ".streams[$A].channels")
    A_LANG=$(probe ".streams[$A].tags.language")
    A_LANG=${A_LANG:-und}
}

# Lists subtitle tracks into SUB_STREAMS and attached pictures (cover art)
# into COVER_STREAMS; decides FIX_V_LANG.
report_subtitles() {
    local s
    mapfile -t SUB_STREAMS < <(probe '.streams[] | select(.codec_type == "subtitle") | .index')
    mapfile -t COVER_STREAMS < <(probe '.streams[] | select(.disposition.attached_pic == 1) | .index')

    heading "Subtitles  ${DIM}${#SUB_STREAMS[@]} track(s)${RESET}"
    if (( ${#SUB_STREAMS[@]} == 0 )); then
        warn "None"
    fi
    for s in "${SUB_STREAMS[@]}"; do
        item "#$s  $(probe ".streams[$s].codec_name")"
        setting "Events" "$(probe ".streams[$s].tags.NUMBER_OF_FRAMES // \"unknown\"")"
        setting "Track" "$(stream_desc "$s")"
    done

    if [[ -z $(probe '.streams[] | select(.codec_type == "subtitle" and .tags.language == "eng") | .index') ]]; then
        WARNINGS+=("No English subtitles in the source.")
    fi
    V_LANG=$(probe ".streams[$V].tags.language")
    FIX_V_LANG=""
    if [[ -n $V_LANG && $V_LANG != "$A_LANG" && $V_LANG != und && $A_LANG != und ]]; then
        FIX_V_LANG=$A_LANG
        WARNINGS+=("Video tagged '$V_LANG', main audio '$A_LANG': video set to '$A_LANG'.")
    fi
}

report_chapters() {
    heading "Chapters"
    [[ $(probe '.chapters | length') == 0 ]] && warn "None"
    probe '.chapters[] | "\(.start_time) \(.tags.title // "")"' | while read -r start title; do
        kv "$(hms "$start")" "$title"
    done
}

report_observations() {
    local w
    heading "Observations"
    if (( ${#WARNINGS[@]} == 0 )); then
        ok "Nothing unusual"
    fi
    for w in "${WARNINGS[@]}"; do
        warn "$w"
    done
}
