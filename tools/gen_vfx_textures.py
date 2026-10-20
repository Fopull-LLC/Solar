#!/usr/bin/env python3
"""python3 tools/gen_vfx_textures.py — build Solar's curated VFX texture set into textures/vfx/.

Sources: the packs in textures/VFXTEX (Kenney smoke CC0, hackcraft flare CC0,
"masks for particles"), the Floptle-jam-release VFXTEX set, and procedural
textures generated here (numpy). Every output is RGBA so it works for both
Alpha and Additive tracks (straight alpha; RGB is the shading, A the coverage).
"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter

SOLAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(SOLAR, "textures/vfx")
UNZ = os.environ.get("VFX_PACKS", "/tmp/vfx_packs")  # the three textures/VFXTEX/*.zip packs, each unzipped into a folder named after it
KEN = UNZ + "/smokeParticleAssets/PNG"
MASK = UNZ + "/masks_for_particles/masks for  particles"
FLARE = UNZ + "/flare_20120324/flare"
JAM = "/mnt/disks/3tb/GithubRepositories/Floptle-jam-release/assets/textures/VFXTEX"
OLD = SOLAR + "/textures/VFXTEX"

rng = np.random.default_rng(7)


def save(img, rel, size=None):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if size:
        img = img.resize((size, size) if isinstance(size, int) else size, Image.LANCZOS)
    img.save(p, optimize=True)
    print("wrote", rel, img.size)


def square(img):
    w, h = img.size
    s = max(w, h)
    c = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    c.paste(img, ((s - w) // 2, (s - h) // 2))
    return c


def lum_to_alpha(path, gamma=1.0, white=True, gain=1.0):
    """RGB-on-black (or greyscale) -> white RGB, alpha = luminance."""
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.float32) / 255.0
    l = a.max(axis=2)
    l = np.clip(l * gain, 0, 1) ** gamma
    out = np.zeros(a.shape[:2] + (4,), np.float32)
    if white:
        out[..., :3] = 1.0
    else:
        out[..., :3] = np.clip(a / np.maximum(l[..., None], 1e-3), 0, 1)
    out[..., 3] = l
    return Image.fromarray((out * 255).astype(np.uint8), "RGBA")


def keep_rgba(path):
    return square(Image.open(path).convert("RGBA"))


def kenney_puff(path):
    """Kenney puffs are white with grey self-shadow. Keep the shading as RGB."""
    im = square(Image.open(path).convert("RGBA"))
    return im


# ---- procedural helpers ---------------------------------------------------
def grid(n):
    y, x = np.mgrid[0:n, 0:n].astype(np.float32)
    x = (x + 0.5) / n * 2 - 1
    y = (y + 0.5) / n * 2 - 1
    return x, y


def value_noise(n, freq, seed):
    r = np.random.default_rng(seed)
    g = r.random((freq + 1, freq + 1)).astype(np.float32)
    g[-1, :] = g[0, :]
    g[:, -1] = g[:, 0]
    img = Image.fromarray((g * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)
    return np.asarray(img).astype(np.float32) / 255.0


def fbm(n, seed, octaves=6, base=4):
    acc = np.zeros((n, n), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        acc += value_noise(n, base * 2 ** o, seed + o) * amp
        tot += amp
        amp *= 0.55
    return acc / tot


def to_img(rgb, a):
    out = np.dstack([np.clip(rgb, 0, 1) if rgb.ndim == 3 else np.repeat(np.clip(rgb, 0, 1)[..., None], 3, 2),
                     np.clip(a, 0, 1)])
    return Image.fromarray((out * 255).astype(np.uint8), "RGBA")


def soft_glow(n=128, power=2.2):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.clip(1 - r, 0, 1) ** power
    return to_img(np.ones_like(a), a)


def hot_core(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-r * r * 18) + 0.35 * np.clip(1 - r, 0, 1) ** 3
    return to_img(np.ones_like(a), np.clip(a, 0, 1))


def spark_dot(n=64):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-r * r * 30) + 0.25 * np.exp(-r * r * 6)
    return to_img(np.ones_like(a), np.clip(a, 0, 1))


def streak(n=128):
    """A spark streak: long in V (height), thin in U, hot head."""
    x, y = grid(n)
    across = np.exp(-(x * 9) ** 2)
    along = np.clip(1 - np.abs(y), 0, 1) ** 0.8
    a = across * along
    return to_img(np.ones_like(a), np.clip(a * 1.2, 0, 1))


def beam_profile(n=128, sharp=14.0, halo=0.35):
    """Beam ribbons: u runs across the width, v along the beam."""
    x, _ = grid(n)
    a = np.exp(-(x * x) * sharp) + halo * np.exp(-(x * x) * 3.0)
    a = a / a.max()
    a = np.repeat(a[:1, :], n, axis=0) if False else a
    return to_img(np.ones_like(a), a)


def beam_noise(n=256, seed=3):
    """Shimmering heat/plasma texture for a scrolling beam layer."""
    x, y = grid(n)
    nz = fbm(n, seed, 5, 3)
    # stretch along v: sample columns of noise
    nz = np.asarray(Image.fromarray((nz * 255).astype(np.uint8)).resize((n, n // 8)).resize((n, n), Image.BICUBIC)).astype(np.float32) / 255
    prof = np.exp(-(x * x) * 5.0)
    a = prof * (0.35 + 0.9 * (nz - 0.3)).clip(0, 1)
    return to_img(np.ones_like(a), a)


def smoke_puff(n=256, seed=1, holes=0.55):
    """A soft, cauliflower-edged smoke puff with self-shadowed shading."""
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    nz = fbm(n, seed, 6, 3)
    edge = 0.62 + 0.38 * (nz - 0.5) * 2.0
    cover = np.clip((edge - r) / 0.28, 0, 1)
    detail = fbm(n, seed + 50, 5, 6)
    a = cover * np.clip(holes + (1 - holes) * detail * 1.6, 0, 1)
    a = a ** 1.2
    # lit from the top-left: darker toward the bottom-right, plus detail
    shade = 0.78 + 0.22 * (-(x + y) * 0.5) + 0.25 * (detail - 0.5)
    shade = np.clip(shade, 0.45, 1.0)
    return to_img(shade, a)


def dust_ring(n=256, seed=9):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    nz = fbm(n, seed, 6, 6)
    ring = np.exp(-((r - 0.72) / 0.16) ** 2)
    inner = np.clip(r / 0.72, 0, 1) ** 2 * 0.35
    a = (ring + inner * (r < 0.72)) * np.clip(0.3 + nz * 1.2, 0, 1)
    a *= np.clip((1 - r) / 0.1, 0, 1)
    return to_img(np.ones_like(a), np.clip(a, 0, 1))


def shock_ring(n=256):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-((r - 0.82) / 0.06) ** 2) + 0.25 * np.exp(-((r - 0.75) / 0.18) ** 2)
    a *= np.clip((1 - r) / 0.05, 0, 1)
    return to_img(np.ones_like(a), np.clip(a, 0, 1))


def scorch(n=256, seed=21):
    """Burn mark decal: charred black core, brown singe, ragged rim."""
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    nz = fbm(n, seed, 6, 4)
    fine = fbm(n, seed + 9, 5, 16)
    rr = r + (nz - 0.5) * 0.45
    a = np.clip((0.9 - rr) / 0.45, 0, 1) ** 1.3
    a *= np.clip(0.55 + fine * 0.8, 0, 1)
    # radial streaks
    ang = np.arctan2(y, x)
    streaks = 0.5 + 0.5 * np.sin(ang * 23 + nz * 9)
    a = np.clip(a * (0.8 + 0.25 * streaks), 0, 1)
    c = np.clip(rr / 0.9, 0, 1)
    rgb = np.dstack([0.05 + 0.20 * c, 0.04 + 0.13 * c, 0.03 + 0.08 * c])
    rgb *= (0.7 + 0.5 * fine)[..., None]
    return to_img(rgb, a * 0.95)


def glow_decal(n=128, seed=5):
    """Molten glow spot for laser hit (additive-looking but used as decal tint)."""
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    nz = fbm(n, seed, 5, 5)
    a = np.clip((0.75 - r - (nz - 0.5) * 0.3) / 0.5, 0, 1) ** 1.5
    return to_img(np.ones_like(a), a)


def droplet(n=64):
    x, y = grid(n)
    # elongated drop: round head at top (v small)
    a = np.exp(-((x * 4.0) ** 2) - ((y + 0.2) * 1.4) ** 2 * 2)
    a = np.clip(a * 1.4, 0, 1)
    shade = 0.75 + 0.25 * np.clip(-x - y, -1, 1)
    return to_img(shade, a)


def grit(n=128, seed=33, count=14):
    """A handful of tiny dark specks — fine debris kicked up."""
    r = np.random.default_rng(seed)
    a = np.zeros((n, n), np.float32)
    shade = np.zeros((n, n), np.float32)
    yy, xx = np.mgrid[0:n, 0:n]
    for _ in range(count):
        cx, cy = r.uniform(0.15, 0.85, 2) * n
        rad = r.uniform(1.5, 4.5)
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        blob = np.clip((rad - d) / 1.2, 0, 1)
        a = np.maximum(a, blob)
        shade = np.maximum(shade, blob * r.uniform(0.5, 1.0))
    return to_img(shade, a)


def chip(n=64, seed=41):
    """A single angular rock chip, shaded."""
    r = np.random.default_rng(seed)
    k = r.integers(5, 8)
    ang = np.sort(r.uniform(0, 2 * np.pi, k))
    rad = r.uniform(0.55, 0.95, k)
    pts = [(n / 2 + np.cos(a) * rr * n * 0.45, n / 2 + np.sin(a) * rr * n * 0.45) for a, rr in zip(ang, rad)]
    from PIL import ImageDraw
    m = Image.new("L", (n * 4, n * 4), 0)
    ImageDraw.Draw(m).polygon([(px * 4, py * 4) for px, py in pts], fill=255)
    m = m.resize((n, n), Image.LANCZOS)
    a = np.asarray(m).astype(np.float32) / 255
    x, y = grid(n)
    shade = np.clip(0.75 + 0.35 * (-x - y) * 0.6 + (fbm(n, seed, 3, 4) - 0.5) * 0.4, 0.35, 1)
    return to_img(shade, a)


def bubble(n=64):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    rim = np.exp(-((r - 0.8) / 0.09) ** 2)
    spec = np.exp(-(((x + 0.35) / 0.18) ** 2 + ((y + 0.35) / 0.12) ** 2))
    a = np.clip(rim * 0.85 + 0.12 * (r < 0.8) + spec, 0, 1) * (r < 0.95)
    return to_img(np.ones_like(a), a)


def heat_haze(n=128, seed=61):
    """Barely-there wavy streak used for heat shimmer (no distortion pass)."""
    x, y = grid(n)
    nz = fbm(n, seed, 4, 3)
    a = np.clip(1 - np.sqrt(x * x + y * y), 0, 1) ** 2 * (0.5 + 0.5 * np.sin((y + nz) * 18))
    return to_img(np.ones_like(a), np.clip(a * 0.6, 0, 1))


def flame_tongue(n=128, seed=71):
    """A soft upward flame tongue for exhaust plumes (v = along the plume)."""
    x, y = grid(n)
    nz = fbm(n, seed, 5, 4)
    w = 0.35 + 0.35 * (1 - (y + 1) / 2)  # wider at the bottom
    a = np.exp(-(x / np.maximum(w, 0.05)) ** 2 * 2.5) * np.clip(1 - np.abs(y) ** 2, 0, 1)
    a *= np.clip(0.55 + nz * 0.9, 0, 1)
    return to_img(np.ones_like(a), np.clip(a, 0, 1))


def main():
    # ---- smoke
    save(kenney_puff(KEN + "/White puff/whitePuff03.png"), "smoke/puff_a.png", 256)
    save(kenney_puff(KEN + "/White puff/whitePuff10.png"), "smoke/puff_b.png", 256)
    save(kenney_puff(KEN + "/White puff/whitePuff17.png"), "smoke/puff_c.png", 256)
    save(kenney_puff(KEN + "/Black smoke/blackSmoke08.png"), "smoke/soot.png", 256)
    save(smoke_puff(256, 11), "smoke/billow_a.png")
    save(smoke_puff(256, 23, 0.4), "smoke/billow_b.png")
    save(lum_to_alpha(MASK + "/42.png", 1.1), "smoke/clump_a.png", 256)
    save(lum_to_alpha(MASK + "/43.png", 1.1), "smoke/clump_b.png", 256)
    save(lum_to_alpha(MASK + "/50.png", 1.0, gain=1.4), "smoke/soft.png", 128)
    save(lum_to_alpha(JAM + "/Fire/4.png", 1.0), "smoke/wisp.png", 256)
    # ---- fire
    save(lum_to_alpha(OLD + "/Fire/3.png", 1.0), "fire/fireball_a.png", 256)
    save(lum_to_alpha(OLD + "/Fire/5.png", 1.0), "fire/fireball_b.png", 256)
    save(lum_to_alpha(JAM + "/Fire/7.png", 1.0), "fire/fireball_c.png", 256)
    save(flame_tongue(), "fire/tongue.png")
    # ---- glows / flashes
    save(soft_glow(128, 2.2), "glow/soft.png")
    save(soft_glow(128, 5.0), "glow/tight.png")
    save(hot_core(128), "glow/core.png")
    save(lum_to_alpha(MASK + "/10.png", 1.0), "glow/flash.png", 256)
    save(lum_to_alpha(MASK + "/34.png", 1.0), "glow/star.png", 256)
    save(lum_to_alpha(MASK + "/8.png", 1.0), "glow/streak.png", 256)
    save(lum_to_alpha(FLARE + "/aura.png", 1.0), "glow/aura.png", 128)
    save(heat_haze(), "glow/haze.png")
    # ---- sparks / debris
    save(spark_dot(), "spark/dot.png")
    save(streak(), "spark/streak.png")
    save(lum_to_alpha(MASK + "/13.png", 1.0, gain=1.5), "spark/burst.png", 256)
    save(grit(), "debris/grit.png")
    save(chip(64, 41), "debris/chip_a.png")
    save(chip(64, 52), "debris/chip_b.png")
    save(lum_to_alpha(MASK + "/25.png", 1.0), "debris/spray.png", 256)
    # ---- rings
    save(dust_ring(), "ring/dust.png")
    save(lum_to_alpha(MASK + "/30.png", 1.0), "ring/smoke.png", 256)
    save(shock_ring(), "ring/shock.png")
    # ---- beam
    save(beam_profile(128, 40.0, 0.0), "beam/core.png")
    save(beam_profile(128, 6.0, 0.4), "beam/glow.png")
    save(beam_noise(), "beam/shimmer.png")
    # ---- water
    save(lum_to_alpha(JAM + "/Water/2.png", 1.0), "water/splat_a.png", 256)
    save(lum_to_alpha(JAM + "/Water/4.png", 1.0), "water/splat_b.png", 256)
    save(lum_to_alpha(JAM + "/Water/8.png", 1.0), "water/foam.png", 256)
    save(droplet(), "water/droplet.png")
    save(bubble(), "water/bubble.png")
    # ---- foliage
    save(lum_to_alpha(JAM + "/Wind/5.png", 1.0, white=False), "leaf/leaf.png", 128)
    # ---- decals
    save(scorch(256, 21), "decal/scorch.png")
    save(scorch(256, 37), "decal/scorch_b.png")
    save(glow_decal(), "decal/molten.png")
    save(keep_rgba(JAM + "/Debris/16.png"), "decal/crater.png", 256)


if __name__ == "__main__":
    main()
