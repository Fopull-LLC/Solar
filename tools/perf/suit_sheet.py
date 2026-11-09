#!/usr/bin/env python3
"""Contact sheets for suitshots.sh: a grid of named shots, or a before/after
pair per shot.

    python3 tools/perf/suit_sheet.py OUT.png DIR name1 name2 ...            # a grid
    python3 tools/perf/suit_sheet.py OUT.png --ab BEFORE AFTER name1 ...    # before | after rows
    --w 640   the width of one tile (default 640)
    --crop x0,y0,x1,y1   crop each shot first (fractions of the frame)
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fonts", "SolarMono.ttf")


def tile(path, w, crop):
    if not os.path.exists(path):
        im = Image.new("RGB", (w, w * 9 // 16), (40, 0, 0))
        return im
    im = Image.open(path).convert("RGB")
    if crop:
        W, H = im.size
        im = im.crop((int(crop[0] * W), int(crop[1] * H), int(crop[2] * W), int(crop[3] * H)))
    return im.resize((w, int(im.size[1] * w / im.size[0])), Image.LANCZOS)


def label(im, text):
    d = ImageDraw.Draw(im)
    try:
        f = ImageFont.truetype(FONT, 16)
    except OSError:
        f = ImageFont.load_default()
    b = d.textbbox((0, 0), text, font=f)
    d.rectangle([0, 0, b[2] + 10, b[3] + 8], fill=(0, 0, 0))
    d.text((5, 3), text, font=f, fill=(240, 240, 240))


def main():
    a = sys.argv[1:]
    w, crop = 640, None
    if "--w" in a:
        i = a.index("--w"); w = int(a[i + 1]); del a[i:i + 2]
    if "--crop" in a:
        i = a.index("--crop"); crop = [float(x) for x in a[i + 1].split(",")]; del a[i:i + 2]
    out = a[0]
    if a[1] == "--ab":
        before, after, names = a[2], a[3], a[4:]
        rows = []
        for n in names:
            l = tile(os.path.join(before, n + ".png"), w, crop); label(l, "BEFORE " + n)
            r = tile(os.path.join(after, n + ".png"), w, crop); label(r, "AFTER " + n)
            h = max(l.size[1], r.size[1])
            row = Image.new("RGB", (2 * w + 6, h), (20, 20, 20))
            row.paste(l, (0, 0)); row.paste(r, (w + 6, 0))
            rows.append(row)
        H = sum(r.size[1] for r in rows) + 6 * (len(rows) - 1)
        sheet = Image.new("RGB", (2 * w + 6, H), (20, 20, 20))
        y = 0
        for r in rows:
            sheet.paste(r, (0, y)); y += r.size[1] + 6
    else:
        d, names = a[1], a[2:]
        cols = 3 if len(names) > 4 else 2
        tiles = []
        for n in names:
            t = tile(os.path.join(d, n + ".png"), w, crop); label(t, n); tiles.append(t)
        th = max(t.size[1] for t in tiles)
        rows_n = (len(tiles) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * w + 6 * (cols - 1), rows_n * th + 6 * (rows_n - 1)), (20, 20, 20))
        for i, t in enumerate(tiles):
            sheet.paste(t, ((i % cols) * (w + 6), (i // cols) * (th + 6)))
    sheet.save(out)
    print(out, sheet.size)


if __name__ == "__main__":
    main()
