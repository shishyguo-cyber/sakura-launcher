#!/bin/bash
# Run from any directory. All generation is local; no input assets or downloads.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
ffmpeg="${SAKURA_FFMPEG:-ffmpeg}"
if ! command -v "$ffmpeg" >/dev/null 2>&1; then
  printf "%s\n" "FFmpeg is optional for rebuilding the bundled demo. Set SAKURA_FFMPEG or provide ffmpeg in this command PATH." >&2
  exit 1
fi
out="launcher-macos/demo-pack"
# A static loop is intentionally identical at every frame, including the seam.
for segment in intro loop outro; do
  gop=45
  filters="drawbox=x=480:y=200:w=320:h=320:color=0x8BAF9B:t=fill,drawbox=x=520:y=240:w=240:h=240:color=0xCBD9BE:t=fill"
  case "$segment" in
    loop) gop=1 ;;
    intro) filters="$filters,fade=t=in:st=0:d=0.5" ;;
    outro) filters="$filters,fade=t=out:st=1.1:d=0.4:color=0x182B29" ;;
  esac
  "$ffmpeg" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=0x182B29:s=1280x720:r=30:d=1.5" \
    -vf "$filters" -an -c:v libx264 -preset medium -qp 20 \
    -g "$gop" -pix_fmt yuv420p -movflags +faststart "$out/$segment.mp4"
done
