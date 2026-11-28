"""Authenticated loopback service and browser operation lifecycle."""

from collections import OrderedDict
from dataclasses import dataclass, field, replace
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import signal
import socket
import tempfile
import threading
import time
from uuid import UUID, uuid4

from browser import Browser, BrowserFailure, CHAT_ID, TAIL, private_directory

LOG = logging.getLogger("deepseek-web")
MAX_HTTP_BYTES = 96_000
MAX_PROMPT_BYTES = 12_000
RESULT_LIMIT = 32
RESULT_TTL = 1800
PREPARED_TTL = 45
BODY_TIMEOUT = 5
WARM_WAIT_SECONDS = 35
WARM_RETRY_SECONDS = 15
AUTH_TOKEN = re.compile(r"[a-zA-Z0-9._~+/=-]{16,256}", re.ASCII)


@dataclass(frozen=True)
class Request:
    id: UUID
    account_epoch: UUID
    account_marker: UUID | None
    remote_id: str | None
    tail: str | None
    prompt: str | None
    candidate_id: str | None = None
    deep_think: bool | None = None
    web_search: bool | None = None

    @property
    def binding(self):
        return self.account_epoch, self.account_marker, self.remote_id, self.tail, self.deep_think, self.web_search

    @property
    def search_enabled(self):
        return self.web_search is not False

    @property
    def prompt_digest(self):
        return hashlib.sha256(self.prompt.encode()).digest() if self.prompt else None


@dataclass
class Operation:
    request: Request
    phase: str
    stop: threading.Event = field(default_factory=threading.Event)
    prepared: object = None
    deadline: float = 0
    candidate_id: str | None = None
    accepted: bool = False
    partial_text: str | None = None
    partial_formatted_text: str | None = None


def check_version(payload):
    if not isinstance(payload, dict) or type(payload.get("version")) is not int or payload["version"] != 1:
        raise ValueError


def parse_request(payload, action):
    check_version(payload)
    if set(payload) - {
        "version", "operationID", "accountEpoch", "accountMarker", "remoteChatID", "remoteTail", "prompt",
        "candidateRemoteChatID", "deepThink", "webSearch",
    }:
        raise ValueError
    operation_id = UUID(payload["operationID"])
    account_epoch = UUID(payload["accountEpoch"])
    account_marker = UUID(payload["accountMarker"]) if payload.get("accountMarker") is not None else None
    remote_id, tail, prompt = payload.get("remoteChatID"), payload.get("remoteTail"), payload.get("prompt")
    candidate_id = payload.get("candidateRemoteChatID")
    if any(value is not None and (not isinstance(value, str) or not CHAT_ID.fullmatch(value)) for value in (remote_id, candidate_id)):
        raise ValueError
    if candidate_id is not None and (action not in {"status", "reconcile", "cancel"} or remote_id not in {None, candidate_id}):
        raise ValueError
    if tail is not None and (not isinstance(tail, str) or not TAIL.fullmatch(tail) or remote_id is None):
        raise ValueError
    if action in {"prepare", "send"} and remote_id is not None and tail is None:
        raise ValueError
    if prompt is not None and (not isinstance(prompt, str) or not prompt.strip() or "\x00" in prompt):
        raise ValueError
    if action in {"send", "reconcile"} and prompt is None:
        raise ValueError
    if prompt is not None:
        prompt.encode("utf-8")  # Reject unpaired surrogates before dispatch.
    if any(field in payload and type(payload[field]) is not bool for field in ("deepThink", "webSearch")):
        raise ValueError
    return Request(operation_id, account_epoch, account_marker, remote_id, tail, prompt, candidate_id,
                   deep_think=payload.get("deepThink"), web_search=payload.get("webSearch"))


def reply(request, status, accepted=False, **fields):
    return {
        "version": 1, "operationID": str(request.id), "status": status, "accepted": accepted,
        **{key: value for key, value in fields.items() if value is not None},
    }


def write_state(path, value):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(value)
            file.flush()
            os.fsync(file.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    sync_directory(path.parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Worker:
    def __init__(self, browser, *, prepared_ttl=PREPARED_TTL, idle_seconds=60):
        self.browser = browser
        self.gate_path = Path(browser.profile) / ".maintenance"
        self.marker_path = Path(browser.profile) / ".account-marker"
        self.marker = UUID(self.marker_path.read_text().strip()) if self.marker_path.exists() else None
        self.gate = self.gate_path.read_text().strip() if self.gate_path.exists() else None
        if self.gate not in (None, "maintenance", "loginRequired"):
            self.gate = "maintenance"
        self.gate_revision = 0
        self.lock = threading.Condition()
        self.active = None
        self.results = OrderedDict()
        self.prepared_ttl = prepared_ttl
        self.idle_seconds = idle_seconds
        self.last_activity = time.monotonic()
        self.warm_stop = None
        self.warm_retry_at = 0
        self.closing_browser = False
        self.shutting_down = False
        self.sweeper = threading.Thread(target=self._sweep, name="browser-lifecycle", daemon=True)
        self.sweeper.start()

    def health(self):
        upstream_status = self.browser.ready() if getattr(self.browser, "is_api", False) else "ready"
        with self.lock:
            if self.shutting_down:
                status = "unavailable"
            elif self.gate:
                status = self.gate
            elif self.warm_stop is not None:
                status = "warming"
            elif self.active or self.closing_browser:
                status = "busy"
            else:
                status = upstream_status
            response = {"version": 1, "status": status, "ready": status in {"ready", "busy"}}
            if self.idle_seconds is None:
                response["browserWarm"] = (status == "ready" and self.browser.session is not None)
            if self.marker:
                response["accountMarker"] = str(self.marker)
            return response

    def _store(self, request, result):
        expiry = time.monotonic() + RESULT_TTL
        self.results[request.id] = (request.binding, request.prompt_digest, result, expiry)
        self.results.move_to_end(request.id)
        while len(self.results) > RESULT_LIMIT:
            self.results.popitem(last=False)

    def _cached(self, request):
        result = self.results.get(request.id)
        if result and result[3] > time.monotonic():
            if result[0] != request.binding or (result[1] and request.prompt_digest and result[1] != request.prompt_digest):
                return reply(request, "notAccepted")
            return result[2]
        return None

    def _close(self):
        try:
            self.browser.close()
        except Exception as error:
            LOG.error("browser shutdown failed (%s)", type(error).__name__)

    def _sweep(self):
        while True:
            with self.lock:
                if self.shutting_down:
                    return
                now = time.monotonic()
                for key in [key for key, item in self.results.items() if item[3] <= now]:
                    self.results.pop(key, None)
                if self.active and self.active.phase == "prepared" and self.active.deadline <= now:
                    self._release_prepared("cancelled")
                if self.active or self.closing_browser or self.gate:
                    self.lock.wait(0.5)
                    continue
                if (getattr(self.browser, "is_api", False)
                        and now >= self.browser.next_refresh and now >= self.warm_retry_at):
                    warm_stop = self.warm_stop = threading.Event()
                    self.browser.next_refresh = now + self.browser.refresh_seconds
                elif self.idle_seconds is None and self.browser.session is None and now >= self.warm_retry_at:
                    warm_stop = self.warm_stop = threading.Event()
                elif (self.idle_seconds is not None and self.browser.session is not None
                        and now - self.last_activity >= self.idle_seconds):
                    warm_stop = None
                    self.closing_browser = True
                else:
                    self.lock.wait(0.5)
                    continue
            if warm_stop is not None:
                self._warm(warm_stop)
            else:
                self._close()
                with self.lock:
                    self.closing_browser = False
                    self.lock.notify_all()

    def _warm(self, stop):
        started = time.monotonic()
        failure = None
        try:
            self.browser.verify(stop)
        except BrowserFailure as error:
            failure = error.status
        except Exception as error:
            failure = type(error).__name__
        if failure or stop.is_set():
            self._close()
        with self.lock:
            if failure == "loginRequired":
                self._pause_for_login()
            self.warm_stop = None
            self.last_activity = time.monotonic()
            self.warm_retry_at = self.last_activity + WARM_RETRY_SECONDS
            self.lock.notify_all()
        if failure and not stop.is_set():
            LOG.warning("browser warmup failed (%s) %.2fs", failure, time.monotonic() - started)
        elif not stop.is_set():
            LOG.info("browser warmed %.2fs", time.monotonic() - started)

    def _pause_for_login(self):
        if not self.gate:
            self.gate = "loginRequired"
            try:
                write_state(self.gate_path, self.gate)
            except OSError:
                LOG.error("could not persist browser authentication pause")

    def _release_prepared(self, status):
        operation = self.active
        operation.stop.set()
        self._store(operation.request, reply(operation.request, status))
        self.active = None
        self.last_activity = time.monotonic()
        self.lock.notify_all()

    def _progress(self, operation, remote_id, accepted, partial_text, formatted_text):
        with self.lock:
            operation.candidate_id = remote_id or operation.candidate_id
            operation.accepted |= accepted
            operation.partial_text = partial_text if remote_id and accepted else None
            operation.partial_formatted_text = formatted_text if operation.partial_text else None

    def _in_progress(self, request, operation):
        phase = "prepared" if operation.phase == "prepared" else "inProgress"
        partial = operation.partial_text if operation.phase == "sending" and not operation.stop.is_set() else None
        return reply(request, phase, operation.accepted, remoteChatID=operation.candidate_id,
                     partialText=partial, partialFormattedText=operation.partial_formatted_text if partial else None,
                     mayHaveSent=operation.phase in {"sending", "reconciling"})

    def perform(self, request, action):
        oversized = request.prompt and len(request.prompt.encode()) > MAX_PROMPT_BYTES
        with self.lock:
            if request.account_marker != self.marker:
                return reply(request, "notAccepted")
            if self.warm_stop is not None and action in {"prepare", "reconcile"}:
                ready = self.lock.wait_for(
                    lambda: self.warm_stop is None or self.gate or self.shutting_down, timeout=WARM_WAIT_SECONDS,
                )
                if not ready:
                    return reply(request, "unavailable")
                if request.account_marker != self.marker:
                    return reply(request, "notAccepted")
            cached = self._cached(request)
            current = self.active
            if current and current.request.id == request.id and current.request.binding != request.binding:
                return reply(request, "notAccepted")
            own = current is not None and current.request.id == request.id
            if (own and current.request.prompt_digest and request.prompt_digest
                    and current.request.prompt_digest != request.prompt_digest):
                return reply(request, "notAccepted")

            known_id = current.candidate_id if own else (cached or {}).get("remoteChatID")
            if request.candidate_id and known_id and request.candidate_id != known_id:
                return reply(request, "uncertain", mayHaveSent=True)

            if action == "status":
                if own:
                    return self._in_progress(request, current)
                return cached or reply(request, "uncertain")

            if action == "cancel":
                if own:
                    if current.phase == "prepared":
                        self._release_prepared("cancelled")
                        return reply(request, "cancelled")
                    current.stop.set()
                    return self._in_progress(request, current)
                if cached:
                    return cached
                result = reply(request, "cancelled")
                self._store(request, result)
                return result

            if self.shutting_down or self.gate:
                return reply(request, self.gate or "unavailable")
            if oversized:
                if own and current.phase == "prepared":
                    self._release_prepared("inputTooLong")
                return reply(request, "inputTooLong")
            if self.closing_browser:
                return reply(request, "busy")

            if action == "send":
                if not own or current.phase != "prepared":
                    if own:
                        return self._in_progress(request, current)
                    return cached or reply(request, "notAccepted")
                if current.deadline <= time.monotonic() or current.stop.is_set():
                    self._release_prepared("cancelled")
                    return reply(request, "cancelled")
                operation = current
                operation.request = request
                operation.phase = "sending"
            elif action == "prepare":
                if own:
                    return self._in_progress(request, current)
                if cached:
                    return cached
                if current:
                    return reply(request, "busy")
                operation = Operation(request, "preparing", candidate_id=request.remote_id)
                self.active = operation
            else:
                if own:
                    return self._in_progress(request, current)
                if cached and (cached["status"] == "completed" or not cached.get("mayHaveSent")):
                    return cached
                if current:
                    return reply(request, "busy")
                candidate = request.remote_id or known_id or request.candidate_id
                if not candidate:
                    return reply(request, "uncertain")
                operation = Operation(request, "reconciling", candidate_id=candidate)
                self.active = operation

        return self._run(operation)

    def _run(self, operation):
        request = operation.request
        start = time.monotonic()
        result = reply(request, "unavailable")

        def update(remote_id, accepted, partial_text=None, formatted_text=None):
            self._progress(operation, remote_id, accepted, partial_text, formatted_text)

        try:
            if operation.phase == "preparing":
                prepared = self.browser.prepare(request, operation.stop)
                with self.lock:
                    if not operation.stop.is_set() and not self.gate and not self.shutting_down:
                        operation.prepared = prepared
                        # API transport preallocates an opaque chat ID so Swift can
                        # persist a candidate before an uncertain HTTP send.
                        operation.candidate_id = getattr(prepared, "remote_id", None) or operation.candidate_id
                        operation.phase = "prepared"
                        operation.deadline = time.monotonic() + self.prepared_ttl
                        LOG.info("operation %s preparing prepared %.2fs", request.id, time.monotonic() - start)
                        return self._in_progress(request, operation)
                raise BrowserFailure("cancelled")

            if operation.phase == "sending":
                answer = self.browser.send(request, operation.prepared, operation.stop, update)
            else:
                answer = self.browser.reconcile(replace(request, remote_id=operation.candidate_id), operation.stop, update)
            result = reply(request, "completed", True, remoteChatID=answer.remote_id,
                           remoteTail=answer.tail, text=answer.text, formattedText=answer.formatted_text, mayHaveSent=True)
        except BrowserFailure as error:
            result = reply(request, error.status, error.accepted or operation.accepted,
                           remoteChatID=error.remote_id or operation.candidate_id,
                           retryAfterSeconds=error.retry_after,
                           mayHaveSent=error.may_have_sent or operation.accepted or operation.phase == "reconciling")
        except Exception as error:
            LOG.warning("operation %s failed (%s)", request.id, type(error).__name__)
            maybe_sent = operation.phase != "preparing"
            result = reply(request, "uncertain" if maybe_sent else "unavailable", operation.accepted,
                           remoteChatID=operation.candidate_id, mayHaveSent=maybe_sent)

        rejected_before_send = (not result.get("mayHaveSent")
                                and result["status"] in {"chatUnavailable", "quota", "busy", "inputTooLong", "moderated"})
        if operation.stop.is_set() or (result["status"] != "completed" and not rejected_before_send):
            self._close()

        with self.lock:
            if result["status"] == "loginRequired":
                self._pause_for_login()
            self._store(request, result)
            self.last_activity = time.monotonic()
            if self.browser.session is None:
                self.warm_retry_at = self.last_activity + WARM_RETRY_SECONDS
            self.active = None
            self.lock.notify_all()

        LOG.info("operation %s %s %s %.2fs", request.id, operation.phase, result["status"], time.monotonic() - start)
        return result

    def begin_maintenance(self):
        with self.lock:
            self.gate = "maintenance"
            self.gate_revision += 1
            write_state(self.gate_path, self.gate)
            if self.active:
                if self.active.phase == "prepared":
                    self._release_prepared("cancelled")
                else:
                    self.active.stop.set()
                    return self._maintenance_reply("busy")
            if self.warm_stop is not None:
                self.warm_stop.set()
                self.lock.notify_all()
                return self._maintenance_reply("busy")
            if self.closing_browser:
                return self._maintenance_reply("busy")
            self.closing_browser = True
        self._close()
        with self.lock:
            self.closing_browser = False
            self.lock.notify_all()
            return self._maintenance_reply("maintenance")

    def _maintenance_reply(self, status):
        response = {"version": 1, "status": status, "ready": status == "ready"}
        if self.marker:
            response["accountMarker"] = str(self.marker)
        return response

    def end_maintenance(self, *, verify, account_changed, abort):
        with self.lock:
            if not self.gate or self.shutting_down:
                return self._maintenance_reply("unavailable")
            if self.active or self.closing_browser or self.warm_stop is not None:
                return self._maintenance_reply("busy")
            if abort:
                return self._maintenance_reply("maintenance")
            self.closing_browser = True
            revision = self.gate_revision
        status = "ready"
        try:
            if not verify:
                raise BrowserFailure("maintenance")
            self.browser.verify(threading.Event())
            with self.lock:
                if self.shutting_down or self.gate_revision != revision:
                    raise BrowserFailure("maintenance")
                if account_changed:
                    marker = uuid4()
                    write_state(self.marker_path, str(marker))
                    self.marker = marker
                    self.results.clear()
                self.gate_path.unlink(missing_ok=True)
                sync_directory(self.gate_path.parent)
                self.gate = None
        except BrowserFailure as error:
            status = error.status
        except BlockingIOError:
            status = "busy"
        except Exception as error:
            LOG.warning("browser authorization verification failed (%s)", type(error).__name__)
            status = "unavailable"
        finally:
            if status != "ready" or self.idle_seconds is not None:
                self._close()
            with self.lock:
                self.closing_browser = False
                self.last_activity = time.monotonic()
                self.lock.notify_all()
        with self.lock:
            return self._maintenance_reply(status)

    def shutdown(self):
        with self.lock:
            self.shutting_down = True
            if self.active:
                if self.active.phase == "prepared":
                    self._release_prepared("cancelled")
                else:
                    self.active.stop.set()
            if self.warm_stop is not None:
                self.warm_stop.set()
            self.lock.notify_all()
            idle = self.lock.wait_for(
                lambda: self.active is None and self.warm_stop is None and not self.closing_browser, timeout=28,
            )
        if idle:
            self._close()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, token, worker):
        if not AUTH_TOKEN.fullmatch(token):
            raise ValueError("invalid DEEPSEEK_WEB_WORKER_TOKEN")
        self.authorization = f"Bearer {token}".encode()
        self.worker = worker
        self.handlers = threading.BoundedSemaphore(16)
        super().__init__(("127.0.0.1", port), Handler)

    def process_request(self, request, client_address):
        if not self.handlers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.handlers.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.handlers.release()

    def handle_error(self, request, client_address):
        LOG.warning("worker HTTP handler failed")


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(BODY_TIMEOUT)
        super().setup()

    def log_message(self, format, *args):
        pass

    def _respond(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass

    def _authorized(self):
        tokens = self.headers.get_all("Authorization", [])
        if len(tokens) != 1 or not hmac.compare_digest(tokens[0].encode("utf-8"), self.server.authorization):
            self._respond(401, {"version": 1, "error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._authorized():
            return
        if self.path == "/v1/health":
            self._respond(200, self.server.worker.health())
        else:
            self._respond(404, {"version": 1, "error": "not_found"})

    def _read_json(self):
        lengths = self.headers.get_all("Content-Length", [])
        if (self.headers.get_content_type() != "application/json" or len(lengths) != 1
                or self.headers.get("Transfer-Encoding") is not None or not lengths[0].isascii()
                or not lengths[0].isdecimal()):
            raise ValueError
        length = int(lengths[0])
        if not 0 < length <= MAX_HTTP_BYTES:
            raise ValueError
        data = self.rfile.read(length)
        if len(data) != length:
            raise ValueError
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)

    def do_POST(self):
        if not self._authorized():
            return
        worker = self.server.worker
        try:
            if self.path == "/v1/maintenance/start":
                payload = self._read_json()
                check_version(payload)
                if set(payload) != {"version"}:
                    raise ValueError
                result = worker.begin_maintenance()
            elif self.path in {"/v1/maintenance/finish", "/v1/maintenance/end"}:
                payload = self._read_json()
                check_version(payload)
                confirm = {key: payload.get(key, default) for key, default in
                           {"verify": True, "accountChanged": False, "abort": False}.items()}
                if set(payload) - confirm.keys() - {"version"} or any(type(value) is not bool for value in confirm.values()):
                    raise ValueError
                result = worker.end_maintenance(verify=confirm["verify"], account_changed=confirm["accountChanged"],
                                                abort=confirm["abort"])
            else:
                action = self.path.removeprefix("/v1/")
                if action not in {"prepare", "send", "status", "reconcile", "cancel"} or self.path != f"/v1/{action}":
                    self._respond(404, {"version": 1, "error": "not_found"})
                    return
                result = worker.perform(parse_request(self._read_json(), action), action)
            self._respond(200, result)
        except (ValueError, KeyError, AttributeError, TypeError, TimeoutError, RecursionError):
            self._respond(400, {"version": 1, "error": "invalid_request"})
        except OSError:
            self._respond(503, {"version": 1, "status": "unavailable", "ready": False})


def integer_env(name, default, lower, upper):
    value = int(os.getenv(name, str(default)))
    if not lower <= value <= upper:
        raise ValueError(f"invalid {name}")
    return value


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s")
    profile = Path(os.environ["DEEPSEEK_WEB_PROFILE_DIR"])
    private_directory(profile)
    firefox = os.getenv("DEEPSEEK_WEB_FIREFOX_BINARY", "/usr/bin/firefox-esr")
    geckodriver = os.getenv("DEEPSEEK_WEB_GECKODRIVER_BINARY", "/usr/local/bin/geckodriver")
    backend = os.getenv("DEEPSEEK_WEB_BACKEND", "browser")
    if backend == "api":
        from api_backend import APIBackend
        browser = APIBackend(
            profile, firefox=firefox, geckodriver=geckodriver,
            key=os.environ["DEEPSEEK_WEB_WORKER_TOKEN"],
            auth_path=os.environ["DEEPSEEK_WEB_AUTH_PATH"],
            port=integer_env("DEEPSEEK_WEB_API_PORT", 9655, 1, 65535),
            deepthink=os.getenv("DEEPSEEK_WEB_DEEPTHINK") == "1",
            refresh_seconds=integer_env("DEEPSEEK_WEB_AUTH_REFRESH_SECONDS", 21600, 0, 86400),
            generation_seconds=integer_env("DEEPSEEK_WEB_GENERATION_SECONDS", 480, 1, 540),
        )
    elif backend == "browser":
        browser = Browser(
            profile, firefox=firefox, geckodriver=geckodriver,
            deepthink=os.getenv("DEEPSEEK_WEB_DEEPTHINK") == "1",
            generation_seconds=integer_env("DEEPSEEK_WEB_GENERATION_SECONDS", 240, 1, 480),
        )
    else:
        raise SystemExit("Invalid DEEPSEEK_WEB_BACKEND (expected browser or api)")
    if any(not os.access(binary, os.X_OK) for binary in (browser.firefox, browser.geckodriver)):
        raise SystemExit("Firefox ESR or geckodriver is missing for interactive re-login")
    port = integer_env("DEEPSEEK_WEB_WORKER_PORT", 8765, 1, 65535)
    idle_seconds = (None if os.getenv("DEEPSEEK_WEB_IDLE_SECONDS") == "never" and backend == "browser"
                    else integer_env("DEEPSEEK_WEB_IDLE_SECONDS", 60, 0, 3600)
                    if os.getenv("DEEPSEEK_WEB_IDLE_SECONDS") != "never" else 60)
    worker = Worker(browser, idle_seconds=idle_seconds)
    server = Server(port, os.environ["DEEPSEEK_WEB_WORKER_TOKEN"], worker)

    def terminate(signum, frame):
        threading.Thread(target=server.shutdown, name="http-shutdown", daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, terminate)
    try:
        server.serve_forever(0.2)
    finally:
        server.server_close()
        worker.shutdown()


if __name__ == "__main__":
    main()
