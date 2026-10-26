#!/usr/bin/env python3
"""Bake the agency emblem's two alphabets into scripts/emblem.lua.

    python3 tools/gen_emblem_glyphs.py

The emblem (scripts/emblem.lua) is rasterised in Lua at run time from a small
spec, so a save carries no pixels and the engine needs no font for it. Its
letters come from the project's own faces, baked here into signed-distance
fields and written into the script between the GLYPHS markers:

    stencil   fonts/SolarStencil.ttf (Saira Stencil One): the monogram
    label     fonts/SolarLabel.ttf (Barlow Semi Condensed SemiBold): the name
              round a patch's band, on a shield's chief and under a flag

Each glyph is a distance field on a grid of CAP/40 units: 40 units is the
capital height, a sample is the signed distance to the outline (negative
inside), clamped to +-RANGE units and stored as one base64 character (64
levels). A distance field scales up smoothly and antialiases at any size with
one comparison per pixel, so a 40-unit glyph draws cleanly 120 pixels tall.

Both faces are SIL OFL 1.1 (fonts/README.md); the baked outlines are a
modified form of them and stay under that licence.
"""
import os
import re

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "scripts", "emblem.lua")
FACES = {
    "stencil": os.path.join(ROOT, "fonts", "SolarStencil.ttf"),
    "label": os.path.join(ROOT, "fonts", "SolarLabel.ttf"),
}
CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&-.'!?/+"
CAP = 40          # units per capital height
SS = 6            # hi-res pixels per unit
RANGE = 4.0       # units either side of the outline that the field keeps
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def face_at(path):
    # Find the point size whose capital H is CAP*SS pixels tall.
    size = 200
    for _ in range(6):
        f = ImageFont.truetype(path, size)
        bb = f.getbbox("H")
        h = bb[3] - bb[1]
        size = int(round(size * CAP * SS / h))
    f = ImageFont.truetype(path, size)
    return f, f.getbbox("H")[1]   # the cap top's offset below the draw origin


def bake(f, cap_top, ch):
    pad = int(RANGE * SS) + SS
    bb = f.getbbox(ch)
    W = bb[2] - bb[0] + 2 * pad
    H = bb[3] - bb[1] + 2 * pad
    img = Image.new("L", (W, H), 0)
    ImageDraw.Draw(img).text((pad - bb[0], pad - bb[1]), ch, font=f, fill=255)
    m = np.asarray(img) >= 128
    # Boundary pixels: inside pixels with an outside 4-neighbour, and vice versa.
    p = np.pad(m, 1)
    nb_out = ~p[:-2, 1:-1] | ~p[2:, 1:-1] | ~p[1:-1, :-2] | ~p[1:-1, 2:]
    nb_in = p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]
    edge = (m & nb_out) | (~m & nb_in)
    ey, ex = np.nonzero(edge)
    ex = ex.astype(np.float32) + 0.5
    ey = ey.astype(np.float32) + 0.5
    gw, gh = W // SS, H // SS
    out = []
    for gy in range(gh):
        sy = (gy + 0.5) * SS
        sxs = (np.arange(gw, dtype=np.float32) + 0.5) * SS
        d = np.sqrt(np.min((sxs[:, None] - ex[None, :]) ** 2 + (sy - ey[None, :]) ** 2, axis=1)) / SS
        ins = m[int(sy), np.minimum((sxs).astype(int), W - 1)]
        d = np.where(ins, -d, d)
        q = np.clip(np.round((np.clip(d, -RANGE, RANGE) / RANGE * 0.5 + 0.5) * 63), 0, 63).astype(int)
        out.append("".join(B64[v] for v in q))
    # Where the grid sits against the pen: the grid's left edge relative to the
    # pen position, and its top relative to the capital's top (both in units).
    ox = (bb[0] - pad) / SS
    oy = (bb[1] - pad - cap_top) / SS
    adv = f.getlength(ch) / SS
    return gw, gh, ox, oy, adv, "".join(out)


def main():
    lines = ["-- GLYPHS BEGIN (tools/gen_emblem_glyphs.py writes this block; do not edit)",
             "GLYPH_CAP, GLYPH_RANGE = %d, %.1f" % (CAP, RANGE),
             "GLYPH_DATA = {"]
    for name, path in FACES.items():
        f, cap_top = face_at(path)
        space = f.getlength(" ") / SS
        lines.append("  %s = { space = %.2f," % (name, space))
        for ch in CHARS:
            gw, gh, ox, oy, adv, data = bake(f, cap_top, ch)
            k = ch if re.match(r"[A-Z0-9]", ch) and not ch.isdigit() else '["%s"]' % ch
            lines.append('    %s = { %d, %d, %.2f, %.2f, %.2f, "%s" },' % (k, gw, gh, ox, oy, adv, data))
        lines.append("  },")
    lines.append("}")
    lines.append("-- GLYPHS END")
    block = "\n".join(lines)
    src = open(TARGET, encoding="utf-8").read()
    a = src.index("-- GLYPHS BEGIN")
    b = src.index("-- GLYPHS END") + len("-- GLYPHS END")
    open(TARGET, "w", encoding="utf-8").write(src[:a] + block + src[b:])
    print("baked %d glyphs x %d faces into %s (%d bytes)" % (len(CHARS), len(FACES), TARGET, len(block)))


if __name__ == "__main__":
    main()
