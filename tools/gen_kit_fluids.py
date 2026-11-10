#!/usr/bin/env python3
"""The kit's FLUID pieces and the S7 pressure pieces (sandbox plan S7; scripts/parts_kit.lua FLUID, LIFE, WALL, FLOOR).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for its
PIECES table, built with its own primitives):

    python3 tools/gen_kit_parts.py flPipe2 flTankWater     # just these (the fixture is not rewritten)

The process line is DN25 (33.7 mm OD stainless). Every port is a flanged stub whose face ends
EXACTLY on the port (at PIPE_Y = 0.6 m over the ground point, a riser's high port 2.4 m above it),
facing out along (nx, nz), so a pipe placed on a port meets it flange to flange. 1:1, real
proportions, industrial paint. The O2 Generator gains its water and hydrogen nozzles at its back and
the Pressuriser its DN25 makeup nozzle (+X): both wrap the existing generators.
"""
import math

import numpy as np

PIPE_Y = 0.6
PR = 0.0169         # DN25 outside radius
FR = 0.045          # its flange
FT = 0.018          # flange thickness

MATERIALS = {}

STAIN = (0.70, 0.71, 0.70)
TANK_WATER = (0.28, 0.40, 0.52)     # potable water: blue enamel
TANK_COOL = (0.36, 0.52, 0.50)      # coolant: teal
TANK_FUEL = (0.56, 0.42, 0.16)      # fuel: amber-brown
O2_WHITE = (0.80, 0.80, 0.78)       # oxygen cylinders: white shoulders (EN 1089-3)
N2_BLACK = (0.10, 0.10, 0.11)       # nitrogen: black
H2_RED = (0.55, 0.12, 0.10)         # hydrogen: red
PUMP_GREEN = (0.24, 0.36, 0.30)
VALVE_RED = (0.55, 0.14, 0.10)
BRASS = (0.62, 0.50, 0.26)
FRAME = (0.42, 0.44, 0.45)


def pieces(K):
    CModel, Shell, bx, tb, rbox = K.CModel, K.Shell, K.bx, K.tb, K.rbox
    tube, lathe, disk = K.tube, K.lathe, K.disk
    DARK, GREY, LIGHT, SAFETY, RUBBER = K.DARK, K.GREY, K.LIGHT, K.SAFETY, K.RUBBER
    UVM = K.UVM
    out = {}

    def nozzle(m, x, z, nx, nz, start, y=PIPE_Y, col=STAIN, r=PR):
        """A stub from `start` to the port at (x, y, z), its flange face ending on the port."""
        port = np.array([x, y, z], float)
        n = np.array([nx, 0.0, nz], float)
        fb = port - n * FT
        tb(m, "Steel", col, start, tuple(fb), r, segs=10)
        tb(m, "Steel", GREY, tuple(fb), tuple(port), FR, segs=12)

    def stand(m, sh, x, z, top=PIPE_Y - PR):
        """A pipe stand: a foot plate, a post and a U-bolt saddle."""
        bx(m, "Steel", DARK, x - 0.06, x + 0.06, 0.0, 0.01, z - 0.06, z + 0.06)
        bx(m, "Steel", GREY, x - 0.02, x + 0.02, 0.01, top - 0.004, z - 0.02, z + 0.02)
        bx(m, "Steel", GREY, x - 0.05, x + 0.05, top - 0.012, top, z - 0.025, z + 0.025)
        sh.add((x, top / 2, z), (0.05, top, 0.05))

    # ── pipes ──
    def p_pipe(L):
        def fn(mat):
            m, sh = CModel(seed=801 + int(L * 10)), Shell()
            h = L / 2
            for s in (-1, 1):
                nozzle(m, 0, s * h, 0, s, (0, PIPE_Y, 0))
            for z in ((-h * 0.6, h * 0.6) if L >= 1.5 else (0.0,)):
                stand(m, sh, 0, z)
            sh.add((0, PIPE_Y, 0), (0.09, 0.09, L))
            return m, sh, []
        return fn

    def p_elbow(mat):
        m, sh = CModel(seed=811), Shell()
        cx, cz, R = 0.5, -0.5, 0.5
        a0, a1 = math.pi - FT / R, math.pi / 2 + FT / R
        n = 10
        pts = [(cx + R * math.cos(a0 + (a1 - a0) * k / n), PIPE_Y, cz + R * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
        m.color = STAIN
        for k in range(n):
            tube(m, "Steel", pts[k], pts[k + 1], PR, segs=10, caps=False, uv_m=UVM["Steel"])
        nozzle(m, 0.0, -0.5, 0, -1, pts[0])
        nozzle(m, 0.5, 0.0, 1, 0, pts[-1])
        a = math.radians(135)
        stand(m, sh, cx + R * math.cos(a), cz + R * math.sin(a))
        sh.add((0.1, PIPE_Y, -0.3), (0.1, 0.1, 0.4))
        return m, sh, []

    def p_tee(mat):
        m, sh = CModel(seed=812), Shell()
        nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, 0))
        nozzle(m, 0, 0.5, 0, 1, (0, PIPE_Y, 0))
        nozzle(m, 0.5, 0, 1, 0, (0, PIPE_Y, 0))
        tb(m, "Steel", STAIN, (0, PIPE_Y - 0.03, 0), (0, PIPE_Y + 0.03, 0), PR + 0.006, segs=10)
        stand(m, sh, 0, -0.25)
        sh.add((0, PIPE_Y, 0), (0.09, 0.09, 1.0))
        return m, sh, []

    def p_riser(mat):
        m, sh = CModel(seed=813), Shell()
        # a bend off each port into the vertical run at z = 0
        y0, y1 = PIPE_Y, PIPE_Y + 2.4
        for y in (y0, y1):
            nozzle(m, 0, -0.5, 0, -1, (0, y, -0.1), y=y)
            tb(m, "Steel", STAIN, (0, y, -0.1), (0, y, 0.0), PR, segs=10)
            tb(m, "Steel", STAIN, (0, y, -0.03), (0, y, 0.021), PR + 0.006, segs=10)
        tb(m, "Steel", STAIN, (0, y0 - 0.02, 0.0), (0, y1 + 0.02, 0.0), PR, segs=10)
        # wall clamps up the run, a foot stand
        stand(m, sh, 0, 0.0, top=y0 - PR)
        for y in (1.4, 2.2):
            bx(m, "Steel", GREY, -0.04, 0.04, y - 0.015, y + 0.015, -0.04, 0.06)
        tb(m, "Steel", SAFETY, (0, 1.75, 0.0), (0, 1.83, 0.0), PR + 0.003, segs=10)
        sh.add((0, (y0 + y1) / 2, 0), (0.06, y1 - y0, 0.06))
        return m, sh, []

    # ── tanks ──
    def p_tank(col, seed, label_col):
        def fn(mat):
            m, sh = CModel(seed=seed), Shell()
            # a vertical 1.2 m vessel on a ring skirt, dished heads, a manway, a level gauge
            bx(m, "Steel", DARK, -0.62, 0.62, 0.0, 0.04, -0.62, 0.62)
            m.color = GREY
            lathe(m, "Steel", [(0.55, 0.04), (0.55, 0.30)], segs=24, uv_m=UVM["Steel"])
            m.color = col
            lathe(m, "Steel", [(0.6, 0.30), (0.6, 2.05)], segs=28, uv_m=UVM["Steel"])
            lathe(m, "Steel", [(0.6, 2.05), (0.52, 2.17), (0.32, 2.25), (0.0, 2.28)], segs=28, uv_m=UVM["Steel"])
            sh.add((0, 1.15, 0), (1.2, 2.25, 1.2))
            # the outlet nozzle at the pipe height, out to the port at z = -1
            nozzle(m, 0, -1.0, 0, -1, (0, PIPE_Y, -0.55))
            # manway on top, the blanket gas regulator, a level gauge glass
            tb(m, "Steel", GREY, (0.2, 2.2, 0.0), (0.2, 2.30, 0.0), 0.12, segs=14)
            tb(m, "Steel", LIGHT, (-0.25, 2.22, 0.1), (-0.25, 2.30, 0.1), 0.03, segs=8)
            tb(m, "Steel", DARK, (0.58, 0.45, 0.25), (0.58, 1.95, 0.25), 0.022, segs=8)
            for yy in (0.55, 1.85):
                tb(m, "Steel", GREY, (0.54, yy, 0.233), (0.58, yy, 0.25), 0.011, segs=6)
            bx(m, "Pane", (1, 1, 1), 0.60, 0.62, 0.5, 1.9, 0.235, 0.265)
            # a band of the substance's colour, the stencil plate
            m.color = label_col
            lathe(m, "Steel", [(0.605, 1.45), (0.605, 1.6)], segs=28, uv_m=UVM["Steel"])
            bx(m, "Steel", LIGHT, -0.18, 0.18, 1.0, 1.25, -0.61, -0.6)
            for k in range(4):
                x = -0.55 + k * 0.366
                bx(m, "Steel", GREY, x - 0.03, x + 0.03, 0.04, 0.32, -0.58 if k % 2 else 0.52, -0.52 if k % 2 else 0.58)
            return m, sh, []
        return fn

    def p_bottles(col, seed):
        def fn(mat):
            m, sh = CModel(seed=seed), Shell()
            bx(m, "Steel", DARK, -0.6, 0.6, 0.0, 0.06, -0.25, 0.25, sh=sh)
            for x in (-0.58, 0.58):
                bx(m, "Steel", GREY, x - 0.02 - (0.003 if x < 0 else 0), x + 0.02 + (0.003 if x > 0 else 0), 0.0, 1.75, -0.24, -0.20)
            bx(m, "Steel", GREY, -0.597, 0.597, 1.70, 1.748, -0.238, -0.202)
            # two back rails the cylinders' straps are bolted to
            for y in (0.4, 1.0):
                bx(m, "Steel", GREY, -0.57, 0.57, y, y + 0.03, -0.238, -0.202)
            for x in (-0.38, 0.0, 0.38):
                tb(m, "Steel", (0.30, 0.31, 0.32), (x, 0.06, 0.0), (x, 1.30, 0.0), 0.115, segs=16)
                m.color = col
                tube(m, "Steel", (x, 1.30, 0.0), (x, 1.46, 0.0), 0.115, segs=16, uv_m=UVM["Steel"], r1=0.04)
                tb(m, "Steel", BRASS, (x, 1.46, 0.0), (x, 1.54, 0.0), 0.025, segs=8)
                for y in (0.4, 1.0):
                    tb(m, "Steel", DARK, (x, y, 0.0), (x, y + 0.03, 0.0), 0.119, segs=12)
                    bx(m, "Steel", DARK, x - 0.015, x + 0.015, y + 0.005, y + 0.025, -0.21, -0.11)
                tb(m, "Steel", STAIN, (x, 1.535, 0.0), (x, 1.60, 0.0), 0.008, segs=6)
                tb(m, "Steel", STAIN, (x, 1.585, 0.0), (x, 1.615, 0.0), 0.02, segs=10)
                sh.add((x, 0.75, 0), (0.24, 1.4, 0.24))
            # the header over the valves, its branch back into the down-run, the elbow into the port's nozzle
            tb(m, "Steel", STAIN, (-0.40, 1.60, 0.0), (0.40, 1.60, 0.0), 0.014, segs=8)
            tb(m, "Steel", STAIN, (0.0, 1.60, 0.0), (0.0, 1.60, -0.3), 0.014, segs=8)
            tb(m, "Steel", STAIN, (0.0, 1.62, -0.3), (0.0, PIPE_Y, -0.3), PR, segs=10)
            tb(m, "Steel", STAIN, (0.0, PIPE_Y, -0.32), (0.0, PIPE_Y, -0.28), PR + 0.006, segs=10)
            nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, -0.3))
            # the contents gauge on the middle boss
            tb(m, "Steel", STAIN, (0.0, 1.61, 0.0), (0.0, 1.645, 0.0), 0.006, segs=6)
            tb(m, "Steel", LIGHT, (0.0, 1.64, 0.0), (0.0, 1.68, 0.0), 0.04, segs=12)
            return m, sh, []
        return fn

    # ── pumps ──
    def p_pump(big):
        def fn(mat):
            m, sh = CModel(seed=821 + (1 if big else 0)), Shell()
            L = 0.75 if big else 0.5
            w = 0.45 if big else 0.3
            bx(m, "Steel", DARK, -w, w, 0.0, 0.08, -L + 0.12, L - 0.12, sh=sh)
            if big:
                # a triplex plunger pump: the crank case, three heads, the motor on its side
                bx(m, "Steel", PUMP_GREEN, -0.32, 0.32, 0.08, 0.52, -0.25, 0.30, sh=sh)
                for k in range(3):
                    x = -0.2 + 0.2 * k
                    tb(m, "Steel", STAIN, (x, 0.52, 0.0), (x, 0.82, 0.0), 0.06, segs=10)
                    tb(m, "Steel", GREY, (x, 0.82, 0.0), (x, 0.90, 0.0), 0.075, segs=10)
                bx(m, "Steel", STAIN, -0.27, 0.27, PIPE_Y - 0.04, PIPE_Y + 0.04, -0.075, 0.075)
                tb(m, "Steel", PUMP_GREEN, (-0.42, 0.30, 0.45), (0.42, 0.30, 0.45), 0.2, segs=16)
                sh.add((0, 0.3, 0.45), (0.84, 0.4, 0.4))
                tb(m, "Steel", DARK, (0.42, 0.30, 0.45), (0.44, 0.30, 0.45), 0.08, segs=10)
                nozzle(m, 0, -L, 0, -1, (0, PIPE_Y, -0.06))
                nozzle(m, 0, L, 0, 1, (0, PIPE_Y, 0.06))
                bx(m, "Steel", (0.75, 0.15, 0.12), -0.12, 0.12, 0.9, 1.08, -0.06, 0.06)
            else:
                # a close-coupled end-suction pump: the volute, the motor behind it
                tb(m, "Steel", PUMP_GREEN, (0, PIPE_Y, -0.12), (0, PIPE_Y, 0.04), 0.16, segs=18)
                tb(m, "Steel", PUMP_GREEN, (0, 0.30, 0.04), (0, 0.30, 0.34), 0.13, segs=16)
                sh.add((0, 0.45, 0.1), (0.36, 0.7, 0.5))
                for k in range(6):
                    a = k * math.tau / 6
                    bx(m, "Steel", PUMP_GREEN, -0.012 + 0.13 * math.cos(a), 0.012 + 0.14 * math.cos(a), 0.30 + 0.13 * math.sin(a) - 0.01,
                       0.30 + 0.14 * math.sin(a) + 0.01, 0.06, 0.32)
                tb(m, "Steel", GREY, (0, 0.30, 0.34), (0, 0.30, 0.38), 0.07, segs=12)
                bx(m, "Steel", DARK, -0.06, 0.06, 0.43, 0.52, 0.12, 0.26)
                bx(m, "Steel", GREY, -0.09, 0.09, 0.08, 0.17, 0.05, 0.33)
                tb(m, "Steel", GREY, (0, PIPE_Y, 0.04), (0, PIPE_Y + 0.25, 0.04), 0.03, segs=8)
                nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, -0.12))
                tb(m, "Steel", STAIN, (0, PIPE_Y + 0.25, 0.04), (0, PIPE_Y + 0.25, 0.2), PR, segs=10)
                tb(m, "Steel", STAIN, (0, PIPE_Y + 0.25, 0.2), (0, PIPE_Y, 0.2), PR, segs=10)
                for yy in (PIPE_Y + 0.25, PIPE_Y):
                    tb(m, "Steel", STAIN, (0, yy, 0.175), (0, yy, 0.222), PR + 0.006, segs=10)
                nozzle(m, 0, 0.5, 0, 1, (0, PIPE_Y, 0.2))
                tb(m, "Steel", DARK, (0, PIPE_Y + 0.25, 0.04), (0, 0.9, 0.04), 0.012, segs=6)
            # the flow arrow on the skid, in → out (−Z → +Z)
            bx(m, "Steel", SAFETY, w - 0.06, w - 0.02, 0.08, 0.086, -L + 0.18, L - 0.25)
            for s in (-1, 1):
                rbox(m, "Steel", SAFETY, (w - 0.04 + s * 0.025, 0.085 + (0.003 if s > 0 else 0.0), L - 0.22), (0.022, 0.008, 0.1), K.rot_y(s * math.radians(35)))
            return m, sh, []
        return fn

    # ── inline fittings ──
    def inline(seed, body):
        def fn(mat):
            m, sh = CModel(seed=seed), Shell()
            nozzle(m, 0, -0.25, 0, -1, (0, PIPE_Y, -0.08))
            nozzle(m, 0, 0.25, 0, 1, (0, PIPE_Y, 0.08))
            stand(m, sh, 0, 0.0, top=PIPE_Y - 0.05)
            body(m, sh)
            return m, sh, []
        return fn

    def gate_valve(m, sh):
        tb(m, "Steel", VALVE_RED, (0, PIPE_Y, -0.08), (0, PIPE_Y, 0.08), 0.05, segs=12)
        tb(m, "Steel", VALVE_RED, (0, PIPE_Y, 0), (0, PIPE_Y + 0.16, 0), 0.04, segs=10)
        tb(m, "Steel", GREY, (0, PIPE_Y + 0.16, 0), (0, PIPE_Y + 0.26, 0), 0.008, segs=6)
        m.color = VALVE_RED
        sub = CModel(seed=1); sub.ground = False; sub.color = VALVE_RED
        disk(sub, "Steel", 0.085, 0.0, segs=18, up=True, r_in=0.07)
        m.merge(sub, t=(0, PIPE_Y + 0.26, 0))
        for k in range(3):
            a = k * math.tau / 3
            tb(m, "Steel", VALVE_RED, (0, PIPE_Y + 0.26, 0), (0.075 * math.cos(a), PIPE_Y + 0.26, 0.075 * math.sin(a)), 0.006, segs=5)
        sh.add((0, PIPE_Y + 0.1, 0), (0.12, 0.3, 0.18))

    def check_valve(m, sh):
        tb(m, "Steel", GREY, (0, PIPE_Y, -0.08), (0, PIPE_Y, 0.08), 0.042, segs=12)
        tb(m, "Steel", GREY, (0, PIPE_Y, 0.0), (0, PIPE_Y + 0.07, 0.0), 0.03, segs=10)
        bx(m, "Steel", SAFETY, -0.006, 0.006, PIPE_Y + 0.07, PIPE_Y + 0.074, -0.05, 0.05)
        sh.add((0, PIPE_Y, 0), (0.09, 0.12, 0.16))

    def regulator(m, sh):
        tb(m, "Steel", BRASS, (0, PIPE_Y, -0.08), (0, PIPE_Y, 0.08), 0.04, segs=12)
        tb(m, "Steel", BRASS, (0, PIPE_Y, 0), (0, PIPE_Y + 0.08, 0), 0.06, segs=14)
        tb(m, "Steel", DARK, (0, PIPE_Y + 0.08, 0), (0, PIPE_Y + 0.2, 0), 0.075, segs=16)
        tb(m, "Steel", GREY, (0, PIPE_Y + 0.2, 0), (0, PIPE_Y + 0.25, 0), 0.015, segs=8)
        for s in (-1, 1):
            tb(m, "Steel", LIGHT, (0, PIPE_Y, s * 0.05), (0.07, PIPE_Y + 0.05, s * 0.05), 0.006, segs=5)
            tb(m, "Steel", LIGHT, (0.07, PIPE_Y + 0.05, s * 0.05), (0.075, PIPE_Y + 0.05, s * 0.05), 0.025, segs=10)
        sh.add((0, PIPE_Y + 0.1, 0), (0.15, 0.3, 0.16))

    def gauge(m, sh):
        tb(m, "Steel", STAIN, (0, PIPE_Y, -0.08), (0, PIPE_Y, 0.08), 0.025, segs=10)
        tb(m, "Steel", STAIN, (0, PIPE_Y, 0), (0, PIPE_Y + 0.12, 0), 0.008, segs=6)
        sub = CModel(seed=2); sub.ground = False; sub.color = DARK
        disk(sub, "Steel", 0.055, 0.0, segs=20, up=True)
        lathe(sub, "Steel", [(0.055, 0.0), (0.055, -0.03)], segs=20)
        m.merge(sub, M=K.rot_x(-math.pi / 2), t=(0, PIPE_Y + 0.18, 0.015))
        bx(m, "Pane", (1, 1, 1), -0.038, 0.038, PIPE_Y + 0.142, PIPE_Y + 0.218, 0.0225, 0.0245)
        bx(m, "Steel", LIGHT, -0.037, 0.037, PIPE_Y + 0.143, PIPE_Y + 0.217, 0.0175, 0.0195)
        bx(m, "Steel", (0.75, 0.15, 0.12), -0.002, 0.03, PIPE_Y + 0.178, PIPE_Y + 0.182, 0.0200, 0.0215)
        sh.add((0, PIPE_Y + 0.08, 0), (0.12, 0.3, 0.1))

    # ── terminals ──
    def p_outlet(mat):
        m, sh = CModel(seed=831), Shell()
        bx(m, "Steel", DARK, -0.18, 0.18, 0.0, 0.02, -0.18, 0.18)
        tb(m, "Steel", STAIN, (0, 0.02, 0), (0, 0.85, 0), 0.03, segs=10)
        tb(m, "Steel", STAIN, (0, PIPE_Y, 0), (0, PIPE_Y, -0.2), PR, segs=10)
        nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, -0.2))
        # the diffuser: a perforated drum
        tb(m, "Steel", LIGHT, (0, 0.85, 0), (0, 0.99, 0), 0.12, segs=18)
        for k in range(10):
            a = k * math.tau / 10
            bx(m, "Steel", DARK, 0.118 * math.cos(a) - 0.01, 0.118 * math.cos(a) + 0.01, 0.88, 0.96, 0.118 * math.sin(a) - 0.01, 0.118 * math.sin(a) + 0.01)
        sh.add((0, 0.5, 0), (0.24, 1.0, 0.24))
        return m, sh, []

    def p_vent(mat):
        m, sh = CModel(seed=832), Shell()
        bx(m, "Steel", DARK, -0.18, 0.18, 0.0, 0.02, -0.18, 0.18)
        tb(m, "Steel", GREY, (0, 0.02, 0), (0, 2.45, 0), 0.04, segs=10)
        tb(m, "Steel", STAIN, (0, PIPE_Y, 0), (0, PIPE_Y, -0.2), PR, segs=10)
        nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, -0.2))
        # a goose-neck with its bird screen
        tb(m, "Steel", GREY, (0, 2.45, 0), (0, 2.55, 0.1), 0.04, segs=10)
        tb(m, "Steel", GREY, (0, 2.55, 0.1), (0, 2.5, 0.18), 0.045, segs=10)
        for y in (1.2, 2.0):
            tb(m, "Steel", SAFETY, (0, y, 0), (0, y + 0.06, 0), 0.043, segs=10)
        sh.add((0, 1.3, 0), (0.1, 2.6, 0.1))
        return m, sh, []

    def p_hose(mat):
        m, sh = CModel(seed=833), Shell()
        bx(m, "Steel", DARK, -0.38, 0.38, 0.0, 0.05, -0.3, 0.38, sh=sh)
        # the 50 L day tank, the reel and its hose, the nozzle hung on its hook
        tb(m, "Steel", TANK_FUEL, (-0.25, 0.35, -0.2), (0.25, 0.35, -0.2), 0.17, segs=16)
        sh.add((0, 0.35, -0.2), (0.5, 0.34, 0.34))
        tb(m, "Steel", STAIN, (0, PIPE_Y, -0.2), (0, PIPE_Y, -0.3), PR, segs=8)
        tb(m, "Steel", STAIN, (0, 0.35, -0.2), (0, PIPE_Y, -0.2), PR, segs=8)
        tb(m, "Steel", STAIN, (0, PIPE_Y, -0.222), (0, PIPE_Y, -0.178), PR + 0.006, segs=8)
        nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, -0.3))
        for x in (-0.3, 0.3):
            bx(m, "Steel", GREY, x - 0.03, x + 0.03, 0.05, 1.35, 0.12, 0.18)
        tb(m, "Steel", (0.75, 0.15, 0.12), (-0.27, 1.05, 0.15), (0.27, 1.05, 0.15), 0.2, segs=18)
        tb(m, "Rubber", RUBBER, (-0.2, 1.05, 0.15), (0.2, 1.05, 0.15), 0.215, segs=18)
        sh.add((0, 1.05, 0.15), (0.6, 0.44, 0.44))
        tb(m, "Rubber", RUBBER, (0.25, 0.9, 0.35), (0.3, 0.4, 0.38), 0.02, segs=6)
        bx(m, "Steel", DARK, 0.26, 0.34, 0.25, 0.42, 0.33, 0.39)
        bx(m, "Steel", LIGHT, -0.2, 0.2, 1.4, 1.58, 0.14, 0.16)
        return m, sh, []

    # ── the pressure pieces (S7 part B) ──
    def p_receiver(mat):
        m, sh = CModel(seed=841), Shell()
        bx(m, "Steel", DARK, -0.42, 0.42, 0.0, 0.05, -0.42, 0.42)
        for x, z in ((-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)):
            bx(m, "Steel", GREY, x - 0.03, x + 0.03, 0.05, 0.36, z - 0.03, z + 0.03)
        m.color = (0.30, 0.42, 0.33)
        lathe(m, "Steel", [(0.0, 0.25), (0.25, 0.28), (0.4, 0.38), (0.4, 1.65), (0.25, 1.76), (0.0, 1.80)], segs=26, uv_m=UVM["Steel"])
        sh.add((0, 1.0, 0), (0.8, 1.55, 0.8))
        tb(m, "Steel", LIGHT, (0, 1.8, 0), (0, 1.9, 0), 0.03, segs=8)
        tb(m, "Steel", DARK, (0, 1.9, 0), (0.12, 1.96, 0), 0.04, segs=10)
        bx(m, "Steel", SAFETY, -0.15, 0.15, 1.2, 1.4, 0.39, 0.405)
        tb(m, "Steel", STAIN, (0.0, 1.1, -0.38), (0.0, 1.1, -0.44), 0.02, segs=8)
        return m, sh, []

    def p_eqValve(mat):
        m, sh = CModel(seed=842), Shell()
        m.ground = False
        # a mount: +Y out of the face it sits on. The sleeve through the wall's
        # face, its flange, the ball valve and its lever, a tag
        sub = CModel(seed=3); sub.ground = False; sub.color = GREY
        disk(sub, "Steel", 0.11, 0.02, segs=20, up=True)
        lathe(sub, "Steel", [(0.11, 0.0), (0.11, 0.02)], segs=20)
        m.merge(sub)
        tb(m, "Steel", STAIN, (0, 0.02, 0), (0, 0.09, 0), 0.03, segs=10)
        tb(m, "Steel", (0.75, 0.15, 0.12), (0, 0.09, 0), (0, 0.13, 0), 0.045, segs=12)
        tb(m, "Steel", (0.75, 0.15, 0.12), (0, 0.13, 0), (0.15, 0.16, 0.0), 0.012, segs=6)
        bx(m, "Steel", SAFETY, -0.08, 0.08, 0.0, 0.004, -0.16, -0.12)
        return m, sh, []

    def p_bulkhead(mat):
        m, sh = CModel(seed=843), Shell()
        WT, WH = K.WT, K.WH
        # (Ty 11-10: 2.08 m, not 1.95: the 1.9 m capsule walks through with 18 cm over its head)
        K.wall_body(m, sh, mat, -1, 1, 0, WH, holes=[(-0.92, 0.0, 0.0, 2.08)], trims=False)
        for s in (-1, 1):
            z0, z1 = s * WT / 2, s * (WT / 2 + 0.07)
            for (a, b, c, d, pr) in ((-0.998, -0.918, 0, 2.082, 0.0), (-0.002, 0.08, 0, 2.082, 0.0), (-0.996, 0.082, 2.08, 2.197, 0.002)):
                bx(m, "Steel", FRAME, a, b, c, d, min(z0, z1) - (pr if s < 0 else 0), max(z0, z1) + (pr if s > 0 else 0))
            # dogs round the frame
            for y in (0.4, 1.0, 1.6):
                bx(m, "Steel", DARK, 0.02, 0.07, y, y + 0.08, min(z0, z1) - 0.02 if s < 0 else max(z0, z1), (min(z0, z1) if s < 0 else max(z0, z1) + 0.02))
            # the equalising valve and its gauge beside the door
            zf = s * (WT / 2 + 0.01)
            tb(m, "Steel", STAIN, (0.3, 1.2, s * (WT / 2 - 0.005)), (0.3, 1.2, s * (WT / 2 + 0.07)), 0.02, segs=8)
            tb(m, "Steel", (0.75, 0.15, 0.12), (0.3, 1.2, s * (WT / 2 + 0.07)), (0.42, 1.24, s * (WT / 2 + 0.07)), 0.01, segs=6)
            bx(m, "Steel", DARK, 0.22, 0.38, 1.36, 1.52, zf - 0.02 if s < 0 else zf, zf if s < 0 else zf + 0.02)
            bx(m, "Lamp", (1.0, 0.75, 0.25), 0.27, 0.33, 1.42, 1.46, s * (WT / 2 + 0.03), s * (WT / 2 + 0.0325))
        lm, lsh = K.door_leaf(0.96, 2.08, heavy=True, t=0.08)
        return m, sh, [("Door", "door", (lm, lsh, (-0.46, 0.0, 0.0)))]

    def p_pressHatch(mat):
        m, sh = CModel(seed=844), Shell()
        m.ground = False
        hole = (-0.95, -0.05, -0.45, 0.45)
        K.floor_body(m, sh, mat, -1, 1, -1, 1, holes=[hole])
        # a heavy coaming round the hatch, the equalising valve at its side
        for (a, b, c, d) in ((-0.998, -0.948, -0.5, 0.5), (-0.052, -0.002, -0.5, 0.5), (-0.948, -0.052, -0.498, -0.448), (-0.948, -0.052, 0.448, 0.498)):
            bx(m, "Steel", FRAME, a, b, 0.2, 0.26, c, d)
        tb(m, "Steel", STAIN, (0.15, 0.2, 0.3), (0.15, 0.27, 0.3), 0.02, segs=8)
        tb(m, "Steel", (0.75, 0.15, 0.12), (0.15, 0.27, 0.3), (0.27, 0.275, 0.3), 0.01, segs=6)
        lm = CModel(seed=845); lm.ground = False
        lsh = Shell()
        bx(lm, "Steel", (0.50, 0.51, 0.52), -0.45, 0.45, -0.07, 0.0, -0.45, 0.45)
        lsh.add((0, -0.035, 0), (0.9, 0.07, 0.9))
        for k in range(4):
            bx(lm, "Steel", SAFETY if k % 2 == 0 else DARK, -0.45 + k * 0.225, -0.45 + (k + 1) * 0.225, 0.0, 0.004, 0.36, 0.44)
        tb(lm, "Steel", GREY, (-0.1, 0.0, 0.0), (0.1, 0.0, 0.0), 0.02, segs=6)
        return m, sh, [("Door", "door", (lm, lsh, (-0.5, 0.2, 0.0)))]

    # ── wrappers: the O2 Generator's two nozzles, the Pressuriser's makeup nozzle ──
    base_o2 = K.PIECES["o2gen"][0]

    def p_o2gen(mat):
        m, sh, ch = base_o2(mat)
        for x in (0.2, -0.2):
            tb(m, "Steel", STAIN, (x, PIPE_Y, -0.22), (x, PIPE_Y, -0.28), PR, segs=8)
            nozzle(m, x, -0.3, 0, -1, (x, PIPE_Y, -0.28), col=(0.30, 0.45, 0.65) if x > 0 else H2_RED)
        return m, sh, ch

    out.update({
        "flPipe2": (p_pipe(2.0), ["steel"]),
        "flPipe1": (p_pipe(1.0), ["steel"]),
        "flElbow": (p_elbow, ["steel"]),
        "flTee": (p_tee, ["steel"]),
        "flRiser": (p_riser, ["steel"]),
        "flTankWater": (p_tank(TANK_WATER, 851, (0.15, 0.35, 0.75)), ["steel"]),
        "flTankCool": (p_tank(TANK_COOL, 852, (0.20, 0.65, 0.60)), ["steel"]),
        "flTankFuel": (p_tank(TANK_FUEL, 853, (0.85, 0.55, 0.10)), ["steel"]),
        "flBottleO2": (p_bottles(O2_WHITE, 861), ["steel"]),
        "flBottleN2": (p_bottles(N2_BLACK, 862), ["steel"]),
        "flBottleH2": (p_bottles(H2_RED, 863), ["steel"]),
        "flPump": (p_pump(False), ["steel"]),
        "flCharge": (p_pump(True), ["steel"]),
        "flValve": (inline(871, gate_valve), ["steel"]),
        "flCheck": (inline(872, check_valve), ["steel"]),
        "flReg": (inline(873, regulator), ["steel"]),
        "flGauge": (inline(874, gauge), ["steel"]),
        "flOutlet": (p_outlet, ["steel"]),
        "flVent": (p_vent, ["steel"]),
        "flHose": (p_hose, ["steel"]),
        "airReceiver": (p_receiver, ["steel"]),
        "eqValve": (p_eqValve, ["steel"]),
        "bulkhead": (p_bulkhead, ["steel"]),
        "pressHatch": (p_pressHatch, ["steel"]),
        "o2gen": (p_o2gen, ["steel"]),
    })
    return out


def pressuriser_wrap(K, fn):
    """The Pressuriser with its DN25 makeup nozzle at +X (port 'makeup', x 0.5, z 0)."""
    def wrapped(mat):
        m, sh, ch = fn(mat)
        port = np.array([0.5, PIPE_Y, 0.0])
        K.tb(m, "Steel", STAIN, (0.38, PIPE_Y, 0.0), tuple(port - np.array([FT, 0, 0])), PR, segs=10)
        K.tb(m, "Steel", K.GREY, tuple(port - np.array([FT, 0, 0])), tuple(port), FR, segs=12)
        return m, sh, ch
    return wrapped
