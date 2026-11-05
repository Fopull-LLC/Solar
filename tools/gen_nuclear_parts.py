#!/usr/bin/env python3
"""Generate the HEAT AND NUCLEAR parts (deep-space step 3, scripts/parts_nuclear.lua):
the Isotope Cell, the Radiator Fin, the Radiator Panel and the Truss Radiator
(both fold like a solar panel about a SolarWingPivot), the Shadow Shield and
the Ember reactor; and the FUEL ROD items: the rod held over the shoulder
(ItemFuelRod / ItemSpentRod) and its loose physics body (FuelRodBody /
SpentRodBody: a 40 kg box collider, ready for the gravity gun).

    python3 tools/gen_nuclear_parts.py          # meshes, prefabs, vis prefabs
    python3 tools/gen_nuclear_parts.py --dry    # print the bounds only

Built from tools/gen_part_meshes.py's primitives and the shared texture
library (textures/parts/), like tools/gen_storage_parts.py. Only its own files
are written.

FRAMES (parts_nuclear.lua holds the same boxes, rx / h / rz):
* radial parts (the cell, the radiators): +X out of the face they mount on,
  the hull at -X, +Y up the stack, the radiating faces ±Z.
* a folding radiator's wing is authored in its HINGE frame (the pin at the
  origin, the panel out along +X), hung under SolarWingPivot at the hinge;
  the flight folds it to yaw +90° for launch (vessel_controller ANIMS.solar).
* stack parts (shield, Ember): Y up. The Ember's radiation cone opens along
  its +Y: the converters and the radiator deck are on top, the core low.
* items: along +Y, slung over the shoulder (scripts/item_hand.lua).
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_part_meshes as G  # noqa: E402
from gen_part_meshes import Model, box, tube, lathe, disk, bolt_ring, rot_y, rot_z  # noqa: E402

TAU = 2 * math.pi
G.MATERIALS.setdefault("Steel", lambda: G.mat_ron("metal", color=(0.70, 0.70, 0.68), rough=0.8, metal=0.6))
G.MATERIALS.setdefault("Radiator", lambda: G.mat_ron("paint", color=(0.93, 0.93, 0.90), rough=1.1))
G.MATERIALS.setdefault("FinBlack", lambda: G.mat_ron("paint", color=(0.10, 0.10, 0.11), rough=1.2))
G.MATERIALS.setdefault("Zircaloy", lambda: G.mat_ron("metal", color=(0.78, 0.78, 0.80), rough=0.7, metal=0.7))
G.MATERIALS.setdefault("Burnt", lambda: G.mat_ron("bell", color=(0.42, 0.36, 0.34), rough=1.2, metal=0.5))
G.MATERIALS.setdefault("Tungsten", lambda: G.mat_ron("metal", color=(0.42, 0.43, 0.45), rough=0.9, metal=0.7))
G.MATERIALS.setdefault("Copper", lambda: G.mat_ron("metal", color=(0.80, 0.50, 0.32), rough=0.7, metal=0.8))


def hazard_band(m, r, y0, y1, n=16):
    """Black and yellow hazard stripes round a cylinder (the one place the
    style allows them: something here is actually dangerous)."""
    for k in range(n):
        a0, a1 = TAU * k / n, TAU * (k + 1) / n
        lathe(m, "Yellow" if k % 2 == 0 else "Paint3", [(r, y0), (r, y1)], segs=3, a0=a0, a1=a1, uv_m=4.0)


# ── the parts ───────────────────────────────────────────────────────────────

def isotope_cell():
    """An MMRTG-style generator on a short boom: the finned heat-source drum
    along the part's +X (built along Y, then turned), eight black fins, end
    flanges, a terminal box and its cable, the mounting saddle at -X."""
    m = Model()
    L0, L1 = -0.24, 0.34                          # the drum (y here, x after the turn)
    lathe(m, "Steel", [(0.0, L0 - 0.02), (0.10, L0 - 0.02), (0.10, L1), (0.0, L1)], segs=32, uv_m=3.0)
    for y in (L0, L1 - 0.02):                     # end flanges
        G.flange(m, "Metal", y - 0.012, y + 0.012, 0.0, 0.13, segs=32)
        bolt_ring(m, "Dark", y + 0.013, 0.115, 8, size=0.008, height=0.006)
    for k in range(8):                            # the fins
        a = TAU * k / 8 + TAU / 16
        M = rot_y(-a)
        c = M @ np.array([0.21, 0.0, 0.0])
        box(m, "FinBlack", (c[0], (L0 + L1) / 2, c[2]), (0.22, (L1 - L0) - 0.05, 0.012), M=M, uv_m=4.0)
        e = M @ np.array([0.315, 0.0, 0.0])        # the fin's rolled edge
        tube(m, "FinBlack", (e[0], L0 + 0.03, e[2]), (e[0], L1 - 0.03, e[2]), 0.007, segs=6)
    box(m, "Dark", (0.0, L1 + 0.012, 0.0), (0.09, 0.03, 0.07), uv_m=8.0)          # terminal box
    tube(m, "Dark", (0.0, L1 + 0.02, 0.03), (0.0, L1 + 0.02, 0.12), 0.012, segs=8)
    # the saddle and its four struts, at the hull end
    box(m, "Dark", (0.0, -0.345, 0.0), (0.24, 0.03, 0.24), uv_m=5.0)
    for sx in (-1, 1):
        for sz in (-1, 1):
            tube(m, "Metal", (sx * 0.09, -0.335, sz * 0.09), (sx * 0.06, L0 - 0.03, sz * 0.06), 0.012, segs=8)
    box(m, "Stencil", (0.0, 0.05, 0.102), (0.08, 0.05, 0.003), uv_m=1.0)
    out = Model()
    out.merge(m, rot_z(-math.pi / 2))             # +Y of the build → +X out of the hull
    return out, (0.36, 0.32, 0.32)


def radiator_fin():
    """A fixed corrugated aluminium fin: coolant headers along the root and
    the edges, pressed ribs, a root bracket. Passive (heat pipes)."""
    m = Model()
    x0, x1, yh = -0.28, 0.31, 0.43
    box(m, "Radiator", ((x0 + x1) / 2, 0, 0), (x1 - x0, 2 * yh, 0.010), uv_m=2.0)
    for i in range(9):                            # ribs on both faces
        y = -yh + 0.06 + i * (2 * yh - 0.12) / 8
        for sz in (-1, 1):
            box(m, "Metal", ((x0 + x1) / 2 + 0.02, y, sz * 0.009), (x1 - x0 - 0.06, 0.012, 0.008), uv_m=6.0)
    tube(m, "Metal", (x0, -yh, 0), (x0, yh, 0), 0.02, segs=10)                # root header
    tube(m, "Metal", (x0, yh, 0), (x1, yh, 0), 0.010, segs=8)                 # edge pipes
    tube(m, "Metal", (x0, -yh, 0), (x1, -yh, 0), 0.010, segs=8)
    box(m, "Dark", (-0.30, 0, 0), (0.04, 0.34, 0.07), uv_m=6.0, bevel=0.006)  # bracket
    box(m, "Stencil", (0.10, -0.30, 0.007), (0.10, 0.03, 0.002), uv_m=1.0)
    return m, (0.32, 0.45, 0.04)


def wing_yoke(hinge_x, back_x, size=1.0):
    """A folding radiator's yoke on the hull: a block, an arm to the hinge
    knuckle, and the flexible coolant hoses that cross the hinge."""
    m = Model()
    box(m, "Dark", (back_x, 0, 0), (0.08 * size, 0.20 * size, 0.11 * size), uv_m=4.0, bevel=0.008)
    tube(m, "Metal", (back_x + 0.04, 0, 0), (hinge_x - 0.012, 0, 0), 0.022 * size, segs=10)
    tube(m, "Metal", (hinge_x, -0.08 * size, 0), (hinge_x, 0.08 * size, 0), 0.025 * size, segs=12)
    for z in (-0.035, 0.035):
        tube(m, "Rubber", (back_x + 0.04, 0.05 * size, z * size), (hinge_x, 0.06 * size, z * size), 0.010, segs=8)
    return m


def radiator_wing(length, yh, n_panels, tube_r=0.012):
    """A radiator wing in its hinge frame: n white panels out along +X in the
    X–Y plane, faces ±Z, framed, with the coolant manifold at the hinge and
    the feed and return lines along the edges."""
    m = Model()
    x0, x1 = 0.03, length
    gap = 0.02
    w = (x1 - x0 - gap * (n_panels - 1)) / n_panels
    for i in range(n_panels):
        a = x0 + i * (w + gap)
        box(m, "Radiator", (a + w / 2, 0, 0), (w, 2 * yh - 0.03, 0.008), uv_m=1.5)
        for j in range(5):                         # the flow tubes across each panel
            y = -yh + 0.08 + j * (2 * yh - 0.16) / 4
            for sz in (-1, 1):
                box(m, "Metal", (a + w / 2, y, sz * 0.006), (w - 0.02, 0.008, 0.004), uv_m=6.0)
        if i < n_panels - 1:                       # a hinge line between panels
            tube(m, "Metal", (a + w + gap / 2, -yh, 0), (a + w + gap / 2, yh, 0), 0.006, segs=6)
    tube(m, "Metal", (x0 - 0.01, -yh, 0), (x0 - 0.01, yh, 0), tube_r * 1.6, segs=10)   # manifold
    tube(m, "Metal", (x0, yh, 0), (x1, yh, 0), tube_r, segs=8)                          # feed
    tube(m, "Metal", (x0, -yh, 0), (x1, -yh, 0), tube_r, segs=8)                        # return
    tube(m, "Metal", (x1, -yh, 0), (x1, yh, 0), tube_r * 0.8, segs=8)
    box(m, "Metal", (0.012, 0, 0), (0.024, 0.14, 0.03), uv_m=4.0)                        # hinge leaf
    box(m, "Stencil", (x0 + 0.12, -yh + 0.05, 0.006), (0.12, 0.03, 0.002), uv_m=1.0)
    return m


def shadow_shield():
    """A shadow shield: a frustum of tungsten over a canned lithium-hydride
    core, flanged both faces and bolted, a hazard band on its rim."""
    m = Model()
    lathe(m, "Tungsten", [(0.0, -0.09), (0.44, -0.09), (0.44, -0.05), (0.0, -0.05)], segs=48, uv_m=2.0)
    lathe(m, "Steel", [(0.0, -0.05), (0.45, -0.05), (0.49, 0.06), (0.0, 0.06)], segs=48, uv_m=2.0)
    lathe(m, "Tungsten", [(0.0, 0.06), (0.49, 0.06), (0.49, 0.09), (0.0, 0.09)], segs=48, uv_m=2.0)
    hazard_band(m, 0.472, -0.01, 0.02, n=20)
    bolt_ring(m, "Dark", 0.091, 0.45, 16, size=0.010, height=0.007)
    bolt_ring(m, "Dark", -0.091, 0.41, 16, size=0.010, height=0.007, up=False)
    box(m, "Stencil", (0.0, 0.04, 0.475), (0.14, 0.03, 0.002), uv_m=1.0)
    return m, (0.5, 0.09, 0.5)


def ember():
    """The Ember: a Kilopower-class fission core. The core can low in the
    stack inside its beryllia reflector; a tungsten shadow shield over it;
    eight sodium heat pipes up through the shield to a ring of Stirling
    converters; a deck and the top flange. Four struts carry the load
    flange to flange; a hazard band round the shield."""
    m = Model()
    yb, yt = -0.70, 0.70
    G.flange(m, "Metal", yb, yb + 0.04, 0.30, 0.50, segs=48)          # the load flanges
    G.flange(m, "Metal", yt - 0.04, yt, 0.30, 0.50, segs=48)
    bolt_ring(m, "Dark", yb + 0.041, 0.46, 16, size=0.010, height=0.007)
    bolt_ring(m, "Dark", yt - 0.041, 0.46, 16, size=0.010, height=0.007, up=False)
    # the core can and its reflector
    lathe(m, "Steel", [(0.0, -0.66), (0.16, -0.66), (0.22, -0.62), (0.22, -0.24), (0.0, -0.24)], segs=40, uv_m=3.0)
    lathe(m, "Paint3", [(0.26, -0.60), (0.26, -0.27)], segs=40, uv_m=3.0)
    disk(m, "Paint3", 0.26, -0.27, segs=40, r_in=0.22)
    disk(m, "Paint3", 0.26, -0.60, segs=40, r_in=0.22, up=False)
    for k in range(6):                                                # reflector clamps
        a = TAU * k / 6
        c, s = math.cos(a), math.sin(a)
        box(m, "Dark", (0.265 * c, -0.44, 0.265 * s), (0.02, 0.30, 0.04), M=rot_y(-a), uv_m=6.0)
    # the shield over it
    lathe(m, "Tungsten", [(0.0, -0.22), (0.30, -0.22), (0.42, 0.0), (0.0, 0.0)], segs=48, uv_m=2.0)
    hazard_band(m, 0.40, -0.05, -0.015, n=20)
    # heat pipes up through the shield to the converters
    for k in range(8):
        a = TAU * k / 8
        c, s = math.cos(a), math.sin(a)
        tube(m, "Copper", (0.20 * c, -0.24, 0.20 * s), (0.30 * c, 0.02, 0.30 * s), 0.012, segs=8)
        tube(m, "Copper", (0.30 * c, 0.02, 0.30 * s), (0.36 * c, 0.30, 0.36 * s), 0.012, segs=8)
    # the Stirling converters, paired, on a ring
    for k in range(8):
        a = TAU * k / 8 + TAU / 16
        c, s = math.cos(a), math.sin(a)
        tube(m, "Metal", (0.36 * c, 0.30, 0.36 * s), (0.36 * c, 0.52, 0.36 * s), 0.055, segs=16)
        tube(m, "Dark", (0.36 * c, 0.52, 0.36 * s), (0.36 * c, 0.55, 0.36 * s), 0.040, segs=12)
        box(m, "FinBlack", (0.36 * c, 0.41, 0.36 * s), (0.135, 0.13, 0.010), M=rot_y(-a), uv_m=6.0)
    G.flange(m, "Metal", 0.28, 0.30, 0.18, 0.44, segs=48)              # converter ring
    disk(m, "Dark", 0.46, 0.57, segs=48)                               # the deck
    disk(m, "Dark", 0.46, 0.565, segs=48, up=False)
    box(m, "Dark", (0.0, 0.61, 0.0), (0.22, 0.07, 0.16), uv_m=6.0, bevel=0.01)   # controller box
    # the four struts, flange to flange
    for k in range(4):
        a = TAU * k / 4 + TAU / 8
        c, s = math.cos(a), math.sin(a)
        tube(m, "Paint3", (0.46 * c, yb + 0.04, 0.46 * s), (0.46 * c, yt - 0.04, 0.46 * s), 0.022, segs=10)
    # control-drum actuators on the reflector
    for k in range(3):
        a = TAU * k / 3
        c, s = math.cos(a), math.sin(a)
        tube(m, "Dark", (0.30 * c, -0.62, 0.30 * s), (0.30 * c, -0.32, 0.30 * s), 0.025, segs=10)
    box(m, "Stencil", (0.0, -0.10, 0.392), (0.16, 0.035, 0.002), M=None, uv_m=1.0)
    return m, (0.5, 0.7, 0.5)


def rod(spent=False):
    """A fuel rod in its carry frame, along +Y: the zircaloy-clad rod (a
    burnt, discoloured one when spent), its end fittings, two rails, end
    plates, a carry handle and a tag."""
    m = Model()
    half = 0.55
    lathe(m, "Burnt" if spent else "Zircaloy", [(0.0, -half), (0.045, -half), (0.045, half), (0.0, half)],
          segs=20, uv_m=3.0)
    for y in (-half - 0.03, half + 0.03):
        tube(m, "Dark", (0, y - 0.03, 0), (0, y + 0.03, 0), 0.06, segs=14)
    frame = "PaintOrange" if spent else "Yellow"
    for sx in (-1, 1):
        box(m, frame, (sx * 0.075, 0, 0), (0.02, 2 * half + 0.16, 0.03), uv_m=4.0)
    for y in (-half - 0.07, half + 0.07):
        box(m, frame, (0, y, 0), (0.17, 0.02, 0.08), uv_m=4.0)
    for y in (-0.2, 0.2):
        box(m, frame, (0, y, 0), (0.17, 0.015, 0.02), uv_m=4.0)
    tube(m, "Rubber", (-0.05, 0.06, 0.06), (0.05, 0.06, 0.06), 0.012, segs=8)   # the handle
    box(m, frame, (-0.05, 0.06, 0.035), (0.012, 0.012, 0.05), uv_m=4.0)
    box(m, frame, (0.05, 0.06, 0.035), (0.012, 0.012, 0.05), uv_m=4.0)
    box(m, "Stencil", (0.0, -0.30, 0.048), (0.08, 0.05, 0.002), uv_m=1.0)
    return m, (0.09, half + 0.08, 0.07)


# ── writing ─────────────────────────────────────────────────────────────────

def wing_prefab(prefab, about, half, mass, yoke_key, wing_key, yoke, wing, hinge_x):
    ym, yc = G.recenter(yoke)
    wm, wc = G.recenter(wing)
    G.write_glb(ym, os.path.join(G.MODELS, yoke_key + ".glb"))
    G.write_glb(wm, os.path.join(G.MODELS, wing_key + ".glb"))
    pivot = f"""    (
        name: "SolarWingPivot",
        transform: (
            translation: ({hinge_x}, 0.0, 0.0),
            // Deployed (yaw 0). Flight folds it to yaw +90° (flat along the
            // hull) for launch and swings it open on Deploy (vessel_controller).
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
    ),
{G.prefab_node("SolarWing", wing_key, wm, wc, 2)}"""
    G.write_prefab(prefab, about, None, half, mass, children=[("SolarYoke", yoke_key, ym, yc)], tail_nodes=pivot)


ITEM_DIR = os.path.join(G.ROOT, "models", "items")


def item_prefabs(name, key, model, half, about, tags):
    """The held item (no body) and its loose physics body (a box)."""
    model, c = G.recenter(model)
    G.write_glb(model, os.path.join(ITEM_DIR, key + ".glb"))
    tx, ty, tz = (round(float(v), 4) for v in c)
    mats = G.object_materials(model)
    hold = f"""// {about} — held over the shoulder (scripts/item_hand.lua, items.lua `hold`).
// Written by tools/gen_nuclear_parts.py — edit the generator, not this file.
[
    (
        name: "Item{name}",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
    ),
    (
        name: "Mesh",
        transform: (
            translation: ({tx}, {ty}, {tz}),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/{key}.glb",
        ),
        {mats}
        scripts: [],
        parent: Some(0),
    ),
]
"""
    open(os.path.join(G.PREFABS, f"Item{name}.prefab.ron"), "w").write(hold)
    hx, hy, hz = half
    body = f"""// {about} — the loose body: a 40 kg box the gravity gun can lift (items.lua `body`).
// Written by tools/gen_nuclear_parts.py — edit the generator, not this file.
[
    (
        name: "{name}Body",
        tags: {tags},
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        rigidbody: Some((
            boxed: true,
            mode: Dynamic,
            radius: {max(hx, hz)},
            height: {2 * hy},
            half_extents: ({hx}, {hy}, {hz}),
            restitution: 0.05,
            friction: 0.7,
            gravity: true,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.04,
        )),
    ),
    (
        name: "Mesh",
        transform: (
            translation: ({tx}, {ty}, {tz}),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/{key}.glb",
        ),
        {mats}
        scripts: [],
        parent: Some(0),
    ),
]
"""
    open(os.path.join(G.PREFABS, f"{name}Body.prefab.ron"), "w").write(body)


def vis(prefab):
    src = open(os.path.join(G.PREFABS, prefab + ".prefab.ron")).read()
    v = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
    head_ = ("// VISUAL-ONLY variant of prefabs/" + prefab + ".prefab.ron for the builder stand: no body,"
             " no scripts.\n// Written by tools/gen_nuclear_parts.py — regenerate, don't edit.\n")
    open(os.path.join(G.VIS_DIR, prefab + ".prefab.ron"), "w").write(head_ + v)


def check(name, m, half):
    mn, mx = m.bounds()
    over = np.maximum(-mn - np.asarray(half), mx - np.asarray(half))
    print(f"{name:14s} bounds {np.round(mn, 3)} .. {np.round(mx, 3)} box {half} tris {m.tris()}"
          + (f"  NOTE past its box by {np.round(over, 3)}" if (over > 0.006).any() else ""))


def main():
    dry = "--dry" in sys.argv
    os.makedirs(G.MODELS, exist_ok=True)
    os.makedirs(G.VIS_DIR, exist_ok=True)
    os.makedirs(ITEM_DIR, exist_ok=True)
    done = []
    for prefab, key, fn, mass, about in (
            ("PartRTG", "nuke_rtg", isotope_cell, 0.045,
             "ISOTOPE CELL — a finned radioisotope generator on a short boom, +X out of the hull (parts_nuclear rtg)."),
            ("PartRadFin", "nuke_rad_fin", radiator_fin, 0.05,
             "RADIATOR FIN — a fixed corrugated radiator, +X out of the hull, faces ±Z (parts_nuclear radFin)."),
            ("PartShadowShield", "nuke_shield", shadow_shield, 0.8,
             "SHADOW SHIELD — a 1 m tungsten and lithium-hydride disc for a stack (parts_nuclear shadowShield)."),
            ("PartEmber", "nuke_ember", ember, 1.8,
             "EMBER REACTOR — a 1 m fission core: core low, converters on top; its radiation cone opens up +Y (parts_nuclear ember).")):
        m, half = fn()
        check(prefab, m, half)
        if dry:
            continue
        model, c = G.recenter(m)
        G.write_glb(model, os.path.join(G.MODELS, key + ".glb"))
        G.write_prefab(prefab, about, None, half, mass, children=[("Body", key, model, c)])
        done.append(prefab)
    for prefab, ykey, wkey, mass, half, hinge, back, length, yh, n, size, about in (
            ("PartRadPanel", "nuke_radp_yoke", "nuke_radp_wing", 0.3, (0.62, 0.46, 0.06), -0.50, -0.57, 1.08, 0.44, 2, 1.0,
             "RADIATOR PANEL — a folding ammonia-loop radiator: a yoke on the hull and a wing hinged to it"
             " (SolarWingPivot), folded flat for launch, out on Deploy (U)."),
            ("PartRadTruss", "nuke_radt_yoke", "nuke_radt_wing", 1.0, (1.40, 0.80, 0.10), -1.28, -1.35, 2.66, 0.78, 6, 1.4,
             "TRUSS RADIATOR — six radiator panels on a folding arm (SolarWingPivot), folded for launch,"
             " out on Deploy (U).")):
        yoke = wing_yoke(hinge, back, size)
        wing = radiator_wing(length, yh, n)
        whole = Model()
        whole.merge(yoke)
        whole.merge(wing, None, (hinge, 0, 0))
        check(prefab, whole, half)
        if dry:
            continue
        wing_prefab(prefab, about, half, mass, ykey, wkey, yoke, wing, hinge)
        done.append(prefab)
    for p in done:
        vis(p)
    for name, key, spent in (("FuelRod", "fuel_rod", False), ("SpentRod", "spent_rod", True)):
        m, half = rod(spent)
        check(name, m, half)
        if dry:
            continue
        item_prefabs(name, key, m, half,
                     "SPENT FUEL ROD — hot, in its orange carry frame" if spent else "FUEL ROD — in its carry frame",
                     '["item", "' + ("spentRod" if spent else "fuelRod") + '"]')
    if done:
        print("prefabs:", ", ".join(done), "+ ItemFuelRod, ItemSpentRod, FuelRodBody, SpentRodBody")


if __name__ == "__main__":
    main()
