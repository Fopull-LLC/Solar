#!/usr/bin/env python3
"""THE BASE BUILDINGS' FOUNDATIONS: where each structure meets the ground, as
rectangles in its own ground frame, written into scripts/base_facilities.lua
(the FOUNDATIONS block) for the concrete footings laid under it there.

    python3 tools/base_foundations.py          # rewrite the block
    python3 tools/base_foundations.py --dry    # print the rectangles only

(tools/gen_base.py runs it after it writes the models.)

WHY. A building is flat; the ground it stands on is graded to the SPHERE
(base_facilities "THE GROUND IS GRADED TO THAT SPHERE"). Away from the point
the building is stood on, the sphere falls below the floor's plane by s²/2R:
at the VAB's corners (39 m out) 0.9 m on a 900 m world and 1.3 m on a 600 m
one, under a floor slab cast 0.6 m deep. Measured in game (tools/perf/
fdnprobe.sh) the grade itself holds within +0.03..+0.25 m of the sphere on an
Earth-like and an alien home; the gaps were the sag. So everything that
stands on the ground gets a footing down to FOOT_Y.

HOW. Each model's glb (the root mesh: for the VAB that is the slab, which the
walls stand on) is read back into its ground frame (the prefab's seat / ox /
oz), every triangle clipped to y <= CONTACT, and the pieces rasterised into
CELL-metre cells holding the lowest geometry over them. Cells with about the
same bottom are merged into rectangles; each rectangle is a footing whose top
sits just under that bottom (TOP_GAP) and whose sides stand a little proud of
the geometry (PAD), so no face of it shares a plane with the model's. A
footing that stays buried even on the smallest home world (BURIED) is left
out. base_facilities builds the footings into its concrete mesh: no draw
call or collider of their own, nothing per frame.
"""
import json
import os
import re
import struct
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "scripts", "base_facilities.lua")

CELL = 0.25        # m
CONTACT = 0.10     # geometry this low (ground frame y) stands on the ground
PAD = 0.03         # footing sides this far proud of the geometry (before rounding out to the cell)
TOP_GAP = 0.01     # footing top this far under the geometry's bottom
SAME = 0.06        # cells whose bottoms differ by less than this share a rectangle
FOOT_Y = -3.0      # footing bottom (ground frame y); at least MIN_DEPTH under its top
MIN_DEPTH = 1.0
R_MIN = 550.0      # smallest graded radius a home base is laid on (worlds are 600-950 m)
BURIED = -9.0      # (no footing is left out: the grade can sit lower than the sphere on rough ground)

# prefab, glb, lift (base_facilities FACILITIES)
STRUCTURES = [
    ("FacHangar", "vab.glb", 0.15),
    ("FacCommand", "command.glb", 0.15),
    ("FacDepot", "depot.glb", 0.15),
    ("FacTracking", "tracking.glb", 0.0),
    ("FacPower", "power.glb", 0.0),
    ("BaseFuel", "fuel.glb", 0.0),
    ("BasePad", "pad.glb", 0.0),
    ("FacIntake", "intake.glb", 0.15),
    ("FacRepair", "repair.glb", 0.15),
    ("FacLab", "lab.glb", 0.15),
    # (M1) the Medical Bay, and its link to the lab: MedLink's rows are in
    # FacMedical's ground frame (its prefab's seat / ox / oz say so), laid with
    # the bay only where the link stands
    ("FacMedical", "medical.glb", 0.15),
    ("MedLink", "medical_link.glb", 0.15),
]


def glb_triangles(path):
    d = open(path, "rb").read()
    jl = struct.unpack("<I", d[12:16])[0]
    js = json.loads(d[20:20 + jl])
    binb = d[20 + jl + 8:]
    out = []
    for mesh in js["meshes"]:
        for pr in mesh["primitives"]:
            pa = js["accessors"][pr["attributes"]["POSITION"]]
            bv = js["bufferViews"][pa["bufferView"]]
            P = np.frombuffer(binb, np.float32, pa["count"] * 3,
                              bv.get("byteOffset", 0) + pa.get("byteOffset", 0)).reshape(-1, 3)
            ia = js["accessors"][pr["indices"]]
            ib = js["bufferViews"][ia["bufferView"]]
            dt = {5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[ia["componentType"]]
            I = np.frombuffer(binb, dt, ia["count"], ib.get("byteOffset", 0) + ia.get("byteOffset", 0)).reshape(-1, 3)
            out.append(P[I].astype(np.float64))
    return np.concatenate(out)


def seat_of(prefab):
    txt = open(os.path.join(ROOT, "prefabs", prefab + ".prefab.ron")).read()
    m = re.search(r"seat ([-\d.]+) m, lot offset ox ([-\d.]+), oz ([-\d.]+)", txt)
    return tuple(float(v) for v in m.groups())


def clip_below(tri, y):
    """The part of a triangle at or under height y (a polygon, maybe empty)."""
    out = []
    n = len(tri)
    for i in range(n):
        a, b = tri[i], tri[(i + 1) % n]
        ia, ib = a[1] <= y, b[1] <= y
        if ia:
            out.append(a)
        if ia != ib:
            t = (y - a[1]) / (b[1] - a[1])
            out.append(a + (b - a) * t)
    return out


def contact_cells(T):
    cells = {}
    for tri in T[T.min(1)[:, 1] <= CONTACT]:
        poly = clip_below(tri, CONTACT)
        if len(poly) < 3:
            continue
        P = np.array(poly)
        lo = P.min(0)
        hi = P.max(0)
        x0, x1 = int(np.floor((lo[0] - PAD) / CELL)), int(np.floor((hi[0] + PAD) / CELL))
        z0, z1 = int(np.floor((lo[2] - PAD) / CELL)), int(np.floor((hi[2] + PAD) / CELL))
        if (x1 - x0 + 1) * (z1 - z0 + 1) > 250000:
            continue
        y = lo[1]
        for cx in range(x0, x1 + 1):
            for cz in range(z0, z1 + 1):
                k = (cx, cz)
                if k not in cells or y < cells[k]:
                    cells[k] = y
    return cells


def rectangles(cells):
    """Cells -> rectangles of about the same bottom: runs along x, row by row,
    then runs with the same ends stacked along z."""
    key = {k: int(np.floor(y / SAME + 0.5)) for k, y in cells.items()}
    rows = {}
    for (cx, cz) in sorted(cells):
        rows.setdefault(cz, []).append(cx)
    runs = []          # (x0, x1, z, key)
    for cz, xs in rows.items():
        xs.sort()
        s = xs[0]
        for i in range(1, len(xs) + 1):
            if i == len(xs) or xs[i] != xs[i - 1] + 1 or key[(xs[i], cz)] != key[(s, cz)]:
                runs.append((s, xs[i - 1], cz, key[(s, cz)]))
                if i < len(xs):
                    s = xs[i]
    open_ = {}
    rects = []
    for (x0, x1, cz, k) in sorted(runs, key=lambda r: (r[2], r[0])):
        prev = open_.pop((x0, x1, k, cz - 1), None)
        r = prev if prev else [x0, x1, cz, cz, k]
        r[3] = cz
        open_[(x0, x1, k, cz)] = r
        if not prev:
            rects.append(r)
    out = []
    for (x0, x1, z0, z1, k) in rects:
        y = min(cells[(cx, cz)] for cx in range(x0, x1 + 1) for cz in range(z0, z1 + 1) if (cx, cz) in cells)
        out.append((x0 * CELL, (x1 + 1) * CELL, z0 * CELL, (z1 + 1) * CELL, y - TOP_GAP))
    return out


def worst_float(r, lift):
    """How far the footing's top stands over the sphere at its farthest corner
    on the smallest world (the ground plane is `lift` over the sphere at x = z = 0)."""
    x0, x1, z0, z1, top = r
    s2 = max(x * x + z * z for x in (x0, x1) for z in (z0, z1))
    return top + lift + s2 / (2 * R_MIN)


def footings():
    res = {}
    for prefab, glb, lift in STRUCTURES:
        seat, ox, oz = seat_of(prefab)
        T = glb_triangles(os.path.join(ROOT, "models", "base", glb)) + np.array([ox, seat, oz])
        rects = [r for r in rectangles(contact_cells(T)) if worst_float(r, lift) > BURIED]
        rects.sort(key=lambda r: (r[2], r[0]))
        res[prefab] = rects
    return res


def lua_block(res):
    rows = ["FOUNDATIONS = {",
            f"  bottom = {FOOT_Y:.2f}, depth = {MIN_DEPTH:.2f},"]
    for prefab, _, _ in STRUCTURES:
        rows.append(f"  {prefab} = {{")
        for (x0, x1, z0, z1, top) in res[prefab]:
            rows.append(f"    {{ {x0:.2f}, {x1:.2f}, {z0:.2f}, {z1:.2f}, {top:.3f} }},")
        rows.append("  },")
    rows.append("}")
    return "\n".join(rows) + "\n"


def write(res=None):
    res = res or footings()
    src = open(LUA).read()
    a = src.index("-- FOUNDATIONS begin\n") + len("-- FOUNDATIONS begin\n")
    b = src.index("-- FOUNDATIONS end")
    open(LUA, "w").write(src[:a] + lua_block(res) + src[b:])
    print(f"base_foundations: {sum(len(v) for v in res.values())} footings under {len(res)} structures -> {LUA}")


def main():
    res = footings()
    for prefab, _, lift in STRUCTURES:
        print(f"{prefab}: {len(res[prefab])} footings")
        for r in res[prefab]:
            print(f"   x {r[0]:7.2f}..{r[1]:7.2f}  z {r[2]:7.2f}..{r[3]:7.2f}  top {r[4]:6.3f}  over the sphere at R {R_MIN:.0f}: {worst_float(r, lift):5.2f}")
    if "--dry" not in sys.argv:
        write(res)


if __name__ == "__main__":
    main()
