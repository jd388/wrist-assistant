from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Dict

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


logger = logging.getLogger(__name__)


@dataclass
class ServiceError(Exception):
    code: str
    message: str
    status_code: int
    retryable: bool = False
    headers: Dict[str, str] = field(default_factory=dict)

    def __str__(self) -> str:
        return self.message

    def payload(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "retryable": self.retryable,
        }


async def service_error_handler(_: Request, error: ServiceError) -> JSONResponse:
    return JSONResponse(
        status_code=error.status_code,
        content=error.payload(),
        headers=error.headers,
    )


async def validation_error_handler(
    _: Request, error: RequestValidationError
) -> JSONResponse:
    messages = []
    for issue in error.errors():
        location = ".".join(str(part) for part in issue.get("loc", ()))
        text = issue.get("msg", "invalid value")
        messages.append(f"{location}: {text}" if location else text)
    message = "; ".join(messages[:4]) or "Request validation failed"
    return JSONResponse(
        status_code=422,
        content={
            "code": "invalid_request",
            "message": message,
            "retryable": False,
        },
    )


async def http_error_handler(
    _: Request, error: StarletteHTTPException
) -> JSONResponse:
    if error.status_code == 404:
        code = "not_found"
        message = "The requested renderer endpoint does not exist."
    elif error.status_code == 405:
        code = "method_not_allowed"
        message = "The HTTP method is not allowed for this endpoint."
    else:
        code = "http_error"
        message = str(error.detail) if error.detail else "The request failed."
    return JSONResponse(
        status_code=error.status_code,
        content={"code": code, "message": message, "retryable": False},
        headers=error.headers,
    )


async def unhandled_error_handler(request: Request, error: Exception) -> JSONResponse:
    logger.exception(
        "Unhandled renderer error for %s %s",
        request.method,
        request.url.path,
        exc_info=error,
    )
    return JSONResponse(
        status_code=500,
        content={
            "code": "internal_error",
            "message": "The renderer encountered an unexpected error.",
            "retryable": True,
        },
    )
