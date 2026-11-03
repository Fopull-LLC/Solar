#!/usr/bin/env python3
"""jumptrace.py <vjump.log> [tag] [every]: the JP T lines of jumpprobe as a table."""
import sys, re
log, tag, every = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None), int(sys.argv[3]) if len(sys.argv) > 3 else 3
rows = {}
for line in open(log, errors="replace"):
    i = line.find("JP T ")
    if i < 0: continue
    f = line[i + 5:].split()
    tg = f[0]
    kv = dict(zip(f[1::2], f[2::2]))
    rows.setdefault(tg, []).append(kv)
for tg, rs in rows.items():
    if tag and tg != tag: continue
    print("==", tg)
    print("   t     d     v   roll    rr  bars    yaw    tq  gr pitch  comp")
    for k, r in enumerate(rs):
        if k % every: continue
        print("%5s %5s %5s %6s %5s %5s %6s %5s %3s %5s %s" % (r['t'], r['d'], r['v'], r['roll'], r['rr'], r['bars'], r['yaw'], r['tq'], r['gr'], r['pitch'], r['comp']))
