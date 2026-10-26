#!/usr/bin/env python3
"""Held items: the Repair Kit, the stowed Relay Beacon, the furled Company Flag
and the Oxygen Tank (docs/crew-and-items.md §5).

    python3 tools/gen_items.py

Builds each item in Blender (tools/gen_items_blender.py, headless), then writes
models/items/<item>.glb and prefabs/Item*.prefab.ron. The look is the hand
tools' (tools/gen_tools.py): worn enamel and dark anodised metal, rubber, a
little signal orange, the same textures, stencils from the tools' decal atlas.
scripts/item_hand.lua carries them (scripts/items.lua names the prefabs).
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import PREFABS, ROOT, Model, mat_ron, write_glb  # noqa: E402

MODELS = os.path.join(ROOT, "models", "items")
BLENDER = os.environ.get("BLENDER", "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender")
BL_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_items_blender.py")

# The tools' palette (tools/gen_tools.py TOOL_MATS), plus webbing olive and
# breathing-oxygen green.
MATS = {
    "Enamel":     lambda: mat_ron("paint", color=(0.86, 0.84, 0.78), hull=False),
    "EnamelWorn": lambda: mat_ron("metal", color=(0.72, 0.71, 0.68), rough=0.8, metal=0.7, hull=False),
    "PaintWorn":  lambda: mat_ron("metal", color=(0.66, 0.64, 0.60), rough=0.8, metal=0.7, hull=False),
    "GunPaint":   lambda: mat_ron("paint", color=(0.97, 0.55, 0.22), hull=False),
    "Hazard":     lambda: mat_ron("paint", color=(0.95, 0.72, 0.12), hull=False),
    "Olive":      lambda: mat_ron("rubber", color=(0.36, 0.37, 0.27), metal=0.0, hull=False),
    "O2Green":    lambda: mat_ron("paint", color=(0.22, 0.42, 0.26), hull=False),
    "Anodised":   lambda: mat_ron("metal", color=(0.42, 0.47, 0.55), rough=0.85, metal=0.5, hull=False),
    "Chrome":     lambda: mat_ron("metal", color=(1.0, 1.0, 1.0), rough=0.4, metal=0.85, hull=False),
    "Dark":       lambda: mat_ron("metal", color=(0.16, 0.16, 0.17), rough=1.3, metal=0.3, hull=False),
    "Rubber":     lambda: mat_ron("rubber", metal=0.0, hull=False),
    "Copper":     lambda: mat_ron("metal", color=(0.80, 0.50, 0.32), rough=0.75, metal=0.9, hull=False),
    "ToolDecal":  lambda: ('(\n                color: (1.0, 1.0, 1.0),\n'
                           '                texture: Some("textures/tools/tool_decals.png"),\n'
                           '                roughness: 0.6,\n                metallic: 0.0,\n'
                           '                shading: Physical,\n            )'),
}

ITEMS = (
    ("repairkit", "repair_kit.glb", "ItemRepairKit",
     "REPAIR KIT — a field repair case, carried by its handle (scripts/item_hand.lua); clamped to a hull for the work."),
    ("beacon", "beacon_stowed.glb", "ItemBeaconStowed",
     "RELAY BEACON, stowed — folded and strapped, carried over the shoulder (scripts/item_hand.lua)."),
    ("flag", "flag_furled.glb", "ItemFlagFurled",
     "COMPANY FLAG, furled — the cloth rolled in its sleeve round the collapsed pole, over the shoulder (scripts/item_hand.lua)."),
    ("o2tank", "o2_tank.glb", "ItemO2Tank",
     "OXYGEN TANK — a spare breathing-oxygen bottle, clipped beside the suit's PLSS while carried (scripts/item_hand.lua)."),
)


def blender_items():
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "items_mesh.json")
        r = subprocess.run([BLENDER, "--background", "--factory-startup", "--python", BL_SCRIPT, "--", out],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            sys.exit("gen_items_blender.py failed:\n" + r.stdout[-3000:] + r.stderr[-3000:])
        for line in r.stdout.splitlines():
            if line.startswith("ITEMS"):
                print(line)
        with open(out) as f:
            return json.load(f)


def model_of(data):
    m = Model()
    for mat, e in data["geo"].items():
        P = np.asarray(e["P"], float).reshape(-1, 3)
        N = np.asarray(e["N"], float).reshape(-1, 3)
        UV = np.asarray(e["UV"], float).reshape(-1, 2)
        key = np.round(np.hstack([P * 1e5, N * 1e4, UV * 1e4])).astype(np.int64)
        _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
        m.add(mat, P[first], N[first], UV[first], inv.reshape(-1, 3))
    # the engine recentres a model on its box: do it here so the anchors agree
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    return out, c, mx - mn


def prefab(name, glb, model, about):
    names = sorted(model.parts.keys())
    body = ",\n".join(f'            "{n}": {MATS[n]()}' for n in names)
    return f'''// {about}
// Written by tools/gen_items.py — edit the generator, not this file.
[
    (
        name: "{name}",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/{glb}",
        ),
        object_materials: {{
{body},
        }},
        scripts: [],
    ),
]
'''


def main():
    os.makedirs(MODELS, exist_ok=True)
    data = blender_items()
    print("ITEMS (relative to each model's centre, metres):")
    for key, glb, pf, about in ITEMS:
        m, c, size = model_of(data[key])
        write_glb(m, os.path.join(MODELS, glb))
        with open(os.path.join(PREFABS, pf + ".prefab.ron"), "w") as f:
            f.write(prefab(pf, glb, m, about))
        g = np.asarray(data[key]["anchors"]["grip"], float) - c
        print(f"  {key:10s} size {np.round(size, 3).tolist()} grip {np.round(g, 3).tolist()} tris {m.tris()}")


if __name__ == "__main__":
    main()
