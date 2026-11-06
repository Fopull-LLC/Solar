#!/usr/bin/env python3
"""The kit's CHARACTER pieces (sandbox plan S4; scripts/parts_kit.lua PROPS, DECALS, SIGNS):
props for clutter and lived-in rooms, decals (hazard stripes, numbers, arrows, placards, supplier
marks, grime), text signs and the agency emblem.

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for its
PIECES table, built with its own primitives) and runs `textures()` first, so

    python3 tools/gen_kit_parts.py                    # everything, the character pieces included
    python3 tools/gen_kit_parts.py crate decalHaz     # just these

THE DECALS are thin quads on a face (the kit's `mount` class, `film` = no overlap, no collider),
not engine decals: decals.add lays a mark only on the collider of a node that DRAWS, and a kit
piece's colliders are Empties beside its Mesh. A quad is a piece like any other, so it saves,
copies, mirrors and travels in a blueprint, and every quad of one kind batches. All the stock
decals share ONE atlas (textures/kit/decals.png, 512 px a metre) and the grime its own
(textures/kit/grime.png, 256 px a metre, blended); both get a paint-film normal, ORM and height
from tools/detail_maps.decals, as the hull and tool decals do.

THE ART is drawn here with Pillow from the project's own fonts (fonts/SolarStencil.ttf: Saira
Stencil One; fonts/SolarLabel.ttf: Barlow Semi Condensed SemiBold, both OFL) to docs/ui-style.md's
signage rules: stencils in ink on enamel or black on safety yellow, placards in a ruled box,
hazard stripes black and `warn` at 45°, paint worn soft and low contrast. The supplier marks are
the game's own fictional firms (base_economy.lua SUPPLIERS). Nothing is downloaded.

THE PROPS are built from the kit's primitives and its CC0/procedural PBR sets (textures/base
steel, cladding, concrete; textures/parts rubber; textures/lab cloth; the flora atlas for a plant),
light enough to place by the hundred: one model each, a collider box where the crew would bump
into it, none for small clutter (`clutter`).
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KTEX = os.path.join(ROOT, "textures", "kit")
FONT_STENCIL = os.path.join(ROOT, "fonts", "SolarStencil.ttf")
FONT_LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")

PXM = 512                 # decal atlas pixels a metre
GPXM = 256                # grime atlas pixels a metre
INK = (235, 227, 207)     # ui tokens: ink 0.92 0.89 0.81
WARN = (255, 204, 71)     # warn 1.00 0.80 0.28
ACCENT = (247, 140, 56)   # accent
DANGER = (200, 62, 46)    # a worn danger red
ENAMEL = (40, 42, 38)     # plate enamel (panel token, a little lifted)
BLACK = (22, 22, 20)
GREEN = (72, 132, 78)

# id → (label, atlas rect x, y, w, h px, desc). Size in metres = rect / PXM.
DECALS = {
    "decalHaz":    ("Hazard Stripe 2 m", (0, 0, 1024, 104), "black and safety yellow at 45° · edges, steps, anything that bites"),
    "decalHazS":   ("Hazard Stripe 1 m", (1024, 0, 512, 52), "a narrow band · door edges, kerbs"),
    "decalHazSq":  ("Hazard Panel", (1536, 0, 256, 256), "a 0.5 m chevron square · pillars, machinery"),
    "decalArrow":  ("Arrow", (1792, 0, 256, 154), "a stencilled arrow · T turns it on the face"),
    "decalChev":   ("Chevrons", (1620, 512, 410, 128), "three chevrons · this way"),
    "decalNoEntry": ("NO ENTRY", (0, 512, 410, 154), "a placard in danger red"),
    "decalAirlock": ("AIRLOCK", (420, 512, 512, 128), "stencilled black on safety yellow"),
    "decalPress":  ("PRESSURE DOOR", (940, 512, 410, 128), "PRESSURE DOOR · KEEP CLEAR"),
    "decalLoad":   ("Load Rating", (1360, 512, 256, 128), "MAX LOAD 500 kg plate"),
    "decalO2":     ("O2 Line Marker", (0, 680, 307, 77), "a pipe band: O2 and its flow"),
    "decalVolt":   ("DANGER 400 V", (320, 680, 307, 77), "a voltage warning band"),
    "decalExit":   ("EXIT", (640, 680, 307, 102), "an exit placard with its arrow"),
    "decalHalden": ("Halden Structural", (0, 790, 512, 205), "the supplier's mark · structure"),
    "decalPell":   ("Pell Groundworks", (520, 790, 512, 205), "the supplier's mark · groundworks"),
}
for _d in range(10):
    DECALS["decalNum%d" % _d] = ("Number %d" % _d, (_d * 160 + 3, 260, 154, 205), "a 0.4 m stencilled numeral · door and bay numbers")
GRIME = {
    "grimeStreaks": ("Grime: Streaks", (0, 0, 512, 563), "run-off down a wall, splash at its foot"),
    "grimeScuff":   ("Grime: Floor Scuffs", (512, 0, 512, 512), "boot traffic worn into a deck"),
    "grimeLeak":    ("Grime: Rust Run", (0, 576, 154, 307), "a weep of rust under a bolt or a seam"),
    "grimeSoot":    ("Grime: Scorch", (160, 576, 256, 256), "soot from a vent, a welder, a fire"),
    "grimeOil":     ("Grime: Oil Stain", (420, 576, 256, 256), "an oil patch on a floor"),
}
DW, DH = 2048, 1024
GW, GH = 1024, 1024


# ── the atlases ──────────────────────────────────────────────────────────────

def _font(path, px):
    return ImageFont.truetype(path, int(px))


def _wear(rng, w, h, amount=0.18, scale=6.0):
    """A soft wear mask (1 = paint kept): low-contrast blotches and a few rubbed scuffs."""
    n = rng.standard_normal((max(2, int(h / scale)), max(2, int(w / scale)))).astype(np.float32)
    img = Image.fromarray(((n - n.min()) / (np.ptp(n) + 1e-6) * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    img = img.filter(ImageFilter.GaussianBlur(2.0))
    a = np.asarray(img, np.float32) / 255
    keep = np.clip(1.0 - amount * np.clip((a - 0.55) * 4, 0, 1), 0, 1)
    fine = rng.random((h, w)).astype(np.float32)
    keep = keep * np.where(fine < 0.012 * (amount / 0.18), 0.35, 1.0)
    return keep


def _cell(w, h, ss=2):
    return Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))


def _down(im, w, h):
    return im.resize((w, h), Image.LANCZOS)


def _paste_worn(atlas, im, x, y, rng, amount=0.18):
    a = np.asarray(im, np.float32).copy()
    keep = _wear(rng, a.shape[1], a.shape[0], amount)
    a[..., 3] *= keep
    # slightly sun-faded and grimed toward the bottom: low contrast
    grad = np.linspace(1.0, 0.92, a.shape[0])[:, None]
    a[..., :3] *= grad[..., None]
    atlas.alpha_composite(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA"), (x, y))


def _text_fit(d, box, text, font_path, fill, max_px, anchor="mm"):
    x0, y0, x1, y1 = box
    px = max_px
    while px > 8:
        f = _font(font_path, px)
        l, t, r, b = d.textbbox((0, 0), text, font=f)
        if r - l <= (x1 - x0) * 0.92 and b - t <= (y1 - y0) * 0.86:
            break
        px -= 2
    d.text(((x0 + x1) / 2, (y0 + y1) / 2), text, font=_font(font_path, px), fill=fill, anchor=anchor)


def _stripes(d, w, h, band, c1, c2):
    d.rectangle((0, 0, w, h), fill=c1)
    k = -2 * h
    while k < w + 2 * h:
        d.polygon([(k, h), (k + band, h), (k + band + h, 0), (k + h, 0)], fill=c2)
        k += 2 * band


def draw_decals(path):
    rng = np.random.default_rng(4401)
    atlas = Image.new("RGBA", (DW, DH), (0, 0, 0, 0))
    ss = 2
    for key, (label, (x, y, w, h), _) in DECALS.items():
        im = _cell(w, h, ss)
        d = ImageDraw.Draw(im)
        W, H = w * ss, h * ss
        if key in ("decalHaz", "decalHazS"):
            _stripes(d, W, H, H * 0.9, WARN, BLACK)
        elif key == "decalHazSq":
            _stripes(d, W, H, H * 0.14, WARN, BLACK)
            d.rectangle((0, 0, W - 1, H - 1), outline=BLACK, width=int(H * 0.04))
        elif key == "decalArrow":
            cy = H / 2
            d.polygon([(W * 0.05, cy - H * 0.16), (W * 0.58, cy - H * 0.16), (W * 0.58, cy - H * 0.42), (W * 0.96, cy),
                       (W * 0.58, cy + H * 0.42), (W * 0.58, cy + H * 0.16), (W * 0.05, cy + H * 0.16)], fill=INK)
        elif key == "decalChev":
            for i in range(3):
                x0 = W * (0.08 + i * 0.29)
                d.polygon([(x0, H * 0.1), (x0 + W * 0.13, H * 0.1), (x0 + W * 0.25, H * 0.5), (x0 + W * 0.13, H * 0.9),
                           (x0, H * 0.9), (x0 + W * 0.12, H * 0.5)], fill=WARN)
        elif key == "decalNoEntry":
            d.rectangle((0, 0, W, H), fill=DANGER)
            d.rectangle((H * 0.08, H * 0.08, W - H * 0.08, H - H * 0.08), outline=INK, width=int(H * 0.035))
            _text_fit(d, (0, 0, W, H), "NO ENTRY", FONT_LABEL, INK, H * 0.62)
        elif key == "decalAirlock":
            d.rectangle((0, 0, W, H), fill=WARN)
            _text_fit(d, (0, 0, W, H), "AIRLOCK", FONT_STENCIL, BLACK, H * 0.8)
        elif key == "decalPress":
            d.rectangle((0, 0, W, H), fill=ENAMEL)
            d.rectangle((H * 0.06, H * 0.06, W - H * 0.06, H - H * 0.06), outline=WARN, width=int(H * 0.03))
            _text_fit(d, (0, H * 0.06, W, H * 0.56), "PRESSURE DOOR", FONT_LABEL, WARN, H * 0.42)
            _text_fit(d, (0, H * 0.52, W, H * 0.92), "KEEP CLEAR WHILE CYCLING", FONT_LABEL, INK, H * 0.26)
        elif key == "decalLoad":
            d.rectangle((0, 0, W, H), fill=(205, 200, 185))
            d.rectangle((H * 0.06, H * 0.06, W - H * 0.06, H - H * 0.06), outline=BLACK, width=int(H * 0.03))
            _text_fit(d, (0, H * 0.06, W, H * 0.46), "MAX LOAD", FONT_LABEL, BLACK, H * 0.32)
            _text_fit(d, (0, H * 0.42, W, H * 0.94), "500 kg", FONT_STENCIL, BLACK, H * 0.5)
            for cx in (H * 0.16, W - H * 0.16):
                for cy in (H * 0.2, H * 0.8):
                    d.ellipse((cx - H * 0.04, cy - H * 0.04, cx + H * 0.04, cy + H * 0.04), fill=(120, 118, 110))
        elif key == "decalO2":
            d.rectangle((0, 0, W, H), fill=GREEN)
            d.rectangle((0, H * 0.12, W, H * 0.88), fill=(225, 222, 210))
            _text_fit(d, (0, 0, W * 0.6, H), "OXYGEN", FONT_LABEL, BLACK, H * 0.6)
            d.polygon([(W * 0.66, H * 0.3), (W * 0.86, H * 0.3), (W * 0.86, H * 0.18), (W * 0.97, H * 0.5),
                       (W * 0.86, H * 0.82), (W * 0.86, H * 0.7), (W * 0.66, H * 0.7)], fill=BLACK)
        elif key == "decalVolt":
            d.rectangle((0, 0, W, H), fill=WARN)
            tri = [(H * 0.15, H * 0.85), (H * 0.55, H * 0.12), (H * 0.95, H * 0.85)]
            d.polygon(tri, fill=BLACK)
            d.polygon([(H * 0.30, H * 0.76), (H * 0.55, H * 0.32), (H * 0.80, H * 0.76)], fill=WARN)
            d.polygon([(H * 0.58, H * 0.36), (H * 0.48, H * 0.58), (H * 0.57, H * 0.58), (H * 0.50, H * 0.74), (H * 0.65, H * 0.50),
                       (H * 0.56, H * 0.50)], fill=BLACK)
            _text_fit(d, (H * 1.05, 0, W, H), "DANGER 400 V", FONT_LABEL, BLACK, H * 0.6)
        elif key == "decalExit":
            d.rectangle((0, 0, W, H), fill=(52, 120, 70))
            _text_fit(d, (0, 0, W * 0.62, H), "EXIT", FONT_LABEL, INK, H * 0.66)
            d.polygon([(W * 0.66, H * 0.38), (W * 0.82, H * 0.38), (W * 0.82, H * 0.2), (W * 0.96, H * 0.5),
                       (W * 0.82, H * 0.8), (W * 0.82, H * 0.62), (W * 0.66, H * 0.62)], fill=INK)
        elif key in ("decalHalden", "decalPell"):
            name, sub = (("HALDEN", "STRUCTURAL") if key == "decalHalden" else ("PELL", "GROUNDWORKS"))
            # the mark: an I-beam section (Halden) or a stepped spade (Pell), in accent
            if key == "decalHalden":
                cx, cy, s = H * 0.5, H * 0.5, H * 0.34
                d.rectangle((cx - s, cy - s, cx + s, cy - s * 0.62), fill=ACCENT)
                d.rectangle((cx - s, cy + s * 0.62, cx + s, cy + s), fill=ACCENT)
                d.rectangle((cx - s * 0.2, cy - s, cx + s * 0.2, cy + s), fill=ACCENT)
            else:
                cx, cy, s = H * 0.5, H * 0.5, H * 0.34
                d.polygon([(cx - s, cy + s), (cx - s, cy), (cx - s * 0.4, cy), (cx - s * 0.4, cy - s * 0.5), (cx + s * 0.2, cy - s * 0.5),
                           (cx + s * 0.2, cy - s), (cx + s, cy - s), (cx + s, cy + s)], fill=ACCENT)
            _text_fit(d, (H * 0.95, H * 0.12, W - H * 0.05, H * 0.62), name, FONT_STENCIL, INK, H * 0.46)
            _text_fit(d, (H * 0.95, H * 0.58, W - H * 0.05, H * 0.9), sub, FONT_LABEL, INK, H * 0.24)
        elif key.startswith("decalNum"):
            _text_fit(d, (0, 0, W, H), key[-1], FONT_STENCIL, INK, H * 1.05)
        im = _down(im, w, h)
        _paste_worn(atlas, im, x, y, rng, amount=0.12 if key.startswith(("decalHal", "decalPell")) else 0.2)
    atlas.save(path)
    return path


def draw_grime(path):
    """Soft grime: alpha-blended films (not cutout), dark and low in saturation."""
    rng = np.random.default_rng(4402)
    atlas = np.zeros((GH, GW, 4), np.float32)

    def blobs(w, h, sigma, n, lo, hi):
        f = np.zeros((h, w), np.float32)
        for _ in range(n):
            cx, cy = rng.uniform(0, w), rng.uniform(0, h)
            r = rng.uniform(lo, hi)
            yy, xx = np.mgrid[0:h, 0:w]
            f += np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * r * r)))
        img = Image.fromarray(np.clip(f / max(f.max(), 1e-6) * 255, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(sigma))
        return np.asarray(img, np.float32) / 255

    def noise(w, h, scale):
        n = rng.standard_normal((max(2, int(h / scale)), max(2, int(w / scale)))).astype(np.float32)
        img = Image.fromarray(((n - n.min()) / (np.ptp(n) + 1e-6) * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        return np.asarray(img, np.float32) / 255

    def put(rect, col, alpha):
        x, y, w, h = rect
        atlas[y:y + h, x:x + w, :3] = np.asarray(col, np.float32)[None, None, :] / 255
        atlas[y:y + h, x:x + w, 3] = np.clip(alpha, 0, 1)

    for key, (label, rect, _) in GRIME.items():
        x, y, w, h = rect
        yy = np.linspace(0, 1, h)[:, None] * np.ones((1, w))
        xx = np.ones((h, 1)) * np.linspace(0, 1, w)[None, :]
        n1, n2 = noise(w, h, 18), noise(w, h, 5)
        if key == "grimeStreaks":
            cols = rng.uniform(0, 1, 26)
            streak = np.zeros((h, w), np.float32)
            for c in cols:
                cx = c * w
                wid = rng.uniform(2, 9)
                ln = rng.uniform(0.25, 0.85)
                streak += np.exp(-((xx * w - cx) ** 2) / (2 * wid * wid)) * np.clip(1 - yy / ln, 0, 1) ** 1.5 * rng.uniform(0.4, 1.0)
            splash = np.clip((yy - 0.82) / 0.18, 0, 1) ** 1.6 * (0.6 + 0.4 * n1)
            top = np.clip(1 - yy / 0.08, 0, 1) * 0.5
            a = np.clip(streak * 0.55 * (0.6 + 0.6 * n2) + splash * 0.75 + top * n1, 0, 0.85)
            put(rect, (48, 42, 34), a)
        elif key == "grimeScuff":
            path_ = np.exp(-((xx - 0.5 - 0.12 * np.sin(yy * 5.0)) ** 2) / (2 * 0.16 ** 2))
            marks = (n2 > 0.62).astype(np.float32) * 0.5
            a = np.clip(path_ * (0.25 + 0.35 * n1) + marks * path_ * 0.5, 0, 0.7)
            put(rect, (36, 34, 30), a)
        elif key == "grimeLeak":
            run = np.exp(-((xx - 0.5 + 0.05 * np.sin(yy * 9)) ** 2) / (2 * (0.07 + 0.18 * yy) ** 2))
            fade = np.clip(1 - yy, 0, 1) ** 0.7 * np.clip(yy * 12, 0, 1)
            a = np.clip(run * fade * (0.6 + 0.5 * n2), 0, 0.9)
            put(rect, (112, 58, 26), a)
        elif key == "grimeSoot":
            r = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) * 2
            a = np.clip((1 - r) ** 1.4 * (0.75 + 0.4 * n1) * (0.8 + 0.3 * n2), 0, 0.92)
            put(rect, (18, 17, 16), a)
        elif key == "grimeOil":
            r = np.sqrt(((xx - 0.5) * (1.0 + 0.3 * n1)) ** 2 + (yy - 0.5) ** 2) * 2
            a = np.clip((1 - r) * 3.0, 0, 1) * 0.75 * (0.7 + 0.3 * n2)
            put(rect, (14, 13, 12), a)
    img = Image.fromarray(np.clip(atlas * 255, 0, 255).astype(np.uint8), "RGBA")
    img.save(path)
    return path


def draw_sign_blank(path):
    """The sign's face before kit_live paints its text: dark enamel with a ruled border."""
    w, h = 512, 170
    im = Image.new("RGBA", (w, h), ENAMEL + (255,))
    d = ImageDraw.Draw(im)
    d.rectangle((8, 8, w - 9, h - 9), outline=INK, width=3)
    _text_fit(d, (0, 0, w, h), "SIGN", FONT_STENCIL, (120, 118, 108), 90)
    im.save(path)
    return path


def textures(dry=False):
    """The atlases and their maps (normal, ORM, height) via tools/detail_maps.decals."""
    if dry:
        return []
    import detail_maps as DM
    os.makedirs(KTEX, exist_ok=True)
    made = [draw_decals(os.path.join(KTEX, "decals.png")), draw_grime(os.path.join(KTEX, "grime.png")),
            draw_sign_blank(os.path.join(KTEX, "sign_blank.png"))]
    DM.decals("kit decals", made[0], 1000.0 / PXM, 0.55, 4403)
    DM.decals("kit grime", made[1], 1000.0 / GPXM, 0.85, 4404)
    DM.register_textures(made + DM.WRITTEN)
    DM.write_hjson()
    return made


# ── materials (prefab object_materials) ─────────────────────────────────────

def _maps(stem, blend=None, rough=1.0, cutoff=None):
    s = f"textures/kit/{stem}"
    out = (f'(\n                color: (1.0, 1.0, 1.0),\n'
           f'                texture: Some("{s}.png"),\n'
           f'                normal_map: Some("{s}_normal.png"),\n'
           f'                normal_strength: 1.0,\n'
           f'                roughness_map: Some("{s}_orm.png"),\n'
           f'                roughness: {rough},\n'
           f'                metallic_map: Some("{s}_orm.png"),\n'
           f'                metallic: 1.0,\n'
           f'                ao_map: Some("{s}_orm.png"),\n')
    if cutoff is not None:
        out += f'                alpha_cutoff: {cutoff},\n'
    if blend:
        out += f'                blend: Some({blend}),\n'
    return out + '                shading: Physical,\n            )'


def _lab(stem):
    s = f"textures/lab/{stem}"
    return (f'(\n                color: (1.0, 1.0, 1.0),\n'
            f'                texture: Some("{s}_albedo.png"),\n'
            f'                normal_map: Some("{s}_normal.png"),\n'
            f'                normal_strength: 1.0,\n'
            f'                roughness_map: Some("{s}_orm.png"),\n'
            f'                roughness: 1.0,\n'
            f'                ao_map: Some("{s}_orm.png"),\n'
            f'                shading: Physical,\n            )')


MATERIALS = {
    "Decal": lambda: _maps("decals", blend="Cutout", cutoff=0.45),
    "Grime": lambda: _maps("grime", blend="Blend"),
    "SignFace": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/kit/sign_blank.png"),\n'
                         '                roughness: 0.55,\n                metallic: 0.0,\n                shading: Physical,\n            )'),
    # (sprayed words: the same face, cut out where kit_live's picture is clear)
    "SignCut": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/kit/sign_blank.png"),\n'
                        '                roughness: 0.6,\n                metallic: 0.0,\n                alpha_cutoff: 0.45,\n'
                        '                blend: Some(Cutout),\n                shading: Physical,\n            )'),
    "Emblem": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/emblem_default.png"),\n'
                       '                roughness: 0.6,\n                metallic: 0.0,\n                alpha_cutoff: 0.45,\n'
                       '                blend: Some(Cutout),\n                shading: Physical,\n            )'),
    "Leaf": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/flora/foliage_l0.png"),\n'
                     '                normal_map: Some("textures/flora/foliage_n.png"),\n                normal_strength: 1.0,\n'
                     '                roughness: 0.75,\n                metallic: 0.0,\n                alpha_cutoff: 0.5,\n'
                     '                blend: Some(Cutout),\n                shading: Physical,\n            )'),
    "Cloth": lambda: _lab("cloth"),
}


# ── geometry helpers ─────────────────────────────────────────────────────────

def quad(m, mat, w, h, uv, y=0.003, col=(1, 1, 1)):
    """A quad facing +Y in the XZ plane (a mount's face), image top at -Z (up on a wall).
    uv = (u0, v0, u1, v1), v0 the image's top."""
    u0, v0, u1, v1 = uv
    m.color = col
    m.add(mat, [(-w / 2, y, -h / 2), (w / 2, y, -h / 2), (w / 2, y, h / 2), (-w / 2, y, h / 2)],
          [(0, 1, 0)] * 4, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)], [(0, 2, 1), (0, 3, 2)])


def pieces(K):
    """More entries for gen_kit_parts.PIECES, built with its primitives (K = that module)."""
    CModel, Shell, bx, tb = K.CModel, K.Shell, K.bx, K.tb
    DARK, GREY, LIGHT, SAFETY, RUBBER, LAMP_WARM, PAINT = K.DARK, K.GREY, K.LIGHT, K.SAFETY, K.RUBBER, K.LAMP_WARM, K.PAINT
    out = {}

    # ── decals ──
    def decal_fn(rect, atlas_w, atlas_h, pxm, mat):
        x, y, w, h = rect

        def fn(_mat):
            m, sh = CModel(seed=501), Shell()
            m.ground = False
            quad(m, mat, w / pxm, h / pxm, (x / atlas_w, y / atlas_h, (x + w) / atlas_w, (y + h) / atlas_h),
                 y=0.003 if mat == "Decal" else 0.002)
            return m, sh, []
        return fn

    for k, (label, rect, desc) in DECALS.items():
        out[k] = (decal_fn(rect, DW, DH, PXM, "Decal"), ["film"])
    for k, (label, rect, desc) in GRIME.items():
        out[k] = (decal_fn(rect, GW, GH, GPXM, "Grime"), ["film"])

    # ── signs: a plate (or bare paint) and a Face kit_live draws the text on ──
    def sign_fn(w, h, plate=True):
        def fn(_mat):
            m, sh = CModel(seed=511), Shell()
            m.ground = False
            fm = CModel(seed=512)
            fm.ground = False
            if plate:
                bx(m, "Steel", DARK, -w / 2 - 0.02, w / 2 + 0.02, 0, 0.008, -h / 2 - 0.02, h / 2 + 0.02)
                for sx in (-1, 1):
                    for sz in (-1, 1):
                        tb(m, "Steel", LIGHT, (sx * (w / 2 - 0.0), 0.008, sz * (h / 2 - 0.0)),
                           (sx * (w / 2 - 0.0), 0.014, sz * (h / 2 - 0.0)), 0.009, segs=6)
                quad(fm, "SignFace", w, h, (0, 0, 1, 1), y=0.0)
                return m, sh, [("Face", "mesh", (fm, (0, 0.0095, 0)))]
            quad(fm, "SignCut", w, h, (0, 0, 1, 1), y=0.0)
            # (bare paint: a hairline backer so the piece has a body to hit)
            bx(m, "Steel", DARK, -0.01, 0.01, 0, 0.002, -0.01, 0.01)
            return m, sh, [("Face", "mesh", (fm, (0, 0.003, 0)))]
        return fn

    out["signPlate"] = (sign_fn(0.9, 0.3), ["steel"])
    out["signBoard"] = (sign_fn(2.0, 0.5), ["steel"])
    out["signStencil"] = (sign_fn(1.6, 0.32, plate=False), ["film"])

    def emblem_fn(_mat):
        m, sh = CModel(seed=521), Shell()
        m.ground = False
        bx(m, "Steel", DARK, -0.01, 0.01, 0, 0.002, -0.01, 0.01)
        fm = CModel(seed=522)
        fm.ground = False
        quad(fm, "Emblem", 0.8, 0.8, (0, 0, 1, 1), y=0.0)
        return m, sh, [("Face", "mesh", (fm, (0, 0.003, 0)))]
    out["decalEmblem"] = (emblem_fn, ["film"])

    # ── props: furniture and storage ──
    CRATE = (0.36, 0.40, 0.33)      # olive-drab crate panels (the kit paints over them)

    def p_crate(_mat, w=1.2, h=0.8, d=0.8, seed=531):
        m, sh = CModel(seed=seed), Shell()
        bx(m, "Clad", CRATE, -w / 2 + 0.03, w / 2 - 0.03, 0.03, h - 0.03, -d / 2 + 0.03, d / 2 - 0.03)
        e = 0.04
        for sx in (-1, 1):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, sx * w / 2 - (e if sx > 0 else 0), sx * w / 2 + (0 if sx > 0 else e), 0, h,
                   sz * d / 2 - (e if sz > 0 else 0), sz * d / 2 + (0 if sz > 0 else e))
        for y in (0.0, h - e):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, -w / 2, w / 2, y, y + e, sz * d / 2 - (e if sz > 0 else 0), sz * d / 2 + (0 if sz > 0 else e))
            for sx in (-1, 1):
                bx(m, "Steel", GREY, sx * w / 2 - (e if sx > 0 else 0), sx * w / 2 + (0 if sx > 0 else e), y, y + e, -d / 2, d / 2)
        # the latches and a stencil plate on the front
        for x in (-w / 4, w / 4):
            bx(m, "Steel", DARK, x - 0.04, x + 0.04, h - 0.16, h - 0.08, d / 2 - 0.01, d / 2 + 0.012)
        bx(m, "Steel", SAFETY, -0.12, 0.12, h * 0.4, h * 0.4 + 0.1, d / 2 - 0.01, d / 2 + 0.006)
        sh.add((0, h / 2, 0), (w, h, d))
        return m, sh, []
    out["crate"] = (p_crate, ["steel"])
    out["crateS"] = (lambda _m: p_crate(_m, 0.6, 0.45, 0.45, seed=532), ["steel"])

    def p_drum(_mat):
        m, sh = CModel(seed=533), Shell()
        tb(m, "Steel", (0.30, 0.36, 0.42), (0, 0.0, 0), (0, 0.88, 0), 0.29, segs=20)
        for y in (0.02, 0.3, 0.58, 0.86):
            tb(m, "Steel", (0.26, 0.31, 0.36), (0, y, 0), (0, y + 0.025, 0), 0.298, segs=20)
        tb(m, "Steel", DARK, (0.15, 0.88, 0.0), (0.15, 0.9, 0.0), 0.03, segs=8)
        bx(m, "Steel", SAFETY, -0.1, 0.1, 0.5, 0.62, 0.285, 0.297)
        sh.add((0, 0.44, 0), (0.58, 0.88, 0.58))
        return m, sh, []
    out["drum"] = (p_drum, ["steel"])

    def p_shelf(_mat):
        m, sh = CModel(seed=534), Shell()
        w, h, d = 1.2, 2.0, 0.45
        for sx in (-1, 1):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, sx * (w / 2 - 0.02) - 0.02, sx * (w / 2 - 0.02) + 0.02, 0, h, sz * (d / 2 - 0.02) - 0.02, sz * (d / 2 - 0.02) + 0.02)
        rng = np.random.default_rng(535)
        for i, y in enumerate((0.1, 0.55, 1.0, 1.45, 1.9)):
            bx(m, "Steel", LIGHT, -w / 2, w / 2, y, y + 0.025, -d / 2, d / 2)
            if y > 1.85:
                continue
            x = -w / 2 + 0.05
            while x < w / 2 - 0.15:
                bw = float(rng.uniform(0.18, 0.36))
                bh = float(rng.uniform(0.12, 0.34))
                bd = float(rng.uniform(0.22, 0.38))
                if x + bw > w / 2 - 0.04:
                    break
                c = [(0.55, 0.45, 0.32), (0.32, 0.36, 0.30), (0.62, 0.60, 0.55), (0.25, 0.27, 0.30)][int(rng.integers(0, 4))]
                bx(m, "Clad", c, x, x + bw, y + 0.025, y + 0.025 + bh, -bd / 2, bd / 2)
                x += bw + float(rng.uniform(0.02, 0.08))
        bx(m, "Steel", GREY, -w / 2, w / 2, 0.9, 0.93, -d / 2 + 0.005, -d / 2 + 0.015)
        sh.add((0, h / 2, 0), (w, h, d))
        return m, sh, []
    out["shelf"] = (p_shelf, ["steel"])

    def p_table(_mat):
        m, sh = CModel(seed=536), Shell()
        w, d, h = 1.6, 0.8, 0.74
        bx(m, "Clad", (0.62, 0.62, 0.60), -w / 2, w / 2, h - 0.035, h, -d / 2, d / 2)
        bx(m, "Steel", DARK, -w / 2, w / 2, h - 0.045, h - 0.035, -d / 2, d / 2)
        for sx in (-1, 1):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, sx * (w / 2 - 0.06) - 0.025, sx * (w / 2 - 0.06) + 0.025, 0, h - 0.045, sz * (d / 2 - 0.06) - 0.025, sz * (d / 2 - 0.06) + 0.025)
        bx(m, "Steel", GREY, -w / 2 + 0.06, w / 2 - 0.06, 0.12, 0.15, -0.012, 0.012)
        sh.add((0, h - 0.02, 0), (w, 0.04, d))
        for sx in (-1, 1):
            sh.add((sx * (w / 2 - 0.06), (h - 0.045) / 2, 0), (0.05, h - 0.045, d - 0.12))
        return m, sh, []
    out["table"] = (p_table, ["steel"])

    def p_chair(_mat):
        m, sh = CModel(seed=537), Shell()
        bx(m, "Rubber", RUBBER, -0.22, 0.22, 0.44, 0.5, -0.22, 0.2)
        bx(m, "Rubber", RUBBER, -0.21, 0.21, 0.55, 0.92, -0.25, -0.21)
        for sx in (-1, 1):
            tb(m, "Steel", GREY, (sx * 0.2, 0.0, 0.18), (sx * 0.2, 0.44, 0.16), 0.012, segs=6)
            tb(m, "Steel", GREY, (sx * 0.2, 0.0, -0.2), (sx * 0.2, 0.92, -0.24), 0.012, segs=6)
        tb(m, "Steel", GREY, (-0.2, 0.25, -0.21), (0.2, 0.25, -0.21), 0.01, segs=6)
        sh.add((0, 0.25, 0), (0.44, 0.5, 0.44))
        return m, sh, []
    out["chair"] = (p_chair, ["steel"])

    def p_bunk(_mat):
        m, sh = CModel(seed=538), Shell()
        L, W = 2.0, 0.9
        for sx in (-1, 1):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, sx * (L / 2) - (0.04 if sx > 0 else 0), sx * (L / 2) + (0 if sx > 0 else 0.04), 0, 1.75,
                   sz * (W / 2) - (0.04 if sz > 0 else 0), sz * (W / 2) + (0 if sz > 0 else 0.04))
        for y in (0.35, 1.25):
            bx(m, "Steel", DARK, -L / 2, L / 2, y - 0.04, y, -W / 2, W / 2)
            bx(m, "Cloth", (0.40, 0.44, 0.40), -L / 2 + 0.05, L / 2 - 0.05, y, y + 0.13, -W / 2 + 0.04, W / 2 - 0.04)
            bx(m, "Cloth", (0.82, 0.80, 0.74), L / 2 - 0.45, L / 2 - 0.08, y + 0.13, y + 0.22, -W / 2 + 0.12, W / 2 - 0.12)
            # a folded blanket at the foot
            bx(m, "Cloth", (0.30, 0.33, 0.42), -L / 2 + 0.1, -L / 2 + 0.55, y + 0.13, y + 0.2, -W / 2 + 0.06, W / 2 - 0.06)
            for sz in (-1, 1):
                bx(m, "Steel", GREY, -L / 2, L / 2, y + 0.14, y + 0.17, sz * W / 2 - 0.02, sz * W / 2 + 0.02) if sz < 0 else None
        # the ladder at the foot
        for k in range(4):
            yy = 0.5 + k * 0.25
            tb(m, "Steel", LIGHT, (-L / 2 + 0.02, yy, W / 2 - 0.25), (-L / 2 + 0.02, yy, W / 2 - 0.02), 0.012, segs=6)
        sh.add((0, 0.875, 0), (L, 1.75, W))
        return m, sh, []
    out["bunk"] = (p_bunk, ["steel"])

    def p_workbench(_mat):
        m, sh = CModel(seed=539), Shell()
        L, D, H = 1.8, 0.75, 0.9
        bx(m, "Steel", (0.42, 0.44, 0.40), -L / 2, L / 2, H - 0.05, H, -D / 2, D / 2)
        bx(m, "Steel", DARK, -L / 2 + 0.04, -L / 2 + 0.6, 0.08, H - 0.05, -D / 2 + 0.04, D / 2 - 0.02)
        for k in range(4):
            y = 0.12 + k * 0.17
            bx(m, "Steel", (0.50, 0.20, 0.14), -L / 2 + 0.06, -L / 2 + 0.58, y, y + 0.15, D / 2 - 0.02, D / 2 - 0.005)
            bx(m, "Steel", LIGHT, -L / 2 + 0.25, -L / 2 + 0.39, y + 0.1, y + 0.12, D / 2 - 0.005, D / 2 + 0.01)
        for sx in (1,):
            for sz in (-1, 1):
                bx(m, "Steel", GREY, sx * (L / 2 - 0.04) - 0.03, sx * (L / 2 - 0.04) + 0.03, 0, H - 0.05, sz * (D / 2 - 0.04) - 0.03, sz * (D / 2 - 0.04) + 0.03)
        bx(m, "Steel", GREY, -L / 2 + 0.6, L / 2 - 0.04, 0.15, 0.18, -D / 2 + 0.04, D / 2 - 0.04)
        # the pegboard behind, the vice, a few tools on the top
        bx(m, "Clad", (0.55, 0.52, 0.44), -L / 2, L / 2, H, H + 1.0, -D / 2, -D / 2 + 0.025)
        for i in range(14):
            for j in range(7):
                bx(m, "Steel", DARK, -L / 2 + 0.08 + i * 0.12, -L / 2 + 0.095 + i * 0.12, H + 0.1 + j * 0.13, H + 0.115 + j * 0.13,
                   -D / 2 + 0.025, -D / 2 + 0.027)
        for x0, y0, ln in ((-0.6, 0.35, 0.28), (-0.45, 0.32, 0.24), (-0.3, 0.3, 0.3), (0.2, 0.4, 0.22), (0.35, 0.38, 0.26), (0.5, 0.42, 0.2)):
            bx(m, "Steel", LIGHT, x0 - 0.012, x0 + 0.012, H + 0.95 - y0 - ln, H + 0.95 - y0, -D / 2 + 0.027, -D / 2 + 0.04)
        bx(m, "Steel", (0.30, 0.38, 0.46), 0.55, 0.75, H, H + 0.1, -0.05, 0.12)
        bx(m, "Steel", DARK, 0.6, 0.7, H + 0.1, H + 0.16, -0.05, 0.12)
        tb(m, "Steel", LIGHT, (0.65, H + 0.13, 0.12), (0.65, H + 0.13, 0.22), 0.008, segs=6)
        bx(m, "Steel", (0.62, 0.20, 0.12), -0.2, 0.15, H, H + 0.12, 0.05, 0.25)
        bx(m, "Steel", DARK, -0.15, 0.1, H + 0.12, H + 0.14, 0.12, 0.18)
        sh.add((0, H / 2, 0), (L, H, D))
        sh.add((0, H + 0.5, -D / 2 + 0.0125), (L, 1.0, 0.025))
        return m, sh, []
    out["workbench"] = (p_workbench, ["steel"])

    def p_coffee(_mat):
        m, sh = CModel(seed=540), Shell()
        bx(m, "Steel", DARK, -0.12, 0.12, 0, 0.34, -0.14, 0.12)
        bx(m, "Steel", (0.62, 0.62, 0.60), -0.12, 0.12, 0.34, 0.38, -0.14, 0.12)
        tb(m, "Pane", (1, 1, 1), (0, 0.02, 0.06), (0, 0.17, 0.06), 0.06, segs=12)
        tb(m, "Steel", DARK, (0, 0.17, 0.06), (0, 0.19, 0.06), 0.065, segs=12)
        bx(m, "Lamp", (1.0, 0.3, 0.2), 0.06, 0.09, 0.28, 0.3, 0.12, 0.124)
        for x in (0.2, 0.3):
            tb(m, "Clad", (0.80, 0.78, 0.72), (x, 0, 0.0), (x, 0.09, 0.0), 0.04, segs=10)
        return m, sh, []
    out["coffee"] = (p_coffee, ["steel"])

    def p_monitor(_mat):
        m, sh = CModel(seed=541), Shell()
        bx(m, "Steel", DARK, -0.12, 0.12, 0, 0.015, -0.09, 0.09)
        tb(m, "Steel", GREY, (0, 0.015, -0.03), (0, 0.22, -0.03), 0.015, segs=8)
        bx(m, "Steel", DARK, -0.28, 0.28, 0.16, 0.5, -0.05, -0.02)
        bx(m, "Screen", (1, 1, 1), -0.26, 0.26, 0.18, 0.48, -0.02, -0.018)
        # a keyboard in front of it
        bx(m, "Steel", DARK, -0.22, 0.22, 0, 0.02, 0.06, 0.2)
        for i in range(12):
            for j in range(4):
                bx(m, "Steel", (0.30, 0.31, 0.31), -0.205 + i * 0.034, -0.18 + i * 0.034, 0.02, 0.026, 0.075 + j * 0.03, 0.098 + j * 0.03)
        return m, sh, []
    out["monitor"] = (p_monitor, ["steel"])

    def p_plant(_mat):
        m, sh = CModel(seed=542), Shell()
        m.ground = False
        m.color = (0.30, 0.28, 0.26)
        K.tube(m, "Concrete", (0, 0, 0), (0, 0.34, 0), 0.15, segs=16, uv_m=K.UVM["Concrete"], r1=0.19)
        tb(m, "Steel", DARK, (0, 0.3, 0), (0, 0.33, 0), 0.17, segs=16)
        # soil, then two crossed cards of the flora atlas's leafy shrub (its tile 0,0)
        tb(m, "Rubber", (0.12, 0.09, 0.07), (0, 0.3, 0), (0, 0.32, 0), 0.165, segs=16)
        m.color = (0.42, 0.62, 0.36)
        u0, v0, u1, v1 = 0.0, 0.0, 0.25, 0.25
        hgt, wid = 0.62, 0.62
        for a in (0.0, math.pi / 3, 2 * math.pi / 3):
            c, s = math.cos(a), math.sin(a)
            P = [(-wid / 2 * c, 0.28, -wid / 2 * s), (wid / 2 * c, 0.28, wid / 2 * s), (wid / 2 * c, 0.28 + hgt, wid / 2 * s), (-wid / 2 * c, 0.28 + hgt, -wid / 2 * s)]
            nrm = (-s, 0.0, c)
            m.add("Leaf", P, [nrm] * 4, [(u0, v1), (u1, v1), (u1, v0), (u0, v0)], [(0, 1, 2), (0, 2, 3)])
        return m, sh, []
    out["plant"] = (p_plant, ["steel"])

    def p_reel(_mat):
        m, sh = CModel(seed=543), Shell()
        for z in (-0.2, 0.2):
            m.color = (0.55, 0.36, 0.20)
            sub = CModel(seed=544)
            sub.ground = False
            sub.color = (0.55, 0.36, 0.20)
            K.disk(sub, "Steel", 0.35, 0.0, segs=20, up=True)
            K.disk(sub, "Steel", 0.35, -0.03, segs=20, up=False)
            m.merge(sub, M=K.rot_x(math.pi / 2), t=(0, 0.35, z + 0.015))
        tb(m, "Rubber", RUBBER, (0, 0.35, -0.18), (0, 0.35, 0.18), 0.25, segs=18)
        tb(m, "Steel", GREY, (0, 0.35, -0.24), (0, 0.35, 0.24), 0.04, segs=8)
        tb(m, "Rubber", RUBBER, (0.0, 0.1, 0.1), (0.5, 0.012, 0.25), 0.02, segs=6)
        sh.add((0, 0.35, 0), (0.7, 0.7, 0.44))
        return m, sh, []
    out["cableReel"] = (p_reel, ["steel"])

    # ── mounts: on a wall (or a ceiling), modelled lying face up, +Y out, -Z up the wall ──
    def p_toolRack(_mat):
        m, sh = CModel(seed=545), Shell()
        m.ground = False
        bx(m, "Clad", (0.50, 0.48, 0.40), -0.6, 0.6, 0, 0.02, -0.4, 0.4)
        bx(m, "Steel", GREY, -0.6, 0.6, 0.02, 0.05, -0.4, -0.36)
        tools = [(-0.5, 0.06, 0.34, LIGHT), (-0.4, 0.05, 0.3, LIGHT), (-0.3, 0.06, 0.26, LIGHT), (-0.15, 0.07, 0.38, (0.6, 0.2, 0.12)),
                 (0.0, 0.05, 0.3, DARK), (0.12, 0.08, 0.22, (0.85, 0.65, 0.15)), (0.28, 0.05, 0.36, LIGHT), (0.42, 0.09, 0.28, (0.25, 0.30, 0.38))]
        for x, w, ln, col in tools:
            tb(m, "Steel", DARK, (x, 0.02, -0.33), (x, 0.07, -0.33), 0.006, segs=5)
            bx(m, "Steel", col, x - w / 4, x + w / 4, 0.03, 0.055, -0.32, -0.32 + ln)
            bx(m, "Steel", col, x - w / 2, x + w / 2, 0.03, 0.06, -0.32 + ln - 0.06, -0.32 + ln)
        return m, sh, []
    out["toolRack"] = (p_toolRack, ["steel"])

    def p_pipeRun(_mat):
        m, sh = CModel(seed=546), Shell()
        m.ground = False
        for x in (-0.8, 0.0, 0.8):
            bx(m, "Steel", DARK, x - 0.03, x + 0.03, 0, 0.2, -0.16, 0.16)
        for z, r, col in ((-0.08, 0.045, (0.25, 0.42, 0.30)), (0.08, 0.035, (0.62, 0.60, 0.55))):
            tb(m, "Steel", col, (-1.0, 0.12, z), (1.0, 0.12, z), r, segs=12)
            for x in (-0.8, 0.0, 0.8):
                tb(m, "Steel", GREY, (x - 0.02, 0.12, z), (x + 0.02, 0.12, z), r + 0.012, segs=12)
        # a valve with its handwheel on the green line
        tb(m, "Steel", (0.62, 0.20, 0.12), (0.4, 0.12, -0.08), (0.4, 0.22, -0.08), 0.02, segs=8)
        tb(m, "Steel", (0.62, 0.20, 0.12), (0.4, 0.22, -0.08), (0.4, 0.235, -0.08), 0.07, segs=14)
        return m, sh, []
    out["pipeRun"] = (p_pipeRun, ["steel"])

    def p_cableRun(_mat):
        m, sh = CModel(seed=547), Shell()
        m.ground = False
        for x in (-0.9, -0.3, 0.3, 0.9):
            bx(m, "Steel", GREY, x - 0.02, x + 0.02, 0, 0.07, -0.08, 0.08)
        for k, (z, r) in enumerate(((-0.05, 0.014), (-0.02, 0.018), (0.015, 0.012), (0.05, 0.016))):
            col = RUBBER if k != 2 else (0.55, 0.30, 0.10)
            tb(m, "Rubber", col, (-1.0, 0.035, z), (1.0, 0.035, z), r, segs=6)
        # one cable sagging off the run
        pts = [(0.6, 0.035, 0.05), (0.7, 0.09, 0.12), (0.78, 0.14, 0.2), (0.82, 0.16, 0.32)]
        for a, b in zip(pts, pts[1:]):
            tb(m, "Rubber", RUBBER, a, b, 0.012, segs=6)
        return m, sh, []
    out["cableRun"] = (p_cableRun, ["steel"])

    def p_extinguisher(_mat):
        m, sh = CModel(seed=548), Shell()
        m.ground = False
        bx(m, "Steel", DARK, -0.05, 0.05, 0, 0.02, -0.22, 0.2)
        tb(m, "Steel", (0.68, 0.10, 0.07), (0, 0.1, 0.25), (0, 0.1, -0.2), 0.075, segs=14)
        tb(m, "Steel", DARK, (0, 0.1, -0.2), (0, 0.1, -0.26), 0.03, segs=8)
        bx(m, "Steel", DARK, -0.015, 0.015, 0.08, 0.13, -0.32, -0.24)
        tb(m, "Rubber", RUBBER, (0.03, 0.1, -0.25), (0.07, 0.16, -0.1), 0.01, segs=6)
        tb(m, "Rubber", RUBBER, (0.07, 0.16, -0.1), (0.06, 0.18, 0.15), 0.01, segs=6)
        bx(m, "Clad", (0.82, 0.80, 0.74), -0.045, 0.045, 0.172, 0.176, -0.05, 0.08)
        return m, sh, []
    out["extinguisher"] = (p_extinguisher, ["steel"])

    # ── lamps (kit_live pools their lights): the lens is its own "Lens" child ──
    def p_lampDesk(_mat):
        m, sh = CModel(seed=549), Shell()
        tb(m, "Steel", DARK, (0, 0, 0), (0, 0.02, 0), 0.08, segs=14)
        tb(m, "Steel", GREY, (0, 0.02, 0), (0.0, 0.3, -0.08), 0.01, segs=6)
        tb(m, "Steel", GREY, (0.0, 0.3, -0.08), (0.0, 0.45, 0.1), 0.01, segs=6)
        m.color = (0.20, 0.30, 0.26)
        K.tube(m, "Steel", (0.0, 0.47, 0.12), (0.0, 0.40, 0.2), 0.03, segs=12, uv_m=1.0, r1=0.075)
        lm = CModel(seed=550)
        lm.ground = False
        lm.color = LAMP_WARM
        K.disk(lm, "Lamp", 0.07, 0.0, segs=12, up=False)
        return m, sh, [("Lens", "mesh", (lm, (0.0, 0.395, 0.205))), ("Light", "empty", (0.0, 0.33, 0.26))]
    out["lampDesk"] = (p_lampDesk, ["steel"])

    def p_lampFloor(_mat):
        m, sh = CModel(seed=551), Shell()
        for k in range(3):
            a = k * K.TAU / 3
            tb(m, "Steel", (0.75, 0.62, 0.14), (0.32 * math.cos(a), 0.0, 0.32 * math.sin(a)), (0, 0.55, 0), 0.012, segs=6)
        tb(m, "Steel", (0.75, 0.62, 0.14), (0, 0.5, 0), (0, 1.55, 0), 0.018, segs=8)
        bx(m, "Steel", DARK, -0.17, 0.17, 1.5, 1.74, -0.06, 0.04)
        bx(m, "Steel", GREY, -0.19, 0.19, 1.48, 1.5, -0.08, 0.06)
        lm = CModel(seed=552)
        lm.ground = False
        bx(lm, "Lamp", (0.92, 0.96, 1.0), -0.15, 0.15, 0, 0.2, -0.004, 0.0)
        return m, sh, [("Lens", "mesh", (lm, (0.0, 1.52, 0.044))), ("Light", "empty", (0.0, 1.62, 0.3))]
    out["lampFloor"] = (p_lampFloor, ["steel"])

    return out
