#!/usr/bin/env python3
"""Generate the procedural plant library: models/flora/*.gltf + *.bin, and the
library table inside scripts/flora_gen.lua.

    python3 tools/gen_flora_tex.py     # the textures (textures/flora/)
    python3 tools/gen_flora.py         # the meshes, one .bin per shape

WHAT THIS IS. A plant generator that runs OFFLINE, because the engine cannot
build a mesh or a texture from Lua at runtime (0.116). Every shape below is
grown from parameters and a seed — branching trunks with tapering, gravitropic
limbs and phyllotaxis, conifer whorls, palm crowns, grass tussocks, fern
rosettes, ribbed cacti, mushroom caps on lathe profiles, crystal prisms, tube
sponges, kelp — and written as glTF that the scatter system instances by the
thousand.

THE FILES. Geometry is shared: `models/flora/<shape>.bin` holds every LOD of
one shape, and `<shape>_l<N>.gltf` is a few hundred bytes of JSON pointing
into it and at the NEUTRAL pictures (tools/gen_flora_tex.py). Colour is not in
the files at all: since engine 0.117 a scatter source takes a `tint`, so
`flora_gen` multiplies the neutral picture into whatever palette suits the
world at runtime (it used to need one file per palette — 2,299 of them).

A TREE is two files per LOD: `<shape>_l<N>.gltf` (the crown) and
`<shape>_bark_l<N>.gltf` (trunk and limbs). A source's tint multiplies every
part of its prop, so a trunk drawn in the crown's source would turn the
crown's colour; `flora_field` draws the trunk from a twin source with the
same seed — the same instances, the same ids — tinted with the bark colour.
Everything else (bushes, reeds, fungus stalks) is one file, all tinted alike.

Samplers are LINEAR with LINEAR_MIPMAP_LINEAR minification: the engine
follows a glTF's own sampler since 0.117 and builds the mip chain, so far
foliage no longer shimmers. A shape that can glow carries the glow map as its
leaf material's emissive texture (emissiveFactor 0, so it is dark unless the
species' source sets `emissive`/`emissiveStrength`).

THE ENGINE RECENTRES every imported model on its bounding-box centre, which
would sink half of every tree into the ground. Each mesh therefore carries two
zero-area anchor triangles at its mirrored extremes, so the box is symmetric
about the root and the root stays at the origin.

Cards (leaves, needles, fronds, blades) are DOUBLE-SIDED as two copies a few
millimetres apart with opposite winding, each carrying the same LIGHTING normal
(away from the crown centre for foliage, up for grass). The engine draws both
faces and flips the normal of a back face, so a single-sided card would light
one side of every leaf as if it faced the ground.
"""
import json
import math
import os
import re
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_flora_tex import (BARKS, BARK_TYPES, NEUTRAL_BARK_MID, NEUTRAL_MID, PALETTES, TILE_NAMES,  # noqa: E402
                            tile_uv)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "models", "flora")
TEXREL = "../../textures/flora/"
LUA = os.path.join(ROOT, "scripts", "flora_gen.lua")
TAU = 2 * math.pi
GOLDEN = math.pi * (3 - math.sqrt(5))
T = {n: i for i, n in enumerate(TILE_NAMES)}


def norm(v):
    v = np.asarray(v, np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def perp(d):
    d = norm(d)
    a = np.array([0.0, 1.0, 0.0]) if abs(d[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
    x = norm(np.cross(a, d))
    return x, np.cross(d, x)


def rot_axis(v, axis, ang):
    axis = norm(axis)
    v = np.asarray(v, np.float64)
    c, s = math.cos(ang), math.sin(ang)
    return v * c + np.cross(axis, v) * s + axis * np.dot(axis, v) * (1 - c)


def dir_from(tilt, az):
    """+Y tilted by `tilt` toward azimuth `az`."""
    st = math.sin(tilt)
    return np.array([st * math.cos(az), math.cos(tilt), st * math.sin(az)])


# ── mesh ────────────────────────────────────────────────────────────────────

class Mesh:
    """Triangles per material ("bark", "leaf"). Winding is CCW-out, set by the
    builders (never auto-flipped: a card's back copy is wound the other way
    on purpose)."""

    def __init__(self):
        self.parts = {}

    def add(self, mat, P, N, UV, I):
        e = self.parts.setdefault(mat, [[], [], [], [], 0])
        P = np.asarray(P, np.float64).reshape(-1, 3)
        e[0].append(P)
        e[1].append(np.asarray(N, np.float64).reshape(-1, 3))
        e[2].append(np.asarray(UV, np.float64).reshape(-1, 2))
        e[3].append(np.asarray(I, np.int64).reshape(-1, 3) + e[4])
        e[4] += len(P)

    def arrays(self):
        out = {}
        for mat, (Ps, Ns, UVs, Is, _) in self.parts.items():
            if Ps:
                out[mat] = (np.vstack(Ps), np.vstack(Ns), np.vstack(UVs), np.vstack(Is))
        return out

    def tris(self):
        return sum(sum(len(i) for i in e[3]) for e in self.parts.values())

    def bounds(self):
        P = np.vstack([np.vstack(e[0]) for e in self.parts.values() if e[0]])
        return P.min(0), P.max(0)

    def anchor(self, every=False):
        """Two zero-area triangles at the mirrored extremes: the bounding box
        becomes symmetric about the root, so the engine's recentring is a no-op
        and the plant stands ON the ground instead of half in it."""
        mn, mx = self.bounds()
        ax = max(abs(mn[0]), abs(mx[0]), 0.05)
        az = max(abs(mn[2]), abs(mx[2]), 0.05)
        ay = max(abs(mn[1]), abs(mx[1]), 0.05)
        mats = list(self.parts) if every else ["leaf" if "leaf" in self.parts else next(iter(self.parts))]
        for mat in mats:
            for s in (-1, 1):
                p = [s * ax, s * ay, s * az]
                self.add(mat, [p, p, p], [[0, 1, 0]] * 3, [[0, 0]] * 3, [[0, 1, 2]])


def tube(m, mat, pts, radii, sides, uv_rect=None, around=1.0, v_per_m=1.0, v0=0.0,
         cap=False, ribs=0, rib_depth=0.0, twist=0.0, flat=1.0):
    """A generalised cylinder along a polyline: parallel-transport frames, so a
    bending limb does not corkscrew. `uv_rect` maps it into one atlas tile
    (u around, v base→tip); without it the UVs tile (bark) — `around` times
    round the circumference and `v_per_m` per metre of length."""
    pts = [np.asarray(p, np.float64) for p in pts]
    n = len(pts)
    if n < 2:
        return
    tang = []
    for i in range(n):
        a = pts[max(0, i - 1)]
        b = pts[min(n - 1, i + 1)]
        tang.append(norm(b - a))
    x, _ = perp(tang[0])
    frames = []
    for i in range(n):
        t = tang[i]
        x = norm(x - t * np.dot(x, t))
        y = np.cross(t, x)
        frames.append((x, y))
    L = [0.0]
    for i in range(1, n):
        L.append(L[-1] + float(np.linalg.norm(pts[i] - pts[i - 1])))
    tot = max(L[-1], 1e-6)
    P, N, UV, I = [], [], [], []
    for i in range(n):
        x, y = frames[i]
        r = radii[i]
        for j in range(sides + 1):
            th = TAU * j / sides + twist * L[i] / tot
            rr = r * (1 + rib_depth * math.cos(th * ribs)) if ribs else r
            dvec = x * math.cos(th) * rr + y * math.sin(th) * rr * flat
            P.append(pts[i] + dvec)
            nn = x * math.cos(th) + y * math.sin(th) / max(flat, 0.2)
            if ribs:
                nn = nn - (x * -math.sin(th) + y * math.cos(th)) * (rib_depth * ribs * math.sin(th * ribs) * 0.5)
            N.append(norm(nn))
            if uv_rect:
                u0, v0r, u1, v1r = uv_rect
                UV.append([u0 + (u1 - u0) * j / sides, v1r - (v1r - v0r) * L[i] / tot])
            else:
                UV.append([around * j / sides, v0 - L[i] * v_per_m])
    for i in range(n - 1):
        for j in range(sides):
            a = i * (sides + 1) + j
            b = a + 1
            c = a + sides + 1
            d = c + 1
            I += [[a, c, b], [b, c, d]]
    m.add(mat, P, N, UV, I)
    if cap:
        # close the far end with a fan (the tip of a cactus arm, a stalk top)
        c0 = len(P)
        x, y = frames[-1]
        t = tang[-1]
        P2 = [pts[-1] + t * radii[-1] * 0.35]
        N2 = [t]
        UV2 = [UV[-1]]
        for j in range(sides + 1):
            th = TAU * j / sides
            P2.append(pts[-1] + (x * math.cos(th) + y * math.sin(th)) * radii[-1])
            N2.append(norm(t + (x * math.cos(th) + y * math.sin(th)) * 0.6))
            UV2.append(UV[(n - 1) * (sides + 1) + j])
        I2 = [[0, j + 1, j + 2] for j in range(sides)]
        m.add(mat, P2, N2, UV2, I2)


def card(m, base, up, right, w, h, uv, lnorm=None, bend=0.0, segs=3, gap=0.004, mat="leaf",
         taper=1.0, curl=0.0):
    """A double-sided textured card standing on `base`, its texture top along
    `up`. `bend` droops the top along the card normal (fronds, blades), `curl`
    cups it across. `lnorm` is the lighting normal (None = the card's own)."""
    up = norm(up)
    right = norm(right - up * np.dot(right, up))
    fn = norm(np.cross(right, up))            # geometric front normal
    u0, v0, u1, v1 = uv
    P, UV = [], []
    for i in range(segs + 1):
        t = i / segs
        wscale = 1.0 - (1.0 - taper) * t
        off = fn * (bend * h * t * t)
        for j in (0, 1, 2):
            s = (j - 1)
            pp = base + up * (h * t) + right * (w * 0.5 * s * wscale) + off + fn * (curl * w * 0.5 * (s * s))
            P.append(pp)
            UV.append([u0 + (u1 - u0) * (j / 2), v1 - (v1 - v0) * t])
    P = np.asarray(P)
    if lnorm is None:
        # follow the bend: per-row normal
        N = []
        for i in range(segs + 1):
            t = i / segs
            nrm = norm(fn - up * (2 * bend * t))
            N += [nrm] * 3
        N = np.asarray(N)
    else:
        N = np.tile(norm(lnorm), (len(P), 1))
    I = []
    for i in range(segs):
        for j in range(2):
            a = i * 3 + j
            b = a + 1
            c = a + 3
            d = c + 1
            I += [[a, b, d], [a, d, c]]     # CCW seen from +fn
    m.add(mat, P, N, UV, I)
    if gap is not None:
        back = P - fn * gap
        Ib = [[t[0], t[2], t[1]] for t in I]
        Nb = N if lnorm is not None else -N
        m.add(mat, back, Nb, UV, Ib)


def lathe(m, mat, prof, sides, center_uv=None, uv_rect=None, polar=False, y_off=0.0):
    """Revolve a profile [(r, y), ...] about +Y. `polar=True` maps the tile as
    seen from above (a mushroom cap): the profile's arc length runs from the
    tile centre to its rim."""
    prof = [(float(r), float(y)) for r, y in prof]
    n = len(prof)
    L = [0.0]
    for i in range(1, n):
        L.append(L[-1] + math.hypot(prof[i][0] - prof[i - 1][0], prof[i][1] - prof[i - 1][1]))
    tot = max(L[-1], 1e-6)
    P, N, UV, I = [], [], [], []
    for i in range(n):
        r, y = prof[i]
        a = prof[max(0, i - 1)]
        b = prof[min(n - 1, i + 1)]
        dr, dy = b[0] - a[0], b[1] - a[1]
        for j in range(sides + 1):
            th = TAU * j / sides
            c, s = math.cos(th), math.sin(th)
            P.append([r * c, y + y_off, r * s])
            nr, ny = dy, -dr          # outward normal of the profile
            ln = math.hypot(nr, ny) or 1.0
            N.append([nr / ln * c, ny / ln, nr / ln * s])
            u0, v0, u1, v1 = uv_rect
            if polar:
                rr = 0.5 * L[i] / tot
                UV.append([(u0 + u1) / 2 + (u1 - u0) * rr * c, (v0 + v1) / 2 + (v1 - v0) * rr * s])
            else:
                UV.append([u0 + (u1 - u0) * j / sides, v1 - (v1 - v0) * L[i] / tot])
    for i in range(n - 1):
        for j in range(sides):
            a = i * (sides + 1) + j
            b = a + 1
            c = a + sides + 1
            d = c + 1
            I += [[a, c, b], [b, c, d]]
    # Winding: make sure faces agree with the normals we computed.
    P_, N_ = np.asarray(P), np.asarray(N)
    I = np.asarray(I)
    fa, fb, fc = P_[I[:, 0]], P_[I[:, 1]], P_[I[:, 2]]
    fnrm = np.cross(fb - fa, fc - fa)
    vn = N_[I[:, 0]] + N_[I[:, 1]] + N_[I[:, 2]]
    flip = (fnrm * vn).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    m.add(mat, P, N, UV, I)


def blob(m, mat, center, radii, uv, sides=8, rings=5, up=(0, 1, 0)):
    """An ellipsoid (a pod, a bulb, a cushion of moss)."""
    cx, cy, cz = center
    P, N, UV, I = [], [], [], []
    u0, v0, u1, v1 = uv
    for i in range(rings + 1):
        ph = math.pi * i / rings
        for j in range(sides + 1):
            th = TAU * j / sides
            d = np.array([math.sin(ph) * math.cos(th), math.cos(ph), math.sin(ph) * math.sin(th)])
            P.append([cx + d[0] * radii[0], cy + d[1] * radii[1], cz + d[2] * radii[2]])
            N.append(norm(d / np.asarray(radii)))
            UV.append([u0 + (u1 - u0) * j / sides, v0 + (v1 - v0) * i / rings])
    for i in range(rings):
        for j in range(sides):
            a = i * (sides + 1) + j
            b = a + 1
            c = a + sides + 1
            d = c + 1
            I += [[a, b, c], [b, d, c]]
    P_, N_ = np.asarray(P), np.asarray(N)
    I = np.asarray(I)
    fa, fb, fc = P_[I[:, 0]], P_[I[:, 1]], P_[I[:, 2]]
    fnrm = np.cross(fb - fa, fc - fa)
    vn = N_[I[:, 0]] + N_[I[:, 1]] + N_[I[:, 2]]
    flip = (fnrm * vn).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    m.add(mat, P, N, UV, I)


def tile(name):
    return tile_uv(T[name])


def half_tile(name, top=True):
    u0, v0, u1, v1 = tile(name)
    mid = (v0 + v1) / 2
    return (u0, v0, u1, mid - 0.002) if top else (u0, mid + 0.002, u1, v1)


# ── branching ───────────────────────────────────────────────────────────────

def limb_path(rng, base, d, length, segs, droop, wiggle, up_bias=0.0):
    """A limb's centreline: starts along `d`, bends under its own weight
    (`droop` > 0 sags, < 0 reaches for the light) and wanders a little."""
    pts = [np.asarray(base, np.float64)]
    cur = norm(d)
    seg = length / segs
    for i in range(segs):
        cur = norm(cur + np.array([0, -droop * (i + 1) / segs + up_bias, 0]) * 0.35
                   + rng.normal(0, wiggle, 3))
        pts.append(pts[-1] + cur * seg)
    return pts


def grow(m, rng, spec, base, d, length, radius, depth, lod, tips, crown_c):
    """Recursive limb growth. `spec` per depth: children, angle, ratio, droop."""
    segs = max(2, int(spec["segs"] - depth - (lod > 0)))
    pts = limb_path(rng, base, d, length, segs, spec["droop"][min(depth, len(spec["droop"]) - 1)],
                    spec.get("wiggle", 0.06), spec.get("up_bias", 0.0) if depth > 0 else 0.0)
    r_tip = radius * spec.get("taper", 0.55)
    radii = [radius + (r_tip - radius) * i / segs for i in range(segs + 1)]
    sides = spec["sides"][min(lod, 2)] if depth == 0 else max(3, spec["sides"][min(lod, 2)] - 2 * depth)
    skip_fine = (lod == 1 and depth >= spec["levels"] - 1) or (lod >= 2 and depth >= 1)
    if not skip_fine or depth == 0:
        if not (lod >= 2 and depth > 0):
            if spec.get("uv_rect"):
                tube(m, "leaf", pts, radii, sides, uv_rect=spec["uv_rect"])
            else:
                tube(m, "bark", pts, radii, sides, around=max(1.0, round(TAU * radius / 0.9)), v_per_m=0.8)
    if depth >= spec["levels"] - 1:
        tips.append((pts, depth))
        return
    kids = spec["children"][depth]
    if lod == 1 and depth == spec["levels"] - 2:
        kids = max(1, int(kids * 0.7))
    start, end = spec["span"][depth]
    az = rng.uniform(0, TAU)
    for k in range(kids):
        f = start + (end - start) * (k + rng.uniform(0.2, 0.8)) / kids
        # point along the limb
        idx = f * segs
        i0 = min(int(idx), segs - 1)
        p = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
        tdir = norm(pts[i0 + 1] - pts[i0])
        az += GOLDEN * spec.get("phyllo", 1.0) + rng.uniform(-0.3, 0.3)
        x, y = perp(tdir)
        side = x * math.cos(az) + y * math.sin(az)
        ang = spec["angle"][depth] * rng.uniform(0.8, 1.2)
        nd = norm(tdir * math.cos(ang) + side * math.sin(ang))
        # crowns grow outward from their middle: bias children away from the axis
        out = p - crown_c
        out[1] = 0
        if np.linalg.norm(out) > 1e-6:
            nd = norm(nd + norm(out) * spec.get("spread", 0.3))
        nl = length * spec["ratio"][depth] * rng.uniform(0.8, 1.15) * (1.15 - 0.35 * f)
        nr = radii[i0] * spec.get("rratio", 0.6)
        grow(m, rng, spec, p, nd, nl, nr, depth + 1, lod, tips, crown_c)


def foliage_on(m, rng, tips, crown_c, tname, size, per_tip, lod, normal_mix=0.7, droop=0.25,
               along=(0.35, 1.0), size_jit=0.25, up_bias=0.3, hang=False, flat=False):
    """Leaf cards along the outer part of every terminal limb, normals away from
    the crown centre so the whole crown shades like one soft volume."""
    uv = tile(tname)
    k = {0: 1.0, 1: 0.5, 2: 0.18}[min(lod, 2)]
    grow_s = {0: 1.0, 1: 1.35, 2: 2.0}[min(lod, 2)]
    for pts, _ in tips:
        n = max(1, int(round(per_tip * k + rng.uniform(-0.3, 0.3))))
        for i in range(n):
            f = along[0] + (along[1] - along[0]) * (i + rng.uniform(0, 1)) / n
            idx = f * (len(pts) - 1)
            i0 = min(int(idx), len(pts) - 2)
            p = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
            tdir = norm(pts[i0 + 1] - pts[i0])
            s = size * grow_s * rng.uniform(1 - size_jit, 1 + size_jit)
            out = norm(p - crown_c + np.array([0, 0.2, 0]))
            if hang:
                up = norm(np.array([0, -1.0, 0]) + rng.normal(0, 0.15, 3))
            elif flat:
                up = norm(tdir * 0.6 + np.array([0, 0.15, 0]) + rng.normal(0, 0.2, 3))
            else:
                up = norm(tdir + out * 0.6 + np.array([0, up_bias, 0]) + rng.normal(0, 0.35, 3))
            right = norm(np.cross(up, out) + rng.normal(0, 0.4, 3))
            if flat:
                right = norm(np.cross(up, np.array([0, 1.0, 0])) + rng.normal(0, 0.2, 3))
            ln = norm(out * normal_mix + np.array([0, 1 - normal_mix, 0]))
            card(m, p - up * s * 0.3, up, right, s, s, uv, lnorm=ln, bend=droop * rng.uniform(0.5, 1.2),
                 segs=1, gap=0.004 if lod == 0 else None)


# ── shapes ──────────────────────────────────────────────────────────────────
# Each returns a Mesh for a given LOD (0 near, 1 mid, 2 far).

def broadleaf(seed, lod, height=9.0, trunk_frac=0.42, crown_w=0.75, levels=4, leaf="broad",
              leaf_size=2.3, per_tip=7, droop=(0.0, 0.15, 0.3, 0.4), angle=(0.7, 0.75, 0.8),
              children=(4, 3, 3), bark_r=0.026, weeping=False, flat_top=False, lean=0.05, multi=1):
    rng = np.random.default_rng(seed)
    m = Mesh()
    tips = []
    crown_c = np.array([0, height * (trunk_frac + (1 - trunk_frac) * 0.5), 0])
    spec = dict(levels=levels, segs=5, sides=(7, 5, 3), children=children,
                angle=angle, ratio=(0.62, 0.6, 0.62), span=((trunk_frac, 0.98), (0.35, 0.95), (0.3, 0.95)),
                droop=droop, wiggle=0.07, spread=0.45 * crown_w, taper=0.5, rratio=0.55)
    for t in range(multi):
        d = norm(dir_from(rng.uniform(0, lean) + (0.25 if multi > 1 else 0), rng.uniform(0, TAU)))
        grow(m, rng, spec, np.array([0, -0.15, 0]), d, height * 0.82, height * bark_r, 0, lod, tips, crown_c)
    if weeping:
        # hanging curtains: cards that hang straight down from each tip
        foliage_on(m, rng, tips, crown_c, leaf, leaf_size, per_tip, lod, hang=True, along=(0.2, 1.0))
    else:
        foliage_on(m, rng, tips, crown_c, leaf, leaf_size, per_tip, lod, flat=flat_top, along=(0.15, 1.0))
    return m


def conifer(seed, lod, height=12.0, base_w=0.32, whorls=12, droop=0.35, bark_r=0.022, needle=1.8,
            per=4, top_bare=0.0, umbrella=False):
    rng = np.random.default_rng(seed)
    m = Mesh()
    lean = rng.normal(0, 0.02, 3)
    trunk = [np.array([0, -0.15, 0]) + np.array([lean[0], 1, lean[2]]) * height * i / 8 for i in range(9)]
    tube(m, "bark", trunk, [height * bark_r * (1 - 0.9 * i / 8) for i in range(9)], (9, 6, 4)[lod],
         around=2, v_per_m=0.8)
    nw = {0: whorls, 1: max(5, whorls * 2 // 3), 2: max(4, whorls // 2)}[lod]
    crown_c = np.array([0, height * 0.55, 0])
    tips = []
    lo = 0.55 if umbrella else 0.18
    for w in range(nw):
        f = lo + (0.96 - lo) * w / nw
        y = height * f
        reach = height * base_w * ((1 - f) ** 0.85 if not umbrella else 0.6 + 0.4 * math.sin(math.pi * (f - lo) / (1 - lo)))
        nb = int(rng.integers(5, 8)) if lod < 2 else 4
        az = rng.uniform(0, TAU)
        for b in range(nb):
            a = az + b * TAU / nb + rng.uniform(-0.3, 0.3)
            d = norm(np.array([math.cos(a), -0.1 if not umbrella else 0.35, math.sin(a)]))
            p0 = np.array([lean[0] * f * height, y, lean[2] * f * height])
            pts = limb_path(rng, p0, d, reach, 3, droop * (0 if umbrella else 1), 0.04)
            if lod < 2:
                tube(m, "bark", pts, [height * bark_r * 0.35 * (1 - f), 0.01, 0.006, 0.004][:len(pts)], 3,
                     around=1, v_per_m=1.5)
            tips.append((pts, 1))
    # needle sprays lie ALONG the limbs, top side up, so a fir reads as layered tiers
    uv = tile("needles")
    k = {0: 1.0, 1: 0.55, 2: 0.25}[lod]
    gs = {0: 1.0, 1: 1.3, 2: 1.9}[lod]
    for pts, _ in tips:
        L = sum(np.linalg.norm(pts[i + 1] - pts[i]) for i in range(len(pts) - 1))
        n = max(1, int(per * k * (0.5 + L / (height * base_w))))
        for i in range(n):
            f = (i + rng.uniform(0.1, 0.9)) / n
            idx = f * (len(pts) - 1)
            i0 = min(int(idx), len(pts) - 2)
            p = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
            tdir = norm(pts[i0 + 1] - pts[i0])
            s = needle * gs * rng.uniform(0.75, 1.2) * (0.6 + 0.4 * min(1, L / (height * 0.2)))
            right = norm(np.cross(tdir, np.array([0, 1.0, 0])) + rng.normal(0, 0.25, 3))
            up = norm(tdir + rng.normal(0, 0.15, 3))
            ln = norm(norm(p - crown_c) * 0.5 + np.array([0, 0.7, 0]))
            card(m, p - up * s * 0.2, up, right, s * 1.1, s, uv, lnorm=ln, bend=0.15, segs=1,
                 gap=0.004 if lod == 0 else None)
            if lod == 0 and rng.uniform() < 0.12:
                right2 = norm(np.cross(tdir, right))
                card(m, p - up * s * 0.2, up, right2, s * 0.8, s * 0.9, uv, lnorm=ln, bend=0.1, segs=1)
    # leader
    top = trunk[-1]
    card(m, top - np.array([0, height * 0.08, 0]), np.array([0, 1.0, 0]), np.array([1.0, 0, 0]),
         needle * 0.9 * gs, height * 0.12, uv, lnorm=np.array([0, 1.0, 0]), segs=1)
    card(m, top - np.array([0, height * 0.08, 0]), np.array([0, 1.0, 0]), np.array([0, 0, 1.0]),
         needle * 0.9 * gs, height * 0.12, uv, lnorm=np.array([0, 1.0, 0]), segs=1)
    return m


def palm(seed, lod, height=8.0, fronds=15, frond_len=4.2, curve=0.6, tree_fern=False):
    rng = np.random.default_rng(seed)
    m = Mesh()
    segs = 10 if lod == 0 else 5
    bend_dir = norm(np.array([math.cos(rng.uniform(0, TAU)), 0, math.sin(rng.uniform(0, TAU))]))
    pts = []
    for i in range(segs + 1):
        f = i / segs
        pts.append(np.array([0, -0.15, 0]) + np.array([0, 1, 0]) * height * f + bend_dir * curve * height * 0.25 * f * f)
    r0 = height * (0.03 if not tree_fern else 0.035)
    tube(m, "bark", pts, [r0 * (1.25 - 0.45 * i / segs) for i in range(segs + 1)], (8, 6, 4)[lod],
         around=2, v_per_m=1.2)
    top = pts[-1]
    tname = "frond" if tree_fern else "palm"
    n = {0: fronds, 1: max(6, fronds * 2 // 3), 2: 6}[lod]
    for k in range(n):
        a = k * GOLDEN * 2.0 + rng.uniform(-0.2, 0.2)
        tilt = rng.uniform(0.35, 1.25)
        out = np.array([math.cos(a), 0, math.sin(a)])
        up = norm(out * math.sin(tilt) + np.array([0, math.cos(tilt), 0]))
        right = norm(np.cross(up, np.array([0, 1.0, 0])) + rng.normal(0, 0.1, 3))
        L = frond_len * rng.uniform(0.8, 1.1)
        ln = norm(out * 0.4 + np.array([0, 0.9, 0]))
        card(m, top, up, right, L * 0.62, L, tile(tname), lnorm=ln, bend=-0.45 if not tree_fern else -0.3,
             segs=4 if lod == 0 else 2, curl=0.15)
    if not tree_fern and lod < 2:
        for k in range(int(rng.integers(3, 6))):
            a = rng.uniform(0, TAU)
            blob(m, "leaf", top + np.array([math.cos(a) * 0.22, -0.25, math.sin(a) * 0.22]), (0.16, 0.18, 0.16),
                 half_tile("stem_moss", False), sides=6, rings=4)
    return m


def bush(seed, lod, height=1.4, width=1.7, leaf="small", leaf2=None, cards=56, stems=6, flat=0.8, card_s=0.75):
    rng = np.random.default_rng(seed)
    m = Mesh()
    c = np.array([0, height * 0.5, 0])
    if lod < 2:
        for s in range(stems if lod == 0 else 3):
            a = rng.uniform(0, TAU)
            d = norm(np.array([math.cos(a) * 0.5, 1, math.sin(a) * 0.5]))
            pts = limb_path(rng, np.array([0, -0.05, 0]), d, height * 0.7, 3, -0.1, 0.1)
            tube(m, "bark", pts, [0.03, 0.022, 0.014, 0.008], 4, around=1, v_per_m=2.0)
    n = {0: cards, 1: cards // 2, 2: max(6, cards // 6)}[lod]
    gs = {0: 1.0, 1: 1.3, 2: 1.9}[lod]
    for i in range(n):
        # points on an ellipsoid shell (a little inside it too)
        u = rng.uniform(-1, 1)
        th = rng.uniform(0, TAU)
        rr = rng.uniform(0.55, 1.0)
        dvec = np.array([math.sqrt(1 - u * u) * math.cos(th), abs(u) * 0.9 + 0.1 if u < -0.2 else u, math.sqrt(1 - u * u) * math.sin(th)])
        p = c + np.array([dvec[0] * width * 0.5, dvec[1] * height * 0.5 * flat, dvec[2] * width * 0.5]) * rr
        p[1] = max(p[1], height * 0.12)
        out = norm(p - c * np.array([1, 0.6, 1]))
        s = card_s * gs * rng.uniform(0.75, 1.25)
        up = norm(out * 0.5 + np.array([0, 1.0, 0]) + rng.normal(0, 0.35, 3))
        right = norm(np.cross(up, out) + rng.normal(0, 0.4, 3))
        t = leaf2 if (leaf2 and rng.uniform() < 0.35) else leaf
        card(m, p - up * s * 0.45, up, right, s, s, tile(t), lnorm=norm(out * 0.7 + np.array([0, 0.5, 0])),
             bend=0.15, segs=1, gap=0.004 if lod == 0 else None)
    return m


def shrub_twiggy(seed, lod, height=1.3, leaf="small", per_tip=2, size=0.4):
    spec_seed = seed
    rng = np.random.default_rng(spec_seed)
    m = Mesh()
    tips = []
    crown_c = np.array([0, height * 0.55, 0])
    spec = dict(levels=3, segs=4, sides=(4, 3, 3), children=(4, 3), angle=(0.6, 0.7),
                ratio=(0.6, 0.6), span=((0.15, 0.9), (0.3, 0.95)), droop=(-0.2, 0.0, 0.2),
                wiggle=0.15, spread=0.6, taper=0.4, rratio=0.6)
    for s in range(3):
        d = dir_from(rng.uniform(0.1, 0.5), rng.uniform(0, TAU))
        grow(m, rng, spec, np.array([0, -0.05, 0]), d, height * 0.8, 0.025, 0, lod, tips, crown_c)
    foliage_on(m, rng, tips, crown_c, leaf, size, per_tip, lod, along=(0.4, 1.0), size_jit=0.35)
    return m


def tussock(seed, lod, height=0.7, width=0.9, cards=5, tname="blades", lean=0.35, flowers=0):
    """A grass clump: cards in a loose star, leaning out, normals UP (grass
    should light like the ground it covers, not like a fence)."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = cards if lod == 0 else max(3, cards * 2 // 3)
    a0 = rng.uniform(0, TAU)
    for i in range(n):
        a = a0 + i * math.pi / n + rng.uniform(-0.25, 0.25)
        right = np.array([math.cos(a), 0, math.sin(a)])
        side = np.cross(right, np.array([0, 1.0, 0]))
        tilt = rng.uniform(-lean, lean)
        up = norm(np.array([0, 1.0, 0]) + side * tilt)
        h = height * rng.uniform(0.75, 1.15)
        off = side * rng.uniform(-0.35, 0.35) * width + right * rng.uniform(-0.25, 0.25) * width
        card(m, off + np.array([0, -0.04, 0]), up, right, width * rng.uniform(0.45, 0.7), h, tile(tname),
             lnorm=norm(np.array([0, 1.0, 0]) + side * 0.15), bend=rng.uniform(0.05, 0.2), segs=2 if lod == 0 else 1)
    for i in range(flowers if lod == 0 else flowers // 2):
        a = rng.uniform(0, TAU)
        right = np.array([math.cos(a), 0, math.sin(a)])
        card(m, right * rng.uniform(0, 0.2), np.array([0, 1.0, 0]), np.cross(right, [0, 1, 0]),
             width * 0.5, height * 0.7, tile("flowers"), lnorm=np.array([0, 1.0, 0]), segs=1)
    return m


def fern(seed, lod, fronds=9, length=1.2, rise=0.9, tname="frond", spread_k=1.0):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = {0: fronds, 1: max(5, fronds * 2 // 3), 2: 4}[lod]
    for k in range(n):
        a = k * GOLDEN * 2 + rng.uniform(-0.2, 0.2)
        tilt = rng.uniform(0.3, 0.75) * spread_k
        out = np.array([math.cos(a), 0, math.sin(a)])
        up = norm(out * math.sin(tilt) + np.array([0, math.cos(tilt) * rise, 0]))
        right = norm(np.cross(up, np.array([0, 1.0, 0])))
        L = length * rng.uniform(0.75, 1.15)
        card(m, np.array([0, -0.03, 0]), up, right, L * 0.55, L, tile(tname),
             lnorm=norm(out * 0.35 + np.array([0, 1.0, 0])), bend=-0.35, segs=3 if lod == 0 else 2, curl=0.1)
    return m


def reeds(seed, lod, height=2.0, stalks=9, heads=True, horsetail=False):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = stalks if lod == 0 else max(4, stalks // 2)
    for i in range(n):
        a, r = rng.uniform(0, TAU), rng.uniform(0, 0.35)
        base = np.array([math.cos(a) * r, -0.05, math.sin(a) * r])
        h = height * rng.uniform(0.7, 1.1)
        d = norm(np.array([math.cos(a) * 0.08, 1, math.sin(a) * 0.08]) + rng.normal(0, 0.03, 3))
        pts = limb_path(rng, base, d, h, 4, 0.05, 0.02)
        tube(m, "leaf", pts, [0.02, 0.017, 0.014, 0.011, 0.008], 4 if lod == 0 else 3, uv_rect=half_tile("stem_moss", True))
        if heads and not horsetail and rng.uniform() < 0.7:
            top = pts[-1]
            hp = [top - d * h * 0.18, top - d * h * 0.02]
            tube(m, "bark", hp, [0.045, 0.04], 5 if lod == 0 else 3, around=1, v_per_m=3, cap=True)
        if horsetail and lod < 2:
            for j in range(1, 4):
                p = pts[j]
                for k in range(6):
                    aa = k * TAU / 6 + j
                    dd = norm(np.array([math.cos(aa), -0.25, math.sin(aa)]))
                    card(m, p, dd, np.cross(dd, [0, 1, 0]) + 1e-3, 0.08, 0.35 * (1 - j * 0.2), tile("needles"),
                         lnorm=np.array([0, 1.0, 0]), segs=1)
    if not horsetail:
        merge(m, tussock(seed + 1, lod, height=height * 0.75, width=0.8, cards=4, tname="blades", lean=0.25))
    return m


def merge(dst, src):
    for k, v in src.parts.items():
        base = 0
        for P, N, UV, I in zip(v[0], v[1], v[2], v[3]):
            dst.add(k, P, N, UV, I - base)
            base += len(P)


def succulent_rosette(seed, lod, leaves=16, length=0.9, width=0.16, rise=0.7):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = {0: leaves, 1: max(8, leaves * 2 // 3), 2: 7}[lod]
    uv = tile("succulent")
    for k in range(n):
        a = k * GOLDEN + rng.uniform(-0.1, 0.1)
        f = k / n
        tilt = 0.25 + 1.1 * f * rise
        out = np.array([math.cos(a), 0, math.sin(a)])
        d = norm(out * math.sin(tilt) + np.array([0, math.cos(tilt), 0]))
        L = length * (1.1 - 0.5 * (1 - f)) * rng.uniform(0.85, 1.1)
        segs = 4 if lod == 0 else 2
        pts = limb_path(rng, np.array([0, 0.02, 0]), d, L, segs, 0.25 * f, 0.0)
        radii = [width * (1 - (i / segs) ** 1.4) + 0.004 for i in range(segs + 1)]
        tube(m, "leaf", pts, radii, 4 if lod < 2 else 3, uv_rect=uv, flat=0.35)
    return m


def cactus(seed, lod, height=3.2, radius=0.22, arms=2, barrel=False):
    rng = np.random.default_rng(seed)
    m = Mesh()
    uv = tile("cactus")
    sides = (16, 10, 6)[lod]
    ribs = 12 if lod == 0 else 0
    if barrel:
        prof = [(0.0, -0.05), (radius * 0.9, 0.0), (radius, radius * 0.5), (radius * 0.95, radius * 1.1),
                (radius * 0.7, radius * 1.5), (radius * 0.25, radius * 1.68), (0.0, radius * 1.7)]
        lathe(m, "leaf", prof, sides, uv_rect=uv)
        return m
    segs = 6 if lod == 0 else 3
    pts = [np.array([0, -0.1 + height * i / segs, 0]) for i in range(segs + 1)]
    tube(m, "leaf", pts, [radius * (1 - 0.15 * (i / segs) ** 3) for i in range(segs + 1)], sides,
         uv_rect=uv, ribs=ribs, rib_depth=0.06, cap=True)
    for k in range(arms):
        a = rng.uniform(0, TAU)
        y0 = height * rng.uniform(0.3, 0.55)
        out = np.array([math.cos(a), 0, math.sin(a)])
        r2 = radius * 0.7
        p0 = np.array([0, y0, 0]) + out * radius * 0.6
        L = height * rng.uniform(0.3, 0.45)
        apts = [p0, p0 + out * L * 0.35 + np.array([0, L * 0.05, 0]), p0 + out * L * 0.45 + np.array([0, L * 0.3, 0]),
                p0 + out * L * 0.48 + np.array([0, L * 0.75, 0]), p0 + out * L * 0.48 + np.array([0, L * 1.0, 0])]
        tube(m, "leaf", apts, [r2] * 5, max(6, sides * 2 // 3), uv_rect=uv, ribs=ribs, rib_depth=0.06, cap=True)
    return m


def pads(seed, lod, count=7, size=0.45):
    """Prickly-pear pads: flattened discs stacked on each other's rims."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    uv = tile("cactus")
    frontier = [(np.array([0, 0.0, 0]), np.array([0, 1.0, 0]))]
    n = {0: count, 1: max(4, count * 2 // 3), 2: 4}[lod]
    made = 0
    while frontier and made < n:
        p, d = frontier.pop(0)
        s = size * rng.uniform(0.8, 1.15)
        c = p + d * s * 0.9
        x, y = perp(d)
        r = x * math.cos(rng.uniform(0, TAU)) + y * math.sin(rng.uniform(0, TAU))
        blob(m, "leaf", (0, 0, 0), (s * 0.75, s, s * 0.18), uv, sides=10 if lod == 0 else 6, rings=6 if lod == 0 else 4)
        # move the last blob into place: rotate +Y→d, spin, translate
        e = m.parts["leaf"]
        P = e[0][-1]
        N = e[1][-1]
        R = np.stack([r, d, np.cross(r, d)], 1)
        e[0][-1] = P @ R.T + c
        e[1][-1] = N @ R.T
        made += 1
        for k in range(int(rng.integers(1, 3))):
            nd = norm(d + r * rng.uniform(-0.9, 0.9) + np.array([0, 0.3, 0]))
            frontier.append((c + d * s * 0.7 + r * rng.uniform(-0.3, 0.3) * s, nd))
    return m


def mushroom(seed, lod, height=1.0, cap_r=0.55, stalk_r=0.08, cap_h=0.35, flat=False, cluster=1,
             spread=0.5, upturn=0.0):
    rng = np.random.default_rng(seed)
    m = Mesh()
    sides = (12 if cluster == 1 else 9, 8, 6)[lod]
    for c in range(cluster if lod < 2 else min(cluster, 3)):
        if c == 0:
            base, s = np.array([0, -0.05, 0]), 1.0
        else:
            a = rng.uniform(0, TAU)
            base = np.array([math.cos(a), 0, math.sin(a)]) * rng.uniform(0.3, 1.0) * spread * height + np.array([0, -0.05, 0])
            s = rng.uniform(0.35, 0.75)
        h = height * s
        d = norm(np.array([base[0], 0, base[2]]) * 0.3 + np.array([0, 1.0, 0]) + rng.normal(0, 0.05, 3))
        segs = 4 if lod == 0 else 2
        pts = limb_path(rng, base, d, h, segs, -0.05, 0.02)
        tube(m, "bark", pts, [stalk_r * s * (1.25 - 0.3 * i / segs) for i in range(segs + 1)], max(5, sides // 2),
             around=1, v_per_m=1.5)
        top = pts[-1]
        R, H = cap_r * s, cap_h * s
        if flat:
            prof = [(0.0, H * 0.35), (R * 0.5, H * 0.32), (R * 0.9, H * 0.15), (R, 0.0 + upturn * H)]
        else:
            prof = [(0.0, H), (R * 0.45, H * 0.92), (R * 0.8, H * 0.6), (R * 0.98, H * 0.18), (R, 0.0 + upturn * H)]
        if lod == 2:
            prof = [prof[0], prof[len(prof) // 2], prof[-1]]
        cap_m = Mesh()
        lathe(cap_m, "leaf", prof, sides, uv_rect=tile("cap"), polar=True)
        under = [(R, upturn * H), (R * 0.6, -H * 0.06), (stalk_r * s, -H * 0.05)]
        lathe(cap_m, "leaf", under, sides, uv_rect=tile("gills"), polar=True)
        e = cap_m.parts["leaf"]
        for i in range(len(e[0])):
            e[0][i] = e[0][i] + top - np.array([0, H * 0.1, 0])
        merge(m, cap_m)
    return m


def shelf_tower(seed, lod, height=4.0, radius=0.35, shelves=7):
    rng = np.random.default_rng(seed)
    m = Mesh()
    segs = 6 if lod == 0 else 3
    pts = limb_path(rng, np.array([0, -0.1, 0]), np.array([0, 1.0, 0]), height, segs, -0.1, 0.03)
    tube(m, "bark", pts, [radius * (1 - 0.6 * i / segs) for i in range(segs + 1)], (10, 7, 5)[lod],
         around=2, v_per_m=0.7, cap=True)
    n = {0: shelves, 1: max(3, shelves * 2 // 3), 2: 3}[lod]
    for k in range(n):
        f = 0.2 + 0.75 * k / n
        idx = f * segs
        i0 = min(int(idx), segs - 1)
        p = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
        R = radius * rng.uniform(1.4, 2.6) * (1.2 - f * 0.5)
        a = rng.uniform(0, TAU)
        out = np.array([math.cos(a), 0, math.sin(a)])
        cap_m = Mesh()
        prof = [(0.0, R * 0.18), (R * 0.6, R * 0.14), (R, 0.0)]
        lathe(cap_m, "leaf", prof, (10, 7, 5)[lod], uv_rect=tile("cap"), polar=True)
        lathe(cap_m, "leaf", [(R, 0.0), (0.0, -R * 0.05)], (10, 7, 5)[lod], uv_rect=tile("gills"), polar=True)
        e = cap_m.parts["leaf"]
        for i in range(len(e[0])):
            P = e[0][i].copy()
            P[:, 2] *= 0.6
            e[0][i] = P + p + out * R * 0.45
        merge(m, cap_m)
    return m


def spire(seed, lod, height=6.0, radius=0.4, twist=3.0, rings=0, tname="coral", horns=1):
    rng = np.random.default_rng(seed)
    m = Mesh()
    for h_ in range(horns):
        if h_ == 0:
            base, s = np.array([0, -0.2, 0]), 1.0
        else:
            a = rng.uniform(0, TAU)
            base = np.array([math.cos(a), 0, math.sin(a)]) * radius * rng.uniform(1.2, 2.2) + np.array([0, -0.2, 0])
            s = rng.uniform(0.4, 0.7)
        segs = 12 if lod == 0 else 6
        d = norm(np.array([base[0], 0, base[2]]) * 0.15 + np.array([0, 1.0, 0]))
        pts = limb_path(rng, base, d, height * s, segs, -0.02, 0.03)
        # gentle S-curve
        side = norm(np.cross(d, [1.0, 0, 0]))
        pts = [p + side * math.sin(i / segs * math.pi * 1.5) * height * s * 0.04 for i, p in enumerate(pts)]
        radii = [radius * s * (1 - (i / segs) ** 0.9) + 0.01 for i in range(segs + 1)]
        tube(m, "leaf", pts, radii, (10, 7, 5)[lod], uv_rect=tile(tname), twist=twist * TAU / 4,
             ribs=5 if lod == 0 else 0, rib_depth=0.12)
        if rings and lod < 2:
            for k in range(rings):
                f = (k + 1) / (rings + 1)
                idx = f * segs
                i0 = min(int(idx), segs - 1)
                p = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
                R = radii[i0] * 1.6
                cap_m = Mesh()
                lathe(cap_m, "leaf", [(R * 0.5, R * 0.2), (R, 0.0), (R * 0.5, -R * 0.12)], (10, 7, 5)[lod],
                      uv_rect=tile("gills"), polar=True)
                e = cap_m.parts["leaf"]
                for i in range(len(e[0])):
                    e[0][i] = e[0][i] + p
                merge(m, cap_m)
    return m


def tubes(seed, lod, count=9, height=2.2, radius=0.16, spread=0.55):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = {0: count, 1: max(4, count * 2 // 3), 2: 4}[lod]
    for i in range(n):
        a, r = rng.uniform(0, TAU), math.sqrt(rng.uniform(0, 1)) * spread
        base = np.array([math.cos(a) * r, -0.08, math.sin(a) * r])
        h = height * rng.uniform(0.45, 1.1) * (1.1 - r / max(spread, 1e-3) * 0.4)
        d = norm(np.array([math.cos(a) * r * 0.4, 1, math.sin(a) * r * 0.4]))
        rr = radius * rng.uniform(0.7, 1.25)
        pts = limb_path(rng, base, d, h, 3, -0.05, 0.03)
        tube(m, "leaf", pts, [rr * 0.85, rr, rr * 1.05, rr * 1.15], (10, 7, 5)[lod], uv_rect=tile("coral"))
        # open mouth: an inner tube, glowing gills inside
        inner = [pts[-1] - d * 0.02, pts[-1] - d * h * 0.2]
        tube(m, "leaf", inner, [rr * 1.1, rr * 0.6], (10, 7, 5)[lod], uv_rect=tile("gills"))
    return m


def crystals(seed, lod, count=7, height=2.2, radius=0.22, spread=0.6):
    rng = np.random.default_rng(seed)
    m = Mesh()
    uv = tile("crystal")
    n = {0: count, 1: max(4, count * 2 // 3), 2: 3}[lod]
    for i in range(n):
        if i == 0:
            base, tilt, s = np.array([0, -0.3, 0]), rng.uniform(0, 0.15), 1.0
        else:
            a = rng.uniform(0, TAU)
            base = np.array([math.cos(a), 0, math.sin(a)]) * rng.uniform(0.2, 1.0) * spread + np.array([0, -0.3, 0])
            tilt, s = rng.uniform(0.25, 0.9), rng.uniform(0.35, 0.8)
        az = math.atan2(base[2], base[0]) if i else rng.uniform(0, TAU)
        d = dir_from(tilt, az)
        h, r = height * s, radius * s
        x, y = perp(d)
        P, N, UV, I = [], [], [], []
        sides = 6
        body_top = base + d * h * 0.78
        tip = base + d * h
        u0, v0, u1, v1 = uv
        for j in range(sides):
            th0, th1 = TAU * j / sides, TAU * (j + 1) / sides
            o0 = x * math.cos(th0) * r + y * math.sin(th0) * r
            o1 = x * math.cos(th1) * r + y * math.sin(th1) * r
            fn = norm(o0 + o1)
            q = [base + o0, base + o1, body_top + o1, body_top + o0]
            k0 = len(P)
            P += q
            N += [fn] * 4
            uu0 = u0 + (u1 - u0) * (j % 4) / 4
            uu1 = uu0 + (u1 - u0) / 4
            UV += [[uu0, v1], [uu1, v1], [uu1, v0 + (v1 - v0) * 0.2], [uu0, v0 + (v1 - v0) * 0.2]]
            I += [[k0, k0 + 1, k0 + 2], [k0, k0 + 2, k0 + 3]]
            # the point
            k1 = len(P)
            tn = norm(fn + d * 0.8)
            P += [body_top + o0, body_top + o1, tip]
            N += [tn] * 3
            UV += [[uu0, v0 + (v1 - v0) * 0.2], [uu1, v0 + (v1 - v0) * 0.2], [(uu0 + uu1) / 2, v0]]
            I += [[k1, k1 + 1, k1 + 2]]
        P_, N_ = np.asarray(P), np.asarray(N)
        I_ = np.asarray(I)
        fa, fb, fc = P_[I_[:, 0]], P_[I_[:, 1]], P_[I_[:, 2]]
        fnrm = np.cross(fb - fa, fc - fa)
        vn = N_[I_[:, 0]] + N_[I_[:, 1]] + N_[I_[:, 2]]
        flip = (fnrm * vn).sum(1) < 0
        I_[flip] = I_[flip][:, [0, 2, 1]]
        m.add("leaf", P, N, UV, I_)
    return m


def coral_tree(seed, lod, height=3.5, radius=0.14, bulbs=True):
    rng = np.random.default_rng(seed)
    m = Mesh()
    tips = []
    crown_c = np.array([0, height * 0.6, 0])
    spec = dict(levels=3 if lod < 2 else 2, segs=5, sides=(8, 6, 4), children=(3, 2), angle=(0.55, 0.6),
                ratio=(0.6, 0.65), span=((0.35, 0.9), (0.4, 0.95)), droop=(-0.3, -0.4, -0.4),
                wiggle=0.1, spread=0.5, taper=0.55, rratio=0.7)
    # Coral limbs wear the atlas, not bark: smooth porous skin.
    spec["uv_rect"] = tile("coral")
    grow(m, rng, spec, np.array([0, -0.1, 0]), np.array([0, 1.0, 0]), height * 0.6, radius, 0, lod, tips, crown_c)
    if bulbs:
        for pts, _ in tips:
            p = pts[-1]
            r = radius * rng.uniform(1.6, 2.6)
            blob(m, "leaf", tuple(p + np.array([0, r * 0.6, 0])), (r, r * 1.2, r), tile("gills"),
                 sides=8 if lod == 0 else 5, rings=5 if lod == 0 else 3)
    return m


def bulb_tree(seed, lod, height=4.5, pods=9, pod_r=0.35):
    rng = np.random.default_rng(seed)
    m = Mesh()
    segs = 6 if lod == 0 else 3
    pts = limb_path(rng, np.array([0, -0.1, 0]), np.array([0, 1.0, 0]), height * 0.75, segs, -0.1, 0.04)
    tube(m, "bark", pts, [height * 0.035 * (1 - 0.5 * i / segs) for i in range(segs + 1)], (8, 6, 4)[lod],
         around=2, v_per_m=1.0)
    n = {0: pods, 1: max(5, pods * 2 // 3), 2: 4}[lod]
    top = pts[-1]
    for k in range(n):
        a = k * GOLDEN * 2
        tilt = rng.uniform(0.3, 1.2)
        d = dir_from(tilt, a)
        L = height * rng.uniform(0.15, 0.3)
        sp = limb_path(rng, top, d, L, 3, 0.3, 0.05)
        if lod < 2:
            tube(m, "bark", sp, [0.04, 0.03, 0.025, 0.02], 4, around=1, v_per_m=2)
        r = pod_r * rng.uniform(0.7, 1.2)
        blob(m, "leaf", tuple(sp[-1] + np.array([0, -r * 0.6, 0])), (r, r * 1.25, r), tile("succulent"),
             sides=10 if lod == 0 else 6, rings=6 if lod == 0 else 4)
    return m


def kelp(seed, lod, height=5.0, blades=7, width=0.9):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = {0: blades, 1: max(3, blades * 2 // 3), 2: 3}[lod]
    for k in range(n):
        a = rng.uniform(0, TAU)
        base = np.array([math.cos(a), 0, math.sin(a)]) * rng.uniform(0, 0.25)
        stipe = limb_path(rng, base - np.array([0, 0.1, 0]), np.array([0, 1.0, 0]), height * 0.25, 3, -0.1, 0.05)
        tube(m, "leaf", stipe, [0.03, 0.025, 0.02, 0.018], 4, uv_rect=half_tile("stem_moss", True))
        up = norm(np.array([math.cos(a) * 0.15, 1, math.sin(a) * 0.15]))
        right = np.array([-math.sin(a), 0, math.cos(a)])
        card(m, stipe[-1] - up * 0.05, up, right, width * rng.uniform(0.8, 1.2), height * rng.uniform(0.7, 1.0),
             tile("kelp"), lnorm=None, bend=rng.uniform(0.1, 0.3), segs=5 if lod == 0 else 2, curl=0.2)
    return m


def cushion(seed, lod, radius=0.6, height=0.35, lumps=5, tname_moss=True, flowers=False):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = {0: lumps, 1: max(2, lumps // 2), 2: 2}[lod]
    uv = half_tile("stem_moss", False)
    for k in range(n):
        a = rng.uniform(0, TAU)
        r = rng.uniform(0, radius * 0.6) if k else 0
        rr = radius * rng.uniform(0.45, 0.8)
        blob(m, "leaf", (math.cos(a) * r, -height * 0.25, math.sin(a) * r), (rr, height * rng.uniform(0.7, 1.1), rr),
             uv, sides=10 if lod == 0 else 6, rings=5 if lod == 0 else 3)
    if flowers and lod < 2:
        for k in range(8):
            a = rng.uniform(0, TAU)
            p = np.array([math.cos(a), 0, math.sin(a)]) * rng.uniform(0, radius * 0.5) + np.array([0, height * 0.5, 0])
            right = np.array([math.cos(a + 1), 0, math.sin(a + 1)])
            card(m, p, np.array([0, 1.0, 0]), right, 0.3, 0.3, tile("flowers"), lnorm=np.array([0, 1.0, 0]), segs=1)
    return m


# ── the library ─────────────────────────────────────────────────────────────
# id, builder, kwargs, metadata for the runtime brain.
#   form    the gameplay form (yields, names): tree shrub grass fungus spire
#           succulent kelp vine (as flora_gen has always had)
#   kind    what the brain reasons about when casting a world
#   h       nominal height (m) of the LOD-0 mesh
#   bark    bark texture type (rough/smooth/palm/stalk) or None
#   lods    number of LOD meshes (1 grass … 3 trees)
#   tags    climate affinities: wet dry cold hot temperate alien aquatic tall
#           (+ "dense" = can carpet ground, "glow" = glow-capable)

LIB = [
    # grasses — the carpets
    ("grass_tuft", tussock, dict(height=0.55, width=2.0, cards=9), dict(form="grass", kind="grass", h=0.55, bark=None, lods=1, tags="temperate wet cold dense")),
    ("grass_tall", tussock, dict(height=1.1, width=2.0, cards=9, lean=0.25), dict(form="grass", kind="grass", h=1.1, bark=None, lods=1, tags="temperate wet hot dense")),
    ("grass_seed", tussock, dict(height=0.85, width=2.0, cards=9, tname="seedgrass"), dict(form="grass", kind="grass", h=0.85, bark=None, lods=1, tags="temperate dry hot dense")),
    ("grass_low", tussock, dict(height=0.3, width=1.8, cards=8, lean=0.5), dict(form="grass", kind="grass", h=0.3, bark=None, lods=1, tags="cold dry temperate dense")),
    ("meadow", tussock, dict(height=0.5, width=1.9, cards=8, flowers=4), dict(form="grass", kind="grass", h=0.5, bark=None, lods=1, tags="temperate wet dense")),
    # ground plants
    ("fern_a", fern, dict(fronds=9, length=1.2), dict(form="shrub", kind="fern", h=0.9, bark=None, lods=2, tags="wet temperate hot")),
    ("fern_tall", fern, dict(fronds=7, length=1.8, rise=1.3, spread_k=0.6), dict(form="shrub", kind="fern", h=1.6, bark=None, lods=2, tags="wet hot")),
    ("reeds", reeds, dict(height=2.0), dict(form="grass", kind="reed", h=2.0, bark="stalk", lods=2, tags="wet temperate")),
    ("horsetail", reeds, dict(height=1.3, stalks=8, horsetail=True), dict(form="grass", kind="reed", h=1.3, bark="stalk", lods=2, tags="wet cold alien")),
    ("cushion", cushion, dict(radius=0.7, height=0.35), dict(form="shrub", kind="moss", h=0.35, bark=None, lods=2, tags="cold wet dry")),
    ("cushion_bloom", cushion, dict(radius=0.6, height=0.3, flowers=True), dict(form="shrub", kind="moss", h=0.4, bark=None, lods=2, tags="cold temperate")),
    # succulents
    ("rosette", succulent_rosette, dict(), dict(form="succulent", kind="succulent", h=0.8, bark=None, lods=2, tags="dry hot")),
    ("rosette_big", succulent_rosette, dict(leaves=22, length=1.6, width=0.22, rise=0.5), dict(form="succulent", kind="succulent", h=1.3, bark=None, lods=2, tags="dry hot")),
    ("pads", pads, dict(), dict(form="succulent", kind="succulent", h=1.4, bark=None, lods=2, tags="dry hot")),
    ("cactus_col", cactus, dict(height=3.4, arms=2), dict(form="succulent", kind="cactus", h=3.4, bark=None, lods=3, tags="dry hot tall")),
    ("cactus_barrel", cactus, dict(radius=0.45, barrel=True), dict(form="succulent", kind="cactus", h=0.8, bark=None, lods=2, tags="dry hot")),
    # bushes & shrubs
    ("bush_round", bush, dict(), dict(form="shrub", kind="bush", h=1.4, bark="rough", lods=2, tags="temperate wet")),
    ("bush_bloom", bush, dict(leaf="small", leaf2="flowers", height=1.6, width=1.8), dict(form="shrub", kind="bush", h=1.6, bark="rough", lods=2, tags="temperate wet hot")),
    ("bush_broad", bush, dict(leaf="broad", height=2.2, width=2.4, cards=34, card_s=0.9), dict(form="shrub", kind="bush", h=2.2, bark="rough", lods=2, tags="wet hot temperate")),
    ("shrub_twig", shrub_twiggy, dict(), dict(form="shrub", kind="shrub", h=1.3, bark="rough", lods=2, tags="dry cold temperate")),
    ("shrub_heath", bush, dict(height=0.6, width=1.3, cards=26, card_s=0.4, flat=0.6, stems=4), dict(form="shrub", kind="shrub", h=0.6, bark="rough", lods=2, tags="cold dry")),
    ("shrub_needle", bush, dict(leaf="needles", height=1.1, width=1.4, cards=30, card_s=0.55), dict(form="shrub", kind="shrub", h=1.1, bark="rough", lods=2, tags="cold dry")),
    # broadleaf trees
    ("oak", broadleaf, dict(height=10.0), dict(form="tree", kind="broadleaf", h=10.0, bark="rough", lods=3, tags="temperate wet")),
    ("oak_wide", broadleaf, dict(height=8.0, trunk_frac=0.3, crown_w=1.2, multi=1, angle=(0.95, 0.8, 0.8)), dict(form="tree", kind="broadleaf", h=8.0, bark="rough", lods=3, tags="temperate dry")),
    ("birch", broadleaf, dict(height=11.0, trunk_frac=0.25, crown_w=0.35, angle=(0.45, 0.6, 0.7), children=(6, 3, 2), leaf="small", leaf_size=1.3, per_tip=8, bark_r=0.018, droop=(0.0, 0.3, 0.6, 0.6)), dict(form="tree", kind="broadleaf", h=11.0, bark="smooth", lods=3, tags="temperate cold wet tall")),
    ("willow", broadleaf, dict(height=8.5, trunk_frac=0.35, crown_w=0.9, weeping=True, leaf="broad", leaf_size=1.0, per_tip=5, droop=(0.0, 0.3, 0.8, 1.0)), dict(form="tree", kind="broadleaf", h=8.5, bark="rough", lods=3, tags="wet temperate")),
    ("acacia", broadleaf, dict(height=7.0, trunk_frac=0.3, crown_w=1.6, flat_top=True, angle=(0.9, 0.9, 1.2), multi=2, leaf="small", leaf_size=1.4, per_tip=3, droop=(-0.1, -0.05, 0.0, 0.05)), dict(form="tree", kind="broadleaf", h=7.0, bark="rough", lods=3, tags="dry hot")),
    ("sapling", broadleaf, dict(height=4.0, trunk_frac=0.35, levels=3, children=(4, 3), leaf_size=0.7, per_tip=7), dict(form="tree", kind="broadleaf", h=4.0, bark="smooth", lods=3, tags="temperate wet hot")),
    ("jungle_giant", broadleaf, dict(height=16.0, trunk_frac=0.62, crown_w=1.1, angle=(1.0, 0.8, 0.8), leaf="broad", leaf_size=2.4, per_tip=7, bark_r=0.03), dict(form="tree", kind="broadleaf", h=16.0, bark="smooth", lods=3, tags="wet hot tall")),
    # conifers
    ("spruce", conifer, dict(height=13.0), dict(form="tree", kind="conifer", h=13.0, bark="rough", lods=3, tags="cold temperate tall")),
    ("fir_slim", conifer, dict(height=15.0, base_w=0.2, whorls=14, droop=0.5), dict(form="tree", kind="conifer", h=15.0, bark="rough", lods=3, tags="cold tall")),
    ("pine", conifer, dict(height=12.0, base_w=0.28, umbrella=True, whorls=9, droop=0.0, needle=1.1), dict(form="tree", kind="conifer", h=12.0, bark="rough", lods=3, tags="dry temperate cold tall")),
    ("dwarf_pine", conifer, dict(height=4.0, base_w=0.45, whorls=8, needle=0.7), dict(form="tree", kind="conifer", h=4.0, bark="rough", lods=3, tags="cold dry")),
    # palms
    ("palm", palm, dict(), dict(form="tree", kind="palm", h=8.0, bark="palm", lods=3, tags="hot wet")),
    ("palm_short", palm, dict(height=4.5, fronds=9, frond_len=2.8, curve=0.2), dict(form="tree", kind="palm", h=4.5, bark="palm", lods=3, tags="hot wet dry")),
    ("tree_fern", palm, dict(height=4.0, fronds=12, frond_len=2.4, curve=0.05, tree_fern=True), dict(form="tree", kind="palm", h=4.0, bark="palm", lods=3, tags="wet temperate hot alien")),
    # fungi
    ("toadstool", mushroom, dict(height=0.9, cap_r=0.45, cap_h=0.35), dict(form="fungus", kind="fungus", h=1.0, bark="stalk", lods=2, tags="wet cold temperate glow")),
    ("parasol", mushroom, dict(height=2.4, cap_r=1.0, stalk_r=0.07, cap_h=0.3, flat=True), dict(form="fungus", kind="fungus", h=2.5, bark="stalk", lods=3, tags="wet temperate alien glow")),
    ("shroom_cluster", mushroom, dict(height=0.7, cap_r=0.3, cap_h=0.22, cluster=7, spread=0.9), dict(form="fungus", kind="fungus", h=0.7, bark="stalk", lods=2, tags="wet cold glow")),
    ("giant_cap", mushroom, dict(height=6.5, cap_r=3.2, stalk_r=0.35, cap_h=1.2, upturn=0.15), dict(form="fungus", kind="fungus", h=7.5, bark="stalk", lods=3, tags="wet alien tall glow")),
    ("shelf_tower", shelf_tower, dict(), dict(form="fungus", kind="fungus", h=4.0, bark="stalk", lods=3, tags="wet cold alien glow")),
    # alien growths
    ("spire", spire, dict(), dict(form="spire", kind="spire", h=6.0, bark=None, lods=3, tags="alien dry cold tall glow")),
    ("spire_ringed", spire, dict(height=8.0, radius=0.5, twist=1.0, rings=4, horns=3), dict(form="spire", kind="spire", h=8.0, bark=None, lods=3, tags="alien hot tall glow")),
    ("tubes", tubes, dict(), dict(form="fungus", kind="tubes", h=2.2, bark=None, lods=2, tags="alien wet hot glow")),
    ("crystals", crystals, dict(), dict(form="spire", kind="crystal", h=2.2, bark=None, lods=2, tags="alien cold dry glow")),
    ("crystal_big", crystals, dict(count=9, height=4.5, radius=0.4, spread=1.1), dict(form="spire", kind="crystal", h=4.5, bark=None, lods=3, tags="alien cold dry tall glow")),
    ("coral_tree", coral_tree, dict(), dict(form="tree", kind="coral", h=3.5, bark=None, lods=3, tags="alien wet hot glow")),
    ("bulb_tree", bulb_tree, dict(), dict(form="tree", kind="bulb", h=4.5, bark="smooth", lods=3, tags="alien hot dry glow")),
    # water
    ("kelp", kelp, dict(), dict(form="kelp", kind="kelp", h=5.0, bark=None, lods=3, tags="aquatic")),
    ("kelp_short", kelp, dict(height=2.2, blades=8, width=0.4), dict(form="kelp", kind="kelp", h=2.2, bark=None, lods=2, tags="aquatic")),
    ("sea_tubes", tubes, dict(count=12, height=1.2, radius=0.12, spread=0.7), dict(form="kelp", kind="tubes", h=1.2, bark=None, lods=2, tags="aquatic alien glow")),
]


# ── writing ─────────────────────────────────────────────────────────────────

def shade(mesh, P, mat):
    """Per-vertex colour, multiplied into the texture by the engine (glTF
    COLOR_0): ambient occlusion low on the plant and deep in the crown, sun
    on the top, and a slow wobble of shade and warmth across the plant — so a
    plant reads as a form at every distance, not just where its texture's
    detail survives the mip chain, and no two clumps of leaves are the same."""
    mn, mx = mesh.bounds()
    hgt = max(1e-3, mx[1] - mn[1])
    t = np.clip((P[:, 1] - mn[1]) / hgt, 0, 1)
    rad = np.sqrt(P[:, 0] ** 2 + P[:, 2] ** 2)
    rmax = max(1e-3, rad.max())
    if mat == "bark":
        ao = 0.62 + 0.38 * np.clip(t * 1.6, 0, 1)
    else:
        ao = (0.58 + 0.42 * t ** 0.7) * (0.72 + 0.28 * np.clip(rad / rmax * 1.3, 0, 1))
    k = 1.7 / max(0.5, hgt) ** 0.5
    w1 = np.sin(P[:, 0] * k * 1.9 + P[:, 2] * k * 2.3 + 1.3) * np.cos(P[:, 1] * k * 1.4 - P[:, 0] * k * 0.7)
    w2 = np.sin(P[:, 2] * k * 3.1 - P[:, 1] * k * 2.2 + 0.4)
    v = ao * (1.0 + 0.10 * w1)
    C = np.stack([v * (1 + 0.05 * w2), v, v * (1 - 0.06 * w2)], -1)
    return np.clip(C, 0, 1).astype(np.float32)


def pack(mesh, colors=True):
    """Mesh → (bytes, primitive descriptors with bufferView offsets)."""
    blob_ = bytearray()
    prims = []

    def put(data):
        while len(blob_) % 4:
            blob_.extend(b"\0")
        off = len(blob_)
        blob_.extend(data)
        return off, len(data)

    for mat, (P, N, UV, I) in sorted(mesh.arrays().items()):
        P = P.astype(np.float32)
        N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
        UV = UV.astype(np.float32)
        I = I.astype(np.uint32).reshape(-1)
        pr = dict(mat=mat, count=len(P), icount=len(I), pmin=P.min(0).tolist(), pmax=P.max(0).tolist(),
                  P=put(P.tobytes()), N=put(N.tobytes()), UV=put(UV.tobytes()), I=put(I.tobytes()))
        if colors:
            pr["C"] = put(shade(mesh, P.astype(np.float64), mat).tobytes())
        prims.append(pr)
    return bytes(blob_), prims


LINEAR, LINEAR_MIPMAP_LINEAR, REPEAT, CLAMP = 9729, 9987, 10497, 33071


def gltf_json(bin_name, bin_len, prims, images, name, glow=None, normals=None, mr=None, glows=None):
    """`images`: material → picture. `glow`: the leaf material's emissive map.
    `normals` / `mr` / `glows`: material → normal map / metallic-roughness map
    / emissive map."""
    normals, mr, glows = normals or {}, mr or {}, dict(glows or {})
    if glow:
        glows.setdefault("leaf", glow)
    views, accs, gprims, mats, texs = [], [], [], [], []
    img_index = {}
    for img in list(images.values()) + list(normals.values()) + list(mr.values()) + list(glows.values()):
        if img not in img_index:
            img_index[img] = len(img_index)
    for pr in prims:
        def view(o, target):
            views.append({"buffer": 0, "byteOffset": o[0], "byteLength": o[1], "target": target})
            return len(views) - 1
        accs.append({"bufferView": view(pr["P"], 34962), "componentType": 5126, "count": pr["count"], "type": "VEC3",
                     "min": pr["pmin"], "max": pr["pmax"]})
        ap = len(accs) - 1
        accs.append({"bufferView": view(pr["N"], 34962), "componentType": 5126, "count": pr["count"], "type": "VEC3"})
        an = len(accs) - 1
        accs.append({"bufferView": view(pr["UV"], 34962), "componentType": 5126, "count": pr["count"], "type": "VEC2"})
        au = len(accs) - 1
        accs.append({"bufferView": view(pr["I"], 34963), "componentType": 5125, "count": pr["icount"], "type": "SCALAR"})
        ai = len(accs) - 1
        ac = None
        if "C" in pr:
            accs.append({"bufferView": view(pr["C"], 34962), "componentType": 5126, "count": pr["count"], "type": "VEC3"})
            ac = len(accs) - 1
        # bark tiles (repeat), the atlas clamps
        tiled = images[pr["mat"]].split("/")[-1].startswith(("bark_", "rock_"))
        texs.append({"source": img_index[images[pr["mat"]]], "sampler": 0 if tiled else 1})
        mat = {"name": pr["mat"], "pbrMetallicRoughness": {"baseColorTexture": {"index": len(texs) - 1},
               "metallicFactor": 0.0, "roughnessFactor": 0.9},
               "alphaMode": "MASK" if pr["mat"] == "leaf" else "OPAQUE", "doubleSided": True}
        smp_i = 0 if tiled else 1
        if pr["mat"] in glows:
            texs.append({"source": img_index[glows[pr["mat"]]], "sampler": smp_i})
            mat["emissiveTexture"] = {"index": len(texs) - 1}
            mat["emissiveFactor"] = [0.0, 0.0, 0.0]
        if pr["mat"] in normals:
            texs.append({"source": img_index[normals[pr["mat"]]], "sampler": smp_i})
            mat["normalTexture"] = {"index": len(texs) - 1}
        if pr["mat"] in mr:
            texs.append({"source": img_index[mr[pr["mat"]]], "sampler": smp_i})
            mat["pbrMetallicRoughness"]["metallicRoughnessTexture"] = {"index": len(texs) - 1}
            mat["pbrMetallicRoughness"]["roughnessFactor"] = 1.0
        mats.append(mat)
        attrs = {"POSITION": ap, "NORMAL": an, "TEXCOORD_0": au}
        if ac is not None:
            attrs["COLOR_0"] = ac
        gprims.append({"attributes": attrs, "indices": ai, "material": len(mats) - 1})
    imgs = [None] * len(img_index)
    for k, i in img_index.items():
        imgs[i] = {"uri": k}
    smp = {"magFilter": LINEAR, "minFilter": LINEAR_MIPMAP_LINEAR}
    return {"asset": {"version": "2.0", "generator": "Solar tools/gen_flora.py"},
            "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": name, "mesh": 0}],
            "meshes": [{"name": name, "primitives": gprims}], "materials": mats, "textures": texs,
            "samplers": [dict(smp, wrapS=REPEAT, wrapT=REPEAT), dict(smp, wrapS=CLAMP, wrapT=CLAMP)],
            "images": imgs, "accessors": accs, "bufferViews": views,
            "buffers": [{"uri": bin_name, "byteLength": bin_len}]}


def lua_library(meta_rows):
    out = ["-- BEGIN FLORA LIBRARY (generated by tools/gen_flora.py — do not edit by hand)",
           "LIBRARY = {"]
    for sid, meta, tris in meta_rows:
        out.append('  { id = "%s", form = "%s", kind = "%s", h = %.2f, bark = %s, twin = %s, lods = %d, tags = "%s", tris = { %s } },'
                   % (sid, meta["form"], meta["kind"], meta["h"],
                      ('"%s"' % meta["bark"]) if meta["bark"] else "nil", "true" if twin(meta) else "false",
                      meta["lods"], meta["tags"], ", ".join(str(t) for t in tris)))
    out.append("}")
    out.append("NEUTRAL = { leaf = %.2f, bark = %.2f }" % (NEUTRAL_MID, NEUTRAL_BARK_MID))
    out.append("PALETTES = {")
    for i, p in enumerate(PALETTES):
        name, dark, mid, light, tip, acc, glow, bark = p
        f = lambda c: "{ %.2f, %.2f, %.2f }" % tuple(c)
        out.append('  { id = %d, name = "%s", dark = %s, mid = %s, light = %s, accent = %s, glow = %s, bark = %d },'
                   % (i, name, f(dark), f(mid), f(light), f(acc), f(glow), bark))
    out.append("}")
    out.append("BARKS = {")
    for i, (name, d, mcol, l) in enumerate(BARKS):
        out.append('  { id = %d, name = "%s", mid = { %.2f, %.2f, %.2f } },' % (i, name, *mcol))
    out.append("}")
    out.append("-- END FLORA LIBRARY")
    return "\n".join(out)


# ── rocks (the mineral field's surface stone) ───────────────────────────────
# Faceted, stratified stones: a lat-long sphere pushed out by noise, then
# chiselled by a few random planes (rock breaks along flat faces), squashed,
# and set a third into the ground. UVs run around (u, an integer number of
# repeats so the seam tiles) and UP (v, in metres) so the texture's strata lie
# level, the way sedimentary rock does.

def rock_blob(m, rng, center, size, lod, squash=0.7, facets=6, mat="bark"):
    rings, segs = ((9, 14), (6, 9), (4, 6))[lod]
    planes = []
    for _ in range(facets):
        n = norm(rng.normal(size=3))
        planes.append((n, rng.uniform(0.72, 0.92)))
    seed3 = rng.uniform(0, 100, 3)
    # The lat-long poles pinch: turn them to lie sideways (into a facet or the
    # ground), never on top where they'd show as a star.
    ax = norm(np.array([rng.uniform(-1, 1), 0.0, rng.uniform(-1, 1)]) + 1e-6)
    ang = rng.uniform(1.2, 1.9)
    K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
    Rm = np.eye(3) + math.sin(ang) * K + (1 - math.cos(ang)) * (K @ K)
    P, UV = [], []
    for i in range(rings + 1):
        ph = math.pi * i / rings
        for j in range(segs + 1):
            th = TAU * j / segs
            d = Rm @ np.array([math.sin(ph) * math.cos(th), math.cos(ph), math.sin(ph) * math.sin(th)])
            r = 1.0 + 0.16 * math.sin(d[0] * 3.1 + seed3[0]) * math.cos(d[2] * 2.7 + seed3[1]) \
                + 0.08 * math.sin(d[1] * 5.3 + d[0] * 4.1 + seed3[2])
            for n, k in planes:
                c = float(np.dot(d, n))
                if c > 1e-3:
                    r = min(r, k / c)
            q = d * r
            q = np.array([q[0], q[1] * squash, q[2]])
            q[1] = max(q[1], -0.45 * squash)       # a flat-ish bed
            P.append(center + q * size)
            UV.append([j / segs * 2.0, -(center[1] + q[1] * size) * 0.6 + rng.uniform(0, 0.0)])
    P = np.asarray(P)
    I = []
    W = segs + 1
    for i in range(rings):
        for j in range(segs):
            a, b, c, d2 = i * W + j, i * W + j + 1, (i + 1) * W + j + 1, (i + 1) * W + j
            I += [[a, b, c], [a, c, d2]]
    I = np.asarray(I)
    # outward winding check, then smooth normals from the faces
    fa, fb, fc = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    out = ((fa + fb + fc) / 3 - center)
    flip = (fn * out).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    fa, fb, fc = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    N = np.zeros_like(P)
    for k in range(3):
        np.add.at(N, I[:, k], fn)
    # the seam column shares positions with column 0: average across it
    for i in range(rings + 1):
        a, b = i * W, i * W + segs
        s_ = N[a] + N[b]
        N[a] = N[b] = s_
    N = N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    m.add(mat, P, N, UV, I)


def rock_shape(kind, seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    if kind == "pebbles":
        for i in range(7 if lod == 0 else 4):
            a, r = rng.uniform(0, TAU), rng.uniform(0.0, 0.9)
            s = rng.uniform(0.17, 0.36)
            rock_blob(m, rng, np.array([math.cos(a) * r, s * 0.15, math.sin(a) * r]), s, lod + 1,
                      squash=rng.uniform(0.5, 0.8), facets=4)
    elif kind == "stone":
        rock_blob(m, rng, np.array([0.0, 0.12, 0.0]), 0.55, lod, squash=0.72, facets=7)
        rock_blob(m, rng, np.array([0.55, 0.0, 0.25]), 0.2, lod, squash=0.6, facets=4)
    elif kind == "boulder":
        rock_blob(m, rng, np.array([0.0, 0.35, 0.0]), 1.0, lod, squash=0.78, facets=8)
        rock_blob(m, rng, np.array([0.9, 0.05, -0.4]), 0.35, lod, squash=0.65, facets=5)
        rock_blob(m, rng, np.array([-0.7, 0.0, 0.6]), 0.22, lod, squash=0.6, facets=4)
    elif kind == "slab":
        rock_blob(m, rng, np.array([0.0, 0.1, 0.0]), 1.1, lod, squash=0.32, facets=6)
    elif kind == "crystal":
        msh = crystals(seed, (0, 1)[lod], count=8, height=1.6, radius=0.18, spread=0.55)
        # the outcrop wears its own crystal picture, not the flora atlas tile
        u0, v0, u1, v1 = tile("crystal")
        for e in msh.parts.values():
            e[2] = [np.column_stack([(uv[:, 0] - u0) / (u1 - u0), (uv[:, 1] - v0) / (v1 - v0)]) for uv in e[2]]
        m = Mesh()
        m.parts["crystal"] = msh.parts["leaf"]
        rock_blob(m, rng, np.array([0.0, -0.25, 0.0]), 0.45, lod, squash=0.5, facets=5)
    m.anchor(every=True)
    return m


ROCKS = ["pebbles", "stone", "boulder", "slab", "crystal"]


def write_rocks():
    n = 0
    for kind in ROCKS:
        sid = f"rock_{kind}"
        seed = sum(ord(c) * (i + 1) for i, c in enumerate(sid))
        blob_all = bytearray()
        packed = []
        for lod in range(2):
            data, prims = pack(rock_shape(kind, seed, lod), colors=False)
            while len(blob_all) % 4:
                blob_all.extend(b"\0")
            base = len(blob_all)
            blob_all.extend(data)
            for pr in prims:
                for k in ("P", "N", "UV", "I"):
                    pr[k] = (pr[k][0] + base, pr[k][1])
            packed.append(prims)
        with open(os.path.join(OUT, sid + ".bin"), "wb") as f:
            f.write(bytes(blob_all))
        for lod, prims in enumerate(packed):
            images = {"bark": f"{TEXREL}rock_l0.png", "crystal": f"{TEXREL}crystal_l0.png"}
            normals = {"bark": f"{TEXREL}rock_n.png", "crystal": f"{TEXREL}crystal_n.png"}
            mr = {"bark": f"{TEXREL}rock_mr.png", "crystal": f"{TEXREL}crystal_mr.png"}
            glows = {"crystal": f"{TEXREL}crystal_glow.png"}
            write_gltf(sid + ".bin", len(blob_all), prims, images, f"{sid}_l{lod}", normals=normals, mr=mr,
                       glows=glows)
            n += 1
        print(f"{sid:16s} tris {[sum(p['icount'] for p in pr) // 3 for pr in packed]}")
    return n


def twin(meta):
    """A tree's trunk is its own file (and its own tinted source at runtime)."""
    return meta["form"] == "tree" and bool(meta["bark"])


def write_gltf(bin_name, bin_len, prims, images, name, glow=None, **maps):
    with open(os.path.join(OUT, name + ".gltf"), "w") as f:
        json.dump(gltf_json(bin_name, bin_len, prims, images, name, glow, **maps), f, separators=(",", ":"))


def main(only=None):
    os.makedirs(OUT, exist_ok=True)
    meta_rows = []
    total_files = 0
    for sid, fn, kw, meta in LIB:
        if only and sid not in only:
            continue
        seed = sum(ord(c) * (i + 1) for i, c in enumerate(sid))
        meshes = []
        for lod in range(meta["lods"]):
            msh = fn(seed, lod, **kw)
            # A twin's two files must recentre alike: anchor every material.
            msh.anchor(every=twin(meta))
            meshes.append(msh)
        # one .bin for every LOD of the shape
        blob_all = bytearray()
        packed = []
        for msh in meshes:
            data, prims = pack(msh)
            while len(blob_all) % 4:
                blob_all.extend(b"\0")
            base = len(blob_all)
            blob_all.extend(data)
            for pr in prims:
                for k in ("P", "N", "UV", "I", "C"):
                    if k in pr:
                        pr[k] = (pr[k][0] + base, pr[k][1])
            packed.append(prims)
        bin_name = f"{sid}.bin"
        with open(os.path.join(OUT, bin_name), "wb") as f:
            f.write(bytes(blob_all))
        tris = [msh.tris() for msh in meshes]
        glow = f"{TEXREL}foliage_glow.png" if " glow" in " " + meta["tags"] else None
        for lod, prims in enumerate(packed):
            # One atlas for every LOD: the engine's mip chain does what the
            # hand-made 512²/256² LOD atlases did (measured: far-crown coverage
            # 67.1 % vs 66.2 %, shimmer the same), so they are gone.
            leaf = f"{TEXREL}foliage_l0.png"
            bark = f"{TEXREL}bark_{meta['bark']}_l{0 if lod == 0 else 1}.png" if meta["bark"] else leaf
            nm = {"leaf": f"{TEXREL}foliage_n.png"}
            nm["bark"] = f"{TEXREL}bark_{meta['bark']}_n.png" if meta["bark"] else nm["leaf"]
            if lod == 2:
                nm = {}   # far: the relief is below a pixel
            if twin(meta):
                write_gltf(bin_name, len(blob_all), [p for p in prims if p["mat"] != "bark"], {"leaf": leaf},
                           f"{sid}_l{lod}", glow, normals={k: v for k, v in nm.items() if k == "leaf"})
                write_gltf(bin_name, len(blob_all), [p for p in prims if p["mat"] == "bark"], {"bark": bark},
                           f"{sid}_bark_l{lod}", normals={k: v for k, v in nm.items() if k == "bark"})
                total_files += 2
            else:
                write_gltf(bin_name, len(blob_all), prims, {"leaf": leaf, "bark": bark}, f"{sid}_l{lod}", glow,
                           normals=nm)
                total_files += 1
        meta_rows.append((sid, meta, tris))
        print(f"{sid:16s} tris {tris}  bin {len(blob_all) // 1024} KB{'  (twin)' if twin(meta) else ''}")
    if not only:
        total_files += write_rocks()
    # The per-palette files (and their filter sidecars) an older run wrote.
    gone = 0
    for f in os.listdir(OUT):
        if re.match(r"^.+_p\d\d_l\d\.(gltf|rig\.ron)$", f):
            os.remove(os.path.join(OUT, f))
            gone += 1
    if gone:
        print(f"removed {gone} per-palette files")
    if not only:
        src = open(LUA).read()
        block = lua_library(meta_rows)
        pat = re.compile(r"-- BEGIN FLORA LIBRARY.*?-- END FLORA LIBRARY", re.S)
        if pat.search(src):
            src = pat.sub(lambda _: block, src)
        else:
            src = src.rstrip("\n") + "\n\n" + block + "\n"
        with open(LUA, "w") as f:
            f.write(src)
        print(f"{len(meta_rows)} shapes, {total_files} gltf, library written to {os.path.relpath(LUA, ROOT)}")


if __name__ == "__main__":
    main(set(sys.argv[1:]) or None)
