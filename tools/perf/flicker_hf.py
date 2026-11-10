#!/usr/bin/env python3
"""flicker_hf.py — temporal jitter of frame bursts (tools/perf/framefix.sh lagshadow).

    flicker_hf.py <dir with one sub-folder of fNN.png per burst> [out.png]

Per burst, on luma (0..255), per pixel: hf = |I(t) - (I(t-1) + I(t+1)) / 2|.
A picture sliding steadily has a small hf (the image moves along a line in
time); a shadow edge crawling across a texel grid, or a prop blinking, has the
hf of its own step. Prints the mean, p99 and the share of pixels over 6 levels
per burst; out.png puts the bursts' hf maps side by side (x4, clipped at 64).
"""
import os
import sys

import numpy as np
from PIL import Image


def luma(p):
    a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def burst(d):
    fs = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    if len(fs) < 3:
        return None
    L = [luma(os.path.join(d, f)) for f in fs]
    hf = [np.abs(L[i] - (L[i - 1] + L[i + 1]) * 0.5) for i in range(1, len(L) - 1)]
    return np.mean(hf, axis=0), len(fs)


def main():
    root = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    maps = []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            continue
        r = burst(d)
        if r is None:
            continue
        m, n = r
        print(f"{name:14s} frames {n:3d}  hf mean {m.mean():6.3f}  p99 {np.percentile(m, 99):6.2f}  >6 {100 * (m > 6).mean():5.2f} %")
        maps.append((name, m))
    if out and maps:
        h = max(m.shape[0] for _, m in maps)
        row = np.concatenate([np.clip(m * 4, 0, 255) for _, m in maps], axis=1)
        Image.fromarray(row.astype(np.uint8)).save(out)
        print("wrote", out, "order:", ", ".join(n for n, _ in maps))


if __name__ == "__main__":
    main()
