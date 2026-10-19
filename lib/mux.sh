# Output naming, track metadata, global tags, finalising the encoded file
# and the section 5 result checks. Sourced by the hevc-*.sh entry scripts.

RELEASE_GROUP="Zi0P4tch0"
ORIGINAL_MEDIA_TYPE="Blu-ray"

# Sets MOVIE_TITLE, MOVIE_DIR (the film's folder beside INPUT, named after
# MOVIE_TITLE) and OUTPUT in it from INPUT, and prints the section 2
# container plan. An entry script may define `rename_stem <stem>` to rewrite
# further parts of the output name.
plan_container() {
    local stem
    stem=$(basename "${INPUT%.*}")
    # Radarr/Sonarr read "Remux-1080p" as a quality; an encode of one is "Bluray-1080p".
    stem=${stem//Remux/Bluray}
    # A source release group after the last bracket ("…[h265]-Group") gives
    # way to ours.
    [[ $stem =~ ^(.*\])-[^][\ -]+$ ]] && stem=${BASH_REMATCH[1]}
    declare -F rename_stem >/dev/null && stem=$(rename_stem "$stem")
    # "Title (Year)" from Radarr-style names, else the whole name.
    MOVIE_TITLE=$(basename "${INPUT%.*}")
    [[ $MOVIE_TITLE =~ ^(.*\([0-9]{4}\)) ]] && MOVIE_TITLE=${BASH_REMATCH[1]}
    MOVIE_DIR="$(dirname "$INPUT")/$MOVIE_TITLE"
    OUTPUT="$MOVIE_DIR/$stem-$RELEASE_GROUP.mkv"

    heading "Subtitles"
    if (( ${#SUB_STREAMS[@]} == 0 )); then
        item "None to carry over"
    else
        item "All ${#SUB_STREAMS[@]} track(s) copied · default flag cleared"
    fi

    heading "Container & metadata"
    item "Matroska · chapters copied · metadata rebuilt"
    setting "Title" "$MOVIE_TITLE"
    setting "Track tags" "source tags dropped; language + title set per track"
    setting "Global tags" "encoder settings, calibration, source identity"
    setting "Statistics" "regenerated with mkvpropedit"
    (( ${#COVER_STREAMS[@]} == 0 )) || setting "Cover art" "${#COVER_STREAMS[@]} attached picture(s) kept"
    [[ -n $FIX_V_LANG ]] && setting "Video language" "$V_LANG → $FIX_V_LANG"

    kv "Output" "$(basename "$MOVIE_DIR")/$(basename "$OUTPUT")"
}

# Builds TAGS (global Matroska tags) from the calibration result, followed by
# any EXTRA_TAGS from the entry script, and prints the output plan. Exits if
# the output already exists.
plan_output() {
    local r fields tag
    # Calibration results go in their own tags, not COMMENT/DESCRIPTION, which
    # media servers may show as the overview.
    for r in "${ROWS[@]}"; do
        IFS=$'\t' read -r -a fields <<<"$r"
        [[ ${fields[0]} == "$SELECTED_CRF" ]] && break
    done
    TAGS=(
        "TITLE=$MOVIE_TITLE"
        "ENCODED_BY=$RELEASE_GROUP"
        "ORIGINAL_MEDIA_TYPE=$ORIGINAL_MEDIA_TYPE"
        "ENCODER_SETTINGS=libx265 preset=$PRESET crf=$SELECTED_CRF $X265_PARAMS"
        "CALIBRATION_DATE=$ANALYSIS_CREATED"
        "CALIBRATION_SAMPLES=$CALIBRATION_SAMPLES × $SAMPLE_DURATION s ($SAMPLE_PERCENT% of the film)"
        "CALIBRATION_VMAF_NEG_MEAN=$(printf '%.2f' "${fields[1]}")"
        "CALIBRATION_VMAF_NEG_1PCT_LOW=$(printf '%.2f' "${fields[2]}")"
        "CALIBRATION_CAMBI_MAX=$(printf '%.3f' "${fields[4]}")"
        "CALIBRATION_XPSNR_Y=${fields[5]}"
        "CALIBRATION_STEREO_GAIN_DB=$GAIN"
        "SOURCE_FILENAME=$(basename "$INPUT")"
        "SOURCE_SIZE=$(probe .format.size)"
        "SOURCE_SHA256=$SOURCE_SHA256"
        "${EXTRA_TAGS[@]}"
    )

    heading "Output"
    kv "File" "$OUTPUT"
    [[ -e $OUTPUT ]] && warn "Output file already exists"
    for tag in "${TAGS[@]}"; do
        printf '      %s%-30s%s ' "$DIM" "${tag%%=*}" "$RESET"
        wrap_text 37 "${tag#*=}"
    done

    [[ -e $OUTPUT ]] && die "$OUTPUT already exists — move it away first"
    return 0
}

# Asks before encoding, unless this is a dry run or YES says why not to.
confirm_encode() {
    local answer
    [[ -n $DRY_RUN ]] && return 0
    if [[ -n ${YES:-} ]]; then
        echo
        ok "Full encode at $PRESET · CRF $SELECTED_CRF ($YES)"
        return 0
    fi
    echo
    [[ -t 0 ]] || die "Not a terminal — cannot ask whether to continue"
    read -r -p "  ${BOLD}Continue with the full encode at $PRESET · CRF $SELECTED_CRF? [y/N]${RESET} " answer
    [[ $answer == [yY]* ]] || { echo "  Aborted."; exit 0; }
}

# Writes TAGS as a Matroska tags XML file for `mkvpropedit --tags global:FILE`.
write_tags_xml() {
    local tag name value
    # Kept for a rewrite: report_score adds tags hours after the encode.
    DATE_ENCODED=${DATE_ENCODED:-$(date -u '+%Y-%m-%d')}
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE Tags SYSTEM "matroskatags.dtd">'
        echo '<Tags><Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>'
        for tag in "${TAGS[@]}" "DATE_ENCODED=$DATE_ENCODED"; do
            name=${tag%%=*} value=${tag#*=}
            # Quoted replacements: bash 5.2+ expands a bare & to the match.
            value=${value//&/"&amp;"} value=${value//</"&lt;"} value=${value//>/"&gt;"}
            printf '<Simple><Name>%s</Name><String>%s</String></Simple>\n' "$name" "$value"
        done
        echo '</Tag></Tags>'
    } >"$1"
}

# Sets V_OUT_LANG, A_TITLE and TOTAL_FRAMES, and writes the tags XML into
# WORK.
prepare_output() {
    A_TITLE="$(probe ".streams[$A].profile // .streams[$A].codec_name" | tr '[:lower:]' '[:upper:]') ${A_LAYOUT%%(*}"
    V_OUT_LANG=${FIX_V_LANG:-${V_LANG:-und}}
    TAGS_XML="$WORK/tags.xml"
    write_tags_xml "$TAGS_XML"
    TOTAL_FRAMES=$(video_frames)
}

# The video's frames, from the span of its own timestamps: not the
# container's duration, its longest stream's (subtitles or audio can run on
# past the video), nor the NUMBER_OF_FRAMES tag, which remuxers can carry
# over unchanged from a longer source. Reads the first 10 s and the last
# 10 min; a video ending earlier than that is counted packet by packet.
video_frames() {
    local tail span
    tail=$(awk -v d="$DURATION" 'BEGIN { printf "%.3f", (d > 600 ? d - 600 : 0) }')
    span=$({
        ffprobe -v error -select_streams "$V" -read_intervals "%+10" -show_entries packet=pts_time -of csv=p=0 "$INPUT"
        ffprobe -v error -select_streams "$V" -read_intervals "$tail%" -show_entries packet=pts_time -of csv=p=0 "$INPUT"
    } | awk -F, -v t="$tail" '$1 != "N/A" { if (s == "" || $1 < s) s = $1; if ($1 > e) e = $1 }
        END { if (e > t) print e - s }')
    # First to last frame, counted from the first: a packet duration would
    # add its own millisecond rounding.
    if [[ -n $span ]]; then
        awk -v t="$span" -v r="$FPS" 'BEGIN { printf "%.0f", t * r + 1 }'
    else
        ffprobe -v error -select_streams "$V" -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$INPUT" | tr -d ,
    fi
}

# Sets the segment title, global tags and fresh track statistics on
# PARTIAL_FILE, then moves it to OUTPUT.
finalize_output() {
    run mkvpropedit -q "$PARTIAL_FILE" --edit info --set "title=$MOVIE_TITLE" --tags global:"$TAGS_XML" \
        --add-track-statistics-tags
    run mv "$PARTIAL_FILE" "$OUTPUT"

    if [[ -n $DRY_RUN ]]; then
        heading "Tags XML  ${DIM}($TAGS_XML, deleted on exit)${RESET}"
        sed 's/^/  /' "$TAGS_XML"
        exit 0
    fi
    PARTIAL=""
}

# ✔ on a match; otherwise a warning showing both values.
check() {
    local label=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then
        ok "$label"
    else
        warn "$label — expected $expected, got ${actual:-nothing}"
    fi
}

# As check, for numbers that may differ by up to the given tolerance.
check_near() {
    local label=$1 expected=$2 actual=$3 tolerance=$4
    if awk -v e="$expected" -v a="$actual" -v t="$tolerance" 'BEGIN { d = e - a; exit !(a != "" && (d < 0 ? -d : d) <= t) }'; then
        ok "$label"
    else
        warn "$label — expected $expected (±$tolerance), got ${actual:-nothing}"
    fi
}

out_probe() { jq -r "$1 // empty" <<<"$OUT_PROBE"; }

# Section 5: gains and checks common to every output; the entry script adds
# its own checks afterwards (out_probe works on the output).
report_result() {
    local src_size out_size out_frames
    section "5 · Result — $(basename "$OUTPUT")"

    OUT_PROBE=$(ffprobe -v error -show_format -show_streams -show_chapters -of json "$OUTPUT")
    src_size=$(probe .format.size)
    out_size=$(out_probe .format.size)
    out_frames=$(out_probe '.streams[0].tags.NUMBER_OF_FRAMES')

    heading "Gains"
    kv "Size" "$(human_bytes "$out_size")  (source $(human_bytes "$src_size"))"
    kv "Saved" "$(human_bytes $((src_size - out_size))) · $(awk -v s="$src_size" -v o="$out_size" 'BEGIN { printf "%.0f%% smaller · %.1f:1", (1 - o / s) * 100, s / o }')"
    kv "vs estimate" "$(human_bytes "$SELECTED_SIZE") predicted · actual $(awk -v e="$SELECTED_SIZE" -v o="$out_size" 'BEGIN { printf "%+.1f%%", (o / e - 1) * 100 }')"
    kv "Video bitrate" "$(kbps "$(out_probe '.streams[0].tags.BPS')")  (source $(kbps "$(stream_bps "$V")"))"
    kv "Encode time" "$(hms "$ENCODE_SECONDS") · $(awk -v f="$out_frames" -v t="$ENCODE_SECONDS" 'BEGIN { printf "%.1f fps", (t > 0 ? f / t : 0) }')"

    heading "Checks"
    # Container durations round to the millisecond and the last frame's length,
    # so allow a couple of frames either way.
    check_near "Frame count" "$TOTAL_FRAMES" "$out_frames" 2
    check_near "Duration (s)" "$(printf '%.2f' "$DURATION")" "$(printf '%.2f' "$(out_probe .format.duration)")" 0.2
    check "Video" "hevc Main 10 ${CROP_W}x${CROP_H}" "$(out_probe '.streams[0] | "\(.codec_name) \(.profile) \(.width)x\(.height)"')"
    check "Audio" "aac stereo default · $(probe ".streams[$A].codec_name") $A_LAYOUT" \
        "$(out_probe '[.streams[] | select(.codec_type == "audio")] | "\(.[0].codec_name) \(.[0].channel_layout) \(if .[0].disposition.default == 1 then "default" else "not default" end) · \(.[1].codec_name) \(.[1].channel_layout)"')"
    check "Subtitles" "${#SUB_STREAMS[@]}" "$(out_probe '[.streams[] | select(.codec_type == "subtitle")] | length')"
    check "Chapters" "$(probe '.chapters | length')" "$(out_probe '.chapters | length')"
    check "Cover art" "${#COVER_STREAMS[@]}" "$(out_probe '[.streams[] | select(.disposition.attached_pic == 1)] | length')"
    check "Source hash tag" "$SOURCE_SHA256" "$(out_probe .format.tags.SOURCE_SHA256)"
}
