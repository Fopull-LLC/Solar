#!/usr/bin/env python3
"""gputable.py bench.jsonl [more.jsonl ...] — the GPU table of a `gpu` run (or
any run): one row per scenario, the picture size, the render scale and graphics
level, the GPU total and every pass the engine timed, then the draw counts."""
import json, sys

rows = []
for path in sys.argv[1:]:
    for line in open(path):
        line = line.strip()
        if line:
            rows.append(json.loads(line))

ORDER = ["sky / environment", "depth prepass", "matter / terrain", "sun shadow map", "opaque + lighting",
         "2D lighting", "glass", "particles", "reflection capture + overlays", "post (AO, bloom, blur…)"]
passes = []
for d in rows:
    for n, _ in d.get("gpuPasses") or []:
        if n not in passes:
            passes.append(n)
passes.sort(key=lambda n: (ORDER.index(n) if n in ORDER else 99, n))
short = {"sky / environment": "sky", "depth prepass": "prepass", "matter / terrain": "matter/terrain",
         "sun shadow map": "sun map", "opaque + lighting": "opaque+light", "2D lighting": "2D light",
         "reflection capture + overlays": "refl+overlays", "post (AO, bloom, blur…)": "post"}

print("| scenario | load | picture | scale | level | frame p50 | gpu ms | " + " | ".join(short.get(p, p) for p in passes) +
      " | draws | inst | chunks | props |")
print("|" + "---|" * (12 + len(passes)))
for d in rows:
    gp = dict(d.get("gpuPasses") or [])
    r = d.get("gpuRes") or {}
    c = d.get("counts") or {}
    pic = f"{int(r.get('w', 0))}x{int(r.get('h', 0))}" if r else ""
    print(f"| {d['scenario']} | {(d.get('uptime_before') or '').split(',')[0]} | {pic} | {r.get('scale', 0):.2f} | {r.get('level', '')} | "
          f"{d['p50']:.1f} | {d.get('gpu', -1):.1f} | " + " | ".join(f"{gp.get(p, 0):.2f}" if p in gp else "" for p in passes) +
          f" | {c.get('draws', 0):.0f} | {c.get('instances', 0):.0f} | {c.get('chunks', 0):.0f} | {c.get('props', 0):.0f} |")
