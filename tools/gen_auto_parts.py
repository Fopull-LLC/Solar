#!/usr/bin/env python3
"""Generate the AUTO-ENGINEERING parts (docs/auto-engineering.md): the Moto
Wheel, the Telescopic Fork, the Swing Arm, the Coil-over Strut and the Balance
Gyro — meshes into models/parts/, whole prefabs into prefabs/ (and their
visual-only copies into prefabs/vis/).

    python3 tools/gen_auto_parts.py          # meshes, prefabs, vis prefabs
    python3 tools/gen_auto_parts.py --dry    # meshes only; print the frames

Built from tools/gen_part_meshes.py's primitives and its shared texture
library (UVs in metres of surface), so a fork's anodised legs carry the same
grain and rivet scale as a rover body's.

THE FRAMES the flight and the builder rely on (scripts/parts_auto.lua holds the
same numbers; this script prints them so the two can be checked):

* Every root is the part's box centre (the engine recentres meshes on their
  bounds, so each moving mesh is a recentred child at its own centre).
* Fork, swing arm and strut are radial parts: +X points OUT of the face they
  mount on. The fork goes on a FRONT face (+X forward), the swing arm on a
  REAR face (+X backward), the strut on a flank (+X outboard). +Y is up.
* The fork's steering axis is raked RAKE degrees: it runs up and back along
  (−sin, cos, 0). Its moving halves hang off two Empties on that axis:
  ForkRake (fixed, turned by the rake about Z) > ForkSteer (yawed by the
  steering) > ForkSlide (slid along local −Y by the suspension).
* Hubs: the point a wheel's centre is clamped at, with its axle direction.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_part_meshes as G  # noqa: E402
from gen_part_meshes import Model, lathe, disk, box, tube, flange, bolt_ring, flat_decal, tyre, rot_z, rot_x, rot_y  # noqa: E402,F401

TAU = 2 * math.pi
RAKE = 24.0                  # degrees, the fork's steering axis from upright
MOTO_R, MOTO_W = 0.33, 0.15  # moto tyre radius and width (m)
AXLE_HALF = 0.11             # through-axle stub ends, ±X of the wheel centre


def shifted(m, d):
    out = Model()
    out.merge(m, None, d)
    return out


def rot_axis_to_x():
    """lathe() revolves about +Y; this turns that axis onto +X."""
    return rot_z(-math.pi / 2)


def rot_axis_to_z():
    return rot_x(math.pi / 2)


def quat_z(deg):
    a = math.radians(deg) / 2
    return (0.0, 0.0, round(math.sin(a), 7), round(math.cos(a), 7))


# ── MOTO WHEEL: a spoked through-axle wheel, centred on its own part ─────────
def moto_wheel():
    """Tyre, rim, 32 crossed wire spokes, hub and a drilled brake disc, about
    the X axis, centred. Returns (wheel, axle): the wheel spins (the live
    tyre's mesh, the part's "Tyre"), the axle stubs do not."""
    w = Model()
    tyre(w, MOTO_R, MOTO_W, segs=48, rim=False)
    rim_r = MOTO_R - 0.065
    rim = Model()
    # a drop-centre rim: a channel profile about +Y (turned onto X below)
    prof = [(rim_r + 0.012, -0.062), (rim_r + 0.004, -0.055), (rim_r - 0.006, -0.03),
            (rim_r - 0.012, 0.0), (rim_r - 0.006, 0.03), (rim_r + 0.004, 0.055), (rim_r + 0.012, 0.062)]
    lathe(rim, "Chrome", prof, segs=48, uv_m=3.0, smooth=True)
    lathe(rim, "Dark", [(rim_r + 0.012, 0.062), (rim_r + 0.012, -0.062)], segs=48, uv_m=3.0, inward=True)
    # hub drum and its spoke flanges
    lathe(rim, "Anodised", [(0.035, -0.07), (0.05, -0.06), (0.05, 0.06), (0.035, 0.07)], segs=20, uv_m=4.0)
    for sy in (-1, 1):
        flange(rim, "Metal", sy * 0.052 - 0.006, sy * 0.052 + 0.006, 0.03, 0.068, segs=20, uv_m=4.0)
    # 2 × 16 spokes, crossed (tangential), each flange to the far side of the rim
    for sy in (-1, 1):
        for k in range(16):
            a = TAU * (k + (0.5 if sy > 0 else 0.0)) / 16
            off = 0.55 * (1 if k % 2 == 0 else -1)
            p0 = (0.062 * math.cos(a), sy * 0.052, 0.062 * math.sin(a))
            p1 = ((rim_r - 0.012) * math.cos(a + off), sy * 0.012, (rim_r - 0.012) * math.sin(a + off))
            tube(rim, "Metal", p0, p1, 0.0032, segs=4, caps=False, uv_m=8.0)
    # the brake disc (drilled look: an outer band and a carrier), +Y side
    disk(rim, "Chrome", 0.15, 0.072, segs=40, up=True, uv_m=4.0, r_in=0.10)
    disk(rim, "Chrome", 0.15, 0.066, segs=40, up=False, uv_m=4.0, r_in=0.10)
    disk(rim, "Dark", 0.10, 0.069, segs=24, up=True, uv_m=4.0, r_in=0.045)
    for k in range(6):
        a = TAU * k / 6
        tube(rim, "Metal", (0.07 * math.cos(a), 0.066, 0.07 * math.sin(a)), (0.07 * math.cos(a), 0.078, 0.07 * math.sin(a)),
             0.006, segs=6, uv_m=8.0)
    w.merge(rim, rot_axis_to_x())
    axle = Model()
    tube(axle, "Chrome", (-AXLE_HALF, 0, 0), (AXLE_HALF, 0, 0), 0.014, segs=12, uv_m=6.0)
    for sx in (-1, 1):
        # castellated axle nuts on both ends: the through-axle's attach faces
        tube(axle, "Metal", (sx * (AXLE_HALF - 0.016), 0, 0), (sx * AXLE_HALF, 0, 0), 0.024, segs=6, uv_m=8.0)
    return w, axle


# ── TELESCOPIC FORK ──────────────────────────────────────────────────────────
def fork():
    """Design frame: the lower triple clamp's centre on the steering axis at
    the origin. Returns head (fixed, design frame), upper and lower (rake
    frame: +Y along the steering axis), the hub in rake frame, the mount face
    x (design)."""
    head = Model()
    # the steering head tube along the axis (fixed to the frame)
    rk = math.radians(RAKE)
    a = np.array([-math.sin(rk), math.cos(rk), 0.0])
    q0, q1 = a * 0.03, a * 0.17
    tube(head, "Anodised", q0, q1, 0.034, segs=16, uv_m=4.0)
    # gusseted mount bracket back to the face it bolts to (design x = X_FACE)
    X_FACE = -0.17
    box(head, "Anodised", (X_FACE + 0.015, 0.10, 0), (0.03, 0.28, 0.20), uv_m=3.0)
    for zc in (-0.06, 0.06):
        tube(head, "Anodised", (X_FACE + 0.02, 0.18, zc), tuple(a * 0.15 + np.array([0, 0, zc * 0.3])), 0.016, segs=8, uv_m=4.0)
        tube(head, "Anodised", (X_FACE + 0.02, 0.02, zc), tuple(a * 0.05 + np.array([0, 0, zc * 0.3])), 0.016, segs=8, uv_m=4.0)
    for sy in (0.0, 0.2):
        for sz in (-0.07, 0.07):
            tube(head, "Metal", (X_FACE, sy, sz), (X_FACE + 0.035, sy, sz), 0.008, segs=6, uv_m=8.0)
    flat_decal(head, "Decal", "hazard", (X_FACE + 0.031, 0.10, 0.0), (0, 0, -1), (0, 1, 0), 0.16, 0.035)

    upper = Model()   # rake frame: everything that steers but does not slide
    LEG_Z, LEG_X = 0.112, 0.04
    for yc in (0.0, 0.2):
        box(upper, "Anodised", (0.015, yc, 0), (0.09, 0.03, 2 * LEG_Z + 0.07), uv_m=4.0, bevel=0.0)
        tube(upper, "Metal", (0.0, yc - 0.016, 0), (0.0, yc + 0.016, 0), 0.038, segs=14, uv_m=6.0)
    # stanchions (chrome) from above the top clamp down into the sliders
    for sz in (-1, 1):
        tube(upper, "Chrome", (LEG_X, 0.235, sz * LEG_Z), (LEG_X, -0.38, sz * LEG_Z), 0.021, segs=14, uv_m=6.0)
        tube(upper, "Dark", (LEG_X, 0.235, sz * LEG_Z), (LEG_X, 0.25, sz * LEG_Z), 0.024, segs=10, uv_m=6.0)
    # handlebar: risers, a bent tubular bar, grips and levers
    for sz in (-0.035, 0.035):
        tube(upper, "Dark", (-0.005, 0.215, sz), (-0.03, 0.28, sz), 0.012, segs=8, uv_m=6.0)
    bar = [(-0.03, 0.28, 0.0), (-0.035, 0.285, 0.14), (-0.075, 0.30, 0.27), (-0.09, 0.305, 0.34)]
    for sz in (-1, 1):
        pts = [(x, y, sz * z) for x, y, z in bar]
        for p, q in zip(pts[:-1], pts[1:]):
            tube(upper, "Chrome", p, q, 0.011, segs=10, uv_m=6.0)
        g0 = (-0.075, 0.30, sz * 0.27)
        g1 = (-0.092, 0.306, sz * 0.355)
        tube(upper, "Rubber", g0, g1, 0.017, segs=10, uv_m=6.0)
        # brake / clutch lever and its perch
        box(upper, "Dark", (-0.06, 0.296, sz * 0.205), (0.04, 0.03, 0.035), uv_m=6.0)
        tube(upper, "Metal", (-0.06, 0.296, sz * 0.205), (-0.12, 0.29, sz * 0.31), 0.006, segs=6, uv_m=8.0)
    # a small round gauge on the top clamp
    tube(upper, "Dark", (0.02, 0.215, 0), (0.035, 0.255, 0), 0.038, segs=16, uv_m=6.0)

    lower = Model()   # rake frame: what slides with the suspension
    HUB = np.array([LEG_X + 0.012, -0.70, 0.0])
    for sz in (-1, 1):
        tube(lower, "Dark", (LEG_X, -0.29, sz * LEG_Z), (LEG_X, -0.66, sz * LEG_Z), 0.03, segs=14, uv_m=5.0)
        tube(lower, "Metal", (LEG_X, -0.30, sz * LEG_Z), (LEG_X, -0.285, sz * LEG_Z), 0.033, segs=14, uv_m=6.0)
        # the axle lug and its pinch bolts
        box(lower, "Dark", (HUB[0], HUB[1] + 0.01, sz * LEG_Z), (0.075, 0.085, 0.05), uv_m=5.0)
        for yy in (-0.73, -0.67):
            tube(lower, "Metal", (HUB[0] - 0.045, yy, sz * (LEG_Z + 0.012)), (HUB[0] - 0.02, yy, sz * (LEG_Z + 0.012)), 0.006,
                 segs=6, uv_m=8.0)
    # the brake caliper on the +Z slider, over the disc
    box(lower, "Yellow", (HUB[0] - 0.09, HUB[1] + 0.10, LEG_Z - 0.035), (0.05, 0.12, 0.035), uv_m=5.0)
    tube(lower, "Dark", (HUB[0] - 0.09, HUB[1] + 0.22, LEG_Z - 0.035), (HUB[0] - 0.13, HUB[1] + 0.48, LEG_Z - 0.01), 0.005, segs=6)
    # fork brace and the front fender over the tyre (about the axle)
    box(lower, "Dark", (LEG_X - 0.01, -0.44, 0), (0.05, 0.035, 2 * LEG_Z), uv_m=5.0)
    fen = Model()
    FR = MOTO_R + 0.035
    lathe(fen, "Paint3", [(FR, -0.085), (FR + 0.012, -0.075), (FR + 0.016, 0.0), (FR + 0.012, 0.075), (FR, 0.085)],
          segs=24, uv_m=2.0, a0=math.radians(-110), a1=math.radians(35), smooth=True)
    lathe(fen, "Dark", [(FR, 0.085), (FR, -0.085)], segs=24, uv_m=2.0, a0=math.radians(-110), a1=math.radians(35),
          inward=True)
    # the fender's arc runs from ahead-low to over the top, in the rake frame:
    # lathe about Y, turned so its axis is Z, about the hub
    lower.merge(fen, rot_axis_to_z(), HUB)
    return head, upper, lower, HUB, X_FACE


# ── SWING ARM ────────────────────────────────────────────────────────────────
def swing_arm():
    """Design frame: the pivot at the origin (on the rear face, +X back).
    Returns mount (fixed), arm (pivot frame = design frame), hub, pivot."""
    mount = Model()
    box(mount, "Anodised", (0.015, 0.06, 0), (0.03, 0.32, 0.30), uv_m=3.0)
    for sz in (-1, 1):
        box(mount, "Anodised", (0.045, 0.0, sz * 0.13), (0.06, 0.10, 0.025), uv_m=4.0)   # pivot lugs
    box(mount, "Anodised", (0.06, 0.20, 0), (0.07, 0.06, 0.07), uv_m=4.0)               # shock tower
    for sy in (-0.06, 0.18):
        for sz in (-0.10, 0.10):
            tube(mount, "Metal", (0.0, sy, sz), (0.036, sy, sz), 0.008, segs=6, uv_m=8.0)
    flat_decal(mount, "Decal", "hazard", (0.031, 0.17, 0.0), (0, 0, -1), (0, 1, 0), 0.18, 0.035)

    arm = Model()
    PIV = np.array([0.05, 0.0, 0.0])
    HUB = np.array([0.60, -0.07, 0.0])
    ARM_Z = 0.112
    tube(arm, "Chrome", (PIV[0], PIV[1], -0.135), (PIV[0], PIV[1], 0.135), 0.022, segs=14, uv_m=6.0)
    for sz in (-1, 1):
        # a tapered box-section side member, pivot to axle
        d = HUB - PIV
        L = float(np.linalg.norm(d))
        ang = math.atan2(d[1], d[0])
        M = rot_z(ang)
        box(arm, "Anodised", tuple(PIV + d * 0.5 + np.array([0, 0, sz * ARM_Z])), (L, 0.07, 0.035), M=M, uv_m=3.0)
        tube(arm, "Anodised", (PIV[0], PIV[1], sz * 0.12), (PIV[0], PIV[1], sz * 0.09), 0.04, segs=14, uv_m=4.0)
        # chain adjuster block at the axle
        box(arm, "Dark", (HUB[0], HUB[1], sz * ARM_Z), (0.08, 0.065, 0.04), uv_m=5.0)
        tube(arm, "Metal", (HUB[0] + 0.04, HUB[1], sz * ARM_Z), (HUB[0] + 0.07, HUB[1], sz * ARM_Z), 0.006, segs=6, uv_m=8.0)
    # cross brace and the shock's lower clevis
    box(arm, "Anodised", (0.17, -0.015, 0), (0.05, 0.06, 2 * ARM_Z), uv_m=3.0)
    box(arm, "Dark", (0.20, 0.03, 0), (0.05, 0.05, 0.05), uv_m=5.0)
    # the monoshock: yellow coil over a chrome body, clevis to the tower
    s0, s1 = np.array([0.20, 0.05, 0.0]), np.array([0.075, 0.20, 0.0])
    tube(arm, "Chrome", s0, s0 + (s1 - s0) * 0.55, 0.013, segs=10, uv_m=6.0)
    tube(arm, "Dark", s0 + (s1 - s0) * 0.45, s1, 0.026, segs=12, uv_m=6.0)
    dd = (s1 - s0) / np.linalg.norm(s1 - s0)
    for k in range(7):
        p = s0 + (s1 - s0) * (0.12 + 0.11 * k)
        tube(arm, "Yellow", p, p + dd * 0.018, 0.04, segs=12, uv_m=6.0)
    # belt guard on the −Z side
    box(arm, "Paint3", (0.36, 0.0, -ARM_Z - 0.035), (0.42, 0.08, 0.008), M=rot_z(math.atan2(HUB[1], HUB[0])), uv_m=3.0)
    return mount, arm, HUB, PIV


# ── COIL-OVER STRUT (a car or rover corner) ──────────────────────────────────
def strut():
    """Design frame: the mount face at x = 0 (+X outboard), +Y up, Z along
    the craft. Returns upper (fixed), lower (slides on the strut's axis and
    steers about it), arm (a lower wishbone, pivot frame), the flange point,
    the strut axis x, the arm pivot and its length."""
    up = Model()
    box(up, "Anodised", (0.015, 0.04, 0), (0.03, 0.56, 0.26), uv_m=3.0)       # mount plate
    for sy in (-0.20, 0.0, 0.25):
        for sz in (-0.095, 0.095):
            tube(up, "Metal", (0.0, sy, sz), (0.036, sy, sz), 0.008, segs=6, uv_m=8.0)
    AX = 0.14                       # the strut's axis, x
    box(up, "Anodised", (0.075, 0.29, 0), (0.12, 0.04, 0.16), uv_m=4.0)       # top mount
    tube(up, "Dark", (AX, 0.30, 0), (AX, 0.02, 0), 0.036, segs=16, uv_m=5.0)  # damper body
    tube(up, "Metal", (AX, 0.24, 0), (AX, 0.255, 0), 0.075, segs=20, uv_m=5.0)  # upper spring seat
    for k in range(8):
        y = 0.225 - 0.028 * k
        tube(up, "Yellow", (AX, y, 0), (AX, y - 0.017, 0), 0.066, segs=16, uv_m=6.0)
    tube(up, "Metal", (AX, 0.0, 0), (AX, 0.015, 0), 0.072, segs=20, uv_m=5.0)  # lower spring seat
    flat_decal(up, "Decal", "hazard", (0.031, -0.12, 0.0), (0, 0, -1), (0, 1, 0), 0.2, 0.035)
    # bump-stop rubber under the damper
    tube(up, "Rubber", (AX, 0.02, 0), (AX, -0.01, 0), 0.03, segs=12, uv_m=6.0)

    lo = Model()   # in the strut's own frame (the axis through x = AX)
    tube(lo, "Chrome", (AX, 0.12, 0), (AX, -0.17, 0), 0.016, segs=12, uv_m=6.0)
    box(lo, "Anodised", (AX + 0.025, -0.22, 0), (0.07, 0.12, 0.09), uv_m=4.0)   # knuckle
    box(lo, "Anodised", (AX + 0.0, -0.18, 0.07), (0.03, 0.03, 0.10), uv_m=4.0)  # steering arm
    FL = np.array([AX + 0.085, -0.22, 0.0])
    lathe_m = Model()
    flange(lathe_m, "Metal", -0.025, 0.0, 0.0, 0.085, segs=24, uv_m=4.0)
    lathe(lathe_m, "Dark", [(0.06, -0.06), (0.07, -0.025)], segs=24, uv_m=4.0)
    for k in range(5):
        a = TAU * k / 5
        tube(lathe_m, "Chrome", (0.055 * math.cos(a), -0.002, 0.055 * math.sin(a)), (0.055 * math.cos(a), 0.022, 0.055 * math.sin(a)),
             0.006, segs=6, uv_m=8.0)
    lo.merge(lathe_m, rot_axis_to_x(), FL)
    FL = FL + np.array([0.0, 0.0, 0.0])

    arm = Model()  # pivot frame: inner pivot at origin, the arm out along +X
    ARM_L = 0.15
    for sz in (-1, 1):
        tube(arm, "Anodised", (0.0, 0.0, sz * 0.085), (ARM_L, 0.0, 0.0), 0.016, segs=10, uv_m=5.0)
        tube(arm, "Dark", (0.0, 0.0, sz * 0.10), (0.0, 0.0, sz * 0.07), 0.024, segs=12, uv_m=5.0)
    tube(arm, "Dark", (ARM_L, -0.02, 0.0), (ARM_L, 0.02, 0.0), 0.025, segs=12, uv_m=5.0)  # ball joint
    PIV = np.array([0.03, -0.26, 0.0])
    return up, lo, arm, FL, AX, PIV, ARM_L


# ── BALANCE GYRO ─────────────────────────────────────────────────────────────
def gyro():
    """A flywheel in a ribbed drum, axis along X, on a base plate. Returns
    body (fixed) and wheel (spins about X)."""
    b = Model()
    box(b, "Anodised", (0, -0.155, 0), (0.40, 0.03, 0.30), uv_m=3.0)
    for sx in (-1, 1):
        box(b, "Anodised", (sx * 0.12, -0.10, 0), (0.03, 0.09, 0.18), uv_m=4.0)   # cradle cheeks
    dr = Model()
    lathe(dr, "Paint2", [(0.13, -0.15), (0.15, -0.13), (0.15, 0.13), (0.13, 0.15)], segs=32, uv_m=2.0, smooth=True)
    for y in (-0.09, -0.03, 0.03, 0.09):
        flange(dr, "Metal", y - 0.006, y + 0.006, 0.15, 0.165, segs=32, uv_m=4.0)  # cooling ribs
    for sy in (-1, 1):
        disk(dr, "Metal", 0.13, sy * 0.15, segs=32, up=sy > 0, uv_m=3.0, r_in=0.06)
        bolt_ring(dr, "Metal", sy * 0.15, 0.10, 8, up=sy > 0)
    b.merge(dr, rot_axis_to_x(), (0, 0.02, 0))
    flat_decal(b, "Decal", "hazard", (0.0, 0.02, 0.1655), (1, 0, 0), (0, 1, 0), 0.20, 0.035)
    box(b, "Dark", (0.0, 0.05, -0.17), (0.08, 0.06, 0.04), uv_m=5.0)      # motor driver
    tube(b, "Dark", (0.04, 0.05, -0.19), (0.18, -0.13, -0.12), 0.008, segs=6)
    w = Model()
    for sy in (-1, 1):
        lathe(w, "Chrome", [(0.06, sy * 0.15), (0.05, sy * 0.175), (0.02, sy * 0.185)], segs=24, uv_m=4.0)
        for k in range(3):
            a = TAU * k / 3
            box(w, "Dark", (0.035 * math.cos(a), sy * 0.172, 0.035 * math.sin(a)), (0.02, 0.012, 0.02), uv_m=6.0)
    wm = Model()
    wm.merge(w, rot_axis_to_x(), (0, 0.02, 0))
    return b, wm


# ── BATTERY PACK (the "tank") ────────────────────────────────────────────────
def battery_pack():
    """A tank-shaped pack, 0.62 long (X), 0.30 high, 0.34 wide: a rounded
    painted shell over a cell box, with a filler-style terminal cap, side
    stencils and rubber knee pads. Stack nodes top and bottom, X forward."""
    m = Model()
    # the shell: a lathed capsule section about X, flattened by a scale
    sh = Model()
    prof = [(0.0, -0.31), (0.09, -0.30), (0.135, -0.27), (0.15, -0.20), (0.15, 0.18), (0.13, 0.26), (0.08, 0.30), (0.0, 0.31)]
    lathe(sh, "Paint", prof, segs=40, uv_m=2.0, smooth=True)
    M = np.diag([1.0, 1.0, 1.0])
    sh2 = Model()
    sh2.merge(sh, rot_axis_to_x())
    # flatten: 0.30 high, 0.34 wide from a 0.30 round section
    S = np.diag([1.0, 0.95, 1.13])
    m.merge(sh2, S, (0, 0.02, 0))
    box(m, "Dark", (0, -0.125, 0), (0.56, 0.05, 0.24), uv_m=3.0)               # cell tray
    tube(m, "Chrome", (0.08, 0.15, 0), (0.08, 0.19, 0), 0.045, segs=18, uv_m=6.0)  # terminal cap
    tube(m, "Dark", (0.08, 0.19, 0), (0.08, 0.20, 0), 0.03, segs=12, uv_m=6.0)
    for sz in (-1, 1):
        box(m, "Rubber", (-0.13, 0.02, sz * 0.165), (0.16, 0.12, 0.012), uv_m=4.0)   # knee pads
        flat_decal(m, "Decal", "hazard", (0.12, -0.02, sz * 0.171), (sz * 1.0, 0, 0), (0, 1, 0), 0.16, 0.03)
    return m


# ── MOTO SADDLE (a crew part) ────────────────────────────────────────────────
def loft(m, mat, stations, ring=20, p=2.6, uv_m=3.0, caps=(True, True)):
    """A soft body lofted along X through superellipse sections: stations are
    (x, half-width, y-bottom, y-top). Smooth normals, UVs in metres."""
    n = ring
    P, I = [], []
    for x, w, yb, yt in stations:
        ym, hh = (yb + yt) / 2, (yt - yb) / 2
        for k in range(n):
            a = TAU * k / n
            c, s = math.cos(a), math.sin(a)
            z = w * math.copysign(abs(c) ** (2 / p), c)
            y = ym + hh * math.copysign(abs(s) ** (2 / p), s)
            P.append((x, y, z))
    P = np.array(P, float)
    ns = len(stations)
    for j in range(ns - 1):
        for k in range(n):
            a0, a1 = j * n + k, j * n + (k + 1) % n
            b0, b1 = a0 + n, a1 + n
            I += [(a0, b0, b1), (a0, b1, a1)]
    # smooth normals from the faces (outward: away from each section's centre)
    N = np.zeros_like(P)
    for a, b, c in I:
        fn = np.cross(P[b] - P[a], P[c] - P[a])
        N[a] += fn; N[b] += fn; N[c] += fn
    for j, (x, w, yb, yt) in enumerate(stations):
        cen = np.array([x, (yb + yt) / 2, 0.0])
        for k in range(n):
            i = j * n + k
            if N[i] @ (P[i] - cen) < 0:
                N[i] = -N[i]
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    UV = np.stack([P[:, 2] * uv_m, P[:, 0] * uv_m + P[:, 1] * uv_m], 1)
    m.add(mat, P, N, UV, I)
    # flat end caps
    for j, sg in ((0, -1), (ns - 1, 1)):
        if not caps[0 if j == 0 else 1]:
            continue
        ring_p = P[j * n:(j + 1) * n]
        cen = ring_p.mean(0)
        cp = np.vstack([ring_p, cen])
        cn = np.tile([sg * 1.0, 0, 0], (n + 1, 1))
        cuv = np.stack([cp[:, 2] * uv_m, cp[:, 1] * uv_m], 1)
        m.add(mat, cp, cn, cuv, [(k, (k + 1) % n, n) for k in range(n)])


# The saddle is modelled about its own centre (mount cradle at y = −0.15);
# the PART's box is the Command Seat's height (1.30 m) from that cradle up:
# it holds the rider. That box matters: the crew is parked at the part's
# centre as a kinematic body 2 m tall, and parked as low as the saddle itself
# (0.15 m over the frame) it reached through the frame into the ground and
# shoved a parked bike off at 20 m/s (motoprobe, 2026-10-26).
SADDLE_HALF = (0.36, 0.65, 0.17)   # the part's box: the stack face is its bottom
SADDLE_LIFT = 0.50                 # the mesh sits this far below the box centre
SADDLE_SIT = (-0.12, 0.085)        # the cushion's dip (x, top y; mesh frame): where the rider sits
SADDLE_PEG = (0.10, -0.385, 0.215)  # footpeg centres (x, y, ±z; mesh frame): either side of the frame


def moto_saddle():
    """A motorcycle saddle and tank-tail shroud on a short subframe, X forward,
    +Y up, the box centred at the origin with its bottom face (the mount
    cradle) at y = −0.15. Footpeg hangers drop below the box either side of
    whatever it is stacked on (the frame rail or node block it bolts to)."""
    m = Model()
    hy = 0.15                      # the mount cradle is the mesh's y = −0.15 (the box's bottom, SADDLE_LIFT lower in the part)
    # the mount cradle: a bolted plate with gussets, the stack face
    box(m, "Dark", (0.0, -hy + 0.015, 0.0), (0.26, 0.03, 0.20), uv_m=4.0, bevel=0.008)
    for sx in (-0.09, 0.09):
        for sz in (-0.07, 0.07):
            tube(m, "Metal", (sx, -hy + 0.03, sz), (sx, -hy + 0.042, sz), 0.009, segs=6, uv_m=8.0)
    for sz in (-0.075, 0.075):
        box(m, "Anodised", (0.0, -hy + 0.06, sz), (0.20, 0.06, 0.012), uv_m=4.0)
    # the subframe: two rails from the shroud back under the tail, cross tubes
    RZ = 0.075
    rail = [(0.30, -0.075), (0.10, -0.085), (-0.12, -0.07), (-0.34, -0.025)]
    for sz in (-1, 1):
        for (x0, y0), (x1, y1) in zip(rail[:-1], rail[1:]):
            tube(m, "Anodised", (x0, y0, sz * RZ), (x1, y1, sz * RZ), 0.013, segs=10, uv_m=6.0)
        tube(m, "Anodised", (-0.06, -hy + 0.06, sz * RZ), (-0.12, -0.07, sz * RZ), 0.011, segs=8, uv_m=6.0)
        tube(m, "Anodised", (0.07, -hy + 0.06, sz * RZ), (0.10, -0.085, sz * RZ), 0.011, segs=8, uv_m=6.0)
    for x, y in ((0.28, -0.075), (-0.32, -0.03)):
        tube(m, "Anodised", (x, y, -RZ), (x, y, RZ), 0.011, segs=8, uv_m=6.0)
    # the seat pan (painted steel) and the cushion (black, deep in the middle)
    pan = [(-0.345, 0.095, -0.03, 0.035), (-0.30, 0.125, -0.04, 0.03), (-0.20, 0.15, -0.045, 0.02),
           (-0.08, 0.15, -0.05, 0.015), (0.04, 0.12, -0.055, 0.02), (0.13, 0.075, -0.06, 0.03)]
    loft(m, "Paint3", pan, ring=16, p=3.0)
    cush = [(-0.355, 0.07, 0.02, 0.085), (-0.335, 0.105, 0.015, 0.11), (-0.29, 0.13, 0.015, 0.118),
            (-0.22, 0.145, 0.012, 0.108), (-0.12, 0.15, 0.01, 0.085), (-0.03, 0.135, 0.012, 0.088),
            (0.05, 0.105, 0.015, 0.098), (0.12, 0.07, 0.02, 0.11), (0.15, 0.045, 0.03, 0.112)]
    loft(m, "Rubber", cush, ring=24, p=2.4, uv_m=4.0)
    # the passenger strap across the tail, and the piping round the pan
    for sz in (-1, 1):
        tube(m, "Dark", (-0.25, 0.02, sz * 0.152), (-0.25, 0.10, sz * 0.12), 0.006, segs=6, uv_m=8.0)
        tube(m, "Dark", (-0.25, 0.10, sz * 0.12), (-0.25, 0.122, 0.0), 0.006, segs=6, uv_m=8.0)
    # the tank-tail shroud: a painted shell rising from the saddle's nose, knee
    # recesses with rubber pads, a filler cap and a stencil
    shroud = [(0.10, 0.095, -0.05, 0.07), (0.15, 0.13, -0.065, 0.105), (0.22, 0.152, -0.075, 0.13),
              (0.30, 0.16, -0.075, 0.145), (0.345, 0.15, -0.07, 0.143), (0.36, 0.125, -0.06, 0.128)]
    loft(m, "Paint", shroud, ring=32, p=2.5, uv_m=2.0)
    for sz in (-1, 1):
        # knee pads, let into the shroud's flanks where the rider's knees grip
        box(m, "Rubber", (0.245, 0.03, sz * 0.154), (0.10, 0.08, 0.014), uv_m=4.0, bevel=0.008)
        flat_decal(m, "Decal", "hazard", (0.30, -0.035, sz * 0.157), (sz * 1.0, 0, 0), (0, 1, 0), 0.09, 0.02)
    tube(m, "Chrome", (0.27, 0.13, 0), (0.27, 0.155, 0), 0.035, segs=16, uv_m=6.0)
    tube(m, "Dark", (0.27, 0.155, 0), (0.27, 0.163, 0), 0.022, segs=12, uv_m=6.0)
    for k in range(6):
        a = TAU * k / 6
        tube(m, "Metal", (0.27 + 0.045 * math.cos(a), 0.138, 0.045 * math.sin(a)),
             (0.27 + 0.045 * math.cos(a), 0.146, 0.045 * math.sin(a)), 0.005, segs=6, uv_m=8.0)
    # the grab rail round the tail and an orange reflector under it
    gr = [(-0.18, -0.01), (-0.30, 0.0), (-0.355, 0.01)]
    for sz in (-1, 1):
        pts = [(x, y, sz * 0.15) for x, y in gr]
        for a_, b_ in zip(pts[:-1], pts[1:]):
            tube(m, "Chrome", a_, b_, 0.011, segs=8, uv_m=6.0)
        tube(m, "Chrome", (-0.355, 0.01, sz * 0.15), (-0.355, 0.01, sz * 0.06), 0.011, segs=8, uv_m=6.0)
        tube(m, "Dark", (-0.18, -0.01, sz * 0.15), (-0.16, -0.07, sz * RZ), 0.009, segs=6, uv_m=8.0)
    tube(m, "Chrome", (-0.355, 0.01, -0.06), (-0.355, 0.01, 0.06), 0.011, segs=8, uv_m=6.0)
    box(m, "PaintOrange", (-0.352, -0.035, 0.0), (0.012, 0.03, 0.09), uv_m=6.0)
    # footpeg hangers: plates from the rails down either side of the frame,
    # folding knurled pegs on pivots, heel guards
    px, py, pz = SADDLE_PEG
    for sz in (-1, 1):
        top = (px + 0.03, -0.083, sz * RZ)
        bot = (px, py + 0.02, sz * 0.15)
        d = np.subtract(bot, top)
        L = float(np.linalg.norm(d))
        mid = tuple(np.add(top, bot) / 2)
        # a flat plate lying in the plane of the drop
        ang = math.atan2(d[0], -d[1])
        roll = math.atan2(d[2], -d[1])
        M = rot_z(ang) @ rot_x(-roll)
        box(m, "Anodised", mid, (0.05, L, 0.012), M=M, uv_m=4.0)
        tube(m, "Metal", (px + 0.03, -0.083, sz * (RZ - 0.012)), (px + 0.03, -0.083, sz * (RZ + 0.012)), 0.012, segs=8, uv_m=8.0)
        box(m, "Dark", (px, py + 0.01, sz * 0.155), (0.045, 0.04, 0.03), uv_m=5.0, bevel=0.005)       # pivot block
        tube(m, "Metal", (px, py, sz * 0.165), (px, py, sz * 0.285), 0.013, segs=8, uv_m=10.0)        # the peg
        box(m, "Dark", (px, py + 0.012, sz * 0.228), (0.034, 0.008, 0.11), uv_m=8.0)                   # its cleat
        for k in range(4):
            box(m, "Metal", (px, py + 0.019, sz * (0.186 + 0.028 * k)), (0.036, 0.006, 0.006), uv_m=10.0)
        box(m, "Anodised", (px - 0.045, py + 0.07, sz * 0.158), (0.06, 0.09, 0.006), uv_m=4.0)         # heel guard
    return m


# ── writing ──────────────────────────────────────────────────────────────────
def bounds_of(*models):
    mn = np.array([1e9] * 3); mx = -mn
    for m in models:
        a, b = m.bounds()
        mn, mx = np.minimum(mn, a), np.maximum(mx, b)
    return mn, mx


def to_frame(m, M, t):
    out = Model()
    out.merge(m, M, t)
    return out


def r4(v):
    return tuple(round(float(x), 4) for x in v)


def empty(name, t, parent, rot=(0.0, 0.0, 0.0, 1.0)):
    tx, ty, tz = r4(t)
    return f"""    (
        name: "{name}",
        transform: (
            translation: ({tx}, {ty}, {tz}),
            rotation: {rot},
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
    ),
"""


def main():
    dry = "--dry" in sys.argv
    os.makedirs(G.MODELS, exist_ok=True)
    frames = {}

    def mesh(key, model):
        model, c = G.recenter(model)
        G.write_glb(model, os.path.join(G.MODELS, key + ".glb"))
        mn, mx = model.bounds()
        print(f"{key:16s} size {np.round(mx - mn, 3)} offset {np.round(c, 3)} tris {model.tris()}")
        return model, c

    # MOTO WHEEL ----------------------------------------------------------------
    wheel, axle = moto_wheel()
    mn, mx = bounds_of(wheel, axle)
    half = r4((mx - mn) / 2)
    wm, wc = mesh("wheel_b_tyre", wheel)
    am, ac = mesh("wheel_b_axle", axle)
    frames["wheelB"] = dict(half=half, hub=(0, 0, 0))
    if not dry:
        G.write_prefab("PartWheelB", "MOTO WHEEL — r 0.33 m spoked through-axle wheel, centred on its part (+X = the"
                       " axle). The Tyre child hides while the live tyre body rolls; the Axle's ends take parts"
                       " on both sides.", None, half, 0.05,
                       children=[("Tyre", "wheel_b_tyre", wm, wc), ("Axle", "wheel_b_axle", am, ac)])
        q = (0.0, -0.7071068, 0.0, 0.7071068)
        body = f"""// LIVE TYRE B (the Moto Wheel) — spawned by vessel_controller in flight and hung
// from the chassis on a wheel joint. Written by tools/gen_auto_parts.py.
[
    (
        name: "WheelTyreB",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
{G.rb_ron((MOTO_R, MOTO_R, MOTO_R), 0.03, kinematic=True, sphere=MOTO_R, friction=1.0, rotates=True)}    ),
{G.prefab_node("TyreMesh", "wheel_b_tyre", wm, (0, 0, 0), 0, q)}]
"""
        open(os.path.join(G.PREFABS, "WheelTyreB.prefab.ron"), "w").write(body)

    # FORK ------------------------------------------------------------------------
    head, upper, lower, HUBr, X_FACE = fork()
    rk = math.radians(RAKE)
    R = rot_z(rk)                          # rake frame -> design frame
    up_d, lo_d = to_frame(upper, R, (0, 0, 0)), to_frame(lower, R, (0, 0, 0))
    mn, mx = bounds_of(head, up_d, lo_d)
    mn[0] = X_FACE                          # the box starts at the mount face
    C = (mn + mx) / 2
    half = r4((mx - mn) / 2)
    Q = -C                                  # the steering axis point, root frame
    hub = R @ HUBr - C
    hm, hc = mesh("fork_head", shifted(head, -C))
    um, uc = mesh("fork_upper", upper)      # rake frame, under ForkSteer
    lm, lc = mesh("fork_lower", lower)      # rake frame, under ForkSlide
    axis = (-math.sin(rk), math.cos(rk), 0.0)
    frames["forkT"] = dict(half=half, hub=r4(hub), axis=r4(axis), pivot=r4(Q), rake=RAKE)
    if not dry:
        G.write_prefab("PartForkT", f"TELESCOPIC FORK — on a front face (+X forward); steering axis raked {RAKE:g}° through"
                       " ForkRake; ForkSteer turns with the steering, ForkSlide rides the suspension.",
                       None, half, 0.03,
                       children=[("ForkHead", "fork_head", hm, hc)],
                       tail_nodes=empty("ForkRake", Q, 0, quat_z(RAKE)) + empty("ForkSteer", (0, 0, 0), 2)
                       + G.prefab_node("ForkUpper", "fork_upper", um, uc, 3) + empty("ForkSlide", (0, 0, 0), 3)
                       + G.prefab_node("ForkLower", "fork_lower", lm, lc, 5))

    # SWING ARM -----------------------------------------------------------------------
    mount, arm, HUB, PIV = swing_arm()
    mn, mx = bounds_of(mount, arm)
    mn[0] = 0.0
    C = (mn + mx) / 2
    half = r4((mx - mn) / 2)
    mm, mc = mesh("swingarm_mount", shifted(mount, -C))
    am2, ac2 = mesh("swingarm_arm", shifted(arm, -PIV))
    frames["swingArm"] = dict(half=half, hub=r4(HUB - C), pivot=r4(PIV - C), len=round(float(np.linalg.norm(HUB - PIV)), 4))
    if not dry:
        G.write_prefab("PartSwingArm", "SWING ARM — on a rear face (+X back); the Arm turns about ArmPivot (local Z)"
                       " with the rear wheel's suspension.", None, half, 0.025,
                       children=[("ArmMount", "swingarm_mount", mm, mc)],
                       tail_nodes=empty("ArmPivot", PIV - C, 0) + G.prefab_node("Arm", "swingarm_arm", am2, ac2, 2))

    # STRUT -----------------------------------------------------------------------------
    up, lo, sarm, FL, AX, SPIV, ARM_L = strut()
    sarm_d = to_frame(sarm, None, SPIV)
    mn, mx = bounds_of(up, lo, sarm_d)
    mn[0] = 0.0
    C = (mn + mx) / 2
    half = r4((mx - mn) / 2)
    sm, sc = mesh("strut_upper", shifted(up, -C))
    slide0 = np.array([AX, 0.0, 0.0]) - C
    lm2, lc2 = mesh("strut_lower", shifted(lo, -np.array([AX, 0.0, 0.0])))
    am3, ac3 = mesh("strut_arm", sarm)
    frames["strutS"] = dict(half=half, flange=r4(FL - C), axis_x=round(float(AX - C[0]), 4), pivot=r4(SPIV - C), arm=ARM_L)
    if not dry:
        G.write_prefab("PartStrutS", "COIL-OVER STRUT — on a flank (+X out); a wheel bolts to the hub flange at +X. The"
                       " StrutSlide (knuckle, rod, flange) rides the suspension and steers about the strut's axis;"
                       " the wishbone turns about ArmPivot.", None, half, 0.04,
                       children=[("StrutUpper", "strut_upper", sm, sc)],
                       tail_nodes=empty("StrutSlide", slide0, 0) + G.prefab_node("StrutLower", "strut_lower", lm2, lc2, 2)
                       + empty("ArmPivot", SPIV - C, 0) + G.prefab_node("StrutArm", "strut_arm", am3, ac3, 4))

    # GYRO ------------------------------------------------------------------------------
    gb, gw = gyro()
    mn, mx = bounds_of(gb, gw)
    C = (mn + mx) / 2
    half = r4((mx - mn) / 2)
    bm, bc = mesh("gyro_body", shifted(gb, -C))
    fm, fc = mesh("gyro_wheel", shifted(gw, -C))
    frames["gyro"] = dict(half=half)
    if not dry:
        G.write_prefab("PartGyro", "BALANCE GYRO — a flywheel (axis X) that holds a two-wheeler upright and leans it"
                       " into turns; the Flywheel caps spin while it works.", None, half, 0.06,
                       children=[("GyroBody", "gyro_body", bm, bc), ("Flywheel", "gyro_wheel", fm, fc)])

    # BATTERY PACK ------------------------------------------------------------------------
    bp = battery_pack()
    mn, mx = bp.bounds()
    C = (mn + mx) / 2
    half = r4((mx - mn) / 2)
    pm, pc = mesh("battery_pack", shifted(bp, -C))
    frames["packB"] = dict(half=half)
    if not dry:
        G.write_prefab("PartPackB", "BATTERY PACK — a tank-shaped 200 EC pack for bikes and small rovers; X forward.",
                       ("battery_pack", pm), half, 0.04)

    # MOTO SADDLE ---------------------------------------------------------------------------
    sd = moto_saddle()
    sm2, sc2 = mesh("moto_saddle", sd)
    half = SADDLE_HALF
    frames["saddle"] = dict(half=half, sit=SADDLE_SIT, peg=SADDLE_PEG, mesh_bounds=r4(sd.bounds()[0]) + r4(sd.bounds()[1]))
    if not dry:
        G.write_prefab("PartSaddle", "MOTO SADDLE — a crew part: a motorcycle saddle and tank-tail shroud on a short"
                       " subframe, X forward; stacks by its bottom (the mount cradle) and its footpegs hang either"
                       " side of the frame below. scripts/command_seat.lua seats the rider astride it (the params).",
                       None, half, 0.03, children=[("Saddle", "moto_saddle", sm2, sc2 + np.array([0.0, -SADDLE_LIFT, 0.0]))])
        # the rider's pose (command_seat.lua): astride, leaning forward, feet on
        # the pegs, hands on a fork's grips (ForkSteer frame, the fork() bar)
        sx, sy = SADDLE_SIT
        px, py, pz = SADDLE_PEG
        pose = [("model_yaw", 3.14159265), ("sit_forward", sx), ("sit_up", round(sy + 0.15 - SADDLE_LIFT, 4)), ("lean_fwd", 0.26),
                ("foot_out", px + 0.01), ("foot_down", round(-py - 0.035 + SADDLE_LIFT, 4)), ("foot_side", pz + 0.005),
                ("knee_out", 0.45),
                ("hand_out", 0.62), ("hand_up", round(0.34 - SADDLE_LIFT, 4)), ("hand_side", 0.30), ("hand_lift", 0.0),
                ("grips", 1.0), ("grip_x", -0.0835), ("grip_y", 0.303), ("grip_z", 0.3125)]
        prm = "".join(f'                        ("{k}", {float(v)}),\n' for k, v in pose)
        scr = ('scripts: [\n                (\n                    kind: "command_seat",\n                    enabled: true,\n'
               '                    params: [\n' + prm +
               '                    ],\n                ),\n            ],')
        fp = os.path.join(G.PREFABS, "PartSaddle.prefab.ron")
        src = open(fp).read()
        src = src.replace("scripts: [],", scr, 1)
        open(fp, "w").write(src)

    for k, v in frames.items():
        print("FRAME", k, v)
    if not dry:
        os.makedirs(G.VIS_DIR, exist_ok=True)
        for prefab in ("PartWheelB", "PartForkT", "PartSwingArm", "PartStrutS", "PartGyro", "PartPackB", "PartSaddle"):
            src = open(os.path.join(G.PREFABS, prefab + ".prefab.ron")).read()
            vis = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
            head_ = ("// VISUAL-ONLY variant of prefabs/" + prefab + ".prefab.ron for the builder stand: no body,"
                     " no scripts.\n// Written by tools/gen_auto_parts.py — regenerate, don't edit.\n")
            open(os.path.join(G.VIS_DIR, prefab + ".prefab.ron"), "w").write(head_ + vis)


if __name__ == "__main__":
    main()
