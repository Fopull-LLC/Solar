#!/usr/bin/env python3
"""Generate the cave formations (worlds W4): models/cave/*.gltf + *.bin, their
neutral pictures (textures/cave/), the cave wall decals
(textures/vfx/decal/cave_*.png) and the flare.

    python3 tools/gen_cave_props.py            # everything
    python3 tools/gen_cave_props.py --sheet    # also a Blender contact sheet (work dir)

WHAT THIS IS. The props cave_field.lua hangs from cave roofs, stands on cave
floors and lays on cave walls, one set per cave kind (scripts/cave_kinds.lua
KINDS[*].props): dripstone (stalactites in clusters with drapery rings,
candle-stack stalagmites, soda straws, flowstone drapes), ice curtains with
icicles and hoarfrost feathers, lavacicles and ropy pahoehoe slabs, angular
breakdown, quartz geode points, selenite blades, hopper-cube halite crusts
and sulfur needles. Grown from parameters and a seed, offline (the engine
builds no mesh from Lua), two LODs each in one .bin.

COLOUR is not in the files: cave_field tints each node by its kind
(node:setTint), so the pictures are NEUTRAL and BRIGHT (a tint only
multiplies: a yellow sulfur needle needs a bright picture to be yellow).
Each set has a picture, a normal map and a metallic-roughness map (glTF: G
roughness, B metal), all tiling, and the meshes carry vertex colour as
ambient occlusion (dark at roots and in crevices, grime streaks down a hanging
prop), which is what makes them read as dirty stone in a lamp beam rather than
plastic.

THE ENGINE RECENTRES a model on its bounding box: every mesh carries the
mirrored zero-area anchor triangles gen_flora uses, so the root stays at the
origin. Every prop grows along +Y from its root at the origin: cave_field
turns +Y down for the hanging ones.
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_flora import Mesh, gltf_json, norm, perp, rot_axis  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "models", "cave")
TEX = os.path.join(ROOT, "textures", "cave")
DECALS = os.path.join(ROOT, "textures", "vfx", "decal")
TEXREL = "../../textures/cave/"
TAU = 2 * math.pi
UV = 1.6   # texture repeats per metre


# ── mesh helpers ────────────────────────────────────────────────────────────
def rows(a):
    return a / np.maximum(np.linalg.norm(a, axis=1, keepdims=True), 1e-12)


def box_uv(P, N):
    a = np.abs(N)
    u = np.where(a[:, 0] >= np.maximum(a[:, 1], a[:, 2]), P[:, 2], P[:, 0])
    v = np.where(a[:, 1] >= np.maximum(a[:, 0], a[:, 2]), P[:, 2], P[:, 1])
    return np.column_stack([u, -v]) * UV


def outward(P, I, center):
    fa, fb, fc = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    flip = (fn * ((fa + fb + fc) / 3 - center)).sum(1) < 0
    I = I.copy()
    I[flip] = I[flip][:, [0, 2, 1]]
    return I


def smooth_add(m, mat, P, I, uv=None):
    P = np.asarray(P, np.float64)
    I = np.asarray(I, np.int64).reshape(-1, 3)
    fa, fb, fc = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    N = np.zeros_like(P)
    for k in range(3):
        np.add.at(N, I[:, k], fn)
    N = rows(N)
    m.add(mat, P, N, box_uv(P, N) if uv is None else uv, I)


def flat_add(m, mat, P, I):
    P = np.asarray(P, np.float64)
    I = np.asarray(I, np.int64).reshape(-1, 3)
    T = P[I.reshape(-1)]
    fn = rows(np.cross(T[1::3] - T[0::3], T[2::3] - T[0::3]))
    N = np.repeat(fn, 3, axis=0)
    m.add(mat, T, N, box_uv(T, N), np.arange(len(T)).reshape(-1, 3))


def lathe_axis(m, mat, base, axis, prof, sides, rng, wob=0.0, wob_k=5.0):
    """A surface of revolution along `axis` from `base`: prof = [(t along, r)],
    the last point the tip (r 0 makes a point). Welded, smooth-shaded, with a
    little noise in the radius so no two are round."""
    axis = norm(np.asarray(axis, np.float64))
    e1, e2 = perp(axis)
    ph = rng.uniform(0, TAU, 3)
    P, I = [], []
    n = len(prof)
    for i, (t, r) in enumerate(prof):
        c = np.asarray(base) + axis * t
        for j in range(sides):
            a = TAU * j / sides
            w = 1.0 + wob * (math.sin(a * 3 + ph[0] + t * wob_k) * 0.6 + math.sin(a * 5 + ph[1] - t * wob_k * 1.7) * 0.4)
            d = e1 * math.cos(a) + e2 * math.sin(a)
            P.append(c + d * r * w)
    for i in range(n - 1):
        for j in range(sides):
            j1 = (j + 1) % sides
            a0, a1, b0, b1 = i * sides + j, i * sides + j1, (i + 1) * sides + j, (i + 1) * sides + j1
            I += [[a0, b0, b1], [a0, b1, a1]]
    # caps: a fan at both ends (the tip collapses to a point when r is 0)
    P.append(np.asarray(base) + axis * prof[0][0])
    c0 = len(P) - 1
    P.append(np.asarray(base) + axis * prof[-1][0])
    c1 = len(P) - 1
    last = (n - 1) * sides
    for j in range(sides):
        j1 = (j + 1) % sides
        I.append([c0, j1, j])
        I.append([c1, last + j, last + j1])
    P = np.asarray(P)
    I = np.asarray(I)
    mid = np.asarray(base) + axis * (prof[0][0] + prof[-1][0]) * 0.5
    # outward from the axis, not the centre (a long cone's faces point sideways)
    fa, fb, fc = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    cen = (fa + fb + fc) / 3
    rel = cen - mid
    along = (rel @ axis)[:, None] * axis
    radial = rel - along * 0.98
    fn = np.cross(fb - fa, fc - fa)
    flip = (fn * radial).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    smooth_add(m, mat, P, I)


def sphere(rings, segs):
    D = [np.array([0.0, 1.0, 0.0])]
    for i in range(1, rings):
        ph = math.pi * i / rings
        for j in range(segs):
            th = TAU * j / segs + (0.5 * TAU / segs if i % 2 else 0)
            D.append(np.array([math.sin(ph) * math.cos(th), math.cos(ph), math.sin(ph) * math.sin(th)]))
    D.append(np.array([0.0, -1.0, 0.0]))
    D = np.asarray(D)
    I = []
    last = len(D) - 1
    for j in range(segs):
        I.append([0, 1 + (j + 1) % segs, 1 + j])
    for i in range(rings - 2):
        a0, b0 = 1 + i * segs, 1 + (i + 1) * segs
        for j in range(segs):
            j1 = (j + 1) % segs
            I += [[a0 + j, a0 + j1, b0 + j1], [a0 + j, b0 + j1, b0 + j]]
    a0 = 1 + (rings - 2) * segs
    for j in range(segs):
        I.append([last, a0 + j, a0 + (j + 1) % segs])
    return D, np.asarray(I)


def rock(m, mat, rng, center, size, lod, squash=0.7, cuts=7, flat=True):
    """An angular block: a sphere cut by random planes (flat breaks)."""
    D, I = sphere(*((7, 10), (4, 7))[lod])
    r = np.ones(len(D))
    for _ in range(cuts):
        n_ = norm(rng.normal(size=3))
        k = rng.uniform(0.45, 0.8)
        c = D @ n_
        r = np.where(c > 1e-3, np.minimum(r, k / np.maximum(c, 1e-3)), r)
    P = D * r[:, None]
    P[:, 1] *= squash
    P = np.asarray(center) + P * size
    I = outward(P, I, np.asarray(center))
    (flat_add if flat else smooth_add)(m, mat, P, I)


def prism(m, mat, base, axis, length, radius, sides, tip, twist=0.0, flatten=1.0, roll=0.0):
    """A crystal: an n-sided prism with a pyramidal termination (flat-shaded)."""
    axis = norm(np.asarray(axis, np.float64))
    e1, e2 = perp(axis)
    if roll:
        e1, e2 = e1 * math.cos(roll) + e2 * math.sin(roll), -e1 * math.sin(roll) + e2 * math.cos(roll)
    P = []
    for t in (0.0, length):
        c = np.asarray(base) + axis * t
        for j in range(sides):
            a = TAU * j / sides + twist * t
            P.append(c + (e1 * math.cos(a) + e2 * math.sin(a) * flatten) * radius)
    P.append(np.asarray(base) + axis * (length + tip))
    P.append(np.asarray(base) - axis * 0.02)
    P = np.asarray(P)
    I = []
    for j in range(sides):
        j1 = (j + 1) % sides
        I += [[j, sides + j, sides + j1], [j, sides + j1, j1]]
        I.append([sides + j, 2 * sides, sides + j1])
        I.append([j, j1, 2 * sides + 1])
    I = np.asarray(I)
    I = outward(P, I, np.asarray(base) + axis * (length * 0.5))
    flat_add(m, mat, P, I)


# ── the shapes (each grows +Y from the origin; metres at scale 1) ────────────
def drip_profile(rng, L, r0, rings, k=1.4, ripple=0.10, flare=1.6):
    """A dripstone's radius down its length: a flared root, drapery rings,
    a long taper and the drop's bulb at the tip."""
    out = []
    for i in range(rings + 1):
        t = i / rings
        r = r0 * (1 - t) ** k
        r *= 1 + (flare - 1) * math.exp(-t * 14)
        r *= 1 + ripple * math.sin(t * 38 + rng.uniform(0, 0.3)) * (1 - t)
        r = max(r, 0.004 if i < rings else 0.0)
        out.append((L * t, r))
    return out


def stalactite(seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    sides, rings = ((11, 22), (6, 8))[lod]
    lathe_axis(m, "calcite", [0, 0, 0], [rng.normal() * 0.05, 1, rng.normal() * 0.05],
               drip_profile(rng, 1.25, 0.15, rings), sides, rng, wob=0.12)
    for i in range(4 if lod == 0 else 2):
        a, d = rng.uniform(0, TAU), rng.uniform(0.18, 0.4)
        L = rng.uniform(0.25, 0.8)
        lathe_axis(m, "calcite", [math.cos(a) * d, 0, math.sin(a) * d], [rng.normal() * 0.08, 1, rng.normal() * 0.08],
                   drip_profile(rng, L, 0.05 + 0.06 * L, max(4, rings // 2)), max(5, sides - 3), rng, wob=0.1)
    # the root: a lumpy boss of flowstone on the roof
    D, I = sphere(*((6, 12), (4, 7))[lod])
    P = D * np.array([0.42, 0.10, 0.36]) * (1 + 0.15 * np.sin(D[:, 0] * 7 + D[:, 2] * 5))[:, None]
    smooth_add(m, "calcite", P, outward(P, I, np.zeros(3)))
    return m


def stalagmite(seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    sides, rings = ((12, 20), (6, 7))[lod]
    H, r0 = 0.95, 0.2
    prof = []
    for i in range(rings + 1):
        t = i / rings
        # a candle stack: stacked bulges, a rounded top (stalagmites have no point)
        r = r0 * (1 - t ** 3.2) ** 0.5 * (1 + 0.55 * math.exp(-t * 9))
        r *= 1 + 0.07 * math.sin(t * 26 + 1.3)
        prof.append((H * t, max(r, 0.0 if i == rings else 0.01)))
    lathe_axis(m, "calcite", [0, -0.05, 0], [rng.normal() * 0.04, 1, rng.normal() * 0.04], prof, sides, rng, wob=0.1)
    if lod == 0:
        for _ in range(2):
            a, d = rng.uniform(0, TAU), rng.uniform(0.2, 0.35)
            h = rng.uniform(0.2, 0.45)
            pr = [(h * t, 0.09 * (1 - t ** 3) ** 0.5 * (1 + 0.4 * math.exp(-t * 8)) + (0.0 if t == 1 else 0.005))
                  for t in np.linspace(0, 1, 7)]
            lathe_axis(m, "calcite", [math.cos(a) * d, -0.03, math.sin(a) * d], [0, 1, 0], pr, 7, rng, wob=0.12)
    D, I = sphere(*((5, 12), (4, 7))[lod])
    P = D * np.array([0.5, 0.12, 0.45]) * (1 + 0.18 * np.sin(D[:, 0] * 6 + D[:, 2] * 7))[:, None]
    P[:, 1] = np.maximum(P[:, 1], -0.04)
    smooth_add(m, "calcite", P, outward(P, I, np.zeros(3)))
    return m


def soda_straws(seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    n, sides = ((22, 5), (9, 4))[lod]
    for _ in range(n):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.22
        L = rng.uniform(0.15, 0.85) ** 1.3
        r = rng.uniform(0.008, 0.014)
        pr = [(0.0, r * 2.2), (0.04, r * 1.1), (L * 0.97, r), (L, r * 0.6)]
        lathe_axis(m, "calcite", [math.cos(a) * d, 0, math.sin(a) * d], [rng.normal() * 0.02, 1, rng.normal() * 0.02],
                   pr, sides, rng)
    D, I = sphere(*((5, 10), (3, 6))[lod])
    P = D * np.array([0.34, 0.05, 0.3])
    smooth_add(m, "calcite", P, outward(P, I, np.zeros(3)))
    return m


def drape(m, mat, rng, W, H, folds, lod, thick=0.12, lobes=True, icicles=0):
    """A curtain sheet down a wall: the top edge at y 0 on the wall (z 0), the
    front face folded in and out (z > 0), lobed at the bottom; a flat back.
    +Y runs down the wall once cave_field turns it."""
    nx, ny = ((28, 12), (12, 5))[lod]
    ph = rng.uniform(0, TAU, 4)
    P, I = [], []
    for j in range(ny + 1):
        v = j / ny
        for i in range(nx + 1):
            u = i / nx
            x = (u - 0.5) * W
            lob = (0.75 + 0.25 * math.sin(u * TAU * folds * 0.5 + ph[2])) if lobes else 1.0
            y = v * H * lob * (1 - 0.15 * abs(u - 0.5) * 2)
            fold = math.sin(u * TAU * folds + ph[0] + v * 1.2) * 0.5 + 0.5
            z = thick * (0.35 + 0.65 * fold) * (1 - 0.6 * v) * (1 - (2 * abs(u - 0.5)) ** 4)
            z += 0.015 * math.sin(v * 31 + u * 17 + ph[1])
            P.append([x, y, z])
    for j in range(ny):
        for i in range(nx):
            a, b = j * (nx + 1) + i, j * (nx + 1) + i + 1
            c, d = (j + 1) * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i
            I += [[a, d, c], [a, c, b]]
    P = np.asarray(P, np.float64)
    I = np.asarray(I)
    # the back: the same grid at z 0.004 behind, wound the other way
    B = P.copy()
    B[:, 2] = -0.004
    nb = len(P)
    I2 = I[:, [0, 2, 1]] + nb
    allP = np.vstack([P, B])
    allI = np.vstack([I, I2])
    # front faces +z
    fa, fb, fc = allP[allI[:, 0]], allP[allI[:, 1]], allP[allI[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    front = np.arange(len(allI)) < len(I)
    want = np.where(front, 1.0, -1.0)
    flip = fn[:, 2] * want < 0
    allI[flip] = allI[flip][:, [0, 2, 1]]
    smooth_add(m, mat, allP, allI)
    for k in range(icicles):
        u = (k + rng.uniform(0.2, 0.8)) / icicles
        x = (u - 0.5) * W
        y0 = H * (0.75 + 0.25 * math.sin(u * TAU * folds * 0.5 + ph[2])) * (1 - 0.15 * abs(u - 0.5) * 2) * 0.96
        L = rng.uniform(0.15, 0.7) * H
        lathe_axis(m, mat, [x, y0, thick * 0.3], [rng.normal() * 0.03, 1, 0],
                   drip_profile(rng, L, 0.035, 6 if lod == 0 else 3, k=1.1, ripple=0.03, flare=1.2),
                   6 if lod == 0 else 4, rng)


def flowstone(seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    drape(m, "calcite", rng, 1.4, 1.25, 3.5, lod, thick=0.16)
    return m


def ice_curtain(seed, lod):
    rng = np.random.default_rng(seed)
    m = Mesh()
    drape(m, "ice", rng, 1.2, 0.35, 2.0, lod, thick=0.07, lobes=False, icicles=(11 if lod == 0 else 5))
    # a few free icicles beside it
    for _ in range(4 if lod == 0 else 2):
        x = rng.uniform(-0.8, 0.8)
        L = rng.uniform(0.3, 1.0)
        lathe_axis(m, "ice", [x, 0, rng.uniform(0.05, 0.3)], [rng.normal() * 0.02, 1, 0],
                   drip_profile(rng, L, 0.045, 7 if lod == 0 else 3, k=1.1, ripple=0.04, flare=1.3),
                   7 if lod == 0 else 4, rng)
    return m


def hoarfrost(seed, lod):
    """Depth hoar: feathery plates and hollow cups grown off the surface."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = 34 if lod == 0 else 12
    for _ in range(n):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.25
        ax = norm(np.array([rng.normal() * 0.6, 1.0, rng.normal() * 0.6]))
        prism(m, "ice", [math.cos(a) * d, -0.01, math.sin(a) * d], ax, rng.uniform(0.04, 0.18),
              rng.uniform(0.03, 0.07), 6, rng.uniform(0.01, 0.03), flatten=0.12, roll=rng.uniform(0, TAU))
    D, I = sphere(*((5, 10), (3, 6))[lod])
    P = D * np.array([0.32, 0.04, 0.3])
    smooth_add(m, "ice", P, outward(P, I, np.zeros(3)))
    return m


def lavacicle(seed, lod):
    """Shark-tooth lavacicles: short, knobbly, glassy drips of remelted rock."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = 9 if lod == 0 else 4
    for i in range(n):
        a, d = rng.uniform(0, TAU), (rng.uniform(0.0, 0.42) if i else 0.0)
        L = rng.uniform(0.12, 0.45) * (1.3 if i == 0 else 1.0)
        rings = 8 if lod == 0 else 4
        pr = []
        for k in range(rings + 1):
            t = k / rings
            r = 0.05 * (1 - t) ** 0.8 * (1 + 0.35 * math.sin(t * 17 + i)) + 0.025 * math.exp(-((t - 0.92) / 0.08) ** 2)
            pr.append((L * t, max(r, 0.0 if k == rings else 0.008)))
        lathe_axis(m, "basalt", [math.cos(a) * d, 0, math.sin(a) * d], [rng.normal() * 0.15, 1, rng.normal() * 0.15],
                   pr, 7 if lod == 0 else 5, rng, wob=0.2, wob_k=9)
    D, I = sphere(*((5, 11), (3, 6))[lod])
    P = D * np.array([0.55, 0.05, 0.5]) * (1 + 0.2 * np.sin(D[:, 0] * 9 + D[:, 2] * 4))[:, None]
    smooth_add(m, "basalt", P, outward(P, I, np.zeros(3)))
    return m


def ropy_slab(seed, lod):
    """A pahoehoe slab: a low plate whose skin is wrinkled into ropes, bent in
    arcs the way the flow dragged it."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    nr, na = ((14, 40), (5, 14))[lod]
    t = np.arange(na) / na * TAU
    rad = 0.85 + 0.2 * np.sin(t * 2 + rng.uniform(0, TAU)) + 0.1 * np.sin(t * 5 + rng.uniform(0, TAU))
    flow = norm(np.array([rng.normal(), 0, rng.normal()]))
    cx = -0.6

    def top(x, z):
        # ropes: ridges on arcs round a point upstream
        d = math.hypot(x - cx * flow[0], z - cx * flow[2])
        rope = math.sin(d * 34) * 0.5 + 0.5
        return 0.1 + 0.03 * rope ** 2 + 0.02 * math.sin(x * 7 + z * 5)

    P, I = [[0.0, top(0.0, 0.0), 0.0]], []
    for i in range(1, nr + 1):
        f = i / nr
        for j in range(na):
            x, z = math.cos(t[j]) * rad[j] * f, math.sin(t[j]) * rad[j] * f
            P.append([x, top(x, z) * (1 - 0.6 * f ** 4), z])
    for j in range(na):
        I.append([0, 1 + (j + 1) % na, 1 + j])
    for i in range(nr - 1):
        a0, b0 = 1 + i * na, 1 + (i + 1) * na
        for j in range(na):
            j1 = (j + 1) % na
            I += [[a0 + j, a0 + j1, b0 + j1], [a0 + j, b0 + j1, b0 + j]]
    P = np.asarray(P)
    smooth_add(m, "basalt", P, outward(P, np.asarray(I), np.array([0.0, -10.0, 0.0])))
    # the broken rim down to the bed
    rim0 = 1 + (nr - 1) * na
    E, EI = [], []
    for j in range(na):
        p = P[rim0 + j]
        E.append(p)
        E.append(np.array([p[0] * 0.97, -0.06, p[2] * 0.97]))
    E = np.asarray(E)
    for j in range(na):
        j1 = (j + 1) % na
        a, b, c_, d = 2 * j, 2 * j1, 2 * j1 + 1, 2 * j + 1
        EI += [[a, c_, b], [a, d, c_]]
    EI = np.asarray(EI)
    fa, fb, fc = E[EI[:, 0]], E[EI[:, 1]], E[EI[:, 2]]
    fn = np.cross(fb - fa, fc - fa)
    flip = (fn * (((fa + fb + fc) / 3) * np.array([1, 0, 1]))).sum(1) < 0
    EI[flip] = EI[flip][:, [0, 2, 1]]
    flat_add(m, "basalt", E, EI)
    return m


def breakdown(seed, lod):
    """Breakdown: angular blocks fallen from the roof, piled and part buried."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    rock(m, "basalt", rng, [0, 0.12, 0], 0.62, lod, squash=0.55, cuts=8)
    for _ in range(4 if lod == 0 else 2):
        a, d = rng.uniform(0, TAU), rng.uniform(0.45, 0.85)
        s = rng.uniform(0.18, 0.38)
        rock(m, "basalt", rng, [math.cos(a) * d, s * 0.25, math.sin(a) * d], s, lod, squash=rng.uniform(0.5, 0.9), cuts=7)
    if lod == 0:
        for _ in range(9):
            a, d = rng.uniform(0, TAU), rng.uniform(0.5, 1.1)
            s = rng.uniform(0.05, 0.12)
            rock(m, "basalt", rng, [math.cos(a) * d, s * 0.2, math.sin(a) * d], s, 1, squash=0.7, cuts=5)
    return m


def geode_cluster(seed, lod):
    """Quartz points grown from a druzy bed: hexagonal prisms with pyramidal
    tips, radiating off the wall."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = 16 if lod == 0 else 7
    for i in range(n):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.22
        ax = norm(np.array([math.cos(a) * d * 2.2, 1.0, math.sin(a) * d * 2.2]) + rng.normal(size=3) * 0.15)
        L = rng.uniform(0.12, 0.42) * (1.4 if i < 3 else 1.0)
        r = L * rng.uniform(0.18, 0.28)
        prism(m, "crystal", [math.cos(a) * d, -0.02, math.sin(a) * d], ax, L, r, 6, r * 1.6, roll=rng.uniform(0, 1))
    D, I = sphere(*((5, 12), (3, 7))[lod])
    P = D * np.array([0.42, 0.06, 0.4]) * (1 + 0.12 * np.sin(D[:, 0] * 11 + D[:, 2] * 9))[:, None]
    smooth_add(m, "crystal", P, outward(P, I, np.zeros(3)))
    return m


def selenite(seed, lod):
    """Selenite: long, flat, clear gypsum blades, crossing, half buried."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    n = 6 if lod == 0 else 3
    for i in range(n):
        a = rng.uniform(0, TAU)
        tilt = rng.uniform(0.25, 1.1)
        ax = norm(np.array([math.cos(a) * math.sin(tilt), math.cos(tilt), math.sin(a) * math.sin(tilt)]))
        L = rng.uniform(0.7, 1.7) * (1.2 if i == 0 else 1.0)
        prism(m, "crystal", [rng.normal() * 0.15, -0.15, rng.normal() * 0.15], ax, L, rng.uniform(0.06, 0.11), 4,
              rng.uniform(0.04, 0.12), flatten=0.28, roll=rng.uniform(0, TAU))
    return m


def salt_crust(seed, lod):
    """Halite: hopper cubes (stepped, hollow-faced in life) over a white crust."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    D, I = sphere(*((6, 14), (4, 8))[lod])
    P = D * np.array([0.7, 0.1, 0.62]) * (1 + 0.15 * np.sin(D[:, 0] * 8 + D[:, 2] * 6))[:, None]
    P[:, 1] = np.maximum(P[:, 1], -0.03)
    smooth_add(m, "crystal", P, outward(P, I, np.zeros(3)))
    n = 14 if lod == 0 else 6
    for i in range(n):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.35
        h = rng.uniform(0.04, 0.14) * (1.5 if i < 2 else 1.0)
        c = np.array([math.cos(a) * d, 0.06 + h * 0.5, math.sin(a) * d])
        ey = norm(np.array([0, 1, 0]) + rng.normal(size=3) * 0.35)
        ex, ez = perp(ey)
        ang = rng.uniform(0, TAU)
        ex, ez = ex * math.cos(ang) + ez * math.sin(ang), -ex * math.sin(ang) + ez * math.cos(ang)
        for step in ((1.0, 0.0), (0.7, 0.55)) if lod == 0 else ((1.0, 0.0),):
            hh = h * step[0]
            cc = c + ey * h * step[1]
            C = np.asarray([cc + (ex * sx + ey * sy + ez * sz) * hh for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
            q = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
            II = []
            for a_, b_, c_, d_ in q:
                II += [[a_, b_, c_], [a_, c_, d_]]
            flat_add(m, "crystal", C, outward(C, np.asarray(II), cc))
    return m


def sulfur_needles(seed, lod):
    """Native sulfur round a vent: a granular crust with acicular needles and a
    few stubby bipyramids."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    D, I = sphere(*((6, 13), (4, 7))[lod])
    P = D * np.array([0.55, 0.09, 0.5]) * (1 + 0.22 * np.sin(D[:, 0] * 13 + D[:, 2] * 9) * np.cos(D[:, 2] * 7))[:, None]
    P[:, 1] = np.maximum(P[:, 1], -0.03)
    smooth_add(m, "sulfur", P, outward(P, I, np.zeros(3)))
    n = 40 if lod == 0 else 14
    for _ in range(n):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.25
        ax = norm(np.array([math.cos(a) * d * 2, 1.0, math.sin(a) * d * 2]) + rng.normal(size=3) * 0.25)
        L = rng.uniform(0.06, 0.32)
        prism(m, "sulfur", [math.cos(a) * d, 0.02, math.sin(a) * d], ax, L, rng.uniform(0.008, 0.02), 4, L * 0.25)
    for _ in range(5 if lod == 0 else 2):
        a, d = rng.uniform(0, TAU), abs(rng.normal()) * 0.3
        s = rng.uniform(0.04, 0.09)
        ax = norm(rng.normal(size=3) * 0.5 + np.array([0, 1, 0]))
        b = np.array([math.cos(a) * d, 0.04, math.sin(a) * d])
        prism(m, "sulfur", b, ax, s * 0.4, s, 4, s * 1.1, roll=rng.uniform(0, 1))
        prism(m, "sulfur", b, -ax, 0.001, s, 4, s * 0.9, roll=rng.uniform(0, 1))
    return m


def flare(seed, lod):
    """A road flare: a red paper tube with its striker cap; the burning end
    glows (its own material, `tip`)."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    sides = 10 if lod == 0 else 6
    lathe_axis(m, "case", [0, -0.11, 0], [0, 1, 0], [(0.0, 0.016), (0.2, 0.016)], sides, rng)
    lathe_axis(m, "tip", [0, 0.09, 0], [0, 1, 0], [(0.0, 0.017), (0.02, 0.018), (0.04, 0.012), (0.05, 0.0)], sides, rng)
    return m


def lamp_cell(seed, lod):
    """The spare lamp cell (items.lua `cell`): a dark cylinder with a contact cap."""
    rng = np.random.default_rng(seed)
    m = Mesh()
    sides = 12 if lod == 0 else 6
    lathe_axis(m, "basalt", [0, -0.035, 0], [0, 1, 0], [(0.0, 0.0105), (0.065, 0.0105)], sides, rng)
    lathe_axis(m, "tip", [0, 0.03, 0], [0, 1, 0], [(0.0, 0.006), (0.006, 0.004), (0.007, 0.0)], sides, rng)
    return m


PROPS = [
    ("stalactite", stalactite), ("stalagmite", stalagmite), ("soda_straws", soda_straws), ("flowstone", flowstone),
    ("ice_curtain", ice_curtain), ("hoarfrost", hoarfrost), ("lavacicle", lavacicle), ("ropy_slab", ropy_slab),
    ("breakdown", breakdown), ("geode_cluster", geode_cluster), ("selenite", selenite), ("salt_crust", salt_crust),
    ("sulfur_needles", sulfur_needles), ("flare", flare), ("lamp_cell", lamp_cell),
]


# ── ambient occlusion in the vertex colour ──────────────────────────────────
def occlusion(P, N, mat):
    """Darker toward the root (the surface it grows from), in the crevices
    (normals facing back toward the root) and in streaks down its length: the
    grime that makes dripstone read as dirty stone."""
    y = P[:, 1]
    ymax = max(1e-3, y.max())
    t = np.clip(y / ymax, 0, 1)
    root = 0.55 + 0.45 * np.clip(t * 4, 0, 1)
    cav = 0.78 + 0.22 * np.clip(N[:, 1] * 0.5 + 0.5, 0, 1)
    streak = 0.88 + 0.12 * np.sin(P[:, 0] * 23 + P[:, 2] * 19 + np.sin(P[:, 1] * 3) * 2)
    v = root * cav * streak
    if mat in ("tip", "case"):
        v = np.ones_like(v)
    return np.clip(np.stack([v, v, v], -1), 0, 1).astype(np.float32)


def pack_ao(mesh):
    blob_ = bytearray()
    prims = []

    def put(data):
        while len(blob_) % 4:
            blob_.extend(b"\0")
        off = len(blob_)
        blob_.extend(data)
        return off, len(data)
    for mat, (P, N, UVs, I) in sorted(mesh.arrays().items()):
        Nn = rows(N)
        C = occlusion(P, Nn, mat)
        P32, N32, U32 = P.astype(np.float32), Nn.astype(np.float32), UVs.astype(np.float32)
        I32 = I.astype(np.uint32).reshape(-1)
        prims.append(dict(mat=mat, count=len(P), icount=len(I32), pmin=P32.min(0).tolist(), pmax=P32.max(0).tolist(),
                          P=put(P32.tobytes()), N=put(N32.tobytes()), UV=put(U32.tobytes()), I=put(I32.tobytes()),
                          C=put(C.tobytes())))
    return bytes(blob_), prims


# ── the pictures ────────────────────────────────────────────────────────────
NEUTRAL = 0.78   # every picture's mean: the tint only multiplies


def _noise(rng, N, sig):
    ky = np.fft.fftfreq(N)[:, None]
    kx = np.fft.fftfreq(N)[None, :]
    f = np.fft.fft2(rng.standard_normal((N, N))) * np.exp(-(kx * kx + ky * ky) * (sig * math.pi) ** 2 * 2)
    a = np.real(np.fft.ifft2(f))
    return (a - a.mean()) / (a.std() + 1e-9)


def _save(name, a):
    from PIL import Image
    Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(TEX, name))


SETS = {
    # name: (seed, roughness lo..hi, look)
    "calcite": (5101, (0.35, 0.8), "wet layered calcite: growth bands, a damp sheen in the hollows"),
    "ice": (5102, (0.06, 0.35), "glacier ice: smooth, trapped bubbles, hairline fractures"),
    "crystal": (5103, (0.08, 0.4), "glassy faces with growth steps and inclusions"),
    "basalt": (5104, (0.65, 0.98), "vesicular basalt: pitted, glassy rind patches, grime"),
    "sulfur": (5105, (0.45, 0.85), "granular sulfur: sugary grains, crusty pits"),
}


def write_textures(N=512):
    os.makedirs(TEX, exist_ok=True)
    yy, xx = np.mgrid[0:N, 0:N]
    for name, (seed, (r0, r1), _) in SETS.items():
        rng = np.random.default_rng(seed)
        if name == "calcite":
            band = np.sin((yy / N) * TAU * 14 + _noise(rng, N, 30) * 2.2) * 0.5 + 0.5
            h = 0.6 * _noise(rng, N, 18) + 0.35 * band + 0.18 * _noise(rng, N, 3)
            wet = np.clip(_noise(rng, N, 40) * 0.6 + 0.2, 0, 1)
            lum = 0.5 + 0.08 * h + 0.06 * band - 0.08 * wet
            rough = r1 - (r1 - r0) * wet - 0.05 * band
        elif name == "ice":
            h = 0.4 * _noise(rng, N, 40) + 0.08 * _noise(rng, N, 4)
            crack = np.clip(1 - np.abs(_noise(rng, N, 22) + _noise(rng, N, 60) * 0.4) * 18, 0, 1)
            bub = np.zeros((N, N))
            for _ in range(500):
                cy, cx, r = rng.uniform(0, N), rng.uniform(0, N), rng.uniform(0.8, 3.5)
                dy = (yy - cy + N / 2) % N - N / 2
                dx = (xx - cx + N / 2) % N - N / 2
                bub = np.maximum(bub, np.clip(1 - np.sqrt(dx * dx + dy * dy) / r, 0, 1))
            h = h - 0.4 * bub - 0.3 * crack
            lum = 0.5 + 0.05 * h + 0.18 * bub + 0.12 * crack
            rough = r0 + (r1 - r0) * np.clip(crack + 0.4 * bub + 0.2 * _noise(rng, N, 50), 0, 1)
        elif name == "crystal":
            steps = np.floor((_noise(rng, N, 60) * 0.5 + 0.5) * 6) / 6
            inc = np.clip(_noise(rng, N, 2) - 1.6, 0, 1)
            h = 0.5 * steps + 0.2 * _noise(rng, N, 12)
            lum = 0.5 + 0.06 * steps + 0.05 * _noise(rng, N, 25) - 0.25 * inc
            rough = r0 + (r1 - r0) * np.clip(0.3 + 0.4 * inc + 0.3 * _noise(rng, N, 30) * 0.5, 0, 1)
        elif name == "basalt":
            h = 0.5 * _noise(rng, N, 20) + 0.3 * _noise(rng, N, 5) + 0.12 * _noise(rng, N, 1.3)
            pits = np.zeros((N, N))
            for _ in range(700):
                cy, cx, r = rng.uniform(0, N), rng.uniform(0, N), rng.uniform(1.0, 5.5)
                dy = (yy - cy + N / 2) % N - N / 2
                dx = (xx - cx + N / 2) % N - N / 2
                pits = np.maximum(pits, np.clip(1 - np.sqrt(dx * dx + dy * dy) / r, 0, 1) ** 1.5)
            rind = np.clip(_noise(rng, N, 35) - 0.6, 0, 1)
            h = h - 0.9 * pits
            lum = 0.5 + 0.07 * h - 0.18 * pits + 0.05 * rind
            rough = np.clip(r1 - (r1 - r0) * rind * 1.5 + 0.05 * pits, r0, r1)
        else:  # sulfur
            grain = _noise(rng, N, 1.2)
            h = 0.4 * _noise(rng, N, 14) + 0.3 * grain + 0.2 * _noise(rng, N, 4)
            pits = np.clip(-_noise(rng, N, 6) - 1.2, 0, 1)
            h = h - 0.6 * pits
            lum = 0.5 + 0.06 * h - 0.2 * pits + 0.03 * grain
            rough = np.clip(r0 + (r1 - r0) * (0.5 + 0.25 * grain + 0.4 * pits), r0, r1)
        lum = lum * (NEUTRAL / lum.mean())
        alb = np.stack([lum, lum * 0.99, lum * 0.975], -1)
        _save(f"{name}_l0.png", alb)
        gy, gx = np.gradient(h)
        k = 1.6 if name in ("ice", "crystal") else 2.6
        nrm = np.stack([-gx * k, gy * k, np.ones_like(h)], -1)
        nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
        _save(f"{name}_n.png", nrm * 0.5 + 0.5)
        mr = np.stack([np.ones_like(h), np.clip(rough, 0.04, 1), np.zeros_like(h)], -1)
        _save(f"{name}_mr.png", mr)
        print(f"  texture {name}: mean {alb.mean():.3f}, roughness {mr[..., 1].mean():.2f}")
    # the flare's case and its burning end
    from PIL import Image
    case = np.ones((64, 64, 3)) * np.array([0.62, 0.08, 0.06])
    case[:, :, :] *= (0.9 + 0.1 * np.random.default_rng(9).random((64, 64, 1)))
    Image.fromarray((case * 255).astype(np.uint8)).save(os.path.join(TEX, "flare_case.png"))
    tip = np.ones((32, 32, 3)) * np.array([1.0, 0.55, 0.35])
    Image.fromarray((tip * 255).astype(np.uint8)).save(os.path.join(TEX, "flare_tip.png"))
    Image.fromarray(np.zeros((8, 8, 3), np.uint8)).save(os.path.join(TEX, "flare_dark.png"))


MAT_SET = {"calcite": "calcite", "ice": "ice", "crystal": "crystal", "basalt": "basalt", "sulfur": "sulfur",
           "case": "flare_case", "tip": "flare_tip"}


def write_models():
    os.makedirs(OUT, exist_ok=True)
    rows_ = []
    for sid, fn in PROPS:
        seed = sum(ord(c) * (i + 3) for i, c in enumerate(sid)) + 4400
        blob_all = bytearray()
        packed = []
        for lod in range(2):
            mesh = fn(seed, lod)
            mesh.anchor(every=True)
            data, prims = pack_ao(mesh)
            while len(blob_all) % 4:
                blob_all.extend(b"\0")
            base = len(blob_all)
            blob_all.extend(data)
            for pr in prims:
                for k in ("P", "N", "UV", "I", "C"):
                    pr[k] = (pr[k][0] + base, pr[k][1])
            packed.append(prims)
        with open(os.path.join(OUT, sid + ".bin"), "wb") as f:
            f.write(bytes(blob_all))
        for lod, prims in enumerate(packed):
            mats = sorted({p["mat"] for p in prims})
            images = {mt: f"{TEXREL}{MAT_SET[mt]}{'_l0' if mt in SETS else ''}.png" for mt in mats}
            normals = {mt: f"{TEXREL}{mt}_n.png" for mt in mats if mt in SETS}
            mr = {mt: f"{TEXREL}{mt}_mr.png" for mt in mats if mt in SETS}
            # the flare's glow is driven by node:setTint{ emissive } while it
            # burns (cave_flares.lua): an emissive map on each part says where
            # (the burning end white, the case black), emissiveFactor 0 when not
            glows = {"tip": f"{TEXREL}flare_tip.png", "case": f"{TEXREL}flare_dark.png"} if sid == "flare" else None
            js = gltf_json(sid + ".bin", len(blob_all), prims, images, f"{sid}_l{lod}", normals=normals, mr=mr,
                           glows=glows)
            # every picture tiles (gen_flora's clamp is for its atlas)
            for t in js["textures"]:
                t["sampler"] = 0
            for mt in js["materials"]:
                mt["doubleSided"] = mt["name"] in ("calcite", "ice")   # the drapes' sheets
            with open(os.path.join(OUT, f"{sid}_l{lod}.gltf"), "w") as f:
                json.dump(js, f, separators=(",", ":"))
        tris = [sum(p["icount"] for p in pr) // 3 for pr in packed]
        rows_.append((sid, tris))
        print(f"  {sid:15s} tris {tris}")
    return rows_


# ── the decals ──────────────────────────────────────────────────────────────
def write_decals(N=256):
    """RGBA marks for the cave walls (decals.add multiplies `color` in):
    soot, a crack, frost, a drip stain, calcite crust, salt bloom, sulfur."""
    from PIL import Image
    os.makedirs(DECALS, exist_ok=True)
    yy, xx = np.mgrid[0:N, 0:N] / N
    r = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) * 2
    edge = np.clip(1 - r, 0, 1)
    for name, seed in (("soot", 61), ("crack", 62), ("frost", 63), ("drip", 64), ("calcite", 65), ("salt", 66), ("sulfur", 67)):
        rng = np.random.default_rng(seed)
        n1, n2, n3 = _noise(rng, N, 14), _noise(rng, N, 4), _noise(rng, N, 1.5)
        if name == "soot":
            a = np.clip(edge ** 0.8 * (0.7 + 0.25 * n1) + 0.1 * n2, 0, 1) * 0.9
            c = np.stack([0.05 + 0.03 * n3 * 0.2] * 3, -1)
        elif name == "crack":
            line = np.zeros((N, N))
            for _ in range(3):
                ph = rng.uniform(0, TAU)
                path = 0.5 + 0.25 * np.sin(xx * rng.uniform(4, 9) + ph) * 0.4 + 0.06 * _noise(rng, N, 6)
                w = 0.006 + 0.01 * np.clip(1 - np.abs(xx - 0.5) * 2, 0, 1)
                line = np.maximum(line, np.clip(1 - np.abs(yy - path) / w, 0, 1))
                yy, xx = xx, yy
            a = np.clip(line * edge ** 0.3 * 1.2, 0, 1)
            c = np.stack([np.full((N, N), 0.04)] * 3, -1)
        elif name == "frost":
            fe = np.clip(n2 * 0.6 + n3 * 0.5 + 0.2, 0, 1)
            a = np.clip(edge ** 0.6 * fe, 0, 1) * 0.85
            c = np.stack([0.92 + 0.05 * n3 * 0.2, 0.96 + 0.0 * n3, 1.0 + 0 * n3], -1)
        elif name == "drip":
            # streaks running down (decal +V is the wall's down once laid)
            x0 = xx + 0.03 * _noise(rng, N, 10)
            streak = np.zeros((N, N))
            for _ in range(7):
                cx, w = rng.uniform(0.2, 0.8), rng.uniform(0.01, 0.04)
                top, ln = rng.uniform(0.05, 0.3), rng.uniform(0.4, 0.9)
                s = np.clip(1 - np.abs(x0 - cx) / w, 0, 1) * np.clip((yy - top) * 8, 0, 1) * np.clip((top + ln - yy) * 4, 0, 1)
                streak = np.maximum(streak, s)
            a = np.clip(streak * 0.75 * (0.8 + 0.2 * n1), 0, 1)
            c = np.stack([np.full((N, N), 0.16), np.full((N, N), 0.13), np.full((N, N), 0.10)], -1)
        elif name == "calcite":
            a = np.clip(edge ** 0.7 * (0.55 + 0.35 * n1 + 0.15 * n3), 0, 1) * 0.8
            c = np.stack([0.86 + 0.04 * n2 * 0.2, 0.82 + 0 * n2, 0.72 + 0 * n2], -1)
        elif name == "salt":
            a = np.clip(edge ** 0.5 * np.clip(n3 * 0.7 + n2 * 0.4 + 0.3, 0, 1), 0, 1) * 0.9
            c = np.stack([np.full((N, N), 0.96)] * 3, -1)
        else:  # sulfur
            a = np.clip(edge ** 0.6 * np.clip(n1 * 0.5 + n3 * 0.4 + 0.45, 0, 1), 0, 1) * 0.85
            c = np.stack([0.95 + 0 * n1, 0.82 + 0.05 * n2 * 0.2, 0.2 + 0 * n1], -1)
        rgba = np.concatenate([np.clip(c, 0, 1), a[..., None]], -1)
        Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(DECALS, f"cave_{name}.png"))
        yy, xx = np.mgrid[0:N, 0:N] / N
    print("  decals: 7")


def main():
    print("textures")
    write_textures()
    print("models")
    write_models()
    write_decals()


if __name__ == "__main__":
    main()
