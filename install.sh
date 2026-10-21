#!/bin/zsh
# Builds Usagi from this checkout into ~/Applications and starts it at login with a LaunchAgent.
#   ./install.sh               install, or update after git pull
#   ./install.sh --uninstall   remove the app and the LaunchAgent (keeps ~/.config/usagi)
#   add --dry-run to either to print what would change without changing anything
set -euo pipefail
project_dir=${0:A:h}
label=io.github.extransload.usagi
app="$HOME/Applications/Usagi.app"
binary="$app/Contents/MacOS/Usagi"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(/usr/bin/id -u)"
mode=install
dry_run=0
for arg in "$@"; do
  case $arg in
    --uninstall) mode=uninstall ;;
    --dry-run) dry_run=1 ;;
    *) print -u2 "usage: ./install.sh [--uninstall] [--dry-run]"; exit 1 ;;
  esac
done
die() { print -u2 -- "$*"; exit 1; }
run() { if (( dry_run )); then print -r -- "would run: ${(q-)@}"; else "$@"; fi; }
cask=
for prefix in /opt/homebrew /usr/local; do
  [[ -d $prefix/Caskroom/usagi ]] && cask=$prefix/Caskroom/usagi
done

# Stops copies running from $app. Matches the whole command line exactly, so spaces in HOME are fine.
stop_running() {
  local line pid pids=() deadline=$(( SECONDS + 5 ))
  for line in ${(f)"$(/bin/ps -axww -o pid=,command=)"}; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ ${line#* } == "$binary" ]] && pids+=(${line%% *})
  done
  (( ${#pids} )) || return 0
  run /bin/kill $pids 2>/dev/null || true
  (( dry_run )) && return 0
  for pid in $pids; do
    while /bin/kill -0 $pid 2>/dev/null && (( SECONDS < deadline )); do /bin/sleep 0.1; done
  done
}

if [[ $mode == uninstall ]]; then
  run /bin/launchctl bootout "$domain/$label" 2>/dev/null || true
  run /bin/rm -f "$plist"
  stop_running
  if [[ -d $app && -n $cask && ! -e $app/Contents/Resources/source-install ]]; then
    print "Kept $app because it may be the Homebrew copy; remove that with: brew uninstall --cask usagi"
  elif [[ -d $app ]]; then
    run /bin/rm -rf "$app"
  fi
  (( dry_run )) && exit 0
  print "Usagi's source install is removed. Your cards and settings in ~/.config/usagi were kept;"
  print "delete that folder to remove them too, and remove the usagi.zsh line from ~/.zshrc if you added it."
  exit 0
fi

[[ -z $cask ]] || die "Usagi is installed with Homebrew ($cask). A source install would collide with it
(same app, two copies starting at login, updates going to the wrong copy).
Remove the Homebrew copy first with: brew uninstall --cask usagi"
developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null) && [[ -x $developer_dir/usr/bin/python3 ]] \
  && /usr/bin/xcrun --find swiftc >/dev/null 2>&1 \
  || die "Usagi needs the Xcode Command Line Tools: swiftc to build it and python3 to run it.
Install them with: xcode-select --install
then run ./install.sh again."

run env USAGI_SOURCE_INSTALL=1 "$project_dir/build.sh"
run /bin/mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
stop_running
run /bin/rm -rf "$app"
run /usr/bin/ditto "$project_dir/build/Usagi.app" "$app"
run /usr/bin/codesign --verify --deep --strict "$app"
if (( dry_run )); then
  print -r -- "would write $plist (runs: /usr/bin/open -a $app at login)"
else
  APP_PATH="$app" PLIST_PATH="$plist" LABEL="$label" /usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path
data = {
    "Label": os.environ["LABEL"],
    "ProgramArguments": ["/usr/bin/open", "-a", os.environ["APP_PATH"]],
    "RunAtLoad": True,
}
Path(os.environ["PLIST_PATH"]).write_bytes(plistlib.dumps(data))
PY
fi
run /bin/launchctl bootout "$domain/$label" 2>/dev/null || true
# Right after a bootout, launchd can still be tearing the job down and bootstrap fails with error 5.
if ! run /bin/launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
  /bin/sleep 1
  run /bin/launchctl bootstrap "$domain" "$plist"
fi
run /usr/bin/open "$app" 2>/dev/null || true  # the LaunchAgent may already be opening it
(( dry_run )) || print -r -- "Installed $app"
