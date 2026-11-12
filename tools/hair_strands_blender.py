"""Render the long hair cards' strand columns from real curves (Blender, headless).

    blender --background --python tools/hair_strands_blender.py -- <out.png> [res]

tools/gen_faces_longhair.py runs this (texture()) and lays the result into
columns 0-5 of textures/faces/hair_long.png; the plait lobe and the solid
under-layer columns stay procedural.

Each column is one CLUMP of hair lying on a plane: a few hundred strands, each
a curve with a round section that thins to nothing at its tip, grown from a
narrow root (top of the picture, v = 0) spreading and gathering again toward
the tips, with waves of its own and strays. Strands sit at random depths in
the clump: the ones behind are darker (the light does not reach them, a baked
occlusion), the roots darker still, a few strands lighter, the tips a touch
lighter (sun-faded). Rendered orthographic from above, emission only (the
material lights it in the game), the film transparent, so the alpha is real
antialiased coverage.

Self-made: CC0.
"""
import math
import random
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp/hair_strands.png"
RES = int(argv[1]) if len(argv) > 1 else 2048
COLS = 8                      # the atlas's columns (only 0-5 drawn here)
DRAW = 6
SEED = 23

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
rnd = random.Random(SEED)

# per column: strands, wave, width scale, strand length spread, stray share
SPEC = [
    dict(n=260, wave=0.020, w=1.00, short=0.30, stray=0.04),    # 0 a full clump
    dict(n=200, wave=0.030, w=0.90, short=0.35, stray=0.06),    # 1 looser
    dict(n=330, wave=0.016, w=1.05, short=0.25, stray=0.03),    # 2 dense (the inner layer)
    dict(n=220, wave=0.060, w=0.95, short=0.30, stray=0.06),    # 3 wavy
    dict(n=150, wave=0.025, w=0.85, short=0.40, stray=0.10),    # 4 sparse (the outer layer)
    dict(n=60, wave=0.040, w=0.70, short=0.55, stray=0.50),     # 5 fine flyaways
]
BUCKETS = 10                   # grey levels (one material each)


def smooth(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


mats = []
for i in range(BUCKETS):
    g = (i + 0.5) / BUCKETS
    m = bpy.data.materials.new(f"g{i}")
    m.use_nodes = True
    nt = m.node_tree
    for nd in list(nt.nodes):
        nt.nodes.remove(nd)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (g, g, g, 1)
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs[0], out.inputs[0])
    mats.append(m)

# one curve object per (column, grey bucket); splines are strands
curves = {}


def curve_for(col, b):
    key = (col, b)
    if key not in curves:
        cd = bpy.data.curves.new(f"c{col}_{b}", "CURVE")
        cd.dimensions = "3D"
        cd.bevel_depth = 1.0          # the points' radius is the strand's radius
        cd.bevel_resolution = 1
        cd.use_fill_caps = False
        ob = bpy.data.objects.new(f"c{col}_{b}", cd)
        ob.data.materials.append(mats[b])
        sc.collection.objects.link(ob)
        curves[key] = cd
    return curves[key]


H = float(COLS)               # the picture is COLS x COLS units: a column is 1 wide, H tall
PX = H / RES                  # one pixel
for col, sp in enumerate(SPEC):
    cx = col + 0.5
    for s in range(sp["n"]):
        stray = rnd.random() < sp["stray"]
        off = rnd.gauss(0, 0.20 if not stray else 0.30)
        depth = rnd.random()                       # 0 front .. 1 back
        ln = 1.0 - sp["short"] * rnd.random() ** 1.4
        if stray:
            ln *= rnd.uniform(0.4, 0.9)
        wav = sp["wave"] * rnd.uniform(0.4, 1.4)
        fr = rnd.uniform(3, 9)
        ph = rnd.uniform(0, 6.3)
        drift = rnd.uniform(-0.06, 0.06) + (rnd.uniform(-0.25, 0.25) if stray else 0.0)
        base_r = PX * rnd.uniform(0.55, 0.95) * sp["w"]
        r_ = rnd.random()
        br = min(1.0, max(0.35, rnd.gauss(0.78, 0.09))) if r_ < 0.8 else \
            (rnd.uniform(0.40, 0.55) if r_ < 0.9 else rnd.uniform(0.90, 1.0))
        br *= 1.0 - 0.35 * depth                   # the back of the clump in its own shade
        b = min(BUCKETS - 1, int(br * BUCKETS))
        cd = curve_for(col, b)
        spl = cd.splines.new("POLY")
        npts = 64
        spl.points.add(npts - 1)
        for k in range(npts):
            u = k / (npts - 1) * ln                # 0 root .. ln tip
            spread = 0.55 + 0.45 * smooth(0.0, 0.25, u) - 0.25 * smooth(0.65, 1.0, u)
            x = cx + off * spread + wav * math.sin(u * fr + ph) + drift * u ** 1.5
            x = min(col + 0.98, max(col + 0.02, x))
            y = H - u * H                          # the root at the top
            z = -depth * 0.1
            spl.points[k].co = (x, y, z, 1.0)
            tip = smooth(ln, ln - 0.22, u)         # thinning to nothing at the tip
            spl.points[k].radius = base_r * (0.15 + 0.85 * tip)
        spl.use_endpoint_u = True

# camera: orthographic over the whole atlas, looking down -z
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.type = "ORTHO"
cam.data.ortho_scale = H
cam.location = (H / 2, H / 2, 5.0)
sc.collection.objects.link(cam)
sc.camera = cam
sc.render.resolution_x = RES
sc.render.resolution_y = RES
sc.render.film_transparent = True
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.render.image_settings.color_depth = "8"
sc.view_settings.view_transform = "Raw"         # the grey written as is (the texture is linear data for the tint)
# Cycles on the CPU (no GPU needed headless; emission only, so few samples)
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = 24
sc.cycles.use_denoising = False
sc.cycles.max_bounces = 0
sc.render.filter_size = 1.2
sc.world = bpy.data.worlds.new("w")
sc.render.filepath = OUT
bpy.ops.render.render(write_still=True)
print("STRANDS", OUT, RES, sum(len(c.splines) for c in curves.values()))
