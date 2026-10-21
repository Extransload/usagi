# Releasing Usagi

Releases are built by GitHub Actions, not on a laptop. `release.sh` drives the whole thing from
the maintainer's Mac: it tags the version, waits for the Release workflow to build and attest the
zip, checks the result, publishes it and points the Homebrew cask at it.

## Before you start

- The GitHub CLI (`gh`) is signed in with push access to `Extransload/usagi` and
  `Extransload/homebrew-tap`.
- You are on `main`, with no uncommitted changes, and `main` matches `origin/main`.
- `CHANGELOG.md` has a `## X.Y.Z` section for the new version, committed and pushed. It becomes
  the release notes, and both `release.sh` and the workflow stop without it.

To rehearse without changing anything, run `./release.sh --check X.Y.Z`: it runs the checks and
the tests and shows the state of the tag, the GitHub release and the cask.

## Release

```sh
./release.sh X.Y.Z
```

| # | Step | What it does | When rerun |
|---|---|---|---|
| 1 | Preflight | Branch, clean tree, `origin/main`, `gh auth status`, push access to both repositories, the CHANGELOG section, and X.Y.Z greater than the version in `Info.plist` (`sort -V`) | Repeated |
| 2 | Tests | `/usr/bin/python3 -m unittest discover -s tests` and `tests/swift/run.sh` | Skipped once the tag exists |
| 3 | Bump and tag | `plutil -replace` of `CFBundleShortVersionString` and `CFBundleVersion` (+1) in `Info.plist`, commit `Release X.Y.Z`, annotated tag `vX.Y.Z` | Skipped if `vX.Y.Z` is at HEAD; stops if it points anywhere else |
| 4 | Push | `git push --atomic origin main vX.Y.Z` | No-op when already pushed |
| 5 | Build | The tag starts `.github/workflows/release.yml` on a `macos-15` runner: tests, `./build.sh`, `.github/verify-app.sh` (version, arm64 + x86_64, minimum macOS 14.0, signature with hardened runtime), zip with `ditto`, build provenance attestation, then a **draft** release with the CHANGELOG section, the Swift version and the runner image in the notes. `release.sh` follows it with `gh run watch` | Skipped when the draft already has the zip |
| 6 | Verify | Downloads the draft's zip, `gh attestation verify` (must come from `release.yml` for `refs/tags/vX.Y.Z`), unzips it, runs `verify-app.sh` on it and computes its sha256 | Repeated |
| 7 | Publish | `gh release edit vX.Y.Z --draft=false --latest=false`: the zip is downloadable, but `releases/latest`, which the in-app update check reads, still points at the previous version | Skipped when published |
| 8 | Public download | Downloads the public asset URL with `curl` and compares its sha256 | Repeated |
| 9 | Cask | Sets `version` and `sha256` in the tap's `Casks/usagi.rb`, checks both lines exactly, runs `brew style`, commits `usagi X.Y.Z` and pushes | Skipped when the cask already has both |
| 10 | Latest | `gh release edit vX.Y.Z --latest`: from now on the in-app update check offers X.Y.Z | Repeated |

The order matters: the app only offers an update (step 10) after Homebrew can install it
(step 9), and the cask only changes after the zip is public and checked (steps 6 to 8).

## Resuming after a failure

`release.sh` prints the step it stopped in. Fix the cause and run the same `./release.sh X.Y.Z`
again; finished steps are skipped.

- **The Release workflow failed for a transient reason** (runner or network trouble): rerun it with
  `gh run rerun <run id> -R Extransload/usagi --failed`, then run `release.sh` again. A rerun replaces
  the zip on the draft.
- **The Release workflow failed because the tagged code is broken**: the tag is already public, so
  don't move it. Delete the draft (`gh release delete vX.Y.Z -R Extransload/usagi --yes`, which keeps
  the tag), fix the code on `main`, add a CHANGELOG section for the next patch version and release
  that.
- **A push failed** (main and tag, or the tap): just run `release.sh` again.

## Rolling back a bad release

A published release is never edited or replaced; it is superseded by a newer one. (With
immutable releases turned on for the repository, GitHub refuses to change its assets or tag
anyway, and people may already have downloaded it.)

1. Point Homebrew back at the previous version by reverting the cask commit:

   ```sh
   gh repo clone Extransload/homebrew-tap /tmp/homebrew-tap && cd /tmp/homebrew-tap
   git log --oneline -3 -- Casks/usagi.rb    # find the "usagi X.Y.Z" commit
   git revert --no-edit <commit>
   git push
   ```

   Homebrew treats any difference between the installed version and the cask's version as
   outdated, so `brew upgrade --cask usagi` moves people on X.Y.Z back to the previous version,
   and new installs get the previous version.

2. Stop the in-app update check from offering X.Y.Z: `gh release edit vPREV -R Extransload/usagi --latest`.

3. Add a warning at the top of X.Y.Z's release notes that points to the fix.

4. Fix the problem on `main` and release the next patch version as usual. `release.sh` moves the
   cask and "latest" forward again.

## Related checks

- `.github/workflows/ci.yml` runs the tests, a build, the bundle checks, a bridge snapshot and a
  launch test on macOS 14, 15, 26 and Intel for every push and pull request.
- The tap's `.github/workflows/check.yml` runs `brew style` and `brew audit --cask --online` on
  changed casks.
- Anyone can check a release zip with
  `gh attestation verify Usagi-X.Y.Z.zip -R Extransload/usagi` (see [SECURITY.md](../SECURITY.md)).
