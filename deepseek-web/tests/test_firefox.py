from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import threading
import unittest
from uuid import uuid4

from browser import DEEPTHINK, Browser, BrowserFailure
from worker import Request

FIREFOX = os.getenv("DEEPSEEK_WEB_TEST_FIREFOX")
GECKODRIVER = os.getenv("DEEPSEEK_WEB_TEST_GECKODRIVER")
FIXTURE = Path(__file__).parent.joinpath("fixtures/deepseek.html").read_text()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        data = FIXTURE.replace("__FIXTURE_MODE__", json.dumps(self.server.mode)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


@unittest.skipUnless(FIREFOX and GECKODRIVER, "set test Firefox and geckodriver paths")
class FirefoxTest(unittest.TestCase):
    def setUp(self):
        self.site = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        self.site.mode = "normal"
        server = threading.Thread(target=self.site.serve_forever, daemon=True)
        server.start()
        self.addCleanup(server.join, 3)
        self.addCleanup(self.site.server_close)
        self.addCleanup(self.site.shutdown)

        self.profile = Path(self.enterContext(TemporaryDirectory()))
        self.browser = Browser(
            self.profile, home=f"http://127.0.0.1:{self.site.server_port}/",
            firefox=FIREFOX, geckodriver=GECKODRIVER,
            prepare_seconds=5, generation_seconds=1.7,
        )
        self.addCleanup(self.browser.close)
        self.stop = threading.Event()
        self.epoch = uuid4()
        self.progress = []

    def request(self, prompt, previous=None):
        return Request(uuid4(), self.epoch, None, previous.remote_id if previous else None,
                       previous.tail if previous else None, prompt)

    def track(self, remote_id, accepted, text=None):
        self.progress.append((remote_id, accepted, text))

    def run_turn(self, request):
        preparation = self.browser.prepare(request, self.stop)
        return self.browser.send(request, preparation, self.stop, self.track)

    def test_topics_restart_reconcile_and_final_format(self):
        first = self.run_turn(self.request("A formatted 😀\nКириллица"))
        self.assertIn(" / 1 / A formatted 😀\nКириллица", first.text)
        self.assertIn("Rate limit: try again in 10 minutes", first.text)
        self.assertIn("- one\n- two", first.text)
        self.assertIn("if x < 2:\n    x & y", first.text)
        self.assertNotIn("Reasoning is never", first.text)
        self.assertNotIn("Copy code label", first.text)

        rotated = self.run_turn(self.request("B"))
        self.assertNotEqual(rotated.remote_id, first.remote_id)
        self.assertIn(" / 1 / B", rotated.text)
        self.browser.close()

        second_request = self.request("A2", first)
        second = self.run_turn(second_request)
        self.assertEqual(second.remote_id, first.remote_id)
        self.assertIn(" / 2 / A2", second.text)
        self.assertNotIn(" / 1 / A formatted", second.text)
        self.assertTrue(self.progress[-1][1])

        self.browser.close()
        same = self.browser.reconcile(second_request, self.stop, self.track)
        self.assertEqual(second, same)
        third = self.run_turn(self.request("A3", same))
        self.assertIn(" / 3 / A3", third.text)

    def test_native_composer_submits_without_labeled_send(self):
        for mode in ("keyboard-submit", "native-submit"):
            with self.subTest(mode=mode):
                self.site.mode = mode
                answer = self.run_turn(self.request("synthetic input"))
                self.assertTrue(answer.text.endswith(" / 1 / synthetic input"))

    def test_reports_growing_answer_before_completion(self):
        self.site.mode = "streaming"
        answer = self.run_turn(self.request("stream this"))
        partials = {text for remote_id, accepted, text in self.progress
                    if remote_id == answer.remote_id and accepted and text}
        self.assertEqual(partials, {"First fragment", "First fragment < & next"})
        self.assertTrue(answer.text.endswith(" / 1 / stream this"))

    def test_deep_think_overrides_worker_default_per_turn(self):
        previous = None
        for choice, default, expected in ((False, True, False), (True, False, True), (None, True, True)):
            with self.subTest(choice=choice, default=default):
                self.browser.deepthink = default
                request = replace(self.request("synthetic input", previous), deep_think=choice)
                previous = self.run_turn(request)
                toggle, = self.browser._read_toggles(self.browser.session[0], DEEPTHINK)
                self.assertIs(toggle["selected"], expected)

    def test_deep_think_change_after_prepare_is_rejected_before_send(self):
        request = replace(self.request("synthetic input"), deep_think=True)
        prepared = self.browser.prepare(request, self.stop)
        toggle, = self.browser._read_toggles(self.browser.session[0], DEEPTHINK)
        toggle["button"].click()
        with self.assertRaises(BrowserFailure) as error:
            self.browser.send(request, prepared, self.stop, self.track)
        self.assertEqual(error.exception.status, "unknownUI")
        self.assertFalse(error.exception.may_have_sent)
        self.assertEqual(self.progress, [])

    def test_refusals_and_unknown_ui(self):
        for mode, expected in (
            ("login", "loginRequired"),
            ("unknown-dialog", "unavailable"),
            ("unexpected-url", "unknownUI"),
            ("old-home", "unknownUI"),
            ("draft", "unknownUI"),
            ("before-click", "unknownUI"),
            ("native-disabled", "unknownUI"),
            ("native-ambiguous", "unknownUI"),
            ("low-limit", "inputTooLong"),
            ("busy", "busy"),
            ("quota", "quota"),
        ):
            with self.subTest(mode=mode), self.assertRaises(BrowserFailure) as exception:
                self.site.mode = mode
                self.run_turn(self.request("synthetic input"))
            self.assertEqual(exception.exception.status, expected)
            self.assertFalse(exception.exception.accepted)
            self.assertFalse(exception.exception.may_have_sent)
            if mode == "quota":
                self.assertEqual(exception.exception.retry_after, 600)

    def test_conflicting_conversation_and_uncertain_click(self):
        first = self.run_turn(self.request("A"))
        other = self.request("B")
        self.site.mode = "send-lost"
        with self.assertRaises(BrowserFailure) as error:
            self.run_turn(other)
        self.assertEqual(error.exception.status, "uncertain")
        self.assertFalse(error.exception.accepted)
        self.assertTrue(error.exception.may_have_sent)

        self.site.mode = "stalled"
        with self.assertRaises(BrowserFailure) as error:
            self.run_turn(self.request("A2", first))
        self.assertEqual(error.exception.status, "uncertain")
        self.assertTrue(error.exception.accepted)
        self.assertEqual(error.exception.remote_id, first.remote_id)

        self.site.mode = "normal"
        bad_request = replace(self.request("Different", first), remote_id="old-b")
        with self.assertRaises(BrowserFailure) as error:
            self.browser.prepare(bad_request, self.stop)
        self.assertEqual(error.exception.status, "chatUnavailable")
        missing_request = replace(bad_request, remote_id="deleted-chat")
        with self.assertRaises(BrowserFailure) as error:
            self.browser.prepare(missing_request, self.stop)
        self.assertEqual(error.exception.status, "chatUnavailable")
