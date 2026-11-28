"""Firefox adapter for one confirmed conversation at a time."""

from collections.abc import Mapping
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import logging
import mimetypes
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
from urllib.parse import urlsplit

DEEPSEEK_URL = "https://chat.deepseek.com/"
LOG = logging.getLogger("deepseek-web")
CHAT_PATH = "/a/chat/s/"
CHAT_ID = re.compile(r"[a-zA-Z0-9_-]{1,128}", re.ASCII)
TAIL = re.compile(r"v1:([1-9][0-9]{0,8}):[a-f0-9]{64}", re.ASCII)
MAX_RESPONSE_BYTES = 64_000
SUBMIT_CONFIRM_SECONDS = 20
ATTACHMENT_UPLOAD_SECONDS = 60
COMPOSER = '#chat-input, [data-testid="chat-input"], textarea[placeholder], [contenteditable="true"][role="textbox"]'
SEND = '[data-testid="send-button"], [aria-label="Send" i], [aria-label="Send message" i], [title="Send message" i]'
NATIVE_SEND = 'div[role="button"].ds-button.ds-button--primary.ds-button--filled.ds-button--circle'
STOP = '[data-testid="stop-button"], [aria-label="Stop generating" i], [aria-label="Stop" i], [title="Stop generating" i]'
ALERT = '[role="alert"], [data-testid="chat-error"], .ds-toast, .ds-message-error'
MODEL_BODY = (
    '[data-message-role="assistant"], [data-role="assistant"], '
    '.ds-assistant-message-main-content, .ds-think-content, '
    '[data-message-role="user"], [data-role="user"], .md-user-markdown, '
    '.ds-message > div > .ds-collapsible-text'
)
DEEPTHINK = ("deepthink", "deep think", "глубокое мышление", "深度思考")
SEARCH = ("search", "web search", "поиск", "联网搜索", "智能搜索")

# The native file card is shared by the composer and sent messages. Image
# preview loading can outlast upload, so readiness uses the send control and
# the upload state on the cards, without waiting for preview pixels.
ATTACHMENT_DOM = r"""
function attachmentCards(root) {
  return [...root.querySelectorAll(
    '[data-file-name], [data-testid="attachment-preview"], [data-testid="file-preview"], ' +
    '.ds-file-preview, .cd314545, img._9f130b7[alt]'
  )].filter(card => card.getClientRects().length && !card.parentElement.closest(
    '[data-file-name], [data-testid="attachment-preview"], [data-testid="file-preview"], .ds-file-preview, .cd314545'
  ));
}
function attachmentName(card) {
  return (card.getAttribute('data-file-name') || card.querySelector('.e70accd6')?.textContent ||
    (card.matches('img') ? card : card.querySelector('img[alt]'))?.getAttribute('alt') || '').trim();
}
"""

READ_ATTACHMENTS = ATTACHMENT_DOM + r"""
const [composer] = arguments;
const scope = composer.closest('._77cefa5, [data-testid="composer"]') || composer.parentElement;
const inputs = scope.querySelectorAll('input[type="file"]');
const input = inputs.length === 1 ? inputs[0] : null;
const cards = attachmentCards(scope);
const hasState = (card, selector) => card.matches(selector) || Boolean(card.querySelector(selector));
return {
  input,
  multiple: input?.multiple,
  accept: input?.accept,
  names: cards.map(attachmentName),
  pending: cards.some(card => hasState(card, '[aria-busy="true"], [role="progressbar"], [data-state="uploading"]') ||
    (card.matches('.cd314545') && hasState(card, '.ds-loading'))),
  failed: cards.some(card => hasState(card, '[data-state="error"], [data-status="error"], [aria-invalid="true"], ' +
    '[aria-label="Retry" i], [title="Retry" i]')),
};
"""

# The native selectors and completion toolbar follow the Firefox adapter in Ai-news-bot.
# Measure position in rendered user/assistant pairs and ignore action and reasoning UI.
READ_TURNS = ATTACHMENT_DOM + r"""
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
const citation = '.ds-markdown-cite';
const streaming = '[aria-busy="true"], [data-status="streaming"], [data-state="streaming"]';
const done = '[data-status="complete"], [data-state="complete"], [data-status="completed"]';
const action = '[data-testid="response-complete"], [data-testid="regenerate"], ' +
  '[aria-label="Regenerate" i], [title="Regenerate" i], [aria-label="Copy response" i], [title="Copy response" i]';
const readAloud = '[aria-label="Read aloud" i], [aria-label="朗读"]';
const stop = Array.from(document.querySelectorAll(arguments[0])).some(visible);
let elements = Array.from(scope.querySelectorAll(`${user}, ${assistant}, .ds-message`)).filter(visible);
elements = elements.filter(node => !elements.some(other => other !== node && node.contains(other)));
const list = elements[0]?.closest('.ds-virtual-list');
const items = elements[0]?.closest('.ds-virtual-list-visible-items');
const offset = items ? parseFloat(getComputedStyle(items).getPropertyValue('--dsl-virtual-list-transform-y')) : NaN;

function withoutControls(node) {
  const body = node.cloneNode(true);
  for (const control of body.querySelectorAll(reasoning + ', ' + controls)) control.remove();
  return body;
}

const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const escapeAttr = value => escape(value).replaceAll('"', '&quot;');
const emphasis = {
  B: 'b', STRONG: 'b', I: 'i', EM: 'i', U: 'u', INS: 'u', S: 's', STRIKE: 's', DEL: 's'
};

function formatted(node, depth = 0, rich = false) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent;
  const render = () => Array.from(node.childNodes).map(child => formatted(child, depth, rich)).join('');
  if (rich && emphasis[node.tagName]) {
    const tag = emphasis[node.tagName];
    return `<${tag}>${render()}</${tag}>`;
  }
  const pad = '  '.repeat(depth);
  switch (node.tagName) {
    case 'BR': return '\n';
    case 'CODE':
      return rich ? '<code>' + escape(node.textContent) + '</code>' : render();
    case 'PRE': {
      const raw = node.textContent;
      if (rich) {
        const code = node.querySelector('code');
        const language = code?.getAttribute('data-language') || node.getAttribute('data-language') ||
          Array.from([...(code?.classList || []), ...node.classList])
            .find(name => name.startsWith('language-'))?.slice('language-'.length);
        const body = escape(raw);
        return '\n\n<pre>' + (language ? '<code class="language-' + escapeAttr(language) + '">' + body + '</code>' : body) +
          '</pre>\n\n';
      }
      const longest = Math.max(2, ...(raw.match(/`+/g) || []).map(run => run.length));
      const fence = '`'.repeat(longest + 1);
      return '\n\n' + fence + '\n' + raw + (raw.endsWith('\n') ? '' : '\n') + fence + '\n\n';
    }
    case 'UL':
    case 'OL': {
      const items = Array.from(node.children).filter(child => child.tagName === 'LI');
      const start = Number(node.getAttribute('start') || '1');
      const lines = items.map((child, index) =>
        pad + (node.tagName === 'UL' ? (rich ? '• ' : '- ') : (start + index) + '. ') +
        formatted(child, depth + 1, rich).trim());
      return (depth ? '\n' : '\n\n') + lines.join('\n') + '\n\n';
    }
    case 'A':
      return rich && node.href ? '<a href="' + escapeAttr(node.href) + '">' + render() + '</a>' : render();
    case 'SPAN':
      return rich && node.classList.contains('tg-spoiler') ? '<tg-spoiler>' + render() + '</tg-spoiler>' : render();
    case 'BLOCKQUOTE': {
      if (!rich) return render() + '\n\n';
      const flag = node.hasAttribute('expandable') ? ' expandable' : '';
      return '<blockquote' + flag + '>' + render().trim() + '</blockquote>\n\n';
    }
    case 'DETAILS':
      return rich ? '<blockquote expandable>' + render().trim() + '</blockquote>\n\n' : render();
    case 'SUMMARY': return render() + (rich ? '\n' : '');
    case 'TR':
      return rich ? Array.from(node.cells, cell => formatted(cell, depth, rich).trim()).join(' | ') + '\n' : render();
    case 'P': return render() + '\n\n';
    case 'H1':
    case 'H2':
    case 'H3':
    case 'H4':
    case 'H5':
    case 'H6': return (rich ? '<b>' + render() + '</b>' : render()) + '\n\n';
    default: return render();
  }
}

return {
  stopping: stop,
  viewport: list && items ? {
    list,
    first: offset === 0,
    last: offset + items.offsetHeight >= items.parentElement.clientHeight - 2 ||
      list.scrollHeight - list.clientHeight - list.scrollTop <= 2
  } : null,
  turns: elements.map((element, index) => {
    const id = element.getAttribute('data-message-id') || '';
    const key = element.closest('[data-virtual-list-item-key]')?.getAttribute('data-virtual-list-item-key');
    const nativeQuestion = element.matches('.ds-message') && !element.matches(assistant) &&
      !element.querySelector(main + ', ' + reasoning)
      ? element.querySelector(':scope > div > .ds-collapsible-text') : null;
    const question = element.querySelector(userBody) || nativeQuestion;
    if (element.matches(user) || question) {
      const text = withoutControls(question || element);
      for (const br of text.querySelectorAll('br')) br.replaceWith('\n');
      return {role: 'user', id, key, text: text.textContent.trim(), complete: true,
              attachments: attachmentCards(element).map(attachmentName)};
    }
    if (!element.matches(assistant) && !element.querySelector(main + ', ' + reasoning)) {
      return {role: 'unknown', id, key, text: '', complete: false};
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
    const body = final && withoutControls(final);
    // Capture the original text for existing tail hashes before cleaning the delivery formats.
    const turn = {role: 'assistant', id, key, text: body ? formatted(body).trim() : '',
                  complete: Boolean(completed && !busy)};
    if (!body || index !== elements.length - 1) return turn;
    const markers = body.querySelectorAll(citation);
    for (const marker of markers) (marker.closest('a') || marker).remove();
    if (markers.length) turn.answerText = formatted(body).trim();
    turn.formattedText = formatted(body, 0, true).trim();
    return turn;
  })
};
"""

SCROLL_HISTORY = """
const [list, toEnd, done] = arguments;
const top = toEnd ? list.scrollHeight : Math.max(0, list.scrollTop - list.clientHeight * 0.75);
list.scrollTo({top, behavior: 'instant'});
requestAnimationFrame(() => requestAnimationFrame(() => done()));
"""

SET_COMPOSER = """
const [element, text] = arguments;
element.focus({preventScroll: true});
if (element instanceof HTMLTextAreaElement) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(element, text);
} else if (element.isContentEditable) {
  element.textContent = text;
} else return false;
element.dispatchEvent(new InputEvent('input', {bubbles: true, data: text, inputType: 'insertText'}));
return (element.value ?? element.textContent) === text;
"""

NEAREST_SEND_CONTROLS = """
const [composer, selector] = arguments;
let parent = composer.parentElement;
for (let depth = 0; parent && depth < 4; ++depth, parent = parent.parentElement) {
  const controls = parent.querySelectorAll(selector);
  if (controls.length) return Array.from(controls);
}
return [];
"""

READ_TOGGLES = """
const buttons = Array.from(document.querySelectorAll('button, [role="button"], [role="switch"], .ds-toggle-button'))
  .filter(node => node.getClientRects().length && getComputedStyle(node).visibility === 'visible');
const candidates = buttons.map(button => ({
  button,
  labels: [button.getAttribute('aria-label'), button.innerText, button.getAttribute('title')]
    .map(label => (label || '').trim().toLowerCase())
}));

function selected(button) {
  for (const key of ['aria-pressed', 'aria-checked', 'data-state', 'data-active']) {
    const value = button.getAttribute(key);
    if (['true', 'checked', 'on', 'active'].includes(value)) return true;
    if (['false', 'unchecked', 'off', 'inactive'].includes(value)) return false;
  }
  const classes = button.classList;
  if (classes.contains('ds-button--selected') || classes.contains('ds-toggle-button--selected')) return true;
  if (classes.contains('ds-button--unselected') || classes.contains('ds-toggle-button--unselected')) return false;
  return null;
}

return Array.from(arguments).map(names => {
  const match = candidates.find(({labels}) => labels.some(label =>
    names.some(name => label === name || label.startsWith(name + ' ('))));
  return match ? {button: match.button, selected: selected(match.button)} : null;
});
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
    history: tuple = ()


@dataclass(frozen=True)
class Answer:
    remote_id: str
    tail: str
    text: str
    formatted_text: str | None = None


def answer_format(turns, text):
    rich = turns[-1].get("formattedText")
    return rich if rich and rich != text and len(rich.encode()) <= MAX_RESPONSE_BYTES else None


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
    identity = [[turn["id"], turn["text"], *sorted(turn.get("attachments", []))] for turn in turns]
    data = json.dumps(identity, ensure_ascii=False, separators=(",", ":"))
    return f"v1:{len(turns) // 2}:{hashlib.sha256(data.encode()).hexdigest()}"


def history_prefix(earlier, later):
    """Find the prefix missing from a later viewport using overlapping native list keys."""
    if not earlier or not later:
        return None
    old_keys = [turn.get("key") for turn in earlier]
    new_keys = [turn.get("key") for turn in later]
    if (not all(old_keys) or not all(new_keys) or len(set(old_keys)) != len(old_keys)
            or len(set(new_keys)) != len(new_keys) or new_keys[0] not in old_keys):
        return None
    start = old_keys.index(new_keys[0])
    overlap = min(len(old_keys) - start, len(new_keys))
    if old_keys[start:start + overlap] != new_keys[:overlap]:
        return None
    return list(earlier[:start])


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
    if re.search(r"unsupported (?:file|format)|file (?:type|format) (?:is )?not supported|不支持.*(?:文件|格式)", message):
        return BrowserFailure("attachmentFormat")
    if re.search(r"upload.*(?:failed|limit)|(?:file|attachment).*too large|failed to (?:upload|parse)|上传失败", message):
        return BrowserFailure("attachmentFailed")
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
    supports_attachments = True

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
        options.page_load_strategy = "eager"
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
            driver.set_page_load_timeout(5)
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

    def _chat_url(self, remote_id):
        return self.home + (CHAT_PATH.lstrip("/") + remote_id if remote_id else "")

    def _navigate(self, driver, remote_id):
        from selenium.common.exceptions import TimeoutException

        try:
            driver.get(self._chat_url(remote_id))
        except TimeoutException:
            # The composer can be usable while page resources are still loading.
            # The caller still verifies the origin, chat ID and visible page.
            LOG.info("browser navigation timed out; checking the visible page")

    def _read(self, driver):
        return driver.execute_script(READ_TURNS, STOP)

    def _read_history(self, driver, stop, deadline, known=()):
        state = self._read(driver)
        viewport = state["viewport"]
        if not viewport:
            return state
        if not viewport["last"]:
            driver.execute_async_script(SCROLL_HISTORY, viewport["list"], True)
            state = self._read(driver)
            viewport = state["viewport"]
            if not viewport or not viewport["last"]:
                return None
        if viewport["first"]:
            return state

        turns = state["turns"]
        prefix = history_prefix(known, turns)
        if prefix is not None:
            return {**state, "turns": prefix + turns}

        # Reopenings and newly mounted turns may have no overlap with the
        # last snapshot. Walk the list with overlapping windows from the end.
        list_element = viewport["list"]
        try:
            while not viewport["first"] and time.monotonic() < deadline:
                if stop.is_set():
                    raise BrowserFailure("cancelled")
                driver.execute_async_script(SCROLL_HISTORY, list_element, False)
                earlier = self._read(driver)
                viewport = earlier["viewport"]
                prefix = history_prefix(earlier["turns"], turns)
                if not viewport or prefix is None:
                    return None
                turns = prefix + turns
            if viewport["first"]:
                return {**state, "turns": turns}
            return None
        finally:
            driver.execute_async_script(SCROLL_HISTORY, list_element, True)

    def _read_toggles(self, driver, *names):
        return driver.execute_script(READ_TOGGLES, *names)

    def _set_toggle(self, driver, names, desired, stop, deadline):
        toggle = self._wait(stop, deadline, lambda: self._read_toggles(driver, names)[0], "unknownUI")
        if toggle["selected"] is None:
            raise BrowserFailure("unknownUI")
        if toggle["selected"] is not desired:
            toggle["button"].click()

            def applied():
                current, = self._read_toggles(driver, names)
                return True if current and current["selected"] is desired else None

            self._wait(stop, deadline, applied, "unknownUI")

    def _toggles_match(self, driver, deep_think, web_search):
        think, search = self._read_toggles(driver, DEEPTHINK, SEARCH)
        return think and search and think["selected"] is deep_think and search["selected"] is web_search

    def _view_for(self, driver, expected_id, expected_tail, stop, deadline, known=()):
        actual_id = self._identity(driver)
        if actual_id != expected_id:
            if self._visible(driver, COMPOSER):
                raise BrowserFailure("chatUnavailable" if expected_id else "unknownUI")
            return None
        state = self._read_history(driver, stop, deadline, known)
        composer = self._visible(driver, COMPOSER)
        if composer is None or state is None or state["stopping"]:
            return None
        if state["viewport"] and self._identity(driver, check_alerts=False) != expected_id:
            return None
        turns = state["turns"]
        if expected_id is None and turns:
            raise BrowserFailure("unknownUI")
        if expected_id is not None and (not turns or tail_for(turns) != expected_tail):
            return None
        value = driver.execute_script("return arguments[0].value ?? arguments[0].textContent", composer)
        if value or driver.execute_script(READ_ATTACHMENTS, composer)["names"]:
            raise BrowserFailure("unknownUI")
        return composer, turns

    def prepare(self, request, stop):
        from selenium.common.exceptions import InvalidSessionIdException, NoSuchWindowException
        from urllib3.exceptions import HTTPError

        was_open = self.session is not None
        try:
            return self._prepare(request, stop)
        except (InvalidSessionIdException, NoSuchWindowException, HTTPError) as error:
            if not was_open or stop.is_set():
                raise
            LOG.info("reopening browser before submission (%s)", type(error).__name__)
            self.close()
            return self._prepare(request, stop)

    def _prepare(self, request, stop):
        deadline = time.monotonic() + self.prepare_seconds
        driver, (_, known) = self._load_view(request.remote_id, request.tail, stop, deadline)
        deep_think = self.deepthink if request.deep_think is None else request.deep_think
        self._set_toggle(driver, DEEPTHINK, deep_think, stop, deadline)
        self._set_toggle(driver, SEARCH, request.search_enabled, stop, deadline)
        _, turns = self._wait(
            stop, deadline, lambda: self._view_for(driver, request.remote_id, request.tail, stop, deadline, known),
            "chatUnavailable" if request.remote_id else "unknownUI",
        )
        if not self._toggles_match(driver, deep_think, request.search_enabled):
            raise BrowserFailure("unknownUI")
        return Prepared(request.remote_id, request.tail, len(turns), tuple(turns))

    def _load_view(self, remote_id, tail, stop, deadline):
        from selenium.common.exceptions import StaleElementReferenceException

        if stop.is_set():
            raise BrowserFailure("cancelled")
        driver = self._open()

        def view():
            return self._view_for(driver, remote_id, tail, stop, deadline)

        if driver.current_url == self._chat_url(remote_id):
            try:
                if (loaded := view()) is not None:
                    return driver, loaded
            except StaleElementReferenceException:
                pass
            except BrowserFailure as error:
                if error.status != "unknownUI":
                    raise
        self._navigate(driver, remote_id)
        return driver, self._wait(stop, deadline, view, "chatUnavailable" if remote_id else "unknownUI")

    def verify(self, stop):
        self._load_view(None, None, stop, time.monotonic() + self.prepare_seconds)

    @staticmethod
    def _can_send(control):
        return (control.is_enabled()
                and control.get_dom_attribute("disabled") is None
                and control.get_dom_attribute("aria-disabled") != "true"
                and "ds-button--disabled" not in (control.get_dom_attribute("class") or "").split())

    @staticmethod
    def _attachment_paths(request):
        root = Path(os.environ.get("TMPDIR", "/tmp")) / f"llmchat-attachments-{request.attachment_batch_id}"
        try:
            private_directory(root)
            paths = []
            for index, name in enumerate(request.attachment_names):
                folder = root / str(index)
                private_directory(folder)
                path = folder / name
                info = path.lstat()
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_mode & 0o077 or info.st_nlink != 1 or not 0 < info.st_size <= 20 << 20):
                    raise ValueError
                paths.append(path)
            return paths
        except (OSError, ValueError):
            raise BrowserFailure("attachmentFailed") from None

    @staticmethod
    def _accepts_attachment(name, accept):
        types = [entry.strip().lower() for entry in accept.split(",") if entry.strip()]
        if not types:
            return True
        mime = mimetypes.guess_type(name)[0] or ""
        name = "." + name.lower()
        return any(
            name.endswith(entry) if entry.startswith(".") else
            mime == entry or (entry.endswith("/*") and mime.startswith(entry[:-1]))
            for entry in types
        )

    def _attach(self, driver, composer, request):
        from selenium.webdriver.remote.file_detector import UselessFileDetector

        state = driver.execute_script(READ_ATTACHMENTS, composer)
        if state["input"] is None or (len(request.attachment_names) > 1 and not state["multiple"]):
            raise BrowserFailure("attachmentFailed")
        if any(not self._accepts_attachment(name, state["accept"]) for name in request.attachment_names):
            raise BrowserFailure("attachmentFormat")
        paths = self._attachment_paths(request)
        # Geckodriver and the worker share the host. Remote Selenium's
        # default file transfer command is unsupported by geckodriver.
        with driver.file_detector_context(UselessFileDetector):
            state["input"].send_keys("\n".join(map(str, paths)))

    def _submission(self, request, prepared, stop):
        from selenium.webdriver.common.keys import Keys

        driver = self.session[0]
        deadline = time.monotonic() + min(self.prepare_seconds, 5)
        view = self._view_for(driver, prepared.remote_id, prepared.tail, stop, deadline, prepared.history)
        if view is None or len(view[1]) != prepared.count:
            raise BrowserFailure("chatUnavailable" if prepared.remote_id else "unknownUI")
        composer = view[0]
        limit = composer.get_dom_attribute("maxlength")
        if limit and limit.isdecimal() and len(request.prompt.encode("utf-16-le")) // 2 > int(limit):
            raise BrowserFailure("inputTooLong")
        expected_files = sorted(request.attachment_names)
        if expected_files:
            if stop.is_set():
                raise BrowserFailure("cancelled")
            deadline = time.monotonic() + ATTACHMENT_UPLOAD_SECONDS
            self._attach(driver, composer, request)
        if not driver.execute_script(SET_COMPOSER, composer, request.prompt):
            raise BrowserFailure("inputTooLong")

        def attachments_ready():
            state = driver.execute_script(READ_ATTACHMENTS, composer)
            if state["failed"] or len(state["names"]) > len(expected_files):
                raise BrowserFailure("attachmentFailed" if expected_files else "unknownUI")
            return sorted(state["names"]) == expected_files and not state["pending"]

        def send_control():
            try:
                current_id = self._identity(driver)
            except BrowserFailure as error:
                if expected_files and error.status == "unavailable":
                    raise BrowserFailure("attachmentFailed") from None
                raise
            if current_id != prepared.remote_id:
                raise BrowserFailure("unknownUI")
            if expected_files and not attachments_ready():
                return None
            controls = driver.execute_script(NEAREST_SEND_CONTROLS, composer, f"{SEND}, {NATIVE_SEND}")
            if controls:
                visible = [control for control in controls if control.is_displayed()]
                return visible[0].click if len(visible) == 1 and self._can_send(visible[0]) else None
            # The native composer handles Enter on layouts with an unlabeled send icon.
            if not expected_files and composer.get_dom_attribute("id") == "chat-input":
                return lambda: composer.send_keys(Keys.ENTER)
            return None

        submit = self._wait(stop, deadline, send_control, "attachmentFailed" if expected_files else "unknownUI")
        current = driver.execute_script("return arguments[0].value ?? arguments[0].textContent", composer)
        state = self._read_history(driver, stop, deadline, prepared.history)
        if current != request.prompt:
            raise BrowserFailure("inputTooLong")
        deep_think = self.deepthink if request.deep_think is None else request.deep_think
        if (self._identity(driver) != prepared.remote_id or state is None or state["stopping"]
                or len(state["turns"]) != prepared.count
                or tail_for(state["turns"]) != prepared.tail or not attachments_ready()
                or not self._toggles_match(driver, deep_think, request.search_enabled)):
            raise BrowserFailure("unknownUI")
        if stop.is_set():
            raise BrowserFailure("cancelled")
        return driver, submit

    def send(self, request, prepared, stop, progress):
        from selenium.common.exceptions import (
            ElementClickInterceptedException, ElementNotInteractableException,
            InvalidSessionIdException, NoSuchWindowException, StaleElementReferenceException, WebDriverException,
        )
        from urllib3.exceptions import HTTPError

        if len(request.prompt.encode("utf-16-le")) // 2 > self.max_prompt_units:
            raise BrowserFailure("inputTooLong")
        for attempt in range(2):
            try:
                driver, submit = self._submission(request, prepared, stop)
            except (InvalidSessionIdException, NoSuchWindowException, StaleElementReferenceException, HTTPError) as error:
                if attempt:
                    raise BrowserFailure("unavailable") from error
                LOG.info("preparing submission again (%s)", type(error).__name__)
            except WebDriverException as error:
                LOG.warning("submission preparation failed (%s)", type(error).__name__)
                raise BrowserFailure("unavailable") from error
            else:
                try:
                    submit()
                except (ElementClickInterceptedException, ElementNotInteractableException,
                        StaleElementReferenceException) as error:
                    # WebDriver rejected the interaction before dispatching it.
                    if attempt:
                        raise BrowserFailure("unknownUI") from error
                    LOG.info("browser rejected interaction (%s); checking the composer again", type(error).__name__)
                except (WebDriverException, HTTPError) as error:
                    LOG.warning("submission needs confirmation (%s)", type(error).__name__)
                    break
                else:
                    break
            try:
                prepared = self.prepare(request, stop)
            except (WebDriverException, HTTPError) as error:
                raise BrowserFailure("unavailable") from error

        remote_id, accepted = prepared.remote_id, False
        confirmation_deadline = time.monotonic() + SUBMIT_CONFIRM_SECONDS
        generation_deadline = time.monotonic() + self.generation_seconds
        known = prepared.history

        def result():
            nonlocal remote_id, accepted, known
            result_id = self._identity(driver, check_alerts=False)
            if remote_id and result_id != remote_id:
                raise BrowserFailure("uncertain")
            if result_id:
                remote_id = result_id
            deadline = generation_deadline if accepted else min(generation_deadline, confirmation_deadline)
            state = self._read_history(driver, stop, deadline, known)
            text, confirmed, complete = self._match(state, request, prepared) if state else (None, False, False)
            accepted |= confirmed
            if confirmed:
                known = state["turns"]
            if self._identity(driver) != result_id:
                return None
            rich = answer_format(state["turns"], text) if text and result_id else None
            if result_id and complete:
                return Answer(result_id, tail_for(state["turns"]), text, rich)
            progress(remote_id, accepted, text if result_id else None, rich)
            if not accepted and time.monotonic() >= confirmation_deadline:
                LOG.warning("browser did not confirm prompt submission")
                raise BrowserFailure("uncertain")
            return None

        try:
            return self._wait(stop, generation_deadline, result, "uncertain")
        except BrowserFailure as error:
            # Only an explicit banner paired with a restored/blocked composer and baseline
            # history can prove a click was rejected. Other failures require reconciliation.
            status = error.status
            accepted |= error.accepted
            may_have_sent = True
            if status in {"quota", "busy", "inputTooLong", "chatUnavailable"} and not accepted:
                try:
                    view = self._read_history(driver, stop, confirmation_deadline, known)
                    if view is not None:
                        turns = view["turns"]
                        may_have_sent = (remote_id != prepared.remote_id or len(turns) != prepared.count
                                         or tail_for(turns) != prepared.tail)
                except (BrowserFailure, WebDriverException):
                    pass
            elif status == "cancelled" or status == "unknownUI":
                status = "uncertain"
            raise BrowserFailure(status, accepted, remote_id, error.retry_after, may_have_sent) from None
        except Exception:
            raise BrowserFailure("uncertain", accepted, remote_id, may_have_sent=True) from None

    def _match(self, state: Mapping, request, prepared):
        turns = state["turns"]
        count = prepared.count
        if len(turns) < count or tail_for(turns[:count]) != prepared.tail:
            return None, False, False
        new = turns[count:]
        if (not new or new[0]["role"] != "user"
                or new[0]["text"].replace("\r\n", "\n").strip() != request.prompt.replace("\r\n", "\n").strip()
                or sorted(new[0].get("attachments", [])) != sorted(request.attachment_names)):
            return None, False, False
        if len(new) > 2:
            raise BrowserFailure("uncertain", accepted=True)
        if len(new) != 2 or new[1]["role"] != "assistant":
            return None, True, False
        answer = new[1].get("answerText", new[1]["text"])
        complete = new[1]["complete"] and not state["stopping"]
        if (complete and not answer) or len(answer.encode()) > MAX_RESPONSE_BYTES:
            raise BrowserFailure("uncertain", accepted=True)
        return answer or None, True, complete

    def reconcile(self, request, stop, progress):
        if not request.remote_id:
            raise BrowserFailure("uncertain")
        count = int(TAIL.fullmatch(request.tail)[1]) * 2 if request.tail else 0
        prepared = Prepared(request.remote_id, request.tail, count)
        deadline = time.monotonic() + min(self.prepare_seconds, 12)
        driver = self._open()
        self._navigate(driver, request.remote_id)
        known = ()

        def result():
            nonlocal known
            if self._identity(driver) != request.remote_id:
                raise BrowserFailure("uncertain")
            state = self._read_history(driver, stop, deadline, known)
            if state is None:
                return None
            answer, accepted, complete = self._match(state, request, prepared)
            if accepted:
                known = state["turns"]
            progress(request.remote_id, accepted)
            if complete and self._identity(driver) == request.remote_id:
                return Answer(request.remote_id, tail_for(state["turns"]), answer, answer_format(state["turns"], answer))
            return None

        # Existing history without the expected appended turn is ambiguous after a crash.
        return self._wait(stop, deadline, result, "uncertain")
