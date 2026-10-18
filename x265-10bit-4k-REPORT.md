# x265-10bit-4k.sh: design report

Research for a 2160p UHD Blu-ray counterpart to `x265-10bit.sh`. The script keeps HDR10 and Dolby Vision and needs zero transcoding on this chain: Shield TV Pro (2019), then Jellyfin Android TV, then LG OLED48CX.

Date: 2026-10-17. Toolchain checked against nixpkgs-unstable `f20cd90e` (the rev in `nix/flake.lock`).

Labels used in this report:

- **[tested]**: run locally on tiny synthetic clips (256×144 or 960×540, 24 frames). No 4K file was available, and a calibration was running.
- **[source]**: cited.
- **[inference]**: my reasoning. Verify these.

---

## Summary

**Tools.** Everything needed is in nixpkgs-unstable:

| Tool | Version |
|---|---|
| dovi_tool (attribute `dovi-tool`) | 2.3.4 |
| hdr10plus_tool | 1.7.2 |
| mkvtoolnix | 102.0 |
| gpac/MP4Box | 26.07 |
| x265 | 4.2, 8+10+12-bit multilib |
| ffmpeg-full | 9.0.1 |
| libvmaf | 3.0.0 |

**Three facts shape the design** [tested]:

1. **HDR10+ is not available in 10-bit.** nixpkgs builds `ENABLE_HDR10_PLUS` only into the 8-bit core. At `--output-depth 10`, x265 prints `--dhdr10-info disabled. Enable HDR10_PLUS in cmake.` and silently ignores the option.
2. **`--dolby-vision-rpu` works only in the x265 CLI.** Through ffmpeg `-x265-params` it is accepted, but no RPU reaches the output.
3. **ffmpeg's own `-dolbyvision` passthrough cannot handle UHD BD sources.**
   - It works for P8 sources.
   - It refuses or skips P7, which is what UHD BDs are: `dovi_rpuenc.c` returns "Coding of Dolby Vision enhancement layers is currently unsupported", and in `auto` mode it skips DV.
   - It does not touch L5 after a crop.

**Recommended DV path:**

1. Run `dovi_tool -m 2 --crop extract-rpu` on the source.
2. Optionally edit the RPU with `dovi_tool editor`.
3. Pipe ffmpeg (decode + crop) into the x265 CLI with `--dolby-vision-profile 8.1 --dolby-vision-rpu`.
4. Mux the raw HEVC with mkvmerge. mkvmerge writes the `dvvC` block-addition mapping, and ffprobe then reports `dv_profile 8, compat id 1` [tested].

`dovi_tool inject-rpu` into a plain encode also works [tested]. It is the fallback if the script must keep encoding through ffmpeg/libx265.

**Drop HDR10+.** Neither the Shield nor the CX supports it. Also, an HDR10+-only file (no DV) is flagged `HDR10Plus`, which jellyfin-androidtv marks unsupported on the Shield. That triggers a remux or transcode. Output either DV 8.1 + HDR10 fallback, or plain HDR10.

**Playback.**

- DV P8.1 in MKV direct-plays on Shield + Jellyfin [source].
- P7 (FEL/MEL) is forced to remux or transcode by jellyfin-androidtv 0.19.x. Only 0.20 betas whitelist the Shield. Converting to 8.1 is therefore also what makes direct play work.
- The CX has no HDR10+ and no DTS at all, including passthrough.

**x265 starting point:**

```
--preset slow --crf 16–20 (calibrated) --output-depth 10 --profile main10
--level-idc 5.1 --high-tier --vbv-maxrate 160000 --vbv-bufsize 160000
--hdr10-opt --aq-mode 3 --aq-strength 0.8 --no-sao --no-strong-intra-smoothing --deblock -2:-2   (same detail block as 1080p; forum range -1..-3)
--colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --range limited --chromaloc 2
--master-display <from source> --max-cll <from source> --hdr10 --repeat-headers
```

Notes:

- VBV is mandatory once DV is enabled. x265 fails with "Dolby Vision requires VBV settings to enable HRD" [tested].
- Use the High tier at L5.1, because the Shield advertises `Main10 High 5.1`. Never let x265 auto-pick L5.2.

**Metrics.**

- `vmaf_4k_v0.6.1neg` is built into libvmaf 3.0.0 [tested]. It is the direct 4K counterpart of the 1080p NEG gate.
- The VMAF v1 models (`vmaf_v1.0.16_*_2160`) need libvmaf ≥ 3.2.0. That explains the CAMBI-extractor load failure on 3.0.0. Don't depend on them until nixpkgs bumps libvmaf.
- CAMBI supports `eotf=pq` [tested]. Use it: the score scale changes, so recalibrate `CAMBI_MAX`.
- XPSNR works at any size and bit depth, but it is not HDR-aware. Use it only as the relative knee detector, as at 1080p.
- All metrics are SDR-trained or PQ-agnostic. Compute them on the PQ signal directly, never after tone mapping, and treat them as *relative* gates.

**Audio.** Use the same plan: AAC stereo default with fixed gain from the measured true peak, plus the original lossless track. Chain specifics:

- **TrueHD/Atmos.** Keep it. It passes via CX eARC.
  - There is an open jellyfin-androidtv bug (#5595): TrueHD gets transcoded on Shield + LG. Set TrueHD bitstreaming to "Enable" in the client and test.
  - ffmpeg decodes only the 7.1 bed for the downmix. Objects are dropped, which is fine for stereo.
- **DTS-HD MA / DTS:X.** The CX cannot play it at all. Either keep it for the archive and accept server-side audio transcode, or add EAC3 5.1/7.1 as a second playable surround track.

**Cost.**

- Expect roughly 5–10 fps at 2160p `slow` on a 16-core desktop. This machine is an 8-core 8945HS laptop, so expect less: likely 2–4 fps [inference]. That makes a 2-hour film about 15–30 h.
- The 1080p calibration grid (10 samples × 20 s × 3 CRFs) costs about 4× more per CRF at 4K. Cut the grid (see §6).
- File sizes: about 8–25 Mb/s video, so 7–22 GB for 2 h.

---

## 1. Tools (nixpkgs-unstable `f20cd90e`)

All of these were checked with `nix shell github:NixOS/nixpkgs/<rev>#<pkg>`. The flake was not touched.

| Package attr | Version | Notes |
|---|---|---|
| `dovi-tool` (not `dovi_tool`) | 2.3.4 | `extract-rpu`, `convert`, `editor`, `inject-rpu`, `generate`, `info`, `demux`/`mux`, `remove`. Global `-m 0–5`, `-c/--crop`. |
| `hdr10plus_tool` | 1.7.2 | `extract`, `inject`, `remove`, `editor`, `plot`. |
| `mkvtoolnix-cli` | 102.0 | Reads single-layer DV from Annex-B HEVC (since v58) and writes the `dvvC` BlockAdditionMapping [tested]. |
| `gpac` | 26.07.0 | MP4Box. Not needed for MKV output. |
| `x265` | 4.2 | `8bit+10bit+12bit` build, so `--output-depth 10/12` works. |
| `ffmpeg-full` | 9.0.1 | Links the same `libx265.so.216` and `libvmaf.so.3` (3.0.0). Has `-dolbyvision` (auto/0/1). |
| `libvmaf` | 3.0.0 | Built-in models: `vmaf_v0.6.1`, `vmaf_v0.6.1neg`, `vmaf_4k_v0.6.1`, `vmaf_4k_v0.6.1neg`, `vmaf_b_v0.6.3`. No v1 models. |

**x265 build details** (from `pkgs/by-name/x2/x265/package.nix`):

- The 10-bit and 12-bit cores are static libraries configured with `cmakeStaticLibFlags`. `ENABLE_HDR10_PLUS=ON` is appended afterwards, so only the 8-bit core has it. Test results:

  | Command | Result |
  |---|---|
  | `x265 --output-depth 10 --dhdr10-info x.json` | `[warning]: --dhdr10-info disabled. Enable HDR10_PLUS in cmake.` and the encode continues **without** HDR10+ |
  | `x265 --output-depth 8 --dhdr10-info missing.json` | `Unable to open tone-map file.` (supported) |

  If HDR10+ were ever wanted, `hdr10plus_tool inject` after encoding works on any bitstream. For this chain it isn't wanted (see §3).

- **Dolby Vision** [tested]:
  - `--dolby-vision-profile 8.1 --dolby-vision-rpu rpu.bin` with VBV and `--master-display` gives `VES muxing with Dolby Vision RPU file successful`. The extracted RPU then reports profile 8 and the correct frame count.
  - Without VBV or master-display it fails: `Dolby Vision requires VBV settings to enable HRD.` and `Dolby Vision profile - 8.1 requires Mastering display color volume information`. CLI options: 5, 8.1, 8.2 (x265 docs add 8.4).
- **RPU frame-count mismatch is only a warning** [tested]:

  | RPU vs frames | x265 output | Exit code |
  |---|---|---|
  | RPU shorter (12 RPU / 24 frames) | `Dolby Vision RPU not found for POC 12…23`; the output's RPU reports 17 frames (garbage) | 0 |
  | RPU longer (48 RPU / 24 frames) | `Dolby Vision RPU count is greater than frame count`; trailing RPUs ignored | 0 |

  **The script must assert `dovi_tool info --summary` Frames == the encoded frame count itself.**
- **ffmpeg `-x265-params dolby-vision-rpu=…`**: accepted, exit 0, **no RPU** in the output [tested]. The RPU file reader is in the CLI (`x265.cpp`), not libx265, and the x265 docs mark it "CLI ONLY".
- **ffmpeg `-dolbyvision 1`** [tested on a P8.1 source]:
  - It regenerates RPUs from decoder side data, and ffprobe shows a DOVI config record (P8, compat 1).
  - It also passed HDR10 mastering/CLL side data through automatically (ffmpeg ≥ 7.0).
  - Per `libavcodec/dovi_rpuenc.c` (9.0.1 source), a P7 source either errors (`-dolbyvision 1`) or skips DV (`auto`).
  - `vf_crop` has no DOVI handling, so L5 offsets are left as-is.
  - This makes it unusable for UHD BD unless the source is first remuxed to P8.1. That is possible (`dovi_tool -m 2 convert --discard`, then remux, then ffmpeg) but it adds a full-size intermediate.

## 2. x265 settings for 2160p HDR10

Sources are mainly Doom9:

- [t-186208](https://forum.doom9.org/archive/index.php/t-186208.html) (2025, UHD HDR BD re-encodes)
- [t-176950](https://forum.doom9.org/archive/index.php/t-176950.html)
- [t-183860](https://forum.doom9.org/showthread.php?t=183860)
- [t-177619](https://forum.doom9.org/archive/index.php/t-177619.html)

Plus the [x265 CLI docs](https://x265.readthedocs.io/en/master/cli.html), the [silentaperture guide](https://silentaperture.gitlab.io/mdbook-guide/encoding/x265.html) and [CodeCalamity](https://codecalamity.com/encoding-settings-for-hdr-4k-videos-using-10-bit-x265/).

| Setting | Recommendation | Evidence / disagreement |
|---|---|---|
| **CRF** | Calibrate in 16–20; start the sweep at 16 | benwaggoner: "start with 18 and iterate". Archival users run 16–18 (one at 14–16). CodeCalamity defaults to 20. With `--hdr10-opt`, HDR needs about 2 CRF lower than SDR (excellentswordfight, t-186208); without it, 4–5 lower (Boulder, t-177619). |
| **Preset** | `slow` (consistent with 1080p); `slower` if time allows | benwaggoner suggests `slower --hdr10 --hdr10-opt` before any tweaks. `slow` → `slower`: bframes 4→8, ref 4→5, rd 4→6, subme 3→4. Speed cost is large (§6). |
| **aq-mode** | `3`, strength 0.8 (as at 1080p) | Z2697 ([p=2022103](https://forum.doom9.org/showthread.php?p=2022103)) recommends 3 with hdr10-opt: the dark bias offsets hdr10-opt's low-luma QP raise. Others use 1, 2 or 4. aq-mode 5 exists only in forks. |
| **hdr10-opt** | On | Block-level luma/chroma QP optimisation (H-Series Supp. 15). Recommended by benwaggoner and microchip8; Z2697 calls it "too simple". It takes the place of manual `cbqpoffs`/`crqpoffs` [weak]. |
| **psy-rd / psy-rdoq** | Preset defaults (2.0 / 1.0) | Range seen: psy-rd 0.8–2, psy-rdoq 1–4 (grain). |
| **SAO** | `no-sao` | silentaperture and blublub use it off. Asmodian and Blue_MiSfit say it's harmless. `selective-sao=2` is a middle ground. Keeping `no-sao` matches 1080p. |
| **deblock** | `-2:-2` (as at 1080p) | Forum range -1..-3 for live action. |
| **strong-intra-smoothing** | Off | For sharp or grainy content; leave it on only for very soft sources. |
| **Level / tier / VBV** | `level-idc=5.1:high-tier=1:vbv-maxrate=160000:vbv-bufsize=160000` | L5.1 limits: Main 40 Mb/s, High 160 Mb/s (confirmed in x265 `level.cpp`). The Shield's MediaCodec advertises HEVC Main10 **High 5.1** ([Jellyfin forum](https://forum.jellyfin.org/t-solved-direct-play-4k-hdr-issues?pid=33863)). jellyfin-androidtv transcodes above the advertised level ([#3380](https://github.com/jellyfin/jellyfin-androidtv/issues/3380), an L5.2 file). A Main-tier 40 Mb/s cap (benwaggoner) is the conservative choice for any decoder. At CRF ~18, peaks rarely reach 40 Mb/s, so either works; High tier is what the Shield needs. |
| **hdr10 / repeat-headers** | Both on | x265 auto-enables `repeat-headers` with HDR [tested: "Turning on repeat-headers for HDR compatibility"]. With DV 8.1, x265 forces HRD SEI and AUD itself (`encoder.cpp`). |
| **aud / hrd** | Not needed for MKV without DV; forced on with DV | |
| **Colour** | `colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:chromaloc=2` | `chromaloc=2` (top-left) is the UHD BD convention ([Doom9 t-168814](https://forum.doom9.org/archive/index.php/t-168814-p-197.html)) and the x265 `BT2100_PQ_YCC` preset. Copy the source's `chroma_location` rather than hard-coding it. Matroska flags: `-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv -chroma_sample_location topleft`. |
| **master-display / max-cll** | Copy from source | See below. |
| **bframes / ref / rc-lookahead / keyint** | Keep the 1080p RC block (`bframes=8:ref=5:rc-lookahead=60`), `keyint=240:min-keyint=24` | No 4K-specific advice found. `ref 5` is within L5.1 DPB limits at 2160p (6 frames). |
| **tune grain** | No | Only for very heavy grain. If used, don't override aq or cutree. benwaggoner suggests `nr-inter` plus chroma QP offset -1 for noise instead. |

**Copying HDR10 metadata.**

1. Read the first frame's side data:

   ```
   ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_frames -show_entries frame=side_data_list -of json
   ```

2. Build `--master-display`:
   - Format: `G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)`. Note the order: G, B, R.
   - Chromaticities are in units of 1/50000. ffprobe may print reduced fractions, so rescale them to /50000.
   - Luminance is in units of 1/10000 cd/m².
3. Build `--max-cll`: `max_content,max_average`.

ffmpeg ≥ 7.0 copies MDCV/CLL to libx265 automatically ([Changelog](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/Changelog); confirmed [tested] in 9.0.1). The x265 CLI route needs them explicitly. Pass them explicitly in both cases so the values appear in the plan and in `ENCODER_SETTINGS`.

**Verify on a real file:** that the first frame carries the side data on UHD BD remuxes. MakeMKV keeps it in the HEVC SEI; some remuxes have it only in the MKV `Colour` element, which ffprobe reports on the stream rather than the frame.

## 3. Dolby Vision workflow

### Source cases

| ffprobe DOVI record | Meaning | Action |
|---|---|---|
| `dv_profile 7`, `el_present_flag 1` | UHD BD dual-layer (FEL or MEL) | Extract the RPU with `-m 2` to make it 8.1. The EL is discarded. |
| `dv_profile 8`, compat 1 | Already 8.1 (e.g. web or converted) | Extract with `-m 0` (or `-m 2`, harmless). |
| `dv_profile 5` | IPTPQc2, no HDR10 base | Out of scope. Re-encoding the base needs DV-aware processing (`-m 3` is a P5→8.1 RPU change, not a picture conversion) [inference]. |
| None, with HDR10+ SEI | HDR10+ only | Encode as HDR10. Optionally add `dovi_tool generate --hdr10plus-json` to create P8.1 from the HDR10+ metadata. |
| None | HDR10 | Plain HDR10 encode. |

Detect the type with `ffprobe … side_data_list` (`DOVI configuration record`: `dv_profile`, `el_present_flag`) and `dovi_tool info -i RPU.bin --summary`.

Distinguishing FEL from MEL is not shown in ffprobe; `dovi_tool info` on frame 0 shows the EL type in the NLQ data [inference]. Report it in section 1, because FEL titles may lose something when converted (below).

### Pipeline (per encode or sample)

```
# 1. RPU: P7 → 8.1, remove mapping; zero L5 if cropping letterbox
dovi_tool -m 2 [--crop] extract-rpu -i source.mkv -o RPU.bin
dovi_tool info -i RPU.bin --summary            # frames, profile, L5, L6

# 2. Encode: ffmpeg decodes/crops, x265 CLI injects the RPU
ffmpeg -i source.mkv -map 0:v:0 -vf crop=… -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - |
  x265 --input - --y4m --output-depth 10 --profile main10 … \
       --dolby-vision-profile 8.1 --dolby-vision-rpu RPU.bin \
       --master-display … --max-cll … -o video.hevc

# 3. Check: dovi_tool extract-rpu video.hevc → Frames must equal the encode's frame count

# 4. Mux (mkvmerge ≥ v58 reads DV from Annex-B HEVC and writes dvvC)
mkvmerge -o out.mkv video.hevc --no-video source.mkv (+ AAC track, tags…)
```

Steps 1, 2 and 4 were [tested] on synthetic clips: `-m 2 --crop extract-rpu`, x265 CLI injection, and mkvmerge writing `Block addition ID type: dvvC`. ffprobe on the result shows `dv_profile 8, dv_bl_signal_compatibility_id 1, rpu_present 1, el_present 0`.

Fallback that keeps the ffmpeg/libx265 encode path: encode to raw HEVC with the HDR10 flags and VBV, then run `dovi_tool inject-rpu -i video.hevc --rpu-in RPU.bin -o video.dv.hevc` [tested]. Here x265 does not add the DV-specific HRD/AUD signalling (dovi_tool README; [inference] that it is harmless for MKV playback).

### Crop and L5

L5 holds the letterbox offsets of the active area. After cropping the bars, L5 must be zero:

- `--crop` at extraction does this. Verified: a synthetic RPU with `top=276,bottom=276` becomes `0,0,0,0` with both `-m 2 --crop extract-rpu` and editor `{"active_area":{"crop":true}}` [tested].
- **Variable aspect-ratio films** (IMAX scenes) have per-shot L5. If the script crops to the *largest* area (as at 1080p, keeping some black bars in the narrower scenes), zeroing L5 is still the accepted practice [inference]. A better alternative is to rewrite L5 per shot to the remaining bars with editor `presets`/`edits`, which is more complex. Flag VAR sources in section 1: the 1080p script already warns when crop samples disagree.
- Never crop without adjusting L5: the TV would apply the old offsets.

### Calibration samples and the RPU

Samples are cut with `-ss`/`-t` stream copy, which starts at a keyframe. Options:

- **(a) Calibrate without DV.** Recommended: metrics see only the base layer, and the RPU does not affect the picture the metrics compare. Use DV only for the final encode.
- **(b) Per sample**, run `dovi_tool editor` with `remove` ranges `0-(N-1)` and `(N+L)-end` ([MakeMKV p=111011](https://forum.makemkv.com/forum/viewtopic.php?p=111011)). Requires exact frame indices of the cut.

(a) is simpler and loses nothing.

### What FEL → 8.1 loses

- **MEL** carries essentially no data, so converting it is lossless in practice.
- **FEL** carries a residual layer that is lost ([MakeMKV p=98585](https://forum.makemkv.com/forum/viewtopic.php?p=98585)). Effects are title-dependent:
  - Usually invisible. quietvoid: No Time to Die shows no difference ([p=134906](https://forum.makemkv.com/forum/viewtopic.php?p=134906)).
  - Occasionally flicker, or more banding on clean animation ([Firecore p76](https://community.firecore.com/t/dolby-vision-profile-7-8-support-ts-mkv-files/19713?page=76)).
  - Some FEL titles expand brightness in the BL+EL composite and do not convert cleanly ([p=134926](https://forum.makemkv.com/forum/viewtopic.php?p=134926)).
- Mapping **must** be removed (`-m 2`), or colours come out wrong.
- Old guides' "mode 2" is today's mode 5. Mode 5 keeps the mapping, which is wrong for FEL.

Since only the 10-bit base layer is re-encoded anyway, FEL → 8.1 is the accepted trade-off.

### Playback chain

| Item | Status | Source |
|---|---|---|
| Shield HDR formats | DV + HDR10 only; **no HDR10+**. HEVC 4K60 10-bit. | [nvidia.com](https://www.nvidia.com/en-us/shield/shield-tv-pro/) |
| Shield HEVC level | Main10 High 5.1 advertised; a Pro tested to 144 Mb/s | [Jellyfin forum](https://forum.jellyfin.org/t-solved-direct-play-4k-hdr-issues?pid=33863), [Emby](https://emby.media/community/topic/104857-2019-tube-nvidia-shield-4k-issues) |
| P8.1 in MKV via jellyfin-androidtv | Direct play | [#5316](https://github.com/jellyfin/jellyfin-androidtv/issues/5316), [forum](https://forum.jellyfin.org/t-solved-jellyfin-doesn-t-fall-back-to-hdr-on-dolby-vision-profile-7-files-on-sony-bravia-8?pid=38833) |
| P7 (FEL/MEL) in MKV | Client 0.19.10 (stable) marks `DOVI_WITH_EL` unsupported, so remux/transcode. PR #5652 whitelists the Shield, but only in 0.20.0 betas (beta.4, 2026-10-15). The Shield itself reportedly plays BL+RPU and ignores FEL. | [deviceProfile.kt](https://github.com/jellyfin/jellyfin-androidtv/blob/master/app/src/main/java/org/jellyfin/androidtv/util/profile/deviceProfile.kt), [PR #5652](https://github.com/jellyfin/jellyfin-androidtv/pull/5652), [MakeMKV](https://forum.makemkv.com/forum/viewtopic.php?p=102893) |
| HDR10+-only file | Flagged `HDR10Plus`, unsupported on the Shield, so remux/transcode. DV + HDR10+ is fine. | deviceProfile.kt |
| `DOVIInvalid` | Wrong compat ID or BL colour disagreeing with the RPU leads to transcode. x265 forces BT.2020/PQ with 8.1. | [VideoRangeType.cs](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Data/Enums/VideoRangeType.cs) |
| LG CX | HDR10, DV, HLG. **No HDR10+.** **No DTS** (no decode, no passthrough over eARC). | [Trusted Reviews](https://www.trustedreviews.com/reviews/lg-cx-oled55cx), [CoreELEC](https://discourse.coreelec.org/t/arc-recommendation-for-7-1-1080p-avr-and-4k-tv/16263) |
| Shield → LG DV mode | TV-led by default | [MakeMKV](https://forum.makemkv.com/forum/viewtopic.php?p=100865) |

**Conclusion: the output is P8.1 (BL = HDR10, compat ID 1) in MKV.** The HDR10 base is the fallback for any non-DV device. Don't carry HDR10+ even if the source has it: it is useless on this chain, and HDR10+ is not available in 10-bit x265 here anyway.

## 4. Quality metrics at 4K HDR

| Metric | Status here | Notes |
|---|---|---|
| `vmaf_4k_v0.6.1neg` | Built in, works [tested] | 4K TV at 1.5H. NEG = no enhancement gain, the right one for codec tuning ([models_v0.md](https://raw.githubusercontent.com/Netflix/vmaf/master/resource/doc/models_v0.md)). Same family as the 1080p gate, so the same 95/90 targets are a reasonable start. |
| `vmaf_v1.0.16_1d5h_2160` / `_3d0h_2160` | **Unusable on libvmaf 3.0.0** | Added in libvmaf **3.2.0** ([releases](https://github.com/Netflix/vmaf/releases)). The model JSON pulls `cambi` (with `cambi_high_res_speedup`, `cambi_vis_lum_threshold`, …), `speed_chroma_uv`, `adm3` and `motion3`, extractors or options 3.0.0 lacks. That explains "could not initialize feature extractor Cambi_feature_cambi_score". Needs a libvmaf bump in nixpkgs, or an override. Docs say SDR. |
| HDR-VMAF (Netflix/Dolby) | Not public | [CSI](https://csimagazine.com/csi/netflix-reveals-hdrvmaf-solution.php) |
| CAMBI | Works; `eotf=pq` supported [tested] | Options: `eotf` (bt1886/pq), `full_ref`, `topk`, `tvi_threshold`, `window_size` (65 ≈ 1° at 4K), `max_log_contrast`, `enc_width/height/bitdepth`, `src_width/height`, `cambi_high_res_speedup` ([cambi.c](https://raw.githubusercontent.com/Netflix/vmaf/master/libvmaf/src/feature/cambi.c)). 4K is native. CAMBI **fails at tiny sizes**: 256×144 gave `problem during vmaf_read_pictures`, 540p was fine. |
| XPSNR | Works on 10-bit [tested] | Block size scales from 3840×2160, so UHD is explicitly handled. No PQ awareness; usable as a relative knee detector ([vf_xpsnr.c](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/vf_xpsnr.c)). |
| ColorVideoVDP | Not in nixpkgs flow; GPU preferred | The only practical true HDR (PQ) metric (`--display standard_hdr_pq`) ([gfxdisp](https://github.com/gfxdisp/ColorVideoVDP)). Useful for a one-off spot check, not for the CRF loop. |
| PU21-PSNR, ΔE ITP | No ffmpeg filter | `pu21` was proposed in 2024 but is not merged. ΔE ITP needs Python (colour-science). |

**CAMBI with `eotf=pq` changes the scale.** On a 540p synthetic CRF 35 encode [tested]:

| CAMBI | `eotf=bt1886` | `eotf=pq` |
|---|---|---|
| `cambi_full_reference` | 0.08 | 0.54 |
| `cambi_source` | 0.16 | 0.32 |

PQ is more sensitive, as expected: dark-region thresholds use PQ luminance. The 1080p `CAMBI_MAX=1` was set for BT.1886. For 4K, either measure the source's `cambi_source` and gate on the *added* banding, or re-derive the threshold on a real film. **Verify on a real file.**

**Score on PQ, never after tone mapping.**

- Ben Waggoner: "VMAF is a lot less accurate for HDR than SDR … a VMAF difference of 0.05 with HDR doesn't tell you anything" ([t-183860](https://forum.doom9.org/showthread.php?t=183860)).
- No authoritative source recommends tone mapping before scoring. Tone mapping adds its own distortion and measures a different picture.
- Use VMAF NEG and XPSNR on the 10-bit PQ signal as **relative** gates between CRFs of the same source. This is what the calibration loop does anyway. Use CAMBI with `eotf=pq`.

**Speed.** No clean libvmaf 4K fps figure was found. MSU reports about 10 fps at 2160p multithreaded for its own implementation ([MSU](https://videoprocessing.ai/vqmt/metrics/vmaf)). Two levers:

- `n_subsample=2..4` cuts VMAF cost roughly linearly.
- `cambi_high_res_speedup=1080` runs CAMBI at 1080p.

Two UHD HEVC decodes per comparison are a real cost too.

## 5. Audio

- **Plan unchanged:** AAC-LC stereo 256k default, with fixed gain to a -1 dBTP true peak measured over the whole film, plus the original lossless track bit-for-bit.
- **TrueHD / TrueHD-Atmos:**
  - ffmpeg's `mlpdec` decodes at most three substreams (2.0, 5.1, 7.1). The Atmos 16-channel substream is skipped, so the downmix comes from the 7.1 bed ([mlpdec.c](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/mlpdec.c)). That is fine for a stereo fallback.
  - The existing 7.1 `pan` downmix applies.
  - Alternative: `-downmix stereo` on the decoder uses the encoder-authored 2.0 presentation, which may be better balanced. Compare on a real disc.
  - Playback: TrueHD over CX eARC is reported working after mid-2020 firmware, but sources conflict.
  - jellyfin-androidtv [#5595](https://github.com/jellyfin/jellyfin-androidtv/issues/5595) (open) reproduces TrueHD Atmos being transcoded on **Shield + LG OLED + soundbar**, while DD+ Atmos passes. Set the client's TrueHD bitstream preference to **Enable** (not Auto) and test one file.
- **DTS-HD MA / DTS:X (common on UHD BD):**
  - The CX has no DTS decoding or passthrough, so this track never direct-plays on this chain.
  - Options:
    1. Keep it for the archive and let Jellyfin transcode the audio only. Video still direct-plays, but the spec says zero transcoding.
    2. Add a multichannel **E-AC-3** (5.1 at 640–1024k) as track 2, keep DTS as track 3 with no default flag, and turn DTS bitstreaming off in the client [inference].
    3. Option 2 without keeping the DTS track.
  - Recommend option 2 if zero transcoding is strict.
  - ffmpeg decodes DTS-HD MA losslessly. DTS:X objects are likely dropped to the 7.1 bed [unverified].
- **Multichannel PCM / FLAC:** rare on UHD. PCM passes to the CX.

## 6. Practical

**Encode speed** [source + inference]:

| Data point | Speed | Source |
|---|---|---|
| UHD HDR, `slow` | ~6.1 fps | [t-183860](https://forum.doom9.org/showthread.php?t=183860) |
| EPYC 7502P/7543P, `slow` | ~6.3–6.4 fps | [p=1964098](https://forum.doom9.org/showthread.php?p=1964098) |
| 5900X / 12700K, `slower` | ~1.4 fps | [p=1964098](https://forum.doom9.org/showthread.php?p=1964098) |
| 9950X3D, CRF 20 `slow` | 5–10 fps | [Selur](https://forum.selur.net/thread-4342.html) |

- This machine (Ryzen 9 8945HS, 8C/16T, mobile power limits): expect roughly 2–4 fps at `slow`. A 2 h film (≈172 k frames) takes about 12–24 h; `slower` takes roughly 2–3× longer.
- Quickest real number: the 1080p `encode_fps` stored in a `.analysis` file × ~0.25–0.3 (4× pixels, slightly better than linear scaling at 4K).
- **No 4K benchmark was run**, because of the running calibration.

**Bitrate and size:**

- CRF 17 gave mostly 4–8 Mb/s on about 10 UHD titles; another poster gets "very good quality at around 15 Mb/s for most titles", and "20–25 Mb/s average makes all but the most challenging scenes look great" ([t-177619](https://forum.doom9.org/archive/index.php/t-177619.html)).
- For 2 h of video: 8 Mb/s ≈ 7 GB, 15 Mb/s ≈ 13.5 GB, 25 Mb/s ≈ 22.5 GB.
- Add the lossless audio, which is often 3–6 GB for TrueHD Atmos.

**Crop detection on HDR:**

- `cropdetect` accepts `yuv420p10le`. The default `limit` (24/255) is relative and scaled to 10-bit (about 96 code value).
- Against PQ limited black (64), that is the same normalised margin as in 8-bit ([vf_cropdetect.c](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/vf_cropdetect.c)).
- [tested]: 10-bit letterboxed synthetic `pad=…:black` detected `crop=384:160:0:28` correctly, with the log showing `limit:0.094118`.
- The 1080p sampling logic can be reused unchanged. At 4K each 2 s sample decodes 4× the pixels: about 10 × 48 UHD frames, which is still cheap.
- Use `round=4` or keep `round=2`. Both are fine for 4:2:0.
- Crop ≠ L5: use cropdetect for the picture, and `--crop` for the RPU.
- **Verify on a real file:** dark PQ scenes near black (code values 64–80) can make cropdetect over-crop. Keep the largest-area rule, and cross-check against the RPU's L5 offsets: `dovi_tool export -d level5=L5.json` gives the disc author's own active area per shot. This is a free, authoritative crop hint when the source has DV.

### Suggested structure for `x265-10bit-4k.sh`

Mirrors `x265-10bit.sh`. Shared helpers could later move to a common file. Not done here.

**Section 1: Source analysis**

- Existing container, video, audio, subtitles and chapters, plus:
  - HDR10: MDCV (primaries, min/max L), CLL (MaxCLL/MaxFALL) from first-frame side data. Warn if missing, since x265 8.1 needs master-display.
  - DV: profile, compat ID, `el_present` from the DOVI record. Extract the RPU (`dovi_tool -m 2 extract-rpu`, fast, no decode) and run `info --summary` for frames, L5, L6, and FEL/MEL.
  - HDR10+ SEI present (`hdr10plus_tool extract` or ffprobe side data): note "dropped, unsupported on Shield and CX".
  - Chroma location (expect `topleft`).
  - Crop: cropdetect votes, cross-checked with RPU L5. Warn on VAR.
- Audio: flag DTS family as "not playable on CX".
- `die` on: SDR (redirect to `x265-10bit.sh`), HLG (out of scope or separate), DV P5, height ≤ 1080.

**Section 2: Proposed conversion**

- Video: HEVC Main10 L5.1 High, HDR10 (+ DV 8.1 if source DV), x265 settings from §2. Show the derived `master-display`/`max-cll` strings and the RPU plan (mode 2, crop yes/no, frame count).
- Audio: AAC stereo default plus original lossless. If the source is DTS, add EAC3 5.1/7.1 (or a warning).
- Tags: add `HDR_FORMAT`, `DOVI_SOURCE_PROFILE` (e.g. `7 FEL`), `DOVI_CONVERSION=dovi_tool -m 2 [--crop]`.

**Section 3: Calibration**

- Same CRF walk, `.analysis` cache and fingerprint. Add the master-display, DV plan and tool versions to the fingerprint.
- Encode samples **without DV** (option (a) in §3) via ffmpeg/libx265 with the same params, so calibration doesn't need the CLI/RPU plumbing.
- Gates:
  - VMAF `vmaf_4k_v0.6.1neg`: mean ≥ 95, 1%-low ≥ 90, per scene. Start from the 1080p values and revisit after the first real film.
  - CAMBI `full_ref=true:eotf=pq` with a re-derived max.
  - XPSNR knee.
- Grid to keep cost sane: 6–8 samples × 10–15 s, CRFs (16 17 18 19 20) with the early stop already there. Consider `n_subsample=2` for VMAF and `cambi_high_res_speedup=1080`.
- Report estimated full-encode time from the measured fps.

**Section 4 (later): full encode**

- If DV: run the full RPU checks (frame count == source frame count), then `ffmpeg | x265 CLI --dolby-vision-rpu`. Otherwise use ffmpeg/libx265 directly.
- Assert the encoded RPU frame count equals the video frame count (x265 only warns on mismatch, §1).
- mkvmerge mux, mkvpropedit tags/statistics.
- Final ffprobe check: `DOVI configuration record` = P8 compat 1, MDCV and CLL present, `color_transfer=smpte2084`.

**Flake additions (when implementing):** `dovi-tool`, and `x265` (for the CLI). `hdr10plus_tool` is only needed if HDR10+ detection is done with it; ffprobe side data may be enough.

### Verify on a real UHD remux

1. ffprobe sees first-frame MDCV/CLL and the DOVI record (P7, el_present) on a MakeMKV remux.
2. `dovi_tool -m 2 extract-rpu` frame count == ffprobe frame count. Check FEL vs MEL.
3. Cropdetect vs RPU L5 agree. Check VAR titles.
4. A 1-minute DV 8.1 encode through `ffmpeg | x265` and mkvmerge plays on the Shield via Jellyfin as **Dolby Vision**. Check the TV's DV badge and the Jellyfin playback info for "Direct play".
5. The same file with TrueHD Atmos: passthrough works (client bitstream setting = Enable).
6. CAMBI `eotf=pq` scale on real content: source vs encode at a few CRFs, to set `CAMBI_MAX`.
7. Actual `slow` fps at 2160p on this machine, once the current calibration has finished.
8. libvmaf ≥ 3.2.0 (if nixpkgs bumps it): compare `vmaf_v1.0.16_1d5h_2160` with `vmaf_4k_v0.6.1neg` on the same samples.
