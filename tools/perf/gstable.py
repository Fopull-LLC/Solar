#!/usr/bin/env python3
"""gstable.py — tables from gpusweep.sh's gs.jsonl files.

  gstable.py a/gs.jsonl b/gs.jsonl ...      one table per resolution:
      scene x preset GPU total, then every pass, draws/instances/props.
  gstable.py --ab before.jsonl... -- after.jsonl...   before -> after per scene/preset
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
    ("post (AO, bloom, blur…)", "post"),
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
        for f in ("gpu", "p50", "p95", "draws", "instances", "props", "chunks", "lights", "scripts", "render"):
            vals = [x.get(f) for x in lst if isinstance(x.get(f), (int, float))]
            m[f] = sum(vals) / len(vals) if vals else None
        ps = {}
        for x in lst:
            for n, v in (x.get("passes") or {}).items():
                ps.setdefault(n, []).append(v)
        m["passes"] = {n: sum(v) / len(v) for n, v in ps.items()}
        m["n"] = len(lst)
        res[k] = m
    return res


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
        print("| scene | preset | scale | GPU | " + " | ".join(s for _, s in PASSES) + " | draws | inst | props | lights |")
        print("|---|---|---|---|" + "---|" * (len(PASSES) + 4))
        for sc in SCENES:
            for pr in ORDER:
                m = res.get((rs, sc, pr))
                if not m:
                    continue
                ps = m["passes"]
                print(f"| {sc} | {pr} | {f(m.get('scale'))} | {f(m['gpu'])} | "
                      + " | ".join(f(ps.get(n)) for n, _ in PASSES)
                      + f" | {f(m['draws'], 0)} | {f(m['instances'], 0)} | {f(m['props'], 0)} | {f(m['lights'], 0)} |")


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
    if args and args[0] == "--ab":
        i = args.index("--")
        ab(load(args[1:i]), load(args[i + 1:]))
    else:
        tables(avg(load(args)))
