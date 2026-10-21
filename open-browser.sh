#!/bin/sh
# BROWSER for `claude auth login`: Google Chrome when installed, otherwise the default browser.
# Takes exactly one https:// URL; anything else is refused.
mark() {
  [ -n "${USAGI_BROWSER_MARKER:-}" ] || return 0
  printf %s "$1" > "$USAGI_BROWSER_MARKER.tmp" && /bin/mv -f "$USAGI_BROWSER_MARKER.tmp" "$USAGI_BROWSER_MARKER"
  return 0
}
case "$#:${1:-}" in
  1:https://*) ;;
  *) mark error; exit 1 ;;
esac
mark opening
# `open -a` brings Chrome forward by itself; scripting it would ask for Automation permission.
if ! /usr/bin/open -a 'Google Chrome' "$1" 2>/dev/null && ! /usr/bin/open "$1"; then
  mark error
  exit 1
fi
mark opened
