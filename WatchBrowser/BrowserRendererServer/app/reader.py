from __future__ import annotations

import codecs
import ipaddress
import re
from dataclasses import dataclass
from typing import Callable, Iterable, List, Optional, Protocol, Sequence, Tuple
from urllib.parse import urljoin, urlsplit

import httpx
from bs4 import BeautifulSoup, Tag

from .config import Settings
from .errors import ServiceError
from .network import PinnedAsyncHTTPTransport, PinnedNetworkBackend
from .schemas import ReadBlock, ReadLink, ReadRequest, ReadResponse
from .security import URLGuard


_READER_USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 14; Pixel 7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Mobile Safari/537.36 WatchBrowserReader/1.0"
)
_REDIRECT_STATUSES = {301, 302, 303, 307, 308}
_ALLOWED_MEDIA_TYPES = {
    "text/html",
    "application/xhtml+xml",
    "text/plain",
}
_BLOCK_TAGS = ("h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote", "pre")
_JUNK_TAGS = (
    "script",
    "style",
    "noscript",
    "template",
    "svg",
    "canvas",
    "iframe",
)


@dataclass(frozen=True)
class StaticFetchResult:
    requested_url: str
    final_url: str
    media_type: str
    encoding: Optional[str]
    body: bytes


@dataclass(frozen=True)
class ExtractedDocument:
    final_url: str
    title: str
    blocks: Tuple[ReadBlock, ...]
    links: Tuple[ReadLink, ...]
    truncated: bool
    links_truncated: bool
    character_count: int
    total_character_count: int
    source: str
    blocked_subresources: int = 0
    requires_dynamic: bool = False

    def response(self, requested_url: str) -> ReadResponse:
        return ReadResponse(
            url=requested_url,
            final_url=self.final_url,
            title=self.title,
            blocks=list(self.blocks),
            links=list(self.links),
            truncated=self.truncated,
            links_truncated=self.links_truncated,
            character_count=self.character_count,
            total_character_count=self.total_character_count,
            source=self.source,
            blocked_subresources=self.blocked_subresources,
        )


class DynamicReader(Protocol):
    @property
    def browser_ready(self) -> bool: ...

    async def read_document(
        self,
        url: str,
        max_blocks: int,
        max_characters: int,
        max_links: int,
    ) -> ExtractedDocument: ...


class ReaderService:
    """Fetches readable content statically and uses Chromium only when needed."""

    def __init__(
        self,
        settings: Settings,
        *,
        url_guard: URLGuard,
        dynamic_reader: Optional[DynamicReader] = None,
        transport: Optional[httpx.AsyncBaseTransport] = None,
        network_backend_factory: Optional[
            Callable[[], PinnedNetworkBackend]
        ] = None,
    ) -> None:
        self.settings = settings
        self.url_guard = url_guard
        self.dynamic_reader = dynamic_reader
        self._transport = transport
        self._network_backend_factory = (
            network_backend_factory or PinnedNetworkBackend
        )

    async def read(self, request: ReadRequest) -> ReadResponse:
        static_document: Optional[ExtractedDocument] = None
        static_error: Optional[ServiceError] = None
        try:
            fetched = await self._fetch_static(request.url)
            static_document = extract_document(
                fetched.body,
                media_type=fetched.media_type,
                preferred_encoding=fetched.encoding,
                final_url=fetched.final_url,
                max_blocks=request.max_blocks,
                max_characters=request.max_characters,
                max_links=request.max_links,
                dynamic_threshold=self.settings.reader_dynamic_threshold_characters,
            )
        except ServiceError as error:
            if error.code == "url_blocked":
                raise
            static_error = error

        needs_dynamic = bool(
            request.prefer_dynamic
            or static_document is None
            or static_document.requires_dynamic
        )
        dynamic_ready = bool(
            self.dynamic_reader is not None and self.dynamic_reader.browser_ready
        )
        if needs_dynamic and dynamic_ready and self.dynamic_reader is not None:
            try:
                dynamic = await self.dynamic_reader.read_document(
                    request.url,
                    request.max_blocks,
                    request.max_characters,
                    request.max_links,
                )
                if dynamic.blocks or not static_document or not static_document.blocks:
                    return dynamic.response(request.url)
            except ServiceError:
                if static_document is None or not static_document.blocks:
                    raise

        if static_document is not None and static_document.blocks:
            return static_document.response(request.url)
        if static_error is not None:
            raise static_error
        if needs_dynamic and not dynamic_ready:
            raise ServiceError(
                code="dynamic_reader_unavailable",
                message=(
                    "The page did not expose readable static content and Chromium "
                    "is not ready."
                ),
                status_code=503,
                retryable=True,
            )
        raise ServiceError(
            code="empty_page",
            message="The target page did not expose readable text content.",
            status_code=502,
            retryable=False,
        )

    async def _fetch_static(self, raw_url: str) -> StaticFetchResult:
        current_url = raw_url
        timeout = httpx.Timeout(self.settings.reader_timeout_seconds)
        limits = httpx.Limits(max_connections=20, max_keepalive_connections=10)
        pinned_backend: Optional[PinnedNetworkBackend] = None
        transport = self._transport
        if transport is None:
            pinned_backend = self._network_backend_factory()
            transport = PinnedAsyncHTTPTransport(pinned_backend, limits=limits)
        headers = {
            "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "User-Agent": _READER_USER_AGENT,
        }
        async with httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=False,
            trust_env=False,
            limits=limits,
            transport=transport,
        ) as client:
            for redirect_count in range(self.settings.reader_max_redirects + 1):
                validated = await self.url_guard.validate(current_url)
                if pinned_backend is not None:
                    pinned_backend.pin(
                        validated.host, validated.port, validated.addresses
                    )
                try:
                    async with client.stream(
                        "GET", validated.url, headers=headers
                    ) as response:
                        if response.status_code in _REDIRECT_STATUSES:
                            location = response.headers.get("location", "").strip()
                            if not location:
                                raise ServiceError(
                                    code="invalid_redirect",
                                    message="The target returned a redirect without a location.",
                                    status_code=502,
                                    retryable=False,
                                )
                            if redirect_count >= self.settings.reader_max_redirects:
                                raise ServiceError(
                                    code="too_many_redirects",
                                    message="The target exceeded the redirect limit.",
                                    status_code=502,
                                    retryable=False,
                                )
                            current_url = urljoin(validated.url, location)
                            continue

                        if response.status_code < 200 or response.status_code >= 300:
                            raise ServiceError(
                                code="web_upstream_rejected",
                                message=(
                                    "The target website returned HTTP "
                                    f"{response.status_code}."
                                ),
                                status_code=502,
                                retryable=(
                                    response.status_code in {408, 425, 429}
                                    or response.status_code >= 500
                                ),
                            )

                        content_type = response.headers.get("content-type")
                        media_type = _media_type(content_type)
                        if media_type and media_type not in _ALLOWED_MEDIA_TYPES:
                            raise ServiceError(
                                code="unsupported_content_type",
                                message=(
                                    "The target is not an HTML or plain-text document."
                                ),
                                status_code=415,
                                retryable=False,
                            )
                        declared_length = _content_length(response.headers.get("content-length"))
                        if declared_length is not None and declared_length > self.settings.reader_maximum_response_bytes:
                            raise _response_too_large()

                        chunks: List[bytes] = []
                        received = 0
                        async for chunk in response.aiter_bytes():
                            received += len(chunk)
                            if received > self.settings.reader_maximum_response_bytes:
                                raise _response_too_large()
                            chunks.append(chunk)
                        body = b"".join(chunks)
                        if not body:
                            raise ServiceError(
                                code="empty_page",
                                message="The target returned an empty document.",
                                status_code=502,
                                retryable=False,
                            )
                        inferred_type = media_type or _sniff_media_type(body)
                        if inferred_type not in _ALLOWED_MEDIA_TYPES:
                            raise ServiceError(
                                code="unsupported_content_type",
                                message=(
                                    "The target is not an HTML or plain-text document."
                                ),
                                status_code=415,
                                retryable=False,
                            )
                        return StaticFetchResult(
                            requested_url=raw_url,
                            final_url=validated.url,
                            media_type=inferred_type,
                            encoding=_content_charset(content_type),
                            body=body,
                        )
                except ServiceError:
                    raise
                except httpx.TimeoutException as exc:
                    raise ServiceError(
                        code="web_fetch_timeout",
                        message="The target website did not respond in time.",
                        status_code=504,
                        retryable=True,
                    ) from exc
                except httpx.HTTPError as exc:
                    raise ServiceError(
                        code="web_fetch_failed",
                        message="The target website could not be downloaded.",
                        status_code=502,
                        retryable=True,
                    ) from exc

        raise ServiceError(
            code="too_many_redirects",
            message="The target exceeded the redirect limit.",
            status_code=502,
            retryable=False,
        )


def extract_document(
    body: bytes,
    *,
    media_type: str,
    final_url: str,
    max_blocks: int,
    max_characters: int,
    max_links: int,
    dynamic_threshold: int,
    preferred_encoding: Optional[str] = None,
) -> ExtractedDocument:
    text = _decode_body(body, media_type, preferred_encoding)
    if media_type == "text/plain":
        raw_blocks = [
            ReadBlock(kind="paragraph", text=item)
            for item in _plain_text_blocks(text)
        ]
        return finalize_document(
            final_url=final_url,
            title=_title_from_url(final_url),
            blocks=raw_blocks,
            links=(),
            max_blocks=max_blocks,
            max_characters=max_characters,
            max_links=max_links,
            source="static",
            requires_dynamic=False,
        )

    soup = BeautifulSoup(text, "html.parser")
    script_count = len(soup.find_all("script"))
    title = _html_title(soup) or _title_from_url(final_url)
    for node in soup.find_all(_JUNK_TAGS):
        node.decompose()
    for node in soup.find_all(attrs={"aria-hidden": "true"}):
        node.decompose()
    for node in soup.find_all(attrs={"hidden": True}):
        node.decompose()

    root = (
        soup.find("main")
        or soup.find("article")
        or soup.find(attrs={"role": "main"})
        or soup.body
        or soup
    )
    blocks, scan_truncated = _html_blocks(root)
    links, links_scan_truncated = _html_links(root, final_url)
    total_characters = sum(len(item.text) for item in blocks)
    requires_dynamic = (
        not blocks
        or (
            script_count > 0
            and len(blocks) <= 1
            and total_characters < dynamic_threshold
        )
    )
    return finalize_document(
        final_url=final_url,
        title=title,
        blocks=blocks,
        links=links,
        max_blocks=max_blocks,
        max_characters=max_characters,
        max_links=max_links,
        source="static",
        inherently_truncated=scan_truncated,
        links_inherently_truncated=links_scan_truncated,
        requires_dynamic=requires_dynamic,
    )


def finalize_document(
    *,
    final_url: str,
    title: str,
    blocks: Sequence[ReadBlock],
    links: Sequence[ReadLink],
    max_blocks: int,
    max_characters: int,
    max_links: int,
    source: str,
    blocked_subresources: int = 0,
    inherently_truncated: bool = False,
    links_inherently_truncated: bool = False,
    requires_dynamic: bool = False,
    reported_total_characters: Optional[int] = None,
) -> ExtractedDocument:
    total_characters = (
        reported_total_characters
        if reported_total_characters is not None
        else sum(len(item.text) for item in blocks)
    )
    output_blocks: List[ReadBlock] = []
    remaining = max_characters
    truncated = inherently_truncated
    for index, block in enumerate(blocks):
        if len(output_blocks) >= max_blocks or remaining <= 0:
            truncated = True
            break
        normalized = _clean_text(block.text)
        if not normalized:
            continue
        if len(normalized) > remaining:
            clipped = normalized[:remaining].rstrip()
            if clipped:
                clipped = clipped[:-1] + "…" if len(clipped) > 1 else "…"
                output_blocks.append(ReadBlock(kind=block.kind, text=clipped))
            remaining = 0
            truncated = True
            break
        output_blocks.append(ReadBlock(kind=block.kind, text=normalized))
        remaining -= len(normalized)
        if index < len(blocks) - 1 and remaining <= 0:
            truncated = True

    output_links = list(links[:max_links]) if max_links else []
    links_truncated = links_inherently_truncated or len(links) > len(output_links)
    returned_characters = sum(len(item.text) for item in output_blocks)
    if total_characters > returned_characters:
        truncated = True
    return ExtractedDocument(
        final_url=final_url[:4096],
        title=_clean_text(title)[:512],
        blocks=tuple(output_blocks),
        links=tuple(output_links),
        truncated=truncated,
        links_truncated=links_truncated,
        character_count=returned_characters,
        total_character_count=max(total_characters, returned_characters),
        source=source,
        blocked_subresources=max(0, blocked_subresources),
        requires_dynamic=requires_dynamic,
    )


def _html_blocks(root: Tag) -> Tuple[List[ReadBlock], bool]:
    output: List[ReadBlock] = []
    seen = set()
    candidates = root.find_all(_BLOCK_TAGS)
    scan_truncated = len(candidates) > 5_000
    for tag in candidates[:5_000]:
        if tag.find_parent(_BLOCK_TAGS) is not None:
            continue
        text = _clean_text(tag.get_text(" ", strip=True))
        if not text or text in seen:
            continue
        seen.add(text)
        if tag.name.startswith("h"):
            kind = "heading"
        elif tag.name == "li":
            kind = "list_item"
        elif tag.name == "blockquote":
            kind = "quote"
        elif tag.name == "pre":
            kind = "code"
        else:
            kind = "paragraph"
        output.append(ReadBlock(kind=kind, text=text[:20_000]))

    if output:
        return output, scan_truncated

    fallback_lines = []
    for item in root.stripped_strings:
        cleaned = _clean_text(str(item))
        if cleaned and cleaned not in seen:
            seen.add(cleaned)
            fallback_lines.append(cleaned)
        if len(fallback_lines) >= 5_000:
            scan_truncated = True
            break
    return (
        [ReadBlock(kind="paragraph", text=item[:20_000]) for item in fallback_lines],
        scan_truncated,
    )


def _html_links(root: Tag, final_url: str) -> Tuple[List[ReadLink], bool]:
    output: List[ReadLink] = []
    seen = set()
    anchors = root.find_all("a", href=True)
    scan_truncated = len(anchors) > 2_000
    for anchor in anchors[:2_000]:
        href = str(anchor.get("href", "")).strip()
        resolved = safe_link(urljoin(final_url, href))
        if not resolved or resolved in seen:
            continue
        seen.add(resolved)
        label = _clean_text(anchor.get_text(" ", strip=True))
        if not label:
            label = _title_from_url(resolved)
        output.append(ReadLink(text=label[:160], url=resolved[:4096]))
    return output, scan_truncated


def _plain_text_blocks(value: str) -> Iterable[str]:
    normalized = value.replace("\r\n", "\n").replace("\r", "\n")
    chunks = re.split(r"\n\s*\n+", normalized)
    for chunk in chunks:
        text = _clean_text(chunk)
        if text:
            yield text[:20_000]


def _decode_body(
    body: bytes, media_type: str, preferred_encoding: Optional[str] = None
) -> str:
    if body.startswith(codecs.BOM_UTF8):
        return body.decode("utf-8-sig", errors="replace")
    if body.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return body.decode("utf-16", errors="replace")

    header = body[:4_096].decode("latin-1", errors="ignore")
    charset_match = re.search(
        r"charset\s*=\s*['\"]?([A-Za-z0-9._-]+)", header, re.IGNORECASE
    )
    candidates = [preferred_encoding] if preferred_encoding else []
    if charset_match:
        candidates.append(charset_match.group(1))
    candidates.extend(("utf-8", "gb18030", "big5"))
    best = ""
    best_replacements: Optional[int] = None
    for encoding in candidates:
        try:
            codecs.lookup(encoding)
            decoded = body.decode(encoding, errors="replace")
        except (LookupError, UnicodeError):
            continue
        replacements = decoded.count("\ufffd")
        if replacements == 0:
            return decoded
        if best_replacements is None or replacements < best_replacements:
            best = decoded
            best_replacements = replacements
    if best:
        return best
    raise ServiceError(
        code="unsupported_text_encoding",
        message=f"The {media_type} document uses an unsupported text encoding.",
        status_code=415,
        retryable=False,
    )


def _html_title(soup: BeautifulSoup) -> str:
    for attribute, value in (("property", "og:title"), ("name", "twitter:title")):
        node = soup.find("meta", attrs={attribute: value})
        if isinstance(node, Tag):
            content = _clean_text(str(node.get("content", "")))
            if content:
                return content
    if soup.title:
        title = _clean_text(soup.title.get_text(" ", strip=True))
        if title:
            return title
    heading = soup.find("h1")
    return _clean_text(heading.get_text(" ", strip=True)) if heading else ""


def _media_type(content_type: Optional[str]) -> str:
    if not content_type:
        return ""
    return content_type.split(";", 1)[0].strip().lower()


def _content_charset(content_type: Optional[str]) -> Optional[str]:
    if not content_type:
        return None
    match = re.search(
        r"(?:^|;)\s*charset\s*=\s*['\"]?([A-Za-z0-9._-]+)",
        content_type,
        re.IGNORECASE,
    )
    return match.group(1) if match else None


def _sniff_media_type(body: bytes) -> str:
    prefix = body[:1_024].lstrip().lower()
    if prefix.startswith((b"<!doctype html", b"<html", b"<?xml")) or b"<body" in prefix:
        return "text/html"
    if b"\x00" not in prefix:
        return "text/plain"
    return "application/octet-stream"


def _content_length(raw: Optional[str]) -> Optional[int]:
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError:
        return None
    return value if value >= 0 else None


def safe_link(raw_url: str) -> Optional[str]:
    try:
        parts = urlsplit(raw_url)
        host = parts.hostname
        port = parts.port
    except ValueError:
        return None
    if (
        parts.scheme.lower() not in {"http", "https"}
        or not host
        or parts.username is not None
        or parts.password is not None
    ):
        return None
    normalized_host = host.rstrip(".").lower()
    if URLGuard._is_blocked_name(normalized_host):
        return None
    try:
        literal = ipaddress.ip_address(normalized_host)
    except ValueError:
        literal = None
    if literal is not None and not literal.is_global:
        return None
    if port is not None and not (1 <= port <= 65_535):
        return None
    return raw_url


def _title_from_url(raw_url: str) -> str:
    try:
        return urlsplit(raw_url).hostname or raw_url
    except ValueError:
        return raw_url


def _clean_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _response_too_large() -> ServiceError:
    return ServiceError(
        code="web_response_too_large",
        message="The target document exceeds the reader download limit.",
        status_code=413,
        retryable=False,
    )
