#!/usr/bin/env python3
"""Generate the BASE section's placeable parts (deep-space addendum K3, step 4)
and the Build Kit the Engineer carries (K1).

    python3 tools/gen_base_parts.py          # models/base/parts/*.glb, items, prefabs
    python3 tools/gen_base_parts.py --dry    # sizes, seats, box centres

Every part is built 1:1 in a GROUND frame (ground y = 0, front +Z, the
footprint centred on x = z = 0) in metres, from the same primitives and PBR
sets as the spaceport (tools/base_models.py, textures/base: concrete,
cladding, steel; all CC0 or procedural, see tools/base_tex.py).

WITH ITS FUTURE INTERIOR (E's direction for steps 4-8). The engine's
interiors Stage 1 (EN1: rb.subShape and rb.shell) should be a flag change,
not a rebuild, so each module is already split the way that stage reads it:

  flat modules   (the Equipment Shed) carry their walls, floor, roof and door
                 as named collider boxes, "Wall N" children: each becomes one
                 rb.subShape of the module's body when Stage 1 lands. The
                 door is closed today (no one walks inside placed modules
                 before EN1/EN2: no kinematic interior fakes).
  curved modules (the Surface Hab) carry their pressure hull as ONE child mesh
                 named "Shell" (models/base/parts/hab_shell.glb, a real
                 0.1 m-thick wall, inner face included) that becomes the
                 rb.shell; today it is closed off by an octagon of four
                 collider boxes round its axis.
  both           carry their fit-out as a child mesh named "Interior" (the
                 racks, the bench, the bunks, the floor deck), modelled now.

The engine recentres every model on its bounding box, so a prefab's origin is
its root model's box centre: `seat` (printed, copied into
scripts/parts_base.lua PARTS[id].seat) is how far that origin sits above the
ground; child nodes stand at their own box centre minus the root's.

Masses and sizes are the real things': a 4 x 4 m precast slab 0.30 m thick
(11.5 t of reinforced concrete); a 3.0 x 2.4 x 2.6 m steel equipment shelter
on skids, the size of a 10 ft ISO container (1.6 t fitted out); a 4 m x 6 m
surface habitat can on two saddles (7.5 t, about an ISS node's dry mass).
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT, PREFABS, box, disk, lathe, rot_x, rot_z, tube  # noqa: E402
from base_models import (CModel, CONC, CONC_DARK, CONT_BLUE, DARK, GREY, LIGHT, PAINT, RUBBER, SAFETY, Shell,  # noqa: E402
                         SLATE, WARM, LAMP_WARM, LAMP_COOL, zcheck, lattice_column, dish, yagi, railing, obstruction, quat_x, quat_from_basis)
import gen_base  # noqa: E402

MODELS = os.path.join(ROOT, "models", "base", "parts")
ITEMS = os.path.join(ROOT, "models", "items")
TAU = 2 * math.pi
UVM = {"Concrete": 0.25, "Clad": 0.5, "Steel": 1.0, "Glass": 1.0, "Lamp": 2.5, "Rubber": 4.0, "Dark": 4.0}


def bx(m, mat, col, c, s, sh=None, M=None):
    """A box by centre and size in the ground frame (no automatic footing)."""
    m.color = col
    box(m, mat, c, s, M=M, uv_m=UVM.get(mat, 1.0))
    if sh is not None:
        sh.add(c, s)


def tb(m, mat, col, p0, p1, r, segs=10):
    m.color = col
    tube(m, mat, p0, p1, r, segs=segs, uv_m=UVM.get(mat, 1.0))


# ── PAD PLATE ────────────────────────────────────────────────────────────────
# A 4 x 4 m precast reinforced-concrete slab, 0.30 m thick, set with its top
# 0.20 m proud of the ground (the rest is its footing: on a slight slope the
# skirt stays in the ground instead of showing daylight under a corner; real
# foundations and grading come with step 5's K5). A galvanised steel edge
# angle round the top, two cast-in tie-down rails, four lifting anchors and
# faded safety-yellow corner marks.

def pad_plate():
    m = CModel(seed=41)
    sh = Shell()
    H, T, F = 4.0, 0.20, 0.40       # side, top above ground, footing below
    bx(m, "Concrete", CONC, (0, (T - F) / 2, 0), (H, T + F, H), sh=sh)
    e = 0.07
    for s in (-1, 1):
        # the edge angle: a strip on the top face's rim and down the side
        bx(m, "Steel", GREY, (0, T + 0.006, s * (H / 2 - e / 2)), (H, 0.012, e))
        bx(m, "Steel", GREY, (s * (H / 2 - e / 2), T + 0.006, 0), (e, 0.012, H - 2 * e))
        bx(m, "Steel", GREY, (0, T - 0.05, s * (H / 2 + 0.006)), (H + 0.024, 0.10, 0.012))
        bx(m, "Steel", GREY, (s * (H / 2 + 0.006), T - 0.05, 0), (0.012, 0.10, H))
        # tie-down rails (a C-channel cast flush, its lips just proud)
        bx(m, "Steel", DARK, (s * 1.0, T + 0.004, 0), (0.12, 0.008, H - 0.5))
        bx(m, "Steel", SLATE, (s * 1.0, T + 0.009, 0), (0.05, 0.004, H - 0.6))
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx, cz = sx * 1.55, sz * 1.55
            # a lifting anchor: a recessed plate and its forged ring
            bx(m, "Steel", DARK, (cx, T + 0.003, cz), (0.16, 0.006, 0.16))
            m.color = GREY
            ring = CModel(seed=1)
            ring.ground = False
            lathe(ring, "Steel", [(0.045, 0.0), (0.06, 0.012), (0.045, 0.024), (0.03, 0.012), (0.045, 0.0)], segs=12)
            m.merge(ring, M=rot_z(math.pi / 2), t=(cx, T + 0.045, cz))
            # the corner marks
            bx(m, "Steel", SAFETY, (sx * 1.82, T + 0.016, sz * 1.65), (0.16, 0.004, 0.5))
            bx(m, "Steel", SAFETY, (sx * 1.65, T + 0.021, sz * 1.81), (0.48, 0.004, 0.155))
    return m, sh


# ── EQUIPMENT SHED ───────────────────────────────────────────────────────────
# A 3.0 (w, x) x 2.4 (d, z) x 2.6 m (h) steel equipment shelter on two skids:
# corrugated walls (the cladding set), square corner posts, a steel roof with
# a drip edge, a closed personnel door on the front (+Z), louvred vents, a
# conduit entry. Its fit-out (racks along the back, a bench on the left, the
# floor deck) is the "Interior" child, sealed in until interiors Stage 1.

SHED = dict(w=3.0, d=2.4, h=2.6, skid=0.15, wall=0.05)


def shed_shell():
    m = CModel(seed=52)
    sh = Shell()
    w, d, h, k, t = SHED["w"], SHED["d"], SHED["h"], SHED["skid"], SHED["wall"]
    y0 = k + 0.05                     # top of the floor frame
    y1 = h - 0.06                     # underside of the roof
    # skids and the floor frame
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, k / 2, s * 0.85), (w + 0.2, k, 0.12))
    bx(m, "Steel", SLATE, (0, k + 0.025, 0), (w - 0.03, 0.05, d - 0.03), sh=sh)
    # the walls: back, two ends, the front either side of the door and its lintel
    door_w, door_h = 0.92, 2.05
    col = CONT_BLUE
    bx(m, "Clad", col, (0, (y0 + y1) / 2, -(d / 2 - t / 2)), (w - 0.24, y1 - y0, t), sh=sh)
    for s in (-1, 1):
        bx(m, "Clad", col, (s * (w / 2 - t / 2), (y0 + y1) / 2, 0), (t, y1 - y0, d - 0.24), sh=sh)
    fw = (w - 0.24 - door_w) / 2
    for s in (-1, 1):
        bx(m, "Clad", col, (s * (door_w / 2 + fw / 2), (y0 + y1) / 2, d / 2 - t / 2), (fw, y1 - y0, t), sh=sh)
    bx(m, "Clad", col, (0, (y0 + door_h + y1) / 2, d / 2 - t / 2), (door_w, y1 - y0 - door_h, t), sh=sh)
    # the doorway (sandbox S1: the door is a sliding leaf on an outside track,
    # the "Door" child scripts/kit_live.lua slides open): its frame and the
    # track it hangs from, running over the right-hand panel it slides across
    for s in (-1, 1):
        bx(m, "Steel", DARK, (s * (door_w / 2 + 0.035), y0 + door_h / 2 + 0.03, d / 2 + 0.02), (0.06, door_h + 0.06, 0.03))
    bx(m, "Steel", DARK, (0, y0 + door_h + 0.035, d / 2 + 0.021), (door_w + 0.14, 0.06, 0.032))
    bx(m, "Steel", GREY, (0.48, y0 + door_h + 0.085, d / 2 + 0.075), (1.95, 0.05, 0.05))
    for x in (-0.48, 0.48, 1.42):
        bx(m, "Steel", DARK, (x, y0 + door_h + 0.085, d / 2 + 0.045), (0.05, 0.08, 0.04))
    # a threshold plate and a stop
    bx(m, "Steel", GREY, (0, y0 + 0.004, d / 2 - 0.02), (door_w, 0.008, 0.10))
    bx(m, "Rubber", RUBBER, (1.43, y0 + 0.5, d / 2 + 0.06), (0.04, 0.12, 0.05))
    # the interior's solids: the back racks and the bench walk-round (their
    # look is the Interior child; the floor is the frame's box above)
    sh.add((0, y0 + 0.95, -0.75), (2.6, 1.9, 0.5))
    sh.add((-1.15, y0 + 0.47, 0.35), (0.6, 0.94, 1.3))
    # corner posts, the roof and its drip edge
    for sx in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Steel", GREY, (sx * (w / 2 - 0.06), (y0 + h - 0.06) / 2, sz * (d / 2 - 0.06)), (0.12, h - 0.06 - y0, 0.12))
    bx(m, "Steel", GREY, (0, h - 0.03, 0), (w + 0.08, 0.06, d + 0.08), sh=sh)
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, h - 0.07, s * (d / 2 + 0.05)), (w + 0.1, 0.04, 0.02))
    # vents on the ends, a lamp over the door, a conduit entry on the back
    for s in (-1, 1):
        for i in range(5):
            bx(m, "Steel", DARK, (s * (w / 2 + 0.012), 1.75 + i * 0.07, 0.35), (0.024, 0.035, 0.5))
        bx(m, "Steel", GREY, (s * (w / 2 + 0.006), 1.89, 0.35), (0.012, 0.42, 0.58))
    bx(m, "Steel", DARK, (0, y0 + door_h + 0.16, d / 2 + 0.06), (0.22, 0.10, 0.10))
    bx(m, "Lamp", LAMP_WARM, (0, y0 + door_h + 0.11, d / 2 + 0.06), (0.16, 0.012, 0.06))
    tb(m, "Steel", GREY, (0.9, 0.35, -d / 2 - 0.05), (0.9, 2.3, -d / 2 - 0.05), 0.03)
    bx(m, "Steel", DARK, (0.9, 2.3, -d / 2 - 0.08), (0.18, 0.18, 0.12))
    return m, sh


def shed_interior():
    m = CModel(seed=53)
    m.ground = False
    w, d, h, k = SHED["w"], SHED["d"], SHED["h"], SHED["skid"]
    y0 = k + 0.05
    # the floor deck (tread plate over the frame) and a strip light
    bx(m, "Steel", GREY, (0, y0 + 0.012, 0), (w - 0.12, 0.02, d - 0.12))
    bx(m, "Lamp", LAMP_WARM, (0, h - 0.10, 0), (1.2, 0.03, 0.08))
    # racks along the back wall: four uprights, three shelves, a few crates
    for x in (-1.2, -0.35, 0.35, 1.2):
        bx(m, "Steel", SAFETY, (x, y0 + 0.022 + 0.95, -0.95), (0.05, 1.9, 0.05))
        bx(m, "Steel", SAFETY, (x, y0 + 0.022 + 0.95, -0.55), (0.05, 1.9, 0.05))
    for y in (0.35, 1.0, 1.65):
        bx(m, "Steel", GREY, (0, y0 + y, -0.75), (2.5, 0.03, 0.46))
    for (x, y, s) in ((-0.9, 0.35, 0.36), (-0.4, 0.35, 0.30), (0.6, 1.0, 0.40), (0.95, 1.65, 0.28), (-0.7, 1.65, 0.34)):
        bx(m, "Clad", WARM, (x, y0 + y + 0.015 + s / 2, -0.75), (s * 1.3, s, s))
    # a workbench at the left end with a vice
    bx(m, "Steel", DARK, (-1.15, y0 + 0.9, 0.35), (0.6, 0.05, 1.3))
    for z in (-0.25, 0.95):
        bx(m, "Steel", DARK, (-1.15, y0 + 0.45, z), (0.5, 0.9, 0.04))
    bx(m, "Steel", SLATE, (-1.15, y0 + 0.99, 0.8), (0.14, 0.12, 0.10))
    return m


def shed_door():
    """The shed's personnel door: a steel leaf hung from the track outside
    the front wall, built about its own centre; (model, its colliders,
    where it hangs closed in the ground frame)."""
    m = CModel(seed=54)
    m.ground = False
    sh = Shell()
    w, h, t = 0.98, 2.07, 0.04
    bx(m, "Steel", SLATE, (0, 0, 0), (w, h, t))
    sh.add((0, 0, 0), (w, h, t))
    # stiffeners, a kick plate, the pull handles, the hangers at its head
    for y in (-0.6, 0.15, 0.8):
        bx(m, "Steel", DARK, (0, y, t / 2 + 0.006), (w - 0.1, 0.05, 0.012))
    bx(m, "Steel", DARK, (0, -h / 2 + 0.14, t / 2 + 0.004), (w - 0.06, 0.24, 0.008))
    for s in (-1, 1):
        tb(m, "Steel", LIGHT, (-w / 2 + 0.1, -0.05, s * (t / 2 + 0.05)), (-w / 2 + 0.1, 0.25, s * (t / 2 + 0.05)), 0.012, segs=8)
        for y in (-0.05, 0.25):
            tb(m, "Steel", LIGHT, (-w / 2 + 0.1, y, s * t / 2), (-w / 2 + 0.1, y, s * (t / 2 + 0.05)), 0.01, segs=6)
    for x in (-0.32, 0.32):
        bx(m, "Steel", DARK, (x, h / 2 + 0.03, 0.02), (0.06, 0.08, 0.02))
    S = SHED
    at = (0.0, S["skid"] + 0.05 + h / 2 + 0.005, S["d"] / 2 + 0.05)
    return m, sh, at


# ── SURFACE HAB ──────────────────────────────────────────────────────────────
# A 4.0 m-diameter, 6.0 m-long pressure can lying along X on two steel
# saddles, its shallow end domes, a hatch with a closed door on the front
# (+Z), two portholes, handrails, lamps. The hull is the "Shell" child: the
# outer skin, the inner face and both domes, 0.10 m thick.

HAB = dict(r=2.0, L=6.0, cy=2.35, wall=0.10, dome=0.45)


def hab_frame():
    m = CModel(seed=61)
    sh = Shell()
    r, L, cy = HAB["r"], HAB["L"], HAB["cy"]
    bot = cy - r
    for x in (-1.9, 1.9):
        # a saddle: a base beam, two raked legs, a curved cradle (3 flats)
        bx(m, "Steel", DARK, (x, 0.08, 0), (0.3, 0.16, 3.2), sh=sh)
        for s in (-1, 1):
            tb(m, "Steel", GREY, (x, 0.16, s * 1.45), (x, bot + 0.55, s * 1.25), 0.07)
        for a in (-0.55, 0.0, 0.55):
            c, sn = math.cos(a), math.sin(a)
            p = (x, cy - (r + 0.06) * c, (r + 0.06) * sn)
            Mr = np.array([[1, 0, 0], [0, c, sn], [0, -sn, c]])
            bx(m, "Steel", GREY, p, (0.26, 0.10, 1.05), M=Mr)
        bx(m, "Steel", SAFETY, (x, 0.165, 1.62), (0.3, 0.01, 0.04))
    # THE ENTRY (sandbox S1): a rectangular door collar through the hull on
    # the front (+Z), its sliding hatch the "Door" child (kit_live), a landing
    # and six steps down along -X, a handrail. The hull is cut to the collar
    # (hab_shell's HATCH cells).
    fy = cy - r + 0.75
    sill = fy + 0.03
    top = cy + 0.77
    z0, z1 = 1.42, 2.13
    hz = r + 0.02
    for s in (-1, 1):
        bx(m, "Steel", GREY, (s * 0.61, (sill + top) / 2, (z0 + z1) / 2), (0.12, top - sill, z1 - z0), sh=sh)
    bx(m, "Steel", GREY, (0, top + 0.06, (z0 + z1) / 2), (1.34, 0.12, z1 - z0), sh=sh)
    bx(m, "Steel", GREY, (0, sill - 0.04, (z0 + z1) / 2), (1.34, 0.08, z1 - z0), sh=sh)
    for k in range(9):
        y = sill + k * 0.22
        if k % 2 == 0:
            for s in (-1, 1):
                bx(m, "Steel", SAFETY, (s * 0.61, min(top, y + 0.11), z1 + 0.003), (0.12, min(0.22, top - y), 0.006))
    # the landing and the steps (their colliders are the treads)
    lz0, lz1 = z1 + 0.02, z1 + 0.82
    lc = (lz0 + lz1) / 2
    # the landing: a deck on a closed steel skirt (its collider reaches into
    # the ground, so nobody walks under it where the ground falls away)
    bx(m, "Steel", DARK, (0, sill - 0.04, lc), (1.5, 0.08, lz1 - lz0))
    for s in (-1, 1):
        bx(m, "Steel", GREY, (s * 0.74, (sill - 0.08 - 0.3) / 2, lc), (0.02, sill - 0.08 + 0.3, lz1 - lz0 - 0.04))
    sh.add((0, (sill - 0.3) / 2, lc), (1.5, sill + 0.3, lz1 - lz0))
    # six closed steps straight out from the landing, away from the hull
    # (alongside it the hull's curve overhung the crew's shoulders)
    n, tr, sw = 6, 0.28, 1.1
    for k in range(n):
        ty = (n - k) * sill / (n + 1)            # k = 0 is the top step, by the landing
        za = lz1 + k * tr
        bx(m, "Steel", (0.50, 0.51, 0.52), (0, ty - 0.02, za + tr / 2), (sw, 0.04, tr))
        bx(m, "Steel", SAFETY, (0, ty + 0.002, za + tr - 0.03), (sw - 0.04, 0.004, 0.04))
        bx(m, "Steel", DARK, (0, (ty - 0.04 - 0.3) / 2, za + tr - 0.005), (sw - 0.02, ty - 0.04 + 0.3, 0.01))
    zend = lz1 + n * tr
    # its collider is a RAMP along the nosings, as the spaceport's stairs are:
    # the walker climbs a slope, not a stack of boxes (it stalled on a riser)
    run_, rise_ = zend - lz1 + 0.15, sill
    L_ = math.hypot(run_, rise_)
    a_ = math.atan2(rise_, run_)
    ca, sa = math.cos(a_), math.sin(a_)
    Mr = np.array([[1, 0, 0], [0, ca, -sa], [0, sa, ca]])     # rising toward -Z
    mid = np.array([0.0, rise_ / 2, lz1 + run_ / 2])
    upn = Mr @ np.array([0.0, 1.0, 0.0])
    sh.add(tuple(mid - upn * 0.06), (sw, 0.12, L_ + 0.1), quat_from_basis(Mr))
    # the stringer plates either side, cut to the flight's line, and the rails
    for sx in (-1, 1):
        xx = sx * (sw / 2 + 0.01)
        sub_ = CModel(seed=66)
        sub_.ground = False
        pts = [(lz1, -0.3), (zend, -0.3), (zend, 0.12), (lz1, sill - 0.02)]
        P_, N_, UV_, I_ = [], [], [], []
        for (ox, nx) in ((xx + 0.006, 1.0), (xx - 0.006, -1.0)):
            b0 = len(P_)
            for (z_, y_) in pts:
                P_.append((ox, y_, z_)); N_.append((nx, 0, 0)); UV_.append((z_, y_))
            I_ += [(b0, b0 + 1, b0 + 2), (b0, b0 + 2, b0 + 3)]
        sub_.color = GREY
        sub_.add("Steel", P_, N_, UV_, I_)
        m.merge(sub_)
        tb(m, "Steel", SAFETY, (sx * 0.6, 1.16, zend - 0.05), (sx * 0.6, sill + 1.0, lz1), 0.022, segs=6)
        tb(m, "Steel", SAFETY, (sx * 0.6, sill + 1.0, lz1), (sx * 0.75, sill + 1.0, lz0 + 0.05), 0.022, segs=6)
        for (xp, zp, yb, yt) in ((0.6, zend - 0.05, 0.16, 1.16), (0.6, lz1, sill, sill + 1.0), (0.75, lz0 + 0.05, sill, sill + 1.0)):
            tb(m, "Steel", SAFETY, (sx * xp, yb, zp), (sx * xp, yt, zp), 0.02, segs=6)
        sh.add((sx * 0.64, (sill + 1.0) / 2 + 0.2, (lz0 + zend) / 2), (0.06, sill + 1.0, zend - lz0))
    # handrails along the top and lamps either side of the hatch
    for s in (-1, 1):
        for x in (-2.2, -0.8, 0.8, 2.2):
            tb(m, "Steel", SAFETY, (x, cy + r * 0.86 + 0.0, s * r * 0.50), (x, cy + r * 0.86 + 0.12, s * r * 0.53), 0.015, segs=6)
        tb(m, "Steel", SAFETY, (-2.3, cy + r * 0.86 + 0.12, s * r * 0.53), (2.3, cy + r * 0.86 + 0.12, s * r * 0.53), 0.018, segs=6)
        bx(m, "Steel", DARK, (s * 0.9, cy + 0.85, hz - 0.15), (0.18, 0.12, 0.12))
        bx(m, "Lamp", LAMP_WARM, (s * 0.9, cy + 0.786, hz - 0.15), (0.12, 0.012, 0.08))
    # THE HULL AS A HOLLOW (sandbox S1: walkable inside, static boxes on the
    # planet as the Lab's are): 16 thin boxes round the axis (the front ones
    # broken at the door collar), the end walls inside the domes, the deck,
    # the racks and the bunks.
    nseg = 16
    t = HAB["wall"]
    for k in range(nseg):
        a = (k + 0.5) * 2 * math.pi / nseg       # from +Y about +X, toward +Z
        c, s = math.cos(a), math.sin(a)
        rr = r - t / 2
        yc, zc = cy + rr * c, rr * s
        w = 2 * r * math.sin(math.pi / nseg) * 1.08
        q = (math.sin(a / 2), 0.0, 0.0, math.cos(a / 2))
        front = zc > 0.9 and (yc - cy) > -1.4 and (yc - cy) < 0.9
        if front:
            for (xa, xb) in ((-L / 2, -0.67), (0.67, L / 2)):
                sh.add(((xa + xb) / 2, yc, zc), (xb - xa, t + 0.04, w), q)
        else:
            sh.add((0, yc, zc), (L, t + 0.04, w), q)
    for s in (-1, 1):
        sh.add((s * (L / 2 + 0.12), cy, 0), (0.12, 2 * r, 2 * r))
    half = math.sqrt(r * r - (fy - cy) ** 2) - 0.12
    sh.add((0, fy - 0.06, 0), (L - 0.1, 0.12, 2 * half))
    for s in (-1, 1):
        sh.add((-1.85, fy + 0.95, s * (half - 0.3)), (2.1, 1.8, 0.55))
    sh.add((2.0, fy + 0.7, -0.6), (1.9, 1.4, 0.85))
    return m, sh


def hab_door():
    """The hab's hatch: a pressure leaf that slides along the hull outside
    the collar (+X), with its porthole and dogs. (model, colliders, at)"""
    m = CModel(seed=65)
    m.ground = False
    sh = Shell()
    r, cy = HAB["r"], HAB["cy"]
    fy = cy - r + 0.75
    w, h, t = 1.16, cy + 0.80 - (fy + 0.03), 0.05
    bx(m, "Steel", (0.62, 0.60, 0.56), (0, 0, 0), (w, h, t))
    sh.add((0, 0, 0), (w, h, t))
    bx(m, "Steel", DARK, (0, 0, t / 2 + 0.01), (w - 0.12, h - 0.12, 0.02))
    bx(m, "Steel", (0.62, 0.60, 0.56), (0, 0, t / 2 + 0.02), (w - 0.2, h - 0.2, 0.02))
    m.color = GREY
    tube(m, "Steel", (0, 0.45, t / 2), (0, 0.45, t / 2 + 0.05), 0.15, segs=16, uv_m=1.0)
    m.color = (0.2, 0.24, 0.28)
    tube(m, "Glass", (0, 0.45, t / 2 + 0.05), (0, 0.45, t / 2 + 0.055), 0.11, segs=16, uv_m=1.0)
    for y in (-0.6, 0.0, 0.6):
        bx(m, "Steel", DARK, (-w / 2 + 0.08, y, t / 2 + 0.04), (0.08, 0.1, 0.03))
    tb(m, "Steel", LIGHT, (-w / 2 + 0.16, -0.1, t / 2 + 0.07), (-w / 2 + 0.16, 0.2, t / 2 + 0.07), 0.016, segs=8)
    for k in range(6):
        bx(m, "Steel", SAFETY if k % 2 == 0 else DARK, (w / 2 - 0.03, -h / 2 + (k + 0.5) * h / 6, t / 2 + 0.004), (0.05, h / 6, 0.008))
    at = (0.0, fy + 0.03 + h / 2, 2.13 + 0.035)
    return m, sh, at


def hab_shell():
    m = CModel(seed=62)
    m.ground = False
    r, L, cy, t, dz = HAB["r"], HAB["L"], HAB["cy"], HAB["wall"], HAB["dome"]
    sub = CModel(seed=63)
    sub.ground = False
    sub.color = PAINT
    # outer skin: the barrel and two shallow domes, revolved about +Y, then
    # laid along X. Profile (radius, along-axis).
    prof = [(0.35, -L / 2 - dz)]
    for i in range(1, 7):
        a = i / 6 * (math.pi / 2)
        prof.append((r * math.sin(a) * 0.999 + 0.0, -L / 2 - dz * math.cos(a)))
    # (the barrel in three bands: the middle one carries the door's cut, the
    # cells HATCH leaves open on the front — hab_frame's collar covers its edges)
    prof += [(r, -0.55), (r, 0.55), (r, L / 2)]
    for i in range(1, 7):
        a = (6 - i) / 6 * (math.pi / 2)
        prof.append((r * math.sin(a) * 0.999, L / 2 + dz * math.cos(a)))
    prof[-1] = (0.35, L / 2 + dz)
    hatch = lambda i, k: k == 7 and 7 <= i <= 14
    lathe(sub, "Clad", prof, segs=48, smooth=True, uv_m=0.5, skip=hatch)
    # the inner face, 0.10 m in (what the crew will see from inside)
    inner = [(max(rr - t, 0.25), y * (1 - t / (L / 2 + dz))) for (rr, y) in prof]
    sub.color = LIGHT
    lathe(sub, "Clad", inner, segs=48, smooth=True, uv_m=0.5, inward=True, skip=hatch)
    # the dome hubs (berthing rings, closed)
    sub.color = GREY
    for s in (-1, 1):
        y = s * (L / 2 + dz)
        disk(sub, "Steel", 0.35, y, segs=24, up=s > 0)
        lathe(sub, "Steel", [(0.42, y - s * 0.02), (0.42, y + s * 0.06), (0.30, y + s * 0.06)], segs=24)
    # weld seams / rings along the barrel
    for y in (-L / 2 + 0.02, -1.0, 1.0, L / 2 - 0.02):
        lathe(sub, "Steel", [(r + 0.012, y - 0.04), (r + 0.012, y + 0.04)], segs=48)
    # Y-axis can → X-axis can, centred at (0, cy, 0)
    M = rot_z(-math.pi / 2)
    m.merge(sub, M=M, t=(0, cy, 0))
    # portholes on the front either side of the hatch
    for x in (-1.6, 1.6):
        a = 0.25
        p = np.array([x, cy + r * math.sin(a), r * math.cos(a) + 0.01])
        m.color = GREY
        tube(m, "Steel", p - np.array([0, math.sin(a), math.cos(a)]) * 0.02,
             p + np.array([0, math.sin(a), math.cos(a)]) * 0.05, 0.22, segs=16)
        m.color = (0.2, 0.24, 0.28)
        tube(m, "Glass", p + np.array([0, math.sin(a), math.cos(a)]) * 0.05,
             p + np.array([0, math.sin(a), math.cos(a)]) * 0.055, 0.17, segs=16)
    return m


def hab_interior():
    m = CModel(seed=64)
    m.ground = False
    r, L, cy = HAB["r"], HAB["L"], HAB["cy"]
    fy = cy - r + 0.75              # the deck, 0.75 m over the hull's lowest point
    half = math.sqrt(r * r - (fy - cy) ** 2) - 0.12
    bx(m, "Steel", GREY, (0, fy, 0), (L - 0.2, 0.04, 2 * half))
    # racks either side (one with a galley block), two bunks at the far end
    for s in (-1, 1):
        bx(m, "Clad", LIGHT, (-1.85, fy + 0.95, s * (half - 0.3)), (2.1, 1.8, 0.55))
    bx(m, "Steel", SLATE, (-1.85, fy + 0.9, -(half - 0.6)), (0.9, 0.04, 0.05))
    for k, yy in enumerate((0.45, 1.25)):
        bx(m, "Clad", WARM, (2.0, fy + yy, -0.6), (1.9, 0.18, 0.85))
        bx(m, "Steel", DARK, (2.0, fy + yy + 0.12, -0.6), (1.9, 0.04, 0.05))
    bx(m, "Lamp", LAMP_WARM, (0, cy + r - 0.35, 0), (3.0, 0.03, 0.12))
    return m


# ── BUILD STAND (deep-space step 6, L1) ──────────────────────────────────────
# A craft stand: a 0.90 m square steel base plate, bolted down at its corners,
# with a short collar housing a telescoping column, and a 0.90 m square deck on
# top with four rubber pads the craft rests on. The deck and its column are
# ONE child node ("Deck") that slides along the base's up: the deck's height
# is a per-part field (scripts/craft_stand.lua), 0.5-4.0 m, and the stand
# lowers to STAND["low"] to let a wheeled craft down. The column is 3.9 m
# long, so at the top setting it is still in its collar and at the bottom it
# runs down into the ground through the collar (a real ground sleeve).
# Its deck is the Deck node's own collider (a child box of it: a script that
# moves the Deck moves it); 0.4 t of steel, like the addendum's.

STAND = dict(base=0.90, deck=0.90, plate=0.03, collar=0.13, col_r=0.10, col_len=3.90, low=0.28, default=1.0)


def stand_base():
    m = CModel(seed=81)
    sh = Shell()
    b, t = STAND["base"], STAND["plate"]
    bx(m, "Steel", DARK, (0, t / 2, 0), (b, t, b), sh=sh)
    # the collar the column runs in, and its ground sleeve below the plate
    m.color = GREY
    tube(m, "Steel", (0, t, 0), (0, STAND["collar"], 0), 0.135, segs=20, uv_m=1.0)
    tube(m, "Steel", (0, STAND["collar"], 0), (0, STAND["collar"] + 0.02, 0), 0.155, segs=20, uv_m=1.0)
    m.color = DARK
    tube(m, "Steel", (0, -0.6, 0), (0, -0.002, 0), 0.12, segs=16, caps=False, uv_m=1.0)
    sh.add((0, STAND["collar"] / 2 + 0.01, 0), (0.30, STAND["collar"] + 0.02, 0.30))
    # four gussets from the plate to the collar, on the diagonals (clear of the gearbox)
    for a in range(4):
        c, s = math.cos(a * math.pi / 2 + math.pi / 4), math.sin(a * math.pi / 2 + math.pi / 4)
        M = np.array([[c, 0, -s], [0, 1, 0], [s, 0, c]])
        bx(m, "Steel", GREY, (0.25 * c, t + 0.045, 0.25 * s), (0.24, 0.09, 0.02), M=M)
    # corner anchors (a pad and its bolt) and the safety-yellow corner marks
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx, cz = sx * (b / 2 - 0.10), sz * (b / 2 - 0.10)
            bx(m, "Steel", GREY, (cx, t + 0.006, cz), (0.12, 0.012, 0.12))
            m.color = LIGHT
            tube(m, "Steel", (cx, t + 0.012, cz), (cx, t + 0.05, cz), 0.018, segs=6, uv_m=4.0)
            bx(m, "Steel", SAFETY, (sx * (b / 2 - 0.03), t + 0.002, sz * (b / 2 - 0.22)), (0.05, 0.004, 0.30))
            bx(m, "Steel", SAFETY, (sx * (b / 2 - 0.22), t + 0.003, sz * (b / 2 - 0.03)), (0.30, 0.004, 0.05))
    # the jack's gearbox on the collar's +X side and its crank
    bx(m, "Steel", SAFETY, (0.24, 0.10, 0), (0.16, 0.12, 0.14))
    m.color = DARK
    tube(m, "Steel", (0.32, 0.10, 0), (0.37, 0.10, 0), 0.016, segs=8, uv_m=4.0)
    tube(m, "Steel", (0.37, 0.10, 0), (0.37, 0.10, 0.14), 0.012, segs=8, uv_m=4.0)
    m.color = RUBBER
    tube(m, "Rubber", (0.37, 0.10, 0.14), (0.43, 0.10, 0.14), 0.02, segs=8, uv_m=4.0)
    return m, sh


def stand_deck():
    """The deck and its column, in a frame whose y = 0 is the deck's top (the
    rubber pads the craft rests on)."""
    m = CModel(seed=82)
    m.ground = False
    sh = Shell()
    d = STAND["deck"]
    # the plate (top at -0.015, under the pads), its edge angle, two beams under it
    bx(m, "Steel", GREY, (0, -0.045, 0), (d, 0.06, d), sh=sh)
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, -0.045, s * (d / 2 + 0.006)), (d + 0.024, 0.07, 0.012))
        bx(m, "Steel", DARK, (s * (d / 2 + 0.006), -0.045, 0), (0.012, 0.07, d))
        bx(m, "Steel", DARK, (s * 0.18, -0.115, 0), (0.08, 0.08, d - 0.1))
        bx(m, "Steel", DARK, (0, -0.112, s * 0.18), (d - 0.1, 0.074, 0.08))
        # safety-yellow edge stripes
        bx(m, "Steel", SAFETY, (0, -0.0135, s * (d / 2 - 0.04)), (d - 0.1, 0.003, 0.05))
    # the rubber pads the craft rests on (their tops are the deck's top)
    for sx in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Rubber", RUBBER, (sx * 0.215, -0.0075, sz * 0.215), (0.38, 0.015, 0.38))
    # the column: a flange under the beams, then 3.9 m of tube with a height
    # band every half metre (painted yellow, so the setting reads at a glance)
    m.color = GREY
    tube(m, "Steel", (0, -0.157, 0), (0, -0.177, 0), 0.16, segs=20, uv_m=1.0)
    top, L, r = -0.177, STAND["col_len"], STAND["col_r"]
    m.color = LIGHT
    tube(m, "Steel", (0, top - L, 0), (0, top, 0), r, segs=16, uv_m=1.0)
    for k in range(1, 8):
        y = top - k * 0.5
        m.color = SAFETY
        tube(m, "Steel", (0, y - 0.02, 0), (0, y + 0.02, 0), r + 0.003, segs=16, caps=False, uv_m=4.0)
    sh.add((0, top - L / 2, 0), (2 * r, L, 2 * r))
    return m, sh


def write_stand(dry):
    """The stand's prefab: the base (root, its collider boxes as "Wall N"), the
    Deck child at the default height, and the deck's collider boxes as ITS
    children ("Deck Wall N"), so moving the Deck moves its colliders."""
    bm, bsh = stand_base()
    dm, dsh = stand_deck()
    rc, lo, hi = centre(bm)
    dc, dlo, dhi = centre(dm)
    seat = rc[1]
    deck_off = -dc[1]                 # the deck's top over the Deck node's origin
    at = np.array([0.0, STAND["default"] - deck_off - seat, 0.0])
    folder = "models/base/parts"
    nodes = [node_mesh("BaseStand", f"{folder}/stand_base.glb", bm, (0, 0, 0), None, tags=["base_part"]),
             node_mesh("Deck", f"{folder}/stand_deck.glb", dm, at, 0)]
    for i, (c, s, q) in enumerate(bsh.boxes):
        nodes.append(node_box(f"Wall {i + 1}", np.asarray(c) - rc, s, q, 0))
    for i, (c, s, q) in enumerate(dsh.boxes):
        nodes.append(node_box(f"Deck Wall {i + 1}", np.asarray(c) - dc, s, q, 1))
    print(f"BaseStand      seat {seat:+.4f}  deck_off {deck_off:+.4f}  base box {f3(hi - lo)}  deck box {f3(dhi - dlo)}"
          f"  tris {bm.tris() + dm.tris()}  colliders {len(bsh.boxes) + len(dsh.boxes)}")
    if dry:
        return seat, deck_off
    for (glb, model) in (("stand_base.glb", bm), ("stand_deck.glb", dm)):
        zcheck(model, glb, verbose=True)
        gen_base.write_glb(model.shifted(np.zeros(3)), os.path.join(ROOT, folder, glb))
    with open(os.path.join(PREFABS, "BaseStand.prefab.ron"), "w") as f:
        f.write("// BUILD STAND — a 0.9 m deck on a telescoping column (BASE section; scripts/craft_stand.lua).\n"
                "// The Deck child (and its \"Deck Wall\" colliders) slides along up with the stand's height.\n"
                "// Written by tools/gen_base_parts.py — edit the generator, not this file.\n[\n")
        f.write("".join(nodes))
        f.write("]\n")
    return seat, deck_off


# ── BASE STATION TOWER (step 7, M1) ─────────────────────────────────────────
# A 12 m galvanised lattice mast, 1.2 m square (four legs, X-braced every
# 2 m), on a bolted steel base frame with a concrete pad under each leg. At
# 11 m a grated work platform with a guard rail; on its front a 3 m solid
# parabolic dish on a yoke, tipped 35 deg up (the outpost's link home); a Yagi
# on the back face, a whip and an aviation obstruction light on top. At the
# foot an equipment cabinet (the radio, the power controller), its conduit up
# a leg, and a caged ladder face. 1.5 t: a real 12 m self-supporting lattice
# with a 3 m dish is 1.2-1.8 t of steel. Footprint 2.6 x 2.6 m: it stands on
# the ground or on a Pad Plate's deck. Colliders ("Wall N"): the base frame,
# the mast as one box, the cabinet, the platform (no one climbs it before
# EN2; no kinematic fakes).

TOWER = dict(frame=2.6, frame_h=0.16, mast_w=1.2, mast_top=11.0, plat=1.9, dish_r=1.5)


def tower():
    m = CModel(seed=91)
    sh = Shell()
    F, fh, w, top = TOWER["frame"], TOWER["frame_h"], TOWER["mast_w"], TOWER["mast_top"]
    hw = w / 2
    # the base frame: two skids, two cross members, a deck plate between the legs
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, fh / 2, s * (F / 2 - 0.08)), (F, fh, 0.16))
        bx(m, "Steel", DARK, (s * (F / 2 - 0.08), fh / 2, 0), (0.16, fh, F - 0.32))
    bx(m, "Steel", GREY, (0, fh - 0.01, 0), (w + 0.3, 0.02, w + 0.3))
    sh.add((0, fh / 2, 0), (F, fh, F))
    # a concrete pad and a base plate under each leg, its four bolts
    for sx in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Concrete", CONC, (sx * hw, fh + 0.062, sz * hw), (0.36, 0.12, 0.36))
            bx(m, "Steel", GREY, (sx * hw, fh + 0.13, sz * hw), (0.24, 0.02, 0.24))
            for bxs in (-1, 1):
                for bzs in (-1, 1):
                    tb(m, "Steel", LIGHT, (sx * hw + bxs * 0.08, fh + 0.14, sz * hw + bzs * 0.08),
                       (sx * hw + bxs * 0.08, fh + 0.18, sz * hw + bzs * 0.08), 0.012, segs=6)
    y0 = fh + 0.14
    lattice_column(m, LIGHT, (0, y0, 0), top, w, step=2.0, r=0.055, rb=0.028)
    sh.add((0, (y0 + top) / 2, 0), (w + 0.12, top - y0, w + 0.12))
    # the work platform at the top: grating, toe boards, a rail all round
    P = TOWER["plat"]
    bx(m, "Steel", GREY, (0, top + 0.03, 0), (P, 0.05, P))
    for s in (-1, 1):
        bx(m, "Steel", SAFETY, (0, top + 0.112, s * (P / 2 - 0.025)), (P - 0.03, 0.10, 0.02))
        bx(m, "Steel", SAFETY, (s * (P / 2 - 0.025), top + 0.112, 0), (0.02, 0.10, P - 0.08))
    c = [(-P / 2, -P / 2), (P / 2, -P / 2), (P / 2, P / 2), (-P / 2, P / 2)]
    for i in range(4):
        (ax, az), (bx_, bz) = c[i], c[(i + 1) % 4]
        railing(m, SAFETY, (ax, top + 0.05, az), (bx_, top + 0.05, bz), h=1.05, posts=0.95)
    sh.add((0, top + 0.05, 0), (P, 0.12, P))
    # a whip mast and the obstruction light over the platform
    tb(m, "Steel", LIGHT, (0, top + 0.05, 0), (0, top + 2.2, 0), 0.05, segs=10)
    obstruction(m, (0, top + 2.36, 0))
    tb(m, "Steel", DARK, (0.25, top + 1.0, 0), (0.25, top + 2.0, 0), 0.012, segs=6)
    # THE DISH: 3 m, on a yoke off the platform's front, tipped 35 deg up
    R = TOWER["dish_r"]
    el = math.radians(35)
    axis = (0.0, math.sin(el), math.cos(el))
    dc = np.array([0.0, top - 0.25, P / 2 + 0.35])
    dish(m, tuple(dc), axis, R, R * 0.62, col=PAINT, feed=True)
    # the yoke: two arms from the platform edge to the dish's back, a hub drum
    back = dc - np.array(axis) * 0.05
    m.color = GREY
    tube(m, "Steel", tuple(back - np.array(axis) * 0.32), tuple(back), 0.16, segs=16, uv_m=1.0)
    for s in (-1, 1):
        tb(m, "Steel", GREY, (s * 0.55, top + 0.02, P / 2 - 0.05), tuple(back - np.array(axis) * 0.25 + np.array([s * 0.12, 0, 0])), 0.05, segs=8)
        tb(m, "Steel", GREY, (s * 0.55, top - 1.2, hw), (s * 0.55, top + 0.02, P / 2 - 0.05), 0.045, segs=8)
    # a Yagi on the back face, pointing out behind
    yagi(m, (0, top - 1.4, -hw - 0.05), (0, 0.05, -1.0), n=7, L=1.8)
    # the ladder up the back face: two rails, a rung every 0.3 m, hoops above 2.4 m
    lz = -hw - 0.22
    for s in (-1, 1):
        tb(m, "Steel", GREY, (s * 0.22, y0 + 0.02, lz), (s * 0.22, top + 0.02, lz), 0.022, segs=6)
    y = y0 + 0.3
    while y < top - 0.05:
        tb(m, "Steel", LIGHT, (-0.22, y, lz), (0.22, y, lz), 0.014, segs=5)
        y += 0.3
    for k in range(12):
        yy = 2.4 + k * 0.72
        if yy > top - 0.2:
            break
        sub = CModel(); sub.color = SAFETY; sub.ground = False
        lathe(sub, "Steel", [(0.36, -0.015), (0.36, 0.015), (0.33, 0.015), (0.33, -0.015), (0.36, -0.015)], segs=14,
              a0=math.pi * 1.08, a1=math.pi * 1.92)
        m.merge(sub, None, (0, yy, lz + 0.02))
    # THE EQUIPMENT CABINET at the foot, on the frame's front right, and its conduit up a leg
    cx, cz = 0.92, 0.75
    bx(m, "Steel", DARK, (cx, fh + 0.052, cz), (0.62, 0.10, 0.52))
    bx(m, "Clad", PAINT, (cx, fh + 0.10 + 0.75, cz), (0.56, 1.5, 0.46))
    bx(m, "Steel", GREY, (cx, fh + 0.10 + 1.53, cz), (0.62, 0.05, 0.52))
    bx(m, "Steel", WARM, (cx, fh + 0.10 + 0.75, cz + 0.235), (0.50, 1.40, 0.012))
    bx(m, "Steel", DARK, (cx - 0.20, fh + 0.10 + 0.85, cz + 0.25), (0.03, 0.14, 0.03))
    for i in range(6):
        bx(m, "Steel", DARK, (cx + 0.285, fh + 0.4 + i * 0.07, cz), (0.012, 0.035, 0.30))
    bx(m, "Lamp", LAMP_WARM, (cx + 0.12, fh + 0.10 + 1.40, cz + 0.243), (0.06, 0.02, 0.006))
    sh.add((cx, fh + 0.10 + 0.78, cz), (0.62, 1.58, 0.52))
    tb(m, "Steel", GREY, (cx - 0.15, fh + 1.65, cz - 0.10), (hw + 0.02, fh + 1.65, hw + 0.02), 0.03, segs=6)
    tb(m, "Steel", GREY, (hw + 0.02, fh + 1.65, hw + 0.02), (hw + 0.02, top - 0.3, hw + 0.02), 0.03, segs=6)
    # a grounding rod and its strap at the back left corner
    tb(m, "Steel", WARM, (-F / 2 + 0.2, 0.0, -F / 2 + 0.2), (-F / 2 + 0.2, fh + 0.3, -F / 2 + 0.2), 0.012, segs=6)
    return m, sh


# ── SOLAR ARRAY (step 7: a source for the tower) ────────────────────────────
# A ground-mount single-axis tracker: two 1.2 x 2.0 m modules (4.8 m2) on a
# torque tube along X, 1.35 m up on two driven steel posts with concrete
# footings, drawn at 25 deg of tilt. Its cells turn about the tube toward the
# sun (electronics.panelExposure, open), as a real tracker's drive does.

def solar_array():
    m = CModel(seed=93)
    sh = Shell()
    hub = 1.35
    for s in (-1, 1):
        bx(m, "Concrete", CONC, (s * 0.9, 0.08, 0), (0.36, 0.16, 0.36))
        bx(m, "Steel", GREY, (s * 0.9, (0.16 + hub) / 2, 0), (0.10, hub - 0.16, 0.14))
        bx(m, "Steel", GREY, (s * 0.9, 0.17, 0), (0.22, 0.02, 0.22))
        sh.add((s * 0.9, hub / 2, 0), (0.36, hub, 0.36))
    tb(m, "Steel", LIGHT, (-1.3, hub, 0), (1.3, hub, 0), 0.06, segs=12)
    # the slew drive and its junction box on the left post
    bx(m, "Steel", DARK, (-0.9, hub, 0.0), (0.18, 0.22, 0.22))
    bx(m, "Clad", PAINT, (-0.9, 0.75, 0.13), (0.22, 0.28, 0.10))
    tilt = math.radians(25)
    Mt = rot_x(-tilt)
    # two modules either side of the centre, rails under them
    for s in (-1, 1):
        cxm = s * 0.62
        c = np.array([cxm, hub + 0.12, 0.0])
        bx(m, "Steel", DARK, tuple(c), (1.18, 0.035, 1.98), M=Mt)
        m.color = (1.0, 1.0, 1.0)
        box(m, "Solar", tuple(c + Mt @ np.array([0, 0.019, 0])), (1.12, 0.004, 1.92), M=Mt, uv_m=0.5)
        for e in (-1, 1):
            bx(m, "Steel", LIGHT, tuple(c + Mt @ np.array([e * 0.585, 0.0, 0])), (0.03, 0.05, 1.98), M=Mt)
            bx(m, "Steel", LIGHT, tuple(c + Mt @ np.array([0, 0.0, e * 0.985])), (1.14, 0.05, 0.03), M=Mt)
        for z in (-0.6, 0.6):
            bx(m, "Steel", GREY, tuple(np.array([cxm, hub + 0.06, 0.0]) + Mt @ np.array([0, 0, z])), (1.1, 0.06, 0.06), M=Mt)
    sh.add((0, hub + 0.12, 0), (2.5, 0.12, 2.0), quat_x(-tilt))
    return m, sh


# ── ISOTOPE SKID (step 7: a source for the tower) ───────────────────────────
# Four Isotope Cells (parts_nuclear `rtg`, an MMRTG each: 0.64 m, 45 kg,
# finned) bolted upright in a 2 x 2 rack on a steel skid, with a guard cage
# and a power junction box. 0.5 EC/s each, day and night: 2.0 EC/s, one
# tower's draw. 0.3 t.

def isotope_skid():
    m = CModel(seed=95)
    sh = Shell()
    L, W, k = 1.7, 1.2, 0.12
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, k / 2, s * (W / 2 - 0.08)), (L, k, 0.14))
    for x in (-0.7, 0.0, 0.7):
        bx(m, "Steel", DARK, (x, k / 2, 0), (0.12, k, W - 0.3))
    bx(m, "Steel", GREY, (0, k + 0.012, 0), (L - 0.05, 0.02, W - 0.05))
    sh.add((0, k / 2, 0), (L, k, W))
    for sx in (-1, 1):
        for sz in (-1, 1):
            x, z = sx * 0.38, sz * 0.26
            bx(m, "Steel", DARK, (x, k + 0.04, z), (0.36, 0.04, 0.36))
            m.color = (0.30, 0.30, 0.32)
            tube(m, "Steel", (x, k + 0.06, z), (x, k + 0.70, z), 0.115, segs=16, uv_m=1.0)
            m.color = DARK
            tube(m, "Steel", (x, k + 0.70, z), (x, k + 0.74, z), 0.13, segs=16, uv_m=1.0)
            for f in range(8):
                a = f * TAU / 8 + TAU / 16
                ca, sa = math.cos(a), math.sin(a)
                bx(m, "Steel", (0.10, 0.10, 0.11), (x + ca * 0.17, k + 0.38, z + sa * 0.17), (0.11, 0.58, 0.012),
                   M=np.array([[ca, 0, -sa], [0, 1, 0], [sa, 0, ca]]))
    # the guard cage: corner posts, top rails, a mesh panel each long side
    H = 0.95
    for sx in (-1, 1):
        for sz in (-1, 1):
            tb(m, "Steel", SAFETY, (sx * (L / 2 - 0.05), k, sz * (W / 2 - 0.05)), (sx * (L / 2 - 0.05), k + H, sz * (W / 2 - 0.05)), 0.025, segs=6)
    for s in (-1, 1):
        tb(m, "Steel", SAFETY, (-(L / 2 - 0.05), k + H, s * (W / 2 - 0.05)), ((L / 2 - 0.05), k + H, s * (W / 2 - 0.05)), 0.022, segs=6)
        tb(m, "Steel", SAFETY, (s * (L / 2 - 0.05), k + H, -(W / 2 - 0.05)), (s * (L / 2 - 0.05), k + H, (W / 2 - 0.05)), 0.022, segs=6)
        for i in range(9):
            x = -L / 2 + 0.2 + i * (L - 0.4) / 8
            tb(m, "Steel", GREY, (x, k + 0.08, s * (W / 2 - 0.05)), (x, k + H - 0.03, s * (W / 2 - 0.05)), 0.008, segs=4)
    sh.add((0, k + H / 2, 0), (L - 0.05, H, W - 0.05))
    # the junction box on the front, its conduit down to the skid
    bx(m, "Clad", PAINT, (0.0, k + 0.45, W / 2 + 0.02), (0.30, 0.36, 0.10))
    bx(m, "Steel", SAFETY, (0.0, k + 0.66, W / 2 + 0.075), (0.18, 0.05, 0.004))
    tb(m, "Steel", GREY, (0.0, k + 0.27, W / 2 + 0.02), (0.0, k + 0.02, W / 2 + 0.02), 0.025, segs=6)
    return m, sh


# ── BATTERY BANK (step 8: the base grid's storage) ──────────────────────────
# An outdoor battery cabinet on a steel skid, the size of a utility
# battery-energy-storage enclosure: 2.4 (x) x 1.2 (z) x 2.2 m, LFP racks
# behind two pairs of front doors, a thermal-management unit (a split-case
# air conditioner with its fan) on the right end, louvres low on the back, a
# DC junction box with its conduit on the left end and the warning placards.
# 2.6 t fitted; 4,000 EC.

def battery_bank():
    m = CModel(seed=97)
    sh = Shell()
    L, D, H, k = 2.4, 1.2, 2.05, 0.15
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, k / 2, s * (D / 2 - 0.07)), (L + 0.1, k, 0.14))
    for x in (-0.9, 0.0, 0.9):
        bx(m, "Steel", DARK, (x, k / 2, 0), (0.12, k, D - 0.28))
    bx(m, "Clad", PAINT, (0, k + H / 2, 0), (L, H, D))
    bx(m, "Steel", GREY, (0, k + H + 0.03, 0), (L + 0.08, 0.06, D + 0.08))
    sh.add((0, (k + H) / 2 + 0.015, 0), (L + 0.1, k + H + 0.03, D + 0.08))
    # the doors: two pairs on the front (+Z), their seams, handles and hinges
    for c in (-0.6, 0.6):
        for s in (-1, 1):
            x = c + s * 0.29
            bx(m, "Clad", WARM, (x, k + H / 2, D / 2 + 0.006), (0.56, H - 0.16, 0.012))
        bx(m, "Steel", DARK, (c, k + H / 2, D / 2 + 0.014), (0.012, H - 0.16, 0.006))
        for s in (-1, 1):
            tb(m, "Steel", LIGHT, (c + s * 0.05, k + H / 2 - 0.15, D / 2 + 0.035), (c + s * 0.05, k + H / 2 + 0.15, D / 2 + 0.035), 0.012, segs=6)
            for hy in (0.35, H - 0.35):
                bx(m, "Steel", GREY, (c + s * 0.57, k + hy, D / 2 + 0.018), (0.03, 0.10, 0.02))
    # the placards: a hazard square on each pair, a rating plate
    for c in (-0.6, 0.6):
        bx(m, "Steel", SAFETY, (c + 0.25, k + 1.55, D / 2 + 0.016), (0.20, 0.20, 0.004))
        bx(m, "Steel", DARK, (c + 0.25, k + 1.55, D / 2 + 0.0195), (0.10, 0.10, 0.003))
    bx(m, "Steel", LIGHT, (0.0, k + 1.15, D / 2 + 0.016), (0.10, 0.07, 0.004))
    # louvres low on the back
    for i in range(6):
        bx(m, "Steel", DARK, (-0.6 + i * 0.24, k + 0.35, -D / 2 - 0.012), (0.18, 0.14, 0.02))
        for j in range(4):
            bx(m, "Steel", GREY, (-0.6 + i * 0.24, k + 0.30 + j * 0.035, -D / 2 - 0.024), (0.17, 0.008, 0.012))
    # the thermal unit on the right end (+X): a case, its fan guard and coil
    bx(m, "Clad", LIGHT, (L / 2 + 0.17, k + 1.25, 0), (0.34, 0.80, 0.90))
    fan = CModel(seed=3)
    fan.ground = False
    m.color = DARK
    lathe(fan, "Steel", [(0.30, 0.0), (0.31, 0.02), (0.05, 0.02), (0.0, 0.03)], segs=24)
    m.merge(fan, M=rot_z(-math.pi / 2), t=(L / 2 + 0.345, k + 1.30, 0))
    for j in range(5):
        tb(m, "Steel", GREY, (L / 2 + 0.36, k + 1.30 - 0.24 + j * 0.12, -0.30), (L / 2 + 0.36, k + 1.30 - 0.24 + j * 0.12, 0.30), 0.006, segs=4)
    sh.add((L / 2 + 0.17, k + 1.25, 0), (0.34, 0.80, 0.90))
    # the DC junction box on the left end, its conduit to the skid
    bx(m, "Clad", PAINT, (-L / 2 - 0.07, k + 0.95, 0.15), (0.14, 0.40, 0.34))
    bx(m, "Steel", SAFETY, (-L / 2 - 0.145, k + 1.08, 0.15), (0.004, 0.08, 0.20))
    tb(m, "Steel", GREY, (-L / 2 - 0.07, k + 0.75, 0.15), (-L / 2 - 0.07, k + 0.02, 0.15), 0.03, segs=8)
    return m, sh


# ── SHIELD WALL (M6c: blocks the A4 radiation cone by its record) ───────────
# A precast concrete shielding block, 2.0 (x) x 2.0 (h) x 0.5 m (z): ordinary
# concrete (2.3 t/m3: 4.6 t), chamfered arrises, a shear key along the top and
# a groove under it so blocks stack, two cast-in lifting loops, a stencilled
# number plate. Half a metre of concrete lets about 5 % of a core's gamma
# through (parts_base shieldWall.shield.k).

def shield_wall():
    m = CModel(seed=99)
    sh = Shell()
    W, H, T, c = 2.0, 2.0, 0.5, 0.03
    bx(m, "Concrete", CONC, (0, H / 2, 0), (W - 2 * c, H, T))
    bx(m, "Concrete", CONC, (0, H / 2, 0), (W, H - 2 * c, T - 2 * c))
    # the shear key along the top
    bx(m, "Concrete", CONC_DARK, (0, H + 0.04, 0), (W - 0.3, 0.08, 0.16))
    sh.add((0, H / 2, 0), (W, H, T))
    # lifting loops, cast in near each end
    for s in (-1, 1):
        ring = CModel(seed=2)
        ring.ground = False
        m.color = GREY
        lathe(ring, "Steel", [(0.06, 0.0), (0.075, 0.015), (0.06, 0.03), (0.045, 0.015), (0.06, 0.0)], segs=12)
        m.merge(ring, M=rot_z(math.pi / 2), t=(s * 0.7, H + 0.06, 0))
        bx(m, "Steel", DARK, (s * 0.7, H + 0.002, 0), (0.14, 0.004, 0.14))
    # the stencilled plate, on both faces
    for f in (-1, 1):
        bx(m, "Steel", SAFETY, (0.55, 1.55, f * (T / 2 + 0.004)), (0.42, 0.16, 0.008))
        bx(m, "Steel", DARK, (0.55, 1.55, f * (T / 2 + 0.009)), (0.30, 0.06, 0.004))
        bx(m, "Steel", DARK, (-0.62, 0.22, f * (T / 2 + 0.003)), (0.36, 0.03, 0.006))
    return m, sh


# ── BASE HUB (playtest 11-09: "a main base hub … what you interact with to go
# full build mode for your actual base") ─────────────────────────────────────
# A site operations console on a steel skid, 2.6 (x) x 1.8 (z) m: a sloped
# control desk on the front (+Z) with two inclined displays and a keyboard
# ledge, a 19-inch equipment rack behind it, a 3.4 m pole with an amber
# beacon and a whip antenna on the back left corner, a document box, a
# handrail along the back and a grounding rod. 0.9 t fitted out. Its menu
# opens the full freecam builder anchored to the base (scripts/base_hub.lua).

def base_hub():
    m = CModel(seed=103)
    sh = Shell()
    L, D, k = 2.6, 1.8, 0.14
    # the skid: two runners, three cross members, a chequer deck plate
    for s in (-1, 1):
        bx(m, "Steel", DARK, (0, k / 2, s * (D / 2 - 0.08)), (L, k, 0.16))
    for x in (-1.1, 0.0, 1.1):
        bx(m, "Steel", DARK, (x, k / 2, 0), (0.12, k, D - 0.32))
    bx(m, "Steel", GREY, (0, k + 0.01, 0), (L - 0.04, 0.02, D - 0.04))
    for s in (-1, 1):
        for e in (-1, 1):
            bx(m, "Steel", SAFETY, (s * (L / 2 - 0.12), k + 0.022, e * (D / 2 - 0.12)), (0.18, 0.004, 0.18))
    sh.add((0, k / 2 + 0.01, 0), (L, k + 0.02, D))
    y0 = k + 0.02
    # THE DESK: a cabinet 2.0 x 0.75 x 0.78 m, its top sloped 20 deg toward the operator (+Z)
    dw, dd, dh = 2.0, 0.75, 0.78
    dz = D / 2 - 0.15 - dd / 2
    bx(m, "Clad", PAINT, (0, y0 + dh / 2, dz), (dw, dh, dd))
    slope = math.radians(20)
    M = np.array([[1, 0, 0], [0, math.cos(slope), -math.sin(slope)], [0, math.sin(slope), math.cos(slope)]])
    bx(m, "Steel", DARK, (0, y0 + dh + 0.03, dz), (dw + 0.04, 0.04, dd + 0.02), M=M)
    # the keyboard ledge and two keyboards
    bx(m, "Steel", GREY, (0, y0 + dh - 0.02, dz + dd / 2 + 0.12), (dw - 0.1, 0.03, 0.26))
    for x in (-0.45, 0.45):
        bx(m, "Steel", (0.12, 0.12, 0.13), (x, y0 + dh + 0.005, dz + dd / 2 + 0.12), (0.46, 0.018, 0.16))
    # two displays, inclined, in dark bezels, glowing a cool blue
    ty = y0 + dh + 0.05
    for x in (-0.48, 0.48):
        Mi = np.array([[1, 0, 0], [0, math.cos(-0.25), -math.sin(-0.25)], [0, math.sin(-0.25), math.cos(-0.25)]])
        bx(m, "Steel", DARK, (x, ty + 0.30, dz - 0.12), (0.86, 0.54, 0.05), M=Mi)
        bx(m, "Lamp", (0.30, 0.55, 0.90), (x, ty + 0.30 + 0.004, dz - 0.12 + 0.028), (0.78, 0.46, 0.006), M=Mi)
        tb(m, "Steel", GREY, (x, ty, dz - 0.18), (x, ty + 0.2, dz - 0.16), 0.03, segs=6)
    # the front: two doors, their handles, a vent strip and a placard
    for s in (-1, 1):
        bx(m, "Clad", WARM, (s * dw / 4, y0 + dh / 2 - 0.02, dz + dd / 2 + 0.006), (dw / 2 - 0.06, dh - 0.16, 0.012))
        tb(m, "Steel", LIGHT, (s * 0.12, y0 + 0.30, dz + dd / 2 + 0.03), (s * 0.12, y0 + 0.52, dz + dd / 2 + 0.03), 0.012, segs=6)
    for i in range(10):
        bx(m, "Steel", DARK, (-0.8 + i * 0.178, y0 + 0.08, dz + dd / 2 + 0.008), (0.14, 0.03, 0.006))
    bx(m, "Steel", SAFETY, (0.75, y0 + 0.62, dz + dd / 2 + 0.014), (0.22, 0.10, 0.004))
    sh.add((0, y0 + dh / 2 + 0.02, dz), (dw + 0.04, dh + 0.08, dd + 0.02))
    # THE RACK behind: 0.6 x 0.8 x 1.9 m, a glass door, its fan vents and status lamps
    rx, rz, rh = 0.55, -D / 2 + 0.5, 1.9
    bx(m, "Clad", (0.22, 0.24, 0.26), (rx, y0 + rh / 2, rz - 0.02), (0.62, rh, 0.76))
    bx(m, "Steel", GREY, (rx, y0 + rh + 0.02, rz), (0.66, 0.04, 0.84))
    bx(m, "Glass", (0.35, 0.40, 0.42), (rx, y0 + rh / 2, rz + 0.412), (0.54, rh - 0.12, 0.01))
    for i in range(7):
        bx(m, "Steel", DARK, (rx, y0 + 0.25 + i * 0.22, rz + 0.37), (0.48, 0.09, 0.04))
        bx(m, "Lamp", LAMP_COOL if i % 3 else (0.40, 0.95, 0.45), (rx + 0.18, y0 + 0.25 + i * 0.22, rz + 0.392), (0.03, 0.015, 0.004))
    for j in range(4):
        bx(m, "Steel", DARK, (rx + 0.312, y0 + 1.2 + j * 0.08, rz), (0.012, 0.04, 0.5))
    sh.add((rx, y0 + rh / 2 + 0.02, rz), (0.66, rh + 0.04, 0.84))
    # a cable tray from the rack down into the desk
    tb(m, "Steel", GREY, (rx - 0.2, y0 + 0.10, rz + 0.30), (-0.2, y0 + 0.10, dz - dd / 2 + 0.02), 0.04, segs=6)
    # THE POLE on the back left corner: an amber beacon and a whip
    px, pz, ph = -L / 2 + 0.22, -D / 2 + 0.22, 3.4
    bx(m, "Steel", DARK, (px, y0 + 0.02, pz), (0.28, 0.04, 0.28))
    tb(m, "Steel", LIGHT, (px, y0 + 0.04, pz), (px, y0 + ph, pz), 0.045, segs=10)
    tb(m, "Steel", DARK, (px, y0 + ph, pz), (px, y0 + ph + 0.06, pz), 0.07, segs=12)
    sub = CModel(); sub.color = (1.0, 0.62, 0.12); sub.ground = False
    prof = [(0.07 * math.cos(a), 0.12 * math.sin(a)) for a in np.linspace(0, math.pi / 2, 7)]
    lathe(sub, "Lamp", prof, segs=14, smooth=True)
    m.merge(sub, None, (px, y0 + ph + 0.065, pz))
    tb(m, "Steel", DARK, (px + 0.12, y0 + ph - 0.6, pz), (px + 0.12, y0 + ph + 0.9, pz), 0.008, segs=5)
    tb(m, "Steel", GREY, (px, y0 + ph - 0.6, pz), (px + 0.12, y0 + ph - 0.6, pz), 0.015, segs=5)
    sh.add((px, y0 + ph / 2, pz), (0.14, ph, 0.14))
    # a weatherproof document box on the skid's right end
    bx(m, "Clad", SAFETY, (L / 2 - 0.25, y0 + 0.55, 0.2), (0.30, 0.42, 0.22))
    tb(m, "Steel", GREY, (L / 2 - 0.25, y0, 0.2), (L / 2 - 0.25, y0 + 0.34, 0.2), 0.03, segs=6)
    # the handrail along the back
    railing(m, SAFETY, (-L / 2 + 0.45, y0, -D / 2 + 0.06), (L / 2 - 0.1, y0, -D / 2 + 0.06), h=1.0, posts=1.0)
    # a grounding rod and its strap
    tb(m, "Steel", WARM, (L / 2 - 0.12, -0.3, -D / 2 + 0.12), (L / 2 - 0.12, y0 + 0.25, -D / 2 + 0.12), 0.012, segs=6)
    return m, sh


# ── CABLE DRUM (B9b: the Power Cable's card and hold model) ─────────────────
# A 500 m drum of 4-core 16 mm2 steel-wire-armoured cable: two 1.3 m plywood
# flanges on a steel barrel, the black cable wound between, its end tied off,
# on a steel jack stand. (The cable a run lays is a mesh: base_cable.lua.)

def cable_drum():
    m = CModel(seed=101)
    Rf, Wd, ax = 0.65, 0.80, 0.80
    for s in (-1, 1):
        m.color = WARM
        tube(m, "Clad", (s * Wd / 2 - 0.02 * s, ax, 0), (s * Wd / 2 + 0.02 * s, ax, 0), Rf, segs=28, uv_m=0.5)
    m.color = RUBBER
    tube(m, "Dark", (-Wd / 2 + 0.02, ax, 0), (Wd / 2 - 0.02, ax, 0), 0.52, segs=28, uv_m=2.0)
    for i in range(7):
        x = -Wd / 2 + 0.06 + i * (Wd - 0.12) / 6
        tube(m, "Dark", (x - 0.03, ax, 0), (x + 0.03, ax, 0), 0.535, segs=28, uv_m=2.0)
    tb(m, "Steel", GREY, (-Wd / 2 - 0.25, ax, 0), (Wd / 2 + 0.25, ax, 0), 0.04, segs=10)
    # the jack stands
    for s in (-1, 1):
        x = s * (Wd / 2 + 0.18)
        for z in (-0.45, 0.45):
            tb(m, "Steel", SAFETY, (x, 0.02, z), (x, ax, 0), 0.03, segs=6)
        bx(m, "Steel", DARK, (x, 0.02, 0), (0.12, 0.04, 1.0))
    # the tail, tied off to a flange
    tb(m, "Dark", RUBBER, (0.2, ax + 0.53, 0.0), (0.38, ax + 0.30, 0.42), 0.014, segs=8)
    return m, Shell()


# ── BUILD KIT (the item) ─────────────────────────────────────────────────────
# A rugged field tablet in a hard carry frame: 0.30 x 0.22 x 0.035 m with
# rubber corner bumpers and a top carry handle, 1.6 kg. Carried by the handle
# (items.lua grip "left"); its long side along the stride (+Z).

def build_kit():
    m = CModel(seed=71)
    m.ground = False
    W, H, T = 0.30, 0.22, 0.035
    bx(m, "Dark", (0.20, 0.21, 0.22), (0, 0, 0), (T, H, W))
    bx(m, "Glass", (0.05, 0.07, 0.09), (T / 2 + 0.001, 0.0, 0.0), (0.002, H - 0.04, W - 0.05))
    for sy in (-1, 1):
        for sz in (-1, 1):
            bx(m, "Rubber", (0.55, 0.36, 0.10), (0, sy * (H / 2 - 0.012), sz * (W / 2 - 0.012)), (T + 0.012, 0.03, 0.03))
    for sz in (-1, 1):
        tb(m, "Dark", (0.15, 0.15, 0.16), (0, H / 2, sz * 0.07), (0, H / 2 + 0.045, sz * 0.07), 0.008, segs=8)
    tb(m, "Rubber", (0.12, 0.12, 0.12), (0, H / 2 + 0.045, -0.08), (0, H / 2 + 0.045, 0.08), 0.013, segs=10)
    return m


# ── writing ──────────────────────────────────────────────────────────────────

ITEM_MATS = {
    "Dark": ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/metal_albedo.png"),\n'
             '                normal_map: Some("textures/parts/metal_normal.png"),\n                normal_strength: 1.0,\n'
             '                roughness_map: Some("textures/parts/metal_orm.png"),\n                roughness: 1.2,\n'
             '                metallic_map: Some("textures/parts/metal_orm.png"),\n                metallic: 0.3,\n'
             '                ao_map: Some("textures/parts/metal_orm.png"),\n                shading: Physical,\n            )'),
    "Solar": ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/solar_albedo.png"),\n'
              '                normal_map: Some("textures/parts/solar_normal.png"),\n                normal_strength: 1.0,\n'
              '                roughness_map: Some("textures/parts/solar_orm.png"),\n                roughness: 1.0,\n'
              '                metallic_map: Some("textures/parts/solar_orm.png"),\n                metallic: 1.0,\n'
              '                ao_map: Some("textures/parts/solar_orm.png"),\n                shading: Physical,\n            )'),
    "Rubber": ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/parts/rubber_albedo.png"),\n'
               '                normal_map: Some("textures/parts/rubber_normal.png"),\n                normal_strength: 1.0,\n'
               '                roughness_map: Some("textures/parts/rubber_orm.png"),\n                roughness: 1.0,\n'
               '                ao_map: Some("textures/parts/rubber_orm.png"),\n                shading: Physical,\n            )'),
}


def mats_of(model):
    out = []
    for n in sorted(model.parts.keys()):
        ron = ITEM_MATS[n] if n in ITEM_MATS else gen_base.MATERIALS[n]()
        out.append(f'            "{n}": {ron}')
    return ",\n".join(out)


def centre(model):
    lo, hi = model.bounds()
    return (lo + hi) / 2, lo, hi


def f3(v):
    return f"({v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f})"


def node_mesh(name, glb, model, at, parent, tags=None, cast=True):
    tag = f"        tags: [{', '.join(chr(34) + t + chr(34) for t in tags)}],\n" if tags else ""
    par = f"        parent: Some({parent}),\n" if parent is not None else ""
    shadow = "" if cast else "        cast_shadow: false,\n"
    return f'''    (
        name: "{name}",
{tag}        transform: (
            translation: {f3(at)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "{glb}",
        ),
        object_materials: {{
{mats_of(model)},
        }},
        scripts: [],
{par}{shadow}    ),
'''


def node_box(name, c, s, q, parent, friction=0.9):
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(c)},
            rotation: ({q[0]:.5f}, {q[1]:.5f}, {q[2]:.5f}, {q[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
        cast_shadow: false,
{gen_base.collider_block(np.asarray(s) / 2, friction=friction)}    ),
'''


def node_empty(name, at, parent):
    return f'''    (
        name: "{name}",
        transform: (
            translation: {f3(at)},
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some({parent}),
    ),
'''


def write_part(name, about, root, shell, children, dry, folder="models/base/parts", doors=(), empties=(), ground_root=False):
    """root: (glb, model); children: [(node name, glb, model)]; shell: Shell;
    doors: [(node name, glb, model, shell, at)] — a sliding leaf (its centre
    `at` in the ground frame) whose colliders are its own children (sandbox
    S1: scripts/kit_live.lua slides it); empties: [(node name, at)]."""
    rc, lo, hi = centre(root[1])
    seat = rc[1]
    if ground_root:
        # (sandbox S1: the root is an Empty AT THE GROUND POINT, the model a
        # child at its own box centre: a module whose box is not centred on its
        # footprint — the hab's steps — still stands where its record says;
        # its `seat` is 0)
        nodes = [f'''    (
        name: "{name}",
        tags: ["base_part"],
        transform: (
            translation: (0.0000, 0.0000, 0.0000),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
    ),
''', node_mesh("Mesh", f"{folder}/{root[0]}", root[1], rc, 0)]
        rc = np.zeros(3)
        seat = 0.0
    else:
        nodes = [node_mesh(name, f"{folder}/{root[0]}", root[1], (0, 0, 0), None, tags=["base_part"])]
    for (cname, cglb, cmodel) in children:
        cc, _, _ = centre(cmodel)
        nodes.append(node_mesh(cname, f"{folder}/{cglb}", cmodel, cc - rc, 0))
    for i, (c, s, q) in enumerate(shell.boxes if shell else []):
        nodes.append(node_box(f"Wall {i + 1}", np.asarray(c) - rc, s, q, 0))
    for (dname, dglb, dmodel, dsh, at) in doors:
        dc, _, _ = centre(dmodel)
        di = len(nodes)
        nodes.append(node_mesh(dname, f"{folder}/{dglb}", dmodel, np.asarray(at) + dc - rc, 0))
        for k, (c, s, q) in enumerate(dsh.boxes):
            nodes.append(node_box(f"{dname} Wall {k + 1}", np.asarray(c) - dc, s, q, di))
        children = list(children) + [(dname, dglb, dmodel)]
    for (ename, at) in empties:
        nodes.append(node_empty(ename, np.asarray(at) - rc, 0))
    all_lo, all_hi = lo.copy(), hi.copy()
    for (_, _, cm) in children:
        l2, h2 = cm.bounds()
        all_lo, all_hi = np.minimum(all_lo, l2), np.maximum(all_hi, h2)
    tris = root[1].tris() + sum(cm.tris() for (_, _, cm) in children)
    print(f"{name:14s} seat {seat:+.4f}  box {f3(all_hi - all_lo)}  ground-frame lo {f3(all_lo)} hi {f3(all_hi)}"
          f"  tris {tris}  colliders {len(shell.boxes) if shell else 0}")
    if dry:
        return seat
    for (glb, model) in [root] + [(g, mm) for (_, g, mm) in children]:
        zcheck(model, glb, verbose=True)
        gen_base.write_glb(model.shifted(np.zeros(3)), os.path.join(ROOT, folder, glb))
    with open(os.path.join(PREFABS, f"{name}.prefab.ron"), "w") as f:
        f.write(f"// {about}\n// Written by tools/gen_base_parts.py — edit the generator, not this file.\n[\n")
        f.write("".join(nodes))
        f.write("]\n")
    return seat


def main():
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    if "--only-hub" in sys.argv:
        hm, hsh = base_hub()
        write_part("BaseHub", "BASE HUB — a site operations console; its menu opens the full builder on the base (scripts/base_hub.lua).",
                   ("base_hub.glb", hm), hsh, [], dry, ground_root=True)
        return
    pm, psh = pad_plate()
    write_part("BasePadPlate", "PAD PLATE — a 4 x 4 m precast slab (BASE section, scripts/parts_base.lua).",
               ("pad_plate.glb", pm), psh, [], dry)
    sm, ssh = shed_shell()
    sdm, sdsh, sdat = shed_door()
    write_part("BaseShed", "EQUIPMENT SHED — a 3.0 x 2.4 x 2.6 m steel shelter: its sliding Door, a walkable interior, a Light (scripts/kit_live.lua).",
               ("shed.glb", sm), ssh, [("Interior", "shed_interior.glb", shed_interior())], dry,
               doors=[("Door", "shed_door.glb", sdm, sdsh, sdat)], empties=[("Light", (0.0, SHED["h"] - 0.3, 0.0))], ground_root=True)
    hm, hsh = hab_frame()
    hdm, hdsh, hdat = hab_door()
    write_part("BaseHab", "SURFACE HAB — a 4 x 6 m pressure can on saddles: its hatch Door, a walkable interior, a Light (scripts/kit_live.lua).",
               ("hab_frame.glb", hm), hsh,
               [("Shell", "hab_shell.glb", hab_shell()), ("Interior", "hab_interior.glb", hab_interior())], dry,
               doors=[("Door", "hab_door.glb", hdm, hdsh, hdat)], empties=[("Light", (0.0, HAB["cy"] + HAB["r"] - 0.6, 0.0))], ground_root=True)
    write_stand(dry)
    tm, tsh = tower()
    write_part("BaseTower", "BASE STATION TOWER — a 12 m lattice mast and a 3 m dish (BASE section; scripts/base_tower.lua).",
               ("tower.glb", tm), tsh, [], dry)
    am, ash = solar_array()
    write_part("BaseSolar", "SOLAR ARRAY — a 4.8 m2 single-axis tracker (BASE section; powers a tower on its structure).",
               ("solar_array.glb", am), ash, [], dry)
    im, ish = isotope_skid()
    write_part("BaseIsotope", "ISOTOPE SKID — four Isotope Cells in a caged rack (BASE section; powers a tower on its structure).",
               ("isotope_skid.glb", im), ish, [], dry)
    bm, bsh = battery_bank()
    write_part("BaseBattery", "BATTERY BANK — an outdoor battery cabinet on a skid (BASE section; the base grid's storage, scripts/base_grid.lua).",
               ("battery_bank.glb", bm), bsh, [], dry)
    wm, wsh = shield_wall()
    write_part("BaseShieldWall", "SHIELD WALL — a 2 x 2 x 0.5 m precast shielding block (BASE section; blocks the radiation cone by its record, scripts/base_shield.lua).",
               ("shield_wall.glb", wm), wsh, [], dry)
    hbm, hbsh = base_hub()
    write_part("BaseHub", "BASE HUB — a site operations console; its menu opens the full builder on the base (scripts/base_hub.lua).",
               ("base_hub.glb", hbm), hbsh, [], dry, ground_root=True)
    dm, _ = cable_drum()
    write_part("BaseCableDrum", "CABLE DRUM — the Power Cable's card and hold model (BASE section; the cable itself is a mesh, scripts/base_cable.lua).",
               ("cable_drum.glb", dm), None, [], dry)
    km = build_kit()
    write_part("ItemBuildKit", "BUILD KIT — the Engineer's field tablet, carried by its handle (scripts/field_builder.lua).",
               ("build_kit.glb", km), None, [], dry, folder="models/items")


if __name__ == "__main__":
    main()
