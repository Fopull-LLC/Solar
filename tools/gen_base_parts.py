#!/usr/bin/env python3
"""Generate the BASE section's placeable parts (deep-space addendum K3, step 4)
and the Build Kit the Engineer carries (K1).

    python3 tools/gen_base_parts.py          # models/base/parts/*.glb, items, prefabs
    python3 tools/gen_base_parts.py --dry    # sizes, seats, box centres

Every part is built 1:1 in a GROUND frame (ground y = 0, front +Z, the
footprint centred on x = z = 0) in metres, from the same primitives and PBR
sets as the spaceport (tools/base_models.py, textures/base: concrete,
cladding, steel; all CC0 or procedural, see tools/base_tex.py).

WITH ITS FUTURE INTERIOR (E's direction for steps 4-8). The engine's
interiors Stage 1 (EN1: rb.subShape and rb.shell) should be a flag change,
not a rebuild, so each module is already split the way that stage reads it:

  flat modules   (the Equipment Shed) carry their walls, floor, roof and door
                 as named collider boxes, "Wall N" children: each becomes one
                 rb.subShape of the module's body when Stage 1 lands. The
                 door is closed today (no one walks inside placed modules
                 before EN1/EN2: no kinematic interior fakes).
  curved modules (the Surface Hab) carry their pressure hull as ONE child mesh
                 named "Shell" (models/base/parts/hab_shell.glb, a real
                 0.1 m-thick wall, inner face included) that becomes the
                 rb.shell; today it is closed off by an octagon of four
                 collider boxes round its axis.
  both           carry their fit-out as a child mesh named "Interior" (the
                 racks, the bench, the bunks, the floor deck), modelled now.

The engine recentres every model on its bounding box, so a prefab's origin is
its root model's box centre: `seat` (printed, copied into
scripts/parts_base.lua PARTS[id].seat) is how far that origin sits above the
ground; child nodes stand at their own box centre minus the root's.

Masses and sizes are the real things': a 4 x 4 m precast slab 0.30 m thick
(11.5 t of reinforced concrete); a 3.0 x 2.4 x 2.6 m steel equipment shelter
on skids, the size of a 10 ft ISO container (1.6 t fitted out); a 4 m x 6 m
surface habitat can on two saddles (7.5 t, about an ISS node's dry mass).
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT, PREFABS, box, disk, lathe, rot_z, tube  # noqa: E402
from base_models import (CModel, CONC, CONT_BLUE, DARK, GREY, LIGHT, PAINT, RUBBER, SAFETY, Shell,  # noqa: E402
                         SLATE, WARM, LAMP_WARM, zcheck)
import gen_base  # noqa: E402

MODELS = os.path.join(ROOT, "models", "base", "parts")
ITEMS = os.path.join(ROOT, "models", "items")
TAU = 2 * math.pi
UVM = {"Concrete": 0.25, "Clad": 0.5, "Steel": 1.0, "Glass": 1.0, "Lamp": 2.5, "Rubber": 4.0, "Dark": 4.0}


def bx(m, mat, col, c, s, sh=None, M=None):
    """A box by centre and size in the ground frame (no automatic footing)."""
    m.color = col
    box(m, mat, c, s, M=M, uv_m=UVM.get(mat, 1.0))
    if sh is not None:
        sh.add(c, s)


def tb(m, mat, col, p0, p1, r, segs=10):
    m.color = col
    tube(m, mat, p0, p1, r, segs=segs, uv_m=UVM.get(mat, 1.0))


# ── PAD PLATE ────────────────────────────────────────────────────────────────
# A 4 x 4 m precast reinforced-concrete slab, 0.30 m thick, set with its top
# 0.20 m proud of the ground (the rest is its footing: on a slight slope the
# skirt stays in the ground instead of showing daylight under a corner; real
# foundations and grading come with step 5's K5). A galvanised steel edge
# angle round the top, two cast-in tie-down rails, four lifting anchors and
# faded safety-yellow corner marks.

def pad_plate():
    m = CModel(seed=41)
    sh = Shell()
    H, T, F = 4.0, 0.20, 0.40       # side, top above ground, footing below
    bx(m, "Concrete", CONC, (0, (T - F) / 2, 0), (H, T + F, H), sh=sh)
    e = 0.07
    for s in (-1, 1):
        # the edge angle: a strip on the top face's rim and down the side
        bx(m, "Steel", GREY, (0, T + 0.006, s * (H / 2 - e / 2)), (H, 0.012, e))
        bx(m, "Steel", GREY, (s * (H / 2 - e / 2), T + 0.006, 0), (e, 0.012, H - 2 * e))
        bx(m, "Steel", GREY, (0, T - 0.05, s * (H / 2 + 0.006)), (H + 0.024, 0.10, 0.012))
        bx(m, "Steel", GREY, (s * (H / 2 + 0.006), T - 0.05, 0), (0.012, 0.10, H))
        # tie-down rails (a C-channel cast flush, its lips just proud)
        bx(m, "Steel", DARK, (s * 1.0, T + 0.004, 0), (0.12, 0.008, H - 0.5))
        bx(m, "Steel", SLATE, (s * 1.0, T + 0.009, 0), (0.05, 0.004, H - 0.6))
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx, cz = sx * 1.55, sz * 1.55
            # a lifting anchor: a recessed plate and its forged ring
            bx(m, "Steel", DARK, (cx, T + 0.003, cz), (0.16, 0.006, 0.16))
            m.color = GREY
            ring = CModel(seed=1)
            ring.ground = False
            lathe(ring, "Steel", [(0.045, 0.0), (0.06, 0.012), (0.045, 0.024), (0.03, 0.012), (0.045, 0.0)], segs=12)
            m.merge(ring, M=rot_z(math.pi / 2), t=(cx, T + 0.045, cz))
            # the corner marks
            bx(m, "Steel", SAFETY, (sx * 1.82, T + 0.016, sz * 1.65), (0.16, 0.004, 0.5))
            bx(m, "Steel", SAFETY, (sx * 1.65, T + 0.021, sz * 1.81), (0.48, 0.004, 0.155))
    return m, sh


# ── EQUIPMENT SHED ───────────────────────────────────────────────────────────
# A 3.0 (w, x) x 2.4 (d, z) x 2.6 m (h) steel equipment shelter on two skids:
# corrugated walls (the cladding set), square corner posts, a steel roof with
# a drip edge, a closed personnel door on the front (+Z), louvred vents, a
# conduit entry. Its fit-out (racks along the back, a bench on the left, the
# floor deck) is the "Interior" child, sealed in until interiors Stage 1.

SHED = dict(w=3.0, d=2.4, h=2.6, skid=0.15, wall=0.05)


def shed_shell():
    m = CModel(seed=52)
    sh = Shell()
    w, d, h, k, t = SHED["w"], SHED["d"], SHED["h"], SHED["skid"], SHED["wall"]
    y0 = k + 0.05                     # top of the floor frame
    y1 = h - 0.06                     # underside of the roof
    # skids and the floor frame
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, k / 2, s * 0.85), (w + 0.2, k, 0.12))
    bx(m, "Steel", SLATE, (0, k + 0.025, 0), (w - 0.03, 0.05, d - 0.03), sh=sh)
    # the walls: back, two ends, the front either side of the door and its lintel
    door_w, door_h = 0.92, 2.05
    col = CONT_BLUE
    bx(m, "Clad", col, (0, (y0 + y1) / 2, -(d / 2 - t / 2)), (w - 0.24, y1 - y0, t), sh=sh)
    for s in (-1, 1):
        bx(m, "Clad", col, (s * (w / 2 - t / 2), (y0 + y1) / 2, 0), (t, y1 - y0, d - 0.24), sh=sh)
    fw = (w - 0.24 - door_w) / 2
    for s in (-1, 1):
        bx(m, "Clad", col, (s * (door_w / 2 + fw / 2), (y0 + y1) / 2, d / 2 - t / 2), (fw, y1 - y0, t), sh=sh)
    bx(m, "Clad", col, (0, (y0 + door_h + y1) / 2, d / 2 - t / 2), (door_w, y1 - y0 - door_h, t), sh=sh)
    # the door: closed, set 2 cm into its frame, with its frame, hinges and lever
    bx(m, "Steel", SLATE, (0, y0 + door_h / 2, d / 2 - t / 2 - 0.005), (door_w - 0.02, door_h - 0.01, 0.04), sh=sh)
    for s in (-1, 1):
        bx(m, "Steel", DARK, (s * (door_w / 2 + 0.035), y0 + door_h / 2 + 0.03, d / 2 + 0.02), (0.06, door_h + 0.06, 0.03))
        bx(m, "Steel", DARK, (-door_w / 2 + 0.02, y0 + 0.4 + s * 0.6 + 0.6, d / 2 + 0.03), (0.04, 0.14, 0.03))
    bx(m, "Steel", DARK, (0, y0 + door_h + 0.035, d / 2 + 0.021), (door_w + 0.14, 0.06, 0.032))
    tb(m, "Steel", LIGHT, (door_w / 2 - 0.12, y0 + 1.0, d / 2 + 0.06), (door_w / 2 - 0.12, y0 + 1.18, d / 2 + 0.06), 0.012, segs=8)
    tb(m, "Steel", LIGHT, (door_w / 2 - 0.12, y0 + 1.05, d / 2 + 0.02), (door_w / 2 - 0.12, y0 + 1.05, d / 2 + 0.06), 0.01, segs=6)
    # corner posts, the roof and its drip edge
    for sx in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Steel", GREY, (sx * (w / 2 - 0.06), (y0 + h - 0.06) / 2, sz * (d / 2 - 0.06)), (0.12, h - 0.06 - y0, 0.12))
    bx(m, "Steel", GREY, (0, h - 0.03, 0), (w + 0.08, 0.06, d + 0.08), sh=sh)
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, h - 0.07, s * (d / 2 + 0.05)), (w + 0.1, 0.04, 0.02))
    # vents on the ends, a lamp over the door, a conduit entry on the back
    for s in (-1, 1):
        for i in range(5):
            bx(m, "Steel", DARK, (s * (w / 2 + 0.012), 1.75 + i * 0.07, 0.35), (0.024, 0.035, 0.5))
        bx(m, "Steel", GREY, (s * (w / 2 + 0.006), 1.89, 0.35), (0.012, 0.42, 0.58))
    bx(m, "Steel", DARK, (0, y0 + door_h + 0.16, d / 2 + 0.06), (0.22, 0.10, 0.10))
    bx(m, "Lamp", LAMP_WARM, (0, y0 + door_h + 0.11, d / 2 + 0.06), (0.16, 0.012, 0.06))
    tb(m, "Steel", GREY, (0.9, 0.35, -d / 2 - 0.05), (0.9, 2.3, -d / 2 - 0.05), 0.03)
    bx(m, "Steel", DARK, (0.9, 2.3, -d / 2 - 0.08), (0.18, 0.18, 0.12))
    return m, sh


def shed_interior():
    m = CModel(seed=53)
    m.ground = False
    w, d, h, k = SHED["w"], SHED["d"], SHED["h"], SHED["skid"]
    y0 = k + 0.05
    # the floor deck (tread plate over the frame) and a strip light
    bx(m, "Steel", GREY, (0, y0 + 0.012, 0), (w - 0.12, 0.02, d - 0.12))
    bx(m, "Lamp", LAMP_WARM, (0, h - 0.10, 0), (1.2, 0.03, 0.08))
    # racks along the back wall: four uprights, three shelves, a few crates
    for x in (-1.2, -0.35, 0.35, 1.2):
        bx(m, "Steel", SAFETY, (x, y0 + 0.022 + 0.95, -0.95), (0.05, 1.9, 0.05))
        bx(m, "Steel", SAFETY, (x, y0 + 0.022 + 0.95, -0.55), (0.05, 1.9, 0.05))
    for y in (0.35, 1.0, 1.65):
        bx(m, "Steel", GREY, (0, y0 + y, -0.75), (2.5, 0.03, 0.46))
    for (x, y, s) in ((-0.9, 0.35, 0.36), (-0.4, 0.35, 0.30), (0.6, 1.0, 0.40), (0.95, 1.65, 0.28), (-0.7, 1.65, 0.34)):
        bx(m, "Clad", WARM, (x, y0 + y + 0.015 + s / 2, -0.75), (s * 1.3, s, s))
    # a workbench at the left end with a vice
    bx(m, "Steel", DARK, (-1.15, y0 + 0.9, 0.35), (0.6, 0.05, 1.3))
    for z in (-0.25, 0.95):
        bx(m, "Steel", DARK, (-1.15, y0 + 0.45, z), (0.5, 0.9, 0.04))
    bx(m, "Steel", SLATE, (-1.15, y0 + 0.99, 0.8), (0.14, 0.12, 0.10))
    return m


# ── SURFACE HAB ──────────────────────────────────────────────────────────────
# A 4.0 m-diameter, 6.0 m-long pressure can lying along X on two steel
# saddles, its shallow end domes, a hatch with a closed door on the front
# (+Z), two portholes, handrails, lamps. The hull is the "Shell" child: the
# outer skin, the inner face and both domes, 0.10 m thick.

HAB = dict(r=2.0, L=6.0, cy=2.35, wall=0.10, dome=0.45)


def hab_frame():
    m = CModel(seed=61)
    sh = Shell()
    r, L, cy = HAB["r"], HAB["L"], HAB["cy"]
    bot = cy - r
    for x in (-1.9, 1.9):
        # a saddle: a base beam, two raked legs, a curved cradle (3 flats)
        bx(m, "Steel", DARK, (x, 0.08, 0), (0.3, 0.16, 3.2), sh=sh)
        for s in (-1, 1):
            tb(m, "Steel", GREY, (x, 0.16, s * 1.45), (x, bot + 0.55, s * 1.25), 0.07)
        for a in (-0.55, 0.0, 0.55):
            c, sn = math.cos(a), math.sin(a)
            p = (x, cy - (r + 0.06) * c, (r + 0.06) * sn)
            Mr = np.array([[1, 0, 0], [0, c, sn], [0, -sn, c]])
            bx(m, "Steel", GREY, p, (0.26, 0.10, 1.05), M=Mr)
        bx(m, "Steel", SAFETY, (x, 0.165, 1.62), (0.3, 0.01, 0.04))
    # the hatch frame on the front (+Z), its door closed, a step plate below
    hz = r + 0.02
    bx(m, "Steel", GREY, (0, cy - 0.1, hz + 0.08), (1.2, 1.6, 0.14))
    bx(m, "Steel", SLATE, (0, cy - 0.1, hz + 0.16), (0.95, 1.35, 0.04))
    tb(m, "Steel", LIGHT, (0.3, cy - 0.1, hz + 0.19), (0.3, cy - 0.1, hz + 0.26), 0.02, segs=8)
    tb(m, "Steel", LIGHT, (0.18, cy - 0.1, hz + 0.26), (0.42, cy - 0.1, hz + 0.26), 0.018, segs=8)
    bx(m, "Steel", DARK, (0, 0.95, hz - 0.2), (1.0, 0.05, 0.6))
    for s in (-1, 1):
        tb(m, "Steel", GREY, (s * 0.45, 0.16, hz - 0.45), (s * 0.45, 0.95, hz - 0.45), 0.03)
    # handrails along the top and lamps either side of the hatch
    for s in (-1, 1):
        for x in (-2.2, -0.8, 0.8, 2.2):
            tb(m, "Steel", SAFETY, (x, cy + r * 0.86 + 0.0, s * r * 0.50), (x, cy + r * 0.86 + 0.12, s * r * 0.53), 0.015, segs=6)
        tb(m, "Steel", SAFETY, (-2.3, cy + r * 0.86 + 0.12, s * r * 0.53), (2.3, cy + r * 0.86 + 0.12, s * r * 0.53), 0.018, segs=6)
        bx(m, "Steel", DARK, (s * 0.9, cy + 0.85, hz - 0.15), (0.18, 0.12, 0.12))
        bx(m, "Lamp", LAMP_WARM, (s * 0.9, cy + 0.786, hz - 0.15), (0.12, 0.012, 0.08))
    # today's collider: an octagon of boxes round the can (the shell's place)
    side = 2 * r * math.tan(math.pi / 8) * 1.04
    for a in (0.0, math.pi / 4, math.pi / 2, 3 * math.pi / 4):
        q = (math.sin(a / 2), 0.0, 0.0, math.cos(a / 2))
        sh.add((0, cy, 0), (L + 2 * HAB["dome"] * 0.6, side, 2 * r), q)
    return m, sh


def hab_shell():
    m = CModel(seed=62)
    m.ground = False
    r, L, cy, t, dz = HAB["r"], HAB["L"], HAB["cy"], HAB["wall"], HAB["dome"]
    sub = CModel(seed=63)
    sub.ground = False
    sub.color = PAINT
    # outer skin: the barrel and two shallow domes, revolved about +Y, then
    # laid along X. Profile (radius, along-axis).
    prof = [(0.35, -L / 2 - dz)]
    for i in range(1, 7):
        a = i / 6 * (math.pi / 2)
        prof.append((r * math.sin(a) * 0.999 + 0.0, -L / 2 - dz * math.cos(a)))
    prof += [(r, L / 2)]
    for i in range(1, 7):
        a = (6 - i) / 6 * (math.pi / 2)
        prof.append((r * math.sin(a) * 0.999, L / 2 + dz * math.cos(a)))
    prof[-1] = (0.35, L / 2 + dz)
    lathe(sub, "Clad", prof, segs=48, smooth=True, uv_m=0.5)
    # the inner face, 0.10 m in (what the crew will see from inside)
    inner = [(max(rr - t, 0.25), y * (1 - t / (L / 2 + dz))) for (rr, y) in prof]
    sub.color = LIGHT
    lathe(sub, "Clad", inner, segs=48, smooth=True, uv_m=0.5, inward=True)
    # the dome hubs (berthing rings, closed)
    sub.color = GREY
    for s in (-1, 1):
        y = s * (L / 2 + dz)
        disk(sub, "Steel", 0.35, y, segs=24, up=s > 0)
        lathe(sub, "Steel", [(0.42, y - s * 0.02), (0.42, y + s * 0.06), (0.30, y + s * 0.06)], segs=24)
    # weld seams / rings along the barrel
    for y in (-L / 2 + 0.02, -1.0, 1.0, L / 2 - 0.02):
        lathe(sub, "Steel", [(r + 0.012, y - 0.04), (r + 0.012, y + 0.04)], segs=48)
    # Y-axis can → X-axis can, centred at (0, cy, 0)
    M = rot_z(-math.pi / 2)
    m.merge(sub, M=M, t=(0, cy, 0))
    # portholes on the front either side of the hatch
    for x in (-1.6, 1.6):
        a = 0.25
        p = np.array([x, cy + r * math.sin(a), r * math.cos(a) + 0.01])
        m.color = GREY
        tube(m, "Steel", p - np.array([0, math.sin(a), math.cos(a)]) * 0.02,
             p + np.array([0, math.sin(a), math.cos(a)]) * 0.05, 0.22, segs=16)
        m.color = (0.2, 0.24, 0.28)
        tube(m, "Glass", p + np.array([0, math.sin(a), math.cos(a)]) * 0.05,
             p + np.array([0, math.sin(a), math.cos(a)]) * 0.055, 0.17, segs=16)
    return m


def hab_interior():
    m = CModel(seed=64)
    m.ground = False
    r, L, cy = HAB["r"], HAB["L"], HAB["cy"]
    fy = cy - r + 0.75              # the deck, 0.75 m over the hull's lowest point
    half = math.sqrt(r * r - (fy - cy) ** 2) - 0.12
    bx(m, "Steel", GREY, (0, fy, 0), (L - 0.2, 0.04, 2 * half))
    # racks either side (one with a galley block), two bunks at the far end
    for s in (-1, 1):
        bx(m, "Clad", LIGHT, (-1.2, fy + 0.95, s * (half - 0.3)), (2.2, 1.8, 0.55))
    bx(m, "Steel", SLATE, (-1.2, fy + 0.9, -(half - 0.6)), (0.9, 0.04, 0.05))
    for k, yy in enumerate((0.45, 1.25)):
        bx(m, "Clad", WARM, (2.0, fy + yy, -0.6), (1.9, 0.18, 0.85))
        bx(m, "Steel", DARK, (2.0, fy + yy + 0.12, -0.6), (1.9, 0.04, 0.05))
    bx(m, "Lamp", LAMP_WARM, (0, cy + r - 0.35, 0), (3.0, 0.03, 0.12))
    return m


# ── BUILD KIT (the item) ─────────────────────────────────────────────────────
# A rugged field tablet in a hard carry frame: 0.30 x 0.22 x 0.035 m with
# rubber corner bumpers and a top carry handle, 1.6 kg. Carried by the handle
# (items.lua grip "left"); its long side along the stride (+Z).

def build_kit():
    m = CModel(seed=71)
    m.ground = False
    W, H, T = 0.30, 0.22, 0.035
    bx(m, "Dark", (0.20, 0.21, 0.22), (0, 0, 0), (T, H, W))
    bx(m, "Glass", (0.05, 0.07, 0.09), (T / 2 + 0.001, 0.0, 0.0), (0.002, H - 0.04, W - 0.05))
    for sy in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Rubber", (0.55, 0.36, 0.10), (0, sy * (H / 2 - 0.012), sz * (W / 2 - 0.012)), (T + 0.012, 0.03, 0.03))
    for sz in (-1, 1):
        tb(m, "Dark", (0.15, 0.15, 0.16), (0, H / 2, sz * 0.07), (0, H / 2 + 0.045, sz * 0.07), 0.008, segs=8)
    tb(m, "Rubber", (0.12, 0.12, 0.12), (0, H / 2 + 0.045, -0.08), (0, H / 2 + 0.045, 0.08), 0.013, segs=10)
    return m


# ── writing ──────────────────────────────────────────────────────────────────

ITEM_MATS = {
    "Dark": ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/metal_albedo.png"),\n'
             '                normal_map: Some("textures/parts/metal_normal.png"),\n                normal_strength: 1.0,\n'
             '                roughness_map: Some("textures/parts/metal_orm.png"),\n                roughness: 1.2,\n'
             '                metallic_map: Some("textures/parts/metal_orm.png"),\n                metallic: 0.3,\n'
             '                ao_map: Some("textures/parts/metal_orm.png"),\n                shading: Physical,\n            )'),
    "Rubber": ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/rubber_albedo.png"),\n'
               '                normal_map: Some("textures/parts/rubber_normal.png"),\n                normal_strength: 1.0,\n'
               '                roughness_map: Some("textures/parts/rubber_orm.png"),\n                roughness: 1.0,\n'
               '                ao_map: Some("textures/parts/rubber_orm.png"),\n                shading: Physical,\n            )'),
}


def mats_of(model):
    out = []
    for n in sorted(model.parts.keys()):
        ron = ITEM_MATS[n] if n in ITEM_MATS else gen_base.MATERIALS[n]()
        out.append(f'            "{n}": {ron}')
    return ",\n".join(out)


def centre(model):
    lo, hi = model.bounds()
    return (lo + hi) / 2, lo, hi


def f3(v):
    return f"({v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f})"


def node_mesh(name, glb, model, at, parent, tags=None, cast=True):
    tag = f"        tags: [{', '.join(chr(34) + t + chr(34) for t in tags)}],\n" if tags else ""
    par = f"        parent: Some({parent}),\n" if parent is not None else ""
    shadow = "" if cast else "        cast_shadow: false,\n"
    return f'''    (
        name: "{name}",
{tag}        transform: (
            translation: {f3(at)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "{glb}",
        ),
        object_materials: {{
{mats_of(model)},
        }},
        scripts: [],
{par}{shadow}    ),
'''


def node_box(name, c, s, q, parent, friction=0.9):
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(c)},
            rotation: ({q[0]:.5f}, {q[1]:.5f}, {q[2]:.5f}, {q[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
        cast_shadow: false,
{gen_base.collider_block(np.asarray(s) / 2, friction=friction)}    ),
'''


def write_part(name, about, root, shell, children, dry, folder="models/base/parts"):
    """root: (glb, model); children: [(node name, glb, model)]; shell: Shell."""
    rc, lo, hi = centre(root[1])
    seat = rc[1]
    nodes = [node_mesh(name, f"{folder}/{root[0]}", root[1], (0, 0, 0), None, tags=["base_part"])]
    for (cname, cglb, cmodel) in children:
        cc, _, _ = centre(cmodel)
        nodes.append(node_mesh(cname, f"{folder}/{cglb}", cmodel, cc - rc, 0))
    for i, (c, s, q) in enumerate(shell.boxes if shell else []):
        nodes.append(node_box(f"Wall {i + 1}", np.asarray(c) - rc, s, q, 0))
    all_lo, all_hi = lo.copy(), hi.copy()
    for (_, _, cm) in children:
        l2, h2 = cm.bounds()
        all_lo, all_hi = np.minimum(all_lo, l2), np.maximum(all_hi, h2)
    tris = root[1].tris() + sum(cm.tris() for (_, _, cm) in children)
    print(f"{name:14s} seat {seat:+.4f}  box {f3(all_hi - all_lo)}  ground-frame lo {f3(all_lo)} hi {f3(all_hi)}"
          f"  tris {tris}  colliders {len(shell.boxes) if shell else 0}")
    if dry:
        return seat
    for (glb, model) in [root] + [(g, mm) for (_, g, mm) in children]:
        zcheck(model, glb, verbose=True)
        gen_base.write_glb(model.shifted(np.zeros(3)), os.path.join(ROOT, folder, glb))
    with open(os.path.join(PREFABS, f"{name}.prefab.ron"), "w") as f:
        f.write(f"// {about}\n// Written by tools/gen_base_parts.py — edit the generator, not this file.\n[\n")
        f.write("".join(nodes))
        f.write("]\n")
    return seat


def main():
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    pm, psh = pad_plate()
    write_part("BasePadPlate", "PAD PLATE — a 4 x 4 m precast slab (BASE section, scripts/parts_base.lua).",
               ("pad_plate.glb", pm), psh, [], dry)
    sm, ssh = shed_shell()
    write_part("BaseShed", "EQUIPMENT SHED — a 3.0 x 2.4 x 2.6 m steel shelter; walls are its future subShapes.",
               ("shed.glb", sm), ssh, [("Interior", "shed_interior.glb", shed_interior())], dry)
    hm, hsh = hab_frame()
    write_part("BaseHab", "SURFACE HAB — a 4 x 6 m pressure can on saddles; the Shell child is its future rb.shell.",
               ("hab_frame.glb", hm), hsh,
               [("Shell", "hab_shell.glb", hab_shell()), ("Interior", "hab_interior.glb", hab_interior())], dry)
    km = build_kit()
    write_part("ItemBuildKit", "BUILD KIT — the Engineer's field tablet, carried by its handle (scripts/field_builder.lua).",
               ("build_kit.glb", km), None, [], dry, folder="models/items")


if __name__ == "__main__":
    main()
