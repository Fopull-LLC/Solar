#!/usr/bin/env python3
"""Generate the SMALL STORAGE parts: the Small Locker (a ribbed steel field
case, 40 kg / 50 L) and the Saddle Box (an aluminium pannier for a bike or a
rover's flank, 15 kg / 20 L). The Stowage Locker (80 kg / 120 L) is
prefabs/PartLocker; these sit below it in the PAYLOAD catalogue.

    python3 tools/gen_storage_parts.py          # meshes, prefabs, vis prefabs
    python3 tools/gen_storage_parts.py --dry    # print the bounds only

Built from tools/gen_part_meshes.py's primitives and texture library, like
tools/gen_gas_parts.py. Only its own files are written.

FRAMES (scripts/parts_registry.lua holds the same boxes, rx / h / rz):
* the box is the part's (rx, h/2, rz) about its centre; Y up, the lid on top.
* the Saddle Box's long side is X, its mounting rail on the -Z face (the side
  that goes against the frame), its lid hinged at that side.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_part_meshes as G  # noqa: E402
from gen_part_meshes import Model, box, tube  # noqa: E402

G.MATERIALS.setdefault("Olive", lambda: G.mat_ron("paint", color=(0.33, 0.35, 0.24)))
G.MATERIALS.setdefault("Alu", lambda: G.mat_ron("metal", color=(0.66, 0.67, 0.68), rough=1.05, metal=0.55))
G.MATERIALS.setdefault("Steel", lambda: G.mat_ron("metal", color=(0.70, 0.70, 0.68), rough=0.8, metal=0.6))


def latch(m, x, y, z, nz):
    """A draw latch on a face whose outward normal is ±Z (nz): the keeper on
    the lid, the lever and its hook on the body."""
    box(m, "Steel", (x, y + 0.012, z + nz * 0.004), (0.03, 0.012, 0.008), uv_m=8.0)
    box(m, "Steel", (x, y - 0.016, z + nz * 0.007), (0.022, 0.04, 0.008), uv_m=8.0)
    box(m, "Dark", (x, y - 0.03, z + nz * 0.004), (0.034, 0.012, 0.01), uv_m=8.0)


def small_locker():
    """A ribbed steel field case in olive: the body, a lid with a lip and a
    gasket line, pressed ribs round the body, two draw latches front and
    back, folding end handles, corner caps and skids."""
    m = Model()
    hx, hy, hz = 0.20, 0.175, 0.20
    lid = 0.06                                   # the lid's depth
    yb = hy - lid                                # the split line
    box(m, "Olive", (0, (yb - hy) / 2, 0), (2 * hx - 0.02, yb + hy, 2 * hz - 0.02), uv_m=3.0, bevel=0.012)
    box(m, "Olive", (0, yb + lid / 2, 0), (2 * hx - 0.012, lid - 0.004, 2 * hz - 0.012), uv_m=3.0, bevel=0.014)
    box(m, "Rubber", (0, yb + 0.001, 0), (2 * hx - 0.016, 0.006, 2 * hz - 0.016), uv_m=6.0)   # gasket line
    box(m, "Olive", (0, hy - 0.004, 0), (2 * hx - 0.08, 0.008, 2 * hz - 0.08), uv_m=3.0, bevel=0.01)  # lid panel
    for y in (-0.09, -0.02):                     # pressed ribs round the body
        box(m, "Olive", (0, y, 0), (2 * hx - 0.008, 0.014, 2 * hz - 0.008), uv_m=4.0, bevel=0.012)
    for nz in (-1, 1):
        for x in (-0.09, 0.09):
            latch(m, x, yb, nz * (hz - 0.006), nz)
    for sx in (-1, 1):                           # folding end handles
        x = sx * (hx - 0.004)
        box(m, "Dark", (x, yb - 0.035, 0), (0.008, 0.03, 0.09), uv_m=8.0)
        tube(m, "Dark", (x + sx * 0.012, yb - 0.05, -0.05), (x + sx * 0.012, yb - 0.05, 0.05), 0.007, segs=8)
    for sx in (-1, 1):                           # corner caps
        for sz in (-1, 1):
            box(m, "Dark", (sx * (hx - 0.015), -hy + 0.02, sz * (hz - 0.015)), (0.03, 0.04, 0.03), uv_m=8.0)
            box(m, "Dark", (sx * (hx - 0.015), hy - 0.02, sz * (hz - 0.015)), (0.03, 0.04, 0.03), uv_m=8.0)
    for x in (-0.12, 0.12):                      # skids
        box(m, "Rubber", (x, -hy + 0.006, 0), (0.03, 0.012, 2 * hz - 0.04), uv_m=6.0)
    box(m, "Stencil", (0, -0.055, hz - 0.003), (0.16, 0.03, 0.002), uv_m=1.0)              # stencil plate
    return m, (hx, hy, hz)


def saddle_box():
    """An aluminium pannier: a riveted box, the lid hinged on the frame side
    (-Z) with a strap and a latch on the outer face, a mounting rail and two
    hooks on the frame side, a rubber bumper strip along the bottom."""
    m = Model()
    hx, hy, hz = 0.20, 0.15, 0.09
    lid = 0.05
    yb = hy - lid
    box(m, "Alu", (0.0, (yb - hy) / 2, 0.006), (2 * hx - 0.012, yb + hy, 2 * hz - 0.024), uv_m=2.5, bevel=0.01)
    box(m, "Alu", (0.0, yb + lid / 2, 0.006), (2 * hx - 0.004, lid - 0.004, 2 * hz - 0.016), uv_m=2.5, bevel=0.012)
    box(m, "Rubber", (0.0, yb + 0.001, 0.006), (2 * hx - 0.01, 0.005, 2 * hz - 0.02), uv_m=6.0)
    for i in range(9):                           # rivet lines on the outer face, top and bottom of the body
        x = -hx + 0.03 + i * (2 * hx - 0.06) / 8
        for y in (yb - 0.012, -hy + 0.015):
            box(m, "Steel", (x, y, hz - 0.004), (0.006, 0.006, 0.006), uv_m=10.0)
    box(m, "Dark", (0.0, yb - 0.02, hz - 0.004), (0.035, 0.03, 0.008), uv_m=8.0)              # latch
    box(m, "Steel", (0.0, yb + 0.012, hz - 0.002), (0.026, 0.012, 0.006), uv_m=8.0)
    for x in (-0.14, 0.14):                      # the strap over the lid
        box(m, "Dark", (x, hy - 0.001, 0.006), (0.03, 0.004, 2 * hz - 0.012), uv_m=6.0)
        box(m, "Dark", (x, yb - 0.015, hz - 0.003), (0.03, 0.04, 0.004), uv_m=6.0)
    box(m, "Dark", (0.0, 0.0, -hz + 0.008), (2 * hx - 0.04, 0.03, 0.014), uv_m=5.0)           # mounting rail
    for x in (-0.12, 0.12):                      # hooks over the frame tube
        box(m, "Steel", (x, yb - 0.01, -hz + 0.008), (0.03, 0.05, 0.014), uv_m=8.0)
    box(m, "Rubber", (0.0, -hy + 0.006, 0.006), (2 * hx - 0.03, 0.012, 2 * hz - 0.04), uv_m=6.0)  # bumper
    box(m, "Stencil", (0.08, -0.05, hz - 0.002), (0.10, 0.025, 0.002), uv_m=1.0)
    return m, (hx, hy, hz)


PARTS = (
    ("lockerS", small_locker, "PartLockerS", "storage_locker_s", 0.012,
     "SMALL LOCKER — a ribbed steel field case with its own 40 kg / 50 L container (parts_registry lockerS)."),
    ("saddleBox", saddle_box, "PartSaddleBox", "storage_saddle_box", 0.005,
     "SADDLE BOX — an aluminium pannier with its own 15 kg / 20 L container; the frame side is -Z (parts_registry saddleBox)."),
)


def main():
    dry = "--dry" in sys.argv
    os.makedirs(G.MODELS, exist_ok=True)
    os.makedirs(G.VIS_DIR, exist_ok=True)
    written = []
    for pid, fn, prefab, key, mass, about in PARTS:
        m, half = fn()
        mn, mx = m.bounds()
        over = np.maximum(-mn - np.asarray(half), mx - np.asarray(half))
        print(f"{pid:10s} bounds {np.round(mn, 3)} .. {np.round(mx, 3)} box {half}"
              + (f"  NOTE past its box by {np.round(over, 3)}" if (over > 0.004).any() else ""))
        if dry:
            continue
        model, c = G.recenter(m)
        G.write_glb(model, os.path.join(G.MODELS, key + ".glb"))
        G.write_prefab(prefab, about, None, half, mass, children=[("Box", key, model, c)])
        written.append(prefab)
    for prefab in written:
        src = open(os.path.join(G.PREFABS, prefab + ".prefab.ron")).read()
        vis = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
        head_ = ("// VISUAL-ONLY variant of prefabs/" + prefab + ".prefab.ron for the builder stand: no body,"
                 " no scripts.\n// Written by tools/gen_storage_parts.py — regenerate, don't edit.\n")
        open(os.path.join(G.VIS_DIR, prefab + ".prefab.ron"), "w").write(head_ + vis)
    if written:
        print("prefabs:", ", ".join(written))


if __name__ == "__main__":
    main()
