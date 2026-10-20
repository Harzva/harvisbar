#!/usr/bin/env python3
"""Generate the H.A.R.V.I.S. macOS app icon source PNG."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
DEFAULT_OUTPUT = PLUGIN_ROOT / "studio" / "assets" / "harvis-app-icon.png"


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def mix(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def load_font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size=size)
        except Exception:
            continue
    return ImageFont.load_default()


def gradient_square(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    top = (13, 23, 38)
    mid = (28, 65, 104)
    bottom = (9, 14, 22)
    for y in range(size):
        for x in range(size):
            dy = y / (size - 1)
            dx = x / (size - 1)
            base = mix(top, mid, min(1, dy * 1.25))
            base = mix(base, bottom, max(0, dy - 0.48) * 1.25)
            accent = int(28 * math.sin((dx + dy) * math.pi))
            pixels[x, y] = (
                min(255, base[0] + accent // 4),
                min(255, base[1] + accent // 2),
                min(255, base[2] + accent),
                255,
            )
    return image


def draw_arc_layer(size: int, scale: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    glow_draw = ImageDraw.Draw(glow)
    box = (168 * scale, 168 * scale, 856 * scale, 856 * scale)
    glow_box = (146 * scale, 146 * scale, 878 * scale, 878 * scale)
    arcs = [
        (205, 318, (114, 232, 255, 255)),
        (320, 44, (119, 167, 255, 255)),
        (48, 126, (255, 114, 199, 255)),
        (132, 198, (255, 209, 102, 255)),
    ]
    for start, end, color in arcs:
        extent = (end - start) % 360
        glow_draw.arc(glow_box, start=start, end=start + extent, fill=color[:3] + (130,), width=34 * scale)
        draw.arc(box, start=start, end=start + extent, fill=color, width=16 * scale)
    glow = glow.filter(ImageFilter.GaussianBlur(18 * scale))
    return Image.alpha_composite(glow, layer)


def generate_icon(output: Path) -> None:
    scale = 2
    size = 1024 * scale
    radius = 230 * scale
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = rounded_mask(size, radius)
    background = gradient_square(size)

    texture = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    texture_draw = ImageDraw.Draw(texture)
    for i in range(0, size, 86 * scale):
        texture_draw.line((i, 0, i - 420 * scale, size), fill=(255, 255, 255, 14), width=2 * scale)
    background = Image.alpha_composite(background, texture)

    canvas.paste(background, (0, 0), mask)
    draw = ImageDraw.Draw(canvas)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    tile = (242 * scale, 232 * scale, 782 * scale, 792 * scale)
    shadow_draw.rounded_rectangle(tile, radius=112 * scale, fill=(0, 0, 0, 125))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30 * scale))
    canvas = Image.alpha_composite(canvas, shadow)

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        tile,
        radius=112 * scale,
        fill=(8, 18, 32, 182),
        outline=(255, 255, 255, 46),
        width=2 * scale,
    )

    canvas = Image.alpha_composite(canvas, draw_arc_layer(size, scale))
    draw = ImageDraw.Draw(canvas)

    font = load_font(350 * scale, bold=True)
    text = "H"
    text_box = draw.textbbox((0, 0), text, font=font)
    text_w = text_box[2] - text_box[0]
    text_h = text_box[3] - text_box[1]
    text_x = (size - text_w) / 2
    text_y = (size - text_h) / 2 - 26 * scale
    glow_text = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow_text)
    glow_draw.text((text_x, text_y), text, font=font, fill=(114, 232, 255, 180))
    glow_text = glow_text.filter(ImageFilter.GaussianBlur(12 * scale))
    canvas = Image.alpha_composite(canvas, glow_text)
    draw = ImageDraw.Draw(canvas)
    draw.text((text_x + 4 * scale, text_y + 7 * scale), text, font=font, fill=(0, 0, 0, 118))
    draw.text((text_x, text_y), text, font=font, fill=(242, 248, 255, 255))

    wave_y = 720 * scale
    for index, height in enumerate([18, 28, 42, 28, 18]):
        cx = (448 + index * 32) * scale
        bar_h = height * scale
        draw.rounded_rectangle(
            (cx - 7 * scale, wave_y - bar_h / 2, cx + 7 * scale, wave_y + bar_h / 2),
            radius=7 * scale,
            fill=(165, 218, 232, 220),
        )

    for cx, cy, color in [
        (322, 704, (114, 232, 255, 255)),
        (702, 318, (255, 114, 199, 255)),
        (698, 698, (255, 209, 102, 255)),
    ]:
        r = 12 * scale
        draw.ellipse(((cx * scale) - r, (cy * scale) - r, (cx * scale) + r, (cy * scale) + r), fill=color)

    output.parent.mkdir(parents=True, exist_ok=True)
    final = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
    final.save(output)
    print(f"H.A.R.V.I.S. app icon source generated: {output}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    generate_icon(args.output.expanduser())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
