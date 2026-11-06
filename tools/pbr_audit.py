#!/usr/bin/env python3
"""The material audit: every material block in prefabs/ and scenes/ (and the runtime tables in
scripts/), grouped by its texture and the maps it binds, every texture set on disk with the maps it
has, and the models' embedded materials. Markdown out.

    python3 tools/pbr_audit.py OUT.md [ROOT]      # ROOT defaults to this checkout

(tools/detail_maps.py --audit calls write().) Scope notes: terrain layers, ores, flora scatter,
VFX sprites, UI images and the pattern library are listed as excluded, not audited.
"""
import collections
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDS = ["texture", "normal_map", "roughness_map", "metallic_map", "ao_map", "emissive_map", "shader"]
SCAL = ["roughness", "metallic", "normal_strength", "shading", "unlit", "color", "reflectivity"]
EXCLUDED = {"env": "terrain layers, planets, ores (another pass owns them)", "flora": "flora scatter (excluded)",
            "vfx": "VFX sprites (alpha cards, unlit)", "VFXTEX": "VFX sprites", "ui": "UI images",
            "patterns": "emblem pattern library (UI)", "water": "a shader's ripple input"}


def blocks(root):
    out = []
    for d in ("prefabs", "scenes"):
        for r, _, ff in os.walk(os.path.join(root, d)):
            for f in sorted(ff):
                if not f.endswith(".ron"):
                    continue
                path = os.path.join(r, f)
                lines = open(path).read().split("\n")
                i = 0
                while i < len(lines):
                    m = re.match(r'^(\s*)(?:"([^"]+)": \(|material: (?:Some\()?\()\s*$', lines[i])
                    if m:
                        ind = len(m.group(1))
                        j = i + 1
                        while j < len(lines) and not re.match(r"^\s{%d}\)" % ind, lines[j]):
                            j += 1
                        txt = "\n".join(lines[i + 1:j])
                        if "color:" in txt or "texture:" in txt or "shading:" in txt:
                            b = dict(file=os.path.relpath(path, root), name=m.group(2) or "(node)")
                            for k in FIELDS:
                                mm = re.search(r'^\s*%s: Some\("([^"]+)"\)' % k, txt, re.M)
                                b[k] = mm.group(1) if mm else None
                            for k in SCAL:
                                mm = re.search(r"^\s*%s: ([^\n]+?),?\s*$" % k, txt, re.M)
                                b[k] = mm.group(1) if mm else None
                            out.append(b)
                        i = j
                    i += 1
    return out


def glbs(root):
    res = collections.defaultdict(lambda: [0, 0, 0, 0])
    for r, _, ff in os.walk(os.path.join(root, "models")):
        for f in ff:
            if not f.endswith(".glb"):
                continue
            b = open(os.path.join(r, f), "rb").read()
            ln = struct.unpack("<I", b[12:16])[0]
            j = json.loads(b[20:20 + ln])
            k = os.path.relpath(r, os.path.join(root, "models")).split(os.sep)[0]
            s = res[k]
            s[0] += 1
            for m in j.get("materials", []):
                pb = m.get("pbrMetallicRoughness", {})
                s[1] += "baseColorTexture" in pb
                s[2] += "normalTexture" in m
                s[3] += "metallicRoughnessTexture" in pb
    return res


def sets(root):
    """Texture sets on disk: stem → which maps exist."""
    tex = os.path.join(root, "textures")
    rows = []
    dirs = [(d, os.path.join(tex, d)) for d in sorted(os.listdir(tex))]
    dirs.append(("models/iva/tex", os.path.join(root, "models", "iva", "tex")))     # the cabin interiors' own set
    for d, p in dirs:
        if not os.path.isdir(p) or d in EXCLUDED:
            continue
        files = sorted(f for f in os.listdir(p) if f.endswith(".png"))
        stems = []
        for f in files:
            s = f[:-4]
            if re.search(r"_(normal|orm|height)$", s):
                continue
            stems.append(re.sub(r"_albedo$", "", s))
        for s in stems:
            have = lambda suf: os.path.exists(os.path.join(p, s + suf + ".png"))
            alb = s + "_albedo.png" if have("_albedo") else s + ".png"
            rows.append((d + "/" + alb, have("_normal"), have("_orm"), have("_height")))
    return rows


def write(path, root=None):
    root = root or os.path.dirname(HERE)
    B = blocks(root)
    g = collections.OrderedDict()
    for b in B:
        key = (b["texture"] or "(none)", bool(b["normal_map"]), bool(b["roughness_map"] or b["metallic_map"] or b["ao_map"]),
               bool(b["ao_map"]), bool(b["emissive_map"]), b["shading"] or "Classic", bool(b["unlit"]), bool(b["shader"]))
        g.setdefault(key, []).append(b)
    L = ["## Material blocks (prefabs/, scenes/): %d blocks" % len(B), "",
         "| n | texture | normal | ORM | AO | shading | names | roughness / metal / normal strength |",
         "|---|---|---|---|---|---|---|---|"]
    for k, v in sorted(g.items(), key=lambda kv: -len(kv[1])):
        names = collections.Counter(x["name"] for x in v)
        rs = collections.Counter("%s / %s / %s" % (x["roughness"], x["metallic"], x["normal_strength"] or "-") for x in v)
        sh = k[5] + (" unlit" if k[6] else "") + (" +shader" if k[7] else "")
        L.append("| %d | `%s` | %s | %s | %s | %s | %s | %s |" % (
            len(v), k[0], "yes" if k[1] else "-", "yes" if k[2] else "-", "yes" if k[3] else "-", sh,
            ", ".join("%s x%d" % nn for nn in names.most_common(5)), "; ".join("%s (x%d)" % rr for rr in rs.most_common(2))))
    L += ["", "## Texture sets on disk (textures/, scope only)", "", "| albedo | normal | ORM | height |", "|---|---|---|---|"]
    for a, n, o, h in sets(root):
        L.append("| `%s` | %s | %s | %s |" % (a, "yes" if n else "-", "yes" if o else "-", "yes" if h else "-"))
    L += ["", "Excluded folders: " + "; ".join("`%s` %s" % kv for kv in EXCLUDED.items()), "",
          "## Models' embedded materials (models/**/*.glb)", "",
          "| folder | files | materials with a base texture | with a normal texture | with a metal-rough texture |",
          "|---|---|---|---|---|"]
    for k, v in sorted(glbs(root).items()):
        L.append("| %s | %d | %d | %d | %d |" % (k, *v))
    open(path, "w").write("\n".join(L) + "\n")
    print("audit", path, len(B), "blocks")


if __name__ == "__main__":
    write(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
