import contextlib
import io
import json
import os
import time
import unittest
from unittest import mock

import bridge
from helpers import IsolatedTest, PYTHON


class CliLookupTests(IsolatedTest):
    def executable(self, path):
        return self.script(path, "#!/bin/sh\n")

    def test_newest_node_install_wins(self):
        for version in ("v9.11.2", "v20.1.0", "v22.21.1"):
            self.executable(self.home / ".nvm/versions/node" / version / "bin/codex")
        for root, version in ((".local/share/fnm/node-versions", "v22.3.0"),
                              ("Library/Application Support/fnm/node-versions", "v23.0.0"),
                              ("Library/Application Support/fnm/node-versions", "v18.0.0")):
            self.executable(self.home / root / version / "installation/bin/claude")
        self.assertEqual(bridge.find_cli("codex"), str(self.home / ".nvm/versions/node/v22.21.1/bin/codex"))
        self.assertEqual(bridge.find_cli("claude"),
                         str(self.home / "Library/Application Support/fnm/node-versions/v23.0.0/installation/bin/claude"))

    def test_other_install_spots(self):
        for folder in (".asdf/shims", ".local/share/mise/shims", "Library/pnpm", ".yarn/bin", ".claude/local"):
            with self.subTest(folder=folder):
                bridge.FOUND.clear()
                path = self.executable(self.home / folder / "claude")
                self.assertEqual(bridge.find_cli("claude"), str(path))
                path.unlink()

    def test_path_lookup_wins(self):
        self.executable(self.home / ".local/bin/codex")
        found = self.executable(self.root / "path-bin/codex")
        os.environ["PATH"] = "%s:%s" % (found.parent, os.environ["PATH"])
        self.assertEqual(bridge.find_cli("codex"), str(found))

    def test_npm_script_runs_with_the_short_finder_path(self):
        """`#!/usr/bin/env node` needs node, which lives next to the script, not on /usr/bin:/bin."""
        node_bin = self.home / ".nvm/versions/node/v22.0.0/bin"
        self.script(node_bin / "node", '#!/bin/sh\nexec "%s" "$@"\n' % PYTHON)
        self.script(node_bin / "claude", '#!/usr/bin/env node\nimport json\nprint(json.dumps({"loggedIn": True}))\n')
        # A symlinked install: node sits next to the real file, not next to the link.
        package = self.root / "lib/codex/bin"
        self.script(package / "node", '#!/bin/sh\nexec "%s" "$@"\n' % PYTHON)
        self.script(package / "codex.js", "#!/usr/bin/env node\nraise SystemExit(0)\n")
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".local/bin/codex").symlink_to(package / "codex.js")
        self.assertEqual(os.environ["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(bridge.cli_status("claude", "default"), "signed_in")
        self.assertEqual(bridge.cli_status("codex", "default"), "signed_in")

    def test_npm_prefix_script_finds_node_in_another_folder(self):
        """~/.npm-global/bin has no node next to it; node is in Homebrew, not on the Finder PATH."""
        brew = self.root / "homebrew/bin"
        self.script(brew / "node", '#!/bin/sh\nexec "%s" "$@"\n' % PYTHON)
        self.script(self.home / ".npm-global/bin/claude",
                    '#!/usr/bin/env node\nimport json\nprint(json.dumps({"loggedIn": True}))\n')
        self.assertEqual(os.environ["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        with mock.patch.object(bridge, "CLI_FOLDERS", (str(brew),)):
            self.assertEqual(bridge.cli_status("claude", "default"), "signed_in")

    def test_bun_and_the_login_shell_path_are_on_the_cli_path(self):
        self.script(self.home / ".bun/bin/bun", '#!/bin/sh\nexec "%s" "$@"\n' % PYTHON)
        self.script(self.home / ".local/bin/claude",
                    '#!/usr/bin/env bun\nimport json\nprint(json.dumps({"loggedIn": True}))\n')
        shell_only = self.root / "shell-only/bin"  # on PATH only after the user's startup files ran
        self.script(shell_only / "node", '#!/bin/sh\nexec "%s" "$@"\n' % PYTHON)
        self.script(self.home / ".yarn/bin/codex", "#!/usr/bin/env node\nraise SystemExit(0)\n")
        self.assertEqual(bridge.cli_status("claude", "default"), "signed_in")
        self.assertEqual(bridge.cli_status("codex", "default"), "unknown")
        bridge.accounts.write_private(bridge.CONFIG_DIR / "cli-paths.json",
                                      json.dumps({"login_path": "relative:%s:/usr/bin" % shell_only}))
        self.assertEqual(bridge.cli_status("codex", "default"), "signed_in")
        _, env = bridge.auth_context("codex", "default")
        self.assertNotIn("relative", env["PATH"].split(":"))

    def test_missing_cli(self):
        self.assertIsNone(bridge.find_cli("claude"))


class LoginShellTests(IsolatedTest):
    def shell(self, setup="", delay=0, after=""):
        """A login shell that logs its calls, prints startup noise (the last line unfinished), runs
        `setup` like a ~/.zshrc, then the command it was given, then `after` like ~/.zlogout."""
        self.calls = self.root / "shell-calls"
        shell = self.script(self.root / "fake-shell", '''#!/bin/sh
echo "$1" >> "%s"
sleep %s
echo "Welcome back!"
printf 'Last login: today'
%s
eval "$2"
%s
''' % (self.calls, delay, setup, after))
        os.environ["SHELL"] = str(shell)

    def call_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def cache(self):
        return json.loads((bridge.CONFIG_DIR / "cli-paths.json").read_text())

    def test_answer_is_cached_revalidated_and_asked_for_on_user_actions_only(self):
        target = self.script(self.root / "odd place/claude", "#!/bin/sh\n")
        self.shell('PATH="%s:$PATH"' % target.parent)
        self.assertIsNone(bridge.find_cli("claude"))  # a background refresh never starts the shell
        self.assertEqual(self.call_count(), 0)
        self.assertEqual(bridge.find_cli("claude", ask=True), str(target))
        self.assertEqual(self.calls.read_text(), "-ilc\n")
        self.assertEqual(self.cache()["claude"]["path"], str(target))
        self.assertEqual(self.cache()["login_path"], "%s:%s" % (target.parent, os.environ["PATH"]))
        self.assertEqual((bridge.CONFIG_DIR / "cli-paths.json").stat().st_mode & 0o777, 0o600)
        bridge.FOUND.clear()
        self.assertEqual(bridge.find_cli("claude"), str(target))  # the cached answer, no shell
        self.assertEqual(self.call_count(), 1)
        target.chmod(0o644)  # no longer executable
        bridge.FOUND.clear()
        self.assertIsNone(bridge.find_cli("claude"))
        self.assertEqual(self.call_count(), 1)
        self.assertIsNone(bridge.find_cli("claude", ask=True))  # asked again; the clean miss is cached
        self.assertEqual(self.call_count(), 2)
        self.assertIsNone(self.cache()["claude"]["path"])

    def test_only_one_absolute_executable_answer_counts(self):
        for setup in ("alias claude='npx claude'", "claude() { :; }",
                      'command() { echo "%s"; }' % (self.root / "missing/claude"),
                      "command() { echo /bin/sh; echo /bin/sh; }"):
            with self.subTest(setup=setup):
                self.shell(setup)
                bridge.FOUND.clear()
                self.assertIsNone(bridge.find_cli("claude", ask=True))
                self.assertIsNone(self.cache()["claude"]["path"])

    def test_snapshot_asks_only_for_the_refresh_button(self):
        target = self.script(self.root / "odd place/codex", "#!/bin/sh\n")
        self.shell('PATH="%s:$PATH"' % target.parent)
        bridge.save_cards([])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            bridge.main(["snapshot"])
        self.assertEqual(self.call_count(), 0)
        self.assertFalse(json.loads(output.getvalue())["providers"]["codex"]["cli"])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            bridge.main(["snapshot", "--ask-shell"])
        self.assertEqual(self.call_count(), 2)  # claude (a clean miss) and codex
        self.assertTrue(json.loads(output.getvalue())["providers"]["codex"]["cli"])
        with self.assertRaisesRegex(ValueError, "Invalid command"):
            bridge.main(["snapshot", "--bogus"])

    def test_slow_garbled_or_cut_short_answers_are_not_cached(self):
        for options in ({"delay": 30}, {"setup": "echo /bin/sh; exit 0"},
                        {"setup": "command() { kill -9 $$; }"}):
            with self.subTest(options=options):
                self.shell(**options)
                bridge.FOUND.clear()
                with mock.patch.object(bridge, "SHELL_TIMEOUT", 0.5):
                    started = time.monotonic()
                    self.assertIsNone(bridge.find_cli("claude", ask=True))
                self.assertLess(time.monotonic() - started, 3)
                self.assertFalse((bridge.CONFIG_DIR / "cli-paths.json").exists())
                self.assertEqual(bridge.CHILDREN, set())

    def test_zlogout_output_and_background_jobs_do_not_hold_the_answer(self):
        target = self.script(self.root / "bin/claude", "#!/bin/sh\n")
        job = self.root / "job.pid"
        # A job started by the startup files keeps stdout open; ~/.zlogout prints and lingers.
        self.shell('PATH="%s:$PATH"; /bin/sleep 30 & echo $! > "%s"' % (target.parent, job),
                   after="echo 'Bye from zlogout'; /bin/sleep 30")
        started = time.monotonic()
        self.assertEqual(bridge.find_cli("claude", ask=True), str(target))
        self.assertLess(time.monotonic() - started, 3)
        pid = int(job.read_text())
        self.kill_later(pid)
        self.wait_for(lambda: not self.alive(pid), 3)
        self.assertEqual(bridge.CHILDREN, set())


if __name__ == "__main__":
    unittest.main()
