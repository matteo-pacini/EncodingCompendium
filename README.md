# EncodingCompendium

# Software Requirements

- Handbrake

# Encoding 1080p Remux to 1080p AVC (reference quality)

- Video Codec: H264 (CPU, plz no hardware)
- FPS: Same as source
- Constant Quality: RF 16 (18 seems to be the golden quality standard, but darker scenes might still suffer with it)
- Preset: VerySlow
- Profile: High
- Level: 4.1
- Advanced Parameters: <code>deblock=-2,-2</code>

# Encoding 1080p Remux to 1080 HEVC

- Video Codec: H265-10Bit (CPU, plz no hardware)
  - 10bit compresses better and avoids color banding with SDR sources.
- FPS: Same as source
- Constant Quality: RF 18
- Preset: Medium
- Profile: Main10
- Level: 4.0
- Advanced Parameters:  <code>
colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited:aq-mode=1:aq-strength=1.0:ctu=32:max-tu-size=16:deblock=-2,-2:merange=44:qcomp=0.8:qg-size=16:no-sao</code>

## Advanced Parameters

TBW
