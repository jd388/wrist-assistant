from __future__ import annotations

import asyncio
import ipaddress
import socket
from dataclasses import dataclass
from typing import Awaitable, Callable, List, Optional, Sequence, Tuple, Union
from urllib.parse import SplitResult, urlsplit, urlunsplit

from .errors import ServiceError


Resolver = Callable[[str, int], Awaitable[Sequence[str]]]
IPAddress = Union[ipaddress.IPv4Address, ipaddress.IPv6Address]


_BLOCKED_HOST_NAMES = {
    "localhost",
    "localhost.localdomain",
    "metadata",
    "metadata.google.internal",
    "instance-data",
}

_EXPLICITLY_BLOCKED_ADDRESSES = {
    ipaddress.ip_address("169.254.169.254"),  # AWS/GCP/OpenStack metadata
    ipaddress.ip_address("100.100.100.200"),  # Alibaba Cloud metadata
    ipaddress.ip_address("168.63.129.16"),  # Azure platform virtual IP
    ipaddress.ip_address("fd00:ec2::254"),  # AWS IPv6 metadata
}


@dataclass(frozen=True)
class ValidatedURL:
    url: str
    host: str
    port: int
    addresses: Tuple[str, ...]


class URLGuard:
    """Validates every browser request before Chromium may continue it."""

    def __init__(self, resolver: Optional[Resolver] = None) -> None:
        self._resolver = resolver or self._system_resolver

    async def validate(self, raw_url: str) -> ValidatedURL:
        parts = self._parse(raw_url)
        host = parts.hostname
        if host is None:
            raise self._blocked("The URL must include a host name.")

        normalized_host = host.rstrip(".").lower()
        if not normalized_host:
            raise self._blocked("The URL must include a valid host name.")
        if self._is_blocked_name(normalized_host):
            raise self._blocked("Local and metadata host names are not allowed.")

        try:
            port = parts.port
        except ValueError as exc:
            raise self._blocked("The URL contains an invalid port.") from exc
        if port is None:
            port = 443 if parts.scheme.lower() == "https" else 80

        literal = self._parse_ip_literal(normalized_host)
        if literal is not None:
            self._require_public(literal)
            normalized_host = str(literal)
            addresses = (str(literal),)
        else:
            normalized_host = self._canonical_dns_name(normalized_host)
            if self._is_blocked_name(normalized_host):
                raise self._blocked("Local and metadata host names are not allowed.")
            try:
                resolved = await self._resolver(normalized_host, port)
            except (OSError, UnicodeError) as exc:
                raise ServiceError(
                    code="dns_resolution_failed",
                    message="The host name could not be resolved.",
                    status_code=502,
                    retryable=True,
                ) from exc
            if not resolved:
                raise ServiceError(
                    code="dns_resolution_failed",
                    message="The host name did not resolve to an address.",
                    status_code=502,
                    retryable=True,
                )
            checked: List[str] = []
            for item in resolved:
                try:
                    address = ipaddress.ip_address(item)
                except ValueError as exc:
                    raise self._blocked("DNS returned an invalid address.") from exc
                self._require_public(address)
                checked.append(str(address))
            addresses = tuple(sorted(set(checked)))

        rendered_host = (
            f"[{normalized_host}]" if literal is not None and literal.version == 6 else normalized_host
        )
        rendered_port = f":{parts.port}" if parts.port is not None else ""
        sanitized = SplitResult(
            scheme=parts.scheme.lower(),
            netloc=f"{rendered_host}{rendered_port}",
            path=parts.path or "/",
            query=parts.query,
            fragment=parts.fragment,
        )
        return ValidatedURL(
            url=urlunsplit(sanitized),
            host=normalized_host,
            port=port,
            addresses=addresses,
        )

    def _parse(self, raw_url: str) -> SplitResult:
        if not isinstance(raw_url, str) or not raw_url.strip():
            raise self._blocked("A non-empty URL is required.")
        if any(ord(character) < 32 or ord(character) == 127 for character in raw_url):
            raise self._blocked("The URL contains forbidden control characters.")
        try:
            parts = urlsplit(raw_url.strip())
        except ValueError as exc:
            raise self._blocked("The URL is malformed.") from exc
        if parts.scheme.lower() not in {"http", "https"}:
            raise self._blocked("Only http and https URLs are allowed.")
        if parts.username is not None or parts.password is not None:
            raise self._blocked("URLs containing user credentials are not allowed.")
        if not parts.hostname:
            raise self._blocked("The URL must include a host name.")
        return parts

    @staticmethod
    def _is_blocked_name(host: str) -> bool:
        return (
            host in _BLOCKED_HOST_NAMES
            or host.endswith(".localhost")
            or host.endswith(".local")
            or host.endswith(".internal")
            or host.endswith(".home.arpa")
        )

    @staticmethod
    def _parse_ip_literal(
        host: str,
    ) -> Optional[IPAddress]:
        try:
            return ipaddress.ip_address(host)
        except ValueError:
            return None

    @staticmethod
    def _canonical_dns_name(host: str) -> str:
        try:
            ascii_host = host.encode("idna").decode("ascii").lower()
        except UnicodeError as exc:
            raise URLGuard._blocked("The URL contains an invalid host name.") from exc
        if len(ascii_host) > 253:
            raise URLGuard._blocked("The URL host name is too long.")
        allowed = frozenset("abcdefghijklmnopqrstuvwxyz0123456789-")
        labels = ascii_host.split(".")
        if any(
            not label
            or len(label) > 63
            or label.startswith("-")
            or label.endswith("-")
            or any(character not in allowed for character in label)
            for label in labels
        ):
            raise URLGuard._blocked("The URL contains an invalid host name.")
        return ascii_host

    @staticmethod
    def _require_public(address: IPAddress) -> None:
        if (
            address in _EXPLICITLY_BLOCKED_ADDRESSES
            or address.is_multicast
            or not address.is_global
        ):
            raise URLGuard._blocked(
                "The URL resolves to a local, private, reserved, or metadata address."
            )

    @staticmethod
    async def _system_resolver(host: str, port: int) -> Sequence[str]:
        loop = asyncio.get_running_loop()
        records = await loop.getaddrinfo(
            host,
            port,
            family=socket.AF_UNSPEC,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
        return [record[4][0] for record in records]

    @staticmethod
    def _blocked(message: str) -> ServiceError:
        return ServiceError(
            code="url_blocked",
            message=message,
            status_code=400,
            retryable=False,
        )
