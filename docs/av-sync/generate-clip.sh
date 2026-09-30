#!/usr/bin/env bash
# Generates the A/V sync test clip: 8 s, 320x180@30, from second 1 on a white
# flash (2 frames) and a 40 ms 1 kHz beep every second, aligned by frame and
# sample index. Requires ffmpeg with libvpx and libopus.
set -euo pipefail
cd "$(dirname "$0")"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=320x180:r=30:d=8" \
  -f lavfi -i "aevalsrc='if(gte(n\,48000)*lt(mod(n\,48000)\,1920)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:d=8:c=stereo" \
  -filter_complex "[0:v]drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(n,30)*lt(mod(n,30),2)'[v]" \
  -map "[v]" -map 1:a -c:v libvpx -b:v 150k -g 15 -auto-alt-ref 0 -c:a libopus -b:a 64k \
  float-av-calibration.webm
echo "Wrote $(pwd)/float-av-calibration.webm"
