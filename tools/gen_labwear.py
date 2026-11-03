#!/usr/bin/env python3
"""Generate the lab SCIENTISTS' clothes on the crew's rig.

    python3 tools/gen_labwear.py          # textures/lab/cloth_*.png, models/lab/scientist.glb
    python3 tools/gen_labwear.py --neck   # … and measure the collar against every head's neck
    python3 tools/gen_labwear.py --dry    # print the budget, write nothing

The geometry is modelled in Blender (tools/gen_labwear_blender.py, headless,
on the suit generator's helpers); this takes it back to the rig's bind space
and writes a skinned glb on the UNTOUCHED rig of models/astronaut/
astronaut_male.glb (the skeleton, its rest pose and its inverse bind
matrices copied byte for byte), so the crew's clips, the IK and the Face
attachment (scripts/face.lua: the crew's own heads, hair and expressions) all
work on it unchanged. The rest box's centre is pinned to the suit's
(gen_suit REST_CENTRE) so the prefab places it exactly as the CrewBody's
suit.

Writes
    models/lab/scientist.glb            the coat, collar, sleeves, gloves, trousers, shoes
    textures/lab/cloth_{albedo,normal,orm}.png   cotton twill (512²)

THE NECK. A scientist's head is the crew's head (models/astronaut/faces),
hung rigid on the Head bone with its own neck running down to about
y 1.48 m. The coat's band collar stands round it: `--neck` casts rays out
from the neck's axis at every height the collar covers and checks the head's
neck is inside the collar's inner face with clearance, for all eight heads
and the head turned through its idle range (yaw ±20°, pitch ±12°); it
exits 1 when any pokes through.
"""
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_suit as GS  # noqa: E402
from gen_part_meshes import ROOT  # noqa: E402
from gen_part_textures import normal_from_height  # noqa: E402

OUT_GLB = os.path.join(ROOT, "models", "lab", "scientist.glb")
TEXDIR = os.path.join(ROOT, "textures", "lab")
MAT_ORDER = ["LabCloth", "LabKnit", "LabNitrile", "LabShoe", "LabPlastic", "SuitHead"]


def tex_cloth(n=512):
    """Cotton twill: a 2/1 diagonal rib, the yarn's own slubs, low contrast."""
    rng = np.random.default_rng(11)
    y, x = np.mgrid[0:n, 0:n].astype(float)
    # the twill's diagonal at 8 px a rib: the mip chain blurs it to an even
    # grey long before it can beat against the screen's pixels (a 3 px rib
    # moired across the whole coat at a few metres)
    rib = 0.5 + 0.5 * np.sin((x + y * 0.5) * (2 * math.pi / 8.0))
    weft = 0.5 + 0.5 * np.sin(y * (2 * math.pi / 16.0))
    slub = rng.random((n // 16, n // 16))
    slub = np.kron(slub, np.ones((16, 16)))
    from PIL import ImageFilter
    sl = np.asarray(Image.fromarray((slub * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6)), float) / 255
    # soft creases at a few centimetres (the texture tiles every 0.3 m on the
    # coat): pressed cotton is never flat
    cr = rng.random((8, 8))
    cr = np.asarray(Image.fromarray((cr * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC).filter(
        ImageFilter.GaussianBlur(18)), float) / 255
    crease = np.abs(np.sin((x * 0.6 + y * 0.25) / n * math.pi * 6 + cr * 6)) ** 0.5
    h = 0.30 * rib + 0.10 * weft + 0.25 * sl + 0.35 * crease
    alb = 0.94 + 0.012 * (rib - 0.5) + 0.02 * (sl - 0.5)
    A = np.clip(np.stack([alb, alb * 1.002, alb * 0.996], -1), 0, 1)
    Image.fromarray((A * 255).astype(np.uint8)).save(os.path.join(TEXDIR, "cloth_albedo.png"))
    nm = normal_from_height(h, strength=1.4)
    Image.fromarray((np.clip(nm, 0, 1) * 255).astype(np.uint8) if nm.dtype != np.uint8 else nm).save(os.path.join(TEXDIR, "cloth_normal.png"))
    orm = np.stack([0.85 + 0.15 * crease, 0.90 + 0.06 * (1 - h), np.zeros_like(h)], -1)
    Image.fromarray((np.clip(orm, 0, 1) * 255).astype(np.uint8)).save(os.path.join(TEXDIR, "cloth_orm.png"))


def tex_knit(n=256):
    """A jersey knit: fine vertical wales (the stitches' columns), the courses
    across them, a heathered fleck of two yarns."""
    from PIL import ImageFilter
    rng = np.random.default_rng(23)
    y, x = np.mgrid[0:n, 0:n].astype(float)
    wale = 0.5 + 0.5 * np.cos(x * (2 * math.pi / 4.0))
    course = 0.5 + 0.5 * np.cos(y * (2 * math.pi / 3.0) + (x // 2 % 2) * math.pi)
    fleck = rng.random((n, n))
    fleck = np.asarray(Image.fromarray((fleck * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.7)), float) / 255
    h = 0.6 * wale + 0.25 * course + 0.15 * fleck
    alb = 0.90 + 0.10 * (fleck - 0.5) + 0.05 * (wale - 0.5)
    Image.fromarray((np.clip(np.stack([alb, alb, alb * 1.01], -1), 0, 1) * 255).astype(np.uint8)).save(
        os.path.join(TEXDIR, "knit_albedo.png"))
    nm = normal_from_height(h, strength=2.2)
    Image.fromarray((np.clip(nm, 0, 1) * 255).astype(np.uint8)).save(os.path.join(TEXDIR, "knit_normal.png"))
    orm = np.stack([0.75 + 0.25 * wale, 0.92 + 0.0 * h, np.zeros_like(h)], -1)
    Image.fromarray((np.clip(orm, 0, 1) * 255).astype(np.uint8)).save(os.path.join(TEXDIR, "knit_orm.png"))


def run_blender(rig_path, out):
    cmd = [GS.blender_bin(), "--background", "--factory-startup", "--python",
           os.path.join(ROOT, "tools", "gen_labwear_blender.py"), "--", rig_path, out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        sys.stderr.write(r.stdout[-6000:] + r.stderr[-4000:])
        sys.exit("gen_labwear: the Blender stage failed")


def assemble(rig, npz):
    z = np.load(npz)
    D = z["D"]
    man = json.loads(bytes(z["manifest"]).decode())
    sk = GS.Skin(rig)
    for i, m in enumerate(man):
        P, N, UV, C = z[f"{i}_P"], z[f"{i}_N"], z[f"{i}_UV"], z[f"{i}_C"]
        Jn, W, I = z[f"{i}_J"], z[f"{i}_W"], z[f"{i}_I"]
        P, N = GS.unpose(P, N, Jn, W, D)
        sk.add(m["mat"], P, N, UV, C, Jn, W, I)
    return sk, man


def pin_centre(sk, want):
    mn, mx = sk.bounds()
    want = np.asarray(want)
    lo, hi = mn.copy(), mx.copy()
    for a in range(3):
        c = (lo[a] + hi[a]) / 2
        if c < want[a]:
            hi[a] = 2 * want[a] - lo[a]
        else:
            lo[a] = 2 * want[a] - hi[a]
    P = np.array([lo, lo, lo, hi, hi, hi])
    J = np.tile([sk.rig.index["Back"], 0, 0, 0], (6, 1))
    W = np.tile([1.0, 0, 0, 0], (6, 1))
    sk.add("LabCloth", P, np.tile([0, 1, 0], (6, 1)), np.zeros((6, 2)), np.ones((6, 3)), J, W,
           np.array([[0, 1, 2], [3, 4, 5]]))
    mn2, mx2 = sk.bounds()
    return (mn2 + mx2) / 2


def write(sk, rig, path):
    src = rig.json
    g = GS.GlbWriter()
    for mat in MAT_ORDER:
        if mat not in sk.parts:
            continue
        e = sk.parts[mat]
        g.prim(mat, np.vstack(e["P"]), np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), sk.faces(mat),
               np.vstack(e["J"]), np.vstack(e["W"]))
    g.accs.append({"bufferView": g.view(rig.ibm_bytes), "componentType": 5126, "count": len(rig.ibm_bytes) // 64,
                   "type": "MAT4"})
    nodes = json.loads(json.dumps(src["nodes"]))
    skin = dict(src["skins"][0])
    skin["inverseBindMatrices"] = len(g.accs) - 1
    nodes[rig.mesh_node]["mesh"] = 0
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_labwear.py",
                             "copyright": "Rig: Clint Bellanger 2009, CC-BY-SA 3.0. Clothes: Solar, CC-BY-SA 3.0."},
                   "scene": src.get("scene", 0), "scenes": src["scenes"], "nodes": nodes,
                   "meshes": [{"name": "LabWear", "primitives": g.prims}], "skins": [skin]})


# ── the neck check ──────────────────────────────────────────────────────────
def _rot(yaw, pitch):
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    return Ry @ Rx


def neck_check(sk, rig):
    """The collar's inner face against each head's neck, by direction round
    the neck's axis at each height: the minimum clearance (mm); < 0 is a poke."""
    import gen_suit as _g
    sys.path.insert(0, os.path.join(ROOT, "tools", "perf"))
    import neck_check as NC
    P = np.vstack([np.vstack(sk.parts[m_]["P"]) for m_ in ("LabCloth", "LabKnit") if m_ in sk.parts])
    collar = P[(P[:, 1] > 1.545) & (P[:, 1] < 1.62) & (np.abs(P[:, 0] + 0.5) < 0.1)]
    hb = rig.p("Head")
    worst = 1e9
    rows = []
    for h in range(1, 9):
        j, B = NC.read_glb(os.path.join(ROOT, "models", "astronaut", "faces", f"head_{h}.glb"))
        Ph = NC.acc(j, B, j["meshes"][0]["primitives"][0]["attributes"]["POSITION"]).astype(float)
        Ph = Ph[Ph[:, 0] > -0.69]
        for yaw in (-20, 0, 20):
            for pitch in (-12, 0, 12):
                R = _rot(math.radians(yaw), math.radians(pitch))
                # the collar's top follows a third of the turn: compare in a frame turned by 2/3
                R2 = _rot(math.radians(yaw * 0.66), math.radians(pitch * 0.66))
                Q = (Ph - hb) @ R2.T + hb
                mind = 1e9
                for y in np.arange(1.556, 1.60, 0.006):
                    cs = collar[np.abs(collar[:, 1] - y) < 0.004]
                    ns = Q[np.abs(Q[:, 1] - y) < 0.003]
                    if len(cs) < 8 or len(ns) < 8:
                        continue
                    c = np.array([-0.5, -0.055])
                    ac = np.arctan2(cs[:, 0] - c[0], cs[:, 2] - c[1]); rc = np.hypot(cs[:, 0] - c[0], cs[:, 2] - c[1])
                    an = np.arctan2(ns[:, 0] - c[0], ns[:, 2] - c[1]); rn = np.hypot(ns[:, 0] - c[0], ns[:, 2] - c[1])
                    for k in range(24):
                        a0 = -math.pi + k * math.pi / 12
                        mc, mn_ = (ac >= a0) & (ac < a0 + math.pi / 12), (an >= a0) & (an < a0 + math.pi / 12)
                        if mc.any() and mn_.any():
                            mind = min(mind, rc[mc].min() - rn[mn_].max())
                rows.append((h, yaw, pitch, mind * 1000))
                worst = min(worst, mind)
    for h in range(1, 9):
        r = [x for x in rows if x[0] == h]
        print(f"  head {h}: collar clearance min {min(x[3] for x in r):5.1f} mm  (rest {[x[3] for x in r if x[1] == 0 and x[2] == 0][0]:.1f})")
    return worst * 1000


def main():
    dry = "--dry" in sys.argv
    os.makedirs(TEXDIR, exist_ok=True)
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    if not dry:
        tex_cloth()
        tex_knit()
    rig_path = os.path.join(ROOT, "models", "astronaut", "astronaut_male.glb")
    rig = GS.Rig(rig_path)
    tmp = tempfile.mkdtemp(prefix="gen_lab_")
    try:
        npz = os.path.join(tmp, "lab.npz")
        run_blender(rig_path, npz)
        sk, man = assemble(rig, npz)
        c = pin_centre(sk, GS.REST_CENTRE["male"])
        per = {m: len(sk.faces(m)) for m in sk.parts}
        print(f"scientist tris {sk.tris()} {per} centre {np.round(c, 5).tolist()}")
        if "--pieces" in sys.argv:
            for m in sorted(man, key=lambda m: -m["tris"]):
                print(f"    {m['tris']:6d}  {m['name']:24s} {m['mat']}")
        if "--neck" in sys.argv:
            w = neck_check(sk, rig)
            print(f"neck: worst clearance {w:.1f} mm")
            if w < 0:
                sys.exit(1)
        if not dry:
            write(sk, rig, OUT_GLB)
            print("wrote", os.path.relpath(OUT_GLB, ROOT))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
