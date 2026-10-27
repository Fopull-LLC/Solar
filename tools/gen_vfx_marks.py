#!/usr/bin/env python3
"""python3 tools/gen_vfx_marks.py — the ground marks vehicle_fx.lua lays:
procedural (numpy), straight-alpha RGBA, written into textures/vfx/decal/.

  tyre_track.png   a tread print pressed into loose ground (regolith, sand):
                   the tread's blocks as darker, compacted cells
  skid.png         black rubber laid by a sliding tyre: streaks along the
                   slide from the tread grooves, ragged soft edges
  scuff.png        a hull dragged over the ground: parallel gouges with a
                   bright metal smear in their bottoms

Every mark runs ALONG v (the texture's height = the decal's `height`, laid
along the direction of travel) and ACROSS u (its width = `size`). The ends
fade so consecutive segments overlap without a seam.
"""
import os
import numpy as np
from PIL import Image

SOLAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(SOLAR, "textures/vfx/decal")
rng = np.random.default_rng(1969)


def noise1(n, freq, seed):
    r = np.random.default_rng(seed)
    k = r.random(freq + 2)
    x = np.linspace(0, freq, n, endpoint=False)
    i = x.astype(int)
    f = x - i
    f = f * f * (3 - 2 * f)
    return k[i] * (1 - f) + k[i + 1] * f


def value2(w, h, fx, fy, seed):
    r = np.random.default_rng(seed)
    g = r.random((fy + 2, fx + 2))
    y = np.linspace(0, fy, h, endpoint=False)[:, None]
    x = np.linspace(0, fx, w, endpoint=False)[None, :]
    iy, ix = y.astype(int), x.astype(int)
    ty, tx = y - iy, x - ix
    ty, tx = ty * ty * (3 - 2 * ty), tx * tx * (3 - 2 * tx)
    a = g[iy, ix] * (1 - tx) + g[iy, ix + 1] * tx
    b = g[iy + 1, ix] * (1 - tx) + g[iy + 1, ix + 1] * tx
    return a * (1 - ty) + b * ty


def fbm2(w, h, f, seed, oct=4):
    s, a, t = 0, 1.0, 0
    for o in range(oct):
        s = s + a * value2(w, h, f * 2 ** o, f * 2 ** o * h // w + 1, seed + o)
        t += a
        a *= 0.5
    return s / t


def save(rgb, a, name):
    os.makedirs(OUT, exist_ok=True)
    img = np.dstack([np.clip(rgb, 0, 1), np.clip(a, 0, 1)])
    Image.fromarray((img * 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, name), optimize=True)
    print("wrote", name, img.shape[1], "x", img.shape[0])


def end_fade(h, w, k=0.12):
    v = np.linspace(0, 1, h)[:, None] * np.ones((1, w))
    return np.clip(v / k, 0, 1) * np.clip((1 - v) / k, 0, 1)


def tyre_track(w=64, h=256):
    u = np.linspace(-1, 1, w)[None, :] * np.ones((h, 1))
    v = np.linspace(0, 6, h)[:, None] * np.ones((1, w))    # six tread pitches a segment
    warp = (fbm2(w, h, 8, 3) - 0.5) * 0.35
    # chevron blocks: a V across the tyre, repeating along it, crumbled by
    # the grains (a print in powder is never crisp)
    chev = (v + np.abs(u) * 0.45 + warp) % 1.0
    block = np.clip((0.5 - np.abs(chev - 0.3)) * 6.0, 0, 1)
    grain = fbm2(w, h, 14, 7)
    block = np.clip(block * (0.55 + 0.6 * grain), 0, 1)
    edge = np.clip((1 - np.abs(u)) / 0.3, 0, 1) ** 1.3
    a = (0.22 + 0.22 * block) * edge * (0.65 + 0.5 * grain) * end_fade(h, w, 0.08)
    # compacted ground reads darker; the walls between blocks a touch lighter
    shade = 0.32 + 0.12 * (1 - block) + 0.08 * grain
    rgb = np.dstack([shade, shade * 0.95, shade * 0.9])
    save(rgb, a * 0.85, "tyre_track.png")


def skid(w=64, h=256):
    u = np.linspace(-1, 1, w)
    # tread grooves: lighter lines along the slide
    grooves = 0.5 + 0.5 * np.cos(u * np.pi * 5.0)
    streak = noise1(w, 22, 11) * 0.6 + noise1(w, 7, 12) * 0.4
    across = np.clip((1 - np.abs(u)) / 0.25, 0, 1) ** 0.8
    base = (0.55 + 0.45 * streak) * (0.72 + 0.28 * grooves) * across
    along = 0.65 + 0.35 * fbm2(w, h, 3, 21)
    a = base[None, :] * along * end_fade(h, w, 0.1)
    rgb = np.ones((h, w, 3)) * 0.035
    rgb += (1 - grooves[None, :, None]) * 0.015
    save(rgb, a * 0.9, "skid.png")


def scuff(w=128, h=256):
    u = np.linspace(-1, 1, w)
    lines = np.zeros(w)
    for _ in range(14):
        c = rng.uniform(-0.8, 0.8)
        wd = rng.uniform(0.01, 0.05)
        lines = np.maximum(lines, rng.uniform(0.4, 1.0) * np.exp(-((u - c) / wd) ** 2))
    across = np.clip((1 - np.abs(u)) / 0.3, 0, 1)
    along = fbm2(w, h, 4, 31)
    # the gouges thin out and break up along their length
    a = (0.25 * across[None, :] + 0.75 * lines[None, :] * np.clip(along * 1.6 - 0.2, 0, 1)) * end_fade(h, w, 0.15)
    rgb = np.ones((h, w, 3)) * 0.07
    # bare-metal smear at the bottom of the deepest gouges
    shine = (lines[None, :] > 0.85) * (along > 0.5)
    rgb = rgb + shine[..., None] * np.array([0.38, 0.37, 0.36])
    save(rgb, np.clip(a, 0, 0.92), "scuff.png")


def main():
    tyre_track()
    skid()
    scuff()


if __name__ == "__main__":
    main()
