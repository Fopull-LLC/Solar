#!/usr/bin/env python3
"""First-person view models of the held items (playtest 2026-11-04: "add
first-person models for holding each holdable item"): the Repair Kit, the
Medkit, the Gas Can, the stowed Relay Beacon, the furled Company Flag and the
Rope Kit (tools/gen_rope.py's bag), each
in the crew's gloved hands (tools/fp_hands.py).

    python3 tools/gen_fp_items.py [item …]     (only those; default all)

Writes models/items/fp_<item>.glb and prefabs/Item<Name>FP.prefab.ron, and
prints scripts/tool_belt.lua's FP_ITEMS lines.

Each model is built IN THE VIEW'S OWN FRAME (+X right, +Y up, -Z ahead,
metres from the eye), the way the item is seen held: the cases (the kit, the
pouch, the can) by their handles in the LEFT hand, low left, as the third
person carries them; the beacon by its mast and the flag by its pole in the
RIGHT hand, low right. The item's own mesh is its generator's (tools/
gen_items.py's Blender build, tools/gen_gas_parts.py's can), so the two never
disagree; its materials are copied from its own prefab, the gloves' from the
tools' (tools/gen_tools.py). The engine recentres a model on its box, so the
model is written centred and tool_belt places it at `at` (its centre in the
view) and turns the sway about `grip` (the hand's hold, from that centre).
"""
import math
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fp_hands as H  # noqa: E402
from gen_part_meshes import PREFABS, ROOT, Model, recenter, write_glb  # noqa: E402

MODELS = os.path.join(ROOT, "models", "items")


def _n(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def frame_from(Y, Z):
    """The rotation that takes an item's +Y to Y and its +Z as near Z as allows."""
    Y = _n(Y)
    Z = _n(np.asarray(Z, float) - Y * (Y @ np.asarray(Z, float)))
    X = np.cross(Y, Z)
    return np.stack([X, Y, Z], 1)


# ── the items' meshes, from their own generators ───────────────────────────

_ITEMS = {}


def item_mesh(key):
    """(the item's Model in its own frame, centred as its glb is, and the
    offset its generator's raw coordinates have to that centre)."""
    if key == "rope":
        import gen_rope as G
        m, c, _ = G.centred(G.kit_model())
        return m, c
    if key == "gascan":
        import gen_gas_parts as G
        m, c = recenter(G.gas_can())
        return m, c
    if not _ITEMS:
        import gen_items
        _ITEMS.update(gen_items.blender_items())
    import gen_items
    m, c, _ = gen_items.model_of(_ITEMS[key])
    return m, c


def prefab_mats(prefab):
    """The object_materials entries of an existing prefab, as text."""
    s = open(os.path.join(PREFABS, prefab + ".prefab.ron")).read()
    i = s.index("object_materials: {") + len("object_materials: {")
    depth, j = 1, i
    while depth:
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
        j += 1
    body = s[i:j - 1].rstrip().rstrip(",")
    names = re.findall(r'^\s*"([^"]+)":', body, re.M)
    return body, set(names)


# ── the designs ────────────────────────────────────────────────────────────
#
# Per item: the item's turn in the view (where its +Y and +Z point), where its
# hold (`grip`, in the generator's raw frame) lands in the view, the bar the
# hand closes on (raw: a point, the axis and the radius) and the hand: which,
# the back of the hand's direction in the view, where the elbow is.

H_KIT = 0.22
H_MED = 0.13
LB = 0.88
LP = 1.45
DESIGNS = {
    # the case by its handle, the left hand round the rubber bar from above,
    # lifted to the hip in front so its lid and stencils show; long side ahead
    "repairkit": dict(prefab="ItemRepairKit", fp="ItemRepairKitFP", glb="fp_repair_kit.glb",
                      about="REPAIR KIT, first person — carried by its handle in the left glove (scripts/tool_belt.lua FP_ITEMS).",
                      Y=(0.10, 1.0, 0.30), Z=(0.30, -0.06, -1.0), at=(-0.150, -0.105, -0.45),
                      grip=(0.0, H_KIT + 0.050, 0.0), axis=(0, 0, 1), r=0.0145, side="L",
                      dorsal=(-1.0, 0.55, 0.15), elbow=(-0.25, -0.50, -0.10), slide=0.004),
    # the pouch by its grab loop: a hook grip on the webbing
    "medkit": dict(prefab="ItemMedkit", fp="ItemMedkitFP", glb="fp_medkit.glb",
                   about="MEDKIT, first person — carried by its grab loop in the left glove (scripts/tool_belt.lua FP_ITEMS).",
                   Y=(0.10, 1.0, 0.32), Z=(0.30, -0.06, -1.0), at=(-0.145, -0.095, -0.42),
                   grip=(0.0, H_MED + 0.033, 0.0), axis=(0, 0, 1), r=0.0075, side="L",
                   dorsal=(-1.0, 0.55, 0.15), elbow=(-0.24, -0.48, -0.10), slide=0.0),
    # the jerry can by its top handle, spout ahead
    "gascan": dict(prefab="ItemGasCan", fp="ItemGasCanFP", glb="fp_gas_can.glb",
                   about="GAS CAN, first person — carried by its handle in the left glove; tipped to pour (scripts/tool_belt.lua FP_ITEMS).",
                   Y=(0.10, 1.0, 0.30), Z=(0.30, -0.06, -1.0), at=(-0.150, -0.100, -0.45),
                   grip=(0.0, 0.135, 0.0), axis=(0, 0, 1), r=0.012, side="L",
                   dorsal=(-1.0, 0.55, 0.15), elbow=(-0.25, -0.50, -0.10), slide=0.0),
    # the folded beacon carried upright by the narrow top of its mast, the cap
    # over the fist, the rest hanging below out of the view
    "beacon": dict(prefab="ItemBeaconStowed", fp="ItemBeaconStowedFP", glb="fp_beacon_stowed.glb",
                   about="RELAY BEACON, first person — carried upright by its mast in the right glove (scripts/tool_belt.lua FP_ITEMS).",
                   Y=(-0.10, 1.0, 0.18), Z=(0.0, 0.0, -1.0), at=(0.200, -0.130, -0.50),
                   grip=(0.0, LB * 0.875, 0.0), axis=(0, 1, 0), r=0.0415, side="R",
                   dorsal=(0.85, 0.0, 0.55), elbow=(0.27, -0.50, -0.10), slide=0.0),
    # the Rope Kit's bag by the webbing grab handle across its mouth, a hook
    # grip like the medkit's loop, the bag and the strapped davit hanging below
    "rope": dict(prefab="ItemRopeKit", fp="ItemRopeKitFP", glb="fp_rope_kit.glb",
                 about="ROPE KIT, first person — the rope bag carried by its grab handle in the left glove (scripts/tool_belt.lua FP_ITEMS).",
                 Y=(0.10, 1.0, 0.30), Z=(0.30, -0.06, -1.0), at=(-0.150, -0.100, -0.43),
                 grip=(-0.045, 0.320, 0.0), axis=(0, 0, 1), r=0.0085, side="L",
                 dorsal=(-1.0, 0.55, 0.15), elbow=(-0.24, -0.48, -0.10), slide=0.0),
    # the furled flag by its pole, the sleeve leaning up and away
    "flag": dict(prefab="ItemFlagFurled", fp="ItemFlagFurledFP", glb="fp_flag_furled.glb",
                 about="COMPANY FLAG, first person — the furled flag carried by its pole in the right glove (scripts/tool_belt.lua FP_ITEMS).",
                 Y=(-0.22, 1.0, -0.42), Z=(0.0, 0.3, 1.0), at=(0.200, -0.160, -0.48),
                 grip=(0.0, LP * 0.30, 0.0), axis=(0, 1, 0), r=0.0165, side="R",
                 dorsal=(0.85, 0.0, 0.55), elbow=(0.26, -0.50, -0.08), slide=0.0),
}


def build(key):
    d = DESIGNS[key]
    item, c = item_mesh(key)
    R = frame_from(d["Y"], d["Z"])
    g_c = np.asarray(d["grip"], float) - c                 # the hold, in the centred item frame
    at = np.asarray(d["at"], float)
    t = at - R @ g_c                                       # the item's centre in the view
    m = Model()
    m.merge(item, R, t)
    # the hand: closed round the bar through the hold, along the item's axis
    ax = R @ np.asarray(d["axis"], float)
    side = d["side"]
    # the bar's axis toward the index finger: ahead for the cases, up for the poles
    if side == "L" and ax[2] > 0:
        ax = -ax
    if side == "R" and ax[1] < 0:
        ax = -ax
    pose = H.Pose(curl=0.0, thumb=dict(abd=0.8, flex=0.45, rot=-0.4))
    fa = np.asarray(d["elbow"], float) - at
    M = H.on_cylinder(at, ax, d["dorsal"], d["r"], side=side, slide=d["slide"], forearm=fa)
    H.wrap(pose, M, at, ax, d["r"], side=side, thumb=True)
    H.glove(m, M, pose, side=side, elbow=0.30)
    mc, centre = recenter(m)
    return mc, centre, at - centre


def prefab_text(d, model):
    body, have = prefab_mats(d["prefab"])
    import gen_tools as T
    extra = []
    for name in sorted(model.parts.keys()):
        if name not in have:
            extra.append(f'            "{name}": {T.TOOL_MATS[name]()}')
    mats = body + (",\n" + ",\n".join(extra) if extra else "")
    return f'''// {d["about"]}
// Written by tools/gen_fp_items.py — edit the generator, not this file.
[
    (
        name: "{d["fp"]}",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/{d["glb"]}",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
    ),
]
'''


def main():
    only = set(a for a in sys.argv[1:] if not a.startswith("-"))
    os.makedirs(MODELS, exist_ok=True)
    lines = []
    for key, d in DESIGNS.items():
        if only and key not in only:
            continue
        m, centre, grip = build(key)
        write_glb(m, os.path.join(MODELS, d["glb"]))
        with open(os.path.join(PREFABS, d["fp"] + ".prefab.ron"), "w") as f:
            f.write(prefab_text(d, m))
        mn, mx = m.bounds()
        print(f"  {key:10s} tris {m.tris()} size {np.round(mx - mn, 3).tolist()}")
        f3 = lambda v: "{ " + ", ".join(f"{x:.3f}" for x in v) + " }"  # noqa: E731
        lines.append(f'  {key} = {{ prefab = "{d["fp"]}", at = {f3(centre)}, grip = {f3(grip)} }},')
    print("tool_belt's FP_ITEMS lines:")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
