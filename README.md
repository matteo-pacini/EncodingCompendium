# EncodingCompendium

My encoding notebook - writing things down for reference.

# Scripts

Bash scripts that convert Blu-ray remuxes to HEVC Main10 within an HEVC level, so any decoder of that level plays them:

- `hevc-1080p-sdr.sh`: 1080p SDR, Level 4.1 Main tier (20 Mb/s VBV).
- `hevc-2160p-hdr.sh`: 2160p HDR10, Level 5.1 High tier (160 Mb/s VBV), plus Dolby Vision 8.1 and HDR10+ when the source has them (Dolby Vision profile 7 is converted).
- `farm.sh`: either, whichever fits the source, spread over several hosts by SSH.

Each run probes the source and crops black bars. It then calibrates the CRF on samples of the film: per preset, the highest CRF that passes VMAF NEG mean ≥ 96, 1%-low ≥ 94 and CAMBI ≤ 2.5 in every half second. It cuts the worst sample for a look, and asks before encoding. The output has the video, a stereo AAC track, the original audio, subtitles and chapters, with the calibration in its tags. Everything goes in a folder named after the film beside the input. Measurements are cached there in a `.analysis` file, so a rerun only encodes what is new.

```
nix run 'github:matteo-pacini/EncodingCompendium?dir=nix#hevc-2160p-hdr' -- [--dry-run] [--score] [--yes] [--start-at <time>] movie.mkv
```

From a checkout: `nix develop path:./nix -c ./hevc-2160p-hdr.sh movie.mkv`.

- `--score` scores the whole output against the source after the encode, and stores the result as `FULL_*` tags.
- `--yes` encodes without asking. `--start-at 23:00` waits until then; any `date -d` time works.
- `PRESETS="medium:14,15,16;slow:16,17,18"` sets the presets and CRFs to try. Defaults: `slow:18,19,20` at 1080p, `slow:16,17,18,19,20` at 2160p.
- `VMAF_TARGET_MEAN` and `VMAF_TARGET_LOW` set the VMAF NEG gates: the mean, and the 1%-low over all samples and in every scene. Defaults: 96 and 94.
- `QCOMP` sets x265's qcomp, from 0.5 to 1.0: higher keeps more bits in complex, grainy scenes. Default: 0.7 (x265's own is 0.6).
- `SAMPLE_PERCENT` and `SAMPLE_DURATION` set how much of the film calibration encodes. Defaults: 3% in 20 s samples at 1080p, 1.5% in 12 s at 2160p.

## Several hosts

```
farm.sh --worker 'box1=nice -n 10' --worker box2 movie.mkv
```

A worker needs an SSH alias with key login, and Nix. It fetches its tools from this flake at the master's commit, so that commit must be pushed. The optional `=wrapper` runs every job on that host under the given command.

- Each host gets one slot per NUMA node, and calibration samples run on every slot.
- The video is split into ≈ 3 min chunks at scene cuts. Each chunk is cut from the source as it is sent, so the master keeps no copy of the video. The chunks are encoded on every slot, with faster slots taking more, and each chunk is scored on the slot that encoded it.
- The master joins the chunks and adds Dolby Vision and HDR10+.
- A failed chunk is retried, and an unreachable host's chunks go to the other hosts.
- `--no-local` leaves the master out of the encoding. With no `--worker`, the master encodes alone.
- Ctrl+C while the samples or chunks run is a safe shutdown: no new job starts, and the running ones finish, are scored and come home before the run ends. A second Ctrl+C aborts at once, discarding the unfinished ones.
- `--stop-at 07:00` starts no chunk that would end later, and stops there. Returned chunks are recorded in a `.chunks` file, so running the same command again carries on. The Dolby Vision RPU and HDR10+ metadata are kept too, and reused when their SHA-256 still matches.
- The whole film is always scored.

# Software Requirements

- ffmpeg
- MediaInfo

# Video Encoding

## AVC

### Encoding 1080p Remux to 1080p AVC (reference quality)

- Video Codec: H264 (CPU)
- FPS: Same as source
- Constant Quality: RF 16 (18 seems to be the golden quality standard, but darker scenes might still suffer with it)
- Preset: VerySlow
- Profile: High
- Level: 4.1
- Tune: film
- Advanced Parameters: <code>deblock=-2,-2</code>

## HEVC 10-bit

### Preset choice and rationale behind parameters

8-bit format is not being used at all, as it introduces a noticeable color banding on SDR sources.

On a Ryzen 3700X (8c/16t) the most viable preset is <code>medium</code>. It encodes with a speed of <code>1.0x</code>.

Slower presets / higher CRF are not worth pursuing, as the encoding time inflates too much, and the quality improvement is debatable.

<code>aq-mode=2</code> seems to yield the best result (both visually and according to SSIM).</br>
<code>aq-mode=1:aq-strength:1</code> is decent too, and it consumes less bitrate than <code>aq-mode=2</code>.

<code>qcomp</code> influences CRF - 0.7 to 0.8 is the community range when trying to replicate AVC quality on HEVC and CRF is <= 23. The scripts default to 0.7 (<code>QCOMP</code>).

<code>no-sao=1:no-strong-intra-smoothing=1</code> are a MUST to preserve quality and avoid blurriness.

### Encoding 1080p Remux to 1080p HEVC-10bit

See [Scripts](#scripts): `hevc-1080p-sdr.sh`.

### Encoding 2160p HDR10 Remux to 1080p HEVC-10but

Same as above, but we apply a <b>lanczos</b> scale video filter.

<code>-vf=scale=1920:800 -sws_flags lanczos</code>

See also HDR flags in the section below. HDR -> SDR tonemapping is totally not worth it.

### Encoding 2160p HDR10 Remux to 2160p HEVC-10bit

See [Scripts](#scripts): `hevc-2160p-hdr.sh`.

# Compare two inputs with identical number of frames

[SSIM](https://ece.uwaterloo.ca/~z70wang/research/ssim/):

<code>ffmpeg -i main.mkv -i reference.mkv -lavfi ssim -f null -</code>

Luminance difference (**Y**) seems to be the most noticeable.

## Interpret SSIM and PSNR

https://forum.doom9.org/showthread.php?p=1334145#post1334145

> ssim: ((1-oldssim)/(1-newssim) - 1)*100 = % improvement
>
> psnr: (new - old) / 0.05 = % improvement 

# Known bugs

## Too many packets buffered for output stream 0:1

https://trac.ffmpeg.org/ticket/6375

Solution:
<code>-max_muxing_queue_size 1024</code>

Some users report that using <code>9999</code> also worked.

## libopus - Invalid channel layout 5.1(side) for specified mapping family -1

https://trac.ffmpeg.org/ticket/5718

FFmpeg is not remapping channels for <code>5.1(side)</code> streams.<br/>
A simple audio filter can fix that: <code>-af "channelmap=channel_layout=5.1"</code>
