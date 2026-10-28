#!/usr/bin/env python3
"""Write the face studio's scene (tools/perf/facestudio.sh): N suits in a row
on a plain floor, each with its Face / Hair / Cap nodes exactly as the
prefabs carry them (tools/gen_faces.py face_nodes), a key and a fill light,
the CrewLib's crew_faces for looks, and the probe."""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import gen_faces  # noqa: E402

out, n, case = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sol = os.path.join(HERE, "..", "..")
doll = open(os.path.join(sol, "prefabs", "CrewDoll.prefab.ron")).read()
# the suit's object_materials, from the CrewDoll prefab (prefab depth → scene depth)
m = re.search(r'(        object_materials: \{.*?\n        \},\n)', doll[doll.index('name: "AstroModel"'):], re.S)
suit_mats = m.group(1).replace("\n", "\n    ")
suit_mats = "    " + suit_mats.rstrip(" ")


def node(name, t, matter, parent=None, extra="", scripts="[]", rot=(0.0, 0.0, 0.0, 1.0)):
    s = (f"        (\n            name: \"{name}\",\n            transform: (\n"
         f"                translation: ({t[0]}, {t[1]}, {t[2]}),\n                rotation: {rot},\n"
         f"                scale: (1.0, 1.0, 1.0),\n            ),\n            matter: {matter},\n" + extra +
         f"            scripts: {scripts},\n")
    if parent is not None:
        s += f"            parent: Some({parent}),\n"
    return s + "        ),\n"


nodes = []
nodes.append(node("Camera", (0, 1.6, 3), "Camera( fov_y: 0.5, active: true )"))
nodes.append(node("Studio", (0, 0, 0), "Empty",
                  scripts=f'[ ( kind: "facestudio", enabled: true, params: [("n", {n}.0)], strs: [("case", "{case}")] ) ]'))
nodes.append(node("CrewLib", (0, 0, 0), "Empty", scripts='[ ( kind: "crew_faces", enabled: true, params: [] ) ]'))
nodes.append(node("Key Light", (1.5, 2.6, 2.2), "PointLight( color: (1.0, 0.93, 0.85), intensity: 6.0, range: 12.0 )"))
nodes.append(node("Fill Light", (-2.5, 1.9, 1.6), "PointLight( color: (0.75, 0.85, 1.0), intensity: 2.0, range: 12.0 )"))
# the helmet's three nodes as system.ron has them (Helmet on the Back bone,
# its Visor and Lamps under it), without their scene ids
sysr = open(os.path.join(sol, "scenes", "system.ron")).read()


def sys_node(name):
    a = sysr.index('\n        (\n            name: "%s",' % name)
    b = sysr.index("\n        ),\n", a) + len("\n        ),\n")
    t = sysr[a + 1:b]
    t = re.sub(r"            id: Some\(\d+\),\n", "", t)
    t = re.sub(r"            parent_id: Some\(\d+\),\n", "", t)
    return t


HELMET = [sys_node("Helmet"), sys_node("Helmet Visor"), sys_node("Helmet Lamps")]
count = len(nodes)          # nodes so far (face_nodes adds three in one string)
for k in range(n):
    x = (k - (n - 1) / 2) * (1.5 if case == "review" else 0.62)
    root = count
    nodes.append(node(f"Actor {k + 1}", (round(x, 3), 1.0, 0.0), "Empty"))
    model = root + 1
    nodes.append(node("AstroModel", (0.0, -0.05, 0.0), 'Mesh(\n                asset_path: "models/astronaut/astronaut_male.glb",\n            )',
                      parent=root, extra=suit_mats + '            anim_controller: Some("animation_controllers/character"),\n',
                      rot=(0.0, 1.0, 0.0, 0.0)))
    nodes.append(gen_faces.face_nodes(model, model + 1, ind="            "))
    helm = model + 4
    nodes.append(re.sub(r"parent: Some\(\d+\)", "parent: Some(%d)" % model, HELMET[0]))
    for t in HELMET[1:]:
        nodes.append(re.sub(r"parent: Some\(\d+\)", "parent: Some(%d)" % helm, t))
    count += 8
scene = "(\n    name: \"facestudio\",\n    lighting: (\n        direction: (0.3, 0.8, 0.6),\n        color: (1.0, 0.97, 0.92),\n" \
        "        ambient: (0.10, 0.11, 0.13),\n        intensity: 1.2,\n        shadows: true,\n    ),\n    nodes: [\n" + \
        "".join(nodes) + "    ],\n)\n"
open(out, "w").write(scene)
print("scene", out, n, case)
