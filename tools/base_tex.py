#!/usr/bin/env python3
"""The SPACEPORT's surfaces: textures/base/*.png, and the sign atlas.

    python3 tools/base_tex.py          (tools/gen_base.py runs it too)

The four SURFACES (concrete, cladding, steel, asphalt) are baked from the
realistic PBR texture library by tools/base_pbr.py, which main() runs: see its
docstring for the sets, the tiles and the licensing (a CC0 fallback committed,
a commercial version for local builds only). They were procedural until wave 2
of the texture upgrade (2026-11-04).

The rest here is procedural (numpy fields and PIL drawing from fixed seeds), so
it is reproducible byte for byte and carries no image licence. The signs
are set in the project's own label faces (fonts/SolarLabel.ttf = Barlow Semi
Condensed SemiBold, fonts/SolarStencil.ttf = Saira Stencil One, both SIL OFL;
see tools/build_ui_font.py), rendered at a resolution that reads cleanly at
the size the plates are hung.

Surface maps: `<name>_albedo.png`, `<name>_normal.png` (tangent space, OpenGL
+Y) and `<name>_orm.png` (R = ambient occlusion, G = roughness, B = metallic),
the layout the engine's ao_map / roughness_map / metallic_map read. Colour is
kept near neutral and LIGHT: the models multiply their paint colour in as a
vertex colour, so one cladding map serves a white VAB, a warm-grey depot and a
blue-grey switch house.

  signs      the atlas: building plates, warning plates, the agency emblem,
             hazard striping, the pad's deck marking, taxiway glyphs
  lens       the lamp lens
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_textures import smoothstep, spectral  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "base")
FONT_LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")
FONT_STENCIL = os.path.join(ROOT, "fonts", "SolarStencil.ttf")
N = 512


def save_rgb(arr, name):
    a = np.clip(arr, 0, 1)
    Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(OUT, name), optimize=True)


# ── the sign atlas ──────────────────────────────────────────────────────────

ATLAS = 1024
ATLAS_H = 1792   # 1536 until the base works (2026-11-02) added their plates
REGIONS = {}   # name -> (u0, v0, u1, v1) in 0..1, v down from the top


class Packer:
    """Shelf packing, tallest first, once everything is in."""

    def __init__(self, img):
        self.img, self.items = img, []

    def put(self, name, tile):
        self.items.append((name, tile))

    def pack(self):
        x, y, row = 4, 4, 0
        for name, tile in sorted(self.items, key=lambda t: -t[1].size[1]):
            w, h = tile.size
            if x + w + 4 > ATLAS:
                x, y, row = 4, y + row + 6, 0
            assert y + h <= ATLAS_H, "the sign atlas is full: %d" % (y + h)
            self.img.paste(tile, (x, y))
            # half a texel in, so filtering never reaches the neighbour
            REGIONS[name] = ((x + 0.5) / ATLAS, (y + 0.5) / ATLAS_H, (x + w - 0.5) / ATLAS, (y + h - 0.5) / ATLAS_H)
            x += w + 6
            row = max(row, h)


def wear(tile, seed, amount=0.10):
    """Fade, grime and chip a painted plate a little."""
    rng = np.random.default_rng(seed)
    a = np.asarray(tile, np.float32) / 255
    h, w = a.shape[:2]
    g = spectral(h, w, rng, beta=1.8, lo=2)[..., None] if h == w else \
        np.asarray(Image.fromarray((spectral(256, 256, rng, beta=1.8, lo=2) * 255).astype(np.uint8)).resize((w, h)), np.float32)[..., None] / 255
    a = a * (1 - amount * g) + amount * 0.5 * g * np.array([0.42, 0.40, 0.36])
    a = a * (1 - 0.04 * (1 - g))
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))


def plate(text, w, h, bg, fg, font=FONT_LABEL, size=None, border=None, sub=None, seed=1, align="center"):
    img = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(img)
    if border:
        d.rectangle([3, 3, w - 4, h - 4], outline=border, width=4)
    size = size or int(h * 0.62)
    while True:
        f = ImageFont.truetype(font, size)
        tb = d.textbbox((0, 0), text, font=f)
        if tb[2] - tb[0] <= w * 0.88 or size < 8:
            break
        size -= 2
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    ty = (h - th) / 2 - tb[1] - (h * 0.12 if sub else 0)
    tx = (w - tw) / 2 - tb[0] if align == "center" else h * 0.3 - tb[0]
    d.text((tx, ty), text, font=f, fill=fg)
    if sub:
        ss = int(h * 0.20)
        while True:
            fs = ImageFont.truetype(FONT_LABEL, ss)
            sb = d.textbbox((0, 0), sub, font=fs)
            if sb[2] - sb[0] <= w * 0.84 or ss < 8:
                break
            ss -= 1
        d.text(((w - (sb[2] - sb[0])) / 2 - sb[0], h * 0.70), sub, font=fs, fill=fg)
    return wear(img, seed)


def emblem(size=360, seed=7):
    """The agency roundel: a weathered painted disc — navy field, a pale world
    and its orbit, a small star, the agency's name round the rim."""
    S = size * 2
    img = Image.new("RGB", (S, S), (176, 178, 176))
    d = ImageDraw.Draw(img)
    c = S / 2
    d.ellipse([4, 4, S - 4, S - 4], fill=(150, 152, 150))
    d.ellipse([22, 22, S - 22, S - 22], fill=(34, 46, 70))
    d.ellipse([c - S * 0.20, c - S * 0.20, c + S * 0.20, c + S * 0.20], fill=(196, 198, 192))
    d.ellipse([c - S * 0.20, c - S * 0.20 + S * 0.05, c + S * 0.12, c + S * 0.20], fill=(170, 174, 170))
    ring = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(ring)
    rd.ellipse([c - S * 0.38, c - S * 0.13, c + S * 0.38, c + S * 0.13], outline=255, width=int(S * 0.018))
    ring = ring.rotate(-24, resample=Image.BICUBIC, center=(c, c))
    img.paste((214, 214, 208), mask=ring)
    sx, sy, r = c + S * 0.24, c - S * 0.25, S * 0.035
    star = [(sx + math.cos(a) * (r if k % 2 == 0 else r * 0.4), sy + math.sin(a) * (r if k % 2 == 0 else r * 0.4))
            for k, a in enumerate(np.linspace(-math.pi / 2, 1.5 * math.pi, 11)[:-1])]
    d.polygon(star, fill=(214, 214, 208))
    f = ImageFont.truetype(FONT_LABEL, int(S * 0.085))
    name = "SOLAR SPACEFLIGHT"
    span = math.radians(150)
    for k, ch in enumerate(name):
        a = math.pi + (k / (len(name) - 1) - 0.5) * span + math.pi / 2 - math.pi / 2
        a = math.radians(-90) + (k / (len(name) - 1) - 0.5) * span
        ch_img = Image.new("L", (int(S * 0.12), int(S * 0.12)), 0)
        ImageDraw.Draw(ch_img).text((S * 0.02, 0), ch, font=f, fill=255)
        ch_img = ch_img.rotate(-math.degrees(a) - 90, resample=Image.BICUBIC, expand=False)
        px, py = c + math.cos(a) * S * 0.405, c + math.sin(a) * S * 0.405
        img.paste((206, 206, 200), (int(px - S * 0.06), int(py - S * 0.06)), mask=ch_img)
    img = img.resize((size, size), Image.LANCZOS)
    return wear(img, seed, amount=0.22)


def hazard(w, h, seed, period=48):
    img = Image.new("RGB", (w, h), (196, 150, 34))
    d = ImageDraw.Draw(img)
    for x in range(-h, w + h, period):
        d.polygon([(x, h), (x + period / 2, h), (x + period / 2 + h, 0), (x + h, 0)], fill=(28, 27, 26))
    return wear(img, seed, amount=0.25)


def deck_marking(seed=9):
    """'LC-1' stencilled in worn white on the hardstand's concrete."""
    con = np.asarray(Image.open(os.path.join(OUT, "concrete_albedo.png")), np.float32) / 255
    w, h = 512, 192
    tile = np.tile(con, (1, 2, 1))[:h, :w]
    img = Image.fromarray((tile * 255).astype(np.uint8))
    mask = Image.new("L", (w, h), 0)
    f = ImageFont.truetype(FONT_STENCIL, 150)
    d = ImageDraw.Draw(mask)
    tb = d.textbbox((0, 0), "LC-1", font=f)
    d.text(((w - (tb[2] - tb[0])) / 2 - tb[0], (h - (tb[3] - tb[1])) / 2 - tb[1]), "LC-1", font=f, fill=255)
    rng = np.random.default_rng(seed)
    m = np.asarray(mask, np.float32) / 255
    m *= 0.55 + 0.45 * smoothstep(0.25, 0.6, np.asarray(Image.fromarray((spectral(256, 256, rng, beta=1.2, lo=8) * 255).astype(np.uint8)).resize((w, h)), np.float32) / 255)
    out = tile * (1 - m[..., None]) + m[..., None] * np.array([0.86, 0.86, 0.83])
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def glyph(ch, bg, fg, size=64):
    img = Image.new("RGB", (size, size), bg)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT_LABEL, int(size * 0.78))
    tb = d.textbbox((0, 0), ch, font=f)
    d.text(((size - (tb[2] - tb[0])) / 2 - tb[0], (size - (tb[3] - tb[1])) / 2 - tb[1]), ch, font=f, fill=fg)
    return img


SLATE_BG = (52, 60, 72)
PLATE_FG = (232, 232, 226)


def signs():
    img = Image.new("RGB", (ATLAS, ATLAS_H), (128, 128, 128))
    P = Packer(img)
    P.put("vab_name", plate("VEHICLE ASSEMBLY BUILDING", 1000, 96, SLATE_BG, PLATE_FG, seed=11))
    P.put("cmd_name", plate("COMMAND CENTRE", 560, 96, SLATE_BG, PLATE_FG, seed=12))
    P.put("depot_name", plate("COMMERCE DEPOT", 440, 76, SLATE_BG, PLATE_FG, seed=13))
    P.put("track_name", plate("TRACKING STATION", 400, 64, SLATE_BG, PLATE_FG, seed=14))
    P.put("power_name", plate("POWER STATION", 340, 64, SLATE_BG, PLATE_FG, seed=15))
    P.put("intake_name", plate("MATERIALS INTAKE", 400, 64, SLATE_BG, PLATE_FG, seed=16))
    P.put("repair_name", plate("REPAIR BAY", 300, 64, SLATE_BG, PLATE_FG, seed=17))
    P.put("lab_name", plate("RESEARCH LAB", 380, 64, SLATE_BG, PLATE_FG, seed=18))
    P.put("lab_entry", plate("RESEARCH LAB · CLEAN AREA", 360, 64, (226, 226, 220), (34, 46, 70),
                             border=(34, 46, 70), seed=42))
    P.put("lab_way", plate("RESEARCH LAB  ▸", 300, 64, (226, 226, 220), (34, 46, 70), border=(34, 46, 70), seed=43))
    P.put("tube_sign", plate("SAMPLE TRANSFER · PNEUMATIC", 360, 56, (204, 160, 40), (24, 22, 20),
                             border=(24, 22, 20), seed=44))
    for k, (code, sub) in enumerate((("1", "VAB"), ("2", "OPS"), ("3", "LOG"), ("4", "TRK"), ("5", "PWR"), ("6", "PROP"),
                                     ("7", "BULK"), ("8", "SVC"), ("9", "R&D"))):
        P.put(f"bldg{code}", plate(code, 112, 136, (226, 226, 220), (38, 42, 48), size=88, border=(38, 42, 48), sub=f"BLDG · {sub}", seed=20 + k))
    P.put("hv", plate("DANGER — HIGH VOLTAGE", 400, 90, (204, 160, 40), (24, 22, 20), border=(24, 22, 20), seed=31))
    P.put("cryo", plate("CRYOGENIC — NO OPEN FLAME", 440, 90, (226, 226, 220), (150, 34, 26), border=(150, 34, 26), seed=32))
    P.put("blast", plate("DANGER — LAUNCH HAZARD AREA", 460, 90, (226, 226, 220), (150, 34, 26), border=(150, 34, 26), seed=33))
    P.put("conveyor", plate("DANGER — MOVING CONVEYOR · KEEP CLEAR", 420, 64, (204, 160, 40), (24, 22, 20),
                            border=(24, 22, 20), seed=39))
    P.put("bay_rules", plate("PARK INSIDE · STOP · SERVICE AT CONSOLE", 420, 64, (226, 226, 220), (34, 46, 70),
                             border=(34, 46, 70), seed=40))
    P.put("lh2", plate("LH2", 200, 100, (226, 226, 220), (34, 46, 70), font=FONT_STENCIL, border=(34, 46, 70), seed=34))
    P.put("lox", plate("LOX", 200, 100, (226, 226, 220), (34, 46, 70), font=FONT_STENCIL, border=(34, 46, 70), seed=35))
    P.put("wall_l", screen("map", 320, 218, 51))
    P.put("wall_c", screen("map", 320, 218, 52))
    P.put("wall_r", screen("plot", 320, 218, 53))
    for k, kind in enumerate(("plot", "list", "map")):
        P.put("con_%d" % k, screen(kind, 216, 120, 60 + k))
    P.put("trade_buy", trade("BUY", 71))
    P.put("trade_sell", trade("SELL", 72))
    P.put("buy", plate("BUY", 240, 72, (38, 70, 52), PLATE_FG, seed=37))
    P.put("sell", plate("SELL", 240, 72, (96, 52, 30), PLATE_FG, seed=38))
    P.put("pad_tower", plate("LC-1", 200, 90, SLATE_BG, PLATE_FG, font=FONT_STENCIL, seed=36))
    P.put("hazard", hazard(256, 48, 41))
    P.put("emblem", emblem(300))
    P.put("deck_lc1", deck_marking())
    for ch in "0123456789-":
        P.put("g_" + ch, glyph(ch, (150, 30, 24), (236, 236, 230)))
    P.put("g_A_loc", glyph("A", (24, 22, 20), (214, 172, 46)))
    P.put("g_A_dir", glyph("A", (214, 172, 46), (24, 22, 20)))
    P.pack()
    img.save(os.path.join(OUT, "signs.png"), optimize=True)
    # the plates are a printed surface: a flat normal, satin roughness
    flat = np.zeros((64, 64, 3)); flat[..., 2] = 1.0
    save_rgb(flat * 0.5 + 0.5, "signs_normal.png")


def screen(kind, w, h, seed):
    """An operations display: dark field, a grid, traces, a ground track,
    rows of readouts. Shown unlit (the Screen material)."""
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (w, h), (10, 18, 30))
    d = ImageDraw.Draw(img)
    for x in range(0, w, w // 12):
        d.line([(x, 0), (x, h)], fill=(20, 36, 54))
    for y in range(0, h, h // 8):
        d.line([(0, y), (w, y)], fill=(20, 36, 54))
    f = ImageFont.truetype(os.path.join(ROOT, "fonts", "NotoSansMono-Medium.ttf"), max(9, h // 14))
    if kind == "map":
        pts = [(x, h * 0.5 - math.sin(x / w * math.tau * 1.5 + seed) * h * 0.3) for x in range(0, w, 3)]
        d.line(pts, fill=(90, 220, 160), width=2)
        for _ in range(4):
            x, y = rng.uniform(0.1, 0.9) * w, rng.uniform(0.2, 0.8) * h
            d.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(240, 200, 90), width=2)
        d.text((6, 4), "GROUND TRACK  REV %03d" % (seed * 7 % 999), font=f, fill=(140, 200, 240))
    elif kind == "plot":
        for c, col in enumerate(((90, 200, 255), (255, 170, 80), (120, 230, 140))):
            ys = np.cumsum(rng.normal(0, 1, w // 4)); ys = (ys - ys.min()) / (np.ptp(ys) + 1e-6)
            d.line([(x * 4, h * 0.85 - y * h * 0.6) for x, y in enumerate(ys)], fill=col, width=2)
        d.text((6, 4), "TELEMETRY  CH %d" % (seed % 9 + 1), font=f, fill=(140, 200, 240))
    else:
        for k in range(7):
            y = 6 + k * (h - 10) / 7
            d.text((6, y), "%-6s %8.2f" % (("LOX", "LH2", "PWR", "COMM", "TEMP", "WIND", "PRES")[k], rng.uniform(0, 999)),
                   font=f, fill=(150, 210, 240) if k % 3 else (120, 230, 140))
            d.rectangle([w * 0.62, y + 3, w * 0.62 + rng.uniform(0.05, 0.33) * w, y + h / 10], fill=(40, 120, 170))
    return img


def trade(label, seed):
    img = screen("list", 240, 144, seed)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT_LABEL, 26)
    d.rectangle([0, 0, 240, 30], fill=(30, 70, 50) if label == "BUY" else (90, 50, 28))
    d.text((8, 0), label + " — DEPOT", font=f, fill=(230, 230, 220))
    return img


def lens():
    """A pressed-glass lamp lens: concentric prism rings and a faint grid,
    brightest at the centre. The Lamp material is unlit: this, times the
    lamp's colour, is what a lit fixture's face shows."""
    n = 128
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n * 2 - 1
    r = np.sqrt(xx * xx + yy * yy)
    rings = 0.82 + 0.18 * np.cos(r * 34.0) ** 2
    grid = 1 - 0.10 * ((np.abs(np.sin(xx * 9 * math.pi)) < 0.12) | (np.abs(np.sin(yy * 9 * math.pi)) < 0.12))
    hot = 0.72 + 0.28 * np.clip(1 - r, 0, 1)
    v = np.clip(rings * grid * hot, 0, 1)
    save_rgb(np.stack([v, v, v], -1), "lens.png")


def main():
    os.makedirs(OUT, exist_ok=True)
    lens()
    import base_pbr
    base_pbr.bake()
    signs()
    return REGIONS


if __name__ == "__main__":
    main()
    for k, v in REGIONS.items():
        print(k, [round(x, 4) for x in v])
