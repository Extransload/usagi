import os
import subprocess
import unittest

from helpers import IsolatedTest, ROOT

SHELLS = (["/bin/zsh", "-f", "-c"], ["/bin/bash", "-c"])  # macOS bash is 3.2
REPORT = 'printf "%s|%s|%s\\n" "${CLAUDE_CONFIG_DIR-unset}" "${CODEX_HOME-unset}" "${_USAGI_CLAUDE_ACCOUNT-}"'


class AccountHookTests(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.state = self.config / "state"
        self.state.mkdir(parents=True)

    def select(self, claude=None, codex=None):
        for provider, name in (("claude", claude), ("codex", codex)):
            if name is not None:
                (self.state / ("account-" + provider)).write_text(name + "\n")

    def run_hook(self, shell, script, **env):
        environment = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", **env}
        result = subprocess.run(shell + ['source "$0"; ' + script, str(ROOT / "usagi.zsh")],
                                capture_output=True, text=True, env=environment, timeout=10)
        self.assertEqual(result.stderr, "")
        return result.stdout.splitlines()

    def test_default_named_and_missing_profiles(self):
        (self.home / ".claude-work").mkdir()
        for shell in SHELLS:
            with self.subTest(shell=shell[0]):
                self.select("default", "default")
                self.assertEqual(self.run_hook(shell, REPORT), ["unset|unset|default"])
                self.select("work", "ghost")  # no ~/.codex-ghost: stays default
                self.assertEqual(self.run_hook(shell, REPORT),
                                 ["%s/.claude-work|unset|work" % self.home])

    def test_switching_back_to_default_undoes_the_export(self):
        (self.home / ".claude-work").mkdir()
        self.select("work", "default")
        for shell in SHELLS:
            with self.subTest(shell=shell[0]):
                script = REPORT + "; printf 'default\\n' > \"$HOME/.config/usagi/state/account-claude\"; " \
                    "_usagi_account_precmd; " + REPORT + "; printf 'work\\n' > \"$HOME/.config/usagi/state/account-claude\""
                self.assertEqual(self.run_hook(shell, script),
                                 ["%s/.claude-work|unset|work" % self.home, "unset|unset|default"])

    def test_inherited_export_is_undone_only_for_a_profile_usagi_or_agent_kit_made(self):
        self.select("default", "default")
        for folder, marker in ((".claude-work", ".usagi-profile"), (".codex-team", ".agentkit-profile"),
                               (".claude-mine", None)):
            (self.home / folder).mkdir()
            if marker:
                (self.home / folder / marker).write_text("")
        for shell in SHELLS:
            with self.subTest(shell=shell[0]):
                # A tmux pane or IDE terminal started while "work" was selected, before tracking was exported.
                self.assertEqual(self.run_hook(shell, REPORT, CLAUDE_CONFIG_DIR=str(self.home / ".claude-work"),
                                               CODEX_HOME=str(self.home / ".codex-team")), ["unset|unset|default"])
                # The user's own exports: a folder without a marker, or not shaped like a profile.
                self.assertEqual(self.run_hook(shell, REPORT, CLAUDE_CONFIG_DIR=str(self.home / ".claude-mine"),
                                               CODEX_HOME="/custom/codex"),
                                 ["%s/.claude-mine|/custom/codex|default" % self.home])
                self.assertEqual(self.run_hook(shell, REPORT, CLAUDE_CONFIG_DIR=str(self.home / ".claude-x/y")),
                                 ["%s/.claude-x/y|unset|default" % self.home])
                # With the tracking variable inherited, the value is the hook's own: undone without a marker.
                self.assertEqual(self.run_hook(shell, REPORT, CLAUDE_CONFIG_DIR=str(self.home / ".claude-mine"),
                                               _USAGI_CLAUDE_ACCOUNT="mine"), ["unset|unset|default"])

    def test_child_shells_know_what_was_set(self):
        (self.home / ".codex-work").mkdir()
        self.select("default", "work")
        for shell in SHELLS:
            with self.subTest(shell=shell[0]):
                child = shell[0] + ' -c \'printf "%s %s\\n" "$_USAGI_CODEX_ACCOUNT" "$CODEX_HOME"\''
                self.assertEqual(self.run_hook(shell, child), ["work %s/.codex-work" % self.home])

    def test_hook_is_registered_once_without_clobbering(self):
        self.assertEqual(self.run_hook(["/bin/bash", "-c"], 'source "$0"; printf "%s" "$PROMPT_COMMAND"',
                                       PROMPT_COMMAND="history -a;"),
                         ["history -a;", "_usagi_account_precmd"])
        self.assertEqual(self.run_hook(["/bin/zsh", "-f", "-c"], 'source "$0"; print -l $precmd_functions'),
                         ["_usagi_account_precmd"])


class BrowserScriptTests(IsolatedTest):
    def run_script(self, *args):
        marker = self.root / "marker"
        result = subprocess.run([str(ROOT / "open-browser.sh"), *args], capture_output=True, timeout=10,
                                env={"PATH": "/usr/bin:/bin", "USAGI_BROWSER_MARKER": str(marker)})
        return result.returncode, marker.read_text() if marker.exists() else None

    def test_anything_but_one_https_url_is_refused_before_opening(self):
        for args in ((), ("http://claude.ai/x",), ("file:///etc/passwd",), ("-a", "Calculator"),
                     ("https://claude.ai/x", "https://claude.ai/y"), ("",)):
            with self.subTest(args=args):
                self.assertEqual(self.run_script(*args), (1, "error"))

    def test_script_never_scripts_chrome(self):
        text = (ROOT / "open-browser.sh").read_text()
        self.assertNotIn("osascript", text)
        self.assertTrue(os.access(ROOT / "open-browser.sh", os.X_OK))


if __name__ == "__main__":
    unittest.main()
