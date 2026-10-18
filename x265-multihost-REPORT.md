# Multi-host encoding: design report

Research for running `hevc-2160p-hdr.sh` and `hevc-1080p-sdr.sh` across several hosts. The master is this laptop. Workers are reached by SSH alias. The report covers both the section 3 calibration and the section 4 encode.

Date: 2026-10-18. Toolchain checked against nixpkgs-unstable `f20cd90e` (the rev in `nix/flake.lock`): x265 4.2+1-e444744, ffmpeg-full 9.0.1, libvmaf 3.0.0, dovi_tool 2.3.4, mkvtoolnix 102.0. x265 source was read at tag 4.2; line numbers below refer to that tag.

Labels:

- **[tested]**: checked here, using read-only commands only. An encode was running, so no encode or VMAF was run.
- **[source]**: cited (URL, or x265 source file:line).
- **[inference]**: reasoning. Verify these before relying on them.

---

## Summary

1. **Topology: the master pushes over its own outbound SSH. No reverse SSH is needed.** Workers never connect back. The master copies inputs to each worker, runs jobs there, streams progress back on the job's stdout, and copies results home. One ControlMaster connection per worker carries all of it.
2. **Workers should get a command, not a flake reference.** The master sends tools by store path (`nix copy`), checks that the store paths match, and then runs `ssh worker /nix/store/…-hevc-worker/bin/hevc-worker <subcommand>`. The proposed `nix run <flake>#… -- --master M` requires the worker to reach the master, which this design avoids.
3. **The lowest-common-asm idea is unnecessary.** x265's asm kernels are designed to be bit-exact with the C code. The testbench `memcmp`s them against C, and your avx512-vs-default runs matched. Each x86 host should keep `asm=avx512`: on hosts without AVX-512 it already warns and falls back. The things that *do* break bit-identity across hosts are different:
   - VBV, which x265 documents as non-deterministic.
   - The auto `--frame-threads` count, which differs on every host.
   - CPU architecture (x86 vs the M1).

   None of these affects seams. They only mean calibration and encode results are equivalent across hosts, not byte-identical.
4. **Calibration distributes as (preset, CRF, sample) units.** Within one CRF the 8 samples run in parallel with no speculation, so results equal a sequential run. Idle slots then take the *next* CRF speculatively. A speculative CRF is still a valid measurement and goes into `.analysis` even if the walk stops before it.
5. **Split the encode into independent, stream-copied source segments cut at IDR frames, ideally at scene cuts.** Each segment is encoded exactly as today: ffmpeg y4m piped into the x265 CLI, open GOP kept, with its own slice of the RPU. The raw HEVC chunks are concatenated with `cat`, and the existing mkvmerge step is unchanged.
   - Do **not** use `--chunk-start/--chunk-end`. They need closed GOP and are silently disabled with your current (open-GOP) flags.
6. **Moving compressed source is cheap; raw y4m is not.**
   - The John Wick video stream is 58 Mb/s. A worker encoding at 3.5 fps consumes about 8.5 Mb/s of it.
   - Raw y4m at the same speed is about 700 Mb/s, roughly 80× more, and nexus has only 1 GbE.

### Hosts found

Read-only SSH probes:

| Host | Platform | CPU | Threads | Top SIMD | Link | Free in `$HOME` | Nix |
|---|---|---|---|---|---|---|---|
| this laptop (master) | x86_64-linux, NixOS | Ryzen 9 PRO 8945HS (Zen 4) | 16 | AVX-512 | 2.5 GbE | 419 GiB | 2.34.8 |
| `nexus` | x86_64-linux, NixOS 26.11 | 2 × Xeon E5-2697 v4 (Broadwell), 2 NUMA nodes | 72 | AVX2 | **1 GbE** | 1.4 TiB | 2.34.8, flakes on, `matteo` trusted |
| `nightsprings` | **aarch64-darwin**, macOS | Apple M1 Max (8P + 2E), MacBook Pro | 10 | NEON | Wi-Fi (en0) | 311 GiB | 2.34.8, flakes on, `matteo` trusted |

Details [tested]:

- Both SSH aliases resolve to their Tailscale names (`*-ts.walrus-draconis.ts.net`). `tailscale status` shows both as `direct` over the LAN, so traffic is WireGuard-encapsulated but not relayed.
- `~/.ssh/config` sets these for `Host *`:
  - `Compression yes`. This is bad for HEVC payloads, so the scripts must override it.
  - `ControlMaster no`.
  - `ServerAliveInterval 0`.
- nexus already has the x86_64-linux x265 store path. Neither host has the ffmpeg-full path yet.
- Every package in the devShell is on cache.nixos.org for both x86_64-linux and aarch64-darwin, so workers substitute rather than build.
- nightsprings has `pmset sleep 1`: it idle-sleeps after one minute. It also has no `setsid`.

---

## 1. Topology

### Options

| | Master pushes (master ssh → worker) | Worker pulls (`--master M`, worker ssh → master) |
|---|---|---|
| Who needs keys / reachability | master only | every worker needs SSH access to the master |
| How the worker reads the source | master sends segments over the same connection | worker mounts or fetches from the master (sshfs, NFS, scp back) |
| Job state | master only; workers are stateless executors | split between master and worker; needs a queue protocol |
| Failure detection | ssh exit status plus output validation, on the master | master needs heartbeats from workers |
| Ctrl+C | master's EXIT trap cancels remote jobs | master must signal workers it doesn't control |
| Prior art | dve (GNU parallel over ssh), ffmpeg_distributed, Nix remote builders | Tdarr, Unmanic, FileFlows (all run a server with an HTTP API) |

### Recommendation: master push, no reverse SSH

Everything fits in outbound connections from the master:

- **Control and progress:** `ssh worker hevc-worker run <job>`. The job's stdout carries ffmpeg `-progress` lines back. Its stdin stays open as a liveness signal (see §6).
- **Data in:** `ssh worker hevc-worker put <job> <name> < local-file`, which is just `cat > scratch/name` on the far side.
  - This is the same as `scp`, with no second tool and no glob-prone remote path.
  - Use one put per file; never a remote glob.
- **Data out:** `ssh worker hevc-worker get <job> <name> > local-file`.
- **Multiplexing:** one `ssh -fNM` ControlMaster per worker, started in section 0 and closed with `ssh -O exit` in `cleanup`. All later calls reuse it.
  - sshd's `MaxSessions` defaults to 10 per connection [source: sshd_config(5)]. Keep at most about 6 sessions per worker: in-flight jobs plus one transfer plus a probe.
  - Bulk rates here are at most a few MB/s per worker (§5), so one multiplexed ssh process is not a crypto bottleneck. The one exception is the initial sample push (§2), at most about 1 GB.

`-R` forwarding, sshfs and NFS would only be needed if workers had to *read the master's filesystem*. Segment push makes that unnecessary.

---

## 2. What to distribute

### 2a. Calibration

**What it does today** [tested, from `lib/calibrate.sh`]:

- For each preset, `walk_preset` walks CRFs lowest first.
- For each CRF, `measure_crf` encodes and scores all `CALIBRATION_SAMPLES` cuts:
  - libx265 encode;
  - libvmaf NEG + CAMBI;
  - XPSNR.
- It pools the per-frame VMAF across samples, judges the gates, and stops at the first failing CRF. The knee gate needs the previous CRF's XPSNR.
- `.analysis` stores one row per `preset@crf`.
- The John Wick cache shows **2426 frames per CRF and 731–794 s of encode per CRF at slow**, about 3.1 fps on the master. That is encode time only; scoring time is not recorded.

**Unit of work:** `(preset, crf, sample)`. The work is pure and independent:

- **Input:** `ref<n>.mkv`. This is a stream-copied cut, about 90 MB at 58 Mb/s (≈300 frames × ≈300 KB).
- **Output:** the encode's byte size and frame count, the VMAF JSON log, the XPSNR value, and the encode seconds.

The master copies the 8 cuts to each worker once per run, about 0.7 GB per worker; nexus needs about 7 s on GbE. Pooling, the gates, the knee and the table stay on the master, unchanged.

**Scheduling the walk:**

1. Keep a queue ordered by `(rank of CRF in its preset's walk, preset, sample)`. All presets walk at once: they are independent, and preset selection happens only after every walk is done.
2. The *head* CRF of each preset (the lowest one not yet judged) has priority. Its 8 samples run in parallel across slots. This is exact: no wasted work, and the same result as sequential.
3. A slot with no head work takes samples of the **next** CRF in the same walk. This is speculation.
4. When a head CRF has all its samples, the master judges it:
   - **Pass:** the speculative CRF becomes the head.
   - **Fail:** the walk stops. Cancel queued speculative samples of that preset.
5. In-flight speculative samples:
   - If it was about to finish, let it finish and cache it. A full CRF that was measured is a valid row for a later run with other gates.
   - If the CRF is incomplete, discard it, because the cache format is per CRF.
   - Simplest rule: cancel unless more than half of the CRF's samples are done.

**Worked example** [inference]: one preset with CRFs 16–20, 3 slots, 8 samples.

- The head CRF takes ⌈8/3⌉ = 3 rounds. Round 3 has 2 head samples and 1 free slot, which takes a speculative sample.
- Speculation therefore mostly fills the tail of each CRF. That is where it pays off.

**Speed and host-normalised fps** [inference]:

- `RES_FPS` (the "Full encode ≈ h" line) is computed from summed encode seconds. Across hosts of different speed that number means nothing.
- Store the host in each sample's record and compute the estimate from the fps the encode plan will actually get, i.e. the sum over slots.
- Preset choice uses x265 preset order, not fps, so the selection logic is unaffected.

**Cache:**

- `.analysis` stays where it is: next to the input, on the master. The master is its only writer.
- Workers never see it. Each keeps a per-job scratch directory and nothing else.
- `preset_fingerprint` hashes `declare -f cut_samples measure_crf encode_sample`. Rewriting `measure_crf` for remote dispatch therefore invalidates every existing `.analysis`, including John Wick's three slow CRFs (about 40 min). Either accept that once, or move the per-sample command into a function that stays textually identical and fingerprint only that.
- Remove `asm=…` from the fingerprint input (see §3). A per-host asm value must not look like a settings change.

**Stereo gain and SHA-256** stay on the master. They read the whole file (48 GB) and are I/O-bound, so they should run *while* the workers calibrate, not after.

**The worst sample** (`cut_worst_sample`) is one more unit. Run it on any slot.

### 2b. Final encode: chunking

#### The source is clean to cut [tested]

For the John Wick remux, the source keyframes are all `IDR_N_LP`:

- `trace_headers` at 120 s, 600 s, 3000 s and 5400 s showed only NAL types 1 (`TRAIL_R`) and 20 (`IDR_N_LP`), with no CRA and no RASL.
- Keyframes come every 24 frames (1.00 s), plus extra ones at scene cuts. Over a 2-minute window there were 132 keyframes, and the off-cadence intervals (0.04–0.96 s) are the encoder's scene-cut IDRs.

A stream-copied segment that starts at any keyframe therefore decodes exactly its own frames.

This must be **checked per boundary**, not assumed:

- UHD BD HEVC can use CRA. I found no citation either way.
- If a cut lands on a CRA, ffmpeg's decoder starts with NoRaslOutputFlag and skips the RASL pictures (`hevcdec.c`). The segment then decodes fewer frames than it has packets, which shifts frame and RPU alignment [source, x265 research agent reading ffmpeg].
- For each planned boundary, run one `-ss <t> -frames:v 1 -c copy -bsf:v trace_headers` and accept NAL 19/20 (IDR) only. That is about 35 cheap calls per film. For an H.264 1080p source, accept `nal_unit_type 5`.

#### Why not `--chunk-start/--chunk-end`

- x265 defaults to open GOP. With chunking and open GOP it zeroes both values and logs *"Chunking requires closed gop structure. Disabling chunking."* (`encoder/encoder.cpp:4700-4704`) [source]. The current settings don't pass `--no-open-gop`.
- Semantics, for the record:
  - Frames before chunk-start are encoded and dropped from the bitstream.
  - Frames after chunk-end feed lookahead only (`doc/reST/cli.rst:610-622`).
  - Input frame `chunkStart-1` is forced to IDR (`encoder/slicetype.cpp:2068-2073`).
  - The emitted range is therefore 1-based inclusive [source; mapping inferred from code, untested].
  - A per-chunk RPU file must start at the first frame *fed*, because the CLI reads RPUs sequentially per input picture and `--seek` doesn't skip RPUs (`x265cli.cpp:1197-1244`) [source].
- Switching to closed GOP to use it would make the final encode differ from what calibration measured; calibration samples are open-GOP encodes. Independent segments keep the encode identical in kind to the calibration samples, which are themselves independent open-GOP encodes of IDR-started cuts. Nothing in the calibration needs re-validating.
- The cost of independent segments is limited:
  - **One extra IDR per chunk.** At a scene cut x265 would have placed an I-frame anyway. At 4K CRF 18 an IDR is about 1–2 MB, so ~35 extra IDRs is about 50 MB of ~12.8 GB, or 0.4% [inference].
  - **Lost lookahead and cutree context across the boundary.** This is minimal at a scene cut, which is the reason to prefer scene-cut IDRs.
  - **Keyint cadence restarts per chunk** (`slicetype.cpp:2163-2166`) [source]. This is harmless.

#### Chunk planning [inference, borrowed from Av1an]

1. **Keyframe list.** Run one `ffprobe -select_streams v:0 -show_entries packet=pts_time,flags` over the whole file. It is I/O-bound, a few minutes for 48 GB. Run it during calibration and cache it next to `.analysis`.
2. **Boundaries.** Use a target length L of about 3 min (4300 frames, about 20 min per chunk at 3.5 fps), which gives about 34 chunks for John Wick (145 577 frames).
   - Near each multiple of L (±15%), prefer a keyframe that follows its predecessor by fewer than 24 frames. That is the source encoder's scene-cut IDR.
   - Otherwise take the nearest cadence IDR.
   - Then verify each boundary's NAL type (above).
3. **Order: longest first** (Av1an's default `long-to-short`). Make the last few chunks shorter so the tail ends together across hosts of different speed.
4. **Segmenting.**
   - Run one pass: `ffmpeg -i "$INPUT" -map 0:"$V" -c copy -f segment -segment_frames <f1,f2,…> -reset_timestamps 1 "$PARTS/seg-%03d.mkv"`. These are exact paths with a printf pattern, not a shell glob.
   - Check each segment's packet count against the plan with `ffprobe -count_packets`, which needs no decode. The sum must equal `TOTAL_FRAMES`.
   - About 44 GB lands in `$PARTS`; the master has 419 GiB free. Add it to `NEED_BYTES`.
   - Alternative without the disk cost: cut each segment lazily, just before dispatch, with `-ss <keyframe pts> -frames:v N`. Verify the first packet's pts and the count. This is more fragile with Matroska millisecond timestamps.

#### Per-chunk Dolby Vision

When the source has DV (John Wick FraMeSToR is HDR10 only):

1. Keep `dovi_tool -m 2 [--crop] extract-rpu` once on the master, as today.
2. Slice it per chunk with `dovi_tool editor` and a `{"remove": ["0-(s-1)", "(e+1)-(N-1)"]}` JSON. Ranges are 0-based and inclusive [source: dovi_tool docs/editor.md].
3. Check each slice's frame count against the segment, and treat a mismatch as fatal. Both x265 and `inject-rpu` only warn on a mismatch [source].
4. Send the slice with the segment. The worker runs the **same** `ffmpeg | x265 --dolby-vision-profile 8.1 --dolby-vision-rpu` command as today.
5. After concatenation, the existing `extract-rpu` + `check` on the whole `video.hevc` still applies unchanged.

The alternative is one `dovi_tool inject-rpu` over the concatenated stream. It works:

- dovi_tool reorders by POC per GOP and resets at each keyframe, so concatenated independent sequences are handled [source: hevc_parser `reorder_frames`].
- But the chunks would be encoded without `--dolby-vision-profile 8.1`, which also sets the HRD/VUI signalling. That makes the encode path differ from today's.

Per-chunk slicing keeps one encode path.

#### Concatenation

- Every chunk starts with VPS/SPS/PPS and an IDR, and POC resets there. Each chunk is its own coded video sequence. `--hdr10` also turns on repeat-headers (`encoder.cpp:4680-4685`), and the HDR10 SEIs come from static params, so they are identical in every chunk [source].
- `cat seg-000.hevc seg-001.hevc … > video.hevc` is therefore a valid Annex-B stream.
  - Concatenate in a loop over the planned names, not a glob.
  - The only per-chunk difference is the x265 info SEI (the option string), which is cosmetic.
- The existing `mkvmerge … --default-duration 0:${V_FPS}p "$VIDEO_HEVC"` then muxes it as today. Av1an also concatenates x265 chunks through mkvmerge with `--default-duration` because raw HEVC has no timestamps [source: av1an-core `concat/mod.rs`].

#### VBV across joins

The settings are VBR (`cbr_flag=0`, maxrate = bufsize = 160 Mb). Each independent chunk assumes its decoder buffer starts at `--vbv-init` 0.9 (`ratecontrol.cpp:428-435`) [source].

- **When the seam is safe:** if the real buffer at the seam is at least 90% full, it is. A VBR buffer cannot overflow; it saturates. A fuller-than-assumed buffer only adds margin.
- **When it is not:** if chunk k ends draining the buffer below 90% (a heavy action scene at the cut), the deficit carries into chunk k+1 and can underflow [inference: HRD reasoning].
- **How likely:** the risk is small. The calibration shows 11.6–21 Mb/s average at slow CRF 16–18, against a 160 Mb/s cap with a 1-second buffer, so the buffer sits near full most of the time [inference].

Mitigations:

1. `--vbv-end 0.9` on every chunk except the last. The docs present it as "basic support for chunk-parallel encoding" so that compliance holds when chunks are stitched (`cli.rst:1713-1723`) [source].
   - It is best-effort: it nudges QP near the end.
   - It needs the frame count, so pass `--frames N` (known from the plan) on the y4m pipe.
2. With DV (profile 8.1 forces HRD SEI), add `--hrd-concat` to every chunk except the first. It only fires at POC 0 (`frameencoder.cpp:776`), which independent chunks have and `--chunk-start` chunks don't [source].
3. **Verify, don't trust.** Add a section 5 check that simulates the leaky bucket over the output's video packets:
   - Read `ffprobe -show_entries packet=size` in decode order.
   - Fill at 160 Mb/s, capped at 160 Mb, and remove each frame at its decode time.
   - Report the minimum fullness.

   This is cheap: one read of the output's packet index, no decode. It covers single-host encodes too.

### What stays on the master

Probe, crop, the stereo AAC, the RPU extraction, segmenting, concat, the mkvmerge mux, mkvpropedit tags and the section 5 checks all stay on the master. As requested, audio, subtitles, mux and tags are not distributed. The stereo AAC encode (a whole-film TrueHD decode) should start in the background as soon as the encode starts, rather than before the video as today.

---

## 3. Asm: is x265 output identical across SIMD levels?

**On one binary and one CPU architecture, the design intent is yes** [source]:

- The x265 testbench compares each asm primitive against its C reference with `memcmp` (`source/test/pixelharness.cpp`, e.g. :1645).
- The only float tolerance found is `ssim_end` (0.001), which affects reporting, not decisions.
- The x86 `mbtree_propagate_cost` deliberately uses DIVPD "to match to C model output" (`common/x86/mc-a2.asm`).
- I found no avx512 mismatch report.

Your local runs (avx512 vs default, medium CRF 19 and slow CRF 20) were bit-identical, which agrees with this [tested by you].

Two things about the option itself [source: `common/param.cpp:971-992`]:

- `asm=avx512` calls `cpu_detect(true)`. Without AVX-512 it logs `AVX512 is not supported` (warning level, hidden by `--log-level error`) and uses what it detects. On nexus that is AVX2.
- On non-x86 builds the value goes through `parseCpuName`. "avx512" is not an ARM CPU name, so the option is **most likely rejected as an error** on the M1 [inference from the code path; untested].

**So the lowest-common-denominator scheme is unnecessary:**

- Every x86 host keeps `asm=avx512` and gets its best kernels.
- A non-x86 host drops the `asm` key.
- Exclude `asm` from `preset_fingerprint`.

**What actually breaks bit-identity across hosts.** None of it comes from asm:

1. **VBV.** *"VBV introduces non-determinism in the encoder, at this point in time, regardless of the amount of frame parallelism."* (`doc/reST/threading.rst:189`). `level.cpp:455` prints "VBV outputs are non-deterministic!" [source].
   - Row-level VBV reads the encoded-bits statistics of rows that parallel frame encoders have finished. Which rows are finished depends on timing (`frameencoder.cpp:1843, 2039`).
   - `--const-vbv` ("consistent across runs", `cli.rst:1976`; also turned on by `--tune grain`) removes the dependence on WPP timing.
   - Your bit-identical runs suggest VBV rarely acts at these rates. 160 Mb/s is far above the content [inference].
2. **`--frame-threads`.** The number of frame threads "should have no effect on the output bitstream except when using ABR or VBV rate control" (`threading.rst:179-183`) [source], and VBV is on. The auto count differs per host (`common/threadpool.cpp:836-848`) [source]:

   | Host | Auto `-F` |
   |---|---|
   | Zen 4, 16 threads | 4 |
   | nexus, 72 threads, height > 2000 | 6 |
   | M1, 10 threads | 3 |

   x265's own regression tests force `-F` for cross-machine comparisons.
3. **CPU architecture and compiler.** x265 builds with `-ffast-math` (`source/CMakeLists.txt:589-592`). Rate control, lookahead and AQ use doubles.
   - aarch64 always has FMA, and the M1 build is clang on Darwin.
   - x86 vs NEON output is therefore **likely not bit-identical** [inference; no cross-arch MD5 report found either way].
   - SAO used to differ between compilers. `no-sao` is already set [source: x265-devel 2016].
4. **libvmaf.** The NEG and 4K models use integer feature extractors.
   - libvmaf's checkasm requires exact equality for VIF, motion and CAMBI.
   - ADM's float stages allow a 1e-4 relative tolerance on x86 (`libvmaf/test/checkasm/check_adm.c:720-725`).
   - Scores may therefore differ in the last digits between AVX2 and AVX-512 hosts [source + inference].
   - XPSNR's SIMD part is exact integer SSE; only its final double math can differ by an ulp [source].

**Does this matter?**

- **Seams: no.** Each chunk is a self-contained coded video sequence. A chunk encoded on nexus joins a chunk encoded on the master exactly as two master chunks would.
- **Calibration validity: hardly.** The gates judge 8 × 12 s samples. Sample choice dominates the noise, and differences from VBV or frame threads move a CRF's file size and VMAF in the noise floor. Three precautions [inference]:
  - Record which host encoded each sample.
  - Keep x86 and aarch64 hosts in **one** calibration only if a one-off cross-host comparison (plan step 0) shows the difference is negligible.
  - Until then, calibrate on x86 hosts only. The M1 can still encode chunks.
- **Should `-F` be pinned for the encode?** No. Pinning costs throughput on nexus, and identity isn't needed.

---

## 4. Same binaries on every host

- **The flake guarantees it per system.**
  - `nixpkgs.legacyPackages.${system}` ignores each host's own nixpkgs config and overlays.
  - The locked rev gives the same derivations.
  - Input-addressed store paths are therefore identical on every host of the same system. nexus already has the exact x265 path, `/nix/store/d9jhmdg9…-x265-4.2` [tested].
  - aarch64-darwin paths differ by construction (`f4irp2la…-x265-4.2`).
- **No `-march` problem in nixpkgs.**
  - `stdenv.hostPlatform.gcc` is `{}` for x86_64-linux, so the generic x86-64 baseline is used [tested].
  - ffmpeg-full is configured with `--arch=x86_64 --enable-runtime-cpudetect` [tested].
  - x265 detects the CPU at runtime: the local binary reports `using cpu capabilities: … AVX2` without `asm=avx512`.
  - libvmaf is built with `-Denable_avx512=true` and also dispatches at runtime [tested].
  - The same binary therefore runs correctly on Zen 4 and on Broadwell.
  - The risk would come from a host-local overlay with `gcc.arch`, which the flake's `legacyPackages` sidesteps.
- **Verification in section 0.**
  - The master evaluates the expected out-path for each worker's system: `nix eval --raw .#packages.<system>.hevc-worker.outPath`.
  - The worker's `probe` reports the store path it runs from, plus the paths of its `ffmpeg`, `x265`, `dovi_tool` and `mkvmerge` (baked in by the wrapper).
  - Any mismatch fails section 0.
  - Also print `x265 --version`, i.e. version, build info and `using cpu capabilities` with the chosen `--asm`. Show the effective SIMD level per host.

---

## 5. Moving data

John Wick numbers [tested]: 145 577 frames at 23.976 fps, video `BPS` 57.97 Mb/s, so about 302 KB per frame and 7.25 MB/s at realtime.

| Per worker at 3.5 fps | Rate | Share of nexus's 1 GbE |
|---|---|---|
| Compressed source (stream copy) | 3.5 × 302 KB ≈ **1.06 MB/s (8.5 Mb/s)** | ≈ 1% |
| Raw y4m, uncropped 3840×2160, 10-bit 4:2:0 (24.9 MB/frame) | ≈ 87 MB/s (700 Mb/s) | ≈ 70% |
| Raw y4m, cropped to about 3840×1600 (≈ 18.4 MB/frame) | ≈ 64 MB/s (515 Mb/s) | ≈ 50% |
| Encoded output returned (slow CRF 18 ≈ 12.8 GB per film) | ≈ 0.3 MB/s | negligible |

What this means:

- **Raw y4m is not literally impossible for one worker on GbE.** But it scales to only one worker per GbE link, and it makes the master decode every frame for everyone. It buys nothing. Rule it out.
- **Compressed segments.** A 3-minute segment is about 1.3 GB. It moves to nexus in about 12 s (≈ 110 MB/s minus WireGuard overhead) and takes about 20 min to encode. **Prefetch the next segment while the current one encodes**, as Unmanic's "preloading" does [source: Unmanic docs]. Then transfer time never shows.
- **sshfs/NFS: not needed.**
  - Either requires the worker to reach the master's filesystem: a reverse connection (sshfs over `-R`), or an NFS export to set up.
  - Seeking would work. ffmpeg input `-ss` jumps by Matroska Cues and reads one GOP.
  - At about 1 MB/s per worker, throughput isn't the issue either [source: ffmpeg docs; sshfs/NFS throughput is well above this in any benchmark].
  - It adds a mount whose failure modes ("Cannot open input file", stale mounts) dominate RipBot264's support threads [source: doom9, videohelp].
- **SSH options for transfers:**
  - `-o Compression=no`, because the global `Compression yes` would zlib incompressible HEVC on one core.
  - Optionally `-c aes128-gcm@openssh.com`, about 1.5× chacha20 with AES-NI [source: openssh-bugs 2020 benchmark]. Neither matters at these rates except for the initial calibration sample push.
- **Wall time** [inference; measure in calibration]:
  - One host at 3.5 fps needs **11.6 h** for John Wick.
  - The speed-up is the sum of slot fps over 3.5.
  - nexus's real 4K slow fps on two NUMA-pinned instances is unknown. Broadwell at 2.3 GHz without AVX-512, but 36 cores. Calibration measures it for free, because every sample records its host and seconds.

---

## 6. Robustness

**Process model on the worker** [inference, from the cleanup gaps found in prior art]:

- `hevc-worker run <job>` runs the job script with job control on (`set -m`), so the pipeline gets its own process group. It writes the PGID to `scratch/<job>/pgid`.
  - `set -m` rather than `setsid`, because macOS has no `setsid`.
- A watchdog `( cat >/dev/null; kill -TERM -"$pgid"; … ) &` reads the session's stdin. When the master's ssh client dies for any reason (Ctrl+C, crash, network loss caught by ServerAlive), sshd closes that stdin, and the watchdog kills the group and removes the job's scratch.
- This matters because, **without a pty, killing the local ssh client does not signal the remote command** [source: openssh-unix-dev; pytranscoder docs warn that Ctrl+C leaves remote ffmpeg running].
- Don't use `-tt` to get SIGHUP instead:
  - A pty mangles binary output and merges stderr into stdout.
  - It interacts badly with multiplexing [source: nix-dev 2011].
- The master keeps the job's stdin open by feeding it from a never-ending process. Closing it means "cancel".

**Ctrl+C on the master.** `cleanup` gains a step *before* `kill_tree $$`:

1. For each worker, run `ssh -o ConnectTimeout=5 worker hevc-worker cancel <run-id>` in the background, bounded by `timeout 10`. It kills every recorded PGID of this run and runs `rm -rf` on that run's scratch.
2. Then the usual `kill_tree`. The watchdog covers the case where the cancel can't get through.
3. Then `ssh -O exit` on each ControlMaster.

The run-id is `<master hostname>-<pid>-<epoch>`, so two masters never collide.

**Failure and retry** (Av1an `--max-tries`, dve `--retries`) [source]:

- A job fails when any of these happens:
  - non-zero exit;
  - ssh exit 255 (connection);
  - the output frame count differs from the plan (`ffprobe -count_packets` on the returned `.hevc`, parser only);
  - with DV, the RPU count differs.
- On failure, requeue the chunk on a different host if possible. After 3 tries, fail the run.
- A host that fails twice in a row is dropped from the pool, with a warning. The master's own slot never is.
- Liveness: `ServerAliveInterval=15`, `ServerAliveCountMax=3`. A dead worker is detected in about 45 s, versus never with the current `ServerAliveInterval 0`.

**Resume.**

- Today the EXIT trap deletes `$PARTS` because an interrupted encode cannot be resumed.
- Chunking makes resume possible. Keep `chunks.json` (the plan) and one `done/<chunk>` record per finished chunk: frames, bytes, sha256, host. Write each record with tmp + `mv`.
- A rerun with the same plan fingerprint (source and settings) skips finished chunks. This is Av1an's `done.json`, made atomic [source: av1an-core `context.rs`].
- Keeping `$PARTS` on Ctrl+C changes current behaviour, so make it the default only in multi-host mode, or behind `--resume`.

**Progress.**

- Each job's stdout is ffmpeg's `-progress` stream, as in today's `encode_video`. The master tags each line with its chunk.
- One aggregator process keeps `frames_done` (finished chunks plus in-flight frames) and the summed instantaneous fps, and writes synthetic `frame=`, `fps=`, `total_size=` and `progress=continue` lines into the **existing `render_progress`**. The bar, ETA and projected size work unchanged against `TOTAL_FRAMES`.
- Below it, one line per slot (host, chunk, %, fps) reuses calibration's `draw_block`/`STEP_NAMES` live block.
- `PROGRESS_SIZE_FILE` becomes the sum of returned chunk sizes plus the in-flight sizes reported by the worker.

**Laptop workers.**

- nightsprings idle-sleeps after one minute. The worker must wrap jobs in `caffeinate -i` on Darwin.
- It is on Wi-Fi, and possibly on battery.
- Treat it as an optional slot: in the pool only when listed, and retried elsewhere on failure.

**Where things live:**

| Item | Location |
|---|---|
| `.analysis`, keyframe list, chunk plan, done records, segments, concat, output | master, next to the input |
| Per-run scratch on workers | `${XDG_CACHE_HOME:-$HOME/.cache}/encoding-compendium/<run-id>/`, removed by `cancel` or at the end of the run |
| Stale scratch from SIGKILLed runs | `hevc-worker gc` removes run directories older than a day, called in section 0 |

---

## 7. Required setup

### SSH

Passed by the script with `-o`, so `~/.ssh/config` doesn't change:

```
-o BatchMode=yes -o ConnectTimeout=10
-o ControlMaster=auto -o ControlPath="$WORK/ssh-%C" -o ControlPersist=yes
-o ServerAliveInterval=15 -o ServerAliveCountMax=3
-o Compression=no -T
```

- Start each ControlMaster explicitly in section 0 with `ssh -fNM`.
- Close it with `ssh -O exit` in `cleanup`.
- `%C` is a hash of the connection, which keeps the socket path short.
- `BatchMode` makes a missing key or an unknown host key fail section 0 instead of prompting.
- The existing `~/.ssh/mesh` key with certificates already works non-interactively for both hosts [tested].

### Nix on workers

Requirements:

- Nix with `nix-command flakes`.
- Either the user in `trusted-users`, or the master's signing key trusted. Both hosts already have `matteo` trusted [tested].
- No daemon changes. No flake checkout on the worker.

Ways to get the tools there:

- **Same system as the master** (nexus):
  1. `out=$(nix build --no-link --print-out-paths .#hevc-worker)`.
  2. `nix copy -s --to ssh-ng://nexus "$out"`. `-s` lets nexus substitute from cache.nixos.org instead of receiving everything over the link [source: nix3-copy].
  3. Run `ssh nexus "$out/bin/hevc-worker" …`.
- **Other system** (nightsprings):
  1. `nix flake archive --to ssh-ng://nightsprings .` copies the flake source and its locked inputs.
  2. `ssh nightsprings nix build --no-link --print-out-paths /nix/store/<…>-source#hevc-worker` substitutes and builds the trivial wrapper.
  3. Compare the printed path with the master's `nix eval .#packages.aarch64-darwin.hevc-worker.outPath`.

Rejected options:

- `git+ssh` would require the worker to reach a git remote and the master to push first.
- `path:` would copy the working directory.

### The flake must move to the repo root

A flake can only reference files inside its own source tree. With `path:./nix`, `../hevc-2160p-hdr.sh` and `../lib` are outside it.

Move `flake.nix` and `flake.lock` to the root and reference them as `git+file:` (the default for `.` in a git repo):

- Only **tracked** files are copied to the store.
- With `path:.`, the 48 GB John Wick MKV in the repo root would be copied into the store on every evaluation.
- Before committing, add a `.gitignore` for `*.mkv`, `*.analysis`, `*.partial/` and `*_worst_sample.mkv`.

Packages, built with `writeShellApplication` and `runtimeInputs` so PATH is fixed and GNU tools are used on Darwin too:

- **`hevc-2160p-hdr`** and **`hevc-1080p-sdr`**: the entry scripts plus `lib/`. Runtime inputs: ffmpeg-full, x265, dovi-tool, mkvtoolnix-cli, jq, coreutils, gawk, gnused, gnugrep, procps, openssh, nix.
- **`hevc-worker`**: the small executor (§8). Runtime inputs: ffmpeg-full, x265, dovi-tool, jq, coreutils, gawk, gnused, procps, and `caffeinate` from the system on Darwin.

Plus `apps` for the two entry scripts. Keep the devShell.

### Per worker, section 0 checks

One `hevc-worker probe` call returns JSON. The master prints one line per host and fails the verdict on any ✖.

| Check | How |
|---|---|
| Reachable, non-interactive | the ControlMaster starts with BatchMode |
| Nix present, flakes on | `nix --version`, `nix config show experimental-features` |
| Identical toolchain | worker's own store path and its tools' paths == master's `nix eval` for that system |
| Cores, NUMA nodes → slots | `nproc`; `lscpu` NUMA count (Linux); `sysctl hw.perflevel0.physicalcpu` (Darwin) |
| CPU flags → asm value | `/proc/cpuinfo` flags or `uname -m`; plus the `using cpu capabilities` line from `x265 --version` |
| x265 10-bit core + `--dolby-vision-rpu` | same test as `require_x265_cli` |
| ffmpeg filters/encoders | `require_ffmpeg_filters libvmaf xpsnr setparams crop`, `require_ffmpeg_encoders libx265` |
| libvmaf model + CAMBI options | `require_vmaf "$VMAF_OPTIONS"` (two 0.1 s 640×360 test clips) |
| Free scratch space | `df` on the scratch dir. At least 2 segments + 1 chunk output + 1 GB of samples, e.g. 3 × 1.5 GB + 1 GB for 4K |
| Sleep inhibitor | `caffeinate` on Darwin |
| Stale scratch | `gc` |

The existing `require_*` functions become the worker's probe body, so local and remote checks share code.

---

## 8. Prior art

| Project | Borrow | Avoid |
|---|---|---|
| **Av1an** (rust-av/Av1an) | Longest-first chunk order. A persisted chunk plan plus `done.json` with frame counts for resume. `--max-tries` 3. mkvmerge concat of `.hevc` chunks with `--default-duration`, since the ffmpeg concat "does not work with x265". `hybrid` chunking: copy-segment at keyframes, then frame-select inside [source]. | `select` chunking: quadratic decode. `done.json` is rewritten non-atomically. With about 1300 chunks, mkvmerge hits the open-file limit (#547). Av1an has no multi-host mode (#899 is open; `ferris_swarm` uses gRPC nodes) [source]. |
| **dve** (tdaede/dve) | The minimal form of this design: `ffmpeg -f segment -c copy`, GNU parallel over ssh, `--retries 2`, return files [source]. | ffmpeg concat-demuxer join. Keyframe cuts without a frame-count check. |
| **ffmpeg_distributed** (Rouji) | Failed tasks go back on the queue. `-r` resume. Streams segments `ssh host ffmpeg -i pipe: … pipe:` with no temp files [source]. | It re-encodes segments losslessly to get frame-exact cuts. Our source's IDR-only boundaries make that unnecessary. |
| **RipBot264** | Resume "from the last completed chunks". Chunks start at source keyframes [source: doom9]. | Workers read the master's SMB share. Most of its support threads are about that share. |
| **Tdarr / Unmanic / FileFlows** | Unmanic's preloading (send the next task before the worker is idle). Unmanic's optional checksums on transfer [source]. | Shared mapped paths, a server with an API, and nodes that pull. Too much machinery for 2–3 hosts. |
| **x265's own chunk mode** | Pre-roll for rate-control context; doom9 advice is pre-roll ≥ max(keyint, fps·bufsize/maxrate) [source]. | It forces closed GOP, which makes the encode differ from calibration (§2b). |
| **Nix remote builders** | Pin tools by store path; `nix copy -s --to ssh-ng://` [source]. | — |

---

## Recommended design

1. `hevc-2160p-hdr.sh [--dry-run] [--workers nexus,nightsprings] <input.mkv>` (the 1080p script likewise).
   - A comma list keeps `parse_args` unambiguous.
   - The master is always a slot unless `--no-local` is given.
   - Without `--workers`, behaviour is exactly today's.
2. **Section 0** checks the local requirements as today, then starts a ControlMaster per worker, installs or verifies `hevc-worker` by store path, and runs `probe`. Results:
   - Slots per host: one per NUMA node on Linux, and one on the M1.
   - The asm value per host.
   - The set of hosts allowed to calibrate (same system as the master, unless enabled).
3. **Sections 1 and 2** are unchanged and run on the master.
4. **Section 3:**
   - Copy the sample cuts once per calibrating host.
   - Dispatch `(preset, CRF, sample)` units: head CRF first, speculation in idle slots.
   - Aggregate on the master into `.analysis`, with the host per sample.
   - Meanwhile the master's I/O runs the stereo gain, SHA-256 and the keyframe scan.
   - Decision and table are as today. The fps estimate is the sum over slots.
5. **Section 4:**
   - Plan scene-cut IDR boundaries (verifying the NAL types) and segment with stream copy.
   - Slice the RPU per chunk.
   - Dispatch longest first, prefetching the next segment.
   - Encode on each slot with today's `ffmpeg | x265` command, plus `--frames N`, `--vbv-end 0.9` (all but the last chunk) and `--hrd-concat` (DV, all but the first).
   - Pull, verify and record each chunk.
   - Meanwhile encode the stereo track locally.
   - Concatenate, then run the existing RPU check and mkvmerge.
6. **Section 5:** today's checks plus a VBV leaky-bucket simulation, chunks per host, and per-host fps.

## Implementation plan

0. **One-off measurements** before writing code. These are CPU-heavy, so run them after the current encode finishes.
   1. Encode one calibration sample with identical args on the master, on nexus with `asm=avx512` (which falls back) and on the M1 without asm. Compare MD5, size, VMAF NEG and CAMBI.
      - This decides whether the M1 may calibrate.
      - It confirms §3 and gives per-host fps.
   2. Encode a 10-minute excerpt whole and as 3 independent IDR-started chunks. Compare total size, VMAF across the seams, and the leaky-bucket minimum.
      - This confirms that the seam cost is about 0.4% and that the VBV is safe.
   3. On nexus, compare one x265 with 72 threads against two instances with `--pools "+,-"` / `"-,+"`. Pick the slot layout.
1. **Flake at the root.**
   - Move `nix/flake.nix` and `flake.lock` to the root, and add `.gitignore` for the media files.
   - Add `packages.<system>.{hevc-2160p-hdr,hevc-1080p-sdr,hevc-worker}` (`writeShellApplication`) and `apps`.
   - Update the `nix develop path:./nix` hints in the scripts, `requirements.sh` and the README.
2. **`bin/hevc-worker`** (bash, portable to Darwin through the GNU runtime inputs), with these subcommands:
   - `probe`
   - `put <run> <name>` (stdin to file)
   - `get <run> <name>` (file to stdout)
   - `run <run> <job> <script-name>`: runs a master-written job script, using `set -m`, a PGID file, the stdin watchdog, and `caffeinate -i` on Darwin
   - `cancel <run>`
   - `gc`

   It is a generic executor. All encode and scoring commands are written by the master with `printf %q`, so the logic and its fingerprint stay in one place.
3. **`lib/remote.sh`.**
   - `--workers` parsing.
   - An `ssh_w` wrapper with the §7 options, plus ControlMaster start and stop.
   - Install or verify the worker by store path.
   - `remote_put`, `remote_get`, `remote_run` (progress lines tagged and returned on stdout) and `remote_cancel_all`, hooked into `cleanup` before `kill_tree`.
4. **Section 0.** `require_workers`: probe, a one-line table per host, store-path equality, and the slot/asm/calibration-eligibility decisions. Fold into `requirements_verdict`.
5. **A slot scheduler** in bash.
   - A job queue file, one background `remote_run` per busy slot, and `wait -n` to collect.
   - Retry and requeue, dropping failing hosts.
   - Used by both sections 3 and 4.
6. **Calibration.**
   - Split `measure_crf` into a per-sample job and a per-CRF aggregate.
   - Speculative dispatch in `walk_preset`.
   - Host recorded per sample, and `asm` excluded from `preset_fingerprint`.
   - Accept one invalidation of the existing caches, or keep the per-sample command function textually stable.
7. **The encode.**
   - Keyframe scan (cached), boundary planner with the NAL-type check, `-f segment -segment_frames` and packet-count checks.
   - RPU slicing with `dovi_tool editor`.
   - Dispatch with prefetch, aggregated progress into `render_progress`, chunk verification and done records.
   - `cat` concat, then the unchanged RPU check and mkvmerge.
   - `NEED_BYTES` gains the segment size.
8. **Section 5.** VBV leaky-bucket check for every encode, plus a per-host summary.
9. **1080p.** Its encode is one ffmpeg pass that also muxes audio and subtitles. Chunking it means switching to the 2160p structure: raw HEVC chunks via `-f hevc`, the stereo track separately, then mkvmerge. Do it after the 4K path is proven.
   - Blu-ray AVC sources often use open GOP with non-IDR I-frames. The boundary check (NAL 5 only) is mandatory there.
10. **Docs.** README sections on setting up a worker: keys, trusted user, nothing else to install.

## Open questions

- Whether `asm=avx512` errors on aarch64. It follows from the code, but is untested.
- Whether x86 and M1 calibration results agree closely enough (plan step 0.1).
- Real nexus throughput and the best slot layout (step 0.3).
- Whether UHD BD remuxes other than this one use CRA keyframes. The per-boundary NAL check handles it either way.
- Whether `--vbv-end` measurably changes quality at chunk ends (step 0.2).
