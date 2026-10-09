"""Draws the app icon and writes Support/AppIcon.png plus the Xcode asset catalog.

Black glass tile with nested silver outlines of a page with a folded corner.
Run with Pillow installed: python3 scripts/make_icon.py
"""
import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 3                      # supersampling factor
S = 1024 * SCALE


def s(v):
    return int(round(v * SCALE))


def vertical_gradient(size, stops):
    """stops: list of (position 0...1, (r, g, b, a))."""
    w, h = size
    column = Image.new("RGBA", (1, h))
    px = column.load()
    for y in range(h):
        t = y / (h - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                f = 0 if p1 == p0 else (t - p0) / (p1 - p0)
                px[0, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * f) for i in range(4))
                break
    return column.resize((w, h))


def rounded_polygon(vertices, radius, steps=24):
    """Closed polyline through `vertices` with each corner rounded."""
    points = []
    n = len(vertices)
    for i in range(n):
        prev, cur, nxt = vertices[i - 1], vertices[i], vertices[(i + 1) % n]
        v1 = (prev[0] - cur[0], prev[1] - cur[1])
        v2 = (nxt[0] - cur[0], nxt[1] - cur[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1, u2 = (v1[0] / l1, v1[1] / l1), (v2[0] / l2, v2[1] / l2)
        angle = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        r = min(radius, l1 / 2.2, l2 / 2.2)
        d = r / math.tan(angle / 2)
        a = (cur[0] + u1[0] * d, cur[1] + u1[1] * d)
        b = (cur[0] + u2[0] * d, cur[1] + u2[1] * d)
        # Quadratic Bezier from a to b with the vertex as control point.
        for k in range(steps + 1):
            t = k / steps
            x = (1 - t) ** 2 * a[0] + 2 * (1 - t) * t * cur[0] + t ** 2 * b[0]
            y = (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * cur[1] + t ** 2 * b[1]
            points.append((x, y))
    return points


def page_vertices(cx, cy, w, h, fold):
    left, top, right, bottom = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    return [(left, top), (right - fold, top), (right, top + fold), (right, bottom), (left, bottom)]


canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
body = (s(100), s(100), s(924), s(924))
radius = s(185)

# Drop shadow under the tile.
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + s(12), body[2], body[3] + s(12)), radius=radius, fill=(0, 0, 0, 150))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(16))))

tile_mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(tile_mask).rounded_rectangle(body, radius=radius, fill=255)

# Black glass: near-black gradient, slightly lifted at the top.
glass = vertical_gradient((S, S), [(0.0, (40, 40, 44, 255)), (0.5, (13, 13, 14, 255)), (1.0, (4, 4, 5, 255))])
canvas.paste(glass, (0, 0), tile_mask)

# Faint reflection across the upper half.
sheen = Image.new("L", (S, S), 0)
ImageDraw.Draw(sheen).ellipse((s(-200), s(-600), s(1224), s(440)), fill=22)
sheen = ImageChops.multiply(sheen.filter(ImageFilter.GaussianBlur(s(110))), tile_mask)
white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
white.putalpha(sheen)
canvas.alpha_composite(white)

# Rim light: a thin edge, bright at the top and fading toward the bottom.
rim = Image.new("L", (S, S), 0)
ImageDraw.Draw(rim).rounded_rectangle(body, radius=radius, outline=255, width=s(3))
rim_fade = vertical_gradient((S, S), [(0.0, (0, 0, 0, 150)), (0.35, (0, 0, 0, 55)), (1.0, (0, 0, 0, 25))]).getchannel("A")
rim_light = Image.new("RGBA", (S, S), (255, 255, 255, 255))
rim_light.putalpha(ImageChops.multiply(rim, rim_fade))
canvas.alpha_composite(rim_light)

# Nested page outlines, each drawn as a filled ring (outer shape minus inner shape).
lines = Image.new("L", (S, S), 0)
ld = ImageDraw.Draw(lines)
cx, cy = s(512), s(512)
stroke = 14
diagonal = math.sqrt(2) - 1      # how much the fold grows per unit of outward offset
for i in range(4):
    inset = i * 42
    w, h = 404 - inset * 2, 512 - inset * 2
    fold = 112 - inset * 0.5
    corner = max(36 - i * 6, 14)
    for offset, value in ((stroke / 2, 255), (-stroke / 2, 0)):
        shape = rounded_polygon(
            page_vertices(cx, cy, s(w + 2 * offset), s(h + 2 * offset), s(fold + offset * diagonal)),
            s(corner + offset),
        )
        ld.polygon(shape, fill=value)

# Silver: bright at the top, darker toward the bottom, like brushed metal.
silver = vertical_gradient((S, S), [(0.0, (255, 255, 255, 255)), (0.3, (236, 236, 240, 255)), (0.62, (176, 176, 184, 255)), (1.0, (120, 120, 128, 255))])

glyph_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 255))
glyph_shadow.putalpha(lines.filter(ImageFilter.GaussianBlur(s(7))).point(lambda a: int(a * 0.7)))
canvas.alpha_composite(glyph_shadow, (0, s(6)))

glyph = silver.copy()
glyph.putalpha(lines)
canvas.alpha_composite(glyph)

icon = canvas.resize((1024, 1024), Image.LANCZOS)
support = os.path.join(ROOT, "Support")
icon.save(os.path.join(support, "AppIcon.png"))

# Xcode asset catalog with every macOS size.
catalog = os.path.join(support, "Assets.xcassets")
iconset = os.path.join(catalog, "AppIcon.appiconset")
os.makedirs(iconset, exist_ok=True)
with open(os.path.join(catalog, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        icon.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(iconset, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
with open(os.path.join(iconset, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
print("wrote", os.path.join(support, "AppIcon.png"))
