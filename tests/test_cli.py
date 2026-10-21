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
                bridge.find_cli.cache_clear()
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

    def test_missing_cli(self):
        self.assertIsNone(bridge.find_cli("claude"))


class LoginShellTests(IsolatedTest):
    def shell(self, answer, delay=0):
        """A login shell that logs its calls, prints some startup noise and then `answer`."""
        self.calls = self.root / "shell-calls"
        shell = self.script(self.root / "fake-shell", '''#!/bin/sh
echo "$*" >> "%s"
sleep %s
echo "Welcome back!"
printf '%%s\\n' "%s"
''' % (self.calls, delay, answer))
        os.environ["SHELL"] = str(shell)

    def call_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def test_login_shell_answer_is_cached_and_revalidated(self):
        target = self.script(self.root / "odd place/claude", "#!/bin/sh\n")
        self.shell(target)
        self.assertEqual(bridge.find_cli("claude"), str(target))
        self.assertEqual(self.calls.read_text(), "-ilc command -v claude\n")
        cache = bridge.CONFIG_DIR / "cli-paths.json"
        self.assertEqual(json.loads(cache.read_text())["claude"]["path"], str(target))
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        bridge.find_cli.cache_clear()
        self.assertEqual(bridge.find_cli("claude"), str(target))
        self.assertEqual(self.call_count(), 1)
        target.chmod(0o644)  # no longer executable: ask again
        bridge.find_cli.cache_clear()
        self.assertIsNone(bridge.find_cli("claude"))
        self.assertEqual(self.call_count(), 2)

    def test_only_an_absolute_executable_last_line_counts(self):
        for answer in ("claude: aliased to npx claude", "claude", str(self.root / "missing/claude")):
            with self.subTest(answer=answer):
                self.shell(answer)
                bridge.find_cli.cache_clear()
                self.assertIsNone(bridge.find_cli("claude", fresh=True))

    def test_a_miss_is_not_asked_again_until_retry_or_sign_in(self):
        self.shell("")
        self.assertIsNone(bridge.find_cli("codex"))
        bridge.find_cli.cache_clear()
        self.assertIsNone(bridge.find_cli("codex"))
        self.assertEqual(self.call_count(), 1)
        self.assertIsNone(bridge.find_cli("codex", fresh=True))
        self.assertEqual(self.call_count(), 2)
        bridge.find_cli.cache_clear()
        with mock.patch.object(bridge, "SHELL_RETRY", 0):
            bridge.find_cli("codex")
        self.assertEqual(self.call_count(), 3)

    def test_slow_shell_times_out(self):
        self.shell("/bin/sh", delay=30)
        with mock.patch.object(bridge, "SHELL_TIMEOUT", 0.3):
            started = time.monotonic()
            self.assertIsNone(bridge.find_cli("claude"))
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(bridge.CHILDREN, set())


if __name__ == "__main__":
    unittest.main()
