#!/usr/bin/env python3
"""The kit's AIR and SURVEY pieces (expansion X1/X2; scripts/parts_kit.lua LIFE, SCIENCE).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for
its PIECES table, built with its own primitives):

    python3 tools/gen_kit_parts.py n2comp o2conc telescope telescope1m surveyStation

1:1, in each piece's ground frame (+Y up, +Z its front), real proportions:
* N2 Compressor: a skid with a scroll compressor's cabinet, an intake filter with its grille and
  rain hood, two hollow-fibre membrane modules (the grey 150 mm tubes industrial nitrogen
  generators use), a receiver bottle, the product line and its gauge.
* O2 Concentrator: a pressure-swing adsorption unit: a cabinet, two zeolite sieve beds in view
  behind a mesh door, a small product tank, a control panel and a status lamp.
* Telescope 0.3 m: a steel pier on a base plate, a wedge and a German equatorial mount, a white
  0.3 m Ritchey-Chretien tube (0.95 m long, 0.36 m across) pointed up 40 degrees, its dew shield,
  focuser and camera, the counterweight shaft and two weights, a hand controller.
* Telescope 1 m: a concrete pier ring, a fork mount (two arms on a turntable), an open Serrurier
  truss tube: the primary's cell (a heavy box), eight struts to the top ring and the secondary's
  spider, a spectrograph box on the fork, cable wrap.
* Survey Station: a tripod frame, a sealed electronics box, a tilted solar panel, a 2.5 m mast
  with a louvred temperature screen, a cup anemometer and a vane, a magnetometer on a 0.8 m boom
  (no iron near it), and the seismometer's buried dome with its cable.
"""
import math

import numpy as np

STEEL_PAINT = (0.62, 0.64, 0.63)
WHITE = (0.86, 0.86, 0.83)
BLACK = (0.08, 0.08, 0.09)
MEMBRANE = (0.48, 0.50, 0.52)
SIEVE = (0.30, 0.42, 0.50)
CONCRETE = (0.58, 0.57, 0.54)
PANEL_BLUE = (0.10, 0.14, 0.22)
ALU = (0.78, 0.79, 0.80)

MATERIALS = {}


def pieces(K):
    CModel, Shell, bx, tb = K.CModel, K.Shell, K.bx, K.tb
    DARK, GREY, LIGHT, SAFETY, RUBBER, PAINT = K.DARK, K.GREY, K.LIGHT, K.SAFETY, K.RUBBER, K.PAINT
    TAU = 2 * math.pi
    out = {}

    def grille(m, x0, x1, y0, y1, z, n, col=DARK):
        step = (y1 - y0) / n
        for k in range(n):
            y = y0 + k * step
            bx(m, "Steel", col, x0, x1, y, y + step * 0.45, z, z + 0.012)

    def lamp(m, x, y, z, col=(0.35, 1.0, 0.45)):
        bx(m, "Lamp", col, x - 0.03, x + 0.03, y - 0.015, y + 0.015, z, z + 0.008)

    # ── N2 Compressor ──
    def p_n2comp(mat):
        m, sh = CModel(seed=901), Shell()
        bx(m, "Steel", DARK, -0.5, 0.5, 0.0, 0.08, -0.35, 0.35, sh=sh)                  # the skid
        bx(m, "Steel", STEEL_PAINT, -0.48, 0.02, 0.08, 0.95, -0.33, 0.33, sh=sh)       # the compressor's cabinet
        grille(m, -0.44, -0.02, 0.18, 0.80, 0.33, 10)
        bx(m, "Steel", GREY, -0.40, -0.10, 0.95, 1.08, -0.20, 0.20)                    # the intake filter
        bx(m, "Steel", DARK, -0.43, -0.07, 1.08, 1.11, -0.23, 0.23)                    # its rain hood
        for z in (-0.17, 0.17):
            bx(m, "Steel", DARK, -0.39, -0.11, 0.97, 1.06, z - 0.004, z + 0.004)
        # the two membrane modules, upright on the right half
        for z in (-0.16, 0.12):
            tb(m, "Steel", MEMBRANE, (0.24, 0.10, z), (0.24, 1.22, z), 0.075, segs=16)
            for y in (0.12, 1.20):
                tb(m, "Steel", GREY, (0.24, y - 0.02, z), (0.24, y + 0.02, z), 0.085, segs=16)
            tb(m, "Steel", LIGHT, (0.24, 1.22, z), (0.24, 1.28, z), 0.018, segs=8)
        tb(m, "Steel", LIGHT, (0.24, 1.28, -0.16), (0.24, 1.28, 0.12), 0.016, segs=8)    # the product header
        tb(m, "Steel", LIGHT, (0.24, 1.28, 0.12), (0.46, 1.28, 0.12), 0.016, segs=8)
        tb(m, "Steel", LIGHT, (0.46, 1.28, 0.12), (0.46, 0.60, 0.12), 0.016, segs=8)     # down to the room line
        sh.add((0.24, 0.66, -0.02), (0.18, 1.12, 0.46))
        # the receiver bottle, black (nitrogen), on its cradle at the back
        tb(m, "Steel", (0.10, 0.10, 0.11), (0.06, 0.20, -0.28), (0.42, 0.20, -0.28), 0.06, segs=14)
        tb(m, "Steel", GREY, (0.06, 0.20, -0.28), (0.10, 0.20, -0.28), 0.062, segs=14)
        # the gauge and the lamp on the cabinet's face
        tb(m, "Steel", PAINT, (-0.10, 0.88, 0.33), (-0.10, 0.88, 0.35), 0.035, segs=14)
        lamp(m, -0.30, 0.88, 0.33)
        bx(m, "Steel", SAFETY, -0.44, -0.20, 0.82, 0.845, 0.33, 0.336)
        return m, sh, []

    # ── O2 Concentrator ──
    def p_o2conc(mat):
        m, sh = CModel(seed=902), Shell()
        bx(m, "Clad", WHITE, -0.38, 0.38, 0.0, 1.42, -0.28, 0.28, sh=sh)
        bx(m, "Steel", DARK, -0.36, 0.36, 0.0, 0.06, -0.26, 0.26)
        # the two sieve beds behind a mesh door (front, left)
        bx(m, "Steel", DARK, -0.34, 0.06, 0.14, 1.12, 0.28, 0.29)
        for x in (-0.24, -0.04):
            tb(m, "Steel", SIEVE, (x, 0.18, 0.24), (x, 1.08, 0.24), 0.08, segs=16)
            for y in (0.18, 1.08):
                tb(m, "Steel", GREY, (x, y - 0.025, 0.24), (x, y + 0.025, 0.24), 0.088, segs=16)
        for k in range(12):                                                           # the mesh door's wires
            y = 0.16 + k * 0.08
            bx(m, "Steel", GREY, -0.34, 0.06, y, y + 0.006, 0.292, 0.298)
        # the product tank (white with the O2 shoulder), the panel, the lamp
        tb(m, "Steel", (0.80, 0.80, 0.78), (0.22, 0.10, 0.20), (0.22, 0.62, 0.20), 0.07, segs=14)
        bx(m, "Steel", (0.06, 0.07, 0.08), 0.12, 0.34, 0.86, 1.18, 0.28, 0.29)
        bx(m, "Screen", (1, 1, 1), 0.15, 0.31, 1.02, 1.14, 0.291, 0.296)
        lamp(m, 0.18, 0.92, 0.29)
        lamp(m, 0.28, 0.92, 0.29, col=(1.0, 0.75, 0.3))
        grille(m, -0.30, 0.30, 1.22, 1.38, 0.28, 4)
        tb(m, "Steel", LIGHT, (0.30, 1.42, -0.10), (0.30, 1.50, -0.10), 0.016, segs=8)   # the O2 line out the top
        return m, sh, []

    # ── Telescope 0.3 m ──
    def p_telescope(mat):
        m, sh = CModel(seed=903), Shell()
        bx(m, "Steel", DARK, -0.36, 0.36, 0.0, 0.03, -0.36, 0.36, sh=sh)                # the base plate
        tb(m, "Steel", STEEL_PAINT, (0, 0.03, 0), (0, 1.05, 0), 0.10, segs=16)          # the pier
        sh.add((0, 0.54, 0), (0.2, 1.02, 0.2))
        for k in range(4):                                                            # its gussets
            a = TAU * k / 4 + TAU / 8
            tb(m, "Steel", STEEL_PAINT, (0.1 * math.cos(a), 0.30, 0.1 * math.sin(a)),
               (0.28 * math.cos(a), 0.035, 0.28 * math.sin(a)), 0.012, segs=6)
        bx(m, "Steel", GREY, -0.14, 0.14, 1.05, 1.09, -0.14, 0.14)                      # the pier head
        # the wedge and the mount head, tilted to the pole (+Z), 40 degrees
        lat = math.radians(40)
        ax = np.array([0.0, math.sin(lat), math.cos(lat)])                              # the polar axis
        c0 = np.array([0.0, 1.20, 0.0])
        tb(m, "Steel", DARK, tuple(c0 - ax * 0.10), tuple(c0 + ax * 0.16), 0.075, segs=16)
        bx(m, "Steel", DARK, -0.08, 0.08, 1.09, 1.18, -0.10, 0.10)
        # the declination axis across it (+X), the counterweight shaft one way, the saddle the other
        d0 = c0 + ax * 0.16
        tb(m, "Steel", DARK, tuple(d0 - np.array([0.12, 0, 0])), tuple(d0 + np.array([0.12, 0, 0])), 0.06, segs=14)
        tb(m, "Steel", ALU, tuple(d0 - np.array([0.12, 0, 0])), tuple(d0 - np.array([0.42, 0, 0])), 0.014, segs=8)
        for x in (0.30, 0.38):
            tb(m, "Steel", GREY, tuple(d0 - np.array([x - 0.03, 0, 0])), tuple(d0 - np.array([x + 0.03, 0, 0])), 0.06, segs=14)
        # the tube: along a direction up 40 degrees toward +Z, centred on the saddle
        u = np.array([0.0, math.sin(math.radians(40)), math.cos(math.radians(40))])
        tc = d0 + np.array([0.20, 0, 0])
        a0, a1 = tc - u * 0.42, tc + u * 0.53
        tb(m, "Steel", WHITE, tuple(a0), tuple(a1), 0.18, segs=24)
        tb(m, "Steel", BLACK, tuple(a1), tuple(a1 + u * 0.12), 0.185, segs=24)            # the dew shield
        tb(m, "Steel", BLACK, tuple(a0 - u * 0.04), tuple(a0), 0.17, segs=24)             # the primary's cell
        tb(m, "Steel", GREY, tuple(a0 - u * 0.04), tuple(a0 - u * 0.12), 0.035, segs=10)  # the focuser
        bx(m, "Steel", DARK, *(lambda p: (p[0] - 0.05, p[0] + 0.05, p[1] - 0.05, p[1] + 0.05, p[2] - 0.05, p[2] + 0.05))(a0 - u * 0.17))
        for f in (-0.18, 0.28):                                                       # the tube rings on the saddle
            p = tc + u * f
            tb(m, "Steel", DARK, tuple(p - u * 0.02), tuple(p + u * 0.02), 0.19, segs=24)
        sh.add(tuple(tc + u * 0.05), (0.38, 0.38, 0.38))
        # the hand controller on its hook
        bx(m, "Steel", DARK, 0.10, 0.16, 0.86, 0.98, 0.10, 0.13)
        lamp(m, 0.13, 0.95, 0.13, col=(1.0, 0.25, 0.2))
        return m, sh, []

    # ── Telescope 1 m ──
    def p_telescope1m(mat):
        m, sh = CModel(seed=904), Shell()
        # the pier ring and the turntable
        m.color = CONCRETE
        K.lathe(m, "Concrete", [(0.0, 0.0), (1.1, 0.0), (1.1, 0.9), (0.0, 0.9)], segs=32, uv_m=0.5)
        sh.add((0, 0.45, 0), (2.0, 0.9, 2.0))
        m.color = DARK
        K.lathe(m, "Steel", [(0.0, 0.9), (0.95, 0.9), (0.95, 1.05), (0.0, 1.05)], segs=32, uv_m=1.0)
        # the fork: two arms
        for s in (-1, 1):
            bx(m, "Steel", STEEL_PAINT, s * 0.95 - 0.12, s * 0.95 + 0.12, 1.05, 2.55, -0.30, 0.30, sh=sh)
            tb(m, "Steel", DARK, (s * 0.95, 2.35, 0), (s * 0.82, 2.35, 0), 0.16, segs=16)    # the altitude bearings
        # the tube, pointed up 65 degrees toward +Z, on the altitude axis (x across)
        ang = math.radians(65)
        u = np.array([0.0, math.sin(ang), math.cos(ang)])
        side = np.array([1.0, 0, 0])
        w = np.cross(u, side)
        c = np.array([0.0, 2.35, 0.0])
        cell = c - u * 0.55
        # the primary's cell: a heavy octagonal box, the mirror's back
        for k in range(8):
            a = TAU * k / 8
            p = cell + (side * math.cos(a) + w * math.sin(a)) * 0.62
            q = cell + (side * math.cos(a + TAU / 8) + w * math.sin(a + TAU / 8)) * 0.62
            tb(m, "Steel", DARK, tuple(p - u * 0.25), tuple(p + u * 0.25), 0.05, segs=8)
            tb(m, "Steel", DARK, tuple(p + u * 0.25), tuple(q + u * 0.25), 0.04, segs=8)
            tb(m, "Steel", DARK, tuple(p - u * 0.25), tuple(q - u * 0.25), 0.04, segs=8)
        tb(m, "Steel", BLACK, tuple(cell - u * 0.20), tuple(cell + u * 0.20), 0.58, segs=24)
        tb(m, "Steel", (0.85, 0.86, 0.88), tuple(cell + u * 0.20), tuple(cell + u * 0.22), 0.52, segs=24)   # the mirror's face
        # the top ring and the eight Serrurier struts
        top = c + u * 1.55
        ringp = []
        for k in range(16):
            a = TAU * k / 16
            ringp.append(top + (side * math.cos(a) + w * math.sin(a)) * 0.6)
        for k in range(16):
            tb(m, "Steel", STEEL_PAINT, tuple(ringp[k]), tuple(ringp[(k + 1) % 16]), 0.035, segs=6)
        for k in range(8):
            a = TAU * k / 8
            b0 = cell + u * 0.22 + (side * math.cos(a) + w * math.sin(a)) * 0.62
            a2 = a + TAU / 16 * (1 if k % 2 == 0 else -1)
            b1 = top + (side * math.cos(a2) + w * math.sin(a2)) * 0.6
            tb(m, "Steel", WHITE, tuple(b0), tuple(b1), 0.025, segs=6)
        # the centre section on the bearings, the secondary's spider and hub
        tb(m, "Steel", STEEL_PAINT, tuple(c - u * 0.12), tuple(c + u * 0.12), 0.66, segs=24)
        tb(m, "Steel", DARK, tuple(c - side * 0.82), tuple(c + side * 0.82), 0.08, segs=12)
        for k in range(4):
            a = TAU * k / 4
            tb(m, "Steel", DARK, tuple(top), tuple(top + (side * math.cos(a) + w * math.sin(a)) * 0.58), 0.008, segs=5)
        tb(m, "Steel", BLACK, tuple(top - u * 0.08), tuple(top + u * 0.10), 0.14, segs=16)
        sh.add(tuple(c + u * 0.5), (1.3, 1.3, 1.3))
        # the spectrograph on the right arm, its fibre run, the cable wrap
        bx(m, "Steel", (0.20, 0.22, 0.25), 1.08, 1.30, 1.30, 1.80, -0.28, 0.28)
        lamp(m, 1.19, 1.74, 0.28)
        tb(m, "Steel", (0.95, 0.65, 0.15), (1.19, 1.80, 0.0), (0.95, 2.20, 0.0), 0.012, segs=6)
        tb(m, "Steel", DARK, (-0.80, 1.05, 0.0), (-0.80, 1.40, 0.0), 0.05, segs=10)
        return m, sh, []

    # ── Survey Station ──
    def p_surveyStation(mat):
        m, sh = CModel(seed=905), Shell()
        # the tripod frame round the mast
        for k in range(3):
            a = TAU * k / 3 + TAU / 12
            tb(m, "Steel", ALU, (0.0, 1.0, 0.0), (0.62 * math.cos(a), 0.0, 0.62 * math.sin(a)), 0.02, segs=8)
            bx(m, "Steel", DARK, 0.62 * math.cos(a) - 0.05, 0.62 * math.cos(a) + 0.05, 0.0, 0.02,
               0.62 * math.sin(a) - 0.05, 0.62 * math.sin(a) + 0.05)
        tb(m, "Steel", ALU, (0.0, 0.0, 0.0), (0.0, 2.55, 0.0), 0.025, segs=10)            # the mast
        sh.add((0, 1.3, 0), (0.08, 2.6, 0.08))
        # the electronics box on the mast
        bx(m, "Steel", WHITE, -0.16, 0.16, 0.55, 0.85, 0.03, 0.25, sh=sh)
        lamp(m, 0.10, 0.80, 0.25)
        bx(m, "Steel", DARK, -0.12, 0.12, 0.60, 0.62, 0.25, 0.255)
        # the solar panel, tilted toward -Z
        M = K.rot_x(math.radians(-50))
        K.rbox(m, "Steel", PANEL_BLUE, (0.0, 1.30, -0.20), (0.62, 0.02, 0.46), M)
        K.rbox(m, "Steel", ALU, (0.0, 1.29, -0.205), (0.65, 0.012, 0.49), M)
        tb(m, "Steel", ALU, (0.0, 1.15, -0.02), (0.0, 1.22, -0.12), 0.012, segs=6)
        # the temperature screen: louvred white box
        for k in range(7):
            y = 1.70 + k * 0.03
            bx(m, "Steel", WHITE, 0.03, 0.23, y, y + 0.018, -0.10, 0.10)
        bx(m, "Steel", WHITE, 0.02, 0.24, 1.91, 1.93, -0.11, 0.11)
        tb(m, "Steel", ALU, (0.0, 1.80, 0.0), (0.03, 1.80, 0.0), 0.01, segs=6)
        # the anemometer: three cups on arms at the top, and the vane
        hub = (0.0, 2.58, 0.0)
        for k in range(3):
            a = TAU * k / 3
            e = (0.13 * math.cos(a), 2.58, 0.13 * math.sin(a))
            tb(m, "Steel", ALU, hub, e, 0.005, segs=5)
            tb(m, "Steel", BLACK, (e[0], e[1] - 0.03, e[2]), (e[0], e[1] + 0.03, e[2]), 0.03, segs=10)
        tb(m, "Steel", ALU, (0.0, 2.30, 0.0), (0.0, 2.30, 0.30), 0.006, segs=5)
        bx(m, "Steel", BLACK, -0.004, 0.004, 2.25, 2.37, 0.24, 0.34)
        # the magnetometer on its boom (fibreglass: no iron near the sensor)
        tb(m, "Steel", (0.85, 0.80, 0.60), (0.0, 2.05, 0.0), (-0.82, 2.05, 0.0), 0.012, segs=6)
        tb(m, "Steel", WHITE, (-0.86, 2.05, 0.0), (-0.70, 2.05, 0.0), 0.03, segs=10)
        # the seismometer: a buried dome out to the side, and its cable
        mm = CModel(seed=906)
        mm.ground = m.ground
        mm.color = (0.55, 0.55, 0.55)
        K.lathe(mm, "Steel", [(0.0, 0.10), (0.10, 0.09), (0.14, 0.04), (0.15, 0.0)], segs=18, uv_m=2.0)
        m.merge(mm, t=(0.45, 0.0, 0.40))
        tb(m, "Rubber", RUBBER, (0.36, 0.01, 0.34), (0.05, 0.01, 0.10), 0.008, segs=5)
        tb(m, "Rubber", RUBBER, (0.05, 0.01, 0.10), (0.05, 0.56, 0.12), 0.008, segs=5)
        return m, sh, []

    out.update({
        "n2comp": (p_n2comp, ["steel"]),
        "o2conc": (p_o2conc, ["steel"]),
        "telescope": (p_telescope, ["steel"]),
        "telescope1m": (p_telescope1m, ["steel"]),
        "surveyStation": (p_surveyStation, ["steel"]),
    })
    return out
