"""HTTP-only DeepSeek Web transport, compatible with the existing worker contract.

The proxy owns the upstream session and credentials. A durable local turn journal
makes independent Telegram chats recoverable after an API-proxy process restart.
Unknown outcomes are NEVER retried automatically: a single request may have
committed upstream even if the HTTP connection died before the reply arrived.
"""

from dataclasses import dataclass
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import re
import socket
import stat
import tempfile
import threading
import time
from uuid import uuid4

from browser import Answer, Browser, BrowserFailure, CHAT_ID, Prepared, tail_for, private_directory

MAX_REPLY_BYTES = 64_000
MAX_JSON_BYTES = 256_000
MAX_TURNS = 130


class APIBackend:
    is_api = True

    def __init__(self, profile, *, port=9655, key, auth_path, firefox, geckodriver,
                 refresh_seconds=21600, deepthink=False, generation_seconds=480):
        self.profile = Path(profile)
        self.data_dir = self.profile.parent / "api-chats"
        self.data_dir.mkdir(mode=0o700, exist_ok=True)
        private_directory(self.data_dir)
        self.auth_path = Path(auth_path)
        self.port = port
        self.key = key
        self.firefox = firefox
        self.geckodriver = geckodriver
        self.deepthink = deepthink
        self.generation_seconds = generation_seconds
        self.session = None   # Never keep Firefox running between requests.
        self.refresh_seconds = refresh_seconds
        self.next_refresh = time.monotonic() + refresh_seconds if refresh_seconds else float("inf")
        self._lock = threading.RLock()

    def close(self):
        # No browser or HTTP connection is kept open by the API adapter.
        self.session = None

    def _request(self, method, path, payload=None, timeout=3, agent_id=None):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        headers = {"Authorization": "Bearer " + self.key, "Content-Type": "application/json"}
        if agent_id is not None:
            headers["x-agent-session"] = agent_id
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) if payload is not None else None
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                raise ValueError("proxy_response_too_large")
            try:
                data = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError) as error:
                raise ValueError("invalid_proxy_response") from error
            return response.status, data, response.getheader("Retry-After")
        finally:
            connection.close()

    def ready(self):
        try:
            status, data, _ = self._request("GET", "/health", timeout=1)
            if status != 200 or not isinstance(data, dict) or data.get("service") != "FreeDeepseekAPI":
                return "unavailable"
            return "ready" if data.get("config_ready") else "loginRequired"
        except (OSError, HTTPException, ValueError):
            return "unavailable"

    def _filename(self, chat_id):
        if not CHAT_ID.fullmatch(chat_id):
            raise BrowserFailure("chatUnavailable")
        return self.data_dir / (chat_id + ".json")

    @staticmethod
    def _write(path, data):
        # Exclusive temporary creation prevents following a pre-existing symlink.
        fd, tmp = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as file:
                json.dump(data, file, ensure_ascii=False, separators=(",", ":"))
                file.flush()
                os.fsync(file.fileno())
            os.replace(tmp, path)
            dirfd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def _load(self, chat_id):
        path = self._filename(chat_id)
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
                raise OSError("insecure_chat_journal")
            with path.open(encoding="utf-8") as file:
                data = json.load(file)
        except FileNotFoundError:
            raise BrowserFailure("chatUnavailable") from None
        except (OSError, ValueError):
            raise BrowserFailure("chatUnavailable") from None
        if (not isinstance(data, dict) or data.get("version") != 1 or data.get("id") != chat_id
                or not isinstance(data.get("turns"), list) or len(data["turns"]) > MAX_TURNS * 2):
            raise BrowserFailure("chatUnavailable")
        return data

    def _tail(self, record):
        return tail_for(record["turns"])

    def prepare(self, request, stop):
        if stop.is_set():
            raise BrowserFailure("cancelled")
        if self.ready() == "loginRequired":
            raise BrowserFailure("loginRequired")
        if self.ready() != "ready":
            raise BrowserFailure("unavailable")
        with self._lock:
            if request.remote_id is None:
                chat_id = uuid4().hex
                record = {"version": 1, "id": chat_id, "turns": [], "pending": None}
                self._write(self._filename(chat_id), record)
            else:
                chat_id = request.remote_id
                record = self._load(chat_id)
                if self._tail(record) != request.tail or record.get("pending") is not None:
                    raise BrowserFailure("chatUnavailable")
            return Prepared(chat_id, request.tail, len(record["turns"]), tuple(record["turns"]))

    def send(self, request, prepared, stop, progress):
        if stop.is_set():
            raise BrowserFailure("cancelled")
        chat_id = prepared.remote_id
        with self._lock:
            record = self._load(chat_id)
            if self._tail(record) != prepared.tail or record.get("pending") is not None:
                raise BrowserFailure("chatUnavailable")
            # Durable BEFORE dispatch: after a crash, a missing response is uncertain.
            record["pending"] = {"operation": str(request.id), "prompt": request.prompt}
            self._write(self._filename(chat_id), record)
            messages = [
                {"role": turn["role"], "content": turn["text"]}
                for turn in record["turns"]
            ] + [{"role": "user", "content": request.prompt}]
        model = "deepseek-v4-flash-thinking-nosearch" if (
            self.deepthink if request.deep_think is None else request.deep_think
        ) else "deepseek-v4-flash-nosearch"
        payload = {"model": model, "messages": messages, "stream": False}
        if stop.is_set():
            # The journal says pending; no remote request was dispatched.
            self._discard_pending(chat_id, request.id)
            raise BrowserFailure("cancelled")
        try:
            # Keep separate dispatch and reply phases, so observers see mayHaveSent
            # only after the request has been handed to the local HTTP transport.
            connection = HTTPConnection("127.0.0.1", self.port, timeout=self.generation_seconds)
            headers = {"Authorization": "Bearer " + self.key, "Content-Type": "application/json",
                       "x-agent-session": chat_id}
            try:
                connection.request("POST", "/v1/chat/completions",
                                   body=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers=headers)
                progress(chat_id, True, None)
                response = connection.getresponse()
                raw = response.read(MAX_JSON_BYTES + 1)
                status = response.status
                retry_after = response.getheader("Retry-After")
            finally:
                connection.close()
            if len(raw) > MAX_JSON_BYTES:
                raise ValueError("proxy_response_too_large")
            body = json.loads(raw.decode("utf-8"))
        except (OSError, HTTPException, UnicodeDecodeError, ValueError, socket.timeout) as error:
            raise BrowserFailure("uncertain", True, chat_id, may_have_sent=True) from None

        if status != 200:
            reason = body.get("error") or {} if isinstance(body, dict) else {}
            code = reason.get("type", "") if isinstance(reason, dict) else ""
            retry = int(retry_after) if retry_after and retry_after.isdecimal() else None
            if status in (401, 403) or code in ("auth_error", "authentication_error", "account_unauthorized"):
                raise BrowserFailure("loginRequired", False, chat_id, retry, True)
            if status == 429 or code in ("rate_limit", "rate_limit_error", "rate_limited"):
                raise BrowserFailure("quota", False, chat_id, retry, True)
            if status == 503 or code in ("account_busy", "account_unavailable"):
                raise BrowserFailure("busy", False, chat_id, retry, True)
            raise BrowserFailure("uncertain", True, chat_id, may_have_sent=True)
        try:
            choices = body["choices"]
            text = choices[0]["message"]["content"]
            if (not isinstance(text, str) or not text.strip() or len(text.encode("utf-8")) > MAX_REPLY_BYTES):
                raise ValueError("invalid_response_text")
        except (KeyError, IndexError, TypeError, ValueError):
            raise BrowserFailure("uncertain", True, chat_id, may_have_sent=True) from None
        with self._lock:
            record = self._load(chat_id)
            pending = record.get("pending") or {}
            if pending.get("operation") != str(request.id) or pending.get("prompt") != request.prompt:
                raise BrowserFailure("uncertain", True, chat_id, may_have_sent=True)
            ordinal = len(record["turns"]) // 2
            record["turns"].extend((
                {"role": "user", "id": f"u{ordinal}", "text": request.prompt, "complete": True},
                {"role": "assistant", "id": f"a{ordinal}", "text": text, "complete": True},
            ))
            record["pending"] = None
            self._write(self._filename(chat_id), record)
        return Answer(chat_id, self._tail(record), text)

    def _discard_pending(self, chat_id, operation_id):
        with self._lock:
            try:
                record = self._load(chat_id)
            except BrowserFailure:
                return
            if (record.get("pending") or {}).get("operation") == str(operation_id):
                record["pending"] = None
                self._write(self._filename(chat_id), record)

    def reconcile(self, request, stop, progress):
        if stop.is_set():
            raise BrowserFailure("cancelled")
        if not request.remote_id:
            raise BrowserFailure("uncertain")
        record = self._load(request.remote_id)
        turns = record["turns"]
        expected = len(turns) - 2
        if (expected >= 0 and turns[-2]["role"] == "user" and turns[-2]["text"] == request.prompt
                and (tail_for(turns[:expected]) == request.tail)):
            progress(request.remote_id, True, turns[-1]["text"])
            return Answer(request.remote_id, self._tail(record), turns[-1]["text"])
        # Never retry a maybe-sent prompt after interruption, even if the
        # journal only contains the pre-dispatch checkpoint.
        raise BrowserFailure("uncertain", may_have_sent=True, remote_id=request.remote_id)

    @staticmethod
    def _normalize_token(value):
        if not value:
            return ""
        if isinstance(value, str):
            try:
                parsed = json.loads(value)
                if isinstance(parsed, dict):
                    return str(parsed.get("value") or parsed.get("token") or parsed.get("access_token") or "")
            except ValueError:
                pass
            return value.strip()
        if isinstance(value, dict):
            return str(value.get("value") or value.get("token") or value.get("access_token") or "")
        return ""

    def verify(self, stop):
        """Refresh local auth from the saved Firefox login; invoked only on
        manual maintenance finish or on a low-frequency scheduled refresh.
        No credentials are returned to the caller or printed in logs.
        """
        if stop.is_set():
            raise BrowserFailure("cancelled")
        browser = Browser(self.profile, firefox=self.firefox, geckodriver=self.geckodriver,
                          deepthink=self.deepthink, prepare_seconds=30)
        try:
            browser.verify(stop)
            driver = browser.session[0]
            stores = driver.execute_script("""
                const out = {};
                for (const store of [localStorage, sessionStorage]) {
                    for (let i = 0; i < store.length; i++) {
                        const key = store.key(i);
                        if (/token/i.test(key)) out[key] = store.getItem(key);
                    }
                }
                return out;
            """) or {}
            token = ""
            for key in ("userToken", "token", "auth_token", "access_token", "accessToken"):
                token = self._normalize_token(stores.get(key))
                if token:
                    break
            if not token:
                for key, value in stores.items():
                    token = self._normalize_token(value)
                    if token:
                        break
            cookies = driver.get_cookies()
            cookie = "; ".join(c["name"] + "=" + c["value"] for c in cookies
                               if c.get("name") and c.get("value"))
            if not token or not cookie:
                raise BrowserFailure("loginRequired")
            current = {}
            if self.auth_path.exists():
                with self.auth_path.open(encoding="utf-8") as file:
                    current = json.load(file)
            current.update({"token": token, "cookie": cookie})
            current.setdefault("baseUrl", "https://chat.deepseek.com")
            self.auth_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            self._write(self.auth_path, current)
            status, _, _ = self._request("POST", "/admin/accounts/reload", payload={}, timeout=8)
            if status != 200:
                raise BrowserFailure("unavailable")
        finally:
            browser.close()
            self.next_refresh = time.monotonic() + self.refresh_seconds if self.refresh_seconds else float("inf")
