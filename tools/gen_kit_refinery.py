#!/usr/bin/env python3
"""The kit's REFINERY pieces: the crusher, the furnace, the kiln, the mixer, the electrolyser, the
Fabricator and the Jacket Radiator (expansion X6; scripts/parts_kit.lua REFINERY, scripts/machines.lua,
scripts/refinery.lua; docs/base-building.md §24).

Not run on its own: tools/gen_kit_parts.py imports it (`pieces(K)` hands back more entries for
its PIECES table, built with its own primitives). To write only these:

    python3 tools/gen_kit_refinery.py            # models/kit/mc*  prefabs/KitMc*  + fixture rows

1:1, in each piece's ground frame (+Y up, +Z its front). Belt ports at 0.8 m (BELT_Y), the heat
port and the fluid nozzles at 0.6 m (PIPE_Y), on the box faces parts_kit names:
* Crusher: a skid, the jaw crusher's frame with its two flywheels and motor, the feed hopper over
  it with the inlet boot and elevator casing from the −Z belt, the discharge apron to +Z, the spoil
  apron to +X, a tube stub at −X.
* Furnace: a cylindrical induction furnace (refractory shell, the coil's bands, a hood and stack),
  the feed screw from the −Z inlet, the caster and its apron to +Z, a second apron to +X, the
  jacket water's flanged heat port at −X, the control cabinet.
* Kiln: a refractory box kiln with its door, stack, inlet hood (−Z), discharge (+Z), heat port (−X).
* Mixer: a twin-shaft paddle trough on legs, its gear motor, inlet (−Z), discharge gate (+Z), its
  DN25 water nozzle (−X).
* Electrolyser: a stack cabinet with its cell plates, gauges, a vent; water (−X) and fuel (+X)
  nozzles.
* Fabricator: an open frame with a gantry mill over its bed, a part in its crate, the store bin
  with its belt inlet (−Z) and a tube stub (−X).
* Jacket Radiator: a 2 × 3 m finned panel on two posts, its headers end to end at 0.6 m.
"""
import math
import os
import sys

import numpy as np

BELT_Y = 0.8
PIPE_Y = 0.6
TR = 0.084
TFR = 0.14
TFT = 0.022

STRUCT = (0.36, 0.38, 0.36)
FRAME_Y = (0.78, 0.62, 0.16)
CAB = (0.70, 0.72, 0.70)
MOTOR = (0.20, 0.32, 0.42)
BLACK = (0.08, 0.08, 0.09)
TUBE = (0.62, 0.63, 0.62)
REFR = (0.66, 0.62, 0.56)        # refractory-lined steel, heat-stained
SHELL = (0.30, 0.29, 0.28)
COIL = (0.72, 0.42, 0.20)        # copper bands
COOL = (0.22, 0.38, 0.62)        # the jacket water's lines
FUEL = (0.86, 0.50, 0.14)
CRATE = (0.52, 0.40, 0.24)
WHITE = (0.82, 0.83, 0.80)

MATERIALS = {}


def pieces(K):
    CModel, Shell, bx, tb, rbox = K.CModel, K.Shell, K.bx, K.tb, K.rbox
    lathe = K.lathe
    DARK, GREY = K.DARK, K.GREY
    out = {}

    def apron(m, x0, x1, z0, z1, face=None):
        """A belt apron at belt height, its dark mouth on the face it meets."""
        # (the casing stops 3 mm short of the face its dark mouth is on: the mouth is the port's face)
        bx(m, "Steel", FRAME_Y, x0, x1 - (0.003 if face == "+x" else 0), BELT_Y - 0.02, BELT_Y + 0.25,
           z0 + (0.003 if face == "-z" else 0), z1 - (0.003 if face == "+z" else 0))
        if face == "+z":
            bx(m, "Steel", DARK, x0 + 0.04, x1 - 0.04, BELT_Y + 0.03, BELT_Y + 0.22, z1 - 0.005, z1)
        elif face == "-z":
            bx(m, "Steel", DARK, x0 + 0.04, x1 - 0.04, BELT_Y + 0.03, BELT_Y + 0.22, z0, z0 + 0.005)
        elif face == "+x":
            bx(m, "Steel", DARK, x1 - 0.005, x1, BELT_Y + 0.03, BELT_Y + 0.22, z0 + 0.04, z1 - 0.04)

    def tube_stub(m, port, n, start):
        port = np.asarray(port, float)
        n = np.asarray(n, float)
        fb = port - n * TFT
        tb(m, "Steel", TUBE, start, tuple(fb), TR, segs=16)
        tb(m, "Steel", GREY, tuple(fb), tuple(port), TFR, segs=18)

    def nozzle(m, port, n, length, r, col):
        """A flanged nozzle ending on `port`, facing n."""
        port = np.asarray(port, float)
        n = np.asarray(n, float)
        start = port - n * length
        fb = port - n * 0.02
        tb(m, "Steel", col, tuple(start), tuple(fb), r, segs=14)
        tb(m, "Steel", GREY, tuple(fb), tuple(port), r * 1.6, segs=16)

    def skid(m, sh, x0, x1, z0, z1, h=0.15):
        bx(m, "Steel", DARK, x0, x1, 0.0, h, z0, z1, sh=sh)

    # ── crusher ──
    def p_crusher(mat):
        m, sh = CModel(seed=1701), Shell()
        skid(m, sh, -1.0, 1.0, -1.0, 1.0)
        bx(m, "Steel", FRAME_Y, -0.7, 0.7, 0.15, 1.5, -0.65, 0.45, sh=sh)
        bx(m, "Steel", DARK, -0.72, 0.72, 1.45, 1.52, -0.67, 0.47)
        # the flywheels and the shaft
        for s in (-1, 1):
            tb(m, "Steel", GREY, (s * 0.74, 1.05, -0.5), (s * 0.92, 1.05, -0.5), 0.40, segs=28)
            tb(m, "Steel", DARK, (s * 0.92, 1.05, -0.5), (s * 0.96, 1.05, -0.5), 0.10, segs=12)
        tb(m, "Steel", GREY, (-0.74, 1.05, -0.5), (0.74, 1.05, -0.5), 0.07, segs=12)
        # the motor and its belt guard at the back
        tb(m, "Steel", MOTOR, (0.3, 0.45, -0.95), (0.3, 0.45, -0.7), 0.22, segs=16)
        bx(m, "Steel", FRAME_Y, 0.55, 0.7, 0.3, 1.2, -0.95, -0.66)
        # the feed hopper over it
        bx(m, "Steel", FRAME_Y, -0.6, 0.6, 1.5, 1.85, -0.55, 0.3)
        bx(m, "Steel", FRAME_Y, -0.95, 0.95, 1.85, 2.38, -0.95, 0.4, sh=sh)
        bx(m, "Steel", DARK, -0.97, 0.97, 2.33, 2.4, -0.97, 0.42)
        # the inlet boot at −Z and the elevator casing up to the hopper
        apron(m, -0.32, 0.32, -1.0, -0.66, "-z")
        bx(m, "Steel", GREY, -0.2, 0.2, BELT_Y + 0.25, 2.3, -1.0, -0.8)
        # the discharge apron to +Z, the spoil apron to +X (the magnetic drum's split)
        apron(m, -0.32, 0.32, 0.45, 1.0, "+z")
        tb(m, "Steel", GREY, (0.45, 0.62, 0.1), (0.45, 0.62, 0.447), 0.16, segs=16)
        apron(m, 0.6, 1.0, -0.3, 0.3, "+x")
        # the tube stub at −X
        tube_stub(m, (-1.0, BELT_Y, 0.0), (-1, 0, 0), (-0.7, BELT_Y, 0.0))
        # a ladder and a warning plate
        for z in (0.15, 0.35):
            bx(m, "Steel", STRUCT, 0.72, 0.75, 0.15, 1.85, z - 0.015, z + 0.015)
        bx(m, "Steel", (0.86, 0.68, 0.10), -0.5, -0.1, 1.1, 1.3, 0.45, 0.455)
        sh.add((0, 0.83, -0.1), (1.4, 1.36, 1.1))
        return m, sh, []

    # ── furnace ──
    def p_furnace(mat):
        m, sh = CModel(seed=1711), Shell()
        skid(m, sh, -1.0, 1.0, -1.0, 1.0)
        m.color = SHELL
        lathe(m, "Steel", [(0.62, 0.15), (0.7, 0.3), (0.7, 2.1), (0.6, 2.25)], segs=32, uv_m=1.0)
        m.color = REFR
        lathe(m, "Steel", [(0.6, 2.25), (0.45, 2.45), (0.2, 2.5)], segs=32, uv_m=1.0)
        for y in (0.6, 0.9, 1.2, 1.5, 1.8):
            m.color = COIL
            lathe(m, "Steel", [(0.715, y), (0.715, y + 0.08)], segs=32)
        tb(m, "Steel", SHELL, (0.0, 2.45, 0.0), (0.0, 2.97, 0.0), 0.18, segs=16)
        tb(m, "Steel", DARK, (0.0, 2.92, 0.0), (0.0, 3.0, 0.0), 0.22, segs=16)
        sh.add((0, 1.25, 0), (1.4, 2.2, 1.4))
        # the feed screw from the −Z inlet up into the hood
        apron(m, -0.32, 0.32, -1.0, -0.72, "-z")
        tb(m, "Steel", GREY, (0.0, 1.0, -0.86), (0.0, 2.3, -0.35), 0.13, segs=16)
        # the caster and its apron to +Z; the second apron to +X
        bx(m, "Steel", DARK, -0.35, 0.35, 0.15, 0.7, 0.62, 0.9)
        apron(m, -0.32, 0.32, 0.6, 1.0, "+z")
        apron(m, 0.62, 1.0, -0.2, 0.2, "+x")
        # the jacket water: supply and return along the shell to the heat port at −X
        nozzle(m, (-1.0, PIPE_Y, 0.5), (-1, 0, 0), 0.4, 0.06, COOL)
        tb(m, "Steel", COOL, (-0.6, PIPE_Y, 0.5), (-0.55, 1.9, 0.38), 0.04, segs=10)
        tb(m, "Steel", COOL, (-0.66, 0.4, 0.2), (-0.66, 1.9, 0.2), 0.035, segs=10)
        # the control cabinet
        bx(m, "Steel", CAB, 0.55, 0.98, 0.15, 1.8, -0.98, -0.62, sh=sh)
        bx(m, "Steel", BLACK, 0.62, 0.9, 1.2, 1.6, -0.62, -0.615)
        bx(m, "Steel", (0.9, 0.12, 0.08), 0.7, 0.78, 1.0, 1.08, -0.62, -0.612)
        return m, sh, []

    # ── kiln ──
    def p_kiln(mat):
        m, sh = CModel(seed=1721), Shell()
        skid(m, sh, -1.0, 1.0, -1.0, 1.0)
        bx(m, "Steel", REFR, -0.85, 0.85, 0.15, 1.85, -0.75, 0.6, sh=sh)
        bx(m, "Steel", SHELL, -0.88, 0.88, 1.82, 1.92, -0.78, 0.63)
        for x in (-0.6, -0.2, 0.2, 0.6):
            bx(m, "Steel", SHELL, x - 0.03, x + 0.03, 0.15, 1.85, 0.6, 0.64)
        # the door on +Z over the discharge
        bx(m, "Steel", SHELL, -0.45, 0.45, 1.0, 1.7, 0.6, 0.66)
        tb(m, "Steel", GREY, (-0.3, 1.35, 0.68), (0.3, 1.35, 0.68), 0.02, segs=8)
        tb(m, "Steel", SHELL, (0.5, 1.9, -0.3), (0.5, 2.4, -0.3), 0.12, segs=14)
        apron(m, -0.32, 0.32, -1.0, -0.75, "-z")
        bx(m, "Steel", GREY, -0.2, 0.2, BELT_Y + 0.25, 1.6, -0.95, -0.75)
        apron(m, -0.32, 0.32, 0.6, 1.0, "+z")
        nozzle(m, (-1.0, PIPE_Y, 0.5), (-1, 0, 0), 0.17, 0.06, COOL)
        tb(m, "Steel", COOL, (-0.86, 0.6, 0.45), (-0.86, 1.7, 0.45), 0.035, segs=10)
        bx(m, "Steel", CAB, 0.6, 0.98, 0.15, 1.5, -0.98, -0.75)
        return m, sh, []

    # ── mixer ──
    def p_mixer(mat):
        m, sh = CModel(seed=1731), Shell()
        for x in (-0.8, 0.8):
            for z in (-0.35, 0.35):
                bx(m, "Steel", STRUCT, x - 0.05, x + 0.05, 0.0, 0.55, z - 0.05, z + 0.05)
                bx(m, "Steel", DARK, x - 0.1, x + 0.1, 0.0, 0.015, z - 0.1, z + 0.1)
        bx(m, "Steel", FRAME_Y, -0.9, 0.9, 0.55, 1.2, -0.42, 0.42, sh=sh)
        bx(m, "Steel", DARK, -0.92, 0.92, 1.18, 1.24, -0.44, 0.44)
        # the twin shafts' bearings and the gear motor on +X
        for z in (-0.18, 0.18):
            tb(m, "Steel", GREY, (-0.95, 0.95, z), (0.95, 0.95, z), 0.05, segs=10)
        bx(m, "Steel", MOTOR, 0.45, 0.9, 1.24, 1.6, -0.3, 0.3)
        tb(m, "Steel", MOTOR, (0.1, 1.42, 0.0), (0.45, 1.42, 0.0), 0.14, segs=14)
        apron(m, -0.3, 0.3, -0.5, -0.3, "-z")
        bx(m, "Steel", GREY, -0.2, 0.2, BELT_Y + 0.25, 1.2, -0.5, -0.42)
        apron(m, -0.3, 0.3, 0.3, 0.5, "+z")
        nozzle(m, (-1.0, PIPE_Y, 0.0), (-1, 0, 0), 0.25, 0.017, COOL)
        tb(m, "Steel", COOL, (-0.75, PIPE_Y, 0.0), (-0.75, 1.0, 0.0), 0.017, segs=8)
        sh.add((0, 0.28, 0), (1.7, 0.55, 0.8))
        return m, sh, []

    # ── electrolyser ──
    def p_electro(mat):
        m, sh = CModel(seed=1741), Shell()
        bx(m, "Steel", DARK, -0.7, 0.7, 0.0, 0.1, -0.45, 0.45)
        bx(m, "Steel", WHITE, -0.62, 0.62, 0.1, 1.85, -0.42, 0.42, sh=sh)
        # the stack's cell plates behind its window
        bx(m, "Steel", BLACK, -0.5, 0.5, 0.5, 1.6, 0.42, 0.425)
        for k in range(14):
            x = -0.45 + k * 0.07
            bx(m, "Steel", (0.55, 0.58, 0.6), x - 0.012, x + 0.012, 0.55, 1.55, 0.425, 0.43)
        for x in (-0.3, 0.0, 0.3):
            tb(m, "Steel", GREY, (x, 1.72, 0.42), (x, 1.72, 0.45), 0.06, segs=12)
        tb(m, "Steel", GREY, (0.35, 1.85, -0.2), (0.35, 2.0, -0.2), 0.06, segs=10)
        tb(m, "Steel", GREY, (-0.35, 1.85, -0.2), (-0.35, 2.0, -0.2), 0.04, segs=10)
        nozzle(m, (-0.75, PIPE_Y, 0.0), (-1, 0, 0), 0.13, 0.017, COOL)
        nozzle(m, (0.75, PIPE_Y, 0.0), (1, 0, 0), 0.13, 0.017, FUEL)
        bx(m, "Steel", (0.86, 0.68, 0.10), -0.2, 0.2, 0.25, 0.4, 0.42, 0.425)
        return m, sh, []

    # ── Fabricator ──
    def p_fab(mat):
        m, sh = CModel(seed=1751), Shell()
        skid(m, sh, -1.0, 1.0, -1.0, 1.0)
        for x in (-0.95, 0.95):
            for z in (-0.95, 0.95):
                bx(m, "Steel", STRUCT, x - 0.05, x + 0.05, 0.15, 2.4, z - 0.05, z + 0.05)
        for x in (-0.95, 0.95):
            bx(m, "Steel", FRAME_Y, x - 0.06, x + 0.06, 2.2, 2.32, -0.95, 0.95)
        # the gantry and its spindle
        bx(m, "Steel", FRAME_Y, -0.9, 0.9, 1.95, 2.15, -0.1, 0.1)
        bx(m, "Steel", GREY, -0.15, 0.15, 1.3, 1.95, -0.15, 0.15)
        tb(m, "Steel", DARK, (0.0, 1.0, 0.0), (0.0, 1.3, 0.0), 0.05, segs=10)
        # the bed and a part in its crate
        bx(m, "Steel", DARK, -0.8, 0.8, 0.15, 0.75, -0.3, 0.8, sh=sh)
        bx(m, "Steel", CRATE, -0.5, 0.2, 0.75, 1.0, 0.1, 0.6)
        bx(m, "Steel", GREY, 0.3, 0.6, 0.75, 0.82, 0.0, 0.5)
        # the store bin at −Z with its belt inlet, the tube stub at −X
        bx(m, "Steel", FRAME_Y, -0.85, 0.85, 0.15, 1.4, -0.92, -0.35, sh=sh)
        apron(m, -0.32, 0.32, -1.0, -0.9, "-z")
        tube_stub(m, (-1.0, BELT_Y, 0.0), (-1, 0, 0), (-0.85, BELT_Y, 0.0))
        bx(m, "Steel", CAB, 0.62, 0.92, 0.15, 1.7, 0.55, 0.92)
        bx(m, "Steel", BLACK, 0.66, 0.88, 1.15, 1.55, 0.92, 0.925)
        return m, sh, []

    # ── Jacket Radiator ──
    def p_jacket(mat):
        m, sh = CModel(seed=1761), Shell()
        for x in (-0.95, 0.95):
            bx(m, "Steel", STRUCT, x - 0.047, x + 0.047, 0.0, 3.4, -0.06, 0.06)
            bx(m, "Steel", DARK, x - 0.12, x + 0.12, 0.0, 0.015, -0.12, 0.12)
        # the headers at the pipe height, flanged end to end
        tb(m, "Steel", COOL, (-0.98, PIPE_Y, 0.0), (0.98, PIPE_Y, 0.0), 0.05, segs=12)
        for s in (-1, 1):
            tb(m, "Steel", GREY, (s * 0.98, PIPE_Y, 0.0), (s * 1.0, PIPE_Y, 0.0), 0.09, segs=14)
        tb(m, "Steel", COOL, (-0.9, 3.25, 0.0), (0.9, 3.25, 0.0), 0.04, segs=10)
        # the panel and its fins
        bx(m, "Steel", (0.30, 0.31, 0.30), -0.9, 0.9, 0.7, 3.3, -0.02, 0.02, sh=sh)
        for k in range(13):
            x = -0.84 + k * 0.14
            bx(m, "Steel", (0.42, 0.43, 0.42), x - 0.008, x + 0.008, 0.72, 3.28, -0.15, 0.15)
        for x in (-0.6, 0.0, 0.6):
            tb(m, "Steel", COOL, (x, PIPE_Y, 0.0), (x, 0.72, 0.0), 0.025, segs=8)
        return m, sh, []

    out.update({
        "mcCrusher": (p_crusher, ["steel"]),
        "mcFurnace": (p_furnace, ["steel"]),
        "mcKiln": (p_kiln, ["steel"]),
        "mcMixer": (p_mixer, ["steel"]),
        "mcElectro": (p_electro, ["steel"]),
        "mcFab": (p_fab, ["steel"]),
        "mcJacket": (p_jacket, ["steel"]),
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
