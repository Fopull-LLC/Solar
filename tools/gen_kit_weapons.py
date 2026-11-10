#!/usr/bin/env python3
"""The kit's DEFENCE pieces and the craft Laser Turret (expansion X9; scripts/parts_kit.lua DEFENCE,
scripts/beam.lua, scripts/lasers.lua, scripts/parts_weapons.lua, scripts/laser_turret.lua;
docs/base-building.md §27).

Not run on its own for the kit: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries
for its PIECES table). To write only these, and the turret part:

    python3 tools/gen_kit_weapons.py            # models/kit/lz*  prefabs/KitLz*  fixture rows; PartLaserTurret

KIT PIECES, 1:1 in each piece's ground frame (+Y up, +Z its front). Pulse ports at 0.45 m (PULSE_Y),
beam ports at 1.0 m (BEAM_Y) on the piece's Z faces, heat ports (DN100) at 0.6 m (PIPE_Y):
* Capacitor Bank: an oil-filled can of film capacitors on a skid, ribbed, its HV bushings at ±X.
* Pulse Bus 2 m / 1 m: copper bars on porcelain post insulators, end to end at ±X.
* Laser Emitter: a slab head's housing on a skid: diode-stack fins on top, the beam tube's flange at
  +Z, the pulse bushing at −X, the coolant nozzle at +X.
* Amplifier Stage: a longer gain-slab housing with its flash cassettes, in −Z, out +Z.
* Lens Group: a lens barrel on a pedestal at beam height, flanged both ends.
* Beam Director: a pedestal and a turntable; its YOKE (a fork) and HEAD (the 0.5 m mirror's housing,
  its aperture +Z) are children lasers.lua turns: both centred on the yaw axis, the head on its
  trunnions' axis at 1.75 m, so node:setAngles(yaw, -elevation, 0) is the gimbal.
* Fire Control Console: a desk with its sloped screen and the ARM key.
* Targeting Radar: a pedestal, a fork and a 1.8 m dish looking up 35°.

THE TURRET (a RADIAL VAB part: +X out of the hull, which is at −X): a base ring and pedestal with the
capacitor pod; a "Mount" empty at the pivot (0.12 m out) turned so its +Y is the part's +X; under it
the "Yoke" and the "Head" (a 0.3 m mirror's barrel along +Z, centred on its trunnions), which
laser_turret.lua turns the same way.
"""
import math
import os
import sys

import numpy as np

PULSE_Y = 0.45
BEAM_Y = 1.0
PIPE_Y = 0.6

OLIVE = (0.40, 0.42, 0.34)       # the military's paint, weathered
STEELC = (0.56, 0.57, 0.55)
DARKC = (0.14, 0.14, 0.15)
COPPER = (0.74, 0.44, 0.24)
PORC = (0.84, 0.82, 0.76)        # glazed porcelain
COOL = (0.22, 0.38, 0.62)
WARN = (0.88, 0.70, 0.10)
BLACK = (0.05, 0.05, 0.055)
MIRROR = (0.80, 0.82, 0.84)
RED = (0.75, 0.12, 0.08)

MATERIALS = {}


def pieces(K):
    CModel, Shell, bx, tb = K.CModel, K.Shell, K.bx, K.tb
    lathe = K.lathe
    rot_x, rot_y, rot_z = K.rot_x, K.rot_y, K.rot_z
    out = {}

    def skid(m, sh, x0, x1, z0, z1, h=0.12):
        bx(m, "Steel", DARKC, x0, x1, 0.0, h, z0, z1, sh=sh)

    def bushing(m, at, n, col=PORC):
        """An HV bushing: porcelain sheds along n, a copper stud at its tip on the port."""
        at = np.asarray(at, float)
        n = np.asarray(n, float)
        base = at - n * 0.16
        tb(m, "Steel", col, tuple(base), tuple(at - n * 0.03), 0.05, segs=14)
        for k in range(3):
            c = base + n * (0.03 + 0.04 * k)
            tb(m, "Steel", col, tuple(c), tuple(c + n * 0.015), 0.075, segs=14)
        tb(m, "Steel", COPPER, tuple(at - n * 0.03), tuple(at), 0.03, segs=10)

    def beam_flange(m, z, nz):
        """The beam tube's flange on a Z face at BEAM_Y."""
        tb(m, "Steel", STEELC, (0, BEAM_Y, z - nz * 0.12), (0, BEAM_Y, z - nz * 0.02), 0.09, segs=18)
        tb(m, "Steel", DARKC, (0, BEAM_Y, z - nz * 0.02), (0, BEAM_Y, z), 0.14, segs=20)

    def nozzle(m, x, z, nx, length, r, col):
        p = np.array([x, PIPE_Y, z])
        n = np.array([nx, 0.0, 0.0])
        tb(m, "Steel", col, tuple(p - n * length), tuple(p - n * 0.02), r, segs=14)
        tb(m, "Steel", STEELC, tuple(p - n * 0.02), tuple(p), r * 1.6, segs=16)

    def stripe(m, x0, x1, y0, y1, z):
        for k in range(int((x1 - x0) / 0.1)):
            xa = x0 + k * 0.1
            bx(m, "Steel", WARN if k % 2 == 0 else BLACK, xa, xa + 0.1, y0, y1, z, z + 0.004)

    # ── capacitor bank ──
    def p_cap(mat):
        m, sh = CModel(seed=1901), Shell()
        skid(m, sh, -1.0, 1.0, -0.5, 0.5)
        bx(m, "Steel", OLIVE, -0.85, 0.85, 0.12, 0.92, -0.45, 0.45, sh=sh)
        bx(m, "Steel", DARKC, -0.87, 0.87, 0.9, 0.96, -0.47, 0.47)
        for x in (-0.6, -0.3, 0.0, 0.3, 0.6):
            bx(m, "Steel", OLIVE, x - 0.02, x + 0.02, 0.14, 0.9, -0.47, 0.47)
        # the bushings onto the pulse ports at ±X
        bushing(m, (1.0, PULSE_Y, 0.0), (1, 0, 0))
        bushing(m, (-1.0, PULSE_Y, 0.0), (-1, 0, 0))
        stripe(m, -0.5, 0.5, 0.7, 0.78, 0.45)
        bx(m, "Steel", PORC, -0.2, 0.2, 0.45, 0.6, 0.45, 0.455)
        # the pressure relief and the gauge
        tb(m, "Steel", STEELC, (0.5, 0.96, 0.1), (0.5, 1.0, 0.1), 0.05, segs=12)
        return m, sh, []

    # ── pulse bus ──
    def p_bus(L):
        def fn(mat):
            m, sh = CModel(seed=1911 + int(L)), Shell()
            h = L / 2
            bx(m, "Steel", DARKC, -h + 0.05, h - 0.05, 0.0, 0.06, -0.15, 0.15, sh=sh)
            xs = (-h + 0.25, h - 0.25) if L >= 1.5 else (0.0,)
            for x in xs:
                tb(m, "Steel", PORC, (x, 0.06, 0.0), (x, PULSE_Y - 0.04, 0.0), 0.04, segs=12)
                for k in range(4):
                    y = 0.12 + k * 0.07
                    tb(m, "Steel", PORC, (x, y, 0.0), (x, y + 0.015, 0.0), 0.065, segs=12)
            bx(m, "Steel", COPPER, -h, h, PULSE_Y - 0.04, PULSE_Y + 0.04, -0.06, -0.02)
            bx(m, "Steel", COPPER, -h, h, PULSE_Y - 0.04, PULSE_Y + 0.04, 0.02, 0.06)
            bx(m, "Steel", WARN, -0.08, 0.08, PULSE_Y + 0.05, PULSE_Y + 0.12, -0.002, 0.002)
            return m, sh, []
        return fn

    # ── emitter ──
    def p_emitter(mat):
        m, sh = CModel(seed=1921), Shell()
        skid(m, sh, -0.5, 0.5, -0.75, 0.75)
        bx(m, "Steel", OLIVE, -0.42, 0.42, 0.12, 1.12, -0.68, 0.62, sh=sh)
        bx(m, "Steel", DARKC, -0.44, 0.44, 1.1, 1.15, -0.7, 0.645)
        # diode-stack heat sinks on top
        for k in range(9):
            z = -0.6 + k * 0.14
            bx(m, "Steel", STEELC, -0.36, 0.36, 1.15, 1.3, z - 0.015, z + 0.015)
        # the beam out at +Z
        beam_flange(m, 0.75, 1)
        bx(m, "Steel", DARKC, -0.2, 0.2, BEAM_Y - 0.2, BEAM_Y + 0.2, 0.6, 0.64)
        # the pulse bushing at −X, the coolant at +X
        bushing(m, (-0.5, PULSE_Y, 0.0), (-1, 0, 0))
        nozzle(m, 0.5, 0.0, 1, 0.1, 0.06, COOL)
        tb(m, "Steel", COOL, (0.44, PIPE_Y, 0.0), (0.44, 1.05, -0.3), 0.03, segs=8)
        # the access panel, the interlock lamp, the stencil
        bx(m, "Steel", DARKC, -0.428, -0.42, 0.35, 0.95, -0.4, 0.3)
        bx(m, "Steel", RED, 0.2, 0.28, 0.98, 1.06, 0.62, 0.64)
        stripe(m, -0.4, 0.0, 0.2, 0.28, 0.62)
        return m, sh, []

    # ── amplifier stage ──
    def p_amp(mat):
        m, sh = CModel(seed=1931), Shell()
        skid(m, sh, -0.5, 0.5, -1.0, 1.0)
        bx(m, "Steel", OLIVE, -0.42, 0.42, 0.12, 1.12, -0.86, 0.86, sh=sh)
        bx(m, "Steel", DARKC, -0.44, 0.44, 1.1, 1.15, -0.88, 0.88)
        # the flash-lamp cassettes along its top
        for z in (-0.6, -0.2, 0.2, 0.6):
            bx(m, "Steel", STEELC, -0.3, 0.3, 1.15, 1.3, z - 0.15, z + 0.15)
            bx(m, "Steel", DARKC, -0.32, 0.32, 1.15, 1.18, z - 0.17, z + 0.17)
        beam_flange(m, -1.0, -1)
        beam_flange(m, 1.0, 1)
        bushing(m, (-0.5, PULSE_Y, 0.0), (-1, 0, 0))
        nozzle(m, 0.5, 0.0, 1, 0.1, 0.06, COOL)
        tb(m, "Steel", COOL, (0.44, PIPE_Y, 0.0), (0.44, 1.05, 0.5), 0.03, segs=8)
        tb(m, "Steel", COOL, (0.44, PIPE_Y, 0.0), (0.44, 1.05, -0.5), 0.03, segs=8)
        stripe(m, -0.3, 0.3, 0.25, 0.33, 0.86)
        return m, sh, []

    # ── lens group ──
    def p_lens(mat):
        m, sh = CModel(seed=1941), Shell()
        bx(m, "Steel", DARKC, -0.4, 0.4, 0.0, 0.08, -0.5, 0.5, sh=sh)
        bx(m, "Steel", OLIVE, -0.12, 0.12, 0.08, BEAM_Y - 0.18, -0.25, 0.25, sh=sh)
        b = CModel(seed=1942)
        b.color = STEELC
        lathe(b, "Steel", [(0.17, -0.42), (0.19, -0.38), (0.19, 0.38), (0.17, 0.42)], segs=24)
        b.color = DARKC
        lathe(b, "Steel", [(0.22, -0.5), (0.22, -0.42)], segs=24)
        lathe(b, "Steel", [(0.22, 0.42), (0.22, 0.5)], segs=24)
        b.color = OLIVE
        lathe(b, "Steel", [(0.2, -0.15), (0.24, -0.12), (0.24, 0.12), (0.2, 0.15)], segs=24)
        m.merge(b, M=rot_x(math.pi / 2), t=(0, BEAM_Y, 0))
        # the focus drive on top
        bx(m, "Steel", DARKC, -0.08, 0.08, BEAM_Y + 0.2, 1.3, -0.12, 0.12)
        return m, sh, []

    # ── director ──
    PIV = 1.75

    def p_director(mat):
        m, sh = CModel(seed=1951), Shell()
        bx(m, "Steel", DARKC, -0.75, 0.75, 0.0, 0.12, -0.75, 0.75, sh=sh)
        m.color = OLIVE
        lathe(m, "Steel", [(0.5, 0.12), (0.42, 0.3), (0.34, 1.2), (0.42, 1.25)], segs=32)
        m.color = DARKC
        lathe(m, "Steel", [(0.44, 1.25), (0.44, 1.32)], segs=32)
        sh.add((0, 0.66, 0), (0.7, 1.08, 0.7))
        # the beam's way in: a tube from the −Z port into the pedestal
        beam_flange(m, -0.75, -1)
        tb(m, "Steel", STEELC, (0, BEAM_Y, -0.62), (0, BEAM_Y, -0.3), 0.09, segs=16)
        # the yoke: a turntable and a fork, centred on the yaw axis
        y = CModel(seed=1952)
        y.color = DARKC
        lathe(y, "Steel", [(0.46, 1.32), (0.46, 1.38)], segs=32)
        for s in (-1, 1):
            bx(y, "Steel", OLIVE, s * 0.40 - 0.04, s * 0.40 + 0.04, 1.38, PIV + 0.08, -0.14, 0.14)
            tb(y, "Steel", DARKC, (s * 0.363, PIV, 0), (s * 0.46, PIV, 0), 0.08, segs=14)
        bx(y, "Steel", OLIVE, -0.40, 0.40, 1.383, 1.46, -0.137, 0.137)
        # the head: the mirror's housing along +Z, centred on its trunnions (box-symmetric about the pivot)
        h = CModel(seed=1953)
        hb = CModel(seed=1954)
        hb.color = OLIVE
        lathe(hb, "Steel", [(0.26, -0.48), (0.30, -0.42), (0.30, 0.42), (0.32, 0.46), (0.32, 0.5)], segs=32)
        hb.color = DARKC
        lathe(hb, "Steel", [(0.32, -0.5), (0.26, -0.48)], segs=32)
        lathe(hb, "Steel", [(0.26, -0.48), (0.0, -0.48)], segs=32)        # the back plate (the housing is closed)
        hb.color = BLACK
        lathe(hb, "Steel", [(0.0, 0.46), (0.27, 0.46)], segs=32)
        hb.color = MIRROR
        lathe(hb, "Steel", [(0.0, 0.44), (0.22, 0.44)], segs=32)
        h.merge(hb, M=rot_x(math.pi / 2), t=(0, PIV, 0))
        for s in (-1, 1):
            tb(h, "Steel", DARKC, (s * 0.30, PIV, 0), (s * 0.36, PIV, 0), 0.07, segs=12)
        # the tracker camera on its side, mirrored by a counterweight (keeps the box centred)
        bx(h, "Steel", STEELC, 0.12, 0.24, PIV + 0.28, PIV + 0.32, -0.2, 0.1)
        bx(h, "Steel", STEELC, -0.24, -0.12, PIV - 0.32, PIV - 0.28, -0.1, 0.2)
        return m, sh, [("Yoke", "mesh", (y, (0, 0, 0))), ("Head", "mesh", (h, (0, 0, 0)))]

    # ── console ──
    def p_console(mat):
        m, sh = CModel(seed=1961), Shell()
        bx(m, "Steel", OLIVE, -0.6, 0.6, 0.0, 0.85, -0.4, 0.2, sh=sh)
        bx(m, "Steel", DARKC, -0.62, 0.62, 0.83, 0.88, -0.42, 0.22)
        # the sloped screen and its hood
        M = rot_x(math.radians(-25))
        K.rbox(m, "Steel", DARKC, (0, 1.05, -0.2), (1.1, 0.5, 0.06), M)
        K.rbox(m, "Steel", BLACK, (0, 1.06, -0.165), (0.9, 0.36, 0.01), M)
        # the keys: ARM (red, guarded), FIRE, the lamps
        bx(m, "Steel", RED, 0.3, 0.42, 0.88, 0.92, 0.0, 0.12)
        bx(m, "Steel", WARN, 0.28, 0.44, 0.88, 0.9, -0.02, 0.14)
        for k in range(5):
            bx(m, "Steel", (0.2, 0.6, 0.25) if k % 2 == 0 else STEELC, -0.5 + k * 0.12, -0.44 + k * 0.12, 0.88, 0.91, 0.02, 0.08)
        stripe(m, -0.6, 0.6, 0.05, 0.12, 0.2)
        bx(m, "Steel", DARKC, -0.6, 0.6, 0.0, 0.05, 0.2, 0.4)
        return m, sh, []

    # ── radar ──
    def p_radar(mat):
        m, sh = CModel(seed=1971), Shell()
        bx(m, "Steel", DARKC, -1.0, 1.0, 0.0, 0.12, -1.0, 1.0, sh=sh)
        m.color = OLIVE
        lathe(m, "Steel", [(0.45, 0.12), (0.3, 0.4), (0.25, 1.3), (0.32, 1.35)], segs=28)
        sh.add((0, 0.7, 0), (0.6, 1.2, 0.6))
        for s in (-1, 1):
            bx(m, "Steel", OLIVE, s * 0.55 - 0.04, s * 0.55 + 0.04, 1.35, 1.75, -0.12, 0.12)
        bx(m, "Steel", OLIVE, -0.55, 0.55, 1.353, 1.42, -0.117, 0.117)
        d = CModel(seed=1972)
        d.color = PORC
        prof = [(0.05 + r, 0.32 * (r / 0.9) ** 2) for r in np.linspace(0.0, 0.9, 10)]
        lathe(d, "Steel", prof, segs=40, smooth=True)
        d.color = DARKC
        lathe(d, "Steel", [(0.12, -0.1), (0.12, 0.02)], segs=16)
        tb(d, "Steel", DARKC, (0, 0.05, 0), (0, 0.55, 0), 0.02, segs=8)
        tb(d, "Steel", STEELC, (0, 0.55, 0), (0, 0.65, 0), 0.06, segs=12)
        m.merge(d, M=rot_x(math.radians(-35)), t=(0, 1.75, 0.05))
        return m, sh, []

    out.update({
        "lzCap": (p_cap, ["steel"]),
        "lzBus2": (p_bus(2.0), ["steel"]),
        "lzBus1": (p_bus(1.0), ["steel"]),
        "lzEmitter": (p_emitter, ["steel"]),
        "lzAmp": (p_amp, ["steel"]),
        "lzLens": (p_lens, ["steel"]),
        "lzDirector": (p_director, ["steel"]),
        "lzConsole": (p_console, ["steel"]),
        "lzRadar": (p_radar, ["steel"]),
    })
    return out


# ── the craft turret (gen_part_meshes' primitives and texture sets) ─────────
def turret(G):
    """→ (body, yoke, head, yoke centre, half) in the part frame: body in the part's own frame; yoke
    and head in the GIMBAL frame (Y = the part's +X, Z = its +Z), the head centred on the pivot."""
    from gen_part_meshes import Model, box, tube, lathe, disk
    rot_z = G.rot_z
    body = Model()
    # the base ring on the hull (a disc in the YZ plane at x −0.42..−0.37) and the pedestal
    ring = Model()
    lathe(ring, "Dark", [(0.30, 0.0), (0.33, 0.01), (0.33, 0.05), (0.26, 0.06)], segs=32)
    lathe(ring, "Paint3", [(0.26, 0.06), (0.20, 0.10), (0.18, 0.34), (0.21, 0.37)], segs=28)
    lathe(ring, "Metal", [(0.21, 0.37), (0.21, 0.4)], segs=28)
    body.merge(ring, rot_z(-math.pi / 2), (-0.42, 0.0, 0.0))
    # the capacitor pod beside the pedestal and its cooling fins
    box(body, "Paint3", (-0.27, 0.22, 0.0), (0.24, 0.16, 0.42))
    for k in range(6):
        box(body, "Metal", (-0.27, 0.31, -0.18 + k * 0.072), (0.2, 0.02, 0.012))
    tube(body, "Dark", (-0.27, 0.15, 0.12), (-0.1, 0.06, 0.12), 0.012, segs=6)
    box(body, "Yellow", (-0.15, 0.22, 0.211), (0.02, 0.1, 0.002))
    # the yoke (gimbal frame: Y up the axis; the turntable at y −0.17)
    y = Model()
    lathe(y, "Dark", [(0.21, -0.17), (0.21, -0.13)], segs=28)
    for s in (-1, 1):
        box(y, "Paint3", (s * 0.22, -0.04, 0.0), (0.04, 0.18, 0.12))
        tube(y, "Metal", (s * 0.19, 0.0, 0.0), (s * 0.245, 0.0, 0.0), 0.045, segs=12)
    box(y, "Paint3", (0.0, -0.12, 0.0), (0.46, 0.03, 0.12))
    yoke, yc = G.recenter(y)
    # the head: a 0.3 m mirror's barrel along +Z, centred on the trunnions
    hd = Model()
    b = Model()
    lathe(b, "Paint3", [(0.15, -0.33), (0.17, -0.3), (0.17, 0.3), (0.175, 0.33)], segs=28)
    lathe(b, "BaffleBlack", [(0.0, 0.31), (0.155, 0.31)], segs=28)
    lathe(b, "Mirror", [(0.0, 0.29), (0.12, 0.29)], segs=28)
    lathe(b, "Dark", [(0.175, -0.33), (0.0, -0.33)], segs=28)
    hd.merge(b, G.rot_x(math.pi / 2), (0, 0, 0))
    for s in (-1, 1):
        tube(hd, "Metal", (s * 0.165, 0.0, 0.0), (s * 0.19, 0.0, 0.0), 0.04, segs=10)
    box(hd, "Dark", (0.0, 0.16, -0.12), (0.08, 0.04, 0.16))
    box(hd, "Dark", (0.0, -0.16, 0.12), (0.08, 0.04, 0.16))
    head, hc = G.recenter(hd)
    return body, yoke, yc, head, hc, (0.42, 0.35, 0.36)


def write_turret(dry=False):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_part_meshes as G
    G.MATERIALS.setdefault("BaffleBlack", lambda: G.mat_ron("paint", color=(0.05, 0.05, 0.055), rough=1.3))
    G.MATERIALS.setdefault("Mirror", lambda: G.mat_ron("metal", color=(0.92, 0.93, 0.95), rough=0.25, metal=0.9))
    body, yoke, yc, head, hc, half = turret(G)
    for nm, mm in (("body", body), ("yoke", yoke), ("head", head)):
        mn, mx = mm.bounds()
        print(f"turret {nm:5s} {np.round(mn, 3)} .. {np.round(mx, 3)} tris {mm.tris()}")
    print(f"turret head centre (should be the pivot, 0): {np.round(hc, 4)}")
    if dry:
        return
    bm, bc = G.recenter(body)
    G.write_glb(bm, os.path.join(G.MODELS, "weapon_turret_base.glb"))
    G.write_glb(yoke, os.path.join(G.MODELS, "weapon_turret_yoke.glb"))
    G.write_glb(head, os.path.join(G.MODELS, "weapon_turret_head.glb"))
    piv = 0.12
    q = (0.0, 0.0, round(-math.sqrt(0.5), 6), round(math.sqrt(0.5), 6))     # rot_z(−90°): its +Y = the part's +X
    mount = f"""    (
        name: "Mount",
        transform: (
            translation: ({piv}, 0.0, 0.0),
            rotation: {q},
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
        parent: Some(0),
    ),
"""
    tail = mount
    tail += G.prefab_node("Yoke", "weapon_turret_yoke", yoke, tuple(yc), 2)
    tail += G.prefab_node("Head", "weapon_turret_head", head, (0.0, 0.0, 0.0), 2)
    G.write_prefab("PartLaserTurret", "LASER TURRET — a 0.3 m mirror on a two-axis gimbal, radial: +X out of the hull (parts_weapons laserTurret).",
                   None, half, 0.40, children=[("Body", "weapon_turret_base", bm, bc)], tail_nodes=tail)
    src = open(os.path.join(G.PREFABS, "PartLaserTurret.prefab.ron")).read()
    v = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
    os.makedirs(G.VIS_DIR, exist_ok=True)
    open(os.path.join(G.VIS_DIR, "PartLaserTurret.prefab.ron"), "w").write(
        "// VISUAL-ONLY variant of prefabs/PartLaserTurret.prefab.ron for the builder stand: no body, no scripts.\n"
        "// Written by tools/gen_kit_weapons.py — regenerate, don't edit.\n" + v)
    print("prefab: PartLaserTurret (+ vis)")


def main():
    """Write only this module's pieces (models, prefabs), merge their rows into the fixture, and the turret."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_kit_parts as K
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    mine = pieces(K)
    rows = []
    for piece, (fn, mats) in mine.items():
        if only and piece not in only:
            continue
        for mat in mats:
            K.write_piece(piece, mat, fn, dry, rows)
    if not only or "turret" in only:
        write_turret(dry)
    if dry:
        return
    path = os.path.join(K.ROOT, "tests", "fixtures", "kit_shapes.lua")
    lines = open(path).read().rstrip().split("\n")
    names = {r.split("=")[0].strip() for r in rows}
    keep = [ln for ln in lines if not (ln.strip() and ln.split("=")[0].strip() in names)]
    assert keep[-1].strip() == "}"
    keep = keep[:-1] + rows + ["}"]
    with open(path, "w") as f:
        f.write("\n".join(keep) + "\n")
    print(f"fixture: {len(rows)} rows merged")


if __name__ == "__main__":
    main()
