#!/usr/bin/env python3
"""soaktable.py soak.jsonl [more.jsonl ...] — the soak probe's growth table.

One row per 30 s sample: frame p50/p95/max, Lua memory, nodes, craft, props,
decals, the top scripts. Then the per-script growth: ms/frame in the first
and the last window of each segment, and the slope over all of them."""
import json, sys

rows = []
for p in sys.argv[1:]:
    for line in open(p, errors="replace"):
        line = line.strip()
        if line.startswith("{"):
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
if not rows:
    print("no rows"); sys.exit(0)

print("| seg | win | t s | p50 | p95 | max | mean | lua MB | nodes | craft | parts | props | decals | particles | terrain MB | chunks | top scripts ms/frame |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    top = ", ".join(f"{n} {v:.2f}" for n, v in (r.get("scripts") or [])[:5])
    print(f"| {r.get('seg', 0)} | {r['win']} | {r['t']:.0f} | {r['p50']:.1f} | {r['p95']:.1f} | {r['max']:.0f} | {r['mean']:.2f} | "
          f"{r['lua_kb'] / 1024:.1f} | {r['nodes']} | {r['craft']} | {r['parts']} | {r['props']} | {r['decals']} | {r['particles']} | "
          f"{r['terrain_mb']:.0f} | {r.get('chunks', '')} | {top} |")

# per-script ms/frame, the windows in order (skipping each segment's first: the boot settling)
series = {}
order = []
for r in rows:
    if r["win"] == 0:
        continue
    order.append(r)
    for n, v in r.get("scripts") or []:
        series.setdefault(n, {})[len(order) - 1] = v
N = len(order)
if N >= 2:
    print()
    print(f"Per-script ms/frame over {N} windows (first → last, least-squares slope per 10 windows = 5 min):")
    print()
    print("| script | first | last | mean | slope /5 min |")
    print("|---|---|---|---|---|")
    out = []
    for n, s in series.items():
        xs = list(range(N))
        ys = [s.get(i, 0.0) for i in xs]
        mx, my = sum(xs) / N, sum(ys) / N
        den = sum((x - mx) ** 2 for x in xs) or 1
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
        out.append((slope, n, ys[0], ys[-1], my))
    out.sort(reverse=True)
    for slope, n, a, b, m in out[:15]:
        print(f"| {n} | {a:.3f} | {b:.3f} | {m:.3f} | {slope * 10:+.3f} |")
