import asyncio

import httpx
import pytest

from app.config import Settings
from app.errors import ServiceError
from app.reader import ReaderService, finalize_document
from app.schemas import ReadBlock, ReadLink, ReadRequest
from app.security import URLGuard


async def public_resolver(host, _port):
    if host == "other.test":
        return ["1.1.1.1"]
    return ["93.184.216.34"]


def settings(**overrides):
    values = {
        "bearer_token": "test-token",
        "reader_timeout_seconds": 3,
        "reader_maximum_response_bytes": 20_000,
        "reader_max_redirects": 3,
        "reader_dynamic_threshold_characters": 80,
    }
    values.update(overrides)
    return Settings(**values)


class FakeDynamicReader:
    def __init__(self, *, ready=True, error=None):
        self.browser_ready = ready
        self.error = error
        self.calls = []

    async def read_document(self, url, max_blocks, max_characters, max_links):
        self.calls.append((url, max_blocks, max_characters, max_links))
        if self.error:
            raise self.error
        return finalize_document(
            final_url="https://example.test/app",
            title="Rendered title",
            blocks=[ReadBlock(kind="paragraph", text="JavaScript rendered content")],
            links=[ReadLink(text="Next", url="https://example.test/next")],
            max_blocks=max_blocks,
            max_characters=max_characters,
            max_links=max_links,
            source="browser",
            blocked_subresources=2,
        )


def run(coroutine):
    return asyncio.run(coroutine)


def service(handler, *, dynamic=None, configured=None):
    return ReaderService(
        configured or settings(),
        url_guard=URLGuard(resolver=public_resolver),
        dynamic_reader=dynamic,
        transport=httpx.MockTransport(handler),
    )


def test_static_html_is_structured_and_does_not_start_chromium():
    html = """
    <html><head><title> Example page </title><script>ignored()</script></head>
    <body><main>
      <h1>Heading</h1><p>Hello <strong>watch</strong>.</p>
      <ul><li>First item</li></ul>
      <a href="/next">Continue</a>
      <a href="http://127.0.0.1/private">unsafe</a>
      <a href="javascript:alert(1)">script</a>
    </main></body></html>
    """
    dynamic = FakeDynamicReader()
    reader = service(
        lambda request: httpx.Response(
            200,
            headers={"Content-Type": "text/html; charset=utf-8"},
            content=html.encode(),
            request=request,
        ),
        dynamic=dynamic,
    )

    result = run(reader.read(ReadRequest(url="https://example.test/start")))

    assert result.source == "static"
    assert result.final_url == "https://example.test/start"
    assert result.title == "Example page"
    assert [(item.kind, item.text) for item in result.blocks] == [
        ("heading", "Heading"),
        ("paragraph", "Hello watch ."),
        ("list_item", "First item"),
    ]
    assert [item.url for item in result.links] == ["https://example.test/next"]
    assert result.blocked_subresources == 0
    assert dynamic.calls == []


def test_script_shell_falls_back_to_temporary_browser_reader():
    dynamic = FakeDynamicReader()
    reader = service(
        lambda request: httpx.Response(
            200,
            headers={"Content-Type": "text/html"},
            content=b"<html><title>Shell</title><body><div id='app'></div><script>boot()</script></body></html>",
            request=request,
        ),
        dynamic=dynamic,
    )

    result = run(reader.read(ReadRequest(url="https://example.test/app")))

    assert result.source == "browser"
    assert result.title == "Rendered title"
    assert result.blocks[0].text == "JavaScript rendered content"
    assert result.blocked_subresources == 2
    assert dynamic.calls == [("https://example.test/app", 40, 12_000, 30)]


def test_prefer_dynamic_still_keeps_static_as_recovery_result():
    failure = ServiceError(
        code="renderer_unavailable",
        message="offline",
        status_code=503,
        retryable=True,
    )
    dynamic = FakeDynamicReader(error=failure)
    reader = service(
        lambda request: httpx.Response(
            200,
            headers={"Content-Type": "text/plain"},
            content="static answer".encode(),
            request=request,
        ),
        dynamic=dynamic,
    )

    result = run(
        reader.read(
            ReadRequest(url="https://example.test/file", prefer_dynamic=True)
        )
    )

    assert result.source == "static"
    assert result.blocks[0].text == "static answer"
    assert len(dynamic.calls) == 1


def test_every_redirect_is_ssrf_checked_before_transport_receives_it():
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(
            302,
            headers={"Location": "http://127.0.0.1/metadata"},
            request=request,
        )

    reader = service(handler)
    with pytest.raises(ServiceError) as captured:
        run(reader.read(ReadRequest(url="https://example.test/start")))

    assert captured.value.code == "url_blocked"
    assert calls == ["https://example.test/start"]


def test_public_redirect_is_followed_and_final_url_is_reported():
    def handler(request):
        if request.url.host == "example.test":
            return httpx.Response(
                302,
                headers={"Location": "https://other.test/article"},
                request=request,
            )
        return httpx.Response(
            200,
            headers={"Content-Type": "text/plain"},
            content=b"redirected text",
            request=request,
        )

    result = run(
        service(handler).read(ReadRequest(url="https://example.test/start"))
    )
    assert result.final_url == "https://other.test/article"
    assert result.blocks[0].text == "redirected text"


def test_streaming_limit_rejects_oversized_document_before_parsing():
    configured = settings(reader_maximum_response_bytes=100)
    reader = service(
        lambda request: httpx.Response(
            200,
            headers={"Content-Type": "text/html"},
            content=b"x" * 101,
            request=request,
        ),
        configured=configured,
    )
    with pytest.raises(ServiceError) as captured:
        run(reader.read(ReadRequest(url="https://example.test/large")))
    assert captured.value.code == "web_response_too_large"
    assert captured.value.status_code == 413


def test_gb18030_html_is_decoded_and_output_limits_are_explicit():
    html = (
        "<html><head><meta charset='gb18030'><title>中文标题</title></head>"
        "<body><p>第一段文字很长</p><p>第二段文字很长</p>"
        "<a href='/1'>一</a><a href='/2'>二</a></body></html>"
    ).encode("gb18030")
    result = run(
        service(
            lambda request: httpx.Response(
                200,
                headers={"Content-Type": "text/html; charset=gb18030"},
                content=html,
                request=request,
            )
        ).read(
            ReadRequest(
                url="https://example.test/",
                max_blocks=1,
                max_characters=500,
                max_links=1,
            )
        )
    )
    assert result.title == "中文标题"
    assert result.blocks[0].text == "第一段文字很长"
    assert result.truncated is True
    assert result.links_truncated is True
    assert result.total_character_count > result.character_count


def test_js_shell_without_chromium_reports_specific_retryable_error():
    dynamic = FakeDynamicReader(ready=False)
    reader = service(
        lambda request: httpx.Response(
            200,
            headers={"Content-Type": "text/html"},
            content=b"<html><body><script>boot()</script></body></html>",
            request=request,
        ),
        dynamic=dynamic,
    )
    with pytest.raises(ServiceError) as captured:
        run(reader.read(ReadRequest(url="https://example.test/app")))
    assert captured.value.code == "dynamic_reader_unavailable"
    assert captured.value.retryable is True
