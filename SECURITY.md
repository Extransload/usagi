# Security policy

## Supported versions

Only the latest release receives fixes. Update with `brew upgrade --cask extransload/tap/usagi`, or pull and run
`./install.sh` again for a source install.

## Reporting a vulnerability

Please report vulnerabilities privately, not in a public issue: open the repository's
**Security** tab and choose **Report a vulnerability**
(<https://github.com/Extransload/usagi/security/advisories/new>). If that button is missing,
open an issue that only asks for a private contact, without details.

Include the Usagi version, your macOS version, what an attacker can do and how to reproduce it.
Usagi is maintained by one person, so reports are handled on a best-effort basis; you will get
a reply in the advisory, and fixes ship as a new release with credit unless you prefer otherwise.

Examples of what is in scope: the menu's web view running content that is not the bundled page,
the bridge running something other than the Claude Code and Codex CLIs, Usagi reading or copying
sign-in tokens, the update path, `install.sh`, the release workflow and the Homebrew cask.

## Signing, quarantine and verifying a download

Usagi is ad-hoc signed and not notarized by Apple. The Homebrew cask removes the
`com.apple.quarantine` flag after installing so the app opens without a Gatekeeper prompt. That
means macOS does not check the app for you: you are trusting this repository and the
[Extransload/homebrew-tap](https://github.com/Extransload/homebrew-tap) cask.

From 1.0.3 on, release zips are built by GitHub Actions from the tagged commit, and each one has a
signed build provenance attestation. To check a download yourself (needs the GitHub CLI):

```sh
gh release download v1.0.3 -R Extransload/usagi -p 'Usagi-*.zip'
gh attestation verify Usagi-1.0.3.zip -R Extransload/usagi \
  --signer-workflow Extransload/usagi/.github/workflows/release.yml --source-ref refs/tags/v1.0.3
shasum -a 256 Usagi-1.0.3.zip   # compare with sha256 in Casks/usagi.rb of the tap
```

With `--signer-workflow` and `--source-ref`, `gh attestation verify` succeeds only if the zip is
byte-for-byte what this repository's release workflow built from that version's tag. Releases 1.0.0 to 1.0.2 were built on the maintainer's Mac and have no
attestation.
