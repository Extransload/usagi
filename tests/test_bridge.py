import os
import sys
import io
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import bridge


class SignInTests(unittest.TestCase):
    def test_default_claude_uses_cli_login_without_overriding_config_dir(self):
        completed = mock.Mock(returncode=0, stdout='{"loggedIn": true}')
        with mock.patch.dict(os.environ, {
            "ANTHROPIC_API_KEY": "placeholder",
            "CLAUDE_CONFIG_DIR": "/tmp/wrong-profile",
        }), mock.patch.object(bridge.subprocess, "run", return_value=completed) as run:
            self.assertTrue(bridge.signed_in("claude", "default", Path("/tmp/default"), Path("/tmp/codex")))
        args, kwargs = run.call_args
        self.assertEqual(args[0][1:], ["auth", "status", "--json"])
        self.assertNotIn("ANTHROPIC_API_KEY", kwargs["env"])
        self.assertNotIn("CLAUDE_CONFIG_DIR", kwargs["env"])

    def test_named_account_checks_its_own_config_dir(self):
        completed = mock.Mock(returncode=0, stdout='{"loggedIn": true}')
        with mock.patch.object(bridge.subprocess, "run", return_value=completed) as run:
            self.assertTrue(bridge.signed_in("claude", "work", Path("/tmp/claude-work"), Path("/tmp/codex-work")))
        self.assertEqual(run.call_args.kwargs["env"]["CLAUDE_CONFIG_DIR"], "/tmp/claude-work")

    def test_codex_status_failure_is_logged_out(self):
        completed = mock.Mock(returncode=1, stdout="Not logged in")
        with mock.patch.object(bridge.subprocess, "run", return_value=completed) as run:
            self.assertFalse(bridge.signed_in("codex", "default", Path("/tmp/claude"), Path("/tmp/codex")))
        self.assertNotIn("CODEX_HOME", run.call_args.kwargs["env"])

    def test_sign_in_starts_app_worker_without_iterm(self):
        worker = mock.Mock()
        worker.stdout = io.StringIO('{"ready": true}\n')
        worker.poll.return_value = None
        with mock.patch.object(bridge.accounts, "profiles", return_value=["default", "work"]), \
             mock.patch.object(bridge, "is_connecting", return_value=False), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=worker) as launch, \
             mock.patch.object(bridge.selectors, "DefaultSelector") as selector:
            selector.return_value.select.return_value = [(None, None)]
            bridge.login("codex", "work")
        command = launch.call_args.args[0]
        self.assertEqual(command[-3:], ["login_worker", "codex", "work"])
        self.assertTrue(launch.call_args.kwargs["start_new_session"])

    def test_sign_in_failure_is_not_reported_as_success(self):
        worker = mock.Mock()
        worker.stdout = io.StringIO('{"error": "Could not open the sign-in page"}\n')
        worker.poll.return_value = 1
        with mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge, "is_connecting", return_value=False), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=worker), \
             mock.patch.object(bridge.selectors, "DefaultSelector") as selector:
            selector.return_value.select.return_value = [(None, None)]
            with self.assertRaisesRegex(RuntimeError, "Could not open the sign-in page"):
                bridge.login("claude", "default")

    def test_retry_stops_existing_login_before_opening_new_one(self):
        worker = mock.Mock()
        worker.stdout = io.StringIO('{"ready": true}\n')
        worker.poll.return_value = None
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "LOGIN_DIR", Path(folder)), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge.os, "getpgid", return_value=123), \
             mock.patch.object(bridge.os, "killpg") as stop, \
             mock.patch.object(bridge.os, "kill", side_effect=ProcessLookupError), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=worker) as launch, \
             mock.patch.object(bridge.selectors, "DefaultSelector") as selector:
            path = bridge.login_file("claude", "default")
            path.write_text("123")
            selector.return_value.select.return_value = [(None, None)]
            with mock.patch.object(bridge, "is_connecting", return_value=True):
                bridge.login("claude", "default")
            self.assertFalse(path.exists())
        stop.assert_called_once_with(123, bridge.signal.SIGTERM)
        launch.assert_called_once()

    def test_worker_keeps_selected_profile_and_opens_browser(self):
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "LOGIN_DIR", Path(folder)), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["work"]), \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path("/tmp/claude-work"), Path("/tmp/codex-work"))), \
             mock.patch.object(bridge, "codex_login_worker") as worker:
            bridge.login_worker("codex", "work")
        self.assertEqual(worker.call_args.args[1]["CODEX_HOME"], "/tmp/codex-work")
        with mock.patch.object(bridge.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            bridge.open_browser("https://auth.openai.com/example")
        self.assertEqual(run.call_args_list[0].args[0][:4],
                         ["/usr/bin/open", "-a", "Google Chrome", "https://auth.openai.com/example"])

    def test_browser_falls_back_to_default_when_chrome_is_missing(self):
        results = [mock.Mock(returncode=1), mock.Mock(returncode=0)]
        with mock.patch.object(bridge.subprocess, "run", side_effect=results) as run:
            bridge.open_browser("https://auth.openai.com/example")
        self.assertEqual(run.call_args_list[1].args[0], ["/usr/bin/open", "https://auth.openai.com/example"])
        self.assertEqual(run.call_count, 2)

    def test_cards_can_be_added_and_removed_without_touching_cli_login(self):
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "CARD_FILE", Path(folder) / "cards.json"), \
             mock.patch.object(bridge, "signed_in", return_value=False), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge.accounts, "active", return_value="default"), \
             mock.patch.object(bridge.accounts, "add") as add:
            bridge.add_card("codex", "default")
            self.assertEqual(bridge.visible_cards(), [{"provider": "codex", "id": "default"}])
        add.assert_not_called()

    def test_default_card_removal_preserves_cli_profile(self):
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "CARD_FILE", Path(folder) / "cards.json"), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge.accounts, "use") as use, \
             mock.patch.object(bridge.accounts, "add") as add:
            bridge.save_cards([{"provider": "codex", "id": "default"}])
            bridge.remove_card("codex", "default")
            self.assertEqual(bridge.visible_cards(), [])
        use.assert_not_called()
        add.assert_not_called()

    def test_multiple_cards_for_one_provider_are_preserved(self):
        cards = [{"provider": "claude", "id": "default"},
                 {"provider": "claude", "id": "work"},
                 {"provider": "codex", "id": "default"}]
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "CARD_FILE", Path(folder) / "cards.json"), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default", "work"]), \
             mock.patch.object(bridge.accounts, "active", return_value="default"), \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path("/tmp/claude"), Path("/tmp/codex"))), \
             mock.patch.object(bridge, "signed_in", return_value=False):
            bridge.save_cards(cards)
            result = bridge.snapshot()
        self.assertEqual(result["cards"], cards)
        self.assertEqual(len(result["providers"]["claude"]["accounts"]), 2)

    def test_provider_tile_reuses_hidden_default_without_opening_login(self):
        with mock.patch.object(bridge, "visible_cards", return_value=[]), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge, "add_card") as add, \
             mock.patch.object(bridge.accounts, "use") as use, \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path("/tmp/claude"), Path("/tmp/codex"))), \
             mock.patch.object(bridge, "signed_in", return_value=False), \
             mock.patch.object(bridge, "login") as login:
            self.assertEqual(bridge.add_next_card("claude"), "default")
        add.assert_called_once_with("claude", "default")
        use.assert_not_called()
        login.assert_not_called()

    def test_provider_tile_creates_next_profile_when_all_are_shown(self):
        with mock.patch.object(bridge, "visible_cards", return_value=[{"provider": "codex", "id": "default"}]), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["default"]), \
             mock.patch.object(bridge, "add_card") as add, \
             mock.patch.object(bridge.accounts, "use") as use, \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path("/tmp/claude"), Path("/tmp/codex"))), \
             mock.patch.object(bridge, "signed_in", return_value=False), \
             mock.patch.object(bridge, "login") as login:
            self.assertEqual(bridge.add_next_card("codex"), "account-2")
        add.assert_called_once_with("codex", "account-2")
        use.assert_not_called()
        login.assert_not_called()

    def test_logged_out_account_never_exposes_cached_usage(self):
        with mock.patch.object(bridge.accounts, "PROVIDERS", ("claude",)), \
             mock.patch.object(bridge, "visible_cards", return_value=[{"provider": "claude", "id": "default"}]), \
             mock.patch.object(bridge.accounts, "active", return_value="default"), \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path("/tmp/claude"), Path("/tmp/codex"))), \
             mock.patch.object(bridge, "signed_in", return_value=False), \
             mock.patch.object(bridge.readers, "read_claude_cached") as cached:
            account = bridge.snapshot()["providers"]["claude"]["accounts"][0]
        self.assertEqual(account["windows"], {})
        self.assertIsNone(account["source"])
        self.assertIsNone(account["email"])
        cached.assert_not_called()


FAKE_CODEX = '''#!{python}
import json, os, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(json.dumps({{"id": 1, "result": {{}}}}), flush=True)
    elif message.get("id") == 2:
        print(json.dumps({{"id": 2, "result": {{"type": "chatgpt", "authUrl": "https://auth.openai.com/x"}}}}), flush=True)
        if os.environ["FAKE_MODE"] == "fail":
            print(json.dumps({{"method": "account/login/completed",
                              "params": {{"success": False, "error": "Token exchange failed: 401"}}}}), flush=True)
'''


class LoginResultTests(unittest.TestCase):
    def run_codex_worker(self, folder, mode):
        fake = Path(folder) / "codex"
        fake.write_text(FAKE_CODEX.format(python=sys.executable))
        fake.chmod(0o755)
        with mock.patch.object(bridge, "LOGIN_DIR", Path(folder) / "logins"), \
             mock.patch.object(bridge, "LOGIN_TIMEOUT", 1), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["work"]), \
             mock.patch.object(bridge.accounts, "dirs", return_value=(Path(folder), Path(folder))), \
             mock.patch.object(bridge, "auth_context", return_value=(str(fake), dict(os.environ, FAKE_MODE=mode))), \
             mock.patch.object(bridge, "open_browser"), \
             mock.patch.object(bridge, "login_ready"):
            with self.assertRaises(RuntimeError) as raised:
                bridge.login_worker("codex", "work")
            return str(raised.exception), bridge.login_error("codex", "work")

    def test_failed_codex_login_is_recorded_for_the_card(self):
        with tempfile.TemporaryDirectory() as folder:
            message, recorded = self.run_codex_worker(folder, "fail")
        self.assertIn("Token exchange failed: 401", message)
        self.assertEqual(recorded, message)

    def test_codex_login_timeout_is_recorded_for_the_card(self):
        with tempfile.TemporaryDirectory() as folder:
            message, recorded = self.run_codex_worker(folder, "hang")
        self.assertIn("timed out", message)
        self.assertEqual(recorded, message)

    def test_new_login_clears_previous_failure(self):
        worker = mock.Mock()
        worker.stdout = io.StringIO('{"ready": true}\n')
        worker.poll.return_value = None
        with tempfile.TemporaryDirectory() as folder, \
             mock.patch.object(bridge, "LOGIN_DIR", Path(folder)), \
             mock.patch.object(bridge.accounts, "profiles", return_value=["work"]), \
             mock.patch.object(bridge, "is_connecting", return_value=False), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=worker), \
             mock.patch.object(bridge.selectors, "DefaultSelector") as selector:
            selector.return_value.select.return_value = [(None, None)]
            bridge.login_error_file("codex", "work").write_text("previous failure")
            bridge.login("codex", "work")
            self.assertIsNone(bridge.login_error("codex", "work"))


FAKE_LIVE_CODEX = '''#!{python}
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(json.dumps({{"id": 1, "result": {{}}}}), flush=True)
    elif message.get("id") == 3:
        account = {{"id": 2, "result": {{"account": {{"type": "chatgpt", "email": "a@example.com", "planType": "team"}}}}}}
        limits = {{"id": 3, "result": {{"rateLimits": {{"primary": {{"usedPercent": 40, "windowDurationMins": 300}}}}}}}}
        sys.stdout.write(json.dumps(account) + "\\n" + json.dumps(limits) + "\\n")
        sys.stdout.flush()
'''


class CodexWindowTests(unittest.TestCase):
    def test_live_read_handles_responses_arriving_in_one_chunk(self):
        with tempfile.TemporaryDirectory() as folder:
            fake = Path(folder) / "codex"
            fake.write_text(FAKE_LIVE_CODEX.format(python=sys.executable))
            fake.chmod(0o755)
            with mock.patch.object(bridge, "auth_context", return_value=(str(fake), dict(os.environ))):
                started = time.monotonic()
                info = bridge.codex_live("default", Path(folder), Path(folder))
        self.assertEqual(info["windows"]["5h"]["used_percent"], 40)
        self.assertLess(time.monotonic() - started, 4)

    def test_windows_are_keyed_by_duration_not_position(self):
        team = bridge.codex_windows({"primary": {"usedPercent": 93, "windowDurationMins": 300, "resetsAt": 1},
                                     "secondary": {"usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 2}})
        free = bridge.codex_windows({"primary": {"usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 3},
                                     "secondary": None})
        self.assertEqual(sorted(team), ["5h", "7d"])
        self.assertEqual(team["5h"]["used_percent"], 93)
        self.assertEqual(list(free), ["30d"])
        self.assertEqual(free["30d"]["resets_at"], 3)


class CliLookupTests(unittest.TestCase):
    def test_cli_is_found_outside_a_finder_launch_path(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            for version in ("v9.11.2", "v20.1.0", "v22.21.1"):
                (home / ".nvm/versions/node" / version / "bin").mkdir(parents=True)
                (home / ".nvm/versions/node" / version / "bin/codex").write_text("")
                (home / ".nvm/versions/node" / version / "bin/codex").chmod(0o755)
            with mock.patch.object(bridge.shutil, "which", return_value=None), \
                 mock.patch.object(bridge, "CLI_FOLDERS", ()), \
                 mock.patch.object(bridge.Path, "home", return_value=home):
                found = bridge.find_cli("codex")
                missing = bridge.find_cli("claude")
        self.assertEqual(found, str(home / ".nvm/versions/node/v22.21.1/bin/codex"))
        self.assertEqual(missing, "claude")

    def test_path_lookup_wins(self):
        with mock.patch.object(bridge.shutil, "which", return_value="/somewhere/codex"):
            self.assertEqual(bridge.find_cli("codex"), "/somewhere/codex")


class ConfigTests(unittest.TestCase):
    def test_legacy_config_moves_once_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as folder:
            legacy, current = Path(folder) / "AgentUsageBar", Path(folder) / "usagi"
            legacy.mkdir()
            (legacy / "cards.json").write_text('[{"provider": "codex", "id": "default"}]')
            with mock.patch.object(bridge, "LEGACY_CONFIG_DIR", legacy), \
                 mock.patch.object(bridge, "CONFIG_DIR", current):
                bridge.migrate_legacy_config()
                legacy.mkdir()
                (legacy / "cards.json").write_text("[]")
                bridge.migrate_legacy_config()
            self.assertEqual((current / "cards.json").read_text(), '[{"provider": "codex", "id": "default"}]')
            self.assertEqual((legacy / "cards.json").read_text(), "[]")

    def test_card_and_login_state_live_under_usagi_config(self):
        self.assertEqual(bridge.CONFIG_DIR, Path.home() / ".config/usagi")
        self.assertEqual(bridge.CARD_FILE.parent, bridge.CONFIG_DIR)
        self.assertEqual(bridge.LOGIN_DIR.parent, bridge.CONFIG_DIR)


if __name__ == "__main__":
    unittest.main()
