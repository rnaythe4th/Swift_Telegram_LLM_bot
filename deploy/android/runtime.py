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
        "DEFAULT_AI_PROVIDER": "deepseek-web",
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


def reap_exited_browser_children(worker_pid):
    for pid in child_processes():
        if pid != worker_pid:
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


def run_web(command, env):
    subreaper = ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_stop)
    worker = subprocess.Popen(command, env=env, start_new_session=True)
    try:
        while not stop and worker.poll() is None:
            if subreaper:
                reap_exited_browser_children(worker.pid)
            time.sleep(0.2)
    finally:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as window:
            window.settimeout(0.5)
            try:
                window.connect(str(WORKER_RUNTIME / "window.sock"))
            except OSError:
                pass
        if worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
        try:
            os.killpg(worker.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        worker.wait()
        if subreaper:
            reap_browser_children()
    if stop:
        return 0
    return worker.returncode if worker.returncode >= 0 else 128 - worker.returncode


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
    if args[0] == "bot":
        binary = str(release / "bin/LLM_chat_bot")
        libraries = release / "lib"
        loader = libraries / "ld-linux-aarch64.so.1"
        if loader.is_file():
            os.execve(loader, [str(loader), "--inhibit-cache", "--library-path", str(libraries), binary], env)
        os.execve(binary, [binary], env)

    env = worker_environment(env)
    python = str(release / ".venv/bin/python")
    source = release / "deepseek-web"
    if args[0] == "web":
        return run_web([python, str(source / "worker.py")], env)
    os.execve(python, [python, str(source / "maintenance.py"), *args[1:]], env)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
