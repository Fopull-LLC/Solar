#!/usr/bin/env python3
"""Generate the RESEARCH LAB's interior: a pristine materials-science lab.

    python3 tools/gen_lab.py           # textures/lab/*, models/lab/*.glb, prefabs/LabInterior + LabCapsule
    python3 tools/gen_lab.py --dry     # sizes, tris, z-fight check

The shell is FacLab (tools/base_buildings.py lab(), written by
tools/gen_base.py); LabInterior's origin IS FacLab's (the shell's box centre),
so base_facilities spawns both with one position and rotation, and
scripts/lab.lua switches the interior on only while the crew is inside, in
the link corridor or the depot, or at the outside door (outside, none of it
is drawn, lit or simulated).

WHAT IS IN IT, in the shell's ground frame (y up from the slab, +z the front,
the lab 21.3 × 13.3 m inside):
  * WHITE SATIN WALL PANELS on 1.2 m centres with their seams, a brushed
    steel coved skirting, a suspended 600 mm ceiling grid with flush LED
    panels and square diffusers, cable trays, sprinklers;
  * along the north wall three FUME HOODS (sashes half up, lit inside, their
    exhaust ducts into the ceiling, airflow monitors), the EMERGENCY SHOWER
    and EYEWASH, a sink bench under a periodic table;
  * two ISLAND BENCHES with black epoxy-resin tops, a service spine of gas
    taps and sockets, glass reagent shelves over them, and on them
    microscopes, a stirrer hotplate, glassware, sample trays;
  * a south WALL BENCH: microscopes, an analytical balance in its draft
    shield, a centrifuge, a vial rack, wall cupboards with glass doors;
  * the SAMPLE RECEIVING STATION in the south-west corner, where the
    pneumatic tube from the Materials Intake comes through the wall, runs
    under the ceiling and drops into a glass receiver on a steel cabinet;
  * a GLOVE BOX (argon) and storage on the west wall, a −80 °C freezer, a
    whiteboard and a flammables cabinet on the east;
  * behind GLASS PARTITIONS: the INSTRUMENT ROOM (an SEM, an XRF analyser, a
    mass spectrometer, a rack) and the ENTRY VESTIBULE from the link corridor
    (coats on hooks, a tacky mat, the sliding doors);
  * light wear: scuffs in the aisles, a darker line where the floor meets
    the benches, labels, tape.

DRAW COST. One mesh node per material family, ten materials, about 60 k
triangles; six real lights (the engine shades the 16 most important) and the
rest glow. Every walkable surface and solid piece is a static box body (LabSolid N),
never switched off.

Prefabs written: LabInterior; LabCapsule (the sample capsule lab.lua sends
up the tube).
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base_tex  # noqa: E402
from base_models import CModel, Shell, cuboid, zcheck  # noqa: E402
from gen_base import f3, spot_rotation, write_glb  # noqa: E402
from gen_part_meshes import PREFABS, ROOT, box, lathe, tube  # noqa: E402
import base_buildings  # noqa: E402

MODELS = os.path.join(ROOT, "models", "lab")
TEXDIR = os.path.join(ROOT, "textures", "lab")
TEX = "textures/lab/"
L = base_buildings.LAB

# ── the room ────────────────────────────────────────────────────────────────
XI = L["W"] - L["t"] - 0.03        # the wall lining's inner face
ZI = L["D"] - L["t"] - 0.03
FT = 0.15                           # the floor's finished top (vinyl on the slab)
CY = 3.45                           # the ceiling
# partitions
VX, VZ = 6.2, 3.4                   # the entry vestibule: x ≥ VX, z ≥ VZ
IX, IZ = 1.5, -2.0                  # the instrument room: x ≥ IX, z ≤ IZ
INNER_DOOR = (4.35, 5.55)           # the vestibule's sliding door, along z on x = VX
INSTR_DOOR = (3.0, 4.2)             # the instrument room's door, along x on z = IZ

# ── colours (vertex colours, linear, on near-white textures) ────────────────
WALL = (0.93, 0.93, 0.92)
WALL_SEAM = (0.55, 0.56, 0.56)
CASE = (0.88, 0.885, 0.88)          # painted steel casework
CASE_SH = (0.80, 0.81, 0.81)
RESIN = (0.035, 0.038, 0.040)       # black epoxy bench tops
STEEL = (0.78, 0.79, 0.80)
STEEL_D = (0.46, 0.47, 0.48)
ALU = (0.70, 0.71, 0.72)            # the partitions' anodised frames
DARKP = (0.06, 0.065, 0.07)         # dark plastics
FLOOR = (0.78, 0.785, 0.78)
SAFETY_Y = (0.78, 0.60, 0.05)
SAFETY_G = (0.05, 0.42, 0.20)
RED = (0.55, 0.05, 0.04)
BLUE_GLOVE = (0.10, 0.20, 0.55)
LAMP = (0.66, 0.655, 0.635)        # a diffused LED panel: it glows, it doesn't blaze
LAMP_TASK = (0.80, 0.68, 0.50)     # the warm task strips under cupboards and in the hoods
TACKY = (0.30, 0.42, 0.58)


# ═════════════════════════════════════════════════════════════════════════════
# textures
# ═════════════════════════════════════════════════════════════════════════════

def _blur_noise(n, rng, cell, rad):
    a = rng.random((max(2, n // cell), max(2, n // cell)))
    im = Image.fromarray((a * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC).filter(ImageFilter.GaussianBlur(rad))
    return np.asarray(im, np.float32) / 255


def _save(arr, name):
    Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(TEXDIR, name), optimize=True)


def textures():
    os.makedirs(TEXDIR, exist_ok=True)
    rng = np.random.default_rng(41)
    n = 512
    # the wall panels: satin white laminate, barely mottled
    m = _blur_noise(n, rng, 16, 6) * 0.6 + _blur_noise(n, rng, 4, 1.5) * 0.4
    a = 0.955 + 0.03 * (m - 0.5)
    _save(np.stack([a, a, a * 0.995], -1), "wall_albedo.png")
    # the floor: sheet vinyl, light warm grey with fine chips, a soft mottle
    chips = rng.random((n, n))
    chip = (chips > 0.985).astype(np.float32) * rng.uniform(-0.18, 0.12, (n, n))
    chip = np.asarray(Image.fromarray(((chip + 0.5) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6)),
                      np.float32) / 255 - 0.5
    mot = _blur_noise(n, rng, 32, 10) - 0.5
    f = 0.90 + chip * 0.9 + mot * 0.05
    _save(np.stack([f, f * 0.995, f * 0.985], -1), "floor_albedo.png")
    from gen_part_textures import normal_from_height
    h = mot * 0.6 + chip * 0.3
    _save(normal_from_height(h, 2.0), "floor_normal.png")
    rough = 0.30 + 0.12 * (_blur_noise(n, rng, 24, 8) - 0.5) + 0.08 * np.abs(chip)
    _save(np.stack([np.ones_like(rough), rough, np.zeros_like(rough)], -1), "floor_orm.png")
    # brushed stainless: streaks along u
    s = rng.normal(0, 1, (n, 1)) * np.ones((1, n))
    s = np.asarray(Image.fromarray(((s * 0.1 + 0.5) * 255).clip(0, 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(0.8)), np.float32) / 255
    s = s.T
    st = 0.82 + (s - 0.5) * 0.12 + (_blur_noise(n, rng, 32, 8) - 0.5) * 0.04
    _save(np.stack([st, st, st * 1.01], -1), "steel_albedo.png")
    sr = 0.30 + (s - 0.5) * 0.25 + (_blur_noise(n, rng, 32, 10) - 0.5) * 0.1
    _save(np.stack([np.ones_like(sr), sr, np.ones_like(sr)], -1), "steel_orm.png")
    _save(normal_from_height((s - 0.5) * 0.3, 1.0), "steel_normal.png")
    signs()


# ── the sign and screen atlas ───────────────────────────────────────────────
ATLAS_W, ATLAS_H = 2048, 2048
PIX = {}


def _pack(img, items):
    x, y, row = 4, 4, 0
    for name, tile in sorted(items, key=lambda t: -t[1].size[1]):
        w, h = tile.size
        if x + w + 4 > ATLAS_W:
            x, y, row = 4, y + row + 6, 0
        assert y + h <= ATLAS_H, "the lab sign atlas is full: %d" % (y + h)
        img.paste(tile, (x, y))
        base_tex.REGIONS["l_" + name] = ((x + 0.5) / ATLAS_W, (y + 0.5) / ATLAS_H,
                                         (x + w - 0.5) / ATLAS_W, (y + h - 0.5) / ATLAS_H)
        PIX["l_" + name] = (w, h)
        x += w + 6
        row = max(row, h)


def _font(size, kind="label"):
    p = {"label": base_tex.FONT_LABEL, "stencil": base_tex.FONT_STENCIL,
         "mono": os.path.join(ROOT, "fonts", "NotoSansMono-Medium.ttf")}[kind]
    return ImageFont.truetype(p, size)


def _screen(kind, w, h, seed):
    """An instrument display, unlit: dark field, a grid, a trace or an image."""
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (w, h), (12, 16, 22))
    d = ImageDraw.Draw(img)
    f = _font(max(10, h // 16), "mono")
    fb = _font(max(11, h // 13), "label")
    d.rectangle([0, 0, w, h // 11], fill=(28, 40, 58))
    if kind == "xrf":
        d.text((8, 2), "XRF  ·  SAMPLE 2611-04  ·  LIVE 120 s", font=f, fill=(190, 210, 230))
        for x in range(0, w, w // 10):
            d.line([(x, h // 11), (x, h - 20)], fill=(26, 34, 46))
        peaks = [(0.14, 0.35, "Si"), (0.22, 0.18, "S"), (0.42, 0.22, "Ca"), (0.62, 0.95, "Fe Kα"), (0.68, 0.25, "Fe Kβ"),
                 (0.78, 0.40, "Cu Kα"), (0.86, 0.12, "Zn")]
        xs = np.linspace(0, 1, w)
        ys = 0.03 + 0.02 * rng.random(w)
        for (c, a, _) in peaks:
            ys = ys + a * np.exp(-((xs - c) / 0.008) ** 2)
        pts = [(i, h - 22 - ys[i] * (h * 0.7)) for i in range(w)]
        d.line(pts, fill=(120, 230, 160), width=2)
        for (c, a, lab_) in peaks:
            d.text((int(c * w) - 10, int(h - 30 - a * h * 0.7) - 16), lab_, font=f, fill=(240, 210, 120))
        d.text((8, h - 18), "0 keV" + " " * 18 + "10" + " " * 18 + "20", font=f, fill=(120, 140, 160))
    elif kind == "sem":
        d.text((8, 2), "SEM  15.0 kV  ×2,500  WD 9.8 mm", font=f, fill=(190, 210, 230))
        g = _blur_noise(256, rng, 8, 2.0) * 0.6 + _blur_noise(256, rng, 2, 0.6) * 0.4
        e = np.asarray(Image.fromarray((g * 255).astype(np.uint8)).filter(ImageFilter.FIND_EDGES), np.float32) / 255
        im = np.clip(g * 0.7 + e * 1.5, 0, 1)
        tile = Image.fromarray((im * 230).astype(np.uint8)).convert("RGB").resize((w - 16, h - h // 11 - 30))
        img.paste(tile, (8, h // 11 + 6))
        d.rectangle([w - 120, h - 20, w - 40, h - 16], fill=(230, 230, 230))
        d.text((w - 120, h - 15), "10 µm", font=f, fill=(230, 230, 230))
    elif kind == "ms":
        d.text((8, 2), "MASS SPEC  ·  ICP-MS  ·  RUN 0412", font=f, fill=(190, 210, 230))
        for i in range(60):
            x = 10 + i * (w - 20) / 60
            a = rng.random() ** 4
            d.line([(x, h - 22), (x, h - 22 - a * h * 0.65)], fill=(120, 190, 255), width=3)
        d.text((8, h - 18), "m/z  20" + " " * 22 + "120" + " " * 22 + "240", font=f, fill=(120, 140, 160))
    elif kind == "log":
        d.text((8, 2), "SAMPLE LOG  ·  RECEIVING", font=f, fill=(190, 210, 230))
        rows = ["2611-04  IRON ORE     2.4 g  XRF", "2611-03  BASALT       3.1 g  THIN SEC", "2611-02  TIMBER       1.2 g  TGA",
                "2611-01  REGOLITH     4.0 g  SIEVE", "2610-17  COPPER ORE   2.2 g  ICP-MS", "2610-16  SULFUR       0.8 g  XRD"]
        for k, r in enumerate(rows):
            d.text((10, h // 11 + 8 + k * (h - h // 11 - 12) / 6.5), r, font=f, fill=(140, 230, 150) if k == 0 else (150, 170, 180))
    elif kind == "micro":
        d.text((8, 2), "CAM  ·  THIN SECTION  ·  XPL  ×40", font=f, fill=(190, 210, 230))
        g = _blur_noise(256, rng, 12, 3)
        cols = np.stack([0.5 + 0.5 * np.sin(g * 17), 0.5 + 0.5 * np.sin(g * 13 + 2), 0.5 + 0.5 * np.sin(g * 11 + 4)], -1)
        e = np.asarray(Image.fromarray((g * 255).astype(np.uint8)).filter(ImageFilter.FIND_EDGES), np.float32) / 255
        cols = cols * (1 - np.clip(e * 3, 0, 1))[..., None]
        tile = Image.fromarray((cols * 220).astype(np.uint8)).resize((w - 16, h - h // 11 - 14))
        img.paste(tile, (8, h // 11 + 6))
    elif kind == "flow":
        d.text((8, 2), "FACE VELOCITY", font=f, fill=(190, 210, 230))
        d.text((10, h // 3), "0.52 m/s", font=_font(h // 3, "mono"), fill=(130, 240, 140))
        d.text((10, h - h // 4), "SASH OK  ·  ALARM OFF", font=f, fill=(150, 170, 180))
    elif kind == "freezer":
        d.text((10, h // 6), "−80.2 °C", font=_font(h // 2, "mono"), fill=(240, 90, 80))
        d.text((10, h - h // 4), "SET −80  ·  DOOR OK", font=f, fill=(150, 170, 180))
    elif kind == "lattice":
        d.text((8, 2), "MODEL  ·  UNIT CELL  ·  RESONANCE MODES", font=f, fill=(190, 210, 230))
        cx, cy, s = w * 0.5, h * 0.56, h * 0.3
        P = [(cx + (i - j) * s * 0.6, cy + (i + j) * s * 0.3 - k * s * 0.7) for i in (0, 1) for j in (0, 1) for k in (0, 1)]
        for a in range(8):
            for b in range(a + 1, 8):
                if bin(a ^ b).count("1") == 1:
                    d.line([P[a], P[b]], fill=(90, 160, 230), width=2)
        for p in P:
            d.ellipse([p[0] - 7, p[1] - 7, p[0] + 7, p[1] + 7], fill=(240, 200, 100))
    return img


def _whiteboard(w=800, h=400, seed=9):
    """A whiteboard half wiped, in marker: a lattice sketch, a rate law, a
    to-do list; a magnet, a corner of tape."""
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (w, h), (238, 240, 240))
    d = ImageDraw.Draw(img)
    ghost = _blur_noise(256, rng, 16, 8)
    gh = Image.fromarray((ghost * 30).astype(np.uint8)).resize((w, h))
    img = Image.composite(Image.new("RGB", (w, h), (210, 214, 218)), img, gh)
    d = ImageDraw.Draw(img)
    fm = _font(30, "label")
    fs = _font(24, "label")
    blue, black, red = (30, 60, 150), (30, 30, 35), (170, 40, 30)
    d.text((30, 24), "SAMPLES TO RUN", font=fm, fill=black)
    for k, t in enumerate(("2611-04 Fe ore — XRF + ICP", "2611-03 basalt — thin section", "regolith grain size (sieve)",
                           "crystal — Vey point re-check!")):
        d.text((40, 70 + k * 36), "□  " + t, font=fs, fill=blue if k < 3 else red)
    d.text((440, 24), "E = hc / λ", font=fm, fill=black)
    d.text((440, 70), "I(T) ∝ (T − T_v)", font=fm, fill=red)
    cx, cy = 600, 260
    for i in range(3):
        for j in range(3):
            x, y = cx + (i - 1) * 60, cy + (j - 1) * 44
            d.ellipse([x - 9, y - 9, x + 9, y + 9], outline=blue, width=4)
            if i < 2:
                d.line([(x + 9, y), (x + 51, y)], fill=blue, width=3)
            if j < 2:
                d.line([(x, y + 9), (x, y + 35)], fill=blue, width=3)
    d.text((520, 340), "T_v = −38 °C ??", font=fs, fill=red)
    d.rectangle([w - 60, 10, w - 20, 50], fill=(200, 50, 40))
    return img


def _periodic(w=900, h=520):
    """A periodic table poster: the 18 groups, coloured by family."""
    img = Image.new("RGB", (w, h), (236, 236, 232))
    d = ImageDraw.Draw(img)
    syms = ("H,,,,,,,,,,,,,,,,,He;Li,Be,,,,,,,,,,,B,C,N,O,F,Ne;Na,Mg,,,,,,,,,,,Al,Si,P,S,Cl,Ar;"
            "K,Ca,Sc,Ti,V,Cr,Mn,Fe,Co,Ni,Cu,Zn,Ga,Ge,As,Se,Br,Kr;Rb,Sr,Y,Zr,Nb,Mo,Tc,Ru,Rh,Pd,Ag,Cd,In,Sn,Sb,Te,I,Xe;"
            "Cs,Ba,La,Hf,Ta,W,Re,Os,Ir,Pt,Au,Hg,Tl,Pb,Bi,Po,At,Rn;Fr,Ra,Ac,Rf,Db,Sg,Bh,Hs,Mt,Ds,Rg,Cn,Nh,Fl,Mc,Lv,Ts,Og")
    rows = [r.split(",") for r in syms.split(";")]
    cw, ch = (w - 40) / 18, (h - 90) / 7
    f = _font(int(ch * 0.42), "label")
    d.text((20, 10), "PERIODIC TABLE OF THE ELEMENTS", font=_font(30, "label"), fill=(40, 46, 56))
    fam = {"H": (190, 210, 230), "He": (220, 200, 230)}
    for r, row in enumerate(rows):
        for c, s in enumerate(row):
            if not s:
                continue
            if c == 17:
                col = (214, 196, 228)
            elif c >= 12 and r > 0:
                col = (236, 214, 170) if s in ("B", "Si", "Ge", "As", "Sb", "Te") else (200, 226, 196)
            elif c <= 1:
                col = (236, 186, 170) if c == 0 else (240, 214, 170)
            else:
                col = (196, 214, 236)
            col = fam.get(s, col)
            x0, y0 = 20 + c * cw, 60 + r * ch
            d.rectangle([x0 + 1, y0 + 1, x0 + cw - 2, y0 + ch - 2], fill=col, outline=(120, 120, 120))
            tb = d.textbbox((0, 0), s, font=f)
            d.text((x0 + (cw - (tb[2] - tb[0])) / 2, y0 + (ch - (tb[3] - tb[1])) / 2 - tb[1]), s, font=f, fill=(30, 30, 34))
    return img


def signs():
    P = base_tex.plate
    WHT, INK, BLU = (232, 232, 226), (24, 22, 20), (34, 60, 110)
    GRN, YEL, RD = (24, 110, 60), (206, 164, 40), (160, 34, 26)
    SL, FG = base_tex.SLATE_BG, base_tex.PLATE_FG
    items = [
        ("receiving", P("SAMPLE RECEIVING", 420, 72, SL, FG, seed=201)),
        ("hood1", P("FUME HOOD 1", 260, 60, WHT, BLU, border=BLU, seed=202)),
        ("hood2", P("FUME HOOD 2", 260, 60, WHT, BLU, border=BLU, seed=203)),
        ("hood3", P("FUME HOOD 3", 260, 60, WHT, BLU, border=BLU, seed=204)),
        ("shower", P("EMERGENCY SHOWER", 380, 80, GRN, WHT, seed=205)),
        ("eyewash", P("EYE WASH", 260, 80, GRN, WHT, seed=206)),
        ("instr", P("INSTRUMENT ROOM", 380, 72, SL, FG, seed=207)),
        ("clean", P("CLEAN AREA · COAT & GLOVES BEYOND THIS POINT", 620, 72, WHT, BLU, border=BLU, seed=208)),
        ("gloves", P("GLOVES REQUIRED", 320, 72, BLU, WHT, seed=209)),
        ("flam", P("FLAMMABLE — KEEP FIRE AWAY", 400, 80, YEL, RD, border=RD, seed=210)),
        ("glovebox", P("GLOVE BOX · ARGON · O₂ < 1 ppm", 440, 64, WHT, INK, border=INK, seed=211)),
        ("sem", P("SEM-2", 180, 60, SL, FG, seed=212)),
        ("xrf", P("XRF ANALYSER", 280, 60, SL, FG, seed=213)),
        ("mspec", P("ICP-MS", 200, 60, SL, FG, seed=214)),
        ("minus80", P("−80 °C · SAMPLE ARCHIVE", 380, 64, WHT, INK, border=INK, seed=215)),
        ("exit", P("EXIT", 180, 70, GRN, WHT, seed=216)),
        ("fire", P("FIRE EXTINGUISHER", 300, 60, RD, WHT, seed=217)),
        ("lab", P("RESEARCH LAB  ·  MATERIALS & PLANETARY SCIENCE", 760, 80, SL, FG, seed=218)),
        ("pneu", P("PNEUMATIC TRANSFER — CAPSULES ONLY", 520, 60, YEL, INK, border=INK, seed=219)),
        ("keep", P("KEEP CLEAR", 220, 60, YEL, INK, border=INK, seed=220)),
        ("hazard", base_tex.hazard(256, 48, 221)),
        ("emblem", base_tex.emblem(256, seed=222)),
        ("label_w", P("", 64, 24, (236, 236, 232), INK, seed=223)),
        ("s_xrf", _screen("xrf", 512, 300, 301)),
        ("s_sem", _screen("sem", 512, 320, 302)),
        ("s_sem2", _screen("micro", 480, 300, 303)),
        ("s_ms", _screen("ms", 480, 280, 304)),
        ("s_log", _screen("log", 420, 260, 305)),
        ("s_micro", _screen("micro", 320, 200, 306)),
        ("s_flow", _screen("flow", 160, 100, 307)),
        ("s_freezer", _screen("freezer", 200, 100, 308)),
        ("s_lattice", _screen("lattice", 480, 300, 309)),
        ("whiteboard", _whiteboard()),
        ("periodic", _periodic()),
    ]
    img = Image.new("RGB", (ATLAS_W, ATLAS_H), (128, 128, 128))
    _pack(img, items)
    img.save(os.path.join(TEXDIR, "signs.png"), optimize=True)


def aspect(reg):
    w, h = PIX[reg]
    return h / w


# ═════════════════════════════════════════════════════════════════════════════
# geometry helpers
# ═════════════════════════════════════════════════════════════════════════════

class Lab:
    """The interior's meshes by family, and its walkable boxes."""

    def __init__(self):
        self.room = CModel(301)      # walls, floor, ceiling
        self.furn = CModel(302)      # benches, cabinets, instruments
        self.glass = CModel(303)     # every pane (one transmissive pass)
        self.sh = Shell()
        for m in (self.room, self.furn, self.glass):
            m.ground = False


def Bx(m, mat, col, x0, x1, y0, y1, z0, z1, sh=None, bevel=0.0):
    x0, x1 = sorted((x0, x1)); y0, y1 = sorted((y0, y1)); z0, z1 = sorted((z0, z1))
    m.color = col
    box(m, mat, ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (x1 - x0, y1 - y0, z1 - z0), uv_m=1.0, bevel=bevel)
    if sh is not None:
        sh.add(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (x1 - x0, y1 - y0, z1 - z0))


def solid(sh, x0, x1, y0, y1, z0, z1):
    """A collider box only (nothing drawn): the solid volume of something
    drawn in finer pieces (a hood, a shelf unit, a stool, a coat rail), so the
    crew can't walk through it and the talk camera's casts see it."""
    x0, x1 = sorted((x0, x1)); y0, y1 = sorted((y0, y1)); z0, z1 = sorted((z0, z1))
    sh.add(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (x1 - x0, y1 - y0, z1 - z0))


def Tb(m, mat, col, p0, p1, r, segs=12, r1=None):
    m.color = col
    tube(m, mat, np.asarray(p0, float), np.asarray(p1, float), r, segs=segs, r1=r1, uv_m=1.0)


def plate(m, reg, center, right, up, width, depth=0.012, back=CASE, mat="LabSign"):
    h = width * aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float) + o * depth / 2
    cuboid(m, c, right, up, width, h, depth, faces={"front": (mat, (1, 1, 1), reg)}, col=back, mat="LabWall")
    return h


def screen(m, reg, center, right, up, width, bezel=0.02, depth=0.03):
    """A monitor: a dark bezel box whose face is the region, unlit."""
    h = width * aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float)
    cuboid(m, c - o * depth / 2, right, up, width + 2 * bezel, h + 2 * bezel, depth, col=DARKP, mat="LabResin")
    cuboid(m, c + o * 0.0015, right, up, width, h, 0.003, faces={"front": ("LabScreen", (1, 1, 1), reg)}, col=DARKP,
           mat="LabResin")
    return h


def glass_cyl(m, c, r, h, segs=18):
    p0 = np.asarray(c, float)
    Tb(m, "LabGlass", (1, 1, 1), p0, p0 + np.array([0, h, 0]), r, segs=segs)


# ═════════════════════════════════════════════════════════════════════════════
# the room
# ═════════════════════════════════════════════════════════════════════════════

def room(K):
    m, sh = K.room, K.sh
    # THE FLOOR: sheet vinyl in 0.6 m quads, so the wear can be coloured in:
    # darker in the aisles' traffic, a grey line along the bench fronts
    xs = np.arange(-XI, XI + 1e-6, 0.3); xs[-1] = XI
    zs = np.arange(-ZI, ZI + 1e-6, 0.3); zs[-1] = ZI
    rng = np.random.default_rng(5)

    def wear_at(x, z):
        a = 0.0
        # the aisles people walk: door → receiving, door → benches
        for (x0, z0, x1, z1, r) in ((8.0, 6.0, 8.0, 3.0, 0.7), (6.2, 5.0, -8.0, 3.2, 0.9), (-8.0, 3.2, -8.0, 1.2, 0.8),
                                    (0.0, 2.2, -9.0, -4.8, 0.9), (3.6, 1.6, 3.6, -2.0, 0.6)):
            dx, dz = x1 - x0, z1 - z0
            t = max(0.0, min(1.0, ((x - x0) * dx + (z - z0) * dz) / max(dx * dx + dz * dz, 1e-6)))
            dd = math.hypot(x - (x0 + dx * t), z - (z0 + dz * t))
            a += math.exp(-(dd / r) ** 2) * 0.05
        return a + rng.uniform(-0.006, 0.006)
    m.color = FLOOR
    P, N, UV, I, C = [], [], [], [], []
    for i in range(len(xs) - 1):
        for j in range(len(zs) - 1):
            x0, x1, z0, z1 = xs[i], xs[i + 1], zs[j], zs[j + 1]
            k = len(P)
            for (x, z) in ((x0, z0), (x1, z0), (x1, z1), (x0, z1)):
                P.append((x, FT, z)); N.append((0, 1, 0)); UV.append((x * 0.5, z * 0.5))
                C.append(np.array(FLOOR) * (1 - wear_at(x, z)))
            I += [(k, k + 2, k + 1), (k, k + 3, k + 2)]
    m.add("LabFloor", P, N, UV, I)
    m.cols["LabFloor"][-1] = np.array(C)
    sh.add((0, FT / 2, 0), (2 * XI, FT, 2 * ZI))
    # the ceiling is solid too: the shell's roof slab is 1.85 m above the
    # tiles, and a 5.2 m/s jump on a light world lifts the feet 3-4 m, so
    # without it the crew jumped up through the tiles into the void
    # (playtest 2026-11-04). 0.3 m thick, from the tiles' face up.
    sh.add((0, CY + 0.15, 0), (2 * XI, 0.3, 2 * ZI))
    # THE WALL LINING: panels 1.2 m wide, a 4 mm shadow seam between them; a
    # brushed coved skirting; holes for the doorway and (left whole) behind
    # the vestibule's and instrument room's own panels
    dx0, dx1, dh = L["door_x0"], L["door_x1"], L["door_h"]

    def lining(axis, fixed, a0, a1, normal, gaps=()):
        """Panels along `axis` ("x" or "z") at the fixed coordinate, a0..a1,
        floor to ceiling, skipping the (a, b, top) gaps."""
        edges = list(np.arange(a0, a1, 1.2)) + [a1]
        for a, b in zip(edges[:-1], edges[1:]):
            for (y0, y1) in ((FT + 0.12, CY),):
                spans = [(a + 0.002, b - 0.002)]
                for (g0, g1, gt) in gaps:
                    nsp = []
                    for (s0, s1) in spans:
                        if s1 <= g0 or s0 >= g1:
                            nsp.append((s0, s1))
                        else:
                            if s0 < g0:
                                nsp.append((s0, g0))
                            if s1 > g1:
                                nsp.append((g1, s1))
                            # over the gap, the header
                            Hs, He = max(s0, g0), min(s1, g1)
                            _panel(axis, fixed, Hs, He, gt, y1, normal)
                    spans = nsp
                for (s0, s1) in spans:
                    _panel(axis, fixed, s0, s1, y0, y1, normal)
            # the seam behind the panels
            _seam(axis, fixed, b, normal)
        # skirting along the run (not across a gap)
        segs = [(a0, a1)]
        for (g0, g1, _) in gaps:
            ns = []
            for (s0, s1) in segs:
                if s1 <= g0 or s0 >= g1:
                    ns.append((s0, s1))
                else:
                    if s0 < g0:
                        ns.append((s0, g0))
                    if s1 > g1:
                        ns.append((g1, s1))
            segs = ns
        for (s0, s1) in segs:
            if axis == "x":
                Bx(m, "LabSteel", STEEL, s0, s1, FT, FT + 0.12, fixed, fixed + normal * 0.018)
            else:
                Bx(m, "LabSteel", STEEL, fixed, fixed + normal * 0.018, FT, FT + 0.12, max(s0, -ZI + 0.019), min(s1, ZI - 0.019))

    def _panel(axis, fixed, s0, s1, y0, y1, normal):
        if s1 - s0 < 0.01:
            return
        if axis == "x":
            Bx(m, "LabWall", WALL, s0, s1, y0, y1, fixed, fixed + normal * 0.012)
        else:
            Bx(m, "LabWall", WALL, fixed, fixed + normal * 0.012, y0, y1, s0, s1)

    def _seam(axis, fixed, at, normal):
        if axis == "x":
            Bx(m, "LabWall", WALL_SEAM, at - 0.002, at + 0.002, FT + 0.12, CY, fixed, fixed + normal * 0.004)
        else:
            Bx(m, "LabWall", WALL_SEAM, fixed, fixed + normal * 0.004, FT + 0.12, CY, at - 0.002, at + 0.002)
    lining("x", -ZI, -XI, XI, 1)                          # north
    lining("x", ZI, -XI, XI, -1, gaps=[(dx0, dx1, dh)])   # south, the doorway
    lining("z", -XI, -ZI + 0.013, ZI - 0.013, 1)          # west
    lining("z", XI, -ZI + 0.013, ZI - 0.013, -1)          # east
    # the doorway's reveal: steel lining the cut through the wall
    for xx in (dx0, dx1):
        Bx(m, "LabSteel", STEEL, xx - 0.015, xx + 0.015, FT, dh, ZI - 0.02, ZI + L["t"] + 0.03)
    Bx(m, "LabSteel", STEEL, dx0 + 0.016, dx1 - 0.016, dh - 0.015, dh + 0.015, ZI - 0.02, ZI + L["t"] + 0.03)

    # THE CEILING: 600 mm tiles in a white T-bar grid; flush LED panels
    m.color = WALL
    ceil_lamps = []
    gx = np.arange(-XI, XI + 1e-6, 0.6); gx[-1] = XI
    gz = np.arange(-ZI, ZI + 1e-6, 0.6); gz[-1] = ZI
    lamp_cells = set()
    # fewer panels, staggered row to row, so the ceiling is not a lit grid
    for jj, j in enumerate(range(2, len(gz) - 2, 4)):
        for i in range(2 + (3 if jj % 2 else 0), len(gx) - 2, 6):
            lamp_cells.add((i, j)); lamp_cells.add((i + 1, j))
            ceil_lamps.append(((gx[i] + gx[i + 2]) / 2, (gz[j] + gz[j + 1]) / 2))
    for i in range(len(gx) - 1):
        for j in range(len(gz) - 1):
            x0, x1, z0, z1 = gx[i], gx[i + 1], gz[j], gz[j + 1]
            if (i, j) in lamp_cells:
                m.color = LAMP
                m.add("LabLamp", [(x0, CY, z0), (x1, CY, z0), (x1, CY, z1), (x0, CY, z1)], [(0, -1, 0)] * 4,
                      [(0, 0), (1, 0), (1, 1), (0, 1)], [(0, 1, 2), (0, 2, 3)])
            else:
                m.color = (0.92, 0.925, 0.92)
                m.add("LabWall", [(x0, CY, z0), (x1, CY, z0), (x1, CY, z1), (x0, CY, z1)], [(0, -1, 0)] * 4,
                      [(x0, z0), (x1, z0), (x1, z1), (x0, z1)], [(0, 1, 2), (0, 2, 3)])
    for x in gx[1:-1]:
        Bx(m, "LabWall", (0.88, 0.885, 0.88), x - 0.010, x + 0.010, CY - 0.018, CY - 0.001, -ZI + 0.014, ZI - 0.014)
    for z in gz[1:-1]:
        for a, b in zip(gx[:-1], gx[1:]):
            Bx(m, "LabWall", (0.88, 0.885, 0.88), max(a + 0.010, -XI + 0.014), min(b - 0.010, XI - 0.014), CY - 0.016, CY - 0.002,
               z - 0.012, z + 0.012)
    # diffusers and sprinklers, a smoke detector or two
    for (x, z) in ((-6.9, -3.3), (-0.9, 1.5), (5.1, -4.5), (-6.9, 4.5), (2.7, 4.5), (8.7, 0.3)):
        Bx(m, "LabWall", (0.86, 0.865, 0.86), x - 0.28, x + 0.28, CY - 0.04, CY - 0.003, z - 0.28, z + 0.28)
        for k in range(1, 4):
            Bx(m, "LabResin", (0.4, 0.4, 0.42), x - 0.28 + k * 0.14 - 0.006, x - 0.28 + k * 0.14 + 0.006, CY - 0.045,
               CY - 0.04, z - 0.25, z + 0.25)
    for (x, z) in ((-8.4, -1.2), (-3.0, 3.0), (2.4, -0.6), (6.0, 3.6), (-4.2, -5.4), (8.0, -3.0), (-9.0, 5.6), (8.4, 5.2)):
        Tb(m, "LabSteel", STEEL, (x, CY - 0.003, z), (x, CY - 0.06, z), 0.012, segs=8)
        Tb(m, "LabSteel", (0.60, 0.15, 0.10), (x, CY - 0.06, z), (x, CY - 0.075, z), 0.022, segs=8)
    for (x, z) in ((-3.0, -3.0), (5.6, 1.2)):
        Tb(m, "LabWall", (0.95, 0.95, 0.94), (x, CY - 0.002, z), (x, CY - 0.05, z), 0.06, segs=16)
    # cable trays along the north and south walls under the ceiling
    for zz, n in ((-ZI + 0.35, 1), (ZI - 0.35, -1)):
        y = CY - 0.32
        Bx(m, "LabSteel", STEEL_D, -XI + 0.3, XI - 0.3, y, y + 0.012, zz - 0.15, zz + 0.15)
        for s in (-1, 1):
            Bx(m, "LabSteel", STEEL_D, -XI + 0.31, XI - 0.31, y - 0.003, y + 0.06, zz + s * 0.15 - 0.004, zz + s * 0.15 + 0.004)
        for k in range(5):
            Tb(m, "LabResin", ((0.12, 0.12, 0.13), (0.55, 0.30, 0.06), (0.08, 0.20, 0.45), (0.12, 0.12, 0.13),
                               (0.45, 0.45, 0.47))[k], (-XI + 0.3, y + 0.025, zz - 0.11 + k * 0.05),
               (XI - 0.3, y + 0.025, zz - 0.11 + k * 0.05), 0.011, segs=6)
        for x in np.arange(-XI + 1.0, XI - 0.5, 1.8):
            Tb(m, "LabSteel", STEEL_D, (x, y + 0.013, zz + 0.155), (x, CY, zz + 0.155), 0.006, segs=6)
    return ceil_lamps


def partitions(K):
    """Glass walls in anodised frames: the vestibule and the instrument room."""
    m, g, sh = K.furn, K.glass, K.sh

    def glazed(axis, fixed, a0, a1, gaps=()):
        # frame: base rail, head rail, posts every 1.2 m; panes between
        spans = [(a0, a1)]
        for (g0, g1) in gaps:
            ns = []
            for (s0, s1) in spans:
                if s1 <= g0 or s0 >= g1:
                    ns.append((s0, s1))
                else:
                    if s0 < g0:
                        ns.append((s0, g0))
                    if s1 > g1:
                        ns.append((g1, s1))
            spans = ns
        for (s0, s1) in spans:
            n = max(1, int(round((s1 - s0) / 1.2)))
            ed = np.linspace(s0, s1, n + 1)
            for a, b in zip(ed[:-1], ed[1:]):
                if axis == "x":
                    g.color = (1, 1, 1)
                    box(g, "LabGlass", ((a + b) / 2, (FT + 0.12 + CY - 0.06) / 2, fixed), (b - a - 0.05, CY - 0.06 - FT - 0.12, 0.012))
                else:
                    g.color = (1, 1, 1)
                    box(g, "LabGlass", (fixed, (FT + 0.12 + CY - 0.06) / 2, (a + b) / 2), (0.012, CY - 0.06 - FT - 0.12, b - a - 0.05))
            for a in ed:
                if axis == "x":
                    Bx(m, "LabSteel", ALU, a - 0.025, a + 0.025, FT, CY, fixed - 0.04, fixed + 0.04)
                else:
                    Bx(m, "LabSteel", ALU, fixed - 0.04, fixed + 0.04, FT, CY, a - 0.025, a + 0.025)
            if axis == "x":
                Bx(m, "LabSteel", ALU, s0 + 0.025, s1 - 0.025, FT, FT + 0.12, fixed - 0.035, fixed + 0.035)
                Bx(m, "LabSteel", ALU, s0 + 0.025, s1 - 0.025, CY - 0.06, CY - 0.002, fixed - 0.035, fixed + 0.035)
                sh.add(((s0 + s1) / 2, CY / 2, fixed), (s1 - s0, CY, 0.08))
            else:
                Bx(m, "LabSteel", ALU, fixed - 0.035, fixed + 0.035, FT, FT + 0.12, s0 + 0.025, s1 - 0.025)
                Bx(m, "LabSteel", ALU, fixed - 0.035, fixed + 0.035, CY - 0.06, CY - 0.002, s0 + 0.025, s1 - 0.025)
                sh.add((fixed, CY / 2, (s0 + s1) / 2), (0.08, CY, s1 - s0))
        for (g0, g1) in gaps:   # a head over each doorway, to the ceiling
            # (solid: the glass over a door stops a jump as the panes beside it do)
            if axis == "x":
                sh.add(((g0 + g1) / 2, (2.3 + CY) / 2, fixed), (g1 - g0, CY - 2.3, 0.08))
            else:
                sh.add((fixed, (2.3 + CY) / 2, (g0 + g1) / 2), (0.08, CY - 2.3, g1 - g0))
            if axis == "x":
                Bx(m, "LabSteel", ALU, g0, g1, 2.3, 2.36, fixed - 0.05, fixed + 0.05)
                g.color = (1, 1, 1)
                box(g, "LabGlass", ((g0 + g1) / 2, (2.36 + CY - 0.06) / 2, fixed), (g1 - g0 - 0.04, CY - 0.06 - 2.36, 0.012))
                Bx(m, "LabSteel", ALU, g0 + 0.02, g1 - 0.02, CY - 0.06, CY - 0.002, fixed - 0.035, fixed + 0.035)
            else:
                Bx(m, "LabSteel", ALU, fixed - 0.05, fixed + 0.05, 2.3, 2.36, g0, g1)
                g.color = (1, 1, 1)
                box(g, "LabGlass", (fixed, (2.36 + CY - 0.06) / 2, (g0 + g1) / 2), (0.012, CY - 0.06 - 2.36, g1 - g0 - 0.04))
                Bx(m, "LabSteel", ALU, fixed - 0.035, fixed + 0.035, CY - 0.06, CY - 0.002, g0 + 0.02, g1 - 0.02)
    # the vestibule: along z = VZ (x VX..XI), and x = VX (z VZ..ZI) with its door
    glazed("x", VZ, VX, XI - 0.04)
    glazed("z", VX, VZ + 0.04, ZI - 0.06, gaps=[INNER_DOOR])
    # the instrument room: along z = IZ with its door, and x = IX
    glazed("x", IZ, IX + 0.04, XI - 0.04, gaps=[INSTR_DOOR])
    glazed("z", IX, -ZI + 0.04, IZ - 0.04)
    # frosted manifestation bands at eye level (so nobody walks into a pane)
    for (axis, fixed, a0, a1) in (("x", VZ, VX, XI), ("z", VX, VZ, ZI), ("x", IZ, IX, XI), ("z", IX, -ZI, IZ)):
        for (y0, y1) in ((1.38, 1.44), (0.98, 1.0)):
            if axis == "x":
                Bx(m, "LabWall", (0.80, 0.82, 0.83), a0 + 0.05, a1 - 0.05, y0, y1, fixed + 0.0065, fixed + 0.0085)
            else:
                Bx(m, "LabWall", (0.80, 0.82, 0.83), fixed + 0.0065, fixed + 0.0085, y0, y1, a0 + 0.05, a1 - 0.05)
    plate(m, "l_instr", (5.5, 2.6, IZ + 0.05), (1, 0, 0), (0, 1, 0), 1.2, depth=0.01)
    plate(m, "l_clean", ((VX + XI) / 2, 2.6, VZ - 0.05), (-1, 0, 0), (0, 1, 0), 2.0, depth=0.01)
    plate(m, "l_gloves", (VX - 0.05, 2.6, 6.1), (0, 0, -1), (0, 1, 0), 0.8, depth=0.01)


# ═════════════════════════════════════════════════════════════════════════════
# furniture
# ═════════════════════════════════════════════════════════════════════════════

def casework(m, sh, x0, x1, z0, z1, top_y=0.90, resin=True, front=1, doors=True):
    """Base cabinets with a worktop: a recessed plinth, door and drawer fronts
    with their gaps, stainless handles, a black resin (or steel) top."""
    Bx(m, "LabResin", DARKP, x0 + 0.03, x1 - 0.03, FT, FT + 0.10, z0 + (0.06 if front < 0 else 0.03),
       z1 - (0.06 if front > 0 else 0.03))
    Bx(m, "LabWall", CASE, x0, x1, FT + 0.10, top_y - 0.035, z0, z1, sh=sh)
    zf = z1 if front > 0 else z0
    if doors:
        n = max(1, int(round((x1 - x0) / 0.6)))
        ed = np.linspace(x0, x1, n + 1)
        for a, b in zip(ed[:-1], ed[1:]):
            Bx(m, "LabWall", CASE_SH, a + 0.004, b - 0.004, FT + 0.12, top_y - 0.05, zf, zf + front * 0.018)
            Bx(m, "LabWall", CASE, a + 0.006, b - 0.006, top_y - 0.22, top_y - 0.052, zf + front * 0.018, zf + front * 0.02)
            Bx(m, "LabWall", CASE, a + 0.006, b - 0.006, FT + 0.122, top_y - 0.226, zf + front * 0.018, zf + front * 0.02)
            hx = (a + b) / 2
            Tb(m, "LabSteel", STEEL, (hx - 0.07, top_y - 0.135, zf + front * 0.045), (hx + 0.07, top_y - 0.135, zf + front * 0.045),
               0.006, segs=6)
            for xx in (hx - 0.06, hx + 0.06):
                Tb(m, "LabSteel", STEEL, (xx, top_y - 0.135, zf + front * 0.02), (xx, top_y - 0.135, zf + front * 0.045), 0.005, segs=6)
    if resin is None:
        return
    if resin:
        Bx(m, "LabResin", RESIN, x0 - 0.02, x1 + 0.02, top_y - 0.035, top_y, z0 - (0.02 if front < 0 else 0.0),
           z1 + (0.02 if front > 0 else 0.0))
    else:
        Bx(m, "LabSteel", STEEL, x0 - 0.02, x1 + 0.02, top_y - 0.035, top_y, z0 - 0.02, z1 + 0.02)


def microscope(m, x, y, z, face=(0, 0, 1)):
    """A trinocular microscope: base, pillar, stage, nosepiece, head, eyepieces,
    a camera on the third port."""
    fx, fz = face[0], face[2]
    def P(a, h, b):  # a along the face, b across
        return (x + fx * a - fz * b, y + h, z + fz * a + fx * b)
    Bx(m, "LabWall", (0.92, 0.92, 0.90), x - 0.13, x + 0.13, y, y + 0.05, z - 0.13, z + 0.13, bevel=0.02)
    Tb(m, "LabWall", (0.92, 0.92, 0.90), P(-0.08, 0.05, 0), P(-0.08, 0.36, 0), 0.04, segs=12)
    Tb(m, "LabResin", DARKP, P(0.0, 0.17, 0), P(0.0, 0.185, 0), 0.08, segs=16)
    Tb(m, "LabSteel", STEEL_D, P(0.0, 0.215, 0), P(0.0, 0.27, 0), 0.035, segs=12)
    for k in range(4):
        a = k * math.pi / 2 + 0.4
        Tb(m, "LabSteel", STEEL, P(0.035 * math.cos(a), 0.215, 0.035 * math.sin(a)), P(0.05 * math.cos(a), 0.19, 0.05 * math.sin(a)),
           0.008, segs=8)
    Bx(m, "LabWall", (0.92, 0.92, 0.90), x - 0.06, x + 0.06, y + 0.30, y + 0.39, z - 0.06, z + 0.06, bevel=0.015)
    for s in (-1, 1):
        Tb(m, "LabResin", DARKP, P(0.0, 0.36, 0.025 * s), P(0.09, 0.45, 0.032 * s), 0.013, segs=10)
    Tb(m, "LabResin", DARKP, P(-0.03, 0.39, 0), P(-0.03, 0.50, 0), 0.02, segs=10)
    Bx(m, "LabResin", DARKP, P(-0.03, 0.5, 0)[0] - 0.03, P(-0.03, 0.5, 0)[0] + 0.03, y + 0.50, y + 0.56,
       P(-0.03, 0.5, 0)[2] - 0.03, P(-0.03, 0.5, 0)[2] + 0.03)
    for s in (-1, 1):
        Tb(m, "LabResin", DARKP, P(-0.06, 0.08, 0.09 * s), P(-0.06, 0.08, 0.12 * s), 0.022, segs=12)


def glassware(K, x, y, z, seed):
    """A few pieces of glassware on a bench: beakers, a flask, a bottle with a
    coloured fill (tinted vertex colour on the glass's inside)."""
    rng = np.random.default_rng(seed)
    g, m = K.glass, K.furn
    nk = int(rng.integers(2, 5))
    for k in range(nk):
        r = rng.uniform(0.025, 0.045)
        h = rng.uniform(0.07, 0.14)
        px, pz = x - 0.25 + k * 0.13, z + rng.uniform(-0.06, 0.06)
        glass_cyl(g, (px, y, pz), r, h, segs=16)
        if rng.random() < 0.7:
            fill = rng.uniform(0.3, 0.7) * h
            col = [(0.70, 0.75, 0.80), (0.75, 0.55, 0.15), (0.20, 0.45, 0.70), (0.80, 0.82, 0.70)][int(rng.integers(0, 4))]
            Tb(m, "LabResin", col, (px, y + 0.003, pz), (px, y + fill, pz), r * 0.9, segs=14)


def hoods(K):
    """Three fume hoods along the north wall, sashes part-open, lit inside."""
    m, g, sh = K.furn, K.glass, K.sh
    z0 = -ZI
    D = 0.92
    zf = z0 + D
    for i, xc in enumerate((-9.35, -7.5, -5.65)):
        x0, x1 = xc - 0.9, xc + 0.9
        casework(m, sh, x0, x1, z0, zf, top_y=0.90, resin=True)
        # the hood's body: cheeks, top cowl, back baffle
        for xx in (x0, x1 - 0.06):
            Bx(m, "LabWall", CASE, xx, xx + 0.06, 0.90, 2.40, z0, zf, sh=sh)
        Bx(m, "LabWall", CASE, x0 + 0.004, x1 - 0.004, 2.10, 2.55, z0, zf + 0.004)
        solid(sh, x0, x1, 0.90, 2.55, z0, zf)
        solid(sh, xc - 0.18, xc + 0.18, 2.55, CY, z0 + 0.27, z0 + 0.63)
        Bx(m, "LabWall", CASE_SH, x0 + 0.06, x1 - 0.06, 0.90, 2.10, z0, z0 + 0.06)
        for k in range(3):
            Bx(m, "LabResin", (0.25, 0.26, 0.27), x0 + 0.1, x1 - 0.1, 1.05 + k * 0.35, 1.07 + k * 0.35, z0 + 0.06, z0 + 0.065)
        # the work surface inside, a lamp strip under the cowl
        Bx(m, "LabLamp", LAMP_TASK, x0 + 0.12, x1 - 0.12, 2.08, 2.095, z0 + 0.25, z0 + 0.45)
        # the sash: glass in a frame, raised to 1.45
        sy0, sy1 = 1.45, 2.12
        Bx(m, "LabSteel", STEEL, x0 + 0.06, x1 - 0.06, sy0 - 0.04, sy0, zf - 0.03, zf + 0.0)
        Bx(m, "LabSteel", STEEL, x0 + 0.06, x1 - 0.06, sy1, sy1 + 0.03, zf - 0.03, zf + 0.0)
        g.color = (1, 1, 1)
        box(g, "LabGlass", (xc, (sy0 + sy1) / 2, zf - 0.015), (x1 - x0 - 0.14, sy1 - sy0, 0.008))
        Tb(m, "LabSteel", STEEL, (x0 + 0.25, sy0 - 0.06, zf + 0.02), (x1 - 0.25, sy0 - 0.06, zf + 0.02), 0.011, segs=8)
        # the airflow monitor on the right cheek, the label over the sash
        screen(m, "l_s_flow", (x1 - 0.03, 1.75, zf + 0.022), (1, 0, 0), (0, 1, 0), 0.1, bezel=0.008, depth=0.02)
        plate(m, f"l_hood{i + 1}", (xc, 2.35, zf), (1, 0, 0), (0, 1, 0), 0.7, depth=0.008)
        # the exhaust duct up into the ceiling
        Tb(m, "LabSteel", STEEL, (xc, 2.55, z0 + 0.45), (xc, CY, z0 + 0.45), 0.16, segs=18)
        Tb(m, "LabSteel", STEEL_D, (xc, 2.55, z0 + 0.45), (xc, 2.6, z0 + 0.45), 0.18, segs=18)
        # inside: a ring stand, a flask, bottles
        Tb(m, "LabSteel", STEEL_D, (xc - 0.4, 0.915, z0 + 0.4), (xc - 0.4, 1.45, z0 + 0.4), 0.008, segs=6)
        Bx(m, "LabResin", DARKP, xc - 0.5, xc - 0.3, 0.90, 0.915, z0 + 0.3, z0 + 0.5)
        glassware(K, xc + 0.1, 0.90, z0 + 0.45, 30 + i)
    # the hood bank's service panel and the duct manifold above the ceiling line


def safety_station(K):
    m, sh = K.furn, K.sh
    x, z = -4.15, -ZI + 0.45
    # the emergency shower: a pipe down from the ceiling, a head, a pull rod
    Tb(m, "LabSteel", SAFETY_G, (x, CY, z - 0.3), (x, 2.35, z - 0.3), 0.024, segs=10)
    Tb(m, "LabSteel", SAFETY_G, (x, 2.35, z - 0.3), (x, 2.35, z + 0.15), 0.024, segs=10)
    Tb(m, "LabSteel", SAFETY_G, (x, 2.33, z + 0.15), (x, 2.26, z + 0.15), 0.13, segs=18, r1=0.15)
    Tb(m, "LabSteel", STEEL, (x + 0.12, 2.3, z - 0.1), (x + 0.12, 1.65, z - 0.1), 0.006, segs=6)
    Bx(m, "LabSteel", SAFETY_G, x + 0.08, x + 0.16, 1.55, 1.65, z - 0.12, z - 0.08)
    # the eyewash: a bowl on a pedestal, two nozzles, a push paddle
    xe = x + 0.75
    solid(sh, xe - 0.2, xe + 0.2, FT, 1.08, z - 0.42, z + 0.06)
    Tb(m, "LabSteel", SAFETY_G, (xe, FT, z - 0.25), (xe, 0.95, z - 0.25), 0.04, segs=12)
    m.color = SAFETY_G
    sub = CModel(); sub.ground = False; sub.color = SAFETY_G
    lathe(sub, "LabSteel", [(0.03, 0.0), (0.16, 0.06), (0.2, 0.12), (0.19, 0.125), (0.04, 0.03)], segs=20)
    m.merge(sub, None, (xe, 0.95, z - 0.2))
    for s in (-1, 1):
        Tb(m, "LabSteel", STEEL, (xe + s * 0.05, 1.0, z - 0.2), (xe + s * 0.05, 1.04, z - 0.2), 0.012, segs=8)
    Bx(m, "LabSteel", SAFETY_G, xe - 0.08, xe + 0.08, 1.0, 1.02, z + 0.0, z + 0.06)
    plate(m, "l_shower", (x + 0.2, 2.6, -ZI + 0.014), (1, 0, 0), (0, 1, 0), 0.9, depth=0.008)
    plate(m, "l_eyewash", (xe, 1.6, -ZI + 0.014), (1, 0, 0), (0, 1, 0), 0.5, depth=0.008)
    # keep-clear hatching on the floor round the shower
    for (a, b, c, d) in ((x - 0.55, x + 0.55, z + 0.70, z + 0.75), (x - 0.55, x - 0.50, z - 0.42, z + 0.70),
                         (x + 0.50, x + 0.55, z - 0.42, z + 0.70)):
        Bx(m, "LabWall", SAFETY_G, a, b, FT, FT + 0.002, c, d)


def sink_bench(K):
    m, g, sh = K.furn, K.glass, K.sh
    x0, x1, z0 = -3.4, 1.3, -ZI
    casework(m, sh, x0, x1, z0, z0 + 0.75, resin=True)
    # a stainless sink, a gooseneck tap, a drying rack with glassware
    Bx(m, "LabSteel", STEEL, -1.6, -0.9, 0.86, 0.902, z0 + 0.18, z0 + 0.6)
    Bx(m, "LabSteel", STEEL_D, -1.55, -0.95, 0.80, 0.86, z0 + 0.23, z0 + 0.55)
    Tb(m, "LabSteel", STEEL, (-1.25, 0.90, z0 + 0.1), (-1.25, 1.25, z0 + 0.1), 0.012, segs=8)
    Tb(m, "LabSteel", STEEL, (-1.25, 1.25, z0 + 0.1), (-1.25, 1.18, z0 + 0.32), 0.012, segs=8)
    Bx(m, "LabSteel", STEEL_D, -0.7, 0.0, 1.0, 1.02, z0 + 0.02, z0 + 0.35)
    for k in range(8):
        Tb(m, "LabSteel", STEEL_D, (-0.66 + k * 0.09, 1.02, z0 + 0.18), (-0.66 + k * 0.09, 1.25, z0 + 0.18), 0.004, segs=5)
        if k % 2 == 0:
            glass_cyl(g, (-0.66 + k * 0.09, 1.05, z0 + 0.22), 0.03, 0.14, segs=12)
    # wall shelves of reagent bottles over the bench, the periodic table
    solid(sh, x0 + 0.1, -1.8, 1.55, 2.2, z0, z0 + 0.3)
    for y in (1.55, 1.95):
        Bx(m, "LabSteel", STEEL, x0 + 0.1, -1.8, y, y + 0.02, z0, z0 + 0.3)
        rng = np.random.default_rng(int(y * 100))
        xx = x0 + 0.18
        while xx < -1.95:
            r = rng.uniform(0.03, 0.045)
            h = rng.uniform(0.12, 0.22)
            col = [(0.32, 0.18, 0.06), (0.85, 0.85, 0.82), (0.10, 0.22, 0.42), (0.28, 0.10, 0.06)][int(rng.integers(0, 4))]
            Tb(m, "LabResin", col, (xx, y + 0.02, z0 + 0.15), (xx, y + 0.02 + h, z0 + 0.15), r, segs=12)
            Tb(m, "LabResin", DARKP, (xx, y + 0.02 + h, z0 + 0.15), (xx, y + 0.045 + h, z0 + 0.15), r * 0.55, segs=10)
            Bx(m, "LabWall", (0.95, 0.95, 0.93), xx - r * 0.7, xx + r * 0.7, y + 0.06, y + 0.06 + h * 0.4, z0 + 0.15 + r,
               z0 + 0.15 + r + 0.002)
            xx += 2 * r + rng.uniform(0.01, 0.03)
    plate(m, "l_periodic", (-0.2, 1.95, -ZI + 0.014), (1, 0, 0), (0, 1, 0), 1.8, depth=0.006, back=(0.9, 0.9, 0.9))


def island(K, x0, x1, z0, z1, seed, scope_at=None):
    """A double-sided island bench: casework both sides, a black resin top,
    a service spine with gas taps and sockets, glass reagent shelves on steel
    uprights over it."""
    m, g, sh = K.furn, K.glass, K.sh
    zc = (z0 + z1) / 2
    casework(m, sh, x0, x1, zc, z1, resin=None, front=1)
    casework(m, sh, x0, x1, z0, zc, resin=None, front=-1)
    Bx(m, "LabResin", RESIN, x0 - 0.03, x1 + 0.03, 0.865, 0.90, z0 - 0.03, z1 + 0.03)
    # the spine
    Bx(m, "LabWall", CASE, x0 + 0.05, x1 - 0.05, 0.90, 1.18, zc - 0.09, zc + 0.09, sh=sh)
    Bx(m, "LabSteel", STEEL, x0 + 0.05, x1 - 0.05, 1.18, 1.2, zc - 0.10, zc + 0.10)
    for xx in np.arange(x0 + 0.4, x1 - 0.3, 0.9):
        for s in (-1, 1):
            Bx(m, "LabWall", (0.95, 0.95, 0.94), xx - 0.05, xx + 0.05, 1.02, 1.1, zc + s * 0.09, zc + s * 0.096)
            for q in (-0.022, 0.022):
                Bx(m, "LabResin", DARKP, xx + q - 0.006, xx + q + 0.006, 1.055, 1.07, zc + s * 0.096, zc + s * 0.098)
            for k, col in enumerate(((0.55, 0.40, 0.05), (0.08, 0.25, 0.55), (0.10, 0.42, 0.18))):
                px = xx + 0.18 + k * 0.08
                Tb(m, "LabSteel", STEEL, (px, 0.97, zc + s * 0.09), (px, 0.97, zc + s * 0.13), 0.008, segs=8)
                Tb(m, "LabResin", col, (px, 0.97, zc + s * 0.11), (px, 1.0, zc + s * 0.11), 0.012, segs=8)
    # uprights and two glass shelves (one solid unit: nobody stands in it,
    # and the talk camera must not be put in it)
    solid(sh, x0 + 0.08, x1 - 0.08, 1.18, 2.25, zc - 0.21, zc + 0.21)
    for xx in (x0 + 0.1, (x0 + x1) / 2, x1 - 0.1):
        Bx(m, "LabSteel", STEEL, xx - 0.02, xx + 0.02, 1.2, 2.05, zc - 0.02, zc + 0.02)
        for y in (1.55, 1.95):
            Bx(m, "LabSteel", STEEL, xx - 0.015, xx + 0.015, y - 0.03, y, zc - 0.2, zc + 0.2)
    for y in (1.55, 1.95):
        g.color = (1, 1, 1)
        box(g, "LabGlass", ((x0 + x1) / 2, y + 0.006, zc), (x1 - x0 - 0.2, 0.012, 0.42))
        rng = np.random.default_rng(seed + int(y * 10))
        xx = x0 + 0.22
        # groups, not a row: a run of reagent bottles of mixed sizes, a gap,
        # binders leaning, a stack of sample boxes, a wash bottle, a gap
        while xx < x1 - 0.3:
            if min(abs(xx - u) for u in (x0 + 0.1, (x0 + x1) / 2, x1 - 0.1)) < 0.06:
                xx += 0.08
                continue
            kind = rng.choice(["bottles", "binders", "boxes", "gap", "bottles", "jar"], p=[0.3, 0.15, 0.15, 0.15, 0.15, 0.1])
            if kind == "gap":
                xx += rng.uniform(0.15, 0.35)
                continue
            if kind == "bottles":
                for _ in range(int(rng.integers(2, 5))):
                    r = float(rng.choice([0.022, 0.03, 0.04, 0.052]))
                    h = r * rng.uniform(2.6, 4.2)
                    col = [(0.30, 0.18, 0.06), (0.88, 0.88, 0.86), (0.10, 0.22, 0.42), (0.35, 0.12, 0.08),
                           (0.86, 0.86, 0.84)][int(rng.integers(0, 5))]
                    zz = zc + rng.uniform(-0.09, 0.09)
                    Tb(m, "LabResin", col, (xx + r, y + 0.012, zz), (xx + r, y + 0.012 + h, zz), r, segs=12)
                    Tb(m, "LabResin", (0.08, 0.08, 0.09) if rng.random() < 0.6 else (0.75, 0.15, 0.08),
                       (xx + r, y + 0.012 + h, zz), (xx + r, y + 0.03 + h, zz), r * 0.55, segs=10)
                    Bx(m, "LabWall", (0.95, 0.95, 0.93), xx + r * 0.4, xx + r * 1.6, y + 0.012 + h * 0.3,
                       y + 0.012 + h * 0.65, zz - r - 0.002, zz - r - 0.0005)
                    xx += 2 * r + rng.uniform(0.008, 0.03)
            elif kind == "binders":
                n = int(rng.integers(2, 5))
                for i in range(n):
                    col = [(0.12, 0.25, 0.55), (0.15, 0.15, 0.16), (0.55, 0.12, 0.10), (0.85, 0.85, 0.82)][int(rng.integers(0, 4))]
                    zb = 0.12 - 0.006 * (i % 3)
                    Bx(m, "LabResin", col, xx, xx + 0.045, y + 0.012, y + 0.30 - 0.008 * (i % 2), zc - 0.13 + 0.004 * (i % 2), zc + zb)
                    Bx(m, "LabWall", (0.95, 0.95, 0.92), xx + 0.008, xx + 0.037, y + 0.20, y + 0.27,
                       zc - 0.134 + 0.004 * (i % 2), zc - 0.131 + 0.004 * (i % 2))
                    xx += 0.051
                xx += 0.03
            elif kind == "boxes":
                hh = y + 0.012
                for i in range(int(rng.integers(1, 4))):
                    bw = rng.uniform(0.16, 0.24)
                    bh = rng.uniform(0.05, 0.09)
                    col = [(0.80, 0.78, 0.72), (0.30, 0.42, 0.55), (0.92, 0.92, 0.90)][int(rng.integers(0, 3))]
                    Bx(m, "LabWall", col, xx, xx + bw, hh, hh + bh, zc - 0.12 + 0.01 * i, zc + 0.10 - 0.01 * i)
                    hh += bh + 0.001
                xx += 0.26
            else:   # a wide-mouth sample jar of something
                Tb(m, "LabResin", (0.86, 0.87, 0.86), (xx + 0.05, y + 0.012, zc), (xx + 0.05, y + 0.13, zc), 0.05, segs=14)
                Tb(m, "LabResin", [(0.45, 0.25, 0.12), (0.30, 0.30, 0.32)][int(rng.integers(0, 2))],
                   (xx + 0.05, y + 0.017, zc), (xx + 0.05, y + 0.07, zc), 0.044, segs=14)
                xx += 0.13
    # what's out on the bench
    rng = np.random.default_rng(seed)
    for s in (-1, 1):
        zz = zc + s * 0.42
        glassware(K, x0 + 0.7 + rng.uniform(0, 0.6), 0.90, zz, seed + s * 3)
        # a sample tray of small vials
        tx = x1 - 0.9 - rng.uniform(0, 0.8)
        Bx(m, "LabWall", (0.86, 0.88, 0.90), tx - 0.16, tx + 0.16, 0.90, 0.925, zz - 0.11, zz + 0.11)
        for i in range(6):
            for j in range(4):
                Tb(m, "LabResin", ((0.75, 0.78, 0.8) if (i + j) % 3 else (0.30, 0.20, 0.10)), (tx - 0.125 + i * 0.05, 0.925, zz - 0.075 + j * 0.05),
                   (tx - 0.125 + i * 0.05, 0.975, zz - 0.075 + j * 0.05), 0.009, segs=6)
    # a hotplate stirrer, a laptop
    hx = x0 + 2.4
    Bx(m, "LabWall", (0.90, 0.90, 0.88), hx - 0.1, hx + 0.1, 0.90, 0.99, zc - 0.48, zc - 0.28, bevel=0.012)
    Bx(m, "LabSteel", STEEL, hx - 0.085, hx + 0.085, 0.99, 1.0, zc - 0.465, zc - 0.295)
    glass_cyl(K.glass, (hx, 1.0, zc - 0.38), 0.045, 0.12)
    lx = x0 + 3.6
    Bx(m, "LabResin", (0.12, 0.12, 0.13), lx - 0.17, lx + 0.17, 0.90, 0.915, zc + 0.3, zc + 0.55)
    cuboid(m, (lx, 1.02, zc + 0.56), (1, 0, 0), (0, 0.94, -0.34), 0.34, 0.22, 0.008, col=(0.12, 0.12, 0.13), mat="LabResin")
    cuboid(m, (lx, 1.02, zc + 0.555), (-1, 0, 0), (0, 0.94, 0.34), 0.31, 0.19, 0.002,
           faces={"front": ("LabScreen", (1, 1, 1), "l_s_lattice")}, col=(0.12, 0.12, 0.13), mat="LabResin")
    if scope_at is not None:
        microscope(m, scope_at[0], 0.90, scope_at[1], face=(0, 0, 1))


def wall_bench(K):
    """The south wall bench: microscopes, a balance in its draft shield, a
    centrifuge, a vial rack; glass-fronted wall cupboards over it."""
    m, g, sh = K.furn, K.glass, K.sh
    x0, x1 = -5.6, 5.6
    z1 = ZI
    z0 = z1 - 0.75
    casework(m, sh, x0, x1, z0, z1, resin=True, front=-1)
    # wall cupboards
    for xx in np.arange(x0, x1 - 0.5, 1.2):
        a, b = xx + 0.02, xx + 1.18
        Bx(m, "LabWall", CASE, a, b, 1.6, 2.35, z1 - 0.36, z1, sh=sh)
        Bx(m, "LabWall", CASE_SH, a + 0.03, b - 0.03, 1.64, 2.31, z1 - 0.362, z1 - 0.36)
        g.color = (1, 1, 1)
        box(g, "LabGlass", ((a + b) / 2, 1.975, z1 - 0.365), (b - a - 0.12, 0.62, 0.006))
        for y in (1.85, 2.08):
            Bx(m, "LabWall", CASE, a + 0.03, b - 0.03, y, y + 0.012, z1 - 0.34, z1 - 0.02)
        Tb(m, "LabSteel", STEEL, ((a + b) / 2 - 0.05, 1.68, z1 - 0.38), ((a + b) / 2 + 0.05, 1.68, z1 - 0.38), 0.005, segs=6)
        # boxes and bottles behind the glass
        rng = np.random.default_rng(int(xx * 10 + 99))
        q = a + 0.08
        while q < b - 0.1:
            w = rng.uniform(0.08, 0.2)
            col = [(0.80, 0.80, 0.78), (0.30, 0.45, 0.62), (0.62, 0.40, 0.20), (0.92, 0.92, 0.9)][int(rng.integers(0, 4))]
            Bx(m, "LabWall", col, q, q + w, 1.862, 1.862 + rng.uniform(0.08, 0.2), z1 - 0.3, z1 - 0.1)
            q += w + 0.02
    # a light strip under the cupboards
    Bx(m, "LabLamp", LAMP_TASK, x0 + 0.1, x1 - 0.1, 1.585, 1.6, z1 - 0.3, z1 - 0.26)
    # microscopes, the camera monitor beside one
    microscope(m, -4.3, 0.90, z1 - 0.38, face=(0, 0, -1))
    microscope(m, 3.9, 0.90, z1 - 0.38, face=(0, 0, -1))
    screen(m, "l_s_micro", (-3.75, 1.2, z1 - 0.4), (-1, 0, 0), (0, 1, 0), 0.38)
    Bx(m, "LabResin", DARKP, -3.80, -3.70, 0.90, 1.05, z1 - 0.42, z1 - 0.36)
    # the analytical balance in its glass draft shield
    bx = -1.8
    Bx(m, "LabWall", (0.90, 0.90, 0.88), bx - 0.18, bx + 0.18, 0.90, 0.96, z1 - 0.55, z1 - 0.15, bevel=0.01)
    Bx(m, "LabResin", DARKP, bx - 0.12, bx + 0.0, 0.93, 0.955, z1 - 0.552, z1 - 0.53)
    Bx(m, "LabSteel", STEEL, bx - 0.15, bx + 0.15, 0.96, 0.975, z1 - 0.5, z1 - 0.2)
    g.color = (1, 1, 1)
    for (c, s) in (((bx, 1.12, z1 - 0.5), (0.34, 0.3, 0.006)), ((bx, 1.12, z1 - 0.18), (0.34, 0.3, 0.006)),
                   ((bx - 0.17, 1.12, z1 - 0.34), (0.006, 0.29, 0.30)), ((bx + 0.17, 1.12, z1 - 0.34), (0.006, 0.29, 0.30)),
                   ((bx, 1.275, z1 - 0.34), (0.33, 0.006, 0.31))):
        box(g, "LabGlass", c, s)
    # the centrifuge
    cx = 0.5
    sub = CModel(); sub.ground = False; sub.color = (0.90, 0.91, 0.92)
    lathe(sub, "LabWall", [(0.0, 0.0), (0.24, 0.0), (0.25, 0.02), (0.25, 0.26), (0.22, 0.30), (0.0, 0.31)], segs=24)
    m.merge(sub, None, (cx, 0.90, z1 - 0.38))
    Bx(m, "LabResin", DARKP, cx - 0.12, cx + 0.12, 0.98, 1.06, z1 - 0.64, z1 - 0.62)
    # a vial rack, a pipette stand
    vx = 2.0
    Bx(m, "LabWall", (0.80, 0.83, 0.88), vx - 0.25, vx + 0.25, 0.90, 0.98, z1 - 0.5, z1 - 0.2)
    for i in range(9):
        for j in range(4):
            Tb(m, "LabResin", ((0.85, 0.86, 0.86) if (i * 3 + j) % 5 else (0.62, 0.15, 0.10)),
               (vx - 0.22 + i * 0.055, 0.98, z1 - 0.47 + j * 0.08), (vx - 0.22 + i * 0.055, 1.06, z1 - 0.47 + j * 0.08), 0.011, segs=6)
    Tb(m, "LabSteel", STEEL, (2.8, 0.9, z1 - 0.3), (2.8, 1.25, z1 - 0.3), 0.008, segs=6)
    for k in range(4):
        Tb(m, "LabResin", ((0.85, 0.30, 0.10), (0.10, 0.35, 0.70), (0.90, 0.75, 0.10), (0.30, 0.60, 0.20))[k],
           (2.75 + k * 0.022, 1.0, z1 - 0.27), (2.75 + k * 0.022, 1.24, z1 - 0.27), 0.009, segs=6)
    glassware(K, 4.7, 0.90, z1 - 0.4, 77)
    plate(m, "l_lab", (0.0, 2.75, ZI - 0.014), (-1, 0, 0), (0, 1, 0), 3.4, depth=0.008)


def receiving(K):
    """The sample receiving station where the pneumatic tube from the
    Materials Intake ends: the tube through the wall, along under the ceiling,
    down into a glass receiver on a steel cabinet; a log screen, a balance,
    trays, floor tape."""
    m, g, sh = K.furn, K.glass, K.sh
    tx, ty = L["tube_x"], L["tube_y"]
    rz = 4.55                                  # the receiver's axis (z)
    x0, x1, z0, z1 = tx - 1.3, tx + 1.3, rz - 0.55, rz + 0.55
    casework(m, sh, x0, x1, z0, z1, top_y=0.95, resin=False, front=-1)
    # the receiver: a steel base ring, a glass bell, a cap where the tube lands
    solid(sh, tx - 0.21, tx + 0.21, 0.95, 1.56, rz - 0.21, rz + 0.21)
    Tb(m, "LabSteel", STEEL_D, (tx, 0.95, rz), (tx, 1.0, rz), 0.2, segs=24)
    g.color = (1, 1, 1)
    Tb(g, "LabGlass", (1, 1, 1), (tx, 1.0, rz), (tx, 1.42, rz), 0.17, segs=24)
    Tb(m, "LabSteel", STEEL, (tx, 1.42, rz), (tx, 1.48, rz), 0.2, segs=24)
    Tb(m, "LabSteel", STEEL_D, (tx, 1.48, rz), (tx, 1.56, rz), 0.13, segs=20)
    # the tube: glass, r 0.07, in steel couplers — through the wall at the
    # ceiling line, north under the ceiling, a sweep, down to the cap
    TR = 0.075
    path = [(tx, ty, ZI + 0.05), (tx, ty, rz + 0.45), (tx, ty - 0.12, rz + 0.12), (tx, ty - 0.45, rz), (tx, 1.56, rz)]
    for a, b in zip(path[:-1], path[1:]):
        Tb(g, "LabGlass", (1, 1, 1), a, b, TR, segs=18)
    # couplers at the joints and hangers to the ceiling
    for (c, ax) in (((tx, ty, ZI - 0.05), (0, 0, 1)), ((tx, ty, rz + 1.8), (0, 0, 1)), ((tx, ty, rz + 0.45), (0, 0, 1)),
                    ((tx, ty - 0.45, rz), (0, 1, 0)), ((tx, 1.9, rz), (0, 1, 0))):
        c = np.array(c, float); a = np.array(ax, float)
        Tb(m, "LabSteel", STEEL, c - a * 0.04, c + a * 0.04, TR + 0.014, segs=18)
    for zz in (rz + 0.9, rz + 1.8):
        Tb(m, "LabSteel", STEEL_D, (tx, ty + TR + 0.014, zz), (tx, CY, zz), 0.006, segs=6)
        Bx(m, "LabSteel", STEEL_D, tx - 0.1, tx + 0.1, ty + TR, ty + TR + 0.02, zz - 0.02, zz + 0.02)
    # the escutcheon where it comes through the wall
    Tb(m, "LabSteel", STEEL, (tx, ty, ZI - 0.012), (tx, ty, ZI), 0.16, segs=20)
    # the log screen on an arm, the balance, trays of sample bags
    screen(m, "l_s_log", (tx + 0.85, 1.35, z0 + 0.25), (-1, 0, 0), (0, 0.97, -0.24), 0.42)
    Tb(m, "LabSteel", STEEL_D, (tx + 0.85, 0.95, z0 + 0.33), (tx + 0.85, 1.22, z0 + 0.33), 0.015, segs=8)
    Bx(m, "LabWall", (0.90, 0.90, 0.88), tx - 1.0, tx - 0.62, 0.95, 1.0, z0 + 0.1, z0 + 0.42, bevel=0.01)
    Bx(m, "LabSteel", STEEL, tx - 0.95, tx - 0.67, 1.0, 1.008, z0 + 0.15, z0 + 0.37)
    Bx(m, "LabSteel", STEEL, tx + 0.35, tx + 0.75, 0.95, 0.97, z1 - 0.45, z1 - 0.1)
    for k in range(5):
        Bx(m, "LabWall", (0.86, 0.85, 0.80), tx + 0.40 + (k % 3) * 0.11, tx + 0.50 + (k % 3) * 0.11, 0.97,
           0.985 + 0.01 * (k % 2), z1 - 0.40 + (k // 3) * 0.13, z1 - 0.29 + (k // 3) * 0.13)
    plate(m, "l_receiving", (tx, 2.2, ZI - 0.014), (-1, 0, 0), (0, 1, 0), 1.6, depth=0.008)
    plate(m, "l_pneu", (tx, 0.75, z0 - 0.021), (-1, 0, 0), (0, 1, 0), 0.9, depth=0.004)
    # the hazard tape on the floor round the station
    for (a, b, c, d) in ((x0 - 0.4, x1 + 0.4, z0 - 0.5, z0 - 0.42), (x0 - 0.4, x0 - 0.32, z0 - 0.42, ZI),
                         (x1 + 0.32, x1 + 0.4, z0 - 0.42, ZI)):
        Bx(m, "LabWall", SAFETY_Y, a, b, FT, FT + 0.0015, c, d)
    # the sample archive: wall shelves of labelled jars above the station's west
    solid(sh, -XI, -XI + 0.32, 1.62, 2.7, 3.3, 5.9)
    for y in (1.65, 2.05, 2.45):
        Bx(m, "LabSteel", STEEL, -XI, -XI + 0.32, y, y + 0.02, 3.3, 5.9)
        rng = np.random.default_rng(int(y * 1000))
        zz = 3.4
        while zz < 5.8:
            Tb(m, "LabResin", (0.88, 0.89, 0.88), (-XI + 0.16, y + 0.02, zz), (-XI + 0.16, y + 0.16, zz), 0.045, segs=12)
            Tb(m, "LabResin", [(0.45, 0.25, 0.12), (0.35, 0.35, 0.36), (0.55, 0.45, 0.30), (0.20, 0.25, 0.20)][int(rng.integers(0, 4))],
               (-XI + 0.16, y + 0.025, zz), (-XI + 0.16, y + 0.10, zz), 0.042, segs=12)
            Tb(m, "LabResin", DARKP, (-XI + 0.16, y + 0.16, zz), (-XI + 0.16, y + 0.18, zz), 0.046, segs=12)
            zz += 0.12
    return {"in": path[0], "p1": path[1], "p2": path[3], "end": (tx, 1.2, rz)}


def instruments(K):
    """The instrument room: an SEM on its desk, an XRF, an ICP-MS, a rack."""
    m, g, sh = K.furn, K.glass, K.sh
    z0 = -ZI
    # the SEM: console desk with two monitors; the column on its isolation table
    Bx(m, "LabWall", CASE, 2.2, 4.6, FT, 0.74, z0, z0 + 0.8, sh=sh)
    Bx(m, "LabResin", (0.22, 0.24, 0.26), 2.18, 4.62, 0.74, 0.77, z0, z0 + 0.82)
    screen(m, "l_s_sem", (2.85, 1.1, z0 + 0.35), (1, 0, 0), (0, 0.98, 0.2), 0.62)
    screen(m, "l_s_sem2", (3.6, 1.1, z0 + 0.35), (1, 0, 0), (0, 0.98, 0.2), 0.62)
    for xx in (2.85, 3.6):
        Bx(m, "LabResin", DARKP, xx - 0.05, xx + 0.05, 0.77, 0.9, z0 + 0.28, z0 + 0.34)
    Bx(m, "LabResin", DARKP, 3.0, 3.45, 0.77, 0.785, z0 + 0.55, z0 + 0.7)
    Bx(m, "LabWall", (0.86, 0.88, 0.9), 4.8, 6.0, FT, 0.82, z0 + 0.05, z0 + 1.05, sh=sh)
    Bx(m, "LabWall", (0.92, 0.93, 0.94), 5.0, 5.8, 0.82, 1.05, z0 + 0.25, z0 + 0.85, bevel=0.04)
    solid(sh, 5.2, 5.6, 0.82, 2.05, z0 + 0.35, z0 + 0.75)
    Tb(m, "LabSteel", STEEL, (5.4, 1.05, z0 + 0.55), (5.4, 1.75, z0 + 0.55), 0.18, segs=24)
    Tb(m, "LabSteel", STEEL_D, (5.4, 1.75, z0 + 0.55), (5.4, 1.95, z0 + 0.55), 0.12, segs=20)
    Tb(m, "LabSteel", STEEL, (5.4, 1.95, z0 + 0.55), (5.4, 2.05, z0 + 0.55), 0.16, segs=20)
    Tb(m, "LabSteel", STEEL_D, (5.4, 1.2, z0 + 0.55), (5.9, 1.2, z0 + 0.55), 0.06, segs=12)
    plate(m, "l_sem", (5.4, 1.6, z0 + 0.73), (1, 0, 0), (0, 1, 0), 0.28, depth=0.004)
    # the XRF benchtop on a bench, its screen
    casework(m, sh, 6.4, 8.1, z0, z0 + 0.75, resin=True)
    Bx(m, "LabWall", (0.90, 0.90, 0.88), 6.6, 7.4, 0.90, 1.32, z0 + 0.1, z0 + 0.65, bevel=0.05)
    cuboid(m, (7.0, 1.22, z0 + 0.66), (1, 0, 0), (0, 0.8, 0.6), 0.5, 0.18, 0.02, col=(0.22, 0.24, 0.26), mat="LabResin")
    screen(m, "l_s_xrf", (7.75, 1.25, z0 + 0.3), (1, 0, 0), (0, 0.98, 0.2), 0.56)
    plate(m, "l_xrf", (7.0, 1.05, z0 + 0.651), (1, 0, 0), (0, 1, 0), 0.4, depth=0.004)
    # the ICP-MS: a tall cabinet with its screen; the rack
    Bx(m, "LabWall", (0.92, 0.93, 0.94), 8.5, 10.3, FT, 1.55, z0 + 0.05, z0 + 0.95, sh=sh, bevel=0.03)
    Bx(m, "LabResin", (0.20, 0.22, 0.26), 8.6, 10.2, 1.25, 1.5, z0 + 0.951, z0 + 0.96)
    screen(m, "l_s_ms", (9.4, 1.85, z0 + 0.25), (1, 0, 0), (0, 0.98, 0.2), 0.6)
    plate(m, "l_mspec", (9.0, 1.15, z0 + 0.951), (1, 0, 0), (0, 1, 0), 0.4, depth=0.004)
    Bx(m, "LabResin", (0.08, 0.085, 0.09), 9.7, 10.4, FT, 2.1, -3.9, -2.9, sh=sh)
    for k in range(10):
        y = 0.35 + k * 0.17
        Bx(m, "LabResin", (0.15, 0.16, 0.17), 9.695, 9.7, y, y + 0.12, -3.85, -2.95)
        for q in range(4):
            Bx(m, "LabLamp", ((0.2, 1.0, 0.4) if (k + q) % 3 else (1.0, 0.6, 0.1)), 9.69, 9.695, y + 0.05, y + 0.07,
               -3.8 + q * 0.03, -3.79 + q * 0.03)
    # a lab stool by the SEM desk
    solid(sh, 3.18, 3.62, FT, 0.68, z0 + 1.03, z0 + 1.47)
    Tb(m, "LabSteel", STEEL_D, (3.4, FT, z0 + 1.25), (3.4, 0.62, z0 + 1.25), 0.025, segs=8)
    Tb(m, "LabResin", (0.10, 0.12, 0.16), (3.4, 0.62, z0 + 1.25), (3.4, 0.68, z0 + 1.25), 0.19, segs=18)
    for k in range(5):
        a = k * TAU5
        Tb(m, "LabSteel", STEEL_D, (3.4, FT + 0.06, z0 + 1.25), (3.4 + 0.28 * math.cos(a), FT + 0.04, z0 + 1.25 + 0.28 * math.sin(a)),
           0.014, segs=6)


TAU5 = 2 * math.pi / 5


def west_east(K):
    """The glove box and the storage on the west wall; the freezer, the
    whiteboard, the flammables cabinet on the east; the vestibule's coats."""
    m, g, sh = K.furn, K.glass, K.sh
    # GLOVE BOX on its stand
    gx0, gx1, gz0, gz1 = -XI, -XI + 0.82, -1.9, 0.6
    for (xx, zz) in ((gx0 + 0.06, gz0 + 0.06), (gx1 - 0.06, gz0 + 0.06), (gx0 + 0.06, gz1 - 0.06), (gx1 - 0.06, gz1 - 0.06)):
        Bx(m, "LabSteel", STEEL_D, xx - 0.03, xx + 0.03, FT, 0.85, zz - 0.03, zz + 0.03)
    Bx(m, "LabSteel", STEEL, gx0, gx1, 0.85, 0.9, gz0, gz1, sh=sh)
    Bx(m, "LabSteel", STEEL, gx0, gx0 + 0.45, 0.9, 1.85, gz0, gz1, sh=sh)
    Bx(m, "LabSteel", STEEL, gx0 + 0.45, gx1, 1.72, 1.85, gz0, gz1)
    for zz in (gz0, gz1 - 0.04):
        Bx(m, "LabSteel", STEEL, gx0 + 0.45, gx1, 0.9, 1.72, zz, zz + 0.04)
    # the sloped window, two glove ports with black gloves hanging in
    g.color = (1, 1, 1)
    from gen_part_meshes import box as _box
    import base_models as BM
    ang = math.radians(16)
    Mw = np.array([[math.cos(ang), 0, math.sin(ang)], [0, 1, 0], [-math.sin(ang), 0, math.cos(ang)]])
    Mw = np.array([[1, 0, 0], [0, math.cos(ang), -math.sin(ang)], [0, math.sin(ang), math.cos(ang)]])
    # the window lies in the y-z plane at x = gx1, leaning in at the top
    wn = np.array([math.cos(ang), math.sin(ang), 0.0])
    Mx = np.column_stack([wn, np.array([-math.sin(ang), math.cos(ang), 0.0]), np.array([0.0, 0.0, 1.0])])
    _box(g, "LabGlass", (gx1 - 0.08, 1.31, (gz0 + gz1) / 2), (0.01, 0.82, gz1 - gz0 - 0.1), M=Mx)
    for zz in ((gz0 + gz1) / 2 - 0.45, (gz0 + gz1) / 2 + 0.45):
        c = np.array([gx1 - 0.06, 1.2, zz])
        Tb(m, "LabSteel", STEEL_D, c - wn * 0.02, c + wn * 0.04, 0.11, segs=20)
        Tb(m, "LabResin", (0.03, 0.03, 0.035), c - wn * 0.02, c - wn * 0.35 - np.array([0, 0.12, 0]), 0.09, segs=14, r1=0.05)
    # the antechamber: a steel cylinder on the side with its door
    solid(sh, gx0 + 0.17, gx0 + 0.63, 0.97, 1.43, gz1, gz1 + 0.54)
    Tb(m, "LabSteel", STEEL, (gx0 + 0.4, 1.2, gz1), (gx0 + 0.4, 1.2, gz1 + 0.5), 0.2, segs=22)
    Tb(m, "LabSteel", STEEL_D, (gx0 + 0.4, 1.2, gz1 + 0.5), (gx0 + 0.4, 1.2, gz1 + 0.54), 0.23, segs=22)
    plate(m, "l_glovebox", (gx1 + 0.002, 1.78, (gz0 + gz1) / 2), (0, 0, -1), (0, 1, 0), 1.1, depth=0.004)
    # storage on the west wall: tall white cupboards, the flammables cabinet
    Bx(m, "LabWall", CASE, -XI, -XI + 0.6, FT, 2.2, 1.0, 2.2, sh=sh)
    for zz in (1.0, 1.6):
        Bx(m, "LabWall", CASE_SH, -XI + 0.6, -XI + 0.615, FT + 0.05, 2.15, zz + 0.01, zz + 0.59)
        Tb(m, "LabSteel", STEEL, (-XI + 0.63, 1.0, zz + (0.52 if zz > 1.2 else 0.08)), (-XI + 0.63, 1.3, zz + (0.52 if zz > 1.2 else 0.08)),
           0.007, segs=6)
    Bx(m, "LabWall", SAFETY_Y, -XI, -XI + 0.55, FT, 1.2, 2.4, 3.15, sh=sh)
    Bx(m, "LabWall", (0.70, 0.54, 0.04), -XI + 0.55, -XI + 0.56, FT + 0.05, 1.15, 2.42, 3.13)
    plate(m, "l_flam", (-XI + 0.562, 0.9, 2.775), (0, 0, -1), (0, 1, 0), 0.5, depth=0.003)
    # EAST: the -80 freezer, a lab fridge, the whiteboard
    Bx(m, "LabWall", (0.93, 0.93, 0.92), XI - 0.85, XI, FT, 2.0, 1.8, 2.75, sh=sh, bevel=0.02)
    Bx(m, "LabWall", (0.86, 0.87, 0.87), XI - 0.87, XI - 0.85, FT + 0.12, 1.85, 1.85, 2.7)
    screen(m, "l_s_freezer", (XI - 0.875, 1.7, 2.25), (0, 0, 1), (0, 1, 0), 0.22, bezel=0.01, depth=0.02)
    Tb(m, "LabSteel", STEEL, (XI - 0.9, 0.9, 1.9), (XI - 0.9, 1.4, 1.9), 0.012, segs=8)
    plate(m, "l_minus80", (XI - 0.871, 1.95, 2.25), (0, 0, 1), (0, 1, 0), 0.7, depth=0.003)
    Bx(m, "LabWall", (0.93, 0.93, 0.92), XI - 0.7, XI, FT, 1.7, 0.6, 1.5, sh=sh, bevel=0.02)
    g.color = (1, 1, 1)
    box(g, "LabGlass", (XI - 0.705, 1.0, 1.05), (0.008, 1.2, 0.8))
    for y in (0.6, 0.95, 1.3):
        Bx(m, "LabSteel", STEEL_D, XI - 0.65, XI - 0.05, y, y + 0.01, 0.66, 1.44)
        for k in range(5):
            Tb(m, "LabResin", ((0.85, 0.86, 0.86), (0.62, 0.15, 0.10), (0.15, 0.35, 0.65))[k % 3],
               (XI - 0.5 + k * 0.09, y + 0.01, 1.2), (XI - 0.5 + k * 0.09, y + 0.12, 1.2), 0.02, segs=8)
    # the whiteboard and its tray, a wall clock
    wz0, wz1 = -1.6, 0.2
    Bx(m, "LabSteel", ALU, XI - 0.03, XI, 1.0, 2.1, wz0 - 0.03, wz1 + 0.03)
    cuboid(m, (XI - 0.031, 1.55, (wz0 + wz1) / 2), (0, 0, 1), (0, 1, 0), wz1 - wz0, 1.04, 0.002,
           faces={"front": ("LabSign", (1, 1, 1), "l_whiteboard")}, col=(0.9, 0.9, 0.9), mat="LabWall")
    Bx(m, "LabSteel", ALU, XI - 0.09, XI - 0.03, 0.98, 1.0, wz0, wz1)
    for k, col in enumerate(((0.05, 0.1, 0.4), (0.4, 0.05, 0.03), (0.05, 0.05, 0.06))):
        Tb(m, "LabResin", col, (XI - 0.06, 1.007, wz0 + 0.2 + k * 0.15), (XI - 0.06, 1.007, wz0 + 0.32 + k * 0.15), 0.007, segs=6)
    Tb(m, "LabWall", (0.95, 0.95, 0.94), (XI - 0.01, 2.75, -0.7), (XI - 0.05, 2.75, -0.7), 0.15, segs=24)
    Tb(m, "LabResin", DARKP, (XI - 0.051, 2.75, -0.7), (XI - 0.053, 2.75, -0.7), 0.13, segs=24)
    # the fire extinguisher by the lab door, a first-aid box
    solid(sh, 5.7, 5.9, FT, 1.0, ZI - 0.21, ZI)
    Tb(m, "LabWall", RED, (5.8, FT + 0.35, ZI - 0.12), (5.8, FT + 0.92, ZI - 0.12), 0.08, segs=16)
    Tb(m, "LabResin", DARKP, (5.8, FT + 0.92, ZI - 0.12), (5.8, FT + 1.0, ZI - 0.12), 0.03, segs=8)
    plate(m, "l_fire", (5.8, 1.55, ZI - 0.014), (-1, 0, 0), (0, 1, 0), 0.4, depth=0.003)
    Bx(m, "LabWall", SAFETY_G, -2.3, -1.9, 1.5, 1.8, ZI - 0.12, ZI - 0.015)
    # THE VESTIBULE: coats on hooks, a bench, the tacky mat, a hand-wash basin
    for k, zz in enumerate((4.0, 4.55, 5.1)):
        Tb(m, "LabSteel", STEEL, (XI - 0.012, 1.85, zz), (XI - 0.08, 1.88, zz), 0.008, segs=6)
        hang = CModel(); hang.ground = False
        prof = [(0.05, 0.0), (0.17, -0.05), (0.21, -0.25), (0.22, -0.7), (0.24, -1.0), (0.0, -1.0)]
        hang.color = (0.88, 0.885, 0.875)
        lathe(hang, "LabWall", [(r, y) for (r, y) in prof], segs=12)
        P = np.vstack(hang.parts["LabWall"][0])
        P[:, 0] *= 0.35          # flattened against the wall
        hang.parts["LabWall"][0][:] = [P]
        m.merge(hang, None, (XI - 0.1, 1.88, zz))
    solid(sh, XI - 0.14, XI, 0.85, 1.9, 3.75, 5.35)
    Bx(m, "LabWall", CASE, 7.2, 9.6, 0.42, 0.46, VZ + 0.15, VZ + 0.5)
    solid(sh, 7.2, 9.6, FT, 0.75, VZ + 0.15, VZ + 0.5)     # (taller than the seat: not a step)
    for xx in (7.3, 9.5):
        Bx(m, "LabSteel", STEEL_D, xx - 0.02, xx + 0.02, FT, 0.42, VZ + 0.3, VZ + 0.34)
    Bx(m, "LabWall", TACKY, L["door_x0"] + 0.05, L["door_x1"] - 0.05, FT, FT + 0.004, ZI - 1.0, ZI - 0.08)
    Bx(m, "LabSteel", STEEL, XI - 0.45, XI, 0.82, 0.9, 5.6, 6.2)
    solid(sh, XI - 0.45, XI, FT, 0.82, 5.6, 6.2)
    Tb(m, "LabSteel", STEEL, (XI - 0.08, 0.9, 5.9), (XI - 0.08, 1.15, 5.9), 0.01, segs=8)
    plate(m, "l_exit", (L["door_x0"] + 1.0, 2.75, ZI - 0.014), (-1, 0, 0), (0, 1, 0), 0.5, depth=0.003)


def doors(K):
    """The sliding doors scripts/lab.lua opens: the lab's own pair in the
    south wall's doorway (from the link corridor), the vestibule's and the
    instrument room's glass sliders. Each a model of its own (it moves),
    built closed, about its own centre."""
    out = {}
    dx0, dx1, dh = L["door_x0"], L["door_x1"], L["door_h"]
    zc = L["D"] - L["t"] / 2
    w = (dx1 - dx0) / 2
    for side, s in (("L", -1), ("R", 1)):
        m = CModel(400 + s); m.ground = False
        cx = (dx0 + dx1) / 2 + s * w / 2
        Bx(m, "LabSteel", ALU, -w / 2, w / 2, 0.0, dh - FT - 0.02, -0.025, 0.025)
        gm = CModel(); gm.ground = False; gm.color = (1, 1, 1)
        box(gm, "LabGlass", (0.0, (dh - FT) / 2 + 0.05, 0.0), (w - 0.12, dh - FT - 0.35, 0.03))
        m.merge(gm)
        Bx(m, "LabSteel", STEEL, -0.02 * s - 0.01 + (w / 2 - 0.08) * -s, -0.02 * s + 0.01 + (w / 2 - 0.08) * -s, 0.85, 1.25, 0.03, 0.045)
        out["Lab Door " + side] = (m, (cx, FT, zc), "z", s)
    for name, (a0, a1), axis, fixed in (("Inner Door", INNER_DOOR, "zaxis", VX), ("Instr Door", INSTR_DOOR, "xaxis", IZ)):
        m = CModel(410); m.ground = False
        ww = a1 - a0
        if axis == "zaxis":
            Bx(m, "LabSteel", ALU, -0.02, 0.02, 0.0, 2.15 - FT, -ww / 2, ww / 2)
            gm = CModel(); gm.ground = False; gm.color = (1, 1, 1)
            box(gm, "LabGlass", (0.0, (2.15 - FT) / 2, 0.0), (0.012, 2.15 - FT - 0.1, ww - 0.08))
            m.merge(gm)
            Bx(m, "LabSteel", STEEL, -0.06, 0.06, 0.95, 1.35, ww / 2 - 0.1, ww / 2 - 0.08)
            out[name] = (m, (fixed, FT, (a0 + a1) / 2), "z", 1)
        else:
            Bx(m, "LabSteel", ALU, -ww / 2, ww / 2, 0.0, 2.15 - FT, -0.02, 0.02)
            gm = CModel(); gm.ground = False; gm.color = (1, 1, 1)
            box(gm, "LabGlass", (0.0, (2.15 - FT) / 2, 0.0), (ww - 0.08, 2.15 - FT - 0.1, 0.012))
            m.merge(gm)
            Bx(m, "LabSteel", STEEL, ww / 2 - 0.1, ww / 2 - 0.08, 0.95, 1.35, -0.06, 0.06)
            out[name] = (m, ((a0 + a1) / 2, FT, fixed), "x", 1)
    return out


def capsule():
    """The pneumatic sample capsule: a clear polycarbonate body between steel
    end caps with felt seal rings; its sample (LabCapsuleCore) is tinted by
    lab.lua to the material inside."""
    m = CModel(500); m.ground = False
    L_, r = 0.28, 0.062
    Tb(m, "LabSteel", STEEL, (0, 0, -L_ / 2), (0, 0, -L_ / 2 + 0.045), r, segs=18)
    Tb(m, "LabSteel", STEEL, (0, 0, L_ / 2 - 0.045), (0, 0, L_ / 2), r, segs=18)
    for zz in (-L_ / 2 + 0.03, L_ / 2 - 0.03):
        Tb(m, "LabResin", (0.12, 0.14, 0.2), (0, 0, zz - 0.006), (0, 0, zz + 0.006), r + 0.008, segs=18)
    Tb(m, "LabGlass", (1, 1, 1), (0, 0, -L_ / 2 + 0.045), (0, 0, L_ / 2 - 0.045), r * 0.96, segs=18)
    # an amber tracer band at each end, lit, so a carrier reads from the yard
    for zz in (-L_ / 2 + 0.012, L_ / 2 - 0.012):
        Tb(m, "LabLamp", (1.0, 0.62, 0.18), (0, 0, zz - 0.008), (0, 0, zz + 0.008), r + 0.003, segs=18)
    core = CModel(501); core.ground = False
    rng = np.random.default_rng(3)
    for k in range(7):
        c = (rng.uniform(-0.025, 0.025), rng.uniform(-0.03, 0.0), rng.uniform(-0.05, 0.05))
        core.color = (1, 1, 1)
        box(core, "LabCapsuleCore", c, tuple(rng.uniform(0.015, 0.035, 3)), bevel=0.004)
    m.merge(core)
    return m


# ═════════════════════════════════════════════════════════════════════════════
# the prefab
# ═════════════════════════════════════════════════════════════════════════════

def _mat(name):
    t = TEX
    M = {
        "LabWall": f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}wall_albedo.png"),\n'
                   '                roughness: 0.42,\n                metallic: 0.0,\n                reflectivity: 0.35,\n'
                   '                shading: Physical,\n            )',
        "LabFloor": f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}floor_albedo.png"),\n'
                    f'                normal_map: Some("{t}floor_normal.png"),\n                normal_strength: 0.6,\n'
                    f'                roughness_map: Some("{t}floor_orm.png"),\n                roughness: 1.0,\n'
                    '                metallic: 0.0,\n                reflectivity: 0.6,\n                shading: Physical,\n            )',
        "LabSteel": f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}steel_albedo.png"),\n'
                    f'                normal_map: Some("{t}steel_normal.png"),\n                normal_strength: 0.5,\n'
                    f'                roughness_map: Some("{t}steel_orm.png"),\n                roughness: 1.0,\n'
                    f'                metallic_map: Some("{t}steel_orm.png"),\n                metallic: 0.85,\n'
                    '                reflectivity: 0.6,\n                shading: Physical,\n            )',
        "LabResin": '(\n                color: (1.0, 1.0, 1.0),\n                roughness: 0.24,\n                metallic: 0.0,\n'
                    '                reflectivity: 0.7,\n                shading: Physical,\n            )',
        "LabGlass": '(\n                color: (0.93, 0.97, 0.97),\n                roughness: 0.03,\n                metallic: 0.0,\n'
                    '                transmission: 0.93,\n                ior: 1.5,\n                thickness: 0.01,\n'
                    '                shading: Physical,\n            )',
        "LabLamp": '(\n                color: (1.0, 1.0, 1.0),\n                unlit: true,\n                fog: false,\n            )',
        "LabScreen": f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}signs.png"),\n'
                     '                unlit: true,\n            )',
        "LabSign": f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}signs.png"),\n'
                   '                roughness: 0.5,\n                metallic: 0.0,\n                reflectivity: 0.3,\n'
                   '                shading: Physical,\n            )',
        "LabCapsuleCore": '(\n                color: (0.6, 0.6, 0.6),\n                roughness: 0.8,\n                metallic: 0.0,\n'
                          '                shading: Physical,\n            )',
    }
    return M[name]


def mesh_node(name, glb, model, pos, parent=0, extra=""):
    mats = ",\n".join(f'            "{n}": {_mat(n)}' for n in sorted(model.parts.keys()))
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/lab/{glb}",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
        parent: Some({parent}),
{extra}    ),
'''


def empty_node(name, pos, parent=0):
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
    ),
'''


def solid_node(name, pos, half, parent=0):
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
        cast_shadow: false,
        rigidbody: Some((
            boxed: true,
            mode: Static,
            radius: 0.5,
            height: 1.0,
            half_extents: {f3(half)},
            restitution: 0.0,
            friction: 0.9,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
        )),
    ),
'''


def light_node(name, pos, col, inten, rng, aim=None, parent=0, angle=70.0):
    rot = spot_rotation(aim) if aim is not None else (0.0, 0.0, 0.0, 1.0)
    spot = f"            spot: Some((angle: {angle}, softness: 0.6)),\n" if aim is not None else ""
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: ({rot[0]:.5f}, {rot[1]:.5f}, {rot[2]:.5f}, {rot[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: {f3(col)},
            intensity: {inten},
            range: {rng},
{spot}        ),
        scripts: [],
        parent: Some({parent}),
        cast_shadow: false,
    ),
'''


# Where the scientists work: (spot, the point they face, where the hands rest)
# Each stands a hand's breadth off the bench front, the hands' point just over
# its edge at the worktop: a straight arm of the rig is 0.55 m from shoulder
# to wrist, so a point half a metre out from a body 0.4 m back held the arms
# out stiff with the hands in the air short of the bench (playtest 2026-11-03).
SCIENTISTS = [   # (the bench fronts: receiving z 4.0, the islands z 1.18, the hoods z -5.70)
    ("Sci 1", (L["tube_x"] + 0.35, FT, 3.80), (L["tube_x"] + 0.35, 1.2, 4.6), (L["tube_x"] + 0.35, 1.04, 4.06)),
    ("Sci 2", (-5.2, FT, 1.38), (-5.2, 1.0, 0.4), (-5.2, 0.99, 1.12)),
    ("Sci 3", (-7.5, FT, -5.50), (-7.5, 1.25, -6.4), (-7.5, 1.00, -5.76)),
    ("Sci 4", (3.0, FT, 1.38), (3.0, 1.0, 0.4), (3.0, 0.99, 1.12)),
]


def floor_shading(K):
    """Contact shading on the floor, baked into its vertex colours: darker
    under and against every bench, cabinet and wall foot, as the eye expects
    a room's corners to be (no light reaches there; the engine's AO is screen
    space and thin)."""
    P = K.room.parts["LabFloor"][0][0]
    C = K.room.cols["LabFloor"][0]
    rects = []
    for (c, sz, q) in K.sh.boxes:
        if sz[0] > 15 or c[1] - sz[1] / 2 > FT + 0.3 or sz[1] < 0.3:
            continue
        rects.append((c[0] - sz[0] / 2, c[0] + sz[0] / 2, c[2] - sz[2] / 2, c[2] + sz[2] / 2))
    x, z = P[:, 0], P[:, 2]
    occ = np.ones(len(P))
    for (x0, x1, z0, z1) in rects:
        dx = np.maximum(np.maximum(x0 - x, x - x1), 0)
        dz = np.maximum(np.maximum(z0 - z, z - z1), 0)
        d = np.hypot(dx, dz)
        occ *= 1 - 0.42 * np.exp(-(d / 0.22) ** 2)
    dw = np.minimum(XI - np.abs(x), ZI - np.abs(z))
    occ *= 1 - 0.22 * np.exp(-(dw / 0.25) ** 2)
    K.room.cols["LabFloor"][0] = C * occ[:, None]


def details(K):
    """A lab people work in: notes and a mug, sample bags waiting with their
    labels, a spectrum on a desk monitor, a clipboard, a plant by the board."""
    m, g = K.furn, K.glass
    rng = np.random.default_rng(77)

    def paper(x, y, z, ang, w=0.21, d=0.297, col=(0.93, 0.93, 0.90)):
        r = (math.cos(ang), 0.0, math.sin(ang))
        cuboid(m, (x, y + 0.0015, z), r, (0, 0, 0), w, 0.003, d, col=col, mat="LabWall") if False else None
        M = np.array([[math.cos(ang), 0, math.sin(ang)], [0, 1, 0], [-math.sin(ang), 0, math.cos(ang)]])
        m.color = col
        box(m, "LabWall", (x, y + 0.0015, z), (w, 0.002, d), M=M)

    def mug(x, y, z, col):
        Tb(m, "LabWall", col, (x, y, z), (x, y + 0.095, z), 0.041, segs=16)
        Tb(m, "LabResin", (0.10, 0.06, 0.03), (x, y + 0.08, z), (x, y + 0.083, z), 0.036, segs=16)
        for a0, a1 in ((0.0, 0.74), (0.86, 1.54), (1.66, 2.34), (2.46, 3.14)):
            pa = (x + 0.041 + 0.024 * math.sin(a0), y + 0.048 + 0.028 * math.cos(a0), z)
            pb = (x + 0.041 + 0.024 * math.sin(a1), y + 0.048 + 0.028 * math.cos(a1), z)
            Tb(m, "LabWall", col, pa, pb, 0.006, segs=6)

    def bag(x, y, z, ang, fill):
        M = np.array([[math.cos(ang), 0, math.sin(ang)], [0, 1, 0], [-math.sin(ang), 0, math.cos(ang)]])
        m.color = fill
        box(m, "LabResin", (x, y + 0.012, z), (0.10, 0.02, 0.15), M=M, bevel=0.01)
        m.color = (0.85, 0.88, 0.90)
        box(m, "LabWall", (x, y + 0.004, z), (0.12, 0.006, 0.18), M=M)
        m.color = (0.96, 0.96, 0.94)
        box(m, "LabWall", (x + 0.02 * math.sin(ang), y + 0.0235, z + 0.02 * math.cos(ang)), (0.07, 0.002, 0.04), M=M)
        m.color = (0.80, 0.12, 0.08)
        box(m, "LabWall", (x - 0.055 * math.sin(ang), y + 0.0075, z - 0.055 * math.cos(ang)), (0.12, 0.004, 0.012), M=M)

    # the island benches: notes, a mug, a desk monitor showing a spectrum
    paper(-6.4, 0.90, 0.92, 0.25)
    paper(-6.2, 0.903, 0.98, -0.15, col=(0.95, 0.93, 0.80))
    paper(1.4, 0.90, -0.25, 0.6)
    mug(-3.0, 0.90, 0.95, (0.15, 0.30, 0.55))
    mug(4.6, 0.90, -0.30, (0.85, 0.85, 0.82))
    mx, mz = -2.9, -0.20
    Bx(m, "LabResin", (0.12, 0.12, 0.13), mx - 0.12, mx + 0.12, 0.90, 0.91, mz - 0.10, mz + 0.06)
    Bx(m, "LabResin", (0.12, 0.12, 0.13), mx - 0.02, mx + 0.02, 0.91, 1.12, mz - 0.03, mz)
    screen(m, "l_s_xrf", (mx, 1.30, mz - 0.03), (-1, 0, 0), (0, 0.99, 0.12), 0.52)
    m.color = (0.95, 0.85, 0.25)
    for k, (dx, dy) in enumerate(((0.24, 0.12), (0.24, 0.03))):
        box(m, "LabWall", (mx + dx * 1.05, 1.30 + dy, mz - 0.048), (0.06, 0.06, 0.002))
    # the receiving counter: sample bags waiting, labelled, a pen
    tx = L["tube_x"]
    for i, (dx, dz, a, f) in enumerate(((0.55, 4.22, 0.1, (0.30, 0.13, 0.07)), (0.70, 4.30, -0.2, (0.22, 0.22, 0.23)),
                                          (0.95, 4.20, 0.3, (0.40, 0.30, 0.18)), (-0.55, 4.25, -0.1, (0.10, 0.10, 0.11)))):
        bag(tx + dx, 0.95, dz, a, f)
    paper(tx - 0.95, 0.952, 4.35, 0.1)
    Tb(m, "LabResin", (0.05, 0.08, 0.25), (tx - 0.9, 0.957, 4.30), (tx - 0.78, 0.957, 4.36), 0.004, segs=6)
    # a clipboard on a hook by the hoods, a pair of safety glasses on the bench
    Bx(m, "LabResin", (0.30, 0.22, 0.12), -4.62, -4.60, 1.25, 1.58, -ZI + 0.02, -ZI + 0.25)
    Bx(m, "LabWall", (0.94, 0.94, 0.92), -4.60, -4.598, 1.27, 1.52, -ZI + 0.04, -ZI + 0.23)
    Tb(m, "LabResin", (0.05, 0.05, 0.05), (-5.4, 0.915, 0.95), (-5.28, 0.915, 0.95), 0.005, segs=6)
    m.color = (0.85, 0.90, 0.95)
    box(g, "LabGlass", (-5.34, 0.93, 0.95), (0.13, 0.04, 0.003))
    # a plant on the end of the sink bench: a pot, its soil, a fan of leaves
    px, pz = 1.05, -ZI + 0.38
    Tb(m, "LabWall", (0.55, 0.30, 0.20), (px, 0.90, pz), (px, 1.05, pz), 0.085, segs=18, r1=0.10)
    Tb(m, "LabResin", (0.10, 0.07, 0.05), (px, 1.036, pz), (px, 1.043, pz), 0.093, segs=18)
    for i in range(16):
        a = i * 2.4 + rng.uniform(-0.2, 0.2)
        up = rng.uniform(0.45, 1.1)
        Lf = rng.uniform(0.18, 0.32)
        d = np.array([math.cos(a) * math.cos(up), math.sin(up), math.sin(a) * math.cos(up)])
        side = np.cross(d, [0, 1, 0]); side /= max(np.linalg.norm(side), 1e-6)
        nrm = np.cross(side, d)
        c = np.array([px, 1.05, pz]) + d * Lf / 2
        M = np.column_stack([side, d, nrm])
        if np.linalg.det(M) < 0:
            M = np.column_stack([-side, d, nrm])
        m.color = (0.10 + 0.06 * rng.random(), 0.28 + 0.12 * rng.random(), 0.08)
        box(m, "LabWall", tuple(c), (0.045, Lf, 0.004), M=M)


def visible_only(m):
    """A copy for the z-fight check without the faces nobody can see: what
    stands on the floor's own faces down onto it, what meets the ceiling its
    faces up into it (the floor and the ceiling are one sheet each, and every
    foot and every hanger's top would otherwise "fight" every other)."""
    out = CModel()
    out.ground = False
    out.__dict__["where"] = m.__dict__.get("where", {})
    for mat, (Ps, Ns, UVs, Is, _) in m.parts.items():
        P = np.vstack(Ps); I = np.vstack(Is); T_ = np.concatenate(m.tags[mat])
        A, Bv, C = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
        n = np.cross(Bv - A, C - A)
        ln = np.linalg.norm(n, axis=1) + 1e-12
        n = n / ln[:, None]
        cy = (A[:, 1] + Bv[:, 1] + C[:, 1]) / 3
        cx = (A[:, 0] + Bv[:, 0] + C[:, 0]) / 3
        cz = (A[:, 2] + Bv[:, 2] + C[:, 2]) / 3
        hide = ((n[:, 1] < -0.99) & (cy < FT + 0.003)) | ((n[:, 1] > 0.99) & (cy > CY - 0.012))
        # faces on the lining's back plane, facing the shell's wall
        hide |= (np.abs(n[:, 0]) > 0.99) & (np.abs(cx) > XI - 0.001) & (np.sign(n[:, 0]) == np.sign(cx))
        hide |= (np.abs(n[:, 2]) > 0.99) & (np.abs(cz) > ZI - 0.001) & (np.sign(n[:, 2]) == np.sign(cz))
        keep = ~hide
        if not keep.any():
            continue
        out.parts[mat] = ([P], [np.vstack(Ns)], [np.vstack(UVs)], [I[keep]], None)
        out.tags[mat] = [T_[keep]]
        out.cols[mat] = [np.vstack(m.cols[mat])]
    return out


def main():
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    if dry:
        signs()
    else:
        textures()
    K = Lab()
    lamps = room(K)
    partitions(K)
    hoods(K)
    safety_station(K)
    sink_bench(K)
    island(K, -8.2, -2.2, -0.45, 1.15, 11, scope_at=(-5.2, 0.62))
    island(K, 0.2, 6.0, -0.45, 1.15, 12, scope_at=(3.0, 0.95) if False else None)
    microscope(K.furn, 3.0, 0.90, 1.05 - 0.25, face=(0, 0, 1))
    wall_bench(K)
    tube_pts = receiving(K)
    instruments(K)
    west_east(K)
    details(K)
    floor_shading(K)
    D = doors(K)
    fights = 0
    allm = CModel()
    for name, m in (("room", K.room), ("furniture", K.furn), ("glass", K.glass)):
        fights += zcheck(visible_only(m), name)
        allm.merge(m)
        print(f"{name:10s} {m.tris():7d} tris  {','.join(sorted(m.parts))}")
    fights += zcheck(visible_only(allm), "lab interior (all parts)")
    base_tex.signs()
    shell, _, _, _ = base_buildings.lab()[:4]
    print(f"{len(K.sh.boxes)} walkable boxes, {len(lamps)} ceiling panels")
    if fights:
        print(f"!! {fights} z-fighting face pairs: nothing written")
        sys.exit(1)
    # the shell's box centre: FacLab's origin, and so LabInterior's
    mn, mx = shell.bounds()
    origin = (mn + mx) / 2
    print("origin (FacLab's box centre):", np.round(origin, 3))
    if dry:
        return
    out = [f'''// LAB INTERIOR — the Research Lab's rooms (tools/gen_lab.py; edit the generator, not this file).
// Same origin as FacLab (its box centre): spawn both with one position and rotation.
// scripts/lab.lua (on FacLab) switches this whole node on only while the crew is in or near the lab.
[
    (
        name: "LabInterior",
        tags: ["lab_interior"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
    ),
''']
    for name, m in (("LabRoom", K.room), ("LabFurniture", K.furn), ("LabGlass", K.glass)):
        mn_, mx_ = m.bounds()
        c = (mn_ + mx_) / 2
        glb = name.lower() + ".glb"
        write_glb(m.shifted(c), os.path.join(MODELS, glb))
        extra = "        cast_shadow: false,\n" if name == "LabGlass" else ""
        out.append(mesh_node(name, glb, m, c - origin, extra=extra))
    for name, (m, pos, axis, s) in D.items():
        mn_, mx_ = m.bounds()
        c = (mn_ + mx_) / 2
        glb = name.lower().replace(" ", "_") + ".glb"
        write_glb(m.shifted(c), os.path.join(MODELS, glb))
        out.append(mesh_node(name, glb, m, np.asarray(pos) + c - origin))
    # markers: the tube's path inside, the receiver, the scientists' spots
    for (nm, p) in (("Tube P0", tube_pts["in"]), ("Tube P1", tube_pts["p1"]), ("Tube P2", tube_pts["p2"]),
                    ("Tube End", tube_pts["end"])):
        out.append(empty_node(nm, np.asarray(p, float) - origin))
    for (nm, spot, look, hands) in SCIENTISTS:
        out.append(empty_node(nm, np.asarray(spot, float) - origin))
        out.append(empty_node(nm + " Look", np.asarray(look, float) - origin))
        out.append(empty_node(nm + " Hands", np.asarray(hands, float) - origin))
    # light: a soft grid of real lights under the ceiling panels (the panels
    # themselves glow), a spot into each room behind glass
    # (at 2.7 m, below the ceiling, so they reach the walls and the faces of
    # whoever stands at a bench, not only the floor under them)
    LIGHTS = [((-7.5, 2.7, -3.0), 2.1, 11.0, None), ((-7.6, 2.6, 5.3), 2.2, 9.0, (1.0, 0.88, 0.74)),
              ((-1.5, 2.7, -1.2), 2.1, 11.0, None), ((-1.0, 2.4, 5.6), 1.9, 8.0, (1.0, 0.88, 0.74)),
              ((4.0, 2.7, 2.2), 2.0, 10.0, None), ((6.0, 2.7, -4.3), 2.0, 9.0, None),
              ((8.4, 2.7, 5.0), 1.5, 7.0, None), ((-9.8, 2.2, -0.4), 1.4, 7.0, None)]
    for i, (p, inten, rng, col) in enumerate(LIGHTS):
        out.append(light_node(f"Lab Light {i + 1}", np.asarray(p) - origin, col or (1.0, 0.955, 0.90), inten, rng))
    # THE SOLIDS: every bench, partition, cabinet and instrument as a static
    # box body ("LabSolid N"; the scientists carry their own capsules,
    # prefabs/LabScientist). Children of LabInterior's root that scripts/lab.lua
    # never switches off (it switches the drawn children only): a collider
    # whose node is switched off is parked by the engine and, on a planet on
    # its rails, comes back where the planet was when it left (2026-11-03:
    # walking through the lab's benches). Boxes, not one mesh: the cheapest
    # shape for the walker and for the talk camera's casts. cast_shadow off:
    # a body is a shadow proxy otherwise.
    for i, (c, s, q) in enumerate(K.sh.boxes):
        out.append(solid_node(f"LabSolid {i + 1}", np.asarray(c, float) - origin, np.asarray(s, float) / 2))
    out.append("]\n")
    with open(os.path.join(PREFABS, "LabInterior.prefab.ron"), "w") as f:
        f.write("".join(out))
    # the clipboard a scientist reads (scripts/scientist.lua holds it)
    cb = CModel(520); cb.ground = False
    Bx(cb, "LabResin", (0.36, 0.25, 0.14), -0.115, 0.115, -0.16, 0.16, -0.003, 0.003)
    Bx(cb, "LabWall", (0.95, 0.95, 0.93), -0.105, 0.105, -0.15, 0.13, 0.003, 0.0045)
    for i in range(9):
        Bx(cb, "LabWall", (0.35, 0.36, 0.40), -0.085, 0.085 - (0.05 if i % 3 == 2 else 0.0), 0.09 - i * 0.025, 0.093 - i * 0.025,
           0.0045, 0.0050)
    Bx(cb, "LabSteel", STEEL, -0.045, 0.045, 0.125, 0.16, 0.003, 0.012)
    mn_, mx_ = cb.bounds()
    write_glb(cb.shifted((mn_ + mx_) / 2), os.path.join(MODELS, "clipboard.glb"))
    with open(os.path.join(PREFABS, "LabClipboard.prefab.ron"), "w") as f:
        f.write("// LAB CLIPBOARD — read by a Research Lab scientist (tools/gen_lab.py; scripts/scientist.lua places it).\n[\n"
                + mesh_node("LabClipboard", "clipboard.glb", cb, (0, 0, 0)).replace("        parent: Some(0),\n", "") + "]\n")
    # the capsule
    cm = capsule()
    mn_, mx_ = cm.bounds()
    write_glb(cm.shifted((mn_ + mx_) / 2), os.path.join(MODELS, "capsule.glb"))
    with open(os.path.join(PREFABS, "LabCapsule.prefab.ron"), "w") as f:
        f.write("// LAB CAPSULE — a pneumatic sample capsule (tools/gen_lab.py); scripts/lab.lua moves it up the tube.\n[\n"
                + mesh_node("LabCapsule", "capsule.glb", cm, (0, 0, 0)).replace("        parent: Some(0),\n", "") + "]\n")
    print("wrote models/lab/*.glb, prefabs/LabInterior.prefab.ron, prefabs/LabCapsule.prefab.ron")


if __name__ == "__main__":
    main()
