#!/usr/bin/env python3
"""pop.py — things popping in still-camera frame bursts (tools/perf/popprobe.sh).

    pop.py <frames dir: <phase>/bK_fNN.png>

Per consecutive pair of a burst, on luma (0..255): the 8x8 blocks whose mean
|difference| is over 24 levels. Wind sway and noise move a few levels; a plant
that appears or vanishes moves a block by tens. Per burst: the pairs with any
such block, the most in one pair, and the total; diff_<phase>_<burst>.png (the
worst pair's difference, x4) beside the frames.
"""
import os, re, sys
from collections import defaultdict
import numpy as np
from PIL import Image

B, TH = 8, 24.0


def luma(p):
    a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def blocks(d):
    h, w = d.shape[0] // B * B, d.shape[1] // B * B
    return d[:h, :w].reshape(h // B, B, w // B, B).mean(axis=(1, 3))


def main():
    root = sys.argv[1]
    print("%-8s %-4s %6s %8s %8s %8s" % ("phase", "bur", "pairs", "popPairs", "maxBlk", "sumBlk"))
    for phase in sorted(os.listdir(root)):
        pd = os.path.join(root, phase)
        if not os.path.isdir(pd):
            continue
        bursts = defaultdict(list)
        for f in os.listdir(pd):
            m = re.match(r"([bf]\d+)_f(\d+)\.png$", f)
            if m:
                bursts[m.group(1)].append((int(m.group(2)), os.path.join(pd, f)))
        for b in sorted(bursts):
            fr = [p for _, p in sorted(bursts[b])]
            prev, worst, worst_d = None, -1, None
            n = pp = tot = mx = 0
            for p in fr:
                try:
                    cur = luma(p)
                except Exception:
                    continue
                if prev is not None and prev.shape == cur.shape:
                    d = np.abs(cur - prev)
                    k = int((blocks(d) > TH).sum())
                    n += 1
                    tot += k
                    mx = max(mx, k)
                    if k > 0:
                        pp += 1
                    if k > worst:
                        worst, worst_d = k, d
                prev = cur
            print("%-8s %-4s %6d %8d %8d %8d" % (phase, b, n, pp, mx, tot))
            if worst_d is not None:
                Image.fromarray(np.clip(worst_d * 4, 0, 255).astype(np.uint8)).save(os.path.join(root, "diff_%s_%s.png" % (phase, b)))


if __name__ == "__main__":
    main()
