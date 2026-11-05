#!/usr/bin/env python3
"""The injury screen's two textures (scripts/injury_fx.lua).

  textures/ui/injury_vignette.png  white, its alpha a soft edge mask with an
                                   uneven, organic inner edge (no clean
                                   ellipse): tinted black for the darkening,
                                   red for blood loss, and the colour of
                                   whatever hit for the flash
  textures/ui/injury_blood.png     blood on the visor's rim: smears and drops
                                   crowding the edges and corners, a few runs
                                   down from the top, the middle clear

Deterministic (seeded); smooth, no pixel art (docs/ui-style.md, the
gritty-realistic look). Run from the repo root: python3 tools/gen_injury_textures.py
"""
import numpy as np
from PIL import Image, ImageFilter

W, H = 1024, 576
rng = np.random.default_rng(20261105)


def smooth_noise(w, h, cell, octaves=4, seed=0):
    """Value noise, bilinear-upsampled octaves summed to ~[-1, 1]."""
    r = np.random.default_rng(seed)
    out = np.zeros((h, w), np.float64)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        c = max(2, int(cell / (2 ** o)))
        gw, gh = w // c + 3, h // c + 3
        g = r.uniform(-1, 1, (gh, gw))
        img = Image.fromarray(((g + 1) * 127.5).astype(np.uint8)).resize((gw * c, gh * c), Image.BICUBIC)
        a = np.asarray(img, np.float64)[:h, :w] / 127.5 - 1
        out += a * amp
        total += amp
        amp *= 0.5
    return out / total


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
nx = (xs + 0.5) / W * 2 - 1          # -1..1 across
ny = (ys + 0.5) / H * 2 - 1
# distance from the middle in a frame that keeps the 16:9 screen's corners at ~1.35
d = np.sqrt((nx * 1.0) ** 2 + (ny * 1.0) ** 2)

# ── the vignette mask ─────────────────────────────────────────────────────────
n1 = smooth_noise(W, H, 160, 4, seed=1)
n2 = smooth_noise(W, H, 48, 3, seed=2)
edge = d + 0.10 * n1 + 0.02 * n2
a = smoothstep(0.62, 1.32, edge) ** 1.25
a = np.asarray(Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(9)), np.float64) / 255
vig = np.zeros((H, W, 4), np.uint8)
vig[..., 0:3] = 255
vig[..., 3] = np.clip(a * 255 + rng.uniform(-1.5, 1.5, a.shape), 0, 255).astype(np.uint8)
Image.fromarray(vig, "RGBA").save("textures/ui/injury_vignette.png", optimize=True)

# ── the blood ─────────────────────────────────────────────────────────────────
alpha = np.zeros((H, W), np.float64)
shade = np.zeros((H, W), np.float64)     # 0 fresh red .. 1 dark, dried


def blob(cx, cy, r, strength, dark, squash=1.0, ang=0.0, soft=0.82):
    """One drop or smear: a noisy-edged disc, crisp rim, darker at its edge."""
    ext = r * 1.3 * max(1.0, squash)
    x0, x1 = int(max(0, cx - ext)), int(min(W, cx + ext))
    y0, y1 = int(max(0, cy - ext)), int(min(H, cy + ext))
    if x1 <= x0 or y1 <= y0:
        return
    px = xs[y0:y1, x0:x1] - cx
    py = ys[y0:y1, x0:x1] - cy
    ca, sa = np.cos(ang), np.sin(ang)
    qx = (px * ca + py * sa) / squash
    qy = -px * sa + py * ca
    rr = np.sqrt(qx * qx + qy * qy) / r
    th = np.arctan2(qy, qx)
    k = rng.uniform(0, 6.283, 4)
    wob = 1 + 0.06 * np.sin(2 * th + k[0]) + 0.035 * np.sin(5 * th + k[1]) + 0.02 * np.sin(11 * th + k[2])
    m = smoothstep(1.0, soft, rr / wob)
    a_old = alpha[y0:y1, x0:x1]
    add = m * strength
    alpha[y0:y1, x0:x1] = a_old + add * (1 - a_old)
    rim = smoothstep(0.55, 0.95, rr / wob) * m
    s_old = shade[y0:y1, x0:x1]
    shade[y0:y1, x0:x1] = np.maximum(s_old, np.clip(dark + 0.45 * rim, 0, 1) * (add > 0.02))


# where the blood is likely: along the edges, most in the corners
def edge_weight(x, y):
    u, v = x / W * 2 - 1, y / H * 2 - 1
    return max(abs(u), abs(v)) ** 3 + 0.4 * (abs(u) * abs(v)) ** 2


# smears: long, soft, dark, laid along the edge (a glove's wipe)
for _ in range(16):
    for _t in range(200):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        if rng.uniform() < edge_weight(x, y) * 1.4:
            break
    tang = np.arctan2(y - H / 2, x - W / 2) + np.pi / 2 + rng.normal(0, 0.35)
    blob(x, y, rng.uniform(28, 60), rng.uniform(0.28, 0.5), rng.uniform(0.35, 0.7), rng.uniform(2.5, 5.0), tang, soft=0.35)
# drops: round, crisp-edged, darker at the rim
for _ in range(150):
    for _t in range(200):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        if rng.uniform() < edge_weight(x, y):
            break
    r = rng.uniform(5, 22) if rng.uniform() < 0.25 else rng.uniform(1.5, 6)
    blob(x, y, r, rng.uniform(0.7, 0.95), rng.uniform(0.0, 0.35), rng.uniform(0.85, 1.25), rng.uniform(0, 3.14), soft=0.9)
# sprays: fine mist thrown in from three points off the frame's edge
for cx, cy in ((-60, H * 0.82), (W + 50, H * 0.25), (W * 0.62, H + 60)):
    for _ in range(260):
        ang = np.arctan2(H / 2 - cy, W / 2 - cx) + rng.normal(0, 0.45)
        dist = abs(rng.normal(0, 210)) + 40
        x, y = cx + np.cos(ang) * dist, cy + np.sin(ang) * dist
        blob(x, y, rng.uniform(0.8, 3.2) * (1.3 - min(1.0, dist / 400)), rng.uniform(0.6, 0.95),
             rng.uniform(0.0, 0.3), rng.uniform(1.0, 2.2), ang, soft=0.9)

# runs down from the top edge: a narrow streak that thins, a bead at its end
for _ in range(5):
    x = rng.choice([rng.uniform(20, W * 0.3), rng.uniform(W * 0.7, W - 20)])
    length = rng.uniform(40, 150)
    wdt = rng.uniform(3.5, 7)
    y = 0.0
    steps = int(length / 2)
    for i in range(steps):
        t = i / steps
        x += rng.normal(0, 0.35)
        blob(x, y, wdt * (1 - 0.55 * t), 0.85, 0.15 + 0.3 * t)
        y += 2
    blob(x, y + wdt, wdt * 1.1, 0.9, 0.3)

# keep the middle clear, whatever was thrown there
alpha *= smoothstep(0.45, 0.85, d + 0.08 * n1)
grain = smooth_noise(W, H, 24, 2, seed=5)
fresh = np.stack([0.50, 0.035, 0.028])
dry = np.stack([0.20, 0.012, 0.012])
col = fresh[None, None, :] * (1 - shade[..., None]) + dry[None, None, :] * shade[..., None]
col *= (1 + 0.06 * grain[..., None])
blood = np.zeros((H, W, 4), np.uint8)
blood[..., 0:3] = np.clip(col * 255, 0, 255).astype(np.uint8)
blood[..., 3] = np.clip(alpha * 255 * (0.9 + 0.1 * grain), 0, 255).astype(np.uint8)
Image.fromarray(blood, "RGBA").save("textures/ui/injury_blood.png", optimize=True)
print("wrote textures/ui/injury_vignette.png, textures/ui/injury_blood.png")
