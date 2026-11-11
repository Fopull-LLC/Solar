#!/usr/bin/env python3
"""drive_pops.py <prefixA> <prefixB> — changes between drive steps that one variant has and the other does not.

The two variants of a gpusweep drive (GS.drive, tools/perf/gpusweep_modes.lua) stand at exactly the same
places at every step (the stepped pictures, no easing), so the parallax between step t-1 and t is the
same in both. drive_diff.py's residual (the smallest luminance change within R px) is taken for each
variant, and a pixel counts as a POP of A when A's residual is over THR and B's under THR/3 at the same
pixel (and the other way round for B): a plant or a patch of ground that turned lighter or darker
between two steps in one variant only. A shadow that appears as the drive crosses a distance is
exactly that. Prints, per variant, the share of pixels that pop per step (mean and p99 over steps), the
steps with the most, and writes pops_<A>.png / pops_<B>.png (where they land, summed over the drive).
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive_diff import R, THR, lum, residual  # noqa: E402


def frames(prefix):
    dd, base = os.path.dirname(prefix) or ".", os.path.basename(prefix) + "_f"
    return dd, [os.path.join(dd, f) for f in sorted(os.listdir(dd)) if f.startswith(base) and f.endswith(".png")]


def res_seq(fs):
    out, prev = [], lum(fs[0])
    for f in fs[1:]:
        cur = lum(f)
        out.append(np.minimum(residual(cur, prev), residual(prev, cur)))
        prev = cur
    return out


if __name__ == "__main__":
    A, B = sys.argv[1:3]
    dd, fa = frames(A)
    _, fb = frames(B)
    n = min(len(fa), len(fb))
    ra, rb = res_seq(fa[:n]), res_seq(fb[:n])
    pa = [((x > THR) & (y < THR / 3)) for x, y in zip(ra, rb)]
    pb = [((y > THR) & (x < THR / 3)) for x, y in zip(ra, rb)]
    for name, p in ((os.path.basename(A), pa), (os.path.basename(B), pb)):
        s = np.array([q.mean() * 100 for q in p])
        worst = np.argsort(-s)[:5]
        print(f"{name:28s} pops: mean {s.mean():.3f} % of px a step, p99 {np.percentile(s, 99):.2f} %, steps over 0.5 %: "
              f"{(s > 0.5).sum()} of {len(s)}; worst " + ", ".join(f"f{i + 1}->{i + 2} {s[i]:.2f}%" for i in worst))
        heat = np.sum(p, axis=0).astype(np.float32)
        Image.fromarray((np.clip(heat / max(heat.max(), 1) * 3, 0, 1) * 255).astype(np.uint8)).save(os.path.join(dd, f"pops_{name}.png"))
