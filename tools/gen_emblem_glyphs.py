#!/usr/bin/env python3
"""Bake the agency emblem's two alphabets into scripts/emblem.lua.

    python3 tools/gen_emblem_glyphs.py

The emblem (scripts/emblem.lua) is drawn at run time from a small spec with
the engine's image.* calls, so a save carries no pixels. Its letters come from
the project's own faces, baked here into OUTLINES (polygons) and written into
the script between the GLYPHS markers:

    stencil   fonts/SolarStencil.ttf (Saira Stencil One): the monogram
    label     fonts/SolarLabel.ttf (Barlow Semi Condensed SemiBold): the name
              round a patch's band, on a shield's chief and under a flag

A glyph is its advance and its contours, flattened to straight edges, in units
where the capital H is CAP (40) tall: x from the pen, y DOWN from the baseline.
A polygon turns and scales freely, so the same letter is drawn upright, round
an arc, thickened for an outline (its edges stroked) or 120 pixels tall. Each
coordinate is two base64 characters, (v + OFFSET) * RES as a 12-bit number.
The contours are filled even-odd (img:polygon); the script checks here that
no face overlaps its own contours, which even-odd would show as holes.

Both faces are SIL OFL 1.1 (fonts/README.md); the baked outlines are a
modified form of them and stay under that licence.
"""
import math
import os
import re

import numpy as np
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "scripts", "emblem.lua")
FACES = {
    "stencil": os.path.join(ROOT, "fonts", "SolarStencil.ttf"),
    "label": os.path.join(ROOT, "fonts", "SolarLabel.ttf"),
}
CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&-.'!?/+"
CAP = 40          # units per capital height
TOL = 0.03        # flattening tolerance, units (a 92-pixel cap: 0.07 px)
RES = 32          # steps per unit in the stored coordinates
OX, OY = 16, 48   # offsets so x in [-16, 112), y in [-48, 80) fit 12 bits
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


class FlatPen(BasePen):
    """Contours as lists of points, curves cut into straight pieces."""

    def __init__(self, glyphset, s):
        super().__init__(glyphset)
        self.s = s
        self.contours = []
        self.cur = None

    def _p(self, p):
        return (p[0] * self.s, -p[1] * self.s)

    def _moveTo(self, p):
        self.cur = [self._p(p)]
        self.contours.append(self.cur)

    def _lineTo(self, p):
        self.cur.append(self._p(p))

    def _qCurveToOne(self, p1, p2):
        a, b, c = self.cur[-1], self._p(p1), self._p(p2)
        d2 = math.hypot(a[0] - 2 * b[0] + c[0], a[1] - 2 * b[1] + c[1])
        n = max(1, math.ceil(math.sqrt(d2 / (8 * TOL))))
        for i in range(1, n + 1):
            t = i / n
            u = 1 - t
            self.cur.append((u * u * a[0] + 2 * u * t * b[0] + t * t * c[0],
                             u * u * a[1] + 2 * u * t * b[1] + t * t * c[1]))

    def _curveToOne(self, p1, p2, p3):
        a, b, c, d = self.cur[-1], self._p(p1), self._p(p2), self._p(p3)
        n = 8
        for i in range(1, n + 1):
            t = i / n
            u = 1 - t
            self.cur.append(tuple(u ** 3 * a[k] + 3 * u * u * t * b[k] + 3 * u * t * t * c[k] + t ** 3 * d[k]
                                  for k in range(2)))

    def _closePath(self):
        if self.cur and len(self.cur) > 1 and self.cur[0] == self.cur[-1]:
            self.cur.pop()
        self.cur = None

    _endPath = _closePath


def enc(v):
    q = int(round(v * RES))
    assert 0 <= q < 4096, v
    return B64[q >> 6] + B64[q & 63]


def overlaps(contours, k=4.0):
    """Pixels (at k px per unit) where the even-odd fill and the non-zero
    fill (the font's own rule) of the contours disagree: overlapping
    contours. 0 for a face img:polygon draws as the font means it."""
    xs = [p[0] for c in contours for p in c]
    ys = [p[1] for c in contours for p in c]
    if not xs:
        return 0
    x0, y0 = min(xs) - 1, min(ys) - 1
    w, h = int((max(xs) - x0 + 1) * k), int((max(ys) - y0 + 1) * k)
    X = (np.arange(w) + 0.5) / k + x0
    bad = 0
    for r in range(h):
        y = (r + 0.5) / k + y0
        wind = np.zeros(w, int)
        for c in contours:
            for i in range(len(c)):
                a, b = c[i], c[(i + 1) % len(c)]
                if (a[1] <= y) != (b[1] <= y):
                    x = a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0])
                    wind += np.where(X < x, 1 if b[1] > a[1] else -1, 0)
        bad += int(((wind != 0) != (wind % 2 != 0)).sum())
    return bad


def bake(path):
    font = TTFont(path)
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    from fontTools.pens.boundsPen import BoundsPen
    bp = BoundsPen(gs)
    gs[cmap[ord("H")]].draw(bp)
    s = CAP / (bp.bounds[3] - bp.bounds[1])
    hmtx = font["hmtx"]
    out = {"space": hmtx[cmap[ord(" ")]][0] * s}
    worst = []
    for ch in CHARS:
        gname = cmap[ord(ch)]
        pen = FlatPen(gs, s)
        gs[gname].draw(pen)
        contours = [c for c in pen.contours if len(c) >= 3]
        if overlaps(contours):
            worst.append(ch)
        out[ch] = (hmtx[gname][0] * s, contours)
    return out, worst


def main():
    lines = ["-- GLYPHS BEGIN (tools/gen_emblem_glyphs.py writes this block; do not edit)",
             "GLYPH_CAP, GLYPH_RES, GLYPH_OX, GLYPH_OY = %d, %d, %d, %d" % (CAP, RES, OX, OY),
             "GLYPH_DATA = {"]
    npts = 0
    for name, path in FACES.items():
        g, worst = bake(path)
        if worst:
            raise SystemExit("%s: overlapping contours in %s; even-odd would draw holes" % (name, " ".join(worst)))
        lines.append("  %s = { space = %.2f," % (name, g["space"]))
        for ch in CHARS:
            adv, contours = g[ch]
            parts = []
            for c in contours:
                parts.append('"%s"' % "".join(enc(x + OX) + enc(y + OY) for x, y in c))
                npts += len(c)
            k = ch if re.match(r"[A-Z]", ch) else '["%s"]' % ch
            lines.append("    %s = { %.2f, %s }," % (k, adv, ", ".join(parts)))
        lines.append("  },")
    lines.append("}")
    lines.append("-- GLYPHS END")
    block = "\n".join(lines)
    src = open(TARGET, encoding="utf-8").read()
    a = src.index("-- GLYPHS BEGIN")
    b = src.index("-- GLYPHS END") + len("-- GLYPHS END")
    open(TARGET, "w", encoding="utf-8").write(src[:a] + block + src[b:])
    print("baked %d glyphs x %d faces (%d points) into %s (%d bytes)" % (len(CHARS), len(FACES), npts, TARGET,
                                                                     len(block)))


if __name__ == "__main__":
    main()
