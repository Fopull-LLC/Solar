"""The EVA suit's tiling PBR sets (albedo, normal, ORM, height), built in
physical units the way tools/detail_maps.py builds every height in Solar: each
relief is modelled in MILLIMETRES at a stated texel size, its normal map is
that height's true slope (so `normal_strength: 1.0` is the real relief), the
AO is the height's own cavity, and textures/heights.json records each height's
depth and texel. Called by tools/gen_suit.py; numpy + Pillow.

    fabric   0.25 m tile, 1024 px (0.24 mm a texel): the TMG's outer layer, an
             ortho-fabric. A plain weave (1 mm yarn pitch) with a ripstop grid
             every 6 mm, the cloth's own crinkle (creases a few millimetres to
             a couple of centimetres long, not quilting), the insulation's
             soft unevenness under it, and a double-needle seam with its fold
             down u = 0 (the loft's u = 0, which the builder turns to the
             inside of each limb). Off-white: the vertex colours (and the
             material's colour, the suit-tint slot) carry the shade.
    shell    0.5 m tile, 1024 px (0.49 mm): the hard parts' paint over a
             composite: orange peel, faint sanding marks, scratches that have
             taken up grime, scuffs, and chips through to a grey primer.
    metal    0.25 m tile, 512 px (0.49 mm): the bearings' hard-anodised
             aluminium: brushed along u (round each ring), fine dings,
             machining rings.
    rubber   0.25 m tile, 1024 px (0.24 mm): RTV silicone grip, the dots of
             the glove's palm pads and fingertips and the boot's sole rubber:
             raised pebbles on a staggered 2.6 mm grid over a fine matte grain,
             worn smoother where they wear.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detail_maps as DM  # noqa: E402

TEXDIR = os.path.join(DM.TEX, "suit")


def _grid(n):
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    return yy, xx


def _ridges(n, rng, sigma, sx=1.0, sy=1.0):
    """Creases: the zero lines of band noise as sharp-crested ridges (0..1),
    stretched sx by sy (a crease runs along its stretch)."""
    a = rng.standard_normal((n, n)).astype(np.float32)
    fy = np.fft.fftfreq(n)[:, None] * sy
    fx = np.fft.fftfreq(n)[None, :] * sx
    k = np.exp(-2 * (np.pi ** 2) * (sigma ** 2) * (fx * fx + fy * fy))
    b = np.real(np.fft.ifft2(np.fft.fft2(a) * k)).astype(np.float32)
    b /= b.std() + 1e-6
    return np.exp(-(b / 0.35) ** 2)


def _creases(n, rng, count, len_px, width_px, angle_sd, amp=1.0):
    """Cloth creases: `count` soft folds, each a short arc with a sharp crest
    and shoulders that fade to its ends, lying mostly along u (a sleeve or a
    leg crumples ACROSS its length, so its creases run round it) within
    angle_sd radians; drawn on the torus so the map tiles. Heights in units of
    amp, up (a ridge) or down (a fold line) at random."""
    h = np.zeros((n, n), np.float32)
    for _ in range(count):
        L = rng.uniform(*len_px)
        w = rng.uniform(*width_px)
        a = rng.normal(0.0, angle_sd)
        bend = rng.normal(0.0, 0.8) / max(L, 1.0)
        sgn = 1.0 if rng.uniform() < 0.7 else -0.6
        x0, y0 = rng.uniform(0, n, 2)
        r = int(L / 2 + 3 * w) + 2
        ys, xs = np.mgrid[-r:r + 1, -r:r + 1].astype(np.float32)
        t = xs * math.cos(a) + ys * math.sin(a)
        d = -xs * math.sin(a) + ys * math.cos(a) - bend * t * t
        along = np.clip(1 - (2 * t / L) ** 2, 0, 1)
        prof = np.exp(-np.abs(d) / w) * along ** 1.5 * sgn
        iy = (np.arange(-r, r + 1) + int(y0)) % n
        ix = (np.arange(-r, r + 1) + int(x0)) % n
        h[np.ix_(iy, ix)] += prof * amp
    return h


def _save(stem, alb, h_mm, texel, rough, metal, method, tile_m, ao_k=0.5, orm_size=None):
    DM.save_rgb(np.clip(alb, 0, 1), DM.out(stem + "_albedo.png"))
    DM.save_rgb(DM.normal_rgb(h_mm, texel), DM.out(stem + "_normal.png"))
    ao = DM.cavity_ao(h_mm, texel, radii_mm=(0.6, 2.0, 8.0), k=ao_k)
    DM.save_orm(ao, np.clip(rough, 0.05, 1), np.clip(metal, 0, 1), DM.out(stem + "_orm.png"), size=orm_size)
    n = h_mm.shape[1]
    DM.save_height(h_mm, DM.out(stem + "_height.png"), texel, method, size=min(n, 512), tile_m=tile_m)


def fabric(n=1024, tile_m=0.25):
    texel = tile_m * 1000 / n                     # 0.244 mm
    rng = np.random.default_rng(3101)
    yy, xx = _grid(n)
    # plain weave: warp (along v) and weft (along u) yarns, 4 px (≈1 mm) pitch,
    # each passing over then under its crossing yarn
    p = 4.0
    wx = 0.5 + 0.5 * np.cos(TAU * xx / p)
    wy = 0.5 + 0.5 * np.cos(TAU * yy / p)
    chk = np.sign(np.sin(math.pi * (np.floor(xx / p) + np.floor(yy / p)) + 0.5 * math.pi))
    weave = wx * (0.5 + 0.5 * chk) + wy * (0.5 - 0.5 * chk)
    # ripstop: a doubled, heavier thread every 24 px (5.9 mm), both ways
    rp = 24.0
    rip = np.maximum(np.exp(-((xx % rp) - 1.5) ** 2 / 1.6), np.exp(-((yy % rp) - 1.5) ** 2 / 1.6))
    # the cloth's crinkle: creases at a few lengths, mostly along v (the
    # limbs' length: a sleeve crumples across, a seat along), and the
    # insulation's soft unevenness under it
    cr = (_creases(n, rng, 420, (18, 70), (1.2, 2.6), 0.45, 0.10)
          + _creases(n, rng, 110, (70, 260), (3.0, 7.0), 0.35, 0.22))
    puff = DM.noise((n, n), rng, 60)
    mott = DM.noise((n, n), rng, 90)
    fib = DM.noise((n, n), rng, 1.2)
    # the seam down u = 0: a fold sunk 0.9 mm, two rows of lock stitches
    # (3 mm stitches, 1 mm gaps) 4 mm and 7.5 mm from it, and the tape under
    du = np.minimum(xx, n - xx)
    du_mm = du * texel
    fold = np.exp(-(du_mm / 1.2) ** 2)
    tape = DM.smoothstep(10.5, 9.5, du_mm)
    ph = (yy * texel) % 4.0
    st_on = (ph > 0.5) & (ph < 3.5)
    stitch = np.zeros_like(xx)
    for row in (4.0, 7.5):
        stitch = np.maximum(stitch, np.exp(-((du_mm - row) / 0.32) ** 2) * st_on)
    holes = np.zeros_like(xx)
    for row in (4.0, 7.5):
        holes = np.maximum(holes, np.exp(-((du_mm - row) / 0.3) ** 2) * np.exp(-((ph - 0.25) / 0.25) ** 2))
    h = (0.030 * weave + 0.045 * rip + cr + 0.25 * puff * 0.5 + 0.008 * fib
         - 0.9 * fold + 0.10 * tape + 0.14 * stitch - 0.08 * holes)
    # albedo: off-white, its unevenness, faint tea stains, the cavities a
    # shade darker (dust lives there), the thread a little greyer
    stain = DM.smoothstep(1.1, 2.4, DM.noise((n, n), rng, 45)) * DM.smoothstep(0.0, 1.2, DM.noise((n, n), rng, 12))
    v = 0.925 + 0.020 * mott + 0.010 * fib - 0.035 * fold - 0.020 * (1 - weave) * 0.5 - 0.012 * rip
    alb = np.stack([v, v * 0.995, v * 0.985], -1)
    alb -= stain[..., None] * np.array([0.045, 0.055, 0.075])
    alb = alb * (1 - stitch[..., None] * 0.10) + stitch[..., None] * np.array([0.80, 0.80, 0.79]) * 0.10
    rough = 0.86 + 0.04 * fib - 0.06 * stitch + 0.04 * stain - 0.03 * rip
    _save(os.path.join(TEXDIR, "fabric"), alb, h, texel, rough, np.zeros_like(v),
          "ortho-fabric: plain weave 1 mm, ripstop 5.9 mm, crinkle, a double-needle seam (tools/suit_textures.py)",
          tile_m)


def shell(n=1024, tile_m=0.5):
    texel = tile_m * 1000 / n                     # 0.49 mm
    rng = np.random.default_rng(3201)
    yy, xx = _grid(n)
    peel = DM.noise((n, n), rng, 2.2)
    mott = DM.noise((n, n), rng, 70)
    sand = _ridges(n, rng, 1.5, 1.0, 0.08) * 0.6 + _ridges(n, rng, 1.5, 0.08, 1.0) * 0.4
    scuff = DM.smoothstep(1.0, 2.2, DM.noise((n, n), rng, 18)) * DM.smoothstep(-0.2, 1.0, DM.noise((n, n), rng, 4))
    chips = DM.smoothstep(2.9, 3.2, DM.noise((n, n), rng, 3.5)) * DM.smoothstep(0.4, 1.2, mott)
    scr = np.zeros((n, n), np.float32)
    for _ in range(46):                          # scratches: thin, mostly short, some long arcs
        x0, y0 = rng.uniform(0, n, 2)
        a = rng.uniform(0, math.pi)
        L = rng.uniform(15, 140) if rng.uniform() < 0.8 else rng.uniform(150, 380)
        for ox in (-n, 0, n):
            for oy in (-n, 0, n):
                t = (xx - x0 - ox) * math.cos(a) + (yy - y0 - oy) * math.sin(a)
                dd = np.abs(-(xx - x0 - ox) * math.sin(a) + (yy - y0 - oy) * math.cos(a) - 0.0006 * t * t)
                m = (t > 0) & (t < L)
                if m.any():
                    scr = np.maximum(scr, np.exp(-(dd / 0.55) ** 2) * m * rng.uniform(0.3, 1.0))
    h = 0.018 * peel + 0.006 * sand - 0.08 * scr - 0.12 * chips - 0.01 * scuff
    v = 0.94 + 0.015 * mott - 0.04 * scuff - 0.05 * scr
    alb = np.stack([v, v * 0.997, v * 0.99], -1)
    primer = np.array([0.62, 0.63, 0.64])
    alb = alb * (1 - chips[..., None]) + primer * chips[..., None]
    rough = 0.40 + 0.03 * mott + 0.20 * scuff + 0.18 * scr + 0.25 * chips + 0.03 * sand
    _save(os.path.join(TEXDIR, "shell"), alb, h, texel, rough, np.zeros_like(v),
          "painted composite: orange peel, sanding, scratches, scuffs, chips (tools/suit_textures.py)", tile_m)


def metal(n=512, tile_m=0.25):
    texel = tile_m * 1000 / n                     # 0.49 mm
    rng = np.random.default_rng(3301)
    yy, xx = _grid(n)
    brush = DM.noise((n, n), rng, 0.8)
    brush = DM.blur(brush, 0.0)
    # streaks along u: blur along x only (FFT, anisotropic)
    a = rng.standard_normal((n, n)).astype(np.float32)
    fy = np.fft.fftfreq(n)[:, None]
    fx = np.fft.fftfreq(n)[None, :]
    k = np.exp(-2 * (np.pi ** 2) * ((40.0 * fx) ** 2 + (0.7 * fy) ** 2))
    streak = np.real(np.fft.ifft2(np.fft.fft2(a) * k)).astype(np.float32)
    streak /= streak.std() + 1e-6
    ding = DM.smoothstep(2.4, 2.9, DM.noise((n, n), rng, 2.0))
    mott = DM.noise((n, n), rng, 50)
    rings = 0.5 + 0.5 * np.sin(TAU * yy / 9.0 + 0.6 * DM.noise((n, n), rng, 30))
    h = 0.004 * streak + 0.002 * rings - 0.05 * ding
    v = 0.90 + 0.025 * streak + 0.015 * mott - 0.08 * ding
    alb = np.stack([v, v, v * 1.005], -1)
    rough = 0.34 + 0.05 * streak + 0.04 * mott + 0.20 * ding
    met = np.full_like(v, 0.9)
    _save(os.path.join(TEXDIR, "metal"), alb, h, texel, rough, met,
          "hard-anodised aluminium, brushed along u, dings (tools/suit_textures.py)", tile_m, ao_k=0.3)


def rubber(n=1024, tile_m=0.25):
    texel = tile_m * 1000 / n                     # 0.244 mm
    rng = np.random.default_rng(3401)
    yy, xx = _grid(n)
    # RTV dots: a staggered grid, 2.6 mm pitch (n / 96 so it tiles), 0.8 mm
    # radius, 0.22 mm proud, each a little irregular
    cells = 96
    pitch = n / cells
    row = np.floor(yy / pitch)
    off = (row % 2) * pitch / 2
    cx = (np.floor((xx - off) / pitch) + 0.5) * pitch + off
    cy = (row + 0.5) * pitch
    jit = DM.noise((n, n), rng, 6) * 0.25 * pitch
    d = np.hypot(xx - cx + jit * 0.3, yy - cy) * texel
    dots = DM.smoothstep(0.95, 0.55, d)
    grain = DM.noise((n, n), rng, 0.9)
    wear = DM.smoothstep(0.4, 1.6, DM.noise((n, n), rng, 50))
    mott = DM.noise((n, n), rng, 40)
    h = 0.22 * dots * (1 - 0.5 * wear) + 0.008 * grain
    v = 0.86 + 0.03 * mott + 0.05 * dots * wear
    alb = np.stack([v, v, v * 1.01], -1)
    rough = 0.80 + 0.04 * grain - 0.18 * dots * wear
    _save(os.path.join(TEXDIR, "rubber"), alb, h, texel, rough, np.zeros_like(v),
          "RTV silicone grip dots on a matte grain (tools/suit_textures.py)", tile_m)


TAU = 2 * math.pi


def all_sets():
    os.makedirs(TEXDIR, exist_ok=True)
    fabric()
    shell()
    metal()
    rubber()
    DM.write_hjson()
    DM.register_textures([p for p in DM.WRITTEN])
    return list(DM.WRITTEN)


if __name__ == "__main__":
    for p in all_sets():
        print(p)
