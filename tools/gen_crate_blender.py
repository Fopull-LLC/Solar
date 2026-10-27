"""The base's SUPPLY CRATE, built in Blender (run headless by tools/gen_crate.py).

    blender --background --factory-startup --python tools/gen_crate_blender.py -- OUT.json

The held items' method and helpers (tools/gen_items_blender.py, whose builders
are reused here without running its own export): real bevels with the bevel
faces in a worn-edge material, stencils from the tools' decal atlas, written to
OUT.json as triangles per material.

A field supply crate, the kind that is dropped off a truck and left out in the
weather: a ribbed steel box in chipped olive drab, a lid that overhangs on a
piano hinge with a dark rubber gasket, steel corner caps, four over-centre
latches, rope-and-bar end handles, two skids under it so a forklift (or a
crane hook) gets under, a stencilled hazard band and serials, and a data plate.
1.10 m long (+Z), 0.66 wide (+X), 0.62 tall (+Y), origin on the ground at the
middle: about 480 L inside.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_src = open(os.path.join(HERE, "gen_items_blender.py")).read()
_src = _src.rsplit("\nmain()", 1)[0]          # the helpers, not the items' run
exec(compile(_src, "gen_items_blender.py", "exec"))

import json  # noqa: E402

WEAR["CrateOlive"] = "PaintWorn"  # noqa: F821  (from gen_items_blender)
WEAR["CrateLid"] = "PaintWorn"    # noqa: F821


def supply_crate():
    L, W, H = 1.10, 0.66, 0.62
    sk = 0.05                     # skid height
    body_h = H - sk - 0.10        # the tub; the lid is the top 0.10
    y0 = sk
    # the tub and the lid (the lid overhangs 1 cm all round)
    box("tub", "CrateOlive", (0, y0 + body_h / 2, 0), (W, body_h, L), bevel=0.016, segs=2)  # noqa: F821
    box("lid", "CrateLid", (0, y0 + body_h + 0.05 + 0.004, 0), (W + 0.02, 0.092, L + 0.02), bevel=0.018, segs=2)  # noqa: F821
    box("gasket", "Rubber", (0, y0 + body_h + 0.003, 0), (W + 0.006, 0.012, L + 0.006))  # noqa: F821
    # a pressed rib panel on the lid
    box("lid_rib", "CrateLid", (0, H + 0.006, 0), (W * 0.72, 0.012, L * 0.76), bevel=0.006)  # noqa: F821
    # pressed vertical ribs on the long sides and horizontal on the ends
    for s in (-1, 1):
        for k in range(5):
            z = -0.40 + k * 0.20
            box(f"rib{s}{k}", "CrateOlive", (s * (W / 2 + 0.006), y0 + body_h * 0.48, z),  # noqa: F821
                (0.014, body_h * 0.80, 0.045), bevel=0.004)
        for k in range(2):
            y = y0 + body_h * (0.30 + 0.38 * k)
            box(f"erib{s}{k}", "CrateOlive", (0, y, s * (L / 2 + 0.006)), (W * 0.80, 0.040, 0.014), bevel=0.004)  # noqa: F821
    # steel corner caps, top and bottom
    for sx in (-1, 1):
        for sz in (-1, 1):
            for top in (0, 1):
                y = (H - 0.035) if top else (y0 + 0.035)
                box(f"cap{sx}{sz}{top}", "Dark", (sx * (W / 2 - 0.015), y, sz * (L / 2 - 0.015)),  # noqa: F821
                    (0.078, 0.090, 0.078), bevel=0.010)
                bolt(f"capb{sx}{sz}{top}", (sx * (W / 2 + 0.025), y, sz * (L / 2 - 0.03)), (sx, 0, 0), r=0.006)  # noqa: F821
    # skids
    for sx in (-1, 1):
        box(f"skid{sx}", "Dark", (sx * (W / 2 - 0.10), sk / 2, 0), (0.09, sk, L * 0.96), bevel=0.006)  # noqa: F821
    # piano hinge along the back (-X) edge of the lid
    cyl("hinge", "Chrome", (-(W / 2 + 0.014), y0 + body_h + 0.004, -L / 2 + 0.06),  # noqa: F821
        (-(W / 2 + 0.014), y0 + body_h + 0.004, L / 2 - 0.06), 0.011, segs=10)
    # four over-centre latches on the front (+X) and the ends
    for z in (-0.30, 0.30):
        box(f"latch_base{z}", "Dark", (W / 2 + 0.012, y0 + body_h - 0.04, z), (0.016, 0.07, 0.07), bevel=0.003)  # noqa: F821
        box(f"latch_lever{z}", "Chrome", (W / 2 + 0.020, y0 + body_h + 0.010, z), (0.010, 0.10, 0.05), bevel=0.003)  # noqa: F821
        box(f"latch_keep{z}", "Dark", (W / 2 + 0.016, y0 + body_h + 0.075, z), (0.014, 0.030, 0.06), bevel=0.003)  # noqa: F821
    for s in (-1, 1):
        box(f"elatch_base{s}", "Dark", (0, y0 + body_h - 0.04, s * (L / 2 + 0.012)), (0.07, 0.07, 0.016), bevel=0.003)  # noqa: F821
        box(f"elatch_lever{s}", "Chrome", (0, y0 + body_h + 0.010, s * (L / 2 + 0.020)), (0.05, 0.10, 0.010), bevel=0.003)  # noqa: F821
    # end handles: two brackets and a rubber-sleeved bar, a rope through it
    for s in (-1, 1):
        zz = s * (L / 2 + 0.03)
        for sx in (-1, 1):
            box(f"hbr{s}{sx}", "Dark", (sx * 0.13, y0 + body_h * 0.62, s * (L / 2 + 0.016)), (0.03, 0.06, 0.032), bevel=0.004)  # noqa: F821
        cyl(f"hbar{s}", "Rubber", (-0.13, y0 + body_h * 0.62, zz), (0.13, y0 + body_h * 0.62, zz), 0.016, segs=10)  # noqa: F821
        hose(f"rope{s}", "Webbing", [(-0.19, y0 + body_h * 0.70, s * (L / 2 + 0.012)),  # noqa: F821
                                     (-0.10, y0 + body_h * 0.48, s * (L / 2 + 0.05)),
                                     (0.10, y0 + body_h * 0.48, s * (L / 2 + 0.05)),
                                     (0.19, y0 + body_h * 0.70, s * (L / 2 + 0.012))], 0.009, sides=6)
    # stencils: hazard band and serials on both long sides, an arrow on the lid
    for s in (-1, 1):
        decal(f"band{s}", "hazard", (s * (W / 2 + 0.0004), y0 + body_h * 0.86, 0), (s, 0, 0), (0, 1, 0), 0.86, 0.06)  # noqa: F821
        decal(f"serial{s}", "serial_a", (s * (W / 2 + 0.0004), y0 + body_h * 0.22, 0.10), (s, 0, 0), (0, 1, 0), 0.42, 0.05)  # noqa: F821
        decal(f"serialb{s}", "serial_b", (s * (W / 2 + 0.0004), y0 + body_h * 0.13, 0.10), (s, 0, 0), (0, 1, 0), 0.30, 0.035)  # noqa: F821
        decal(f"emb{s}", "emblem", (0, y0 + body_h * 0.5, s * (L / 2 + 0.0004)), (0, 0, s), (0, 1, 0), 0.16, 0.16)  # noqa: F821
    decal("arrow", "arrow", (0.0, H + 0.0125, 0.25), (0, 1, 0), (0, 0, 1), 0.16, 0.08)  # noqa: F821
    decal("lid_serial", "serial_b", (0.0, H + 0.0125, -0.18), (0, 1, 0), (1, 0, 0), 0.34, 0.04)  # noqa: F821
    # the data plate, riveted
    box("plate", "Chrome", (W / 2 + 0.0015, y0 + body_h * 0.50, -0.30), (0.003, 0.08, 0.14), bevel=0.001)  # noqa: F821
    for k, (dy, dz) in enumerate(((-0.03, -0.06), (-0.03, 0.06), (0.03, -0.06), (0.03, 0.06))):
        bolt(f"pb{k}", (W / 2 + 0.003, y0 + body_h * 0.50 + dy, -0.30 + dz), (1, 0, 0), r=0.004)  # noqa: F821
    return {"size": [W, H, L]}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    path = argv[0] if argv else "/tmp/crate_mesh.json"
    reset()  # noqa: F821
    anchors = supply_crate()
    geo = export()  # noqa: F821
    tris = sum(len(m["P"]) // 9 for m in geo.values())
    print(f"CRATE supply: {tris} tris, materials {sorted(geo.keys())}")
    with open(path, "w") as f:
        json.dump({"crate": {"geo": geo, "anchors": anchors}}, f)


main()
