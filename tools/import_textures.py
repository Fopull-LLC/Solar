#!/usr/bin/env python3
"""Import the realistic environment texture library into Solar.

    python3 tools/import_textures.py              # convert what changed, write palettes + manifest
    python3 tools/import_textures.py --dry        # say what it would do, write nothing
    python3 tools/import_textures.py --force      # convert everything again
    python3 tools/import_textures.py --only Rock035 Ground039
    python3 tools/import_textures.py --sheet DIR  # contact sheets (terrain layers, sets) into DIR
    python3 tools/import_textures.py --stage DIR  # make a project copy at DIR use the local sets:
                                                  # copy textures/env_local in, point the terrain
                                                  # palettes' slots at their local versions
    python3 tools/import_textures.py --lib PATH   # another library folder
    python3 tools/import_textures.py --means --write  # far_bodies.lua's PAL (each layer's mean
                                                  # colour) from the committed layers

THE LIBRARY (LIB below, read only; never written): 73 items in four formats.
  ambientCG    `Name###_2K-PNG.zip`: _Color _NormalGL/_NormalDX _Roughness
               _AmbientOcclusion _Displacement [_Metalness _Opacity]   CC0
  Substance    `*_PbrGenericMetallic2kBitmap.zip`: basecolor normal roughness
               metallic height ambientocclusion opacity emissive       commercial
  older sets   `_DIFF _DISP _SPEC [_NRM _OCC _RGH _MTL _ALBEDO]`, or
               `_albedo _normal _roughness _height`                    commercial
  loose PNGs   colour only                                             commercial
A zip's name can carry the user's note after the set name ("... Use as maybe
the star geode replacement mat"); it is kept in the manifest.

LICENSING (the user's hard rule; the repo is public): CC0 output goes to
textures/env/ (committed). Commercial output goes to textures/env_local/,
which .gitignore keeps out of git: no pixel of a commercial set may enter the
repo, previews and contact sheets included (--sheet refuses a folder inside
the repo). The committed terrain palettes only ever name committed files, so a
clean checkout runs without the local folder; `--stage` puts the local
versions into a build (tools/perf/exportcheck.sh does it).

WHAT EACH SET BECOMES (textures/env{,_local}/sets/<id>/), the engine's material
conventions (floptle-core material.rs, raster.wgsl):
  albedo.png   sRGB colour (RGBA where the set has an opacity map)
  normal.png   tangent-space, OpenGL (+Y up; the engine's positive
               normal_strength). DirectX sources get green flipped; a source
               that does not say is tested against its own height map.
  orm.png      glTF packing: R occlusion, G roughness, B metallic: the engine
               reads ao_map .r, roughness_map .g, metallic_map .b, so the one
               file goes in all three slots.
  height.png   8-bit height, normalised, where the set has one.
Older sets have no roughness: it comes from the specular map (1 - spec),
else a constant by kind. No AO map: one is worked out from the height.

THE TERRAIN (textures/env{,_local}/terrain/, TERRAIN below). The engine's
terrain palette (terrain/<scene>.palette) is 32 slots of ONE 256x256 sRGB
albedo layer each, one mip level, projected triplanar and multiplied by the
voxel's tint x 1.6 (floptle-render raster.wgsl `terrain_triplanar`,
raymarch.rs TERRAIN_TEX_SIZE). It has no normal, roughness or AO channel, so
each layer is baked here: the set's albedo, darkened by its AO and by how far
its normal map tilts from the surface (cavities and the sides of grains read
darker, from any light direction), its broad light-and-dark blotches flattened
(the thing that makes a photo's tile repeat visibly across a hillside), graded
for the slot, and reduced to 256 in linear light. Slot numbers are what
mining reads (materials.lua SLOT), so each slot keeps its geology.

Idempotent: each output folder holds a `.import` stamp (the source's size and
time, the recipe, this file's IMPORTER_VERSION); a set whose stamp matches is
skipped. Uses numpy + Pillow only.
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import zipfile
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image

IMPORTER_VERSION = 4
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = "/mnt/disks/3tb/Art+Assets/AAA_TEXTURES/gametexturesdotcom"
OUT_CC0 = "textures/env"            # committed
OUT_LOCAL = "textures/env_local"    # git-ignored
MANIFEST = "textures/env/manifest.json"
LAYER = 256                         # the engine's terrain palette layer size

Image.MAX_IMAGE_PIXELS = 20000 * 20000

# ── what each set is ─────────────────────────────────────────────────────────
# kind: what it is for. The resolution of the stored maps follows it and the
# licence (CC0 output is committed, so it is kept small until a wave uses it;
# re-run with a bigger RES entry when one does).
KINDS = [
    (r"^(Rock|Rocks|Old_Rocks|Mossy_Rock|Rock_Wall|Stone_01|MarsSmoothRock|Onyx)", "rock"),
    (r"^(Ground|Dirt|Dirty_Grass|Grass|FineClumpySand|MossAndSmallFerns|White_Stones|Potato)", "ground"),
    (r"^Snow", "snow"),
    (r"^(Metal|DiamondPlate|Diamond_Plate|Galvanized|AgedPolishedCopper|MetalCrate)", "metal"),
    (r"^(Concrete|Dirty_Concrete|New_Concrete)", "concrete"),
    (r"^(Road|Cracked_Asphalt|Red_Asphalt|Regular_Pavement|Stone_Pavement)", "road"),
    (r"^(Wood|Basic_Wood|Damaged_Wood|Olive_Wood|Old_Wood)", "wood"),
    (r"^(Bark|OrangePineTreeBark)", "bark"),
    (r"^(LeafSet|DeadLeafBranches)", "foliage"),
    (r"^(SpaceLab|SpaceStation|bolted|maintenance|worn-safety)", "scifi"),
    (r"^(ChristmasTreeOrnament)", "crystal"),
    (r"^(Generated_Checker)", "pattern"),
]
RES = {  # (cc0, local) stored size of the full maps, by kind
    "rock": (512, 1024), "ground": (512, 1024), "snow": (512, 1024), "crystal": (512, 1024),
    "metal": (512, 1024), "concrete": (512, 1024), "road": (512, 1024), "wood": (512, 1024),
    "bark": (512, 1024), "foliage": (512, 1024), "scifi": (512, 1024), "pattern": (512, 512),
}
ROUGH_DEFAULT = {"rock": 0.85, "ground": 0.92, "snow": 0.7, "metal": 0.45, "concrete": 0.85, "road": 0.9,
                 "wood": 0.75, "bark": 0.9, "foliage": 0.7, "scifi": 0.6, "crystal": 0.15, "pattern": 0.6}
METAL_DEFAULT = {"metal": 1.0}

# Where each set is meant to go next (the manifest's `use` for sets no terrain
# slot takes yet): the plan for the later waves.
PLANNED = {
    "metal": "wave 3: vehicle parts, hangar and VAB metal (replace textures/parts, textures/hangar, textures/vab)",
    "concrete": "wave 2: base pads, foundations and buildings (replace textures/base concrete)",
    "road": "wave 2: base roads and pads (replace textures/base asphalt)",
    "wood": "wave 4: crates, props and felled-log ends",
    "bark": "wave 4: tree bark (replace textures/flora bark_*)",
    "foliage": "wave 4: leaf cards (replace textures/flora foliage_*)",
    "scifi": "wave 3: lab, hangar and station interiors (textures/lab, textures/hangar)",
    "pattern": "test pattern only (scale checks)",
    "rock": "terrain variety reserve: later palettes, boulders and cave props",
    "ground": "terrain variety reserve: later palettes and ground decals",
    "snow": "terrain variety reserve",
    "crystal": "terrain glow slots (resonant crystal / Star Geode)",
}

# ── the terrain palette: 32 slots (terrain/system.palette) ────────────────────
# Slot n here is palette line n: the numbers are what mining reads (materials.lua
# SLOT, VEIN_SLOTS), what the planet generator lays (system_generator.lua
# GEO_SLOT) and what saves have painted, so each keeps its geology.
#   cc0 / local   (set id, grade); the local one is used by `--stage` builds when
#                 textures/env_local has it, the cc0 one everywhere else
#   grade         see grade(): sat, tint (linear rgb, luminance kept), gain,
#                 contrast, flatten (0..1 of the broad blotches removed),
#                 ao / cav (how strongly the AO and the normal's tilt darken)
#   scale         the palette's |scale= (4.5 m / scale per tile)
#   blend, rough  the palette's edge blend width (m) and its noise
#   glow          a self-lit slot (the cave-visibility channel)
#   make          a special recipe instead of the plain bake
G = dict  # shorthand
TERRAIN = [
    # 1–12: the original set (6–8 glow). Names kept: generator and saves use the numbers.
    dict(slot=1, name="rust", was="planet_rust_rock", mat="rustrock", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rocks011", G(sat=1.2, tint=(1.0, 0.42, 0.26), contrast=1.15)),
         local=("MarsSmoothRock", G(sat=0.75, tint=(1.0, 0.7, 0.58)))),
    dict(slot=2, name="soil", was="planet_purple_dirt", mat="soil", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Ground039", G())),
    dict(slot=3, name="flagstone", was="planet_purple_slate", mat="slate", scale=1.4, blend=0.8, rough=0.7,
         cc0=("Rocks011", G(sat=0.6, gain=1.6, contrast=1.15)), local=("Old_Rocks", G(sat=0.7))),
    dict(slot=4, name="onyx", was="planet_banded_onyx", mat="onyx", scale=1.2, blend=0.8, rough=0.7,
         cc0=("Onyx006", G(sat=0.85, flatten=0.0))),
    dict(slot=5, name="veinstone", was="cave_orange_veinstone", mat="veinstone", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rock058", G(make="veins", vein=(1.0, 0.45, 0.16), veinGain=3.5, base=1.5))),
    dict(slot=6, name="magma", was="cave_magma_veins", mat="uranium", scale=1.4, glow=True,
         cc0=("Rock058", G(make="magma"))),
    dict(slot=7, name="amethyst", was="cave_amethyst", mat="crystal", scale=1.3, glow=True,
         cc0=("ChristmasTreeOrnament021", G(make="crystal", tint=(0.62, 0.38, 1.0)))),
    dict(slot=8, name="bluecrystal", was="cave_blue_crystal", mat="crystal", scale=1.3, glow=True,
         cc0=("ChristmasTreeOrnament021", G(make="crystal", tint=(0.30, 0.62, 1.0)))),
    dict(slot=9, name="slate", was="moon_silver_slate", mat="slate", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rock058", G(sat=0.15, gain=2.0, contrast=1.1)), local=("Rock_Wall", G(sat=0.5))),
    dict(slot=10, name="gravelregolith", was="moon_gray_regolith", mat="regolith", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Ground110", G(sat=0.12, gain=0.9))),
    dict(slot=11, name="dust", was="moon_crater_dust", mat="regolith", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Ground093B", G(sat=0.25, contrast=1.6, flatten=0.3))),
    dict(slot=12, name="bandedice", was="moon_teal_ice", mat="ice", scale=1.2, blend=0.8, rough=0.7,
         cc0=("Onyx006", G(sat=0.25, tint=(0.75, 0.95, 1.0), gain=1.9, contrast=0.6))),
    # 13–32: the geology set.
    dict(slot=13, name="basalt", was="geo_basalt", mat="basalt", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock035", G(sat=0.25, gain=5.0, contrast=0.9))),
    dict(slot=14, name="granite", was="geo_granite", mat="granite", scale=1.8, blend=0.8, rough=0.7,
         cc0=("Rock060", G(sat=0.7, gain=1.8, contrast=1.15)), local=("Rock_05", G())),
    dict(slot=15, name="sandstone", was="geo_sandstone", mat="sandstone", scale=1.0, blend=0.8, rough=0.7,
         cc0=("Onyx010", G(sat=0.55, tint=(1.0, 0.78, 0.55), contrast=0.75)), local=("Mossy_Rock", G(contrast=1.1))),
    dict(slot=16, name="sand", was="geo_sand", mat="sand", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Ground093B", G(contrast=1.4, flatten=0.3, ripples=dict(count=16, amp=0.16)))),
    dict(slot=17, name="regolith", was="geo_regolith", mat="regolith", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Ground039", G(sat=0.2, contrast=1.1))),
    dict(slot=18, name="salt", was="geo_salt", mat="salt", scale=1.2, blend=1.2, rough=0.7,
         cc0=("Snow014", G(sat=0.0, tint=(1.0, 0.97, 0.9), gain=0.92, contrast=1.4)),
         local=("Cracked_Asphalt", G(sat=0.15, tint=(1.0, 0.97, 0.92), gain=2.3, contrast=0.7))),
    dict(slot=19, name="mudcrack", was="geo_mudcrack", mat="clay", scale=1.6, blend=1.2, rough=0.7,
         cc0=("Ground039", G(sat=0.8, tint=(1.0, 0.8, 0.6), gain=1.15, contrast=1.2)),
         local=("MarsSmoothRock", G(sat=0.6, gain=1.15))),
    dict(slot=20, name="moss", was="geo_moss", mat="soil", scale=1.8, blend=1.2, rough=0.7,
         cc0=("Ground037", G()), local=("MossAndSmallFerns", G(contrast=1.15))),
    dict(slot=21, name="ash", was="geo_ash", mat="ash", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Ground110", G(sat=0.2, gain=0.6, contrast=1.1))),
    dict(slot=22, name="snow", was="geo_snow", mat="ice", scale=1.8, blend=1.2, rough=0.7,
         cc0=("Snow014", G(contrast=1.3))),
    dict(slot=23, name="glacier", was="geo_glacier", mat="ice", scale=1.0, blend=0.8, rough=0.7,
         cc0=("Snow008A", G(sat=1.0, tint=(0.82, 0.93, 1.0), gain=0.6, contrast=3.0, flatten=0.0))),
    dict(slot=24, name="scree", was="geo_scree", mat="gravel", scale=1.8, blend=1.2, rough=0.7,
         cc0=("Ground110", G(sat=0.7))),
    dict(slot=25, name="limestone", was="geo_limestone", mat="limestone", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock051", G(sat=0.45, gain=1.6)), local=("Rock_04", G(sat=0.6))),
    dict(slot=26, name="sulfur", was="geo_sulfur", mat="sulfur", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rocks011", G(sat=1.4, tint=(1.0, 0.85, 0.22), gain=1.3, contrast=1.2)),
         local=("Potato", G(sat=0.75, tint=(1.0, 0.92, 0.45), gain=0.85, contrast=1.3))),
    dict(slot=27, name="hematite", was="geo_hematite", mat="hematite", scale=2.0, blend=0.8, rough=0.7,
         cc0=("Ground085", G(sat=1.2, tint=(1.0, 0.5, 0.35)))),
    dict(slot=28, name="tundra", was="geo_tundra", mat="soil", scale=1.6, blend=1.2, rough=0.7,
         cc0=("Grass004", G(make="patchy", sat=0.55, tint=(1.0, 0.92, 0.7), contrast=1.2,
                            under=("Ground039", G(sat=0.45, tint=(1.0, 0.9, 0.75), gain=0.85)), cover=0.68)),
         local=("Dirty_Grass", G(sat=0.6))),
    dict(slot=29, name="pahoehoe", was="geo_pahoehoe", mat="basalt", scale=1.25, blend=0.8, rough=0.7,
         cc0=("Rock058", G(sat=0.3, gain=0.6, contrast=1.3))),
    dict(slot=30, name="shale", was="geo_shale", mat="shale", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock051", G(sat=0.15, gain=0.95, contrast=1.2)), local=("Rock_03", G())),
    dict(slot=31, name="peat", was="geo_peat", mat="soil", scale=1.4, blend=1.2, rough=0.7,
         cc0=("Rock063", G(sat=0.7, gain=0.55))),
    dict(slot=32, name="litter", was="geo_litter", mat="soil", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Grass004", G(make="patchy", sat=0.85, gain=0.8, contrast=1.15,
                            under=("Ground085", G(sat=0.8, gain=0.85)), cover=0.5))),
]
# planetoid.palette: the first 12 slots (the legacy archetype scene).
PLANETOID_SLOTS = 12

# ── small image helpers ──────────────────────────────────────────────────────


def srgb_to_lin(a):
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(a):
    a = np.clip(a, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)


def to_float(im):
    """PIL image → float32 array in 0..1 (H, W[, C]); 16-bit aware."""
    if im.mode in ("I;16", "I;16B", "I;16L", "I"):
        a = np.asarray(im, dtype=np.float32)
        return a / (65535.0 if a.max() > 255 else 255.0)
    if im.mode == "F":
        a = np.asarray(im, dtype=np.float32)
        return (a - a.min()) / max(1e-6, a.max() - a.min())
    if im.mode == "P":
        im = im.convert("RGBA")
    if im.mode == "LA":
        im = im.convert("L")
    if im.mode == "CMYK":
        im = im.convert("RGB")
    return np.asarray(im, dtype=np.float32) / 255.0


def gray(a):
    return a if a.ndim == 2 else a[..., :3].mean(axis=2) if a.shape[2] >= 3 else a[..., 0]


def resize(a, size, linear=False):
    """Resize a float image to size x size (Lanczos, per channel; `linear` = sRGB data,
    reduced in linear light)."""
    if a.shape[0] == size and a.shape[1] == size:
        return a
    x = srgb_to_lin(a) if linear else a
    chans = [x] if x.ndim == 2 else [x[..., i] for i in range(x.shape[2])]
    out = [np.asarray(Image.fromarray(c.astype(np.float32), "F").resize((size, size), Image.LANCZOS)) for c in chans]
    r = out[0] if x.ndim == 2 else np.stack(out, axis=2)
    return lin_to_srgb(r) if linear else np.clip(r, 0, 1)


def squarify(a):
    """A tileable non-square map made square by repeating its short side (keeps the
    aspect and the tiling: Rock063 is 2:1)."""
    h, w = a.shape[:2]
    if h == w:
        return a
    if w > h and w % h == 0:
        return np.concatenate([a] * (w // h), axis=0)
    if h > w and h % w == 0:
        return np.concatenate([a] * (h // w), axis=1)
    s = min(h, w)
    return a[:s, :s]


def blur_wrap(a, sigma):
    """Gaussian blur on a torus (FFT), so a tileable map stays tileable."""
    h, w = a.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    k = np.exp(-2 * (np.pi ** 2) * (sigma ** 2) * (fx * fx + fy * fy))
    if a.ndim == 2:
        return np.real(np.fft.ifft2(np.fft.fft2(a) * k))
    return np.stack([np.real(np.fft.ifft2(np.fft.fft2(a[..., i]) * k)) for i in range(a.shape[2])], axis=2)


def save_png(a, path, mode):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    u8 = (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(u8, mode).save(path, optimize=True)


def lum(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


# ── the library ──────────────────────────────────────────────────────────────
MAPS = [  # (map, regex on the member's file name, case-insensitive), first match wins
    ("color", r"(_Color|_basecolor|_ALBEDO|_albedo)\.(png|jpe?g)$"),
    ("diff", r"_DIFF\.(png|jpe?g)$"),
    ("normal_gl", r"_NormalGL\.png$"),
    ("normal_dx", r"_NormalDX\.png$"),
    ("normal", r"(_normal|_NRM|_NRML)\.(png|jpe?g)$"),
    ("rough", r"(_Roughness|_RGH)\.(png|jpe?g)$"),
    ("spec", r"_SPEC\.(png|jpe?g)$"),
    ("metal", r"(_Metalness|_metallic|_MTL)\.(png|jpe?g)$"),
    ("ao", r"(_AmbientOcclusion|_ambientocclusion|_OCC)\.(png|jpe?g)$"),
    ("height", r"(_Displacement|_height|_DISP|_Height)\.(png|jpe?g)$"),
    ("opacity", r"_opacity\.png$|_Opacity\.png$"),
    ("emissive", r"_emissive\.png$"),
]


def set_id(item):
    base = item[:-4] if item.lower().endswith((".zip", ".png")) else item
    note = ""
    m = re.match(r"^(\S+?)(_2K-PNG|_PbrGenericMetallic2kBitmap)?( .*)?$", base)
    if m and m.group(3) and m.group(2):
        note = m.group(3).strip()
    sid = (m.group(1) if m else base)
    if not m or not m.group(2):
        sid = base  # older sets keep their whole name ("Galvanized Metal")
    sid = re.sub(r"[^A-Za-z0-9_-]+", "_", sid).strip("_")
    return sid, note


def licence_of(item):
    return "CC0" if re.search(r"_2K-PNG", item) else "commercial"


def fmt_of(item):
    if re.search(r"_2K-PNG", item):
        return "ambientCG"
    if "PbrGenericMetallic" in item:
        return "substance"
    if item.lower().endswith(".png"):
        return "loose"
    return "older"


def kind_of(sid):
    for rx, k in KINDS:
        if re.match(rx, sid):
            return k
    return "rock"


def scan(lib):
    sets = {}
    for item in sorted(os.listdir(lib)):
        p = os.path.join(lib, item)
        if not os.path.isfile(p) or not item.lower().endswith((".zip", ".png")):
            continue
        sid, note = set_id(item)
        st = os.stat(p)
        members = {}
        if item.lower().endswith(".zip"):
            with zipfile.ZipFile(p) as z:
                names = [n for n in z.namelist() if not n.endswith("/")]
            for key, rx in MAPS:
                hits = [n for n in names if re.search(rx, os.path.basename(n), re.I)]
                # Older sets ship a _DIFF2 / _DISP2 / _RGH_Dirty beside the main one: prefer the plain name.
                hits.sort(key=len)
                if hits and key not in members:
                    members[key] = hits[0]
        else:
            members["color"] = None
        lic = licence_of(item)
        kind = kind_of(sid)
        sets[sid] = dict(id=sid, item=item, note=note, licence=lic, format=fmt_of(item), kind=kind,
                         members=members, size=st.st_size, mtime=int(st.st_mtime))
    return sets


def read_map(lib, s, key):
    p = os.path.join(lib, s["item"])
    m = s["members"].get(key, "missing")
    if m == "missing":
        return None
    if m is None:  # a loose PNG
        return to_float(Image.open(p))
    with zipfile.ZipFile(p) as z:
        return to_float(Image.open(io.BytesIO(z.read(m))))


def out_root(s):
    return OUT_CC0 if s["licence"] == "CC0" else OUT_LOCAL


# ── one set → albedo / normal / orm / height ─────────────────────────────────


def gl_from_height(nrm, height):
    """Is this unlabelled normal map OpenGL (+Y up)? In a GL map the green channel
    follows dH/d(row) (a bump's upper side, toward row 0, faces up); in a DirectX one
    it runs against it. Measured on the set's own height map; None = can't tell."""
    if height is None:
        return None
    n = 256
    h = resize(gray(height), n)
    g = resize(nrm[..., 1], n) * 2 - 1
    r = resize(nrm[..., 0], n) * 2 - 1
    dhy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    dhx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    cy = np.corrcoef(g.ravel(), dhy.ravel())[0, 1]
    cx = np.corrcoef(r.ravel(), dhx.ravel())[0, 1]
    if not np.isfinite(cy) or abs(cy) < 0.05:
        return None
    # cx should come out negative (normal.x leans away from rising height); if it
    # doesn't, the height map is inverted (a depth map) and so is our reading of y.
    flip = -1.0 if (np.isfinite(cx) and cx > 0.05) else 1.0
    return bool((cy * flip) > 0)


def normal_from_height(h, strength=4.0):
    dhy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5 * h.shape[0] / 256
    dhx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5 * h.shape[1] / 256
    n = np.stack([-dhx * strength, dhy * strength, np.ones_like(h)], axis=2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n * 0.5 + 0.5


def ao_from_height(h):
    hb = blur_wrap(h, h.shape[0] / 96)
    return np.clip(1.0 - np.clip(hb - h, 0, None) * 4.0, 0.35, 1.0)


def convert_set(lib, s, size):
    """Load and convert one set at `size`. Returns dict of float maps + notes."""
    notes = []
    color = read_map(lib, s, "color")
    if color is None:
        color = read_map(lib, s, "diff")
        if color is not None and s["format"] == "older":
            notes.append("albedo from _DIFF (may carry baked light)")
    if color is None:
        raise RuntimeError("no colour map")
    if color.ndim == 2:
        color = np.stack([color] * 3, axis=2)
    alpha = color[..., 3] if color.shape[2] == 4 and color[..., 3].min() < 0.99 else None
    color = color[..., :3]
    opacity = read_map(lib, s, "opacity")
    if opacity is not None and gray(opacity).min() < 0.99:
        alpha = gray(opacity)
    height = read_map(lib, s, "height")
    if height is not None:
        height = gray(height)
        if height.max() - height.min() < 1e-3:
            height = None
    # normal
    nrm, conv = None, None
    if s["members"].get("normal_gl"):
        nrm, conv = read_map(lib, s, "normal_gl"), "GL (as shipped)"
    elif s["members"].get("normal_dx"):
        nrm = read_map(lib, s, "normal_dx")
        nrm[..., 1] = 1 - nrm[..., 1]
        conv = "DX -> GL (green flipped)"
    elif s["members"].get("normal"):
        nrm = read_map(lib, s, "normal")
        if nrm.ndim == 2:
            nrm = None
        else:
            nrm = nrm[..., :3]
            hm = height
            if hm is not None and hm.shape != nrm.shape[:2]:
                hm = resize(squarify(hm), nrm.shape[0]) if nrm.shape[0] == nrm.shape[1] else None
            gl = gl_from_height(nrm, hm)
            if gl is False:
                nrm[..., 1] = 1 - nrm[..., 1]
                conv = "DX -> GL (measured against its height map)"
            elif gl is True:
                conv = "GL (measured against its height map)"
            else:
                conv = "assumed GL (no height map to test against)"
    if nrm is not None and nrm.ndim == 3:
        nrm = nrm[..., :3]
    if nrm is None and height is not None:
        nrm = normal_from_height(resize(squarify(height), min(1024, height.shape[0])))
        conv = "made from the height map"
    if nrm is None:
        conv = "flat (no normal or height)"
    # roughness
    rough = read_map(lib, s, "rough")
    if rough is not None:
        rough = gray(rough)
        rsrc = "roughness map"
    else:
        spec = read_map(lib, s, "spec")
        if spec is not None:
            spec = gray(spec)
            rough = np.clip(1.0 - spec * 0.8, 0.2, 1.0)
            rsrc = "1 - 0.8 x specular map"
        else:
            rough, rsrc = None, "constant %.2f" % ROUGH_DEFAULT.get(s["kind"], 0.8)
    metal = read_map(lib, s, "metal")
    if metal is not None:
        metal = gray(metal)
    ao = read_map(lib, s, "ao")
    if ao is not None:
        ao = gray(ao)
        aosrc = "AO map"
    elif height is not None:
        ao, aosrc = None, "from height"
    else:
        aosrc = "none (white)"

    def fit(a, linear=False):
        return None if a is None else resize(squarify(a), size, linear)

    out = {}
    out["albedo"] = fit(color, True)
    out["alpha"] = fit(alpha)
    out["height"] = fit(height)
    if out["height"] is not None:
        hh = out["height"]
        out["height"] = (hh - hh.min()) / max(1e-6, hh.max() - hh.min())
    if nrm is not None:
        n = fit(nrm) * 2 - 1
        n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
        out["normal"] = n * 0.5 + 0.5
    else:
        out["normal"] = None
    o = np.ones((size, size), np.float32)
    aof = fit(ao) if ao is not None else (ao_from_height(out["height"]) if out["height"] is not None else o)
    rf = fit(rough) if rough is not None else o * ROUGH_DEFAULT.get(s["kind"], 0.8)
    mf = fit(metal) if metal is not None else o * METAL_DEFAULT.get(s["kind"], 0.0)
    out["orm"] = np.stack([aof, rf, mf], axis=2)
    out["notes"] = notes
    out["info"] = dict(normal=conv, roughness=rsrc, ao=aosrc,
                       metal="metal map" if metal is not None else "constant %.1f" % METAL_DEFAULT.get(s["kind"], 0.0))
    return out


def stamp_of(s, extra):
    h = hashlib.sha1(json.dumps([IMPORTER_VERSION, s["item"], s["size"], s["mtime"], extra],
                                sort_keys=True).encode()).hexdigest()
    return h[:16]


def write_set(args):
    lib, s, dry, force = args
    lic_cc0 = s["licence"] == "CC0"
    size = RES[s["kind"]][0 if lic_cc0 else 1]
    d = os.path.join(ROOT, out_root(s), "sets", s["id"])
    st = stamp_of(s, size)
    stf = os.path.join(d, ".import")
    if not force and os.path.exists(stf) and open(stf).read().strip() == st:
        info = json.load(open(os.path.join(d, "info.json"))) if os.path.exists(os.path.join(d, "info.json")) else {}
        return s["id"], "up to date", size, info
    if dry:
        return s["id"], "would convert", size, {}
    out = convert_set(lib, s, size)
    os.makedirs(d, exist_ok=True)
    if out["alpha"] is not None:
        save_png(np.concatenate([out["albedo"], out["alpha"][..., None]], axis=2), os.path.join(d, "albedo.png"), "RGBA")
    else:
        save_png(out["albedo"], os.path.join(d, "albedo.png"), "RGB")
    if out["normal"] is not None:
        save_png(out["normal"], os.path.join(d, "normal.png"), "RGB")
    save_png(out["orm"], os.path.join(d, "orm.png"), "RGB")
    if out["height"] is not None:
        save_png(out["height"], os.path.join(d, "height.png"), "L")
    info = dict(out["info"], notes=out["notes"], size=size)
    json.dump(info, open(os.path.join(d, "info.json"), "w"), indent=1)
    open(stf, "w").write(st + "\n")
    return s["id"], "converted", size, info


# ── terrain layers ───────────────────────────────────────────────────────────
BAKE = 1024  # the working size a layer is baked at before its reduction to 256


def load_for_layer(lib, s):
    """Full-resolution albedo (linear), normal (-1..1), AO, height for a layer bake."""
    c = convert_set(lib, s, BAKE)
    alb = srgb_to_lin(c["albedo"])
    n = c["normal"] * 2 - 1 if c["normal"] is not None else None
    return alb, n, c["orm"][..., 0], c["height"]


def grade(alb, n, ao, g):
    """The plain layer bake, in linear light."""
    c = alb.copy()
    # Relief that the engine can't light: AO and the normal's tilt, darkening.
    c *= (1 - g.get("ao", 0.6)) + g.get("ao", 0.6) * ao[..., None]
    if n is not None:
        tilt = np.clip(n[..., 2], 0, 1)
        c *= ((1 - g.get("cav", 0.5)) + g.get("cav", 0.5) * tilt ** 2)[..., None]
    # Wind ripples (sand): none of the library's sands has them, and on a dune
    # world they are what says "sand" from ten metres. A tileable ripple field
    # (an integer count across the tile, its phase bent by wrap noise) shaded as
    # relief: the lee slopes darker, the crests a little lighter.
    rp = g.get("ripples")
    if rp:
        N = c.shape[0]
        rng = np.random.default_rng(11)
        warp = blur_wrap(rng.standard_normal((N, N)), N / 10)
        warp = warp / (warp.std() + 1e-9)
        fine = blur_wrap(rng.standard_normal((N, N)), N / 60)
        fine = fine / (fine.std() + 1e-9)
        yy = np.arange(N)[:, None] / N
        phase = 2 * np.pi * (rp["count"] * yy + rp.get("bend", 0.25) * warp + 0.05 * fine)
        # h = sin + a quarter of the second harmonic: a long stoss slope, a short lee;
        # shaded by its slope (light across the ripples), faded in and out by noise
        dh = np.cos(phase) + 0.5 * np.cos(2 * phase)
        fade = np.clip(0.65 + 0.35 * fine, 0.2, 1.0)
        shade = 1 + rp.get("amp", 0.1) * dh / 1.5 * fade
        c *= shade[..., None]
    # Flatten the broad blotches (wrap blur at a sixth of the tile): the low
    # frequencies are what repeat visibly when a tile is laid 50 times.
    fl = g.get("flatten", 0.7)
    if fl > 0:
        L = np.maximum(lum(c), 1e-4)
        Lb = np.maximum(blur_wrap(L, c.shape[0] / 6), 1e-4)
        c *= ((L.mean() / Lb) ** fl)[..., None]
    # Colour: saturation about the pixel's luminance, a tint that keeps luminance.
    L = lum(c)[..., None]
    c = L + (c - L) * g.get("sat", 1.0)
    t = np.array(g.get("tint", (1, 1, 1)), np.float32)
    t = t / (t[0] * 0.2126 + t[1] * 0.7152 + t[2] * 0.0722)
    c = c * t
    # Contrast in log space about the mean (keeps the mean brightness), then gain.
    k = g.get("contrast", 1.0)
    if k != 1.0:
        L = np.maximum(lum(c), 1e-4)
        m = np.exp(np.log(L).mean())
        c *= ((L / m) ** (k - 1))[..., None]
    c *= g.get("gain", 1.0)
    return np.clip(c, 0, 1)


def make_veins(alb, n, ao, g, glow=False):
    """Rock058's warm veins as a seam stone (veinstone) or lit from inside (magma)."""
    L = lum(alb)
    r, gg, b = alb[..., 0], alb[..., 1], alb[..., 2]
    warm = np.clip((r - b) / np.maximum(r + gg + b, 1e-4) * 3.0, 0, 1)   # how orange
    bright = np.clip(L / max(1e-4, np.percentile(L, 97)), 0, 1)
    mask = np.clip((warm * bright - (0.08 if glow else 0.05)) * (4.0 if glow else 6.0), 0, 1)
    mask = np.maximum(mask, blur_wrap(mask, 3.0) * 0.8)
    if glow:
        base = alb * 0.08 * ao[..., None]
        hot = np.array([1.0, 0.36, 0.06], np.float32)
        core = np.array([1.0, 0.85, 0.45], np.float32)
        m = mask[..., None]
        halo = np.clip(blur_wrap(mask, 9.0) * 1.6, 0, 1)[..., None]
        c = base * (1 - m) + (hot * m + core * m ** 3) * 0.9 + hot * halo * 0.12
        return np.clip(c, 0, 1)
    c = grade(alb, n, ao, dict(sat=0.35, flatten=0.6)) * g.get("base", 1.0)
    vein = np.array(g.get("vein", (1.0, 0.5, 0.2)), np.float32) * 0.5
    return np.clip(c * (1 - mask[..., None]) + vein * mask[..., None] * g.get("veinGain", 1.0) * c.mean(), 0, 1)


def make_crystal(alb, n, g):
    """The faceted band of ChristmasTreeOrnament021 (the user's Star Geode note) as a
    crystal lining: its facets shaded from fixed lights through its normal map (the
    tilt exaggerated, so neighbouring faces differ), each face reading as its own
    plane, the edges between them catching light, in the slot's colour."""
    h = alb.shape[0]
    a, b = int(h * 0.30), int(h * 0.70)       # the faceted band (the ornament's equator)
    band_n = n[a:b]
    # Make a tileable square: the band and its mirror (rows), wrapping across (columns).
    nn = np.concatenate([band_n, band_n[::-1] * np.array([1, -1, 1], np.float32)], axis=0)
    nn = resize(nn * 0.5 + 0.5, h) * 2 - 1
    nn = np.concatenate([nn[..., :2] * 3.0, nn[..., 2:]], axis=2)
    nn /= np.maximum(np.linalg.norm(nn, axis=2, keepdims=True), 1e-6)
    lights = [np.array(v, np.float32) / np.linalg.norm(v) for v in ((0.55, 0.55, 0.62), (-0.75, 0.15, 0.6), (0.1, -0.85, 0.5))]
    shade = sum(np.clip((nn * l).sum(axis=2), 0, 1) ** p * w for l, p, w in zip(lights, (4, 2, 2), (0.85, 0.35, 0.25)))
    tilt = 1 - np.clip(nn[..., 2], 0, 1)
    gy, gx = np.gradient(nn[..., 0]), np.gradient(nn[..., 1])
    edge = np.clip((np.hypot(*gy) + np.hypot(*gx)) * 3, 0, 1)
    edge = np.clip(blur_wrap(edge, 1.2) * 1.3, 0, 1) ** 1.5
    t = np.array(g.get("tint", (0.6, 0.4, 1.0)), np.float32)
    c = t[None, None, :] * (0.035 + 0.75 * shade[..., None] ** 1.6) + edge[..., None] * (0.22 * t + 0.12)
    c *= (1.0 - 0.5 * tilt)[..., None] + 0.5
    return np.clip(c, 0, 1)


def make_patchy(alb, n, ao, g, sets):
    """A cover worn through in patches to the ground under it (tundra: dry sedge over
    stony soil): a lawn-like cover alone is one flat colour from ten metres. The patch
    mask is tileable noise at a third of the tile, edged by the cover's own luminance
    so the boundary follows the blades, not a smooth curve."""
    top = grade(alb, n, ao, g)
    us, ug = g["under"]
    ualb, un, uao, _ = load_for_layer(LIB_PATH[0], sets[us])
    bot = grade(ualb, un, uao, ug)
    rng = np.random.default_rng(7)
    a = blur_wrap(rng.standard_normal(alb.shape[:2]), alb.shape[0] / 30)
    b = blur_wrap(rng.standard_normal(alb.shape[:2]), alb.shape[0] / 90)
    noise = a / (a.std() + 1e-9) + 0.6 * b / (b.std() + 1e-9)
    noise = (noise - noise.mean()) / (noise.std() + 1e-6)
    L = lum(top)
    edge = (L - L.mean()) / (L.std() + 1e-6)
    thr = np.quantile(noise, 1 - g.get("cover", 0.6))
    m = np.clip((noise - thr) * 3.0 + edge * 0.6 + 0.5, 0, 1)[..., None]
    return np.clip(top * m + bot * (1 - m), 0, 1)


def bake_layer(lib, sets, src):
    sid, g = src
    s = sets[sid]
    alb, n, ao, height = load_for_layer(lib, s)
    mk = g.get("make")
    if mk == "veins":
        c = make_veins(alb, n, ao, g)
    elif mk == "magma":
        c = make_veins(alb, n, ao, g, glow=True)
    elif mk == "crystal":
        c = make_crystal(alb, n, g)
    elif mk == "patchy":
        c = make_patchy(alb, n, ao, g, sets)
    else:
        c = grade(alb, n, ao, g)
    out = resize(lin_to_srgb(c), LAYER, linear=True)
    # Grain back: a 2048 photo reduced 8x loses the micro-contrast that reads as
    # grit at the player's feet (the layer is magnified 3-5x there). A small
    # wrap-around unsharp mask restores it; measured, the far ground's per-pixel
    # speckle stays well under the old procedural layers' (the palette has no mips).
    k = g.get("sharpen", 0.3 if mk else 0.8)
    if k > 0:
        out = np.clip(out + k * (out - blur_wrap(out, 0.9)), 0, 1)
    return out


def layer_path(root, t):
    return "%s/terrain/%02d_%s.png" % (root, t["slot"], t["name"])


def layer_job(args):
    lib, sets, t, which, dry, force = args
    src = t.get(which)
    if not src:
        return t["slot"], which, "none", None
    s = sets.get(src[0])
    if s is None:
        return t["slot"], which, "missing set " + src[0], None
    root = OUT_CC0 if which == "cc0" else OUT_LOCAL
    if which == "cc0" and s["licence"] != "CC0":
        raise SystemExit("slot %d: cc0 layer from a commercial set (%s)" % (t["slot"], src[0]))
    rel = layer_path(root, t)
    p = os.path.join(ROOT, rel)
    st = stamp_of(s, [LAYER, BAKE, src[1], RECIPE_HASH()])
    stf = p + ".import" if which == "local" else os.path.join(ROOT, root, "terrain", ".import-%02d" % t["slot"])
    if not force and os.path.exists(p) and os.path.exists(stf) and open(stf).read().strip() == st:
        return t["slot"], which, "up to date", rel
    if dry:
        return t["slot"], which, "would bake", rel
    a = bake_layer(LIB_PATH[0], sets, src)
    save_png(a, p, "RGB")
    open(stf, "w").write(st + "\n")
    return t["slot"], which, "baked", rel


LIB_PATH = [LIB]


def RECIPE_HASH():
    """The layer recipes' own code, so changing one re-bakes its layers."""
    import inspect
    src = "".join(inspect.getsource(f) for f in (grade, make_veins, make_crystal, make_patchy, bake_layer, load_for_layer, convert_set))
    return hashlib.sha1(src.encode()).hexdigest()[:12]


def palette_line(t, path):
    line = path
    if t.get("glow"):
        line += "|glow"
    line += "|scale=%g" % t["scale"]
    if not t.get("glow"):
        line += "|blend=%g|rough=%g" % (t.get("blend", 0.8), t.get("rough", 0.7))
    return line


def write_palettes(dry, root_dir=None, local=False):
    """terrain/system.palette (32 slots) and planetoid.palette (12). Committed: cc0
    layers only. `local` (for --stage) names a slot's local layer where root_dir has it."""
    root_dir = root_dir or ROOT
    lines = []
    for t in TERRAIN:
        path = layer_path(OUT_CC0, t)
        if local and t.get("local") and os.path.exists(os.path.join(root_dir, layer_path(OUT_LOCAL, t))):
            path = layer_path(OUT_LOCAL, t)
        lines.append(palette_line(t, path))
    out = {"terrain/system.palette": "\n".join(lines),
           "terrain/planetoid.palette": "\n".join(lines[:PLANETOID_SLOTS])}
    for rel, text in out.items():
        p = os.path.join(root_dir, rel)
        old = open(p).read() if os.path.exists(p) else None
        if old == text:
            continue
        print(("would write " if dry else "wrote ") + rel)
        if not dry:
            open(p, "w").write(text)


TEXRON = ".floptle/textures.ron"


def write_texture_settings(dry, root_dir=None):
    """Every terrain layer filtered smooth (an unlisted texture is Pixelated, and the
    palette loader resizes and samples a Pixelated slot nearest-neighbour)."""
    p = os.path.join(root_dir or ROOT, TEXRON)
    text = open(p).read()
    keys = [layer_path(root, t) for t in TERRAIN for root, which in ((OUT_CC0, "cc0"), (OUT_LOCAL, "local")) if t.get(which)]
    # a layer the table no longer has (a slot renamed, a local version dropped) loses its line
    lines = text.split("\n")
    rx = re.compile(r'^\s*"(%s|%s)/terrain/[^"]*"' % (re.escape(OUT_CC0), re.escape(OUT_LOCAL)))
    kept = [l for l in lines if not (rx.match(l) and l.strip().split('"')[1] not in keys)]
    gone = len(lines) - len(kept)
    text = "\n".join(kept)
    want = ['    "%s": (filter: SmoothMipmaps, wrap: Repeat),' % k for k in keys if '"%s"' % k not in text]
    if not want and not gone:
        return
    print(("would change " if dry else "changed ") + "%s: %d added, %d dropped" % (TEXRON, len(want), gone))
    if dry:
        return
    if want:
        i = text.rstrip().rfind("}")
        text = text[:i].rstrip() + "\n" + "\n".join(want) + "\n}\n"
    open(p, "w").write(text)


def layer_means():
    """Mean linear colour of each committed layer (far_bodies.lua PAL)."""
    out = []
    for t in TERRAIN:
        a = srgb_to_lin(to_float(Image.open(os.path.join(ROOT, layer_path(OUT_CC0, t)))))
        out.append(tuple(round(float(v), 3) for v in a.reshape(-1, 3).mean(axis=0)))
    return out


def write_manifest(sets, results, dry):
    uses = {}
    for t in TERRAIN:
        for which in ("cc0", "local"):
            if t.get(which):
                uses.setdefault(t[which][0], []).append(
                    "terrain slot %d %s (%s)%s" % (t["slot"], t["name"], t["mat"], "" if which == "cc0" else ", local builds"))
                if t[which][1].get("under"):
                    uses.setdefault(t[which][1]["under"][0], []).append(
                        "terrain slot %d %s (%s), the ground under its cover" % (t["slot"], t["name"], t["mat"]))
    rows = []
    for sid, s in sorted(sets.items()):
        r = results.get(sid, {})
        rows.append(dict(
            id=sid, source=s["item"], note=s["note"] or None, licence=s["licence"], format=s["format"], kind=s["kind"],
            committed=s["licence"] == "CC0", out="%s/sets/%s/" % (out_root(s), sid),
            resolution=RES[s["kind"]][0 if s["licence"] == "CC0" else 1],
            maps=sorted(k for k in s["members"]), conversion=r or None,
            use=uses.get(sid) or [PLANNED.get(s["kind"], "reserve")],
        ))
    layers = [dict(slot=t["slot"], name=t["name"], material=t["mat"], replaces="textures/terrain/%s.png" % t["was"],
                   cc0=dict(set=t["cc0"][0], file=layer_path(OUT_CC0, t)),
                   local=dict(set=t["local"][0], file=layer_path(OUT_LOCAL, t)) if t.get("local") else None,
                   size=LAYER, scale=t["scale"], glow=bool(t.get("glow"))) for t in TERRAIN]
    doc = dict(
        about="Solar's environment texture library, converted by tools/import_textures.py. CC0 output "
              "(textures/env) is committed; commercial output (textures/env_local) is git-ignored and must "
              "never be committed. Each set: albedo.png (sRGB), normal.png (OpenGL), orm.png (R AO, G rough, "
              "B metal), height.png.",
        library=os.path.basename(LIB_PATH[0].rstrip("/")) + " (a local folder: --lib)", sets=rows, terrain=layers)
    text = json.dumps(doc, indent=1, ensure_ascii=False) + "\n"
    p = os.path.join(ROOT, MANIFEST)
    if os.path.exists(p) and open(p).read() == text:
        return
    print(("would write " if dry else "wrote ") + MANIFEST)
    if not dry:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)


# ── --stage: a build copy that uses the local sets ───────────────────────────


# What a build carries of textures/env_local: only what the game references. The full
# sets (sets/<id>/) wait for the wave that uses them; that wave adds its folders here.
STAGE_DIRS = ["terrain"]


def stage(dst):
    src = os.path.join(ROOT, OUT_LOCAL)
    if not os.path.isdir(os.path.join(dst, "terrain")):
        raise SystemExit("--stage: %s is not a Solar project copy (no terrain/)" % dst)
    if not os.path.isdir(src):
        print("STAGE: no %s here: the build keeps the CC0 terrain" % OUT_LOCAL)
        return
    to = os.path.join(dst, OUT_LOCAL)
    if os.path.realpath(to) != os.path.realpath(src):
        if os.path.islink(to):
            os.unlink(to)
        for sub in STAGE_DIRS:
            if os.path.isdir(os.path.join(src, sub)):
                if os.path.isdir(os.path.join(to, sub)):
                    shutil.rmtree(os.path.join(to, sub))
                shutil.copytree(os.path.join(src, sub), os.path.join(to, sub),
                                ignore=shutil.ignore_patterns(".import*", "*.import", "info.json"))
    write_palettes(False, dst, local=True)
    if os.path.exists(os.path.join(dst, TEXRON)):
        write_texture_settings(False, dst)
    n = sum(1 for t in TERRAIN if t.get("local") and os.path.exists(os.path.join(dst, layer_path(OUT_LOCAL, t))))
    print("STAGE: %s now uses %d local terrain layers (%s)" % (dst, n, ", ".join(OUT_LOCAL + "/" + d for d in STAGE_DIRS)))


# ── --sheet ──────────────────────────────────────────────────────────────────


def sheets(outdir):
    from PIL import ImageDraw
    outdir = os.path.abspath(outdir)
    if os.path.realpath(outdir).startswith(os.path.realpath(ROOT) + os.sep):
        raise SystemExit("--sheet: contact sheets hold commercial pixels; write them outside the repo")
    os.makedirs(outdir, exist_ok=True)
    for which, root in (("cc0", OUT_CC0), ("local", OUT_LOCAL)):
        tiles = []
        for t in TERRAIN:
            p = os.path.join(ROOT, layer_path(root, t))
            if os.path.exists(p):
                im = Image.open(p).convert("RGB")
                big = Image.new("RGB", (512, 512))
                for i in range(2):
                    for j in range(2):
                        big.paste(im, (i * 256, j * 256))
                tiles.append(("%02d %s (%s)" % (t["slot"], t["name"], t[which][0]), big))
        if not tiles:
            continue
        cols = 8
        S = Image.new("RGB", (cols * 256, ((len(tiles) + cols - 1) // cols) * 272), (16, 16, 16))
        d = ImageDraw.Draw(S)
        for k, (label, im) in enumerate(tiles):
            x, y = (k % cols) * 256, (k // cols) * 272
            S.paste(im.resize((256, 256), Image.LANCZOS), (x, y))
            d.text((x + 3, y + 258), label, fill=(255, 255, 255))
        S.save(os.path.join(outdir, "terrain_%s.png" % which))
        print("sheet", os.path.join(outdir, "terrain_%s.png" % which))


# ── main ─────────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--lib", default=LIB)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--sheet")
    ap.add_argument("--stage")
    ap.add_argument("--means", action="store_true", help="print far_bodies.lua PAL from the committed layers")
    ap.add_argument("--write", action="store_true", help="with --means: write it into scripts/far_bodies.lua")
    a = ap.parse_args()
    LIB_PATH[0] = a.lib
    if a.stage:
        stage(os.path.abspath(a.stage))
        return
    if a.means:
        m = layer_means()
        text = "\n".join("  " + " ".join("{ %.3f, %.3f, %.3f }," % v for v in m[i:i + 4]) for i in range(0, 32, 4))
        print(text)
        if a.write:
            p = os.path.join(ROOT, "scripts/far_bodies.lua")
            src = open(p).read()
            i = src.index("PAL = {\n")
            j = src.index("\n}\n", i)
            new = src[:i] + "PAL = {\n" + text + src[j:]
            if new != src:
                open(p, "w").write(new)
                print("wrote scripts/far_bodies.lua PAL")
        return
    if a.sheet:
        sheets(a.sheet)
        return
    if not os.path.isdir(a.lib):
        print("no library at %s: nothing to convert; palettes and manifest left as they are" % a.lib)
        return
    sets = scan(a.lib)
    print("library: %d sets (%d CC0, %d commercial)" % (len(sets), sum(s["licence"] == "CC0" for s in sets.values()),
                                                        sum(s["licence"] != "CC0" for s in sets.values())))
    pick = [s for s in sets.values() if not a.only or s["id"] in a.only]
    results = {}
    with ProcessPoolExecutor(max_workers=a.jobs, initializer=_init, initargs=(a.lib,)) as ex:
        for sid, what, size, info in ex.map(write_set, [(a.lib, s, a.dry, a.force) for s in pick]):
            print("  %-34s %-15s %4d  %s" % (sid, what, size, (info or {}).get("normal", "")))
            results[sid] = info
        jobs = [(a.lib, sets, t, w, a.dry, a.force) for t in TERRAIN for w in ("cc0", "local")
                if t.get(w) and (not a.only or t[w][0] in a.only)]
        for slot, which, what, rel in ex.map(layer_job, jobs):
            print("  layer %2d %-5s %-12s %s" % (slot, which, what, rel or ""))
    for sid in sets:
        if sid not in results:
            p = os.path.join(ROOT, out_root(sets[sid]), "sets", sid, "info.json")
            results[sid] = json.load(open(p)) if os.path.exists(p) else {}
    write_palettes(a.dry)
    write_texture_settings(a.dry)
    write_manifest(sets, results, a.dry)


def _init(lib):
    LIB_PATH[0] = lib


if __name__ == "__main__":
    main()
