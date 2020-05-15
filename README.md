# EncodingCompendium

My encoding notebook - writing things down for reference.

# Software Requirements

- Handbrake
- MediaInfo

# Video Encoding

## Encoding 1080p Remux to 1080p AVC (reference quality)

- Video Codec: H264 (CPU)
- FPS: Same as source
- Constant Quality: RF 16 (18 seems to be the golden quality standard, but darker scenes might still suffer with it)
- Preset: VerySlow
- Profile: High
- Level: 4.1
- Tune: film
- Advanced Parameters: <code>deblock=-2,-2</code>

## Encoding 1080p Remux to 1080 HEVC

- Video Codec: H265-10Bit (CPU)
  - 10bit seems to compress better and doesn't introduce color banding with SDR sources (like 8-bit HEVC does).
- FPS: Same as source
- Constant Quality: RF 18
- Preset: Medium
- Profile: Main10
- Level: 4.0
- Tune: none
- Advanced Parameters:  <code>
colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited:aq-mode=1:aq-strength=1.0:ctu=32:max-tu-size=16:deblock=-2,-2:merange=44:qcomp=0.8:qg-size=16:no-sao</code>
    - <code>colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited</code> SDR
    - <code>aq-mode=1</code> requires more bitrate, but gives a better result overall
    - <code>ctu=32:max-tu-size=16</code> [Suggested](https://forum.doom9.org/showthread.php?t=172458) C.T.U. values for 1080p
    - <code>qcomp=0.8</code> seems to be necessary if CRF<=23 if we want to compete with AVC quality
    - <code>no-sao</code>, as it would blur the image a lot - it may work wonders with grainy movies though.

## Encoding 2160p HDR10 Remux to 2160p HEVC-10bit

- Video Codec: H265-10Bit (CPU)
- FPS: Same as source
- Constant Quality: **EXPERIMENTING**
- Preset: **EXPERIMENTING**
- Profile: Main10
- Level: 5.1
- Tune: none
- Advanced Parameters: <code>aq-mode=1:aq-strength=1.0:deblock=-2,-2:qcomp=0.8:no-sao:transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc:chromaloc=2:hdr:hdr-opt:max-cll=724,647:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)</code>
    - <code>transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc:hdr:hdr-opt</code> HDR
    - <code>chromaloc=2</code> check this on the source file with MediaInfo, make sure it's the same
    - <code>max-cll=724,647</code> check this on the source file with MediaInfo, make sure it's the same
    - <code>master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)</code> P3 display specification

# Compare two inputs with identical number of frames

SSIM:

<code>ffmpeg -i main.mkv -i reference.mkv -lavfi ssim -f null -</code>

Luminance difference (**Y**) seems to be the most noticeable.
