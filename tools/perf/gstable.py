#!/usr/bin/env python3
"""gstable.py — tables from gpusweep.sh's gs.jsonl files.

  gstable.py a/gs.jsonl b/gs.jsonl ...      one table per resolution:
      scene x preset GPU total, then every pass, draws/instances/props.
  gstable.py --ab before.jsonl... -- after.jsonl...   before -> after per scene/preset
  gstable.py --all a/gs.jsonl ...            every measurement with EVERY timer row (variants
      such as "High_tree0" included), one column per row name, plus the counts
"""
import json
import sys
from collections import OrderedDict

PASSES = [
    ("sky / environment", "sky"),
    ("sun shadow map", "shadow"),
    ("depth prepass + volumetric fog", "prepass+fog"),
    ("matter / terrain", "raymarch"),
    ("opaque + lighting", "opaque"),
    ("glass", "glass"),
    ("particles", "particles"),
    ("reflection capture + overlays", "refl"),
    ("post total", "post"),   # the old "post (…)" row + every "post: " sub-row (engine .1463+)
]
ORDER = ["Low", "Medium", "High", "Ultra"]
SCENES = ["base", "runway", "meadow", "forest", "far", "bigbase", "vab", "alien", "alienfar"]


def load(paths):
    rows = []
    for p in paths:
        for line in open(p, errors="replace"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    return rows


def key(r):
    return (f"{r['w']}x{r['h']}", r["scene"], r["preset"])


def avg(rows):
    """mean of repeated measurements of the same scene/preset/res"""
    out = OrderedDict()
    for r in rows:
        out.setdefault(key(r), []).append(r)
    res = {}
    for k, lst in out.items():
        m = dict(lst[0])
        for f in ("gpu", "p50", "p95", "draws", "instances", "props", "chunks", "lights", "scripts", "render",
                  "sunMapDraws", "sunMapCulled", "triangles"):
            vals = [x.get(f) for x in lst if isinstance(x.get(f), (int, float))]
            m[f] = sum(vals) / len(vals) if vals else None
        ps = {}
        for x in lst:
            for n, v in (x.get("passes") or {}).items():
                ps.setdefault(n, []).append(v)
        m["passes"] = {n: sum(v) / len(v) for n, v in ps.items()}
        # since engine .1463 the timer splits post into "post: AO", "post: FXAA", …; the old
        # "post (…)" row is left a sliver. "post total" is the two summed, on any engine.
        m["passes"]["post total"] = sum(v for n, v in m["passes"].items() if n.startswith("post"))
        m["n"] = len(lst)
        res[k] = m
    return res


def tris(v):
    return "-" if v is None else f"{v / 1e6:.2f} M"


def f(v, d=2):
    return "-" if v is None else f"{v:.{d}f}"


def tables(res):
    resl = sorted({k[0] for k in res})
    for rs in resl:
        print(f"\n### {rs}: GPU ms per frame (frame p50 ms in brackets)\n")
        print("| scene | " + " | ".join(ORDER) + " |")
        print("|---|" + "---|" * len(ORDER))
        for sc in SCENES:
            cells = []
            any_ = False
            for pr in ORDER:
                m = res.get((rs, sc, pr))
                if m:
                    any_ = True
                    cells.append(f"**{f(m['gpu'])}** ({f(m['p50'], 1)})")
                else:
                    cells.append("-")
            if any_:
                print(f"| {sc} | " + " | ".join(cells) + " |")
        print(f"\n### {rs}: per pass (ms), draws / instances / props\n")
        print("| scene | preset | scale | GPU | " + " | ".join(s for _, s in PASSES) + " | draws | inst | props | lights | sun-map draws / culled | tris |")
        print("|---|---|---|---|" + "---|" * (len(PASSES) + 6))
        for sc in SCENES:
            for pr in ORDER:
                m = res.get((rs, sc, pr))
                if not m:
                    continue
                ps = m["passes"]
                print(f"| {sc} | {pr} | {f(m.get('scale'))} | {f(m['gpu'])} | "
                      + " | ".join(f(ps.get(n)) for n, _ in PASSES)
                      + f" | {f(m['draws'], 0)} | {f(m['instances'], 0)} | {f(m['props'], 0)} | {f(m['lights'], 0)}"
                      + f" | {f(m.get('sunMapDraws'), 0)} / {f(m.get('sunMapCulled'), 0)} | {tris(m.get('triangles'))} |")
        subs = sorted({n for m in res.values() if m["w"] == int(rs.split("x")[0]) for n in m["passes"] if n.startswith("post: ")})
        if subs:
            print(f"\n### {rs}: post sub-rows (ms)\n")
            print("| scene | preset | " + " | ".join(n[6:] for n in subs) + " | total |")
            print("|---|---|" + "---|" * (len(subs) + 1))
            for sc in SCENES:
                for pr in ORDER:
                    m = res.get((rs, sc, pr))
                    if m:
                        print(f"| {sc} | {pr} | " + " | ".join(f(m["passes"].get(n)) for n in subs) + f" | {f(m['passes']['post total'])} |")


def dump_all(rows):
    names = []
    for r in rows:
        for n in (r.get("passes") or {}):
            if n not in names:
                names.append(n)
    # biggest rows first (by their largest value), the tiny ones last
    names.sort(key=lambda n: -max((r.get("passes") or {}).get(n, 0) for r in rows))
    print("| run | GPU | " + " | ".join(names) + " | draws | inst | props | tris | sun-map draws / culled |")
    print("|---|---|" + "---|" * (len(names) + 5))
    for r in rows:
        ps = r.get("passes") or {}
        print(f"| {r['scene']} {r['preset']} ({r['w']}x{r['h']} @{f(r.get('scale'))}) | **{f(r.get('gpu'))}** | "
              + " | ".join(f(ps.get(n)) for n in names)
              + f" | {f(r.get('draws'), 0)} | {f(r.get('instances'), 0)} | {f(r.get('props'), 0)} | {tris(r.get('triangles'))}"
              + f" | {f(r.get('sunMapDraws'), 0)} / {f(r.get('sunMapCulled'), 0)} |")


def ab(before, after):
    rb, ra = avg(before), avg(after)
    resl = sorted({k[0] for k in rb} | {k[0] for k in ra})
    for rs in resl:
        print(f"\n### {rs}: GPU ms before -> after (frame p50)\n")
        print("| scene | " + " | ".join(ORDER) + " |")
        print("|---|" + "---|" * len(ORDER))
        for sc in SCENES:
            cells, any_ = [], False
            for pr in ORDER:
                b, a = rb.get((rs, sc, pr)), ra.get((rs, sc, pr))
                if b or a:
                    any_ = True
                cells.append(f"{f(b and b['gpu'])} -> **{f(a and a['gpu'])}** ({f(b and b['p50'], 1)} -> {f(a and a['p50'], 1)})")
            if any_:
                print(f"| {sc} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--all":
        dump_all(load(args[1:]))
    elif args and args[0] == "--ab":
        i = args.index("--")
        ab(load(args[1:i]), load(args[i + 1:]))
    else:
        tables(avg(load(args)))
