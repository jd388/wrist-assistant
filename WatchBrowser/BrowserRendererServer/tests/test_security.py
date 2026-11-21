import asyncio

import pytest

from app.errors import ServiceError
from app.security import URLGuard


def run(coroutine):
    return asyncio.run(coroutine)


def resolver_for(*addresses):
    async def resolve(_host, _port):
        return addresses

    return resolve


def assert_blocked(url, resolver=None):
    guard = URLGuard(resolver=resolver or resolver_for("93.184.216.34"))
    with pytest.raises(ServiceError) as captured:
        run(guard.validate(url))
    assert captured.value.code == "url_blocked"
    assert captured.value.retryable is False


def test_public_http_url_is_normalized_and_resolved():
    guard = URLGuard(resolver=resolver_for("2606:2800:220:1:248:1893:25c8:1946"))
    result = run(guard.validate("HTTPS://Example.COM?q=1#part"))
    assert result.url == "https://example.com/?q=1#part"
    assert result.host == "example.com"
    assert result.port == 443
    assert result.addresses == ("2606:2800:220:1:248:1893:25c8:1946",)


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "ftp://example.com/file",
        "https://user:secret@example.com/",
        "http://localhost/",
        "http://thing.local/",
        "http://service.internal/",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://127.0.0.1/",
        "http://10.0.0.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://224.0.0.1/",
        "http://[ff02::1]/",
        "http://[::1]/",
        "http://./",
        "http://bad_host.example/",
    ],
)
def test_forbidden_targets_are_blocked(url):
    assert_blocked(url)


def test_mixed_public_and_private_dns_answer_is_blocked():
    assert_blocked(
        "https://example.test/",
        resolver_for("93.184.216.34", "192.168.1.20"),
    )


def test_dns_failure_has_retryable_structured_error():
    async def failing_resolver(_host, _port):
        raise OSError("offline")

    with pytest.raises(ServiceError) as captured:
        run(URLGuard(resolver=failing_resolver).validate("https://example.test/"))
    assert captured.value.code == "dns_resolution_failed"
    assert captured.value.status_code == 502
    assert captured.value.retryable is True


def test_control_characters_are_rejected():
    assert_blocked("https://example.com/\tprivate")
