#!/usr/bin/env python3
"""The SPACEPORT's surfaces: textures/base/*.png, and the sign atlas.

    python3 tools/base_tex.py          (tools/gen_base.py runs it too)

Everything is procedural — numpy fields and PIL drawing from fixed seeds — so
the set is reproducible byte for byte and carries no image licence. The signs
are set in the project's own label faces (fonts/SolarLabel.ttf = Barlow Semi
Condensed SemiBold, fonts/SolarStencil.ttf = Saira Stencil One, both SIL OFL;
see tools/build_ui_font.py), rendered at a resolution that reads cleanly at
the size the plates are hung.

Per surface: `<name>_albedo.png`, `<name>_normal.png` (tangent space, OpenGL
+Y) and `<name>_orm.png` (R = ambient occlusion, G = roughness, B = metallic),
the layout the engine's ao_map / roughness_map / metallic_map read — the same
convention as textures/parts. Colour is kept near neutral and LIGHT: the
models multiply their paint colour in as a vertex colour, so one cladding map
serves a white VAB, a warm-grey depot and a blue-grey switch house.

  concrete   4 m tile: cast slab, broom finish, aggregate, saw-cut expansion
             joints on the tile edge, rust and water staining, grime
  cladding   2 m tile: trapezoidal ribbed steel sheet (ribs 0.25 m apart,
             carried in the normal map, not painted on), rain streaks down
             the ribs, chalky weathering, no horizontal seams (no grid)
  steel      1 m tile: painted plate, orange-peel, scratches to bare metal,
             rust specks and runs, grime
  asphalt    8 m tile: dark binder, stone chips, crack sealant, wear
  signs      the atlas: building plates, warning plates, the agency emblem,
             hazard striping, the pad's deck marking, taxiway glyphs
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_textures import normal_from_height, smoothstep, spectral  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "base")
FONT_LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")
FONT_STENCIL = os.path.join(ROOT, "fonts", "SolarStencil.ttf")
N = 512


def save_rgb(arr, name):
    a = np.clip(arr, 0, 1)
    Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(OUT, name), optimize=True)


def save_set(name, albedo, height, strength, ao, rough, metal):
    save_rgb(albedo, f"{name}_albedo.png")
    save_rgb(normal_from_height(height, strength), f"{name}_normal.png")
    save_rgb(np.stack([ao, rough, metal], -1), f"{name}_orm.png")


def specks(rng, shape, density, radius):
    """A field of soft round specks (0..1), wrapping."""
    H, W = shape
    out = np.zeros(shape, np.float32)
    n = int(H * W * density)
    ys, xs = rng.integers(0, H, n), rng.integers(0, W, n)
    rs = rng.uniform(0.4, 1.0, n) * radius
    yy, xx = np.mgrid[-4:5, -4:5]
    for y, x, r in zip(ys, xs, rs):
        k = np.clip(1 - (xx * xx + yy * yy) / (r * r + 1e-6), 0, 1)
        out[(yy + y) % H, (xx + x) % W] = np.maximum(out[(yy + y) % H, (xx + x) % W], k)
    return out


def concrete():
    rng = np.random.default_rng(101)
    low = spectral(N, N, rng, beta=2.2, lo=1.5)
    mid = spectral(N, N, rng, beta=1.6, lo=6)
    fine = spectral(N, N, rng, beta=0.9, lo=40)
    v = 0.60 + (low - 0.5) * 0.10 + (mid - 0.5) * 0.06 + (fine - 0.5) * 0.05
    agg = specks(rng, (N, N), 0.004, 2.2)
    v += agg * rng.choice([-0.10, 0.08], size=1)[0] * 0.6
    pits = specks(rng, (N, N), 0.002, 1.3)
    v -= pits * 0.12
    # saw-cut expansion joints on the tile edge (every 4 m), a little spalled
    yy, xx = np.mgrid[0:N, 0:N]
    dj = np.minimum(np.minimum(xx, N - 1 - xx), np.minimum(yy, N - 1 - yy)).astype(np.float32)
    joint = 1 - smoothstep(0.5, 2.2, dj)
    spall = (spectral(N, N, rng, beta=1.0, lo=30) > 0.72) * (1 - smoothstep(1, 5, dj))
    v -= joint * 0.30 + spall * 0.06
    # water staining and rust blooms, and a darker damp patch
    stain = smoothstep(0.62, 0.85, spectral(N, N, rng, beta=2.0, lo=2))
    rust = smoothstep(0.80, 0.92, spectral(N, N, rng, beta=1.8, lo=4))
    v -= stain * 0.06
    alb = np.stack([v, v * 0.985, v * 0.955], -1)
    alb[..., 0] += rust * 0.06
    alb[..., 2] -= rust * 0.06
    hgt = fine * 0.5 + agg * 0.6 - pits * 0.8 - joint * 2.5 - spall * 0.6
    ao = 1 - joint * 0.5 - pits * 0.2
    rough = 0.86 + (fine - 0.5) * 0.08 - stain * 0.08
    save_set("concrete", alb, hgt, 2.2, ao, rough, np.zeros_like(v))


def cladding():
    rng = np.random.default_rng(202)
    x = (np.arange(N) / N) * 8.0           # 8 ribs across the 2 m tile
    ph = x % 1.0
    # trapezoid profile: crest 0.10, slopes 0.12, pan 0.66 (fractions of a rib)
    prof = np.interp(ph, [0.0, 0.10, 0.22, 0.88, 1.0], [1.0, 1.0, 0.0, 0.0, 1.0])
    prof += np.interp(ph, [0.45, 0.50, 0.55], [0.0, 0.10, 0.0])   # a stiffening minor rib
    hgt = np.tile(prof[None, :], (N, 1)).astype(np.float32)
    dents = spectral(N, N, rng, beta=2.4, lo=3) - 0.5
    hgt += dents * 0.25
    # weathering: rain streaks running down from crests, chalky fade, grime
    streak = spectral(N, N, rng, beta=1.4, sx=1.0, sy=0.04, lo=4)
    streak = smoothstep(0.45, 0.85, streak)
    mott = spectral(N, N, rng, beta=2.2, lo=1.5)
    chalk = smoothstep(0.55, 0.9, spectral(N, N, rng, beta=1.8, lo=3))
    v = 0.84 + (mott - 0.5) * 0.07 - streak * 0.10 + chalk * 0.04
    # the slopes catch less light in the albedo's own AO, not as painted bands
    slope = np.abs(np.gradient(np.tile(prof[None, :], (N, 1)), axis=1)) * N / 8
    v -= np.clip(slope, 0, 1) * 0.015
    alb = np.stack([v, v * 0.995, v * 0.985], -1)
    alb[..., 0] += streak * 0.012
    ao = 0.82 + 0.18 * hgt.clip(0, 1)
    rough = 0.50 + streak * 0.18 + chalk * 0.12 + (mott - 0.5) * 0.08
    metal = 0.25 - chalk * 0.12
    save_set("cladding", alb, hgt, 9.0, ao, rough, metal)


def steel():
    rng = np.random.default_rng(303)
    peel = spectral(N, N, rng, beta=1.0, lo=60)
    mott = spectral(N, N, rng, beta=2.0, lo=2)
    v = 0.80 + (mott - 0.5) * 0.08 + (peel - 0.5) * 0.02
    img = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(img)
    for _ in range(70):
        x, y = rng.uniform(0, N, 2)
        a = rng.uniform(0, math.pi)
        L = rng.uniform(6, 40)
        d.line([(x, y), (x + math.cos(a) * L, y + math.sin(a) * L)], fill=int(rng.uniform(120, 255)), width=1)
    scratch = np.asarray(img, np.float32) / 255
    rust = specks(rng, (N, N), 0.0012, 2.6) * smoothstep(0.5, 0.8, spectral(N, N, rng, beta=1.6, lo=3))
    runs = spectral(N, N, rng, beta=1.3, sx=1.0, sy=0.05, lo=5)
    runs = smoothstep(0.7, 0.92, runs) * 0.6
    alb = np.stack([v, v, v * 0.99], -1)
    for c, k in zip(range(3), (0.30, 0.16, 0.06)):
        alb[..., c] = alb[..., c] * (1 - rust - runs * 0.35) + (rust + runs * 0.35) * k * 1.6
    alb += scratch[..., None] * 0.08
    hgt = peel * 0.3 - scratch * 0.6 + rust * 0.5
    ao = np.ones_like(v) - rust * 0.2
    rough = 0.48 + (mott - 0.5) * 0.1 + rust * 0.35 + runs * 0.15 - scratch * 0.15
    metal = 0.12 + scratch * 0.6
    save_set("steel", alb, hgt, 1.6, ao, rough, metal)


def asphalt():
    rng = np.random.default_rng(404)
    low = spectral(N, N, rng, beta=2.0, lo=1.5)
    fine = spectral(N, N, rng, beta=0.8, lo=60)
    chips = specks(rng, (N, N), 0.010, 1.6)
    v = 0.55 + (low - 0.5) * 0.10 + (fine - 0.5) * 0.06 + chips * 0.22
    # crack sealant: a few meandering dark bands
    img = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(img)
    for _ in range(3):
        x, y = rng.uniform(0, N, 2)
        pts = [(x, y)]
        a = rng.uniform(0, math.tau)
        for _ in range(30):
            a += rng.normal(0, 0.35)
            x, y = x + math.cos(a) * 9, y + math.sin(a) * 9
            pts.append((x % N, y % N))
        for p, q in zip(pts, pts[1:]):
            if abs(p[0] - q[0]) < 20 and abs(p[1] - q[1]) < 20:
                d.line([p, q], fill=255, width=4)
    seal = np.asarray(img.filter(ImageFilter.GaussianBlur(1.0)), np.float32) / 255
    v = v * (1 - seal * 0.3)
    alb = np.stack([v, v, v * 1.01], -1)
    hgt = chips * 0.8 + fine * 0.3 - seal * 0.3
    rough = 0.90 - seal * 0.25 + (fine - 0.5) * 0.06
    save_set("asphalt", alb, hgt, 2.5, 1 - chips * 0.1, rough, np.zeros_like(v))


# ── the sign atlas ──────────────────────────────────────────────────────────

ATLAS = 1024
ATLAS_H = 1536
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
    for k, (code, sub) in enumerate((("1", "VAB"), ("2", "OPS"), ("3", "LOG"), ("4", "TRK"), ("5", "PWR"), ("6", "PROP"))):
        P.put(f"bldg{code}", plate(code, 112, 136, (226, 226, 220), (38, 42, 48), size=88, border=(38, 42, 48), sub=f"BLDG · {sub}", seed=20 + k))
    P.put("hv", plate("DANGER — HIGH VOLTAGE", 400, 90, (204, 160, 40), (24, 22, 20), border=(24, 22, 20), seed=31))
    P.put("cryo", plate("CRYOGENIC — NO OPEN FLAME", 440, 90, (226, 226, 220), (150, 34, 26), border=(150, 34, 26), seed=32))
    P.put("blast", plate("DANGER — LAUNCH HAZARD AREA", 460, 90, (226, 226, 220), (150, 34, 26), border=(150, 34, 26), seed=33))
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
    concrete()
    cladding()
    steel()
    asphalt()
    signs()
    return REGIONS


if __name__ == "__main__":
    main()
    for k, v in REGIONS.items():
        print(k, [round(x, 4) for x in v])
