"""Pose the crew's suit at the joints' extremes and render it (Blender, headless).

    blender --background --factory-startup --python tools/suit_posecheck.py -- MODEL.glb OUTDIR [flags] [pose ...]

Imports the glb as the engine would draw it (the rig, the skin, the vertex
colours), poses the bones by rotations about WORLD axes through each bone's
head (parents first, so a child's rotation is relative to where its parent
left it), and renders the whole figure from the front, the side and behind,
and close-ups of the joints that pose stresses. Blender's world: +X the crew's
left, −Y forward, +Z up. Blender's skinning is the same linear blend the
engine's is, so what pinches here pinches in the game.

Flags:
  --helmet   also import the helmet, visor and lamps (helmet_*.glb beside the
             suit) and hang them on the Back bone, as the scene does
  --look     render with the game's textures (EEVEE: each material's albedo
             times the vertex colour, normal maps, the bubble see-through)
             instead of the Workbench's flat vertex colours
  --sweep    the shoulder sweep: abduction 0→170° and flexion −40→170° from
             arms-down, close-ups of the left shoulder from the front, the
             side and behind (sweep_abd_###_*.png, sweep_flex_###_*.png)

Poses: tpose (the bind), idle (arms down), elbow140, armraise (one arm up,
one forward), crouch (a deep knee bend), seated, walk, toolhold (both hands
on a tool's grips, as tool_belt holds one), headcheck (helmet off, the head),
openhand / fist (the glove at rest and curled as the clips curl it), wrist
(bent), crossbody (a hand across the chest, the other arm back), hipflex (a
thigh high forward, the other back).
Blender is not part of the game; it only checks it (tools/gen_suit.py writes
the suit).
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
MODEL, OUT = argv[0], argv[1]
FLAGS = {a for a in argv[2:] if a.startswith("--")}
ONLY = {a for a in argv[2:] if not a.startswith("--")}
os.makedirs(OUT, exist_ok=True)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
# (bone, axis, degrees), parents first. Signs: an arm hangs by turning about
# +Y (left +, right −); a hanging limb swings forward about −X; a knee and an
# elbow flex (forearm forward) about ∓X.
DOWN = 78
POSES = {
    "tpose": [],
    "idle": [("Upperarm.Left", Y, DOWN), ("Upperarm.Right", Y, -DOWN),
             ("Forearm.Left", X, -20), ("Forearm.Right", X, -20)],
    "elbow140": [("Upperarm.Left", Y, 70), ("Upperarm.Right", Y, -70),
                 ("Upperarm.Left", X, -20), ("Upperarm.Right", X, -20),
                 ("Forearm.Left", X, -140), ("Forearm.Right", X, -140)],
    "armraise": [("Upperarm.Left", Y, -75), ("Upperarm.Right", Y, -DOWN),
                 ("Upperarm.Right", X, -95), ("Forearm.Left", X, -30)],
    "crouch": [("Back", X, 25), ("Hip", X, -35),
               ("Thigh.Left", X, -115), ("Thigh.Right", X, -100),
               ("Shin.Left", X, 135), ("Shin.Right", X, 125),
               ("Foot.Left", X, -25), ("Foot.Right", X, -20),
               ("Upperarm.Left", Y, 70), ("Upperarm.Right", Y, -70),
               ("Upperarm.Left", X, -40), ("Upperarm.Right", X, -40),
               ("Forearm.Left", X, -60), ("Forearm.Right", X, -60)],
    "seated": [("Thigh.Left", X, -90), ("Thigh.Right", X, -90),
               ("Shin.Left", X, 90), ("Shin.Right", X, 90),
               ("Upperarm.Left", Y, 65), ("Upperarm.Right", Y, -65),
               ("Upperarm.Left", X, -35), ("Upperarm.Right", X, -35),
               ("Forearm.Left", X, -70), ("Forearm.Right", X, -70)],
    "walk": [("Thigh.Left", X, -35), ("Shin.Left", X, 20), ("Foot.Left", X, -10),
             ("Thigh.Right", X, 22), ("Shin.Right", X, 50), ("Foot.Right", X, 15),
             ("Upperarm.Left", Y, DOWN), ("Upperarm.Right", Y, -DOWN),
             ("Upperarm.Left", X, 20), ("Upperarm.Right", X, -25),
             ("Forearm.Left", X, -25), ("Forearm.Right", X, -45)],
    # tool_belt's hold: the right hand on the grip at the hip, the left on the
    # fore grip, the tool across the body
    "toolhold": [("Upperarm.Right", Y, -DOWN), ("Upperarm.Right", X, -38), ("Upperarm.Right", Z, 18),
                 ("Forearm.Right", X, -70),
                 ("Upperarm.Left", Y, DOWN), ("Upperarm.Left", X, -62), ("Upperarm.Left", Z, 30),
                 ("Forearm.Left", X, -55), ("Forearm.Left", Z, 25)],
    "headcheck": [("Upperarm.Left", Y, DOWN), ("Upperarm.Right", Y, -DOWN), ("Head", Z, 20)],
    # the hands, arms out: open (the glove's rest), a fist as the clips curl
    # it (the knuckles 50°, the middle joints a further 65°), the wrist bent
    "openhand": [],
    "fist": [("Fingers1.Left", Y, 50), ("Fingers2.Left", Y, 65),
             ("Fingers1.Right", Y, -50), ("Fingers2.Right", Y, -65)],
    "wrist": [("Hand.Left", Y, 55), ("Hand.Right", Y, 40), ("Hand.Right", Z, -30)],
    # the left hand across the chest; the right arm reaching up and back
    "crossbody": [("Upperarm.Left", Y, DOWN), ("Upperarm.Left", X, -85), ("Upperarm.Left", Z, -45),
                  ("Forearm.Left", X, -50), ("Upperarm.Right", Y, -DOWN), ("Upperarm.Right", X, 35),
                  ("Forearm.Right", X, -20)],
    # the hips: one thigh high forward, one back (a stride's extremes)
    "hipflex": [("Thigh.Left", X, -100), ("Shin.Left", X, 60), ("Thigh.Right", X, 30), ("Shin.Right", X, 30),
                ("Upperarm.Left", Y, DOWN), ("Upperarm.Right", Y, -DOWN)],
}
# Close-ups: (name, bone whose head to look at, view direction from the target, distance)
CLOSE = {
    "idle": [("shoulder_front", "Upperarm.Left", (0.3, -1, 0.15), 0.9),
             ("shoulder_back", "Upperarm.Right", (-0.3, 1, 0.3), 0.9)],
    "elbow140": [("elbow_side", "Forearm.Left", (1, -0.2, 0.1), 0.75),
                 ("elbow_inner", "Forearm.Right", (-0.4, -1, 0.3), 0.75)],
    "armraise": [("shoulder_up", "Upperarm.Left", (0.4, -1, 0.1), 1.0),
                 ("shoulder_fwd", "Upperarm.Right", (-1, -0.3, 0.2), 1.0)],
    "crouch": [("knee_side", "Shin.Left", (1, -0.15, 0.1), 1.0),
               ("hip_back", "Thigh.Left", (0.5, 1, 0.3), 1.1),
               ("knee_front", "Shin.Right", (-0.2, -1, 0.4), 1.0)],
    "seated": [("hip_side", "Thigh.Left", (1, 0, 0.15), 1.1),
               ("shoulder", "Upperarm.Left", (0.6, -1, 0.3), 0.9)],
    "walk": [("legs_side", "Shin.Left", (1, 0, 0.0), 1.4)],
    "toolhold": [("shoulders", "Back", (0.5, -1, 0.35), 1.3), ("shoulder_r", "Upperarm.Right", (-1, -0.6, 0.3), 0.8)],
    "headcheck": [("head_front", "Head", (0.25, -1, -0.25), 0.55), ("head_side", "Head", (1, -0.3, -0.2), 0.55)],
    "openhand": [("hand_top", "Hand.Left", (0.15, -0.45, 1), 0.42), ("hand_palm", "Hand.Left", (0.25, -0.5, -1), 0.42),
                 ("hand_thumb", "Hand.Left", (0.35, -1, 0.35), 0.42), ("hand_tip", "Hand.Left", (1, -0.35, 0.35), 0.45)],
    "fist": [("fist_top", "Hand.Left", (0.15, -0.45, 1), 0.42), ("fist_thumb", "Hand.Left", (0.35, -1, 0.35), 0.42),
             ("fist_side", "Hand.Left", (0.4, -0.25, -0.2), 0.42), ("fist_palm", "Hand.Left", (0.3, -0.6, -1), 0.42)],
    "wrist": [("wrist_side", "Hand.Left", (0.2, -1, 0.15), 0.5), ("wrist_r", "Hand.Right", (-0.2, -1, 0.3), 0.5)],
    "crossbody": [("cross_front", "Upperarm.Left", (0.2, -1, 0.35), 1.0), ("cross_back", "Upperarm.Left", (0.4, 1, 0.5), 1.0),
                  ("reach_back", "Upperarm.Right", (-1, 0.2, 0.3), 1.0)],
    "hipflex": [("hip_side", "Thigh.Left", (1, -0.1, 0.1), 1.1), ("hip_back", "Thigh.Left", (0.4, 1, 0.2), 1.1),
                ("hip_front", "Thigh.Right", (-0.1, -1, 0.1), 1.1)],
}
MAT_TEX = {   # material: (albedo, normal map, roughness, metallic)
    "SuitFabric": ("textures/suit/fabric_albedo.png", "textures/suit/fabric_normal.png", 0.9, 0.0),
    "SuitShell": ("textures/suit/shell_albedo.png", "textures/suit/shell_normal.png", 0.5, 0.0),
    "SuitMetal": ("textures/parts/metal_albedo.png", "textures/parts/metal_normal.png", 0.5, 0.6),
    "SuitHead": ("textures/suit/head.png", None, 0.6, 0.0),
    "SuitDecal": ("textures/suit/decals.png", None, 0.8, 0.0),
    "SuitVisor": ("textures/suit/visor.png", None, 0.15, 0.6),
}


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    for o in list(new):
        if o.type == "MESH" and o.parent is None and any(p.type == "ARMATURE" for p in new):
            bpy.data.objects.remove(o)       # the importer's bone shape
    return [o for o in bpy.data.objects if o not in before]


def look_materials():
    """The game's look: albedo × vertex colour, a normal map, the bubble clear,
    the lamps glowing."""
    for m in bpy.data.materials:
        name = m.name.split(".")[0]
        m.use_nodes = True
        nt = m.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        vc = nt.nodes.new("ShaderNodeVertexColor")
        vc.layer_name = "Color"
        if name == "SuitBubble":
            bsdf.inputs["Base Color"].default_value = (0.85, 0.9, 0.95, 1)
            bsdf.inputs["Roughness"].default_value = 0.05
            bsdf.inputs["Alpha"].default_value = 0.15
            m.surface_render_method = "BLENDED"
            continue
        if name == "SuitLamp":
            bsdf.inputs["Emission Color"].default_value = (1, 0.95, 0.86, 1)
            bsdf.inputs["Emission Strength"].default_value = 4.0
            continue
        tex = MAT_TEX.get(name)
        if not tex:
            continue
        img = nt.nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(os.path.join(ROOT, tex[0]))
        mul = nt.nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        nt.links.new(img.outputs["Color"], mul.inputs["A"])
        nt.links.new(vc.outputs["Color"], mul.inputs["B"])
        nt.links.new(mul.outputs["Result"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = tex[2]
        bsdf.inputs["Metallic"].default_value = tex[3]
        if tex[1]:
            nimg = nt.nodes.new("ShaderNodeTexImage")
            nimg.image = bpy.data.images.load(os.path.join(ROOT, tex[1]))
            nimg.image.colorspace_settings.name = "Non-Color"
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(nimg.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])


def setup():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    objs = import_glb(MODEL)
    arm = next(o for o in objs if o.type == "ARMATURE")
    if "--helmet" in FLAGS:
        d, base = os.path.split(MODEL)
        sex = base.split("_")[-1]
        for part in ("helmet", "visor", "lamps"):
            p = os.path.join(d, f"{part}_{sex}")
            if not os.path.exists(p):
                continue
            for o in import_glb(p):
                if o.type != "MESH":
                    continue
                mw = o.matrix_world.copy()
                o.parent = arm
                o.parent_type = "BONE"
                o.parent_bone = "Back"
                bpy.context.view_layer.update()
                o.matrix_world = mw
    sc = bpy.context.scene
    if "--look" in FLAGS:
        look_materials()
        sc.render.engine = "BLENDER_EEVEE"
        w = bpy.data.worlds.new("w")
        sc.world = w
        w.use_nodes = True
        w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.30, 0.32, 0.36, 1)
        w.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8
        sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
        sun.data.energy = 3.5
        sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
        sc.collection.objects.link(sun)
        sc.view_settings.view_transform = "Standard"
    else:
        # The decals, the visor and the lamps carry white vertex colours (their
        # look is a texture in the engine): tint them so they read here.
        TINT = {"SuitDecal": (0.25, 0.27, 0.32, 1), "SuitVisor": (0.75, 0.55, 0.2, 1), "SuitLamp": (1, 0.95, 0.8, 1),
                "SuitHead": (0.70, 0.55, 0.45, 1), "SuitBubble": (0.7, 0.75, 0.8, 1)}
        for o in bpy.data.objects:
            if o.type != "MESH" or "Color" not in o.data.color_attributes:
                continue
            ca = o.data.color_attributes["Color"]
            for poly in o.data.polygons:
                t = TINT.get(o.data.materials[poly.material_index].name.split(".")[0])
                if not t:
                    continue
                for li in poly.loop_indices:
                    idx = li if ca.domain == "CORNER" else o.data.loops[li].vertex_index
                    ca.data[idx].color = t
        sc.render.engine = "BLENDER_WORKBENCH"
        sc.display.shading.light = "STUDIO"
        sc.display.shading.color_type = "VERTEX"
        sc.display.shading.show_cavity = True
        sc.display.shading.cavity_type = "WORLD"
        sc.display.shading.show_object_outline = False
        sc.display.shading.background_type = "VIEWPORT"
        sc.display.shading.background_color = (0.35, 0.37, 0.40)
    sc.render.resolution_x, sc.render.resolution_y = 720, 720
    sc.render.film_transparent = False
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    return arm, cam


def rest(arm):
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()


def pose(arm, steps):
    rest(arm)
    W = arm.matrix_world
    for bone, axis, deg in steps:
        pb = arm.pose.bones[bone]
        bpy.context.view_layer.update()
        wm = W @ pb.matrix
        h = wm.translation.copy()
        R = Matrix.Rotation(math.radians(deg), 4, axis)
        new = Matrix.Translation(h) @ R @ Matrix.Translation(-h) @ wm
        pb.matrix = W.inverted() @ new
        bpy.context.view_layer.update()


def head(arm, bone):
    return arm.matrix_world @ arm.pose.bones[bone].head


def shoot(cam, target, direction, dist, path, lens=50):
    d = Vector(direction).normalized()
    cam.location = Vector(target) + d * dist
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = lens
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def sweep(arm, cam):
    """The left shoulder through abduction 0→170° (in the frontal plane, from
    arms down) and flexion −40→170° (forward, from arms down)."""
    views = (("front", (0.35, -1, 0.15)), ("side", (1, -0.25, 0.2)), ("back", (0.3, 1, 0.3)))
    keep = [("Upperarm.Right", Y, -DOWN), ("Forearm.Left", X, -15)]
    for a in (0, 30, 60, 90, 120, 150, 170):
        pose(arm, [("Upperarm.Left", Y, DOWN - a)] + keep)
        for v, d in views:
            shoot(cam, head(arm, "Upperarm.Left"), d, 0.95, os.path.join(OUT, f"sweep_abd_{a:03d}_{v}.png"), lens=40)
    for b in (-40, 0, 45, 90, 135, 170):
        pose(arm, [("Upperarm.Left", Y, DOWN), ("Upperarm.Left", X, -b)] + keep)
        for v, d in views:
            shoot(cam, head(arm, "Upperarm.Left"), d, 0.95,
                  os.path.join(OUT, f"sweep_flex_{b + 40:03d}_{v}.png"), lens=40)


def main():
    arm, cam = setup()
    if "--sweep" in FLAGS:
        sweep(arm, cam)
    for name, steps in POSES.items():
        if (ONLY and name not in ONLY) or (not ONLY and "--sweep" in FLAGS):
            continue
        pose(arm, steps)
        c = (head(arm, "Hip") + head(arm, "Back")) / 2
        c.z -= 0.25
        for view, d in (("front", (0.15, -1, 0.12)), ("side", (1, -0.05, 0.08)), ("back", (-0.5, 1, 0.25)),
                        ("quarter", (0.7, -0.8, 0.25))):
            shoot(cam, c, d, 3.3, os.path.join(OUT, f"{name}_{view}.png"), lens=45)
        for cname, bone, d, dist in CLOSE.get(name, []):
            t = head(arm, bone)
            if bone == "Head":
                t = t + Vector((0, 0, 0.15))      # the face, not the neck
            if bone.startswith("Hand."):
                # the middle of the glove: the wrist's head toward the knuckles
                f = head(arm, "Fingers1" + bone[4:])
                t = t + (f - t) * 0.75
            shoot(cam, t, d, dist, os.path.join(OUT, f"{name}_{cname}.png"), lens=40)


main()
