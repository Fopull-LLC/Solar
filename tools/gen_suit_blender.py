"""Model the crew's EVA suit in Blender (headless) — the geometry half of
tools/gen_suit.py, which runs this and writes the glbs.

    blender --background --factory-startup --python tools/gen_suit_blender.py -- RIG.glb OUT.npz [LOD]

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

THE 2026-11-09 REVAMP ("cartoony"): the soft parts are subdivided twice
(arms) and once (the lower body) and the CLOTH'S FOLDS are laid on the
finished surface (arm_disp, leg_disp: bunching, compression folds in the
crooks, diagonal drape, unevenness), the glove's region thinned by a masked
decimation (Piece.thin) so the sleeves keep their edge loops; the bearings
are lathed profiles (two races, a groove, chamfers); the hardware is
modelled (rbox, bolt, knob, hose, connector: the DCM's controls, the
umbilicals, the PLSS's panel, grille and SOP, the helmet's lamp housings and
camera, the boots' straps and lugs); one surface may carry several materials
(`mats` / `fmat`: the glove's RTV, the boot's rubber) with its normals kept
whole; ambient occlusion is baked into the vertex colours by Blender's ray
tracer (bake_ao). Argument 3 is the LOD (0, 1, 2): the same build with fewer
subdivisions and segments and the smallest hardware left off.

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
# LEVEL OF DETAIL: 0 the full suit (the player, close crew), 1 and 2 coarser
# builds of the SAME surfaces (fewer subdivision levels and ring segments,
# the smallest hardware left off) for crew seen farther away and in numbers:
# the dolls in their seats, the bodies, the remains. Same rig, same weights
# (painted by the same functions), so every LOD bends alike.
LOD = int(argv[2]) if len(argv) > 2 else 0

AUTHOR_ABDUCT = 50.0      # the arms are modelled this far down from the rig's T
AUTHOR_ELBOW = 35.0       # … with the elbows this far bent
AUTHOR_KNEE = 25.0        # … and the knees (see the soft suit's notes)
SCYE_BORE = 0.088         # the scye bearing's bore (radius, m on the male rig)


def lod(*v):
    """The value for this LOD (v[0] the full suit, v[1], v[2] coarser)."""
    return v[min(LOD, len(v) - 1)]


def segs_(n):
    """Ring segments for hardware at this LOD (a multiple of 4, at least 8)."""
    return max(8, int(round(n * lod(1.0, 0.6, 0.4) / 4)) * 4)


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


def vnoise(P, seed, freq):
    """Smooth 3-D value noise in [0, 1] at points P (N x 3)."""
    P = np.asarray(P, float) * freq
    i = np.floor(P).astype(np.int64)
    f = P - i
    f = f * f * (3 - 2 * f)

    def h(ix, iy, iz):
        n = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791) ^ (seed * 2654435761)
        n = (n ^ (n >> 13)) * 1274126177
        return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * h(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz)
    return out


def fbm(P, seed, freq, octaves=3):
    """Fractal noise, centred on 0 (about +-0.5)."""
    out, amp, tot = 0.0, 1.0, 0.0
    for o in range(octaves):
        out = out + amp * (vnoise(P, seed + o * 17, freq * 2 ** o) - 0.5)
        tot += amp
        amp *= 0.5
    return out / tot * 2


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
                 sharp=None, smooth=True, mods=(), mats=None, fmat=None, ao=True):
        self.name, self.mat, self.part, self.tile, self.dirt = name, mat, part, tile, dirt
        self.W, self.C = W, C
        self.sharp = sharp
        # one surface, several materials: `mats` names them, `fmat` gives each
        # face's index (subdivision carries it to the faces it makes); the
        # export splits the triangles by it but keeps the normals of the
        # whole, so the cloth and the rubber meet with no shading seam
        self.mats = mats
        self.mat_col = {}            # material index -> the colour its faces take
        self.ao_on = ao
        V = np.asarray(V, float)
        me = bpy.data.meshes.new(name)
        me.from_pydata(V.tolist(), [], [list(map(int, f)) for f in F])
        me.update()
        if mats:
            for mn in mats:
                me.materials.append(bpy.data.materials.get(mn) or bpy.data.materials.new(mn))
            me.polygons.foreach_set("material_index", np.asarray(fmat, np.int32))
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
        elif kind == "recalc":    # faces wound outward (cages are built without caring)
            import bmesh
            bm = bmesh.new()
            bm.from_mesh(ob.data)
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            bm.to_mesh(ob.data)
            bm.free()
            ob.data.update()
        elif kind == "bool":
            m = ob.modifiers.new("bool", "BOOLEAN")
            m.operation = a[0]
            m.object = a[1].ob
            m.solver = "EXACT"
        self.apply()

    def displace(self, fn):
        """Move every vertex by fn(P, N, G) (N×3 metres): the cloth's folds,
        laid on after subdivision. G is the vertex groups as dicts."""
        self.apply()
        me = self.ob.data
        nv = len(me.vertices)
        P = np.zeros(nv * 3)
        me.vertices.foreach_get("co", P)
        P = P.reshape(-1, 3)
        N = np.zeros(nv * 3)
        me.vertices.foreach_get("normal", N)
        N = N.reshape(-1, 3)
        names = {g.index: g.name for g in self.ob.vertex_groups}
        G = [{names[g.group]: g.weight for g in v.groups} for v in me.vertices]
        d = np.asarray(fn(P, N, G), float)
        me.vertices.foreach_set("co", (P + d).reshape(-1))
        me.update()

    def thin(self, mask, cut):
        """Collapse-decimate only where mask(P) is 1 (a vertex group drives the
        modifier), removing about `cut` of the triangles there: the glove's
        fingers and palm, small and densely subdivided, give up triangles the
        eye can't find, the sleeve keeps its quads and edge loops."""
        self.apply()
        me = self.ob.data
        nv = len(me.vertices)
        P = np.zeros(nv * 3)
        me.vertices.foreach_get("co", P)
        m = np.asarray(mask(P.reshape(-1, 3)), float)
        vg = self.ob.vertex_groups.new(name="_dec")
        for w in np.unique(np.round(m, 2)):
            ids = np.nonzero(np.round(m, 2) == w)[0].tolist()
            if w > 0 and ids:
                vg.add(ids, float(w), "REPLACE")
        tri = sum(len(p.vertices) - 2 for p in me.polygons)
        sel = sum(len(p.vertices) - 2 for p in me.polygons if m[list(p.vertices)].mean() > 0.5)
        md = self.ob.modifiers.new("thin", "DECIMATE")
        md.decimate_type = "COLLAPSE"
        md.ratio = max(0.05, 1.0 - cut * sel / max(tri, 1))
        md.vertex_group = "_dec"
        md.vertex_group_factor = 1.0
        md.use_collapse_triangulate = True
        self.apply()
        self.ob.vertex_groups.remove(self.ob.vertex_groups["_dec"])

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


def lathe_piece(name, mat, c, axis, prof, W, segs, part="suit", dirt="metal", sharp=35, ref=None, a0=0.0, **kw):
    """A solid of revolution about `axis` through `c` from a closed profile
    [(rho, h, colour), …] (h along the axis), smooth-shaded with hard edges
    where the profile turns more than `sharp` degrees. A profile point listed
    twice with two colours splits the surface there, so a colour change is a
    clean line, not a blur across a vertex. UVs: u round (4 tiles), v along
    the profile's length."""
    axis = unit(axis)
    if ref is None:
        ref = X if abs(axis @ X) < 0.9 else Z
    e1 = unit(np.asarray(ref, float) - axis * (axis @ ref))
    e2 = np.cross(axis, e1)
    c = np.asarray(c, float)
    V, C, vs = [], [], [0.0]
    for k_, (rho, h, col) in enumerate(prof):
        if k_:
            vs.append(vs[-1] + math.hypot(rho - prof[k_ - 1][0], h - prof[k_ - 1][1]) / 0.1)
        for i in range(segs):
            a = a0 + TAU * i / segs
            V.append(c + axis * h + (e1 * math.cos(a) + e2 * math.sin(a)) * rho)
            C.append(col)
    np_ = len(prof)
    F, UVc = [], []
    for k_ in range(np_):
        k2 = (k_ + 1) % np_
        if math.hypot(prof[k_][0] - prof[k2][0], prof[k_][1] - prof[k2][1]) < 1e-9:
            continue                                  # a colour split: no face
        v0, v1 = vs[k_], (vs[k2] if k2 else vs[-1] + 0.1)
        for i in range(segs):
            j = (i + 1) % segs
            f = (k_ * segs + i, k_ * segs + j, k2 * segs + j, k2 * segs + i)
            P0, P1, P2, P3 = V[f[0]], V[f[1]], V[f[2]], V[f[3]]
            # outward: away from the solid's inside (the profile's centroid)
            cen = np.mean([[p[0], p[1]] for p in prof], axis=0)
            m = (P0 + P1 + P2 + P3) / 4 - c
            hh = m @ axis
            rr = np.linalg.norm(m - axis * hh)
            want = unit(m - axis * hh) * (rr - cen[0]) + axis * (hh - cen[1])
            nrm = np.cross(P1 - P0, P3 - P0) + np.cross(P2 - P1, P0 - P1)
            u0, u1 = i / segs * 4, (i + 1) / segs * 4
            uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
            if nrm @ want < 0:
                f, uv = tuple(reversed(f)), uv[::-1]
            F.append(f)
            UVc.append(uv)
    return Piece(name, mat, V, F, W, np.asarray(C, float), UVc=UVc, part=part, dirt=dirt, smooth=True, sharp=sharp,
                 **kw)


def ring_piece(name, mat, c, axis, ri, ro, w, bone, col, segs=16, part="suit", dirt="metal", band=None):
    """A BEARING (or a disconnect, or the neck ring): two races of anodised
    aluminium about `axis`, each with chamfered edges, the split between them
    a sunk groove, the bore's lip rolled in toward the cloth. `band` colours
    the outer race's face (the wrist disconnects' blue and red, the EMU's way
    of telling left from right). The ring is wider than the cloth it covers on
    both sides, so the cloth always disappears into it."""
    cw = min(0.0025 * (ro / 0.08), w * 0.16)          # the chamfers
    g = min(0.0018, (ro - ri) * 0.18)                  # the groove's depth
    gw = w * 0.07
    bc = band if band is not None else col
    lip = ri - 0.0015
    prof = [
        (lip, -w / 2 + cw, col), (ri + cw, -w / 2, col), (ro - cw, -w / 2, col), (ro, -w / 2 + cw, col),
        (ro, -gw, col), (ro - g, -gw * 0.4, col),
        (ro - g, -gw * 0.4, bc), (ro, gw, bc), (ro, w / 2 - cw, bc), (ro - cw, w / 2, bc),
        (ro - cw, w / 2, col), (ri + cw, w / 2, col), (lip, w / 2 - cw, col),
    ]
    if LOD >= 2:          # far away: one chamfered race, no groove
        prof = [(lip, -w / 2 + cw, col), (ro - cw, -w / 2, col), (ro, -w / 2 + cw, col), (ro, w / 2 - cw, bc),
                (ro - cw, w / 2, col), (lip, w / 2 - cw, col)]
    return lathe_piece(name, mat, c, axis, prof, {bone: 1}, segs_(max(int(segs * 1.25), 16)),
                       part=part, dirt=dirt, sharp=35)


def rbox(name, mat, c, size, M=None, W=None, col=None, r=0.003, seg=2, part="suit", dirt="hard", tile=0.5,
         sharp=40, angle=40):
    """A box with its edges rounded over `r` in `seg` segments (a bevel by
    angle), smooth-shaded so the rounds catch the light and the faces stay
    flat: machined and moulded hardware."""
    V, F = box_mesh(c, size, M)
    seg = lod(seg, max(1, seg - 1), 1)
    mods = [("bevel", r, seg, angle)] if r > 0 else []
    return Piece(name, mat, V, F, W or {"Back": 1}, col if col is not None else SHELL_G, tile=tile, part=part,
                 dirt=dirt, mods=mods, sharp=sharp)


def bolt(name, p, n, r, h, W, col=None, part="suit", dirt="metal", mat="SuitMetal"):
    """A hex-head cap screw standing `h` proud along `n` at `p` (its washer a
    touch wider, the head chamfered)."""
    if LOD >= 2:
        return None
    c = col if col is not None else METAL_D
    prof = [(1e-4, -0.0004, c), (r * 1.15, -0.0004, c), (r * 1.15, h * 0.75, c), (r * 0.8, h, c), (1e-4, h, c)]
    return lathe_piece(name, mat, p, n, prof, W, 6, part=part, dirt=dirt, sharp=30)


def knob(name, p, n, r, h, W, col, mat="SuitShell", flutes=True, part="suit", dirt="hard", ref=None):
    """A control knob along `n` at `p`: a skirt, a fluted grip (the flutes
    as a 3-to-1 ripple round it), a domed cap."""
    segs = lod(16, 12, 8)
    prof = [(1e-4, 0.0, col), (r * 1.08, 0.0, col), (r * 1.08, h * 0.18, col), (r, h * 0.24, col),
            (r, h * 0.86, col), (r * 0.82, h, col), (1e-4, h * 1.04, col)]
    pc = lathe_piece(name, mat, p, n, prof, W, segs, part=part, dirt=dirt, sharp=35, ref=ref)
    if flutes and LOD == 0:
        me = pc.ob.data
        n_ = unit(n)
        P = np.zeros(len(me.vertices) * 3)
        me.vertices.foreach_get("co", P)
        P = P.reshape(-1, 3)
        rel = P - np.asarray(p)
        hh = rel @ n_
        rad = rel - np.outer(hh, n_)
        rr = np.linalg.norm(rad, axis=1)
        ref_ = unit(np.cross(n_, X if abs(n_ @ X) < 0.9 else Z))
        ang = np.arctan2(rad @ np.cross(n_, ref_), rad @ ref_)
        grip = (hh > h * 0.26) & (hh < h * 0.84) & (rr > r * 0.9)
        f = 1.0 - 0.10 * (np.cos(ang * segs / 2) > 0) * grip
        P = np.asarray(p) + np.outer(hh, n_) + rad * f[:, None]
        me.vertices.foreach_set("co", P.reshape(-1))
        me.update()
    return pc


def hose(name, pts, r, W, col, pitch=0.012, segs=8, part="suit", dirt="hard", mat="SuitRubber", n=None):
    """A corrugated hose along a Catmull-Rom path through `pts`: ribs every
    `pitch` metres (crests r, troughs 0.86 r), 10 sides; ends capped."""
    P = np.array(bezier_path(pts, 200))
    L = np.concatenate([[0.0], np.cumsum([np.linalg.norm(P[i + 1] - P[i]) for i in range(len(P) - 1)])])
    step = pitch / 2 if LOD == 0 else pitch * 1.5
    ns = max(4, int(L[-1] / step))
    ts = np.linspace(0, L[-1], ns + 1)
    cs = [np.array([np.interp(t, L, P[:, a]) for a in range(3)]) for t in ts]
    rings = []
    for i, c in enumerate(cs):
        rr = r if (i % 2 == 0 or LOD > 0) else r * 0.86
        if i in (0, ns):
            rr = r * 1.05
        rings.append(dict(c=c, r=rr, w=W, col=col))
    V, F, UVc, Wl, C = loft(limb(rings, Z if n is None else n), lod(segs, 8, 6), cap0=True, cap1=True, tile=0.1)
    return Piece(name, mat, V, F, Wl, C, UVc=UVc, part=part, dirt=dirt)


def connector(name, p, n, r, L, W, col=None, band=None, part="suit"):
    """A fluid / electrical quick-disconnect along `n` at `p`: a mounting
    flange, the body, a knurled locking collar and the nose."""
    c = col if col is not None else METAL
    b = band if band is not None else METAL_D
    prof = [(1e-4, 0.0, c), (r * 1.45, 0.0, c), (r * 1.45, L * 0.10, c), (r * 1.05, L * 0.16, c),
            (r * 1.05, L * 0.35, c), (r * 1.05, L * 0.35, b), (r * 1.28, L * 0.40, b), (r * 1.28, L * 0.72, b),
            (r * 0.9, L * 0.78, b), (r * 0.9, L * 0.78, c), (r * 0.9, L, c), (1e-4, L, c)]
    return lathe_piece(name, "SuitMetal", p, n, prof, W, lod(12, 10, 8), part=part, dirt="metal", sharp=35)


# ═════════════════════════════════════════════════════════════════════════════
# palette (albedo multipliers; the textures carry the grain)
# ═════════════════════════════════════════════════════════════════════════════

CLOTH = (0.92, 0.915, 0.895)      # ortho-fabric TMG, a white a little tired
CLOTH_SH = (0.87, 0.865, 0.845)   # the same in a fold (the baked AO does the rest)
SHELL = (0.94, 0.94, 0.93)        # painted composite (the PLSS cover, DCM, EVVA)
SHELL_G = (0.55, 0.555, 0.55)     # grey hardware
SHELL_D = (0.17, 0.17, 0.18)      # dark hardware, rubber
ORANGE = (0.86, 0.42, 0.14)       # signal orange, used three times
METAL = (0.60, 0.61, 0.62)        # hard-anodised bearings, a matte grey
METAL_D = (0.33, 0.34, 0.36)
BLUE_A = (0.16, 0.26, 0.48)       # the left wrist disconnect's anodising
RED_A = (0.52, 0.15, 0.12)        # the right's
RUBBER = (0.15, 0.15, 0.155)      # RTV grip, sole rubber
GLOVE = (0.78, 0.775, 0.76)       # the glove's TMG, greyer than the suit
GLOVE_D = (0.52, 0.515, 0.50)     # under the gauntlet's lip
PALM = (0.16, 0.16, 0.17)         # RTV grip
SOLE = (0.14, 0.14, 0.145)
BOOT_W = (0.80, 0.79, 0.76)       # the boot's TMG, greyer and more used than the suit's
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
        D[rig.index["Upperarm." + side]] = R
        # the elbow part-bent (the forearm forward), about the elbow as posed
        Ea = (R @ np.append(J("Forearm." + side), 1.0))[:3]
        Re = rot_about(unit(np.cross(unit(Ea - J("Upperarm." + side)), Z)), AUTHOR_ELBOW, Ea)
        for b in ("Forearm", "Hand", "Fingers1", "Fingers2", "Thumb1", "Thumb2"):
            D[rig.index[b + "." + side]] = Re @ R
        # the knee part-bent (the shin back)
        Kb = J("Shin." + side)
        Rk = rot_about(unit(np.cross(unit(Kb - J("Thigh." + side)), -Z)), AUTHOR_KNEE, Kb)
        for b in ("Shin", "Foot", "Toes"):
            D[rig.index[b + "." + side]] = Rk

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
                mods=[("remesh", lod(0.0042, 0.0055, 0.007) * k), ("smooth", 0.6, 6), ("decimate", lod(3200, 1500, 800))],
                sharp=44)
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

    # ── HUT hardware: the scye housings' screws, the neck ring's latches ──
    for side, (P, n, d) in scye.items():
        e1 = unit(np.cross(n, Z))
        e2 = np.cross(n, e1)
        for i in range(8):
            a = TAU * (i + 0.5) / 8
            bp = P + n * d + (e1 * math.cos(a) + e2 * math.sin(a)) * 0.1175 * k
            bolt("ScyeBolt", bp, n, 0.0032 * k, 0.0035 * k, {"Back": 1})
    # the helmet's latches on the neck ring: three housings round it (front
    # two and the back), each with its lever
    ne1 = X
    ne2 = np.cross(nax, ne1)
    for a_deg in (55, 125, 270):
        a = math.radians(a_deg)
        rdir = ne1 * math.cos(a) + ne2 * math.sin(a)
        Ml = np.column_stack([np.cross(nax, rdir), nax, rdir])
        lc = nc + nax * 0.010 * k + rdir * 0.140 * k
        rbox("NeckLatch", "SuitMetal", lc, (0.028 * k, 0.022 * k, 0.014 * k), Ml, col=METAL_D, r=0.0025 * k,
             dirt="metal", tile=0.25)
        if LOD < 2:
            rbox("NeckLatchLever", "SuitShell", lc + rdir * 0.009 * k + nax * 0.002 * k,
                 (0.020 * k, 0.006 * k, 0.006 * k), Ml, col=ORANGE if a_deg == 270 else SHELL_D, r=0.0015 * k)

    # ── DCM: the display and control module on the lower chest ─────────────
    # A moulded housing with rounded edges; its control face tipped up to the
    # eyes carries the display behind a raised bezel, four rotary controls
    # (fan, water, and the two comm volumes), three toggles behind a guard
    # (power, comm mode, the alarm test), and at its right end the orange
    # purge valve; the SCU's multiple connector on its right side; two
    # brackets back to the HUT and two short corrugated umbilicals from its
    # underside into the HUT's front ports.
    dy = hut_y0 + 0.125 * k
    hit, _ = surf_point(tree, (x0, dy, zh + 0.5), (0, 0, -1), (x0, dy, zh + 0.15 * k))
    dz = hit[2]
    tiltd = math.radians(-16)
    Md = np.array([[1, 0, 0], [0, math.cos(tiltd), -math.sin(tiltd)], [0, math.sin(tiltd), math.cos(tiltd)]])
    dc = np.array([x0, dy, dz + 0.042 * k])
    DW, DH, DD = 0.250 * k, 0.092 * k, 0.086 * k
    rbox("DCM", "SuitShell", dc, (DW, DH, DD), Md, col=(0.80, 0.80, 0.78), r=0.011 * k, seg=3, dirt="hard",
         angle=35)
    up_d = Md @ Y
    fw_d = Md @ Z
    top_c = dc + up_d * DH / 2
    # the display: a dark window in a raised bezel on the face's front half
    dw, dh = 0.105 * k, 0.034 * k
    dpc = top_c + fw_d * 0.018 * k
    for (ox, oz, sx, sz) in ((0, dh / 2 + 0.004 * k, dw + 0.016 * k, 0.008 * k),
                             (0, -dh / 2 - 0.004 * k, dw + 0.016 * k, 0.008 * k),
                             (dw / 2 + 0.004 * k, 0, 0.008 * k, dh), (-dw / 2 - 0.004 * k, 0, 0.008 * k, dh)):
        rbox("DCMbezel", "SuitShell", dpc + X * ox + fw_d * oz + up_d * 0.002 * k, (sx, 0.005 * k, sz), Md,
             col=SHELL_D, r=0.0012 * k, seg=1)

    def disp(su, tv):
        return dpc + up_d * 0.0012 * k + X * (-dw / 2 + dw * su) + fw_d * (dh / 2 - dh * tv)
    decal_piece("DCMdisplay", "display", disp, up_d, "Back")
    # the rotary controls along the back half of the face
    kb = top_c - fw_d * 0.022 * k
    for i, (dx, r, h, col) in enumerate(((-0.098, 0.0125, 0.016, SHELL_D), (-0.064, 0.0110, 0.014, SHELL_D),
                                          (0.050, 0.0090, 0.013, SHELL_D), (0.074, 0.0090, 0.013, SHELL_D))):
        knob("DCMknob", kb + X * dx * k, up_d, r * k, h * k, {"Back": 1}, col)
    # the toggles behind their guard
    if LOD < 2:
        for i, dx in enumerate((-0.022, 0.0, 0.022)):
            p0 = kb + X * dx * k
            bolt("DCMtoggle", p0, up_d, 0.0055 * k, 0.004 * k, {"Back": 1}, col=METAL)
            tip = p0 + up_d * 0.016 * k + fw_d * (0.004 if i != 1 else -0.004) * k
            V, F = cyl_mesh(p0 + up_d * 0.003 * k, tip, 0.0018 * k, segs=8, r1=0.0024 * k)
            Piece("DCMlever", "SuitMetal", V, F, {"Back": 1}, METAL, tile=0.1, dirt="metal", sharp=40)
        gpts = [kb + X * -0.036 * k - fw_d * 0.004 * k, kb + X * -0.034 * k - fw_d * 0.004 * k + up_d * 0.022 * k,
                kb + X * 0.034 * k - fw_d * 0.004 * k + up_d * 0.022 * k, kb + X * 0.036 * k - fw_d * 0.004 * k]
        gr = [dict(c=q, r=0.0022 * k, w={"Back": 1}, col=METAL) for q in bezier_path(gpts, 12)]
        V, F, UVc, W, C = loft(limb(gr, fw_d), 6, cap0=True, cap1=True, tile=0.1)
        Piece("DCMguard", "SuitMetal", V, F, W, C, UVc=UVc, dirt="metal")
    # the purge valve: the one orange control, big enough for a glove
    knob("PurgeValve", top_c + X * 0.105 * k + fw_d * 0.004 * k, up_d, 0.0165 * k, 0.020 * k, {"Back": 1}, ORANGE)
    # the SCU's multiple connector on the right side, and the left side's
    # comm connector
    connector("SCUconnector", dc - X * DW / 2 + up_d * 0.004 * k, -X, 0.017 * k, 0.034 * k, {"Back": 1})
    connector("CommConnector", dc + X * DW / 2 + up_d * 0.008 * k, X, 0.010 * k, 0.022 * k, {"Back": 1},
              band=(0.22, 0.24, 0.27))
    # the brackets back to the HUT, and their screws
    for sx in (-1, 1):
        bc = np.array([x0 + sx * 0.082 * k, dy - 0.006 * k, (dz + dc[2] - DD / 2) / 2 + 0.002 * k])
        blen = (dc[2] - DD / 2) - dz + 0.010 * k
        rbox("DCMbracket", "SuitMetal", bc, (0.034 * k, 0.060 * k, max(blen, 0.01 * k)), None, col=METAL_D,
             r=0.003 * k, dirt="metal", tile=0.25)
        for oy in (-0.018, 0.018):
            bolt("DCMbolt", np.array([bc[0], bc[1] + oy * k, dz + 0.001 * k]) + Z * 0.0, Z, 0.0028 * k, 0.003 * k,
                 {"Back": 1})
    # the two umbilicals: out of the underside's corners, a slack loop down,
    # and into the HUT's front ports (the cooling water, the vent loop)
    for sx in (-1, 1):
        a = dc + X * sx * 0.088 * k - up_d * DH / 2 + fw_d * 0.010 * k
        portp, nrm = surf_point(tree, (x0 + sx * 0.112 * k, hut_y0 + 0.040 * k, zh + 0.5), (0, 0, -1),
                                (x0 + sx * 0.112 * k, hut_y0 + 0.040 * k, zh + 0.15 * k))
        pts = [a, a - up_d * 0.030 * k + X * sx * 0.012 * k, portp + nrm * 0.050 * k + Y * -0.035 * k + X * sx * 0.02 * k,
               portp + nrm * 0.030 * k, portp + nrm * 0.004 * k]
        hose("Umbilical", pts, 0.0105 * k, {"Back": 1}, RUBBER, pitch=0.012 * k)
        lathe_piece("UmbilicalPort", "SuitMetal", portp - nrm * 0.004 * k, nrm,
                    [(0.010 * k, 0.0, METAL), (0.018 * k, 0.0, METAL), (0.018 * k, 0.006 * k, METAL),
                     (0.014 * k, 0.010 * k, METAL), (0.010 * k, 0.010 * k, METAL)], {"Back": 1}, lod(14, 10, 8))
        connector("UmbilicalFitting", a + up_d * 0.004 * k, -up_d, 0.011 * k, 0.016 * k, {"Back": 1})

    # the name tape on the right breast, sewn on above the DCM
    pw_, ph_ = 0.115 * k, 0.028 * k
    py = hut_y0 + 0.225 * k

    def placard(su, tv):
        x = x0 - 0.035 * k - pw_ + pw_ * su
        y = py + ph_ / 2 - ph_ * tv
        p, _ = surf_point(tree, (x, y, zh + 0.5), (0, 0, -1), (x, y, zh + 0.15 * k))
        return p + Z * 0.0018
    decal_piece("Placard", "placard", placard, Z, "Back", nu=4, nv=1)

    # the purge hose's stub from the SCU connector, looping down to a clip low
    # on the HUT's front, right of centre (on Back: the waist never drags it;
    # in front: clear of the arm, which hangs and swings at the side)
    sc0 = dc - X * (DW / 2 + 0.034 * k) + up_d * 0.004 * k
    hp1, nrm = surf_point(tree, (x0 - 0.158 * k, hut_y0 + 0.018 * k, zh + 0.5), (0, 0, -1),
                          (x0 - 0.158 * k, hut_y0 + 0.018 * k, zh + 0.15 * k))
    hose("SCUhose", [sc0, sc0 - X * 0.024 * k - Y * 0.022 * k + Z * 0.006 * k,
                     hp1 + nrm * 0.040 * k + Y * 0.012 * k - X * 0.006 * k, hp1 + nrm * 0.012 * k],
         0.0115 * k, {"Back": 1}, RUBBER, pitch=0.013 * k)
    connector("SCUclip", hp1, nrm, 0.012 * k, 0.014 * k, {"Back": 1})

    # ── the WAIST and the BRIEF are the top of the lower body's one surface
    # (lower_body, after the arms) ─────────────────────────────────────────
    waist_y = hip[1] - 0.078 * k
    crotch = J("Thigh.Left")[1] - 0.090 * k

    # ── PLSS: the pack, rigid on Back, high on the back ────────────────────
    # A moulded composite case (its corners generously radiused, as a
    # moulding is) on the HUT's flat back; the top housing rolls over toward
    # the helmet; the SOP is the narrower step under it. On the back face:
    # the access panel on its screws with the serial plate, two stiffening
    # ribs, the vent grille over the SOP, the grab handles (orange) on their
    # blocks, the antenna and the beacon on top, bumpers at the bottom
    # corners; on the SOP its actuator, its gauge and the fill port.
    hit, _ = surf_point(tree, (x0, hut_y0 + 0.22 * k, zh - 0.5), (0, 0, 1), (x0, 0, zh - 0.14 * k))
    back_z = hit[2]
    Wp, Hp, Dp = 0.500 * k, 0.560 * k, 0.175 * k
    top = neck_top + 0.020 * k
    zf = back_z - 0.010 * k                       # the pack's front face, on the HUT
    yb = top - Hp - 0.11 * k
    SEC = [  # y over the bottom, half-width, depth, sq
        (0.000, 0.200, 0.140, 3.6), (0.006, 0.214, 0.168, 3.8), (0.020, 0.222, 0.180, 4.0), (0.090, 0.226, 0.186, 4.0),
        (0.104, 0.229, 0.180, 4.2), (0.112, 0.238, 0.170, 4.5), (0.130, 0.250, 0.176, 5.0), (0.380, 0.252, 0.178, 5.0),
        (0.520, 0.250, 0.196, 4.5), (0.600, 0.244, 0.205, 3.6), (0.640, 0.228, 0.190, 3.0),
        (0.662, 0.196, 0.150, 2.6), (0.670, 0.150, 0.100, 2.4)]
    prings = []
    for y, hw, dp, sq in SEC:
        prings.append(dict(c=(x0, yb + y * k, zf - dp / 2 * k), e1=X, e2=Z, r1=hw * k, r2=dp / 2 * k, sq=sq,
                           w={"Back": 1}, col=SHELL if y > 0.105 else (0.80, 0.795, 0.77)))
    V, F, UVc, W, C = loft(prings, lod(40, 28, 20), cap0=True, cap1=True, tile=0.5)
    pl = Piece("PLSS", "SuitShell", V, F, W, C, UVc=UVc, dirt="pack", sharp=50)
    Dp = 0.178 * k
    pz = zf - Dp / 2
    pc = np.array([x0, yb + 0.11 * k + Hp / 2, pz])
    ptree = bvh(pl)

    def back_at(x, y):
        """The pack's back surface at (x, y), and its normal."""
        p, nn = surf_point(ptree, (x, y, pz - 0.6), (0, 0, 1), (x, y, pz - Dp / 2))
        return p, unit(nn)
    pb = pz - Dp / 2
    Mb = np.column_stack([-X, Y, -Z])               # a frame facing out of the back
    # the access panel on its screws
    apc, _ = back_at(x0, pc[1] + 0.035 * k)
    rbox("PLSSpanel", "SuitShell", apc - Z * 0.003 * k, (0.330 * k, 0.300 * k, 0.012 * k), Mb, col=(0.83, 0.83, 0.81),
         r=0.005 * k, seg=2)
    for i in range(10):
        bx_ = (-0.150, -0.050, 0.050, 0.150, 0.150, 0.150, 0.050, -0.050, -0.150, -0.150)[i]
        by_ = (0.135, 0.135, 0.135, 0.135, 0.0, -0.135, -0.135, -0.135, -0.135, 0.0)[i]
        bolt("PLSSbolt", apc + np.array([bx_ * k, by_ * k, -0.0092 * k]), -Z, 0.0034 * k, 0.003 * k, {"Back": 1})
    decal_piece("PLSSplate", "plss",
                lambda su, tv: np.array([x0 + 0.11 * k - 0.22 * k * su, apc[1] + 0.065 * k - 0.11 * k * tv,
                                         apc[2] - 0.0098 * k]), -Z, "Back")
    # stiffening ribs down the sides of the back face
    for sx in (-1, 1):
        rp, _ = back_at(x0 + sx * 0.200 * k, pc[1] + 0.02 * k)
        rbox("PLSSrib", "SuitShell", rp - Z * 0.002 * k, (0.016 * k, 0.400 * k, 0.012 * k), Mb, col=SHELL, r=0.004 * k)
    # the vent grille over the SOP
    gp, _ = back_at(x0, yb + 0.150 * k)
    rbox("PLSSgrilleFrame", "SuitShell", gp - Z * 0.001 * k, (0.250 * k, 0.062 * k, 0.010 * k), Mb, col=SHELL_D,
         r=0.003 * k)
    if LOD < 2:
        for i in range(5):
            rbox("PLSSslat", "SuitShell", gp + np.array([0, (-0.022 + i * 0.011) * k, -0.006 * k]),
                 (0.232 * k, 0.004 * k, 0.006 * k), Mb, col=SHELL_G, r=0.0012 * k, seg=1)
    # grab handles on their blocks (orange: the second accent)
    for sx in (-1, 1):
        hx = x0 + sx * (Wp / 2 + 0.028 * k)
        yt, ybm = pc[1] + 0.10 * k, pc[1] - 0.06 * k
        pts = [np.array([x0 + sx * (Wp / 2 - 0.004 * k), yt, pz - 0.02 * k]),
               np.array([hx, yt - 0.01 * k, pz - 0.02 * k]), np.array([hx, ybm + 0.01 * k, pz - 0.02 * k]),
               np.array([x0 + sx * (Wp / 2 - 0.004 * k), ybm, pz - 0.02 * k])]
        hr = [dict(c=q, r=0.0085 * k, w={"Back": 1}, col=ORANGE) for q in bezier_path(pts, 14)]
        V, F, UVc, W, C = loft(limb(hr, Z), lod(10, 8, 6), cap0=True, cap1=True, tile=0.1)
        Piece("PLSShandle", "SuitShell", V, F, W, C, UVc=UVc, dirt="hard")
        for yy_ in (yt, ybm):
            rbox("PLSShandleBlock", "SuitShell", np.array([x0 + sx * (Wp / 2 + 0.002 * k), yy_, pz - 0.02 * k]),
                 (0.022 * k, 0.026 * k, 0.030 * k), None, col=SHELL_G, r=0.004 * k)
    # the antenna, the beacon
    at = pc + np.array([0.17 * k, Hp / 2 - 0.02 * k, -0.03 * k])
    hit, _ = surf_point(ptree, at + Y * 0.3, (0, -1, 0), at)
    connector("AntennaBase", hit - Y * 0.004 * k, Y, 0.009 * k, 0.014 * k, {"Back": 1}, col=SHELL_G)
    V, F = cyl_mesh(hit + Y * 0.010 * k, hit + Y * 0.075 * k, 0.0055 * k, segs=lod(10, 8, 6), r1=0.0035 * k)
    Piece("Antenna", "SuitRubber", V, F, {"Back": 1}, RUBBER, tile=0.2, dirt="hard")
    bt = pc + np.array([-0.15 * k, Hp / 2 - 0.02 * k, -0.04 * k])
    hit, _ = surf_point(ptree, bt + Y * 0.3, (0, -1, 0), bt)
    knob("Beacon", hit - Y * 0.003 * k, Y, 0.016 * k, 0.018 * k, {"Back": 1}, (0.85, 0.42, 0.14), flutes=False)
    # bumpers at the bottom corners
    for sx in (-1, 1):
        rbox("PLSSbumper", "SuitRubber", np.array([x0 + sx * 0.205 * k, yb + 0.012 * k, zf - 0.155 * k]),
             (0.040 * k, 0.030 * k, 0.050 * k), None, col=RUBBER, r=0.008 * k, seg=2, dirt="hard", tile=0.25)
    # the SOP: actuator, gauge, fill port
    sop_y = yb + 0.055 * k
    sp, sn = surf_point(ptree, (x0 + 0.12 * k, sop_y, pz - 0.6), (0, 0, 1), (x0, sop_y, zf - 0.186 * k))
    knob("SOPactuator", sp - Z * 0.001, unit(sn), 0.024 * k, 0.026 * k, {"Back": 1}, METAL_D, mat="SuitMetal")
    gp2, gn = surf_point(ptree, (x0 - 0.12 * k, sop_y, pz - 0.6), (0, 0, 1), (x0, sop_y, zf - 0.186 * k))
    gprof = [(1e-4, 0.0, SHELL_D), (0.024 * k, 0.0, SHELL_D), (0.024 * k, 0.012 * k, SHELL_D),
             (0.021 * k, 0.014 * k, SHELL_D), (0.021 * k, 0.014 * k, (0.80, 0.80, 0.76)), (1e-4, 0.0135 * k, (0.80, 0.80, 0.76))]
    lathe_piece("SOPgauge", "SuitShell", gp2, unit(gn), gprof, {"Back": 1}, lod(24, 16, 10), dirt="hard")
    fp_, fn = surf_point(ptree, (x0, sop_y - 0.01 * k, pz - 0.6), (0, 0, 1), (x0, sop_y, zf - 0.186 * k))
    connector("SOPfill", fp_, unit(fn), 0.008 * k, 0.018 * k, {"Back": 1})

    # ── ARMS ──────────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        arm(rig, D, Ja, J, side, s, k, scye[side])

    # ── the LOWER BODY (waist, brief, legs) and the BOOTS ─────────────────
    lower_body(rig, D, J, Ja, k, x0, zc, hut_y0, waist_y, crotch)
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        boot(rig, D, J, side, s, k)

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
    "full": (0.0, 0.0, 1.0, 1.0),       # a material of its own (the emblem patch)
}


def decal_piece(name, region, pos, normal, bone, nu=1, nv=1, part="suit", mat="SuitDecal"):
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
    return Piece(name, mat, V, F, bone if isinstance(bone, dict) else {bone: 1}, (1, 1, 1), UVc=UVc,
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
# the soft suit: one skinned surface per limb chain
# ═════════════════════════════════════════════════════════════════════════════
#
# The cloth is not pieces. Each ARM — the gathered cloth in the scye bearing,
# the sleeve, the elbow, the forearm, the gauntlet, the palm, four fingers and
# the thumb — is ONE closed quad cage, smoothed by a level of Catmull-Clark
# subdivision, so the fingers grow out of the palm and the palm out of the
# cuff with no seam anywhere. The LOWER TORSO and both LEGS are one surface
# too: the waist convolute, the brief, and the legs split out of the brief at
# a crotch line both legs share, down into the boots.
#
# WEIGHTS ARE PAINTED, NOT ASSIGNED PER PIECE: after subdivision every vertex
# is weighted by a falloff of its own position about the joint it is near
# (arm_weights, low_weights), so a joint blends smoothly over several edge
# loops. Each joint's blend is ASYMMETRIC, the way a weight painter does it
# for linear blend skinning (which the engine uses): narrow on the crease
# side, so the crease tucks in rather than collapsing, broad on the outer
# side, so the outside of an elbow or knee rounds over instead of pinching.
# And the limbs are MODELLED PART-BENT (the elbows 35°, the knees 25°, in the
# authoring pose; see build()): linear blending shrinks a blended ring by
# cos(θ/2) for a bend θ away from the pose it was modelled in, so modelling
# mid-range halves the worst bend (140° at the elbow becomes 105° away: the
# blended ring keeps 61% of its section instead of 34%).
#
# THE SHOULDER is the exception, deliberately: the scye bearing is rigid on
# the hard upper torso, as on the real suit, and the sleeve's root inside it is
# a dome centred exactly on the shoulder pivot, weighted wholly to the upper
# arm, which turns about its own centre and so always fills the bearing's
# bore. A Back→Upperarm blend there would be shrunk by cos(θ/2) — to 9% of
# its section at 170° of abduction — and tear the sleeve off the bearing; no
# weighting fixes that without a helper joint driven at half the arm's turn,
# which nothing in the engine drives (see the hand-back's engine notes).
#
# HANDS. The rig has one finger chain per hand (Fingers1 at the knuckles,
# Fingers2 at the middle joints) and a two-bone thumb; all four fingers are
# skinned to that chain — the knuckle line arcs (the little finger's knuckle
# set back), each finger's joints sit as near the chain's pivots as a hand's
# proportions allow — and the thumb to Thumb1/Thumb2. The glove is modelled
# relaxed: the fingers a little curled, the thumb opposed under the index
# finger, as a pressurised glove rests. No clip moves the thumb bones.

class Cage:
    """A quad (or n-gon) mesh under construction: positions, per-vertex
    vertex groups (bones or helper scalars), colours, faces with per-corner
    UVs (None: a box projection is made for the face)."""

    def __init__(self, tile=0.25):
        self.P, self.G, self.C, self.F, self.UV = [], [], [], [], []
        self.tile = tile

    def add(self, p, g=None, c=CLOTH):
        self.P.append(np.asarray(p, float))
        self.G.append(dict(g or {}))
        self.C.append(tuple(c))
        return len(self.P) - 1

    def ring(self, pts, g=None, c=CLOTH):
        out = []
        for i, p in enumerate(pts):
            gi = g(i) if callable(g) else g
            ci = c(i) if callable(c) else c
            out.append(self.add(p, gi, ci))
        return out

    def face(self, idx, uv=None):
        self.F.append(tuple(int(i) for i in idx))
        self.UV.append(uv)

    def band(self, ra, rb, ut, va, vb):
        """Quads between two rings of the same count, u round (ut tiles), v
        along. Winding is fixed afterwards (recalc)."""
        n = len(ra)
        for i in range(n):
            j = (i + 1) % n
            u0, u1 = i / n * ut, (i + 1) / n * ut
            self.face((ra[i], ra[j], rb[j], rb[i]), [(u0, va), (u1, va), (u1, vb), (u0, vb)])

    def piece(self, name, mat, dirt, part="suit", subsurf=0, mats=None, face_mat=None, disp=None):
        """The cage as a Piece, subdivided `subsurf` levels. With `mats`, each
        face's material index is face_mat(its vertices' colours); with
        `disp`, the folds are laid on after the subdivision."""
        UVc = []
        for f, uv in zip(self.F, self.UV):
            if uv is None:
                # a box projection of this face, in tiles
                P = np.array([self.P[i] for i in f])
                n = np.cross(P[1] - P[0], P[2] - P[0])
                ax = int(np.argmax(np.abs(n)))
                q = [a for a in range(3) if a != ax]
                uv = [(p[q[0]] / self.tile, p[q[1]] / self.tile) for p in P]
            UVc.append(uv)
        fmat = None
        if mats:
            fmat = [face_mat([self.C[i] for i in f]) for f in self.F]
        pc = Piece(name, mat, np.array(self.P), self.F, self.G, np.array(self.C, float), UVc=UVc, part=part,
                   dirt=dirt, mods=[("recalc",)] + ([("subsurf", subsurf)] if subsurf else []), mats=mats, fmat=fmat)
        if disp is not None:
            pc.displace(disp)
        return pc


def frame_ring(c, ex, ey, t, rx, ry, angs, bump=None):
    """Ring points about centre c in the plane normal to t, with ex/ey (made
    perpendicular to t) as the x and y of the section, radii rx/ry, at the
    given angles (radians); bump(a) adds to the radius."""
    t = unit(t)
    ex = unit(np.asarray(ex, float) - t * (t @ ex))
    ey = np.asarray(ey, float) - t * (t @ ey) - ex * (ex @ ey)
    ey = unit(ey)
    out = []
    for a in angs:
        r = 1.0 + (bump(a) if bump else 0.0)
        out.append(np.asarray(c, float) + ex * (rx * r * math.cos(a)) + ey * (ry * r * math.sin(a)))
    return out


def follow_ring(prev, c0, c, t, rx, ry, ex):
    """A ring of len(prev) points about c (normal t) whose points keep the
    previous ring's angular order: each previous point's direction from c0,
    flattened onto the new plane, scaled to an ellipse rx (along ex) by ry."""
    t = unit(t)
    ex = unit(np.asarray(ex, float) - t * (t @ ex))
    ey = np.cross(t, ex)
    out = []
    for p in prev:
        d = np.asarray(p, float) - c0
        x, y = d @ ex, d @ ey
        a = math.atan2(y, x)
        out.append(np.asarray(c, float) + ex * (rx * math.cos(a)) + ey * (ry * math.sin(a)))
    return out


def stitch(cg, A, B, tA, tB, ut, va, vb):
    """Close the band between rings A and B of different counts with
    triangles, marching both by their angular parameter t (0..1, increasing
    round the ring, A[0] at tA[0]); u = t·ut."""
    nA, nB = len(A), len(B)
    t0 = tA[0]
    ta = [(x - t0) % 1.0 for x in tA]
    tb = [(x - t0) % 1.0 for x in tB]
    j0 = min(range(nB), key=lambda j: min(tb[j], 1 - tb[j]))
    B = B[j0:] + B[:j0]
    tb = tb[j0:] + tb[:j0]
    if tb[0] > 0.5:
        tb[0] -= 1.0
    tb = [tb[0]] + [x if x >= tb[0] else x + 1.0 for x in tb[1:]]
    i = j = 0

    def ua(q):
        return (ta[q % nA] + (1.0 if q >= nA else 0.0)) * ut

    def ub(q):
        return (tb[q % nB] + (1.0 if q >= nB else 0.0)) * ut
    while i < nA or j < nB:
        na = ta[i + 1] if i + 1 < nA else 1.0 + ta[0]
        nb = tb[j + 1] if j + 1 < nB else 1.0 + tb[0]
        if j >= nB or (i < nA and na <= nb):
            cg.face((A[i % nA], A[(i + 1) % nA], B[j % nB]), [(ua(i), va), (ua(i + 1), va), (ub(j), vb)])
            i += 1
        else:
            cg.face((A[i % nA], B[(j + 1) % nB], B[j % nB]), [(ua(i), va), (ub(j + 1), vb), (ub(j), vb)])
            j += 1


ENC = 0.06      # helper groups carry offsets in metres as 0.5 + x / ENC


def enc(x):
    return float(np.clip(0.5 + x / ENC, 0.0, 1.0))


def dec(g, name):
    return (g.get(name, 0.5) - 0.5) * ENC


def wsum(*parts):
    out = {}
    for f, d in parts:
        if f <= 0:
            continue
        for b, w in d.items():
            out[b] = out.get(b, 0.0) + f * w
    return out


# ═════════════════════════════════════════════════════════════════════════════
# arms
# ═════════════════════════════════════════════════════════════════════════════

# Cage radii are a little over the finished ones: a level of Catmull-Clark
# pulls a ring of eight in by about 5 %.
CAGE = 1.05


def arm(rig, D, Ja, J, side, s, k, sc):
    ua, fa, hd = "Upperarm." + side, "Forearm." + side, "Hand." + side
    f1n, f2n = "Fingers1." + side, "Fingers2." + side
    t1n, t2n = "Thumb1." + side, "Thumb2." + side
    P, n, d = sc                       # pivot, scye normal, ring plane distance
    S, E, H = Ja(ua), Ja(fa), Ja(hd)
    F1, F2 = Ja(f1n), Ja(f2n)
    axu, axf = unit(E - S), unit(H - E)
    L1 = float(np.linalg.norm(E - S))
    L2 = float(np.linalg.norm(H - E))
    out = unit(s * np.cross(Z, axu))   # away from the body, in the frontal plane

    # the hand's frame: along it, the back of the hand, toward the thumb
    hax = unit(F2 - H)
    hup = D[rig.index[hd]][:3, :3] @ Y
    hup = unit(hup - hax * (hup @ hax))
    hfw = np.cross(hax, hup)
    if hfw @ Ja(t1n) < hfw @ H:
        hfw = -hfw
    hk = float(np.linalg.norm(F1 - H)) / 0.1120          # the hand's own scale
    nb_e = unit(axu + axf)                               # the elbow's bisector
    crease_e = unit(axf - axu * (axf @ axu))             # the side the forearm folds to

    cg = Cage(tile=0.2)
    ANG8 = [(j + 1) * TAU / 8 for j in range(8)]        # T0 T2 T4 SL B4 B2 B0 SI

    def ring8(c, t, rx, ry, col=CLOTH, bump=None):
        return cg.ring(frame_ring(c, hfw, hup, t, rx * CAGE, ry * CAGE, ANG8, bump), {"_ko": 0.5, "_po": 0.5}, col)

    rings, vs = [], []                                    # the tube's rings and their v (arc length / tile)

    def push(r, c):
        if rings:
            vs.append(vs[-1] + float(np.linalg.norm(c - push.last)) / 0.25)
        else:
            vs.append(0.0)
        push.last = np.asarray(c, float)
        rings.append(r)

    # ── the shoulder: the dome in the scye bearing ──────────────────────────
    ring_out = d + 0.019 * k
    Rb = (math.sqrt((SCYE_BORE * k) ** 2 + ring_out ** 2) + 0.003 * k) / 0.985
    ex_s = hfw
    # a shoulder convolute: concentric pleats round the arm's axis, so the
    # dome the bearing shows when the arm is high reads as gathered cloth
    for i, th in enumerate((165, 124, 106, 90, 74, 58, 46)):
        a = math.radians(th)
        pl = 1.0 if i % 2 == 0 else 0.90                  # ridge, fold
        R_ = Rb * (pl if th < 160 else 1.0)
        c = S + axu * R_ * math.cos(a)
        rho = R_ * math.sin(a)
        r = ring8(c, axu, rho, rho, CLOTH if pl == 1.0 else CLOTH_SH,
                  bump=lambda a_, i=i: 0.02 * math.sin(4 * a_ + i * 0.9))
        push(r, c)
    cg.face(rings[0])                                     # the dome's far pole, inside the HUT

    # ── the upper arm: the sleeve out of the dome, the upper-arm bearing ───
    s_ub = 0.165 * k
    for t, r, col in ((0.104, 0.075, CLOTH), (0.138, 0.077, CLOTH), (s_ub, 0.077, CLOTH), (0.198, 0.075, CLOTH),
                      (0.240, 0.072, CLOTH)):
        c = S + axu * t * k
        push(ring8(c, axu, r * k, r * k * 0.97, col), c)
    # ── the elbow: pleats across the pivot, along the bent path ─────────────
    for dd, r, col in ((-0.046, 0.069, CLOTH), (-0.024, 0.063, CLOTH_SH), (0.0, 0.067, CLOTH),
                       (0.024, 0.062, CLOTH_SH), (0.046, 0.064, CLOTH)):
        if dd < 0:
            c, t = E + axu * dd * k, axu if dd < -0.03 else unit(axu + nb_e)
        elif dd > 0:
            c, t = E + axf * dd * k, axf if dd > 0.03 else unit(axf + nb_e)
        else:
            c, t = E, nb_e
        push(ring8(c, t, r * k, r * k * 0.96, col,
                   bump=lambda a_, dd=dd: 0.03 * max(0.0, -math.cos(a_ - 0.0)) * (1 if dd == 0 else 0)), c)
    # ── the forearm to the wrist disconnect, then the glove's gauntlet ──────
    wr = L2 - 0.062 * k                                 # the wrist disconnect, from the elbow
    for dd, r, col in ((0.095 * k, 0.062, CLOTH), (wr - 0.042 * k, 0.057, CLOTH), (wr - 0.014 * k, 0.053, CLOTH),
                       (wr, 0.050, CLOTH), (wr + 0.012 * k, 0.063, GLOVE), (wr + 0.036 * k, 0.066, GLOVE),
                       (wr + 0.041 * k, 0.059, GLOVE_D), (L2 - 0.010 * k, 0.051, GLOVE),
                       (L2 + 0.004 * k, 0.047, GLOVE)):
        c = E + axf * dd
        push(ring8(c, axf, r * k, r * k * (0.92 if col == GLOVE else 1.0), col), c)
    circ = TAU * 0.07 * k
    ut = max(1, round(circ / 0.25))
    for a_, b_, va, vb in zip(rings[:-1], rings[1:], vs[:-1], vs[1:]):
        cg.band(a_, b_, ut, va, vb)

    # ── the glove's hand ────────────────────────────────────────────────────
    # Finger table: lateral centre (toward the thumb +), knuckle set back,
    # middle joint from the knuckle, length, spread. Metres on the male hand.
    FING = [(+0.0315, -0.003, 0.047, 0.088, +0.07), (+0.0105, 0.000, 0.0497, 0.096, +0.01),
            (-0.0105, -0.003, 0.047, 0.090, -0.05), (-0.0315, -0.010, 0.040, 0.072, -0.13)]
    kn = float((F1 - H) @ hax)                           # wrist → knuckle line
    pip = float((F2 - F1) @ hax)                         # knuckle → middle-joint line
    w_, t_ = 0.044 * hk, 0.0195 * hk                     # the palm's half width, half thickness
    lat = [0.042, 0.021, 0.0, -0.021, -0.042]            # T0..T4 / B0..B4 across
    ko_edge = [FING[0][1], (FING[0][1] + FING[1][1]) / 2, (FING[1][1] + FING[2][1]) / 2,
               (FING[2][1] + FING[3][1]) / 2, FING[3][1]]

    def palm_ring(sv, wd, th, ko=None, arch=0.25, side_dn=0.35):
        """12 points: T0..T4 (back of the hand, thumb side first), SL, B4..B0
        (the palm), SI; sv along the hand from the wrist."""
        pts, kos = [], []
        for i in range(5):
            x = lat[i] / 0.042 * wd
            o = ko[i] if ko else 0.0
            pts.append(H + hax * (sv + o * hk) + hfw * x + hup * th * (1 + arch * (1 - (x / wd) ** 2)))
            kos.append(o)
        pts.append(H + hax * sv + hfw * (-wd - 0.006 * hk) + hup * (-th * 0.15))
        kos.append(ko[4] if ko else 0.0)
        for i in (4, 3, 2, 1, 0):
            x = lat[i] / 0.042 * wd
            o = ko[i] if ko else 0.0
            pts.append(H + hax * (sv + o * hk) + hfw * x - hup * th * (1 - 0.15 * (1 - (x / wd) ** 2)))
            kos.append(o)
        pts.append(H + hax * sv + hfw * (wd + 0.009 * hk) - hup * th * side_dn)
        kos.append(ko[0] if ko else 0.0)
        return pts, kos

    def pal_col(i, dark):
        return PALM if (dark and 6 <= i <= 10) else GLOVE

    Wr = rings[-1]                                       # the wrist, 8: T0 T2 T4 SL B4 B2 B0 SI
    p1, _ = palm_ring(0.030 * hk, w_ * 0.95, t_ * 1.05)
    P1 = cg.ring(p1, {"_ko": 0.5, "_po": 0.5}, lambda i: pal_col(i, True))
    p2, _ = palm_ring(0.064 * hk, w_ * 1.02, t_ * 1.08)
    P2 = cg.ring(p2, {"_ko": 0.5, "_po": 0.5}, lambda i: pal_col(i, True))
    pk, kos = palm_ring(kn - 0.006 * hk, w_, t_ * 0.95, ko=ko_edge, arch=0.32)
    # the knuckles: a ridge across the back of the hand
    pk = [p + hup * (0.0035 * hk if i < 5 else 0.0) for i, p in enumerate(pk)]
    K = [cg.add(p, {"_ko": enc(o * hk), "_po": 0.5}, pal_col(i, True)) for i, (p, o) in enumerate(zip(pk, kos))]
    # wrist (8) → P1 (12): pentagons over the back and the palm, quads at the sides
    m8 = [0, 2, 4, 5, 6, 8, 10, 11]
    for j in range(8):
        a, b = m8[j], m8[(j + 1) % 8]
        span = list(range(a, b + 1)) if b > a else [a, 0] if b == 0 else list(range(a, 12)) + list(range(0, b + 1))
        cg.face([Wr[j], Wr[(j + 1) % 8]] + [P1[q] for q in reversed(span)])
    # P1 → P2, leaving the thumb's two faces (B0–SI–T0 side) open
    for i in range(12):
        j = (i + 1) % 12
        if i in (10, 11):
            continue
        cg.face((P1[i], P1[j], P2[j], P2[i]))
    for i in range(12):
        j = (i + 1) % 12
        cg.face((P2[i], P2[j], K[j], K[i]))
    # the knuckle end's sides
    cg.face((K[4], K[5], K[6]))
    cg.face((K[10], K[11], K[0]))

    # ── four fingers out of the knuckle end ────────────────────────────────
    def bend(v, ax, deg):
        a = math.radians(deg)
        ax = unit(ax)
        return v * math.cos(a) + np.cross(ax, v) * math.sin(a) + ax * (ax @ v) * (1 - math.cos(a))

    for fi, (lx, ko, pj, ln, spread) in enumerate(FING):
        q0 = [K[fi], K[fi + 1], K[10 - (fi + 1)], K[10 - fi]]     # T_i, T_i+1, B_i+1, B_i
        root = np.mean([cg.P[q] for q in q0], axis=0)
        lat_ax = hfw                                    # the finger's own sideways
        dr = unit(hax + hfw * spread)
        po = (ko + pj) - pip / hk                       # where its middle joint is, off the chain's
        # the relaxed curl: the knuckle 8°, the middle joint 14°, the end joint 16°
        cur = root.copy()
        d0 = bend(dr, unit(np.cross(hup, dr)), 10)
        # rings: (distance from the knuckle, half width, half height, top bump, curl after)
        L = ln * hk
        J1, J2 = pj * hk, (pj + 0.55 * (ln - pj)) * hk
        steps = [(0.009 * hk, 0.0142, 0.0138, 0.0020), (0.026 * hk, 0.0132, 0.0124, 0.0),
                 (J1, 0.0138, 0.0130, 0.0018), (J1 + 0.4 * (J2 - J1), 0.0126, 0.0118, 0.0),
                 (J2, 0.0126, 0.0120, 0.0012), (L - 0.011 * hk, 0.0120, 0.0112, 0.0),
                 (L - 0.0035 * hk, 0.0072, 0.0066, 0.0)]
        prev, prev_c = [cg.P[q] for q in q0], root
        prev_i = q0
        sdist, dcur = 0.0, d0
        g = {"_ko": enc(ko * hk), "_po": enc(po * hk)}
        for si, (sd, hw_, hh_, bump) in enumerate(steps):
            if sd > J1 and sdist <= J1:
                dcur = bend(dcur, unit(np.cross(hup, dcur)), 20)
            if sd > J2 and sdist <= J2:
                dcur = bend(dcur, unit(np.cross(hup, dcur)), 20)
            cur = cur + dcur * (sd - sdist)
            sdist = sd
            fup = unit(np.cross(dcur, lat_ax) * -1)
            fup = fup if fup @ hup > 0 else -fup
            pts = []
            for qi, (sx, sy) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
                pts.append(cur + lat_ax * sx * hw_ * hk * 1.06 + fup * (sy * hh_ * hk * 1.06 + (bump * hk if sy > 0 else 0)))
            # the RTV grip: the finger's palm side from the knuckle out, and a
            # cap over the whole fingertip (the Phase VI glove's)
            cap = si >= len(steps) - 3
            ids = cg.ring(pts, g, lambda q, cap=cap, si=si: PALM if (cap or (si >= 1 and q >= 2)) else GLOVE)
            for q in range(4):
                cg.face((prev_i[q], prev_i[(q + 1) % 4], ids[(q + 1) % 4], ids[q]))
            prev_i = ids
        cg.face(prev_i)                                  # the fingertip

    # ── the thumb: out of the palm's thumb side, opposed under the index ───
    q0 = [P1[10], P1[11], P1[0], P2[0], P2[11], P2[10]]
    base = np.mean([cg.P[q] for q in q0], axis=0)
    d1 = unit(hax * 0.58 + hfw * 0.74 - hup * 0.22)
    Tc1 = base - d1 * 0.012 * hk                          # the thumb's root, in the palm
    Tc2 = Tc1 + d1 * 0.050 * hk                           # its knuckle
    d2 = unit(hax * 0.92 + hfw * 0.02 - hup * 0.28)
    def curl(v, deg):
        return bend(v, unit(np.cross(hup, v)), deg)
    tex = unit(np.cross(d1, hup))
    d3 = curl(d2, 18)
    th_rings = [(base + d1 * 0.008 * hk, d1, 0.0215, 0.0175), (Tc1 + d1 * 0.030 * hk, d1, 0.0178, 0.0152),
                (Tc2, unit(d1 + d2), 0.0156, 0.0142), (Tc2 + d2 * 0.016 * hk, d2, 0.0138, 0.0128),
                (Tc2 + d2 * 0.031 * hk, d2, 0.0134, 0.0124), (Tc2 + d2 * 0.031 * hk + d3 * 0.016 * hk, d3, 0.0122, 0.0112),
                (Tc2 + d2 * 0.031 * hk + d3 * 0.0245 * hk, d3, 0.0068, 0.0062)]
    prev_pts, prev_c, prev_i = [cg.P[q] for q in q0], base, q0
    for ti, (c, t, rx, ry) in enumerate(th_rings):
        pts = follow_ring(prev_pts, prev_c, c, t, rx * hk * CAGE, ry * hk * CAGE, tex)
        dark = ti >= 2
        cap = ti >= len(th_rings) - 2

        def tcol(q, pts=pts, c=c, dark=dark):
            return PALM if (cap or (dark and (pts[q] - c) @ (-hup + hfw * 0.3) > 0.0)) else GLOVE
        ids = cg.ring(pts, {"_th": 1.0, "_ko": 0.5, "_po": 0.5}, tcol)
        for q in range(6):
            cg.face((prev_i[q], prev_i[(q + 1) % 6], ids[(q + 1) % 6], ids[q]))
        prev_pts, prev_c, prev_i = pts, c, ids
    cg.face(prev_i)

    # ── the cloth's folds, laid on the subdivided surface ──────────────────
    # A pressurised sleeve is not a smooth tube: it bunches in rings above
    # the wrist disconnect, folds across the crook of the elbow (sharp on the
    # inside, where it is compressed; barely on the outside, where it is
    # pulled), drapes in long shallow diagonals down the upper arm and the
    # forearm, and is never quite round. The glove (past the wrist) keeps
    # only a little of it; the fingers none.
    def arm_disp(Pv, Nv, G):
        rel_h = (Pv - H) @ axf
        sleeve = 1.0 - smooth01(-0.080 * k, -0.058 * k, rel_h)           # 1 up the sleeve, 0 at the disconnect
        glove = smooth01(-0.050 * k, -0.035 * k, rel_h) * (1 - smooth01(0.010 * k, 0.030 * k, rel_h))
        # around each segment: the angle from the back of the hand
        d = np.zeros(len(Pv))
        # (1) the cloth's own unevenness, everywhere on the sleeve
        d += 0.0022 * k * fbm(Pv, 11 + int(s > 0), 9.0 / k) * sleeve
        # (2) the elbow: compression folds on the crease side
        se = (Pv - E) @ nb_e
        rad = Pv - E - np.outer(se, nb_e)
        rn = np.maximum(np.linalg.norm(rad, axis=1), 1e-9)
        cr = (rad @ crease_e) / rn
        env = np.exp(-(se / (0.055 * k)) ** 2) * smooth01(-0.35, 0.75, cr)
        ph = 2 * math.pi * se / (0.021 * k) + 2.5 * fbm(Pv, 21, 14.0 / k)
        d += 0.0058 * k * env * np.sin(ph) * sleeve
        # (3) diagonal drape folds down the upper arm and the forearm
        for c0, ax, La, Lb, sd in ((S, axu, 0.10, L1 / k - 0.06, 31), (E, axf, 0.05, L2 / k - 0.09, 41)):
            t = (Pv - c0) @ ax
            r_ = Pv - c0 - np.outer(t, ax)
            ang = np.arctan2(r_ @ np.cross(ax, hup), r_ @ hup)
            band = smooth01(La * k, La * k + 0.03 * k, t) * (1 - smooth01(Lb * k - 0.03 * k, Lb * k, t))
            wob = fbm(Pv, sd, 8.0 / k)
            dr = np.sin(2 * math.pi * t / (0.085 * k) + 1.6 * ang + 3.0 * wob)
            d += 0.0030 * k * band * np.sign(dr) * np.abs(dr) ** 1.6 * (0.5 + wob) * sleeve
        # (4) the cloth bunched in rings above the wrist disconnect
        bun = smooth01(-0.180 * k, -0.120 * k, rel_h) * (1 - smooth01(-0.082 * k, -0.066 * k, rel_h))
        ph = 2 * math.pi * rel_h / (0.019 * k) + 2.2 * fbm(Pv, 51, 18.0 / k)
        d += 0.0040 * k * bun * np.sin(ph)
        # (5) the gauntlet: a few soft creases round the wrist
        d += 0.0012 * k * glove * np.sin(2 * math.pi * rel_h / (0.012 * k) + 3 * fbm(Pv, 61, 25.0 / k))
        return Nv * d[:, None]

    pc = cg.piece("Arm." + side, "SuitFabric", "arm", subsurf=lod(2, 1, 0), mats=["SuitFabric", "SuitRubber"],
                  face_mat=lambda cs: 1 if all(tuple(c) == PALM for c in cs) else 0,
                  disp=arm_disp if LOD < 2 else None)
    pc.mat_col = {1: RUBBER}
    pc.dirt2 = "glove"
    if LOD == 0:
        pc.thin(lambda Pv: smooth01(-0.010 * k, 0.004 * k, (Pv - H) @ axf), 0.45)

    # ── the knuckle bar: a padded strip across the back of the knuckles
    # (an EVA glove's metacarpal bar), rigid on the hand, laid on the glove's
    # finished surface ────────────────────────────────────────────────────
    if LOD < 2:
        gt = bvh(pc)
        kb_r = []
        for lx in np.linspace(-0.036, 0.036, 7):
            q = H + hax * (kn - 0.016 * hk) + hfw * lx * hk
            sp_, _ = surf_point(gt, q + hup * 0.08, -hup, q + hup * t_)
            kb_r.append(dict(c=sp_ + hup * 0.0022 * hk, r=0.0040 * hk, r2=0.0095 * hk, w={hd: 1}, col=(0.34, 0.34, 0.35)))
        V, F, UVc, W, C = loft(limb(kb_r, hup), lod(10, 8, 6), cap0=True, cap1=True, tile=0.1)
        Piece("KnuckleBar." + side, "SuitRubber", V, F, W, C, UVc=UVc, dirt="glove")

    # ── the weights, painted on the subdivided surface ──────────────────────
    hin_e, hout_e = 0.014 * k, 0.050 * k

    def arm_weights(Pv, G):
        out_w = []
        for p, g in zip(Pv, G):
            # the elbow
            se = float((p - E) @ nb_e)
            rad = p - E - nb_e * se
            cr = float(unit(rad) @ crease_e) if np.linalg.norm(rad) > 1e-9 else 0.0
            h = hout_e + (hin_e - hout_e) * (cr + 1) / 2
            wf = float(smooth01(-h, h, se))
            # the wrist
            sw = float((p - H) @ axf)
            wh = float(smooth01(-0.034 * k, 0.008 * k, sw))
            # the fingers, on the one chain
            ko, po, th = dec(g, "_ko"), dec(g, "_po"), g.get("_th", 0.0)
            up = float((p - F1) @ hup)
            s1 = float((p - F1) @ hax) - ko
            a1, b1 = ((0.013, 0.009) if up > 0 else (0.004, 0.006))
            w1 = float(smooth01(-a1 * hk, b1 * hk, s1))
            s2 = float((p - F2) @ hax) - po
            a2, b2 = ((0.008, 0.007) if up > 0 else (0.003, 0.004))
            w2 = float(smooth01(-a2 * hk, b2 * hk, s2)) * w1
            hand = {hd: 1 - w1, f1n: w1 - w2, f2n: w2}
            # the thumb: Thumb1 from the base of the thenar, Thumb2 past its knuckle
            wt1 = float(smooth01(-0.008 * hk, 0.014 * hk, float((p - Tc1) @ d1)))
            wt2 = float(smooth01(-0.005 * hk, 0.006 * hk, float((p - Tc2) @ unit(d1 + d2)))) * wt1
            thumb = {hd: 1 - wt1, t1n: wt1 - wt2, t2n: wt2}
            hc = wsum((1 - th, hand), (th, thumb))
            out_w.append(wsum((1 - wh, {ua: 1 - wf, fa: wf}), (wh, hc)))
        return out_w
    pc.W = arm_weights
    pc.wg = True

    # ── hardware on the arm: rigid, each where the cloth under it is ────────
    up_c = lambda t: S + axu * t                         # noqa: E731
    ring_piece("UpperArmBearing." + side, "SuitMetal", up_c(s_ub), axu, 0.072 * k, 0.088 * k, 0.020 * k, ua, METAL,
               segs=16, band=METAL_D)
    wc = E + axf * wr
    ring_piece("Wrist." + side, "SuitMetal", wc, axf, 0.046 * k, 0.061 * k, 0.022 * k, fa, METAL, segs=16,
               band=BLUE_A if s > 0 else RED_A)
    # the emblem on the left upper arm, the flag on the right
    r_p = 0.077 * k * 0.985 + 0.0050
    ph = 0.075 * k
    span = ph / r_p
    sc_ = s_ub + 0.085 * k
    across = unit(-Z - axu * (-Z @ axu))

    def patch(su, tv, sc_=sc_, across=across, span=span, ph=ph):
        a = (su - 0.5) * span * s
        return up_c(sc_ + (tv - 0.5) * ph) + (out * math.cos(a) + across * math.sin(a)) * r_p
    if s > 0:
        decal_piece("Emblem." + side, "full", patch, out, ua, nu=6, nv=2, mat="SuitEmblem")
    else:
        decal_piece("Emblem." + side, "flag", patch, out, ua, nu=6, nv=2)

    # the CUFF CHECKLIST on the left forearm, a wrist mirror on the right,
    # each on a strap
    top = unit(np.cross(axf, hfw))
    if top @ hup < 0:
        top = -top
    if s > 0:
        cc = E + axf * 0.128 * k + top * 0.064 * k
        Mb = np.column_stack([unit(np.cross(top, axf)), top, axf])
        V, F = box_mesh(cc, (0.085 * k, 0.020 * k, 0.095 * k), Mb)
        Piece("Cuff", "SuitShell", V, F, {fa: 1}, SHELL_G, tile=0.5, dirt="hard", mods=[("bevel", 0.003 * k, 1)],
              sharp=30)
        decal_piece("CuffPage", "cuff",
                    lambda su, tv: cc + top * 0.0105 * k + Mb[:, 0] * (-0.038 * k + 0.076 * k * su)
                    + axf * (0.042 * k - 0.084 * k * tv), top, fa)
    else:
        cc = E + axf * 0.125 * k + top * 0.066 * k
        Mb = np.column_stack([unit(np.cross(top, axf)), top, axf])
        V, F = box_mesh(cc, (0.06 * k, 0.012 * k, 0.07 * k), Mb)
        Piece("Mirror", "SuitMetal", V, F, {fa: 1}, METAL, tile=0.5, dirt="metal", mods=[("bevel", 0.002 * k, 1)],
              sharp=30)
    strap = [dict(c=E + axf * t * k, r=0.0625 * k, w={fa: 1}, col=SHELL_D) for t in (0.117, 0.137)]
    V, F, UVc, W, C = loft(limb(strap, Z), 16, tile=0.1)
    Piece("Strap." + side, "SuitFabric", V, F, W, C, UVc=UVc, dirt="arm")


# ═════════════════════════════════════════════════════════════════════════════
# the lower torso and the legs: one surface
# ═════════════════════════════════════════════════════════════════════════════

def lower_body(rig, D, J, Jp, k, x0, zc, hut_y0, waist_y, crotch):
    """The waist convolute (Back into Hip), the waist bearing, the brief, and
    both legs out of it to the boots — one mesh. The trunk's lowest ring (24)
    splits into the legs: each leg's first ring is half the trunk's ring and
    a crotch line of seven points both legs share."""
    cg = Cage(tile=0.25)
    TS = 24
    # one level of subdivision pulls the 16- and 24-point rings in by about
    # 3.5 %: the cage is drawn that much fuller (LOD 0 only; the coarser LODs
    # draw the cage itself)
    LC = lod(1.035, 1.0, 1.0)
    # EMU legs are bulky: the cloth stands off the leg by the comfort gap and
    # the restraint layer, more at the shin (the boot's tongue and the LCVG's
    # tubes under it) than at the thigh
    FAT_T, FAT_K, FAT_S = 1.05, 1.07, 1.09

    def trunk_ring(y, hd, hw, zoff=0.0, sq=2.5, rad=None):
        out = []
        for i in range(TS):
            a = TAU * i / TS                              # 0 front, π/2 left, π back
            ca, sa = math.cos(a), math.sin(a)
            x = math.copysign(abs(sa) ** (2.0 / sq), sa)
            z = math.copysign(abs(ca) ** (2.0 / sq), ca)
            r = 1.0 + (rad(a) if rad else 0.0)
            out.append(np.array([x0 + hw * x * r * LC, y, zc + zoff + hd * z * r * LC]))
        return out

    rings, vs, ys = [], [], []
    # the waist: convolutes from inside the body seal closure to the bearing
    yw = np.linspace(hut_y0 + 0.004 * k, waist_y + 0.012 * k, 7)
    for i, y in enumerate(yw):
        ridge = i % 2 == 1
        hw = (0.176 if ridge else 0.166) * k
        wob = (lambda a, i=i: 0.014 * math.sin(3 * a + i * 1.3) + 0.010 * math.sin(7 * a + i))
        rings.append(cg.ring(trunk_ring(y, hw * 0.74, hw, sq=2.4, rad=wob), None, CLOTH if ridge else CLOTH_SH))
        ys.append(y)
    # the waist bearing's band, then the brief, which hangs
    for y, hw, hd, dz in ((waist_y - 0.002 * k, 0.178, 0.132, 0.0), (waist_y - 0.016 * k, 0.181, 0.134, 0.0),
                          (waist_y - 0.050 * k, 0.190, 0.134, -0.004), (crotch + 0.150 * k, 0.197, 0.136, -0.010),
                          (crotch + 0.098 * k, 0.195, 0.133, -0.012)):
        sagf = (lambda a, y=y: 0.016 * (0.6 * math.sin(4 * a + y * 40) + 0.4 * math.sin(7 * a + y * 80))
                - 0.012 * max(0.0, -math.cos(a)))
        rings.append(cg.ring(trunk_ring(y, hd * k, hw * k, dz * k, rad=sagf), None, CLOTH))
        ys.append(y)
    yT = crotch + 0.052 * k
    T = cg.ring(trunk_ring(yT, 0.124 * k, 0.186 * k, -0.012 * k, sq=2.3), None, CLOTH)
    rings.append(T)
    ys.append(yT)
    ut_t = max(1, round(TAU * 0.16 * k / 0.25))
    v = 0.0
    for a_, b_, y0_, y1_ in zip(rings[:-1], rings[1:], ys[:-1], ys[1:]):
        cg.band(a_, b_, ut_t, v, v + (y0_ - y1_) / 0.25)
        v += (y0_ - y1_) / 0.25
    # the crotch line: from the back centre (T[12]) down under the body and
    # up to the front centre (T[0]), seven points both legs share
    zb, zf = cg.P[T[12]][2], cg.P[T[0]][2]
    cl = []
    for q in range(1, 8):
        u = q / 8
        z = zb + (zf - zb) * u
        y = yT - (yT - (crotch - 0.004 * k)) * math.sin(math.pi * u) ** 0.55
        cl.append(cg.add((x0, y, z), None, CLOTH))
    # (cl runs back → front)

    legs = {}
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        th, sh_, ft = "Thigh." + side, "Shin." + side, "Foot." + side
        Tp, K, A = Jp(th), Jp(sh_), Jp(ft)
        axt, axs = unit(K - Tp), unit(A - K)
        LT, LS = float(np.linalg.norm(K - Tp)), float(np.linalg.norm(A - K))
        lat = unit(s * X - axt * (s * X @ axt))
        nb_k = unit(axt + axs)
        legs[side] = dict(T=Tp, K=K, A=A, axt=axt, axs=axs, nb_k=nb_k, LT=LT, LS=LS, s=s)
        half = [T[0]] + ([T[i] for i in range(1, 12)] if s > 0 else [T[24 - i] for i in range(1, 12)]) + [T[12]]
        r0 = half + cl                                    # front → lateral → back → crotch (back → front)
        # each point's turn about the thigh from its front toward its outside
        fr = unit(Z - axt * (Z @ axt))
        lt = unit(lat - fr * (lat @ fr))
        c0 = Tp + axt * 0.06 * k

        def ang(p, c=c0, fr=fr, lt=lt):
            d_ = np.asarray(p) - c
            return (math.atan2(d_ @ lt, d_ @ fr) / TAU) % 1.0
        t0 = [ang(cg.P[q]) for q in r0]
        # unwrap: the ring runs once round, increasing
        for q in range(1, len(t0)):
            while t0[q] < t0[q - 1] - 0.5:
                t0[q] += 1.0
        LSG = 16
        angs = [TAU * j / LSG for j in range(LSG)]

        def lring(c, t, r1, r2, col=CLOTH, bump=None, cen_lat=0.0):
            return cg.ring(frame_ring(np.asarray(c) + lt * cen_lat, fr, lt, t, r1, r2, angs, bump), None, col)

        lr, lv = [], []
        # the thigh, out of the brief: the thigh bearing, the EV1 band
        prof = [(0.118, 0.104, 0.098, 0.006, CLOTH), (0.160, 0.105, 0.103, 0.003, CLOTH),
                (0.205, 0.103, 0.101, 0.0, CLOTH), (0.250, 0.101, 0.099, 0.0, CLOTH),
                (0.320, 0.097, 0.095, 0.0, CLOTH), (LT / k - 0.075, 0.092, 0.090, 0.0, CLOTH)]
        for dd, r1, r2, cl_, col in prof:
            c = Tp + axt * dd * k
            f_ = LC * (1.0 + (FAT_T - 1.0) * smooth01(0.11, 0.20, dd))
            lr.append(lring(c, axt, r1 * k * f_, r2 * k * f_, col, cen_lat=cl_ * k,
                            bump=lambda a, dd=dd: 0.03 * math.sin(5 * a + dd * 30)
                            + 0.04 * max(0.0, -math.cos(a)) * math.sin(math.pi * min(1.0, dd / 0.4))))
            lv.append(dd * k)
        # the knee: pleats across the pivot, proud at the front
        for dd, r, col in ((-0.050, 0.091, CLOTH), (-0.026, 0.084, CLOTH_SH), (0.0, 0.089, CLOTH),
                           (0.026, 0.083, CLOTH_SH), (0.050, 0.087, CLOTH)):
            if dd < 0:
                c, t = K + axt * dd * k, axt if dd < -0.03 else unit(axt + nb_k)
            elif dd > 0:
                c, t = K + axs * dd * k, axs if dd > 0.03 else unit(axs + nb_k)
            else:
                c, t = K, nb_k
            lr.append(lring(c, t, r * k * LC * FAT_K, r * k * 0.97 * LC * FAT_K, col,
                            bump=lambda a, dd=dd: 0.035 * max(0.0, math.cos(a)) * (1.0 if dd == 0 else 0.4)
                            + 0.02 * math.sin(3 * a + dd * 120)))
            lv.append(LT + dd * k)
        # the shin, into the boot
        for dd, r in ((0.11, 0.088), (0.20, 0.085), (0.28, 0.078), (LS / k - 0.12, 0.068), (LS / k - 0.085, 0.064),
                      (LS / k - 0.060, 0.063)):
            c = K + axs * dd * k
            f_ = LC * (FAT_S if dd < LS / k - 0.10 else 1.0)
            lr.append(lring(c, axs, r * k * f_, r * k * 0.98 * f_, CLOTH,
                            bump=lambda a, dd=dd: 0.03 * math.sin(4 * a + dd * 50)))
            lv.append(LT + dd * k)
        ut_l = max(1, round(TAU * 0.10 * k / 0.25))
        # the crotch band: the 20 of the first ring down to the leg's 16
        t1 = [ang(cg.P[q]) for q in lr[0]]
        stitch(cg, r0, lr[0], t0, t1, ut_l, -0.4, lv[0] / 0.25)
        for a_, b_, va, vb in zip(lr[:-1], lr[1:], lv[:-1], lv[1:]):
            cg.band(a_, b_, ut_l, va / 0.25, vb / 0.25)

    # ── the folds (as the arms'): behind the knee, bunched above the boot,
    # long diagonals down the thigh from the crotch, the brief's own sag ──
    def leg_disp(Pv, Nv, G):
        d = 0.0026 * k * fbm(Pv, 71, 7.0 / k)
        sd = smooth01(x0 - 0.02 * k, x0 + 0.02 * k, Pv[:, 0])
        for side, f in (("Left", sd), ("Right", 1 - sd)):
            L = legs[side]
            # behind the knee: compression folds; in front: a little
            se = (Pv - L["K"]) @ L["nb_k"]
            rad = Pv - L["K"] - np.outer(se, L["nb_k"])
            rn = np.maximum(np.linalg.norm(rad, axis=1), 1e-9)
            back = unit(-Z + L["nb_k"] * (Z @ L["nb_k"]))
            cr = (rad @ back) / rn
            env = np.exp(-(se / (0.065 * k)) ** 2)
            ph = 2 * math.pi * se / (0.024 * k) + 2.4 * fbm(Pv, 81, 12.0 / k)
            d = d + f * env * (0.0062 * k * smooth01(-0.3, 0.8, cr) + 0.0015 * k) * np.sin(ph)
            # bunched in rings above the boot
            ha = (L["A"] - Pv) @ L["axs"]
            bun = smooth01(0.200 * k, 0.130 * k, ha) * (1 - smooth01(0.085 * k, 0.065 * k, ha))
            ph = 2 * math.pi * ha / (0.023 * k) + 2.0 * fbm(Pv, 91, 15.0 / k)
            d = d + f * 0.0048 * k * bun * np.sin(ph)
            # diagonal drape down the thigh and the shin
            for c0, ax, a0_, a1_, sd_ in ((L["T"], L["axt"], 0.08, L["LT"] / k - 0.08, 101),
                                          (L["K"], L["axs"], 0.08, L["LS"] / k - 0.20, 111)):
                t = (Pv - c0) @ ax
                r_ = Pv - c0 - np.outer(t, ax)
                ang = np.arctan2(r_ @ (L["s"] * X), r_ @ Z)
                band = smooth01(a0_ * k, a0_ * k + 0.04 * k, t) * (1 - smooth01(a1_ * k - 0.04 * k, a1_ * k, t))
                wob = fbm(Pv, sd_, 6.0 / k)
                dr = np.sin(2 * math.pi * t / (0.11 * k) + 1.3 * ang + 3.0 * wob)
                d = d + f * 0.0034 * k * band * np.sign(dr) * np.abs(dr) ** 1.6 * (0.5 + wob)
        # nothing on the waist's convolutes (they are their own folds)
        d = d * (1 - smooth01(waist_y - 0.03 * k, waist_y + 0.01 * k, Pv[:, 1]))
        return Nv * d[:, None]

    pc = cg.piece("LowerBody", "SuitFabric", "leg", subsurf=lod(1, 0, 0), disp=leg_disp if LOD < 2 else None)

    # ── the weights ─────────────────────────────────────────────────────────
    w_lo, w_hi = yw[-1] + 0.012 * k, yw[0] - 0.012 * k        # the waist's blend, Hip below → Back above

    def thigh_w(p, L):
        sv = float((p - L["T"]) @ L["axt"])
        rad = p - L["T"] - L["axt"] * sv
        nr = np.linalg.norm(rad)
        u = rad / nr if nr > 1e-9 else Z
        c, l_ = float(u @ Z), float(u @ (L["s"] * X))
        cc, ll = c * c, l_ * l_
        tot = max(cc + ll, 1e-9)
        lo = ((0.030 if c > 0 else -0.030) * cc + (0.000 if l_ > 0 else 0.050) * ll) / tot
        hi = ((0.100 if c > 0 else 0.150) * cc + (0.120 if l_ > 0 else 0.120) * ll) / tot
        return float(smooth01(lo * k, hi * k, sv))

    def knee_w(p, L):
        sv = float((p - L["K"]) @ L["nb_k"])
        rad = p - L["K"] - L["nb_k"] * sv
        cr = float(unit(rad) @ unit(-Z + L["nb_k"] * (Z @ L["nb_k"]))) if np.linalg.norm(rad) > 1e-9 else 0.0
        h = (0.060 + (0.016 - 0.060) * (cr + 1) / 2) * k
        return float(smooth01(-h, h, sv))

    def ankle_w(p, L):
        ha = float((L["A"] - p) @ L["axs"])
        return 1.0 - float(smooth01(0.050 * k, 0.100 * k, ha))

    def low_weights(Pv):
        out_w = []
        for p in Pv:
            y = p[1]
            back = float(smooth01(w_lo, w_hi, y))
            sd = float(smooth01(x0 - 0.02 * k, x0 + 0.02 * k, p[0]))
            parts = []
            for side, f in (("Left", sd), ("Right", 1 - sd)):
                if f <= 0:
                    continue
                L = legs[side]
                wt = thigh_w(p, L)
                wk = knee_w(p, L) if wt > 0 else 0.0
                wa = ankle_w(p, L) if wk > 0 else 0.0
                parts.append((f, {"Hip": 1 - wt, "Thigh." + side: wt * (1 - wk), "Shin." + side: wt * wk * (1 - wa),
                                  "Foot." + side: wt * wk * wa}))
            leg = wsum(*parts)
            out_w.append(wsum((back, {"Back": 1.0}), (1 - back, leg)))
        return out_w
    pc.W = low_weights

    # the waist bearing (Hip) and the thigh bearings (Thigh), where the cloth
    # under each is wholly on its bone
    bring = []
    for y, g in ((-0.012, 0.0), (-0.006, 0.006), (0.006, 0.006), (0.012, 0.0)):
        bring.append(dict(c=(x0, waist_y - 0.009 * k + y * k, zc), e1=X, e2=Z, r1=(0.181 + g) * k, r2=(0.135 + g) * k,
                          sq=2.4, w={"Hip": 1}))
    V, F, UVc, W, C = loft(bring, 24, tile=0.1)
    Piece("WaistRing", "SuitMetal", V, F, W, np.tile(METAL, (len(V), 1)), UVc=UVc, dirt="metal", smooth=False,
          sharp=30)
    for side, L in legs.items():
        ring_piece("ThighBearing." + side, "SuitMetal", L["T"] + L["axt"] * 0.160 * k, L["axt"], 0.104 * k,
                   0.122 * k, 0.022 * k, "Thigh." + side, METAL, segs=16, band=METAL_D)
    return legs


def boot(rig, D, J, side, s, k):
    """The BOOT, an EVA boot after the EMU's and the xEMU's: a tall, stiff
    upper of the suit's TMG (greyer, more used) high round the ankle to the
    ankle bearing, a raised toe box, a moulded rubber toe cap and heel
    counter, two buckled straps over the instep; under it a thick midsole and
    an outsole of square lugs with a heel block. Rigid on Foot, the toe box
    on Toes with a flex line at the ball of the foot. Built in the bind pose
    and carried into the authoring pose by the Foot's own turn (the knees are
    modelled bent)."""
    A, Tp = J("Foot." + side), J("Toes." + side)
    ft, to = "Foot." + side, "Toes." + side
    Mf = D[rig.index[ft]]

    def posed(V):
        V = np.asarray(V, float)
        return (np.hstack([V, np.ones((len(V), 1))]) @ Mf.T)[:, :3]
    bx = A[0] + s * 0.004 * k
    heel_z, toe_z = A[2] - 0.094 * k, Tp[2] + 0.118 * k
    sole_t = 0.034 * k                        # midsole + outsole
    lug_t = 0.007 * k
    ty = Tp[2]
    y0 = sole_t - 0.004 * k                   # the upper's foot, tucked into the midsole
    SEC = [  # z, half-width, top, sq
        (heel_z, 0.046, 0.110, 3.0), (heel_z + 0.010 * k, 0.060, 0.175, 3.0), (heel_z + 0.035 * k, 0.068, 0.205, 2.8),
        (A[2] + 0.010 * k, 0.070, 0.210, 2.6), (A[2] + 0.050 * k, 0.069, 0.190, 2.6), (ty - 0.060 * k, 0.067, 0.150, 2.8),
        (ty - 0.025 * k, 0.066, 0.122, 3.0), (ty + 0.010 * k, 0.064, 0.102, 3.2), (ty + 0.045 * k, 0.060, 0.092, 3.2),
        (toe_z - 0.035 * k, 0.054, 0.084, 3.0), (toe_z - 0.015 * k, 0.046, 0.076, 2.8), (toe_z - 0.004 * k, 0.034, 0.066, 2.6),
        (toe_z, 0.018, 0.056, 2.4)]

    def bw(z):
        return blend(ft, to, float(smooth01(ty - 0.030 * k, ty + 0.012 * k, z)))
    up_ = []
    for i, (z, hw, tp, sq) in enumerate(SEC):
        tp = tp * k

        def ucol(a, z=z):
            # the toe cap and heel counter: moulded rubber over the low part
            low = math.sin(a) < (-0.15 if z > ty else -0.45)
            return BOOT_RUB if (low and (z > ty - 0.020 * k or z < heel_z + 0.045 * k)) else BOOT_W
        up_.append(dict(c=(bx, (y0 + tp) / 2, z), e1=X, e2=Y, r1=hw * k, r2=(tp - y0) / 2, sq=sq, w=bw(z),
                        col=ucol, rad=lambda a, i=i: 0.0012 * k * math.sin(5 * a + i * 1.7)))
    V, F, UVc, W, C = loft(up_, lod(28, 20, 14), cap0=True, cap1=True, tile=0.25)
    fm = [1 if all(tuple(C[q]) == BOOT_RUB for q in f) else 0 for f in F]
    pc = Piece("Boot." + side, "SuitFabric", posed(V), F, W, C, UVc=UVc, dirt="boot", sharp=60,
               mats=["SuitFabric", "SuitRubber"], fmat=fm)
    pc.mat_col = {1: BOOT_RUB}
    pc.dirt2 = "boot"
    # the midsole: a slab a little proud of the upper all round, its edge
    # rounded; the outsole's lugs and heel block under it
    so_ = []
    for i, (z, hw, tp, sq) in enumerate(SEC):
        so_.append(dict(c=(bx, lug_t + (sole_t - lug_t) / 2, z), e1=X, e2=Y,
                        r1=(hw + 0.008) * k * (0.92 if i in (0, len(SEC) - 1) else 1.0),
                        r2=(sole_t - lug_t) / 2, sq=5.0, w=bw(z), col=SOLE))
    V, F, UVc, W, C = loft(so_, lod(20, 14, 10), cap0=True, cap1=True, tile=0.25)
    Piece("Sole." + side, "SuitRubber", posed(V), F, W, C, UVc=UVc, dirt="boot", sharp=50)
    if LOD < 2:
        zs = np.linspace(heel_z + 0.016 * k, toe_z - 0.022 * k, lod(9, 6, 0))
        for j, z in enumerate(zs):
            if heel_z + 0.075 * k < z < heel_z + 0.110 * k:
                continue                                   # the arch between heel block and forefoot
            hw = float(np.interp(z, [q[0] for q in SEC], [q[1] for q in SEC])) * k
            for sx in (-1, 1):
                lc = np.array([bx + sx * hw * 0.48, lug_t / 2 + 0.0005, z])
                V, F = box_mesh(lc, (hw * 0.80, lug_t + 0.001, 0.020 * k))
                Piece("Lug." + side, "SuitRubber", posed(V), F, bw(z), SOLE, tile=0.25, dirt="boot", smooth=False,
                      sharp=30)
    # two straps over the instep, each buckled on the outside
    zs_, hw_, tp_ = [q[0] for q in SEC], [q[1] for q in SEC], [q[2] for q in SEC]
    for zst in (A[2] + 0.050 * k, A[2] + 0.095 * k):
        sp_ = []
        for z in (zst - 0.011 * k, zst + 0.011 * k):
            hw, tp = float(np.interp(z, zs_, hw_)) * k, float(np.interp(z, zs_, tp_)) * k
            sp_.append(dict(c=(bx, (y0 + tp) / 2 + 0.002 * k, z), e1=X, e2=Y, r1=hw + 0.0035 * k,
                            r2=(tp - y0) / 2 + 0.0035 * k, sq=2.8, w={ft: 1}, col=(0.30, 0.30, 0.31)))
        V, F, UVc, W, C = loft(sp_, lod(28, 20, 14), tile=0.1)
        Piece("BootStrap." + side, "SuitRubber", posed(V), F, W, C, UVc=UVc, dirt="boot")
        hw, tp = float(np.interp(zst, zs_, hw_)) * k, float(np.interp(zst, zs_, tp_)) * k
        bc = np.array([bx + s * (hw + 0.006 * k), y0 + (tp - y0) * 0.55, zst])
        V, F = box_mesh(bc, (0.008 * k, 0.026 * k, 0.030 * k))
        Piece("Buckle." + side, "SuitMetal", posed(V), F, {ft: 1}, METAL, tile=0.25, dirt="metal",
              mods=[("bevel", 0.002 * k, lod(2, 1, 1), 40)], sharp=40)
    # the ankle bearing on the boot's collar
    pc = ring_piece("Ankle." + side, "SuitMetal", np.array([bx, 0.190 * k, A[2] - 0.006 * k]), Y, 0.062 * k,
                    0.082 * k, 0.032 * k, ft, METAL, segs=16, band=METAL_D)
    me = pc.ob.data
    Vb = np.zeros(len(me.vertices) * 3)
    me.vertices.foreach_get("co", Vb)
    me.vertices.foreach_set("co", posed(Vb.reshape(-1, 3)).reshape(-1))
    me.update()


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


# The head itself, its hair and the comm cap are the crew's own now
# (tools/gen_faces.py: models/astronaut/faces, hung on the Head bone by
# scripts/face.lua's Face node); the suit keeps only the neck and the
# collar. HEAD_IN_SUIT = True puts the old plain head and cap back.
HEAD_IN_SUIT = False


def head_piece(J, k, x0, zh, neck_top, nc):
    """The neck rising out of the neck ring's well (and, with HEAD_IN_SUIT,
    the old plain head in a comm cap on the Head bone)."""
    Hj = J("Head")
    hc = Hj + np.array([0, 0.150, 0.020]) * k
    if HEAD_IN_SUIT:
        old_head(J, k, Hj, hc)
    # the neck: out of the well in the neck ring and up into the head, the
    # cooling garment's collar at its base
    nr = []
    # (thin: the crew's own head brings its neck down into the ring over this
    # one, which is only there so the ring's well is never empty)
    # (and short: it stops in the ring's well, below the chin and the jaw at any
    # turn of the head — tools/perf/neck_check.py — so nothing of it is seen)
    for y, r, w in ((neck_top - 0.012 * k, 0.038, {"Back": 1}), (neck_top + 0.004 * k, 0.036, blend("Back", "Head", 0.15)),
                    (Hj[1] + 0.012 * k, 0.033, blend("Back", "Head", 0.5)), (Hj[1] + 0.018 * k, 0.030, blend("Back", "Head", 0.7))):
        nr.append(dict(c=(x0, y, Hj[2] - 0.012 * k), e1=X, e2=Z, r1=r * k, r2=r * k * 1.1, w=w))
    V, F, UVc, W, C = loft(nr, 12, tile=0.25)
    npc = Piece("Neck", "SuitHead", V, F, W, (1, 1, 1), dirt="none")
    npc.uvmode = "face"
    npc.face = (hc, k)
    cr = [dict(c=(x0, neck_top - 0.020 * k + y * k, Hj[2] - 0.004 * k), e1=X, e2=Z, r1=r * k, r2=r * k * 1.1,
               w={"Back": 1}, col=(0.50, 0.55, 0.62)) for y, r in ((0.0, 0.060), (0.026, 0.059), (0.032, 0.054))]
    V, F, UVc, W, C = loft(cr, 12, tile=0.25)
    Piece("Collar", "SuitFabric", V, F, W, C, UVc=UVc, dirt="none")


def old_head(J, k, Hj, hc):
    """A plain human head in a comm cap ("Snoopy cap") on the Head bone: a
    cube sphere shaped by head_r, the face painted (textures/suit/head.png);
    the cap a shell 5 mm off the skull with its ear cups, two mic booms and a
    chin strap; the neck rising out of the neck ring's well."""
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
        for a in np.linspace(0, 104, lod(11, 9, 8)):
            r = math.radians(a)
            prof.append((R * scale * math.sin(r), R * scale * math.cos(r)))
        # the skirt to the ring
        prof.append((0.140 * k * scale, base[1] + 0.012 * k - hc[1]))
        return prof
    nb_ = lod(32, 24, 16)
    brings = lathe_pts(bubble_rings(1.0)[1:], hc, Y, Z, nb_)
    for r in brings:
        r["w"] = {"Back": 1}
    # the skirt ring sits on the neck ring (the bubble is forward of it)
    brings[-1]["c"] = base + nax * 0.012 * k
    V, F, UVc, W, C = loft(brings, nb_, cap0=True, tile=0.5)
    Piece("Bubble", "SuitBubble", V, F, W, (1, 1, 1), UVc=UVc, part="helmet", dirt="none")

    # The EVVA shell over the top, back and sides, with the visor opening
    # cut from its front: a thick shell, its edge rolled.
    Re = R * 1.075
    shell_prof = []
    for a in np.linspace(0, 112, lod(14, 10, 8)):
        r = math.radians(a)
        shell_prof.append((Re * math.sin(r), Re * math.cos(r)))
    ns_ = lod(40, 28, 20)
    srings = lathe_pts(shell_prof[1:], hc, Y, Z, ns_)
    for r in srings:
        r["w"] = {"Back": 1}
        r["col"] = SHELL
    V, F, UVc, W, C = loft(srings, ns_, cap0=True, tile=0.5)
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
    V, F, UVc, W, C = loft(limb(st, X), 6, tile=0.1)
    Piece("EVVAseam", "SuitShell", V, F, W, C, UVc=UVc, part="helmet", dirt="evva")

    # The gold sun visor: a spherical cap filling the opening, standing just
    # off the bubble and tucked under the EVVA's front edge.
    Rv = R * 1.035
    vr = []
    for el_ in np.linspace(-50, 38, lod(13, 9, 7)):
        vr.append(el_)
    Vv, UVv = [], []
    azs = np.linspace(-68, 68, lod(25, 17, 13))
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

    # The helmet lights and camera (after the EMU's EHIP): at each temple a
    # cylindrical lamp housing, its back rounded and its front a bezel round
    # the LED lens (the lens is the "lamps" model, which glows), carried on a
    # clamp arm whose foot is screwed to the EVVA's side; the HD camera rides
    # the right housing, its lens barrel forward. Twin pivot hubs carry the
    # visor at the sides, and a pull tab sits on its top edge.
    for sx in (-1, 1):
        side_dir = np.array([sx, 0.0, 0.0])
        lc = hc + np.array([sx * (Re + 0.030 * k), 0.026 * k, 0.030 * k])
        Lh, rh = 0.105 * k, 0.019 * k
        hprof = [(1e-4, -Lh / 2, SHELL_G), (rh * 0.55, -Lh / 2, SHELL_G), (rh * 0.92, -Lh / 2 + 0.008 * k, SHELL_G),
                 (rh, -Lh / 2 + 0.018 * k, SHELL_G), (rh, Lh / 2 - 0.016 * k, SHELL_G),
                 (rh, Lh / 2 - 0.016 * k, SHELL_D), (rh * 1.12, Lh / 2 - 0.012 * k, SHELL_D), (rh * 1.12, Lh / 2, SHELL_D),
                 (rh * 0.80, Lh / 2, SHELL_D), (rh * 0.78, Lh / 2 - 0.004 * k, SHELL_D), (1e-4, Lh / 2 - 0.004 * k, SHELL_D)]
        lathe_piece("LampHousing", "SuitShell", lc, Z, hprof, {"Back": 1}, lod(16, 12, 8), part="helmet",
                    dirt="evva", sharp=40, ref=Y)
        # the lens (glows; the "lamps" model) and the reflector's rings
        lathe_piece("LampLens", "SuitLamp", lc + Z * (Lh / 2 - 0.005 * k), Z,
                    [(1e-4, 0.0, (1, 1, 1)), (rh * 0.80, 0.0, (1, 1, 1)), (rh * 0.80, 0.0015 * k, (1, 1, 1)),
                     (1e-4, 0.0025 * k, (1, 1, 1))], {"Back": 1}, lod(24, 16, 10), part="lamps", dirt="none", ao=False)
        # cooling fins on the housing's back half
        if LOD < 2:
            for i in range(2):
                fz = -Lh / 2 + 0.024 * k + i * 0.009 * k
                lathe_piece("LampFin", "SuitShell", lc + Z * fz, Z,
                            [(rh * 0.95, 0.0, SHELL_G), (rh * 1.14, 0.0, SHELL_G), (rh * 1.14, 0.0035 * k, SHELL_G),
                             (rh * 0.95, 0.0035 * k, SHELL_G)], {"Back": 1}, lod(16, 12, 8), part="helmet",
                            dirt="evva", sharp=40, ref=Y)
        # the clamp arm and its foot on the EVVA
        foot, nn = hc + side_dir * Re * 0.99 + np.array([0, 0.030 * k, -0.010 * k]), side_dir
        arm_c = (foot + lc) / 2 - Z * 0.020 * k
        rbox("LampArm", "SuitShell", arm_c, (np.linalg.norm(lc - foot) + 0.010 * k, 0.016 * k, 0.020 * k), None,
             col=SHELL_D, r=0.003 * k, part="helmet", dirt="evva")
        rbox("LampFoot", "SuitShell", foot + side_dir * 0.004 * k - Z * 0.020 * k, (0.010 * k, 0.040 * k, 0.050 * k),
             None, col=SHELL_D, r=0.003 * k, part="helmet", dirt="evva")
        for oy, oz in ((0.012, -0.034), (-0.012, -0.006)):
            bolt("LampFootBolt", foot + side_dir * 0.009 * k + np.array([0, oy * k, oz * k]), side_dir, 0.0026 * k,
                 0.0025 * k, {"Back": 1}, part="helmet")
        # the visor's pivot hub
        pivot = hc + side_dir * Re * 1.0 + np.array([0, -0.006 * k, 0.018 * k])
        lathe_piece("VisorPivot", "SuitMetal", pivot - side_dir * 0.004 * k, side_dir,
                    [(1e-4, 0.0, METAL_D), (0.017 * k, 0.0, METAL_D), (0.017 * k, 0.005 * k, METAL_D),
                     (0.013 * k, 0.008 * k, METAL_D), (0.006 * k, 0.008 * k, METAL_D), (0.006 * k, 0.010 * k, METAL),
                     (1e-4, 0.010 * k, METAL)], {"Back": 1}, lod(14, 10, 8), part="helmet", dirt="metal", sharp=35)
        if sx < 0:
            # (the right side: the clip-on torch, items "flashlight", straps
            # over the left housing — scripts/flashlight.lua MOUNT)
            # the camera: a body with rounded edges on the housing, a lens
            # barrel and its dark glass
            cc = lc + np.array([0.0, rh + 0.017 * k, 0.004 * k])
            rbox("Camera", "SuitShell", cc, (0.032 * k, 0.030 * k, 0.074 * k), None, col=(0.20, 0.20, 0.21),
                 r=0.004 * k, part="helmet", dirt="evva")
            lathe_piece("CameraLens", "SuitShell", cc + Z * 0.037 * k, Z,
                        [(1e-4, 0.0, SHELL_D), (0.011 * k, 0.0, SHELL_D), (0.011 * k, 0.010 * k, SHELL_D),
                         (0.009 * k, 0.012 * k, SHELL_D), (0.009 * k, 0.012 * k, (0.03, 0.035, 0.05)),
                         (1e-4, 0.010 * k, (0.03, 0.035, 0.05))], {"Back": 1}, lod(20, 14, 10), part="helmet",
                        dirt="none", sharp=40, ref=Y)
    # the visor's pull tab
    tab = hc + Rv * np.array([0.0, math.sin(math.radians(36)), math.cos(math.radians(36))]) * 1.01
    rbox("VisorTab", "SuitShell", tab, (0.030 * k, 0.010 * k, 0.012 * k), frame_to(unit(tab - hc), Z), col=SHELL_D,
         r=0.002 * k, part="visor", dirt="none")


# ═════════════════════════════════════════════════════════════════════════════
# export
# ═════════════════════════════════════════════════════════════════════════════

def export(rig, D, path):
    arrays = {"D": D}
    manifest = []
    for pc in PIECES:
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
        if callable(pc.W) and getattr(pc, "wg", False):
            names = {g.index: g.name for g in ob.vertex_groups}
            G = [{names[g.group]: g.weight for g in v.groups} for v in me.vertices]
            Wl = pc.W(P, G)
        elif callable(pc.W):
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
        ao = getattr(pc, "ao", None)
        if pc.mats:
            tm = np.zeros(len(me.loop_triangles), np.int64)
            me.loop_triangles.foreach_get("material_index", tm)
            groups = [(q, np.nonzero(tm == q)[0]) for q in range(len(pc.mats))]
        else:
            groups = [(None, np.arange(len(tris)))]
        for q, sel in groups:
            if len(sel) == 0:
                continue
            cs = (sel[:, None] * 3 + np.arange(3)[None, :]).reshape(-1)     # this group's corners
            cvq, Nq, UVq = cv[cs], N[cs], UV[cs]
            # weld identical corners into vertices
            key = np.hstack([cvq[:, None].astype(float), np.round(Nq * 1e4), np.round(UVq * 1e5)])
            _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
            inv = inv.reshape(-1)
            vid = cvq[first]
            I = inv.reshape(-1, 3)
            Cq = Cv[vid].copy()
            if q is not None and q in pc.mat_col:
                Cq[:] = pc.mat_col[q]
            if ao is not None:
                Cq *= ao[vid][:, None]
            n_ = len(manifest)
            arrays[f"{n_}_P"] = P[vid]
            arrays[f"{n_}_N"] = Nq[first]
            arrays[f"{n_}_UV"] = UVq[first]
            arrays[f"{n_}_C"] = Cq
            arrays[f"{n_}_J"] = Jn[vid]
            arrays[f"{n_}_W"] = Wn[vid]
            arrays[f"{n_}_I"] = I
            mat = pc.mat if q is None else pc.mats[q]
            dirt = pc.dirt if q is None or q == 0 else getattr(pc, "dirt2", pc.dirt)
            manifest.append(dict(name=pc.name, mat=mat, part=pc.part, dirt=dirt, tris=int(len(I))))
    arrays["manifest"] = np.frombuffer(json.dumps(manifest).encode(), np.uint8)
    np.savez_compressed(path, **arrays)
    tot = {}
    for m in manifest:
        tot[m["part"]] = tot.get(m["part"], 0) + m["tris"]
    print("SUIT_BLENDER", json.dumps(tot))


def bake_ao(k):
    """AMBIENT OCCLUSION, baked into the vertex colours with Blender's own
    ray tracer (a BVH of the finished pieces in the authoring pose): from each
    vertex, 24 cosine-weighted rays over its normal's hemisphere, each that
    hits something within 9 cm counted by how near it hit. So the creases of
    the cloth, the skirt under a bearing, the gaps between the fingers, the
    pack's seam on the back and the boot's welt darken by their own geometry,
    as a texture bake would darken them, without a unique UV set (the suit's
    textures tile). The suit is traced on its own (the helmet comes off); the
    helmet against the suit and itself. Clear and glowing parts take none."""
    dist = 0.09 * k
    n_r = lod(24, 14, 8)
    gold = math.pi * (3 - math.sqrt(5))
    dirs = []
    for i in range(n_r):
        z = math.sqrt(1 - (i + 0.5) / n_r)               # cosine-weighted
        r = math.sqrt(max(0.0, 1 - z * z))
        dirs.append((r * math.cos(i * gold), r * math.sin(i * gold), z))
    dirs = np.array(dirs)
    groups = (("suit", ("suit",)), ("helmet", ("suit", "helmet", "visor", "lamps")))
    for target, occl in groups:
        V, Fs = [], []
        for pc in PIECES:
            if pc.part not in occl or pc.mat in ("SuitBubble",):
                continue
            pc.apply()
            me = pc.ob.data
            o = len(V)
            V += [v.co.copy() for v in me.vertices]
            Fs += [[o + i for i in p.vertices] for p in me.polygons]
        tree = BVHTree.FromPolygons(V, Fs)
        for pc in PIECES:
            if pc.part != target and not (target == "helmet" and pc.part in ("visor", "lamps")):
                continue
            if not pc.ao_on or pc.mat in ("SuitBubble", "SuitVisor", "SuitLamp", "SuitDecal"):
                continue
            me = pc.ob.data
            nv = len(me.vertices)
            P = np.zeros(nv * 3); me.vertices.foreach_get("co", P); P = P.reshape(-1, 3)
            N = np.zeros(nv * 3); me.vertices.foreach_get("normal", N); N = N.reshape(-1, 3)
            ao = np.ones(nv)
            for i in range(nv):
                n = N[i]
                t1 = np.cross(n, X if abs(n[0]) < 0.9 else Y)
                t1 /= max(np.linalg.norm(t1), 1e-9)
                t2 = np.cross(n, t1)
                D = dirs[:, :1] * t1 + dirs[:, 1:2] * t2 + dirs[:, 2:] * n
                o = Vector(P[i] + n * 0.0012 * k)
                occ = 0.0
                for d in D:
                    hit = tree.ray_cast(o, Vector(d), dist)
                    if hit[0] is not None:
                        occ += 1.0 - (hit[3] / dist) ** 1.5
                ao[i] = 1.0 - occ / n_r
            pc.ao = np.clip(0.42 + 0.58 * ao ** 1.2, 0.42, 1.0)
    print("SUIT_AO done")


def main():
    global COL
    bpy.ops.wm.read_factory_settings(use_empty=True)
    COL = bpy.data.collections.new("suit")
    bpy.context.scene.collection.children.link(COL)
    rig = Rig(RIG_PATH)
    D = build(rig)
    bake_ao(rig.p("Head")[1] / 1.575)
    export(rig, D, OUT_PATH)


main()
