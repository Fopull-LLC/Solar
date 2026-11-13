#!/usr/bin/env python3
"""cputable.py <results dir> — cpuprobe.sh's table: the engine's threads
(thr.jsonl, from thrmon.py) beside the game's RT rows (SOAKJSON in <mode>.log).
One line a minute of threads (CPU % by thread name, thread count, RSS, load),
then one line per RT row (frame p50/p95, top scripts, the counts that grow)."""
import json, os, sys, glob
d = sys.argv[1]
thr = [json.loads(l) for l in open(os.path.join(d, 'thr.jsonl'))] if os.path.exists(os.path.join(d, 'thr.jsonl')) else []
print('## threads (every ~30 s)')
for i, r in enumerate(thr):
    if i % 6 and i != len(thr) - 1: continue
    names = ', '.join(f"{k} {v[0]:.0f}%x{v[1]}" for k, v in list(r['byname'].items())[:7])
    print(f"t {r['t']:6.0f}s  total {r['total_pct']:6.0f}%  threads {r['threads']:3d}  rss {r['rss_mb']:5d} MB  load {r['load1']:5.1f} | {names}")
rows = []
for lg in glob.glob(os.path.join(d, '*.log')):
    for l in open(lg, errors='replace'):
        i = l.find('SOAKJSON ')
        if i >= 0:
            try: rows.append(json.loads(l[i + 9:]))
            except Exception: pass
if rows:
    print('## game rows')
    keys = ['nodes', 'props', 'lights', 'voices', 'particles', 'effects', 'chunks', 'fieldChunks', 'fieldStandIns', 'meshesPending', 'meshesInFlight', 'rays', 'sweeps']
    for r in rows:
        c = r.get('counts', {})
        scr = ', '.join(f"{a} {b:.2f}" for a, b in (r.get('scripts') or [])[:5])
        cs = ' '.join(f"{k} {c.get(k, 0):.0f}" for k in keys)
        print(f"w{r['win']:02d} t {r['t']:5.0f} {r.get('phase', ''):6s} p50 {r['p50']:5.1f} p95 {r['p95']:5.1f} max {r['max']:4.0f} lua {r['lua_kb'] / 1024:5.0f}MB base {r.get('from_base', -1):5.0f}m | {cs} | {scr}")
