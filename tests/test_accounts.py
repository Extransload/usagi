import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import usagi_accounts as accounts
import usagi_usage as usage


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.home = Path(self.folder.name)
        self.patches = [mock.patch.object(accounts, "HOME", self.home),
                        mock.patch.object(accounts, "STATE", self.home / "state"),
                        mock.patch.object(accounts, "AGENTKIT", self.home / "no-agentkit")]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        self.folder.cleanup()

    def test_profiles_accept_usagi_and_agent_kit_markers_only(self):
        for name, marker in (("work", ".usagi-profile"), ("team", ".agentkit-profile"), ("plain", None)):
            folder = self.home / (".codex-" + name)
            folder.mkdir()
            if marker:
                (folder / marker).write_text("")
        (self.home / ".codex-Bad_Name").mkdir()
        (self.home / ".codex-Bad_Name" / ".usagi-profile").write_text("")
        self.assertEqual(accounts.profiles("codex"), ["default", "team", "work"])

    def test_selected_account_round_trips_and_unknown_falls_back(self):
        accounts.add("work", "codex")
        accounts.use("work", "codex")
        self.assertEqual(accounts.active("codex"), "work")
        self.assertEqual(accounts.active("claude"), "default")
        (self.home / "state" / "account-claude").write_text("ghost\n")
        self.assertEqual(accounts.active("claude"), "default")
        with self.assertRaises(accounts.AccountError):
            accounts.use("ghost", "codex")

    def test_new_profile_shares_settings_without_replacing_existing(self):
        (self.home / ".codex").mkdir()
        (self.home / ".codex" / "config.toml").write_text("model = 'x'\n")
        (self.home / ".codex" / "AGENTS.md").write_text("shared\n")
        target = self.home / ".codex-work"
        target.mkdir()
        (target / "AGENTS.md").write_text("own\n")
        _, codex, linked = accounts.add("work", "codex")
        self.assertTrue((codex / ".usagi-profile").exists())
        self.assertFalse((codex / ".agentkit-profile").exists())
        self.assertTrue((codex / "config.toml").is_symlink())
        self.assertEqual((codex / "AGENTS.md").read_text(), "own\n")
        self.assertEqual(linked["codex"], ["config.toml"])

    def test_agent_kit_sees_profiles_made_by_usagi(self):
        (self.home / "no-agentkit").mkdir()
        _, codex, _ = accounts.add("work", "codex")
        self.assertTrue((codex / ".agentkit-profile").exists())


class ClaudeUsageTests(unittest.TestCase):
    def test_cached_utilization_maps_windows_and_expires_past_resets(self):
        now = 1_800_000_000
        cached = {"cachedUsageUtilization": {"fetchedAtMs": (now - 60) * 1000, "utilization": {"limits": [
            {"kind": "session", "percent": 13, "resets_at": now + 3600},
            {"kind": "weekly_all", "percent": 16, "resets_at": "2027-01-15T10:00:00+00:00"},
            {"kind": "weekly_scoped", "percent": 40, "resets_at": now - 1,
             "scope": {"model": {"display_name": "Fable"}}}]}}}
        with tempfile.TemporaryDirectory() as folder:
            profile = Path(folder) / ".claude.json"
            profile.write_text(json.dumps(cached))
            windows = usage.read_claude_cached(profile, now=now)
        self.assertEqual(windows["5h"]["used_percent"], 13)
        self.assertGreater(windows["7d"]["resets_at"], now)
        self.assertEqual(windows["fable"]["used_percent"], 0.0)
        self.assertTrue(windows["fable"]["reset"])

    def test_missing_caches_read_as_empty(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(usage.read_claude_cached(Path(folder) / "none.json"), {})
            self.assertEqual(usage.read_claude(Path(folder) / "none.json"), {})
        self.assertEqual(usage.merge_windows({"5h": {"captured_at": 1, "used_percent": 1}},
                                             {"5h": {"captured_at": 2, "used_percent": 2}})["5h"]["used_percent"], 2)


if __name__ == "__main__":
    unittest.main()
