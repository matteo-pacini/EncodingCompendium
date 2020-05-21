#!/bin/bash

clear

##################
## Bash colours ##
##################
CLEAR='\033[00m'
RED='\033[01;31m'

#################
## Color space ##
#################

# SDR
SDR="colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited"
# HDR
CHROMALOC="2"
MAXCLL="915,70"
MASTERDISPLAY="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
HDR="transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc:chromaloc=$CHROMALOC:hdr=1:hdr-opt=1:max-cll=$MAXCLL:master-display=$MASTERDISPLAY"

#################
# x265 settings #
#################

PRESET="medium"
CRF="18"
AQ="aq-mode=2"
CTU="ctu=32:max-tu-size=16"
DEBLOCK="deblock=-2,-2"
QCOMP="qcomp=0.8"
SAO="no-sao=1:no-strong-intra-smoothing=1"
PROFILE="main10"
LEVEL="level-idc=41"
EXTRA="merange=44:qg-size=16:rc-lookahead=48:keyint=240:min-keyint=24:log-level=error"

###################
## Video Filters ##
###################

# Crop
CROPSS=300 # 5 minutes

# HDR -> SDR tonemapping
TONEMAPPING="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

##########
# Script #
##########

echo -e "${RED}Input file:${CLEAR} $(basename "$1").\n"

# Crop
echo -e "${RED}Detecting crop value...${CLEAR}"

CROP=$(ffmpeg -ss $CROPSS -i "$1" -t 1 -vf cropdetect -f null -max_muxing_queue_size 1024 - 2>&1 | awk '/crop/ { print $NF }' | tail -1)

echo -e "${RED}Detected crop value:${CLEAR} $CROP."

# Audio
ACHANNELS=$(ffprobe -v quiet -show_streams -select_streams a:0 -print_format compact=nokey=1 "$1" | cut -d '|' -f 13)

echo -e "${RED}Channel layout for first audio track:${CLEAR} $ACHANNELS."
AUDIOMAP=(-map 0:1 -map 0:1)

if [[ $ACHANNELS =~ 5\.1* ]]; then
    AUDIO=(-af channelmap=channel_layout=5.1)                                                                                            
    AUDIO+=(-c:a:0 libopus -ac:a:0 2 -b:a:0 192K -metadata:s:1 title=English\ /\ Opus\ /\ Stereo\ /\ 24\ bit\ /\ 48kHz\ /\ 192kbps)      
    AUDIO+=(-c:a:1 libopus -b:a:1 384K -metadata:s:2 title=English\ /\ Opus\ /\ 5.1\ /\ 24\ bit\ /\ 48kHz\ /\ 384kbps)                  
else                                                                                                                      
    AUDIO=(-c:a:0 libopus -ac:a:0 2 -b:a:0 192K -metadata:s:1 title=English\ /\ Opus\ /\ Stereo\ /\ 24\ bit\ /\ 48kHz\ /\ 192kbps)      
    AUDIO+=(-c:a:1 libopus -ac:a:1 6 -b:a:1 384K -metadata:s:2 title=English\ /\ Opus\ /\ 5.1\ /\ 24\ bit\ /\ 48kHz\ /\ 384kbps)        
    AUDIO+=(-c:a:2 libopus -b:a:2 512K -metadata:s:3 title=English\ /\ Opus\ /\ 7.1\ /\ 24\ bit\ /\ 48kHz\ /\ 512kbps)         
    AUDIOMAP+=(-map 0:1)         
fi

echo -e "${RED}Audio options:${CLEAR}"
echo -e "${AUDIO[@]}"

# Subtitles
echo -e "${RED}Analysing subtitles...${CLEAR}"

ENGSUBS=$(ffprobe -v quiet -show_streams -select_streams s -print_format compact=nokey=1 "$1" | grep eng)
SUBS=$(echo "$ENGSUBS" | grep SDH | head -1)
if [ -z "$SUBS" ]; then
    SUBS=$(echo "$ENGSUBS" | grep English | head -1)
    if [ -z "$SUBS" ]; then
        SUBS="N/A"
    fi 
fi

echo -e "${RED}Best candidate:${CLEAR} $SUBS"

if [[ $SUBS == "N/A" ]]; then
    SUBMAP=()
else
    SUBSTREAM=$(echo "$SUBS" | cut -d '|' -f 2)
    SUBMAP=(-map 0:"$SUBSTREAM")
fi

# FFmpeg

echo -e "${RED}Encoding is about to begin...${CLEAR}"

OUTPUT=$(basename "$1" | sed s/Remux/Bluray/)

echo -e "\n${RED}Output file:${CLEAR} $OUTPUT.\n"

sleep 1

pv "$1" | ffmpeg -loglevel error -y -i -                                                                                                 \
    -map 0:0 "${AUDIOMAP[@]}" "${SUBMAP[@]}" -map_chapters 0                                                                             \
    -vf $CROP                                                                                                                            \
    -c:v libx265 -preset $PRESET -profile:v $PROFILE -crf $CRF -pix_fmt yuv420p10le                                                      \
    -x265-params "$SDR:$AQ:$CTU:$DEBLOCK:$SAO:$QCOMP:$LEVEL:$EXTRA"                                                                      \
    "${AUDIO[@]}"                                                                                                                        \
    -c:s copy                                                                                                                            \
    "$OUTPUT"