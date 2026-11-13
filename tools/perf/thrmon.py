#!/usr/bin/env python3
"""thrmon.py <match-substring> <out.jsonl> [period]
Waits for a process whose cmdline contains <match> (a floptle play), then
every period s logs: per-thread-name CPU % (summed), thread count, RSS MB,
system loadavg, and top threads. Read-only."""
import os, sys, time, json, collections
match, out = sys.argv[1], sys.argv[2]
period = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
HZ = os.sysconf('SC_CLK_TCK')
def find():
    for p in os.listdir('/proc'):
        if not p.isdigit(): continue
        try:
            cl = open(f'/proc/{p}/cmdline', 'rb').read().split(b'\0')
        except Exception: continue
        if cl and cl[0].endswith(b'floptle') and b'play' in cl and any(match.encode() in a for a in cl):
            return int(p)
    return None
t0 = time.time()
pid = None
while pid is None and time.time() - t0 < 1500:
    pid = find()
    if pid is None: time.sleep(1)
if pid is None: sys.exit(1)
f = open(out, 'a')
def snap():
    d = {}
    for t in os.listdir(f'/proc/{pid}/task'):
        try:
            s = open(f'/proc/{pid}/task/{t}/stat').read()
            comm = s[s.index('(') + 1:s.rindex(')')]
            fl = s[s.rindex(')') + 2:].split()
            d[int(t)] = (comm, int(fl[11]) + int(fl[12]), fl[0])
        except Exception: pass
    return d
prev, pt = snap(), time.time()
start = pt
while os.path.exists(f'/proc/{pid}'):
    time.sleep(period)
    try:
        cur, ct = snap(), time.time()
        rss = 0
        for l in open(f'/proc/{pid}/status'):
            if l.startswith('VmRSS'): rss = int(l.split()[1]) / 1024
        la = open('/proc/loadavg').read().split()
    except Exception: break
    dt = ct - pt
    byname = collections.Counter(); cnt = collections.Counter(); per = []; running = 0
    for tid, (comm, ticks, st) in cur.items():
        p = prev.get(tid)
        used = (ticks - p[1]) if p else ticks
        pct = 100.0 * used / HZ / dt
        byname[comm] += pct; cnt[comm] += 1
        per.append((pct, tid, comm))
        if st == 'R': running += 1
    per.sort(reverse=True)
    rec = {'t': round(ct - start, 1), 'threads': len(cur), 'running': running, 'total_pct': round(sum(byname.values()), 1),
           'rss_mb': round(rss), 'load1': float(la[0]), 'procs_running': la[3],
           'byname': {k: [round(v, 1), cnt[k]] for k, v in byname.most_common(14)},
           'top': [[round(a, 1), b, c] for a, b, c in per[:8]]}
    f.write(json.dumps(rec) + '\n'); f.flush()
    prev, pt = cur, ct
