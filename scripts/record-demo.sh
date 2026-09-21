#!/bin/bash
# Record the hero GIF for the README: menu bar + dropdown, ~8 seconds.
# 1. Set Menu Bar Style → Two-line Pill, make sure Claude shows a non-zero %.
# 2. Run this, then within 3s click the UsageBar item and hover the rows.
set -e
command -v ffmpeg >/dev/null || { echo "brew install ffmpeg"; exit 1; }
OUT=demo.mov
echo "recording top-right 700x500 in 3s…"; sleep 3
# -R x,y,w,h  (top-right corner of the main display)
W=$(system_profiler SPDisplaysDataType | awk '/Resolution/{print $2; exit}')
screencapture -v -V 8 -R $((W/2-700)),0,700,500 "$OUT"
ffmpeg -y -i "$OUT" -vf "fps=12,scale=700:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" demo.gif
echo "→ demo.gif  (add to README: ![UsageBar](demo.gif))"
