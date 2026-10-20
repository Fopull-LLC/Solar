#!/usr/bin/env python3
"""Generate the flora textures into textures/flora/.

Everything is PROCEDURAL: leaves, needles, grass blades, fern fronds, kelp,
mushroom caps, cactus skin, crystal and bark are painted from parametric
outlines and Fourier noise with numpy + PIL from fixed seeds, so the set is
reproducible byte for byte and carries no third-party image licence.

    python3 tools/gen_flora_tex.py        # writes textures/flora/*.png

WHY ONE NEUTRAL SET. Since engine 0.117 a scatter source takes a `tint` (and
an `emissive`), and a prop keeps its model's base colour, maps and glow. So
every picture here is painted ONCE in a neutral grey ramp, and a species'
colour is a multiply at runtime: `flora_gen` turns the palette it picks into
`tint = palette.mid / NEUTRAL.mid` (and a bark colour into a bark tint the
same way). The PALETTES below are no longer painted; they are the colours the
runtime tints toward, published into flora_gen.lua by gen_flora.py.

Files:
  foliage_l0.png   1024² atlas, 4×4 tiles of 256, for every LOD: the engine
                   builds its mip chain (linear sampler, trilinear). The
                   hand-made 512²/256² coverage-kept LOD atlases are retired —
                   measured on 0.117, a far crown on the engine's mips covers
                   as much (67.1 % vs 66.2 %) and shimmers no more.
  foliage_n.png    the atlas's normal map (flat on the cut-out cards)
  foliage_glow.png 512²  the luminous parts only (gills, crystal, coral
                         pores): the emissive map, so a glowing species glows
                         where it should and nowhere else
  bark_<type>_l0.png 256², bark_<type>_l1.png 64²   tiling, neutral

Atlas tiles (index → what):
   0 broad leaves on a twig     1 small round leaves (bush)   2 conifer needles
   3 fern frond                 4 grass blades                5 grass with seed heads
   6 palm frond                 7 kelp ribbons                8 flowers + leaves
   9 mushroom cap (top, polar)  10 gills / glow pads (polar)  11 succulent skin
  12 cactus skin                13 crystal                    14 coral / tube pores
  15 top half: herb stem streaks, bottom half: moss
"""
import math
import os
import re

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "flora")
TILE = 256          # final tile size at LOD 0
SS = 2              # supersample for painting
T = TILE * SS       # painting resolution
GUT = 6             # px (final) the UVs keep inside each tile


# ── palettes ────────────────────────────────────────────────────────────────
# Each foliage palette: dark / mid / light foliage, a dry tip colour, an accent
# (flowers, cap spots), a glow colour (luminous patches), and which bark colour
# goes with it. `flora_gen` reads the summary that gen_flora.py writes into it.

def rgb(*c):
    return np.array(c, np.float32)


PALETTES = [
    # name          dark                  mid                   light                 tip                   accent                glow                  bark
    ("verdant",   rgb(.06, .16, .05), rgb(.17, .36, .10), rgb(.38, .58, .20), rgb(.55, .58, .22), rgb(.92, .86, .95), rgb(.60, 1.0, .55), 0),
    ("spring",    rgb(.14, .30, .06), rgb(.34, .58, .14), rgb(.62, .82, .30), rgb(.80, .80, .35), rgb(1.0, .92, .35), rgb(.80, 1.0, .40), 3),
    ("sage",      rgb(.18, .22, .14), rgb(.38, .44, .30), rgb(.60, .66, .50), rgb(.66, .62, .44), rgb(.80, .70, .90), rgb(.70, 1.0, .80), 2),
    ("chartreuse", rgb(.22, .28, .02), rgb(.52, .60, .08), rgb(.78, .84, .26), rgb(.86, .74, .30), rgb(.95, .45, .20), rgb(.90, 1.0, .30), 4),
    ("teal",      rgb(.02, .16, .15), rgb(.08, .38, .34), rgb(.28, .62, .55), rgb(.50, .62, .45), rgb(.98, .80, .40), rgb(.40, 1.0, .90), 2),
    ("emerald",   rgb(.01, .14, .06), rgb(.04, .34, .16), rgb(.18, .56, .30), rgb(.40, .50, .20), rgb(.95, .30, .35), rgb(.30, 1.0, .60), 1),
    ("amber",     rgb(.30, .10, .02), rgb(.70, .36, .07), rgb(.94, .64, .22), rgb(.85, .70, .40), rgb(.98, .90, .55), rgb(1.0, .70, .30), 1),
    ("crimson",   rgb(.20, .02, .04), rgb(.52, .06, .08), rgb(.80, .22, .18), rgb(.70, .40, .25), rgb(1.0, .80, .40), rgb(1.0, .35, .30), 5),
    ("ochre",     rgb(.30, .22, .06), rgb(.64, .52, .20), rgb(.86, .76, .42), rgb(.88, .80, .55), rgb(.85, .30, .15), rgb(1.0, .85, .40), 8),
    ("rust",      rgb(.18, .06, .03), rgb(.42, .18, .08), rgb(.66, .36, .18), rgb(.70, .52, .30), rgb(.95, .85, .40), rgb(1.0, .55, .25), 1),
    ("frost",     rgb(.22, .34, .34), rgb(.50, .66, .64), rgb(.78, .90, .88), rgb(.88, .94, .95), rgb(.70, .80, 1.0), rgb(.70, 1.0, 1.0), 3),
    ("azure",     rgb(.02, .12, .24), rgb(.10, .38, .58), rgb(.36, .66, .82), rgb(.60, .78, .85), rgb(1.0, .95, .60), rgb(.45, .85, 1.0), 2),
    ("indigo",    rgb(.04, .04, .16), rgb(.16, .14, .42), rgb(.36, .34, .70), rgb(.55, .50, .75), rgb(.95, .75, .40), rgb(.55, .55, 1.0), 7),
    ("violet",    rgb(.14, .04, .18), rgb(.40, .16, .48), rgb(.66, .40, .74), rgb(.72, .58, .70), rgb(.98, .90, .50), rgb(.85, .50, 1.0), 7),
    ("aubergine", rgb(.06, .01, .06), rgb(.20, .05, .17), rgb(.40, .16, .32), rgb(.44, .30, .34), rgb(.90, .50, .60), rgb(1.0, .40, .70), 5),
    ("umbra",     rgb(.02, .02, .025), rgb(.07, .06, .08), rgb(.20, .15, .20), rgb(.30, .24, .22), rgb(.75, .20, .25), rgb(.90, .30, .40), 5),
    ("rose",      rgb(.30, .06, .18), rgb(.70, .28, .48), rgb(.94, .60, .74), rgb(.90, .76, .70), rgb(1.0, .95, .80), rgb(1.0, .60, .85), 4),
    ("ivory",     rgb(.46, .46, .42), rgb(.74, .74, .68), rgb(.94, .94, .90), rgb(.95, .92, .80), rgb(.60, .80, .95), rgb(.90, 1.0, 1.0), 3),
    ("straw",     rgb(.34, .26, .12), rgb(.62, .52, .32), rgb(.86, .78, .56), rgb(.92, .86, .66), rgb(.75, .35, .55), rgb(1.0, .90, .55), 8),
]

BARKS = [
    ("brown",  rgb(.12, .08, .05), rgb(.30, .21, .14), rgb(.46, .36, .26)),
    ("dark",   rgb(.06, .04, .03), rgb(.17, .12, .09), rgb(.30, .23, .17)),
    ("grey",   rgb(.16, .16, .15), rgb(.40, .39, .37), rgb(.60, .59, .56)),
    ("pale",   rgb(.40, .38, .34), rgb(.80, .78, .73), rgb(.95, .94, .90)),
    ("red",    rgb(.16, .06, .04), rgb(.42, .19, .12), rgb(.62, .34, .22)),
    ("black",  rgb(.02, .02, .02), rgb(.08, .07, .07), rgb(.20, .18, .18)),
    ("green",  rgb(.08, .12, .05), rgb(.26, .34, .17), rgb(.44, .52, .30)),
    ("violet", rgb(.10, .07, .12), rgb(.30, .24, .34), rgb(.50, .42, .54)),
    ("ochre",  rgb(.20, .15, .08), rgb(.50, .40, .24), rgb(.70, .60, .42)),
]
BARK_TYPES = ["rough", "smooth", "palm", "stalk"]

# The neutral ramps everything is painted in. The ratios are the palettes'
# own (median luminance of dark, light, tip, accent against mid), so a tint of
# palette.mid / NEUTRAL mid lands each ramp close to where that palette painted
# it. Kept below 1 everywhere, so nothing clips before the multiply.
def _g(v):
    return rgb(v, v, v)


NEUTRAL_MID = 0.45
NEUTRAL = ("neutral", _g(0.18), _g(NEUTRAL_MID), _g(0.78), _g(0.82), _g(0.95), _g(0.95), 0)
NEUTRAL_BARK_MID = 0.5
NEUTRAL_BARK = ("neutral", _g(0.17), _g(NEUTRAL_BARK_MID), _g(0.83))
# Paints only what glows: every colour black but the glow.
MASK = ("mask", _g(0.0), _g(0.0), _g(0.0), _g(0.0), _g(0.0), _g(1.0), 0)
GLOW_TILES = {10, 13, 14}

TILE_NAMES = ["broad", "small", "needles", "frond", "blades", "seedgrass", "palm", "kelp",
              "flowers", "cap", "gills", "succulent", "cactus", "crystal", "coral", "stem_moss"]


def tile_uv(idx, inset=True):
    """(u0, v0, u1, v1) of a tile in the atlas, glTF UV (v down from the top)."""
    col, row = idx % 4, idx // 4
    g = GUT / (TILE * 4.0) if inset else 0.0
    return (col / 4 + g, row / 4 + g, (col + 1) / 4 - g, (row + 1) / 4 - g)


# ── fields ──────────────────────────────────────────────────────────────────

def spectral(h, w, rng, beta=1.8, sx=1.0, sy=1.0, lo=2.0):
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


def mix(a, b, t):
    t = np.asarray(t, np.float32)
    if t.ndim and t.shape[-1] != 1 and np.ndim(a) and np.shape(a)[-1] == 3:
        t = t[..., None]
    return a + (b - a) * t


def ramp3(dark, mid, light, t):
    """t 0..1 → dark→mid→light."""
    t = np.clip(t, 0, 1)[..., None]
    lo = dark + (mid - dark) * np.clip(t * 2, 0, 1)
    return np.where(t < 0.5, lo, mid + (light - mid) * np.clip(t * 2 - 1, 0, 1))


def jitter(c, rng, amt=0.08, val=0.15):
    """Per-element colour jitter: hue-ish channel wobble plus a brightness roll."""
    k = 1.0 + rng.uniform(-val, val)
    return np.clip(c * k + rng.uniform(-amt, amt, 3) * c.mean(), 0, 1).astype(np.float32)


class Canvas:
    """A straight-alpha RGBA float canvas painted back to front."""

    def __init__(self, h, w, bg=None):
        self.h, self.w = h, w
        self.rgb = np.zeros((h, w, 3), np.float32)
        self.a = np.zeros((h, w), np.float32)
        if bg is not None:
            self.rgb[:] = bg
            self.a[:] = 1.0

    def over(self, y0, x0, col, a):
        """Composite `col` (h,w,3) with alpha `a` (h,w) at (y0, x0), clipped."""
        h, w = a.shape
        ys, xs = max(0, y0), max(0, x0)
        ye, xe = min(self.h, y0 + h), min(self.w, x0 + w)
        if ye <= ys or xe <= xs:
            return
        sa = a[ys - y0:ye - y0, xs - x0:xe - x0]
        sc = col[ys - y0:ye - y0, xs - x0:xe - x0]
        da = self.a[ys:ye, xs:xe]
        out_a = sa + da * (1 - sa)
        num = sc * sa[..., None] + self.rgb[ys:ye, xs:xe] * (da * (1 - sa))[..., None]
        self.rgb[ys:ye, xs:xe] = num / np.maximum(out_a, 1e-6)[..., None]
        self.a[ys:ye, xs:xe] = out_a

    def image(self):
        out = np.concatenate([np.clip(self.rgb, 0, 1), np.clip(self.a, 0, 1)[..., None]], -1)
        return out


def _bbox(pts, pad, h, w):
    pts = np.asarray(pts)
    x0 = int(math.floor(pts[:, 0].min() - pad)); x1 = int(math.ceil(pts[:, 0].max() + pad))
    y0 = int(math.floor(pts[:, 1].min() - pad)); y1 = int(math.ceil(pts[:, 1].max() + pad))
    x0, y0 = max(x0, 0), max(y0, 0)
    x1, y1 = min(x1, w), min(y1, h)
    return x0, y0, x1, y1


def stroke(cv, pts, w0, w1, c0, c1=None, shade=0.35):
    """A tapered stroke along a polyline (twig, stem, rachis), rounded, with a
    lit side so it reads as a cylinder."""
    pts = np.asarray(pts, np.float32)
    if c1 is None:
        c1 = c0
    n = len(pts) - 1
    lens = np.linalg.norm(pts[1:] - pts[:-1], axis=1)
    tot = max(lens.sum(), 1e-6)
    acc = 0.0
    for i in range(n):
        p0, p1 = pts[i], pts[i + 1]
        t0, t1 = acc / tot, (acc + lens[i]) / tot
        acc += lens[i]
        wa, wb = w0 + (w1 - w0) * t0, w0 + (w1 - w0) * t1
        x0, y0, x1, y1 = _bbox([p0, p1], max(wa, wb) + 2, cv.h, cv.w)
        if x1 <= x0 or y1 <= y0:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
        d = p1 - p0
        L2 = max(float(d @ d), 1e-6)
        t = np.clip(((xx - p0[0]) * d[0] + (yy - p0[1]) * d[1]) / L2, 0, 1)
        px, py = p0[0] + d[0] * t, p0[1] + d[1] * t
        dist = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
        wid = (wa + (wb - wa) * t) * 0.5
        a = np.clip(wid - dist + 0.5, 0, 1)
        # signed side, for a lit edge
        side = ((xx - px) * -d[1] + (yy - py) * d[0]) / math.sqrt(L2)
        lit = 1.0 + shade * np.clip(side / np.maximum(wid, 0.5), -1, 1)
        tt = (t0 + (t1 - t0) * t)[..., None]
        col = (c0 + (c1 - c0) * tt) * lit[..., None]
        cv.over(y0, x0, col.astype(np.float32), a.astype(np.float32))


def leaf(cv, rng, base, ang, length, width, cols, shape="ovate", curve=0.0, veins=9,
         serr=0.0, vein_c=0.18, edge_dark=0.35, spot=0.0, fold=0.25, taper=1.0, wave=0.0,
         wave_f=6.0, lobes=0, mid_light=0.22):
    """One leaf, painted with a midrib, lateral veins, a folded light/dark half,
    darker margins and mottling. `cols` = (dark, mid, light) for THIS leaf.

    The leaf's own frame: `u` runs base→tip (0..1), `v` across (-1..1 of the
    local half-width). Everything is a function of (u, v), vectorised over the
    leaf's bounding box."""
    ca, sa = math.cos(ang), math.sin(ang)
    tip = (base[0] + ca * length, base[1] + sa * length)
    pad = width + abs(curve) * length + 4
    x0, y0, x1, y1 = _bbox([base, tip], pad, cv.h, cv.w)
    if x1 <= x0 or y1 <= y0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    dx, dy = xx - base[0], yy - base[1]
    u = (dx * ca + dy * sa) / length
    v = (-dx * sa + dy * ca)
    v = v - curve * length * np.clip(u, 0, 1) ** 2      # the leaf bends
    if wave:
        v = v - wave * width * np.sin(np.clip(u, 0, 1) * wave_f * math.pi)
    uc = np.clip(u, 0, 1)
    sinp = lambda x: np.clip(np.sin(x), 0, 1)
    if shape == "ovate":
        prof = sinp(math.pi * uc ** 0.75) ** 0.85
    elif shape == "lance":
        prof = sinp(math.pi * uc ** 0.6) ** 1.2 * (1 - uc) ** 0.15
    elif shape == "round":
        prof = np.sqrt(np.clip(1 - (2 * uc - 1) ** 2, 0, 1))
    elif shape == "blade":      # grass: wide base, long taper to a point
        prof = (1 - uc) ** taper * np.clip(uc * 30, 0, 1)
    elif shape == "needle":
        prof = np.clip((1 - uc) * 1.4, 0, 1) ** 0.6 * np.clip(uc * 12, 0, 1)
    elif shape == "ribbon":     # kelp: long, nearly parallel, round tip
        prof = np.clip((1 - uc) * 5, 0, 1) ** 0.5 * np.clip(uc * 8, 0, 1) ** 0.5
    elif shape == "petal":
        prof = sinp(math.pi * uc ** 1.1) ** 0.6
    else:
        prof = sinp(math.pi * uc)
    if serr:
        prof = prof * (1 - serr * (0.5 + 0.5 * np.sin(uc * veins * 2 * math.pi)) ** 3)
    if lobes:
        prof = prof * (0.6 + 0.4 * np.abs(np.sin(uc * lobes * math.pi)) ** 0.5)
    half = width * 0.5 * prof
    av = np.abs(v)
    inside = (u >= 0) & (u <= 1)
    a = np.clip(half - av + 0.6, 0, 1) * inside
    if not a.any():
        return
    vn = v / np.maximum(half, 1e-3)                     # -1..1 across
    dark, mid, light = cols
    # Folded halves: one side catches the light. Base darker, tip lighter.
    t = 0.52 + fold * np.sign(vn) * np.abs(vn) ** 0.5 * 0.5 + 0.15 * (uc - 0.4)
    # Mottling: low-frequency blotches + fine grain.
    gx = (xx * 0.13 + rng.uniform(0, 99))
    grain = (np.sin(gx) * np.sin(yy * 0.11 + gx * 0.3) * 0.5 + 0.5)
    t = t + (grain - 0.5) * 0.12 + rng.uniform(-0.04, 0.04)
    # Margins darken.
    t = t - edge_dark * smoothstep(0.65, 1.0, np.abs(vn)) * 0.5
    col = ramp3(dark, mid, light, t)
    # Midrib and lateral veins (lighter, thin).
    if veins:
        mid_l = np.exp(-(np.abs(vn) / 0.07) ** 2) * (1 - uc * 0.6)
        lat = np.abs(((uc * veins - np.abs(vn) * 0.9) % 1.0) - 0.5)
        lat_l = np.exp(-(lat / 0.06) ** 2) * smoothstep(1.0, 0.25, np.abs(vn)) * 0.7
        vl = np.clip(mid_l * mid_light / max(vein_c, 1e-3) + lat_l, 0, 1) * vein_c
        col = col + (light - col) * vl[..., None] * 1.6
    if spot:
        sp = (np.sin(xx * 0.9 + rng.uniform(0, 9)) * np.sin(yy * 0.8 + rng.uniform(0, 9)))
        col = col * (1 - spot * smoothstep(0.85, 1.0, sp)[..., None] * 0.6)
    cv.over(y0, x0, np.clip(col, 0, 1).astype(np.float32), a.astype(np.float32))


def tint_cols(pal, rng, k=0.0, jit=0.10):
    """(dark, mid, light) for one leaf: the palette, shifted toward light/dark by
    `k` and jittered, so a cluster never reads as clip-art."""
    _, dark, mid, light, tip, acc, glow, _ = pal
    s = k + rng.uniform(-0.18, 0.18)
    if s > 0:
        dark, mid, light = mix(dark, mid, s), mix(mid, light, s), mix(light, tip, s * 0.5)
    else:
        dark, mid, light = dark * (1 + s), mix(mid, dark, -s), mix(light, mid, -s)
    return tuple(jitter(np.asarray(c, np.float32), rng, jit, 0.1) for c in (dark, mid, light))


# ── tiles ───────────────────────────────────────────────────────────────────
# Each paints a T×T canvas (the tile at supersample) and returns it.

def tile_broad(pal, rng, bark):
    """A leafy spray: five twigs fanning from the card's foot, each carrying
    a dozen small alternate leaves — so a 2 m card reads as a branch-end full
    of 15-25 cm leaves, not as three giant ones."""
    cv = Canvas(T, T)
    twigs = []
    for tw in range(5):
        bx = T * (0.5 + rng.uniform(-0.04, 0.04)); by = T * 0.99
        ang = -math.pi / 2 + (tw - 2) * 0.38 + rng.uniform(-0.1, 0.1)
        L = T * rng.uniform(0.5, 0.68) * (1.0 - 0.12 * abs(tw - 2))
        bend = rng.uniform(-0.25, 0.25)
        pts = [(bx + math.cos(ang + bend * i / 6) * L * i / 6,
                by + math.sin(ang + bend * i / 6) * L * i / 6) for i in range(7)]
        twigs.append((pts, ang))
        stroke(cv, pts, T * 0.016, T * 0.005, bark[1], bark[2])
    for pts, ang in twigs:
        n = int(rng.integers(10, 14))
        for i in range(n):
            f = 0.15 + 0.85 * i / n
            k = f * 6
            i0 = min(5, int(k))
            p = (pts[i0][0] + (pts[i0 + 1][0] - pts[i0][0]) * (k - i0),
                 pts[i0][1] + (pts[i0 + 1][1] - pts[i0][1]) * (k - i0))
            side = 1 if i % 2 else -1
            la = ang + side * rng.uniform(0.55, 1.05)
            ln = T * rng.uniform(0.10, 0.14) * (1.1 - 0.3 * f)
            leaf(cv, rng, p, la, ln, ln * rng.uniform(0.42, 0.55), tint_cols(pal, rng, rng.uniform(-0.35, 0.35)),
                 shape="ovate", curve=side * rng.uniform(0.0, 0.12), veins=int(rng.integers(5, 8)),
                 serr=rng.uniform(0, 0.15), vein_c=0.14)
        leaf(cv, rng, pts[-1], ang + rng.uniform(-0.2, 0.2), T * 0.12, T * 0.06, tint_cols(pal, rng, 0.25),
             shape="ovate", veins=6)
    return cv


def tile_small(pal, rng, bark):
    cv = Canvas(T, T)
    c = np.array([T * 0.5, T * 0.55])
    for i in range(7):
        a = -math.pi / 2 + rng.uniform(-1.2, 1.2)
        stroke(cv, [(T * 0.5, T * 0.98), (c[0] + math.cos(a) * T * 0.3, c[1] + math.sin(a) * T * 0.3)],
               T * 0.014, T * 0.005, bark[1], bark[2])
    # A rounded mass of small leaves, darker inside, lighter on the rim.
    for i in range(240):
        r = math.sqrt(rng.uniform(0, 1)) * T * 0.42
        th = rng.uniform(0, 2 * math.pi)
        p = (c[0] + math.cos(th) * r, c[1] + math.sin(th) * r * 0.9)
        k = (r / (T * 0.42)) * 0.6 - 0.35 + (0.25 if math.sin(th) < 0 else -0.1)
        ln = T * rng.uniform(0.06, 0.10)
        leaf(cv, rng, p, rng.uniform(0, 2 * math.pi), ln, ln * rng.uniform(0.5, 0.7), tint_cols(pal, rng, k),
             shape="ovate", veins=4, vein_c=0.1)
    return cv


def tile_needles(pal, rng, bark):
    cv = Canvas(T, T)
    # A drooping conifer branchlet: main twig, side twigs, dense needles.
    main = [(T * 0.06 + i * T * 0.145, T * 0.22 + (i / 6) ** 1.4 * T * 0.5) for i in range(7)]
    twigs = [main]
    for i in range(1, 6):
        p = main[i]
        for side in (-1, 1):
            a = math.atan2(main[i + 1][1] - p[1], main[i + 1][0] - p[0]) + side * rng.uniform(0.6, 0.9)
            L = T * rng.uniform(0.26, 0.4) * (1 - i * 0.08)
            twigs.append([p, (p[0] + math.cos(a) * L, p[1] + math.sin(a) * L)])
    for tw in twigs:
        stroke(cv, tw, T * 0.016, T * 0.006, bark[1], bark[2])
    for tw in twigs:
        p0, p1 = np.array(tw[0], np.float32), np.array(tw[-1], np.float32)
        d = p1 - p0
        L = float(np.linalg.norm(d)) + 1e-6
        a0 = math.atan2(d[1], d[0])
        for j in range(int(L / (T * 0.012))):
            f = j / max(1, int(L / (T * 0.012)))
            p = p0 + d * f
            for side in (-1, 1):
                la = a0 + side * rng.uniform(0.5, 1.0)
                k = -0.2 + 0.5 * f + (0.3 if f > 0.85 else 0)      # new growth at the tips
                leaf(cv, rng, (p[0], p[1]), la, T * rng.uniform(0.07, 0.1), T * 0.014,
                     tint_cols(pal, rng, k, 0.06), shape="needle", veins=0, fold=0.4)
    return cv


def tile_frond(pal, rng, bark, palm=False):
    cv = Canvas(T, T)
    # A rachis curving up from the bottom, pinnae pairs shrinking to the tip.
    n = 22 if not palm else 30
    pts = []
    for i in range(n + 1):
        f = i / n
        x = T * (0.5 + 0.10 * math.sin(f * 2.2) - 0.05 * f)
        y = T * (0.98 - 0.94 * f)
        pts.append((x, y))
    stem_c = mix(pal[1], bark[1], 0.5) if not palm else bark[1]
    for i in range(1, n):
        f = i / n
        p = pts[i]
        d = np.subtract(pts[i + 1], pts[i - 1])
        a0 = math.atan2(d[1], d[0])
        for side in (-1, 1):
            if palm:
                la = a0 + side * (1.15 - 0.25 * f) + side * 0.25
                ln = T * 0.42 * (1 - f * 0.55) * rng.uniform(0.85, 1.0)
                leaf(cv, rng, p, la, ln, T * 0.035, tint_cols(pal, rng, rng.uniform(-0.2, 0.2)),
                     shape="lance", curve=-side * 0.12, veins=0, fold=0.5)
            else:
                la = a0 + side * (1.2 - 0.3 * f)
                ln = T * 0.30 * math.sin(math.pi * (0.15 + 0.85 * f) ** 0.8) * rng.uniform(0.9, 1.05)
                leaf(cv, rng, p, la, ln, ln * 0.28, tint_cols(pal, rng, 0.1 * (1 - f)),
                     shape="lance", curve=side * 0.05, veins=int(8 + 6 * (1 - f)), serr=0.35, vein_c=0.12)
    stroke(cv, pts, T * (0.02 if not palm else 0.03), T * 0.005, stem_c, mix(stem_c, pal[3], 0.3))
    return cv


def tile_blades(pal, rng, bark, seeds=False):
    cv = Canvas(T, T)
    n = 70
    order = sorted(range(n), key=lambda i: rng.uniform())
    for k, i in enumerate(order):
        depth = k / n                        # back → front: darker → lighter
        bx = T * rng.uniform(0.06, 0.94)
        L = T * rng.uniform(0.55, 0.97)
        ang = -math.pi / 2 + rng.uniform(-0.35, 0.35) + (bx / T - 0.5) * 0.5
        w = T * rng.uniform(0.018, 0.034)
        dark, mid, light, tip = pal[1], pal[2], pal[3], pal[4]
        cols = tint_cols(pal, rng, -0.35 + 0.55 * depth, 0.08)
        # dry tips: blend the light end toward the palette's tip colour
        tip_k = rng.uniform(0.0, 0.6)
        cols = (cols[0], cols[1], mix(cols[2], tip, tip_k))
        leaf(cv, rng, (bx, T * 0.995), ang, L, w, cols, shape="blade", taper=rng.uniform(0.8, 1.3),
             curve=rng.uniform(-0.18, 0.18), veins=0, fold=0.35, edge_dark=0.15, mid_light=0.4)
    if seeds:
        for i in range(9):
            bx = T * rng.uniform(0.15, 0.85)
            top = T * rng.uniform(0.04, 0.22)
            sway = rng.uniform(-0.12, 0.12) * T
            pts = [(bx, T), (bx + sway * 0.4, (T + top) / 2), (bx + sway, top + T * 0.12)]
            stroke(cv, pts, T * 0.008, T * 0.004, mix(pal[4], bark[1], 0.4), pal[4])
            hx, hy = pts[-1]
            for j in range(10):
                f = j / 10
                sx, sy = hx + rng.uniform(-3, 3) * SS, hy - f * T * 0.12
                leaf(cv, rng, (sx, sy), -math.pi / 2 + rng.uniform(-0.9, 0.9), T * 0.035, T * 0.016,
                     (mix(pal[4], bark[0], 0.5), pal[4], mix(pal[4], np.ones(3, np.float32), 0.4)),
                     shape="ovate", veins=0)
    return cv


def tile_kelp(pal, rng, bark):
    cv = Canvas(T, T)
    for i in range(2):
        bx = T * (0.3 + 0.4 * i + rng.uniform(-0.03, 0.03))
        leaf(cv, rng, (bx, T * 0.995), -math.pi / 2 + rng.uniform(-0.06, 0.06), T * 0.97, T * rng.uniform(0.22, 0.27),
             tint_cols(pal, rng, rng.uniform(-0.1, 0.2)), shape="ribbon", wave=0.1, wave_f=rng.uniform(3, 4.5),
             veins=40, vein_c=0.08, fold=0.12, edge_dark=-0.5, serr=0.12)
    return cv


def tile_flowers(pal, rng, bark):
    cv = Canvas(T, T)
    acc = pal[5]
    for i in range(16):       # foliage under the flowers
        p = (T * rng.uniform(0.15, 0.85), T * rng.uniform(0.35, 0.95))
        leaf(cv, rng, p, rng.uniform(0, 2 * math.pi), T * 0.16, T * 0.07, tint_cols(pal, rng, -0.1), shape="ovate", veins=6)
    for i in range(11):
        cx, cy = T * rng.uniform(0.15, 0.85), T * rng.uniform(0.12, 0.7)
        R = T * rng.uniform(0.05, 0.085)
        petals = int(rng.integers(5, 8))
        a0 = rng.uniform(0, 2 * math.pi)
        pc = jitter(acc, rng, 0.08, 0.1)
        for j in range(petals):
            a = a0 + j * 2 * math.pi / petals
            leaf(cv, rng, (cx, cy), a, R, R * 0.7, (pc * 0.55, pc * 0.85, np.clip(pc * 1.15, 0, 1)),
                 shape="petal", veins=3, vein_c=0.08, fold=0.1)
        ctr = mix(pal[4], np.array([0.9, 0.7, 0.15], np.float32), 0.6)
        leaf(cv, rng, (cx - R * 0.22, cy), 0.0, R * 0.44, R * 0.44, (ctr * 0.5, ctr, ctr * 1.2), shape="round", veins=0)
    return cv


def polar(T_):
    yy, xx = np.mgrid[0:T_, 0:T_].astype(np.float32)
    dx, dy = (xx - T_ / 2) / (T_ / 2), (yy - T_ / 2) / (T_ / 2)
    return np.sqrt(dx * dx + dy * dy), np.arctan2(dy, dx)


def tile_cap(pal, rng, bark):
    r, th = polar(T)
    n = spectral(T, T, rng, 1.6)
    acc = pal[5]
    base_d, base_m, base_l = pal[1], pal[2], pal[3]
    t = 0.75 - 0.45 * np.clip(r, 0, 1) ** 1.5 + (n - 0.5) * 0.25
    # concentric zones
    t = t + 0.08 * np.sin(r * rng.uniform(14, 26))
    # radial fibres
    t = t + 0.05 * np.sin(th * rng.uniform(60, 120) + n * 6)
    col = ramp3(base_d, base_m, base_l, t)
    # warts / spots in the accent colour (some species)
    if rng.uniform() < 0.75:
        spots = np.zeros((T, T), np.float32)
        for i in range(int(rng.integers(18, 40))):
            rr = math.sqrt(rng.uniform(0.0, 0.85))
            aa = rng.uniform(0, 2 * math.pi)
            cx, cy = T / 2 + math.cos(aa) * rr * T / 2, T / 2 + math.sin(aa) * rr * T / 2
            R = T * rng.uniform(0.012, 0.035) * (1.2 - rr * 0.5)
            yy, xx = np.ogrid[0:T, 0:T]
            d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / R
            spots = np.maximum(spots, np.clip(1.2 - d, 0, 1))
        col = col + (np.clip(acc, 0, 1) - col) * (spots[..., None] * 0.9)
    # dark rim
    col = col * (1 - 0.45 * smoothstep(0.82, 1.0, r))[..., None]
    return Canvas_from(col)


def tile_gills(pal, rng, bark):
    r, th = polar(T)
    glow = pal[6]
    lines = 0.5 + 0.5 * np.cos(th * 96 + np.sin(th * 7) * 2)
    t = 0.35 + 0.35 * lines * smoothstep(0.08, 0.3, r)
    col = ramp3(pal[1] * 0.6, mix(pal[2], glow, 0.5), mix(glow, np.ones(3, np.float32), 0.25), t)
    col = col * (0.55 + 0.45 * smoothstep(1.0, 0.2, r))[..., None]
    return Canvas_from(col)


def tile_succulent(pal, rng, bark):
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32) / T
    n = spectral(T, T, rng, 2.2, sx=4, sy=1)
    stripes = 0.5 + 0.5 * np.sin(xx * 2 * math.pi * 7 + n * 3)
    t = 0.35 + 0.25 * (1 - yy) + 0.12 * stripes + (n - 0.5) * 0.2
    col = ramp3(pal[1], pal[2], pal[3], t)
    bloom = smoothstep(0.55, 0.9, spectral(T, T, rng, 1.4))
    col = col + (np.array([0.85, 0.9, 0.88], np.float32) - col) * (bloom * 0.18)[..., None]
    col = col + (pal[4] - col) * (smoothstep(0.75, 1.0, yy) * 0.3)[..., None]
    return Canvas_from(col)


def tile_cactus(pal, rng, bark):
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32) / T
    ribs = 12
    rib = np.cos(xx * 2 * math.pi * ribs)
    n = spectral(T, T, rng, 2.0, sx=3, sy=1)
    t = 0.45 + 0.3 * rib + (n - 0.5) * 0.2
    col = ramp3(pal[1] * 0.8, pal[2], pal[3], t)
    cv = Canvas_from(col)
    # areoles on the rib crests, with pale spines
    sp = mix(pal[4], np.array([0.95, 0.92, 0.85], np.float32), 0.6)
    for i in range(ribs):
        x = (i + 0.0) / ribs * T + T / ribs * 0.0
        for j in range(9):
            y = (j + 0.5 + 0.5 * (i % 2)) / 9 * T
            if y >= T:
                continue
            leaf(cv, rng, (x, y), 0, T * 0.012, T * 0.012, (sp * 0.5, sp * 0.8, sp), shape="round", veins=0)
            for k in range(4):
                a = rng.uniform(0, 2 * math.pi)
                stroke(cv, [(x, y), (x + math.cos(a) * T * 0.03, y + math.sin(a) * T * 0.03)], SS * 1.2, SS * 0.4, sp, sp)
    return cv


def tile_crystal(pal, rng, bark):
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32) / T
    n = spectral(T, T, rng, 1.7, sx=5, sy=1)
    n2 = spectral(T, T, rng, 1.2)
    acc = mix(pal[3], pal[6], 0.5)
    t = 0.25 + 0.6 * (1 - yy) + (n - 0.5) * 0.35
    col = ramp3(pal[1] * 0.7, mix(pal[2], acc, 0.4), np.clip(acc * 1.1, 0, 1), t)
    # fracture planes: bright thin streaks
    fr = np.abs(((xx * 3 + yy * 1.3 + n2 * 0.8) % 1.0) - 0.5)
    col = col + (np.ones(3, np.float32) - col) * (np.exp(-(fr / 0.02) ** 2) * 0.35)[..., None]
    # facet edges at the tile's vertical quarters (prism faces map one each)
    edge = np.abs(((xx * 4) % 1.0) - 0.5)
    col = col + (np.ones(3, np.float32) - col) * (smoothstep(0.44, 0.5, edge) * 0.4)[..., None]
    return Canvas_from(col)


def tile_coral(pal, rng, bark):
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32) / T
    n = spectral(T, T, rng, 1.8)
    t = 0.4 + 0.35 * (1 - yy) + (n - 0.5) * 0.3
    col = ramp3(pal[1], pal[2], pal[3], t)
    cv = Canvas_from(col)
    pore = mix(pal[1] * 0.4, pal[6], 0.25)
    rim = mix(pal[3], pal[5], 0.3)
    for i in range(160):
        x, y = rng.uniform(0, T), rng.uniform(0, T)
        R = T * rng.uniform(0.008, 0.02)
        leaf(cv, rng, (x - R * 1.4, y), 0, R * 2.8, R * 2.8, (rim * 0.8, rim, rim), shape="round", veins=0)
        leaf(cv, rng, (x - R, y), 0, R * 2, R * 2, (pore * 0.6, pore, pore), shape="round", veins=0)
    return cv


def tile_stem_moss(pal, rng, bark):
    yy, xx = np.mgrid[0:T, 0:T].astype(np.float32) / T
    out = np.zeros((T, T, 3), np.float32)
    n = spectral(T, T, rng, 2.0, sx=8, sy=0.5)
    t = 0.4 + (n - 0.5) * 0.6 + 0.15 * np.sin(xx * 2 * math.pi * 3)
    stem = ramp3(mix(pal[1], bark[1], 0.4), mix(pal[2], bark[2], 0.3), pal[3], t)
    m = spectral(T, T, rng, 1.2)
    m2 = spectral(T, T, rng, 0.8)
    tm = 0.25 + 0.6 * m + 0.25 * (m2 - 0.5)
    moss = ramp3(pal[1] * 0.7, pal[2], mix(pal[3], pal[4], 0.3), tm)
    h = T // 2
    out[:h] = stem[:h]
    out[h:] = moss[h:]
    return Canvas_from(out)


def Canvas_from(col):
    cv = Canvas(col.shape[0], col.shape[1])
    cv.rgb[:] = np.clip(col, 0, 1)
    cv.a[:] = 1.0
    return cv


TILES = [tile_broad, tile_small, tile_needles, lambda p, r, b: tile_frond(p, r, b, False),
         lambda p, r, b: tile_blades(p, r, b, False), lambda p, r, b: tile_blades(p, r, b, True),
         lambda p, r, b: tile_frond(p, r, b, True), tile_kelp, tile_flowers, tile_cap, tile_gills,
         tile_succulent, tile_cactus, tile_crystal, tile_coral, tile_stem_moss]


# ── bark ────────────────────────────────────────────────────────────────────

def bark_tex(kind, cols, rng, size=512):
    dark, mid, light = cols
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    if kind == "rough":
        n1 = spectral(size, size, rng, 2.0, sx=7.0, sy=0.6)
        n2 = spectral(size, size, rng, 1.6)
        ridges = smoothstep(0.35, 0.65, n1)
        t = 0.15 + 0.7 * ridges + (n2 - 0.5) * 0.35
        col = ramp3(dark, mid, light, t)
        crack = smoothstep(0.42, 0.30, n1)
        col = col * (1 - 0.55 * crack)[..., None]
        lich = smoothstep(0.78, 0.9, spectral(size, size, rng, 1.3))
        col = col + (np.array([0.55, 0.62, 0.45], np.float32) - col) * (lich * 0.35)[..., None]
    elif kind == "smooth":
        n = spectral(size, size, rng, 1.5)
        t = 0.62 + (n - 0.5) * 0.3
        col = ramp3(dark, mid, light, t)
        # lenticels: short horizontal dark dashes
        for i in range(140):
            x, y = rng.uniform(0, 1), rng.uniform(0, 1)
            w, h = rng.uniform(0.02, 0.09), rng.uniform(0.003, 0.008)
            d = np.exp(-(((xx - x + 0.5) % 1 - 0.5) / w) ** 2 - (((yy - y + 0.5) % 1 - 0.5) / h) ** 2)
            col = col * (1 - 0.6 * d)[..., None]
        patches = smoothstep(0.7, 0.85, spectral(size, size, rng, 1.8, sx=1, sy=2))
        col = col * (1 - 0.45 * patches)[..., None]
    elif kind == "palm":
        n = spectral(size, size, rng, 2.0, sx=6, sy=0.4)
        rings = np.abs(((yy * 7 + n * 0.15) % 1.0) - 0.5)
        band = smoothstep(0.05, 0.16, rings)
        t = 0.2 + 0.55 * band + (n - 0.5) * 0.4
        col = ramp3(dark, mid, light, t)
        fib = spectral(size, size, rng, 1.2, sx=4, sy=1)
        col = col * (0.85 + 0.3 * fib)[..., None]
    else:  # stalk: fine pale fibres
        n = spectral(size, size, rng, 1.8, sx=10, sy=0.3)
        t = 0.55 + (n - 0.5) * 0.5
        col = ramp3(dark, mid, light, t)
    return np.clip(col, 0, 1)


# ── output ──────────────────────────────────────────────────────────────────

def downsample_rgba(img, size):
    """Premultiplied resize, then alpha re-thresholded so the cut-out keeps the
    coverage it had at full size (a naive shrink makes foliage go thin and
    then vanish into the distance)."""
    h = img.shape[0]
    a = img[..., 3:4]
    pm = np.concatenate([img[..., :3] * a, a], -1)
    out = []
    for c in range(4):
        ch = Image.fromarray((pm[..., c] * 255.0).astype(np.float32), mode="F")
        out.append(np.asarray(ch.resize((size, size), Image.BOX), np.float32) / 255.0)
    pm2 = np.stack(out, -1)
    a2 = pm2[..., 3]
    rgb2 = pm2[..., :3] / np.maximum(a2, 1e-4)[..., None]
    return np.concatenate([np.clip(rgb2, 0, 1), a2[..., None]], -1)


def keep_coverage(src_a, dst_a, opaque_tile):
    if opaque_tile:
        return np.ones_like(dst_a)
    target = float((src_a >= 0.5).mean())
    lo, hi = 0.02, 0.98
    for _ in range(24):
        mid = (lo + hi) / 2
        if float((dst_a >= mid).mean()) > target:
            lo = mid
        else:
            hi = mid
    thr = (lo + hi) / 2
    return np.clip((dst_a - thr) * 4.0 + 0.5, 0, 1)


OPAQUE_TILES = {9, 10, 11, 12, 13, 14, 15}


def save_png(arr, path, quant=True):
    im = Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA" if arr.shape[-1] == 4 else "RGB")
    if quant:
        im = im.quantize(colors=256, method=Image.Quantize.LIBIMAGEQUANT, dither=Image.Dither.FLOYDSTEINBERG)
    im.save(path, optimize=True)


def build_atlas(pal, bark, pi=0):
    atlas = np.zeros((TILE * 4, TILE * 4, 4), np.float32)
    tiles = []
    for ti, fn in enumerate(TILES):
        trng = np.random.default_rng(7919 * (ti + 1) + pi)     # same layout per tile index…
        trng_col = np.random.default_rng(31 * pi + ti)           # …(colour jitter differs)
        del trng_col
        cv = fn(pal, trng, bark)
        img = cv.image()
        img = downsample_rgba(img, TILE)
        if ti in OPAQUE_TILES:
            img[..., 3] = 1.0
        else:
            # Dilate colour into transparent texels so bilinear/LOD edges don't
            # fringe black.
            img = bleed(img)
        tiles.append(img)
        col, row = ti % 4, ti // 4
        atlas[row * TILE:(row + 1) * TILE, col * TILE:(col + 1) * TILE] = img
    return atlas, tiles


def bleed(img, iters=8):
    rgb = img[..., :3].copy()
    a = img[..., 3]
    known = a > 0.02
    for _ in range(iters):
        acc = np.zeros_like(rgb)
        cnt = np.zeros(a.shape, np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sh = np.roll(np.roll(known, dy, 0), dx, 1)
            acc += np.roll(np.roll(rgb, dy, 0), dx, 1) * sh[..., None]
            cnt += sh
        fill = (~known) & (cnt > 0)
        rgb[fill] = acc[fill] / cnt[fill][:, None]
        known = known | fill
    rgb[~known] = rgb[known].mean(0) if known.any() else 0
    return np.concatenate([rgb, a[..., None]], -1)


def lod_atlas(tiles, size_tile):
    atlas = np.zeros((size_tile * 4, size_tile * 4, 4), np.float32)
    for ti, img in enumerate(tiles):
        d = downsample_rgba(img, size_tile)
        d[..., 3] = keep_coverage(img[..., 3], d[..., 3], ti in OPAQUE_TILES)
        if ti not in OPAQUE_TILES:
            d = bleed(d, 4)
        col, row = ti % 4, ti // 4
        atlas[row * size_tile:(row + 1) * size_tile, col * size_tile:(col + 1) * size_tile] = d
    return atlas


def turf_tex(rng, size=256):
    """The ground wash a grass field lays under itself (a decal, tinted at
    runtime by the field's own grass colour — decals DO take a tint): pale
    speckled blades, a soft irregular edge."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    n = spectral(size, size, rng, 1.6)
    fine = spectral(size, size, rng, 0.6)
    streak = spectral(size, size, rng, 1.0, sx=3, sy=0.6)
    v = 0.78 + 0.22 * n - 0.25 * smoothstep(0.62, 0.9, fine) + 0.08 * (streak - 0.5)
    r = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) * 2
    edge = smoothstep(1.0, 0.45, r + (spectral(size, size, rng, 2.0) - 0.5) * 0.5)
    a = np.clip(edge * (0.75 + 0.25 * n), 0, 1)
    rgb = np.stack([v, v, v], -1)
    return np.concatenate([np.clip(rgb, 0, 1), a[..., None]], -1)


# ── relief: normal maps ─────────────────────────────────────────────────────

def normal_from_height(h, strength=4.0, wrap=True):
    """Tangent-space normal map (glTF: +Y up in texture space = green) from a
    height field 0..1. Wrapping differences for tiling pictures."""
    if wrap:
        dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
        dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    else:
        dx = np.gradient(h, axis=1)
        dy = np.gradient(h, axis=0)
    n = np.stack([-dx * strength * h.shape[1] / 64.0, dy * strength * h.shape[0] / 64.0, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return (n * 0.5 + 0.5).astype(np.float32)


def lum(rgb):
    return (rgb[..., 0] * 0.3 + rgb[..., 1] * 0.59 + rgb[..., 2] * 0.11).astype(np.float32)


def save_rgb(arr, path):
    Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(path, optimize=True)


# ── rock ────────────────────────────────────────────────────────────────────
# Surface rock, for the mineral field: stratified, weathered stone painted in
# a neutral ramp (tinted at runtime to the world's own strata colour), with a
# normal map and a roughness map, tiling both ways.

def rock_height(size, rng):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    warp = spectral(size, size, rng, 2.2)
    big = spectral(size, size, rng, 2.0)
    mid = spectral(size, size, rng, 1.5)
    fine = spectral(size, size, rng, 0.9)
    # strata: bands across v, warped and of uneven thickness
    phase = yy * 9.0 + (warp - 0.5) * 1.6 + (big - 0.5) * 0.6
    band = np.abs(((phase) % 1.0) - 0.5) * 2
    strata = smoothstep(0.15, 0.85, band)
    ledge = smoothstep(0.88, 0.98, band)               # the thin hard layers stand out
    h = 0.35 * strata + 0.25 * mid + 0.15 * fine + 0.25 * big - 0.2 * ledge
    # fractures: thin dark cuts across the layers
    fr = spectral(size, size, rng, 1.9, sx=0.4, sy=3.0)
    crack = smoothstep(0.035, 0.0, np.abs(fr - 0.5))
    h = h - 0.25 * crack
    h = (h - h.min()) / max(1e-6, h.max() - h.min())
    return h, strata, crack, fine, phase


def rock_textures(size=512):
    rng = np.random.default_rng(4242)
    h, strata, crack, fine, phase = rock_height(size, rng)
    # Albedo: layers of slightly different shade (and a faint warm/cool
    # alternation, so a tint doesn't land as one flat colour), darker in the
    # cracks and hollows, paler where weathered on the high points.
    layer = np.floor(phase).astype(np.int64)
    shades = np.random.default_rng(7).uniform(0.78, 1.18, 64)
    warmth = np.random.default_rng(8).uniform(-0.06, 0.06, 64)
    k = shades[layer % 64]
    w = warmth[layer % 64]
    base = 0.46 * k * (0.82 + 0.3 * fine)
    rgb = np.stack([base * (1 + w), base, base * (1 - w)], -1)
    rgb = rgb * (1 - 0.55 * crack)[..., None]
    rgb = rgb * (0.72 + 0.4 * h)[..., None]
    # weathering: pale dust on the upper faces, dark stains running down
    dust = smoothstep(0.62, 0.9, h) * 0.18
    rgb = rgb + (0.75 - rgb) * dust[..., None]
    stain = spectral(size, size, rng, 1.6, sx=0.3, sy=4.0)
    rgb = rgb * (1 - 0.18 * smoothstep(0.6, 0.85, stain))[..., None]
    # lichen-ish speckle, neutral (it takes the tint like the rock)
    speck = smoothstep(0.82, 0.9, spectral(size, size, rng, 0.5))
    rgb = rgb + (0.85 - rgb) * (speck * 0.25)[..., None]
    albedo = np.clip(rgb, 0, 1)
    normal = normal_from_height(h, 5.0)
    # glTF metallicRoughness: G = roughness, B = metalness. Rough everywhere,
    # a little smoother on the hard layers, never metal.
    rough = np.clip(0.92 - 0.25 * smoothstep(0.85, 1.0, h) - 0.1 * (1 - crack) * strata * 0.3, 0.5, 1.0)
    mr = np.stack([np.ones_like(rough), rough, np.zeros_like(rough)], -1)
    return albedo, normal, mr


def crystal_rock_textures(size=256):
    """The mineral field's crystal outcrops: the flora atlas has a crystal tile,
    but an outcrop wants its own, bright-cored and fractured, with relief."""
    rng = np.random.default_rng(99)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    n = spectral(size, size, rng, 1.7, sx=5, sy=1)
    n2 = spectral(size, size, rng, 1.2)
    t = 0.3 + 0.55 * (1 - yy) + (n - 0.5) * 0.35
    col = 0.25 + 0.6 * t
    fr = np.abs(((xx * 3 + yy * 1.3 + n2 * 0.8) % 1.0) - 0.5)
    streak = np.exp(-(fr / 0.02) ** 2)
    col = col + (1 - col) * streak * 0.4
    edge = np.abs(((xx * 4) % 1.0) - 0.5)
    col = col + (1 - col) * smoothstep(0.44, 0.5, edge) * 0.35
    albedo = np.stack([col, col, col], -1)
    h = np.clip(0.5 + 0.3 * streak - 0.2 * smoothstep(0.44, 0.5, edge) + 0.1 * (n - 0.5), 0, 1)
    normal = normal_from_height(h, 2.0)
    rough = 0.25 + 0.2 * n2
    mr = np.stack([np.ones_like(rough), rough, np.zeros_like(rough)], -1)
    glow = np.clip(streak * 0.8 + 0.25 * t, 0, 1)
    return albedo, normal, mr, np.stack([glow] * 3, -1)


def main():
    os.makedirs(OUT, exist_ok=True)
    nbark = NEUTRAL_BARK[1:]
    atlas, tiles = build_atlas(NEUTRAL, nbark)
    save_png(atlas, os.path.join(OUT, "foliage_l0.png"))
    for old in ("foliage_l1.png", "foliage_l2.png"):     # the hand-made LOD atlases, retired
        if os.path.exists(os.path.join(OUT, old)):
            os.remove(os.path.join(OUT, old))
    # Relief for the solid tiles (caps, gills, succulent and cactus skin,
    # crystal, coral, stems): a normal map from each tile's own shading. The
    # cards (leaves, blades, fronds) stay flat — their lighting normal is set
    # per card by the mesh, and a bumped cut-out only adds noise.
    nrm = np.zeros((TILE * 4, TILE * 4, 3), np.float32) + np.array([0.5, 0.5, 1.0], np.float32)
    for ti in OPAQUE_TILES:
        col, row = ti % 4, ti // 4
        sl = (slice(row * TILE, (row + 1) * TILE), slice(col * TILE, (col + 1) * TILE))
        nrm[sl] = normal_from_height(lum(atlas[sl][..., :3]), 3.0, wrap=False)
    save_rgb(nrm, os.path.join(OUT, "foliage_n.png"))
    # The emissive map: the glow tiles painted in the mask palette, the rest black.
    mask, _ = build_atlas(MASK, (_g(0.0), _g(0.0), _g(0.0)))
    glow = np.zeros((TILE * 4, TILE * 4, 3), np.float32)
    for ti in GLOW_TILES:
        col, row = ti % 4, ti // 4
        sl = (slice(row * TILE, (row + 1) * TILE), slice(col * TILE, (col + 1) * TILE))
        g = mask[sl][..., :3].max(-1)
        glow[sl] = np.clip(g * 1.4, 0, 1)[..., None]
    gi = Image.fromarray((glow * 255 + 0.5).astype(np.uint8), "RGB").resize((TILE * 2, TILE * 2), Image.BOX)
    gi.save(os.path.join(OUT, "foliage_glow.png"), optimize=True)
    print("foliage: neutral atlas, two LOD atlases and the glow map")
    save_png(turf_tex(np.random.default_rng(77)), os.path.join(OUT, "turf.png"), quant=False)
    for kind in BARK_TYPES:
        rng = np.random.default_rng(500 + BARK_TYPES.index(kind))
        big = bark_tex(kind, nbark, rng, 512)
        im0 = np.asarray(Image.fromarray((big * 255).astype(np.uint8)).resize((256, 256), Image.LANCZOS), np.float32) / 255
        im1 = np.asarray(Image.fromarray((big * 255).astype(np.uint8)).resize((64, 64), Image.BOX), np.float32) / 255
        save_png(im0, os.path.join(OUT, f"bark_{kind}_l0.png"))
        save_png(im1, os.path.join(OUT, f"bark_{kind}_l1.png"))
        save_rgb(normal_from_height(lum(im0), 4.0 if kind in ("rough", "palm") else 2.0),
                 os.path.join(OUT, f"bark_{kind}_n.png"))
    print("bark: neutral " + ", ".join(BARK_TYPES) + ", with normal maps")
    alb, nrm_r, mr = rock_textures(512)
    save_rgb(alb, os.path.join(OUT, "rock_l0.png"))
    save_rgb(nrm_r, os.path.join(OUT, "rock_n.png"))
    save_rgb(mr, os.path.join(OUT, "rock_mr.png"))
    alb, nrm_c, mr, glow_c = crystal_rock_textures(256)
    save_rgb(alb, os.path.join(OUT, "crystal_l0.png"))
    save_rgb(nrm_c, os.path.join(OUT, "crystal_n.png"))
    save_rgb(mr, os.path.join(OUT, "crystal_mr.png"))
    save_rgb(glow_c, os.path.join(OUT, "crystal_glow.png"))
    print("rock: stratified stone and crystal, albedo + normal + roughness")
    # The per-palette pictures this generator used to bake (engine 0.116 had
    # no tint) are gone: delete any left from an older run.
    gone = 0
    for f in os.listdir(OUT):
        if re.match(r"^(foliage_p\d\d_l\d|bark_[a-z]+_b\d\d_l\d)\.png$", f):
            os.remove(os.path.join(OUT, f))
            gone += 1
    if gone:
        print(f"removed {gone} baked palette pictures")


if __name__ == "__main__":
    main()
