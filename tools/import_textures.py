#!/usr/bin/env python3
"""Import the realistic environment texture library into Solar.

    python3 tools/import_textures.py              # convert what changed, write palettes + manifest
    python3 tools/import_textures.py --dry        # say what it would do, write nothing
    python3 tools/import_textures.py --force      # convert everything again
    python3 tools/import_textures.py --only Rock035 Ground039
    python3 tools/import_textures.py --sheet DIR  # contact sheets (terrain layers, sets) into DIR
    python3 tools/import_textures.py --stage DIR  # make a project copy at DIR use the local sets:
                                                  # copy textures/env_local in, point the terrain
                                                  # palettes' slots at their local versions, lay
                                                  # the local overlays (OVERLAYS) over textures/base
    python3 tools/import_textures.py --lib PATH   # another library folder
    python3 tools/import_textures.py --extra-lib PATH  # a folder of fetched CC0 sets (EXTRA_LIBS):
                                                  # ambientCG zips and Poly Haven ph/<asset>/ folders;
                                                  # only their terrain layers are baked
    Run it with `python3 -I` when a library holds downloaded data.
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
terrain palette (terrain/<scene>.palette) is 32 slots of one LAYER-square sRGB
colour layer each (project.ron terrain_layer_size, 512), with mips, projected
triplanar and multiplied by the voxel's tint x 1.6 (floptle-render raster.wgsl
`terrain_triplanar`). Since engine 0637 (dev .1438) a slot can also name a
normal, ORM and height map (`|normal= |orm= |height=`), which the engine lights
when the terrain's Material is Physical (system_generator makeBody). Each layer
is baked here: the set's albedo, darkened by part of its AO and of how far its
normal map tilts from the surface (RELIEF_MAPPED: the engine lights the rest
from the sun's side), its broad light-and-dark blotches flattened (the thing
that makes a photo's tile repeat visibly across a hillside), graded for the
slot, reduced to LAYER in linear light and kept at the fully baked layer's mean.
Its maps (maps/, layer_maps) come from the same set at the same size. Slot
numbers are what mining reads (materials.lua SLOT), so each slot keeps its
geology.

TERRAIN entries 33 and up are the LIBRARY (worlds plan W1): layers baked and committed the
same way but on no palette line (PALETTE_SLOTS); each entry has a `role` (HEIGHT_ROLES). A
re-sourced slot's grade can `hold` its old mean colour (linear rgb) so far_bodies PAL and
the mining tints keep it. Recipes beside the plain bake: veins/magma, copper, crystal,
patchy, and (W1) soot, gossan, sulfurvein, pitchblende, columnar, (W3) galena (RECIPES).

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
# CC0 sets fetched for the terrain (worlds plan W1, 2026-11-10: ambientCG `Name_2K-PNG.zip` and
# Poly Haven ph/<asset>/ folders, each page's licence checked: NOTES in work/worlds_w01). Read only,
# like LIB; a folder that is not there is skipped. `--extra-lib PATH` adds or replaces it.
EXTRA_LIBS = ["/mnt/disks/3tb/.floptle-shared/solar/work/worlds_w01/dl"]
OUT_CC0 = "textures/env"            # committed
OUT_LOCAL = "textures/env_local"    # git-ignored
MANIFEST = "textures/env/manifest.json"
LAYER = 512                         # the terrain palette's layer size: project.ron terrain_layer_size
# The unsharp mask that gives a layer its grain back after the reduction
# (bake_layer). Its strength follows the reduction: 0.8 suited 256 (a 2048
# photo reduced 8x); at 512 (4x) half of it, measured (work/t1437 REPORT.md).
SHARPEN = 0.8 * 256 / LAYER
SHARPEN_MADE = 0.3 * 256 / LAYER    # the made layers (veins, copper, crystal, patchy)
# How much of the baked relief (AO and the normal's tilt darkening the colour,
# the ripple shading) a slot keeps once the engine lights its own normal and
# ORM maps (engine 0637, dev .1438): the rest the engine now draws from the sun's
# side, so baking it all as well would darken every crevice twice. The layer is
# then scaled back to the mean of the fully baked one, so its average colour
# (far_bodies PAL, the map, the mining tints) stays what it was.
RELIEF_MAPPED = 0.35

Image.MAX_IMAGE_PIXELS = 20000 * 20000

# ── what each set is ─────────────────────────────────────────────────────────
# kind: what it is for. The resolution of the stored maps follows it and the
# licence (CC0 output is committed, so it is kept small until a wave uses it;
# re-run with a bigger RES entry when one does).
KINDS = [
    (r"^(Rock|Rocks|Old_Rocks|Mossy_Rock|Rock_Wall|Stone_01|MarsSmoothRock|Onyx)", "rock"),
    (r"^(Ground|Dirt|Dirty_Grass|Grass|FineClumpySand|MossAndSmallFerns|White_Stones|Potato)", "ground"),
    (r"^(Snow|snow_)", "snow"),
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
    "metal": "reserve: later props and station hardware (wave 3 dressed the parts from the CC0 metals, tools/parts_pbr.py)",
    "concrete": "wave 2: base pads, foundations and buildings (replace textures/base concrete)",
    "road": "wave 2: base roads and pads (replace textures/base asphalt)",
    "wood": "wave 4: crates, props and felled-log ends",
    "bark": "wave 4: tree bark (replace textures/flora bark_*)",
    "foliage": "wave 4: leaf cards (replace textures/flora foliage_*)",
    "scifi": "reserve: station interiors (their baked panel layouts fight the meshes' own seams; wave 3 left them out)",
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
#   drift         the slot's height map for blending is reshaped (drift_height): snow
#                 and ice thin out over a band with a soft fringe instead of a stencil
#   make          a special recipe instead of the plain bake
G = dict  # shorthand
TERRAIN = [
    # 1–12: the original set (6–8 glow). Names kept: generator and saves use the numbers.
    dict(slot=1, name="rust", role="rock", was="planet_rust_rock", mat="rustrock", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rocks011", G(sat=1.2, tint=(1.0, 0.42, 0.26), contrast=1.15)),
         local=("MarsSmoothRock", G(sat=0.75, tint=(1.0, 0.7, 0.58)))),
    dict(slot=2, name="soil", role="loose", was="planet_purple_dirt", mat="soil", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Ground039", G())),
    dict(slot=3, name="flagstone", role="rock", was="planet_purple_slate", mat="slate", scale=1.4, blend=0.8, rough=0.7,
         cc0=("Rock023", G(sat=0.6, contrast=1.1, hold=(0.173, 0.166, 0.149))), local=("Old_Rocks", G(sat=0.7))),
    dict(slot=4, name="onyx", role="rock", was="planet_banded_onyx", mat="onyx", scale=1.2, blend=0.8, rough=0.7,
         cc0=("Onyx006", G(sat=0.85, flatten=0.0))),
    dict(slot=5, name="veinstone", role="ore", was="cave_orange_veinstone", mat="veinstone", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rock058", G(make="copper", cover=0.48))),
    dict(slot=6, name="magma", role="glow", was="cave_magma_veins", mat="uranium", scale=1.4, glow=True,
         cc0=("Rock058", G(make="magma"))),
    # The crystal seams (resonant crystal, phasite, cryovolt): druzy crystal in its host
    # rock, lit like stone (playtest 2026-11-06: the old self-lit faceted ornament band read as
    # flat neon polygons). Not glow slots any more: they take maps, blend and anti-tiling.
    dict(slot=7, name="amethyst", role="crystal", was="cave_amethyst", mat="crystal", scale=1.3, blend=0.8, rough=0.9,
         rfloor=0.12, cc0=("Rock035", G(make="crystal", tint=(0.36, 0.22, 0.46), pale=(0.74, 0.71, 0.76), seed=7))),
    dict(slot=8, name="bluecrystal", role="crystal", was="cave_blue_crystal", mat="crystal", scale=1.3, blend=0.8, rough=0.9,
         rfloor=0.12, cc0=("Rock035", G(make="crystal", tint=(0.20, 0.32, 0.46), pale=(0.72, 0.76, 0.79), seed=8))),
    dict(slot=9, name="slate", role="rock", was="moon_silver_slate", mat="slate", scale=1.6, blend=0.8, rough=0.7,
         cc0=("dark_rock", G(sat=0.3, contrast=1.05, hold=(0.162, 0.165, 0.169))), local=("Rock_Wall", G(sat=0.5))),
    dict(slot=10, name="gravelregolith", role="loose", was="moon_gray_regolith", mat="regolith", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Ground110", G(sat=0.12, gain=0.9))),
    dict(slot=11, name="dust", role="loose", was="moon_crater_dust", mat="regolith", scale=2.0, blend=1.2, rough=0.7,
         cc0=("moon_dusted_01", G(sat=0.4, contrast=1.7, flatten=0.2, hold=(0.519, 0.490, 0.444)))),
    dict(slot=12, name="bandedice", role="ice", was="moon_teal_ice", mat="ice", scale=1.2, blend=1.6, rough=0.7, rfloor=0.3,
         drift=G(own=1.0, soften=0.012, lobew=0.6, finew=0.0),
         cc0=("Rock019", G(sat=0.25, tint=(0.75, 0.95, 1.0), contrast=0.8, hold=(0.279, 0.362, 0.384)))),
    # 13–32: the geology set.
    dict(slot=13, name="basalt", role="rock", was="geo_basalt", mat="basalt", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock050", G(sat=0.3, contrast=1.35, hold=(0.045, 0.051, 0.054)))),
    dict(slot=14, name="granite", role="rock", was="geo_granite", mat="granite", scale=1.8, blend=0.8, rough=0.7,
         cc0=("Rock060", G(sat=0.7, gain=1.8, contrast=1.15)), local=("Rock_05", G())),
    dict(slot=15, name="sandstone", role="rock", was="geo_sandstone", mat="sandstone", scale=1.0, blend=0.8, rough=0.7,
         cc0=("Onyx010", G(sat=0.55, tint=(1.0, 0.78, 0.55), contrast=0.75)), local=("Mossy_Rock", G(contrast=1.1))),
    dict(slot=16, name="sand", role="sand", was="geo_sand", mat="sand", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Ground093B", G(contrast=1.4, flatten=0.3, ripples=dict(count=16, amp=0.16)))),
    dict(slot=17, name="regolith", role="loose", was="geo_regolith", mat="regolith", scale=2.0, blend=1.2, rough=0.7,
         cc0=("moon_meteor_01", G(sat=0.4, contrast=1.3, flatten=0.4, hold=(0.218, 0.205, 0.203)))),
    dict(slot=18, name="salt", role="sand", was="geo_salt", mat="salt", scale=1.2, blend=1.2, rough=0.7,
         cc0=("Ground031", G(sat=0.05, contrast=1.2, flatten=0.5, hold=(0.424, 0.411, 0.382))),
         local=("Cracked_Asphalt", G(sat=0.15, tint=(1.0, 0.97, 0.92), gain=2.3, contrast=0.7))),
    dict(slot=19, name="mudcrack", role="loose", was="geo_mudcrack", mat="clay", scale=1.6, blend=1.2, rough=0.7,
         cc0=("mud_cracked_dry_riverbed_002", G(sat=0.9, contrast=1.1, hold=(0.348, 0.224, 0.159))),
         local=("MarsSmoothRock", G(sat=0.6, gain=1.15))),
    dict(slot=20, name="moss", role="veg", was="geo_moss", mat="soil", scale=1.8, blend=1.2, rough=0.7,
         cc0=("Ground037", G()), local=("MossAndSmallFerns", G(contrast=1.15))),
    dict(slot=21, name="ash", role="loose", was="geo_ash", mat="ash", scale=2.2, blend=1.2, rough=0.7,
         cc0=("Gravel043", G(sat=0.2, contrast=1.1, hold=(0.076, 0.073, 0.070)))),
    dict(slot=22, name="snow", role="snow", was="geo_snow", mat="ice", scale=1.8, blend=3.0, rough=0.7, drift=G(own=1.0, soften=0.008, finew=0.5),
         cc0=("Snow014", G(contrast=1.3))),
    dict(slot=23, name="glacier", role="ice", was="geo_glacier", mat="ice", scale=1.0, blend=2.0, rough=0.7, rfloor=0.25,
         drift=G(own=1.0, soften=0.012, lobew=0.5, finew=0.2),
         cc0=("Snow008A", G(sat=1.0, tint=(0.82, 0.93, 1.0), gain=0.6, contrast=3.0, flatten=0.0))),
    dict(slot=24, name="scree", role="loose", was="geo_scree", mat="gravel", scale=1.8, blend=1.2, rough=0.7,
         cc0=("Rocks006", G(sat=0.7, hold=(0.127, 0.110, 0.093)))),
    dict(slot=25, name="limestone", role="rock", was="geo_limestone", mat="limestone", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock051", G(sat=0.45, gain=1.6)), local=("Rock_04", G(sat=0.6))),
    dict(slot=26, name="sulfur", role="ore", was="geo_sulfur", mat="sulfur", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rock055", G(sat=1.2, contrast=1.1, hold=(0.179, 0.138, 0.027))),
         local=("Potato", G(sat=0.75, tint=(1.0, 0.92, 0.45), gain=0.85, contrast=1.3))),
    dict(slot=27, name="hematite", role="ore", was="geo_hematite", mat="hematite", scale=2.0, blend=0.8, rough=0.7,
         cc0=("Ground085", G(sat=1.2, tint=(1.0, 0.5, 0.35)))),
    dict(slot=28, name="tundra", role="veg", was="geo_tundra", mat="soil", scale=1.6, blend=1.2, rough=0.7,
         cc0=("Grass004", G(make="patchy", sat=0.55, tint=(1.0, 0.92, 0.7), contrast=1.2,
                            under=("Ground039", G(sat=0.45, tint=(1.0, 0.9, 0.75), gain=0.85)), cover=0.68)),
         local=("Dirty_Grass", G(sat=0.6))),
    dict(slot=29, name="pahoehoe", role="rock", was="geo_pahoehoe", mat="basalt", scale=1.25, blend=0.8, rough=0.7,
         cc0=("Rock041", G(sat=0.3, contrast=1.7, flatten=0.4, hold=(0.049, 0.051, 0.053)))),
    dict(slot=30, name="shale", role="rock", was="geo_shale", mat="shale", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock022", G(sat=0.3, contrast=1.15, hold=(0.168, 0.167, 0.162))), local=("Rock_03", G())),
    dict(slot=31, name="peat", role="veg", was="geo_peat", mat="soil", scale=1.4, blend=1.2, rough=0.7,
         cc0=("Rock063", G(sat=0.7, gain=0.55))),
    dict(slot=32, name="litter", role="veg", was="geo_litter", mat="soil", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Grass004", G(make="patchy", sat=0.85, gain=0.8, contrast=1.15,
                            under=("Ground085", G(sat=0.8, gain=0.85)), cover=0.5))),
    # 33+: the LIBRARY layers (worlds plan W1, §3.1): baked and committed, but on no palette
    # line yet (PALETTE_SLOTS). The planet generator lays them through wildcard slots
    # (terrain.setSlotMaterial on a picture-less line, W2) or a per-terrain palette (engine
    # slot-materials stage 5, W9). Numbers are stable names, not palette lines. Mostly
    # underground: cave walls, flowstone, frost, volcanic and evaporite rock, ore host rock.
    dict(slot=33, name="cavewall", role="cavewall", mat="limestone", scale=1.4, blend=0.8, rough=0.7, rfloor=0.45,
         cc0=("quarry_wall", G(sat=0.35, gain=0.8, contrast=1.35, flatten=0.5))),
    dict(slot=34, name="flowstone", role="flowstone", mat="limestone", scale=1.2, blend=1.0, rough=0.7, rfloor=0.3,
         cc0=("marble_cliff_05", G(sat=0.9, tint=(1.0, 0.86, 0.66), gain=0.95, flatten=0.4))),
    dict(slot=35, name="dripstone", role="flowstone", mat="limestone", scale=1.3, blend=1.0, rough=0.7, rfloor=0.22,
         cc0=("marble_rock_01", G(sat=0.5, tint=(1.0, 0.95, 0.86), gain=0.9))),
    dict(slot=36, name="soot", role="cavewall", mat="basalt", scale=1.4, blend=0.8, rough=0.7,
         cc0=("quarry_wall_02", G(make="soot", cover=0.7))),
    dict(slot=37, name="frost", role="snow", mat="ice", scale=1.4, blend=1.6, rough=0.7, rfloor=0.35,
         cc0=("Snow013", G(sat=0.5, tint=(0.92, 0.97, 1.0), contrast=1.2))),
    dict(slot=38, name="tuff", role="volcanic", mat="basalt", scale=1.5, blend=0.8, rough=0.7,
         cc0=("rock_05", G(sat=0.45, tint=(1.0, 0.86, 0.78), gain=1.3))),
    dict(slot=39, name="columnar", role="volcanic", mat="basalt", scale=1.0, blend=0.8, rough=0.7, antitile=0.3,
         cc0=("Rock050", G(make="columnar", cells=6))),
    dict(slot=40, name="halite", role="evaporite", mat="salt", scale=1.2, blend=1.2, rough=0.7, rfloor=0.4,
         cc0=("mud_cracked_dry_03", G(sat=0.1, tint=(1.0, 0.97, 0.93), gain=2.2, contrast=0.8))),
    dict(slot=41, name="clearice", role="ice", mat="ice", scale=1.0, blend=1.6, rough=0.7, rfloor=0.12,
         cc0=("Snow006", G(sat=1.0, tint=(0.72, 0.88, 1.0), gain=0.8, contrast=1.8, flatten=0.3))),
    dict(slot=42, name="gossan", role="ore", mat="hematite", scale=1.6, blend=0.8, rough=0.7,
         cc0=("Rock056", G(make="gossan", cover=0.75))),
    dict(slot=43, name="pitchblende", role="ore", mat="uranium", scale=1.6, blend=0.8, rough=0.7, rfloor=0.3,
         cc0=("Rock048", G(make="pitchblende"))),
    dict(slot=44, name="redbeds", role="rock", mat="sandstone", scale=1.2, blend=0.8, rough=0.7, antitile=0.25,
         cc0=("cliff_side", G(sat=1.0, flatten=0.5))),
    dict(slot=45, name="mudstone", role="rock", mat="shale", scale=1.5, blend=0.8, rough=0.7, antitile=0.3,
         cc0=("Ground105", G(sat=0.15, gain=0.85))),
    dict(slot=46, name="chalk", role="rock", mat="limestone", scale=1.4, blend=0.8, rough=0.7,
         cc0=("Rock018", G(sat=0.4))),
    dict(slot=47, name="clinker", role="volcanic", mat="basalt", scale=1.6, blend=1.0, rough=0.7,
         cc0=("rocks_ground_09", G(sat=0.4, tint=(1.0, 0.8, 0.7), gain=0.45, contrast=1.3))),
    dict(slot=48, name="obsidian", role="volcanic", mat="obsidian", scale=1.3, blend=0.8, rough=0.7, rfloor=0.12,
         cc0=("dark_rock_02", G(sat=0.1, gain=0.35, contrast=1.4))),
    dict(slot=49, name="scoria", role="volcanic", mat="basalt", scale=1.5, blend=0.8, rough=0.7,
         cc0=("rock_06", G(sat=0.6, tint=(1.0, 0.6, 0.5), gain=0.45, contrast=1.2))),
    dict(slot=50, name="schist", role="rock", mat="slate", scale=1.5, blend=0.8, rough=0.7,
         cc0=("Rock045", G(sat=0.6))),
    dict(slot=51, name="gneiss", role="rock", mat="granite", scale=1.3, blend=0.8, rough=0.7, antitile=0.4,
         cc0=("marble_cliff_04", G(sat=0.6, flatten=0.4))),
    dict(slot=52, name="marble", role="rock", mat="limestone", scale=1.4, blend=0.8, rough=0.7, rfloor=0.4,
         cc0=("marble_rock_02", G(sat=0.35, gain=1.1))),
    dict(slot=53, name="blacksand", role="sand", mat="sand", scale=2.0, blend=1.2, rough=0.7,
         cc0=("dense_sand", G(sat=0.15, gain=0.32, contrast=1.4, ripples=dict(count=14, amp=0.14)))),
    dict(slot=54, name="redregolith", role="loose", mat="regolith", scale=2.0, blend=1.2, rough=0.7,
         cc0=("gravelly_sand", G(sat=0.75, tint=(1.0, 0.62, 0.45), contrast=1.3))),
    dict(slot=55, name="loess", role="loose", mat="soil", scale=2.0, blend=1.2, rough=0.7,
         cc0=("Ground102", G(sat=0.8))),
    dict(slot=56, name="laggravel", role="loose", mat="gravel", scale=1.8, blend=1.2, rough=0.7,
         cc0=("sandy_gravel_02", G(sat=0.8, gain=0.8, contrast=1.5, flatten=0.5))),
    dict(slot=57, name="dirtyice", role="ice", mat="ice", scale=1.2, blend=1.6, rough=0.7, rfloor=0.25,
         cc0=("Snow012", G(sat=0.45, gain=0.85, contrast=0.55, flatten=0.8))),
    dict(slot=58, name="firn", role="snow", mat="ice", scale=1.6, blend=2.5, rough=0.7,
         cc0=("snow_02", G(contrast=1.2))),
    dict(slot=59, name="sulfurvein", role="ore", mat="sulfur", scale=1.5, blend=0.8, rough=0.7,
         cc0=("rock_05", G(make="sulfurvein", cover=0.35))),
    dict(slot=60, name="quartzdruzy", role="crystal", mat="quartz", scale=1.3, blend=0.8, rough=0.9, rfloor=0.12,
         cc0=("Rock048", G(make="crystal", tint=(0.80, 0.80, 0.78), pale=(0.86, 0.86, 0.84), seed=60))),
    # worlds W3: the lead-zinc ore (materials.lua galena), galena cubes and sphalerite in limestone
    dict(slot=61, name="galena", role="ore", mat="galena", scale=1.4, blend=0.8, rough=0.7, rfloor=0.25,
         cc0=("Rock051", G(make="galena", cover=0.55))),
]
# Palette lines: slots 1..PALETTE_SLOTS go to terrain/system.palette; the rest are the library.
PALETTE_SLOTS = 32
# The wildcard slots (scripts/geology.lua WILD; none has a `local` version): their
# system.palette lines carry flags and a height map but no picture. Keep the two in step.
WILDCARD_SLOTS = (4, 10, 11, 12, 21, 29, 31, 32)
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
    ("color", r"(_Color|_basecolor|_ALBEDO|_albedo|_diff_\dk)\.(png|jpe?g)$"),
    ("diff", r"_DIFF\.(png|jpe?g)$"),
    ("normal_gl", r"(_NormalGL|_nor_gl_\dk)\.png$"),
    ("normal_dx", r"(_NormalDX|_nor_dx_\dk)\.png$"),
    ("normal", r"(_normal|_NRM|_NRML)\.(png|jpe?g)$"),
    ("rough", r"(_Roughness|_RGH|_rough_\dk)\.(png|jpe?g)$"),
    ("spec", r"_SPEC\.(png|jpe?g)$"),
    ("metal", r"(_Metalness|_metallic|_MTL)\.(png|jpe?g)$"),
    ("ao", r"(_AmbientOcclusion|_ambientocclusion|_OCC|_ao_\dk)\.(png|jpe?g)$"),
    ("height", r"(_Displacement|_height|_DISP|_Height|_disp_\dk)\.(png|jpe?g)$"),
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
    return "CC0" if re.search(r"_2K-PNG", item) or item.startswith(PH_DIR + "/") else "commercial"


def fmt_of(item):
    if item.startswith(PH_DIR + "/"):
        return "polyhaven"
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


# Poly Haven (CC0): a library's ph/<asset>/ folder holds the asset's 2k PNG maps as Poly Haven
# names them (<asset>_diff_2k.png, _nor_gl_2k, _rough_2k, _disp_2k, _ao_2k). The set id is the
# asset's name (dark_rock).
PH_DIR = "ph"


def _members(names):
    members = {}
    for key, rx in MAPS:
        hits = [n for n in names if re.search(rx, os.path.basename(n), re.I)]
        # Older sets ship a _DIFF2 / _DISP2 / _RGH_Dirty beside the main one: prefer the plain name.
        hits.sort(key=len)
        if hits and key not in members:
            members[key] = hits[0]
    return members


def scan_ph(lib, sets, extra):
    d = os.path.join(lib, PH_DIR)
    if not os.path.isdir(d):
        return
    for aid in sorted(os.listdir(d)):
        ad = os.path.join(d, aid)
        if not os.path.isdir(ad):
            continue
        names = sorted(f for f in os.listdir(ad) if f.lower().endswith((".png", ".jpg", ".jpeg")))
        if not names:
            continue
        sid = re.sub(r"[^A-Za-z0-9_-]+", "_", aid).strip("_")
        sts = [os.stat(os.path.join(ad, f)) for f in names]
        item = PH_DIR + "/" + aid
        sets[sid] = dict(id=sid, item=item, note="", licence=licence_of(item), format="polyhaven", kind=kind_of(sid),
                         members=_members(names), size=sum(x.st_size for x in sts), mtime=int(max(x.st_mtime for x in sts)),
                         lib=lib, extra=extra)


def scan(lib, extra=False):
    """The sets of one library folder. `extra`: a library of CC0 sets fetched for the terrain
    (EXTRA_LIBS): only their terrain layers are baked (no sets/<id>/ folder), which keeps the
    public repo small."""
    sets = {}
    scan_ph(lib, sets, extra)
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
            members = _members(names)
        else:
            members["color"] = None
        lic = licence_of(item)
        kind = kind_of(sid)
        sets[sid] = dict(id=sid, item=item, note=note, licence=lic, format=fmt_of(item), kind=kind,
                         members=members, size=st.st_size, mtime=int(st.st_mtime), lib=lib, extra=extra)
    return sets


def scan_all(lib, extra_libs):
    """The main library and the fetched CC0 ones; a set id found twice keeps the main one."""
    sets = {}
    for xl in extra_libs:
        if os.path.isdir(xl):
            sets.update(scan(xl, extra=True))
    if os.path.isdir(lib):
        sets.update(scan(lib))
    return sets


def read_map(lib, s, key):
    lib = s.get("lib", lib)
    p = os.path.join(lib, s["item"])
    m = s["members"].get(key, "missing")
    if m == "missing":
        return None
    if s["format"] == "polyhaven":
        return to_float(Image.open(os.path.join(p, m)))
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


_RELIEF = [1.0]   # the share of the baked relief grade() lays (1, or RELIEF_MAPPED)


def ripple_field(N, rp):
    """The wind ripples' field on an N-square tile: (height, its slope along the
    rows' phase, fade), all tileable. The ripples run across the rows: an
    integer count down the tile, the phase bent by wrap noise."""
    rng = np.random.default_rng(11)
    warp = blur_wrap(rng.standard_normal((N, N)), N / 10)
    warp = warp / (warp.std() + 1e-9)
    fine = blur_wrap(rng.standard_normal((N, N)), N / 60)
    fine = fine / (fine.std() + 1e-9)
    yy = np.arange(N)[:, None] / N
    phase = 2 * np.pi * (rp["count"] * yy + rp.get("bend", 0.25) * warp + 0.05 * fine)
    # h = sin + a quarter of the second harmonic: a long stoss slope, a short lee;
    # dh its slope (shaded by it: light across the ripples), faded in and out by noise
    h = np.sin(phase) + 0.25 * np.sin(2 * phase)
    dh = np.cos(phase) + 0.5 * np.cos(2 * phase)
    fade = np.clip(0.65 + 0.35 * fine, 0.2, 1.0)
    return h, dh, fade


def grade(alb, n, ao, g):
    """The plain layer bake, in linear light."""
    c = alb.copy()
    # Relief baked into the colour: AO and the normal's tilt, darkening. A slot
    # with surface maps keeps only RELIEF_MAPPED of it (_RELIEF; see bake_layer).
    r = _RELIEF[0]
    k_ao, k_cav = g.get("ao", 0.6) * r, g.get("cav", 0.5) * r
    c *= (1 - k_ao) + k_ao * ao[..., None]
    if n is not None:
        tilt = np.clip(n[..., 2], 0, 1)
        c *= ((1 - k_cav) + k_cav * tilt ** 2)[..., None]
    # Wind ripples (sand): none of the library's sands has them, and on a dune
    # world they are what says "sand" from ten metres. A tileable ripple field
    # (an integer count across the tile, its phase bent by wrap noise) shaded as
    # relief: the lee slopes darker, the crests a little lighter.
    rp = g.get("ripples")
    if rp:
        _, dh, fade = ripple_field(c.shape[0], rp)
        shade = 1 + rp.get("amp", 0.1) * r * dh / 1.5 * fade
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


def make_copper(alb, n, ao, g):
    """Slot 5, copper's vein stone (materials.VEIN_SLOTS copper): Rock058 graded to a grey host rock,
    broadly stained with the copper carbonates (malachite green, azurite-leaning blue-green, as
    materials ORE.copper: seam 0.24,0.56,0.44, stain 0.34,0.60,0.48) over `cover` of the tile, its own
    warm veins kept as copper-oxide orange with a rusty halo. The stains follow the veins (they are
    where the water ran) and broad wrap noise, so a seam reads as copper from mining distance, not as
    hairlines on grey (playtest 2026-11-04: copper couldn't be found)."""
    N = alb.shape[0]
    rng = np.random.default_rng(505)
    rock = grade(alb, n, ao, dict(sat=0.3, flatten=0.6)) * 1.25
    L = np.maximum(lum(rock), 1e-4)
    detail = np.clip(L / L.mean(), 0.45, 1.6)[..., None]          # the rock's grain, kept under the stain
    r, gg, b = alb[..., 0], alb[..., 1], alb[..., 2]
    warm = np.clip((r - b) / np.maximum(r + gg + b, 1e-4) * 3.0, 0, 1)
    bright = np.clip(lum(alb) / max(1e-4, np.percentile(lum(alb), 97)), 0, 1)
    vein = np.clip((warm * bright - 0.05) * 6.0, 0, 1)
    vein = np.maximum(vein, blur_wrap(vein, 3.0) * 0.8)

    def noise(sigma):
        f = blur_wrap(rng.standard_normal((N, N)), sigma)
        return (f - f.mean()) / (f.std() + 1e-9)
    field = noise(N / 9) * 0.8 + noise(N / 30) * 0.35 + blur_wrap(vein, N / 40) / (blur_wrap(vein, N / 40).std() + 1e-9) * 0.6
    thr = np.percentile(field, 100 * (1 - g.get("cover", 0.42)))
    stain = np.clip((field - thr) * 2.2, 0, 1)
    stain = stain * (0.75 + 0.25 * np.clip(noise(N / 80) * 0.5 + 0.5, 0, 1))  # patchy within
    hue = np.clip(noise(N / 14) * 0.5 + 0.5, 0, 1)[..., None]
    green = srgb_to_lin(np.array([0.24, 0.56, 0.44], np.float32))
    stain_c = srgb_to_lin(np.array([0.34, 0.60, 0.48], np.float32))
    azure = srgb_to_lin(np.array([0.18, 0.48, 0.56], np.float32))
    oxide = srgb_to_lin(np.array([0.66, 0.33, 0.13], np.float32))
    col = green * (1 - hue) + azure * hue * 0.6 + stain_c * hue * 0.4
    col = col * detail * 1.1
    c = rock * (1 - stain[..., None]) + col * stain[..., None]
    halo = np.clip(blur_wrap(vein, 6.0) * 1.8, 0, 1)[..., None] * 0.55
    c = c * (1 - halo) + oxide * detail * halo
    m = vein[..., None]
    c = c * (1 - m) + oxide * 1.25 * m
    return np.clip(c, 0, 1)


def _worley(N, cells, rng):
    """Tileable jittered-grid Voronoi on an N-square: for each pixel the nearest
    seed's cell id, the distances to the nearest and second-nearest seed (pixels)
    and the offset (dx, dy) from the nearest seed. One seed a grid cell, searched
    over the 3x3 cells round each pixel's own, on the torus."""
    cs = N / cells
    jit = rng.random((cells, cells, 2))
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) + 0.5
    ci, cj = np.floor(yy / cs).astype(int), np.floor(xx / cs).astype(int)
    d1 = np.full((N, N), np.inf, np.float32)
    d2 = np.full((N, N), np.inf, np.float32)
    cid = np.zeros((N, N), int)
    ox = np.zeros((N, N), np.float32)
    oy = np.zeros((N, N), np.float32)
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            gi, gj = ci + di, cj + dj
            wi, wj = gi % cells, gj % cells
            sy = (gi + jit[wi, wj, 0]) * cs
            sx = (gj + jit[wi, wj, 1]) * cs
            dy, dx = yy - sy, xx - sx
            d = np.sqrt(dx * dx + dy * dy)
            closer = d < d1
            d2 = np.where(closer, d1, np.minimum(d2, d))
            d1 = np.where(closer, d, d1)
            cid = np.where(closer, wi * cells + wj, cid)
            ox = np.where(closer, dx, ox)
            oy = np.where(closer, dy, oy)
    return cid, d1, d2, ox, oy


def crystal_fields(alb, n, ao, g):
    """A crystal seam as it is in the rock (slots 7 and 8; playtest 2026-11-06): druzy
    crystal (a crust of small terminations with a few big points through it) grown
    in vugs of a dark host rock (the set's own stone, graded to a basaltic grey),
    the host stained round the vugs. Every crystal is a Voronoi cell with a
    pyramidal tip: its faces (3-6, a random turn) tilt away from its apex, each
    face its own flat normal, so a lamp catches some faces and not others. The
    colour is zoned like amethyst: deep at the tips, paler and milky toward each
    crystal's base, each crystal its own shade; the grain stays at every scale.
    Tileable throughout. → colour (linear), normal (-1..1), ORM, height, all N-square."""
    N = alb.shape[0]
    rng = np.random.default_rng(int(g.get("seed", 7)) * 7919 + 11)
    tint = srgb_to_lin(np.array(g.get("tint", (0.42, 0.20, 0.62)), np.float32))
    pale = srgb_to_lin(np.array(g.get("pale", (0.80, 0.76, 0.84)), np.float32))

    def noise(sigma):
        f = blur_wrap(rng.standard_normal((N, N)), sigma)
        return (f - f.mean()) / (f.std() + 1e-9)

    # the host rock: the set's stone, dark and nearly grey, its own grain kept
    host = grade(alb, n, ao, dict(sat=0.3, flatten=0.5))
    host = host * (0.075 / max(1e-4, float(lum(host).mean())))
    hn = n if n is not None else np.dstack([np.zeros((N, N)), np.zeros((N, N)), np.ones((N, N))])

    # where the crystal grew: vugs from tileable noise, ~58 % of the tile, edged by grain
    field = noise(N / 7) * 0.75 + noise(N / 22) * 0.4 + noise(N / 70) * 0.15
    thr = np.percentile(field, 100 * (1 - g.get("cover", 0.58)))

    col = host.copy()
    nrm = hn.copy()
    rough = np.full((N, N), 0.88, np.float32)
    occ = np.clip(ao, 0, 1).astype(np.float32).copy()
    hgt = np.clip(0.25 + 0.1 * noise(N / 40), 0, 1)
    covered = np.zeros((N, N), bool)
    # two generations: big points first, then the druzy crust between them
    for cells, keep, lift in ((14, 0.4, 1.0), (46, 1.0, 0.6)):
        cid, d1, d2, ox, oy = _worley(N, cells, rng)
        ncell = cells * cells
        cshade = rng.uniform(0.3, 1.3, ncell)[cid] * (0.75 + 0.25 * np.clip(noise(N / 10) * 0.5 + 0.5, 0, 1))  # each crystal its own depth of colour, in broad zones
        chue = rng.uniform(-1, 1, ncell)[cid]              # and a small shift of hue
        nface = rng.integers(3, 7, ncell)[cid]
        turn = rng.uniform(0, 2 * np.pi, ncell)[cid]
        tilt = rng.uniform(0.35, 0.75, ncell)[cid]          # how steep its faces (tan)
        # a crystal of this generation stands here if the vug field holds it at its
        # seed (sampled through the cell's own id: its whole body in or out)
        seedfield = np.zeros(ncell, np.float32)
        np.maximum.at(seedfield, cid.ravel(), np.where(d1.ravel() < 2.0, field.ravel(), -9))
        here = (seedfield[cid] > thr) & (rng.random(ncell)[cid] < keep) & ~covered
        if lift < 1.0:
            here = (field > thr - 0.15) & ~covered                     # the crust fills the vugs
        cs = N / cells
        r = np.clip(d1 / (0.5 * (d1 + d2) + 1e-6), 0, 1)              # 0 at the apex, 1 at the crystal's edge
        # the face this pixel is on: its angle about the apex, in nface sectors
        ang = np.arctan2(oy, ox) - turn
        sector = np.floor((ang % (2 * np.pi)) / (2 * np.pi) * nface)
        mid = (sector + 0.5) / nface * 2 * np.pi + turn
        fx, fy = np.cos(mid) * tilt, np.sin(mid) * tilt
        fn = np.dstack([fx, -fy, np.ones((N, N))])
        fn /= np.linalg.norm(fn, axis=2, keepdims=True)
        # colour: zoned (deep at the tip, milky at the base), each crystal its own
        zone = np.clip(1.0 - r ** 2.6, 0, 1)
        deep = tint[None, None, :] * (0.35 + 0.9 * cshade[..., None]) \
            * (1 + 0.18 * chue[..., None] * np.array([1.0, -0.4, -0.8], np.float32))
        c = pale[None, None, :] * 0.16 * (1 - zone[..., None]) + deep * zone[..., None]
        # inclusions and fractures inside the crystal, and its own faint grain
        c *= (0.86 + 0.14 * np.clip(noise(1.4) * 0.5 + 0.5, 0, 1))[..., None]
        c *= (0.9 + 0.1 * np.cos(sector * 2.1 + chue * 3))[..., None]
        # the seams between crystals are dark and shadowed
        seam = np.clip((d2 - d1) / (0.06 * cs + 1.0), 0, 1)
        c *= (0.35 + 0.65 * seam ** 0.6)[..., None]
        m = here[..., None]
        col = np.where(m, c, col)
        nrm = np.where(m, fn, nrm)
        rough = np.where(here, 0.16 + 0.12 * rng.random(ncell)[cid] + (1 - seam) * 0.4, rough)
        occ = np.where(here, np.clip(0.55 + 0.45 * seam, 0, 1), occ)
        hgt = np.where(here, np.clip(0.35 + lift * 0.6 * (1 - r) * seam, 0, 1), hgt)
        covered |= here
    # the host rock round each vug: stained (iron, the fluids the crystal grew from)
    # and shadowed at the lip, so the crystal sits IN the rock rather than on it
    cov = covered.astype(np.float32)
    halo = np.clip(blur_wrap(cov, N / 90) * 1.6, 0, 1) * (1 - cov)
    stain = srgb_to_lin(np.array((0.36, 0.24, 0.16), np.float32))
    col = col * (1 - 0.35 * halo[..., None]) + stain[None, None, :] * 0.12 * halo[..., None]
    lip = np.clip(blur_wrap(cov, 1.6) - cov, 0, 1) * 2.5
    col *= (1 - 0.5 * np.clip(lip, 0, 1))[..., None]
    occ = occ * (1 - 0.4 * np.clip(lip, 0, 1))
    # the faces' light baked in, most of it: the Classic-lit terrain turns a normal
    # map's faces only a little (seen in the 2026-11-06 shots: flat purple), and
    # far off the mips average the faces and only this keeps the crystal's texture.
    # Each face lit from a soft sky and a key, so neighbouring faces differ.
    rel = max(_RELIEF[0], 0.75)
    lights = [np.array(v, np.float32) / np.linalg.norm(v) for v in ((0.45, 0.5, 0.74), (-0.6, -0.2, 0.77), (0.1, -0.7, 0.7))]
    face = sum(np.clip((nrm * l).sum(axis=2), 0, 1) ** p * w for l, p, w in zip(lights, (3, 2, 2), (0.6, 0.3, 0.2)))
    glint = sum(np.clip((nrm * l).sum(axis=2), 0, 1) ** 24 * w for l, w in zip(lights, (0.5, 0.25, 0.15)))
    k = (1 - rel) + rel * (0.35 + 0.9 * face)
    col = col * np.where(cov > 0.5, k, 1.0)[..., None] + (glint * cov * rel)[..., None] * (0.5 * tint + 0.08)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=2, keepdims=True), 1e-6)
    orm = np.dstack([occ, np.clip(rough, 0, 1), np.zeros((N, N), np.float32)])
    return np.clip(col, 0, 1), nrm, orm, np.clip(hgt, 0, 1)


def make_crystal(alb, n, ao, g):
    """The crystal seam's colour (crystal_fields)."""
    return crystal_fields(alb, n, ao, g)[0]


def make_patchy(alb, n, ao, g, sets, mask_only=False):
    """A cover worn through in patches to the ground under it (tundra: dry sedge over
    stony soil): a lawn-like cover alone is one flat colour from ten metres. The patch
    mask is tileable noise at a third of the tile, edged by the cover's own luminance
    so the boundary follows the blades, not a smooth curve. `mask_only`: the mask
    (1 = cover), for the slot's surface maps."""
    top = grade(alb, n, ao, g)
    rng = np.random.default_rng(7)
    a = blur_wrap(rng.standard_normal(alb.shape[:2]), alb.shape[0] / 30)
    b = blur_wrap(rng.standard_normal(alb.shape[:2]), alb.shape[0] / 90)
    noise = a / (a.std() + 1e-9) + 0.6 * b / (b.std() + 1e-9)
    noise = (noise - noise.mean()) / (noise.std() + 1e-6)
    L = lum(top)
    edge = (L - L.mean()) / (L.std() + 1e-6)
    thr = np.quantile(noise, 1 - g.get("cover", 0.6))
    m = np.clip((noise - thr) * 3.0 + edge * 0.6 + 0.5, 0, 1)[..., None]
    if mask_only:
        return m[..., 0]
    us, ug = g["under"]
    ualb, un, uao, _ = load_for_layer(LIB_PATH[0], sets[us])
    bot = grade(ualb, un, uao, ug)
    return np.clip(top * m + bot * (1 - m), 0, 1)


def _noise(N, rng, sigma):
    f = blur_wrap(rng.standard_normal((N, N)), sigma)
    return (f - f.mean()) / (f.std() + 1e-9)


def _streak(a, length):
    """Smear a tileable map down the rows (a box of `length` rows, wrapping): runs and drips."""
    out = np.zeros_like(a)
    for k in range(int(length)):
        out += np.roll(a, k, axis=0)
    return out / max(1, int(length))


def _grain(rock):
    L = np.maximum(lum(rock), 1e-4)
    return np.clip(L / L.mean(), 0.45, 1.6)[..., None]


def make_soot(alb, n, ao, g):
    """Soot and black crust on a cave or vent wall (library layer 36): the host rock graded grey,
    coated over `cover` of the tile by a matte black film that runs in streaks down the face and
    sits thickest in the hollows (the set's AO), the rock's grain kept under it so it reads as a
    coating, not paint. A few bare ribs show the rock through."""
    N = alb.shape[0]
    rng = np.random.default_rng(36)
    rock = grade(alb, n, ao, dict(sat=0.2, flatten=0.6)) * 0.7
    grain = _grain(rock)
    streaks = _streak(_noise(N, rng, 2.0), N / 6)
    streaks = streaks / (streaks.std() + 1e-9)
    field = _noise(N, rng, N / 14) * 0.6 + _noise(N, rng, N / 40) * 0.4 + streaks * 0.5 + (1 - ao) * 2.0
    thr = np.percentile(field, 100 * (1 - g.get("cover", 0.7)))
    s = (np.clip((field - thr) * 0.9, 0, 1) * 0.85)[..., None]
    soot = srgb_to_lin(np.array([0.14, 0.13, 0.12], np.float32)) * grain
    return np.clip(rock * (1 - s) + soot * s, 0, 1)


def make_gossan(alb, n, ao, g):
    """Gossan (library layer 42): the rusty cap rock over a weathered sulphide body, iron's
    prospecting sign. The host rock (the set's own) leached pale, then stained over `cover` of the
    tile by hematite red, goethite ochre and limonite yellow-brown in broad patches, with dark
    boxwork (the cell walls left where the sulphide grains dissolved) through the strongest."""
    N = alb.shape[0]
    rng = np.random.default_rng(42)
    rock = grade(alb, n, ao, dict(sat=0.25, flatten=0.6)) * 1.1
    grain = _grain(rock)
    field = _noise(N, rng, N / 16) * 0.8 + _noise(N, rng, N / 45) * 0.5 + (1 - ao) * 0.8
    thr = np.percentile(field, 100 * (1 - g.get("cover", 0.75)))
    st = np.clip((field - thr) * 1.1, 0, 1) * 0.9
    hue = np.clip(_noise(N, rng, N / 12) * 0.5 + 0.5, 0, 1)[..., None]
    hem = srgb_to_lin(np.array([0.46, 0.13, 0.06], np.float32))
    goe = srgb_to_lin(np.array([0.70, 0.42, 0.14], np.float32))
    lim = srgb_to_lin(np.array([0.58, 0.44, 0.22], np.float32))
    col = hem * (1 - hue) ** 2 + goe * 2 * hue * (1 - hue) + lim * hue ** 2
    c = rock * (1 - st[..., None]) + col * grain * st[..., None]
    _, d1, d2, _, _ = _worley(N, 22, rng)
    wall = np.clip(1 - (d2 - d1) / 2.5, 0, 1) * np.clip(st * 1.5 - 0.5, 0, 1)
    c *= (1 - 0.6 * wall)[..., None]
    return np.clip(c, 0, 1)


def make_sulfurvein(alb, n, ao, g):
    """Native sulfur along fractures (library layer 59): the host rock graded to a grey, its
    cracks (Voronoi fracture lines and the set's own deepest hollows) filled with yellow sulfur
    crust, a pale efflorescence bloom (white sulfates) feathering out from each, and a few broad
    crust patches over `cover` of the tile."""
    N = alb.shape[0]
    rng = np.random.default_rng(59)
    rock = grade(alb, n, ao, dict(sat=0.2, flatten=0.6)) * 0.95
    grain = _grain(rock)
    _, d1, d2, _, _ = _worley(N, 9, rng)
    warp = _noise(N, rng, N / 40)
    crack = np.clip(1 - (d2 - d1 + warp * 2.0) / 3.0, 0, 1) ** 2
    crack = np.maximum(crack, np.clip((0.55 - ao) * 3, 0, 1))
    patch = _noise(N, rng, N / 10) + _noise(N, rng, N / 40) * 0.4
    patch = np.clip((patch - np.percentile(patch, 100 * (1 - g.get("cover", 0.35)))) * 0.9, 0, 1)
    vein = np.clip(np.maximum(crack, patch * 0.7), 0, 1) * np.clip(0.55 + 0.6 * _noise(N, rng, 3.0) * 0.5 + 0.25, 0, 1)
    bloom = np.clip(blur_wrap(vein, 6.0) * 1.6 - vein, 0, 1) * 0.6
    yel = srgb_to_lin(np.array([0.80, 0.70, 0.24], np.float32))
    wht = srgb_to_lin(np.array([0.90, 0.88, 0.80], np.float32))
    c = rock * (1 - bloom[..., None]) + wht * grain * 0.8 * bloom[..., None]
    c = c * (1 - vein[..., None]) + yel * np.clip(grain, 0.55, 1.5) * vein[..., None]
    return np.clip(c, 0, 1)


def make_pitchblende(alb, n, ao, g):
    """Pitchblende (uraninite, library layer 43): black, pitchy, botryoidal (round clustered
    knobs, each lit on its upper side and shining a little at its crown) in a dark host rock,
    with sparse yellow-green flecks of autunite and orange-yellow gummite where it weathers.
    Realistic: it does NOT glow (worlds plan §3.4; the dosimeter finds it)."""
    N = alb.shape[0]
    rng = np.random.default_rng(43)
    host = grade(alb, n, ao, dict(sat=0.2, flatten=0.5))
    host = host * (0.06 / max(1e-4, float(lum(host).mean())))
    _, d1, d2, ox, oy = _worley(N, 28, rng)
    r = np.clip(d1 / (0.5 * (d1 + d2) + 1e-6), 0, 1)
    dome = np.sqrt(np.clip(1 - r ** 2, 0, 1))
    lit = np.clip(0.5 - oy / (N / 28) * 0.8, 0, 1)
    body = np.clip(_noise(N, rng, N / 14) * 0.5 + _noise(N, rng, N / 40) * 0.4 + (1 - ao) * 0.8 + 0.3, 0, 1) ** 1.5
    pitch = srgb_to_lin(np.array([0.07, 0.07, 0.065], np.float32))
    c_b = pitch * (0.55 + 0.6 * dome * (0.5 + lit))[..., None] + (dome ** 12 * 0.06)[..., None]
    c = host * (1 - body[..., None]) + c_b * body[..., None]
    fleck = np.clip((_noise(N, rng, 1.6) - 2.6) * 2.0, 0, 1) * np.clip(_noise(N, rng, N / 14) + 0.3, 0, 1)
    aut = srgb_to_lin(np.array([0.72, 0.80, 0.22], np.float32))
    gum = srgb_to_lin(np.array([0.85, 0.55, 0.12], np.float32))
    mix = np.clip(_noise(N, rng, N / 20) * 0.5 + 0.5, 0, 1)[..., None]
    fc = aut * (1 - mix) + gum * mix
    c = c * (1 - fleck[..., None]) + fc * 0.8 * fleck[..., None]
    return np.clip(c, 0, 1)


def make_columnar(alb, n, ao, g):
    """Columnar basalt seen end-on (library layer 39): the set's basalt cut into 5-7-sided
    column tops (Voronoi cells, `cells` across the tile, ~0.75 m at scale 1), each column its own
    shade and a slight tilt of light, the joints between them dark and a little rusty."""
    N = alb.shape[0]
    rng = np.random.default_rng(39)
    rock = grade(alb, n, ao, dict(sat=0.25, flatten=0.6))
    cells = int(g.get("cells", 6))
    cid, d1, d2, ox, oy = _worley(N, cells, rng)
    shade = rng.uniform(0.75, 1.2, cells * cells)[cid]
    tilt = (ox * rng.uniform(-1, 1, cells * cells)[cid] + oy * rng.uniform(-1, 1, cells * cells)[cid]) / (N / cells)
    c = rock * (shade * (1 + 0.12 * tilt))[..., None]
    joint = np.clip(1 - (d2 - d1) / (N / cells * 0.06 + 1.0), 0, 1)
    rust = srgb_to_lin(np.array([0.20, 0.12, 0.08], np.float32)) * 0.4
    c = c * (1 - joint[..., None] * 0.85) + rust * joint[..., None] * 0.3
    return np.clip(c, 0, 1)


def make_galena(alb, n, ao, g):
    """Galena with sphalerite (lead-zinc ore, library layer 61; worlds W3): a Mississippi-Valley
    replacement body in grey carbonate host. Galena grows as CUBES: each crystal is a square
    (a rotated Chebyshev cell) of lead-grey metal whose three visible faces take three shades, the
    lit one bright with a metallic sheen and fine stepped cleavage lines; resinous yellow-brown to
    black sphalerite fills between clusters, and white sparry calcite gangue rims each cube. The
    host (the set's own limestone) is graded to a cool grey. Ore covers `cover` of the tile."""
    N = alb.shape[0]
    rng = np.random.default_rng(61)
    host = grade(alb, n, ao, dict(sat=0.15, flatten=0.6)) * 0.95
    grain = _grain(host)
    body = _noise(N, rng, N / 14) * 0.7 + _noise(N, rng, N / 40) * 0.5 + (1 - ao) * 0.6
    thr = np.percentile(body, 100 * (1 - g.get("cover", 0.55)))
    ore = np.clip((body - thr) * 1.4, 0, 1)
    # cubes: one seed per grid cell, each a square turned by its own angle, the nearest square
    # (Chebyshev distance in its own frame) owning the pixel
    cells = int(g.get("cells", 22))
    cs = N / cells
    jit = rng.random((cells, cells, 2))
    ang = rng.uniform(0, np.pi / 2, (cells, cells))
    size = (rng.uniform(0.22, 0.6, (cells, cells)) ** 1.3 / 0.6 ** 0.3) * cs
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) + 0.5
    ci, cj = np.floor(yy / cs).astype(int), np.floor(xx / cs).astype(int)
    best = np.full((N, N), np.inf, np.float32)
    face = np.zeros((N, N), int)
    edge = np.zeros((N, N), np.float32)
    step = np.zeros((N, N), np.float32)
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            gi, gj = ci + di, cj + dj
            wi, wj = gi % cells, gj % cells
            sy = (gi + jit[wi, wj, 0]) * cs
            sx = (gj + jit[wi, wj, 1]) * cs
            dy, dx = yy - sy, xx - sx
            a = ang[wi, wj]
            u = dx * np.cos(a) + dy * np.sin(a)
            v = -dx * np.sin(a) + dy * np.cos(a)
            d = np.maximum(np.abs(u), np.abs(v)) / size[wi, wj]
            closer = d < best
            best = np.where(closer, d, best)
            # a cube seen from above and a little aside: its top face, and two strips of
            # side face along two edges (one lit, one in shade), `k` of its width
            k = 0.18 + 0.22 * jit[wi, wj, 0]
            un, vn = u / size[wi, wj], v / size[wi, wj]
            f = np.where(un > 1 - 2 * k, 2, np.where(vn < -1 + 2 * k, 1, 0))
            face = np.where(closer, f, face)
            st = np.abs(np.sin((u + v) * 0.9 + a * 7.0))
            step = np.where(closer, st, step)
            edge = np.where(closer, np.clip((d - 0.86) / 0.14, 0, 1), edge)
    cube = (best < 1.0) & (ore > 0.25)
    rim = ((best >= 1.0) & (best < 1.25) & (ore > 0.25)).astype(np.float32)
    tones = srgb_to_lin(np.array([[0.58, 0.59, 0.62], [0.44, 0.45, 0.48], [0.24, 0.25, 0.28]], np.float32))
    lit = (0.85 + 0.3 * rng.random((cells, cells)))[ci % cells, cj % cells]
    gal = tones[face] * (0.9 + 0.12 * (step > 0.96))[..., None] * lit[..., None]
    gal = gal * (1 - 0.55 * edge)[..., None]
    sph_mix = np.clip(_noise(N, rng, N / 24) * 0.5 + 0.5, 0, 1)[..., None]
    sph = srgb_to_lin(np.array([0.27, 0.19, 0.10], np.float32)) * (1 - sph_mix) + \
        srgb_to_lin(np.array([0.10, 0.08, 0.06], np.float32)) * sph_mix
    cal = srgb_to_lin(np.array([0.86, 0.85, 0.80], np.float32))
    c = host.copy()
    o3 = ore[..., None]
    c = c * (1 - o3) + sph * grain * o3
    c = c * (1 - rim[..., None] * 0.6) + cal * grain * rim[..., None] * 0.6
    c = np.where(cube[..., None], gal, c)
    return np.clip(c, 0, 1)


RECIPES = {"soot": make_soot, "gossan": make_gossan, "sulfurvein": make_sulfurvein,
           "pitchblende": make_pitchblende, "columnar": make_columnar, "galena": make_galena}
# Recipes stamped by their own code alone (layer_job), not in RECIPE_HASH: adding one
# must not re-bake every other layer (worlds W3 added galena).
OWN_HASH = ("galena",)


def slot_mapped(t):
    """Does this slot carry surface maps? Every photographic slot does; the glow
    slots (self-lit: magma, the crystals) keep their look."""
    return not t.get("glow") and t.get("maps", True)


def _bake_colour(sets, src, loaded, relief):
    """A layer's colour in linear light at BAKE, with `relief` of the baked relief."""
    sid, g = src
    alb, n, ao, height = loaded
    mk = g.get("make")
    _RELIEF[0] = relief
    try:
        if mk == "veins":
            return make_veins(alb, n, ao, g)
        if mk == "magma":
            return make_veins(alb, n, ao, g, glow=True)
        if mk == "crystal":
            return make_crystal(alb, n, ao, g)
        if mk == "patchy":
            return make_patchy(alb, n, ao, g, sets)
        if mk == "copper":
            return make_copper(alb, n, ao, g)
        if mk in RECIPES:
            return RECIPES[mk](alb, n, ao, g)
        return grade(alb, n, ao, g)
    finally:
        _RELIEF[0] = 1.0


def bake_layer(lib, sets, src, mapped=False):
    sid, g = src
    loaded = load_for_layer(lib, sets[sid])
    mk = g.get("make")
    ref = _bake_colour(sets, src, loaded, 1.0)
    # Less baked relief on a slot with maps (the engine lights them).
    c = _bake_colour(sets, src, loaded, RELIEF_MAPPED) if mapped else ref
    # Grain back: a 2048 photo reduced to the layer loses the micro-contrast that
    # reads as grit at the player's feet (the layer is magnified 3-5x there). A
    # small wrap-around unsharp mask restores it. The palette has mips since
    # engine .1437, so its far speckle averages away; the strength follows the
    # reduction (SHARPEN).
    def reduce(c, size, k):
        out = resize(lin_to_srgb(c), size, linear=True)
        if k > 0:
            out = np.clip(out + k * (out - blur_wrap(out, 0.9)), 0, 1)
        return out
    out = reduce(c, LAYER, g.get("sharpen", SHARPEN_MADE if mk else SHARPEN))
    if g.get("hold"):
        # A slot re-sourced to another photograph keeps the mean colour it had (linear, per
        # channel), so far_bodies PAL, the map, the mining tints and the far ground do not move.
        lin = srgb_to_lin(out)
        for _ in range(3):   # a few rounds: clipping at 1 pulls a bright channel's mean back
            m = lin.reshape(-1, 3).mean(axis=0)
            lin = np.clip(lin * (np.array(g["hold"], np.float32) / np.maximum(m, 1e-6)), 0, 1)
        return lin_to_srgb(lin)
    # Kept at the mean of the layer as it was baked before the maps (256, fully
    # baked relief, its sharpening then): the slot's average colour does not move
    # (far_bodies PAL, the map, the mining tints, the far ground).
    was = reduce(ref, 256, g.get("sharpen", (0.3 if mk else 0.8)))
    m_was, m_now = lum(srgb_to_lin(was)).mean(), lum(srgb_to_lin(out)).mean()
    return lin_to_srgb(srgb_to_lin(out) * (m_was / max(1e-6, m_now)))


# ── a slot's surface maps (engine 0637: palette |normal= |orm= |height=) ──────
# The engine lights them: the normal (OpenGL, +Y up the picture, lying on the
# ground as the colour does), the ORM (glTF: R occlusion of the sky's light,
# G roughness times the terrain Material's, B metalness) and the height (kept for
# height blending). Each at LAYER, from the same set at the same orientation as
# the colour, so every bump sits under its own pixel. A slot whose maps come
# straight from its set shares one file per set (maps/<set>_*.png); a slot that
# changes them (patchy cover, ripples, its own normal strength) has its own
# (maps/<slot>_<name>_*.png): its own roughness floor too.
MAP_KINDS = ("normal", "orm", "height")
RIPPLE_HEIGHT = 0.0035  # m: a wind ripple's half-height (crest to trough ~7 mm on a ~14 cm wavelength; 5 mm read busy from 30 m on)
# Ground is rough. Several sets' roughness maps are of polished or sealed stone
# (Onyx006/010 0.04-0.10, a studio-lit Ground039 0.49), which under the Physical
# terrain Material would turn a hillside into a mirror at a low sun. Each slot's
# roughness is lifted onto [floor, 1] (r' = floor + (1 - floor) r), so it keeps
# its own variation; ice may be smoother (rfloor per slot).
ROUGH_FLOOR = 0.6


def own_maps(t, which):
    g = t[which][1]
    return bool(g.get("make") == "patchy" or g.get("ripples") or t.get("nstr", 1.0) != 1.0 or "rfloor" in t)


def drift_only(t, which):
    """A slot whose only change to its set's maps is its drift height: it names the
    set's shared normal and ORM, and only its height is its own."""
    return "drift" in t and not own_maps(t, which)


def map_stem(t, which, kind="height"):
    if own_maps(t, which) or ("drift" in t and kind == "height"):
        return "%02d_%s" % (t["slot"], t["name"])
    return t[which][0]


def map_path(root, t, which, kind):
    return "%s/terrain/maps/%s_%s.png" % (root, map_stem(t, which, kind), kind)


def whiteout(a, b):
    """Two tangent normals (-1..1) combined, each keeping its own bumps."""
    n = np.concatenate([a[..., :2] + b[..., :2], (a[..., 2] * b[..., 2])[..., None]], axis=2)
    return n / np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)


def _set_maps(lib, s):
    """A set's normal (-1..1), ORM and height (or None) at BAKE."""
    c = convert_set(lib, s, BAKE)
    if c["normal"] is not None:
        n = c["normal"] * 2 - 1
    else:
        n = np.zeros((BAKE, BAKE, 3), np.float32)
        n[..., 2] = 1
    return n, c["orm"].copy(), c["height"], c


def layer_maps(lib, sets, t, which):
    """The slot's normal (0..1 encoded), ORM and height (or None) at LAYER."""
    sid, g = t[which]
    if g.get("make") == "crystal":
        # the crystal seam's own faces, roughness and heights (crystal_fields)
        alb, sn, sao, _ = load_for_layer(lib, sets[sid])
        _RELIEF[0] = RELIEF_MAPPED
        try:
            _, n, orm, h = crystal_fields(alb, sn, sao, g)
        finally:
            _RELIEF[0] = 1.0
    else:
        n, orm, h, c = _set_maps(lib, sets[sid])
    if g.get("make") == "patchy":
        # The cover's maps where the cover is, the ground's where it is worn through.
        _RELIEF[0] = RELIEF_MAPPED
        try:
            m = make_patchy(srgb_to_lin(c["albedo"]), n, orm[..., 0], g, sets, mask_only=True)
        finally:
            _RELIEF[0] = 1.0
        un, uorm, uh, _ = _set_maps(lib, sets[g["under"][0]])
        n = n * m[..., None] + un * (1 - m[..., None])
        n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
        orm = orm * m[..., None] + uorm * (1 - m[..., None])
        if h is not None or uh is not None:
            h = (h if h is not None else 0.5) * m + (uh if uh is not None else 0.5) * (1 - m)
    rp = g.get("ripples")
    if rp:
        # The ripples as relief (the colour keeps only RELIEF_MAPPED of their shading):
        # their height in texels of a tile 4.5 m / scale across, so the slopes are true.
        N = n.shape[0]
        hr, _, fade = ripple_field(N, rp)
        texel = (4.5 / t["scale"]) / N
        hp = hr * fade * (RIPPLE_HEIGHT / texel)
        dy = (np.roll(hp, -1, 0) - np.roll(hp, 1, 0)) * 0.5
        dx = (np.roll(hp, -1, 1) - np.roll(hp, 1, 1)) * 0.5
        rn = np.stack([-dx, dy, np.ones_like(hp)], axis=2)
        rn /= np.linalg.norm(rn, axis=2, keepdims=True)
        n = whiteout(n, rn)
        hn = (hr * fade - (hr * fade).min()) / max(1e-6, np.ptp(hr * fade))
        h = hn if h is None else h * 0.5 + hn * 0.5
    if "drift" in t and h is not None:
        h = drift_height(h, t["drift"])
    k = t.get("nstr", 1.0)
    if k != 1.0:
        n = np.concatenate([n[..., :2] * k, n[..., 2:]], axis=2)
        n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    n = resize(n * 0.5 + 0.5, LAYER) * 2 - 1
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    orm = resize(orm, LAYER)
    fl = t.get("rfloor", ROUGH_FLOOR)
    orm[..., 1] = fl + (1 - fl) * orm[..., 1]
    orm[..., 2] = 0.0            # ground is not metal (no terrain slot is)
    if h is not None:
        h = resize(h, LAYER)
        h = (h - h.min()) / max(1e-6, h.max() - h.min())
    return n * 0.5 + 0.5, orm, h


# Snow and ice at a border (Ty 2026-11-06: snow meeting rock or grass read as a
# cut-out). Real snow thins out over a band: it lies on in hollows and in the
# cracks between stones, the stones' tops poke through, and the edge is a soft
# lobed fringe. The rock's relief already decides the pokes (it is the other
# slot's height); what the snow's own photo height adds is crusty grain a few
# centimetres across, which turned each patch edge into a crisp ragged line.
# The height the border reads is instead the snow's depth: its own height
# blurred to the size of a footprint, under drifts and scoured hollows of
# tileable noise (lobes `lobe` of a tile across, a finer `fine` octave). A depth
# that is smooth spreads the fade over its own gentle slope, so the edge goes
# thin and grey before it goes, and wanders in lobes rather than following the
# grain.
def drift_height(h, d):
    N = h.shape[0]
    rng = np.random.default_rng(d.get("seed", 22))

    def noise(cells):
        f = blur_wrap(rng.standard_normal((N, N)), N / cells / 2.5)
        return (f - f.mean()) / (f.std() + 1e-9)
    own = blur_wrap(h.astype(np.float64), N * d.get("soften", 0.025))
    own = (own - own.mean()) / (own.std() + 1e-9)
    out = own * d.get("own", 0.5) + noise(d.get("lobe", 3.0)) * d.get("lobew", 1.0) + noise(d.get("fine", 9.0)) * d.get("finew", 0.4)
    return ((out - out.min()) / max(1e-9, np.ptp(out))).astype(np.float32)


def maps_hash():
    import inspect
    src = "".join(inspect.getsource(f) for f in (layer_maps, drift_height, _set_maps, ripple_field, whiteout, convert_set, make_patchy, crystal_fields, _worley))
    return hashlib.sha1(src.encode()).hexdigest()[:12]


def map_job(args):
    lib, sets, t, which, dry, force = args
    sid = t[which][0]
    s = sets.get(sid)
    if s is None:
        return map_stem(t, which), which, "missing set " + sid
    root = OUT_CC0 if which == "cc0" else OUT_LOCAL
    paths = {k: os.path.join(ROOT, map_path(root, t, which, k)) for k in MAP_KINDS}
    g = t[which][1]
    extra = [LAYER, BAKE, "maps", maps_hash(), RELIEF_MAPPED, RIPPLE_HEIGHT, t.get("nstr", 1.0), t.get("rfloor", ROUGH_FLOOR), t.get("drift"),
             t["scale"] if g.get("ripples") else None, g if (g.get("make") in ("patchy", "crystal") or g.get("ripples")) else None]
    st = stamp_of(s, extra)
    stf = os.path.join(os.path.dirname(paths["normal"]), ".import-" + map_stem(t, which))
    if not force and os.path.exists(paths["normal"]) and os.path.exists(stf) and open(stf).read().strip() == st:
        return map_stem(t, which), which, "up to date"
    if dry:
        return map_stem(t, which), which, "would bake"
    n, orm, h = layer_maps(LIB_PATH[0], sets, t, which)
    # else the set's own job writes the shared normal and ORM; a set no other slot takes any more
    # (slot 22 snow keeps Snow014's since slot 18 moved to its own photo) has them written here
    if not drift_only(t, which) or not (os.path.exists(paths["normal"]) and os.path.exists(paths["orm"])):
        save_png(n, paths["normal"], "RGB")
        save_png(orm, paths["orm"], "RGB")
    if h is not None:
        save_png(h, paths["height"], "L")
    elif os.path.exists(paths["height"]):
        os.remove(paths["height"])
    open(stf, "w").write(st + "\n")
    return map_stem(t, which), which, "baked"


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
    mapped = slot_mapped(t)
    extra = [LAYER, BAKE, src[1], RECIPE_HASH(), SHARPEN, SHARPEN_MADE, RELIEF_MAPPED if mapped else None]
    if src[1].get("make") == "copper":
        import inspect
        extra.append(hashlib.sha1(inspect.getsource(make_copper).encode()).hexdigest()[:12])
    if src[1].get("make") in OWN_HASH:
        import inspect
        extra.append(hashlib.sha1(inspect.getsource(RECIPES[src[1]["make"]]).encode()).hexdigest()[:12])
    st = stamp_of(s, extra)
    stf = p + ".import" if which == "local" else os.path.join(ROOT, root, "terrain", ".import-%02d" % t["slot"])
    if not force and os.path.exists(p) and os.path.exists(stf) and open(stf).read().strip() == st:
        return t["slot"], which, "up to date", rel
    if dry:
        return t["slot"], which, "would bake", rel
    a = bake_layer(LIB_PATH[0], sets, src, mapped)
    save_png(a, p, "RGB")
    open(stf, "w").write(st + "\n")
    return t["slot"], which, "baked", rel


LIB_PATH = [LIB]


def RECIPE_HASH():
    """The layer recipes' own code, so changing one re-bakes its layers."""
    import inspect
    src = "".join(inspect.getsource(f) for f in (grade, ripple_field, make_veins, make_crystal, crystal_fields, _worley, make_patchy, _bake_colour, bake_layer, load_for_layer, convert_set,
                                                 _noise, _streak, _grain) + tuple(f for k, f in RECIPES.items() if k not in OWN_HASH))
    return hashlib.sha1(src.encode()).hexdigest()[:12]


# Engine 0626 (dev .1434): |antitile= lays a slot in randomly shifted, turned
# hexagons so no grid shows from afar (3 texture reads instead of 1, so only
# where it reads), and |macro= a slow light/dark swell |macrosize= m across.
# Banded, layered or tiled looks turn little; the glow slots keep their look.
ANTITILE_LOW = {"onyx": 0.2, "bandedice": 0.2, "shale": 0.25, "sandstone": 0.25, "flagstone": 0.15,
                "slate": 0.3, "pahoehoe": 0.5, "glacier": 0.6}
MACRO = 0.35
MACRO_SIZE = 60


# Engine terrain stage 2 (dev .1455): a border between two slots can be decided
# by their height maps (|heightblend= k, 0-1, the pair takes the larger): each
# slot's height there, (h - 0.5) * |contrast= + |heightbias=, pushes it up and
# the higher one shows, so sand fills the cracks between stones, rock tops poke
# out of snow, and a crystal vein's points stand out of its host rock rather
# than ending on the voxel mesh's polygon. Pairs of photographic maps have very
# different means and spreads (0.36-0.77, sd 0.08-0.21), so the flags are set
# from each slot's own height map: its ROLE gives the height the slot should
# have at a border (mean) and how far its relief should count (sd), and
# height_flags() turns the map's measured mean and spread into bias and
# contrast that give exactly that. Read in raster.wgsl terrain_height_t:
# diff = (2t - 1) + k (h_hi - h_lo), so k * (sd_a + sd_b) ~ 0.5-0.8 spreads
# the patches over most of a blend's width, and a higher mean settles over a
# lower one. The glow slots keep their look (no flags; magma has no height
# map and counts as 0.5, i.e. bias 0, against its neighbours).
#   k     |heightblend= (crisper the higher: the engine's fade is 0.5 (1 - k) + 0.02;
#         0.5-0.6 here, see CONTRAST_MAX; snow and ice higher, over a wide blend)
#   mean  where the slot sits against others (rock tops above loose ground,
#         snow and ice over rock, sand lowest)
#   sd    how much its relief counts (stones and crystal points, a lot; snow,
#         sand and ice are smooth)
HEIGHT_ROLES = {
    "rock":    dict(k=0.5, mean=0.0, sd=0.60),     # bedrock: stones and ledges stand proud of their own mean
    "loose":   dict(k=0.55, mean=-0.08, sd=0.25),  # soil, gravel, regolith, ash: pebbles poke up a little
    "veg":     dict(k=0.55, mean=-0.06, sd=0.28),  # moss, tundra, litter, peat: tufts between the stones
    "sand":    dict(k=0.55, mean=-0.15, sd=0.12),  # sand and salt: fills the cracks, lies flat
    "snow":    dict(k=0.62, mean=0.15, sd=0.35),   # settles over rock first, the tallest rock pokes through;
                                                   # its height is its depth (drift_height), lobes and hollows
    "ice":     dict(k=0.65, mean=0.12, sd=0.30),   # glacier and banded ice (their own relief, softened)
    "ore":     dict(k=0.6, mean=0.10, sd=0.50),    # painted veins (hematite, veinstone, sulfur): ragged, but a
                                                   # thin seam keeps its painted width against the host rock
    "crystal": dict(k=0.6, mean=0.10, sd=0.60),    # druzy points stand out of the host rock at a deposit's rim
    # worlds plan W1 roles (the library layers 33+); they also say where a geology may put a layer
    "cavewall":  dict(k=0.5, mean=0.0, sd=0.50),   # cave rock: ledges and knobs, a little smoother than a cliff
    "flowstone": dict(k=0.55, mean=0.06, sd=0.25), # calcite skins: smooth, they drape over the rock beside them
    "evaporite": dict(k=0.55, mean=-0.12, sd=0.15),  # salt and gypsum crusts: flat, fill the low ground
    "volcanic":  dict(k=0.5, mean=0.0, sd=0.55),   # lava, tuff, clinker: rock-like
    # "glow": magma; no height flags (GLOW_HEIGHT_BIAS)
}
# A glow slot (magma) keeps its look and has no height map, so it counts as half
# height plus its bias: against a height-blended rock a small pocket was overrun
# whole (the rock's relief won every pixel). The bias alone holds it to its
# painted size; nothing else on its line changes.
GLOW_HEIGHT_BIAS = 0.3
# Soft, not crisp (2026-11-06 shots): k 0.7-0.8 made each border a near-hard
# line (fade 0.5 (1 - k) + 0.02 of the pair's diff), and a contrast of 6 on the
# smooth maps (onyx, sandstone, hematite, sd ~0.1) amplified their 8-bit steps.
# k 0.5-0.6 and contrast at most 3.5 keep the borders height-decided and soft.
# Snow and ice are the exception (2026-11-06 snow pass): on a 0.8-1.2 m blend their
# edge read as a stencil, and a lower k only smeared it into a veil. They get a
# wide blend instead (snow 3 m, glacier 2 m, banded ice 1.6 m: a band where the
# cover thins out) with a higher k (0.62-0.65), so inside that band the heights
# decide crisply pixel by pixel: rock tops and grass poke through, snow lies on in
# the cracks and hollows, and the snow's own height is its smooth drift depth
# (drift_height), so the fringe wanders in soft lobes. The pair takes the larger
# k, so this touches only borders with snow or ice.
CONTRAST_MAX = 3.5
HEIGHT_ROLE = {
    "rust": "rock", "flagstone": "rock", "onyx": "rock", "slate": "rock", "basalt": "rock", "granite": "rock",
    "sandstone": "rock", "limestone": "rock", "pahoehoe": "rock", "shale": "rock",
    "soil": "loose", "gravelregolith": "loose", "dust": "loose", "regolith": "loose", "mudcrack": "loose",
    "ash": "loose", "scree": "loose",
    "moss": "veg", "tundra": "veg", "litter": "veg", "peat": "veg",
    "sand": "sand", "salt": "sand",
    "snow": "snow", "bandedice": "ice", "glacier": "ice",
    "veinstone": "ore", "sulfur": "ore", "hematite": "ore",
    "amethyst": "crystal", "bluecrystal": "crystal",
}


def role_of(t):
    """A layer's role (TERRAIN `role`; HEIGHT_ROLE for an entry written without one)."""
    return t.get("role") or HEIGHT_ROLE.get(t["name"], "")


def palette_slots():
    """The TERRAIN entries that are palette lines (1..PALETTE_SLOTS), in order."""
    return [t for t in TERRAIN if t["slot"] <= PALETTE_SLOTS]


def height_flags(t, height_file):
    """The |heightblend= |heightbias= |contrast= suffix for slot t, from its own
    height map (absolute path): '' for a glow slot or one without a role or map."""
    role = HEIGHT_ROLES.get(role_of(t))
    if t.get("glow") or not role or not height_file or not os.path.exists(height_file):
        return ""
    h = np.asarray(Image.open(height_file).convert("L"), dtype=np.float32) / 255.0
    m, sd = float(h.mean()), max(float(h.std()), 0.02)
    contrast = min(CONTRAST_MAX, role["sd"] / sd)
    bias = max(-1.0, min(1.0, role["mean"] - (m - 0.5) * contrast))
    return "|heightblend=%g|heightbias=%.2f|contrast=%.2f" % (role["k"], bias, contrast)


def palette_line(t, path, maps=None, root_dir=None):
    line = path
    if t.get("glow"):
        line += "|glow"
    line += "|scale=%g" % t["scale"]
    if t.get("glow"):
        line += "|heightbias=%g" % GLOW_HEIGHT_BIAS
    else:
        line += "|blend=%g|rough=%g" % (t.get("blend", 0.8), t.get("rough", 0.7))
        line += "|antitile=%g|macro=%g|macrosize=%g" % (
            t.get("antitile", ANTITILE_LOW.get(t["name"], 1.0)), t.get("macro", MACRO), t.get("macrosize", MACRO_SIZE))
        if maps and maps.get("height"):
            line += height_flags(t, os.path.join(root_dir or ROOT, maps["height"]))
    for k in MAP_KINDS:   # after every other flag (engine 0637)
        if maps and maps.get(k):
            line += "|%s=%s" % (k, maps[k])
    return line


def slot_maps(t, which, root_dir):
    """The surface maps a palette line names for slot t's `which` layer: those of
    its own set that are there (none for a slot that has none)."""
    if not slot_mapped(t) or not t.get(which):
        return None
    root = OUT_CC0 if which == "cc0" else OUT_LOCAL
    return {k: map_path(root, t, which, k) for k in MAP_KINDS
            if os.path.exists(os.path.join(root_dir, map_path(root, t, which, k)))}


def write_palettes(dry, root_dir=None, local=False):
    """terrain/system.palette (32 slots) and planetoid.palette (12). Committed: cc0
    layers only. `local` (for --stage) names a slot's local layer where root_dir has it."""
    root_dir = root_dir or ROOT
    lines, wild = [], []
    for t in palette_slots():
        path, which = layer_path(OUT_CC0, t), "cc0"
        if local and t.get("local") and os.path.exists(os.path.join(root_dir, layer_path(OUT_LOCAL, t))):
            path, which = layer_path(OUT_LOCAL, t), "local"
        maps = slot_maps(t, which, root_dir)
        lines.append(palette_line(t, path, maps, root_dir))
        # a WILDCARD line (worlds plan W2, scripts/geology.lua WILD): the slot's flags and its
        # own height map, but no picture, normal or ORM, so terrain.setSlotMaterial gives the
        # slot the layer the star system's roll assigns (an older save: its own layer again)
        if t["slot"] in WILDCARD_SLOTS:
            hmaps = {"height": maps["height"]} if maps and maps.get("height") else None
            wild.append(palette_line(t, "", hmaps, root_dir))
        else:
            wild.append(lines[-1])
    out = {"terrain/system.palette": "\n".join(wild),
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


def lin_mean(t):
    """Mean linear colour of slot t's committed layer."""
    a = srgb_to_lin(to_float(Image.open(os.path.join(ROOT, layer_path(OUT_CC0, t))).convert("RGB")))
    return tuple(round(float(v), 3) for v in a.reshape(-1, 3).mean(axis=0))


def layer_means():
    """Mean linear colour of each committed layer (far_bodies.lua PAL)."""
    return [lin_mean(t) for t in palette_slots()]


SOURCE_PAGE = {"ambientCG": "https://ambientcg.com/view?id={id}", "polyhaven": "https://polyhaven.com/a/{id}"}


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
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:   # run with python -I, the script's own folder is not on the path
        sys.path.insert(0, here)
    for mod in ("base_pbr", "parts_pbr"):  # the base wave's and the parts wave's sets
        try:
            m = __import__(mod)
        except ImportError:
            continue
        for sid, u in m.USES.items():
            uses.setdefault(sid, []).extend(u)
    rows = []
    for sid, s in sorted(sets.items()):
        r = results.get(sid, {})
        ex = bool(s.get("extra"))
        rows.append(dict(
            id=sid, source=s["item"], note=s["note"] or None, licence=s["licence"], format=s["format"], kind=s["kind"],
            committed=s["licence"] == "CC0", out=None if ex else "%s/sets/%s/" % (out_root(s), sid),
            page=SOURCE_PAGE.get(s["format"], "").format(id=sid) or None,
            fetched="worlds W1 2026-11-10: terrain layers only" if ex else None,
            resolution=None if ex else RES[s["kind"]][0 if s["licence"] == "CC0" else 1],
            maps=sorted(k for k in s["members"]), conversion=r or None,
            use=uses.get(sid) or [PLANNED.get(s["kind"], "reserve")],
        ))
    def maps_of(t, which):
        m = slot_maps(t, which, ROOT) if which == "cc0" else (
            {k: map_path(OUT_LOCAL, t, which, k) for k in MAP_KINDS} if slot_mapped(t) else None)
        return m or None
    layers = [dict(slot=t["slot"], name=t["name"], role=role_of(t), palette=t["slot"] <= PALETTE_SLOTS,
                   material=t["mat"], was_psx=t.get("was"),
                   cc0=dict(set=t["cc0"][0], file=layer_path(OUT_CC0, t), maps=maps_of(t, "cc0")),
                   local=dict(set=t["local"][0], file=layer_path(OUT_LOCAL, t), maps=maps_of(t, "local"))
                   if t.get("local") else None,
                   size=LAYER, scale=t["scale"], glow=bool(t.get("glow"))) for t in TERRAIN]
    doc = dict(
        about="Solar's environment texture library, converted by tools/import_textures.py. CC0 output "
              "(textures/env) is committed; commercial output (textures/env_local) is git-ignored and must "
              "never be committed. Each set: albedo.png (sRGB), normal.png (OpenGL), orm.png (R AO, G rough, "
              "B metal), height.png. Each terrain layer (but the glow slots) also has maps/<set or slot>_{normal,orm,height}.png "
              "at the layer size, named on its palette line.",
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
# Local versions of committed files: textures/env_local/<dir>/<file> replaces <target>/<file> in a
# local build (same path, so nothing that names it changes). base: the spaceport's concrete
# (tools/base_pbr.py), whose committed file is a CC0 fallback.
OVERLAYS = {"base": "textures/base"}


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
    nov = 0
    for sub, target in OVERLAYS.items():
        d = os.path.join(src, sub)
        if not os.path.isdir(d):
            continue
        if os.path.realpath(os.path.join(dst, target)).startswith(os.path.realpath(ROOT) + os.sep):
            raise SystemExit("--stage: %s/%s is this checkout's own folder; stage a copy" % (dst, target))
        for f in sorted(os.listdir(d)):
            t = os.path.join(dst, target, f)
            if f.endswith(".png") and os.path.exists(t):   # only ever replaces a committed file
                shutil.copy2(os.path.join(d, f), t)
                nov += 1
    print("STAGE: %d local overlay files (%s)" % (nov, ", ".join("%s/%s -> %s" % (OUT_LOCAL, k, v) for k, v in OVERLAYS.items())))
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

    def tile(root, t, which):
        p = os.path.join(ROOT, layer_path(root, t))
        if not os.path.exists(p):
            return None
        im = Image.open(p).convert("RGB")
        big = Image.new("RGB", (im.width * 2, im.height * 2))
        for i in range(2):
            for j in range(2):
                big.paste(im, (i * im.width, j * im.height))
        return ("%02d %s (%s)" % (t["slot"], t["name"], t[which][0]), big)

    def sheet(name, rows):
        """rows: [(heading or None, [tiles])]; each heading starts a new row."""
        cols = 8
        nrow = sum(max(1, (len(ts) + cols - 1) // cols) for _, ts in rows)
        S = Image.new("RGB", (cols * 256, nrow * 288), (16, 16, 16))
        d = ImageDraw.Draw(S)
        y = 0
        for head, ts in rows:
            if head:
                d.text((3, y + 2), head, fill=(255, 220, 120))
            for k, (label, im) in enumerate(ts):
                if k and k % cols == 0:
                    y += 288
                x = (k % cols) * 256
                S.paste(im.resize((256, 256), Image.LANCZOS), (x, y + 16))
                d.text((x + 3, y + 274), label, fill=(255, 255, 255))
            y += 288
        S.save(os.path.join(outdir, name))
        print("sheet", os.path.join(outdir, name))

    for which, root in (("cc0", OUT_CC0), ("local", OUT_LOCAL)):
        tiles = [(t, tile(root, t, which)) for t in TERRAIN if t.get(which)]
        tiles = [(t, x) for t, x in tiles if x]
        if not tiles:
            continue
        sheet("terrain_%s.png" % which, [(None, [x for t, x in tiles if t["slot"] <= PALETTE_SLOTS]),
                                          ("library (33+, on no palette line yet)", [x for t, x in tiles if t["slot"] > PALETTE_SLOTS])])
        # by source photograph: the palette slots that share one show side by side
        by = {}
        for t, x in tiles:
            if t["slot"] <= PALETTE_SLOTS:
                by.setdefault(t[which][0], []).append(x)
        rows, single = [], []
        for sid, ts in sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            if len(ts) > 1:
                rows.append(("%s: %d slots" % (sid, len(ts)), ts))
            else:
                single += ts
        rows.append(("one photograph each: %d slots" % len(single), single))
        sheet("terrain_%s_by_source.png" % which, rows)
        # by role (the whole library)
        roles = {}
        for t, x in tiles:
            roles.setdefault(role_of(t), []).append(x)
        sheet("terrain_%s_by_role.png" % which, [("role " + r, ts) for r, ts in sorted(roles.items())])


# ── main ─────────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--lib", default=LIB)
    ap.add_argument("--extra-lib", action="append", help="a folder of fetched CC0 sets (default EXTRA_LIBS)")
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
        # the library layers (33+), which a wildcard slot may hold (LIB_PAL, keyed by layer)
        lib = [(t["slot"], lin_mean(t)) for t in TERRAIN if t["slot"] > PALETTE_SLOTS]
        ltext = "\n".join("  " + " ".join("[%d] = { %.3f, %.3f, %.3f }," % ((n,) + v) for n, v in lib[i:i + 3])
                          for i in range(0, len(lib), 3))
        print(ltext)
        if a.write:
            p = os.path.join(ROOT, "scripts/far_bodies.lua")
            src = open(p).read()
            i = src.index("PAL = {\n")
            j = src.index("\n}\n", i)
            src = src[:i] + "PAL = {\n" + text + src[j:]
            i = src.index("LIB_PAL = {\n")
            j = src.index("\n}\n", i)
            new = src[:i] + "LIB_PAL = {\n" + ltext + src[j:]
            if new != src:
                open(p, "w").write(new)
                print("wrote scripts/far_bodies.lua PAL")
        return
    if a.sheet:
        sheets(a.sheet)
        return
    extra = a.extra_lib or EXTRA_LIBS
    if not os.path.isdir(a.lib):
        print("no library at %s: nothing to convert; palettes and manifest left as they are" % a.lib)
        return
    sets = scan_all(a.lib, extra)
    print("library: %d sets (%d CC0, %d commercial)" % (len(sets), sum(s["licence"] == "CC0" for s in sets.values()),
                                                        sum(s["licence"] != "CC0" for s in sets.values())))
    # a fetched CC0 set gives only its terrain layers (no sets/<id>/ folder: the repo is public
    # and its size counts; worlds plan §7.1 Repo)
    pick = [s for s in sets.values() if (not a.only or s["id"] in a.only) and not s.get("extra")]
    results = {}
    with ProcessPoolExecutor(max_workers=a.jobs, initializer=_init, initargs=(a.lib,)) as ex:
        for sid, what, size, info in ex.map(write_set, [(a.lib, s, a.dry, a.force) for s in pick]):
            print("  %-34s %-15s %4d  %s" % (sid, what, size, (info or {}).get("normal", "")))
            results[sid] = info
        jobs = [(a.lib, sets, t, w, a.dry, a.force) for t in TERRAIN for w in ("cc0", "local")
                if t.get(w) and (not a.only or t[w][0] in a.only)]
        for slot, which, what, rel in ex.map(layer_job, jobs):
            print("  layer %2d %-5s %-12s %s" % (slot, which, what, rel or ""))
        seen, mjobs = set(), []
        for t in TERRAIN:
            for w in ("cc0", "local"):
                if t.get(w) and slot_mapped(t) and (not a.only or t[w][0] in a.only) and (w, map_stem(t, w)) not in seen:
                    seen.add((w, map_stem(t, w)))
                    mjobs.append((a.lib, sets, t, w, a.dry, a.force))
        for stem, which, what in ex.map(map_job, mjobs):
            print("  maps  %-5s %-12s %s" % (which, what, stem))
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
