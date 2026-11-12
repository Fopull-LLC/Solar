#!/usr/bin/env python3
"""rf_frames.py — one-frame flashes in a dumped window stream (tools/perf/renderfix.sh flick).

    rf_frames.py <dump dir: frame-NNNNN.png> [run.log]

Per frame: the mean luma (Rec.709 of sRGB, 0..255) of the whole picture and of a 4x4 grid
of tiles. A FLASH is a frame whose luma departs from the mean of its two neighbours by more
than `T` levels on the whole picture, or on a quarter or more of the tiles, while the two
neighbours agree with each other (a real cut or a turn moves several frames, a flash is
one). Prints the count, the worst ten, and a frame-to-frame |dL| histogram.
"""
import os, sys, re
import numpy as np
from PIL import Image

T = 6.0


def luma_tiles(p):
    a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)[::4, ::4]
    y = a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722
    h, w = y.shape
    t = y[: h // 4 * 4, : w // 4 * 4].reshape(4, h // 4, 4, w // 4).mean(axis=(1, 3))
    return y.mean(), t.ravel()


def main():
    d = sys.argv[1]
    fs = sorted(f for f in os.listdir(d) if f.startswith("frame-") and f.endswith(".png"))
    if len(fs) < 3:
        print("RFF too few frames", len(fs))
        return
    ids = [int(f[6:11]) for f in fs]
    L, TL = [], []
    for f in fs:
        try:
            m, t = luma_tiles(os.path.join(d, f))
        except Exception:
            m, t = np.nan, np.full(16, np.nan)
        L.append(m)
        TL.append(t)
    L = np.array(L)
    TL = np.array(TL)
    gaps = sum(1 for a, b in zip(ids, ids[1:]) if b != a + 1)
    print(f"RFF {len(fs)} frames {ids[0]}..{ids[-1]} ({gaps} gaps: frames the dump dropped); mean luma {np.nanmean(L):.1f}")
    flashes = []
    for i in range(1, len(fs) - 1):
        if ids[i - 1] != ids[i] - 1 or ids[i + 1] != ids[i] + 1:
            continue
        nb = (L[i - 1] + L[i + 1]) / 2
        agree = abs(L[i - 1] - L[i + 1])
        dev = L[i] - nb
        tn = (TL[i - 1] + TL[i + 1]) / 2
        tdev = TL[i] - tn
        tagree = np.abs(TL[i - 1] - TL[i + 1])
        tiles = int(np.sum((np.abs(tdev) > T) & (tagree < np.abs(tdev) * 0.5)))
        if (abs(dev) > T and agree < abs(dev) * 0.5) or tiles >= 4:
            flashes.append((abs(dev), ids[i], dev, tiles))
    flashes.sort(reverse=True)
    print(f"RFF flashes (one-frame departures > {T} levels whole-picture, or on >= 4 of 16 tiles): {len(flashes)}")
    for a, fid, dev, tiles in flashes[:10]:
        print(f"RFF   frame {fid}: whole {dev:+.1f} levels, tiles off {tiles}")
    dl = np.abs(np.diff(L))
    dl = dl[~np.isnan(dl)]
    if len(dl):
        print("RFF |dL| frame to frame: p50 %.2f p95 %.2f p99 %.2f max %.2f" % tuple(np.percentile(dl, [50, 95, 99, 100])))


if __name__ == "__main__":
    main()
