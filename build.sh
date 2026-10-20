#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h}
app="$project_dir/build/Usagi.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  /usr/bin/swiftc -O -target "$arch-apple-macos14.0" -framework AppKit -framework WebKit \
    "$project_dir/Usagi.swift" -o "$project_dir/build/Usagi-$arch"
done
/usr/bin/lipo -create "$project_dir/build/Usagi-arm64" "$project_dir/build/Usagi-x86_64" \
  -output "$app/Contents/MacOS/Usagi"
cp "$project_dir/bridge.py" "$app/Contents/Resources/bridge.py"
cp "$project_dir/open-browser.sh" "$project_dir/usagi.zsh" "$project_dir/usagi_accounts.py" "$project_dir/usagi_usage.py" "$app/Contents/Resources/"
chmod 755 "$app/Contents/Resources/open-browser.sh"
cp "$project_dir/index.html" "$app/Contents/Resources/index.html"
mkdir -p "$app/Contents/Resources/assets"
cp "$project_dir/assets/claude.png" "$app/Contents/Resources/assets/claude.png"
cp "$project_dir/assets/codex.png" "$app/Contents/Resources/assets/codex.png"
cp "$project_dir/assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$app" >/dev/null
echo "$app"
