#!/usr/bin/env python3
"""The SPACEPORT's surfaces from the realistic PBR library (wave 2 of the texture upgrade).

    python3 tools/base_pbr.py            # bake what changed (tools/base_tex.py runs it too)
    python3 tools/base_pbr.py --force    # bake everything again
    python3 tools/base_pbr.py --sheet DIR  # contact sheets (CC0 and local) into DIR, outside the repo

Writes textures/base/<surface>_{albedo,normal,orm}.png for the four surfaces the base's
models, paving and the VAB interior share (tools/gen_base.py MATERIALS, scripts/base_facilities.lua
MATS, tools/gen_vab.py). The signs atlas and the lamp lens stay procedural (tools/base_tex.py).

THE SAME TILES AS BEFORE. Every texture still covers the area the meshes' UVs give it (base_models.py
UVM, base_facilities.lua ASPHALT_TILE / CONCRETE_TILE): concrete 4 m, asphalt 4 m, cladding 2 m,
steel 1 m. The photographic sets are resampled to their real size inside that tile, so no model,
prefab or script changes, and the VAB and hangar pick the new surfaces up as they are.

NO VISIBLE REPEAT INSIDE A TILE. A set that is smaller than the tile (a 2 m concrete photo in a 4 m
slab) is not laid 2 x 2: the tile is assembled from patches of the set at random offsets (and quarter
turns, for the surfaces that have no direction), joined along soft seams of a jittered Voronoi with a
variance-preserving blend (the seam keeps the grain's contrast instead of greying). The broad
light-and-dark blotches are flattened, since those are what read as a repeat across a 60 m apron.

PAINT COMES FROM THE MESH. The models multiply a paint colour in as a vertex colour (base_models.py,
base_facilities.lua COL), so each albedo is kept near neutral and its mean (in linear light) is
matched to the procedural texture it replaces: the white VAB stays white, the asphalt as dark.

LICENSING (the repo is public). CC0 sets (ambientCG) bake into textures/base (committed). A surface
whose best source is a commercial set bakes twice: a CC0 fallback into textures/base, and the
commercial version into textures/env_local/base (git-ignored), which
`tools/import_textures.py --stage` copies over textures/base in a local build. A clean checkout has
every file the game loads.

  surface   tile  px (albedo, normal / orm)  CC0 (committed)                   local build
  concrete  4 m   1024 / 512                 Road010A grain inverted to pores,  Dirty_Concrete (2 m)
                                             Metal052C mottling (no CC0
                                             concrete in the library)
  asphalt   4 m   1024 / 512                 Road010A + Road009A (6 m), the     (same)
                                             painted lines cut out
  cladding  2 m   1024 / 512                 Metal053B painted steel, rust      (same)
                                             runs, on the trapezoidal rib
  steel     1 m   512 / 512                  Metal052C painted plate, chips,    (same)
                                             scratches to bare metal
Saw-cut joints are cut into the concrete on the tile edge (the slab), as before.

Idempotent: textures/base/.pbr stamp (recipe hash + the sources' size and time). numpy + Pillow.
"""
import argparse
import hashlib
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_textures as IT  # noqa: E402
from gen_part_textures import smoothstep, spectral  # noqa: E402

ROOT = IT.ROOT
OUT = os.path.join(ROOT, "textures", "base")
OUT_LOCAL = os.path.join(ROOT, IT.OUT_LOCAL, "base")
STAMP = os.path.join(OUT, ".pbr")
WORK = 2048          # the size each set is loaded at

# the manifest's `use` for the sets baked here (tools/import_textures.py write_manifest)
USES = {
    "Road010A": ["wave 2: base asphalt (textures/base/asphalt); the CC0 concrete's grain"],
    "Road009A": ["wave 2: base asphalt (textures/base/asphalt)"],
    "Metal052C": ["wave 2: base steel (textures/base/steel); the CC0 concrete's mottling"],
    "Metal053B": ["wave 2: base cladding (textures/base/cladding)"],
    "Dirty_Concrete": ["wave 2: base concrete (textures/base/concrete), local builds"],
}

# the old procedural means (linear), kept so the meshes' paint colours read as before
MEAN = {"concrete": (0.300, 0.290, 0.271), "asphalt": (0.265, 0.265, 0.271),
        "cladding": (0.636, 0.625, 0.611), "steel": (0.598, 0.594, 0.578)}

_SETS = {}
_CACHE = {}


def sets():
    if not _SETS:
        _SETS.update(IT.scan(IT.LIB_PATH[0]))
    return _SETS


def load(sid):
    """albedo (linear RGB), normal xy (-1..1, GL), ao, rough, metal, height at WORK px."""
    if sid not in _CACHE:
        c = IT.convert_set(IT.LIB_PATH[0], sets()[sid], WORK)
        n = c["normal"] * 2 - 1 if c["normal"] is not None else np.zeros((WORK, WORK, 3), np.float32) + (0, 0, 1)
        h = c["height"] if c["height"] is not None else np.full((WORK, WORK), 0.5, np.float32)
        _CACHE[sid] = dict(alb=IT.srgb_to_lin(c["albedo"]).astype(np.float32), nxy=n[..., :2].astype(np.float32),
                           ao=c["orm"][..., 0].astype(np.float32), rough=c["orm"][..., 1].astype(np.float32),
                           metal=c["orm"][..., 2].astype(np.float32), h=h.astype(np.float32))
    return _CACHE[sid]


# ── periodic helpers ─────────────────────────────────────────────────────────


def fft_resize(a, size):
    """Resize a periodic map to size x size in Fourier space: the result tiles exactly. The top
    sixth of the kept band is tapered (a raised cosine) so sharp edges don't ring."""
    if a.ndim == 3:
        return np.stack([fft_resize(a[..., i], size) for i in range(a.shape[2])], axis=2)
    n = a.shape[0]
    if n == size:
        return a.copy()
    F = np.fft.fftshift(np.fft.fft2(a))
    out = np.zeros((size, size), complex)
    m = min(n, size)
    s0, d0 = (n - m) // 2, (size - m) // 2
    out[d0:d0 + m, d0:d0 + m] = F[s0:s0 + m, s0:s0 + m]
    f = np.fft.fftshift(np.fft.fftfreq(size)) * size / (m / 2)     # 1 at the kept band's edge
    r = np.sqrt(f[:, None] ** 2 + f[None, :] ** 2)
    taper = np.where(r < 0.83, 1.0, np.where(r < 1.0, 0.5 + 0.5 * np.cos(np.pi * (r - 0.83) / 0.17), 0.0))
    out *= taper
    return np.real(np.fft.ifft2(np.fft.ifftshift(out))) * (size * size) / (n * n)


def rot_maps(m, k, flip=False):
    """Quarter-turn a set's maps k times (counter-clockwise), the normal's xy turned with them."""
    o = {}
    for key, a in m.items():
        b = a[:, ::-1] if flip else a
        o[key] = np.rot90(b, k, axes=(0, 1)).copy()
    nx, ny = o["nxy"][..., 0], o["nxy"][..., 1]
    if flip:
        nx = -nx
    for _ in range(k % 4):
        nx, ny = -ny, nx
    o["nxy"] = np.stack([nx, ny], axis=2)
    return o


def bomb(m, N, rng, cells=3, seam=0.06, turns=True, flips=True):
    """An N x N periodic tile assembled from patches of the periodic maps `m` (all the same size,
    already at the output's pixel size). cells x cells jittered Voronoi sites on the torus; each takes
    the source at a random offset (and turn / mirror); seams `seam` x N wide; variance-preserving."""
    S = m["alb"].shape[0]
    K = cells * cells
    g = (np.arange(cells) + 0.5) / cells
    sy, sx = np.meshgrid(g, g, indexing="ij")
    sites = np.stack([sy.ravel(), sx.ravel()], 1) + rng.uniform(-0.3, 0.3, (K, 2)) / cells
    sites = (sites % 1.0) * N
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    D, DY, DX = [], [], []
    for (cy, cx) in sites:
        dy = (yy - cy + N / 2) % N - N / 2
        dx = (xx - cx + N / 2) % N - N / 2
        DY.append(dy)
        DX.append(dx)
        D.append(np.sqrt(dy * dy + dx * dx))
    D = np.stack(D)
    # a little noise in the distances so the seams wander instead of running straight
    wob = np.stack([IT.blur_wrap(rng.standard_normal((N, N)), N / 40) for _ in range(K)])
    wob /= wob.std() + 1e-9
    D = D + wob * N * 0.025
    W = np.exp(-(D - D.min(0)) / (seam * N))
    W /= W.sum(0)
    norm = 1.0 / np.sqrt((W * W).sum(0))
    keys = list(m.keys())
    mean = {k: m[k].mean(axis=(0, 1)) for k in keys}
    acc = {k: np.zeros((N, N) + m[k].shape[2:], np.float32) for k in keys}
    for i in range(K):
        mi = rot_maps(m, int(rng.integers(0, 4)) if turns else 0, bool(rng.integers(0, 2)) if flips else False)
        oy, ox = rng.integers(0, S, 2)
        iy = ((DY[i] + oy).astype(np.int64)) % S
        ix = ((DX[i] + ox).astype(np.int64)) % S
        w = W[i]
        for k in keys:
            v = mi[k][iy, ix] - mean[k]
            acc[k] += (w[..., None] if v.ndim == 3 else w) * v
    return {k: acc[k] * (norm[..., None] if acc[k].ndim == 3 else norm) + mean[k] for k in keys}


def at_scale(m, src_m, tile_m, N):
    """The set resampled so its src_m metres span the right share of an N px, tile_m metre tile."""
    size = int(round(N * src_m / tile_m))
    return {k: fft_resize(a, size).astype(np.float32) for k, a in m.items()}


def lum(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


def flatten(c, frac, amount):
    """Take `amount` of the broad blotches (wrap blur at frac x the tile) out of a linear albedo."""
    L = np.maximum(lum(c), 1e-4)
    Lb = np.maximum(IT.blur_wrap(L, c.shape[0] * frac), 1e-4)
    return c * ((L.mean() / Lb) ** amount)[..., None]


def grade(c, mean, sat):
    """Saturation about luminance, then each channel scaled to the old texture's mean."""
    L = lum(c)[..., None]
    c = L + (c - L) * sat
    c = c * (np.array(mean) / np.maximum(c.reshape(-1, 3).mean(0), 1e-4))
    return np.clip(c, 0, 1)


def nrm_rgb(nxy, strength=1.0):
    """xy (-1..1) → an OpenGL normal map image (0..1)."""
    x, y = nxy[..., 0] * strength, nxy[..., 1] * strength
    z = np.sqrt(np.clip(1 - x * x - y * y, 0.02, 1))
    n = np.stack([x, y, z], 2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n * 0.5 + 0.5


def height_nxy(h, strength):
    """A height field's slopes as normal xy (OpenGL: rows run down, green up)."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    n = np.stack([-dx * strength, dy * strength, np.ones_like(h)], 2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n[..., :2]


def down(a, size):
    return a if a.shape[0] == size else fft_resize(a, size)


def save_set(root, name, alb_lin, nxy, ao, rough, metal, n_px, orm_px):
    os.makedirs(root, exist_ok=True)
    alb = IT.lin_to_srgb(down(np.clip(alb_lin, 0, 1), n_px))
    IT.save_png(alb, os.path.join(root, name + "_albedo.png"), "RGB")
    IT.save_png(nrm_rgb(down(nxy, n_px)), os.path.join(root, name + "_normal.png"), "RGB")
    orm = np.stack([down(ao, orm_px), down(rough, orm_px), down(metal, orm_px)], 2)
    IT.save_png(np.clip(orm, 0, 1), os.path.join(root, name + "_orm.png"), "RGB")
    print("  %-8s %s (albedo/normal %d, orm %d)" % (name, os.path.relpath(root, ROOT), n_px, orm_px))


# ── the surfaces ─────────────────────────────────────────────────────────────


def slab_joints(N, rng):
    """The saw-cut joint round the slab (the tile edge): groove, spalled edge, dirt either side."""
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    dj = np.minimum(np.minimum(xx + 0.5, N - 0.5 - xx), np.minimum(yy + 0.5, N - 0.5 - yy))
    groove = 1 - smoothstep(0.7, 2.0, dj)
    spall = (spectral(N, N, rng, beta=1.0, lo=40) > 0.74) * (1 - smoothstep(1.5, 5.0, dj))
    dirt = (1 - smoothstep(2.0, 14.0, dj)) * (0.6 + 0.4 * spectral(N, N, rng, beta=1.4, lo=12))
    return groove, spall, dirt


def concrete(local):
    N = 1024
    rng = np.random.default_rng(2101)
    if local:
        m = at_scale(load("Dirty_Concrete"), 2.0, 4.0, N)
        t = bomb(m, N, rng, cells=4, seam=0.05)
        alb, nxy, ao, rough = t["alb"], t["nxy"], t["ao"], t["rough"]
        alb = flatten(alb, 1 / 8, 0.9)
        # broom-finished outdoor slab: matte (the set's roughness map read glossy under a clear sky)
        rough = np.clip(0.80 + (rough - rough.mean()) * 0.6, 0.65, 1)
        sat = 0.6
    else:
        # No CC0 concrete in the library: asphalt's grain turned inside out (its stone chips
        # become a broom-finished slab's pores and sand), on the mottling of a weathered grey paint.
        r = at_scale(cut_lines(dict(load("Road010A"))), 6.0 * 0.45, 4.0, N)   # grain at concrete fineness
        t = bomb(r, N, rng, cells=4, seam=0.05)
        g = lum(t["alb"])
        g = g - IT.blur_wrap(g, 6)
        g = -g / (g.std() + 1e-6)
        p = at_scale(load("Metal052C"), 1.4, 4.0, N)
        tp = bomb(p, N, rng, cells=4, seam=0.08)
        mot = lum(tp["alb"])
        mot = mot / mot.mean()
        mot = mot ** 2.2
        mot = mot / mot.mean()
        base = 0.30 * (0.62 + 0.38 * mot) * (1 + 0.28 * np.clip(g, -2.5, 2.5))
        warm = spectral(N, N, rng, beta=2.0, lo=2)
        alb = np.stack([base * (1.02 + 0.03 * warm), base, base * (0.95 - 0.03 * warm)], 2)
        nxy = -t["nxy"] * 1.0
        ao = np.clip(1 - np.clip(-g, 0, None) * 0.08, 0.6, 1)
        rough = np.clip(0.86 + 0.04 * g - 0.08 * (1 - tp["rough"]), 0.6, 1)
        sat = 1.0
    groove, spall, dirt = slab_joints(N, rng)
    alb = alb * (1 - groove * 0.55 - spall * 0.10 - dirt * 0.10)[..., None]
    jh = -groove * 2.5 - spall * 0.6
    nxy = nxy + height_nxy(jh, 1.0)
    ao = ao * (1 - groove * 0.5 - spall * 0.15)
    rough = np.clip(rough + dirt * 0.04, 0, 1)
    alb = grade(alb, MEAN["concrete"], sat)
    return alb, nxy, ao, rough, np.zeros_like(ao)


def asphalt():
    N = 1024
    rng = np.random.default_rng(2202)
    ms = []
    for sid in ("Road010A", "Road009A"):
        m = dict(load(sid))
        m = cut_lines(m)
        ms.append(at_scale(m, 6.0, 4.0, N))
    # cells alternate between the two roads: half the patches from each
    t0 = bomb(ms[0], N, rng, cells=3, seam=0.07, turns=False)
    t1 = bomb(ms[1], N, rng, cells=3, seam=0.07, turns=False)
    mix = smoothstep(0.35, 0.65, spectral(N, N, rng, beta=2.2, lo=2))
    t = {k: t0[k] * (1 - (mix[..., None] if t0[k].ndim == 3 else mix)) +
         t1[k] * (mix[..., None] if t1[k].ndim == 3 else mix) for k in t0}
    alb = flatten(t["alb"], 1 / 4, 0.8)
    # grit: the stone chips' contrast up (the photo's grain, 1.6x above ~2 cm)
    L = np.maximum(lum(alb), 1e-4)
    Lb = np.maximum(IT.blur_wrap(L, 5), 1e-4)
    alb = alb * ((L / Lb) ** 0.6)[..., None]
    alb = grade(alb, MEAN["asphalt"], 0.35)
    rough = np.clip(0.80 + (t["rough"] - t["rough"].mean()) * 1.0 + 0.08, 0.55, 1)
    return alb, t["nxy"] * 1.5, t["ao"], rough, np.zeros_like(t["ao"])


def cut_lines(m):
    """A road set with its painted lines (yellow, vertical) replaced by asphalt from beside them."""
    a = m["alb"]
    S = a.shape[0]
    yellow = (a[..., 0] + a[..., 1]) * 0.5 - a[..., 2]
    col = (yellow > 0.03).mean(axis=0)
    bad = col > 0.02
    bad = np.convolve(bad.astype(float), np.ones(25), "same") > 0   # widen: the line's soft edge
    xs = np.nonzero(bad)[0]
    if len(xs) == 0:
        return m
    # each bad column takes the column a fixed shift away, feathered at the run's ends
    w = np.convolve(bad.astype(float), np.hanning(17) / np.hanning(17).sum(), "same").clip(0, 1)
    shift = S // 5
    src = (np.arange(S) + shift) % S
    while bad[src[xs]].any():
        shift += 7
        src = (np.arange(S) + shift) % S
    out = {}
    for k, v in m.items():
        sv = v[:, src]
        ww = w[None, :, None] if v.ndim == 3 else w[None, :]
        out[k] = v * (1 - ww) + sv * ww
    return out


def cladding():
    N = 1024
    rng = np.random.default_rng(2303)
    m = load("Metal053B")
    # its rust runs trail up the image: turned the right way up, drips hang from the rust
    m = {k: v[::-1].copy() for k, v in m.items()}
    m["nxy"][..., 1] *= -1
    m = at_scale(m, 2.0, 2.0, N)
    rust = np.clip((1 - m["metal"]) * 4.0, 0, 1)
    rust = np.clip(IT.blur_wrap(rust, 2.0) * 2.0, 0, 1)     # the whole footprint, soft edges included
    # keep the rust in a few weather-beaten places, faint elsewhere
    # faint everywhere: any distinct rust patch repeats every 2 m up a 72 m wall (wallpaper)
    keep = 0.05 + 0.0 * spectral(N, N, rng, beta=2.0, lo=2)
    rust_k = rust * keep
    paint = m["alb"].copy()
    Lp = lum(paint)[..., None]
    paint_n = Lp + (paint - Lp) * 0.15                 # the paint goes neutral; the mesh paints it
    # under the rust there is paint too: the rust's footprint is filled with the paint around it (a wide
    # wrap blur of the paint alone), so the faint rust left on top is a tint, not a dark grey blotch
    clean = 1 - rust
    under = IT.blur_wrap(paint_n * clean[..., None], N / 32) / np.maximum(IT.blur_wrap(clean, N / 32), 1e-3)[..., None]
    paint_n = paint_n * clean[..., None] + under * rust[..., None]
    alb = paint_n * (1 - rust_k[..., None]) + m["alb"] * rust_k[..., None]
    alb = flatten(alb, 1 / 8, 0.9)
    # the trapezoidal rib (8 across the 2 m tile), as the procedural sheet had it
    x = (np.arange(N) / N) * 8.0
    ph = x % 1.0
    prof = np.interp(ph, [0.0, 0.10, 0.22, 0.88, 1.0], [1.0, 1.0, 0.0, 0.0, 1.0])
    prof += np.interp(ph, [0.45, 0.50, 0.55], [0.0, 0.10, 0.0])
    hgt = np.tile(prof[None, :], (N, 1)).astype(np.float32)
    dents = spectral(N, N, rng, beta=2.4, lo=3) - 0.5
    rib = hgt + dents * 0.25
    # grime runs down the pans
    streak = smoothstep(0.50, 0.88, spectral(N, N, rng, beta=1.4, sx=1.0, sy=0.04, lo=4))
    alb = alb * (1 - streak * 0.08)[..., None]
    alb = grade(alb, MEAN["cladding"], 1.0)
    nxy = height_nxy(rib, 9.0 * N / 512) + m["nxy"] + height_nxy(m["h"] * rust_k, 6.0)
    ao = (0.82 + 0.18 * np.clip(hgt, 0, 1)) * (1 - rust_k * 0.15)
    rough = np.clip(0.42 + 0.35 * (m["rough"] - m["rough"].min()) / (np.ptp(m["rough"]) + 1e-6) + streak * 0.12
                    + rust_k * 0.35, 0, 1)
    metal = np.clip(0.06 * (1 - rust), 0, 1)
    return alb, nxy, ao, rough, metal


def steel():
    N = 512
    rng = np.random.default_rng(2404)
    m = at_scale(load("Metal052C"), 1.0, 1.0, N)
    alb = m["alb"]
    Lp = lum(alb)[..., None]
    alb = Lp + (alb - Lp) * 0.3
    alb = flatten(alb, 1 / 4, 0.4)
    # scratches through the paint to bare metal
    img = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(img)
    for _ in range(60):
        x, y = rng.uniform(0, N, 2)
        a = rng.uniform(0, math.pi)
        L = rng.uniform(5, 30)
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                d.line([(x + ox, y + oy), (x + ox + math.cos(a) * L, y + oy + math.sin(a) * L)],
                       fill=int(rng.uniform(110, 255)), width=1)
    scratch = np.asarray(img, np.float32) / 255
    chips = np.clip(1 - m["metal"], 0, 1)              # the set's chips and dirt spots
    alb = alb * (1 - scratch[..., None] * 0.15) + scratch[..., None] * 0.25
    alb = grade(alb, MEAN["steel"], 1.0)
    nxy = m["nxy"] + height_nxy(-scratch * 0.5 + m["h"] * 0.3, 2.0)
    rough = np.clip(0.38 + 0.4 * (m["rough"] - m["rough"].min()) / (np.ptp(m["rough"]) + 1e-6) + chips * 0.2
                    - scratch * 0.15, 0.2, 1)
    metal = np.clip(0.05 + scratch * 0.65, 0, 1)
    return alb, nxy, m["ao"] * (1 - chips * 0.1), rough, metal


# ── main ─────────────────────────────────────────────────────────────────────

PLAN = [  # (surface, recipe, local?, albedo/normal px, orm px)
    ("concrete", lambda: concrete(False), False, 1024, 512),
    ("concrete", lambda: concrete(True), True, 1024, 512),
    ("asphalt", asphalt, False, 1024, 512),
    ("cladding", cladding, False, 1024, 512),
    ("steel", steel, False, 512, 512),
]
SOURCES = ["Road010A", "Road009A", "Metal052C", "Metal053B", "Dirty_Concrete"]


def stamp():
    src = open(os.path.abspath(__file__), "rb").read()
    s = sets()
    info = [(sid, s[sid]["size"], s[sid]["mtime"]) for sid in SOURCES if sid in s]
    return hashlib.sha1(src + json.dumps(info).encode() + str(IT.IMPORTER_VERSION).encode()).hexdigest()[:16]


def bake(force=False):
    if not os.path.isdir(IT.LIB_PATH[0]):
        print("base_pbr: no texture library at %s: textures/base left as they are" % IT.LIB_PATH[0])
        return
    st = stamp()
    have_local = os.path.exists(os.path.join(OUT_LOCAL, "concrete_albedo.png"))
    if not force and os.path.exists(STAMP) and open(STAMP).read().strip() == st and have_local:
        print("base_pbr: textures/base up to date")
        return
    for name, fn, local, npx, opx in PLAN:
        if local and sets().get("Dirty_Concrete") is None:
            continue
        alb, nxy, ao, rough, metal = fn()
        save_set(OUT_LOCAL if local else OUT, name, alb, nxy, ao, rough, metal, npx, opx)
    open(STAMP, "w").write(st + "\n")


def sheet(outdir):
    outdir = os.path.abspath(outdir)
    if os.path.realpath(outdir).startswith(os.path.realpath(ROOT) + os.sep):
        raise SystemExit("--sheet: the local sheet holds commercial pixels; write it outside the repo")
    os.makedirs(outdir, exist_ok=True)
    for which, root in (("cc0", OUT), ("local", OUT_LOCAL)):
        rows = []
        for name in ("concrete", "asphalt", "cladding", "steel"):
            p = os.path.join(root, name + "_albedo.png")
            if not os.path.exists(p):
                p = os.path.join(OUT, name + "_albedo.png")
            ims = [Image.open(p.replace("_albedo", s)).convert("RGB").resize((512, 512)) for s in ("_albedo", "_normal", "_orm")]
            two = Image.new("RGB", (512, 512))
            a = Image.open(p).convert("RGB").resize((256, 256))
            for i in range(2):
                for j in range(2):
                    two.paste(a, (i * 256, j * 256))
            rows.append(ims + [two])
        S = Image.new("RGB", (4 * 512, len(rows) * 512))
        for r, row in enumerate(rows):
            for c, im in enumerate(row):
                S.paste(im, (c * 512, r * 512))
        S.save(os.path.join(outdir, "base_%s.png" % which))
        print("sheet", os.path.join(outdir, "base_%s.png" % which))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--lib", default=IT.LIB)
    ap.add_argument("--sheet")
    a = ap.parse_args()
    IT.LIB_PATH[0] = a.lib
    if a.sheet:
        sheet(a.sheet)
        return
    bake(a.force)


if __name__ == "__main__":
    main()
