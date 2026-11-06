#!/usr/bin/env python3
"""The ROPE KIT: an edge davit with its pulley, the kit as carried, and the
static line's own texture (scripts/rope.lua, scripts/rope_climb.lua).

    python3 tools/gen_rope.py

Models (models/items/):
    rope_pylon.glb   a galvanised edge davit, painted safety yellow: a base
                     plate on four rock bolts, a 1.3 m mast braced by two
                     back stays to ground stakes, a boom cantilevered 0.8 m
                     out with a sheave (pulley wheel) in cheek plates at its
                     tip, and a brake drum on the mast holding the spare line.
                     The line runs from the drum up over the sheave; the
                     hanging rope itself is built at runtime (scripts/rope.lua,
                     mesh.build) from where it fell.
    rope_kit.glb     the kit as carried: a canvas rope bag with the line's end
                     and its figure-eight out of the top, the davit's mast and
                     boom collapsed and strapped along its side. Along +Y, for
                     the over-the-shoulder carry (item_hand grip "shoulder").

Textures (textures/items/):
    rope_static_albedo.png, rope_static_normal.png (rope_static_orm / _height:
                     tools/detail_maps.py, from the same braid)
                     a kernmantle sheath: 32 carriers braided two over two,
                     cream with one black tracer pair, grimed. Tiles: u once
                     round the rope, v once every ROPE_V_M metres of length.

Prefabs (prefabs/):
    RopePylon        the planted davit (deployables kind "rope"): an Empty root
                     ORIGIN above the ground point, with a static box for the
                     context menu and a body to bump into, scripts/rope.lua,
                     and the mesh as a child (the engine recentres a model on
                     its box, so the child sits at the box centre)
    RopePylonGhost, RopePylonGhostBad   the deploy mode's previews
    ItemRopeKit      the kit in hand (over the shoulder)
    RopeLib          scripts/rope_climb.lua's node: the climbing itself

The davit's frame: +Y up, -Z out over the drop (deployables plants a node
with setUp(up, away from the planter), so its -Z faces the edge), ground at
y = 0 in the model; the root node sits ORIGIN above it. The rope leaves the
sheave at DROP = (0, DROP_Y, -DROP_OUT) — scripts/rope_climb.lua ROPE.drop_y /
drop_out must match what this prints.
"""
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import PREFABS, ROOT, TAU, Model, box, disk, frame_to, lathe, mat_ron, tube, write_glb  # noqa: E402

MODELS = os.path.join(ROOT, "models", "items")
TEXDIR = os.path.join(ROOT, "textures", "items")

ORIGIN = 0.75          # the root node above the ground point (deployables KINDS.rope.origin)
MAST_TOP = 1.30
BOOM_TIP = (0.0, 1.42, -0.82)   # the sheave's axle
SHEAVE_R = 0.065
DROP_Y = BOOM_TIP[1]
DROP_OUT = -BOOM_TIP[2] + SHEAVE_R
ROPE_R = 0.0055        # 11 mm static line (the runtime rope uses ROPE.radius)
ROPE_V_M = 0.12        # metres of rope per texture repeat along it
KIT_GRIP = (-0.045, 0.320, 0.0)   # the top of the kit's grab handle (its raw frame)

ROPE_MAT = ('(\n                color: (1.0, 1.0, 1.0),\n'
            '                texture: Some("textures/items/rope_static_albedo.png"),\n'
            '                normal_map: Some("textures/items/rope_static_normal.png"),\n'
            '                normal_strength: 1.0,\n'
            '                roughness_map: Some("textures/items/rope_static_orm.png"),\n'
            '                roughness: 1.0,\n                metallic: 0.0,\n'
            '                metallic_map: Some("textures/items/rope_static_orm.png"),\n'
            '                ao_map: Some("textures/items/rope_static_orm.png"),\n'
            '                shading: Physical,\n            )')
MATS = {
    # safety-yellow davit paint, chipped (the hand tools' worn enamel)
    "Davit":   lambda: mat_ron("paint", color=(0.93, 0.70, 0.13), hull=False),
    # hot-dip galvanised steel: the stays, plate and cheek plates
    "Galv":    lambda: mat_ron("metal", color=(0.70, 0.71, 0.70), rough=1.1, metal=0.55, hull=False),
    "Dark":    lambda: mat_ron("metal", color=(0.16, 0.16, 0.17), rough=1.3, metal=0.3, hull=False),
    "Chrome":  lambda: mat_ron("metal", color=(1.0, 1.0, 1.0), rough=0.4, metal=0.85, hull=False),
    "Rubber":  lambda: mat_ron("rubber", metal=0.0, hull=False),
    "Canvas":  lambda: mat_ron("rubber", color=(0.40, 0.39, 0.29), metal=0.0, hull=False),
    "Webbing": lambda: mat_ron("rubber", color=(0.24, 0.25, 0.20), metal=0.0, hull=False),
    "Rope":    lambda: ROPE_MAT,
}


# ── a rope swept along a path (UV v along its length, u round it) ──────────
def sweep(m, mat, pts, r, sides=8, v_m=ROPE_V_M, caps=True):
    pts = [np.asarray(p, float) for p in pts]
    n = len(pts)
    T = []
    for i in range(n):
        a = pts[max(0, i - 1)]
        b = pts[min(n - 1, i + 1)]
        t = b - a
        T.append(t / (np.linalg.norm(t) or 1.0))
    # a rotation-minimising frame
    ref = np.array([0.0, 1.0, 0.0]) if abs(T[0][1]) < 0.9 else np.array([1.0, 0.0, 0.0])
    nrm = np.cross(T[0], ref); nrm /= np.linalg.norm(nrm)
    P, N, UV, I = [], [], [], []
    s = 0.0
    for i in range(n):
        if i > 0:
            s += float(np.linalg.norm(pts[i] - pts[i - 1]))
            nrm = nrm - T[i] * float(nrm @ T[i])
            nrm /= (np.linalg.norm(nrm) or 1.0)
        bi = np.cross(T[i], nrm)
        for k in range(sides + 1):
            a = TAU * k / sides
            d = nrm * math.cos(a) + bi * math.sin(a)
            P.append(pts[i] + d * r); N.append(d); UV.append((k / sides, s / v_m))
    for i in range(n - 1):
        for k in range(sides):
            a0 = i * (sides + 1) + k
            b0 = (i + 1) * (sides + 1) + k
            I.append((a0, b0, b0 + 1)); I.append((a0, b0 + 1, a0 + 1))
    m.add(mat, P, N, UV, I)
    if caps:
        for end, sg in ((0, -1.0), (n - 1, 1.0)):
            c = pts[end]
            t = T[end] * sg
            base = len(P)
            sub_P, sub_N, sub_UV, sub_I = [c], [t], [(0.5, 0.5)], []
            nn = np.cross(t, ref if abs(t[1]) < 0.9 else np.array([1.0, 0.0, 0.0])); nn /= np.linalg.norm(nn)
            bb = np.cross(t, nn)
            for k in range(sides + 1):
                a = TAU * k / sides
                sub_P.append(c + (nn * math.cos(a) + bb * math.sin(a)) * r); sub_N.append(t)
                sub_UV.append((0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a)))
            for k in range(sides):
                sub_I.append((0, 1 + k, 2 + k))
            m.add(mat, sub_P, sub_N, sub_UV, sub_I)
            del base


def wheel(m, mat, centre, r, w, axis="x", segs=20, groove=0.012):
    """A sheave: a grooved disc about an axis through `centre`."""
    sub = Model()
    prof = [(0.008, -w / 2), (r, -w / 2), (r, -w / 2 + 0.006), (r - groove, 0.0), (r, w / 2 - 0.006), (r, w / 2),
            (0.008, w / 2)]
    lathe(sub, mat, prof, segs=segs, uv_m=8.0)
    disk(sub, mat, r, -w / 2, segs=segs, up=False)
    disk(sub, mat, r, w / 2, segs=segs, up=True)
    M = frame_to((1, 0, 0) if axis == "x" else (0, 0, 1))
    m.merge(sub, M, centre)


# ── the planted davit ───────────────────────────────────────────────────────
def pylon_model():
    m = Model()
    # base plate on four rock bolts
    box(m, "Galv", (0, 0.0125, 0), (0.34, 0.025, 0.34), uv_m=3.0)
    for sx in (-1, 1):
        for sz in (-1, 1):
            tube(m, "Chrome", (sx * 0.13, 0.02, sz * 0.13), (sx * 0.13, 0.05, sz * 0.13), 0.011, segs=6)
            tube(m, "Dark", (sx * 0.13, 0.025, sz * 0.13), (sx * 0.13, 0.034, sz * 0.13), 0.019, segs=6)
    # the mast, a socket collar at its foot, a cap at its head
    tube(m, "Dark", (0, 0.025, 0), (0, 0.16, 0), 0.045, segs=14)
    tube(m, "Davit", (0, 0.16, 0), (0, MAST_TOP, 0), 0.034, segs=14, uv_m=3.0)
    tube(m, "Dark", (0, MAST_TOP - 0.10, 0), (0, MAST_TOP + 0.02, 0), 0.042, segs=14)
    # the boom out over the drop, its brace, and an adjust pin
    boom0 = np.array((0.0, MAST_TOP - 0.06, 0.0))
    tip = np.array(BOOM_TIP)
    d = tip - boom0; d /= np.linalg.norm(d)
    tube(m, "Davit", boom0, tip - d * 0.05, 0.028, segs=12, uv_m=3.0)
    tube(m, "Davit", (0, 0.82, -0.02), boom0 + (tip - boom0) * 0.55, 0.015, segs=10)
    tube(m, "Chrome", (-0.05, MAST_TOP - 0.05, 0), (0.05, MAST_TOP - 0.05, 0), 0.008, segs=8)
    # the sheave in its cheek plates
    for sx in (-1, 1):
        box(m, "Galv", (sx * 0.024, tip[1] + 0.005, tip[2] + 0.035), (0.006, 0.10, 0.12), uv_m=4.0)
    wheel(m, "Dark", tuple(tip), SHEAVE_R, 0.032)
    tube(m, "Chrome", (-0.034, tip[1], tip[2]), (0.034, tip[1], tip[2]), 0.009, segs=8)
    # back stays to staked feet
    head = np.array((0.0, 1.02, 0.0))
    for sx in (-1, 1):
        foot = np.array((sx * 0.42, 0.012, 0.52))
        tube(m, "Galv", head, foot, 0.017, segs=10, uv_m=3.0)
        box(m, "Galv", tuple(foot + (0, 0.005, 0)), (0.10, 0.012, 0.10), uv_m=4.0)
        tube(m, "Chrome", tuple(foot + (0, 0.0, 0)), tuple(foot + (0, 0.07, 0)), 0.010, segs=6)
        tube(m, "Dark", tuple(foot + (0, 0.06, 0)), tuple(foot + (0, 0.085, 0)), 0.018, segs=8)
    tube(m, "Dark", (0, 1.0, -0.03), (0, 1.07, -0.03), 0.045, segs=12)   # the stays' clamp
    # the brake drum with the spare line on it, and its crank
    drum_c = np.array((0.0, 0.55, -0.075))
    wheel(m, "Galv", tuple(drum_c), 0.075, 0.13, segs=18, groove=0.0)
    for k in range(5):
        x = -0.045 + k * 0.0225
        ring = [(x + 0.004 * math.sin(a), drum_c[1] + 0.058 * math.cos(a), drum_c[2] + 0.058 * math.sin(a))
                for a in np.linspace(0, TAU, 17)]
        sweep(m, "Rope", ring, ROPE_R * 1.1, sides=6, caps=False)
    box(m, "Galv", (0, 0.55, -0.035), (0.14, 0.16, 0.02), uv_m=4.0)   # the drum's bracket
    tube(m, "Galv", (0.075, 0.55, -0.075), (0.11, 0.55, -0.075), 0.007, segs=6)
    tube(m, "Galv", (0.11, 0.55, -0.075), (0.11, 0.47, -0.075), 0.006, segs=6)
    tube(m, "Rubber", (0.11, 0.47, -0.075), (0.15, 0.47, -0.075), 0.011, segs=8)
    # the line: off the top of the drum, up past the boom, over the sheave
    top = (0.0, tip[1] + SHEAVE_R - 0.009, tip[2])
    run = [(0.0, drum_c[1] + 0.06, drum_c[2] - 0.02), (0.0, 0.95, -0.12), (0.0, 1.30, -0.62), top]
    arc = [(0.0, tip[1] + (SHEAVE_R - 0.009) * math.cos(a), tip[2] - (SHEAVE_R - 0.009) * math.sin(a))
           for a in np.linspace(0, math.pi / 2, 7)]
    sweep(m, "Rope", run + arc[1:], ROPE_R, sides=8)
    return m


# ── the kit as carried ──────────────────────────────────────────────────────
def kit_model():
    m = Model()
    # the rope bag: heavy canvas, a little bulged, a drawstring collar
    prof = [(0.0, -0.30), (0.11, -0.30), (0.125, -0.27), (0.132, -0.10), (0.130, 0.12), (0.120, 0.22),
            (0.105, 0.25)]
    lathe(m, "Canvas", prof, segs=20, uv_m=4.0, smooth=True)
    lathe(m, "Webbing", [(0.106, 0.245), (0.112, 0.26), (0.098, 0.275)], segs=20, uv_m=6.0, smooth=True)
    disk(m, "Rubber", 0.11, -0.302, segs=20, up=False)
    disk(m, "Canvas", 0.106, 0.235, segs=20, up=True)   # the drawn-shut mouth
    # a webbing grab handle across the mouth (the first-person carry's hold:
    # tools/gen_fp_items.py, KIT_GRIP)
    handle = [(KIT_GRIP[0], 0.245 + 0.075 * math.sin(a), 0.075 * math.cos(a)) for a in np.linspace(0, math.pi, 13)]
    sweep(m, "Webbing", handle, 0.008, sides=6)
    # the line's end out of the top, in a figure-eight on a bight
    end = [(0.0, 0.26, 0.0), (0.02, 0.31, 0.01), (0.05, 0.34, 0.02), (0.07, 0.36, 0.0), (0.06, 0.39, -0.03),
           (0.03, 0.38, -0.04), (0.035, 0.35, -0.01), (0.06, 0.33, 0.02), (0.08, 0.35, 0.03), (0.07, 0.40, 0.01)]
    sweep(m, "Rope", end, ROPE_R * 1.3, sides=8)
    # a coil of spare line cinched under the lid
    for k in range(3):
        y = 0.20 - k * 0.012
        ring = [(0.128 * math.cos(a), y + 0.004 * math.sin(3 * a), 0.128 * math.sin(a)) for a in np.linspace(0, TAU, 25)]
        sweep(m, "Rope", ring, ROPE_R * 1.2, sides=6, caps=False)
    # the collapsed davit strapped along one side: mast and boom tubes
    for dz, r, mat in ((0.0, 0.034, "Davit"), (0.06, 0.028, "Davit")):
        tube(m, mat, (0.155, -0.36, dz), (0.155, 0.40, dz), r, segs=12, uv_m=3.0)
        tube(m, "Dark", (0.155, 0.40, dz), (0.155, 0.43, dz), r * 1.2, segs=12)
    wheel(m, "Dark", (0.155, 0.46, 0.06), SHEAVE_R, 0.032, axis="x")
    for sx in (-1, 1):
        box(m, "Galv", (0.155 + sx * 0.024, 0.465, 0.075), (0.006, 0.10, 0.12), uv_m=4.0)
    # two webbing straps round bag and tubes, with cam buckles
    for y in (-0.16, 0.10):
        ring = [(0.135 * math.cos(a) + (0.06 if math.cos(a) > 0.5 else 0.0) * math.cos(a), y,
                 0.135 * math.sin(a) + (0.03 if math.cos(a) > 0.5 else 0.0)) for a in np.linspace(0, TAU, 33)]
        sweep(m, "Webbing", ring, 0.012, sides=4, caps=False)
        box(m, "Chrome", (-0.14, y, 0.0), (0.012, 0.04, 0.05), uv_m=6.0)
    # stakes in a side pocket
    for k in range(3):
        tube(m, "Chrome", (-0.06 + k * 0.03, -0.20, -0.13), (-0.06 + k * 0.03, 0.08, -0.13), 0.007, segs=6)
    box(m, "Canvas", (-0.03, -0.12, -0.13), (0.12, 0.16, 0.02), uv_m=4.0)
    return m


def centred(m):
    mn, mx = m.bounds()
    c = (mn + mx) / 2
    out = Model()
    out.merge(m, None, -c)
    return out, c, mx - mn


# ── the static line's texture ───────────────────────────────────────────────
def _braid(W=64, H=256, carriers=16, turns=4):
    """A kernmantle sheath: `carriers` strands each way round the rope, each
    making `turns` turns per texture height, two over two under (a 2/2 twill
    braid). Returns the height (0..1, a strand's crown 1), the strand ids, the
    over mask, ia and ib (the strand indices each way)."""
    y, x = np.mgrid[0:H, 0:W].astype(float)
    u, v = x / W, y / H
    a = (u * carriers + v * carriers * turns / 2.0)      # strands winding one way
    b = (u * carriers - v * carriers * turns / 2.0)      # and the other
    ia, ib = np.floor(a), np.floor(b)
    fa, fb = a - ia, b - ib
    over = ((np.floor(ia / 1) + np.floor(ib / 2)) % 2 == 0)
    # each strand's round cross-section, and the strand on top shows
    ha = np.sin(fa * math.pi)
    hb = np.sin(fb * math.pi)
    h = np.where(over, ha * 0.8 + 0.2, hb * 0.8 + 0.2)
    strand = np.where(over, ia, ib + 1000)
    # fibre streaks along each strand
    streak = np.where(over, np.sin(fb * math.pi * 14 + ia), np.sin(fa * math.pi * 14 + ib)) * 0.06
    h = np.clip(h + streak, 0, 1)
    return h, strand, over, ia, ib


def rope_height(W=64, H=256, carriers=16, turns=4):
    """The braid's height (0..1) and its tracer mask, for tools/detail_maps.py (the rope's ORM
    and height come from the same braid as its albedo and normal)."""
    h, strand, over, ia, ib = _braid(W, H, carriers, turns)
    is_tracer = over & ((ia % carriers) == 3) | over & ((ia % carriers) == 11)
    return h, is_tracer


def rope_textures(W=64, H=256, carriers=16, turns=4):
    """The sheath's albedo and normal (tools/detail_maps.py adds its ORM and height)."""
    rng = np.random.default_rng(7)
    h, strand, over, ia, ib = _braid(W, H, carriers, turns)
    # colour: cream sheath, one black tracer pair winding one way
    base = np.array([0.80, 0.76, 0.66])
    tracer = np.array([0.10, 0.10, 0.11])
    col = np.ones((H, W, 3)) * base
    is_tracer = over & ((ia % carriers) == 3) | over & ((ia % carriers) == 11)
    col[is_tracer] = tracer
    # per-strand shade jitter and grime in the valleys
    jit = (np.sin(strand * 12.9898) * 43758.5453) % 1.0
    col *= (0.92 + 0.10 * jit)[..., None]
    grime = 0.55 + 0.45 * h
    dirt = rng.random((H // 16, W // 8))
    dirt = np.kron(dirt, np.ones((16, 8)))
    col *= (grime * (0.86 + 0.14 * dirt))[..., None]
    col = col * np.array([1.0, 0.97, 0.92])   # dust-brown cast
    alb = (np.clip(col, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
    # normal from the height (tileable gradients)
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 2.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 2.5
    n = np.dstack([-dx, dy, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    nrm = ((n * 0.5 + 0.5) * 255).astype(np.uint8)
    os.makedirs(TEXDIR, exist_ok=True)
    Image.fromarray(alb, "RGB").save(os.path.join(TEXDIR, "rope_static_albedo.png"))
    Image.fromarray(nrm, "RGB").save(os.path.join(TEXDIR, "rope_static_normal.png"))


# ── prefabs ─────────────────────────────────────────────────────────────────
HEAD = "// Written by tools/gen_rope.py — edit the generator, not this file.\n"


def mats_block(model, indent="            "):
    return ",\n".join(f'{indent}"{n}": {MATS[n]()}' for n in sorted(model.parts.keys()))


def pylon_prefab(model, c):
    cx, cy, cz = c
    return f'''// ROPE PYLON — a Rope Kit's edge davit, planted (scripts/deployables.lua kind
// "rope" spawns one per planted kit, parented to its planet, ORIGIN {ORIGIN} m above
// the ground point, -Z out over the drop). scripts/rope.lua hangs the line
// from its sheave; scripts/rope_climb.lua climbs it.
{HEAD}[
    (
        name: "RopePylon",
        tags: ["rope", "deployable"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [
            (
                kind: "rope",
                enabled: true,
                params: [],
            ),
        ],
        rigidbody: Some((
            boxed: true,
            mode: Static,
            radius: 0.3,
            height: {2 * ORIGIN:.3f},
            half_extents: (0.42, {ORIGIN:.3f}, 0.58),
            restitution: 0.05,
            friction: 0.8,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.02,
        )),
    ),
    (
        name: "Rope Pylon Mesh",
        transform: (
            translation: ({cx:.4f}, {cy - ORIGIN:.4f}, {cz:.4f}),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/rope_pylon.glb",
        ),
        object_materials: {{
{mats_block(model)},
        }},
        scripts: [],
        parent: Some(0),
    ),
]
'''


def ghost_prefab(name, rgb, c, about):
    r, g, b = rgb
    cx, cy, cz = c
    return f'''// {about}
{HEAD}[
    (
        name: "{name}",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [],
    ),
    (
        name: "{name} Mesh",
        transform: (
            translation: ({cx:.4f}, {cy - ORIGIN:.4f}, {cz:.4f}),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/rope_pylon.glb",
        ),
        material: Some((
            color: ({r}, {g}, {b}),
            emissive: ({r}, {g}, {b}),
            emissive_strength: 0.8,
            unlit: true,
            alpha: 0.5,
        )),
        scripts: [],
        parent: Some(0),
    ),
]
'''


def kit_prefab(model):
    return f'''// ROPE KIT — 30 m of static line in its bag, the edge davit collapsed and
// strapped along its side, carried over the shoulder (scripts/item_hand.lua).
{HEAD}[
    (
        name: "ItemRopeKit",
        tags: ["item"],
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Mesh(
            asset_path: "models/items/rope_kit.glb",
        ),
        object_materials: {{
{mats_block(model)},
        }},
        scripts: [],
    ),
]
'''


LIB = f'''// ROPE LIBRARY — scripts/rope_climb.lua: clipping on to a Rope Kit's line,
// climbing it, the prompts, and the lines' layouts. Spawned by the first rope
// pylon in a scene that has none; reached with findScript("rope_climb").
{HEAD}[
    (
        name: "RopeLib",
        transform: (
            translation: (0.0, 0.0, 0.0),
            rotation: (0.0, 0.0, 0.0, 1.0),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: Empty,
        scripts: [
            (
                kind: "rope_climb",
                enabled: true,
                params: [],
            ),
        ],
    ),
]
'''


def main():
    os.makedirs(MODELS, exist_ok=True)
    rope_textures()
    pm, pc, psize = centred(pylon_model())
    write_glb(pm, os.path.join(MODELS, "rope_pylon.glb"))
    km, kc, ksize = centred(kit_model())
    write_glb(km, os.path.join(MODELS, "rope_kit.glb"))
    files = {
        "RopePylon": pylon_prefab(pm, pc),
        "RopePylonGhost": ghost_prefab("RopePylonGhost", (0.30, 0.95, 0.80), pc,
                                       "ROPE PYLON GHOST — the placement preview where it can stand (scripts/item_hand.lua)."),
        "RopePylonGhostBad": ghost_prefab("RopePylonGhostBad", (1.0, 0.38, 0.30), pc,
                                          "ROPE PYLON GHOST, red — the placement preview where it can't (scripts/item_hand.lua)."),
        "ItemRopeKit": kit_prefab(km),
        "RopeLib": LIB,
    }
    for name, text in files.items():
        with open(os.path.join(PREFABS, name + ".prefab.ron"), "w") as f:
            f.write(text)
    print(f"rope_pylon  size {np.round(psize, 3).tolist()} centre {np.round(pc, 4).tolist()} tris {pm.tris()}")
    print(f"rope_kit    size {np.round(ksize, 3).tolist()} centre {np.round(kc, 4).tolist()} tris {km.tris()}")
    print(f"ROPE.origin {ORIGIN}  drop_y {DROP_Y:.4f}  drop_out {DROP_OUT:.4f}  (scripts/rope_climb.lua)")


if __name__ == "__main__":
    main()
