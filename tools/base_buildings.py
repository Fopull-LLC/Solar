"""The SPACEPORT's structures (tools/gen_base.py writes them out).

Ground frame, metres: the ground is y = 0, the front faces +Z, the lot centre
is x = z = 0. Each builder returns (model, shell, lights).
"""
import math

import numpy as np

from gen_part_meshes import box, disk, lathe, rot_x, rot_z, tube
from base_models import (B, CModel, CONC, CONC_DARK, CONT_BLUE, CONT_RED, DARK, GREY, GREYBLUE, INSUL,  # noqa: F401
                         LAMP_COOL, LAMP_RED, LAMP_WARM, LIGHT, OCHRE, PAINT, RUBBER, RUST_ORANGE, SAFETY,
                         SCORCH, SCREEN, SLATE, TAU, WARM, Shell, T, bollard, cable_tray, cuboid, dish, emblem,
                         hvac, lamp_head, lattice_column, louvre, obstruction, plate, quat_x, railing, region_aspect,
                         stair, wall_pack, yagi)


def vab():
    """VEHICLE ASSEMBLY BUILDING — 24 × 28 m, 21 m high. A high-bay door on
    each end (south to the apron and the runway, north to the crawlerway and
    the pad), framed by a steel door gantry, the lower 6.5 m open; a stair
    tower up the east side to the roof; louvre bands, cable tray, wall packs;
    work platforms and an overhead crane inside. E opens the builder."""
    m, sh = CModel(11), Shell()
    W, D, H, t = 12.0, 14.0, 21.0, 0.6
    DW, DH, OPEN = 6.0, 17.0, 6.5
    B(m, "Concrete", CONC, -W - 0.5, W + 0.5, -0.6, 0.12, -D - 0.5, D + 0.5, sh=sh)
    for sx in (-1, 1):
        x0, x1 = (W - t, W) if sx > 0 else (-W, -W + t)
        B(m, "Clad", PAINT, x0, x1, -0.5, H, -D, D)
        sh.add(((x0 + x1) / 2, H / 2, 0.0), (t, H, 2 * D))
        xo = x1 if sx > 0 else x0
        for k in (-3, -2, 2, 3):
            z = k * 4.0
            B(m, "Steel", GREY, xo, xo + 0.22 * sx, 0.0, H - 0.2, z - 0.25, z + 0.25)
        for k in (-2.5, -1.5, 1.5, 2.5):
            louvre(m, (xo, 18.6, k * 4.0), (0, 0, -sx), 2.6, 1.4, (sx, 0, 0))
        for z in (-10.0, -2.0, 6.0):
            wall_pack(m, (xo, 7.0, z), (sx, 0, 0))
        emblem(m, (xo, 12.0, 0.0), (sx, 0, 0), 3.0)
    cable_tray(m, (W + 0.45, 4.2, -D + 0.8), (W + 0.45, 4.2, D - 0.8))
    for z in np.arange(-D + 1.5, D - 1, 3.0):
        if abs(abs(z) - 8.0) > 0.4 and abs(abs(z) - 12.0) > 0.4:
            B(m, "Steel", DARK, W, W + 0.25, 4.0, 4.06, z - 0.04, z + 0.04, var=False)
    for sx in (-1, 1):
        for sz in (-1, 1):
            B(m, "Steel", GREY, sx * (W - 0.4), sx * (W + 0.3), -0.3, H + 0.95, sz * (D - 0.4), sz * (D + 0.3))
    for sz in (-1, 1):
        z0, z1 = (D - t, D) if sz > 0 else (-D, -D + t)
        zf = z1 if sz > 0 else z0
        for xa, xb in ((-W + t, -DW), (DW, W - t)):
            B(m, "Clad", PAINT, xa, xb, -0.5, H, z0, z1)
            sh.add(((xa + xb) / 2, H / 2, (z0 + z1) / 2), (xb - xa, H, t))
        B(m, "Clad", PAINT, -DW, DW, DH, H, z0, z1, sh=sh)
        zl0, zl1 = (z0 + 0.1, z0 + 0.4) if sz > 0 else (z1 - 0.4, z1 - 0.1)
        zr = zl1 if sz > 0 else zl0
        for k in range(5):
            ya = OPEN + k * (DH - OPEN) / 5
            yb = ya + (DH - OPEN) / 5 - 0.08
            B(m, "Clad", GREYBLUE, -DW + 0.05, DW - 0.05, ya, yb, zl0, zl1)
            for xx in np.arange(-DW + 1.0, DW - 0.5, 1.5):
                B(m, "Steel", SLATE, xx - 0.06, xx + 0.06, ya + (0.5 if k == 0 else 0.1), yb - 0.1, zr, zr + 0.07 * sz)
        sh.add((0.0, (OPEN + DH) / 2, (zl0 + zl1) / 2), (2 * DW, DH - OPEN, 0.3))
        cuboid(m, (0.0, OPEN + 0.2, zr + 0.05 * sz), (sz, 0, 0), (0, 1, 0), 2 * DW - 0.2, 0.36, 0.1,
               faces={"front": ("Sign", (1, 1, 1), "hazard")}, col=DARK)
        for sx in (-1, 1):
            B(m, "Steel", SLATE, sx * (DW + 0.25), sx * (DW + 0.95), 0.0, DH + 0.02, zf, zf + 0.7 * sz)
        B(m, "Steel", SLATE, -DW - 1.2, DW + 1.2, DH + 0.02, DH + 1.15, zf, zf + 0.9 * sz)
        for sx in (-1, 1):
            bollard(m, sx * (DW + 0.6), zf + 1.6 * sz)
            lamp_head(m, (sx * 3.5, DH + 1.6, zf + 0.6 * sz), (0, -0.55, 0.83 * sz), w=0.9, h=0.45)
        right = (sz, 0, 0)
        plate(m, "vab_name", (0.0, 19.3, zf), right, (0, 1, 0), 15.0, depth=0.06)
        plate(m, "bldg1", (sz * (DW + 2.6), 2.4, zf), right, (0, 1, 0), 0.75, depth=0.04)
    B(m, "Concrete", CONC_DARK, -W + t, W - t, H - 0.6, H, -D + t, D - t, sh=sh)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, D - 0.3, D), (-W + 0.4, W - 0.4, -D, -D + 0.3),
                             (W - 0.3, W, -D + 0.4, D - 0.4), (-W, -W + 0.3, -D + 0.4, D - 0.4)):
        B(m, "Clad", PAINT, xa, xb, H, H + 0.8, za, zb)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, D - 0.35, D + 0.05), (-W + 0.4, W - 0.4, -D - 0.05, -D + 0.35),
                             (W - 0.35, W + 0.05, -D + 0.4, D - 0.4), (-W - 0.05, -W + 0.35, -D + 0.4, D - 0.4)):
        B(m, "Steel", GREY, xa, xb, H + 0.8, H + 0.9, za, zb, var=False)
    for (x, z) in ((-6, -7), (-6, 1), (5, -3)):
        hvac(m, x, H, z, 3.4, 2.2, 1.5, fans=2)
    B(m, "Steel", GREY, 7.0, 8.4, H, H + 0.9, 8.0, 9.4)
    for (x, z) in ((-W + 0.6, -D + 0.6), (W - 0.6, -D + 0.6), (W - 0.6, D - 0.6), (-W + 0.6, D - 0.6)):
        T(m, "Steel", GREY, (x, H + 0.95, z), (x, H + 3.5, z), 0.025, segs=6)
    T(m, "Steel", GREY, (9.0, H, 10.0), (9.0, H + 7.0, 10.0), 0.1)
    obstruction(m, (9.0, H + 7.16, 10.0), r=0.13)
    # THE STAIR TOWER up the east wall to the roof
    sx0, sx1, sz0, sz1 = W + 0.7, W + 4.3, -7.0, -2.0
    for (x, z) in ((sx0, sz0), (sx1, sz0), (sx1, sz1), (sx0, sz1)):
        T(m, "Steel", GREY, (x, 0.0, z), (x, H + 1.0, z), 0.09)
    levels = [0.0, 3.5, 7.0, 10.5, 14.0, 17.5, H]
    for i, y in enumerate(levels[1:], 1):
        za, zb = (sz0 + 0.1, sz0 + 1.6) if i % 2 else (sz1 - 1.6, sz1 - 0.1)
        B(m, "Steel", GREY, sx0 + 0.1, sx1 - 0.1, y - 0.12, y, za, zb, var=False, sh=sh)
        railing(m, SAFETY, (sx1 - 0.05, y, sz0 + 0.1), (sx1 - 0.05, y, sz1 - 0.1), h=1.05, posts=1.2, sh=sh)
    for i in range(len(levels) - 1):
        ya, yb = levels[i], levels[i + 1]
        xm = (sx0 + sx1) / 2 + (0.5 if i % 2 else -0.5)
        if i % 2 == 0:
            stair(m, (xm, ya + 0.02, sz1 - 0.3), (xm, yb - 0.14, sz0 + 1.6), 1.0, sh=sh)
        else:
            stair(m, (xm, ya + 0.02, sz0 + 0.3), (xm, yb - 0.14, sz1 - 1.6), 1.0, sh=sh)
    # INSIDE: work platforms down both walls, an overhead crane, strip lights
    for sx in (-1, 1):
        for y in (6.0, 10.5, 15.0):
            x0, x1 = (W - t - 3.2, W - t - 0.02) if sx > 0 else (-W + t + 0.02, -W + t + 3.2)
            B(m, "Steel", GREYBLUE, x0, x1, y, y + 0.3, -9.0, 9.0, var=False, sh=sh)
            xe = x0 + 0.05 if sx > 0 else x1 - 0.05
            railing(m, SAFETY, (xe, y + 0.3, -9.0), (xe, y + 0.3, 9.0), sh=sh)
    for sx in (-1, 1):
        B(m, "Steel", DARK, sx * (W - t - 0.02), sx * (W - t - 0.5), 17.6, 18.1, -D + t + 0.02, D - t - 0.02, var=False)
    B(m, "Steel", OCHRE, -W + t + 0.6, W - t - 0.6, 18.15, 18.95, -0.7, 0.7)
    B(m, "Steel", DARK, -1.4, 1.4, 17.35, 18.15, -1.0, 1.0)
    T(m, "Steel", DARK, (0.0, 17.35, 0.0), (0.0, 12.0, 0.0), 0.04)
    m.color = LAMP_COOL
    for x in (-6.0, 0.0, 6.0):
        for z in (-9.0, -3.0, 3.0, 9.0):
            box(m, "Lamp", (x, H - 0.63, z), (0.5, 0.06, 3.0))
    for (cx, cz, w, d) in ((0, -5.0, 10.4, 0.4), (0, 5.0, 10.4, 0.4), (-5.0, 0, 0.4, 9.6), (5.0, 0, 0.4, 9.6)):
        cuboid(m, (cx, 0.135, cz), (1, 0, 0), (0, 0, -1), w, d, 0.03,
               faces={"front": ("Sign", (1, 1, 1), "hazard")}, col=DARK)
    lights = [("Interior Light", (0.0, 14.0, 0.0), (1.0, 0.95, 0.86), 3.2, 30.0, None)]
    return m, sh, lights


def command_centre():
    """COMMAND CENTRE — 20 × 14 m, two storeys of ribbon glazing between
    slate spandrels, an entrance canopy, the operations room on the ground
    floor (two console rows facing a video wall). On the roof an antenna farm:
    a radome, two dishes, yagi masts, a GPS cluster, cable trays. Beside it a
    16 m communications lattice and a weather station."""
    m, sh = CModel(12), Shell()
    W, D, H, t = 10.0, 7.0, 8.4, 0.4
    B(m, "Concrete", CONC, -W - 0.4, W + 0.4, -0.6, 0.12, -D - 0.4, D + 0.4, sh=sh)
    bands = [(-0.5, 1.0, SLATE), (3.0, 5.0, SLATE), (7.2, H, PAINT)]
    glass = [(1.0, 3.0), (5.0, 7.2)]

    def mullions(xa, xb, ya, yb, z, sz):
        n = max(1, int((xb - xa) / 1.5))
        for k in range(0, n + 1):
            x = xa + k * (xb - xa) / n
            x = min(max(x, xa + 0.05), xb - 0.05)
            B(m, "Steel", DARK, x - 0.05, x + 0.05, ya + 0.08, yb, z, z + 0.09 * sz, var=False)
        B(m, "Steel", DARK, xa, xb, ya - 0.02, ya + 0.08, z, z + 0.12 * sz, var=False)

    for sx in (-1, 1):
        x0, x1 = (W - t, W) if sx > 0 else (-W, -W + t)
        for (ya, yb, c) in bands:
            B(m, "Clad", c, x0, x1, ya, yb, -D, D)
        for (ya, yb) in glass:
            B(m, "Glass", (1, 1, 1), x0 + 0.08, x1 - 0.08, ya, yb, -D + 0.35, D - 0.35)
        sh.add(((x0 + x1) / 2, H / 2, 0.0), (t, H, 2 * D))
        xo = x1 if sx > 0 else x0
        for (ya, yb) in glass:
            n = 7
            for k in range(n + 1):
                z = -D + 0.6 + k * (2 * D - 1.2) / n
                B(m, "Steel", DARK, xo, xo + 0.09 * sx, ya, yb, z - 0.05, z + 0.05, var=False)

    def wall_z(sz, door):
        z0, z1 = (D - t, D) if sz > 0 else (-D, -D + t)
        zo = z1 if sz > 0 else z0
        segs = [(-W + t, -2.2), (2.2, W - t)] if door else [(-W + t, W - t)]
        for (xa, xb) in segs:
            for (ya, yb, c) in bands:
                B(m, "Clad", c, xa, xb, ya, yb, z0, z1)
            for (ya, yb) in glass:
                B(m, "Glass", (1, 1, 1), xa, xb, ya, yb, z0 + 0.08, z1 - 0.08)
                mullions(xa, xb, ya, yb, zo, sz)
            sh.add(((xa + xb) / 2, H / 2, (z0 + z1) / 2), (xb - xa, H, t))
        if door:
            B(m, "Clad", SLATE, -2.2, 2.2, 3.3, 5.0, z0, z1)
            B(m, "Glass", (1, 1, 1), -2.2, 2.2, 5.0, 7.2, z0 + 0.08, z1 - 0.08)
            mullions(-2.2, 2.2, 5.0, 7.2, zo, sz)
            B(m, "Clad", PAINT, -2.2, 2.2, 7.2, H, z0, z1)
            sh.add((0.0, (3.3 + H) / 2, (z0 + z1) / 2), (4.4, H - 3.3, t))
            for xa in (-2.35, 2.15):
                B(m, "Steel", DARK, xa, xa + 0.2, 0.0, 3.32, z0 - 0.05, z1 + 0.05, var=False)
            B(m, "Steel", DARK, -2.4, 2.4, 3.32, 3.5, z0 - 0.06, z1 + 0.06, var=False)
            for s in (-1, 1):
                B(m, "Glass", (1, 1, 1), 1.95 * s - 0.03, 1.95 * s + 0.03, 0.14, 3.2, z1 + 0.06, z1 + 1.0)
                B(m, "Steel", DARK, 1.95 * s - 0.05, 1.95 * s + 0.05, 0.14, 3.2, z1 + 1.0, z1 + 1.08, var=False)

    wall_z(-1, False)
    wall_z(1, True)
    for sx in (-1, 1):
        for sz in (-1, 1):
            B(m, "Steel", GREY, sx * (W - 0.46), sx * (W + 0.15), -0.3, H + 0.95, sz * (D - 0.46), sz * (D + 0.15))
    plate(m, "cmd_name", (0.0, 8.15, D), (1, 0, 0), (0, 1, 0), 8.5, depth=0.06)
    plate(m, "bldg2", (3.4, 2.0, D), (1, 0, 0), (0, 1, 0), 0.6, depth=0.04)
    emblem(m, (-6.4, 6.1, D + 0.1), (0, 0, 1), 0.85, depth=0.05)
    B(m, "Concrete", CONC_DARK, -W + t, W - t, H - 0.4, H, -D + t, D - t, sh=sh)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, -D, -D + 0.25), (-W + 0.4, W - 0.4, D - 0.25, D),
                             (W - 0.25, W, -D + 0.4, D - 0.4), (-W, -W + 0.25, -D + 0.4, D - 0.4)):
        B(m, "Clad", PAINT, xa, xb, H, H + 0.8, za, zb)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, -D - 0.05, -D + 0.3), (-W + 0.4, W - 0.4, D - 0.3, D + 0.05),
                             (W - 0.3, W + 0.05, -D + 0.4, D - 0.4), (-W - 0.05, -W + 0.3, -D + 0.4, D - 0.4)):
        B(m, "Steel", GREY, xa, xb, H + 0.8, H + 0.88, za, zb, var=False)
    B(m, "Concrete", LIGHT, -W + t + 0.02, W - t - 0.02, 3.9, 4.2, -D + t + 0.02, D - t - 0.02)
    m.color = LAMP_COOL
    for x in (-6, -2, 2, 6):
        for z in (-3.5, 0.0, 3.5):
            box(m, "Lamp", (x, 3.88, z), (1.2, 0.03, 0.3))
    B(m, "Steel", PAINT, -3.5, 3.5, 3.55, 3.85, D + 0.12, D + 3.2)
    B(m, "Steel", SLATE, -3.55, 3.55, 3.85, 3.95, D + 0.1, D + 3.25, var=False)
    for s in (-1, 1):
        T(m, "Steel", GREY, (3.1 * s, 0.12, D + 2.9), (3.1 * s, 3.55, D + 2.9), 0.12)
        bollard(m, 3.1 * s, D + 4.4)
    m.color = LAMP_WARM
    for x in (-1.5, 0.0, 1.5):
        box(m, "Lamp", (x, 3.535, D + 1.6), (0.5, 0.03, 0.5))
    B(m, "Steel", RUBBER, -6.5, 6.5, 0.7, 3.7, -D + t + 0.02, -D + t + 0.14, var=False)
    for k, (xa, xb) in enumerate(((-6.3, -2.2), (-2.05, 2.05), (2.2, 6.3))):
        cuboid(m, ((xa + xb) / 2, 2.2, -D + t + 0.155), (1, 0, 0), (0, 1, 0), xb - xa, 2.8, 0.02,
               faces={"front": ("Screen", (1, 1, 1), ("wall_l", "wall_c", "wall_r")[k])}, col=RUBBER)
    for z in (-1.5, 1.6):
        B(m, "Steel", GREY, -5.5, 5.5, 0.12, 0.85, z - 0.45, z + 0.45, sh=sh, var=False)
        B(m, "Steel", DARK, -5.55, 5.55, 0.85, 0.9, z - 0.5, z + 0.5, var=False)
        for k in range(6):
            x = -4.6 + k * 1.84
            mm = rot_x(math.radians(-12))
            # the monitor's FACE toward the operators' chairs (+z), its back
            # to the video wall
            mm = rot_x(math.radians(12))
            m.color = DARK
            box(m, "Steel", (x, 1.27, z - 0.2), (1.2, 0.72, 0.06), M=mm)
            up = mm @ np.array([0.0, 1.0, 0.0])
            fwd = mm @ np.array([0.0, 0.0, 1.0])
            cuboid(m, np.array([x, 1.27, z - 0.2]) + fwd * 0.04, (1, 0, 0), up, 1.08, 0.6, 0.02,
                   faces={"front": ("Screen", (1, 1, 1), "con_%d" % (k % 3))}, col=DARK)
            m.color = DARK
            box(m, "Steel", (x, 0.98, z - 0.24), (0.12, 0.3, 0.08))
        for k in range(5):
            x = -4.6 + k * 2.3
            B(m, "Steel", DARK, x - 0.3, x + 0.3, 0.12, 0.55, z + 0.7, z + 1.3, var=False)
            B(m, "Steel", DARK, x - 0.3, x + 0.3, 0.55, 1.2, z + 1.31, z + 1.39, var=False)
    # ROOF: the antenna farm
    sub = CModel(); sub.color = PAINT; sub.ground = False
    prof = [(1.5 * math.sin(a), 1.5 * math.cos(a)) for a in np.linspace(0, math.pi * 0.62, 10)]
    lathe(sub, "Steel", prof[::-1], segs=24, smooth=True)
    m.merge(sub, None, (5.5, H + 1.65, -3.6))
    T(m, "Concrete", LIGHT, (5.5, H, -3.6), (5.5, H + 1.1, -3.6), 1.3, segs=24)
    for (x, z, ax) in ((-2.0, -4.2, (0.3, 0.6, 0.74)), (1.2, -4.4, (-0.4, 0.7, 0.6))):
        T(m, "Steel", GREY, (x, H, z), (x, H + 1.3, z), 0.09)
        dish(m, (x, H + 1.4, z), ax, 1.1, 0.8)
    for (x, z) in ((-7.4, -4.6), (-7.4, 3.6)):
        T(m, "Steel", GREY, (x, H, z), (x, H + 7.5, z), 0.07)
        for y in (H + 3.0, H + 5.0, H + 7.0):
            yagi(m, (x + 0.08, y, z), (1, 0, 0.2), n=7, L=1.6)
    obstruction(m, (-7.4, H + 7.66, -4.6))
    for k in range(4):
        x = 2.0 + k * 0.5
        T(m, "Steel", PAINT, (x, H, 3.5), (x, H + 0.45, 3.5), 0.05, segs=10)
        T(m, "Steel", LIGHT, (x, H + 0.45, 3.5), (x, H + 0.55, 3.5), 0.09, segs=12)
    hvac(m, -2.5, H, 2.0, 3.0, 2.0, 1.3, fans=2)
    cable_tray(m, (-7.2, H + 0.35, -4.0), (4.0, H + 0.35, -4.0), w=0.35)
    cable_tray(m, (-1.0, H + 0.35, -3.55), (-1.0, H + 0.35, 0.8), w=0.35)
    # THE COMMS LATTICE east of the building
    cx, cz = W + 4.2, -3.0
    B(m, "Concrete", CONC, cx - 1.8, cx + 1.8, -0.4, 0.3, cz - 1.8, cz + 1.8)
    lattice_column(m, LIGHT, (cx, 0.3, cz), 16.0, 1.4, step=2.6, r=0.07, rb=0.035)
    for y in (6.0, 10.0, 14.0):
        yagi(m, (cx + 0.75, y, cz), (1, 0.05, 0), n=8, L=2.0)
    dish(m, (cx - 0.95, 12.0, cz), (-0.8, 0.3, 0.5), 0.8, 0.6)
    B(m, "Steel", GREY, cx - 0.75, cx + 0.75, 16.0, 16.1, cz - 0.75, cz + 0.75, var=False)
    T(m, "Steel", LIGHT, (cx, 16.1, cz), (cx, 18.2, cz), 0.06, segs=8)
    obstruction(m, (cx, 18.36, cz))
    sh.add((cx, 8.0, cz), (1.6, 16.0, 1.6))
    # THE WEATHER STATION west of the building
    wx, wz = -W - 4.0, 2.0
    B(m, "Concrete", CONC, wx - 1.2, wx + 1.2, -0.4, 0.15, wz - 1.2, wz + 1.2)
    T(m, "Steel", LIGHT, (wx, 0.15, wz), (wx, 9.5, wz), 0.06, segs=8)
    T(m, "Steel", LIGHT, (wx - 0.8, 9.3, wz), (wx + 0.8, 9.3, wz), 0.025, segs=6)
    for k in range(3):
        a = k * TAU / 3
        T(m, "Steel", GREY, (wx + 0.8, 9.55, wz), (wx + 0.8 + math.cos(a) * 0.22, 9.55, wz + math.sin(a) * 0.22), 0.008, segs=4)
        sub = CModel(); sub.color = GREY; sub.ground = False
        lathe(sub, "Steel", [(0.0, 0.0), (0.05, 0.02), (0.06, 0.06)], segs=10)
        m.merge(sub, rot_z(math.pi / 2), (wx + 0.8 + math.cos(a) * 0.22, 9.55, wz + math.sin(a) * 0.22))
    T(m, "Steel", GREY, (wx + 0.8, 9.3, wz), (wx + 0.8, 9.55, wz), 0.015, segs=5)
    T(m, "Steel", GREY, (wx - 0.8, 9.3, wz), (wx - 0.8, 9.6, wz), 0.012, segs=5)
    B(m, "Steel", GREY, wx - 1.05, wx - 0.55, 9.5, 9.7, wz - 0.01, wz + 0.01, var=False)
    for (dx, dz) in ((-0.3, 0.9), (0.3, 0.9), (-0.3, 1.5), (0.3, 1.5)):
        T(m, "Steel", LIGHT, (wx + dx, 0.15, wz + dz), (wx + dx, 1.25, wz + dz), 0.025, segs=5)
    B(m, "Clad", PAINT, wx - 0.4, wx + 0.4, 1.25, 1.9, wz + 0.8, wz + 1.6)
    B(m, "Steel", PAINT, wx - 0.45, wx + 0.45, 1.9, 1.96, wz + 0.75, wz + 1.65, var=False)
    m.color = (0.08, 0.10, 0.16)
    box(m, "Glass", (wx, 3.2, wz - 0.25), (0.7, 0.03, 0.5), M=rot_x(math.radians(-40)))
    T(m, "Steel", PAINT, (wx + 0.9, 0.15, wz - 1.0), (wx + 0.9, 1.0, wz - 1.0), 0.1, segs=12)
    lights = [("Interior Light", (0.0, 3.2, 0.0), (1.0, 0.93, 0.82), 2.4, 16.0, None)]
    return m, sh, lights


def depot():
    """COMMERCE DEPOT — a 16 × 12 m clad warehouse, a roll-up door to the
    front (open to 4.6 m: you walk in to the counter), a loading dock down the
    east side with levellers and dock lights, a gantry crane over the cargo
    pad beyond it, two containers waiting on the west side."""
    m, sh = CModel(13), Shell()
    W, D, H, t = 8.0, 6.0, 7.5, 0.4
    DW, DH = 3.0, 4.6
    B(m, "Concrete", CONC, -W - 0.4, W + 0.4, -0.6, 0.12, -D - 0.4, D + 0.4, sh=sh)
    for sx in (-1, 1):
        x0, x1 = (W - t, W) if sx > 0 else (-W, -W + t)
        B(m, "Clad", WARM, x0, x1, -0.5, H, -D, D)
        sh.add(((x0 + x1) / 2, H / 2, 0.0), (t, H, 2 * D))
    B(m, "Clad", WARM, -W + t, W - t, -0.5, H, -D, -D + t, sh=sh)
    z0, z1 = D - t, D
    for (xa, xb) in ((-W + t, -DW - 0.25), (DW + 0.25, W - t)):
        B(m, "Clad", WARM, xa, xb, -0.5, H, z0, z1)
        sh.add(((xa + xb) / 2, H / 2, (z0 + z1) / 2), (xb - xa, H, t))
    B(m, "Clad", WARM, -DW - 0.25, DW + 0.25, DH + 0.25, H, z0, z1, sh=sh)
    for sx in (-1, 1):
        for sz in (-1, 1):
            B(m, "Steel", GREY, sx * (W - 0.46), sx * (W + 0.15), -0.3, H + 0.6, sz * (D - 0.46), sz * (D + 0.15))
    for sx in (-1, 1):
        B(m, "Steel", DARK, sx * DW, sx * (DW + 0.25), 0.0, DH, z0 - 0.05, z1 + 0.12, var=False)
        bollard(m, sx * (DW + 0.55), D + 0.5)
    B(m, "Steel", DARK, -DW - 0.25, DW + 0.25, DH, DH + 0.25, z0 - 0.05, z1 + 0.12, var=False)
    B(m, "Steel", GREY, -DW, DW, DH - 0.05, DH + 0.6, z0 - 0.75, z0 - 0.08)
    for k in range(4):
        ya = DH - 0.8 + k * 0.2
        B(m, "Steel", GREYBLUE, -DW + 0.03, DW - 0.03, ya, ya + 0.18, z0 + 0.02, z0 + 0.1, var=False)
    lamp_head(m, (0.0, DH + 0.9, z1 + 0.45), (0, -0.7, 0.7), w=0.8, h=0.35)
    plate(m, "depot_name", (0.0, 6.0, z1), (1, 0, 0), (0, 1, 0), 5.6, depth=0.05)
    plate(m, "bldg3", (-DW - 1.2, 2.0, z1), (1, 0, 0), (0, 1, 0), 0.6, depth=0.04)
    for x in (-6.0, 6.0):
        wall_pack(m, (x, 4.0, z1), (0, 0, 1))
    B(m, "Concrete", CONC_DARK, -W + t, W - t, H - 0.3, H, -D + t, D - t, sh=sh)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, D - 0.2, D), (-W + 0.4, W - 0.4, -D, -D + 0.2),
                             (W - 0.2, W, -D + 0.4, D - 0.4), (-W, -W + 0.2, -D + 0.4, D - 0.4)):
        B(m, "Clad", WARM, xa, xb, H, H + 0.5, za, zb)
    for (xa, xb, za, zb) in ((-W + 0.4, W - 0.4, D - 0.25, D + 0.05), (-W + 0.4, W - 0.4, -D - 0.05, -D + 0.25),
                             (W - 0.25, W + 0.05, -D + 0.4, D - 0.4), (-W - 0.05, -W + 0.25, -D + 0.4, D - 0.4)):
        B(m, "Steel", GREY, xa, xb, H + 0.5, H + 0.58, za, zb, var=False)
    hvac(m, -3.5, H, -2.0, 2.6, 1.8, 1.1, fans=1)
    for x in (2.0, 4.0):
        T(m, "Steel", GREY, (x, H, -3.0), (x, H + 1.0, -3.0), 0.12, segs=10)
        T(m, "Steel", GREY, (x, H + 1.0, -3.0), (x + 0.35, H + 1.2, -3.0), 0.11, segs=10)
    for x in (-W + 0.7, W - 0.7):
        T(m, "Steel", GREY, (x, 0.15, D + 0.12), (x, H, D + 0.12), 0.07, segs=8)
    # TWO COUNTERS: BUY on the left as you come in, SELL on the right, each
    # with its plate hung over it (scripts' marker nodes "Depot Buy Counter" /
    # "Depot Sell Counter" stand at their fronts)
    for (xa, xb, reg) in ((-4.2, -0.9, "buy"), (0.9, 4.2, "sell")):
        B(m, "Steel", SLATE, xa, xb, 0.12, 1.05, -1.2, -0.5, sh=sh, var=False)
        B(m, "Steel", DARK, xa - 0.1, xb + 0.1, 1.05, 1.12, -1.25, -0.45, var=False)
        for xx in (xa + 0.3, xb - 0.3):
            T(m, "Steel", GREY, (xx, 1.12, -0.85), (xx, 2.6, -0.85), 0.025, segs=6)
        plate(m, reg, ((xa + xb) / 2, 2.85, -0.85), (1, 0, 0), (0, 1, 0), 2.0, depth=0.04)
        mt = rot_x(math.radians(-15))
        cuboid(m, ((xa + xb) / 2, 1.4, -0.95), (1, 0, 0), mt @ np.array([0.0, 1.0, 0.0]), 0.7, 0.42, 0.04,
               faces={"front": ("Screen", (1, 1, 1), "trade_" + reg)}, col=DARK)
    for x in (-6.0, -3.0, 3.0, 6.0):
        for y in (0.12, 1.5, 2.9):
            B(m, "Steel", OCHRE, x - 1.15, x + 1.15, y + 0.01, y + 0.08, -5.5, -4.4, var=False)
            if y < 2.9:
                B(m, "Steel", (0.50, 0.40, 0.28), x - 0.9, x - 0.1, y + 0.08, y + 0.9, -5.4, -4.6)
                B(m, "Steel", (0.40, 0.44, 0.34), x + 0.1, x + 0.9, y + 0.08, y + 0.7, -5.4, -4.6)
        for xx in (x - 1.25, x + 1.2):
            B(m, "Steel", GREY, xx, xx + 0.05, 0.12, 3.0, -5.55, -5.48, var=False)
            B(m, "Steel", GREY, xx, xx + 0.05, 0.12, 3.0, -4.42, -4.35, var=False)
    m.color = LAMP_COOL
    for x in (-4.0, 0.0, 4.0):
        box(m, "Lamp", (x, H - 0.33, 0.0), (0.4, 0.04, 2.4))
    B(m, "Concrete", CONC, W + 0.15, W + 3.5, -0.55, 1.2, -5.0, 5.0, sh=sh)
    cuboid(m, (W + 3.42, 1.21, 0.0), (0, 0, 1), (-1, 0, 0), 10.0, 0.16, 0.02,
           faces={"front": ("Sign", (1, 1, 1), "hazard")}, col=DARK)
    for z in (-2.5, 2.5):
        B(m, "Clad", GREYBLUE, W + 0.02, W + 0.1, 1.25, 4.4, z - 1.5, z + 1.5)
        B(m, "Steel", GREY, W + 0.15, W + 2.2, 1.21, 1.25, z - 1.0, z + 1.0, var=False)
        B(m, "Steel", RUBBER, W + 3.5, W + 3.72, 0.35, 1.05, z - 1.6, z - 1.25, var=False)
        B(m, "Steel", RUBBER, W + 3.5, W + 3.72, 0.35, 1.05, z + 1.25, z + 1.6, var=False)
        lamp_head(m, (W + 0.4, 4.9, z + 1.8), (0.6, -0.8, 0.0), w=0.4, h=0.25)
    railing(m, SAFETY, (W + 0.25, 1.2, -4.9), (W + 3.4, 1.2, -4.9), h=1.0, sh=sh)
    stair(m, (W + 1.9, 0.0, 6.6), (W + 1.9, 1.2, 5.05), 1.1, sh=sh)
    gx0, gx1 = W + 5.0, W + 12.5
    for x in (gx0, gx1):
        for z in (-5.0, 5.0):
            B(m, "Steel", OCHRE, x - 0.25, x + 0.25, 0.4, 9.0, z - 0.25, z + 0.25, var=False)
            B(m, "Steel", DARK, x - 0.45, x + 0.45, 0.0, 0.4, z - 0.6, z + 0.6, var=False)
        B(m, "Steel", OCHRE, x - 0.18, x + 0.18, 0.9, 1.25, -4.75, 4.75, var=False)
        T(m, "Steel", OCHRE, (x, 1.3, -4.7), (x, 8.6, 4.7), 0.08, segs=6)
        T(m, "Steel", DARK, (x, 0.0, -9.0), (x, 0.08, 9.0), 0.06, segs=6)
    for z in (-5.0, 5.0):
        B(m, "Steel", OCHRE, gx0 - 0.6, gx1 + 0.6, 9.0, 9.9, z - 0.35, z + 0.35, var=False)
    xm = (gx0 + gx1) / 2
    B(m, "Steel", OCHRE, xm - 1.0, xm + 1.0, 9.9, 10.7, -5.6, 5.6, var=False)
    B(m, "Steel", DARK, xm - 0.6, xm + 0.6, 7.9, 8.95, -0.6, 0.6, var=False)
    T(m, "Steel", DARK, (xm, 7.9, 0.0), (xm, 4.0, 0.0), 0.03)
    B(m, "Steel", OCHRE, xm - 0.5, xm + 0.5, 3.6, 4.0, -0.3, 0.3, var=False)
    B(m, "Steel", GREY, gx1 - 0.8, gx1 + 0.8, 6.8, 8.2, 4.05, 4.7)
    m.color = (0.10, 0.12, 0.15)
    box(m, "Glass", (gx1, 7.6, 4.03), (1.4, 0.8, 0.02))
    for k in range(9):
        y = 0.6 + k * 0.7
        T(m, "Steel", DARK, (gx1 + 0.3, y, 5.4), (gx1 - 0.3, y, 5.4), 0.02, segs=4)
    obstruction(m, (gx1 + 0.3, 10.86, 5.0))
    for (z, col) in ((-2.8, CONT_RED), (0.2, CONT_BLUE)):
        B(m, "Clad", col, -W - 3.1, -W - 0.7, 0.04, 2.6, z, z + 2.45, sh=sh)
        for (xx, zz) in ((-W - 3.1, z), (-W - 0.7, z), (-W - 3.1, z + 2.45), (-W - 0.7, z + 2.45)):
            for yy in (0.04, 2.6):
                B(m, "Steel", DARK, xx - 0.07, xx + 0.07, yy - 0.07, yy + 0.07, zz - 0.07, zz + 0.07, var=False)
    lights = [("Interior Light", (0.0, 5.0, 0.0), (1.0, 0.94, 0.84), 2.2, 14.0, None)]
    markers = [("Depot Buy Counter", (-2.55, 0.12, -0.2)), ("Depot Sell Counter", (2.55, 0.12, -0.2))]
    return m, sh, lights, markers


def tracking():
    """TRACKING STATION — an 11 m Cassegrain dish on an azimuth alidade over an
    octagonal concrete pedestal: two A-frame side towers carry the elevation
    bearings 7.2 m up, a sector gear and counterweight ride behind the dish,
    which is tipped 40° toward the front. A stair climbs to the pedestal deck.
    The equipment shelter stands behind, its cable tray running to the base.
    The ground station's comms point is the prefab origin + 6 m."""
    m, sh = CModel(14), Shell()
    B(m, "Concrete", CONC, -3.6, 3.6, -0.6, 0.25, -3.6, 3.6)
    sub = CModel(14); sub.color = CONC
    lathe(sub, "Concrete", [(2.9, 0.25), (2.6, 3.4)], segs=8, a0=math.pi / 8, a1=math.pi / 8 + TAU, uv_m=0.25)
    sub.color = CONC_DARK
    disk(sub, "Concrete", 2.6, 3.4, segs=8, up=True, uv_m=0.25)
    m.merge(sub)
    sh.add((0.0, 1.8, 0.0), (5.0, 3.2, 5.0))
    m.color = DARK
    rot = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1.0]])
    box(m, "Steel", (0.0, 1.3, 2.80), (1.0, 2.1, 0.08), M=rot @ rot_x(math.atan2(0.3, 3.15)))
    for k in range(8):
        a0 = math.pi / 8 + k * TAU / 8
        a1 = a0 + TAU / 8
        am = (a0 + a1) / 2
        if math.hypot(2.4 * math.cos(am) + 1.4, 2.4 * math.sin(am) - 2.3) > 1.0:   # open where the stair lands
            railing(m, SAFETY, (2.4 * math.cos(a0), 3.4, 2.4 * math.sin(a0)), (2.4 * math.cos(a1), 3.4, 2.4 * math.sin(a1)),
                    h=1.0, posts=2.0, sh=sh)
    stair(m, (-1.4, 0.27, 6.4), (-1.4, 3.4, 2.75), 0.9, sh=sh)
    T(m, "Steel", GREY, (0, 3.42, 0), (0, 3.9, 0), 2.1, segs=28)
    T(m, "Steel", DARK, (0, 3.9, 0), (0, 4.0, 0), 2.15, segs=28)
    for sx in (-1, 1):
        for sz in (-1, 1):
            T(m, "Steel", PAINT, (1.55 * sx, 4.5, 1.3 * sz), (1.55 * sx, 7.0, 0.2 * sz), 0.16, segs=8)
        T(m, "Steel", PAINT, (1.55 * sx, 4.75, -1.1), (1.55 * sx, 4.75, 1.1), 0.1, segs=8)
        T(m, "Steel", GREY, (1.15 * sx, 7.2, 0.0), (2.0 * sx, 7.2, 0.0), 0.42, segs=16)
    B(m, "Steel", PAINT, -1.75, 1.75, 4.0, 4.5, -1.45, 1.45)
    B(m, "Steel", GREY, -1.0, 1.0, 4.5, 5.6, -1.6, -0.4)
    el = math.radians(40.0)
    M = rot_x(-(math.pi / 2 - el))
    c = np.array([0.0, 7.2, 0.0])
    R, f = 5.5, 4.4
    dsh = CModel(15); dsh.color = PAINT; dsh.ground = False
    prof = [(r, r * r / (4 * f)) for r in np.linspace(0.0, R, 14)]
    lathe(dsh, "Steel", prof, segs=48, smooth=True, inward=True)
    lathe(dsh, "Steel", [(r, y - 0.08) for r, y in prof], segs=48, smooth=True)
    rim = R * R / (4 * f)
    lathe(dsh, "Steel", [(R, rim - 0.08), (R + 0.07, rim - 0.04), (R, rim)], segs=48)
    dsh.color = GREY
    lathe(dsh, "Steel", [(1.0, -1.2), (1.2, -0.12)], segs=16)
    disk(dsh, "Steel", 1.0, -1.2, segs=16, up=False)
    for k in range(16):
        a = k * TAU / 16
        ca, sa = math.cos(a), math.sin(a)
        r1 = R * 0.95
        p0 = np.array([1.1 * ca, -0.9, 1.1 * sa])
        p1 = np.array([r1 * ca, r1 * r1 / (4 * f) - 0.14, r1 * sa])
        pm = np.array([r1 * 0.55 * ca, (r1 * 0.55) ** 2 / (4 * f) - 0.12, r1 * 0.55 * sa])
        tube(dsh, "Steel", p0, p1, 0.045, segs=5)
        tube(dsh, "Steel", p0 + (p1 - p0) * 0.02, pm, 0.035, segs=5)
        if k % 2 == 0:
            b = (k + 2) * TAU / 16
            q1 = np.array([r1 * 0.55 * math.cos(b), (r1 * 0.55) ** 2 / (4 * f) - 0.12, r1 * 0.55 * math.sin(b)])
            tube(dsh, "Steel", pm, q1, 0.03, segs=4)
    dsh.color = LIGHT
    for k in range(4):
        a = k * TAU / 4 + TAU / 8
        p0 = np.array([R * 0.78 * math.cos(a), (R * 0.78) ** 2 / (4 * f), R * 0.78 * math.sin(a)])
        tube(dsh, "Steel", p0, (0, f - 0.45, 0), 0.06, segs=6)
    lathe(dsh, "Steel", [(0.2, f - 0.62), (0.45, f - 0.45), (0.7, f - 0.42)], segs=24)
    lathe(dsh, "Steel", [(0.7, f - 0.42), (0.18, f - 0.40)], segs=24)
    dsh.color = GREY
    tube(dsh, "Steel", (0, 0.0, 0), (0, 1.2, 0), 0.38, segs=16, r1=0.22)
    dsh.color = GREY
    for sx in (-1, 1):                                                   # counterweight arms
        tube(dsh, "Steel", (0.7 * sx, -1.1, 0.0), (0.7 * sx, -2.9, 0.0), 0.1, segs=8)
    box(dsh, "Steel", (0.0, -3.25, 0.0), (2.2, 0.7, 1.3))
    m.merge(dsh, M, c + M @ np.array([0.0, -0.3, 0.0]))

    B(m, "Clad", PAINT, -2.6, 2.6, -0.4, 3.0, -9.0, -5.2, sh=sh)
    B(m, "Steel", GREY, -2.7, 2.7, 3.0, 3.15, -9.1, -5.1, var=False)
    B(m, "Steel", DARK, -0.5, 0.5, 0.0, 2.2, -5.2, -5.12, var=False)
    hvac(m, 3.25, 0.05, -7.1, 1.1, 1.6, 1.4, fans=1)
    lamp_head(m, (0.0, 2.55, -4.95), (0, -0.5, 0.86), w=0.5, h=0.3)
    T(m, "Steel", GREY, (-2.2, 3.15, -8.5), (-2.2, 6.2, -8.5), 0.04)
    plate(m, "track_name", (0.0, 2.75, -5.2), (1, 0, 0), (0, 1, 0), 3.4, depth=0.04)
    plate(m, "bldg4", (1.4, 1.7, -5.2), (1, 0, 0), (0, 1, 0), 0.5, depth=0.04)
    cable_tray(m, (1.8, 0.6, -5.15), (1.8, 0.6, -3.05), w=0.3)
    return m, sh, []


def power():
    """POWER STATION — a switch house, three oil-filled transformers with their
    radiator banks and bushings under a bus gantry, a fenced yard with its
    warning plate, two rows of ground-mounted solar tables."""
    m, sh = CModel(16), Shell()
    B(m, "Concrete", CONC, -9.0, 9.0, -0.6, 0.1, -6.0, 6.0)
    B(m, "Clad", GREYBLUE, -8.5, -2.5, -0.4, 4.2, -5.5, -1.0, sh=sh)
    B(m, "Steel", GREY, -8.6, -2.4, 4.2, 4.35, -5.6, -0.9, var=False)
    B(m, "Steel", DARK, -6.0, -5.0, 0.1, 2.3, -0.98, -0.9, var=False)
    louvre(m, (-3.6, 2.6, -1.0), (1, 0, 0), 1.0, 1.0, (0, 0, 1))
    louvre(m, (-7.6, 2.6, -1.0), (1, 0, 0), 1.0, 1.0, (0, 0, 1))
    lamp_head(m, (-5.5, 2.7, -0.75), (0, -0.5, 0.86), w=0.5, h=0.3)
    plate(m, "power_name", (-5.5, 3.6, -1.0), (1, 0, 0), (0, 1, 0), 3.2, depth=0.04)
    plate(m, "bldg5", (-4.3, 1.7, -1.0), (1, 0, 0), (0, 1, 0), 0.5, depth=0.04)
    hvac(m, -5.5, 4.35, -3.3, 1.8, 1.4, 0.9, fans=1)
    for x in (0.0, 3.4, 6.8):
        B(m, "Concrete", CONC, x - 1.4, x + 1.4, 0.1, 0.4, -5.0, -2.0)
        B(m, "Steel", (0.34, 0.40, 0.37), x - 1.1, x + 1.1, 0.4, 2.6, -4.6, -2.8)
        for kk in range(6):
            xx = x - 0.9 + kk * 0.36
            B(m, "Steel", (0.30, 0.36, 0.33), xx - 0.03, xx + 0.03, 0.6, 2.4, -2.8, -2.3, var=False)
        for kk in (-0.6, 0.0, 0.6):
            T(m, "Steel", (0.45, 0.32, 0.26), (x + kk, 2.6, -3.7), (x + kk, 3.5, -3.7), 0.09, segs=8)
            for y in (2.8, 3.0, 3.2):
                T(m, "Steel", (0.45, 0.32, 0.26), (x + kk, y, -3.7), (x + kk, y + 0.05, -3.7), 0.14, segs=8)
    sh.add((3.4, 1.4, -3.6), (9.2, 2.6, 2.8))
    for x in (-1.6, 8.4):
        T(m, "Steel", GREY, (x, 0.1, -3.7), (x, 5.1, -3.7), 0.12)
    T(m, "Steel", GREY, (-1.75, 5.2, -3.7), (8.55, 5.2, -3.7), 0.1)
    for x in (0.0, 3.4, 6.8):
        T(m, "Steel", DARK, (x, 3.55, -3.7), (x, 5.1, -3.7), 0.02)
    for (a, b) in (((-1.9, -5.8), (9.0, -5.8)), ((9.0, -5.8), (9.0, -1.2)), ((-1.9, -1.2), (9.0, -1.2))):
        railing(m, GREY, (a[0], 0.1, a[1]), (b[0], 0.1, b[1]), h=2.1, posts=2.5)
    plate(m, "hv", (4.0, 1.2, -1.15), (1, 0, 0), (0, 1, 0), 1.6, depth=0.02)
    tilt = rot_x(math.radians(-30))
    for z in (1.6, 4.4):
        for k in range(5):
            x = -7.0 + k * 3.4
            m.color = (0.07, 0.09, 0.15)
            box(m, "Glass", (x, 1.16, z), (3.1, 0.04, 1.9), M=tilt)
            m.color = LIGHT
            box(m, "Steel", (x, 1.10, z - 0.03), (3.2, 0.06, 2.0), M=tilt)
            T(m, "Steel", GREY, (x, 0.1, z - 0.5), (x, 0.75, z - 0.5), 0.05)
            T(m, "Steel", GREY, (x, 0.1, z + 0.5), (x, 1.35, z + 0.5), 0.05)
    return m, sh, []


def fuel_farm():
    """PROPELLANT FARM — a liquid-hydrogen sphere on its legs with a stair to
    its crown, two horizontal LOX tanks on saddles in a bund, a bank of
    ambient vaporisers, the pump house, a pipe rack running toward the pad
    (−z) behind a blast wall, and the deluge water tower."""
    m, sh = CModel(17), Shell()
    B(m, "Concrete", CONC, -14.0, 14.0, -0.6, 0.1, -9.0, 9.0)
    sub = CModel(17); sub.color = PAINT; sub.ground = False
    prof = [(4.8 * math.sin(a), -4.8 * math.cos(a)) for a in np.linspace(0, math.pi, 18)]
    lathe(sub, "Steel", prof, segs=36, smooth=True)
    sub.color = GREY
    lathe(sub, "Steel", [(4.84, -0.15), (4.84, 0.15)], segs=36)
    m.merge(sub, None, (-6.5, 6.6, 0.0))
    for k in range(8):
        a = k * TAU / 8
        x, z = -6.5 + 4.2 * math.cos(a), 4.2 * math.sin(a)
        T(m, "Steel", LIGHT, (x, 0.5, z), (x, 5.8, z), 0.22)
        B(m, "Concrete", CONC, x - 0.5, x + 0.5, 0.1, 0.5, z - 0.5, z + 0.5)
        a2 = (k + 1) * TAU / 8
        x2, z2 = -6.5 + 4.2 * math.cos(a2), 4.2 * math.sin(a2)
        T(m, "Steel", GREY, (x, 0.7, z), (x2, 4.4, z2), 0.06, segs=5)
    B(m, "Steel", GREY, -7.6, -5.4, 11.35, 11.5, -1.1, 1.1, var=False, sh=sh)
    railing(m, SAFETY, (-7.6, 11.5, -1.05), (-5.4, 11.5, -1.05), h=1.0, posts=1.1, sh=sh)
    railing(m, SAFETY, (-7.6, 11.5, 1.05), (-5.4, 11.5, 1.05), h=1.0, posts=1.1, sh=sh)
    T(m, "Steel", GREY, (-6.5, 11.5, 0.0), (-6.5, 12.6, 0.0), 0.08)
    for (x, z) in ((-12.6, 3.2), (-11.0, 3.2), (-12.6, 4.8), (-11.0, 4.8)):
        T(m, "Steel", GREY, (x, 0.1, z), (x, 11.5, z), 0.07)
    for y in (3.8, 11.4):
        B(m, "Steel", GREY, -12.55, -11.05, y - 0.1, y, 3.25, 4.75, var=False, sh=sh)
    stair(m, (-11.8, 0.12, 7.6), (-11.8, 3.68, 4.9), 0.9, sh=sh)
    stair(m, (-11.8, 3.82, 3.1), (-11.8, 7.45, 0.6), 0.9, sh=sh)
    B(m, "Steel", GREY, -12.55, -11.05, 7.45, 7.55, -0.6, 0.55, var=False, sh=sh)
    stair(m, (-11.8, 7.57, 0.62), (-11.8, 11.28, 3.2), 0.9, sh=sh)
    B(m, "Steel", GREY, -11.0, -7.6, 11.35, 11.5, 0.3, 0.9, var=False, sh=sh)
    # the sphere: a core box inside it and a ring of boxes round its waist
    sh.add((-6.5, 6.6, 0.0), (6.8, 6.8, 6.8))
    for k in range(8):
        a = k * TAU / 8
        sh.add((-6.5 + 3.9 * math.cos(a), 6.6, 3.9 * math.sin(a)), (2.0, 4.6, 2.0))
    plate(m, "lh2", (-11.8, 9.6, 4.82), (1, 0, 0), (0, 1, 0), 1.4, depth=0.04)
    for (xa, xb, za, zb) in ((1.5, 13.5, -6.5, -6.2), (1.5, 13.5, 6.2, 6.5), (1.5, 1.8, -6.2, 6.2), (13.2, 13.5, -6.2, 6.2)):
        B(m, "Concrete", CONC, xa, xb, 0.1, 0.9, za, zb)
    for z in (-2.6, 2.6):
        sub = CModel(17); sub.color = PAINT; sub.ground = False
        prof = [(0.0, -5.6), (1.2, -5.5), (1.8, -4.9), (1.8, 4.9), (1.2, 5.5), (0.0, 5.6)]
        lathe(sub, "Steel", prof, segs=28, smooth=True)
        sub.color = GREYBLUE
        lathe(sub, "Steel", [(1.83, -0.5), (1.83, 0.5)], segs=28)
        m.merge(sub, rot_z(math.pi / 2), (7.5, 2.6, z))
        for x in (4.0, 11.0):
            B(m, "Concrete", CONC, x - 0.4, x + 0.4, 0.1, 1.3, z - 1.4, z + 1.4)
        T(m, "Steel", GREY, (2.0, 2.6, z), (1.0, 2.6, z), 0.18)
        T(m, "Steel", GREY, (1.0, 2.42, z), (1.0, 4.1, z), 0.18)
    plate(m, "lox", (7.5, 1.6, 6.5), (1, 0, 0), (0, 1, 0), 1.4, depth=0.04)
    plate(m, "cryo", (7.5, 0.5, 6.5), (1, 0, 0), (0, 1, 0), 2.4, depth=0.03)
    for z in (-2.6, 2.6):
        sh.add((7.5, 2.6, z), (11.0, 3.4, 3.4))
    for k in range(6):
        x = 2.5 + k * 1.6
        T(m, "Steel", LIGHT, (x, 0.1, -8.0), (x, 5.1, -8.0), 0.12, segs=8)
        for a in range(4):
            ang = a * math.pi / 4 + math.pi / 8
            m.color = LIGHT
            box(m, "Steel", (x, 2.6 + a * 0.01, -8.0), (0.7 - a * 0.02, 4.8 - a * 0.03, 0.03), M=rot_z(0) @ np.array([[math.cos(ang), 0, math.sin(ang)], [0, 1, 0], [-math.sin(ang), 0, math.cos(ang)]]))
    T(m, "Steel", GREY, (2.0, 5.3, -8.0), (11.0, 5.3, -8.0), 0.14)
    B(m, "Clad", PAINT, -2.0, 1.0, -0.4, 3.0, -8.5, -5.5, sh=sh)
    B(m, "Steel", GREY, -2.1, 1.1, 3.0, 3.15, -8.6, -5.4, var=False)
    B(m, "Steel", DARK, -1.0, -0.1, 0.1, 2.2, -5.5, -5.42, var=False)
    plate(m, "bldg6", (0.45, 2.1, -5.5), (1, 0, 0), (0, 1, 0), 0.5, depth=0.04)
    for z in (-8.3, -6.0, -3.2):
        for x in (-2.8, 2.6):
            T(m, "Steel", GREY, (x, 0.1, z), (x, 3.55, z), 0.1)
        T(m, "Steel", GREY, (-2.9, 3.6, z), (2.7, 3.6, z), 0.08)
    for k, (x, col) in enumerate(((-2.0, PAINT), (-0.7, PAINT), (0.6, INSUL), (1.8, SAFETY))):
        r = 0.18 if k < 2 else 0.12
        T(m, "Steel", col, (x, 3.85, -8.5), (x, 3.85, 0.0), r, segs=10)
        T(m, "Steel", col, (x, 3.85 - r, 0.0), (x, 0.9, 0.0), r, segs=10)
        T(m, "Steel", DARK, (x, 3.85, -4.5), (x, 3.85, -4.2), r + 0.08, segs=10)
    B(m, "Concrete", CONC, -13.5, 13.5, -0.4, 3.2, -8.95, -8.55)
    lattice_column(m, LIGHT, (-11.0, 0.1, -5.0), 13.0, 2.4, step=3.2)
    sub = CModel(17); sub.color = PAINT; sub.ground = False
    lathe(sub, "Steel", [(0.0, 0.0), (2.6, 0.4), (2.6, 4.2), (1.6, 5.0), (0.0, 5.2)], segs=24)
    m.merge(sub, None, (-11.0, 13.0, -5.0))
    obstruction(m, (-11.0, 18.36, -5.0), r=0.13)
    sh.add((-11.0, 15.6, -5.0), (5.0, 5.0, 5.0))
    for (dx, dz) in ((-1.2, -1.2), (1.2, -1.2), (1.2, 1.2), (-1.2, 1.2)):
        sh.add((-11.0 + dx, 6.55, -5.0 + dz), (0.25, 12.9, 0.25))
    return m, sh, []


# The launch complex. Ground frame: the mount is at x = z = 0; the crawlerway
# arrives from -z up the ramp; the flame trench runs along x and opens at both
# ends; the service tower stands on the +z block.
HS = 17.0           # hardstand half-size
HS_H = 2.0          # hardstand top above the ground
DECK = 2.49         # mount deck above the hardstand (the Launchpad collider's height)
TRENCH = 3.0        # trench half-width


def launch_complex():
    m, sh = CModel(18), Shell()
    for (za, zb) in ((-HS, -TRENCH), (TRENCH, HS)):
        B(m, "Concrete", CONC, -HS, HS, -0.8, HS_H, za, zb, sh=sh)
    B(m, "Concrete", SCORCH, -HS - 4.0, HS + 4.0, -0.8, 0.15, -TRENCH + 0.06, TRENCH - 0.06)
    for sz in (-1, 1):
        B(m, "Concrete", SCORCH, -HS - 0.03, HS + 0.03, 0.15, HS_H - 0.03, TRENCH * sz - 0.06 * sz, TRENCH * sz - 0.01 * sz)
    ang = math.atan2(1.55, 3.5)
    L = math.hypot(3.5, 1.55)
    m.ground = False
    for sx in (-1, 1):
        m.color = (0.22, 0.20, 0.19)
        box(m, "Steel", (1.75 * sx, 0.15 + 1.55 / 2 + 0.03, 0.0), (L, 0.25, 2 * TRENCH - (0.3 if sx > 0 else 0.36)), M=rot_z(-ang * sx))
    m.ground = True
    for sz in (-1, 1):
        cuboid(m, (0.0, HS_H + 0.015, TRENCH * sz + 0.3 * sz), (1, 0, 0), (0, 0, -1), 2 * HS - 0.4, 0.5, 0.03,
               faces={"front": ("Sign", (1, 1, 1), "hazard")}, col=DARK)
    cuboid(m, (0.0, HS_H + 0.015, -11.0), (-1, 0, 0), (0, 0, 1), 10.0, 10.0 * region_aspect("deck_lc1"), 0.03,
           faces={"front": ("Sign", (1, 1, 1), "deck_lc1")}, mat="Concrete", col=CONC)
    top = HS_H + DECK
    for (xa, xb, za, zb) in ((-4.0, 4.0, -4.0, -1.2), (-4.0, 4.0, 1.2, 4.0), (-4.0, -1.2, -1.2, 1.2), (1.2, 4.0, -1.2, 1.2)):
        B(m, "Steel", GREY, xa, xb, top - 0.8, top, za, zb, var=False)
    sh.add((0.0, top - 0.4, 0.0), (8.0, 0.8, 8.0))
    for sx in (-1, 1):
        for sz in (-1, 1):
            B(m, "Steel", GREY, 3.4 * sx - 0.45, 3.4 * sx + 0.45, HS_H, top - 0.82, 3.6 * sz - 0.4, 3.6 * sz + 0.4, var=False)
    for sz in (-1, 1):
        T(m, "Steel", GREY, (-HS + 1.0, HS_H + 0.45, 8.0 * sz), (HS - 1.0, HS_H + 0.45, 8.0 * sz), 0.4, segs=12)
        for x in (-HS + 1.0, HS - 1.0):
            T(m, "Steel", DARK, (x, HS_H, 8.0 * sz), (x, HS_H + 0.2, 8.0 * sz), 0.25, segs=8)
    for sx in (-1, 1):
        T(m, "Steel", GREY, (5.0 * sx, HS_H + 0.45, -7.6), (5.0 * sx, HS_H + 0.45, 7.6), 0.3, segs=10)
        T(m, "Steel", GREY, (5.0 * sx, HS_H + 0.7, 0.0), (4.4 * sx, HS_H + 2.6, 0.0), 0.22, segs=10)
    tz, tw, ttop = 9.5, 4.0, 28.0
    lattice_column(m, RUST_ORANGE, (0.0, HS_H, tz), ttop, tw, step=3.0, r=0.16, rb=0.07)
    lv = list(np.arange(HS_H + 6.0, ttop + 0.1, 6.0))
    for i, y in enumerate(lv):
        B(m, "Steel", GREY, -1.85, 1.85, y - 0.15, y, tz - 1.85, tz + 1.85, var=False, sh=sh)
        railing(m, SAFETY, (-1.85, y, tz - 1.85), (1.85, y, tz - 1.85), h=1.0, sh=sh)
        B(m, "Steel", GREY, 1.86, 3.4, y - 0.15, y, tz + (1.1 if i % 2 == 0 else -2.4), tz + (2.4 if i % 2 == 0 else -1.1),
          var=False, sh=sh)
    prev = HS_H
    for i, y in enumerate(lv):
        if i % 2 == 0:
            stair(m, (2.85, prev + 0.02, tz - 1.8), (2.85, y - 0.05, tz + 1.1), 0.9, col=GREY, sh=sh)
        else:
            stair(m, (2.85, prev + 0.02, tz + 1.8), (2.85, y - 0.05, tz - 1.1), 0.9, col=GREY, sh=sh)
        prev = y
    for (dx, dz) in ((-2, -2), (2, -2), (2, 2), (-2, 2)):
        sh.add((dx, (HS_H + ttop) / 2, tz + dz), (0.35, ttop - HS_H, 0.35))
    B(m, "Steel", RUST_ORANGE, -3.0, 9.0, ttop + 0.1, ttop + 1.0, tz - 0.6, tz + 0.6, var=False)
    B(m, "Steel", DARK, -3.0, -1.2, ttop + 1.0, ttop + 2.6, tz - 1.0, tz + 1.0, var=False)
    T(m, "Steel", DARK, (7.5, ttop + 0.1, tz), (7.5, ttop - 6.0, tz), 0.03)
    T(m, "Steel", GREY, (0.0, ttop + 2.6, tz), (0.0, ttop + 6.0, tz), 0.06)
    obstruction(m, (8.4, ttop + 1.16, tz))
    obstruction(m, (0.0, ttop + 6.16, tz))
    plate(m, "pad_tower", (0.0, ttop - 3.0, tz - tw / 2 - 0.3), (-1, 0, 0), (0, 1, 0), 2.6, depth=0.04)
    cable_tray(m, (-1.2, HS_H + 0.3, tz - 2.2), (-1.2, HS_H + 0.3, 4.1), w=0.5)
    cable_tray(m, (1.2, HS_H + 0.3, tz - 2.2), (1.2, HS_H + 0.3, 4.1), w=0.5)

    def arm(y, z_end, w=1.4, h=1.6, hood=True):
        z0 = tz - tw / 2
        B(m, "Steel", RUST_ORANGE, -w / 2, w / 2, y, y + 0.12, z_end, z0 - 0.2, var=False, sh=sh)
        B(m, "Steel", RUST_ORANGE, -w / 2, w / 2, y + h - 0.12, y + h, z_end, z0 - 0.2, var=False)
        for sx in (-1, 1):
            n = max(2, int((z0 - z_end) / 1.2))
            for k in range(n + 1):
                z = z_end + 0.1 + (z0 - 0.3 - z_end) * k / n
                T(m, "Steel", RUST_ORANGE, (w / 2 * sx, y + 0.12, z), (w / 2 * sx, y + h - 0.12, z), 0.05, segs=5)
            T(m, "Steel", RUST_ORANGE, (w / 2 * sx, y + 0.13, z_end + 0.2), (w / 2 * sx, y + h - 0.13, z0 - 0.4), 0.04, segs=5)
        if hood:
            B(m, "Clad", PAINT, -w / 2 - 0.2, w / 2 + 0.2, y - 0.1, y + h + 0.2, z_end - 0.6, z_end - 0.02)
    arm(HS_H + 7.0, 2.4)
    for (y, sx) in ((HS_H + 3.5, -1), (HS_H + 12.0, 1)):
        x0 = (tw / 2 + 0.25) * sx
        B(m, "Steel", RUST_ORANGE, x0, x0 + 4.0 * sx, y, y + 0.9, tz - 2.5, tz - 1.7, var=False)
        T(m, "Steel", DARK, (x0, y + 0.45, tz - 2.65), (x0 + 4.0 * sx, y + 0.45, tz - 2.65), 0.12)
    MAST, MH = 20.0, 34.0
    tops = []
    for (sx, sz) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        x, z = MAST * sx, MAST * sz
        B(m, "Concrete", CONC, x - 1.0, x + 1.0, -0.6, 0.4, z - 1.0, z + 1.0)
        T(m, "Steel", LIGHT, (x, 0.4, z), (x, MH, z), 0.45, segs=12, r1=0.16)
        T(m, "Steel", GREY, (x, MH, z), (x, MH + 2.0, z), 0.04, segs=6)
        B(m, "Steel", GREY, x - 0.35, x + 0.35, MH - 0.9, MH - 0.82, z - 0.35, z + 0.35, var=False)
        obstruction(m, (x + 0.24, MH - 0.66, z))
        tops.append(np.array([x, MH - 0.3, z]))
    for i in range(4):
        a, b = tops[i], tops[(i + 1) % 4]
        n = 12
        pts = [a + (b - a) * k / n - np.array([0.0, 3.0 * 4 * (k / n) * (1 - k / n), 0.0]) for k in range(n + 1)]
        for k in range(n):
            T(m, "Steel", DARK, pts[k], pts[k + 1], 0.035, segs=4)
    floods = []
    for (sx, sz) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        x, z = 15.5 * sx, 15.5 * sz
        T(m, "Steel", GREY, (x, HS_H, z), (x, HS_H + 13.0, z), 0.16, segs=10, r1=0.1)
        B(m, "Steel", GREY, x - 1.2, x + 1.2, HS_H + 13.0, HS_H + 13.15, z - 0.2, z + 0.2, var=False)
        aim = np.array([0.0, top + 3.0, 0.0]) - np.array([x, HS_H + 13.6, z])
        aim = aim / np.linalg.norm(aim)
        for dx in (-0.65, 0.65):
            lamp_head(m, (x + dx, HS_H + 13.6, z), aim, w=0.9, h=0.7)
        floods.append(((x, HS_H + 13.6, z), aim))
    for (x, z) in ((-14.0, -6.0), (14.0, -6.0)):
        T(m, "Steel", GREY, (x, HS_H, z), (x, HS_H + 4.5, z), 0.08)
        B(m, "Steel", PAINT, x - 0.25, x + 0.25, HS_H + 4.5, HS_H + 4.9, z - 0.35, z + 0.35, var=False)
        B(m, "Steel", DARK, x - 0.18, x + 0.18, HS_H + 4.55, HS_H + 4.85, z + 0.35, z + 0.42, var=False)
    B(m, "Concrete", CONC, -16.0, -9.5, -0.4, 2.6, -27.0, -21.0, sh=sh)
    B(m, "Concrete", CONC_DARK, -16.3, -9.2, 2.6, 2.9, -27.3, -20.7)
    B(m, "Steel", GREYBLUE, -12.6, -11.4, 0.1, 2.1, -21.0, -20.92, var=False)
    plate(m, "blast", (-12.7, 2.35, -20.92), (1, 0, 0), (0, 1, 0), 2.4, depth=0.03)
    th = math.atan2(HS_H, 12.0)
    L = math.hypot(12.0, HS_H)
    n = np.array([0.0, math.cos(th), -math.sin(th)])
    c_top = np.array([0.0, HS_H / 2, -HS - 6.0])
    c = c_top - n * 1.5
    m.color = CONC
    m.ground = False
    box(m, "Concrete", c, (15.96, 3.0, L), M=rot_x(-th), uv_m=0.25)
    m.ground = True
    sh.add(c, (16.0, 3.0, L), quat_x(-th))
    for sx in (-1, 1):
        railing(m, SAFETY, (7.75 * sx, 0.0, -HS - 12.0), (7.75 * sx, HS_H, -HS - 0.05), h=1.0, posts=3.0, sh=sh)
    lights = []
    for i, (p, aim) in enumerate(floods):
        lights.append((f"Pad Flood {i + 1}", p, (1.0, 0.92, 0.80), 6.0, 60.0, aim))
    return m, sh, lights


def pad_clamps():
    """The hold-down posts round the mount's exhaust hole. Its ROOT collider is
    the old Launchpad's deck box, unchanged (vessel_spawner's deck = 1.24)."""
    m = CModel(19)
    m.ground = False
    for sx in (-1, 1):
        for sz in (-1, 1):
            x, z = 1.55 * sx, 1.55 * sz
            m.color = RUST_ORANGE
            box(m, "Steel", (x, 0.0, z), (0.45, 0.5, 0.45))
            m.color = DARK
            box(m, "Steel", (x - 0.18 * sx, 0.28, z - 0.18 * sz), (0.3, 0.06, 0.3))
    return m
