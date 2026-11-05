#!/usr/bin/env python3
"""jetland.py <log> [...]: the gear's motion from a motoprobe jetland log.

Reads the per-tick `JT` lines (tools/perf/motoprobe_modes.lua run_jetland):
  JT <phase> <t> V agl vu theta q p herr capped | uid:G/- pos load oleo ...
and prints, per phase, each wheel's contact changes, stroke (mean, rms about
the mean, peak to peak), the stroke's dominant frequency, the load's spread,
and the hull's vertical and pitch motion; then, per landing, the touchdown,
the bounce, the peak load factor, the settle time and the heading drift.
"""
import re
import sys

import numpy as np


def parse(path):
    rows = []
    g = 7.0
    for line in open(path, errors="replace"):
        m = re.search(r"MP jetland craft: .* g ([0-9.]+)", line)
        if m:
            g = float(m.group(1))
        i = line.find(" JT ")
        if i < 0:
            continue
        head, _, tail = line[i + 4:].partition("|")
        h = head.split()
        if len(h) < 10:
            continue
        r = dict(ph=h[0], t=float(h[1]), V=float(h[2]), agl=float(h[3]), vu=float(h[4]), th=float(h[5]),
                 q=float(h[6]), p=float(h[7]), herr=float(h[8]), cap=float(h[9]), w={})
        if len(h) >= 15:
            r.update(cx=float(h[10]), cy=float(h[11]), cz=float(h[12]), m=float(h[13]), rh=int(h[14]))
        tok = tail.split()
        for k in range(0, len(tok) - 3, 4):
            uid, gs = tok[k].split(":")
            r["w"][int(uid)] = dict(g=gs == "G", pos=float(tok[k + 1]), load=float(tok[k + 2]), oleo=float(tok[k + 3]))
        rows.append(r)
    return rows, g


def dom_freq(x, dt):
    x = np.asarray(x) - np.mean(x)
    if len(x) < 16 or np.std(x) < 1e-5:
        return 0.0
    f = np.fft.rfftfreq(len(x), dt)
    a = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    a[0] = 0
    return float(f[int(np.argmax(a))])


def phase_table(rows):
    phases = []
    for r in rows:
        if not phases or phases[-1][0] != r["ph"]:
            phases.append((r["ph"], []))
        phases[-1][1].append(r)
    print("%-8s %5s %5s | %-44s | %s" % ("phase", "s", "V", "hull: vu rms, |a| max g, q rms, theta p2p", "wheel uid: contact changes, stroke mean/rms/p2p mm, f Hz, load mean/rms kN"))
    for ph, rs in phases:
        if len(rs) < 10:
            continue
        t = np.array([r["t"] for r in rs])
        dt = float(np.median(np.diff(t))) or 1 / 60
        vu = np.array([r["vu"] for r in rs])
        a = np.diff(vu) / dt
        th = np.array([r["th"] for r in rs])
        q = np.array([r["q"] for r in rs])
        out = []
        for uid in sorted(rs[0]["w"]):
            pos = np.array([r["w"].get(uid, {}).get("pos", 0) for r in rs]) * 1000
            gr = [r["w"].get(uid, {}).get("g", False) for r in rs]
            ld = np.array([r["w"].get(uid, {}).get("load", 0) for r in rs])
            ch = sum(1 for k in range(1, len(gr)) if gr[k] != gr[k - 1])
            out.append("%d: %3d ch %5.1f/%4.1f/%5.1f mm %4.1f Hz %5.1f/%4.1f kN" % (uid, ch, pos.mean(), pos.std(), pos.max() - pos.min(),
                                                                                   dom_freq(pos, dt), ld.mean(), ld.std()))
        print("%-8s %5.1f %5.1f | vu %.3f a %5.2f q %.3f th %4.1f | %s" % (ph, t[-1] - t[0], np.mean([r["V"] for r in rs]), vu.std(),
                                                                         (np.abs(a).max() if len(a) else 0) / 9.81, np.sqrt(np.mean(q * q)),
                                                                         th.max() - th.min(), " · ".join(out)))


def landings(rows, g):
    i = 0
    n = 0
    while i < len(rows):
        r = rows[i]
        if r["ph"].startswith("land") and (i == 0 or not rows[i - 1]["ph"].startswith("land")):
            n += 1
            ph = r["ph"]
            rs = [x for x in rows[i:] if x["ph"] == ph]
            # the touchdown: the approach's last ticks, back to the first tyre down
            k = i
            while k > 0 and rows[k - 1]["ph"].startswith("appr") and any(w["g"] for w in rows[k - 1]["w"].values()):
                k -= 1
            td = rows[k]
            seq = rows[k:i] + rs
            t = np.array([x["t"] for x in seq])
            dt = float(np.median(np.diff(t))) if len(t) > 2 else 1 / 60
            vu = np.array([x["vu"] for x in seq])
            a = np.diff(vu) / dt
            a3 = np.convolve(a, np.ones(3) / 3, mode="same") if len(a) > 3 else a
            agl = np.array([x["agl"] for x in seq])
            # the bounce: the highest the CoM got above its touchdown height,
            # after the gear first pushed it up
            up = np.argmax(vu > 0.05) if np.any(vu > 0.05) else len(vu) - 1
            bounce = float(np.max(agl[up:]) - td["agl"]) if up < len(agl) else 0.0
            air = [not any(w["g"] for w in x["w"].values()) for x in seq]
            air_s = sum(air) * dt
            first = None
            for uid, w in td["w"].items():
                if w["g"]:
                    first = uid
            # settled: every tyre down and |vu| < 0.15 m/s for 1 s on end
            settle = None
            run = 0
            for x in seq:
                ok = all(w["g"] for w in x["w"].values()) and abs(x["vu"]) < 0.15
                run = run + dt if ok else 0
                if run >= 1.0:
                    settle = x["t"] - 1.0 - td["t"]
                    break
            herr = np.array([x["herr"] for x in seq[:int(5 / dt)]])
            pos = {uid: max(x["w"][uid]["pos"] for x in seq) * 1000 for uid in td["w"]}
            ch = {uid: sum(1 for a_, b_ in zip(seq, seq[1:]) if a_["w"][uid]["g"] != b_["w"][uid]["g"]) for uid in td["w"]}
            th = np.array([x["th"] for x in seq[:int(3 / dt)]])
            print("landing %d: V %.1f sink %.2f theta %.1f first %s | bounce %.2f m, %.2f s in the air, peak %.2f g (%.2f raw), settle %s, "
                  "heading drift %.1f deg, pitch %.1f..%.1f | stroke max %s mm, contact changes %s" % (
                      n, td["V"], -td["vu"], td["th"], first, bounce, air_s, 1 + a3.max() / g, 1 + a.max() / g,
                      ("%.2f s" % settle) if settle is not None else "never", np.max(np.abs(herr - herr[0])) if len(herr) else 0,
                      th.min(), th.max(), {u: round(v) for u, v in pos.items()}, ch))
            i += len(rs)
        else:
            i += 1


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print("==", p)
        rows, g = parse(p)
        print("%d ticks, g %.2f" % (len(rows), g))
        phase_table(rows)
        landings(rows, g)


def windows(rows, ph, win=1.0):
    """Per-window detail of one phase: speed, the stroke range of each wheel, contact changes, peak |a|."""
    rs = [r for r in rows if r["ph"] == ph]
    if not rs:
        return
    t0 = rs[0]["t"]
    k = 0
    while k < len(rs):
        ws = [r for r in rs[k:] if r["t"] < rs[k]["t"] + win]
        vu = np.array([r["vu"] for r in ws])
        dt = 1 / 60
        a = np.abs(np.diff(vu)) / dt if len(vu) > 1 else np.zeros(1)
        parts = []
        for uid in sorted(ws[0]["w"]):
            pos = [r["w"][uid]["pos"] * 1000 for r in ws if uid in r["w"]]
            gr = [r["w"][uid]["g"] for r in ws if uid in r["w"]]
            ld = [r["w"][uid]["load"] for r in ws if uid in r["w"]]
            ch = sum(1 for i in range(1, len(gr)) if gr[i] != gr[i - 1])
            parts.append("%d %4.0f..%4.0f mm ch %2d ld %4.1f..%4.1f" % (uid, min(pos), max(pos), ch, min(ld), max(ld)))
        print("  %s +%4.1f V %5.1f th %5.1f..%5.1f a %5.1f | %s" % (ph, ws[0]["t"] - t0, ws[0]["V"], min(r["th"] for r in ws), max(r["th"] for r in ws),
                                                               a.max(), " · ".join(parts)))
        k += len(ws)


if __name__ == "__main__" and len(sys.argv) > 1 and False:
    pass
