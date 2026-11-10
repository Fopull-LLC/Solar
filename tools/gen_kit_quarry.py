#!/usr/bin/env python3
"""The kit's LOGISTICS pieces: the quarry, conveyors, tubes, hoppers, silos, the loading chute
(expansion X5; scripts/parts_kit.lua LOGISTICS, scripts/logistics.lua; docs/base-building.md §23).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for
its PIECES table, built with its own primitives). To write only these, without touching any other
piece's model or the whole fixture:

    python3 tools/gen_kit_quarry.py            # models/kit/q*,cv*,tb*,lg*  prefabs/Kit*  + fixture rows

1:1, in each piece's ground frame (+Y up, +Z its front), real proportions:
* Quarry Post: a 300 mm H-column 3 m tall on a base plate, the gantry's rail bracket at its top,
  hazard banding at its foot.
* Quarry Drive: a skid with the winch house (cable drum, gear motor, brake), the control cabinet,
  and the discharge bin (500 kg) whose apron chute ends on the belt port (+Z, 0.8 m) and a tube
  port (+X).
* Conveyors: a troughed belt 0.6 m wide between two channel stringers on legs, idlers under it;
  the running surface is its own strip (uv.y = metres along: shaders/conveyor_run.flsl) and the
  load a subdivided strip over it (shaders/conveyor_load.flsl, the "Load" child). 2 m, 1 m, a
  curved 90° corner, a T merge, a 15° ramp (2 m, rising 0.5 m).
* Transfer Tube: DN150 (168 mm OD) on stands, flanged; 2 m, 1 m, an elbow; the Tube Blower (a
  side-channel blower on the line, its motor and filter).
* Hopper: a 2 × 2 m bin on four legs, its pyramid bottom, the belt inlet hood (−Z) and the
  discharge feeder (+Z), tube stubs either side.
* Silo: Ø2.2 × 6.2 m: a welded steel bin on a skirt, its cone, a roof with a vent, the bucket
  elevator's casing up its side from the inlet (−Z) to the roof, the discharge spout (+Z).
* Loading Chute: a mast with a boom 2.2 m out over the deck, a telescoping spout and its sock, an
  inclined screw casing from the inlet hopper (−Z) up to the boom.
* The gantry's moving parts (hidden pieces, no colliders): the bridge (a 1 m box-truss unit,
  scaled to the quarry's width), the hoist cable (1 m, scaled down), the cutter head (a
  bucket wheel on its frame).
"""
import math
import os
import sys

import numpy as np

BELT_Y = 0.8            # the belt's running surface: every BELT and DN150 port is at this height
BW = 0.6                # belt width
TR = 0.084              # DN150 outside radius
TFR = 0.14              # its flange
TFT = 0.022

STRUCT = (0.36, 0.38, 0.36)        # galvanised / grey structural steel
FRAME_Y = (0.78, 0.62, 0.16)       # machinery yellow
HAZ_Y = (0.86, 0.68, 0.10)
HAZ_K = (0.07, 0.07, 0.07)
CAB = (0.70, 0.72, 0.70)
MOTOR = (0.20, 0.32, 0.42)
SILO_W = (0.74, 0.75, 0.72)
BLACK = (0.08, 0.08, 0.09)
TUBE = (0.62, 0.63, 0.62)

MATERIALS = {
    "Belt": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                roughness: 0.92,\n                metallic: 0.0,\n'
                     '                shader: Some("shaders/conveyor_run.flsl"),\n                shading: Physical,\n            )'),
    "Load": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                roughness: 0.95,\n                metallic: 0.0,\n'
                     '                shader: Some("shaders/conveyor_load.flsl"),\n                shading: Physical,\n            )'),
}


def strip(m, mat, path, width, y_of=None, n_across=1, step=None):
    """A flat strip along a polyline `path` [(x, y, z)…] (its up +Y), `width` wide: uv.x 0..1
    across, uv.y metres along. Subdivided every `step` m along and n_across across."""
    pts = [np.asarray(p, float) for p in path]
    # resample
    if step:
        out = [pts[0]]
        for a, b in zip(pts[:-1], pts[1:]):
            L = float(np.linalg.norm(b - a))
            n = max(1, int(math.ceil(L / step)))
            for k in range(1, n + 1):
                out.append(a + (b - a) * k / n)
        pts = out
    P, N, UV, I = [], [], [], []
    s = 0.0
    for i, p in enumerate(pts):
        if i > 0:
            s += float(np.linalg.norm(p - pts[i - 1]))
        a = pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]
        a = a / max(1e-9, np.linalg.norm(a))
        side = np.cross(np.array([0.0, 1.0, 0.0]), a)
        side = side / max(1e-9, np.linalg.norm(side))
        nrm = np.cross(a, side)
        for j in range(n_across + 1):
            u = j / n_across
            P.append(p + side * (u - 0.5) * width)
            N.append(nrm)
            UV.append((u, s))
    w = n_across + 1
    for i in range(len(pts) - 1):
        for j in range(n_across):
            a0, b0 = i * w + j, i * w + j + 1
            a1, b1 = a0 + w, b0 + w
            I.append((a0, a1, b1))
            I.append((a0, b1, b0))
    m.add(mat, P, N, UV, I)


def pieces(K):
    CModel, Shell, bx, tb, rbox = K.CModel, K.Shell, K.bx, K.tb, K.rbox
    lathe, disk = K.lathe, K.disk
    DARK, GREY, LIGHT, RUBBER = K.DARK, K.GREY, K.LIGHT, K.RUBBER
    out = {}

    def hazard(m, x0, x1, y0, y1, z0, z1, n=6):
        """Diagonal-ish banding as alternating boxes round a column foot."""
        step = (y1 - y0) / n
        for k in range(n):
            col = HAZ_Y if k % 2 == 0 else HAZ_K
            bx(m, "Steel", col, x0, x1, y0 + k * step, y0 + (k + 1) * step, z0, z1)

    # ── conveyors ──
    def belt_frame(m, sh, path, legs, width=BW):
        """Stringers, idlers and legs along a path of (x, z) points at the belt's height."""
        P = [np.array([p[0], BELT_Y, p[1]], float) for p in path]
        for a, b in zip(P[:-1], P[1:]):
            d = b - a
            L = float(np.linalg.norm(d))
            ax = d / L
            side = np.cross(np.array([0.0, 1.0, 0.0]), ax)
            side /= np.linalg.norm(side)
            yaw = math.atan2(ax[0], ax[2])
            M = K.rot_y(yaw)
            c = (a + b) / 2
            for s in (-1, 1):
                q = c + side * s * (width / 2 + 0.05)
                rbox(m, "Steel", STRUCT, (q[0], BELT_Y - 0.09, q[2]), (0.05, 0.16, L + 0.01), M)
                rbox(m, "Steel", DARK, (q[0], BELT_Y - 0.01, q[2]), (0.07, 0.012, L + 0.01), M)
            # the belt's carcass under its surface, and its return run
            rbox(m, "Rubber", RUBBER, (c[0], BELT_Y - 0.012, c[2]), (width, 0.02, L), M)
            rbox(m, "Rubber", RUBBER, (c[0], BELT_Y - 0.22, c[2]), (width * 0.95, 0.012, L), M)
            n = max(1, int(round(L / 0.5)))
            for k in range(n):
                f = (k + 0.5) / n
                p = a + d * f
                e0, e1 = p - side * width * 0.48, p + side * width * 0.48
                tb(m, "Steel", GREY, (e0[0], BELT_Y - 0.06, e0[2]), (e1[0], BELT_Y - 0.06, e1[2]), 0.04, segs=10)
        for (x, z) in legs:
            for s in (-1, 1):
                # legs on the frame's own sides (the first segment's normal is good enough for a straight run)
                a, b = P[0], P[-1]
                ax = (b - a) / max(1e-9, np.linalg.norm(b - a))
                side = np.cross(np.array([0.0, 1.0, 0.0]), ax)
                side /= np.linalg.norm(side)
                q = np.array([x, 0, z]) + side * s * (width / 2 + 0.05)
                bx(m, "Steel", STRUCT, q[0] - 0.03, q[0] + 0.03, 0.0, BELT_Y - 0.17, q[2] - 0.03, q[2] + 0.03)
                bx(m, "Steel", DARK, q[0] - 0.07, q[0] + 0.07, 0.0, 0.012, q[2] - 0.07, q[2] + 0.07)
            sh.add((x, (BELT_Y - 0.17) / 2, z), (width + 0.16, BELT_Y - 0.17, 0.08))
        # the walkable belt top, one box a segment
        for a, b in zip(P[:-1], P[1:]):
            d = b - a
            L = float(np.linalg.norm(d))
            yaw = math.atan2(d[0], d[2])
            c = (a + b) / 2
            sh.add((c[0], BELT_Y - 0.09, c[2]), (width + 0.16, 0.18, L), K.quat_from_basis(K.rot_y(yaw)))

    def p_belt(L):
        def fn(mat):
            m, sh = CModel(seed=1501 + int(L * 10)), Shell()
            h = L / 2
            belt_frame(m, sh, [(0, -h), (0, h)], [(0, -h + 0.15), (0, h - 0.15)] if L >= 1.5 else [(0, 0)])
            strip(m, "Belt", [(0, BELT_Y, -h), (0, BELT_Y, h)], BW * 0.98)
            ld = CModel(seed=1502)
            ld.ground = False
            ld.color = (1.0, 1.0, 1.0)
            strip(ld, "Load", [(0, BELT_Y + 0.004, -h), (0, BELT_Y + 0.004, h)], BW * 0.8, n_across=6, step=0.08)
            return m, sh, [("Load", "mesh", (ld, (0, 0, 0)))]
        return fn

    def p_corner(mat):
        m, sh = CModel(seed=1511), Shell()
        cx, cz, R = 0.5, -0.5, 0.5
        n = 12
        path = [(cx + R * math.cos(math.pi - (math.pi / 2) * k / n), cz + R * math.sin(math.pi - (math.pi / 2) * k / n)) for k in range(n + 1)]
        # (the path runs from the a port (0, −0.5) round to the b port (0.5, 0))
        belt_frame(m, sh, path, [(0.12, -0.12)], width=BW * 0.85)
        strip(m, "Belt", [(x, BELT_Y, z) for (x, z) in path], BW * 0.83)
        ld = CModel(seed=1512)
        ld.ground = False
        ld.color = (1.0, 1.0, 1.0)
        strip(ld, "Load", [(x, BELT_Y + 0.004, z) for (x, z) in path], BW * 0.68, n_across=6, step=0.08)
        return m, sh, [("Load", "mesh", (ld, (0, 0, 0)))]

    def p_merge(mat):
        m, sh = CModel(seed=1521), Shell()
        belt_frame(m, sh, [(0, -0.5), (0, 0.5)], [(0, 0)])
        strip(m, "Belt", [(0, BELT_Y, -0.5), (0, BELT_Y, 0.5)], BW * 0.98)
        # the side feed: a short chute and skirt from +X onto the belt
        bx(m, "Steel", FRAME_Y, BW / 2 + 0.06, 0.5, BELT_Y + 0.02, BELT_Y + 0.05, -0.25, 0.25)
        bx(m, "Steel", FRAME_Y, BW / 2 - 0.05, 0.5, BELT_Y + 0.05, BELT_Y + 0.30, -0.27, -0.24)
        bx(m, "Steel", FRAME_Y, BW / 2 - 0.05, 0.5, BELT_Y + 0.05, BELT_Y + 0.30, 0.24, 0.27)
        bx(m, "Steel", STRUCT, 0.44, 0.47, 0.0, BELT_Y, -0.03, 0.03)
        sh.add((0.42, BELT_Y / 2, 0), (0.16, BELT_Y, 0.5))
        ld = CModel(seed=1522)
        ld.ground = False
        ld.color = (1.0, 1.0, 1.0)
        strip(ld, "Load", [(0, BELT_Y + 0.004, -0.5), (0, BELT_Y + 0.004, 0.5)], BW * 0.8, n_across=6, step=0.08)
        return m, sh, [("Load", "mesh", (ld, (0, 0, 0)))]

    def p_ramp(mat):
        m, sh = CModel(seed=1531), Shell()
        rise = 0.5
        a, b = np.array([0, BELT_Y, -1.0]), np.array([0, BELT_Y + rise, 1.0])
        d = b - a
        L = float(np.linalg.norm(d))
        pitch = math.atan2(rise, 2.0)
        M = K.rot_x(-pitch)
        c = (a + b) / 2
        for s in (-1, 1):
            rbox(m, "Steel", STRUCT, (s * (BW / 2 + 0.05), c[1] - 0.09, c[2]), (0.05, 0.16, L), M)
        rbox(m, "Rubber", RUBBER, (0, c[1] - 0.012, c[2]), (BW, 0.02, L), M)
        for k in range(4):
            f = (k + 0.5) / 4
            p = a + d * f
            tb(m, "Steel", GREY, (-BW * 0.48, p[1] - 0.06, p[2]), (BW * 0.48, p[1] - 0.06, p[2]), 0.04, segs=10)
        for (z, y) in ((-0.85, BELT_Y), (0.85, BELT_Y + rise)):
            for s in (-1, 1):
                bx(m, "Steel", STRUCT, s * (BW / 2 + 0.05) - 0.03, s * (BW / 2 + 0.05) + 0.03, 0.0, y - 0.15, z - 0.03, z + 0.03)
            sh.add((0, (y - 0.15) / 2, z), (BW + 0.16, y - 0.15, 0.08))
        sh.add((0, c[1] - 0.09, c[2]), (BW + 0.16, 0.18, L), K.quat_from_basis(M))
        strip(m, "Belt", [tuple(a), tuple(b)], BW * 0.98)
        ld = CModel(seed=1532)
        ld.ground = False
        ld.color = (1.0, 1.0, 1.0)
        strip(ld, "Load", [(0, BELT_Y + 0.004, -1.0), (0, BELT_Y + rise + 0.004, 1.0)], BW * 0.8, n_across=6, step=0.08)
        return m, sh, [("Load", "mesh", (ld, (0, 0, 0)))]

    # ── tubes ──
    def tube_stub(m, port, n, start):
        port = np.asarray(port, float)
        n = np.asarray(n, float)
        fb = port - n * TFT
        tb(m, "Steel", TUBE, start, tuple(fb), TR, segs=16)
        tb(m, "Steel", GREY, tuple(fb), tuple(port), TFR, segs=18)

    def tube_stand(m, sh, x, z):
        top = BELT_Y - TR
        bx(m, "Steel", DARK, x - 0.1, x + 0.1, 0.0, 0.012, z - 0.1, z + 0.1)
        bx(m, "Steel", STRUCT, x - 0.03, x + 0.03, 0.012, top, z - 0.03, z + 0.03)
        bx(m, "Steel", STRUCT, x - 0.12, x + 0.12, top - 0.03, top, z - 0.04, z + 0.04)
        sh.add((x, top / 2, z), (0.08, top, 0.08))

    def p_tube(L):
        def fn(mat):
            m, sh = CModel(seed=1541 + int(L * 10)), Shell()
            h = L / 2
            for s in (-1, 1):
                tube_stub(m, (0, BELT_Y, s * h), (0, 0, s), (0, BELT_Y, 0))
            for z in ((-h * 0.6, h * 0.6) if L >= 1.5 else (0.0,)):
                tube_stand(m, sh, 0, z)
            sh.add((0, BELT_Y, 0), (2 * TR, 2 * TR, L))
            return m, sh, []
        return fn

    def p_tube_elbow(mat):
        m, sh = CModel(seed=1551), Shell()
        cx, cz, R = 0.5, -0.5, 0.5
        n = 10
        a0, a1 = math.pi - TFT / R, math.pi / 2 + TFT / R
        pts = [(cx + R * math.cos(a0 + (a1 - a0) * k / n), BELT_Y, cz + R * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
        for p, q in zip(pts[:-1], pts[1:]):
            tb(m, "Steel", TUBE, p, q, TR, segs=16)
        tb(m, "Steel", GREY, (0, BELT_Y, -0.5 + TFT), (0, BELT_Y, -0.5), TFR, segs=18)
        tb(m, "Steel", GREY, (0.5 - TFT, BELT_Y, 0), (0.5, BELT_Y, 0), TFR, segs=18)
        tube_stand(m, sh, 0.15, -0.15)
        sh.add((0.15, BELT_Y, -0.15), (0.3, 2 * TR, 0.3))
        return m, sh, []

    def p_blower(mat):
        m, sh = CModel(seed=1561), Shell()
        for s in (-1, 1):
            tube_stub(m, (0, BELT_Y, s * 0.5), (0, 0, s), (0, BELT_Y, 0))
        # the side-channel blower: a round housing on a frame, its motor, a filter silencer
        bx(m, "Steel", DARK, -0.45, 0.45, 0.0, 0.08, -0.4, 0.4, sh=sh)
        tb(m, "Steel", MOTOR, (0.18, 0.55, -0.28), (0.18, 0.55, 0.28), 0.26, segs=24)
        tb(m, "Steel", GREY, (0.18, 0.55, -0.31), (0.18, 0.55, -0.28), 0.18, segs=18)
        tb(m, "Steel", MOTOR, (0.18, 0.55, 0.28), (0.18, 0.55, 0.40), 0.12, segs=16)
        for z in (-0.2, 0.2):
            bx(m, "Steel", STRUCT, 0.05, 0.31, 0.08, 0.30, z - 0.04, z + 0.04)
        tb(m, "Steel", GREY, (0.18, 0.81, 0.0), (0.18, 1.05, 0.0), 0.09, segs=14)        # the filter silencer
        tb(m, "Steel", DARK, (0.18, 1.05, 0.0), (0.18, 1.08, 0.0), 0.11, segs=14)
        tb(m, "Steel", TUBE, (0.0, BELT_Y, 0.0), (0.18, 0.62, 0.0), 0.05, segs=12)       # into the line
        bx(m, "Steel", CAB, -0.42, -0.2, 0.1, 0.55, 0.15, 0.35)                           # the starter box
        bx(m, "Steel", DARK, -0.40, -0.22, 0.46, 0.50, 0.35, 0.355)
        sh.add((0.18, 0.55, 0.05), (0.52, 0.52, 0.72))
        sh.add((0, BELT_Y, 0), (2 * TR, 2 * TR, 1.0))
        return m, sh, []

    # ── the stores ──
    def belt_port_hood(m, z, sgn, top):
        """A belt delivers into / takes from a store at (0, BELT_Y, z): a hood over the belt's end and a
        casing up the store's side to its top (the belt's elevator), or the discharge feeder."""
        bx(m, "Steel", FRAME_Y, -0.36, 0.36, BELT_Y - 0.02, BELT_Y + 0.35, z - sgn * 0.30, z)
        bx(m, "Steel", DARK, -0.33, 0.33, BELT_Y + 0.02, BELT_Y + 0.30, z - sgn * 0.005, z + sgn * 0.0)

    def p_hopper(mat):
        m, sh = CModel(seed=1571), Shell()
        # four legs and their braces
        for x in (-0.9, 0.9):
            for z in (-0.9, 0.9):
                bx(m, "Steel", STRUCT, x - 0.06, x + 0.06, 0.0, 1.35, z - 0.06, z + 0.06)
                bx(m, "Steel", DARK, x - 0.12, x + 0.12, 0.0, 0.015, z - 0.12, z + 0.12)
            tb(m, "Steel", STRUCT, (x, 0.2, -0.9), (x, 1.2, 0.9), 0.025, segs=6)
        for z in (-0.9, 0.9):
            tb(m, "Steel", STRUCT, (-0.9, 0.2, z), (0.9, 1.2, z), 0.025, segs=6)
        # the bin: a box 2 × 2 from 1.35 to 2.5, its pyramid bottom to a 0.5 m outlet at 0.95
        bx(m, "Steel", FRAME_Y, -1.0, 1.0, 1.35, 2.5, -1.0, 1.0, sh=sh)
        bx(m, "Steel", DARK, -1.02, 1.02, 2.45, 2.52, -1.02, 1.02)
        for k in range(4):
            yaw = k * math.pi / 2
            M = K.rot_y(yaw) @ K.rot_x(math.radians(40))
            c = K.rot_y(yaw) @ np.array([0, 1.15, 0.6])
            rbox(m, "Steel", FRAME_Y, tuple(c), (1.5, 0.03, 0.62), M)
        bx(m, "Steel", DARK, -0.25, 0.25, 0.92, 1.0, -0.25, 0.25)
        # the discharge feeder: the outlet onto a short apron to the +Z belt port
        bx(m, "Steel", FRAME_Y, -0.3, 0.3, BELT_Y + 0.02, 0.92, -0.25, 0.25)
        bx(m, "Steel", FRAME_Y, -0.32, 0.32, BELT_Y - 0.02, BELT_Y + 0.25, 0.25, 1.0)
        bx(m, "Steel", DARK, -0.28, 0.28, BELT_Y + 0.03, BELT_Y + 0.22, 0.99, 1.0)
        # the inlet: a belt delivering at −Z rides a casing up the bin's side to its top
        bx(m, "Steel", FRAME_Y, -0.32, 0.32, BELT_Y - 0.02, BELT_Y + 0.25, -1.0, -0.6)
        bx(m, "Steel", DARK, -0.28, 0.28, BELT_Y + 0.03, BELT_Y + 0.22, -1.0, -0.995)
        bx(m, "Steel", GREY, -0.2, 0.2, BELT_Y + 0.25, 2.62, -0.98, -0.62)
        bx(m, "Steel", GREY, -0.2, 0.2, 2.5, 2.62, -0.62, -0.1)
        # tube stubs both sides at belt height
        for s in (-1, 1):
            tube_stub(m, (s * 1.0, BELT_Y, 0), (s, 0, 0), (s * 0.55, BELT_Y, 0))
            bx(m, "Steel", STRUCT, s * 0.55 - 0.03, s * 0.55 + 0.03, 0.0, BELT_Y - TR, -0.03, 0.03)
        # a ladder and the level gauge
        for x in (0.75, 0.95):
            bx(m, "Steel", STRUCT, x - 0.015, x + 0.015, 1.35, 2.6, 1.0, 1.03)
        bx(m, "Steel", BLACK, -0.6, -0.4, 1.6, 2.3, 1.0, 1.01)
        sh.add((0, 0.675, 0), (1.9, 1.35, 1.9))
        return m, sh, []

    def p_silo(mat):
        m, sh = CModel(seed=1581), Shell()
        R = 1.0
        # the skirt on its ring footing, the cone, the bin, the roof
        lathe(m, "Steel", [(R * 0.98, 0.0), (R * 0.98, 1.5)], segs=32, uv_m=1.0)
        lathe(m, "Steel", [(0.22, 0.95), (R, 1.75)], segs=32, uv_m=1.0)
        m.color = SILO_W
        lathe(m, "Steel", [(R, 1.5), (R, 5.6)], segs=40, uv_m=1.0)
        m.color = SILO_W
        lathe(m, "Steel", [(R + 0.02, 5.55), (R + 0.02, 5.62), (0.25, 6.05), (0.2, 6.05)], segs=40, uv_m=1.0)
        tb(m, "Steel", GREY, (0.0, 6.05, 0.0), (0.0, 6.2, 0.0), 0.12, segs=12)
        for k in range(4):
            y = 1.8 + k * 1.0
            tb(m, "Steel", DARK, (R + 0.005, y, -0.01), (R + 0.005, y + 0.02, 0.01), 0.004, segs=4)
        lathe(m, "Steel", [(R + 0.01, 3.0), (R + 0.01, 3.03)], segs=40)
        lathe(m, "Steel", [(R + 0.01, 4.5), (R + 0.01, 4.53)], segs=40)
        sh.add((0, 3.1, 0), (2 * R, 6.2, 2 * R))
        # the outlet under the cone, its slide gate and the spout to the +Z belt port
        bx(m, "Steel", DARK, -0.2, 0.2, 0.85, 0.95, -0.2, 0.2)
        bx(m, "Steel", FRAME_Y, -0.3, 0.3, BELT_Y - 0.02, BELT_Y + 0.25, -0.2, 1.1)
        bx(m, "Steel", DARK, -0.27, 0.27, BELT_Y + 0.03, BELT_Y + 0.22, 1.095, 1.1)
        # the bucket elevator: from the inlet boot at −Z up the side to the roof
        bx(m, "Steel", FRAME_Y, -0.32, 0.32, BELT_Y - 0.02, BELT_Y + 0.35, -1.1, -0.75)
        bx(m, "Steel", DARK, -0.28, 0.28, BELT_Y + 0.03, BELT_Y + 0.28, -1.1, -1.095)
        bx(m, "Steel", GREY, -0.18, 0.18, BELT_Y + 0.35, 6.4, -1.05, -0.8)
        bx(m, "Steel", MOTOR, -0.18, 0.18, 6.4, 6.6, -1.08, -0.78)
        tb(m, "Steel", GREY, (0.0, 6.3, -0.9), (0.0, 6.05, -0.25), 0.1, segs=10)
        # tube stubs both sides
        for s in (-1, 1):
            tube_stub(m, (s * 1.1, BELT_Y, 0), (s, 0, 0), (s * 0.7, BELT_Y, 0))
        # a caged ladder up the +X side
        for zz in (-0.2, 0.2):
            bx(m, "Steel", STRUCT, R + 0.06, R + 0.09, 1.0, 6.0, zz - 0.015, zz + 0.015)
        for k in range(16):
            y = 1.2 + k * 0.3
            tb(m, "Steel", STRUCT, (R + 0.075, y, -0.2), (R + 0.075, y, 0.2), 0.012, segs=6)
        return m, sh, []

    def p_chute(mat):
        m, sh = CModel(seed=1591), Shell()
        # the mast on its base plate, the boom out along +Z
        bx(m, "Steel", DARK, -0.4, 0.4, 0.0, 0.03, -0.4, 0.4)
        bx(m, "Steel", FRAME_Y, -0.13, 0.13, 0.03, 3.2, -0.13, 0.13, sh=sh)
        hazard(m, -0.135, 0.135, 0.03, 0.9, -0.135, 0.135, n=6)
        bx(m, "Steel", FRAME_Y, -0.11, 0.11, 2.95, 3.2, 0.13, 2.4)
        tb(m, "Steel", STRUCT, (0.0, 2.5, 0.13), (0.0, 2.95, 1.2), 0.04, segs=8)
        # the spout: a telescoping tube and its rubber sock at the boom's end
        tb(m, "Steel", GREY, (0.0, 2.95, 2.2), (0.0, 2.45, 2.2), 0.16, segs=16)
        tb(m, "Steel", GREY, (0.0, 2.5, 2.2), (0.0, 2.1, 2.2), 0.13, segs=16)
        tb(m, "Rubber", RUBBER, (0.0, 2.12, 2.2), (0.0, 1.85, 2.2), 0.15, segs=16)
        # the inlet hopper at the foot (−Z belt port) and the inclined screw up to the boom
        bx(m, "Steel", FRAME_Y, -0.32, 0.32, BELT_Y - 0.02, BELT_Y + 0.3, -0.6, -0.15)
        bx(m, "Steel", DARK, -0.28, 0.28, BELT_Y + 0.03, BELT_Y + 0.26, -0.6, -0.595)
        tb(m, "Steel", GREY, (0.0, BELT_Y + 0.2, -0.3), (0.0, 3.05, 0.2), 0.11, segs=14)
        tb(m, "Steel", MOTOR, (0.0, 3.05, 0.2), (0.0, 3.2, 0.35), 0.12, segs=12)
        bx(m, "Steel", STRUCT, -0.03, 0.03, 0.0, BELT_Y - 0.02, -0.45, -0.39)
        # the tube inlet on −X
        tube_stub(m, (-0.5, BELT_Y, 0.0), (-1, 0, 0), (-0.13, BELT_Y, 0.0))
        sh.add((0, (BELT_Y + 0.3) / 2, -0.37), (0.64, BELT_Y + 0.3, 0.46))
        return m, sh, []

    # ── the quarry ──
    def p_post(mat):
        m, sh = CModel(seed=1601), Shell()
        bx(m, "Steel", DARK, -0.25, 0.25, 0.0, 0.03, -0.25, 0.25)
        # a 300 mm H: two flanges and the web
        for s in (-1, 1):
            bx(m, "Steel", FRAME_Y, -0.15, 0.15, 0.03, 2.85, s * 0.15 - 0.012, s * 0.15 + 0.012)
        bx(m, "Steel", FRAME_Y, -0.01, 0.01, 0.03, 2.85, -0.14, 0.14)
        hazard(m, -0.152, 0.152, 0.03, 0.9, -0.165, 0.165, n=6)
        # the rail bracket and the cap
        bx(m, "Steel", DARK, -0.24, 0.24, 2.85, 3.0, -0.24, 0.24)
        bx(m, "Steel", GREY, -0.06, 0.06, 2.6, 2.85, 0.16, 0.24)
        for x in (-0.2, 0.2):
            for z in (-0.2, 0.2):
                tb(m, "Steel", GREY, (x, 0.03, z), (x, 0.07, z), 0.012, segs=6)
        sh.add((0, 1.5, 0), (0.3, 3.0, 0.3))
        return m, sh, []

    def p_drive(mat):
        m, sh = CModel(seed=1611), Shell()
        bx(m, "Steel", DARK, -1.0, 1.0, 0.0, 0.12, -1.0, 1.0, sh=sh)                       # the skid
        # the winch house: a frame, the cable drum, the gear motor, the brake
        bx(m, "Steel", FRAME_Y, -0.95, -0.05, 0.12, 1.5, -0.95, 0.1)
        bx(m, "Steel", DARK, -0.93, -0.07, 1.48, 1.52, -0.97, 0.12)
        tb(m, "Steel", GREY, (-0.9, 1.0, -0.42), (-0.1, 1.0, -0.42), 0.32, segs=24)     # (the drum shows through a window)
        bx(m, "Steel", BLACK, -0.85, -0.15, 0.7, 1.3, 0.1, 0.105)
        tb(m, "Steel", MOTOR, (-0.5, 0.5, 0.12), (-0.5, 0.5, 0.45), 0.18, segs=16)
        bx(m, "Steel", CAB, -0.95, -0.55, 0.12, 1.25, 0.45, 0.95)                       # the control cabinet
        bx(m, "Steel", DARK, -0.93, -0.57, 0.9, 1.15, 0.95, 0.955)
        bx(m, "Steel", (0.9, 0.1, 0.08), -0.80, -0.72, 0.7, 0.78, 0.95, 0.958)
        sh.add((-0.5, 0.8, -0.4), (0.9, 1.4, 1.1))
        # the discharge bin on its frame, its apron chute to the +Z belt port
        for x in (0.15, 0.85):
            for z in (-0.85, -0.15):
                bx(m, "Steel", STRUCT, x - 0.04, x + 0.04, 0.12, 1.6, z - 0.04, z + 0.04)
        bx(m, "Steel", FRAME_Y, 0.08, 0.92, 1.6, 2.5, -0.92, -0.08, sh=sh)
        bx(m, "Steel", DARK, 0.06, 0.94, 2.46, 2.52, -0.94, -0.06)
        tb(m, "Steel", FRAME_Y, (0.5, 1.6, -0.5), (0.5, 1.2, -0.5), 0.18, segs=14)
        bx(m, "Steel", FRAME_Y, 0.2, 0.8, BELT_Y - 0.02, 1.2, -0.75, -0.25)
        bx(m, "Steel", FRAME_Y, -0.3, 0.3, BELT_Y - 0.02, BELT_Y + 0.25, -0.25, 1.0)
        bx(m, "Steel", FRAME_Y, 0.2, 0.8, BELT_Y - 0.02, BELT_Y + 0.25, -0.25, 0.25)
        bx(m, "Steel", DARK, -0.27, 0.27, BELT_Y + 0.03, BELT_Y + 0.22, 0.995, 1.0)
        # the head's cable runs out of the winch house toward the pit (−X)
        tb(m, "Steel", BLACK, (-0.95, 1.0, -0.42), (-1.0, 1.3, -0.42), 0.012, segs=6)
        # the tube discharge on +X
        tube_stub(m, (1.0, BELT_Y, 0.4), (1, 0, 0), (0.5, BELT_Y, 0.4))
        bx(m, "Steel", STRUCT, 0.62, 0.68, 0.12, BELT_Y - TR, 0.37, 0.43)
        # the gantry's power cable reel
        tb(m, "Rubber", RUBBER, (-0.1, 1.85, 0.3), (-0.1, 1.85, 0.9), 0.3, segs=20)
        bx(m, "Steel", STRUCT, -0.14, -0.06, 0.12, 1.85, 0.55, 0.65)
        sh.add((0.5, 0.45, 0.4), (0.6, 0.66, 1.2))
        return m, sh, []

    # (the gantry's moving parts: drawn by logistics.lua, no colliders)
    def p_bridge(mat):
        m, sh = CModel(seed=1621), Shell()
        # a 1 m box-truss unit along X (scaled to the quarry's width): top and bottom chords, a
        # diagonal, the rail on top
        for y in (0.0, 0.5):
            for z in (-0.2, 0.2):
                bx(m, "Steel", FRAME_Y, -0.5, 0.5, y - 0.04, y + 0.04, z - 0.04, z + 0.04)
        for z in (-0.2, 0.2):
            tb(m, "Steel", FRAME_Y, (-0.5, 0.0, z), (0.5, 0.5, z), 0.02, segs=6)
        bx(m, "Steel", DARK, -0.5, 0.5, 0.54, 0.58, -0.06, 0.06)
        return m, sh, []

    def p_cable(mat):
        m, sh = CModel(seed=1631), Shell()
        tb(m, "Steel", BLACK, (0.0, -1.0, -0.1), (0.0, 0.0, -0.1), 0.012, segs=6)
        tb(m, "Steel", BLACK, (0.0, -1.0, 0.1), (0.0, 0.0, 0.1), 0.012, segs=6)
        return m, sh, []

    def p_head(mat):
        m, sh = CModel(seed=1641), Shell()
        # the trolley on the rail, the frame down to the wheel, the bucket wheel (Ø1.2 m)
        wheel = CModel(seed=1642)
        wheel.color = GREY
        lathe(wheel, "Steel", [(0.55, -0.22), (0.6, -0.22), (0.6, 0.22), (0.55, 0.22)], segs=24)
        for k in range(8):
            a = 2 * math.pi * k / 8
            c = (0.62 * math.cos(a), 0.0, 0.62 * math.sin(a))
            M = K.rot_y(-a)
            rbox(wheel, "Steel", DARK, c, (0.16, 0.42, 0.22), M)
        # (the wheel turns in the X–Y plane: its axle along X)
        bx(m, "Steel", FRAME_Y, -0.5, 0.5, 1.45, 1.6, -0.35, 0.35)
        for s in (-1, 1):
            bx(m, "Steel", FRAME_Y, s * 0.42 - 0.04, s * 0.42 + 0.04, 0.6, 1.45, -0.04, 0.04)
        tb(m, "Steel", GREY, (-0.45, 0.6, 0), (0.45, 0.6, 0), 0.08, segs=12)
        m.merge(wheel, M=K.rot_z(math.pi / 2), t=(0.0, 0.6, 0.0))
        tb(m, "Steel", MOTOR, (0.45, 0.6, 0), (0.62, 0.6, 0), 0.14, segs=14)
        return m, sh, []

    out.update({
        "qPost": (p_post, ["steel"]),
        "qDrive": (p_drive, ["steel"]),
        "qBridge": (p_bridge, ["steel"]),
        "qCable": (p_cable, ["steel"]),
        "qHead": (p_head, ["steel"]),
        "cvBelt2": (p_belt(2.0), ["steel"]),
        "cvBelt1": (p_belt(1.0), ["steel"]),
        "cvCorner": (p_corner, ["steel"]),
        "cvMerge": (p_merge, ["steel"]),
        "cvRamp": (p_ramp, ["steel"]),
        "tbTube2": (p_tube(2.0), ["steel"]),
        "tbTube1": (p_tube(1.0), ["steel"]),
        "tbElbow": (p_tube_elbow, ["steel"]),
        "tbBlower": (p_blower, ["steel"]),
        "lgHopper": (p_hopper, ["steel"]),
        "lgSilo": (p_silo, ["steel"]),
        "lgChute": (p_chute, ["steel"]),
    })
    return out


def main():
    """Write only this module's pieces (models, prefabs) and merge their rows into the fixture."""
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
