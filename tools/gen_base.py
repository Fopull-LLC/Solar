#!/usr/bin/env python3
"""Generate the SPACEPORT: the home base's buildings, launch complex, their
prefabs, and (through tools/base_tex.py) their textures and sign atlas.

    python3 tools/gen_base.py            # textures, models/base/*.glb, prefabs
    python3 tools/gen_base.py --dry      # sizes, seats, offsets, z-fight check

The structures themselves are tools/base_buildings.py (built from the
primitives in tools/base_models.py); the base is laid out by
scripts/base_facilities.lua. Each structure is built in a GROUND frame — the
ground is y = 0, the front faces +Z, the lot centre is x = z = 0 — then
shifted onto its own bounding-box centre, because the engine recentres a model
on its box. That shift is printed per model and copied into base_facilities'
FACILITIES table:

    seat    how far the prefab origin sits above the ground (the box centre's y)
    ox, oz  where the origin sits relative to the lot centre, in the model's
            own x / z (a crane or a ramp makes a box lopsided)

LOOK. Grounded hardware in the manner of Kennedy, Kourou and Baikonur: ribbed
steel cladding, cast concrete, painted steel, curtain-wall glass. Surfaces are
PBR texture sets (albedo + normal + ORM) at a modest resolution; colour is a
muted paint colour carried as a vertex colour (glTF COLOR_0), darkened toward
the ground and varied panel to panel. Signage is font-rendered plates from one
atlas. Nothing is pixel lettering.

NO Z-FIGHTING. Every model is checked for coplanar, same-facing, overlapping
faces (base_models.zcheck) before it is written, and the build fails on any.

DRAW COST. One glb per structure, at most six materials (Concrete, Clad,
Steel, Glass, Lamp, Sign).

Prefabs written (all Static, parented to the planet by base_facilities):
FacHangar, FacCommand, FacDepot, FacTracking, FacPower, BaseFuel, BasePad,
PadClamps (the hold-down posts vessel_spawner drops on the mount for a
launch) and BaseFlood (an apron floodlight's light).
"""
import json
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT, PREFABS  # noqa: E402
import base_tex  # noqa: E402

MODELS = os.path.join(ROOT, "models", "base")
TEX = "textures/base/"


def write_glb(model, path):
    """gen_part_meshes.write_glb plus COLOR_0 (float RGBA, linear)."""
    bin_ = bytearray()
    views, accs, prims, mats = [], [], [], []

    def view(data, target):
        nonlocal bin_
        while len(bin_) % 4:
            bin_ += b"\0"
        off = len(bin_)
        bin_ += data
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    for mi, mat in enumerate(sorted(model.parts.keys())):
        Ps, Ns, UVs, Is, _ = model.parts[mat]
        P = np.vstack(Ps).astype(np.float32)
        N = np.vstack(Ns)
        N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
        UV = np.vstack(UVs).astype(np.float32)
        I = np.vstack(Is).astype(np.uint32).reshape(-1)
        C = np.clip(np.vstack(model.cols[mat]), 0, 1)
        C = np.hstack([C, np.ones((len(C), 1))]).astype(np.float32)
        attrs = {}
        vp = view(P.tobytes(), 34962)
        accs.append({"bufferView": vp, "componentType": 5126, "count": len(P), "type": "VEC3",
                     "min": P.min(0).tolist(), "max": P.max(0).tolist()})
        attrs["POSITION"] = len(accs) - 1
        vn = view(N.tobytes(), 34962)
        accs.append({"bufferView": vn, "componentType": 5126, "count": len(N), "type": "VEC3"})
        attrs["NORMAL"] = len(accs) - 1
        vu = view(UV.tobytes(), 34962)
        accs.append({"bufferView": vu, "componentType": 5126, "count": len(UV), "type": "VEC2"})
        attrs["TEXCOORD_0"] = len(accs) - 1
        vc = view(C.tobytes(), 34962)
        accs.append({"bufferView": vc, "componentType": 5126, "count": len(C), "type": "VEC4"})
        attrs["COLOR_0"] = len(accs) - 1
        vi = view(I.tobytes(), 34963)
        accs.append({"bufferView": vi, "componentType": 5125, "count": len(I), "type": "SCALAR"})
        mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1],
                                                           "metallicFactor": 0.0, "roughnessFactor": 0.7}})
        prims.append({"attributes": attrs, "indices": len(accs) - 1, "material": mi})
    gl = {"asset": {"version": "2.0", "generator": "Solar tools/gen_base.py"},
          "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": os.path.splitext(os.path.basename(path))[0], "mesh": 0}],
          "meshes": [{"name": "base", "primitives": prims}],
          "materials": mats, "accessors": accs, "bufferViews": views,
          "buffers": [{"byteLength": len(bin_)}]}
    js = json.dumps(gl, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    while len(bin_) % 4:
        bin_ += b"\0"
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack("<II", len(bin_), 0x004E4942)); f.write(bytes(bin_))


# ── materials (prefab object_materials) ─────────────────────────────────────

def _pbr(tex, normal=1.0):
    t = TEX + tex
    return (f'(\n                color: (1.0, 1.0, 1.0),\n'
            f'                texture: Some("{t}_albedo.png"),\n'
            f'                normal_map: Some("{t}_normal.png"),\n'
            f'                normal_strength: {normal},\n'
            f'                roughness_map: Some("{t}_orm.png"),\n'
            f'                roughness: 1.0,\n'
            f'                metallic_map: Some("{t}_orm.png"),\n'
            f'                metallic: 1.0,\n'
            f'                ao_map: Some("{t}_orm.png"),\n'
            f'                shading: Physical,\n            )')


MATERIALS = {
    "Concrete": lambda: _pbr("concrete"),
    "Clad":     lambda: _pbr("cladding", normal=1.2),
    "Steel":    lambda: _pbr("steel"),
    # Opaque on purpose: a blended pane costs a pass of its own, and tinted
    # curtain wall reads as glass from outside by its reflection alone.
    "Glass":    lambda: ('(\n                color: (0.16, 0.20, 0.24),\n                roughness: 0.06,\n'
                         '                metallic: 0.5,\n                shading: Physical,\n            )'),
    "Lamp":     lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}lens.png"),\n'
                         '                unlit: true,\n                fog: false,\n            )'),
    # Screens: font-rendered displays from the sign atlas, unlit.
    "Screen":   lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}signs.png"),\n'
                         '                unlit: true,\n            )'),
    "Sign":     lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}signs.png"),\n'
                         '                roughness: 0.62,\n                metallic: 0.05,\n                shading: Physical,\n            )'),
}


# ── prefab writing ──────────────────────────────────────────────────────────

def quat_from_basis(M):
    """A rotation matrix → (x, y, z, w)."""
    m = np.asarray(M, float)
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        return ((m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s)
    if m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return (0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s)
    if m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return ((m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s)
    s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return ((m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s)


def spot_rotation(aim):
    """A node rotation whose local −Z points along `aim` (a spot's beam)."""
    f = -np.asarray(aim, float); f = f / np.linalg.norm(f)        # local +Z
    up = np.array([0.0, 1.0, 0.0])
    x = np.cross(up, f); x = x / np.linalg.norm(x)
    y = np.cross(f, x)
    return quat_from_basis(np.column_stack([x, y, f]))


def f3(v):
    return f"({v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f})"


def collider_block(half, mode="Static"):
    return f'''        rigidbody: Some((
            boxed: true,
            mode: {mode},
            radius: 0.5,
            height: 1.0,
            half_extents: {f3(half)},
            restitution: 0.0,
            friction: 0.9,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
        )),
'''


def prefab(name, glb, model, about, shell=None, lights=(), shift=(0, 0, 0), root_collider=None, tags=None, markers=()):
    names = sorted(model.parts.keys())
    mats = ",\n".join(f'            "{n}": {MATERIALS[n]()}' for n in names)
    tag_line = f"        tags: [{', '.join(chr(34) + t + chr(34) for t in tags)}],\n" if tags else ""
    out = [f'''// {about}
// Written by tools/gen_base.py — edit the generator, not this file.
[
    (
        name: "{name}",
{tag_line}        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/base/{glb}",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
{collider_block(root_collider) if root_collider is not None else ""}    ),
''']
    d = np.asarray(shift, float)
    for i, (c, s, q) in enumerate(shell.boxes if shell else []):
        out.append(f'''    (
        name: "Shell {i + 1}",
        transform: (
            translation: {f3(c - d)},
            rotation: ({q[0]:.5f}, {q[1]:.5f}, {q[2]:.5f}, {q[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
        cast_shadow: false,
{collider_block(s / 2)}    ),
''')
    # Marker nodes scripts look up by name (no matter, no body).
    for (mname, p) in markers:
        out.append(f'''    (
        name: "{mname}",
        transform: (
            translation: {f3(np.asarray(p, float) - d)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
    ),
''')
    for (lname, p, col, inten, rng, aim) in lights:
        rot = spot_rotation(aim) if aim is not None else (0.0, 0.0, 0.0, 1.0)
        spot = "            spot: Some((angle: 34.0, softness: 0.35)),\n" if aim is not None else ""
        out.append(f'''    (
        name: "{lname}",
        transform: (
            translation: {f3(np.asarray(p, float) - d)},
            rotation: ({rot[0]:.5f}, {rot[1]:.5f}, {rot[2]:.5f}, {rot[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: {f3(col)},
            intensity: {inten},
            range: {rng},
{spot}        ),
        scripts: [],
        parent: Some(0),
    ),
''')
    out.append("]\n")
    return "".join(out)


from base_buildings import (command_centre, depot, fuel_farm, launch_complex, pad_clamps,  # noqa: E402
                            power, tracking, vab)
from base_models import zcheck  # noqa: E402

BUILDS = [
    # prefab, glb, builder, what it is
    ("FacHangar", "vab.glb", vab,
     "VEHICLE ASSEMBLY BUILDING — the base's hangar (walk in through either high-bay door; E opens the builder)."),
    ("FacCommand", "command.glb", command_centre,
     "COMMAND CENTRE — the base HQ (walk in; E at the consoles opens the Ops Board)."),
    ("FacDepot", "depot.glb", depot,
     "COMMERCE DEPOT — warehouse, loading dock and gantry crane (walk in; E at the counter)."),
    ("FacTracking", "tracking.glb", tracking,
     "TRACKING STATION — the ground station's dish (comms.station = this origin + 6 m)."),
    ("FacPower", "power.glb", power,
     "POWER YARD — switch house, transformers, solar tables."),
    ("BaseFuel", "fuel.glb", fuel_farm,
     "PROPELLANT FARM — LH2 sphere, LOX tanks, pump house, deluge water tower."),
    ("BasePad", "pad.glb", launch_complex,
     "LAUNCH COMPLEX 1 — hardstand, flame trench and deflector, mount, service tower, lightning masts, floodlights."),
]


def write_sign_uv():
    """The atlas tiles base_facilities lays signs from, into its SIGN_UV block."""
    path = os.path.join(ROOT, "scripts", "base_facilities.lua")
    src = open(path).read()
    a = src.index("-- SIGN_UV begin\n") + len("-- SIGN_UV begin\n")
    b = src.index("-- SIGN_UV end")
    rows = ["SIGN_UV = {"]
    for k, (u0, v0, u1, v1) in sorted(base_tex.REGIONS.items()):
        if k.startswith("g_") or k in ("blast", "hazard"):
            rows.append(f'  ["{k}"] = {{ {u0:.5f}, {v0:.5f}, {u1:.5f}, {v1:.5f} }},')
    from base_models import region_aspect
    rows.append(f"  blast_aspect = {region_aspect('blast'):.4f},")
    rows.append("}")
    open(path, "w").write(src[:a] + "\n".join(rows) + "\n" + src[b:])


def main():
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    if dry:
        base_tex.signs()          # the atlas regions are needed to lay the plates
    else:
        base_tex.main()
    print("prefab        size (x, y, z)                seat     ox      oz     tris  boxes  mats")
    fights = 0
    for name, glb, fn, about in BUILDS:
        res = fn()
        m, sh, lights = res[0], res[1], res[2]
        markers = res[3] if len(res) > 3 else ()
        fights += zcheck(m, name)
        mn, mx = m.bounds()
        c = (mn + mx) / 2
        size = mx - mn
        mc = m.shifted(c)
        print(f"{name:12s} ({size[0]:6.2f}, {size[1]:6.2f}, {size[2]:6.2f})  {c[1]:7.3f} {c[0]:7.3f} {c[2]:7.3f} {m.tris():7d} {len(sh.boxes):4d}  {len(m.parts)}")
        if dry or fights:
            continue
        write_glb(mc, os.path.join(MODELS, glb))
        about2 = about + f"\n// Ground frame → origin: seat {c[1]:.3f} m, lot offset ox {c[0]:.3f}, oz {c[2]:.3f} (base_facilities FACILITIES)."
        with open(os.path.join(PREFABS, name + ".prefab.ron"), "w") as f:
            f.write(prefab(name, glb, mc, about2, shell=sh, lights=lights, shift=c, markers=markers))
    if not dry:
        # BaseFlood: one apron floodlight (a spot down its −Z). The mast and
        # the lamp housing are in base_facilities' fixtures mesh; this is only
        # the light, aimed there with node:lookAt.
        with open(os.path.join(PREFABS, "BaseFlood.prefab.ron"), "w") as f:
            f.write('''// BASE FLOOD — an apron floodlight's light (scripts/base_facilities.lua aims it with lookAt).
// Written by tools/gen_base.py — edit the generator, not this file.
[
    (
        name: "BaseFlood",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: PointLight(
            color: (1.0, 0.88, 0.70),
            intensity: 5.0,
            range: 70.0,
            spot: Some((angle: 42.0, softness: 0.4)),
        ),
        scripts: [],
    ),
]
''')
    if fights:
        print(f"!! {fights} z-fighting face pairs: nothing written")
        sys.exit(1)
    if not dry:
        write_sign_uv()
    pc = pad_clamps()
    mn, mx = pc.bounds()
    c = (mn + mx) / 2
    print(f"PadClamps    ({(mx - mn)[0]:6.2f}, {(mx - mn)[1]:6.2f}, {(mx - mn)[2]:6.2f})  centre {np.round(c, 3)}")
    if not dry:
        # The posts sit on the deck: the root is the deck box's centre (1.245
        # under its top), so the posts' local y is 1.245 + their half height.
        pcs = pc.shifted(c)
        write_glb(pcs, os.path.join(MODELS, "pad_clamps.glb"))
        text_ = prefab("PadClamps", "pad_clamps.glb", pcs,
                       "PAD CLAMPS — the hold-down posts vessel_spawner drops on Launch Complex 1's mount for a launch.\n"
                       "// The root collider is the old Launchpad deck box: its top is 1.245 over the origin (deck = 1.24).",
                       root_collider=(2.55, 1.245, 2.17))
        # the mesh is centred on the posts; lift it so they stand on the deck top
        text_ = text_.replace('        matter: Mesh(\n            asset_path: "models/base/pad_clamps.glb",\n        ),',
                              '        matter: Empty,', 1)
        text_ = text_.replace("    ),\n]\n", f'''    ),
    (
        name: "Clamp Posts",
        transform: (
            translation: (0.0, {1.245 + 0.25:.3f}, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/base/pad_clamps.glb",
        ),
        object_materials: {{
            "Steel": {MATERIALS["Steel"]()},
        }},
        scripts: [],
        parent: Some(0),
    ),
]
''', 1)
        # the root's object_materials belong to the posts node now
        i0 = text_.find("        object_materials: {")
        i1 = text_.find("        scripts: [],", i0)
        text_ = text_[:i0] + text_[i1:]
        with open(os.path.join(PREFABS, "PadClamps.prefab.ron"), "w") as f:
            f.write(text_)


if __name__ == "__main__":
    main()
