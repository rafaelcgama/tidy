#!/usr/bin/env python3
"""Draws Tidy's app icon (an original design: sparkles on a mint-to-teal tile) into
Resources/AppIcon.iconset. Needs Pillow. scripts/make-app.sh turns the iconset into AppIcon.icns."""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 4096  # drawn large, then scaled down for smooth edges
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon.iconset")


def sparkle(cx, cy, radius, sharpness=3.4, steps=1440):
    """A four-pointed star with curved sides (a fattened astroid)."""
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        points.append((cx + radius * math.copysign(abs(c) ** sharpness, c),
                       cy + radius * math.copysign(abs(s) ** sharpness, s)))
    return points


def draw():
    u = SIZE / 1024  # design units are on a 1024 canvas
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    body = (100 * u, 100 * u, 924 * u, 924 * u)
    radius = 186 * u

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + 14 * u, body[2], body[3] + 14 * u),
                                             radius=radius, fill=(0, 0, 0, 90))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * u)))

    top, bottom = (94, 234, 212), (14, 116, 144)
    gradient = Image.new("RGBA", (SIZE, SIZE))
    pen = ImageDraw.Draw(gradient)
    for y in range(SIZE):
        t = min(max((y - body[1]) / (body[3] - body[1]), 0), 1)
        pen.line([(0, y), (SIZE, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius=radius, fill=255)
    image.paste(gradient, (0, 0), mask)

    pen = ImageDraw.Draw(image)
    pen.polygon(sparkle(460 * u, 565 * u, 290 * u), fill=(255, 255, 255, 255))
    pen.polygon(sparkle(712 * u, 318 * u, 135 * u), fill=(255, 255, 255, 235))
    pen.polygon(sparkle(742 * u, 712 * u, 75 * u), fill=(255, 255, 255, 215))
    return image.resize((1024, 1024), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    icon = draw()
    for base in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            name = f"icon_{base}x{base}{'@2x' if factor == 2 else ''}.png"
            icon.resize((base * factor, base * factor), Image.LANCZOS).save(os.path.join(OUT, name))
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
