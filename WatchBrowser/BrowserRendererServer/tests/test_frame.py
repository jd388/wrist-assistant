import io

import pytest
from PIL import Image, ImageDraw

from app.errors import ServiceError
from app.frame import JPEGEncoder, ScreenshotInspector


def png_bytes(image):
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def test_near_white_and_near_black_images_are_blank():
    inspector = ScreenshotInspector()
    white = inspector.inspect(png_bytes(Image.new("RGB", (396, 484), "white")))
    black = inspector.inspect(png_bytes(Image.new("RGB", (396, 484), "black")))
    assert white.is_near_blank is True
    assert white.tone == "white"
    assert black.is_near_blank is True
    assert black.tone == "black"


def test_transparent_image_is_composited_on_white_for_detection():
    transparent = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
    signal = ScreenshotInspector().inspect(png_bytes(transparent))
    assert signal.is_near_blank is True
    assert signal.tone == "white"


def test_visually_varied_image_is_not_blank():
    image = Image.new("RGB", (396, 484), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((40, 80, 356, 400), fill=(25, 90, 180))
    signal = ScreenshotInspector().inspect(png_bytes(image))
    assert signal.is_near_blank is False
    assert signal.tone is None


def test_jpeg_encoder_respects_48kb_contract():
    image = Image.effect_noise((396, 484), 80).convert("RGB")
    encoded = JPEGEncoder(maximum_bytes=48_000).encode(png_bytes(image))
    assert len(encoded) <= 48_000
    with Image.open(io.BytesIO(encoded)) as decoded:
        assert decoded.format == "JPEG"
        assert decoded.width <= 396


def test_invalid_screenshot_returns_structured_error():
    with pytest.raises(ServiceError) as captured:
        ScreenshotInspector().inspect(b"not an image")
    assert captured.value.code == "frame_encoding_failed"
