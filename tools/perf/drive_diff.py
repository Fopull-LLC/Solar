#!/usr/bin/env python3
"""drive_diff.py <prefix> [<prefix> ...] — what changes between drive frames that the motion does not explain.

<prefix> is e.g. results/<TAG>/shots/drive_base: the frames are <prefix>_f0001.png, ...

The frames are gpusweep's drive (GS.drive, tools/perf/gpusweep_modes.lua): a 640x360 PNG a frame as the
eye runs along a line through a forest. Between two frames everything moves a little, so a plain
difference is all motion. For each pixel of frame t this takes the SMALLEST luminance difference to any
pixel within R px of the same place in frame t-1 (a block search with no model of the motion): what
moved by less than R px is explained, what changed brightness in place is not. Far things (20-200 m,
where a plant crossed a shadow distance) move by a pixel or two a frame at drive speed, so a plant that
turns lighter in one frame stands out. Near things move by more than R and leave residual at their
edges in every variant alike, so compare variants of the same drive (the steps are the same places),
not absolute numbers; the residual is taken both ways (t vs t-1 and back) and the smaller kept.

Per run: the mean residual, its p99 and p99.9, the frames with a burst (more than 0.2 % of the picture's
pixels over the threshold, in the band above the bottom quarter, where the near ground streaks), and a
heat map of where the residual lands (heat_<prefix>.png beside the frames).
"""
import os
import sys

import numpy as np
from PIL import Image

R = int(os.environ.get("DRIVE_R", 2))              # px of motion explained
THR = float(os.environ.get("DRIVE_THR", 0.06))     # residual luminance (0..1, sRGB-ish) that counts as a change
BAND = float(os.environ.get("DRIVE_BAND", 0.75))   # the top share of the picture looked at (far things move least)


def lum(p):
    a = np.asarray(Image.open(p).convert("RGB"), np.float32) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def residual(a, b):
    """min over shifts |a(p) - b(p+d)|, |d| <= R."""
    h, w = a.shape
    best = np.full((h - 2 * R, w - 2 * R), 9.0, np.float32)
    core = a[R:h - R, R:w - R]
    for dy in range(-R, R + 1):
        for dx in range(-R, R + 1):
            sb = b[R + dy:h - R + dy, R + dx:w - R + dx]
            np.minimum(best, np.abs(core - sb), out=best)
    return best


def run(d):
    dd, base = os.path.dirname(d) or ".", os.path.basename(d) + "_f"
    fs = [os.path.join(dd, f) for f in sorted(os.listdir(dd)) if f.startswith(base) and f.endswith(".png")]
    if len(fs) < 3:
        return None
    prev = lum(fs[0])
    h, w = prev.shape
    heat = np.zeros((h - 2 * R, w - 2 * R), np.float32)
    allr, bursts = [], []
    band = slice(0, int((h - 2 * R) * BAND))           # leave out the near ground's streak
    for i, f in enumerate(fs[1:], 1):
        cur = lum(f)
        r1 = residual(cur, prev)
        r2 = residual(prev, cur)
        r = np.minimum(r1, r2)                         # a change in place shows both ways; an occlusion edge one way
        rb = r[band]
        allr.append(rb.ravel()[::7])
        over = (rb > THR).mean()
        heat[band] += (rb > THR)
        if over > 0.002:
            bursts.append((i, over))
        prev = cur
    a = np.concatenate(allr)
    hm = heat / max(heat.max(), 1)
    Image.fromarray((np.clip(hm * 4, 0, 1) * 255).astype(np.uint8)).save(os.path.join(dd, f"heat_{os.path.basename(d)}.png"))
    return dict(frames=len(fs), mean=float(a.mean()), p99=float(np.percentile(a, 99)), p999=float(np.percentile(a, 99.9)),
                over=float((a > THR).mean()), bursts=len(bursts), worst=sorted(bursts, key=lambda x: -x[1])[:5])


if __name__ == "__main__":
    for d in sys.argv[1:]:
        o = run(d)
        if not o:
            print(f"{d}: too few frames")
            continue
        print(f"{os.path.basename(d.rstrip('/')):28s} frames {o['frames']:4d}  residual mean {o['mean']:.4f} p99 {o['p99']:.3f} "
              f"p99.9 {o['p999']:.3f}  over {THR} {o['over'] * 100:.3f} %  burst frames {o['bursts']}  worst "
              + ", ".join(f"f{i} {v * 100:.2f}%" for i, v in o['worst']))
