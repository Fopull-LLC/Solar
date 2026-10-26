"""The RCS Pack's model (docs/crew-and-items.md §5.7), built in Blender.

    blender --background --factory-startup --python tools/gen_rcs_pack.py

Writes models/items/rcs_pack.glb. A SAFER-style unit that clips round the
suit's PLSS: a propellant module under the backpack, two side towers up its
flanks with a four-way nozzle block at each end (eight blocks, the eight
nozzle axes eva_pack fires), and the hand controller on a stub arm at the
left hip.

Coordinates are the SUIT's model space as Blender imports
models/astronaut/astronaut_male.glb (Z up, the back toward +Y, the body
centred on x = -0.5), the same space the helmet's glb is authored in, so the
prefab hangs it on the Back bone with the helmet's attachment offset.
Materials by name for the prefab: PackShell, PackMetal, PackHazard,
PackNozzle.
"""
import math
import bpy
import bmesh
from mathutils import Vector

OUT = "models/items/rcs_pack.glb"
CX = -0.5          # the body's centre line in this space
BACK = 0.39        # the PLSS's back face

bpy.ops.wm.read_factory_settings(use_empty=True)
MATS = {}


def mat(name, rgb):
    if name not in MATS:
        m = bpy.data.materials.new(name)
        m.diffuse_color = (*rgb, 1.0)
        MATS[name] = m
    return MATS[name]


def box(name, c, size, m, bevel=0.012):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=c)
    o = bpy.context.object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if bevel > 0:
        mod = o.modifiers.new("b", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        bpy.ops.object.modifier_apply(modifier="b")
    o.data.materials.append(m)
    return o


def cyl(name, c, r, depth, axis, m, verts=12, r2=None):
    if r2 is None:
        bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=c)
    else:
        bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r2, depth=depth, location=c)
    o = bpy.context.object
    o.name = name
    rot = {"x": (0, math.pi / 2, 0), "-x": (0, -math.pi / 2, 0), "y": (-math.pi / 2, 0, 0),
           "-y": (math.pi / 2, 0, 0), "z": (0, 0, 0), "-z": (math.pi, 0, 0)}[axis]
    o.rotation_euler = rot
    bpy.ops.object.transform_apply(rotation=True)
    o.data.materials.append(m)
    return o


shell = mat("PackShell", (0.86, 0.86, 0.82))
metal = mat("PackMetal", (0.45, 0.47, 0.5))
hazard = mat("PackHazard", (0.95, 0.72, 0.1))
nozzle = mat("PackNozzle", (0.12, 0.12, 0.13))

parts = []
# the propellant module, under the backpack
parts.append(box("Module", (CX, BACK - 0.13, 0.86), (0.52, 0.30, 0.16), shell, 0.02))
parts.append(box("ModuleBand", (CX, BACK + 0.022, 0.86), (0.53, 0.012, 0.05), hazard, 0.0))
for sx in (-1, 1):
    # two cold-gas bottles across the module
    parts.append(cyl("Bottle", (CX + sx * 0.12, BACK - 0.12, 0.77), 0.055, 0.22, "y", metal, 16))
    # the side towers up the backpack's flanks
    tx = CX + sx * 0.30
    parts.append(box("Tower", (tx, BACK - 0.13, 1.20), (0.06, 0.15, 0.70), shell, 0.012))
    parts.append(box("TowerStripe", (tx + sx * 0.031, BACK - 0.13, 1.20), (0.004, 0.05, 0.60), hazard, 0.0))
    for z in (0.88, 1.53):
        # a nozzle block with four thrusters: out, back, and up or down
        parts.append(box("Block", (tx, BACK - 0.06, z), (0.09, 0.09, 0.09), metal, 0.01))
        parts.append(cyl("NozOut", (tx + sx * 0.06, BACK - 0.06, z), 0.016, 0.04, "x" if sx > 0 else "-x", nozzle, 10, 0.026))
        parts.append(cyl("NozBack", (tx, BACK + 0.0, z), 0.016, 0.04, "y", nozzle, 10, 0.026))
        parts.append(cyl("NozFwd", (tx, BACK - 0.12, z), 0.016, 0.04, "-y", nozzle, 10, 0.026))
        parts.append(cyl("NozUpDn", (tx, BACK - 0.06, z + (0.06 if z > 1.2 else -0.06)), 0.016, 0.04,
                         "z" if z > 1.2 else "-z", nozzle, 10, 0.026))
# the hand controller: a stub arm round the left hip to a grip box in front
parts.append(cyl("Arm", (CX + 0.33, 0.12, 0.92), 0.02, 0.42, "y", metal, 10))
parts.append(box("Controller", (CX + 0.33, -0.12, 0.95), (0.08, 0.10, 0.07), shell, 0.012))
parts.append(cyl("Stick", (CX + 0.33, -0.13, 1.0), 0.012, 0.06, "z", nozzle, 8))

bpy.ops.object.select_all(action="DESELECT")
for o in parts:
    o.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
pack = bpy.context.object
pack.name = "RcsPack"
bpy.ops.object.shade_flat()
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_apply=True)
print("wrote", OUT, len(pack.data.polygons), "faces")
