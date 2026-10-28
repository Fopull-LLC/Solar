"""The crew's hair and the comm cap (tools/gen_faces.py imports this).

HAIR is cards, as games draw it: hundreds of narrow strips, each a clump of
strands (textures/faces/hair_cards.png, alpha-cut), rooted over the scalp
inside the style's hairline and laid along the style's combing — away from
the crown's whorl, off a side parting, swept back, gathered to a bun or a
tail, or short tight curls — lifting off the scalp toward their tips so the
head's outline is soft and broken, not a shell. Under them a thin solid
layer of the same hair (the atlas's last column) so no scalp shows between
clumps. One model per style fits all eight heads: the scalp it grows from is
the largest of the eight (`scalp`).

THE CAP is the suit's old comm cap (tools/gen_suit_blender.py), fitted to the
new heads' scalp: a cloth shell with its white crown and black sides, the ear
cups, two mic booms and a chin strap.
"""
import math

import numpy as np

import gen_faces_base as GB

O = np.array([0.0, 0.0, -0.005])
_SCALP = None


def smooth(a, b, x):
    return GB.smooth(a, b, x)


def unit(v):
    return GB.unit(v)


def dirs(phi, th):
    return np.stack([np.cos(th) * np.sin(phi), np.sin(th), np.cos(th) * np.cos(phi)], -1)


def _shift(R, k):
    """R moved k rows in θ, the edge row repeated (θ does not wrap round:
    the crown is not next to the neck)."""
    out = np.roll(R, k, 0)
    if k > 0:
        out[:k] = R[:1]
    else:
        out[k:] = R[-1:]
    return out


def scalp():
    """r(φ, θ) about O: the largest of the eight heads' skin, binned and
    smoothed (ears excluded: the hair goes over them, not out round them)."""
    global _SCALP
    if _SCALP is not None:
        return _SCALP
    nb = 0.045
    nphi, nth = int(round(2 * np.pi / nb)), int(round(np.pi / nb))
    R = np.zeros((nth, nphi))
    for h in GB.HEADS:
        hd = GB.head(h)
        P = hd["P"]
        ear = (np.abs(P[:, 0]) > 0.066) & (P[:, 1] < 0.035) & (P[:, 1] > -0.045) & (P[:, 2] < 0.03) & (P[:, 2] > -0.045)
        P = P[~ear]
        v = P - O
        r = np.linalg.norm(v, axis=1)
        phi = np.arctan2(v[:, 0], v[:, 2])
        th = np.arcsin(np.clip(v[:, 1] / r, -1, 1))
        i = np.clip(((th + np.pi / 2) / nb).astype(int), 0, nth - 1)
        j = np.clip(((phi + np.pi) / nb).astype(int), 0, nphi - 1)
        np.maximum.at(R, (i, j), r)
    # fill empty bins from their neighbours, then a light blur (wrapping in φ)
    for _ in range(20):
        empty = R <= 0
        if not empty.any():
            break
        Rn = np.maximum.reduce([np.roll(R, 1, 1), np.roll(R, -1, 1), _shift(R, 1), _shift(R, -1)])
        R[empty] = Rn[empty]
    R0 = R.copy()
    for _ in range(2):
        R = (R * 4 + np.roll(R, 1, 1) + np.roll(R, -1, 1) + _shift(R, 1) + _shift(R, -1)) / 8
    # never inside the skin: the blur may not take a bump off; a margin over it
    R = np.maximum(R, np.maximum.reduce([R0, np.roll(R0, 1, 1), np.roll(R0, -1, 1), _shift(R0, 1),
                                         _shift(R0, -1)])) + 0.0012
    _SCALP = (R, nb)
    return _SCALP


def r_scalp(phi, th):
    R, nb = scalp()
    nth, nphi = R.shape
    fi = np.clip((np.asarray(th) + np.pi / 2) / nb - 0.5, 0, nth - 1.001)
    fj = (np.asarray(phi) + np.pi) / nb - 0.5
    i0 = np.floor(fi).astype(int)
    j0 = np.floor(fj).astype(int)
    ti, tj = fi - i0, fj - j0
    j0m, j1m = j0 % nphi, (j0 + 1) % nphi
    i1 = np.minimum(i0 + 1, nth - 1)
    return (R[i0, j0m] * (1 - ti) * (1 - tj) + R[i0, j1m] * (1 - ti) * tj + R[i1, j0m] * ti * (1 - tj)
            + R[i1, j1m] * ti * tj)


def on_scalp(phi, th, lift=0.0):
    return O + dirs(phi, th) * (r_scalp(phi, th) + lift)[..., None]


def to_angles(p):
    v = np.asarray(p, float) - O
    r = np.linalg.norm(v, axis=-1)
    return np.arctan2(v[..., 0], v[..., 2]), np.arcsin(np.clip(v[..., 1] / r, -1, 1))


def hairline(phi, th, kind):
    """Coverage 0..1 at (φ, θ) for a hairline `kind`: over the forehead,
    down the temples, a sideburn before the ear, up over it, down the nape."""
    a = np.abs(phi)
    edge = np.interp(a, [0.0, 0.45, 0.85, 1.12, 1.30, 1.40, 1.55, 1.95, 2.25, np.pi],
                     [0.70, 0.67, 0.52, 0.34, 0.02, -0.10, 0.36, 0.34, -0.12, -0.50])
    if kind == "high":           # receding at the temples
        edge = edge + np.interp(a, [0.0, 0.35, 0.65, 0.95, 1.2], [0.06, 0.10, 0.20, 0.12, 0.0])
    if kind == "low":
        edge = edge - np.interp(a, [0.0, 0.8, 1.2], [0.05, 0.04, 0.0])
    # a real hairline is never a clean curve: a little irregular along it
    edge = edge + 0.012 * np.sin(phi * 23.0) + 0.008 * np.sin(phi * 41.0 + 1.3)
    return smooth(edge - 0.03, edge + 0.07, th)


def hairline_edge(phi, kind="normal"):
    """θ of the hairline's middle at azimuth φ (the skin shader's scalp fade)."""
    a = np.abs(phi)
    edge = np.interp(a, [0.0, 0.45, 0.85, 1.12, 1.30, 1.40, 1.55, 1.95, 2.25, np.pi],
                     [0.70, 0.67, 0.52, 0.34, 0.02, -0.10, 0.36, 0.34, -0.12, -0.50])
    return edge + 0.02


# ── styles ──────────────────────────────────────────────────────────────────
# length (m), lift (how far clumps stand off the scalp at their tips),
# width of a clump, how many roots, the combing, the hairline
STYLES = {
    "buzz":     dict(line="normal", length=0.007, lift=0.0010, width=0.005, n=1540, flow="crown", shell=0.0008),
    "crop":     dict(line="normal", length=0.030, lift=0.0030, width=0.006, n=1400, flow="crown", shell=0.0012),
    "side":     dict(line="normal", length=0.075, lift=0.0055, width=0.007, n=1330, flow="part", shell=0.0015),
    "swept":    dict(line="high", length=0.070, lift=0.0050, width=0.007, n=1330, flow="back", shell=0.0015),
    "bun":      dict(line="low", length=0.110, lift=0.0030, width=0.007, n=1330, flow="gather", gather=(0.0, 0.06, -0.105),
                     bun=True, shell=0.0012),
    "tail":     dict(line="low", length=0.110, lift=0.0030, width=0.007, n=1330, flow="gather", gather=(0.0, 0.025, -0.11),
                     tail=True, shell=0.0012),
    "curls":    dict(line="normal", length=0.020, lift=0.0065, width=0.008, n=1680, flow="curl", shell=0.0035),
    "receding": dict(line="high", length=0.020, lift=0.0028, width=0.006, n=1120, flow="crown", thin=True, shell=0.0009),
}
CROWN = np.array([0.0, 0.12, -0.045])
ATLAS_COLS = 5            # card columns 0..2 (clumps), 3 (fine, sparse: the hairline), the solid layer in 4
FINE, SOLID = 3, 4


def flow_dir(p, n, st, rng):
    """The combing at point p (unit, tangent to the scalp; n the scalp's
    outward normal there)."""
    f = st["flow"]
    if f == "crown":
        d = p - CROWN
        d[1] -= 0.02                                  # and down
    elif f == "part":
        side = 1.0 if p[0] > 0.028 else -1.0
        d = np.array([side * 1.0, -0.6, 0.15 if p[2] > 0.0 else -0.2])
        if p[1] < 0.06:
            d = np.array([side * 0.3, -1.0, -0.15])
    elif f == "back":
        d = np.array([0.0, -0.35, -1.0]) + np.array([p[0] * 2.0, 0, 0])
        if p[1] < 0.0:
            d = np.array([p[0] * 2.0, -1.0, -0.4])
    elif f == "gather":
        d = np.asarray(st["gather"]) - p
    else:                                             # curls: any way
        a = rng.random() * 2 * np.pi
        d = np.array([math.cos(a), math.sin(a), rng.random() - 0.5])
    d = d - n * (d @ n)
    if np.linalg.norm(d) < 1e-6:
        d = np.cross(n, [1.0, 0, 0])
    return unit(d)


def card(root_phi, root_th, st, rng, col):
    """One clump: a strip from the root along the combing, kept on the
    scalp and lifting toward its tip. (points, faces, uvs)"""
    segs = 3 if st["length"] < 0.01 else 5
    L = st["length"] * (0.7 + 0.6 * rng.random())
    w = st["width"] * 1.2 * (0.75 + 0.5 * rng.random())
    phi, th = root_phi, root_th
    pts, sides = [], []
    p = on_scalp(phi, th, 0.0005)
    for k in range(segs + 1):
        u = k / segs
        n = unit(p - O)
        d = flow_dir(p, n, st, rng)
        if st["flow"] == "curl":                       # a curl turns as it goes
            d = unit(d + np.cross(n, d) * math.sin(u * 5 + rng.random()))
        lift = 0.0006 + st["lift"] * u ** 0.8
        ph, tt = to_angles(p)
        q = on_scalp(ph, tt, lift)
        pts.append(q)
        sides.append(unit(np.cross(n, d)))
        p = q + d * (L / segs)
    P, UV, F = [], [], []
    u0 = (col + 0.04) / ATLAS_COLS
    u1 = (col + 0.96) / ATLAS_COLS
    for k, (q, s) in enumerate(zip(pts, sides)):
        taper = 1.0 - 0.45 * (k / segs)
        P.append(q - s * w * 0.5 * taper)
        P.append(q + s * w * 0.5 * taper)
        v = k / segs
        UV += [(u0, v), (u1, v)]
    for k in range(segs):
        a = 2 * k
        F.append((a, a + 1, a + 3, a + 2))
    return P, F, UV


def solid_layer(st, rng):
    """The hair's solid under-layer: the base head's own scalp faces inside
    the hairline, lifted off the skin (so its edge is as fine as the head's
    mesh, not a coarse grid's staircase) and sunk under the skin past the
    hairline. The ears are left out: short hair goes round them."""
    b = GB.base()
    P, Q = b["P"], b["Q"]
    phi, th = to_angles(P)
    cov = hairline(phi, th, st["line"])
    ear = (np.abs(P[:, 0]) > 0.062) & (P[:, 1] < 0.03) & (P[:, 1] > -0.05) & (P[:, 2] < 0.035) & (P[:, 2] > -0.05)
    cov = np.where(ear, 0.0, cov)
    keep = cov[Q].max(1) > 0.02
    Qk = Q[keep]
    used = np.unique(Qk)
    remap = -np.ones(len(P), int)
    remap[used] = np.arange(len(used))
    # vertex normals of the base
    N = np.zeros_like(P)
    for a_, b_, c_, d_ in Q:
        n = np.cross(P[c_] - P[a_], P[d_] - P[b_])
        N[[a_, b_, c_, d_]] += n
    N = unit(N)
    # the solid layer stops well inside the hairline (it meets the skin
    # where coverage is ~0.7): the last stretch is fine cards over the
    # skin's own scalp shading (face_skin.flsl), not an opaque edge
    c = smooth(0.62, 1.0, cov[used])
    off = -0.005 + (0.005 + 0.0012 + st["shell"]) * c ** 0.5
    Pv = P[used] + N[used] * off[:, None]
    # strands run down the head: u round it (continuous, a seam every 60°,
    # under the clumps), v down from the crown
    UVv = [((SOLID + 0.05 + 0.9 * (((phi[k] + np.pi) / (2 * np.pi) * 6) % 1.0)) / ATLAS_COLS,
            min(0.99, max(0.01, (1.57 - th[k]) / 2.3))) for k in used]
    F = [tuple(remap[q]) for q in Qk]
    return Pv, F, UVv


def hair_mesh(name):
    st = STYLES[name]
    rng = np.random.default_rng(abs(hash(name)) % 2 ** 31 if False else sum(map(ord, name)))
    P, F, UV = [], [], []

    def add(Pp, Ff, UVv, flip_out=True):
        n0 = len(P)
        P.extend(Pp)
        UV.extend(UVv)
        F.extend(tuple(i + n0 for i in f) for f in Ff)
    Ps, Fs, UVs = solid_layer(st, rng)
    add(list(Ps), Fs, UVs)
    # roots: jittered over the coverage, a little denser on top
    roots = []
    tries = 0
    while len(roots) < st["n"] and tries < st["n"] * 40:
        tries += 1
        ph = rng.uniform(-np.pi, np.pi)
        th = np.arcsin(rng.uniform(np.sin(-0.55), 1.0))
        c = hairline(np.array(ph), np.array(th), st["line"])
        if st.get("thin"):
            c = c * (1 - 0.7 * np.exp(-((th - 1.25) / 0.25) ** 2))
        if rng.random() < c - 0.05:
            roots.append((ph, th))
    for k, (ph, th) in enumerate(roots):
        c = float(hairline(np.array(ph), np.array(th), st["line"]))
        if c < 0.85:
            # near the hairline: finer, sparser, shorter clumps
            st2 = dict(st, length=st["length"] * (0.45 + 0.4 * c), width=st["width"] * 0.8)
            Pc, Fc, UVc = card(ph, th, st2, rng, FINE)
        else:
            Pc, Fc, UVc = card(ph, th, st, rng, k % 3)
        add(Pc, Fc, UVc)
    # baby hairs: short fine wisps along the hairline itself, lying down,
    # growing out of the skin past the edge of the mass
    edge, tries = 0, 0
    want = int(st["n"] * 0.45)
    while edge < want and tries < want * 60:
        tries += 1
        ph = rng.uniform(-np.pi, np.pi)
        th = np.arcsin(rng.uniform(np.sin(-0.55), 1.0))
        c = float(hairline(np.array(ph), np.array(th), st["line"]))
        if 0.04 < c < 0.7:
            st2 = dict(st, length=min(0.012, st["length"] * 0.5) * (0.6 + 0.8 * c), width=st["width"] * 0.7,
                       lift=0.0006)
            if st["flow"] in ("gather", "back"):
                st2["flow"] = "crown"          # pulled-back hair still has its short hairs lying forward
            Pc, Fc, UVc = card(ph, th, st2, rng, FINE)
            add(Pc, Fc, UVc)
            edge += 1
    P = np.array(P)
    # a bun or a tail: clumps wound round a knot
    if st.get("bun"):
        c = np.asarray(st["gather"], float)
        for k in range(160):
            a = rng.random() * 2 * np.pi
            b = rng.uniform(-1.1, 1.1)
            n = unit(np.array([math.cos(a) * math.cos(b), math.sin(b), -0.6 - 0.4 * math.sin(a) * math.cos(b)]))
            t = unit(np.cross(n, [0, 0, 1.0]) + np.cross(n, [0, 1.0, 0]) * (rng.random() - 0.5))
            q = c + n * 0.022
            s = unit(np.cross(n, t))
            segs = 4
            Pc, UVc, Fc = [], [], []
            for i in range(segs + 1):
                ang = i / segs * 1.6
                qq = c + (n * math.cos(ang) + t * math.sin(ang)) * (0.021 + 0.002 * rng.random())
                Pc += [qq - s * 0.006, qq + s * 0.006]
                col = k % 3
                UVc += [((col + 0.04) / ATLAS_COLS, i / segs * 0.8), ((col + 0.96) / ATLAS_COLS, i / segs * 0.8)]
            Fc = [(2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2) for i in range(segs)]
            n0 = len(P)
            P = np.vstack([P, Pc])
            UV.extend(UVc)
            F.extend(tuple(x + n0 for x in f) for f in Fc)
            del q
    if st.get("tail"):
        c = np.asarray(st["gather"], float)
        for k in range(140):
            a = rng.random() * 2 * np.pi
            off = np.array([math.cos(a), 0, math.sin(a) * 0.7]) * 0.007 * rng.random()
            path = [c + off, c + off + [0, -0.035, -0.02], c + off * 1.6 + [0, -0.08, -0.028],
                    c + off * 1.2 + [0, -0.125, -0.022]]
            s = unit(np.array([math.cos(a + 1.57), 0, math.sin(a + 1.57)]))
            Pc, UVc = [], []
            for i, q in enumerate(path):
                taper = 1 - 0.5 * i / 3
                Pc += [q - s * 0.006 * taper, q + s * 0.006 * taper]
                col = k % 3
                UVc += [((col + 0.04) / ATLAS_COLS, i / 3), ((col + 0.96) / ATLAS_COLS, i / 3)]
            Fc = [(2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2) for i in range(3)]
            n0 = len(P)
            P = np.vstack([P, Pc])
            UV.extend(UVc)
            F.extend(tuple(x + n0 for x in f) for f in Fc)
    # every clump faces out (cards are one-sided: wound away from the head)
    F2 = []
    for f in F:
        a, b, c3 = P[f[0]], P[f[1]], P[f[2]]
        nrm = np.cross(b - a, c3 - a)
        if np.linalg.norm(nrm) < 1e-14 and len(f) == 4:
            nrm = np.cross(c3 - a, P[f[3]] - a)
        F2.append(f if nrm @ ((a + b + c3) / 3 - O) >= 0 else tuple(reversed(f)))
    # normals: the scalp's (a clump is lit as the head's surface, which is
    # how hair cards read as a mass)
    N = unit(P - O - np.array([0, 0.02, 0]))
    return P, N, np.array(UV, float), F2


def hair_texture(n=640, seed=7):
    """The cards' atlas: 4 columns, 3 of loose clumps (alpha-cut strands,
    root at v = 0, tapering tips toward v = 1) and a solid one."""
    rng = np.random.default_rng(seed)
    img = np.zeros((n, n, 4))
    cw = n // ATLAS_COLS
    yy = np.arange(n)[:, None]
    for col in range(ATLAS_COLS):
        x0 = col * cw
        solid = col == SOLID
        fine = col == FINE
        k = 260 if solid else (34 if fine else 110)
        for _ in range(k):
            cx = x0 + rng.uniform(3, cw - 3)
            ln = 1.0 if solid else (rng.uniform(0.35, 0.9) if fine else rng.uniform(0.55, 1.0))
            wv = rng.uniform(0.5, 2.5)
            ph = rng.uniform(0, 6.3)
            wd = rng.uniform(0.35, 0.7) if fine else rng.uniform(0.45, 1.0)
            br = rng.uniform(0.62, 1.0)
            ys = np.arange(n)
            v = ys / n
            xs = cx + wv * np.sin(v * rng.uniform(3, 9) + ph) + (0 if solid else (v ** 1.5) * rng.uniform(-6, 6))
            for y in ys:
                if v[y] > ln:
                    break
                tip = 1.0 if solid else smooth(ln, ln - 0.25, v[y])
                xa = xs[y]
                lo, hi = int(xa - wd - 1), int(xa + wd + 2)
                for x in range(max(x0, lo), min(x0 + cw, hi)):
                    cov = max(0.0, 1 - abs(x + 0.5 - xa) / wd) * tip
                    if cov <= 0:
                        continue
                    a0 = img[y, x, 3]
                    img[y, x, :3] = img[y, x, :3] * (1 - cov) + br * cov
                    img[y, x, 3] = a0 + (1 - a0) * cov
        if solid:
            img[:, x0:x0 + cw, 3] = 1.0
            under = img[:, x0:x0 + cw, :3]
            img[:, x0:x0 + cw, :3] = np.maximum(under, 0.3)
    # roots darker (shade toward the scalp), alpha a little denser there
    root = 1 - 0.35 * smooth(0.25, 0.0, yy / n)             # (n, 1)
    img[..., :3] *= root[..., None]
    img[..., 3] = np.clip(img[..., 3] * (1 + 0.6 * smooth(0.3, 0.0, yy / n)), 0, 1)
    return img


# ── the comm cap ────────────────────────────────────────────────────────────
CAP_W = (0.86, 0.85, 0.82)
CAP_B = (0.13, 0.13, 0.14)
SHELL_D = (0.30, 0.31, 0.32)


def cap_mesh(tube, cylinder, bezier, normals, tris, orient):
    """The comm cap on the scalp: (parts per material) as gen_faces writes
    statics. The shapes' helpers come from gen_faces."""
    S = np.linspace(-np.pi, np.pi, 73)
    T = np.linspace(-0.7, np.pi / 2 - 0.03, 34)
    ss, tt = np.meshgrid(S, T)
    a = np.abs(ss)
    face = (a < 1.1) & (tt < 0.52)
    low = tt < -0.36 - 0.25 * np.clip((a - 1.6) / 1.5, 0, None)
    keep = ~(face | low)
    P = on_scalp(ss, tt, 0.0045 + 0.0015 * smooth(0.3, 1.2, tt))
    parts = {}

    def add(mat, P_, F_, C_):
        e = parts.setdefault(mat, dict(P=[], N=[], UV=[], C=[], I=[], n=0))
        P_ = np.asarray(P_, float)
        e["P"].append(P_)
        e["N"].append(normals(P_, F_))
        e["UV"].append(np.zeros((len(P_), 2)))
        e["C"].append(np.asarray(C_, float))
        e["I"].append(tris(F_) + e["n"])
        e["n"] += len(P_)
    nt, ns = ss.shape
    for side in (False, True):
        Pv, Cv, F = [], [], []
        idx = {}
        for i in range(nt - 1):
            for j in range(ns - 1):
                q = [(i, j), (i, j + 1), (i + 1, j + 1), (i + 1, j)]
                if not all(keep[x] for x in q):
                    continue
                sm = np.mean([ss[x] for x in q])
                is_side = 0.55 < abs(sm) < 2.6 and np.mean([tt[x] for x in q]) < 1.0
                if is_side != side:
                    continue
                ids = []
                for x in q:
                    if x not in idx:
                        idx[x] = len(Pv)
                        Pv.append(P[x])
                        Cv.append(CAP_B if side else CAP_W)
                    ids.append(idx[x])
                F.append(tuple(ids))
        if not side:
            cp = len(Pv)
            Pv.append(on_scalp(np.array(0.0), np.array(np.pi / 2), 0.006))
            Cv.append(CAP_W)
            for j in range(ns - 1):
                x0, x1 = (nt - 1, j), (nt - 1, j + 1)
                if x0 in idx and x1 in idx:
                    F.append((cp, idx[x0], idx[x1]))
        Pv = np.array(Pv)
        add("CapCloth", Pv, orient(Pv, F, O), Cv)
    for sx in (-1, 1):
        ec = on_scalp(np.array(sx * 1.72), np.array(-0.05), 0.006)
        out = unit(ec - O)
        Pc, Fc = cylinder(ec - out * 0.004, ec + out * 0.018, 0.031, 0.027, 14)
        add("CapShell", Pc, Fc, [SHELL_D] * len(Pc))
        tip = np.array([sx * 0.036, -0.058, 0.092])
        pts = [ec + out * 0.012, ec + out * 0.012 + np.array([0, -0.02, 0.05]), tip]
        path = bezier(pts, 8)
        Pb, Fb = tube(path, 0.0035, 6)
        add("CapShell", Pb, Fb, [SHELL_D] * len(Pb))
        d = unit(pts[2] - pts[1])
        Pm, Fm = cylinder(tip - d * 0.004, tip + d * 0.014, 0.008, 0.008, 10)
        add("CapShell", Pm, Fm, [(0.08, 0.08, 0.085)] * len(Pm))
    ecL = on_scalp(np.array(1.72), np.array(-0.05), 0.006)
    ecR = ecL * np.array([-1, 1, 1])
    pts = [ecR + [0.0, -0.02, 0.0], np.array([-0.05, -0.11, 0.03]), np.array([0.0, -0.126, 0.055]),
           np.array([0.05, -0.11, 0.03]), ecL + [0.0, -0.02, 0.0]]
    Ps, Fs = tube(bezier(pts, 12), 0.004, 6, flat=2.2)
    add("CapCloth", Ps, Fs, [CAP_B] * len(Ps))
    return parts
