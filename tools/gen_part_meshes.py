#!/usr/bin/env python3
"""Generate the rocket parts' glTF meshes into models/parts/ and point the part
prefabs at them.

    python3 tools/gen_part_meshes.py           # meshes + prefab materials
    python3 tools/gen_part_meshes.py --dry     # meshes only, print the AABBs

Every part is built here from numpy primitives — lathed shells with proper
cylindrical UVs, bevelled flanges, bolt rings, struts, nozzle bells — and
written as a .glb by hand (no glTF library is needed). The surface comes from
the SHARED texture library in textures/parts/ (tools/gen_part_textures.py):
each mesh names a handful of materials ("Paint", "Metal", "Bell", …) and the
prefab binds each name to a texture set through `object_materials`, so a tank,
a pod and an engine all draw from the same few maps. UVs are in metres of
surface (1 paint tile = 1 m), which is what keeps panel and rivet sizes the
same on every part.

Rules this file keeps, because the physics depends on them:

* The engine RECENTERS a model on its own bounding box. Every exterior mesh is
  therefore built symmetric about its centre at the part's builder height `h`,
  and `check_centered` refuses one whose box would shift the part.
* A prefab's root SCALE also scales its collider, and those numbers belong to
  the flight model. Meshes are authored at their real size and divided by the
  prefab's scale here, so the root transform and every collider stay as they
  were. UVs are computed before the division, so textures are not stretched.
* Prefab children the scripts look up by name (Engine Flame, LegUpperPivot,
  Dock Light, RCS Plume, …) are not touched. Only the root's `matter` and
  material are replaced, plus the pod's interior subtree.
"""
import json
import math
import os
import re
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_textures import INTERIOR, MARKINGS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "models", "parts")
PREFABS = os.path.join(ROOT, "prefabs")
TEX = "textures/parts/"
TAU = 2 * math.pi
ATLAS = 1024.0


# ── mesh container ───────────────────────────────────────────────────────────

class Model:
    def __init__(self):
        self.parts = {}  # material -> [P list, N list, UV list, I list, count]

    def add(self, mat, P, N, UV, I):
        P = np.asarray(P, np.float64).reshape(-1, 3)
        N = np.asarray(N, np.float64).reshape(-1, 3)
        UV = np.asarray(UV, np.float64).reshape(-1, 2)
        I = np.asarray(I, np.int64).reshape(-1, 3)
        # Orient every triangle to agree with its vertices' normals (CCW out).
        a, b, c = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
        fn = np.cross(b - a, c - a)
        vn = N[I[:, 0]] + N[I[:, 1]] + N[I[:, 2]]
        flip = (fn * vn).sum(1) < 0
        I = I.copy()
        I[flip] = I[flip][:, [0, 2, 1]]
        e = self.parts.setdefault(mat, [[], [], [], [], 0])
        e[0].append(P); e[1].append(N); e[2].append(UV); e[3].append(I + e[4])
        e[4] += len(P)

    def merge(self, other, M=None, t=(0, 0, 0)):
        for mat, (Ps, Ns, UVs, Is, _) in other.parts.items():
            P = np.vstack(Ps); N = np.vstack(Ns); UV = np.vstack(UVs); I = np.vstack(Is)
            if M is not None:
                P = P @ np.asarray(M).T
                N = N @ np.asarray(M).T
            P = P + np.asarray(t)
            self.add(mat, P, N, UV, I)

    def arrays(self):
        out = {}
        for mat, (Ps, Ns, UVs, Is, _) in self.parts.items():
            out[mat] = (np.vstack(Ps), np.vstack(Ns), np.vstack(UVs), np.vstack(Is))
        return out

    def bounds(self):
        P = np.vstack([np.vstack(e[0]) for e in self.parts.values()])
        return P.min(0), P.max(0)

    def tris(self):
        return sum(sum(len(i) for i in e[3]) for e in self.parts.values())


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def frame_to(d):
    """A rotation taking +Y onto unit vector d."""
    d = np.asarray(d, float); d = d / np.linalg.norm(d)
    y = np.array([0.0, 1.0, 0.0])
    v = np.cross(y, d); c = float(np.dot(y, d))
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1 / (1 + c))


# ── primitives ───────────────────────────────────────────────────────────────

def lathe(m, mat, prof, segs=48, uv_m=1.0, u_tiles=None, smooth=False, a0=0.0, a1=TAU,
          v_norm=None, skip=None, inward=False, v0=0.0):
    """Revolve a (r, y) profile about +Y.

    UV: u runs around (u_tiles repeats over the full turn, default chosen so a
    tile is ~1/uv_m metres at the widest radius); v is the slant length in
    metres × uv_m, running DOWN the image as the profile climbs. v_norm=(a, b)
    maps the profile's length onto v ∈ [a, b] instead (nozzle bells).
    smooth: average the profile normals at shared points (curved surfaces).
    skip(i, j) -> True leaves cell (around i, band j) open — window holes.
    """
    prof = [(float(r), float(y)) for r, y in prof]
    rmax = max(r for r, _ in prof)
    if u_tiles is None:
        u_tiles = max(1, int(round(TAU * rmax * uv_m * (a1 - a0) / TAU)))
    nb = len(prof) - 1
    # slant lengths
    L = [0.0]
    for k in range(nb):
        (r0, y0), (r1, y1) = prof[k], prof[k + 1]
        L.append(L[-1] + math.hypot(r1 - r0, y1 - y0))
    total = L[-1] if L[-1] > 0 else 1.0
    # per-band profile normal (in r,y): perpendicular to (dr, dy) pointing out
    bandn = []
    for k in range(nb):
        (r0, y0), (r1, y1) = prof[k], prof[k + 1]
        dr, dy = r1 - r0, y1 - y0
        l = math.hypot(dr, dy) or 1.0
        bandn.append((dy / l, -dr / l))  # (nr, ny)
    pointn = []
    for k in range(nb + 1):
        if k == 0:
            pointn.append(bandn[0])
        elif k == nb:
            pointn.append(bandn[-1])
        else:
            a, b = bandn[k - 1], bandn[k]
            s = (a[0] + b[0], a[1] + b[1]); l = math.hypot(*s) or 1.0
            pointn.append((s[0] / l, s[1] / l))
    full = abs((a1 - a0) - TAU) < 1e-9
    P, N, UV, I = [], [], [], []
    ang = [a0 + (a1 - a0) * i / segs for i in range(segs + 1)]
    for k in range(nb):
        (r0, y0), (r1, y1) = prof[k], prof[k + 1]
        n0 = pointn[k] if smooth else bandn[k]
        n1 = pointn[k + 1] if smooth else bandn[k]
        if v_norm:
            va = v_norm[0] + (v_norm[1] - v_norm[0]) * L[k] / total
            vb = v_norm[0] + (v_norm[1] - v_norm[0]) * L[k + 1] / total
        else:
            va, vb = v0 - L[k] * uv_m, v0 - L[k + 1] * uv_m
        base = len(P)
        for i, a in enumerate(ang):
            c, s = math.cos(a), math.sin(a)
            u = (a - a0) / TAU * u_tiles * (TAU / (a1 - a0) if not full else 1.0)
            for (r, y, nn, v) in ((r0, y0, n0, va), (r1, y1, n1, vb)):
                P.append((r * c, y, r * s))
                sg = -1.0 if inward else 1.0
                N.append((nn[0] * c * sg, nn[1] * sg, nn[0] * s * sg))
                UV.append((u, v))
        for i in range(segs):
            if skip and skip(i, k):
                continue
            a_ = base + i * 2
            b_ = base + (i + 1) * 2
            I.append((a_, b_, b_ + 1)); I.append((a_, b_ + 1, a_ + 1))
    m.add(mat, P, N, UV, I)


def disk(m, mat, r, y, segs=48, up=True, uv_m=1.0, r_in=0.0, cx=0.0, cz=0.0):
    """A flat (annular) cap facing +Y (up) or −Y, planar UV in metres."""
    P, N, UV, I = [], [], [], []
    ny = 1.0 if up else -1.0
    for i in range(segs + 1):
        a = TAU * i / segs
        c, s = math.cos(a), math.sin(a)
        for rr in (r_in, r):
            P.append((cx + rr * c, y, cz + rr * s)); N.append((0, ny, 0))
            UV.append((rr * c * uv_m, rr * s * uv_m))
    for i in range(segs):
        a_, b_ = i * 2, (i + 1) * 2
        I.append((a_, b_, b_ + 1)); I.append((a_, b_ + 1, a_ + 1))
    m.add(mat, P, N, UV, I)


def box(m, mat, center, size, M=None, uv_m=1.0, bevel=0.0):
    """An axis box (optionally rotated by M about its centre), per-face UVs in
    metres. `bevel` chamfers the vertical edges (reads as a machined block)."""
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    M = np.eye(3) if M is None else np.asarray(M)
    c = np.asarray(center, float)
    faces = [((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
             ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
             ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    h = np.array([hx, hy, hz])
    P, N, UV, I = [], [], [], []
    for n, uax, vax in faces:
        n, uax, vax = np.array(n, float), np.array(uax, float), np.array(vax, float)
        cen = n * h
        eu, ev = abs(uax @ h), abs(vax @ h)
        base = len(P)
        for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            p = cen + uax * eu * su + vax * ev * sv
            P.append(M @ p + c); N.append(M @ n)
            UV.append(((p @ uax) * uv_m, -(p @ vax) * uv_m))
        I.append((base, base + 1, base + 2)); I.append((base, base + 2, base + 3))
    m.add(mat, P, N, UV, I)


def tube(m, mat, p0, p1, r, segs=10, caps=True, uv_m=1.0, r1=None):
    """A cylinder (or cone with r1) between two points."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    L = float(np.linalg.norm(d))
    sub = Model()
    rr1 = r if r1 is None else r1
    lathe(sub, mat, [(r, 0.0), (rr1, L)], segs=segs, uv_m=uv_m, u_tiles=1)
    if caps:
        disk(sub, mat, r, 0.0, segs=segs, up=False, uv_m=uv_m)
        disk(sub, mat, rr1, L, segs=segs, up=True, uv_m=uv_m)
    m.merge(sub, frame_to(d / L), p0)


def bolt_ring(m, mat, y, r, n, size=0.012, height=0.008, up=True, radial=False, a0=0.0):
    """A ring of hex bolt heads: on a flange face (pointing ±Y) or radial
    (pointing out of a cylinder wall at radius r)."""
    for k in range(n):
        a = a0 + TAU * k / n
        c, s = math.cos(a), math.sin(a)
        if radial:
            p0 = np.array([r * c, y, r * s]); d = np.array([c, 0, s])
        else:
            p0 = np.array([r * c, y, r * s]); d = np.array([0, 1.0 if up else -1.0, 0])
        tube(m, mat, p0 - d * 0.002, p0 + d * height, size, segs=6, caps=True, uv_m=8.0)


def flange(m, mat, y0, y1, r_in, r_out, segs=48, uv_m=2.0, chamfer=0.006):
    """A bevelled ring band from y0 to y1, outer radius r_out."""
    c = min(chamfer, (y1 - y0) / 3)
    lathe(m, mat, [(r_in, y0), (r_out - c, y0), (r_out, y0 + c), (r_out, y1 - c), (r_out - c, y1), (r_in, y1)],
          segs=segs, uv_m=uv_m)


def bell(m, r_throat, r_exit, y_top, y_bot, segs=40, power=0.7, lip=0.012, wall=0.008, inner=True):
    """A rocket nozzle bell: a contoured outer skin ("Bell", v 0 → 1 throat to
    exit), a rolled lip, and the sooty inner wall ("BellIn", same map, tinted)."""
    n = 14
    prof = []
    for k in range(n + 1):
        t = k / n
        r = r_throat + (r_exit - r_throat) * (t ** power)
        prof.append((r, y_top + (y_bot - y_top) * t))
    lathe(m, "Bell", list(reversed(prof)), segs=segs, smooth=True, u_tiles=2, v_norm=(1.0, 0.0))
    # Lip: a small rounded rim.
    lathe(m, "Metal", [(r_exit, y_bot), (r_exit + lip, y_bot + lip * 0.3), (r_exit + lip, y_bot + lip * 1.2), (r_exit, y_bot + lip * 1.8)],
          segs=segs, smooth=True, uv_m=4.0)
    if inner:
        ip = [(r - wall, y) for (r, y) in prof]
        lathe(m, "BellIn", list(reversed(ip)), segs=segs, smooth=True, u_tiles=2, v_norm=(1.0, 0.0), inward=True)
        lathe(m, "BellIn", [(r_exit - wall, y_bot), (r_exit, y_bot)], segs=segs, u_tiles=2, v_norm=(1.0, 1.0))


def atlas_uv(name):
    for (n, x, y, w, h) in MARKINGS:
        if n == name:
            return x / ATLAS, y / ATLAS, w / ATLAS, h / ATLAS
    raise KeyError(name)


def decal(m, mat, name, rfun, theta, yc, width, height=None, off=0.0035, nu=10, vertical=False, slope=None):
    """A curved decal patch lying on a lathed surface r = rfun(y), centred at
    angle `theta` (radians; −π/2 faces −Z) and height yc. width/height in m;
    height defaults to the atlas cell's aspect. Text reads left→right as seen
    from outside; `vertical` turns it 90° (reads top→bottom)."""
    x0, y0, w, h = atlas_uv(name)
    aspect = (h * ATLAS) / (w * ATLAS)
    if vertical:
        if height is None:
            height = width
            width = height * aspect
        else:
            width = height * aspect
    elif height is None:
        height = width * aspect
    rmid = rfun(yc)
    half = width / 2 / rmid
    nv = 3
    P, N, UV, I = [], [], [], []
    for j in range(nv):
        fy = j / (nv - 1)
        yy = yc + height / 2 - height * fy
        r = rfun(yy)
        dr = (rfun(yy + 1e-3) - rfun(yy - 1e-3)) / 2e-3
        nl = math.hypot(1, dr)
        for i in range(nu):
            fx = i / (nu - 1)
            a = theta + half - 2 * half * fx
            c, s = math.cos(a), math.sin(a)
            nr, ny = 1 / nl, -dr / nl
            P.append(((r + off * nr) * c, yy + off * ny, (r + off * nr) * s))
            N.append((nr * c, ny, nr * s))
            if not vertical:
                UV.append((x0 + w * fx, y0 + h * fy))
            else:
                # text top → viewer's right (smaller angle)
                UV.append((x0 + w * fy, y0 + h * (1 - fx)))
    for j in range(nv - 1):
        for i in range(nu - 1):
            a_ = j * nu + i
            I.append((a_, a_ + 1, a_ + nu + 1)); I.append((a_, a_ + nu + 1, a_ + nu))
    m.add(mat, P, N, UV, I)


def flat_decal(m, mat, name, center, right, up, width, height=None, off=0.002):
    """A flat decal quad: `right`/`up` unit vectors span it, normal = right × up."""
    x0, y0, w, h = atlas_uv(name)
    if height is None:
        height = width * h / w
    c = np.asarray(center, float); r = np.asarray(right, float); u = np.asarray(up, float)
    n = np.cross(r, u); n /= np.linalg.norm(n)
    c = c + n * off
    P = [c - r * width / 2 + u * height / 2, c + r * width / 2 + u * height / 2,
         c + r * width / 2 - u * height / 2, c - r * width / 2 - u * height / 2]
    UV = [(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h)]
    m.add(mat, P, [n] * 4, UV, [(0, 1, 2), (0, 2, 3)])


def cyl_r(r):
    return lambda y: r


def cone_r(ra, ya, rb, yb):
    return lambda y: ra + (rb - ra) * (y - ya) / (yb - ya)


# ── parts ────────────────────────────────────────────────────────────────────
# Each returns (Model, prefab-scale). All built at REAL size, centred.

FRONT = -math.pi / 2   # angle facing −Z (the ship's "forward": the pod window)
BACK = math.pi / 2
RIGHT = 0.0            # +X


def tank_body(m, h, r, label, serial):
    y0, y1 = -h / 2, h / 2
    ring = 0.045
    # Skin.
    lathe(m, "Paint", [(r - 0.004, y0 + ring), (r - 0.004, y1 - ring)], segs=48, uv_m=1.0, v0=0.37)
    # Ring frames top and bottom: bevelled bolted bands.
    flange(m, "Metal", y0, y0 + ring, r - 0.03, r, uv_m=2.0)
    flange(m, "Metal", y1 - ring, y1, r - 0.03, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + ring * 0.5, r, 32, size=0.007, height=0.006, radial=True, a0=0.05)
    bolt_ring(m, "Metal", y1 - ring * 0.5, r, 32, size=0.007, height=0.006, radial=True, a0=0.05)
    # Bulkhead domes so the stack never shows daylight through itself.
    for sgn in (-1, 1):
        yb = y0 + 0.004 if sgn < 0 else y1 - 0.004
        prof = [(r - 0.03, yb)] + [((r - 0.03) * math.cos(t), yb - sgn * 0.08 * math.sin(t))
                                   for t in np.linspace(0.15, math.pi / 2, 6)]
        lathe(m, "Metal", prof, segs=32, smooth=True, uv_m=2.0)
    # Weld lands between barrel sections.
    for yw in np.arange(y0 + 0.5, y1 - 0.2, 0.5):
        lathe(m, "Metal", [(r - 0.004, yw - 0.008), (r + 0.001, yw - 0.004), (r + 0.001, yw + 0.004), (r - 0.004, yw + 0.008)], segs=48, uv_m=3.0)
    # Feed line down the +X flank, with stand-off brackets.
    lx = r + 0.035
    tube(m, "Metal", (lx, y0 + ring, 0.06), (lx, y1 - ring, 0.06), 0.022, segs=10, uv_m=3.0)
    tube(m, "Metal", (lx - 0.012, y0 + ring, -0.07), (lx - 0.012, y1 - ring, -0.07), 0.012, segs=8, uv_m=3.0)
    for yb in np.linspace(y0 + 0.12, y1 - 0.12, max(2, int(h / 0.35))):
        box(m, "Metal", (r + 0.02, yb, 0.0), (0.04, 0.025, 0.17), uv_m=4.0)
        box(m, "Metal", (-r - 0.02, yb, 0.0), (0.04, 0.025, 0.12), uv_m=4.0)
    # Cable tray on the −X flank (it also keeps the mesh's box centred).
    tube(m, "Dark", (-lx, y0 + ring, 0.0), (-lx, y1 - ring, 0.0), 0.022, segs=8, uv_m=3.0)
    # Markings: name across the front, roll squares on the back, serials.
    decal(m, "Stencil", label, cyl_r(r - 0.004), FRONT, 0.0 if h < 1.2 else 0.18, 0.46)
    decal(m, "Decal", "flag", cyl_r(r - 0.004), FRONT + 0.75, (0.0 if h < 1.2 else 0.18) + 0.02, 0.16)
    decal(m, "Stencil", "roll", cyl_r(r - 0.004), BACK, -h / 4, 0.26)
    decal(m, "Stencil", serial, cyl_r(r - 0.004), RIGHT + 0.55, y1 - ring - 0.05, 0.14)
    decal(m, "Stencil", "lox", cyl_r(r - 0.004), RIGHT - 0.42, y0 + ring + 0.07, 0.12)


def part_tankS():
    m = Model()
    tank_body(m, 1.0, 0.5, "fts", "serial1")
    return m, (1, 1, 1)


def part_tankM():
    m = Model()
    tank_body(m, 1.5, 0.5, "ftm", "serial2")
    decal(m, "Stencil", "solar", cyl_r(0.496), FRONT, -0.28, 0.38)
    return m, (1, 3, 1)


def part_nose():
    m = Model()
    h, r = 0.9, 0.5
    y0, y1 = -h / 2, h / 2
    # Tangent ogive from the base ring to a blunted tip.
    base = 0.05
    L = h - base - 0.06
    prof = []
    rho = (r ** 2 + L ** 2) / (2 * r)
    for k in range(13):
        t = k / 12
        x = t * L                      # height above the base ring
        rr = math.sqrt(max(rho ** 2 - x ** 2, 0)) + r - rho
        prof.append((max(rr, 0.035), y0 + base + x))
    lathe(m, "Paint", prof[:9], segs=48, smooth=True, uv_m=1.0)
    lathe(m, "Tiles", prof[8:], segs=48, smooth=True, uv_m=2.0)
    # Blunt metal tip + pitot.
    tip_y = prof[-1][1]
    lathe(m, "Metal", [(0.035, tip_y)] + [(0.035 * math.cos(t), tip_y + 0.03 * math.sin(t)) for t in np.linspace(0.3, math.pi / 2, 5)],
          segs=24, smooth=True, uv_m=6.0)
    tube(m, "Metal", (0, tip_y + 0.02, 0), (0, y1, 0), 0.006, segs=6)
    flange(m, "Metal", y0, y0 + base, r - 0.06, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + base * 0.5, r, 28, size=0.007, height=0.006, radial=True)
    # Fairing split line (two halves) as a raised strip + its bolts.
    rf = lambda y: np.interp(y, [p[1] for p in prof], [p[0] for p in prof])
    for a in (0.0, math.pi):
        pts = [(rf(y) + 0.002, y) for y in np.linspace(y0 + base, prof[8][1], 8)]
        for k in range(len(pts) - 1):
            (ra, ya), (rb, yb) = pts[k], pts[k + 1]
            ca, sa = math.cos(a), math.sin(a)
            tube(m, "Metal", (ra * ca, ya, ra * sa), (rb * ca, yb, rb * sa), 0.006, segs=6, caps=False)
    decal(m, "Stencil", "solar", rf, FRONT, y0 + 0.2, 0.36)
    decal(m, "Decal", "hazard", rf, BACK, y0 + 0.085, 0.42, height=0.05)
    return m, (1, 1, 1)


# ── pod ──────────────────────────────────────────────────────────────────────
# A 1 m capsule: ablative heat shield, black tile skirt, white upper cone, a
# real WINDOW (an opening with a bolted frame and a glass pane) facing −Z, a
# hatch on +X, handrails, and a bolted docking/chute collar on top.

POD = dict(h=0.8, rb=0.5, rt=0.24, yb=-0.34, yt=0.28, segs=48,
           win_band=(3, 6), win_seg_half=4)


def pod_profile():
    p = POD
    ys = np.linspace(p["yb"], p["yt"], 9)
    # A slightly convex cone, like a crew capsule's sidewall.
    rs = [p["rb"] + (p["rt"] - p["rb"]) * ((y - p["yb"]) / (p["yt"] - p["yb"])) ** 1.08 for y in ys]
    return list(zip(rs, ys))


def pod_window_skip(seg_lo, seg_hi, band_lo, band_hi):
    def skip(i, k):
        return seg_lo <= i < seg_hi and band_lo <= k < band_hi
    return skip


def pod_window_geom():
    """Window opening in segment/band indices and the corner points."""
    p = POD
    segs = p["segs"]
    # Segment centred on −Z: angle index of −π/2 with a0 = 0 is 3/4 of a turn.
    c = int(round(segs * 0.75))
    lo, hi = c - p["win_seg_half"], c + p["win_seg_half"]
    b0, b1 = p["win_band"]
    return lo, hi, b0, b1


def part_pod():
    m = Model()
    p = POD
    y_bot, y_top = -0.4, 0.4
    prof = pod_profile()
    lo, hi, b0, b1 = pod_window_geom()
    segs = p["segs"]
    # Lower bands black tiles, upper white paint; both share the window hole.
    lathe(m, "Tiles", prof[:4], segs=segs, uv_m=1.0)
    lathe(m, "Paint", prof[3:], segs=segs, uv_m=1.0, skip=lambda i, k: lo <= i < hi and b0 - 3 <= k < b1 - 3)
    # A dark inner liner: what you see through the window from outside (the
    # lit cabin only exists in first person). Same "Dark" material as the
    # collar, so it adds no draw.
    lathe(m, "Dark", [(r - 0.012, y) for (r, y) in prof], segs=segs, uv_m=2.0, inward=True,
          skip=lambda i, k: lo <= i < hi and b0 <= k < b1)
    # Window frame: a bolted tunnel through the hull and a glass pane.
    ang = lambda i: TAU * i / segs
    corners = []
    for (i, k) in ((lo, b0), (hi, b0), (hi, b1), (lo, b1)):
        r, y = prof[k]
        corners.append(np.array([r * math.cos(ang(i)), y, r * math.sin(ang(i))]))
    ctr = sum(corners) / 4
    out_n = np.array([0.0, 0.0, -1.0])
    # Frame: four bars round the opening (outer bezel) and a tunnel inward.
    depth = 0.07
    for a, b in ((0, 1), (1, 2), (2, 3), (3, 0)):
        pa, pb = corners[a], corners[b]
        mid = (pa + pb) / 2
        L = np.linalg.norm(pb - pa)
        d = (pb - pa) / L
        inw = (ctr - mid); inw -= d * (inw @ d); inw /= np.linalg.norm(inw)
        # bezel strip (on the skin, 3 cm wide, raised 1 cm)
        nrm = np.cross(d, inw)
        if nrm @ out_n < 0:
            nrm = -nrm
        M = np.stack([d, nrm, -inw], 1)  # local x along edge, y out, z outward from hole
        box(m, "Metal", mid + nrm * 0.005 - inw * 0.012, (L + 0.024, 0.012, 0.024), M, uv_m=6.0)
        # tunnel wall
        Pt = [pa, pb, pb - out_n * depth, pa - out_n * depth]
        nn = inw
        m.add("Metal", Pt, [nn] * 4, [(0, 0), (L * 4, 0), (L * 4, depth * 4), (0, depth * 4)], [(0, 1, 2), (0, 2, 3)])
        # bolts along the bezel
        nb = max(2, int(L / 0.05))
        for t in np.linspace(0.12, 0.88, nb):
            q = pa + (pb - pa) * t + nrm * 0.011 - inw * 0.012
            tube(m, "Metal", q - nrm * 0.004, q + nrm * 0.006, 0.0045, segs=6, uv_m=8.0)
    # The pane, set back into the tunnel.
    gl = [c - out_n * 0.02 for c in corners]
    m.add("Glass", gl, [out_n] * 4, [(0, 0), (1, 0), (1, 1), (0, 1)], [(0, 1, 2), (0, 2, 3)])
    # Heat shield: shallow ablative dome under a bolted metal rim.
    hs = [(0.0, y_bot)] + [(0.5 * math.sin(t), y_bot + 0.05 * (1 - math.cos(t))) for t in np.linspace(0.15, math.pi / 2, 7)]
    lathe(m, "Ablative", hs, segs=segs, smooth=True, uv_m=1.5)
    flange(m, "Metal", y_bot + 0.045, p["yb"] + 0.012, 0.44, 0.5, uv_m=2.0)
    bolt_ring(m, "Metal", p["yb"] + 0.0, 0.47, 36, size=0.006, height=0.006, up=True)
    # Top collar: shoulder ring, bolted collar, hatch rim.
    lathe(m, "Metal", [(p["rt"], p["yt"]), (p["rt"] - 0.012, p["yt"] + 0.008), (0.205, p["yt"] + 0.012)], segs=segs, uv_m=3.0)
    flange(m, "Metal", p["yt"] + 0.01, y_top - 0.03, 0.17, 0.205, uv_m=3.0)
    lathe(m, "Dark", [(0.205, y_top - 0.03), (0.2, y_top - 0.015), (0.16, y_top - 0.015)], segs=segs, uv_m=3.0)
    disk(m, "Metal", 0.16, y_top - 0.02, segs=32, uv_m=3.0)
    bolt_ring(m, "Metal", y_top - 0.03, 0.19, 16, size=0.006, height=0.005, up=True)
    lathe(m, "Dark", [(0.12, y_top - 0.02), (0.12, y_top), (0.08, y_top), (0.08, y_top - 0.02)], segs=24, uv_m=4.0)
    # Hatch on +X: an outlined decal, a handle, two handrails.
    rf = lambda y: np.interp(y, [q[1] for q in prof], [q[0] for q in prof])
    decal(m, "Stencil", "hatch", rf, RIGHT, -0.02, 0.26)
    decal(m, "Stencil", "rescue", rf, RIGHT, -0.19, 0.24)
    for side in (-1, 1):
        a = RIGHT + side * 0.42
        pts = []
        for y in (-0.12, 0.1):
            r = rf(y) + 0.03
            pts.append((r * math.cos(a), y, r * math.sin(a)))
        tube(m, "Paint2", pts[0], pts[1], 0.008, segs=8, uv_m=4.0)
        for (x, y, z) in pts:
            r0 = rf(y)
            tube(m, "Paint2", (r0 * math.cos(a), y, r0 * math.sin(a)), (x, y, z), 0.006, segs=6)
    # RCS doghouses on ±Z/±X diagonals, low on the skirt.
    for a in (math.pi / 4, 3 * math.pi / 4, 5 * math.pi / 4, 7 * math.pi / 4):
        y = -0.24
        r = rf(y)
        c, s = math.cos(a), math.sin(a)
        M = rot_y(-a)
        box(m, "Dark", (r * c, y, r * s), (0.05, 0.07, 0.07), M, uv_m=8.0)
        tube(m, "Metal", ((r + 0.02) * c, y + 0.012, (r + 0.02) * s), ((r + 0.045) * c, y + 0.012, (r + 0.045) * s), 0.008, segs=6, r1=0.013)
    # Markings.
    decal(m, "Stencil", "pod", rf, BACK, 0.02, 0.3)
    decal(m, "Decal", "flag", rf, FRONT + 0.85, 0.02, 0.13)
    decal(m, "Stencil", "serial1", rf, FRONT - 0.85, 0.04, 0.12)
    return m, (1, 1, 1)


def part_pod_interior():
    """The cabin: an inward-facing liner with the window opening, a reclined
    seat, an instrument console under the window, the commander's legs and
    gloved hands on the controllers. Lives in a child node that is only
    enabled in first person."""
    m = Model()
    p = POD
    prof = pod_profile()
    lo, hi, b0, b1 = pod_window_geom()
    segs = p["segs"]
    inset = 0.045
    liner = [(r - inset, y) for (r, y) in prof]
    # Liner UVs map into the atlas's wall quadrant (u, v ∈ [0, 0.5]).
    wx, wy, ww, wh = [c / 1024 for c in INTERIOR["wall"]]
    sub = Model()
    # The liner is laid in three panels round the cabin, each its own strip
    # of the wall quadrant: UVs are squeezed into the quadrant LINEARLY, never
    # wrapped per vertex (a triangle whose corners wrapped from 0.98 to 0.02
    # smeared the whole quadrant across one cell — the glitchy streaks in the
    # cabin).
    for third in range(3):
        a0, a1 = TAU * third / 3, TAU * (third + 1) / 3
        n3 = segs // 3
        part = Model()
        lathe(part, "Cabin", liner, segs=n3, uv_m=1.0, u_tiles=1, a0=a0, a1=a1, inward=True,
              skip=lambda i, k, t=third: lo <= i + t * n3 < hi and b0 <= k < b1)
        for mat, (Ps, Ns, UVs, Is, _) in part.parts.items():
            for UV in UVs:
                vv = -UV[:, 1] * 1.6
                vv = (vv - vv.min()) / max(vv.max() - vv.min(), 1e-6)
                UV[:, 0] = wx + np.clip(UV[:, 0], 0, 1) * ww * 0.995 + ww * 0.0025
                UV[:, 1] = wy + vv * wh * 0.995 + wh * 0.0025
        sub.merge(part)
    m.merge(sub)
    # Floor (over the heat shield) and ceiling with the hatch tunnel.
    disk(m, "Dark", liner[0][0], liner[0][1], segs=segs, up=True, uv_m=3.0)
    disk(m, "Cabin", liner[-1][0], liner[-1][1], segs=segs, up=False, uv_m=0.4)
    # Window tunnel continuation (liner → hull) so there's no gap.
    ang = lambda i: TAU * i / segs
    cin, cout = [], []
    for (i, k) in ((lo, b0), (hi, b0), (hi, b1), (lo, b1)):
        r, y = prof[k]
        cout.append(np.array([r * math.cos(ang(i)), y, r * math.sin(ang(i))]))
        cin.append(np.array([(r - inset) * math.cos(ang(i)), y, (r - inset) * math.sin(ang(i))]))
    ctr = sum(cin) / 4
    for a, b in ((0, 1), (1, 2), (2, 3), (3, 0)):
        Pq = [cin[a], cin[b], cout[b], cout[a]]
        mid = (cin[a] + cin[b]) / 2
        nn = ctr - mid; nn[2] = 0 if abs(nn[2]) < 1e-6 else nn[2]
        nn = nn / np.linalg.norm(nn)
        m.add("Metal", Pq, [nn] * 4, [(0, 0), (2, 0), (2, 0.2), (0, 0.2)], [(0, 1, 2), (0, 2, 3)])
        # inner window trim
        d = cin[b] - cin[a]; L = np.linalg.norm(d); d /= L
        M = np.stack([d, np.array([0, 0, 1.0]) if abs(d[1]) < 0.9 else np.array([0, 0, 1.0]), np.cross(d, [0, 0, 1.0])], 1)
        tube(m, "Metal", cin[a] + (cin[a] - ctr) * 0.08, cin[b] + (cin[b] - ctr) * 0.08, 0.008, segs=6)
    # Console: an angled panel under the window, with screens set into it.
    cx, cy, cz = 0.0, -0.215, -0.235
    tilt = rot_x(-0.75)
    cxr, cyr, cw, chh = [c / 1024 for c in INTERIOR["console"]]
    P = []
    W, H = 0.36, 0.2
    for (sx, sy) in ((-1, 1), (1, 1), (1, -1), (-1, -1)):
        P.append(tilt @ np.array([sx * W / 2, sy * H / 2, 0.0]) + np.array([cx, cy, cz]))
    n = tilt @ np.array([0, 0, 1.0])
    m.add("Cabin", P, [n] * 4, [(cxr, cyr), (cxr + cw, cyr), (cxr + cw, cyr + chh), (cxr, cyr + chh)], [(0, 1, 2), (0, 2, 3)])
    # Console body (a wedge box behind the fascia).
    box(m, "Dark", (cx, cy - 0.02, cz - 0.05), (W + 0.02, 0.2, 0.1), tilt, uv_m=4.0)
    # Screens (unlit material) on the lower half of the fascia.
    sx0, sy0, sw, sh = [c / 1024 for c in INTERIOR["screens"]]
    P = []
    SW, SH = 0.3, 0.15
    for (ax, ay) in ((-1, 1), (1, 1), (1, -1), (-1, -1)):
        P.append(tilt @ np.array([ax * SW / 2, ay * SH / 2 - 0.0, 0.004]) + np.array([cx, cy + 0.0, cz]) + tilt @ np.array([0, -0.025, 0]))
    m.add("Screen", P, [n] * 4, [(sx0, sy0), (sx0 + sw, sy0), (sx0 + sw, sy0 + sh * 0.8), (sx0, sy0 + sh * 0.8)], [(0, 1, 2), (0, 2, 3)])
    # Seat: a reclined couch behind the eye point.
    # Eye point: (0, 0.0, 0.06) — SEAT_EYE in planet_camera.lua.
    sx_, sy_, sw_, sh_ = [c / 1024 for c in INTERIOR["seat"]]
    seatM = rot_x(0.35)
    def seat_box(center, size, M):
        sub = Model()
        box(sub, "Cabin", (0, 0, 0), size, None, uv_m=1.0)
        for mat, (Ps, Ns, UVs, Is, _) in sub.parts.items():
            for UV in UVs:
                # box UVs are centred on 0 (negative half the face): shift,
                # never wrap
                UV[:, 0] = sx_ + np.clip(UV[:, 0] * 1.4 + 0.5, 0, 1) * sw_ * 0.995
                UV[:, 1] = sy_ + np.clip(UV[:, 1] * 1.4 + 0.5, 0, 1) * sh_ * 0.995
        m.merge(sub, M, center)
    seat_box((0.0, -0.02, 0.2), (0.24, 0.32, 0.05), seatM)   # back rest
    seat_box((0.0, 0.17, 0.25), (0.14, 0.08, 0.05), seatM)   # head rest
    seat_box((0.0, -0.17, 0.12), (0.24, 0.05, 0.16), rot_x(-0.15))  # seat pan
    tube(m, "Metal", (-0.13, -0.3, 0.2), (-0.13, -0.12, 0.2), 0.012, segs=8)
    tube(m, "Metal", (0.13, -0.3, 0.2), (0.13, -0.12, 0.2), 0.012, segs=8)
    # The commander: thighs, shins and boots in suit fabric; gloved hands on
    # the two controllers either side of the console.
    ux, uy, uw, uh = [c / 1024 for c in INTERIOR["suit"]]
    def suit_tube(a, b, r):
        sub = Model()
        tube(sub, "Cabin", a, b, r, segs=12, uv_m=1.0)
        for mat, (Ps, Ns, UVs, Is, _) in sub.parts.items():
            for UV in UVs:
                vv = np.abs(UV[:, 1]) * 2.0
                UV[:, 0] = ux + np.clip(UV[:, 0], 0, 1) * uw * 0.995
                UV[:, 1] = uy + np.clip(vv, 0, 0.7) * uh * 0.995
        m.merge(sub)
    for side in (-1, 1):
        hip = np.array([side * 0.05, -0.2, 0.06])
        knee = np.array([side * 0.06, -0.18, -0.12])
        ankle = np.array([side * 0.055, -0.29, -0.19])
        suit_tube(hip, knee, 0.03)
        suit_tube(knee, ankle, 0.025)
        box(m, "Dark", ankle + np.array([0, -0.015, -0.025]), (0.045, 0.04, 0.08), None, uv_m=6.0)
        # forearm + glove on a hand controller
        elbow = np.array([side * 0.17, -0.19, 0.06])
        wrist = np.array([side * 0.17, -0.17, -0.07])
        suit_tube(elbow, wrist, 0.02)
        box(m, "Dark", wrist + np.array([0, 0.0, -0.018]), (0.034, 0.028, 0.04), rot_x(0.3), uv_m=6.0)
        tube(m, "Metal", wrist + np.array([0, -0.08, -0.02]), wrist + np.array([0, -0.02, -0.02]), 0.009, segs=8)
        box(m, "Dark", wrist + np.array([0, -0.1, -0.02]), (0.06, 0.03, 0.06), None, uv_m=6.0)
    # Overhead panel strip and a few stowage boxes.
    box(m, "Dark", (0.0, 0.2, -0.12), (0.16, 0.02, 0.1), rot_x(0.6), uv_m=6.0)
    box(m, "Paint2", (-0.25, -0.2, 0.14), (0.09, 0.09, 0.12), rot_y(0.5), uv_m=3.0)
    box(m, "Paint2", (0.25, -0.2, 0.14), (0.09, 0.09, 0.12), rot_y(-0.5), uv_m=3.0)
    return m


# ── engines ──────────────────────────────────────────────────────────────────

def thrust_top(m, y_top, r, plate=0.06, foil_to=None, r_low=0.3):
    """Bolted interface plate + gold-foil thrust structure below it."""
    flange(m, "Metal", y_top - plate, y_top, 0.0, r, uv_m=2.0)
    bolt_ring(m, "Metal", y_top - plate * 0.5, r, 32, size=0.007, height=0.006, radial=True)
    if foil_to is not None:
        lathe(m, "Foil", [(r - 0.02, y_top - plate), (r_low, foil_to)], segs=40, uv_m=1.5)
        disk(m, "Foil", r_low, foil_to, segs=40, up=False, uv_m=1.5)


def chamber(m, y_top, y_throat, r_ch, r_th):
    """Injector dome, combustion chamber and the converging section."""
    lathe(m, "Metal", [(0.02, y_top + 0.03), (r_ch * 0.7, y_top + 0.02), (r_ch, y_top - 0.01),
                       (r_ch, y_throat + (y_top - y_throat) * 0.35), (r_th, y_throat)], segs=32, smooth=False, uv_m=3.0)
    # Cooling-jacket bands.
    for t in (0.25, 0.55):
        y = y_top - (y_top - y_throat) * t * 0.6
        lathe(m, "Dark", [(r_ch, y - 0.008), (r_ch + 0.008, y - 0.004), (r_ch + 0.008, y + 0.004), (r_ch, y + 0.008)], segs=32, uv_m=6.0)


def gimbal_struts(m, y_top, y_bot, r_top, r_bot, n=4, a0=0.4):
    for k in range(n):
        a = a0 + TAU * k / n
        c, s = math.cos(a), math.sin(a)
        p0 = (r_top * c, y_top, r_top * s)
        p1 = (r_bot * c, y_bot, r_bot * s)
        tube(m, "Metal", p0, p1, 0.012, segs=8)


def actuator(m, p0, p1, r=0.016):
    """Hydraulic gimbal actuator: barrel + polished rod + end eyes."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    mid = p0 + (p1 - p0) * 0.55
    tube(m, "Dark", p0, mid, r, segs=10)
    tube(m, "Chrome", mid, p1, r * 0.55, segs=8)


def turbopump(m, x, z, y0, y1, r=0.05):
    tube(m, "Metal", (x, y0, z), (x, y1, z), r, segs=14, uv_m=3.0)
    tube(m, "Dark", (x, y1 - 0.02, z), (x, y1 + 0.01, z), r + 0.01, segs=14)
    tube(m, "Dark", (x, y0 - 0.01, z), (x, y0 + 0.02, z), r + 0.008, segs=14)


def part_engineS():
    m = Model()
    h = 1.3
    y1, y0 = h / 2, -h / 2
    thrust_top(m, y1, 0.5, plate=0.07, foil_to=y1 - 0.3, r_low=0.24)
    chamber(m, y1 - 0.3, y1 - 0.55, 0.12, 0.07)
    bell(m, 0.07, 0.4, y1 - 0.55, y0 + 0.002, segs=40)
    gimbal_struts(m, y1 - 0.07, y1 - 0.32, 0.38, 0.14)
    actuator(m, (0.3, y1 - 0.08, 0.1), (0.12, y1 - 0.48, 0.06))
    actuator(m, (-0.1, y1 - 0.08, -0.3), (-0.06, y1 - 0.48, -0.12))
    turbopump(m, 0.17, -0.12, y1 - 0.42, y1 - 0.26, 0.045)
    tube(m, "Metal", (0.17, y1 - 0.42, -0.12), (0.07, y1 - 0.5, -0.04), 0.014, segs=8)
    # Exhaust duct of the gas generator, alongside the bell.
    tube(m, "Dark", (0.2, y1 - 0.42, -0.12), (0.26, y1 - 0.75, -0.16), 0.022, segs=10)
    # Four stabiliser fins on the skirt (they are the 2.7 m stance the flight
    # model gives this engine — see the prefab's collider note).
    # They root on a short painted aft skirt, open below so the engine shows.
    ys0, ys1 = y1 - 0.36, y1 - 0.07
    lathe(m, "Paint", [(0.47, ys0), (0.5, ys0 + 0.06), (0.5, ys1)], segs=48, uv_m=1.0)
    lathe(m, "Dark", [(0.455, ys0), (0.485, ys1)], segs=48, uv_m=2.0, inward=True)
    lathe(m, "Metal", [(0.455, ys0), (0.47, ys0)], segs=48, uv_m=4.0)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        fin_shape(m, a, root_r=0.49, y_root_top=ys1 - 0.01, y_root_bot=ys0 + 0.04, span=0.36, sweep=0.18, tip_len=0.36)
    rf = cyl_r(0.5)
    decal(m, "Stencil", "sputter", rf, FRONT, y1 - 0.2, 0.3)
    decal(m, "Decal", "flag", rf, FRONT + 0.6, y1 - 0.2, 0.11)
    return m, (1, 1, 1)


def fin_shape(m, a, root_r, y_root_top, y_root_bot, span, sweep, tip_len, thick=0.022, mat="Paint"):
    """A swept, thin fin standing out of a body at angle a (radial)."""
    c, s = math.cos(a), math.sin(a)
    out = np.array([c, 0, s]); side = np.array([-s, 0, c]); up = np.array([0, 1.0, 0])
    root_len = y_root_top - y_root_bot
    pts2 = [(0.0, y_root_top), (span, y_root_top - sweep), (span, y_root_top - sweep - tip_len), (0.0, y_root_bot)]
    P, N, UV, I = [], [], [], []
    for sgn in (1, -1):
        base = len(P)
        for (x, y) in pts2:
            taper = 1 - 0.6 * (x / span)
            p = out * (root_r + x) + up * y + side * sgn * thick / 2 * taper
            P.append(p); N.append(side * sgn); UV.append((x * 1.0, -y * 1.0))
        I += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    m.add(mat, P, N, UV, I)
    # edges: leading (dark heat strip), tip, trailing
    edges = [(0, 1, "Tiles"), (1, 2, "Metal"), (2, 3, "Metal")]
    for (i, j, emat) in edges:
        (xa, ya), (xb, yb) = pts2[i], pts2[j]
        ta, tb = 1 - 0.6 * xa / span, 1 - 0.6 * xb / span
        A = [out * (root_r + xa) + up * ya + side * thick / 2 * ta, out * (root_r + xb) + up * yb + side * thick / 2 * tb,
             out * (root_r + xb) + up * yb - side * thick / 2 * tb, out * (root_r + xa) + up * ya - side * thick / 2 * ta]
        e = np.array([xb - xa, yb - ya]); en = np.array([e[1], -e[0]]); en /= np.linalg.norm(en)
        nn = out * en[0] + up * en[1]
        if (nn @ (out * ((xa + xb) / 2 - span / 3) + up * ((ya + yb) / 2 - (y_root_top + y_root_bot) / 2))) < 0:
            nn = -nn
        L = math.hypot(*e)
        m.add(emat, A, [nn] * 4, [(0, 0), (L * 2, 0), (L * 2, 0.05), (0, 0.05)], [(0, 1, 2), (0, 2, 3)])
    # root fillet strip
    box(m, "Metal", out * (root_r + 0.01) + up * (y_root_top + y_root_bot) / 2, (0.03, root_len, thick * 2.2), rot_y(-a), uv_m=4.0)


def part_engineM():
    m = Model()
    h = 1.6
    y1, y0 = h / 2, -h / 2
    thrust_top(m, y1, 0.5, plate=0.08, foil_to=y1 - 0.36, r_low=0.28)
    chamber(m, y1 - 0.36, y1 - 0.66, 0.15, 0.085)
    bell(m, 0.085, 0.48, y1 - 0.66, y0 + 0.002, segs=48)
    gimbal_struts(m, y1 - 0.08, y1 - 0.38, 0.42, 0.17, n=6)
    for k in range(2):
        a = 0.3 + k * math.pi / 2
        c, s = math.cos(a), math.sin(a)
        actuator(m, (0.36 * c, y1 - 0.09, 0.36 * s), (0.16 * c, y1 - 0.6, 0.16 * s), r=0.02)
    turbopump(m, 0.22, -0.1, y1 - 0.5, y1 - 0.3, 0.06)
    turbopump(m, -0.2, 0.14, y1 - 0.5, y1 - 0.32, 0.05)
    tube(m, "Metal", (0.22, y1 - 0.5, -0.1), (0.09, y1 - 0.6, -0.04), 0.018, segs=8)
    tube(m, "Metal", (-0.2, y1 - 0.5, 0.14), (-0.08, y1 - 0.6, 0.06), 0.016, segs=8)
    tube(m, "Dark", (0.26, y1 - 0.52, -0.1), (0.34, y1 - 0.95, -0.12), 0.026, segs=10)
    # Fuel/ox manifolds round the chamber head.
    lathe(m, "Metal", [(0.17, y1 - 0.39), (0.19, y1 - 0.385), (0.19, y1 - 0.365), (0.17, y1 - 0.36)], segs=32, uv_m=6.0)
    decal(m, "Stencil", "anvil", cyl_r(0.5), FRONT, y1 - 0.04, 0.22, height=0.05)
    decal(m, "Decal", "hazard", cyl_r(0.5), BACK, y1 - 0.04, 0.3, height=0.05)
    return m, (1, 1, 1)


def part_skipper():
    """Heavy engine: three chambers under a gunmetal boat-tail."""
    m = Model()
    h = 1.6
    y1, y0 = h / 2, -h / 2
    flange(m, "Metal", y1 - 0.07, y1, 0.0, 0.5, uv_m=2.0)
    bolt_ring(m, "Metal", y1 - 0.035, 0.5, 32, size=0.007, height=0.006, radial=True)
    # Boat-tail skirt (paint, dark tint) down to the engine plate.
    yb = y1 - 0.42
    lathe(m, "Paint3", [(0.5, y1 - 0.07), (0.47, yb + 0.05), (0.44, yb)], segs=48, uv_m=1.0)
    disk(m, "Foil", 0.44, yb, segs=48, up=False, uv_m=1.5)
    for k in range(3):
        a = math.pi / 2 + k * TAU / 3
        cx, cz = 0.2 * math.cos(a), 0.2 * math.sin(a)
        sub = Model()
        chamber(sub, yb, yb - 0.2, 0.08, 0.05)
        bell(sub, 0.05, 0.2, yb - 0.2, y0 + 0.002, segs=32)
        m.merge(sub, None, (cx, 0, cz))
        actuator(m, (cx * 1.9, yb, cz * 1.9), (cx * 1.05, yb - 0.32, cz * 1.05), r=0.014)
    tube(m, "Dark", (0, yb, 0), (0, yb - 0.25, 0), 0.06, segs=14)
    for k in range(6):  # skirt stringers
        a = TAU * k / 6 + 0.26
        c, s = math.cos(a), math.sin(a)
        tube(m, "Metal", (0.495 * c, y1 - 0.08, 0.495 * s), (0.445 * c, yb + 0.01, 0.445 * s), 0.008, segs=6)
    decal(m, "Decal", "skipper", cone_r(0.5, y1 - 0.07, 0.44, yb), FRONT, y1 - 0.2, 0.32)
    decal(m, "Decal", "hazard", cone_r(0.5, y1 - 0.07, 0.44, yb), BACK, y1 - 0.15, 0.36, height=0.05)
    return m, (1, 1, 1)


# ── structure and utilities ─────────────────────────────────────────────────

def part_decoupler():
    m = Model()
    h, r = 0.25, 0.51
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.06, 0.0, r, uv_m=2.0)
    flange(m, "Metal", y1 - 0.06, y1, 0.0, r, uv_m=2.0)
    lathe(m, "Paint3", [(r - 0.02, y0 + 0.06), (r - 0.02, -0.012)], segs=48, uv_m=1.0)
    lathe(m, "Paint3", [(r - 0.02, 0.012), (r - 0.02, y1 - 0.06)], segs=48, uv_m=1.0)
    # The separation groove and its frangible-bolt ring.
    lathe(m, "Dark", [(r - 0.02, -0.012), (r - 0.035, -0.006), (r - 0.035, 0.006), (r - 0.02, 0.012)], segs=48, uv_m=3.0)
    bolt_ring(m, "Metal", 0.0, r - 0.03, 24, size=0.009, height=0.012, radial=True)
    bolt_ring(m, "Metal", y0 + 0.03, r, 32, size=0.006, height=0.005, radial=True)
    bolt_ring(m, "Metal", y1 - 0.03, r, 32, size=0.006, height=0.005, radial=True)
    rf = cyl_r(r - 0.02)
    for a in (FRONT, BACK):
        decal(m, "Decal", "hazard", rf, a, (y0 + 0.06 - 0.012) / 2 - 0.006, 0.42, height=0.035)
    decal(m, "Stencil", "pyro", rf, RIGHT, 0.042, 0.3, height=0.035)
    decal(m, "Stencil", "deco", rf, math.pi, 0.042, 0.3, height=0.035)
    return m, (1.02, 0.5, 1.02)


# ── parachute ────────────────────────────────────────────────────────────────
# The packed-chute canister that sits on the pod's docking/chute collar (Ø0.41
# at the pod's top), so it is the same width: a white drum with an orange
# mortar cap. The cap is held on by four retaining straps with buckles across
# the split line; a bolted adapter ring underneath, a pull loop and vent on
# top, pyro and hazard markings. Real size, 0.44 m across, 0.34 m tall.

CHUTE = dict(h=0.34, r=0.215)


def part_chute():
    m = Model()
    p = CHUTE
    h, r = p["h"], p["r"]
    y0, y1 = -h / 2, h / 2
    seg = 40
    # Adapter ring: the bolted foot that mates with the pod's collar.
    ya = y0 + 0.03
    flange(m, "Metal", y0, ya, 0.12, r + 0.008, segs=seg, uv_m=3.0, chamfer=0.006)
    bolt_ring(m, "Metal", y0 + 0.015, r + 0.008, 20, size=0.0055, height=0.005, radial=True)
    # The drum: white paint, with a rolled bead just above the foot.
    ys = 0.045                      # split line between drum and cap
    lathe(m, "Paint", [(r - 0.004, ya), (r, ya + 0.006), (r, ys - 0.004)], segs=seg, uv_m=1.0)
    lathe(m, "Metal", [(r, ya + 0.022), (r + 0.006, ya + 0.026), (r + 0.006, ya + 0.034), (r, ya + 0.038)],
          segs=seg, smooth=True, uv_m=4.0)
    # The split line: a dark recessed gap.
    lathe(m, "Dark", [(r, ys - 0.004), (r - 0.006, ys - 0.002), (r - 0.006, ys + 0.002), (r, ys + 0.004)],
          segs=seg, uv_m=4.0)
    # The cap: a short lip, a rounded shoulder and a shallow cone to the top.
    cap = [(r, ys + 0.004), (r, ys + 0.03)]
    for t in np.linspace(0.0, 1.0, 6)[1:]:
        a = t * math.pi / 2 * 0.62
        cap.append((r - 0.04 * (1 - math.cos(a)) / (1 - math.cos(math.pi / 2 * 0.62)) * 1.0,
                    ys + 0.03 + 0.045 * math.sin(a) / math.sin(math.pi / 2 * 0.62)))
    rc, yc = cap[-1]
    rtop = 0.085
    ytop = y1 - 0.012
    cap.append((rtop, ytop))
    lathe(m, "PaintOrange", cap, segs=seg, uv_m=1.0, smooth=False)
    disk(m, "PaintOrange", rtop, ytop, segs=seg, uv_m=1.0, r_in=0.05)
    # Top: a machined boss with the mortar vent, and a folded pull loop.
    flange(m, "Metal", ytop - 0.002, ytop + 0.008, 0.0, 0.05, segs=24, uv_m=6.0, chamfer=0.003)
    lathe(m, "Dark", [(0.022, ytop + 0.0081), (0.016, ytop + 0.0081)], segs=16, uv_m=8.0)
    bolt_ring(m, "Metal", ytop + 0.008, 0.038, 6, size=0.005, height=0.003, up=True)
    loop = [(-0.03, ytop + 0.008), (-0.03, y1 - 0.002), (0.03, y1 - 0.002), (0.03, ytop + 0.008)]
    for (xa, ya_), (xb, yb) in zip(loop, loop[1:]):
        tube(m, "Paint3", (xa, ya_, 0.0), (xb, yb, 0.0), 0.004, segs=6, uv_m=8.0)
    # Rivets round the cap's lip.
    bolt_ring(m, "Metal", ys + 0.017, r, 24, size=0.004, height=0.003, radial=True, a0=0.13)
    # Four retaining straps over the split line and up over the cap's
    # shoulder (following its profile), each with a buckle and an end clip.
    rf_drum = cyl_r(r)
    path = [(r, ya + 0.04)] + [(rr, yy) for (rr, yy) in cap[1:-1]] + [(rc - 0.03, yc + 0.02)]
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        c, s = math.cos(a), math.sin(a)
        for (ra, ya_), (rb, yb) in zip(path, path[1:]):
            dr, dy = rb - ra, yb - ya_
            L = math.hypot(dr, dy)
            nr, ny = dy / L, -dr / L                 # outward normal in (r, y)
            rm, ym = (ra + rb) / 2 + nr * 0.003, (ya_ + yb) / 2 + ny * 0.003
            tilt = math.atan2(dr, dy)                # lean of the segment from vertical
            M = rot_y(-a) @ rot_z(-tilt)
            box(m, "Paint3", (rm * c, ym, rm * s), (0.006, L + 0.004, 0.026), M, uv_m=6.0)
        box(m, "Metal", ((r + 0.008) * c, ys - 0.012, (r + 0.008) * s), (0.008, 0.03, 0.034), rot_y(-a), uv_m=8.0, bevel=0.002)
        re, ye = path[-1]
        box(m, "Metal", ((re + 0.002) * c, ye + 0.004, (re + 0.002) * s), (0.012, 0.016, 0.03),
            rot_y(-a) @ rot_z(-0.9), uv_m=8.0, bevel=0.002)
    # Markings: pyro warning and lot number on the drum, hazard flash on the cap lip.
    decal(m, "Stencil", "pyro", rf_drum, FRONT, (ya + 0.04 + ys) / 2 - 0.004, 0.24, height=0.03)
    decal(m, "Stencil", "serial2", rf_drum, BACK, (ya + 0.04 + ys) / 2 - 0.004, 0.13)
    decal(m, "Decal", "hazard2", cyl_r(r), RIGHT, ys + 0.017, 0.12, height=0.02)
    decal(m, "Decal", "hazard2", cyl_r(r), RIGHT + math.pi, ys + 0.017, 0.12, height=0.02)
    return m, (1, 1, 1)


def part_dockport():
    m = Model()
    h, r = 0.28, 0.53
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.05, 0.0, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + 0.05, r - 0.03, 24, size=0.007, height=0.006, up=True)
    # Collar body and the androgynous capture ring.
    lathe(m, "Paint", [(0.4, y0 + 0.05), (0.38, y0 + 0.14), (0.36, y1 - 0.05)], segs=48, uv_m=1.0)
    flange(m, "Metal", y1 - 0.05, y1 - 0.02, 0.24, 0.37, uv_m=3.0)
    lathe(m, "Dark", [(0.37, y1 - 0.02), (0.355, y1), (0.27, y1), (0.25, y1 - 0.02)], segs=48, uv_m=4.0)
    disk(m, "Metal", 0.25, y1 - 0.03, segs=32, uv_m=3.0)
    # Three guide petals and latch hooks.
    for k in range(3):
        a = TAU * k / 3 + 0.3
        c, s = math.cos(a), math.sin(a)
        M = rot_y(-a) @ rot_z(-0.35)
        box(m, "Metal", (0.31 * c, y1 - 0.045, 0.31 * s), (0.02, 0.07, 0.12), M, uv_m=6.0)
        box(m, "Dark", (0.37 * c, y1 - 0.06, 0.37 * s), (0.03, 0.035, 0.04), rot_y(-a - 1.0), uv_m=6.0)
    decal(m, "Stencil", "dock", cone_r(0.4, y0 + 0.05, 0.36, y1 - 0.05), FRONT, 0.0, 0.16, height=0.045)
    return m, (1.06, 0.34, 1.06)


def part_rcs():
    """RCS quad: housing on a mount pad, five nozzles (±Y, ±Z, +X)."""
    m = Model()
    # Real size ~0.4 (x) × 0.34 (y) × 0.34 (z); the hull is at −X.
    box(m, "Metal", (-0.17, 0, 0), (0.04, 0.2, 0.2), uv_m=4.0)
    box(m, "Paint", (-0.06, 0, 0), (0.18, 0.15, 0.15), uv_m=2.0)
    tube(m, "Dark", (0.03, 0, 0), (0.1, 0, 0), 0.02, segs=10)
    for (d, nm) in (((0, 1, 0), "y"), ((0, -1, 0), "y"), ((0, 0, 1), "z"), ((0, 0, -1), "z"), ((1, 0, 0), "x")):
        d = np.array(d, float)
        base = np.array([-0.06, 0, 0]) + d * (0.075 if nm != "x" else 0.155)
        tube(m, "Dark", base - d * 0.005, base + d * 0.03, 0.022, segs=10)
        sub = Model()
        bell(sub, 0.01, 0.03, 0.06, 0.0, segs=12, power=0.7, lip=0.004, wall=0.003)
        # bell is built pointing down (−Y) from y=0.06 to 0: map −Y onto d
        M = frame_to(-d)
        m.merge(sub, M, base + d * 0.09)
    flat_decal(m, "Stencil", "rcs", (-0.06, 0.0, 0.0755), (1, 0, 0), (0, 1, 0), 0.1)
    return m, (0.3, 0.3, 0.3)


def part_battery():
    m = Model()
    h, r = 1.0, 0.5
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.05, 0.0, r, uv_m=2.0)
    flange(m, "Metal", y1 - 0.05, y1, 0.0, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + 0.025, r, 32, size=0.007, height=0.006, radial=True)
    bolt_ring(m, "Metal", y1 - 0.025, r, 32, size=0.007, height=0.006, radial=True)
    lathe(m, "Foil", [(0.36, y0 + 0.05), (0.36, y1 - 0.05)], segs=40, uv_m=1.5)
    # Six battery boxes on a truss, with cable runs.
    for k in range(6):
        a = TAU * k / 6 + 0.3
        c, s = math.cos(a), math.sin(a)
        M = rot_y(-a)
        for yy in (-0.2, 0.18):
            box(m, "Paint2", (0.42 * c, yy, 0.42 * s), (0.11, 0.3, 0.2), M, uv_m=1.5)
            box(m, "Dark", (0.48 * c, yy + 0.1, 0.48 * s), (0.012, 0.04, 0.12), M, uv_m=6.0)
            flat_decal(m, "Decal", "hazard", (0.4755 * c, yy - 0.1, 0.4755 * s), (-s, 0, c), (0, 1, 0), 0.16, 0.03)
        tube(m, "Dark", (0.38 * math.cos(a + 0.5), y0 + 0.06, 0.38 * math.sin(a + 0.5)),
             (0.38 * math.cos(a + 0.5), y1 - 0.06, 0.38 * math.sin(a + 0.5)), 0.012, segs=6)
    a = TAU * 1 / 6 + 0.3
    flat_decal(m, "Stencil", "battery", (0.4755 * math.cos(a), 0.0, 0.4755 * math.sin(a)), (-math.sin(a), 0, math.cos(a)), (0, 1, 0), 0.18)
    return m, (1, 1, 1)


def part_cargo():
    m = Model()
    h, r = 1.2, 0.5
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.06, r - 0.06, r, uv_m=2.0)
    flange(m, "Metal", y1 - 0.06, y1, r - 0.06, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + 0.03, r, 32, size=0.007, height=0.006, radial=True)
    bolt_ring(m, "Metal", y1 - 0.03, r, 32, size=0.007, height=0.006, radial=True)
    disk(m, "Metal", r - 0.06, y0 + 0.004, segs=32, up=True, uv_m=2.0)
    disk(m, "Metal", r - 0.06, y1 - 0.004, segs=32, up=False, uv_m=2.0)
    # Two clamshell doors, each slightly proud of a darker longeron.
    for (a0, a1) in ((0.06, math.pi - 0.06), (math.pi + 0.06, TAU - 0.06)):
        lathe(m, "Paint", [(r - 0.012, y0 + 0.06), (r - 0.012, y1 - 0.06)], segs=24, a0=a0, a1=a1, uv_m=1.0)
        for a in (a0, a1):
            c, s = math.cos(a), math.sin(a)
            # door edge faces
            m.add("Metal", [((r - 0.012) * c, y0 + 0.06, (r - 0.012) * s), ((r - 0.012) * c, y1 - 0.06, (r - 0.012) * s),
                            ((r - 0.04) * c, y1 - 0.06, (r - 0.04) * s), ((r - 0.04) * c, y0 + 0.06, (r - 0.04) * s)],
                  [(-s, 0, c)] * 4, [(0, 0), (0, 1), (0.1, 1), (0.1, 0)], [(0, 1, 2), (0, 2, 3)])
        # hinge line + latches
        am = (a0 + a1) / 2
    for a in (0.0, math.pi):
        c, s = math.cos(a), math.sin(a)
        tube(m, "Dark", ((r - 0.02) * c, y0 + 0.06, (r - 0.02) * s), ((r - 0.02) * c, y1 - 0.06, (r - 0.02) * s), 0.016, segs=8)
        for yy in np.linspace(y0 + 0.15, y1 - 0.15, 5):
            box(m, "Metal", ((r - 0.006) * c, yy, (r - 0.006) * s), (0.02, 0.05, 0.06), rot_y(-a), uv_m=6.0)
    # Longeron behind the gaps (seen through them).
    lathe(m, "Dark", [(r - 0.04, y0 + 0.06), (r - 0.04, y1 - 0.06)], segs=48, uv_m=1.0)
    decal(m, "Stencil", "cargo", cyl_r(r - 0.012), FRONT, 0.2, 0.4)
    decal(m, "Decal", "flag", cyl_r(r - 0.012), FRONT, -0.05, 0.16)
    decal(m, "Stencil", "nostep", cyl_r(r - 0.012), BACK, 0.35, 0.22)
    return m, (1.0, 1.2, 1.0)


def part_radial_tank():
    """A spherical propellant tank in gold MLI on a strut cradle; the hull is
    at −X (radial parts face +X outward)."""
    m = Model()
    R = 0.42
    prof = [(R * math.sin(t), -R * math.cos(t)) for t in np.linspace(0.0, math.pi, 17)]
    lathe(m, "Foil", prof, segs=40, smooth=True, uv_m=1.5)
    lathe(m, "Metal", [(R + 0.003, -0.025), (R + 0.015, -0.015), (R + 0.015, 0.015), (R + 0.003, 0.025)], segs=40, uv_m=4.0)
    bolt_ring(m, "Metal", 0.0, R + 0.015, 24, size=0.006, height=0.005, radial=True)
    # Cradle: a mounting plate on −X and struts to the girth ring.
    box(m, "Metal", (-0.48, 0, 0), (0.04, 0.5, 0.3), uv_m=2.0)
    for (y, z) in ((0.2, 0.12), (0.2, -0.12), (-0.2, 0.12), (-0.2, -0.12)):
        tube(m, "Metal", (-0.47, y, z), (-0.3, y * 0.15, z * 1.9), 0.014, segs=8)
    # Plumbing out of the poles toward the hull.
    tube(m, "Metal", (0, R, 0), (0, 0.5, 0), 0.03, segs=10)
    tube(m, "Metal", (0, -R, 0), (0, -0.5, 0), 0.03, segs=10)
    tube(m, "Metal", (0, 0.47, 0), (-0.46, 0.47, 0), 0.016, segs=8)
    tube(m, "Metal", (0, -0.47, 0), (-0.46, -0.47, 0), 0.016, segs=8)
    # Pad the box to ±0.5 in x and z so the recentre keeps the attach point.
    box(m, "Metal", (0.495, 0, 0), (0.01, 0.06, 0.06), uv_m=4.0)
    box(m, "Metal", (0, 0, 0.495), (0.06, 0.06, 0.01), uv_m=4.0)
    box(m, "Metal", (0, 0, -0.495), (0.06, 0.06, 0.01), uv_m=4.0)
    return m, (1, 1, 1)


def part_fin():
    """A swept aero fin in the old fin.glb's exact box (0.74 × 1.02 × 0.14):
    the root mount at −X carries the 0.14 thickness, the blade is thin."""
    m = Model()
    # old AABB: x [-0.37, 0.37], y [-0.51, 0.51], z [-0.07, 0.07]
    root_x = -0.30
    box(m, "Metal", (-0.335, -0.02, 0), (0.07, 0.86, 0.14), uv_m=2.0)
    for yy in np.linspace(-0.4, 0.36, 6):
        for z in (-0.071, 0.071):
            tube(m, "Metal", (-0.345, yy, z * 0.9), (-0.345, yy, z * 0.995), 0.008, segs=6)
    fin_shape(m, 0.0, root_r=root_x, y_root_top=0.43, y_root_bot=-0.45, span=0.67, sweep=0.44, tip_len=0.28, thick=0.03)
    # Keep the old box exactly: tip-of-root pin to y = +0.51 and −0.51.
    box(m, "Metal", (-0.335, 0.48, 0), (0.03, 0.06, 0.04), uv_m=4.0)
    box(m, "Metal", (-0.335, -0.48, 0), (0.03, 0.06, 0.04), uv_m=4.0)
    flat_decal(m, "Stencil", "nostep", (0.0, -0.15, 0.0151), (1, 0, 0), (0, 1, 0), 0.22)
    flat_decal(m, "Stencil", "nostep", (0.0, -0.15, -0.0151), (-1, 0, 0), (0, 1, 0), 0.22)
    return m, (1, 1, 1)


# The wing's hinge: where it folds against the hull for launch (part frame).
SOLAR_HINGE_X = -0.30


def part_solar():
    """Solar array wing on a yoke. Returns (yoke, wing): the yoke in the part
    frame (hull at −X), the wing in its HINGE frame (the pin at the origin,
    the panel out along +X in the X–Y plane, cells facing +Z). Real size
    0.9 × 0.66 × 0.06 deployed, inside the builder's box. Uniform scale: the
    old node scale (1.3, 0.12, 1.0) is gone, and the flight folds the wing
    about its pin (SolarWingPivot yaw) instead of squashing the part flat
    along X ("the solar panels are squished", 2026-10-23)."""
    yoke = Model()
    box(yoke, "Metal", (-0.41, 0, 0), (0.08, 0.16, 0.1), uv_m=4.0)
    tube(yoke, "Metal", (-0.37, 0, 0), (SOLAR_HINGE_X - 0.012, 0, 0), 0.02, segs=10)
    tube(yoke, "Metal", (SOLAR_HINGE_X, -0.07, 0), (SOLAR_HINGE_X, 0.07, 0), 0.022, segs=12)  # hinge knuckle
    wing = Model()
    x0, x1, yh = 0.02, 0.74, 0.33
    box(wing, "Metal", (0.01, 0, 0), (0.02, 0.12, 0.03), uv_m=4.0)                           # hinge leaf
    box(wing, "Metal", ((x0 + x1) / 2, yh, 0), (x1 - x0, 0.02, 0.025), uv_m=3.0)
    box(wing, "Metal", ((x0 + x1) / 2, -yh, 0), (x1 - x0, 0.02, 0.025), uv_m=3.0)
    box(wing, "Metal", (x0, 0, 0), (0.02, 2 * yh, 0.025), uv_m=3.0)
    box(wing, "Metal", (x1, 0, 0), (0.02, 2 * yh, 0.025), uv_m=3.0)
    box(wing, "Metal", ((x0 + x1) / 2, 0, 0), (0.012, 2 * yh, 0.02), uv_m=3.0)
    for sgn, mat in ((1, "Solar"), (-1, "Foil")):
        P = [(x0, yh, sgn * 0.006), (x1, yh, sgn * 0.006), (x1, -yh, sgn * 0.006), (x0, -yh, sgn * 0.006)]
        UV = [(0, 0), ((x1 - x0) * 4, 0), ((x1 - x0) * 4, 2 * yh * 4), (0, 2 * yh * 4)]
        wing.add(mat, P, [(0, 0, sgn)] * 4, UV, [(0, 1, 2), (0, 2, 3)])
    return yoke, wing


def part_dish():
    m = Model()
    # Real 0.8 tall × 0.76 wide; dish faces +Y (the device tips it).
    y0, y1 = -0.4, 0.4
    flange(m, "Metal", y0, y0 + 0.04, 0.0, 0.22, uv_m=3.0)
    bolt_ring(m, "Metal", y0 + 0.04, 0.19, 8, size=0.008, height=0.006)
    box(m, "Foil", (0, y0 + 0.11, 0), (0.18, 0.12, 0.18), uv_m=2.0)
    tube(m, "Metal", (0, y0 + 0.17, 0), (0, y0 + 0.36, 0), 0.03, segs=12)
    box(m, "Dark", (0, y0 + 0.36, 0), (0.1, 0.05, 0.1), uv_m=6.0)
    # Paraboloid reflector with a rolled rim and ribs on its back.
    R, depth, yd = 0.38, 0.16, y0 + 0.38
    prof = [(R * t, yd + depth * t * t) for t in np.linspace(0.0, 1.0, 10)]
    lathe(m, "Paint", prof, segs=40, smooth=True, uv_m=1.5)
    back = [(r, y - 0.012) for (r, y) in prof]
    lathe(m, "Metal", back, segs=40, smooth=True, uv_m=2.0, inward=True)
    lathe(m, "Metal", [(R, yd + depth - 0.012), (R + 0.012, yd + depth - 0.006), (R, yd + depth)], segs=40, uv_m=4.0)
    for k in range(8):
        a = TAU * k / 8
        c, s = math.cos(a), math.sin(a)
        pts = [(r * c, y - 0.02, r * s) for (r, y) in back[1::2]]
        for i in range(len(pts) - 1):
            tube(m, "Metal", pts[i], pts[i + 1], 0.006, segs=5, caps=False)
    # Feed horn on a tripod.
    yf = yd + depth + 0.2
    for k in range(3):
        a = TAU * k / 3
        tube(m, "Metal", (0.3 * math.cos(a), yd + 0.3 * 0.3 * depth / 0.3 + 0.02, 0.3 * math.sin(a)), (0, yf, 0), 0.006, segs=5)
    tube(m, "Paint2", (0, yf - 0.06, 0), (0, yf, 0), 0.03, segs=12, r1=0.04)
    tube(m, "Dark", (0, yf, 0), (0, y1, 0), 0.02, segs=10)
    # Even the box out in y: dish top is y1 by the horn.
    decal(m, "Stencil", "dish", lambda y: 0.22, FRONT, y0 + 0.02, 0.18, height=0.03)
    return m, (0.7, 0.7, 0.7)


def part_probe():
    """Probe core: a squat octagonal avionics ring between two bolted flanges,
    foil-wrapped boxes on its faces, a status lamp and a stub antenna on top.
    Real size 0.84 × 0.42 × 0.84 — the builder's box (h 0.42, r 0.42)."""
    m = Model()
    h, r = 0.42, 0.42
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.04, 0.0, r, uv_m=2.0)
    flange(m, "Metal", y1 - 0.04, y1, 0.0, r, uv_m=2.0)
    bolt_ring(m, "Metal", y0 + 0.04, r - 0.03, 16, size=0.006, height=0.005, up=True)
    bolt_ring(m, "Metal", y1 - 0.04, r - 0.03, 16, size=0.006, height=0.005, up=False)
    # The octagonal body (8 flat faces: a lathe with 8 segments).
    lathe(m, "Paint3", [(0.37, y0 + 0.04), (0.37, y1 - 0.04)], segs=8, uv_m=2.0, a0=TAU / 16, a1=TAU + TAU / 16)
    for k in range(8):
        a = TAU * k / 8 + TAU / 16 + TAU / 16
        c, s_ = math.cos(a), math.sin(a)
        M = rot_y(-a)
        mat = "Foil" if k % 2 == 0 else "Paint2"
        box(m, mat, (0.355 * c, 0.0, 0.355 * s_), (0.03, 0.2, 0.16), M, uv_m=3.0)
        if k % 2 == 1:
            box(m, "Dark", (0.372 * c, 0.05, 0.372 * s_), (0.008, 0.03, 0.08), M, uv_m=6.0)
    # A status lamp and a stub antenna through the top flange (inside the box).
    tube(m, "Chrome", (0.2, y1 - 0.005, 0.0), (0.2, y1, 0.0), 0.02, segs=10)
    return m, (1, 1, 1)


def part_antenna():
    """The Comm Whip: a mounting block against the hull (−X) carrying a
    telescoping mast that runs up the hull (+Y). Folded, the device telescopes
    the mast down into its base. Real size 0.24 × 0.9 × 0.24."""
    m = Model()
    y0, y1 = -0.45, 0.45
    box(m, "Metal", (-0.09, y0 + 0.07, 0.0), (0.06, 0.14, 0.12), uv_m=4.0)
    box(m, "Paint2", (-0.02, y0 + 0.07, 0.0), (0.1, 0.1, 0.1), uv_m=4.0, bevel=0.01)
    tube(m, "Dark", (0.0, y0 + 0.12, 0.0), (0.0, y0 + 0.2, 0.0), 0.03, segs=12)
    # Three telescoping sections, each thinner.
    tube(m, "Chrome", (0.0, y0 + 0.2, 0.0), (0.0, y0 + 0.48, 0.0), 0.018, segs=10)
    tube(m, "Chrome", (0.0, y0 + 0.48, 0.0), (0.0, y0 + 0.72, 0.0), 0.013, segs=10)
    tube(m, "Chrome", (0.0, y0 + 0.72, 0.0), (0.0, y1 - 0.02, 0.0), 0.009, segs=8)
    tube(m, "Dark", (0.0, y1 - 0.02, 0.0), (0.0, y1, 0.0), 0.016, segs=8)
    # Keep the box symmetric about the centre in x/z: a sliver of bracket on +X.
    box(m, "Metal", (0.11, y0 + 0.07, 0.0), (0.02, 0.05, 0.04), uv_m=4.0)
    tube(m, "Metal", (0.0, y0 + 0.07, -0.12), (0.0, y0 + 0.07, 0.12), 0.006, segs=6)
    return m, (1, 1, 1)


def part_light():
    """A floodlight: a bracket on the hull (−X) and a lamp head facing out (+X)
    with a bright lens. Real size 0.3 × 0.3 × 0.3."""
    m = Model()
    box(m, "Metal", (-0.13, 0.0, 0.0), (0.04, 0.2, 0.16), uv_m=4.0)
    tube(m, "Dark", (-0.11, 0.0, 0.0), (-0.05, 0.0, 0.0), 0.03, segs=10)
    tube(m, "Paint3", (-0.06, 0.0, 0.0), (0.12, 0.0, 0.0), 0.11, segs=20, r1=0.14)
    tube(m, "Chrome", (0.12, 0.0, 0.0), (0.15, 0.0, 0.0), 0.13, segs=20)
    for k in range(6):
        a = TAU * k / 6
        tube(m, "Dark", (-0.04, 0.115 * math.cos(a), 0.115 * math.sin(a)),
             (0.08, 0.135 * math.cos(a), 0.135 * math.sin(a)), 0.006, segs=4)
    box(m, "Metal", (0.0, 0.15 - 0.005, 0.0), (0.02, 0.01, 0.02), uv_m=4.0)
    box(m, "Metal", (0.0, -0.15 + 0.005, 0.0), (0.02, 0.01, 0.02), uv_m=4.0)
    box(m, "Metal", (0.0, 0.0, 0.15 - 0.005), (0.02, 0.02, 0.01), uv_m=4.0)
    box(m, "Metal", (0.0, 0.0, -0.15 + 0.005), (0.02, 0.02, 0.01), uv_m=4.0)
    return m, (1, 1, 1)


# ── landing legs ─────────────────────────────────────────────────────────────
# Three segments, each authored about its JOINT (the hip / knee at the origin)
# inside exactly the box the old tools/gen_parts.py segments had — the prefab's
# pivot offsets compensate for the engine's recentre by those boxes, so the
# boxes must not move (check_box enforces it).

LEG_BOXES = {
    "leg_hinge": ((-0.12, -0.13, -0.17), (0.12, 0.20, 0.17)),
    "leg_upper": ((-0.09, -0.92, -0.10), (0.13, 0.0, 0.10)),
    "leg_lower": ((-0.15, -0.71, -0.20), (0.39, 0.0, 0.20)),
}


def part_leg_hinge():
    m = Model()
    box(m, "Paint2", (0.0, 0.0, 0.0), (0.24, 0.26, 0.34), uv_m=2.0)
    box(m, "Metal", (0.0, 0.14, 0.0), (0.16, 0.12, 0.22), uv_m=3.0)
    tube(m, "Chrome", (0.0, 0.14, -0.17), (0.0, 0.14, 0.17), 0.03, segs=12)
    for x in (-0.08, 0.08):
        for z in (-0.13, 0.13):
            tube(m, "Metal", (x, 0.128, z), (x, 0.138, z), 0.012, segs=6)
    flat_decal(m, "Decal", "hazard", (0.0, -0.06, 0.1701), (1, 0, 0), (0, 1, 0), 0.22, 0.04)
    return m


def part_leg_upper():
    m = Model()
    box(m, "Metal", (0.0, -0.04, 0.0), (0.15, 0.08, 0.15), uv_m=3.0)          # hip clevis
    tube(m, "Paint2", (0.0, -0.06, 0.0), (0.0, -0.78, 0.0), 0.06, segs=14)    # strut
    box(m, "Metal", (0.0, -0.84, 0.0), (0.15, 0.16, 0.2), uv_m=3.0)           # knee block
    # Hydraulic damper: barrel, polished rod, end eyes.
    tube(m, "Dark", (0.095, -0.05, 0.0), (0.095, -0.4, 0.0), 0.035, segs=12)
    tube(m, "Chrome", (0.095, -0.4, 0.0), (0.095, -0.72, 0.0), 0.018, segs=10)
    tube(m, "Metal", (0.095, -0.72, 0.0), (0.095, -0.76, 0.0), 0.028, segs=10)
    for y in (-0.2, -0.5):
        lathe(m, "Metal", [(0.06, y - 0.012), (0.066, y - 0.006), (0.066, y + 0.006), (0.06, y + 0.012)], segs=14, uv_m=6.0)
    box(m, "Dark", (-0.075, -0.4, 0.0), (0.03, 0.5, 0.05), uv_m=4.0)          # cable channel
    return m


def part_leg_lower():
    m = Model()
    box(m, "Metal", (0.0, -0.03, 0.0), (0.13, 0.06, 0.13), uv_m=3.0)          # knee clevis
    tube(m, "Paint2", (0.0, -0.05, 0.0), (0.0, -0.5, 0.0), 0.05, segs=14)     # shin
    tube(m, "Chrome", (0.0, -0.5, 0.0), (0.0, -0.6, 0.0), 0.035, segs=12)     # crush stroke
    lathe(m, "Metal", [(0.05, -0.53), (0.06, -0.525), (0.06, -0.505), (0.05, -0.5)], segs=14, uv_m=6.0)
    # Foot pad: a dished honeycomb pad on a ball joint.
    tube(m, "Dark", (0.0, -0.6, 0.0), (0.0, -0.63, 0.0), 0.045, segs=12)
    sub = Model()
    lathe(sub, "Metal", [(0.0, 0.0), (0.12, 0.004), (0.2, 0.02), (0.27, 0.05), (0.27, 0.1), (0.0, 0.08)], segs=28, uv_m=2.0)
    m.merge(sub, np.diag([1.0, 1.0, 0.2 / 0.27]), (0.12, -0.71, 0.0))
    for k in range(6):
        a = TAU * k / 6
        tube(m, "Metal", (0.0, -0.6, 0.0), (0.12 + 0.2 * math.cos(a), -0.66, 0.15 * math.sin(a)), 0.008, segs=5)
    return m


def check_box(name, model):
    mn, mx = model.bounds()
    want = LEG_BOXES[name]
    ok = np.allclose(mn, want[0], atol=0.004) and np.allclose(mx, want[1], atol=0.004)
    print(f"{name:12s} box {np.round(mn, 3)} .. {np.round(mx, 3)} tris {model.tris()}" + ("" if ok else f"  !! want {want}"))
    return ok


def patch_legs(models):
    """PartLegs carries three mesh nodes, each with its own material block."""
    path = os.path.join(PREFABS, "PartLegs.prefab.ron")
    src = open(path).read()
    for name in ("leg_hinge", "leg_upper", "leg_lower"):
        at = src.find(f'asset_path: "models/parts/{name}.glb"')
        assert at >= 0, name
        start = src.find("material: Some((", at)
        om = src.find("object_materials: {", at)
        nxt = src.find("asset_path:", at + 10)
        nxt = len(src) if nxt < 0 else nxt
        if 0 <= om < nxt and (start < 0 or om < start or start > nxt):
            depth, i = 0, src.find("{", om)
            while True:
                if src[i] == "{": depth += 1
                elif src[i] == "}":
                    depth -= 1
                    if depth == 0: break
                i += 1
            end = src.find(",", i) + 1
            src = src[:om] + object_materials(models[name]) + src[end:]
        else:
            depth, i = 0, src.find("(", start)
            while True:
                if src[i] == "(": depth += 1
                elif src[i] == ")":
                    depth -= 1
                    if depth == 0: break
                i += 1
            end = src.find(",", i) + 1
            src = src[:start] + object_materials(models[name]) + src[end:]
    open(path, "w").write(src)


PARTS = {
    "pod":        (part_pod, "PartPod"),
    "nose":       (part_nose, "PartNose"),
    "tank_s":     (part_tankS, "PartTankS"),
    "tank_m":     (part_tankM, "PartTankM"),
    "engine_s":   (part_engineS, "PartEngineS"),
    "engine_m":   (part_engineM, "PartEngineM"),
    "skipper":    (part_skipper, "PartSkipper"),
    "decoupler":  (part_decoupler, "PartDecoupler"),
    "dock_port":  (part_dockport, "PartDockPort"),
    "rcs":        (part_rcs, "PartRCS"),
    "battery":    (part_battery, "PartBattery"),
    "cargo":      (part_cargo, "PartCargo"),
    "radial_tank": (part_radial_tank, "PartRadialTank"),
    "aero_fin":   (part_fin, "PartFins"),
    "dish":       (part_dish, "PartDish"),
    "chute":      (part_chute, "PartChute"),
    "probe_core": (part_probe, "PartProbe"),
    "antenna":    (part_antenna, "PartAntenna"),
    "floodlight": (part_light, "PartLight"),
}

# Builder envelopes (h, and the box each mesh must stay centred in).
ENVELOPE = {
    "pod": (1.0, 0.8, 1.0), "nose": (1.0, 0.9, 1.0), "tank_s": (1.0, 1.0, 1.0), "tank_m": (1.0, 1.5, 1.0),
    "engine_s": (None, 1.3, None), "engine_m": (1.0, 1.6, 1.0), "skipper": (1.0, 1.6, 1.0),
    "decoupler": (1.02, 0.25, 1.02), "dock_port": (1.06, 0.28, 1.06), "battery": (1.0, 1.0, 1.0),
    "cargo": (1.0, 1.2, 1.0), "radial_tank": (1.0, 1.0, 1.0), "aero_fin": (0.74, 1.02, 0.14),
    "chute": (None, 0.34, None),
    "probe_core": (0.84, 0.42, 0.84), "antenna": (0.24, 0.9, 0.24), "floodlight": (0.3, 0.3, 0.3),
}


# ── glTF writer ──────────────────────────────────────────────────────────────

def write_glb(model, path, scale=(1, 1, 1)):
    s = np.asarray(scale, float)
    arrs = model.arrays()
    bin_ = bytearray()
    views, accs, prims, mats = [], [], [], []

    def view(data, target):
        nonlocal bin_
        while len(bin_) % 4:
            bin_ += b"\0"
        off = len(bin_)
        bin_ += data
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    for mi, (mat, (P, N, UV, I)) in enumerate(sorted(arrs.items())):
        P = (P / s).astype(np.float32)
        N = N * s
        N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
        UV = UV.astype(np.float32)
        I = I.astype(np.uint32).reshape(-1)
        vp = view(P.tobytes(), 34962)
        accs.append({"bufferView": vp, "componentType": 5126, "count": len(P), "type": "VEC3",
                     "min": P.min(0).tolist(), "max": P.max(0).tolist()})
        ap = len(accs) - 1
        vn = view(N.tobytes(), 34962)
        accs.append({"bufferView": vn, "componentType": 5126, "count": len(N), "type": "VEC3"})
        an = len(accs) - 1
        vu = view(UV.tobytes(), 34962)
        accs.append({"bufferView": vu, "componentType": 5126, "count": len(UV), "type": "VEC2"})
        au = len(accs) - 1
        vi = view(I.tobytes(), 34963)
        accs.append({"bufferView": vi, "componentType": 5125, "count": len(I), "type": "SCALAR"})
        ai = len(accs) - 1
        mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1.0],
                                                           "metallicFactor": 0.0, "roughnessFactor": 0.6}})
        prims.append({"attributes": {"POSITION": ap, "NORMAL": an, "TEXCOORD_0": au}, "indices": ai, "material": mi})
    gl = {"asset": {"version": "2.0", "generator": "Solar tools/gen_part_meshes.py"},
          "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": os.path.splitext(os.path.basename(path))[0], "mesh": 0}],
          "meshes": [{"name": "part", "primitives": prims}],
          "materials": mats, "accessors": accs, "bufferViews": views,
          "buffers": [{"byteLength": len(bin_)}]}
    js = json.dumps(gl, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    while len(bin_) % 4:
        bin_ += b"\0"
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack("<II", len(bin_), 0x004E4942)); f.write(bytes(bin_))


def check_centered(name, model):
    mn, mx = model.bounds()
    c = (mn + mx) / 2
    size = mx - mn
    env = ENVELOPE.get(name)
    msg = f"{name:12s} size {np.round(size, 3)} centre {np.round(c, 3)} tris {model.tris()}"
    bad = np.abs(c) > 0.004
    if env:
        for ax in range(3):
            if env[ax] is not None and abs(size[ax] - env[ax]) > 0.02:
                msg += f"  !! axis {'xyz'[ax]} size {size[ax]:.3f} != {env[ax]}"
    if bad.any():
        msg += "  !! OFF-CENTRE (the engine would shift this part)"
    print(msg)
    return not bad.any()


# ── materials (prefab object_materials) ──────────────────────────────────────

# The hull materials wear the damage shader (shaders/hullPanels.flsl): their
# own maps lit by the engine's Physical model (litPbr, v0.117), with scorch,
# gouges and dents laid over as the part's `damage` rises. The material colour
# goes in as its `tint`, because a shader replaces the built-in look.
HULL_SHADER = "shaders/hullPanels.flsl"


def mat_ron(tex, color=(1, 1, 1), rough=1.0, metal=1.0, normal=1.0, extra="", hull=True):
    t = TEX + tex
    if hull:
        extra += (f'                shader: Some("{HULL_SHADER}"),\n'
                  f'                shader_params: {{\n'
                  f'                    "tint": ({color[0]}, {color[1]}, {color[2]}, 1.0),\n'
                  f'                }},\n')
    return (f'(\n                color: ({color[0]}, {color[1]}, {color[2]}),\n'
            f'                texture: Some("{t}_albedo.png"),\n'
            f'                normal_map: Some("{t}_normal.png"),\n'
            f'                normal_strength: {normal},\n'
            f'                roughness_map: Some("{t}_orm.png"),\n'
            f'                roughness: {rough},\n'
            f'                metallic_map: Some("{t}_orm.png"),\n'
            f'                metallic: {metal},\n'
            f'                ao_map: Some("{t}_orm.png"),\n'
            f'{extra}'
            f'                shading: Physical,\n            )')


MATERIALS = {
    "Paint":    lambda: mat_ron("paint"),
    "Paint2":   lambda: mat_ron("paint", color=(0.9, 0.9, 0.88)),
    "Paint3":   lambda: mat_ron("paint", color=(0.22, 0.23, 0.25)),
    # The parachute's mortar cap: the same painted skin in safety orange.
    "PaintOrange": lambda: mat_ron("paint", color=(1.0, 0.46, 0.12)),
    # Metallic is held below 1 on purpose: in space the sky is black, and a
    # true metal reflects nothing but the sun there — every flange read as a
    # black hole. A partly dielectric response keeps the brushed grain lit.
    "Metal":    lambda: mat_ron("metal", metal=0.55),
    "Dark":     lambda: mat_ron("metal", color=(0.3, 0.3, 0.32), rough=1.2, metal=0.4),
    "Chrome":   lambda: mat_ron("metal", color=(1.0, 1.0, 1.0), rough=0.4, metal=0.85),
    "Tiles":    lambda: mat_ron("tiles", metal=0.0),
    "Ablative": lambda: mat_ron("ablative", metal=0.0),
    "Bell":     lambda: mat_ron("bell", metal=0.6),
    "BellIn":   lambda: mat_ron("bell", color=(0.16, 0.14, 0.13), rough=1.3),
    "Foil":     lambda: mat_ron("foil", metal=0.7),
    "Solar":    lambda: mat_ron("solar", hull=False),
    # Structure and rovers: diamond tread plate on decks, tyre rubber, and an
    # anodised (dark blue-grey) alloy for frames and robotic housings.
    "Tread":    lambda: mat_ron("tread", metal=0.6),
    "Rubber":   lambda: mat_ron("rubber", metal=0.0, hull=False),
    "Anodised": lambda: mat_ron("metal", color=(0.5, 0.56, 0.66), rough=0.85, metal=0.5),
    "Yellow":   lambda: mat_ron("paint", color=(0.95, 0.72, 0.12)),
    # Alpha, not transmission: a transmissive pane switches on the renderer's
    # whole refraction pass (measured 1.9 ms GPU for this one small window
    # seen from outside). A thin tinted pane that blends is a fraction of that
    # and still carries the sky's reflection on its Physical surface.
    "Glass": lambda: ('(\n                color: (0.30, 0.38, 0.42),\n                roughness: 0.04,\n'
                      '                metallic: 0.0,\n                alpha: 0.32,\n'
                      '                shading: Physical,\n            )'),
    "Stencil": lambda: (f'(\n                color: (0.06, 0.06, 0.07),\n                texture: Some("{TEX}markings.png"),\n'
                        '                roughness: 0.6,\n                metallic: 0.0,\n                shading: Physical,\n            )'),
    "Decal": lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}markings.png"),\n'
                      '                roughness: 0.55,\n                metallic: 0.0,\n                shading: Physical,\n            )'),
    "Cabin": lambda: mat_ron("interior", metal=0.0, hull=False),
    "Screen": lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}interior_albedo.png"),\n'
                       '                unlit: true,\n                fog: false,\n            )'),
}


def object_materials(model):
    names = sorted(model.parts.keys())
    body = ",\n".join(f'            "{n}": {MATERIALS[n]()}' for n in names)
    return "object_materials: {\n" + body + ",\n        },"


def patch_prefab(prefab, glb_rel, model, interior=None):
    path = os.path.join(PREFABS, prefab + ".prefab.ron")
    src = open(path).read()
    # Root node = first node. Replace its Mesh asset_path.
    src, n = re.subn(r'(matter: Mesh\(\s*asset_path: ")[^"]+(")', r'\g<1>' + glb_rel + r'\2', src, count=1)
    assert n == 1, prefab
    # Replace the root's material block (or a previous object_materials block).
    start = src.find("material: Some((")
    om = src.find("object_materials: {")
    scripts_at = src.find("scripts:")
    if 0 <= om < scripts_at:
        depth, i = 0, src.find("{", om)
        while True:
            if src[i] == "{": depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0: break
            i += 1
        end = src.find(",", i) + 1
        src = src[:om] + object_materials(model) + src[end:]
    elif 0 <= start < scripts_at:
        depth, i = 0, src.find("(", start)
        while True:
            if src[i] == "(": depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0: break
            i += 1
        end = src.find(",", i) + 1
        src = src[:start] + object_materials(model) + src[end:]
    else:
        raise SystemExit(f"{prefab}: no root material block found")
    if interior is not None:
        src = add_interior(src, interior)
    open(path, "w").write(src)


INTERIOR_MARK = "// ── pod interior (tools/gen_part_meshes.py) ──"


def add_interior(src, interior):
    """Append (or refresh) the pod's cabin subtree: a disabled Empty holding the
    cabin mesh and its lamp. planet_camera.lua enables it in first person."""
    model, centre = interior
    if INTERIOR_MARK in src:
        src = src[:src.index(INTERIOR_MARK)].rstrip() + "\n"
        src = src.rstrip().rstrip("]").rstrip() + "\n"
    else:
        src = src.rstrip()
        assert src.endswith("]")
        src = src[:-1].rstrip() + "\n"
    cx, cy, cz = (round(float(v), 4) for v in centre)
    block = f'''    {INTERIOR_MARK}
    // Only enabled in first person (planet_camera.lua): it costs nothing while
    // disabled. The mesh is recentred by the engine, so its node sits at the
    // cabin's box centre ({cx}, {cy}, {cz}) in the pod's frame.
    (
        name: "Pod Interior",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        disabled: true,
        parent: Some(0),
    ),
    (
        name: "Pod Cabin",
        transform: (
            translation: ({cx}, {cy}, {cz}),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/parts/pod_interior.glb",
        ),
        {object_materials(model)}
        scripts: [],
        parent: Some(INTERIOR_INDEX),
    ),
    (
        name: "Pod Cabin Lamp",
        transform: (
            translation: (0.0, 0.22, -0.05),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: (1.0, 0.86, 0.7),
            intensity: 1.4,
            range: 1.4,
        ),
        scripts: [],
        parent: Some(INTERIOR_INDEX),
    ),
]
'''
    # The interior Empty's index = number of nodes already in the file.
    n_nodes = len(re.findall(r'^\s{8}name: "', src, flags=re.M))
    block = block.replace("INTERIOR_INDEX", str(n_nodes))
    return src + block



# ── round two: structure, rovers, robotics, the claw and the drill ──────────
# These parts are written as WHOLE prefabs (write_prefab), not patched: a root
# node with the part's kinematic box collider (its builder footprint, so a
# craft rests on what you see) and the meshes as recentred children. A child
# the flight scripts move is named: "Tyre" (a wheel's tyre, hidden while the
# live tyre body rolls), "Head" (a hinge's, piston's or rotor's moving half),
# "Stage" (a piston's middle tube), "Bit" (the drill's auger), "Fingers"
# (the claw's), "Lamp" (the rover body's headlights).

def end_plate(m, y, w, d, t=0.016, mat="Metal", up=True, bolts=True, bolt_mat="Metal"):
    """A bolted square end plate (w × d) centred on the Y axis at height y.
    The bolts wear the plate's own Metal so a frame member is two materials
    (two draws): a 1,000-member frame was 3,096 draws at four (design §8.2)."""
    yc = y - t / 2 if up else y + t / 2
    box(m, mat, (0, yc, 0), (w, t, d), uv_m=4.0)
    if bolts:
        for sx in (-1, 1):
            for sz in (-1, 1):
                p = np.array([sx * (w / 2 - 0.018), y, sz * (d / 2 - 0.018)])
                dirv = np.array([0, 1.0 if up else -1.0, 0])
                tube(m, bolt_mat, p - dirv * 0.002, p + dirv * 0.007, 0.007, segs=6, uv_m=8.0)


def part_strut(L):
    """Square aluminium tube, 0.1 m, with bolted end plates and a row of
    lightening-hole bosses each side. 0.14 × L × 0.14."""
    def fn():
        m = Model()
        h = L / 2
        box(m, "Anodised", (0, 0, 0), (0.1, L - 0.04, 0.1), uv_m=2.0)
        end_plate(m, h, 0.14, 0.14)
        end_plate(m, -h, 0.14, 0.14, up=False)
        n = max(2, int(round(L / 0.25)))
        for k in range(n):
            y = -h + 0.06 + (L - 0.12) * (k + 0.5) / n
            for ax in (0, 2):
                for sg in (-1, 1):
                    c = [0, y, 0]
                    c[ax] = sg * 0.0505
                    sz = [0.05, 0.12 * min(1.0, L / n / 0.25), 0.05]
                    sz[ax] = 0.004
                    box(m, "Metal", tuple(c), tuple(sz), uv_m=6.0)
        return m
    return fn


def part_beam(L):
    """Rectangular box beam 0.2 × 0.1 (X × Z), bolted end plates."""
    def fn():
        m = Model()
        h = L / 2
        box(m, "Anodised", (0, 0, 0), (0.2, L - 0.04, 0.1), uv_m=2.0)
        # a stiffening rib down each broad face
        for sg in (-1, 1):
            box(m, "Metal", (0, 0, sg * 0.052), (0.03, L - 0.08, 0.006), uv_m=4.0)
        end_plate(m, h, 0.24, 0.14)
        end_plate(m, -h, 0.24, 0.14, up=False)
        return m
    return fn


def part_ibeam(L):
    """Painted steel I-beam: flanges 0.2 wide at ±Z, web 0.24 deep."""
    def fn():
        m = Model()
        h = L / 2
        Ls = L - 0.04
        for sg in (-1, 1):
            box(m, "Yellow", (0, 0, sg * 0.11), (0.2, Ls, 0.02), uv_m=1.5)
        box(m, "Yellow", (0, 0, 0), (0.014, Ls, 0.2), uv_m=1.5)
        # web stiffeners every half metre
        n = int(L / 0.5)
        for k in range(1, n):
            y = -h + L * k / n
            for sx in (-1, 1):
                box(m, "Yellow", (sx * 0.05, y, 0), (0.086, 0.012, 0.2), uv_m=1.5)
        end_plate(m, h, 0.24, 0.26)
        end_plate(m, -h, 0.24, 0.26, up=False)
        return m
    return fn


def part_panel(W, D):
    """A flat structural panel W × D, 0.04 thick: a bolted alloy frame round
    a diamond-tread infill. Lies in its X–Z plane (stack nodes on its faces)."""
    def fn():
        m = Model()
        t = 0.04
        e = 0.05
        box(m, "Tread", (0, 0, 0), (W - 2 * e + 0.004, t * 0.6, D - 2 * e + 0.004), uv_m=2.0)
        for sg in (-1, 1):
            box(m, "Metal", (0, 0, sg * (D / 2 - e / 2)), (W, t, e), uv_m=3.0)
            box(m, "Metal", (sg * (W / 2 - e / 2), 0, 0), (e, t, D - 2 * e), uv_m=3.0)
        # bolts round the frame, both faces
        for face in (1, -1):
            nx = int(W / 0.25)
            nz = int(D / 0.25)
            pts = []
            for k in range(nx + 1):
                x = -W / 2 + e / 2 + (W - e) * k / nx
                pts += [(x, D / 2 - e / 2), (x, -D / 2 + e / 2)]
            for k in range(1, nz):
                z = -D / 2 + e / 2 + (D - e) * k / nz
                pts += [(W / 2 - e / 2, z), (-W / 2 + e / 2, z)]
            for (x, z) in pts:
                p = np.array([x, face * t / 2, z])
                dv = np.array([0, face, 0.0])
                tube(m, "Metal", p - dv * 0.002, p + dv * 0.006, 0.008, segs=6, uv_m=8.0)
        return m
    return fn


def part_plate():
    """Deck plate 1 × 1 × 0.1: a tread-plate top on a boxed frame."""
    m = Model()
    W, t = 1.0, 0.1
    box(m, "Tread", (0, t / 2 - 0.01, 0), (W, 0.02, W), uv_m=2.0)
    box(m, "Metal", (0, -0.01, 0), (W - 0.02, t - 0.02, W - 0.02), uv_m=2.0)
    box(m, "Metal", (0, -t / 2 + 0.008, 0), (W, 0.016, W), uv_m=2.0)
    return m


def part_hub():
    """Strut hub: a 0.24 m machined cube with a bolted pad on every face."""
    m = Model()
    s = 0.24
    box(m, "Anodised", (0, 0, 0), (s - 0.02, s - 0.02, s - 0.02), uv_m=4.0, bevel=0.01)
    for ax in range(3):
        for sg in (-1, 1):
            c = [0, 0, 0]
            c[ax] = sg * (s / 2 - 0.005)
            sz = [0.16, 0.16, 0.16]
            sz[ax] = 0.01
            box(m, "Metal", tuple(c), tuple(sz), uv_m=6.0)
    return m


def part_adapter():
    """1.0 → 0.5 m stack adapter: a painted cone between two flanges."""
    m = Model()
    h = 0.5
    y0, y1 = -h / 2, h / 2
    flange(m, "Metal", y0, y0 + 0.04, 0.0, 0.5)
    flange(m, "Metal", y1 - 0.03, y1, 0.0, 0.25)
    lathe(m, "Paint", [(0.48, y0 + 0.04), (0.255, y1 - 0.03)], segs=48, uv_m=1.5)
    bolt_ring(m, "Dark", y0 + 0.02, 0.5, 24, size=0.006, height=0.005, radial=True)
    bolt_ring(m, "Dark", y1 - 0.015, 0.25, 12, size=0.005, height=0.004, radial=True)
    decal(m, "Decal", "hazard", cone_r(0.48, y0 + 0.04, 0.255, y1 - 0.03), -math.pi / 2, y0 + 0.12, 0.3, height=0.04)
    return m


# ── rovers ──────────────────────────────────────────────────────────────────

def tyre(m, r, w, segs=40, rim=True):
    """A tyre about the X axis (centred): a rubber carcass with rounded
    shoulders, u across the tread, v along it (0.5 m a tile), and a spoked
    alloy rim each side."""
    # profile across the tread: (x, radius, normal-x, normal-r)
    sh = min(0.35 * w, 0.3 * r)
    prof = []
    # left shoulder: from the sidewall (normal −X) round to the tread (normal +r)
    for k in range(7):
        t = (math.pi / 2) * k / 6
        prof.append((-w / 2 + sh - sh * math.cos(t), r - sh + sh * math.sin(t), -math.cos(t), math.sin(t)))
    # right shoulder: from the tread round to the sidewall (normal +X)
    for k in range(7):
        t = (math.pi / 2) * (6 - k) / 6
        prof.append((w / 2 - sh + sh * math.cos(t), r - sh + sh * math.sin(t), math.cos(t), math.sin(t)))
    # the sidewalls down to the rim
    prof.insert(0, (-w / 2, r - sh * 1.6, -1.0, 0.0))
    prof.append((w / 2, r - sh * 1.6, 1.0, 0.0))
    tiles = max(1, int(round(TAU * r / 0.5)))
    P, N, UV, I = [], [], [], []
    n = len(prof)
    for i in range(segs + 1):
        a = TAU * i / segs
        c, s = math.cos(a), math.sin(a)
        for j, (x, rr, nx, nr) in enumerate(prof):
            P.append((x, rr * c, rr * s))
            N.append((nx, nr * c, nr * s))
            UV.append((j / (n - 1), a / TAU * tiles))
    for i in range(segs):
        for j in range(n - 1):
            a_ = i * n + j
            b_ = (i + 1) * n + j
            I.append((a_, b_, b_ + 1)); I.append((a_, b_ + 1, a_ + 1))
    m.add("Rubber", P, N, UV, I)
    if rim:
        rr = r - sh * 1.1
        for sg in (-1, 1):
            sub = Model()
            disk(sub, "Metal", rr, 0.0, segs=segs, up=True, uv_m=2.0, r_in=rr * 0.28)
            disk(sub, "Dark", rr * 0.28, -0.004, segs=16, up=True, uv_m=4.0)
            for k in range(5):
                a = TAU * k / 5
                tube(sub, "Metal", (0.35 * rr * math.cos(a), 0.01, 0.35 * rr * math.sin(a)),
                     (0.9 * rr * math.cos(a), 0.01, 0.9 * rr * math.sin(a)), 0.035 * rr + 0.006, segs=6)
            M = rot_z(-math.pi / 2) if sg > 0 else rot_z(math.pi / 2)
            m.merge(sub, M, (sg * (w / 2 - 0.02), 0, 0))


WHEELS = {
    #        tyre r, width, bracket depth
    "S": (0.25, 0.18, 0.10),
    "M": (0.40, 0.26, 0.14),
    "L": (0.60, 0.38, 0.18),
}


def wheel_dims(size):
    r, w, b = WHEELS[size]
    rx = (w + b) / 2
    return r, w, b, rx, -rx + b + w / 2   # tyre centre x in the part frame


def part_wheel(size):
    """A powered wheel on a flank (radial_orient: +X is out, the axle). The
    root carries the suspension bracket and hub motor against the hull (−X);
    the tyre is the "Tyre" child, centred on the axle."""
    def fn():
        r, w, b, rx, tx = wheel_dims(size)
        br = Model()
        x0, x1 = -rx, -rx + b
        # mounting plate against the hull
        box(br, "Anodised", (x0 + 0.015, 0.0, 0.0), (0.03, 0.9 * r, 0.7 * r), uv_m=3.0)
        # trailing suspension arm and coil-over
        box(br, "Metal", ((x0 + x1) / 2, -0.15 * r, 0.0), (b * 0.7, 0.18 * r, 0.25 * r), uv_m=4.0)
        tube(br, "Chrome", (x0 + 0.05, 0.38 * r, 0.25 * r), (x0 + 0.05, -0.1 * r, 0.05 * r), 0.06 * r + 0.01, segs=10)
        for k in range(6):
            yy = 0.32 * r - 0.07 * r * k
            tube(br, "Yellow", (x0 + 0.05, yy, 0.22 * r - 0.03 * r * k), (x0 + 0.05, yy - 0.035 * r, 0.21 * r - 0.03 * r * k),
                 0.1 * r + 0.012, segs=10)
        # hub motor drum on the axle
        tube(br, "Dark", (x1 - 0.03, 0, 0), (x1 + 0.02, 0, 0), 0.32 * r, segs=20)
        tube(br, "Anodised", (x0 + 0.03, 0, 0), (x1 - 0.03, 0, 0), 0.22 * r, segs=20)
        t0 = Model()
        tyre(t0, r, w)
        ty = Model()
        ty.merge(t0, None, (tx, 0, 0))
        return br, ty
    return fn


def part_rover_body():
    """Rover body 1.6 × 0.3 × 1.0: a tread-plate deck on a boxed chassis with
    its avionics, battery and a small whip inside; headlights and a bumper at
    the FRONT (+X)."""
    m = Model()
    L, H, W = 1.6, 0.3, 1.0
    box(m, "Paint2", (0, -0.015, 0), (L - 0.06, H - 0.03, W - 0.04), uv_m=1.5)
    box(m, "Tread", (0, H / 2 - 0.012, 0), (L, 0.024, W), uv_m=2.0)
    # bumpers front and back
    for sg in (-1, 1):
        box(m, "Dark", (sg * (L / 2 - 0.02), -0.04, 0), (0.04, 0.12, W - 0.1), uv_m=3.0)
    # side rails with hazard stripes
    for sg in (-1, 1):
        box(m, "Metal", (0, -H / 2 + 0.03, sg * (W / 2 - 0.01)), (L - 0.1, 0.05, 0.02), uv_m=3.0)
        flat_decal(m, "Decal", "hazard", (L / 2 - 0.25, 0.02, sg * (W / 2 - 0.02) + sg * 0.002),
                   (sg, 0, 0) if sg > 0 else (-1, 0, 0), (0, 1, 0), 0.3, 0.05)
    # avionics hatch and a sensor box on the deck
    box(m, "Dark", (-0.45, H / 2 + 0.03, 0.2), (0.3, 0.06, 0.25), uv_m=4.0)
    box(m, "Anodised", (0.45, H / 2 + 0.035, -0.25), (0.18, 0.07, 0.18), uv_m=4.0)
    flat_decal(m, "Stencil", "serial1", (-0.1, H / 2 + 0.001, -0.3), (1, 0, 0), (0, 0, -1), 0.3, 0.055)
    flat_decal(m, "Decal", "arrow", (0.5, H / 2 + 0.001, 0.15), (0, 0, 1), (1, 0, 0), 0.22)
    # headlights on the front face
    for sz in (-0.32, 0.32):
        tube(m, "Dark", (L / 2 - 0.02, 0.05, sz), (L / 2 + 0.0, 0.05, sz), 0.055, segs=14)
        tube(m, "Chrome", (L / 2 - 0.005, 0.05, sz), (L / 2 + 0.0, 0.05, sz), 0.045, segs=14)
    return m


def part_fairing_base(R):
    """Fairing base ring: the interstage collar the procedural shell stands on
    (scripts/fairing build it to fit the payload), a pyro band and bolts."""
    def fn():
        m = Model()
        h = 0.2
        y0, y1 = -h / 2, h / 2
        flange(m, "Metal", y0, y0 + 0.05, 0.0, R)
        lathe(m, "Dark", [(R - 0.01, y0 + 0.05), (R - 0.01, y1 - 0.04)], segs=64, uv_m=2.0)
        flange(m, "Metal", y1 - 0.04, y1, R * 0.45, R)
        disk(m, "Dark", R * 0.45, y1 - 0.01, segs=48, up=True)
        bolt_ring(m, "Dark", y0 + 0.025, R, 40, size=0.007, height=0.006, radial=True)
        decal(m, "Decal", "pyro", cyl_r(R - 0.01), -math.pi / 2, (y0 + y1) / 2 + 0.005, 0.5 * R, height=0.05)
        return m
    return fn


# ── robotics ────────────────────────────────────────────────────────────────

def part_hinge():
    """Servo hinge 0.4 × 0.4 × 0.4: a clevis base (lower half) and a tongue
    head (upper half) on a pin along Z through the centre. The head is the
    "Head" child; the flight turns it about the pin."""
    base = Model()
    box(base, "Anodised", (0, -0.15, 0), (0.4, 0.1, 0.4), uv_m=4.0)
    for sz in (-1, 1):
        box(base, "Anodised", (0, -0.05, sz * 0.15), (0.2, 0.2, 0.06), uv_m=4.0)
    box(base, "Dark", (0.13, -0.07, 0), (0.1, 0.06, 0.22), uv_m=4.0)   # servo motor
    tube(base, "Chrome", (0, 0, -0.19), (0, 0, 0.19), 0.035, segs=14)
    end_plate(base, -0.2, 0.4, 0.4, t=0.012, up=False)
    head = Model()
    box(head, "Metal", (0, 0.03, 0), (0.18, 0.2, 0.22), uv_m=4.0)
    box(head, "Metal", (0, 0.17, 0), (0.4, 0.06, 0.4), uv_m=4.0)
    end_plate(head, 0.2, 0.4, 0.4, t=0.012)
    flat_decal(head, "Decal", "hazard", (0, 0.17, 0.2011), (1, 0, 0), (0, 1, 0), 0.3, 0.04)
    return base, head


def part_piston(): 
    """Telescopic piston: a 0.5 m barrel (base), a middle "Stage" and the rod
    "Head" with its top plate. Extends up to 0.8 m along +Y."""
    base = Model()
    lathe(base, "Anodised", [(0.1, -0.23), (0.1, 0.22)], segs=24, uv_m=2.0)
    flange(base, "Metal", -0.25, -0.22, 0.0, 0.16)
    flange(base, "Metal", 0.2, 0.23, 0.0, 0.11)
    box(base, "Dark", (0.11, -0.05, 0), (0.04, 0.3, 0.08), uv_m=4.0)
    flat_decal(base, "Decal", "hazard", (0, 0.1, 0.101), (1, 0, 0), (0, 1, 0), 0.12, 0.03)
    stage = Model()
    lathe(stage, "Metal", [(0.075, -0.2), (0.075, 0.21)], segs=20, uv_m=3.0)
    flange(stage, "Metal", 0.2, 0.22, 0.0, 0.085)
    head = Model()
    lathe(head, "Chrome", [(0.05, -0.2), (0.05, 0.2)], segs=18, uv_m=3.0)
    flange(head, "Metal", 0.2, 0.25, 0.0, 0.16)
    return base, stage, head


def part_rotor():
    """Rotor 0.6 × 0.3: a drum housing and the turntable "Head" on top."""
    base = Model()
    flange(base, "Anodised", -0.15, 0.0, 0.0, 0.3, uv_m=3.0)
    bolt_ring(base, "Dark", -0.075, 0.3, 16, size=0.008, height=0.006, radial=True)
    box(base, "Dark", (0.0, -0.075, 0.3), (0.14, 0.08, 0.04), uv_m=4.0)
    head = Model()
    flange(head, "Metal", 0.0, 0.15, 0.0, 0.28, uv_m=3.0)
    bolt_ring(head, "Dark", 0.15, 0.2, 8, size=0.012, height=0.008)
    flat_decal(head, "Decal", "hazard", (0.0, 0.075, 0.2811), (1, 0, 0), (0, 1, 0), 0.2, 0.04)
    return base, head


def part_claw():
    """Landing claw 0.7 × 0.6: a hub that mounts under a stack, three hooked
    fingers (the "Fingers" child) that open when armed and bite when they
    close."""
    hub = Model()
    flange(hub, "Metal", 0.22, 0.3, 0.0, 0.3)
    lathe(hub, "Anodised", [(0.22, 0.22), (0.16, -0.05)], segs=32, uv_m=2.0)
    disk(hub, "Dark", 0.16, -0.05, segs=24, up=False)
    bolt_ring(hub, "Dark", 0.26, 0.3, 18, size=0.007, height=0.006, radial=True)
    fing = Model()
    for k in range(3):
        a = TAU * k / 3
        c, s = math.cos(a), math.sin(a)
        pts = [(0.12, -0.02), (0.26, -0.12), (0.32, -0.26), (0.3, -0.4), (0.22, -0.48)]
        for (r0, y0), (r1, y1) in zip(pts, pts[1:]):
            tube(fing, "Dark", (r0 * c, y0, r0 * s), (r1 * c, y1, r1 * s), 0.035, segs=8)
        tube(fing, "Chrome", (0.22 * c, -0.48, 0.22 * s), (0.14 * c, -0.5, 0.14 * s), 0.025, segs=8, r1=0.004)
    # centred in its 0.8 m box: the mount face at +0.4, the finger tips at −0.4
    h2, f2 = Model(), Model()
    h2.merge(hub, None, (0, 0.1, 0))
    f2.merge(fing, None, (0, 0.1, 0))
    return h2, f2


def part_drill():
    """Core drill 0.4 × 1.0 × 0.4 for a flank (radial_orient): a bracket on the
    hull (−X), the yellow drive housing, and the auger "Bit" pointing down,
    which lowers 0.5 m when deployed and spins while drilling."""
    m = Model()
    box(m, "Anodised", (-0.18, 0.2, 0), (0.04, 0.4, 0.3), uv_m=3.0)
    box(m, "Yellow", (0.02, 0.28, 0), (0.3, 0.44, 0.3), uv_m=2.0)
    tube(m, "Dark", (0.02, 0.5, 0), (0.02, 0.56, 0), 0.08, segs=16)  # motor cap (top)
    tube(m, "Metal", (0.02, 0.06, 0), (0.02, -0.12, 0), 0.09, segs=18)  # chuck sleeve
    flat_decal(m, "Decal", "hazard", (0.02, 0.12, 0.151), (1, 0, 0), (0, 1, 0), 0.28, 0.05)
    flat_decal(m, "Stencil", "nostep", (0.171, 0.36, 0), (0, 0, -1), (0, 1, 0), 0.26, 0.032)
    bit = Model()
    tube(bit, "Chrome", (0, 0.0, 0), (0, -0.55, 0), 0.035, segs=12)
    # auger flight: a helix of small segments
    n = 40
    for k in range(n):
        a0, a1 = k * 0.6, (k + 1) * 0.6
        y0, y1 = -0.04 - 0.5 * k / n, -0.04 - 0.5 * (k + 1) / n
        tube(bit, "Chrome", (0.06 * math.cos(a0), y0, 0.06 * math.sin(a0)), (0.06 * math.cos(a1), y1, 0.06 * math.sin(a1)),
             0.012, segs=5)
    tube(bit, "Dark", (0, -0.55, 0), (0, -0.62, 0), 0.04, segs=10, r1=0.004)
    # centred in its 1.2 m box (−0.6 … +0.6)
    m2, b2 = Model(), Model()
    m2.merge(m, None, (0, 0.03, 0))
    b2.merge(bit, None, (0, 0.03, 0))
    return m2, b2


def recenter(model):
    mn, mx = model.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(model, None, -c)
    return out, c


def prefab_node(name, glb, model, t, parent, rot=(0.0, 0.0, 0.0, 1.0), extra=""):
    tx, ty, tz = (round(float(v), 4) for v in t)
    return f"""    (
        name: "{name}",
        transform: (
            translation: ({tx}, {ty}, {tz}),
            rotation: {rot},
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/parts/{glb}.glb",
        ),
        {object_materials(model)}
        scripts: [],{extra}
        parent: Some({parent}),
    ),
"""


def rb_ron(half, mass, kinematic=True, sphere=None, friction=0.6, rotates=False):
    hx, hy, hz = half
    if sphere:
        return (f"""        rigidbody: Some((
            mode: {"Kinematic" if kinematic else "Dynamic"},
            radius: {sphere},
            height: 2.0,
            half_extents: ({sphere}, {sphere}, {sphere}),
            restitution: 0.0,
            friction: {friction},
            gravity: true,{chr(10) + "            rotates: true," if rotates else ""}
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: {mass},
        )),
""")
    return f"""        rigidbody: Some((
            boxed: true,
            mode: Kinematic,
            radius: {max(hx, hz)},
            height: {2 * hy},
            half_extents: ({hx}, {hy}, {hz}),
            restitution: 0.05,
            friction: {friction},
            gravity: true,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: {mass},
        )),
"""


def write_prefab(prefab, comment, root_mesh, half, mass, children=(), root_extra="", friction=0.6,
                 tail_nodes=""):
    """A whole part prefab: the root (its own mesh when `root_mesh` is a
    centred (glb, model) pair, else an Empty) with the box collider, then
    the child meshes [(name, glb, model, translation[, rotation])]."""
    if root_mesh:
        glb, model = root_mesh
        matter = f'matter: Mesh(\n            asset_path: "models/parts/{glb}.glb",\n        ),\n        {object_materials(model)}'
    else:
        matter = "matter: Empty,"
    body = f"""// {comment}
// Written by tools/gen_part_meshes.py (write_prefab) — edit the generator, not this file.
[
    (
        name: "{prefab}",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        {matter}
        scripts: [],{root_extra}
{rb_ron(half, mass, friction=friction)}    ),
"""
    for ch in children:
        name, glb, model, t = ch[0], ch[1], ch[2], ch[3]
        rot = ch[4] if len(ch) > 4 else (0.0, 0.0, 0.0, 1.0)
        par = ch[5] if len(ch) > 5 else 0
        body += prefab_node(name, glb, model, t, par, rot)
    body += tail_nodes
    body += "]\n"
    open(os.path.join(PREFABS, prefab + ".prefab.ron"), "w").write(body)


def build_new_parts(dry=False, only=()):
    """Write every round-two part: meshes into models/parts/, prefabs whole."""
    ok = True

    def mesh(key, model):
        nonlocal ok
        model, c = recenter(model)
        write_glb(model, os.path.join(MODELS, key + ".glb"))
        mn, mx = model.bounds()
        print(f"{key:14s} size {np.round(mx - mn, 3)} offset {np.round(c, 3)} tris {model.tris()}")
        return model, c

    def want(k):
        return not only or k in only

    # STRUCTURE — simple centred meshes on the root.
    simple = [
        ("strut1", part_strut(1.0), "PartStrut1", (0.07, 0.5, 0.07), 0.012, "1 m square strut"),
        ("strut2", part_strut(2.0), "PartStrut2", (0.07, 1.0, 0.07), 0.024, "2 m square strut"),
        ("strut3", part_strut(3.0), "PartStrut3", (0.07, 1.5, 0.07), 0.036, "3 m square strut"),
        ("beam1", part_beam(1.0), "PartBeam1", (0.12, 0.5, 0.07), 0.02, "1 m box beam"),
        ("beam2", part_beam(2.0), "PartBeam2", (0.12, 1.0, 0.07), 0.04, "2 m box beam"),
        ("ibeam2", part_ibeam(2.0), "PartIBeam2", (0.12, 1.0, 0.13), 0.06, "2 m I-beam"),
        ("ibeam3", part_ibeam(3.0), "PartIBeam3", (0.12, 1.5, 0.13), 0.09, "3 m I-beam"),
        ("panel1", part_panel(1.0, 1.0), "PartPanel1", (0.5, 0.02, 0.5), 0.025, "1 × 1 m panel"),
        ("panel2", part_panel(2.0, 1.0), "PartPanel2", (1.0, 0.02, 0.5), 0.05, "2 × 1 m panel"),
        ("panel3", part_panel(2.0, 2.0), "PartPanel3", (1.0, 0.02, 1.0), 0.1, "2 × 2 m panel"),
        ("plate", part_plate, "PartPlate", (0.5, 0.05, 0.5), 0.06, "1 m deck plate"),
        ("hub", part_hub, "PartHub", (0.12, 0.12, 0.12), 0.008, "strut hub"),
        ("adapter", part_adapter, "PartAdapter", (0.5, 0.25, 0.5), 0.05, "1.0 → 0.5 m adapter"),
        ("fairing_s", part_fairing_base(0.625), "PartFairingS", (0.625, 0.1, 0.625), 0.08, "1.25 m fairing base"),
        ("fairing_m", part_fairing_base(1.25), "PartFairingM", (1.25, 0.1, 1.25), 0.2, "2.5 m fairing base"),
    ]
    for key, fn, prefab, half, mass, what in simple:
        if not want(key):
            continue
        model, c = mesh(key, fn())
        ok &= bool(np.all(np.abs(c) < 0.004)) or print(f"  !! {key} is off-centre {c}") or False
        if dry:
            continue
        tail = ""
        write_prefab(prefab, f"{what.upper()} — round-two part.", (key, model), half, mass, tail_nodes=tail)

    # DRAWN PARTS (builder_proc.lua): an Empty root with the box collider at
    # its 1 m default. The mesh is built at runtime from the blueprint's
    # `size` (builder_proc.dress) and the collider's half-extents are written
    # from it before the vessel's assembly.rebuild, so one prefab serves every
    # length and profile.
    if want("proc"):
        for prefab, half, mass, what in (
                ("PartMember", (0.12, 0.5, 0.07), 0.02, "DRAWN MEMBER — any length and profile (size.len, size.prof)"),
                ("PartPanelP", (0.5, 0.02, 0.5), 0.025, "DRAWN PANEL — any size (size.w, size.d, size.t)"),
                ("PartBrace", (0.035, 0.5, 0.035), 0.004, "BRACE — a two-point strut (size.len)")):
            if not dry:
                write_prefab(prefab, what + "; meshed by scripts/builder_proc.lua.", None, half, mass)
            print(f"{prefab:14s} procedural (builder_proc)")

    # ROVER BODY — the deck kit stands proud of the box, so its mesh is a
    # recentred child; the headlights' Lamp rides the root.
    if want("rover_body"):
        model, c = mesh("rover_body", part_rover_body())
        if not dry:
            write_prefab("PartRoverBody", "ROVER BODY — a probe core, battery and whip in a 1.6 × 0.3 × 1.0 chassis;"
                         " its FRONT is +X (headlights).", None, (0.8, 0.15, 0.5), 0.35,
                         children=[("Body", "rover_body", model, c)], tail_nodes="""    (
        name: "Lamp",
        transform: (
            translation: (1.0, 0.05, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: (1.0, 0.94, 0.82),
            intensity: 0.0,
            range: 18.0,
        ),
        scripts: [],
        parent: Some(0),
    ),
""")

    # WHEELS — root = bracket (recentred child), "Tyre" child; and the live
    # tyre body each wheel spins up in flight (WheelTyreS/M/L).
    for size, mass, tmass in (("S", 0.03, 0.012), ("M", 0.06, 0.025), ("L", 0.12, 0.05)):
        key = "wheel_" + size.lower()
        if not want(key):
            continue
        r, w, b, rx, tx = wheel_dims(size)
        br, ty = part_wheel(size)()
        bm, bc = mesh(key + "_mount", br)
        tm, tc = mesh(key + "_tyre", ty)
        if dry:
            continue
        write_prefab("PartWheel" + size, f"POWERED WHEEL {size} — r {r} m, on a flank (+X = the axle, out)."
                     " The Tyre child hides while the live tyre body rolls.",
                     None, (rx, r, r), mass,
                     children=[("Mount", key + "_mount", bm, bc), ("Tyre", key + "_tyre", tm, tc)])
        # The rolling tyre: a sphere body; its mesh turned so the axle is local Z
        # (the chassis's Z — the engine's wheel joint turns about it).
        q = (0.0, -0.7071068, 0.0, 0.7071068)
        body = f"""// LIVE TYRE {size} — spawned by vessel_controller under a powered wheel in flight
// and hung from the chassis on a wheel joint. Written by tools/gen_part_meshes.py.
[
    (
        name: "WheelTyre{size}",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
{rb_ron(None and 0 or (r, r, r), tmass, kinematic=True, sphere=r, friction=1.0, rotates=True)}    ),
{prefab_node("TyreMesh", key + "_tyre", tm, (0, 0, 0), 0, q)}]
"""
        open(os.path.join(PREFABS, f"WheelTyre{size}.prefab.ron"), "w").write(body)

    # ROBOTICS
    if want("hinge"):
        base, head = part_hinge()
        bm, bc = mesh("hinge_base", base)
        hm, hc = mesh("hinge_head", head)
        if not dry:
            write_prefab("PartHinge", "SERVO HINGE — the Head child turns about the pin (local Z through the centre).",
                         None, (0.2, 0.2, 0.2), 0.06,
                         children=[("Base", "hinge_base", bm, bc), ("Head", "hinge_head", hm, hc)])
    if want("piston"):
        base, stage, head = part_piston()
        bm, bc = mesh("piston_base", base)
        sm, sc = mesh("piston_stage", stage)
        hm, hc = mesh("piston_head", head)
        if not dry:
            write_prefab("PartPiston", "PISTON — Stage and Head slide up along +Y as it extends (0–0.8 m).",
                         None, (0.16, 0.25, 0.16), 0.08,
                         children=[("Base", "piston_base", bm, bc), ("Stage", "piston_stage", sm, sc),
                                   ("Head", "piston_head", hm, hc)])
    if want("rotor"):
        base, head = part_rotor()
        bm, bc = mesh("rotor_base", base)
        hm, hc = mesh("rotor_head", head)
        if not dry:
            write_prefab("PartRotor", "ROTOR — the Head turntable spins about local +Y.",
                         None, (0.3, 0.15, 0.3), 0.1,
                         children=[("Base", "rotor_base", bm, bc), ("Head", "rotor_head", hm, hc)])
    if want("claw"):
        hub, fing = part_claw()
        hm, hc = mesh("claw_hub", hub)
        fm, fc = mesh("claw_fingers", fing)
        if not dry:
            write_prefab("PartClaw", "LANDING CLAW — mounts under a stack; the Fingers open when armed.",
                         None, (0.35, 0.4, 0.35), 0.09,
                         children=[("Hub", "claw_hub", hm, hc), ("Fingers", "claw_fingers", fm, fc)])
    if want("drill"):
        body, bit = part_drill()
        dm, dc = mesh("drill_body", body)
        bm, bc = mesh("drill_bit", bit)
        if not dry:
            write_prefab("PartDrill", "CORE DRILL — on a flank (+X out); the Bit lowers 0.5 m and spins.",
                         None, (0.2, 0.6, 0.2), 0.12,
                         children=[("Housing", "drill_body", dm, dc), ("Bit", "drill_bit", bm, bc)])
    if want("solar"):
        yoke, wing = part_solar()
        ym, yc = mesh("solar", yoke)
        wm, wc = mesh("solar_wing", wing)
        if not dry:
            pivot = f"""    (
        name: "SolarWingPivot",
        transform: (
            translation: ({SOLAR_HINGE_X}, 0.0, 0.0),
            // Deployed (yaw 0). Flight folds it to yaw +90° — the wing flat
            // along the hull, cells out — and swings it open (vessel_controller).
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
    ),
{prefab_node("SolarWing", "solar_wing", wm, wc, 2)}"""
            write_prefab("PartSolar", "SOLAR PANEL — a radial blade (+X out off the flank, like a fin): a Yoke on"
                         " the hull and a cell Wing hinged to it (SolarWingPivot). Flight folds the wing"
                         " flat along the hull for launch and swings it open on Deploy (U).",
                         None, (0.45, 0.34, 0.05), 0.05,
                         children=[("SolarYoke", "solar", ym, yc)], tail_nodes=pivot)
    return ok


# ── AIRCRAFT (scripts/parts_aero.lua) ────────────────────────────────────────
# The lifting surfaces are RADIAL parts: +X is the span (the root on the
# host's flank at −X), +Y the chord with the LEADING EDGE at +Y, the faces
# ±Z. Their sections are symmetric (NACA 00xx), so a copy a ring or a mirror
# turns over looks the same. A control surface's moving part hangs off an
# Empty laid along its hinge line ("FlapHinge", rotated about Z so its own X
# is the hinge) through a "FlapPivot" the flight turns about X; an all-moving
# surface turns its "SurfacePivot". Landing gear folds about "GearPivot".
# python3 tools/gen_part_meshes.py aero      (or a single key, e.g. wing_l)

def naca_z(t, x):
    """Half-thickness of a NACA 00xx section of unit chord at x (0 = leading edge)."""
    x = min(max(x, 0.0), 1.0)
    return 5 * t * (0.2969 * math.sqrt(x) - 0.1260 * x - 0.3516 * x ** 2 + 0.2843 * x ** 3 - 0.1036 * x ** 4)


def naca_dz(t, x):
    x = min(max(x, 1e-4), 1.0)
    return 5 * t * (0.2969 * 0.5 / math.sqrt(x) - 0.1260 - 2 * 0.3516 * x + 3 * 0.2843 * x ** 2 - 4 * 0.1036 * x ** 3)


def wing_shell(m, span, root, tip, lsw, le, t=0.09, c0=0.0, c1=1.0, x0=None, mat="Paint2",
               lead="Metal", n=9, root_cap="Metal", decals=True):
    """A straight-tapered panel between chord fractions c0 and c1 (the part
    ahead of a hinge, or the flap behind it): the section is lofted from the
    root (x0) to the tip (x0 + span). UV in metres (u along the span, v along
    the chord) so the paint's panel lines keep their size."""
    if x0 is None:
        x0 = -span / 2
    xs = [c0 + (c1 - c0) * 0.5 * (1 - math.cos(math.pi * i / n)) for i in range(n + 1)]

    def station(f):
        c = root + (tip - root) * f
        return x0 + span * f, le - lsw * f, c

    for sgn in (1, -1):
        for i in range(n):
            xa, xb = xs[i], xs[i + 1]
            mt = lead if (lead and xb <= 0.1 + 1e-9 and c0 < 0.05) else mat
            P, N, UV = [], [], []
            for f in (0.0, 1.0):
                X, yle, c = station(f)
                for x in (xa, xb):
                    y = yle - x * c
                    z = sgn * naca_z(t, x) * c
                    if x < 1e-6:
                        nn = (0.0, 1.0, 0.0)
                    else:
                        d = naca_dz(t, x)
                        l = math.hypot(d, 1.0)
                        nn = (0.0, d / l, sgn / l)
                    P.append((X, y, z)); N.append(nn); UV.append((X, -y))
            # quad: (root,xa) (root,xb) (tip,xb) (tip,xa)
            m.add(mt, P, N, UV, [(0, 1, 3), (0, 3, 2)])
    # caps: the root and the tip, and the blunt hinge face of a panel ahead of a flap
    for f, mt, nx in ((0.0, root_cap, -1.0), (1.0, mat, 1.0)):
        X, yle, c = station(f)
        P, N, UV, I = [], [], [], []
        ring = [(yle - x * c, naca_z(t, x) * c) for x in xs] + [(yle - x * c, -naca_z(t, x) * c) for x in reversed(xs[1:-1])]
        cy = sum(p[0] for p in ring) / len(ring)
        P.append((X, cy, 0.0)); N.append((nx, 0, 0)); UV.append((cy, 0))
        for (y, z) in ring:
            P.append((X, y, z)); N.append((nx, 0, 0)); UV.append((-y, z))
        k = len(ring)
        for i in range(k):
            I.append((0, 1 + i, 1 + (i + 1) % k))
        m.add(mt, P, N, UV, I)
    if c1 < 0.999 or c0 > 0.001:
        for cc in ([c1] if c1 < 0.999 else []) + ([c0] if c0 > 0.001 else []):
            P, N, UV = [], [], []
            for f in (0.0, 1.0):
                X, yle, c = station(f)
                y = yle - cc * c
                h = naca_z(t, cc) * c
                ny = -1.0 if cc == c1 else 1.0
                for z in (h, -h):
                    P.append((X, y, z)); N.append((0, ny, 0)); UV.append((X, z))
            m.add("Dark", P, N, UV, [(0, 1, 3), (0, 3, 2)])
    if decals and c0 < 0.05 and span > 0.9:
        X, yle, c = station(0.32)
        xm = 0.35 if c1 > 0.6 else 0.5 * c1
        y = yle - xm * c
        zt = naca_z(t, xm) * c
        w = min(0.32, 0.22 * span)
        flat_decal(m, "Stencil", "nostep", (X, y, zt + 0.002), (1, 0, 0), (0, 1, 0), w)
        flat_decal(m, "Stencil", "nostep", (X, y, -zt - 0.002), (-1, 0, 0), (0, 1, 0), w)


def wing_root_block(m, span, root, le, t, x0=None):
    """The fitting that bolts a panel to its host: a machined block along the
    root chord, inside the panel's own thickness."""
    if x0 is None:
        x0 = -span / 2
    box(m, "Metal", (x0 + 0.025, le - root / 2, 0.0), (0.05, root * 0.86, 2 * naca_z(t, 0.3) * root * 0.9), uv_m=3.0)


def to_frame(model, origin, theta):
    """Re-express a model in a frame at `origin` turned theta about Z (its X
    along a hinge line)."""
    out = Model()
    out.merge(model, rot_z(-theta), -rot_z(-theta) @ np.asarray(origin, float))
    return out


def quat_z(theta):
    return (0.0, 0.0, round(math.sin(theta / 2), 7), round(math.cos(theta / 2), 7))


def empty_node(name, t, parent, rot=(0.0, 0.0, 0.0, 1.0), comment=""):
    tx, ty, tz = (round(float(v), 4) for v in t)
    cm = f"        // {comment}\n" if comment else ""
    return f"""    (
        name: "{name}",
{cm}        transform: (
            translation: ({tx}, {ty}, {tz}),
            rotation: {rot},
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
    ),
"""


# The planforms, exactly as scripts/parts_aero.lua gives them to the flight:
# span, root chord, tip chord, leading-edge sweep (m at the tip), root LE y,
# thickness ratio, flap chord share (None = fixed, "all" = all-moving).
WINGS = {
    "wing_s":     ("PartWingS",     2.0, 1.0, 1.0, 0.0, 0.5, 0.10, None,  0.03,  "WING PANEL S — 2.0 × 1.0 m"),
    "wing_l":     ("PartWingL",     3.5, 1.6, 1.6, 0.0, 0.8, 0.09, None,  0.07,  "WING PANEL L — 3.5 × 1.6 m"),
    "wing_swept": ("PartWingSwept", 3.0, 1.8, 0.8, 1.2, 1.0, 0.08, None,  0.06,  "SWEPT WING — 3.0 m, 1.8 → 0.8 m chord"),
    "wing_tip":   ("PartWingTip",   1.2, 0.8, 0.3, 0.5, 0.4, 0.08, None,  0.012, "WING TIP — 1.2 m, tapered and swept"),
    "wing_delta": ("PartWingDelta", 2.4, 3.0, 0.4, 2.4, 1.5, 0.06, None,  0.07,  "DELTA WING — 2.4 m span, 3.0 m root"),
    "elevon":     ("PartElevon",    1.6, 1.0, 0.6, 0.4, 0.5, 0.09, 0.35,  0.025, "ELEVON PANEL — tail plane with a 35 % elevon"),
    "aileron":    ("PartAileron",   2.0, 1.2, 1.2, 0.0, 0.6, 0.10, 0.30,  0.035, "AILERON PANEL — wing panel with a 30 % aileron"),
    "tail_fin":   ("PartTailFin",   1.5, 1.5, 0.7, 0.8, 0.75, 0.09, 0.35, 0.03,  "TAIL FIN — fin with a 35 % rudder"),
    "canard":     ("PartCanard",    1.0, 0.6, 0.4, 0.2, 0.3, 0.09, "all", 0.012, "CANARD — all-moving"),
}


def build_wing(key, dry, mesh):
    prefab, span, root, tip, lsw, le, t, flap, mass, what = WINGS[key]
    x0 = -span / 2
    half = (span / 2, max(le, root / 2), max(0.02, naca_z(t, 0.3) * root))
    children, tail = [], ""
    if flap is None:
        m = Model()
        wing_shell(m, span, root, tip, lsw, le, t)
        wing_root_block(m, span, root, le, t)
        pm, pc = mesh(key, m)
        children.append(("Panel", key, pm, pc))
    elif flap == "all":
        # the mount stays on the hull, the blade turns about its quarter chord
        ym = le - root * 0.25
        blade = Model()
        wing_shell(blade, span - 0.06, root, tip, lsw * (span - 0.06) / span, le, t, x0=x0 + 0.06, root_cap="Paint2")
        bm = to_frame(blade, (0.0, ym, 0.0), 0.0)
        mount = Model()
        box(mount, "Metal", (x0 + 0.03, ym, 0.0), (0.06, root * 0.5, 2 * naca_z(t, 0.3) * root * 1.1), uv_m=3.0)
        tube(mount, "Chrome", (x0 + 0.02, ym, 0.0), (x0 + 0.1, ym, 0.0), 0.012, segs=8, uv_m=6.0)
        mm, mc = mesh(key + "_mount", mount)
        bmm, bmc = mesh(key + "_blade", bm)
        children.append(("Mount", key + "_mount", mm, mc))
        tail = empty_node("SurfacePivot", (0.0, ym, 0.0), 0, comment="turned about X by the flight (the surface's deflection)")
        tail += prefab_node("Blade", key + "_blade", bmm, bmc, 2)
    else:
        hinge = 1.0 - flap
        main = Model()
        wing_shell(main, span, root, tip, lsw, le, t, c0=0.0, c1=hinge)
        wing_root_block(main, span, root * hinge, le, t)
        fl = Model()
        # the flap is a hair narrower than the panel so it clears the root block
        wing_shell(fl, span - 0.05, root, tip, lsw * (span - 0.05) / span, le, t, c0=hinge, c1=1.0,
                   x0=x0 + 0.05, mat="Paint3", lead=None, root_cap="Paint3", decals=False)
        # the hinge line, root to tip, and an Empty laid along it
        h0 = np.array([x0, le - hinge * root, 0.0])
        h1 = np.array([x0 + span, le - lsw - hinge * tip, 0.0])
        th = math.atan2(h1[1] - h0[1], h1[0] - h0[0])
        hm = (h0 + h1) / 2
        flm = to_frame(fl, hm, th)
        pm, pc = mesh(key, main)
        fm, fc = mesh(key + "_flap", flm)
        children.append(("Panel", key, pm, pc))
        tail = empty_node("FlapHinge", hm, 0, quat_z(th), comment="along the hinge line (its +X); never moves")
        tail += empty_node("FlapPivot", (0, 0, 0), 2, comment="turned about X by the flight: + = trailing edge toward −Z")
        tail += prefab_node("Flap", key + "_flap", fm, fc, 3)
    if dry:
        return
    write_prefab(prefab, f"{what} — a lifting surface (scripts/parts_aero.lua): +X span from the root at −X,"
                 " leading edge at +Y, faces ±Z.", None, tuple(round(v, 3) for v in half), mass,
                 children=children, tail_nodes=tail)


def part_cockpit():
    """The Swift cockpit: a 1.0 m fuselage nose with a bubble canopy over its
    −Z side (the top), the nose at +Y, the stack flange at −Y."""
    m = Model()
    r = 0.5
    # hull: barrel, then an ogive to a dark radome tip; the canopy opening is
    # left out of the skin (cells facing −Z between y −0.55 and 0.75)
    prof = [(r, -1.1), (r, -1.05), (r, -0.55)]
    ys = np.linspace(-0.55, 1.0, 12)
    for y in ys[1:]:
        u = max(0.0, (y + 0.1) / 1.18)
        prof.append((r * (1 - min(1, u) ** 2.2) ** 0.62 if y > -0.1 else r, y))
    hole_lo, hole_hi = 1, 1 + 8
    seg = 48

    def skip(i, k):
        a = TAU * (i + 0.5) / seg
        da = abs(((a - FRONT) + math.pi) % TAU - math.pi)
        return hole_lo + 1 <= k <= hole_hi - 1 and da < 0.62
    lathe(m, "Paint", prof[:-2], segs=seg, uv_m=1.0, smooth=True, skip=skip)
    lathe(m, "Dark", prof[-3:] + [(0.02, 1.08), (0.0, 1.1)], segs=seg, smooth=True, uv_m=2.0)
    flange(m, "Metal", -1.1, -1.05, r - 0.04, r, uv_m=2.0)
    disk(m, "Metal", r - 0.04, -1.1, segs=seg, up=False, uv_m=2.0)
    # canopy: the upper half of an ellipsoid standing out of the opening
    cx, cy, cz, ax, ay, az = 0.0, 0.12, -0.28, 0.33, 0.78, 0.42
    P, N, UV, I = [], [], [], []
    nu, nv = 24, 10
    for j in range(nv + 1):
        ph = (math.pi / 2) * j / nv           # 0 at the rim, π/2 at the top
        for i in range(nu + 1):
            th = TAU * i / nu
            ex, ey, ez = math.cos(th) * math.cos(ph), math.sin(th) * math.cos(ph), -math.sin(ph)
            P.append((cx + ax * ex, cy + ay * ey, cz + az * ez))
            nn = np.array([ex / ax, ey / ay, ez / az]); nn /= np.linalg.norm(nn)
            N.append(tuple(nn)); UV.append((i / nu, j / nv))
    for j in range(nv):
        for i in range(nu):
            a_ = j * (nu + 1) + i
            I.append((a_, a_ + 1, a_ + nu + 2)); I.append((a_, a_ + nu + 2, a_ + nu + 1))
    m.add("Glass", P, N, UV, I)
    # the canopy's frame: a bow at the windscreen and a sill along each side
    for k in range(7):
        a0, a1 = math.pi * 0.5 * k / 7, math.pi * 0.5 * (k + 1) / 7
        p0 = (cx, cy + ay * math.cos(a0) * 0.62, cz - az * math.sin(a0) * 1.005)
        p1 = (cx, cy + ay * math.cos(a1) * 0.62, cz - az * math.sin(a1) * 1.005)
    for sx in (-1, 1):
        tube(m, "Dark", (sx * ax * 0.98, cy - ay * 0.95, cz - 0.01), (sx * ax * 0.98, cy + ay * 0.95, cz - 0.01), 0.018, segs=6, uv_m=4.0)
    # the windscreen bow: an arch over the canopy at its front third
    arc = []
    for k in range(9):
        th = math.pi * k / 8
        arc.append((cx + ax * math.cos(th) * 1.01, cy + ay * 0.42, cz - az * 0.91 * math.sin(th) * 1.01))
    for a, b in zip(arc[:-1], arc[1:]):
        tube(m, "Dark", a, b, 0.016, segs=6, caps=False, uv_m=4.0)
    # inside: the tub floor, an ejection seat, a coaming over the panel
    box(m, "Dark", (0.0, 0.05, -0.12), (0.56, 1.3, 0.04), uv_m=3.0)
    box(m, "Anodised", (0.0, -0.32, -0.32), (0.32, 0.12, 0.5), uv_m=3.0)        # seat back
    box(m, "Anodised", (0.0, -0.12, -0.2), (0.32, 0.42, 0.1), uv_m=3.0)         # seat pan
    box(m, "Yellow", (0.0, -0.36, -0.6), (0.1, 0.06, 0.08), uv_m=6.0)           # the handle
    box(m, "Dark", (0.0, 0.62, -0.32), (0.5, 0.18, 0.2), uv_m=3.0)              # panel coaming
    # markings: a flag on each flank, the rescue arrow by the canopy rail
    decal(m, "Decal", "flag", cyl_r(r), RIGHT, -0.75, 0.2)
    decal(m, "Decal", "flag", cyl_r(r), math.pi, -0.75, 0.2)
    decal(m, "Stencil", "rescue", cyl_r(r), RIGHT - 0.55, -0.55, 0.42)
    decal(m, "Stencil", "serial1", cyl_r(r), BACK, -0.85, 0.16)
    return m


def part_fuse_tank():
    m = Model()
    tank_body(m, 2.0, 0.5, "rp1", "serial2")
    return m


def part_turbojet():
    """A turbojet nacelle: the stack flange at +Y, a grey cowl, a hot-section
    band, a convergent nozzle and, inside it, the turbine face and tail cone."""
    m = Model()
    r = 0.5
    flange(m, "Metal", 0.84, 0.9, r - 0.04, r, uv_m=2.0)
    disk(m, "Metal", r - 0.04, 0.9, segs=48, up=True, uv_m=2.0)
    lathe(m, "Paint3", [(r, -0.25), (r, 0.84)], segs=48, uv_m=1.0)
    for yb in (0.55, 0.15):
        lathe(m, "Metal", [(r, yb - 0.012), (r + 0.006, yb - 0.006), (r + 0.006, yb + 0.006), (r, yb + 0.012)], segs=48, uv_m=3.0)
    bolt_ring(m, "Metal", 0.81, r, 28, size=0.008, height=0.006, radial=True)
    flange(m, "Metal", -0.36, -0.25, r - 0.06, r, uv_m=2.0)
    # access panels and the oil-tank bulge on the flank
    box(m, "Metal", (r * 0.97, 0.35, 0.0), (0.04, 0.5, 0.26), uv_m=3.0, bevel=0.01)
    box(m, "Metal", (-r * 0.97, 0.35, 0.0), (0.04, 0.5, 0.26), uv_m=3.0, bevel=0.01)
    # the nozzle: heat-tinted, convergent
    lathe(m, "Bell", [(0.36, -0.9), (0.42, -0.62), (0.47, -0.36)], segs=40, smooth=True, u_tiles=2, v_norm=(0.0, 1.0))
    lathe(m, "Metal", [(0.36, -0.9), (0.375, -0.895), (0.375, -0.88), (0.355, -0.875)], segs=40, smooth=True, uv_m=4.0)
    lathe(m, "BellIn", [(0.345, -0.88), (0.32, -0.55)], segs=40, inward=True, u_tiles=2, v_norm=(1.0, 0.0))
    disk(m, "Dark", 0.32, -0.55, segs=40, up=False, uv_m=2.0)
    # turbine blades and the tail cone
    for k in range(18):
        a = TAU * k / 18
        c, s = math.cos(a), math.sin(a)
        box(m, "Metal", (0.2 * c, -0.555, 0.2 * s), (0.2, 0.01, 0.05), rot_y(-a) @ rot_x(0.4), uv_m=6.0)
    lathe(m, "Dark", [(0.12, -0.55), (0.08, -0.7), (0.0, -0.78)], segs=24, smooth=True, uv_m=3.0)
    decal(m, "Stencil", "nostep", cyl_r(r), FRONT, 0.6, 0.3)
    decal(m, "Decal", "hazard", cyl_r(r), RIGHT, -0.15, 0.4)
    decal(m, "Decal", "hazard", cyl_r(r), math.pi, -0.15, 0.4)
    decal(m, "Stencil", "serial2", cyl_r(r), BACK, 0.62, 0.16)
    return m


def part_intake():
    """A radial ram intake: a duct on the flank (mount face at −X), its mouth
    at +Y facing the flight, a boundary-layer splitter against the hull."""
    m = Model()
    box(m, "Metal", (-0.185, 0.0, 0.0), (0.03, 0.86, 0.46), uv_m=3.0)                 # splitter / mount
    box(m, "Paint2", (0.0, -0.02, 0.0), (0.34, 0.6, 0.42), uv_m=1.0, bevel=0.02)        # duct
    # the mouth: a lip frame round a dark throat
    for (cx_, cz_, sx, sz) in ((0.0, 0.2, 0.36, 0.03), (0.0, -0.2, 0.36, 0.03), (0.165, 0.0, 0.03, 0.43), (-0.165, 0.0, 0.03, 0.43)):
        box(m, "Metal", (cx_, 0.33, cz_), (sx, 0.1, sz), uv_m=4.0)
    box(m, "Dark", (0.0, 0.28, 0.0), (0.3, 0.02, 0.37), uv_m=3.0)
    # the tail fairing tapers into the hull
    lathe_m = Model()
    lathe(lathe_m, "Paint2", [(0.17, 0.0), (0.12, -0.07), (0.04, -0.11)], segs=16, smooth=True, uv_m=2.0)
    m.merge(lathe_m, np.diag([1.0, 1.0, 1.25]), (0.0, -0.32, 0.0))
    flat_decal(m, "Decal", "hazard", (0.171, 0.15, 0.0), (0, 0, -1), (0, 1, 0), 0.38, 0.06)
    return m


def part_intake_cone():
    """A nose intake: an annular cowl round a translating shock cone."""
    m = Model()
    lathe(m, "Paint", [(0.5, -0.5), (0.5, 0.05), (0.47, 0.3), (0.44, 0.42)], segs=48, smooth=True, uv_m=1.0)
    lathe(m, "Metal", [(0.44, 0.42), (0.43, 0.45), (0.41, 0.44)], segs=48, smooth=True, uv_m=4.0)
    lathe(m, "Dark", [(0.41, 0.44), (0.36, 0.1), (0.34, -0.3)], segs=48, inward=True, uv_m=2.0)
    disk(m, "Dark", 0.34, -0.3, segs=48, up=True, uv_m=2.0)
    lathe(m, "Metal", [(0.3, -0.3), (0.3, 0.05), (0.2, 0.28), (0.06, 0.45), (0.0, 0.5)], segs=32, smooth=True, uv_m=2.0)
    flange(m, "Metal", -0.5, -0.45, 0.46, 0.5, uv_m=2.0)
    disk(m, "Metal", 0.46, -0.5, segs=48, up=False, uv_m=2.0)
    decal(m, "Decal", "hazard", cyl_r(0.5), FRONT, -0.2, 0.42)
    decal(m, "Stencil", "serial1", cyl_r(0.5), BACK, -0.3, 0.16)
    return m


GEARS = {
    #       prefab        rx    tyre r  width  h     rz    mass
    "S": ("PartGearS", 0.50, 0.25, 0.14, 0.60, 0.15, 0.035),
    "M": ("PartGearM", 0.75, 0.40, 0.20, 0.95, 0.20, 0.08),
}


def gear_parts(size):
    """A landing-gear leg on a flank (+X out = down off a belly): the mount at
    −X, an oleo strut, a fork round a tyre whose axle is the part's Z. The leg
    hangs from GearPivot (it folds aft, toward −Y); the tyre is the root's
    "Tyre" child (hidden while the live tyre rolls)."""
    prefab, rx, r, w, h, rz, mass = GEARS[size]
    tc = rx - r
    piv = np.array([-rx + 0.05, 0.0, 0.0])
    leg = Model()
    box(leg, "Metal", (-rx + 0.04, 0.0, 0.0), (0.08, 0.22 + r * 0.3, 0.2), uv_m=3.0)
    top, mid = -rx + 0.06, tc - r - 0.02
    tube(leg, "Paint3", (top, 0, 0), (mid, 0, 0), 0.05 + r * 0.06, segs=14, uv_m=3.0)
    tube(leg, "Chrome", (mid, 0, 0), (tc - r * 0.55, 0, 0), 0.032 + r * 0.04, segs=14, uv_m=4.0)
    # torque links on the aft side
    tube(leg, "Metal", ((top + mid) / 2, -0.07, 0), (mid + 0.02, -0.11, 0), 0.012, segs=6, uv_m=6.0)
    tube(leg, "Metal", (mid + 0.02, -0.11, 0), (tc - r * 0.6, -0.05, 0), 0.012, segs=6, uv_m=6.0)
    # the fork: a crown over the tyre and an arm down each side to the axle
    zf = w / 2 + 0.025
    box(leg, "Dark", (tc - r - 0.01, 0.0, 0.0), (0.05, 0.12, 2 * zf + 0.04), uv_m=4.0)
    for sz in (-1, 1):
        box(leg, "Dark", (tc - r * 0.5 - 0.01, 0.0, sz * zf), (r + 0.02, 0.07, 0.025), uv_m=4.0)
    tube(leg, "Metal", (tc, 0, -zf - 0.02), (tc, 0, zf + 0.02), 0.022, segs=10, uv_m=6.0)
    flat_decal(leg, "Decal", "hazard", ((top + mid) / 2, 0.0, 0.05 + r * 0.06 + 0.001), (1, 0, 0), (0, 1, 0), 0.2, 0.04)
    legp = Model()
    legp.merge(leg, None, -piv)
    t0 = Model()
    tyre(t0, r, w)
    ty = Model()
    ty.merge(t0, rot_y(math.pi / 2), (tc, 0, 0))
    return prefab, rx, r, h, rz, mass, piv, legp, ty


def build_gear(size, dry, mesh):
    prefab, rx, r, h, rz, mass, piv, legp, ty = gear_parts(size)
    key = "gear_" + size.lower()
    lm, lc = mesh(key + "_leg", legp)
    tm, tc = mesh(key + "_tyre", ty)
    if dry:
        return
    tail = empty_node("GearPivot", piv, 0, comment="the leg folds about Z (aft, toward −Y) as the gear retracts")
    tail += prefab_node("Leg", key + "_leg", lm, lc, 2)
    write_prefab(prefab, f"LANDING GEAR {size} — r {r} m tyre on a leg; +X out (down off a belly), the axle"
                 " along Z. The Tyre child hides while the live tyre rolls; GearPivot folds the leg.",
                 None, (rx, h / 2, rz), mass, children=[("Tyre", key + "_tyre", tm, tc)], tail_nodes=tail)


AERO_KEYS = ("cockpit", "fuse_tank", "turbojet", "intake", "intake_cone", "gear_s", "gear_m") + tuple(WINGS.keys())


def build_aero_parts(dry=False, only=()):
    """Write every aircraft part (scripts/parts_aero.lua): meshes and prefabs."""
    def mesh(key, model):
        model, c = recenter(model)
        write_glb(model, os.path.join(MODELS, key + ".glb"))
        mn, mx = model.bounds()
        print(f"{key:16s} size {np.round(mx - mn, 3)} offset {np.round(c, 3)} tris {model.tris()}")
        return model, c

    def want(k):
        return not only or k in only

    for key in WINGS:
        if want(key):
            build_wing(key, dry, mesh)
    for size in ("S", "M"):
        if want("gear_" + size.lower()):
            build_gear(size, dry, mesh)
    if want("cockpit"):
        cm, cc = mesh("cockpit", part_cockpit())
        if not dry:
            write_prefab("PartCockpit", "SWIFT COCKPIT — a jet cockpit on a 1.0 m fuselage: nose at +Y, canopy on"
                         " the −Z side (the top, as the pod's window), the stack flange at −Y.",
                         None, (0.5, 1.1, 0.5), 0.35, children=[("Body", "cockpit", cm, cc)])
    simple = [
        ("fuse_tank", part_fuse_tank, "PartFuseTank", (0.5, 1.0, 0.5), 0.12, "FUSELAGE TANK — 2 m of liquid fuel on a 1.0 m fuselage."),
        ("turbojet", part_turbojet, "PartTurbojet", (0.5, 0.9, 0.5), 0.35, "WASP TURBOJET — air-breathing; the flange at +Y, the nozzle at −Y (thrust along +Y)."),
        ("intake", part_intake, "PartIntake", (0.2, 0.45, 0.24), 0.03, "RAM INTAKE — radial (+X out); its mouth at +Y faces the flight."),
        ("intake_cone", part_intake_cone, "PartIntakeCone", (0.5, 0.5, 0.5), 0.06, "SHOCK CONE INTAKE — a nose intake; the cone at +Y."),
    ]
    for key, fn, prefab, half, mass, what in simple:
        if not want(key):
            continue
        model, c = mesh(key, fn())
        if not dry:
            write_prefab(prefab, what, None, half, mass, children=[("Body", key, model, c)])
    if not dry and want("aerolib"):
        open(os.path.join(PREFABS, "AeroLib.prefab.ron"), "w").write("""// AERO LIBRARY — scripts/aero.lua (the aerodynamics) and scripts/parts_aero.lua
// (the aircraft parts). Spawned by vessel_controller and the builder when the
// scene carries no node running them; reached with findScript("aero") /
// findScript("parts_aero"). Written by tools/gen_part_meshes.py.
[
    (
        name: "AeroLib",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [
            (
                kind: "aero",
                enabled: true,
                params: [],
            ),
            (
                kind: "parts_aero",
                enabled: true,
                params: [],
            ),
        ],
    ),
]
""")


ROUND2_KEYS = ("strut1", "strut2", "strut3", "beam1", "beam2", "ibeam2", "ibeam3", "panel1", "panel2",
               "panel3", "plate", "hub", "adapter", "rover_body", "fairing_s", "fairing_m", "wheel_s",
               "wheel_m", "wheel_l", "hinge", "piston", "rotor", "claw", "drill", "solar", "proc")


# ── VISUAL-ONLY VARIANTS (prefabs/vis/) ──────────────────────────────────────
# The builder stand spawns these: the same meshes and materials with every
# rigidbody and script stripped, so 1,000 parts on the stand cost the physics
# nothing (a Kinematic box each cost 58 ms a frame idle at 1,000; design
# §2.2) and nothing on the stand runs flight code. Derived from the flight
# prefabs as they are on disk, so run it after anything that rewrites them:
#     python3 tools/gen_part_meshes.py vis

VIS_DIR = os.path.join(PREFABS, "vis")


def strip_block(src, key):
    """Remove every `key: Some(( … )),` block (balanced parentheses)."""
    out, i = [], 0
    while True:
        j = src.find(key, i)
        if j < 0:
            out.append(src[i:])
            break
        ls = src.rfind("\n", 0, j) + 1
        out.append(src[i:ls])
        k = src.find("(", j)
        depth = 0
        while True:
            if src[k] == "(":
                depth += 1
            elif src[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        e = src.find("\n", k) + 1
        i = e
    return "".join(out)


def strip_scripts(src):
    """Every `scripts: [ … ],` list becomes `scripts: [],`."""
    out, i = [], 0
    while True:
        j = src.find("scripts: [", i)
        if j < 0:
            out.append(src[i:])
            break
        k = src.find("[", j)
        depth = 0
        while True:
            if src[k] == "[":
                depth += 1
            elif src[k] == "]":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        out.append(src[i:j] + "scripts: []")
        i = k + 1
    return "".join(out)


def write_vis_prefabs():
    os.makedirs(VIS_DIR, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(PREFABS)):
        if not (f.startswith("Part") and f.endswith(".prefab.ron")):
            continue
        src = open(os.path.join(PREFABS, f)).read()
        vis = strip_scripts(strip_block(src, "rigidbody: Some(("))
        assert "rigidbody: Some" not in vis, f
        head = ("// VISUAL-ONLY variant of prefabs/" + f + " for the builder stand: no body,"
                " no scripts.\n// Written by tools/gen_part_meshes.py (write_vis_prefabs) — regenerate,"
                " don't edit.\n")
        open(os.path.join(VIS_DIR, f), "w").write(head + vis)
        n += 1
    print(f"vis: {n} visual-only prefabs in prefabs/vis/")


def main():
    dry = "--dry" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(MODELS, exist_ok=True)
    ok = True
    for key, (fn, prefab) in PARTS.items():
        if only and key not in only:
            continue
        model, scale = fn()
        ok &= check_centered(key, model)
        glb = os.path.join(MODELS, key + ".glb")
        write_glb(model, glb, scale)
        interior = None
        if key == "pod":
            cab = part_pod_interior()
            mn, mx = cab.bounds()
            centre = (mn + mx) / 2
            print(f"{'interior':12s} size {np.round(mx - mn, 3)} centre {np.round(centre, 3)} tris {cab.tris()}")
            write_glb(cab, os.path.join(MODELS, "pod_interior.glb"))
            interior = (cab, centre)
        if not dry:
            patch_prefab(prefab, "models/parts/" + key + ".glb", model, interior)
    if not only or "legs" in only:
        legs = {}
        for name, fn in (("leg_hinge", part_leg_hinge), ("leg_upper", part_leg_upper), ("leg_lower", part_leg_lower)):
            legs[name] = fn()
            ok &= check_box(name, legs[name])
            write_glb(legs[name], os.path.join(MODELS, name + ".glb"))
        if not dry:
            patch_legs(legs)
    if not only or "round2" in only or any(k in only for k in ROUND2_KEYS):
        sub = [k for k in only if k in ROUND2_KEYS]
        ok &= build_new_parts(dry, sub)
    if not only or "aero" in only or any(k in only for k in AERO_KEYS + ("aerolib",)):
        sub = [k for k in only if k in AERO_KEYS or k == "aerolib"]
        build_aero_parts(dry, sub)
    if not dry and (not only or "vis" in only):
        write_vis_prefabs()
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
