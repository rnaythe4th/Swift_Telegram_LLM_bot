"""Run the Swift bot and, when configured, its loopback browser worker."""

import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from maintenance import WINDOW_SOCKET, close_window


SHUTDOWN_SECONDS = 25
PR_SET_CHILD_SUBREAPER = 36


def worker_environment():
    allowed = {"HOME", "LANG", "PATH", "PYTHONUNBUFFERED", "SSL_CERT_FILE", "TZ"}
    return {
        key: value
        for key, value in os.environ.items()
        if key in allowed or key.startswith(("DEEPSEEK_WEB_", "LC_"))
    }


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def reap_orphans(keep=()):
    # WebDriver creates a separate process group. The kernel reparents it to
    # this supervisor if the worker dies before it can close Firefox.
    children = Path("/proc/thread-self/children")
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            pids = children.read_text().split()
        except OSError:
            print("Could not enumerate orphaned browser processes", file=sys.stderr)
            return
        orphans = [pid for pid in map(int, pids) if pid not in keep]
        if not orphans:
            return
        for pid in orphans:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, os.WNOHANG)
            except (ProcessLookupError, ChildProcessError):
                pass
        time.sleep(0.05)


def main():
    if os.getuid() != 65532 or os.getgid() != 65532:
        raise SystemExit("Bot runtime requires UID/GID 65532")

    stop_signal = None

    def stop(signum, _frame):
        nonlocal stop_signal
        stop_signal = signum

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    subreaper = ctypes.CDLL(None).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0
    if not subreaper:
        print("Process reparenting is unavailable in this runtime", file=sys.stderr)

    worker = None
    if os.environ.get("DEEPSEEK_WEB_PROFILE_DIR"):
        if os.environ.get("DEEPSEEK_WEB_WORKER_TOKEN"):
            worker = subprocess.Popen(
                [sys.executable, "/opt/deepseek-web/worker.py"],
                env=worker_environment(),
                start_new_session=True,
            )
        else:
            print("DeepSeek Web worker unavailable: missing worker token", file=sys.stderr)

    app = subprocess.Popen(["/usr/local/bin/app"], start_new_session=True)
    while stop_signal is None and app.poll() is None:
        if worker and worker.poll() is not None:
            print("DeepSeek Web worker stopped; restart the deployment to restore it", file=sys.stderr)
            kill_group(worker)
            if subreaper:
                reap_orphans(keep=(app.pid,))
            worker = None
        time.sleep(0.1)

    close_window()
    children = [process for process in (app, worker) if process is not None]
    for process in children:
        if process.poll() is None:
            process.terminate()

    deadline = time.monotonic() + SHUTDOWN_SECONDS
    while time.monotonic() < deadline:
        if all(process.poll() is not None for process in children) and not WINDOW_SOCKET.exists():
            break
        time.sleep(0.1)
    for process in children:
        kill_group(process)
        process.wait()
    if subreaper:
        reap_orphans()
    if stop_signal is not None and app.returncode == -signal.SIGTERM:
        return 0
    return 128 - app.returncode if app.returncode < 0 else app.returncode


if __name__ == "__main__":
    sys.exit(main())
