"""Pose the crew's suit at the joints' extremes and render it (Blender, headless).

    blender --background --factory-startup --python tools/suit_posecheck.py -- MODEL.glb OUTDIR [pose ...]

Imports the glb as the engine would draw it (the rig, the skin, the vertex
colours), poses the bones by rotations about WORLD axes through each bone's
head (parents first, so a child's rotation is relative to where its parent
left it), and renders Workbench images: the whole figure from the front, the
side and behind, and close-ups of the joints that pose stresses. Blender's
world: +X the crew's left, −Y forward, +Z up. Blender's skinning is the same
linear blend the engine's is, so what pinches here pinches in the game.

Poses: tpose (the bind), idle (arms down), elbow140, armraise (one arm up,
one forward), crouch (a deep knee bend), seated, walk. Blender is not part of
the build; it only checks it (tools/gen_suit.py writes the suit).
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
MODEL, OUT = argv[0], argv[1]
ONLY = set(argv[2:])
os.makedirs(OUT, exist_ok=True)

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
    "seated": [("hip_side", "Thigh.Left", (1, 0, 0.15), 1.1)],
    "walk": [("legs_side", "Shin.Left", (1, 0, 0.0), 1.4)],
}


def setup():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=MODEL)
    for o in list(bpy.data.objects):
        if o.type == "MESH" and o.parent is None:      # the importer's bone shape
            bpy.data.objects.remove(o)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    # The decals, the visor and the lamps carry white vertex colours (their
    # look is a texture in the engine): tint them so they read here.
    TINT = {"SuitDecal": (0.25, 0.27, 0.32, 1), "SuitVisor": (0.75, 0.55, 0.2, 1), "SuitLamp": (1, 0.95, 0.8, 1)}
    for o in bpy.data.objects:
        if o.type != "MESH" or "Color" not in o.data.color_attributes:
            continue
        ca = o.data.color_attributes["Color"]
        for poly in o.data.polygons:
            t = TINT.get(o.data.materials[poly.material_index].name)
            if not t:
                continue
            for li in poly.loop_indices:
                idx = li if ca.domain == "CORNER" else o.data.loops[li].vertex_index
                ca.data[idx].color = t
    sc = bpy.context.scene
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


def main():
    arm, cam = setup()
    for name, steps in POSES.items():
        if ONLY and name not in ONLY:
            continue
        pose(arm, steps)
        c = (head(arm, "Hip") + head(arm, "Back")) / 2
        c.z -= 0.25
        for view, d in (("front", (0.15, -1, 0.12)), ("side", (1, -0.05, 0.08)), ("back", (-0.5, 1, 0.25))):
            shoot(cam, c, d, 3.3, os.path.join(OUT, f"{name}_{view}.png"), lens=45)
        for cname, bone, d, dist in CLOSE.get(name, []):
            shoot(cam, head(arm, bone), d, dist, os.path.join(OUT, f"{name}_{cname}.png"), lens=40)


main()
