from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Awaitable, Callable, Dict, Optional, Tuple, TypeVar
from urllib.parse import urlsplit

from playwright.async_api import (
    Browser,
    BrowserContext,
    CDPSession,
    Error as PlaywrightError,
    Frame,
    Page,
    Request,
    Route,
    TimeoutError as PlaywrightTimeoutError,
    WebSocketRoute,
    async_playwright,
)

from .config import Settings
from .errors import ServiceError
from .frame import JPEGEncoder, ScreenshotInspector
from .reader import ExtractedDocument, finalize_document, safe_link
from .schemas import FrameResponse, ReadBlock, ReadLink
from .security import URLGuard


logger = logging.getLogger(__name__)
ResultType = TypeVar("ResultType")


_MOBILE_CHROME_USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 14; Pixel 7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Mobile Safari/537.36"
)


_SCROLL_PROGRESS_SCRIPT = """
() => {
  const root = document.scrollingElement || document.documentElement;
  const top = Math.max(0, root ? root.scrollTop : window.scrollY || 0);
  const height = Math.max(
    root ? root.scrollHeight : 0,
    document.body ? document.body.scrollHeight : 0
  );
  const viewport = Math.max(1, window.innerHeight || 1);
  const maximum = Math.max(0, height - viewport);
  return maximum > 0 ? Math.min(1, Math.max(0, top / maximum)) : 0;
}
"""

_DOM_SIGNAL_SCRIPT = """
() => {
  const body = document.body;
  const text = body && body.innerText ? body.innerText.trim() : "";
  return {
    text_chars: Math.min(100000, text.length),
    links: document.querySelectorAll("a[href]").length,
    images: document.querySelectorAll("img,svg,canvas,video").length
  };
}
"""

_FOCUSED_INPUT_SCRIPT = r"""
() => {
  if (!document.hasFocus()) return { focused: false, label: null };
  const element = document.activeElement;
  if (!element) return { focused: false, label: null };
  const tag = element.tagName ? element.tagName.toLowerCase() : "";
  const type = tag === "input"
    ? String(element.getAttribute("type") || "text").toLowerCase()
    : "";
  const textInputTypes = new Set([
    "text", "search", "url", "tel", "email", "password", "number"
  ]);
  const editable = tag === "textarea"
    || (tag === "input" && textInputTypes.has(type))
    || element.isContentEditable;
  if (!editable || element.disabled || element.readOnly) {
    return { focused: false, label: null };
  }
  const labelText = element.labels
    ? Array.from(element.labels).map(item => item.innerText || item.textContent || "").join(" ")
    : "";
  const rawLabel = element.getAttribute("aria-label")
    || labelText
    || element.getAttribute("placeholder")
    || element.getAttribute("name")
    || element.getAttribute("title")
    || null;
  const label = rawLabel
    ? String(rawLabel).replace(/\s+/g, " ").trim().slice(0, 120) || null
    : null;
  return { focused: true, label };
}
"""

_READER_DOCUMENT_SCRIPT = r"""
({ maxBlocks, maxCharacters, maxLinks }) => {
  const clean = value => String(value || "").replace(/\s+/g, " ").trim();
  const root = document.querySelector("main")
    || document.querySelector("article")
    || document.querySelector('[role="main"]')
    || document.body
    || document.documentElement;
  const selector = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre";
  const candidates = root ? Array.from(root.querySelectorAll(selector)) : [];
  const blocks = [];
  const seenText = new Set();
  let totalCharacterCount = 0;
  let remaining = maxCharacters;
  let truncated = candidates.length > 5000;

  for (const element of candidates.slice(0, 5000)) {
    const parentBlock = element.parentElement && element.parentElement.closest(selector);
    if (parentBlock && root.contains(parentBlock)) continue;
    if (element.closest('[hidden],[aria-hidden="true"]')) continue;
    const style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") continue;
    const text = clean(element.innerText || element.textContent);
    if (!text || seenText.has(text)) continue;
    seenText.add(text);
    totalCharacterCount += text.length;
    if (blocks.length >= maxBlocks || remaining <= 0) {
      truncated = true;
      continue;
    }
    let kind = "paragraph";
    const tag = element.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) kind = "heading";
    else if (tag === "li") kind = "list_item";
    else if (tag === "blockquote") kind = "quote";
    else if (tag === "pre") kind = "code";
    let rendered = text;
    if (rendered.length > remaining) {
      rendered = rendered.slice(0, remaining).trim();
      if (rendered.length > 1) rendered = rendered.slice(0, -1) + "…";
      truncated = true;
    }
    if (rendered) blocks.push({ kind, text: rendered });
    remaining -= rendered.length;
  }

  if (!blocks.length && root) {
    const fallback = clean(root.innerText || root.textContent);
    totalCharacterCount = Math.max(totalCharacterCount, fallback.length);
    if (fallback) {
      let rendered = fallback.slice(0, maxCharacters);
      if (fallback.length > rendered.length && rendered.length > 1) {
        rendered = rendered.slice(0, -1) + "…";
        truncated = true;
      }
      blocks.push({ kind: "paragraph", text: rendered });
    }
  }

  const links = [];
  const seenURLs = new Set();
  const anchors = root ? Array.from(root.querySelectorAll("a[href]")) : [];
  let linksTruncated = anchors.length > 2000;
  for (const anchor of anchors.slice(0, 2000)) {
    let parsed;
    try { parsed = new URL(anchor.getAttribute("href"), location.href); }
    catch (_) { continue; }
    if (!new Set(["http:", "https:"]).has(parsed.protocol)) continue;
    if (parsed.username || parsed.password || seenURLs.has(parsed.href)) continue;
    seenURLs.add(parsed.href);
    if (links.length >= maxLinks) {
      linksTruncated = true;
      continue;
    }
    const label = clean(anchor.innerText || anchor.textContent)
      || parsed.hostname
      || "Link";
    links.push({ text: label.slice(0, 160), url: parsed.href.slice(0, 4096) });
  }

  return {
    title: clean(document.title),
    blocks,
    links,
    totalCharacterCount,
    truncated,
    linksTruncated
  };
}
"""


@dataclass
class SecurityEvents:
    navigation_error: Optional[ServiceError] = None
    blocked_subresources: int = 0

    def reset(self) -> None:
        self.navigation_error = None
        self.blocked_subresources = 0


@dataclass
class BrowserSession:
    session_id: str
    context: BrowserContext
    page: Page
    viewport_width: int
    viewport_height: int
    last_access: float
    cdp_session: Optional[CDPSession] = None
    sequence: int = 0
    closed: bool = False
    closing: bool = False
    operation_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    security_events: SecurityEvents = field(default_factory=SecurityEvents)


@dataclass(frozen=True)
class DOMSignals:
    text_chars: int = 0
    links: int = 0
    images: int = 0

    @property
    def has_content(self) -> bool:
        return self.text_chars > 0 or self.links > 0 or self.images > 0


class BrowserRenderer:
    """Owns Chromium and one isolated BrowserContext per Watch session."""

    def __init__(
        self,
        settings: Settings,
        *,
        url_guard: Optional[URLGuard] = None,
        browser: Optional[Browser] = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self.url_guard = url_guard or URLGuard()
        self.encoder = JPEGEncoder(settings.maximum_image_bytes)
        self.inspector = ScreenshotInspector()
        self._clock = clock
        self._browser: Optional[Browser] = browser
        self._owns_browser = browser is None
        self._playwright: Any = None
        self._sessions: Dict[str, BrowserSession] = {}
        self._sessions_lock = asyncio.Lock()
        self._capacity_lock = asyncio.Lock()
        self._open_lock = asyncio.Lock()
        self._opening_sessions = 0
        self._inflight_operations = 0
        self._cleanup_task: Optional[asyncio.Task[None]] = None

    @property
    def browser_ready(self) -> bool:
        if not self.settings.chromium_egress_isolated:
            return False
        if self._browser is None:
            return False
        try:
            return bool(self._browser.is_connected())
        except Exception:
            return False

    async def start(self) -> None:
        if not self.settings.chromium_egress_isolated:
            logger.info(
                "Chromium disabled until deployment egress isolation is confirmed"
            )
            return
        if self._browser is None:
            self._playwright = await async_playwright().start()
            try:
                self._browser = await self._playwright.chromium.launch(
                    headless=True,
                    args=[
                        "--disable-background-networking",
                        "--disable-default-apps",
                        "--disable-dev-shm-usage",
                        "--disable-extensions",
                        "--disable-features=PreconnectToSearch,Prerender2,SpeculationRulesPrefetchProxy",
                        "--disable-sync",
                        "--dns-prefetch-disable",
                        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
                        "--metrics-recording-only",
                        "--no-first-run",
                    ],
                )
            except Exception:
                await self._playwright.stop()
                self._playwright = None
                raise

        if self._browser is not None:
            with contextlib.suppress(Exception):
                self._browser.on(
                    "disconnected",
                    lambda _: asyncio.create_task(self._drop_all_sessions()),
                )
        if self._cleanup_task is None:
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def stop(self) -> None:
        if self._cleanup_task is not None:
            self._cleanup_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._cleanup_task
            self._cleanup_task = None

        await self._drop_all_sessions()
        if self._owns_browser and self._browser is not None:
            with contextlib.suppress(Exception):
                await self._browser.close()
        self._browser = None
        if self._playwright is not None:
            with contextlib.suppress(Exception):
                await self._playwright.stop()
            self._playwright = None

    async def active_session_count(self) -> int:
        await self.cleanup_expired_sessions()
        async with self._sessions_lock:
            return len(self._sessions)

    async def open_session(
        self, url: str, viewport_width: int, viewport_height: int
    ) -> FrameResponse:
        async def serialized_open() -> FrameResponse:
            async with self._open_lock:
                return await self._open_session(url, viewport_width, viewport_height)

        return await self._run_bounded(serialized_open)

    async def read_document(
        self,
        url: str,
        max_blocks: int,
        max_characters: int,
        max_links: int,
    ) -> ExtractedDocument:
        return await self._run_bounded(
            lambda: self._read_document(
                url, max_blocks, max_characters, max_links
            )
        )

    async def scroll_session(self, session_id: str, amount: float) -> FrameResponse:
        async def action(session: BrowserSession) -> str:
            await session.page.mouse.wheel(0, amount * session.viewport_height)
            await self._settle(session.page)
            return "Page scrolled."

        return await self._run_bounded(
            lambda: self._operate_session(session_id, action)
        )

    async def tap_session(self, session_id: str, x: float, y: float) -> FrameResponse:
        async def action(session: BrowserSession) -> str:
            pixel_x = min(
                session.viewport_width - 1,
                max(0.0, x * session.viewport_width),
            )
            pixel_y = min(
                session.viewport_height - 1,
                max(0.0, y * session.viewport_height),
            )
            await session.page.touchscreen.tap(pixel_x, pixel_y)
            await self._settle(session.page)
            return "Page tapped."

        return await self._run_bounded(
            lambda: self._operate_session(session_id, action)
        )

    async def fill_session(
        self, session_id: str, text: str, submit: bool
    ) -> FrameResponse:
        async def action(session: BrowserSession) -> str:
            target = await self._focused_input(session.page)
            if target is None:
                raise ServiceError(
                    code="input_not_focused",
                    message=(
                        "No editable input is focused. Tap a text field before filling it."
                    ),
                    status_code=409,
                    retryable=False,
                )
            frame, _ = target
            locator = frame.locator(":focus").first
            try:
                await locator.fill(text)
            except PlaywrightError as exc:
                raise ServiceError(
                    code="input_not_focused",
                    message=(
                        "The focused input is no longer editable. Tap it and try again."
                    ),
                    status_code=409,
                    retryable=True,
                ) from exc
            if submit:
                await locator.press("Enter")
            await self._settle(session.page)
            return "Text submitted." if submit else "Text filled."

        return await self._run_bounded(
            lambda: self._operate_session(session_id, action)
        )

    async def back_session(self, session_id: str) -> FrameResponse:
        async def action(session: BrowserSession) -> str:
            if not await self._can_go_back(session):
                raise ServiceError(
                    code="cannot_go_back",
                    message="The page has no previous browser history entry.",
                    status_code=409,
                    retryable=False,
                )
            await session.page.go_back(
                wait_until="domcontentloaded",
                timeout=self.settings.navigation_timeout_ms,
            )
            await self._settle(session.page)
            return "Returned to the previous page."

        return await self._run_bounded(
            lambda: self._operate_session(session_id, action)
        )

    async def refresh_session(self, session_id: str) -> FrameResponse:
        async def action(session: BrowserSession) -> str:
            await session.page.reload(
                wait_until="domcontentloaded",
                timeout=self.settings.navigation_timeout_ms,
            )
            await self._settle(session.page)
            return "Page refreshed."

        return await self._run_bounded(
            lambda: self._operate_session(session_id, action)
        )

    async def close_session(self, session_id: str) -> None:
        """Idempotently closes a session and its isolated BrowserContext."""
        async with self._sessions_lock:
            session = self._sessions.get(session_id)
            if session is not None:
                session.closing = True
                self._sessions.pop(session_id, None)
        if session is None:
            return
        async with session.operation_lock:
            await self._close_session(session)

    async def cleanup_expired_sessions(self) -> int:
        cutoff = self._clock() - self.settings.session_ttl_seconds
        expired = []
        async with self._sessions_lock:
            for session_id, session in list(self._sessions.items()):
                if session.last_access <= cutoff and not session.operation_lock.locked():
                    expired.append(self._sessions.pop(session_id))
        for session in expired:
            await self._close_session(session)
        return len(expired)

    async def _open_session(
        self, url: str, viewport_width: int, viewport_height: int
    ) -> FrameResponse:
        self._require_browser()
        validated = await self.url_guard.validate(url)
        await self.cleanup_expired_sessions()
        if self.settings.replace_existing_session:
            await self._close_all_active_sessions()

        async with self._sessions_lock:
            if len(self._sessions) + self._opening_sessions >= self.settings.max_sessions:
                raise ServiceError(
                    code="session_capacity_reached",
                    message="The renderer has reached its active session limit.",
                    status_code=429,
                    retryable=True,
                )
            self._opening_sessions += 1

        context: Optional[BrowserContext] = None
        registered = False
        try:
            browser = self._require_browser()
            context = await browser.new_context(
                viewport={"width": viewport_width, "height": viewport_height},
                screen={"width": viewport_width, "height": viewport_height},
                device_scale_factor=2,
                is_mobile=True,
                has_touch=True,
                accept_downloads=False,
                ignore_https_errors=False,
                java_script_enabled=True,
                service_workers="block",
                user_agent=_MOBILE_CHROME_USER_AGENT,
                locale="zh-CN",
                color_scheme="light",
                extra_http_headers={
                    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
                },
            )
            security_events = SecurityEvents()
            await context.route(
                "**/*", self._route_handler(security_events)
            )
            await context.route_web_socket(
                "**/*", self._websocket_handler(security_events)
            )
            page = await context.new_page()
            page.set_default_navigation_timeout(self.settings.navigation_timeout_ms)
            page.set_default_timeout(self.settings.navigation_timeout_ms)
            cdp_session: Optional[CDPSession] = None
            with contextlib.suppress(PlaywrightError):
                cdp_session = await context.new_cdp_session(page)
            session = BrowserSession(
                session_id=uuid.uuid4().hex,
                context=context,
                page=page,
                viewport_width=viewport_width,
                viewport_height=viewport_height,
                last_access=self._clock(),
                cdp_session=cdp_session,
                security_events=security_events,
            )
            session.security_events.reset()
            try:
                await page.goto(
                    validated.url,
                    wait_until="domcontentloaded",
                    timeout=self.settings.navigation_timeout_ms,
                )
            except PlaywrightError:
                self._raise_security_error(session)
                raise
            await self._settle(page)
            self._raise_security_error(session)
            response = await self._build_frame(session, "Page opened.")
            async with self._sessions_lock:
                self._sessions[session.session_id] = session
            registered = True
            return response
        finally:
            async with self._sessions_lock:
                self._opening_sessions -= 1
            if context is not None and not registered:
                with contextlib.suppress(Exception):
                    await context.close()

    async def _read_document(
        self,
        url: str,
        max_blocks: int,
        max_characters: int,
        max_links: int,
    ) -> ExtractedDocument:
        browser = self._require_browser()
        validated = await self.url_guard.validate(url)
        context: Optional[BrowserContext] = None
        try:
            context = await browser.new_context(
                viewport={"width": 396, "height": 484},
                screen={"width": 396, "height": 484},
                device_scale_factor=2,
                is_mobile=True,
                has_touch=True,
                accept_downloads=False,
                ignore_https_errors=False,
                java_script_enabled=True,
                service_workers="block",
                user_agent=_MOBILE_CHROME_USER_AGENT,
                locale="zh-CN",
                color_scheme="light",
                extra_http_headers={
                    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
                },
            )
            security_events = SecurityEvents()
            await context.route("**/*", self._route_handler(security_events))
            await context.route_web_socket(
                "**/*", self._websocket_handler(security_events)
            )
            page = await context.new_page()
            page.set_default_navigation_timeout(self.settings.navigation_timeout_ms)
            page.set_default_timeout(self.settings.navigation_timeout_ms)
            try:
                await page.goto(
                    validated.url,
                    wait_until="domcontentloaded",
                    timeout=self.settings.navigation_timeout_ms,
                )
            except PlaywrightError:
                if security_events.navigation_error is not None:
                    raise security_events.navigation_error
                raise
            await self._settle(page)
            await page.wait_for_timeout(max(800, self.settings.settle_delay_ms))
            if security_events.navigation_error is not None:
                raise security_events.navigation_error
            final_url = (await self.url_guard.validate(page.url)).url
            result = await page.evaluate(
                _READER_DOCUMENT_SCRIPT,
                {
                    "maxBlocks": max_blocks,
                    "maxCharacters": max_characters,
                    "maxLinks": max_links,
                },
            )
            if not isinstance(result, dict):
                raise ServiceError(
                    code="reader_extraction_failed",
                    message="Chromium returned an invalid readable document.",
                    status_code=502,
                    retryable=True,
                )

            blocks = []
            for item in result.get("blocks", []):
                if not isinstance(item, dict):
                    continue
                kind = str(item.get("kind", "paragraph"))
                if kind not in {"heading", "paragraph", "list_item", "quote", "code"}:
                    kind = "paragraph"
                text = str(item.get("text", "")).strip()[:20_000]
                if text:
                    blocks.append(ReadBlock(kind=kind, text=text))
            links = []
            for item in result.get("links", []):
                if not isinstance(item, dict):
                    continue
                text = str(item.get("text", "")).strip()[:160]
                target = str(item.get("url", "")).strip()[:4096]
                safe_target = safe_link(target)
                if text and safe_target:
                    links.append(ReadLink(text=text, url=safe_target))
            try:
                total_characters = max(
                    0, int(result.get("totalCharacterCount", 0))
                )
            except (TypeError, ValueError):
                total_characters = sum(len(item.text) for item in blocks)
            title = str(result.get("title", "")).strip()
            return finalize_document(
                final_url=final_url,
                title=title,
                blocks=blocks,
                links=links,
                max_blocks=max_blocks,
                max_characters=max_characters,
                max_links=max_links,
                source="browser",
                blocked_subresources=security_events.blocked_subresources,
                inherently_truncated=bool(result.get("truncated", False)),
                links_inherently_truncated=bool(
                    result.get("linksTruncated", False)
                ),
                reported_total_characters=total_characters,
            )
        finally:
            if context is not None:
                with contextlib.suppress(Exception):
                    await context.close()

    async def _operate_session(
        self,
        session_id: str,
        action: Callable[[BrowserSession], Awaitable[str]],
    ) -> FrameResponse:
        self._require_browser()
        session = await self._get_session(session_id)
        async with session.operation_lock:
            if session.closed or session.closing:
                raise self._session_gone()
            if self._clock() - session.last_access >= self.settings.session_ttl_seconds:
                await self._remove_session(session)
                raise ServiceError(
                    code="session_expired",
                    message="The browser session expired. Open the page again.",
                    status_code=410,
                    retryable=False,
                )

            session.last_access = self._clock()
            session.security_events.reset()
            try:
                message = await action(session)
            except PlaywrightError:
                self._raise_security_error(session)
                raise
            self._raise_security_error(session)
            response = await self._build_frame(session, message)
            self._raise_security_error(session)
            session.last_access = self._clock()
            return response

    async def _build_frame(
        self, session: BrowserSession, message: str
    ) -> FrameResponse:
        # Routes cover network requests; this final check also rejects non-network
        # navigations such as data:, blob:, about:, or browser error pages.
        await self.url_guard.validate(session.page.url)
        screenshot = await self._capture_nonblank_screenshot(session)
        encoded = self.encoder.encode(screenshot)
        focused = await self._focused_input(session.page)
        progress_value = await session.page.evaluate(_SCROLL_PROGRESS_SCRIPT)
        try:
            scroll_progress = min(1.0, max(0.0, float(progress_value)))
        except (TypeError, ValueError):
            scroll_progress = 0.0
        title = (await session.page.title()).strip()[:256]
        can_go_back = await self._can_go_back(session)
        session.sequence += 1

        if session.security_events.blocked_subresources:
            count = session.security_events.blocked_subresources
            message = f"{message} Blocked {count} unsafe page resource(s)."

        return FrameResponse(
            session_id=session.session_id,
            sequence=session.sequence,
            url=session.page.url[:4096],
            title=title,
            can_go_back=can_go_back,
            scroll_progress=scroll_progress,
            image_base64=base64.b64encode(encoded).decode("ascii"),
            message=message,
            focused_input=focused is not None,
            focused_input_label=focused[1] if focused is not None else None,
        )

    async def _capture_nonblank_screenshot(self, session: BrowserSession) -> bytes:
        attempts = self.settings.blank_frame_retries + 1
        last_tone = "blank"
        for attempt in range(attempts):
            screenshot = await session.page.screenshot(
                type="png",
                full_page=False,
                scale="css",
                animations="disabled",
                caret="hide",
            )
            signal = self.inspector.inspect(screenshot)
            if not signal.is_near_blank:
                return screenshot
            last_tone = signal.tone or "blank"
            dom = await self._dom_signals(session.page)
            if not dom.has_content:
                raise ServiceError(
                    code="empty_page",
                    message="The target page has no visible page or DOM content.",
                    status_code=502,
                    retryable=False,
                )
            if attempt < attempts - 1:
                await session.page.wait_for_timeout(
                    self.settings.blank_frame_retry_delay_ms
                )

        raise ServiceError(
            code="blank_frame",
            message=(
                f"Chromium repeatedly captured a near-{last_tone} blank frame "
                "even though the page reported DOM content."
            ),
            status_code=502,
            retryable=True,
        )

    async def _dom_signals(self, page: Page) -> DOMSignals:
        text_chars = 0
        links = 0
        images = 0
        for frame in page.frames:
            try:
                result = await frame.evaluate(_DOM_SIGNAL_SCRIPT)
            except PlaywrightError:
                continue
            if not isinstance(result, dict):
                continue
            text_chars += max(0, int(result.get("text_chars", 0)))
            links += max(0, int(result.get("links", 0)))
            images += max(0, int(result.get("images", 0)))
        return DOMSignals(text_chars=text_chars, links=links, images=images)

    async def _focused_input(
        self, page: Page
    ) -> Optional[Tuple[Frame, Optional[str]]]:
        for frame in page.frames:
            try:
                result = await frame.evaluate(_FOCUSED_INPUT_SCRIPT)
            except PlaywrightError:
                continue
            if isinstance(result, dict) and result.get("focused") is True:
                raw_label = result.get("label")
                label = str(raw_label)[:120] if raw_label else None
                return frame, label
        return None

    async def _can_go_back(self, session: BrowserSession) -> bool:
        if session.cdp_session is not None:
            try:
                history = await session.cdp_session.send("Page.getNavigationHistory")
                index = int(history.get("currentIndex", 0))
                entries = history.get("entries", [])
                return any(
                    urlsplit(str(item.get("url", ""))).scheme in {"http", "https"}
                    for item in entries[:index]
                )
            except (PlaywrightError, TypeError, ValueError):
                pass
        result = await session.page.evaluate("() => window.history.length > 1")
        return bool(result)

    async def _settle(self, page: Page) -> None:
        try:
            await page.wait_for_load_state("domcontentloaded", timeout=2_000)
        except PlaywrightTimeoutError:
            pass
        await page.wait_for_timeout(self.settings.settle_delay_ms)

    def _route_handler(
        self, events: SecurityEvents
    ) -> Callable[[Route, Request], Awaitable[None]]:
        async def handle(route: Route, request: Request) -> None:
            try:
                await self.url_guard.validate(request.url)
            except ServiceError as error:
                if request.is_navigation_request():
                    events.navigation_error = error
                else:
                    events.blocked_subresources += 1
                with contextlib.suppress(PlaywrightError):
                    await route.abort("blockedbyclient")
                return
            await route.continue_()

        return handle

    @staticmethod
    def _websocket_handler(
        events: SecurityEvents,
    ) -> Callable[[WebSocketRoute], Awaitable[None]]:
        async def handle(websocket: WebSocketRoute) -> None:
            events.blocked_subresources += 1
            await websocket.close(
                code=1008,
                reason="WatchBrowser permits HTTP(S) page resources only.",
            )

        return handle

    async def _get_session(self, session_id: str) -> BrowserSession:
        async with self._sessions_lock:
            session = self._sessions.get(session_id)
        if session is None:
            raise self._session_gone()
        return session

    async def _remove_session(self, session: BrowserSession) -> None:
        async with self._sessions_lock:
            current = self._sessions.get(session.session_id)
            if current is session:
                self._sessions.pop(session.session_id, None)
        await self._close_session(session)

    async def _drop_all_sessions(self) -> None:
        async with self._sessions_lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            session.closing = True
            await self._close_session(session)

    async def _close_all_active_sessions(self) -> None:
        async with self._sessions_lock:
            session_ids = list(self._sessions)
        for session_id in session_ids:
            await self.close_session(session_id)

    async def _close_session(self, session: BrowserSession) -> None:
        if session.closed:
            return
        session.closed = True
        with contextlib.suppress(Exception):
            await session.context.close()

    async def _cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(self.settings.cleanup_interval_seconds)
            try:
                await self.cleanup_expired_sessions()
            except Exception:
                logger.exception("Session cleanup failed")

    @asynccontextmanager
    async def _operation_slot(self) -> AsyncIterator[None]:
        async with self._capacity_lock:
            if self._inflight_operations >= self.settings.max_concurrent_operations:
                raise ServiceError(
                    code="renderer_busy",
                    message="The renderer is busy. Try again shortly.",
                    status_code=429,
                    retryable=True,
                )
            self._inflight_operations += 1
        try:
            yield
        finally:
            async with self._capacity_lock:
                self._inflight_operations -= 1

    async def _run_bounded(
        self, operation: Callable[[], Awaitable[ResultType]]
    ) -> ResultType:
        async with self._operation_slot():
            try:
                return await asyncio.wait_for(
                    operation(), timeout=self.settings.operation_timeout_seconds
                )
            except ServiceError:
                raise
            except asyncio.TimeoutError as exc:
                raise ServiceError(
                    code="operation_timeout",
                    message="The browser operation timed out. Try again.",
                    status_code=504,
                    retryable=True,
                ) from exc
            except PlaywrightTimeoutError as exc:
                raise ServiceError(
                    code="page_timeout",
                    message="The target page did not finish the browser operation in time.",
                    status_code=504,
                    retryable=True,
                ) from exc
            except PlaywrightError as exc:
                raise ServiceError(
                    code="browser_operation_failed",
                    message="Chromium could not complete the page operation.",
                    status_code=502,
                    retryable=True,
                ) from exc

    def _require_browser(self) -> Browser:
        if not self.settings.chromium_egress_isolated:
            raise ServiceError(
                code="renderer_egress_isolation_required",
                message=(
                    "Chromium is disabled until the deployment confirms network-level "
                    "egress isolation."
                ),
                status_code=503,
                retryable=False,
            )
        if not self.browser_ready or self._browser is None:
            raise ServiceError(
                code="renderer_unavailable",
                message="Chromium is not ready.",
                status_code=503,
                retryable=True,
            )
        return self._browser

    @staticmethod
    def _raise_security_error(session: BrowserSession) -> None:
        if session.security_events.navigation_error is not None:
            raise session.security_events.navigation_error

    @staticmethod
    def _session_gone() -> ServiceError:
        return ServiceError(
            code="session_gone",
            message="The browser session is unavailable or expired. Open the page again.",
            status_code=410,
            retryable=False,
        )
