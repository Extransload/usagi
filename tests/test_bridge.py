import contextlib
import errno
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import threading
import time
import unittest
from unittest import mock

import bridge
from helpers import IsolatedTest, PYTHON, ROOT


class StatusTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.claude = self.fake_cli("claude", "")
        self.codex = self.fake_cli("codex", "")

    def test_default_claude_uses_cli_login_without_overriding_config_dir(self):
        os.environ.update(ANTHROPIC_API_KEY="placeholder", CLAUDE_CONFIG_DIR="/tmp/wrong-profile")
        with mock.patch.object(bridge, "run", return_value=(0, '{"loggedIn": true}')) as run:
            self.assertEqual(bridge.cli_status("claude", "default"), "signed_in")
        command, env, _ = run.call_args.args
        self.assertEqual(command, [str(self.claude), "auth", "status", "--json"])
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("CLAUDE_CONFIG_DIR", env)

    def test_named_account_checks_its_own_config_dir(self):
        with mock.patch.object(bridge, "run", return_value=(0, '{"loggedIn": true}')) as run:
            self.assertEqual(bridge.cli_status("claude", "work"), "signed_in")
        self.assertEqual(run.call_args.args[1]["CLAUDE_CONFIG_DIR"], str(self.home / ".claude-work"))

    def test_claude_answers_map_to_status(self):
        for answer, expected in (((1, '{"loggedIn": false}'), "signed_out"),
                                 ((0, '{"loggedIn": true}'), "signed_in"),
                                 ((1, '{"loggedIn": true}'), "unknown"),
                                 ((127, "env: node: No such file or directory"), "unknown"),
                                 ((0, "[]"), "unknown"),
                                 (None, "unknown")):  # timed out or could not start
            with mock.patch.object(bridge, "run", return_value=answer):
                self.assertEqual(bridge.cli_status("claude", "default"), expected, answer)

    def test_codex_login_status_maps_exit_codes(self):
        for answer, expected in (((0, ""), "signed_in"), ((1, ""), "signed_out"),
                                 ((-9, ""), "unknown"), (None, "unknown")):
            with mock.patch.object(bridge, "run", return_value=answer) as run:
                self.assertEqual(bridge.cli_status("codex", "default"), expected)
            self.assertNotIn("CODEX_HOME", run.call_args.args[1])

    def test_missing_cli_is_its_own_status(self):
        self.claude.unlink()
        self.codex.unlink()
        with mock.patch.object(bridge, "run") as run:
            self.assertEqual(bridge.cli_status("claude", "default"), "cli_missing")
            self.assertEqual(bridge.codex_live("default"), {"status": "cli_missing"})
        run.assert_not_called()


class SnapshotTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.fake_cli("claude", "")
        self.fake_cli("codex", "")
        for name in ("work", "account-2", "account-10"):
            for prefix in (".claude-", ".codex-"):
                (self.home / (prefix + name)).mkdir()
                (self.home / (prefix + name) / ".usagi-profile").write_text("")

    def test_cards_are_preserved_and_accounts_listed_in_natural_order(self):
        cards = [{"provider": "claude", "id": "account-10"}, {"provider": "claude", "id": "work"},
                 {"provider": "claude", "id": "account-2"}, {"provider": "claude", "id": "default"},
                 {"provider": "codex", "id": "default"}]
        bridge.save_cards(cards)
        with mock.patch.object(bridge, "check_account", return_value={"status": "signed_out"}):
            result = bridge.snapshot()
        self.assertEqual(result["cards"], cards)
        self.assertEqual([account["id"] for account in result["providers"]["claude"]["accounts"]],
                         ["default", "account-2", "account-10", "work"])
        account = result["providers"]["codex"]["accounts"][0]
        self.assertEqual((account["status"], account["logged_in"], account["connecting"]), ("signed_out", False, False))
        self.assertEqual(result["providers"]["claude"]["active"], "default")

    def test_snapshot_reports_cli_and_version(self):
        (self.home / ".local/bin/codex").unlink()
        plist = bridge.APP_PATH / "Contents/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "9.8.7"}))
        bridge.save_cards([{"provider": "codex", "id": "default"}])
        result = bridge.snapshot()
        self.assertEqual(result["version"], "9.8.7")
        self.assertEqual((result["providers"]["claude"]["cli"], result["providers"]["codex"]["cli"]), (True, False))
        self.assertEqual(result["providers"]["codex"]["accounts"][0]["status"], "cli_missing")
        self.assertFalse(result["providers"]["codex"]["accounts"][0]["logged_in"])

    def test_version_falls_back_to_the_source_tree_info_plist(self):
        with open(ROOT / "Info.plist", "rb") as file:
            expected = plistlib.load(file)["CFBundleShortVersionString"]
        self.assertEqual(bridge.app_version(), expected)

    def test_one_failing_account_does_not_hide_the_others(self):
        bridge.save_cards([{"provider": "codex", "id": "default"}, {"provider": "codex", "id": "work"},
                           {"provider": "claude", "id": "default"}])

        def live(name):
            if name == "work":
                raise AttributeError("'list' object has no attribute 'get'")
            return {"status": "signed_in", "email": "a@example.com", "windows": {}}

        with mock.patch.object(bridge, "codex_live", side_effect=live), \
             mock.patch.object(bridge, "cli_status", return_value="signed_in"), \
             mock.patch.object(bridge.readers, "read_claude_cached", side_effect=ValueError("broken")):
            result = bridge.snapshot()
        codex = {account["id"]: account for account in result["providers"]["codex"]["accounts"]}
        self.assertEqual(codex["default"]["status"], "signed_in")
        self.assertEqual(codex["default"]["email"], "a@example.com")
        self.assertEqual(codex["work"]["status"], "unknown")
        self.assertFalse(codex["work"]["logged_in"])
        self.assertEqual(result["providers"]["claude"]["accounts"][0]["status"], "unknown")

    def test_first_run_checks_each_account_once_and_concurrently(self):
        calls, together = [], threading.Barrier(2, timeout=5)  # broken unless both run at once

        def check(provider, name):
            calls.append((provider, name))
            together.wait()
            return {"status": "signed_in"}

        with mock.patch.object(bridge, "check_account", side_effect=check):
            result = bridge.snapshot()
        self.assertEqual(sorted(calls), [("claude", "default"), ("codex", "default")])
        self.assertEqual(result["cards"], [{"provider": "claude", "id": "default"}, {"provider": "codex", "id": "default"}])

    def test_accounts_are_checked_concurrently(self):
        bridge.save_cards([{"provider": provider, "id": name} for provider in ("claude", "codex")
                           for name in ("default", "work")])
        together = threading.Barrier(4, timeout=5)
        with mock.patch.object(bridge, "check_account",
                               side_effect=lambda *_: together.wait() and {"status": "signed_out"}
                               or {"status": "signed_out"}):
            result = bridge.snapshot()
        self.assertEqual([account["status"] for account in result["providers"]["codex"]["accounts"]],
                         ["signed_out", "signed_out"])

    def test_first_run_add_auto_and_remove_check_each_account_once(self):
        for action, expected in ((["add_auto", "codex"], [("claude", "default"), ("codex", "account-2"),
                                                          ("codex", "default")]),
                                 (["remove", "codex", "default"], [("claude", "default"), ("codex", "default")])):
            with self.subTest(action=action[0]):
                bridge.CARD_FILE.unlink(missing_ok=True)
                calls = []
                with mock.patch.object(bridge, "check_account",
                                       side_effect=lambda *key: calls.append(key) or {"status": "signed_in"}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    bridge.main(action)
                self.assertEqual(sorted(calls), expected)

    def test_logged_out_account_never_exposes_cached_usage(self):
        bridge.save_cards([{"provider": "claude", "id": "default"}])
        with mock.patch.object(bridge, "cli_status", return_value="signed_out"), \
             mock.patch.object(bridge.readers, "read_claude_cached") as cached:
            account = bridge.snapshot()["providers"]["claude"]["accounts"][0]
        self.assertEqual(account["windows"], {})
        self.assertIsNone(account["source"])
        self.assertIsNone(account["email"])
        cached.assert_not_called()

    def test_signed_in_claude_reads_its_cache_with_staleness(self):
        now = time.time()
        (self.home / ".claude.json").write_text(json.dumps({
            "oauthAccount": {"emailAddress": "c@example.com", "organizationRateLimitTier": "default_claude_max_20x"},
            "cachedUsageUtilization": {"fetchedAtMs": (now - 3600) * 1000, "utilization": {"limits": [
                {"kind": "session", "percent": 13, "resets_at": now + 3600},
                {"kind": "weekly_all", "percent": 16, "resets_at": now + 86400}]}}}))
        bridge.save_cards([{"provider": "claude", "id": "default"}])
        with mock.patch.object(bridge, "cli_status", return_value="signed_in"):
            account = bridge.snapshot()["providers"]["claude"]["accounts"][0]
        self.assertEqual((account["email"], account["plan"]), ("c@example.com", "Max 20x"))
        self.assertTrue(account["windows"]["5h"]["stale"])
        self.assertFalse(account["windows"]["7d"]["stale"])

    def test_login_error_is_cleared_once_signed_in(self):
        bridge.save_cards([{"provider": "codex", "id": "work"}, {"provider": "codex", "id": "default"}])
        for name in ("work", "default"):
            bridge.accounts.write_private(bridge.login_error_file("codex", name), "Token exchange failed")
        statuses = {"work": "signed_in", "default": "signed_out"}
        with mock.patch.object(bridge, "codex_live", side_effect=lambda name: {"status": statuses[name]}):
            accounts = {account["id"]: account for account in bridge.snapshot()["providers"]["codex"]["accounts"]}
        self.assertIsNone(accounts["work"]["login_error"])
        self.assertFalse(bridge.login_error_file("codex", "work").exists())
        self.assertEqual(accounts["default"]["login_error"], "Token exchange failed")

    def test_cards_can_be_added_and_removed_without_touching_cli_login(self):
        with mock.patch.object(bridge.accounts, "add") as add:
            bridge.add_card("codex", "default")
            self.assertEqual(bridge.visible_cards(), [{"provider": "codex", "id": "default"}])
            bridge.remove_card("codex", "default")
            self.assertEqual(bridge.visible_cards(), [])
        add.assert_not_called()

    def test_adding_an_older_profile_backfills_the_agent_kit_marker_only(self):
        bridge.save_cards([])
        (self.home / ".codex-account-2/.agentkit-profile").write_text("Agent Kit's own\n")
        team = self.home / ".claude-team"
        team.mkdir()
        (team / ".agentkit-profile").write_text("")
        with mock.patch.object(bridge.accounts, "add") as add:
            bridge.add_card("claude", "work")
            bridge.add_card("codex", "account-2")
            bridge.add_card("claude", "team")
            bridge.add_card("claude", "default")
        add.assert_not_called()
        marker = self.home / ".claude-work/.agentkit-profile"
        self.assertEqual(marker.read_text(), "Created by Usagi; safe to keep.\n")
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.home / ".codex-work/.agentkit-profile").exists())
        self.assertEqual((self.home / ".codex-account-2/.agentkit-profile").read_text(), "Agent Kit's own\n")
        self.assertFalse((team / ".usagi-profile").exists())
        self.assertFalse((self.home / ".claude/.agentkit-profile").exists())

    def test_provider_tile_reuses_hidden_profile_then_creates_the_next_one(self):
        bridge.save_cards([])
        self.assertEqual(bridge.add_next_card("claude"), "default")
        self.assertEqual(bridge.add_next_card("claude"), "account-2")
        self.assertEqual(bridge.add_next_card("claude"), "account-10")
        self.assertEqual(bridge.add_next_card("claude"), "work")
        self.assertEqual(bridge.add_next_card("claude"), "account-3")
        self.assertTrue((self.home / ".claude-account-3/.usagi-profile").exists())

    def test_add_auto_reports_the_added_account_and_add_is_gone(self):
        bridge.save_cards([{"provider": "codex", "id": "default"}])
        output = io.StringIO()
        with mock.patch.object(bridge, "check_account", return_value={"status": "signed_out"}), \
             contextlib.redirect_stdout(output):
            bridge.main(["add_auto", "codex"])
        result = json.loads(output.getvalue())
        self.assertEqual(result["added"], "account-2")
        self.assertIn({"provider": "codex", "id": "account-2"}, result["cards"])
        with self.assertRaisesRegex(ValueError, "Invalid command"):
            bridge.main(["add", "codex", "work"])

    def test_errors_carry_an_optional_code(self):
        self.assertEqual(bridge.error_output(bridge.CliMissing("codex")),
                         {"error": "Codex CLI not found. Install it, then try again.", "code": "cli_missing"})
        self.assertEqual(bridge.error_output(ValueError("Invalid command")), {"error": "Invalid command"})

    def test_system_errors_read_as_sentences(self):
        claude = str(self.home / ".local/bin/claude")
        for exc, expected in ((OSError(errno.ENOEXEC, "Exec format error", claude),
                               "~/.local/bin/claude is not a program this Mac can run"),
                              (PermissionError(errno.EACCES, "Permission denied", "/opt/x"),
                               "Usagi is not allowed to use /opt/x"),
                              (OSError(errno.ENOSPC, "No space left on device", claude), "The disk is full"),
                              (OSError(errno.EIO, "Input/output error", claude), "Input/output error: ~/.local/bin/claude"),
                              (OSError(errno.EIO, "Input/output error"), "Input/output error"),
                              (OSError("Usagi is quitting"), "Usagi is quitting")):
            with self.subTest(exc=exc):
                self.assertEqual(bridge.error_output(exc), {"error": expected})

    def test_profile_folder_that_cannot_be_made_is_explained(self):
        bridge.save_cards([{"provider": "claude", "id": "default"}])
        for name in ("work", "account-2", "account-10"):
            (self.home / (".claude-" + name) / ".usagi-profile").unlink()
            (self.home / (".claude-" + name)).rmdir()
        self.home.chmod(0o555)
        self.addCleanup(self.home.chmod, 0o755)
        with mock.patch.object(bridge, "check_account", return_value={"status": "signed_out"}), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaises(PermissionError) as raised:
            bridge.main(["add_auto", "claude"])
        self.assertEqual(bridge.error_output(raised.exception),
                         {"error": "Usagi is not allowed to use ~/.claude-account-2"})


FAKE_LIVE_CODEX = '''
import json, sys, time
if sys.argv[1:] == ["login", "status"]:
    raise SystemExit(0)
def out(text):
    sys.stdout.write(text)
    sys.stdout.flush()
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        out('[1, 2]\\n"text"\\n42\\nnull\\nnot json\\n')
        out(json.dumps({"id": 1, "result": {}}) + "\\n")
    elif message.get("id") == 3:
        out(json.dumps({"id": 2, "method": "item/commandExecution/requestApproval", "params": {}}) + "\\n")
        out(json.dumps({"method": "remoteControl/status/changed", "params": {}}) + "\\n")
        out(json.dumps({"id": [2], "result": {}}) + "\\n")
        account = json.dumps({"id": 2, "result": {"account": %s}})
        out(account[:15])
        time.sleep(0.2)
        out(account[15:] + "\\n" + json.dumps({"id": 3, "result": {"rateLimits": %s}}) + "\\n")
'''


class ReorderTests(IsolatedTest):
    def test_reorder_moves_services_and_keeps_account_order(self):
        for name in ("account-2", "account-3"):
            bridge.accounts.add(name, "codex")
        cards = [{"provider": "claude", "id": "default"}, {"provider": "codex", "id": "account-3"},
                 {"provider": "codex", "id": "account-2"}]
        bridge.save_cards(cards)
        bridge.reorder_cards("codex,claude")
        self.assertEqual(bridge.visible_cards(), [cards[1], cards[2], cards[0]])
        bridge.reorder_cards("claude")  # services left out keep their place after the named ones
        self.assertEqual(bridge.visible_cards(), [cards[0], cards[1], cards[2]])
        for bad in ("claude,claude", "gemini,claude", ""):
            with self.assertRaises(bridge.accounts.AccountError):
                bridge.reorder_cards(bad)


class CodexLiveTests(IsolatedTest):
    def live(self, account, limits='{"primary": {"usedPercent": 40, "windowDurationMins": 300}}'):
        self.fake_cli("codex", FAKE_LIVE_CODEX % (account, limits))
        return bridge.codex_live("default")

    def test_noise_server_requests_and_split_lines_are_handled(self):
        info = self.live('{"type": "chatgpt", "email": "a@example.com", "planType": "team"}')
        self.assertEqual((info["status"], info["email"], info["plan"]), ("signed_in", "a@example.com", "Team"))
        self.assertEqual(info["windows"]["5h"]["used_percent"], 40)
        self.assertFalse(info["windows"]["5h"]["stale"])

    def test_free_limit_resets_are_counted_soonest_first(self):
        now = 1_800_000_000
        resets = {"availableCount": 3, "credits": [
            {"status": "available", "expiresAt": now + 900},
            {"status": "available", "expiresAt": now + 100},
            {"status": "used", "expiresAt": now + 500},
            {"status": "available", "expiresAt": now - 1},
            {"status": "available"}, "junk"]}
        self.assertEqual(bridge.codex_extras(resets, now=now),
                         [{"kind": "resets", "count": 3, "expires_at": [now + 100, now + 900]}])
        for empty in ({"credits": []}, {"credits": None}, None, False, {"credits": [{"status": "used"}]},
                      {"availableCount": 0, "credits": None}, {"credits": [{"status": "available", "expiresAt": 0}]}):
            self.assertEqual(bridge.codex_extras(empty, now=now), [])
        self.assertEqual(bridge.codex_extras({"availableCount": 2, "credits": None}, now=now),
                         [{"kind": "resets", "count": 2, "expires_at": []}], "only the count is known")
        capped = {"availableCount": 5, "credits": [{"status": "available", "expiresAt": now + 60}] * 3}
        self.assertEqual(bridge.codex_extras(capped, now=now)[0]["count"], 5, "a capped list")

    def test_plan_names_are_capitalized_like_claude(self):
        self.assertEqual([bridge.plan_name(value) for value in ("free", "team", "plus", "pro", "Business", "team_plus", "", None, 3)],
                         ["Free", "Team", "Plus", "Pro", "Business", "Team Plus", None, None, None])

    def test_signed_out_and_api_key_accounts(self):
        self.assertEqual(self.live("None"), {"status": "signed_out"})
        self.assertEqual(self.live('{"type": "apiKey"}'), {"status": "signed_in"})
        self.assertEqual(self.live("[]"), {"status": "signed_in"})  # no usable answer: `codex login status`

    def test_cli_without_account_methods_or_app_server_falls_back_to_login_status(self):
        older = '''
import json, sys
if sys.argv[1:] == ["login", "status"]:
    raise SystemExit(%d)
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif "id" in message:
        print(json.dumps({"id": message["id"], "error": {"code": -32601, "message": "Method not found"}}), flush=True)
'''
        self.fake_cli("codex", older % 0)
        self.assertEqual(bridge.codex_live("default"), {"status": "signed_in"})
        self.fake_cli("codex", older % 1)
        self.assertEqual(bridge.codex_live("default"), {"status": "signed_out"})
        self.fake_cli("codex", 'import sys\nraise SystemExit(0 if sys.argv[1:] == ["login", "status"] else 2)\n')
        self.assertEqual(bridge.codex_live("default"), {"status": "signed_in"})

    def test_malformed_limits_are_ignored(self):
        info = self.live('{"type": "chatgpt", "email": 7}', limits='{"primary": [1], "secondary": "x"}')
        self.assertEqual((info["status"], info["email"], info["windows"]), ("signed_in", None, {}))
        info = self.live('{"type": "chatgpt"}', limits="[]")
        self.assertEqual(info["windows"], {})

    def test_partial_line_never_completed_respects_the_deadline(self):
        self.fake_cli("codex", '''
import json, sys, time
if sys.argv[1:] == ["login", "status"]:
    time.sleep(30)
for line in sys.stdin:
    if json.loads(line).get("id") == 1:
        sys.stdout.write('{"id": 1, "res')
        sys.stdout.flush()
        time.sleep(30)
''')
        with mock.patch.object(bridge, "APP_SERVER_TIMEOUT", 0.5), mock.patch.object(bridge, "STATUS_TIMEOUT", 0.5):
            started = time.monotonic()
            self.assertEqual(bridge.codex_live("default"), {"status": "unknown"})
        self.assertLess(time.monotonic() - started, 4)

    def test_app_server_process_group_is_stopped(self):
        self.fake_cli("codex", '''
import os, subprocess, sys, time
if sys.argv[1] != "app-server":
    raise SystemExit(3)
child = subprocess.Popen(["/bin/sleep", "30"], stdout=subprocess.DEVNULL)
open(sys.argv[0] + ".pid", "w").write(str(child.pid))
os.close(1)  # codex_live sees EOF only once the pid is written, however slowly this started
time.sleep(30)
''')
        pid_file = Path(str(self.home / ".local/bin/codex") + ".pid")
        self.assertEqual(bridge.codex_live("default"), {"status": "unknown"})
        pid = int(pid_file.read_text())
        self.kill_later(pid)
        self.wait_for(lambda: not self.alive(pid), 3)
        self.assertEqual(bridge.CHILDREN, set())

    def test_windows_are_keyed_by_duration_not_position(self):
        team = bridge.codex_windows({"primary": {"usedPercent": 93, "windowDurationMins": 300, "resetsAt": 1},
                                     "secondary": {"usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 2}})
        free = bridge.codex_windows({"primary": {"usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 3},
                                     "secondary": None})
        self.assertEqual(sorted(team), ["5h", "7d"])
        self.assertEqual(team["5h"]["used_percent"], 93)
        self.assertEqual(list(free), ["30d"])
        self.assertEqual(free["30d"]["resets_at"], 3)
        self.assertEqual(bridge.codex_windows({"primary": {"usedPercent": True}}), {})


class TerminationTests(IsolatedTest):
    @staticmethod
    def zombie(pid):
        state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
        return state.strip().startswith("Z")

    def test_stop_ends_the_group_of_a_cli_that_already_exited(self):
        pid_file = self.root / "grandchild.pid"
        process = bridge.start([PYTHON, "-c", 'import os, subprocess, sys\n'
                                'child = subprocess.Popen(["/bin/sleep", "30"])\n'
                                'open(sys.argv[1] + ".tmp", "w").write(str(child.pid))\n'
                                'os.rename(sys.argv[1] + ".tmp", sys.argv[1])', str(pid_file)])
        self.wait_for(pid_file.exists)
        grandchild = int(pid_file.read_text())
        self.kill_later(grandchild)
        self.wait_for(lambda: self.zombie(process.pid))  # exited, not reaped yet
        bridge.stop(process)
        self.wait_for(lambda: not self.alive(grandchild), 3)
        self.assertEqual(bridge.CHILDREN, set())

    def test_stop_never_signals_a_cli_reaped_before(self):
        process = bridge.start(["/usr/bin/true"])
        process.wait()
        with mock.patch.object(bridge.os, "killpg") as killpg:
            bridge.stop(process)
        killpg.assert_not_called()
        self.assertEqual(bridge.CHILDREN, set())

    def test_sigterm_kills_children_that_ignore_it_and_starts_no_new_ones(self):
        status_ran = self.root / "status-ran"
        self.fake_cli("claude", 'print(\'{"loggedIn": false}\')\nraise SystemExit(1)')
        self.fake_cli("codex", '''
import os, signal, sys, time
if sys.argv[1:] == ["login", "status"]:
    open(%r, "w").write("ran")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[0] + ".pid", "w").write(str(os.getpid()))
time.sleep(30)
''' % str(status_ran))
        pid_file = Path(str(self.home / ".local/bin/codex") + ".pid")
        process = subprocess.Popen([PYTHON, str(ROOT / "bridge.py"), "snapshot"], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=dict(os.environ))
        self.addCleanup(process.kill)
        self.wait_for(lambda: pid_file.exists() and pid_file.read_text())
        pid = int(pid_file.read_text())
        self.kill_later(pid)
        started = time.monotonic()
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM)
        self.assertLess(time.monotonic() - started, 1.9)  # Swift SIGKILLs the bridge after 2 s
        self.wait_for(lambda: not self.alive(pid), 1)
        self.assertFalse(status_ran.exists())

    def test_sigterm_stops_the_cli_children(self):
        self.fake_cli("claude", 'print(\'{"loggedIn": false}\')\nraise SystemExit(1)')
        self.fake_cli("codex", '''
import os, sys, time
open(sys.argv[0] + ".pid", "w").write(str(os.getpid()))
time.sleep(30)
''')
        pid_file = Path(str(self.home / ".local/bin/codex") + ".pid")
        process = subprocess.Popen([PYTHON, str(ROOT / "bridge.py"), "snapshot"], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=dict(os.environ))
        self.addCleanup(process.kill)
        self.wait_for(lambda: pid_file.exists() and pid_file.read_text())
        pid = int(pid_file.read_text())
        self.kill_later(pid)
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM)
        self.wait_for(lambda: not self.alive(pid), 3)

    def test_handler_never_ignores_sigterm_for_later_children(self):
        with mock.patch.object(bridge, "TERMINATING", False), mock.patch.object(bridge, "CHILDREN", set()), \
             self.assertRaises(SystemExit):
            bridge.terminate(signal.SIGTERM, None)
        self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)


class BrowserTests(IsolatedTest):
    def test_chrome_first_without_applescript(self):
        with mock.patch.object(bridge, "run", return_value=(0, "")) as run:
            bridge.open_browser("https://auth.openai.com/example")
        self.assertEqual(run.call_args_list[0].args[0],
                         ["/usr/bin/open", "-a", "Google Chrome", "https://auth.openai.com/example"])
        self.assertEqual(run.call_count, 1)

    def test_default_browser_when_chrome_is_missing(self):
        with mock.patch.object(bridge, "run", side_effect=[(1, ""), (0, "")]) as run:
            bridge.open_browser("https://auth.openai.com/example")
        self.assertEqual(run.call_args_list[1].args[0], ["/usr/bin/open", "https://auth.openai.com/example"])
        with mock.patch.object(bridge, "run", return_value=None), \
             self.assertRaisesRegex(RuntimeError, "Could not open"):
            bridge.open_browser("https://auth.openai.com/example")

    def test_only_https_urls_open(self):
        with mock.patch.object(bridge, "run") as run:
            for url in ("http://auth.openai.com/x", "file:///etc/passwd", "https:///nohost"):
                with self.assertRaises(ValueError):
                    bridge.open_browser(url)
        run.assert_not_called()


class UpdateTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.prefix = self.root / "brew"
        (self.prefix / "Caskroom/usagi").mkdir(parents=True)
        self.calls = self.root / "brew-calls"
        self.script(self.prefix / "bin/brew", '#!/bin/sh\necho "$*" >> "%s"\necho "brew $*"\n' % self.calls)
        patch = mock.patch.object(bridge, "BREW_PREFIXES", (str(self.prefix),))
        patch.start()
        self.addCleanup(patch.stop)

    def test_homebrew_install_starts_one_background_worker(self):
        with mock.patch.object(bridge, "start") as start:
            self.assertEqual(bridge.update(), {"updating": True})
        command = start.call_args.args[0]
        self.assertEqual(command[1:], [str(Path(bridge.__file__).resolve()), "update_worker"])
        self.assertEqual(bridge.APP_PATH, self.root / "Usagi.app")

    def test_running_update_is_not_started_twice(self):
        lock = bridge.update_lock()
        self.addCleanup(os.close, lock)
        with mock.patch.object(bridge, "start") as start:
            self.assertEqual(bridge.update(), {"updating": True})
            bridge.update_worker()
        start.assert_not_called()
        self.assertFalse(self.calls.exists())

    def test_worker_upgrades_the_qualified_cask_and_reopens(self):
        log = self.config / "update.log"
        log.parent.mkdir(parents=True)
        log.parent.chmod(0o755)
        log.write_text("old run\n")
        log.chmod(0o644)
        bridge.update_worker()
        self.assertEqual(self.calls.read_text().splitlines(), ["update", "upgrade --cask extransload/tap/usagi"])
        text = log.read_text()
        self.assertNotIn("old run", text)
        self.assertIn("$ /usr/bin/open %s" % bridge.APP_PATH, text)
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)

    def test_source_and_other_installs_get_the_release_page(self):
        url = "https://github.com/Extransload/usagi/releases/latest"
        marker = bridge.APP_PATH / "Contents/Resources/source-install"
        marker.parent.mkdir(parents=True)
        marker.write_text("")
        with mock.patch.object(bridge, "start") as start:
            self.assertEqual(bridge.update(), {"release_url": url, "source_install": True})
            marker.unlink()
            with mock.patch.object(bridge, "BREW_PREFIXES", ()):
                self.assertEqual(bridge.update(), {"release_url": url})
        start.assert_not_called()


class ConfigTests(IsolatedTest):
    def test_legacy_config_moves_once_and_never_overwrites(self):
        legacy, current = bridge.LEGACY_CONFIG_DIR, bridge.CONFIG_DIR
        legacy.mkdir(parents=True)
        (legacy / "cards.json").write_text('[{"provider": "codex", "id": "default"}]')
        bridge.migrate_legacy_config()
        legacy.mkdir()
        (legacy / "cards.json").write_text("[]")
        bridge.migrate_legacy_config()
        self.assertEqual((current / "cards.json").read_text(), '[{"provider": "codex", "id": "default"}]')
        self.assertEqual((legacy / "cards.json").read_text(), "[]")

    def test_state_files_are_private(self):
        bridge.save_cards([])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.home / ".config").stat().st_mode & 0o777, 0o700)
        self.assertEqual(bridge.CARD_FILE.stat().st_mode & 0o777, 0o600)

    def test_command_line_keeps_state_under_usagi_config(self):
        self.fake_cli("claude", 'print(\'{"loggedIn": false}\')\nraise SystemExit(1)')
        self.fake_cli("codex", "raise SystemExit(1)")
        result = subprocess.run([PYTHON, str(ROOT / "bridge.py"), "add_auto", "claude"], capture_output=True,
                                text=True, timeout=20, env=dict(os.environ))
        self.assertEqual(result.returncode, 0, result.stdout)
        snapshot = json.loads(result.stdout)
        self.assertEqual(snapshot["added"], "default")
        self.assertEqual(snapshot["providers"]["claude"]["accounts"][0]["status"], "signed_out")
        self.assertTrue((self.home / ".config/usagi/cards.json").exists())
        result = subprocess.run([PYTHON, str(ROOT / "bridge.py"), "bogus"], capture_output=True, text=True,
                                timeout=20, env=dict(os.environ))
        self.assertEqual((result.returncode, json.loads(result.stdout)), (1, {"error": "Invalid command"}))


if __name__ == "__main__":
    unittest.main()
