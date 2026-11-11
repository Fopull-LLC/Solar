#!/usr/bin/env python3
"""The kit's lockable storage props (the interaction plan S5, work/interact/PLAN.md §5.1).

    python3 tools/gen_kit_storage.py          # models/kit/{cabinet,locker}_steel.glb, their prefabs,
                                              # and their lines in tests/fixtures/kit_shapes.lua
    python3 tools/gen_kit_storage.py --dry    # bounds only

Two pieces beside the crates, shelving, bunks and the workbench that already hold
things (scripts/loot.lua makes every one of them a container `piece:<sid>:<uid>`):

  cabinet  a 0.9 m two-door steel store cabinet, 1.9 m tall, louvred, with a
           keypad by the right door's handle (a code locks it)
  locker   a 0.5 m personnel locker, 1.9 m tall, vent slots, a number plate and
           a keypad

Built with gen_kit_parts' primitives and materials exactly as tools/gen_kit_props.py
builds the other props (one model, one collider box). `pieces(K)` is the entry
gen_kit_parts.PIECES takes (work/interact_s5/gen_kit_parts_storage.patch adds the
import line there, so a full regeneration keeps these two); this file's own
`main` writes just them so the kit's owner does not have to regenerate the kit.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OLIVE = (0.36, 0.40, 0.33)      # store cabinet enamel (the kit paints over it)
LOCKER = (0.42, 0.47, 0.52)     # a grey-blue locker enamel


def pieces(K):
    """More entries for gen_kit_parts.PIECES (K = that module)."""
    CModel, Shell, bx = K.CModel, K.Shell, K.bx
    DARK, GREY, LIGHT, SAFETY = K.DARK, K.GREY, K.LIGHT, K.SAFETY
    out = {}

    def keypad(m, x, y, z):
        """A keypad on a face at +Z z: a plate, a dark LCD, a 3 x 4 grid of keys (all proud of each other)."""
        bx(m, "Steel", DARK, x - 0.045, x + 0.045, y - 0.07, y + 0.07, z, z + 0.012)
        bx(m, "Screen", (0.05, 0.07, 0.08), x - 0.034, x + 0.034, y + 0.032, y + 0.058, z + 0.012, z + 0.016)
        for r in range(4):
            for c in range(3):
                kx = x - 0.026 + c * 0.026
                ky = y + 0.012 - r * 0.02
                bx(m, "Steel", LIGHT, kx - 0.009, kx + 0.009, ky - 0.007, ky + 0.007, z + 0.012, z + 0.018)

    def p_cabinet(_mat):
        m, sh = CModel(seed=561), Shell()
        w, h, d = 0.9, 1.9, 0.5
        # the carcass (back and sides), a plinth set in 2 cm, the doors 2 mm proud of the front edge
        bx(m, "Steel", OLIVE, -w / 2, w / 2, 0.06, h, -d / 2, d / 2 - 0.02)
        bx(m, "Steel", DARK, -w / 2 + 0.02, w / 2 - 0.02, 0.0, 0.06, -d / 2 + 0.02, d / 2 - 0.04)
        gap = 0.004
        for sx in (-1, 1):
            x0, x1 = (-w / 2 + 0.01, -gap) if sx < 0 else (gap, w / 2 - 0.01)
            bx(m, "Steel", OLIVE, x0, x1, 0.08, h - 0.02, d / 2 - 0.02, d / 2 - 0.002)
            # louvres high and low on each door
            for y in (h - 0.36, h - 0.30, h - 0.24, 0.24, 0.30, 0.36):
                bx(m, "Steel", DARK, x0 + 0.08, x1 - 0.08, y, y + 0.022, d / 2 - 0.002, d / 2 + 0.004)
            # the handles by the middle gap
            hx = -0.05 if sx < 0 else 0.05
            bx(m, "Steel", LIGHT, hx - 0.012, hx + 0.012, 0.86, 1.10, d / 2 + 0.006, d / 2 + 0.03)
        keypad(m, 0.16, 1.18, d / 2 - 0.002)
        # a stencil band and a top lip
        bx(m, "Steel", SAFETY, -0.30, -0.10, h - 0.12, h - 0.07, d / 2 - 0.002, d / 2 + 0.003)
        bx(m, "Steel", GREY, -w / 2 - 0.004, w / 2 + 0.004, h, h + 0.02, -d / 2 - 0.004, d / 2 + 0.002)
        sh.add((0, (h + 0.02) / 2, 0), (w, h + 0.02, d))
        return m, sh, []
    out["cabinet"] = (p_cabinet, ["steel"])

    def p_locker(_mat):
        m, sh = CModel(seed=562), Shell()
        w, h, d = 0.5, 1.9, 0.5
        bx(m, "Steel", LOCKER, -w / 2, w / 2, 0.08, h, -d / 2, d / 2 - 0.02)
        bx(m, "Steel", DARK, -w / 2 + 0.02, w / 2 - 0.02, 0.0, 0.08, -d / 2 + 0.02, d / 2 - 0.04)
        x0, x1 = -w / 2 + 0.012, w / 2 - 0.012
        bx(m, "Steel", LOCKER, x0, x1, 0.10, h - 0.02, d / 2 - 0.02, d / 2 - 0.002)
        # vent slots top and bottom
        for y in (h - 0.30, h - 0.26, h - 0.22, h - 0.18, 0.22, 0.26, 0.30):
            bx(m, "Steel", DARK, x0 + 0.08, x1 - 0.08, y, y + 0.016, d / 2 - 0.002, d / 2 + 0.004)
        # a number plate, the handle, the keypad above it
        bx(m, "Steel", LIGHT, -0.07, 0.07, h - 0.50, h - 0.42, d / 2 - 0.002, d / 2 + 0.004)
        bx(m, "Steel", LIGHT, 0.14, 0.17, 0.88, 1.08, d / 2 + 0.006, d / 2 + 0.03)
        keypad(m, 0.12, 1.20, d / 2 - 0.002)
        bx(m, "Steel", GREY, -w / 2 - 0.004, w / 2 + 0.004, h, h + 0.02, -d / 2 - 0.004, d / 2 + 0.002)
        sh.add((0, (h + 0.02) / 2, 0), (w, h + 0.02, d))
        return m, sh, []
    out["locker"] = (p_locker, ["steel"])
    return out


def main():
    import gen_kit_parts as K
    dry = "--dry" in sys.argv
    os.makedirs(K.MODELS, exist_ok=True)
    fixture = []
    for piece, (fn, mats) in pieces(K).items():
        for mat in mats:
            K.write_piece(piece, mat, fn, dry, fixture)
    if dry:
        return
    path = os.path.join(K.ROOT, "tests", "fixtures", "kit_shapes.lua")
    with open(path) as f:
        text = f.read()
    for line in fixture:
        name = line.strip().split(" ", 1)[0]
        pat = re.compile(r"^  " + re.escape(name) + r" = .*$", re.M)
        if pat.search(text):
            text = pat.sub(line.replace("\\", "\\\\"), text)
        else:
            text = text.rstrip()
            assert text.endswith("}")
            text = text[:-1] + line + "\n}\n"
    with open(path, "w") as f:
        f.write(text)


if __name__ == "__main__":
    main()
