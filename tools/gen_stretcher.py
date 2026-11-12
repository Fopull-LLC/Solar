#!/usr/bin/env python3
"""THE STRETCHER (missions N1): a folding rescue litter as the Depot's item
card and the pack shows it — two anodised poles with the orange canvas
rolled between them, cinched by two webbing straps, the folding spreader
bars and the carry handles at the ends.

    python3 tools/gen_stretcher.py     # models/items/stretcher.glb, prefabs/ItemStretcher

items.lua `stretcher` shows it (`show = "ItemStretcher"`).
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import PREFABS, ROOT, TAU, Model, box, mat_ron, tube, write_glb  # noqa: E402

MODELS = os.path.join(ROOT, "models", "items")
MATS = {
    "Canvas": lambda: mat_ron("rubber", (0.78, 0.30, 0.08), rough=1.0, metal=0.0, hull=False),
    "Webbing": lambda: mat_ron("rubber", (0.10, 0.11, 0.12), rough=1.0, metal=0.0, hull=False),
    "Alu": lambda: mat_ron("metal", (0.74, 0.75, 0.76), rough=0.5, metal=0.85, hull=False),
    "Grip": lambda: mat_ron("rubber", (0.05, 0.05, 0.05), rough=1.0, metal=0.0, hull=False),
}
L = 1.10      # folded length (m)


def model():
    m = Model()
    # the two poles, the canvas rolled between them (a fat soft cylinder)
    for sx in (-1, 1):
        tube(m, "Alu", (sx * 0.07, 0.0, -L / 2), (sx * 0.07, 0.0, L / 2), 0.016, segs=12, uv_m=3.0)
        for sz in (-1, 1):
            tube(m, "Grip", (sx * 0.07, 0.0, sz * (L / 2 - 0.12)), (sx * 0.07, 0.0, sz * (L / 2 + 0.02)), 0.021, segs=12)
    ring = 18
    for k in range(9):
        z0 = -L / 2 + 0.16 + k * (L - 0.32) / 9
        z1 = z0 + (L - 0.32) / 9
        r = 0.058 + 0.004 * math.sin(k * 1.7)
        tube(m, "Canvas", (0.0, 0.004, z0), (0.0, 0.004, z1), r, segs=ring, uv_m=4.0)
    # the folded spreader bars, hinged at the poles
    for sz in (-1, 1):
        z = sz * (L / 2 - 0.10)
        tube(m, "Alu", (-0.07, -0.02, z), (0.07, -0.02, z), 0.008, segs=8)
        box(m, "Alu", (0.0, -0.02, z), (0.03, 0.016, 0.02), uv_m=6.0)
    # two webbing straps round the bundle, with buckles
    for z in (-0.22, 0.22):
        pts = [(0.095 * math.cos(a), 0.072 * math.sin(a), z) for a in np.linspace(0, TAU, 25)]
        for a, b in zip(pts[:-1], pts[1:]):
            tube(m, "Webbing", a, b, 0.009, segs=4)
        box(m, "Alu", (0.0, 0.075, z), (0.03, 0.008, 0.03), uv_m=6.0)
    return m


def centred(m):
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    return out


def prefab(m):
    mats = ",\n".join(f'            "{n}": {MATS[n]()}' for n in sorted(m.parts.keys()))
    return f'''// STRETCHER — a folding rescue litter, folded: the Depot's item card and the pack show it
// (items.lua `stretcher`, missions N1). Written by tools/gen_stretcher.py — edit the generator, not this file.
[
    (
        name: "ItemStretcher",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/stretcher.glb",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
    ),
]
'''


def main():
    os.makedirs(MODELS, exist_ok=True)
    m = centred(model())
    write_glb(m, os.path.join(MODELS, "stretcher.glb"))
    with open(os.path.join(PREFABS, "ItemStretcher.prefab.ron"), "w") as f:
        f.write(prefab(m))
    print("stretcher:", m.tris() if hasattr(m, "tris") else "", "tris")


if __name__ == "__main__":
    main()
