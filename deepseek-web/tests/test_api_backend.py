"""Safety/continuation regression tests for the browserless DeepSeek transport."""

from dataclasses import replace
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

from api_backend import APIBackend
from browser import BrowserFailure
from worker import Request


class FakeReply:
    status = 200

    def __init__(self, content):
        self.content = content

    def read(self, size):
        return json.dumps({"choices": [{"message": {"content": self.content}}]}).encode()

    def getheader(self, name):
        return None


class FakeConnection:
    sent = []
    response = FakeReply("Ответ")
    failure = None

    def __init__(self, *_a, **_kw):
        pass

    def request(self, method, path, body=None, headers=None):
        self.sent.append((method, path, json.loads(body), headers))
        if self.failure:
            raise self.failure

    def getresponse(self):
        return self.response

    def close(self):
        pass


class APIBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "profile").mkdir(mode=0o700)
        self.backend = APIBackend(root / "profile", key="local-worker-key", port=9655,
                                  auth_path=root / "auth.json", firefox="/bin/false", geckodriver="/bin/false",
                                  refresh_seconds=0)
        self.backend.ready = lambda: "ready"
        self.stop = threading.Event()
        FakeConnection.sent = []
        FakeConnection.failure = None
        FakeConnection.response = FakeReply("Ответ")
        self.patcher = patch("api_backend.HTTPConnection", FakeConnection)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.marker = uuid4()

    def request(self, remote=None, tail=None, prompt="Вопрос", op=None):
        return Request(op or uuid4(), uuid4(), self.marker, remote, tail, prompt)

    def test_model_matches_search_and_deep_think(self):
        for think, search, model in (
            (False, None, "deepseek-v4-flash"),
            (True, True, "deepseek-v4-flash-thinking"),
            (False, False, "deepseek-v4-flash-nosearch"),
            (True, False, "deepseek-v4-flash-thinking-nosearch"),
        ):
            with self.subTest(think=think, search=search):
                request = replace(self.request(), deep_think=think, web_search=search)
                prepared = self.backend.prepare(request, self.stop)
                self.backend.send(request, prepared, self.stop, lambda *_: None)
                self.assertEqual(FakeConnection.sent[-1][2]["model"], model)

    def test_independent_sessions_and_continuation_after_restart(self):
        request1 = self.request()
        prepared1 = self.backend.prepare(request1, self.stop)
        answer1 = self.backend.send(request1, prepared1, self.stop, lambda *_: None)
        request2 = self.request(prompt="Другой вопрос")
        prepared2 = self.backend.prepare(request2, self.stop)
        answer2 = self.backend.send(request2, prepared2, self.stop, lambda *_: None)
        self.assertNotEqual(answer1.remote_id, answer2.remote_id)
        self.assertNotEqual(answer1.tail, answer2.tail)
        self.assertEqual(FakeConnection.sent[0][3]["x-agent-session"], answer1.remote_id)
        self.assertEqual(FakeConnection.sent[1][3]["x-agent-session"], answer2.remote_id)

        restarted = APIBackend(self.backend.profile, key="local-worker-key", port=9655,
                               auth_path=self.backend.auth_path, firefox="/bin/false", geckodriver="/bin/false",
                               refresh_seconds=0)
        restarted.ready = lambda: "ready"
        request3 = self.request(remote=answer1.remote_id, tail=answer1.tail, prompt="Продолжение")
        prepared3 = restarted.prepare(request3, self.stop)
        answer3 = restarted.send(request3, prepared3, self.stop, lambda *_: None)
        self.assertEqual(answer3.remote_id, answer1.remote_id)
        transcript = FakeConnection.sent[-1][2]["messages"]
        self.assertEqual([t["role"] for t in transcript], ["user", "assistant", "user"])
        self.assertEqual(transcript[0]["content"], "Вопрос")
        self.assertEqual(transcript[-1]["content"], "Продолжение")
        self.assertTrue(answer3.tail.startswith("v1:2:"))

    def test_unknown_maybe_sent_request_is_not_replayed(self):
        request = self.request()
        prepared = self.backend.prepare(request, self.stop)
        FakeConnection.failure = ConnectionResetError("lost after dispatch")
        with self.assertRaises(BrowserFailure) as error:
            self.backend.send(request, prepared, self.stop, lambda *_: None)
        self.assertEqual(error.exception.status, "uncertain")
        self.assertTrue(error.exception.may_have_sent)
        with self.assertRaises(BrowserFailure) as error2:
            self.backend.reconcile(self.request(remote=prepared.remote_id, prompt=request.prompt),
                                   self.stop, lambda *_: None)
        self.assertEqual(error2.exception.status, "uncertain")
        self.assertEqual(len(FakeConnection.sent), 1)
        with self.assertRaises(BrowserFailure):
            self.backend.prepare(self.request(remote=prepared.remote_id), self.stop)

    def test_reconciliation_from_durable_success(self):
        request = self.request()
        prepared = self.backend.prepare(request, self.stop)
        answer = self.backend.send(request, prepared, self.stop, lambda *_: None)
        probe = self.request(remote=answer.remote_id, prompt=request.prompt)
        result = self.backend.reconcile(probe, self.stop, lambda *_: None)
        self.assertEqual(result, answer)
        self.assertEqual(len(FakeConnection.sent), 1)

    def test_tail_mismatch_and_unrecognized_old_browser_chat_rejected(self):
        request = self.request()
        prepared = self.backend.prepare(request, self.stop)
        answer = self.backend.send(request, prepared, self.stop, lambda *_: None)
        with self.assertRaises(BrowserFailure) as error:
            self.backend.prepare(self.request(remote=answer.remote_id, tail="v1:1:" + "a" * 64), self.stop)
        self.assertEqual(error.exception.status, "chatUnavailable")
        with self.assertRaises(BrowserFailure):
            self.backend.prepare(self.request(remote="legacy_browser_chat_id", tail=answer.tail), self.stop)

    def test_auth_required_is_fail_closed_and_does_not_send(self):
        self.backend.ready = lambda: "loginRequired"
        with self.assertRaises(BrowserFailure) as error:
            self.backend.prepare(self.request(), self.stop)
        self.assertEqual(error.exception.status, "loginRequired")
        self.assertFalse(FakeConnection.sent)


if __name__ == "__main__":
    unittest.main()
