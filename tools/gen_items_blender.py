"""The held items' geometry, built in Blender (run headless by tools/gen_items.py).

    blender --background --factory-startup --python tools/gen_items_blender.py -- OUT.json

The same method as the hand tools (tools/gen_tools_blender.py, which this
matches in look and does not import: that file builds and writes on import):
real bevels with the bevel faces in a worn-edge material, extruded
silhouettes, swept straps and cables, evaluated and written to OUT.json as
triangles per material. tools/gen_items.py turns that into .glb files and
prefabs. Nothing is rendered here and no .blend is kept.

Coordinates are the GAME's: +X right, +Y up, +Z ahead, metres. Each item's
frame is the one scripts/item_hand.lua carries it in:

  ItemRepairKit     a field repair case: +Y out of its handle (the handle on
                    top, carried hanging), its long side along +Z. Laid on a
                    hull for the work, +Y is the hull's normal.
  ItemBeaconStowed  the relay beacon folded for carrying: the mast tube and
                    its folded legs along +Y, slung over a shoulder.
  ItemFlagFurled    the company flag furled round its collapsed pole, in a
                    sleeve, along +Y.
  ItemO2Tank        a spare breathing-oxygen bottle with its valve and quick-
                    disconnect, along +Y (clipped beside the PLSS).
"""
import json
import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

UV_M = 3.0
WEAR = {"Enamel": "EnamelWorn", "GunPaint": "PaintWorn", "Hazard": "PaintWorn", "Olive": "PaintWorn",
        "O2Green": "PaintWorn"}
DECALS = {   # cells of textures/tools/tool_decals.png (gen_tools_blender.py's table)
    "hazard": (0, 288, 128, 32), "serial_a": (0, 336, 256, 32), "serial_b": (256, 336, 256, 32),
    "arrow": (0, 368, 128, 64), "bolts": (384, 368, 128, 64), "emblem": (384, 160, 128, 128),
}
ATLAS = 512.0
OBJS = []


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    OBJS.clear()


def mat(name):
    return bpy.data.materials.get(name) or bpy.data.materials.new(name)


def finish(bm, name, material, bevel=0.0, segs=1, sharp=40.0, decal=False, smooth=True):
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
    OBJS.append((ob, decal))
    return ob


def box(name, m, center, size, M=None, bevel=0.0, segs=1):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    S = Matrix.Diagonal((size[0], size[1], size[2], 1.0))
    R = M.to_4x4() if M is not None else Matrix.Identity(4)
    bmesh.ops.transform(bm, matrix=Matrix.Translation(Vector(center)) @ R @ S, verts=bm.verts)
    if min(size) < 0.012:
        bevel = 0.0
    return finish(bm, name, m, bevel=bevel, segs=segs)


def lathe_bm(prof, segs=24):
    bm = bmesh.new()
    rings = []
    for r, z in prof:
        rings.append([bm.verts.new((r * math.cos(2 * math.pi * k / segs), r * math.sin(2 * math.pi * k / segs), z))
                      for k in range(segs)])
    for i in range(len(rings) - 1):
        A, B = rings[i], rings[i + 1]
        for k in range(segs):
            k1 = (k + 1) % segs
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
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def along_y(at=(0, 0, 0)):
    """+Z (the lathe axis) onto +Y, at a point."""
    return Matrix.Translation(Vector(at)) @ Matrix.Rotation(-math.pi / 2, 4, "X")


def lathe_y(name, m, prof, at=(0, 0, 0), segs=24, bevel=0.0, sharp=40.0, M=None):
    """A surface of revolution about +Y: prof = [(r, y), ...]."""
    bm = lathe_bm(prof, segs)
    T = (M.to_4x4() if M is not None else Matrix.Identity(4)) @ along_y(at)
    bmesh.ops.transform(bm, matrix=T, verts=bm.verts)
    return finish(bm, name, m, bevel=bevel, sharp=sharp)


def cyl(name, m, p0, p1, r, segs=16, r1=None, bevel=0.0):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    bm = lathe_bm([(0.0, 0.0), (r, 0.0), (r if r1 is None else r1, d.length), (0.0, d.length)], segs)
    bmesh.ops.transform(bm, matrix=Matrix.Translation(p0) @ q.to_matrix().to_4x4(), verts=bm.verts)
    if r < 0.016:
        bevel = 0.0
    return finish(bm, name, m, bevel=bevel)


def slab(name, m, prof, x0, x1, bevel=0.0, segs=1, M=None):
    """An extruded silhouette: prof = [(z, y), ...] extruded along X from x0 to x1."""
    bm = bmesh.new()
    lo = [bm.verts.new((x0, v, u)) for u, v in prof]
    hi = [bm.verts.new((x1, v, u)) for u, v in prof]
    bm.faces.new(lo)
    bm.faces.new(list(reversed(hi)))
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if M is not None:
        bmesh.ops.transform(bm, matrix=M.to_4x4(), verts=bm.verts)
    return finish(bm, name, m, bevel=bevel, segs=segs)


def hose(name, m, pts, r, res=3, sides=6):
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
    cu.materials.append(mat(m))
    OBJS.append((ob, False))
    return ob


def bolt(name, p, normal, r=0.004, h=0.003, m="Chrome"):
    n = Vector(normal).normalized()
    p = Vector(p)
    return cyl(name, m, p - n * 0.001, p + n * h, r, segs=6)


def decal(name, cell, center, normal, up, w, h):
    x, y, cw, ch = DECALS[cell]
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
    u0, u1 = x / ATLAS, (x + cw) / ATLAS
    v0, v1 = 1 - (y + ch) / ATLAS, 1 - y / ATLAS
    for lp in f.loops:
        q = lp.vert.co - c
        a = q.dot(rgt) / w + 0.5
        b = q.dot(u) / h + 0.5
        lp[uvl].uv = (u0 + (u1 - u0) * a, v0 + (v1 - v0) * b)
    return finish(bm, name, "ToolDecal", decal=True, smooth=False)


def band_y(name, m, y0, y1, r, segs=24):
    """A thin ring round a +Y cylinder (a strap, a stripe)."""
    return lathe_y(name, m, [(r, y0), (r, y1)], segs=segs)


# ── the REPAIR KIT: a field repair case ────────────────────────────────────
#
# A ribbed, rotomoulded case in worn enamel with dark bumpers at the corners,
# two over-centre latches, a folding handle on top, a stencilled band and a
# serial plate, and the welder's lead coiled and strapped on one end. 34 cm
# long, 22 tall, 10 thick: 6 L as the registry says.

def repair_kit():
    L, H, T = 0.34, 0.22, 0.10
    # the shell: two halves split along the long side, a seam between
    box("shell_lo", "Enamel", (0, H * 0.27, 0), (T, H * 0.54, L), bevel=0.012, segs=2)
    box("shell_hi", "Enamel", (0, H * 0.78, 0), (T * 0.98, H * 0.44, L * 0.98), bevel=0.014, segs=2)
    box("seam", "Dark", (0, H * 0.555, 0), (T * 1.012, 0.008, L * 1.006))
    # moulded ribs on both faces
    for s in (-1, 1):
        for k in range(4):
            z = -0.11 + k * 0.073
            box(f"rib{s}{k}", "Enamel", (s * (T / 2 + 0.003), H * 0.27, z), (0.006, H * 0.40, 0.022), bevel=0.002)
    # rubber corner bumpers (eight)
    for sx in (-1, 1):
        for sy in (0, 1):
            for sz in (-1, 1):
                box(f"bump{sx}{sy}{sz}", "Rubber", (sx * (T / 2 - 0.012), 0.016 + sy * (H - 0.032), sz * (L / 2 - 0.016)),
                    (0.034, 0.038, 0.040), bevel=0.008)
    # two over-centre latches across the seam
    for sz in (-1, 1):
        z = sz * 0.095
        for s in (-1, 1):
            box(f"latch_base{sz}{s}", "Dark", (s * (T / 2 + 0.006), H * 0.51, z), (0.008, 0.050, 0.030), bevel=0.002)
            box(f"latch_lever{sz}{s}", "Chrome", (s * (T / 2 + 0.011), H * 0.565, z), (0.006, 0.060, 0.022), bevel=0.0015)
            bolt(f"latch_pin{sz}{s}", (s * (T / 2 + 0.014), H * 0.60, z), (s, 0, 0), r=0.003)
    # the handle: two pivots and a rubber-gripped bar, folded up
    for sz in (-1, 1):
        box(f"pivot{sz}", "Dark", (0, H + 0.012, sz * 0.075), (0.030, 0.026, 0.020), bevel=0.004)
        cyl(f"arm{sz}", "Chrome", (0, H + 0.012, sz * 0.075), (0, H + 0.048, sz * 0.060), 0.006, segs=8)
    cyl("grip_bar", "Rubber", (0, H + 0.050, -0.064), (0, H + 0.050, 0.064), 0.013, segs=12)
    for k in range(6):
        z = -0.05 + k * 0.02
        cyl(f"grip_ring{k}", "Dark", (0, H + 0.050, z - 0.002), (0, H + 0.050, z + 0.002), 0.0142, segs=12)
    # stencils: a hazard band, the serial plate, an arrow
    for s in (-1, 1):
        decal(f"band{s}", "hazard", (s * (T / 2 + 0.0002), H * 0.72, 0), (s, 0, 0), (0, 1, 0), 0.30, 0.03)
        decal(f"serial{s}", "serial_a", (s * (T / 2 + 0.0002), H * 0.84, 0.0), (s, 0, 0), (0, 1, 0), 0.18, 0.022)
    box("plate", "Chrome", (T / 2 + 0.0015, H * 0.30, -0.06), (0.002, 0.040, 0.090), bevel=0.001)
    for k, (yy, zz) in enumerate(((0.30 - 0.015, -0.10), (0.30 - 0.015, -0.02), (0.30 + 0.015, -0.10), (0.30 + 0.015, -0.02))):
        bolt(f"plate_bolt{k}", (T / 2 + 0.003, H * yy / 0.30 * 0.30, zz), (1, 0, 0), r=0.0025)
    # the welder's lead, coiled on the end and held by a strap
    for k in range(4):
        hose(f"coil{k}", "Rubber", [(-0.030, 0.050 + k * 0.022, L / 2 + 0.010), (0.0, 0.040 + k * 0.022, L / 2 + 0.024),
                                    (0.030, 0.050 + k * 0.022, L / 2 + 0.010)], 0.0055, sides=6)
    box("coil_strap", "Olive", (0, 0.085, L / 2 + 0.018), (0.075, 0.016, 0.032), bevel=0.003)
    cyl("lead_plug", "Copper", (0.034, 0.12, L / 2 + 0.006), (0.034, 0.15, L / 2 + 0.006), 0.007, segs=10)
    return {"grip": [0.0, H + 0.050, 0.0]}


# ── the RELAY BEACON, stowed ───────────────────────────────────────────────
#
# The planted beacon's mast telescoped down, its dish folded flat against
# the tube, its three legs folded up the sides and held by two cargo straps,
# with a carry sling. 88 cm long.

def beacon_stowed():
    Lb = 0.88
    lathe_y("mast", "Enamel", [(0.0, 0.0), (0.050, 0.0), (0.050, Lb * 0.78), (0.040, Lb * 0.80),
                               (0.040, Lb * 0.96), (0.0, Lb * 0.96)], segs=20, bevel=0.004)
    lathe_y("foot", "Dark", [(0.0, -0.02), (0.064, -0.02), (0.068, 0.06), (0.052, 0.07), (0.0, 0.07)], segs=20, bevel=0.003)
    lathe_y("collar", "Chrome", [(0.054, Lb * 0.40), (0.056, Lb * 0.42), (0.056, Lb * 0.44), (0.054, Lb * 0.46)], segs=20)
    lathe_y("cap", "GunPaint", [(0.0, Lb * 0.96), (0.044, Lb * 0.96), (0.040, Lb), (0.0, Lb + 0.006)], segs=20)
    # the folded dish, flat on the tube's front
    lathe_y("dish", "Chrome", [(0.0, 0.0), (0.11, 0.025), (0.115, 0.03)], segs=24,
            M=Matrix.Translation((0, Lb * 0.66, 0.062)) @ Matrix.Rotation(math.pi / 2, 4, "X") @ Matrix.Translation((0, 0, 0)))
    box("dish_arm", "Dark", (0, Lb * 0.66, 0.056), (0.012, 0.11, 0.010))
    # three folded legs up the sides
    for k in range(3):
        a = math.pi / 6 + k * 2 * math.pi / 3
        x, z = 0.062 * math.cos(a), 0.062 * math.sin(a)
        ob = box(f"leg{k}", "Dark", (x, Lb * 0.27, z), (0.016, Lb * 0.46, 0.010), bevel=0.002)
        ob.matrix_world = Matrix.Translation((x, 0, z)) @ Matrix.Rotation(-a, 4, "Y") @ Matrix.Translation((-x, 0, -z)) @ ob.matrix_world
        cyl(f"leg_pad{k}", "Rubber", (x * 1.15, 0.04, z * 1.15), (x * 1.15, 0.065, z * 1.15), 0.014, segs=8)
    # two cargo straps and their buckles, and the sling between them
    for k, y in enumerate((Lb * 0.18, Lb * 0.56)):
        band_y(f"strap{k}", "Olive", y - 0.014, y + 0.014, 0.0745, segs=20)
        box(f"buckle{k}", "Chrome", (0.074, y, 0), (0.008, 0.036, 0.030), bevel=0.002)
    hose("sling", "Olive", [(-0.07, Lb * 0.18, 0.0), (-0.12, Lb * 0.37, 0.0), (-0.07, Lb * 0.56, 0.0)], 0.009, sides=4)
    decal("beacon_band", "hazard", (0, Lb * 0.86, 0.0412), (0, 0, 1), (0, 1, 0), 0.06, 0.04)
    decal("beacon_serial", "serial_b", (0, Lb * 0.30, 0.0512), (0, 0, 1), (1, 0, 0), 0.24, 0.022)
    return {"grip": [0.0, Lb * 0.37, 0.0]}


# ── the COMPANY FLAG, furled ───────────────────────────────────────────────
#
# The pole collapsed to three sections, the cloth rolled round the top one
# and buckled into a sleeve, the crossbar folded down along it; a spike at
# the foot for driving it in. 1.45 m long.

def flag_furled():
    Lp = 1.45
    lathe_y("pole_lo", "Anodised", [(0.0, 0.0), (0.016, 0.0), (0.016, Lp * 0.42), (0.0, Lp * 0.42)], segs=12)
    lathe_y("pole_mid", "Anodised", [(0.0, Lp * 0.40), (0.0135, Lp * 0.40), (0.0135, Lp * 0.98), (0.0, Lp * 0.98)], segs=12)
    lathe_y("spike", "Chrome", [(0.0, -0.11), (0.003, -0.10), (0.014, -0.02), (0.016, 0.0), (0.0, 0.0)], segs=12)
    lathe_y("joint", "Dark", [(0.019, Lp * 0.40), (0.019, Lp * 0.44)], segs=12)
    lathe_y("knob", "Dark", [(0.0, Lp * 0.98), (0.020, Lp * 0.98), (0.020, Lp), (0.0, Lp + 0.004)], segs=12)
    # the rolled cloth in its sleeve
    lathe_y("sleeve", "Olive", [(0.0, Lp * 0.52), (0.040, Lp * 0.53), (0.046, Lp * 0.60), (0.046, Lp * 0.90),
                                (0.040, Lp * 0.95), (0.0, Lp * 0.955)], segs=18, bevel=0.0)
    for k, y in enumerate((Lp * 0.62, Lp * 0.76, Lp * 0.88)):
        band_y(f"tie{k}", "Dark", y - 0.008, y + 0.008, 0.0475, segs=18)
        box(f"tie_buckle{k}", "Chrome", (0.048, y, 0), (0.006, 0.020, 0.018))
    # a flash of the cloth's colour at the sleeve's mouth
    lathe_y("cloth_peek", "GunPaint", [(0.030, Lp * 0.505), (0.041, Lp * 0.525)], segs=18)
    # the crossbar folded down beside the pole
    cyl("crossbar", "Anodised", (0.024, Lp * 0.96, 0.0), (0.024, Lp * 0.60, 0.0), 0.007, segs=8)
    decal("flag_serial", "serial_a", (0, Lp * 0.75, 0.0467), (0, 0, 1), (1, 0, 0), 0.20, 0.02)
    return {"grip": [0.0, Lp * 0.3, 0.0]}


# ── the OXYGEN TANK ────────────────────────────────────────────────────────
#
# A composite-wrapped bottle in breathing-oxygen green, a stainless valve
# and gauge, a quick-disconnect for the suit's port and two clip bands.

def o2_tank():
    Lt, r = 0.46, 0.058
    lathe_y("bottle", "O2Green", [(0.0, 0.0), (r * 0.6, 0.004), (r, 0.03), (r, Lt - 0.05), (r * 0.62, Lt - 0.012),
                                  (0.016, Lt), (0.0, Lt)], segs=22, bevel=0.0, sharp=60)
    lathe_y("neck", "Chrome", [(0.0, Lt - 0.002), (0.017, Lt - 0.002), (0.017, Lt + 0.03), (0.0, Lt + 0.03)], segs=12)
    box("valve", "Chrome", (0, Lt + 0.045, 0), (0.036, 0.030, 0.030), bevel=0.004)
    cyl("knob", "Dark", (0, Lt + 0.06, 0), (0, Lt + 0.075, 0), 0.020, segs=14)
    cyl("gauge", "Chrome", (0.018, Lt + 0.045, 0), (0.034, Lt + 0.045, 0), 0.016, segs=14)
    cyl("gauge_face", "Enamel", (0.034, Lt + 0.045, 0), (0.0355, Lt + 0.045, 0), 0.013, segs=14)
    cyl("qd", "Copper", (-0.018, Lt + 0.045, 0), (-0.042, Lt + 0.045, 0), 0.009, segs=10)
    for k, y in enumerate((0.11, Lt - 0.13)):
        band_y(f"clip{k}", "Dark", y - 0.012, y + 0.012, r + 0.003, segs=22)
        box(f"clip_tab{k}", "Chrome", (0, y, -(r + 0.010)), (0.022, 0.018, 0.010), bevel=0.002)
    band_y("label_band", "Enamel", Lt * 0.40, Lt * 0.56, r + 0.0008, segs=22)
    decal("o2_serial", "serial_b", (0, Lt * 0.48, r + 0.0015), (0, 0, 1), (1, 0, 0), 0.07, 0.012)
    return {"grip": [0.0, Lt * 0.5, 0.0]}


def export():
    dg = bpy.context.evaluated_depsgraph_get()
    out = {}
    for ob, is_decal in OBJS:
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
            e = out.setdefault(mname, {"P": [], "N": [], "UV": []})
            loops = list(tri.loops)
            if flip:
                loops = loops[::-1]
            P = [Mw @ me.vertices[me.loops[li].vertex_index].co for li in loops]
            N = [(Mn @ Vector(cn[li].vector)).normalized() for li in loops]
            if uvl is not None:
                UV = [(u, 1.0 - v) for u, v in (tuple(uvl.data[li].uv) for li in loops)]
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
        ev.to_mesh_clear()
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    path = argv[0] if argv else "/tmp/items_mesh.json"
    res = {}
    for name, fn in (("repairkit", repair_kit), ("beacon", beacon_stowed), ("flag", flag_furled), ("o2tank", o2_tank)):
        reset()
        anchors = fn()
        geo = export()
        tris = sum(len(m["P"]) // 9 for m in geo.values())
        res[name] = {"geo": geo, "anchors": anchors}
        print(f"ITEMS {name}: {tris} tris, materials {sorted(geo.keys())}")
    with open(path, "w") as f:
        json.dump(res, f)
    print("ITEMS wrote", path)


main()
