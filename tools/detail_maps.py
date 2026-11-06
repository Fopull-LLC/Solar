#!/usr/bin/env python3
"""DETAIL MAPS for every Solar surface that lacked them: normal, ORM and height, made from the
best source each one has (the maps pass of 2026-11-06).

    python3 tools/detail_maps.py              # bake everything below, then wire the prefabs
    python3 tools/detail_maps.py --only signs rope heights
    python3 tools/detail_maps.py --wire       # the prefab wiring alone (idempotent)
    python3 tools/detail_maps.py --audit FILE # the material audit table (markdown) into FILE
    python3 tools/detail_maps.py --sheet DIR  # contact sheets, outside the repo

WHERE EACH MAP COMES FROM, best source first:

  (a) REAL SOURCE DATA. A surface made from a CC0 photographic set (ambientCG, see
      textures/env/manifest.json) takes that set's own normal, roughness, AO and height:
      the lab wall (Metal050A, in tools/parts_pbr.py lab_wall) and the loose rocks
      (Rock051, below: `rock`).
  (b) THE GENERATOR'S OWN GEOMETRY. A drawn texture gets its height from the shapes that drew
      it, not from its colours: the sign atlases' plate rectangles come from the generators
      themselves (tools/base_tex.py, gen_vab.py, gen_lab.py are run into a temporary folder for
      their REGIONS table, the exact pixel rect of every plate, screen, stencil and board), the
      VAB tool board's holes from its drawing grid, the stencils on concrete from the concrete
      they were cut from (the same pixels, 1:1), the rope's braid from tools/gen_rope.py's own
      height field. The ink of a printed plate is its fg colour against its bg colour: an exact
      separation of two flat paints (the generator drew exactly two), not a guess.
  (c) The albedo, as a last resort, for nothing in this pass: every surface had (a) or (b).

  HEIGHT for the surfaces that already had a normal map (parts, base, lab, suit, skin) is the
  normal map INTEGRATED (Frankot-Chellappa, FFT, periodic for a tiling map): the height whose
  slopes are exactly the slopes the game already shades, so a parallax or displacement pass
  added later (engine stage 8) lines up with the lighting texel for texel.

PHYSICAL UNITS, SO NO SURFACE IS FLATTER THAN ITS NEIGHBOUR. Every new height is built in
millimetres at a stated texel size (mm a pixel), and its normal is that height's true slope:
`normal_strength: 1.0` means the real relief. textures/heights.json records each height map's
depth (mm from black to white) and texel size, for the engine's parallax scale.

THE ENGINE (0.117.1): a Material takes normal_map, roughness_map (G), metallic_map (B),
ao_map (R) and emissive_map; one ORM image feeds all three of the middle slots. Height and
parallax on regular materials are not in yet (stage 8) and there is no GPU compression
(stage 7), so the *_height.png files ship beside the maps, unbound, and cost no VRAM until then.

ROUGHNESS IS ABSOLUTE. As in every set baked by base_pbr.py and parts_pbr.py, an ORM's G is the
roughness itself and the material says `roughness: 1.0, metallic: 1.0`; the old constant (the
sign's 0.62, the stencil's 0.6) is now the map's value over the paint, so a wired material keeps
its mean and gains its variation.

Licensing: every source here is generated or CC0 (ambientCG), so every output is committed.
numpy + Pillow.
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_textures as IT  # noqa: E402

ROOT = IT.ROOT
TEX = os.path.join(ROOT, "textures")
HJSON = os.path.join(TEX, "heights.json")
TEXRON = os.path.join(ROOT, ".floptle", "textures.ron")


# ── maths ────────────────────────────────────────────────────────────────────


def read_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), np.float32) / 255


def read_rgba(path):
    return np.asarray(Image.open(path).convert("RGBA"), np.float32) / 255


def slopes_of_normal(path, strength=1.0):
    """A tangent-space normal map (OpenGL, the project's convention: tools/base_pbr.py height_nxy)
    as the height slopes it shades: p = dh/dcolumn, q = dh/drow, in texels per texel."""
    n = read_rgb(path) * 2 - 1
    nz = np.maximum(n[..., 2], 0.08)
    return -n[..., 0] / nz * strength, n[..., 1] / nz * strength


def integrate(p, q, periodic=True):
    """The least-squares height whose central-difference slopes are (p, q): Frankot-Chellappa in
    the Fourier domain. A map that does not tile is mirrored first (slopes flip sign with it)."""
    H, W = p.shape
    if not periodic:
        p = np.concatenate([p, -p[:, ::-1]], 1)
        p = np.concatenate([p, p[::-1, :]], 0)
        q = np.concatenate([q, q[:, ::-1]], 1)
        q = np.concatenate([q, -q[::-1, :]], 0)
    h, w = p.shape
    wx = 2 * np.pi * np.fft.fftfreq(w)[None, :]
    wy = 2 * np.pi * np.fft.fftfreq(h)[:, None]
    dx, dy = 1j * np.sin(wx), 1j * np.sin(wy)
    den = np.abs(dx) ** 2 + np.abs(dy) ** 2
    den[den < 1e-9] = 1e-9
    Z = (np.conj(dx) * np.fft.fft2(p) + np.conj(dy) * np.fft.fft2(q)) / den
    Z[0, 0] = 0
    z = np.real(np.fft.ifft2(Z))
    return z[:H, :W].astype(np.float32)


def grad(h, wrap=True):
    if wrap:
        return (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5, (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    gy, gx = np.gradient(h)
    return gx, gy


def normal_rgb(h_mm, texel_mm, wrap=True):
    """A height in millimetres at texel_mm a pixel → its true-slope OpenGL normal map (0..1)."""
    gx, gy = grad(h_mm / texel_mm, wrap)
    n = np.stack([-gx, gy, np.ones_like(h_mm)], 2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n * 0.5 + 0.5


def half_normal(n):
    """A normal map at half size: each channel reduced, then the vectors renormalised."""
    h, w = n.shape[:2]
    v = np.stack([resize_f(n[..., i] * 2 - 1, w // 2, h // 2) for i in range(3)], 2)
    v /= np.maximum(np.linalg.norm(v, axis=2, keepdims=True), 1e-6)
    return v * 0.5 + 0.5


def blur(a, sigma, wrap=True):
    if sigma <= 0:
        return a
    if wrap:
        return IT.blur_wrap(a, sigma).astype(np.float32)
    pad = int(sigma * 3) + 1
    b = np.pad(a, pad, mode="reflect")
    return IT.blur_wrap(b, sigma)[pad:-pad, pad:-pad].astype(np.float32)


def cavity_ao(h_mm, texel_mm, wrap=True, radii_mm=(1.5, 5.0, 15.0), k=0.5, floor=0.45):
    """Ambient occlusion from a height: how far each point sits below its neighbourhood, at three
    radii, each depth divided by its radius (a pit as deep as it is wide loses about half the sky)."""
    occ = np.zeros_like(h_mm)
    for r in radii_mm:
        s = max(r / texel_mm, 0.6)
        occ += np.clip(blur(h_mm, s, wrap) - h_mm, 0, None) / r
    return np.clip(1 - k * occ, floor, 1).astype(np.float32)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def noise(shape, rng, sigma):
    """Unit-variance band noise at a wavelength of about sigma pixels (tileable)."""
    n = blur(rng.standard_normal(shape).astype(np.float32), sigma)
    return n / (n.std() + 1e-6)


def resize_f(a, w, h):
    return np.asarray(Image.fromarray(a.astype(np.float32), "F").resize((w, h), Image.LANCZOS), np.float32)


# ── outputs ──────────────────────────────────────────────────────────────────

_HMETA = {}


def save_rgb(a, path):
    IT.save_png(np.clip(a, 0, 1), path, "RGB")


def save_orm(ao, rough, metal, path, size=None):
    orm = np.stack([ao, rough, metal], 2)
    if size and orm.shape[1] != size:
        h = orm.shape[0] * size // orm.shape[1]
        orm = np.stack([resize_f(orm[..., i], size, h) for i in range(3)], 2)
    save_rgb(orm, path)


def save_height(h_mm, path, texel_mm, method, size=None, tile_m=None):
    """8-bit height, black the lowest point and white the highest (0.1/99.9 percentiles, so one
    stray pit does not crush the rest); its depth and texel size go to textures/heights.json."""
    if size and h_mm.shape[1] != size:
        f = h_mm.shape[1] / size
        h_mm = resize_f(h_mm, size, h_mm.shape[0] * size // h_mm.shape[1])
        texel_mm *= f
    lo, hi = np.percentile(h_mm, 0.1), np.percentile(h_mm, 99.9)
    d = max(hi - lo, 1e-4)
    IT.save_png((h_mm - lo) / d, path, "L")
    rel = os.path.relpath(path, ROOT)
    _HMETA[rel] = {"depth_mm": round(float(d), 3), "texel_mm": round(float(texel_mm), 3), "method": method}
    if tile_m:
        _HMETA[rel]["tile_m"] = tile_m


def write_hjson():
    have = json.load(open(HJSON)) if os.path.exists(HJSON) else {}
    have.update(_HMETA)
    doc = {"_about": "Height maps beside the normal maps (tools/detail_maps.py). Black = lowest, white = highest; "
                     "depth_mm is the real relief between them, texel_mm the size of one pixel. Not bound to any "
                     "material yet: the engine's parallax for regular materials is stage 8."}
    doc.update({k: have[k] for k in sorted(have) if not k.startswith("_")})
    with open(HJSON, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")


def register_textures(paths):
    """Every new map filtered smooth and wrapping, as its albedo is (.floptle/textures.ron)."""
    text = open(TEXRON).read()
    want = []
    for p in paths:
        rel = os.path.relpath(p, ROOT)
        if '"%s"' % rel not in text:
            want.append('    "%s": (filter: SmoothMipmaps, wrap: Repeat),' % rel)
    if want:
        i = text.rstrip().rfind("}")
        text = text[:i].rstrip() + "\n" + "\n".join(want) + "\n}\n"
        open(TEXRON, "w").write(text)


WRITTEN = []


def out(path):
    WRITTEN.append(path)
    return path


# ── (1) heights of the maps that exist ───────────────────────────────────────

# normal map → (tile metres across its width, tiles?, material normal_strength); the tile sizes are
# the meshes' UV scales (tools/gen_part_meshes.py, base_models.py UVM, gen_lab.py, gen_suit.py)
EXISTING = {
    "parts/paint": (1.0, True, 1.0), "parts/metal": (0.5, True, 1.0), "parts/tiles": (0.5, True, 1.0),
    "parts/ablative": (0.67, True, 1.0), "parts/bell": (1.0, True, 1.0), "parts/foil": (0.5, True, 1.0),
    "parts/tread": (0.5, True, 1.0), "parts/rubber": (0.5, True, 1.0), "parts/solar": (1.0, True, 1.0),
    "parts/interior": (1.0, False, 1.0),
    "base/concrete": (4.0, True, 1.0), "base/asphalt": (4.0, True, 1.0), "base/cladding": (2.0, True, 1.2),
    "base/steel": (1.0, True, 1.0),
    "lab/wall": (1.0, True, 1.0), "lab/steel": (1.0, True, 0.5), "lab/cloth": (0.5, True, 1.0), "lab/knit": (0.25, True, 1.0),
    "suit/fabric": (0.25, True, 1.0), "suit/shell": (0.5, True, 0.7),
    "faces/skin": (0.25, False, 0.5),
    # the cabin interiors (tools/gen_iva.py: 1024 px a metre; the panel atlas does not tile)
    "../models/iva/tex/padding": (1.0, True, 1.0), "../models/iva/tex/cushion": (1.0, True, 1.0),
    "../models/iva/tex/strap": (0.5, True, 1.0), "../models/iva/tex/panel": (2.0, False, 0.6),
}


def existing_height(key):
    tile_m, tiles, strength = EXISTING[key]
    stem = os.path.join(TEX, key)
    npath = stem + "_normal.png"
    p, q = slopes_of_normal(npath, strength)
    h = integrate(p, q, tiles)                         # texels
    W = p.shape[1]
    texel_mm = tile_m * 1000 / W
    size = min(W, 512)
    save_height(h * texel_mm, out(stem + "_height.png"), texel_mm, "integrated from %s_normal.png x%.2g" %
                (os.path.basename(key), strength), size=size, tile_m=tile_m)
    return h * texel_mm, texel_mm


def heights():
    for key in EXISTING:
        if not os.path.exists(os.path.join(TEX, key + "_normal.png")):
            continue
        existing_height(key)
        print("  height %s" % key)


# ── (2) the sign atlases: plates, stencils, screens, boards ──────────────────

PLATE_TEXEL_MM = 2.0          # a 300 px plate is a 0.6 m sign


def atlas_regions():
    """Each sign atlas's region table, from its generator run into a temporary folder: name →
    (x0, y0, x1, y1) px. The layouts are checked against the committed atlases (same background)."""
    import base_tex
    import gen_lab
    import gen_vab
    t = tempfile.mkdtemp()
    try:
        shutil.copy(os.path.join(TEX, "base", "concrete_albedo.png"), t)
        res = {}
        jobs = (("base", lambda: base_tex.signs(), "", (base_tex, "OUT")),
                ("vab", lambda: gen_vab.signs(), "v_", (gen_vab, "TEXDIR")),
                ("lab", lambda: gen_lab.signs(), "l_", (gen_lab, "TEXDIR")))
        for name, fn, pre, (mod, attr) in jobs:
            base_tex.REGIONS.clear()
            old = getattr(mod, attr)
            setattr(mod, attr, t)
            try:
                fn()
            finally:
                setattr(mod, attr, old)
            ref = np.asarray(Image.open(os.path.join(TEX, name, "signs.png")).convert("RGB"))
            new = np.asarray(Image.open(os.path.join(t, "signs.png")).convert("RGB"))
            if ref.shape != new.shape or not np.array_equal((ref == 128).all(2), (new == 128).all(2)):
                raise SystemExit("detail_maps: the %s sign atlas's layout no longer matches its generator" % name)
            H, W = ref.shape[:2]
            regs = {}
            for k, (u0, v0, u1, v1) in base_tex.REGIONS.items():
                if not k.startswith(pre) or (not pre and (k.startswith("v_") or k.startswith("l_"))):
                    continue
                regs[k[len(pre):]] = (int(round(u0 * W - 0.5)), int(round(v0 * H - 0.5)),
                                      int(round(u1 * W + 0.5)), int(round(v1 * H + 0.5)))
            res[name] = regs
        return res
    finally:
        shutil.rmtree(t, ignore_errors=True)


def mode_colour(c):
    """The most common colour of a region (to 1/32 steps), refined to the mean of its members."""
    q = (c * 31 + 0.5).astype(np.int32)
    key = q[..., 0] * 1024 + q[..., 1] * 32 + q[..., 2]
    vals, cnt = np.unique(key, return_counts=True)
    k = vals[np.argmax(cnt)]
    m = key == k
    return c[m].mean(0)


def ink_of(c, bg):
    """How much of a two-paint plate is the second paint, 0..1: the colour's distance from the
    bg paint over the distance of the plate's far paint (its 97th percentile)."""
    d = np.linalg.norm(c - bg, axis=2)
    D = max(np.percentile(d, 97), 0.08)
    return smoothstep(0.30 * D, 0.65 * D, d)


def edge_dist(h, w):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return np.minimum(np.minimum(xx + 0.5, w - 0.5 - xx), np.minimum(yy + 0.5, h - 0.5 - yy))


_CONC = {}


def concrete_tile(h, w):
    """The base concrete's height (mm), roughness and AO laid from (0, 0) at 1:1, as
    tools/gen_vab.py _stencil_on_concrete and base_tex.deck_marking lay its albedo."""
    if not _CONC:
        hh, texel = existing_height("base/concrete")
        orm = read_rgb(os.path.join(TEX, "base", "concrete_orm.png"))
        N = hh.shape[0]
        rough = resize_f(orm[..., 1], N, N)
        _CONC.update(h=hh, r=rough, t=texel)
    reps = (h // _CONC["h"].shape[0] + 1, w // _CONC["h"].shape[1] + 1)
    return np.tile(_CONC["h"], reps)[:h, :w], np.tile(_CONC["r"], reps)[:h, :w]


def classify(atlas, name):
    if name.startswith(("s_", "wall_", "con_", "trade_")):
        return "screen"
    if name in ("whiteboard",):
        return "board"
    if name in ("periodic",):
        return "paper"
    if name.startswith("floor_") or name == "deck_lc1":
        return "stencil_concrete"
    if atlas == "vab" and name in ("yellow", "white", "green"):
        return "floor_paint"
    if name == "pegboard":
        return "pegboard"
    return "plate"


def region_maps(atlas, name, c, rng):
    """(height mm, roughness, metal) for one region of a sign atlas, from its class."""
    h, w = c.shape[:2]
    cls = classify(atlas, name)
    z = np.zeros((h, w), np.float32)
    if cls == "screen":
        # a display behind a glass cover: flat, glossy
        return z, np.full((h, w), 0.12, np.float32), z, cls
    if cls == "board":
        # a whiteboard's enamel: glossy, a faint ripple; the marker ink a little rougher
        ink = ink_of(c, mode_colour(c))
        return noise((h, w), rng, 6.0) * 0.004, 0.16 + 0.10 * ink, z, cls
    if cls == "paper":
        # a laminated poster: the paper's fibre under a satin laminate
        return noise((h, w), rng, 0.8) * 0.006 + noise((h, w), rng, 4.0) * 0.01, np.full((h, w), 0.5, np.float32), z, cls
    if cls in ("stencil_concrete", "floor_paint"):
        hc, rc = concrete_tile(h, w)
        if cls == "floor_paint":
            m = np.ones((h, w), np.float32)
        else:
            m = ink_of(c, mode_colour(c))
        # floor paint fills the finest pores and sits on them as a film (0.1 mm)
        fine = hc - blur(hc, 3.0, False)
        hh = hc - fine * 0.6 * m + 0.10 * blur(m, 0.6, False)
        r = rc * (1 - m) + m * np.clip(0.55 + 0.25 * (rc - rc.mean()), 0.4, 0.8)
        return hh, r, z, cls
    if cls == "pegboard":
        bg = mode_colour(c)
        hh = noise((h, w), rng, 1.0) * 0.01
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        # the holes, from the drawing grid (tools/gen_vab.py _pegboard: every 12 px from 6, r 1.5)
        dx = (xx - 6) - np.round((xx - 6) / 12) * 12
        dy = (yy - 6) - np.round((yy - 6) / 12) * 12
        hole = 1 - smoothstep(1.2, 2.2, np.sqrt(dx * dx + dy * dy))
        d = np.linalg.norm(c - bg, axis=2)
        # what hangs on the board (tools, the clipboard, outlines, the label) covers the holes behind it
        holecol = np.linalg.norm(c - np.array([70, 66, 58]) / 255, axis=2) < 0.08
        obj = (d > 0.12) & ~holecol
        hole = hole * (1 - smoothstep(0.02, 0.15, blur(obj.astype(np.float32), 1.5, False)))
        hung = smoothstep(0.10, 0.25, d) * (1 - hole) * (~holecol)
        # the tools on it stand off the board (about 8 mm, rounded in section); the painted outlines
        # and the label are a film; the holes go through (4 mm hardboard)
        lum = IT.lum(c)
        tool = hung * smoothstep(0.35, 0.5, lum)
        hh = hh - hole * 4.0 + blur(tool, 2.0, False) * 8.0 + hung * 0.05
        r = 0.78 - 0.38 * tool
        met = tool * smoothstep(0.5, 0.6, lum) * 0.8
        return hh, r.astype(np.float32), met.astype(np.float32), cls
    # a printed plate: enamelled sheet, the legend a screen-print film, a pressed edge
    bg = mode_colour(c)
    ink = ink_of(c, bg)
    ed = edge_dist(h, w)
    hh = 0.04 * blur(ink, 0.5, False)                       # ink film, 40 microns
    # orange peel, as strong as the painted plate beside it (base/steel, parts/paint: a median tilt of about
    # 1.3 to 1.6 degrees), so a sign does not read as a sticker flatter than the wall it is bolted to
    hh += noise((h, w), rng, 1.2) * 0.045 + noise((h, w), rng, 5.0) * 0.05
    hh -= 0.35 * (1 - smoothstep(0.0, 3.0, ed))             # the plate's rolled edge
    # the wear the generator laid (base_tex.wear: faded, grimy patches) reads as rougher paint
    L = IT.lum(c)
    dirt = np.clip((blur(L, 6.0, False) - L) * 4, -0.1, 0.1)
    # the enamel keeps the roughness its material had as a constant (base and VAB plates 0.62, the lab's 0.5)
    r = (0.5 if atlas == "lab" else 0.62) - 0.10 * ink + dirt
    return hh.astype(np.float32), r.astype(np.float32), z, cls


def signs():
    regs = atlas_regions()
    for atlas in ("base", "vab", "lab"):
        img = read_rgb(os.path.join(TEX, atlas, "signs.png"))
        H, W = img.shape[:2]
        texel = PLATE_TEXEL_MM * (0.75 if atlas == "lab" else 1.0)
        hm = np.zeros((H, W), np.float32)
        rough = np.full((H, W), 0.62, np.float32)
        metal = np.zeros((H, W), np.float32)
        rng = np.random.default_rng({"base": 6101, "vab": 6102, "lab": 6103}[atlas])
        counts = {}
        # the normal is made per region, so one plate's edge never tilts its neighbour's
        nrm = np.zeros((H, W, 3), np.float32) + (0.5, 0.5, 1.0)
        ao = np.ones((H, W), np.float32)
        for name, (x0, y0, x1, y1) in sorted(regs[atlas].items()):
            c = img[y0:y1, x0:x1]
            if c.size == 0:
                continue
            hh, r, m, cls = region_maps(atlas, name, c, rng)
            t = _CONC.get("t", 3.9) if cls in ("stencil_concrete", "floor_paint") else texel
            hm[y0:y1, x0:x1] = hh
            rough[y0:y1, x0:x1] = r
            metal[y0:y1, x0:x1] = m
            nrm[y0:y1, x0:x1] = normal_rgb(hh, t, wrap=False)
            ao[y0:y1, x0:x1] = cavity_ao(hh, t, wrap=False)
            counts[cls] = counts.get(cls, 0) + 1
        stem = os.path.join(TEX, atlas, "signs")
        # stored at half size, as the ORM is: the legends sit in the albedo, the relief is broad (a
        # plate edge, peel, a stencil on concrete), and a 2048 sign normal is 21 MiB of VRAM
        save_rgb(half_normal(nrm), out(stem + "_normal.png"))
        save_orm(ao, np.clip(rough, 0.05, 1), np.clip(metal, 0, 1), out(stem + "_orm.png"), size=W // 2)
        save_height(hm, out(stem + "_height.png"), texel, "plate regions from the generator; ink from the plate's two paints",
                    size=W // 2)
        print("  signs %s: %s" % (atlas, ", ".join("%s %d" % kv for kv in sorted(counts.items()))))


# ── (3) decal atlases (RGBA, cut out by alpha) ───────────────────────────────

_PAINT = {}


def paint_grain(h, w, rng):
    """The hull paint's own fine relief, as strong as it is on the paint itself: textures/parts/paint's
    height (its normal integrated) high-passed, its robust RMS measured away from the seams and rivets
    (the median absolute deviation), and a band noise of that RMS laid instead of the paint's pixels,
    because the paint's seams and rivets would not line up with a decal laid anywhere on a part."""
    if not _PAINT:
        hh, texel = existing_height("parts/paint")
        g = hh - blur(hh, 3.0)
        _PAINT["rms"] = float(np.median(np.abs(g - np.median(g))) * 1.4826)
    return noise((h, w), rng, 1.0) * _PAINT["rms"]


def decals(name, path, texel_mm, rough_ink, seed):
    """A sprayed or printed decal: alpha is the paint, a 50 micron film; worn edges (partial
    alpha) are thinner and rougher; under it, the hull paint's orange peel."""
    a = read_rgba(path)
    H, W = a.shape[:2]
    rng = np.random.default_rng(seed)
    al = a[..., 3]
    hh = 0.05 * blur(al, 0.5) + paint_grain(H, W, rng)
    worn = np.clip(al * (1 - al) * 4, 0, 1)
    rough = np.clip(rough_ink + 0.10 * worn + 0.03 * noise((H, W), rng, 3.0), 0.2, 1)
    stem = os.path.splitext(path)[0]
    save_rgb(normal_rgb(hh, texel_mm), out(stem + "_normal.png"))
    save_orm(cavity_ao(hh, texel_mm), rough, np.zeros_like(rough), out(stem + "_orm.png"), size=W // 2)
    save_height(hh, out(stem + "_height.png"), texel_mm, "decal alpha as a paint film over the hull paint's grain",
                size=W // 2)
    print("  decals %s" % name)


def suit_decals():
    """The suit's patches, name tape, cuff checklist, display and PLSS plate on the cloth: each
    element is a stitched-on patch or a printed plate (0.4 mm proud of the cloth, its edge
    stitched), the ground between them a plain patch cloth."""
    path = os.path.join(TEX, "suit", "decals.png")
    c = read_rgb(path)
    H, W = c.shape[:2]
    texel = 0.5
    rng = np.random.default_rng(6201)
    bg = mode_colour(c)
    d = np.linalg.norm(c - bg, axis=2)
    el = smoothstep(0.06, 0.14, blur(d, 1.5, False))             # the elements and their ground
    el = smoothstep(0.3, 0.6, blur(el, 2.0, False))
    # the ground between them is the patch cloth: a plain weave (fine grain, 0.03 mm), not the suit's
    # quilted outer fabric, whose diamonds are a 0.25 m pattern that has no place on a sewn patch
    weave = noise((H, W), rng, 0.6) * 0.03
    ink = ink_of(c, bg) * el
    hh = weave * (1 - 0.7 * el) + 0.4 * blur(el, 1.0, False) + 0.03 * ink + noise((H, W), rng, 0.8) * 0.01 * el
    L = IT.lum(c)
    screen = (el > 0.5) & (L < 0.12)
    rough = np.where(screen, 0.2, 0.88 - 0.08 * el).astype(np.float32)     # the old constant was 0.8
    stem = os.path.join(TEX, "suit", "decals")
    save_rgb(normal_rgb(hh, texel, wrap=False), out(stem + "_normal.png"))
    save_orm(cavity_ao(hh, texel, wrap=False), rough, np.zeros_like(rough), out(stem + "_orm.png"), size=W // 2)
    save_height(hh, out(stem + "_height.png"), texel, "elements from their ground colour; a plain-weave ground",
                size=W // 2)
    print("  decals suit")


# ── (4) the rope (tools/gen_rope.py's own braid) ─────────────────────────────


def rope():
    import gen_rope
    h, tracer = gen_rope.rope_height()
    H, W = h.shape
    texel = np.pi * 11.0 / W                       # an 11 mm static line, W px round it
    hh = h * 0.9                                    # strand relief, a little under a strand's radius
    rough = np.where(tracer, 0.9, 0.97) - 0.05 * h  # polyester sheath (the old 0.95), the crowns burnished
    stem = os.path.join(TEX, "items", "rope_static")
    save_orm(cavity_ao(hh, texel, radii_mm=(0.5, 1.5, 4.0), k=0.8), rough.astype(np.float32), np.zeros_like(hh),
             out(stem + "_orm.png"))
    save_height(hh, out(stem + "_height.png"), texel, "tools/gen_rope.py braid height")
    print("  rope")


# ── (5) loose rocks: a CC0 photographic rock (a) ─────────────────────────────

ROCK_SET = "Rock051"


def rock():
    """The loose rock and boulder props (models/tools/loose_rock.glb): Rock051's own albedo,
    normal, roughness, AO and displacement, graded to the granite colour the props wore
    (textures/env/terrain/14_granite.png, which stays the terrain's and is not touched)."""
    import base_pbr as BP
    BP.sets()
    if ROCK_SET not in BP.sets() or BP.sets()[ROCK_SET]["licence"] != "CC0":
        raise SystemExit("detail_maps: %s is not a CC0 set in the library" % ROCK_SET)
    m = BP.load(ROCK_SET)
    N = 512             # a 0.6 m rock: 1.2 mm a texel is past what a prop shows (VRAM: 1.3 MiB a map)
    m = {k: BP.fft_resize(v, N).astype(np.float32) for k, v in m.items()}
    gran = IT.srgb_to_lin(read_rgb(os.path.join(TEX, "env", "terrain", "14_granite.png")))
    mean = gran.reshape(-1, 3).mean(0)
    alb = BP.flatten(m["alb"], 1 / 6, 0.6)
    alb = BP.grade(alb, mean, 0.35)
    root = os.path.join(TEX, "props")
    os.makedirs(root, exist_ok=True)
    stem = os.path.join(root, "rock")
    IT.save_png(IT.lin_to_srgb(alb), out(stem + "_albedo.png"), "RGB")
    save_rgb(BP.nrm_rgb(m["nxy"]), out(stem + "_normal.png"))
    # dry rock is matte: the set's roughness (a wet-looking 0.57 on average) is held round the 0.92
    # the props had, keeping its variation (polished faces a little glossier)
    rr = np.clip(0.92 + (m["rough"] - m["rough"].mean()) * 0.6, 0.65, 1)
    save_orm(m["ao"], rr, np.zeros_like(m["ao"]), out(stem + "_orm.png"))
    # the set's displacement is 0..1 over its own relief; ambientCG's rock surfaces span about 2 m a
    # tile with some 12 cm of relief, here laid over the props' 0.625 m UV tile (gen_tools.py
    # loose_rock: uv = position x 1.6), so the relief scales with it to about 4 cm
    texel = 625.0 / N
    save_height(m["h"] * 38.0, out(stem + "_height.png"), texel, "%s displacement (CC0)" % ROCK_SET, tile_m=0.625)
    print("  rock (%s)" % ROCK_SET)


# ── the prefab wiring ────────────────────────────────────────────────────────

# texture → the maps it gains (normal, orm); every material block that draws the texture lit,
# without a normal map yet, is rewritten to bind them (roughness and metal become the maps')
WIRE = {
    "textures/vab/signs.png": "textures/vab/signs",
    "textures/base/signs.png": "textures/base/signs",
    "textures/lab/signs.png": "textures/lab/signs",
    "textures/parts/markings.png": "textures/parts/markings",
    "textures/tools/tool_decals.png": "textures/tools/tool_decals",
    "textures/suit/decals.png": "textures/suit/decals",
    "textures/lab/wall_albedo.png": "textures/lab/wall",
    "textures/suit/fabric_albedo.png": "textures/suit/fabric",
    "textures/env/terrain/14_granite.png": "textures/props/rock",
}
# blocks that bind some maps already and only miss others: texture → maps to add
COMPLETE = {
    "textures/lab/steel_albedo.png": "textures/lab/steel",
    "textures/lab/floor_albedo.png": "textures/lab/floor",
    "textures/items/rope_static_albedo.png": "textures/items/rope_static",
    "textures/parts/metal_albedo.png": "textures/parts/metal",
}


def wire_block(body, ind):
    """A material block's lines → the same block with the maps bound, or None to leave it."""
    m = re.search(r'^(\s*)texture: Some\("([^"]+)"\),\n', body, re.M)
    if not m or re.search(r"^\s*unlit: true", body, re.M):
        return None
    tex = m.group(2)
    sp = m.group(1)
    if tex in WIRE and "normal_map:" not in body:
        stem = WIRE[tex]
        rough = re.search(r"^\s*roughness: [^\n]*\n", body, re.M)
        metal = re.search(r"^\s*metallic: [^\n]*\n", body, re.M)
        body2 = body
        for mm in (metal, rough):
            if mm:
                body2 = body2.replace(mm.group(0), "", 1)
        maps = (f'{sp}normal_map: Some("{stem}_normal.png"),\n'
                f'{sp}normal_strength: 1.0,\n'
                f'{sp}roughness_map: Some("{stem}_orm.png"),\n'
                f'{sp}roughness: 1.0,\n'
                f'{sp}metallic_map: Some("{stem}_orm.png"),\n'
                f'{sp}metallic: 1.0,\n'
                f'{sp}ao_map: Some("{stem}_orm.png"),\n')
        if "shading: Physical" not in body2:
            maps += f"{sp}shading: Physical,\n"
        tex_line = m.group(0)
        if stem == "textures/props/rock":
            tex_line = tex_line.replace(tex, "textures/props/rock_albedo.png")
            body2 = re.sub(r"^(\s*)color: \([^)]*\),", r"\1color: (1.0, 1.0, 1.0),", body2, count=1, flags=re.M)
        return body2.replace(m.group(0), tex_line + maps, 1)
    if tex in COMPLETE:
        stem = COMPLETE[tex]
        orm = f'Some("{stem}_orm.png")'
        add = []
        if "roughness_map:" not in body and os.path.exists(os.path.join(ROOT, stem + "_orm.png")):
            add.append(("roughness_map", orm))
        if "metallic_map:" not in body and os.path.exists(os.path.join(ROOT, stem + "_orm.png")):
            add.append(("metallic_map", orm))
        if "ao_map:" not in body and os.path.exists(os.path.join(ROOT, stem + "_orm.png")):
            add.append(("ao_map", orm))
        if not add:
            return None
        if any(k == "metallic_map" for k, _ in add):
            # the ORM's B is the metal itself (0 or 1 a texel): the material's constant becomes its
            # scale, which for these sets is what it was (lab steel 0.85, the floor's and rope's 0)
            pass
        if any(k == "roughness_map" for k, _ in add):
            body = re.sub(r"^(\s*)roughness: [^\n]*\n", r"\1roughness: 1.0,\n", body, count=1, flags=re.M)
        lines = "".join(f"{sp}{k}: {v},\n" for k, v in add)
        last = list(re.finditer(r"^\s*(normal_map|normal_strength|roughness_map|roughness|metallic_map|metallic): [^\n]*\n",
                                body, re.M))
        at = last[-1].end() if last else m.end()
        return body[:at] + lines + body[at:]
    return None


def wire_text(text):
    lines = text.split("\n")
    outl, i, n = [], 0, 0
    while i < len(lines):
        ln = lines[i]
        mm = re.match(r'^(\s*)(?:"[^"]+": \(|material: Some\(\()\s*$', ln)
        if mm:
            ind = len(mm.group(1))
            j = i + 1
            while j < len(lines) and not re.match(r"^\s{%d}\)" % ind, lines[j]):
                j += 1
            body = "\n".join(lines[i + 1:j]) + "\n"
            nb = wire_block(body, ind)
            if nb is not None and nb != body:
                outl.append(ln)
                outl.extend(nb.rstrip("\n").split("\n"))
                n += 1
                i = j
                continue
        outl.append(ln)
        i += 1
    return "\n".join(outl), n


def wire():
    tot = 0
    files = [os.path.join(r, f) for d in ("prefabs", "scenes") for r, _, ff in os.walk(os.path.join(ROOT, d))
             for f in ff if f.endswith(".ron")]
    for p in sorted(files):
        if True:
            t = open(p).read()
            nt, n = wire_text(t)
            if n:
                open(p, "w").write(nt)
                tot += n
    print("wired %d material blocks" % tot)


# ── main ─────────────────────────────────────────────────────────────────────

JOBS = {
    "heights": heights,
    "signs": signs,
    "markings": lambda: decals("parts/markings", os.path.join(TEX, "parts", "markings.png"), 1.0, 0.58, 6301),
    "tooldecals": lambda: decals("tools/tool_decals", os.path.join(TEX, "tools", "tool_decals.png"), 0.6, 0.6, 6302),
    "suitdecals": suit_decals,
    "rope": rope,
    "rock": rock,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--wire", action="store_true")
    ap.add_argument("--audit")
    ap.add_argument("--sheet")
    a = ap.parse_args()
    if a.audit:
        import pbr_audit
        pbr_audit.write(a.audit)
        return
    if a.wire:
        wire()
        return
    for k, fn in JOBS.items():
        if a.only and k not in a.only:
            continue
        fn()
    write_hjson()
    register_textures([p for p in WRITTEN if not p.endswith("_height.png")] +
                      [p for p in WRITTEN if p.endswith("_height.png")])
    if not a.only:
        wire()


if __name__ == "__main__":
    main()
