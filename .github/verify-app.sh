#!/bin/zsh
# Checks a built Usagi.app: ./.github/verify-app.sh path/to/Usagi.app [X.Y.Z]
# Used by CI, the release workflow and release.sh, so all three check the same things.
set -euo pipefail
app=${1:?usage: verify-app.sh path/to/Usagi.app [version]}
want_version=${2:-}
bin="$app/Contents/MacOS/Usagi"
fail() { print -u2 -- "verify-app: $*"; exit 1; }

[[ -x $bin ]] || fail "missing executable $bin"
for f in Info.plist Resources/bridge.py Resources/index.html; do
  [[ -f $app/Contents/$f ]] || fail "missing Contents/$f"
done
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
[[ -z $want_version || $version == "$want_version" ]] || fail "version is $version, expected $want_version"
[[ $(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist") == 14.0 ]] \
  || fail "LSMinimumSystemVersion is not 14.0"

archs=$(/usr/bin/lipo -archs "$bin")
for arch in arm64 x86_64; do
  [[ " $archs " == *" $arch "* ]] || fail "$arch slice missing (found: $archs)"
  minos=$(/usr/bin/vtool -arch "$arch" -show-build "$bin" | /usr/bin/awk '$1 == "minos" {print $2}')
  [[ $minos == 14.0 ]] || fail "$arch minos is '$minos', expected 14.0"
done

/usr/bin/codesign --verify --strict --deep "$app" || fail "codesign verification failed"
signature=$(/usr/bin/codesign -d --verbose=2 "$app" 2>&1)
[[ $signature =~ 'flags=0x[0-9a-f]+\(([a-z-]+,)*runtime[,)]' ]] || fail "hardened runtime flag not set"
print -- "verify-app: OK $app ($version, $archs, minos 14.0, signed with hardened runtime)"
