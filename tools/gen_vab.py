#!/usr/bin/env python3
"""Generate the VEHICLE ASSEMBLY BUILDING's interior: the high bay the craft
builder takes place in.

    python3 tools/gen_vab.py           # textures/vab/signs.png, models/vab/*.glb, prefabs/VabInterior
    python3 tools/gen_vab.py --dry     # sizes, chunks, tris, z-fight check

The shell is FacHangar (tools/base_buildings.py vab(), written by
tools/gen_base.py); both build from tools/vab_dims.py, and VabInterior's
origin IS FacHangar's (the slab's centre, vab_dims.ORIGIN), so the two are
spawned with the same position and rotation.

WHAT IS IN IT. A mobile launcher on six mounts in the middle of the floor,
the craft's build point on its deck. Five levels of work platforms down both
side walls (10.5 m to 52.5 m), each reached by a switchback stair tower in a
north corner. An overhead bridge crane on runway girders, parked at the north
end, its hook block hanging. Seven roof trusses with high-bay pendants, a
maintenance catwalk along them. Columns, girts, wainscot, cable trays, spiral
HVAC ducts with diffusers, electrical panels, fire points, personnel doors.
On the floor: a workshop (benches, pegboards, tool carts, cabinets, a gas
cage), pallet racking, two shipping containers, a glazed assembly-control
booth, a forklift, a scissor lift, an engine on its transport stand, a tank
section on cradles, work-light towers. Plated signs (textures/vab/signs.png,
set in the house label faces) and painted floor markings.

FADING. Everything that could come between the builder's camera and the craft
is a CHUNK: its own node ("Fade <name>") that scripts/vab_fade.lua thins away
by screen-door dither (the materials carry retro dither_alpha) when the camera
is near it or behind it. The floor markings (VabFloor) never fade. The chunk
boxes ride the root's script params, so the script needs no other data.

DRAW COST. Five materials (Concrete, Clad, Steel, Lamp, VabSign, and Glass on
the booth and the crane cab), meshes merged per chunk. Light: four high-bay
spots and one fill (the engine shades the 16 most important lights).

Prefab written: VabInterior.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base_tex  # noqa: E402
import vab_dims as V  # noqa: E402
from base_models import (B, CModel, CONC_DARK, CONT_BLUE, CONT_RED, DARK, GREY, GREYBLUE, LAMP_COOL,  # noqa: E402
                         LAMP_WARM, LIGHT, OCHRE, PAINT, RUBBER, RUST_ORANGE, SAFETY, SLATE, WARM, Shell, T,
                         cable_tray, cuboid, railing, stair, zcheck)
from gen_base import MATERIALS, dithered, f3, spot_rotation, write_glb  # noqa: E402
from gen_part_meshes import PREFABS, ROOT, box, lathe, rot_x  # noqa: E402

MODELS = os.path.join(ROOT, "models", "vab")
TEXDIR = os.path.join(ROOT, "textures", "vab")
TEX = "textures/vab/"

# ── the sign atlas ──────────────────────────────────────────────────────────

ATLAS_W, ATLAS_H = 1024, 1536
PIX = {}      # region -> (w, h) in pixels, for plate aspect


def _pack(img, items):
    """Shelf packing, tallest first; regions go into base_tex.REGIONS as
    "v_<name>" so base_models.cuboid can face a box with them."""
    x, y, row = 4, 4, 0
    for name, tile in sorted(items, key=lambda t: -t[1].size[1]):
        w, h = tile.size
        if x + w + 4 > ATLAS_W:
            x, y, row = 4, y + row + 6, 0
        assert y + h <= ATLAS_H, "the VAB sign atlas is full: %d" % (y + h)
        img.paste(tile, (x, y))
        base_tex.REGIONS["v_" + name] = ((x + 0.5) / ATLAS_W, (y + 0.5) / ATLAS_H,
                                         (x + w - 0.5) / ATLAS_W, (y + h - 0.5) / ATLAS_H)
        PIX["v_" + name] = (w, h)
        x += w + 6
        row = max(row, h)


def _stencil_on_concrete(text, w, h, seed, ink=(0.86, 0.80, 0.42), size=None):
    """Stencilled paint on the floor's own concrete, worn through in places."""
    from gen_part_textures import smoothstep, spectral
    con = np.asarray(Image.open(os.path.join(base_tex.OUT, "concrete_albedo.png")), np.float32) / 255
    reps = (h // con.shape[0] + 1, w // con.shape[1] + 1, 1)
    tile = np.tile(con, reps)[:h, :w] * np.array([0.93, 0.92, 0.90])
    mask = Image.new("L", (w, h), 0)
    f = ImageFont.truetype(base_tex.FONT_STENCIL, size or int(h * 0.74))
    d = ImageDraw.Draw(mask)
    tb = d.textbbox((0, 0), text, font=f)
    d.text(((w - (tb[2] - tb[0])) / 2 - tb[0], (h - (tb[3] - tb[1])) / 2 - tb[1]), text, font=f, fill=255)
    rng = np.random.default_rng(seed)
    m = np.asarray(mask, np.float32) / 255
    wear = np.asarray(Image.fromarray((spectral(256, 256, rng, beta=1.2, lo=8) * 255).astype(np.uint8)).resize((w, h)),
                      np.float32) / 255
    m *= 0.5 + 0.5 * smoothstep(0.25, 0.6, wear)
    out = tile * (1 - m[..., None]) + m[..., None] * np.array(ink)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def _paint_line(rgb, seed, w=64, h=64):
    """A strip of floor paint: a flat colour, scuffed and worn."""
    img = Image.new("RGB", (w, h), rgb)
    return base_tex.wear(img, seed, amount=0.30)


def _pegboard(seed):
    """A tool board: perforated hardboard, painted outlines, the tools hung."""
    w, h = 384, 192
    img = Image.new("RGB", (w, h), (118, 112, 100))
    d = ImageDraw.Draw(img)
    for yy in range(6, h, 12):
        for xx in range(6, w, 12):
            d.ellipse([xx - 1.5, yy - 1.5, xx + 1.5, yy + 1.5], fill=(70, 66, 58))
    ink, steel, grip = (40, 40, 40), (150, 152, 152), (150, 40, 30)
    # hammer, wrenches, screwdrivers, pliers, a saw — outline then tool
    for k, x0 in enumerate((24, 70, 104, 136, 168)):
        L = 70 + 10 * (k % 3)
        d.rounded_rectangle([x0 - 7, 30, x0 + 7, 30 + L], 5, outline=ink, width=3)
        d.rectangle([x0 - 4, 33, x0 + 4, 30 + L - 3], fill=steel)
        d.ellipse([x0 - 9, 22, x0 + 9, 40], fill=steel, outline=ink, width=2)
    for k, x0 in enumerate((210, 236, 262)):
        d.rectangle([x0 - 4, 30, x0 + 4, 80], fill=grip, outline=ink)
        d.line([x0, 80, x0, 130], fill=steel, width=4)
    d.polygon([(292, 30), (352, 30), (360, 110), (300, 110)], fill=(170, 172, 170), outline=ink)
    d.rectangle([316, 18, 340, 34], fill=grip, outline=ink)
    d.rectangle([24, 140, 160, 180], fill=(72, 74, 78), outline=ink)
    d.text((32, 146), "SHADOW BOARD 3", font=ImageFont.truetype(base_tex.FONT_LABEL, 24), fill=(230, 222, 200))
    return base_tex.wear(img, seed, amount=0.18)


def signs():
    os.makedirs(TEXDIR, exist_ok=True)
    SL, FG = base_tex.SLATE_BG, base_tex.PLATE_FG
    YEL, INK = (206, 164, 40), (24, 22, 20)
    RED, WHT = (150, 34, 26), (226, 226, 220)
    BLU, GRN = (34, 74, 140), (36, 110, 60)
    P = base_tex.plate
    items = [
        ("highbay", P("HIGH BAY 1", 520, 96, SL, FG, seed=101)),
        ("control", P("ASSEMBLY CONTROL", 420, 72, SL, FG, seed=102)),
        ("crane", P("BRIDGE CRANE 1 — SWL 250 t", 560, 80, YEL, INK, border=INK, seed=103)),
        ("hardhat", P("HARD HATS MUST BE WORN", 420, 84, BLU, WHT, border=WHT, seed=104)),
        ("noflame", P("NO SMOKING · NO NAKED FLAMES", 460, 84, WHT, RED, border=RED, seed=105)),
        ("exit", P("EXIT", 200, 72, GRN, WHT, seed=106)),
        ("fire", P("FIRE POINT", 200, 72, RED, WHT, seed=107)),
        ("keepclear", P("KEEP CLEAR — VEHICLE MOVEMENTS", 520, 80, YEL, INK, border=INK, seed=108)),
        ("hv", P("DANGER — HIGH VOLTAGE", 360, 84, YEL, INK, border=INK, seed=109)),
        ("stair1", P("STAIR 1", 200, 84, SL, FG, seed=110)),
        ("stair2", P("STAIR 2", 200, 84, SL, FG, seed=111)),
        ("ml1", P("ML-1", 300, 120, SL, FG, font=base_tex.FONT_STENCIL, seed=112)),
        ("forks", P("FORKLIFT ROUTE", 300, 72, YEL, INK, border=INK, seed=113)),
        ("gas", P("COMPRESSED GAS", 300, 72, WHT, INK, border=INK, seed=114)),
        ("flam", P("FLAMMABLE", 260, 72, YEL, RED, border=RED, seed=115)),
        ("lift", P("SWL 450 kg", 220, 60, YEL, INK, seed=116)),
        ("hazard", base_tex.hazard(256, 48, 117)),
        ("emblem", base_tex.emblem(256, seed=118)),
        ("floor_bay", _stencil_on_concrete("HIGH BAY 1", 640, 128, 119)),
        ("floor_ml", _stencil_on_concrete("ML-1", 256, 128, 120, ink=(0.84, 0.84, 0.80))),
        ("yellow", _paint_line((206, 164, 40), 121)),
        ("white", _paint_line((214, 214, 206), 122)),
        ("green", _paint_line((52, 120, 70), 123)),
        ("pegboard", _pegboard(124)),
    ]
    for k, lv in enumerate(V.LEVELS):
        items.append((f"lvl{k + 1}", P(f"PLATFORM {chr(65 + k)}", 300, 96, SL, FG, sub=f"EL. +{lv:.1f} M", seed=130 + k)))
    img = Image.new("RGB", (ATLAS_W, ATLAS_H), (128, 128, 128))
    _pack(img, items)
    img.save(os.path.join(TEXDIR, "signs.png"), optimize=True)


def aspect(reg):
    w, h = PIX[reg]
    return h / w


# ── helpers ─────────────────────────────────────────────────────────────────

SIGN = "VabSign"


def vplate(m, reg, center, right, up, width, depth=0.04, back=DARK):
    """A plate standing `depth` proud of what it hangs on, its face the region."""
    h = width * aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float) + o * depth / 2
    g = m.ground
    m.ground = False
    cuboid(m, c, right, up, width, h, depth, faces={"front": (SIGN, (1, 1, 1), reg)}, col=back)
    m.ground = g
    return h


def mark(m, reg, cx, cz, w, d, top, rot=False, base=V.SLAB_Y1):
    """A painted mark: a flat slab from `base` up to `top` whose upper face is
    the region (rot: the region's long side runs along z)."""
    right, up = ((0, 0, -1), (-1, 0, 0)) if rot else ((1, 0, 0), (0, 0, -1))
    ww, dd = (d, w) if rot else (w, d)
    if base == V.SLAB_Y1:
        # floor paint: a 12 mm skin lifted 4 cm, so the slab never wins the
        # depth test at range (the engine's depth is standard-Z)
        top += 0.04
        base = top - 0.012
    th = top - base
    cuboid(m, (cx, base + th / 2, cz), right, up, ww, dd, th, faces={"front": (SIGN, (1, 1, 1), reg)}, col=DARK)


def beam(m, col, p0, p1, w, h, mat="Steel"):
    """A square-section member between two points (truss webs, braces)."""
    p0 = np.asarray(p0, float); p1 = np.asarray(p1, float)
    d = p1 - p0
    L = np.linalg.norm(d)
    r = d / L
    a = np.array([0, 0, 1.0]) if abs(r[2]) < 0.9 else np.array([1.0, 0, 0])
    up = np.cross(a, r); up /= np.linalg.norm(up)
    cuboid(m, (p0 + p1) / 2, r, up, L, w, h, mat=mat, col=col)


def wheel(m, c, axis, r, w, col=RUBBER):
    c = np.asarray(c, float); a = np.asarray(axis, float)
    T(m, "Steel", col, c - a * w / 2, c + a * w / 2, r, segs=12)


class Chunks:
    """The interior's fadeable parts, by name; each is its own CModel."""

    def __init__(self):
        self.m = {}
        self.seed = 300

    def __call__(self, name):
        if name not in self.m:
            self.m[name] = CModel(self.seed)
            self.seed += 1
        return self.m[name]


def zpart(z):
    return "N" if z < -8.4 else ("S" if z > 8.4 else "M")


ZSEG = {"N": (-V.IN_D, -8.4), "M": (-8.4, 8.4), "S": (8.4, V.IN_D)}


# ── the walls' inner faces ──────────────────────────────────────────────────

def walls(C, sh):
    for sx, side in ((1, "E"), (-1, "W")):
        xi = sx * V.IN_W
        for part, (za, zb) in ZSEG.items():
            m = C(f"Wall {side} {part}")
            # wainscot: a cast plinth along the foot of the wall
            B(m, "Concrete", CONC_DARK, xi - 0.25 * sx, xi + 0.1 * sx, -0.3, 2.6, za, zb)
            # girts between the columns, and the crane runway on its corbels
            for y in (8.0, 16.0, 24.0, 32.0, 40.0, 48.0):
                B(m, "Steel", GREY, xi - 0.3 * sx, xi + 0.08 * sx, y, y + 0.3, za, zb, var=False)
            B(m, "Steel", OCHRE, xi - 1.6 * sx, xi - 1.0 * sx, 57.4, 58.9, za, zb, var=False)
            B(m, "Steel", DARK, xi - 1.36 * sx, xi - 1.24 * sx, 58.9, V.CRANE_RAIL, za, zb, var=False)
            # cable trays, low and high
            cable_tray(m, (xi - 0.42 * sx, 6.6, za), (xi - 0.42 * sx, 6.6, zb))
            cable_tray(m, (xi - 0.42 * sx, 54.6, za), (xi - 0.42 * sx, 54.6, zb))
            # a spiral duct under the trusses, hung from them
            m.color = LIGHT
            T(m, "Steel", LIGHT, (xi - 3.2 * sx, 64.4, za), (xi - 3.2 * sx, 64.4, zb), 0.65, segs=14)
        for z in V.COL_Z:
            m = C(f"Wall {side} {zpart(z)}")
            # the column: an I section, flanges parallel to the wall
            B(m, "Steel", LIGHT, xi - 0.05 * sx, xi, 0.0, V.TRUSS_LO, z - 0.3, z + 0.3)
            B(m, "Steel", LIGHT, xi - 0.9 * sx, xi - 0.84 * sx, 0.0, V.TRUSS_LO, z - 0.3, z + 0.3)
            B(m, "Steel", LIGHT, xi - 0.84 * sx, xi - 0.05 * sx, 0.0, V.TRUSS_LO, z - 0.02, z + 0.02, var=False)
            B(m, "Steel", OCHRE, xi - 1.7 * sx, xi - 0.9 * sx, 56.4, 57.4, z - 0.32, z + 0.32, var=False)
            beam(m, OCHRE, (xi - 0.9 * sx, 53.5, z), (xi - 1.55 * sx, 56.4, z), 0.2, 0.2)
            # duct hangers off the truss
            if abs(z) < 23:
                T(m, "Steel", DARK, (xi - 3.2 * sx, 65.05, z), (xi - 3.2 * sx, V.TRUSS_LO, z), 0.03, segs=5)
            # a fire point on the column's face
            if abs(z) in (8.0, 16.0):
                xf = xi - 0.9 * sx
                T(m, "Steel", CONT_RED, (xf - 0.14 * sx, 0.9, z), (xf - 0.14 * sx, 1.55, z), 0.09, segs=10)
                vplate(m, "v_fire", (xf, 2.0, z), (0, 0, sx), (0, 1, 0), 0.55, depth=0.03)
        for z in (-4.0, 4.0):
            m = C(f"Wall {side} M")
            # electrical panels, a conduit up to the tray
            B(m, "Steel", SLATE, xi - 0.7 * sx, xi - 0.2 * sx, 0.5, 2.5, z - 0.7, z + 0.7)
            B(m, "Steel", DARK, xi - 0.72 * sx, xi - 0.7 * sx, 0.7, 2.3, z - 0.62, z - 0.02, var=False)
            B(m, "Steel", DARK, xi - 0.72 * sx, xi - 0.7 * sx, 0.7, 2.3, z + 0.02, z + 0.62, var=False)
            T(m, "Steel", GREY, (xi - 0.45 * sx, 2.5, z + 0.4), (xi - 0.45 * sx, 6.55, z + 0.4), 0.05, segs=6)
            vplate(m, "v_hv", (xi, 3.1, z), (0, 0, sx), (0, 1, 0), 1.1, depth=0.03)
        # high-bay lamps on the columns, aimed into the bay
        for z in (-8.0, 8.0):
            m = C(f"Wall {side} {zpart(z)}")
            for y in (30.0, 46.0):
                p = np.array([xi - 1.25 * sx, y, z])
                B(m, "Steel", DARK, xi - 0.9 * sx, xi - 1.0 * sx, y - 0.1, y + 0.1, z - 0.06, z + 0.06, var=False)
                from base_models import lamp_head
                lamp_head(m, p, (-0.6 * sx, -0.8, 0), w=0.7, h=0.45, col=LAMP_COOL)
        # personnel doors with their exit signs
        for z in (-12.0, 12.0):
            m = C(f"Wall {side} {zpart(z)}")
            B(m, "Steel", SLATE, xi - 0.33 * sx, xi - 0.25 * sx, 0.0, 2.35, z - 0.62, z + 0.62)
            for zz in (z - 0.7, z + 0.7):
                B(m, "Steel", DARK, xi - 0.36 * sx, xi - 0.25 * sx, 0.0, 2.45, zz - 0.08, zz + 0.08, var=False)
            B(m, "Steel", DARK, xi - 0.36 * sx, xi - 0.25 * sx, 2.37, 2.45, z - 0.62, z + 0.62, var=False)
            B(m, "Steel", GREY, xi - 0.4 * sx, xi - 0.33 * sx, 1.0, 1.06, z - 0.5, z - 0.1, var=False)
            g = m.ground; m.ground = False
            m.color = (0.30, 0.95, 0.45)
            box(m, "Lamp", (xi - 0.36 * sx, 2.85, z), (0.08, 0.26, 0.7))
            m.ground = g
            vplate(m, "v_exit", (xi - 0.4 * sx, 2.85, z), (0, 0, sx), (0, 1, 0), 0.62, depth=0.02)
        # the house rules by the doors
        m = C(f"Wall {side} S")
        vplate(m, "v_hardhat", (xi, 3.6, 20.0), (0, 0, sx), (0, 1, 0), 2.4, depth=0.03)
        m = C(f"Wall {side} N")
        vplate(m, "v_noflame", (xi, 3.7, -12.0), (0, 0, sx), (0, 1, 0), 2.4, depth=0.03)
    # the ends: the door jambs' inside, the inner face above the lower door
    for sz, side in ((1, "S"), (-1, "N")):
        m = C(f"End {side}")
        zi = sz * V.IN_D
        for s in (-1, 1):
            # the jamb's inside face, and a fender against the crawler
            B(m, "Steel", SLATE, s * V.LOW_W, s * (V.LOW_W + 0.6), 0.0, V.LOW_H, zi - 0.6 * sz, zi)
            B(m, "Steel", SAFETY, s * (V.LOW_W - 0.12), s * V.LOW_W, 0.0, 1.2, zi - 0.55 * sz, zi)
            B(m, "Steel", SLATE, s * V.SLOT_W, s * (V.SLOT_W + 0.5), V.LOW_H, V.SLOT_H, zi - 0.5 * sz, zi)
            # the wind girts over the inside of the door's shoulders
            for y in (28.0, 36.0, 44.0, 52.0, 60.0):
                B(m, "Steel", GREY, s * (V.SLOT_W + 0.5), s * (V.IN_W - 0.9), y, y + 0.3, zi - 0.3 * sz, zi + 0.08 * sz,
                  var=False)
            # the agency's roundel, painted on each shoulder
            from base_models import region
            u0, v0, u1, v1 = region("v_emblem")
            n = np.array([0, 0, -sz], float)
            c = np.array([s * 18.3, 40.0, zi - 0.32 * sz])
            segs, r = 40, 4.2
            ax = np.array([1.0, 0, 0]) * (-sz)
            ay = np.array([0, 1.0, 0])
            Pp, Nn, UV, I = [], [], [], []
            for i in range(segs):
                a = 2 * math.pi * i / segs
                x, y = math.cos(a), math.sin(a)
                Pp.append(c + ax * x * r + ay * y * r); Nn.append(n)
                UV.append((u0 + (u1 - u0) * (0.5 + 0.5 * x), v0 + (v1 - v0) * (0.5 - 0.5 * y)))
            Pp.append(c); Nn.append(n); UV.append(((u0 + u1) / 2, (v0 + v1) / 2))
            for i in range(segs):
                I.append((segs, i, (i + 1) % segs))
            m.color = (1, 1, 1)
            m.add(SIGN, Pp, Nn, UV, I)
        vplate(m, "v_keepclear", (0.0, V.LOW_H + 0.2, zi - 0.62 * sz), (-sz, 0, 0), (0, 1, 0), 9.0, depth=0.04)
        if sz > 0:
            vplate(m, "v_highbay", (-17.6, V.LOW_H + 2.6, zi), (-sz, 0, 0), (0, 1, 0), 6.0, depth=0.05)


# ── platforms and stair towers ──────────────────────────────────────────────

def platforms(C, sh):
    for sx, side in ((1, "E"), (-1, "W")):
        xa, xb = sx * V.PLAT_X0, sx * V.PLAT_X1
        for k, y in enumerate(V.LEVELS):
            for half, (z0, z1) in (("N", (V.PLAT_Z0, 0.0)), ("S", (0.0, V.PLAT_Z1))):
                m = C(f"Plat {side}{k + 1}")
                m.ground = False
                B(m, "Steel", GREY, xa, xb, y - 0.2, y, z0, z1, var=False, sh=sh)
                # the fascia: an edge stringer and a toe board
                B(m, "Steel", DARK, xa, xa + 0.3 * sx, y - 0.8, y - 0.2, z0, z1, var=False)
                B(m, "Steel", SAFETY, xa - 0.02 * sx, xa + 0.04 * sx, y, y + 0.16, z0, z1, var=False)
                railing(m, SAFETY, (xa + 0.12 * sx, y, z0 + 0.05), (xa + 0.12 * sx, y, z1 - 0.05), sh=sh)
                if half == "S":
                    railing(m, SAFETY, (xa + 0.12 * sx, y, z1 - 0.12), (xb - 0.02 * sx, y, z1 - 0.12), sh=sh)
                # cantilevers off the columns, with knee braces
                for zc in V.COL_Z:
                    if not (z0 <= zc < z1) or zc < V.PLAT_Z0 or zc > V.PLAT_Z1:
                        continue
                    B(m, "Steel", DARK, xa + 0.3 * sx, xb, y - 0.75, y - 0.2, zc - 0.14, zc + 0.14, var=False)
                    beam(m, DARK, (xb, y - 3.6, zc), (xa + 1.2 * sx, y - 0.75, zc), 0.18, 0.18)
                # lights under the deck, a work kit on it
                for zz in (z0 + (z1 - z0) * 0.3, z0 + (z1 - z0) * 0.7):
                    m.color = LAMP_COOL
                    box(m, "Lamp", ((xa + xb) / 2, y - 0.83, zz), (0.35, 0.05, 1.3))
                    B(m, "Steel", DARK, (xa + xb) / 2 - 0.25, (xa + xb) / 2 + 0.25, y - 0.8, y - 0.2, zz - 0.75, zz + 0.75,
                      var=False)
                zm = (z0 + z1) / 2
                vplate(m, f"v_lvl{k + 1}", (xa, y - 0.5, zm), (0, 0, sx), (0, 1, 0), 1.2, depth=0.03)
                kit = (k + (half == "S")) % 3
                xk = xb - 0.9 * sx
                if kit == 0:      # a tool chest
                    B(m, "Steel", CONT_RED, xk - 0.3, xk + 0.3, y, y + 0.9, zm + 2.0, zm + 3.1)
                    B(m, "Steel", DARK, xk - 0.31, xk + 0.31, y + 0.9, y + 0.95, zm + 1.98, zm + 3.12, var=False)
                elif kit == 1:    # a cable reel on its stand
                    T(m, "Steel", GREY, (xk, y + 0.55, zm - 2.5), (xk, y + 0.55, zm - 1.9), 0.55, segs=14)
                    T(m, "Steel", (0.12, 0.12, 0.13), (xk, y + 0.55, zm - 2.45), (xk, y + 0.55, zm - 1.95), 0.45, segs=14)
                    for zz in (zm - 2.6, zm - 1.8):
                        B(m, "Steel", DARK, xk - 0.4, xk + 0.4, y, y + 0.06, zz - 0.04, zz + 0.04, var=False)
                else:             # stacked transit cases
                    B(m, "Steel", SLATE, xk - 0.35, xk + 0.35, y, y + 0.5, zm - 1.0, zm + 0.2)
                    B(m, "Steel", CONT_BLUE, xk - 0.3, xk + 0.3, y + 0.5, y + 0.9, zm - 0.9, zm + 0.1)


def stair_towers(C, sh):
    rise = V.LEVELS[0] / 4.0          # four flights a level: 2.625 m each
    n = 4 * len(V.LEVELS)
    zN, zS = -22.9, -19.0            # the flights run between the landings
    for sx, side, reg in ((1, "E", "v_stair1"), (-1, "W", "v_stair2")):
        xa, xb = sx * V.PLAT_X0, sx * V.PLAT_X1
        lane = {0: sx * (V.PLAT_X1 - 1.15), 1: sx * (V.PLAT_X0 + 1.15)}
        for k in range(n):
            y0, y1 = rise * k, rise * (k + 1)
            m = C(f"Stair {side} {'Lo' if y1 <= 21.0 + 1e-6 else 'Hi'}")
            m.ground = y0 < 1.0
            if k % 2 == 0:
                stair(m, (lane[0], y0 + 0.02, zS), (lane[0], y1 - 0.14, zN), 1.3, sh=sh)
            else:
                stair(m, (lane[1], y0 + 0.02, zN), (lane[1], y1 - 0.14, zS), 1.3, sh=sh)
            # the landing this flight arrives at
            za, zb = ((V.STAIR_Z0, zN) if k % 2 == 0 else (zS, V.STAIR_Z1))
            B(m, "Steel", GREY, xa, xb, y1 - 0.15, y1, za, zb, var=False, sh=sh)
            B(m, "Steel", DARK, xa, xb, y1 - 0.45, y1 - 0.15, za + 0.05, za + 0.25, var=False)
            railing(m, SAFETY, (xa + 0.06 * sx, y1, za + 0.05), (xa + 0.06 * sx, y1, zb - 0.05), sh=sh)
            if k % 2 == 0:
                railing(m, SAFETY, (xa + 0.06 * sx, y1, za + 0.05), (xb - 0.04 * sx, y1, za + 0.05), sh=sh)
            elif (k + 1) % 4:
                # a half landing, not a platform: rail its open south side
                railing(m, SAFETY, (xa + 0.06 * sx, y1, zb - 0.05), (xb - 0.04 * sx, y1, zb - 0.05), sh=sh)
        # the tower frame: four posts, X bracing on the bay side
        for part, (ya, yb) in (("Lo", (0.0, 22.6)), ("Hi", (22.6, V.LEVELS[-1] + 1.2))):
            m = C(f"Stair {side} {part}")
            for (x, z) in ((xa, V.STAIR_Z0), (xb, V.STAIR_Z0), (xa, V.STAIR_Z1), (xb, V.STAIR_Z1)):
                T(m, "Steel", GREY, (x, ya, z), (x, yb, z), 0.11, segs=8)
            y = ya
            while y < yb - 1.0:
                y2 = min(y + rise * 2, yb)
                beam(m, GREY, (xa, y + 0.2, V.STAIR_Z0 + 0.1), (xa, y2 - 0.2, V.STAIR_Z1 - 0.1), 0.09, 0.09)
                beam(m, GREY, (xa - 0.1 * sx, y + 0.2, V.STAIR_Z1 - 0.1), (xa - 0.1 * sx, y2 - 0.2, V.STAIR_Z0 + 0.1),
                     0.09, 0.09)
                y = y2
        m = C(f"Stair {side} Lo")
        vplate(m, reg, (xa - 0.12 * sx, 2.2, V.STAIR_Z1), (-sx, 0, 0), (0, 1, 0), 0.8, depth=0.03)


# ── the mobile launcher ─────────────────────────────────────────────────────

def mobile_launcher(C, sh):
    m = C("ML")
    hx, hz, top = V.ML_HX, V.ML_HZ, V.ML_TOP
    base = top - 1.6
    for (x, z) in ((-9.0, -7.0), (0.0, -7.0), (9.0, -7.0), (-9.0, 7.0), (0.0, 7.0), (9.0, 7.0)):
        B(m, "Concrete", CONC_DARK, x - 1.1, x + 1.1, 0.0, base - 0.12, z - 1.1, z + 1.1, sh=sh)
        B(m, "Steel", DARK, x - 0.9, x + 0.9, base - 0.12, base, z - 0.9, z + 0.9, var=False)
    B(m, "Steel", LIGHT, -hx, hx, base, top, -hz, hz, sh=sh)
    # stiffeners down the sides
    for x in np.arange(-hx + 1.0, hx - 0.5, 2.0):
        for sz in (-1, 1):
            B(m, "Steel", GREY, x - 0.08, x + 0.08, base + 0.1, top - 0.1, sz * hz, sz * (hz + 0.08), var=False)
    for z in np.arange(-hz + 1.0, hz - 0.5, 2.0):
        for sx in (-1, 1):
            B(m, "Steel", GREY, sx * hx, sx * (hx + 0.08), base + 0.1, top - 0.1, z - 0.08, z + 0.08, var=False)
    # the deck: hazard-painted edge, the hold-down plate the craft stands on
    t = top + 0.03
    for sz in (-1, 1):
        mark(m, "v_hazard", 0.0, sz * (hz - 0.3), 2 * hx - 1.2, 0.5, t, base=top)
    for sx in (-1, 1):
        mark(m, "v_hazard", sx * (hx - 0.3), 0.0, 0.5, 2 * hz, t, rot=True, base=top)
    B(m, "Steel", SLATE, -3.5, 3.5, top, top + 0.02, -3.5, 3.5, var=False)
    for k in range(-3, 4):
        B(m, "Steel", DARK, -3.3, 3.3, top + 0.02, top + 0.035, k - 0.04, k + 0.04, var=False)
    for (x, z) in ((-2.9, -2.9), (2.9, -2.9), (2.9, 2.9), (-2.9, 2.9)):
        B(m, "Steel", OCHRE, x - 0.25, x + 0.25, top + 0.02, top + 0.32, z - 0.25, z + 0.25, var=False)
    vplate(m, "v_ml1", (0.0, base + 0.8, hz + 0.08), (1, 0, 0), (0, 1, 0), 2.6, depth=0.04)
    vplate(m, "v_ml1", (0.0, base + 0.8, -hz - 0.08), (-1, 0, 0), (0, 1, 0), 2.6, depth=0.04)
    # stairs up on both sides, and the umbilical service boxes on the deck
    for sx in (-1, 1):
        stair(m, (sx * (hx + 3.75), V.SLAB_Y1 + 0.02, 4.0), (sx * (hx + 0.1), top - 0.14, 4.0), 1.2, sh=sh)
        B(m, "Steel", GREYBLUE, sx * (hx - 2.6), sx * (hx - 1.0), top, top + 1.4, -hz + 1.2, -hz + 2.6)
        B(m, "Steel", DARK, sx * (hx - 2.62), sx * (hx - 2.6), top + 0.3, top + 1.2, -hz + 1.4, -hz + 2.4, var=False)
        T(m, "Steel", DARK, (sx * (hx - 1.8), top + 0.7, -hz + 2.6), (sx * 3.6, top + 0.12, -hz + 6.5), 0.07, segs=6)


# ── the bridge crane ────────────────────────────────────────────────────────

def crane(C, sh):
    m = C("Crane")
    m.ground = False
    zc = -16.0
    xr = V.IN_W - 1.3                     # the rail line
    y0 = V.CRANE_RAIL
    for sx in (-1, 1):
        # end trucks riding the rails, with their wheels and buffers
        B(m, "Steel", OCHRE, sx * (xr - 0.6), sx * (xr + 0.6), y0 + 0.4, y0 + 1.6, zc - 3.2, zc + 3.2)
        for zz in (zc - 2.4, zc + 2.4):
            wheel(m, (sx * xr, y0 + 0.4, zz), (1, 0, 0), 0.38, 0.3, col=DARK)
            T(m, "Steel", RUBBER, (sx * xr, y0 + 1.0, zz + (0.8 if zz > zc else -0.8)),
              (sx * xr, y0 + 1.0, zz + (1.3 if zz > zc else -1.3)), 0.22, segs=10)
    for sz in (-1, 1):
        B(m, "Steel", OCHRE, -xr + 0.6, xr - 0.6, y0 + 0.6, y0 + 3.2, zc + sz * 1.0, zc + sz * 1.9)
        for x in np.arange(-xr + 2.0, xr - 1.0, 3.0):     # web stiffeners
            B(m, "Steel", OCHRE, x - 0.05, x + 0.05, y0 + 0.7, y0 + 3.1, zc + sz * 1.9, zc + sz * 1.96, var=False)
    # the walkway along the south girder
    B(m, "Steel", GREY, -xr + 0.6, xr - 0.6, y0 + 3.2, y0 + 3.3, zc + 1.9, zc + 3.0, var=False, sh=sh)
    railing(m, SAFETY, (-xr + 0.7, y0 + 3.3, zc + 2.95), (xr - 0.7, y0 + 3.3, zc + 2.95), sh=sh)
    vplate(m, "v_crane", (2.0, y0 + 1.9, zc + 1.96), (1, 0, 0), (0, 1, 0), 9.0, depth=0.04)
    vplate(m, "v_crane", (2.0, y0 + 1.9, zc - 1.96), (-1, 0, 0), (0, 1, 0), 9.0, depth=0.04)
    # the trolley and its hoist
    xt = -5.0
    B(m, "Steel", OCHRE, xt - 3.0, xt + 3.0, y0 + 3.2, y0 + 3.9, zc - 2.1, zc + 1.8)
    T(m, "Steel", GREY, (xt - 2.2, y0 + 4.6, zc - 0.4), (xt + 2.2, y0 + 4.6, zc - 0.4), 0.65, segs=16)
    B(m, "Steel", DARK, xt + 2.3, xt + 2.9, y0 + 3.9, y0 + 5.0, zc - 1.2, zc + 0.4)
    # four falls of rope down to the hook block
    yb = 44.0
    for dx in (-0.35, 0.35):
        for dz in (-0.25, 0.25):
            T(m, "Steel", DARK, (xt + dx, y0 + 3.2, zc + dz), (xt + dx, yb + 1.2, zc + dz), 0.025, segs=4)
    B(m, "Steel", OCHRE, xt - 0.7, xt + 0.7, yb, yb + 1.3, zc - 0.45, zc + 0.45)
    for dx in (-0.35, 0.35):
        T(m, "Steel", DARK, (xt + dx, yb + 0.9, zc - 0.5), (xt + dx, yb + 0.9, zc + 0.5), 0.3, segs=12)
    T(m, "Steel", DARK, (xt, yb, zc), (xt, yb - 0.7, zc), 0.12, segs=8)
    # the hook: a shank and a bent bill
    pts = [(xt, yb - 0.7, zc)] + [(xt + 0.45 * math.sin(a), yb - 1.15 - 0.45 * math.cos(a), zc)
                                  for a in np.linspace(-0.2, 3.6, 8)]
    for p, q in zip(pts[:-1], pts[1:]):
        T(m, "Steel", OCHRE, p, q, 0.1, segs=8)
    # the operator's cab, under the east end
    xc = xr - 3.2
    B(m, "Steel", OCHRE, xc - 1.2, xc + 1.2, y0 - 1.8, y0 + 0.6, zc + 1.0, zc + 3.2)
    m.color = (1, 1, 1)
    box(m, "Glass", (xc, y0 - 0.55, zc + 3.22), (2.0, 1.6, 0.04))
    box(m, "Glass", (xc - 1.22, y0 - 0.55, zc + 2.1), (0.04, 1.6, 1.8))
    for x in (-xr + 3.0, 0.0, xr - 6.0):
        m.color = LAMP_COOL
        box(m, "Lamp", (x, y0 + 0.57, zc), (1.0, 0.04, 0.5))


# ── the roof trusses ────────────────────────────────────────────────────────

def trusses(C, sh):
    lo, hi = V.TRUSS_LO, V.TRUSS_HI
    span = V.IN_W - 0.05
    xs = np.linspace(-24.0, 24.0, 13)
    zt = list(V.TRUSS_Z)
    for i, z in enumerate(zt):
        m = C(f"Truss {i + 1}")
        m.ground = False
        B(m, "Steel", LIGHT, -span, span, lo, lo + 0.45, z - 0.22, z + 0.22, var=False)
        B(m, "Steel", LIGHT, -span, span, hi - 0.45, hi, z - 0.22, z + 0.22, var=False)
        for x in xs:
            B(m, "Steel", LIGHT, x - 0.13, x + 0.13, lo + 0.45, hi - 0.45, z - 0.13, z + 0.13, var=False)
        for a, b in zip(xs[:-1], xs[1:]):
            if b <= 0:     # Pratt: the diagonals fall toward mid-span
                beam(m, LIGHT, (a + 0.13, hi - 0.45, z), (b - 0.13, lo + 0.45, z), 0.16, 0.16)
            else:
                beam(m, LIGHT, (a + 0.13, lo + 0.45, z), (b - 0.13, hi - 0.45, z), 0.16, 0.16)
        # purlins to the next truss
        if i + 1 < len(zt):
            z2 = zt[i + 1]
            for x in xs[1:-1:2]:
                B(m, "Steel", GREY, x - 0.1, x + 0.1, hi - 0.35, hi, z + 0.22, z2 - 0.22, var=False)
            # the maintenance catwalk down the middle, hung under the trusses
            za = z - 0.6 if i == 0 else z
            zb = z2 + 0.6 if i + 2 == len(zt) else z2
            B(m, "Steel", GREY, -0.6, 0.6, lo - 1.1, lo - 1.0, za, zb, var=False, sh=sh)
            for sx in (-1, 1):
                railing(m, SAFETY, (sx * 0.55, lo - 1.0, z + 0.3), (sx * 0.55, lo - 1.0, z2 - 0.3), h=1.0, sh=sh)
        for sx in (-1, 1):
            T(m, "Steel", DARK, (sx * 0.67, lo - 1.1, z), (sx * 0.67, lo, z), 0.03, segs=5)
        # high-bay pendants
        for x in (-16.0, -8.0, 8.0, 16.0):
            T(m, "Steel", DARK, (x, lo, z), (x, lo - 0.9, z), 0.02, segs=4)
            sub = CModel(); sub.ground = False; sub.color = GREY
            lathe(sub, "Steel", [(0.12, 0.0), (0.18, -0.2), (0.42, -0.62), (0.44, -0.66)], segs=14)
            sub.color = LAMP_WARM
            lathe(sub, "Lamp", [(0.40, -0.63), (0.0, -0.6)], segs=14)
            m.merge(sub, None, (x, lo - 0.9, z))


# ── the floor ───────────────────────────────────────────────────────────────

def floor_marks(m):
    m.ground = False
    y = V.SLAB_Y1
    for sx in (-1, 1):
        # the crawlerway: the path the launcher rolls out on
        mark(m, "v_yellow", sx * 13.6, 0.0, 0.22, 2 * V.IN_D - 2.6, y + 0.03, rot=True)
        # embedded crawler track plates
        B(m, "Steel", DARK, sx * 5.4, sx * 7.0, y, y + 0.02, -V.IN_D + 0.7, V.IN_D - 0.7, var=False)
        # the walkways down both walls
        mark(m, "v_green", sx * 17.4, 2.0, 0.14, 38.0, y + 0.03, rot=True)
    # a hazard border round the launcher
    hx, hz = V.ML_HX + 0.9, V.ML_HZ + 0.9
    for sz in (-1, 1):
        mark(m, "v_hazard", 0.0, sz * hz, 2 * hx + 0.5, 0.5, y + 0.035)
    for sx in (-1, 1):
        mark(m, "v_hazard", sx * hx, 0.0, 0.5, 2 * hz - 0.5, y + 0.035, rot=True)
    # the thresholds
    for sz in (-1, 1):
        mark(m, "v_hazard", 0.0, sz * (V.IN_D - 1.0), 2 * V.LOW_W - 1.2, 0.6, y + 0.035)
    mark(m, "v_floor_bay", 0.0, 17.5, 10.0, 2.0, y + 0.025)
    mark(m, "v_floor_ml", 0.0, -16.2, 4.0, 2.0, y + 0.025)
    # the stair feet kept clear, the forklift route
    for sx in (-1, 1):
        mark(m, "v_hazard", sx * (V.PLAT_X1 - 1.15), -17.4, 1.6, 0.4, y + 0.035)
    mark(m, "v_yellow", -15.6, -12.0, 0.15, 10.0, y + 0.03, rot=True)


# ── the floor's furniture ───────────────────────────────────────────────────

def bench(m, x, z, sx):
    """A workbench against the wall (its back toward +sx)."""
    w, d, h = 2.0, 0.8, 0.92
    for zz in (z - w / 2 + 0.08, z + w / 2 - 0.08):
        for xx in (x - d / 2 + 0.06, x + d / 2 - 0.06):
            B(m, "Steel", CONT_BLUE, xx - 0.03, xx + 0.03, 0.0, h - 0.05, zz - 0.03, zz + 0.03, var=False)
    B(m, "Steel", DARK, x - d / 2, x + d / 2, h - 0.05, h, z - w / 2, z + w / 2)
    B(m, "Steel", CONT_BLUE, x - d / 2 + 0.06, x + d / 2 - 0.06, 0.18, 0.22, z - w / 2 + 0.1, z + w / 2 - 0.1, var=False)
    B(m, "Steel", CONT_RED, x - d / 2 + 0.06, x + d / 2 - 0.06, 0.22, h - 0.12, z + w / 2 - 0.6, z + w / 2 - 0.12)
    B(m, "Steel", GREY, x - 0.15 * sx - 0.1, x - 0.15 * sx + 0.1, h, h + 0.16, z - 0.6, z - 0.3)     # a vise
    B(m, "Steel", LIGHT, x - 0.2, x + 0.2, h, h + 0.12, z + 0.1, z + 0.4)                       # a parts tray


def tool_cart(m, x, z, col=CONT_RED):
    B(m, "Steel", col, x - 0.45, x + 0.45, 0.2, 1.0, z - 0.28, z + 0.28)
    for k in range(4):
        y = 0.35 + k * 0.17
        B(m, "Steel", DARK, x - 0.4, x + 0.4, y, y + 0.02, z + 0.28, z + 0.3, var=False)
    T(m, "Steel", GREY, (x - 0.5, 1.0, z - 0.2), (x - 0.5, 1.0, z + 0.2), 0.02, segs=5)
    for (xx, zz) in ((x - 0.35, z - 0.2), (x + 0.35, z - 0.2), (x - 0.35, z + 0.2), (x + 0.35, z + 0.2)):
        wheel(m, (xx, 0.2 - 0.07 + 0.12 * 0, zz), (0, 0, 1), 0.07, 0.05)


def furniture(C, sh):
    # THE WORKSHOP, south-west
    m = C("Shop")
    xw = -V.PLAT_X1 + 0.5
    for z in (9.7, 14.2, 18.4):
        bench(m, xw, z, -1)
        vplate(m, "v_pegboard", (-V.IN_W + 0.25, 1.6, z), (0, 0, -1), (0, 1, 0), 1.9, depth=0.03)
    for (x, z) in ((-19.6, 10.2), (-19.4, 15.0)):
        tool_cart(m, x, z)
    tool_cart(m, -18.9, 12.6, col=CONT_BLUE)
    for z in (21.0, 22.05):     # tall cabinets
        B(m, "Steel", GREYBLUE, -V.PLAT_X1 + 0.05, -V.PLAT_X1 + 0.6, 0.0, 2.0, z - 0.5, z + 0.5)
        B(m, "Steel", DARK, -V.PLAT_X1 + 0.6, -V.PLAT_X1 + 0.62, 0.15, 1.9, z - 0.02, z + 0.02, var=False)
    for (x, z) in ((-20.6, 10.2), (-20.6, 14.4)):    # stools
        T(m, "Steel", DARK, (x, 0.0, z), (x, 0.6, z), 0.03, segs=6)
        T(m, "Steel", RUBBER, (x, 0.6, z), (x, 0.66, z), 0.18, segs=10)
    # the gas cage
    gx, gz = -17.6, 21.6
    for (x, z) in ((gx - 1.0, gz - 0.7), (gx + 1.0, gz - 0.7), (gx + 1.0, gz + 0.7), (gx - 1.0, gz + 0.7)):
        T(m, "Steel", GREY, (x, 0.0, z), (x, 1.9, z), 0.04, segs=6)
    for (p, q) in (((gx - 1.0, 1.9, gz - 0.7), (gx + 1.0, 1.9, gz - 0.7)), ((gx + 1.0, 1.9, gz - 0.7), (gx + 1.0, 1.9, gz + 0.7)),
                   ((gx + 1.0, 1.9, gz + 0.7), (gx - 1.0, 1.9, gz + 0.7)), ((gx - 1.0, 1.9, gz + 0.7), (gx - 1.0, 1.9, gz - 0.7)),
                   ((gx - 1.0, 0.9, gz - 0.7), (gx + 1.0, 0.9, gz - 0.7))):
        T(m, "Steel", GREY, p, q, 0.03, segs=5)
    for k, col in enumerate(((0.22, 0.40, 0.25), (0.22, 0.40, 0.25), GREY, (0.20, 0.30, 0.55), GREY, (0.55, 0.20, 0.15))):
        x = gx - 0.75 + (k % 3) * 0.75
        z = gz - 0.25 + (k // 3) * 0.5
        T(m, "Steel", col, (x, 0.0, z), (x, 1.45, z), 0.12, segs=10)
        T(m, "Steel", GREY, (x, 1.45, z), (x, 1.62, z), 0.05, segs=6)
    vplate(m, "v_gas", (gx, 2.2, gz - 0.72), (-1, 0, 0), (0, 1, 0), 1.4, depth=0.02)

    # PALLET RACKING down the west wall
    m = C("Racks")
    x0, x1 = -V.PLAT_X1 + 0.1, -V.PLAT_X1 + 1.3
    zs = np.arange(-7.5, 7.6, 2.7)
    for z in zs:
        for x in (x0, x1):
            B(m, "Steel", RUST_ORANGE, x - 0.05, x + 0.05, 0.0, 6.2, z - 0.05, z + 0.05, var=False)
    for y in (0.15, 2.15, 4.15):
        for x in (x0, x1):
            B(m, "Steel", CONT_BLUE, x - 0.04, x + 0.04, y, y + 0.14, zs[0], zs[-1], var=False)
    rng = np.random.default_rng(7)
    for i, (za, zb) in enumerate(zip(zs[:-1], zs[1:])):
        for j, y in enumerate((0.29, 2.29, 4.29)):
            kind = (i + 2 * j) % 4
            if kind == 0:       # crates
                B(m, "Clad", WARM, x0 + 0.08, x1 - 0.08, y, y + 1.1, za + 0.15, za + 1.25)
                B(m, "Clad", WARM, x0 + 0.08, x1 - 0.08, y, y + 0.8, za + 1.4, zb - 0.15)
            elif kind == 1:     # drums
                for k in range(3):
                    zc = za + 0.45 + k * 0.85
                    T(m, "Steel", CONT_BLUE if k != 1 else GREY, ((x0 + x1) / 2, y, zc), ((x0 + x1) / 2, y + 0.88, zc), 0.29,
                      segs=12)
            elif kind == 2:     # boxed spares
                for k in range(4):
                    h = 0.35 + 0.1 * rng.integers(0, 3)
                    B(m, "Clad", (0.62, 0.55, 0.42), x0 + 0.12, x1 - 0.12, y, y + h, za + 0.12 + k * 0.62, za + 0.68 + k * 0.62)
            else:               # a pallet of panels
                B(m, "Steel", (0.45, 0.36, 0.25), x0 + 0.05, x1 - 0.05, y, y + 0.14, za + 0.1, zb - 0.1, var=False)
                B(m, "Steel", PAINT, x0 + 0.1, x1 - 0.1, y + 0.14, y + 0.6, za + 0.2, zb - 0.2)
    vplate(m, "v_forks", (x1 + 0.06, 6.0, 0.0), (0, 0, -1), (0, 1, 0), 1.8, depth=0.02)

    # STORE: two shipping containers and a flammables cabinet, east wall
    m = C("Store")
    xa, xb = V.PLAT_X1 - 2.45, V.PLAT_X1 - 0.05
    for (za, zb, col) in ((-7.0, -0.94, CONT_RED), (0.6, 6.66, CONT_BLUE)):
        B(m, "Clad", col, xa, xb, 0.0, 2.59, za, zb)
        B(m, "Steel", DARK, xa - 0.04, xb + 0.04, 2.59, 2.66, za - 0.04, zb + 0.04, var=False)
        for x in (xa + 0.6, xb - 0.6):     # the door end's locking bars
            T(m, "Steel", GREY, (x, 0.2, zb + 0.06), (x, 2.4, zb + 0.06), 0.025, segs=5)
    B(m, "Steel", SAFETY, xb - 0.6, xb, 0.0, 1.8, 9.0, 10.2)
    vplate(m, "v_flam", (xb - 0.6, 1.4, 9.6), (0, 0, 1), (0, 1, 0), 0.9, depth=0.02)

    # BOOTH: the assembly control room, south-east
    m = C("Booth")
    bx0, bx1, bz0, bz1, bh = 16.2, V.PLAT_X1 - 0.6, 13.4, 20.4, 3.3
    B(m, "Steel", PAINT, bx0, bx1, 0.0, 1.0, bz0, bz1, sh=sh)
    B(m, "Steel", PAINT, bx0, bx1, 2.6, bh, bz0, bz1)
    for (x, z) in ((bx0, bz0), (bx0, bz1), (bx1, bz0)):
        B(m, "Steel", SLATE, x - 0.1, x + 0.1, 1.0, 2.6, z - 0.1, z + 0.1, var=False)
    for z in np.arange(bz0 + 1.5, bz1 - 0.5, 1.5):
        B(m, "Steel", SLATE, bx0 - 0.05, bx0 + 0.05, 1.0, 2.6, z - 0.04, z + 0.04, var=False)
    for x in np.arange(bx0 + 1.5, bx1 - 0.5, 1.5):
        B(m, "Steel", SLATE, x - 0.04, x + 0.04, 1.0, 2.6, bz0 - 0.05, bz0 + 0.05, var=False)
    m.color = (1, 1, 1)
    box(m, "Glass", (bx0, 1.8, (bz0 + bz1) / 2), (0.03, 1.5, bz1 - bz0 - 0.2))
    box(m, "Glass", ((bx0 + bx1) / 2, 1.8, bz0), (bx1 - bx0 - 0.2, 1.5, 0.03))
    B(m, "Steel", SLATE, bx0 + 0.6, bx1 - 0.6, 1.0, 2.6, bz1 - 0.12, bz1, var=False)      # back wall
    B(m, "Steel", DARK, bx0 - 0.04, bx0, 0.0, 2.2, bz1 - 1.9, bz1 - 0.9, var=False)       # door
    sh.add(((bx0 + bx1) / 2, bh / 2, (bz0 + bz1) / 2), (bx1 - bx0, bh, bz1 - bz0))
    from base_models import hvac
    hvac(m, (bx0 + bx1) / 2, bh, (bz0 + bz1) / 2, 2.2, 1.4, 0.9, fans=1)
    vplate(m, "v_control", (bx0 - 0.02, 2.95, (bz0 + bz1) / 2), (0, 0, 1), (0, 1, 0), 3.6, depth=0.03)
    B(m, "Steel", DARK, bx0 + 0.3, bx0 + 1.1, 0.5, 0.95, bz0 + 0.6, bz1 - 2.2)     # the console inside the glass

    # KIT W: a forklift, a tank section on cradles, a work-light tower
    m = C("Kit W")
    fx, fz = -16.4, -13.0           # the forklift, forks toward +z
    B(m, "Steel", SAFETY, fx - 0.6, fx + 0.6, 0.35, 1.2, fz - 1.3, fz + 0.4)
    B(m, "Steel", DARK, fx - 0.6, fx + 0.6, 0.35, 1.45, fz - 1.75, fz - 1.3)
    B(m, "Steel", DARK, fx - 0.25, fx + 0.25, 1.2, 1.6, fz - 0.9, fz - 0.4)
    for (x, z) in ((fx - 0.55, fz - 1.1), (fx + 0.55, fz - 1.1), (fx - 0.55, fz + 0.2), (fx + 0.55, fz + 0.2)):
        T(m, "Steel", DARK, (x, 1.2, z), (x, 2.2, z), 0.04, segs=6)
    B(m, "Steel", DARK, fx - 0.6, fx + 0.6, 2.2, 2.26, fz - 1.15, fz + 0.25, var=False)
    for x in (fx - 0.35, fx + 0.35):
        B(m, "Steel", DARK, x - 0.06, x + 0.06, 0.1, 2.9, fz + 0.45, fz + 0.6, var=False)
        B(m, "Steel", GREY, x - 0.06, x + 0.06, 0.12, 0.17, fz + 0.6, fz + 1.8, var=False)
    for (x, z, r) in ((fx - 0.62, fz - 1.2, 0.3), (fx + 0.62, fz - 1.2, 0.3), (fx - 0.62, fz + 0.1, 0.36), (fx + 0.62, fz + 0.1, 0.36)):
        wheel(m, (x, r, z), (1, 0, 0), r, 0.24)
    # the tank section, lying along z on two saddles
    tx, tz, r = -16.8, -1.5, 1.7
    sub = CModel(seed=5); sub.color = PAINT
    lathe(sub, "Clad", [(r, 0.0), (r, 4.0)], segs=28)
    lathe(sub, "Clad", [(r - 0.04, 4.0), (r - 0.04, 0.0)], segs=28)
    lathe(sub, "Steel", [(r - 0.04, 0.0), (r + 0.03, 0.0), (r + 0.03, 0.1), (r - 0.04, 0.1)], segs=28)
    lathe(sub, "Steel", [(r - 0.04, 3.9), (r + 0.03, 3.9), (r + 0.03, 4.0), (r - 0.04, 4.0)], segs=28)
    m.merge(sub, rot_x(math.pi / 2), (tx, r + 0.55, tz - 2.0))
    for zz in (tz - 1.2, tz + 1.2):
        B(m, "Steel", DARK, tx - 1.3, tx + 1.3, 0.0, 0.7, zz - 0.2, zz + 0.2)
    # a work-light tower
    lx, lz = -15.2, -21.0
    B(m, "Steel", SAFETY, lx - 0.7, lx + 0.7, 0.3, 1.3, lz - 1.1, lz + 1.1)
    for zz in (lz - 0.8, lz + 0.8):
        wheel(m, (lx, 0.3, zz), (1, 0, 0), 0.3, 0.2)
    T(m, "Steel", GREY, (lx, 1.3, lz), (lx, 6.5, lz), 0.07, segs=8)
    for dx in (-0.45, 0.45):
        from base_models import lamp_head
        lamp_head(m, (lx + dx, 6.7, lz + 0.1), (0, -0.4, 0.92), w=0.5, h=0.4, col=LAMP_WARM)
    B(m, "Steel", DARK, lx - 0.6, lx + 0.6, 6.5, 6.58, lz - 0.08, lz + 0.08, var=False)

    # KIT E: a scissor lift, an engine on its transport stand, cones
    m = C("Kit E")
    sx_, sz_ = 15.8, -13.5
    B(m, "Steel", SAFETY, sx_ - 0.6, sx_ + 0.6, 0.15, 0.6, sz_ - 1.2, sz_ + 1.2)
    for (x, z) in ((sx_ - 0.6, sz_ - 0.9), (sx_ + 0.6, sz_ - 0.9), (sx_ - 0.6, sz_ + 0.9), (sx_ + 0.6, sz_ + 0.9)):
        wheel(m, (x, 0.17, z), (1, 0, 0), 0.17, 0.12)
    ytop = 4.2
    nst = 3
    for k in range(nst):
        ya, yb = 0.6 + (ytop - 0.6) * k / nst, 0.6 + (ytop - 0.6) * (k + 1) / nst
        for x in (sx_ - 0.5, sx_ + 0.5):
            beam(m, DARK, (x, ya, sz_ - 1.0), (x, yb, sz_ + 1.0), 0.08, 0.12)
            beam(m, DARK, (x + (0.1 if x > sx_ else -0.1), ya, sz_ + 1.0), (x + (0.1 if x > sx_ else -0.1), yb, sz_ - 1.0),
                 0.08, 0.12)
    B(m, "Steel", SAFETY, sx_ - 0.65, sx_ + 0.65, ytop, ytop + 0.15, sz_ - 1.3, sz_ + 1.3)
    for (p, q) in (((sx_ - 0.6, sz_ - 1.25), (sx_ + 0.6, sz_ - 1.25)), ((sx_ + 0.6, sz_ - 1.25), (sx_ + 0.6, sz_ + 1.25)),
                   ((sx_ + 0.6, sz_ + 1.25), (sx_ - 0.6, sz_ + 1.25)), ((sx_ - 0.6, sz_ + 1.25), (sx_ - 0.6, sz_ - 1.25))):
        railing(m, SAFETY, (p[0], ytop + 0.15, p[1]), (q[0], ytop + 0.15, q[1]), h=1.0, posts=1.3)
    vplate(m, "v_lift", (sx_ - 0.6, 0.38, sz_), (0, 0, 1), (0, 1, 0), 0.8, depth=0.02)
    # the engine: a bell, its chamber and turbopump, on a stand
    ex, ez = 16.6, 7.2
    sub = CModel(seed=6); sub.ground = False
    sub.color = (0.42, 0.30, 0.22)
    prof = [(1.05 - 0.7 * (1 - (1 - t) ** 1.6), 0.45 + 1.9 * t) for t in np.linspace(0, 1, 8)]
    lathe(sub, "Steel", prof, segs=24, smooth=True)
    lathe(sub, "Steel", [(r_ - 0.02, y) for r_, y in prof[::-1]], segs=24, smooth=True, inward=True)
    sub.color = GREY
    lathe(sub, "Steel", [(0.36, 2.35), (0.46, 2.5), (0.46, 3.0), (0.3, 3.15), (0.0, 3.2)], segs=20)
    m.merge(sub, None, (ex, 0.0, ez))
    B(m, "Steel", DARK, ex + 0.45, ex + 0.85, 2.6, 3.2, ez - 0.25, ez + 0.25)
    T(m, "Steel", GREY, (ex + 0.65, 2.6, ez), (ex + 0.3, 2.0, ez + 0.2), 0.07, segs=6)
    T(m, "Steel", GREY, (ex - 0.5, 2.9, ez), (ex - 0.6, 1.7, ez - 0.3), 0.06, segs=6)
    for (x, z) in ((ex - 1.1, ez - 1.1), (ex + 1.1, ez - 1.1), (ex + 1.1, ez + 1.1), (ex - 1.1, ez + 1.1)):
        B(m, "Steel", CONT_BLUE, x - 0.07, x + 0.07, 0.0, 2.6, z - 0.07, z + 0.07, var=False)
    for (xa_, xb_, za_, zb_) in ((ex - 1.18, ex + 1.18, ez - 1.18, ez - 1.02), (ex - 1.18, ex + 1.18, ez + 1.02, ez + 1.18),
                                 (ex - 1.18, ex - 1.02, ez - 1.02, ez + 1.02), (ex + 1.02, ex + 1.18, ez - 1.02, ez + 1.02)):
        B(m, "Steel", CONT_BLUE, xa_, xb_, 2.6, 2.75, za_, zb_, var=False)
        B(m, "Steel", CONT_BLUE, xa_, xb_, 0.1, 0.2, za_, zb_, var=False)
    for (x, z) in ((14.6, -3.0), (14.6, -5.4), (14.6, 10.2), (14.6, 12.4)):     # cones
        T(m, "Steel", (0.80, 0.30, 0.08), (x, 0.03, z), (x, 0.72, z), 0.17, segs=10, r1=0.03)
        B(m, "Steel", RUBBER, x - 0.2, x + 0.2, 0.0, 0.04, z - 0.2, z + 0.2, var=False)


# ── the lights ──────────────────────────────────────────────────────────────

LIGHTS = [
    # name, position, colour, intensity, range, aim (None = point)
    # (aimed a little in toward the middle: a beam straight down has no yaw)
    ("High Bay NE", (11.0, 63.0, -9.0), (1.0, 0.93, 0.80), 7.0, 85.0, (-0.12, -1.0, 0.1)),
    ("High Bay NW", (-11.0, 63.0, -9.0), (1.0, 0.93, 0.80), 7.0, 85.0, (0.12, -1.0, 0.1)),
    ("High Bay SE", (11.0, 63.0, 9.0), (1.0, 0.93, 0.80), 7.0, 85.0, (-0.12, -1.0, -0.1)),
    ("High Bay SW", (-11.0, 63.0, 9.0), (1.0, 0.93, 0.80), 7.0, 85.0, (0.12, -1.0, -0.1)),
    ("Bay Fill", (0.0, 18.0, 0.0), (0.86, 0.90, 1.0), 2.5, 45.0, None),
]

MARKERS = [
    ("VabBuildPoint", V.BUILD_POINT),
    ("VabCamHome", (0.0, 9.0, 21.0)),
    ("VabDoorSouth", (0.0, V.SLAB_Y1, V.IN_D)),
    ("VabDoorNorth", (0.0, V.SLAB_Y1, -V.IN_D)),
    ("VabStairE", (V.PLAT_X1 - 1.15, V.SLAB_Y1, -18.6)),
    ("VabStairW", (-(V.PLAT_X1 - 1.15), V.SLAB_Y1, -18.6)),
    ("VabCraneHook", (-5.0, 42.2, -16.0)),
]


# How close the camera must come before a chunk thins, as a factor of the
# fade script's near distances: the launcher under the craft and the kit on
# the floor stay until the camera is right on them.
NEAR_K = {"ML": 0.12, "Shop": 0.6, "Racks": 0.6, "Store": 0.6, "Booth": 0.6, "Kit W": 0.6, "Kit E": 0.6}


# ── the prefab ──────────────────────────────────────────────────────────────

def material(name):
    if name == SIGN:
        ron = ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/vab/signs.png"),\n'
               '                roughness: 0.62,\n                metallic: 0.05,\n                shading: Physical,\n            )')
    else:
        ron = MATERIALS[name]()
    return dithered(ron)


def mesh_node(name, glb, model, pos, parent=0):
    mats = ",\n".join(f'            "{n}": {material(n)}' for n in sorted(model.parts.keys()))
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/vab/{glb}",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
        parent: Some({parent}),
    ),
'''


def write_prefab(nodes, chunk_spec, ext_spec, sh, origin):
    o = np.asarray(origin, float)
    out = [f'''// VAB INTERIOR — the high bay of the Vehicle Assembly Building, where the craft builder takes place.
// Written by tools/gen_vab.py — edit the generator, not this file.
// Same origin as FacHangar (the slab's centre): spawn both with one position and rotation.
// "Fade *" children are thinned away near (and in front of) the camera by scripts/vab_fade.lua.
[
    (
        name: "VabInterior",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [
            (
                kind: "vab_fade",
                enabled: true,
                params: [],
                strs: [
                    ("chunks", "{chunk_spec}"),
                    ("ext", "{ext_spec}"),
                ],
            ),
        ],
    ),
''']
    for (name, glb, model, c) in nodes:
        out.append(mesh_node(name, glb, model, np.asarray(c) - o))
    for (mname, p) in MARKERS:
        out.append(f'''    (
        name: "{mname}",
        transform: (
            translation: {f3(np.asarray(p, float) - o)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
    ),
''')
    for (lname, p, col, inten, rng, aim) in LIGHTS:
        rot = spot_rotation(aim) if aim is not None else (0.0, 0.0, 0.0, 1.0)
        spot = "            spot: Some((angle: 64.0, softness: 0.5)),\n" if aim is not None else ""
        out.append(f'''    (
        name: "{lname}",
        transform: (
            translation: {f3(np.asarray(p, float) - o)},
            rotation: ({rot[0]:.5f}, {rot[1]:.5f}, {rot[2]:.5f}, {rot[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: {f3(col)},
            intensity: {inten},
            range: {rng},
{spot}        ),
        scripts: [],
        parent: Some(0),
    ),
''')
    # Everything a boot stands on or leans against, as ONE hidden triangle
    # collider: a few hundred box nodes cost a node each in the scripts'
    # mirror and the scene, one mesh collider costs one.
    wm, wc = walk_mesh(sh)
    write_glb(wm.shifted(wc), os.path.join(MODELS, "walk.glb"))
    out.append(f'''    (
        name: "VabWalk",
        transform: (
            translation: {f3(wc - o)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/vab/walk.glb",
        ),
        scripts: [],
        parent: Some(0),
        mesh_collider: true,
        visible: false,
        cast_shadow: false,
    ),
''')
    out.append("]\n")
    with open(os.path.join(PREFABS, "VabInterior.prefab.ron"), "w") as f:
        f.write("".join(out))


def walk_mesh(sh):
    """The walkable shell boxes as one triangle mesh (each an oriented box)."""
    from gen_part_meshes import Model
    m = CModel(1)
    m.ground = False
    for (c, s, q) in sh.boxes:
        x, y, z, w = q
        R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        m.color = (1, 1, 1)
        box(m, "Walk", c, s, M=R)
    mn, mx = m.bounds()
    return m, (mn + mx) / 2


def ext_spec():
    """FacHangar's fading parts, for the same script: their boxes in the
    shared ground frame (the exterior is built here only to be measured)."""
    import base_buildings
    _, _, _, _, subs = base_buildings.vab()
    rows = []
    for name, sm in subs.items():
        mn, mx = sm.bounds()
        h = (mx - mn) / 2
        rows.append(f"{name}|{h[0]:.2f}|{h[1]:.2f}|{h[2]:.2f}|{','.join(sorted(sm.parts.keys()))}")
    return ";".join(rows)


def base_regions():
    """The base atlas' regions (the exterior's plates), without writing the
    base textures: those are tools/gen_base.py's."""
    save = Image.Image.save
    Image.Image.save = lambda *a, **k: None
    try:
        base_tex.signs()
    finally:
        Image.Image.save = save


def main():
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    base_regions()
    signs()
    C, sh = Chunks(), Shell()
    walls(C, sh)
    platforms(C, sh)
    stair_towers(C, sh)
    mobile_launcher(C, sh)
    crane(C, sh)
    trusses(C, sh)
    furniture(C, sh)
    floor = CModel(299)
    floor_marks(floor)
    fights = 0
    allm = CModel()
    total = 0
    rows = []
    print("chunk              size (x, y, z)              tris  mats")
    for name, m in list(C.m.items()) + [("VabFloor", floor)]:
        fights += zcheck(m, name)
        allm.merge(m)
        mn, mx = m.bounds()
        s = mx - mn
        total += m.tris()
        print(f"{name:16s} ({s[0]:6.2f}, {s[1]:6.2f}, {s[2]:6.2f})  {m.tris():7d}  {','.join(sorted(m.parts))}")
        rows.append((name, m, (mn + mx) / 2, s / 2))
    # across chunks, and against the shell's inner faces
    import base_buildings
    root, _, _, _, subs = base_buildings.vab()
    for part in [root] + list(subs.values()):
        allm.merge(part)
    fights += zcheck(allm, "VAB interior + shell")
    print(f"{len(rows)} chunks, {total} tris, {len(sh.boxes)} walkable boxes (one collision mesh)")
    if fights:
        print(f"!! {fights} z-fighting face pairs: nothing written")
        sys.exit(1)
    if dry:
        return
    nodes, spec = [], []
    for (name, m, c, h) in rows:
        node = name if name == "VabFloor" else "Fade " + name
        glb = name.lower().replace(" ", "_") + ".glb"
        write_glb(m.shifted(c), os.path.join(MODELS, glb))
        nodes.append((node, glb, m, c))
        if name != "VabFloor":
            spec.append(f"{node}|{h[0]:.2f}|{h[1]:.2f}|{h[2]:.2f}|{','.join(sorted(m.parts.keys()))}|{NEAR_K.get(name, 1.0):g}")
    write_prefab(nodes, ";".join(spec), ext_spec(), sh, V.ORIGIN)
    print(f"wrote {len(nodes)} models to models/vab/, prefabs/VabInterior.prefab.ron")


if __name__ == "__main__":
    main()
