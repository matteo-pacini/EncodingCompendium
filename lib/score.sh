# The whole film scored after the encode: the output against its source
# with the calibration's VMAF options and filters, pooled into one VMAF NEG,
# CAMBI and XPSNR for the film, set beside the calibration's prediction,
# then stored as FULL_* global tags and in the .analysis. Opt-in on the
# single-host scripts (--score); farm.sh always scores, chunk by
# chunk on the slot that encoded it. Sourced by the entry scripts.

# Scores encode $1 (its first video stream) against stream $3 of reference
# $2 into $4, one line per frame: VMAF, CAMBI (full_ref) and XPSNR Y ("inf"
# on identical frames). Further arguments go to ffmpeg before the inputs, so
# an input option there applies to the encode. One decode of each side feeds
# both metrics; XPSNR's inputs are padded as in score_xpsnr.
score_frames() {
    local out=$4 pad="pad=ceil((iw+1)/64)*64:ih"
    ffmpeg -nostdin -v error "${@:5}" -i "$1" -i "$2" -lavfi "[0:v:0]${DIST_FILTER},split[d1][d2];[1:$3]${REF_FILTER},split[r1][r2];[d1][r1]libvmaf=$VMAF_OPTIONS:n_threads=$(nproc):log_fmt=json:log_path=$out.json[v];[d2]${pad}[d3];[r2]${pad}[r3];[d3][r3]xpsnr=stats_file=$out.xpsnr[x]" \
        -map '[v]' -map '[x]' -f null -
    jq -r '.frames[].metrics | "\(.vmaf)\t\(.cambi_full_reference)"' "$out.json" >"$out.vmaf"
    awk '$1 == "n:" { print $5 }' "$out.xpsnr" | paste "$out.vmaf" - >"$out"
    [[ $(wc -l <"$out.vmaf") == $(awk '$1 == "n:"' "$out.xpsnr" | wc -l) ]] || { echo "VMAF and XPSNR frame counts differ" >&2; return 1; }
    rm -f "$out.json" "$out.vmaf" "$out.xpsnr"
}

# Pools score_frames' lines in $1 (the whole film, in order) into
# FULL_FRAMES, FULL_NEG (mean), FULL_LOW (1%-low), FULL_XPSNR, FULL_CAMBI
# (worst half second, as the calibration's gate), FULL_BANDING (runs of half
# seconds above CAMBI_MAX less than 2 s apart: "start-frame end-frame peak"
# each, worst first) and FULL_WORST (the three worst one-second VMAF means
# at least 10 s apart: "frame mean" each).
pool_scores() {
    local out
    FULL_LOW=$(cut -f1 "$1" | sort -g | sed -n "$(( $(wc -l <"$1") / 100 + 1 ))p")
    out=$(awk -F'\t' -v r="$FPS" -v cx="$CAMBI_MAX" '
        # XPSNR as ffmpeg pools it: the mean of each frame'"'"'s root error.
        { v[NR] = $1; c[NR] = $2; s += $1; if ($3 != "inf") x += 10 ^ (-$3 / 20) }
        END {
            w = int(r / 2 + 0.5)
            for (i = 1; i <= NR; i++) {
                cs += c[i]; if (i > w) cs -= c[i - w]
                if (i < w) continue
                m = cs / w
                if (m > cm) cm = m
                if (m <= cx) continue
                if (k && i - w + 1 <= e[k] + 2 * r) { e[k] = i; if (m > p[k]) p[k] = m }
                else { k++; b[k] = i - w + 1; e[k] = i; p[k] = m }
            }
            printf "%d %.6f %.4f %.4f\n", NR, s / NR, -20 * log(x / NR) / log(10), cm
            for (j = 1; j <= k; j++) printf "band %d %d %.3f\n", b[j] - 1, e[j] - 1, p[j]
            L = int(r + 0.5)
            for (i = 1; i <= NR; i++) { vs += v[i]; if (i > L) vs -= v[i - L]; if (i >= L) vm[i - L + 1] = vs / L }
            for (t = 1; t <= 3; t++) {
                best = 0
                for (i = 1; i <= NR - L + 1; i++) {
                    if (best && vm[i] >= vm[best]) continue
                    for (u = 1; u < t; u++) if ((i - got[u]) ^ 2 < (10 * r) ^ 2) break
                    if (u == t) best = i
                }
                if (!best) break
                got[t] = best
                printf "worst %d %.2f\n", best - 1, vm[best]
            }
        }' "$1")
    read -r FULL_FRAMES FULL_NEG FULL_XPSNR FULL_CAMBI <<<"${out%%$'\n'*}"
    mapfile -t FULL_BANDING < <(grep '^band' <<<"$out" | sort -k4,4gr | cut -d' ' -f2-)
    mapfile -t FULL_WORST < <(grep '^worst' <<<"$out" | cut -d' ' -f2-)
}

# Film time of frame $1.
frame_time() { hms "$(awk -v f="$1" -v r="$FPS" 'BEGIN { print f / r }')"; }

# Value of tag $1 in TAGS.
tag_value() {
    local tag
    for tag in "${TAGS[@]}"; do
        [[ $tag == "$1="* ]] && { echo "${tag#*=}"; return 0; }
    done
}

# Reports the pooled scores of the per-frame file $1 against the
# calibration's prediction and the gates (warnings only: the encode is
# done), then adds them to OUTPUT's global tags and to the .analysis
# under "<preset>@<crf>.full" (tab-separated: created frames neg 1%-low
# cambi xpsnr).
report_score() {
    local band start end peak places=() worst=() seconds=0 n where i
    pool_scores "$1"
    for band in "${FULL_BANDING[@]}"; do
        read -r start end peak <<<"$band"
        seconds=$(awk -v s="$seconds" -v a="$start" -v b="$end" -v r="$FPS" 'BEGIN { print s + (b - a + 1) / r }')
        if (( ${#places[@]} < 12 )); then places+=("$(frame_time "$start") $(printf '%.2f' "$peak")"); fi
    done
    for band in "${FULL_WORST[@]}"; do worst+=("$(frame_time "${band% *}") ${band#* }"); done

    heading "Whole film  ${DIM}vs calibration${RESET}"
    kv "Frames" "$FULL_FRAMES"
    kv "VMAF NEG" "$(printf '%.2f · 1%%-low %.2f' "$FULL_NEG" "$FULL_LOW")  (calibration $(tag_value CALIBRATION_VMAF_NEG_MEAN) · $(tag_value CALIBRATION_VMAF_NEG_1PCT_LOW))"
    kv "XPSNR" "$(printf '%.2f' "$FULL_XPSNR") dB  (calibration $(tag_value CALIBRATION_XPSNR_Y))"
    kv "CAMBI" "$(printf '%.2f' "$FULL_CAMBI") worst ½ s  (calibration $(printf '%.2f' "$(tag_value CALIBRATION_CAMBI_MAX)"))"
    kv "Worst VMAF seconds" "$(IFS=,; echo "${worst[*]}" | sed 's/,/ · /g')"
    if awk -v m="$FULL_NEG" -v l="$FULL_LOW" -v tm="$VMAF_TARGET_MEAN" -v tl="$VMAF_TARGET_LOW" 'BEGIN { exit !(m >= tm && l >= tl) }'; then
        ok "VMAF NEG mean ≥ $VMAF_TARGET_MEAN · 1%-low ≥ $VMAF_TARGET_LOW"
    else
        warn "VMAF NEG below the gate (mean ≥ $VMAF_TARGET_MEAN · 1%-low ≥ $VMAF_TARGET_LOW)"
    fi
    n=${#FULL_BANDING[@]}
    where="$n place$( ((n == 1)) || echo s), $(printf '%.1f' "$seconds") s in all"
    if (( n == 0 )); then
        ok "CAMBI ≤ $CAMBI_MAX in every half second"
    else
        warn "CAMBI over $CAMBI_MAX in $where · worst first:"
        # Four to a line: wrapping would split a time from its score.
        for ((i = 0; i < ${#places[@]}; i += 4)); do
            printf '    %s\n' "$(IFS=,; echo "${places[*]:i:4}" | sed 's/,/ · /g')"
        done
        (( n <= ${#places[@]} )) || printf '    %s… %d more%s\n' "$DIM" $((n - ${#places[@]})) "$RESET"
    fi

    TAGS+=(
        "FULL_FRAMES=$FULL_FRAMES"
        "FULL_VMAF_NEG_MEAN=$(printf '%.2f' "$FULL_NEG")"
        "FULL_VMAF_NEG_1PCT_LOW=$(printf '%.2f' "$FULL_LOW")"
        "FULL_CAMBI_MAX=$(printf '%.3f' "$FULL_CAMBI")"
        "FULL_XPSNR_Y=$(printf '%.2f' "$FULL_XPSNR")"
        "FULL_VMAF_WORST_SECONDS=$(IFS=,; echo "${worst[*]}" | sed 's/,/, /g')"
    )
    (( n == 0 )) || TAGS+=("FULL_CAMBI_OVER_LIMIT=$where; worst first: $(IFS=,; echo "${places[*]}" | sed 's/,/, /g')")
    write_tags_xml "$TAGS_XML"
    mkvpropedit -q "$OUTPUT" --tags global:"$TAGS_XML"
    # shellcheck disable=SC2004 # CACHE is associative: the key is a string
    CACHE[$PRESET@$SELECTED_CRF.full]=$(printf '%s\t' "$(date '+%Y-%m-%d %H:%M')" "$FULL_FRAMES" "$FULL_NEG" "$FULL_LOW" "$FULL_CAMBI" "$FULL_XPSNR")
    save_analysis
    ok "Stored as FULL_* tags and in $(basename "$ANALYSIS")"
}

# Scores OUTPUT against INPUT on this host, then report_score.
score_output() {
    local STEP_NAMES=("score") BLOCK_CRF="" start=$SECONDS
    heading "Scoring the whole film"
    begin_sample "VMAF NEG · CAMBI · XPSNR · $(hms "$DURATION")"
    run_step 0 "$TOTAL_FRAMES" score_frames "$OUTPUT" "$INPUT" "$V" "$WORK/score.tsv" -nostats -progress pipe:1
    clear_block
    ok "Scored in $(hms $((SECONDS - start)))"
    report_score "$WORK/score.tsv"
}
