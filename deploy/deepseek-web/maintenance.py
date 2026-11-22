"""Open a time-limited Firefox session on the worker's persistent profile."""

import argparse
from contextlib import contextmanager
import fcntl
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time


RUNTIME = Path("/run/deepseek-web")
WINDOW_SOCKET = RUNTIME / "window.sock"
WINDOW_LOCK = RUNTIME / "window.lock"
DISPLAY = ":93"
VNC_PORT = 15943


def worker_request(action, payload=None, timeout=15):
    token = os.environ.get("DEEPSEEK_WEB_WORKER_TOKEN")
    if not token:
        raise RuntimeError("Missing DEEPSEEK_WEB_WORKER_TOKEN")
    port = int(os.environ.get("DEEPSEEK_WEB_WORKER_PORT", "8765"))
    connection = HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    body = json.dumps({"version": 1, **payload}) if payload is not None else None
    try:
        connection.request("POST" if body else "GET", f"/v1/{action}", body, headers)
        response = connection.getresponse()
        result = json.loads(response.read(16_384))
        if (response.status not in (200, 409, 503) or not isinstance(result, dict)
                or result.get("version") != 1):
            raise RuntimeError(f"Unexpected worker response (HTTP {response.status})")
        return result
    except (OSError, HTTPException, ValueError) as error:
        raise RuntimeError("Loopback DeepSeek Web worker unavailable") from error
    finally:
        connection.close()


@contextmanager
def exclusive_lock(path, timeout=0):
    with path.open("a") as lock:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Firefox profile or maintenance session is still in use")
                time.sleep(0.1)
        yield


@contextmanager
def window_control():
    WINDOW_SOCKET.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(WINDOW_SOCKET))
        listener.listen(1)
        try:
            yield listener
        finally:
            WINDOW_SOCKET.unlink(missing_ok=True)


def close_window():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(0.5)
        try:
            client.connect(str(WINDOW_SOCKET))
        except OSError:
            return


def stop_requested(listener, seconds):
    listener.settimeout(seconds)
    try:
        connection, _ = listener.accept()
    except (TimeoutError, BlockingIOError):
        return False
    connection.close()
    return True


def gui_environment(xauthority):
    allowed = {"HOME", "LANG", "PATH", "TZ"}
    env = {key: value for key, value in os.environ.items() if key in allowed or key.startswith("LC_")}
    env.update({"DISPLAY": DISPLAY, "XAUTHORITY": str(xauthority)})
    return env


@contextmanager
def gui_processes():
    children = []

    def spawn(command, env, log):
        process = subprocess.Popen(
            command, env=env, stdin=subprocess.DEVNULL,
            stdout=log, stderr=log, start_new_session=True,
        )
        children.append(process)
        return process

    try:
        yield spawn
    finally:
        # Let Firefox close the profile before tearing the display down.
        for process in reversed(children):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def wait_for_gui(probe, process, error_message):
    deadline = time.monotonic() + 8
    while process.poll() is None and time.monotonic() < deadline:
        if probe():
            return
        time.sleep(0.1)
    raise RuntimeError(error_message)


def display_available(env):
    try:
        return subprocess.run(
            ["xdpyinfo"], env=env, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=1, check=False,
        ).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def vnc_available():
    try:
        with socket.create_connection(("127.0.0.1", VNC_PORT), timeout=0.5) as connection:
            return connection.recv(12).startswith(b"RFB ")
    except OSError:
        return False


def open_window(profile, listener, seconds):
    with tempfile.TemporaryDirectory(prefix="auth-", dir=RUNTIME) as temp_dir:
        directory = Path(temp_dir)
        xauthority = directory / "Xauthority"
        xauthority.touch(mode=0o600)
        env = gui_environment(xauthority)
        subprocess.run(
            ["xauth", "-q"], env=env, check=True,
            input=f"add {DISPLAY} . {secrets.token_hex(16)}\n", text=True,
        )
        password_file = directory / "vnc.pass"
        password = secrets.token_urlsafe(6)
        saved_password = subprocess.run(
            ["x11vnc", "-storepasswd", password, str(password_file)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if saved_password.returncode != 0:
            raise RuntimeError("Temporary VNC password could not be saved")
        with (directory / "session.log").open("w") as log, gui_processes() as spawn:
            xvfb = spawn(["Xvfb", DISPLAY, "-screen", "0", "1280x800x24",
                          "-nolisten", "tcp", "-auth", str(xauthority)], env, log)
            wait_for_gui(lambda: display_available(env), xvfb, "Temporary X display failed to start")
            vnc = spawn(["x11vnc", "-display", DISPLAY, "-localhost", "-noipv6",
                         "-rfbport", str(VNC_PORT), "-rfbauth", str(password_file),
                         "-noshm", "-shared", "-forever"], env, log)
            wait_for_gui(vnc_available, vnc, "Loopback VNC failed to start")
            firefox = spawn([os.environ.get("DEEPSEEK_WEB_FIREFOX_BINARY", "/usr/bin/firefox-esr"),
                             "--no-remote", "--profile", str(profile),
                             "https://chat.deepseek.com/"], env, log)
            print(f"VNC on 127.0.0.1:{VNC_PORT}. One-time password: {password}", flush=True)
            print(f"Window expires in {seconds} seconds. Close it with the finish command.", flush=True)
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline and all(p.poll() is None for p in (firefox, xvfb, vnc)):
                if stop_requested(listener, 0.25):
                    return


def start(seconds):
    profile_dir = os.environ.get("DEEPSEEK_WEB_PROFILE_DIR")
    if not profile_dir or not Path(profile_dir).is_dir():
        raise RuntimeError("DeepSeek Web profile is unavailable")
    profile = Path(profile_dir)
    with exclusive_lock(WINDOW_LOCK), window_control() as listener:
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            result = worker_request("maintenance/start", {})
            if result.get("status") == "maintenance":
                break
            if result.get("status") != "busy":
                raise RuntimeError(f"Worker refused maintenance ({result.get('status', 'unknown')})")
            if stop_requested(listener, 0.5):
                return
        else:
            raise RuntimeError("Worker did not release the browser")
        if stop_requested(listener, 0):
            return
        with exclusive_lock(profile / ".deepseek-web.lock", timeout=8):
            open_window(profile, listener, seconds)


def finish(account_changed):
    close_window()
    with exclusive_lock(WINDOW_LOCK, timeout=45):
        result = worker_request(
            "maintenance/finish", {"verify": True, "accountChanged": account_changed}, timeout=65,
        )
        if not result.get("ready"):
            raise RuntimeError(f"Worker is still paused ({result.get('status', 'unknown')})")
        print("DeepSeek Web worker reports ready")


def status():
    result = worker_request("health")
    print(f"DeepSeek Web worker: {result.get('status', 'unknown')}")
    print(f"Temporary login session: {'active' if WINDOW_SOCKET.exists() else 'closed'}")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(prog="deepseek-web-maintenance")
    commands = parser.add_subparsers(dest="command", required=True)
    start_parser = commands.add_parser("start")
    start_parser.add_argument("--seconds", type=int, default=600, choices=range(60, 901), metavar="60..900")
    commands.add_parser("status")
    finish_parser = commands.add_parser("finish")
    finish_parser.add_argument("--account-changed", action="store_true")
    args = parser.parse_args()

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        if args.command == "start":
            start(args.seconds)
            print("Temporary Firefox closed. Web stays paused until finish verifies sign-in.")
        elif args.command == "finish":
            finish(args.account_changed)
        else:
            status()
        return 0
    except KeyboardInterrupt:
        if args.command == "start":
            print("Temporary Firefox closed. Web stays paused until finish verifies sign-in.")
        return 130
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Maintenance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
