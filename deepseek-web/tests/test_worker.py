from dataclasses import replace
from http.client import HTTPConnection
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import threading
import time
import unittest
from uuid import uuid4

from browser import Answer, BrowserFailure, Prepared, locked_profile
from worker import Request, Server, Worker, parse_request

TOKEN = "local-private-fixture-token"
TAIL = "v1:1:" + "a" * 64


class FakeBrowser:
    def __init__(self, profile):
        self.profile = profile
        self.session = None
        self.guard = None
        self.prepare_count = 0
        self.send_count = 0
        self.reconciles = []
        self.sending = threading.Event()
        self.release = threading.Event()
        self.closed = threading.Event()
        self.reject_login = False
        self.uncertain = False
        self.block_close = False
        self.allow_close = threading.Event()

    def verify(self, stop):
        self.guard = locked_profile(self.profile)
        self.guard.__enter__()
        self.session = object()
        if self.reject_login:
            raise BrowserFailure("loginRequired")

    def prepare(self, request, stop):
        if self.session is None:
            self.verify(stop)
        self.prepare_count += 1
        return Prepared(request.remote_id, request.tail, 0)

    def send(self, request, prepared, stop, progress):
        self.send_count += 1
        progress("new-chat", True)
        self.sending.set()
        while not self.release.wait(0.02):
            if stop.is_set():
                raise BrowserFailure("uncertain", True, "new-chat", may_have_sent=True)
        if self.uncertain:
            raise BrowserFailure("uncertain", True, "new-chat", may_have_sent=True)
        return Answer("new-chat", TAIL, request.prompt)

    def reconcile(self, request, stop, progress):
        self.reconciles.append(request.remote_id)
        return Answer(request.remote_id, TAIL, request.prompt)

    def close(self):
        if self.block_close:
            self.allow_close.wait(3)
        if self.session:
            self.guard.__exit__(None, None, None)
            self.guard = None
            self.session = None
        self.closed.set()


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.profile = Path(self.enterContext(TemporaryDirectory()))
        self.browser = FakeBrowser(self.profile)
        self.worker = Worker(self.browser, idle_seconds=0.1, prepared_ttl=0.3)
        self.addCleanup(self.worker.shutdown)
        self.request = Request(uuid4(), uuid4(), None, None, None, "Первая строка\n👋 вторая")

    def test_split_operation_and_idempotency(self):
        self.assertEqual(self.worker.perform(self.request, "send")["status"], "notAccepted")
        self.assertEqual(self.worker.perform(replace(self.request, prompt=None), "prepare")["status"], "prepared")
        self.assertEqual(self.worker.perform(self.request, "status")["status"], "prepared")
        self.browser.release.set()
        response = self.worker.perform(self.request, "send")
        self.assertEqual(response["text"], self.request.prompt)
        self.assertEqual(self.worker.perform(self.request, "send"), response)
        self.assertEqual(self.worker.perform(self.request, "reconcile"), response)
        self.assertEqual(self.browser.send_count, 1)
        self.assertEqual(self.browser.reconciles, [])
        changed = replace(self.request, prompt="changed")
        self.assertEqual(self.worker.perform(changed, "send")["status"], "notAccepted")
        self.assertTrue(self.browser.closed.wait(2))

    def test_cancel_holds_browser_until_cleanup(self):
        other = replace(self.request, id=uuid4())
        self.browser.block_close = True
        self.assertEqual(self.worker.perform(self.request, "prepare")["status"], "prepared")
        running = threading.Thread(target=self.worker.perform, args=(self.request, "send"))
        running.start()
        self.addCleanup(running.join, 5)
        self.addCleanup(self.browser.allow_close.set)
        self.assertTrue(self.browser.sending.wait(2))
        status = self.worker.perform(self.request, "reconcile")
        self.assertEqual(status["status"], "inProgress")
        self.assertTrue(status["accepted"])
        self.assertEqual(status["remoteChatID"], "new-chat")
        self.assertEqual(self.worker.perform(self.request, "cancel")["status"], "inProgress")
        self.assertEqual(self.worker.perform(other, "prepare")["status"], "busy")
        self.browser.allow_close.set()
        running.join(3)
        self.assertFalse(running.is_alive())
        self.assertEqual(self.worker.perform(self.request, "status")["status"], "uncertain")
        self.assertEqual(self.worker.perform(other, "prepare")["status"], "prepared")

    def test_uncertain_new_dialog_reconciles_known_candidate_without_send(self):
        self.browser.uncertain = True
        self.browser.release.set()
        self.worker.perform(self.request, "prepare")
        response = self.worker.perform(self.request, "send")
        self.assertEqual(response["status"], "uncertain")
        self.assertTrue(response["mayHaveSent"])
        self.assertEqual(self.worker.perform(self.request, "reconcile")["status"], "completed")
        self.assertEqual(self.browser.reconciles, ["new-chat"])
        self.assertEqual(self.browser.send_count, 1)

    def test_new_chat_reconcile_uses_durable_candidate_after_worker_restart(self):
        candidate = replace(self.request, candidate_id="known-after-restart")
        response = self.worker.perform(candidate, "reconcile")
        self.assertEqual(response["status"], "completed")
        self.assertEqual(response["remoteChatID"], "known-after-restart")
        self.assertEqual(self.browser.reconciles, ["known-after-restart"])
        self.assertEqual(self.browser.send_count, 0)

    def test_account_change_fences_old_marker_and_releases_profile(self):
        self.worker.perform(self.request, "prepare")
        with self.assertRaises(BlockingIOError):
            with locked_profile(self.profile):
                self.fail("profile was concurrently acquired")

        self.assertEqual(self.worker.begin_maintenance()["status"], "maintenance")
        self.assertEqual(self.worker.health()["status"], "maintenance")
        with locked_profile(self.profile):
            self.assertEqual(
                self.worker.end_maintenance(verify=True, account_changed=True, abort=False)["status"], "busy"
            )

        response = self.worker.end_maintenance(verify=True, account_changed=True, abort=False)
        self.assertEqual(response["status"], "ready")
        self.assertEqual(self.worker.health()["accountMarker"], response["accountMarker"])
        self.assertEqual(self.worker.perform(self.request, "prepare")["status"], "notAccepted")
        self.worker.shutdown()

        restarted = Worker(self.browser)
        self.addCleanup(restarted.shutdown)
        self.assertEqual(restarted.health()["accountMarker"], response["accountMarker"])

    def test_expired_login_persists_gate_and_prepared_lease_expires(self):
        self.assertEqual(self.worker.perform(self.request, "prepare")["status"], "prepared")
        time.sleep(0.35)
        self.assertEqual(self.worker.perform(self.request, "send")["status"], "cancelled")
        self.browser.reject_login = True
        self.assertEqual(self.worker.begin_maintenance()["status"], "maintenance")
        response = self.worker.end_maintenance(verify=True, account_changed=False, abort=False)
        self.assertEqual(response["status"], "loginRequired")
        self.worker.shutdown()
        restarted = Worker(self.browser)
        self.addCleanup(restarted.shutdown)
        self.assertEqual(restarted.health()["status"], "maintenance")

    def test_parse_swift_uuid_and_rejects_path_or_prompt_injection(self):
        data = {"version": 1, "operationID": str(self.request.id).upper(),
                "accountEpoch": str(self.request.account_epoch).upper(), "prompt": self.request.prompt}
        self.assertEqual(parse_request(data, "send"), self.request)
        for field in ("a/b", "../../x", "?mode=foo", "%2f"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                parse_request(dict(data, remoteChatID=field, remoteTail=TAIL), "send")
        conflict = dict(data, remoteChatID="existing-a", remoteTail=TAIL, candidateRemoteChatID="existing-b")
        with self.assertRaises(ValueError):
            parse_request(conflict, "reconcile")
        data["prompt"] = "\x00"
        with self.assertRaises(ValueError):
            parse_request(data, "send")


class HTTPTest(unittest.TestCase):
    def setUp(self):
        profile = Path(self.enterContext(TemporaryDirectory()))
        self.browser = FakeBrowser(profile)
        self.worker = Worker(self.browser)
        self.server = Server(0, TOKEN, self.worker)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.worker.shutdown)
        self.addCleanup(self.thread.join, 4)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.payload = {"version": 1, "operationID": str(uuid4()), "accountEpoch": str(uuid4())}

    def connection(self):
        return HTTPConnection("127.0.0.1", self.server.server_port, timeout=4)

    def request(self, path, body=None, *, token=TOKEN):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        client = self.connection()
        try:
            if body is not None:
                headers["Content-Type"] = "application/json"
                client.request("POST", path, json.dumps(body).encode(), headers)
            else:
                client.request("GET", path, headers=headers)
            response = client.getresponse()
            return response.status, json.loads(response.read())
        finally:
            client.close()

    def test_authorization_and_schema(self):
        self.assertEqual(self.request("/v1/health", token=None)[0], 401)
        self.assertEqual(self.request("/v1/health", token="wrong")[0], 401)
        self.assertEqual(self.request("/v1/health")[1], {"version": 1, "status": "ready", "ready": True})
        self.assertEqual(self.request("/v1/prepare", {"version": 1})[0], 400)
        self.assertEqual(self.request("/v1/prepare", self.payload)[1]["status"], "prepared")
        self.assertEqual(self.request("/v1/prepare", dict(self.payload, operationID=str(uuid4())))[1]["status"], "busy")
        self.assertEqual(self.request("/v1/cancel", self.payload)[1]["status"], "cancelled")

    def test_client_disconnect_preserves_operation_ownership_and_result(self):
        self.assertEqual(self.request("/v1/prepare", self.payload)[1]["status"], "prepared")
        task = dict(self.payload, prompt="final")
        client = self.connection()
        client.request("POST", "/v1/send", json.dumps(task).encode(),
                       headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
        self.assertTrue(self.browser.sending.wait(2))
        client.close()
        self.assertEqual(self.request("/v1/status", task)[1]["status"], "inProgress")
        self.assertEqual(self.request("/v1/prepare", dict(self.payload, operationID=str(uuid4())))[1]["status"], "busy")
        self.browser.release.set()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = self.request("/v1/status", task)[1]
            if result["status"] == "completed":
                break
            time.sleep(0.01)
        self.assertEqual(result["text"], "final")
        self.assertEqual(self.request("/v1/send", task)[1], result)
        self.assertEqual(self.browser.send_count, 1)
