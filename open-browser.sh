#!/bin/sh
# BROWSER for `claude auth login`: Google Chrome when installed, otherwise the default browser.
mark() {
  [ -n "${USAGI_BROWSER_MARKER:-}" ] && printf %s "$1" > "$USAGI_BROWSER_MARKER"
  return 0
}
mark opening
if /usr/bin/open -a 'Google Chrome' "$@" 2>/dev/null; then
  /usr/bin/osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1 || true
elif ! /usr/bin/open "$@"; then
  mark error
  exit 1
fi
mark opened
