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
  laser        Focus, the knurled focusing ring (or the emitter crown), spun
               round the barrel axis.

The terrain laser comes in VARIANTS (LASERS below): C (the TL-3 Plasma Bore)
is the tool in the game; TL7 (the old TL-7), A and B are kept, built only
when asked for (`-- OUT.json TL7,A,B,C`). B is also the crew's plasma rifle,
the TL-5 SURVEYOR (res["surveyor"], always built: laser_B(rifle=True)).

ENERGY PARTS carry a uv of their own instead of a texture map (UVMODE, set by
uvmode()): the tool_* shaders (shaders/tool_*.flsl) read uv.y as distance
along the flow in metres and uv.x as the way round the axis (see custom_uv).
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
    "tl9":        (0, 432, 170,  80),
    "tl5":        (170, 432, 171, 80),
    "tl3":        (341, 432, 171, 80),
    "tl5_name":   (0, 320, 128,  16),
}
ATLAS = 512.0

OBJS = []           # (object, node, decal?)
PER_OBJ = [True] if "--count" in sys.argv else []
UVMODE = {}         # object name -> (kind, cx, cy, r0): an energy part's own uv (custom_uv)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    OBJS.clear()
    UVMODE.clear()


def uvmode(ob, kind, cx=0.0, cy=0.0, r0=0.0):
    """Give an object the uv its tool_* shader reads instead of a texture map
    (custom_uv). Axis-relative kinds turn about an axis along Z through
    (cx, cy)."""
    UVMODE[ob.name] = (kind, cx, cy, r0)
    return ob


def custom_uv(mode, p):
    """uv.y = distance ALONG the flow (m), uv.x = the way round (0..1, the
    seam underneath, where it is least seen):
      axial      along the axis toward the muzzle (-Z)
      axial_rev  along the axis toward the stock (a return line)
      radial     uv.x = metres OUT from radius r0 (a heat sink's hot root)
      dish       uv.y = metres out from the axis (a dish, a crown)
      around     uv.y = metres round a ring of radius r0"""
    kind, cx, cy, r0 = mode
    dx, dy = p.x - cx, p.y - cy
    ang = math.atan2(dx, dy) / (2 * math.pi) + 0.5
    r = math.hypot(dx, dy)
    if kind == "axial":
        return ang, -p.z
    if kind == "axial_rev":
        return ang, p.z
    if kind == "radial":
        return max(0.0, r - r0), -p.z
    if kind == "dish":
        return ang, r
    if kind == "around":
        return ang, ang * 2 * math.pi * r0
    raise ValueError(kind)


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


def hose(name, mat_, pts, r, node="Body", res=2, sides=6):
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


def screen(name, mat_, center, normal, up, w, h, node="Body"):
    """A readout window: a quad a hair off the surface with its own 0..1 uv
    (uv.x along `right` = up x normal, uv.y up), for tool_gauge."""
    n = Vector(normal).normalized()
    u = Vector(up).normalized()
    rgt = u.cross(n).normalized()
    c = Vector(center) + n * 0.0007
    bm = bmesh.new()
    vs = [bm.verts.new(c + rgt * (sx * w / 2) + u * (sy * h / 2)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.dot(n) < 0:
        f.normal_flip()
    uvl = bm.loops.layers.uv.new("decal")
    for lp in f.loops:
        q = lp.vert.co - c
        lp[uvl].uv = (q.dot(rgt) / w + 0.5, 1.0 - (q.dot(u) / h + 0.5))
    return finish(bm, name, mat_, node, decal=True, smooth=False)


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


# ── shared pieces: the family's energy cell, grip and focus ring ──────────

def energy_cell(name, x, y, z0, z1, r, g0, g1, segs=20, bars=6, rod=None, node="Body", rodmat="Energy",
                glassmat="EnergyGlass"):
    """A power cell along Z (axis at x, y) from z0 to z1, radius r: anodised
    ends, and between g0 and g1 a glass sleeve (EnergyGlass) over a glowing
    rod (Energy, its bands running toward the muzzle, -Z) behind
    a grille of `bars` bars, with dark straps over the joins. The cell the
    whole family shares: the gravity gun's is blue, a laser's amber."""
    rod = rod or r * 0.6
    cyl(name + "_rear", "Anodised", (x, y, g1), (x, y, z1), r, segs=segs)
    cyl(name + "_front", "Anodised", (x, y, z0), (x, y, g0), r, segs=segs)
    uvmode(cyl(name + "_glass", glassmat, (x, y, g0), (x, y, g1), r - 0.002, segs=segs, caps=False), "axial", x, y)
    uvmode(cyl(name + "_rod", rodmat, (x, y, g0), (x, y, g1), rod, segs=max(8, segs // 2), caps=False), "axial", x, y)
    # the rod's seats: dark discs inside each end, so the glass shows depth
    for k, z in enumerate((g0, g1)):
        zz = z + (0.002 if k == 0 else -0.002)
        lathe(f"{name}_seat{k}", "Dark", [(rod, zz), (r - 0.002, zz)], at=(x, y, 0), segs=max(8, segs // 2))
    for k in range(bars):
        a = 2 * math.pi * (k + 0.5) / bars
        box(f"{name}_bar{k}", "Dark", (x + (r - 0.0005) * math.cos(a), y + (r - 0.0005) * math.sin(a), (g0 + g1) / 2),
            (0.0045, 0.0045, g1 - g0 + 0.002), M=Matrix.Rotation(a, 3, "Z"))
    for k, z in enumerate((g0, g1)):
        ring_z(f"{name}_strap{k}", "Dark", z, r - 0.002, r + 0.0035, 0.008, x=x, y=y, segs=max(10, segs - 6))


def pistol_grip(dz):
    """The family's pistol grip, guard and trigger (the gravity gun's, moved
    dz along Z)."""
    gp = [(0.004, 0.0), (0.078, 0.0), (0.090, -0.040), (0.104, -0.098), (0.108, -0.122), (0.064, -0.130),
          (0.054, -0.108), (0.044, -0.096), (0.046, -0.080), (0.036, -0.066), (0.036, -0.050), (0.024, -0.034),
          (0.018, -0.018)]
    slab("grip", "Rubber", [(z + dz, y) for z, y in gp], -0.0205, 0.0205, bevel=0.006, segs=1)
    slab("grip_cap", "Dark", [(0.064 + dz, -0.124), (0.108 + dz, -0.116), (0.110 + dz, -0.132), (0.062 + dz, -0.138)],
         -0.022, 0.022, bevel=0.002)
    guard = [(0.002, -0.004), (-0.028, -0.004), (-0.036, -0.016), (-0.030, -0.050), (0.018, -0.060), (0.034, -0.056),
             (0.032, -0.050), (0.016, -0.052), (-0.022, -0.044), (-0.026, -0.016), (-0.020, -0.010), (0.002, -0.010)]
    slab("tguard", "Dark", [(z + dz, y) for z, y in guard], -0.0055, 0.0055)
    slab("trigger", "Chrome", [(0.006 + dz, -0.004), (-0.002 + dz, -0.004), (-0.010 + dz, -0.024),
                               (-0.006 + dz, -0.036), (0.000 + dz, -0.034), (0.004 + dz, -0.020)], -0.004, 0.004,
         bevel=0.0012)


def fore_grip(Y, top, bot, r=0.0155):
    """A raked rubber fore-grip from `top` (y, z) down to `bot` (y, z) under
    the barrel axis at height Y: the other hand's hold."""
    cyl("fgrip", "Rubber", (0, Y + top[0], top[1]), (0, Y + bot[0], bot[1]), r, segs=12, bevel=0.002)
    cyl("fgrip_cap", "Dark", (0, Y + bot[0], bot[1]), (0, Y + bot[0] - 0.007, bot[1] - 0.002), r + 0.0025, segs=12)


def focus_ring(Y, z0, z1, r, knurls=12):
    """The orange knurled ring that spins with the beam: node Focus."""
    obs = [lathe("focus", "GunPaint", [(r - 0.007, z0), (r, z0 - 0.002), (r, z1 + 0.002), (r - 0.007, z1)],
                 segs=20, at=(0, Y, 0), node="Focus")]
    for k in range(knurls):
        a = 2 * math.pi * k / knurls
        obs.append(box(f"knurl{k}", "Dark", ((r + 0.001) * math.cos(a), Y + (r + 0.001) * math.sin(a), (z0 + z1) / 2),
                       (0.004, 0.005, abs(z1 - z0) - 0.008), M=Matrix.Rotation(a, 3, "Z"), node="Focus"))
    return obs


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
    # recessed top spine, a bolt at each end and the FIELD CHARGE strip
    # between them: a row of lamps the first-person view looks down on, filling
    # with the field (tool_gauge; tool_belt drives `charge`)
    box("spine", "Dark", (0, 0.101, 0.010), (0.056, 0.010, 0.17), bevel=0.002)
    for k, z in enumerate((-0.06, 0.08)):
        bolt(f"spine_b{k}", (0.0, 0.106, z), (0, 1, 0))
    box("strip_bezel", "GunBody", (0.0, 0.1068, 0.010), (0.018, 0.0016, 0.100))
    screen("strip", "Gauge", (0.0, 0.1076, 0.010), (0, 1, 0), (-1, 0, 0), 0.090, 0.011)
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
    # the field's glow behind the vent slats (the side a third-person view sees)
    uvmode(box("vent_glow", "EnergyBand", (0.0500, 0.054, 0.040), (0.001, 0.058, 0.072)), "axial", 0.0, Y)
    box("gauge", "GunBody", (0.052, 0.062, -0.050), (0.012, 0.034, 0.050), bevel=0.003)
    screen("gauge_win", "Gauge", (0.0580, 0.064, -0.050), (1, 0, 0), (0, 1, 0), 0.036, 0.012)
    decal("gauge_lbl", "charge", (0.0582, 0.046, -0.050), (1, 0, 0), (0, 1, 0), 0.044, 0.0055)
    # ── two capacitors along the top, in clamps; orange caps (the accent)
    for s in (-1, 1):
        x = s * 0.034
        cyl(f"cap{s}", "Anodised", (x, 0.117, 0.055), (x, 0.117, -0.080), 0.0135, segs=14, bevel=0.002)
        cyl(f"capend{s}", "GunPaint", (x, 0.117, -0.080), (x, 0.117, -0.090), 0.0115, segs=14, bevel=0.0015)
        # a lit band round each capacitor: it breathes with the field
        uvmode(ring_z(f"capband{s}", "EnergyBand", 0.040, 0.0130, 0.0150, 0.006, x=x, y=0.117, segs=14),
               "around", x, 0.117, 0.015)
        for z in (-0.050, 0.020):
            box(f"capclamp{s}{z}", "Dark", (x, 0.110, z), (0.032, 0.012, 0.010), bevel=0.002)
    # ── the power cell, slung low behind the grip: an ENERGY CELL, the glowing
    # core seen through a glass sleeve behind a grille, between anodised ends
    cz0, cz1, cy, cr = 0.120, 0.250, 0.022, 0.041
    energy_cell("cell", 0.0, cy, cz0, cz1, cr, 0.146, 0.216, segs=20, bars=6, rod=0.024)
    band("cell_band", 0.232, cr + 0.0006, 0.012, segs=20, y=cy)
    lathe("cell_cap", "GunBody", [(0.0, cz1 + 0.012), (0.030, cz1 + 0.012), (0.036, cz1 + 0.006), (0.043, cz1)],
          segs=20, at=(0, cy, 0), bevel=0.0)
    for k in range(4):
        a = k * math.pi / 2 + math.pi / 4
        bolt(f"cell_b{k}", (0.031 * math.cos(a), cy + 0.031 * math.sin(a), cz1 + 0.0085), (0, 0, 1), r=0.0033)
    box("cell_latch", "GunPaint", (0, cy, cz1 + 0.016), (0.034, 0.008, 0.006), bevel=0.002)
    decal("cell_ser", "serial_b", (-cr - 0.0004, cy, 0.134), (-1, 0, 0), (0, 1, 0), 0.024, 0.0036)
    # ── the field-coil body: windings round a glowing core, a cage, a guard
    zc0, zc1 = -0.096, -0.205
    for z in (zc0 - 0.006, zc1 + 0.006):
        ring_z(f"flange{z}", "GunBody", z, 0.018, 0.063, 0.013, y=Y, segs=18)
    # the field core: tool_energy, its bands running down toward the emitter,
    # glowing between the copper windings (spaced so it shows between them)
    uvmode(cyl("core", "Energy", (0, Y, zc0), (0, Y, zc1), 0.026, segs=14, caps=False), "axial", 0.0, Y)
    for k in range(4):
        torus_z(f"wind{k}", "Copper", -0.118 - k * 0.022, 0.034, 0.0078, y=Y, seg_major=12, seg_minor=5)
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
    # the emitter dish: rings drawn in toward its centre (EnergyDish)
    uvmode(lathe("dish", "EnergyDish", [(0.030, -0.236), (0.022, -0.242), (0.012, -0.250), (0.0, -0.254)], segs=16,
                 at=(0, Y, 0)), "dish", 0.0, Y)
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
    pistol_grip(0.0)
    claws = [gg_claw(n, a) for n, a in GG_CLAWS]
    anchors = {
        "grip": [0.0, -0.040, 0.050],
        "muzzle": [0.0, Y, -0.330],
        "fore": [0.0, Y - 0.100, -0.159],
        "vent": [0.0, Y + 0.064, -0.150],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0}]
    for c in claws:
        nodes.append({"name": c["mount"], "parent": "Body", "t": c["pivot"], "roll": c["roll"]})
        nodes.append({"name": c["name"], "parent": c["mount"], "t": [0, 0, 0], "roll": 0.0})
    return export(), anchors, nodes


# ── the TERRAIN LASERS: mining and cutting tools ───────────────────────────
#
# One family with the gravity gun: graphite and enamel, worn edges, stencils,
# the same pistol grip and energy cell, signal orange only on what moves.
#
#   TL7  the TL-7, the game's laser until design C was picked: a skeletal stock round its cell, an
#        enamel receiver, a rangefinder on the rail, a rubber hand-guard, then
#        a radial heat sink CONCENTRIC with the barrel (annular fins round a
#        core that glows from the root out with heat), the stepped optics, the
#        focus ring and a crown of focusing vanes.
#   A    TL-9 EXCAVATOR, a heavy mining cutter: a carry handle over a deep
#        receiver, twin cells on the stock, and an EXPOSED focusing chamber, a
#        hexagonal crystal in a cage between copper coils, ahead of a heavy
#        nozzle.
#   B    TL-5 SURVEYOR (also the crew's plasma rifle, scripts/surveyor.lua), a slim beam rifle: a survey scope, a long barrel in a
#        ventilated shroud and a glowing COOLANT LOOP: a reservoir under the
#        barrel feeding two lines up the sides to a ring at the muzzle; the
#        coolant warms from ice blue toward amber with heat.
#   C    TL-3 PLASMA BORE, THE LASER IN THE GAME, stubby: a hoop handle, a fat plasma drum seen
#        between ribs and copper magnet rings, and an EMITTER CROWN of six
#        electrodes that spins with the beam.
#
# Every variant keeps the grip where the TL-7 has it (pistol_grip(0.03)) and a
# fore-grip about where the TL-7's is, so the first-person hands and the
# third-person hold fit any of them.

TL_Y = 0.05
LASER_DZ = 0.030     # the laser's grip sits 3 cm further back than the gravity gun's


def laser_tl7():
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
    # the rail, and the rangefinder on it; its back is the HEAT readout,
    # facing the user (tool_gauge on `heat`)
    box("rail", "Dark", (0.0, 0.103, 0.010), (0.032, 0.012, 0.230), bevel=0.0015)
    for k in range(8):
        box(f"rail_s{k}", "GunBody", (0.0, 0.1095, -0.090 + k * 0.026), (0.034, 0.004, 0.012))
    box("rf", "GunBody", (0.0, 0.130, 0.010), (0.034, 0.032, 0.076), bevel=0.004, segs=2)
    cyl("rf_lens", "Lens", (0.0, 0.132, -0.027), (0.0, 0.132, -0.0285), 0.011, segs=12)
    ring_z("rf_hood", "Dark", -0.033, 0.011, 0.0145, 0.012, y=0.132, segs=12)
    box("rf_bezel", "Dark", (0.0, 0.133, 0.0475), (0.027, 0.017, 0.002))
    screen("rf_screen", "Gauge", (0.0, 0.133, 0.0485), (0, 0, 1), (0, 1, 0), 0.022, 0.010)
    # ── the fill canister on the left, its clamps and window
    fx, fy = -0.072, 0.056
    cyl("fill", "Hazard", (fx, fy, -0.040), (fx, fy, 0.120), 0.027, segs=16)
    lathe("fill_cap", "GunBody", [(0.027, 0.120), (0.027, 0.124), (0.020, 0.132), (0.0, 0.132)], segs=16,
          at=(fx, fy, 0))
    for z in (-0.020, 0.100):
        ring_z(f"fill_clamp{z}", "Dark", z, 0.026, 0.031, 0.012, x=fx, y=fy, segs=12)
        box(f"fill_arm{z}", "Dark", (-0.050, fy, z), (0.016, 0.014, 0.012), bevel=0.002)
    lathe("fill_end", "GunBody", [(0.0, -0.052), (0.020, -0.052), (0.027, -0.044), (0.027, -0.040)], segs=16,
          at=(fx, fy, 0))
    box("fill_win", "GlowAmber", (fx - 0.0262, fy, 0.040), (0.002, 0.005, 0.044))
    decal("fill_lbl", "fill", (fx, fy + 0.0275, 0.040), (0, 1, 0), (0, 0, -1), 0.042, 0.011)
    # ── the coolant coupling on the right
    box("coupling", "GunBody", (0.052, 0.040, 0.060), (0.020, 0.044, 0.090), bevel=0.004)
    cyl("coup_port", "Chrome", (0.062, 0.050, 0.030), (0.072, 0.050, 0.030), 0.009, segs=10)
    cyl("coup_port2", "Chrome", (0.062, 0.030, 0.030), (0.072, 0.030, 0.030), 0.009, segs=10)
    # ── the stock: two anodised rods, the energy cell between them, a rubber butt
    cyl("stock_top", "Anodised", (0, 0.084, 0.170), (0, 0.074, 0.312), 0.010, segs=10)
    cyl("stock_bot", "Anodised", (0, -0.002, 0.150), (0, -0.026, 0.312), 0.010, segs=10)
    slab("butt", "Rubber", [(0.302, 0.090), (0.326, 0.088), (0.330, 0.030), (0.326, -0.046), (0.302, -0.048)],
         -0.026, 0.026, bevel=0.006, segs=2)
    box("butt_plate", "GunBody", (0, 0.020, 0.298), (0.044, 0.120, 0.010), bevel=0.003)
    ccy, ccr = 0.030, 0.031
    energy_cell("cell", 0.0, ccy, 0.180, 0.290, ccr, 0.198, 0.272, segs=18, bars=6, rod=0.017)
    box("cell_latch", "GunPaint", (0, ccy + ccr + 0.003, 0.282), (0.014, 0.006, 0.012), bevel=0.0015)
    # ── the hand-guard round the barrel: rubber over a dark sleeve, ribbed
    cyl("guard", "Rubber", (0, Y, -0.128), (0, Y, -0.252), 0.040, segs=18)
    for k in range(5):
        ring_z(f"guard_r{k}", "Rubber", -0.144 - k * 0.022, 0.039, 0.0435, 0.006, y=Y, segs=12)
    ring_z("guard_end", "GunBody", -0.256, 0.020, 0.046, 0.010, y=Y, segs=18)
    fore_grip(Y, (-0.030, -0.188), (-0.118, -0.204))
    # ── the barrel and the RADIAL HEAT SINK, on the barrel's own axis: annular
    # fins round a sleeve that glows from the root out (tool_heat), held by
    # three tie rods between two collars. (It was a finned block sitting above
    # the axis, which read as a box stuck on the barrel.)
    cyl("barrel", "Dark", (0, Y, -0.250), (0, Y, -0.430), 0.021, segs=12)
    hz0, hz1, hr0, hr1 = -0.262, -0.414, 0.0245, 0.051
    uvmode(cyl("hs_core", "HeatGlow", (0, Y, hz0), (0, Y, hz1), hr0, segs=12, caps=False), "radial", 0.0, Y, hr0)
    nf = 8
    for k in range(nf):
        z = hz0 - 0.011 - k * (hz0 - hz1 - 0.022) / (nf - 1)
        uvmode(ring_z(f"fin{k}", "HeatGlow", z, hr0, hr1, 0.0048, y=Y, segs=12), "radial", 0.0, Y, hr0)
    for z in (hz0 - 0.002, hz1 + 0.002):
        ring_z(f"hs_collar{z}", "GunBody", z, 0.020, hr1 + 0.003, 0.010, y=Y, segs=14)
    band("hs_band", hz0 - 0.002, hr1 + 0.0036, 0.007, segs=14, y=Y)
    for k, ang in enumerate((30, 150, 270)):
        a = math.radians(ang)
        p = (0.0475 * math.cos(a), Y + 0.0475 * math.sin(a))
        cyl(f"hs_tie{k}", "Dark", (p[0], p[1], hz0), (p[0], p[1], hz1), 0.0032, segs=6)
    # ── the optics: a stepped housing, the focus ring, the lens and its emitter
    lathe("optics", "GunBody", [(0.020, -0.414), (0.044, -0.414), (0.050, -0.420), (0.050, -0.462), (0.040, -0.468),
                                (0.040, -0.500), (0.048, -0.505), (0.048, -0.536), (0.042, -0.541), (0.042, -0.552),
                                (0.033, -0.552), (0.029, -0.546)], segs=16, at=(0, Y, 0))
    lathe("lens_cup", "Dark", [(0.029, -0.546), (0.027, -0.542), (0.0, -0.542)], segs=16, at=(0, Y, 0))
    uvmode(lathe("iris", "Emitter", [(0.0, -0.5435), (0.011, -0.5435), (0.0115, -0.5425)], segs=12, at=(0, Y, 0)),
           "dish", 0.0, Y)
    cyl("lens", "EnergyGlass", (0, Y, -0.5455), (0, Y, -0.5465), 0.027, segs=12)
    ring_z("opt_ring", "Chrome", -0.520, 0.046, 0.0495, 0.004, y=Y, segs=16)
    # the focusing crown: three vanes reaching past the lens, angled in,
    # each with a small mirror pad at its tip
    for k in range(3):
        a = math.pi / 2 + k * 2 * math.pi / 3 + math.pi / 3
        R = Matrix.Translation((0, Y, 0)) @ Matrix.Rotation(a - math.pi / 2, 4, "Z")
        vane = slab(f"vane{k}", "Dark", [(-0.536, 0.034), (-0.536, 0.046), (-0.566, 0.040), (-0.584, 0.030),
                                         (-0.584, 0.024), (-0.556, 0.030)], -0.004, 0.004, bevel=0.001)
        pad = box(f"vane_pad{k}", "Chrome", (0, 0.027, -0.580), (0.0085, 0.004, 0.008))
        rotate_objs([vane, pad], R)
    focus_ring(Y, -0.470, -0.499, 0.047)
    # ── coolant hoses from the coupling to the sink's rear collar; a cable to the optics
    hose("hose_a", "Rubber", [(0.072, 0.050, 0.030), (0.080, 0.070, -0.060), (0.064, 0.090, -0.200),
                              (0.040, Y + 0.034, -0.256)], 0.0068)
    hose("hose_b", "Rubber", [(0.072, 0.030, 0.030), (0.074, 0.016, -0.080), (0.060, 0.016, -0.200),
                              (0.040, Y - 0.026, -0.256)], 0.0062)
    hose("cable", "Dark", [(-0.040, 0.090, -0.110), (-0.052, 0.104, -0.200), (-0.062, 0.096, -0.380),
                           (-0.046, Y + 0.020, -0.440)], 0.003, sides=4)
    pistol_grip(LASER_DZ)
    anchors = {
        "grip": [0.0, -0.035, 0.080],
        "muzzle": [0.0, Y, -0.560],
        "fore": [0.0, Y - 0.074, -0.196],
        "vent": [0.0, Y + hr1, -0.338],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0},
             {"name": "Focus", "parent": "Body", "t": [0, Y, 0], "roll": 0.0}]
    return export(), anchors, nodes


def receiver_plates(prof, x0, x1, name_cell, tag, ys=(0.064, 0.040), zs=(0.070, 0.070)):
    """Enamel side plates on both flanks: the stencilled name on the left,
    the laser placard on the right, and their bolts."""
    slab(tag + "_lp", "Enamel", prof, -x1, -x0, bevel=0.0025)
    slab(tag + "_rp", "Enamel", prof, x0, x1, bevel=0.0025)
    decal(tag + "_name", name_cell, (-x1 - 0.0003, ys[0], zs[0]), (-1, 0, 0), (0, 1, 0), 0.070, 0.022)
    decal(tag + "_sub", "tl7_name", (-x1 - 0.0003, ys[1], zs[1]), (-1, 0, 0), (0, 1, 0), 0.098, 0.0078)
    decal(tag + "_ser", "serial_b", (x1 + 0.0003, 0.020, 0.090), (1, 0, 0), (0, 1, 0), 0.056, 0.0070)
    zmin, zmax = min(p[0] for p in prof), max(p[0] for p in prof)
    for s in (-1, 1):
        for k, (z, y) in enumerate(((zmax - 0.012, 0.074), (zmin + 0.016, 0.074), (zmin + 0.016, 0.020))):
            bolt(f"{tag}_b{s}{k}", (s * (x1 + 0.0002), y, z), (s, 0, 0), r=0.0034)


def laser_A():
    """TL-9 EXCAVATOR: the heavy mining cutter with the exposed crystal."""
    reset()
    Y = TL_Y
    # ── a deep graphite receiver, enamel plates on both flanks
    prof = [(0.160, 0.112), (-0.098, 0.112), (-0.120, 0.096), (-0.124, 0.004), (-0.094, -0.010), (0.050, -0.010),
            (0.130, -0.004), (0.160, 0.030)]
    slab("rcv", "GunBody", prof, -0.050, 0.050, bevel=0.006, segs=2)
    plate = [(0.134, 0.100), (-0.086, 0.100), (-0.104, 0.084), (-0.106, 0.014), (-0.084, 0.002), (0.120, 0.006),
             (0.142, 0.040)]
    receiver_plates(plate, 0.050, 0.0565, "tl9", "pl", ys=(0.072, 0.046), zs=(0.050, 0.050))
    decal("pl_emb", "emblem", (-0.0569, 0.072, -0.066), (-1, 0, 0), (0, 1, 0), 0.026, 0.026)
    decal("pl_warn", "laser_warn", (0.0569, 0.060, -0.040), (1, 0, 0), (0, 1, 0), 0.050, 0.033)
    # ── the carry handle over it: two posts and a rubber bar; the rear post's
    # back is the HEAT readout, a vertical bar facing the user
    for k, z in enumerate((0.100, -0.072)):
        box(f"post{k}", "GunBody", (0.0, 0.140, z), (0.022, 0.058, 0.024), bevel=0.004)
        box(f"post_cap{k}", "GunPaint", (0.0, 0.1700, z), (0.026, 0.006, 0.028), bevel=0.002)
    cyl("handle", "Rubber", (0.0, 0.158, 0.088), (0.0, 0.158, -0.060), 0.0125, segs=10, bevel=0.002)
    for k in range(4):
        ring_z(f"handle_r{k}", "Rubber", 0.050 - k * 0.030, 0.012, 0.0145, 0.005, y=0.158, segs=10)
    screen("heat_bar", "Gauge", (0.0, 0.140, 0.1121), (0, 0, 1), (-1, 0, 0), 0.044, 0.012)
    # ── twin energy cells along the stock block, a rubber butt
    slab("pack", "GunBody", [(0.300, 0.104), (0.150, 0.104), (0.150, -0.004), (0.300, -0.034)], -0.044, 0.044,
         bevel=0.005, segs=2)
    slab("butt", "Rubber", [(0.300, 0.108), (0.326, 0.104), (0.330, 0.030), (0.326, -0.040), (0.300, -0.040)],
         -0.030, 0.030, bevel=0.006, segs=2)
    for s in (-1, 1):
        energy_cell(f"cell{s}", s * 0.024, 0.124, 0.168, 0.292, 0.019, 0.186, 0.270, segs=12, bars=4, rod=0.010)
    box("cell_clamp", "Dark", (0.0, 0.112, 0.230), (0.092, 0.012, 0.016), bevel=0.002)
    # ── the fill canister low on the left
    fx, fy = -0.078, 0.034
    cyl("fill", "Hazard", (fx, fy, -0.060), (fx, fy, 0.100), 0.024, segs=14, bevel=0.002)
    lathe("fill_cap", "GunBody", [(0.024, 0.100), (0.024, 0.104), (0.017, 0.112), (0.0, 0.112)], segs=14,
          at=(fx, fy, 0))
    for z in (-0.040, 0.080):
        ring_z(f"fill_clamp{z}", "Dark", z, 0.023, 0.028, 0.012, x=fx, y=fy, segs=14)
    lathe("fill_end", "GunBody", [(0.0, -0.072), (0.018, -0.072), (0.024, -0.064), (0.024, -0.060)], segs=14,
          at=(fx, fy, 0))
    box("fill_win", "GlowAmber", (fx - 0.0232, fy, 0.020), (0.002, 0.005, 0.044))
    decal("fill_lbl", "fill", (fx, fy + 0.0245, 0.020), (0, 1, 0), (0, 0, -1), 0.040, 0.010)
    # ── a capacitor drum on the right, an orange cap
    cyl("cap", "Anodised", (0.064, 0.074, 0.090), (0.064, 0.074, -0.090), 0.019, segs=14, bevel=0.002)
    cyl("cap_end", "GunPaint", (0.064, 0.074, -0.090), (0.064, 0.074, -0.100), 0.017, segs=14, bevel=0.0015)
    for z in (-0.050, 0.050):
        ring_z(f"cap_clamp{z}", "Dark", z, 0.018, 0.023, 0.010, x=0.064, y=0.074, segs=14)
    # ── the FOCUSING CHAMBER: an octagonal frame front and back, four bars, the
    # crystal between two copper coils, a feed emitter at its back
    oct_ = dict(segs=8, a0=math.radians(22.5), a1=math.radians(22.5) + 2 * math.pi)
    lathe("cham_rear", "GunBody", [(0.028, -0.124), (0.068, -0.124), (0.072, -0.130), (0.072, -0.140),
                                   (0.028, -0.140)], at=(0, Y, 0), **oct_)
    lathe("cham_front", "GunBody", [(0.028, -0.290), (0.072, -0.290), (0.072, -0.300), (0.066, -0.306),
                                    (0.028, -0.306)], at=(0, Y, 0), **oct_)
    for k in range(4):
        a = math.radians(45 + 90 * k)
        box(f"bar{k}", "GunBody" if k < 2 else "Dark", (0.062 * math.cos(a), Y + 0.062 * math.sin(a), -0.215),
            (0.013, 0.013, 0.152), M=Matrix.Rotation(a, 3, "Z"), bevel=0.002)
    for k in range(2):
        a = math.radians(45 + 90 * k)
        box(f"bar_band{k}", "Hazard", (0.0625 * math.cos(a), Y + 0.0625 * math.sin(a), -0.160),
            (0.0145, 0.0145, 0.010), M=Matrix.Rotation(a, 3, "Z"))
    uvmode(lathe("emit_feed", "Emitter", [(0.0, -0.141), (0.020, -0.141), (0.024, -0.140)], segs=12, at=(0, Y, 0)),
           "dish", 0.0, Y)
    uvmode(lathe("crystal", "Crystal", [(0.0, -0.150), (0.016, -0.158), (0.026, -0.170), (0.026, -0.264),
                                        (0.016, -0.276), (0.0, -0.284)], segs=6, at=(0, Y, 0), sharp=20,
                 a0=math.radians(30), a1=math.radians(30) + 2 * math.pi), "axial", 0.0, Y)
    for k, z in enumerate((-0.176, -0.260)):
        lathe(f"clamp{k}", "Chrome", [(0.024, z + 0.005), (0.030, z + 0.005), (0.030, z - 0.005), (0.024, z - 0.005)],
              at=(0, Y, 0), segs=6, a0=math.radians(30), a1=math.radians(30) + 2 * math.pi, sharp=20)
        for j in range(3):
            a = math.radians(90 + 120 * j)
            box(f"clamp_arm{k}{j}", "Dark", (0.044 * math.cos(a), Y + 0.044 * math.sin(a), z),
                (0.004, 0.030, 0.006), M=Matrix.Rotation(a - math.pi / 2, 3, "Z"))
    for k, z in enumerate((-0.196, -0.240)):
        torus_z(f"coil{k}", "Copper", z, 0.036, 0.0065, y=Y, seg_major=12, seg_minor=5)
    # ── the heavy nozzle, its focus ring and emitter
    lathe("nozzle", "GunBody", [(0.028, -0.306), (0.058, -0.306), (0.058, -0.330), (0.050, -0.338), (0.050, -0.382),
                                (0.044, -0.388), (0.044, -0.404), (0.034, -0.404), (0.030, -0.398)],
          segs=16, at=(0, Y, 0))
    lathe("noz_cup", "Dark", [(0.030, -0.398), (0.028, -0.394), (0.0, -0.394)], segs=12, at=(0, Y, 0))
    uvmode(lathe("iris", "Emitter", [(0.0, -0.3955), (0.016, -0.3955), (0.0165, -0.3945)], segs=12, at=(0, Y, 0)),
           "dish", 0.0, Y)
    cyl("lens", "EnergyGlass", (0, Y, -0.3975), (0, Y, -0.3985), 0.029, segs=14)
    ring_z("noz_rim", "Chrome", -0.402, 0.043, 0.0465, 0.004, y=Y, segs=16)
    focus_ring(Y, -0.342, -0.376, 0.054, knurls=10)
    # ── under the chamber, the fore-grip
    box("fgrip_mount", "GunBody", (0.0, Y - 0.074, -0.150), (0.026, 0.012, 0.050), bevel=0.003)
    fore_grip(Y, (-0.078, -0.150), (-0.158, -0.168))
    # ── hoses: the drum to the chamber; a cable to the nozzle
    hose("hose_a", "Rubber", [(0.064, 0.074, -0.100), (0.066, 0.080, -0.118), (0.040, Y + 0.040, -0.128)], 0.0065)
    hose("cable", "Dark", [(-0.050, 0.100, -0.100), (-0.066, 0.108, -0.200), (-0.064, 0.090, -0.300),
                           (-0.050, Y + 0.030, -0.320)], 0.003, sides=4)
    pistol_grip(LASER_DZ)
    anchors = {
        "grip": [0.0, -0.035, 0.080],
        "muzzle": [0.0, Y, -0.405],
        "fore": [0.0, Y - 0.112, -0.162],
        "vent": [0.0, Y + 0.070, -0.215],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0},
             {"name": "Focus", "parent": "Body", "t": [0, Y, 0], "roll": 0.0}]
    return export(), anchors, nodes


def laser_B(rifle=False):
    """TL-5 SURVEYOR: the slim beam rifle with the glowing coolant loop.
    `rifle`: the crew weapon (scripts/surveyor.lua) — its own nameplate line
    and a slotted muzzle brake over the emitter head; the rest is design B."""
    reset()
    Y = TL_Y
    # ── a slim enamel receiver with a dark waist
    prof = [(0.150, 0.090), (-0.118, 0.090), (-0.138, 0.076), (-0.140, 0.018), (-0.118, 0.002), (0.050, -0.004),
            (0.120, 0.000), (0.150, 0.020)]
    slab("rcv", "Enamel", prof, -0.034, 0.034, bevel=0.005, segs=2)
    box("waist", "Dark", (0.0, 0.046, -0.020), (0.0695, 0.082, 0.008))
    decal("rcv_name", "tl5", (-0.0346, 0.066, 0.070), (-1, 0, 0), (0, 1, 0), 0.066, 0.021)
    decal("rcv_sub", "tl5_name" if rifle else "tl7_name", (-0.0346, 0.044, 0.070), (-1, 0, 0), (0, 1, 0),
          0.094 if not rifle else 0.072, 0.0075 if not rifle else 0.009)
    decal("rcv_emb", "emblem", (-0.0346, 0.060, -0.080), (-1, 0, 0), (0, 1, 0), 0.022, 0.022)
    decal("rcv_warn", "laser_warn", (0.0346, 0.056, -0.075), (1, 0, 0), (0, 1, 0), 0.042, 0.028)
    decal("rcv_ser", "serial_b", (0.0346, 0.020, 0.090), (1, 0, 0), (0, 1, 0), 0.056, 0.0070)
    for s in (-1, 1):
        for k, (z, y) in enumerate(((0.136, 0.078), (0.136, 0.012), (-0.124, 0.072), (-0.124, 0.016))):
            bolt(f"rcv_b{s}{k}", (s * 0.0345, y, z), (s, 0, 0), r=0.0032)
    # the HEAT readout on the receiver's top, behind the scope
    box("gauge_bezel", "Dark", (0.0, 0.0905, 0.122), (0.016, 0.002, 0.050))
    screen("heat_bar", "Gauge", (0.0, 0.0915, 0.122), (0, 1, 0), (-1, 0, 0), 0.044, 0.010)
    # ── the survey scope on two mounts, a ranging pod on its left
    for k, z in enumerate((0.060, -0.070)):
        box(f"mount{k}", "Dark", (0.0, 0.100, z), (0.020, 0.020, 0.016), bevel=0.002)
    cyl("scope", "GunBody", (0.0, 0.124, 0.100), (0.0, 0.124, -0.090), 0.0165, segs=14, bevel=0.002)
    lathe("scope_bell", "GunBody", [(0.0165, -0.090), (0.022, -0.106), (0.022, -0.128), (0.018, -0.128)], segs=14,
          at=(0, 0.124, 0))
    cyl("scope_lens", "Lens", (0, 0.124, -0.125), (0, 0.124, -0.1262), 0.018, segs=14)
    lathe("scope_eye", "Rubber", [(0.0165, 0.100), (0.019, 0.104), (0.019, 0.122), (0.014, 0.122)], segs=12,
          at=(0, 0.124, 0))
    ring_z("scope_ring", "GunPaint", 0.010, 0.0164, 0.0185, 0.012, y=0.124, segs=14)
    box("pod", "Dark", (-0.028, 0.118, -0.020), (0.020, 0.022, 0.060), bevel=0.003)
    cyl("pod_lens", "GlowAmber", (-0.028, 0.118, -0.0505), (-0.028, 0.118, -0.0515), 0.006, segs=8)
    # ── the fill canister, slim, on the left
    fx, fy = -0.056, 0.042
    cyl("fill", "Hazard", (fx, fy, -0.030), (fx, fy, 0.100), 0.020, segs=14, bevel=0.002)
    lathe("fill_cap", "GunBody", [(0.020, 0.100), (0.020, 0.104), (0.013, 0.112), (0.0, 0.112)], segs=14,
          at=(fx, fy, 0))
    for z in (-0.010, 0.080):
        ring_z(f"fill_clamp{z}", "Dark", z, 0.019, 0.024, 0.010, x=fx, y=fy, segs=14)
    lathe("fill_end", "GunBody", [(0.0, -0.040), (0.015, -0.040), (0.020, -0.033), (0.020, -0.030)], segs=14,
          at=(fx, fy, 0))
    box("fill_win", "GlowAmber", (fx - 0.0192, fy, 0.035), (0.002, 0.004, 0.040))
    # ── a skeletal stock: two converging bars, a cheek pad, the cell between, a butt
    cyl("stock_top", "Anodised", (0, 0.080, 0.145), (0, 0.068, 0.318), 0.009, segs=10)
    cyl("stock_bot", "Anodised", (0, 0.000, 0.140), (0, 0.006, 0.318), 0.009, segs=10)
    box("cheek", "Rubber", (0.0, 0.088, 0.250), (0.024, 0.012, 0.080), bevel=0.004)
    slab("butt", "Rubber", [(0.310, 0.088), (0.330, 0.086), (0.334, 0.040), (0.330, -0.012), (0.310, -0.014)],
         -0.022, 0.022, bevel=0.005, segs=2)
    energy_cell("cell", 0.0, 0.038, 0.165, 0.300, 0.020, 0.182, 0.284, segs=12, bars=4, rod=0.011)
    # ── the long barrel in a ventilated shroud: rings and six slats
    cyl("barrel", "Dark", (0, Y, -0.140), (0, Y, -0.500), 0.013, segs=10)
    for k, z in enumerate((-0.150, -0.300, -0.450)):
        ring_z(f"shroud_ring{k}", "GunBody", z, 0.013, 0.031, 0.014, y=Y, segs=16)
    for k in range(6):
        a = 2 * math.pi * (k + 0.5) / 6
        box(f"slat{k}", "Dark", (0.026 * math.cos(a), Y + 0.026 * math.sin(a), -0.300), (0.007, 0.004, 0.300),
            M=Matrix.Rotation(a + math.pi / 2, 3, "Z"))
    # ── THE COOLANT LOOP: a reservoir under the barrel, two lines up the sides
    # to a ring round the muzzle, glowing (tool_energy, cold blue warming to
    # amber with heat) and flowing out on the left and back on the right
    energy_cell("res", 0.0, Y - 0.040, -0.236, -0.144, 0.019, -0.226, -0.154, segs=12, bars=4, rod=0.012,
                rodmat="Coolant", glassmat="CoolGlass")
    uvmode(hose("cool_l", "Coolant", [(-0.010, Y - 0.026, -0.160), (-0.030, Y - 0.006, -0.190),
                                       (-0.035, Y + 0.002, -0.300), (-0.034, Y + 0.002, -0.440),
                                       (-0.033, Y, -0.476)], 0.0052, sides=6), "axial", 0.0, Y)
    uvmode(hose("cool_r", "Coolant", [(0.010, Y - 0.026, -0.160), (0.030, Y - 0.006, -0.190),
                                       (0.035, Y + 0.002, -0.300), (0.034, Y + 0.002, -0.440),
                                       (0.033, Y, -0.476)], 0.0052, sides=6), "axial_rev", 0.0, Y)
    uvmode(torus_z("cool_ring", "Coolant", -0.478, 0.033, 0.0058, y=Y, seg_major=16, seg_minor=5), "around", 0.0, Y,
           0.033)
    for k, z in enumerate((-0.300, -0.450)):
        for s in (-1, 1):
            box(f"cool_clip{k}{s}", "Chrome", (s * 0.0345, Y + 0.002, z), (0.010, 0.012, 0.008))
    # ── the emitter head: focus ring, iris, lens
    lathe("head", "GunBody", [(0.013, -0.484), (0.024, -0.484), (0.028, -0.490), (0.028, -0.544), (0.024, -0.550),
                              (0.024, -0.562), (0.018, -0.562), (0.016, -0.558)], segs=16, at=(0, Y, 0))
    lathe("head_cup", "Dark", [(0.016, -0.558), (0.015, -0.555), (0.0, -0.555)], segs=10, at=(0, Y, 0))
    uvmode(lathe("iris", "Emitter", [(0.0, -0.5565), (0.009, -0.5565), (0.0095, -0.5555)], segs=10, at=(0, Y, 0)),
           "dish", 0.0, Y)
    cyl("lens", "EnergyGlass", (0, Y, -0.5585), (0, Y, -0.5595), 0.0165, segs=12)
    ring_z("head_rim", "Chrome", -0.561, 0.0235, 0.0262, 0.004, y=Y, segs=16)
    focus_ring(Y, -0.500, -0.528, 0.032, knurls=10)
    if rifle:
        # a slotted muzzle brake round the emitter: four ports a side vent the
        # bolt's blast sideways (the kick the hands feel)
        lathe("brake", "Dark", [(0.024, -0.562), (0.027, -0.564), (0.027, -0.606), (0.022, -0.608), (0.0175, -0.606)],
              segs=16, at=(0, Y, 0))
        for s_ in (-1, 1):
            for k in range(4):
                box(f"port{s_}{k}", "GunBody", (s_ * 0.0268, Y, -0.572 - k * 0.009), (0.002, 0.012, 0.004))
        ring_z("brake_rim", "Chrome", -0.607, 0.0175, 0.0225, 0.003, y=Y, segs=16)
    # ── the fore-grip under the reservoir
    box("fgrip_mount", "GunBody", (0.0, Y - 0.062, -0.190), (0.022, 0.010, 0.050), bevel=0.003)
    fore_grip(Y, (-0.066, -0.188), (-0.146, -0.204))
    pistol_grip(LASER_DZ)
    anchors = {
        "grip": [0.0, -0.035, 0.080],
        "muzzle": [0.0, Y, -0.612 if rifle else -0.565],
        "fore": [0.0, Y - 0.106, -0.196],
        "vent": [0.0, Y + 0.034, -0.300],
        # the rifle's scope: the eye end of the tube (first-person ADS)
        "scope": [0.0, 0.124, 0.122],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0},
             {"name": "Focus", "parent": "Body", "t": [0, Y, 0], "roll": 0.0}]
    return export(), anchors, nodes


def laser_C():
    """TL-3 PLASMA BORE: stubby, a plasma drum, a spinning emitter crown."""
    reset()
    Y = TL_Y
    # ── a compact graphite receiver, enamel plates, a hoop handle
    prof = [(0.140, 0.100), (-0.064, 0.100), (-0.084, 0.084), (-0.088, 0.006), (-0.064, -0.008), (0.050, -0.008),
            (0.120, -0.004), (0.145, 0.030)]
    slab("rcv", "GunBody", prof, -0.048, 0.048, bevel=0.006, segs=2)
    plate = [(0.124, 0.088), (-0.050, 0.088), (-0.066, 0.074), (-0.068, 0.012), (-0.050, 0.002), (0.112, 0.006),
             (0.130, 0.036)]
    receiver_plates(plate, 0.048, 0.0545, "tl3", "pl", ys=(0.064, 0.040), zs=(0.040, 0.040))
    decal("pl_warn", "laser_warn", (0.0549, 0.058, -0.010), (1, 0, 0), (0, 1, 0), 0.046, 0.030)
    decal("pl_emb", "emblem", (-0.0549, 0.070, -0.042), (-1, 0, 0), (0, 1, 0), 0.020, 0.020)
    hose("hoop", "Rubber", [(0.0, 0.098, 0.112), (0.0, 0.150, 0.086), (0.0, 0.160, 0.010), (0.0, 0.146, -0.050),
                            (0.0, 0.098, -0.060)], 0.0105, sides=8)
    for k, z in enumerate((0.110, -0.058)):
        box(f"hoop_foot{k}", "Dark", (0.0, 0.104, z), (0.026, 0.010, 0.024), bevel=0.002)
    box("gauge_bezel", "Dark", (0.0, 0.1005, 0.030), (0.016, 0.002, 0.056))
    screen("heat_bar", "Gauge", (0.0, 0.1015, 0.030), (0, 1, 0), (-1, 0, 0), 0.050, 0.010)
    # vents down the right flank
    for k in range(5):
        box(f"vent{k}", "Dark", (0.0548, 0.024 + k * 0.009, 0.080), (0.004, 0.0042, 0.050), bevel=0.0008)
    # ── the fill canister on the left
    fx, fy = -0.070, 0.040
    cyl("fill", "Hazard", (fx, fy, -0.060), (fx, fy, 0.090), 0.022, segs=14, bevel=0.002)
    lathe("fill_cap", "GunBody", [(0.022, 0.090), (0.022, 0.094), (0.015, 0.102), (0.0, 0.102)], segs=14,
          at=(fx, fy, 0))
    for z in (-0.040, 0.070):
        ring_z(f"fill_clamp{z}", "Dark", z, 0.021, 0.026, 0.010, x=fx, y=fy, segs=14)
    lathe("fill_end", "GunBody", [(0.0, -0.070), (0.016, -0.070), (0.022, -0.063), (0.022, -0.060)], segs=14,
          at=(fx, fy, 0))
    box("fill_win", "GlowAmber", (fx - 0.0212, fy, 0.015), (0.002, 0.004, 0.040))
    # ── the energy cell slung low behind the grip, as the gravity gun's, and a butt cap
    ccy, ccr = 0.036, 0.038
    energy_cell("cell", 0.0, ccy, 0.140, 0.262, ccr, 0.162, 0.236, segs=18, bars=6, rod=0.021)
    lathe("butt", "Rubber", [(0.0, 0.276), (0.028, 0.276), (0.036, 0.270), (0.040, 0.262)], segs=18, at=(0, ccy, 0))
    band("cell_band", 0.249, ccr + 0.0006, 0.010, segs=18, y=ccy)
    # ── THE PLASMA DRUM: end discs, the plasma inside a glass sleeve, ten
    # ribs over it with gaps to see it through, two copper magnet rings
    ring_z("pc_rear", "GunBody", -0.094, 0.020, 0.077, 0.020, y=Y, segs=20)
    ring_z("pc_front", "GunBody", -0.222, 0.020, 0.077, 0.016, y=Y, segs=20)
    uvmode(cyl("plasma", "Plasma", (0, Y, -0.104), (0, Y, -0.214), 0.056, segs=16, caps=False), "axial", 0.0, Y)
    uvmode(cyl("pc_glass", "EnergyGlass", (0, Y, -0.104), (0, Y, -0.214), 0.0605, segs=16, caps=False), "axial",
           0.0, Y)
    for k in range(10):
        a = 2 * math.pi * k / 10 + math.pi / 2
        box(f"rib{k}", "GunBody", (0.068 * math.cos(a), Y + 0.068 * math.sin(a), -0.158), (0.012, 0.013, 0.118),
            M=Matrix.Rotation(a, 3, "Z"), bevel=0.0015)
    for k, z in enumerate((-0.128, -0.190)):
        torus_z(f"mag{k}", "Copper", z, 0.076, 0.0065, y=Y, seg_major=20, seg_minor=5)
    decal("pc_hot", "hot", (0.0, Y + 0.0752, -0.159), (0, 1, 0), (0, 0, -1), 0.040, 0.010)
    # ── the emitter: a nozzle cone with its glowing cup; round it the CROWN
    # (node Focus): an orange ring and six electrodes leaning in, chrome tips
    lathe("nozzle", "Dark", [(0.020, -0.230), (0.036, -0.234), (0.032, -0.262), (0.020, -0.272), (0.016, -0.268)],
          segs=16, at=(0, Y, 0))
    uvmode(lathe("iris", "Emitter", [(0.0, -0.266), (0.016, -0.2685)], segs=12, at=(0, Y, 0)), "dish", 0.0, Y)
    crown = [lathe("crown", "GunPaint", [(0.040, -0.230), (0.058, -0.232), (0.058, -0.246), (0.040, -0.248)],
                   segs=18, at=(0, Y, 0), node="Focus")]
    for k in range(6):
        a = 2 * math.pi * k / 6
        R = Matrix.Translation((0, Y, 0)) @ Matrix.Rotation(a, 4, "Z")
        pr = [(-0.240, 0.050), (-0.240, 0.058), (-0.280, 0.040), (-0.316, 0.024), (-0.316, 0.018), (-0.290, 0.030)]
        e = slab(f"prong{k}", "Dark", [(z, y + Y) for z, y in pr], -0.0045, 0.0045, node="Focus", bevel=0.001)
        t = box(f"prong_tip{k}", "Chrome", (0.0, Y + 0.021, -0.316), (0.010, 0.008, 0.008), node="Focus")
        e.matrix_world = R @ Matrix.Translation((0, -Y, 0)) @ e.matrix_world
        t.matrix_world = R @ Matrix.Translation((0, -Y, 0)) @ t.matrix_world
        crown += [e, t]
    # ── under the drum, the fore-grip
    box("fgrip_mount", "GunBody", (0.0, Y - 0.080, -0.150), (0.024, 0.010, 0.050), bevel=0.003)
    fore_grip(Y, (-0.084, -0.150), (-0.164, -0.166))
    hose("cable", "Dark", [(-0.046, 0.090, -0.060), (-0.064, 0.100, -0.090), (-0.074, 0.090, -0.110)], 0.003, sides=4)
    pistol_grip(LASER_DZ)
    anchors = {
        "grip": [0.0, -0.035, 0.080],
        "muzzle": [0.0, Y, -0.320],
        "fore": [0.0, Y - 0.118, -0.158],
        "vent": [0.0, Y + 0.080, -0.158],
    }
    nodes = [{"name": "Body", "parent": None, "t": [0, 0, 0], "roll": 0.0},
             {"name": "Focus", "parent": "Body", "t": [0, Y, 0], "roll": 0.0}]
    return export(), anchors, nodes


LASERS = {"TL7": laser_tl7, "A": laser_A, "B": laser_B, "C": laser_C}


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
        mode = UVMODE.get(ob.name)
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
            elif mode is not None:
                UV = [custom_uv(mode, p) for p in P]
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
    """-- OUT.json [LASERS]: the gravity gun and each laser variant named
    (comma-separated, default TL7), as res["gravgun"] and res["laser_<V>"]."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    argv = [a for a in argv if not a.startswith("--")]
    path = argv[0] if argv else "/tmp/tools_mesh.json"
    want = argv[1].split(",") if len(argv) > 1 else ["C"]
    res = {}
    for name, fn in ([("gravgun", gravity_gun)] + [("laser_" + v, LASERS[v]) for v in want]
                     + [("surveyor", lambda: laser_B(rifle=True))]):
        geo, anchors, nodes = fn()
        tris = sum(len(m["P"]) // 9 for n in geo.values() for m in n.values())
        res[name] = {"geo": geo, "anchors": anchors, "nodes": nodes}
        print(f"TOOLS {name}: {tris} tris, nodes {list(geo.keys())}")
    with open(path, "w") as f:
        json.dump(res, f)
    print("TOOLS wrote", path)


main()
