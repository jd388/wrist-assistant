from __future__ import annotations

import secrets
from typing import Optional

from fastapi import Header, Request

from .errors import ServiceError


async def require_bearer_token(
    request: Request,
    authorization: Optional[str] = Header(default=None),
) -> None:
    expected = request.app.state.settings.bearer_token
    scheme = ""
    token = ""
    if authorization:
        pieces = authorization.split(None, 1)
        if len(pieces) == 2:
            scheme, token = pieces[0], pieces[1].strip()

    valid = (
        scheme.lower() == "bearer"
        and bool(token)
        and secrets.compare_digest(token.encode("utf-8"), expected.encode("utf-8"))
    )
    if not valid:
        raise ServiceError(
            code="unauthorized",
            message="A valid renderer bearer token is required.",
            status_code=401,
            retryable=False,
            headers={"WWW-Authenticate": "Bearer"},
        )
