#!/usr/bin/env python3
"""Frame-to-frame flicker in the visual6 probe's bursts (tools/perf/visual6probe.sh).

    python3 tools/perf/flicker_diff.py <folder> [out folder]

Each burst is <tag>_f1.png .. <tag>_fN.png, shot on consecutive frames with the
camera held still. For every burst: the share of pixels whose brightness jumps
by more than 12 % of full scale between two neighbouring frames (sway moves a
blade a pixel or two: those jumps are small and scattered; a patch flickering is
a large connected block), the share of those pixels that brightened, and the
largest such block. With an out folder: a map per burst (red = brightened,
blue = darkened, over the first frame dimmed)."""
import glob
import os
import re
import sys

import numpy as np
from PIL import Image


def lum(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def blocks(mask):
    """Size of the largest 4-connected block of True (a flood fill on a 1/4 grid)."""
    m = mask[::4, ::4]
    seen = np.zeros_like(m, bool)
    best = 0
    H, W = m.shape
    for y in range(H):
        for x in range(W):
            if m[y, x] and not seen[y, x]:
                stack, n = [(y, x)], 0
                seen[y, x] = True
                while stack:
                    cy, cx = stack.pop()
                    n += 1
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < H and 0 <= nx < W and m[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
                best = max(best, n)
    return best * 16


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    tags = sorted({re.sub(r"_f\d+\.png$", "", os.path.basename(p)) for p in glob.glob(os.path.join(src, "*_f1.png"))})
    for tag in tags:
        files = sorted(glob.glob(os.path.join(src, tag + "_f*.png")), key=lambda p: int(re.findall(r"_f(\d+)\.png$", p)[0]))
        fr = [np.asarray(Image.open(p).convert("RGB"), np.float32) / 255 for p in files]
        L = [lum(f) for f in fr]
        jumps, ups, big = [], [], 0
        acc_up = np.zeros_like(L[0])
        acc_dn = np.zeros_like(L[0])
        for a, b in zip(L, L[1:]):
            d = b - a
            j = np.abs(d) > 0.12
            jumps.append(j.mean())
            ups.append((d > 0.12).sum() / max(1, j.sum()))
            big = max(big, blocks(j))
            acc_up = np.maximum(acc_up, np.clip(d, 0, 1))
            acc_dn = np.maximum(acc_dn, np.clip(-d, 0, 1))
        print("%-28s %2d frames  jumping %.3f %% of pixels a frame (max %.3f %%), %.0f %% of them brightening, largest block %d px"
              % (tag, len(fr), 100 * np.mean(jumps), 100 * max(jumps), 100 * np.mean(ups), big))
        if out:
            os.makedirs(out, exist_ok=True)
            base = fr[0] * 0.45
            k = 4.0
            vis = base.copy()
            vis[..., 0] = np.clip(vis[..., 0] + acc_up * k, 0, 1)
            vis[..., 2] = np.clip(vis[..., 2] + acc_dn * k, 0, 1)
            Image.fromarray((vis * 255).astype(np.uint8)).save(os.path.join(out, tag + "_flicker.png"))


if __name__ == "__main__":
    main()
