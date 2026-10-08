#!/usr/bin/env python3
"""Draws Resources/AppIcon.icns: the bubble's cyan→blue→indigo droplet on a
macOS-style rounded square. Requires Pillow (pip install pillow)."""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
SCALE = 4  # supersampling for smooth edges


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vertical_gradient(size, stops):
    width, height = size
    column = Image.new("RGBA", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                column.putpixel((0, y), lerp(c0, c1, (t - p0) / (p1 - p0)) + (255,))
                break
    return column.resize(size)


def cubic(p0, p1, p2, p3, steps=96):
    return [tuple((1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t ** 2 * c + t ** 3 * d
                  for a, b, c, d in zip(p0, p1, p2, p3)) for t in (i / steps for i in range(steps + 1))]


def quad(p0, p1, p2, steps=96):
    return [tuple((1 - t) ** 2 * a + 2 * (1 - t) * t * b + t ** 2 * c
                  for a, b, c in zip(p0, p1, p2)) for t in (i / steps for i in range(steps + 1))]


def droplet_path(x, y, w, h):
    """Same construction as DropletShape in Views.swift."""
    y0, r = h * 0.60, w * 0.5
    k = 0.5523 * r
    pts = quad((w * 0.5, 0), (w * 0.06, h * 0.26), (0, y0))
    pts += cubic((0, y0), (0, y0 + k), (w * 0.5 - k, y0 + r), (w * 0.5, y0 + r))
    pts += cubic((w * 0.5, y0 + r), (w * 0.5 + k, y0 + r), (w, y0 + k), (w, y0))
    pts += quad((w, y0), (w * 0.94, h * 0.26), (w * 0.5, 0))
    return [(x + px, y + py) for px, py in pts]


def render():
    s = SIZE * SCALE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Rounded-square plate (Big Sur grid: 824/1024 with ~185 radius).
    inset, radius = round(100 * SCALE), round(185 * SCALE)
    plate_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(plate_mask).rounded_rectangle((inset, inset, s - inset, s - inset), radius, fill=255)
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shadow.putalpha(plate_mask.point(lambda v: v * 0.35))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SCALE))
    canvas.alpha_composite(shadow, (0, 10 * SCALE))
    plate = vertical_gradient((s, s), [(0.0, (246, 250, 255)), (1.0, (214, 228, 247))])
    plate.putalpha(plate_mask)
    canvas.alpha_composite(plate)

    # Droplet with its gradient and a soft blue shadow.
    dw, dh = 470 * SCALE, 600 * SCALE
    dx, dy = (s - dw) // 2, 205 * SCALE
    drop_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(drop_mask).polygon(droplet_path(dx, dy, dw, dh), fill=255)
    glow = Image.new("RGBA", (s, s), (31, 90, 230, 0))
    glow.putalpha(drop_mask.point(lambda v: v * 0.45))
    glow = glow.filter(ImageFilter.GaussianBlur(30 * SCALE))
    canvas.alpha_composite(glow, (0, 26 * SCALE))
    body = vertical_gradient((s, s), [(0.0, (0, 0, 0)), (dy / s, (40, 214, 240)),
                                      ((dy + dh * 0.55) / s, (28, 110, 238)), ((dy + dh) / s, (88, 72, 214)), (1.0, (88, 72, 214))])
    body.putalpha(drop_mask)
    canvas.alpha_composite(body)

    # Highlight, like the bubble's white ellipse.
    highlight = Image.new("L", (s, s), 0)
    hx, hy = dx + dw * 0.24, dy + dh * 0.52
    ImageDraw.Draw(highlight).ellipse((hx, hy, hx + dw * 0.17, hy + dh * 0.22), fill=150)
    highlight = highlight.filter(ImageFilter.GaussianBlur(9 * SCALE))
    highlight = ImageChops.multiply(highlight, drop_mask)
    white = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    white.putalpha(highlight)
    canvas.alpha_composite(white)

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    icon = render()
    resources = ROOT / "Resources"
    resources.mkdir(exist_ok=True)
    icon.save(resources / "AppIcon.png")
    icon.save(resources / "AppIcon.icns",
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print(f"Wrote {resources / 'AppIcon.icns'}")


if __name__ == "__main__":
    main()
