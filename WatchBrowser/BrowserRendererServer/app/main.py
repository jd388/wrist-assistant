from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator, Optional

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from .ai import AIGateway
from .auth import require_bearer_token
from .config import Settings
from .errors import (
    ServiceError,
    http_error_handler,
    service_error_handler,
    unhandled_error_handler,
    validation_error_handler,
)
from .reader import ReaderService
from .renderer import BrowserRenderer
from .schemas import (
    AskRequest,
    AskResponse,
    EmptyRequest,
    FillRequest,
    FrameResponse,
    HealthResponse,
    OpenRequest,
    ReadRequest,
    ReadResponse,
    ScrollRequest,
    TapRequest,
)
from .security import URLGuard


logger = logging.getLogger(__name__)


def create_app(
    *,
    settings: Optional[Settings] = None,
    renderer: Optional[BrowserRenderer] = None,
    reader: Optional[ReaderService] = None,
    ai_gateway: Optional[AIGateway] = None,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        resolved_settings = settings or Settings.from_environment()
        resolved_renderer = renderer or BrowserRenderer(resolved_settings)
        resolved_reader = reader or ReaderService(
            resolved_settings,
            url_guard=getattr(resolved_renderer, "url_guard", URLGuard()),
            dynamic_reader=resolved_renderer,
        )
        resolved_ai_gateway = ai_gateway or AIGateway(resolved_settings)
        application.state.settings = resolved_settings
        application.state.renderer = resolved_renderer
        application.state.reader = resolved_reader
        application.state.ai_gateway = resolved_ai_gateway
        application.state.startup_detail = None
        try:
            await resolved_renderer.start()
        except Exception as exc:
            application.state.startup_detail = type(exc).__name__
            logger.exception("Chromium failed to start")
        try:
            yield
        finally:
            await resolved_renderer.stop()

    application = FastAPI(
        title="WatchBrowser Renderer",
        version="1.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    application.add_exception_handler(ServiceError, service_error_handler)
    application.add_exception_handler(RequestValidationError, validation_error_handler)
    application.add_exception_handler(StarletteHTTPException, http_error_handler)
    application.add_exception_handler(Exception, unhandled_error_handler)

    authentication = [Depends(require_bearer_token)]

    @application.get(
        "/health",
        response_model=HealthResponse,
        dependencies=authentication,
    )
    async def health(request: Request) -> HealthResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        active_sessions = await active_renderer.active_session_count()
        active_settings: Settings = request.app.state.settings
        browser_ready = active_renderer.browser_ready
        return HealthResponse(
            status="ok" if browser_ready else "degraded",
            browser_ready=browser_ready,
            browser_egress_isolated=active_settings.chromium_egress_isolated,
            reader_ready=True,
            ai_configured=bool(active_settings.ai_api_key),
            active_sessions=active_sessions,
            max_sessions=active_settings.max_sessions,
            detail=(
                None
                if browser_ready
                else request.app.state.startup_detail or "Chromium is not ready."
            ),
        )

    @application.post(
        "/v1/read",
        response_model=ReadResponse,
        dependencies=authentication,
    )
    async def read_page(body: ReadRequest, request: Request) -> ReadResponse:
        active_reader: ReaderService = request.app.state.reader
        return await active_reader.read(body)

    @application.post(
        "/v1/ask",
        response_model=AskResponse,
        dependencies=authentication,
    )
    async def ask_ai(body: AskRequest, request: Request) -> AskResponse:
        active_ai_gateway: AIGateway = request.app.state.ai_gateway
        return await active_ai_gateway.ask(body)

    @application.post(
        "/v1/sessions/open",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def open_session(body: OpenRequest, request: Request) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.open_session(
            body.url,
            body.viewport_width,
            body.viewport_height,
        )

    @application.post(
        "/v1/sessions/{session_id}/scroll",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def scroll_session(
        session_id: str, body: ScrollRequest, request: Request
    ) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.scroll_session(session_id, body.amount)

    @application.post(
        "/v1/sessions/{session_id}/tap",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def tap_session(
        session_id: str, body: TapRequest, request: Request
    ) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.tap_session(session_id, body.x, body.y)

    @application.post(
        "/v1/sessions/{session_id}/fill",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def fill_session(
        session_id: str, body: FillRequest, request: Request
    ) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.fill_session(session_id, body.text, body.submit)

    @application.post(
        "/v1/sessions/{session_id}/back",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def back_session(
        session_id: str, _: EmptyRequest, request: Request
    ) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.back_session(session_id)

    @application.post(
        "/v1/sessions/{session_id}/refresh",
        response_model=FrameResponse,
        dependencies=authentication,
    )
    async def refresh_session(
        session_id: str, _: EmptyRequest, request: Request
    ) -> FrameResponse:
        active_renderer: BrowserRenderer = request.app.state.renderer
        return await active_renderer.refresh_session(session_id)

    @application.delete(
        "/v1/sessions/{session_id}",
        status_code=204,
        response_class=Response,
        dependencies=authentication,
    )
    async def close_session(session_id: str, request: Request) -> Response:
        active_renderer: BrowserRenderer = request.app.state.renderer
        await active_renderer.close_session(session_id)
        return Response(status_code=204)

    return application


app = create_app()
