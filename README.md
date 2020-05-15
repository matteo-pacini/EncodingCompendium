# EncodingCompendium

# Software Requirements

- Handbrake

# Video Encoding

## Encoding 1080p Remux to 1080p AVC (reference quality)

- Video Codec: H264 (CPU, plz no hardware)
- FPS: Same as source
- Constant Quality: RF 16 (18 seems to be the golden quality standard, but darker scenes might still suffer with it)
- Preset: VerySlow
- Profile: High
- Level: 4.1
- Advanced Parameters: <code>deblock=-2,-2</code>

## Encoding 1080p Remux to 1080 HEVC

- Video Codec: H265-10Bit (CPU, plz no hardware)
  - 10bit compresses better and avoids color banding with SDR sources.
- FPS: Same as source
- Constant Quality: RF 18
- Preset: Medium
- Profile: Main10
- Level: 4.0
- Advanced Parameters:  <code>
colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited:aq-mode=1:aq-strength=1.0:ctu=32:max-tu-size=16:deblock=-2,-2:merange=44:qcomp=0.8:qg-size=16:no-sao</code>

## Encoding 2160p HDR10 Remux to 2160p HEVC-10bit

- Video Codec: H265-10Bit (CPU, plz no hardware)
- FPS: Same as source
- Constant Quality: **EXPERIMENTING**
- Preset: **EXPERIMENTING**
- Profile: Main10
- Level: 5.1
- Advanced Parameters: <code>aq-mode=1:aq-strength=1.0:deblock=-2,-2:qcomp=0.8:no-sao:transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc:chromaloc=2:hdr:hdr-opt:max-cll=724,647:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)</code>

# Compare two inputs with identical number of frames

SSIM:

<code>ffmpeg -i main.mkv -i reference.mkv -lavfi ssim -f null -</code>
