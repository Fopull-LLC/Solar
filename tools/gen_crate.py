#!/usr/bin/env python3
"""The base's supply crates: `python3 tools/gen_crate.py`.

Builds the crate in Blender (tools/gen_crate_blender.py, headless), then writes

    models/props/supply_crate.glb
    prefabs/SupplyCrate.prefab.ron     a static, boxed collider (you walk into
                                       it, stand on it, it does not move)

scripts/supply_crates.lua lays them out round the base and keeps what is in
them (inventory containers "crate:<n>"). The look is the held items'
(tools/gen_items.py): chipped paint over metal, rubber, the tools' stencils.
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_items import BLENDER, MATS, model_of  # noqa: E402
from gen_part_meshes import PREFABS, ROOT, mat_ron, write_glb  # noqa: E402

MODELS = os.path.join(ROOT, "models", "props")
BL_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_crate_blender.py")

MATS = dict(MATS)
# Olive drab over steel, sun-bleached on the lid; the worn edges are gen_items' PaintWorn.
MATS["CrateOlive"] = lambda: mat_ron("paint", color=(0.33, 0.35, 0.24), rough=1.15, hull=False)
MATS["CrateLid"] = lambda: mat_ron("paint", color=(0.40, 0.41, 0.30), rough=1.2, hull=False)


def main():
    os.makedirs(MODELS, exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "crate.json")
        r = subprocess.run([BLENDER, "--background", "--factory-startup", "--python", BL_SCRIPT, "--", out],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            sys.exit("gen_crate_blender.py failed:\n" + r.stdout[-3000:] + r.stderr[-3000:])
        for line in r.stdout.splitlines():
            if line.startswith("CRATE"):
                print(line)
        with open(out) as f:
            data = json.load(f)["crate"]
    m, c, size = model_of(data)
    write_glb(m, os.path.join(MODELS, "supply_crate.glb"))
    hx, hy, hz = (np.round(np.asarray(size) / 2 * 0.97, 3)).tolist()
    names = sorted(m.parts.keys())
    body = ",\n".join(f'            "{n}": {MATS[n]()}' for n in names)
    with open(os.path.join(PREFABS, "SupplyCrate.prefab.ron"), "w") as f:
        f.write(f'''// SUPPLY CRATE — a ribbed steel field crate left round the base (scripts/supply_crates.lua spawns
// one per layout spot, parented to the planet, origin {hy:.3f} m above the ground). Static: walk into
// it, stand on it; E (or right-click) opens it — the crew's storage between trips.
// Written by tools/gen_crate.py — edit the generator, not this file.
[
    (
        name: "SupplyCrate",
        tags: ["supply_crate"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/props/supply_crate.glb",
        ),
        object_materials: {{
{body},
        }},
        scripts: [],
        rigidbody: Some((
            boxed: true,
            mode: Static,
            radius: 0.3,
            height: {2 * hy},
            half_extents: ({hx}, {hy}, {hz}),
            restitution: 0.05,
            friction: 0.9,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.09,
        )),
    ),
]
''')
    print(f"  SupplyCrate size {np.round(size, 3).tolist()} centre {np.round(c, 3).tolist()} tris {m.tris()}")


if __name__ == "__main__":
    main()
