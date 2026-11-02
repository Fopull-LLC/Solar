#!/usr/bin/env python3
"""exportcheck.py — does an exported build carry every asset the game loads?

    python3 -I tools/perf/exportcheck.py <repo> <file list> <build assets dir>

Run by tools/perf/exportcheck.sh after it exports HEAD. Three checks, each a
FAIL line per missing file and a non-zero exit if any fails:

  1. SHIPPED   every file the project tracks (the <file list>: what the source
               archive was made from) is in the build, unless the exporter
               leaves it out on purpose: .floptleignore, a dot-entry, a root
               runtime dir (save/, replays/), an authoring extension (.py,
               .blend, ...). This is what caught the 2026-10-28 demo: a bare
               `tools export-ignore` in .gitattributes dropped models/tools
               and textures/tools from the archive, so no tool was drawn.
  2. NAMED     every asset path a shipped script, scene, prefab or data file
               names ("models/x.glb", "vfx/AimMark", ...) is in the build. A
               name no file in the repo has either is a WARN (a fallback, an
               optional file), not a FAIL.
  3. HELD      the gear's COMPUTED loads, resolved: every prefab the tool belt
               (TOOLDEF prefab / fp_prefab) and the item registry (hold.prefab,
               hold.fp, worn.prefab) spawn by name, and every model and texture
               those prefabs name, is in the build. These names never appear as
               a path, so a reference scan alone cannot see them.
"""
import os
import re
import sys

NEVER_SHIPS = {"fbx", "obj", "mtl", "dae", "stl", "ply", "3ds", "max", "ma", "mb", "usd", "usda", "usdc",
               "usdz", "blend", "blend1", "blend2", "c4d", "psd", "xcf", "uasset", "umap", "upk", "py",
               "pyc", "pyo"}
RUNTIME_DIRS = {"save", "replays"}
TEXTY = {"lua", "ron", "json", "flsl", "wgsl", "uistyle", "txt", "toml", "cfg"}
ASSET_EXT = r"(?:glb|gltf|png|jpe?g|ktx2|hdr|exr|ogg|wav|mp3|flac|ttf|otf|ron|flsl|wgsl|json|uistyle|bin)"
PATH_RE = re.compile(r'"((?:[A-Za-z0-9_\-]+/)+[A-Za-z0-9_\-.]+\.' + ASSET_EXT + r')"')
VFX_RE = re.compile(r'"(vfx/[A-Za-z0-9_\-]+)"')
ROOTS = ("models/", "textures/", "audio/", "prefabs/", "scenes/", "vfx/", "shaders/", "fonts/", "ui/",
         "materials/", "animations/", "animation_controllers/", "terrain/", "scripts/")


# ── .floptleignore, read as crates/floptle-editor/src/export.rs reads it ─────
def load_ignore(repo):
    pats = []
    p = os.path.join(repo, ".floptleignore")
    if not os.path.exists(p):
        return pats
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.replace("\\", "/")
        dir_only = line.endswith("/")
        body = line.strip("/")
        anchored = line.startswith("/") or "/" in body
        pats.append((body.split("/"), dir_only, anchored))
    return pats


def name_match(pat, name):
    # `*` and `?` within a name, nothing else special (export.rs name_match)
    rx = re.escape(pat).replace(r"\*", ".*").replace(r"\?", ".")
    return re.fullmatch(rx, name, re.S) is not None


def segs_match(pat, path):
    if not pat:
        return not path
    first, rest = pat[0], pat[1:]
    if first == "**":
        return any(segs_match(rest, path[k:]) for k in range(len(path) + 1))
    return bool(path) and name_match(first, path[0]) and segs_match(rest, path[1:])


def ignored(pats, rel):
    """Is `rel` (a file) left out: the file itself, or any folder above it."""
    parts = rel.split("/")
    for depth in range(1, len(parts) + 1):
        sub = parts[:depth]
        is_dir = depth < len(parts)
        for segs, dir_only, anchored in pats:
            if dir_only and not is_dir:
                continue
            if anchored:
                if segs_match(segs, sub):
                    return True
            elif name_match(segs[0], sub[-1]):
                return True
    return False


def exporter_skips(rel, pats):
    parts = rel.split("/")
    if any(p.startswith(".") for p in parts) and rel != ".floptle/textures.ron":
        return "dot-entry"
    if parts[0] in RUNTIME_DIRS and len(parts) > 1:
        return "runtime dir"
    ext = rel.rsplit(".", 1)[-1].lower() if "." in parts[-1] else ""
    if ext in NEVER_SHIPS:
        return "authoring file"
    if ignored(pats, rel):
        return ".floptleignore"
    return None


def main():
    repo, listfile, build = sys.argv[1], sys.argv[2], sys.argv[3]
    fails, warns = [], []
    pats = load_ignore(repo)
    tracked = [l.strip() for l in open(listfile, encoding="utf-8") if l.strip()]
    tracked_set = set(tracked)

    # 1. SHIPPED
    want = 0
    for rel in tracked:
        if exporter_skips(rel, pats):
            continue
        want += 1
        if not os.path.exists(os.path.join(build, rel)):
            fails.append(("SHIPPED", rel, "tracked, not left out by the exporter, missing from the build"))
    print(f"EXPORTCHECK shipped: {want} tracked files should ship, "
          f"{sum(1 for f in fails if f[0] == 'SHIPPED')} missing")

    # 2. NAMED (scanned in the build's own text files)
    named = {}
    for dp, dn, fn in os.walk(build):
        dn[:] = [d for d in dn if not d.startswith(".")]
        for f in fn:
            if f.rsplit(".", 1)[-1].lower() not in TEXTY:
                continue
            p = os.path.join(dp, f)
            try:
                t = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            src = os.path.relpath(p, build)
            for m in PATH_RE.finditer(t):
                r = m.group(1)
                if r.startswith(ROOTS):
                    named.setdefault(r, src)
            for m in VFX_RE.finditer(t):
                named.setdefault(m.group(1) + ".vfx.ron", src)
    n_named_fail = 0
    for r, src in sorted(named.items()):
        if os.path.exists(os.path.join(build, r)):
            continue
        if r in tracked_set or os.path.exists(os.path.join(repo, r)):
            fails.append(("NAMED", r, f"named by {src}, in the repo, missing from the build"))
            n_named_fail += 1
        else:
            warns.append(("NAMED", r, f"named by {src}; no such file in the repo either"))
    print(f"EXPORTCHECK named: {len(named)} asset paths named by shipped files, {n_named_fail} missing "
          f"({sum(1 for w in warns if w[0] == 'NAMED')} name no file anywhere: warnings)")

    # 3. HELD: the gear's prefabs, spawned by name, and what they load
    prefab_at = {}
    for dp, dn, fn in os.walk(os.path.join(repo, "prefabs")):
        for f in fn:
            if f.endswith(".prefab.ron"):
                prefab_at[f[:-len(".prefab.ron")]] = os.path.relpath(os.path.join(dp, f), repo)
    gear = {}
    for script, keys in (("scripts/tool_belt.lua", ("prefab", "fp_prefab")),
                         ("scripts/items.lua", ("prefab", "fp"))):
        t = open(os.path.join(repo, script), encoding="utf-8").read()
        for k in keys:
            for m in re.finditer(r'\b' + k + r'\s*=\s*"([A-Za-z0-9_]+)"', t):
                gear.setdefault(m.group(1), script)
    loads = 0
    for name, script in sorted(gear.items()):
        rel = prefab_at.get(name)
        if not rel:
            fails.append(("HELD", name, f"{script} spawns prefab {name}: no prefabs/{name}.prefab.ron in the repo"))
            continue
        if not os.path.exists(os.path.join(build, rel)):
            fails.append(("HELD", rel, f"{script} spawns it by name; missing from the build"))
            continue
        t = open(os.path.join(build, rel), encoding="utf-8").read()
        for m in PATH_RE.finditer(t):
            loads += 1
            if not os.path.exists(os.path.join(build, m.group(1))):
                fails.append(("HELD", m.group(1), f"loaded by {rel} ({script} spawns {name}); missing from the build"))
        for m in VFX_RE.finditer(t):
            loads += 1
            if not os.path.exists(os.path.join(build, m.group(1) + ".vfx.ron")):
                fails.append(("HELD", m.group(1), f"played by {rel}; missing from the build"))
    print(f"EXPORTCHECK held: {len(gear)} gear prefabs spawned by name, {loads} files they load, "
          f"{sum(1 for f in fails if f[0] == 'HELD')} missing")

    for kind, r, why in warns[:40]:
        print(f"EXPORTCHECK WARN {kind} {r}: {why}")
    if len(warns) > 40:
        print(f"EXPORTCHECK WARN ... and {len(warns) - 40} more")
    for kind, r, why in fails:
        print(f"EXPORTCHECK FAIL {kind} {r}: {why}")
    if fails:
        tops = {}
        for _, r, _ in fails:
            tops[r.split("/")[0]] = tops.get(r.split("/")[0], 0) + 1
        print("EXPORTCHECK RESULT FAIL: %d missing (%s)" % (len(fails), ", ".join(f"{k} {v}" for k, v in sorted(tops.items()))))
        sys.exit(1)
    print("EXPORTCHECK RESULT PASS")


if __name__ == "__main__":
    main()
