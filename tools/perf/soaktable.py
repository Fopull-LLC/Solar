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

def g(r, k, fmt="{}"):
    v = r.get(k)
    return "" if v is None else fmt.format(v)

print("| seg | win | t s | menus | p50 | p95 | max | mean | lua MB | lua live MB | nodes | scripts | rigidbodies | meshes | textures | craft | props | decals | draws | terrain MB | chunks | top scripts ms/frame |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    top = ", ".join(f"{n} {v:.2f}" for n, v in (r.get("scripts") or [])[:4])
    live = r.get("lua_live_kb")
    print(f"| {r.get('seg', 0)} | {r['win']} | {r['t']:.0f} | {g(r, 'menus')} | {r['p50']:.1f} | {r['p95']:.1f} | {r['max']:.0f} | {r['mean']:.2f} | "
          f"{r['lua_kb'] / 1024:.1f} | {'' if live is None else f'{live / 1024:.1f}'} | {r['nodes']} | {g(r, 'inst')} | {g(r, 'rigidbodies')} | "
          f"{g(r, 'meshes')} | {g(r, 'textures')} | {r['craft']} | {r['props']} | {r['decals']} | {g(r, 'draws')} | "
          f"{r['terrain_mb']:.0f} | {r.get('chunks', '')} | {top} |")

# per-script ms/frame, the windows in order (skipping each segment's first: the boot settling)
series = {}
order = []
for r in rows:
    # each segment's first window is the boot settling; a stub window (the
    # last sample, seconds after the one before) is too short to compare
    if r["win"] == 0 or r.get("frames", 1000) < 300:
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
        # a script missing from a window's top list is under its cut: count
        # it at the smallest listed cost of that window rather than 0
        ys = [s.get(i, min((v for _, v in (order[i].get("scripts") or [])), default=0.0)) for i in xs]
        mx, my = sum(xs) / N, sum(ys) / N
        den = sum((x - mx) ** 2 for x in xs) or 1
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
        out.append((slope, n, ys[0], ys[-1], my))
    out.sort(reverse=True)
    for slope, n, a, b, m in out[:15]:
        print(f"| {n} | {a:.3f} | {b:.3f} | {m:.3f} | {slope * 10:+.3f} |")
