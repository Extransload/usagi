"""Shared test setup: every test runs against a temporary HOME and never reaches real CLIs or state."""
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest import mock

import bridge
import usagi_accounts as accounts
import usagi_usage as usage

ROOT = Path(__file__).resolve().parents[1]
SHORT_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"  # what an app opened from Finder gets
PYTHON = sys.executable
CLEARED = ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "BASH_ENV", "ENV", "ZDOTDIR", "BROWSER", "USAGI_BROWSER_MARKER",
           "PROMPT_COMMAND", "_USAGI_CLAUDE_ACCOUNT", "_USAGI_CODEX_ACCOUNT", "ANTHROPIC_API_KEY",
           "OPENAI_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CODEX_ACCESS_TOKEN")


class IsolatedTest(unittest.TestCase):
    """HOME, Path.home() and every module-level path point into a temp folder. System CLI folders and
    Homebrew prefixes are emptied and SHELL points nowhere, so nothing real is found or run."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="usagi-test-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = self.home / ".config/usagi"
        environment = mock.patch.dict(os.environ, {"HOME": str(self.home), "PATH": SHORT_PATH,
                                                   "SHELL": str(self.root / "no-shell")})
        environment.start()
        self.addCleanup(environment.stop)
        for name in CLEARED:
            os.environ.pop(name, None)
        for module, name, value in (
                (bridge, "CONFIG_DIR", self.config),
                (bridge, "LEGACY_CONFIG_DIR", self.home / ".config/AgentUsageBar"),
                (bridge, "CARD_FILE", self.config / "cards.json"),
                (bridge, "LOGIN_DIR", self.config / "logins"),
                (bridge, "CLI_FOLDERS", ()),
                (bridge, "BREW_PREFIXES", ()),
                (bridge, "APP_PATH", self.root / "Usagi.app"),
                (accounts, "HOME", self.home),
                (accounts, "AGENTKIT", self.home / ".config/iterm2/agentkit"),
                (accounts, "STATE", self.config / "state"),
                (usage, "CLAUDE_PROFILE", self.home / ".claude.json")):
            patch = mock.patch.object(module, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        for clear in (bridge.FOUND.clear, bridge.app_version.cache_clear):
            clear()
            self.addCleanup(clear)
        self.addCleanup(self.stop_children)
        self.assertEqual(Path.home(), self.home)
        for path in (bridge.CONFIG_DIR, bridge.CARD_FILE, bridge.LOGIN_DIR, accounts.STATE, usage.CLAUDE_PROFILE):
            self.assertIn(self.root, path.parents)

    @staticmethod
    def stop_children():
        for process in list(bridge.CHILDREN):
            bridge.stop(process)

    def script(self, path, body):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)
        return path

    def fake_cli(self, name, body, folder=None):
        """A Python stand-in for a CLI, by default in ~/.local/bin where the short PATH misses it."""
        return self.script((folder or self.home / ".local/bin") / name, "#!%s\n%s" % (PYTHON, body))

    def wait_for(self, condition, timeout=5.0):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > deadline:
                self.fail("condition not met within %.1f s" % timeout)
            time.sleep(0.02)

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def kill_later(self, pid):
        def kill():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.addCleanup(kill)
