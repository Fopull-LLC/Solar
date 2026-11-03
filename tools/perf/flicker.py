#!/usr/bin/env python3
"""flicker.py — temporal flicker of still-camera frame bursts (tools/perf/flickerprobe.sh).

    flicker.py <frames dir: <cfg>/<spot>/fNN.png> <out dir> [--cmp <other out dir> <label>]

Per burst, on luma (Rec.709 of the sRGB values, 0..255):
  std   the per-pixel temporal standard deviation over the frames
  hf    the per-pixel mean |I(t) - (I(t-1) + I(t+1)) / 2| (frame-to-frame jitter;
        a slow drift such as the sun moving scores ~0 here, flicker does not)
  >4    the share of pixels whose std is above 4 levels (visible)
  bands the std mean of the picture's top / middle / bottom thirds (far .. near
        on the landscape and yard views)
Writes table.txt (and table.json), heat/<cfg>_<spot>.png (the mean frame in
grey with the std over it, 0 → transparent, 16+ levels → white-hot) and
std/<cfg>_<spot>.npz (float16) for comparisons; with every config present,
heat/attr_<effect>_<spot>.png: std(base) - std(without that effect), the
flicker that effect is responsible for.
"""
import json, os, sys
import numpy as np
from PIL import Image


def luma(p):
    a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def heat(mean, std, path, vmax=16.0):
    t = np.clip(std / vmax, 0, 1)
    # black-red-yellow-white ramp
    r = np.clip(t * 3, 0, 1); g = np.clip(t * 3 - 1, 0, 1); b = np.clip(t * 3 - 2, 0, 1)
    base = (mean[..., None] * 0.45).repeat(3, axis=2) / 255.0
    a = np.clip(t * 4, 0, 1)[..., None]
    rgb = base * (1 - a) + np.stack([r, g, b], axis=2) * a
    Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).save(path)


def cut_dump(dump, log, out):
    """The engine's FLOPTLE_FRAME_DUMP frames (frame-NNNNN.png, the player's
    frame count) cut into bursts by the probe's `DUMP <cfg> <spot> frames a b`
    lines (its own update count). The two counts differ by a small constant:
    the one that makes the bursts stillest is taken, then the frames are
    linked as <out>/dumpframes/<cfg>/<spot>/fNN.png."""
    import re
    wins = []
    for ln in open(log, errors="replace"):
        m = re.search(r"DUMP (\S+) (\S+) frames (\d+) (\d+)", ln)
        if m:
            wins.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4))))
    have = {int(f[6:11]) for f in os.listdir(dump) if f.startswith("frame-") and f.endswith(".png")}
    def path(i):
        return os.path.join(dump, f"frame-{i:05d}.png")
    def score(k):
        tot = 0.0
        for (_, _, a, b) in wins[:4]:
            ids = [i + k for i in range(a, b + 1, 3)]
            if not all(i in have for i in ids):
                return 1e9
            st = np.stack([luma(path(i))[::4, ::4] for i in ids])
            tot += float(st.std(axis=0).mean())
        return tot
    best = min(range(-12, 13), key=score)
    print(f"dump: frame offset {best:+d} (stillness {score(best):.3f}; {len(wins)} bursts, {len(have)} frames)")
    root = os.path.join(out, "dumpframes")
    for (cfg, spot, a, b) in wins:
        d = os.path.join(root, cfg, spot)
        os.makedirs(d, exist_ok=True)
        for j, i in enumerate(range(a + best, b + best + 1)):
            if i in have:
                dst = os.path.join(d, f"f{j:02d}.png")
                if os.path.lexists(dst):
                    os.remove(dst)
                os.symlink(path(i), dst)
    return root


def main():
    if sys.argv[1] == "--dump":
        root = cut_dump(sys.argv[2], sys.argv[3], sys.argv[4])
        sys.argv = [sys.argv[0], root, sys.argv[4]]
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(out, "heat"), exist_ok=True)
    os.makedirs(os.path.join(out, "std"), exist_ok=True)
    rows, stds, means = [], {}, {}
    for cfg in sorted(os.listdir(src)):
        cd = os.path.join(src, cfg)
        if not os.path.isdir(cd):
            continue
        for spot in sorted(os.listdir(cd)):
            sd = os.path.join(cd, spot)
            fs = sorted(f for f in os.listdir(sd) if f.endswith(".png"))
            if len(fs) < 3:
                continue
            st = np.stack([luma(os.path.join(sd, f)) for f in fs])
            std = st.std(axis=0)
            hf = np.abs(st[1:-1] - 0.5 * (st[:-2] + st[2:])).mean(axis=0)
            mean = st.mean(axis=0)
            h = std.shape[0]
            bands = [float(std[i * h // 3:(i + 1) * h // 3].mean()) for i in range(3)]
            r = dict(cfg=cfg, spot=spot, n=len(fs), std_mean=float(std.mean()), std_p99=float(np.percentile(std, 99)),
                     hf_mean=float(hf.mean()), hf_p99=float(np.percentile(hf, 99)), vis=float((std > 4).mean() * 100),
                     bands=bands)
            rows.append(r)
            stds[(cfg, spot)], means[(cfg, spot)] = std, mean
            heat(mean, std, os.path.join(out, "heat", f"{cfg}_{spot}.png"))
            np.savez_compressed(os.path.join(out, "std", f"{cfg}_{spot}.npz"), std=std.astype(np.float16),
                                hf=hf.astype(np.float16), mean=mean.astype(np.float16))
    for eff, cfg in (("refl", "norefl"), ("ao", "noao"), ("contact", "nocontact")):
        for (c, spot), std in list(stds.items()):
            if c == "base" and (cfg, spot) in stds:
                heat(means[(c, spot)], np.clip(std - stds[(cfg, spot)], 0, None),
                     os.path.join(out, "heat", f"attr_{eff}_{spot}.png"))
    lines = [f"{'cfg':10s} {'spot':16s} {'n':>3s} {'std mean':>8s} {'std p99':>8s} {'hf mean':>8s} {'hf p99':>8s} "
             f"{'%>4':>6s}  bands top/mid/bot"]
    for r in rows:
        lines.append(f"{r['cfg']:10s} {r['spot']:16s} {r['n']:3d} {r['std_mean']:8.3f} {r['std_p99']:8.2f} "
                     f"{r['hf_mean']:8.3f} {r['hf_p99']:8.2f} {r['vis']:6.2f}  "
                     + " / ".join(f"{b:.2f}" for b in r["bands"]))
    open(os.path.join(out, "table.txt"), "w").write("\n".join(lines) + "\n")
    json.dump(rows, open(os.path.join(out, "table.json"), "w"), indent=1)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
