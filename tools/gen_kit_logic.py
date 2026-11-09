#!/usr/bin/env python3
"""The kit's LOGIC pieces (sandbox plan S8; scripts/parts_kit.lua LOGIC).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for its
PIECES table, built with its own primitives):

    python3 tools/gen_kit_parts.py lgAnd lgPlc     # just these (the fixture is not rewritten)

Wall-hung control gear is modelled lying on a floor, its face +Y out (a mount): on a wall its +Z
points down, so every box's cable glands are on its +Z end, where parts_kit puts its pins (inputs
left, outputs right). Real sizes: DIN enclosures 18 × 22 × 10 cm in RAL 7035 light grey with a
function stripe, pilot lamps 22 mm, a mushroom button in a yellow box, a PIR dome, a PLC on its
desk with a CRT and a terminal rail at its back. Lamp lenses and the beacon's dome are their own
"Lens" child (logic_net tints them), the PLC's screen its "Screen" quad (logic_net paints it).
"""
import math

MATERIALS = {}

RAL7035 = (0.78, 0.79, 0.77)     # light grey enclosure
RAL7016 = (0.20, 0.22, 0.24)     # anthracite
YELLOW = (0.86, 0.66, 0.10)
RED = (0.70, 0.10, 0.08)
WHITE = (0.88, 0.88, 0.86)
TERM_GREY = (0.62, 0.63, 0.62)
TERM_BLUE = (0.18, 0.34, 0.62)
CABLE = (0.10, 0.18, 0.30)
STRIPE = {
    "and": (0.18, 0.36, 0.70), "or": (0.20, 0.55, 0.26), "xor": (0.12, 0.52, 0.52), "not": (0.72, 0.16, 0.12),
    "timer": (0.86, 0.66, 0.10), "latch": (0.90, 0.45, 0.10), "cmp": (0.45, 0.28, 0.62), "counter": (0.90, 0.90, 0.88),
}

NO_PAINT = set()


def pieces(K):
    CModel, Shell, bx, tb = K.CModel, K.Shell, K.bx, K.tb
    lathe, disk = K.lathe, K.disk
    DARK, GREY, LIGHT, SAFETY, RUBBER = K.DARK, K.GREY, K.LIGHT, K.SAFETY, K.RUBBER
    UVM = K.UVM
    out = {}

    def mount():
        m = CModel(seed=900)
        m.ground = False
        return m, Shell()

    def glands(m, b, n, d):
        """n cable glands on the box's +Z end, where the pins are (parts_kit `glands`)."""
        w = b[1] - b[0]
        for k in range(n):
            x = b[0] + w * (k + 0.5) / n
            tb(m, "Rubber", RUBBER, (x, d * 0.5, b[5] - 0.014), (x, d * 0.5, b[5]), 0.006, segs=8)
            tb(m, "Steel", DARK, (x, d * 0.5, b[5] - 0.018), (x, d * 0.5, b[5] - 0.012), 0.009, segs=6)

    def enclosure(m, b, col, d, stripe=None, led=None):
        """a wall box: its back plate, the body (short of the glands' end), a stripe and an LED"""
        x0, x1, z0, z1 = b[0], b[1], b[4], b[5]
        bx(m, "Steel", DARK, x0, x1, 0.0, 0.006, z0, z1)
        bx(m, "Steel", col, x0 + 0.004, x1 - 0.004, 0.006, d, z0 + 0.004, z1 - 0.018)
        # the lid's seam and its four screws
        bx(m, "Steel", (col[0] * 0.8, col[1] * 0.8, col[2] * 0.8), x0 + 0.006, x1 - 0.006, d - 0.004, d + 0.001, z0 + 0.006, z0 + 0.010)
        for sx in (x0 + 0.014, x1 - 0.014):
            for sz in (z0 + 0.016, z1 - 0.03):
                tb(m, "Steel", GREY, (sx, d, sz), (sx, d + 0.003, sz), 0.004, segs=6)
        if stripe:
            bx(m, "Steel", stripe, x0 + 0.02, x1 - 0.02, d, d + 0.002, z0 + 0.03, z0 + 0.06)
        if led:
            tb(m, "Lamp", led, (x1 - 0.03, d, z1 - 0.05), (x1 - 0.03, d + 0.004, z1 - 0.05), 0.005, segs=8)

    # ── the drum ──
    def p_sigCable(mat):
        m, sh = CModel(seed=901), Shell()
        cy = 0.21
        for s in (-1, 1):
            tb(m, "Steel", (0.42, 0.30, 0.18), (s * 0.23, cy, 0), (s * 0.25, cy, 0), 0.21, segs=24)
        tb(m, "Rubber", CABLE, (-0.21, cy, 0), (0.21, cy, 0), 0.165, segs=24)
        tb(m, "Steel", GREY, (-0.26, cy, 0), (0.26, cy, 0), 0.02, segs=10)
        # a loose end hanging off the drum
        tb(m, "Rubber", CABLE, (0.12, cy - 0.16, 0.06), (0.16, 0.02, 0.2), 0.0045, segs=6)
        return m, sh, []

    # ── gates ──
    def gate(kind, nin, nout):
        def fn(mat):
            m, sh = mount()
            b = (-0.09, 0.09, 0.0, 0.1, -0.11, 0.11)
            enclosure(m, b, RAL7035, 0.095, stripe=STRIPE[kind], led=(0.35, 1.0, 0.45))
            # (inside: a DIN rail and the relay board's bulk show as the lid's bulge)
            bx(m, "Steel", RAL7035, -0.07, 0.07, 0.095, 0.1, -0.06, 0.04)
            if kind == "timer":
                tb(m, "Steel", RAL7016, (0.0, 0.1, -0.01), (0.0, 0.11, -0.01), 0.018, segs=12)
                bx(m, "Steel", WHITE, -0.002, 0.002, 0.11, 0.112, -0.026, -0.01)
            if kind == "counter":
                bx(m, "Pane", (1, 1, 1), -0.05, 0.05, 0.1, 0.102, -0.02, 0.01)
            glands(m, b, nin + nout, 0.1)
            return m, sh, []
        return fn

    # ── sensors ──
    def s_box(seed, b, col, d, extra=None, nglands=1):
        def fn(mat):
            m, sh = mount()
            enclosure(m, b, col, d, led=(0.35, 1.0, 0.45))
            if extra:
                extra(m, b, d)
            glands(m, b, nglands, d)
            return m, sh, []
        return fn

    def press_head(m, b, d):
        tb(m, "Steel", (0.62, 0.62, 0.60), (0, 0.05, -0.015), (0, b[3], -0.015), 0.05, segs=18)
        m.color = (1.0, 1.0, 1.0)
        disk(m, "Pane", 0.045, b[3] + 0.001, segs=18, up=True, cz=-0.015)
        bx(m, "Steel", DARK, -0.002, 0.002, b[3], b[3] + 0.003, -0.05, -0.015)

    def grille(m, b, d):
        for k in range(6):
            z = b[4] + 0.03 + k * 0.022
            bx(m, "Steel", DARK, -0.06, 0.06, d, d + 0.003, z, z + 0.01)

    def temp_head(m, b, d):
        tb(m, "Steel", (0.70, 0.71, 0.70), (0, 0.02, 0.0), (0, 0.1, 0.0), 0.045, segs=16)
        tb(m, "Steel", (0.70, 0.71, 0.70), (0, 0.1, 0.0), (0, b[3], 0.0), 0.006, segs=8)

    def flow_head(m, b, d):
        tb(m, "Steel", (0.30, 0.42, 0.62), (-0.06, 0.05, 0.0), (0.06, 0.05, 0.0), 0.03, segs=14)
        tb(m, "Steel", GREY, (0, 0.05, 0.0), (0, b[3], 0.0), 0.012, segs=8)

    def level_head(m, b, d):
        tb(m, "Steel", (0.70, 0.71, 0.70), (0.0, d, -0.03), (0.0, d, 0.02), 0.02, segs=10)

    def meter(m, b, d):
        bx(m, "Pane", (1, 1, 1), -0.045, 0.045, d, d + 0.002, b[4] + 0.02, b[4] + 0.07)
        bx(m, "Steel", (0.95, 0.92, 0.8), -0.04, 0.04, d - 0.002, d, b[4] + 0.025, b[4] + 0.065)

    def dose_face(m, b, d):
        m.color = RAL7016
        disk(m, "Steel", 0.04, d + 0.001, segs=20, up=True, cz=-0.02)
        tb(m, "Steel", RAL7016, (0, d, -0.02), (0, d + 0.002, -0.02), 0.04, segs=20)
        for k in range(3):
            a = math.radians(90 + k * 120)
            bx(m, "Steel", YELLOW, 0.012 * math.cos(a) - 0.008, 0.012 * math.cos(a) + 0.008, d + 0.002, d + 0.004,
               -0.02 + 0.022 * math.sin(a) - 0.008, -0.02 + 0.022 * math.sin(a) + 0.008)

    def p_prox(mat):
        m, sh = mount()
        m.color = WHITE
        disk(m, "Steel", 0.06, 0.004, segs=24, up=True)
        m.color = WHITE
        lathe(m, "Steel", [(0.06, 0.0), (0.06, 0.012), (0.045, 0.03), (0.02, 0.045), (0.0, 0.05)], segs=24, uv_m=UVM["Steel"])
        tb(m, "Lamp", (1.0, 0.25, 0.2), (0.035, 0.02, 0.035), (0.035, 0.024, 0.035), 0.003, segs=6)
        glands(m, (-0.06, 0.06, 0, 0.05, -0.06, 0.06), 1, 0.025)
        return m, sh, []

    def p_day(mat):
        m, sh = mount()
        bx(m, "Steel", WHITE, -0.045, 0.045, 0.0, 0.035, -0.065, 0.05)
        m.color = (0.92, 0.92, 0.9)
        lathe(m, "Pane", [(0.03, 0.035), (0.026, 0.055), (0.012, 0.067), (0.0, 0.07)], segs=18, uv_m=1.0)
        glands(m, (-0.05, 0.05, 0, 0.07, -0.07, 0.07), 1, 0.035)
        return m, sh, []

    def p_door(mat):
        m, sh = mount()
        bx(m, "Steel", WHITE, -0.045, 0.045, 0.0, 0.035, -0.08, -0.01)
        bx(m, "Steel", WHITE, -0.045, 0.045, 0.0, 0.035, 0.005, 0.06)
        glands(m, (-0.05, 0.05, 0, 0.04, -0.08, 0.08), 1, 0.02)
        return m, sh, []

    # ── inputs ──
    def p_button(mat):
        m, sh = mount()
        b = (-0.06, 0.06, 0, 0.1, -0.08, 0.08)
        enclosure(m, b, YELLOW, 0.06)
        tb(m, "Steel", DARK, (0, 0.06, -0.01), (0, 0.07, -0.01), 0.026, segs=16)
        tb(m, "Steel", RED, (0, 0.07, -0.01), (0, 0.085, -0.01), 0.018, segs=16)
        m.color = RED
        lathe(m, "Steel", [(0.035, 0.085), (0.035, 0.092), (0.03, 0.098), (0.0, 0.1)], segs=20, uv_m=UVM["Steel"])
        glands(m, b, 1, 0.05)
        return m, sh, []

    def p_lever(mat):
        m, sh = mount()
        b = (-0.06, 0.06, 0, 0.14, -0.09, 0.09)
        enclosure(m, b, RAL7016, 0.06, stripe=YELLOW)
        tb(m, "Steel", GREY, (-0.03, 0.06, -0.02), (0.03, 0.06, -0.02), 0.012, segs=10)
        tb(m, "Steel", GREY, (0, 0.06, -0.02), (0, 0.13, -0.07), 0.008, segs=8)
        tb(m, "Rubber", RED, (0, 0.125, -0.066), (0, 0.14, -0.078), 0.014, segs=10)
        glands(m, b, 1, 0.05)
        return m, sh, []

    def p_keypad(mat):
        m, sh = mount()
        b = (-0.07, 0.07, 0, 0.04, -0.1, 0.1)
        enclosure(m, b, (0.52, 0.53, 0.54), 0.03)
        bx(m, "Pane", (1, 1, 1), -0.05, 0.05, 0.03, 0.032, -0.085, -0.055)
        for r in range(4):
            for c in range(3):
                x = -0.035 + c * 0.035
                z = -0.04 + r * 0.03
                bx(m, "Steel", DARK, x - 0.012, x + 0.012, 0.03, 0.038, z - 0.01, z + 0.01)
        glands(m, b, 1, 0.025)
        return m, sh, []

    # ── outputs ──
    def p_lamp(mat):
        m, sh = mount()
        tb(m, "Steel", RAL7016, (0, 0.0, 0), (0, 0.03, 0), 0.045, segs=6)
        tb(m, "Steel", GREY, (0, 0.03, 0), (0, 0.045, 0), 0.016, segs=16)
        glands(m, (-0.05, 0.05, 0, 0.08, -0.05, 0.05), 1, 0.015)
        lm = CModel(seed=905)
        lm.ground = False
        lm.color = (1.0, 1.0, 1.0)
        lathe(lm, "Lamp", [(0.014, 0.0), (0.014, 0.018), (0.01, 0.03), (0.0, 0.035)], segs=16, uv_m=2.5)
        return m, sh, [("Lens", "mesh", (lm, (0.0, 0.045, 0.0)))]

    def p_alarm(mat):
        m, sh = mount()
        tb(m, "Steel", RAL7016, (0, 0.0, 0), (0, 0.06, 0), 0.085, segs=20)
        # the klaxon's horn under the beacon (toward +Z: down on a wall)
        tb(m, "Steel", RAL7016, (0, 0.03, 0.05), (0, 0.03, 0.095), 0.018, segs=12)
        m.color = RAL7016
        K.tube(m, "Steel", (0, 0.03, 0.06), (0, 0.03, 0.098), 0.02, segs=12, uv_m=1.0, r1=0.034)
        glands(m, (-0.1, 0.1, 0, 0.22, -0.1, 0.1), 1, 0.03)
        lm = CModel(seed=906)
        lm.ground = False
        lm.color = (1.0, 1.0, 1.0)
        lathe(lm, "Lamp", [(0.07, 0.0), (0.07, 0.11), (0.06, 0.14), (0.03, 0.158), (0.0, 0.16)], segs=24, uv_m=2.5)
        return m, sh, [("Lens", "mesh", (lm, (0.0, 0.06, 0.0)))]

    def p_radio(tx):
        def fn(mat):
            m, sh = mount()
            b = (-0.07, 0.07, 0, 0.08, -0.09, 0.09)
            enclosure(m, b, RAL7035, 0.07, stripe=(0.86, 0.30, 0.10) if tx else (0.20, 0.45, 0.75), led=(1.0, 0.25, 0.2) if tx else (0.35, 1.0, 0.45))
            # the whip up the wall (toward −Z) off a bulkhead connector
            tb(m, "Steel", GREY, (0.04, 0.04, -0.09), (0.04, 0.04, -0.11), 0.008, segs=8)
            tb(m, "Rubber", RUBBER, (0.04, 0.04, -0.11), (0.04, 0.04, -0.36), 0.0055, segs=8)
            glands(m, b, 1, 0.07)
            return m, sh, []
        return fn

    # ── the ladder controller ──
    def p_plc(mat):
        m, sh = CModel(seed=910), Shell()
        col = (0.52, 0.55, 0.54)
        bx(m, "Steel", col, -0.58, 0.58, 0.0, 0.74, -0.38, 0.28, sh=sh)
        bx(m, "Steel", DARK, -0.56, 0.56, 0.0, 0.08, 0.28, 0.30)
        bx(m, "Steel", (0.36, 0.38, 0.38), -0.60, 0.60, 0.74, 0.78, -0.40, 0.40)
        sh.add((0, 0.76, 0), (1.2, 0.04, 0.8))
        # a sloped keyboard: a row of keys, a key switch, a red STOP
        M = K.rot_x(math.radians(-18))
        K.rbox(m, "Steel", (0.30, 0.32, 0.33), (0, 0.81, 0.18), (1.0, 0.03, 0.26), M)
        for i in range(12):
            for j in range(3):
                x = -0.42 + i * 0.06
                z = 0.10 + j * 0.06
                y = 0.83 + (0.18 - z) * math.tan(math.radians(18))
                bx(m, "Steel", DARK if (i + j) % 5 else (0.60, 0.50, 0.30), x - 0.022, x + 0.022, y, y + 0.012, z - 0.02, z + 0.02)
        tb(m, "Steel", RED, (0.48, 0.84, 0.16), (0.48, 0.87, 0.16), 0.03, segs=14)
        bx(m, "Steel", SAFETY, 0.43, 0.53, 0.84, 0.845, 0.20, 0.24)
        # the CRT's housing at the back, its stand
        bx(m, "Steel", DARK, -0.56, 0.56, 0.80, 1.45, -0.40, -0.30, sh=sh)
        bx(m, "Steel", (0.30, 0.32, 0.33), -0.56, 0.56, 1.42, 1.45, -0.40, -0.28)
        bx(m, "Steel", (0.30, 0.32, 0.33), -0.56, 0.56, 0.80, 0.84, -0.40, -0.28)
        # the terminal rail at its back: X1-X8 grey, Y1-Y8 blue (parts_kit's pins)
        bx(m, "Steel", GREY, -0.56, 0.56, 0.53, 0.57, -0.395, -0.38)
        for k in range(16):
            x = (-0.52 + k * 0.06) if k < 8 else (0.10 + (k - 8) * 0.06)
            c = TERM_GREY if k < 8 else TERM_BLUE
            bx(m, "Steel", c, x - 0.022, x + 0.022, 0.50, 0.60, -0.40, -0.385)
            tb(m, "Steel", (0.75, 0.75, 0.72), (x, 0.58, -0.40), (x, 0.58, -0.402), 0.006, segs=6)
        bx(m, "Steel", LIGHT, -0.52, -0.10, 0.62, 0.65, -0.392, -0.388)
        bx(m, "Steel", LIGHT, 0.10, 0.52, 0.62, 0.65, -0.392, -0.388)
        sm = CModel(seed=911)
        sm.ground = False
        sm.color = (1, 1, 1)
        w, y0, y1, z = 0.52, 0.86, 1.39, -0.298
        sm.add("Screen", [(-w, y1, z), (w, y1, z), (w, y0, z), (-w, y0, z)],
               [(0, 0, 1)] * 4, [(0, 0), (1, 0), (1, 1), (0, 1)], [(0, 3, 2), (0, 2, 1)])
        return m, sh, [("Screen", "mesh", (sm, (0, 0, 0)))]

    S = lambda seed, b, col, d, extra=None: s_box(seed, b, col, d, extra)
    out.update({
        "sigCable": (p_sigCable, ["steel"]),
        "lgAnd": (gate("and", 2, 1), ["steel"]),
        "lgOr": (gate("or", 2, 1), ["steel"]),
        "lgXor": (gate("xor", 2, 1), ["steel"]),
        "lgNot": (gate("not", 1, 1), ["steel"]),
        "lgTimer": (gate("timer", 1, 1), ["steel"]),
        "lgLatch": (gate("latch", 2, 1), ["steel"]),
        "lgCmp": (gate("cmp", 2, 1), ["steel"]),
        "lgCounter": (gate("counter", 2, 1), ["steel"]),
        "lsPress": (S(920, (-0.07, 0.07, 0, 0.11, -0.09, 0.09), RAL7035, 0.05, press_head), ["steel"]),
        "lsGas": (S(921, (-0.08, 0.08, 0, 0.09, -0.11, 0.11), RAL7035, 0.085, grille), ["steel"]),
        "lsTemp": (S(922, (-0.06, 0.06, 0, 0.16, -0.08, 0.08), RAL7035, 0.02, temp_head), ["steel"]),
        "lsFlow": (S(923, (-0.07, 0.07, 0, 0.1, -0.09, 0.09), RAL7035, 0.03, flow_head), ["steel"]),
        "lsLevel": (S(924, (-0.07, 0.07, 0, 0.1, -0.09, 0.09), RAL7035, 0.095, level_head), ["steel"]),
        "lsPower": (S(925, (-0.07, 0.07, 0, 0.07, -0.09, 0.09), RAL7035, 0.065, meter), ["steel"]),
        "lsDose": (S(926, (-0.08, 0.08, 0, 0.1, -0.1, 0.1), YELLOW, 0.095, dose_face), ["steel"]),
        "lsProx": (p_prox, ["steel"]),
        "lsDay": (p_day, ["steel"]),
        "lsReactor": (S(927, (-0.08, 0.08, 0, 0.09, -0.1, 0.1), RAL7016, 0.085, meter), ["steel"]),
        "lsDoor": (p_door, ["steel"]),
        "liButton": (p_button, ["steel"]),
        "liLever": (p_lever, ["steel"]),
        "liKeypad": (p_keypad, ["steel"]),
        "loLamp": (p_lamp, ["steel"]),
        "loAlarm": (p_alarm, ["steel"]),
        "lwTx": (p_radio(True), ["steel"]),
        "lwRx": (p_radio(False), ["steel"]),
        "lgPlc": (p_plc, ["steel"]),
    })
    NO_PAINT.update(out.keys())
    return out
