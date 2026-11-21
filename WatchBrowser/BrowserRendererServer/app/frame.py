from __future__ import annotations

import io
from dataclasses import dataclass
from typing import Optional, Sequence

from PIL import Image

from .errors import ServiceError


class JPEGEncoder:
    """Produces a bounded JPEG suitable for direct watchOS HTTPS responses."""

    def __init__(self, maximum_bytes: int = 48_000) -> None:
        self.maximum_bytes = maximum_bytes

    def encode(self, source: bytes) -> bytes:
        try:
            with Image.open(io.BytesIO(source)) as opened:
                image = opened.convert("RGB")
        except (OSError, ValueError) as exc:
            raise ServiceError(
                code="frame_encoding_failed",
                message="Chromium returned an invalid screenshot.",
                status_code=500,
                retryable=True,
            ) from exc

        widths = self._candidate_widths(image.width)
        qualities = (68, 58, 48, 38, 30, 24, 18)
        current = image
        for width in widths:
            if width < current.width:
                height = max(1, round(current.height * width / current.width))
                current = current.resize((width, height), Image.Resampling.LANCZOS)
            for quality in qualities:
                output = io.BytesIO()
                current.save(
                    output,
                    format="JPEG",
                    quality=quality,
                    optimize=True,
                    progressive=False,
                    subsampling="4:2:0",
                )
                data = output.getvalue()
                if len(data) <= self.maximum_bytes:
                    return data

        raise ServiceError(
            code="frame_too_large",
            message=(
                "The page image could not be reduced to the configured frame limit."
            ),
            status_code=500,
            retryable=True,
        )

    @staticmethod
    def _candidate_widths(original: int) -> Sequence[int]:
        candidates = [original, 360, 320, 280, 240, 200, 160]
        return tuple(dict.fromkeys(max(1, min(original, value)) for value in candidates))


@dataclass(frozen=True)
class ScreenshotSignal:
    is_near_blank: bool
    tone: Optional[str]
    near_white_ratio: float
    near_black_ratio: float


class ScreenshotInspector:
    """Detects screenshots that are effectively all white or all black."""

    def __init__(self, blank_ratio: float = 0.985) -> None:
        if not 0.9 <= blank_ratio <= 1.0:
            raise ValueError("blank_ratio must be between 0.9 and 1.0")
        self.blank_ratio = blank_ratio

    def inspect(self, source: bytes) -> ScreenshotSignal:
        try:
            with Image.open(io.BytesIO(source)) as opened:
                image = self._flatten(opened)
                image.thumbnail((96, 96), Image.Resampling.LANCZOS)
                pixels = list(image.getdata())
        except (OSError, ValueError) as exc:
            raise ServiceError(
                code="frame_encoding_failed",
                message="Chromium returned an invalid screenshot.",
                status_code=500,
                retryable=True,
            ) from exc

        total = max(1, len(pixels))
        near_white = sum(
            1 for red, green, blue in pixels if min(red, green, blue) >= 242
        )
        near_black = sum(
            1 for red, green, blue in pixels if max(red, green, blue) <= 13
        )
        white_ratio = near_white / total
        black_ratio = near_black / total
        if white_ratio >= self.blank_ratio:
            tone: Optional[str] = "white"
        elif black_ratio >= self.blank_ratio:
            tone = "black"
        else:
            tone = None
        return ScreenshotSignal(
            is_near_blank=tone is not None,
            tone=tone,
            near_white_ratio=white_ratio,
            near_black_ratio=black_ratio,
        )

    @staticmethod
    def _flatten(opened: Image.Image) -> Image.Image:
        if "A" not in opened.getbands():
            return opened.convert("RGB")
        rgba = opened.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        return Image.alpha_composite(background, rgba).convert("RGB")
