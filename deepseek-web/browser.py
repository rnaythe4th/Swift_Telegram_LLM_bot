"""Firefox adapter for one confirmed conversation at a time."""

from collections.abc import Mapping
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
from urllib.parse import urlsplit

DEEPSEEK_URL = "https://chat.deepseek.com/"
CHAT_PATH = "/a/chat/s/"
CHAT_ID = re.compile(r"[a-zA-Z0-9_-]{1,128}", re.ASCII)
TAIL = re.compile(r"v1:([1-9][0-9]{0,8}):[a-f0-9]{64}", re.ASCII)
MAX_RESPONSE_BYTES = 64_000
COMPOSER = '#chat-input, [data-testid="chat-input"], textarea[placeholder], [contenteditable="true"][role="textbox"]'
SEND = '[data-testid="send-button"], [aria-label="Send" i], [aria-label="Send message" i], [title="Send message" i]'
STOP = '[data-testid="stop-button"], [aria-label="Stop generating" i], [aria-label="Stop" i], [title="Stop generating" i]'
ATTACHMENT = '[data-testid="attachment-preview"], [data-testid="file-preview"], .ds-file-preview'
ALERT = '[role="alert"], [data-testid="chat-error"], .ds-toast, .ds-message-error'
MODEL_BODY = (
    '[data-message-role="assistant"], [data-role="assistant"], '
    '.ds-assistant-message-main-content, .ds-think-content, '
    '[data-message-role="user"], [data-role="user"], .md-user-markdown'
)
DEEPTHINK = ("deepthink", "deep think", "глубокое мышление", "深度思考")
SEARCH = ("search", "web search", "поиск", "联网搜索", "智能搜索")

# The native selectors and completion toolbar follow the Firefox adapter in Ai-news-bot.
# Measure position in rendered user/assistant pairs and ignore action and reasoning UI.
READ_TURNS = r"""
const visible = node => node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden';
const scope = document.querySelector('[data-testid="conversation"], [data-testid="message-list"]') || document;
const user = '[data-message-role="user"], [data-role="user"]';
const assistant = '[data-message-role="assistant"], [data-role="assistant"]';
const userBody = '.md-user-markdown, [data-testid="user-message-content"]';
const main = '.ds-assistant-message-main-content';
const reasoning = '[data-testid="reasoning"], [data-role="reasoning"], .ds-think, .ds-think-content, ' +
  '[class*="thinking" i], [class*="reasoning" i]';
const code = 'pre, .md-code-block, [data-testid="code-block"]';
const controls = 'button, [role="button"], .md-code-block-banner';
const streaming = '[aria-busy="true"], [data-status="streaming"], [data-state="streaming"]';
const done = '[data-status="complete"], [data-state="complete"], [data-status="completed"]';
const action = '[data-testid="response-complete"], [data-testid="regenerate"], ' +
  '[aria-label="Regenerate" i], [title="Regenerate" i], [aria-label="Copy response" i], [title="Copy response" i]';
const readAloud = '[aria-label="Read aloud" i], [aria-label="朗读"]';
const stop = Array.from(document.querySelectorAll(arguments[0])).some(visible);
let elements = Array.from(scope.querySelectorAll(`${user}, ${assistant}, .ds-message`)).filter(visible);
elements = elements.filter(node => !elements.some(other => other !== node && node.contains(other)));

function withoutControls(node) {
  const body = node.cloneNode(true);
  for (const control of body.querySelectorAll(reasoning + ', ' + controls)) control.remove();
  return body;
}

function formatted(node, depth = 0) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent;
  const render = (level = depth) => Array.from(node.childNodes).map(child => formatted(child, level)).join('');
  const pad = '  '.repeat(depth);
  switch (node.tagName) {
    case 'BR': return '\n';
    case 'PRE': {
      const raw = node.textContent;
      const longest = Math.max(2, ...(raw.match(/`+/g) || []).map(run => run.length));
      const fence = '`'.repeat(longest + 1);
      return '\n\n' + fence + '\n' + raw + (raw.endsWith('\n') ? '' : '\n') + fence + '\n\n';
    }
    case 'UL':
    case 'OL': {
      const items = Array.from(node.children).filter(child => child.tagName === 'LI');
      const start = Number(node.getAttribute('start') || '1');
      const lines = items.map((child, index) =>
        pad + (node.tagName === 'UL' ? '- ' : (start + index) + '. ') + formatted(child, depth + 1).trim());
      return (depth ? '\n' : '\n\n') + lines.join('\n') + '\n\n';
    }
    case 'P':
    case 'BLOCKQUOTE':
    case 'H1':
    case 'H2':
    case 'H3':
    case 'H4':
    case 'H5':
    case 'H6': return render() + '\n\n';
    default: return render();
  }
}

return {
  stopping: stop,
  turns: elements.map(element => {
    const id = element.getAttribute('data-message-id') || '';
    const question = element.querySelector(userBody);
    if (element.matches(user) || question) {
      const text = withoutControls(question || element);
      for (const br of text.querySelectorAll('br')) br.replaceWith('\n');
      return {role: 'user', id, text: text.textContent.trim(), complete: true};
    }
    if (!element.matches(assistant) && !element.querySelector(main + ', ' + reasoning)) {
      return {role: 'unknown', id, text: '', complete: false};
    }
    let blocks = Array.from(element.querySelectorAll(
      `[data-testid="final-answer"], [data-testid="response-content"], ${main}, .ds-markdown`
    )).filter(node => visible(node) && !node.closest(reasoning));
    blocks = blocks.filter(node => !blocks.some(other => other !== node && other.contains(node)));
    const final = blocks.length === 1 ? blocks[0] : null;
    const nativeToolbar = element.matches('.ds-message') && final?.matches(main) && element.parentElement &&
      element.parentElement.querySelectorAll(':scope > .ds-message').length === 1 &&
      Array.from(element.parentElement.children).some(node => node !== element && node.matches('.ds-flex') &&
        Array.from(node.querySelectorAll(readAloud)).some(visible));
    const completed = element.matches(done) || nativeToolbar ||
      Array.from(element.querySelectorAll(action)).some(node => visible(node) && !node.closest(reasoning + ', ' + code));
    const busy = element.matches(streaming) || Array.from(element.querySelectorAll(streaming)).some(visible);
    return {role: 'assistant', id, text: final ? formatted(withoutControls(final)).trim() : '',
            complete: Boolean(completed && !busy)};
  })
};
"""

SET_COMPOSER = """
const [element, text] = arguments;
if (element instanceof HTMLTextAreaElement) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(element, text);
} else if (element.isContentEditable) {
  element.textContent = text;
} else return false;
element.dispatchEvent(new InputEvent('input', {bubbles: true, data: text, inputType: 'insertText'}));
return (element.value ?? element.textContent) === text;
"""


@dataclass
class BrowserFailure(Exception):
    status: str
    accepted: bool = False
    remote_id: str | None = None
    retry_after: int | None = None
    may_have_sent: bool = False


@dataclass(frozen=True)
class Prepared:
    remote_id: str | None
    tail: str | None
    count: int


@dataclass(frozen=True)
class Answer:
    remote_id: str
    tail: str
    text: str


def tail_for(turns):
    if not turns:
        return None
    if len(turns) % 2 or any(
        turn["role"] != ("assistant" if position % 2 else "user")
        or not turn["complete"] or not turn["text"]
        for position, turn in enumerate(turns)
    ):
        return None
    # Text hashes with native IDs when available cover the ordered prefix as well as the last pair.
    data = json.dumps([(turn["id"], turn["text"]) for turn in turns], ensure_ascii=False, separators=(",", ":"))
    return f"v1:{len(turns) // 2}:{hashlib.sha256(data.encode()).hexdigest()}"


def classify_alert(message):
    message = message.casefold()
    if re.search(r"sign in|log in|verify|captcha|войдите|проверка|验证|登录", message):
        return BrowserFailure("loginRequired")
    if re.search(r"server is busy|temporarily overloaded|сервер перегружен|服务器繁忙", message):
        return BrowserFailure("busy")
    if re.search(r"rate limit|too many requests|quota exceeded|request limit|лимит запросов|请求次数", message):
        delay = None
        if match := re.search(r"(?:try again|retry) in (\d{1,5})\s*(seconds?|minutes?|hours?)\b", message):
            number, unit = match.groups()
            scale = 3600 if unit.startswith("hour") else 60 if unit.startswith("minute") else 1
            delay = min(int(number) * scale, 604800) or None
        return BrowserFailure("quota", retry_after=delay)
    if re.search(r"message is too long|input too long|message length|输入过长|слишком длинн", message):
        return BrowserFailure("inputTooLong")
    if re.search(r"(chat|conversation) (?:is )?(?:not found|unavailable|too long|full)|maximum context length", message):
        return BrowserFailure("chatUnavailable")
    if re.search(r"blocked by (?:content )?moderation|violates? (?:our )?content policy|content policy violation", message):
        return BrowserFailure("moderated")
    return BrowserFailure("unavailable")


def private_directory(profile):
    info = Path(profile).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Firefox profile must be private and owned by the worker")


@contextmanager
def locked_profile(profile):
    private_directory(profile)
    fd = os.open(Path(profile) / ".deepseek-web.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Firefox profile lock must be private and owned by the worker")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


class Browser:
    def __init__(self, profile, *, home=DEEPSEEK_URL, firefox="/usr/bin/firefox-esr",
                 geckodriver="/usr/local/bin/geckodriver", deepthink=False,
                 prepare_seconds=25, generation_seconds=240, max_prompt_units=12_000):
        self.profile = Path(profile)
        self.home = home
        self.origin = urlsplit(home).netloc
        self.scheme = urlsplit(home).scheme
        self.firefox = firefox
        self.geckodriver = geckodriver
        self.deepthink = deepthink
        self.prepare_seconds = prepare_seconds
        self.generation_seconds = generation_seconds
        self.max_prompt_units = max_prompt_units
        self.session = None
        self.profile_lock = None

    def _open(self):
        from selenium import webdriver
        from selenium.webdriver.common.proxy import Proxy, ProxyType
        from selenium.webdriver.firefox.service import Service
        from selenium.webdriver.remote.client_config import ClientConfig

        if self.session:
            return self.session[0]
        guard = locked_profile(self.profile)
        guard.__enter__()
        self.profile_lock = guard
        browser_env = {
            key: value for key, value in os.environ.items()
            if key in {"PATH", "HOME", "LANG", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMPDIR", "TZ"}
            or key.startswith("LC_")
        }
        options = webdriver.FirefoxOptions()
        options.binary_location = self.firefox
        options.accept_insecure_certs = False
        options.set_preference("intl.accept_languages", "en-US,en")
        options.add_argument("-profile")
        options.add_argument(str(self.profile))
        options.add_argument("-headless")
        service = Service(self.geckodriver, log_output=subprocess.DEVNULL, env=browser_env,
                          popen_kw={"start_new_session": True})
        driver = None
        try:
            service.start()
            client = ClientConfig(remote_server_addr=service.service_url, timeout=12,
                                  proxy=Proxy(raw={"proxyType": ProxyType.DIRECT}))
            driver = webdriver.Remote(command_executor=service.service_url, options=options, client_config=client)
            driver.set_page_load_timeout(10)
            driver.set_script_timeout(8)
            self.session = driver, service
            return driver
        except Exception:
            self.session = driver, service
            self.close()
            raise

    def close(self):
        session, self.session = self.session, None
        guard, self.profile_lock = self.profile_lock, None
        try:
            if session:
                driver, service = session
                process = getattr(service, "process", None)
                group = process.pid if process else None
                try:
                    if driver is not None:
                        try:
                            driver.quit()
                        except Exception:
                            pass
                finally:
                    if group is not None:
                        try:
                            os.killpg(group, signal.SIGTERM)
                            process.wait(timeout=2)
                        except (ProcessLookupError, subprocess.TimeoutExpired):
                            pass
                        finally:
                            try:
                                os.killpg(group, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        process.wait(timeout=2)
        finally:
            if guard:
                guard.__exit__(None, None, None)

    @staticmethod
    def _elements(driver, selector):
        return [element for element in driver.find_elements("css selector", selector) if element.is_displayed()]

    def _visible(self, driver, selector):
        return next(iter(self._elements(driver, selector)), None)

    def _identity(self, driver, *, check_alerts=True):
        here = urlsplit(driver.current_url)
        if here.scheme != self.scheme or here.netloc != self.origin:
            if here.hostname and here.hostname.endswith(".deepseek.com"):
                raise BrowserFailure("loginRequired")
            raise BrowserFailure("unknownUI")
        if re.search(r"/(sign[-_]?in|sign[-_]?up|log[-_]?in|verify)(/|$)", here.path, re.I) or self._visible(
            driver, 'input[type="password"], iframe[src*="captcha" i], iframe[src*="challenges.cloudflare.com"]',
        ):
            raise BrowserFailure("loginRequired")
        for alert in self._elements(driver, ALERT) if check_alerts else ():
            # Quoted model content and its widgets cannot set account state.
            inside_response = driver.execute_script("return Boolean(arguments[0].closest(arguments[1]))", alert, MODEL_BODY)
            if not inside_response and alert.text.strip():
                raise classify_alert(alert.text.strip())
        if here.path == "/":
            return None
        if here.path.startswith(CHAT_PATH) and CHAT_ID.fullmatch(remote_id := here.path[len(CHAT_PATH):]):
            return remote_id
        raise BrowserFailure("unknownUI")

    def _wait(self, stop, deadline, predicate, on_timeout):
        from selenium.common.exceptions import StaleElementReferenceException

        while time.monotonic() < deadline:
            if stop.is_set():
                raise BrowserFailure("cancelled")
            try:
                if (value := predicate()) is not None:
                    return value
            except StaleElementReferenceException:
                pass
            stop.wait(min(0.15, max(0, deadline - time.monotonic())))
        raise BrowserFailure(on_timeout)

    def _go(self, remote_id):
        driver = self._open()
        driver.get(self.home + (CHAT_PATH.lstrip("/") + remote_id if remote_id else ""))
        return driver

    def _read(self, driver):
        return driver.execute_script(READ_TURNS, STOP)

    def _find_toggle(self, driver, names):
        for button in self._elements(driver, 'button, [role="button"], [role="switch"], .ds-toggle-button'):
            values = (button.get_attribute("aria-label"), button.text, button.get_attribute("title"))
            for value in values:
                label = (value or "").strip().casefold()
                if any(label == name or label.startswith(name + " (") for name in names):
                    return button
        return None

    @staticmethod
    def _toggle_state(button):
        if button is None:
            return None
        for key in ("aria-pressed", "aria-checked", "data-state", "data-active"):
            if (value := button.get_dom_attribute(key)) in ("true", "checked", "on", "active"):
                return True
            if value in ("false", "unchecked", "off", "inactive"):
                return False
        classes = set((button.get_dom_attribute("class") or "").split())
        if {"ds-button--selected", "ds-toggle-button--selected"} & classes:
            return True
        if {"ds-button--unselected", "ds-toggle-button--unselected"} & classes:
            return False
        return None

    def _set_toggle(self, driver, names, desired, stop, deadline):
        button = self._wait(stop, deadline, lambda: self._find_toggle(driver, names), "unknownUI")
        current = self._toggle_state(button)
        if current is None:
            raise BrowserFailure("unknownUI")
        if current is not desired:
            button.click()
            self._wait(stop, deadline, lambda: True if self._toggle_state(self._find_toggle(driver, names)) is desired else None,
                       "unknownUI")

    def _view_for(self, driver, expected_id, expected_tail):
        actual_id = self._identity(driver)
        if actual_id != expected_id:
            if self._visible(driver, COMPOSER):
                raise BrowserFailure("chatUnavailable" if expected_id else "unknownUI")
            return None
        state = self._read(driver)
        composer = self._visible(driver, COMPOSER)
        if composer is None or state["stopping"]:
            return None
        turns = state["turns"]
        if expected_id is None and turns:
            raise BrowserFailure("unknownUI")
        if expected_id is not None and (not turns or tail_for(turns) != expected_tail):
            return None
        value = driver.execute_script("return arguments[0].value ?? arguments[0].textContent", composer)
        if value or self._visible(driver, ATTACHMENT):
            raise BrowserFailure("unknownUI")
        return composer, len(turns)

    def prepare(self, request, stop):
        deadline = time.monotonic() + self.prepare_seconds
        driver = self._go(request.remote_id)
        timeout = "chatUnavailable" if request.remote_id else "unknownUI"

        def view():
            return self._view_for(driver, request.remote_id, request.tail)

        self._wait(stop, deadline, view, timeout)
        self._set_toggle(driver, DEEPTHINK, self.deepthink, stop, deadline)
        self._set_toggle(driver, SEARCH, False, stop, deadline)
        _, count = self._wait(stop, deadline, view, timeout)
        return Prepared(request.remote_id, request.tail, count)

    def verify(self, stop):
        driver = self._go(None)
        self._wait(stop, time.monotonic() + self.prepare_seconds,
                   lambda: self._view_for(driver, None, None), "unknownUI")

    def send(self, request, prepared, stop, progress):
        from selenium.common.exceptions import WebDriverException

        if len(request.prompt.encode("utf-16-le")) // 2 > self.max_prompt_units:
            raise BrowserFailure("inputTooLong")
        driver = self.session[0]
        view = self._view_for(driver, prepared.remote_id, prepared.tail)
        if view is None or view[1] != prepared.count:
            raise BrowserFailure("chatUnavailable" if prepared.remote_id else "unknownUI")
        composer = view[0]
        limit = composer.get_dom_attribute("maxlength")
        if limit and limit.isdecimal() and len(request.prompt.encode("utf-16-le")) // 2 > int(limit):
            raise BrowserFailure("inputTooLong")
        if not driver.execute_script(SET_COMPOSER, composer, request.prompt):
            raise BrowserFailure("inputTooLong")

        def send_control():
            if self._identity(driver) != prepared.remote_id:
                raise BrowserFailure("unknownUI")
            send = self._visible(driver, SEND)
            if send and send.is_enabled() and send.get_dom_attribute("aria-disabled") != "true":
                return send
            return None

        send = self._wait(stop, time.monotonic() + min(self.prepare_seconds, 5), send_control, "unknownUI")
        current = driver.execute_script("return arguments[0].value ?? arguments[0].textContent", composer)
        state = self._read(driver)
        if current != request.prompt:
            raise BrowserFailure("inputTooLong")
        if (self._identity(driver) != prepared.remote_id or state["stopping"] or len(state["turns"]) != prepared.count
                or tail_for(state["turns"]) != prepared.tail or self._visible(driver, ATTACHMENT)
                or self._toggle_state(self._find_toggle(driver, DEEPTHINK)) is not self.deepthink
                or self._toggle_state(self._find_toggle(driver, SEARCH)) is not False):
            raise BrowserFailure("unknownUI")
        if stop.is_set():
            raise BrowserFailure("cancelled")

        # This is the only send call. A driver error can happen after delivery.
        remote_id, accepted = prepared.remote_id, False
        try:
            send.click()
        except WebDriverException:
            pass

        def result():
            nonlocal remote_id, accepted
            result_id = self._identity(driver, check_alerts=False)
            if remote_id and result_id != remote_id:
                raise BrowserFailure("uncertain")
            if result_id:
                remote_id = result_id
            state = self._read(driver)
            answer, confirmed = self._match(state, request.prompt, prepared)
            accepted |= confirmed
            progress(remote_id, accepted)
            self._identity(driver)
            if remote_id and answer:
                return Answer(remote_id, tail_for(state["turns"]), answer)
            return None

        try:
            return self._wait(stop, time.monotonic() + self.generation_seconds, result, "uncertain")
        except BrowserFailure as error:
            # Only an explicit banner paired with a restored/blocked composer and baseline
            # history can prove a click was rejected. Other failures require reconciliation.
            status = error.status
            accepted |= error.accepted
            may_have_sent = True
            if status in {"quota", "busy", "inputTooLong", "chatUnavailable"} and not accepted:
                try:
                    turns = self._read(driver)["turns"]
                    may_have_sent = (
                        remote_id != prepared.remote_id or len(turns) != prepared.count
                        or tail_for(turns) != prepared.tail
                    )
                except WebDriverException:
                    pass
            elif status == "cancelled" or status == "unknownUI":
                status = "uncertain"
            raise BrowserFailure(status, accepted, remote_id, error.retry_after, may_have_sent) from None
        except Exception:
            raise BrowserFailure("uncertain", accepted, remote_id, may_have_sent=True) from None

    def _match(self, state: Mapping, prompt, prepared):
        turns = state["turns"]
        count = prepared.count
        if len(turns) < count or tail_for(turns[:count]) != prepared.tail:
            return None, False
        new = turns[count:]
        if (not new or new[0]["role"] != "user"
                or new[0]["text"].replace("\r\n", "\n").strip() != prompt.replace("\r\n", "\n").strip()):
            return None, False
        if len(new) > 2:
            raise BrowserFailure("uncertain", accepted=True)
        if len(new) != 2 or new[1]["role"] != "assistant" or not new[1]["complete"] or state["stopping"]:
            return None, True
        answer = new[1]["text"]
        if not answer or len(answer.encode()) > MAX_RESPONSE_BYTES:
            raise BrowserFailure("uncertain", accepted=True)
        return answer, True

    def reconcile(self, request, stop, progress):
        if not request.remote_id:
            raise BrowserFailure("uncertain")
        count = int(TAIL.fullmatch(request.tail)[1]) * 2 if request.tail else 0
        prepared = Prepared(request.remote_id, request.tail, count)
        deadline = time.monotonic() + min(self.prepare_seconds, 12)
        driver = self._go(request.remote_id)

        def result():
            if self._identity(driver) != request.remote_id:
                raise BrowserFailure("uncertain")
            state = self._read(driver)
            answer, accepted = self._match(state, request.prompt, prepared)
            progress(request.remote_id, accepted)
            if answer:
                return Answer(request.remote_id, tail_for(state["turns"]), answer)
            return None

        # Existing history without the expected appended turn is ambiguous after a crash.
        return self._wait(stop, deadline, result, "uncertain")
