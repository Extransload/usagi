#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h}
app="$project_dir/build/Usagi.app"
resources="$app/Contents/Resources"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$resources/assets"
# Swift 5 mode is pinned: Xcode 15 (the macOS 14 runner) has no Swift 6 mode. The sources also build clean with -swift-version 6.
for arch in arm64 x86_64; do
  /usr/bin/swiftc -O -swift-version 5 -module-name Usagi -target "$arch-apple-macos14.0" -framework AppKit -framework WebKit \
    "$project_dir"/Sources/*.swift -o "$project_dir/build/Usagi-$arch"
done
/usr/bin/lipo -create "$project_dir/build/Usagi-arm64" "$project_dir/build/Usagi-x86_64" \
  -output "$app/Contents/MacOS/Usagi"
cp "$project_dir/bridge.py" "$project_dir"/usagi_*.py "$project_dir/open-browser.sh" "$project_dir/usagi.zsh" \
  "$project_dir/index.html" "$resources/"
chmod 755 "$resources/open-browser.sh"
cp "$project_dir/assets/claude.png" "$project_dir/assets/codex.png" "$resources/assets/"
cp "$project_dir/assets/AppIcon.icns" "$resources/AppIcon.icns"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
if [[ ${USAGI_SOURCE_INSTALL:-} == 1 ]]; then
  : > "$resources/source-install"
fi
/usr/bin/xattr -cr "$app"
/usr/bin/codesign --force --options runtime --sign - "$app" >/dev/null
echo "$app"
