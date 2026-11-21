from __future__ import annotations

from typing import List, Literal, Optional, Self

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictBody(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class OpenRequest(StrictBody):
    url: str = Field(min_length=1, max_length=4096)
    viewport_width: int = Field(default=396, ge=160, le=512)
    viewport_height: int = Field(default=484, ge=160, le=640)


class ScrollRequest(StrictBody):
    amount: float = Field(ge=-3.0, le=3.0)

    @field_validator("amount")
    @classmethod
    def amount_must_be_finite(cls, value: float) -> float:
        if not (-3.0 <= value <= 3.0):
            raise ValueError("amount must be finite and between -3 and 3")
        return value


class TapRequest(StrictBody):
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)

    @field_validator("x", "y")
    @classmethod
    def coordinate_must_be_finite(cls, value: float) -> float:
        if not (0.0 <= value <= 1.0):
            raise ValueError("coordinate must be finite and between 0 and 1")
        return value


class FillRequest(StrictBody):
    text: str = Field(max_length=500)
    submit: bool = False


class EmptyRequest(StrictBody):
    pass


class ReadRequest(StrictBody):
    url: str = Field(min_length=1, max_length=4096)
    prefer_dynamic: bool = False
    max_blocks: int = Field(default=40, ge=1, le=80)
    max_characters: int = Field(default=12_000, ge=500, le=20_000)
    max_links: int = Field(default=30, ge=0, le=60)


class ReadBlock(BaseModel):
    kind: Literal["heading", "paragraph", "list_item", "quote", "code"]
    text: str = Field(min_length=1, max_length=20_000)


class ReadLink(BaseModel):
    text: str = Field(min_length=1, max_length=160)
    url: str = Field(min_length=1, max_length=4096)


class ReadResponse(BaseModel):
    url: str
    final_url: str
    title: str
    blocks: List[ReadBlock]
    links: List[ReadLink]
    truncated: bool
    links_truncated: bool = False
    character_count: int = Field(ge=0)
    total_character_count: int = Field(ge=0)
    source: Literal["static", "browser"]
    blocked_subresources: int = Field(default=0, ge=0)


class AskPageContext(StrictBody):
    url: Optional[str] = Field(default=None, max_length=4096)
    title: Optional[str] = Field(default=None, max_length=512)
    blocks: List[ReadBlock] = Field(default_factory=list, max_length=80)

    @model_validator(mode="after")
    def has_context(self) -> Self:
        if not any(
            (
                self.url and self.url.strip(),
                self.title and self.title.strip(),
                self.blocks,
            )
        ):
            raise ValueError("page must contain a URL, title, or content block")
        return self


class AskRequest(StrictBody):
    question: str = Field(default="", max_length=2_000)
    mode: Literal["answer", "summarize"] = "answer"
    web_search: bool = False
    page: Optional[AskPageContext] = None

    @model_validator(mode="after")
    def valid_question_for_mode(self) -> Self:
        normalized = self.question.strip()
        if self.mode == "answer" and not normalized:
            raise ValueError("question must not be empty in answer mode")
        if self.mode == "summarize" and self.page is None:
            raise ValueError("page is required in summarize mode")
        self.question = normalized
        return self


class Citation(BaseModel):
    title: str = Field(min_length=1, max_length=512)
    url: str = Field(min_length=1, max_length=4096)


class AskResponse(BaseModel):
    answer: str = Field(min_length=1)
    citations: List[Citation] = Field(default_factory=list)
    model: str
    web_search_used: bool
    page_context_used: bool
    truncated: bool = False


class FrameResponse(BaseModel):
    session_id: str
    sequence: int = Field(ge=1)
    url: str
    title: str
    can_go_back: bool
    scroll_progress: float = Field(ge=0.0, le=1.0)
    image_base64: str
    message: str
    focused_input: bool = False
    focused_input_label: Optional[str] = None


class HealthResponse(BaseModel):
    status: str
    browser_ready: bool
    browser_egress_isolated: bool = False
    reader_ready: bool = True
    ai_configured: bool = False
    active_sessions: int = Field(ge=0)
    max_sessions: int = Field(ge=1)
    detail: Optional[str] = None
