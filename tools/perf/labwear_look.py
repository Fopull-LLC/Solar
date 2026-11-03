"""Render a lab scientist (models/lab/scientist.glb + a crew head and hair) in
Blender, headless, to check the clothes and the neck before the engine does.

    blender --background --factory-startup --python tools/perf/labwear_look.py -- OUTDIR [head] [hair] [yaw] [pitch]

Poses the body idle (arms down, the elbows a little bent), hangs the head and
the hair rigid on the Head bone (as scripts/face.lua's Face node hangs them),
turns the head by yaw/pitch degrees, and renders the whole figure from the
front, the side and behind, and close-ups of the neck and collar from the
front, three-quarter, side, behind and below the chin. EEVEE, the game's
cloth texture times the vertex colours.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = argv[0]
HEAD = int(argv[1]) if len(argv) > 1 else 1
HAIR = argv[2] if len(argv) > 2 else "crop"
YAW = float(argv[3]) if len(argv) > 3 else 0.0
PITCH = float(argv[4]) if len(argv) > 4 else 0.0
os.makedirs(OUT, exist_ok=True)
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
SKIN = (0.52, 0.33, 0.24, 1)


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    for o in list(new):
        if o.type == "MESH" and o.parent is None and any(p.type == "ARMATURE" for p in new) and not o.data.polygons:
            bpy.data.objects.remove(o)
            new.remove(o)
    return new


def mat_setup():
    for m in bpy.data.materials:
        name = m.name.split(".")[0]
        m.use_nodes = True
        nt = m.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        for l in list(nt.links):
            if l.to_node == bsdf and l.to_socket.name == "Base Color":
                nt.links.remove(l)
        vc = nt.nodes.new("ShaderNodeVertexColor")
        vc.layer_name = "Color"
        if name in ("FaceSkin", "SuitHead"):
            bsdf.inputs["Base Color"].default_value = SKIN
            bsdf.inputs["Roughness"].default_value = 0.55
            continue
        if name == "FaceEye":
            bsdf.inputs["Base Color"].default_value = (0.8, 0.8, 0.78, 1)
            continue
        if name == "FaceMouth":
            bsdf.inputs["Base Color"].default_value = (0.35, 0.12, 0.10, 1)
            continue
        if name == "Hair":
            bsdf.inputs["Base Color"].default_value = (0.03, 0.022, 0.016, 1)
            bsdf.inputs["Roughness"].default_value = 0.6
            img = nt.nodes.new("ShaderNodeTexImage")
            img.image = bpy.data.images.load(os.path.join(ROOT, "textures/faces/hair_cards.png"))
            nt.links.new(img.outputs["Alpha"], bsdf.inputs["Alpha"])
            m.surface_render_method = "DITHERED"
            continue
        mul = nt.nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        mul.inputs["A"].default_value = (1, 1, 1, 1)
        if name == "LabCloth":
            img = nt.nodes.new("ShaderNodeTexImage")
            img.image = bpy.data.images.load(os.path.join(ROOT, "textures/lab/cloth_albedo.png"))
            nt.links.new(img.outputs["Color"], mul.inputs["A"])
            nimg = nt.nodes.new("ShaderNodeTexImage")
            nimg.image = bpy.data.images.load(os.path.join(ROOT, "textures/lab/cloth_normal.png"))
            nimg.image.colorspace_settings.name = "Non-Color"
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(nimg.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
            bsdf.inputs["Roughness"].default_value = 0.85
        elif name == "LabKnit":
            img = nt.nodes.new("ShaderNodeTexImage")
            img.image = bpy.data.images.load(os.path.join(ROOT, "textures/lab/knit_albedo.png"))
            nt.links.new(img.outputs["Color"], mul.inputs["A"])
            nimg = nt.nodes.new("ShaderNodeTexImage")
            nimg.image = bpy.data.images.load(os.path.join(ROOT, "textures/lab/knit_normal.png"))
            nimg.image.colorspace_settings.name = "Non-Color"
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(nimg.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
            bsdf.inputs["Roughness"].default_value = 0.95
        elif name == "LabNitrile":
            bsdf.inputs["Roughness"].default_value = 0.42
        elif name == "LabShoe":
            bsdf.inputs["Roughness"].default_value = 0.5
        else:
            bsdf.inputs["Roughness"].default_value = 0.35
        nt.links.new(vc.outputs["Color"], mul.inputs["B"])
        nt.links.new(mul.outputs["Result"], bsdf.inputs["Base Color"])


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    body = import_glb(os.path.join(ROOT, "models/lab/scientist.glb"))
    arm = next(o for o in body if o.type == "ARMATURE")
    extra = import_glb(os.path.join(ROOT, f"models/astronaut/faces/head_{HEAD}.glb"))
    extra += import_glb(os.path.join(ROOT, f"models/astronaut/faces/hair_{HAIR}.glb"))
    bpy.context.view_layer.update()
    for o in extra:
        if o.parent is None:
            mw = o.matrix_world.copy()
            o.parent = arm
            o.parent_type = "BONE"
            o.parent_bone = "Head"
            bpy.context.view_layer.update()
            o.matrix_world = mw
    mat_setup()
    W = arm.matrix_world

    def turn(bone, axis, deg):
        pb = arm.pose.bones[bone]
        bpy.context.view_layer.update()
        wm = W @ pb.matrix
        h = wm.translation.copy()
        R = Matrix.Rotation(math.radians(deg), 4, axis)
        pb.matrix = W.inverted() @ (Matrix.Translation(h) @ R @ Matrix.Translation(-h) @ wm)
        bpy.context.view_layer.update()
    for b, ax, d in (("Upperarm.Left", Y, 80), ("Upperarm.Right", Y, -80), ("Forearm.Left", X, -18),
                     ("Forearm.Right", X, -18), ("Upperarm.Left", X, -6), ("Upperarm.Right", X, -6),
                     ("Head", Z, YAW), ("Head", X, -PITCH)):
        turn(b, ax, d)
    sc = bpy.context.scene
    # Cycles on the CPU: no GPU context at all (the engine's lock is for GPU work)
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 24
    sc.cycles.use_denoising = True
    sc.render.threads_mode = "FIXED"
    sc.render.threads = 6
    w = bpy.data.worlds.new("w")
    sc.world = w
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.57, 0.60, 1)
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.7
    for (rx, rz, e) in ((55, -35, 3.0), (70, 150, 1.0)):
        sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
        sun.data.energy = e
        sun.rotation_euler = (math.radians(rx), 0, math.radians(rz))
        sc.collection.objects.link(sun)
    sc.view_settings.view_transform = "AgX"
    sc.render.resolution_x, sc.render.resolution_y = 720, 900
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam

    def shoot(target, direction, dist, name, lens=50, res=(720, 900)):
        sc.render.resolution_x, sc.render.resolution_y = res
        d = Vector(direction).normalized()
        cam.location = Vector(target) + d * dist
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        cam.data.lens = lens
        sc.render.filepath = os.path.join(OUT, name + ".png")
        bpy.ops.render.render(write_still=True)
    hb = W @ arm.pose.bones["Head"].head
    mid = Vector((hb.x, hb.y, 0.95))
    shoot(mid, (0.15, -1, 0.05), 4.6, "full_front")
    shoot(mid, (1, -0.1, 0.05), 4.6, "full_side")
    shoot(mid, (-0.3, 1, 0.1), 4.6, "full_back")
    neck = Vector((hb.x, hb.y, hb.z + 0.02))
    sq = (720, 720)
    shoot(neck, (0.05, -1, 0.05), 0.75, "neck_front", res=sq)
    shoot(neck, (0.8, -1, 0.15), 0.75, "neck_34", res=sq)
    shoot(neck, (1, 0, 0.1), 0.75, "neck_side", res=sq)
    shoot(neck, (-0.3, 1, 0.3), 0.75, "neck_back", res=sq)
    shoot(neck, (0.1, -1, -0.6), 0.6, "neck_below", res=sq)
    shoot(neck, (0.2, -0.7, 1.0), 0.75, "neck_above", res=sq)
    hand = W @ arm.pose.bones["Hand.Left"].head
    shoot(hand, (0.4, -1, 0.2), 0.55, "hand", res=sq)
    shoot(Vector((hb.x, hb.y, 1.3)), (0.4, -1, 0.15), 1.4, "chest", res=sq)


main()
