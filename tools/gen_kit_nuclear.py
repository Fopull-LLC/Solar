#!/usr/bin/env python3
"""The kit's NUCLEAR pieces (sandbox plan S6; scripts/parts_kit.lua NUCLEAR, two SHIELD blocks).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for
its PIECES table, built with its own primitives):

    python3 tools/gen_kit_parts.py                       # everything
    python3 tools/gen_kit_parts.py reactorBase pipe2     # just these (the fixture is not rewritten)

A reactor is a layout: 0.5 m columns (fuel channels, moderator, control rods) stand on the
Reactor Vessel Base's 5 x 5 grid plate, and pipes and components meet at PORTS. Every port is at
PIPE_Y = 0.6 m over the piece's ground point, on the 0.5 m grid, and each one is modelled as a
DN100 nozzle (OD 0.114 m) whose flange face ends EXACTLY on the port, facing out along (nx, nz):
a pipe placed on a port meets it flange to flange. 1:1, real proportions, industrial paint.
"""
import math

import numpy as np

PIPE_Y = 0.6
PR = 0.057          # DN100 outside radius
FR = 0.105          # its flange
FT = 0.03           # flange thickness

MATERIALS = {}

STAIN = (0.70, 0.71, 0.70)       # stainless, brushed
VESSEL = (0.62, 0.64, 0.63)
GRAPH = (0.15, 0.15, 0.16)       # nuclear graphite
GRAPH_LINE = (0.07, 0.07, 0.08)
TANK = (0.45, 0.50, 0.54)        # a steel tank in blue-grey enamel
WATER = (0.10, 0.22, 0.30)
GEN_GREEN = (0.34, 0.40, 0.36)
PUMP_BLUE = (0.22, 0.32, 0.44)
MAGNETITE = (0.40, 0.36, 0.33)
RUST = (0.42, 0.22, 0.12)
BLACKPAINT = (0.06, 0.06, 0.065)


def pieces(K):
    CModel, Shell, bx, tb, rbox = K.CModel, K.Shell, K.bx, K.tb, K.rbox
    tube, lathe, rot_x = K.tube, K.lathe, K.rot_x
    DARK, GREY, LIGHT, SAFETY, RUBBER = K.DARK, K.GREY, K.LIGHT, K.SAFETY, K.RUBBER
    UVM = K.UVM
    out = {}

    # ── shared bits ──
    def nozzle(m, x, z, nx, nz, start, col=STAIN, r=PR):
        """A pipe stub from `start` (x, y, z) to the port at (x, PIPE_Y, z), its flange
        face ending on the port."""
        port = np.array([x, PIPE_Y, z], float)
        n = np.array([nx, 0.0, nz], float)
        fb = port - n * FT
        tb(m, "Steel", col, start, tuple(fb), r, segs=12)
        tb(m, "Steel", GREY, tuple(fb), tuple(port), FR, segs=14)
        # bolt heads on the flange's back face
        side = np.array([-nz, 0.0, nx])
        up = np.array([0.0, 1.0, 0.0])
        for k in range(6):
            a = k * math.tau / 6 + 0.3
            p = fb + (side * math.cos(a) + up * math.sin(a)) * (FR - 0.022)
            tb(m, "Steel", DARK, tuple(p), tuple(p - n * 0.014), 0.009, segs=6)

    def stanchion(m, sh, x, z, top=PIPE_Y - PR, w=0.11):
        """A pipe support: a post on its base plate, a saddle under the pipe."""
        bx(m, "Steel", GREY, x - w, x + w, 0.0, 0.015, z - 0.09, z + 0.09)
        tb(m, "Steel", GREY, (x, 0.015, z), (x, top - 0.03, z), 0.028, segs=8)
        bx(m, "Steel", DARK, x - 0.07, x + 0.07, top - 0.03, top, z - 0.04, z + 0.04)
        sh.add((x, (top) / 2, z), (0.06, top, 0.06))

    def column_base(m, col=GREY):
        """The foot every column stands in the grid plate with."""
        bx(m, "Steel", col, -0.24, 0.24, 0.0, 0.06, -0.24, 0.24)

    # ── the vessel base ──
    def p_reactorBase(mat):
        m, sh = CModel(seed=601), Shell()
        # the plinth: a heavy stainless lower head and plenum, chamfered
        bx(m, "Steel", VESSEL, -1.25, 1.25, 0.0, 0.08, -1.25, 1.25)
        bx(m, "Steel", STAIN, -1.20, 1.20, 0.08, 0.86, -1.20, 1.20, sh=sh)
        bx(m, "Steel", VESSEL, -1.25, 1.25, 0.86, 0.92, -1.25, 1.25)
        # the grid plate and its 25 channel sockets at 0.5 m pitch
        bx(m, "Steel", (0.55, 0.56, 0.56), -1.25, 1.25, 0.92, 1.0, -1.25, 1.25)
        sh.add((0, 0.96, 0), (2.5, 0.08, 2.5))
        for i in range(5):
            for j in range(5):
                x, z = -1.0 + 0.5 * i, -1.0 + 0.5 * j
                tb(m, "Steel", DARK, (x, 0.995, z), (x, 1.005, z), 0.16, segs=12)
                tb(m, "Steel", GREY, (x, 1.005, z), (x, 1.012, z), 0.11, segs=10)
        # stiffener ribs round the plenum and lifting lugs
        for s in (-1, 1):
            for k in range(5):
                c = -1.0 + 0.5 * k
                bx(m, "Steel", VESSEL, c - 0.02, c + 0.02, 0.1, 0.84, s * 1.20, s * 1.24)
                bx(m, "Steel", VESSEL, s * 1.20, s * 1.24, 0.1, 0.84, c - 0.02, c + 0.02)
        for (x, z) in ((-1.1, -1.1), (1.1, -1.1), (-1.1, 1.1), (1.1, 1.1)):
            bx(m, "Steel", DARK, x - 0.05, x + 0.05, 1.0, 1.06, z - 0.02, z + 0.02)
        # the inlet (cold leg, −Z) and outlet (hot leg, +Z) nozzles, reinforced pads
        for sz in (-1, 1):
            tb(m, "Steel", VESSEL, (0, PIPE_Y, sz * 1.2), (0, PIPE_Y, sz * 1.27), 0.16, segs=16)
            nozzle(m, 0.0, sz * 1.5, 0, sz, (0, PIPE_Y, sz * 1.25), r=0.075)
        # the rating plate and a radiation trefoil plate
        bx(m, "Steel", LIGHT, 0.45, 0.85, 0.35, 0.55, 1.20, 1.205)
        bx(m, "Steel", SAFETY, -0.85, -0.55, 0.32, 0.62, 1.20, 1.205)
        bx(m, "Steel", BLACKPAINT, -0.73, -0.67, 0.44, 0.50, 1.205, 1.207)
        return m, sh, []

    # ── columns ──
    def p_fuelChannel(mat):
        m, sh = CModel(seed=611), Shell()
        column_base(m)
        # the square lattice tube round the pressure tube
        bx(m, "Steel", (0.58, 0.59, 0.58), -0.22, 0.22, 0.06, 2.26, -0.22, 0.22, sh=sh)
        for (x, z) in ((-0.23, -0.23), (0.23, -0.23), (-0.23, 0.23), (0.23, 0.23)):
            bx(m, "Steel", GREY, x - 0.02, x + 0.02, 0.06, 2.26, z - 0.02, z + 0.02)
        for y in (0.5, 1.1, 1.7):
            bx(m, "Steel", GREY, -0.235, 0.235, y, y + 0.04, -0.235, 0.235)
        # the channel head: its closure plug and feeder, over the top
        tb(m, "Steel", STAIN, (0, 2.26, 0), (0, 2.32, 0), 0.19, segs=16)
        tb(m, "Steel", (0.52, 0.53, 0.53), (0, 2.32, 0), (0, 2.38, 0), 0.13, segs=16)
        tb(m, "Steel", DARK, (0, 2.38, 0), (0, 2.42, 0), 0.07, segs=12)
        bx(m, "Steel", DARK, -0.10, 0.10, 2.42, 2.44, -0.015, 0.015)
        tb(m, "Steel", STAIN, (0.13, 2.29, 0.0), (0.24, 2.29, 0.0), 0.025, segs=8)
        # the stencil plate and its hazard band
        bx(m, "Steel", LIGHT, -0.12, 0.12, 1.30, 1.45, 0.22, 0.226)
        bx(m, "Steel", SAFETY, -0.12, 0.12, 1.24, 1.28, 0.22, 0.226)
        return m, sh, []

    def p_modGraphite(mat):
        m, sh = CModel(seed=612), Shell()
        sh.add((0, 1.2, 0), (0.5, 2.4, 0.5))
        # six bricks, each with a joint between, and keyway grooves up the faces
        for k in range(6):
            y0 = k * 0.4
            jit = 1.0 + 0.04 * ((k * 7) % 3 - 1)
            bx(m, "Concrete", tuple(c * jit for c in GRAPH), -0.25, 0.25, y0 + 0.004, y0 + 0.396, -0.25, 0.25)
            bx(m, "Concrete", GRAPH_LINE, -0.245, 0.245, y0, y0 + 0.004, -0.245, 0.245)
        for s in (-1, 1):
            bx(m, "Concrete", GRAPH_LINE, -0.03, 0.03, 0.0, 2.4, s * 0.25 - 0.004, s * 0.25 + 0.004)
            bx(m, "Concrete", GRAPH_LINE, s * 0.25 - 0.004, s * 0.25 + 0.004, 0.0, 2.4, -0.03, 0.03)
        # the central bore's plug on top
        tb(m, "Concrete", GRAPH_LINE, (0, 2.4, 0), (0, 2.405, 0), 0.06, segs=10)
        return m, sh, []

    def water_tank(seed, heavy):
        def fn(mat):
            m, sh = CModel(seed=seed), Shell()
            column_base(m)
            bx(m, "Steel", TANK, -0.23, 0.23, 0.06, 2.32, -0.23, 0.23, sh=sh)
            for y in (0.06, 2.28):
                bx(m, "Steel", GREY, -0.24, 0.24, y, y + 0.04, -0.24, 0.24)
            # the top head, its vent and fill
            tb(m, "Steel", GREY, (0, 2.32, 0), (0, 2.36, 0), 0.16, segs=14)
            tb(m, "Steel", DARK, (0.08, 2.36, 0.08), (0.08, 2.40, 0.08), 0.03, segs=8)
            tb(m, "Steel", LIGHT, (-0.08, 2.36, -0.06), (-0.08, 2.39, -0.06), 0.04, segs=8)
            # a sight glass on its front: the water behind it
            bx(m, "Steel", DARK, -0.05, 0.05, 0.35, 2.05, 0.23, 0.24)
            bx(m, "Steel", WATER, -0.03, 0.03, 0.38, 1.85, 0.24, 0.242)
            bx(m, "Pane", (1, 1, 1), -0.03, 0.03, 0.38, 2.02, 0.243, 0.248)
            if heavy:
                # the heavy-water band and the marking stripe under it
                bx(m, "Steel", SAFETY, -0.235, 0.235, 1.95, 2.10, -0.235, 0.235)
                bx(m, "Steel", BLACKPAINT, -0.20, 0.20, 2.00, 2.047, 0.235, 0.238)
                bx(m, "Steel", BLACKPAINT, 0.235, 0.238, 2.00, 2.05, -0.20, 0.20)
            else:
                bx(m, "Steel", (0.30, 0.48, 0.66), -0.235, 0.235, 1.95, 2.02, -0.235, 0.235)
            return m, sh, []
        return fn

    def p_controlRod(mat):
        m, sh = CModel(seed=615), Shell()
        column_base(m)
        # the guide column: four angle posts and its guide tube, banded
        tb(m, "Steel", LIGHT, (0, 0.06, 0), (0, 2.40, 0), 0.10, segs=14)
        for (x, z) in ((-0.21, -0.21), (0.21, -0.21), (-0.21, 0.21), (0.21, 0.21)):
            bx(m, "Steel", GREY, x - 0.025, x + 0.025, 0.06, 2.40, z - 0.025, z + 0.025)
        for y in (0.45, 1.05, 1.65, 2.25):
            bx(m, "Steel", GREY, -0.238, 0.238, y, y + 0.04, -0.238, 0.238)
        sh.add((0, 1.23, 0), (0.48, 2.34, 0.48))
        # the drive on top: its housing, the stepper motor, the position indicator
        bx(m, "Steel", (0.55, 0.57, 0.56), -0.22, 0.22, 2.40, 2.66, -0.22, 0.22, sh=sh)
        tb(m, "Steel", PUMP_BLUE, (0, 2.66, 0), (0, 2.92, 0), 0.13, segs=16)
        for k in range(5):
            y = 2.69 + k * 0.045
            tb(m, "Steel", PUMP_BLUE, (0, y, 0), (0, y + 0.015, 0), 0.145, segs=16)
        tb(m, "Steel", DARK, (0, 2.92, 0), (0, 3.0, 0), 0.08, segs=12)
        bx(m, "Steel", DARK, 0.12, 0.22, 2.46, 2.60, 0.22, 0.226)
        bx(m, "Lamp", (0.35, 1.0, 0.45), 0.15, 0.19, 2.55, 2.58, 0.226, 0.229)
        bx(m, "Steel", SAFETY, -0.222, 0.222, 2.403, 2.43, -0.222, 0.222)
        # its cable out of the side
        tb(m, "Rubber", RUBBER, (-0.13, 2.8, 0), (-0.24, 2.6, 0), 0.015, segs=6)
        return m, sh, []

    # ── pipes ──
    def p_pipe(L, insulated=False):
        def fn(mat):
            m, sh = CModel(seed=621 + int(L * 10) + (5 if insulated else 0)), Shell()
            h = L / 2
            for s in (-1, 1):
                nozzle(m, 0, s * h, 0, s, (0, PIPE_Y, 0))
            if insulated:
                # the aluminium jacket (80 mm of wool under it) with its seams
                tb(m, "Steel", (0.78, 0.79, 0.80), (0, PIPE_Y, -h + 0.12), (0, PIPE_Y, h - 0.12), 0.135, segs=14)
                n = max(1, int(L / 0.5))
                for k in range(1, n):
                    z = -h + 0.12 + k * (L - 0.24) / n
                    tb(m, "Steel", (0.70, 0.71, 0.72), (0, PIPE_Y, z - 0.008), (0, PIPE_Y, z + 0.008), 0.138, segs=14)
                top = PIPE_Y - 0.135
            else:
                top = PIPE_Y - PR
            zs = (-h * 0.6, h * 0.6) if L >= 1.5 else (0.0,)
            for z in zs:
                stanchion(m, sh, 0, z, top=top, w=0.11)
            r = 0.135 if insulated else FR
            sh.add((0, PIPE_Y, 0), (2 * r, 2 * r, L))
            return m, sh, []
        return fn

    def p_pipeElbow(mat):
        m, sh = CModel(seed=631), Shell()
        cx, cz, R = 0.5, -0.5, 0.5
        # the bend: from port a (0, −0.5) round to port b (0.5, 0), less the flanges
        a0 = math.pi - FT / R
        a1 = math.pi / 2 + FT / R
        n = 10
        pts = [(cx + R * math.cos(a0 + (a1 - a0) * k / n), PIPE_Y, cz + R * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
        m.color = STAIN
        for k in range(n):
            tube(m, "Steel", pts[k], pts[k + 1], PR, segs=12, caps=False, uv_m=UVM["Steel"])
        nozzle(m, 0.0, -0.5, 0, -1, pts[0])
        nozzle(m, 0.5, 0.0, 1, 0, pts[-1])
        a = math.radians(135)
        stanchion(m, sh, cx + R * math.cos(a), cz + R * math.sin(a))
        sh.add((0.06, PIPE_Y, -0.35), (0.2, 0.2, 0.3))
        sh.add((0.35, PIPE_Y, -0.06), (0.3, 0.2, 0.2))
        return m, sh, []

    def p_pipeTee(mat):
        m, sh = CModel(seed=632), Shell()
        nozzle(m, 0, -0.5, 0, -1, (0, PIPE_Y, 0))
        nozzle(m, 0, 0.5, 0, 1, (0, PIPE_Y, 0))
        nozzle(m, 0.5, 0, 1, 0, (0, PIPE_Y, 0))
        tb(m, "Steel", STAIN, (0, PIPE_Y - 0.075, 0), (0, PIPE_Y + 0.075, 0), PR + 0.008, segs=12)
        stanchion(m, sh, 0, -0.25)
        sh.add((0, PIPE_Y, 0), (0.21, 0.21, 1.0))
        sh.add((0.3, PIPE_Y, 0), (0.4, 0.2, 0.2))
        return m, sh, []

    # ── the loop's components ──
    def p_coolantPump(mat):
        m, sh = CModel(seed=641), Shell()
        # the skid
        bx(m, "Steel", DARK, -0.5, 0.5, 0.0, 0.12, -0.75, 0.75, sh=sh)
        for s in (-1, 1):
            bx(m, "Steel", GREY, s * 0.5 - 0.04 * s, s * 0.503, 0.0, 0.14, -0.752, 0.752)
        # the volute casing: a vertical-axis case, its suction and discharge nozzles
        tb(m, "Steel", PUMP_BLUE, (0, 0.30, 0), (0, 0.86, 0), 0.34, segs=20)
        tb(m, "Steel", GREY, (0, 0.86, 0), (0, 0.92, 0), 0.36, segs=20)
        tb(m, "Steel", PUMP_BLUE, (0, 0.12, 0), (0, 0.30, 0), 0.22, segs=16)
        sh.add((0, 0.52, 0), (0.68, 0.8, 0.68))
        nozzle(m, 0, -1.0, 0, -1, (0, PIPE_Y, -0.25), col=PUMP_BLUE, r=0.07)
        nozzle(m, 0, 1.0, 0, 1, (0, PIPE_Y, 0.25), col=PUMP_BLUE, r=0.07)
        # the motor stool and the canned motor with its fins and terminal box
        tb(m, "Steel", GREY, (0, 0.92, 0), (0, 1.02, 0), 0.20, segs=16)
        tb(m, "Steel", PUMP_BLUE, (0, 1.02, 0), (0, 1.42, 0), 0.25, segs=20)
        for k in range(8):
            a = k * math.tau / 8
            c, s_ = math.cos(a), math.sin(a)
            bx(m, "Steel", PUMP_BLUE, c * 0.25 - 0.012, c * 0.29 + 0.012, 1.05, 1.39, s_ * 0.25 - 0.012, s_ * 0.27 + 0.012)
        tb(m, "Steel", GREY, (0, 1.42, 0), (0, 1.48, 0), 0.20, segs=16)
        tb(m, "Steel", DARK, (0, 1.48, 0), (0, 1.50, 0), 0.06, segs=10)
        sh.add((0, 1.21, 0), (0.56, 0.58, 0.56))
        bx(m, "Steel", DARK, 0.25, 0.40, 1.15, 1.32, -0.08, 0.08)
        tb(m, "Rubber", RUBBER, (0.40, 1.2, 0), (0.46, 0.12, 0.0), 0.02, segs=6)
        # its flow arrow on the skid, in → out (−Z → +Z)
        bx(m, "Steel", SAFETY, 0.36, 0.42, 0.12, 0.128, -0.55, 0.35)
        for s in (-1, 1):
            M = K.rot_y(s * math.radians(35))
            rbox(m, "Steel", SAFETY, (0.39 + s * 0.04, 0.125 + (0.003 if s > 0 else 0.0), 0.40), (0.035, 0.010, 0.16), M)
        bx(m, "Steel", LIGHT, -0.20, 0.20, 0.55, 0.70, -0.345, -0.34)
        return m, sh, []

    def p_pressuriser(mat):
        m, sh = CModel(seed=651), Shell()
        # the skirt, the heater flange under the lower head
        m.color = VESSEL
        lathe(m, "Steel", [(0.40, 0.0), (0.40, 0.42)], segs=24, uv_m=UVM["Steel"])
        bx(m, "Steel", DARK, -0.44, 0.44, 0.0, 0.03, -0.44, 0.44)
        tb(m, "Steel", GREY, (0, 0.30, 0), (0, 0.38, 0), 0.22, segs=16)
        for k in range(6):
            a = k * math.tau / 6
            tb(m, "Steel", DARK, (0.12 * math.cos(a), 0.18, 0.12 * math.sin(a)), (0.12 * math.cos(a), 0.30, 0.12 * math.sin(a)), 0.02, segs=6)
        # the vessel: its shell and hemispherical heads
        m.color = LIGHT
        prof = [(0.0, 0.36), (0.22, 0.38), (0.36, 0.45), (0.42, 0.60), (0.42, 3.15), (0.36, 3.33), (0.22, 3.42), (0.0, 3.45)]
        lathe(m, "Steel", prof, segs=24, uv_m=UVM["Steel"], smooth=True)
        sh.add((0, 1.8, 0), (0.84, 3.1, 0.84))
        for y in (1.2, 2.2):
            tb(m, "Steel", VESSEL, (0, y, 0), (0, y + 0.04, 0), 0.43, segs=24)
        # the surge nozzle out to its port (−Z)
        nozzle(m, 0, -1.0, 0, -1, (0, PIPE_Y, -0.35))
        # the spray line, the relief valve and its tailpipe on top
        tb(m, "Steel", STAIN, (0, 3.44, 0), (0, 3.52, 0), 0.06, segs=10)
        bx(m, "Steel", (0.62, 0.20, 0.14), -0.07, 0.07, 3.52, 3.60, -0.07, 0.07)
        tb(m, "Steel", STAIN, (0.07, 3.56, 0), (0.30, 3.56, 0), 0.025, segs=8)
        tb(m, "Steel", STAIN, (0.30, 3.56, 0), (0.30, 3.20, 0.32), 0.025, segs=8)
        # level gauge and plate
        tb(m, "Steel", DARK, (0.30, 0.9, 0.30), (0.30, 3.0, 0.30), 0.02, segs=6)
        bx(m, "Steel", SAFETY, -0.18, 0.18, 1.70, 1.85, 0.418, 0.424)
        return m, sh, []

    def p_steamGen(mat):
        m, sh = CModel(seed=661), Shell()
        # four legs to the floor
        for (x, z) in ((-0.42, -0.42), (0.42, -0.42), (-0.42, 0.42), (0.42, 0.42)):
            tb(m, "Steel", GREY, (x, 0.0, z), (x, 0.95, z), 0.05, segs=8)
            bx(m, "Steel", DARK, x - 0.09, x + 0.09, 0.0, 0.02, z - 0.09, z + 0.09)
        # the shell: the primary head (hemispherical, low), the tube bundle's
        # shell, the cone up to the steam drum and its dome
        m.color = LIGHT
        prof = [(0.0, 0.30), (0.26, 0.36), (0.45, 0.55), (0.55, 0.85), (0.55, 2.35), (0.68, 2.65), (0.68, 3.35),
                (0.56, 3.58), (0.32, 3.74), (0.0, 3.78)]
        lathe(m, "Steel", prof, segs=28, uv_m=UVM["Steel"], smooth=True)
        tb(m, "Steel", VESSEL, (0, 0.82, 0), (0, 0.90, 0), 0.58, segs=28)
        sh.add((0, 1.55, 0), (1.1, 2.4, 1.1))
        sh.add((0, 3.05, 0), (1.36, 1.0, 1.36))
        # the primary nozzles: hot leg in, cold leg out (−Z), up into the head
        for x in (-0.5, 0.5):
            nozzle(m, x, -1.0, 0, -1, (x, PIPE_Y, -0.40), r=0.075)
            tb(m, "Steel", STAIN, (x, PIPE_Y, -0.40), (x * 0.5, 0.52, -0.22), 0.075, segs=12)
        bx(m, "Steel", (0.62, 0.20, 0.14), -0.50, 0.50, 0.40, 0.44, -0.54, -0.52)
        # the secondary nozzles (+Z): feedwater up into the shell at mid height,
        # the steam line down from the dome
        nozzle(m, 0.5, 1.0, 0, 1, (0.5, PIPE_Y, 0.62))
        tb(m, "Steel", STAIN, (0.5, PIPE_Y, 0.62), (0.5, 1.80, 0.62), PR, segs=12)
        tb(m, "Steel", STAIN, (0.5, 1.80, 0.62), (0.32, 1.80, 0.40), PR, segs=12)
        nozzle(m, -0.5, 1.0, 0, 1, (-0.5, PIPE_Y, 0.62))
        tb(m, "Steel", STAIN, (-0.5, PIPE_Y, 0.62), (-0.5, 3.45, 0.62), PR, segs=12)
        tb(m, "Steel", STAIN, (-0.5, 3.45, 0.62), (-0.28, 3.55, 0.42), PR, segs=12)
        for y in (1.1, 2.3, 3.1):
            bx(m, "Steel", GREY, -0.56, -0.44, y, y + 0.03, 0.56, 0.68)
        # the manway, the level column, the plate
        tb(m, "Steel", GREY, (0, 3.0, 0.66), (0, 3.0, 0.74), 0.18, segs=16)
        tb(m, "Steel", DARK, (0.62, 2.7, -0.2), (0.62, 3.3, -0.2), 0.025, segs=6)
        bx(m, "Steel", SAFETY, -0.20, 0.20, 1.6, 1.75, -0.556, -0.55)
        return m, sh, []

    def p_turbineSet(mat):
        m, sh = CModel(seed=671), Shell()
        # the skid and its rails
        bx(m, "Steel", DARK, -1.75, 1.75, 0.0, 0.18, -0.70, 0.70, sh=sh)
        for s in (-1, 1):
            bx(m, "Steel", GREY, -1.752, 1.752, 0.10, 0.20, s * 0.70 - s * 0.06, s * 0.702)
        # the turbine: casing along X, its pedestals, the steam chest and governor valve
        m.color = LIGHT
        tube(m, "Steel", (-1.55, 0.85, 0), (-0.15, 0.85, 0), 0.40, segs=20, uv_m=UVM["Steel"], r1=0.48)
        tb(m, "Steel", GREY, (-1.62, 0.85, 0), (-1.55, 0.85, 0), 0.22, segs=16)
        tb(m, "Steel", GREY, (-0.15, 0.85, 0), (-0.05, 0.85, 0), 0.30, segs=16)
        bx(m, "Steel", LIGHT, -1.553, -0.147, 0.84, 0.88, -0.44, 0.44)
        for x in (-1.60, -0.10):
            bx(m, "Steel", GREY, x - 0.1, x + 0.1, 0.18, 0.62, -0.25, 0.25)
        sh.add((-0.85, 0.85, 0), (1.5, 0.96, 0.96))
        bx(m, "Steel", (0.58, 0.59, 0.58), -1.22, -0.78, 0.40, 0.98, -0.62, -0.34)
        nozzle(m, -1.0, -1.0, 0, -1, (-1.0, PIPE_Y, -0.60), r=0.075)
        tb(m, "Steel", DARK, (-1.0, 0.98, -0.48), (-1.0, 1.25, -0.48), 0.06, segs=10)
        bx(m, "Steel", (0.62, 0.20, 0.14), -1.08, -0.92, 1.25, 1.40, -0.56, -0.40)
        # the exhaust: down from the casing's end into a duct to its port
        tb(m, "Steel", GREY, (-0.25, 0.75, -0.30), (-0.25, PIPE_Y, -0.55), 0.10, segs=12)
        tb(m, "Steel", GREY, (-0.25, PIPE_Y, -0.55), (1.0, PIPE_Y, -0.55), 0.09, segs=12)
        nozzle(m, 1.0, -1.0, 0, -1, (1.0, PIPE_Y, -0.55), col=GREY, r=0.075)
        # the coupling under its guard
        tb(m, "Steel", DARK, (-0.05, 0.85, 0), (0.42, 0.85, 0), 0.08, segs=10)
        bx(m, "Steel", SAFETY, 0.02, 0.38, 0.70, 1.02, -0.17, 0.17)
        # the generator: green-grey, its end bells, cooling ribs, terminal box
        m.color = GEN_GREEN
        tube(m, "Steel", (0.45, 0.85, 0), (1.55, 0.85, 0), 0.44, segs=22, uv_m=UVM["Steel"])
        for x in (0.45, 1.55):
            tb(m, "Steel", (0.30, 0.36, 0.32), (x - 0.04, 0.85, 0), (x + 0.04, 0.85, 0), 0.40, segs=20)
        for k in range(6):
            x = 0.6 + k * 0.17
            tb(m, "Steel", GEN_GREEN, (x, 0.85, 0), (x + 0.03, 0.85, 0), 0.47, segs=22)
        for x in (0.55, 1.45):
            bx(m, "Steel", GREY, x - 0.08, x + 0.08, 0.18, 0.45, -0.32, 0.32)
        sh.add((1.0, 0.85, 0), (1.2, 0.95, 0.95))
        bx(m, "Steel", (0.30, 0.36, 0.32), 0.80, 1.20, 1.28, 1.52, -0.18, 0.18)
        tb(m, "Rubber", RUBBER, (1.2, 1.4, 0.1), (1.7, 0.2, 0.55), 0.03, segs=6)
        # the oil line and the lifting lugs over it all
        tb(m, "Steel", (0.62, 0.48, 0.20), (-1.6, 1.30, 0.3), (1.5, 1.30, 0.3), 0.015, segs=6)
        for x in (-1.2, -0.5, 0.7, 1.3):
            bx(m, "Steel", DARK, x - 0.04, x + 0.04, 1.28, 1.66, -0.015, 0.015)
        bx(m, "Steel", LIGHT, 0.85, 1.15, 0.72, 0.86, 0.438, 0.444)
        return m, sh, []

    def p_radiatorPanel(mat):
        m, sh = CModel(seed=681), Shell()
        # the frame: two posts on their feet
        for x in (-1.07, 1.07):
            bx(m, "Steel", GREY, x - 0.04, x + 0.04, 0.0, 4.40, -0.04, 0.04)
            bx(m, "Steel", DARK, x - 0.06, x + 0.06, 0.0, 0.03, -0.30, 0.30)
            rbox(m, "Steel", GREY, (x, 0.35, -0.16), (0.04, 0.04, 0.42), rot_x(math.radians(-55)))
            rbox(m, "Steel", GREY, (x, 0.35, 0.16), (0.04, 0.04, 0.42), rot_x(math.radians(55)))
        bx(m, "Steel", GREY, -1.07, 1.07, 4.36, 4.397, -0.038, 0.038)
        # the panel: high-emissivity black, heat pipes up both faces
        bx(m, "Steel", BLACKPAINT, -0.998, 0.998, 0.70, 4.25, -0.015, 0.015, sh=sh)
        for s in (-1, 1):
            for k in range(20):
                x = -0.95 + k * 0.1
                tb(m, "Steel", (0.10, 0.10, 0.11), (x, 0.703, s * 0.022), (x, 4.247, s * 0.022), 0.011, segs=5)
        # the headers: steam in at the top (its riser from the inlet), condensate out at the bottom
        tb(m, "Steel", STAIN, (-1.0, 4.30, 0), (1.0, 4.30, 0), 0.055, segs=12)
        tb(m, "Steel", STAIN, (-1.0, PIPE_Y, 0), (1.0, PIPE_Y, 0), 0.055, segs=12)
        tb(m, "Steel", STAIN, (-1.18, PIPE_Y, 0), (-1.18, 4.30, 0), PR, segs=12)
        tb(m, "Steel", STAIN, (-1.18, 4.30, 0), (-1.0, 4.30, 0), PR, segs=12)
        nozzle(m, -1.5, 0.0, -1, 0, (-1.18, PIPE_Y, 0))
        nozzle(m, 1.5, 0.0, 1, 0, (1.0, PIPE_Y, 0))
        bx(m, "Steel", SAFETY, -0.25, 0.25, 0.40, 0.55, 0.03, 0.036)
        return m, sh, []

    def p_coolingTower(mat):
        m, sh = CModel(seed=691), Shell()
        col = (0.62, 0.64, 0.63)
        # the casing on its basin, louvres down the four sides
        bx(m, "Concrete", K.CONC_DARK, -1.5, 1.5, 0.0, 0.35, -1.5, 1.5)
        bx(m, "Clad", col, -1.42, 1.42, 0.35, 4.20, -1.42, 1.42, sh=sh)
        sh.add((0, 0.175, 0), (3.0, 0.35, 3.0))
        for k in range(10):
            y = 0.50 + k * 0.12
            for s in (-1, 1):
                bx(m, "Steel", DARK, -1.30, 1.30, y, y + 0.05, s * 1.42, s * 1.46)
                bx(m, "Steel", DARK, s * 1.42, s * 1.46, y, y + 0.05, -1.30, 1.30)
        for x in (-1.45, 1.45):
            for z in (-1.45, 1.45):
                bx(m, "Steel", GREY, x - 0.05, x + 0.05, 0.35, 4.22, z - 0.05, z + 0.05)
        # the fan deck, the shroud, the fan and its guard
        bx(m, "Steel", GREY, -1.503, 1.503, 4.20, 4.30, -1.503, 1.503)
        m.color = col
        lathe(m, "Clad", [(1.25, 4.30), (1.15, 4.70), (1.25, 5.20)], segs=28, uv_m=UVM["Clad"])
        lathe(m, "Clad", [(1.21, 5.20), (1.11, 4.70), (1.19, 4.30)], segs=28, uv_m=UVM["Clad"])
        tb(m, "Steel", DARK, (0, 4.30, 0), (0, 4.75, 0), 0.20, segs=14)
        for k in range(6):
            a = k * math.tau / 6
            rbox(m, "Steel", (0.30, 0.31, 0.32), (0.55 * math.cos(a), 4.72, 0.55 * math.sin(a)), (0.9, 0.02, 0.2),
                 K.rot_y(-a) @ rot_x(0.25))
        for k in range(8):
            a = k * math.tau / 8
            tb(m, "Steel", GREY, (0.04 * math.cos(a), 5.15, 0.04 * math.sin(a)), (1.14 * math.cos(a), 5.15, 1.14 * math.sin(a)), 0.01, segs=4)
        tb(m, "Steel", GREY, (0, 5.13, 0), (0, 5.17, 0), 0.05, segs=10)
        sh.add((0, 4.75, 0), (2.4, 0.9, 2.4))
        # the supply and return to their ports (−Z), a ladder up the side
        for x in (-0.5, 0.5):
            nozzle(m, x, -2.0, 0, -1, (x, PIPE_Y, -1.42))
        for y in [0.4 + 0.3 * k for k in range(13)]:
            bx(m, "Steel", SAFETY, 1.462, 1.488, y, y + 0.025, 0.55, 0.95)
        for z in (0.55, 0.95):
            bx(m, "Steel", SAFETY, 1.46, 1.49, 0.35, 4.33, z - 0.02, z + 0.02)
        bx(m, "Steel", LIGHT, -0.4, 0.4, 2.6, 2.9, -1.47, -1.465)
        return m, sh, []

    def p_reactorConsole(mat):
        m, sh = CModel(seed=701), Shell()
        col = (0.50, 0.53, 0.52)
        # the pedestal, the desk, the kick plate
        bx(m, "Steel", col, -0.78, 0.78, 0.0, 0.74, -0.42, 0.10, sh=sh)
        bx(m, "Steel", DARK, -0.76, 0.76, 0.0, 0.08, 0.10, 0.12)
        bx(m, "Steel", (0.36, 0.38, 0.38), -0.80, 0.80, 0.74, 0.78, -0.45, 0.45)
        sh.add((0, 0.76, 0), (1.6, 0.04, 0.9))
        # the sloped control panel: rod and pump switches, lamps, the SCRAM button
        M = rot_x(math.radians(-28))
        rbox(m, "Steel", (0.30, 0.32, 0.33), (0, 0.86, -0.12), (1.50, 0.04, 0.34), M)
        for i in range(10):
            for j in range(2):
                x = -0.62 + i * 0.12
                zz = -0.20 + j * 0.13
                yy = 0.86 + 0.02 + (-0.12 - zz) * math.tan(math.radians(28)) + 0.0
                if j == 0 and i % 2 == 0:
                    bx(m, "Lamp", (0.35, 1.0, 0.45) if i < 6 else (1.0, 0.7, 0.2), x - 0.02, x + 0.02, yy, yy + 0.015, zz - 0.02, zz + 0.02)
                else:
                    tb(m, "Steel", DARK, (x, yy - 0.005, zz), (x, yy + 0.02, zz), 0.016, segs=8)
        tb(m, "Steel", (0.70, 0.12, 0.08), (0.66, 0.90, -0.04), (0.66, 0.94, -0.04), 0.05, segs=12)
        bx(m, "Steel", SAFETY, 0.59, 0.73, 0.88, 0.89, -0.11, 0.03)
        # the screen's housing at the back, its stand
        bx(m, "Steel", DARK, -0.64, 0.64, 0.82, 1.45, -0.45, -0.35, sh=sh)
        bx(m, "Steel", (0.30, 0.32, 0.33), -0.643, 0.643, 1.42, 1.453, -0.453, -0.33)
        sm = CModel(seed=702)
        sm.ground = False
        sm.color = (1, 1, 1)
        w, y0, y1, z = 0.55, 0.85, 1.40, -0.348
        sm.add("Screen", [(-w, y1, z), (w, y1, z), (w, y0, z), (-w, y0, z)],
               [(0, 0, 1)] * 4, [(0, 0), (1, 0), (1, 1), (0, 1)], [(0, 3, 2), (0, 2, 1)])
        return m, sh, [("Screen", "mesh", (sm, (0, 0, 0)))]

    # ── shielding ──
    def p_shieldHeavy(mat):
        m, sh = CModel(seed=711), Shell()
        bx(m, "Concrete", MAGNETITE, -0.5, 0.5, 0.0, 1.0, -0.5, 0.5, sh=sh)
        rng = np.random.default_rng(712)
        for k in range(14):
            face = k % 4
            u, v = rng.uniform(-0.42, 0.42), rng.uniform(0.08, 0.92)
            s = rng.uniform(0.02, 0.05)
            if face == 0:
                bx(m, "Concrete", RUST, u - s, u + s, v - s * 0.6, v + s * 0.6, 0.5, 0.502)
            elif face == 1:
                bx(m, "Concrete", RUST, u - s, u + s, v - s * 0.6, v + s * 0.6, -0.502, -0.5)
            elif face == 2:
                bx(m, "Concrete", RUST, 0.5, 0.502, v - s * 0.6, v + s * 0.6, u - s, u + s)
            else:
                bx(m, "Concrete", RUST, -0.502, -0.5, v - s * 0.6, v + s * 0.6, u - s, u + s)
        for x in (-0.3, 0.3):
            tb(m, "Steel", DARK, (x - 0.06, 1.0, 0), (x - 0.06, 1.05, 0), 0.012, segs=6)
            tb(m, "Steel", DARK, (x + 0.06, 1.0, 0), (x + 0.06, 1.05, 0), 0.012, segs=6)
            tb(m, "Steel", DARK, (x - 0.06, 1.05, 0), (x + 0.06, 1.05, 0), 0.014, segs=6)
        bx(m, "Concrete", SAFETY, -0.15, 0.15, 0.85, 0.92, 0.5, 0.503)
        return m, sh, []

    def p_waterShield(mat):
        m, sh = CModel(seed=721), Shell()
        bx(m, "Steel", K.SLATE, -0.48, 0.48, 0.03, 1.97, -0.24, 0.24, sh=sh)
        for y in (0.0, 1.95):
            bx(m, "Steel", GREY, -0.5, 0.5, y, y + 0.05, -0.25, 0.25)
        for x in (-0.25, 0.0, 0.25):
            bx(m, "Steel", K.SLATE, x - 0.015, x + 0.015, 0.05, 1.95, -0.25, 0.25)
        tb(m, "Steel", DARK, (0.3, 2.0, 0), (0.3, 2.06, 0), 0.06, segs=10)
        tb(m, "Steel", LIGHT, (-0.3, 2.0, 0.0), (-0.3, 2.03, 0.0), 0.03, segs=8)
        tb(m, "Steel", GREY, (-0.35, 0.12, 0.24), (-0.35, 0.12, 0.30), 0.03, segs=8)
        bx(m, "Steel", DARK, 0.35, 0.40, 0.2, 1.8, 0.24, 0.25)
        bx(m, "Pane", (1, 1, 1), 0.36, 0.39, 0.25, 1.75, 0.25, 0.254)
        return m, sh, []

    out.update({
        "reactorBase": (p_reactorBase, ["steel"]),
        "fuelChannel": (p_fuelChannel, ["steel"]),
        "modGraphite": (p_modGraphite, ["graphite"]),
        "modWater": (water_tank(613, False), ["steel"]),
        "modHeavy": (water_tank(614, True), ["steel"]),
        "controlRod": (p_controlRod, ["steel"]),
        "pipe2": (p_pipe(2.0), ["steel"]),
        "pipe1": (p_pipe(1.0), ["steel"]),
        "pipeElbow": (p_pipeElbow, ["steel"]),
        "pipeTee": (p_pipeTee, ["steel"]),
        "pipeIns2": (p_pipe(2.0, insulated=True), ["steel"]),
        "coolantPump": (p_coolantPump, ["steel"]),
        "pressuriser": (p_pressuriser, ["steel"]),
        "steamGen": (p_steamGen, ["steel"]),
        "turbineSet": (p_turbineSet, ["steel"]),
        "radiatorPanel": (p_radiatorPanel, ["steel"]),
        "coolingTower": (p_coolingTower, ["steel"]),
        "reactorConsole": (p_reactorConsole, ["steel"]),
        "shieldHeavy": (p_shieldHeavy, ["concrete"]),
        "waterShield": (p_waterShield, ["steel"]),
    })
    return out
