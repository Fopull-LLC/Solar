#!/usr/bin/env python3
"""Generate the on-foot TOOLS and the loose rock they throw around.

    python3 tools/gen_tools.py          (needs Blender: $BLENDER, default the Steam install)
    python3 tools/gen_tools.py --laser-variant B      the game's laser is design B (default C)
    python3 tools/gen_tools.py --protos DIR           also write every laser design
                                         (TL7, A, B, C) into DIR/models/tools and
                                         DIR/prefabs as ToolLaser<V>[FP], for
                                         tools/perf/toolstand.sh's PROTOS=1 sheet

The two tools are industrial machine tools in the spirit of Valve's gravity
gun, pulled into Solar's NASA/ESA-era look (graphite and enamel, worn paint
at the edges, stencilled labels, signal orange only on the moving parts):

    GM-3 gravitic field manipulator (the Gravity Gun): a power cell slung low
        behind the grip, a graphite receiver with an enamel nameplate on the
        left and an open vent and charge gauge on the right, two capacitors on
        top, the field-coil body (copper windings round a glowing core in a
        cage, a padded guard, a fore-grip under it), the emitter bell with its
        glowing dish, and three hinged claws round it.
    TL-3 plasma bore (the terrain laser, design C): stubby, a hoop handle
        over a compact graphite receiver, the energy cell slung low behind
        the grip, a fat plasma drum seen between ribs and copper magnet
        rings, and an emitter crown of six electrodes that spins with the
        beam. The other designs (TL7, the old TL-7; A, the TL-9 Excavator;
        B, the TL-5 Surveyor) are still built by --laser-variant:
        gen_tools_blender.py's LASERS.
    TL-5 SURVEYOR plasma rifle (the crew's weapon, design B): a slim
        enamel receiver under a survey scope, a skeletal stock round its
        cell, a long barrel in a ventilated shroud with a glowing coolant
        loop, a slotted muzzle brake. models/tools/surveyor.glb and
        fp_surveyor.glb, prefabs ToolSurveyor / ToolSurveyorFP, in the
        "plasma" palette (ice blue to blue-white).

THE ENERGY PARTS wear the tool_* surface shaders (shaders/tool_*.flsl): the
gravity gun's field core, dish, cell and capacitor bands glow blue, a laser's
cell, emitter and crystal or plasma amber; glass sleeves catch the light; the
gauges are lamp rows; a laser's heat sink glows from the root out. Their
`charge` and `heat` are driven by scripts/tool_belt.lua (THE MECHANISMS).

tools/gen_tools_blender.py builds their geometry in Blender (bevels, extruded
silhouettes, swept hoses) and hands it back; this script adds the first-person
gloves, draws the decal atlas, and writes:

    models/tools/gravity_gun.glb     the tools, third person; each keeps its
    models/tools/terrain_laser.glb   moving parts as NODES (ClawTop/Left/Right,
    models/tools/fp_gravity_gun.glb  Focus), which the engine poses as bones —
    models/tools/fp_terrain_laser.glb  scripts/tool_belt.lua's THE MECHANISMS.
                                     The fp_ models carry the crew's gloved hands
                                     on both grips and the suit's sleeves.
    textures/tools/tool_decals.png   512² RGBA atlas: stencils, placards, the
                                     agency emblem, a hazard stripe
    models/tools/socket.glb          a few millimetres of nothing the hand
                                     node wears, so only the tool shows
    models/tools/loose_rock.glb      a chunk knocked loose by the laser
    prefabs/ToolGravGun, ToolLaser   the held tools (object_materials, no body)
    prefabs/ToolGravGunFP, ToolLaserFP   their first-person view models
    prefabs/LooseRock                a one-part assembly the gravity gun lifts

Every tool is modelled barrel down -Z with the grip under the receiver, at
TRUE SIZE in metres and held at scale 1 in both views (the gravity gun is
0.69 m long, the laser 0.60 m). The engine recentres a model on its rest
bounding box, so each model is shifted to be centred and the GRIP, MUZZLE and
FORE (the other hand's hold) are printed relative to that centre — the numbers
`scripts/tool_belt.lua` keeps in `RIG` (third person) and `RIG_FP` (first
person: a different model, so a different centre).
"""
import ast
import json
import math
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import PREFABS, ROOT, Model, box, lathe, mat_ron, tube, write_glb  # noqa: E402
import base_tex  # noqa: E402

MODELS = os.path.join(ROOT, "models", "tools")

# The EVA suit's colours and materials for the first-person gloves and
# sleeves, held HERE rather than imported from tools/gen_suit.py, so the
# view models keep their look while the suit's generator changes: warm
# off-white beta cloth, light-grey gloves with dark grip palms, an anodised
# wrist bearing. Their cloth is the suit's own texture set (textures/suit/).
CLOTH = (0.80, 0.785, 0.745)     # the suit's TMG (gen_suit_blender.py CLOTH)
GLOVE = (0.62, 0.615, 0.60)      # its gloves, with the grime they carry
PALM = (0.16, 0.16, 0.17)        # RTV grip


def suit_cloth(col):
    """The suit's cloth texture set in one of its colours."""
    t = "textures/suit/fabric"
    return (f'(\n                color: {tuple(col)},\n                texture: Some("{t}_albedo.png"),\n'
            f'                normal_map: Some("{t}_normal.png"),\n                normal_strength: 1.0,\n'
            f'                roughness_map: Some("{t}_orm.png"),\n                roughness: 1.0,\n'
            f'                metallic_map: Some("{t}_orm.png"),\n                metallic: 1.0,\n'
            f'                ao_map: Some("{t}_orm.png"),\n                shading: Physical,\n            )')


def suit_metal():
    return ('(\n                color: (1.0, 1.0, 1.0),\n'
            '                texture: Some("textures/parts/metal_albedo.png"),\n'
            '                normal_map: Some("textures/parts/metal_normal.png"),\n'
            '                roughness_map: Some("textures/parts/metal_orm.png"),\n'
            '                roughness: 0.7,\n'
            '                metallic_map: Some("textures/parts/metal_orm.png"),\n'
            '                metallic: 0.6,\n'
            '                shading: Physical,\n            )')


def glow(r, g, b, s=2.6):
    return (f'(\n                color: ({r}, {g}, {b}),\n                emissive: ({r}, {g}, {b}),\n'
            f'                emissive_strength: {s},\n                roughness: 0.3,\n'
            f'                metallic: 0.0,\n                shading: Physical,\n            )')


TOOL_MATS = {
    "GunBody":   lambda: mat_ron("metal", color=(0.26, 0.27, 0.29), rough=1.1, metal=0.45, hull=False),
    "GunPaint":  lambda: mat_ron("paint", color=(0.97, 0.55, 0.22), hull=False),     # signal orange, sparingly
    "Enamel":    lambda: mat_ron("paint", color=(0.86, 0.84, 0.78), hull=False),
    "Anodised":  lambda: mat_ron("metal", color=(0.42, 0.47, 0.55), rough=0.85, metal=0.5, hull=False),
    "Chrome":    lambda: mat_ron("metal", color=(1.0, 1.0, 1.0), rough=0.4, metal=0.85, hull=False),
    "Dark":      lambda: mat_ron("metal", color=(0.16, 0.16, 0.17), rough=1.3, metal=0.3, hull=False),
    "Rubber":    lambda: mat_ron("rubber", metal=0.0, hull=False),
    # The EVA suit (tools/gen_suit.py), for the first-person sleeves and
    # gloves: its cloth in its own colours, and its bearing metal.
    "Glove":     lambda: suit_cloth(GLOVE),
    "Palm":      lambda: suit_cloth(PALM),
    "Suit":      lambda: suit_cloth(CLOTH),
    "SuitMetal": suit_metal,
    "Hazard":    lambda: mat_ron("paint", color=(0.95, 0.72, 0.12), hull=False),
    "Lens":      lambda: ('(\n                color: (0.20, 0.30, 0.34),\n                roughness: 0.05,\n'
                          '                metallic: 0.2,\n                alpha: 0.85,\n'
                          '                shading: Physical,\n            )'),
    "GlowAmber": lambda: glow(1.0, 0.62, 0.25, 2.6),
    # the gravity gun's field core: a warm white-amber, never the old teal
    "GlowCore":  lambda: glow(1.0, 0.74, 0.42, 3.0),
    "Copper":    lambda: mat_ron("metal", color=(0.80, 0.50, 0.32), rough=0.75, metal=0.9, hull=False),
    # bare metal where the paint has worn off an edge (Blender's bevel faces)
    "EnamelWorn": lambda: mat_ron("metal", color=(0.72, 0.71, 0.68), rough=0.8, metal=0.7, hull=False),
    "PaintWorn": lambda: mat_ron("metal", color=(0.66, 0.64, 0.60), rough=0.8, metal=0.7, hull=False),
    # the laser's heat sink (fins and core): dark metal whose glow
    # scripts/tool_belt.lua raises with the laser's heat (node:material("HeatGlow"))
    "HeatGlow":  lambda: mat_ron("metal", color=(0.32, 0.32, 0.33), rough=0.95, metal=0.6, hull=False,
                                 extra='                emissive: (1.0, 0.36, 0.1),\n'
                                       '                emissive_strength: 0.0,\n'),
    # stencils, placards, the emblem: textures/tools/tool_decals.png, cut out
    "ToolDecal": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n'
                          '                texture: Some("textures/tools/tool_decals.png"),\n'
                          '                roughness: 0.6,\n                metallic: 0.0,\n'
                          '                shading: Physical,\n            )'),
    "Rock":      lambda: ('(\n                color: (0.78, 0.74, 0.68),\n'
                          '                texture: Some("textures/terrain/geo_granite.png"),\n'
                          '                roughness: 0.92,\n                metallic: 0.0,\n'
                          '                shading: Physical,\n            )'),
}


# ── the energy parts: tool_* surface shaders, in each tool's palette ───────
#
# `charge` and `heat` start where an idle tool sits; tool_belt drives them.

PALETTES = {
    # the gravity gun's field: a cold electric blue that whitens as it charges
    "field": {"glow": (0.30, 0.60, 1.00), "core": (0.90, 0.95, 1.00), "gauge": (1.00, 0.62, 0.24), "heat": 0.0},
    # a laser's beam energy: amber to white-hot; its gauges read heat
    "laser": {"glow": (1.00, 0.50, 0.16), "core": (1.00, 0.92, 0.78), "gauge": (1.00, 0.62, 0.24), "heat": 1.0},
    # the TL-5 Surveyor's plasma: ice blue to blue-white as it charges; its
    # gauge reads the cell's charge, not heat (the coolant loop shows the heat)
    "plasma": {"glow": (0.42, 0.74, 1.00), "core": (0.90, 0.97, 1.00), "gauge": (0.55, 0.85, 1.00), "heat": 0.0},
}
COOLANT = {"glow": (0.40, 0.78, 1.00), "core": (0.88, 0.97, 1.00), "heatTo": (1.00, 0.45, 0.12)}


def _param(v):
    if isinstance(v, (tuple, list)):
        return f"({v[0]}, {v[1]}, {v[2]}, 1.0)"
    return f"({float(v)}, 0.0, 0.0, 0.0)"


def shader_mat(shader, params, color=(1.0, 1.0, 1.0), rough=0.5, metal=0.0):
    ps = "".join(f'                    "{k}": {_param(v)},\n' for k, v in params.items())
    return (f'(\n                color: ({color[0]}, {color[1]}, {color[2]}),\n'
            f'                roughness: {rough},\n                metallic: {metal},\n'
            f'                shader: Some("shaders/{shader}.flsl"),\n'
            f'                shader_params: {{\n{ps}                }},\n'
            f'                shading: Physical,\n            )')


def energy(p, bands, flow, power, glow=None, core=None, **extra):
    g, c = glow or p["glow"], core or p["core"]
    return shader_mat("tool_energy", dict(glow=g, core=c, charge=0.3, bands=bands, flow=flow, power=power, **extra),
                      color=g)


ENERGY_MATS = {
    "Energy":      lambda p: energy(p, 40, 0.5, 3.0),
    "EnergyDish":  lambda p: energy(p, 120, -0.12, 3.2),
    "EnergyBand":  lambda p: energy(p, 0, 0.0, 2.4),
    "Emitter":     lambda p: energy(p, 150, -0.10, 3.5),
    "Crystal":     lambda p: energy(p, 25, 0.3, 2.6),
    "Plasma":      lambda p: energy(p, 30, 0.8, 3.0),
    "Coolant":     lambda p: energy(p, 30, 0.25, 2.2, glow=COOLANT["glow"], core=COOLANT["core"],
                                    heatTo=COOLANT["heatTo"], heatMix=1.0),
    "EnergyGlass": lambda p: shader_mat("tool_glass", dict(glow=p["glow"], charge=0.3), color=p["glow"]),
    "CoolGlass":   lambda p: shader_mat("tool_glass", dict(glow=COOLANT["glow"], charge=0.3), color=COOLANT["glow"]),
    "Gauge":       lambda p: shader_mat("tool_gauge", dict(glow=p["gauge"], charge=0.3, useHeat=p["heat"], segs=10),
                                        color=p["gauge"]),
    # a laser's heat sink: dark machined metal that glows from the root out
    "HeatGlow":    lambda p: shader_mat("tool_heat", dict(tint=(0.32, 0.32, 0.33), heat=0.0, reach=0.026),
                                        color=(0.32, 0.32, 0.33), rough=0.75, metal=0.6),
}


def centred(m):
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    return out, c


# ── the tools themselves: built in Blender ─────────────────────────────────
#
# tools/gen_tools_blender.py builds both tools (bevels, extruded silhouettes,
# swept hoses) and hands back triangles per (node, material), the anchors and
# the articulated nodes. Here they become a Rig: one Model per node, in the
# tool's frame at rest.

BLENDER = os.environ.get("BLENDER", "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender")
BL_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_tools_blender.py")
_BL = {}
LASER_VARIANTS = ("TL7", "A", "B", "C")
WANT_LASERS = ["C"]          # what blender_tools() asks Blender for (main sets it)


def blender_tools():
    if not _BL:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "tools_mesh.json")
            r = subprocess.run([BLENDER, "--background", "--factory-startup", "--python", BL_SCRIPT, "--", out,
                                ",".join(WANT_LASERS)], capture_output=True, text=True)
            if r.returncode != 0 or not os.path.exists(out):
                sys.exit("gen_tools_blender.py failed:\n" + r.stdout[-3000:] + r.stderr[-3000:])
            with open(out) as f:
                _BL.update(json.load(f))
    return _BL


class Rig:
    """A tool as nodes: `models[name]` is that node's geometry in the TOOL's
    frame (at rest); `nodes` the tree, each with its rest translation `t`
    (in its parent's frame) and a roll about Z."""

    def __init__(self, data):
        self.nodes = [dict(n) for n in data["nodes"]]
        self.models = {}
        for node, mats in data["geo"].items():
            m = Model()
            for mat, e in mats.items():
                P = np.asarray(e["P"], float).reshape(-1, 3)
                N = np.asarray(e["N"], float).reshape(-1, 3)
                UV = np.asarray(e["UV"], float).reshape(-1, 2)
                # weld the triangle soup: identical (position, normal, uv)
                key = np.round(np.hstack([P * 1e5, N * 1e4, UV * 1e4])).astype(np.int64)
                _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
                m.add(mat, P[first], N[first], UV[first], inv.reshape(-1, 3))
            self.models[node] = m
        for n in self.nodes:
            self.models.setdefault(n["name"], None)
        self.anchors = {k: np.asarray(v, float) for k, v in data["anchors"].items()}

    @property
    def body(self):
        return self.models["Body"]

    def bounds(self):
        bs = [m.bounds() for m in self.models.values() if m is not None]
        return np.min([b[0] for b in bs], 0), np.max([b[1] for b in bs], 0)

    def tris(self):
        return sum(m.tris() for m in self.models.values() if m is not None)

    def world(self, name):
        """The node's rest matrix in the tool's frame (4x4)."""
        n = next(x for x in self.nodes if x["name"] == name)
        c, s = math.cos(n["roll"]), math.sin(n["roll"])
        M = np.array([[c, -s, 0, n["t"][0]], [s, c, 0, n["t"][1]], [0, 0, 1, n["t"][2]], [0, 0, 0, 1.0]])
        return M if n["parent"] is None else self.world(n["parent"]) @ M

    def shift(self, d):
        """Move the whole tool by d (the root's translation and every node's
        geometry, which is held in the tool's frame)."""
        d = np.asarray(d, float)
        for k, m in self.models.items():
            if m is not None:
                out = Model()
                out.merge(m, None, d)
                self.models[k] = out
        root = next(x for x in self.nodes if x["parent"] is None)
        root["t"] = list(np.asarray(root["t"], float) + d)
        for k in self.anchors:
            self.anchors[k] = self.anchors[k] + d


def gravity_gun():
    return Rig(blender_tools()["gravgun"])


def terrain_laser(variant="C"):
    return Rig(blender_tools()["laser_" + variant])


def surveyor():
    """The TL-5 SURVEYOR plasma rifle: design B with its own nameplate line
    and a muzzle brake (gen_tools_blender.laser_B(rifle=True))."""
    return Rig(blender_tools()["surveyor"])


# ── first person: the same tools in gloved hands ───────────────────────────
#
# The view-model camera films these and nothing else, so the hands, cuffs and
# sleeves are part of the model: no arm rig to pose, nothing to clip into a
# wall. They wear the EVA suit (tools/gen_suit.py): light-grey gloves with dark
# palms, a metal wrist bearing, the suit's cloth sleeve. The view looks down on
# the tool from up and to its left, so each hand is placed where that view can
# see it: the right hand's knuckles and thumb round the pistol grip, the left
# hand cupping the LEFT side of the fore-end with its fingers over the top.
# The sleeves run back and down past the bottom of the view.
#
# The engine recentres a model on its box, and tool_belt's RIG_FP holds the
# grip and muzzle relative to that centre — so each view model's box centre
# is pinned to FP_CENTRE (two zero-area triangles), and RIG_FP never changes
# when the hands do.

FP_CENTRE = {
    "gravgun_fp": (-0.09172205158580735, -0.14120499599902658, 0.09168546816154502),
    "laser_fp": (-0.09129929678446527, -0.14607702949859874, 0.030868770701170667),
}


def pin_centre(rig, want):
    """Grow the rig's box (two zero-area triangles on the Body) until its
    centre is `want`."""
    m = rig.body
    mn, mx = rig.bounds()
    lo, hi = mn.copy(), mx.copy()
    for a in range(3):
        if (lo[a] + hi[a]) / 2 < want[a]:
            hi[a] = 2 * want[a] - lo[a]
        else:
            lo[a] = 2 * want[a] - hi[a]
    # zero-area: never drawn, but the box is read from the vertices
    m.add("Dark", [lo, lo, lo, hi, hi, hi], [(0, 1, 0)] * 6, [(0, 0)] * 6, [(0, 1, 2), (3, 4, 5)])
    return m


def capsule(m, p0, p1, thick, wide, palm_n, segs=12, back="Glove", front="Palm"):
    """A flattened capsule from p0 to p1: `thick` the half-depth along palm_n
    (the side facing palm_n is the dark palm), `wide` the half-width across."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    L = float(np.linalg.norm(d))
    ax = d / L
    nx = np.asarray(palm_n, float)
    nx = nx - ax * (nx @ ax)
    nx /= np.linalg.norm(nx)
    nz = np.cross(nx, ax)
    # radius 1 (scaled to thick / wide), the ends domed
    dome = min(thick, wide)
    pr = [(0.0, -dome), (0.5, -dome * 0.87), (0.87, -dome * 0.5), (1.0, 0.0),
          (1.0, L), (0.87, L + dome * 0.5), (0.5, L + dome * 0.87), (0.0, L + dome)]
    for mat, a0, a1 in ((front, -math.pi / 2, math.pi / 2), (back, math.pi / 2, 3 * math.pi / 2)):
        sub = Model()
        lathe(sub, mat, pr, segs=segs // 2, smooth=True, a0=a0, a1=a1, uv_m=4.0)
        # lathe's (r, y): r scales by thick / wide in x / z; y is the true length
        out = Model()
        for k, (Ps, Ns, UVs, Is, _) in sub.parts.items():
            P = np.vstack(Ps); N = np.vstack(Ns)
            P2 = P[:, [0]] * (nx * thick) + P[:, [1]] * ax + P[:, [2]] * (nz * wide)
            N2 = N[:, [0]] * (nx / thick) + N[:, [1]] * ax + N[:, [2]] * (nz / wide)
            out.add(k, P2, N2, np.vstack(UVs), np.vstack(Is))
        m.merge(out, None, p0)


def fp_glove(m, wrist, elbow, palm, fingers, palm_n, thumb, wide=0.05, thick=0.03):
    """A gloved hand: the palm (wrist end to knuckles) and the fingers (bent
    on from the knuckles) as flattened capsules with dark palms toward
    `palm_n`, the thumb, a flared gauntlet, the wrist bearing and the suit
    sleeve back to `elbow`."""
    capsule(m, palm[0], palm[1], thick, wide, palm_n)
    # four fingers, as the suit's glove has them (tools/gen_suit_blender.py):
    # side by side across the hand's width, the middle finger longest, the
    # little finger short and set back, each its own padded capsule
    f0, f1 = np.asarray(fingers[0], float), np.asarray(fingers[1], float)
    fn = np.asarray(fingers[2] if len(fingers) > 2 else palm_n, float)
    ax = (f1 - f0) / float(np.linalg.norm(f1 - f0))
    nx = fn - ax * (fn @ ax)
    nx /= np.linalg.norm(nx)
    nz = np.cross(nx, ax)
    L = float(np.linalg.norm(f1 - f0))
    fw = wide * 0.94 / 4
    for i, (ln, back) in enumerate(((0.92, 0.03), (1.0, 0.0), (0.94, 0.03), (0.76, 0.10))):
        o = nz * fw * (1.5 - i) * 2
        capsule(m, f0 + o - ax * back * L, f0 + o + ax * (ln - back) * L, thick * 0.66, fw * 0.92, fn, segs=8)
    capsule(m, thumb[0], thumb[1], 0.016, 0.018, thumb[2] if len(thumb) > 2 else palm_n, segs=8)
    wrist, elbow = np.asarray(wrist, float), np.asarray(elbow, float)
    d = elbow - wrist
    u = d / float(np.linalg.norm(d))
    # the gauntlet: from the heel of the hand, flaring to the bearing
    tube(m, "Glove", np.asarray(palm[0], float), wrist + u * 0.035, 0.034, segs=14, r1=0.045)
    # the wrist disconnect: a bright bearing and its darker lock collar
    tube(m, "SuitMetal", wrist + u * 0.035, wrist + u * 0.056, 0.049, segs=18)
    tube(m, "Dark", wrist + u * 0.056, wrist + u * 0.064, 0.045, segs=18)
    tube(m, "Suit", wrist + u * 0.064, elbow, 0.045, segs=16, r1=0.062)


def fore_grip_hand(m, Y, z):
    """The left glove round a vertical fore-grip whose top is under the
    barrel at depth z (the grip raked a little forward)."""
    w = np.array([-0.052, Y - 0.150, z + 0.050])
    fp_glove(m, w, w + np.array([-0.20, -0.30, 0.36]),
             palm=((-0.046, Y - 0.122, z + 0.028), (-0.040, Y - 0.108, z - 0.018)),
             fingers=((-0.026, Y - 0.106, z - 0.036), (0.022, Y - 0.104, z - 0.030), (0.0, 0.0, 1.0)),
             palm_n=(1.0, 0.0, 0.0),
             thumb=((-0.040, Y - 0.072, z + 0.022), (0.004, Y - 0.066, z + 0.016), (0.0, -1.0, 0.0)),
             wide=0.040, thick=0.024)


def fp_gravity_gun():
    rig = gravity_gun()
    m = rig.body
    # Right hand round the raked pistol grip: the palm down its back, the
    # fingers across its front, the thumb up the receiver's left flank.
    w = np.array([0.012, -0.10, 0.125])
    fp_glove(m, w, w + np.array([0.13, -0.30, 0.42]),
             palm=((0.012, -0.095, 0.10), (0.008, -0.02, 0.07)),
             fingers=((-0.004, -0.03, 0.03), (0.0, -0.09, 0.012), (0.0, 0.0, 1.0)),
             palm_n=(-0.2, 0.0, -1.0),
             thumb=((-0.045, -0.035, 0.09), (-0.074, 0.008, 0.03), (1.0, 0.0, 0.0)), wide=0.042, thick=0.026)
    # Left hand round the fore-grip under the coil body: the palm on its
    # left, the fingers curled round its front, the thumb over the top behind;
    # the forearm runs back and down out of the view, under the gun, so the
    # coil, the bell and the claws stay in sight.
    fore_grip_hand(m, Y=0.05, z=-0.155)
    return rig


def fp_terrain_laser(variant="C"):
    return fp_laser_hands(terrain_laser(variant))


def fp_surveyor():
    return fp_laser_hands(surveyor())


def fp_laser_hands(rig):
    """The gloves on a laser-family tool (the TL-7's grip, a fore-grip at the
    design's `fore` anchor)."""
    m = rig.body
    # Right hand on the pistol grip.
    w = np.array([0.012, -0.095, 0.155])
    fp_glove(m, w, w + np.array([0.13, -0.30, 0.40]),
             palm=((0.012, -0.09, 0.13), (0.008, -0.015, 0.10)),
             fingers=((-0.004, -0.025, 0.06), (0.0, -0.085, 0.042), (0.0, 0.0, 1.0)),
             palm_n=(-0.2, 0.0, -1.0),
             thumb=((-0.04, -0.03, 0.12), (-0.066, 0.008, 0.06), (1.0, 0.0, 0.0)), wide=0.042, thick=0.026)
    # Left hand round the fore-grip under the barrel, as the gravity gun's
    # (every design keeps its fore-grip about here: its `fore` anchor).
    fore_grip_hand(m, Y=0.05, z=float(rig.anchors["fore"][2]) + 0.004)
    return rig


# ── the glb: one mesh per node, the node tree kept ─────────────────────────
#
# A glb with two or more mesh nodes keeps its node tree in the engine
# (gltf_rig.rs), and every node is a bone a script can pose:
# node:animator():setBoneRot("ClawTop", 0, pitch, 0). Each node's geometry
# goes in its own frame, so a rotation turns it about its pivot.

def write_rig_glb(rig, path):
    bin_ = bytearray()
    views, accs, meshes, mats, mat_ix = [], [], [], [], {}

    def view(data, target):
        nonlocal bin_
        while len(bin_) % 4:
            bin_ += b"\0"
        off = len(bin_)
        bin_ += data
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    def acc(data, ctype, count, typ, target, mm=None):
        a = {"bufferView": view(data, target), "componentType": ctype, "count": count, "type": typ}
        if mm is not None:
            a["min"], a["max"] = mm
        accs.append(a)
        return len(accs) - 1

    node_ix = {n["name"]: i for i, n in enumerate(rig.nodes)}
    gnodes = []
    for n in rig.nodes:
        h = n["roll"] / 2
        g = {"name": n["name"], "translation": [float(v) for v in n["t"]],
             "rotation": [0.0, 0.0, math.sin(h), math.cos(h)]}
        kids = [node_ix[c["name"]] for c in rig.nodes if c["parent"] == n["name"]]
        if kids:
            g["children"] = kids
        m = rig.models.get(n["name"])
        if m is not None:
            Wi = np.linalg.inv(rig.world(n["name"]))
            prims = []
            for mat, (P, N, UV, I) in sorted(m.arrays().items()):
                P = (P @ Wi[:3, :3].T + Wi[:3, 3]).astype(np.float32)
                N = N @ Wi[:3, :3].T
                N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
                if mat not in mat_ix:
                    mat_ix[mat] = len(mats)
                    mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1.0],
                                                                       "metallicFactor": 0.0, "roughnessFactor": 0.6}})
                prims.append({"attributes": {
                    "POSITION": acc(P.tobytes(), 5126, len(P), "VEC3", 34962, (P.min(0).tolist(), P.max(0).tolist())),
                    "NORMAL": acc(N.tobytes(), 5126, len(N), "VEC3", 34962),
                    "TEXCOORD_0": acc(UV.astype(np.float32).tobytes(), 5126, len(UV), "VEC2", 34962)},
                    "indices": acc(I.astype(np.uint32).reshape(-1).tobytes(), 5125, I.size, "SCALAR", 34963),
                    "material": mat_ix[mat]})
            g["mesh"] = len(meshes)
            meshes.append({"name": n["name"], "primitives": prims})
        gnodes.append(g)
    roots = [node_ix[n["name"]] for n in rig.nodes if n["parent"] is None]
    gl = {"asset": {"version": "2.0", "generator": "Solar tools/gen_tools.py"},
          "scene": 0, "scenes": [{"nodes": roots}], "nodes": gnodes, "meshes": meshes,
          "materials": mats, "accessors": accs, "bufferViews": views, "buffers": [{"byteLength": len(bin_)}]}
    js = json.dumps(gl, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    while len(bin_) % 4:
        bin_ += b"\0"
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_)))
        f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack("<II", len(bin_), 0x004E4942)); f.write(bytes(bin_))


# ── the decal atlas: textures/tools/tool_decals.png ────────────────────────
#
# Stencils, placards, the agency emblem and a tileable hazard stripe, in the
# game's own faces (docs/ui-style.md): Saira Stencil for the tool names and
# "HOT", Barlow Semi Condensed SemiBold for placards and serials. Drawn at
# twice the size and halved, so the edges are soft, with a little grain and
# a few scuffs; RGBA, cut out by the material. The cells come from
# gen_tools_blender.py's DECALS table, which places the quads.

ATLAS_PATH = os.path.join(ROOT, "textures", "tools", "tool_decals.png")


def decal_cells():
    src = open(BL_SCRIPT).read()
    a = src.index("DECALS = {")
    b = src.index("}", a)
    return ast.literal_eval(src[a + len("DECALS = "):b + 1])


def tool_atlas():
    K = 2
    S = 512 * K
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cells = {k: tuple(v * K for v in c) for k, c in decal_cells().items()}
    INK = (34, 32, 29, 255)            # print on enamel: warm black
    LIGHT = (235, 227, 207, 255)       # print on dark metal: `ink`
    WARN = (255, 204, 71, 255)         # caution yellow
    ACC = (247, 140, 56, 255)          # signal orange
    RED = (214, 72, 52, 255)
    stencil = lambda s: ImageFont.truetype(base_tex.FONT_STENCIL, s)
    label = lambda s: ImageFont.truetype(base_tex.FONT_LABEL, s)

    def fit(text, font, box, size, track=0):
        x, y, w, h = box
        while size > 6:
            f = font(size)
            tw = sum(d.textlength(ch, font=f) for ch in text) + track * size * (len(text) - 1)
            bb = d.textbbox((0, 0), text, font=f)
            if tw <= w and bb[3] - bb[1] <= h:
                return f, tw, bb
            size -= 2
        return font(size), w, d.textbbox((0, 0), text, font=font(size))

    def text(cell, s, font, size, fill, pad=6, track=0.0, align="c", yoff=0):
        x, y, w, h = cells[cell]
        f, tw, bb = fit(s, font, (x, y, w - 2 * pad * K, h - 2 * pad * K), size * K, track)
        tx = x + (w - tw) / 2 if align == "c" else x + pad * K
        ty = y + (h - (bb[3] - bb[1])) / 2 - bb[1] + yoff * K
        for ch in s:
            d.text((tx, ty), ch, font=f, fill=fill)
            tx += d.textlength(ch, font=f) + track * f.size

    text("gm3", "GM-3", stencil, 64, INK, track=0.08)
    text("tl7", "TL-7", stencil, 64, INK, track=0.08)
    text("tl9", "TL-9", stencil, 64, INK, track=0.08)        # the design prototypes
    text("tl5", "TL-5", stencil, 64, INK, track=0.08)
    text("tl3", "TL-3", stencil, 64, INK, track=0.08)
    text("tl5_name", "PLASMA SURVEY RIFLE", label, 14, INK, pad=2, track=0.06)
    text("gm3_name", "GRAVITIC FIELD MANIPULATOR", label, 30, INK, track=0.08)
    text("tl7_name", "TERRAIN LASER  /  CUT · FILL", label, 30, INK, track=0.08)
    text("serial_a", "S/N GM3-0417   MAINT. 26-09", label, 22, INK, track=0.05)
    text("serial_b", "S/N TL7-1183   MAINT. 26-08", label, 22, LIGHT, track=0.05)
    text("charge", "FIELD CHARGE", label, 24, LIGHT, track=0.12)
    text("dig", "DIG  ·  FILL", label, 24, LIGHT, track=0.12)
    text("fill", "FILL", stencil, 40, INK, track=0.1)
    # placards: caution yellow, a ruled black border, a symbol and text
    for cell, lines, sym in (("field_warn", ("CAUTION", "GRAVITIC FIELD", "KEEP HANDS CLEAR"), "field"),
                             ("laser_warn", ("DANGER", "LASER RADIATION", "CLASS 4 · NO EYE EXPOSURE"), "laser")):
        x, y, w, h = cells[cell]
        d.rectangle((x + 2 * K, y + 2 * K, x + w - 2 * K, y + h - 2 * K), fill=WARN, outline=INK, width=4 * K)
        d.rectangle((x + 8 * K, y + 8 * K, x + w - 8 * K, y + 36 * K), fill=INK)
        f, tw, bb = fit(lines[0], stencil, (0, 0, w - 24 * K, 24 * K), 26 * K)
        d.text((x + (w - tw) / 2, y + 22 * K - (bb[1] + bb[3]) / 2), lines[0], font=f, fill=WARN)
        # the symbol: a triangle with a starburst (laser) or concentric arcs (field)
        cx, cy, r = x + 34 * K, y + 82 * K, 26 * K
        d.polygon([(cx, cy - r), (cx + r * 0.95, cy + r * 0.65), (cx - r * 0.95, cy + r * 0.65)], outline=INK,
                  width=4 * K)
        if sym == "laser":
            d.ellipse((cx - 5 * K, cy - 2 * K, cx + 5 * K, cy + 8 * K), fill=INK)
            for k in range(8):
                a = k * math.pi / 4
                d.line((cx + math.cos(a) * 7 * K, cy + 3 * K + math.sin(a) * 7 * K,
                        cx + math.cos(a) * 12 * K, cy + 3 * K + math.sin(a) * 12 * K), fill=INK, width=2 * K)
            d.line((cx - 3 * K, cy + 3 * K, cx - 18 * K, cy + 14 * K), fill=INK, width=2 * K)
        else:
            for rr in (5, 10, 15):
                d.arc((cx - rr * K, cy + 4 * K - rr * K, cx + rr * K, cy + 4 * K + rr * K), 200, 340, fill=INK,
                      width=2 * K)
            d.ellipse((cx - 3 * K, cy + 1 * K, cx + 3 * K, cy + 7 * K), fill=INK)
        for i, ln in enumerate(lines[1:]):
            f, tw, bb = fit(ln, label, (0, 0, w - 84 * K, 20 * K), 20 * K)
            d.text((x + 70 * K, y + (60 + i * 26) * K - bb[1]), ln, font=f, fill=INK)
    # the agency emblem, small, on its own white-rimmed roundel
    x, y, w, h = cells["emblem"]
    em = base_tex.emblem(w - 8 * K, seed=7).convert("RGBA")
    mask = Image.new("L", em.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, em.size[0] - 1, em.size[1] - 1), fill=255)
    img.paste(em, (x + 4 * K, y + 4 * K), mask)
    # the hazard stripe: tileable along its length (period = its height)
    x, y, w, h = cells["hazard"]
    d.rectangle((x, y, x + w - 1, y + h - 1), fill=WARN)
    for k in range(-1, w // h + 2):
        x0 = x + k * h
        d.polygon([(x0, y + h), (x0 + h / 2, y + h), (x0 + h, y), (x0 + h / 2, y)], fill=INK)
    # HOT: white stencil on warning red
    x, y, w, h = cells["hot"]
    d.rectangle((x + K, y + K, x + w - K, y + h - K), fill=RED)
    text("hot", "HOT SURFACE", stencil, 30, LIGHT, track=0.06)
    # a direction arrow (field emitter, this way) in orange
    x, y, w, h = cells["arrow"]
    d.polygon([(x + 8 * K, y + 16 * K), (x + 70 * K, y + 16 * K), (x + 70 * K, y + 4 * K), (x + 120 * K, y + h / 2),
               (x + 70 * K, y + h - 4 * K), (x + 70 * K, y + h - 16 * K), (x + 8 * K, y + h - 16 * K)], fill=ACC)
    img = img.resize((512, 512), Image.LANCZOS)
    # wear: soft grain and a few scuffs, low contrast
    a = np.asarray(img).astype(np.float32)
    rng = np.random.default_rng(17)
    grain = rng.normal(0, 5.0, a.shape[:2])
    a[..., :3] += grain[..., None]
    sc = np.asarray(Image.fromarray((rng.random((64, 64)) * 255).astype(np.uint8)).resize((512, 512), Image.BICUBIC)
                    .filter(ImageFilter.GaussianBlur(2)), np.float32) / 255
    scuff = np.clip((sc - 0.78) * 6, 0, 1)
    a[..., 3] *= 1 - 0.55 * scuff
    a[a[..., 3] < 1, :3] = 0          # nothing under the cut-out: it compresses
    a = np.clip(a, 0, 255).astype(np.uint8)
    os.makedirs(os.path.dirname(ATLAS_PATH), exist_ok=True)
    Image.fromarray(a, "RGBA").save(ATLAS_PATH, optimize=True)


def socket():
    m = Model()
    box(m, "Dark", (0.0, 0.0, 0.0), (0.004, 0.004, 0.004))
    return m


# ── a loose rock ────────────────────────────────────────────────────────────

def ico(sub=2):
    t = (1 + 5 ** 0.5) / 2
    V = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
         (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    V = [np.array(v, float) / np.linalg.norm(v) for v in V]
    F = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6),
         (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10),
         (8, 6, 7), (9, 8, 1)]
    for _ in range(sub):
        mid = {}
        NF = []

        def m_(a, b):
            k = (min(a, b), max(a, b))
            if k not in mid:
                p = V[a] + V[b]
                V.append(p / np.linalg.norm(p))
                mid[k] = len(V) - 1
            return mid[k]
        for a, b, c in F:
            ab, bc, ca = m_(a, b), m_(b, c), m_(c, a)
            NF += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        F = NF
    return np.array(V), F


def loose_rock(seed=7, size=(0.62, 0.42, 0.5)):
    rng = np.random.default_rng(seed)
    V, F = ico(2)
    # lumpy: a few random planes shaved off, plus low-frequency bumps
    P = V.copy()
    for _ in range(6):
        n = rng.normal(size=3)
        n /= np.linalg.norm(n)
        d = rng.uniform(0.55, 0.8)
        dist = P @ n
        over = dist > d
        P[over] -= np.outer(dist[over] - d, n)
    bump = 1 + 0.08 * np.sin(P[:, 0] * 5.1 + 1.3) * np.cos(P[:, 1] * 4.3) + 0.05 * np.sin(P[:, 2] * 7.7)
    P = P * bump[:, None] * np.asarray(size) / 2
    m = Model()
    # flat-shaded facets, triplanar-ish UVs per face
    for a, b, c in F:
        pa, pb, pc = P[a], P[b], P[c]
        n = np.cross(pb - pa, pc - pa)
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            continue
        n /= ln
        ax = int(np.argmax(np.abs(n)))
        u_ax, v_ax = [(1, 2), (0, 2), (0, 1)][ax]
        UV = [(p[u_ax] * 1.6, p[v_ax] * 1.6) for p in (pa, pb, pc)]
        m.add("Rock", [pa, pb, pc], [n, n, n], UV, [(0, 1, 2)])
    return m


# ── prefabs ─────────────────────────────────────────────────────────────────

def mats_block(model, indent="        ", pal=None):
    if isinstance(model, Rig):
        names = sorted({k for m in model.models.values() if m is not None for k in m.parts})
    else:
        names = sorted(model.parts.keys())
    pal = pal or PALETTES["laser"]
    body = ",\n".join(f'{indent}    "{n}": {ENERGY_MATS[n](pal) if n in ENERGY_MATS else TOOL_MATS[n]()}'
                      for n in names)
    return f"{indent}object_materials: {{\n{body},\n{indent}}},\n"


def tool_prefab(name, glb, model, about, pal=None):
    return f'''// {about}
// Written by tools/gen_tools.py — edit the generator, not this file.
[
    (
        name: "{name}",
        tags: ["tool"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/tools/{glb}",
        ),
{mats_block(model, pal=pal)}        scripts: [],
    ),
]
'''


def rock_prefab(model, half, mass):
    hx, hy, hz = half
    return f'''// LOOSE ROCK — a chunk the Terrain Laser knocks loose; the Gravity Gun lifts and
// throws it (scripts/tool_belt.lua). A one-part assembly, so a pull at a grab
// point torques it like any craft.
// Written by tools/gen_tools.py — edit the generator, not this file.
[
    (
        name: "LooseRock",
        tags: ["loose_rock"],
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
        name: "Rock",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/tools/loose_rock.glb",
        ),
{mats_block(model)}        scripts: [],
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


def build(name, fn, glb, prefab, about, pal, models_dir, prefabs_dir, asset_dir="models/tools"):
    """Build one tool, centre it, write its glb and prefab; return its RIG line."""
    r = fn()
    if name in FP_CENTRE:
        pin_centre(r, FP_CENTRE[name])
    mn, mx = r.bounds()
    r.shift(-(mn + mx) / 2)
    mn, mx = r.bounds()
    write_rig_glb(r, os.path.join(models_dir, glb))
    with open(os.path.join(prefabs_dir, prefab + ".prefab.ron"), "w") as f:
        f.write(tool_prefab(prefab, glb, r, about, pal=pal).replace('"models/tools/', f'"{asset_dir}/'))
    A = r.anchors
    return (A["grip"], A["muzzle"], A["fore"], A.get("vent", A["muzzle"]), mx - mn, r.tris(),
            [n["name"] for n in r.nodes if r.models.get(n["name"]) is not None], A.get("scope", A["grip"]))


def rig_lines(r, r_fp):
    """tool_belt's RIG / RIG_FP `laser` lines for a design (RIG_FP's grip is
    the same for every design: the view model's centre is pinned)."""
    f = lambda v: "{ " + ", ".join(f"{x:.3f}".rstrip("0").rstrip(".") if abs(x) > 5e-4 else "0.0" for x in v) + " }"
    g, mz, fo, vt = r[:4]
    gf, mzf, _, vtf = r_fp[:4]
    return (f"  laser   = {{ grip = {f(g)}, muzzle = {f(mz)}, fore = {f(fo)}, vent = {f(vt)} }},\n"
            f"  laser   = {{ grip = {f(gf)}, muzzle = {f(mzf)}, vent = {f(vtf)} }},\n")


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--laser-variant", default="C", choices=LASER_VARIANTS,
                    help="the laser design the game's ToolLaser / ToolLaserFP wear (default C, the TL-3 Plasma Bore)")
    ap.add_argument("--protos", metavar="DIR",
                    help="also write every laser design into DIR/models/tools and DIR/prefabs (ToolLaser<V>[FP])")
    args = ap.parse_args()
    lv = args.laser_variant
    WANT_LASERS[:] = list(LASER_VARIANTS) if args.protos else [lv]
    os.makedirs(MODELS, exist_ok=True)
    tool_atlas()
    rig = {}
    fld, las = PALETTES["field"], PALETTES["laser"]
    for name, fn, glb, prefab, about, pal in (
        ("gravgun", gravity_gun, "gravity_gun.glb", "ToolGravGun",
         "GRAVITY GUN — the crew's multi-purpose tool, held (scripts/tool_belt.lua).", fld),
        ("laser", lambda: terrain_laser(lv), "terrain_laser.glb", "ToolLaser",
         "TERRAIN LASER — digs and places ground, held (scripts/tool_belt.lua).", las),
        ("gravgun_fp", fp_gravity_gun, "fp_gravity_gun.glb", "ToolGravGunFP",
         "GRAVITY GUN, first person — gloved hands on it; the view-model camera draws it (scripts/tool_belt.lua).", fld),
        ("laser_fp", lambda: fp_terrain_laser(lv), "fp_terrain_laser.glb", "ToolLaserFP",
         "TERRAIN LASER, first person — gloved hands on it; the view-model camera draws it (scripts/tool_belt.lua).",
         las),
    ):
        rig[name] = build(name, fn, glb, prefab, about, pal, MODELS, PREFABS)
    pls = PALETTES["plasma"]
    for name, fn, glb, prefab, about in (
        ("surveyor", surveyor, "surveyor.glb", "ToolSurveyor",
         "TL-5 SURVEYOR — the crew's plasma rifle, held (scripts/tool_belt.lua draws it, scripts/surveyor.lua fires it)."),
        ("surveyor_fp", fp_surveyor, "fp_surveyor.glb", "ToolSurveyorFP",
         "TL-5 SURVEYOR, first person — gloved hands on it; the view-model camera draws it (scripts/tool_belt.lua)."),
    ):
        rig[name] = build(name, fn, glb, prefab, about, pls, MODELS, PREFABS)
    if args.protos:
        pm, pp = os.path.join(args.protos, "models", "tools"), os.path.join(args.protos, "prefabs")
        os.makedirs(pm, exist_ok=True)
        os.makedirs(pp, exist_ok=True)
        for v in LASER_VARIANTS:
            rig[f"laser{v}"] = build("laser", (lambda v=v: terrain_laser(v)), f"terrain_laser_{v}.glb",
                                     f"ToolLaser{v}", f"TERRAIN LASER design {v} (a prototype)", las, pm, pp)
            rig[f"laser{v}_fp"] = build("laser_fp", (lambda v=v: fp_terrain_laser(v)), f"fp_terrain_laser_{v}.glb",
                                        f"ToolLaser{v}FP", f"TERRAIN LASER design {v}, first person (a prototype)",
                                        las, pm, pp)
            with open(os.path.join(args.protos, f"rig_{v}.txt"), "w") as f:
                f.write(rig_lines(rig[f"laser{v}"], rig[f"laser{v}_fp"]))
    write_glb(socket(), os.path.join(MODELS, "socket.glb"))
    rk = loose_rock()
    rk, _ = centred(rk)
    mn, mx = rk.bounds()
    write_glb(rk, os.path.join(MODELS, "loose_rock.glb"))
    half = np.round((mx - mn) / 2 * 0.92, 3)
    with open(os.path.join(PREFABS, "LooseRock.prefab.ron"), "w") as f:
        f.write(rock_prefab(rk, half, 0.09))
    print(f"RIG (relative to each model's centre, metres; the game's laser is design {lv}):")
    for k, (g, mz, fo, vt, size, tris, nodes, _sc) in rig.items():
        print(f"  {k:10s} grip {np.round(g, 3).tolist()} muzzle {np.round(mz, 3).tolist()} "
              f"fore {np.round(fo, 3).tolist()} vent {np.round(vt, 3).tolist()} size {np.round(size, 3).tolist()} "
              f"tris {tris} nodes {nodes}")
    print(f"  rock     half {half.tolist()} tris {rk.tris()}")
    print("tool_belt's laser lines (RIG, then RIG_FP):")
    print(rig_lines(rig["laser"], rig["laser_fp"]), end="")
    print("tool_belt's surveyor lines (RIG, then RIG_FP; scope = the eyepiece):")
    print(rig_lines(rig["surveyor"], rig["surveyor_fp"]).replace("laser   =", "surveyor ="), end="")
    for k in ("surveyor", "surveyor_fp"):
        print(f"  {k} scope {np.round(rig[k][7], 3).tolist()}")


if __name__ == "__main__":
    main()
