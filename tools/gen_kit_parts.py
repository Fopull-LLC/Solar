#!/usr/bin/env python3
"""Generate the modular structure kit's pieces (sandbox plan S1; scripts/parts_kit.lua).

    python3 tools/gen_kit_parts.py          # models/kit/*.glb, prefabs/Kit*.prefab.ron, the bounds fixture
    python3 tools/gen_kit_parts.py --dry    # bounds and counts only

Every piece is built 1:1 in its GROUND frame (its ground point is the origin,
+Y up, +Z its front, metres), one model per piece and material, from the
spaceport's primitives and its CC0/procedural PBR sets (textures/base:
concrete, cladding, steel; tools/base_tex.py). Nothing new is painted: the
material is the set, the paint is the vertex colour (regocrete is the concrete
set in a regolith brown).

THE PREFAB: the root is an Empty AT THE GROUND POINT (so parts_kit's `seat` is
0 for every piece); its children are the "Mesh" (at its own box centre: the
engine centres a model on its box), its static collider boxes ("Wall N", in
the ground frame), and what a live piece moves or lights:
  "Door" (and "Door2" for a pair)  the leaf's mesh, with ITS colliders as its
                children ("Door Wall N"): scripts/kit_live.lua slides the node
                and the colliders follow (a Collidable moved by a script);
  "Light"       an Empty where the point light goes (kit_live pools them);
  "Screen"      a quad kit_live paints with the base's status.
Interiors are walkable because the walls, floors and fittings are static
collider boxes on the planet, as the Research Lab's are (no kinematic fakes).

The bounds fixture (tests/fixtures/kit_shapes.lua) is what smoke_kit checks
parts_kit's nominal boxes against.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT, PREFABS, box, disk, lathe, rot_x, rot_y, rot_z, tube  # noqa: E402
from base_models import (CModel, CONC, DARK, GREY, LIGHT, PAINT, RUBBER, SAFETY, Shell, SLATE, WARM,  # noqa: E402
                         LAMP_WARM, zcheck, stair, quat_from_basis)
import gen_base  # noqa: E402

MODELS = os.path.join(ROOT, "models", "kit")
FOLDER = "models/kit"
TAU = 2 * math.pi
UVM = {"Concrete": 0.25, "Clad": 0.5, "Steel": 1.0, "Pane": 1.0, "Lamp": 2.5, "Rubber": 4.0, "Screen": 1.0}
REGO = (0.66, 0.53, 0.42)          # regolith concrete: a dusty ochre-brown
STEELWALL = (0.74, 0.74, 0.71)     # a factory-white sandwich panel, weathered
WT, WH = 0.2, 2.2

MATS = dict(gen_base.MATERIALS)
# a real pane: laminated glass the light comes through (the Lab's)
MATS["Pane"] = lambda: ('(\n                color: (0.90, 0.95, 0.96),\n                roughness: 0.04,\n'
                        '                metallic: 0.0,\n                transmission: 0.9,\n                ior: 1.5,\n'
                        '                thickness: 0.012,\n                shading: Physical,\n            )')
MATS["Rubber"] = lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/rubber_albedo.png"),\n'
                          '                normal_map: Some("textures/parts/rubber_normal.png"),\n                normal_strength: 1.0,\n'
                          '                roughness_map: Some("textures/parts/rubber_orm.png"),\n                roughness: 1.0,\n'
                          '                ao_map: Some("textures/parts/rubber_orm.png"),\n                shading: Physical,\n            )')
# (the screen's face: kit_live paints it; until then a dark glass)
MATS["Screen"] = lambda: ('(\n                color: (0.05, 0.07, 0.08),\n                roughness: 0.2,\n'
                          '                metallic: 0.0,\n                emissive: (0.02, 0.05, 0.07),\n                shading: Physical,\n            )')


# ── primitives (no automatic footing: a piece stands where it is put) ───────

def bx(m, mat, col, x0, x1, y0, y1, z0, z1, sh=None, M=None):
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    z0, z1 = min(z0, z1), max(z0, z1)
    m.color = col
    c = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    s = (x1 - x0, y1 - y0, z1 - z0)
    box(m, mat, c, s, M=M, uv_m=UVM.get(mat, 1.0))
    if sh is not None:
        sh.add(c, s)


def tb(m, mat, col, p0, p1, r, segs=8):
    m.color = col
    tube(m, mat, p0, p1, r, segs=segs, uv_m=UVM.get(mat, 1.0))


def rbox(m, mat, col, c, s, M, sh=None):
    """A box at centre c, size s, turned by M (columns = its axes)."""
    m.color = col
    box(m, mat, c, s, M=M, uv_m=UVM.get(mat, 1.0))
    if sh is not None:
        sh.add(c, s, quat_from_basis(M))


def prism_x(m, mat, col, poly, x0, x1):
    """A prism along X from a convex (z, y) polygon (counter-clockwise seen
    from +X), planar UVs in metres."""
    m.color = col
    uv = UVM.get(mat, 1.0)
    P, N, UV, I = [], [], [], []
    n = len(poly)
    for x, sx in ((x1, 1.0), (x0, -1.0)):
        base = len(P)
        for (z, y) in poly:
            P.append((x, y, z)); N.append((sx, 0, 0)); UV.append((z * uv, y * uv))
        for k in range(1, n - 1):
            I.append((base, base + k, base + k + 1))
    for k in range(n):
        (za, ya), (zb, yb) = poly[k], poly[(k + 1) % n]
        dz, dy = zb - za, yb - ya
        l = math.hypot(dz, dy) or 1.0
        nn = (0, -dz / l, dy / l)
        base = len(P)
        for (x, z, y) in ((x0, za, ya), (x1, za, ya), (x1, zb, yb), (x0, zb, yb)):
            P.append((x, y, z)); N.append(nn); UV.append((x * uv, (z * dy - y * dz) / l * uv + (z if abs(dy) < 1e-6 else 0) * 0))
        I.append((base, base + 1, base + 2)); I.append((base, base + 2, base + 3))
    m.add(mat, P, N, UV, I)


def prism_z(m, mat, col, poly, z0, z1):
    """A prism along Z from a convex (x, y) polygon."""
    sub = CModel(seed=7)
    sub.ground = m.ground
    prism_x(sub, mat, col, [(-x, y) for (x, y) in poly], -z1, -z0)
    m.merge(sub, M=rot_y(-math.pi / 2))


# ── the materials' looks ─────────────────────────────────────────────────────

def look(mat):
    """(surface material, paint) for a piece's body in kit material `mat`."""
    return {"steel": ("Clad", STEELWALL), "concrete": ("Concrete", CONC), "regocrete": ("Concrete", REGO),
            "glass": ("Steel", GREY)}[mat]


def solid_cells(x0, x1, y0, y1, holes):
    """The wall [x0,x1]×[y0,y1] less rectangular holes, as boxes (x0,x1,y0,y1)."""
    xs = sorted({x0, x1, *[h[0] for h in holes], *[h[1] for h in holes]})
    xs = [x for x in xs if x0 <= x <= x1]
    out = []
    for a, b in zip(xs, xs[1:]):
        if b - a < 1e-6:
            continue
        cuts = sorted([(h[2], h[3]) for h in holes if h[0] <= a + 1e-6 and h[1] >= b - 1e-6])
        y = y0
        for (c0, c1) in cuts:
            if c0 > y + 1e-6:
                out.append((a, b, y, c0))
            y = max(y, c1)
        if y < y1 - 1e-6:
            out.append((a, b, y, y1))
    return out


def wall_body(m, sh, mat, x0, x1, y0, y1, holes=(), t=WT, trims=True):
    """A wall panel with rectangular holes, in its material. Steel: a
    sandwich panel (cladding faces over a core) with galvanised top and
    bottom channels and end studs. Concrete / regocrete: a precast panel
    with a cast steel lifting insert on top. Glass: a steel frame round a
    pane (the holes, if any, framed)."""
    surf, col = look(mat)
    hz = t / 2
    if mat == "glass":
        f = 0.08
        for (a, b, c, d) in solid_cells(x0, x1, y0, y1, [(x0 + f, x1 - f, y0 + f, y1 - f)]):
            bx(m, "Steel", GREY, a, b, c, d, -hz, hz)
        sh.add(((x0 + x1) / 2, (y0 + y1) / 2, 0), (x1 - x0, y1 - y0, t))
        cells = solid_cells(x0 + f, x1 - f, y0 + f, y1 - f, holes)
        for (a, b, c, d) in cells:
            bx(m, "Pane", (1, 1, 1), a, b, c, d, -0.012, 0.012)
        # a transom and a mullion: a 2 m pane is two
        if x1 - x0 > 1.5:
            bx(m, "Steel", GREY, -0.03, 0.03, y0 + f, y1 - f, -0.05, 0.05)
        return
    cells = solid_cells(x0, x1, y0, y1, holes)
    if mat == "steel":
        e = 0.05
        for (a, b, c, d) in cells:
            a2 = a + (e if abs(a - x0) < 1e-6 else 0)
            b2 = b - (e if abs(b - x1) < 1e-6 else 0)
            c2 = c + (e if abs(c - y0) < 1e-6 else 0)
            d2 = d - (e if abs(d - y1) < 1e-6 else 0)
            if b2 - a2 > 1e-3 and d2 - c2 > 1e-3:
                bx(m, "Clad", col, a2, b2, c2, d2, -hz, hz)
            sh.add(((a + b) / 2, (c + d) / 2, 0), (b - a, d - c, t))
        # the channels and studs at the panel's own edges (where it is solid)
        for (a, b, c, d) in cells:
            if abs(c - y0) < 1e-6:
                bx(m, "Steel", GREY, a, b, y0, y0 + e, -hz - 0.004, hz + 0.004)
            if abs(d - y1) < 1e-6:
                bx(m, "Steel", GREY, a, b, y1 - e, y1, -hz - 0.004, hz + 0.004)
            if abs(a - x0) < 1e-6:
                bx(m, "Steel", GREY, x0, x0 + e, max(c, y0 + e), min(d, y1 - e), -hz - 0.003, hz + 0.003)
            if abs(b - x1) < 1e-6:
                bx(m, "Steel", GREY, x1 - e, x1, max(c, y0 + e), min(d, y1 - e), -hz - 0.003, hz + 0.003)
    else:
        for (a, b, c, d) in cells:
            bx(m, "Concrete", col, a, b, c, d, -hz, hz, sh=sh)
        if y1 - y0 > 1.0:
            for x in ((x0 + x1) / 2 - (x1 - x0) / 4, (x0 + x1) / 2 + (x1 - x0) / 4):
                if any(a <= x <= b and d >= y1 - 1e-6 for (a, b, c, d) in cells):
                    bx(m, "Steel", DARK, x - 0.05, x + 0.05, y1 - 0.004, y1 + 0.006, -0.05, 0.05)
    # reveals round every hole: a steel lining through the wall and a trim proud of each face
    if trims:
        for (a, b, c, d) in holes:
            r = 0.035
            for (p0, p1, q0, q1) in ((a - r, a, c, d), (b, b + r, c, d), (a - r, b + r, d, d + r)) + (((a - r, b + r, c - r, c),) if c > y0 + 1e-3 else ()):
                bx(m, "Steel", GREY, p0, p1, q0, q1, -hz - 0.012, hz + 0.012)


def door_leaf(w, h, heavy=False, window=True, t=0.05):
    """A sliding leaf about its own bottom centre: (model, its colliders)."""
    m = CModel(seed=301)
    m.ground = False
    sh = Shell()
    col = (0.62, 0.62, 0.60) if not heavy else (0.55, 0.50, 0.32)
    bx(m, "Steel", col, -w / 2, w / 2, 0.005, h, -t / 2, t / 2)
    sh.add((0, h / 2, 0), (w, h, t))
    # a kick plate, a pull, a vision panel
    bx(m, "Steel", DARK, -w / 2 + 0.03, w / 2 - 0.03, 0.03, 0.28, -t / 2 - 0.004, t / 2 + 0.004)
    for s in (-1, 1):
        bx(m, "Steel", LIGHT, -w / 2 + 0.06, -w / 2 + 0.09, 0.85, 1.25, s * (t / 2 + 0.02) - 0.012, s * (t / 2 + 0.02) + 0.012)
    if window:
        wy0, wy1 = (1.25, 1.75) if not heavy else (1.35, 1.65)
        ww = 0.22 if not heavy else 0.30
        bx(m, "Steel", DARK, -ww / 2 - 0.03, ww / 2 + 0.03, wy0 - 0.03, wy1 + 0.03, -t / 2 - 0.006, t / 2 + 0.006)
        bx(m, "Pane", (1, 1, 1), -ww / 2, ww / 2, wy0, wy1, -t / 2 - 0.008, t / 2 + 0.008)
    if heavy:
        # dogs round the edge and hazard chevrons along the leading edge
        for y in (0.4, 1.0, 1.6):
            for s in (-1, 1):
                bx(m, "Steel", DARK, -w / 2 + 0.02, -w / 2 + 0.10, y, y + 0.08, s * (t / 2 + 0.012) - 0.01, s * (t / 2 + 0.012) + 0.01)
        for k in range(8):
            y = 0.12 + k * 0.24
            bx(m, "Steel", SAFETY if k % 2 == 0 else DARK, -w / 2 - 0.004, -w / 2 + 0.05, y, y + 0.24, -t / 2 - 0.003, t / 2 + 0.003)
    return m, sh


# ── the pieces: each returns (model, colliders, children) ───────────────────
# children: list of (name, kind, data) — ("Door", "door", (model, shell, at)),
# ("Light", "empty", at), ("Screen", "mesh", (model, at))

def p_slab2(mat):
    m, sh = CModel(seed=11), Shell()
    surf, col = look(mat)
    bx(m, "Concrete", col, -1, 1, -0.10, 0.20, -1, 1, sh=sh)
    for s in (-1, 1):
        bx(m, "Steel", GREY, -1, 1, 0.20, 0.206, s * 0.965 - 0.035, s * 0.965 + 0.035)
        bx(m, "Steel", GREY, s * 0.965 - 0.035, s * 0.965 + 0.035, 0.20, 0.206, -0.93, 0.93)
    for sx in (-1, 1):
        bx(m, "Steel", DARK, sx * 0.6 - 0.06, sx * 0.6 + 0.06, 0.20, 0.205, -0.06, 0.06)
    return m, sh, []


def p_pier(mat):
    m, sh = CModel(seed=12), Shell()
    if mat == "concrete":
        bx(m, "Concrete", CONC, -0.25, 0.25, 0, 1.47, -0.25, 0.25, sh=sh)
    else:
        bx(m, "Steel", GREY, -0.12, 0.12, 0.03, 1.47, -0.12, 0.12)
        bx(m, "Steel", DARK, -0.25, 0.25, 0, 0.03, -0.25, 0.25)
        sh.add((0, 0.75, 0), (0.5, 1.5, 0.5))
        for a in range(4):
            c, s = math.cos(a * math.pi / 2), math.sin(a * math.pi / 2)
            rbox(m, "Steel", GREY, (0.18 * c, 0.15, 0.18 * s), (0.12, 0.24, 0.015),
                 np.array([[c, 0, -s], [0, 1, 0], [s, 0, c]]))
    bx(m, "Steel", DARK, -0.25, 0.25, 1.47, 1.5, -0.25, 0.25)
    return m, sh, []


def p_ramp(mat):
    m, sh = CModel(seed=13), Shell()
    surf, col = ("Concrete", CONC) if mat == "concrete" else ("Steel", GREY)
    prism_x(m, surf, col, [(2, 0), (-2, 0.5), (-2, 0)], -1, 1)
    ang = math.atan2(0.5, 4.0)
    L = math.hypot(4, 0.5)
    c, s = math.cos(ang), math.sin(ang)
    M = np.array([[1, 0, 0], [0, c, s], [0, -s, c]])
    sh.add((0, 0.25 - 0.06 * c, 0 - 0.06 * s * 0), (2, 0.12, L), quat_from_basis(M))
    if mat == "steel":
        for k in range(8):
            z = 1.75 - k * 0.5
            y = (2 - z) / 8 + 0.002
            rbox(m, "Steel", DARK, (0, y, z), (1.9, 0.012, 0.04), M)
    else:
        for s_ in (-1, 1):
            bx(m, "Steel", SAFETY, s_ * 0.93 - 0.04, s_ * 0.93 + 0.04, 0.004, 0.006, 1.5, 2.0)
    return m, sh, []


def p_stairs(mat, rise=2.4, run=3.6, width=1.6):
    m, sh = CModel(seed=14), Shell()
    m.ground = False
    if mat == "steel":
        kit_stair(m, sh, rise, run, width)
    else:
        n = int(round(rise / 0.2))
        for k in range(n):
            z1 = run / 2 - k * run / n
            bx(m, "Concrete", CONC, -width / 2, width / 2, 0, (k + 1) * rise / n, z1 - run / n, z1)
        for k in range(n):
            z1 = run / 2 - k * run / n
            bx(m, "Steel", SAFETY, -width / 2 + 0.05, width / 2 - 0.05, (k + 1) * rise / n, (k + 1) * rise / n + 0.004, z1 - 0.06, z1 - 0.01)
        d = np.array([0, rise, -run]); f3 = d / np.linalg.norm(d)
        side = np.array([1.0, 0, 0]); upn = np.cross(f3, side)
        if upn[1] < 0:
            upn = -upn
        Mr = np.column_stack([side, upn, f3])
        sh.add((0, rise / 2 - 0.02, 0), (width, 0.16, np.linalg.norm(d) + 0.2), quat_from_basis(Mr))
        for s in (-1, 1):
            a = np.array([s * (width / 2 + 0.05), 0, run / 2])
            tb(m, "Steel", SAFETY, a + (0, 1.0, 0), a + d + (0, 1.0, 0), 0.025, segs=6)
            for k in range(0, n + 1, 3):
                q = a + d * (k / n)
                tb(m, "Steel", SAFETY, q + (0, 0.04, 0), q + (0, 1.0, 0), 0.022, segs=6)
            sh.add(tuple(a + d / 2 + (0, 0.6, 0)), (0.06, 1.1, np.linalg.norm(d)), quat_from_basis(Mr))
    return m, sh, []


def kit_stair(m, sh, rise, run, width):
    """A steel stair from the front foot (z = +run/2, y 0) up to the back
    (z = -run/2, y = rise): two channel stringers, a checker tread every
    0.2 m of rise, handrails both sides; its colliders a ramp along the
    nosings and the two rails (the spaceport's stair, without its footing)."""
    n = max(2, int(round(rise / 0.2)))
    p0 = np.array([0.0, 0.0, run / 2]); d = np.array([0.0, rise, -run])
    L = float(np.linalg.norm(d)); f3 = d / L
    side = np.array([1.0, 0, 0]); upn = np.cross(f3, side)
    if upn[1] < 0:
        upn = -upn
    Mr = np.column_stack([side, upn, f3])
    for s in (-1, 1):
        c = p0 + d / 2 + side * s * (width / 2 + 0.03) + upn * 0.06
        rbox(m, "Steel", GREY, c, (0.05, 0.2, L), Mr)
    for k in range(1, n + 1):
        y = rise * k / n
        z = run / 2 - run * (k - 0.5) / n
        bx(m, "Steel", (0.50, 0.51, 0.52), -width / 2, width / 2, y - 0.04, y, z - run / n * 0.5, z + run / n * 0.5 - 0.01)
        bx(m, "Steel", SAFETY, -width / 2 + 0.02, width / 2 - 0.02, y, y + 0.003, z + run / n * 0.5 - 0.06, z + run / n * 0.5 - 0.02)
    sh.add(tuple(p0 + d / 2 - upn * 0.06), (width, 0.12, L + 0.1), quat_from_basis(Mr))
    for s in (-1, 1):
        a = p0 + side * s * (width / 2 + 0.03)
        tb(m, "Steel", SAFETY, a + (0, 1.0, 0), a + d + (0, 1.0, 0), 0.025, segs=6)
        for k in range(0, n + 1, max(1, n // 4)):
            q = a + d * (k / n)
            tb(m, "Steel", SAFETY, q + (0, 0.1, 0), q + (0, 1.0, 0), 0.022, segs=6)
        sh.add(tuple(a + d / 2 + (0, 0.55, 0)), (0.06, 1.0, L), quat_from_basis(Mr))


def p_steps(mat):
    return p_stairs(mat, rise=0.8, run=1.0, width=1.2)


def p_ladder(mat):
    m, sh, ch = p_stairs("steel", rise=2.4, run=2.2, width=0.7)
    return m, sh, ch


def p_grating(mat):
    m, sh = CModel(seed=15), Shell()
    m.ground = False
    for s in (-1, 1):
        bx(m, "Steel", GREY, -1, 1, 0, 0.1, s * 0.975 - 0.025, s * 0.975 + 0.025)
        bx(m, "Steel", GREY, s * 0.975 - 0.025, s * 0.975 + 0.025, 0, 0.1, -0.95, 0.95)
    for k in range(31):
        x = -0.9 + k * 0.06
        bx(m, "Steel", DARK, x - 0.006, x + 0.006, 0.02, 0.095, -0.95, 0.95)
    for k in range(5):
        z = -0.8 + k * 0.4
        bx(m, "Steel", DARK, -0.95, 0.95, 0.06, 0.09, z - 0.01, z + 0.01)
    sh.add((0, 0.05, 0), (2, 0.1, 2))
    return m, sh, []


def floor_body(m, sh, mat, x0, x1, z0, z1, t=0.2, holes=()):
    """A deck panel [x0,x1]×[z0,z1], 0..t high, less rectangular (x, z) holes."""
    surf, col = look(mat)
    cells = [(a, b, c, d) for (a, b, c, d) in solid_cells(x0, x1, z0, z1, holes)]
    if mat == "glass":
        f = 0.08
        for (a, b, c, d) in solid_cells(x0, x1, z0, z1, [(x0 + f, x1 - f, z0 + f, z1 - f)]):
            bx(m, "Steel", GREY, a, b, 0, t, c, d)
        bx(m, "Pane", (1, 1, 1), x0 + f, x1 - f, t - 0.03, t - 0.006, z0 + f, z1 - f)
        if x1 - x0 > 1.5:
            bx(m, "Steel", GREY, -0.04, 0.04, 0, t - 0.035, z0 + f, z1 - f)
        sh.add(((x0 + x1) / 2, t / 2, (z0 + z1) / 2), (x1 - x0, t, z1 - z0))
        return
    for (a, b, c, d) in cells:
        if mat == "steel":
            bx(m, "Steel", (0.50, 0.51, 0.52), a, b, t - 0.012, t, c, d)
            bx(m, "Steel", DARK, a + 0.003, b - 0.003, 0, t - 0.012, c + 0.003, d - 0.003)
        else:
            bx(m, "Concrete", col, a, b, 0, t, c, d)
        sh.add(((a + b) / 2, t / 2, (c + d) / 2), (b - a, t, d - c))
    for (a, b, c, d) in holes:
        for (p0, p1, q0, q1) in ((a - 0.04, b + 0.04, c - 0.04, c), (a - 0.04, b + 0.04, d, d + 0.04), (a - 0.04, a, c, d), (b, b + 0.04, c, d)):
            bx(m, "Steel", SAFETY, p0, p1, t, t + 0.005, q0, q1)


def p_floor(mat, w=2.0, d=2.0):
    m, sh = CModel(seed=16), Shell()
    m.ground = False
    floor_body(m, sh, mat, -w / 2, w / 2, -d / 2, d / 2)
    return m, sh, []


def p_floor21(mat):
    return p_floor(mat, 2.0, 1.0)


def p_floor11(mat):
    return p_floor(mat, 1.0, 1.0)


def p_floorHatch(mat):
    m, sh = CModel(seed=17), Shell()
    m.ground = False
    hole = (-0.95, -0.05, -0.45, 0.45)
    floor_body(m, sh, mat, -1, 1, -1, 1, holes=[hole])
    lm = CModel(seed=18); lm.ground = False
    lsh = Shell()
    bx(lm, "Steel", (0.50, 0.51, 0.52), -0.45, 0.45, -0.05, 0.0, -0.45, 0.45)
    lsh.add((0, -0.025, 0), (0.9, 0.05, 0.9))
    for k in range(4):
        bx(lm, "Steel", SAFETY if k % 2 == 0 else DARK, -0.45 + k * 0.225, -0.45 + (k + 1) * 0.225, 0.0, 0.004, 0.36, 0.44)
    bx(lm, "Steel", LIGHT, -0.06, 0.06, 0.0, 0.03, -0.30, -0.26)
    return m, sh, [("Door", "door", (lm, lsh, (-0.5, 0.2, 0.0)))]


def p_wall(mat, x0=-1, x1=1, h=WH):
    m, sh = CModel(seed=21), Shell()
    wall_body(m, sh, mat, x0, x1, 0, h)
    return m, sh, []


def p_halfWall(mat):
    return p_wall(mat, h=1.1)


def p_wall12(mat):
    return p_wall(mat, -0.5, 0.5)


def p_doorWall(mat):
    m, sh = CModel(seed=22), Shell()
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.92, 0.0, 0.0, 2.05)])
    # outside: a bulkhead lamp over the door, a threshold plate, a door number
    bx(m, "Steel", DARK, -0.56, -0.36, 2.09, 2.17, WT / 2 + 0.005, WT / 2 + 0.10)
    bx(m, "Lamp", LAMP_WARM, -0.54, -0.38, 2.085, 2.09, WT / 2 + 0.02, WT / 2 + 0.09)
    bx(m, "Steel", GREY, -0.92, 0.0, 0.0, 0.012, -WT / 2 - 0.06, WT / 2 + 0.06)
    for k in range(4):
        bx(m, "Steel", SAFETY if k % 2 == 0 else DARK, 0.08 + k * 0.05, 0.13 + k * 0.05, 1.75, 1.9, WT / 2 + 0.012, WT / 2 + 0.016)
    lm, lsh = door_leaf(0.94, 2.05)
    return m, sh, [("Door", "door", (lm, lsh, (-0.46, 0.0, 0.0)))]


def p_doubleDoor(mat):
    m, sh = CModel(seed=23), Shell()
    wall_body(m, sh, mat, -2, 2, 0, WH, holes=[(-0.9, 0.9, 0.0, 2.05)])
    a, ash = door_leaf(0.92, 2.05)
    b, bsh = door_leaf(0.92, 2.05)
    return m, sh, [("Door", "door", (a, ash, (0.45, 0.0, 0.0))), ("Door2", "door", (b, bsh, (-0.45, 0.0, 0.0)))]


def p_windowWall(mat):
    m, sh = CModel(seed=24), Shell()
    hole = (-0.6, 0.6, 0.9, 1.9)
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[hole])
    # double glazing, a sill outside, the pane's frame
    bx(m, "Pane", (1, 1, 1), -0.6, 0.6, 0.9, 1.9, -0.035, -0.023)
    bx(m, "Pane", (1, 1, 1), -0.6, 0.6, 0.9, 1.9, 0.023, 0.035)
    bx(m, "Steel", DARK, -0.6, 0.6, 1.385, 1.415, -0.04, 0.04)
    bx(m, "Steel", GREY, -0.66, 0.66, 0.86, 0.9, 0.08, 0.17)
    sh.add((0, 1.4, 0), (1.2, 1.0, 0.07))
    return m, sh, []


def p_porthole(mat):
    m, sh = CModel(seed=25), Shell()
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.25, 0.25, 1.3, 1.8)], trims=False)
    cy = 1.55
    for s in (-1, 1):
        m.color = GREY
        sub = CModel(seed=2); sub.ground = False; sub.color = GREY
        disk(sub, "Steel", 0.40, 0.0, segs=28, up=True, r_in=0.25)
        lathe(sub, "Steel", [(0.40, 0.0), (0.40, -0.03)], segs=28)
        M = rot_x(-s * math.pi / 2)
        m.merge(sub, M=M, t=(0, cy, s * (WT / 2 + 0.03)))
        for k in range(8):
            a = k * TAU / 8
            tb(m, "Steel", DARK, (0.33 * math.cos(a), cy + 0.33 * math.sin(a), s * (WT / 2 + 0.03)),
               (0.33 * math.cos(a), cy + 0.33 * math.sin(a), s * (WT / 2 + 0.05)), 0.018, segs=6)
    sub = CModel(seed=3); sub.ground = False; sub.color = (1, 1, 1)
    disk(sub, "Pane", 0.26, 0.0, segs=28, up=True)
    disk(sub, "Pane", 0.26, -0.03, segs=28, up=False)
    m.merge(sub, M=rot_x(-math.pi / 2), t=(0, cy, 0.015))
    sh.add((0, cy, 0), (0.5, 0.5, 0.1))
    return m, sh, []


def p_airlockWall(mat):
    m, sh = CModel(seed=26), Shell()
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.92, 0.0, 0.0, 1.95)], trims=False)
    # a heavy pressure frame proud of both faces, hazard-striped, with its seal
    for s in (-1, 1):
        z0, z1 = s * WT / 2, s * (WT / 2 + 0.06)
        for (a, b, c, d) in ((-1.0, -0.92, 0, 2.05), (0.0, 0.08, 0, 2.05), (-1.0, 0.08, 1.95, 2.13)):
            bx(m, "Steel", (0.55, 0.50, 0.32), a, b, c, d, min(z0, z1) - s * 0.004, max(z0, z1))
        for k in range(9):
            y = k * 0.22
            if k % 2 == 0:
                bx(m, "Steel", DARK, 0.0, 0.08, y, min(1.95, y + 0.22), min(z0, z1) - 0.003 if s < 0 else max(z0, z1) - 0.002,
                   min(z0, z1) + 0.002 if s < 0 else max(z0, z1) + 0.003)
        # the indicator lamp and the cycle panel beside the door
        bx(m, "Steel", DARK, 0.18, 0.38, 1.25, 1.55, s * (WT / 2) - 0.002, s * (WT / 2 + 0.04))
        bx(m, "Lamp", (0.25, 1.0, 0.35), 0.24, 0.32, 1.45, 1.5, s * (WT / 2 + 0.04) - 0.004, s * (WT / 2 + 0.04) + 0.004)
    lm, lsh = door_leaf(0.96, 1.95, heavy=True, t=0.07)
    return m, sh, [("Door", "door", (lm, lsh, (-0.46, 0.0, 0.0)))]


def p_openFrame(mat):
    m, sh = CModel(seed=27), Shell()
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.9, 0.9, 0.0, 2.05)])
    return m, sh, []


def p_ventWall(mat):
    m, sh = CModel(seed=28), Shell()
    hole = (-0.5, 0.5, 1.4, 1.9)
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[hole])
    c, s = math.cos(math.radians(40)), math.sin(math.radians(40))
    M = np.array([[1, 0, 0], [0, c, s], [0, -s, c]])
    for k in range(6):
        y = 1.44 + k * 0.08
        rbox(m, "Steel", GREY, (0, y, 0.06), (1.0, 0.012, 0.11), M)
    bx(m, "Steel", DARK, -0.5, 0.5, 1.4, 1.9, -0.06, -0.055)
    sh.add((0, 1.65, 0), (1.0, 0.5, 0.1))
    return m, sh, []


def p_cornerPost(mat):
    m, sh = CModel(seed=29), Shell()
    if mat == "concrete":
        bx(m, "Concrete", CONC, -0.1, 0.1, 0, WH, -0.1, 0.1, sh=sh)
    else:
        bx(m, "Steel", GREY, -0.1, 0.1, 0, WH, -0.1, 0.1, sh=sh)
        bx(m, "Steel", DARK, -0.104, 0.104, 0, 0.05, -0.104, 0.104)
    return m, sh, []


def p_roofPitch(mat):
    m, sh = CModel(seed=31), Shell()
    m.ground = False
    a = math.radians(30)
    L = 2.0 / math.cos(a)
    c, s = math.cos(a), math.sin(a)
    # the panel rises toward its back (-Z): local z along the slope
    M = np.array([[1, 0, 0], [0, c, s], [0, -s, c]])
    t = 0.12
    n = np.array([0, c, s])
    mid = np.array([0, 1.155 / 2, 0])
    cen = mid - n * (t / 2) + n * t / 2
    cen = mid + n * (t / 2 - t)    # (its top surface on the line from the eave to the ridge)
    if mat == "glass":
        for sx in (-1, 1):
            rbox(m, "Steel", GREY, cen + np.array([sx * 0.96, 0, 0]), (0.08, t, L), M)
        for sz in (-1, 1):
            rbox(m, "Steel", GREY, cen + M @ np.array([0, 0, sz * (L / 2 - 0.04)]), (1.84, t, 0.08), M)
        rbox(m, "Pane", (1, 1, 1), cen + n * (t / 2 - 0.02), (1.84, 0.02, L - 0.16), M)
        rbox(m, "Steel", GREY, cen, (0.06, t * 0.8, L - 0.16), M)
    else:
        rbox(m, "Clad", (0.40, 0.42, 0.44), cen, (2.0, t, L), M)
        # the eave's gutter on the low front edge
        tb(m, "Steel", GREY, (-1, -0.02, 1.02), (1, -0.02, 1.02), 0.06, segs=10)
    sh.add(tuple(cen), (2.0, t, L), quat_from_basis(M))
    return m, sh, []


def p_roofRidge(mat):
    m, sh = CModel(seed=32), Shell()
    m.ground = False
    for s in (-1, 1):
        a = math.radians(30) * s
        c, sn = math.cos(a), math.sin(a)
        M = np.array([[1, 0, 0], [0, c, sn], [0, -sn, c]])
        rbox(m, "Steel", (0.40, 0.42, 0.44), (0, 0.08, -s * 0.09), (2.0, 0.02, 0.2), M)
    tb(m, "Steel", GREY, (-1, 0.13, 0), (1, 0.13, 0), 0.025, segs=8)
    sh.add((0, 0.08, 0), (2.0, 0.16, 0.36))
    return m, sh, []


def p_gable(mat):
    m, sh = CModel(seed=33), Shell()
    surf, col = look(mat)
    poly = [(-1.0, 0.0), (1.0, 0.0), (1.0, 1.155)]
    if mat == "glass":
        prism_z(m, "Steel", GREY, poly, -0.05, 0.05)
    else:
        prism_z(m, surf, col, poly, -WT / 2, WT / 2)
    for k in range(3):
        x0 = -1 + k * 2 / 3
        h = (x0 + 2 / 3 + 1) * 1.155 / 2
        sh.add((x0 + 1 / 3, h / 2, 0), (2 / 3, h, WT))
    return m, sh, []


def p_pillar(mat, h):
    m, sh = CModel(seed=34), Shell()
    if mat == "concrete":
        bx(m, "Concrete", CONC, -0.15, 0.15, 0, h, -0.15, 0.15, sh=sh)
    else:
        bx(m, "Steel", GREY, -0.12, 0.12, 0.02, h - 0.02, -0.12, 0.12)
        bx(m, "Steel", DARK, -0.15, 0.15, 0, 0.02, -0.15, 0.15)
        bx(m, "Steel", DARK, -0.15, 0.15, h - 0.02, h, -0.15, 0.15)
        sh.add((0, h / 2, 0), (0.3, h, 0.3))
    return m, sh, []


def p_pillar2(mat):
    return p_pillar(mat, 2.2)


def p_pillar4(mat):
    return p_pillar(mat, 4.4)


def p_beam(mat, L):
    m, sh = CModel(seed=35), Shell()
    m.ground = False
    bx(m, "Steel", GREY, -L / 2, L / 2, 0, 0.02, -0.1, 0.1)
    bx(m, "Steel", GREY, -L / 2, L / 2, 0.38, 0.4, -0.1, 0.1)
    bx(m, "Steel", GREY, -L / 2, L / 2, 0.02, 0.38, -0.006, 0.006)
    for x in [-L / 2 + 0.01 + k * 1.0 for k in range(int(L) + 1)]:
        x = min(x, L / 2 - 0.01)
        for s in (-1, 1):
            bx(m, "Steel", GREY, x - 0.006, x + 0.006, 0.02, 0.38, s * 0.006, s * 0.09)
    sh.add((0, 0.2, 0), (L, 0.4, 0.2))
    return m, sh, []


def p_beam2(mat):
    return p_beam(mat, 2.0)


def p_beam4(mat):
    return p_beam(mat, 4.0)


def p_truss(mat, L):
    m, sh = CModel(seed=36), Shell()
    m.ground = False
    w = 0.22
    for sx in (-1, 1):
        for sz in (-1, 1):
            tb(m, "Steel", GREY, (sx * w, 0, sz * w), (sx * w, L, sz * w), 0.03, segs=8)
    bays = max(1, int(round(L / 0.5)))
    for k in range(bays + 1):
        y = L * k / bays
        y = min(max(y, 0.015), L - 0.015)
        for (a, b) in (((-w, -w), (w, -w)), ((w, -w), (w, w)), ((w, w), (-w, w)), ((-w, w), (-w, -w))):
            tb(m, "Steel", GREY, (a[0], y, a[1]), (b[0], y, b[1]), 0.015, segs=6)
    for k in range(bays):
        y0, y1 = L * k / bays, L * (k + 1) / bays
        f = 1 if k % 2 == 0 else -1
        for (a, b) in (((-w, -w), (w, -w)), ((w, -w), (w, w)), ((w, w), (-w, w)), ((-w, w), (-w, -w))):
            p0 = (a[0], y0 if f > 0 else y1, a[1]); p1 = (b[0], y1 if f > 0 else y0, b[1])
            tb(m, "Steel", GREY, p0, p1, 0.012, segs=5)
    for y in (0.0, L):
        bx(m, "Steel", DARK, -0.25, 0.25, y - 0.008 if y > 0 else 0, y if y > 0 else 0.008, -0.25, 0.25)
    sh.add((0, L / 2, 0), (0.5, L, 0.5))
    return m, sh, []


def p_truss2(mat):
    return p_truss(mat, 2.0)


def p_truss4(mat):
    return p_truss(mat, 4.0)


def p_truss6(mat):
    return p_truss(mat, 6.0)


def p_trussNode(mat):
    m, sh = CModel(seed=37), Shell()
    m.ground = False
    bx(m, "Steel", GREY, -0.2, 0.2, 0.05, 0.45, -0.2, 0.2)
    for (c, s) in (((0, 0.025, 0), (0.5, 0.05, 0.5)), ((0, 0.475, 0), (0.5, 0.05, 0.5)),
                   ((0.225, 0.25, 0), (0.05, 0.4, 0.5)), ((-0.225, 0.25, 0), (0.05, 0.4, 0.5)),
                   ((0, 0.25, 0.225), (0.4, 0.4, 0.05)), ((0, 0.25, -0.225), (0.4, 0.4, 0.05))):
        bx(m, "Steel", DARK, c[0] - s[0] / 2, c[0] + s[0] / 2, c[1] - s[1] / 2, c[1] + s[1] / 2, c[2] - s[2] / 2, c[2] + s[2] / 2)
    sh.add((0, 0.25, 0), (0.5, 0.5, 0.5))
    return m, sh, []


def p_catwalk(mat):
    m, sh = CModel(seed=38), Shell()
    m.ground = False
    for s in (-1, 1):
        bx(m, "Steel", GREY, s * 0.48 - 0.02, s * 0.48 + 0.02, 0, 0.08, -1, 1)
    for k in range(15):
        x = -0.42 + k * 0.06
        bx(m, "Steel", DARK, x - 0.006, x + 0.006, 0.01, 0.075, -1, 1)
    for k in range(5):
        z = -0.8 + k * 0.4
        bx(m, "Steel", DARK, -0.46, 0.46, 0.04, 0.07, z - 0.01, z + 0.01)
    sh.add((0, 0.04, 0), (1.0, 0.08, 2.0))
    for s in (-1, 1):
        for z in (-0.97, 0.0, 0.97):
            tb(m, "Steel", SAFETY, (s * 0.48, 0.08, z), (s * 0.48, 1.1, z), 0.022, segs=6)
        tb(m, "Steel", SAFETY, (s * 0.48, 1.1, -1.0), (s * 0.48, 1.1, 1.0), 0.025, segs=6)
        tb(m, "Steel", SAFETY, (s * 0.48, 0.6, -1.0), (s * 0.48, 0.6, 1.0), 0.018, segs=6)
        sh.add((s * 0.48, 0.6, 0), (0.06, 1.05, 2.0))
    return m, sh, []


def p_rail(mat):
    m, sh = CModel(seed=39), Shell()
    m.ground = False
    for x in (-0.97, 0.0, 0.97):
        tb(m, "Steel", SAFETY, (x, 0, 0), (x, 1.1, 0), 0.022, segs=6)
        bx(m, "Steel", DARK, x - 0.04, x + 0.04, 0, 0.01, -0.04, 0.04)
    tb(m, "Steel", SAFETY, (-1, 1.08, 0), (1, 1.08, 0), 0.025, segs=6)
    tb(m, "Steel", SAFETY, (-1, 0.55, 0), (1, 0.55, 0), 0.018, segs=6)
    sh.add((0, 0.55, 0), (2.0, 1.1, 0.06))
    return m, sh, []


# ── the hab can (2.5 m, along Z, on saddles) ─────────────────────────────────
HR, HT, HAX = 1.25, 0.08, 1.65    # outer radius, hull, the axis's height (saddles 0.4 m)
HDECK = 0.80                      # the deck's top


def hab_saddles(m, sh, zs):
    for z in zs:
        bx(m, "Steel", DARK, -1.1, 1.1, 0, 0.12, z - 0.12, z + 0.12, sh=sh)
        for s in (-1, 1):
            tb(m, "Steel", GREY, (s * 0.95, 0.12, z), (s * 0.62, HAX - 1.12, z), 0.05, segs=8)
        for a in (-0.6, -0.3, 0.0, 0.3, 0.6):
            c, sn = math.cos(a), math.sin(a)
            Mr = np.array([[c, -sn, 0], [sn, c, 0], [0, 0, 1]])
            rbox(m, "Steel", GREY, (-(HR + 0.03) * sn, HAX - (HR + 0.03) * c, z), (0.42, 0.06, 0.2), Mr)
        bx(m, "Steel", SAFETY, -1.1, -0.9, 0.12, 0.124, z - 0.12, z + 0.12)


def hab_ring_colliders(sh, z0, z1, skip=lambda a: False):
    n = 16
    for k in range(n):
        a = (k + 0.5) * TAU / n
        if skip(a):
            continue
        c, s = math.cos(a), math.sin(a)
        r = HR - HT / 2
        M = np.array([[-s, c, 0], [c, s, 0], [0, 0, 1]])
        sh.add((r * c, HAX + r * s, (z0 + z1) / 2), (2 * HR * math.sin(math.pi / n) * 1.08, HT + 0.04, z1 - z0), quat_from_basis(M))


def hab_deck(m, sh, z0, z1):
    half = math.sqrt((HR - HT) ** 2 - (HDECK - HAX) ** 2) - 0.02
    bx(m, "Steel", (0.50, 0.51, 0.52), -half, half, HDECK - 0.04, HDECK, z0, z1)
    sh.add((0, HDECK - 0.06, (z0 + z1) / 2), (2 * half + 0.1, 0.12, z1 - z0))
    return half


def hull(m, z0, z1, skip=None, bands=None):
    """The can's barrel from z0 to z1: outer skin, inner face (both revolved
    about +Y, then laid along Z)."""
    sub = CModel(seed=61)
    sub.ground = False
    prof = [(HR, y) for y in (bands or [z0, z1])]
    sub.color = PAINT
    lathe(sub, "Clad", prof, segs=32, smooth=True, uv_m=0.5, skip=skip)
    sub.color = LIGHT
    lathe(sub, "Clad", [(HR - HT, y) for (_, y) in prof], segs=32, smooth=True, uv_m=0.5, inward=True, skip=skip)
    # rot_x(+90°): +Y → +Z; a lathe point (r cos a, y, r sin a) → (r cos a, -r sin a, y)
    m.merge(sub, M=rot_x(math.pi / 2), t=(0, HAX, 0))


def flange(m, z, out=1):
    sub = CModel(seed=62); sub.ground = False; sub.color = GREY
    disk(sub, "Steel", HR + 0.05, 0.0, segs=32, up=out > 0, r_in=HR - HT - 0.005)
    lathe(sub, "Steel", [(HR + 0.05, -0.05 * out), (HR + 0.05, 0.0)], segs=32)
    m.merge(sub, M=rot_x(math.pi / 2), t=(0, HAX, z))
    for k in range(16):
        a = k * TAU / 16
        tb(m, "Steel", DARK, ((HR + 0.025) * math.cos(a), HAX + (HR + 0.025) * math.sin(a), z - 0.06 * out),
           ((HR + 0.025) * math.cos(a), HAX + (HR + 0.025) * math.sin(a), z + 0.01 * out), 0.012, segs=5)


def p_habSeg(mat, window=False):
    m, sh = CModel(seed=63), Shell()
    m.ground = False
    if window:
        # two windows, either side at eye height: cells left open in the hull
        segs = 32
        def skip(i, k):
            if k != 1:
                return False
            return i in (0, 31, 15, 16)
        hull(m, -1, 1, skip=skip, bands=[-1, -0.38, 0.38, 1])
        for sx in (-1, 1):
            # a flat frame round the hole (the cells span ±0.196 rad) and the pane
            hy = HR * math.sin(TAU / 32)
            x = sx * (HR * math.cos(TAU / 32) - 0.01)
            for (yy0, yy1, zz0, zz1) in ((-hy - 0.06, -hy, -0.44, 0.44), (hy, hy + 0.06, -0.44, 0.44),
                                         (-hy, hy, -0.44, -0.38), (-hy, hy, 0.38, 0.44)):
                bx(m, "Steel", GREY, x - 0.06, x + 0.06, HAX + yy0, HAX + yy1, zz0, zz1)
            bx(m, "Pane", (1, 1, 1), x - 0.012, x + 0.012, HAX - hy, HAX + hy, -0.38, 0.38)
            sh.add((x, HAX, 0), (0.1, 2 * hy, 0.76))
    else:
        hull(m, -1, 1)
    flange(m, -1, -1)
    flange(m, 1, 1)
    hab_saddles(m, sh, (-0.55, 0.55))
    half = hab_deck(m, sh, -1, 1)
    hab_ring_colliders(sh, -1, 1, skip=(lambda a: abs(math.cos(a)) > 0.97) if window else (lambda a: False))
    # a cable tray and a strip lamp along the crown, handholds on the walls
    bx(m, "Steel", GREY, -0.12, 0.12, HAX + HR - HT - 0.10, HAX + HR - HT - 0.04, -0.95, 0.95)
    bx(m, "Lamp", LAMP_WARM, -0.05, 0.05, HAX + HR - HT - 0.105, HAX + HR - HT - 0.10, -0.8, 0.8)
    for sx in (-1, 1):
        bx(m, "Steel", DARK, sx * (half + 0.02) - 0.03, sx * (half + 0.02) + 0.03, HDECK, HDECK + 0.08, -1, 1)
    return m, sh, [("Light", "empty", (0, HAX + HR - HT - 0.3, 0))]


def p_habWindow(mat):
    return p_habSeg(mat, window=True)


def p_habCap(mat):
    m, sh = CModel(seed=64), Shell()
    m.ground = False
    sub = CModel(seed=65); sub.ground = False
    prof = [(HR, -0.35)]
    for i in range(1, 7):
        a = i / 6 * (math.pi / 2)
        prof.append((HR * math.cos(a) * 0.999 + 0.0001, -0.35 + 0.62 * math.sin(a) * (1 if i < 6 else 1)))
    prof[-1] = (0.28, 0.27)
    sub.color = PAINT
    lathe(sub, "Clad", prof, segs=32, smooth=True, uv_m=0.5)
    sub.color = LIGHT
    lathe(sub, "Clad", [(max(r - HT, 0.2), y - HT * 0.5) for (r, y) in prof], segs=32, smooth=True, uv_m=0.5, inward=True)
    sub.color = GREY
    disk(sub, "Steel", 0.30, 0.27, segs=24, up=True)
    m.merge(sub, M=rot_x(math.pi / 2), t=(0, HAX, 0))
    flange(m, -0.35, -1)
    hab_saddles(m, sh, (-0.2,))
    sh.add((0, HAX, -0.05), (2.4, 2.4, 0.1))
    return m, sh, []


def p_habBulkhead(mat):
    m, sh = CModel(seed=66), Shell()
    m.ground = False
    R = HR - 0.02
    dx0, dx1, dy0, dy1 = -0.84, 0.0, HDECK, HDECK + 1.8
    # the plate in 0.05 m strips (its stepped edge under the flange rings)
    t = 0.05
    ny = int(2 * R / 0.05)
    for k in range(ny):
        y0 = HAX - R + k * 0.05
        y1 = y0 + 0.05
        yy = max(abs(y0 - HAX), abs(y1 - HAX))
        if yy >= R:
            continue
        w = math.sqrt(R * R - yy * yy)
        if y1 > dy0 + 1e-6 and y0 < dy1 - 1e-6:
            for (a, b) in ((-w, dx0), (dx1, w)):
                if b - a > 0.01:
                    bx(m, "Steel", (0.70, 0.70, 0.67), a, b, y0, y1, -t / 2, t / 2)
        else:
            bx(m, "Steel", (0.70, 0.70, 0.67), -w, w, y0, y1, -t / 2, t / 2)
    for out in (-1, 1):
        sub = CModel(seed=67); sub.ground = False; sub.color = GREY
        disk(sub, "Steel", HR + 0.05, 0.0, segs=32, up=out > 0, r_in=HR - 0.16)
        m.merge(sub, M=rot_x(math.pi / 2), t=(0, HAX, out * (t / 2 + 0.005)))
    lathe_sub = CModel(seed=68); lathe_sub.ground = False; lathe_sub.color = GREY
    lathe(lathe_sub, "Steel", [(HR + 0.05, -t / 2 - 0.005), (HR + 0.05, t / 2 + 0.005)], segs=32)
    m.merge(lathe_sub, M=rot_x(math.pi / 2), t=(0, HAX, 0))
    # the door frame, hazard-striped
    for s in (-1, 1):
        z0, z1 = s * (t / 2), s * (t / 2 + 0.05)
        for (a, b, c, d) in ((dx0 - 0.08, dx0, dy0, dy1 + 0.08), (dx1, dx1 + 0.08, dy0, dy1 + 0.08), (dx0 - 0.08, dx1 + 0.08, dy1, dy1 + 0.08)):
            bx(m, "Steel", (0.55, 0.50, 0.32), a, b, c, d, min(z0, z1) - s * 0.003, max(z0, z1))
    sh.add(((-R + dx0) / 2, HAX, 0), (R + dx0, 2 * R, 0.08))
    sh.add(((R + dx1) / 2, HAX, 0), (R - dx1, 2 * R, 0.08))
    sh.add(((dx0 + dx1) / 2, (dy1 + HAX + R) / 2, 0), (dx1 - dx0, HAX + R - dy1, 0.08))
    sh.add(((dx0 + dx1) / 2, (HAX - R + dy0) / 2, 0), (dx1 - dx0, dy0 - (HAX - R), 0.08))
    hab_saddles(m, sh, (0.0,))
    lm, lsh = door_leaf(0.88, 1.8, heavy=True, t=0.05)
    return m, sh, [("Door", "door", (lm, lsh, (-0.42, HDECK, -0.065)))]


def p_shieldBlock(mat):
    m, sh = CModel(seed=71), Shell()
    surf, col = look(mat)
    bx(m, "Concrete", col, -0.5, 0.5, 0, 1.0, -0.25, 0.25, sh=sh)
    for x in (-0.25, 0.25):
        tb(m, "Steel", DARK, (x, 1.0, -0.04), (x, 1.06, -0.04), 0.015, segs=6)
        tb(m, "Steel", DARK, (x, 1.06, -0.04), (x, 1.06, 0.04), 0.015, segs=6)
        tb(m, "Steel", DARK, (x, 1.0, 0.04), (x, 1.06, 0.04), 0.015, segs=6)
    bx(m, "Steel", SAFETY, -0.2, 0.2, 0.72, 0.84, 0.25, 0.254)
    return m, sh, []


def p_leadWall(mat):
    m, sh = CModel(seed=72), Shell()
    wall_body(m, sh, "steel", -1, 1, 0, WH)
    # the lead is behind the inner skin; the outside says so
    bx(m, "Steel", SAFETY, -0.25, 0.25, 1.45, 1.75, WT / 2 - 0.002, WT / 2 + 0.004)
    bx(m, "Steel", DARK, -0.2, 0.2, 1.5, 1.7, WT / 2 + 0.003, WT / 2 + 0.006)
    return m, sh, []


# mounts: modelled lying on a floor, their face +Y out
def p_lightFitting(mat):
    m, sh = CModel(seed=81), Shell()
    m.ground = False
    bx(m, "Steel", DARK, -0.3, 0.3, 0, 0.06, -0.1, 0.1)
    bx(m, "Lamp", LAMP_WARM, -0.27, 0.27, 0.06, 0.075, -0.07, 0.07)
    for s in (-1, 1):
        bx(m, "Steel", GREY, s * 0.3 - 0.01, s * 0.3 + 0.01, 0, 0.09, -0.12, 0.12)
    tb(m, "Steel", GREY, (-0.29, 0.085, 0), (0.29, 0.085, 0), 0.006, segs=5)
    return m, sh, [("Light", "empty", (0, 0.25, 0))]


def p_switchPlate(mat):
    m, sh = CModel(seed=82), Shell()
    m.ground = False
    bx(m, "Steel", LIGHT, -0.06, 0.06, 0, 0.012, -0.09, 0.09)
    bx(m, "Steel", DARK, -0.015, 0.015, 0.012, 0.03, -0.03, 0.03)
    bx(m, "Lamp", (0.4, 1.0, 0.4), -0.01, 0.01, 0.012, 0.016, 0.055, 0.07)
    return m, sh, []


def p_wallScreen(mat):
    m, sh = CModel(seed=83), Shell()
    m.ground = False
    bx(m, "Steel", DARK, -0.45, 0.45, 0, 0.045, -0.28, 0.28)
    bx(m, "Steel", GREY, -0.08, 0.08, -0.0, 0.01, -0.28, -0.25)
    sm = CModel(seed=84); sm.ground = False
    # the face: one quad facing +Y, UV 0..1 over it (kit_live paints it)
    sm.color = (1, 1, 1)
    w, h = 0.8, 0.48
    sm.add("Screen", [(-w / 2, 0, -h / 2), (w / 2, 0, -h / 2), (w / 2, 0, h / 2), (-w / 2, 0, h / 2)],
           [(0, 1, 0)] * 4, [(0, 0), (1, 0), (1, 1), (0, 1)], [(0, 2, 1), (0, 3, 2)])
    return m, sh, [("Screen", "mesh", (sm, (0, 0.047, 0)))]


def p_wallTray(mat):
    m, sh = CModel(seed=85), Shell()
    m.ground = False
    bx(m, "Steel", GREY, -1, 1, 0, 0.004, -0.1, 0.1)
    for s in (-1, 1):
        bx(m, "Steel", GREY, -1, 1, 0, 0.1, s * 0.098 - 0.002, s * 0.098 + 0.002)
    for k, (z, r) in enumerate(((-0.05, 0.016), (0.0, 0.02), (0.05, 0.014), (-0.02, 0.012))):
        tb(m, "Rubber", RUBBER, (-1, 0.004 + r + (0.03 if k == 3 else 0), z), (1, 0.004 + r + (0.03 if k == 3 else 0), z), r, segs=6)
    for x in (-0.7, 0.0, 0.7):
        bx(m, "Steel", DARK, x - 0.02, x + 0.02, 0, 0.1, -0.11, 0.11)
    return m, sh, []


def p_floorDuct(mat):
    m, sh = CModel(seed=86), Shell()
    m.ground = False
    bx(m, "Steel", DARK, -1, 1, 0, 0.1, -0.2, 0.2)
    bx(m, "Steel", (0.50, 0.51, 0.52), -1, 1, 0.1, 0.12, -0.2, 0.2)
    for x in (-0.5, 0.5):
        bx(m, "Steel", SAFETY, x - 0.01, x + 0.01, 0.12, 0.123, -0.2, 0.2)
    sh.add((0, 0.06, 0), (2, 0.12, 0.4))
    return m, sh, []


# ── life support (S3: scripts/room_air.lua): floor-standing machines ─────────

def p_scrubber(mat):
    """An amine-bed CO2 scrubber: a steel cabinet, an intake grille, two beds
    behind an access panel, a fan housing on top, its status lamp."""
    m, sh = CModel(seed=91), Shell()
    bx(m, "Steel", (0.58, 0.60, 0.60), -0.35, 0.35, 0.0, 1.30, -0.25, 0.25, sh=sh)
    bx(m, "Steel", DARK, -0.33, 0.33, 0.0, 0.08, -0.23, 0.23)
    # the intake grille (front, low) and the beds' panel (front, high)
    for k in range(9):
        y = 0.16 + k * 0.045
        bx(m, "Steel", DARK, -0.27, 0.27, y, y + 0.022, 0.25, 0.262)
    bx(m, "Steel", (0.50, 0.52, 0.52), -0.28, 0.28, 0.66, 1.18, 0.25, 0.258)
    for x in (-0.26, 0.26):
        for y in (0.68, 1.16):
            tb(m, "Steel", LIGHT, (x, y, 0.258), (x, y, 0.268), 0.01, segs=6)
    bx(m, "Steel", SAFETY, -0.28, 0.28, 1.19, 1.215, 0.25, 0.258)
    # the fan on top, its guard
    tb(m, "Steel", GREY, (0, 1.30, 0), (0, 1.38, 0), 0.20, segs=16)
    for k in range(6):
        a = k * TAU / 6
        tb(m, "Steel", DARK, (0, 1.385, 0), (0.18 * math.cos(a), 1.385, 0.18 * math.sin(a)), 0.008, segs=5)
    sh.add((0, 1.34, 0), (0.42, 0.08, 0.42))
    # the lamp and a duct stub out of its back
    bx(m, "Lamp", (0.35, 1.0, 0.45), 0.18, 0.26, 1.24, 1.27, 0.25, 0.256)
    tb(m, "Steel", GREY, (0, 0.95, -0.25), (0, 0.95, -0.34), 0.07, segs=12)
    return m, sh, []


def p_o2gen(mat):
    """An electrolyser: a white cabinet with a stack window, its water tank on
    the side, a gas manifold and the O2 line, hazard placards."""
    m, sh = CModel(seed=92), Shell()
    bx(m, "Clad", STEELWALL, -0.45, 0.30, 0.0, 1.55, -0.30, 0.30, sh=sh)
    bx(m, "Steel", DARK, -0.43, 0.28, 0.0, 0.07, -0.28, 0.28)
    # the cell stack behind its window
    bx(m, "Steel", DARK, -0.36, 0.20, 0.55, 1.25, 0.30, 0.31)
    for k in range(10):
        x = -0.32 + k * 0.05
        bx(m, "Steel", (0.62, 0.48, 0.30) if k % 2 == 0 else GREY, x, x + 0.03, 0.62, 1.18, 0.30, 0.314)
    bx(m, "Pane", (1, 1, 1), -0.36, 0.20, 0.55, 1.25, 0.318, 0.326)
    # the water tank on its side
    tb(m, "Steel", (0.30, 0.42, 0.55), (0.37, 0.05, 0.0), (0.37, 1.25, 0.0), 0.075, segs=14)
    sh.add((0.37, 0.65, 0), (0.15, 1.2, 0.15))
    # the manifold and the O2 line up and over
    tb(m, "Steel", LIGHT, (-0.30, 1.55, 0.05), (-0.30, 1.62, 0.05), 0.03, segs=8)
    tb(m, "Steel", LIGHT, (-0.30, 1.62, 0.05), (0.20, 1.62, 0.05), 0.02, segs=8)
    tb(m, "Steel", (0.20, 0.45, 0.85), (0.20, 1.62, 0.05), (0.20, 1.62, -0.30), 0.02, segs=8)
    bx(m, "Steel", SAFETY, -0.40, -0.25, 1.32, 1.45, 0.30, 0.306)
    bx(m, "Lamp", (0.35, 1.0, 0.45), 0.05, 0.13, 1.36, 1.40, 0.30, 0.306)
    return m, sh, []


def p_airTank(mat):
    """Three 200 bar air cylinders strapped in a rack, a manifold, a regulator
    with its gauge."""
    m, sh = CModel(seed=93), Shell()
    bx(m, "Steel", DARK, -0.6, 0.6, 0.0, 0.06, -0.25, 0.25, sh=sh)
    for x in (-0.58, 0.58):
        bx(m, "Steel", GREY, x - 0.02, x + 0.02, 0.0, 1.75, -0.24, -0.20)
    bx(m, "Steel", GREY, -0.6, 0.6, 1.70, 1.75, -0.24, -0.20)
    for k, x in enumerate((-0.38, 0.0, 0.38)):
        tb(m, "Steel", (0.18, 0.34, 0.22), (x, 0.06, 0.0), (x, 1.42, 0.0), 0.17, segs=18)
        m.color = (0.18, 0.34, 0.22)
        tube(m, "Steel", (x, 1.42, 0.0), (x, 1.52, 0.0), 0.17, segs=18, uv_m=UVM["Steel"], r1=0.06)
        tb(m, "Steel", LIGHT, (x, 1.52, 0.0), (x, 1.60, 0.0), 0.035, segs=8)
        for y in (0.4, 1.1):
            tb(m, "Steel", DARK, (x - 0.18, y, 0.0), (x + 0.18, y, 0.0), 0.01, segs=5)
        bx(m, "Steel", PAINT, x - 0.06, x + 0.06, 1.0, 1.2, 0.165, 0.175)
        sh.add((x, 0.8, 0), (0.34, 1.5, 0.34))
    tb(m, "Steel", LIGHT, (-0.38, 1.62, 0.0), (0.38, 1.62, 0.0), 0.02, segs=8)
    bx(m, "Steel", DARK, 0.42, 0.56, 1.52, 1.68, -0.05, 0.08)
    tb(m, "Steel", PAINT, (0.49, 1.60, 0.08), (0.49, 1.60, 0.10), 0.05, segs=14)
    return m, sh, []


# ── mirrored variants (a piece symmetric in neither of its planes) ─────────

def reflect_model(m):
    out = CModel(seed=990)
    out.ground = m.ground
    out.merge(m, M=np.diag([-1.0, 1.0, 1.0]))
    return out


def reflect_shell(sh):
    out = Shell()
    for (c, s, q) in sh.boxes:
        out.add((-c[0], c[1], c[2]), s, (q[0], -q[1], -q[2], q[3]))
    return out


def mirrored(fn):
    """fn reflected in its own X: the model, its colliders, its children."""
    def g(mat):
        m, sh, children = fn(mat)
        kids = []
        for (name, kind, data) in children:
            if kind == "empty":
                kids.append((name, kind, (-data[0], data[1], data[2])))
            elif kind == "mesh":
                cm, at = data
                kids.append((name, kind, (reflect_model(cm), (-at[0], at[1], at[2]))))
            elif kind == "door":
                dm, dsh, at = data
                kids.append((name, kind, (reflect_model(dm), reflect_shell(dsh), (-at[0], at[1], at[2]))))
        return reflect_model(m), reflect_shell(sh), kids
    return g


PIECES = {
    "slab2": (p_slab2, ["concrete", "regocrete"]),
    "pier": (p_pier, ["concrete", "steel"]),
    "ramp": (p_ramp, ["concrete", "steel"]),
    "stairs": (p_stairs, ["steel", "concrete"]),
    "steps": (p_steps, ["steel", "concrete"]),
    "ladder": (p_ladder, ["steel"]),
    "grating": (p_grating, ["steel"]),
    "floor": (p_floor, ["steel", "concrete", "regocrete", "glass"]),
    "floor21": (p_floor21, ["steel", "concrete", "regocrete", "glass"]),
    "floor11": (p_floor11, ["steel", "concrete", "regocrete", "glass"]),
    "floorHatch": (p_floorHatch, ["steel", "concrete"]),
    "wall": (p_wall, ["steel", "concrete", "regocrete", "glass"]),
    "halfWall": (p_halfWall, ["steel", "concrete", "regocrete", "glass"]),
    "wall12": (p_wall12, ["steel", "concrete", "regocrete", "glass"]),
    "doorWall": (p_doorWall, ["steel", "concrete", "regocrete"]),
    "doorWallM": (mirrored(p_doorWall), ["steel", "concrete", "regocrete"]),
    "doubleDoor": (p_doubleDoor, ["steel", "concrete", "regocrete"]),
    "windowWall": (p_windowWall, ["steel", "concrete", "regocrete"]),
    "porthole": (p_porthole, ["steel", "concrete"]),
    "airlockWall": (p_airlockWall, ["steel", "concrete"]),
    "openFrame": (p_openFrame, ["steel", "concrete", "regocrete"]),
    "ventWall": (p_ventWall, ["steel"]),
    "cornerPost": (p_cornerPost, ["steel", "concrete"]),
    "roofPitch": (p_roofPitch, ["steel", "glass"]),
    "roofRidge": (p_roofRidge, ["steel"]),
    "gable": (p_gable, ["steel", "concrete", "regocrete", "glass"]),
    "pillar2": (p_pillar2, ["steel", "concrete"]),
    "pillar4": (p_pillar4, ["steel", "concrete"]),
    "beam2": (p_beam2, ["steel"]),
    "beam4": (p_beam4, ["steel"]),
    "truss2": (p_truss2, ["steel"]),
    "truss4": (p_truss4, ["steel"]),
    "truss6": (p_truss6, ["steel"]),
    "trussNode": (p_trussNode, ["steel"]),
    "catwalk": (p_catwalk, ["steel"]),
    "rail": (p_rail, ["steel"]),
    "habSeg": (p_habSeg, ["steel"]),
    "habWindow": (p_habWindow, ["steel"]),
    "habCap": (p_habCap, ["steel"]),
    "habBulkhead": (p_habBulkhead, ["steel"]),
    "shieldBlock": (p_shieldBlock, ["concrete", "regocrete"]),
    "leadWall": (p_leadWall, ["steel"]),
    "lightFitting": (p_lightFitting, ["steel"]),
    "switchPlate": (p_switchPlate, ["steel"]),
    "wallScreen": (p_wallScreen, ["steel"]),
    "wallTray": (p_wallTray, ["steel"]),
    "floorDuct": (p_floorDuct, ["steel"]),
    "scrubber": (p_scrubber, ["steel"]),
    "o2gen": (p_o2gen, ["steel"]),
    "airTank": (p_airTank, ["steel"]),
}


# ── writing ──────────────────────────────────────────────────────────────────

def f3(v):
    return f"({v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f})"


def mats_of(model):
    return ",\n".join(f'            "{n}": {MATS[n]()}' for n in sorted(model.parts.keys()))


def node_empty(name, at, parent, tags=None):
    tag = f"        tags: [{', '.join(chr(34) + t + chr(34) for t in tags)}],\n" if tags else ""
    par = f"        parent: Some({parent}),\n" if parent is not None else ""
    return f'''    (
        name: "{name}",
{tag}        transform: (
            translation: {f3(at)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
{par}    ),
'''


def node_mesh(name, glb, model, at, parent, cast=True):
    shadow = "" if cast else "        cast_shadow: false,\n"
    return f'''    (
        name: "{name}",
        transform: (
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
        parent: Some({parent}),
{shadow}    ),
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


def centre(model):
    lo, hi = model.bounds()
    return (lo + hi) / 2, lo, hi


def write_piece(piece, mat, fn, dry, fixture):
    m, sh, children = fn(mat)
    name = "Kit" + piece[0].upper() + piece[1:] + "_" + mat
    glb = f"{piece}_{mat}.glb"
    c, lo, hi = centre(m)
    small = (hi - lo).max() < 0.7
    nodes = [node_empty(name, (0, 0, 0), None, tags=["base_part", "kit"]),
             node_mesh("Mesh", f"{FOLDER}/{glb}", m, c, 0, cast=not small)]
    for i, (bc, bs, q) in enumerate(sh.boxes):
        nodes.append(node_box(f"Wall {i + 1}", bc, bs, q, 0))
    all_lo, all_hi = lo.copy(), hi.copy()
    extra = []
    ncol = len(sh.boxes)
    for (cname, kind, data) in children:
        if kind == "empty":
            nodes.append(node_empty(cname, data, 0))
        elif kind == "mesh":
            cm, at = data
            cc, clo, chi = centre(cm)
            nodes.append(node_mesh(cname, f"{FOLDER}/{piece}_{mat}_{cname.lower()}.glb", cm, np.asarray(at) + cc, 0, cast=False))
            extra.append((f"{piece}_{mat}_{cname.lower()}.glb", cm))
        elif kind == "door":
            dm, dsh, at = data
            at = np.asarray(at, float)
            dc, dlo, dhi = centre(dm)
            # the Door node stands at the leaf's box centre (the engine centres
            # its model there); its colliders are its own children
            di = len(nodes)
            nodes.append(node_mesh(cname, f"{FOLDER}/{piece}_{mat}_{cname.lower()}.glb", dm, at + dc, 0))
            for k, (bc, bs, q) in enumerate(dsh.boxes):
                nodes.append(node_box(f"{cname} Wall {k + 1}", np.asarray(bc) - dc, bs, q, di))
            ncol += len(dsh.boxes)
            extra.append((f"{piece}_{mat}_{cname.lower()}.glb", dm))
            all_lo, all_hi = np.minimum(all_lo, at + dlo), np.maximum(all_hi, at + dhi)
    tris = m.tris() + sum(e[1].tris() for e in extra)
    fixture.append(f'  {name} = {{ lo = {{ {lo[0]:.3f}, {lo[1]:.3f}, {lo[2]:.3f} }}, hi = {{ {hi[0]:.3f}, {hi[1]:.3f}, {hi[2]:.3f} }}, '
                   f'colliders = {ncol}, tris = {tris}, children = {{ {", ".join(chr(34) + ch[0] + chr(34) for ch in children)} }} }},')
    print(f"{name:26s} lo {f3(lo)} hi {f3(hi)}  tris {tris:5d}  colliders {ncol}")
    if dry:
        return
    for (g, model) in [(glb, m)] + extra:
        zcheck(model, g, verbose=False)
        gen_base.write_glb(model.shifted(np.zeros(3)), os.path.join(MODELS, g))
    with open(os.path.join(PREFABS, f"{name}.prefab.ron"), "w") as f:
        f.write(f"// KIT PIECE — {piece} in {mat} (the modular structure kit; scripts/parts_kit.lua).\n"
                "// Root = the ground point; Mesh, its colliders (Wall N) and its live children.\n"
                "// Written by tools/gen_kit_parts.py — edit the generator, not this file.\n[\n")
        f.write("".join(nodes))
        f.write("]\n")


def main():
    dry = "--dry" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(MODELS, exist_ok=True)
    fixture = ["-- Written by tools/gen_kit_parts.py: each kit prefab's mesh bounds (ground frame),", "-- its collider count and live children. tests/smoke_kit.lua reads it.", "return {"]
    for piece, (fn, mats) in PIECES.items():
        if only and piece not in only:
            continue
        for mat in mats:
            write_piece(piece, mat, fn, dry, fixture)
    fixture.append("}")
    if not dry and not only:
        with open(os.path.join(ROOT, "tests", "fixtures", "kit_shapes.lua"), "w") as f:
            f.write("\n".join(fixture) + "\n")


if __name__ == "__main__":
    main()
