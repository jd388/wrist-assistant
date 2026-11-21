import math

import pytest
from pydantic import ValidationError

from app.schemas import (
    AskPageContext,
    AskRequest,
    FillRequest,
    FrameResponse,
    ReadRequest,
    ScrollRequest,
    TapRequest,
)


def test_fill_request_accepts_500_characters_and_rejects_501():
    assert len(FillRequest(text="字" * 500, submit=True).text) == 500
    with pytest.raises(ValidationError):
        FillRequest(text="字" * 501, submit=False)


@pytest.mark.parametrize(
    ("model", "arguments"),
    [
        (ScrollRequest, {"amount": math.nan}),
        (ScrollRequest, {"amount": math.inf}),
        (TapRequest, {"x": math.nan, "y": 0.5}),
    ],
)
def test_non_finite_numbers_are_rejected(model, arguments):
    with pytest.raises(ValidationError):
        model(**arguments)


def test_request_bodies_reject_unknown_fields():
    with pytest.raises(ValidationError):
        FillRequest(text="hello", submit=False, unexpected=True)


def test_frame_serializes_exact_snake_case_contract():
    frame = FrameResponse(
        session_id="abc",
        sequence=1,
        url="https://example.com/",
        title="Example",
        can_go_back=False,
        scroll_progress=0,
        image_base64="AA==",
        message="ok",
        focused_input=True,
        focused_input_label="Search",
    )
    assert frame.model_dump() == {
        "session_id": "abc",
        "sequence": 1,
        "url": "https://example.com/",
        "title": "Example",
        "can_go_back": False,
        "scroll_progress": 0.0,
        "image_base64": "AA==",
        "message": "ok",
        "focused_input": True,
        "focused_input_label": "Search",
    }


def test_read_limits_fit_watch_contract_and_reject_unknown_fields():
    request = ReadRequest(url="https://example.com")
    assert request.max_blocks == 40
    assert request.max_characters == 12_000
    assert request.max_links == 30
    with pytest.raises(ValidationError):
        ReadRequest(url="https://example.com", max_characters=20_001)
    with pytest.raises(ValidationError):
        ReadRequest(url="https://example.com", unexpected=True)


def test_answer_and_summary_require_their_relevant_input():
    with pytest.raises(ValidationError):
        AskRequest(question="   ")
    with pytest.raises(ValidationError):
        AskRequest(mode="summarize")
    summary = AskRequest(
        mode="summarize",
        page=AskPageContext(title="Page"),
    )
    assert summary.question == ""
    assert summary.page.title == "Page"
