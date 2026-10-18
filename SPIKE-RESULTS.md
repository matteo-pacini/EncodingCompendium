# Multi-host spike: results

Branch `farm-spike`, 2026-10-18. Design: [x265-multihost-REPORT.md](x265-multihost-REPORT.md). Scripts: [spike/](spike/).

**Verdict: go.** Spreading a 4K encode over the three hosts is 2.7× faster than BrightFalls alone, and about 3.2× with balanced chunks. Joins don't show in the metrics or to the eye. The decoder buffer stays valid across them.

## Hosts

| Host | Role | CPU | SIMD x265 uses | Slots |
|---|---|---|---|---|
| brightfalls | master and worker | Ryzen 9 PRO 8945HS (Zen 4), 16 threads | AVX-512 (only with `--asm avx512`) | 1 |
| nexus | worker, under `with-fans 50 --` | 2 × Xeon E5-2697 v4 (Broadwell), 72 threads | AVX2 (`--asm avx512` warns and falls back) | 2, one per NUMA node |
| nightsprings | worker, under `caffeinate -i` | Apple M1 Max, 10 threads | NEON + DotProd (`--asm avx512` is an error: drop it) | 1 |

## Results

### 1. Tools (`spike/probe.sh`)

- Each worker ran `nix shell 'github:…/<commit>?dir=nix#tools'`, and every binary came from cache.nixos.org.
  - nightsprings bootstrapped in 10 s, nexus in 19 s.
  - Only the small `tools` wrapper was built locally.
- nexus runs exactly BrightFalls's store paths: x265 `d9jhmdg9…`, ffmpeg `7172h3q4…`.
- aarch64-darwin evaluates, and all five tools are in the cache. libvmaf, xpsnr, cropdetect and setparams all work there.
- No `nix copy` was needed.

### 2. Same segment on every host (`spike/speed.sh`)

The segment was 60 s (1,453 frames) of John Wick's worst scene (0:44:06), at slow CRF 17, with all three hosts encoding at once.

| Host | fps | Size | MD5 | NEG | 1%-low | CAMBI | XPSNR |
|---|---|---|---|---|---|---|---|
| brightfalls | 2.54 | 107.63 MiB | 206f4632… | 98.291 | 92.68 | 0.776 | 41.736 |
| nexus (1 instance) | 1.88 | 107.63 MiB | 778057fc… | 98.291 | 92.68 | 0.776 | 41.736 |
| nightsprings | 2.98 | 107.62 MiB | de27c7f6… | 98.292 | 92.66 | 0.719 | 41.736 |

- **Bytes differ, quality doesn't.** No two outputs are byte-identical, not even on the same x86 binary: x265 documents VBV as non-deterministic.
  - The two x86 encodes still score identically.
  - The M1 is within noise of them.
- **Scoring is host-independent.** All three hosts score the same encode identically, so every host can calibrate.
- **Transfer:** 81 MiB/s to nexus and 50 MiB/s to nightsprings over Wi-Fi. A slot needs about 1 MiB/s.

### 3. Slots on nexus (`spike/slots.sh`)

| Layout | fps |
|---|---|
| 1 x265 over all 72 threads | 1.88 |
| 2 at once, each pinned to a NUMA node (`--pools`, plus `taskset` for ffmpeg) | 1.82 + 1.81 = **3.61** (1.92×) |

### 4. Chunked encode (`spike/chunks.sh`)

A 10-minute excerpt (14,398 frames, from 0:40:00) was split into 4 chunks at source keyframes on scene cuts. Each slot encoded one chunk, and the results were joined with `cat` and muxed with the original audio.

| Slot | Frames | fps |
|---|---|---|
| brightfalls | 4,052 | 3.38 |
| nexus node 0 | 2,761 | 2.47 |
| nexus node 1 | 3,127 | 1.98 |
| nightsprings | 4,458 | 2.89 |

- **Speed:** 26 min 22 s wall time, **9.10 fps**, against about 71 min for BrightFalls alone.
- **Balance:** nexus node 0 finished 7 min before node 1. The chunk sizes came from earlier speed figures, which didn't hold on this content.
- **Frames:** all 14,398 present; size 959 MiB (13.4 Mb/s).
- **Decoder buffer** (160 Mb/s, 160 Mb, starting 90% full, `--vbv-end 0.9` on all but the last chunk): no underflow; the lowest fullness was 89.3%.
- **Joins:** the ±2 s around each join, against a control encoded without the join.

  | Join | Chunked mean / min / CAMBI | Control mean / min / CAMBI | Δ mean |
  |---|---|---|---|
  | 1 · 2:49.0 | 96.74 / 93.0 / 0.026 | 96.74 / 93.0 / 0.351 | +0.00 |
  | 2 · 4:44.2 | 97.23 / 94.9 / 0.030 | 97.28 / 95.0 / 0.006 | −0.05 |
  | 3 · 6:54.6 | 97.15 / 93.9 / 0.004 | 97.17 / 94.1 / 0.104 | −0.02 |

- **Human QA** (mpv on BrightFalls, at each join): no join visible.
- **Mid-scene joins can band.** An earlier 30 s test cut at keyframes regardless of scenes.
  - One chunk opened mid-scene on dark content, and its first frame (an IDR with cold rate control) scored VMAF 77.7 against the control's 87.1, with CAMBI 6.05 against 0.02.
  - The banding faded over about 10 frames. The other two mid-scene joins were clean.
  - Placing joins on scene cuts removed it.
  - On this dark film, ffmpeg's `scdet` needs a threshold of 5, not its default 10: at 10 it found 6 cuts in 10 minutes, against 82 at 5.

### 5. Failures (`spike/failures.sh`)

| Test | Result |
|---|---|
| A · Ctrl+C on the master (ssh client killed mid-encode) | ✘ **The remote encode keeps running**: nexus still ran 60 s later, and nightsprings ran to completion. ffmpeg ignores the closed progress pipe. |
| B · A worker's x265 killed mid-encode | ✔ ssh exits 137. The segment, rescheduled on nightsprings, came back with all 1,453 frames. nexus kept 9 MiB of partial output. |
| C · Unreachable worker | ✔ ssh exits 255 after the 10 s `ConnectTimeout`. |

## What this means for the farm script

1. **Boundaries go on scene cuts:** source keyframes with an scdet score above 5. Mid-scene joins are a last resort, and they get flagged.
2. **Many small chunks from a queue,** not one chunk per slot. A free slot takes the next chunk, so speed differences between slots and between scenes even out.
3. **Missing segments are retried until 100%.** When every slot has finished or failed, the master checks every segment for presence and full frame count. It reschedules the missing ones on the hosts still up, and repeats. Partial output on a failed host is deleted, never used.
4. **Remote cancel is explicit.** The ssh client dying doesn't stop a remote job. Each job runs as its own process group under a stdin watchdog: when stdin closes, the group is killed. On Ctrl+C, the master's cleanup also runs a cancel on every worker.
5. **Slots are automatic:** one per NUMA node (read from `/sys/devices/system/node`), pinned with x265 `--pools` plus `taskset`.
6. **asm per architecture:** `--asm avx512` on every x86 host, none on ARM.
7. **Workers need only SSH keys, Nix and an optional wrapper:** `--worker 'nexus=with-fans 50 --' --worker 'nightsprings=caffeinate -i'`. Code and tools come from `nix run`/`nix shell` pinned to a commit.
8. **The UI has one progress bar per slot,** with fps and ETA, plus the totals.

## Not covered

- **Dolby Vision.** The plan keeps it on the master: workers encode plain HDR10 chunks, and the master adds the source RPU to the joined stream with `dovi_tool inject-rpu`, then checks that every frame has one. Two things are untested for lack of a DV source: the x265 HRD flags chunks need without `--dolby-vision-profile`, and whether the Shield/CX show Dolby Vision.
- **A full film end to end:** the longest test was 10 minutes.
- **A worker dropping its network mid-job** (as opposed to its process failing). It should look like test B plus test C, but nobody pulled a cable.
