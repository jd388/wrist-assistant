from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlsplit


def _positive_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if value <= 0:
        raise RuntimeError(f"{name} must be greater than zero")
    return value


def _required_token() -> str:
    token = os.getenv("BROWSER_RENDERER_TOKEN", "").strip()
    if not token:
        raise RuntimeError(
            "BROWSER_RENDERER_TOKEN must be set to a non-empty bearer token"
        )
    return token


def _boolean(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be a boolean")


def _optional_secret(*names: str) -> Optional[str]:
    for name in names:
        value = os.getenv(name)
        if value is not None and value.strip():
            return value.strip()
    return None


def _string(name: str, default: str) -> str:
    value = os.getenv(name, default).strip()
    if not value:
        raise RuntimeError(f"{name} must be non-empty")
    return value


def _https_base_url(name: str, value: str) -> str:
    try:
        parts = urlsplit(value)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be a valid HTTPS URL") from exc
    if (
        parts.scheme.lower() != "https"
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.query
        or parts.fragment
    ):
        raise RuntimeError(
            f"{name} must be an HTTPS base URL without credentials, query, or fragment"
        )
    return value.rstrip("/")


@dataclass(frozen=True)
class Settings:
    bearer_token: str
    session_ttl_seconds: int = 300
    max_sessions: int = 8
    max_concurrent_operations: int = 4
    operation_timeout_seconds: int = 25
    navigation_timeout_ms: int = 20_000
    maximum_image_bytes: int = 48_000
    cleanup_interval_seconds: int = 15
    blank_frame_retries: int = 3
    blank_frame_retry_delay_ms: int = 350
    settle_delay_ms: int = 300
    replace_existing_session: bool = True
    chromium_egress_isolated: bool = False
    reader_timeout_seconds: int = 12
    reader_maximum_response_bytes: int = 1_500_000
    reader_max_redirects: int = 5
    reader_dynamic_threshold_characters: int = 180
    ai_api_key: Optional[str] = field(default=None, repr=False)
    ai_base_url: str = "https://api.deepseek.com"
    ai_model: str = "deepseek-v4-flash"
    ai_timeout_seconds: int = 45
    ai_max_output_tokens: int = 900
    ai_maximum_response_bytes: int = 512_000
    ai_maximum_page_context_characters: int = 12_000

    def __post_init__(self) -> None:
        token = self.bearer_token.strip()
        if not token:
            raise RuntimeError("bearer_token must be non-empty")
        object.__setattr__(self, "bearer_token", token)
        api_key = self.ai_api_key.strip() if self.ai_api_key else None
        object.__setattr__(self, "ai_api_key", api_key or None)
        object.__setattr__(
            self,
            "ai_base_url",
            _https_base_url("ai_base_url", self.ai_base_url.strip()),
        )
        model = self.ai_model.strip()
        if not model or len(model) > 128:
            raise RuntimeError("ai_model must be between 1 and 128 characters")
        object.__setattr__(self, "ai_model", model)
        positive_values = {
            "session_ttl_seconds": self.session_ttl_seconds,
            "max_sessions": self.max_sessions,
            "max_concurrent_operations": self.max_concurrent_operations,
            "operation_timeout_seconds": self.operation_timeout_seconds,
            "navigation_timeout_ms": self.navigation_timeout_ms,
            "maximum_image_bytes": self.maximum_image_bytes,
            "cleanup_interval_seconds": self.cleanup_interval_seconds,
            "blank_frame_retries": self.blank_frame_retries,
            "blank_frame_retry_delay_ms": self.blank_frame_retry_delay_ms,
            "settle_delay_ms": self.settle_delay_ms,
            "reader_timeout_seconds": self.reader_timeout_seconds,
            "reader_maximum_response_bytes": self.reader_maximum_response_bytes,
            "reader_max_redirects": self.reader_max_redirects,
            "reader_dynamic_threshold_characters": self.reader_dynamic_threshold_characters,
            "ai_timeout_seconds": self.ai_timeout_seconds,
            "ai_max_output_tokens": self.ai_max_output_tokens,
            "ai_maximum_response_bytes": self.ai_maximum_response_bytes,
            "ai_maximum_page_context_characters": self.ai_maximum_page_context_characters,
        }
        for name, value in positive_values.items():
            if value <= 0:
                raise RuntimeError(f"{name} must be greater than zero")
        if self.maximum_image_bytes > 48_000:
            raise RuntimeError(
                "BROWSER_RENDERER_MAXIMUM_IMAGE_BYTES cannot exceed 48000"
            )
        if self.blank_frame_retries > 3:
            raise RuntimeError("blank_frame_retries cannot exceed 3")
        if self.reader_maximum_response_bytes > 5_000_000:
            raise RuntimeError(
                "reader_maximum_response_bytes cannot exceed 5000000"
            )
        if self.reader_max_redirects > 10:
            raise RuntimeError("reader_max_redirects cannot exceed 10")
        if self.ai_max_output_tokens > 4_096:
            raise RuntimeError("ai_max_output_tokens cannot exceed 4096")
        if self.ai_maximum_response_bytes > 2_000_000:
            raise RuntimeError(
                "ai_maximum_response_bytes cannot exceed 2000000"
            )
        if self.ai_maximum_page_context_characters > 20_000:
            raise RuntimeError(
                "ai_maximum_page_context_characters cannot exceed 20000"
            )

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            bearer_token=_required_token(),
            session_ttl_seconds=_positive_int(
                "BROWSER_RENDERER_SESSION_TTL_SECONDS", 300
            ),
            max_sessions=_positive_int("BROWSER_RENDERER_MAX_SESSIONS", 8),
            max_concurrent_operations=_positive_int(
                "BROWSER_RENDERER_MAX_CONCURRENT_OPERATIONS", 4
            ),
            operation_timeout_seconds=_positive_int(
                "BROWSER_RENDERER_OPERATION_TIMEOUT_SECONDS", 25
            ),
            navigation_timeout_ms=_positive_int(
                "BROWSER_RENDERER_NAVIGATION_TIMEOUT_MS", 20_000
            ),
            maximum_image_bytes=_positive_int(
                "BROWSER_RENDERER_MAXIMUM_IMAGE_BYTES", 48_000
            ),
            cleanup_interval_seconds=_positive_int(
                "BROWSER_RENDERER_CLEANUP_INTERVAL_SECONDS", 15
            ),
            blank_frame_retries=_positive_int(
                "BROWSER_RENDERER_BLANK_FRAME_RETRIES", 3
            ),
            blank_frame_retry_delay_ms=_positive_int(
                "BROWSER_RENDERER_BLANK_FRAME_RETRY_DELAY_MS", 350
            ),
            settle_delay_ms=_positive_int(
                "BROWSER_RENDERER_SETTLE_DELAY_MS", 300
            ),
            replace_existing_session=_boolean(
                "BROWSER_RENDERER_REPLACE_EXISTING_SESSION", True
            ),
            chromium_egress_isolated=_boolean(
                "BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED", False
            ),
            reader_timeout_seconds=_positive_int(
                "BROWSER_RENDERER_READER_TIMEOUT_SECONDS", 12
            ),
            reader_maximum_response_bytes=_positive_int(
                "BROWSER_RENDERER_READER_MAXIMUM_RESPONSE_BYTES", 1_500_000
            ),
            reader_max_redirects=_positive_int(
                "BROWSER_RENDERER_READER_MAX_REDIRECTS", 5
            ),
            reader_dynamic_threshold_characters=_positive_int(
                "BROWSER_RENDERER_READER_DYNAMIC_THRESHOLD_CHARACTERS", 180
            ),
            ai_api_key=_optional_secret(
                "BROWSER_RENDERER_AI_API_KEY", "DEEPSEEK_API_KEY"
            ),
            ai_base_url=_string(
                "BROWSER_RENDERER_AI_BASE_URL", "https://api.deepseek.com"
            ),
            ai_model=_string(
                "BROWSER_RENDERER_AI_MODEL", "deepseek-v4-flash"
            ),
            ai_timeout_seconds=_positive_int(
                "BROWSER_RENDERER_AI_TIMEOUT_SECONDS", 45
            ),
            ai_max_output_tokens=_positive_int(
                "BROWSER_RENDERER_AI_MAX_OUTPUT_TOKENS", 900
            ),
            ai_maximum_response_bytes=_positive_int(
                "BROWSER_RENDERER_AI_MAXIMUM_RESPONSE_BYTES", 512_000
            ),
            ai_maximum_page_context_characters=_positive_int(
                "BROWSER_RENDERER_AI_MAXIMUM_PAGE_CONTEXT_CHARACTERS", 12_000
            ),
        )
