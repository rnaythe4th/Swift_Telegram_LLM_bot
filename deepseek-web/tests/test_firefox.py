from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import threading
from time import monotonic
import unittest
from unittest.mock import patch
from uuid import uuid4

from browser import DEEPTHINK, SEARCH, Browser, BrowserFailure
from worker import Request

FIREFOX = os.getenv("DEEPSEEK_WEB_TEST_FIREFOX")
GECKODRIVER = os.getenv("DEEPSEEK_WEB_TEST_GECKODRIVER")
FIXTURE = Path(__file__).parent.joinpath("fixtures/deepseek.html").read_text()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.server.home_loads += 1
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
        self.site.home_loads = 0
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

    def test_reuses_verified_home_after_navigation_timeout(self):
        from selenium.common.exceptions import TimeoutException

        driver = self.browser._open()
        load = driver.get

        def loaded_with_timeout(url):
            load(url)
            raise TimeoutException()

        with patch.object(driver, "get", side_effect=loaded_with_timeout) as get:
            self.browser.verify(self.stop)
            answer = self.run_turn(self.request("synthetic input"))
        get.assert_called_once_with(self.browser.home)
        self.assertIn(" / 1 / synthetic input", answer.text)

    def test_intercepted_click_recovers_without_duplicate_send(self):
        self.site.mode = "intercept-once"
        answer = self.run_turn(self.request("synthetic input"))
        self.assertIn(" / 1 / synthetic input", answer.text)
        self.assertEqual(self.site.home_loads, 2)

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

    def test_followups_and_reconciliation_with_unmounted_messages(self):
        self.site.mode = "virtualized"
        first = self.run_turn(replace(self.request("first group message"), deep_think=True))
        second = self.run_turn(replace(self.request("follow-up", first), deep_think=True))
        self.assertEqual(second.remote_id, first.remote_id)
        self.assertIn(" / 2 / follow-up", second.text)
        self.assertEqual(len(self.browser._read(self.browser.session[0])["turns"]), 3)

        driver = self.browser.session[0]
        driver.execute_script("document.querySelector('.ds-virtual-list').style.height = '170px'")
        third_request = replace(self.request("without DeepThink", second), deep_think=False)
        third = self.run_turn(third_request)
        self.assertEqual(third.remote_id, first.remote_id)
        self.assertIn(" / 3 / without DeepThink", third.text)

        self.browser.close()
        self.assertEqual(self.browser.reconcile(third_request, self.stop, self.track), third)
        fourth = self.run_turn(self.request("after reopening", third))
        self.assertIn(" / 4 / after reopening", fourth.text)

    def test_native_composer_submits_without_labeled_send(self):
        for mode in ("keyboard-submit", "native-submit"):
            with self.subTest(mode=mode):
                self.site.mode = mode
                answer = self.run_turn(self.request("synthetic input"))
                self.assertTrue(answer.text.endswith(" / 1 / synthetic input"))

    def test_reports_growing_answer_before_completion(self):
        self.site.mode = "streaming"
        self.browser.generation_seconds = 5
        request = self.request("stream this")
        prepared = self.browser.prepare(request, self.stop)

        def advance(remote_id, accepted, text):
            if remote_id and accepted and text:
                self.track(remote_id, accepted, text)
                self.browser.session[0].execute_script("window.advanceStream()")

        answer = self.browser.send(request, prepared, self.stop, advance)
        self.assertEqual(self.progress, [(answer.remote_id, True, "First fragment"),
                                         (answer.remote_id, True, "First fragment < & next")])
        self.assertTrue(answer.text.endswith(" / 1 / stream this"))

    def test_toggles_follow_each_turn(self):
        previous = None
        for think, default, expected_think, search, expected_search in (
            (False, True, False, None, True),
            (True, False, True, False, False),
            (None, True, True, True, True),
        ):
            with self.subTest(think=think, default=default, search=search):
                self.browser.deepthink = default
                request = replace(self.request("synthetic input", previous), deep_think=think, web_search=search)
                previous = self.run_turn(request)
                driver = self.browser.session[0]
                think_toggle, search_toggle = self.browser._read_toggles(driver, DEEPTHINK, SEARCH)
                self.assertIs(think_toggle["selected"], expected_think)
                self.assertIs(search_toggle["selected"], expected_search)
                self.assertEqual(driver.execute_script("return sessionStorage.submittedSearch"),
                                 "true" if expected_search else "false")

    def test_toggle_change_after_prepare_is_rejected_before_send(self):
        for names in (DEEPTHINK, SEARCH):
            with self.subTest(toggle=names[0]):
                request = replace(self.request("synthetic input"), deep_think=True)
                prepared = self.browser.prepare(request, self.stop)
                toggle, = self.browser._read_toggles(self.browser.session[0], names)
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
                if self.browser.session:
                    self.browser.session[0].get(self.browser.home)
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
        self.browser.generation_seconds = 10
        prepared = self.browser.prepare(other, self.stop)
        started = monotonic()
        with patch("browser.SUBMIT_CONFIRM_SECONDS", 0.4):
            with self.assertRaises(BrowserFailure) as error:
                self.browser.send(other, prepared, self.stop, self.track)
        self.assertLess(monotonic() - started, 5)
        self.assertEqual(self.browser.session[0].execute_script("return sessionStorage.lostSubmissions"), "1")
        self.assertEqual(error.exception.status, "uncertain")
        self.assertFalse(error.exception.accepted)
        self.assertTrue(error.exception.may_have_sent)

        self.site.mode = "stalled"
        self.browser.generation_seconds = 1.7
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
