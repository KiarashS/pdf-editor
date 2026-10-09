"""Draws the app icon and writes Support/AppIcon.png plus the Xcode asset catalog.

Run with Pillow installed: python3 scripts/make_icon.py
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 2                      # supersampling factor
S = 1024 * SCALE


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    for y in range(h):
        c = lerp(top, bottom, y / (h - 1))
        for x in range(w):
            px[x, y] = c
    return img


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def s(v):
    return int(v * SCALE)


canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Icon body: the macOS grid uses an 824 pt square with ~185 pt corners on a 1024 canvas.
body = (s(100), s(100), s(924), s(924))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + s(14), body[2], body[3] + s(14)), radius=s(185), fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(s(18)))
canvas.alpha_composite(shadow)

background = vertical_gradient((S, S), (255, 112, 92, 255), (200, 30, 60, 255))
canvas.paste(background, (0, 0), rounded_mask((S, S), body, s(185)))

# Document page with a folded corner.
left, top, right, bottom = s(262), s(212), s(762), s(842)
fold = s(130)
page_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(page_shadow).polygon(
    [(left, top + s(12)), (right - fold, top + s(12)), (right, top + fold + s(12)), (right, bottom + s(12)), (left, bottom + s(12))],
    fill=(90, 0, 20, 110),
)
page_shadow = page_shadow.filter(ImageFilter.GaussianBlur(s(16)))
canvas.alpha_composite(page_shadow)

draw = ImageDraw.Draw(canvas)
draw.polygon([(left, top), (right - fold, top), (right, top + fold), (right, bottom), (left, bottom)], fill=(255, 255, 255, 255))
draw.polygon([(right - fold, top), (right - fold, top + fold), (right, top + fold)], fill=(255, 205, 200, 255))

# Text lines, one of them highlighted.
line_left = left + s(62)
y = top + s(150)
widths = [300, 330, 250, 330, 290, 200]
for i, w in enumerate(widths):
    if i == 2:
        draw.rounded_rectangle((line_left - s(14), y - s(18), line_left + s(w) + s(14), y + s(40)), radius=s(10), fill=(255, 214, 10, 255))
    draw.rounded_rectangle((line_left, y, line_left + s(w), y + s(22)), radius=s(11), fill=(70, 74, 86, 255) if i != 2 else (60, 50, 20, 255))
    y += s(72)

# Pen crossing the bottom-right corner of the page.
pen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pd = ImageDraw.Draw(pen)
cx, cy = s(512), s(512)
length, width = s(520), s(78)
x0 = cx - length // 2
pd.rounded_rectangle((x0, cy - width // 2, x0 + length, cy + width // 2), radius=s(20), fill=(38, 42, 56, 255))
pd.rectangle((x0 + length - s(120), cy - width // 2, x0 + length - s(96), cy + width // 2), fill=(200, 204, 214, 255))
pd.polygon([(x0, cy - width // 2), (x0, cy + width // 2), (x0 - s(92), cy)], fill=(244, 214, 170, 255))
pd.polygon([(x0 - s(60), cy - s(13)), (x0 - s(60), cy + s(13)), (x0 - s(92), cy)], fill=(38, 42, 56, 255))
pen = pen.rotate(40, resample=Image.BICUBIC, center=(cx, cy))
pen_shadow = pen.copy()
pen_shadow.putalpha(pen.getchannel("A").point(lambda a: a * 0.35))
black = Image.new("RGBA", (S, S), (60, 0, 15, 255))
black.putalpha(pen_shadow.getchannel("A"))
black = black.filter(ImageFilter.GaussianBlur(s(12)))
offset = (s(150), s(205))
canvas.alpha_composite(black, (offset[0] + s(10), offset[1] + s(18)))
canvas.alpha_composite(pen, offset)

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
