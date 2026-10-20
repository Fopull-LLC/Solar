#!/usr/bin/env python3
"""Generate the rocket parts' surface textures into textures/parts/.

Everything here is PROCEDURAL — random fields, geometry and text drawn with
numpy + PIL from fixed seeds — so the set is reproducible byte for byte and
carries no third-party image licence. See textures/parts/SOURCES.md.

    python3 tools/gen_part_textures.py            # writes textures/parts/*.png

The set is a small SHARED library, not one picture per part: every part's mesh
(tools/gen_part_meshes.py) names a few of these materials and tiles them by
world size, so a tank and a pod read as the same family of hardware and the GPU
holds one copy of each map.

Per material: `<name>_albedo.png`, `<name>_normal.png` (tangent space, OpenGL
+Y), and `<name>_orm.png` — glTF's packed layout, R = ambient occlusion,
G = roughness, B = metallic — so one image feeds the engine's ao_map,
roughness_map and metallic_map slots at once.

  paint     white-painted aluminium skin, 1 m tile: staggered panels, bevelled
            seams, rivet rows, screwed access hatches, streaked grime, chips
  metal     brushed bare alloy, 0.5 m tile: brush grain, seams, hex bolts
            (tinted dark in a material for anodised or gunmetal parts)
  tiles     black thermal-protection tiles, 0.5 m tile, staggered, gap filler
  ablative  heat-shield honeycomb, charred
  bell      engine nozzle, NOT tiled along its length: regenerative-cooling
            tubes, heat-tint bands (straw/bronze/blue), dark throat
  foil      gold multi-layer insulation, crinkled, with tape seams
  solar     photovoltaic cells, busbars and fingers
  tread     diamond tread plate, 0.5 m tile: raised lozenges in a staggered
            grid on scuffed bare alloy (deck plates, rover decks, structure)
  rubber    tyre rubber, 0.5 m tile along the tread: chevron lugs, sipes,
            dust in the grooves (the rover wheels)
  markings  RGBA decal atlas: names, numbers, hazard stripes, a flag, labels
  interior  cabin atlas: quilted wall padding, console, seat, suit, screens
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "parts")
FONT_BOLD = "/usr/share/fonts/noto/NotoSans-Bold.ttf"
FONT_BLACK = "/usr/share/fonts/noto/NotoSans-Black.ttf"
FONT_MONO = os.path.join(ROOT, "fonts", "NotoSansMono-Medium.ttf")


# ── fields ──────────────────────────────────────────────────────────────────

def spectral(h, w, rng, beta=1.8, sx=1.0, sy=1.0, lo=2.0):
    """Tileable fractal noise, 0..1: white noise shaped by 1/f^beta in Fourier
    space (periodic by construction, so every map tiles seamlessly). sx/sy
    stretch it (sx > sy streaks along x)."""
    n = rng.standard_normal((h, w))
    fy = np.fft.fftfreq(h)[:, None] * h / sy
    fx = np.fft.fftfreq(w)[None, :] * w / sx
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    amp = 1.0 / np.maximum(f, lo) ** beta
    amp[0, 0] = 0.0
    r = np.real(np.fft.ifft2(np.fft.fft2(n) * amp))
    r -= r.min()
    return (r / max(r.max(), 1e-9)).astype(np.float32)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def normal_from_height(hgt, strength):
    """Tangent-space normal map from a height field (wraps at the edges)."""
    dx = (np.roll(hgt, -1, 1) - np.roll(hgt, 1, 1)) * 0.5
    dy = (np.roll(hgt, -1, 0) - np.roll(hgt, 1, 0)) * 0.5
    # Image rows run DOWN, texture +Y (green) points UP the image.
    nx, ny, nz = -dx * strength, dy * strength, np.ones_like(hgt)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / l, ny / l, nz / l], -1)
    return (n * 0.5 + 0.5)


def save_rgb(arr, name, size=None):
    """size: downsample on save (texture memory: GPU cost is w × h × 4 × 4/3)."""
    a = np.clip(arr, 0, 1)
    im = Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGB")
    if size and im.size[0] > size:
        im = im.resize((size, size * im.size[1] // im.size[0]), Image.LANCZOS)
    im.save(os.path.join(OUT, name), optimize=True)


def save_orm(ao, rough, metal, name, size=None):
    save_rgb(np.stack([ao, rough, metal], -1), name, size)


def dist_to_lines(coord, positions, period):
    """Distance (px) from each coordinate to the nearest of `positions` (mod period)."""
    d = np.full(coord.shape, 1e9, np.float32)
    for p in positions:
        q = np.abs(((coord - p) + period / 2) % period - period / 2)
        d = np.minimum(d, q)
    return d


def stamp_domes(hgt, centers, radius, height, mask=None):
    """Add hemispherical bumps (rivets, bolt heads) at pixel centers (wrapping)."""
    H, W = hgt.shape
    r = int(math.ceil(radius)) + 1
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    for (cx, cy) in centers:
        ix, iy = int(round(cx)), int(round(cy))
        fx, fy = cx - ix, cy - iy
        rr = np.sqrt((xx - fx) ** 2 + (yy - fy) ** 2) / radius
        dome = np.sqrt(np.clip(1 - rr * rr, 0, 1)) * height
        ys = (iy + yy) % H
        xs = (ix + xx) % W
        hgt[ys, xs] = np.where(dome > 0, np.maximum(hgt[ys, xs], dome), hgt[ys, xs])
        if mask is not None:
            mask[ys, xs] = np.maximum(mask[ys, xs], (rr < 1.0).astype(np.float32))


def stamp_hexbolts(hgt, centers, radius, height, mask=None, washer=1.45):
    """Hex bolt heads on a round washer."""
    H, W = hgt.shape
    r = int(math.ceil(radius * washer)) + 2
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1].astype(np.float32)
    ang = np.arctan2(yy, xx)
    rad = np.sqrt(xx * xx + yy * yy)
    # hexagon "radius" in direction ang
    hexr = radius * math.cos(math.pi / 6) / np.cos(((ang + math.pi / 6) % (math.pi / 3)) - math.pi / 6)
    head = (rad < hexr).astype(np.float32) * height
    wash = (rad < radius * washer).astype(np.float32) * height * 0.35
    shape = np.maximum(head, wash) * (1 - 0.15 * smoothstep(0.0, hexr, rad))
    for (cx, cy) in centers:
        ix, iy = int(round(cx)), int(round(cy))
        ys = (iy + yy.astype(int)) % H
        xs = (ix + xx.astype(int)) % W
        hgt[ys, xs] = np.where(shape > 0, np.maximum(hgt[ys, xs], shape), hgt[ys, xs])
        if mask is not None:
            mask[ys, xs] = np.maximum(mask[ys, xs], (rad < radius * washer).astype(np.float32))


def stamp_screws(hgt, centers, radius, depth):
    """Countersunk cross-head screws: a shallow dish with a + slot."""
    H, W = hgt.shape
    r = int(math.ceil(radius)) + 1
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1].astype(np.float32)
    rad = np.sqrt(xx * xx + yy * yy)
    dish = -depth * 0.35 * (rad < radius)
    slot = ((np.abs(xx) < radius * 0.18) | (np.abs(yy) < radius * 0.18)) & (rad < radius * 0.75)
    shape = dish - depth * slot
    ring = (np.abs(rad - radius) < 0.8) * (-depth * 0.4)
    shape = shape + ring
    for (cx, cy) in centers:
        ix, iy = int(round(cx)), int(round(cy))
        ys = (iy + yy.astype(int)) % H
        xs = (ix + xx.astype(int)) % W
        hgt[ys, xs] = hgt[ys, xs] + shape


def rect_groove(hgt, x0, y0, x1, y1, depth, width=1.6):
    """A recessed outline (access hatch) on the height field."""
    H, W = hgt.shape
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    inside = (xx >= x0 - 3) & (xx <= x1 + 3) & (yy >= y0 - 3) & (yy <= y1 + 3)
    dx = np.minimum(np.abs(xx - x0), np.abs(xx - x1))
    dy = np.minimum(np.abs(yy - y0), np.abs(yy - y1))
    onx = (yy >= y0) & (yy <= y1)
    ony = (xx >= x0) & (xx <= x1)
    d = np.where(onx, dx, 1e9)
    d = np.minimum(d, np.where(ony, dy, 1e9))
    g = np.exp(-(d / width) ** 2) * inside
    hgt -= g * depth
    return g


# ── paint: white aluminium skin ─────────────────────────────────────────────

def gen_paint(S=1024, seed=11):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    hgt = np.zeros((S, S), np.float32)
    half = S // 2
    # Two rows of panels, 0.5 m tall; the second row's vertical seams are
    # staggered by a quarter, like a riveted launch-vehicle skin.
    row = (yy >= half).astype(np.float32)
    dv = dist_to_lines(yy, [0, half], S)
    du_a = dist_to_lines(xx, [0, half], S)
    du_b = dist_to_lines(xx, [S // 4, 3 * S // 4], S)
    du = np.where(row > 0, du_b, du_a)
    seam = np.minimum(dv, du)
    # Bevel: plates roll down into a 2 px groove.
    hgt -= 1.0 * np.exp(-(seam / 1.8) ** 2)
    hgt -= 0.35 * (1 - smoothstep(0, 7, seam))
    # Per-panel tone, so it reads as separate sheets.
    panel_id = (yy // half) * 4 + np.where(row > 0, ((xx + S // 4) % S) // half, xx // half)
    tones = rng.normal(0, 0.018, 64)
    tone = tones[panel_id.astype(int) % 64]
    # Rivet rows 10 px either side of every seam, 24 px pitch.
    rivet_mask = np.zeros((S, S), np.float32)
    centers = []
    for y in (0, half):
        for off in (-10, 10):
            for x in np.arange(6, S, 24):
                centers.append((x, (y + off) % S))
    for x in (0, half):  # row A verticals
        for off in (-10, 10):
            for y in np.arange(12, half - 6, 24):
                centers.append(((x + off) % S, y))
    for x in (S // 4, 3 * S // 4):  # row B verticals
        for off in (-10, 10):
            for y in np.arange(half + 12, S - 6, 24):
                centers.append(((x + off) % S, y))
    stamp_domes(hgt, centers, 3.0, 0.9, rivet_mask)
    # Screwed access hatches: a couple per tile, never across a seam.
    hatch_mask = np.zeros((S, S), np.float32)
    for (x0, y0, w, h) in ((90, 150, 150, 100), (640, 640, 110, 150), (300, 760, 90, 60)):
        g = rect_groove(hgt, x0, y0, x0 + w, y0 + h, 0.9)
        hatch_mask = np.maximum(hatch_mask, g)
        scr = [(x0 + 9, y0 + 9), (x0 + w - 9, y0 + 9), (x0 + 9, y0 + h - 9), (x0 + w - 9, y0 + h - 9)]
        stamp_screws(hgt, scr, 4.2, 0.8)
    # Doubler strip with a bolt row along one horizontal seam.
    strip = ((np.abs(yy - half) < 14)).astype(np.float32)
    hgt += 0.25 * strip * (1 - smoothstep(12, 14, np.abs(yy - half)))
    # Fine orange-peel of the paint, and dents.
    hgt += (spectral(S, S, rng, beta=1.0, lo=60) - 0.5) * 0.08
    hgt += (spectral(S, S, rng, beta=2.2, lo=3) - 0.5) * 0.25

    # Albedo: off-white with mottle, streaks running DOWN the skin, seam dirt.
    mottle = spectral(S, S, rng, beta=2.0, lo=3)
    streak = spectral(S, S, rng, beta=1.6, sx=8.0, sy=0.6, lo=2)
    streak = smoothstep(0.62, 0.9, streak) * 0.7
    cavity = np.exp(-(seam / 3.0) ** 2) + rivet_mask * 0.0
    base = np.array([0.86, 0.865, 0.85], np.float32)
    alb = np.ones((S, S, 3), np.float32) * base
    alb *= (1 + tone)[..., None]
    alb *= (0.95 + 0.07 * mottle)[..., None]
    grime = np.array([0.52, 0.48, 0.42], np.float32)
    g = np.clip(streak * 0.35 + cavity * 0.55, 0, 1)[..., None]
    alb = alb * (1 - g) + alb * grime * g
    # Paint chips: bare alloy showing at worn seam edges and random scuffs.
    chipn = spectral(S, S, rng, beta=0.8, lo=40)
    chips = ((chipn > 0.78) & (seam < 9)) | (chipn > 0.93)
    chips = chips.astype(np.float32)
    alb = alb * (1 - chips[..., None]) + np.array([0.58, 0.59, 0.6]) * chips[..., None]
    hgt -= chips * 0.15
    ao = np.clip(1 - 0.7 * np.exp(-(seam / 2.5) ** 2) - 0.25 * hatch_mask, 0, 1)
    rough = np.clip(0.42 + 0.25 * streak + 0.15 * cavity - 0.1 * rivet_mask + 0.05 * mottle, 0, 1)
    rough = np.where(chips > 0, 0.35, rough)
    metal = chips * 0.9
    save_rgb(alb, "paint_albedo.png")
    save_rgb(normal_from_height(hgt, 1.6), "paint_normal.png")
    save_orm(ao, rough, metal, "paint_orm.png", 512)


# ── metal: brushed bare alloy ───────────────────────────────────────────────

def gen_metal(S=512, seed=12):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    hgt = np.zeros((S, S), np.float32)
    brush = spectral(S, S, rng, beta=0.9, sx=40.0, sy=0.5, lo=4)
    hgt += (brush - 0.5) * 0.25
    seam = np.minimum(dist_to_lines(yy, [0], S), dist_to_lines(xx, [0], S))
    hgt -= np.exp(-(seam / 1.4) ** 2) * 1.0
    bolt_mask = np.zeros((S, S), np.float32)
    bolts = []
    for x in (14, S - 14):
        for y in np.arange(14, S, 54):
            bolts.append((x % S, y))
    for y in (14, S - 14):
        for x in np.arange(68, S - 40, 54):
            bolts.append((x, y % S))
    stamp_hexbolts(hgt, bolts, 4.5, 1.4, bolt_mask)
    mott = spectral(S, S, rng, beta=2.0, lo=2)
    alb = np.ones((S, S, 3), np.float32) * np.array([0.66, 0.665, 0.67])
    alb *= (0.86 + 0.18 * brush * 0.6 + 0.1 * mott)[..., None]
    alb *= (1 - 0.45 * np.exp(-(seam / 2.0) ** 2))[..., None]
    stain = smoothstep(0.6, 0.9, spectral(S, S, rng, beta=1.7, lo=2))
    alb *= (1 - 0.07 * stain)[..., None]
    ao = np.clip(1 - 0.6 * np.exp(-(seam / 2.0) ** 2), 0, 1)
    rough = np.clip(0.32 + 0.18 * brush + 0.2 * stain + 0.12 * bolt_mask, 0, 1)
    metal = np.ones_like(rough)
    save_rgb(alb, "metal_albedo.png")
    save_rgb(normal_from_height(hgt, 1.4), "metal_normal.png")
    save_orm(ao, rough, metal, "metal_orm.png")


# ── tiles: black thermal-protection tiles ───────────────────────────────────

def gen_tiles(S=512, seed=13):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    T = S // 4  # 0.125 m tiles on a 0.5 m map
    rowi = (yy // T).astype(int)
    xs = (xx + (rowi % 2) * (T // 2)) % S
    lx = xs % T
    ly = yy % T
    d = np.minimum(np.minimum(lx, T - 1 - lx), np.minimum(ly, T - 1 - ly))
    tid = rowi * 8 + (xs // T).astype(int)
    tone = rng.normal(0, 0.012, 64)[tid % 64]
    hgt = smoothstep(0, 5, d) * 1.0 - 1.0
    speck = spectral(S, S, rng, beta=0.5, lo=80)
    hgt += (speck - 0.5) * 0.15
    mott = spectral(S, S, rng, beta=2.0, lo=2)
    v = 0.065 + tone + 0.03 * mott + 0.02 * (speck - 0.5)
    alb = np.stack([v, v * 1.0, v * 1.04], -1)
    gap = d < 1.6
    alb[gap] = (0.42, 0.41, 0.39)
    # Heat streaks: faint lighter wash where the flow scoured them.
    st = smoothstep(0.62, 0.95, spectral(S, S, rng, beta=1.6, sx=0.6, sy=6, lo=2))
    alb += st[..., None] * 0.05
    ao = np.clip(0.55 + 0.45 * smoothstep(0, 4, d), 0, 1)
    rough = np.clip(0.78 + 0.1 * speck, 0, 1)
    save_rgb(alb, "tiles_albedo.png")
    save_rgb(normal_from_height(hgt, 2.0), "tiles_normal.png")
    save_orm(ao, rough, np.zeros_like(rough), "tiles_orm.png")


# ── ablative heat shield ────────────────────────────────────────────────────

def gen_ablative(S=512, seed=14):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    # Hex grid: cell size so it tiles exactly (32 cells across).
    n = 32
    a = S / n
    hgtc = a * math.sqrt(3) / 2
    rows = int(round(S / hgtc))
    sy = S / rows
    best = np.full((S, S), 1e9, np.float32)
    second = np.full((S, S), 1e9, np.float32)
    for r in range(-1, rows + 1):
        cy = r * sy
        off = (r % 2) * a / 2
        for c in range(-1, n + 1):
            cx = c * a + off
            dxx = np.abs(((xx - cx) + S / 2) % S - S / 2)
            dyy = np.abs(((yy - cy) + S / 2) % S - S / 2)
            dd = np.sqrt(dxx * dxx + dyy * dyy)
            m = dd < best
            second = np.where(m, best, np.minimum(second, dd))
            best = np.where(m, dd, best)
    edge = second - best  # 0 on the cell walls
    hgt = smoothstep(0, 3.0, edge) * -1.0
    char = spectral(S, S, rng, beta=1.8, lo=2)
    base = np.array([0.42, 0.29, 0.18])
    burnt = np.array([0.08, 0.06, 0.05])
    k = smoothstep(0.35, 0.8, char)[..., None]
    alb = base * (1 - k) + burnt * k
    alb *= (0.85 + 0.25 * spectral(S, S, rng, beta=0.6, lo=60))[..., None]
    walls = (1 - smoothstep(0, 2.0, edge))[..., None]
    alb = alb * (1 - walls * 0.5)
    hgt += (char - 0.5) * 0.6
    ao = np.clip(0.6 + 0.4 * smoothstep(0, 3, edge), 0, 1)
    rough = np.clip(0.85 + 0.1 * char, 0, 1)
    save_rgb(alb, "ablative_albedo.png")
    save_rgb(normal_from_height(hgt, 1.6), "ablative_normal.png")
    save_orm(ao, rough, np.zeros_like(rough), "ablative_orm.png")


# ── bell: engine nozzle with heat tint ──────────────────────────────────────

def gen_bell(W=512, H=1024, seed=15):
    """u = around the bell (tiles), v = 0 at the throat → 1 at the exit lip."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    v = yy / (H - 1)
    tubes = 40  # per texture width; the bell wraps it twice → 80 tubes round
    ph = (xx / W) * tubes * 2 * math.pi
    hgt = (np.cos(ph) * 0.5 + 0.5) ** 0.6 * 0.9
    # The tube jacket ends at 70 % and a plain radiatively-cooled skirt runs
    # to the lip, with a stiffening hoop at the joint.
    skirt = smoothstep(0.69, 0.71, v)
    hgt = hgt * (1 - skirt)
    hoop = np.exp(-((v - 0.70) / 0.008) ** 2)
    hgt += hoop * 1.2 + np.exp(-((v - 0.985) / 0.006) ** 2) * 1.0
    streak = spectral(H, W, rng, beta=1.5, sx=0.4, sy=12, lo=2)
    hgt += (streak - 0.5) * 0.2
    # Heat-tint ramp down the bell: dark throat, then the temper colours a
    # steel/niobium skirt takes (blue → purple → bronze → straw → bare).
    stops = [
        (0.00, (0.16, 0.14, 0.13)),
        (0.10, (0.22, 0.19, 0.17)),
        (0.18, (0.30, 0.22, 0.14)),
        (0.26, (0.36, 0.24, 0.30)),
        (0.33, (0.20, 0.26, 0.52)),
        (0.42, (0.30, 0.42, 0.62)),
        (0.52, (0.62, 0.50, 0.30)),
        (0.62, (0.72, 0.60, 0.40)),
        (0.72, (0.62, 0.60, 0.58)),
        (1.00, (0.70, 0.69, 0.68)),
    ]
    col = np.zeros((H, W, 3), np.float32)
    for i in range(len(stops) - 1):
        a, ca = stops[i]
        b, cb = stops[i + 1]
        t = np.clip((v - a) / (b - a), 0, 1)[..., None]
        m = ((v >= a) & (v <= b))[..., None]
        col = np.where(m, np.array(ca) * (1 - t) + np.array(cb) * t, col)
    # Wobble the bands so they are not ruler-straight.
    wob = spectral(H, W, rng, beta=2.2, lo=2)
    col *= (0.85 + 0.3 * wob)[..., None]
    col *= (0.8 + 0.3 * streak)[..., None]
    col *= (0.75 + 0.25 * hgt.clip(0, 1))[..., None]
    soot = smoothstep(0.55, 0.9, spectral(H, W, rng, beta=1.4, sx=0.5, sy=10, lo=2)) * smoothstep(0.75, 1.0, v)
    col *= (1 - 0.5 * soot)[..., None]
    ao = np.clip(0.7 + 0.3 * hgt.clip(0, 1), 0, 1)
    rough = np.clip(0.38 + 0.25 * streak + 0.2 * soot, 0, 1)
    save_rgb(col, "bell_albedo.png")
    save_rgb(normal_from_height(hgt, 2.2), "bell_normal.png")
    save_orm(ao, rough, np.ones_like(rough) * 0.95, "bell_orm.png")


# ── foil: gold MLI blanket ──────────────────────────────────────────────────

def gen_foil(S=512, seed=16):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    n1 = spectral(S, S, rng, beta=1.6, lo=4)
    n2 = spectral(S, S, rng, beta=1.4, lo=10)
    n3 = spectral(S, S, rng, beta=1.2, lo=25)
    # Ridged noise: creases where the field crosses its middle.
    hgt = (1 - np.abs(n1 - 0.5) * 2) ** 3 * 1.0 + (1 - np.abs(n2 - 0.5) * 2) ** 3 * 0.6 + (1 - np.abs(n3 - 0.5) * 2) ** 2 * 0.25
    tape = (np.abs(yy - S * 0.75) < 14).astype(np.float32)
    tape_e = np.exp(-((np.abs(yy - S * 0.75) - 14) / 1.2) ** 2)
    hgt = hgt * (1 - tape * 0.85) + tape * 0.9 + tape_e * 0.3
    gold = np.array([0.95, 0.70, 0.30])
    tapec = np.array([0.80, 0.55, 0.22])
    shade = 0.7 + 0.35 * n2 + 0.15 * n3
    alb = gold * shade[..., None]
    alb = alb * (1 - tape[..., None]) + tapec * (0.9 + 0.1 * n3[..., None]) * tape[..., None]
    rough = np.clip(0.18 + 0.3 * (1 - np.abs(n1 - 0.5) * 2) ** 2, 0, 1)
    rough = np.where(tape > 0, 0.35, rough)
    ao = np.clip(0.8 + 0.2 * n2, 0, 1)
    save_rgb(alb, "foil_albedo.png")
    save_rgb(normal_from_height(hgt, 3.0), "foil_normal.png")
    save_orm(ao, rough, np.ones_like(rough), "foil_orm.png")


# ── solar cells ─────────────────────────────────────────────────────────────

def gen_solar(S=512, seed=17):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    C = S // 4
    lx, ly = xx % C, yy % C
    gap = (lx < 3) | (ly < 3)
    # Monocrystalline cells: chamfered corners show the white backsheet.
    cx, cy = np.minimum(lx - 3, C - 1 - lx), np.minimum(ly - 3, C - 1 - ly)
    corner = (cx + cy) < 14
    back = gap | corner
    flake = spectral(S, S, rng, beta=0.3, lo=100)
    cell = np.stack([0.035 + 0.02 * flake, 0.055 + 0.025 * flake, 0.16 + 0.05 * flake], -1)
    fingers = ((ly % 8) < 1).astype(np.float32) * 0.5
    bus = (np.abs(lx - C * 0.33) < 1.5) | (np.abs(lx - C * 0.66) < 1.5)
    alb = cell * (1 + fingers[..., None] * 0.8)
    alb[bus] = (0.72, 0.72, 0.74)
    alb[back] = (0.86, 0.86, 0.84)
    hgt = np.where(back, -0.6, 0.0) + bus * 0.4 + fingers * 0.1
    rough = np.where(back, 0.6, np.where(bus, 0.3, 0.12)).astype(np.float32)
    metal = np.where(bus, 1.0, 0.0).astype(np.float32)
    ao = np.where(back, 0.8, 1.0).astype(np.float32)
    save_rgb(alb, "solar_albedo.png")
    save_rgb(normal_from_height(hgt, 1.2), "solar_normal.png")
    save_orm(ao, rough, metal, "solar_orm.png", 256)


# ── tread: diamond tread plate ──────────────────────────────────────────────

def gen_tread(S=512, seed=18):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    hgt = np.zeros((S, S), np.float32)
    # Lozenges 32 px (3 cm) long on a staggered 32 px grid, alternating ±45°.
    P = 32.0
    cx = (xx % P) - P / 2
    cy = (yy % P) - P / 2
    cell = (np.floor(xx / P) + np.floor(yy / P)) % 2
    a = np.where(cell > 0, 1.0, -1.0) * (math.pi / 4)
    u = cx * np.cos(a) + cy * np.sin(a)
    v = -cx * np.sin(a) + cy * np.cos(a)
    d = (u / 11.0) ** 2 + (v / 2.6) ** 2
    lug = np.clip(1.0 - d, 0, 1) ** 0.35
    hgt += lug * 1.6
    brush = spectral(S, S, rng, beta=1.0, sx=20.0, sy=1.0, lo=4)
    hgt += (brush - 0.5) * 0.15
    seam = np.minimum(dist_to_lines(yy, [0], S), dist_to_lines(xx, [0], S))
    hgt -= np.exp(-(seam / 1.4) ** 2) * 1.2
    wear = smoothstep(0.55, 0.85, spectral(S, S, rng, beta=1.6, lo=2))
    mott = spectral(S, S, rng, beta=2.0, lo=2)
    alb = np.ones((S, S, 3), np.float32) * np.array([0.62, 0.63, 0.64])
    alb *= (0.84 + 0.12 * brush + 0.1 * mott)[..., None]
    # the raised tops are polished by boots; the floor between holds grime
    alb *= (0.82 + 0.26 * lug)[..., None]
    alb *= (1 - 0.18 * wear * (1 - lug))[..., None]
    alb *= (1 - 0.4 * np.exp(-(seam / 2.0) ** 2))[..., None]
    ao = np.clip(0.72 + 0.28 * lug - 0.5 * np.exp(-(seam / 2.0) ** 2), 0, 1)
    rough = np.clip(0.5 - 0.22 * lug + 0.25 * wear * (1 - lug), 0, 1)
    metal = np.ones_like(rough)
    save_rgb(alb, "tread_albedo.png")
    save_rgb(normal_from_height(hgt, 1.6), "tread_normal.png")
    save_orm(ao, rough, metal, "tread_orm.png")


# ── rubber: tyre tread ──────────────────────────────────────────────────────

def gen_rubber(S=512, seed=19):
    """u = across the tread (one tile = the tyre width), v = along it."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    hgt = np.ones((S, S), np.float32)
    # Chevron lugs: a V across the tread, 64 px pitch along it, with grooves.
    x = (xx / S) * 2 - 1
    pitch = 64.0
    phase = (yy + np.abs(x) * 70.0) % pitch
    groove = (phase < 14).astype(np.float32)
    centre = (np.abs(x) < 0.06).astype(np.float32)
    hgt -= np.maximum(groove, centre) * 1.0
    sipe = ((phase > 34) & (phase < 37)).astype(np.float32) * (np.abs(x) > 0.15)
    hgt -= sipe * 0.4
    shoulder = smoothstep(0.82, 1.0, np.abs(x))
    hgt -= shoulder * 0.5
    grain = spectral(S, S, rng, beta=1.4, lo=4)
    hgt += (grain - 0.5) * 0.08
    dust = smoothstep(0.35, 0.8, spectral(S, S, rng, beta=1.8, lo=2))
    low = 1 - np.clip(hgt, 0, 1)
    alb = np.ones((S, S, 3), np.float32) * np.array([0.075, 0.075, 0.08])
    alb *= (0.85 + 0.3 * grain)[..., None]
    alb = alb * (1 - 0.6 * low[..., None] * dust[..., None]) + \
        np.array([0.36, 0.31, 0.26]) * (0.6 * low * dust)[..., None]
    ao = np.clip(1 - 0.55 * low, 0, 1)
    rough = np.clip(0.82 + 0.1 * grain - 0.1 * (1 - low), 0, 1)
    metal = np.zeros_like(rough)
    save_rgb(alb, "rubber_albedo.png")
    save_rgb(normal_from_height(hgt, 2.4), "rubber_normal.png")
    save_orm(ao, rough, metal, "rubber_orm.png")


# ── markings: decal atlas (RGBA, not tiled) ─────────────────────────────────
#
# Each entry is (name, x, y, w, h) in pixels of a 1024² atlas. The mesh
# generator reads the same table (MARKINGS) to UV its decal patches, so the two
# can never disagree. Text is drawn WHITE: a "Stencil" material multiplies it
# to black on white skin; the colour items (flag, hazard) use a white material.

MARKINGS = [
    ("solar",      0,    0, 512, 128),
    ("flag",     512,    0, 256, 160),
    ("hazard",   768,    0, 256,  64),
    ("hazard2",  768,   64, 256,  64),
    ("pod",        0,  128, 512,  96),
    ("fts",        0,  224, 512,  96),
    ("ftm",        0,  320, 512,  96),
    ("sputter",    0,  416, 512,  96),
    ("anvil",      0,  512, 512,  96),
    ("skipper",    0,  608, 512,  96),
    ("cargo",      0,  704, 512,  96),
    ("battery",    0,  800, 512,  96),
    ("nostep",   512,  160, 512,  64),
    ("pyro",     512,  224, 512,  64),
    ("rescue",   512,  288, 512,  64),
    ("serial1",  512,  352, 256,  48),
    ("serial2",  768,  352, 256,  48),
    ("rcs",      512,  400, 256,  64),
    ("lox",      768,  400, 256,  64),
    ("rp1",      512,  464, 256,  64),
    ("dock",     768,  464, 256,  64),
    ("hatch",    512,  528, 256, 256),
    ("arrow",    768,  528, 256, 128),
    ("roll",     768,  656, 256, 128),
    ("dish",       0,  896, 512,  96),
    ("radial",   512,  784, 512,  96),
    ("deco",     512,  880, 512,  64),
    ("comms",    512,  944, 512,  64),
]


def gen_markings(S=1024):
    img = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    d = ImageDraw.Draw(img)
    fb = lambda s: ImageFont.truetype(FONT_BLACK, s)
    fm = lambda s: ImageFont.truetype(FONT_MONO, s)
    W = (255, 255, 255, 255)
    R = {n: (x, y, w, h) for (n, x, y, w, h) in MARKINGS}

    def text(name, s, font, size, pad=8, spacing=0):
        x, y, w, h = R[name]
        f = font(size)
        # shrink to fit
        while True:
            bb = d.textbbox((0, 0), s, font=f)
            if bb[2] - bb[0] <= w - 2 * pad and bb[3] - bb[1] <= h - 2 * pad:
                break
            size -= 2
            f = font(size)
        bb = d.textbbox((0, 0), s, font=f)
        tx = x + (w - (bb[2] - bb[0])) / 2 - bb[0]
        ty = y + (h - (bb[3] - bb[1])) / 2 - bb[1]
        d.text((tx, ty), s, font=f, fill=W)

    # Wordmark: a ring "orbit" glyph + SOLAR.
    x, y, w, h = R["solar"]
    d.ellipse((x + 18, y + 22, x + 102, y + 106), outline=W, width=9)
    d.ellipse((x + 50, y + 54, x + 70, y + 74), fill=W)
    d.arc((x + 4, y + 44, x + 116, y + 84), 200, 340, fill=W, width=6)
    f = fb(84)
    d.text((x + 126, y + 6), "SOLAR", font=f, fill=W)
    # Flag of the (fictional) Solar colony: navy field, an amber star with a
    # ring, a white band. Coloured, so it rides the white "Decal" material.
    x, y, w, h = R["flag"]
    d.rectangle((x + 4, y + 4, x + w - 4, y + h - 4), fill=(24, 38, 92, 255))
    d.rectangle((x + 4, y + h - 46, x + w - 4, y + h - 30), fill=(235, 235, 235, 255))
    d.rectangle((x + 4, y + h - 30, x + w - 4, y + h - 4), fill=(214, 92, 30, 255))
    cx, cy = x + 92, y + 58
    d.ellipse((cx - 26, cy - 26, cx + 26, cy + 26), fill=(255, 176, 40, 255))
    d.ellipse((cx - 44, cy - 14, cx + 44, cy + 14), outline=(255, 226, 150, 255), width=5)
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        sx, sy = x + 190 + 22 * math.cos(a), y + 50 + 22 * math.sin(a)
        d.ellipse((sx - 5, sy - 5, sx + 5, sy + 5), fill=(255, 255, 255, 255))
    d.rectangle((x + 4, y + 4, x + w - 4, y + h - 4), outline=(10, 10, 10, 255), width=3)
    # Hazard stripes (yellow/black) and a red/white variant.
    for name, c1, c2 in (("hazard", (250, 196, 20, 255), (16, 16, 16, 255)),
                         ("hazard2", (200, 30, 30, 255), (240, 240, 240, 255))):
        x, y, w, h = R[name]
        d.rectangle((x, y + 4, x + w, y + h - 4), fill=c1)
        for k in range(-4, 20):
            x0 = x + k * 32
            d.polygon([(x0, y + h - 4), (x0 + 16, y + h - 4), (x0 + 16 + h - 8, y + 4), (x0 + h - 8, y + 4)], fill=c2)
        d.rectangle((x - 40, y, x - 1, y + h), fill=(255, 255, 255, 0))
    # clip spill to the left of the hazard cells
    img.paste((255, 255, 255, 0), (512, 0, 768, 0))
    text("pod", "POD MK1", fb, 80)
    text("fts", "FT-S  PROPELLANT", fb, 64)
    text("ftm", "FT-M  PROPELLANT", fb, 64)
    text("sputter", "SPUTTER", fb, 80)
    text("anvil", "ANVIL", fb, 80)
    text("skipper", "SKIPPER", fb, 80)
    text("cargo", "CARGO BAY", fb, 80)
    text("battery", "BATTERY  28V", fb, 72)
    text("nostep", "NO STEP", fb, 52)
    text("pyro", "DANGER  PYROTECHNIC", fb, 48)
    text("rescue", "RESCUE  HATCH", fb, 46)
    text("serial1", "SN-0427", fm, 40)
    text("serial2", "LOT 11-B", fm, 40)
    text("rcs", "RCS", fb, 52)
    text("lox", "LOX", fb, 52)
    text("rp1", "RP-1", fb, 52)
    text("dock", "DOCK", fb, 52)
    text("dish", "S-BAND", fb, 72)
    text("radial", "RADIAL TANK", fb, 64)
    text("deco", "SEPARATION PLANE", fb, 44)
    text("comms", "COMMS", fb, 50)
    # Hatch outline with handle, and a direction arrow, and a roll-pattern
    # quadrant block (the black/white squares launch cameras track).
    x, y, w, h = R["hatch"]
    d.rounded_rectangle((x + 12, y + 12, x + w - 12, y + h - 12), radius=40, outline=W, width=8)
    d.rounded_rectangle((x + 30, y + 30, x + w - 30, y + h - 30), radius=26, outline=W, width=3)
    d.rectangle((x + w / 2 - 50, y + h / 2 - 10, x + w / 2 + 50, y + h / 2 + 10), fill=W)
    x, y, w, h = R["arrow"]
    d.polygon([(x + 10, y + 50), (x + 170, y + 50), (x + 170, y + 20), (x + 246, y + 64), (x + 170, y + 108), (x + 170, y + 78), (x + 10, y + 78)], fill=W)
    x, y, w, h = R["roll"]
    d.rectangle((x + 4, y + 4, x + w / 2, y + h / 2), fill=W)
    d.rectangle((x + w / 2, y + h / 2, x + w - 4, y + h - 4), fill=W)
    # Weather the whole atlas a touch: decals are paint too.
    a = np.asarray(img).astype(np.float32)
    rng = np.random.default_rng(21)
    wear = spectral(S, S, rng, beta=0.9, lo=30)
    a[..., 3] *= np.clip(0.75 + 0.5 * wear, 0, 1)
    a[..., 3] *= (wear > 0.12)
    Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, "markings.png"), optimize=True)


# ── interior atlas ──────────────────────────────────────────────────────────
#
# Quadrants (u right, v down, 1024²):
#   TL  wall padding (quilted beta-cloth, velcro, stowage straps)
#   TR  console fascia (switch rows, guards, labels, bezels)
#   BL  top half: seat cushion fabric; bottom half: suit fabric
#   BR  displays (drawn UNLIT so they glow): attitude ball, telemetry, alarms
INTERIOR = {
    "wall":    (0, 0, 512, 512),
    "console": (512, 0, 512, 512),
    "seat":    (0, 512, 512, 256),
    "suit":    (0, 768, 512, 256),
    "screens": (512, 512, 512, 512),
}


def gen_interior(S=1024, seed=31):
    rng = np.random.default_rng(seed)
    alb = np.zeros((S, S, 3), np.float32)
    hgt = np.zeros((S, S), np.float32)
    rough = np.ones((S, S), np.float32) * 0.85
    yy, xx = np.mgrid[0:512, 0:512].astype(np.float32)
    # Wall: quilted cloth in diamonds, stitches, velcro squares.
    q = 64
    a1 = ((xx + yy) % q) / q
    a2 = ((xx - yy) % q) / q
    quilt = (np.sin(a1 * math.pi) * np.sin(a2 * math.pi)) ** 0.5
    stitch = ((np.abs(a1 * q) < 1.2) | (np.abs(a2 * q) < 1.2)).astype(np.float32)
    weave = spectral(512, 512, rng, beta=0.2, lo=120)
    h = quilt * 1.0 - stitch * 0.4 + (weave - 0.5) * 0.1
    c = np.ones((512, 512, 3)) * np.array([0.80, 0.79, 0.74]) * (0.88 + 0.12 * quilt)[..., None]
    c *= (0.95 + 0.08 * weave)[..., None]
    for (vx, vy) in ((60, 70), (300, 120), (180, 330), (400, 400)):
        c[vy:vy + 50, vx:vx + 70] = (0.16, 0.17, 0.18)
        h[vy:vy + 50, vx:vx + 70] = 0.6 + (weave[vy:vy + 50, vx:vx + 70] - 0.5) * 0.8
    for sx in (0, 256):  # stowage straps
        c[:, sx + 120:sx + 132] = (0.30, 0.34, 0.42)
        h[:, sx + 120:sx + 132] = 1.1
    alb[0:512, 0:512] = c
    hgt[0:512, 0:512] = h
    # Console: dark grey fascia, rows of toggle switches with guards, bezels.
    con = Image.new("RGB", (512, 512), (40, 42, 46))
    hc = Image.new("L", (512, 512), 128)
    dc, dh = ImageDraw.Draw(con), ImageDraw.Draw(hc)
    f = ImageFont.truetype(FONT_BOLD, 13)
    labels = ["MAIN BUS A", "MAIN BUS B", "FUEL CELL", "O2 FLOW", "SEP ARM", "CHUTE ARM", "RCS A", "RCS B", "GIMBAL", "SAS"]
    for row in range(4):
        y0 = 30 + row * 60
        dc.text((20, y0 - 22), labels[row * 2 % len(labels)], font=f, fill=(200, 200, 190))
        for k in range(8):
            x0 = 30 + k * 58
            dc.rectangle((x0 - 14, y0 - 4, x0 + 14, y0 + 30), outline=(90, 92, 96), width=2)
            dh.rectangle((x0 - 14, y0 - 4, x0 + 14, y0 + 30), outline=170, width=2)
            dc.ellipse((x0 - 7, y0 + 6, x0 + 7, y0 + 20), fill=(150, 152, 156))
            dh.ellipse((x0 - 7, y0 + 6, x0 + 7, y0 + 20), fill=230)
            on = (row * 8 + k) % 3 != 0
            dc.rectangle((x0 - 2, y0 - (2 if on else -12), x0 + 2, y0 + 13), fill=(210, 210, 214))
    for k in range(6):  # caution lamps (dark when not lit)
        dc.rectangle((30 + k * 78, 280, 90 + k * 78, 310), fill=(70, 40, 20) if k % 2 else (25, 50, 25), outline=(10, 10, 10))
        dc.text((36 + k * 78, 288), ["ABORT", "MASTER", "CABIN P", "FUEL", "HEAT", "COMM"][k], font=ImageFont.truetype(FONT_BOLD, 11), fill=(140, 140, 120))
    dc.rectangle((20, 330, 492, 492), outline=(120, 122, 126), width=4)  # bezel
    dh.rectangle((20, 330, 492, 492), outline=220, width=4)
    for k in range(16):  # bezel screws
        sx = 30 + k * 30
        dc.ellipse((sx - 3, 336, sx + 3, 342), fill=(160, 160, 160))
    alb[0:512, 512:1024] = np.asarray(con).astype(np.float32) / 255
    hgt[0:512, 512:1024] = (np.asarray(hc).astype(np.float32) - 128) / 64
    rough[0:512, 512:1024] = 0.55
    # Seat cushion (dark blue, tufted) and suit fabric (white, folds).
    yy2, xx2 = np.mgrid[0:256, 0:512].astype(np.float32)
    tuft = (np.sin(xx2 / 512 * 8 * math.pi) * np.sin(yy2 / 256 * 4 * math.pi)) ** 2
    w2 = spectral(256, 512, rng, beta=0.2, lo=100)
    alb[512:768, 0:512] = np.array([0.10, 0.13, 0.22]) * (0.8 + 0.3 * tuft + 0.1 * w2)[..., None]
    hgt[512:768, 0:512] = tuft * 0.8 + (w2 - 0.5) * 0.2
    folds = spectral(256, 512, rng, beta=2.0, sx=0.4, sy=3.0, lo=2)
    alb[768:1024, 0:512] = np.array([0.86, 0.86, 0.82]) * (0.8 + 0.25 * folds + 0.05 * w2)[..., None]
    hgt[768:1024, 0:512] = folds * 1.5
    # Glove strip and suit cuff colours on the suit band's lower edge.
    alb[960:1024, 0:512] = np.array([0.80, 0.80, 0.78]) * (0.85 + 0.15 * folds[192:256])[..., None]
    alb[940:960, 0:512] = (0.70, 0.36, 0.12)  # orange cuff ring
    # Screens: drawn bright, the material is unlit so they glow.
    scr = Image.new("RGB", (512, 512), (4, 6, 8))
    ds = ImageDraw.Draw(scr)
    # Attitude display (left half): sky/ground ball with a pitch ladder.
    ds.rectangle((8, 8, 250, 250), fill=(6, 10, 14), outline=(60, 70, 80), width=3)
    ds.pieslice((24, 24, 234, 234), 180, 360, fill=(40, 110, 190))
    ds.pieslice((24, 24, 234, 234), 0, 180, fill=(140, 90, 40))
    for k in range(-3, 4):
        yk = 129 + k * 20
        ww = 40 if k % 2 == 0 else 22
        ds.line((129 - ww, yk, 129 + ww, yk), fill=(240, 240, 240), width=2)
    ds.line((60, 129, 110, 129), fill=(255, 210, 40), width=5)
    ds.line((148, 129, 198, 129), fill=(255, 210, 40), width=5)
    ds.ellipse((124, 124, 134, 134), fill=(255, 210, 40))
    # Telemetry (right half): green text + bar graphs.
    fm = ImageFont.truetype(FONT_MONO, 15)
    ds.rectangle((262, 8, 504, 250), fill=(4, 12, 6), outline=(60, 70, 80), width=3)
    lines = ["ALT   001.284 KM", "VEL   0094.6 M/S", "AP    003.910 KM", "PROP  062 %", "TWR   1.84", "Q     12.4 KPA", "STG   1 / 3", "SAS   STAB"]
    for i, s in enumerate(lines):
        ds.text((274, 18 + i * 22), s, font=fm, fill=(80, 255, 120))
    for i in range(6):
        hbar = [60, 90, 40, 110, 70, 30][i]
        ds.rectangle((280 + i * 36, 240 - hbar, 300 + i * 36, 240), fill=(60, 200, 255))
    # Lower: a map strip and annunciators.
    ds.rectangle((8, 262, 504, 400), fill=(4, 8, 12), outline=(60, 70, 80), width=3)
    for k in range(0, 496, 24):
        ds.line((8 + k, 262, 8 + k, 400), fill=(16, 36, 44))
    pts = [(8 + i * 8, 330 - 50 * math.sin(i / 62 * math.pi * 2)) for i in range(63)]
    ds.line(pts, fill=(255, 200, 60), width=3)
    ann = [("MASTER ALARM", (220, 40, 30)), ("CHUTE ARM", (240, 170, 30)), ("SEP READY", (60, 220, 90)), ("GUIDANCE", (60, 180, 255))]
    for i, (s, colr) in enumerate(ann):
        x0 = 12 + i * 124
        ds.rectangle((x0, 412, x0 + 116, 500), fill=tuple(int(c * 0.35) for c in colr), outline=colr, width=3)
        ds.text((x0 + 8, 444), s, font=ImageFont.truetype(FONT_BOLD, 15), fill=colr)
    alb[512:1024, 512:1024] = np.asarray(scr).astype(np.float32) / 255
    rough[512:1024, 512:1024] = 0.1
    save_rgb(alb, "interior_albedo.png")
    save_rgb(normal_from_height(hgt, 1.5), "interior_normal.png", 512)
    save_orm(np.ones_like(rough), rough, np.zeros_like(rough), "interior_orm.png", 256)


def main():
    os.makedirs(OUT, exist_ok=True)
    only = set(sys.argv[1:])
    for name, fn in (("paint", gen_paint), ("metal", gen_metal), ("tiles", gen_tiles),
                     ("ablative", gen_ablative), ("bell", gen_bell), ("foil", gen_foil),
                     ("solar", gen_solar), ("tread", gen_tread), ("rubber", gen_rubber),
                     ("markings", gen_markings), ("interior", gen_interior)):
        if only and name not in only:
            continue
        fn()
        print("wrote", name)


if __name__ == "__main__":
    main()
