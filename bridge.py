#!/usr/bin/env python3
"""Usagi's reader for Claude Code and Codex accounts. Prints usage metadata only, never credentials."""
from concurrent.futures import ThreadPoolExecutor
import contextlib
import errno
import fcntl
import functools
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

import usagi_accounts as accounts
import usagi_usage as readers

CONFIG_DIR = Path.home() / ".config/usagi"
LEGACY_CONFIG_DIR = Path.home() / ".config/AgentUsageBar"
CARD_FILE = CONFIG_DIR / "cards.json"
LOGIN_DIR = CONFIG_DIR / "logins"
LOGIN_TIMEOUT = 600        # a sign-in left open in the browser
READY_TIMEOUT = 15         # until the sign-in page is open
STATUS_TIMEOUT = 5
APP_SERVER_TIMEOUT = 8
SHELL_TIMEOUT = 5
STOP_WAIT = 5              # for a previous sign-in worker to exit, per signal
UPDATE_STEP_TIMEOUT = 300   # per brew step; the page gives up after 11 minutes
TERM_GRACE = 0.7           # Swift SIGKILLs the bridge 2 s after its SIGTERM
CLI_FOLDERS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")
CLI_NAMES = {"claude": "Claude Code CLI", "codex": "Codex CLI"}
BREW_PREFIXES = ("/opt/homebrew", "/usr/local")
CASK = "extransload/tap/usagi"
RELEASES_URL = "https://github.com/Extransload/usagi/releases/latest"
APP_PATH = Path(__file__).resolve().parents[2]  # Usagi.app/Contents/Resources/bridge.py
BROWSER_SCRIPT = Path(__file__).resolve().with_name("open-browser.sh")
CHILDREN = set()  # running CLIs we started; SIGTERM stops them
FOUND = {}  # CLI paths looked up in this run; None for a miss
STARTING = threading.RLock()  # held while a child starts, so SIGTERM never misses one
TERMINATING = False  # set by SIGTERM; no child starts after that


class CliMissing(RuntimeError):
    code = "cli_missing"

    def __init__(self, provider):
        super().__init__("%s not found. Install it, then try again." % CLI_NAMES[provider])


def start(command, env=None, **options):
    """Popen in a new session, so stop() can end the CLI together with anything it spawned. Refused
    once SIGTERM arrived, as an OSError like any CLI that can't start."""
    options.setdefault("stdin", subprocess.DEVNULL)
    with STARTING:
        if TERMINATING:
            raise OSError("Usagi is quitting")
        process = subprocess.Popen(command, env=env, start_new_session=True, **options)
        CHILDREN.add(process)
    return process


def stop(process):
    """Closes our pipes and ends the process group: SIGTERM, then SIGKILL, waiting at most 2 s each.
    The group is signalled even when the CLI itself already exited, so what it spawned goes too: until
    we reap it, its PID and group can't be reused. One reaped before this call is left alone."""
    try:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                with contextlib.suppress(OSError):
                    stream.close()
        if process.returncode is not None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with contextlib.suppress(OSError):
                os.killpg(process.pid, sig)
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=2)
    finally:
        CHILDREN.discard(process)


def terminate(signum, _frame):
    """Swift's watchdog sends SIGTERM and SIGKILLs us 2 s later, but our CLIs run in their own
    sessions and would outlive us: SIGTERM their groups, SIGKILL what is left after TERM_GRACE, then
    exit through the finally blocks. A flag guards re-entry; SIG_IGN would be inherited by children."""
    global TERMINATING
    if TERMINATING:
        return
    with STARTING:  # a child starting in another thread is in CHILDREN once we hold this
        TERMINATING = True
    groups = {process.pid: process for process in list(CHILDREN) if process.returncode is None}
    for pgid in groups:
        with contextlib.suppress(OSError):
            os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + TERM_GRACE
    while groups and time.monotonic() < deadline:
        time.sleep(0.02)
        for pgid, process in list(groups.items()):
            try:  # poll() reaps the leader unless another frame waits on it; signal 0 finds the rest
                if process.poll() is not None:
                    os.killpg(pgid, 0)
            except ProcessLookupError:
                del groups[pgid]
            except OSError:
                pass
    for pgid in groups:
        with contextlib.suppress(OSError):
            os.killpg(pgid, signal.SIGKILL)
    raise SystemExit(128 + signum)


class LineReader:
    """Lines from a pipe with a deadline; file.readline() would block on a partial line."""

    def __init__(self, stream):
        self.fd, self.buffer = stream.fileno(), b""

    def readline(self, deadline):
        """The next line, b"" at EOF, None when the deadline passes first."""
        while b"\n" not in self.buffer:
            timeout = deadline - time.monotonic()
            if timeout <= 0 or not select.select([self.fd], [], [], timeout)[0]:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                line, self.buffer = self.buffer, b""
                return line
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line + b"\n"


def run(command, env, timeout):
    """(exit code, stdout) of a short command, or None when it can't start or runs out of time."""
    try:
        process = start(command, env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output.decode(errors="replace")
    except subprocess.TimeoutExpired:
        return None
    finally:
        stop(process)


def is_executable(path):
    return os.path.isfile(path) and os.access(path, os.X_OK)


def cli_folders():
    """Usual install spots; apps opened from Finder or at login get a short PATH. Newest node first."""
    home = Path.home()
    node = ((home / ".nvm/versions/node", "*/bin"),
            (home / ".local/share/fnm/node-versions", "*/installation/bin"),
            (home / "Library/Application Support/fnm/node-versions", "*/installation/bin"))
    versions = sorted(((folder, root) for root, pattern in node for folder in root.glob(pattern)), reverse=True,
                      key=lambda item: [int(part) for part in
                                        re.findall(r"\d+", item[0].relative_to(item[1]).parts[0])])
    return [home / ".local/bin", *map(Path, CLI_FOLDERS), home / ".npm-global/bin", home / ".bun/bin",
            home / ".volta/bin", home / ".claude/local", home / "Library/pnpm", home / ".yarn/bin",
            home / ".asdf/shims", home / ".local/share/mise/shims", *(folder for folder, _ in versions)]


def find_cli(name, ask=False):
    """Absolute path of the CLI, or None: PATH, the usual install spots, then the login shell's last
    clean answer. Only user actions pass `ask`, which asks the login shell itself when all miss."""
    if FOUND.get(name) is None and (ask or name not in FOUND):
        found = shutil.which(name)
        found = os.path.abspath(found) if found else next(
            (str(folder / name) for folder in cli_folders() if is_executable(folder / name)), None)
        FOUND[name] = found or shell_cli(name, ask)
    return FOUND[name]


def find_clis(ask=()):
    """Whether each CLI is there, looked up in this thread before concurrent checks need them. The
    login shell is asked about the providers in `ask` only."""
    return {provider: find_cli(provider, provider in ask) is not None for provider in accounts.PROVIDERS}


def shell_answers():
    try:
        cache = json.loads((CONFIG_DIR / "cli-paths.json").read_text())
    except (OSError, ValueError):
        return {}
    return cache if isinstance(cache, dict) else {}


def shell_cli(name, ask):
    """The login shell's cached answer, rechecked before use. With `ask` a missing or outdated one is
    asked for now; only a clean answer (a path or a clean miss) is cached, never a timeout."""
    entry = shell_answers().get(name)
    path = entry.get("path") if isinstance(entry, dict) else None
    if isinstance(path, str) and is_executable(path):
        return path
    answer = login_shell_lookup(name) if ask else None
    if answer is None:
        return None
    path, login_path = answer
    with contextlib.suppress(OSError):  # merged under a lock: another bridge may be writing too
        accounts.private_dir(CONFIG_DIR)
        fd = os.open(str(CONFIG_DIR / "cli-paths.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            accounts.write_private(CONFIG_DIR / "cli-paths.json", json.dumps(dict(
                shell_answers(), login_path=login_path, **{name: {"path": path, "checked_at": time.time()}})))
        finally:
            os.close(fd)
    return path


def login_shell_lookup(name):
    """(path or None, the shell's PATH) from the user's login shell, for installs only its startup
    files put on PATH; None unless the answer arrived whole between two sentinel lines in time.
    Startup files may print anything before it. Reading stops at the closing sentinel and the shell's
    group is killed right away (an interactive shell ignores SIGTERM), so ~/.zlogout or a background
    job holding stdout can't hold it up."""
    try:
        shell = os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell
    except KeyError:
        return None
    if not (os.path.isabs(shell) and is_executable(shell)):
        return None
    tag = "usagi-%s-" % os.urandom(8).hex()  # the command line holds it apart from begin/end
    script = ("printf '\\n%%s%%s\\n' %s begin; printf '%%s\\n' \"$PATH\"; command -v %s; "
              "printf '%%s%%s\\n' %s end" % (tag, name, tag))
    try:
        process = start([shell, "-ilc", script], None, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    try:
        reader, deadline, lines = LineReader(process.stdout), time.monotonic() + SHELL_TIMEOUT, None
        while True:
            line = reader.readline(deadline)
            if not line:  # timed out, or the shell exited before the closing sentinel
                return None
            line = line.decode(errors="replace").rstrip("\r\n")
            if line == tag + "begin":
                lines = []
            elif lines is not None and line == tag + "end":
                break
            elif lines is not None:
                lines.append(line)
    finally:
        with contextlib.suppress(OSError):
            os.killpg(process.pid, signal.SIGKILL)  # not reaped yet, so the group is still its own
        stop(process)
    if not lines:
        return None
    answer = lines[1:]  # `command -v`: one absolute path for a program; aliases and functions don't count
    found = answer[0] if len(answer) == 1 and os.path.isabs(answer[0]) and is_executable(answer[0]) else None
    return found, lines[0]


def auth_context(provider, name):
    """The CLI (None when missing) and an environment pointing it at this account only."""
    env = os.environ.copy()
    for variable in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                     "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
                     "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"):
        env.pop(variable, None)
    claude_dir, codex_dir = accounts.dirs(name)
    variable, folder = (("CLAUDE_CONFIG_DIR", claude_dir) if provider == "claude"
                        else ("CODEX_HOME", codex_dir))
    if name == "default":
        env.pop(variable, None)
    else:
        env[variable] = str(folder)
    executable = find_cli(provider)
    if executable:
        # npm, pnpm, yarn and bun installs are `#!/usr/bin/env node` scripts or wrappers calling node,
        # and an app opened from Finder gets a short PATH: put the CLI's folder (node is often next to
        # it), node's folder, ~/.bun/bin and the login shell's last PATH first.
        folders = [os.path.dirname(executable), os.path.dirname(os.path.realpath(executable))]
        node = find_cli("node")
        if node:
            folders.append(os.path.dirname(node))
        if (Path.home() / ".bun/bin").is_dir():
            folders.append(str(Path.home() / ".bun/bin"))
        login_path = shell_answers().get("login_path")
        if isinstance(login_path, str):
            folders += [part for part in login_path.split(os.pathsep) if os.path.isabs(part)]
        env["PATH"] = os.pathsep.join(dict.fromkeys(
            folders + [part for part in env.get("PATH", os.defpath).split(os.pathsep) if part]))
    return executable, env


def cli_status(provider, name):
    """The CLI's own status command: signed_in or signed_out; unknown when it times out or crashes."""
    executable, env = auth_context(provider, name)
    if executable is None:
        return "cli_missing"
    if provider == "codex":
        result = run([executable, "login", "status"], env, STATUS_TIMEOUT)
        return {0: "signed_in", 1: "signed_out"}.get(result[0], "unknown") if result else "unknown"
    result = run([executable, "auth", "status", "--json"], env, STATUS_TIMEOUT)
    try:
        logged_in = json.loads(result[1]).get("loggedIn") if result else None
    except (ValueError, AttributeError):
        logged_in = None
    if logged_in is True and result[0] == 0:
        return "signed_in"
    return "signed_out" if logged_in is False else "unknown"


@functools.lru_cache(maxsize=None)
def app_version():
    """CFBundleShortVersionString of the app, or of the repo's Info.plist when run from source."""
    for plist in (APP_PATH / "Contents/Info.plist", Path(__file__).resolve().with_name("Info.plist")):
        try:
            with open(plist, "rb") as file:
                version = plistlib.load(file).get("CFBundleShortVersionString")
        except Exception:  # missing or malformed plist: try the next one
            continue
        if isinstance(version, str):
            return version
    return None


class AppServer:
    """`codex app-server --stdio`, JSON-RPC over lines. Leaving the with block stops its process group."""

    def __init__(self, executable, env):
        self.process = start([executable, "app-server", "--stdio"], env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.lines = LineReader(self.process.stdout)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        stop(self.process)

    def send(self, message):
        try:
            self.process.stdin.write((json.dumps(dict(message, jsonrpc="2.0")) + "\n").encode())
            self.process.stdin.flush()
        except OSError:
            raise RuntimeError("The Codex app-server exited") from None

    def receive(self, deadline):
        """The next JSON object, or None at EOF or the deadline. Other lines are skipped."""
        while True:
            line = self.lines.readline(deadline)
            if not line:
                return None
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict):
                return message

    def request(self, calls, deadline):
        """Sends {id: (method, params)} and returns {id: response} for those answered in time.
        Server requests and notifications carry a method and are not responses."""
        for request_id, (method, params) in calls.items():
            self.send({"id": request_id, "method": method, "params": params})
        responses = {}
        while len(responses) < len(calls):
            message = self.receive(deadline)
            if message is None:
                break
            request_id = message.get("id")
            if "method" not in message and type(request_id) is int and request_id in calls:
                responses[request_id] = message
        return responses

    def initialize(self, deadline):
        response = self.request({1: ("initialize", {
            "clientInfo": {"name": "usagi", "title": "Usagi", "version": app_version() or "0"},
            "capabilities": {}})}, deadline).get(1, {})
        if not isinstance(response.get("result"), dict):
            return False
        self.send({"method": "initialized", "params": {}})
        return True


def result_of(response, field):
    result = response.get("result") if isinstance(response, dict) else None
    return result.get(field, False) if isinstance(result, dict) else False


def codex_live(name):
    """Status, identity and account-wide limits from Codex's public app-server protocol. account/read
    gives {"account": null} when signed out and an object (chatgpt or apiKey) when signed in."""
    executable, env = auth_context("codex", name)
    if executable is None:
        return {"status": "cli_missing"}
    deadline = time.monotonic() + APP_SERVER_TIMEOUT
    responses = {}
    try:
        with AppServer(executable, env) as server:
            if server.initialize(deadline):
                responses = server.request({2: ("account/read", {}),
                                            3: ("account/rateLimits/read", {})}, deadline)
    except (OSError, RuntimeError):
        pass
    account = result_of(responses.get(2), "account")
    if account is None:
        return {"status": "signed_out"}
    if not isinstance(account, dict):  # no answer (an older CLI, a slow start): ask `codex login status`
        return {"status": cli_status("codex", name)}
    if account.get("type") != "chatgpt":
        return {"status": "signed_in"}
    windows = codex_windows(result_of(responses.get(3), "rateLimits"))
    email, plan = account.get("email"), account.get("planType")
    return {"status": "signed_in", "email": email if isinstance(email, str) else None,
            "plan": plan if isinstance(plan, str) else None, "windows": windows,
            "source": "Codex account limits · official app-server" if windows else None}


def window_key(minutes, fallback):
    if not isinstance(minutes, int) or minutes <= 0:
        return fallback
    if minutes % 1440 == 0:
        return "%dd" % (minutes // 1440)
    return "%dh" % round(minutes / 60)


def codex_windows(limits):
    windows = {}
    for fallback, field in (("5h", "primary"), ("7d", "secondary")):
        reading = limits.get(field) if isinstance(limits, dict) else None
        used = readers._number(reading.get("usedPercent")) if isinstance(reading, dict) else None
        if used is not None:
            windows[window_key(reading.get("windowDurationMins"), fallback)] = {
                "used_percent": used, "resets_at": readers._number(reading.get("resetsAt")),
                "captured_at": time.time(), "stale": False}  # read live just now
    return windows


def check_account(provider, name):
    """Status, identity and limits of one account. A failure here leaves only this account unknown."""
    try:
        if provider == "codex":
            return codex_live(name)
        status = cli_status("claude", name)
        if status != "signed_in":
            return {"status": status}
        claude_dir, _ = accounts.dirs(name)
        info = accounts.account_info(name)
        return {"status": status, "email": info.get("email"), "plan": info.get("plan"),
                "source": "Claude Code local cache",
                "windows": readers.merge_windows(
                    readers.read_claude_cached(None if name == "default" else claude_dir / ".claude.json"),
                    readers.read_claude(readers.claude_cache_for(name)))}
    except Exception:
        return {"status": "unknown"}


def run_checks(keys, checks):
    """Fills `checks` for the (provider, account) keys not checked yet in this run, concurrently."""
    missing = [key for key in dict.fromkeys(keys) if key not in checks]
    if missing:
        pool = ThreadPoolExecutor(max_workers=4)
        try:
            for key, result in zip(missing, pool.map(lambda key: check_account(*key), missing)):
                checks[key] = result
        finally:
            pool.shutdown(cancel_futures=True)
    return checks


def migrate_legacy_config():
    if CONFIG_DIR.exists() or not LEGACY_CONFIG_DIR.is_dir():
        return
    try:
        LEGACY_CONFIG_DIR.rename(CONFIG_DIR)
    except OSError:
        pass


def visible_cards(checks=None):
    try:
        saved = json.loads(CARD_FILE.read_text())
    except FileNotFoundError:
        saved = None
    except (OSError, ValueError):
        saved = []
    if saved is None:  # first run: the CLI accounts already signed in
        active = [(provider, accounts.active(provider)) for provider in accounts.PROVIDERS]
        checks = run_checks(active, {} if checks is None else checks)
        saved = [{"provider": provider, "id": name} for provider, name in active
                 if checks[(provider, name)]["status"] == "signed_in"]
    if not isinstance(saved, list):
        return []
    return [card for card in saved if isinstance(card, dict)
            and card.get("provider") in accounts.PROVIDERS
            and card.get("id") in accounts.profiles(card["provider"])]


def save_cards(cards):
    accounts.write_private(CARD_FILE, json.dumps(cards, ensure_ascii=False))


def account_entry(provider, name, check):
    status = check.get("status", "unknown")
    signed_in = status == "signed_in"
    connecting = not signed_in and is_connecting(provider, name)
    if signed_in:
        clear_login_error(provider, name)
    return {"id": name, "email": check.get("email"), "plan": check.get("plan"),
            "status": status, "logged_in": signed_in, "connecting": connecting,
            "login_error": None if signed_in or connecting else login_error(provider, name),
            "source": check.get("source"), "windows": check.get("windows") or {}}


def snapshot(checks=None, ask=()):
    """`checks` carries results an action already has; `ask` names the CLIs to ask the login shell about."""
    checks = {} if checks is None else checks
    cli = find_clis(ask)
    cards = visible_cards(checks)
    run_checks([(card["provider"], card["id"]) for card in cards], checks)
    result = {"version": app_version(), "cards": cards, "providers": {}}
    for provider in accounts.PROVIDERS:
        names = sorted({card["id"] for card in cards if card["provider"] == provider}, key=accounts.sort_key)
        result["providers"][provider] = {
            "active": accounts.active(provider), "cli": cli[provider],
            "accounts": [account_entry(provider, name, checks[(provider, name)]) for name in names]}
    return result


def add_card(provider, name, checks=None):
    if provider not in accounts.PROVIDERS:
        raise accounts.AccountError("Unknown provider")
    if name not in accounts.profiles(provider):
        accounts.add(name, provider)
    else:
        accounts.add_missing_marker(name, provider)
    cards = visible_cards(checks)
    card = {"provider": provider, "id": name}
    if card not in cards:
        cards.append(card)
    save_cards(cards)


def add_next_card(provider, checks=None):
    """`checks` is filled on the way, so the snapshot after it checks no account twice."""
    if provider not in accounts.PROVIDERS:
        raise accounts.AccountError("Unknown provider")
    find_clis(ask=(provider,))
    shown = {card["id"] for card in visible_cards(checks) if card["provider"] == provider}
    name = next((candidate for candidate in accounts.profiles(provider) if candidate not in shown), None)
    if name is None:
        number = 2
        existing = set(accounts.profiles(provider))
        while "account-%d" % number in existing:
            number += 1
        name = "account-%d" % number
    add_card(provider, name, checks)
    return name


def remove_card(provider, name, checks=None):
    find_clis()
    cards = visible_cards(checks)
    card = {"provider": provider, "id": name}
    if card not in cards:
        raise accounts.AccountError("That account is not in the list")
    stop_login(provider, name)  # a sign-in left open in the browser must not finish for a hidden card
    save_cards([item for item in cards if item != card])


def validate_login(provider, name):
    if provider not in accounts.PROVIDERS or name not in accounts.profiles(provider):
        raise accounts.AccountError("Unknown provider or account")


def login_file(provider, name):
    key = hashlib.sha256((provider + "\0" + name).encode()).hexdigest()[:20]
    return LOGIN_DIR / (provider + "-" + key)


def login_error_file(provider, name):
    path = login_file(provider, name)
    return path.with_name(path.name + ".error")


def login_error(provider, name):
    try:
        return login_error_file(provider, name).read_text() or None
    except OSError:
        return None


def clear_login_error(provider, name):
    with contextlib.suppress(OSError):
        login_error_file(provider, name).unlink(missing_ok=True)


@contextlib.contextmanager
def login_guard():
    """Serializes marker checks with marker creation and removal; held for microseconds."""
    accounts.private_dir(LOGIN_DIR)
    fd = os.open(str(LOGIN_DIR / ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def worker_pid(provider, name, sig=None):
    """PID of the account's live sign-in worker, or None. A worker holds an exclusive flock on its
    marker for life, so a marker nobody holds is stale (reboot, crash) and is removed: its PID may
    belong to another process by now. With `sig`, signals the worker's process group (the worker
    started a new session, so pgid == pid) while the lock proves the PID is the worker's."""
    path = login_file(provider, name)
    if not path.exists():
        return None
    with login_guard():
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except OSError:  # gone since the check above
            return None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            text = os.read(fd, 32).decode(errors="replace").strip()
            pid = int(text) if text.isdigit() else 0
            if sig is not None and pid > 1:
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(pid, sig)
            return pid
        else:
            path.unlink(missing_ok=True)
            return None
        finally:
            os.close(fd)


def is_connecting(provider, name):
    try:
        return worker_pid(provider, name) is not None
    except OSError:
        return False


def hold_marker(path):
    """Claims the account's marker for this worker's lifetime; the returned fd keeps the lock."""
    with login_guard():
        fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.ftruncate(fd, 0)
            os.write(fd, str(os.getpid()).encode())
        except BlockingIOError:
            os.close(fd)
            raise RuntimeError("Another sign-in for this account is still running. Try again.") from None
        except BaseException:
            os.close(fd)
            raise
    return fd


def release_marker(path, fd):
    try:
        with login_guard():
            path.unlink(missing_ok=True)
    finally:
        os.close(fd)


def stop_login(provider, name):
    """Ends the account's running sign-in, if any: SIGTERM to the worker's group, SIGKILL if it lingers."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if worker_pid(provider, name, sig) is None:
            return
        deadline = time.monotonic() + STOP_WAIT
        while time.monotonic() < deadline:
            if worker_pid(provider, name) is None:
                return
            time.sleep(0.05)
    raise RuntimeError("The previous sign-in is still closing. Try again.")


def open_browser(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("Invalid sign-in URL")
    # `open -a` brings Chrome forward by itself; scripting it would ask for Automation permission.
    for command in (["/usr/bin/open", "-a", "Google Chrome", url], ["/usr/bin/open", url]):
        result = run(command, None, 10)
        if result and result[0] == 0:
            return
    raise RuntimeError("Could not open the sign-in page in a browser")


def login_ready():
    print(json.dumps({"ready": True}), flush=True)


def codex_login_worker(executable, env):
    deadline = time.monotonic() + LOGIN_TIMEOUT
    with AppServer(executable, env) as server:
        if not server.initialize(min(deadline, time.monotonic() + APP_SERVER_TIMEOUT)):
            raise RuntimeError("Could not start the Codex app-server")
        response = server.request({2: ("account/login/start", {"type": "chatgpt"})}, deadline).get(2, {})
        result = response.get("result")
        if (not isinstance(result, dict) or result.get("type") != "chatgpt"
                or not isinstance(result.get("authUrl"), str)):
            error = response.get("error")
            message = error.get("message") if isinstance(error, dict) else None
            raise RuntimeError(message if isinstance(message, str) and message
                               else "Codex did not return a sign-in URL")
        open_browser(result["authUrl"])
        login_ready()
        while True:
            message = server.receive(deadline)
            if message is None:
                raise RuntimeError("Sign-in timed out. Try again." if time.monotonic() >= deadline
                                   else "The Codex sign-in process exited")
            if message.get("method") == "account/login/completed":
                params = message.get("params") if isinstance(message.get("params"), dict) else {}
                if params.get("success") is not True:
                    raise RuntimeError(str(params.get("error") or "Codex sign-in failed"))
                return


def last_line(output):
    """The CLI's last non-empty output line, without colour codes, short enough for a card."""
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output.decode(errors="replace"))
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1][:200] if lines else ""


def claude_login_worker(executable, env):
    with tempfile.TemporaryDirectory(prefix="usagi-login-") as folder:
        marker = Path(folder) / "browser-opened"
        env = dict(env, BROWSER=str(BROWSER_SCRIPT), USAGI_BROWSER_MARKER=str(marker))
        process = start([executable, "auth", "login"], env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            fd, tail, done = process.stdout.fileno(), b"", False
            deadline = time.monotonic() + LOGIN_TIMEOUT
            opened = False
            while True:
                code = process.poll()  # before the marker, so a browser error wins over the exit it causes
                try:
                    browser = marker.read_text()
                except OSError:
                    browser = None
                if browser == "error":
                    raise RuntimeError("Could not open the sign-in page in a browser")
                if browser == "opened" and not opened:
                    login_ready()
                    opened = True
                if code is not None:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("Sign-in timed out. Try again.")
                # Drain the output so the CLI never blocks on a full pipe; keep the tail for errors.
                if done:
                    time.sleep(0.25)
                elif select.select([fd], [], [], 0.25)[0]:
                    chunk = os.read(fd, 65536)
                    done, tail = not chunk, (tail + chunk)[-8192:]
            while not done and select.select([fd], [], [], 0)[0]:  # printed just before it exited
                chunk = os.read(fd, 65536)
                done, tail = not chunk, (tail + chunk)[-8192:]
            if code != 0:
                reason = last_line(tail)
                raise RuntimeError("Claude sign-in failed: " + reason if reason
                                   else "Claude sign-in failed (exit %d)" % code)
            if not opened:  # signed in without needing the browser
                login_ready()
        finally:
            stop(process)


def login(provider, name):
    validate_login(provider, name)
    if find_cli(provider, ask=True) is None:
        raise CliMissing(provider)
    stop_login(provider, name)
    clear_login_error(provider, name)
    worker = start([sys.executable, str(Path(__file__).resolve()), "login_worker", provider, name],
                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        line = LineReader(worker.stdout).readline(time.monotonic() + READY_TIMEOUT)
        if line is None:
            raise RuntimeError("Timed out opening the sign-in page")
        try:
            response = json.loads(line or b"{}")
        except ValueError:
            response = {}
        if not isinstance(response, dict) or response.get("ready") is not True:
            error = response.get("error") if isinstance(response, dict) else None
            raise RuntimeError(error if isinstance(error, str) and error else "Could not open the sign-in page")
    except BaseException:
        stop(worker)
        raise
    CHILDREN.discard(worker)  # it keeps running on its own until the sign-in finishes
    worker.stdout.close()


def login_status(provider, name):
    """Cheap check while a sign-in is open; Codex uses `codex login status`, not the app-server."""
    validate_login(provider, name)
    connecting = is_connecting(provider, name)
    status = cli_status(provider, name)
    if status == "signed_in":
        clear_login_error(provider, name)
    return {"connecting": connecting, "status": status,
            "login_error": None if status == "signed_in" or connecting else login_error(provider, name)}


def login_worker(provider, name):
    validate_login(provider, name)
    path = login_file(provider, name)
    lock = hold_marker(path)
    try:
        executable, env = auth_context(provider, name)
        if executable is None:
            raise CliMissing(provider)
        if provider == "codex":
            codex_login_worker(executable, env)
        else:
            claude_login_worker(executable, env)
    except Exception as exc:
        with contextlib.suppress(OSError):
            accounts.write_private(login_error_file(provider, name), friendly_error(exc) if str(exc)
                                   else "Sign-in failed")
        raise
    finally:
        release_marker(path, lock)


def homebrew():
    """brew, when Usagi was installed as a Homebrew cask."""
    for prefix in map(Path, BREW_PREFIXES):
        brew = prefix / "bin/brew"
        if (prefix / "Caskroom/usagi").is_dir() and is_executable(brew):
            return brew
    return None


def update_lock():
    """An fd holding the update lock, or None while another update holds it."""
    accounts.private_dir(CONFIG_DIR)
    fd = os.open(str(CONFIG_DIR / "update.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def update():
    """Homebrew installs upgrade in the background and reopen; Usagi quits while the cask is replaced."""
    if (APP_PATH / "Contents/Resources/source-install").exists():
        return {"release_url": RELEASES_URL, "source_install": True}
    if homebrew() is None:
        return {"release_url": RELEASES_URL}
    lock = update_lock()
    if lock is not None:  # else an update is already running
        os.close(lock)
        worker = start([sys.executable, str(Path(__file__).resolve()), "update_worker"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        CHILDREN.discard(worker)
    return {"updating": True}


def update_worker():
    lock = update_lock()  # held until this process exits
    brew = homebrew()
    if lock is None or brew is None:
        return
    fd = os.open(str(CONFIG_DIR / "update.log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)  # a log left by an older version may be readable by others
    with os.fdopen(fd, "w") as log:
        for command in ([str(brew), "update"], [str(brew), "upgrade", "--cask", CASK],
                        ["/usr/bin/open", str(APP_PATH)]):
            log.write("$ %s\n" % " ".join(command))
            log.flush()
            process = start(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=UPDATE_STEP_TIMEOUT)
            except subprocess.TimeoutExpired:
                log.write("Timed out\n")
            finally:
                stop(process)


def print_json(value):
    print(json.dumps(value, ensure_ascii=False))


OS_ERRORS = {errno.ENOEXEC: "{} is not a program this Mac can run",
             86: "{} is not a program this Mac can run",  # EBADARCH: built for another processor
             errno.EACCES: "Usagi is not allowed to use {}", errno.EPERM: "Usagi is not allowed to use {}",
             errno.ENOENT: "{} was not found", errno.EEXIST: "{} already exists",
             errno.ENOTDIR: "{} is not a folder", errno.EISDIR: "{} is a folder",
             errno.EROFS: "{} is on a read-only disk", errno.ENOSPC: "The disk is full"}


def friendly_error(exc):
    """The message people see: an OSError's "[Errno 8] Exec format error: '/x'" becomes a sentence."""
    if not isinstance(exc, OSError) or not exc.strerror:
        return str(exc) or type(exc).__name__
    path, home = str(exc.filename or ""), str(Path.home()) + "/"
    path = "~/" + path[len(home):] if path.startswith(home) else path
    if not path:
        return exc.strerror
    return OS_ERRORS.get(exc.errno, exc.strerror + ": {}").format(path)


def error_output(exc):
    error = {"error": friendly_error(exc)}
    if isinstance(getattr(exc, "code", None), str):
        error["code"] = exc.code
    return error


def main(argv):
    migrate_legacy_config()
    action = argv[0] if argv else "snapshot"
    if action == "snapshot" and argv[1:] in ([], ["--ask-shell"]):  # --ask-shell: the refresh button
        print_json(snapshot(ask=accounts.PROVIDERS if argv[1:] else ()))
    elif action == "select" and len(argv) == 3:
        accounts.use(argv[2], argv[1])
        print_json(snapshot())
    elif action == "add_auto" and len(argv) == 2:
        checks = {}
        added = add_next_card(argv[1], checks)
        print_json(dict(snapshot(checks), added=added))
    elif action == "remove" and len(argv) == 3:
        checks = {}
        remove_card(argv[1], argv[2], checks)
        print_json(snapshot(checks))
    elif action == "login" and len(argv) == 3:
        login(argv[1], argv[2])
        print_json({"ok": True})
    elif action == "login_status" and len(argv) == 3:
        print_json(login_status(argv[1], argv[2]))
    elif action == "login_worker" and len(argv) == 3:
        login_worker(argv[1], argv[2])
    elif action == "update" and len(argv) == 1:
        print_json(update())
    elif action == "update_worker" and len(argv) == 1:
        update_worker()
    else:
        raise ValueError("Invalid command")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    try:
        main(sys.argv[1:])
    except Exception as exc:
        print_json(error_output(exc))
        sys.exit(1)
