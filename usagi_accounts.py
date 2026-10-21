"""Account profiles built on the officially supported config directories.

Claude Code keeps a separate login, history and settings per
CLAUDE_CONFIG_DIR, and Codex per CODEX_HOME. A profile named "work" is the
pair ~/.claude-work and ~/.codex-work; "default" is the plain ~/.claude and
~/.codex. Shared configuration is symlinked into each new profile while logins
and histories stay apart, except a Claude settings.json that signs in by
itself. Agent Kit uses the same layout; when it is installed its state folder
is shared, and new profiles always carry its marker too. Nothing here reads or
copies a login token.
"""
import contextlib
import json
import os
from pathlib import Path
import re
import tempfile

HOME = Path.home()
AGENTKIT = HOME / ".config/iterm2/agentkit"
STATE = AGENTKIT / "state" if AGENTKIT.is_dir() else HOME / ".config/usagi/state"
PROVIDERS = ("claude", "codex")
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")  # use fullmatch: match() with $ accepts "work\n"
MARKERS = (".usagi-profile", ".agentkit-profile")
SHARED_CLAUDE = ("settings.json", "CLAUDE.md", "CLAUDE-omc.md", "hooks", "skills", "plugins",
                 "statusline", "agents", "commands", "keybindings.json", "output-styles")
SHARED_CODEX = ("config.toml", "hooks.json", "AGENTS.md", "skills", "agents", "rules", "prompts")
CREDENTIAL_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN")


class AccountError(Exception):
    pass


def private_dir(path):
    """mkdir -p, but every folder it creates is 0700 (parents=True would make them 0755)."""
    path = Path(path)
    if not path.is_dir():
        private_dir(path.parent)
        with contextlib.suppress(FileExistsError):
            path.mkdir(mode=0o700)
    return path


def write_private(path, text):
    """Replaces the file atomically with one only the user can read."""
    private_dir(path.parent)
    fd, temp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".")
    try:
        with os.fdopen(fd, "w") as file:
            file.write(text)
        os.replace(temp, str(path))
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temp)
        raise


def sort_key(name):
    """default first, then natural order: account-2 before account-10."""
    return name != "default", [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name)]


def dirs(name):
    if name == "default":
        return HOME / ".claude", HOME / ".codex"
    return HOME / (".claude-" + name), HOME / (".codex-" + name)


def check_name(name):
    if name == "default" or not isinstance(name, str) or not NAME.fullmatch(name):
        raise AccountError("Use lowercase letters, digits and -; 'default' is reserved: %r" % name)


def check_provider(provider):
    if provider is not None and provider not in PROVIDERS:
        raise AccountError("Unknown provider: %s" % provider)


def is_profile(folder):
    return any((folder / marker).exists() for marker in MARKERS)


def profiles(provider=None):
    """Registered names; provider views include accounts made for only that CLI."""
    check_provider(provider)
    names = []
    prefix = ".codex-" if provider == "codex" else ".claude-"
    for path in HOME.glob(prefix + "*"):
        name = path.name[len(prefix):]
        legacy_codex = provider == "codex" and is_profile(HOME / (".claude-" + name))
        if NAME.fullmatch(name) and (is_profile(path) or legacy_codex):
            names.append(name)
    return ["default"] + sorted(names, key=sort_key)


def active(provider=None):
    check_provider(provider)
    selected = STATE / ("account" if provider is None else "account-" + provider)
    try:
        name = selected.read_text().strip()
    except OSError:
        return active() if provider is not None else "default"
    return name if name in profiles(provider) else "default"


def _write_active(path, name):
    write_private(path, name + "\n")


def use(name, provider=None):
    check_provider(provider)
    if name not in profiles(provider):
        raise AccountError("No such account: %s" % name)
    if provider is None:
        _write_active(STATE / "account", name)
        for source in PROVIDERS:
            _write_active(STATE / ("account-" + source), name)
    else:
        _write_active(STATE / ("account-" + provider), name)


def _link_shared(source_root, target_root, names):
    """Symlink shared items; never replaces anything already in the profile."""
    linked = []
    for item in names:
        source, target = source_root / item, target_root / item
        if source.exists() and not target.exists() and not target.is_symlink():
            target.symlink_to(source)
            linked.append(item)
    return linked


def _signs_in(settings):
    """A Claude settings file with its own credentials (apiKeyHelper, or a token in env) would sign
    every profile into the same account. One that can't be read is treated the same way."""
    try:
        data = json.loads(settings.read_text())
    except (OSError, ValueError):
        return True
    if not isinstance(data, dict):
        return True
    env = data.get("env")
    return "apiKeyHelper" in data or (isinstance(env, dict) and any(key in env for key in CREDENTIAL_ENV))


def add(name, provider=None):
    """Creates the profile folders. Returns them, the shared items linked per CLI, and the items
    not shared because they carry credentials."""
    check_name(name)
    check_provider(provider)
    claude, codex = dirs(name)
    selected = ((claude, codex) if provider is None else
                (claude,) if provider == "claude" else (codex,))
    for folder in selected:
        folder.mkdir(mode=0o700, exist_ok=True)
        for marker in MARKERS:  # both, so Agent Kit installed later sees the profile too
            if not (folder / marker).exists():
                write_private(folder / marker, "Created by Usagi; safe to keep.\n")
    shared, skipped = SHARED_CLAUDE, []
    settings = HOME / ".claude/settings.json"
    if claude in selected and settings.exists() and _signs_in(settings):
        shared, skipped = tuple(item for item in SHARED_CLAUDE if item != "settings.json"), ["settings.json"]
    linked = {"claude": _link_shared(HOME / ".claude", claude, shared)
              if claude in selected else [],
              "codex": _link_shared(HOME / ".codex", codex, SHARED_CODEX)
              if codex in selected else []}
    return claude, codex, linked, skipped


def account_info(name):
    """Email and plan for display, from the profile's cached Claude profile only."""
    claude, codex = dirs(name)
    profile_file = HOME / ".claude.json" if name == "default" else claude / ".claude.json"
    info = {"name": name, "claude_dir": str(claude), "codex_dir": str(codex)}
    try:
        account = json.loads(profile_file.read_text()).get("oauthAccount") or {}
    except (OSError, ValueError, AttributeError):
        account = {}
    if isinstance(account, dict) and account.get("emailAddress"):
        tier = str(account.get("organizationRateLimitTier") or "")
        match = re.search(r"claude_(max|pro|team|enterprise)(?:_(\d+x))?", tier)
        info["email"] = str(account["emailAddress"])
        info["plan"] = (match.group(1).capitalize() + (" " + match.group(2) if match.group(2) else "")
                        if match else "")
    return info
