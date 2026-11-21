import pytest

from app.config import Settings


def test_environment_requires_non_empty_bearer_token(monkeypatch):
    monkeypatch.delenv("BROWSER_RENDERER_TOKEN", raising=False)
    with pytest.raises(RuntimeError, match="BROWSER_RENDERER_TOKEN"):
        Settings.from_environment()


def test_environment_trims_token_and_reads_positive_limits(monkeypatch):
    monkeypatch.setenv("BROWSER_RENDERER_TOKEN", "  secret  ")
    monkeypatch.setenv("BROWSER_RENDERER_MAX_SESSIONS", "3")
    configured = Settings.from_environment()
    assert configured.bearer_token == "secret"
    assert configured.max_sessions == 3


def test_non_positive_environment_limit_is_rejected(monkeypatch):
    monkeypatch.setenv("BROWSER_RENDERER_TOKEN", "secret")
    monkeypatch.setenv("BROWSER_RENDERER_MAX_SESSIONS", "0")
    with pytest.raises(RuntimeError, match="greater than zero"):
        Settings.from_environment()


def test_replace_existing_session_defaults_true_and_parses_false(monkeypatch):
    monkeypatch.setenv("BROWSER_RENDERER_TOKEN", "secret")
    assert Settings.from_environment().replace_existing_session is True
    monkeypatch.setenv("BROWSER_RENDERER_REPLACE_EXISTING_SESSION", "false")
    assert Settings.from_environment().replace_existing_session is False


def test_chromium_requires_explicit_egress_isolation_confirmation(monkeypatch):
    monkeypatch.setenv("BROWSER_RENDERER_TOKEN", "secret")
    monkeypatch.delenv(
        "BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED", raising=False
    )
    assert Settings.from_environment().chromium_egress_isolated is False
    monkeypatch.setenv("BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED", "true")
    assert Settings.from_environment().chromium_egress_isolated is True


def test_frame_limit_cannot_exceed_watch_contract():
    with pytest.raises(RuntimeError, match="cannot exceed 48000"):
        Settings(bearer_token="secret", maximum_image_bytes=48_001)


def test_ai_key_is_optional_and_prefers_renderer_specific_environment(monkeypatch):
    monkeypatch.setenv("BROWSER_RENDERER_TOKEN", "secret")
    monkeypatch.delenv("BROWSER_RENDERER_AI_API_KEY", raising=False)
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    assert Settings.from_environment().ai_api_key is None

    monkeypatch.setenv("DEEPSEEK_API_KEY", " fallback-key ")
    assert Settings.from_environment().ai_api_key == "fallback-key"
    monkeypatch.setenv("BROWSER_RENDERER_AI_API_KEY", " preferred-key ")
    configured = Settings.from_environment()
    assert configured.ai_api_key == "preferred-key"
    assert "preferred-key" not in repr(configured)


def test_ai_base_url_must_be_credential_free_https():
    with pytest.raises(RuntimeError, match="HTTPS base URL"):
        Settings(bearer_token="secret", ai_base_url="http://api.example.test")
    with pytest.raises(RuntimeError, match="HTTPS base URL"):
        Settings(
            bearer_token="secret",
            ai_base_url="https://user:pass@api.example.test",
        )
