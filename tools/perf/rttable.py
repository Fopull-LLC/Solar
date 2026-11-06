#!/usr/bin/env python3
"""rttable.py — the route soak's windows (soakprobe.sh ROUTE=1) as a table.

    rttable.py soak.jsonl [more.jsonl ...]

One row a window (10 s by default): frame p50/p95/p99/max, frames over 33 ms,
hitches (>= 50 ms) and their ms, the bucket they spent most in, Lua memory,
the counts that can grow, and the costliest script of the window."""
import json, sys

def top(lst, n=1):
    return ", ".join(f"{k} {v:.0f}" for k, v in (lst or [])[:n]) or "-"

for path in sys.argv[1:]:
    rows = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    rows = [r for r in rows if "counts" in r]
    if not rows:
        print(f"{path}: no route rows"); continue
    print(f"### {path}\n")
    print("| win | t s | phase | from base m | p50 | p95 | p99 | max | >33 | hitches (ms) | hitch bucket | lua MB | nodes | props | decals | effects | voices | draws | chunks | field | standIns | pending | tex MB | sMesh | top script ms |")
    print("|" + "---|" * 25)
    for r in rows:
        c = r["counts"]
        sc = r.get("scripts") or []
        print(f"| {r['win']} | {r['t']:.0f} | {r['phase']} | {r.get('from_base', -1):.0f} | {r['p50']:.1f} | {r['p95']:.1f} | {r['p99']:.1f} | {r['max']:.0f} | "
              f"{r.get('over33', 0)} | {r['hitches']} ({r.get('hitchMs', 0):.0f}) | {top(r.get('hitchBuckets'))} | {r['lua_kb'] / 1024:.1f} | "
              f"{c.get('nodes', 0)} | {c.get('props', 0)} | {c.get('decals', 0)} | {c.get('effects', 0)} | {c.get('voices', 0)} | {c.get('draws', 0)} | "
              f"{c.get('chunks', 0)} | {c.get('fieldChunks', 0)} | {c.get('fieldStandIns', 0)} | {c.get('meshesPending', 0)} | "
              f"{c.get('textureBytes', 0) / 1048576:.0f} | {c.get('scriptMeshes', 0)} | {(sc[0][0] + ' %.2f' % sc[0][1]) if sc else '-'} |")
    # first third against last third
    k = max(1, len(rows) // 3)
    def mean(rs, f): return sum(f(r) for r in rs) / max(len(rs), 1)
    a, b = rows[:k], rows[-k:]
    print()
    for name, f in [("p50", lambda r: r["p50"]), ("p95", lambda r: r["p95"]), ("p99", lambda r: r["p99"]),
                    ("hitches/window", lambda r: r["hitches"]), ("hitch ms/window", lambda r: r.get("hitchMs", 0)),
                    ("lua MB", lambda r: r["lua_kb"] / 1024), ("nodes", lambda r: r["counts"].get("nodes", 0)),
                    ("fieldChunks", lambda r: r["counts"].get("fieldChunks", 0)), ("tex MB", lambda r: r["counts"].get("textureBytes", 0) / 1048576)]:
        print(f"- {name}: first {k} windows {mean(a, f):.1f}, last {k} {mean(b, f):.1f}")
    # the whole run: where the hitches spent their time, and who allocates
    def acc(key):
        d = {}
        for r in rows:
            for k2, v in (r.get(key) or []):
                d[k2] = d.get(k2, 0) + v
        return sorted(d.items(), key=lambda e: -e[1])
    nh = sum(r["hitches"] for r in rows)
    hm = sum(r.get("hitchMs", 0) for r in rows)
    fr = sum(r["frames"] for r in rows)
    o33 = sum(r.get("over33", 0) for r in rows)
    print(f"\n- whole run: {fr} frames, {o33} over 33 ms, {nh} hitches >= 50 ms ({hm:.0f} ms)")
    print("- hitch buckets (ms): " + ", ".join(f"{k} {v:.0f}" for k, v in acc("hitchBuckets")[:8]))
    print("- hitch parts (ms): " + ", ".join(f"{k} {v:.0f}" for k, v in acc("hitchParts")[:10]))
    print("- hitch scripts (worst six a window, ms): " + ", ".join(f"{k} {v:.0f}" for k, v in acc("hitchScripts")[:10]))
    al = acc("alloc")
    n = max(len([r for r in rows if r.get("alloc")]), 1)
    tot = sum(r.get("allocKBs", 0) for r in rows) / n
    print(f"- allocation, mean KB/s ({tot:.0f} in all): " + ", ".join(f"{k} {v / n:.0f}" for k, v in al[:14]))
    print()
