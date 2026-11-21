import asyncio
import io

import pytest
from PIL import Image, ImageDraw

from app.config import Settings
from app.errors import ServiceError
from app.renderer import BrowserRenderer, BrowserSession, SecurityEvents
from app.security import URLGuard


def png(color="white", varied=False):
    image = Image.new("RGB", (396, 484), color)
    if varied:
        ImageDraw.Draw(image).rectangle((30, 60, 360, 420), fill=(25, 100, 190))
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def settings(**overrides):
    values = {
        "bearer_token": "test-token",
        "session_ttl_seconds": 30,
        "max_sessions": 8,
        "max_concurrent_operations": 4,
        "operation_timeout_seconds": 5,
        "navigation_timeout_ms": 1_000,
        "maximum_image_bytes": 48_000,
        "cleanup_interval_seconds": 60,
        "blank_frame_retries": 3,
        "blank_frame_retry_delay_ms": 1,
        "settle_delay_ms": 1,
        "replace_existing_session": False,
        "chromium_egress_isolated": True,
    }
    values.update(overrides)
    return Settings(**values)


async def public_resolver(_host, _port):
    return ["93.184.216.34"]


class FakeLocator:
    def __init__(self):
        self.filled = None
        self.pressed = []

    @property
    def first(self):
        return self

    async def fill(self, text):
        self.filled = text

    async def press(self, key):
        self.pressed.append(key)


class FakeFrame:
    def __init__(self, *, dom_content=True, focused=False):
        self.dom_content = dom_content
        self.focused = focused
        self.locator_value = FakeLocator()

    async def evaluate(self, script):
        if "document.hasFocus" in script:
            return {"focused": self.focused, "label": "Search" if self.focused else None}
        if "text_chars" in script:
            if self.dom_content:
                return {"text_chars": 20, "links": 1, "images": 0}
            return {"text_chars": 0, "links": 0, "images": 0}
        raise AssertionError(f"unexpected frame script: {script[:40]}")

    def locator(self, selector):
        assert selector == ":focus"
        return self.locator_value


class FakeMouse:
    def __init__(self):
        self.clicks = []
        self.wheels = []

    async def click(self, x, y):
        self.clicks.append((x, y))

    async def wheel(self, x, y):
        self.wheels.append((x, y))


class FakeTouchscreen:
    def __init__(self):
        self.taps = []

    async def tap(self, x, y):
        self.taps.append((x, y))


class FakePage:
    def __init__(self, screenshots=None, *, dom_content=True, focused=False):
        self.url = "about:blank"
        self.frame = FakeFrame(dom_content=dom_content, focused=focused)
        self.frames = [self.frame]
        self.mouse = FakeMouse()
        self.touchscreen = FakeTouchscreen()
        self._screenshots = list(screenshots or [png(varied=True)])
        self.screenshot_calls = 0
        self.screenshot_options = []
        self.timeout_waits = []

    def set_default_navigation_timeout(self, _timeout):
        pass

    def set_default_timeout(self, _timeout):
        pass

    async def goto(self, url, **_kwargs):
        self.url = url

    async def reload(self, **_kwargs):
        return None

    async def go_back(self, **_kwargs):
        return None

    async def wait_for_load_state(self, *_args, **_kwargs):
        return None

    async def wait_for_timeout(self, milliseconds):
        self.timeout_waits.append(milliseconds)

    async def screenshot(self, **_kwargs):
        self.screenshot_calls += 1
        self.screenshot_options.append(_kwargs)
        if len(self._screenshots) > 1:
            return self._screenshots.pop(0)
        return self._screenshots[0]

    async def evaluate(self, script, argument=None):
        if "maxBlocks" in script:
            assert argument == {
                "maxBlocks": 4,
                "maxCharacters": 500,
                "maxLinks": 3,
            }
            return {
                "title": "Rendered article",
                "blocks": [
                    {"kind": "heading", "text": "Live heading"},
                    {"kind": "paragraph", "text": "Live paragraph"},
                ],
                "links": [
                    {"text": "Next", "url": "https://mobile.test/next"}
                ],
                "totalCharacterCount": 26,
                "truncated": False,
                "linksTruncated": False,
            }
        if "scrollingElement" in script:
            return 0.0
        if "history.length" in script:
            return False
        raise AssertionError(f"unexpected page script: {script[:40]}")

    async def title(self):
        return "Example"


class FakeCDP:
    async def send(self, method):
        assert method == "Page.getNavigationHistory"
        return {"currentIndex": 0, "entries": [{"url": "https://example.test/"}]}


class FakeContext:
    def __init__(self, page=None):
        self.page = page or FakePage()
        self.route_handler = None
        self.websocket_handler = None
        self.closed = False

    async def route(self, pattern, handler):
        assert pattern == "**/*"
        self.route_handler = handler

    async def route_web_socket(self, pattern, handler):
        assert pattern == "**/*"
        self.websocket_handler = handler

    async def new_page(self):
        return self.page

    async def new_cdp_session(self, _page):
        return FakeCDP()

    async def close(self):
        self.closed = True


class FakeBrowser:
    def __init__(self):
        self.contexts = []
        self.context_options = []
        self.connected = True

    def is_connected(self):
        return self.connected

    def on(self, *_args):
        pass

    async def new_context(self, **_kwargs):
        context = FakeContext()
        self.contexts.append(context)
        self.context_options.append(_kwargs)
        return context

    async def close(self):
        self.connected = False


class FakeRoute:
    def __init__(self):
        self.aborted = None
        self.continued = False

    async def abort(self, reason):
        self.aborted = reason

    async def continue_(self):
        self.continued = True


class FakeRequest:
    def __init__(self, url, navigation):
        self.url = url
        self.navigation = navigation

    def is_navigation_request(self):
        return self.navigation


class FakeWebSocket:
    def __init__(self):
        self.closed = None

    async def close(self, *, code, reason):
        self.closed = (code, reason)


def test_open_uses_distinct_contexts_and_close_releases_capacity():
    async def scenario():
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(max_sessions=2),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
        )
        first = await renderer.open_session("https://one.test/", 396, 484)
        second = await renderer.open_session("https://two.test/", 396, 484)
        assert first.session_id != second.session_id
        assert len(browser.contexts) == 2
        assert browser.contexts[0] is not browser.contexts[1]
        assert await renderer.active_session_count() == 2

        await renderer.close_session(first.session_id)
        await renderer.close_session(first.session_id)
        assert browser.contexts[0].closed is True
        assert await renderer.active_session_count() == 1
        replacement = await renderer.open_session("https://three.test/", 396, 484)
        assert replacement.sequence == 1
        await renderer.stop()

    asyncio.run(scenario())


def test_chromium_fails_closed_without_egress_isolation_confirmation():
    async def scenario():
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(chromium_egress_isolated=False),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
        )
        assert renderer.browser_ready is False
        await renderer.start()
        with pytest.raises(ServiceError) as captured:
            await renderer.open_session("https://example.test/", 396, 484)
        assert captured.value.code == "renderer_egress_isolation_required"
        assert captured.value.retryable is False
        assert browser.contexts == []
        await renderer.stop()

    asyncio.run(scenario())


def test_mobile_context_keeps_css_screenshot_and_tap_contract():
    async def scenario():
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
        )
        opened = await renderer.open_session("https://mobile.test/", 396, 484)
        options = browser.context_options[0]
        assert options["viewport"] == {"width": 396, "height": 484}
        assert options["screen"] == {"width": 396, "height": 484}
        assert options["device_scale_factor"] == 2
        assert options["is_mobile"] is True
        assert options["has_touch"] is True
        assert options["locale"] == "zh-CN"
        assert "Android" in options["user_agent"]
        assert "Mobile" in options["user_agent"]
        assert "Apple Watch" not in options["user_agent"]

        page = browser.contexts[0].page
        assert page.screenshot_options[-1]["scale"] == "css"
        assert page.screenshot_options[-1]["full_page"] is False

        response = await renderer.tap_session(opened.session_id, 0.5, 0.25)
        assert page.touchscreen.taps == [(198.0, 121.0)]
        assert page.mouse.clicks == []
        assert response.sequence == 2
        assert response.session_id == opened.session_id
        await renderer.stop()

    asyncio.run(scenario())


def test_dynamic_reader_uses_temporary_secured_context_and_closes_it():
    async def scenario():
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
        )
        document = await renderer.read_document(
            "https://mobile.test/article", 4, 500, 3
        )
        assert document.source == "browser"
        assert document.final_url == "https://mobile.test/article"
        assert document.title == "Rendered article"
        assert [item.text for item in document.blocks] == [
            "Live heading",
            "Live paragraph",
        ]
        assert document.links[0].url == "https://mobile.test/next"
        assert browser.contexts[0].route_handler is not None
        assert browser.contexts[0].websocket_handler is not None
        assert browser.contexts[0].closed is True
        assert await renderer.active_session_count() == 0
        await renderer.stop()

    asyncio.run(scenario())


def test_session_limit_returns_429_until_a_context_is_closed():
    async def scenario():
        renderer = BrowserRenderer(
            settings(max_sessions=1),
            browser=FakeBrowser(),
            url_guard=URLGuard(resolver=public_resolver),
        )
        opened = await renderer.open_session("https://one.test/", 396, 484)
        with pytest.raises(ServiceError) as captured:
            await renderer.open_session("https://two.test/", 396, 484)
        assert captured.value.code == "session_capacity_reached"
        assert captured.value.status_code == 429
        await renderer.close_session(opened.session_id)
        assert (await renderer.open_session("https://two.test/", 396, 484)).sequence == 1
        await renderer.stop()

    asyncio.run(scenario())


def test_new_open_replaces_old_session_by_default_policy():
    async def scenario():
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(replace_existing_session=True),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
        )
        first = await renderer.open_session("https://one.test/", 396, 484)
        second = await renderer.open_session("https://two.test/", 396, 484)
        assert first.session_id != second.session_id
        assert browser.contexts[0].closed is True
        assert await renderer.active_session_count() == 1
        with pytest.raises(ServiceError) as captured:
            await renderer.scroll_session(first.session_id, 0.72)
        assert captured.value.status_code == 410
        await renderer.stop()

    asyncio.run(scenario())


def test_expired_session_returns_410_and_closes_context():
    async def scenario():
        now = [0.0]
        browser = FakeBrowser()
        renderer = BrowserRenderer(
            settings(session_ttl_seconds=5),
            browser=browser,
            url_guard=URLGuard(resolver=public_resolver),
            clock=lambda: now[0],
        )
        opened = await renderer.open_session("https://one.test/", 396, 484)
        now[0] = 6.0
        with pytest.raises(ServiceError) as captured:
            await renderer.scroll_session(opened.session_id, 0.72)
        assert captured.value.status_code == 410
        assert captured.value.code == "session_expired"
        assert browser.contexts[0].closed is True
        await renderer.stop()

    asyncio.run(scenario())


def test_fill_requires_focus_then_fills_and_submits_current_input():
    async def scenario():
        renderer = BrowserRenderer(
            settings(),
            browser=FakeBrowser(),
            url_guard=URLGuard(resolver=public_resolver),
        )
        opened = await renderer.open_session("https://one.test/", 396, 484)
        session = renderer._sessions[opened.session_id]
        with pytest.raises(ServiceError) as captured:
            await renderer.fill_session(opened.session_id, "query", True)
        assert captured.value.code == "input_not_focused"
        assert captured.value.status_code == 409

        session.page.frame.focused = True
        response = await renderer.fill_session(opened.session_id, "query", True)
        assert session.page.frame.locator_value.filled == "query"
        assert session.page.frame.locator_value.pressed == ["Enter"]
        assert response.sequence == 2
        assert response.focused_input is True
        assert response.focused_input_label == "Search"
        await renderer.stop()

    asyncio.run(scenario())


def test_non_http_main_frame_navigation_is_never_returned_as_success():
    async def scenario():
        renderer = BrowserRenderer(
            settings(),
            browser=FakeBrowser(),
            url_guard=URLGuard(resolver=public_resolver),
        )
        opened = await renderer.open_session("https://one.test/", 396, 484)
        renderer._sessions[opened.session_id].page.url = "data:text/html,blocked"
        with pytest.raises(ServiceError) as captured:
            await renderer.scroll_session(opened.session_id, 0.72)
        assert captured.value.code == "url_blocked"
        await renderer.stop()

    asyncio.run(scenario())


def test_blank_screenshot_with_dom_retries_then_succeeds():
    async def scenario():
        page = FakePage(
            screenshots=[png("white"), png("white"), png(varied=True)],
            dom_content=True,
        )
        context = FakeContext(page)
        renderer = BrowserRenderer(settings(), browser=FakeBrowser())
        session = BrowserSession("id", context, page, 396, 484, 0)
        result = await renderer._capture_nonblank_screenshot(session)
        assert result == png(varied=True)
        assert page.screenshot_calls == 3
        assert page.timeout_waits == [1, 1]

    asyncio.run(scenario())


def test_blank_screenshot_and_empty_dom_returns_empty_page():
    async def scenario():
        page = FakePage(screenshots=[png("black")], dom_content=False)
        renderer = BrowserRenderer(settings(), browser=FakeBrowser())
        session = BrowserSession("id", FakeContext(page), page, 396, 484, 0)
        with pytest.raises(ServiceError) as captured:
            await renderer._capture_nonblank_screenshot(session)
        assert captured.value.code == "empty_page"
        assert page.screenshot_calls == 1

    asyncio.run(scenario())


def test_blank_screenshot_with_dom_exhausts_three_retries():
    async def scenario():
        page = FakePage(screenshots=[png("white")], dom_content=True)
        renderer = BrowserRenderer(settings(blank_frame_retries=3), browser=FakeBrowser())
        session = BrowserSession("id", FakeContext(page), page, 396, 484, 0)
        with pytest.raises(ServiceError) as captured:
            await renderer._capture_nonblank_screenshot(session)
        assert captured.value.code == "blank_frame"
        assert captured.value.retryable is True
        assert page.screenshot_calls == 4

    asyncio.run(scenario())


def test_route_guard_blocks_private_navigation_and_subresource():
    async def scenario():
        renderer = BrowserRenderer(
            settings(),
            browser=FakeBrowser(),
            url_guard=URLGuard(resolver=public_resolver),
        )
        events = SecurityEvents()
        handler = renderer._route_handler(events)

        public_route = FakeRoute()
        await handler(public_route, FakeRequest("https://public.test/a.js", False))
        assert public_route.continued is True

        resource_route = FakeRoute()
        await handler(resource_route, FakeRequest("http://127.0.0.1/a.js", False))
        assert resource_route.aborted == "blockedbyclient"
        assert events.blocked_subresources == 1

        navigation_route = FakeRoute()
        await handler(
            navigation_route,
            FakeRequest("http://169.254.169.254/latest/meta-data/", True),
        )
        assert navigation_route.aborted == "blockedbyclient"
        assert events.navigation_error.code == "url_blocked"

        websocket = FakeWebSocket()
        await renderer._websocket_handler(events)(websocket)
        assert websocket.closed[0] == 1008
        assert events.blocked_subresources == 2

    asyncio.run(scenario())


def test_global_concurrency_limit_rejects_instead_of_queueing():
    async def scenario():
        renderer = BrowserRenderer(
            settings(max_concurrent_operations=1), browser=FakeBrowser()
        )
        async with renderer._operation_slot():
            with pytest.raises(ServiceError) as captured:
                async with renderer._operation_slot():
                    pass
        assert captured.value.code == "renderer_busy"
        assert captured.value.status_code == 429

    asyncio.run(scenario())
