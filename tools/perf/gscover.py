#!/usr/bin/env python3
"""gscover.py — coverage pictures from gpusweep.sh COVER=1 runs.

  gscover.py <results dir>     reads cover.txt (the ray grids) and
  shots/cover_<scene>_with.png / _without.png (flora on / off), writes
  coverage_<scene>.png (sky blue, terrain brown, geometry grey, flora green,
  beside the picture) and prints the shares.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops

COL = {"s": (90, 150, 230), "t": (140, 100, 60), "g": (150, 150, 150), "f": (60, 200, 60)}


def main(d):
    d = Path(d)
    for line in open(d / "cover.txt"):
        parts = line.split()
        if len(parts) < 4:
            continue
        scene, gw, gh, rows = parts[0], int(parts[1]), int(parts[2]), parts[3].split("/")
        wpath, npath = d / "shots" / f"cover_{scene}_with.png", d / "shots" / f"cover_{scene}_without.png"
        flora = None
        if wpath.exists() and npath.exists():
            a, b = Image.open(wpath).convert("RGB"), Image.open(npath).convert("RGB")
            diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
            flora = diff.resize((gw, gh), Image.BOX).point(lambda v: 255 if v > 100 else 0)
        img = Image.new("RGB", (gw, gh))
        n = {"s": 0, "t": 0, "g": 0, "f": 0}
        for j, row in enumerate(rows[:gh]):
            for i, c in enumerate(row[:gw]):
                k = c
                if flora is not None and flora.getpixel((i, j)) > 0 and c != "s":
                    k = "f"
                elif flora is not None and flora.getpixel((i, j)) > 0:
                    k = "f"
                n[k] += 1
                img.putpixel((i, j), COL[k])
        tot = gw * gh
        big = img.resize((960, 540), Image.NEAREST)
        if wpath.exists():
            pic = Image.open(wpath).convert("RGB").resize((960, 540))
            out = Image.new("RGB", (1920, 540))
            out.paste(pic, (0, 0))
            out.paste(big, (960, 0))
        else:
            out = big
        out.save(d / f"coverage_{scene}.png")
        print(f"{scene}: sky {100*n['s']/tot:.0f}%  terrain {100*n['t']/tot:.0f}%  flora {100*n['f']/tot:.0f}%  geometry {100*n['g']/tot:.0f}%")


if __name__ == "__main__":
    main(sys.argv[1])
