import asyncio

import httpcore
import pytest

from app.config import Settings
from app.errors import ServiceError
from app.network import PinnedNetworkBackend
from app.reader import ReaderService
from app.schemas import ReadRequest
from app.security import URLGuard


class CannedStream(httpcore.AsyncNetworkStream):
    def __init__(self, address, port, response):
        self.peer = (address, port)
        self._response = response
        self.writes = []
        self.tls_server_names = []
        self.closed = False

    async def read(self, _max_bytes, timeout=None):
        response, self._response = self._response, b""
        return response

    async def write(self, buffer, timeout=None):
        self.writes.append(buffer)

    async def aclose(self):
        self.closed = True

    async def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        self.tls_server_names.append(server_hostname)
        return self

    def get_extra_info(self, info):
        if info == "server_addr":
            return self.peer
        if info == "ssl_object":
            return None
        return None


class CannedBackend(httpcore.AsyncNetworkBackend):
    def __init__(self, responses, *, peer_override=None):
        self.responses = {key: list(value) for key, value in responses.items()}
        self.peer_override = peer_override
        self.connect_calls = []
        self.streams = []

    async def connect_tcp(
        self,
        host,
        port,
        timeout=None,
        local_address=None,
        socket_options=None,
    ):
        self.connect_calls.append((host, port))
        response = self.responses[host].pop(0)
        peer_host = self.peer_override or host
        stream = CannedStream(peer_host, port, response)
        self.streams.append(stream)
        return stream

    async def connect_unix_socket(self, path, timeout=None, socket_options=None):
        raise AssertionError("Unix sockets must not be used")

    async def sleep(self, seconds):
        return None


def http_response(status, body=b"", headers=()):
    reason = b"OK" if status == 200 else b"Found"
    rendered_headers = b"".join(
        name + b": " + value + b"\r\n" for name, value in headers
    )
    return (
        b"HTTP/1.1 "
        + str(status).encode()
        + b" "
        + reason
        + b"\r\n"
        + rendered_headers
        + b"Content-Length: "
        + str(len(body)).encode()
        + b"\r\nConnection: close\r\n\r\n"
        + body
    )


def run(coroutine):
    return asyncio.run(coroutine)


def reader_settings():
    return Settings(
        bearer_token="test-token",
        reader_timeout_seconds=3,
        reader_maximum_response_bytes=20_000,
        reader_max_redirects=3,
    )


def test_reader_connects_to_validated_ip_while_preserving_host_and_tls_sni():
    dns_calls = []

    async def rebinding_resolver(host, port):
        dns_calls.append((host, port))
        # A vulnerable second lookup would receive the private address.
        return ["93.184.216.34"] if len(dns_calls) == 1 else ["127.0.0.1"]

    underlying = CannedBackend(
        {
            "93.184.216.34": [
                http_response(
                    200,
                    b"safe body",
                    headers=((b"Content-Type", b"text/plain"),),
                )
            ]
        }
    )
    reader = ReaderService(
        reader_settings(),
        url_guard=URLGuard(resolver=rebinding_resolver),
        network_backend_factory=lambda: PinnedNetworkBackend(underlying),
    )

    result = run(reader.read(ReadRequest(url="https://example.test/read")))

    assert result.blocks[0].text == "safe body"
    assert dns_calls == [("example.test", 443)]
    assert underlying.connect_calls == [("93.184.216.34", 443)]
    assert underlying.streams[0].tls_server_names == ["example.test"]
    request_bytes = b"".join(underlying.streams[0].writes)
    assert b"Host: example.test" in request_bytes


def test_reader_revalidates_and_repins_each_redirect_hop():
    dns_calls = []

    async def resolver(host, port):
        dns_calls.append((host, port))
        return {
            "example.test": ["93.184.216.34"],
            "other.test": ["1.1.1.1"],
        }[host]

    underlying = CannedBackend(
        {
            "93.184.216.34": [
                http_response(
                    302,
                    headers=((b"Location", b"https://other.test/final"),),
                )
            ],
            "1.1.1.1": [
                http_response(
                    200,
                    b"redirected body",
                    headers=((b"Content-Type", b"text/plain"),),
                )
            ],
        }
    )
    reader = ReaderService(
        reader_settings(),
        url_guard=URLGuard(resolver=resolver),
        network_backend_factory=lambda: PinnedNetworkBackend(underlying),
    )

    result = run(reader.read(ReadRequest(url="https://example.test/start")))

    assert result.final_url == "https://other.test/final"
    assert dns_calls == [("example.test", 443), ("other.test", 443)]
    assert underlying.connect_calls == [
        ("93.184.216.34", 443),
        ("1.1.1.1", 443),
    ]


def test_pinned_backend_fails_closed_without_a_pin_or_on_peer_mismatch():
    underlying = CannedBackend(
        {"93.184.216.34": [b""]}, peer_override="1.1.1.1"
    )
    backend = PinnedNetworkBackend(underlying)
    with pytest.raises(httpcore.ConnectError, match="no URLGuard-approved"):
        run(backend.connect_tcp("example.test", 443))

    backend.pin("example.test", 443, ["93.184.216.34"])
    with pytest.raises(httpcore.ConnectError, match="did not match"):
        run(backend.connect_tcp("example.test", 443))
    assert underlying.streams[0].closed is True


def test_fake_ip_and_private_dns_answers_remain_blocked():
    async def fake_ip_resolver(_host, _port):
        return ["198.18.0.1"]

    reader = ReaderService(
        reader_settings(),
        url_guard=URLGuard(resolver=fake_ip_resolver),
    )
    with pytest.raises(ServiceError) as captured:
        run(reader.read(ReadRequest(url="https://fake-ip.test/")))
    assert captured.value.code == "url_blocked"
