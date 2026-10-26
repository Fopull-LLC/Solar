"""The hand tools' geometry, built in Blender (run headless by tools/gen_tools.py).

    blender --background --factory-startup --python tools/gen_tools_blender.py -- OUT.json

Blender is used for what it does better than numpy primitives: real bevels
(with the bevel faces of painted parts in a worn-edge material), extruded
silhouettes, swept hoses. Nothing is rendered here and no .blend is kept: each
tool is built from code, evaluated, triangulated and written to OUT.json as
triangles grouped by (node, material), with the anchors and the articulated
nodes' pivots. tools/gen_tools.py turns that into the .glb files (adding the
first-person gloves) and the prefabs.

Coordinates are the GAME's, written straight into Blender's numbers: +X right,
+Y up, the barrel down -Z, metres, the grip at about the origin. Blender's own
idea of "up" never matters, nothing is rendered.

Articulated nodes (the engine poses a model's sub-nodes as bones:
anim:setBoneRot):
  gravity gun  ClawTop, ClawLeft, ClawRight, each under a <name>Mount node
               rolled round the barrel axis to its place, so the claw itself
               opens with a plain pitch about its hinge.
  laser        Focus, the knurled focusing ring, spun round the barrel axis.
"""
import json
import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

UV_M = 3.0          # tiled materials: one texture repeat per 1/UV_M metres
WEAR = {"Enamel": "EnamelWorn", "GunPaint": "PaintWorn", "Hazard": "PaintWorn"}

# The decal atlas (textures/tools/tool_decals.png, 512²), cell = (x, y, w, h) px.
# tools/gen_tools.py draws it from the same table (it imports this dict by
# reading this file's DECALS literal), so the two never disagree.
DECALS = {
    "gm3":        (0,   0, 256,  80),
    "tl7":        (256, 0, 256,  80),
    "gm3_name":   (0,  80, 512,  40),
    "tl7_name":   (0, 120, 512,  40),
    "field_warn": (0, 160, 192, 128),
    "laser_warn": (192, 160, 192, 128),
    "emblem":     (384, 160, 128, 128),
    "hazard":     (0, 288, 128,  32),
    "hot":        (128, 288, 192, 48),
    "fill":       (320, 288, 192, 48),
    "serial_a":   (0, 336, 256,  32),
    "serial_b":   (256, 336, 256, 32),
    "arrow":      (0, 368, 128,  64),
    "charge":     (128, 368, 256, 32),
    "dig":        (128, 400, 256, 32),
    "bolts":      (384, 368, 128, 64),
}
ATLAS = 512.0

OBJS = []           # (object, node, decal?)
PER_OBJ = [True] if "--count" in sys.argv else []


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    OBJS.clear()


def mat(name):
    m = bpy.data.materials.get(name)
    return m or bpy.data.materials.new(name)


def finish(bm, name, material, node="Body", bevel=0.0, segs=1, sharp=40.0, decal=False, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(mat(material))
    wear = WEAR.get(material)
    if wear:
        me.materials.append(mat(wear))
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
        me.set_sharp_from_angle(angle=math.radians(sharp))
    if bevel > 0:
        md = ob.modifiers.new("bevel", "BEVEL")
        md.width = bevel
        md.segments = segs
        md.limit_method = "ANGLE"
        md.angle_limit = math.radians(35)
        md.harden_normals = True
        md.miter_outer = "MITER_ARC"
        if wear:
            md.material = 1
    OBJS.append((ob, node, decal))
    return ob


# ── primitive builders (each returns a fresh bmesh) ────────────────────────

def bm_box(center, size, M=None):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    S = Matrix.Diagonal((size[0], size[1], size[2], 1.0))
    T = Matrix.Translation(Vector(center))
    R = (M.to_4x4() if M is not None else Matrix.Identity(4))
    bmesh.ops.transform(bm, matrix=T @ R @ S, verts=bm.verts)
    return bm


def box(name, mat_, center, size, M=None, bevel=0.0, node="Body", segs=1):
    if min(size) < 0.012:
        bevel = 0.0         # a bevel on a small part costs 32 triangles and never shows
    return finish(bm_box(center, size, M), name, mat_, node, bevel=bevel, segs=segs)


def orient(p0, p1):
    """A matrix taking +Z onto p0→p1, translated to p0."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    return Matrix.Translation(p0) @ q.to_matrix().to_4x4(), d.length


def lathe_bm(prof, segs=24, a0=0.0, a1=2 * math.pi, cap0=False, cap1=False):
    """A surface of revolution about +Z: prof = [(r, z), ...]."""
    bm = bmesh.new()
    full = abs(a1 - a0 - 2 * math.pi) < 1e-6
    n = segs if full else segs + 1
    rings = []
    for r, z in prof:
        ring = []
        for k in range(n):
            a = a0 + (a1 - a0) * k / segs
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
        rings.append(ring)
    for i in range(len(rings) - 1):
        A, B = rings[i], rings[i + 1]
        for k in range(segs):
            k1 = (k + 1) % n
            if prof[i][0] < 1e-7 and prof[i + 1][0] < 1e-7:
                continue
            try:
                if prof[i][0] < 1e-7:
                    bm.faces.new((A[k], B[k], B[k1]))
                elif prof[i + 1][0] < 1e-7:
                    bm.faces.new((A[k], B[k], A[k1]))
                else:
                    bm.faces.new((A[k], B[k], B[k1], A[k1]))
            except ValueError:
                pass
    if cap0 and full and prof[0][0] > 1e-7:
        bm.faces.new(list(reversed(rings[0])))
    if cap1 and full and prof[-1][0] > 1e-7:
        bm.faces.new(rings[-1])
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def lathe(name, mat_, prof, at=(0, 0, 0), segs=24, node="Body", bevel=0.0, cap0=False, cap1=False, M=None, sharp=40.0,
          a0=0.0, a1=2 * math.pi):
    bm = lathe_bm(prof, segs, a0=a0, a1=a1, cap0=cap0, cap1=cap1)
    T = Matrix.Translation(Vector(at)) @ (M.to_4x4() if M is not None else Matrix.Identity(4))
    bmesh.ops.transform(bm, matrix=T, verts=bm.verts)
    return finish(bm, name, mat_, node, bevel=bevel, sharp=sharp)


def cyl(name, mat_, p0, p1, r, segs=16, r1=None, node="Body", bevel=0.0, caps=True):
    M, L = orient(p0, p1)
    if r < 0.016:
        bevel = 0.0
    bm = lathe_bm([(r, 0.0), (r if r1 is None else r1, L)], segs, cap0=caps, cap1=caps)
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    return finish(bm, name, mat_, node, bevel=bevel)


def ring_z(name, mat_, z, r_in, r_out, w, x=0.0, y=0.0, segs=24, node="Body", bevel=0.0):
    bm = lathe_bm([(r_in, z + w / 2), (r_out, z + w / 2), (r_out, z - w / 2), (r_in, z - w / 2)], segs)
    bmesh.ops.transform(bm, matrix=Matrix.Translation((x, y, 0)), verts=bm.verts)
    return finish(bm, name, mat_, node, bevel=bevel)


def torus_z(name, mat_, z, R, r, x=0.0, y=0.0, seg_major=16, seg_minor=6, node="Body"):
    bm = bmesh.new()
    rings = []
    for i in range(seg_major):
        a = 2 * math.pi * i / seg_major
        c, s = math.cos(a), math.sin(a)
        ring = []
        for j in range(seg_minor):
            b = 2 * math.pi * j / seg_minor
            rr = R + r * math.cos(b)
            ring.append(bm.verts.new((x + rr * c, y + rr * s, z + r * math.sin(b))))
        rings.append(ring)
    for i in range(seg_major):
        A, B = rings[i], rings[(i + 1) % seg_major]
        for j in range(seg_minor):
            j1 = (j + 1) % seg_minor
            bm.faces.new((A[j], B[j], B[j1], A[j1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish(bm, name, mat_, node, sharp=80.0)


def slab(name, mat_, prof, x0, x1, plane="yz", node="Body", bevel=0.0, segs=1, M=None, at=(0, 0, 0)):
    """An extruded silhouette. plane "yz": prof = [(z, y), ...] extruded along
    X from x0 to x1; "xy": prof = [(x, y)] along Z; "xz": prof = [(x, z)]
    along Y."""
    bm = bmesh.new()

    def P(u, v, w):
        if plane == "yz":
            return (w, v, u)
        if plane == "xy":
            return (u, v, w)
        return (u, w, v)
    lo = [bm.verts.new(P(u, v, x0)) for u, v in prof]
    hi = [bm.verts.new(P(u, v, x1)) for u, v in prof]
    n = len(prof)
    bm.faces.new(lo)
    bm.faces.new(list(reversed(hi)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # n-gon caps: triangulate them beautifully so bevels stay clean
    T = Matrix.Translation(Vector(at)) @ (M.to_4x4() if M is not None else Matrix.Identity(4))
    bmesh.ops.transform(bm, matrix=T, verts=bm.verts)
    return finish(bm, name, mat_, node, bevel=bevel, segs=segs)


def hose(name, mat_, pts, r, node="Body", res=3, sides=6):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = max(0, sides // 2 - 2)
    cu.resolution_u = res
    cu.use_fill_caps = True
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for bp, p in zip(sp.bezier_points, pts):
        bp.co = Vector(p)
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    ob = bpy.data.objects.new(name, cu)
    bpy.context.scene.collection.objects.link(ob)
    cu.materials.append(mat(mat_))
    OBJS.append((ob, node, False))
    return ob


def bolt(name, p, normal, r=0.0045, h=0.003, mat_="Chrome", node="Body"):
    n = Vector(normal).normalized()
    p = Vector(p)
    return cyl(name, mat_, p - n * 0.001, p + n * h, r, segs=6, node=node)


def decal(name, cell, center, normal, up, w, h, node="Body", flip=False):
    """A cut-out label: a quad a hair off the surface, UV'd to an atlas cell."""
    x, y, cw, ch = DECALS[cell]
    n = Vector(normal).normalized()
    u = Vector(up).normalized()
    rgt = u.cross(n).normalized()          # reading direction, seen from outside
    if flip:
        rgt = -rgt
    c = Vector(center) + n * 0.0007
    bm = bmesh.new()
    vs = [bm.verts.new(c + rgt * (sx * w / 2) + u * (sy * h / 2)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.dot(n) < 0:
        f.normal_flip()
    uvl = bm.loops.layers.uv.new("decal")
    u0, u1 = x / ATLAS, (x + cw) / ATLAS
    v0, v1 = 1 - (y + ch) / ATLAS, 1 - y / ATLAS        # glTF V runs down the image
    for lp in f.loops:
        q = lp.vert.co - c
        a = q.dot(rgt) / w + 0.5
        b = q.dot(u) / h + 0.5
        lp[uvl].uv = (u0 + (u1 - u0) * a, v0 + (v1 - v0) * b)
    return finish(bm, name, "ToolDecal", node, decal=True, smooth=False)


def band(name, center_z, r, w, segs=16, x=0.0, y=0.0, node="Body", cell="hazard"):
    """A ring of decal quads round a cylinder, each a whole atlas cell, so a
    tileable stripe runs round unbroken."""
    xx, yy, cw, ch = DECALS[cell]
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("decal")
    u0, u1 = xx / ATLAS, (xx + cw) / ATLAS
    v0, v1 = 1 - (yy + ch) / ATLAS, 1 - yy / ATLAS
    for k in range(segs):
        a0, a1 = 2 * math.pi * k / segs, 2 * math.pi * (k + 1) / segs
        P = [(x + r * math.cos(a0), y + r * math.sin(a0), center_z - w / 2),
             (x + r * math.cos(a1), y + r * math.sin(a1), center_z - w / 2),
             (x + r * math.cos(a1), y + r * math.sin(a1), center_z + w / 2),
             (x + r * math.cos(a0), y + r * math.sin(a0), center_z + w / 2)]
        f = bm.faces.new([bm.verts.new(p) for p in P])
        f.normal_update()
        mid = Vector((math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2), 0))
        if f.normal.dot(mid) < 0:
            f.normal_flip()
        for lp, (a, b) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            lp[uvl].uv = (u0 + (u1 - u0) * a, v0 + (v1 - v0) * b)
    return finish(bm, name, "ToolDecal", node, decal=True, smooth=False)


def mirror_x(ob):
    """A mirrored copy (X → -X) of an object, same node and material."""
    me = ob.data.copy()
    o2 = bpy.data.objects.new(ob.name + "_m", me)
    bpy.context.scene.collection.objects.link(o2)
    for md in ob.modifiers:
        m2 = o2.modifiers.new(md.name, md.type)
        for k in ("width", "segments", "limit_method", "angle_limit", "harden_normals", "miter_outer", "material"):
            if hasattr(md, k):
                setattr(m2, k, getattr(md, k))
    o2.matrix_world = Matrix.Scale(-1, 4, (1, 0, 0)) @ ob.matrix_world
    node = next(n for o, n, _ in OBJS if o == ob)
    OBJS.append((o2, node, False))
    return o2


def rotate_objs(objs, M):
    for ob in objs:
        ob.matrix_world = M @ ob.matrix_world


# ── the GRAVITY GUN: a field manipulator ───────────────────────────────────
#
# Rear to front: a power cell slung low behind the grip (so the first-person
# view looks past it), a graphite receiver with an enamel side plate on the
# left and an open vent and gauge on the right, two capacitors along the top,
# the field-coil body (copper windings round a glowing core in a cage, a
# rubber-padded guard on the left for the off hand, a fore-grip under it),
# the emitter bell with its glowing dish, and three hinged claws round it.

GG_Y = 0.05                 # the barrel axis
GG_CLAW_Z = -0.238          # the claws' hinge plane
GG_CLAW_R = 0.071           # hinge radius from the axis
GG_CLAWS = (("ClawTop", 90.0), ("ClawLeft", 210.0), ("ClawRight", 330.0))


def gg_claw(name, angle_deg):
    """One claw, built as the TOP claw (pivot on its hinge, opening = a pitch
    about X), then rolled round the barrel axis to its place."""
    node = name
    py, pz = GG_Y + GG_CLAW_R, GG_CLAW_Z
    obs = []
    # the blade: out from the hinge, along, and hooking in at the tip
    prof = [(0.016, 0.010), (-0.025, 0.034), (-0.085, 0.050), (-0.135, 0.043), (-0.172, 0.016), (-0.186, -0.016),
            (-0.172, -0.012), (-0.140, 0.012), (-0.090, 0.022), (-0.040, 0.010), (-0.004, -0.012), (0.016, -0.010)]
    prof = [(z + pz, y + py) for z, y in prof]
    obs.append(slab(name + "_blade", "GunBody", prof, -0.0085, 0.0085, node=node, bevel=0.003))
    # the orange armour on its back half (the accent: one per claw)
    pr2 = [(-0.022, 0.036), (-0.085, 0.053), (-0.118, 0.050), (-0.112, 0.038), (-0.080, 0.040), (-0.030, 0.026)]
    pr2 = [(z + pz, y + py) for z, y in pr2]
    obs.append(slab(name + "_plate", "GunPaint", pr2, -0.0105, 0.0105, node=node, bevel=0.002))
    # a hardened tip
    tip = [(-0.165, 0.010), (-0.186, -0.016), (-0.172, -0.012), (-0.158, 0.000)]
    tip = [(z + pz, y + py) for z, y in tip]
    obs.append(slab(name + "_tip", "Chrome", tip, -0.0095, 0.0095, node=node, bevel=0.0015))
    # the hinge knuckle and its pin
    obs.append(cyl(name + "_knuckle", "Chrome", (-0.016, py, pz), (0.016, py, pz), 0.012, segs=10, node=node))
    obs.append(cyl(name + "_pin", "Dark", (-0.02, py, pz), (0.02, py, pz), 0.005, segs=6, node=node))
    # its actuator: a small ram from behind the hinge onto the blade
    obs.append(cyl(name + "_ram", "Dark", (0, py + 0.020, pz + 0.004), (0, py + 0.034, pz - 0.050), 0.0065, segs=8, node=node))
    obs.append(cyl(name + "_rod", "Chrome", (0, py + 0.034, pz - 0.050), (0, py + 0.040, pz - 0.068), 0.0038, segs=6, node=node))
    a = math.radians(angle_deg - 90.0)
    R = Matrix.Translation((0, GG_Y, 0)) @ Matrix.Rotation(a, 4, "Z") @ Matrix.Translation((0, -GG_Y, 0))
    rotate_objs(obs, R)
    pivot = R @ Vector((0, py, pz))
    return {"name": name, "mount": name + "Mount", "pivot": list(pivot), "roll": a}


def gravity_gun():
    reset()
    Y = GG_Y
    # ── receiver: a graphite block, its silhouette raked at both ends
    prof = [(0.120, 0.098), (-0.070, 0.098), (-0.092, 0.080), (-0.096, 0.012), (-0.060, -0.004), (0.020, -0.004),
            (0.105, 0.000), (0.128, 0.030), (0.130, 0.080)]
    slab("rcv", "GunBody", prof, -0.047, 0.047, bevel=0.006, segs=2)
    # recessed top spine with three bolts
    box("spine", "Dark", (0, 0.101, 0.010), (0.056, 0.010, 0.17), bevel=0.002)
    for k, z in enumerate((-0.06, 0.01, 0.08)):
        bolt(f"spine_b{k}", (0.0, 0.106, z), (0, 1, 0))
    # ── the left side plate: enamel, worn at the edges, the tool's name on it
    lp = [(0.112, 0.088), (-0.062, 0.088), (-0.080, 0.070), (-0.082, 0.020), (-0.050, 0.008), (0.098, 0.012), (0.116, 0.040)]
    slab("lplate", "Enamel", lp, -0.0545, -0.0475, bevel=0.0025, segs=1)
    decal("lp_name", "gm3", (-0.0548, 0.060, 0.030), (-1, 0, 0), (0, 1, 0), 0.080, 0.025)
    decal("lp_sub", "gm3_name", (-0.0548, 0.034, 0.030), (-1, 0, 0), (0, 1, 0), 0.115, 0.009)
    decal("lp_emb", "emblem", (-0.0548, 0.066, -0.046), (-1, 0, 0), (0, 1, 0), 0.026, 0.026)
    decal("lp_ser", "serial_a", (-0.0548, 0.019, 0.050), (-1, 0, 0), (0, 1, 0), 0.06, 0.0075)
    for k, (z, y) in enumerate(((0.104, 0.080), (0.104, 0.022), (-0.070, 0.078), (-0.072, 0.024))):
        bolt(f"lp_b{k}", (-0.0545, y, z), (-1, 0, 0), r=0.0038)
    # ── the right side: an open vent and the field gauge
    for k in range(6):
        box(f"vent{k}", "Dark", (0.0485, 0.030 + k * 0.0095, 0.040), (0.006, 0.0045, 0.075), bevel=0.001)
    box("vent_frame", "GunBody", (0.0475, 0.054, 0.040), (0.004, 0.068, 0.090), bevel=0.0015)
    box("gauge", "GunBody", (0.052, 0.062, -0.050), (0.012, 0.034, 0.050), bevel=0.003)
    box("gauge_win", "GlowAmber", (0.0585, 0.064, -0.050), (0.002, 0.012, 0.034))
    decal("gauge_lbl", "charge", (0.0582, 0.046, -0.050), (1, 0, 0), (0, 1, 0), 0.044, 0.0055)
    # ── two capacitors along the top, in clamps; orange caps (the accent)
    for s in (-1, 1):
        x = s * 0.034
        cyl(f"cap{s}", "Anodised", (x, 0.117, 0.055), (x, 0.117, -0.080), 0.0135, segs=14, bevel=0.002)
        cyl(f"capend{s}", "GunPaint", (x, 0.117, -0.080), (x, 0.117, -0.090), 0.0115, segs=14, bevel=0.0015)
        ring_z(f"capband{s}", "Chrome", 0.040, 0.0130, 0.0150, 0.006, x=x, y=0.117, segs=14)
        for z in (-0.050, 0.020):
            box(f"capclamp{s}{z}", "Dark", (x, 0.110, z), (0.032, 0.012, 0.010), bevel=0.002)
    # ── the power cell, slung low behind the grip
    cz0, cz1, cy, cr = 0.120, 0.250, 0.022, 0.041
    cyl("cell", "Anodised", (0, cy, cz0), (0, cy, cz1), cr, segs=20, bevel=0.003)
    band("cell_band", 0.170, cr + 0.0006, 0.016, segs=20, y=cy)
    for z in (0.140, 0.222):
        ring_z(f"cell_strap{z}", "Dark", z, cr - 0.002, cr + 0.004, 0.010, y=cy, segs=16)
    lathe("cell_cap", "GunBody", [(0.0, cz1 + 0.012), (0.030, cz1 + 0.012), (0.036, cz1 + 0.006), (0.043, cz1)],
          segs=20, at=(0, cy, 0), bevel=0.0)
    for k in range(4):
        a = k * math.pi / 2 + math.pi / 4
        bolt(f"cell_b{k}", (0.031 * math.cos(a), cy + 0.031 * math.sin(a), cz1 + 0.0085), (0, 0, 1), r=0.0033)
    box("cell_latch", "GunPaint", (0, cy, cz1 + 0.016), (0.034, 0.008, 0.006), bevel=0.002)
    box("cell_win", "GlowAmber", (0.0, cy + cr + 0.0004, 0.195), (0.010, 0.002, 0.034))
    box("cell_winframe", "Dark", (0.0, cy + cr - 0.002, 0.195), (0.018, 0.006, 0.042), bevel=0.0015)
    decal("cell_ser", "serial_b", (-cr - 0.0004, cy, 0.198), (-1, 0, 0), (0, 1, 0), 0.042, 0.006)
    # ── the field-coil body: windings round a glowing core, a cage, a guard
    zc0, zc1 = -0.096, -0.205
    for z in (zc0 - 0.006, zc1 + 0.006):
        ring_z(f"flange{z}", "GunBody", z, 0.018, 0.063, 0.013, y=Y, segs=18)
    cyl("core", "GlowCore", (0, Y, zc0), (0, Y, zc1), 0.020, segs=12, caps=False)
    for k in range(4):
        torus_z(f"wind{k}", "Copper", -0.118 - k * 0.022, 0.032, 0.0105, y=Y, seg_major=12, seg_minor=5)
    for k, ang in enumerate((20, 60, 100, 340, 300)):
        a = math.radians(ang)
        box(f"cage{k}", "GunBody", (0.056 * math.cos(a), Y + 0.056 * math.sin(a), (zc0 + zc1) / 2),
            (0.008, 0.008, zc0 - zc1 + 0.004), M=Matrix.Rotation(a, 3, "Z"), bevel=0.0015)
    # the left guard: a curved enamel plate with a ribbed rubber pad
    lathe("guard", "Enamel", [(0.060, zc0 - 0.010), (0.066, zc0 - 0.010), (0.066, zc1 + 0.010), (0.060, zc1 + 0.010),
                              (0.060, zc0 - 0.010)], segs=10, at=(0, Y, 0), a0=math.radians(125), a1=math.radians(240),
          bevel=0.0015)
    for k in range(4):
        z = -0.118 - k * 0.022
        lathe(f"pad{k}", "Rubber", [(0.066, z + 0.006), (0.0715, z + 0.004), (0.0715, z - 0.004), (0.066, z - 0.006)],
              segs=8, at=(0, Y, 0), a0=math.radians(140), a1=math.radians(225))
    decal("guard_warn", "field_warn", (0.0, Y + 0.0635, -0.150), (0, 1, 0), (0, 0, -1), 0.040, 0.027)
    # the fore-grip under it, raked forward, ribbed
    cyl("fgrip", "Rubber", (0, Y - 0.058, -0.150), (0, Y - 0.140, -0.168), 0.0165, segs=12, bevel=0.002)
    for k in range(2):
        t = 0.35 + k * 0.3
        p = Vector((0, Y - 0.058, -0.150)).lerp(Vector((0, Y - 0.140, -0.168)), t)
        M, _ = orient((0, Y - 0.058, -0.150), (0, Y - 0.140, -0.168))
        cyl(f"fgrip_r{k}", "Rubber", p - (M.to_3x3() @ Vector((0, 0, 0.003))), p + (M.to_3x3() @ Vector((0, 0, 0.003))),
            0.0185, segs=12)
    box("fgrip_mount", "GunBody", (0, Y - 0.060, -0.150), (0.026, 0.016, 0.060), bevel=0.003)
    cyl("fgrip_cap", "Dark", (0, Y - 0.140, -0.168), (0, Y - 0.147, -0.170), 0.019, segs=12, bevel=0.002)
    # ── the emitter bell, the dish, the hinge brackets
    lathe("bell", "GunBody", [(0.060, -0.198), (0.066, -0.206), (0.077, -0.232), (0.079, -0.250), (0.074, -0.258),
                              (0.060, -0.258), (0.050, -0.250)], segs=20, at=(0, Y, 0), bevel=0.0)
    lathe("throat", "Dark", [(0.052, -0.250), (0.040, -0.240), (0.030, -0.236)], segs=20, at=(0, Y, 0))
    lathe("dish", "GlowCore", [(0.030, -0.236), (0.022, -0.242), (0.012, -0.250), (0.0, -0.254)], segs=16, at=(0, Y, 0))
    ring_z("bell_rim", "Chrome", -0.256, 0.068, 0.0775, 0.006, y=Y, segs=20)
    decal("bell_arrow", "arrow", (0.0, Y + 0.0745, -0.226), (0, 0.95, -0.3), (0, 0.3, 0.95), 0.016, 0.008)
    for name, ang in GG_CLAWS:
        a = math.radians(ang)
        c, s = math.cos(a), math.sin(a)
        Rz = Matrix.Rotation(a - math.pi / 2, 3, "Z")
        for side in (-1, 1):
            box(f"brk_{name}{side}", "Dark",
                (GG_CLAW_R * c + Rz[0][0] * side * 0.021, Y + GG_CLAW_R * s + Rz[1][0] * side * 0.021, GG_CLAW_Z + 0.006),
                (0.006, 0.026, 0.030), M=Rz, bevel=0.0015)
    # a hydraulic damper under the receiver to the bell
    cyl("damp", "Dark", (0, 0.004, -0.070), (0, Y - 0.052, -0.205), 0.008, segs=10)
    cyl("damp_rod", "Chrome", (0, Y - 0.046, -0.180), (0, Y - 0.058, -0.214), 0.0045, segs=8)
    # ── hoses from the cell
    hose("hose_l", "Rubber", [(-0.026, cy + 0.032, 0.150), (-0.058, 0.090, 0.090), (-0.066, 0.092, -0.010),
                              (-0.060, Y + 0.040, -0.090)], 0.0075)
    hose("hose_r", "Rubber", [(0.030, cy + 0.010, 0.140), (0.060, 0.008, 0.070), (0.062, 0.016, -0.040),
                              (0.044, Y - 0.020, -0.095)], 0.0068)
    # ── the grip, its guard and trigger
    gp = [(0.004, 0.0), (0.078, 0.0), (0.090, -0.040), (0.104, -0.098), (0.108, -0.122), (0.064, -0.130),
          (0.054, -0.108), (0.044, -0.096), (0.046, -0.080), (0.036, -0.066), (0.036, -0.050), (0.024, -0.034),
          (0.018, -0.018)]
    slab("grip", "Rubber", gp, -0.0205, 0.0205, bevel=0.006, segs=1)
    slab("grip_cap", "Dark", [(0.064, -0.124), (0.108, -0.116), (0.110, -0.132), (0.062, -0.138)], -0.022, 0.022,
         bevel=0.002)
    guard = [(0.002, -0.004), (-0.028, -0.004), (-0.036, -0.016), (-0.030, -0.050), (0.018, -0.060), (0.034, -0.056),
             (0.032, -0.050), (0.016, -0.052), (-0.022, -0.044), (-0.026, -0.016), (-0.020, -0.010), (0.002, -0.010)]
    slab("tguard", "Dark", guard, -0.0055, 0.0055, bevel=0.0015)
    slab("trigger", "Chrome", [(0.006, -0.004), (-0.002, -0.004), (-0.010, -0.024), (-0.006, -0.036), (0.000, -0.034),
                               (0.004, -0.020)], -0.004, 0.004, bevel=0.0012)
    claws = [gg_claw(n, a) for n, a in GG_CLAWS]
    anchors = {
        "grip": [0.0, -0.040, 0.050],
        "muzzle": [0.0, Y, -0.330],
        "fore": [0.0, Y - 0.100, -0.159],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0}]
    for c in claws:
        nodes.append({"name": c["mount"], "parent": "Body", "t": c["pivot"], "roll": c["roll"]})
        nodes.append({"name": c["name"], "parent": c["mount"], "t": [0, 0, 0], "roll": 0.0})
    return export(), anchors, nodes


# ── the TERRAIN LASER: a mining and cutting tool ───────────────────────────
#
# A skeletal stock holding the power cell, an enamel receiver with the fill
# canister on its left and the coolant coupling on its right, a rangefinder
# on the rail, a rubber hand-guard round the barrel, then the finned heat
# sink (its core glows with the laser's heat), the focusing optics with an
# orange knurled focus ring (spins with the beam) and the lens.

TL_Y = 0.05


def terrain_laser():
    reset()
    Y = TL_Y
    # ── receiver
    prof = [(0.175, 0.098), (-0.105, 0.098), (-0.128, 0.084), (-0.130, 0.012), (-0.100, -0.004), (0.050, -0.004),
            (0.140, 0.000), (0.175, 0.020)]
    slab("rcv", "Enamel", prof, -0.044, 0.044, bevel=0.005, segs=2)
    # panel break: a dark band across the receiver's waist
    box("waist", "Dark", (0.0, 0.050, 0.020), (0.0905, 0.090, 0.008))
    decal("rcv_name", "tl7", (-0.0446, 0.068, 0.090), (-1, 0, 0), (0, 1, 0), 0.075, 0.023)
    decal("rcv_sub", "tl7_name", (-0.0446, 0.042, 0.090), (-1, 0, 0), (0, 1, 0), 0.105, 0.0082)
    decal("rcv_emb", "emblem", (-0.0446, 0.070, -0.065), (-1, 0, 0), (0, 1, 0), 0.024, 0.024)
    decal("rcv_warn", "laser_warn", (0.0446, 0.058, -0.060), (1, 0, 0), (0, 1, 0), 0.045, 0.030)
    decal("rcv_ser", "serial_b", (0.0446, 0.020, 0.120), (1, 0, 0), (0, 1, 0), 0.060, 0.0075)
    for s in (-1, 1):
        for k, (z, y) in enumerate(((0.160, 0.085), (0.160, 0.012), (-0.112, 0.082), (-0.112, 0.016))):
            bolt(f"rcv_b{s}{k}", (s * 0.0445, y, z), (s, 0, 0), r=0.0035)
    # the rail, and the rangefinder on it with its readout facing the user
    box("rail", "Dark", (0.0, 0.103, 0.010), (0.032, 0.012, 0.230), bevel=0.0015)
    for k in range(8):
        box(f"rail_s{k}", "GunBody", (0.0, 0.1095, -0.090 + k * 0.026), (0.034, 0.004, 0.012))
    box("rf", "GunBody", (0.0, 0.130, 0.010), (0.034, 0.032, 0.076), bevel=0.004, segs=2)
    cyl("rf_lens", "Lens", (0.0, 0.132, -0.027), (0.0, 0.132, -0.0285), 0.011, segs=12)
    ring_z("rf_hood", "Dark", -0.033, 0.011, 0.0145, 0.012, y=0.132, segs=12)
    box("rf_screen", "GlowAmber", (0.0, 0.133, 0.0485), (0.020, 0.010, 0.002))
    box("rf_bezel", "Dark", (0.0, 0.133, 0.0475), (0.027, 0.017, 0.002))
    # ── the fill canister on the left, its clamps and window
    fx, fy = -0.072, 0.056
    cyl("fill", "Hazard", (fx, fy, -0.040), (fx, fy, 0.120), 0.027, segs=16, bevel=0.002)
    for z in (-0.020, 0.100):
        ring_z(f"fill_clamp{z}", "Dark", z, 0.026, 0.031, 0.012, x=fx, y=fy, segs=16)
        box(f"fill_arm{z}", "Dark", (-0.050, fy, z), (0.016, 0.014, 0.012), bevel=0.002)
    lathe("fill_end", "GunBody", [(0.0, -0.052), (0.020, -0.052), (0.027, -0.044), (0.027, -0.040)], segs=16,
          at=(fx, fy, 0))
    box("fill_win", "GlowAmber", (fx - 0.0262, fy, 0.040), (0.002, 0.005, 0.044))
    decal("fill_lbl", "fill", (fx, fy + 0.0275, 0.040), (0, 1, 0), (0, 0, -1), 0.042, 0.011)
    # ── the coolant coupling on the right
    box("coupling", "GunBody", (0.052, 0.040, 0.060), (0.020, 0.044, 0.090), bevel=0.004)
    cyl("coup_port", "Chrome", (0.062, 0.050, 0.030), (0.072, 0.050, 0.030), 0.009, segs=10)
    cyl("coup_port2", "Chrome", (0.062, 0.030, 0.030), (0.072, 0.030, 0.030), 0.009, segs=10)
    # ── the stock: two anodised rods, the cell between them, a rubber butt
    cyl("stock_top", "Anodised", (0, 0.084, 0.170), (0, 0.074, 0.312), 0.010, segs=10)
    cyl("stock_bot", "Anodised", (0, -0.002, 0.150), (0, -0.026, 0.312), 0.010, segs=10)
    slab("butt", "Rubber", [(0.302, 0.090), (0.326, 0.088), (0.330, 0.030), (0.326, -0.046), (0.302, -0.048)],
         -0.026, 0.026, bevel=0.006, segs=2)
    box("butt_plate", "GunBody", (0, 0.020, 0.298), (0.044, 0.120, 0.010), bevel=0.003)
    ccz0, ccz1, ccy, ccr = 0.180, 0.290, 0.030, 0.031
    cyl("cell", "Anodised", (0, ccy, ccz0), (0, ccy, ccz1), ccr, segs=18, bevel=0.002)
    band("cell_band", 0.225, ccr + 0.0006, 0.014, segs=18, y=ccy)
    for z in (0.192, 0.278):
        ring_z(f"cell_strap{z}", "Dark", z, ccr - 0.002, ccr + 0.004, 0.009, y=ccy, segs=14)
    box("cell_latch", "GunPaint", (0, ccy + ccr + 0.003, 0.252), (0.014, 0.006, 0.020), bevel=0.0015)
    box("cell_win", "GlowAmber", (ccr + 0.0004, ccy, 0.236), (0.002, 0.008, 0.026))
    decal("cell_ser", "charge", (-ccr - 0.0005, ccy, 0.240), (-1, 0, 0), (0, 1, 0), 0.040, 0.005)
    # ── the hand-guard round the barrel: rubber over a dark sleeve, ribbed
    cyl("guard", "Rubber", (0, Y, -0.128), (0, Y, -0.252), 0.040, segs=18, bevel=0.003)
    for k in range(5):
        ring_z(f"guard_r{k}", "Rubber", -0.144 - k * 0.022, 0.039, 0.0435, 0.006, y=Y, segs=14)
    ring_z("guard_end", "GunBody", -0.256, 0.020, 0.046, 0.010, y=Y, segs=18)
    # the fore-grip under it (the other hand's hold in third person)
    cyl("fgrip", "Rubber", (0, Y - 0.030, -0.188), (0, Y - 0.118, -0.204), 0.0155, segs=12, bevel=0.002)
    cyl("fgrip_cap", "Dark", (0, Y - 0.118, -0.204), (0, Y - 0.125, -0.206), 0.018, segs=12)
    # ── the barrel and the heat sink: fins round a core that glows with heat
    cyl("barrel", "Dark", (0, Y, -0.250), (0, Y, -0.430), 0.021, segs=12)
    hz0, hz1 = -0.262, -0.414
    box("hs_core", "HeatGlow", (0, Y + 0.022, (hz0 + hz1) / 2), (0.040, 0.050, hz0 - hz1 - 0.004))
    nf = 11
    fin = [(-0.056, -0.010), (-0.056, 0.060), (-0.044, 0.078), (0.044, 0.078), (0.056, 0.060), (0.056, -0.010),
           (0.026, -0.010), (0.026, 0.008), (-0.026, 0.008), (-0.026, -0.010)]
    fin = [(x, y + Y) for x, y in fin]
    for k in range(nf):
        z = hz0 - 0.006 - k * (hz0 - hz1 - 0.012) / (nf - 1)
        slab(f"fin{k}", "HeatGlow", fin, z - 0.0022, z + 0.0022, plane="xy")
    for s in (-1, 1):
        box(f"hs_rail{s}", "Dark", (s * 0.052, Y + 0.068, (hz0 + hz1) / 2), (0.008, 0.010, hz0 - hz1 + 0.010),
            bevel=0.0015)
        box(f"hs_skid{s}", "Dark", (s * 0.044, Y - 0.006, (hz0 + hz1) / 2), (0.020, 0.008, hz0 - hz1 + 0.010),
            bevel=0.0015)
    decal("hs_hot2", "hot", (0.0565, Y + 0.030, (hz0 + hz1) / 2), (1, 0, 0), (0, 1, 0), 0.050, 0.0125)
    # ── the optics: a stepped housing, the focus ring, the lens and its iris
    lathe("optics", "GunBody", [(0.020, -0.414), (0.044, -0.414), (0.050, -0.420), (0.050, -0.462), (0.040, -0.468),
                                (0.040, -0.500), (0.048, -0.505), (0.048, -0.536), (0.042, -0.541), (0.042, -0.552),
                                (0.033, -0.552), (0.029, -0.546)], segs=20, at=(0, Y, 0))
    lathe("lens_cup", "Dark", [(0.029, -0.546), (0.027, -0.542), (0.0, -0.542)], segs=16, at=(0, Y, 0))
    lathe("iris", "GlowAmber", [(0.0, -0.5435), (0.011, -0.5435), (0.0115, -0.5425)], segs=12, at=(0, Y, 0))
    cyl("lens", "Lens", (0, Y, -0.5455), (0, Y, -0.5465), 0.027, segs=16)
    ring_z("opt_ring", "Chrome", -0.520, 0.046, 0.0495, 0.004, y=Y, segs=20)
    # the focusing crown: three vanes reaching past the lens, angled in,
    # each with a small mirror pad at its tip
    for k in range(3):
        a = math.pi / 2 + k * 2 * math.pi / 3 + math.pi / 3
        R = Matrix.Translation((0, Y, 0)) @ Matrix.Rotation(a - math.pi / 2, 4, "Z")
        vane = slab(f"vane{k}", "Dark", [(-0.536, 0.034), (-0.536, 0.046), (-0.566, 0.040), (-0.584, 0.030),
                                         (-0.584, 0.024), (-0.556, 0.030)], -0.004, 0.004, bevel=0.001)
        pad = box(f"vane_pad{k}", "Chrome", (0, 0.027, -0.580), (0.0085, 0.004, 0.008))
        rotate_objs([vane, pad], R)
    # the knurled focus ring: an orange band with raised grip bars (its own node)
    focus_obs = [lathe("focus", "GunPaint", [(0.040, -0.470), (0.047, -0.472), (0.047, -0.497), (0.040, -0.499)],
                       segs=24, at=(0, Y, 0), node="Focus")]
    for k in range(12):
        a = 2 * math.pi * k / 12
        focus_obs.append(box(f"knurl{k}", "Dark", (0.048 * math.cos(a), Y + 0.048 * math.sin(a), -0.4845),
                             (0.004, 0.005, 0.020), M=Matrix.Rotation(a, 3, "Z"), node="Focus"))
    # ── coolant hoses from the coupling to the heat sink; a cable to the optics
    hose("hose_a", "Rubber", [(0.072, 0.050, 0.030), (0.080, 0.070, -0.060), (0.066, 0.096, -0.200),
                              (0.050, Y + 0.068, -0.268)], 0.0068)
    hose("hose_b", "Rubber", [(0.072, 0.030, 0.030), (0.074, 0.016, -0.080), (0.060, 0.020, -0.200),
                              (0.044, Y - 0.006, -0.268)], 0.0062)
    hose("cable", "Dark", [(-0.040, 0.090, -0.110), (-0.052, 0.104, -0.200), (-0.058, 0.092, -0.380),
                           (-0.046, Y + 0.020, -0.440)], 0.003, sides=4)
    # ── the grip, its guard and trigger (the gravity gun's, 3 cm further back)
    dz = 0.030
    gp = [(0.004, 0.0), (0.078, 0.0), (0.090, -0.040), (0.104, -0.098), (0.108, -0.122), (0.064, -0.130),
          (0.054, -0.108), (0.044, -0.096), (0.046, -0.080), (0.036, -0.066), (0.036, -0.050), (0.024, -0.034),
          (0.018, -0.018)]
    slab("grip", "Rubber", [(z + dz, y) for z, y in gp], -0.0205, 0.0205, bevel=0.006, segs=1)
    slab("grip_cap", "Dark", [(0.064 + dz, -0.124), (0.108 + dz, -0.116), (0.110 + dz, -0.132), (0.062 + dz, -0.138)],
         -0.022, 0.022, bevel=0.002)
    guard = [(0.002, -0.004), (-0.028, -0.004), (-0.036, -0.016), (-0.030, -0.050), (0.018, -0.060), (0.034, -0.056),
             (0.032, -0.050), (0.016, -0.052), (-0.022, -0.044), (-0.026, -0.016), (-0.020, -0.010), (0.002, -0.010)]
    slab("tguard", "Dark", [(z + dz, y) for z, y in guard], -0.0055, 0.0055, bevel=0.0015)
    slab("trigger", "Chrome", [(0.006 + dz, -0.004), (-0.002 + dz, -0.004), (-0.010 + dz, -0.024),
                               (-0.006 + dz, -0.036), (0.000 + dz, -0.034), (0.004 + dz, -0.020)], -0.004, 0.004,
         bevel=0.0012)
    anchors = {
        "grip": [0.0, -0.035, 0.080],
        "muzzle": [0.0, Y, -0.560],
        "fore": [0.0, Y - 0.074, -0.196],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0},
             {"name": "Focus", "parent": "Body", "t": [0, Y, 0], "roll": 0.0}]
    return export(), anchors, nodes


# ── export: triangles per (node, material) ─────────────────────────────────

def export():
    dg = bpy.context.evaluated_depsgraph_get()
    out = {}
    for ob, node, is_decal in OBJS:
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        Mw = ob.matrix_world
        Mn = Mw.to_3x3().inverted().transposed()
        flip = Mw.to_3x3().determinant() < 0
        cn = me.corner_normals
        uvl = me.uv_layers.get("decal") if is_decal else None
        slots = [m.name if m else "Dark" for m in me.materials] or ["Dark"]
        for tri in me.loop_triangles:
            mname = slots[min(tri.material_index, len(slots) - 1)]
            e = out.setdefault(node, {}).setdefault(mname, {"P": [], "N": [], "UV": []})
            loops = list(tri.loops)
            if flip:
                loops = loops[::-1]
            P = [Mw @ me.vertices[me.loops[li].vertex_index].co for li in loops]
            N = [(Mn @ Vector(cn[li].vector)).normalized() for li in loops]
            if uvl is not None:
                UV = [tuple(uvl.data[li].uv) for li in loops]
                UV = [(u, 1.0 - v) for u, v in UV]          # glTF: v down
            else:
                fn = (P[1] - P[0]).cross(P[2] - P[0])
                ax = max(range(3), key=lambda i: abs(fn[i]))
                ua, va = [(1, 2), (0, 2), (0, 1)][ax]
                UV = [(p[ua] * UV_M, -p[va] * UV_M) for p in P]
            for p in P:
                e["P"] += [round(p.x, 6), round(p.y, 6), round(p.z, 6)]
            for n in N:
                e["N"] += [round(n.x, 5), round(n.y, 5), round(n.z, 5)]
            for u, v in UV:
                e["UV"] += [round(u, 5), round(v, 5)]
        if PER_OBJ:
            PER_OBJ.append((len(me.loop_triangles), ob.name))
        ev.to_mesh_clear()
    if PER_OBJ:
        tops = sorted(PER_OBJ[1:], reverse=True)[:200]
        print("TOOLS heaviest:", ", ".join(f"{n} {t}" for t, n in tops))
        del PER_OBJ[1:]
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    path = argv[0] if argv else "/tmp/tools_mesh.json"
    res = {}
    for name, fn in (("gravgun", gravity_gun), ("laser", terrain_laser)):
        geo, anchors, nodes = fn()
        tris = sum(len(m["P"]) // 9 for n in geo.values() for m in n.values())
        res[name] = {"geo": geo, "anchors": anchors, "nodes": nodes}
        print(f"TOOLS {name}: {tris} tris, nodes {list(geo.keys())}")
    with open(path, "w") as f:
        json.dump(res, f)
    print("TOOLS wrote", path)


main()
