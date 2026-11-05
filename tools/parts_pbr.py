#!/usr/bin/env python3
"""The CRAFT PARTS' and the RESEARCH LAB's surfaces from the realistic PBR library (wave 3 of
the texture upgrade).

    python3 tools/parts_pbr.py             # bake what changed (gen_part_textures.py and
                                           # gen_lab.py run it too)
    python3 tools/parts_pbr.py --force     # bake everything again
    python3 tools/parts_pbr.py --only paint tread
    python3 tools/parts_pbr.py --sheet DIR # before/after contact sheet into DIR, outside the repo

Writes textures/parts/<name>_{albedo,normal,orm}.png for the hull materials every part, tool
and crate shares (tools/gen_part_meshes.py MATERIALS), and textures/lab/{wall,floor,steel}_*
(tools/gen_lab.py _mat). What stays procedural, untouched here: the decal atlas
(parts/markings), the cabin atlas (parts/interior: screens and switches), the solar cells
(drawn busbars and fingers, nothing in the library is closer), the flag and emblem, the lab's
signs and screens, and the scientists' cloth and knit (no fabric in the library).

THE PANELS STAY WHERE THEY WERE. Each part's mesh lays its UVs by world size (paint 1 m a tile,
metal and tiles 0.5 m, ...), and the procedural maps carry structure the meshes are built
around: the paint's staggered panel seams, rivet rows and hatches, the alloy's seams and hex
bolts, the 125 mm thermal tiles, the heat shield's honeycomb, the nozzle's cooling tubes and
heat-tint bands, the foil's tape seam, the tyre's chevrons. That structure is taken from the
procedural generator itself (tools/gen_part_textures.py, run into a temporary folder) and the
photographic sets supply the SURFACE at their real size inside the same tile: the paint's
mottling, scratches and grime, the alloy's streaks, a ceramic's pores, char, a rubber's grain.
No model, prefab or script changes.

NO VISIBLE REPEAT INSIDE A TILE. As wave 2 (tools/base_pbr.py bomb): a set is laid from
patches at random offsets joined on soft wandering seams, and its broad light-and-dark blotches
are flattened, since those are what read as a repeat down a 10 m tank.

TINT COMES FROM THE MATERIAL. A part's material colour multiplies the albedo (the hull shader's
`tint` x the texture: shaders/hullPanels.flsl); one white paint map serves the white, grey,
dark, orange and yellow paints, one alloy map the bare, dark, anodised and chrome metals. So
each albedo is kept neutral where it was neutral and its mean (linear light) is matched to the
procedural map it replaces; the roughness and metal means are kept too, because the materials
multiply them (Chrome's roughness 0.4, Dark's 1.2 ...).

LICENSING (the repo is public). Every set used here is CC0 (ambientCG), so every output is
committed; nothing is written to textures/env_local and no local overlay is needed.

  texture        tile    px            structure (procedural)         surface (CC0)
  parts/paint    1 m     1024 / 512    seams, rivets, hatches, grime  Metal052C painted plate: mottle,
                                       streaks, chips                 scratches, specks
  parts/metal    0.5 m   512           seams, hex bolts, brush grain  Metal048C streaks and spots
                                                                      (greyed), Metal052C scratches
  parts/tiles    0.5 m   512           125 mm tiles, gap filler       Rock035 basalt pores
  parts/ablative 0.67 m  512           honeycomb, char blotches       Rock063 burnt-organic grain
  parts/bell     (bell)  512 x 1024    cooling tubes, heat tint       Metal048C streaks (greyed)
  parts/foil     0.5 m   512           crinkles, tape seam            Metal048C gold, its spots
  parts/tread    0.5 m   512           (the photo's own lozenges)     DiamondPlate008C, whole
  parts/rubber   tyre    512           chevron lugs, sipes, dust      Road010A fine grain
  lab/wall       1 m     512 (albedo)  -                              Metal050A white enamel,
                                                                      Metal052C faint mottle
  lab/floor      1 m     512           -                              Road010A chips as a vinyl's
                                                                      fleck, Metal052C scuffs
  lab/steel      1 m     512           -                              Metal048C streaks (greyed),
                                                                      Metal052C scratches

Idempotent: textures/parts/.pbr and textures/lab/.pbr stamps (recipe hash, the sources' size
and time, and a hash of every file written, so a procedural regeneration over them is noticed
and baked again). numpy + Pillow.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_textures as IT  # noqa: E402
import base_pbr as BP  # noqa: E402
import gen_part_textures as GPT  # noqa: E402
from base_pbr import at_scale, bomb, flatten, height_nxy, lum  # noqa: E402

ROOT = IT.ROOT
PARTS = os.path.join(ROOT, "textures", "parts")
LAB = os.path.join(ROOT, "textures", "lab")

# the manifest's `use` for the sets baked here (tools/import_textures.py write_manifest)
USES = {
    "Metal052C": ["wave 3: part paint and alloy scratches (textures/parts paint, metal), lab floor and steel scuffs, "
                  "lab wall mottle"],
    "Metal048C": ["wave 3: part alloy, nozzle and foil (textures/parts metal, bell, foil), lab steel"],
    "Metal050A": ["wave 3: lab wall enamel (textures/lab/wall)"],
    "DiamondPlate008C": ["wave 3: part tread plate (textures/parts/tread)"],
    "Rock035": ["wave 3: thermal tile pores (textures/parts/tiles)"],
    "Rock063": ["wave 3: heat-shield char (textures/parts/ablative)"],
    "Road010A": ["wave 3: tyre grain (textures/parts/rubber), lab floor fleck"],
}
SOURCES = sorted(USES)


# ── the procedural structure ─────────────────────────────────────────────────

_PROC = {}


def _read(path):
    return np.asarray(Image.open(path).convert("RGB"), np.float32) / 255


def _up(a, shape):
    """A map at the albedo's size (the orm is often stored smaller): periodic Fourier resize."""
    if a.shape[:2] == shape:
        return a
    if shape[0] == shape[1] and a.shape[0] == a.shape[1]:
        return BP.fft_resize(a, shape[0]).astype(np.float32)
    chans = [a[..., i] for i in range(a.shape[2])] if a.ndim == 3 else [a]
    out = [np.asarray(Image.fromarray(c.astype(np.float32), "F").resize((shape[1], shape[0]), Image.BICUBIC)) for c in chans]
    return np.stack(out, 2) if a.ndim == 3 else out[0]


def proc(name):
    """The procedural generator's own maps for `name` (tools/gen_part_textures.py, written into a
    temporary folder): albedo (linear), normal xy, ao, rough, metal, all at the albedo's size."""
    if name not in _PROC:
        tmp = tempfile.mkdtemp(prefix="parts_pbr_")
        old = GPT.OUT
        try:
            GPT.OUT = tmp
            getattr(GPT, "gen_" + name)()
            alb = IT.srgb_to_lin(_read(os.path.join(tmp, name + "_albedo.png")))
            n = _read(os.path.join(tmp, name + "_normal.png")) * 2 - 1
            orm = _up(_read(os.path.join(tmp, name + "_orm.png")), alb.shape[:2])
        finally:
            GPT.OUT = old
            shutil.rmtree(tmp, ignore_errors=True)
        _PROC[name] = dict(alb=alb.astype(np.float32), nxy=_up(n[..., :2], alb.shape[:2]).astype(np.float32),
                           ao=orm[..., 0], rough=orm[..., 1], metal=orm[..., 2])
    return _PROC[name]


# ── helpers ──────────────────────────────────────────────────────────────────


def surface(sid, src_m, tile_m, N, rng, cells=3, seam=0.07, turns=True, flips=True):
    """A CC0 set at its real size (src_m metres across) inside an N px, tile_m metre tile,
    assembled from patches so no feature of it repeats inside the tile."""
    m = dict(BP.load(sid))
    if sid.startswith("Road"):
        m = BP.cut_lines(m)                    # a road set's painted lines out (tools/base_pbr.py)
    m = at_scale(m, src_m, tile_m, N)
    return bomb(m, N, rng, cells=cells, seam=seam, turns=turns, flips=flips)


def detail(L, N, frac=1 / 8, lo=0.5, hi=1.6):
    """A luminance's fine and middle detail as a ratio about 1 (its broad blotches divided out)."""
    L = np.maximum(L, 1e-4)
    return np.clip(L / np.maximum(IT.blur_wrap(L, N * frac), 1e-4), lo, hi)


def highpass(a, sigma):
    h = a - IT.blur_wrap(a, sigma)
    return h / (h.std() + 1e-6)


def fine(nxy, sigma):
    """A normal map's fine relief only (its broad tilts, a cliff's slopes in a rock set, taken out)."""
    return nxy - IT.blur_wrap(nxy, sigma)


def match(a, mean, lo=0.0, hi=1.0):
    """A map shifted to keep the procedural map's mean (the materials multiply it)."""
    return np.clip(a + (mean - a.mean()), lo, hi)


def grade(c, mean, sat):
    L = lum(c)[..., None]
    c = L + (c - L) * sat
    c = c * (np.array(mean, np.float32) / np.maximum(c.reshape(-1, 3).mean(0), 1e-5))
    return np.clip(c, 0, 1)


def save(root, name, alb_lin, nxy, ao=None, rough=None, metal=None, n_px=None, orm_px=None):
    """albedo (sRGB), normal (OpenGL) and orm, each at its stored size (non-square: bell)."""
    H, W = alb_lin.shape[:2]
    n_px = n_px or W
    orm_px = orm_px or W

    def sized(a, w):
        if a.shape[1] == w:
            return a
        if a.shape[0] == a.shape[1]:
            return BP.fft_resize(a, w)
        return _up(a, (a.shape[0] * w // a.shape[1], w))
    IT.save_png(IT.lin_to_srgb(np.clip(sized(alb_lin, W), 0, 1)), os.path.join(root, name + "_albedo.png"), "RGB")
    if nxy is not None:
        IT.save_png(BP.nrm_rgb(sized(nxy, n_px)), os.path.join(root, name + "_normal.png"), "RGB")
    if rough is not None:
        orm = np.stack([sized(ao, orm_px), sized(rough, orm_px), sized(metal, orm_px)], 2)
        IT.save_png(np.clip(orm, 0, 1), os.path.join(root, name + "_orm.png"), "RGB")
    print("  %-14s albedo %dx%d%s" % (os.path.relpath(os.path.join(root, name), os.path.join(ROOT, "textures")), W, H,
                                      "" if rough is None else ", orm %d" % orm_px))


# ── the parts ────────────────────────────────────────────────────────────────


def paint():
    """White-painted aluminium skin, 1 m tile: the procedural panels, rivets, hatches and
    grime, on Metal052C's painted plate (its mottle, scratches and specks at 1 m)."""
    N = 1024
    rng = np.random.default_rng(3101)
    P = proc("paint")
    s = surface("Metal052C", 1.0, 1.0, N, rng, cells=3, seam=0.08)
    Ls = lum(s["alb"])
    # the photo's fine wear only, softened: its dark specks at full strength read as filth on a
    # white skin (the 11-04 shots), so they are compressed toward the paint (worn, not dirty)
    d = detail(Ls, N, 1 / 16, 0.55, 1.35)
    d = np.where(d < 1, 1 - (1 - d) * 0.45, 1 + (d - 1) * 0.7)
    scratch = np.clip(highpass(s["rough"], 1.5), 0, 4) / 4            # the set's fine scratches (rough map)
    # the procedural grime and tone, softened a little: the photo carries the fine wear now
    Lp = lum(P["alb"])
    pk = (Lp / Lp.mean()) ** 0.85
    alb = P["alb"] / np.maximum(Lp, 1e-4)[..., None] * (Lp.mean() * pk)[..., None]
    alb = alb * d[..., None] * (1 + 0.10 * scratch)[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    rough = P["rough"] + (s["rough"] - s["rough"].mean()) * 0.9 - scratch * 0.06
    rough = match(rough, P["rough"].mean(), 0.12, 1.0)
    nxy = P["nxy"] + height_nxy(-scratch * 0.25 + highpass(Ls, 2.0) * 0.03, 1.0)
    ao = P["ao"] * (1 - 0.35 * (1 - s["ao"]))
    return alb, nxy, ao, rough, P["metal"]


def metal():
    """Brushed bare alloy, 0.5 m tile: the procedural seams, hex bolts and brush grain, with
    Metal048C's streaks and dark spots (greyed: the material tints it) and Metal052C's scratches."""
    N = 512
    rng = np.random.default_rng(3202)
    P = proc("metal")
    s = surface("Metal048C", 1.0, 0.5, N, rng, cells=3, seam=0.07, turns=False)   # streaks keep their direction
    k = surface("Metal052C", 1.0, 0.5, N, rng, cells=3, seam=0.07)
    d = detail(lum(s["alb"]), N, 1 / 6, 0.5, 1.4)
    d = np.where(d < 1, 1 - (1 - d) * 0.55, d)                  # its dark spots halved
    scratch = np.clip(highpass(k["rough"], 1.2), 0, 4) / 4
    alb = P["alb"] * d[..., None] * (1 + 0.18 * scratch)[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 0.0)
    rough = P["rough"] + (s["rough"] - s["rough"].mean()) * 1.2 - scratch * 0.10 + (k["rough"] - k["rough"].mean()) * 0.4
    rough = match(rough, P["rough"].mean(), 0.08, 1.0)
    nxy = P["nxy"] + height_nxy(-scratch * 0.3, 1.0)
    return alb, nxy, P["ao"], rough, P["metal"]


def tiles():
    """Black thermal-protection tiles, 0.5 m tile: the procedural 125 mm tiles and gap filler,
    the tiles' faces given a fired ceramic's pores and pits from Rock035 (basalt) at 0.6 m."""
    N = 512
    rng = np.random.default_rng(3303)
    P = proc("tiles")
    s = surface("Rock035", 0.6, 0.5, N, rng, cells=3, seam=0.07)
    g = highpass(lum(s["alb"]), 3.0)
    face = np.clip((lum(P["alb"]) < 0.05).astype(np.float32), 0, 1)        # the tiles, not the gap filler
    face = IT.blur_wrap(face, 0.7)
    alb = P["alb"] * (1 + face * np.clip(0.30 * g, -0.5, 0.8))[..., None]
    # scorch: the photo's broad dark patches as a faint soot over the faces
    soot = np.clip(-highpass(lum(s["alb"]), N / 12), 0, 3) / 3
    alb = alb * (1 - 0.25 * soot * face)[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    # (the sets' own normals, not their heights: an 8-bit height high-passed draws contour lines)
    nxy = P["nxy"] + fine(s["nxy"], 6) * 0.3 * face[..., None]
    rough = match(P["rough"] + 0.05 * g * face, P["rough"].mean(), 0.4, 1.0)
    ao = P["ao"] * (1 - 0.15 * face * (1 - s["ao"]))
    return alb, nxy, ao, rough, P["metal"]


def ablative():
    """The heat shield, honeycomb at 0.67 m: the procedural cells and char, the char broken up by
    Rock063's dark organic grain (burnt resin), its pits in the normal."""
    N = 512
    rng = np.random.default_rng(3404)
    P = proc("ablative")
    s = surface("Rock063", 0.8, 0.67, N, rng, cells=3, seam=0.07)
    d = detail(lum(s["alb"]), N, 1 / 8, 0.4, 1.8) ** 1.2
    alb = P["alb"] * d[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    nxy = P["nxy"] + fine(s["nxy"], 8) * 0.6
    rough = match(P["rough"] + (s["rough"] - s["rough"].mean()) * 0.5, P["rough"].mean(), 0.5, 1.0)
    return alb, nxy, P["ao"] * (0.85 + 0.15 * s["ao"]), rough, P["metal"]


def bell():
    """The nozzle (512 x 1024, u round it, v down it): the procedural tubes, heat-tint bands and
    soot, with Metal048C's streaks and spots (greyed) on the metal. The detail is a 512 tile laid
    twice down the bell (u wraps; v is not tiled)."""
    rng = np.random.default_rng(3505)
    P = proc("bell")
    s = surface("Metal048C", 0.6, 0.5, 512, rng, cells=3, seam=0.07, turns=False)
    d = detail(lum(s["alb"]), 512, 1 / 6, 0.5, 1.5) ** 0.8
    d = np.concatenate([d, d], 0)
    sr = np.concatenate([s["rough"], s["rough"]], 0)
    alb = P["alb"] * d[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    rough = match(P["rough"] + (sr - sr.mean()) * 1.0, P["rough"].mean(), 0.1, 1.0)
    return alb, P["nxy"], P["ao"], rough, P["metal"]


def foil():
    """Gold multi-layer insulation, 0.5 m: the procedural crinkles and tape seam, coloured by
    Metal048C (a worn gold metal: its hue drifts and its dark spots)."""
    N = 512
    rng = np.random.default_rng(3606)
    P = proc("foil")
    s = surface("Metal048C", 1.0, 0.5, N, rng, cells=3, seam=0.07)
    c = s["alb"]
    Lc = np.maximum(lum(c), 1e-4)
    hue = c / Lc[..., None]
    hue = hue / hue.reshape(-1, 3).mean(0)                     # the photo's hue drift about 1
    d = detail(Lc, N, 1 / 8, 0.5, 1.4)
    alb = P["alb"] * (0.6 + 0.4 * hue) * d[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    rough = match(P["rough"] + (s["rough"] - s["rough"].mean()) * 1.0, P["rough"].mean(), 0.05, 1.0)
    return alb, P["nxy"], P["ao"], rough, P["metal"]


def tread():
    """Diamond tread plate, 0.5 m: DiamondPlate008C whole (its lozenges about 45 mm apart, its own
    scuffs and dirt), greyed and matched to the old plate's brightness; its broad blotches flattened."""
    N = 512
    m = at_scale(BP.load("DiamondPlate008C"), 0.5, 0.5, N)
    old = proc("tread")
    alb = flatten(m["alb"], 1 / 4, 0.7)
    # the lozenges' tops polished bright by boots (the photo's own contrast between them is low:
    # at deck distance the plate read as grain, the 11-04 shots); its height map finds them
    h = m["h"] - IT.blur_wrap(m["h"], 12)
    top = np.clip(h / (np.percentile(h, 99) + 1e-6), 0, 1)
    alb = alb * (0.88 + 0.40 * top)[..., None]
    alb = grade(alb, old["alb"].reshape(-1, 3).mean(0), 0.3)
    rough = match(m["rough"] - 0.10 * top, old["rough"].mean(), 0.1, 1.0)
    metal = np.clip(m["metal"] * 1.1, 0, 1)
    return alb, m["nxy"] * 1.6, m["ao"] * (0.9 + 0.1 * top), rough, metal


def rubber():
    """Tyre rubber: the procedural chevrons, sipes and dust in the grooves, with Road010A's fine
    grain (the worn rubber's grit) in the albedo and the normal."""
    N = 512
    rng = np.random.default_rng(3707)
    P = proc("rubber")
    s = surface("Road010A", 0.5, 0.5, N, rng, cells=3, seam=0.07)
    g = highpass(lum(s["alb"]), 2.0)
    alb = P["alb"] * (1 + np.clip(0.22 * g, -0.4, 0.6))[..., None]
    alb = grade(alb, P["alb"].reshape(-1, 3).mean(0), 1.0)
    nxy = P["nxy"] + fine(s["nxy"], 4) * 0.35
    rough = match(P["rough"] + 0.04 * g, P["rough"].mean(), 0.4, 1.0)
    return alb, nxy, P["ao"], rough, P["metal"]


# ── the lab ──────────────────────────────────────────────────────────────────

LAB_MEAN = {"wall": (0.900, 0.900, 0.891), "floor": (0.784, 0.775, 0.757), "steel": (0.640, 0.640, 0.655)}


def lab_wall():
    """Satin white wall panels, 1 m (the material is albedo only): Metal050A's white enamel, its
    faint scratches, over a whisper of Metal052C's mottle. Pristine, not sterile."""
    N = 512
    rng = np.random.default_rng(3808)
    a = surface("Metal050A", 1.0, 1.0, N, rng, cells=3, seam=0.08)
    b = surface("Metal052C", 1.4, 1.0, N, rng, cells=3, seam=0.08)
    d = detail(lum(a["alb"]), N, 1 / 16, 0.9, 1.08) ** 1.5
    mot = detail(lum(b["alb"]), N, 1 / 6, 0.85, 1.15) ** 0.12
    scr = np.clip(highpass(a["rough"], 1.2), 0, 4) / 4
    v = d * mot * (1 - 0.03 * scr)
    alb = np.stack([v, v, v * 0.995], 2)
    return grade(alb, LAB_MEAN["wall"], 1.0), None, None, None, None


def lab_floor():
    """Sheet vinyl, 1 m: a light warm grey with a fleck (Road010A's stone chips at a fifth of
    their size), soft mottle, and scuffs where feet turn (Metal052C's scratches), satin."""
    N = 512
    rng = np.random.default_rng(3909)
    r = surface("Road010A", 6.0 * 0.16, 1.0, N, rng, cells=3, seam=0.06)
    k = surface("Metal052C", 1.2, 1.0, N, rng, cells=3, seam=0.08)
    g = highpass(lum(r["alb"]), 1.5)
    fleck = np.clip(np.abs(g) - 1.4, 0, 3) * np.sign(g)            # only the stand-out chips
    mot = highpass(lum(k["alb"]), N / 10) * 0.5
    scuff = np.clip(highpass(k["rough"], 1.5), 0, 4) / 4
    v = 0.90 * (1 + 0.10 * fleck + 0.012 * mot - 0.05 * scuff)
    alb = np.stack([v, v * 0.995, v * 0.985], 2)
    alb = grade(alb, LAB_MEAN["floor"], 1.0)
    # A sheet vinyl or epoxy floor gives a smooth, slightly soft sheen. Any relief or fine roughness
    # variation breaks the lamps' reflections into a speckled orange-peel (the 11-04 shots: first a
    # mottle in the normal, then the flecks and scuffs in the roughness), so the normal is flat and
    # the roughness holds a tight range round its mean: broad, soft wear and faint scuffs only.
    nxy = np.zeros((N, N, 2), np.float32)
    soft = IT.blur_wrap(mot, 6.0)
    soft = soft / (np.abs(soft).max() + 1e-6)
    rough = 0.30 + 0.012 * soft + 0.015 * IT.blur_wrap(scuff, 1.5)
    rough = match(rough, 0.301, 0.27, 0.33)
    return alb, nxy, np.ones_like(rough), rough, np.zeros_like(rough)


def lab_steel():
    """Brushed stainless, 1 m: Metal048C's streaks greyed (they run down the image, as the old
    brush did) and Metal052C's fine scratches; satin."""
    N = 512
    rng = np.random.default_rng(4010)
    s = surface("Metal048C", 1.0, 1.0, N, rng, cells=3, seam=0.07, turns=False, flips=True)
    k = surface("Metal052C", 1.0, 1.0, N, rng, cells=3, seam=0.07)
    # the brush: fine streaks down v
    col = rng.standard_normal((1, N))
    brush = IT.blur_wrap(np.repeat(col, N, 0), 0.7)
    brush = brush / (brush.std() + 1e-6)
    d = detail(lum(s["alb"]), N, 1 / 6, 0.6, 1.3)
    scr = np.clip(highpass(k["rough"], 1.2), 0, 4) / 4
    v = d * (1 + 0.04 * brush) * (1 + 0.12 * scr)
    alb = np.stack([v, v, v * 1.01], 2)
    alb = grade(alb, LAB_MEAN["steel"], 1.0)
    rough = 0.30 + (s["rough"] - s["rough"].mean()) * 0.8 + 0.04 * brush - 0.08 * scr
    rough = match(rough, 0.298, 0.08, 0.8)
    nxy = height_nxy(brush * 0.15 - scr * 0.3, 1.0)
    return alb, nxy, np.ones_like(rough), rough, np.ones_like(rough)


# ── main ─────────────────────────────────────────────────────────────────────

# (group, name, recipe, normal px, orm px): albedo sizes are the old ones (paint 1024, bell
# 512 x 1024, the rest 512); paint keeps its 512 orm, the lab wall has no other maps
PLAN = [
    ("parts", "paint", paint, 1024, 512),
    ("parts", "metal", metal, 512, 512),
    ("parts", "tiles", tiles, 512, 512),
    ("parts", "ablative", ablative, 512, 512),
    ("parts", "bell", bell, 512, 512),
    ("parts", "foil", foil, 512, 512),
    ("parts", "tread", tread, 512, 512),
    ("parts", "rubber", rubber, 512, 512),
    ("lab", "wall", lab_wall, None, None),
    ("lab", "floor", lab_floor, 512, 512),
    ("lab", "steel", lab_steel, 512, 512),
]
GROUP_DIR = {"parts": PARTS, "lab": LAB}


def outputs(group):
    out = []
    for g, name, fn, npx, opx in PLAN:
        if g == group:
            out.append(name + "_albedo.png")
            if npx:
                out += [name + "_normal.png", name + "_orm.png"]
    return out


def recipe_stamp():
    src = open(os.path.abspath(__file__), "rb").read()
    src += open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_part_textures.py"), "rb").read()
    s = BP.sets()
    info = [(sid, s[sid]["size"], s[sid]["mtime"]) for sid in SOURCES if sid in s]
    return hashlib.sha1(src + json.dumps(info).encode() + str(IT.IMPORTER_VERSION).encode()).hexdigest()[:16]


def file_hashes(group):
    d = GROUP_DIR[group]
    return {f: hashlib.sha1(open(os.path.join(d, f), "rb").read()).hexdigest()[:12] if os.path.exists(os.path.join(d, f))
            else None for f in outputs(group)}


def bake(force=False, only=None, groups=("parts", "lab")):
    if not os.path.isdir(IT.LIB_PATH[0]):
        print("parts_pbr: no texture library at %s: textures/parts and textures/lab left as they are" % IT.LIB_PATH[0])
        return
    for sid in SOURCES:
        if BP.sets().get(sid) is None or BP.sets()[sid]["licence"] != "CC0":
            raise SystemExit("parts_pbr: %s is not a CC0 set in the library (every output here is committed)" % sid)
    st = recipe_stamp()
    for group in groups:
        d = GROUP_DIR[group]
        sp = os.path.join(d, ".pbr")
        have = json.load(open(sp)) if os.path.exists(sp) else {}
        if not force and not only and have.get("recipe") == st and have.get("files") == file_hashes(group):
            print("parts_pbr: textures/%s up to date" % group)
            continue
        for g, name, fn, npx, opx in PLAN:
            if g != group or (only and name not in only):
                continue
            alb, nxy, ao, rough, metal = fn()
            save(d, name, alb, nxy, ao, rough, metal, npx, opx)
        json.dump({"recipe": st, "files": file_hashes(group)}, open(sp, "w"), indent=1)
        open(sp, "a").write("\n")


def sheet(outdir):
    """Before (the procedural generator) and after, albedo / normal / orm, one row a texture."""
    outdir = os.path.abspath(outdir)
    if os.path.realpath(outdir).startswith(os.path.realpath(ROOT) + os.sep):
        raise SystemExit("--sheet: write it outside the repo")
    os.makedirs(outdir, exist_ok=True)
    from PIL import ImageDraw
    T = 320
    rows = [(g, n) for g, n, *_ in PLAN]
    S = Image.new("RGB", (6 * T, len(rows) * T))
    dr = ImageDraw.Draw(S)
    for r, (g, n) in enumerate(rows):
        d = GROUP_DIR[g]
        for c, suf in enumerate(("_albedo", "_normal", "_orm")):
            p = os.path.join(d, n + suf + ".png")
            if os.path.exists(p):
                S.paste(Image.open(p).convert("RGB").resize((T, T)), ((c + 3) * T, r * T))
        if g == "parts":
            for c, key in enumerate(("alb", "nxy", "orm")):
                P = proc(n)
                if key == "alb":
                    a = IT.lin_to_srgb(P["alb"])
                elif key == "nxy":
                    a = BP.nrm_rgb(P["nxy"])
                else:
                    a = np.stack([P["ao"], P["rough"], P["metal"]], 2)
                S.paste(Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).resize((T, T)), (c * T, r * T))
        dr.text((4, r * T + 4), "%s/%s  procedural | realistic" % (g, n), fill=(255, 255, 0))
    S.save(os.path.join(outdir, "parts_pbr.png"))
    print("sheet", os.path.join(outdir, "parts_pbr.png"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--lib", default=IT.LIB)
    ap.add_argument("--sheet")
    a = ap.parse_args()
    IT.LIB_PATH[0] = a.lib
    if a.sheet:
        sheet(a.sheet)
        return
    bake(a.force, a.only)


if __name__ == "__main__":
    main()
