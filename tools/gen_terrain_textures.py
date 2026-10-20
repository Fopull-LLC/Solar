#!/usr/bin/env python3
"""Generate the planets' surface materials into textures/terrain/geo_*.png.

Everything is PROCEDURAL (numpy + PIL, fixed seeds): reproducible byte for
byte, no third-party image licence.

    python3 tools/gen_terrain_textures.py          # writes textures/terrain/geo_*.png
    python3 tools/gen_terrain_textures.py --sheet  # + a labelled contact sheet

WHAT THE ENGINE DOES WITH THEM (floptle-render raymarch.wgsl `triplanar`):
a terrain palette slot is ONE 256x256 RGBA8 albedo layer, projected on three
axes in object space (~4.5 m per tile at scale 1, per-slot `|scale=` in the
.palette), blended by the normal, and multiplied by the voxel's painted tint
x 1.6. There is no normal or roughness channel for terrain, so each image BAKES
its own small-scale relief into the albedo (a soft top-down light, cavity
darkening) — that is what keeps the ground from reading as flat painted noise.

The colour here is the material's own, at a natural brightness; the planet
generator (scripts/system_generator.lua, GEO_MATS) tints it near-neutral
(about 0.62 grey, which x 1.6 is ~1) and pushes it toward the world's chemistry,
so one basalt image is a black Icelandic flow on one world and a rust-stained
one on the next.

Every image tiles: all noise is synthesised in the frequency domain on a
torus, and all cell patterns measure distance with wrap-around.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "terrain")
N = 256

# ── tileable building blocks ────────────────────────────────────────────────


def fbm(seed, beta=2.0, lo=1.0, hi=None, n=N):
    """Tileable 1/f^beta noise, normalised to mean 0, std 1."""
    rng = np.random.default_rng(seed)
    w = rng.standard_normal((n, n))
    f = np.fft.fft2(w)
    fy = np.fft.fftfreq(n)[:, None] * n
    fx = np.fft.fftfreq(n)[None, :] * n
    k = np.sqrt(fx * fx + fy * fy)
    k[0, 0] = 1.0
    amp = 1.0 / k ** (beta / 2.0)
    amp[k < lo] = 0.0
    if hi is not None:
        amp[k > hi] = 0.0
    out = np.real(np.fft.ifft2(f * amp))
    out -= out.mean()
    return out / (out.std() + 1e-9)


def aniso(seed, sx=1.0, sy=1.0, beta=2.0, lo=1.0, n=N):
    """Tileable noise stretched along an axis (sx, sy scale the frequencies)."""
    rng = np.random.default_rng(seed)
    w = rng.standard_normal((n, n))
    f = np.fft.fft2(w)
    fy = np.fft.fftfreq(n)[:, None] * n
    fx = np.fft.fftfreq(n)[None, :] * n
    k = np.sqrt((fx * sx) ** 2 + (fy * sy) ** 2)
    k[0, 0] = 1.0
    amp = 1.0 / k ** (beta / 2.0)
    amp[np.sqrt(fx * fx + fy * fy) < lo] = 0.0
    out = np.real(np.fft.ifft2(f * amp))
    out -= out.mean()
    return out / (out.std() + 1e-9)


def voronoi(seed, count, n=N, jitter=1.0):
    """Wrap-around Worley: (F1, F2, cell id) per pixel, distances in pixels."""
    rng = np.random.default_rng(seed)
    pts = rng.random((count, 2)) * n
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    f1 = np.full((n, n), 1e9, np.float32)
    f2 = np.full((n, n), 1e9, np.float32)
    cid = np.zeros((n, n), np.int32)
    for i, (px, py) in enumerate(pts):
        dx = np.abs(xx - px)
        dx = np.minimum(dx, n - dx)
        dy = np.abs(yy - py)
        dy = np.minimum(dy, n - dy)
        d = np.sqrt(dx * dx + dy * dy)
        closer = d < f1
        f2 = np.where(closer, f1, np.minimum(f2, d))
        cid = np.where(closer, i, cid)
        f1 = np.where(closer, d, f1)
    return f1, f2, cid


def warp(field, seed, amount):
    """Domain-warp a tileable field by tileable noise (wrapping lookups)."""
    n = field.shape[0]
    ux = fbm(seed, 2.6, lo=1, hi=24) * amount
    uy = fbm(seed + 1, 2.6, lo=1, hi=24) * amount
    yy, xx = np.mgrid[0:n, 0:n]
    sx = (xx + ux).astype(np.int64) % n
    sy = (yy + uy).astype(np.int64) % n
    return field[sy, sx]


def norm01(a):
    a = a - a.min()
    return a / (a.max() + 1e-9)


def shade(h, strength=1.0, light=(-0.55, -0.45, 0.70)):
    """Baked relief light from a height map (pixels of height): Lambert from
    a high, soft key plus cavity darkening, around 1.0 on flat ground."""
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    nx, ny, nz = -gx * strength, -gy * strength, np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    lx, ly, lz = light
    ll = math.sqrt(lx * lx + ly * ly + lz * lz)
    d = (nx * lx + ny * ly + nz * lz) / (ln * ll)
    flat = lz / ll
    lam = 0.55 + 0.45 * d / flat
    # cavity: below the local mean is darker
    blur = h.copy()
    for s in (1, 2, 4):
        blur = (blur + np.roll(blur, s, 0) + np.roll(blur, -s, 0) + np.roll(blur, s, 1) + np.roll(blur, -s, 1)) / 5
    cav = np.clip(1.0 + (h - blur) * 0.08 * strength, 0.75, 1.12)
    return np.clip(lam * cav, 0.35, 1.45)


def ramp(t, stops):
    """Colour ramp: t in [0,1] -> RGB through (pos, (r,g,b)) stops."""
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (3,))
    ps = [s[0] for s in stops]
    cs = [np.array(s[1], float) / 255.0 for s in stops]
    for c in range(3):
        out[..., c] = np.interp(t, ps, [x[c] for x in cs])
    return out


def mix(a, b, m):
    m = np.clip(m, 0, 1)[..., None]
    return a * (1 - m) + b * m


def finish(rgb, light):
    return np.clip(rgb * light[..., None], 0, 1)


def blur(a, passes=1):
    for _ in range(passes):
        a = (a * 4 + np.roll(a, 1, 0) + np.roll(a, -1, 0) + np.roll(a, 1, 1) + np.roll(a, -1, 1)) / 8
    return a


# ── the materials ───────────────────────────────────────────────────────────
# Each returns an (N, N, 3) float image. Names are the file stems (geo_<name>).


def basalt():
    base = fbm(101, 2.2)
    grain = fbm(102, 0.6)
    f1, f2, _ = voronoi(103, 9)                  # columnar joints
    joints = np.clip(1 - (f2 - f1) / 3.0, 0, 1) ** 2
    ves = fbm(104, 0.3)                           # vesicles: tiny dark pits
    pits = np.clip((ves - 1.9) * 2.0, 0, 1)
    h = base * 3 + grain * 0.8 - joints * 6 - pits * 3
    col = ramp(norm01(base * 0.6 + grain * 0.4), [(0, (38, 38, 40)), (0.6, (66, 64, 63)), (1, (92, 88, 84))])
    col = mix(col, np.array([20, 20, 22]) / 255.0, joints * 0.7 + pits * 0.8)
    return finish(col * 1.35, shade(h, 1.2))


def granite():
    g1 = fbm(111, 0.2)
    g2 = fbm(112, 0.4)
    base = fbm(113, 2.4)
    col = ramp(norm01(base), [(0, (150, 136, 130)), (1, (190, 176, 168))])
    feld = np.clip((g1 - 0.6) * 3, 0, 1)          # pink feldspar
    mica = np.clip((g2 - 1.1) * 3, 0, 1)          # black biotite
    quartz = np.clip((-g1 - 1.0) * 3, 0, 1)
    col = mix(col, np.array([196, 140, 120]) / 255.0, feld * 0.8)
    col = mix(col, np.array([40, 38, 40]) / 255.0, mica)
    col = mix(col, np.array([220, 218, 214]) / 255.0, quartz * 0.7)
    f1, f2, _ = voronoi(114, 5)
    crack = np.clip(1 - (f2 - f1) / 1.6, 0, 1) ** 3
    h = base * 3 - crack * 5 + g2 * 0.3
    return finish(col * 0.85, shade(h, 1.0))


def sandstone():
    n = N
    yy = np.mgrid[0:n, 0:n][0] / n
    wob = fbm(121, 3.0, hi=12) * 0.05
    layers = np.sin((yy + wob) * 2 * math.pi * 9) * 0.5 + 0.5
    fine = np.sin((yy + wob * 1.6) * 2 * math.pi * 31) * 0.5 + 0.5
    grain = fbm(122, 0.5)
    base = fbm(123, 2.4)
    t = norm01(layers * 0.55 + fine * 0.2 + base * 0.15)
    col = ramp(t, [(0, (150, 92, 58)), (0.45, (196, 136, 88)), (0.75, (214, 168, 116)), (1, (226, 190, 140))])
    col = col * (1 + grain[..., None] * 0.04)
    h = layers * 3 + fine * 1.2 + base * 2 + grain * 0.4
    return finish(col * 0.9, shade(h, 1.1))


def sand():
    n = N
    yy, xx = np.mgrid[0:n, 0:n] / n
    wob = fbm(131, 3.2, hi=10) * 0.06
    rip = np.sin((xx * 1.0 + yy * 0.25 + wob) * 2 * math.pi * 14)
    rip = np.sign(rip) * np.abs(rip) ** 0.7       # asymmetric crests
    grain = fbm(132, 0.2)
    base = fbm(133, 2.6)
    col = ramp(norm01(base * 0.6 + grain * 0.2), [(0, (190, 160, 112)), (1, (228, 204, 156))])
    dark = np.clip((grain - 1.6), 0, 1)           # dark mineral grains
    col = mix(col, np.array([90, 80, 70]) / 255.0, dark * 0.7)
    h = rip * 1.6 + base * 1.0 + grain * 0.25
    return finish(col * 0.82, shade(h, 1.0))


def regolith():
    base = fbm(141, 2.3)
    grain = fbm(142, 0.4)
    h = base * 2.5 + grain * 0.5
    rng = np.random.default_rng(143)
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    for _ in range(26):                            # micro-craters
        cx, cy = rng.random(2) * N
        r = rng.uniform(3, 18) if rng.random() < 0.85 else rng.uniform(18, 34)
        dx = np.minimum(np.abs(xx - cx), N - np.abs(xx - cx))
        dy = np.minimum(np.abs(yy - cy), N - np.abs(yy - cy))
        d = np.sqrt(dx * dx + dy * dy) / r
        h += (np.where(d < 1, (d * d - 1) * 2.2, 0) + np.exp(-((d - 1.05) ** 2) / 0.02) * 0.9) * r / 10
    pebble = np.clip((fbm(144, 0.1) - 2.0) * 2, 0, 1)
    h += pebble * 1.5
    col = ramp(norm01(base * 0.5 + grain * 0.5), [(0, (96, 94, 92)), (1, (150, 146, 140))])
    col = mix(col, np.array([170, 168, 162]) / 255.0, pebble * 0.6)
    return finish(col * 1.05, shade(h, 1.2))


def salt():
    f1, f2, cid = voronoi(151, 22)
    f1 = warp(f1, 152, 3)
    f2 = warp(f2, 152, 3)
    edge = np.exp(-((f2 - f1) ** 2) / 6.0)       # raised polygon ridges
    base = fbm(153, 2.4)
    grain = fbm(154, 0.3)
    h = edge * 3.5 + base * 0.8 + grain * 0.3
    col = ramp(norm01(base * 0.7 + grain * 0.3), [(0, (205, 200, 192)), (1, (240, 238, 232))])
    dirt = np.clip(fbm(155, 2.0) * 0.5, 0, 1) * (1 - edge)
    col = mix(col, np.array([180, 166, 146]) / 255.0, dirt * 0.5)
    return finish(col * 0.88, shade(h, 1.0))


def mudcrack():
    f1, f2, _ = voronoi(161, 30)
    f1 = warp(f1, 162, 2.5)
    f2 = warp(f2, 162, 2.5)
    gap = f2 - f1
    crack = np.clip(1 - gap / 2.2, 0, 1)
    curl = np.clip(gap / 14.0, 0, 1)              # plates curl up at the edges
    base = fbm(163, 2.2)
    grain = fbm(164, 0.5)
    h = -crack * 5 + (1 - curl) * 1.2 + base * 0.8 + grain * 0.2
    col = ramp(norm01(base * 0.6 + grain * 0.4), [(0, (140, 112, 84)), (1, (182, 152, 116))])
    col = mix(col, np.array([52, 40, 32]) / 255.0, crack ** 1.5)
    return finish(col * 0.95, shade(h, 1.1))


def moss():
    soil = fbm(171, 2.2)
    clump = fbm(172, 2.8, hi=40)
    fine = fbm(173, 0.3)
    blades = aniso(174, 1.0, 0.18, 0.4)
    cover = np.clip((clump + 0.35) * 1.1 + fine * 0.35, 0, 1)
    soil_c = ramp(norm01(soil), [(0, (64, 50, 38)), (1, (104, 84, 62))])
    moss_c = ramp(norm01(fine * 0.6 + clump * 0.3 + blades * 0.4), [(0, (44, 58, 30)), (0.55, (72, 92, 42)), (1, (112, 124, 62))])
    col = mix(soil_c, moss_c, cover)
    stones = np.clip((fbm(175, 0.6) - 1.8) * 2, 0, 1) * (1 - cover)
    col = mix(col, np.array([120, 116, 108]) / 255.0, stones)
    h = cover * 3 + fine * 0.9 + blades * 0.4 * cover + stones * 1.5
    return finish(col * 1.2, shade(h, 1.1))


def ash():
    base = fbm(181, 2.6)
    grain = fbm(182, 0.5)
    n = N
    yy, xx = np.mgrid[0:n, 0:n] / n
    drift = np.sin((xx * 0.4 + yy + fbm(183, 3, hi=8) * 0.08) * 2 * math.pi * 6) * 0.5
    lap = np.clip((fbm(184, 0.4) - 1.7) * 2, 0, 1)   # lapilli
    h = base * 2 + drift * 1.2 + grain * 0.3 + lap
    col = ramp(norm01(base * 0.6 + grain * 0.4), [(0, (40, 38, 38)), (1, (78, 72, 68))])
    col = mix(col, np.array([110, 70, 54]) / 255.0, lap * 0.5)
    return finish(col * 1.3, shade(h, 1.0))


def snow():
    n = N
    yy, xx = np.mgrid[0:n, 0:n] / n
    base = fbm(191, 2.8)
    sast = aniso(192, 0.25, 1.0, 2.2, lo=2)        # sastrugi: wind-carved ridges
    sparkle = np.clip((fbm(193, 0.0) - 2.6) * 3, 0, 1)
    h = base * 2 + sast * 1.6
    col = ramp(norm01(base * 0.5 + sast * 0.5), [(0, (206, 216, 228)), (1, (246, 248, 252))])
    col = col + sparkle[..., None] * 0.15
    return finish(col * 0.85, shade(h, 0.8, light=(-0.4, -0.3, 0.86)))


def glacier():
    base = fbm(201, 2.4)
    f1, f2, _ = voronoi(202, 7)
    f1 = warp(f1, 203, 6)
    f2 = warp(f2, 203, 6)
    crack = np.exp(-((f2 - f1) ** 2) / 2.0)
    bub = np.clip((fbm(204, 0.4) - 1.6) * 1.5, 0, 1)
    depth = norm01(fbm(205, 2.8))
    col = ramp(depth, [(0, (120, 170, 200)), (0.6, (170, 210, 228)), (1, (214, 234, 242))])
    col = mix(col, np.array([236, 244, 250]) / 255.0, crack * 0.8 + bub * 0.4)
    h = base * 1.5 + crack * 1.0
    return finish(col * 0.86, shade(h, 0.7))


def scree():
    f1, f2, cid = voronoi(211, 70)
    rng = np.random.default_rng(212)
    tone = rng.uniform(0.75, 1.2, 70)[cid]
    hue = rng.integers(0, 3, 70)[cid]
    dome = np.clip(f2 - f1, 0, 9) ** 0.6           # each stone a rounded dome
    grain = fbm(213, 0.6)
    h = dome * 1.5 + grain * 0.3
    pal = np.array([[122, 118, 112], [140, 128, 112], [100, 100, 104]]) / 255.0
    col = pal[hue] * tone[..., None]
    gap = np.clip(1 - (f2 - f1) / 2.0, 0, 1)
    col = mix(col, np.array([50, 46, 42]) / 255.0, gap)
    col = col * (1 + grain[..., None] * 0.05)
    return finish(col * 1.05, shade(h, 1.3))


def limestone():
    base = fbm(221, 2.3)
    pits = np.clip((fbm(222, 0.8) - 1.5) * 1.5, 0, 1)
    fos = np.clip((fbm(223, 1.4, hi=60) - 1.9) * 2, 0, 1)
    f1, f2, _ = voronoi(224, 6)
    crack = np.clip(1 - (f2 - f1) / 1.5, 0, 1) ** 2
    h = base * 2.5 - pits * 2 - crack * 4 + fos
    col = ramp(norm01(base), [(0, (186, 178, 158)), (1, (226, 220, 200))])
    col = mix(col, np.array([140, 132, 112]) / 255.0, pits * 0.6 + crack * 0.6)
    return finish(col * 0.88, shade(h, 1.0))


def sulfur():
    f1, f2, cid = voronoi(231, 40)
    rng = np.random.default_rng(232)
    xtal = np.clip(f2 - f1, 0, 6) / 6.0
    crust = np.clip((fbm(233, 2.6) + 0.3) * 0.9 + fbm(237, 0.8) * 0.2, 0, 1)
    grain = fbm(234, 0.4)
    ground = ramp(norm01(fbm(235, 2.2)), [(0, (150, 140, 104)), (1, (190, 178, 130))])
    yel = ramp(xtal * (0.7 + 0.3 * rng.random(40)[cid]), [(0, (168, 146, 52)), (1, (222, 202, 96))])
    col = mix(ground, yel, crust)
    stain = np.clip((fbm(236, 2.4) - 1.0), 0, 1)
    col = mix(col, np.array([170, 96, 40]) / 255.0, stain * 0.5)
    h = crust * 2.5 + xtal * crust * 1.5 + grain * 0.3
    return finish(col * 0.88, shade(h, 1.1))


def hematite():
    base = fbm(241, 2.3)
    grain = fbm(242, 0.5)
    rock = np.clip((fbm(243, 1.0) - 1.4) * 1.8, 0, 1)
    h = base * 2 + grain * 0.4 + rock * 2.2
    col = ramp(norm01(base * 0.6 + grain * 0.4), [(0, (110, 50, 32)), (0.5, (150, 72, 44)), (1, (182, 104, 64))])
    col = mix(col, np.array([70, 44, 36]) / 255.0, rock * 0.8)
    return finish(col * 1.0, shade(h, 1.1))


def tundra():
    f1, f2, cid = voronoi(251, 14)
    f1 = warp(f1, 252, 4)
    f2 = warp(f2, 252, 4)
    trough = np.clip(1 - (f2 - f1) / 7.0, 0, 1)
    lichen = np.clip((fbm(253, 1.2) - 0.4) * 1.5, 0, 1)
    stones = np.clip((fbm(254, 0.5) - 1.6) * 2, 0, 1) * trough
    soil = ramp(norm01(fbm(255, 2.2)), [(0, (92, 82, 64)), (1, (132, 120, 92))])
    col = mix(soil, np.array([120, 128, 82]) / 255.0, lichen * 0.6)
    col = mix(col, np.array([170, 168, 150]) / 255.0, lichen * np.clip(fbm(256, 0.3), 0, 1) * 0.5)
    col = mix(col, np.array([128, 126, 122]) / 255.0, stones)
    col = mix(col, np.array([60, 56, 46]) / 255.0, trough ** 2 * 0.6)
    h = -trough * 3 + lichen * 0.6 + stones * 1.5 + fbm(257, 2.4)
    return finish(col * 1.1, shade(h, 1.1))


def pahoehoe():
    n = N
    yy, xx = np.mgrid[0:n, 0:n] / n
    flow = fbm(261, 3.0, hi=6) * 0.15
    ropes = np.sin((yy + flow + np.sin(xx * 2 * math.pi * 2) * 0.03) * 2 * math.pi * 26)
    lobes = fbm(262, 2.8)
    h = ropes * 0.8 * np.clip(lobes + 0.8, 0, 1.5) + lobes * 3
    sheen = np.clip(fbm(263, 1.5), 0, 1)
    col = ramp(norm01(lobes), [(0, (30, 28, 30)), (1, (66, 60, 58))])
    col = mix(col, np.array([110, 104, 112]) / 255.0, sheen * 0.35)
    ox = np.clip((fbm(264, 2.0) - 1.2), 0, 1)
    col = mix(col, np.array([110, 60, 40]) / 255.0, ox * 0.5)
    return finish(col * 1.35, shade(h, 1.4))


def shale():
    n = N
    yy = np.mgrid[0:n, 0:n][0] / n
    wob = fbm(271, 3.0, hi=10) * 0.03
    lam = np.sin((yy + wob) * 2 * math.pi * 40) * 0.5 + 0.5
    beds = np.sin((yy + wob) * 2 * math.pi * 7) * 0.5 + 0.5
    base = fbm(272, 2.4)
    f1, f2, _ = voronoi(273, 8)
    crack = np.clip(1 - (f2 - f1) / 1.4, 0, 1) ** 2
    h = lam * 0.8 + beds * 2 + base * 1.5 - crack * 3
    col = ramp(norm01(beds * 0.5 + base * 0.3 + lam * 0.2), [(0, (58, 60, 64)), (1, (104, 104, 106))])
    return finish(col * 1.2, shade(h, 1.2))


def peat():
    base = fbm(281, 2.4)
    fib = aniso(282, 1.0, 0.2, 0.6)
    wet = np.clip((fbm(283, 2.8, hi=30) - 0.6) * 2, 0, 1)
    h = base * 2 + fib * 0.5 - wet * 2
    col = ramp(norm01(base * 0.6 + fib * 0.4), [(0, (40, 30, 22)), (1, (88, 66, 44))])
    col = mix(col, np.array([30, 34, 30]) / 255.0, wet * 0.6)
    col = col + (wet * np.clip(fbm(284, 0.5) - 0.8, 0, 1))[..., None] * 0.25   # glints
    sedge = np.clip((fbm(285, 1.2) - 1.1) * 2, 0, 1) * (1 - wet)
    col = mix(col, np.array([96, 108, 54]) / 255.0, sedge * 0.7)
    return finish(col * 1.25, shade(h, 0.9))


def litter():
    soil = ramp(norm01(fbm(291, 2.2)), [(0, (50, 36, 24)), (1, (86, 64, 42))])
    col = soil.copy()
    h = fbm(292, 2.2) * 1.5
    img = Image.new("RGB", (N * 3, N * 3), (0, 0, 0))
    hm = Image.new("L", (N * 3, N * 3), 0)
    d = ImageDraw.Draw(img)
    dh = ImageDraw.Draw(hm)
    rng = np.random.default_rng(293)
    pal = [(120, 82, 40), (150, 104, 48), (96, 70, 36), (70, 92, 40), (160, 120, 60), (110, 58, 34)]
    for i in range(420):
        cx, cy = rng.random(2) * N + N
        L = rng.uniform(8, 20)
        W = L * rng.uniform(0.3, 0.5)
        a = rng.random() * math.pi
        ca, sa = math.cos(a), math.sin(a)
        poly = []
        for k in range(12):
            t = k / 12 * 2 * math.pi
            x, y = math.cos(t) * L / 2, math.sin(t) * W / 2 * (1 - 0.3 * math.cos(t))
            poly.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
        c = pal[rng.integers(0, len(pal))]
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                pp = [(x + ox, y + oy) for x, y in poly]
                d.polygon(pp, fill=c)
                dh.polygon(pp, fill=int(40 + i * 0.5))
    leaves = np.asarray(img).astype(float)[N:2 * N, N:2 * N] / 255.0
    lh = np.asarray(hm).astype(float)[N:2 * N, N:2 * N] / 255.0
    m = (lh > 0).astype(float)
    col = mix(col, leaves, m * 0.95)
    h = h + lh * 6
    return finish(col * 1.3, shade(blur(h), 1.2))


# Slot order IS the palette order (slot 13 = first). Never reorder: a world's
# painted voxels store the slot number, so moving a material repaints every
# planet already generated. Append only.
MATERIALS = [
    ("basalt", basalt), ("granite", granite), ("sandstone", sandstone), ("sand", sand),
    ("regolith", regolith), ("salt", salt), ("mudcrack", mudcrack), ("moss", moss),
    ("ash", ash), ("snow", snow), ("glacier", glacier), ("scree", scree),
    ("limestone", limestone), ("sulfur", sulfur), ("hematite", hematite), ("tundra", tundra),
    ("pahoehoe", pahoehoe), ("shale", shale), ("peat", peat), ("litter", litter),
]
FIRST_SLOT = 13


def main():
    os.makedirs(OUT, exist_ok=True)
    tiles = []
    for i, (name, fn) in enumerate(MATERIALS):
        img = (np.clip(fn(), 0, 1) * 255 + 0.5).astype(np.uint8)
        path = os.path.join(OUT, f"geo_{name}.png")
        Image.fromarray(img, "RGB").save(path, optimize=True)
        m = img.reshape(-1, 3).mean(0) / 255
        print(f"slot {FIRST_SLOT + i:2d}  geo_{name:10s} mean {m.round(2)}")
        tiles.append((name, img))
    if "--sheet" in sys.argv:
        cols = 5
        rows = (len(tiles) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * 2 * N // 2, rows * (N + 18)), (20, 20, 20))
        d = ImageDraw.Draw(sheet)
        for i, (name, img) in enumerate(tiles):
            x, y = (i % cols) * N, (i // cols) * (N + 18)
            sheet.paste(Image.fromarray(img).resize((N, N)), (x, y + 18))
            d.text((x + 4, y + 3), f"{FIRST_SLOT + i} {name}", fill=(230, 230, 230))
        p = sys.argv[sys.argv.index("--sheet") + 1] if len(sys.argv) > sys.argv.index("--sheet") + 1 else os.path.join(OUT, "..", "geo_sheet.png")
        sheet.save(p)
        print("sheet", p)


if __name__ == "__main__":
    main()
