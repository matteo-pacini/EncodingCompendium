# The stereo track: downmix of the primary audio A, AAC-LC at a fixed gain
# that puts the true peak at TARGET_PEAK (measured over the whole film), plus
# the original track copied. Sourced by the entry scripts.

# One fixed gain, measured in section 3, puts the downmix's true peak here:
# the film's dynamics stay intact, and the summed downmix cannot clip.
TARGET_PEAK=-1
STEREO_BITRATE="256k"

# Chooses DOWNMIX for A's layout and prints the section 2 audio plan.
plan_audio() {
    local a dropped=()
    # Surround channel names depend on the layout ffmpeg reports.
    case $A_LAYOUT in
        "5.1(side)") DOWNMIX="pan=stereo|FL=FL+FC+0.707*SL|FR=FR+FC+0.707*SR" ;;
        5.1)         DOWNMIX="pan=stereo|FL=FL+FC+0.707*BL|FR=FR+FC+0.707*BR" ;;
        7.1)         DOWNMIX="pan=stereo|FL=FL+FC+0.707*SL+0.5*BL|FR=FR+FC+0.707*SR+0.5*BR" ;;
        mono|stereo) DOWNMIX="" ;;
        *)           DOWNMIX="aresample=ochl=stereo" ;;
    esac
    STEREO_PREFILTER="aformat=sample_fmts=fltp${DOWNMIX:+,$DOWNMIX}"

    heading "Audio"
    if (( A_CHANNELS > 2 )); then
        item "Track 1 · stereo · AAC-LC $STEREO_BITRATE · 48 kHz · $A_LANG · default"
    else
        item "Track 1 · $A_LAYOUT · AAC-LC $STEREO_BITRATE · 48 kHz · $A_LANG · default"
    fi
    if [[ $DOWNMIX == aresample* ]]; then
        setting "Downmix" "$DOWNMIX"
        warn "Unrecognised channel layout '$A_LAYOUT' — using ffmpeg's default downmix."
    elif [[ -n $DOWNMIX ]]; then
        setting "Downmix" "$DOWNMIX"
    fi
    setting "Gain" "fixed, true peak → $TARGET_PEAK dBTP (measured in section 3)"
    item "Track 2 · #$A $(probe ".streams[$A].profile // .streams[$A].codec_name") ${A_LAYOUT} · $A_LANG · copied bit-for-bit"
    for a in "${AUDIO_STREAMS[@]}"; do
        [[ $a == "$A" ]] || dropped+=("#$a")
    done
    (( ${#dropped[@]} == 0 )) || item "Dropped: ${dropped[*]}"
}

# Measures the downmix over the whole film into MEASURED_I/LRA/PEAK and sets
# GAIN and STEREO_FILTER.
# Runs as step 0 of the calibration's live block.
measure_gain() {
    local ebur128
    # ebur128 prints its summary to stderr; stdout carries the progress.
    run_time_step 0 "$DURATION" ffmpeg -nostdin -hide_banner -nostats -progress pipe:1 -i "$INPUT" -map 0:"$A" \
        -af "$STEREO_PREFILTER,ebur128=peak=true:framelog=quiet" -f null - 2>"$WORK/ebur128.log"
    ebur128=$(sed -n '/Summary:/,$p' "$WORK/ebur128.log")
    MEASURED_I=$(awk '$1 == "I:" { print $2 }' <<<"$ebur128")
    MEASURED_LRA=$(awk '$1 == "LRA:" { print $2 }' <<<"$ebur128")
    MEASURED_PEAK=$(awk '/True peak:/ { tp = 1 } tp && $1 == "Peak:" { print $2; exit }' <<<"$ebur128")
    [[ -n $MEASURED_PEAK ]] || die "Could not measure the stereo downmix"
    GAIN=$(awk -v t="$TARGET_PEAK" -v p="$MEASURED_PEAK" 'BEGIN { printf "%.1f", t - p }')
    set_stereo_filter
}

set_stereo_filter() { STEREO_FILTER="$STEREO_PREFILTER,volume=${GAIN}dB,aresample=48000"; }

print_gain() {
    kv "True peak" "$MEASURED_PEAK dBTP"
    kv "Loudness" "$MEASURED_I LUFS → $(awk -v i="$MEASURED_I" -v g="$GAIN" 'BEGIN { printf "%.1f", i + g }') LUFS · range $MEASURED_LRA LU"
    kv "Gain" "${GAIN} dB"
    setting "Filter" "$STEREO_FILTER"
}
