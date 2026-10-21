import os
from pathlib import Path
import signal
import subprocess
import time
import unittest
from unittest import mock

import bridge
from helpers import IsolatedTest, PYTHON, ROOT

# Holds the marker like a live sign-in worker: exclusive flock for life, its own pid inside.
LOCK_HOLDER = '''
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.ftruncate(fd, 0)
os.write(fd, str(os.getpid()).encode())
print("locked", flush=True)
time.sleep(30)
'''


class MarkerTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.fake_cli("claude", "")
        self.marker = bridge.login_file("claude", "default")
        bridge.accounts.private_dir(self.marker.parent)

    def hold(self):
        holder = self.script(self.root / "holder.py", "#!%s\n%s" % (PYTHON, LOCK_HOLDER))
        process = subprocess.Popen([str(holder), str(self.marker)], stdout=subprocess.PIPE,
                                   start_new_session=True)
        self.addCleanup(self.reap, process)
        self.assertEqual(process.stdout.readline(), b"locked\n")
        process.stdout.close()
        return process

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.wait()

    def fake_worker(self, body, started=None):
        """Swaps the real login worker for a script, so login() never starts a real sign-in. With
        `started`, login() waits for that file before reading the worker, however slow its start."""
        script = self.fake_cli("worker", body, self.root)
        real_start = bridge.start

        def start(command, *args, **kwargs):
            process = real_start([str(script)] if "login_worker" in command else command, *args, **kwargs)
            self.addCleanup(self.reap, process)
            if started and "login_worker" in command:
                self.wait_for(lambda: started.exists() and started.read_text())
            return process
        patch = mock.patch.object(bridge, "start", side_effect=start)
        patch.start()
        self.addCleanup(patch.stop)

    def test_stale_marker_with_a_reused_pid_is_removed_and_never_signalled(self):
        stranger = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        self.addCleanup(self.reap, stranger)
        self.marker.write_text(str(stranger.pid))
        self.assertFalse(bridge.is_connecting("claude", "default"))
        self.assertFalse(self.marker.exists())
        self.marker.write_text(str(stranger.pid))
        self.fake_worker('print(\'{"ready": true}\')')
        with mock.patch.object(bridge.os, "killpg", wraps=os.killpg) as killpg:
            bridge.login("claude", "default")
        self.assertNotIn(stranger.pid, [call.args[0] for call in killpg.call_args_list])
        self.assertIsNone(stranger.poll())

    def test_live_worker_is_connecting_and_is_stopped_before_a_new_sign_in(self):
        holder = self.hold()
        self.assertTrue(bridge.is_connecting("claude", "default"))
        self.assertEqual(bridge.worker_pid("claude", "default"), holder.pid)
        self.fake_worker('print(\'{"ready": true}\')')
        bridge.login("claude", "default")
        self.assertEqual(holder.wait(timeout=2), -signal.SIGTERM)
        self.assertFalse(bridge.is_connecting("claude", "default"))

    def test_worker_that_cannot_be_signalled_is_reported(self):
        holder = self.hold()
        self.fake_worker('print(\'{"ready": true}\')')
        with mock.patch.object(bridge.os, "killpg", side_effect=PermissionError), \
             mock.patch.object(bridge, "STOP_WAIT", 0.1), \
             self.assertRaisesRegex(RuntimeError, "still closing"):
            bridge.login("claude", "default")
        self.assertIsNone(holder.poll())
        self.assertTrue(bridge.is_connecting("claude", "default"))

    def test_marker_vanishing_between_checks_is_not_connecting(self):
        with mock.patch.object(Path, "exists", return_value=True):
            self.assertIsNone(bridge.worker_pid("claude", "default"))

    def test_second_worker_for_the_same_account_refuses(self):
        self.hold()
        with self.assertRaisesRegex(RuntimeError, "Another sign-in"):
            bridge.login_worker("claude", "default")

    def test_worker_releases_its_marker(self):
        with mock.patch.object(bridge, "claude_login_worker") as worker:
            bridge.login_worker("claude", "default")
        worker.assert_called_once()
        self.assertFalse(self.marker.exists())
        self.assertFalse(bridge.is_connecting("claude", "default"))
        self.assertEqual(self.marker.parent.stat().st_mode & 0o777, 0o700)

    def test_sigterm_ends_the_worker_its_cli_and_its_marker(self):
        pid_file = self.root / "claude.pid"
        self.fake_cli("claude", '''
import os, time
open(%r, "w").write(str(os.getpid()))
time.sleep(30)
''' % str(pid_file))
        worker = subprocess.Popen([PYTHON, str(ROOT / "bridge.py"), "login_worker", "claude", "default"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True, env=dict(os.environ))
        self.addCleanup(self.reap, worker)
        self.wait_for(lambda: pid_file.exists() and pid_file.read_text() and bridge.is_connecting("claude", "default"))
        cli = int(pid_file.read_text())
        self.kill_later(cli)
        bridge.stop_login("claude", "default")
        self.assertEqual(worker.wait(timeout=5), 128 + signal.SIGTERM)
        self.wait_for(lambda: not self.alive(cli), 3)
        self.assertFalse(self.marker.exists())
        self.assertIsNone(bridge.login_error("claude", "default"))

    def test_login_without_the_cli_says_so(self):
        (self.home / ".local/bin/claude").unlink()
        with mock.patch.object(bridge, "start") as start, \
             self.assertRaisesRegex(bridge.CliMissing, "Claude Code CLI not found. Install it, then try again."):
            bridge.login("claude", "default")
        start.assert_not_called()

    def test_ready_timeout_kills_the_worker_process_group(self):
        pid_file = self.root / "worker.pid"
        self.fake_worker('''
import os, subprocess, sys, time
child = subprocess.Popen(["/bin/sleep", "30"])
open(sys.argv[0] + ".pid", "w").write(str(child.pid))
time.sleep(30)
''', started=pid_file)
        with mock.patch.object(bridge, "READY_TIMEOUT", 0.5), \
             self.assertRaisesRegex(RuntimeError, "Timed out opening the sign-in page"):
            bridge.login("claude", "default")
        grandchild = int(pid_file.read_text())
        self.kill_later(grandchild)
        self.wait_for(lambda: not self.alive(grandchild), 3)
        self.assertEqual(bridge.CHILDREN, set())

    def test_worker_error_is_reported_and_previous_error_cleared(self):
        bridge.accounts.write_private(bridge.login_error_file("claude", "default"), "previous failure")
        self.fake_worker('print(\'{"error": "Could not open the sign-in page in a browser"}\')')
        with self.assertRaisesRegex(RuntimeError, "Could not open the sign-in page in a browser"):
            bridge.login("claude", "default")
        self.assertIsNone(bridge.login_error("claude", "default"))

    def test_hiding_a_card_stops_its_sign_in(self):
        bridge.save_cards([{"provider": "claude", "id": "default"}])
        holder = self.hold()
        with mock.patch.object(bridge, "check_account", return_value={"status": "signed_out"}):
            bridge.remove_card("claude", "default")
        self.assertEqual(holder.wait(timeout=2), -signal.SIGTERM)
        self.assertEqual(bridge.visible_cards(), [])

    def test_login_status_is_cheap_and_clears_errors_once_signed_in(self):
        bridge.accounts.write_private(bridge.login_error_file("claude", "default"), "failed")
        with mock.patch.object(bridge, "run", return_value=(1, '{"loggedIn": false}')):
            self.assertEqual(bridge.login_status("claude", "default"),
                             {"connecting": False, "status": "signed_out", "login_error": "failed"})
        self.hold()
        with mock.patch.object(bridge, "run", return_value=(0, '{"loggedIn": true}')):
            self.assertEqual(bridge.login_status("claude", "default"),
                             {"connecting": True, "status": "signed_in", "login_error": None})
        self.assertIsNone(bridge.login_error("claude", "default"))


FAKE_CLAUDE_LOGIN = '''
import os, subprocess, sys, time
mode = os.environ["FAKE_MODE"]
subprocess.call([os.environ["BROWSER"], "http://insecure.example" if mode == "bad-url" else "https://claude.ai/oauth"])
if mode == "noisy":
    sys.stdout.write("x" * 300000 + "\\n")
if mode == "fail":
    print("Opening browser...")
    print("\\x1b[31mError: OAuth error: invalid_grant\\x1b[0m")
    print("")
    sys.exit(1)
if mode in ("hang", "bad-url"):
    time.sleep(30)
print("Login successful.")
'''


class ClaudeLoginWorkerTests(IsolatedTest):
    def run_worker(self, mode, browser="opened"):
        self.fake_cli("claude", FAKE_CLAUDE_LOGIN)
        os.environ["FAKE_MODE"] = mode
        script = self.script(self.root / "browser.sh", '#!/bin/sh\nprintf %s > "$USAGI_BROWSER_MARKER"\n' % browser)
        with mock.patch.object(bridge, "BROWSER_SCRIPT", script if browser else bridge.BROWSER_SCRIPT), \
             mock.patch.object(bridge, "LOGIN_TIMEOUT", 1.5), \
             mock.patch.object(bridge, "login_ready") as ready:
            try:
                bridge.login_worker("claude", "default")
                error = None
            except RuntimeError as exc:
                error = str(exc)
        self.assertEqual(bridge.CHILDREN, set())
        self.assertFalse(bridge.login_file("claude", "default").exists())
        self.assertEqual(bridge.login_error("claude", "default"), error)
        return error, ready.call_count

    def test_success(self):
        self.assertEqual(self.run_worker("ok"), (None, 1))

    def test_lots_of_output_never_blocks_the_cli(self):
        self.assertEqual(self.run_worker("noisy"), (None, 1))

    def test_failure_after_the_browser_opened_is_recorded_with_the_cli_reason(self):
        error, ready = self.run_worker("fail")
        self.assertEqual(error, "Claude sign-in failed: Error: OAuth error: invalid_grant")
        self.assertEqual(ready, 1)

    def test_deadline_is_recorded(self):
        started = time.monotonic()
        self.assertEqual(self.run_worker("hang"), ("Sign-in timed out. Try again.", 1))
        self.assertLess(time.monotonic() - started, 5)

    def test_browser_refusal_is_recorded(self):
        # The real open-browser.sh refuses a non-https URL before opening anything.
        self.assertEqual(self.run_worker("bad-url", browser=None),
                         ("Could not open the sign-in page in a browser", 0))

    def test_cli_that_is_not_a_program_is_explained(self):
        self.script(self.home / ".local/bin/claude", "this is not a program\n")
        with self.assertRaises(OSError):
            bridge.login_worker("claude", "default")
        self.assertEqual(bridge.login_error("claude", "default"),
                         "~/.local/bin/claude is not a program this Mac can run")
        self.assertEqual(bridge.CHILDREN, set())


FAKE_CODEX_LOGIN = '''
import json, os, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif message.get("id") == 2:
        print("[]\\n" + json.dumps({"id": 2, "result": {"type": "chatgpt", "authUrl": "https://auth.openai.com/x"}}),
              flush=True)
        if os.environ["FAKE_MODE"] == "fail":
            print(json.dumps({"method": "account/login/completed",
                              "params": {"success": False, "error": "Token exchange failed: 401"}}), flush=True)
        if os.environ["FAKE_MODE"] == "ok":
            print(json.dumps({"method": "account/login/completed", "params": {"success": True}}), flush=True)
'''


class CodexLoginWorkerTests(IsolatedTest):
    def run_worker(self, mode):
        (self.home / ".codex-work").mkdir()
        (self.home / ".codex-work/.usagi-profile").write_text("")
        self.fake_cli("codex", FAKE_CODEX_LOGIN)
        os.environ["FAKE_MODE"] = mode
        with mock.patch.object(bridge, "LOGIN_TIMEOUT", 1), \
             mock.patch.object(bridge, "open_browser") as browser, \
             mock.patch.object(bridge, "login_ready"):
            try:
                bridge.login_worker("codex", "work")
                error = None
            except RuntimeError as exc:
                error = str(exc)
        browser.assert_called_once_with("https://auth.openai.com/x")
        self.assertEqual(bridge.login_error("codex", "work"), error)
        self.assertEqual(bridge.CHILDREN, set())
        return error

    def test_success(self):
        self.assertIsNone(self.run_worker("ok"))

    def test_failed_codex_login_is_recorded_for_the_card(self):
        self.assertEqual(self.run_worker("fail"), "Token exchange failed: 401")

    def test_codex_login_timeout_is_recorded_for_the_card(self):
        self.assertEqual(self.run_worker("hang"), "Sign-in timed out. Try again.")


if __name__ == "__main__":
    unittest.main()
