#!/usr/bin/env python3
"""The O2 MASK item (expansion X2; scripts/items.lua o2mask, scripts/atmo.lua): a soft oronasal
mask with its exhalation valve and head harness, on a coiled hose to a quick-connect fitting that
clips to the suit's oxygen port. Shown on the depot's item card and in a crate; worn, it rides
inside the neck ring (no model on the suit).

    python3 tools/gen_o2mask.py

Built from tools/gen_part_meshes.py's primitives in the items' palette (tools/gen_items.py MATS),
real size: the cup ~0.12 m tall, the hose a 12 mm coil.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import PREFABS, ROOT, Model, lathe, tube, write_glb  # noqa: E402
import gen_items  # noqa: E402

TAU = 2 * math.pi


def mask():
    m = Model()
    # the cup: a soft silicone shell, lathed about +Z (built along +Y, then turned to face +Z)
    cup = Model()
    prof = [(0.0, 0.075), (0.022, 0.072), (0.038, 0.062), (0.050, 0.045), (0.058, 0.022), (0.062, 0.0),
            (0.066, -0.004), (0.066, -0.010)]
    lathe(cup, "Rubber", prof, segs=28, uv_m=8.0, smooth=True)
    # the valve housing on its front and the inlet below it
    lathe(cup, "Dark", [(0.0, 0.092), (0.020, 0.092), (0.022, 0.078), (0.0, 0.078)], segs=20, uv_m=10.0)
    lathe(cup, "O2Green", [(0.023, 0.080), (0.026, 0.080), (0.026, 0.074), (0.023, 0.074)], segs=20, uv_m=10.0)
    M = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)     # +Y of the build → +Z
    # squash it into a face's shape: taller than it is wide
    S = np.diag([0.86, 1.18, 1.0])
    m.merge(cup, S @ M)
    # the inlet stub under the valve, and the hose: a coil down and away
    tube(m, "Dark", (0.0, -0.045, 0.055), (0.0, -0.075, 0.07), 0.009, segs=10)
    pts = []
    for k in range(80):
        t = k / 79
        a = t * TAU * 3.2
        r = 0.035
        pts.append((r * math.cos(a), -0.08 - t * 0.30, 0.07 + r * math.sin(a) - t * 0.02))
    for k in range(len(pts) - 1):
        tube(m, "Rubber", pts[k], pts[k + 1], 0.006, segs=8, caps=False)
    end = pts[-1]
    tube(m, "Chrome", end, (end[0], end[1] - 0.03, end[2]), 0.009, segs=12)       # the quick-connect
    tube(m, "O2Green", (end[0], end[1] - 0.03, end[2]), (end[0], end[1] - 0.045, end[2]), 0.011, segs=12)
    # the head harness: two strap loops behind the cup
    for (y, rr) in ((0.035, 0.085), (-0.03, 0.08)):
        seg = []
        for k in range(25):
            a = math.pi * 0.15 + k / 24 * math.pi * 0.7
            seg.append((rr * math.cos(a) * 1.05, y, -rr * math.sin(a) * 0.9 + 0.01))
        for k in range(len(seg) - 1):
            tube(m, "Webbing", seg[k], seg[k + 1], 0.005, segs=6, caps=False)
    return m


def main():
    m = mask()
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    os.makedirs(gen_items.MODELS, exist_ok=True)
    write_glb(out, os.path.join(gen_items.MODELS, "o2_mask.glb"))
    with open(os.path.join(PREFABS, "ItemO2Mask.prefab.ron"), "w") as f:
        f.write(gen_items.prefab("ItemO2Mask", "o2_mask.glb", out,
                                 "O2 MASK — an oronasal mask on a coiled hose to the suit's oxygen port (scripts/items.lua o2mask)."
                                 ).replace("tools/gen_items.py", "tools/gen_o2mask.py"))
    print("o2 mask: size", np.round(mx - mn, 3).tolist(), "tris", out.tris())


if __name__ == "__main__":
    main()
