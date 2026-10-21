#!/bin/zsh
# Publishes a version: ./release.sh X.Y.Z    (./release.sh --check X.Y.Z runs the checks and tests only)
# Every step can be repeated: after a failure, fix the cause and run the same command again.
# 1. Preflight, tests, bump Info.plist, commit, tag vX.Y.Z and push (skipped if the tag is at HEAD).
# 2. The Release workflow builds, attests and uploads Usagi-X.Y.Z.zip to a draft release.
# 3. Verify the draft's zip, publish it without marking it latest, point the Homebrew cask at it,
#    then mark it latest, which is when the in-app update check starts offering it.
# See docs/RELEASING.md. Needs `gh` signed in with push access to both repositories.
set -euo pipefail
repo=Extransload/usagi
tap_repo=Extransload/homebrew-tap
check_only=0
[[ ${1:-} == --check ]] && { check_only=1; shift; }
version=${1:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: ./release.sh [--check] X.Y.Z"; exit 1; }
tag=v$version
zip_name=Usagi-$version.zip
project_dir=${0:A:h}
cd "$project_dir"

step=preflight
stopped=0
work=$(/usr/bin/mktemp -d)
on_exit() {  # also the ZERR trap: zsh skips EXIT traps when set -e fires inside a function
  local exit_status=$?
  (( ZSH_SUBSHELL == 0 && ! stopped )) || return 0
  stopped=1
  /bin/rm -rf "$work"
  (( exit_status == 0 )) || print -u2 -- "\nrelease.sh stopped during: $step
Fix the cause and run ./release.sh $version again; finished steps are skipped."
}
trap on_exit EXIT
trap on_exit ZERR
say() { step=$1; print -- "==> $1"; }
die() { print -u2 -- "error: $*"; exit 1; }
version_gt() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | /usr/bin/sort -V | /usr/bin/tail -1) == "$1" ]]; }
release_state() {  # "none", or "draft"/"published" plus "with zip"/"without zip"
  local query="(if .isDraft then \"draft\" else \"published\" end) + (if any(.assets[]; .name == \"$zip_name\") then \" with zip\" else \" without zip\" end)"
  gh release view "$tag" -R "$repo" --json isDraft,assets --jq "$query" 2>/dev/null || print none
}

say "Preflight"
(( $+commands[gh] )) || die "Install the GitHub CLI (gh)."
[[ $(git branch --show-current) == main ]] || die "Release from the main branch."
[[ -z $(git status --porcelain) ]] || die "Commit or stash your changes first."
gh auth status >/dev/null 2>&1 || die "Sign in to the GitHub CLI first: gh auth login"
for r in $repo $tap_repo; do
  [[ $(gh api "repos/$r" --jq .permissions.push) == true ]] || die "Your gh account cannot push to $r."
done
section=$(/usr/bin/awk -v v="$version" '$1 == "##" && $2 == v {f = 1; next} f && /^## / {exit} f' CHANGELOG.md)
[[ $section == *[^[:space:]]* ]] || die "CHANGELOG.md has no '## $version' section; it becomes the release notes."
git fetch -q --tags origin main
head=$(git rev-parse HEAD)
current=$(/usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist)
if tag_commit=$(git rev-parse -q --verify "refs/tags/$tag^{commit}"); then
  [[ $tag_commit == "$head" ]] || die "Tag $tag already exists at ${tag_commit:0:12}, not at HEAD (${head:0:12})."
  git merge-base --is-ancestor origin/main HEAD || die "origin/main has commits that HEAD does not; resolve that first."
  [[ $current == "$version" ]] || die "Tag $tag is at HEAD but Info.plist says $current."
  tagged=1
else
  [[ $head == $(git rev-parse origin/main) ]] || die "main differs from origin/main; pull or push first."
  version_gt "$version" "$current" || die "$version is not greater than the current version $current."
  tagged=0
  say "Run the tests"
  /usr/bin/python3 -m unittest discover -s tests
  tests/swift/run.sh
fi

if (( check_only )); then
  if (( tagged )); then
    print "Tag $tag is at HEAD: a release run skips the version bump and continues from the push."
  else
    print "A release run bumps Info.plist from $current to $version, commits, tags $tag and pushes main."
  fi
  print "GitHub release $tag: $(release_state)"
  print "Tap cask now: $(gh api -H 'Accept: application/vnd.github.raw' "repos/$tap_repo/contents/Casks/usagi.rb" \
    | /usr/bin/awk '$1 == "version" || $1 == "sha256" {printf "%s %s  ", $1, $2}')"
  print "Checks passed; nothing was changed."
  exit 0
fi

if (( ! tagged )); then
  say "Bump Info.plist to $version, commit and tag $tag"
  build_number=$(( $(/usr/bin/plutil -extract CFBundleVersion raw Info.plist) + 1 ))
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" Info.plist
  /usr/bin/plutil -replace CFBundleVersion -string "$build_number" Info.plist
  [[ $(/usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist) == "$version" &&
     $(/usr/bin/plutil -extract CFBundleVersion raw Info.plist) == "$build_number" ]] || die "Info.plist was not updated."
  git commit -q -m "Release $version" Info.plist
  git tag -a "$tag" -m "Usagi $version"
fi
say "Push main and $tag"
git push -q --atomic origin main "$tag"

say "Wait for the Release workflow to upload $zip_name to a draft"
state=$(release_state)
if [[ $state != *" with zip" ]]; then
  run_id=
  for attempt in {1..30}; do
    run_id=$(gh run list -R "$repo" --workflow release.yml --branch "$tag" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null) || true
    [[ -n $run_id ]] && break
    sleep 5
  done
  [[ -n $run_id ]] || die "No Release workflow run for $tag yet: https://github.com/$repo/actions/workflows/release.yml"
  gh run watch "$run_id" -R "$repo" --exit-status --compact --interval 15 \
    || die "The Release workflow failed: https://github.com/$repo/actions/runs/$run_id
  Transient failure: gh run rerun $run_id -R $repo --failed, then run release.sh again.
  Broken code in the tag: fix it on main and release the next version."
  state=$(release_state)
  [[ $state == *" with zip" ]] || die "The workflow finished but release $tag is '$state'."
fi

say "Download and verify $zip_name"
gh release download "$tag" -R "$repo" --pattern "$zip_name" --dir "$work" --clobber
gh attestation verify "$work/$zip_name" -R "$repo" --signer-workflow "$repo/.github/workflows/release.yml" \
  --source-ref "refs/tags/$tag" --deny-self-hosted-runners
/usr/bin/ditto -x -k "$work/$zip_name" "$work/unzipped"
.github/verify-app.sh "$work/unzipped/Usagi.app" "$version"
sha=$(/usr/bin/shasum -a 256 "$work/$zip_name" | /usr/bin/awk '{print $1}')
print "sha256 $sha"

if [[ $state == draft* ]]; then
  say "Publish $tag without marking it latest"
  gh release edit "$tag" -R "$repo" --draft=false --latest=false >/dev/null
fi

say "Check the public download"
/usr/bin/curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$work/public.zip" \
  "https://github.com/$repo/releases/download/$tag/$zip_name"
public_sha=$(/usr/bin/shasum -a 256 "$work/public.zip" | /usr/bin/awk '{print $1}')
[[ $public_sha == "$sha" ]] || die "The public download's sha256 is $public_sha, not $sha."

say "Point the Homebrew cask at $version"
gh repo clone "$tap_repo" "$work/tap" -- -q
cask="$work/tap/Casks/usagi.rb"
/usr/bin/sed -i '' -E -e "s/^  version \"[^\"]*\"$/  version \"$version\"/" \
  -e "s/^  sha256 \"[0-9a-f]*\"$/  sha256 \"$sha\"/" "$cask"
/usr/bin/grep -qx "  version \"$version\"" "$cask" && /usr/bin/grep -qx "  sha256 \"$sha\"" "$cask" \
  || die "Could not set version and sha256 in Casks/usagi.rb."
if git -C "$work/tap" diff --quiet; then
  print "The cask already points at $version."
else
  if (( $+commands[brew] )); then HOMEBREW_NO_AUTO_UPDATE=1 brew style "$cask"; fi
  git -C "$work/tap" commit -q -am "usagi $version"
  git -C "$work/tap" push -q
fi

say "Mark $tag as the latest release"
gh release edit "$tag" -R "$repo" --latest >/dev/null
print "Released Usagi $version (sha256 $sha)"
