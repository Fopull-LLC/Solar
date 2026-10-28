"""Pull the head out of Blender's Human Base Meshes bundle (CC0) into
head_base.npz, the source tools/gen_faces.py builds every crew face from.

    blender --background --factory-startup --disable-autoexec \\
        --python tools/faces_base/export_base.py -- <human_base_meshes_bundle.blend> tools/faces_base/head_base.npz

The bundle: https://www.blender.org/download/demo-files/ (Human Base Meshes
v1.4.1, Blender Studio, CC0). Only mesh data is read (bpy.data.libraries.load,
autoexec off): "GEO-head_animation_realistic" at its multires level 1, and its
two scleras. Positions are written in glTF axes (x the head's left, y up, z
forward), metres.
"""
import sys

import bpy
import numpy as np

path, out = sys.argv[sys.argv.index("--") + 1:][:2]
NAMES = ["GEO-head_animation_realistic", "GEO-head_animation_realistic.sclera.L", "GEO-head_animation_realistic.sclera.R"]
with bpy.data.libraries.load(path, link=False) as (src, dst):
    dst.objects = [n for n in NAMES if n in src.objects]
data = {}
for o in dst.objects:
    bpy.context.scene.collection.objects.link(o)
for o in dst.objects:
    for m in o.modifiers:
        if m.type == 'MULTIRES':
            m.levels = min(1, m.total_levels)
            m.render_levels = m.levels
    me = o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
    M = np.array(o.matrix_world)
    P = np.array([v.co[:] for v in me.vertices])
    P = (np.c_[P, np.ones(len(P))] @ M.T)[:, :3]
    P = np.c_[P[:, 0], P[:, 2], -P[:, 1]]                      # Blender z-up, -y forward → glTF
    key = "head" if "." not in o.name else o.name.split(".")[-2] + o.name.split(".")[-1]
    data[key + "_P"] = P.astype(np.float64)
    data[key + "_F"] = np.array([i for p in me.polygons for i in p.vertices], np.int32)
    data[key + "_N"] = np.array([len(p.vertices) for p in me.polygons], np.int32)
    print(key, len(P), len(me.polygons))
np.savez_compressed(out, **data)
