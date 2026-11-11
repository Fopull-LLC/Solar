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
from base_models import (CModel, CONC, CONC_DARK, DARK, GREY, LIGHT, PAINT, RUBBER, SAFETY, Shell, SLATE, WARM,  # noqa: E402
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


import gen_kit_props  # noqa: E402  (S4: decals, signs, props; its own materials)
MATS.update(gen_kit_props.MATERIALS)


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
    # (z-fight, playtest 11-10: a lining's face lay in the panel's cut edge and
    # the channels' ends, the jamb Ty saw flicker; each now stands RI proud of
    # the cut into the opening, and the jambs meet the head and the sill
    # end to end instead of overlapping them)
    if trims:
        RI = 0.003
        for (a, b, c, d) in holes:
            r = 0.035
            sill = c > y0 + 1e-3
            cj = c + RI if sill else c + 0.002   # (no sill: 2 mm off the floor line, clear of the channel's underside)
            for (p0, p1, q0, q1) in ((a - r, a + RI, cj, d - RI), (b - RI, b + r, cj, d - RI), (a - r, b + r, d - RI, d + r)) + (((a - r, b + r, c - r, c + RI),) if sill else ()):
                bx(m, "Steel", GREY, p0, p1, q0, q1, -hz - 0.012, hz + 0.012)


def door_leaf(w, h, heavy=False, window=True, t=0.05, ww=None, wx=0.0):
    """A sliding leaf about its own bottom centre: (model, its colliders).
    ww, wx: the vision panel's width and its centre across the leaf (a narrow leaf
    of a pair keeps it clear of the dogs and the chevrons on its leading edge)."""
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
        if ww is None:
            ww = 0.22 if not heavy else 0.30
        bx(m, "Steel", DARK, wx - ww / 2 - 0.03, wx + ww / 2 + 0.03, wy0 - 0.03, wy1 + 0.03, -t / 2 - 0.006, t / 2 + 0.006)
        bx(m, "Pane", (1, 1, 1), wx - ww / 2, wx + ww / 2, wy0, wy1, -t / 2 - 0.008, t / 2 + 0.008)
    if heavy:
        # dogs round the edge and hazard chevrons along the leading edge
        for y in (0.4, 1.0, 1.6):
            for s in (-1, 1):
                bx(m, "Steel", DARK, -w / 2 + 0.02, -w / 2 + 0.10, y, y + 0.08, s * (t / 2 + 0.012) - 0.01, s * (t / 2 + 0.012) + 0.01)
        for k in range(8):
            # (z-fight, playtest 11-10: the top chevron ended on the leaf's top face; they now stop 5 mm under it)
            ch = (h - 0.125) / 8
            y = 0.12 + k * ch
            # (3 mm proud of the kick plate they cross)
            bx(m, "Steel", SAFETY if k % 2 == 0 else DARK, -w / 2 - 0.004, -w / 2 + 0.05, y, y + ch, -t / 2 - 0.007, t / 2 + 0.007)
    return m, sh


# ── the pieces: each returns (model, colliders, children) ───────────────────
# children: list of (name, kind, data) — ("Door", "door", (model, shell, at)),
# ("Light", "empty", at), ("Screen", "mesh", (model, at))

def p_slab2(mat):
    m, sh = CModel(seed=11), Shell()
    surf, col = look(mat)
    bx(m, "Concrete", col, -1, 1, -0.10, 0.20, -1, 1, sh=sh)
    # (z-fight: the edge strips stop 2 mm inside the slab's edge, so their ends and outer faces never share a
    # plane with the end of a wall or post standing on that edge, or with the next slab's strips)
    for s in (-1, 1):
        bx(m, "Steel", GREY, -0.998, 0.998, 0.20, 0.206, s * 0.964 - 0.034, s * 0.964 + 0.034)
        bx(m, "Steel", GREY, s * 0.964 - 0.034, s * 0.964 + 0.034, 0.20, 0.206, -0.93, 0.93)
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
            sh.add(tuple(a + d / 2 + (0, 0.6, 0)), (0.06, 1.1, max(0.2, np.linalg.norm(d) - 0.8)), quat_from_basis(Mr))
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
        # (Ty 11-10, "improper connections for stairs": the rail's box stands square to the slope, so
        # a full-length one reached ~0.4 m past the foot and the top and fenced the way on; 0.8 m shorter)
        sh.add(tuple(a + d / 2 + (0, 0.55, 0)), (0.06, 1.0, max(0.2, L - 0.8)), quat_from_basis(Mr))


def p_steps(mat):
    return p_stairs(mat, rise=0.8, run=1.0, width=1.2)


def p_habSteps(mat):
    # (builderperf: the ground to a hab's lowered deck, at its Door Bulkhead)
    return p_stairs(mat, rise=HDECK, run=0.8, width=1.2)


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
    # (z-fight, playtest 11-10: the transom's ends lay in the panes' ends; the panes' edges now
    # sit inside the reveals, 3 mm proud of the cut, and the transom stops on the reveals' faces)
    g = 0.003
    bx(m, "Pane", (1, 1, 1), -0.6, 0.6, 0.9, 1.9, -0.035, -0.023)
    bx(m, "Pane", (1, 1, 1), -0.6, 0.6, 0.9, 1.9, 0.023, 0.035)
    bx(m, "Steel", DARK, -0.6 + g, 0.6 - g, 1.385, 1.415, -0.04, 0.04)
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
        # (playtest 11-10: the disk faced the wall, so from outside it was see-through and its bolts' feet fought it)
        disk(sub, "Steel", 0.40, 0.0, segs=28, up=False, r_in=0.25)
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
    # (Ty 11-10, "barely squeezing through doors": a 1.95 m opening left the 1.9 m capsule 5 cm; 2.08 m
    # leaves 18 cm, the frame's head still under the wall's top channel)
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.92, 0.0, 0.0, 2.08)], trims=False)
    # a heavy pressure frame proud of both faces, hazard-striped, with its seal
    for s in (-1, 1):
        z0, z1 = s * WT / 2, s * (WT / 2 + 0.06)
        # (z-fight, playtest 11-10: the jambs overlapped the head and lay in the wall's cut edges
        # and its end stud; now 3 mm into the opening, 3 mm in from the wall's end, jambs under the head)
        for (a, b, c, d) in ((-0.997, -0.917, 0.002, 2.077), (-0.003, 0.08, 0.002, 2.077), (-0.997, 0.08, 2.077, 2.197)):
            bx(m, "Steel", (0.55, 0.50, 0.32), a, b, c, d, min(z0, z1) - s * 0.004, max(z0, z1))
        for k in range(9):
            y = k * 0.22
            if k % 2 == 0:
                bx(m, "Steel", DARK, 0.0, 0.08, y, min(2.074, y + 0.22), min(z0, z1) - 0.003 if s < 0 else max(z0, z1) - 0.002,
                   min(z0, z1) + 0.002 if s < 0 else max(z0, z1) + 0.003)
        # the indicator lamp and the cycle panel beside the door
        bx(m, "Steel", DARK, 0.18, 0.38, 1.25, 1.55, s * (WT / 2) - 0.002, s * (WT / 2 + 0.04))
        bx(m, "Lamp", (0.25, 1.0, 0.35), 0.24, 0.32, 1.45, 1.5, s * (WT / 2 + 0.04) - 0.004, s * (WT / 2 + 0.04) + 0.004)
    lm, lsh = door_leaf(0.96, 2.08, heavy=True, t=0.07)
    return m, sh, [("Door", "door", (lm, lsh, (-0.46, 0.0, 0.0)))]


def p_openFrame(mat):
    m, sh = CModel(seed=27), Shell()
    # (z-fight, Ty 11-10: a 1.8 m hole put its cut edges and jambs in the inner faces of the walls
    # either side when it closed a room's corner; 1.72 m keeps the frame 3.6 cm proud of them)
    wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.86, 0.86, 0.0, 2.05)])
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
        # (z-fight, playtest 11-10: the two flashings' ends and the roll's caps shared the end planes)
        rbox(m, "Steel", (0.40, 0.42, 0.44), (0, 0.08, -s * 0.09), (2.0 - (0.004 if s > 0 else 0), 0.02, 0.2), M)
    tb(m, "Steel", GREY, (-0.995, 0.13, 0), (0.995, 0.13, 0), 0.025, segs=8)
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
            # (the chords end 3 mm inside the end plates: a free end shows the plate, not two faces)
            tb(m, "Steel", GREY, (sx * w, 0.003, sz * w), (sx * w, L - 0.003, sz * w), 0.03, segs=8)
    bays = max(1, int(round(L / 0.5)))
    for k in range(bays + 1):
        y = L * k / bays
        y = min(max(y, 0.018), L - 0.018)
        for (a, b) in (((-w, -w), (w, -w)), ((w, -w), (w, w)), ((w, w), (-w, w)), ((-w, w), (-w, -w))):
            tb(m, "Steel", GREY, (a[0], y, a[1]), (b[0], y, b[1]), 0.015, segs=6)
    for k in range(bays):
        y0, y1 = L * k / bays, L * (k + 1) / bays
        f = 1 if k % 2 == 0 else -1
        for (a, b) in (((-w, -w), (w, -w)), ((w, -w), (w, w)), ((w, w), (-w, w)), ((-w, w), (-w, -w))):
            p0 = (a[0], y0 if f > 0 else y1, a[1]); p1 = (b[0], y1 if f > 0 else y0, b[1])
            # (alternate bays' diagonals 1.5 mm thinner: two meeting at a node share no facet plane)
            tb(m, "Steel", GREY, p0, p1, 0.012 if k % 2 == 0 else 0.0105, segs=5)
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
# (builderperf, Ty 11-10 decision: the walker's capsule is 1.9 m and the hab door and
# the junction's passage were 1.8 m. The deck is 15 cm lower, so both openings are
# 2.0 m clear; the can, its flanges, saddles and snap points are as they were. The
# deck is narrower for it: 1.14 m between the kick strips, was 1.57.)
HDECK = 0.65                      # the deck's top
KICKZ = 0.996                     # the deck's kick strips stop short of the flanges' faces


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


def hab_ring_colliders(sh, z0, z1, skip=lambda a: False, split=lambda a: False):
    n = 16
    for k in range(n):
        a = (k + 0.5) * TAU / n
        if split(a):
            # (a junction's port side: the box either side of the hull's hole)
            for (za, zb) in ((z0, -PHZ), (PHZ, z1)):
                hab_ring_box(sh, a, za, zb, n)
            continue
        if skip(a):
            continue
        hab_ring_box(sh, a, z0, z1, n)


def hab_ring_box(sh, a, z0, z1, n=16):
    c, s = math.cos(a), math.sin(a)
    r = HR - HT / 2
    M = np.array([[-s, c, 0], [c, s, 0], [0, 0, 1]])
    sh.add((r * c, HAX + r * s, (z0 + z1) / 2), (2 * HR * math.sin(math.pi / n) * 1.08, HT + 0.04, z1 - z0), quat_from_basis(M))


def hab_deck(m, sh, z0, z1):
    half = math.sqrt((HR - HT) ** 2 - (HDECK - HAX) ** 2) - 0.02
    # (z-fight, playtest 11-10: the deck's ends lay in the flanges' faces; 4 mm in, the collider still whole)
    bx(m, "Steel", (0.50, 0.51, 0.52), -half, half, HDECK - 0.04, HDECK, z0 + (1 - KICKZ), z1 - (1 - KICKZ))
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
    # (playtest 11-10: the skins' gap was open at each end, so the hairline
    # where two segments' linings meet showed the back faces behind it: a
    # dotted line of daylight at every joint. A ring 1 cm in closes the gap
    # out of sight behind the flanges.)
    disk(sub, "Clad", HR, z1 - 0.01, segs=32, up=True, uv_m=0.5, r_in=HR - HT)
    disk(sub, "Clad", HR, z0 + 0.01, segs=32, up=False, uv_m=0.5, r_in=HR - HT)
    # ...and the hairline itself is backed by a band of lining 4 mm behind it,
    # facing in and lit as the wall is, so the seam reads as one surface
    for (ya, yb) in ((z1 - 0.012, z1), (z0, z0 + 0.012)):
        lathe(sub, "Clad", [(HR - HT + 0.004, ya), (HR - HT + 0.004, yb)], segs=32, smooth=True, uv_m=0.5, inward=True)
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


def p_habSeg(mat, window=False, join=None):
    m, sh = CModel(seed=63), Shell()
    m.ground = False
    if join is not None:
        return hab_junction(m, sh, window, join)
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
        # (z-fight, playtest 11-10: the kick strips' ends lay in the flange's face at z ±1; 4 mm in)
        bx(m, "Steel", DARK, sx * (half + 0.02) - 0.03, sx * (half + 0.02) + 0.03, HDECK, HDECK + 0.08, -KICKZ, KICKZ)
    return m, sh, [("Light", "empty", (0, HAX + HR - HT - 0.3, 0))]


def p_habWindow(mat):
    return p_habSeg(mat, window=True)


# ── hab junctions (Ty 11-10: "it just recognizes what's near it and forms the
# connection"). A segment with another segment's END against its side is a
# junction: that side has a PORT (the hull cut, a short trunk out to a berthing
# plate the branch's open ring butts on, flush), and an end with nothing on it
# is closed by a flat end plate (an L corner, a dead-end T). The catalogue
# keeps the one Hab Segment: scripts/kit_snap.lua habShapes picks the code from
# the neighbours, parts_kit names the hidden variant habSegJ<code>, and
# structures.lua swaps the prefab. Codes: L / R a port on -X / +X, b / f the
# -Z / +Z end closed.
JOIN_CODES = ("L", "R", "LR", "Lb", "Lf", "Lbf", "Rb", "Rf", "Rbf", "LRb", "LRf", "LRbf")
PZ, PWT = 0.62, 0.10                 # the passage's half-width, the trunk's walls
PHZ = 0.67                           # the hull's hole half-width (inside the walls)
PY1 = HDECK + 2.0                    # the passage's ceiling (the deck is its floor): the bulkhead door's height
PFB, PCT = HAX - 1.05, HAX + 1.05    # the trunk's underside and top (they bury the hole's edges)
PX0 = 0.62                           # where the trunk starts, inside the hull
PLX0, PLX1 = 1.31, 1.35              # the berthing plate; the branch's ring butts on PLX1 (the box's side)
PLR = HR + 0.05                      # its radius: the flanges'
RFR = HR - HT - 0.05                 # the frame's room edge, 5 cm proud of the lining
FRAME = (0.55, 0.50, 0.32)           # the bulkhead's hazard frame
PLATE = (0.70, 0.70, 0.67)           # the bulkhead's plate
DECKC = (0.50, 0.51, 0.52)
# the hull's cells cut for a port (lathe cell i spans i × 11.25°, measured from
# +X toward -Y): ±56.25° about the side, so both skins' edges land inside the
# trunk's floor and ceiling
HOLE_I = {1: set(range(0, 5)) | set(range(27, 32)), -1: set(range(11, 21))}


def face_poly(m, mat, col, pts, n):
    """A flat convex polygon (3D points in order round it) facing n, planar UVs in metres."""
    m.color = col
    n = np.asarray(n, float)
    a = np.cross(n, [0.0, 1.0, 0.0] if abs(n[1]) < 0.9 else [1.0, 0.0, 0.0]); a /= np.linalg.norm(a)
    b = np.cross(n, a)
    uvm = UVM.get(mat, 1.0)
    P = [np.asarray(p, float) for p in pts]
    UV = [((p @ a) * uvm, -(p @ b) * uvm) for p in P]
    I = []
    for k in range(1, len(P) - 1):
        if np.cross(P[k] - P[0], P[k + 1] - P[0]) @ n >= 0:
            I.append((0, k, k + 1))
        else:
            I.append((0, k + 1, k))
    m.add(mat, [tuple(p) for p in P], [tuple(n)] * len(P), UV, I)


def prism_xy(m, mat, col, poly, z0, z1):
    """A prism along Z from a convex (x, y) polygon, every face facing out."""
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    face_poly(m, mat, col, [(x, y, z1) for x, y in poly], (0, 0, 1))
    face_poly(m, mat, col, [(x, y, z0) for x, y in poly], (0, 0, -1))
    n = len(poly)
    for k in range(n):
        (xa, ya), (xb, yb) = poly[k], poly[(k + 1) % n]
        l = math.hypot(xb - xa, yb - ya)
        if l < 1e-6:
            continue
        nx, ny = (yb - ya) / l, -(xb - xa) / l
        if nx * ((xa + xb) / 2 - cx) + ny * ((ya + yb) / 2 - cy) < 0:
            nx, ny = -nx, -ny
        face_poly(m, mat, col, [(xa, ya, z0), (xb, yb, z0), (xb, yb, z1), (xa, ya, z1)], (nx, ny, 0))


def quads_add(m, mat, col, quads):
    """Many flat quads ((p0, p1, p2, p3), n) in one call, each wound to face n."""
    m.color = col
    uvm = UVM.get(mat, 1.0)
    P, N, UV, I = [], [], [], []
    for pts, n in quads:
        n = np.asarray(n, float)
        a = np.cross(n, [0.0, 1.0, 0.0] if abs(n[1]) < 0.9 else [1.0, 0.0, 0.0]); a /= np.linalg.norm(a)
        b = np.cross(n, a)
        base = len(P)
        Q = [np.asarray(q, float) for q in pts]
        for q in Q:
            P.append(tuple(q)); N.append(tuple(n)); UV.append(((q @ a) * uvm, -(q @ b) * uvm))
        for (i, j, k) in ((0, 1, 2), (0, 2, 3)):
            if np.cross(Q[j] - Q[i], Q[k] - Q[i]) @ n >= 0:
                I.append((base + i, base + j, base + k))
            else:
                I.append((base + i, base + k, base + j))
    m.add(mat, P, N, UV, I)


def curved_slab(m, mat, col, inn, out, z0, z1):
    """A slab along Z between two (x, y) polylines of equal length (its inner
    and outer edges, y rising), from z0 to z1: no faces inside it."""
    q = []
    for k in range(len(inn) - 1):
        a, b, c, d = inn[k], out[k], out[k + 1], inn[k + 1]
        for z, nz in ((z1, 1), (z0, -1)):
            q.append(([(a[0], a[1], z), (b[0], b[1], z), (c[0], c[1], z), (d[0], d[1], z)], (0, 0, nz)))
    for (k, ny) in ((0, -1), (len(inn) - 1, 1)):
        a, b = inn[k], out[k]
        q.append(([(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], (0, ny, 0)))
    quads_add(m, mat, col, q)
    # the curved edges with smooth normals (flat facets read as a sawtooth of
    # light along the arc in the engine's shading)
    for (pl, sg) in ((inn, -1), (out, 1)):
        segn = []
        for k in range(len(pl) - 1):
            dx, dy = pl[k + 1][0] - pl[k][0], pl[k + 1][1] - pl[k][1]
            l = math.hypot(dx, dy) or 1.0
            segn.append((dy / l * sg, -dx / l * sg))
        vn = []
        for k in range(len(pl)):
            ns = [segn[j] for j in (k - 1, k) if 0 <= j < len(segn)]
            nx, ny = sum(n[0] for n in ns), sum(n[1] for n in ns)
            l = math.hypot(nx, ny) or 1.0
            vn.append((nx / l, ny / l, 0.0))
        m.color = col
        uvm = UVM.get(mat, 1.0)
        P, N, UV, I = [], [], [], []
        s_acc = 0.0
        for k in range(len(pl)):
            if k > 0:
                s_acc += math.hypot(pl[k][0] - pl[k - 1][0], pl[k][1] - pl[k - 1][1])
            for z in (z0, z1):
                P.append((pl[k][0], pl[k][1], z)); N.append(vn[k]); UV.append((z * uvm, -s_acc * uvm))
        for k in range(len(pl) - 1):
            i0, i1, i2, i3 = 2 * k, 2 * k + 1, 2 * k + 3, 2 * k + 2
            A, B, C = np.asarray(P[i0]), np.asarray(P[i1]), np.asarray(P[i2])
            n = np.array([segn[k][0], segn[k][1], 0.0])
            if np.cross(B - A, C - A) @ n >= 0:
                I += [(i0, i1, i2), (i0, i2, i3)]
            else:
                I += [(i0, i2, i1), (i0, i3, i2)]
        m.add(mat, P, N, UV, I)


def hab_port(m, sh, s, half):
    """One side's port, built on +X and turned half round for -X (s = -1)."""
    sub = CModel(seed=70 + s)
    sub.ground = False
    W0, W1 = PZ, PZ + PWT
    PX1 = PLX0 + 0.01     # (the trunk's shell ends inside the plate; its lining meets the passage's edges)

    def xc(yr, r):
        return math.sqrt(max(r * r - yr * yr, 0.0))

    # the side walls in strips, following the hull: a hazard frame from 5 cm
    # proud of the lining out through both skins (it buries the hole's edges),
    # then the trunk's wall to the plate, lined inside and painted outside
    n = 18
    y0r, y1r = PFB + 0.01 - HAX, PCT - 0.01 - HAX   # (their ends inside the floor's filler and the ceiling)
    ys = [y0r + (y1r - y0r) * k / n for k in range(n + 1)]
    inn = [(max(PX0, xc(y, RFR)), HAX + y) for y in ys]
    out = [(max(PX0 + 0.04, xc(y, HR + 0.02)), HAX + y) for y in ys]
    for sz in (-1, 1):
        z0, z1 = sorted((sz * W0, sz * W1))
        curved_slab(sub, "Steel", FRAME, inn, out, z0, z1)
        zl0, zl1 = sorted((sz * W0, sz * (W0 + 0.02)))
        zs0, zs1 = sorted((sz * (W0 + 0.02), sz * W1))
        curved_slab(sub, "Clad", LIGHT, out, [(PLX0, y) for (_, y) in out], zl0, zl1)
        curved_slab(sub, "Clad", PAINT, out, [(PX1, y) for (_, y) in out], zs0, zs1)
    # the ceiling: lining under, the painted shell over (both skins' top edges inside it)
    bx(sub, "Clad", LIGHT, PX0, PLX0, PY1, PY1 + 0.02, -W0, W0)
    bx(sub, "Clad", PAINT, PX0, PX1, PY1 + 0.02, PCT, -W1 + 0.005, W1 - 0.005)
    # the floor: the deck carried through, a filler under it (the bottom edges inside it)
    bx(sub, "Steel", DECKC, half, PLX0, HDECK - 0.04, HDECK, -W0, W0)
    bx(sub, "Steel", DARK, PX0, PX1 + 0.005, PFB, HDECK - 0.04, -W1 + 0.005, W1 - 0.005)
    # stiffening ribs round the trunk, outside
    for xr in (PLX0 - 0.06,):
        bx(sub, "Steel", GREY, xr - 0.03, xr + 0.03, PCT, PCT + 0.04, -W1 - 0.02, W1 + 0.02)
        for sz in (-1, 1):
            bx(sub, "Steel", GREY, xr - 0.03, xr + 0.03, PFB, PCT, sz * (W1 + 0.0), sz * (W1 + 0.04))
    # the berthing plate: a disc (the flanges' radius) with the passage through it
    yb0, yb1 = HDECK - HAX, PY1 - HAX
    corners = [math.atan2(yb0, W0), math.atan2(yb1, W0), math.atan2(yb1, -W0), math.atan2(yb0, -W0)]
    angs = sorted(set([TAU * i / 48 - math.pi for i in range(48)] + corners))

    def inner(t):
        c, sn = math.cos(t), math.sin(t)
        tz = W0 / abs(c) if abs(c) > 1e-9 else 1e9
        ty = (yb1 / sn) if sn > 1e-9 else ((yb0 / sn) if sn < -1e-9 else 1e9)
        r = min(tz, ty)
        return r * c, HAX + r * sn
    for k in range(len(angs)):
        t_a, t_b = angs[k], angs[(k + 1) % len(angs)]
        if t_b < t_a:
            t_b += TAU
        za, ya = inner(t_a)
        zb, yb = inner(t_b)
        oza, oya = PLR * math.cos(t_a), HAX + PLR * math.sin(t_a)
        ozb, oyb = PLR * math.cos(t_b), HAX + PLR * math.sin(t_b)
        face_poly(sub, "Steel", PLATE, [(PLX1, ya, za), (PLX1, yb, zb), (PLX1, oyb, ozb), (PLX1, oya, oza)], (1, 0, 0))
        face_poly(sub, "Clad", PAINT, [(PLX0, ya, za), (PLX0, yb, zb), (PLX0, oyb, ozb), (PLX0, oya, oza)], (-1, 0, 0))
        nz, ny = math.cos((t_a + t_b) / 2), math.sin((t_a + t_b) / 2)
        face_poly(sub, "Steel", GREY, [(PLX0, oya, oza), (PLX1, oya, oza), (PLX1, oyb, ozb), (PLX0, oyb, ozb)], (0, ny, nz))
    # the passage's edges through the plate, and a hazard sill
    face_poly(sub, "Steel", DECKC, [(PLX0, HDECK, -W0), (PLX1, HDECK, -W0), (PLX1, HDECK, W0), (PLX0, HDECK, W0)], (0, 1, 0))
    face_poly(sub, "Clad", LIGHT, [(PLX0, PY1, -W0), (PLX1, PY1, -W0), (PLX1, PY1, W0), (PLX0, PY1, W0)], (0, -1, 0))
    for sz in (-1, 1):
        face_poly(sub, "Steel", FRAME, [(PLX0, HDECK, sz * W0), (PLX1, HDECK, sz * W0), (PLX1, PY1, sz * W0), (PLX0, PY1, sz * W0)], (0, 0, -sz))
    bx(sub, "Steel", FRAME, PLX0 - 0.10, PLX1, HDECK, HDECK + 0.012, -W0, W0)
    # bolts round the plate, inside the branch's bore and clear of the passage
    for k in range(24):
        t = TAU * k / 24
        z, yr = 1.08 * math.cos(t), 1.08 * math.sin(t)
        if abs(z) < W0 + 0.06 and yb0 - 0.06 < yr < yb1 + 0.06:
            continue
        tb(sub, "Steel", DARK, (PLX1 - 0.002, HAX + yr, z), (PLX1 + 0.012, HAX + yr, z), 0.012, segs=6)
    m.merge(sub, M=rot_y(math.pi) if s < 0 else None)
    # colliders: the trunk's floor, ceiling and walls, the plate round the passage
    boxes = [((half + PLX1) / 2, HDECK - 0.06, 0, PLX1 - half, 0.12, 2 * W0),
             ((PX0 + PLX1) / 2, (PY1 + PCT + 0.05) / 2, 0, PLX1 - PX0, PCT + 0.05 - PY1, 2 * W1),
             ((1.0 + PLX1) / 2, HAX, (W0 + W1) / 2, PLX1 - 1.0, PCT - PFB, W1 - W0),
             ((1.0 + PLX1) / 2, HAX, -(W0 + W1) / 2, PLX1 - 1.0, PCT - PFB, W1 - W0),
             ((PLX0 + PLX1) / 2, (PY1 + HAX + 1.28) / 2, 0, PLX1 - PLX0, HAX + 1.28 - PY1, 1.8),
             ((PLX0 + PLX1) / 2, (HDECK + PY1) / 2, (W0 + 1.25) / 2, PLX1 - PLX0, PY1 - HDECK, 1.25 - W0),
             ((PLX0 + PLX1) / 2, (HDECK + PY1) / 2, -(W0 + 1.25) / 2, PLX1 - PLX0, PY1 - HDECK, 1.25 - W0)]
    for (cx, cy, cz, sx, sy, sz) in boxes:
        sh.add((s * cx, cy, s * cz), (sx, sy, sz))


def hab_end_plate(m, s):
    """A junction's free end closed flat (s = +1 its +Z end): the lining's face
    inside, a raised cover plate with two stiffeners on the flange outside."""
    sub = CModel(seed=73 + s)
    sub.ground = False
    sub.color = LIGHT
    disk(sub, "Clad", HR - HT, 0.95 * s, segs=32, up=s < 0, uv_m=0.5)
    sub.color = PLATE
    disk(sub, "Steel", 1.18, 1.02 * s, segs=32, up=s > 0)
    sub.color = GREY
    lathe(sub, "Steel", [(1.18, min(1.0 * s, 1.02 * s)), (1.18, max(1.0 * s, 1.02 * s))], segs=32)
    m.merge(sub, M=rot_x(math.pi / 2), t=(0, HAX, 0))
    z0, z1 = sorted((1.02 * s, 1.08 * s))
    bx(m, "Steel", DARK, -1.0, 1.0, HAX - 0.06, HAX + 0.06, z0, z1)
    z0, z1 = sorted((1.015 * s, 1.075 * s))
    bx(m, "Steel", DARK, -0.06, 0.06, HAX - 1.0, HAX + 1.0, z0, z1)
    # a stencilled data plate by the deck line
    z0, z1 = sorted((1.02 * s, 1.03 * s))
    bx(m, "Steel", SAFETY, 0.35, 0.75, HDECK + 0.05, HDECK + 0.25, z0, z1)


def hab_junction(m, sh, window, join):
    L, R, cb, cf = join
    ports = [s for s, on in ((-1, L), (1, R)) if on]
    wins = [s for s in (-1, 1) if window and s not in ports]
    bands = [-1, -PHZ, -0.38, 0.38, PHZ, 1] if window else [-1, -PHZ, PHZ, 1]

    def skip(i, k):
        mid = (bands[k] + bands[k + 1]) / 2
        for s in ports:
            if abs(mid) < PHZ and i in HOLE_I[s]:
                return True
        if abs(mid) < 0.38:
            if 1 in wins and i in (0, 31):
                return True
            if -1 in wins and i in (15, 16):
                return True
        return False
    hull(m, -1, 1, skip=skip, bands=bands)
    for sx in wins:
        hy = HR * math.sin(TAU / 32)
        x = sx * (HR * math.cos(TAU / 32) - 0.01)
        for (yy0, yy1, zz0, zz1) in ((-hy - 0.06, -hy, -0.44, 0.44), (hy, hy + 0.06, -0.44, 0.44),
                                     (-hy, hy, -0.44, -0.38), (-hy, hy, 0.38, 0.44)):
            bx(m, "Steel", GREY, x - 0.06, x + 0.06, HAX + yy0, HAX + yy1, zz0, zz1)
        bx(m, "Pane", (1, 1, 1), x - 0.012, x + 0.012, HAX - hy, HAX + hy, -0.38, 0.38)
        sh.add((x, HAX, 0), (0.1, 2 * hy, 0.76))
    flange(m, -1, -1)
    flange(m, 1, 1)
    hab_saddles(m, sh, (-0.87, 0.87))
    half = hab_deck(m, sh, -1, 1)
    hab_ring_colliders(sh, -1, 1, skip=lambda a: any(s * math.cos(a) > 0.97 for s in wins),
                       split=lambda a: any(s * math.cos(a) > 0.3 for s in ports))
    bx(m, "Steel", GREY, -0.12, 0.12, HAX + HR - HT - 0.10, HAX + HR - HT - 0.04, -0.95, 0.95)
    bx(m, "Lamp", LAMP_WARM, -0.05, 0.05, HAX + HR - HT - 0.105, HAX + HR - HT - 0.10, -0.8, 0.8)
    for sx in (-1, 1):
        xa, xb = sx * (half + 0.02) - 0.03, sx * (half + 0.02) + 0.03
        spans = ((-KICKZ, -PZ - 0.03), (PZ + 0.03, KICKZ)) if sx in ports else ((-KICKZ, KICKZ),)   # (cut ends inside the frame)
        for (za, zb) in spans:
            bx(m, "Steel", DARK, xa, xb, HDECK, HDECK + 0.08, za, zb)
    for s in ports:
        hab_port(m, sh, s, half)
    if cb:
        hab_end_plate(m, -1)
        sh.add((0, HAX, -0.975), (2.3, 2.3, 0.06))
    if cf:
        hab_end_plate(m, 1)
        sh.add((0, HAX, 0.975), (2.3, 2.3, 0.06))
    return m, sh, [("Light", "empty", (0, HAX + HR - HT - 0.3, 0))]


def join_flags(code):
    return ("L" in code, "R" in code, "b" in code, "f" in code)


def join_inside(c):
    """A junction's INSIDE (its MeshIn): the can's lining and deck, the
    passage's own faces, and the plate's face the branch sees."""
    x, y, z = c
    if math.hypot(x, y - HAX) < HR - HT * 0.5 and abs(z) < 1.0 + 1e-3:
        return True
    ax = abs(x)
    if PX0 - 0.05 <= ax <= PLX1 + 1e-3 and abs(z) <= PZ + 1e-3 and HDECK - 1e-3 <= y <= PY1 + 1e-3:
        return True
    if ax >= PLX1 - 1e-3 and math.hypot(z, y - HAX) < PLR - 0.01:
        return True
    return False


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
    # (builderperf: 2.0 m clear from the lowered deck. A 2 m leaf parked beside the
    # opening must stay inside the flanges' 1.28 m, which leaves 0.8 m of width for
    # opening AND parked leaf: so a centred 0.76 m opening closed by a PAIR of leaves
    # sliding apart, each parked inside the flange ring; centred on the narrower deck.)
    dx0, dx1, dy0, dy1 = -0.38, 0.38, HDECK, HDECK + 2.0
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
        for (a, b, c, d) in ((dx0 - 0.08, dx0, dy0, dy1 + 0.08), (dx1, dx1 + 0.08, dy0, dy1 + 0.08), (dx0, dx1, dy1, dy1 + 0.08)):
            # (z-fight, playtest 11-10: reaching 3 mm into the plate, the frame's edges lay in the plate strips' ends)
            bx(m, "Steel", (0.55, 0.50, 0.32), a, b, c, d, min(z0, z1), max(z0, z1))
    sh.add(((-R + dx0) / 2, HAX, 0), (R + dx0, 2 * R, 0.08))
    sh.add(((R + dx1) / 2, HAX, 0), (R - dx1, 2 * R, 0.08))
    sh.add(((dx0 + dx1) / 2, (dy1 + HAX + R) / 2, 0), (dx1 - dx0, HAX + R - dy1, 0.08))
    sh.add(((dx0 + dx1) / 2, (HAX - R + dy0) / 2, 0), (dx1 - dx0, dy0 - (HAX - R), 0.08))
    hab_saddles(m, sh, (0.0,))
    # the right leaf slides +X (its leading edge, chevrons and dogs, on its -X side);
    # the left one is the same leaf turned about Y (kit_live slides Door2 the other way)
    # (0.39 m each, meeting at the middle in one plane; 1 cm behind each jamb)
    lm, lsh = door_leaf(0.39, 2.0, heavy=True, t=0.05, ww=0.16, wx=0.05)
    l2 = CModel(seed=302); l2.ground = False
    l2.merge(lm, M=rot_y(math.pi))
    return m, sh, [("Door", "door", (lm, lsh, (0.195, HDECK, -0.065))), ("Door2", "door", (l2, lsh, (-0.195, HDECK, -0.065)))]


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
    bx(m, "Steel", SAFETY, -0.25, 0.25, 1.45, 1.75, WT / 2 - 0.002, WT / 2 + 0.006)
    bx(m, "Steel", DARK, -0.2, 0.2, 1.5, 1.7, WT / 2 + 0.004, WT / 2 + 0.010)
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
    bx(m, "Steel", GREY, -0.08, 0.08, -0.0, 0.01, -0.277, -0.25)
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
    # (z-fight, playtest 11-10: the tray's floor and its sides ended in one plane; the floor stops 2 mm short)
    bx(m, "Steel", GREY, -0.998, 0.998, 0, 0.004, -0.096, 0.096)
    for s in (-1, 1):
        bx(m, "Steel", GREY, -1, 1, 0, 0.1, s * 0.098 - 0.002, s * 0.098 + 0.002)
    for k, (z, r) in enumerate(((-0.05, 0.016), (0.0, 0.02), (0.05, 0.014), (-0.02, 0.012))):
        tb(m, "Rubber", RUBBER, (-1, 0.004 + r + (0.03 if k == 3 else 0), z), (1, 0.004 + r + (0.03 if k == 3 else 0), z), r, segs=6)
    for x in (-0.7, 0.0, 0.7):
        bx(m, "Steel", DARK, x - 0.02, x + 0.02, 0, 0.103, -0.11, 0.11)
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
    # (the back stands 15 mm in from the box's -0.30, so the water and H2 nozzles' flanges, whose
    # faces end on the ports at -0.30, stand proud of it: a pipe is seen to meet them)
    bx(m, "Clad", STEELWALL, -0.45, 0.30, 0.0, 1.55, -0.285, 0.30, sh=sh)
    bx(m, "Steel", DARK, -0.43, 0.28, 0.0, 0.07, -0.27, 0.28)
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
    with its gauge. (Ty 11-10: the manifold floated on the necks and stopped
    short of the regulator.) Each cylinder valve's pigtail rises into a boss on
    the header; the header is capped at one end and runs INTO the regulator,
    which hangs on the right post by a bracket; the outlet goes back to a wall
    plate. The straps are bands round each cylinder, bolted to two back rails.
    The frame posts stand 3 mm proud of the base and the top bar; nothing
    shares a face."""
    m, sh = CModel(seed=93), Shell()
    GREEN = (0.18, 0.34, 0.22)
    bx(m, "Steel", DARK, -0.6, 0.6, 0.0, 0.06, -0.25, 0.25, sh=sh)
    for x in (-0.58, 0.58):
        bx(m, "Steel", GREY, x - 0.023, x + 0.023, 0.0, 1.753, -0.243, -0.197)
    bx(m, "Steel", GREY, -0.597, 0.597, 1.70, 1.75, -0.24, -0.20)
    for y in (0.4, 1.1):     # the strap rails between the posts
        bx(m, "Steel", GREY, -0.58, 0.58, y - 0.02, y + 0.02, -0.236, -0.204)
    for k, x in enumerate((-0.38, 0.0, 0.38)):
        tb(m, "Steel", GREEN, (x, 0.06, 0.0), (x, 1.42, 0.0), 0.17, segs=18)
        m.color = GREEN
        tube(m, "Steel", (x, 1.42, 0.0), (x, 1.52, 0.0), 0.17, segs=18, uv_m=UVM["Steel"], r1=0.06)
        # the neck ring and the valve: a block, its handwheel, the pigtail up into the header's boss
        tb(m, "Steel", LIGHT, (x, 1.50, 0.0), (x, 1.60, 0.0), 0.035, segs=10)
        bx(m, "Steel", DARK, x - 0.03, x + 0.03, 1.595, 1.655, -0.03, 0.03)
        tb(m, "Steel", SAFETY, (x, 1.625, 0.03), (x, 1.625, 0.07), 0.008, segs=6)
        tb(m, "Steel", SAFETY, (x, 1.625, 0.07), (x, 1.625, 0.078), 0.028, segs=12)
        tb(m, "Steel", LIGHT, (x, 1.65, 0.0), (x, 1.725, 0.0), 0.009, segs=8)
        tb(m, "Steel", LIGHT, (x - 0.026, 1.725, 0.0), (x + 0.026, 1.725, 0.0), 0.022, segs=10)
        for y in (0.4, 1.1):
            tb(m, "Steel", DARK, (x, y - 0.015, 0.0), (x, y + 0.015, 0.0), 0.174, segs=18)
            bx(m, "Steel", DARK, x - 0.02, x + 0.02, y - 0.015, y + 0.015, -0.21, -0.16)
        bx(m, "Steel", PAINT, x - 0.06, x + 0.06, 1.0, 1.2, 0.165, 0.176)
        sh.add((x, 0.8, 0), (0.34, 1.5, 0.34))
    # the header: a cap at the left, into the regulator on the right
    tb(m, "Steel", LIGHT, (-0.42, 1.725, 0.0), (0.46, 1.725, 0.0), 0.016, segs=10)
    tb(m, "Steel", DARK, (-0.43, 1.725, 0.0), (-0.41, 1.725, 0.0), 0.02, segs=10)
    # the regulator on its bracket off the right post, its gauge and the outlet to the wall plate
    bx(m, "Steel", DARK, 0.44, 0.56, 1.64, 1.80, -0.05, 0.07)
    bx(m, "Steel", GREY, 0.50, 0.57, 1.66, 1.70, -0.21, -0.045)
    tb(m, "Steel", PAINT, (0.50, 1.76, 0.065), (0.50, 1.76, 0.09), 0.045, segs=14)
    tb(m, "Steel", LIGHT, (0.47, 1.67, -0.04), (0.47, 1.67, -0.247), 0.012, segs=8)
    bx(m, "Steel", GREY, 0.42, 0.52, 1.62, 1.72, -0.25, -0.244)
    return m, sh, []


# ── power networks II (S5: scripts/base_power.lua) ──────────────────────────

def breaker_panel(w, h, d, amps, seed):
    """A wall-hung breaker enclosure (mount: +Y out of the face): a grey steel
    box, its door with a window over the breaker's handle, a rating plate, a
    cable gland under it for each way, and its state lamp (a "Lens" child
    base_power lights green, amber or red)."""
    def fn(mat):
        m, sh = CModel(seed=seed), Shell()
        m.ground = False
        bx(m, "Steel", (0.56, 0.58, 0.58), -w / 2, w / 2, 0, d * 0.82, -h / 2, h / 2)
        # the door, a hair proud, with its hinge side and latch
        bx(m, "Steel", (0.60, 0.62, 0.62), -w / 2 + 0.01, w / 2 - 0.01, d * 0.82, d * 0.86, -h / 2 + 0.01, h / 2 - 0.01)
        bx(m, "Steel", DARK, w / 2 - 0.05, w / 2 - 0.02, d * 0.86, d * 0.9, -0.04, 0.04)
        # the window over the breaker row, and the handles behind it
        bx(m, "Steel", DARK, -w / 2 + 0.05, w / 2 - 0.08, d * 0.86, d * 0.87, 0.02, h / 2 - 0.08)
        n = 3 if amps < 100 else 4
        for k in range(n):
            x = -w / 2 + 0.08 + k * (w - 0.2) / max(1, n - 1)
            bx(m, "Steel", (0.12, 0.12, 0.13) if k else SAFETY, x - 0.012, x + 0.012, d * 0.87, d * 0.9, h / 2 - 0.2, h / 2 - 0.12)
        # the rating plate and the hazard flash
        # (2.5 mm proud of the door: thinner fights it)
        bx(m, "Steel", LIGHT, -w / 2 + 0.05, -w / 2 + 0.18, d * 0.86, d * 0.86 + 0.0025, -h / 2 + 0.05, -h / 2 + 0.11)
        bx(m, "Steel", SAFETY, -0.03, 0.03, d * 0.86, d * 0.86 + 0.0025, -0.045, 0.012)
        # the glands under it
        for k in range(2):
            x = -w / 4 + k * w / 2
            tb(m, "Rubber", RUBBER, (x, d * 0.4, -h / 2), (x, d * 0.4, -h / 2 - 0.05), 0.02, segs=8)
        lm = CModel(seed=seed + 1)
        lm.ground = False
        bx(lm, "Lamp", (0.4, 1.0, 0.45), -0.015, 0.015, 0, 0.012, -0.015, 0.015)
        return m, sh, [("Lens", "mesh", (lm, (w / 2 - 0.07, d * 0.87, h / 2 - 0.05)))]
    return fn


def p_transformer(mat):
    """A 100 kVA pad-mounted transformer: its tank in a green-grey enclosure on
    a plinth, cooling fins down both sides, three HV bushings on top (porcelain
    sheds) where the 11 kV cable lands, the LV cable box on its front, the
    rating and danger plates."""
    m, sh = CModel(seed=131), Shell()
    bx(m, "Concrete", CONC_DARK, -0.72, 0.72, 0.0, 0.12, -0.56, 0.56, sh=sh)
    col = (0.38, 0.44, 0.38)
    bx(m, "Steel", col, -0.55, 0.55, 0.12, 1.30, -0.40, 0.40, sh=sh)
    bx(m, "Steel", (0.34, 0.40, 0.34), -0.58, 0.58, 1.30, 1.36, -0.43, 0.43)
    for s in (-1, 1):
        for k in range(7):
            z = -0.33 + k * 0.11
            bx(m, "Steel", col, s * 0.55, s * 0.69, 0.22, 1.20, z - 0.012, z + 0.012)
    sh.add((0, 0.71, 0), (1.38, 0.98, 0.80))
    # the bushings: a porcelain stack each and a copper stud
    for x in (-0.3, 0.0, 0.3):
        tb(m, "Steel", DARK, (x, 1.36, 0.1), (x, 1.40, 0.1), 0.06, segs=10)
        for k in range(4):
            y = 1.40 + k * 0.05
            tb(m, "Steel", (0.62, 0.40, 0.28), (x, y, 0.1), (x, y + 0.03, 0.1), 0.05, segs=12)
            tb(m, "Steel", (0.62, 0.40, 0.28), (x, y + 0.03, 0.1), (x, y + 0.05, 0.1), 0.032, segs=10)
        tb(m, "Steel", (0.72, 0.45, 0.25), (x, 1.60, 0.1), (x, 1.66, 0.1), 0.012, segs=6)
    # the LV cable box on the front, its conduit into the ground
    bx(m, "Steel", (0.34, 0.40, 0.34), -0.35, 0.35, 0.18, 0.75, 0.40, 0.52, sh=sh)
    tb(m, "Rubber", RUBBER, (0.0, 0.18, 0.47), (0.0, 0.02, 0.47), 0.05, segs=10)
    # the plates
    bx(m, "Steel", SAFETY, -0.12, 0.12, 0.90, 1.06, 0.40, 0.406)
    bx(m, "Steel", LIGHT, 0.22, 0.46, 0.95, 1.10, 0.40, 0.405)
    return m, sh, []


def p_powerPole(mat):
    """An 8 m distribution pole: a tapered galvanised tube (or a spun concrete
    pole), a 1.4 m crossarm at 7.6 m with three pin insulators where the
    strung cable lands, its earth wire and a stencilled number plate."""
    m, sh = CModel(seed=141), Shell()
    if mat == "concrete":
        m.color = CONC
        tube(m, "Concrete", (0, 0.0, 0), (0, 8.0, 0), 0.14, segs=12, uv_m=UVM["Concrete"], r1=0.09)
    else:
        m.color = LIGHT
        tube(m, "Steel", (0, 0.0, 0), (0, 8.0, 0), 0.11, segs=12, uv_m=UVM["Steel"], r1=0.075)
        tb(m, "Steel", GREY, (0, 0.0, 0), (0, 0.04, 0), 0.22, segs=12)
    tb(m, "Steel", DARK, (0, 8.0, 0), (0, 8.04, 0), 0.10, segs=10)
    sh.add((0, 4.0, 0), (0.26, 8.0, 0.26))
    # the crossarm and its braces
    bx(m, "Steel", GREY, -0.70, 0.70, 7.52, 7.60, -0.05, 0.05)
    for s in (-1, 1):
        tb(m, "Steel", GREY, (s * 0.06, 7.15, 0.0), (s * 0.5, 7.53, 0.0), 0.012, segs=5)
    for x in (-0.6, 0.0, 0.6):
        tb(m, "Steel", DARK, (x, 7.60, 0), (x, 7.66, 0), 0.008, segs=5)
        for k in range(3):
            y = 7.66 + k * 0.035
            tb(m, "Steel", (0.62, 0.40, 0.28), (x, y, 0), (x, y + 0.025, 0), 0.03, segs=10)
    # the earth wire down it and the number plate at eye height
    tb(m, "Steel", (0.45, 0.32, 0.20), (0.12, 0.2, 0.0), (0.09, 7.5, 0.0), 0.004, segs=4)
    bx(m, "Steel", SAFETY, -0.08, 0.08, 2.2, 2.42, 0.10 if mat == "concrete" else 0.08, 0.11 if mat == "concrete" else 0.09)
    return m, sh, []


def p_junctionBox(mat):
    """A feeder pillar: a green steel cabinet on a buried root, its double
    door and latch, a vent under its hood, the cable glands at its foot."""
    m, sh = CModel(seed=151), Shell()
    col = (0.24, 0.34, 0.26)
    bx(m, "Steel", col, -0.30, 0.30, 0.0, 0.95, -0.18, 0.18, sh=sh)
    bx(m, "Steel", (0.22, 0.31, 0.24), -0.32, 0.32, 0.95, 1.0, -0.20, 0.20)
    bx(m, "Steel", (0.26, 0.37, 0.28), -0.28, -0.005, 0.08, 0.88, 0.18, 0.186)
    bx(m, "Steel", (0.26, 0.37, 0.28), 0.005, 0.28, 0.08, 0.88, 0.18, 0.186)
    bx(m, "Steel", DARK, -0.02, 0.02, 0.45, 0.55, 0.186, 0.196)
    for k in range(5):
        y = 0.78 + k * 0.02
        bx(m, "Steel", DARK, -0.2, 0.2, y, y + 0.008, 0.186, 0.19)
    bx(m, "Steel", SAFETY, -0.06, 0.06, 0.62, 0.70, 0.186, 0.19)
    for x in (-0.18, 0.0, 0.18):
        tb(m, "Rubber", RUBBER, (x, 0.05, -0.18), (x, 0.05, -0.24), 0.025, segs=8)
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
    "habSteps": (p_habSteps, ["steel", "concrete"]),
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
    "breaker63": (breaker_panel(0.40, 0.50, 0.14, 63, 121), ["steel"]),
    "breaker160": (breaker_panel(0.56, 0.72, 0.20, 160, 123), ["steel"]),
    "transformer": (p_transformer, ["steel"]),
    "powerPole": (p_powerPole, ["steel", "concrete"]),
    "junctionBox": (p_junctionBox, ["steel"]),
}


# ── hab junctions: hidden variants of the Hab Segment and the Hab Window
# Segment (a window side that has a port loses its window, so a window
# junction with ports on both sides is the plain one: none is made)
for _code in JOIN_CODES:
    PIECES["habSegJ" + _code] = ((lambda mat, j=join_flags(_code): p_habSeg(mat, False, j)), ["steel"])
    if not ("L" in _code and "R" in _code):
        PIECES["habWindowJ" + _code] = ((lambda mat, j=join_flags(_code): p_habSeg(mat, True, j)), ["steel"])

# ── S4: the character pieces (tools/gen_kit_props.py) ────────────────────────
PIECES.update(gen_kit_props.pieces(sys.modules[__name__]))

# ── S6: the reactor's components (tools/gen_kit_nuclear.py) ─────────────────
import gen_kit_nuclear  # noqa: E402
MATS.update(gen_kit_nuclear.MATERIALS)
PIECES.update(gen_kit_nuclear.pieces(sys.modules[__name__]))

# ── S7: the fluid network's pieces and the pressure pieces (tools/gen_kit_fluids.py) ──
import gen_kit_fluids  # noqa: E402
MATS.update(gen_kit_fluids.MATERIALS)
PIECES.update(gen_kit_fluids.pieces(sys.modules[__name__]))
PIECES["pressuriser"] = (gen_kit_fluids.pressuriser_wrap(sys.modules[__name__], PIECES["pressuriser"][0]), PIECES["pressuriser"][1])

# ── S8: the logic pieces: sensors, gates, inputs, outputs, radios, the PLC (tools/gen_kit_logic.py) ──
import gen_kit_logic  # noqa: E402
MATS.update(gen_kit_logic.MATERIALS)
PIECES.update(gen_kit_logic.pieces(sys.modules[__name__]))
# ── X1/X2: the air and survey pieces (tools/gen_kit_survey.py) ──────────────
import gen_kit_survey  # noqa: E402
MATS.update(gen_kit_survey.MATERIALS)
PIECES.update(gen_kit_survey.pieces(sys.modules[__name__]))
# ── X5: the quarry, conveyors, tubes, hoppers, silos, the loading chute (tools/gen_kit_quarry.py) ──
import gen_kit_quarry  # noqa: E402
MATS.update(gen_kit_quarry.MATERIALS)
PIECES.update(gen_kit_quarry.pieces(sys.modules[__name__]))
# ── X6: the refineries and the Fabricator (tools/gen_kit_refinery.py) ──
import gen_kit_refinery  # noqa: E402
MATS.update(gen_kit_refinery.MATERIALS)
PIECES.update(gen_kit_refinery.pieces(sys.modules[__name__]))
# ── X9: the laser's pieces (tools/gen_kit_weapons.py; its main also writes the craft turret) ──
import gen_kit_weapons  # noqa: E402
MATS.update(gen_kit_weapons.MATERIALS)
PIECES.update(gen_kit_weapons.pieces(sys.modules[__name__]))
# ── S5 (interaction plan): the lockable storage props, cabinet and locker (tools/gen_kit_storage.py) ──
import gen_kit_storage  # noqa: E402
PIECES.update(gen_kit_storage.pieces(sys.modules[__name__]))

# ── S4: PAINT SURFACES. node:setTint tints everything a node draws, so what
# paint must not touch, and a wall's second face, are split into children of
# their own after the piece is built (no piece function changes):
#   "MeshIn"  a two-faced piece's inside: a wall's triangles behind its middle
#             plane (z < 0), a hab can's inside its hull (radius under the
#             hull's inner skin): its lining and deck. kit_paint tints it apart.
#   "Glass"   panes and lamp lenses (never painted: a painted window is not
#             orange glass), on every paintable piece.
FACES2 = {
    "z": {"wall", "halfWall", "wall12", "doorWall", "doorWallM", "doubleDoor", "windowWall", "porthole", "airlockWall",
          "openFrame", "ventWall", "leadWall", "gable"},
    "ring": {"habSeg", "habWindow"} | {"habSegJ" + c for c in JOIN_CODES} | {"habWindowJ" + c for c in JOIN_CODES if not ("L" in c and "R" in c)},
}
NO_PAINT = {"lightFitting", "wallScreen", "switchPlate", "lampDesk", "lampFloor"}
NO_PAINT |= gen_kit_logic.NO_PAINT   # (S8: control gear is never painted)
UNPAINTED = {"Pane", "Lamp", "Screen"}


def faces2_of(piece):
    for k, names in FACES2.items():
        if piece in names:
            return k
    return None


def split_model(m, take):
    """(kept, taken): the model's triangles split by take(mat, centroid) → bool. Vertices are
    re-indexed per part, so each half's bounds are its own."""
    from gen_part_meshes import Model as _Model
    keep, got = CModel(seed=7), CModel(seed=8)
    keep.ground = got.ground = False
    for mat, (Ps, Ns, UVs, Is, _) in m.parts.items():
        P = np.vstack(Ps); N = np.vstack(Ns); UV = np.vstack(UVs); I = np.vstack(Is)
        C = np.vstack(m.cols[mat])
        cen = (P[I[:, 0]] + P[I[:, 1]] + P[I[:, 2]]) / 3
        if take.__code__.co_argcount >= 3:
            # (builderperf) the triangle's facing too: its vertices' normals averaged
            nrm = N[I[:, 0]] + N[I[:, 1]] + N[I[:, 2]]
            nrm = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
            sel = np.array([bool(take(mat, c, n)) for c, n in zip(cen, nrm)], bool)
        else:
            sel = np.array([bool(take(mat, c)) for c in cen], bool)
        for model, mask in ((got, sel), (keep, ~sel)):
            if not mask.any():
                continue
            J = I[mask]
            used = np.unique(J)
            remap = -np.ones(len(P), np.int64)
            remap[used] = np.arange(len(used))
            _Model.add(model, mat, P[used], N[used], UV[used], remap[J])
            model.cols.setdefault(mat, []).append(C[used])
            model.tags.setdefault(mat, []).append(np.zeros(len(J), np.int64))
    return keep, got


def paint_split(piece, m, children):
    """The piece's model less its Glass and MeshIn, and those as extra mesh children."""
    if piece in NO_PAINT or piece.startswith(("decal", "grime", "sign")):
        return m, children
    kids = list(children)
    if any(mat in UNPAINTED for mat in m.parts):
        m, g = split_model(m, lambda mat, c: mat in UNPAINTED)
        if g.parts:
            kids.append(("Glass", "mesh", (g, (0, 0, 0))))
    f2 = faces2_of(piece)
    inn = None
    if f2 == "z":
        # (builderperf, 11-10) the inside is the faces that LOOK into the room: facing -Z, on or
        # beyond the panel's inner face. Split by centroid before, every face across the wall's
        # thickness (its top, its ends, a doorway's reveals, a sill) was cut along its diagonal,
        # half painted and lit as the inside and half as the outside. Now those are all the
        # Mesh's, so the Mesh alone is the wall's whole silhouette and MeshIn need not cast
        # (one sun-map draw less a wall), and a concrete panel's lifting inserts (on its top,
        # inside the thickness) leave MeshIn with the concrete alone (one instance less).
        m, inn = split_model(m, lambda mat, c, n: n[2] < -0.5 and c[2] < -(WT / 2) + 1e-3)
    elif f2 == "ring" and "J" in piece:
        m, inn = split_model(m, lambda mat, c: join_inside(c))
    elif f2 == "ring":
        m, inn = split_model(m, lambda mat, c: math.hypot(c[0], c[1] - HAX) < HR - HT * 0.5 and abs(c[2]) < 1.0 + 1e-3)
    if inn is not None and inn.parts:
        kids.append(("MeshIn", "mesh", (inn, (0, 0, 0))))
    return m, kids


# ── writing ──────────────────────────────────────────────────────────────────

def f3(v):
    return f"({v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f})"


def mats_of(model, refl=None):
    def one(n):
        t = MATS[n]()
        if refl is not None and "shading: Physical" in t:
            t = t.replace("shading: Physical", f"reflectivity: {refl},\n                shading: Physical")
        return f'            "{n}": {t}'
    return ",\n".join(one(n) for n in sorted(model.parts.keys()))


# (S5 polish) how much of the sky a surface reflects (1 = all, the default):
# a wall's or hab can's INSIDE (its MeshIn) sees the room, not the sky, so it
# reflects little of the sky map (which shows the red ground and the blue
# sky that turned white walls pink indoors); a floor or roof panel's
# underside is a ceiling. On a moving world a reflection probe re-captures
# every frame, so the room can't be captured instead (a note for E).
INSIDE_REFL = 0.12
FLOOR_REFL = 0.35
FLOOR_LIKE = {"floor", "floor21", "floor11", "floorHatch", "roofPitch", "roofRidge"}


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


def node_mesh(name, glb, model, at, parent, cast=True, refl=None):
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
{mats_of(model, refl)},
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
    m, children = paint_split(piece, m, children)
    name = "Kit" + piece[0].upper() + piece[1:] + "_" + mat
    glb = f"{piece}_{mat}.glb"
    c, lo, hi = centre(m)
    small = (hi - lo).max() < 0.7 or mat == "film"
    mesh_lo, mesh_hi = lo.copy(), hi.copy()
    nodes = [node_empty(name, (0, 0, 0), None, tags=["base_part", "kit"]),
             node_mesh("Mesh", f"{FOLDER}/{glb}", m, c, 0, cast=not small, refl=FLOOR_REFL if piece in FLOOR_LIKE else None)]
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
            # (S4: a wall's inside and a piece's glass are as much of it as its Mesh: they cast)
            # (builderperf: a two-faced WALL's MeshIn is only its room-facing faces, behind the
            # Mesh's own: the Mesh casts the whole shadow. A hab can's lining and deck still cast,
            # for the sun through its windows and open ends.)
            cast = cname in ("MeshIn", "Glass") and not small and not (cname == "MeshIn" and faces2_of(piece) == "z")
            nodes.append(node_mesh(cname, f"{FOLDER}/{piece}_{mat}_{cname.lower()}.glb", cm, np.asarray(at) + cc, 0, cast=cast,
                                   refl=INSIDE_REFL if cname == "MeshIn" else None))
            extra.append((f"{piece}_{mat}_{cname.lower()}.glb", cm))
            if True:   # (every drawn child is the piece's: the fixture's bounds hold them all)
                mesh_lo = np.minimum(mesh_lo, np.asarray(at) + clo)
                mesh_hi = np.maximum(mesh_hi, np.asarray(at) + chi)
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
    lo, hi = mesh_lo, mesh_hi
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
    # (S4) the decal and grime atlases and their maps, the sign's blank face
    if not dry and (not only or "--tex" in sys.argv):
        gen_kit_props.textures()
    fixture =["-- Written by tools/gen_kit_parts.py: each kit prefab's mesh bounds (ground frame),", "-- its collider count and live children. tests/smoke_kit.lua reads it.", "return {"]
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
