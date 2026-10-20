#!/usr/bin/env python3
"""Generate the COMMAND SEAT (KSP's external seat): models/parts/seat.glb and
prefabs/PartSeat.prefab.ron.

    python3 tools/gen_seat.py

Built from tools/gen_part_meshes.py's primitives and shared material set, so
it wears the same textures as every other part. The seat FACES +X (a rover's
front) and its centre — which is where the engine centres the model — is where
the rider's origin goes: scripts/command_seat.lua parks the astronaut there and
bends its legs onto the footrest. The astronaut's hip joints are 0.04 m below
its origin, its knees 0.40 m out and its ankles 0.48 m below them, so the
cushion top is at -0.16 and the footrest at -0.56, 0.40 m ahead.

The model is symmetric about its centre on every axis (the base plate spans
x ±0.45 and the headrest reaches the same height above as the plate sits
below), so the engine's recentring moves nothing.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import (MATERIALS, MODELS, PREFABS, Model, box, check_centered,  # noqa: E402
                             rot_z, tube, write_glb)

H = 1.30         # REG seat.h
HALF = H / 2


def seat_model():
    m = Model()
    # base plate (bolts to the deck) and the pedestal under the pan
    box(m, "Dark", (0.0, -HALF + 0.03, 0.0), (0.90, 0.06, 0.60), uv_m=1.0, bevel=0.01)
    box(m, "Metal", (-0.06, -0.41, 0.0), (0.14, 0.38, 0.16))
    for z in (-0.2, 0.2):
        tube(m, "Metal", (0.30, -HALF + 0.06, z), (0.38, -0.56, z), 0.018, segs=8)
        tube(m, "Metal", (-0.30, -HALF + 0.06, z), (-0.06, -0.24, z * 0.6), 0.018, segs=8)
    # the pan and its cushion
    box(m, "Paint3", (0.0, -0.215, 0.0), (0.48, 0.05, 0.52))
    box(m, "Rubber", (0.01, -0.175, 0.0), (0.44, 0.04, 0.46))
    # backrest, raked back 12°, with its cushion and a headrest
    rake = rot_z(math.radians(12))
    box(m, "Paint3", (-0.29, 0.12, 0.0), (0.05, 0.62, 0.52), M=rake)
    box(m, "Rubber", (-0.255, 0.12, 0.0), (0.03, 0.56, 0.44), M=rake)
    box(m, "Paint3", (-0.37, 0.545, 0.0), (0.07, 0.21, 0.30), M=rake)
    # armrests on posts, and the stick on the right one (facing +X with +Y up,
    # the pilot's right is +Z)
    for z in (-0.275, 0.275):
        box(m, "Dark", (-0.03, -0.03, z), (0.38, 0.045, 0.06))
        tube(m, "Metal", (0.12, -0.19, z), (0.12, -0.05, z), 0.016, segs=8)
    tube(m, "Chrome", (0.13, -0.01, 0.275), (0.17, 0.11, 0.275), 0.014, segs=10)
    box(m, "PaintOrange", (0.17, 0.125, 0.275), (0.04, 0.04, 0.04))
    # footrest
    box(m, "Yellow", (0.38, -0.565, 0.0), (0.14, 0.03, 0.46))
    # harness straps
    for z in (-0.1, 0.1):
        box(m, "PaintOrange", (-0.235, 0.12, z), (0.012, 0.52, 0.035), M=rake)
    # balance the box: the plate sets x ±0.45 and the bottom; the headrest's
    # top must reach +HALF (checked below)
    return m


def prefab_text(model):
    names = sorted(model.parts.keys())
    mats = ",\n".join(f'            "{n}": {MATERIALS[n]()}' for n in names)
    return f'''// COMMAND SEAT — an open chair that commands the craft (KSP's external seat).
// Written by tools/gen_seat.py — edit the generator, not this file.
// scripts/command_seat.lua seats the rider while the craft is crewed from it.
[
    (
        name: "PartSeat",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/parts/seat.glb",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [
            (
                kind: "command_seat",
                enabled: true,
                params: [],
            ),
        ],
        rigidbody: Some((
            boxed: true,
            mode: Kinematic,
            radius: 0.45,
            height: {H},
            half_extents: (0.45, {HALF}, 0.3),
            restitution: 0.05,
            friction: 0.6,
            gravity: true,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.05,
        )),
    ),
]
'''


def main():
    m = seat_model()
    mn, mx = m.bounds()
    print("seat bounds", np.round(mn, 3), np.round(mx, 3))
    ok = check_centered("seat", m)
    write_glb(m, os.path.join(MODELS, "seat.glb"))
    with open(os.path.join(PREFABS, "PartSeat.prefab.ron"), "w") as f:
        f.write(prefab_text(m))
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
