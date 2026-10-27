#!/usr/bin/env python3
"""IVA interiors: the inside of every closed crew part, for the first-person
seat view (V) and the crew strip's live portraits (docs/crew-and-items.md
§3.4, §4.4).

    python3 tools/gen_iva.py            # textures, meshes (Blender), prefabs
    python3 tools/gen_iva.py --tex      # textures only
    python3 tools/gen_iva.py --no-tex   # meshes and prefabs only

One file, two halves. Run by system Python it draws the texture atlases
(numpy + Pillow), runs ITSELF headless in Blender (the Steam install, or
$BLENDER) to build the geometry, and turns Blender's triangles into .glb
files and prefabs. Inside Blender (`import bpy` works) it only builds and
writes triangles to a JSON file.

WHAT IS MADE

    models/iva/<iva>.glb          the cabin: walls, windows, hatch, seats,
                                  consoles, stowage — one mesh, few materials
    models/iva/self.glb           the wearer's own legs and gloves, seen
                                  when you look down from the eye seat
    models/iva/tex/*.png          padding (quilted beta cloth), the panel
                                  atlas (labels, gauges, placards) and the
                                  screen atlas (lit displays)
    prefabs/Iva<Name>.prefab.ron  a root Empty at the PART's origin, the mesh
                                  child at its box centre (the engine recentres
                                  meshes), Self<k> per seat, Lamp<k> lights

THE SCALE. A Pod Mk1 is 0.8 m tall and the astronaut is 1.88 m, so a cabin
at the hull's own size could never hold a person. The interior is built at
HUMAN scale, round the part's origin, and is drawn by a camera of its own
stacked on the main one (planet_camera.lua): the main camera looks out from
the eye point inside the hull (EYE_MAIN), the interior camera from the same
direction at the human-scale eye (EYE), and the interior covers everything
but its windows. Nothing outside is ever drawn over or through it, and the
interior is never drawn by the main camera (it lives on the `interior`
layer). The same rooms are what the portrait cameras film.

THE FRAME. Each IVA is modelled in its SEAT frame: +X the crew's right, +Y
up, -Z the way the crew faces (the windows), metres, origin at the part's
origin. BASIS maps that frame onto the part's own (the Swift cockpit flies
nose +Y with its canopy on -Z). Seats are hip points (the CrewDoll's node,
which is the rig's hip: scripts/command_seat.lua) and a facing yaw about +Y
(0 = -Z); scripts/iva.lua reads the same numbers from the prefab's Seat<k>
empties.

TEXEL DENSITY. Every tiled material is mapped in metres at 1024 px per metre
(paint 1 m tiles, metal/tread/rubber/foil 0.5 m, padding 1 m), whatever the
object, so a bolt head is the same size on a hatch as on a console. Atlas
plates (labels, gauges, screens) are mapped to their cells; they run finer
(about 2,500 px/m) because they are read from 0.6 m. Everything is smooth
filtered (project.ron model_texture_filter: Smooth; the prefabs name PNGs).
"""
import json
import math
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_MODELS = os.path.join(ROOT, "models", "iva")
OUT_TEX = os.path.join(OUT_MODELS, "tex")
OUT_PREFABS = os.path.join(ROOT, "prefabs")
TEX = "models/iva/tex/"
PT = "textures/parts/"
BLENDER = os.environ.get("BLENDER", "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender")

try:
    import bpy  # noqa: F401
    IN_BLENDER = True
except ImportError:
    IN_BLENDER = False

# ── shared tables (both halves read these) ───────────────────────────────────

# Panel atlas (lit), 2048², cell = (x, y, w, h) px from the top left.
PANEL = {
    "sw_main":  (0,    0,    1024, 256),   # MAIN BUS / FUEL CELL toggles
    "sw_rcs":   (1024, 0,    1024, 256),   # RCS / SAS toggles
    "sw_pyro":  (0,    256,  1024, 256),   # PYRO ARM / CHUTE (red guards)
    "sw_comm":  (1024, 256,  1024, 256),   # COMM / LIGHTS
    "cb":       (0,    512,  1024, 512),   # circuit breaker panel
    "keypad":   (1024, 512,  512,  512),   # the nav keypad
    "blank":    (1536, 512,  512,  512),   # plain panel with screws
    "g0":       (0,    1024, 256,  256),   # gauge faces (round)
    "g1":       (256,  1024, 256,  256),
    "g2":       (512,  1024, 256,  256),
    "g3":       (768,  1024, 256,  256),
    "g4":       (0,    1280, 256,  256),
    "g5":       (256,  1280, 256,  256),
    "g6":       (512,  1280, 256,  256),
    "g7":       (768,  1280, 256,  256),
    "fire":     (1024, 1024, 256,  128),   # placards
    "o2":       (1280, 1024, 256,  128),
    "hatch":    (1536, 1024, 512,  128),
    "pyro":     (1024, 1152, 512,  128),
    "nostep":   (1536, 1152, 256,  128),
    "serial":   (1792, 1152, 256,  128),
    "hazard":   (1024, 1280, 512,  64),
    "emerg":    (1024, 1344, 512,  192),
    "grille":   (1536, 1280, 512,  256),
    "stow":     (0,    1536, 512,  128),
    "stow2":    (512,  1536, 512,  128),
    "sidecon":  (1024, 1536, 1024, 256),   # the jet's side console
    "eject":    (0,    1664, 512,  128),
    "flight":   (512,  1664, 512,  128),
    "rotary":   (0,    1792, 1024, 256),   # rotary-knob panel
    "warnlist": (1024, 1792, 1024, 256),   # checklist card
}
PANEL_SIZE = 2048

# Screen atlas (unlit, glowing), 1024².
SCREEN = {
    "adi":    (0,   0,   512, 512),
    "orbit":  (512, 0,   512, 512),
    "sys":    (0,   512, 512, 256),
    "eng":    (512, 512, 512, 256),
    "annun":  (0,   768, 512, 256),
    "dsky":   (512, 768, 256, 128),
    "radar":  (768, 768, 256, 256),
    "clock":  (512, 896, 256, 128),
}
SCREEN_SIZE = 1024

# Every interior. seats: hip point (seat frame) and yaw (0 faces -Z, + turns
# toward +X... i.e. facing (sin yaw, 0, -cos yaw)). eye: the eye seat's eye
# in the seat frame (the IVA camera); eye_main: the main camera's eye in the
# PART frame (inside the hull, at its window). basis: the part-frame images
# of the seat frame's X, Y, Z. lamps: point lights (seat frame).
IVAS = {
    "IvaPodMk1": dict(part="pod", label="Pod Mk1", basis=((1, 0, 0), (0, 1, 0), (0, 0, 1)),
                      seats=[(0.0, -0.22, 0.16, 0.0)],
                      eye_main=(0.0, 0.02, 0.06),
                      lamps=[(0.0, 0.78, -0.05), (0.0, 0.05, 0.62)]),
    "IvaPodMk2": dict(part="podMk2", label="Pod Mk2", basis=((1, 0, 0), (0, 1, 0), (0, 0, 1)),
                      seats=[(0.0, -0.28, 0.22, 0.0), (-0.66, -0.28, 0.16, -0.30), (0.66, -0.28, 0.16, 0.30)],
                      eye_main=(0.0, 0.06, 0.04),
                      lamps=[(0.0, 0.92, 0.0), (-0.75, 0.55, -0.35), (0.75, 0.55, -0.35)]),
    "IvaCabin":  dict(part="cabin", label="Crew Cabin", basis=((1, 0, 0), (0, 1, 0), (0, 0, 1)),
                      seats=[(-0.44, -0.30, 0.64, 0.0), (0.44, -0.30, 0.64, 0.0),
                             (0.44, -0.30, -0.64, math.pi), (-0.44, -0.30, -0.64, math.pi)],
                      eye_main=(0.0, 0.18, 0.0),
                      lamps=[(0.0, 0.95, 0.0), (-0.95, 0.5, 0.0)]),
    # The Swift cockpit: nose +Y, canopy on -Z (the pilot's up), so the seat
    # frame's X -> part -X, Y -> part -Z, Z -> part -Y.
    "IvaCockpit": dict(part="cockpit", label="Swift Cockpit", basis=((-1, 0, 0), (0, 0, -1), (0, -1, 0)),
                       seats=[(0.0, -0.20, 0.30, 0.0)],
                       eye_main=(0.0, 0.10, -0.40),
                       lamps=[(0.0, 0.25, -0.35)]),
}
# The seated doll's numbers (scripts/command_seat.lua): the rig's hip is the
# node; eyes 0.77 m above it and 0.08 forward; feet 0.42 out, 0.55 down.
EYE_UP, EYE_FWD = 0.77, 0.07


def eye_of(seat):
    x, y, z, yaw = seat
    return (x + math.sin(yaw) * EYE_FWD, y + EYE_UP, z - math.cos(yaw) * EYE_FWD)


# ═════════════════════════════════════════════════════════════════════════════
# BLENDER HALF: the geometry
# ═════════════════════════════════════════════════════════════════════════════
if IN_BLENDER:
    import bmesh
    from mathutils import Matrix, Vector

    # metres per texture repeat -> uv scale (repeats per metre), per material:
    # 1024 px per metre on every tiled texture.
    UVM = {"Padding": 1.0, "Cushion": 1.0, "Paint": 1.0, "PanelPaint": 1.0, "Metal": 2.0, "Dark": 2.0,
           "Chrome": 2.0, "Tread": 2.0, "Rubber": 2.0, "Foil": 2.0, "Strap": 2.0, "Suit": 2.0,
           "Yellow": 1.0, "Red": 1.0, "Glass": 1.0, "Lamp": 1.0, "Hose": 2.0}
    ATLAS_MATS = {"Panel": (PANEL, PANEL_SIZE), "Gauge": (PANEL, PANEL_SIZE), "Screen": (SCREEN, SCREEN_SIZE)}

    OBJS = []      # (object, node, uvmode)
    CUTTERS = []

    def reset():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        OBJS.clear()
        CUTTERS.clear()

    def mat(name):
        m = bpy.data.materials.get(name)
        return m or bpy.data.materials.new(name)

    def finish(bm, name, material, node="Shell", bevel=0.0, segs=2, smooth=False, uv="box", sharp=35.0,
               mats=None):
        me = bpy.data.meshes.new(name)
        bm.normal_update()
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        me.materials.append(mat(material))
        for extra in (mats or []):
            me.materials.append(mat(extra))
        for p in me.polygons:
            p.use_smooth = smooth or bevel > 0
        if smooth or bevel > 0:
            me.set_sharp_from_angle(angle=math.radians(sharp))
        if bevel > 0:
            md = ob.modifiers.new("bevel", "BEVEL")
            md.width = bevel
            md.segments = segs
            md.limit_method = "ANGLE"
            md.angle_limit = math.radians(40)
            md.harden_normals = True
        OBJS.append((ob, node, uv))
        return ob

    def M3(right, up, back):
        """A rotation whose columns are the given axes."""
        return Matrix((right, up, back)).transposed()

    def frame(n, up_hint=(0, 1, 0)):
        """Axes (t, u, n) with n the given normal (the plate's front) and u as
        close to up_hint as possible."""
        n = Vector(n).normalized()
        u = Vector(up_hint)
        u = (u - n * u.dot(n))
        if u.length < 1e-4:
            u = Vector((0, 0, -1)) - n * (-n.z)
        u.normalize()
        t = u.cross(n).normalized()
        return t, u, n

    def place(bm, center, R=None, S=None):
        T = Matrix.Translation(Vector(center))
        Rm = R.to_4x4() if R is not None else Matrix.Identity(4)
        Sm = Matrix.Diagonal((S[0], S[1], S[2], 1.0)) if S is not None else Matrix.Identity(4)
        bmesh.ops.transform(bm, matrix=T @ Rm @ Sm, verts=bm.verts)

    # ── primitives ──────────────────────────────────────────────────────────
    def box(name, m_, center, size, R=None, bevel=0.0, node="Shell", segs=2, smooth=False):
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        place(bm, center, R, size)
        if min(size) < 0.01:
            bevel = 0.0
        return finish(bm, name, m_, node, bevel=min(bevel, min(size) * 0.45), segs=segs, smooth=smooth)

    def cushion(name, m_, center, size, R=None, round_=0.035, node="Shell"):
        """A padded block: a box with a deep rounded bevel (3 segments)."""
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        place(bm, center, R, size)
        return finish(bm, name, m_, node, bevel=min(round_, min(size) * 0.45), segs=3)

    def cyl(name, m_, p0, p1, r, segs=12, r1=None, node="Shell", caps=True, bevel=0.0, smooth=True):
        p0, p1 = Vector(p0), Vector(p1)
        d = p1 - p0
        L = d.length
        if L < 1e-6:
            return None
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=segs, radius1=r,
                              radius2=(r if r1 is None else r1), depth=L)
        q = Vector((0, 0, 1)).rotation_difference(d.normalized())
        place(bm, (p0 + p1) / 2, q.to_matrix())
        return finish(bm, name, m_, node, bevel=bevel, smooth=smooth, sharp=50.0)

    def tube_path(name, m_, pts, r, sides=8, node="Shell", closed=False):
        """A swept round tube through points (cables, hoses, bent rails)."""
        pts = [Vector(p) for p in pts]
        bm = bmesh.new()
        rings = []
        prev_side = None
        for i, p in enumerate(pts):
            if i == 0:
                d = pts[1] - pts[0]
            elif i == len(pts) - 1:
                d = pts[-1] - pts[-2]
            else:
                d = (pts[i + 1] - pts[i - 1])
            d.normalize()
            if prev_side is None:
                side = d.cross(Vector((0, 1, 0)) if abs(d.y) < 0.9 else Vector((1, 0, 0))).normalized()
            else:
                side = (prev_side - d * prev_side.dot(d)).normalized()
            prev_side = side
            up = side.cross(d).normalized()
            ring = []
            for k in range(sides):
                a = 2 * math.pi * k / sides
                ring.append(bm.verts.new(p + side * (math.cos(a) * r) + up * (math.sin(a) * r)))
            rings.append(ring)
        for i in range(len(rings) - 1):
            a, b = rings[i], rings[i + 1]
            for k in range(sides):
                k2 = (k + 1) % sides
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
        if not closed:
            bm.faces.new(list(reversed(rings[0])))
            bm.faces.new(rings[-1])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        return finish(bm, name, m_, node, smooth=True, sharp=70.0)

    def lathe(name, m_, prof, segs=48, node="Shell", a0=0.0, a1=2 * math.pi, flip=False, smooth=True, uv="cyl",
              cap0=False, cap1=False):
        """A surface of revolution about +Y: prof = [(r, y), ...]; the angle
        runs from the front (-Z) toward +X. The faces' front is (around) ×
        (along the profile): a profile running UP faces the axis (a cabin
        wall); `flip` turns them round (a bottle, a ring)."""
        bm = bmesh.new()
        full = abs((a1 - a0) - 2 * math.pi) < 1e-6
        n = segs if full else segs + 1
        rows = []
        for (r, y) in prof:
            row = []
            for i in range(n):
                a = a0 + (a1 - a0) * i / segs
                row.append(bm.verts.new((r * math.sin(a), y, -r * math.cos(a))))
            rows.append(row)
        for j in range(len(rows) - 1):
            for i in range(segs):
                i2 = (i + 1) % n if full else i + 1
                f = (rows[j][i], rows[j][i2], rows[j + 1][i2], rows[j + 1][i])
                if len(set(v.co.to_tuple(6) for v in f)) < 3:
                    continue
                try:
                    bm.faces.new(f if not flip else tuple(reversed(f)))
                except ValueError:
                    pass
        if cap0 and full:
            bm.faces.new(rows[0] if flip else list(reversed(rows[0])))
        if cap1 and full:
            bm.faces.new(list(reversed(rows[-1])) if flip else rows[-1])
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
        return finish(bm, name, m_, node, smooth=smooth, uv=uv, sharp=40.0)

    def ring(name, m_, center, n, r_in, r_out, depth, segs=24, node="Shell", bevel=0.0):
        """A flat annulus with depth, its axis along n (bezels, hatch rims)."""
        prof = [(r_in, 0.0), (r_out, 0.0), (r_out, depth), (r_in, depth), (r_in, 0.0)]
        ob = lathe(name, m_, prof, segs=segs, node=node, uv="box", flip=True)
        t, u, nn = frame(n)
        # the lathe's axis (+Y) onto n
        R = Matrix((t, u, nn)).transposed() @ Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
        ob.matrix_world = Matrix.Translation(Vector(center)) @ R.to_4x4()
        if bevel:
            md = ob.modifiers.new("bevel", "BEVEL")
            md.width = bevel
            md.segments = 2
        return ob

    def disc(name, m_, center, n, r, segs=24, node="Shell", cell=None, atlas=None):
        """A flat disc facing n; with `cell` its UVs map the circle into that
        atlas cell (a gauge face)."""
        bm = bmesh.new()
        t, u, nn = frame(n)
        c = Vector(center)
        ctr = bm.verts.new(c)
        rim = [bm.verts.new(c + t * (r * math.cos(2 * math.pi * k / segs)) + u * (r * math.sin(2 * math.pi * k / segs)))
               for k in range(segs)]
        for k in range(segs):
            bm.faces.new((ctr, rim[k], rim[(k + 1) % segs]))
        uvmode = "box"
        if cell is not None:
            uvl = bm.loops.layers.uv.new("UVMap")
            cx, cy, cw, ch = atlas[0][cell]
            S = atlas[1]
            for f in bm.faces:
                for lp in f.loops:
                    d = lp.vert.co - c
                    a, b = d.dot(t) / r, d.dot(u) / r
                    lp[uvl].uv = ((cx + cw * (0.5 + 0.5 * a * 0.98)) / S, (cy + ch * (0.5 - 0.5 * b * 0.98)) / S)
            uvmode = "atlas"
        return finish(bm, name, m_, node, uv=uvmode)

    def plate(name, m_, center, n, w, h, cell=None, atlas=None, node="Shell", up=(0, 1, 0), lift=0.0, flipu=False):
        """A flat quad facing n (a label, a screen, a placard), mapped onto an
        atlas cell (or box-mapped without one)."""
        bm = bmesh.new()
        t, u, nn = frame(n, up)
        c = Vector(center) + nn * lift
        vs = [bm.verts.new(c + t * (sx * w / 2) + u * (sy * h / 2)) for (sx, sy) in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        f = bm.faces.new(vs)
        uvmode = "box"
        if cell is not None:
            uvl = bm.loops.layers.uv.new("UVMap")
            cx, cy, cw, ch = atlas[0][cell]
            S = atlas[1]
            pad = 1.5
            for lp, (sx, sy) in zip(f.loops, ((-1, -1), (1, -1), (1, 1), (-1, 1))):
                if flipu:
                    sx = -sx
                lp[uvl].uv = ((cx + pad + (cw - 2 * pad) * (sx + 1) / 2) / S, (cy + pad + (ch - 2 * pad) * (1 - sy) / 2) / S)
            uvmode = "atlas"
        return finish(bm, name, m_, node, uv=uvmode)

    def P(cell):
        return (PANEL, PANEL_SIZE) if cell in PANEL else (SCREEN, SCREEN_SIZE)

    # ── fixtures ────────────────────────────────────────────────────────────
    def screws(name, center, n, w, h, inset=0.012, up=(0, 1, 0), r=0.0045):
        t, u, nn = frame(n, up)
        c = Vector(center)
        for sx in (-1, 1):
            for sy in (-1, 1):
                p = c + t * (sx * (w / 2 - inset)) + u * (sy * (h / 2 - inset))
                cyl(name, "Chrome", p - nn * 0.001, p + nn * 0.003, r, segs=6, r1=r * 0.8)

    def panel_face(name, center, n, w, h, cell, up=(0, 1, 0), depth=0.03, body="PanelPaint", bevel=0.004,
                   screwed=True):
        """A panel set on a surface: a painted backing box and the atlas face."""
        t, u, nn = frame(n, up)
        R = M3(t, u, nn)
        box(name + "Body", body, Vector(center) - nn * (depth / 2), (w + 0.012, h + 0.012, depth), R, bevel=bevel)
        plate(name, "Panel", Vector(center) + nn * 0.0012, n, w, h, cell, P(cell), up=up)
        if screwed:
            screws(name + "Scr", Vector(center) + nn * 0.001, n, w + 0.012, h + 0.012, up=up)
        return t, u, nn

    def toggles(name, center, n, w, count, up=(0, 1, 0), guard=None, lever=0.022):
        """A row of toggle switches across width w: hex bush, lever, ball tip
        (some thrown up, some down); `guard` = indices with a red flip guard."""
        t, u, nn = frame(n, up)
        c = Vector(center)
        for k in range(count):
            x = (k - (count - 1) / 2) * (w / count)
            p = c + t * x
            cyl(name + "Bush", "Chrome", p, p + nn * 0.007, 0.0055, segs=6)
            ang = 0.45 if ((k * 7 + count) % 3) else -0.45
            tip = p + nn * (0.007 + lever * math.cos(ang)) + u * (lever * math.sin(ang))
            cyl(name + "Lever", "Chrome", p + nn * 0.006, tip, 0.0018, segs=6, r1=0.0024)
            bm = bmesh.new()
            bmesh.ops.create_uvsphere(bm, u_segments=6, v_segments=4, radius=0.0035)
            place(bm, tip)
            finish(bm, name + "Tip", "Chrome", smooth=True)
            if guard and k in guard:
                g = p + nn * 0.012
                box(name + "Guard", "Red", g + u * 0.002, (w / count * 0.7, 0.032, 0.024), M3(t, u, nn), bevel=0.003)

    def knobs(name, center, n, w, count, up=(0, 1, 0), r=0.011):
        t, u, nn = frame(n, up)
        c = Vector(center)
        for k in range(count):
            p = c + t * ((k - (count - 1) / 2) * (w / count))
            cyl(name, "Dark", p, p + nn * 0.016, r, segs=10, r1=r * 0.85)
            cyl(name + "Ptr", "Chrome", p + nn * 0.016 + u * (r * 0.3), p + nn * 0.017 + u * (r * 0.8), 0.0016, segs=4)

    def breakers(name, center, n, w, h, cols, rows, up=(0, 1, 0)):
        t, u, nn = frame(n, up)
        c = Vector(center)
        for i in range(cols):
            for j in range(rows):
                p = c + t * ((i - (cols - 1) / 2) * (w / cols)) + u * ((j - (rows - 1) / 2) * (h / rows) - 0.006)
                out = 0.004 if (i * 3 + j * 5) % 11 == 0 else 0.0
                cyl(name, "Dark", p, p + nn * (0.009 + out), 0.0048, segs=6)
                if out:
                    cyl(name + "W", "Chrome", p + nn * 0.009, p + nn * (0.009 + out), 0.0044, segs=6)

    def gauge(name, center, n, r, cell, up=(0, 1, 0), depth=0.02):
        t, u, nn = frame(n, up)
        c = Vector(center)
        cyl(name + "Can", "Dark", c - nn * depth, c + nn * 0.002, r + 0.006, segs=20)
        ring(name + "Bezel", "Chrome", c + nn * 0.001, nn, r - 0.001, r + 0.009, 0.007, segs=24)
        disc(name, "Gauge", c + nn * 0.0035, nn, r, segs=24, cell=cell, atlas=(PANEL, PANEL_SIZE))
        disc(name + "Glass", "Glass", c + nn * 0.0075, nn, r, segs=16)

    def screen(name, center, n, w, h, cell, up=(0, 1, 0), bezel=0.016, buttons=5):
        """A display: a deep bezel, the glowing face, push buttons below/above."""
        t, u, nn = frame(n, up)
        R = M3(t, u, nn)
        c = Vector(center)
        box(name + "Bezel", "Dark", c - nn * 0.012, (w + 2 * bezel, h + 2 * bezel + 0.03, 0.03), R, bevel=0.004)
        plate(name, "Screen", c + nn * 0.0035, n, w, h, cell, (SCREEN, SCREEN_SIZE), up=up)
        plate(name + "Glass", "Glass", c + nn * 0.006, n, w, h, None, None, up=up)
        for k in range(buttons):
            x = (k - (buttons - 1) / 2) * (w / buttons)
            for s in (-1, 1):
                p = c + t * x + u * (s * (h / 2 + bezel * 0.5 + 0.008))
                box(name + "Btn", "Rubber", p + nn * 0.004, (w / buttons * 0.6, 0.009, 0.008), R, bevel=0.002)

    def handhold(name, p0, p1, n, stand=0.045, r=0.011, m_="Yellow"):
        """A bent grab bar standing off a surface (n = out of the surface)."""
        p0, p1, nn = Vector(p0), Vector(p1), Vector(n).normalized()
        d = p1 - p0
        pts = [p0, p0 + nn * (stand * 0.7) + d * 0.04, p0 + nn * stand + d * 0.15, p1 + nn * stand - d * 0.15,
               p1 + nn * (stand * 0.7) - d * 0.04, p1]
        tube_path(name, m_, pts, r, sides=8)
        for p in (p0, p1):
            cyl(name + "Foot", "Metal", p - nn * 0.004, p + nn * 0.01, r * 1.8, segs=8)

    def lamp(name, center, n, w=0.16, h=0.06, up=(0, 1, 0)):
        """A flood lamp: a metal housing, a frosted glowing lens, a grille."""
        t, u, nn = frame(n, up)
        R = M3(t, u, nn)
        c = Vector(center)
        box(name + "Housing", "Dark", c - nn * 0.012, (w + 0.02, h + 0.02, 0.03), R, bevel=0.006)
        plate(name, "Lamp", c + nn * 0.004, n, w, h, None, None, up=up)
        for k in range(5):
            x = (k - 2) * (w / 5)
            box(name + "Bar", "Metal", c + t * x + nn * 0.007, (0.003, h, 0.004), R)

    def stow_bag(name, center, size, R=None, strap_n=2, m_="Cushion"):
        """A soft stowage bag: a puffy block with webbing straps and a buckle."""
        cushion(name, m_, center, size, R, round_=min(size) * 0.3)
        R = R or Matrix.Identity(3)
        c = Vector(center)
        for k in range(strap_n):
            x = (k - (strap_n - 1) / 2) * (size[0] / max(strap_n, 1)) * 0.8
            box(name + "Strap", "Strap", c + R @ Vector((x, 0, 0)), (0.025, size[1] + 0.008, size[2] + 0.008), R)
            box(name + "Buckle", "Chrome", c + R @ Vector((x, size[1] * 0.1, size[2] / 2 + 0.006)), (0.035, 0.03, 0.006), R)

    def bottle(name, base, axis, r, L, m_="Paint", neck="Chrome"):
        """A pressure bottle: a domed cylinder, a valve and its handwheel."""
        base, axis = Vector(base), Vector(axis).normalized()
        prof = [(0.0, 0.0), (r * 0.7, 0.004), (r, r * 0.35), (r, L - r * 0.6), (r * 0.75, L - r * 0.15), (r * 0.25, L)]
        ob = lathe(name, m_, prof, segs=16, uv="box", flip=True)
        q = Vector((0, 1, 0)).rotation_difference(axis)
        ob.matrix_world = Matrix.Translation(base) @ q.to_matrix().to_4x4()
        top = base + axis * L
        cyl(name + "Valve", neck, top, top + axis * 0.04, r * 0.22, segs=8)
        t, u, nn = frame(axis)
        ring(name + "Wheel", neck, top + axis * 0.03, axis, r * 0.35, r * 0.45, 0.006, segs=12)

    def extinguisher(name, base, axis):
        bottle(name, base, axis, 0.045, 0.30, m_="Red", neck="Dark")
        a = Vector(axis).normalized()
        top = Vector(base) + a * 0.33
        t, u, nn = frame(a)
        tube_path(name + "Hose", "Rubber", [top, top + t * 0.05 + a * 0.02, top + t * 0.07 - a * 0.1,
                                             top + t * 0.06 - a * 0.22], 0.008, sides=6)
        plate(name + "Tag", "Panel", Vector(base) + a * 0.16 + nn * 0.0 - t * 0.046, -t, 0.06, 0.03, "fire",
              (PANEL, PANEL_SIZE), up=tuple(a))

    def cable_run(name, pts, count=3, r=0.007, spread=0.016, m_="Hose"):
        """A loom of cables along a path, clamped every ~0.25 m."""
        base = [Vector(p) for p in pts]
        for k in range(count):
            off = Vector(((k - (count - 1) / 2) * spread, 0, 0))
            tube_path(name, m_ if k % 2 == 0 else "Rubber", [p + off for p in base], r, sides=6)
        for i in range(0, len(base) - 1, 4 if len(base) > 6 else 1):
            mid = (base[i] + base[i + 1]) / 2
            d = (base[i + 1] - base[i]).normalized()
            t, u, nn = frame(d)
            box(name + "Clamp", "Metal", mid, (spread * count + 0.012, 0.012, 0.022), M3(u.cross(d), d, u))

    def net(name, center, n, w, h, up=(0, 1, 0), cells=5):
        """A bungee stowage net over a recess."""
        t, u, nn = frame(n, up)
        c = Vector(center) + nn * 0.02
        for i in range(cells + 1):
            x = (i / cells - 0.5) * w
            cyl(name, "Strap", c + t * x - u * (h / 2), c + t * x + u * (h / 2), 0.003, segs=4)
        for j in range(cells + 1):
            y = (j / cells - 0.5) * h
            cyl(name, "Strap", c - t * (w / 2) + u * y, c + t * (w / 2) + u * y, 0.003, segs=4)
        for sx in (-1, 1):
            for sy in (-1, 1):
                cyl(name + "Hook", "Chrome", c + t * (sx * w / 2) + u * (sy * h / 2) - nn * 0.02,
                    c + t * (sx * w / 2) + u * (sy * h / 2), 0.005, segs=6)

    def vent(name, center, n, w, h, up=(0, 1, 0)):
        t, u, nn = frame(n, up)
        R = M3(t, u, nn)
        c = Vector(center)
        box(name + "Frame", "Metal", c - nn * 0.006, (w + 0.02, h + 0.02, 0.014), R, bevel=0.003)
        plate(name, "Panel", c + nn * 0.002, n, w, h, "grille", (PANEL, PANEL_SIZE), up=up)
        for k in range(6):
            y = (k - 2.5) * (h / 6)
            box(name + "Slat", "Dark", c + u * y + nn * 0.004, (w, 0.004, 0.008), R @ Matrix.Rotation(0.5, 3, "X"))

    # ── the seat (a crew couch) ─────────────────────────────────────────────
    def couch(name, hip, yaw, controller=True, jet=False, wide=0.50):
        """A crew couch for a seated hip at `hip`, facing yaw: a tubular frame,
        seat pan and back cushions with side bolsters, headrest, a five-point
        harness lying open, a footrest and the armrests (a hand controller on
        the right, a T-handle on the left)."""
        hip = Vector(hip)
        Ry = Matrix.Rotation(-yaw, 3, "Y")      # yaw turns -Z toward +X

        def L(x, y, z):
            return hip + Ry @ Vector((x, y, z))
        Rb = Ry @ Matrix.Rotation(math.radians(14), 3, "X")    # backrest leans back
        pan_y = -0.15
        cushion(name + "Pan", "Cushion", L(0, pan_y, -0.02), (wide - 0.06, 0.08, 0.46), Ry, round_=0.03)
        cushion(name + "Back", "Cushion", L(0, 0.24, 0.30), (wide - 0.06, 0.70, 0.09), Rb, round_=0.03)
        cushion(name + "Head", "Cushion", L(0, 0.80, 0.40), (0.26, 0.20, 0.08), Rb, round_=0.03)
        for s in (-1, 1):
            cushion(name + "Bolster", "Cushion", L(s * (wide / 2 - 0.02), 0.20, 0.26), (0.07, 0.56, 0.12), Rb, round_=0.025)
            cushion(name + "PanBol", "Cushion", L(s * (wide / 2 - 0.02), pan_y + 0.03, -0.02), (0.07, 0.07, 0.42), Ry, round_=0.025)
        # frame: a welded shell behind and under the cushions
        box(name + "Shell", "PanelPaint", L(0, 0.26, 0.37), (wide, 0.78, 0.03), Rb, bevel=0.01)
        box(name + "Base", "PanelPaint", L(0, pan_y - 0.07, -0.02), (wide, 0.05, 0.50), Ry, bevel=0.01)
        for s in (-1, 1):
            cyl(name + "Leg", "Metal", L(s * (wide / 2 - 0.05), pan_y - 0.09, 0.15), L(s * (wide / 2 - 0.05), -0.62, 0.30), 0.016, segs=10)
            cyl(name + "Leg", "Metal", L(s * (wide / 2 - 0.05), pan_y - 0.09, -0.18), L(s * (wide / 2 - 0.05), -0.62, -0.22), 0.016, segs=10)
            cyl(name + "Strut", "Metal", L(s * (wide / 2 - 0.02), 0.62, 0.43), L(s * (wide / 2 - 0.03), pan_y - 0.08, 0.36), 0.013, segs=8)
        # the footrest (feet 0.42 out, 0.55 down)
        box(name + "Foot", "Tread", L(0, -0.60, -0.46), (wide - 0.08, 0.02, 0.22), Ry @ Matrix.Rotation(0.35, 3, "X"), bevel=0.004)
        for s in (-1, 1):
            cyl(name + "FootArm", "Metal", L(s * (wide / 2 - 0.06), -0.60, -0.40), L(s * (wide / 2 - 0.06), pan_y - 0.09, -0.20), 0.012, segs=8)
            box(name + "Heel", "Rubber", L(s * 0.12, -0.56, -0.36), (0.10, 0.05, 0.04), Ry, bevel=0.008)
        # harness: shoulder straps down the backrest, lap belt off the sides,
        # the crotch strap, the buckle box resting on the pan
        for s in (-1, 1):
            p0, p1 = L(s * 0.09, 0.62, 0.33), L(s * 0.12, 0.10, 0.25)
            tube_path(name + "Shoulder", "Strap", [p0, L(s * 0.10, 0.40, 0.26), p1, L(s * 0.17, pan_y + 0.06, 0.12)], 0.012, sides=4)
            tube_path(name + "Lap", "Strap", [L(s * (wide / 2 - 0.03), pan_y + 0.03, 0.10), L(s * 0.24, pan_y + 0.06, -0.02),
                                              L(s * 0.25, pan_y + 0.02, -0.10)], 0.012, sides=4)
            box(name + "Adj", "Chrome", L(s * 0.10, 0.38, 0.27), (0.035, 0.03, 0.008), Rb)
        tube_path(name + "Crotch", "Strap", [L(0, pan_y + 0.04, -0.18), L(0, pan_y + 0.05, -0.24)], 0.012, sides=4)
        box(name + "Buckle", "Chrome", L(0, pan_y + 0.06, -0.25), (0.07, 0.02, 0.07), Ry, bevel=0.006)
        # armrests and the hand controllers
        for s in (-1, 1):
            cushion(name + "Arm", "Cushion", L(s * (wide / 2 + 0.05), 0.02, 0.0), (0.08, 0.05, 0.36), Ry, round_=0.02)
            box(name + "ArmBar", "Metal", L(s * (wide / 2 + 0.05), -0.02, 0.12), (0.03, 0.12, 0.03), Ry)
        if controller:
            # right: rotational hand controller (a pistol grip on a gimbal)
            b = L(wide / 2 + 0.05, 0.04, -0.14)
            cyl(name + "RhcBase", "Dark", b, b + Ry @ Vector((0, 0.04, 0)), 0.03, segs=14)
            ring(name + "RhcBoot", "Rubber", b + Ry @ Vector((0, 0.04, 0)), Ry @ Vector((0, 1, 0)), 0.012, 0.03, 0.012, segs=12)
            g0 = b + Ry @ Vector((0, 0.05, 0))
            g1 = b + Ry @ Vector((0, 0.15, 0.02))
            cyl(name + "RhcGrip", "Rubber", g0, g1, 0.016, segs=10, r1=0.019)
            cyl(name + "RhcTrig", "Red", g1 + Ry @ Vector((0, -0.03, -0.018)), g1 + Ry @ Vector((0, -0.01, -0.02)), 0.005, segs=6)
            box(name + "RhcTop", "Dark", g1 + Ry @ Vector((0, 0.008, 0)), (0.03, 0.016, 0.04), Ry, bevel=0.005)
            # left: translation controller (a T-handle)
            b = L(-(wide / 2 + 0.05), 0.04, -0.14)
            cyl(name + "ThcBase", "Dark", b, b + Ry @ Vector((0, 0.04, 0)), 0.026, segs=12)
            cyl(name + "ThcStem", "Chrome", b, b + Ry @ Vector((0, 0.11, 0)), 0.008, segs=8)
            cyl(name + "ThcBar", "Rubber", b + Ry @ Vector((-0.045, 0.11, 0)), b + Ry @ Vector((0.045, 0.11, 0)), 0.012, segs=10)

    # ── shells ──────────────────────────────────────────────────────────────
    def wall_at(prof, theta, y):
        """Point on the lathe wall (inner surface) at angle theta (0 = -Z,
        toward +X) and height y; inward normal, tangent, slant-up."""
        ys = [q[1] for q in prof]
        rs = [q[0] for q in prof]

        def rr(yy):
            for i in range(len(ys) - 1):
                if ys[i] <= yy <= ys[i + 1] or i == len(ys) - 2:
                    f = (yy - ys[i]) / max(ys[i + 1] - ys[i], 1e-9)
                    return rs[i] + (rs[i + 1] - rs[i]) * f
            return rs[-1]
        r = rr(y)
        dr = (rr(y + 0.01) - rr(y - 0.01)) / 0.02
        s, c = math.sin(theta), math.cos(theta)
        p = Vector((r * s, y, -r * c))
        out = Vector((s, 0, -c))
        up = Vector((dr * s, 1.0, -dr * c)).normalized()
        t = Vector((c, 0, s))
        n_out = t.cross(up).normalized()
        if n_out.dot(out) < 0:
            n_out = -n_out
        return p, -n_out, t, up

    def cutter(center, R, size):
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        me = bpy.data.meshes.new("cut")
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new("cut", me)
        bpy.context.scene.collection.objects.link(ob)
        ob.matrix_world = Matrix.Translation(Vector(center)) @ R.to_4x4() @ Matrix.Diagonal((size[0], size[1], size[2], 1.0))
        ob.hide_render = True
        CUTTERS.append(ob)
        return ob

    def shell(name, prof, cuts, segs=64, thick=0.05, m_="Padding", outer="Dark"):
        """The cabin wall: an inward-facing lathe, thickened outward (so a cut
        edge has depth, never a paper-thin slit), with every opening cut by a
        real boolean (windows, hatch)."""
        ob = lathe(name, m_, prof, segs=segs, uv="cyl")
        ob.data.materials.append(mat(outer))
        sm = ob.modifiers.new("solid", "SOLIDIFY")
        sm.thickness = thick
        sm.offset = -1.0           # grow away from the faces' front (outward)
        sm.material_offset = 1
        sm.material_offset_rim = 1
        for c in cuts:
            bo = ob.modifiers.new("cut", "BOOLEAN")
            bo.operation = "DIFFERENCE"
            bo.object = c
            bo.solver = "EXACT"
        return ob

    def window(name, prof, theta, y, w, h, cuts, round_r=0.03, frame_w=0.045, depth=0.11, shade=False):
        """A window on the wall: the opening cut through, a thick bolted frame
        proud of the padding, a tunnel (reveal) out to the hull, two panes
        (an inner scratch pane and the outer pressure pane), a lip strap."""
        p, n, t, up = wall_at(prof, theta, y)
        R = M3(t, up, n)                     # local z = into the cabin
        cuts.append(cutter(p, R, (w, h, 0.6)))
        # reveal: four plates from the padding out through the wall thickness
        for (cx, cy, sx, sy) in ((0, h / 2, w, 0.0), (0, -h / 2, w, 0.0), (w / 2, 0, 0.0, h), (-w / 2, 0, 0.0, h)):
            c = p + t * cx + up * cy - n * (depth / 2 - 0.02)
            box(name + "Reveal", "Dark", c, (max(sx, 0.006), max(sy, 0.006), depth), R)
        # frame (four bevelled bars) and its bolts
        for (cx, cy, sx, sy) in ((0, h / 2 + frame_w / 2, w + 2 * frame_w, frame_w), (0, -h / 2 - frame_w / 2, w + 2 * frame_w, frame_w),
                                 (w / 2 + frame_w / 2, 0, frame_w, h), (-w / 2 - frame_w / 2, 0, frame_w, h)):
            c = p + t * cx + up * cy + n * 0.012
            box(name + "Frame", "Metal", c, (sx, sy, 0.03), R, bevel=0.005)
            nb = max(2, int(max(sx, sy) / 0.07))
            for k in range(nb):
                f = (k + 0.5) / nb - 0.5
                q = c + (t * (sx * f) if sx > sy else up * (sy * f)) + n * 0.015
                cyl(name + "Bolt", "Chrome", q - n * 0.002, q + n * 0.005, 0.0055, segs=6)
        plate(name + "PaneIn", "Glass", p - n * 0.01, n, w, h, None, None, up=tuple(up))
        plate(name + "PaneOut", "Glass", p - n * (depth - 0.02), n, w, h, None, None, up=tuple(up))
        if shade:
            # a rolled-up sun shade over the window
            c = p + up * (h / 2 + frame_w + 0.025) + n * 0.03
            cyl(name + "Shade", "Cushion", c - t * (w / 2 + 0.02), c + t * (w / 2 + 0.02), 0.02, segs=12)
            box(name + "ShadeTab", "Strap", c - up * 0.03 + n * 0.01, (0.05, 0.05, 0.004), R)
        return p, n, t, up

    def hatch(name, prof, theta, y, w, h, cuts, round_=True):
        """The side hatch, from the inside: the opening cut, a heavy door plate
        set in it, a bolted coaming, the handwheel on its spindle, latch dogs,
        hinges, a placard and the jettison T-handle under a guard."""
        p, n, t, up = wall_at(prof, theta, y)
        R = M3(t, up, n)
        cuts.append(cutter(p, R, (w, h, 0.6)))
        box(name + "Door", "PanelPaint", p - n * 0.05, (w + 0.01, h + 0.01, 0.05), R, bevel=0.012)
        box(name + "DoorPad", "Padding", p - n * 0.022, (w - 0.08, h - 0.08, 0.02), R, bevel=0.008)
        cw = 0.06
        for (cx, cy, sx, sy) in ((0, h / 2 + cw / 2, w + 2 * cw, cw), (0, -h / 2 - cw / 2, w + 2 * cw, cw),
                                 (w / 2 + cw / 2, 0, cw, h), (-w / 2 - cw / 2, 0, cw, h)):
            c = p + t * cx + up * cy + n * 0.015
            box(name + "Coaming", "Metal", c, (sx, sy, 0.04), R, bevel=0.008)
            nb = max(2, int(max(sx, sy) / 0.08))
            for k in range(nb):
                f = (k + 0.5) / nb - 0.5
                q = c + (t * (sx * f) if sx > sy else up * (sy * f)) + n * 0.02
                cyl(name + "Bolt", "Chrome", q - n * 0.002, q + n * 0.006, 0.006, segs=6)
        hc = p + n * 0.005
        cyl(name + "Spindle", "Chrome", hc - n * 0.02, hc + n * 0.06, 0.012, segs=10)
        ring(name + "Wheel", "Metal", hc + n * 0.06, n, 0.09, 0.105, 0.016, segs=28, bevel=0.003)
        for k in range(4):
            a = math.pi / 4 + k * math.pi / 2
            d = t * math.cos(a) + up * math.sin(a)
            cyl(name + "Spoke", "Metal", hc + n * 0.066, hc + n * 0.066 + d * 0.095, 0.008, segs=6)
        cyl(name + "Knob", "Rubber", hc + n * 0.066 + t * 0.098, hc + n * 0.12 + t * 0.098, 0.012, segs=8)
        for (sx, sy) in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            q = p + t * (sx * (w / 2 - 0.02)) + up * (sy * (h / 2 - 0.02)) + n * 0.03
            box(name + "Dog", "Chrome", q, (0.05 if sy else 0.03, 0.03 if sy else 0.05, 0.02), R, bevel=0.004)
            cyl(name + "Rod", "Chrome", hc + n * 0.02, q, 0.005, segs=6)
        for k in (-0.3, 0.3):
            q = p - t * (w / 2 + cw * 0.5) + up * (h * k) + n * 0.05
            cyl(name + "Hinge", "Metal", q - up * 0.05, q + up * 0.05, 0.018, segs=10)
        plate(name + "Placard", "Panel", p + up * (h / 2 + cw + 0.05) + n * 0.002, n, 0.24, 0.06, "hatch", (PANEL, PANEL_SIZE), up=tuple(up))
        jt = p + t * (w / 2 + cw + 0.07) - up * 0.08
        box(name + "JetGuard", "Red", jt + n * 0.01, (0.07, 0.11, 0.02), R, bevel=0.005)
        cyl(name + "JetT", "Yellow", jt + n * 0.02 - up * 0.03, jt + n * 0.02 + up * 0.03, 0.008, segs=8)
        plate(name + "Pyro", "Panel", jt - up * 0.09 + n * 0.002, n, 0.12, 0.03, "pyro", (PANEL, PANEL_SIZE), up=tuple(up))
        return p, n, t, up

    def floor_disc(name, y, r, m_="Tread", up=True):
        bm = bmesh.new()
        segs = 40
        ctr = bm.verts.new((0, y, 0))
        rim = [bm.verts.new((r * math.sin(2 * math.pi * k / segs), y, -r * math.cos(2 * math.pi * k / segs))) for k in range(segs)]
        for k in range(segs):
            f = (ctr, rim[(k + 1) % segs], rim[k]) if up else (ctr, rim[k], rim[(k + 1) % segs])
            bm.faces.new(f)
        bm.normal_update()
        return finish(bm, name, m_)

    def ceiling_tunnel(name, y, r_open, r_ceiling, h=0.35, rungs=4):
        """The docking/chute tunnel through the top: a ring ceiling with a
        circular opening, a short metal tunnel closed by the upper hatch."""
        lathe(name + "Ceil", "Padding", [(r_ceiling, y), (r_open, y)], segs=48, uv="box")
        lathe(name + "Tube", "Metal", [(r_open, y), (r_open, y + h)], segs=32, uv="cyl")
        floor_disc(name + "Lid", y + h, r_open + 0.01, m_="PanelPaint", up=False)
        ring(name + "Rim", "Metal", (0, y - 0.005, 0), (0, -1, 0), r_open - 0.01, r_open + 0.05, 0.03, segs=32, bevel=0.004)
        hc = Vector((0, y + h - 0.01, 0))
        cyl(name + "LidSpindle", "Chrome", hc, hc - Vector((0, 0.06, 0)), 0.01)
        ring(name + "LidWheel", "Metal", hc - Vector((0, 0.06, 0)), (0, -1, 0), r_open * 0.45, r_open * 0.52, 0.014, segs=24)
        for k in range(rungs):
            yy = y + 0.05 + k * (h - 0.08) / max(rungs - 1, 1)
            cyl(name + "Rung", "Yellow", (-r_open * 0.6, yy, r_open * 0.82), (r_open * 0.6, yy, r_open * 0.82), 0.01, segs=8)

    # ── the wearer (the eye seat's own legs, arms and gloves) ───────────────
    def self_body():
        """Seen only from the eye seat: thighs, knees, shins and boots down to
        the footrest, forearms to gloves on the controllers, the chest's
        control box. Hip at the origin, facing -Z."""
        node = "Self"
        for s in (-1, 1):
            hip, knee = Vector((s * 0.10, -0.02, 0.02)), Vector((s * 0.12, 0.0, -0.40))
            ankle = Vector((s * 0.12, -0.48, -0.44))
            tube_path("SelfThigh", "Suit", [hip, (hip + knee) / 2 + Vector((0, 0.02, 0)), knee], 0.085, sides=12)
            bm = bmesh.new()
            bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=6, radius=0.075)
            place(bm, knee + Vector((0, 0.01, -0.01)))
            finish(bm, "SelfKnee", "Suit", node=node, smooth=True)
            tube_path("SelfShin", "Suit", [knee, (knee + ankle) / 2, ankle], 0.065, sides=12)
            box("SelfBoot", "Rubber", ankle + Vector((0, -0.07, -0.06)), (0.12, 0.12, 0.27), bevel=0.03)
            box("SelfSole", "Dark", ankle + Vector((0, -0.13, -0.06)), (0.13, 0.03, 0.29), bevel=0.01)
            box("SelfStrapA", "Strap", ankle + Vector((0, -0.02, -0.02)), (0.13, 0.03, 0.13))
            sh, el = Vector((s * 0.21, 0.42, 0.10)), Vector((s * 0.30, 0.10, 0.06))
            wr = Vector((s * 0.30, 0.16, -0.08))
            tube_path("SelfUpper", "Suit", [sh, el], 0.06, sides=10)
            tube_path("SelfFore", "Suit", [el, (el + wr) / 2, wr], 0.052, sides=10)
            ring("SelfCuff", "Metal", wr, (0, 0.2, -1), 0.04, 0.058, 0.03, segs=14)
            cushion("SelfGlove", "Rubber", wr + Vector((0, -0.01, -0.06)), (0.085, 0.07, 0.11), round_=0.025)
            for k in range(4):
                cyl("SelfFinger", "Rubber", wr + Vector((s * 0.0 + (k - 1.5) * 0.018, 0.02, -0.12)),
                    wr + Vector(((k - 1.5) * 0.018, -0.01, -0.16)), 0.009, segs=6)
        box("SelfChestBox", "PanelPaint", Vector((0, 0.36, -0.17)), (0.20, 0.10, 0.07), bevel=0.012)
        plate("SelfChestPanel", "Panel", Vector((0, 0.38, -0.21)), (0, 0.3, -1), 0.17, 0.05, "flight", (PANEL, PANEL_SIZE))
        knobs("SelfChestKnob", Vector((0, 0.335, -0.21)), (0, 0.3, -1), 0.14, 3, r=0.008)
        tube_path("SelfHose", "Hose", [Vector((0.08, 0.34, -0.17)), Vector((0.16, 0.25, -0.12)), Vector((0.22, 0.30, 0.05))], 0.016, sides=8)
        tube_path("SelfHose", "Hose", [Vector((-0.08, 0.34, -0.17)), Vector((-0.16, 0.25, -0.12)), Vector((-0.22, 0.30, 0.05))], 0.016, sides=8)
        cushion("SelfTorso", "Suit", Vector((0, 0.30, 0.06)), (0.40, 0.42, 0.26), round_=0.08)
        # everything built here belongs to the Self node
        for i, (ob, nd, uvm) in enumerate(OBJS):
            OBJS[i] = (ob, "Self", uvm)

    # ── the interiors ───────────────────────────────────────────────────────
    def common_seat_dressing(key, seats, controller_slots=(0,)):
        for i, (x, y, z, yaw) in enumerate(seats):
            couch("Couch%d" % (i + 1), (x, y, z), yaw, controller=i in controller_slots)

    def iva_pod_mk1():
        """Pod Mk1, one seat: a truncated cone 2.0 m across the floor, 1.7 m
        tall. The window ahead at eye height over an angled main console;
        the hatch on the right (+X) as on the hull; a breaker panel overhead;
        stowage, bottles and an extinguisher behind; the tunnel up top."""
        prof = [(1.00, -0.84), (0.98, -0.55), (0.92, -0.20), (0.84, 0.15), (0.74, 0.45), (0.62, 0.72), (0.52, 0.90)]
        cuts = []
        S = IVAS["IvaPodMk1"]["seats"][0]
        ey = eye_of(S)[1]
        window("Win", prof, 0.0, ey + 0.02, 0.40, 0.30, cuts, shade=True)
        hatch("Hatch", prof, math.pi / 2, -0.10, 0.52, 0.60, cuts)
        shell("Wall", prof, cuts)
        floor_disc("Floor", -0.84, 1.0)
        for k in range(8):
            a = k * math.pi / 4 + math.pi / 8
            box("FloorRib", "Metal", (0.55 * math.sin(a), -0.83, -0.55 * math.cos(a)), (0.03, 0.02, 0.9),
                Matrix.Rotation(-a, 3, "Y"))
        ceiling_tunnel("Top", 0.90, 0.30, 0.53)
        main_console(prof, ey, width=0.86, drop=0.44, depth_into=0.30)
        common_seat_dressing("pod1", IVAS["IvaPodMk1"]["seats"])
        # up the left: a circuit-breaker panel angled down at the crew
        p, n, t, up = wall_at(prof, -1.05, 0.50)
        panel_face("Cb", p + n * 0.035, n, 0.46, 0.24, "cb", up=tuple(up))
        breakers("CbBtn", p + n * 0.037, n, 0.40, 0.17, 12, 4, up=tuple(up))
        # left wall at eye height: the RCS panel and two gauges
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.1, 0.45)
        panel_face("Rcs", p + n * 0.03, n, 0.44, 0.11, "sw_rcs", up=tuple(up))
        toggles("RcsSw", p + n * 0.032 - up * 0.012, n, 0.40, 8, up=tuple(up))
        for k, g in enumerate(("g1", "g2")):
            q, qn, qt, qu = wall_at(prof, -math.pi / 2 - 0.55 + k * 0.2, 0.40)
            gauge("SideGauge", q + qn * 0.02, qn, 0.04, g, up=tuple(qu))
        # right wall above the hatch: the checklist, a lamp, a hand-held mic
        p, n, t, up = wall_at(prof, math.pi / 2 - 0.55, 0.42)
        box("Clip", "Dark", p + n * 0.01, (0.2, 0.28, 0.01), M3(t, up, n), bevel=0.004)
        plate("ClipCard", "Panel", p + n * 0.016, n, 0.18, 0.12, "warnlist", (PANEL, PANEL_SIZE), up=tuple(up))
        plate("ClipCard2", "Panel", p + n * 0.016 - up * 0.08, n, 0.18, 0.06, "emerg", (PANEL, PANEL_SIZE), up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi / 2 + 0.5, 0.40)
        box("MicBox", "Dark", p + n * 0.03, (0.07, 0.10, 0.05), M3(t, up, n), bevel=0.01)
        tube_path("MicCord", "Rubber", [p + n * 0.05 - up * 0.05, p + n * 0.10 - up * 0.15, p + n * 0.06 - up * 0.28,
                                        p + n * 0.12 - up * 0.36], 0.006, sides=6)
        # left wall: comm panel, rotary knobs, a vent, the O2 bottles
        p, n, t, up = wall_at(prof, -math.pi / 2 + 0.05, 0.20)
        panel_face("Comm", p + n * 0.03, n, 0.44, 0.11, "sw_comm", up=tuple(up))
        toggles("CommSw", p + n * 0.032 - up * 0.012, n, 0.40, 8, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 + 0.05, -0.08)
        panel_face("Rot", p + n * 0.03, n, 0.44, 0.11, "rotary", up=tuple(up))
        knobs("RotK", p + n * 0.032 - up * 0.008, n, 0.40, 5, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.35, -0.45)
        vent("Vent", p + n * 0.012, n, 0.20, 0.12, up=tuple(up))
        for k, a in enumerate((-2.25, -2.55)):
            p, n, t, up = wall_at(prof, a, -0.80)
            bottle("O2Bottle", p + n * 0.09, (0, 1, 0), 0.07, 0.62, m_="Paint")
            plate("O2Tag", "Panel", p + n * 0.165 + Vector((0, 0.30, 0)), n, 0.08, 0.04, "o2", (PANEL, PANEL_SIZE))
            box("O2Band", "Strap", p + n * 0.09 + Vector((0, 0.42, 0)), (0.16, 0.03, 0.16))
        # behind: stowage bags under a net, a locker, the extinguisher
        p, n, t, up = wall_at(prof, math.pi, 0.15)
        R = M3(t, up, n)
        stow_bag("Bag", p + n * 0.12 + t * 0.15, (0.30, 0.22, 0.18), R)
        stow_bag("Bag", p + n * 0.12 - t * 0.20, (0.26, 0.20, 0.16), R)
        net("Net", p + n * 0.02, n, 0.70, 0.40, up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi + 0.6, -0.30)
        R = M3(t, up, n)
        box("Locker", "PanelPaint", p + n * 0.12, (0.36, 0.40, 0.24), R, bevel=0.012)
        plate("LockerTag", "Panel", p + n * 0.241 + up * 0.13, n, 0.24, 0.06, "stow", (PANEL, PANEL_SIZE), up=tuple(up))
        for s in (-1, 1):
            box("LockerLatch", "Chrome", p + n * 0.245 + t * (s * 0.12) - up * 0.05, (0.03, 0.05, 0.012), R, bevel=0.004)
        p, n, t, up = wall_at(prof, math.pi - 0.75, -0.35)
        extinguisher("Ext", p + n * 0.07 - up * 0.17, tuple(up))
        # handholds, cable runs, lamps
        p, n, t, up = wall_at(prof, -0.55, 0.45)
        handhold("Grab", p - t * 0.12, p + t * 0.12, n)
        p, n, t, up = wall_at(prof, 0.55, 0.45)
        handhold("Grab", p - t * 0.12, p + t * 0.12, n)
        cable_run("Loom", [wall_at(prof, math.pi * (0.6 + 0.8 * k / 16), 0.56)[0] + wall_at(prof, math.pi * (0.6 + 0.8 * k / 16), 0.56)[1] * 0.03
                           for k in range(17)])
        p, n, t, up = wall_at(prof, 0.0, 0.80)
        lamp("LampA", p + n * 0.02, n, up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi, 0.70)
        lamp("LampB", p + n * 0.02, n, up=tuple(up))
        return cuts

    def main_console(prof, ey, width=0.86, theta=0.0, depth_into=0.34, name="Con", drop=0.30):
        """The main console under the front window: a slanted face carrying
        the displays and gauges, a lower switch deck, a glare shield, side
        cheeks, a footwell kick panel."""
        p, n, t, up = wall_at(prof, theta, ey - drop)
        base = p + n * depth_into
        tilt = Matrix.Rotation(math.radians(-38), 3, t)
        fn = (tilt @ n).normalized()           # the console face's normal (up and back)
        fu = t.cross(fn).normalized()
        if fu.y < 0:
            fu = -fu
        face_h = 0.40
        fc = base + up * 0.02
        Rf = M3(t, fu, fn)
        box(name + "Body", "PanelPaint", fc - fn * 0.10, (width, face_h + 0.04, 0.2), Rf, bevel=0.012)
        # the body down to the floor and back to the wall
        box(name + "Plinth", "PanelPaint", base - up * 0.40 + n * -0.10, (width * 0.9, 0.60, 0.22), M3(t, up, n), bevel=0.012)
        box(name + "Kick", "Tread", base - up * 0.70 + n * 0.02, (width * 0.85, 0.02, 0.18), M3(t, up, n))
        # screens and gauges on the face
        screen(name + "MfdL", fc + fu * 0.02 - t * (width * 0.25), fn, 0.17, 0.13, "adi", up=tuple(fu))
        screen(name + "MfdR", fc + fu * 0.02 + t * (width * 0.25), fn, 0.17, 0.13, "orbit", up=tuple(fu))
        screen(name + "Sys", fc + fu * 0.065, fn, 0.13, 0.06, "sys", up=tuple(fu), buttons=3)
        plate(name + "Dsky", "Screen", fc - fu * 0.035 + fn * 0.002, fn, 0.12, 0.045, "dsky", (SCREEN, SCREEN_SIZE), up=tuple(fu))
        for i, g in enumerate(("g0", "g1", "g2")):
            gauge(name + "Gauge", fc - fu * 0.125 + t * ((i - 1) * 0.085) - t * (width * 0.25), fn, 0.034, g, up=tuple(fu))
        for i, g in enumerate(("g3", "g4", "g5")):
            gauge(name + "Gauge", fc - fu * 0.125 + t * ((i - 1) * 0.085) + t * (width * 0.25), fn, 0.034, g, up=tuple(fu))
        plate(name + "Annun", "Screen", fc + fu * 0.165 + fn * 0.002, fn, 0.30, 0.045, "annun", (SCREEN, SCREEN_SIZE), up=tuple(fu))
        kp = fc - fu * 0.125
        plate(name + "Keys", "Panel", kp + fn * 0.002, fn, 0.10, 0.07, "keypad", (PANEL, PANEL_SIZE), up=tuple(fu))
        for i in range(4):
            for j in range(3):
                q = kp + fu * (0.024 - i * 0.016) + t * ((j - 1) * 0.028) + fn * 0.004
                box(name + "Key", "Rubber", q, (0.022, 0.012, 0.006), Rf, bevel=0.002)
        # glare shield over the top edge
        gs = fc + fu * (face_h / 2 + 0.02) + fn * 0.06
        box(name + "Glare", "Dark", gs, (width + 0.04, 0.03, 0.16), M3(t, up, n), bevel=0.01)
        # the switch deck: a near-flat shelf toward the crew
        deck = base - up * 0.17 + n * 0.17
        dn = (Matrix.Rotation(math.radians(-70), 3, t) @ n).normalized()
        du = t.cross(dn).normalized()
        if du.dot(n) < 0:
            du = -du
        panel_face(name + "SwA", deck - t * (width * 0.24), dn, 0.38, 0.095, "sw_main", up=tuple(du))
        toggles(name + "SwAT", deck - t * (width * 0.24) + dn * 0.002 - du * 0.012, dn, 0.34, 8, up=tuple(du))
        panel_face(name + "SwB", deck + t * (width * 0.24), dn, 0.38, 0.095, "sw_pyro", up=tuple(du))
        toggles(name + "SwBT", deck + t * (width * 0.24) + dn * 0.002 - du * 0.012, dn, 0.34, 8, up=tuple(du), guard=(5, 6, 7))
        # cheeks either side
        for s in (-1, 1):
            box(name + "Cheek", "PanelPaint", base + t * (s * (width / 2 + 0.02)) - up * 0.15 - n * 0.05,
                (0.04, 0.62, 0.42), M3(t, up, n), bevel=0.01)
        plate(name + "Serial", "Panel", base - up * 0.48 + n * 0.012, n, 0.12, 0.03, "serial", (PANEL, PANEL_SIZE), up=tuple(up))
        plate(name + "Haz", "Panel", base - up * 0.62 + n * 0.012, n, width * 0.8, 0.03, "hazard", (PANEL, PANEL_SIZE), up=tuple(up))
        return fc, fn, fu, t

    def iva_pod_mk2():
        """Pod Mk2, three abreast: 2.9 m across the floor, 1.9 m tall; three
        windows across the front, the long main console under them with the
        commander's displays in the middle, the hatch on +X, lockers and
        bottles behind, an overhead panel and the top tunnel."""
        prof = [(1.45, -0.90), (1.42, -0.60), (1.33, -0.25), (1.18, 0.12), (1.00, 0.45), (0.84, 0.72), (0.72, 1.00)]
        cuts = []
        seats = IVAS["IvaPodMk2"]["seats"]
        ey = eye_of(seats[0])[1]
        for th, w in ((-0.55, 0.36), (0.0, 0.44), (0.55, 0.36)):
            window("Win", prof, th, ey + 0.02, w, 0.30, cuts, shade=(th == 0.0))
        hatch("Hatch", prof, math.pi / 2 + 0.15, -0.12, 0.56, 0.66, cuts)
        shell("Wall", prof, cuts, segs=80)
        floor_disc("Floor", -0.90, 1.45)
        for k in range(10):
            a = k * math.pi / 5
            box("FloorRib", "Metal", (0.8 * math.sin(a), -0.89, -0.8 * math.cos(a)), (0.03, 0.02, 1.3), Matrix.Rotation(-a, 3, "Y"))
        ceiling_tunnel("Top", 1.00, 0.34, 0.73)
        main_console(prof, ey, width=1.70)
        common_seat_dressing("pod2", seats, controller_slots=(0, 1, 2))
        for th in (-1.2, 1.2):
            p, n, t, up = wall_at(prof, th, 0.50)
            panel_face("Cb", p + n * 0.035, n, 0.40, 0.22, "cb", up=tuple(up))
            breakers("CbBtn", p + n * 0.037, n, 0.35, 0.16, 10, 4, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.1, 0.25)
        panel_face("Comm", p + n * 0.03, n, 0.44, 0.11, "sw_comm", up=tuple(up))
        toggles("CommSw", p + n * 0.032 - up * 0.012, n, 0.40, 8, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.1, 0.0)
        panel_face("Rcs", p + n * 0.03, n, 0.44, 0.11, "sw_rcs", up=tuple(up))
        toggles("RcsSw", p + n * 0.032 - up * 0.012, n, 0.40, 8, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.1, -0.25)
        panel_face("Rot", p + n * 0.03, n, 0.44, 0.11, "rotary", up=tuple(up))
        knobs("RotK", p + n * 0.032 - up * 0.008, n, 0.40, 5, up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.55, -0.45)
        vent("Vent", p + n * 0.012, n, 0.24, 0.14, up=tuple(up))
        for a in (math.pi - 0.35, math.pi + 0.35):
            p, n, t, up = wall_at(prof, a, 0.05)
            R = M3(t, up, n)
            box("Locker", "PanelPaint", p + n * 0.14, (0.42, 0.56, 0.28), R, bevel=0.014)
            plate("LockerTag", "Panel", p + n * 0.281 + up * 0.20, n, 0.26, 0.065, "stow2", (PANEL, PANEL_SIZE), up=tuple(up))
            for s in (-1, 1):
                box("LockerLatch", "Chrome", p + n * 0.285 + t * (s * 0.15) - up * 0.06, (0.03, 0.05, 0.012), R, bevel=0.004)
            handhold("Grab", p + up * 0.36 - t * 0.14, p + up * 0.36 + t * 0.14, n)
        p, n, t, up = wall_at(prof, math.pi, -0.60)
        R = M3(t, up, n)
        stow_bag("Bag", p + n * 0.14 + t * 0.2, (0.36, 0.24, 0.22), R)
        stow_bag("Bag", p + n * 0.14 - t * 0.22, (0.30, 0.22, 0.20), R, strap_n=1)
        net("Net", p + n * 0.02 + up * 0.04, n, 0.80, 0.34, up=tuple(up))
        for a in (-2.35, -2.6):
            p, n, t, up = wall_at(prof, a, -0.86)
            bottle("O2Bottle", p + n * 0.1, (0, 1, 0), 0.075, 0.7)
            plate("O2Tag", "Panel", p + n * 0.176 + Vector((0, 0.32, 0)), n, 0.08, 0.04, "o2", (PANEL, PANEL_SIZE))
            box("O2Band", "Strap", p + n * 0.1 + Vector((0, 0.48, 0)), (0.17, 0.03, 0.17))
        p, n, t, up = wall_at(prof, math.pi - 0.95, -0.35)
        extinguisher("Ext", p + n * 0.07 - up * 0.17, tuple(up))
        cable_run("Loom", [wall_at(prof, math.pi * (0.62 + 0.76 * k / 16), 0.62)[0] + wall_at(prof, math.pi * (0.62 + 0.76 * k / 16), 0.62)[1] * 0.03
                           for k in range(17)])
        for th in (-0.3, 0.3):
            p, n, t, up = wall_at(prof, th, 0.80)
            handhold("Grab", p - t * 0.12, p + t * 0.12, n)
        for th, y in ((0.0, 0.84), (-1.9, 0.5), (1.9, 0.5)):
            p, n, t, up = wall_at(prof, th, y)
            lamp("Lamp", p + n * 0.02, n, up=tuple(up))
        return cuts

    def iva_cabin():
        """The Crew Cabin, four passengers: a 2.5 m barrel, 2.1 m tall. Two
        couches against each of the front and back walls face the middle; the
        hatch on +X between them, round portholes, stowage on -X, lights in a
        ceiling strip."""
        R0 = 1.25
        prof = [(R0, -1.05), (R0, 1.05)]
        cuts = []
        seats = IVAS["IvaCabin"]["seats"]
        ey = eye_of(seats[0])[1]
        # portholes: round cutters
        for th in (math.pi / 2 - 0.85, math.pi / 2 + 0.85, -math.pi / 2 + 0.5, -math.pi / 2 - 0.5):
            p, n, t, up = wall_at(prof, th, ey - 0.02)
            bm = bmesh.new()
            bmesh.ops.create_cone(bm, cap_ends=True, segments=28, radius1=0.15, radius2=0.15, depth=0.6)
            me = bpy.data.meshes.new("cut")
            bm.to_mesh(me)
            bm.free()
            c = bpy.data.objects.new("cut", me)
            bpy.context.scene.collection.objects.link(c)
            c.matrix_world = Matrix.Translation(p) @ M3(t, up, n).to_4x4()
            CUTTERS.append(c)
            cuts.append(c)
            ring("Port", "Metal", p + n * 0.0, n, 0.15, 0.21, 0.04, segs=32, bevel=0.004)
            for k in range(10):
                a = 2 * math.pi * k / 10
                q = p + (t * math.cos(a) + up * math.sin(a)) * 0.185 + n * 0.04
                cyl("PortBolt", "Chrome", q - n * 0.003, q + n * 0.006, 0.006, segs=6)
            lathe_c = lathe("PortTunnel", "Dark", [(0.15, 0.0), (0.15, 0.12)], segs=28, uv="box")
            lathe_c.matrix_world = Matrix.Translation(p) @ M3(t, -n, up).to_4x4()
            disc("PortGlass", "Glass", p - n * 0.02, n, 0.15, segs=20)
            disc("PortGlass2", "Glass", p - n * 0.10, n, 0.15, segs=20)
        hatch("Hatch", prof, math.pi / 2, -0.15, 0.58, 0.78, cuts)
        shell("Wall", prof, cuts, segs=72)
        floor_disc("Floor", -1.05, R0)
        floor_disc("Ceiling", 1.05, R0, m_="Padding", up=False)
        for k in range(6):
            box("FloorRib", "Metal", (0, -1.04, -0.9 + k * 0.36), (2.2, 0.02, 0.03))
        common_seat_dressing("cabin", seats, controller_slots=())
        # a ceiling light strip, a centre handrail, a ceiling hatch ring
        box("LightStrip", "Dark", (0, 1.03, 0), (0.14, 0.04, 1.6), bevel=0.01)
        plate("LightLens", "Lamp", (0, 1.005, 0), (0, -1, 0), 0.10, 1.5, None, None, up=(0, 0, 1))
        for s in (-1, 1):
            handhold("Rail", (s * 0.35, 1.04, -0.6), (s * 0.35, 1.04, 0.6), (0, -1, 0))
        ring("TopRing", "Metal", (0, 1.04, 0.0), (0, -1, 0), 0.32, 0.40, 0.03, segs=32)
        # -X wall: lockers and nets, a vent; +X either side of the hatch:
        # breaker and comm panels
        for y in (-0.5, 0.2):
            p, n, t, up = wall_at(prof, -math.pi / 2, y)
            R = M3(t, up, n)
            box("Locker", "PanelPaint", p + n * 0.13, (0.55, 0.5, 0.26), R, bevel=0.014)
            plate("LockerTag", "Panel", p + n * 0.261 + up * 0.17, n, 0.26, 0.065, "stow", (PANEL, PANEL_SIZE), up=tuple(up))
            for s in (-1, 1):
                box("LockerLatch", "Chrome", p + n * 0.265 + t * (s * 0.2) - up * 0.06, (0.03, 0.05, 0.012), R, bevel=0.004)
        p, n, t, up = wall_at(prof, -math.pi / 2, 0.75)
        net("Net", p + n * 0.02, n, 0.9, 0.36, up=tuple(up))
        stow_bag("Bag", p + n * 0.1, (0.5, 0.22, 0.16), M3(t, up, n))
        p, n, t, up = wall_at(prof, math.pi / 2 - 0.55, 0.45)
        panel_face("Cb", p + n * 0.035, n, 0.34, 0.22, "cb", up=tuple(up))
        breakers("CbBtn", p + n * 0.037, n, 0.30, 0.16, 9, 4, up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi / 2 + 0.55, 0.45)
        panel_face("Comm", p + n * 0.03, n, 0.40, 0.11, "sw_comm", up=tuple(up))
        toggles("CommSw", p + n * 0.032 - up * 0.012, n, 0.36, 8, up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi / 2 + 0.55, 0.15)
        gauge("CabGauge", p + n * 0.02, n, 0.045, "g1", up=tuple(up))
        p, n, t, up = wall_at(prof, math.pi / 2 - 0.55, 0.12)
        plate("Emerg", "Panel", p + n * 0.003, n, 0.30, 0.11, "emerg", (PANEL, PANEL_SIZE), up=tuple(up))
        p, n, t, up = wall_at(prof, -math.pi / 2 - 0.9, -0.95)
        extinguisher("Ext", p + n * 0.07, (0, 1, 0))
        p, n, t, up = wall_at(prof, -math.pi / 2 + 0.9, -1.0)
        bottle("O2Bottle", p + n * 0.1, (0, 1, 0), 0.07, 0.62)
        plate("O2Tag", "Panel", p + n * 0.17 + Vector((0, 0.3, 0)), n, 0.08, 0.04, "o2", (PANEL, PANEL_SIZE))
        for th in (-0.5, 0.5, math.pi - 0.5, math.pi + 0.5):
            p, n, t, up = wall_at(prof, th, 0.75)
            vent("Vent", p + n * 0.012, n, 0.18, 0.1, up=tuple(up))
        cable_run("Loom", [(R0 - 0.04) * Vector((math.sin(a), 0, -math.cos(a))) + Vector((0, 0.92, 0)) for a in
                           [-math.pi * 0.3 + math.pi * 0.6 * k / 12 for k in range(13)]])
        return cuts

    def iva_cockpit():
        """The Swift's cockpit, from the ejection seat: a narrow tub with side
        consoles (throttle quadrant left, avionics right), the main panel
        with two MFDs, a radar scope and standby gauges under a glare shield,
        the HUD combiner, a centre stick, rudder pedals, the canopy frame
        and its glazing overhead. Open above the sills: the canopy is glass."""
        cuts = []
        S = IVAS["IvaCockpit"]["seats"][0]
        hip = Vector(S[:3])
        ey = eye_of(S)[1]
        W = 0.86            # tub width between the sills
        # the tub: floor, sides up to the sills, the rear bulkhead
        box("TubFloor", "Tread", (0, -0.86, -0.15), (W, 0.03, 1.9))
        for s in (-1, 1):
            box("TubSide", "PanelPaint", (s * (W / 2 + 0.02), -0.40, -0.15), (0.04, 0.95, 1.9), bevel=0.008)
            box("Sill", "Dark", (s * (W / 2 + 0.02), 0.09, -0.15), (0.09, 0.04, 1.9), bevel=0.01)
            box("SillPad", "Cushion", (s * (W / 2 - 0.01), 0.06, 0.15), (0.05, 0.06, 0.6), bevel=0.02)
        box("Bulkhead", "PanelPaint", (0, -0.05, 0.85), (W + 0.08, 1.7, 0.04), bevel=0.01)
        box("Footwell", "Dark", (0, -0.55, -1.10), (W, 0.65, 0.04))
        # side consoles
        for s, cell in ((-1, "sidecon"), (1, "sidecon")):
            top = Vector((s * (W / 2 - 0.13), -0.18, 0.0))
            box("SideCon", "PanelPaint", top - Vector((0, 0.18, 0)), (0.24, 0.36, 0.9), bevel=0.01)
            plate("SideConFace", "Panel", top + Vector((0, 0.0012, 0)), (0, 1, 0), 0.22, 0.86, cell, (PANEL, PANEL_SIZE), up=(0, 0, -1), flipu=s > 0)
            toggles("SideSw", top + Vector((0, 0.002, 0.25)), (0, 1, 0), 0.18, 5, up=(0, 0, -1))
            knobs("SideK", top + Vector((0, 0.002, 0.05)), (0, 1, 0), 0.18, 3, up=(0, 0, -1))
            breakers("SideCb", top + Vector((0, 0.002, 0.35)), (0, 1, 0), 0.18, 0.06, 6, 2, up=(0, 0, -1))
        # throttle (left) on its quadrant
        q = Vector((-(W / 2 - 0.13), -0.17, -0.18))
        box("ThrQuad", "Dark", q, (0.08, 0.04, 0.24), bevel=0.008)
        cyl("ThrArm", "Chrome", q + Vector((0, 0.02, 0.02)), q + Vector((0.02, 0.13, -0.04)), 0.01)
        cushion("ThrGrip", "Rubber", q + Vector((0.03, 0.16, -0.05)), (0.06, 0.07, 0.11), round_=0.02)
        # the main panel and glare shield
        pz = -0.62
        Rp = Matrix.Rotation(math.radians(-12), 3, "X")
        pc = Vector((0, 0.02, pz))
        box("Panel", "PanelPaint", pc + Rp @ Vector((0, 0, -0.06)), (W - 0.02, 0.46, 0.12), Rp, bevel=0.012)
        fn = (Rp @ Vector((0, 0, 1))).normalized()
        fu = (Rp @ Vector((0, 1, 0))).normalized()
        screen("MfdL", pc + fu * 0.03 - Vector((0.24, 0, 0)), fn, 0.17, 0.15, "radar", up=tuple(fu))
        screen("MfdR", pc + fu * 0.03 + Vector((0.24, 0, 0)), fn, 0.17, 0.15, "eng", up=tuple(fu))
        screen("Up", pc + fu * 0.10, fn, 0.14, 0.10, "adi", up=tuple(fu), buttons=0)
        for i, g in enumerate(("g6", "g7", "g4", "g2")):
            gauge("Stby", pc - fu * 0.10 + Vector(((i - 1.5) * 0.075, 0, 0)), fn, 0.03, g, up=tuple(fu))
        plate("PanelWarn", "Screen", pc - fu * 0.175 + fn * 0.002, fn, 0.40, 0.04, "annun", (SCREEN, SCREEN_SIZE), up=tuple(fu))
        box("Glare", "Dark", pc + fu * 0.25 + fn * 0.08, (W - 0.06, 0.035, 0.2), bevel=0.012)
        # HUD: a frame on the glare shield and two combiner glasses
        hb = pc + fu * 0.27 + fn * 0.02
        box("HudBase", "Dark", hb, (0.16, 0.05, 0.10), bevel=0.008)
        for k, dz in enumerate((0.0, 0.035)):
            plate("Hud%d" % k, "Glass", hb + Vector((0, 0.11, 0.02 + dz)), (0, 0.25, 1), 0.15, 0.13, None, None)
        for s in (-1, 1):
            cyl("HudPost", "Dark", hb + Vector((s * 0.075, 0.02, 0.0)), hb + Vector((s * 0.075, 0.18, 0.03)), 0.005, segs=6)
        # stick and pedals
        base = hip + Vector((0, -0.2, -0.32))
        ring("StickBoot", "Rubber", base, (0, 1, 0), 0.01, 0.06, 0.03, segs=14)
        cyl("Stick", "Dark", base, base + Vector((0, 0.32, 0.04)), 0.013, segs=10)
        cushion("StickGrip", "Rubber", base + Vector((0, 0.38, 0.05)), (0.05, 0.13, 0.055), round_=0.02)
        cyl("StickTrig", "Red", base + Vector((0, 0.36, 0.02)), base + Vector((0, 0.34, 0.0)), 0.006, segs=6)
        for s in (-1, 1):
            box("Pedal", "Tread", (s * 0.15, -0.70, -0.98), (0.10, 0.18, 0.02), Matrix.Rotation(0.6, 3, "X"), bevel=0.004)
            cyl("PedalArm", "Metal", (s * 0.15, -0.80, -0.96), (s * 0.15, -0.86, -1.05), 0.01)
        # the ejection seat
        couch("Couch1", tuple(hip), 0.0, controller=False, wide=0.50)
        box("SeatHeadbox", "Dark", hip + Vector((0, 0.98, 0.46)), (0.34, 0.24, 0.16), bevel=0.02)
        plate("SeatEject", "Panel", hip + Vector((0, 0.98, 0.37)), (0, 0, -1), 0.24, 0.06, "eject", (PANEL, PANEL_SIZE))
        tube_path("SeatHandle", "Yellow", [hip + Vector((-0.08, -0.12, -0.24)), hip + Vector((-0.04, -0.06, -0.27)),
                                            hip + Vector((0.04, -0.06, -0.27)), hip + Vector((0.08, -0.12, -0.24))], 0.01)
        for s in (-1, 1):
            cyl("SeatRail", "Metal", hip + Vector((s * 0.2, -0.65, 0.45)), hip + Vector((s * 0.2, 1.05, 0.52)), 0.02, segs=10)
        # the canopy: a bow at the windscreen, a rear arch, rails, glazing
        def arch(z, rx, ry, base_y, name, r=0.03):
            pts = [Vector((rx * math.cos(a), base_y + ry * math.sin(a), z)) for a in [math.pi * k / 16 for k in range(17)]]
            tube_path(name, "Dark", pts, r, sides=8)
        arch(-0.82, W / 2 + 0.02, 0.62, 0.10, "Bow", r=0.035)
        arch(0.86, W / 2 + 0.06, 0.88, 0.10, "Arch", r=0.04)
        tube_path("Spine", "Dark", [Vector((0, 0.72, -0.82)), Vector((0, 0.95, -0.2)), Vector((0, 0.98, 0.5)), Vector((0, 0.98, 0.86))], 0.02)
        # glazing: an ellipsoid dome over the sills, windscreen ahead
        nu, nv = 32, 12
        W2 = W
        bm = bmesh.new()
        grid = []
        for j in range(nv + 1):
            v = j / nv                       # 0 front .. 1 back
            z = -0.86 + v * 1.74
            row = []
            for i in range(nu + 1):
                a = math.pi * i / nu
                hy = 0.62 + 0.26 * math.sin(math.pi * min(1.0, v * 1.3) / 2)
                row.append(bm.verts.new((-(W / 2 + 0.04) * math.cos(a), 0.10 + hy * math.sin(a), z)))
            grid.append(row)
        for j in range(nv):
            for i in range(nu):
                bm.faces.new((grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]))
        finish(bm, "Canopy", "Glass", smooth=True)
        # windscreen: a flat front pane closing the bow
        bm = bmesh.new()
        ctr = bm.verts.new((0, 0.3, -0.84))
        rim = [bm.verts.new((-(W / 2 + 0.04) * math.cos(math.pi * k / 16), 0.10 + 0.62 * math.sin(math.pi * k / 16), -0.84))
               for k in range(17)]
        for k in range(16):
            bm.faces.new((ctr, rim[k], rim[k + 1]))
        finish(bm, "Windscreen", "Glass")
        # behind the seat: avionics boxes, cable runs, a small lamp
        for k in range(3):
            box("Avionics", "Paint", (-0.25 + k * 0.25, 0.30, 0.78), (0.2, 0.16, 0.1), bevel=0.008)
            plate("AvTag", "Panel", (-0.25 + k * 0.25, 0.30, 0.727), (0, 0, -1), 0.16, 0.04, "serial", (PANEL, PANEL_SIZE))
        cable_run("Loom", [Vector((-0.38, 0.05, 0.7)), Vector((-0.38, 0.05, 0.0)), Vector((-0.38, 0.05, -0.5))], count=2)
        cable_run("Loom", [Vector((0.38, 0.05, 0.7)), Vector((0.38, 0.05, 0.0)), Vector((0.38, 0.05, -0.5))], count=2)
        lamp("Lamp", Vector((0.0, 0.25, -0.50)) + Vector((0, 0.0, 0)), (0, -0.4, 1), w=0.08, h=0.03)
        p = Vector((0.40, -0.10, 0.45))
        plate("Check", "Panel", p, (-1, 0, 0), 0.24, 0.12, "warnlist", (PANEL, PANEL_SIZE))
        return cuts

    BUILDERS = {"IvaPodMk1": iva_pod_mk1, "IvaPodMk2": iva_pod_mk2, "IvaCabin": iva_cabin, "IvaCockpit": iva_cockpit}

    # ── export ──────────────────────────────────────────────────────────────
    def export():
        dg = bpy.context.evaluated_depsgraph_get()
        out = {}
        for ob, node, uvmode in OBJS:
            ev = ob.evaluated_get(dg)
            me = ev.to_mesh()
            me.calc_loop_triangles()
            Mw = ob.matrix_world
            # one radius for the whole object: a per-triangle radius gave
            # neighbours different u along a shared edge (a shattered look)
            R_obj = 1.0
            if uvmode == "cyl" and len(me.vertices):
                R_obj = max(math.hypot((Mw @ v.co).x, (Mw @ v.co).z) for v in me.vertices)
            Mn = Mw.to_3x3().inverted().transposed()
            flip = Mw.to_3x3().determinant() < 0
            cn = me.corner_normals
            uvl = me.uv_layers.get("UVMap") if uvmode == "atlas" else None
            slots = [m.name if m else "Dark" for m in me.materials] or ["Dark"]
            for tri in me.loop_triangles:
                mname = slots[min(tri.material_index, len(slots) - 1)]
                e = out.setdefault(node, {}).setdefault(mname, {"P": [], "N": [], "UV": []})
                loops = list(tri.loops)
                if flip:
                    loops = loops[::-1]
                Pw = [Mw @ me.vertices[me.loops[li].vertex_index].co for li in loops]
                N = [(Mn @ Vector(cn[li].vector)).normalized() for li in loops]
                k = UVM.get(mname, 2.0)
                if uvl is not None and mname in ATLAS_MATS:
                    UV = [(uvl.data[li].uv[0], uvl.data[li].uv[1]) for li in loops]
                elif uvmode == "cyl":
                    UV = []
                    for p in Pw:
                        a = math.atan2(p.x, -p.z)            # 0 at the front, + toward +X
                        r = math.hypot(p.x, p.z)
                        UV.append([a, r, p.y])
                    # keep a triangle on one side of the seam (at the back)
                    a0 = UV[0][0]
                    for q in UV:
                        while q[0] - a0 > math.pi:
                            q[0] -= 2 * math.pi
                        while q[0] - a0 < -math.pi:
                            q[0] += 2 * math.pi
                    UV = [(q[0] * R_obj * k, -q[2] * k) for q in UV]
                else:
                    fn = (Pw[1] - Pw[0]).cross(Pw[2] - Pw[0])
                    ax = max(range(3), key=lambda i: abs(fn[i]))
                    ua, va = [(2, 1), (0, 2), (0, 1)][ax]
                    sg = 1.0 if fn[ax] >= 0 else -1.0
                    if ax == 1:
                        UV = [(p[0] * k, p[2] * k * sg) for p in Pw]
                    elif ax == 0:
                        UV = [(-p[2] * k * sg, -p[1] * k) for p in Pw]
                    else:
                        UV = [(p[0] * k * sg, -p[1] * k) for p in Pw]
                for p in Pw:
                    e["P"] += [round(p.x, 5), round(p.y, 5), round(p.z, 5)]
                for n in N:
                    e["N"] += [round(n.x, 4), round(n.y, 4), round(n.z, 4)]
                for u, v in UV:
                    e["UV"] += [round(u, 5), round(v, 5)]
            ev.to_mesh_clear()
        return out

    def blender_main():
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
        path = argv[0] if argv else "/tmp/iva_mesh.json"
        want = argv[1].split(",") if len(argv) > 1 else list(BUILDERS.keys())
        res = {}
        for name in want:
            reset()
            BUILDERS[name]()
            geo = export()
            res[name] = geo
            tris = sum(len(m["P"]) // 9 for n in geo.values() for m in n.values())
            print(f"IVA {name}: {tris} tris, nodes {list(geo.keys())}, mats {sorted(geo.get('Shell', {}).keys())}")
        reset()
        self_body()
        res["self"] = export()
        print("IVA self:", sum(len(m["P"]) // 9 for n in res["self"].values() for m in n.values()), "tris")
        with open(path, "w") as f:
            json.dump(res, f)
        print("IVA wrote", path)

    blender_main()


# ═════════════════════════════════════════════════════════════════════════════
# SYSTEM-PYTHON HALF: textures, .glb files, prefabs
# ═════════════════════════════════════════════════════════════════════════════
else:
    import numpy as np

    # ── textures ────────────────────────────────────────────────────────────
    def pnoise(n, lo, hi, seed, beta=1.0):
        """Periodic band-limited noise, n×n, wavelengths between n/hi and n/lo
        px, normalised to 0..1. Tiles seamlessly (built in frequency space)."""
        rng = np.random.default_rng(seed)
        f = np.fft.fftfreq(n) * n
        fx, fy = np.meshgrid(f, f)
        r = np.sqrt(fx * fx + fy * fy)
        amp = np.where((r >= lo) & (r <= hi), 1.0 / np.maximum(r, 1) ** beta, 0.0)
        ph = rng.uniform(0, 2 * np.pi, (n, n))
        z = np.real(np.fft.ifft2(amp * np.exp(1j * ph)))
        z -= z.min()
        return z / max(z.max(), 1e-9)

    def normal_from(h, strength):
        dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * strength
        dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * strength
        nz = np.ones_like(h)
        L = np.sqrt(dx * dx + dy * dy + 1)
        return np.stack([(-dx / L) * 0.5 + 0.5, (dy / L) * 0.5 + 0.5, (nz / L) * 0.5 + 0.5], -1)

    def save_rgb(a, name):
        from PIL import Image
        a = np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8)
        Image.fromarray(a, "RGB").save(os.path.join(OUT_TEX, name), optimize=True)

    def padding_tex():
        """Quilted beta-cloth padding, 1 m tile at 1024 px: soft diamond
        pillows stitched every 12.5 cm, a fine weave, grime and scuffs."""
        n = 1024
        y, x = np.mgrid[0:n, 0:n].astype(np.float64)
        sp = 128.0
        d1 = ((x + y) % sp) / sp
        d2 = ((x - y) % sp) / sp
        # a pillow is the product of two soft humps: smooth everywhere but the
        # stitch line itself (no ridges, no facets)
        pill = (np.sin(np.pi * d1) * np.sin(np.pi * d2)) ** 0.35
        weave = (np.sin(x * np.pi / 2.0) * np.sin(y * np.pi / 2.0)) * 0.5 + 0.5
        fine = pnoise(n, 60, 400, 3)
        h = pill * 1.0 + weave * 0.02 + fine * 0.03
        stitch_line = np.minimum(np.minimum(d1, 1 - d1), np.minimum(d2, 1 - d2)) * sp
        stitch = (stitch_line < 1.2) & ((((x + y) // 5) % 2) == 0)
        grime = pnoise(n, 1, 8, 7, beta=1.4)
        grime2 = pnoise(n, 6, 40, 11, beta=1.0)
        base = np.array([0.76, 0.76, 0.73])
        col = np.ones((n, n, 3)) * base
        col *= (0.88 + 0.12 * pill)[..., None]
        col *= (0.88 + 0.12 * (1 - grime ** 1.6))[..., None]
        col *= (0.96 + 0.04 * grime2)[..., None]
        col *= (0.985 + 0.015 * weave)[..., None]
        col[stitch] *= 0.62
        scuff = pnoise(n, 3, 20, 21, beta=0.5)
        col *= (1 - 0.08 * np.clip((scuff - 0.78) * 6, 0, 1))[..., None]
        save_rgb(col, "padding_albedo.png")
        save_rgb(normal_from(h, 1.1), "padding_normal.png")
        ao = 0.72 + 0.28 * pill
        rough = 0.88 + 0.06 * fine
        orm = np.stack([ao, rough, np.zeros_like(ao)], -1)
        save_rgb(orm, "padding_orm.png")

    def cushion_tex():
        """Seat cushion: dark blue-grey ripstop with seams, 1 m tile."""
        n = 1024
        y, x = np.mgrid[0:n, 0:n].astype(np.float64)
        rip = (((x % 24) < 1.5) | ((y % 24) < 1.5)).astype(float)
        fine = pnoise(n, 100, 500, 13)
        grime = pnoise(n, 1, 10, 17, beta=1.3)
        base = np.array([0.17, 0.20, 0.25])
        col = np.ones((n, n, 3)) * base
        col *= (0.9 + 0.1 * fine)[..., None]
        col *= (1 + 0.15 * rip)[..., None]
        col *= (0.85 + 0.25 * grime)[..., None]
        h = fine * 0.3 + rip * 0.4
        save_rgb(col, "cushion_albedo.png")
        save_rgb(normal_from(h, 1.2), "cushion_normal.png")
        orm = np.stack([0.85 + 0.15 * fine, 0.8 + 0.1 * fine, np.zeros_like(fine)], -1)
        save_rgb(orm, "cushion_orm.png")

    def strap_tex():
        """Webbing: olive-drab nylon with a herringbone weave, 0.5 m tile."""
        n = 512
        y, x = np.mgrid[0:n, 0:n].astype(np.float64)
        hb = np.sin((x + np.abs((y % 16) - 8)) * np.pi / 4) * 0.5 + 0.5
        fine = pnoise(n, 60, 250, 23)
        base = np.array([0.30, 0.31, 0.21])
        col = np.ones((n, n, 3)) * base * (0.85 + 0.15 * hb)[..., None] * (0.9 + 0.1 * fine)[..., None]
        save_rgb(col, "strap_albedo.png")
        save_rgb(normal_from(hb * 0.6 + fine * 0.2, 1.0), "strap_normal.png")
        save_rgb(np.stack([np.ones_like(hb) * 0.95, 0.85 + 0.05 * hb, np.zeros_like(hb)], -1), "strap_orm.png")

    def fonts():
        from PIL import ImageFont
        cand = {"bold": ["/usr/share/fonts/noto/NotoSans-Bold.ttf"],
                "black": ["/usr/share/fonts/noto/NotoSans-Black.ttf"],
                "mono": [os.path.join(ROOT, "fonts/NotoSansMono-Medium.ttf"), "/usr/share/fonts/noto/NotoSansMono-Medium.ttf"],
                "stencil": [os.path.join(ROOT, "fonts/SolarStencil.ttf"), "/usr/share/fonts/noto/NotoSans-Black.ttf"]}

        def get(kind, size):
            for p in cand[kind]:
                if os.path.exists(p):
                    return ImageFont.truetype(p, size)
            return ImageFont.load_default()
        return get

    def panel_tex():
        """The lit panel atlas: dark grey anodised panels with white
        silk-screened labels, switch legends, breaker rows, gauge faces,
        stencilled placards. Drawn at 2048² with wear."""
        from PIL import Image, ImageDraw
        F = fonts()
        S = PANEL_SIZE
        rng = np.random.default_rng(31)
        base = np.ones((S, S, 3)) * np.array([0.235, 0.245, 0.25])
        g = pnoise(S, 2, 30, 41, beta=1.2)
        base *= (0.88 + 0.2 * g)[..., None]
        im = Image.fromarray(np.clip(base * 255, 0, 255).astype(np.uint8), "RGB")
        d = ImageDraw.Draw(im)
        WHITE, DIM, YEL, RED, BLK = (226, 224, 214), (150, 152, 150), (230, 186, 40), (190, 40, 30), (16, 16, 18)

        def cell(k):
            return PANEL[k]

        def frame_lines(k, inset=10):
            x, y, w, h = cell(k)
            d.rectangle([x + inset, y + inset, x + w - inset, y + h - inset], outline=DIM, width=2)

        def title(k, text, size=28):
            x, y, w, h = cell(k)
            d.text((x + 22, y + 14), text, fill=WHITE, font=F("bold", size))

        def switch_row(k, head, labels, guards=()):
            x, y, w, h = cell(k)
            frame_lines(k)
            title(k, head)
            n = len(labels)
            for i, lab in enumerate(labels):
                cx = x + w * (i + 0.5) / n
                cy = y + h * 0.62
                d.text((cx, y + 62), lab, fill=WHITE, font=F("bold", 20), anchor="mm")
                d.text((cx, cy - 46), "ON", fill=DIM, font=F("bold", 15), anchor="mm")
                d.text((cx, cy + 50), "OFF", fill=DIM, font=F("bold", 15), anchor="mm")
                d.ellipse([cx - 18, cy - 18, cx + 18, cy + 18], outline=DIM, width=2)
                if i in guards:
                    d.rectangle([cx - 34, cy - 30, cx + 34, cy + 30], outline=RED, width=4)
            d.line([x + 20, y + 88, x + w - 20, y + 88], fill=DIM, width=2)

        switch_row("sw_main", "MAIN BUS · FUEL CELL", ["BUS A", "BUS B", "FC 1", "FC 2", "INV 1", "INV 2", "BATT", "XTIE"])
        switch_row("sw_rcs", "RCS · SAS", ["RCS A", "RCS B", "QUAD 1", "QUAD 2", "SAS", "ROLL", "PITCH", "YAW"])
        switch_row("sw_pyro", "SEQUENCER · PYRO", ["LOGIC 1", "LOGIC 2", "CHUTE", "DROGUE", "SEP ARM", "PYRO A", "PYRO B", "JETT"],
                   guards=(5, 6, 7))
        switch_row("sw_comm", "COMM · LIGHTS", ["VHF A", "VHF B", "S-BAND", "BEACON", "FLOOD", "PANEL", "UTIL", "DOCK"])
        # circuit breakers
        x, y, w, h = cell("cb")
        frame_lines("cb")
        title("cb", "CIRCUIT BREAKERS — MAIN BUS A / B")
        names = ["SAS", "RCS", "FC", "BATT", "INV", "GUID", "COMM", "LTS", "ECS", "O2", "CO2", "HTR"]
        for r in range(4):
            yy = y + 110 + r * 96
            d.text((x + 24, yy - 30), ["BUS A", "BUS B", "ESS", "PYRO"][r], fill=YEL, font=F("bold", 18))
            for c in range(12):
                cx = x + 60 + c * ((w - 100) / 11)
                d.text((cx, yy - 10), names[(c + r * 3) % 12], fill=WHITE, font=F("bold", 14), anchor="mm")
                d.ellipse([cx - 14, yy + 12, cx + 14, yy + 40], outline=DIM, width=2)
                d.text((cx, yy + 54), "%d" % (5 * (1 + (c + r) % 4)), fill=DIM, font=F("bold", 12), anchor="mm")
        # keypad
        x, y, w, h = cell("keypad")
        frame_lines("keypad")
        keys = ["VERB", "NOUN", "+", "-", "7", "8", "9", "CLR", "4", "5", "6", "PRO", "1", "2", "3", "KEY", "0", "ENTR", "RSET", "REL"]
        for i, k in enumerate(keys):
            cx, cy = x + 70 + (i % 4) * 120, y + 70 + (i // 4) * 92
            d.rounded_rectangle([cx - 46, cy - 34, cx + 46, cy + 34], radius=8, fill=(40, 42, 44), outline=DIM, width=2)
            d.text((cx, cy), k, fill=WHITE, font=F("bold", 22), anchor="mm")
        # blank panel with screws
        x, y, w, h = cell("blank")
        for (sx, sy) in ((x + 30, y + 30), (x + w - 30, y + 30), (x + 30, y + h - 30), (x + w - 30, y + h - 30)):
            d.ellipse([sx - 12, sy - 12, sx + 12, sy + 12], fill=(120, 120, 118))
            d.line([sx - 8, sy, sx + 8, sy], fill=BLK, width=3)
        # gauge faces
        gauges = [("O2 PRESS", "PSI", 0, 1000, 0.72, [(0.0, 0.15, RED), (0.15, 0.3, YEL)]),
                  ("CABIN", "PSI", 0, 16, 0.88, [(0.0, 0.25, RED)]),
                  ("CO2", "mmHg", 0, 30, 0.12, [(0.6, 1.0, RED), (0.4, 0.6, YEL)]),
                  ("BUS VOLTS", "V", 0, 40, 0.70, [(0.0, 0.5, RED)]),
                  ("PROP", "%", 0, 100, 0.62, [(0.0, 0.1, RED)]),
                  ("TEMP", "°C", -50, 150, 0.45, [(0.8, 1.0, RED)]),
                  ("ALT", "x1000 M", 0, 10, 0.31, []),
                  ("AIRSPEED", "KT", 0, 600, 0.40, [(0.85, 1.0, RED)])]
        for gi, (lab, unit, lo, hi, val, arcs) in enumerate(gauges):
            x, y, w, h = cell("g%d" % gi)
            cx, cy, R = x + w / 2, y + h / 2, w * 0.47
            d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(14, 14, 15))
            a0, a1 = 135, 405
            for (f0, f1, col) in arcs:
                d.arc([cx - R * 0.86, cy - R * 0.86, cx + R * 0.86, cy + R * 0.86], a0 + (a1 - a0) * f0, a0 + (a1 - a0) * f1, fill=col, width=10)
            for t in range(41):
                a = math.radians(a0 + (a1 - a0) * t / 40)
                r0 = R * (0.74 if t % 5 == 0 else 0.80)
                d.line([cx + math.cos(a) * r0, cy + math.sin(a) * r0, cx + math.cos(a) * R * 0.9, cy + math.sin(a) * R * 0.9],
                       fill=WHITE, width=3 if t % 5 == 0 else 1)
                if t % 10 == 0:
                    v = lo + (hi - lo) * t / 40
                    d.text((cx + math.cos(a) * R * 0.58, cy + math.sin(a) * R * 0.58), "%g" % round(v, 1), fill=WHITE,
                           font=F("bold", 17), anchor="mm")
            d.text((cx, cy + R * 0.42), lab, fill=WHITE, font=F("bold", 15), anchor="mm")
            d.text((cx, cy + R * 0.62), unit, fill=DIM, font=F("bold", 12), anchor="mm")
            a = math.radians(a0 + (a1 - a0) * val)
            d.line([cx - math.cos(a) * R * 0.12, cy - math.sin(a) * R * 0.12, cx + math.cos(a) * R * 0.82, cy + math.sin(a) * R * 0.82],
                   fill=(236, 236, 228), width=5)
            d.ellipse([cx - 9, cy - 9, cx + 9, cy + 9], fill=(60, 60, 60))

        def placard(k, text, sub=None, bg=YEL, fg=BLK, size=40):
            x, y, w, h = cell(k)
            d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=bg)
            d.rectangle([x + 10, y + 10, x + w - 10, y + h - 10], outline=fg, width=3)
            d.text((x + w / 2, y + h / 2 - (12 if sub else 0)), text, fill=fg, font=F("black", size), anchor="mm")
            if sub:
                d.text((x + w / 2, y + h / 2 + 28), sub, fill=fg, font=F("bold", 16), anchor="mm")

        placard("fire", "FIRE EXT", "PULL PIN · AIM · SQUEEZE", bg=RED, fg=WHITE, size=34)
        placard("o2", "OXYGEN", "HIGH PRESSURE", bg=(40, 120, 60), fg=WHITE, size=36)
        placard("hatch", "HATCH — TURN TO OPEN  ↺", "EQUALISE CABIN PRESSURE FIRST", size=34)
        placard("pyro", "DANGER  PYRO", "HATCH JETTISON — LIFT GUARD", bg=RED, fg=WHITE, size=34)
        placard("nostep", "NO STEP", None, size=40)
        x, y, w, h = cell("serial")
        d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=(170, 168, 160))
        d.text((x + 14, y + 16), "P/N 7120-448-02", fill=BLK, font=F("mono", 18))
        d.text((x + 14, y + 46), "S/N 00%d31" % 7, fill=BLK, font=F("mono", 18))
        d.text((x + 14, y + 76), "SOLAR EXPL. AGENCY", fill=BLK, font=F("mono", 14))
        x, y, w, h = cell("hazard")
        for i in range(-2, w // 40 + 2):
            d.polygon([(x + i * 40, y + h), (x + i * 40 + 20, y + h), (x + i * 40 + 20 + h, y), (x + i * 40 + h, y)], fill=YEL if i % 2 else BLK)
        x, y, w, h = cell("emerg")
        d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=(200, 196, 182))
        d.text((x + 18, y + 14), "EMERGENCY EGRESS", fill=RED, font=F("black", 26))
        for i, line in enumerate(["1. HELMET ON — VISOR DOWN", "2. SUIT O2 — CHECK GREEN", "3. CABIN VENT — OPEN",
                                  "4. HATCH — LIFT GUARD, PULL T-HANDLE"]):
            d.text((x + 18, y + 54 + i * 30), line, fill=BLK, font=F("bold", 18))
        # grille: perforated metal
        x, y, w, h = cell("grille")
        d.rectangle([x, y, x + w, y + h], fill=(70, 72, 72))
        for i in range(0, w, 16):
            for j in range(0, h, 16):
                d.ellipse([x + i + 4, y + j + 4, x + i + 12, y + j + 12], fill=(12, 12, 13))
        for k, text in (("stow", "STOWAGE  A-3  ·  FOOD · HYGIENE"), ("stow2", "STOWAGE  B-1  ·  TOOLS · SPARES")):
            x, y, w, h = cell(k)
            d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=(205, 200, 186))
            d.text((x + w / 2, y + h / 2), text, fill=BLK, font=F("bold", 28), anchor="mm")
        # the jet's side console: rows of legends
        x, y, w, h = cell("sidecon")
        frame_lines("sidecon")
        for i, row in enumerate(["ENG START  ·  IGN  ·  FUEL", "GEN 1 · GEN 2 · BATT", "NAV · ANTI-COLL · FORM",
                                 "ECS · PRESS · DEFOG", "RADIO  UHF · VHF · IFF"]):
            d.text((x + 24, y + 22 + i * 46), row, fill=WHITE, font=F("bold", 22))
            d.line([x + 20, y + 58 + i * 46, x + w - 20, y + 58 + i * 46], fill=DIM, width=1)
        for k, text in (("eject", "EJECTION SEAT — SAFE / ARM"), ("flight", "SUIT  O2 · COMM · VENT")):
            x, y, w, h = cell(k)
            d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=(30, 30, 32), outline=YEL, width=4)
            d.text((x + w / 2, y + h / 2), text, fill=YEL, font=F("bold", 26), anchor="mm")
        x, y, w, h = cell("rotary")
        frame_lines("rotary")
        title("rotary", "AUDIO · ECS")
        for i, lab in enumerate(["VOL", "SQL", "CABIN T", "SUIT T", "FAN"]):
            cx = x + w * (i + 0.5) / 5
            d.text((cx, y + 70), lab, fill=WHITE, font=F("bold", 20), anchor="mm")
            for t in range(9):
                a = math.radians(135 + 270 * t / 8)
                d.line([cx + math.cos(a) * 44, y + 160 + math.sin(a) * 44, cx + math.cos(a) * 54, y + 160 + math.sin(a) * 54], fill=DIM, width=3)
        x, y, w, h = cell("warnlist")
        d.rectangle([x + 4, y + 4, x + w - 4, y + h - 4], fill=(214, 210, 196))
        d.text((x + 18, y + 12), "BEFORE TAKEOFF", fill=BLK, font=F("black", 28))
        for i, line in enumerate(["CANOPY ........ CLOSED, LOCKED", "SEAT ............ ARMED", "FLAPS ........... TAKEOFF",
                                  "TRIM ............. SET", "LIGHTS ......... ON"]):
            d.text((x + 18, y + 56 + i * 36), line, fill=BLK, font=F("mono", 22))
        # wear: chips along every panel's edge and greasy finger marks
        a = np.asarray(im).astype(np.float64) / 255.0
        wear = pnoise(S, 20, 200, 77, beta=0.8)
        a *= (0.92 + 0.12 * wear)[..., None]
        save_rgb(a, "panel_albedo.png")
        lum = a.mean(-1)
        save_rgb(normal_from(lum * 0.6 + wear * 0.3, 1.2), "panel_normal.png")
        save_rgb(np.stack([np.ones_like(lum) * 0.95, 0.55 + 0.25 * wear, np.zeros_like(lum)], -1), "panel_orm.png")

    def screen_tex():
        """Glowing displays (unlit): an attitude ball, an orbit plot, a
        systems page, engine bars, an annunciator block, a 7-segment DSKY, a
        radar scope and a clock. Scanlines and phosphor bloom."""
        from PIL import Image, ImageDraw, ImageFilter
        F = fonts()
        S = SCREEN_SIZE
        im = Image.new("RGB", (S, S), (4, 7, 6))
        d = ImageDraw.Draw(im)
        G, A, C, R_, Wt = (70, 230, 120), (240, 170, 40), (80, 200, 230), (230, 60, 40), (200, 220, 210)

        def box_(k):
            return SCREEN[k]
        x, y, w, h = box_("adi")
        cx, cy, R = x + w / 2, y + h / 2, w * 0.38
        d.rectangle([x, y, x + w, y + h], fill=(5, 8, 10))
        d.pieslice([cx - R, cy - R, cx + R, cy + R], 190, 370, fill=(30, 90, 150))
        d.pieslice([cx - R, cy - R, cx + R, cy + R], 10, 190, fill=(110, 70, 30))
        for p in range(-3, 4):
            yy = cy + p * 22 + 10
            d.line([cx - 40 + abs(p) * 4, yy, cx + 40 - abs(p) * 4, yy], fill=Wt, width=3)
        d.line([cx - 110, cy + 2, cx - 30, cy + 2], fill=A, width=8)
        d.line([cx + 30, cy + 2, cx + 110, cy + 2], fill=A, width=8)
        d.ellipse([cx - 8, cy - 6, cx + 8, cy + 10], fill=A)
        d.text((x + 20, y + 16), "ATT", fill=G, font=F("mono", 28))
        d.text((x + w - 150, y + 16), "HDG 047", fill=G, font=F("mono", 28))
        d.text((x + 20, y + h - 46), "P +04.2  R -01.8", fill=G, font=F("mono", 26))
        x, y, w, h = box_("orbit")
        d.rectangle([x, y, x + w, y + h], fill=(4, 8, 8))
        cx, cy = x + w / 2, y + h / 2 + 20
        d.ellipse([cx - 60, cy - 60, cx + 60, cy + 60], outline=C, width=3)
        d.ellipse([cx - 190, cy - 130, cx + 160, cy + 130], outline=G, width=3)
        d.ellipse([cx + 150, cy - 8, cx + 168, cy + 10], fill=A)
        d.text((x + 20, y + 16), "ORBIT", fill=G, font=F("mono", 28))
        d.text((x + 20, y + h - 90), "AP  112.4 KM", fill=G, font=F("mono", 26))
        d.text((x + 20, y + h - 50), "PE   84.0 KM", fill=G, font=F("mono", 26))
        x, y, w, h = box_("sys")
        d.rectangle([x, y, x + w, y + h], fill=(4, 6, 4))
        for i, line in enumerate(["SYS  NOMINAL", "BUS A  28.4V  B  28.1V", "O2   91%  CO2  2.1", "CABIN 14.6 PSI  21C", "RCS  A 82%  B 79%"]):
            d.text((x + 16, y + 12 + i * 46), line, fill=G if i else A, font=F("mono", 30))
        x, y, w, h = box_("eng")
        d.rectangle([x, y, x + w, y + h], fill=(4, 6, 6))
        d.text((x + 16, y + 10), "ENG  N1   EGT   FF", fill=G, font=F("mono", 28))
        for i, v in enumerate((0.82, 0.64, 0.71, 0.4, 0.9)):
            bx = x + 40 + i * 92
            d.rectangle([bx, y + 60, bx + 44, y + 220], outline=G, width=2)
            d.rectangle([bx + 4, y + 216 - 152 * v, bx + 40, y + 216], fill=G if v < 0.85 else A)
        x, y, w, h = box_("annun")
        d.rectangle([x, y, x + w, y + h], fill=(10, 10, 10))
        labs = [("MASTER CAUT", None), ("CABIN P", None), ("O2 FLOW", None), ("FUEL CELL", None),
                ("SEP READY", G), ("CHUTE ARM", None), ("GUIDANCE", C), ("RCS", None),
                ("HEAT", None), ("COMM", G), ("ABORT", None), ("GEAR", None)]
        for i, (lab, lit) in enumerate(labs):
            cx0, cy0 = x + 6 + (i % 4) * 126, y + 6 + (i // 4) * 82
            d.rectangle([cx0, cy0, cx0 + 120, cy0 + 76], fill=(lit[0] // 3, lit[1] // 3, lit[2] // 3) if lit else (24, 22, 20),
                        outline=(60, 60, 58), width=2)
            d.text((cx0 + 60, cy0 + 38), lab, fill=(lit if lit else (70, 66, 60)), font=F("bold", 16), anchor="mm")
        x, y, w, h = box_("dsky")
        d.rectangle([x, y, x + w, y + h], fill=(4, 8, 4))
        d.text((x + 14, y + 10), "PROG 15", fill=G, font=F("mono", 22))
        d.text((x + 14, y + 50), "+00347", fill=G, font=F("mono", 34))
        d.text((x + 14, y + 90), "-01206", fill=G, font=F("mono", 22))
        x, y, w, h = box_("radar")
        d.rectangle([x, y, x + w, y + h], fill=(3, 8, 4))
        cx, cy = x + w / 2, y + h - 20
        for r in (60, 120, 180):
            d.arc([cx - r, cy - r, cx + r, cy + r], 210, 330, fill=(30, 110, 50), width=2)
        d.line([cx, cy, cx + 120, cy - 170], fill=G, width=3)
        d.ellipse([cx - 60, cy - 140, cx - 50, cy - 130], fill=A)
        x, y, w, h = box_("clock")
        d.rectangle([x, y, x + w, y + h], fill=(6, 4, 2))
        d.text((x + w / 2, y + h / 2), "041:12:07", fill=A, font=F("mono", 40), anchor="mm")
        # bloom and scanlines
        glow = im.filter(ImageFilter.GaussianBlur(4))
        a = np.asarray(im).astype(np.float64) / 255.0
        g = np.asarray(glow).astype(np.float64) / 255.0
        a = np.clip(a + g * 0.45, 0, 1)
        scan = (np.arange(S) % 4 < 1)[:, None, None]
        a = np.where(scan, a * 0.78, a)
        a = a * 0.85
        save_rgb(a, "screen_albedo.png")

    def textures():
        os.makedirs(OUT_TEX, exist_ok=True)
        padding_tex()
        cushion_tex()
        strap_tex()
        panel_tex()
        screen_tex()
        print("IVA textures ->", OUT_TEX)

    # ── glb ─────────────────────────────────────────────────────────────────
    def write_glb(node_geo, path):
        """One mesh, one primitive per material. Returns (min, max) bounds."""
        bin_ = bytearray()
        views, accs, prims, mats = [], [], [], []
        lo = np.array([1e9] * 3)
        hi = np.array([-1e9] * 3)

        def view(data, target):
            nonlocal bin_
            while len(bin_) % 4:
                bin_ += b"\0"
            off = len(bin_)
            bin_ += data
            views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
            return len(views) - 1
        for mi, mname in enumerate(sorted(node_geo.keys())):
            g = node_geo[mname]
            Pp = np.asarray(g["P"], np.float32).reshape(-1, 3)
            N = np.asarray(g["N"], np.float32).reshape(-1, 3)
            UV = np.asarray(g["UV"], np.float32).reshape(-1, 2)
            # weld identical vertices (position, normal, uv)
            key = np.concatenate([np.round(Pp, 5), np.round(N, 3), np.round(UV, 5)], 1)
            uniq, inv = np.unique(key, axis=0, return_inverse=True)
            inv = inv.reshape(-1)
            first = np.zeros(len(uniq), np.int64)
            first[inv[::-1]] = np.arange(len(inv))[::-1]
            P2, N2, U2 = Pp[first], N[first], UV[first]
            I = inv.astype(np.uint32)
            lo = np.minimum(lo, P2.min(0))
            hi = np.maximum(hi, P2.max(0))
            vp = view(P2.astype(np.float32).tobytes(), 34962)
            accs.append({"bufferView": vp, "componentType": 5126, "count": len(P2), "type": "VEC3",
                         "min": P2.min(0).tolist(), "max": P2.max(0).tolist()})
            ap = len(accs) - 1
            vn = view(N2.astype(np.float32).tobytes(), 34962)
            accs.append({"bufferView": vn, "componentType": 5126, "count": len(N2), "type": "VEC3"})
            an = len(accs) - 1
            vu = view(U2.astype(np.float32).tobytes(), 34962)
            accs.append({"bufferView": vu, "componentType": 5126, "count": len(U2), "type": "VEC2"})
            au = len(accs) - 1
            vi = view(I.tobytes(), 34963)
            accs.append({"bufferView": vi, "componentType": 5125, "count": len(I), "type": "SCALAR"})
            ai = len(accs) - 1
            mats.append({"name": mname, "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1.0],
                                                                 "metallicFactor": 0.0, "roughnessFactor": 0.6}})
            prims.append({"attributes": {"POSITION": ap, "NORMAL": an, "TEXCOORD_0": au}, "indices": ai, "material": mi})
        gl = {"asset": {"version": "2.0", "generator": "Solar tools/gen_iva.py"},
              "scene": 0, "scenes": [{"nodes": [0]}],
              "nodes": [{"name": os.path.splitext(os.path.basename(path))[0], "mesh": 0}],
              "meshes": [{"name": "iva", "primitives": prims}],
              "materials": mats, "accessors": accs, "bufferViews": views,
              "buffers": [{"byteLength": len(bin_)}]}
        js = json.dumps(gl, separators=(",", ":")).encode()
        while len(js) % 4:
            js += b" "
        while len(bin_) % 4:
            bin_ += b"\0"
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_)))
            f.write(struct.pack("<II", len(js), 0x4E4F534A))
            f.write(js)
            f.write(struct.pack("<II", len(bin_), 0x004E4942))
            f.write(bytes(bin_))
        return lo, hi

    # ── materials (prefab RON) ──────────────────────────────────────────────
    def tiled(tex, color=(1, 1, 1), rough=1.0, metal=0.0, nstr=1.0, root=PT):
        c = "(%g, %g, %g)" % color
        return (f'(\n                color: {c},\n                texture: Some("{root}{tex}_albedo.png"),\n'
                f'                normal_map: Some("{root}{tex}_normal.png"),\n                normal_strength: {nstr},\n'
                f'                roughness_map: Some("{root}{tex}_orm.png"),\n                roughness: {rough},\n'
                f'                metallic_map: Some("{root}{tex}_orm.png"),\n                metallic: {metal},\n'
                f'                ao_map: Some("{root}{tex}_orm.png"),\n                shading: Physical,\n            )')

    MATS = {
        "Padding": lambda: tiled("padding", (1, 1, 1), 1.0, 0.0, 1.0, TEX),
        "Cushion": lambda: tiled("cushion", (1, 1, 1), 1.0, 0.0, 1.0, TEX),
        "Strap": lambda: tiled("strap", (1, 1, 1), 1.0, 0.0, 1.0, TEX),
        "Panel": lambda: tiled("panel", (1, 1, 1), 1.0, 0.0, 0.6, TEX),
        "Gauge": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("' + TEX + 'panel_albedo.png"),\n'
                          '                roughness: 0.5,\n                metallic: 0.0,\n                emissive: (1.0, 0.92, 0.8),\n'
                          '                emissive_strength: 0.06,\n                shading: Physical,\n            )'),
        "Screen": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("' + TEX + 'screen_albedo.png"),\n'
                           '                unlit: true,\n                fog: false,\n            )'),
        "Lamp": lambda: ('(\n                color: (1.0, 0.95, 0.85),\n                emissive: (1.0, 0.9, 0.75),\n'
                         '                emissive_strength: 1.1,\n                roughness: 0.4,\n                shading: Physical,\n            )'),
        "Glass": lambda: ('(\n                color: (0.55, 0.62, 0.64),\n                roughness: 0.05,\n                metallic: 0.0,\n'
                          '                alpha: 0.10,\n                blend: Some(Blend),\n                fog: false,\n                shading: Physical,\n            )'),
        "PanelPaint": lambda: tiled("paint", (0.36, 0.38, 0.38), 1.1, 0.6),
        "Paint": lambda: tiled("paint", (0.9, 0.9, 0.88), 1.0, 0.8),
        "Metal": lambda: tiled("metal", (0.8, 0.8, 0.8), 1.0, 0.6),
        "Dark": lambda: tiled("metal", (0.16, 0.16, 0.17), 1.2, 0.4),
        "Chrome": lambda: tiled("metal", (1.0, 1.0, 1.0), 0.45, 0.9),
        "Tread": lambda: tiled("tread", (0.7, 0.7, 0.7), 1.0, 0.7),
        "Rubber": lambda: tiled("rubber", (0.35, 0.35, 0.35), 1.0, 0.0),
        "Hose": lambda: tiled("rubber", (0.55, 0.45, 0.32), 1.0, 0.0),
        "Foil": lambda: tiled("foil", (1, 1, 1), 1.0, 1.0),
        "Yellow": lambda: tiled("paint", (0.85, 0.62, 0.10), 1.0, 0.3),
        "Red": lambda: tiled("paint", (0.62, 0.10, 0.07), 1.0, 0.3),
        "Suit": lambda: ('(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("textures/suit/fabric_albedo.png"),\n'
                         '                normal_map: Some("textures/suit/fabric_normal.png"),\n                normal_strength: 1.0,\n'
                         '                roughness_map: Some("textures/suit/fabric_orm.png"),\n                roughness: 1.0,\n'
                         '                metallic_map: Some("textures/suit/fabric_orm.png"),\n                metallic: 1.0,\n'
                         '                ao_map: Some("textures/suit/fabric_orm.png"),\n                shading: Physical,\n            )'),
    }

    def materials_block(names, indent=8):
        lines = []
        for m in sorted(names):
            body = MATS.get(m, MATS["Dark"])()
            lines.append(f'                "{m}": {body},')
        return "object_materials: {\n" + "\n".join(lines) + "\n            },"

    def quat_from_basis(Bx, By, Bz):
        """The rotation whose columns are the images of X, Y, Z."""
        m = np.array([Bx, By, Bz], float).T
        tr = m[0, 0] + m[1, 1] + m[2, 2]
        if tr > 0:
            s = math.sqrt(tr + 1.0) * 2
            w, x, y, z = 0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s
        elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
            s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
            w, x, y, z = (m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s
        elif m[1, 1] > m[2, 2]:
            s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
            w, x, y, z = (m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s
        else:
            s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
            w, x, y, z = (m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s
        return (round(x, 6), round(y, 6), round(z, 6), round(w, 6))

    def node_ron(name, t, q, matter, parent, extra=""):
        par = f"\n        parent: Some({parent})," if parent is not None else ""
        return (f'    (\n        name: "{name}",\n        transform: (\n            translation: ({t[0]:.4f}, {t[1]:.4f}, {t[2]:.4f}),\n'
                f'            rotation: ({q[0]}, {q[1]}, {q[2]}, {q[3]}),\n            scale: (1.0, 1.0, 1.0),\n        ),\n'
                f'        {matter}\n{extra}        scripts: [],{par}\n    ),')

    def write_prefab(name, d, lo, hi, mats, self_lo, self_hi, self_mats):
        """Root (the part's frame, at its origin) > Basis (the seat frame) >
        Shell mesh, Seat<k> / Eye<k> empties, Self<k> (the wearer, hidden
        until scripts/iva.lua shows the eye seat's), Lamp<k>."""
        out = ["// IVA interior (tools/gen_iva.py; docs/crew-and-items.md §3.4, §4.4). Generated: do not edit.",
               "// Root: the PART's origin and frame. Basis: the seat frame (+X right, +Y up, -Z ahead).",
               "// Built at human scale, drawn only by the interior cameras (layer `interior`, set by",
               "// scripts/iva.lua): see the generator's header for why it is bigger than the hull.",
               "["]
        I = lambda: (0.0, 0.0, 0.0, 1.0)  # noqa: E731
        bq = quat_from_basis(*d["basis"])
        em = d["eye_main"]
        out.append(node_ron(name, (0, 0, 0), I(), "matter: Empty,", None,
                            f'        // eye_main: the main camera\'s eye in the part frame\n'))
        out.append(node_ron("Basis", (0, 0, 0), bq, "matter: Empty,", 0))
        c = (lo + hi) / 2
        out.append(node_ron("Shell", tuple(c), I(), f'matter: Mesh(\n            asset_path: "models/iva/{name.lower()}.glb",\n        ),\n        ' +
                            materials_block(mats) + "\n        cast_shadow: false,", 1))
        idx = 3
        out.append(node_ron("EyeMain", (em[0], em[1], em[2]), I(), "matter: Empty,", 0))
        idx += 1
        sc = (self_lo + self_hi) / 2
        for k, s in enumerate(d["seats"]):
            x, y, z, yaw = s
            qy = (0.0, round(math.sin(-yaw / 2), 6), 0.0, round(math.cos(-yaw / 2), 6))
            out.append(node_ron("Seat%d" % (k + 1), (x, y, z), qy, "matter: Empty,", 1))
            seat_i = idx
            idx += 1
            out.append(node_ron("Eye%d" % (k + 1), (0.0, EYE_UP, -EYE_FWD), I(), "matter: Empty,", seat_i))
            idx += 1
            out.append(node_ron("Self%d" % (k + 1), tuple(sc), I(), f'matter: Mesh(\n            asset_path: "models/iva/self.glb",\n        ),\n        ' +
                                materials_block(self_mats) + "\n        cast_shadow: false,\n        disabled: true,", seat_i))
            idx += 1
        for k, lp in enumerate(d["lamps"]):
            out.append(node_ron("Lamp%d" % (k + 1), lp, I(),
                                "matter: PointLight(\n            color: (1.0, 0.88, 0.72),\n            intensity: 1.6,\n            range: 2.6,\n        ),",
                                1, "        disabled: true,\n"))
            idx += 1
        out.append("]")
        path = os.path.join(OUT_PREFABS, name + ".prefab.ron")
        with open(path, "w") as f:
            f.write("\n".join(out) + "\n")
        return path

    def py_main():
        args = sys.argv[1:]
        if "--no-tex" not in args:
            textures()
        if "--tex" in args:
            return
        os.makedirs(OUT_MODELS, exist_ok=True)
        tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "iva_mesh_%d.json" % os.getpid())
        cmd = [BLENDER, "--background", "--factory-startup", "--python", os.path.abspath(__file__), "--", tmp]
        r = subprocess.run(cmd, capture_output=True, text=True)
        for line in (r.stdout + r.stderr).splitlines():
            if line.startswith("IVA") or "Error" in line or "Traceback" in line or line.startswith("  "):
                print(line)
        if r.returncode != 0 or not os.path.exists(tmp):
            sys.exit("Blender failed")
        with open(tmp) as f:
            res = json.load(f)
        os.remove(tmp)
        sg = res.pop("self")["Self"]
        slo, shi = write_glb(sg, os.path.join(OUT_MODELS, "self.glb"))
        for name, geo in res.items():
            shell = geo["Shell"]
            lo, hi = write_glb(shell, os.path.join(OUT_MODELS, name.lower() + ".glb"))
            p = write_prefab(name, IVAS[name], lo, hi, shell.keys(), slo, shi, sg.keys())
            tris = sum(len(m["P"]) // 9 for m in shell.values())
            print(f"{name}: {tris} tris, {len(shell)} materials, box {np.round(hi - lo, 2)} -> {os.path.relpath(p, ROOT)}")

    if __name__ == "__main__":
        py_main()
