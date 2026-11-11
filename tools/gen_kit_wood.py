#!/usr/bin/env python3
"""The kit's TIMBER: wood as a material on the existing pieces, and the TIMBER section's own pieces
(progression W1; scripts/parts_kit.lua TIMBER, work/progression/PLAN.md §3; docs/base-building.md §35).

Not run on its own: tools/gen_kit_parts.py calls `install(K)` once its PIECES table is built. That
adds "wood" to the pieces parts_kit gives it (their steel builder is untouched: a timber piece is its
own builder here, the colliders are the existing piece's, so a timber floor walks and snaps exactly
like a steel one) and the twelve TIMBER pieces. To write only these:

    python3 tools/gen_kit_parts.py post3 deck24 ...    (the fixture is written by a full run only)

THE LOOK (Ty: gritty and real, no shiny CG wood). Every board is its own box with its grain along its
length (the box's local X: `board`), a random offset into the CC0 Wood062 set (ambientCG, in git:
textures/env/sets/Wood062) and its own tint, so no two boards repeat; gaps of 4-8 mm between boards
show the dark behind them. Round posts are peeled logs in Bark016 (CC0, in git) with sawn end grain.
Iron is black (strap hinges, bolts, nails, post bases). Grime by height like the kit's steel. The
material is rough (the set's own roughness map, metallic 0): wood never shines.

Z-FIGHTING: the members of one frame are each at their own depth (plates ±0.066, studs ±0.063, jambs
±0.060, headers ±0.057) so where they overlap no two faces share a plane; claddings stand 3 mm clear
of the frame; a lap board is tilted 3.4° so its face is never in a neighbour's plane; trim stands
proud. tools zall (work/prog_w1/zall_w.py) must stay at 0 for every timber prefab.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import box, lathe, disk, rot_x  # noqa: E402
import base_models as BM  # noqa: E402

# wood weathers by height like the kit's paint (splash, damp at the foot)
BM.GRIMED.add("Timber")
BM.GRIMED.add("LogBark")

TEX = "textures/env/sets/"
UVW = 0.9                         # Wood062's tile is ~1.1 m of board
IRON = (0.11, 0.105, 0.10)        # black iron: straps, bolts, nails
GALV = (0.40, 0.41, 0.40)         # galvanised post bases and plates
BARK = (0.78, 0.66, 0.54)         # the mossy bark set browned toward a dry pine log
WT, WH = 0.2, 2.2


REFL = 0.3      # (wood reflects little sky: at 1.0 a rough dark board read as blue-grey concrete outdoors)


def _set(name, normal=1.0, albedo=None, prefix=None):
    t = prefix or (TEX + name + "/")
    return ('(\n                color: (1.0, 1.0, 1.0),\n'
            f'                texture: Some("{albedo or (t + "albedo.png")}"),\n'
            f'                normal_map: Some("{t}normal.png"),\n'
            f'                normal_strength: {normal},\n'
            f'                roughness_map: Some("{t}orm.png"),\n'
            '                roughness: 1.0,\n'
            '                metallic: 0.0,\n'
            f'                ao_map: Some("{t}orm.png"),\n'
            f'                reflectivity: {REFL},\n'
            '                shading: Physical,\n            )')


# (the boards' colour: Wood062's albedo warmed and lifted toward sawn, weathered softwood —
# textures/kit/timber_albedo.png, made by timber_albedo() from the CC0 set, so CC0 too)
TIMBER_ALBEDO = "textures/kit/timber_albedo.png"
# (W2: the boards wear the strip atlas below, timber_board(); W1's TIMBER_ALBEDO is kept for its maker)
MATERIALS = {"Timber": lambda: _set("Wood062", 0.9, prefix="textures/kit/timber_board_"), "LogBark": lambda: _set("Bark016", 1.2)}


def timber_albedo():
    """Wood062's albedo, its linear mean moved from (0.13, 0.09, 0.07) to a weathered pine's
    (0.27, 0.18, 0.11): the grain kept, the colour warmer and a little lighter."""
    from PIL import Image
    src = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), TEX, "Wood062", "albedo.png")
    a = np.asarray(Image.open(src).convert("RGB"), np.float64) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    mean = lin.reshape(-1, 3).mean(0)
    lin = np.clip(lin * (np.array([0.27, 0.18, 0.11]) / mean), 0, 1)
    s = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), TIMBER_ALBEDO)
    Image.fromarray((np.clip(s, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out)
    return out

# (W2, Ty 11-11: "the hut reads as grey stone at a distance") THE BOARD SET: a strip atlas, four
# boards of Wood062 one above the other, each 128 px across its width (a board's width maps to its
# strip whatever it is: 0.1-0.3 m), the grain along U at Wood062's own scale. Each strip is the set
# weathered toward a grey-brown softwood (pores softened along the grain and the figure's contrast
# taken to 0.6, the colour warm and a little silvered, one strip greyer, one warmer) with its EDGES dark in albedo and AO (the gap, the
# lap's shadow, the dirt in the joint) and a rounded arris in the normal map: the board lines then
# read at 20-60 m, where Wood062's fine grain has long since gone to its mean. Rougher than the set
# (0.84 mean, 0.95 at the edges): weathered wood never shines. Made by timber_board() from the CC0
# set, so CC0 too. _shift_uv() puts every Timber block's faces into one strip each.
BOARD = "textures/kit/timber_board_"
STRIPS = 4
# linear albedo each strip is moved to (weathered pine: grey-brown, one greyer, one warmer; warm enough
# that a wall in the shade, lit by a blue sky alone, still reads as wood and not slate)
STRIP_MEAN = [(0.310, 0.228, 0.140), (0.280, 0.218, 0.150), (0.330, 0.235, 0.128), (0.262, 0.196, 0.124)]


def timber_board():
    """textures/kit/timber_board_{albedo,normal,orm}.png from textures/env/sets/Wood062 (CC0)."""
    from PIL import Image
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = os.path.join(root, TEX, "Wood062")
    alb = np.asarray(Image.open(os.path.join(src, "albedo.png")).convert("RGB"), np.float64) / 255.0
    nrm = np.asarray(Image.open(os.path.join(src, "normal.png")).convert("RGB"), np.float64) / 255.0
    orm = np.asarray(Image.open(os.path.join(src, "orm.png")).convert("RGB"), np.float64) / 255.0
    lin = np.where(alb <= 0.04045, alb / 12.92, ((alb + 0.055) / 1.055) ** 2.4)
    W = alb.shape[1]
    H = 128                                   # px per strip
    rows = int(round(0.2 * UVW * alb.shape[0]))   # a 0.2 m board's worth of the set's rows (~92)
    rng = np.random.default_rng(6206)
    out_a = np.zeros((H * STRIPS, W, 3))
    out_n = np.zeros((H * STRIPS, W, 3))
    out_o = np.zeros((H * STRIPS, W, 3))
    v = (np.arange(H) + 0.5) / H              # across the board, 0..1
    e = np.minimum(v, 1 - v) * H              # px from the nearer edge
    # (v 0 is a board's top on a wall — box() runs v down the face — and the lap above shades a
    # broad band there; its foot is a thin dark line under a lit arris. A deck plank or a stud
    # shows the same: a shadowed side and a crisp one, which reads as a gap either way.)
    top, foot = v * H, (1 - v) * H
    edge_dark = (1.0 - 0.62 * np.exp(-top / 18.0) - 0.22 * np.exp(-top / 3.0)) * (1.0 - 0.70 * np.exp(-foot / 4.0))
    edge_dark = edge_dark * (1.0 + 0.10 * np.exp(-((foot - 9.0) / 4.0) ** 2))
    edge_ao = (1.0 - 0.55 * np.exp(-top / 12.0)) * (1.0 - 0.65 * np.exp(-foot / 3.0))
    bevel = np.exp(-e / 3.0) * np.where(v < 0.5, 1.0, -1.0)    # the arris: the normal leans out over each edge

    def along_blur(img, r):
        k = np.ones(2 * r + 1) / (2 * r + 1)
        pad = np.concatenate([img[:, -r:], img, img[:, :r]], axis=1)
        o = np.zeros_like(img)
        for c in range(img.shape[2]):
            for i in range(img.shape[0]):
                o[i, :, c] = np.convolve(pad[i, :, c], k, mode="valid")
        return o
    for k in range(STRIPS):
        y0 = int(rng.integers(0, alb.shape[0] - rows))
        idx = np.clip(y0 + (np.arange(H) + 0.5) * rows / H, 0, alb.shape[0] - 1).astype(int)
        shift = int(rng.integers(0, W))
        L = np.roll(lin[idx], shift, axis=1)
        N = np.roll(nrm[idx], shift, axis=1)
        O = np.roll(orm[idx], shift, axis=1)
        # (the pores softened along the grain: weathered wood's raised grain, not walnut's speckle)
        L = 0.45 * L + 0.55 * along_blur(L, 8)
        # (the grain's contrast taken down to 0.6: at 5-20 m the board lines, not the figure, should read)
        mu = L.reshape(-1, 3).mean(0)
        L = mu + (L - mu) * 0.6
        lum = L.mean(axis=2, keepdims=True)
        L = 0.78 * L + 0.22 * lum                # a little silvered
        L = L * (np.array(STRIP_MEAN[k]) / L.reshape(-1, 3).mean(0))
        L = L * edge_dark[:, None, None]
        out_a[k * H:(k + 1) * H] = np.clip(L, 0, 1)
        # normal: the set's, a little softer, and the arris
        t = (N * 2 - 1)
        t[..., 0:2] *= 0.45      # (the grain's bumps soft: at 5-20 m they only sparkle)
        t[..., 1] += 0.7 * bevel[:, None]
        t /= np.linalg.norm(t, axis=2, keepdims=True)
        out_n[k * H:(k + 1) * H] = t * 0.5 + 0.5
        ao = np.clip(O[..., 0] * edge_ao[:, None], 0, 1)
        rough = np.clip(0.30 + 0.80 * O[..., 1], 0, 1)
        rough = rough + (0.95 - rough) * np.exp(-e / 6.0)[:, None]
        out_o[k * H:(k + 1) * H] = np.stack([ao, rough, np.zeros_like(ao)], axis=2)
    srgb = np.where(out_a <= 0.0031308, out_a * 12.92, 1.055 * out_a ** (1 / 2.4) - 0.055)
    for name, img in (("albedo", srgb), ("normal", out_n), ("orm", out_o)):
        Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(root, BOARD + name + ".png"))
    return BOARD


K = None    # gen_kit_parts, set by install()


# ── boards ───────────────────────────────────────────────────────────────────

def tint(m, k=1.0):
    """A board's own colour: sawn softwood varies board to board (and a little in hue)."""
    # (W2: a wider spread than W1's 0.80-1.0, so a wall's courses and a deck's planks still
    # read as boards at 20-60 m once the grain has gone to its mean; one in five greyer, weathered)
    v = m.rng.uniform(0.70, 1.0) * k
    g, b = m.rng.uniform(0.93, 1.0), m.rng.uniform(0.84, 0.98)
    if m.rng.uniform() < 0.2:
        g, b = 0.98, 1.0
    return (min(1.0, v * 1.0), min(1.0, v * g), min(1.0, v * b))


def _shift_uv(m, mat, uo, whole=False):
    """Offset the last block's UVs into the set; a Timber block's faces each go into one board strip
    of the atlas (v across the face's width 0..1 inside strip k, picked per block): its edges then
    darken where a board's do. Faces are runs of vertices sharing a normal (a box's six, a prism's
    caps and sides); a smooth surface (a peeled log) goes in whole."""
    uv = m.parts[mat][2]
    uv[-1] = uv[-1] + np.asarray(uo, float)
    if mat != "Timber":
        return
    U = uv[-1].copy()
    N = np.asarray(m.parts[mat][1][-1], float)
    k = int(m.rng.integers(0, STRIPS))
    groups = []
    if not whole:
        i = 0
        while i < len(U):
            j = i + 1
            while j < len(U) and np.allclose(N[j], N[i], atol=1e-4):
                j += 1
            groups.append((i, j))
            i = j
        if max(j - i for i, j in groups) < 3:
            groups = []
    if not groups:
        groups = [(0, len(U))]
    for i, j in groups:
        v = U[i:j, 1]
        lo, hi = v.min(), v.max()
        t = (v - lo) / (hi - lo) if hi - lo > 1e-6 else np.full_like(v, 0.5)
        U[i:j, 1] = (k + 0.02 + 0.96 * t) / STRIPS
    uv[-1] = U


def wb(m, c, s, M=None, col=None, mat="Timber", sh=None):
    """A box of wood, grain along its local X, at a random place in the set."""
    m.color = col if col is not None else tint(m)
    box(m, mat, c, s, M=M, uv_m=UVW)
    _shift_uv(m, mat, (m.rng.uniform(0, 1), m.rng.uniform(0, 1)))
    if sh is not None:
        sh.add(tuple(np.asarray(c, float)), tuple(s), BM.quat_from_basis(M) if M is not None else (0.0, 0.0, 0.0, 1.0))


def wbx(m, x0, x1, y0, y1, z0, z1, along="x", col=None, sh=None):
    """An axis-aligned piece of wood from its extents, its grain along `along`."""
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    z0, z1 = min(z0, z1), max(z0, z1)
    c = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
    if along == "x":
        wb(m, c, (sx, sy, sz), col=col)
    elif along == "y":
        M = np.column_stack([(0, 1.0, 0), (-1.0, 0, 0), (0, 0, 1.0)])
        wb(m, c, (sy, sx, sz), M=M, col=col)
    else:
        M = np.column_stack([(0, 0, 1.0), (0, 1.0, 0), (-1.0, 0, 0)])
        wb(m, c, (sz, sy, sx), M=M, col=col)
    if sh is not None:
        sh.add(c, (sx, sy, sz))


def board(m, p0, p1, w, t, nrm, col=None, mat="Timber", sh=None):
    """A board from p0 to p1 (its centre line), `w` wide, `t` thick along `nrm`."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    L = float(np.linalg.norm(d))
    ex = d / L
    ey = np.asarray(nrm, float)
    ey = ey - ex * (ey @ ex)
    ey = ey / np.linalg.norm(ey)
    ez = np.cross(ex, ey)
    M = np.column_stack([ex, ey, ez])
    wb(m, (p0 + p1) / 2, (L, t, w), M=M, col=col, mat=mat, sh=sh)
    return M


def iron(m, x0, x1, y0, y1, z0, z1, col=IRON):
    K.bx(m, "Steel", col, x0, x1, y0, y1, z0, z1)


def bolt(m, p, n, r=0.011, h=0.007, col=IRON):
    p, n = np.asarray(p, float), np.asarray(n, float)
    K.tb(m, "Steel", col, tuple(p - n * 0.0015), tuple(p + n * h), r, segs=6)


def bar(m, x0, x1, hy, hz, ch, M=None, t=(0, 0, 0), col=None):
    """A sawn bar along local X from x0 to x1, section 2hy × 2hz with chamfered arrises."""
    sub = BM.CModel(seed=int(m.rng.integers(1, 1 << 30)))
    sub.ground = m.ground
    poly = [(-hz + ch, -hy), (hz - ch, -hy), (hz, -hy + ch), (hz, hy - ch), (hz - ch, hy), (-hz + ch, hy), (-hz, hy - ch), (-hz, -hy + ch)]
    K.prism_x(sub, "Timber", col if col is not None else tint(m), poly, x0, x1)
    # (prism_x's UVs are in metres from the origin: offset this bar into the set)
    _shift_uv(sub, "Timber", (m.rng.uniform(0, 1), m.rng.uniform(0, 1)))
    m.merge(sub, M=M, t=t)


def log(m, y0, y1, r0, r1, segs=12, wobble=0.006, peeled=False, cap_top=True, cap_bot=False, cx=0.0, cz=0.0):
    """A round log up Y: its side in bark (or peeled, grain along it), sawn end grain on its caps."""
    n = max(2, int((y1 - y0) / 0.5) + 1)
    prof = []
    for k in range(n + 1):
        f = k / n
        r = r0 + (r1 - r0) * f + (m.rng.uniform(-wobble, wobble) if 0 < k < n else 0.0)
        prof.append((r, y0 + (y1 - y0) * f))
    sub = BM.CModel(seed=int(m.rng.integers(1, 1 << 30)))
    sub.ground = m.ground
    mat = "Timber" if peeled else "LogBark"
    sub.color = tint(m) if peeled else tuple(c * m.rng.uniform(0.85, 1.0) for c in BARK)
    lathe(sub, mat, prof, segs=segs, uv_m=1.0 if peeled else 1.2, u_tiles=1, smooth=True)
    if peeled:
        # (the lathe's u runs round the log: swap so the grain runs along it)
        uv = sub.parts[mat][2]
        uv[-1] = uv[-1][:, ::-1] * np.array([UVW, 0.25 * UVW])
    _shift_uv(sub, mat, (m.rng.uniform(0, 1), m.rng.uniform(0, 1)), whole=True)
    end = (0.86, 0.80, 0.70)     # sawn end grain, lighter than the weathered side
    if cap_top:
        sub.color = end
        disk(sub, "Timber", r1, y1, segs=segs, up=True, uv_m=UVW)
        _shift_uv(sub, "Timber", (m.rng.uniform(0, 1), 0.0), whole=True)
    if cap_bot:
        sub.color = end
        disk(sub, "Timber", r0, y0, segs=segs, up=False, uv_m=UVW)
        _shift_uv(sub, "Timber", (m.rng.uniform(0, 1), 0.0), whole=True)
    m.merge(sub, t=(cx, 0, cz))


# ── a timber stud wall ───────────────────────────────────────────────────────

def runs(x0, x1, y0, y1, holes):
    """A horizontal band [y0,y1] less the holes, as boards that run as far as they can:
    (a, b, c, d) — split in height only where a hole's top or bottom falls in the band."""
    ys = sorted({y0, y1, *[h[2] for h in holes if y0 < h[2] < y1], *[h[3] for h in holes if y0 < h[3] < y1]})
    out = []
    for c, d in zip(ys, ys[1:]):
        cut = sorted((h[0], h[1]) for h in holes if h[2] < d - 1e-6 and h[3] > c + 1e-6)
        x = x0
        for (a, b) in cut:
            if a > x + 1e-6:
                out.append((x, min(a, x1), c, d))
            x = max(x, b)
        if x < x1 - 1e-6:
            out.append((x, x1, c, d))
    return out


def wood_wall(m, sh, x0, x1, y0, y1, holes=(), pocket=None, casing=True):
    """A stud wall [x0,x1]×[y0,y1] less rectangular holes (x0, x1, y0, y1): plates, studs, framed
    openings, lapped weatherboards outside (+Z), vertical boards inside (-Z), linings and casings
    round each hole. `pocket` = (xa, xb): no studs or sole plate there (a sliding leaf runs in it).
    `sh` (if given) takes the solid cells as colliders."""
    hz = WT / 2
    # the frame: each member at its own depth (see the module's note)
    PL, ST, JB, HD = 0.066, 0.063, 0.060, 0.057
    gaps = [(h[0], h[1]) for h in holes if h[2] <= y0 + 1e-3]       # doorways cut the sole plate
    if pocket:
        gaps.append(pocket)
    xs = sorted({x0 + 0.003, x1 - 0.003, *[g[0] for g in gaps], *[g[1] for g in gaps]})
    for a, b in zip(xs, xs[1:]):
        mid = (a + b) / 2
        if b - a > 0.02 and not any(g[0] - 1e-6 <= mid <= g[1] + 1e-6 for g in gaps):
            wbx(m, a, b, y0, y0 + 0.045, -PL, PL)
    wbx(m, x0 + 0.003, x1 - 0.003, y1 - 0.045, y1, -PL, PL)
    sy0, sy1 = y0 + 0.045, y1 - 0.045
    studs = [x0 + 0.003, x1 - 0.048]
    x = x0 + 0.6
    while x < x1 - 0.2:
        studs.append(x - 0.0225)
        x += 0.6
    busy = [(h[0] - 0.12, h[1] + 0.12) for h in holes] + ([(pocket[0] - 0.05, pocket[1] + 0.02)] if pocket else [])
    for sx in studs:
        end = abs(sx - (x0 + 0.003)) < 1e-6 or abs(sx - (x1 - 0.048)) < 1e-6
        if not end and any(a < sx + 0.045 and sx < b for (a, b) in busy):
            continue
        if end and pocket and pocket[0] < sx + 0.045 and sx < pocket[1]:
            continue
        wbx(m, sx, sx + 0.045, sy0, sy1, -ST, ST, along="y")
    for (a, b, c, d) in holes:
        top = min(d, sy1)
        bot = sy0 if c <= y0 + 1e-3 else c
        for (p, q) in ((a - 0.045, a), (b, b + 0.045)):
            if p >= x0 and q <= x1:
                wbx(m, p, q, sy0, top, -JB, JB, along="y")
        if d < sy1 - 0.02:
            wbx(m, max(x0 + 0.003, a - 0.045), min(x1 - 0.003, b + 0.045), d, min(d + 0.15, sy1 - 0.003), -HD, HD)
        if c > y0 + 0.05:
            wbx(m, a, b, c - 0.045, c, -HD, HD)
    # OUTSIDE: lapped weatherboards, 200 mm, each tilted so its foot stands proud of the one below
    ang = -0.06
    R = rot_x(ang)
    rows = []
    y = y0
    while y < y1 - 1e-6:
        rows.append((y, min(y1, y + 0.2)))
        y += 0.2
    laps = []
    for (ra, rb) in rows:
        laps += runs(x0, x1, ra, rb, holes)
    starts = sorted({round(c, 4) for (_a, _b, c, _d) in laps})
    for (a, b, c, d) in laps:
        if b - a < 0.01 or d - c < 0.01:
            continue
        # (a lap overlaps the board above it: every other course stops 2.5 mm short at its
        # ends, so two boards' end grain never shares a plane where they overlap)
        e = 0.0025 if starts.index(round(c, 4)) % 2 else 0.0
        h = (d - c) + (0.006 if d < y1 - 1e-6 else 0.0)
        wb(m, ((a + b) / 2, c + h / 2, 0.0835), (b - a - 2 * e, h, 0.018), M=R)
    # INSIDE: vertical boards, 145 mm with 5 mm gaps
    xa = x0
    while xa < x1 - 1e-6:
        xb = min(x1, xa + 0.145)
        if x1 - xb < 0.05:
            xb = x1
        for (a, b, c, d) in K.solid_cells(xa, xb, y0, y1, holes):
            if b - a > 0.01 and d - c > 0.01:
                wbx(m, a, b, c, d, -hz, -hz + 0.02, along="y")
        xa = xb + 0.005
    # linings through each hole and casings proud of both faces
    for (a, b, c, d) in holes:
        sill = c > y0 + 1e-3
        L = 0.022
        jb0 = c + L if sill else c + 0.002
        wbx(m, a, a + L, jb0, d - L, -hz, hz, along="y")
        wbx(m, b - L, b, jb0, d - L, -hz, hz, along="y")
        wbx(m, a, b, d - L, d, -hz + 0.002, hz - 0.002)
        if sill:
            wbx(m, a, b, c, c + L, -hz + 0.002, hz - 0.002)
        if casing:
            for s in (-1, 1):
                z0, z1 = (hz + 0.001, hz + 0.023) if s > 0 else (-hz - 0.023, -hz - 0.001)
                cb = c if sill else c + 0.004
                wbx(m, max(x0, a - 0.07), a, cb, d, z0, z1, along="y")
                wbx(m, b, min(x1, b + 0.07), cb, d, z0, z1, along="y")
                wbx(m, max(x0, a - 0.07), min(x1, b + 0.07), d, min(y1 - 0.003, d + 0.07), z0, z1)
                if sill and s < 0:
                    # (inside: an apron under the sill; outside the window's own sloped sill)
                    wbx(m, max(x0, a - 0.07), min(x1, b + 0.07), c - 0.07, c, z0, z1)
    if sh is not None:
        for (a, b, c, d) in K.solid_cells(x0, x1, y0, y1, holes):
            sh.add(((a + b) / 2, (c + d) / 2, 0), (b - a, d - c, WT))


def plank_leaf(w, h, t=0.032, ledges=(0.16, 0.95, 1.80), braced=True, hinges=True, seed=401):
    """A ledged-and-braced plank door leaf about its bottom centre: (model, colliders). Its boards
    face +Z, its ledges and braces are on -Z; strap hinges on +Z from its -X edge."""
    m = BM.CModel(seed=seed)
    m.ground = False
    sh = BM.Shell()
    n = 6 if w > 0.8 else 5
    bw = w / n
    for k in range(n):
        a = -w / 2 + k * bw + (0.0025 if k > 0 else 0.0)
        b = -w / 2 + (k + 1) * bw - (0.0025 if k < n - 1 else 0.0)
        wbx(m, a, b, 0.0, h, -t / 2, t / 2, along="y")
    lz0, lz1 = -t / 2 - 0.026, -t / 2
    ys = [y for y in ledges if y < h - 0.1]
    for y in ys:
        wbx(m, -w / 2 + 0.05, w / 2 - 0.05, y - 0.07, y + 0.07, lz0, lz1)
    if braced and len(ys) >= 2:
        for (ya, yb) in zip(ys, ys[1:]):
            # (rising from the hinge side's lower ledge to the latch side's upper one)
            p0 = np.array([-w / 2 + 0.12, ya + 0.07, (lz0 + lz1) / 2 + 0.001])
            p1 = np.array([w / 2 - 0.12, yb - 0.07, (lz0 + lz1) / 2 + 0.001])
            board(m, p0, p1, 0.12, 0.022, (0, 0, 1.0))
    if hinges:
        for y in (ys[0], ys[-1]):
            iron(m, -w / 2 + 0.005, -w / 2 + 0.52, y - 0.022, y + 0.022, t / 2, t / 2 + 0.005)
            for k in range(3):
                bolt(m, (-w / 2 + 0.08 + k * 0.17, y, t / 2 + 0.005), (0, 0, 1))
        # a thumb latch and its pull (outside), a wooden turn button (inside)
        K.tb(m, "Steel", IRON, (w / 2 - 0.09, 0.92, t / 2), (w / 2 - 0.09, 0.92, t / 2 + 0.05), 0.008, segs=6)
        K.tb(m, "Steel", IRON, (w / 2 - 0.09, 1.10, t / 2), (w / 2 - 0.09, 1.10, t / 2 + 0.05), 0.008, segs=6)
        K.tb(m, "Steel", IRON, (w / 2 - 0.09, 0.915, t / 2 + 0.05), (w / 2 - 0.09, 1.105, t / 2 + 0.05), 0.009, segs=6)
        wbx(m, w / 2 - 0.13, w / 2 - 0.05, 1.0, 1.04, lz0 - 0.025, lz0 - 0.001)
    sh.add((0, h / 2, -0.013), (w, h, t + 0.026))
    return m, sh


# ── the timber versions of the kit's pieces (colliders: the existing piece's) ─

def shell_of(fn, mat):
    _m, sh, _ch = fn(mat)
    return sh


def w_wall(x0=-1, x1=1, h=WH):
    def g(base, first):
        m = BM.CModel(seed=521)
        wood_wall(m, None, x0, x1, 0, h)
        return m, shell_of(base, first), []
    return g


def w_doorWall(base, first):
    m = BM.CModel(seed=522)
    wood_wall(m, None, -1, 1, 0, WH, holes=[(-0.92, 0.0, 0.0, 2.05)], pocket=(0.0, 0.95))
    # outside: a caged bulb lamp over the door, a step board
    iron(m, -0.52, -0.40, 2.10, 2.17, WT / 2 + 0.024, WT / 2 + 0.09)
    K.bx(m, "Lamp", K.LAMP_WARM, -0.50, -0.42, 2.095, 2.10, WT / 2 + 0.03, WT / 2 + 0.085)
    lm, lsh = plank_leaf(0.94, 2.03, ledges=(0.16, 0.95, 1.80), braced=False, hinges=False, seed=402)
    # (a sliding leaf: a recessed pull instead of hinges)
    iron(lm, 0.39, 0.42, 0.85, 1.15, 0.016, 0.022)
    return m, shell_of(base, first), [("Door", "door", (lm, lsh, (-0.46, 0.008, 0.0)))]


def w_windowWall(base, first):
    m = BM.CModel(seed=524)
    a, b, c, d = -0.6, 0.6, 0.9, 1.9
    wood_wall(m, None, -1, 1, 0, WH, holes=[(a, b, c, d)])
    # the sash: a frame inside the linings, a single pane in four lights, a sloped sill outside
    L, f = 0.022, 0.05
    a2, b2, c2, d2 = a + L + 0.002, b - L - 0.002, c + L + 0.002, d - L - 0.002
    wbx(m, a2, a2 + f, c2, d2, -0.028, 0.028, along="y")
    wbx(m, b2 - f, b2, c2, d2, -0.028, 0.028, along="y")
    wbx(m, a2 + f, b2 - f, d2 - f, d2, -0.026, 0.026)
    wbx(m, a2 + f, b2 - f, c2, c2 + f + 0.02, -0.026, 0.026)
    K.bx(m, "Pane", (1, 1, 1), a2 + f - 0.003, b2 - f + 0.003, c2 + f + 0.017, d2 - f + 0.003, -0.005, 0.005)
    wbx(m, -0.015, 0.015, c2 + f + 0.02, d2 - f, -0.018, 0.018, along="y")
    wbx(m, a2 + f, -0.015, 1.385, 1.415, -0.016, 0.016)
    wbx(m, 0.015, b2 - f, 1.385, 1.415, -0.016, 0.016)
    M = rot_x(0.12)
    wb(m, (0, c - 0.035, WT / 2 + 0.06), (1.32, 0.035, 0.13), M=M)
    return m, shell_of(base, first), []


def w_openFrame(base, first):
    m = BM.CModel(seed=527)
    wood_wall(m, None, -1, 1, 0, WH, holes=[(-0.86, 0.86, 0.0, 2.05)])
    return m, shell_of(base, first), []


def wood_floor(m, x0, x1, z0, z1, t=0.2, bt=0.03, joists=True):
    """Joists along Z under boards along X (gaps 6 mm), rim joists round the edge."""
    jt = t - bt
    if joists:
        for s in (-1, 1):
            zz = z1 if s > 0 else z0
            wbx(m, x0 + 0.003, x1 - 0.003, 0.0, jt, zz - s * 0.045, zz - s * 0.0)
        n = max(2, int(round((x1 - x0) / 0.6)) + 1)
        for k in range(n):
            xc = x0 + 0.0255 + k * ((x1 - x0) - 0.051) / (n - 1)
            wbx(m, xc - 0.0225, xc + 0.0225, 0.0, jt - 0.002, z0 + 0.047, z1 - 0.047, along="z")
    w = 0.14
    z = z0
    while z < z1 - 1e-6:
        zb = min(z1, z + w)
        if z1 - zb < 0.05:
            zb = z1
        j = m.rng.uniform(-0.004, 0.0)
        wbx(m, x0 - j * 0, x1, jt, t, z, zb)
        z = zb + 0.006


def w_floor(w, d):
    def g(base, first):
        m = BM.CModel(seed=531)
        m.ground = False
        wood_floor(m, -w / 2, w / 2, -d / 2, d / 2)
        return m, shell_of(base, first), []
    return g


def roof_frame():
    """The steel Pitched Roof's own frame (tools/gen_kit_parts.py p_roofPitch), so a timber roof
    lies exactly where a steel one does: → (top centre, X, normal, uphill, slope length)."""
    a = math.radians(30)
    L = 2.0 / math.cos(a)
    c, s = math.cos(a), math.sin(a)
    M = np.array([[1, 0, 0], [0, c, s], [0, -s, c]])
    t = 0.12
    n = np.array([0, c, s])
    mid = np.array([0, 1.155 / 2, 0])
    cen = mid + n * (t / 2 - t)
    return cen + M[:, 1] * (t / 2), M[:, 0], M[:, 1], M[:, 2], L, M


def roof_body(m, kind="shingle"):
    """Rafters, battens and shingles (or boards and battens) in the pitched roof's frame."""
    top, X, Nn, U, L, M = roof_frame()

    def P(x, s, h):
        return top + X * x + U * s + Nn * h
    # rafters (h -0.12 .. -0.045)
    for xr in (-0.925, 0.0, 0.925):
        wb(m, P(xr, 0, -0.0825), (L - 0.006, 0.075, 0.05), M=np.column_stack([U, Nn, -X]))
    if kind == "shingle":
        # battens under each course (h -0.045 .. -0.02)
        s = -L / 2 + 0.24
        while s < L / 2 - 0.05:
            wb(m, P(0, s, -0.0325), (1.98, 0.025, 0.045), M=np.column_stack([X, Nn, -U]))
            s += 0.17
        # courses of split shingles, butts down the slope, each tilted under the next
        expo, ln, th = 0.17, 0.40, 0.012
        beta = math.atan2(0.016, ln)
        k = 0
        s0 = -L / 2
        recent = []      # the joints of the courses this one lies on (3 overlap anywhere)
        nclip = 0
        while s0 < L / 2 - 0.03:
            top_s = s0 + ln
            if top_s > L / 2:
                # (the courses cut at the ridge stop 6 mm apart: their heads never share a plane)
                top_s = L / 2 - 0.006 * nclip
                nclip += 1
            ll = top_s - s0
            x = -1.0 + (m.rng.uniform(0.0, 0.12) if k % 2 else m.rng.uniform(0.07, 0.2))
            xs = [-1.0]
            while x < 1.0 - 0.06:
                # (a joint never within 2 cm of one in the courses under it: no shared side planes,
                # and the water never finds a straight way through)
                while any(abs(x - e) < 0.02 for e in recent):
                    x += 0.025
                if x >= 1.0 - 0.06:
                    break
                xs.append(x)
                x += m.rng.uniform(0.14, 0.30)
            xs.append(1.0)
            recent = (recent + xs[1:-1])[-30:]
            e = 0.0025 if k % 2 else 0.0      # (alternate courses stop short at the verges: no shared end planes)
            for a, b in zip(xs, xs[1:]):
                a2 = a + (0.003 if a > -1.0 + 1e-6 else e)
                b2 = b - (0.003 if b < 1.0 - 1e-6 else e)
                if b2 - a2 < 0.03:
                    continue
                # the shingle's butt at h = 0 (on the roof line), its head pushed down
                Ms = np.column_stack([U * math.cos(beta) - Nn * math.sin(beta), Nn * math.cos(beta) + U * math.sin(beta), np.cross(U * math.cos(beta) - Nn * math.sin(beta), Nn * math.cos(beta) + U * math.sin(beta))])
                cc = P((a2 + b2) / 2, s0, 0.0) + Ms[:, 0] * (ll / 2) - Ms[:, 1] * (th / 2)
                wb(m, cc, (ll, th, b2 - a2), M=Ms, col=tint(m, 0.92))
            s0 += expo
            k += 1
    else:
        # boards down the slope with 3 mm gaps, battens over the gaps
        x = -1.0
        xs = [-1.0]
        while x < 1.0 - 0.1:
            x += 0.2
            xs.append(min(1.0, x))
        for a, b in zip(xs, xs[1:]):
            a2 = a + (0.0015 if a > -1.0 + 1e-6 else 0.0)
            b2 = b - (0.0015 if b < 1.0 - 1e-6 else 0.0)
            wb(m, P((a2 + b2) / 2, 0, -0.0325), (L - 0.004, 0.025, b2 - a2), M=np.column_stack([U, Nn, -X]))
        for xb in xs[1:-1]:
            wb(m, P(xb, 0, -0.01), (L - 0.01, 0.02, 0.05), M=np.column_stack([U, Nn, -X]))
    # a fascia board along the low eave
    wb(m, P(0, -L / 2 + 0.012, -0.0725), (1.994, 0.085, 0.024), M=np.column_stack([X, Nn, -U]))


def w_roofPitch(base, first):
    m = BM.CModel(seed=541)
    m.ground = False
    roof_body(m, "boards")
    return m, shell_of(base, first), []


def w_roofRidge(base, first):
    m = BM.CModel(seed=542)
    m.ground = False
    for s in (-1, 1):
        a = math.radians(30) * s
        c, sn = math.cos(a), math.sin(a)
        M = np.array([[1, 0, 0], [0, c, sn], [0, -sn, c]])
        wb(m, (0, 0.08 + (0.004 if s > 0 else 0.0), -s * 0.09), (2.0 - (0.006 if s > 0 else 0.0), 0.025, 0.2), M=M)
    for x in (-0.8, -0.27, 0.27, 0.8):
        bolt(m, (x, 0.152, 0.0), (0, 1, 0), r=0.008, h=0.006)
    return m, shell_of(base, first), []


def w_gable(base, first):
    m = BM.CModel(seed=543)
    H = 1.155

    def xl(y):
        return -1.0 + 2.0 * y / H
    for z0, z1, dz in ((0.078, 0.1, 0.0), (-0.1, -0.078, 0.0)):
        y = 0.0
        while y < H - 0.03:
            y1 = min(H, y + 0.2)
            a0, a1 = xl(y) + 0.003, xl(y1) + 0.003
            poly = [(a0, y), (1.0, y), (1.0, y1 - 0.004)] + ([(max(a1, a0), y1 - 0.004)] if a1 < 0.99 else [])
            if len(poly) >= 3:
                K.prism_z(m, "Timber", tint(m), poly, -z1, -z0)     # (prism_z lands on [-z1, -z0])
                _shift_uv(m, "Timber", (m.rng.uniform(0, 1), m.rng.uniform(0, 1)))
            y = y1
    # the frame inside: a sole plate, a raking rafter, two studs
    wbx(m, -0.99, 0.997, 0.0, 0.045, -0.066, 0.066)
    ang = math.atan2(H, 2.0)
    board(m, (-0.9, 0.06, 0), (0.95, H - 0.02, 0), 0.12, 0.09, (-math.sin(ang), math.cos(ang), 0))
    for xs in (0.25, 0.952):
        top = (xs + 0.045 + 1.0) * H / 2.0 - 0.12
        if top > 0.1:
            wbx(m, xs, xs + 0.045, 0.045, top, -0.063, 0.063, along="y")
    return m, shell_of(base, first), []


def w_pillar(h):
    def g(base, first):
        m = BM.CModel(seed=551)
        bar(m, 0.03, h - 0.012, 0.135, 0.135, 0.018, M=np.column_stack([(0, 1.0, 0), (-1.0, 0, 0), (0, 0, 1.0)]))
        # a galvanised post base (a stand-off shoe) and a cap plate
        K.bx(m, "Steel", GALV, -0.15, 0.15, 0, 0.012, -0.15, 0.15)
        K.bx(m, "Steel", GALV, -0.10, 0.10, 0.012, 0.03, -0.10, 0.10)
        for s in (-1, 1):
            K.bx(m, "Steel", GALV, s * 0.135 + (0.0 if s > 0 else -0.006), s * 0.135 + (0.006 if s > 0 else 0.0), 0.03, 0.22, -0.05, 0.05)
            bolt(m, (s * 0.141, 0.16, 0.0), (s, 0, 0))
        K.bx(m, "Steel", GALV, -0.15, 0.15, h - 0.012, h, -0.15, 0.15)
        return m, shell_of(base, first), []
    return g


def w_beam(Ln):
    def g(base, first):
        m = BM.CModel(seed=561)
        m.ground = False
        # glued laminated: eight 50 mm laminations, each its own board
        for k in range(8):
            wbx(m, -Ln / 2 + 0.002, Ln / 2 - 0.002, k * 0.05, (k + 1) * 0.05 - (0.0 if k == 7 else 0.0), -0.1 + (0.0 if k % 2 else 0.001), 0.1 - (0.0 if k % 2 else 0.001))
        for x in (-Ln / 2 + 0.12, Ln / 2 - 0.12):
            for y in (0.12, 0.28):
                for s in (-1, 1):
                    bolt(m, (x, y, s * 0.1), (0, 0, s), r=0.014, h=0.009)
        return m, shell_of(base, first), []
    return g


def w_pier(base, first):
    m = BM.CModel(seed=571)
    wbx(m, -0.25, 0.25, 0.0, 0.035, -0.25, 0.25, along="z")
    bar(m, 0.035, 1.465, 0.11, 0.11, 0.015, M=np.column_stack([(0, 1.0, 0), (-1.0, 0, 0), (0, 0, 1.0)]))
    wbx(m, -0.25, 0.25, 1.465, 1.5, -0.25, 0.25)
    for a in range(4):
        c, s = math.cos(a * math.pi / 2), math.sin(a * math.pi / 2)
        d = np.array([c, 0, s])
        board(m, d * 0.235 + np.array([0, 0.05, 0]), d * 0.115 + np.array([0, 0.45, 0]), 0.07 - 0.004 * (a % 2), 0.05, np.array([-s, 0, c]))
    for y in (0.7, 1.2):
        iron(m, -0.112, 0.112, y, y + 0.04, -0.112, 0.112, col=GALV)
    return m, shell_of(base, first), []


def w_ramp(base, first):
    m = BM.CModel(seed=572)
    ang = math.atan2(0.5, 4.0)
    L = math.hypot(4, 0.5)
    t = 0.032
    for xs in (-0.88, 0.0, 0.88):
        hy = t / math.cos(ang)
        K.prism_x(m, "Timber", tint(m), [(1.98, 0.0), (-1.98, 0.5 - hy - 0.0025), (-1.98, 0.0)], xs - 0.04, xs + 0.04)
        _shift_uv(m, "Timber", (m.rng.uniform(0, 1), m.rng.uniform(0, 1)))
    d = np.array([0, 0.5, -4.0]) / L
    nrm = np.array([0, 4.0, 0.5]) / L
    n = 19
    for k in range(n):
        s0 = k * L / n + 0.006
        s1 = (k + 1) * L / n - 0.006
        p0 = np.array([0, 0, 2.0]) + d * s0 - nrm * (t / 2)
        p1 = np.array([0, 0, 2.0]) + d * s1 - nrm * (t / 2)
        M = np.column_stack([(1.0, 0, 0), nrm, -d])
        wb(m, (p0 + p1) / 2, (1.99 - m.rng.uniform(0, 0.01), t, s1 - s0), M=M)
    wbx(m, -0.995, 0.995, 0.0, 0.5 - 0.035, -2.0, -1.975)
    return m, shell_of(base, first), []


def wood_stair(m, rise, run, width, rails=True):
    """Two stringers along the slope, a tread every 0.2 m of rise, handrails on posts."""
    n = max(2, int(round(rise / 0.2)))
    p0 = np.array([0.0, 0.0, run / 2]); d = np.array([0.0, rise, -run])
    L = float(np.linalg.norm(d)); f3 = d / L
    side = np.array([1.0, 0, 0]); upn = np.cross(f3, side)
    if upn[1] < 0:
        upn = -upn
    for s in (-1, 1):
        c = p0 + d / 2 + side * s * (width / 2 + 0.03) + upn * 0.06
        wb(m, c, (L, 0.2, 0.05), M=np.column_stack([f3, upn, np.cross(f3, upn)]))
    for k in range(1, n + 1):
        y = rise * k / n
        z = run / 2 - run * (k - 0.5) / n
        wbx(m, -width / 2 - 0.004, width / 2 + 0.004, y - 0.038, y, z - run / n * 0.5 - 0.012, z + run / n * 0.5 - 0.006)
        for s in (-1, 1):
            bolt(m, (s * (width / 2 + 0.055), y - 0.05, z), (s, 0, 0), r=0.01, h=0.006)
    if rails:
        for s in (-1, 1):
            a = p0 + side * s * (width / 2 + 0.03)
            for k in range(0, n + 1, max(1, n // 3)):
                q = a + d * (k / n) + side * s * 0.055
                wbx(m, q[0] - 0.03, q[0] + 0.03, q[1] + 0.12, q[1] + 1.0, q[2] - 0.03, q[2] + 0.03, along="y")
            r0 = a + side * s * 0.055 + np.array([0, 1.02, 0])
            board(m, r0, r0 + d, 0.07, 0.04, upn)


def w_stairs(rise, run, width):
    def g(base, first):
        m = BM.CModel(seed=581)
        m.ground = False
        wood_stair(m, rise, run, width)
        return m, shell_of(base, first), []
    return g


def w_catwalk(base, first):
    m = BM.CModel(seed=591)
    m.ground = False
    for s in (-1, 1):
        wbx(m, s * 0.46 - 0.035, s * 0.46 + 0.035, 0.0, 0.05, -1.0, 1.0, along="z")
    z = -1.0
    while z < 1.0 - 1e-6:
        zb = min(1.0, z + 0.14)
        wbx(m, -0.5, 0.5, 0.05, 0.08, z, zb)
        z = zb + 0.007
    for s in (-1, 1):
        for zz in (-0.94, 0.0, 0.94):
            wbx(m, s * 0.465 - 0.03, s * 0.465 + 0.03, 0.08, 1.13, zz - 0.03, zz + 0.03, along="y")
        wbx(m, s * 0.465 - 0.035, s * 0.465 + 0.035, 1.13, 1.15, -1.0, 1.0, along="z")
        wbx(m, s * 0.465 + (0.03 if s > 0 else -0.05), s * 0.465 + (0.05 if s > 0 else -0.03), 0.55, 0.65, -1.0, 1.0, along="z")
    return m, shell_of(base, first), []


def w_rail(base, first):
    m = BM.CModel(seed=592)
    m.ground = False
    for x in (-0.965, 0.0, 0.965):
        wbx(m, x - 0.035, x + 0.035, 0.0, 1.06, -0.035, 0.035, along="y")
        iron(m, x - 0.05, x + 0.05, 0.0, 0.008, -0.05, 0.05, col=GALV)
    wbx(m, -1.0, 1.0, 1.06, 1.1, -0.04, 0.04)
    wbx(m, -0.93, 0.93, 0.5, 0.6, 0.035, 0.057)
    return m, shell_of(base, first), []


# ── the TIMBER section's own pieces ──────────────────────────────────────────

def p_post(h):
    def g(mat):
        m, sh = BM.CModel(seed=611 + int(h)), BM.Shell()
        log(m, 0.0, h - 0.004, 0.15, 0.138, segs=14, wobble=0.007)
        # (the top 0.12 m peeled where a beam or a plate sits on it)
        sh.add((0, h / 2, 0), (0.28, h, 0.28))
        return m, sh, []
    return g


def p_beam6w(mat):
    m, sh = BM.CModel(seed=621), BM.Shell()
    m.ground = False
    bar(m, -3.0, 3.0, 0.15, 0.1, 0.012, t=(0, 0.15, 0))
    # through-bolts with square washers at the bearings
    for x in (-2.82, -2.62, 2.62, 2.82):
        for s in (-1, 1):
            z0, z1 = (0.1, 0.104) if s > 0 else (-0.104, -0.1)
            iron(m, x - 0.03, x + 0.03, 0.12, 0.18, z0, z1)
            bolt(m, (x, 0.15, z1 if s > 0 else z0), (0, 0, s), r=0.014, h=0.009)
    sh.add((0, 0.15, 0), (6.0, 0.3, 0.2))
    return m, sh, []


def p_trussW4(mat):
    m, sh = BM.CModel(seed=631), BM.Shell()
    m.ground = False
    H = 0.9
    # the tie (bottom chord) 150 deep, z ±0.05
    wbx(m, -2.0, 2.0, 0.0, 0.15, -0.05, 0.05, sh=sh)
    def up_normal(d):
        n = np.array([-d[1], d[0], 0.0])
        return n if n[1] >= 0 else -n
    # rafters from the tie's ends to the apex (z ±0.045)
    for s in (-1, 1):
        p0 = np.array([s * 1.93, 0.075, 0.0])
        p1 = np.array([0.0, H - 0.075, 0.0])
        # (the two rafters cross at the apex: one 3 mm thinner each side)
        board(m, p0, p1, 0.09 if s < 0 else 0.084, 0.14, up_normal((p1 - p0) / np.linalg.norm(p1 - p0)), sh=sh)
    # the king post (z ±0.04) and two struts (z ±0.035)
    wbx(m, -0.06, 0.06, 0.15, H - 0.06, -0.04, 0.04, along="y", sh=sh)
    for s in (-1, 1):
        p0 = np.array([s * 0.07, 0.22, 0.0])
        p1 = np.array([s * 0.95, 0.52, 0.0])
        board(m, p0, p1, 0.07, 0.09, up_normal((p1 - p0) / np.linalg.norm(p1 - p0)))
    # galvanised gusset plates both faces at the heels, the king post's foot and the apex, bolted
    for zs in (-1, 1):
        z0, z1 = (0.0505, 0.056) if zs > 0 else (-0.056, -0.0505)
        zf = z1 if zs > 0 else z0
        for s in (-1, 1):
            iron(m, min(s * 1.99, s * 1.76), max(s * 1.99, s * 1.76), 0.01, 0.30, z0, z1, col=GALV)
            for (bx_, by_) in ((s * 1.84, 0.075), (s * 1.92, 0.21)):
                bolt(m, (bx_, by_, zf), (0, 0, zs), r=0.012, h=0.007)
        iron(m, -0.14, 0.14, 0.02, 0.32, z0, z1, col=GALV)
        iron(m, -0.11, 0.11, H - 0.24, H - 0.02, z0, z1, col=GALV)
        for (bx_, by_) in ((-0.08, 0.08), (0.08, 0.08), (0.0, 0.25), (0.0, H - 0.12)):
            bolt(m, (bx_, by_, zf), (0, 0, zs), r=0.012, h=0.007)
    return m, sh, []


def p_deck24(mat):
    m, sh = BM.CModel(seed=641), BM.Shell()
    m.ground = False
    for xs in (-0.82, 0.0, 0.82):
        wbx(m, xs - 0.05, xs + 0.05, 0.0, 0.055, -1.997, 1.997, along="z")
    z = -2.0
    k = 0
    while z < 2.0 - 1e-6:
        zb = min(2.0, z + 0.18)
        if 2.0 - zb < 0.06:
            zb = 2.0
        j0, j1 = m.rng.uniform(0.0, 0.012), m.rng.uniform(0.0, 0.012)
        wbx(m, -1.0 + j0, 1.0 - j1, 0.055, 0.1, z, zb, col=tint(m, 0.95))
        for xs in (-0.82, 0.0, 0.82):
            for zz in (z + 0.045, zb - 0.045):
                iron(m, xs - 0.006, xs + 0.006, 0.1, 0.1025, zz - 0.006, zz + 0.006)
        z = zb + 0.02
        k += 1
    sh.add((0, 0.05, 0), (2.0, 0.1, 4.0))
    return m, sh, []


def p_plankFloor(mat):
    m, sh = BM.CModel(seed=651), BM.Shell()
    m.ground = False
    for xs in (-0.9, 0.0, 0.9):
        wbx(m, xs - 0.04, xs + 0.04, 0.0, 0.052, -0.997, 0.997, along="z")
    z = -1.0
    while z < 1.0 - 1e-6:
        zb = min(1.0, z + 0.14)
        if 1.0 - zb < 0.05:
            zb = 1.0
        wbx(m, -1.0, 1.0, 0.052, 0.08, z, zb)
        for xs in (-0.9, 0.0, 0.9):
            iron(m, xs - 0.005, xs + 0.005, 0.08, 0.0825, (z + zb) / 2 - 0.005, (z + zb) / 2 + 0.005)
        z = zb + 0.008
    sh.add((0, 0.04, 0), (2.0, 0.08, 2.0))
    return m, sh, []


def p_shingleRoof(mat):
    m, sh = BM.CModel(seed=661), BM.Shell()
    m.ground = False
    roof_body(m, "shingle")
    top, X, Nn, U, L, M = roof_frame()
    sh.add(tuple(top - Nn * 0.06), (2.0, 0.12, L), BM.quat_from_basis(M))
    return m, sh, []


def p_fence(mat):
    m, sh = BM.CModel(seed=671), BM.Shell()
    for xs in (-0.96, 0.96):
        wbx(m, xs - 0.04, xs + 0.04, 0.0, 1.1, -0.05, 0.03, along="y")
    for y in (0.28, 0.82):
        wbx(m, -0.92, 0.92, y - 0.045, y + 0.045, -0.048, -0.02)
    x = -0.9
    while x < 0.9 - 0.03:
        xb = min(0.9, x + 0.08)
        h = 1.02 + m.rng.uniform(-0.015, 0.01)
        poly = [(x, 0.05), (xb, 0.05), (xb, h - 0.05), ((x + xb) / 2, h), (x, h - 0.05)]
        # (gen_kit_parts.prism_z builds over [-z1, -z0]: asked for that, it lands on [-0.0195, 0])
        K.prism_z(m, "Timber", tint(m), poly, 0.0, 0.0195)
        _shift_uv(m, "Timber", (m.rng.uniform(0, 1), m.rng.uniform(0, 1)))
        for y in (0.28, 0.82):
            iron(m, (x + xb) / 2 - 0.005, (x + xb) / 2 + 0.005, y - 0.005, y + 0.005, 0.0, 0.0025)
        x = xb + 0.04
    sh.add((0, 0.55, 0), (2.0, 1.1, 0.1))
    return m, sh, []


def p_hutDoor(mat):
    m, sh = BM.CModel(seed=681), BM.Shell()
    hole = (-0.5, 0.5, 0.0, 2.05)
    wood_wall(m, sh, -1, 1, 0, WH, holes=[hole])
    # pintles on the hinge jamb (the leaf's straps hang on them), a stop on the latch side
    for y in (0.16, 1.80):
        K.tb(m, "Steel", IRON, (-0.478, y - 0.03, 0.018), (-0.478, y + 0.03, 0.018), 0.008, segs=6)
        iron(m, -0.478, -0.448, y - 0.012, y + 0.012, 0.016, 0.02)
    lm, lsh = plank_leaf(0.94, 2.03, seed=403)
    # (the leaf's hinge edge at x = -0.47, where parts_kit's hinge is: it turns about its own edge)
    return m, sh, [("Door", "door", (lm, lsh, (0.0, 0.01, 0.0)))]


def p_campMast(mat):
    m, sh = BM.CModel(seed=691), BM.Shell()
    H = 7.25
    log(m, 0.0, H, 0.125, 0.085, segs=12, wobble=0.004, peeled=True)
    sh.add((0, H / 2, 0), (0.24, H, 0.24))
    # three raking struts to an iron collar
    for k in range(3):
        a = k * 2 * math.pi / 3 + 0.3
        p0 = np.array([0.5 * math.cos(a), 0.0, 0.5 * math.sin(a)])
        p1 = np.array([0.13 * math.cos(a), 1.55, 0.13 * math.sin(a)])
        sub = BM.CModel(seed=700 + k)
        sub.ground = True
        d = p1 - p0
        Lk = float(np.linalg.norm(d))
        log(sub, 0.0, Lk, 0.045, 0.04, segs=8, wobble=0.0, cap_top=False, cap_bot=True)
        from gen_part_meshes import frame_to
        m.merge(sub, M=frame_to(d / Lk), t=tuple(p0))
        iron(m, p0[0] - 0.08, p0[0] + 0.08, 0.0, 0.01, p0[2] - 0.08, p0[2] + 0.08, col=GALV)
    K.tb(m, "Steel", IRON, (0, 1.5, 0), (0, 1.64, 0), 0.135, segs=14)
    # the radio box and its battery, a cable up the pole
    K.bx(m, "Steel", (0.36, 0.40, 0.33), 0.12, 0.22, 1.05, 1.45, -0.15, 0.15)
    iron(m, 0.1, 0.12, 1.1, 1.4, -0.06, 0.06)
    K.bx(m, "Steel", (0.20, 0.21, 0.20), -0.42, -0.14, 0.0, 0.32, 0.18, 0.42)
    sh.add((-0.28, 0.16, 0.30), (0.28, 0.32, 0.24))
    K.tb(m, "Rubber", K.RUBBER, (0.17, 1.45, 0.0), (0.17, 1.62, 0.0), 0.012, segs=6)
    K.tb(m, "Rubber", K.RUBBER, (0.125, 1.66, 0.0), (0.095, H - 0.06, 0.0), 0.009, segs=6)
    # the whip: a spring base on an iron cap, a thin steel rod
    K.tb(m, "Steel", IRON, (0, H - 0.08, 0), (0, H + 0.03, 0), 0.095, segs=12)
    K.tb(m, "Steel", (0.30, 0.30, 0.29), (0, H + 0.03, 0), (0, H + 0.16, 0), 0.022, segs=8)
    K.tb(m, "Steel", (0.62, 0.62, 0.60), (0, H + 0.16, 0), (0, 7.995, 0), 0.006, segs=6)
    return m, sh, []


def p_shoring(mat):
    m, sh = BM.CModel(seed=711), BM.Shell()
    for s in (-1, 1):
        sub = BM.CModel(seed=712 + s)
        log(sub, 0.0, 2.0, 0.11, 0.105, segs=12, wobble=0.006, cap_top=False)
        # (battered: their feet 4 cm wider than their heads)
        a = s * 0.02
        Mr = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
        m.merge(sub, M=Mr, t=(s * 0.875, 0, 0))
        sh.add((s * 0.865, 1.0, 0), (0.22, 2.0, 0.22))
    bar(m, -1.0, 1.0, 0.1, 0.1, 0.015, t=(0, 2.1, 0))
    sh.add((0, 2.1, 0), (2.0, 0.2, 0.2))
    # wedges between cap and legs, iron dogs over the joints
    for s in (-1, 1):
        for zs in (-1, 1):
            wbx(m, s * 0.865 - 0.05, s * 0.865 + 0.05, 1.975, 2.0, zs * 0.07 - 0.03, zs * 0.07 + 0.03)
        K.tb(m, "Steel", IRON, (s * 0.77, 2.05, 0.104), (s * 0.77, 1.90, 0.115), 0.01, segs=6)
    return m, sh, []


def p_sawbench(mat):
    m, sh = BM.CModel(seed=721), BM.Shell()
    # two trestles: splayed legs under a cross rail
    for xs in (-0.6, 0.6):
        for zs in (-1, 1):
            p0 = np.array([xs, 0.0, zs * 0.4])
            p1 = np.array([xs, 0.76, zs * 0.2])
            d = (p1 - p0) / np.linalg.norm(p1 - p0)
            board(m, p0, p1, 0.07, 0.07, np.array([1.0, 0, 0]))
        wbx(m, xs - 0.04, xs + 0.04, 0.76, 0.82, -0.3, 0.3, along="z")
        wbx(m, xs - 0.03, xs + 0.03, 0.28, 0.34, -0.33, 0.33, along="z")
    # the top: three planks with a slot for the blade
    for (z0, z1) in ((-0.3, -0.11), (-0.105, -0.008), (0.008, 0.105), (0.11, 0.3)):
        wbx(m, -0.8, 0.8, 0.82, 0.865, z0, z1)
    sh.add((0, 0.43, 0), (1.6, 0.86, 0.8))
    # the blade (rip saw, 0.5 m), its guard and its fence
    sub = BM.CModel(seed=722)
    sub.ground = False
    sub.color = (0.55, 0.56, 0.55)
    lathe(sub, "Steel", [(0.004, 0.0), (0.25, 0.0), (0.25, 0.003), (0.004, 0.003)], segs=36, uv_m=2.0)
    m.merge(sub, M=np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]]), t=(0.1, 0.62, -0.0015))
    K.bx(m, "Steel", (0.62, 0.48, 0.12), -0.07, 0.30, 0.89, 0.93, -0.03, 0.03)
    K.bx(m, "Steel", (0.62, 0.48, 0.12), -0.07, -0.05, 0.865, 0.89, -0.03, 0.03)
    wbx(m, -0.75, 0.75, 0.865, 0.925, 0.20, 0.245)
    # the arbor's pulley and belt down to the motor under the bench, the crank on its wheel
    K.tb(m, "Steel", IRON, (0.1, 0.62, -0.03), (0.1, 0.62, -0.08), 0.06, segs=14)
    K.tb(m, "Steel", (0.24, 0.32, 0.26), (-0.35, 0.40, -0.02), (-0.35, 0.40, -0.26), 0.09, segs=14)
    K.tb(m, "Steel", IRON, (-0.35, 0.40, -0.02), (-0.35, 0.40, 0.0), 0.04, segs=10)
    board(m, (0.1, 0.62, -0.065), (-0.35, 0.40, -0.065), 0.025, 0.008, (0, 0, 1.0), col=(0.08, 0.08, 0.08), mat="Rubber")
    sub = BM.CModel(seed=723)
    sub.ground = False
    sub.color = IRON
    lathe(sub, "Steel", [(0.15, 0.0), (0.18, 0.0), (0.18, 0.025), (0.15, 0.025)], segs=24, uv_m=2.0)
    for k in range(4):
        a = k * math.pi / 2
        K.tb(sub, "Steel", IRON, (0, 0.0125, 0), (0.15 * math.cos(a), 0.0125, 0.15 * math.sin(a)), 0.01, segs=6)
    m.merge(sub, M=np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]]), t=(0.72, 0.5, 0.0))
    K.tb(m, "Steel", IRON, (0.745, 0.64, 0.0), (0.775, 0.64, 0.0), 0.012, segs=6)
    wbx(m, 0.775, 0.8, 0.615, 0.665, -0.02, 0.02)
    return m, sh, []


# ── installing into gen_kit_parts ─────────────────────────────────────────────

WOOD_ON = {
    "floor": lambda: w_floor(2.0, 2.0), "floor21": lambda: w_floor(2.0, 1.0), "floor11": lambda: w_floor(1.0, 1.0),
    "wall": lambda: w_wall(), "halfWall": lambda: w_wall(h=1.1), "wall12": lambda: w_wall(-0.5, 0.5),
    "doorWall": lambda: w_doorWall, "windowWall": lambda: w_windowWall, "openFrame": lambda: w_openFrame,
    "roofPitch": lambda: w_roofPitch, "roofRidge": lambda: w_roofRidge, "gable": lambda: w_gable,
    "pillar2": lambda: w_pillar(2.2), "pillar4": lambda: w_pillar(4.4), "beam2": lambda: w_beam(2.0), "beam4": lambda: w_beam(4.0),
    "rail": lambda: w_rail, "catwalk": lambda: w_catwalk, "pier": lambda: w_pier, "ramp": lambda: w_ramp,
    "stairs": lambda: w_stairs(2.4, 3.6, 1.6), "steps": lambda: w_stairs(0.8, 1.0, 1.2), "ladder": lambda: w_stairs(2.4, 2.2, 0.7),
}

TIMBER = {
    "post3": p_post(3.0), "post5": p_post(5.0), "beam6w": p_beam6w, "trussW4": p_trussW4, "deck24": p_deck24,
    "plankFloor": p_plankFloor, "shingleRoof": p_shingleRoof, "fence": p_fence, "hutDoor": p_hutDoor,
    "campMast": p_campMast, "shoring": p_shoring, "sawbench": p_sawbench,
}


def install(Kmod):
    """Add wood to the existing pieces and the TIMBER pieces to gen_kit_parts' tables."""
    global K
    K = Kmod
    K.MATS.update(MATERIALS)
    P = K.PIECES
    base = {}
    for name, mk in WOOD_ON.items():
        fn, mats = P[name]
        base[name] = fn
        wood = mk()

        def g(mat, fn=fn, wood=wood, first=mats[0]):
            if mat == "wood":
                return wood(fn, first)
            return fn(mat)
        P[name] = (g, list(mats) + ["wood"])
    # the Door Wall's mirrored variant: its timber leaf the other way too
    base_m, mats_m = P["doorWallM"]
    wood_m = K.mirrored(lambda mat: w_doorWall(base["doorWall"], "steel"))
    P["doorWallM"] = ((lambda mat, f=base_m: wood_m(mat) if mat == "wood" else f(mat)), list(mats_m) + ["wood"])
    for name, fn in TIMBER.items():
        P[name] = (fn, ["wood"])
    K.FACES2["z"] |= {"hutDoor"}
    # a wall's inside (its "<mat>In" slots, or a MeshIn) asks a lower sky reflectivity than
    # wood's own: keep the lower one
    base_mats_of = K.mats_of

    def mats_of(model, refl=None, wall=False, **kw):
        if not any((n[:-2] if n.endswith("In") else n) in MATERIALS for n in model.parts):
            return base_mats_of(model, refl, wall, **kw) if wall else base_mats_of(model, refl, **kw)

        def one(n):
            inside = bool(wall) and n.endswith("In")
            base = n[:-2] if inside else n
            t = K.MATS[base]()
            r = getattr(K, "INSIDE_REFL", 0.12) if inside else refl
            if base in MATERIALS:
                if r is not None and r < REFL:
                    t = t.replace(f"reflectivity: {REFL},", f"reflectivity: {r},")
            elif r is not None and "shading: Physical" in t:
                t = t.replace("shading: Physical", f"reflectivity: {r},\n                shading: Physical")
            return f'            "{n}": {t}'
        return ",\n".join(one(n) for n in sorted(model.parts.keys()))
    K.mats_of = mats_of
    # (meshfold, 11-11) a wall-class piece's inside is folded into its own model as "<mat>In"
    # slots and moved onto the steel/concrete atlas; timber has no column there, so a timber
    # wall is folded but keeps its own sets (Wood062's boards and the iron's steel): two sets
    if hasattr(K, "fold_inside"):
        base_split = K.paint_split

        def paint_split(piece, m, children):
            if K.faces2_of(piece) != "z" or not any(n in MATERIALS for n in m.parts):
                return base_split(piece, m, children)
            kids = list(children)
            if any(mat in K.UNPAINTED for mat in m.parts):
                m, g = K.split_model(m, lambda mat, c: mat in K.UNPAINTED)
                if g.parts:
                    kids.append(("Glass", "mesh", (g, (0, 0, 0))))
            m, inn = K.split_model(m, lambda mat, c, n: n[2] < -0.5 and c[2] < -(WT / 2) + 1e-3)
            m = K.fold_inside(m, inn)
            m.wall = "fold"
            return m, kids
        K.paint_split = paint_split
    if not os.path.exists(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), TIMBER_ALBEDO)):
        timber_albedo()
