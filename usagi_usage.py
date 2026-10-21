"""Claude usage from local caches. Only percentages and reset times are read, never tokens."""
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import time

import usagi_accounts

CLAUDE_PROFILE = Path.home() / ".claude.json"
STALE_AFTER = {"5h": 30 * 60}  # seconds; longer windows change slowly
STALE_DEFAULT = 3 * 3600


def _number(value):
    # bool is an int subclass and json accepts NaN; neither is a percentage.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def _epoch(value):
    """ISO 8601 ('2026-10-15T10:19:59.644864+00:00') or a number → unix seconds. Python 3.9's
    fromisoformat takes only 3 or 6 fraction digits; a time without a zone is UTC."""
    number = _number(value)
    if number is not None:
        return number
    if not isinstance(value, str):
        return None
    text = value.strip()
    text = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    text = re.sub(r"(?<=:\d\d)\.(\d+)", lambda match: "." + (match.group(1) + "00000")[:6], text, count=1)
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return (moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)).timestamp()


def _stale(label, captured_at, now):
    """The reading may be outdated: a 5h window after 30 minutes, longer ones after 3 hours."""
    return captured_at is None or now - captured_at > STALE_AFTER.get(label, STALE_DEFAULT)


def _live(windows, captured_at, now):
    """Windows as of `now`. One that already reset is back to 0%: the old
    percentage no longer applies, and any use since would have left a newer
    reading. Its next reset is unknown until the window starts again."""
    now = time.time() if now is None else now
    live = {}
    for label, window in (windows.items() if isinstance(windows, dict) else ()):
        if not isinstance(window, dict):
            continue
        used, resets = _number(window.get("used_percent")), _number(window.get("resets_at"))
        if used is None:
            continue
        if resets is not None and resets <= now:
            live[label] = {"used_percent": 0.0, "resets_at": None, "reset": True,
                           "captured_at": max(resets, captured_at or 0.0)}
        else:
            live[label] = {"used_percent": used, "resets_at": resets, "captured_at": captured_at}
        live[label]["stale"] = _stale(label, live[label]["captured_at"], now)
    return live


def read_claude_cached(profile_file=None, now=None):
    """Claude Code's own cached usage (cachedUsageUtilization in .claude.json).

    Claude Code refreshes it itself; it holds model-scoped weekly limits such as
    Fable that the status-line payload lacks.
    """
    try:
        data = json.loads(Path(profile_file or CLAUDE_PROFILE).read_text())
    except (OSError, ValueError):
        return {}
    cached = data.get("cachedUsageUtilization") if isinstance(data, dict) else None
    if not isinstance(cached, dict) or not isinstance(cached.get("utilization"), dict):
        return {}
    fetched = _number(cached.get("fetchedAtMs"))
    windows = {}
    limits = cached["utilization"].get("limits")
    for item in limits if isinstance(limits, list) else []:
        used = _number(item.get("percent")) if isinstance(item, dict) else None
        if used is None:
            continue
        kind, label = item.get("kind"), None
        if kind == "session":
            label = "5h"
        elif kind == "weekly_all":
            label = "7d"
        elif kind == "weekly_scoped":
            model = (item.get("scope") or {}).get("model") if isinstance(item.get("scope"), dict) else None
            name = model.get("display_name") if isinstance(model, dict) else model
            if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9 .-]{1,30}", name.strip()):
                label = name.strip().lower()
        if label:
            windows[label] = {"used_percent": used, "resets_at": _epoch(item.get("resets_at"))}
    return _live(windows, fetched / 1000.0 if fetched else None, now)


def claude_cache_for(profile):
    """Agent Kit's status-line reading for a profile; absent without Agent Kit."""
    state = usagi_accounts.AGENTKIT / "state"
    return state / ("usage-claude.json" if profile == "default" else "usage-claude-%s.json" % profile)


def read_claude(path, now=None):
    try:
        stored = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(stored, dict):
        return {}
    return _live(stored.get("windows"), _number(stored.get("captured_at")), now)


def merge_windows(*sources):
    """Per window, keep the most recently captured reading."""
    merged = {}
    for windows in sources:
        for label, window in (windows or {}).items():
            current = merged.get(label)
            if current is None or (window.get("captured_at") or 0) >= (current.get("captured_at") or 0):
                merged[label] = window
    return merged
