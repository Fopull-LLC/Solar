#!/usr/bin/env python3
"""The loose things the gravity gun has to play with: `python3 tools/gen_props.py`.

Writes

    models/tools/prop_can.glb      a cargo can (an enamel box with a hazard band)
    models/tools/prop_cone.glb     a traffic cone for the pads
    models/tools/loose_log.glb     a felled trunk (flora_field.fell leaves one)

and the prefabs that make each a one-part ASSEMBLY (the LooseRock pattern,
tools/gen_tools.py: an assembly root, a boxed kinematic part carrying the
mesh, the mass and the collider), so a pull at a grab point torques it like a
craft, and the strain gauge reads its mass:

    LooseBoulder   the terrain's own boulders, plucked out of the scatter
    LooseCrystal   a crystal outcrop, likewise
    LooseLog       a felled trunk
    PropCan        a cargo can, left round the depot and the pads
    PropCone       a cone on the pads
    PropCrate      a cargo crate (models/parts/cargo.glb)

Every tag is read by scripts/tool_belt.lua: `loose_rock` rocks and crystals
stow as their ore, `log` as timber, `prop` goes to the depot's intake.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import Model, box, tube, write_glb, mat_ron  # noqa: E402
from gen_tools import TOOL_MATS, centred, MODELS, PREFABS  # noqa: E402

MATS = dict(TOOL_MATS)
MATS["Bark"] = lambda: ('(\n                color: (0.62, 0.52, 0.42),\n'
                        '                texture: Some("textures/flora/bark_rough_l0.png"),\n'
                        '                roughness: 0.95,\n                metallic: 0.0,\n'
                        '                shading: Physical,\n            )')
MATS["Wood"] = lambda: ('(\n                color: (0.78, 0.62, 0.42),\n'
                        '                roughness: 0.85,\n                metallic: 0.0,\n'
                        '                shading: Physical,\n            )')
# models/parts/cargo.glb's own slots, in the base's enamel and signal orange.
MATS["Paint"] = lambda: mat_ron("paint", color=(0.97, 0.55, 0.22), hull=False)
MATS["Metal"] = lambda: mat_ron("metal", color=(0.42, 0.47, 0.55), rough=0.85, metal=0.5, hull=False)
MATS["Decal"] = lambda: ('(\n                color: (1.0, 1.0, 1.0),\n'
                         '                texture: Some("textures/parts/markings.png"),\n'
                         '                roughness: 0.55,\n                metallic: 0.0,\n'
                         '                shading: Physical,\n            )')
MATS["Stencil"] = lambda: ('(\n                color: (0.06, 0.06, 0.07),\n'
                           '                texture: Some("textures/parts/markings.png"),\n'
                           '                roughness: 0.6,\n                metallic: 0.0,\n'
                           '                shading: Physical,\n            )')
MATS["Crystal"] = lambda: ('(\n                color: (0.55, 0.85, 1.0),\n'
                           '                emissive: (0.35, 0.75, 1.0),\n'
                           '                emissive_strength: 0.5,\n'
                           '                roughness: 0.25,\n                metallic: 0.1,\n'
                           '                shading: Physical,\n            )')


def mats_block(names, indent="        "):
    body = ",\n".join(f'{indent}    "{n}": {MATS[n]()}' for n in sorted(names))
    return f"{indent}object_materials: {{\n{body},\n{indent}}},\n"


def prop_prefab(name, tags, about, model, mats, half, mass, scale=1.0):
    hx, hy, hz = half
    tag_s = ", ".join(f'"{t}"' for t in tags)
    return f'''// {about}
// Written by tools/gen_props.py — edit the generator, not this file.
[
    (
        name: "{name}",
        tags: [{tag_s}],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        rigidbody: Some((
            mode: Dynamic,
            radius: 0.3,
            height: 0.6,
            half_extents: ({hx}, {hy}, {hz}),
            restitution: 0.15,
            friction: 0.8,
            gravity: true,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            assembly: true,
        )),
    ),
    (
        name: "Body",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: ({scale}, {scale}, {scale}),
        ),
        matter: Mesh(
            asset_path: "{model}",
        ),
{mats_block(mats)}        scripts: [],
        rigidbody: Some((
            boxed: true,
            mode: Kinematic,
            radius: 0.3,
            height: 0.6,
            half_extents: ({hx}, {hy}, {hz}),
            restitution: 0.15,
            friction: 0.8,
            gravity: true,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: {mass},
        )),
        parent: Some(0),
    ),
]
'''


def can():
    m = Model()
    box(m, "Enamel", (0, 0, 0), (0.5, 0.62, 0.5), bevel=0.03, uv_m=2.0)
    box(m, "Hazard", (0, 0.12, 0), (0.505, 0.09, 0.505), uv_m=2.0)
    box(m, "Dark", (0, 0.33, 0), (0.42, 0.04, 0.42), uv_m=2.0)
    box(m, "Dark", (0, -0.33, 0), (0.46, 0.04, 0.46), uv_m=2.0)
    return m


def cone():
    m = Model()
    tube(m, "Hazard", (0, -0.33, 0), (0, 0.37, 0), 0.2, segs=20, r1=0.03)
    box(m, "Enamel", (0, -0.35, 0), (0.5, 0.04, 0.5))
    tube(m, "Enamel", (0, -0.02, 0), (0, 0.1, 0), 0.165, segs=20, r1=0.135)
    return m


def log():
    m = Model()
    rng = np.random.default_rng(3)
    # a trunk along X, a little taper, lumpy
    tube(m, "Bark", (-1.6, 0, 0), (1.6, 0, 0), 0.24, segs=14, caps=False, r1=0.19, uv_m=1.5)
    sub = Model()
    tube(sub, "Wood", (-1.61, 0, 0), (-1.59, 0, 0), 0.235, segs=14)
    tube(sub, "Wood", (1.59, 0, 0), (1.61, 0, 0), 0.185, segs=14)
    m.merge(sub)
    # two stubs of branch
    tube(m, "Bark", (0.4, 0.15, 0.1), (0.75, 0.55, 0.35), 0.07, segs=8, r1=0.04)
    tube(m, "Bark", (-0.7, 0.1, -0.15), (-0.95, 0.4, -0.45), 0.06, segs=8, r1=0.035)
    return m


def half_of(m, k=0.92):
    mn, mx = m.bounds()
    return tuple(np.round((mx - mn) / 2 * k, 3).tolist())


def main():
    os.makedirs(MODELS, exist_ok=True)
    out = []
    for fn, glb, name, tags, about, mass in (
        (can, "prop_can.glb", "PropCan", ["prop", "can"],
         "CARGO CAN — a loose enamel can left round the base (scripts/base_props.lua); the gravity gun's toy.", 0.07),
        (cone, "prop_cone.glb", "PropCone", ["prop", "cone"],
         "TRAFFIC CONE — on the pads (scripts/base_props.lua); light, so the gravity gun flings it.", 0.012),
        (log, "loose_log.glb", "LooseLog", ["log"],
         "FELLED LOG — what a cut tree leaves (scripts/flora_field.lua fell); timber at the depot, or stowed.", 0.42),
    ):
        m = fn()
        m, _ = centred(m)
        write_glb(m, os.path.join(MODELS, glb))
        half = half_of(m)
        with open(os.path.join(PREFABS, name + ".prefab.ron"), "w") as f:
            f.write(prop_prefab(name, tags, about, "models/tools/" + glb, m.parts.keys(), half, mass))
        out.append((name, half, m.tris()))
    # The boulder and the crystal: the scatter's own meshes, as a body.
    with open(os.path.join(PREFABS, "LooseBoulder.prefab.ron"), "w") as f:
        f.write(prop_prefab("LooseBoulder", ["loose_rock", "boulder"],
                            "LOOSE BOULDER — a terrain boulder plucked out of the scatter by the gravity gun (scripts/tool_belt.lua). Heavy: it drags, it does not lift.",
                            "models/tools/loose_rock.glb", ["Rock"], (0.637, 0.377, 0.559), 0.9, scale=2.3))
    with open(os.path.join(PREFABS, "LooseCrystal.prefab.ron"), "w") as f:
        f.write(prop_prefab("LooseCrystal", ["loose_rock", "crystal"],
                            "LOOSE CRYSTAL — an outcrop plucked out of the scatter by the gravity gun (scripts/tool_belt.lua).",
                            "models/flora/rock_crystal_l0.gltf", ["Bark", "Crystal"], (0.33, 0.55, 0.39), 0.16, scale=0.42))
    with open(os.path.join(PREFABS, "PropCrate.prefab.ron"), "w") as f:
        f.write(prop_prefab("PropCrate", ["prop", "crate"],
                            "CARGO CRATE — a loose crate round the depot (scripts/base_props.lua); the gravity gun's toy.",
                            "models/parts/cargo.glb", ["Dark", "Decal", "Metal", "Paint", "Stencil"], (0.273, 0.248, 0.253), 0.14, scale=0.55))
    for name, half, tris in out:
        print(f"  {name:12s} half {half} tris {tris}")


if __name__ == "__main__":
    main()
