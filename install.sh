#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h}
"$project_dir/build.sh" >/dev/null
installed="$HOME/Applications/Usagi.app"
legacy="$HOME/Applications/AgentUsageBar.app"
plist="$HOME/Library/LaunchAgents/io.github.extransload.usagi.plist"
legacy_plist="$HOME/Library/LaunchAgents/local.gyu.agentusagebar.plist"
uid=$(/usr/bin/id -u)
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
while IFS= read -r pid; do
  [[ -n "$pid" ]] && /bin/kill "$pid" 2>/dev/null || true
done < <(/bin/ps -axo pid=,command= | /usr/bin/awk -v app="$installed/Contents/MacOS/Usagi" \
  -v legacy="$legacy/Contents/MacOS/AgentUsageBar" '$2 == app || $2 == legacy {print $1}')
/bin/rm -rf "$installed"
/usr/bin/ditto "$project_dir/build/Usagi.app" "$installed"
/usr/bin/codesign --verify --deep --strict "$installed"
APP_PATH="$installed" PLIST_PATH="$plist" /usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path
data = {
    "Label": "io.github.extransload.usagi",
    "ProgramArguments": ["/usr/bin/open", "-a", os.environ["APP_PATH"]],
    "RunAtLoad": True,
}
Path(os.environ["PLIST_PATH"]).write_bytes(plistlib.dumps(data))
PY
if [[ -f "$legacy_plist" ]]; then
  /bin/launchctl bootout "gui/$uid" "$legacy_plist" 2>/dev/null || true
  /bin/rm -f "$legacy_plist"
fi
if [[ "$(/usr/bin/defaults read "$legacy/Contents/Info" CFBundleIdentifier 2>/dev/null)" == local.gyu.AgentUsageBar ]]; then
  /bin/rm -rf "$legacy"
fi
/bin/launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$uid" "$plist"
/usr/bin/open "$installed"
echo "$installed"
