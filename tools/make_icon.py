#!/usr/bin/env python3
"""Draws the app icon (1024 px, opaque): a white page with the Armenian letter Հ and a pen line,
on the app's blue. Usage: python3 tools/make_icon.py <out.png> <Noto Serif Armenian .ttf>"""
import sys
from PIL import Image, ImageDraw, ImageFont

out, font_path = sys.argv[1], sys.argv[2]
S = 1024
img = Image.new("RGB", (S, S), (33, 92, 217))
d = ImageDraw.Draw(img)
# Soft vertical shade.
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(40 - 14 * t), int(104 - 22 * t), int(228 - 18 * t)))
# The page, with a folded corner.
x0, y0, x1, y1, fold = 262, 170, 762, 854, 120
shadow = Image.new("L", (S, S), 0)
ds = ImageDraw.Draw(shadow)
ds.rounded_rectangle([x0 + 10, y0 + 22, x1 + 10, y1 + 22], radius=44, fill=90)
from PIL import ImageFilter
shadow = shadow.filter(ImageFilter.GaussianBlur(26))
img.paste((10, 40, 110), (0, 0), shadow)
d = ImageDraw.Draw(img)
d.rounded_rectangle([x0, y0, x1, y1], radius=44, fill=(255, 255, 255))
d.polygon([(x1 - fold, y0), (x1 + 1, y0), (x1 + 1, y0 + fold)], fill=(40, 104, 228))
d.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold - 18), (x1 - 18, y0 + fold), (x1, y0 + fold)], fill=(214, 226, 248))
# The letter.
font = ImageFont.truetype(font_path, 430)
try:
    font.set_variation_by_name("Bold")
except Exception:
    pass
letter = "Հ"
box = d.textbbox((0, 0), letter, font=font)
w, h = box[2] - box[0], box[3] - box[1]
d.text(((x0 + x1) / 2 - w / 2 - box[0], y0 + 300 - h / 2 - box[1]), letter, font=font, fill=(33, 92, 217))
# A pen stroke under it.
pts = []
import math
for i in range(60):
    t = i / 59
    pts.append((x0 + 90 + t * 320, y0 + 560 + math.sin(t * math.pi * 2.2) * 26))
d.line(pts, fill=(242, 168, 0), width=26, joint="curve")
for p in (pts[0], pts[-1]):
    d.ellipse([p[0] - 13, p[1] - 13, p[0] + 13, p[1] + 13], fill=(242, 168, 0))
img.save(out)
print(out)
