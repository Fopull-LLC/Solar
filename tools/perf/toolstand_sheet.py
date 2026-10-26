#!/usr/bin/env python3
"""Contact sheets for the hand tools' design reviews, from toolstand.sh and
toolshots.sh pictures.

    toolstand_sheet.py protos STAND_DIR PROTOS_DIR OUT.png GAME:TL7=DIR GAME:A=DIR ...
        the laser design sheet: a row per design (the gravity gun first, for
        the family), 3/4 front and side from the bench (toolstand.sh PROTOS=…),
        first person in the game (toolshots.sh VARIANT=…, mode 1), labelled,
        with each design's triangle counts read from its .glb files.
    toolstand_sheet.py energy BEFORE_DIR AFTER_DIR OUT.png
        before / after of the gravity gun's energy treatment: toolshots.sh
        mode 1 pictures (BEFORE=1 and not), daylight and shade.
"""
import json
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")
STENCIL = os.path.join(ROOT, "fonts", "SolarStencil.ttf")
BG, INK, DIM, ACC = (24, 25, 27), (236, 230, 214), (150, 148, 140), (247, 140, 56)

DESIGNS = [
    ("GM-3", "GG", "Gravity gun (reference)",
     "The family look the lasers should match: blue field energy in the core, dish, cell and capacitor bands.",
     "gravity_gun"),
    ("TL-7", "TL7", "Current laser, fixed",
     "The game's laser now: the heat sink is a radial finned sink on the barrel's axis, glowing from the root out.",
     "terrain_laser_TL7"),
    ("A", "A", "TL-9 Excavator",
     "Heavy mining cutter: carry handle, twin cells, an exposed crystal focusing chamber between copper coils.",
     "terrain_laser_A"),
    ("B", "B", "TL-5 Surveyor",
     "Slim beam rifle: survey scope, ventilated barrel, a glowing coolant loop that warms from blue to amber.",
     "terrain_laser_B"),
    ("C", "C", "TL-3 Plasma Bore",
     "Stubby bore: hoop handle, a plasma drum seen between ribs, a six-electrode emitter crown that spins.",
     "terrain_laser_C"),
]


def glb_tris(path, pinned=False):
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack("<I", data[12:16])[0]
    js = json.loads(data[20:20 + n])
    t = 0
    for m in js["meshes"]:
        for p in m["primitives"]:
            t += js["accessors"][p["indices"]]["count"] // 3
    return t - 2 if pinned else t      # a view model's two zero-area box pins never draw


def font(path, size):
    return ImageFont.truetype(path, size)


def crop(im, box):
    w, h = im.size
    return im.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))


def fit(im, w, h):
    """Scale to cover w x h, centre-cropped."""
    s = max(w / im.width, h / im.height)
    im = im.resize((max(w, int(im.width * s)), max(h, int(im.height * s))), Image.LANCZOS)
    x, y = (im.width - w) // 2, (im.height - h) // 2
    return im.crop((x, y, x + w, y + h))


def protos(stand, pdir, out, games):
    CW, CH, LW, PAD = 520, 300, 360, 10
    cols = ["3/4 front · idle", "left side · working", "first person · in game, daylight"]
    rows = len(DESIGNS)
    W = LW + 3 * (CW + PAD) + PAD
    H = 120 + 40 + rows * (CH + PAD) + 70
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    d.text((PAD * 2, 22), "TERRAIN LASER — DESIGN PROTOTYPES", font=font(STENCIL, 44), fill=INK)
    d.text((PAD * 2, 78), "Same bench light for every design; the energy parts idle in the 3/4 view and working "
           "(charge and heat high) in the side view.", font=font(LABEL, 22), fill=DIM)
    for j, c in enumerate(cols):
        d.text((LW + PAD + j * (CW + PAD) + 6, 126), c.upper(), font=font(LABEL, 20), fill=DIM)
    y = 160
    for tag, key, name, line, glb in DESIGNS:
        tp = glb_tris(os.path.join(pdir, "models", "tools", glb + ".glb")) if key != "GG" else \
            glb_tris(os.path.join(ROOT, "models", "tools", "gravity_gun.glb"))
        fp = glb_tris(os.path.join(pdir, "models", "tools", "fp_" + glb + ".glb"), True) if key != "GG" else \
            glb_tris(os.path.join(ROOT, "models", "tools", "fp_gravity_gun.glb"), True)
        d.text((PAD * 2, y + 4), tag, font=font(STENCIL, 64 if len(tag) == 1 else 40), fill=ACC if len(tag) == 1 else INK)
        d.text((PAD * 2, y + 82), name, font=font(LABEL, 26), fill=INK)
        # the one-line description, wrapped to the label column
        words, ln, yy = line.split(), "", y + 120
        f = font(LABEL, 19)
        for wd in words:
            t = (ln + " " + wd).strip()
            if d.textlength(t, font=f) > LW - 3 * PAD:
                d.text((PAD * 2, yy), ln, font=f, fill=DIM)
                yy += 24
                ln = wd
            else:
                ln = t
        d.text((PAD * 2, yy), ln, font=f, fill=DIM)
        if tp:
            d.text((PAD * 2, y + CH - 30), f"{tp:,} tris held · {fp:,} first person", font=font(LABEL, 18), fill=DIM)
        cells = []
        for v in ("q", "side"):
            p = os.path.join(stand, f"{key}_{v}.png")
            cells.append(crop(Image.open(p).convert("RGB"), (0.02, 0.085, 0.98, 0.915)) if os.path.exists(p) else None)
        g = games.get(key)
        p = g and os.path.join(g, "day_fp_" + ("gravgun" if key == "GG" else "laser") + "_idle.png")
        cells.append(crop(Image.open(p).convert("RGB"), (0.30, 0.28, 1.0, 1.0)) if p and os.path.exists(p) else None)
        for j, im in enumerate(cells):
            x = LW + PAD + j * (CW + PAD)
            if im is None:
                d.rectangle((x, y, x + CW, y + CH), outline=DIM)
                d.text((x + 20, y + CH // 2), "(first-person shot pending)", font=font(LABEL, 20), fill=DIM)
            else:
                sheet.paste(fit(im, CW, CH), (x, y))
        y += CH + PAD
    d.text((PAD * 2, y + 18), "Pick A, B or C (or keep the TL-7). Every design keeps the same grip, fore-grip and "
           "first-person hands, and works with the same heat and charge effects.", font=font(LABEL, 20), fill=DIM)
    sheet.save(out)
    print("wrote", out, sheet.size)


def energy(before, after, out):
    CW, CH, LW, PAD = 760, 428, 250, 10
    rows = [("day_fp_gravgun_idle", "Daylight", "first person, idle"),
            ("day_fp_gravgun_work", "Daylight", "first person, reaching (charging)"),
            ("day_tp_gravgun_idle", "Daylight", "third person, idle"),
            ("day_tp_gravgun_work", "Daylight", "third person, reaching"),
            ("shade_fp_gravgun_idle", "Shade", "first person, idle"),
            ("shade_tp_gravgun_idle", "Shade", "third person, idle"),
            ("shade_tp_gravgun_work", "Shade", "third person, reaching")]
    W = LW + 2 * (CW + PAD) + PAD
    H = 130 + len(rows) * (CH + PAD) + 20
    sheet = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(sheet)
    d.text((PAD * 2, 20), "GM-3 GRAVITY GUN — ENERGY TREATMENT", font=font(STENCIL, 44), fill=INK)
    d.text((LW + PAD + 6, 92), "BEFORE (HEAD)", font=font(LABEL, 24), fill=DIM)
    d.text((LW + 2 * PAD + CW + 6, 92), "AFTER (tool_energy · tool_glass · tool_gauge)", font=font(LABEL, 24),
           fill=ACC)
    y = 130
    for name, light, what in rows:
        d.text((PAD * 2, y + 10), light.upper(), font=font(STENCIL, 30), fill=INK)
        d.text((PAD * 2, y + 52), what, font=font(LABEL, 20), fill=DIM)
        for j, base in enumerate((before, after)):
            p = os.path.join(base, name + ".png")
            x = LW + PAD + j * (CW + PAD)
            if os.path.exists(p):
                im = Image.open(p).convert("RGB")
                box = (0.30, 0.25, 1.0, 1.0) if "_fp_" in name else (0.0, 0.0, 1.0, 1.0)
                sheet.paste(fit(crop(im, box), CW, CH), (x, y))
            else:
                d.rectangle((x, y, x + CW, y + CH), outline=DIM)
        y += CH + PAD
    sheet.save(out)
    print("wrote", out, sheet.size)


def main():
    if sys.argv[1] == "protos":
        games = {}
        for a in sys.argv[5:]:
            k, v = a.split("=", 1)
            games[k.split(":", 1)[1]] = v
        protos(sys.argv[2], sys.argv[3], sys.argv[4], games)
    elif sys.argv[1] == "energy":
        energy(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
