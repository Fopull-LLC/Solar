#!/usr/bin/env python3
"""Generate the MEDICAL BAY's interior (missions M1, Ty 2026-11-11).

    python3 tools/gen_medical.py           # models/medical/*.glb, prefabs/MedInterior, textures/medical/*
    python3 tools/gen_medical.py --dry     # tris, z-fight check (with the shell and the link)

The shell is FacMedical (tools/base_buildings.py medical(), written by
tools/gen_base.py) and the link to the lab is MedLink; MedInterior's origin IS
FacMedical's (the shell's box centre), so base_facilities spawns them with one
position and rotation, and scripts/medical.lua switches the interior on only
near the bay. It is VISUAL ONLY: every solid is one of the shell's collider
boxes (base_buildings MED_SOLIDS), drawn here to the same numbers, so nothing
that collides is ever switched off (lab.lua's lesson: a parked collider comes
back where the planet was).

WHAT IS IN IT, in the shell's ground frame (y up from the ground, the slab's
top at 0.12, +z the front, the room 12.3 × 16.3 m inside):
  * the DRIVE-IN BAY (east): sealed painted concrete, a yellow box line and a
    stop line, a decon tray and shower, a painted dado, steel shelving with
    supply bins, spine boards, a hose reel, a wheelchair, high-bay lamps;
  * the TREATMENT AREA (west): sheet vinyl, white satin wall panels, a
    dropped ceiling with LED panels; two hospital beds heads to the north
    wall under a headwall (oxygen, vacuum and air outlets, reading lamps),
    curtain tracks with the curtains drawn back, patient monitors on arms, IV
    poles, an exam lamp over Bed 1, the crash cart the medic works at, an
    oxygen cylinder rack, glass-front supply cabinets, a sink, a wall
    defibrillator, the medic's desk and terminal, lockers, a stretcher
    trolley at the bay's edge, a triage chart;
  * honest wear: scuffed traffic lanes, tape on the floor, a mop bucket.

Materials: the lab's (tools/gen_lab.py, textures/lab/*), the bay's own plates
and screens (tools/med_signs.py, textures/medical/signs.png), and the lab's
cloth for curtains, bedding and the stretcher pad.
"""
import math
import os
import shutil
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base_tex  # noqa: E402
import base_buildings  # noqa: E402
import gen_lab  # noqa: E402
import med_signs  # noqa: E402
from base_models import CModel, cuboid, zcheck  # noqa: E402
from gen_base import MATERIALS, f3, spot_rotation, write_glb  # noqa: E402
from gen_lab import Bx, Tb, _mat as lab_mat, empty_node, light_node  # noqa: E402
from gen_part_meshes import PREFABS, ROOT, box  # noqa: E402

MODELS = os.path.join(ROOT, "models", "medical")
M_ = base_buildings.MED
S_ = base_buildings.MED_SOLIDS
BEDS = base_buildings.BEDS
BED = base_buildings.BED
W, D, H, t = M_["W"], M_["D"], M_["H"], M_["t"]
XI = W - t - 0.03                  # the lining's (and every wall fixing's) plane
ZI = D - t - 0.03
FY = 0.13                          # the drawn floor (1 cm over the slab)
CEIL = M_["ceil"]
TX = M_["treat_x1"]                # the treatment area's east edge
ROOF = H - 0.3                     # the roof slab's underside over the bay
DX0, DX1, DH = M_["door_x0"], M_["door_x1"], M_["door_h"]
WZ0, WZ1, WH = M_["walk_z0"], M_["walk_z1"], M_["walk_h"]

# colours (vertex colours on near-white textures)
WALL = (0.92, 0.925, 0.915)
SEAM = (0.55, 0.56, 0.56)
DADO = (0.50, 0.57, 0.55)          # the bay's painted block: a hospital green-grey, scuffed
VINYL = (0.70, 0.74, 0.72)         # treatment floor: a pale sage sheet vinyl
EPOXY = (0.46, 0.48, 0.47)         # the bay floor: sealed concrete, tyre-marked
STEEL = (0.78, 0.79, 0.80)
STEEL_D = (0.42, 0.43, 0.44)
CASE = (0.88, 0.885, 0.88)
DARKP = (0.06, 0.065, 0.07)
YEL = (0.80, 0.62, 0.08)
RED = (0.58, 0.07, 0.05)
GRN = (0.08, 0.40, 0.20)
LAMP = (0.66, 0.655, 0.635)
SHEET = (0.84, 0.87, 0.88)
BLANKET = (0.36, 0.46, 0.58)
CURTAIN = (0.52, 0.64, 0.62)
ORANGE = (0.78, 0.36, 0.08)


class Med:
    def __init__(self):
        self.room = CModel(601)
        self.furn = CModel(602)
        self.glass = CModel(603)
        for m in (self.room, self.furn, self.glass):
            m.ground = False


def quad_floor(m, mat, col, x0, x1, z0, z1, y, wear=None, step=0.6, seed=1):
    """A floor in quads (so the wear can be coloured in): `wear(x, z)` darkens."""
    rng = np.random.default_rng(seed)
    xs = list(np.arange(x0, x1, step)) + [x1]
    zs = list(np.arange(z0, z1, step)) + [z1]
    P, N, UV, I, C = [], [], [], [], []
    for i in range(len(xs) - 1):
        for j in range(len(zs) - 1):
            a, b, c, d = xs[i], xs[i + 1], zs[j], zs[j + 1]
            if b - a < 1e-4 or d - c < 1e-4:
                continue
            k = len(P)
            for (x, z) in ((a, c), (b, c), (b, d), (a, d)):
                P.append((x, y, z)); N.append((0, 1, 0)); UV.append((x * 0.5, z * 0.5))
                w = (wear(x, z) if wear else 0.0) + rng.uniform(-0.008, 0.008)
                C.append(np.array(col) * (1 - w))
            I += [(k, k + 2, k + 1), (k, k + 3, k + 2)]
    m.color = col
    m.add(mat, P, N, UV, I)
    m.cols[mat][-1] = np.array(C)


def lanes(paths):
    def f(x, z):
        a = 0.0
        for (x0, z0, x1, z1, r, k) in paths:
            dx, dz = x1 - x0, z1 - z0
            tt = max(0.0, min(1.0, ((x - x0) * dx + (z - z0) * dz) / max(dx * dx + dz * dz, 1e-6)))
            dd = math.hypot(x - (x0 + dx * tt), z - (z0 + dz * tt))
            a += math.exp(-(dd / r) ** 2) * k
        return a
    return f


def panels(m, axis, fixed, a0, a1, normal, y0, y1, col=WALL, gaps=(), seam=True, step=1.2):
    """Wall panels along `axis` at the fixed coordinate (a0..a1), y0..y1,
    skipping the (g0, g1, top) gaps (a header over each)."""
    edges = list(np.arange(a0, a1, step)) + [a1]
    for a, b in zip(edges[:-1], edges[1:]):
        spans = [(a + 0.002, b - 0.002)]
        for (g0, g1, gt) in gaps:
            ns = []
            for (s0, s1) in spans:
                if s1 <= g0 or s0 >= g1:
                    ns.append((s0, s1))
                else:
                    if s0 < g0:
                        ns.append((s0, g0))
                    if s1 > g1:
                        ns.append((g1, s1))
                    hs, he = max(s0, g0), min(s1, g1)
                    if gt < y1 and he - hs > 0.01:
                        _panel(m, axis, fixed, hs, he, gt, y1, normal, col)
            spans = ns
        for (s0, s1) in spans:
            _panel(m, axis, fixed, s0, s1, y0, y1, normal, col)
        if seam and b < a1 - 1e-6:
            inside_gap = any(g0 <= b <= g1 for (g0, g1, _) in gaps)
            if not inside_gap:
                if axis == "x":
                    Bx(m, "LabWall", SEAM, b - 0.002, b + 0.002, y0, y1, fixed, fixed + normal * 0.004)
                else:
                    Bx(m, "LabWall", SEAM, fixed, fixed + normal * 0.004, y0, y1, b - 0.002, b + 0.002)


def _panel(m, axis, fixed, s0, s1, y0, y1, normal, col):
    if s1 - s0 < 0.01 or y1 - y0 < 0.01:
        return
    if axis == "x":
        Bx(m, "LabWall", col, s0, s1, y0, y1, fixed, fixed + normal * 0.012)
    else:
        Bx(m, "LabWall", col, fixed, fixed + normal * 0.012, y0, y1, s0, s1)


def mplate(m, reg, center, right, up, width, depth=0.008, back=CASE):
    """One of the bay's own plates (MedSign), proud of its wall."""
    h = width * med_signs.aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float) + o * depth / 2
    cuboid(m, c, right, up, width, h, depth, faces={"front": ("MedSign", (1, 1, 1), reg)}, col=back, mat="LabWall")
    return h


def mscreen(m, reg, center, right, up, width, bezel=0.02, depth=0.035):
    """A display: a dark bezel box, its face the region, unlit (MedScreen)."""
    h = width * med_signs.aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float)
    cuboid(m, c - o * depth / 2, right, up, width + 2 * bezel, h + 2 * bezel, depth, col=DARKP, mat="LabResin")
    cuboid(m, c + o * 0.0015, right, up, width, h, 0.003, faces={"front": ("MedScreen", (1, 1, 1), reg)}, col=DARKP,
           mat="LabResin")
    return h


def visible_only(m):
    """gen_lab.visible_only for this room: without the faces nobody can see
    (what stands on the floor, its faces down onto it; what meets a ceiling,
    its faces up into it; faces on the lining's back plane, toward the shell)."""
    out = CModel()
    out.ground = False
    for mat, (Ps, Ns, UVs, Is, _) in m.parts.items():
        P = np.vstack(Ps); I = np.vstack(Is); T_ = np.concatenate(m.tags[mat])
        A, Bv, C = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
        n = np.cross(Bv - A, C - A)
        n = n / (np.linalg.norm(n, axis=1) + 1e-12)[:, None]
        cx = (A[:, 0] + Bv[:, 0] + C[:, 0]) / 3
        cy = (A[:, 1] + Bv[:, 1] + C[:, 1]) / 3
        cz = (A[:, 2] + Bv[:, 2] + C[:, 2]) / 3
        hide = (n[:, 1] < -0.99) & (cy < FY + 0.003)
        hide |= (n[:, 1] > 0.99) & (((cy > CEIL - 0.012) & (cy < CEIL + 0.01) & (cx < TX)) | (cy > ROOF - 0.012))
        hide |= (np.abs(n[:, 0]) > 0.99) & (np.abs(cx) > XI - 0.001) & (np.sign(n[:, 0]) == np.sign(cx))
        hide |= (np.abs(n[:, 2]) > 0.99) & (np.abs(cz) > ZI - 0.001) & (np.sign(n[:, 2]) == np.sign(cz))
        keep = ~hide
        if not keep.any():
            continue
        out.parts[mat] = ([P], [np.vstack(Ns)], [np.vstack(UVs)], [I[keep]], None)
        out.tags[mat] = [T_[keep]]
        out.cols[mat] = [np.vstack(m.cols[mat])]
    return out


def tagged(models):
    """The models merged, each one's triangles under one tag: zcheck then
    counts only pairs ACROSS them (each was checked on its own)."""
    out = CModel()
    out.ground = False
    for i, mod in enumerate(models):
        out.merge(mod)
        for mat in mod.parts:
            out.tags[mat][-1] = np.full(len(out.tags[mat][-1]), 1000 + i)
    return out


# ═════════════════════════════════════════════════════════════════════════════
# the room
# ═════════════════════════════════════════════════════════════════════════════

def room(K):
    m = K.room
    # FLOORS: vinyl in the treatment area, sealed concrete in the bay
    quad_floor(m, "LabFloor", VINYL, -XI, TX, -ZI, ZI, FY, seed=3,
               wear=lanes([(-6.1, 0.15, -3.3, -3.6, 0.8, 0.06), (-6.1, 0.15, 0.0, 2.0, 0.8, 0.05),
                           (-3.3, -3.6, -3.3, 3.0, 0.7, 0.04), (-4.2, 6.6, -1.0, 2.0, 0.7, 0.03)]))
    quad_floor(m, "LabFloor", EPOXY, TX, XI, -ZI, ZI, FY, seed=4, step=0.8,
               wear=lanes([(1.7, 8.1, 1.7, -2.6, 0.35, 0.10), (3.8, 8.1, 3.8, -2.6, 0.35, 0.10),
                           (2.75, 2.0, -0.6, 1.0, 1.2, 0.04)]))
    # the bay's box line and stop line (Bay Floor 2.75, 2.6; BAY hx 3.0, hz 5.5)
    by = FY + 0.003
    bx0, bx1, bz0, bz1 = -0.25, 5.75, -2.9, 8.1
    for (xa, xb, za, zb) in ((bx0, bx0 + 0.1, bz0, bz1), (bx1 - 0.1, bx1, bz0, bz1)):
        Bx(m, "LabResin", YEL, xa, xb, FY, by, za, zb)
    for k in range(17):
        xa = 0.6 + k * 0.25
        Bx(m, "LabResin", RED if k % 2 else (0.86, 0.86, 0.84), xa, min(4.9, xa + 0.25), FY, by + 0.001, -2.9, -2.7)
    # decon tray: a shallow stainless pan with a grate, in the bay's north-east corner
    Bx(m, "LabSteel", STEEL, 3.7, 5.9, FY, FY + 0.05, -ZI + 0.02, -6.9)
    Bx(m, "LabSteel", STEEL_D, 3.8, 5.8, FY + 0.05, FY + 0.052, -ZI + 0.12, -7.0)
    for k in range(12):
        xa = 3.85 + k * 0.16
        Bx(m, "LabSteel", STEEL, xa, xa + 0.05, FY + 0.052, FY + 0.06, -ZI + 0.12, -7.0)
    # tape on the floor (a parking box for the trolley, a worn strip)
    for (xa, xb, za, zb) in ((-1.30, -1.26, 2.85, 5.15), (-0.48, -0.44, 2.85, 5.15), (-1.26, -0.48, 2.85, 2.89),
                             (-1.26, -0.48, 5.11, 5.15)):
        Bx(m, "LabResin", (0.70, 0.55, 0.10), xa, xb, FY, FY + 0.002, za, zb)
    # WALLS. Treatment area: white satin panels to the dropped ceiling, a
    # steel skirting; the bay: a painted dado to 2.4 m (the cladding above)
    panels(m, "x", -ZI, -XI, TX, 1, FY + 0.1, CEIL)                       # north (treatment)
    panels(m, "x", ZI, -XI, TX, -1, FY + 0.1, CEIL)                       # south (treatment)
    panels(m, "z", -XI, -ZI + 0.013, ZI - 0.013, 1, FY + 0.1, CEIL, gaps=[(WZ0, WZ1, WH)])   # west, the walk-in
    for (axis, fx, a0, a1, n) in (("x", -ZI, TX, XI, 1), ("z", XI, -ZI + 0.013, ZI - 0.013, -1)):
        panels(m, axis, fx, a0, a1, n, FY + 0.1, 2.4, col=DADO, step=2.4)
    for (a0, a1) in ((TX, DX0 - 0.3), (DX1 + 0.3, XI)):
        panels(m, "x", ZI, a0, a1, -1, FY + 0.1, 2.4, col=DADO, step=2.4)
    # skirting (steel in treatment, black rubber in the bay) and the dado's rail
    for (x0, x1, z0, z1, col, mat) in (
            (-XI, TX, -ZI + 0.012, -ZI + 0.03, STEEL, "LabSteel"), (-XI, TX, ZI - 0.03, ZI - 0.012, STEEL, "LabSteel"),
            (-XI + 0.012, -XI + 0.03, -ZI + 0.03, WZ0, STEEL, "LabSteel"), (-XI + 0.012, -XI + 0.03, WZ1, ZI - 0.03, STEEL, "LabSteel"),
            (TX, XI, -ZI + 0.012, -ZI + 0.03, DARKP, "LabResin"), (XI - 0.03, XI - 0.012, -ZI + 0.03, ZI - 0.03, DARKP, "LabResin"),
            (TX, DX0 - 0.3, ZI - 0.03, ZI - 0.012, DARKP, "LabResin"), (DX1 + 0.3, XI - 0.03, ZI - 0.03, ZI - 0.012, DARKP, "LabResin")):
        Bx(m, mat, col, x0, x1, FY, FY + 0.1, z0, z1)
    for (x0, x1, z0, z1) in ((TX, XI, -ZI + 0.012, -ZI + 0.05), (XI - 0.05, XI - 0.012, -ZI + 0.05, ZI - 0.05),
                             (TX, DX0 - 0.3, ZI - 0.05, ZI - 0.012), (DX1 + 0.3, XI - 0.05, ZI - 0.05, ZI - 0.012)):
        Bx(m, "LabResin", (0.30, 0.34, 0.33), x0, x1, 2.4, 2.46, z0, z1)
    # THE CEILING over the treatment area: 600 mm tiles, LED panels, and the
    # bulkhead down to it from the bay's roof
    gx = list(np.arange(-XI, TX, 0.6)) + [TX]
    gz = list(np.arange(-ZI, ZI, 0.6)) + [ZI]
    lamps = []
    for i in range(len(gx) - 1):
        for j in range(len(gz) - 1):
            x0, x1, z0, z1 = gx[i], gx[i + 1], gz[j], gz[j + 1]
            lit = (i % 4 == 2) and (j % 5 == 2) and x1 - x0 > 0.5 and z1 - z0 > 0.5
            m.color = LAMP if lit else (0.92, 0.925, 0.92)
            m.add("LabLamp" if lit else "LabWall", [(x0, CEIL, z0), (x1, CEIL, z0), (x1, CEIL, z1), (x0, CEIL, z1)],
                  [(0, -1, 0)] * 4, [(x0, z0), (x1, z0), (x1, z1), (x0, z1)], [(0, 1, 2), (0, 2, 3)])
            if lit:
                lamps.append(((x0 + x1) / 2, (z0 + z1) / 2))
    for x in gx[1:-1]:
        Bx(m, "LabWall", (0.86, 0.865, 0.86), x - 0.01, x + 0.01, CEIL - 0.018, CEIL - 0.001, -ZI + 0.014, ZI - 0.014)
    for z in gz[1:-1]:
        Bx(m, "LabWall", (0.86, 0.865, 0.86), -XI + 0.014, TX - 0.014, CEIL - 0.016, CEIL - 0.002, z - 0.012, z + 0.012)
    Bx(m, "LabWall", WALL, TX, TX + 0.03, CEIL, ROOF, -ZI + 0.013, ZI - 0.013)
    Bx(m, "LabSteel", STEEL, TX - 0.02, TX + 0.05, CEIL - 0.06, CEIL, -ZI + 0.013, ZI - 0.013)
    # high-bay lamps over the bay on drop rods, and the cable trays
    for x in (1.4, 4.1):
        for z in (-5.0, 0.0, 5.0):
            Tb(m, "LabSteel", STEEL_D, (x, ROOF, z), (x, 4.45, z), 0.008, segs=6)
            Bx(m, "LabSteel", STEEL_D, x - 0.22, x + 0.22, 4.35, 4.45, z - 0.6, z + 0.6)
            m.color = LAMP
            box(m, "LabLamp", (x, 4.345, z), (0.38, 0.01, 1.1))
    for z in (-6.8, 6.8):
        Bx(m, "LabSteel", STEEL_D, TX + 0.3, XI - 0.3, 4.6, 4.612, z - 0.15, z + 0.15)
        for s in (-1, 1):
            Bx(m, "LabSteel", STEEL_D, TX + 0.31, XI - 0.31, 4.597, 4.66, z + s * 0.15 - 0.004, z + s * 0.15 + 0.004)
    return lamps


# ═════════════════════════════════════════════════════════════════════════════
# the treatment area
# ═════════════════════════════════════════════════════════════════════════════

def bed(K, c, seed):
    m, sh = K.furn, None
    z0, z1, top = BED["z0"], BED["z1"], BED["top"]
    hw = BED["hw"]
    # castors and legs, the frame, the base cover
    for (xx, zz) in ((c - hw + 0.08, z0 + 0.12), (c + hw - 0.08, z0 + 0.12), (c - hw + 0.08, z1 - 0.12), (c + hw - 0.08, z1 - 0.12)):
        Tb(m, "LabResin", DARKP, (xx - 0.03, FY + 0.06, zz), (xx + 0.03, FY + 0.06, zz), 0.055, segs=12)
        Tb(m, "LabSteel", STEEL, (xx, FY + 0.11, zz), (xx, 0.30, zz), 0.022, segs=8)
    Bx(m, "LabSteel", STEEL, c - hw + 0.03, c + hw - 0.03, 0.30, 0.36, z0 + 0.06, z1 - 0.06)
    Bx(m, "LabResin", (0.80, 0.81, 0.80), c - hw + 0.05, c + hw - 0.05, 0.36, 0.42, z0 + 0.08, z1 - 0.08)
    # head and foot boards
    Bx(m, "LabResin", (0.74, 0.76, 0.76), c - hw, c + hw, 0.36, 1.02, z0, z0 + 0.05, bevel=0.015)
    Bx(m, "LabResin", (0.74, 0.76, 0.76), c - hw, c + hw, 0.36, 0.86, z1 - 0.05, z1, bevel=0.015)
    # the mattress, the sheet folded down, the blanket, the pillow
    Bx(m, "MedCloth", SHEET, c - hw + 0.04, c + hw - 0.04, 0.42, top - 0.04, z0 + 0.07, z1 - 0.07, bevel=0.03)
    Bx(m, "MedCloth", BLANKET, c - hw + 0.02, c + hw - 0.02, top - 0.06, top, -7.05, z1 - 0.06, bevel=0.012)
    Bx(m, "MedCloth", SHEET, c - hw + 0.025, c + hw - 0.025, top - 0.045, top + 0.008, -7.18, -7.04, bevel=0.01)
    Bx(m, "MedCloth", (0.93, 0.94, 0.94), c - 0.30, c + 0.30, top - 0.04, top + 0.08, z0 + 0.12, z0 + 0.50, bevel=0.04)
    # side rails, half length, folded down on Bed 2, up on Bed 1
    up = 1 if seed % 2 else 0
    for s in (-1, 1):
        xr = c + s * (hw + 0.02)
        yr = top + (0.22 if up else -0.08)
        Tb(m, "LabSteel", STEEL, (xr, yr, -7.75), (xr, yr, -6.65), 0.016, segs=8)
        Tb(m, "LabSteel", STEEL, (xr, yr - 0.14, -7.75), (xr, yr - 0.14, -6.65), 0.012, segs=8)
        for zz in (-7.7, -6.7):
            Tb(m, "LabSteel", STEEL, (xr, 0.40, zz), (xr, yr, zz), 0.014, segs=8)
    # the chart clipped on the foot board
    Bx(m, "LabResin", (0.36, 0.25, 0.14), c - 0.12, c + 0.12, 0.55, 0.80, z1 + 0.001, z1 + 0.008)
    Bx(m, "LabWall", (0.95, 0.95, 0.93), c - 0.105, c + 0.105, 0.56, 0.77, z1 + 0.008, z1 + 0.010)


def curtains(K, c):
    """The curtain track round a bed, on hangers from the ceiling, and the
    curtains drawn back to the head end, pleated."""
    m = K.furn
    y = 2.42
    xa, xb, zf = c - 0.66, c + 0.66, -5.55
    za = -ZI + 0.06
    for p0, p1 in (((xa, y, za), (xa, y, zf)), ((xa, y, zf), (xb, y, zf)), ((xb, y, zf), (xb, y, za))):
        Tb(m, "LabSteel", STEEL, p0, p1, 0.016, segs=8)
    for p in ((xa, zf), (xb, zf), (xa, -6.8), (xb, -6.8)):
        Tb(m, "LabSteel", STEEL_D, (p[0], y, p[1]), (p[0], CEIL, p[1]), 0.006, segs=6)
    for xx in (xa, xb):
        for k in range(9):
            zz = -8.0 + k * 0.07
            off = 0.035 if k % 2 else -0.035
            Bx(m, "MedCloth", CURTAIN, xx + off - 0.012, xx + off + 0.012, 0.45, y - 0.03, zz, zz + 0.08)


def headwall(K):
    m = K.furn
    z0 = -ZI + 0.015
    Bx(m, "LabResin", (0.82, 0.84, 0.84), -6.0, -0.85, 1.25, 1.75, z0, z0 + 0.09, bevel=0.01)
    Bx(m, "LabResin", (0.30, 0.38, 0.46), -6.0, -0.85, 1.36, 1.39, z0 + 0.09, z0 + 0.092)
    for c in BEDS:
        for k, col in enumerate(((0.92, 0.94, 0.95), GRN, YEL, (0.86, 0.86, 0.86))):
            xx = c - 0.36 + k * 0.16
            Tb(m, "LabResin", col, (xx, 1.52, z0 + 0.09), (xx, 1.52, z0 + 0.13), 0.028, segs=12)
            Tb(m, "LabSteel", STEEL, (xx, 1.52, z0 + 0.13), (xx, 1.52, z0 + 0.15), 0.014, segs=8)
        # sockets, the nurse-call handset on its curly lead
        for k in range(3):
            xx = c + 0.18 + k * 0.1
            Bx(m, "LabResin", (0.94, 0.94, 0.93), xx, xx + 0.08, 1.28, 1.34, z0 + 0.09, z0 + 0.1)
        Tb(m, "LabResin", DARKP, (c - 0.42, 1.30, z0 + 0.1), (c - 0.30, 0.75, z0 + 0.5), 0.006, segs=6)
        Bx(m, "LabResin", (0.85, 0.86, 0.86), c - 0.34, c - 0.26, 0.70, 0.86, z0 + 0.47, z0 + 0.53, bevel=0.01)
        # the reading lamp along the headwall's top
        m.color = LAMP
        box(m, "LabLamp", (c, 1.755, z0 + 0.05), (0.7, 0.01, 0.06))
        # the patient monitor on its arm, turned to the bed
        ax = c + 0.62
        Bx(m, "LabSteel", STEEL_D, ax - 0.05, ax + 0.05, 1.86, 2.0, z0, z0 + 0.06)
        Tb(m, "LabSteel", STEEL, (ax, 1.93, z0 + 0.06), (ax - 0.1, 1.93, z0 + 0.42), 0.022, segs=8)
        mscreen(m, "m_ecg", (ax - 0.1, 2.0, z0 + 0.46), (1, 0, 0), (0, 0.97, 0.24), 0.34)
        # the name plate over the bed
        mplate(m, "m_bed1" if c == BEDS[0] else "m_bed2", (c, 2.75, -ZI + 0.012), (1, 0, 0), (0, 1, 0), 0.62)


def iv_pole(K, k):
    m, g = K.furn, K.glass
    x0, x1, _, _, z0, z1 = S_[k]
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    Tb(m, "LabSteel", STEEL, (cx, FY + 0.08, cz), (cx, 1.98, cz), 0.012, segs=8)
    for a in range(5):
        aa = a * 2 * math.pi / 5
        Tb(m, "LabSteel", STEEL_D, (cx, FY + 0.08, cz), (cx + 0.07 * math.cos(aa), FY + 0.04, cz + 0.07 * math.sin(aa)),
           0.01, segs=6)
        Tb(m, "LabResin", DARKP, (cx + 0.07 * math.cos(aa), FY + 0.02, cz + 0.07 * math.sin(aa)),
           (cx + 0.07 * math.cos(aa), FY + 0.035, cz + 0.07 * math.sin(aa)), 0.014, segs=6)
    for s in (-1, 1):
        Tb(m, "LabSteel", STEEL, (cx, 1.96, cz), (cx + s * 0.1, 1.98, cz), 0.006, segs=6)
    g.color = (1, 1, 1)
    box(g, "LabGlass", (cx + 0.1, 1.80, cz), (0.07, 0.17, 0.025))
    Tb(m, "LabResin", (0.85, 0.86, 0.86), (cx + 0.1, 1.71, cz), (cx + 0.08, 1.0, cz + 0.12), 0.003, segs=4)


def crash_cart(K):
    m = K.furn
    x0, x1, y0, y1, z0, z1 = S_["cart"]
    Bx(m, "LabResin", (0.62, 0.08, 0.06), x0 + 0.02, x1 - 0.02, FY + 0.12, y1 - 0.04, z0 + 0.02, z1 - 0.02, bevel=0.01)
    Bx(m, "LabResin", (0.20, 0.21, 0.22), x0, x1, y1 - 0.04, y1, z0, z1, bevel=0.008)
    for k in range(5):
        yy = FY + 0.18 + k * 0.13
        Bx(m, "LabResin", (0.50, 0.06, 0.05), x0 + 0.04, x1 - 0.04, yy, yy + 0.11, z1 - 0.022, z1 - 0.012)
        Bx(m, "LabSteel", STEEL, (x0 + x1) / 2 - 0.1, (x0 + x1) / 2 + 0.1, yy + 0.04, yy + 0.06, z1 - 0.012, z1 - 0.002)
    for (xx, zz) in ((x0 + 0.06, z0 + 0.06), (x1 - 0.06, z0 + 0.06), (x0 + 0.06, z1 - 0.06), (x1 - 0.06, z1 - 0.06)):
        Tb(m, "LabResin", DARKP, (xx - 0.02, FY + 0.045, zz), (xx + 0.02, FY + 0.045, zz), 0.045, segs=10)
    # on top: the defibrillator, a tray of syringes, a sharps bin
    Bx(m, "LabResin", (0.86, 0.68, 0.10), x0 + 0.06, x0 + 0.36, y1, y1 + 0.14, z0 + 0.06, z0 + 0.32, bevel=0.01)
    mscreen(m, "m_ecg", (x0 + 0.21, y1 + 0.10, z0 + 0.325), (1, 0, 0), (0, 0.8, 0.6), 0.14, bezel=0.008, depth=0.01)
    Bx(m, "LabSteel", STEEL, x0 + 0.42, x1 - 0.08, y1, y1 + 0.03, z0 + 0.12, z1 - 0.1)
    Bx(m, "LabResin", (0.82, 0.70, 0.10), x1 - 0.06, x1 + 0.06, y1 - 0.25, y1 - 0.05, z0 + 0.1, z0 + 0.22)


def o2_rack(K):
    m = K.furn
    x0, x1, _, y1, z0, z1 = S_["o2"]
    Bx(m, "LabSteel", STEEL_D, x0, x1, FY, FY + 0.04, z0 + 0.02, z1 - 0.02)
    for yy in (0.6, 1.2):
        Bx(m, "LabSteel", STEEL_D, x0, x1, yy, yy + 0.03, z1 - 0.06, z1 - 0.03)
    for k, xx in enumerate((x0 + 0.13, x1 - 0.13)):
        zc = (z0 + z1) / 2
        Tb(m, "LabResin", (0.08, 0.30, 0.16), (xx, FY + 0.04, zc), (xx, 1.25, zc), 0.105, segs=16)
        Tb(m, "LabResin", (0.92, 0.93, 0.93), (xx, 1.25, zc), (xx, 1.38, zc), 0.105, segs=16, r1=0.05)
        Tb(m, "LabSteel", STEEL, (xx, 1.38, zc), (xx, 1.47, zc), 0.025, segs=8)
    mplate(m, "m_oxy", ((x0 + x1) / 2, 2.0, -ZI + 0.012), (1, 0, 0), (0, 1, 0), 0.62)


def west_wall(K):
    m, g = K.furn, K.glass
    # SUPPLY CABINETS, glass fronted, boxes and bottles behind
    x0, x1, _, y1, z0, z1 = S_["cab"]
    x0 = -XI
    Bx(m, "LabWall", CASE, x0, x1, FY, FY + 0.08, z0, z1)
    Bx(m, "LabWall", CASE, x0, x1 - 0.03, FY + 0.08, y1 - 0.04, z0, z0 + 0.03)
    Bx(m, "LabWall", CASE, x0, x1 - 0.03, FY + 0.08, y1 - 0.04, z1 - 0.03, z1)
    Bx(m, "LabWall", CASE, x0, x1, y1 - 0.04, y1, z0, z1)
    Bx(m, "LabWall", (0.86, 0.87, 0.86), x0, x0 + 0.02, FY + 0.08, y1 - 0.04, z0 + 0.03, z1 - 0.03)
    rng = np.random.default_rng(71)
    for k in range(5):
        yy = FY + 0.08 + k * 0.38
        Bx(m, "LabSteel", STEEL, x0 + 0.02, x1 - 0.05, yy, yy + 0.015, z0 + 0.03, z1 - 0.03)
        zz = z0 + 0.08
        while zz < z1 - 0.3 and k < 4:
            w = rng.uniform(0.12, 0.28)
            col = [(0.86, 0.85, 0.80), (0.70, 0.78, 0.86), (0.85, 0.64, 0.42), (0.92, 0.92, 0.92)][int(rng.integers(0, 4))]
            Bx(m, "LabResin", col, x0 + 0.05, x0 + 0.05 + rng.uniform(0.18, 0.32), yy + 0.015, yy + rng.uniform(0.12, 0.30),
               zz, zz + w)
            zz += w + rng.uniform(0.02, 0.06)
    g.color = (1, 1, 1)
    for k in range(3):
        za = z0 + 0.04 + k * (z1 - z0 - 0.08) / 3
        zb = za + (z1 - z0 - 0.08) / 3 - 0.02
        Bx(m, "LabSteel", (0.86, 0.87, 0.86), x1 - 0.03, x1, FY + 0.1, y1 - 0.05, za, za + 0.03)
        box(g, "LabGlass", (x1 - 0.015, (FY + 0.1 + y1 - 0.05) / 2, (za + zb) / 2), (0.006, y1 - FY - 0.17, zb - za - 0.04))
        Tb(m, "LabSteel", STEEL, (x1 + 0.02, 1.0, zb - 0.06), (x1 + 0.02, 1.25, zb - 0.06), 0.008, segs=6)
    # THE SINK: a base cabinet, a steel top and basin, an elbow tap, soap
    x0, x1, _, y1, z0, z1 = S_["sink"]
    x0 = -XI
    Bx(m, "LabWall", CASE, x0, x1 - 0.02, FY, y1 - 0.04, z0 + 0.02, z1 - 0.02)
    Bx(m, "LabSteel", STEEL, x0, x1, y1 - 0.04, y1, z0, z1)
    Bx(m, "LabSteel", STEEL_D, x0 + 0.1, x1 - 0.1, y1 + 0.002, y1 + 0.004, z0 + 0.12, z1 - 0.12)
    Tb(m, "LabSteel", STEEL, (x0 + 0.06, y1, (z0 + z1) / 2), (x0 + 0.06, y1 + 0.32, (z0 + z1) / 2), 0.015, segs=8)
    Tb(m, "LabSteel", STEEL, (x0 + 0.06, y1 + 0.32, (z0 + z1) / 2), (x0 + 0.24, y1 + 0.26, (z0 + z1) / 2), 0.013, segs=8)
    Bx(m, "LabResin", (0.92, 0.92, 0.90), x0 + 0.012, x0 + 0.08, 1.15, 1.40, z1 - 0.2, z1 - 0.08)
    mplate(m, "m_wash", (-XI + 0.012, 1.62, (z0 + z1) / 2), (0, 0, -1), (0, 1, 0), 0.5)
    # the AED on the wall south of the doorway, its sign over it
    Bx(m, "LabResin", GRN, -XI + 0.012, -XI + 0.14, 1.05, 1.45, 1.55, 1.95, bevel=0.012)
    Bx(m, "LabResin", (0.85, 0.86, 0.86), -XI + 0.14, -XI + 0.142, 1.12, 1.38, 1.62, 1.88)
    mplate(m, "m_aed", (-XI + 0.012, 1.62, 1.75), (0, 0, -1), (0, 1, 0), 0.5)
    # over the walk-in: the way to the lab
    mplate(m, "m_lab", (-XI + 0.012, WH + 0.28, (WZ0 + WZ1) / 2), (0, 0, -1), (0, 1, 0), 0.9)
    # THE DESK: a top on legs, the terminal turned to the room, papers, a mug
    x0, x1, _, y1, z0, z1 = S_["desk"]
    x0 = -XI
    Bx(m, "LabResin", (0.42, 0.40, 0.36), x0, x1, y1 - 0.035, y1, z0, z1, bevel=0.005)
    for (xx, zz) in ((x1 - 0.05, z0 + 0.05), (x1 - 0.05, z1 - 0.05)):
        Bx(m, "LabSteel", STEEL_D, xx - 0.025, xx + 0.025, FY, y1 - 0.035, zz - 0.025, zz + 0.025)
    Bx(m, "LabWall", CASE, x0, x0 + 0.5, FY, y1 - 0.04, z0 + 0.02, z0 + 0.45)
    mscreen(m, "m_term", (x0 + 0.22, y1 + 0.30, (z0 + z1) / 2), (0, 0, -1), (0.2, 0.98, 0), 0.5)
    Bx(m, "LabResin", DARKP, x0 + 0.13, x0 + 0.17, y1, y1 + 0.16, (z0 + z1) / 2 - 0.03, (z0 + z1) / 2 + 0.03)
    Bx(m, "LabResin", (0.12, 0.12, 0.13), x0 + 0.42, x0 + 0.58, y1, y1 + 0.015, (z0 + z1) / 2 - 0.22, (z0 + z1) / 2 + 0.22)
    for k in range(3):
        Bx(m, "LabWall", (0.95, 0.95, 0.93), x0 + 0.30 + k * 0.004, x0 + 0.51 + k * 0.004, y1 + k * 0.004, y1 + k * 0.004 + 0.003,
           z0 + 0.15 + k * 0.03, z0 + 0.45 + k * 0.03)
    Tb(m, "LabResin", (0.62, 0.20, 0.12), (x1 - 0.15, y1, z1 - 0.2), (x1 - 0.15, y1 + 0.1, z1 - 0.2), 0.04, segs=12)
    mplate(m, "m_officer", (-XI + 0.012, 1.95, (z0 + z1) / 2), (0, 0, -1), (0, 1, 0), 0.7)
    # the chair
    x0, x1, _, y1, z0, z1 = S_["chair"]
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    Tb(m, "LabSteel", STEEL_D, (cx, FY + 0.06, cz), (cx, y1 - 0.06, cz), 0.025, segs=8)
    Bx(m, "LabResin", (0.12, 0.14, 0.18), x0, x1, y1 - 0.06, y1, z0, z1, bevel=0.02)
    Bx(m, "LabResin", (0.12, 0.14, 0.18), x1 - 0.06, x1, y1, y1 + 0.42, z0 + 0.04, z1 - 0.04, bevel=0.02)
    for a in range(5):
        aa = a * 2 * math.pi / 5
        Tb(m, "LabSteel", STEEL_D, (cx, FY + 0.06, cz), (cx + 0.26 * math.cos(aa), FY + 0.04, cz + 0.26 * math.sin(aa)), 0.012, segs=6)
    # the triage chart
    mplate(m, "m_triage", (-XI + 0.012, 1.85, 5.0), (0, 0, -1), (0, 1, 0), 0.6, back=(0.9, 0.9, 0.88))


def lockers(K):
    m = K.furn
    x0, x1, _, y1, z0, z1 = S_["lockers"]
    z1 = ZI
    n = 6
    w = (x1 - x0) / n
    for k in range(n):
        xa = x0 + k * w
        col = (0.42, 0.48, 0.52) if k % 3 else (0.40, 0.46, 0.50)
        Bx(m, "LabSteel", col, xa + 0.005, xa + w - 0.005, FY, y1, z0 + 0.01, z1)
        Bx(m, "LabSteel", (0.36, 0.41, 0.45), xa + 0.03, xa + w - 0.03, FY + 0.05, y1 - 0.05, z0, z0 + 0.01)
        for j in range(4):
            yy = y1 - 0.25 - j * 0.035
            Bx(m, "LabSteel", DARKP, xa + 0.10, xa + w - 0.10, yy, yy + 0.012, z0 - 0.002, z0)
        Bx(m, "LabSteel", STEEL, xa + w - 0.09, xa + w - 0.06, 1.0, 1.15, z0 - 0.02, z0)
    # a jacket hanging off one door, a helmet on top
    Bx(m, "MedCloth", ORANGE, x0 + 0.08, x0 + 0.34, 0.9, 1.6, z0 - 0.06, z0 - 0.02, bevel=0.02)
    Tb(m, "LabResin", (0.88, 0.88, 0.86), (x0 + w * 4.5, y1, z0 + 0.22), (x0 + w * 4.5, y1 + 0.16, z0 + 0.22), 0.13, segs=14, r1=0.09)


def bucket(K):
    m = K.furn
    x0, x1, _, y1, z0, z1 = S_["bucket"]
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    Tb(m, "LabResin", YEL, (cx, FY, cz), (cx, y1 - 0.12, cz), 0.17, segs=16, r1=0.19)
    Bx(m, "LabResin", YEL, x0 - 0.02, x1 + 0.02, FY + 0.02, y1 - 0.18, z0 - 0.06, z0 + 0.05)
    Tb(m, "LabSteel", STEEL_D, (cx + 0.05, FY + 0.15, cz), (cx + 0.22, 1.35, cz - 0.30), 0.012, segs=6)


def trolley(K):
    m = K.furn
    x0, x1, _, y1, z0, z1 = S_["trolley"]
    for (xx, zz) in ((x0 + 0.06, z0 + 0.1), (x1 - 0.06, z0 + 0.1), (x0 + 0.06, z1 - 0.1), (x1 - 0.06, z1 - 0.1)):
        Tb(m, "LabResin", DARKP, (xx - 0.02, FY + 0.06, zz), (xx + 0.02, FY + 0.06, zz), 0.06, segs=10)
        Tb(m, "LabSteel", STEEL, (xx, FY + 0.12, zz), (xx, y1 - 0.08, zz), 0.018, segs=8)
    Bx(m, "LabSteel", STEEL, x0, x1, y1 - 0.12, y1 - 0.08, z0 + 0.05, z1 - 0.05)
    Bx(m, "MedCloth", ORANGE, x0 + 0.02, x1 - 0.02, y1 - 0.08, y1, z0 + 0.06, z1 - 0.06, bevel=0.02)
    for zz in (z0 + 0.5, z1 - 0.7):
        Bx(m, "LabResin", (0.10, 0.10, 0.11), x0 - 0.005, x1 + 0.005, y1 - 0.06, y1 + 0.005, zz, zz + 0.05)
    for s in (-1, 1):
        xr = (x0 + x1) / 2 + s * ((x1 - x0) / 2 + 0.02)
        Tb(m, "LabSteel", STEEL, (xr, y1 + 0.15, z0 + 0.3), (xr, y1 + 0.15, z1 - 0.3), 0.012, segs=6)
        for zz in (z0 + 0.3, z1 - 0.3):
            Tb(m, "LabSteel", STEEL, (xr, y1 - 0.1, zz), (xr, y1 + 0.15, zz), 0.012, segs=6)


# ═════════════════════════════════════════════════════════════════════════════
# the bay
# ═════════════════════════════════════════════════════════════════════════════

def bay(K):
    m = K.furn
    # steel shelving on the east wall: bins, boxes, a first-aid kit
    x0, x1, _, y1, z0, z1 = S_["shelf"]
    x1 = XI
    for xx in (x0 + 0.02, x1 - 0.03):
        for zz in (z0 + 0.02, z1 - 0.02):
            Bx(m, "LabSteel", STEEL_D, xx - 0.015, xx + 0.015, FY, y1, zz - 0.015, zz + 0.015)
    rng = np.random.default_rng(73)
    for k in range(4):
        yy = FY + 0.15 + k * 0.52
        Bx(m, "LabSteel", STEEL, x0, x1, yy, yy + 0.025, z0, z1)
        zz = z0 + 0.06
        while zz < z1 - 0.35:
            w = rng.uniform(0.25, 0.42)
            col = [(0.20, 0.36, 0.58), (0.62, 0.12, 0.08), (0.80, 0.62, 0.12), (0.30, 0.32, 0.34)][int(rng.integers(0, 4))]
            Bx(m, "LabResin", col, x0 + 0.04, x1 - 0.04, yy + 0.025, yy + rng.uniform(0.18, 0.34), zz, zz + w)
            zz += w + 0.04
    # spine boards leaning on the wall, a hose reel, the decon shower
    x0, x1, _, y1, z0, z1 = S_["boards"]
    for k in range(3):
        za = z0 + 0.05 + k * 0.5
        Bx(m, "LabResin", (0.80 - k * 0.04, 0.42, 0.10), XI - 0.05 - k * 0.04, XI - 0.02 - k * 0.04, FY + 0.02, y1, za, za + 0.42)
    Tb(m, "LabSteel", (0.62, 0.08, 0.06), (XI, 1.3, 6.3), (XI - 0.22, 1.3, 6.3), 0.32, segs=20)
    Tb(m, "LabResin", (0.62, 0.12, 0.08), (XI - 0.02, 1.3, 6.3), (XI - 0.20, 1.3, 6.3), 0.27, segs=20)
    Tb(m, "LabSteel", STEEL, (5.0, ROOF, -7.5), (5.0, 2.3, -7.5), 0.016, segs=8)
    Tb(m, "LabSteel", STEEL, (5.0, 2.3, -7.5), (5.0, 2.25, -7.5), 0.12, segs=14)
    Tb(m, "LabSteel", STEEL_D, (5.12, 2.27, -7.5), (5.12, 1.6, -7.5), 0.004, segs=4)
    Tb(m, "LabResin", GRN, (5.12, 1.6, -7.5), (5.12, 1.5, -7.5), 0.025, segs=8)
    mplate(m, "m_decon", (2.75, 2.75, -ZI + 0.012), (1, 0, 0), (0, 1, 0), 1.5, back=(0.8, 0.62, 0.15))
    # the first-aid cross on the bulkhead, read from the bay
    mplate(m, "m_cross", (TX + 0.03, 3.9, 0.0), (0, 0, -1), (0, 1, 0), 0.6, back=(0.84, 0.85, 0.84))
    # the wheelchair, parked against the north wall
    x0, x1, _, y1, z0, z1 = S_["chairw"]
    cx = (x0 + x1) / 2
    for s in (-1, 1):
        xw = cx + s * 0.31
        Tb(m, "LabResin", DARKP, (xw - 0.015, 0.43, z1 - 0.3), (xw + 0.015, 0.43, z1 - 0.3), 0.30, segs=20)
        Tb(m, "LabSteel", STEEL, (xw - 0.02, 0.43, z1 - 0.3), (xw + 0.02, 0.43, z1 - 0.3), 0.04, segs=8)
        Tb(m, "LabSteel", STEEL, (cx + s * 0.24, 0.51, z0 + 0.1), (cx + s * 0.24, y1, z0 + 0.1), 0.012, segs=6)
        Tb(m, "LabResin", DARKP, (cx + s * 0.22, FY + 0.06, z1 - 0.05), (cx + s * 0.26, FY + 0.06, z1 - 0.05), 0.06, segs=8)
    Bx(m, "MedCloth", (0.12, 0.13, 0.15), cx - 0.24, cx + 0.24, 0.5, 0.54, z0 + 0.1, z1 - 0.15)
    Bx(m, "MedCloth", (0.12, 0.13, 0.15), cx - 0.24, cx + 0.24, 0.54, y1 - 0.05, z0 + 0.08, z0 + 0.12)


def exam_lamp(K):
    m = K.furn
    c = BEDS[0]
    Bx(m, "LabSteel", STEEL, c - 0.08, c + 0.08, CEIL - 0.04, CEIL - 0.002, -6.98, -6.82)
    Tb(m, "LabSteel", STEEL, (c, CEIL - 0.04, -6.9), (c, 2.75, -6.9), 0.025, segs=10)
    Tb(m, "LabSteel", STEEL, (c, 2.75, -6.9), (c + 0.32, 2.42, -6.9), 0.02, segs=10)
    Tb(m, "LabSteel", (0.88, 0.89, 0.89), (c + 0.32, 2.42, -6.9), (c + 0.32, 2.32, -6.9), 0.24, segs=24, r1=0.27)
    Tb(m, "LabLamp", LAMP, (c + 0.32, 2.318, -6.9), (c + 0.32, 2.316, -6.9), 0.23, segs=24)


def main():
    dry = "--dry" in sys.argv
    tmp = tempfile.mkdtemp(prefix="gen_medical_")
    shutil.copy(os.path.join(base_tex.OUT, "concrete_albedo.png"), tmp)
    base_tex.OUT = tmp                     # (the base atlas, laid out for its regions only)
    base_tex.signs()
    med_signs.signs(None if dry else os.path.join(ROOT, "textures", "medical"))
    K = Med()
    lamps = room(K)
    for i, c in enumerate(BEDS):
        bed(K, c, i + 1)
        curtains(K, c)
    headwall(K)
    iv_pole(K, "iv1")
    iv_pole(K, "iv2")
    crash_cart(K)
    o2_rack(K)
    west_wall(K)
    lockers(K)
    bucket(K)
    trolley(K)
    bay(K)
    exam_lamp(K)
    fights = 0
    allm = CModel()
    for name, m in (("room", K.room), ("furniture", K.furn), ("glass", K.glass)):
        fights += zcheck(visible_only(m), name)
        allm.merge(m)
        print(f"{name:10s} {m.tris():7d} tris  {','.join(sorted(m.parts))}")
    shell, sh, _, _ = base_buildings.medical()
    link, _ = base_buildings.medical_link()
    fights += zcheck(visible_only(allm), "interior (all parts)")
    fights += zcheck(tagged([visible_only(allm), shell, link]), "MedInterior against FacMedical and MedLink")
    print(f"interior {allm.tris()} tris, {len(lamps)} ceiling panels; shell {len(sh.boxes)} collider boxes")
    if fights:
        print(f"!! {fights} z-fighting face pairs: nothing written")
        sys.exit(1)
    mn, mx = shell.bounds()
    origin = (mn + mx) / 2
    print("origin (FacMedical's box centre):", np.round(origin, 3))
    if dry:
        return
    os.makedirs(MODELS, exist_ok=True)

    def mat(n):
        if n == "MedSign":
            return med_signs.MED_SIGN
        if n == "MedScreen":
            return med_signs.MED_SCREEN
        if n == "MedCloth":
            tt = "textures/lab/"
            return (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{tt}cloth_albedo.png"),\n'
                    f'                normal_map: Some("{tt}cloth_normal.png"),\n                normal_strength: 1.0,\n'
                    f'                roughness_map: Some("{tt}cloth_orm.png"),\n                roughness: 1.0,\n'
                    '                metallic: 0.0,\n                reflectivity: 0.15,\n'
                    f'                ao_map: Some("{tt}cloth_orm.png"),\n                shading: Physical,\n            )')
        return lab_mat(n)

    def mesh_node(name, glb, model, pos, extra=""):
        mats = ",\n".join(f'            "{n}": {mat(n)}' for n in sorted(model.parts.keys()))
        return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(pos)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/medical/{glb}",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
        parent: Some(0),
{extra}    ),
'''
    out = ['''// MED INTERIOR — the Medical Bay's rooms (tools/gen_medical.py; edit the generator, not this file).
// Same origin as FacMedical (its box centre): spawn both with one position and rotation.
// Visual only: every solid is a collider box of FacMedical's. scripts/medical.lua (on FacMedical)
// switches this node's drawn children and its lights on only near the bay.
[
    (
        name: "MedInterior",
        tags: ["med_interior"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
    ),
''']
    for name, m in (("MedRoom", K.room), ("MedFurniture", K.furn), ("MedGlass", K.glass)):
        mn_, mx_ = m.bounds()
        c = (mn_ + mx_) / 2
        glb = name.lower() + ".glb"
        write_glb(m.shifted(c), os.path.join(MODELS, glb))
        extra = "        cast_shadow: false,\n" if name == "MedGlass" else ""
        out.append(mesh_node(name, glb, m, c - origin, extra=extra))
    LIGHTS = [("Med Light Bay", (2.75, 4.2, 1.5), (0.94, 0.97, 1.0), 2.4, 12.0, None),
              ("Med Light Treat", (-3.4, 2.85, -3.0), (1.0, 0.955, 0.90), 2.0, 10.0, None),
              ("Med Light Exam", (BEDS[0] + 0.32, 2.2, -6.9), (1.0, 0.93, 0.82), 1.6, 5.0, (-0.12, -1.0, 0.1))]
    for (nm, p, col, inten, rng, aim) in LIGHTS:
        out.append(light_node(nm, np.asarray(p) - origin, col, inten, rng, aim=aim, angle=60.0))
    out.append("]\n")
    with open(os.path.join(PREFABS, "MedInterior.prefab.ron"), "w") as f:
        f.write("".join(out))
    print("wrote models/medical/*.glb, prefabs/MedInterior.prefab.ron, textures/medical/*")


if __name__ == "__main__":
    main()
