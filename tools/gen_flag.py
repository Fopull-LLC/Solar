#!/usr/bin/env python3
"""Generate the agency's FLAG and EMBLEM PLATES (docs/crew-and-items.md §2.5, §7).

    python3 tools/gen_flag.py

Models (models/parts/):
    flag_pole.glb      a 2.2 m aluminium pole with a ground spike, a collar
                       and a finial; the root of the Flag prefab
    flag_bar.glb       the Apollo crossbar the cloth hangs from (it turns
                       with the cloth, so it is its own node)
    flag_cloth.glb     the 1.2 × 0.8 m sheet, 24 × 12 quads, UV u = 0 at the
                       pole → 1 at the fly end, v = 0 at the top
    emblem_plate_*.glb a bezelled plate (frame) and emblem_face_*.glb its
                       face, flat or curved to the hull it sits on

Prefabs (prefabs/):
    Flag, FlagGhost, FlagGhostBad   the planted flag and its placement ghosts
    EmblemPlate                      a free-standing plate (frame + face)
    DeployLib                        scripts/deployables.lua's node
    AgencyLib                        scripts/emblem.lua's node
    Remains                          a fallen crew member (the deployables
                                     store's `remains` kind)

and the "Emblem Plate" children injected into PartPod, PartSeat and
PartCockpit (re-run this after tools/gen_seat.py or gen_part_meshes.py, which
rewrite those prefabs).

Default textures (textures/parts/emblem_default.png, flag_default.png) are
the Lua rasteriser's own output for the default agency name (it runs
luajit on scripts/emblem.lua), shown until the runtime texture is built.

The engine recentres a model on its bounding box, so each mesh's node sits at
its box centre in the prefab's frame; the Flag's root is the pole, whose
centre is FLAG_ORIGIN above the ground (scripts/deployables.lua plants it
there).
"""
import math
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import MATERIALS, MODELS, PREFABS, Model, box, tube, write_glb  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEXDIR = os.path.join(ROOT, "textures", "parts")

POLE_TOP = 2.20       # m above the ground
SPIKE = 0.35          # m driven into the ground
POLE_R = 0.018
CLOTH_W, CLOTH_H = 1.20, 0.80
CLOTH_NX, CLOTH_NY = 24, 12
BAR_Y = 2.15          # the crossbar (and the cloth's top edge)
CLOTH_X0 = 0.03       # the cloth's pole edge (the sleeve sits round the pole)


def pole_model():
    m = Model()
    tube(m, "Chrome", (0, 0.05, 0), (0, POLE_TOP, 0), POLE_R, segs=14, uv_m=3.0)
    tube(m, "Metal", (0, -SPIKE + 0.06, 0), (0, 0.05, 0), POLE_R * 0.85, segs=12)
    tube(m, "Metal", (0, -SPIKE, 0), (0, -SPIKE + 0.06, 0), 0.002, segs=10, r1=POLE_R * 0.85)
    tube(m, "Dark", (0, 0.02, 0), (0, 0.11, 0), POLE_R * 1.7, segs=14)        # the ground collar
    tube(m, "Dark", (0, BAR_Y - 0.03, 0), (0, BAR_Y + 0.03, 0), POLE_R * 1.6, segs=14)  # the bar's clamp
    tube(m, "Chrome", (0, POLE_TOP, 0), (0, POLE_TOP + 0.035, 0), POLE_R * 1.5, segs=12, r1=POLE_R * 0.5)
    return m


def bar_model():
    m = Model()
    tube(m, "Chrome", (0.0, 0.0, 0.0), (CLOTH_X0 + CLOTH_W + 0.02, 0.0, 0.0), 0.008, segs=8, uv_m=3.0)
    tube(m, "Dark", (CLOTH_X0 + CLOTH_W + 0.02, 0.0, 0.0), (CLOTH_X0 + CLOTH_W + 0.045, 0.0, 0.0), 0.011, segs=8)
    return m


def cloth_model():
    m = Model()
    P, N, UV, I = [], [], [], []
    for j in range(CLOTH_NY + 1):
        for i in range(CLOTH_NX + 1):
            u, v = i / CLOTH_NX, j / CLOTH_NY
            P.append((CLOTH_X0 + u * CLOTH_W, BAR_Y - 0.012 - v * CLOTH_H, 0.0))
            N.append((0, 0, 1))
            UV.append((u, v))
    for j in range(CLOTH_NY):
        for i in range(CLOTH_NX):
            a = j * (CLOTH_NX + 1) + i
            b, c, d = a + 1, a + CLOTH_NX + 1, a + CLOTH_NX + 2
            I.append((a, c, b)); I.append((b, c, d))
    m.add("Cloth", P, N, UV, I)
    return m


def plate_models(curve, size, depth=0.008, rim=0.012):
    """A plate in the XY plane facing +Z, its back on z = 0, bent round a
    vertical axis of radius `curve` (0 = flat) so it sits on a round hull.
    Returns (frame, face)."""
    def bend(p):
        x, y, z = p
        if curve <= 0:
            return np.array([x, y, z])
        a = x / curve
        r = curve + z
        return np.array([math.sin(a) * r, y, math.cos(a) * r - curve])

    def bent(m, nx=8):
        # rebuild every part with its X subdivided and bent
        out = Model()
        for mat, (P, Nn, UV, I) in m.arrays().items():
            out.add(mat, [bend(p) for p in P], [bend_n(p, n) for p, n in zip(P, Nn)], UV, I)
        return out

    def bend_n(p, n):
        if curve <= 0:
            return n
        a = p[0] / curve
        c, s = math.cos(a), math.sin(a)
        return np.array([n[0] * c + n[2] * s, n[1], -n[0] * s + n[2] * c])

    half = size / 2
    frame = Model()
    # the back plate, as a grid so it can bend
    seg = 10
    P, Nn, UV, I = [], [], [], []
    for side, z, nz in ((0, depth * 0.5, 1), (1, 0.0, -1)):
        base = len(P)
        for j in range(2):
            for i in range(seg + 1):
                x = -half + size * i / seg
                y = -half + size * j
                P.append((x, y, z)); Nn.append((0, 0, nz)); UV.append((x * 2, y * 2))
        for i in range(seg):
            a = base + i
            I.append((a, a + 1, a + seg + 2)); I.append((a, a + seg + 2, a + seg + 1))
    frame.add("Metal", P, Nn, UV, I)
    # the bezel: four bars, each subdivided along its length
    for k in range(seg):
        x0 = -half + size * k / seg
        w = size / seg
        box(frame, "Dark", (x0 + w / 2, half - rim / 2, depth * 0.75), (w * 1.01, rim, depth * 0.5))
        box(frame, "Dark", (x0 + w / 2, -half + rim / 2, depth * 0.75), (w * 1.01, rim, depth * 0.5))
    box(frame, "Dark", (half - rim / 2, 0, depth * 0.75), (rim, size, depth * 0.5))
    box(frame, "Dark", (-half + rim / 2, 0, depth * 0.75), (rim, size, depth * 0.5))
    # four rivets
    for sx in (-1, 1):
        for sy in (-1, 1):
            box(frame, "Chrome", (sx * (half - rim / 2), sy * (half - rim / 2), depth * 1.05), (rim * 0.45, rim * 0.45, depth * 0.2))
    face = Model()
    fh = half - rim * 0.95
    P, Nn, UV, I = [], [], [], []
    for j in range(2):
        for i in range(seg + 1):
            x = -fh + 2 * fh * i / seg
            y = fh - 2 * fh * j
            P.append((x, y, depth * 0.55)); Nn.append((0, 0, 1)); UV.append((i / seg, j))
    for i in range(seg):
        a = i
        I.append((a, a + seg + 1, a + 1)); I.append((a + 1, a + seg + 1, a + seg + 2))
    face.add("Emblem", P, Nn, UV, I)
    return bent(frame), bent(face)


def centre(m):
    mn, mx = m.bounds()
    return (mn + mx) / 2


def f3(v):
    return "(%.4f, %.4f, %.4f)" % tuple(float(x) for x in v)


def quat_from_matrix(M):
    m = np.asarray(M, float)
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
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
    return (x, y, z, w)


def facing(n, up=(0, 1, 0)):
    """A rotation taking +Z onto the unit normal n with +Y as near `up` as it goes."""
    z = np.asarray(n, float); z /= np.linalg.norm(z)
    y = np.asarray(up, float) - z * np.dot(up, z); y /= np.linalg.norm(y)
    x = np.cross(y, z)
    return np.c_[x, y, z]


def mats_text(model, ind="            "):
    names = sorted(model.parts.keys())
    return ",\n".join(f'{ind}"{n}": {MATERIALS[n]()}' for n in names)


EMBLEM_FACE_MAT = '''(
                color: (1.0, 1.0, 1.0),
                texture: Some("textures/parts/emblem_default.png"),
                roughness: 0.55,
                metallic: 0.15,
                blend: Some(Blend),
                shading: Physical,
            )'''

CLOTH_MAT = '''(
                color: (1.0, 1.0, 1.0),
                texture: Some("textures/parts/flag_default.png"),
                roughness: 0.9,
                metallic: 0.0,
                shader: Some("shaders/flag_cloth.flsl"),
                shading: Physical,
            )'''


REMAINS_BODY = """        rigidbody: Some((
            boxed: true,
            mode: Static,
            radius: 0.3,
            height: 0.36,
            half_extents: (0.35, 0.18, 0.9),
            restitution: 0.05,
            friction: 0.8,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.02,
        )),
"""

SUIT_MATS = """            "SuitFabric": (
                color: (0.86, 0.85, 0.82),
                texture: Some("textures/suit/fabric_albedo.png"),
                normal_map: Some("textures/suit/fabric_normal.png"),
                normal_strength: 1.0,
                roughness_map: Some("textures/suit/fabric_orm.png"),
                roughness: 1.0,
                metallic_map: Some("textures/suit/fabric_orm.png"),
                metallic: 1.0,
                ao_map: Some("textures/suit/fabric_orm.png"),
                shading: Physical,
            ),
            "SuitShell": (
                color: (0.86, 0.85, 0.82),
                texture: Some("textures/suit/shell_albedo.png"),
                normal_map: Some("textures/suit/shell_normal.png"),
                normal_strength: 0.7,
                roughness_map: Some("textures/suit/shell_orm.png"),
                roughness: 1.0,
                metallic_map: Some("textures/suit/shell_orm.png"),
                metallic: 1.0,
                ao_map: Some("textures/suit/shell_orm.png"),
                shading: Physical,
            ),
            "SuitMetal": (
                color: (1.0, 1.0, 1.0),
                texture: Some("textures/parts/metal_albedo.png"),
                normal_map: Some("textures/parts/metal_normal.png"),
                roughness_map: Some("textures/parts/metal_orm.png"),
                roughness: 0.7,
                metallic_map: Some("textures/parts/metal_orm.png"),
                metallic: 0.6,
                shading: Physical,
            ),
            "SuitHead": (
                color: (1.0, 1.0, 1.0),
                texture: Some("textures/suit/head.png"),
                roughness: 0.7,
                metallic: 0.0,
                shading: Physical,
            ),
            "SuitDecal": (
                color: (1.0, 1.0, 1.0),
                texture: Some("textures/suit/decals.png"),
                roughness: 0.8,
                metallic: 0.0,
                shading: Physical,
            )"""


def node(name, parent, t, matter, mats=None, material=None, scripts="[]", extra="", rot=(0.0, 0.0, 0.0, 1.0)):
    s = f'''    (
        name: "{name}",
        transform: (
            translation: {f3(t)},
            rotation: ({rot[0]:.5f}, {rot[1]:.5f}, {rot[2]:.5f}, {rot[3]:.5f}),
            scale: (1.0, 1.0, 1.0),
        ),
        matter: {matter},
'''
    if mats:
        s += f"        object_materials: {{\n{mats},\n        }},\n"
    if material:
        s += f"        material: Some({material}),\n"
    s += f"        scripts: {scripts},\n{extra}"
    if parent is not None:
        s += f"        parent: Some({parent}),\n"
    return s + "    ),\n"


def mesh(path):
    return f'Mesh(\n            asset_path: "{path}",\n        )'


def ghost_mat(rgb):
    r, g, b = rgb
    return (f"(\n            color: ({r}, {g}, {b}),\n            emissive: ({r}, {g}, {b}),\n"
            f"            emissive_strength: 0.8,\n            unlit: true,\n            alpha: 0.5,\n        )")


def main():
    pole, bar, cloth = pole_model(), bar_model(), cloth_model()
    write_glb(pole, os.path.join(MODELS, "flag_pole.glb"))
    write_glb(bar, os.path.join(MODELS, "flag_bar.glb"))
    write_glb(cloth, os.path.join(MODELS, "flag_cloth.glb"))
    cp, cb, cc = centre(pole), centre(bar), centre(cloth)
    print("flag pole centre", np.round(cp, 4), "(FLAG_ORIGIN = %.4f)" % cp[1])
    # Root = the pole (its centre at FLAG_ORIGIN above the ground); the cloth's
    # pivot sits on the pole axis at the bar's height, so turning it swings the
    # bar and the cloth round the pole together.
    pivot = np.array([0.0, BAR_Y, 0.0]) - cp
    bar_t = cb                          # the bar is built at the pivot (y = 0)
    cloth_t = cc - np.array([0.0, BAR_Y, 0.0])
    collider = f'''        rigidbody: Some((
            boxed: true,
            mode: Static,
            radius: 0.06,
            height: {POLE_TOP + SPIKE:.3f},
            half_extents: (0.06, {(POLE_TOP + SPIKE) / 2:.3f}, 0.06),
            restitution: 0.05,
            friction: 0.8,
            gravity: false,
            lock_pos: (false, false, false),
            lock_rot: (false, false, false),
            mass: 0.02,
        )),
'''
    flag = "// FLAG — the agency's flag, planted (scripts/deployables.lua spawns one per\n" \
           "// planted flag, parented to its planet; origin FLAG_ORIGIN above the ground).\n" \
           "// scripts/flag.lua waves it in the local wind (shaders/flag_cloth.flsl).\n" \
           "// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n"
    flag += node("Flag", None, (0, 0, 0), mesh("models/parts/flag_pole.glb"), mats=mats_text(pole),
                 scripts='[\n            (\n                kind: "flag",\n                enabled: true,\n                params: [],\n            ),\n        ]',
                 extra=collider).replace('        name: "Flag",\n', '        name: "Flag",\n        tags: ["flag", "deployable"],\n')
    flag += node("Flag Pivot", 0, pivot, "Empty")
    flag += node("Flag Bar", 1, bar_t, mesh("models/parts/flag_bar.glb"), mats=mats_text(bar))
    flag += node("Flag Cloth", 1, cloth_t, mesh("models/parts/flag_cloth.glb"), material=CLOTH_MAT.replace("\n            ", "\n        "))
    flag += "]\n"
    open(os.path.join(PREFABS, "Flag.prefab.ron"), "w").write(flag)
    for name, rgb, what in (("FlagGhost", (0.30, 0.95, 0.80), "where it can stand"),
                            ("FlagGhostBad", (1.0, 0.38, 0.30), "where it can't")):
        g = f"// {name.upper()} — the flag's placement preview, {what} (the tool belt's deploy mode).\n" \
            "// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n"
        g += node(name, None, (0, 0, 0), mesh("models/parts/flag_pole.glb"), material=ghost_mat(rgb))
        g += node(name + " Pivot", 0, pivot, "Empty")
        g += node(name + " Cloth", 1, cloth_t, mesh("models/parts/flag_cloth.glb"), material=ghost_mat(rgb))
        g += "]\n"
        open(os.path.join(PREFABS, name + ".prefab.ron"), "w").write(g)

    # ── plates ──
    plates = {}
    for key, curve, size in (("flat", 0.0, 0.18), ("r44", 0.44, 0.16), ("r60", 0.60, 0.22)):
        fr, fa = plate_models(curve, size)
        write_glb(fr, os.path.join(MODELS, f"emblem_plate_{key}.glb"))
        write_glb(fa, os.path.join(MODELS, f"emblem_face_{key}.glb"))
        plates[key] = (fr, fa, centre(fr), centre(fa))

    def plate_nodes(parent, at, n, key, first_index, name="Emblem Plate"):
        """The plate frame (with the script) and its face, as nodes; `at` the
        point on the hull, `n` the hull's outward normal there."""
        fr, fa, cf, cfa = plates[key]
        R = facing(n)
        q = quat_from_matrix(R)
        t = np.asarray(at, float) + R @ cf
        s = node(name, parent, t, mesh(f"models/parts/emblem_plate_{key}.glb"), mats=mats_text(fr),
                 scripts='[\n            (\n                kind: "emblem_plate",\n                enabled: true,\n                params: [],\n            ),\n        ]',
                 rot=q)
        s += node(name + " Face", first_index, cfa - cf, mesh(f"models/parts/emblem_face_{key}.glb"),
                  material=EMBLEM_FACE_MAT.replace("\n            ", "\n        "))
        return s

    ep = "// EMBLEM PLATE — the agency's emblem on a bezelled plate (scripts/emblem_plate.lua\n" \
         "// paints it). Crewed parts carry one as a child; this is the free-standing one.\n" \
         "// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n"
    ep += plate_nodes(None, (0, 0, 0), (0, 0, 1), "flat", 0).replace('        name: "Emblem Plate",\n', '        name: "EmblemPlate",\n', 1)
    ep += "]\n"
    open(os.path.join(PREFABS, "EmblemPlate.prefab.ron"), "w").write(ep)

    # ── the plates on the crewed parts (injected; idempotent) ──
    sites = {
        # the pod's cone, on the side opposite the hatch: r 0.378 at y 0.05,
        # the wall leaning in 30.5°
        "PartPod": ((-0.382, 0.052, 0.0), (-0.862, 0.508, 0.0), "r44"),
        # the seat's backrest, its rear face
        "PartSeat": ((-0.320, 0.119, 0.0), (-0.978, -0.208, 0.0), "flat"),
        # the cockpit's cylinder, low on its left flank
        "PartCockpit": ((-0.602, -0.35, 0.0), (-1.0, 0.0, 0.0), "r60"),
    }
    MARK = "    // ── emblem plate (tools/gen_flag.py) ──\n"
    for pf, (at, n, key) in sites.items():
        path = os.path.join(PREFABS, pf + ".prefab.ron")
        src = open(path).read()
        if MARK in src:
            src = src[:src.index(MARK)] + "]\n"
        body = src.rstrip()
        assert body.endswith("]"), pf
        body = body[:-1].rstrip()
        if not body.endswith(","):
            body += ","
        count = len(re.findall(r'^    \(\n        name: ', body, flags=re.M))
        n_ = np.asarray(n, float); n_ /= np.linalg.norm(n_)
        block = MARK + plate_nodes(0, np.asarray(at) , n_, key, count)
        open(path, "w").write(body + "\n" + block + "]\n")
        print(pf, "plate node", count)

    # ── the libraries ──
    for name, kind, about in (("DeployLib", "deployables", "DEPLOY LIBRARY — scripts/deployables.lua: flags and every other deployable\n// planted in the world. Spawned by whoever needs it when the scene has none;\n// reached with findScript(\"deployables\")."),
                              ("AgencyLib", "emblem", "AGENCY LIBRARY — scripts/emblem.lua: the agency's name and emblem, and the\n// textures built from them. Spawned by whoever needs it when the scene has\n// none; reached with findScript(\"emblem\").")):
        t = f"// {about}\n// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n"
        t += node(name, None, (0, 0, 0), "Empty",
                  scripts=f'[\n            (\n                kind: "{kind}",\n                enabled: true,\n                params: [],\n            ),\n        ]')
        t += "]\n"
        open(os.path.join(PREFABS, name + ".prefab.ron"), "w").write(t)

    # ── the photo camera (scripts/flag.lua spawns one per photo, then drops it) ──
    t = ("// FLAG PHOTO CAM — the camera a planted flag's photo is taken through\n"
         "// (scripts/flag.lua: spawned, captured from off-screen, destroyed).\n"
         "// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n")
    t += node("FlagPhotoCam", None, (0, 0, 0), "Camera(\n            fov_y: 0.95,\n            active: false,\n        )")
    t += "]\n"
    open(os.path.join(PREFABS, "FlagPhotoCam.prefab.ron"), "w").write(t)

    # ── remains: the suit, fallen (lying on its back, the rig at rest) ──
    t = ("// REMAINS — a crew member who died out there (scripts/deployables.lua kind\n"
         "// `remains`): the suit lying on its back where it fell. A still model (no\n"
         "// animator), so it costs a mesh; origin 0.18 m above the ground.\n"
         "// Written by tools/gen_flag.py — edit the generator, not this file.\n[\n")
    t += node("Remains", None, (0, 0, 0), "Empty",
              extra="        tags: [\"remains\", \"deployable\"],\n" + REMAINS_BODY)
    q = quat_from_matrix(np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float))   # +Y (head) along -Z... lying down
    t += node("Remains Suit", 0, (0, -0.02, 0.0), mesh("models/astronaut/astronaut_male.glb"),
              mats=SUIT_MATS, rot=q)
    t += "]\n"
    open(os.path.join(PREFABS, "Remains.prefab.ron"), "w").write(t)

    # ── default textures: the rasteriser's own output for the default name ──
    raw = os.path.join(TEXDIR, ".emblem_raw")
    os.makedirs(raw, exist_ok=True)
    lua = ('local env = setmetatable({}, { __index = _G })\n'
           'local c = assert(loadfile("scripts/emblem.lua")); setfenv(c, env); c()\n'
           'local s = env.specFor(env.DEFAULT_NAME)\n'
           'local px = env.rasterEmblem(s, env.DEFAULT_NAME)\n'
           'local f = io.open(arg[1] .. "/e.rgba", "wb"); f:write(px); f:close()\n'
           'f = io.open(arg[1] .. "/f.rgba", "wb"); f:write(env.rasterFlag(s, env.DEFAULT_NAME, px)); f:close()\n')
    lf = os.path.join(raw, "dump.lua")
    open(lf, "w").write(lua)
    subprocess.check_call(["luajit", lf, raw], cwd=ROOT)
    from PIL import Image
    Image.frombytes("RGBA", (256, 256), open(os.path.join(raw, "e.rgba"), "rb").read()).save(
        os.path.join(TEXDIR, "emblem_default.png"), optimize=True)
    Image.frombytes("RGBA", (512, 341), open(os.path.join(raw, "f.rgba"), "rb").read()).convert("RGB").save(
        os.path.join(TEXDIR, "flag_default.png"), optimize=True)
    for fn in ("e.rgba", "f.rgba", "dump.lua"):
        os.remove(os.path.join(raw, fn))
    os.rmdir(raw)
    print("wrote flag + plate models, prefabs and default textures")


if __name__ == "__main__":
    main()
