#!/usr/bin/env python3
"""Draws the DMG window background: background.png (640x420) and background@2x.png.

Colors come from the Foliarium product page (semicolon.consulting/foliarium): navy #262b63 text,
brand blue #0B4AA2 to teal #0D9488 for the app name, and the soft blue / lavender / peach wash.
The app icon and the Applications folder are drawn by Finder on top, at the positions set in
scripts/dmg-settings.py, so keep the two in step.

Needs Pillow and the Inter font (https://rsms.me/inter/). Run from anywhere:
    python3 Design/dmg/make-background.py [/path/to/Inter-Bold.otf] [/path/to/Inter-Medium.otf]
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H = 640, 380          # Finder window content size, in points
S = 2                    # draw at 2x, then downscale for the 1x file
APP_X, MIDDLE_Y, APPS_X = 170, 222, 470  # icon centres, in points (see scripts/dmg-settings.py)

HERE = os.path.dirname(os.path.abspath(__file__))
BOLD = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/opentype/inter/Inter-Bold.otf"
MEDIUM = sys.argv[2] if len(sys.argv) > 2 else "/usr/share/fonts/opentype/inter/Inter-Medium.otf"

NAVY = (38, 43, 99)
MUTED = (97, 97, 120)
BLUE = (11, 74, 162)
SKY = (63, 178, 236)
TEAL = (13, 148, 136)


def hgradient(size, stops):
    """A left-to-right gradient image through the given (position, rgb) stops."""
    w, h = size
    row = Image.new("RGB", (w, 1))
    px = row.load()
    for x in range(w):
        t = x / max(w - 1, 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                k = (t - p0) / (p1 - p0) if p1 > p0 else 0
                px[x, 0] = tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
                break
    return row.resize((w, h))


def background():
    w, h = W * S, H * S
    img = Image.new("RGB", (w, h), (250, 250, 253))
    wash = Image.new("RGB", (w, h), (250, 250, 253))
    d = ImageDraw.Draw(wash)
    # Soft colour blobs, blurred into a wash (product page: #7fb7d9, #b9a6d9, #f2c4a8, teal).
    for (cx, cy, r, color) in [
        (60, 40, 210, (196, 220, 240)),    # sky blue, top left
        (600, 30, 200, (246, 222, 210)),   # peach, top right
        (430, 0, 150, (228, 220, 244)),    # lavender, top
        (620, 380, 190, (206, 236, 230)),  # mint/teal, bottom right
        (40, 390, 160, (224, 226, 246)),   # lavender, bottom left
    ]:
        d.ellipse([(cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S], fill=color)
    wash = wash.filter(ImageFilter.GaussianBlur(90 * S))
    img = Image.blend(img, wash, 0.9)
    return img


def draw_text(img, y, parts, font):
    """Draws a centred line made of (text, fill) parts; fill is an rgb tuple or a gradient stop list."""
    d = ImageDraw.Draw(img)
    widths = [d.textlength(t, font=font) for t, _ in parts]
    x = (img.width - sum(widths)) / 2
    for (text, fill), width in zip(parts, widths):
        if isinstance(fill, tuple):
            d.text((x, y), text, font=font, fill=fill)
        else:
            mask = Image.new("L", img.size, 0)
            ImageDraw.Draw(mask).text((x, y), text, font=font, fill=255)
            box = mask.getbbox()
            grad = Image.new("RGB", img.size)
            grad.paste(hgradient((box[2] - box[0], img.height), fill), (box[0], 0))
            img.paste(grad, (0, 0), mask)
        x += width


def draw_arrow(img):
    """A short gradient arrow between the two icons."""
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    x0, x1, y = 282 * S, 358 * S, MIDDLE_Y * S
    t = 7 * S  # stroke width
    d.line([(x0, y), (x1 - 4 * S, y)], fill=255, width=t)
    d.ellipse([x0 - t / 2, y - t / 2, x0 + t / 2, y + t / 2], fill=255)
    head = 18 * S
    for dy in (-1, 1):
        d.line([(x1, y), (x1 - head, y + dy * head)], fill=255, width=t)
        cx, cy = x1 - head, y + dy * head
        d.ellipse([cx - t / 2, cy - t / 2, cx + t / 2, cy + t / 2], fill=255)
    d.ellipse([x1 - t / 2, y - t / 2, x1 + t / 2, y + t / 2], fill=255)
    grad = Image.new("RGB", (w, h))
    grad.paste(hgradient((x1 - x0 + t, h), [(0, SKY), (0.55, BLUE), (1, TEAL)]), (int(x0 - t / 2), 0))
    # A faint shadow under the arrow.
    shadow = mask.filter(ImageFilter.GaussianBlur(4 * S)).point(lambda v: v * 0.18)
    shadow = ImageChops.offset(shadow, 0, 3 * S)
    img.paste((11, 40, 110), (0, 0), shadow)
    img.paste(grad, (0, 0), mask)


def main():
    img = background()
    headline = ImageFont.truetype(BOLD, 27 * S)
    tagline = ImageFont.truetype(MEDIUM, 14 * S)
    draw_text(img, 56 * S, [("Drag ", NAVY), ("Foliarium", [(0, SKY), (0.45, BLUE), (1, TEAL)]),
                            (" into Applications", NAVY)], headline)
    draw_text(img, 98 * S, [("Tidies your Mac’s folders by itself", MUTED)], tagline)
    draw_arrow(img)
    img.save(os.path.join(HERE, "background@2x.png"), optimize=True)
    img.resize((W, H), Image.LANCZOS).save(os.path.join(HERE, "background.png"), optimize=True)


if __name__ == "__main__":
    main()
