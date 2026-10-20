#!/bin/zsh
# Regenerates assets/AppIcon.icns, assets/claude.png and assets/codex.png from their SVG sources.
# Needs Google Chrome for SVG rendering.
set -euo pipefail
project_dir=${0:A:h}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
work=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$work"' EXIT

render() {  # render <svg> <png>: 1024×1024 with a transparent background
  {
    print -r -- '<!doctype html><style>html,body{margin:0;background:transparent}svg{display:block;width:1024px;height:1024px}</style>'
    cat "$1"
  } > "$work/render.html"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$2" "file://$work/render.html" >/dev/null 2>&1
}

render "$project_dir/assets/AppIcon.svg" "$work/icon.png"
mkdir "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z $size $size "$work/icon.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z $((size * 2)) $((size * 2)) "$work/icon.png" \
    --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$work/AppIcon.iconset" -o "$project_dir/assets/AppIcon.icns"
echo "$project_dir/assets/AppIcon.icns"

for provider in claude codex; do
  render "$project_dir/assets/$provider.svg" "$work/$provider.png"
  /usr/bin/sips -z 128 128 "$work/$provider.png" --out "$project_dir/assets/$provider.png" >/dev/null
  echo "$project_dir/assets/$provider.png"
done
