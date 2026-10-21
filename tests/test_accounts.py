from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

import usagi_accounts as accounts
import usagi_usage as usage
from helpers import IsolatedTest


class ProfileTests(IsolatedTest):
    def profile(self, folder_name, marker=".usagi-profile"):
        folder = self.home / folder_name
        folder.mkdir()
        if marker:
            (folder / marker).write_text("")

    def test_profiles_accept_usagi_and_agent_kit_markers_only(self):
        for name, marker in (("work", ".usagi-profile"), ("team", ".agentkit-profile"), ("plain", None)):
            self.profile(".codex-" + name, marker)
        self.profile(".codex-Bad_Name")
        self.profile(".codex-work\n")  # match() with $ would have taken it as "work"
        self.assertEqual(accounts.profiles("codex"), ["default", "team", "work"])

    def test_names_must_match_in_full(self):
        for name in ("work\n", "default", "Work", "-work", "a" * 32, "", None):
            with self.assertRaises(accounts.AccountError):
                accounts.check_name(name)
        accounts.check_name("a" * 31)

    def test_profiles_sort_naturally_with_default_first(self):
        for name in ("account-10", "work", "account-2", "account-1"):
            self.profile(".claude-" + name)
        self.assertEqual(accounts.profiles("claude"), ["default", "account-1", "account-2", "account-10", "work"])
        self.assertEqual(sorted(["work", "account-10", "default", "account-2"], key=accounts.sort_key),
                         ["default", "account-2", "account-10", "work"])

    def test_selected_account_round_trips_and_unknown_falls_back(self):
        accounts.add("work", "codex")
        accounts.use("work", "codex")
        self.assertEqual(accounts.active("codex"), "work")
        self.assertEqual(accounts.active("claude"), "default")
        state = self.config / "state"
        self.assertEqual(state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o700)
        self.assertEqual((state / "account-codex").stat().st_mode & 0o777, 0o600)
        (state / "account-claude").write_text("ghost\n")
        self.assertEqual(accounts.active("claude"), "default")
        with self.assertRaises(accounts.AccountError):
            accounts.use("ghost", "codex")

    def test_new_profile_shares_settings_without_replacing_existing(self):
        (self.home / ".codex").mkdir()
        (self.home / ".codex/config.toml").write_text("model = 'x'\n")
        (self.home / ".codex/AGENTS.md").write_text("shared\n")
        target = self.home / ".codex-work"
        target.mkdir()
        (target / "AGENTS.md").write_text("own\n")
        _, codex, linked, skipped = accounts.add("work", "codex")
        self.assertTrue((codex / "config.toml").is_symlink())
        self.assertEqual((codex / "AGENTS.md").read_text(), "own\n")
        self.assertEqual((linked["codex"], skipped), (["config.toml"], []))

    def test_new_profiles_carry_both_markers(self):
        _, codex, _, _ = accounts.add("work", "codex")
        self.assertTrue((codex / ".usagi-profile").exists())
        self.assertTrue((codex / ".agentkit-profile").exists())
        self.assertEqual((codex / ".usagi-profile").stat().st_mode & 0o777, 0o600)
        (codex / ".agentkit-profile").write_text("Agent Kit's own\n")
        accounts.add("work", "codex")
        self.assertEqual((codex / ".agentkit-profile").read_text(), "Agent Kit's own\n")

    def test_settings_with_credentials_are_not_shared(self):
        claude = self.home / ".claude"
        claude.mkdir()
        (claude / "CLAUDE.md").write_text("shared\n")
        for number, settings in enumerate((
                {"apiKeyHelper": "~/bin/key.sh"},
                {"awsAuthRefresh": "aws sso login"},
                {"awsCredentialExport": "~/bin/aws-creds.sh"},
                *({"env": {key: "placeholder"}} for key in (
                    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "AWS_BEARER_TOKEN_BEDROCK",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID",
                    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "GOOGLE_APPLICATION_CREDENTIALS")),
                "{not json",
                [])):
            (claude / "settings.json").write_text(settings if isinstance(settings, str) else json.dumps(settings))
            profile, _, linked, skipped = accounts.add("account-%d" % number, "claude")
            self.assertEqual(skipped, ["settings.json"], settings)
            self.assertFalse((profile / "settings.json").exists())
            self.assertIn("CLAUDE.md", linked["claude"])
        (claude / "settings.json").write_text(json.dumps({"env": {"DISABLE_TELEMETRY": "1"}, "model": "opus"}))
        profile, _, linked, skipped = accounts.add("plain", "claude")
        self.assertEqual(skipped, [])
        self.assertTrue((profile / "settings.json").is_symlink())

    def test_private_dir_and_atomic_private_files(self):
        target = self.home / "a/b/c.txt"
        accounts.write_private(target, "one")
        accounts.write_private(target, "two")
        self.assertEqual(target.read_text(), "two")
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        for folder in (self.home / "a", self.home / "a/b"):
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        self.assertEqual(sorted(path.name for path in (self.home / "a/b").iterdir()), ["c.txt"])


class ClaudeUsageTests(unittest.TestCase):
    def test_cached_utilization_maps_windows_and_expires_past_resets(self):
        now = 1_800_000_000
        cached = {"cachedUsageUtilization": {"fetchedAtMs": (now - 60) * 1000, "utilization": {"limits": [
            {"kind": "session", "percent": 13, "resets_at": now + 3600},
            {"kind": "weekly_all", "percent": 16, "resets_at": "2027-01-15T10:00:00+00:00"},
            {"kind": "weekly_scoped", "percent": 40, "resets_at": now - 1,
             "scope": {"model": {"display_name": "Fable"}}}]}}}
        windows = self.read(cached, now)
        self.assertEqual(windows["5h"]["used_percent"], 13)
        self.assertGreater(windows["7d"]["resets_at"], now)
        self.assertEqual(windows["fable"]["used_percent"], 0.0)
        self.assertTrue(windows["fable"]["reset"])
        self.assertNotIn("reset", windows["5h"])

    def read(self, cached, now):
        with tempfile.TemporaryDirectory() as folder:
            profile = Path(folder) / ".claude.json"
            profile.write_text(json.dumps(cached))
            return usage.read_claude_cached(profile, now=now)

    def test_staleness_depends_on_the_window(self):
        now = 1_800_000_000
        windows = {"5h": {"used_percent": 1, "resets_at": now + 60}, "7d": {"used_percent": 1, "resets_at": now + 60},
                   "fable": {"used_percent": 1, "resets_at": now + 60}}
        stale = lambda age: {label: window["stale"] for label, window in usage._live(windows, now - age, now).items()}
        self.assertEqual(stale(29 * 60), {"5h": False, "7d": False, "fable": False})
        self.assertEqual(stale(31 * 60), {"5h": True, "7d": False, "fable": False})
        self.assertEqual(stale(3 * 3600 + 1), {"5h": True, "7d": True, "fable": True})
        self.assertTrue(usage._live(windows, None, now)["7d"]["stale"])
        reset = usage._live({"5h": {"used_percent": 50, "resets_at": now - 60}}, now - 7200, now)["5h"]
        self.assertEqual((reset["used_percent"], reset["reset"], reset["stale"]), (0.0, True, False))

    def test_timestamps_parse_on_python_3_9(self):
        utc = datetime(2026, 10, 15, 10, 19, 59, tzinfo=timezone.utc).timestamp()
        for text, expected in (("2026-10-15T10:19:59.644864+00:00", utc + 0.644864),
                               ("2026-10-15T10:19:59.1Z", utc + 0.1),
                               ("2026-10-15T10:19:59.12345Z", utc + 0.12345),
                               ("2026-10-15T10:19:59.123456789Z", utc + 0.123456),
                               ("2026-10-15T10:19:59", utc),
                               ("2026-10-15T10:19:59.5", utc + 0.5),
                               ("2026-10-15T19:19:59+09:00", utc)):
            self.assertAlmostEqual(usage._epoch(text), expected, places=5, msg=text)
        for value in ("soon", "", None, [], True):
            self.assertIsNone(usage._epoch(value))
        self.assertEqual(usage._epoch(12.5), 12.5)

    def test_missing_caches_read_as_empty(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(usage.read_claude_cached(Path(folder) / "none.json"), {})
            self.assertEqual(usage.read_claude(Path(folder) / "none.json"), {})
        self.assertEqual(usage.merge_windows({"5h": {"captured_at": 1, "used_percent": 1}},
                                             {"5h": {"captured_at": 2, "used_percent": 2}})["5h"]["used_percent"], 2)


if __name__ == "__main__":
    unittest.main()
