#!/usr/bin/env python3
"""Generate the GAS parts (playtest 2026-11-03c): the four Gas Engines, the
two Gas Tanks, the Drive Chain's prefab (its mesh is builder_proc's, drawn to
its length) and the Gas Can the crew carries. (The Repair Bay's gas pump is
part of the bay: tools/base_buildings.py repair_bay().)

    python3 tools/gen_gas_parts.py          # meshes, prefabs, vis prefabs
    python3 tools/gen_gas_parts.py --dry    # print the frames only

Built from tools/gen_part_meshes.py's primitives and texture library, the
same as the auto parts (tools/gen_auto_parts.py), so a crankcase carries the
grain a fork does. Only its own files are written.

FRAMES (scripts/parts_auto.lua holds the same numbers):
* an engine's box is the part's (rx, h/2, rz) about its centre: X forward,
  Y up, Z across (+Z right). The single cylinder stands up and leans forward
  CYL_LEAN; the carburettor and its air filter behind it; the exhaust
  leaves the head forward, turns down and runs back along the right side to
  a silencer whose tailpipe is the module's ex, ey, ez (pointing −X); the
  gearbox sprocket stands just outside the LEFT case, at the module's
  sx, sy, sz, turning about Z.
* a tank's box is its part box; the filler on top.
* the Gas Can: +Y out of its handle (carried hanging from the left hand like
  the Repair Kit), its long side along +Z, the spout at the front (+Z).
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_part_meshes as G  # noqa: E402
from gen_part_meshes import Model, lathe, disk, box, tube, flange, bolt_ring, rot_z, rot_x, rot_y  # noqa: E402,F401

TAU = 2 * math.pi
CYL_LEAN = math.radians(14.0)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ITEM_MODELS = os.path.join(ROOT, "models", "items")

# materials beside gen_part_meshes' own (an engine's sand-cast alloy, its
# black barrel, heat-browned header pipe, a petrol-red enamel, olive drab)
G.MATERIALS.setdefault("Cast", lambda: G.mat_ron("metal", color=(0.62, 0.62, 0.60), rough=1.15, metal=0.45))
G.MATERIALS.setdefault("Barrel", lambda: G.mat_ron("metal", color=(0.17, 0.17, 0.18), rough=1.2, metal=0.35))
G.MATERIALS.setdefault("Header", lambda: G.mat_ron("metal", color=(0.42, 0.33, 0.27), rough=1.0, metal=0.6))
G.MATERIALS.setdefault("PetrolRed", lambda: G.mat_ron("paint", color=(0.58, 0.11, 0.07)))
G.MATERIALS.setdefault("Olive", lambda: G.mat_ron("paint", color=(0.33, 0.35, 0.24)))
G.MATERIALS.setdefault("Steel", lambda: G.mat_ron("metal", color=(0.70, 0.70, 0.68), rough=0.8, metal=0.6))

# The engines' boxes and their two points (parts_auto.lua gasengine sx/sy/sz, ex/ey/ez)
ENGINES = {
    "gasE50":  dict(cc=50,  hx=0.13, hy=0.13, hz=0.10, s=(-0.04, -0.07, -0.135), e=(-0.13, -0.08, 0.07), two=True,
                    prefab="PartGasE50", mass=0.011),
    "gasE125": dict(cc=125, hx=0.16, hy=0.16, hz=0.12, s=(-0.05, -0.09, -0.155), e=(-0.16, -0.10, 0.085), two=False,
                    prefab="PartGasE125", mass=0.022),
    "gasE250": dict(cc=250, hx=0.18, hy=0.19, hz=0.13, s=(-0.06, -0.11, -0.165), e=(-0.18, -0.12, 0.09), two=False,
                    prefab="PartGasE250", mass=0.028),
    "gasE500": dict(cc=500, hx=0.21, hy=0.22, hz=0.15, s=(-0.07, -0.13, -0.185), e=(-0.21, -0.14, 0.105), two=False,
                    prefab="PartGasE500", mass=0.036),
}


def along(m, p0, p1, r, mat, segs=10, caps=True):
    tube(m, mat, p0, p1, r, segs=segs, caps=caps, uv_m=6.0)


def pipe(m, pts, r, mat, segs=10):
    """A bent pipe through points: straight runs with a ball at each bend."""
    for a, b in zip(pts[:-1], pts[1:]):
        along(m, a, b, r, mat, segs=segs, caps=False)
    for p in pts[1:-1]:
        sph = Model()
        prof = [(r * math.sin(t), -r * math.cos(t)) for t in np.linspace(0, math.pi, 7)]
        lathe(sph, mat, prof, segs=segs, uv_m=6.0, smooth=True)
        m.merge(sph, None, p)


def toothed(m, mat, c, r, n, t, axis="z"):
    """A sprocket: n teeth on radius r, t thick, about Z (or X) through c."""
    sub = Model()
    prof = []
    k = 2 * n
    P, N, UV, I = [], [], [], []
    for sgn in (1, -1):
        base = len(P)
        P.append((0, 0, sgn * t / 2)); N.append((0, 0, sgn)); UV.append((0, 0))
        for i in range(k):
            a = TAU * i / k
            rr = r + 0.004 if i % 2 == 0 else r - 0.005
            P.append((rr * math.cos(a), rr * math.sin(a), sgn * t / 2)); N.append((0, 0, sgn)); UV.append((rr * math.cos(a) * 6, rr * math.sin(a) * 6))
        for i in range(k):
            j = (i + 1) % k
            I.append((base, base + 1 + i, base + 1 + j))
    sub.add(mat, P, N, UV, I)
    P, N, UV, I = [], [], [], []
    for i in range(k):
        a0, a1 = TAU * i / k, TAU * (i + 1) / k
        r0 = r + 0.004 if i % 2 == 0 else r - 0.005
        r1 = r + 0.004 if (i + 1) % 2 == 0 else r - 0.005
        p0, p1 = (r0 * math.cos(a0), r0 * math.sin(a0)), (r1 * math.cos(a1), r1 * math.sin(a1))
        nn = np.array([(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2, 0.0]); nn /= np.linalg.norm(nn)
        b = len(P)
        for (x, y) in (p0, p1):
            for z in (-t / 2, t / 2):
                P.append((x, y, z)); N.append(tuple(nn)); UV.append((x * 6, z * 6))
        I.append((b, b + 2, b + 3)); I.append((b, b + 3, b + 1))
    sub.add(mat, P, N, UV, I)
    M = np.eye(3) if axis == "z" else rot_y(math.pi / 2)
    m.merge(sub, M, c)


def finned_barrel(m, base, axis, r, h, fins, fin_r, mat_core="Barrel", mat_fin="Barrel"):
    """A finned cylinder barrel from `base` along `axis`: a core tube and
    `fins` square cooling fins (as thin boxes turned to the axis)."""
    axis = np.asarray(axis, float) / np.linalg.norm(axis)
    M = G.frame_to(axis)
    core = Model()
    lathe(core, mat_core, [(r, 0.0), (r, h)], segs=20, uv_m=6.0)
    m.merge(core, M, base)
    for k in range(fins):
        y = h * (k + 0.5) / fins
        f = Model()
        box(f, mat_fin, (0, y, 0), (fin_r * 2, 0.006, fin_r * 2 * 0.92), uv_m=6.0)
        m.merge(f, M, base)


def engine(spec):
    """A single-cylinder engine with its gearbox (see the module docstring)."""
    hx, hy, hz = spec["hx"], spec["hy"], spec["hz"]
    m = Model()
    # the crankcase / gearbox: a cast block in the lower half, its round
    # flywheel cover on the left and clutch cover on the right
    cy = -hy * 0.42
    box(m, "Cast", (-hx * 0.18, cy, 0), (hx * 1.45, hy * 0.95, hz * 1.35), uv_m=4.0, bevel=0.012)
    for sgn, rr in ((-1, 0.40), (1, 0.46)):
        cov = Model()
        R = min(hy * rr * 1.25, hz * 1.1)
        lathe(cov, "Cast", [(R, 0.0), (R * 0.97, 0.018), (R * 0.75, 0.03), (0.0, 0.032)], segs=28, uv_m=4.0, smooth=True)
        bolt_ring(cov, "Chrome", 0.03, R * 0.82, 6, size=0.006, height=0.006)
        M = rot_x(-sgn * math.pi / 2)        # +Y onto ±Z
        m.merge(cov, M, (-hx * 0.05 if sgn > 0 else -hx * 0.30, cy + hy * 0.05, sgn * hz * 0.66))
    # sump fins underneath
    for k in range(4):
        box(m, "Cast", (-hx * 0.55 + k * hx * 0.28, -hy * 0.93, 0), (0.012, hy * 0.12, hz * 1.1), uv_m=6.0)
    # the barrel and the head, leaning forward
    ax = np.array([math.sin(CYL_LEAN), math.cos(CYL_LEAN), 0.0])
    base = np.array([hx * 0.10, cy + hy * 0.40, 0.0])
    br = hz * 0.42
    bh = hy * 0.42
    finned_barrel(m, base, ax, br, bh, 5 if spec["cc"] >= 125 else 4, hz * 0.78)
    head_c = base + ax * (bh + hy * 0.10)
    M = G.frame_to(ax)
    hd = Model()
    box(hd, "Cast", (0, 0, 0), (hz * 1.45, hy * 0.20, hz * 1.45), uv_m=5.0, bevel=0.01)
    for k in range(2):
        box(hd, "Cast", (0, hy * 0.10 + 0.004 + k * 0.012, 0), (hz * 1.4 - k * 0.03, 0.005, hz * 1.4 - k * 0.03), uv_m=6.0)
    m.merge(hd, M, head_c)
    # spark plug and its cap, angled out of the head's back, the HT lead on back
    bk = np.array([-math.cos(CYL_LEAN), math.sin(CYL_LEAN), 0.0])
    pd = (bk + ax) / np.linalg.norm(bk + ax)
    plug0 = head_c + bk * hz * 0.6 + ax * hy * 0.05
    along(m, plug0, plug0 + pd * 0.022, 0.009, "Chrome", segs=8)
    along(m, plug0 + pd * 0.022, plug0 + pd * 0.05, 0.012, "Rubber", segs=10)
    pipe(m, [plug0 + pd * 0.045, plug0 + pd * 0.045 + np.array([-hx * 0.3, -hy * 0.1, -hz * 0.25]),
             np.array([-hx * 0.75, cy + hy * 0.5, -hz * 0.55])], 0.004, "Rubber", segs=6)
    # the intake: a stub off the back of the head, the carburettor and its
    # air filter pod, pointing back
    intake = head_c + np.array([-hz * 0.72, -hy * 0.10, 0.0])
    carb = intake + np.array([-hx * 0.18, -hy * 0.06, 0.0])
    along(m, intake, carb, hz * 0.18, "Rubber", segs=10)
    cb = Model()
    box(cb, "Cast", (0, 0, 0), (hx * 0.22, hy * 0.22, hz * 0.55), uv_m=6.0, bevel=0.006)
    along(cb, (0, hy * 0.11, 0), (0, hy * 0.19, 0), hz * 0.12, "Chrome", segs=10)   # the slide's cap
    m.merge(cb, None, carb)
    filt = carb + np.array([-hx * 0.22, -hy * 0.02, 0.0])
    fp = Model()
    lathe(fp, "Dark", [(hz * 0.2, 0.0), (hz * 0.42, 0.02), (hz * 0.46, hx * 0.18), (hz * 0.38, hx * 0.24), (0.0, hx * 0.25)],
          segs=18, uv_m=6.0, smooth=True)
    m.merge(fp, rot_z(math.pi / 2), filt)          # +Y onto −X
    # fuel line from above (the tank) to the carb's float bowl
    pipe(m, [carb + np.array([0.0, -hy * 0.11, hz * 0.2]), carb + np.array([0.02, -hy * 0.2, hz * 0.4]),
             np.array([carb[0] + 0.03, hy * 0.85, hz * 0.45])], 0.004, "Rubber", segs=6)
    # the exhaust: forward out of the head, down the front of the case, back
    # along the right side to the silencer
    ex = np.asarray(spec["e"], float)
    p0 = head_c + np.array([hz * 0.7, -hy * 0.03, 0.0])
    pts = [p0, p0 + np.array([hx * 0.12, -hy * 0.06, hz * 0.2]),
           np.array([hx * 0.84, -hy * 0.35, hz * 0.62]), np.array([hx * 0.76, -hy * 0.80, hz * 0.80]),
           np.array([hx * 0.20, -hy * 0.86, hz * 0.84]), np.array([-hx * 0.20, ex[1] + 0.01, ex[2]])]
    pr = hz * (0.15 if spec["two"] else 0.13)
    pipe(m, pts, pr, "Header", segs=10)
    if spec["two"]:
        # a two-stroke's expansion chamber: the fat belly under the case
        along(m, pts[3] + np.array([0.0, 0.0, 0.0]), pts[4], pr * 1.8, "Header", segs=12)
    # silencer and tailpipe
    sil0 = np.array([-hx * 0.18, ex[1], ex[2]])
    sil1 = np.array([ex[0] + 0.03, ex[1], ex[2]])
    along(m, sil0, sil1, pr * 1.55, "Steel", segs=14)
    along(m, sil1, np.array([ex[0], ex[1], ex[2]]), pr * 0.55, "Dark", segs=10)
    # the gearbox sprocket, outside the left case, and its output shaft
    s = np.asarray(spec["s"], float)
    along(m, (s[0], s[1], -hz * 0.6), (s[0], s[1], s[2] + 0.004), 0.012, "Steel", segs=10)
    teeth = {50: 13, 125: 14, 250: 13, 500: 15}[spec["cc"]]
    rp = 0.015875 / (2 * math.sin(math.pi / teeth))
    toothed(m, "Steel", (s[0], s[1], s[2]), rp, teeth, 0.006)
    # the gear lever and the kick-start
    pipe(m, [(s[0] + hx * 0.12, s[1] + hy * 0.06, -hz * 0.8), (s[0] + hx * 0.12, s[1] + hy * 0.06, -hz * 0.98),
             (s[0] + hx * 0.4, s[1] - hy * 0.1, -hz * 0.98)], 0.006, "Dark", segs=6)
    pipe(m, [(-hx * 0.62, cy + hy * 0.15, hz * 0.85), (-hx * 0.62, cy + hy * 0.15, hz * 0.98),
             (-hx * 0.95, cy + hy * 0.42, hz * 0.98)], 0.008, "Chrome", segs=6)
    # the mounting lugs the frame bolts through, front and back of the case
    for (x, y) in ((hx * 0.55, -hy * 0.15), (-hx * 0.85, -hy * 0.1), (-hx * 0.4, -hy * 0.84)):
        box(m, "Cast", (x, y, 0), (0.03, 0.03, hz * 1.5), uv_m=6.0)
        along(m, (x, y, -hz * 0.8), (x, y, hz * 0.8), 0.006, "Chrome", segs=6)
    return m


def clip_check(name, m, half, allow_z=0.03):
    mn, mx = m.bounds()
    h = np.asarray(half)
    over = np.maximum(mn * -1 - h, mx - h)
    over[2] = max(0.0, over[2] - allow_z)
    if (over > 0.006).any():
        print(f"  NOTE {name}: the mesh is past its box by {np.round(over, 3)}")


def tank_s():
    """A bike's teardrop tank in petrol red: a lathed shell about X, squashed,
    a chrome filler cap, rubber knee pads, a petcock underneath."""
    m = Model()
    sh = Model()
    prof = [(0.0, -0.17), (0.055, -0.165), (0.08, -0.14), (0.09, -0.08), (0.092, 0.06), (0.08, 0.13), (0.05, 0.165), (0.0, 0.17)]
    lathe(sh, "PetrolRed", prof, segs=36, uv_m=3.0, smooth=True)
    m.merge(sh, np.diag([1.0, 1.05, 1.08]) @ rot_z(-math.pi / 2), (0, 0.003, 0))
    box(m, "Dark", (0, -0.08, 0), (0.30, 0.03, 0.12), uv_m=4.0)                      # the tunnel / mount rail
    along(m, (0.03, 0.09, 0), (0.03, 0.10, 0), 0.032, "Chrome", segs=16)               # filler cap
    along(m, (0.03, 0.10, 0), (0.03, 0.104, 0), 0.024, "Chrome", segs=16)
    for sz in (-1, 1):
        box(m, "Rubber", (-0.07, 0.0, sz * 0.096), (0.11, 0.07, 0.008), uv_m=4.0)
    along(m, (-0.08, -0.09, 0.03), (-0.08, -0.098, 0.03), 0.01, "Chrome", segs=8)       # petcock
    return m


def tank_m():
    """A steel jerry tank stood on a strap cradle: the X pressings on both
    flat sides, three carry handles on top, the spout cap."""
    m = Model()
    hx, hy, hz = 0.17, 0.165, 0.085
    box(m, "Olive", (0, -0.01, 0), (2 * hx - 0.02, 2 * hy - 0.04, 2 * hz - 0.004), uv_m=3.0, bevel=0.012)
    for sz in (-1, 1):
        for a in (1, -1):
            d = Model()
            box(d, "Olive", (0, 0, 0), (0.36, 0.022, 0.006), uv_m=4.0)
            m.merge(d, rot_z(a * math.atan2(0.24, 0.30)), (0, -0.01, sz * (hz + 0.002)))
        box(m, "Olive", (0, -0.01, sz * (hz + 0.002)), (0.30, 0.25, 0.003), uv_m=4.0)
    for x in (-0.09, 0.0, 0.09):
        pipe(m, [(x - 0.02, hy - 0.03, 0), (x - 0.02, hy - 0.005, 0), (x + 0.02, hy - 0.005, 0), (x + 0.02, hy - 0.03, 0)],
             0.006, "Olive", segs=6)
    along(m, (0.12, hy - 0.03, 0), (0.14, hy, 0), 0.025, "Dark", segs=14)               # spout cap
    for x in (-0.11, 0.11):
        box(m, "Dark", (x, -0.01, 0), (0.025, 2 * hy - 0.01, 2 * hz + 0.012), uv_m=5.0)  # straps
    box(m, "Dark", (0, -hy + 0.008, 0), (2 * hx, 0.016, 2 * hz + 0.01), uv_m=4.0)      # cradle
    return m


def gas_can():
    """The 10 L jerry can the crew carries: 0.26 long (Z), 0.12 thick (X),
    0.31 to the top of the handle (+Y up); the spout at the front."""
    m = Model()
    L, T, H = 0.26, 0.12, 0.27
    box(m, "PetrolRed", (0, -0.035, 0), (T, H, L), uv_m=3.0, bevel=0.01)
    for sx in (-1, 1):
        for a in (1, -1):
            d = Model()
            box(d, "PetrolRed", (0, 0, 0), (0.004, 0.018, 0.3), uv_m=4.0)
            m.merge(d, rot_x(a * math.atan2(0.21, 0.22)), (sx * (T / 2 + 0.002), -0.035, 0))
    top = -0.035 + H / 2
    # the handle: a bar on three posts, the hand's grip
    for z in (-0.07, 0.0, 0.07):
        along(m, (0, top - 0.005, z), (0, top + 0.03, z), 0.008, "PetrolRed", segs=8)
    along(m, (0, top + 0.035, -0.08), (0, top + 0.035, 0.08), 0.011, "PetrolRed", segs=10)
    # the spout and its clamp cap at the front corner
    sp = Model()
    along(sp, (0, 0, 0), (0, 0.035, 0), 0.02, "Steel", segs=14)
    along(sp, (0, 0.035, 0), (0, 0.045, 0), 0.026, "Dark", segs=14)
    box(sp, "Steel", (0.0, 0.02, -0.03), (0.012, 0.012, 0.04), uv_m=6.0)                 # the cam lever
    m.merge(sp, rot_x(math.radians(25)), (0, top - 0.005, L / 2 - 0.035))
    # the seam around the middle
    box(m, "Dark", (0, -0.035, 0), (T + 0.004, H - 0.03, 0.006), uv_m=6.0)
    return m


def main():
    dry = "--dry" in sys.argv
    os.makedirs(G.MODELS, exist_ok=True)
    os.makedirs(ITEM_MODELS, exist_ok=True)
    os.makedirs(G.VIS_DIR, exist_ok=True)
    written = []

    def mesh(key, model, folder=None):
        model, c = G.recenter(model)
        G.write_glb(model, os.path.join(folder or G.MODELS, key + ".glb"))
        mn, mx = model.bounds()
        print(f"{key:16s} size {np.round(mx - mn, 3)} offset {np.round(c, 3)} tris {model.tris()}")
        return model, c

    for pid, spec in ENGINES.items():
        m = engine(spec)
        half = (spec["hx"], spec["hy"], spec["hz"])
        clip_check(pid, m, half)
        if dry:
            print(pid, "bounds", np.round(m.bounds()[0], 3), np.round(m.bounds()[1], 3))
            continue
        key = f"gas_engine_{spec['cc']}"
        em, ec = mesh(key, m)
        G.write_prefab(spec["prefab"], f"GAS ENGINE {spec['cc']}cc — a single with its gearbox (X forward, the gearbox"
                       " sprocket on the left −Z, the exhaust on the right); a Drive Chain from its sprocket powers a wheel"
                       " (scripts/parts_auto.lua, auto_drive §5).", None, half, spec["mass"],
                       children=[("Engine", key, em, ec)])
        written.append(spec["prefab"])

    for pid, fn, prefab, half, mass, about in (
            ("gasTankS", tank_s, "PartGasTankS", (0.17, 0.10, 0.10), 0.0055, "GAS TANK 4 L — a bike's petrol tank; X forward, the filler on top."),
            ("gasTankM", tank_m, "PartGasTankM", (0.18, 0.17, 0.09), 0.014, "GAS TANK 12 L — a steel jerry tank in a strap cradle.")):
        m = fn()
        clip_check(pid, m, half, allow_z=0.0)
        if dry:
            continue
        key = "gas_tank_s" if pid == "gasTankS" else "gas_tank_m"
        tm, tc = mesh(key, m)
        G.write_prefab(prefab, about, None, half, mass, children=[("Tank", key, tm, tc)])
        written.append(prefab)

    if not dry:
        # THE DRIVE CHAIN: one prefab for every length; builder_proc dresses it
        # (its mesh, a token collider) from the part's size, as the Brace
        with open(os.path.join(G.PREFABS, "PartChain.prefab.ron"), "w") as f:
            f.write("""// DRIVE CHAIN — a roller chain from a gas engine's sprocket to a wheel's hub (size: len, e, w, teeth,
// front); meshed by scripts/builder_proc.lua chainArrays. Written by tools/gen_gas_parts.py.
[
    (
        name: "PartChain",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
""" + G.rb_ron((0.01, 0.01, 0.01), 0.0016) + """    ),
]
""")
        written.append("PartChain")
        # vis/ copies for the builder stand
        for prefab in written:
            src = open(os.path.join(G.PREFABS, prefab + ".prefab.ron")).read()
            vis = G.strip_scripts(G.strip_block(src, "rigidbody: Some(("))
            head_ = ("// VISUAL-ONLY variant of prefabs/" + prefab + ".prefab.ron for the builder stand: no body,"
                     " no scripts.\n// Written by tools/gen_gas_parts.py — regenerate, don't edit.\n")
            open(os.path.join(G.VIS_DIR, prefab + ".prefab.ron"), "w").write(head_ + vis)
        # THE GAS CAN (the hand's prop: its mesh is the root, centred)
        cm, cc = mesh("gas_can", gas_can(), ITEM_MODELS)
        mats = ",\n".join(f'            "{n}": {G.MATERIALS[n]()}' for n in sorted(cm.parts.keys()))
        mats = mats.replace('                shader: Some("shaders/hullPanels.flsl"),\n', "")
        import re
        mats = re.sub(r'                shader_params: \{\n[^}]*\},\n', "", mats)
        with open(os.path.join(G.PREFABS, "ItemGasCan.prefab.ron"), "w") as f:
            f.write(f"""// GAS CAN — a 10 L steel jerry can of petrol, carried by its handle (scripts/item_hand.lua); poured into a
// craft's gas tanks, filled at the Repair Bay's pump. Written by tools/gen_gas_parts.py.
[
    (
        name: "ItemGasCan",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/gas_can.glb",
        ),
        object_materials: {{
{mats},
        }},
        scripts: [],
    ),
]
""")
        print("prefabs:", ", ".join(written + ["ItemGasCan"]))


if __name__ == "__main__":
    main()
