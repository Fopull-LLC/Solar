#!/usr/bin/env python3
"""Generate the on-foot TOOLS and the loose rock they throw around.

    python3 tools/gen_tools.py

Writes
    models/tools/gravity_gun.glb     the Gravity Gun: a graphite receiver, a
                                     rear power cell, three signal-orange
                                     claws round a glowing emitter
    models/tools/terrain_laser.glb   the Terrain Laser: an enamel receiver, a
                                     finned barrel shroud, a lens head and the
                                     yellow fill canister it places rock from
    models/tools/fp_gravity_gun.glb  the FIRST-PERSON versions: the same tool
    models/tools/fp_terrain_laser.glb with the crew's gloved hands on its grips
                                     and the suit's sleeves running back out of
                                     the bottom of the view. Drawn only by the
                                     view-model camera (scripts/tool_belt.lua).
    models/tools/socket.glb          a few millimetres of nothing the hand
                                     node wears, so only the tool shows
    models/tools/loose_rock.glb      a chunk knocked loose by the laser
    prefabs/ToolGravGun, ToolLaser   the held tools (object_materials, no body)
    prefabs/ToolGravGunFP, ToolLaserFP   their first-person view models
    prefabs/LooseRock                a one-part assembly the gravity gun lifts

Every tool is modelled barrel down -Z with the grip under the receiver. The
engine recentres a model on its bounding box, so each model is shifted to be
centred and the GRIP, MUZZLE and FORE (the other hand's hold) are printed
relative to that centre — those are the numbers `scripts/tool_belt.lua` keeps
in `RIG` (third person) and `RIG_FP` (first person: a different model, so a
different centre).

The tools are modelled at TRUE SIZE, in metres, and held at scale 1 in both
views: a gravity gun is 0.64 m long, the laser 0.83 m.

Built from tools/gen_part_meshes.py's primitives and textures, so a tool in
the hand wears the same paint and metal as the craft it stands beside.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import (PREFABS, ROOT, TAU, Model, box, disk, flange, frame_to,  # noqa: E402
                             lathe, mat_ron, rot_x, rot_z, tube, write_glb)

from gen_suit import CLOTH, GLOVE, PALM, SUIT_MATS  # noqa: E402

MODELS = os.path.join(ROOT, "models", "tools")


def suit_cloth(col):
    """The suit's cloth texture set in one of its colours (the suit itself
    carries these as vertex colours; a view model's material does it)."""
    return SUIT_MATS["SuitFabric"]().replace("color: (1.0, 1.0, 1.0)", f"color: {tuple(col)}", 1)


def glow(r, g, b, s=2.6):
    return (f'(\n                color: ({r}, {g}, {b}),\n                emissive: ({r}, {g}, {b}),\n'
            f'                emissive_strength: {s},\n                roughness: 0.3,\n'
            f'                metallic: 0.0,\n                shading: Physical,\n            )')


TOOL_MATS = {
    "GunBody":   lambda: mat_ron("metal", color=(0.26, 0.27, 0.29), rough=1.1, metal=0.45, hull=False),
    "GunPaint":  lambda: mat_ron("paint", color=(0.97, 0.52, 0.18), hull=False),
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
    "SuitMetal": lambda: SUIT_MATS["SuitMetal"](),
    "Hazard":    lambda: mat_ron("paint", color=(0.95, 0.72, 0.12), hull=False),
    "Lens":      lambda: ('(\n                color: (0.20, 0.30, 0.34),\n                roughness: 0.05,\n'
                          '                metallic: 0.2,\n                alpha: 0.85,\n'
                          '                shading: Physical,\n            )'),
    "GlowTeal":  lambda: glow(0.45, 0.95, 1.0, 3.2),
    "GlowAmber": lambda: glow(1.0, 0.62, 0.25, 2.6),
    "Rock":      lambda: ('(\n                color: (0.78, 0.74, 0.68),\n'
                          '                texture: Some("textures/terrain/geo_granite.png"),\n'
                          '                roughness: 0.92,\n                metallic: 0.0,\n'
                          '                shading: Physical,\n            )'),
}


def along_z(m, mat, z0, z1, r, y=0.0, x=0.0, segs=16, r1=None, caps=True):
    """A tube on the Z axis (the barrel axis) from z0 to z1."""
    tube(m, mat, (x, y, z0), (x, y, z1), r, segs=segs, caps=caps, r1=r1)


def ring_z(m, mat, z, r_in, r_out, w, y=0.0, x=0.0, segs=24):
    """A flange ring round the Z axis: a short fat tube with a bore."""
    sub = Model()
    flange(sub, mat, -w / 2, w / 2, r_in, r_out, segs=segs, uv_m=4.0, chamfer=min(0.003, w / 4))
    m.merge(sub, rot_x(math.pi / 2), (x, y, z))


def lathe_z(m, mat, prof, z_at, y=0.0, segs=24, smooth=True):
    """A lathe about +Z: profile (r, t) with t measured along -Z from z_at."""
    sub = Model()
    lathe(sub, mat, prof, segs=segs, smooth=smooth, uv_m=4.0)
    m.merge(sub, rot_x(-math.pi / 2), (0.0, y, z_at))


def centred(m):
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    return out, c


# ── the gravity gun ─────────────────────────────────────────────────────────

def gravity_gun():
    m = Model()
    Y = 0.045                         # the barrel axis, above the grip
    # Receiver: a bevelled graphite block, a darker spine on top.
    box(m, "GunBody", (0.0, Y, -0.02), (0.115, 0.125, 0.30), bevel=0.012)
    box(m, "Dark", (0.0, Y + 0.068, -0.03), (0.06, 0.016, 0.24))
    # Cooling fins down the spine.
    for k in range(7):
        box(m, "Chrome", (0.0, Y + 0.082, -0.13 + k * 0.032), (0.075, 0.014, 0.006))
    # Side armour plates in signal orange, with a recessed vent.
    for s in (-1, 1):
        box(m, "GunPaint", (s * 0.061, Y + 0.004, -0.04), (0.010, 0.085, 0.20), bevel=0.004)
        box(m, "Dark", (s * 0.067, Y + 0.004, -0.075), (0.004, 0.04, 0.07))
    # The rear power cell: a fat drum with a hazard band and a lit gauge.
    along_z(m, "Anodised", 0.13, 0.25, 0.058, y=Y + 0.01, segs=20)
    ring_z(m, "Hazard", 0.165, 0.057, 0.062, 0.022, y=Y + 0.01)
    ring_z(m, "Chrome", 0.245, 0.04, 0.06, 0.012, y=Y + 0.01)
    box(m, "GlowTeal", (0.0, Y + 0.066, 0.20), (0.018, 0.006, 0.05))
    # Emitter housing: a flared bell round the barrel axis.
    lathe_z(m, "GunBody", [(0.068, 0.0), (0.072, 0.02), (0.064, 0.06), (0.05, 0.075)], -0.17, y=Y)
    ring_z(m, "Chrome", -0.18, 0.06, 0.075, 0.014, y=Y)
    ring_z(m, "Chrome", -0.215, 0.055, 0.069, 0.010, y=Y)
    # The emitter core, glowing, inside a dark throat.
    along_z(m, "Dark", -0.245, -0.215, 0.04, y=Y, segs=18)
    lathe_z(m, "GlowTeal", [(0.0, -0.012), (0.024, 0.0), (0.03, 0.018), (0.018, 0.034), (0.0, 0.04)], -0.235, y=Y,
            segs=18)
    # Three claws: out from the bell, then hooking in at the tip.
    for k in range(3):
        a = math.pi / 2 + k * TAU / 3
        c, s = math.cos(a), math.sin(a)
        p0 = np.array([c * 0.058, Y + s * 0.058, -0.20])
        p1 = np.array([c * 0.098, Y + s * 0.098, -0.30])
        p2 = np.array([c * 0.072, Y + s * 0.072, -0.385])
        tube(m, "GunPaint", p0, p1, 0.013, segs=8)
        tube(m, "GunPaint", p1, p2, 0.011, segs=8, r1=0.007)
        tube(m, "Chrome", p1 - (p1 - p0) * 0.08, p1 + (p2 - p1) * 0.08, 0.016, segs=8)
        # a lit tip on each claw
        tube(m, "GlowTeal", p2, p2 + (p2 - p1) * 0.12, 0.007, segs=6)
    # Pistol grip, raked back, with a trigger guard.
    rake = rot_x(-0.32)
    box(m, "Rubber", (0.0, -0.055, 0.045), (0.042, 0.13, 0.055), M=rake, bevel=0.01)
    box(m, "Dark", (0.0, -0.012, -0.012), (0.012, 0.012, 0.07))
    box(m, "Dark", (0.0, -0.035, -0.045), (0.012, 0.05, 0.010))
    box(m, "Chrome", (0.0, -0.005, 0.012), (0.008, 0.03, 0.01))
    # A fore-grip under the bell for the other hand.
    tube(m, "Rubber", (0.0, Y - 0.06, -0.12), (0.0, Y - 0.12, -0.13), 0.018, segs=10)
    grip = np.array([0.0, -0.04, 0.05])
    muzzle = np.array([0.0, Y, -0.30])
    fore = np.array([0.0, Y - 0.09, -0.125])   # the fore-grip's middle
    return m, grip, muzzle, fore


# ── the terrain laser ───────────────────────────────────────────────────────

def terrain_laser():
    m = Model()
    Y = 0.05
    # Receiver in off-white enamel, a dark top rail.
    box(m, "Enamel", (0.0, Y, 0.02), (0.095, 0.11, 0.30), bevel=0.01)
    box(m, "Dark", (0.0, Y + 0.062, 0.0), (0.04, 0.014, 0.26))
    for k in range(9):
        box(m, "Dark", (0.0, Y + 0.071, -0.11 + k * 0.026), (0.046, 0.006, 0.010))
    # The barrel shroud: anodised, ringed with heat-sink fins.
    along_z(m, "Anodised", -0.13, -0.46, 0.034, y=Y, segs=18)
    for k in range(10):
        ring_z(m, "Chrome", -0.16 - k * 0.028, 0.033, 0.05, 0.007, y=Y)
    # The lens head: a stepped bell with an amber glass and a lit ring.
    lathe_z(m, "GunBody", [(0.036, 0.0), (0.048, 0.015), (0.052, 0.05), (0.046, 0.07)], -0.46, y=Y)
    ring_z(m, "GlowAmber", -0.52, 0.036, 0.044, 0.006, y=Y)
    disk_m = Model()
    disk(disk_m, "Lens", 0.04, 0.0, segs=20, up=True)
    m.merge(disk_m, rot_x(-math.pi / 2), (0.0, Y, -0.529))
    # Under-barrel emitter coil housing.
    along_z(m, "Dark", -0.10, -0.30, 0.018, y=Y - 0.05, segs=10)
    # The fill canister on the left: yellow, with a window and two clamps.
    along_z(m, "Hazard", -0.07, 0.14, 0.034, y=Y + 0.01, x=-0.075, segs=16)
    ring_z(m, "Chrome", -0.04, 0.033, 0.038, 0.012, y=Y + 0.01, x=-0.075)
    ring_z(m, "Chrome", 0.11, 0.033, 0.038, 0.012, y=Y + 0.01, x=-0.075)
    box(m, "GlowAmber", (-0.108, Y + 0.01, 0.035), (0.004, 0.02, 0.07))
    # Power tap on the right and a sight on top.
    box(m, "GunBody", (0.058, Y - 0.01, 0.06), (0.02, 0.05, 0.12), bevel=0.004)
    tube(m, "Dark", (0.0, Y + 0.08, -0.02), (0.0, Y + 0.08, -0.09), 0.012, segs=10)
    # Stock, raked down, with a rubber butt.
    box(m, "GunBody", (0.0, Y - 0.01, 0.22), (0.05, 0.08, 0.12), M=rot_x(0.12), bevel=0.008)
    box(m, "Rubber", (0.0, Y - 0.02, 0.285), (0.055, 0.095, 0.02), M=rot_x(0.12))
    # Pistol grip and guard.
    box(m, "Rubber", (0.0, -0.05, 0.075), (0.04, 0.12, 0.052), M=rot_x(-0.3), bevel=0.01)
    box(m, "Dark", (0.0, -0.01, 0.015), (0.012, 0.012, 0.07))
    box(m, "Dark", (0.0, -0.03, -0.018), (0.012, 0.045, 0.01))
    grip = np.array([0.0, -0.035, 0.08])
    muzzle = np.array([0.0, Y, -0.535])
    fore = np.array([0.0, Y - 0.08, -0.22])    # a palm under the emitter housing
    return m, grip, muzzle, fore


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


def pin_centre(m, want):
    mn, mx = m.bounds()
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
    capsule(m, fingers[0], fingers[1], thick * 0.78, wide * 0.94, fingers[2] if len(fingers) > 2 else palm_n)
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


def fp_gravity_gun():
    m, grip, muzzle, fore = gravity_gun()
    # Right hand round the raked pistol grip: the palm down its back, the
    # fingers across its front, the thumb up the receiver's left flank.
    w = np.array([0.012, -0.10, 0.125])
    fp_glove(m, w, w + np.array([0.13, -0.30, 0.42]),
             palm=((0.012, -0.095, 0.10), (0.008, -0.02, 0.07)),
             fingers=((-0.004, -0.03, 0.03), (0.0, -0.09, 0.012), (0.0, 0.0, 1.0)),
             palm_n=(-0.2, 0.0, -1.0),
             thumb=((-0.045, -0.035, 0.09), (-0.074, 0.008, 0.03), (1.0, 0.0, 0.0)), wide=0.042, thick=0.026)
    # Left hand on the emitter bell's left flank, palm in, the fingers
    # curled over its top.
    Y = 0.045
    w = np.array([-0.135, Y - 0.10, -0.075])
    fp_glove(m, w, w + np.array([-0.24, -0.36, 0.34]),
             palm=((-0.118, Y - 0.07, -0.115), (-0.098, Y + 0.025, -0.135)),
             fingers=((-0.082, Y + 0.058, -0.138), (-0.018, Y + 0.084, -0.142), (0.45, -1.0, 0.0)),
             palm_n=(1.0, 0.0, 0.0),
             thumb=((-0.112, Y - 0.06, -0.14), (-0.07, Y - 0.075, -0.185), (0.3, 1.0, 0.0)), wide=0.055, thick=0.034)
    return m, grip, muzzle, fore


def fp_terrain_laser():
    m, grip, muzzle, fore = terrain_laser()
    # Right hand on the pistol grip.
    w = np.array([0.012, -0.095, 0.155])
    fp_glove(m, w, w + np.array([0.13, -0.30, 0.40]),
             palm=((0.012, -0.09, 0.13), (0.008, -0.015, 0.10)),
             fingers=((-0.004, -0.025, 0.06), (0.0, -0.085, 0.042), (0.0, 0.0, 1.0)),
             palm_n=(-0.2, 0.0, -1.0),
             thumb=((-0.04, -0.03, 0.12), (-0.066, 0.008, 0.06), (1.0, 0.0, 0.0)), wide=0.042, thick=0.026)
    # Left hand on the barrel shroud's left side, fingers over its fins.
    Y = 0.05
    w = np.array([-0.12, Y - 0.10, -0.165])
    fp_glove(m, w, w + np.array([-0.25, -0.34, 0.33]),
             palm=((-0.10, Y - 0.07, -0.205), (-0.078, Y + 0.02, -0.225)),
             fingers=((-0.066, Y + 0.05, -0.228), (-0.008, Y + 0.068, -0.232), (0.45, -1.0, 0.0)),
             palm_n=(1.0, 0.0, 0.0),
             thumb=((-0.09, Y - 0.06, -0.225), (-0.05, Y - 0.07, -0.27), (0.3, 1.0, 0.0)), wide=0.055, thick=0.034)
    return m, grip, muzzle, fore


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

def mats_block(model, indent="        "):
    names = sorted(model.parts.keys())
    body = ",\n".join(f'{indent}    "{n}": {TOOL_MATS[n]()}' for n in names)
    return f"{indent}object_materials: {{\n{body},\n{indent}}},\n"


def tool_prefab(name, glb, model, about):
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
{mats_block(model)}        scripts: [],
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


def main():
    os.makedirs(MODELS, exist_ok=True)
    rig = {}
    for name, fn, glb, prefab, about in (
        ("gravgun", gravity_gun, "gravity_gun.glb", "ToolGravGun",
         "GRAVITY GUN — the crew's multi-purpose tool, held (scripts/tool_belt.lua)."),
        ("laser", terrain_laser, "terrain_laser.glb", "ToolLaser",
         "TERRAIN LASER — digs and places ground, held (scripts/tool_belt.lua)."),
        ("gravgun_fp", fp_gravity_gun, "fp_gravity_gun.glb", "ToolGravGunFP",
         "GRAVITY GUN, first person — gloved hands on it; the view-model camera draws it (scripts/tool_belt.lua)."),
        ("laser_fp", fp_terrain_laser, "fp_terrain_laser.glb", "ToolLaserFP",
         "TERRAIN LASER, first person — gloved hands on it; the view-model camera draws it (scripts/tool_belt.lua)."),
    ):
        m, grip, muzzle, fore = fn()
        if name in FP_CENTRE:
            pin_centre(m, FP_CENTRE[name])
        m, c = centred(m)
        mn, mx = m.bounds()
        write_glb(m, os.path.join(MODELS, glb))
        with open(os.path.join(PREFABS, prefab + ".prefab.ron"), "w") as f:
            f.write(tool_prefab(prefab, glb, m, about))
        rig[name] = (grip - c, muzzle - c, fore - c, mx - mn, m.tris())
    write_glb(socket(), os.path.join(MODELS, "socket.glb"))
    r = loose_rock()
    r, _ = centred(r)
    mn, mx = r.bounds()
    write_glb(r, os.path.join(MODELS, "loose_rock.glb"))
    half = np.round((mx - mn) / 2 * 0.92, 3)
    with open(os.path.join(PREFABS, "LooseRock.prefab.ron"), "w") as f:
        f.write(rock_prefab(r, half, 0.09))
    print("RIG (relative to each model's centre, metres):")
    for k, (g, mz, fo, size, tris) in rig.items():
        print(f"  {k:10s} grip {np.round(g, 3).tolist()} muzzle {np.round(mz, 3).tolist()} "
              f"fore {np.round(fo, 3).tolist()} size {np.round(size, 3).tolist()} tris {tris}")
    print(f"  rock     half {half.tolist()} tris {r.tris()}")


if __name__ == "__main__":
    main()
