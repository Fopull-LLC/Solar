#!/usr/bin/env python3
"""Plants that move in the wind: `python3 tools/gen_flora_prefabs.py` writes
prefabs/flora/<model>.prefab.ron and the flora entries of .floptle/textures.ron.

A scatter field draws a .glb/.gltf with the look its file gives it, and a
file's look has no wind in it. Since engine 0.117.0-rc6 (card 0466) a
scattered PREFAB draws each Mesh node with that node's Material, sway and
backlight included, so every plant model gets a one-node prefab wearing the
same pictures its file names, plus:

  sway       how far the game's wind (weather.addWind, weather.lua) bends it.
             The engine's unit: the metres a point ONE metre above the root
             moves in a 10 m/s wind, growing with the square of the height.
             So it is sized to the plant: tip travel = sway * h^2, and we want
             the tip to travel a fraction of the plant's height, so
             sway = fraction / h. A 12 m tree gets 0.0125 (tip 1.8 m), a
             0.5 m grass 0.7 (tip 0.18 m). A tree's bark and crown are two
             models drawn at the same place: both take the SAME sway (from
             the taller of the two), or the crown slides off its trunk.
  backlight  the sun through a leaf from behind. Leaves only; bark none.

Left as plain models (no prefab, no sway): stiff things (cacti, crystals,
coral, spires, tubes, cushions, rosettes, pads, rocks), plants under water
(kelp, sea tubes: there is no wind there) and the models with two materials
in one file (a node Material replaces EVERY part's look, so a bush whose bark
and leaves share a file would be drawn all-leaf).

A Material texture is sampled as its project setting says, and a texture with
no setting is pixel-crisp; the file's own sampler only reaches the plain
model. So the flora pictures get SmoothMipmaps (foliage clamped, as the files
say) in .floptle/textures.ron, or the prefab plants shimmer.

flora_gen.assetFor uses prefabs/flora/<model>.prefab.ron whenever it exists.
"""
import json, os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # or a project given
MODELS = "models/flora"
OUT = "prefabs/flora"

STIFF = {"cactus_barrel", "cactus_col", "crystal_big", "crystals", "coral_tree", "spire", "spire_ringed",
         "tubes", "cushion", "cushion_bloom", "rosette", "rosette_big", "pads"}
UNDERWATER = {"kelp", "kelp_short", "sea_tubes"}
NEEDLES = {"pine", "spruce", "fir_slim", "dwarf_pine"}
TREE_H = 4.0          # taller than this is a tree
TREE_FRAC = 0.15      # a tree's tip travels 15 % of its height in a 10 m/s wind
LOW_FRAC = 0.35       # grass, ferns, herbs: 35 %
SWAY_MAX = 1.0
BACKLIGHT = {"leaf": 0.5, "needle": 0.25, "bark": 0.0}


def load(path):
    with open(os.path.join(ROOT, path)) as f:
        return json.load(f)


def height(g):
    """The model's height above its root. gen_flora.py writes every model's box
    symmetric about the root (the engine recentres on the box), so it is max y."""
    h = 0.0
    for m in g["meshes"]:
        for p in m["primitives"]:
            h = max(h, g["accessors"][p["attributes"]["POSITION"]]["max"][1])
    return h


def image(g, tex):
    if tex is None:
        return None
    uri = g["images"][g["textures"][tex["index"]]["source"]]["uri"]
    return os.path.normpath(os.path.join(MODELS, uri)).replace(os.sep, "/")


def shape_of(name):
    m = re.match(r"(.+?)(_bark)?_l(\d)\.gltf$", name)
    return m.group(1), bool(m.group(2)), int(m.group(3))


def main():
    files = sorted(f for f in os.listdir(os.path.join(ROOT, MODELS)) if f.endswith(".gltf"))
    tall = {}
    for f in files:
        shape, _, _ = shape_of(f)
        tall[shape] = max(tall.get(shape, 0.0), height(load(os.path.join(MODELS, f))))
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    wrote, skipped, textures = 0, {}, {}
    for f in files:
        shape, bark, lod = shape_of(f)
        g = load(os.path.join(MODELS, f))
        why = None
        if shape in STIFF or shape.startswith("rock_"):
            why = "stiff"
        elif shape in UNDERWATER:
            why = "under water"
        elif len(g["materials"]) != 1:
            why = "two materials in one file"
        mat = g["materials"][0]
        pbr = mat.get("pbrMetallicRoughness", {})
        if not why and (pbr.get("metallicRoughnessTexture") or mat.get("emissiveTexture")):
            why = "has maps a prefab Material would not carry"
        if why:
            skipped.setdefault(why, set()).add(shape)
            continue
        h = tall[shape]
        frac = TREE_FRAC if h > TREE_H else LOW_FRAC
        sway = min(SWAY_MAX, frac / h)
        kind = "bark" if mat["name"] == "bark" else ("needle" if shape in NEEDLES else "leaf")
        tex = image(g, pbr.get("baseColorTexture"))
        nrm = image(g, mat.get("normalTexture"))
        fields = []
        if tex:
            fields.append('texture: Some("%s")' % tex)
            textures[tex] = "Clamp" if mat.get("alphaMode") == "MASK" else "Repeat"
        if nrm:
            fields.append('normal_map: Some("%s")' % nrm)
            textures[nrm] = textures.get(tex, "Repeat") if tex else "Repeat"
        fields.append("sway: %.4f" % sway)
        if BACKLIGHT[kind] > 0:
            fields.append("backlight: %.2f" % BACKLIGHT[kind])
        name = f[: -len(".gltf")]
        body = ("// %s: %s, %.1f m tall, tip travels %.2f m in a 10 m/s wind. tools/gen_flora_prefabs.py\n"
                "[(name: \"%s\", transform: (translation: (0.0, 0.0, 0.0)), "
                "matter: Mesh(asset_path: \"%s/%s\"), material: Some((%s)))]\n"
                % (name, kind, h, sway * h * h, name, MODELS, f, ", ".join(fields)))
        with open(os.path.join(ROOT, OUT, name + ".prefab.ron"), "w") as o:
            o.write(body)
        wrote += 1
    # .floptle/textures.ron: keep every other entry, set the flora ones.
    tpath = os.path.join(ROOT, ".floptle", "textures.ron")
    keep = []
    if os.path.exists(tpath):
        # Only the one-line form this tool writes is merged; a file the
        # editor pretty-printed is left for a person to merge.
        for line in open(tpath):
            line = line.rstrip("\n")
            if line.strip() in ("{", "}", ""):
                continue
            m = re.match(r'\s*"([^"]+)": \(.*\),$', line)
            if not m:
                sys.exit("%s is not in this tool's one-line form; add the flora entries by hand" % tpath)
            if m.group(1) not in textures:
                keep.append(line)
    lines = keep + ['    "%s": (filter: SmoothMipmaps, wrap: %s),' % (t, w) for t, w in sorted(textures.items())]
    os.makedirs(os.path.dirname(tpath), exist_ok=True)
    with open(tpath, "w") as o:
        o.write("{\n" + "\n".join(lines) + "\n}\n")
    print("wrote %d prefabs to %s, %d texture settings" % (wrote, OUT, len(textures)))
    for why, s in sorted(skipped.items()):
        print("  plain (%s): %s" % (why, ", ".join(sorted(s))))


if __name__ == "__main__":
    main()
