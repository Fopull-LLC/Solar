#!/usr/bin/env python3
"""Generate the SURVEY parts (expansion X1, scripts/parts_survey.lua): the
Space Telescope (a 0.3 m reflector for a satellite) and the Orbital Scanner
(a nadir-looking imaging spectrometer and limb sounder).

    python3 tools/gen_survey_parts.py          # meshes, prefabs, vis prefabs
    python3 tools/gen_survey_parts.py --dry    # print the bounds only

Built from tools/gen_part_meshes.py's primitives and the shared texture
library (textures/parts/), like tools/gen_nuclear_parts.py. Only its own files
are written.

FRAMES (parts_survey.lua holds the same boxes, rx / h / rz): both are RADIAL
parts: +X out of the face they mount on (the hull at -X), +Y up the stack.
* the telescope's tube lies along +Y beside the hull on two saddles, its
  aperture (and the sun shade's angled cut) at +Y, the baffle's cap open;
* the scanner's box stands off the hull on its bracket, the spectrometer's
  aperture looking out along +X (point it at the ground: mount it on the
  craft's belly), the limb sounder's telescope along +Y.
Real proportions: a 0.3 m Ritchey-Chrétien OTA is ~0.95 m long and ~0.36 m
across its tube; an instrument like CRISM is ~0.3 m a side.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_part_meshes as G  # noqa: E402
from gen_part_meshes import Model, box, tube, lathe, disk, bolt_ring, rot_y, rot_z  # noqa: E402

TAU = 2 * math.pi
G.MATERIALS.setdefault("Steel", lambda: G.mat_ron("metal", color=(0.70, 0.70, 0.68), rough=0.8, metal=0.6))
G.MATERIALS.setdefault("BaffleBlack", lambda: G.mat_ron("paint", color=(0.05, 0.05, 0.055), rough=1.3))
G.MATERIALS.setdefault("Mirror", lambda: G.mat_ron("metal", color=(0.92, 0.93, 0.95), rough=0.25, metal=0.9))


def telescope():
    """A 0.3 m Ritchey-Chrétien on a radial cradle: the white tube (built along
    +Y), a black-anodised baffle with an angled sun shade at the aperture,
    the secondary's spider vanes and hub inside, the primary's cell and focal
    plane box at the back, two clamp rings on saddles to the hull at -X."""
    m = Model()
    R, Y0, Y1 = 0.18, -0.40, 0.36
    cx = 0.20                                         # the tube's axis, off the hull
    t = Model()
    lathe(t, "Paint2", [(R, Y0 + 0.06), (R, Y1 - 0.10)], segs=40, uv_m=2.0)
    lathe(t, "BaffleBlack", [(R - 0.006, Y0 + 0.06), (R - 0.006, Y1 - 0.10)], segs=40, uv_m=2.0)  # its inside
    # the sun shade: the last 0.1 m, cut at an angle (a band of segments, longer on the sun side)
    for k in range(40):
        a0, a1 = TAU * k / 40, TAU * (k + 1) / 40
        am = (a0 + a1) / 2
        top = Y1 - 0.10 + 0.10 * (0.5 + 0.5 * math.cos(am))
        lathe(t, "Foil", [(R + 0.004, Y1 - 0.10), (R + 0.004, top)], segs=1, a0=a0, a1=a1, uv_m=3.0)
        lathe(t, "BaffleBlack", [(R - 0.004, Y1 - 0.10), (R - 0.004, top)], segs=1, a0=a0, a1=a1, uv_m=3.0)
    G.flange(t, "Metal", Y1 - 0.11, Y1 - 0.095, R - 0.01, R + 0.012, segs=40)
    # the secondary: a hub on three vanes
    tube(t, "Dark", (0, Y1 - 0.16, 0), (0, Y1 - 0.12, 0), 0.05, segs=16)
    for k in range(3):
        a = TAU * k / 3
        tube(t, "Dark", (0, Y1 - 0.14, 0), (R * math.cos(a), Y1 - 0.14, R * math.sin(a)), 0.004, segs=5)
    disk(t, "Mirror", R - 0.02, Y0 + 0.075, segs=32, up=True)   # the primary, seen down the tube
    # the primary's cell and the focal plane box behind it
    lathe(t, "Metal", [(0.0, Y0 + 0.02), (R + 0.01, Y0 + 0.02), (R + 0.01, Y0 + 0.06), (0.0, Y0 + 0.06)], segs=40, uv_m=2.0)
    bolt_ring(t, "Dark", Y0 + 0.02, R - 0.02, 12, size=0.008, height=0.006, up=False)
    box(t, "Foil", (0.0, Y0 - 0.01, 0.0), (0.18, 0.06, 0.14), uv_m=4.0)
    box(t, "Dark", (0.06, Y0 - 0.035, 0.05), (0.04, 0.012, 0.03), uv_m=8.0)
    tube(t, "Dark", (-0.05, Y0 - 0.01, 0.07), (-0.05, Y0 - 0.01, 0.14), 0.008, segs=6)   # its harness
    m.merge(t, None, (cx, 0, 0))
    # two clamp rings and saddles to the hull
    for y in (-0.22, 0.16):
        tt = Model()
        G.flange(tt, "Dark", y - 0.02, y + 0.02, R, R + 0.016, segs=40)
        m.merge(tt, None, (cx, 0, 0))
        box(m, "Anodised", (-0.01, y, 0.0), (0.04, 0.06, 0.16), uv_m=5.0)              # the saddle on the hull
        # the strut from the saddle to the clamp ring's foot (cx - R)
        box(m, "Anodised", ((cx - R) / 2, y, 0.0), (cx - R + 0.01, 0.04, 0.07), uv_m=5.0)
    box(m, "Stencil", (cx, 0.0, R + 0.002), (0.10, 0.04, 0.002), uv_m=1.0)
    return G.recenter(m)[0], (0.215, 0.405, 0.20)


def scanner():
    """An orbital imaging spectrometer: a gold-foiled box on a standoff
    bracket, its scan mirror's aperture and baffle looking out (+X), a
    passive radiator plate (white) facing ±Z, the limb sounder's small
    telescope along +Y, a calibration lamp housing and the harness."""
    m = Model()
    # the bracket off the hull
    box(m, "Anodised", (0.03, 0.0, 0.0), (0.06, 0.26, 0.20), uv_m=4.0)
    for sy in (-1, 1):
        tube(m, "Metal", (0.04, sy * 0.10, 0.0), (0.12, sy * 0.06, 0.0), 0.012, segs=8)
    # the instrument box
    box(m, "Foil", (0.25, 0.0, 0.0), (0.26, 0.30, 0.24), uv_m=3.0)
    box(m, "Paint3", (0.25, 0.155, 0.0), (0.27, 0.012, 0.25), uv_m=3.0)
    # the radiator plates on both sides (white, the cold detector's)
    for sz in (-1, 1):
        box(m, "Radiator" if "Radiator" in G.MATERIALS else "Paint2", (0.25, -0.01, sz * 0.128), (0.24, 0.26, 0.012), uv_m=3.0)
    # the scan aperture and its baffle, out along +X
    sc = Model()
    lathe(sc, "BaffleBlack", [(0.065, 0.0), (0.065, 0.07)], segs=24, uv_m=3.0)
    lathe(sc, "Metal", [(0.072, 0.0), (0.072, 0.07)], segs=24, uv_m=3.0)
    G.flange(sc, "Metal", 0.065, 0.075, 0.06, 0.08, segs=24)
    disk(sc, "Mirror", 0.06, 0.01, segs=24, up=True)
    m.merge(sc, rot_z(-math.pi / 2), (0.38, 0.0, 0.0))
    # the limb sounder: a small telescope along +Y
    lt = Model()
    lathe(lt, "Paint2", [(0.035, 0.0), (0.035, 0.10)], segs=20, uv_m=3.0)
    lathe(lt, "BaffleBlack", [(0.03, 0.0), (0.03, 0.10)], segs=20, uv_m=3.0)
    m.merge(lt, None, (0.30, 0.16, -0.05))
    # the calibration lamp housing and the harness
    box(m, "Dark", (0.18, 0.17, 0.07), (0.06, 0.03, 0.05), uv_m=6.0)
    tube(m, "Dark", (0.12, -0.15, 0.06), (0.04, -0.15, 0.06), 0.009, segs=6)
    box(m, "Stencil", (0.25, -0.05, 0.135), (0.10, 0.03, 0.002), uv_m=1.0)
    return G.recenter(m)[0], (0.23, 0.21, 0.14)


def vis(prefab):
    src = open(os.path.join(G.PREFABS, prefab + ".prefab.ron")).read()
    v = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
    head_ = ("// VISUAL-ONLY variant of prefabs/" + prefab + ".prefab.ron for the builder stand: no body,"
             " no scripts.\n// Written by tools/gen_survey_parts.py — regenerate, don't edit.\n")
    open(os.path.join(G.VIS_DIR, prefab + ".prefab.ron"), "w").write(head_ + v)


def check(name, m, half):
    mn, mx = m.bounds()
    over = np.maximum(-mn - np.asarray(half), mx - np.asarray(half))
    print(f"{name:14s} bounds {np.round(mn, 3)} .. {np.round(mx, 3)} box {half} tris {m.tris()}"
          + (f"  NOTE past its box by {np.round(over, 3)}" if (over > 0.006).any() else ""))


def main():
    dry = "--dry" in sys.argv
    os.makedirs(G.MODELS, exist_ok=True)
    os.makedirs(G.VIS_DIR, exist_ok=True)
    done = []
    for prefab, key, fn, mass, about in (
            ("PartTelescopeS", "survey_telescope", telescope, 0.06,
             "SPACE TELESCOPE — a 0.3 m reflector on a radial cradle, its aperture up +Y, +X out of the hull (parts_survey telescopeS)."),
            ("PartScanner", "survey_scanner", scanner, 0.18,
             "ORBITAL SCANNER — an imaging spectrometer and limb sounder, its aperture out +X (parts_survey scanner).")):
        m, half = fn()
        check(prefab, m, half)
        if dry:
            continue
        model, c = G.recenter(m)
        G.write_glb(model, os.path.join(G.MODELS, key + ".glb"))
        G.write_prefab(prefab, about, None, half, mass, children=[("Body", key, model, c)])
        done.append(prefab)
    for p in done:
        vis(p)
    if done:
        print("prefabs:", ", ".join(done))


if __name__ == "__main__":
    main()
