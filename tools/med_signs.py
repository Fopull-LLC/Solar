"""The MEDICAL BAY's sign atlas (missions M1): textures/medical/signs.png.

Its own small atlas, so the base's full one (tools/base_tex.py, 1792 px
tall) is left alone. The regions go into base_tex.REGIONS with an "m_"
prefix (base_models.cuboid looks them up there); their pixel sizes into PIX
for the plates' aspect. Used by the shell (tools/base_buildings.py medical(),
material "MedSign") and the interior (tools/gen_medical.py, "MedSign" and the
unlit "MedScreen").

    signs(out_dir=None)   build the atlas (written when out_dir is given)
    aspect(reg)           h / w of a region
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import base_tex

ATLAS_W, ATLAS_H = 1024, 1024
PIX = {}
RED = (168, 30, 24)
WHT = (234, 234, 228)
INK = (24, 22, 20)
GRN = (24, 110, 60)
YEL = (206, 164, 40)
BLU = (34, 60, 110)


def _font(size, kind="label"):
    p = {"label": base_tex.FONT_LABEL, "stencil": base_tex.FONT_STENCIL,
         "mono": os.path.join(base_tex.ROOT, "fonts", "NotoSansMono-Medium.ttf")}[kind]
    return ImageFont.truetype(p, size)


def _cross(n=192, seed=401):
    """A red cross on a white enamel square, a thin red border."""
    img = Image.new("RGB", (n, n), WHT)
    d = ImageDraw.Draw(img)
    d.rectangle([4, 4, n - 5, n - 5], outline=RED, width=5)
    a, b = n * 0.36, n * 0.64
    d.rectangle([a, n * 0.16, b, n * 0.84], fill=RED)
    d.rectangle([n * 0.16, a, n * 0.84, b], fill=RED)
    return base_tex.wear(img, seed, 0.14)


def _ecg(w=320, h=200, seed=411):
    """A bedside monitor: ECG, SpO2 and resp traces with their numbers."""
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (w, h), (6, 10, 12))
    d = ImageDraw.Draw(img)
    f = _font(14, "mono")
    fb = _font(30, "mono")
    rows = ((0.24, (90, 230, 120), "ECG II"), (0.52, (90, 200, 240), "SpO2"), (0.78, (240, 220, 90), "RESP"))
    for yk, col, lab in rows:
        y0 = h * yk
        pts = []
        for x in range(0, int(w * 0.68)):
            t = x / 52.0
            if lab == "ECG II":
                ph = t % 1.0
                v = 0.0
                if 0.10 < ph < 0.16:
                    v = 0.12 * math.sin((ph - 0.10) / 0.06 * math.pi)
                elif 0.22 < ph < 0.25:
                    v = -0.15
                elif 0.25 <= ph < 0.28:
                    v = 1.0
                elif 0.28 <= ph < 0.31:
                    v = -0.3
                elif 0.45 < ph < 0.6:
                    v = 0.22 * math.sin((ph - 0.45) / 0.15 * math.pi)
                v += rng.normal(0, 0.015)
                pts.append((x + 4, y0 - v * h * 0.11))
            elif lab == "SpO2":
                ph = t % 1.0
                v = math.exp(-((ph - 0.3) / 0.12) ** 2) + 0.35 * math.exp(-((ph - 0.62) / 0.08) ** 2)
                pts.append((x + 4, y0 - v * h * 0.08))
            else:
                v = math.sin(t * 1.1)
                pts.append((x + 4, y0 - v * h * 0.05))
        d.line(pts, fill=col, width=2)
        d.text((6, y0 - h * 0.11), lab, font=f, fill=col)
    d.text((w * 0.72, h * 0.10), "72", font=fb, fill=(90, 230, 120))
    d.text((w * 0.72, h * 0.38), "97", font=fb, fill=(90, 200, 240))
    d.text((w * 0.72, h * 0.66), "16", font=fb, fill=(240, 220, 90))
    d.text((w * 0.72, h * 0.92 - 12), "118/76", font=f, fill=(220, 220, 220))
    return img


def _terminal(w=320, h=200, seed=412):
    """The medic's desk terminal: a crew list with their condition."""
    img = Image.new("RGB", (w, h), (10, 16, 24))
    d = ImageDraw.Draw(img)
    f = _font(13, "mono")
    d.rectangle([0, 0, w, 20], fill=(30, 46, 66))
    d.text((6, 3), "MEDICAL  ·  CREW CONDITION", font=f, fill=(200, 216, 232))
    rows = [("OKAFOR, J.", "FIT", (120, 230, 140)), ("VASQUEZ, M.", "FIT", (120, 230, 140)),
            ("LINDQVIST, A.", "OBS  DOSE 0.04", (240, 210, 110)), ("BECK, T.", "FIT", (120, 230, 140)),
            ("—", "", (150, 160, 170)), ("BEDS  2 / 2 FREE", "", (150, 200, 240))]
    for k, (a, b, c) in enumerate(rows):
        y = 30 + k * 26
        d.text((8, y), a, font=f, fill=(170, 186, 200))
        d.text((w * 0.55, y), b, font=f, fill=c)
    return img


def _triage(w=360, h=480, seed=413):
    """A wall chart: the triage tags and the first checks, printed."""
    img = Image.new("RGB", (w, h), (236, 236, 230))
    d = ImageDraw.Draw(img)
    d.text((18, 14), "TRIAGE", font=_font(40), fill=INK)
    for k, (col, t1, t2) in enumerate((((150, 30, 26), "IMMEDIATE", "airway · bleeding · shock"),
                                        ((214, 172, 46), "DELAYED", "fractures · burns < 20 %"),
                                        ((40, 120, 60), "MINOR", "walking wounded"),
                                        ((30, 30, 34), "EXPECTANT", "comfort care"))):
        y = 80 + k * 92
        d.rectangle([18, y, 72, y + 70], fill=col)
        d.text((88, y + 4), t1, font=_font(26), fill=INK)
        d.text((88, y + 40), t2, font=_font(18), fill=(70, 70, 74))
    d.text((18, h - 34), "DOSE > 0.5: DECON BEFORE TREATMENT", font=_font(16), fill=(150, 30, 26))
    return base_tex.wear(img, seed, 0.10)


def signs(out_dir=None):
    P = base_tex.plate
    SL, FG = base_tex.SLATE_BG, base_tex.PLATE_FG
    items = [
        ("name", P("MEDICAL BAY", 400, 64, SL, FG, seed=401)),
        ("cross", _cross()),
        ("bldg", P("10", 112, 136, (226, 226, 220), (38, 42, 48), size=88, border=(38, 42, 48), sub="BLDG · MED", seed=402)),
        ("keep", P("AMBULANCE BAY · KEEP CLEAR", 440, 64, YEL, INK, border=INK, seed=403)),
        ("lab", P("◂  RESEARCH LAB", 300, 60, WHT, BLU, border=BLU, seed=404)),
        ("med", P("MEDICAL BAY  ▸", 300, 60, WHT, BLU, border=BLU, seed=405)),
        ("bed1", P("TREATMENT 1", 240, 56, WHT, INK, border=INK, seed=406)),
        ("bed2", P("TREATMENT 2", 240, 56, WHT, INK, border=INK, seed=407)),
        ("oxy", P("OXYGEN · NO NAKED FLAME", 400, 64, (226, 226, 220), RED, border=RED, seed=408)),
        ("aed", P("AED · DEFIBRILLATOR", 300, 60, GRN, WHT, seed=409)),
        ("wash", P("WASH HANDS", 220, 56, BLU, WHT, seed=410)),
        ("officer", P("MEDICAL OFFICER", 300, 56, SL, FG, seed=414)),
        ("decon", P("DECON · DRIVE IN · STOP AT LINE", 440, 64, YEL, INK, border=INK, seed=415)),
        ("ecg", _ecg()),
        ("term", _terminal()),
        ("triage", _triage()),
        ("hazard", base_tex.hazard(256, 48, 416)),
    ]
    img = Image.new("RGB", (ATLAS_W, ATLAS_H), (128, 128, 128))
    x, y, row = 4, 4, 0
    for name, tile in sorted(items, key=lambda t: -t[1].size[1]):
        w, h = tile.size
        if x + w + 4 > ATLAS_W:
            x, y, row = 4, y + row + 6, 0
        assert y + h <= ATLAS_H, "the medical sign atlas is full: %d" % (y + h)
        img.paste(tile, (x, y))
        base_tex.REGIONS["m_" + name] = ((x + 0.5) / ATLAS_W, (y + 0.5) / ATLAS_H,
                                         (x + w - 0.5) / ATLAS_W, (y + h - 0.5) / ATLAS_H)
        PIX["m_" + name] = (w, h)
        x += w + 6
        row = max(row, h)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        img.save(os.path.join(out_dir, "signs.png"), optimize=True)
        flat = np.zeros((64, 64, 3), np.uint8); flat[..., 0] = 128; flat[..., 1] = 128; flat[..., 2] = 255
        Image.fromarray(flat).save(os.path.join(out_dir, "signs_normal.png"), optimize=True)


def aspect(reg):
    w, h = PIX[reg]
    return h / w


# The material both the shell and the interior wear for these plates.
TEX = "textures/medical/"
MED_SIGN = (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}signs.png"),\n'
            f'                normal_map: Some("{TEX}signs_normal.png"),\n                normal_strength: 1.0,\n'
            '                roughness: 0.55,\n                metallic: 0.0,\n                reflectivity: 0.3,\n'
            '                shading: Physical,\n            )')
MED_SCREEN = (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}signs.png"),\n'
              '                unlit: true,\n            )')


def plate(m, reg, center, right, up, width, depth=0.03, back=(0.17, 0.18, 0.19), mat="Steel"):
    """A plate of this atlas standing `depth` proud of what it hangs on."""
    from base_models import cuboid
    h = width * aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float) + o * depth / 2
    g = m.ground
    m.ground = False
    cuboid(m, c, right, up, width, h, depth, faces={"front": ("MedSign", (1, 1, 1), reg)}, col=back, mat=mat)
    m.ground = g
    return h
