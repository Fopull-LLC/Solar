#!/usr/bin/env python3
"""Grid the raw RGBA dumps of emblem_sheet.lua into one PNG: emblem_sheet.py DIR OUT.png"""
import glob, os, sys
from PIL import Image
d, outp = sys.argv[1], sys.argv[2]
es = sorted(glob.glob(os.path.join(d, "e*.rgba")), key=lambda p: int(os.path.basename(p)[1:-5]))
fl = sorted(glob.glob(os.path.join(d, "flag*.rgba")))
cols = 4
rows = (len(es) + cols - 1) // cols
W = cols * 272 + 16
H = rows * 272 + 16 + (360 if fl else 0)
sheet = Image.new("RGB", (W, H), (58, 60, 56))
for i, p in enumerate(es):
    im = Image.frombytes("RGBA", (256, 256), open(p, "rb").read())
    sheet.paste(im, (16 + (i % cols) * 272, 16 + (i // cols) * 272), im)
for j, p in enumerate(fl):
    im = Image.frombytes("RGBA", (512, 341), open(p, "rb").read())
    sheet.paste(im, (16 + j * 540, 16 + rows * 272), im)
sheet.save(outp)
