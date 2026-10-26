"""Model the crew's EVA suit in Blender (headless) — the geometry half of
tools/gen_suit.py, which runs this and writes the glbs.

    blender --background --factory-startup --python tools/gen_suit_blender.py -- RIG.glb OUT.npz

RIG.glb is the suit being replaced (only its skeleton is read). OUT.npz holds
every piece's triangles in the AUTHORING pose (see gen_suit.py): positions,
corner normals, UVs, vertex colours, four bone weights per vertex, the
material, which glb it belongs to (the suit, or the helmet / visor / lamps the
game can take off), and the authoring pose itself (`D`), so gen_suit.py can
take it all back to bind space and write it on the untouched rig.

WHY BLENDER. The first suit was numpy lofts, and it read as a toy: tubes of one
radius, a box for a torso, a box for a pack. Here the hard parts are MODELLED —
primitives fused by a voxel remesh (fillets where a scye housing grows out of
the torso, where the pack's top hump meets its case), relaxed with a volume-
preserving smooth, decimated to budget and given crisp edges by angle — and
the soft parts are subdivided lofts with the cloth's own irregularity built
into each ring (gathers at the shoulders, sag under the elbows and knees, a
seat that hangs). Skin weights ride the cages as vertex groups, which
subdivision interpolates, so the weighting is designed per ring, not painted.

COORDINATES are the glTF bind space throughout: +X the crew's left, +Y up, +Z
forward, metres, the 1.87 m male rig (every length scales with the rig, `k`).

REFERENCE (NASA EMU / A7L figures, rounded): HUT about 0.42 m across the chest,
0.30 m deep, its scye bearings near 0.19 m bore set into the upper corners and
canted down and forward; a 0.26 m neck ring tilted forward; the PLSS 0.50 ×
0.62 × 0.18 m with the SOP under it, its top level with the neck ring; the
helmet's EVVA about 0.34 m across; upper arm 0.15 m, the wrist disconnect
0.12 m; thigh 0.21 m, knee 0.18 m, calf 0.17 m; boots 0.31 m long, 0.12 m
wide; the DCM 0.24 × 0.11 × 0.12 m on the lower chest, its control face tilted
up toward the wearer's eyes.
"""
import json
import math
import os
import struct
import sys

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

TAU = 2 * math.pi
X, Y, Z = np.eye(3)
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RIG_PATH, OUT_PATH = argv[0], argv[1]

AUTHOR_ABDUCT = 50.0      # the arms are modelled this far down from the rig's T
SCYE_BORE = 0.088         # the scye bearing's bore (radius, m on the male rig)


# ═════════════════════════════════════════════════════════════════════════════
# the rig (read only)
# ═════════════════════════════════════════════════════════════════════════════

def read_glb(path):
    b = open(path, "rb").read()
    jl = struct.unpack("<I", b[12:16])[0]
    j = json.loads(b[20:20 + jl])
    off = 20 + jl
    bl = struct.unpack("<I", b[off:off + 4])[0]
    return j, b[off + 8:off + 8 + bl]


class Rig:
    def __init__(self, path):
        j, B = read_glb(path)
        skin = j["skins"][0]
        a = j["accessors"][skin["inverseBindMatrices"]]
        v = j["bufferViews"][a["bufferView"]]
        o = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        ibm = np.frombuffer(B[o:o + 64 * a["count"]], np.float32).reshape(-1, 4, 4).transpose(0, 2, 1)
        self.names = [j["nodes"][k]["name"] for k in skin["joints"]]
        self.index = {n: i for i, n in enumerate(self.names)}
        self.bind = {n: np.linalg.inv(m.astype(np.float64)) for n, m in zip(self.names, ibm)}

    def p(self, name):
        return self.bind[name][:3, 3].copy()


def rot_about(axis, deg, pivot):
    a = np.asarray(axis, float) / np.linalg.norm(axis)
    th = math.radians(deg)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    R = np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * K @ K
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = np.asarray(pivot) - R @ np.asarray(pivot)
    return M


def unit(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def smooth01(a, b, x):
    t = np.clip((np.asarray(x, float) - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return np.asarray(a, float) + (np.asarray(b, float) - np.asarray(a, float)) * t


def blend(a, b, t):
    t = float(t)
    if a == b or t <= 0.0:
        return {a: 1.0}
    if t >= 1.0:
        return {b: 1.0}
    return {a: 1.0 - t, b: t}


# ═════════════════════════════════════════════════════════════════════════════
# pieces: what a Blender object is built from and what it exports as
# ═════════════════════════════════════════════════════════════════════════════

PIECES = []
COL = None


class Piece:
    """One Blender object. `W` is a {bone: w} for the whole piece, a list of
    them per vertex, or a callable(P) -> list (for remeshed pieces, whose
    vertices are new). `C` likewise: an rgb, an N×3 array, or callable(P, N).
    `UVc` per face corner (a list per face) or None for a box projection in
    tiles of `tile` metres. `part` names the glb: suit, helmet, visor, lamps."""

    def __init__(self, name, mat, V, F, W, C, UVc=None, part="suit", tile=0.25, dirt="body",
                 sharp=None, smooth=True, mods=()):
        self.name, self.mat, self.part, self.tile, self.dirt = name, mat, part, tile, dirt
        self.W, self.C = W, C
        self.sharp = sharp
        V = np.asarray(V, float)
        me = bpy.data.meshes.new(name)
        me.from_pydata(V.tolist(), [], [list(map(int, f)) for f in F])
        me.update()
        if UVc is not None:
            uv = me.uv_layers.new(name="uv")
            flat = [c for f in UVc for c in f]
            uv.data.foreach_set("uv", np.asarray(flat, np.float32).reshape(-1))
            self.uvmode = "given"
        else:
            self.uvmode = "box"
        if smooth:
            me.shade_smooth()
        ob = bpy.data.objects.new(name, me)
        COL.objects.link(ob)
        self.ob = ob
        if isinstance(W, list):
            groups = {}
            for i, wd in enumerate(W):
                for b, w in wd.items():
                    if w > 1e-5:
                        groups.setdefault(b, {}).setdefault(round(w, 5), []).append(i)
            for b, by_w in groups.items():
                vg = ob.vertex_groups.new(name=b)
                for w, ids in by_w.items():
                    vg.add(ids, w, "REPLACE")
        if not callable(C) and np.asarray(C).ndim == 2:
            ca = me.color_attributes.new("col", "FLOAT_COLOR", "POINT")
            cc = np.hstack([np.asarray(C, float), np.ones((len(V), 1))]).astype(np.float32)
            ca.data.foreach_set("color", cc.reshape(-1))
        for m in mods:
            self.mod(*m)
        PIECES.append(self)

    def mod(self, kind, *a):
        ob = self.ob
        if kind == "subsurf":
            m = ob.modifiers.new("subsurf", "SUBSURF")
            m.levels = m.render_levels = a[0]
            m.uv_smooth = "PRESERVE_BOUNDARIES"
        elif kind == "remesh":
            m = ob.modifiers.new("remesh", "REMESH")
            m.mode = "VOXEL"
            m.voxel_size = a[0]
            m.use_smooth_shade = True
        elif kind == "smooth":   # a volume-keeping relax
            m = ob.modifiers.new("smooth", "LAPLACIANSMOOTH")
            m.lambda_factor = a[0]
            m.iterations = a[1]
            m.use_volume_preserve = True
            m.use_normalized = True
        elif kind == "plainsmooth":
            m = ob.modifiers.new("psmooth", "SMOOTH")
            m.factor = a[0]
            m.iterations = a[1]
        elif kind == "decimate":
            self.apply()
            n = sum(len(p.vertices) - 2 for p in ob.data.polygons)
            m = ob.modifiers.new("decimate", "DECIMATE")
            m.decimate_type = "COLLAPSE"
            m.ratio = min(1.0, a[0] / max(1, n))
            m.use_collapse_triangulate = True
        elif kind == "bevel":
            m = ob.modifiers.new("bevel", "BEVEL")
            m.width = a[0]
            m.segments = a[1]
            m.limit_method = "ANGLE"
            m.angle_limit = math.radians(a[2] if len(a) > 2 else 40)
            m.harden_normals = False
        elif kind == "bool":
            m = ob.modifiers.new("bool", "BOOLEAN")
            m.operation = a[0]
            m.object = a[1].ob
            m.solver = "EXACT"
        self.apply()

    def apply(self):
        ob = self.ob
        if not ob.modifiers:
            return
        dg = bpy.context.evaluated_depsgraph_get()
        ev = ob.evaluated_get(dg)
        me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=dg)
        old = ob.data
        ob.modifiers.clear()
        ob.data = me
        bpy.data.meshes.remove(old)


def bvh(piece):
    piece.apply()
    me = piece.ob.data
    V = [v.co.copy() for v in me.vertices]
    P = [list(p.vertices) for p in me.polygons]
    return BVHTree.FromPolygons(V, P)


def surf_point(tree, origin, direction, fallback):
    hit = tree.ray_cast(Vector(origin), Vector(direction))
    if hit[0] is None:
        return np.asarray(fallback, float), np.asarray(direction, float) * -1
    return np.array(hit[0]), np.array(hit[1])


# ── cages ──────────────────────────────────────────────────────────────────

def ring_pts(c, e1, e2, r1, r2, segs, sq=2.0, a0=0.0, rad=None):
    out = []
    for i in range(segs):
        a = a0 + TAU * i / segs
        ca, sa = math.cos(a), math.sin(a)
        x = math.copysign(abs(ca) ** (2.0 / sq), ca)
        y = math.copysign(abs(sa) ** (2.0 / sq), sa)
        p = c + e1 * (r1 * x) + e2 * (r2 * y)
        if rad is not None:
            d = e1 * (r1 * x) + e2 * (r2 * y)
            p = p + d / max(np.linalg.norm(d), 1e-9) * rad(a)
        out.append(p)
    return out


def loft(rings, segs, cap0=False, cap1=False, a0=0.0, tile=0.25):
    """Quads through closed rings (dicts: c, e1, e2, r1, r2[, sq, rad(a), w,
    w_in + inner, col]), outward faces, corner UVs in `tile` metres (u round,
    v along), and per-vertex weights and colours. Returns V, F, UVc, W, C."""
    V, W, C = [], [], []
    vacc, prev = 0.0, None
    circ = max(TAU * math.sqrt((r["r1"] ** 2 + r["r2"] ** 2) / 2) for r in rings)
    ut = max(1, round(circ / tile))
    vs = []
    for r in rings:
        c = np.asarray(r["c"], float)
        e1, e2 = np.asarray(r["e1"], float), np.asarray(r["e2"], float)
        pts = ring_pts(c, e1, e2, r["r1"], r["r2"], segs, r.get("sq", 2.0), a0, r.get("rad"))
        if prev is not None:
            vacc += float(np.linalg.norm(c - prev))
        prev = c
        vs.append(vacc / tile)
        for i, p in enumerate(pts):
            V.append(p)
            ang = a0 + TAU * i / segs
            col = r.get("col", (1, 1, 1))
            C.append(col(ang) if callable(col) else col)
            if "w_in" in r:
                rad_ = p - c
                f = float(smooth01(-0.15, 0.55, float(rad_ @ np.asarray(r["inner"])) / max(np.linalg.norm(rad_), 1e-9)))
                wd = {}
                for b_, w_ in r["w"].items():
                    wd[b_] = wd.get(b_, 0.0) + (1 - f) * w_
                for b_, w_ in r["w_in"].items():
                    wd[b_] = wd.get(b_, 0.0) + f * w_
                W.append(wd)
            else:
                W.append(dict(r["w"]))
    n = segs
    F, UVc = [], []
    for k in range(len(rings) - 1):
        for i in range(segs):
            j = (i + 1) % segs
            F.append((k * n + i, k * n + j, (k + 1) * n + j, (k + 1) * n + i))
            u0, u1 = i / segs * ut, (i + 1) / segs * ut
            UVc.append([(u0, vs[k]), (u1, vs[k]), (u1, vs[k + 1]), (u0, vs[k + 1])])
    V = np.array(V)
    # orient outward (from each ring's centre)
    if F:
        a, b, c_ = V[F[0][0]], V[F[0][1]], V[F[0][2]]
        nrm = np.cross(b - a, c_ - a)
        if nrm @ (a - np.asarray(rings[0]["c"], float)) < 0:
            F = [tuple(reversed(f)) for f in F]
            UVc = [list(reversed(u)) for u in UVc]
    for which, on in ((0, cap0), (len(rings) - 1, cap1)):
        if not on:
            continue
        r = rings[which]
        ci = len(V)
        V = np.vstack([V, np.asarray(r["c"], float)[None]])
        W.append(dict(r["w"]))
        col = r.get("col", (1, 1, 1))
        C.append(col(0.0) if callable(col) else col)
        nb = rings[1 if which == 0 else which - 1]["c"]
        out = np.asarray(r["c"], float) - np.asarray(nb, float)
        for i in range(segs):
            j = (i + 1) % segs
            f = (ci, which * n + i, which * n + j)
            a, b, c_ = V[f[0]], V[f[1]], V[f[2]]
            if np.cross(b - a, c_ - a) @ out < 0:
                f = (f[0], f[2], f[1])
            F.append(f)
            UVc.append([(0.5 * ut, vs[which]), (0.5 * ut, vs[which]), (0.5 * ut, vs[which])])
    return V, F, UVc, W, np.asarray(C, float)


def frames(cs, ref):
    cs = [np.asarray(c, float) for c in cs]
    out = []
    for i in range(len(cs)):
        a, b = cs[max(0, i - 1)], cs[min(len(cs) - 1, i + 1)]
        t = unit(b - a)
        e1 = unit(np.asarray(ref, float) - t * np.dot(ref, t))
        out.append((t, e1, np.cross(t, e1)))
    return out


def limb(rings, ref):
    """Rings on a path: dicts c, r[, r2], w[, sq, rad, col, w_in/inner]; the
    cross-section frames follow the path."""
    out = []
    for r, (t, e1, e2) in zip(rings, frames([r["c"] for r in rings], ref)):
        d = dict(r)
        d.update(e1=e1, e2=e2, r1=r["r"], r2=r.get("r2", r["r"]))
        out.append(d)
    return out


def lathe_pts(prof, centre, axis, ref, segs, cap0=True, cap1=True):
    """A closed lathe as rings (for loft): prof = [(rho, h)], end rings that
    reach rho 0 are capped by the loft's fan."""
    axis = unit(axis)
    e1 = unit(np.asarray(ref, float) - axis * np.dot(ref, axis))
    e2 = np.cross(axis, e1)
    return [dict(c=np.asarray(centre, float) + axis * h, e1=e1, e2=e2, r1=max(rho, 1e-5), r2=max(rho, 1e-5))
            for rho, h in prof]


def box_mesh(c, size, M=None):
    """A box (8 verts, 6 quads) centred at c, sides size, rotated by M (3×3)."""
    hx, hy, hz = np.asarray(size, float) / 2
    V = np.array([[sx * hx, sy * hy, sz * hz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
    if M is not None:
        V = V @ np.asarray(M).T
    V = V + np.asarray(c, float)
    F = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    return V, F


def merge(*meshes):
    V, F = [], []
    for v, f in meshes:
        o = sum(len(x) for x in V)
        V.append(np.asarray(v, float))
        F += [tuple(i + o for i in ff) for ff in f]
    return np.vstack(V), F


def cyl_mesh(p0, p1, r, segs=16, r1=None):
    rings = lathe_pts([(0.0, 0.0), (r, 0.0), (r if r1 is None else r1, 1.0), (0.0, 1.0)], p0, np.asarray(p1) - p0, X if abs(unit(np.asarray(p1) - p0) @ X) < 0.9 else Y, segs)
    L = float(np.linalg.norm(np.asarray(p1) - p0))
    for rr in rings:
        rr["c"] = np.asarray(p0, float) + (rr["c"] - np.asarray(p0, float)) * L
    for rr in rings:
        rr["w"] = {}
    V, F, _, _, _ = loft(rings[1:3], segs)
    n = len(V)
    V = np.vstack([V, np.asarray(p0, float)[None], np.asarray(p1, float)[None]])
    for i in range(segs):
        j = (i + 1) % segs
        F.append((n, j, i))
        F.append((n + 1, segs + i, segs + j))
    return V, F


def frame_to(d, ref=None):
    """A 3×3 whose columns map +Y onto d (x, z completing a frame)."""
    d = unit(d)
    ref = X if ref is None else np.asarray(ref, float)
    if abs(ref @ d) > 0.95:
        ref = Z
    xx = unit(ref - d * (ref @ d))
    zz = np.cross(xx, d)
    return np.column_stack([xx, d, zz])


def ring_piece(name, mat, c, axis, ri, ro, w, bone, col, segs=16, part="suit", dirt="metal", band=None):
    """A bearing: a flat-faced annulus about `axis` at `c`, flat shaded (its
    four faces meet at hard edges). `band` colours its outer face."""
    axis = unit(axis)
    ref = X if abs(axis @ X) < 0.9 else Z
    e1 = unit(ref - axis * (axis @ ref))
    e2 = np.cross(axis, e1)
    c = np.asarray(c, float)
    prof = [(ri, -w / 2), (ro, -w / 2), (ro, w / 2), (ri, w / 2)]
    V, C = [], []
    for k_, (rho, h) in enumerate(prof):
        for i in range(segs):
            a = TAU * i / segs
            V.append(c + axis * h + (e1 * math.cos(a) + e2 * math.sin(a)) * rho)
            C.append(col)
    F, UVc = [], []
    for k_ in range(4):
        k2 = (k_ + 1) % 4
        for i in range(segs):
            j = (i + 1) % segs
            f = (k_ * segs + i, k_ * segs + j, k2 * segs + j, k2 * segs + i)
            P0, P1, P2 = V[f[0]], V[f[1]], V[f[2]]
            m = (P0 + P1 + P2) / 3 - c
            rad = m - axis * (m @ axis)
            want = [-axis, unit(rad), axis, -unit(rad)][k_]
            if np.cross(P1 - P0, P2 - P0) @ want < 0:
                f = tuple(reversed(f))
            F.append(f)
            u0, u1 = i / segs * 4, (i + 1) / segs * 4
            UVc.append([(u0, k_ * 0.25), (u1, k_ * 0.25), (u1, k_ * 0.25 + 0.25), (u0, k_ * 0.25 + 0.25)])
    C = np.asarray(C, float)
    if band is not None:
        # the outer face's own colour: split it off with its own vertices
        n0 = len(V)
        for i in range(segs):
            F[segs + i] = tuple(q + n0 - segs if segs <= q < 3 * segs else q for q in F[segs + i])
        V = V + V[segs:3 * segs]
        C = np.vstack([C, np.tile(band, (2 * segs, 1))])
    return Piece(name, mat, V, F, {bone: 1}, C, UVc=UVc, part=part, dirt=dirt, smooth=False, sharp=30)


# ═════════════════════════════════════════════════════════════════════════════
# palette (albedo multipliers; the textures carry the grain)
# ═════════════════════════════════════════════════════════════════════════════

CLOTH = (0.80, 0.785, 0.745)      # ortho-fabric TMG, warm and a little tired
CLOTH_SH = (0.70, 0.685, 0.645)   # the same in a fold
SHELL = (0.86, 0.855, 0.83)       # painted composite (the PLSS cover, DCM, EVVA)
SHELL_G = (0.55, 0.555, 0.55)     # grey hardware
SHELL_D = (0.17, 0.17, 0.18)      # dark hardware, rubber
ORANGE = (0.92, 0.47, 0.16)       # signal orange, used three times
METAL = (0.80, 0.80, 0.78)        # anodised bearings
METAL_D = (0.42, 0.43, 0.45)
GLOVE = (0.66, 0.655, 0.64)       # the glove's TMG, greyer than the suit
PALM = (0.16, 0.16, 0.17)         # RTV grip
SOLE = (0.14, 0.14, 0.145)
BOOT_W = (0.74, 0.73, 0.70)       # the boot's TMG, greyer and more used than the suit's
BOOT_RUB = (0.36, 0.36, 0.37)     # rubberised toe cap and heel counter
SKIN = (0.70, 0.52, 0.42)
CAP_W = (0.86, 0.85, 0.82)
CAP_B = (0.13, 0.13, 0.14)        # the comm cap's black sides


# ═════════════════════════════════════════════════════════════════════════════
# the suit
# ═════════════════════════════════════════════════════════════════════════════

def build(rig):
    J = rig.p
    head, back, hip = J("Head"), J("Back"), J("Hip")
    x0 = back[0]
    k = head[1] / 1.575
    zc = (back[2] + hip[2]) / 2

    nb = len(rig.names)
    D = np.tile(np.eye(4), (nb, 1, 1))
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        R = rot_about(Z, -s * AUTHOR_ABDUCT, J("Upperarm." + side))
        for b in ("Upperarm", "Forearm", "Hand", "Fingers1", "Fingers2", "Thumb1", "Thumb2"):
            D[rig.index[b + "." + side]] = R

    def Ja(name):
        return (D[rig.index[name]] @ np.append(J(name), 1.0))[:3]

    hut_y0 = hip[1] + 0.026 * k           # the HUT's lower edge, above the waist pivot
    zh = zc + 0.004 * k                    # the HUT's middle, front to back
    neck_top = head[1] + 0.024 * k         # the HUT's yoke under the neck ring

    # ── HUT: a cast shell, rigid on Back ───────────────────────────────────
    # Body: superellipse sections, the chest full at the front and flat at
    # the back (the PLSS mounts there), narrowing under the scyes (the arms
    # hang there) and rising in a sloped yoke to the neck ring.
    HUT = [  # y over the lower edge, half-width, front, back
        (0.000, 0.168, 0.128, 0.120), (0.050, 0.172, 0.140, 0.124), (0.110, 0.178, 0.154, 0.128),
        (0.170, 0.190, 0.160, 0.132), (0.215, 0.200, 0.158, 0.134), (0.255, 0.198, 0.150, 0.132),
        (0.300, 0.180, 0.138, 0.126), (0.335, 0.150, 0.126, 0.118), (0.355, 0.128, 0.118, 0.112),
        (neck_top / k - hut_y0 / k, 0.122, 0.112, 0.108),
    ]
    rings = []
    for y, hw, fr, bk in HUT:
        c = np.array([x0, hut_y0 + y * k, zh + (fr - bk) / 2 * k])
        rings.append(dict(c=c, e1=X, e2=Z, r1=hw * k, r2=(fr + bk) / 2 * k, sq=2.7, w={"Back": 1}))
    Vb, Fb, _, _, _ = loft(rings, 32, cap0=True, cap1=True)
    parts = [(Vb, Fb)]
    scye = {}
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        P = J("Upperarm." + side)
        n = unit(np.array([s * 0.74, -0.56, 0.22]))
        d = 0.040 * k
        scye[side] = (P, n, d)
        parts.append(cyl_mesh(P - n * 0.06 * k, P + n * d, 0.122 * k, segs=28))
    V, F = merge(*parts)

    def hut_col(P, N):
        C = np.tile(SHELL, (len(P), 1))
        # inside the neck ring: the dark well the neck rises from
        rr = np.hypot(P[:, 0] - x0, (P[:, 2] - zh) * 1.1)
        C[(P[:, 1] > neck_top - 0.012 * k) & (rr < 0.115 * k)] = SHELL_D
        return C
    hut = Piece("HUT", "SuitShell", V, F, {"Back": 1}, hut_col, tile=0.5, dirt="hut",
                mods=[("remesh", 0.0055 * k), ("smooth", 0.6, 6), ("decimate", 820)], sharp=44)
    tree = bvh(hut)

    # The body seal closure: a metal band round the lower edge.
    bsc = []
    for y, g in ((-0.014, 0.0), (-0.006, 0.006), (0.010, 0.006), (0.016, 0.0)):
        bsc.append(dict(c=(x0, hut_y0 + y * k, zh + 0.004 * k), e1=X, e2=Z, r1=(0.172 + g) * k, r2=(0.126 + g) * k,
                        sq=2.7, w={"Back": 1}))
    V, F, UVc, W, C = loft(bsc, 24, tile=0.1)
    Piece("BSC", "SuitMetal", V, F, W, np.tile(METAL, (len(V), 1)), UVc=UVc, dirt="metal", smooth=False, sharp=30)

    # The neck ring the helmet locks onto, tilted forward as on the HUT.
    tilt = math.radians(10)
    nax = np.array([0, math.cos(tilt), math.sin(tilt)])
    nc = np.array([x0, neck_top - 0.004 * k, zh + 0.004 * k])
    neck_ring = (nc, nax)
    ring_piece("NeckRing", "SuitMetal", nc + nax * 0.012 * k, nax, 0.112 * k, 0.136 * k, 0.026 * k, "Back", METAL,
               segs=24, band=METAL_D)

    # The scye bearings, set into the housings, and the cloth balls behind
    # them (see the arms).
    for side, (P, n, d) in scye.items():
        ring_piece("Scye." + side, "SuitMetal", P + n * (d + 0.009 * k), n, SCYE_BORE * k, 0.112 * k, 0.020 * k,
                   "Back", METAL, segs=18, band=METAL_D)

    # ── DCM: the display and control module on the lower chest ─────────────
    dy = hut_y0 + 0.125 * k
    hit, _ = surf_point(tree, (x0, dy, zh + 0.5), (0, 0, -1), (x0, dy, zh + 0.15 * k))
    dz = hit[2]
    tiltd = math.radians(-16)                   # the control face tips up to the eyes
    Md = np.array([[1, 0, 0], [0, math.cos(tiltd), -math.sin(tiltd)], [0, math.sin(tiltd), math.cos(tiltd)]])
    dc = np.array([x0, dy, dz + 0.036 * k])
    V, F = box_mesh(dc, (0.240 * k, 0.100 * k, 0.090 * k), Md)
    Piece("DCM", "SuitShell", V, F, {"Back": 1}, SHELL_G, tile=0.5, dirt="hard",
          mods=[("bevel", 0.012 * k, 2, 35)], sharp=40)
    # its mounting brackets back to the HUT
    for sx in (-1, 1):
        V, F = box_mesh((x0 + sx * 0.085 * k, dy + 0.01 * k, dz + 0.004 * k), (0.03 * k, 0.07 * k, 0.04 * k))
        Piece("DCMbracket", "SuitShell", V, F, {"Back": 1}, SHELL_D, tile=0.5, dirt="hard", smooth=False, sharp=30)
    up_d = Md @ Y
    fw_d = Md @ Z
    top_c = dc + up_d * 0.050 * k
    # knobs on the control face: fan, water, comm volume ×2, and the purge
    # valve (the accent)
    for i, (dx, r, h, col) in enumerate(((-0.085, 0.013, 0.014, METAL_D), (-0.045, 0.011, 0.012, METAL_D),
                                          (0.005, 0.009, 0.016, SHELL_D), (0.035, 0.009, 0.016, SHELL_D),
                                          (0.085, 0.015, 0.020, ORANGE))):
        p0 = top_c + X * dx * k - fw_d * 0.018 * k
        V, F = cyl_mesh(p0, p0 + up_d * h * k, r * k, segs=8)
        Piece("DCMknob", "SuitShell", V, F, {"Back": 1}, col, tile=0.2, dirt="hard", smooth=False, sharp=30)
    # the display window on the front edge of the control face
    dw, dh = 0.105 * k, 0.034 * k
    dpc = top_c + fw_d * 0.030 * k + up_d * 0.0008

    def disp(su, tv):
        return dpc + X * (-dw / 2 + dw * su) + fw_d * (dh / 2 - dh * tv)
    decal_piece("DCMdisplay", "display", disp, up_d, "Back")
    # the umbilical connectors on the DCM's sides
    for sx in (-1, 1):
        p0 = dc + X * sx * 0.12 * k - up_d * 0.012 * k
        V, F = cyl_mesh(p0, p0 + X * sx * 0.03 * k, 0.019 * k, segs=12)
        Piece("DCMport", "SuitMetal", V, F, {"Back": 1}, METAL_D, tile=0.2, dirt="metal", smooth=False, sharp=30)

    # the name tape on the right breast, sewn on above the DCM
    pw_, ph_ = 0.115 * k, 0.028 * k
    py = hut_y0 + 0.225 * k

    def placard(su, tv):
        x = x0 - 0.035 * k - pw_ + pw_ * su
        y = py + ph_ / 2 - ph_ * tv
        p, _ = surf_point(tree, (x, y, zh + 0.5), (0, 0, -1), (x, y, zh + 0.15 * k))
        return p + Z * 0.0018
    decal_piece("Placard", "placard", placard, Z, "Back", nu=4, nv=1)

    # ── the cooling hose: from the DCM's right port, a slack loop down and
    # round to the HUT's side, where it goes in through a grommet (A7L-style
    # plumbing); all on Back, so the waist never drags it
    hp0 = dc + X * -0.15 * k - up_d * 0.012 * k
    hp1, nrm = surf_point(tree, (x0 - 0.5, hut_y0 + 0.05 * k, zh + 0.03 * k), (1, 0, 0),
                          (x0 - 0.172 * k, hut_y0 + 0.05 * k, zh + 0.03 * k))
    # a cubic: out of the port, sagging, into the grommet along its normal
    c0, c3 = hp0, hp1
    c1 = c0 + np.array([-0.06, -0.09, 0.0]) * k
    c2 = c3 + nrm * 0.07 * k + np.array([0, -0.06, 0]) * k
    pts = [(1 - t) ** 3 * c0 + 3 * (1 - t) ** 2 * t * c1 + 3 * (1 - t) * t * t * c2 + t ** 3 * c3
           for t in np.linspace(0, 1, 11)]
    hrings = [dict(c=p, r=0.0115 * k, w={"Back": 1}, col=SHELL_D) for p in pts]
    V, F, UVc, W, C = loft(limb(hrings, Z), 6, cap0=True, cap1=True, tile=0.1)
    Piece("Hose", "SuitShell", V, F, W, C, UVc=UVc, dirt="hard")
    ring_piece("Grommet", "SuitMetal", hp1, nrm, 0.010 * k, 0.020 * k, 0.010 * k, "Back", METAL_D, segs=10)

    # ── WAIST and BRIEF (the LTA top): a convoluted waist from the BSC down to
    # the waist bearing, then the brief, which hangs ─────────────────────────
    waist_y = hip[1] - 0.078 * k
    crotch = J("Thigh.Left")[1] - 0.090 * k
    wrings = []
    ys = np.linspace(waist_y + 0.010 * k, hut_y0 + 0.004 * k, 7)
    for i, y in enumerate(ys):
        ridge = i % 2 == 1
        hw = (0.176 if ridge else 0.166) * k
        wob = (lambda a, i=i: 0.0025 * k * math.sin(3 * a + i * 1.3) + 0.002 * k * math.sin(7 * a + i))
        wrings.append(dict(c=(x0, y, zc), e1=X, e2=Z, r1=hw, r2=hw * 0.74, sq=2.4, rad=wob,
                           w=blend("Hip", "Back", float(smooth01(ys[0] + 0.012 * k, ys[-1] - 0.012 * k, y))),
                           col=CLOTH if ridge else CLOTH_SH))
    V, F, UVc, W, C = loft(wrings, 22, a0=-math.pi / 2)
    Piece("Waist", "SuitFabric", V, F, W, C, UVc=UVc, dirt="body")
    bring = []
    for y, g in ((-0.012, 0.0), (-0.006, 0.006), (0.006, 0.006), (0.012, 0.0)):
        bring.append(dict(c=(x0, waist_y + y * k, zc), e1=X, e2=Z, r1=(0.180 + g) * k, r2=(0.134 + g) * k, sq=2.4,
                          w={"Hip": 1}))
    V, F, UVc, W, C = loft(bring, 24, tile=0.1)
    Piece("WaistRing", "SuitMetal", V, F, W, np.tile(METAL, (len(V), 1)), UVc=UVc, dirt="metal", smooth=False,
          sharp=30)

    def sag(amp, n=5, ph=0.0):
        return lambda a: amp * (0.6 * math.sin(n * a + ph) + 0.4 * math.sin((n + 3) * a + 2 * ph)) \
            - amp * 0.8 * max(0.0, -math.sin(a))
    brief = []
    for y, hw, hd, dzz in ((crotch + 0.020 * k, 0.060, 0.055, 0.0), (crotch + 0.045 * k, 0.150, 0.108, -0.006),
                           (crotch + 0.095 * k, 0.196, 0.132, -0.012), (crotch + 0.155 * k, 0.198, 0.136, -0.010),
                           (waist_y - 0.045 * k, 0.190, 0.134, -0.004), (waist_y - 0.010 * k, 0.182, 0.134, 0.0)):
        brief.append(dict(c=(x0, y, zc + dzz * k), e1=X, e2=Z, r1=hw * k, r2=hd * k, sq=2.5, w={"Hip": 1},
                          col=CLOTH, rad=sag(0.003 * k, 4, y * 40)))
    V, F, UVc, W, C = loft(brief, 22, cap0=True, a0=-math.pi / 2)
    Piece("Brief", "SuitFabric", V, F, W, C, UVc=UVc, dirt="seat")

    # ── PLSS: the pack, rigid on Back, high on the back ────────────────────
    hit, _ = surf_point(tree, (x0, hut_y0 + 0.22 * k, zh - 0.5), (0, 0, 1), (x0, 0, zh - 0.14 * k))
    back_z = hit[2]
    Wp, Hp, Dp = 0.500 * k, 0.560 * k, 0.175 * k
    top = neck_top + 0.020 * k
    pz = back_z - 0.012 * k - Dp / 2
    pc = np.array([x0, top - Hp / 2, pz])
    # Sections up the pack (plan superellipses): the SOP at the bottom, a
    # step, the case, and the top housing that is deeper than the case and
    # rolls over to the front.
    zf = back_z - 0.010 * k                       # the pack's front face, on the HUT
    yb = top - Hp - 0.11 * k
    SEC = [  # y over the bottom, half-width, depth, sq
        (0.000, 0.205, 0.150, 4.0), (0.010, 0.222, 0.180, 4.0), (0.100, 0.226, 0.186, 4.0),
        (0.112, 0.236, 0.168, 4.5), (0.135, 0.250, 0.176, 5.0), (0.380, 0.252, 0.178, 5.0),
        (0.520, 0.250, 0.196, 4.5), (0.600, 0.244, 0.205, 3.6), (0.640, 0.228, 0.190, 3.0),
        (0.662, 0.196, 0.150, 2.6), (0.670, 0.150, 0.100, 2.4)]
    prings = []
    for y, hw, dp, sq in SEC:
        prings.append(dict(c=(x0, yb + y * k, zf - dp / 2 * k), e1=X, e2=Z, r1=hw * k, r2=dp / 2 * k, sq=sq,
                           w={"Back": 1}, col=SHELL if y > 0.105 else (0.78, 0.775, 0.75)))
    V, F, UVc, W, C = loft(prings, 24, cap0=True, cap1=True, tile=0.5)
    pl = Piece("PLSS", "SuitShell", V, F, W, C, UVc=UVc, dirt="pack", sharp=50)
    Dp = 0.178 * k
    pz = zf - Dp / 2
    pc = np.array([x0, yb + 0.11 * k + Hp / 2, pz])
    ptree = bvh(pl)
    pb = pz - Dp / 2                              # the pack's back face (−z)
    # the TMG cover's lacing seam round the case, a dark line of hardware
    for sy in (Hp / 2 - 0.15 * k, -Hp / 2 + 0.05 * k):
        V, F = box_mesh(pc + np.array([0, sy, -Dp / 2 - 0.002 * k]), (Wp - 0.06 * k, 0.012 * k, 0.012 * k))
        Piece("PLSSseam", "SuitShell", V, F, {"Back": 1}, SHELL_G, tile=0.5, dirt="hard", smooth=False, sharp=30)
    # the SOP's actuator and gauge, and the pack's lower access plate
    sop_c = np.array([x0, yb + 0.055 * k, zf - 0.186 * k])
    for i, dx in enumerate((-0.12, 0.12)):
        p0 = sop_c + X * dx * k
        V, F = cyl_mesh(p0, p0 - Z * 0.022 * k, 0.024 * k if i == 0 else 0.018 * k, segs=14)
        Piece("SOPknob", "SuitShell", V, F, {"Back": 1}, METAL_D if i == 0 else SHELL_D, tile=0.2, dirt="hard",
              smooth=False, sharp=30)
    V, F = box_mesh(sop_c + np.array([0, 0.005 * k, -0.004 * k]), (0.14 * k, 0.06 * k, 0.012 * k))
    Piece("SOPplate", "SuitShell", V, F, {"Back": 1}, SHELL_G, tile=0.5, dirt="hard", mods=[("bevel", 0.003 * k, 1)],
          sharp=30)
    # the radio antenna on the top left
    at = pc + np.array([0.17 * k, Hp / 2 - 0.02 * k, -0.03 * k])
    hit, _ = surf_point(ptree, at + Y * 0.3, (0, -1, 0), at)
    V, F = cyl_mesh(hit - Y * 0.01 * k, hit + Y * 0.06 * k, 0.010 * k, segs=10, r1=0.006 * k)
    Piece("Antenna", "SuitShell", V, F, {"Back": 1}, SHELL_D, tile=0.2, dirt="hard")
    # the plate
    decal_piece("PLSSplate", "plss",
                lambda su, tv: np.array([x0 + 0.11 * k - 0.22 * k * su, pc[1] + 0.08 * k - 0.11 * k * tv,
                                         pb - 0.0015]), -Z, "Back")
    # two grab handles on the sides (orange: the second accent)
    for sx in (-1, 1):
        hx = x0 + sx * (Wp / 2 + 0.028 * k)
        pts = [np.array([x0 + sx * (Wp / 2 - 0.004 * k), pc[1] + 0.10 * k, pz - 0.02 * k]),
               np.array([hx, pc[1] + 0.09 * k, pz - 0.02 * k]), np.array([hx, pc[1] - 0.05 * k, pz - 0.02 * k]),
               np.array([x0 + sx * (Wp / 2 - 0.004 * k), pc[1] - 0.06 * k, pz - 0.02 * k])]
        hr = [dict(c=p, r=0.0085 * k, w={"Back": 1}, col=ORANGE) for p in bezier_path(pts, 8)]
        V, F, UVc, W, C = loft(limb(hr, Z), 6, cap0=True, cap1=True, tile=0.1)
        Piece("PLSShandle", "SuitShell", V, F, W, C, UVc=UVc, dirt="hard")

    # ── ARMS ──────────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        arm(rig, D, Ja, J, side, s, k, scye[side])

    # ── LEGS ──────────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        leg(rig, J, side, s, k, x0, zc, crotch)

    # ── HEAD (under the helmet) and the neck ───────────────────────────────
    head_piece(J, k, x0, zh, neck_top, nc)

    # ── HELMET (a separate model the game can take off) ────────────────────
    helmet(J, k, x0, zh, neck_ring)
    return D


# ═════════════════════════════════════════════════════════════════════════════
# decals and paths
# ═════════════════════════════════════════════════════════════════════════════

DECAL_W, DECAL_H = 512, 256
REG = {
    "emblem": (0 / 512, 0 / 256, 128 / 512, 128 / 256),
    "placard": (128 / 512, 0 / 256, 384 / 512, 64 / 256),
    "display": (128 / 512, 64 / 256, 320 / 512, 160 / 256),
    "plss": (320 / 512, 64 / 256, 512 / 512, 160 / 256),
    "flag": (384 / 512, 0 / 256, 512 / 512, 64 / 256),
    "cuff": (0 / 512, 128 / 256, 128 / 512, 256 / 256),
}


def decal_piece(name, region, pos, normal, bone, nu=1, nv=1, part="suit"):
    u0, v0, u1, v1 = REG[region]
    V, UVv = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            s_, t_ = i / nu, j / nv
            V.append(np.asarray(pos(s_, t_), float))
            UVv.append((u0 + (u1 - u0) * s_, v0 + (v1 - v0) * t_))
    F, UVc = [], []
    V = np.array(V)
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            f = (a, a + 1, a + nu + 2, a + nu + 1)
            p0, p1, p2 = V[f[0]], V[f[1]], V[f[2]]
            if np.cross(p1 - p0, p2 - p0) @ np.asarray(normal, float) < 0:
                f = tuple(reversed(f))
            F.append(f)
            UVc.append([UVv[q] for q in f])
    return Piece(name, "SuitDecal", V, F, bone if isinstance(bone, dict) else {bone: 1}, (1, 1, 1), UVc=UVc,
                 part=part, dirt="decal")


def bezier_path(ctrl, n):
    """A Catmull-Rom spline through the control points, n samples."""
    P = [np.asarray(p, float) for p in ctrl]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = []
    segs = len(P) - 3
    for i in range(n):
        t = i / (n - 1) * segs
        j = min(int(t), segs - 1)
        u = t - j
        p0, p1, p2, p3 = P[j], P[j + 1], P[j + 2], P[j + 3]
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * u ** 3))
    return out


# ═════════════════════════════════════════════════════════════════════════════
# arms
# ═════════════════════════════════════════════════════════════════════════════

def arm(rig, D, Ja, J, side, s, k, sc):
    ua, fa, hd = "Upperarm." + side, "Forearm." + side, "Hand." + side
    P, n, d = sc                       # pivot, scye normal, ring plane distance
    S, E, H = Ja(ua), Ja(fa), Ja(hd)
    axu, axf = unit(E - S), unit(H - E)
    out = unit(s * np.cross(Z, axu))   # away from the body, in the frontal plane
    L1 = float(np.linalg.norm(E - S))
    L2 = float(np.linalg.norm(H - E))

    # The SHOULDER is a ball and socket. The scye bearing and its housing are
    # rigid on Back. Behind the bearing sits a cloth BALL centred exactly on
    # the shoulder pivot and rigid on Upperarm: a sphere turning about its own
    # centre stays where it is, so whatever the arm does, the bearing's bore
    # closes on the same cloth surface — never a gap, never a floating ring.
    # Its radius is the bore at the bearing's OUTER face (bore² + depth²), so
    # the bore is covered across the bearing's whole width, and its folds only
    # ever stand out from that sphere, never into it. The sleeve is rooted
    # INSIDE the ball, rigid on Upperarm, and comes out of it like an arm out
    # of a gathered shoulder; nothing between the two is blended, so nothing
    # pinches into fins (linear skinning shrinks a blended ring by cos(θ/2),
    # a third of it at the 140° an overhead reach asks of a shoulder).
    ring_out = d + 0.019 * k
    Rb = math.sqrt((SCYE_BORE * k) ** 2 + ring_out ** 2) + 0.001 * k
    prof = [(Rb * math.sin(a), -Rb * math.cos(a)) for a in np.linspace(0, math.pi, 9)]
    rings = lathe_pts(prof[1:-1], P, axu, Z, 16)
    for i, r in enumerate(rings):
        r["w"] = {ua: 1}
        r["col"] = CLOTH_SH if i % 2 else CLOTH
        r["rad"] = (lambda a, i=i: 0.004 * k * max(0.0, math.sin(5 * a + i * 1.7)) * math.sin(math.pi * i / 7))
    V, F, UVc, W, C = loft(rings, 16, cap0=True, cap1=True, tile=0.25)
    Piece("ShoulderBall." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="body")

    def off(t):
        return 0.020 * k * (1 - float(smooth01(0.10 * k, L1 - 0.06 * k, t)))

    def up_c(t):
        return S + axu * t + out * off(t)

    s_ub = 0.165 * k
    sock = []
    # the sleeve's root, gathered, inside the ball and out through it
    for t, r, g in ((0.000, 0.058, 0.0), (0.050, 0.064, 0.004), (0.095, 0.072, 0.005), (0.130, 0.078, 0.003)):
        sock.append(dict(c=up_c(t * k), r=r * k, w={ua: 1}, col=CLOTH,
                         rad=lambda a, g=g, t=t: g * k * math.sin(6 * a + t * 60)))
    # The upper arm: TMG over the restraint, a slight sag on its underside.
    conv0 = L1 - 0.070 * k
    for t in np.linspace(s_ub + 0.006 * k, conv0, 4):
        f = (t - s_ub) / (conv0 - s_ub)
        sock.append(dict(c=up_c(t), r=(0.075 - 0.007 * f) * k, w={ua: 1}, col=CLOTH,
                         rad=lambda a, f=f: 0.0025 * k * math.sin(4 * a + 9 * f) - 0.003 * k * max(0, math.cos(a))))
    # The elbow: pleats either side, a three-ring blend across the pivot, the
    # inner side rigid (the crease tucks in), and a ball on the pivot.
    for dd, r, w, c_ in ((-0.050, 0.068, {ua: 1}, CLOTH), (-0.038, 0.061, {ua: 1}, CLOTH_SH),
                         (-0.026, 0.067, {ua: 1}, CLOTH), (-0.012, 0.059, blend(ua, fa, 0.25), CLOTH_SH),
                         (0.000, 0.059, blend(ua, fa, 0.5), CLOTH_SH), (0.012, 0.059, blend(ua, fa, 0.75), CLOTH_SH),
                         (0.025, 0.065, {fa: 1}, CLOTH), (0.037, 0.060, {fa: 1}, CLOTH_SH),
                         (0.049, 0.064, {fa: 1}, CLOTH)):
        c = up_c(L1 + dd * k) if dd < 0 else (E + axf * dd * k)
        sock.append(dict(c=c, r=r * k, w=w, col=c_, w_in={ua: 1} if dd <= 0 else {fa: 1}, inner=Z,
                         rad=lambda a, dd=dd: 0.003 * k * math.sin(3 * a + dd * 90)))
    # The forearm, tapering to the wrist disconnect.
    for dd, r in ((0.085, 0.063), (0.15, 0.060), (L2 / k - 0.075, 0.055), (L2 / k - 0.040, 0.052)):
        sock.append(dict(c=E + axf * dd * k, r=r * k, w={fa: 1}, col=CLOTH,
                         rad=lambda a, dd=dd: 0.0018 * k * math.sin(5 * a + dd * 40)))
    V, F, UVc, W, C = loft(limb(sock, Z), 13, a0=math.pi / 2 * s + math.pi, tile=0.25)
    Piece("Sleeve." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="arm")
    ball = lathe_pts([(0.057 * k * math.sin(a), -0.057 * k * math.cos(a)) for a in np.linspace(0, math.pi, 6)][1:-1],
                     E, axu, Z, 10)
    for r in ball:
        r["w"] = {ua: 1}
        r["col"] = CLOTH_SH
    V, F, UVc, W, C = loft(ball, 10, cap0=True, cap1=True)
    Piece("ElbowBall." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="arm")
    # the upper-arm bearing, the wrist disconnect (a lock ring with a
    # coloured band: blue left, red right, as the real ones are keyed)
    ring_piece("UpperArmBearing." + side, "SuitMetal", up_c(s_ub), axu, 0.072 * k, 0.084 * k, 0.020 * k, ua, METAL,
               segs=16, band=METAL_D)
    wc = H - axf * 0.030 * k
    ring_piece("Wrist." + side, "SuitMetal", wc, axf, 0.046 * k, 0.061 * k, 0.024 * k, fa, METAL, segs=16,
               band=(0.24, 0.34, 0.56) if s > 0 else (0.62, 0.22, 0.18))
    # the emblem on the left upper arm, the flag on the right
    r_p = 0.074 * k + 0.0025
    ph = 0.075 * k
    span = ph / r_p
    sc_ = s_ub + 0.085 * k
    across = unit(-Z - axu * (-Z @ axu))

    def patch(su, tv, sc_=sc_, across=across, span=span, ph=ph):
        a = (su - 0.5) * span * s
        return up_c(sc_ + (tv - 0.5) * ph) + (out * math.cos(a) + across * math.sin(a)) * r_p
    decal_piece("Emblem." + side, "emblem" if s > 0 else "flag", patch, out, ua, nu=4, nv=1)

    # the CUFF CHECKLIST on the left forearm: a small spiral-bound book on a
    # strap; a wrist mirror on the right
    if s > 0:
        top = unit(np.cross(axf, Z))
        if top @ Y < 0:
            top = -top
        cc = E + axf * 0.15 * k + top * 0.060 * k
        Mb = np.column_stack([unit(np.cross(top, axf)), top, axf])
        V, F = box_mesh(cc, (0.085 * k, 0.020 * k, 0.095 * k), Mb)
        Piece("Cuff", "SuitShell", V, F, {fa: 1}, SHELL_G, tile=0.5, dirt="hard", mods=[("bevel", 0.003 * k, 1)],
              sharp=30)
        decal_piece("CuffPage", "cuff",
                    lambda su, tv: cc + top * 0.0105 * k + Mb[:, 0] * (-0.038 * k + 0.076 * k * su)
                    + axf * (0.042 * k - 0.084 * k * tv), top, fa)
    else:
        top = unit(np.cross(axf, Z))
        if top @ Y < 0:
            top = -top
        cc = E + axf * 0.14 * k + top * 0.062 * k
        Mb = np.column_stack([unit(np.cross(top, axf)), top, axf])
        V, F = box_mesh(cc, (0.06 * k, 0.012 * k, 0.07 * k), Mb)
        Piece("Mirror", "SuitMetal", V, F, {fa: 1}, METAL, tile=0.5, dirt="metal", mods=[("bevel", 0.002 * k, 1)],
              sharp=30)
    # a strap round the forearm under it
    strap = [dict(c=E + axf * t * k, r=0.0615 * k, w={fa: 1}, col=SHELL_D) for t in (0.135, 0.155)]
    V, F, UVc, W, C = loft(limb(strap, Z), 16, tile=0.1)
    Piece("Strap." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="arm")

    glove(rig, D, Ja, J, side, s, k, H, axf)


def glove(rig, D, Ja, J, side, s, k, H, axf):
    hd = "Hand." + side
    f1n, f2n = "Fingers1." + side, "Fingers2." + side
    t1n, t2n = "Thumb1." + side, "Thumb2." + side
    F1, F2 = Ja(f1n), Ja(f2n)
    T1, T2 = Ja(t1n), Ja(t2n)
    hax = unit(F2 - H)
    hup = D[rig.index[hd]][:3, :3] @ Y       # the back of the hand (T-pose: up)
    hup = unit(hup - hax * (hup @ hax))
    hfw = np.cross(hax, hup)
    if hfw @ Ja(t1n) < hfw @ H:             # across the palm toward the thumb
        hfw = -hfw

    # The gauntlet: TMG flaring over the wrist disconnect.
    g = [(-0.030, 0.060), (-0.018, 0.067), (0.000, 0.066), (0.016, 0.056), (0.026, 0.050)]
    gl = [dict(c=H + axf * dd * k, r=r * k, w={hd: 1}, col=GLOVE,
               rad=lambda a, dd=dd: 0.0025 * k * math.sin(6 * a + dd * 200)) for dd, r in g]
    V, F, UVc, W, C = loft(limb(gl, Z), 14, tile=0.2)
    Piece("Gauntlet." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="glove")

    # The palm: a padded block from the wrist to the knuckles, dark RTV on
    # the palm side.
    def pal(a):
        return PALM if math.sin(a) < -0.45 else GLOVE

    def gr(p, wdt, th, w, sq=2.8):
        return dict(c=p, e1=hfw, e2=hup, r1=wdt * k, r2=th * k, w=w, col=pal, sq=sq)
    base = H + hax * 0.012 * k
    palm = [gr(base, 0.044, 0.029, {hd: 1}), gr(lerp(H, F1, 0.45), 0.051, 0.031, {hd: 1}),
            gr(lerp(H, F1, 0.85), 0.053, 0.028, {hd: 1}), gr(F1 + hax * 0.004 * k, 0.051, 0.023, blend(hd, f1n, 0.5))]
    V, F, UVc, W, C = loft(palm, 16, cap1=True, tile=0.2)
    Piece("Palm." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="glove")

    # Four fingers, all on the one finger chain (the rig's), spread a little,
    # each a padded tube with a dark grip pad on its tip.
    for i, (lat, ln, rr) in enumerate(((0.034, 0.082, 0.0118), (0.012, 0.090, 0.0124), (-0.011, 0.086, 0.0118),
                                      (-0.032, 0.070, 0.0106))):
        o = hfw * lat * k
        root = F1 + o - hax * 0.006 * k
        mid = F2 + o * 1.05
        dirn = unit(hax + hfw * lat * 0.6)
        tip = mid + dirn * (ln * k - float(np.linalg.norm(F2 - F1)))
        fr = []
        for t, r, w in ((0.0, rr, {f1n: 1}), (0.35, rr * 1.04, {f1n: 1}), (0.62, rr * 0.98, blend(f1n, f2n, 0.5)),
                        (0.85, rr * 0.97, {f2n: 1}), (0.97, rr * 0.80, {f2n: 1}), (1.0, rr * 0.45, {f2n: 1})):
            c = lerp(root, mid, t / 0.62) if t <= 0.62 else lerp(mid, tip, (t - 0.62) / 0.38)
            fr.append(dict(c=c, e1=hfw, e2=hup, r1=r * k, r2=r * k * 0.92, w=w,
                           col=(lambda a, t=t: PALM if (math.sin(a) < -0.3 and t > 0.7) else GLOVE)))
        V, F, UVc, W, C = loft(fr, 6, cap1=True, tile=0.2)
        Piece("Finger%d.%s" % (i, side), "SuitFabric", V, F, W, C, UVc=UVc, dirt="glove")
    # The thumb.
    tdir = unit(T2 - T1)
    th = [dict(c=T1 - tdir * 0.012 * k, r=0.018 * k, w=blend(hd, t1n, 0.4), col=GLOVE),
          dict(c=T2, r=0.0150 * k, w=blend(t1n, t2n, 0.5), col=GLOVE),
          dict(c=T2 + tdir * 0.030 * k, r=0.0135 * k, w={t2n: 1}, col=GLOVE),
          dict(c=T2 + tdir * 0.046 * k, r=0.007 * k, w={t2n: 1}, col=PALM)]
    V, F, UVc, W, C = loft(limb(th, hup), 8, cap1=True, tile=0.2)
    Piece("Thumb." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="glove")


# ═════════════════════════════════════════════════════════════════════════════
# legs
# ═════════════════════════════════════════════════════════════════════════════

def leg(rig, J, side, s, k, x0, zc, crotch):
    T, K, A = J("Thigh." + side), J("Shin." + side), J("Foot." + side)
    th, sh_, ft, to = "Thigh." + side, "Shin." + side, "Foot." + side, "Toes." + side
    axt, axs = unit(K - T), unit(A - K)
    LT, LS = float(np.linalg.norm(K - T)), float(np.linalg.norm(A - K))
    rings = []
    # the hip: from inside the brief, Hip blending into Thigh below the joint
    for dd, r in ((-0.10, 0.086), (-0.04, 0.092), (0.02, 0.098), (0.08, 0.104)):
        rings.append(dict(c=T + axt * dd * k, r=r * k, w=blend("Hip", th, float(smooth01(-0.05, 0.09, dd))),
                          col=CLOTH))
    # thigh bearing, then the thigh: the EV1 band (the third accent), a slight
    # bag at the back
    for dd, r, c_ in ((0.13, 0.104, CLOTH), (0.20, 0.102, CLOTH), (0.2001, 0.102, ORANGE), (0.235, 0.101, ORANGE),
                      (0.2351, 0.101, CLOTH), (0.30, 0.097, CLOTH), (LT / k - 0.068, 0.092, CLOTH)):
        rings.append(dict(c=T + axt * dd * k, r=r * k, w={th: 1}, col=c_,
                          rad=lambda a, dd=dd: 0.003 * k * math.sin(5 * a + dd * 30)
                          + 0.004 * k * max(0.0, -math.sin(a)) * math.sin(math.pi * min(1, dd / 0.4))))
    # the knee: pleats, Thigh blending into Shin, proud at the front
    for dd, r, w, c_ in ((-0.052, 0.091, {th: 1}, CLOTH), (-0.038, 0.083, {th: 1}, CLOTH_SH),
                         (-0.024, 0.090, {th: 1}, CLOTH), (-0.011, 0.081, blend(th, sh_, 0.25), CLOTH_SH),
                         (0.000, 0.081, blend(th, sh_, 0.5), CLOTH_SH), (0.011, 0.081, blend(th, sh_, 0.75), CLOTH_SH),
                         (0.024, 0.089, {sh_: 1}, CLOTH), (0.037, 0.082, {sh_: 1}, CLOTH_SH),
                         (0.050, 0.088, {sh_: 1}, CLOTH)):
        c = (K + axt * dd * k) if dd < 0 else (K + axs * dd * k)
        rings.append(dict(c=c, r=r * k, w=w, col=c_, w_in={th: 1} if dd <= 0 else {sh_: 1}, inner=-Z,
                          rad=lambda a, dd=dd: 0.003 * k * math.sin(3 * a + dd * 120)))
    for dd, r in ((0.11, 0.088), (0.20, 0.085), (0.28, 0.078), (LS / k - 0.12, 0.068)):
        rings.append(dict(c=K + axs * dd * k, r=r * k, w={sh_: 1}, col=CLOTH,
                          rad=lambda a, dd=dd: 0.0025 * k * math.sin(4 * a + dd * 50)))
    for dd, r in ((LS / k - 0.085, 0.064), (LS / k - 0.060, 0.064)):
        rings.append(dict(c=K + axs * dd * k, r=r * k,
                          w=blend(sh_, ft, float(smooth01(LS - 0.10 * k, LS - 0.05 * k, dd * k))), col=CLOTH))
    V, F, UVc, W, C = loft(limb(rings, Z), 13, a0=math.pi if s > 0 else 0.0, tile=0.25)
    Piece("Leg." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="leg")
    for nm, c, r, bone in (("HipBall", T, 0.088, "Hip"), ("KneeBall", K, 0.079, th)):
        ball = lathe_pts([(r * k * math.sin(a), -r * k * math.cos(a)) for a in np.linspace(0, math.pi, 6)][1:-1],
                         c, axt, Z, 10)
        for rr in ball:
            rr["w"] = {bone: 1}
            rr["col"] = CLOTH_SH
        V, F, UVc, W, C = loft(ball, 10, cap0=True, cap1=True)
        Piece(nm + "." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="leg")
    ring_piece("ThighBearing." + side, "SuitMetal", T + axt * 0.13 * k, axt, 0.098 * k, 0.110 * k, 0.020 * k, th, METAL,
               segs=16, band=METAL_D)

    # The BOOT: one cast-looking shoe on a dark sole — an upper lofted from
    # heel to toe (high at the ankle, low and rounded at the toe), the sole a
    # slab a little proud of it; rigid on Foot, the toe box on Toes with a
    # flex line at the ball of the foot; grey rubber round the toe and heel.
    Tp = J("Toes." + side)
    bx = A[0] + s * 0.004 * k
    heel_z, toe_z = A[2] - 0.090 * k, Tp[2] + 0.112 * k
    sole_t = 0.030 * k
    ty = Tp[2]
    SEC = [  # z, half-width, top
        (heel_z, 0.040, 0.085), (heel_z + 0.012 * k, 0.054, 0.140), (heel_z + 0.045 * k, 0.060, 0.170),
        (A[2] + 0.040 * k, 0.061, 0.168), (ty - 0.045 * k, 0.062, 0.122), (ty - 0.005 * k, 0.061, 0.100),
        (ty + 0.040 * k, 0.057, 0.086), (toe_z - 0.030 * k, 0.050, 0.074), (toe_z - 0.008 * k, 0.040, 0.062),
        (toe_z, 0.022, 0.050)]

    def bw(z):
        return blend(ft, to, float(smooth01(ty - 0.030 * k, ty + 0.012 * k, z)))
    up_, so_ = [], []
    for i, (z, hw, tp) in enumerate(SEC):
        y0 = sole_t - 0.004 * k
        tp = tp * k

        def ucol(a, z=z):
            low = math.sin(a) < -0.35
            return BOOT_RUB if (low and (z > ty - 0.005 * k or z < heel_z + 0.05 * k)) else BOOT_W
        up_.append(dict(c=(bx, (y0 + tp) / 2, z), e1=X, e2=Y, r1=hw * k, r2=(tp - y0) / 2, sq=2.8, w=bw(z),
                        col=ucol, rad=lambda a, i=i: 0.0015 * k * math.sin(5 * a + i)))
        so_.append(dict(c=(bx, sole_t / 2, z), e1=X, e2=Y, r1=(hw + 0.007) * k * (0.9 if i in (0, 9) else 1.0),
                        r2=sole_t / 2, sq=6.0, w=bw(z), col=SOLE))
    V, F, UVc, W, C = loft(up_, 14, cap0=True, cap1=True, tile=0.25)
    Piece("Boot." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="boot", sharp=60)
    V, F, UVc, W, C = loft(so_, 8, cap0=True, cap1=True, tile=0.25)
    Piece("Sole." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="boot", sharp=45)
    # the strap over the instep, buckled on the outside
    sp_ = []
    zst = A[2] + 0.075 * k
    zs_, hw_, tp_ = [q[0] for q in SEC], [q[1] for q in SEC], [q[2] for q in SEC]
    for z in (zst - 0.012 * k, zst + 0.012 * k):
        hw, tp = float(np.interp(z, zs_, hw_)) * k, float(np.interp(z, zs_, tp_)) * k
        y0 = sole_t - 0.004 * k
        sp_.append(dict(c=(bx, (y0 + tp) / 2, z), e1=X, e2=Y, r1=hw + 0.004 * k, r2=(tp - y0) / 2 + 0.004 * k,
                        sq=2.8, w={ft: 1}, col=SHELL_D))
    V, F, UVc, W, C = loft(sp_, 14, tile=0.1)
    Piece("BootStrap." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="boot")
    # the ankle bearing on the boot's collar
    ring_piece("Ankle." + side, "SuitMetal", np.array([bx, 0.170 * k, A[2] - 0.004 * k]), Y, 0.058 * k, 0.071 * k,
               0.020 * k, ft, METAL, segs=16, band=METAL_D)


# ═════════════════════════════════════════════════════════════════════════════
# the head under the helmet
# ═════════════════════════════════════════════════════════════════════════════

# The head's shape, as a radius per direction from its centre (x across, y
# up, z forward; φ the azimuth from straight ahead, θ the elevation): an
# ellipsoid, the jaw narrowing under it, and the face's planes as soft bumps
# and hollows — brow, sockets, cheekbones, nose, lips, chin. Plain on purpose.
FACE = [  # φ, θ, σφ, σθ, metres (out +, in −)
    (0.00, -0.08, 0.070, 0.16, 0.017),     # the nose's bridge and ridge
    (0.00, -0.21, 0.090, 0.06, 0.010),     # its tip
    (0.00, -0.30, 0.05, 0.03, -0.004),     # under it
    (0.36, 0.21, 0.24, 0.06, 0.006), (-0.36, 0.21, 0.24, 0.06, 0.006),     # brow
    (0.38, 0.09, 0.13, 0.08, -0.011), (-0.38, 0.09, 0.13, 0.08, -0.011),   # eye sockets
    (0.40, 0.095, 0.07, 0.045, 0.004), (-0.40, 0.095, 0.07, 0.045, 0.004),  # the eyes in them
    (0.62, -0.12, 0.15, 0.10, 0.005), (-0.62, -0.12, 0.15, 0.10, 0.005),   # cheekbones
    (0.55, -0.40, 0.14, 0.12, -0.004), (-0.55, -0.40, 0.14, 0.12, -0.004),  # under them
    (0.00, -0.45, 0.22, 0.07, 0.005),      # lips
    (0.00, -0.475, 0.20, 0.012, -0.003),   # the mouth's line
    (0.00, -0.76, 0.26, 0.14, 0.008),      # chin
    (1.15, 0.25, 0.25, 0.18, -0.004), (-1.15, 0.25, 0.25, 0.18, -0.004),   # temples
]


def head_r(d):
    """The head's radius along unit directions d (N×3)."""
    dx, dy, dz = d[:, 0], d[:, 1], d[:, 2]
    jaw = smooth01(-0.10, -0.85, dy)
    ax = 0.078 * (1 - 0.24 * jaw)
    ay = np.where(dy > 0, 0.114, 0.118)
    az = np.where(dz > 0, 0.098 - 0.004 * jaw, 0.104)
    r = 1 / np.sqrt((dx / ax) ** 2 + (dy / ay) ** 2 + (dz / az) ** 2)
    phi = np.arctan2(dx, dz)
    th = np.arcsin(np.clip(dy, -1, 1))
    for p, t, sp, st, amp in FACE:
        r = r + amp * np.exp(-(((phi - p) / sp) ** 2 + ((th - t) / st) ** 2))
    return r


def cube_sphere(n):
    """Unit directions on a subdivided cube (n × n quads a face), shared
    vertices, quads facing out."""
    V, F, key = [], [], {}

    def vid(p):
        q = unit(p)
        kk = tuple(np.round(q, 6))
        if kk not in key:
            key[kk] = len(V)
            V.append(q)
        return key[kk]
    for ax in range(3):
        for sgn in (-1, 1):
            u_ax, v_ax = [a for a in range(3) if a != ax]
            grid = {}
            for i in range(n + 1):
                for j in range(n + 1):
                    p = np.zeros(3)
                    p[ax] = sgn
                    p[u_ax] = -1 + 2 * i / n
                    p[v_ax] = -1 + 2 * j / n
                    grid[i, j] = vid(p)
            for i in range(n):
                for j in range(n):
                    f = [grid[i, j], grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]]
                    a, b, c = V[f[0]], V[f[1]], V[f[2]]
                    if np.cross(b - a, c - a) @ a < 0:
                        f = f[::-1]
                    F.append(tuple(f))
    return np.array(V), F


def face_sphere():
    """Unit directions on a latitude-longitude grid packed toward the face
    (azimuth and elevation both closer together in front, where the nose,
    brow and lips need the vertices), and its quads, poles fanned."""
    t = np.linspace(-1, 1, 27)[:-1]
    phis = np.pi * np.sign(t) * np.abs(t) ** 1.45
    us = np.linspace(-1, 1, 16)
    ths = np.where(us < 0, -1.40 * np.abs(us) ** 1.25, 1.35 * us ** 1.5) - 0.08 * (1 - us ** 2)
    na, nt = len(phis), len(ths)
    V = []
    for th in ths:
        for ph in phis:
            V.append((math.cos(th) * math.sin(ph), math.sin(th), math.cos(th) * math.cos(ph)))
    V += [(0, -1, 0), (0, 1, 0)]
    V = np.array(V)
    F = []
    for i in range(nt - 1):
        for j in range(na):
            jj = (j + 1) % na
            F.append((i * na + j, (i + 1) * na + j, (i + 1) * na + jj, i * na + jj))
    for j in range(na):
        jj = (j + 1) % na
        F.append((na * nt, j, jj))
        F.append((na * nt + 1, (nt - 1) * na + jj, (nt - 1) * na + j))
    out = []
    for f in F:
        a, b, c = V[f[0]], V[f[1]], V[f[2]]
        nrm = np.cross(b - a, c - a)
        out.append(f if nrm @ (a + b + c) >= 0 else tuple(reversed(f)))
    return V, out


def head_piece(J, k, x0, zh, neck_top, nc):
    """A plain human head in a comm cap ("Snoopy cap") on the Head bone: a
    cube sphere shaped by head_r, the face painted (textures/suit/head.png);
    the cap a shell 5 mm off the skull with its ear cups, two mic booms and a
    chin strap; the neck rising out of the neck ring's well."""
    Hj = J("Head")
    hc = Hj + np.array([0, 0.150, 0.020]) * k

    def head_w(P):
        return [blend("Back", "Head", float(smooth01(Hj[1] - 0.010 * k, Hj[1] + 0.045 * k, p[1]))) for p in P]

    D_, F = face_sphere()
    V = hc + D_ * head_r(D_)[:, None] * k
    hp = Piece("Head", "SuitHead", V, F, head_w, (1, 1, 1), tile=1.0, dirt="none")
    hp.uvmode = "face"
    hp.face = (hc, k)

    # the cap: the skull's shape 5 mm out, over the crown, the forehead to
    # above the brows, the ears and the back of the head
    D2, F2 = cube_sphere(8)
    V2 = hc + D2 * (head_r(D2) + 0.0055)[:, None] * k
    keep = []
    for f in F2:
        d = unit(np.mean(D2[list(f)], axis=0))
        phi = math.atan2(d[0], d[2])
        th = math.asin(d[1])
        face = abs(phi) < 1.12 and th < 0.30
        low = th < -0.32 - 0.25 * max(0.0, (abs(phi) - 1.6) / 1.5)
        if not (face or low):
            keep.append(f)
    # two panels: the white crown strip and the black sides, each its own
    # piece so the colour changes at a seam, not across a blurred vertex
    # (the sides are the cube sphere's ±X faces: their edges run as clean
    # curves over the crown and round the face, not a staircase)
    def side_face(f):
        d = np.abs(unit(np.mean(D2[list(f)], axis=0)))
        return d[0] >= d[1] and d[0] >= d[2]
    for nm, col, test in (("CapTop", CAP_W, lambda f: not side_face(f)), ("CapSide", CAP_B, side_face)):
        sel = [f for f in keep if test(f)]
        used = sorted({q for f in sel for q in f})
        remap = {q: i for i, q in enumerate(used)}
        cp = Piece(nm, "SuitHead", V2[used], [tuple(remap[q] for q in f) for f in sel], {"Head": 1}, col,
                   tile=0.25, dirt="cap")
        cp.uvmode = "plain"      # smooth cloth: the head texture's plain corner, coloured per vertex
    for sx in (-1, 1):
        ec = hc + np.array([sx * 0.080, -0.022, -0.006]) * k
        V, F = cyl_mesh(ec - X * sx * 0.004 * k, ec + X * sx * 0.020 * k, 0.033 * k, segs=12, r1=0.029 * k)
        Piece("EarCup", "SuitShell", V, F, {"Head": 1}, SHELL_D, tile=0.2, dirt="hard", sharp=40)
        # the mic boom: from the cup forward to the corner of the mouth
        tip = hc + np.array([sx * 0.040, -0.052, 0.098]) * k
        pts = [ec + X * sx * 0.014 * k, ec + np.array([sx * 0.012, -0.020, 0.055]) * k, tip]
        br = [dict(c=p, r=0.0035 * k, w={"Head": 1}, col=SHELL_D) for p in bezier_path(pts, 8)]
        V, F, UVc, W, C = loft(limb(br, Y), 5, cap0=True, cap1=True, tile=0.1)
        Piece("Boom", "SuitShell", V, F, W, C, UVc=UVc, dirt="hard")
        dirn = unit(pts[2] - pts[1])
        V, F = cyl_mesh(tip - dirn * 0.004 * k, tip + dirn * 0.014 * k, 0.0080 * k, segs=8)
        Piece("Mic", "SuitShell", V, F, {"Head": 1}, (0.08, 0.08, 0.085), tile=0.1, dirt="hard")
    # the chin strap, under the jaw from cup to cup
    pts = [hc + np.array([-0.076, -0.050, -0.004]) * k, hc + np.array([-0.050, -0.098, 0.030]) * k,
           hc + np.array([0, -0.112, 0.050]) * k, hc + np.array([0.050, -0.098, 0.030]) * k,
           hc + np.array([0.076, -0.050, -0.004]) * k]
    sr = [dict(c=p, r=0.003 * k, r2=0.008 * k, w={"Head": 1}, col=CAP_B) for p in bezier_path(pts, 9)]
    V, F, UVc, W, C = loft(limb(sr, Y), 6, tile=0.1)
    Piece("ChinStrap", "SuitFabric", V, F, W, C, UVc=UVc, dirt="cap")
    # the neck: out of the well in the neck ring and up into the head, the
    # cooling garment's collar at its base
    nr = []
    for y, r, w in ((neck_top - 0.010 * k, 0.053, {"Back": 1}), (neck_top + 0.018 * k, 0.052, blend("Back", "Head", 0.2)),
                    (Hj[1] + 0.035 * k, 0.048, blend("Back", "Head", 0.75)), (Hj[1] + 0.070 * k, 0.042, {"Head": 1})):
        nr.append(dict(c=(x0, y, Hj[2] - 0.012 * k), e1=X, e2=Z, r1=r * k, r2=r * k * 1.1, w=w))
    V, F, UVc, W, C = loft(nr, 12, tile=0.25)
    npc = Piece("Neck", "SuitHead", V, F, W, (1, 1, 1), dirt="none")
    npc.uvmode = "face"
    npc.face = (hc, k)
    cr = [dict(c=(x0, neck_top - 0.020 * k + y * k, Hj[2] - 0.004 * k), e1=X, e2=Z, r1=r * k, r2=r * k * 1.1,
               w={"Back": 1}, col=(0.50, 0.55, 0.62)) for y, r in ((0.0, 0.060), (0.026, 0.059), (0.032, 0.054))]
    V, F, UVc, W, C = loft(cr, 12, tile=0.25)
    Piece("Collar", "SuitFabric", V, F, W, C, UVc=UVc, dirt="none")


# ═════════════════════════════════════════════════════════════════════════════
# the helmet: EVVA over a clear bubble, the gold visor, the lamps
# ═════════════════════════════════════════════════════════════════════════════

def helmet(J, k, x0, zh, neck_ring):
    nc, nax = neck_ring
    base = nc + nax * 0.026 * k             # the helmet's ring seats on the neck ring
    R = 0.160 * k
    hc = np.array([x0, base[1] + 0.112 * k, base[2] + 0.024 * k])   # the bubble's centre
    # the helmet's own mating ring
    ring_piece("HelmetRing", "SuitMetal", base + nax * 0.010 * k, nax, 0.118 * k, 0.140 * k, 0.020 * k, "Back", METAL,
               segs=20, part="helmet", band=METAL_D)

    # The bubble: a sphere over a short skirt down to the ring (the EMU's
    # helmet is a bubble on a collar, not a ball). Clear: its own material.
    def bubble_rings(scale, skip_front=False):
        prof = []
        for a in np.linspace(0, 104, 8):
            r = math.radians(a)
            prof.append((R * scale * math.sin(r), R * scale * math.cos(r)))
        # the skirt to the ring
        prof.append((0.140 * k * scale, base[1] + 0.012 * k - hc[1]))
        return prof
    brings = lathe_pts(bubble_rings(1.0)[1:], hc, Y, Z, 20)
    for r in brings:
        r["w"] = {"Back": 1}
    # the skirt ring sits on the neck ring (the bubble is forward of it)
    brings[-1]["c"] = base + nax * 0.012 * k
    V, F, UVc, W, C = loft(brings, 20, cap0=True, tile=0.5)
    Piece("Bubble", "SuitBubble", V, F, W, (1, 1, 1), UVc=UVc, part="helmet", dirt="none")

    # The EVVA shell over the top, back and sides, with the visor opening
    # cut from its front: a thick shell, its edge rolled.
    Re = R * 1.075
    shell_prof = []
    for a in np.linspace(0, 112, 10):
        r = math.radians(a)
        shell_prof.append((Re * math.sin(r), Re * math.cos(r)))
    srings = lathe_pts(shell_prof[1:], hc, Y, Z, 24)
    for r in srings:
        r["w"] = {"Back": 1}
        r["col"] = SHELL
    V, F, UVc, W, C = loft(srings, 24, cap0=True, tile=0.5)
    # the opening: front faces between brow and chin, ±62° either side
    keep = []
    for f, uv in zip(F, UVc):
        cc = np.mean([V[i] for i in f], axis=0) - hc
        az = math.degrees(math.atan2(cc[0], cc[2]))
        el_ = math.degrees(math.atan2(cc[1], math.hypot(cc[0], cc[2])))
        if abs(az) < 64 and el_ < 34:
            continue
        keep.append((f, uv))
    F = [f for f, _ in keep]
    UVc = [u for _, u in keep]
    ev = Piece("EVVA", "SuitShell", V, F, W, C, UVc=UVc, part="helmet", dirt="evva")
    # give it thickness and a rolled edge
    m = ev.ob.modifiers.new("solid", "SOLIDIFY")
    m.thickness = 0.008 * k
    m.offset = 1.0
    m.use_rim = True
    ev.apply()
    # a dark seam where the EVVA's two halves meet, over the crown
    st = []
    for a in np.linspace(-10, 112, 11):
        r = math.radians(a)
        st.append(dict(c=hc + np.array([0, Re * 1.06 * math.cos(r), -Re * 1.06 * math.sin(r)]),
                       r=0.0035 * k, w={"Back": 1}, col=SHELL_G))
    V, F, UVc, W, C = loft(limb(st, X), 5, tile=0.1)
    Piece("EVVAseam", "SuitShell", V, F, W, C, UVc=UVc, part="helmet", dirt="evva")

    # The gold sun visor: a spherical cap filling the opening, standing just
    # off the bubble and tucked under the EVVA's front edge.
    Rv = R * 1.035
    vr = []
    for el_ in np.linspace(-50, 38, 9):
        vr.append(el_)
    Vv, UVv = [], []
    azs = np.linspace(-68, 68, 17)
    for el_ in vr:
        for az in azs:
            e, a = math.radians(el_), math.radians(az)
            p = hc + Rv * np.array([math.cos(e) * math.sin(a), math.sin(e), math.cos(e) * math.cos(a)])
            Vv.append(p)
            UVv.append((0.5 + az / 150.0, 0.5 - el_ / 110.0))
    F, UVc = [], []
    na = len(azs)
    for i in range(len(vr) - 1):
        for j in range(na - 1):
            f = (i * na + j, i * na + j + 1, (i + 1) * na + j + 1, (i + 1) * na + j)
            a, b, c = Vv[f[0]], Vv[f[1]], Vv[f[2]]
            if np.cross(b - a, c - a) @ (a - hc) < 0:
                f = tuple(reversed(f))
            F.append(f)
            UVc.append([UVv[q] for q in f])
    Piece("Visor", "SuitVisor", Vv, F, {"Back": 1}, (1, 1, 1), UVc=UVc, part="visor", dirt="none")

    # The lamps (EHIP-style): a housing at each temple on a bracket, a lens
    # forward; the camera on the left one.
    for sx in (-1, 1):
        lc = hc + np.array([sx * (Re + 0.022 * k), 0.028 * k, 0.040 * k])
        V, F = box_mesh(lc, (0.040 * k, 0.046 * k, 0.110 * k))
        Piece("LampHousing", "SuitShell", V, F, {"Back": 1}, SHELL_G, tile=0.5, part="helmet", dirt="evva",
              mods=[("bevel", 0.006 * k, 2, 35)], sharp=40)
        V, F = box_mesh(lc - np.array([sx * 0.024, 0.0, 0.03]) * k, (0.022 * k, 0.026 * k, 0.03 * k))
        Piece("LampBracket", "SuitShell", V, F, {"Back": 1}, SHELL_D, tile=0.5, part="helmet", dirt="evva",
              smooth=False, sharp=30)
        for dy in (0.010, -0.011):
            p0 = lc + np.array([0, dy, 0.055]) * k
            V, F = cyl_mesh(p0 - Z * 0.004 * k, p0 + Z * 0.004 * k, 0.0105 * k, segs=8)
            Piece("LampBezel", "SuitShell", V, F, {"Back": 1}, SHELL_D, tile=0.2, part="helmet", dirt="none",
                  smooth=False, sharp=30)
            V, F = cyl_mesh(p0 + Z * 0.0035 * k, p0 + Z * 0.0055 * k, 0.0085 * k, segs=8)
            Piece("LampLens", "SuitLamp", V, F, {"Back": 1}, (1, 1, 1), tile=0.2, part="lamps", dirt="none",
                  smooth=False, sharp=30)
        if sx > 0:
            cc = lc + np.array([0.0, 0.040, 0.012]) * k
            V, F = box_mesh(cc, (0.036 * k, 0.034 * k, 0.07 * k))
            Piece("Camera", "SuitShell", V, F, {"Back": 1}, SHELL_D, tile=0.5, part="helmet", dirt="evva",
                  mods=[("bevel", 0.003 * k, 1)], sharp=30)
            V, F = cyl_mesh(cc + Z * 0.035 * k, cc + Z * 0.045 * k, 0.011 * k, segs=12)
            Piece("CameraLens", "SuitShell", V, F, {"Back": 1}, (0.05, 0.05, 0.06), tile=0.2, part="helmet",
                  dirt="none", smooth=False, sharp=30)


# ═════════════════════════════════════════════════════════════════════════════
# export
# ═════════════════════════════════════════════════════════════════════════════

def export(rig, D, path):
    arrays = {"D": D}
    manifest = []
    for idx, pc in enumerate(PIECES):
        pc.apply()
        ob = pc.ob
        me = ob.data
        if pc.sharp is not None:
            me.set_sharp_from_angle(angle=math.radians(pc.sharp))
        me.calc_loop_triangles()
        nv = len(me.vertices)
        P = np.zeros(nv * 3)
        me.vertices.foreach_get("co", P)
        P = P.reshape(-1, 3)
        tris = np.zeros(len(me.loop_triangles) * 3, np.int64)
        me.loop_triangles.foreach_get("loops", tris)
        tris = tris.reshape(-1, 3)
        lv = np.zeros(len(me.loops), np.int64)
        me.loops.foreach_get("vertex_index", lv)
        cn = np.zeros(len(me.loops) * 3)
        me.corner_normals.foreach_get("vector", cn)
        cn = cn.reshape(-1, 3)
        # per-vertex weights
        if callable(pc.W):
            Wl = pc.W(P)
        elif isinstance(pc.W, dict):
            Wl = [pc.W] * nv
        else:
            names = {g.index: g.name for g in ob.vertex_groups}
            Wl = []
            for v in me.vertices:
                Wl.append({names[g.group]: g.weight for g in v.groups if g.weight > 1e-5})
        Jn = np.zeros((nv, 4), np.int64)
        Wn = np.zeros((nv, 4))
        for i, wd in enumerate(Wl):
            items = sorted(((rig.index[b], w) for b, w in wd.items() if w > 1e-4), key=lambda t: -t[1])[:4]
            if not items:
                items = [(rig.index["Back"], 1.0)]
            tot = sum(w for _, w in items)
            for q, (b, w) in enumerate(items):
                Jn[i, q] = b
                Wn[i, q] = w / tot
        # per-vertex colour
        if callable(pc.C):
            Vn = np.zeros((nv, 3))
            Cv = np.asarray(pc.C(P, Vn), float)
        elif np.asarray(pc.C).ndim == 1:
            Cv = np.tile(np.asarray(pc.C, float), (nv, 1))
        else:
            ca = me.color_attributes.get("col")
            if ca is not None and ca.domain == "POINT" and len(ca.data) == nv:
                cc = np.zeros(nv * 4, np.float32)
                ca.data.foreach_get("color", cc)
                Cv = cc.reshape(-1, 4)[:, :3].astype(float)
            else:
                Cv = np.tile(np.asarray(pc.C, float)[0], (nv, 1))
        # per-corner uv
        corners = tris.reshape(-1)
        cv = lv[corners]
        if pc.uvmode == "given" and me.uv_layers:
            uvl = np.zeros(len(me.loops) * 2)
            me.uv_layers[0].data.foreach_get("uv", uvl)
            UV = uvl.reshape(-1, 2)[corners]
        elif pc.uvmode == "plain":
            UV = np.tile([0.012, 0.012], (len(corners), 1))
        elif pc.uvmode == "face":
            hc, kk = pc.face
            rel = (P[cv] - hc) / kk
            # the face's own angles (head_r's φ, θ), which the painted face
            # (gen_suit.py tex_head) is drawn in: u = ½ + φ·0.2546, v = ½ − θ/2
            phi = np.arctan2(rel[:, 0], rel[:, 2])
            th = np.arcsin(np.clip(rel[:, 1] / np.maximum(np.linalg.norm(rel, axis=1), 1e-9), -1, 1))
            UV = np.stack([np.clip(0.5 + phi * 0.2546, 0.01, 0.99), np.clip(0.5 - th / 2.0, 0.01, 0.99)], 1)
        else:
            tp = P[lv[tris]]
            fn = np.cross(tp[:, 1] - tp[:, 0], tp[:, 2] - tp[:, 0])
            ax = np.argmax(np.abs(fn), 1)
            ax = np.repeat(ax, 3)
            pp = P[cv] / pc.tile
            UV = np.where((ax == 0)[:, None], pp[:, [2, 1]], np.where((ax == 1)[:, None], pp[:, [0, 2]], pp[:, [0, 1]]))
        N = cn[corners]
        # weld identical corners into vertices
        key = np.hstack([cv[:, None].astype(float), np.round(N * 1e4), np.round(UV * 1e5)])
        _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
        inv = inv.reshape(-1)
        vid = cv[first]
        I = inv.reshape(-1, 3)
        arrays[f"{idx}_P"] = P[vid]
        arrays[f"{idx}_N"] = N[first]
        arrays[f"{idx}_UV"] = UV[first]
        arrays[f"{idx}_C"] = Cv[vid]
        arrays[f"{idx}_J"] = Jn[vid]
        arrays[f"{idx}_W"] = Wn[vid]
        arrays[f"{idx}_I"] = I
        manifest.append(dict(name=pc.name, mat=pc.mat, part=pc.part, dirt=pc.dirt, tris=int(len(I))))
    arrays["manifest"] = np.frombuffer(json.dumps(manifest).encode(), np.uint8)
    np.savez_compressed(path, **arrays)
    tot = {}
    for m in manifest:
        tot[m["part"]] = tot.get(m["part"], 0) + m["tris"]
    print("SUIT_BLENDER", json.dumps(tot))


def main():
    global COL
    bpy.ops.wm.read_factory_settings(use_empty=True)
    COL = bpy.data.collections.new("suit")
    bpy.context.scene.collection.children.link(COL)
    rig = Rig(RIG_PATH)
    D = build(rig)
    export(rig, D, OUT_PATH)


main()
