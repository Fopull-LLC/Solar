#!/usr/bin/env python3
"""Generate the RELAY BEACON: models/parts/beacon.glb and its three prefabs.

    python3 tools/gen_beacon.py

The beacon is the cheap ground relay the crew carries and plants on the
ground (scripts/comms.lua keeps the network of them, scripts/tool_belt.lua
places them). It is a folding tripod-and-mast: four splayed legs, a battery
box at the foot, a small solar trickle panel half way up, and an omni whip
with a blinker on top. H is the whole thing, feet to whip tip; the engine
recentres a model on its bounding box, so the model is built symmetric about
its centre and the node's origin is H/2 above the ground it stands on
(comms.BEACON.seat).

Prefabs written:
    RelayBeacon        planted on the ground (Static collider round the mast)
    RelayBeaconGhost   the placement preview, teal (mesh only, one translucent glow)
    RelayBeaconGhostBad   the same, red (it can't stand there)
    PartBeacon         the same beacon as a craft part (builder REG `beacon`)

Built from tools/gen_part_meshes.py's primitives and shared material set, so it
wears the same textures as every other part.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import (MATERIALS, MODELS, PREFABS, Model, box, check_centered,  # noqa: E402
                             rot_y, tube, write_glb)

H = 4.2          # feet to whip tip (electronics COMMS.beacon.height, builder REG beacon.h)
HALF = H / 2
FOOT = 0.45      # leg spread (half-width of the footprint)


def beacon_model():
    m = Model()
    y0, y1 = -HALF, HALF
    # four splayed legs from a collar on the mast down to pads on the ground
    collar = y0 + 0.62
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        fx, fz = math.cos(a) * (FOOT - 0.05), math.sin(a) * (FOOT - 0.05)
        tube(m, "Metal", (0.0, collar, 0.0), (fx, y0 + 0.04, fz), 0.016, segs=8)
        box(m, "Rubber", (fx, y0 + 0.02, fz), (0.10, 0.04, 0.10), M=rot_y(a))
    tube(m, "Dark", (0.0, collar - 0.03, 0.0), (0.0, collar + 0.05, 0.0), 0.045, segs=12)
    # the battery box at the foot of the mast, and its stencilled lid
    box(m, "Paint2", (0.0, y0 + 0.30, 0.0), (0.24, 0.26, 0.24), bevel=0.015)
    box(m, "PaintOrange", (0.0, y0 + 0.445, 0.0), (0.25, 0.03, 0.25))
    # the mast, two telescoping sections
    tube(m, "Chrome", (0.0, y0 + 0.46, 0.0), (0.0, y0 + 1.45, 0.0), 0.028, segs=10)
    tube(m, "Chrome", (0.0, y0 + 1.45, 0.0), (0.0, y1 - 0.38, 0.0), 0.02, segs=10)
    tube(m, "Dark", (0.0, y0 + 1.42, 0.0), (0.0, y0 + 1.49, 0.0), 0.034, segs=10)
    # the solar trickle panel, tilted 35° off the mast on a short arm
    tilt = np.array([[1, 0, 0], [0, math.cos(0.61), -math.sin(0.61)], [0, math.sin(0.61), math.cos(0.61)]])
    tube(m, "Metal", (0.0, y0 + 1.15, 0.0), (0.0, y0 + 1.15, 0.12), 0.012, segs=6)
    box(m, "Metal", (0.0, y0 + 1.15, 0.16), (0.40, 0.30, 0.02), M=tilt)
    box(m, "Solar", (0.0, y0 + 1.15 + 0.008, 0.16 - 0.006), (0.37, 0.27, 0.01), M=tilt)
    # the radio head: a small drum with the omni whip and a ground-plane cross
    tube(m, "Paint3", (0.0, y1 - 0.40, 0.0), (0.0, y1 - 0.28, 0.0), 0.06, segs=14)
    for k in range(4):
        a = k * math.pi / 2
        tube(m, "Chrome", (0.0, y1 - 0.34, 0.0),
             (math.cos(a) * 0.30, y1 - 0.42, math.sin(a) * 0.30), 0.006, segs=6)
    tube(m, "Chrome", (0.0, y1 - 0.28, 0.0), (0.0, y1 - 0.04, 0.0), 0.008, segs=8)
    # the blinker cap tops the box
    tube(m, "PaintOrange", (0.0, y1 - 0.06, 0.0), (0.0, y1, 0.0), 0.022, segs=10)
    # keep the box symmetric in x/z: the panel reaches +z, a counterweight -z
    box(m, "Dark", (0.0, y0 + 1.15, -0.30), (0.06, 0.08, 0.06))
    return m


COLLIDER = '''        rigidbody: Some((
            boxed: true,
            mode: {mode},
            radius: 0.3,
            height: {H},
            half_extents: (0.3, {HALF}, 0.3),
            restitution: 0.05,
            friction: 0.8,
            gravity: {grav},
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.02,
        )),
'''


def prefab_text(model, name, about, tags=None, collider=None):
    names = sorted(model.parts.keys())
    mats = ",\n".join(f'            "{n}": {MATERIALS[n]()}' for n in names)
    tag_line = f"        tags: [{', '.join(chr(34) + t + chr(34) for t in tags)}],\n" if tags else ""
    body = collider or ""
    return f'''// {about}
// Written by tools/gen_beacon.py — edit the generator, not this file.
[
    (
        name: "{name}",
{tag_line}        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/parts/beacon.glb",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
{body}    ),
]
'''


def ghost_text(name, rgb, about):
    r, g, b = rgb
    return f'''// {about}
// Written by tools/gen_beacon.py — edit the generator, not this file.
// One flat translucent glow over the whole model (no per-part materials: a
// node material over the parts' hull shader drew black).
[
    (
        name: "{name}",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/parts/beacon.glb",
        ),
        material: Some((
            color: ({r}, {g}, {b}),
            emissive: ({r}, {g}, {b}),
            emissive_strength: 0.8,
            unlit: true,
            alpha: 0.5,
        )),
        scripts: [],
    ),
]
'''


def main():
    m = beacon_model()
    mn, mx = m.bounds()
    print("beacon bounds", np.round(mn, 3), np.round(mx, 3))
    ok = check_centered("beacon", m)
    write_glb(m, os.path.join(MODELS, "beacon.glb"))
    files = {
        "RelayBeacon": prefab_text(
            m, "RelayBeacon",
            "RELAY BEACON — planted on the ground by the crew (scripts/comms.lua spawns one per\n"
            "// placed beacon, parented to its planet; origin H/2 above the ground).",
            tags=["RelayBeacon"],
            collider=COLLIDER.format(mode="Static", H=H, HALF=HALF, grav="false")),
        "RelayBeaconGhost": ghost_text(
            "RelayBeaconGhost", (0.30, 0.95, 0.80),
            "RELAY BEACON GHOST — the placement preview where it can stand (scripts/tool_belt.lua)."),
        "RelayBeaconGhostBad": ghost_text(
            "RelayBeaconGhostBad", (1.0, 0.38, 0.30),
            "RELAY BEACON GHOST, red — the placement preview where it can't (scripts/tool_belt.lua)."),
        "PartBeacon": prefab_text(
            m, "PartBeacon",
            "RELAY BEACON as a craft part (builder REG `beacon`): a cheap low-power relay.",
            collider=COLLIDER.format(mode="Kinematic", H=H, HALF=HALF, grav="true")),
    }
    for name, text in files.items():
        with open(os.path.join(PREFABS, name + ".prefab.ron"), "w") as f:
            f.write(text)
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
