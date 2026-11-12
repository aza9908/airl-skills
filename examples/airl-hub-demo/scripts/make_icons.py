#!/usr/bin/env python3
"""Иконки PWA для оболочки хаба и сервисов: тёмный квадрат, звезда AIRL (фирменный акцент),
под звездой — подпись отдела. Maskable — с полем безопасности 20 %. Нужен Pillow."""
import math
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = {"hub": ("services/hub/public/icons", "AIRL"), "finance": ("services/finance/public/icons", "ФИН"),
           "sales": ("services/sales/public/icons", "ПРОД"), "edu": ("services/edu/public/icons", "ОБУЧ"),
           "hr": ("services/hr/public/icons", "HR"), "marketing": ("services/marketing/public/icons", "МАРК")}
BG, ACC, FG = (22, 22, 26), (143, 123, 240), (244, 244, 250)


def star(draw, cx, cy, r):
    pts = []
    for i in range(8):
        a = math.pi / 2 + i * math.pi / 4
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + rr * math.cos(a), cy - rr * math.sin(a)))
    draw.polygon(pts, fill=ACC)


def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def icon(size, label, safe=1.0, rounded=True):
    im = Image.new("RGBA", (size, size), BG + (255,) if not rounded else (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if rounded:
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=BG)
    s = size * safe
    off = (size - s) / 2
    star(d, size / 2, off + s * 0.40, s * 0.30)
    f = font(int(s * 0.15))
    w = d.textlength(label, font=f)
    d.text(((size - w) / 2, off + s * 0.74), label, font=f, fill=FG)
    return im


for key, (rel, label) in TARGETS.items():
    out = os.path.join(ROOT, rel)
    os.makedirs(out, exist_ok=True)
    icon(192, label).save(os.path.join(out, "icon-192.png"))
    icon(512, label).save(os.path.join(out, "icon-512.png"))
    icon(512, label, safe=0.8, rounded=False).save(os.path.join(out, "maskable-512.png"))
    icon(180, label, rounded=False).save(os.path.join(out, "apple-touch-icon.png"))
print("иконки готовы")
