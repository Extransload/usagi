#!/usr/bin/env python3
"""Usagi's reader for Claude Code and Codex accounts. Prints usage metadata only, never credentials."""
import json
import hashlib
import os
import re
from pathlib import Path
import shutil
import signal
import selectors
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

import usagi_accounts as accounts
import usagi_usage as readers

CONFIG_DIR = Path.home() / ".config/usagi"
LEGACY_CONFIG_DIR = Path.home() / ".config/AgentUsageBar"
CARD_FILE = CONFIG_DIR / "cards.json"
LOGIN_DIR = CONFIG_DIR / "logins"
LOGIN_TIMEOUT = 600
CLI_FOLDERS = ("/opt/homebrew/bin", "/usr/local/bin")


def find_cli(name):
    """PATH first. Apps opened from Finder or at login get a short PATH, so the usual install spots follow."""
    found = shutil.which(name)
    if found:
        return found
    home = Path.home()
    node = sorted((home / ".nvm/versions/node").glob("*/bin"), reverse=True,
                  key=lambda folder: [int(part) for part in re.findall(r"\d+", folder.parent.name)])
    for folder in [home / ".local/bin", *map(Path, CLI_FOLDERS), home / ".npm-global/bin",
                   home / ".bun/bin", home / ".volta/bin", *node]:
        if os.access(folder / name, os.X_OK):
            return str(folder / name)
    return name


def auth_context(provider, name, claude_dir, codex_dir):
    env = os.environ.copy()
    for variable in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                     "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
                     "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"):
        env.pop(variable, None)
    if provider == "claude":
        if name == "default":
            env.pop("CLAUDE_CONFIG_DIR", None)
        else:
            env["CLAUDE_CONFIG_DIR"] = str(claude_dir)
        executable = find_cli("claude")
        return executable, env
    else:
        if name == "default":
            env.pop("CODEX_HOME", None)
        else:
            env["CODEX_HOME"] = str(codex_dir)
        executable = find_cli("codex")
        return executable, env


def signed_in(provider, name, claude_dir, codex_dir):
    executable, env = auth_context(provider, name, claude_dir, codex_dir)
    command = ([executable, "auth", "status", "--json"] if provider == "claude"
               else [executable, "login", "status"])
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
        if provider == "claude":
            return result.returncode == 0 and json.loads(result.stdout).get("loggedIn") is True
        return result.returncode == 0
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def codex_live(name, claude_dir, codex_dir):
    """Read account identity and account-wide limits from Codex's public app-server protocol."""
    executable, env = auth_context("codex", name, claude_dir, codex_dir)
    process = None
    selector = selectors.DefaultSelector()
    responses = {}
    try:
        process = subprocess.Popen([executable, "app-server", "--stdio"], env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, bufsize=0)
        selector.register(process.stdout, selectors.EVENT_READ)

        def send(payload):
            process.stdin.write((json.dumps(payload) + "\n").encode())

        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "usagi", "title": "Usagi", "version": "1.0.0"},
            "capabilities": {}}})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not {2, 3}.issubset(responses):
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            request_id = message.get("id")
            if request_id == 1:
                if "result" not in message:
                    break
                send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
                send({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}})
                send({"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": {}})
            elif request_id in (2, 3):
                responses[request_id] = message.get("result") or {}
    except (OSError, ValueError, BrokenPipeError):
        pass
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

    account = responses.get(2, {}).get("account") or {}
    if account.get("type") != "chatgpt":
        return {"email": None, "plan": None, "windows": {}}
    return {"email": account.get("email"), "plan": account.get("planType"),
            "windows": codex_windows(responses.get(3, {}).get("rateLimits") or {})}


def window_key(minutes, fallback):
    if not isinstance(minutes, int) or minutes <= 0:
        return fallback
    if minutes % 1440 == 0:
        return "%dd" % (minutes // 1440)
    return "%dh" % round(minutes / 60)


def codex_windows(limits):
    windows = {}
    for fallback, field in (("5h", "primary"), ("7d", "secondary")):
        reading = limits.get(field) or {}
        if isinstance(reading.get("usedPercent"), (int, float)):
            windows[window_key(reading.get("windowDurationMins"), fallback)] = {
                "used_percent": reading["usedPercent"],
                "resets_at": reading.get("resetsAt"),
                "captured_at": time.time()}
    return windows


def migrate_legacy_config():
    if CONFIG_DIR.exists() or not LEGACY_CONFIG_DIR.is_dir():
        return
    try:
        LEGACY_CONFIG_DIR.rename(CONFIG_DIR)
    except OSError:
        pass


def visible_cards():
    try:
        saved = json.loads(CARD_FILE.read_text())
    except FileNotFoundError:
        saved = None
    except (OSError, ValueError):
        saved = []
    if saved is None:
        saved = []
        for provider in accounts.PROVIDERS:
            name = accounts.active(provider)
            if signed_in(provider, name, *accounts.dirs(name)):
                saved.append({"provider": provider, "id": name})
    if not isinstance(saved, list):
        return []
    return [card for card in saved if isinstance(card, dict)
            and card.get("provider") in accounts.PROVIDERS
            and card.get("id") in accounts.profiles(card["provider"])]


def save_cards(cards):
    CARD_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = CARD_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(cards, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(CARD_FILE)


def snapshot():
    result = {"providers": {}, "cards": visible_cards()}
    for provider in accounts.PROVIDERS:
        selected = accounts.active(provider)
        entries = []
        names = {card["id"] for card in result["cards"] if card["provider"] == provider}
        for name in sorted(names):
            claude_dir, codex_dir = accounts.dirs(name)
            logged_in = signed_in(provider, name, claude_dir, codex_dir)
            info = {}
            windows = {}
            source = None
            if logged_in and provider == "claude":
                profile_file = None if name == "default" else claude_dir / ".claude.json"
                windows = readers.merge_windows(
                    readers.read_claude_cached(profile_file),
                    readers.read_claude(readers.claude_cache_for(name)))
                info = accounts.account_info(name)
                source = "Claude Code local cache"
            elif logged_in:
                info = codex_live(name, claude_dir, codex_dir)
                windows = info["windows"]
                source = "Codex account limits · official app-server" if windows else None
            connecting = not logged_in and is_connecting(provider, name)
            entries.append({"id": name, "email": info.get("email"),
                            "plan": info.get("plan"),
                            "logged_in": logged_in, "connecting": connecting,
                            "login_error": None if logged_in or connecting else login_error(provider, name),
                            "source": source,
                            "windows": windows})
        result["providers"][provider] = {"active": selected, "accounts": entries}
    return result


def add_card(provider, name):
    if provider not in accounts.PROVIDERS:
        raise accounts.AccountError("Unknown provider")
    if name not in accounts.profiles(provider):
        accounts.add(name, provider)
    cards = visible_cards()
    card = {"provider": provider, "id": name}
    if card not in cards:
        cards.append(card)
    save_cards(cards)


def add_next_card(provider):
    if provider not in accounts.PROVIDERS:
        raise accounts.AccountError("Unknown provider")
    shown = {card["id"] for card in visible_cards() if card["provider"] == provider}
    name = next((candidate for candidate in accounts.profiles(provider) if candidate not in shown), None)
    if name is None:
        number = 2
        existing = set(accounts.profiles(provider))
        while "account-%d" % number in existing:
            number += 1
        name = "account-%d" % number
    add_card(provider, name)
    return name


def remove_card(provider, name):
    cards = visible_cards()
    card = {"provider": provider, "id": name}
    if card not in cards:
        raise accounts.AccountError("That account is not in the list")
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


def is_connecting(provider, name):
    path = login_file(provider, name)
    try:
        pid = int(path.read_text())
        os.kill(pid, 0)
        return True
    except (FileNotFoundError, ValueError, ProcessLookupError):
        path.unlink(missing_ok=True)
        return False
    except PermissionError:
        return True


def open_browser(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("Invalid sign-in URL")
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if not subprocess.run(["/usr/bin/open", "-a", "Google Chrome", url], **quiet).returncode:
        subprocess.run(["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to activate'], **quiet)
    elif subprocess.run(["/usr/bin/open", url], **quiet).returncode:
        raise RuntimeError("Could not open the sign-in page in a browser")


def login_ready():
    print(json.dumps({"ready": True}), flush=True)


def codex_login_worker(executable, env):
    process = subprocess.Popen([executable, "app-server", "--stdio"], env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)

        def send(payload):
            try:
                process.stdin.write((json.dumps(payload) + "\n").encode())
            except BrokenPipeError:
                raise RuntimeError("The Codex sign-in process exited") from None

        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "usagi", "title": "Usagi", "version": "1.0.0"},
            "capabilities": {}}})
        deadline = time.monotonic() + LOGIN_TIMEOUT
        while time.monotonic() < deadline:
            if not selector.select(min(1, max(0, deadline - time.monotonic()))):
                if process.poll() is not None:
                    raise RuntimeError("The Codex sign-in process exited")
                continue
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("The Codex sign-in process exited")
            message = json.loads(line)
            if message.get("method") == "account/login/completed":
                params = message.get("params") or {}
                if not params.get("success"):
                    raise RuntimeError(params.get("error") or "Codex sign-in failed")
                return
            if "method" in message:
                continue
            if message.get("id") == 1:
                if "result" not in message:
                    raise RuntimeError("Could not start the Codex app-server")
                send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
                send({"jsonrpc": "2.0", "id": 2, "method": "account/login/start",
                      "params": {"type": "chatgpt"}})
            elif message.get("id") == 2:
                response = message.get("result") or {}
                if response.get("type") != "chatgpt" or not response.get("authUrl"):
                    raise RuntimeError((message.get("error") or {}).get("message")
                                       or "Codex did not return a sign-in URL")
                open_browser(response["authUrl"])
                login_ready()
        raise RuntimeError("Sign-in timed out. Try again.")
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()


def claude_login_worker(executable, env):
    with tempfile.TemporaryDirectory(prefix="usagi-login-") as folder:
        marker = Path(folder) / "browser-opened"
        env["BROWSER"] = str(Path(__file__).with_name("open-browser.sh"))
        env["USAGI_BROWSER_MARKER"] = str(marker)
        process = subprocess.Popen([executable, "auth", "login"], env=env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        selector = selectors.DefaultSelector()
        opened = False
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + LOGIN_TIMEOUT
            while time.monotonic() < deadline:
                browser_status = marker.read_text() if marker.exists() else None
                if browser_status == "error":
                    raise RuntimeError("Could not open the sign-in page in a browser")
                if browser_status == "opened" and not opened:
                    login_ready()
                    opened = True
                if not selector.select(min(1, max(0, deadline - time.monotonic()))):
                    if process.poll() is not None:
                        break
                    continue
                if not process.stdout.readline():
                    break
            if not opened:
                raise RuntimeError("Could not open the Claude sign-in page")
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()


def login(provider, name):
    validate_login(provider, name)
    login_error_file(provider, name).unlink(missing_ok=True)
    if is_connecting(provider, name):
        path = login_file(provider, name)
        pid = int(path.read_text())
        try:
            if os.getpgid(pid) == pid:
                os.killpg(pid, signal.SIGTERM)
                for _ in range(40):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
        except ProcessLookupError:
            pass
        path.unlink(missing_ok=True)
    worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                               "login_worker", provider, name],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    selector = selectors.DefaultSelector()
    ready = False
    try:
        selector.register(worker.stdout, selectors.EVENT_READ)
        if not selector.select(15):
            raise RuntimeError("Timed out opening the sign-in page")
        line = worker.stdout.readline()
        response = json.loads(line) if line else {}
        if response.get("ready") is not True:
            raise RuntimeError(response.get("error") or "Could not open the sign-in page")
        ready = True
    except (OSError, ValueError) as exc:
        raise RuntimeError("Could not open the sign-in page") from exc
    finally:
        selector.close()
        worker.stdout.close()
        if not ready and worker.poll() is None:
            worker.terminate()


def login_worker(provider, name):
    validate_login(provider, name)
    LOGIN_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = login_file(provider, name)
    path.write_text(str(os.getpid()))
    path.chmod(0o600)
    try:
        claude_dir, codex_dir = accounts.dirs(name)
        executable, env = auth_context(provider, name, claude_dir, codex_dir)
        if provider == "codex":
            codex_login_worker(executable, env)
        else:
            claude_login_worker(executable, env)
    except Exception as exc:
        error = login_error_file(provider, name)
        error.write_text(str(exc))
        error.chmod(0o600)
        raise
    finally:
        try:
            if path.read_text() == str(os.getpid()):
                path.unlink()
        except FileNotFoundError:
            pass


def main(argv):
    migrate_legacy_config()
    action = argv[0] if argv else "snapshot"
    if action == "snapshot" and len(argv) == 1:
        print(json.dumps(snapshot(), ensure_ascii=False))
    elif action == "select" and len(argv) == 3:
        accounts.use(argv[2], argv[1])
        print(json.dumps(snapshot(), ensure_ascii=False))
    elif action == "add" and len(argv) == 3:
        add_card(argv[1], argv[2])
        print(json.dumps(snapshot(), ensure_ascii=False))
    elif action == "add_auto" and len(argv) == 2:
        add_next_card(argv[1])
        print(json.dumps(snapshot(), ensure_ascii=False))
    elif action == "login" and len(argv) == 3:
        login(argv[1], argv[2])
        print(json.dumps({"ok": True}))
    elif action == "login_worker" and len(argv) == 3:
        login_worker(argv[1], argv[2])
    elif action == "remove" and len(argv) == 3:
        remove_card(argv[1], argv[2])
        print(json.dumps(snapshot(), ensure_ascii=False))
    else:
        raise ValueError("Invalid command")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        sys.exit(1)
