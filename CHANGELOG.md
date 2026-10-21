# Changelog

All notable changes to Usagi. Each `## X.Y.Z` section is used as the release notes for that version: `release.sh` and the Release workflow stop if the section is missing.

## 1.0.5

### Changed

- The menu grows to fit your cards and only scrolls when they are taller than the screen; it never scrolls sideways.
- Accounts are named by their email instead of the profile name (`default`, `account-2`). An account that isn't signed in yet shows as "Account 2" and so on; hover over it to see its profile folder. Two accounts of a service with the same email also show their number.
- The menu bar shows one item per service, for its **Active** account, so a second Codex account no longer adds "+1". "+N" now counts services beyond the limit, which you choose in the right-click menu under **Menu Bar Shows** (1, 2 or all services; 2 by default).

## 1.0.4

### Added

- The bottom of the menu shows your Usagi version and whether it is up to date. Click it, or choose **Check for Updates** from the right-click menu, to check right away instead of waiting up to 6 hours.

## 1.0.3 - 2026-10-21

### Fixed

- Finds Claude Code and Codex CLIs installed with npm, not only those in the usual folders.
- Sign-in: while a sign-in is open, Usagi checks only that account every few seconds instead of refreshing everything, tracks the sign-in process reliably, and shows why a Claude sign-in failed.
- A CLI that hangs no longer blocks Usagi: every check has a time limit and is stopped when it runs out.
- Unexpected or incomplete answers from the Codex app-server no longer break the Codex card.
- Updates: only one update runs at a time, and copies installed from source open the release page instead of trying Homebrew.
- The account switch in `usagi.zsh` also works inside tmux and in bash.
- When the menu bar's numbers are out of date they are dimmed, and hovering shows why.
- Only one copy of Usagi runs at a time, even with both a Homebrew and a source install.

### Changed

- Uses less energy: refreshes every minute while the menu is open and every 5 minutes while it is closed, and pauses while the display sleeps.
- Each limit shows how fresh its reading is, marks readings that may be out of date, and says when a limit has reset since the last reading.
- Clearer cards: an empty state when no CLI is set up, error cards that say what to do, a clearer sign-in button, and buttons that show when an action is running.
- Removing a card is now called hiding, because it only hides the card.
- Menu bar: VoiceOver labels and a right-click menu.
- Better accessibility and contrast throughout the menu.
- If the Xcode Command Line Tools are missing, Usagi says how to install them instead of failing.
- The menu's web view is locked down: a Content Security Policy that blocks remote content and `eval`, and only the bundled page can send commands to the app.

### Distribution

- Releases are built by GitHub Actions from the tagged commit, with a build provenance attestation. Check a download with `gh attestation verify Usagi-1.0.3.zip -R Extransload/usagi --signer-workflow Extransload/usagi/.github/workflows/release.yml --source-ref refs/tags/v1.0.3` (see SECURITY.md).
- CI runs the tests and a build on macOS 14, 15 and 26 and on an Intel Mac.
- Homebrew: `brew uninstall --zap --cask usagi` now also removes Usagi's caches, preferences, web view data and login LaunchAgent, and `brew livecheck` works for the cask.
- `install.sh` stops when the Homebrew cask is installed (the two would collide), checks for the Command Line Tools first, and `./install.sh --uninstall` removes a source install.
- Added SECURITY.md and an issue template.

## 1.0.2 - 2026-10-20

### Added

- Usagi tells you about new versions. When you open the menu it checks GitHub (at most every 6 hours) and, if a newer release exists, asks whether to update. With a Homebrew install, **Update** upgrades in the background and reopens Usagi.

1.0.0 and 1.0.1 can't check for updates, so update them once by hand: `brew upgrade --cask usagi`.

## 1.0.1 - 2026-10-20

### Changed

- Cards, the menu bar and the Add account dialog show the real Claude and Codex icons. They come from the Claude and ChatGPT apps when installed; if the Claude app isn't installed, Usagi downloads Claude's icon once from claude.ai and keeps it in `~/.config/usagi/icons`. Without either, the plain C and X badges remain.

## 1.0.0 - 2026-10-20

First public release.

- Claude Code and Codex usage limits and the time until each resets, per account, in the macOS menu bar.
- Add account cards and sign in with the official CLI sign-in; failed sign-ins show the reason.
- One card per service; flip through its accounts with ‹ › or a trackpad swipe.
- Pick the account new terminals use (source `usagi.zsh` from `~/.zshrc`).
- Never reads or copies sign-in tokens.
- Install with `brew install --cask extransload/tap/usagi`. Needs macOS 14 or later (universal build) and `/usr/bin/python3` from the Xcode Command Line Tools.
