from fastapi.testclient import TestClient

from app.config import Settings
from app.errors import ServiceError
from app.main import create_app
from app.renderer import BrowserRenderer
from app.schemas import (
    AskResponse,
    FrameResponse,
    ReadBlock,
    ReadResponse,
)


def frame(session_id="session123", sequence=1):
    return FrameResponse(
        session_id=session_id,
        sequence=sequence,
        url="https://example.com/",
        title="Example",
        can_go_back=False,
        scroll_progress=0.0,
        image_base64="/9j/2Q==",
        message="ok",
        focused_input=False,
        focused_input_label=None,
    )


class FakeRenderer:
    def __init__(self):
        self.browser_ready = True
        self.started = False
        self.stopped = False
        self.open_arguments = None
        self.closed_session_id = None

    async def start(self):
        self.started = True

    async def stop(self):
        self.stopped = True

    async def active_session_count(self):
        return 2

    async def open_session(self, url, width, height):
        self.open_arguments = (url, width, height)
        return frame()

    async def scroll_session(self, session_id, amount):
        return frame(session_id, 2)

    async def tap_session(self, session_id, x, y):
        return frame(session_id, 2)

    async def fill_session(self, session_id, text, submit):
        raise ServiceError(
            code="input_not_focused",
            message="Tap an input first.",
            status_code=409,
            retryable=False,
        )

    async def back_session(self, session_id):
        return frame(session_id, 2)

    async def refresh_session(self, session_id):
        return frame(session_id, 2)

    async def close_session(self, session_id):
        self.closed_session_id = session_id


class FakeReader:
    def __init__(self):
        self.request = None

    async def read(self, request):
        self.request = request
        return ReadResponse(
            url=request.url,
            final_url="https://example.com/final",
            title="Article",
            blocks=[ReadBlock(kind="paragraph", text="Readable text")],
            links=[],
            truncated=False,
            character_count=13,
            total_character_count=13,
            source="static",
        )


class FakeAI:
    def __init__(self):
        self.request = None

    async def ask(self, request):
        self.request = request
        return AskResponse(
            answer="Answer",
            citations=[],
            model="deepseek-v4-flash",
            web_search_used=request.web_search,
            page_context_used=request.page is not None,
        )


def make_client(fake=None, *, configured=None, reader=None, ai_gateway=None):
    renderer = fake or FakeRenderer()
    app = create_app(
        settings=configured
        or Settings(
            bearer_token="test-token", chromium_egress_isolated=True
        ),
        renderer=renderer,
        reader=reader,
        ai_gateway=ai_gateway,
    )
    return TestClient(app), renderer


def auth_headers(token="test-token"):
    return {"Authorization": f"Bearer {token}"}


def test_health_requires_bearer_and_reports_ready_browser():
    client, renderer = make_client()
    with client:
        unauthorized = client.get("/health")
        wrong = client.get("/health", headers=auth_headers("wrong"))
        healthy = client.get("/health", headers=auth_headers())
    assert unauthorized.status_code == 401
    assert unauthorized.json() == {
        "code": "unauthorized",
        "message": "A valid renderer bearer token is required.",
        "retryable": False,
    }
    assert unauthorized.headers["www-authenticate"] == "Bearer"
    assert wrong.status_code == 401
    assert healthy.status_code == 200
    assert healthy.json()["browser_ready"] is True
    assert healthy.json()["browser_egress_isolated"] is True
    assert healthy.json()["active_sessions"] == 2
    assert renderer.started is True
    assert renderer.stopped is True


def test_health_reports_independent_capabilities_when_chromium_is_not_ready():
    fake = FakeRenderer()
    fake.browser_ready = False
    client, _ = make_client(fake)
    with client:
        response = client.get("/health", headers=auth_headers())
    assert response.status_code == 200
    assert response.json()["status"] == "degraded"
    assert response.json()["browser_ready"] is False
    assert response.json()["browser_egress_isolated"] is True
    assert response.json()["reader_ready"] is True
    assert response.json()["ai_configured"] is False


def test_open_contract_and_strict_request_validation():
    client, renderer = make_client()
    with client:
        response = client.post(
            "/v1/sessions/open",
            headers=auth_headers(),
            json={
                "url": "https://example.com",
                "viewport_width": 396,
                "viewport_height": 484,
            },
        )
        invalid = client.post(
            "/v1/sessions/open",
            headers=auth_headers(),
            json={"url": "https://example.com", "unknown": True},
        )
    assert response.status_code == 200
    assert response.json()["session_id"] == "session123"
    assert "focused_input" in response.json()
    assert renderer.open_arguments == ("https://example.com", 396, 484)
    assert invalid.status_code == 422
    assert invalid.json()["code"] == "invalid_request"


def test_fill_returns_explicit_input_not_focused_error():
    client, _ = make_client()
    with client:
        response = client.post(
            "/v1/sessions/session123/fill",
            headers=auth_headers(),
            json={"text": "query", "submit": True},
        )
    assert response.status_code == 409
    assert response.json() == {
        "code": "input_not_focused",
        "message": "Tap an input first.",
        "retryable": False,
    }


def test_unknown_route_uses_structured_error_shape():
    client, _ = make_client()
    with client:
        response = client.get("/missing")
    assert response.status_code == 404
    assert response.json()["code"] == "not_found"
    assert response.json()["retryable"] is False


def test_delete_session_is_authenticated_and_returns_204():
    client, renderer = make_client()
    with client:
        unauthorized = client.delete("/v1/sessions/session123")
        response = client.delete(
            "/v1/sessions/session123", headers=auth_headers()
        )
    assert unauthorized.status_code == 401
    assert response.status_code == 204
    assert response.content == b""
    assert renderer.closed_session_id == "session123"


def test_read_and_ask_routes_share_bearer_and_strict_contracts():
    reader = FakeReader()
    ai = FakeAI()
    client, _ = make_client(reader=reader, ai_gateway=ai)
    with client:
        unauthorized = client.post(
            "/v1/read", json={"url": "https://example.com"}
        )
        read = client.post(
            "/v1/read",
            headers=auth_headers(),
            json={"url": "https://example.com", "max_links": 0},
        )
        asked = client.post(
            "/v1/ask",
            headers=auth_headers(),
            json={"question": "current?", "web_search": True},
        )
        invalid = client.post(
            "/v1/ask",
            headers=auth_headers(),
            json={"question": "hello", "secret": "must be rejected"},
        )
    assert unauthorized.status_code == 401
    assert read.status_code == 200
    assert read.json()["source"] == "static"
    assert reader.request.max_links == 0
    assert asked.status_code == 200
    assert asked.json()["web_search_used"] is True
    assert ai.request.question == "current?"
    assert invalid.status_code == 422


def test_ask_without_server_key_returns_structured_not_configured_error():
    client, _ = make_client()
    with client:
        response = client.post(
            "/v1/ask",
            headers=auth_headers(),
            json={"question": "hello"},
        )
    assert response.status_code == 503
    assert response.json() == {
        "code": "ai_not_configured",
        "message": "The server AI key is not configured.",
        "retryable": False,
    }


def test_default_security_policy_keeps_static_reader_up_and_chromium_off():
    configured = Settings(bearer_token="test-token")
    renderer = BrowserRenderer(configured)
    reader = FakeReader()
    app = create_app(
        settings=configured,
        renderer=renderer,
        reader=reader,
        ai_gateway=FakeAI(),
    )
    client = TestClient(app)
    with client:
        health = client.get("/health", headers=auth_headers())
        read = client.post(
            "/v1/read",
            headers=auth_headers(),
            json={"url": "https://example.com"},
        )
        browser = client.post(
            "/v1/sessions/open",
            headers=auth_headers(),
            json={"url": "https://example.com"},
        )
    assert health.status_code == 200
    assert health.json()["reader_ready"] is True
    assert health.json()["browser_ready"] is False
    assert health.json()["browser_egress_isolated"] is False
    assert read.status_code == 200
    assert browser.status_code == 503
    assert browser.json()["code"] == "renderer_egress_isolation_required"
