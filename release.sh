#!/bin/zsh
# Publishes a version: ./release.sh 1.2.3 [notes.md]
# Bumps the version, tags and pushes, builds the zip from a clean clone of the tag,
# uploads a draft release, points the Homebrew cask at it, then publishes the release, so the
# in-app update check never offers a version brew can't install yet. Needs `gh` with push access.
set -euo pipefail
project_dir=${0:A:h}
version=${1:-}
notes=${2:-}
tap_repo=Extransload/homebrew-tap
cd "$project_dir"

[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: ./release.sh X.Y.Z [notes.md]"; exit 1; }
[[ $(git branch --show-current) == main ]] || { print -u2 "Release from the main branch."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit or stash your changes first."; exit 1; }
[[ -z $notes || -r $notes ]] || { print -u2 "Notes file not found: $notes"; exit 1; }
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { print -u2 "Tag v$version already exists."; exit 1; }

python3 -m unittest discover -s tests
build_number=$(( $(/usr/bin/plutil -extract CFBundleVersion raw Info.plist) + 1 ))
sed -i '' -E \
  -e "s#(<key>CFBundleShortVersionString</key><string>)[^<]*#\1$version#" \
  -e "s#(<key>CFBundleVersion</key><string>)[^<]*#\1$build_number#" Info.plist
sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"$version\"/g" bridge.py
git commit -qam "Release $version"
git tag -a "v$version" -m "Usagi $version"
git push -q --atomic origin main "v$version"

work=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$work"' EXIT
git clone -q --branch "v$version" --depth 1 "$(git remote get-url origin)" "$work/src" 2>/dev/null
(cd "$work/src" && ./build.sh >/dev/null)
zip="$work/Usagi-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$work/src/build/Usagi.app" "$zip"
sha=$(/usr/bin/shasum -a 256 "$zip" | cut -d' ' -f1)
if [[ -n $notes ]]; then
  gh release create "v$version" "$zip" --draft --title "Usagi $version" --notes-file "$notes" >/dev/null
else
  gh release create "v$version" "$zip" --draft --title "Usagi $version" --generate-notes >/dev/null
fi

gh repo clone "$tap_repo" "$work/tap" -- -q
sed -i '' -E -e "s/version \"[0-9.]+\"/version \"$version\"/" -e "s/sha256 \"[0-9a-f]+\"/sha256 \"$sha\"/" \
  "$work/tap/Casks/usagi.rb"
git -C "$work/tap" commit -qam "usagi $version"
git -C "$work/tap" push -q
gh release edit "v$version" --draft=false --latest >/dev/null
print "Released Usagi $version (sha256 $sha)"
