"""The SPACEPORT's structures, as geometry (tools/gen_base.py writes them out).

Every structure is built in metres in a GROUND frame — the ground it stands on
is y = 0, its front (door, sign) faces +Z, the lot centre the layout places is
x = z = 0. Surfaces are three PBR texture sets (Concrete, Clad, Steel, from
tools/base_tex.py) plus Glass, Lamp and the Sign atlas; the paint colour rides
as a vertex colour, darkened and browned toward the ground (`grime`) and
varied a little panel to panel. `zcheck` refuses coplanar overlapping faces.
"""
import math
import traceback

import numpy as np

from gen_part_meshes import Model, box, disk, frame_to, lathe, rot_x, rot_y, rot_z, tube
import base_tex

TAU = 2 * math.pi

# ── paint (linear, multiplied into the texture's near-white albedo) ─────────
PAINT = (0.80, 0.80, 0.78)        # white-painted cladding, weathered
WARM = (0.62, 0.61, 0.57)         # warm grey cladding
GREYBLUE = (0.47, 0.51, 0.55)
SLATE = (0.30, 0.34, 0.39)
DARK = (0.17, 0.18, 0.19)
GREY = (0.43, 0.44, 0.45)
LIGHT = (0.66, 0.67, 0.67)
CONC = (0.95, 0.94, 0.91)         # concrete as cast
CONC_DARK = (0.62, 0.60, 0.57)
SCORCH = (0.32, 0.30, 0.28)
RUST_ORANGE = (0.56, 0.25, 0.12)  # pad tower: a faded international orange
OCHRE = (0.60, 0.46, 0.17)        # crane yellow, faded
SAFETY = (0.70, 0.54, 0.14)
CONT_RED = (0.42, 0.19, 0.14)
CONT_BLUE = (0.25, 0.32, 0.40)
INSUL = (0.76, 0.56, 0.36)        # spray-foam insulation, sun-aged
RUBBER = (0.08, 0.08, 0.08)
LAMP_WARM = (1.0, 0.86, 0.62)
LAMP_COOL = (0.86, 0.92, 1.0)
LAMP_RED = (1.0, 0.12, 0.08)
SCREEN = (0.30, 0.55, 0.90)

UVM = {"Screen": 1.0, "Concrete": 0.25, "Clad": 0.5, "Steel": 1.0, "Glass": 1.0, "Lamp": 2.5, "Sign": 1.0}
GRIMED = {"Concrete", "Clad", "Steel"}


def grime(y):
    """Paint darkens and browns toward the ground (splash, dirt, damp)."""
    t = min(1.0, max(0.0, y / 2.2))
    t = t * t * (3 - 2 * t)
    k = 0.70 + 0.30 * t
    return np.array([k, k * (0.985 + 0.015 * t), k * (0.95 + 0.05 * t)])


class CModel(Model):
    """Model + one RGB per vertex. Set `m.color` before a primitive call; every
    vertex that call adds wears it (times grime, for weathering materials).
    Each call's triangles are tagged, for the z-fight check."""

    def __init__(self, seed=1):
        super().__init__()
        self.cols = {}
        self.tags = {}
        self.color = PAINT
        self.call = 0
        self.rng = np.random.default_rng(seed)
        self.jitter = 1.0
        self.ground = True       # apply grime by height

    def _colors(self, mat, P):
        c = np.tile(np.asarray(self.color, float) * self.jitter, (len(P), 1))
        if mat in GRIMED and self.ground:
            c = c * np.array([grime(y) for y in P[:, 1]])
        return c

    def add(self, mat, P, N, UV, I):
        P = np.asarray(P, np.float64).reshape(-1, 3)
        super().add(mat, P, N, UV, I)
        self.cols.setdefault(mat, []).append(self._colors(mat, P))
        self.call += 1
        self.tags.setdefault(mat, []).append(np.full(len(np.asarray(I).reshape(-1, 3)), self.call))
        self.note()

    def note(self):
        for fr in reversed(traceback.extract_stack()[:-2]):
            if fr.filename.endswith("base_buildings.py"):
                self.__dict__.setdefault("where", {})[self.call] = fr.lineno
                return

    def merge(self, other, M=None, t=(0, 0, 0)):
        for mat, (Ps, Ns, UVs, Is, _) in other.parts.items():
            P = np.vstack(Ps); N = np.vstack(Ns); UV = np.vstack(UVs); I = np.vstack(Is)
            if M is not None:
                P = P @ np.asarray(M).T
                N = N @ np.asarray(M).T
            P = P + np.asarray(t)
            if isinstance(other, CModel):
                C = np.vstack(other.cols[mat])
                if mat in GRIMED and other.ground and self.ground:
                    # a sub-model built at its own origin: grime by where it now stands
                    C = C / np.maximum(np.array([grime(y) for y in np.vstack(Ps)[:, 1]]), 1e-6)
                    C = C * np.array([grime(y) for y in P[:, 1]])
            else:
                C = self._colors(mat, P)
            Model.add(self, mat, P, N, UV, I)
            self.cols.setdefault(mat, []).append(C)
            self.call += 1
            self.tags.setdefault(mat, []).append(np.full(len(I), self.call))
            self.note()

    def shifted(self, d):
        out = CModel()
        for mat, (Ps, Ns, UVs, Is, _) in self.parts.items():
            P = np.vstack(Ps) - np.asarray(d)
            Model.add(out, mat, P, np.vstack(Ns), np.vstack(UVs), np.vstack(Is))
            out.cols[mat] = [np.vstack(self.cols[mat])]
        return out


def zcheck(m, name, verbose=True):
    """Coplanar, same-facing, overlapping triangles from different calls —
    faces that would fight for the same pixels. Returns the count."""
    tris = []
    for mat, (Ps, Ns, UVs, Is, _) in m.parts.items():
        P = np.vstack(Ps); I = np.vstack(Is); T_ = np.concatenate(m.tags[mat])
        A, Bv, C = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
        n = np.cross(Bv - A, C - A)
        ln = np.linalg.norm(n, axis=1)
        ok = ln > 1e-9
        n[ok] /= ln[ok, None]
        for k in np.nonzero(ok)[0]:
            tris.append((n[k], float(n[k] @ A[k]), A[k], Bv[k], C[k], T_[k], mat))
    allT = np.array([[t[2], t[3], t[4]] for t in tris]) if tris else np.zeros((0, 3, 3))
    buckets = {}
    for t in tris:
        key = (tuple(np.round(t[0] * 200).astype(int)), int(round(t[1] * 400)))
        buckets.setdefault(key, []).append(t)
    bad, where = 0, []
    for key, lst in buckets.items():
        if len(lst) < 2 or len({t[5] for t in lst}) < 2:
            continue
        n = lst[0][0]
        a = np.cross(n, [1, 0, 0] if abs(n[0]) < 0.9 else [0, 1, 0]); a /= np.linalg.norm(a)
        b = np.cross(n, a)
        pts = [np.array([[p @ a, p @ b] for p in (t[2], t[3], t[4])]) for t in lst]
        lo = [p.min(0) for p in pts]; hi = [p.max(0) for p in pts]
        for i in range(len(lst)):
            for j in range(i + 1, len(lst)):
                if lst[i][5] == lst[j][5]:
                    continue
                if np.any(lo[i] > hi[j] - 1e-3) or np.any(lo[j] > hi[i] - 1e-3):
                    continue
                if _tri_overlap(pts[i], pts[j]) and not _hidden(allT, lst[i], lst[j]):
                    bad += 1
                    if True:
                        where.append((lst[i][6], lst[j][6], np.round((lst[i][2] + lst[i][3] + lst[i][4]) / 3, 2), np.round(n, 2), m.__dict__.get("where", {}).get(lst[i][5]), m.__dict__.get("where", {}).get(lst[j][5])))
    if verbose and bad:
        print(f"  !! {name}: {bad} coplanar overlapping face pairs (z-fighting), e.g.")
        from collections import Counter
        cnt = Counter((w[0], w[1], w[4], w[5]) for w in where)
        for (a, b, la, lb), k in cnt.most_common():
            ex = next(w for w in where if (w[0], w[1], w[4], w[5]) == (a, b, la, lb))
            print(f"      {k:4d}x  {a}@{la} vs {b}@{lb}  e.g. {ex[2]} n={ex[3]}")
    return bad


def _inside(allT, p, d=np.array([0.5773, 0.5774, 0.5775])):
    """Is p inside the model's solids? A ray's crossings, counted (odd = in)."""
    v0, v1, v2 = allT[:, 0], allT[:, 1], allT[:, 2]
    e1, e2 = v1 - v0, v2 - v0
    h = np.cross(d, e2)
    a = (e1 * h).sum(1)
    ok = np.abs(a) > 1e-12
    f = np.zeros_like(a); f[ok] = 1.0 / a[ok]
    s = p - v0
    u = f * (s * h).sum(1)
    q = np.cross(s, e1)
    v = f * (q @ d)
    t = f * (e2 * q).sum(1)
    hit = ok & (u >= 0) & (u <= 1) & (v >= 0) & (u + v <= 1) & (t > 1e-6)
    return int(hit.sum()) % 2 == 1


def _hidden(allT, a, b):
    """A coplanar pair nobody can see: just in front of it is solid."""
    c = (a[2] + a[3] + a[4]) / 3
    return _inside(allT, c + a[0] * 0.006)


def _tri_overlap(p, q, eps=2e-3):
    for poly in (p, q):
        for k in range(3):
            e = poly[(k + 1) % 3] - poly[k]
            ax = np.array([-e[1], e[0]])
            l = np.linalg.norm(ax)
            if l < 1e-12:
                continue
            ax /= l
            a = p @ ax; b = q @ ax
            if a.max() <= b.min() + eps or b.max() <= a.min() + eps:
                return False
    return True


# ── primitives in the ground frame ──────────────────────────────────────────

class Shell:
    """Collider boxes, in the ground frame: (centre, size, quaternion)."""

    def __init__(self):
        self.boxes = []

    def add(self, c, s, q=(0.0, 0.0, 0.0, 1.0)):
        self.boxes.append((np.asarray(c, float), np.asarray(s, float), q))


def B(m, mat, col, x0, x1, y0, y1, z0, z1, sh=None, uv_m=None, var=True):
    """Axis box from extents; `sh` also makes it a collider. A tall box that
    starts near the ground is split at 2.2 m so the grime gradient stays at
    its foot. `var` gives it a slight panel-to-panel tint variation."""
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    z0, z1 = min(z0, z1), max(z0, z1)
    if -0.01 <= y0 <= 0.16 and y1 > 0.5:
        y0 = -0.35          # footed below the ground: a lifted building never shows a gap
    m.jitter = 1.0 + (m.rng.uniform(-0.035, 0.035) if var and mat in GRIMED else 0.0)
    m.color = col
    uv = uv_m or UVM.get(mat, 1.0)
    if mat in GRIMED and y0 < 1.0 and y1 > 3.2:
        parts = [(y0, 2.2), (2.2, y1)]
    else:
        parts = [(y0, y1)]
    for (a, b) in parts:
        box(m, mat, ((x0 + x1) / 2, (a + b) / 2, (z0 + z1) / 2), (x1 - x0, b - a, z1 - z0), uv_m=uv)
    m.jitter = 1.0
    if sh is not None:
        sh.add(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), (x1 - x0, y1 - y0, z1 - z0))


def T(m, mat, col, p0, p1, r, segs=8, r1=None):
    # The same tube twice (a corner post two railings share) is skipped.
    key = (mat, tuple(np.round(p0, 3)), tuple(np.round(p1, 3)), round(r, 4))
    key2 = (mat, tuple(np.round(p1, 3)), tuple(np.round(p0, 3)), round(r, 4))
    seen = m.__dict__.setdefault("seen_tubes", set())
    if key in seen or key2 in seen:
        return
    seen.add(key)
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    if np.linalg.norm(d) > 0.4 and abs(d[1]) / np.linalg.norm(d) > 0.95:
        lo = p0 if p0[1] < p1[1] else p1
        if -0.01 <= lo[1] <= 0.16:
            lo[1] = -0.35   # (a post standing on the ground goes into it)
    m.color = col
    tube(m, mat, p0, p1, r, segs=segs, r1=r1, uv_m=UVM.get(mat, 1.0))


def region(name):
    return base_tex.REGIONS[name]


def region_aspect(name):
    u0, v0, u1, v1 = region(name)
    return ((v1 - v0) * base_tex.ATLAS_H) / ((u1 - u0) * base_tex.ATLAS)


def cuboid(m, center, right, up, w, h, d, faces=None, mat="Steel", col=DARK):
    """A box spanned by `right` (w), `up` (h) and out = right × up (d), any
    face of which may wear its own (material, colour, atlas region):
    faces = {"front": ("Sign", (1, 1, 1), "hazard")}. Front is +out."""
    faces = faces or {}
    r = np.asarray(right, float); r /= np.linalg.norm(r)
    u = np.asarray(up, float); u /= np.linalg.norm(u)
    o = np.cross(r, u)
    c = np.asarray(center, float)
    hw, hh, hd = w / 2, h / 2, d / 2

    def P(a, b, e):
        return c + r * a * hw + u * b * hh + o * e * hd
    quads = {
        "front": ([P(-1, 1, 1), P(1, 1, 1), P(1, -1, 1), P(-1, -1, 1)], o, (w, h)),
        "back": ([P(1, 1, -1), P(-1, 1, -1), P(-1, -1, -1), P(1, -1, -1)], -o, (w, h)),
        "top": ([P(-1, 1, -1), P(1, 1, -1), P(1, 1, 1), P(-1, 1, 1)], u, (w, d)),
        "bottom": ([P(-1, -1, 1), P(1, -1, 1), P(1, -1, -1), P(-1, -1, -1)], -u, (w, d)),
        "right": ([P(1, 1, 1), P(1, 1, -1), P(1, -1, -1), P(1, -1, 1)], r, (d, h)),
        "left": ([P(-1, 1, -1), P(-1, 1, 1), P(-1, -1, 1), P(-1, -1, -1)], -r, (d, h)),
    }
    for name, (pts, n, (sw, sh_)) in quads.items():
        spec = faces.get(name)
        if spec:
            fm, fc, reg = spec
            u0, v0, u1, v1 = region(reg)
            uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
        else:
            fm, fc = mat, col
            k = UVM.get(mat, 1.0)
            uvs = [(0, 0), (sw * k, 0), (sw * k, sh_ * k), (0, sh_ * k)]
        m.color = fc
        m.add(fm, pts, [n] * 4, uvs, [(0, 1, 2), (0, 2, 3)])


def plate(m, reg, center, right, up, width, depth=0.05, back=DARK):
    """A sign plate standing `depth` proud of what it hangs on: its face IS
    the atlas region, so nothing lies on top of anything."""
    h = width * region_aspect(reg)
    o = np.cross(np.asarray(right, float), np.asarray(up, float))
    c = np.asarray(center, float) + o * depth / 2
    g = m.ground
    m.ground = False
    cuboid(m, c, right, up, width, h, depth, faces={"front": ("Sign", (1, 1, 1), reg)}, col=back)
    m.ground = g
    return h


def emblem(m, center, normal, r, depth=0.06):
    """The agency roundel: a shallow disc whose face is the atlas emblem."""
    u0, v0, u1, v1 = region("emblem")
    n = np.asarray(normal, float); n /= np.linalg.norm(n)
    M = frame_to(n)                          # local +Y → normal
    segs = 40
    P, N, UV, I = [], [], [], []
    for i in range(segs):
        a = TAU * i / segs
        x, z = math.cos(a), math.sin(a)
        P.append(np.asarray(center) + M @ np.array([x * r, depth, z * r]))
        N.append(n)
        UV.append((u0 + (u1 - u0) * (0.5 + 0.5 * x), v0 + (v1 - v0) * (0.5 + 0.5 * z)))
    P.append(np.asarray(center) + M @ np.array([0, depth, 0])); N.append(n)
    UV.append(((u0 + u1) / 2, (v0 + v1) / 2))
    for i in range(segs):
        I.append((segs, (i + 1) % segs, i))
    m.color = (1, 1, 1)
    m.add("Sign", P, N, UV, I)
    sub = CModel(); sub.color = DARK; sub.ground = False
    lathe(sub, "Steel", [(r, 0.0), (r, depth)], segs=segs)
    m.merge(sub, M, center)


def railing(m, col, p0, p1, h=1.1, posts=1.5, sh=None):
    p0 = np.asarray(p0, float); p1 = np.asarray(p1, float)
    if sh is not None:
        d = p1 - p0
        L = np.linalg.norm(d)
        f = d / L
        side = np.cross([0, 1.0, 0], f)
        if np.linalg.norm(side) > 1e-6:
            side /= np.linalg.norm(side)
            up = np.cross(f, side)
            if up[1] < 0:
                up, side = -up, -side
            sh.add((p0 + p1) / 2 + np.array([0, h / 2, 0]), (0.06, h, L), quat_from_basis(np.column_stack([side, up, f])))
    L = np.linalg.norm(p1 - p0)
    n = max(1, int(L / posts))
    for i in range(n + 1):
        p = p0 + (p1 - p0) * i / n
        T(m, "Steel", col, p, p + (0, h, 0), 0.025, segs=6)
    for hh in (h, h * 0.52):
        T(m, "Steel", col, p0 + (0, hh, 0), p1 + (0, hh, 0), 0.022, segs=6)
    T(m, "Steel", col, p0 + (0, 0.12, 0), p1 + (0, 0.12, 0), 0.012, segs=4)


def stair(m, p0, p1, width, col=GREY, rails=True, sh=None):
    """A straight steel stair from p0 (foot, centre) to p1 (head, centre):
    two stringers, a tread every ~0.2 m of rise, handrails both sides."""
    p0 = np.asarray(p0, float); p1 = np.asarray(p1, float)
    d = p1 - p0
    run = np.array([d[0], 0.0, d[2]])
    rl = np.linalg.norm(run)
    f = run / rl
    side = np.cross(f, [0, 1, 0]); side /= np.linalg.norm(side)
    rise = d[1]
    n = max(2, int(rise / 0.2))
    for s in (-1, 1):
        a = p0 + side * s * width / 2
        T(m, "Steel", col, a + (0, 0.12, 0), a + d + (0, 0.12, 0), 0.06, segs=6)
    M = np.column_stack([side, [0, 1, 0], f])
    for k in range(1, n):
        p = p0 + d * (k / n)
        m.color = col
        box(m, "Steel", p + (0, 0.02, 0), (width - 0.14, 0.04, rl / n * 0.92), M=M)
    if sh is not None:
        # the flight is a RAMP to walk on: a slab along the treads' nosing line
        f3 = d / np.linalg.norm(d)
        upn = np.cross(f3, side)
        if upn[1] < 0:
            upn = -upn
        Mr = np.column_stack([side, upn, f3])
        if np.linalg.det(Mr) < 0:
            Mr[:, 0] *= -1
        c = (p0 + p1) / 2 + upn * (0.04 - 0.08)
        sh.add(c, (width, 0.16, np.linalg.norm(d) + 0.2), quat_from_basis(Mr))
        for sgn in (-1, 1):   # and its handrails stop you walking off the side
            a = (p0 + p1) / 2 + side * sgn * (width / 2 + 0.03) + upn * 0.55
            sh.add(a, (0.06, 1.1, np.linalg.norm(d)), quat_from_basis(Mr))
    if rails:
        for s in (-1, 1):
            a = p0 + side * s * (width / 2 + 0.03)
            T(m, "Steel", SAFETY, a + (0, 1.0, 0), a + d + (0, 1.0, 0), 0.025, segs=6)
            for k in range(0, n + 1, max(1, n // 4)):
                q = a + d * (k / n)
                T(m, "Steel", SAFETY, q + (0, 0.14, 0), q + (0, 1.0, 0), 0.022, segs=6)


def lattice_column(m, col, base, top, w, step=3.0, r=0.09, rb=0.05):
    """A square lattice tower: four legs, X bracing on every face."""
    x, y0, z = base
    y1 = top
    hw = w / 2
    corners = [(x - hw, z - hw), (x + hw, z - hw), (x + hw, z + hw), (x - hw, z + hw)]
    for cx, cz in corners:
        T(m, "Steel", col, (cx, y0, cz), (cx, y1, cz), r, segs=8)
    n = max(1, int(round((y1 - y0) / step)))
    for k in range(n):
        ya, yb = y0 + (y1 - y0) * k / n, y0 + (y1 - y0) * (k + 1) / n
        for i in range(4):
            (ax, az), (bx, bz) = corners[i], corners[(i + 1) % 4]
            mx, mz = (ax + bx) / 2 - x, (az + bz) / 2 - z
            ml = math.hypot(mx, mz) or 1.0
            ox, oz = mx / ml * rb * 1.2, mz / ml * rb * 1.2       # the second brace passes outside the first
            T(m, "Steel", col, (ax, ya + 0.1, az), (bx, yb - 0.1, bz), rb, segs=5)
            T(m, "Steel", col, (bx + ox, ya + 0.1, bz + oz), (ax + ox, yb - 0.1, az + oz), rb, segs=5)
            T(m, "Steel", col, (ax, yb, az), (bx, yb, bz), rb * 1.2, segs=5)


def lamp_head(m, p, face, w=1.0, h=0.6, col=LAMP_WARM, housing=DARK):
    """A floodlight or wall pack at p whose lit face points along `face`."""
    face = np.asarray(face, float); face = face / np.linalg.norm(face)
    M = frame_to(face)    # local +Y → face
    g = m.ground
    m.ground = False
    m.color = housing
    box(m, "Steel", np.asarray(p) - face * 0.2, (w, 0.4, h), M=M)
    m.color = col
    box(m, "Lamp", np.asarray(p) + face * 0.01, (w * 0.86, 0.02, h * 0.8), M=M)
    m.ground = g


def wall_pack(m, p, out):
    """A small wall light on a bracket."""
    out = np.asarray(out, float)
    T(m, "Steel", DARK, np.asarray(p), np.asarray(p) + out * 0.3, 0.03, segs=5)
    lamp_head(m, np.asarray(p) + out * 0.45 + np.array([0, -0.1, 0]),
              out * 0.5 + np.array([0, -0.86, 0]), w=0.42, h=0.28)


def hvac(m, x, y, z, w, d, h, fans=2):
    """A packaged air handler: casing, plinth, louvred side, fan shrouds."""
    B(m, "Steel", DARK, x - w / 2 - 0.05, x + w / 2 + 0.05, y + 0.01, y + 0.15, z - d / 2 - 0.05, z + d / 2 + 0.05, var=False)
    y = y + 0.15
    B(m, "Clad", LIGHT, x - w / 2, x + w / 2, y, y + h, z - d / 2, z + d / 2)
    for k in range(fans):
        fx = x - w / 2 + w * (k + 0.5) / fans
        sub = CModel(); sub.color = GREY; sub.ground = False
        r = min(w / fans, d) * 0.36
        lathe(sub, "Steel", [(r, 0.0), (r, 0.32), (r + 0.04, 0.34)], segs=20)
        lathe(sub, "Steel", [(r * 0.98, 0.30), (r * 0.98, 0.0)], segs=20)
        sub.color = DARK
        disk(sub, "Steel", r * 0.97, 0.16, segs=20, up=True)
        for s in range(3):
            a = s * TAU / 3
            box(sub, "Steel", (math.cos(a) * r * 0.45, 0.2, math.sin(a) * r * 0.45), (r * 0.9, 0.02, 0.12), M=rot_y(-a))
        m.merge(sub, None, (fx, y + h, z))
    for k in range(int(w / 0.25) - 1):
        xx = x - w / 2 + 0.25 * (k + 1)
        m.color = GREY
        box(m, "Steel", (xx, y + h * 0.5, z + d / 2 + 0.04), (0.04, h * 0.6, 0.06))


def louvre(m, center, right, w, h, out):
    """A louvred vent panel standing proud of a wall."""
    c = np.asarray(center, float); r = np.asarray(right, float); o = np.asarray(out, float)
    g = m.ground
    m.ground = False
    cuboid(m, c + o * 0.05, r, (0, 1, 0), w, h, 0.10, mat="Steel", col=DARK)
    n = int(h / 0.18)
    M = np.column_stack([r, np.array([0, 1.0, 0]), o])
    tilt = M @ rot_x(math.radians(35))
    for k in range(n):
        y = -h / 2 + (k + 0.5) * h / n
        m.color = GREY
        box(m, "Steel", c + o * 0.17 + np.array([0, y, 0]), (w - 0.06, 0.14, 0.02), M=tilt)
    m.ground = g


def cable_tray(m, p0, p1, w=0.45, col=GREY):
    p0 = np.asarray(p0, float); p1 = np.asarray(p1, float)
    d = p1 - p0
    L = np.linalg.norm(d)
    f = d / L
    up = np.array([0, 1.0, 0]) if abs(f[1]) < 0.9 else np.array([1.0, 0, 0])
    s = np.cross(f, up); s /= np.linalg.norm(s)
    u = np.cross(s, f)
    M = np.column_stack([s, u, f])
    c = (p0 + p1) / 2
    m.color = col
    box(m, "Steel", c, (w, 0.02, L), M=M)
    for k in (-1, 1):
        box(m, "Steel", c + s * k * (w / 2 + 0.01) + u * 0.06, (0.02, 0.14, L), M=M)
    m.color = DARK
    box(m, "Steel", c + u * 0.05, (w - 0.08, 0.06, L - 0.02), M=M)


def bollard(m, x, z, y0=0.0, h=1.1):
    """A steel bollard, safety yellow, a dark cap."""
    T(m, "Steel", SAFETY, (x, y0 - 0.2, z), (x, y0 + h, z), 0.13, segs=12)
    T(m, "Steel", DARK, (x, y0 + h, z), (x, y0 + h + 0.04, z), 0.14, segs=12)


def yagi(m, p, along, n=6, L=1.6):
    p = np.asarray(p, float); a = np.asarray(along, float); a /= np.linalg.norm(a)
    T(m, "Steel", LIGHT, p, p + a * L, 0.02, segs=5)
    side = np.cross(a, [0, 1, 0]); side /= np.linalg.norm(side)
    for k in range(n):
        q = p + a * (L * (k + 0.5) / n)
        el = 0.55 - k * 0.04
        T(m, "Steel", LIGHT, q - side * el / 2, q + side * el / 2, 0.008, segs=4)


def dish(m, center, axis, R, f, col=PAINT, feed=True):
    """A small parabolic dish (both faces) aimed along `axis`."""
    sub = CModel(); sub.color = col; sub.ground = False
    prof = [(r, r * r / (4 * f)) for r in np.linspace(0.0, R, 8)]
    lathe(sub, "Steel", prof, segs=24, smooth=True, inward=True)
    lathe(sub, "Steel", [(r, y - 0.03) for r, y in prof], segs=24, smooth=True)
    lathe(sub, "Steel", [(R, R * R / (4 * f) - 0.03), (R + 0.02, R * R / (4 * f) - 0.015), (R, R * R / (4 * f))], segs=24)
    if feed:
        sub.color = DARK
        for k in range(3):
            a = k * TAU / 3
            p0 = np.array([R * 0.9 * math.cos(a), (R * 0.9) ** 2 / (4 * f), R * 0.9 * math.sin(a)])
            tube(sub, "Steel", p0, (0, f, 0), 0.012, segs=4)
        tube(sub, "Steel", (0, f - 0.05, 0), (0, f + 0.08, 0), 0.05, segs=8)
    m.merge(sub, frame_to(axis), center)


def quat_x(a):
    return (math.sin(a / 2), 0.0, 0.0, math.cos(a / 2))


def quat_from_basis(M):
    """A rotation matrix (columns = the box's local x, y, z) → (x, y, z, w)."""
    m = np.asarray(M, float)
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        return ((m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s)
    if m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return (0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s)
    if m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return ((m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s)
    s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return ((m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s)


def obstruction(m, p, r=0.11):
    """An aviation obstruction light: a dark cast base and a red ribbed glass
    dome — the dome alone glows."""
    p = np.asarray(p, float)
    g = m.ground
    m.ground = False
    T(m, "Steel", DARK, p - (0, 0.16, 0), p, r * 1.15, segs=14)
    T(m, "Steel", GREY, p - (0, 0.035, 0), p - (0, 0.008, 0), r * 1.3, segs=14)
    sub = CModel(); sub.color = LAMP_RED; sub.ground = False
    prof = [(r * math.cos(a), r * 1.3 * math.sin(a)) for a in np.linspace(0, math.pi / 2, 7)]
    lathe(sub, "Lamp", prof, segs=14, smooth=True)
    m.merge(sub, None, p + (0, 0.005, 0))
    m.ground = g
