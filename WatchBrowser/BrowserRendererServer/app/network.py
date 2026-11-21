from __future__ import annotations

import ipaddress
import ssl
from typing import Dict, Iterable, Optional, Tuple

import certifi
import httpcore
import httpx
from httpcore._backends.auto import AutoBackend


class PinnedNetworkBackend(httpcore.AsyncNetworkBackend):
    """Connects an origin only to IP addresses approved by ``URLGuard``.

    HTTP Host and TLS SNI are intentionally not changed here. ``httpcore`` keeps
    using the original request origin for both; this backend substitutes only the
    destination passed to the operating system's TCP connect call.
    """

    def __init__(
        self, underlying: Optional[httpcore.AsyncNetworkBackend] = None
    ) -> None:
        self._underlying = underlying or AutoBackend()
        self._pins: Dict[Tuple[str, int], Tuple[str, ...]] = {}

    def pin(
        self, host: str, port: int, addresses: Iterable[str]
    ) -> None:
        normalized_host = _normalize_host(host)
        checked = []
        for item in addresses:
            address = ipaddress.ip_address(item)
            if not address.is_global:
                raise ValueError("Pinned addresses must be globally routable")
            checked.append(str(address))
        if not checked:
            raise ValueError("At least one validated address is required")
        # Prefer IPv4 first. Some hosts publish unreachable IPv6 addresses, and
        # trying a dead IPv6 address first can consume the whole Watch timeout.
        checked.sort(key=lambda value: (ipaddress.ip_address(value).version, value))
        self._pins[(normalized_host, port)] = tuple(dict.fromkeys(checked))

    async def connect_tcp(
        self,
        host: str,
        port: int,
        timeout: Optional[float] = None,
        local_address: Optional[str] = None,
        socket_options: Optional[Iterable[Tuple[int, int, int]]] = None,
    ) -> httpcore.AsyncNetworkStream:
        addresses = self._pins.get((_normalize_host(host), port))
        if not addresses:
            raise httpcore.ConnectError(
                "The destination has no URLGuard-approved address pin."
            )

        last_error: Optional[Exception] = None
        for address in addresses:
            try:
                stream = await self._underlying.connect_tcp(
                    host=address,
                    port=port,
                    timeout=timeout,
                    local_address=local_address,
                    socket_options=socket_options,
                )
                if not _peer_matches(stream, address, port):
                    await stream.aclose()
                    raise httpcore.ConnectError(
                        "The connected peer did not match the approved address pin."
                    )
                return stream
            except (httpcore.ConnectError, httpcore.ConnectTimeout) as exc:
                last_error = exc
        if last_error is not None:
            raise last_error
        raise httpcore.ConnectError("No approved destination address was usable.")

    async def connect_unix_socket(
        self,
        path: str,
        timeout: Optional[float] = None,
        socket_options: Optional[Iterable[Tuple[int, int, int]]] = None,
    ) -> httpcore.AsyncNetworkStream:
        raise httpcore.ConnectError("Unix sockets are not allowed by the reader.")

    async def sleep(self, seconds: float) -> None:
        await self._underlying.sleep(seconds)


class PinnedAsyncHTTPTransport(httpx.AsyncBaseTransport):
    """An HTTPX transport backed by an address-pinned httpcore pool."""

    def __init__(
        self,
        backend: PinnedNetworkBackend,
        *,
        limits: httpx.Limits,
    ) -> None:
        self._pool = httpcore.AsyncConnectionPool(
            ssl_context=ssl.create_default_context(cafile=certifi.where()),
            max_connections=limits.max_connections,
            max_keepalive_connections=limits.max_keepalive_connections,
            keepalive_expiry=limits.keepalive_expiry,
            http1=True,
            http2=False,
            retries=0,
            network_backend=backend,
        )

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if not isinstance(request.stream, httpx.AsyncByteStream):
            raise TypeError("PinnedAsyncHTTPTransport requires an async request stream")
        core_request = httpcore.Request(
            method=request.method,
            url=httpcore.URL(
                scheme=request.url.raw_scheme,
                host=request.url.raw_host,
                port=request.url.port,
                target=request.url.raw_path,
            ),
            headers=request.headers.raw,
            content=request.stream,
            extensions=request.extensions,
        )
        try:
            response = await self._pool.handle_async_request(core_request)
        except httpcore.TimeoutException as exc:
            raise httpx.TimeoutException(
                "The pinned HTTP connection timed out.", request=request
            ) from exc
        except (
            httpcore.NetworkError,
            httpcore.ProtocolError,
            httpcore.UnsupportedProtocol,
        ) as exc:
            raise httpx.TransportError(
                "The pinned HTTP connection failed.", request=request
            ) from exc
        return httpx.Response(
            status_code=response.status,
            headers=response.headers,
            stream=_CoreResponseStream(response.stream),
            extensions=response.extensions,
        )

    async def aclose(self) -> None:
        await self._pool.aclose()


class _CoreResponseStream(httpx.AsyncByteStream):
    def __init__(self, stream: object) -> None:
        self._stream = stream

    async def __aiter__(self):
        async for part in self._stream:  # type: ignore[attr-defined]
            yield part

    async def aclose(self) -> None:
        await self._stream.aclose()  # type: ignore[attr-defined]


def _normalize_host(host: str) -> str:
    return host.rstrip(".").encode("idna").decode("ascii").lower()


def _peer_matches(
    stream: httpcore.AsyncNetworkStream, expected_address: str, expected_port: int
) -> bool:
    peer = stream.get_extra_info("server_addr")
    if peer is None:
        # The TCP call still received the literal approved IP, so it cannot cause
        # a second DNS lookup. Some custom backends simply do not expose peer data.
        return True
    if not isinstance(peer, (tuple, list)) or len(peer) < 2:
        return False
    try:
        peer_address = ipaddress.ip_address(str(peer[0]).split("%", 1)[0])
        expected = ipaddress.ip_address(expected_address)
        peer_port = int(peer[1])
    except (TypeError, ValueError):
        return False
    return peer_address == expected and peer_port == expected_port
