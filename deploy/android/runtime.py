"""Launch the phone's isolated Swift and DeepSeek Web processes."""

import ctypes
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import sys
import time
from urllib.parse import urlsplit


ROOT = Path("/opt/llmchat")
WORKER_RUNTIME = ROOT / "run/worker"
ENV_KEY = re.compile(r"[a-zA-Z_][a-zA-Z_0-9]*")
WORKER_TOKEN = re.compile(r"[A-Za-z0-9_-]{32,256}")
COMMON_ENV = {"HOME", "LANG", "PATH", "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED",
              "SSL_CERT_FILE", "TMPDIR", "TZ", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"}


def read_environment(path):
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        key = key.removeprefix("export ").strip()
        try:
            parts = shlex.split(value, comments=True)
        except ValueError:
            raise ValueError(f"Invalid environment at line {number}") from None
        if "=" not in line or not ENV_KEY.fullmatch(key) or key in values or len(parts) > 1:
            raise ValueError(f"Invalid environment at line {number}")
        values[key] = next(iter(parts), "")
    return values


def check_environment(values):
    for key in ("TG_BOT_TOKEN", "DATABASE_URL", "DEEPSEEK_WEB_WORKER_TOKEN"):
        if not values.get(key):
            raise ValueError(f"Missing {key}")
    if not WORKER_TOKEN.fullmatch(values["DEEPSEEK_WEB_WORKER_TOKEN"]):
        raise ValueError("Invalid DEEPSEEK_WEB_WORKER_TOKEN")
    try:
        database = urlsplit(values["DATABASE_URL"])
        valid_database = (database.scheme in ("postgres", "postgresql") and database.hostname
                          and database.username and database.port != 6543)
    except ValueError:
        valid_database = False
    if not valid_database:
        raise ValueError("DATABASE_URL must use a PostgreSQL session connection")


def process_environment(values):
    env = {key: value for key, value in os.environ.items() if key in {"LANG", "TZ"} or key.startswith("LC_")}
    env.update(values)
    env.update({
        "HOME": str(ROOT / "home"),
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1",
        "TMPDIR": str(ROOT / "run/tmp"),
        "XDG_CACHE_HOME": str(ROOT / "data/cache"),
        "XDG_RUNTIME_DIR": str(WORKER_RUNTIME),
        "UPDATE_MODE": "polling",
        "REQUIRE_DURABLE_STATE": "true",
        "HTTP_BIND_HOST": "127.0.0.1",
        "PORT": "18080",
        "DEEPSEEK_WEB_ENABLED": "true",
        "DEEPSEEK_WEB_PROFILE_DIR": str(ROOT / "data/firefox-profile"),
        "DEEPSEEK_WEB_RUNTIME_DIR": str(WORKER_RUNTIME),
        "DEEPSEEK_WEB_WORKER_PORT": "8766",
        "DEEPSEEK_WEB_DISPLAY": ":94",
        "DEEPSEEK_WEB_VNC_PORT": "15944",
    })
    env.setdefault("DEEPSEEK_WEB_FIREFOX_BINARY", "/usr/bin/firefox-esr")
    env.setdefault("DEEPSEEK_WEB_GECKODRIVER_BINARY", "/usr/bin/geckodriver")
    return env


def worker_environment(env):
    return {key: value for key, value in env.items()
            if key in COMMON_ENV or key.startswith(("DEEPSEEK_WEB_", "LC_"))}


def child_processes():
    try:
        return [int(pid) for pid in Path("/proc/thread-self/children").read_text().split()]
    except OSError:
        return []


def reap_exited_browser_children(keep_pids):
    for pid in child_processes():
        if pid not in keep_pids:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass


def reap_browser_children():
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        pids = child_processes()
        if not pids:
            return
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, os.WNOHANG)
            except (ProcessLookupError, ChildProcessError):
                pass
        time.sleep(0.05)


def run_web(command, env, companion=None):
    subreaper = ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_stop)
    processes = []
    try:
        if companion is not None:
            processes.append(subprocess.Popen(companion[0], env=companion[1], start_new_session=True))
        worker = subprocess.Popen(command, env=env, start_new_session=True)
        processes.append(worker)
        keep = {process.pid for process in processes}
        while not stop and all(process.poll() is None for process in processes):
            if subreaper:
                reap_exited_browser_children(keep)
            time.sleep(0.2)
    finally:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as window:
            window.settimeout(0.5)
            try:
                window.connect(str(WORKER_RUNTIME / "window.sock"))
            except OSError:
                pass
        for process in processes:
            if process.poll() is None:
                process.terminate()
        deadline = time.monotonic() + 25
        for process in processes:
            if process.poll() is None:
                try:
                    process.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    pass
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        if subreaper:
            reap_browser_children()
    if stop:
        return 0
    errors = [p.returncode for p in processes if p.returncode]
    if errors:
        return errors[0] if errors[0] >= 0 else 128 - errors[0]
    return 1


def api_environment(env):
    """Only the local API service receives credentials, never Telegram secrets."""
    return {
        key: value for key, value in env.items() if key in COMMON_ENV or key.startswith("LC_")
    } | {
        "NODE_ENV": "production",
        "NON_INTERACTIVE": "1",
        "OPEN_DASHBOARD": "1",
        "FDSA_RESTARTED": "1",
        "HOST": "127.0.0.1",
        "PORT": env["DEEPSEEK_WEB_API_PORT"],
        "DEEPSEEK_AUTH_PATH": env["DEEPSEEK_WEB_AUTH_PATH"],
        "PROXY_API_KEY": env["DEEPSEEK_WEB_WORKER_TOKEN"],
        "REQUIRE_PROXY_API_KEY": "1",
        "DEEPSEEK_MAX_CONCURRENT": "1",
    }


def main():
    os.umask(0o077)
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "check":
        check_environment(read_environment(Path(args[1])))
        return 0
    if not args or args[0] not in ("bot", "web", "maintenance"):
        raise ValueError("Usage: runtime.py {bot|web|maintenance}")
    if os.getuid() == 0:
        raise ValueError("Run as llmchat with runuser")

    values = read_environment(ROOT / ".env")
    check_environment(values)
    env = process_environment(values)
    release = (ROOT / "current").resolve(strict=True)
    has_api = (release / "free-deepseek-api/server.js").is_file()
    mode = values.get("DEEPSEEK_WEB_BACKEND", "browser")
    if mode not in ("api", "browser"):
        raise ValueError("DEEPSEEK_WEB_BACKEND must be api or browser")
    if mode == "api" and not has_api:
        raise ValueError("API backend selected but FreeDeepseekAPI is not deployed")
    env["DEEPSEEK_WEB_BACKEND"] = mode
    env.setdefault("DEEPSEEK_WEB_IDLE_SECONDS", "never" if mode == "browser" else "60")
    env["DEEPSEEK_WEB_API_PORT"] = values.get("DEEPSEEK_WEB_API_PORT", "9655")
    env["DEEPSEEK_WEB_AUTH_PATH"] = str(ROOT / "data/deepseek-auth.json")
    env["DEEPSEEK_WEB_AUTH_REFRESH_SECONDS"] = values.get("DEEPSEEK_WEB_AUTH_REFRESH_SECONDS", "21600")
    if args[0] == "bot":
        binary = str(release / "bin/LLM_chat_bot")
        libraries = release / "lib"
        loader = libraries / "ld-linux-aarch64.so.1"
        if loader.is_file():
            os.execve(loader, [str(loader), "--inhibit-cache", "--library-path", str(libraries), binary], env)
        os.execve(binary, [binary], env)

    if args[0] == "web":
        worker_env = worker_environment(env)
        if mode == "api":
            companion = (["/usr/bin/node", str(release / "free-deepseek-api/server.js")], api_environment(env))
            return run_web([str(release / ".venv/bin/python"), str(release / "deepseek-web/worker.py")],
                           worker_env, companion=companion)
        return run_web([str(release / ".venv/bin/python"), str(release / "deepseek-web/worker.py")], worker_env)
    env = worker_environment(env)
    python = str(release / ".venv/bin/python")
    source = release / "deepseek-web"
    os.execve(python, [python, str(source / "maintenance.py"), *args[1:]], env)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
