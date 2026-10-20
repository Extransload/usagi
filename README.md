# Usagi

A macOS menu bar app that shows Claude Code and Codex usage limits (5-hour, weekly and more) and when they reset, for each of your accounts.
Add several accounts as cards and pick which one new terminals use.
The name is Japanese for rabbit (うさぎ), and sounds a bit like "usage".

<img src="docs/screenshot.png" width="380" alt="Usagi popover showing Claude and Codex cards with 5-hour and weekly usage and the time until each limit resets">

## Install

```sh
brew install --cask extransload/tap/usagi
open -a Usagi
```

- A rabbit icon or your usage percentages appear in the menu bar. Click it to open the account cards.
- To start Usagi when you log in, add it under **System Settings > General > Login Items**.
- Usagi is not signed or notarized by Apple. So that it opens right away, the Homebrew install removes the macOS quarantine flag. That skips Apple's check, so install it only if you trust this repository.

Update and uninstall:

```sh
brew upgrade --cask usagi
brew uninstall --cask usagi          # remove the app
brew uninstall --zap --cask usagi    # also remove the card list and sign-in state (~/.config/usagi)
```

## Requirements

| Item | Details |
|---|---|
| macOS | 14 Sonoma or later |
| CLI | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`), [Codex CLI](https://github.com/openai/codex) (`codex`), or both |
| Python | `/usr/bin/python3`, which comes with the Xcode Command Line Tools (already installed if you use Homebrew) |
| Browser | Sign-in opens in Google Chrome when it is installed, otherwise in your default browser |

Usagi looks for the CLIs in `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin` and `~/.nvm/versions/node/*/bin`, in that order.

## Usage

- On first launch, the CLI accounts you are already signed in to (`default`) appear as cards.
- **＋** then Claude or Codex adds an account card. Usagi shows a hidden existing account if there is one; otherwise it creates a new profile such as `account-2` (`~/.claude-account-2`, `~/.codex-account-2`).
- **→** (sign in) opens the official CLI sign-in in your browser. If it fails, the card shows why.
- When a service has several accounts, flip through them with **‹ ›** at the top right of the card or a horizontal trackpad swipe. `default` comes first, and the account new terminals use is marked `Active`.
- **✓** picks the account new terminals use. To make it take effect, add this line to `~/.zshrc`. It applies to `claude` and `codex` runs started afterwards; sessions already running keep their account.

  ```sh
  for usagi in /Applications ~/Applications; do [[ -r $usagi/Usagi.app/Contents/Resources/usagi.zsh ]] && { source $usagi/Usagi.app/Contents/Resources/usagi.zsh; break; }; done
  ```

- **Trash** only hides the card. It does not sign out of the CLI or delete the profile folder.

## What Usagi reads

- **Claude**: the usage cache Claude Code keeps in `~/.claude.json` (`~/.claude-<name>/.claude.json` for extra accounts). Only percentages and reset times are read. Right after you use Claude the numbers can lag.
- **Codex**: Usagi asks the Codex CLI's official app-server (`codex app-server`) for the account and its limits. Limits are named by the period Codex reports (Team: 5-hour and weekly, Free: 30-day, and so on).
- Usagi never reads or copies sign-in tokens. Sign-in uses `claude auth login` and the Codex app-server's own sign-in.
- Usagi stores only the card list (`~/.config/usagi/cards.json`), in-progress sign-in markers and the name of the selected account.
- With the same account, the Claude apps, claude.ai and Claude Code share limits. Codex limits can also be shared with other Codex use on the same ChatGPT account.

Usagi uses the same profile layout as [Agent Kit](#agent-kit-users) and shares its state folder when Agent Kit is installed.

## Tested environment

Checked on the developer's Mac on 2026-10-20.

| Item | Version |
|---|---|
| macOS | 27.0.1 (26A434), Apple Silicon |
| Claude Code | 2.1.304 |
| Codex CLI | 0.163.0 |
| Python | 3.9.6 (`/usr/bin/python3`); the tests also run on 3.11.9 |
| Swift | 6.4 |
| Homebrew | 7.0.9 |

Checked:

- Menu bar icon and popover after install, card scrolling, flipping through accounts per service
- Usage for Claude Max 20x (5-hour, weekly, per-model weekly), Codex Team (5-hour, weekly) and Codex Free (30-day)
- Signing in a second Codex account in Chrome, and its usage right after sign-in
- Finding the CLIs and reading usage with the short `PATH` an app opened from Finder gets
- A Mac without Agent Kit, simulated with an empty home folder: clean start, adding a profile, selecting an account, and `usagi.zsh` switching `CODEX_HOME`
- Installing with `brew install --cask` and opening the app without a Gatekeeper block
- 29 automated tests

Not checked:

- Intel Macs (the build is universal but has not been run on one)
- Running on macOS 14, 15 or 26
- Sign-in on a Mac without Chrome (the default-browser fallback is covered by automated tests only)
- Account selection (✓) in daily use on any Mac other than the developer's

Please report problems in [Issues](https://github.com/Extransload/usagi/issues).

## Agent Kit users

When Agent Kit (`~/.config/iterm2/agentkit`) is installed, Usagi shares its state folder and profile marker (`.agentkit-profile`). Agent Kit's own shell hook already handles account selection, so you don't need `usagi.zsh`.

## Install from source

```sh
git clone https://github.com/Extransload/usagi.git
cd usagi
./install.sh
```

This installs `~/Applications/Usagi.app` and registers a LaunchAgent so it starts when you log in.

## Development

```sh
./build.sh                                  # build/Usagi.app (arm64 + x86_64)
python3 -m unittest discover -s tests
./make-icon.sh                              # only after editing the SVGs in assets; needs Google Chrome
```

## License

[MIT](LICENSE)

Claude is a trademark of Anthropic. Codex and ChatGPT are trademarks of OpenAI. Usagi is an unofficial app and is not affiliated with either company.
