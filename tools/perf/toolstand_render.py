"""Blender stand-in for toolstand.sh: render a tool .glb when the engine cannot
run (no GPU device). An approximation of the in-game look, not a match: the
materials are rebuilt from tools/gen_tools.py's colours, the tool_* shaders as
flat emission at a fixed charge/heat.

    blender --background --factory-startup --python tools/perf/toolstand_render.py -- \
        OUT_DIR TAG MODEL.glb fp|q|side [more views...]

Views: q (3/4 front from the left), side (left side), fp (first person: the
view model placed as scripts/tool_belt.lua places it, VIEW_AT / VIEW_TOE /
VIEW_CANT / VM_FOV, the grip read from RIG_FP; pass the tool id as
TOOL=gravgun|laser in the environment, default laser). Cycles on the CPU.
"""
import math
import os
import re
import sys

import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
argv = sys.argv[sys.argv.index("--") + 1:]
OUT, TAG, GLB, VIEWS = argv[0], argv[1], argv[2], argv[3:]
TOOL = os.environ.get("TOOL", "laser")
CHARGE, HEAT = float(os.environ.get("CHARGE", "0.5")), float(os.environ.get("HEAT", "0.4"))

FIELD, LASER, COOL = (0.30, 0.60, 1.0), (1.0, 0.50, 0.16), (0.40, 0.78, 1.0)
PAL = FIELD if TOOL == "gravgun" else LASER
# name: (base colour, metallic, roughness, emission colour or None, emission strength, transmission)
MATS = {
    "GunBody": ((0.26, 0.27, 0.29), 0.45, 0.55, None, 0, 0), "GunPaint": ((0.97, 0.55, 0.22), 0, 0.5, None, 0, 0),
    "Enamel": ((0.86, 0.84, 0.78), 0, 0.45, None, 0, 0), "Anodised": ((0.42, 0.47, 0.55), 0.5, 0.4, None, 0, 0),
    "Chrome": ((0.9, 0.9, 0.9), 0.85, 0.25, None, 0, 0), "Dark": ((0.16, 0.16, 0.17), 0.3, 0.6, None, 0, 0),
    "Rubber": ((0.05, 0.05, 0.05), 0, 0.85, None, 0, 0), "Glove": ((0.62, 0.615, 0.60), 0, 0.9, None, 0, 0),
    "Palm": ((0.16, 0.16, 0.17), 0, 0.9, None, 0, 0), "Suit": ((0.80, 0.785, 0.745), 0, 0.9, None, 0, 0),
    "SuitMetal": ((0.8, 0.8, 0.8), 0.6, 0.35, None, 0, 0), "Hazard": ((0.95, 0.72, 0.12), 0, 0.5, None, 0, 0),
    "Lens": ((0.2, 0.3, 0.34), 0.2, 0.05, None, 0, 0), "Copper": ((0.8, 0.5, 0.32), 0.9, 0.35, None, 0, 0),
    "EnamelWorn": ((0.72, 0.71, 0.68), 0.7, 0.4, None, 0, 0), "PaintWorn": ((0.66, 0.64, 0.60), 0.7, 0.4, None, 0, 0),
    "GlowAmber": ((1.0, 0.62, 0.25), 0, 0.3, (1.0, 0.62, 0.25), 3.0, 0),
    "HeatGlow": ((0.32, 0.32, 0.33), 0.6, 0.5, (1.0, 0.36, 0.06), 6.0 * HEAT ** 2.2, 0),
    "Energy": (PAL, 0, 0.3, PAL, 3.0 * (0.3 + CHARGE), 0), "EnergyDish": (PAL, 0, 0.3, PAL, 3.0 * (0.3 + CHARGE), 0),
    "EnergyBand": (PAL, 0, 0.3, PAL, 2.4 * (0.3 + CHARGE), 0), "Emitter": (PAL, 0, 0.3, PAL, 3.5 * (0.3 + CHARGE), 0),
    "Crystal": (PAL, 0, 0.3, PAL, 2.6 * (0.3 + CHARGE), 0), "Plasma": (PAL, 0, 0.3, PAL, 3.0 * (0.3 + CHARGE), 0),
    "Coolant": (COOL, 0, 0.3, COOL, 2.2 * (0.3 + CHARGE), 0),
    "EnergyGlass": ((1, 1, 1), 0, 0.05, None, 0, 1), "CoolGlass": ((1, 1, 1), 0, 0.05, None, 0, 1),
    "Gauge": ((1.0, 0.62, 0.24), 0, 0.3, (1.0, 0.62, 0.24), 2.6, 0),
}


def read_rig():
    tb = open(os.path.join(ROOT, "scripts", "tool_belt.lua")).read()
    num = lambda pat: [float(x) for x in re.findall(r"-?[0-9.]+", re.search(pat, tb).group(0))]
    view_at = num(r"local VIEW_AT = \{[^}]*\}")
    toe = num(r"local VIEW_TOE = [0-9.]+")[0]
    cant = num(r"local VIEW_CANT = -?[0-9.]+")[0]
    fov = num(r"local VM_FOV = [0-9.]+")[0]
    blk = tb[tb.index("RIG_FP = {"):]
    line = next(l for l in blk.splitlines() if l.strip().startswith(TOOL))
    grip = [float(x) for x in re.findall(r"-?[0-9.]+", re.search(r"grip = \{[^}]*\}", line).group(0))]
    return view_at, toe, cant, fov, grip


def material(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    if name == "ToolDecal":
        img = bpy.data.images.load(os.path.join(ROOT, "textures", "tools", "tool_decals.png"))
        t = m.node_tree.nodes.new("ShaderNodeTexImage")
        t.image = img
        m.node_tree.links.new(t.outputs["Color"], b.inputs["Base Color"])
        m.node_tree.links.new(t.outputs["Alpha"], b.inputs["Alpha"])
        b.inputs["Roughness"].default_value = 0.6
        return m
    col, met, rough, em, es, tr = MATS.get(name, ((0.5, 0.5, 0.5), 0, 0.5, None, 0, 0))
    b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Metallic"].default_value = met
    b.inputs["Roughness"].default_value = rough
    if tr:
        b.inputs["Transmission Weight"].default_value = 1.0
        b.inputs["IOR"].default_value = 1.2
    if em:
        b.inputs["Emission Color"].default_value = (*em, 1)
        b.inputs["Emission Strength"].default_value = es
    return m


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 48
    sc.cycles.use_denoising = True
    sc.render.resolution_x, sc.render.resolution_y = 1280, 720
    sc.view_settings.view_transform = "AgX"
    bpy.ops.import_scene.gltf(filepath=GLB)
    objs = [o for o in sc.objects if o.type == "MESH"]
    cache = {}
    for o in objs:
        for slot in o.material_slots:
            n = slot.material.name.split(".")[0] if slot.material else "Dark"
            if n not in cache:
                cache[n] = material(n)
            slot.material = cache[n]
    roots = [o for o in sc.objects if o.parent is None]
    # world: a grey sky; a sun as toolstand.lua's key light
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.42, 0.45, 0.5, 1)
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    sc.world = w
    C = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))     # game (y up, -z ahead) -> Blender
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.5
    d = (C.to_3x3() @ Vector((-0.45, -0.75, -0.5))).normalized()
    sun.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    sc.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    piv = bpy.data.objects.new("pivot", None)
    sc.collection.objects.link(piv)
    for o in roots:
        o.parent = piv
    os.makedirs(OUT, exist_ok=True)
    for v in VIEWS:
        if v == "fp":
            va, toe, cant, fov, g = read_rig()
            yw, pt, rl = math.atan(va[0] / toe), math.atan(-va[1] / toe), cant
            R = Matrix.Rotation(yw, 4, "Y") @ Matrix.Rotation(pt, 4, "X") @ Matrix.Rotation(rl, 4, "Z")
            rg = R.to_3x3() @ Vector(g)
            M = Matrix.Translation(Vector(va) - rg) @ R
            piv.matrix_world = C @ M @ C.inverted()
            cam.location = (0, 0, 0)
            cam.rotation_euler = (math.pi / 2, 0, 0)
            cam.data.sensor_fit = "VERTICAL"
            cam.data.angle = fov
        else:
            piv.matrix_world = Matrix.Identity(4)
            yaw = math.radians(-128 if v == "q" else -90)
            pitch = math.radians(16 if v == "q" else 3)
            off = Vector((math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))) * 1.45
            cam.location = C.to_3x3() @ off
            cam.rotation_euler = (-(C.to_3x3() @ off)).to_track_quat("-Z", "Z").to_euler()
            cam.data.sensor_fit = "VERTICAL"
            cam.data.angle = 0.6
        sc.render.filepath = os.path.join(OUT, f"{TAG}_{v}.png")
        bpy.ops.render.render(write_still=True)
        print("RENDERED", sc.render.filepath)


main()
