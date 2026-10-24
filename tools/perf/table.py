#!/usr/bin/env python3
"""table.py bench.jsonl [more.jsonl ...] — the scenario table, the per-frame
breakdown and the top scripts, as markdown. Several files: one row per run."""
import json, sys

GROUPS = [
    ("script", ["scripts", "mirror"]),
    ("physics", ["physics"]),
    ("terrain", ["terrain", "scatter"]),
    ("render", ["render", "models", "animation", "particles", "ui", "assets"]),
    ("gpu/vsync", ["gpuWait", "present"]),
    ("untimed", ["untimed"]),
    ("other", ["audio"]),
]

rows = []
for path in sys.argv[1:]:
    for line in open(path):
        line = line.strip()
        if line:
            rows.append(json.loads(line))

def g(b, keys):
    return sum((b or {}).get(k, 0) for k in keys)

print("| scenario | load (1/5/15) | frames | p50 | p95 | p99 | max | >33 ms | >100 ms | hitches | work p50/p95/max | " +
      " | ".join(n for n, _ in GROUPS) + " |")
print("|" + "---|" * (11 + len(GROUPS)))
for d in rows:
    b = d.get("buckets", {})
    print(f"| {d['scenario']} ({d['mode']}) | {d.get('uptime_before','')} | {d['frames']} | {d['p50']:.1f} | {d['p95']:.1f} | "
          f"{d['p99']:.1f} | {d['max']:.0f} | {d['over33']} | {d['over100']} | {d['hitches']} | "
          f"{(d.get('work') or {}).get('p50',0):.1f}/{(d.get('work') or {}).get('p95',0):.1f}/{(d.get('work') or {}).get('max',0):.0f} | " +
          " | ".join(f"{g(b, ks):.1f}" for _, ks in GROUPS) + " |")

print("\n### Frames over 33 ms: what they were spent on (ms per spike frame)\n")
print("| scenario | spikes | " + " | ".join(n for n, _ in GROUPS) + " | top scripts in spikes | top parts |")
print("|" + "---|" * (4 + len(GROUPS)))
for d in rows:
    if not d.get("nSpikes"):
        continue
    b = d.get("spikeBuckets", {})
    ss = ", ".join(f"{n} {v:.1f}" for n, v in (d.get("spikeScripts") or [])[:4])
    print(f"| {d['scenario']} ({d['mode']}) | {d['nSpikes']} | " + " | ".join(f"{g(b, ks):.1f}" for _, ks in GROUPS) +
          f" | {ss} | |")

print("\n### Top scripts (mean ms/frame, worst frame ms)\n")
for d in rows:
    sc = d.get("scripts") or []
    mx = dict((n, v) for n, v in (d.get("scriptsMax") or []))
    print(f"- **{d['scenario']}** ({d['mode']}): " + ", ".join(f"{n} {v:.2f} (max {mx.get(n, 0):.0f})" for n, v in sc[:8]))
    if d.get("luaFns"):
        print("  - Lua functions (inclusive ms/frame): " + ", ".join(f"{n} {v:.2f}" for n, v in d["luaFns"][:8]))

print("\n### Hitches (frames >= 50 ms, the engine's own record): where the time went\n")
for d in rows:
    if d.get("hitches"):
        hb = ", ".join(f"{n} {v:.0f}" for n, v in (d.get("hitchBuckets") or [])[:5])
        hp = ", ".join(f"{n} {v:.0f}" for n, v in (d.get("hitchParts") or [])[:5])
        print(f"- {d['scenario']} ({d['mode']}): {d['hitches']} hitches, {d.get('hitchMs',0):.0f} ms in all — buckets {hb}; parts {hp}")

print("\n### Worst frames (engine hitch records; scripts from the inverted means, approximate)\n")
for d in rows:
    for i, w in enumerate((d.get("worst") or [])[:3]):
        bs = ", ".join(f"{n} {v:.0f}" for n, v in w["b"])
        ss = ", ".join(f"{n} {v:.0f}" for n, v in w.get("s", []))
        ps = ", ".join(f"{n} {v:.0f}" for n, v in w["p"])
        print(f"- {d['scenario']} #{i+1}: {w['ms']:.0f} ms at +{w['t']:.1f} s — buckets {bs}; scripts {ss}; parts {ps}")

print("\n### Notes and counts\n")
for d in rows:
    c = d.get("counts") or {}
    cm = d.get("countsMax") or {}
    notes = d.get("notes") or {}
    print(f"- {d['scenario']}: " + ", ".join(f"{k}={v}" for k, v in sorted(notes.items())) +
          f" | draws {c.get('draws',0):.0f} (max {cm.get('draws',0)}), nodes {c.get('nodes',0):.0f}, chunks {c.get('chunks',0):.0f}, "
          f"props {c.get('props',0):.0f}, decals {c.get('decals',0):.0f}, rays/frame {c.get('rays',0):.0f} ({c.get('rayMs',0):.2f} ms), "
          f"mirror rebuilds {c.get('mirrorRebuilds',0):.2f}, gpu {d.get('gpu',-1):.1f} ms ({', '.join(f'{n} {v:.1f}' for n, v in (d.get('gpuPasses') or [])[:4])}), parts {', '.join(f'{n} {v:.2f}' for n, v in (d.get('parts') or [])[:4])}")
