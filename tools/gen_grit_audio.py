#!/usr/bin/env python3
"""Synthesize the gritty-realism pass's sounds (2026-11-10): the Terrain
Laser's bite, the cave, and the suit you breathe in.

Made from numbers like tools/gen_soundscape_audio.py (whose building blocks
this borrows): noise shaped in the frequency domain, impulse trains, decaying
resonators, a convolution reverb. Deterministic (fixed seeds), the project's
own licence, numpy + ffmpeg only.

    audio/foley/laser_hiss.ogg      12 s loop: the cut's steady hiss (vapour jetting off the bite)
    audio/foley/laser_crackle.ogg   12 s loop: molten rock spitting, sparks, spalling grit
    audio/foley/laser_rumble.ogg    12 s loop: the rock taking it, felt through the boots
    audio/ambience/cave_tone.ogg    30 s loop: a cave's room tone, low and close
    audio/ambience/cave_drip_1..4   a drop falling into a pool, in the cave's reverb
    audio/ambience/cave_creak_1..3  rock settling: a stick-slip creak through stone
    audio/ambience/cave_groan_1..2  a deep, far groan of the mountain, and a trickle of grit
    audio/sfx/breath_calm.ogg       ~7.6 s loop: two easy breaths inside a helmet
    audio/sfx/breath_heavy.ogg      ~4.4 s loop: three hard breaths (running, climbing)
    audio/sfx/suit_hum.ogg          10 s loop: the suit's fan and regulator

Nobody should audition these through speakers to check them: `--stats` prints
duration, peak, RMS, approximate loudness, centroid and the loop seam.

    python3 tools/gen_grit_audio.py            # write everything
    python3 tools/gen_grit_audio.py --stats    # just measure what is on disk
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_soundscape_audio import (SR, ROOT, shaped_noise, band_noise, loop_lfo, lowpass_fft, reverb, pan,  # noqa: E402
                                  fade, level, write_ogg, stats)


def highpass_fft(x, hz, order=2):
    spec = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(x.shape[0], 1 / SR)
    f[0] = 1e-3
    g = 1 / np.sqrt(1 + (hz / f) ** (2 * order))
    if x.ndim == 2:
        g = g[:, None]
    return np.fft.irfft(spec * g, x.shape[0], axis=0)


def resonate(x, freqs, q=12.0):
    """A bank of resonances (stone, a helmet's shell) laid over x, in the frequency domain."""
    spec = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(x.shape[0], 1 / SR)
    g = np.zeros_like(f)
    for c, amp in freqs:
        bw = c / q
        g += amp / (1 + ((f - c) / (bw / 2)) ** 2)
    if x.ndim == 2:
        g = g[:, None]
    return np.fft.irfft(spec * g, x.shape[0], axis=0)


def circ_add(dst, src, at):
    """Add src into dst starting at `at`, wrapping round the end (loop-safe)."""
    n = dst.shape[0]
    idx = (np.arange(src.shape[0]) + at) % n
    np.add.at(dst, idx, src)


# ── the laser ───────────────────────────────────────────────────────────────

def laser_hiss(seconds=12.0, seed=1101):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        body = shaped_noise(n, rng, 1400, 9500, tilt=-0.4)
        # the jet flutters: a few whole-cycle wobbles, never a pulse
        g = 0.82 + 0.08 * loop_lfo(n, 23, rng.uniform(0, 6)) + 0.06 * loop_lfo(n, 37, rng.uniform(0, 6)) \
            + 0.04 * loop_lfo(n, 59, rng.uniform(0, 6))
        roar = shaped_noise(n, rng, 180, 1400, tilt=-1.2) * 0.35
        out.append(body * g + roar)
    return level(np.stack(out, axis=1), lufs=-24.0, peak_db=-4.0)


def crackle_events(n, rng, rate, amp_lo, amp_hi, dec_lo, dec_hi, lo, hi):
    x = np.zeros(n)
    k = rng.poisson(rate * n / SR)
    for _ in range(k):
        at = rng.integers(0, n)
        d = rng.uniform(dec_lo, dec_hi)
        m = int(d * SR * 6)
        t = np.arange(m) / SR
        e = np.exp(-t / d) * rng.uniform(amp_lo, amp_hi) ** 2
        click = rng.standard_normal(m) * e
        circ_add(x, click, at)
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    f[0] = 1.0
    g = 1 / (1 + (lo / f) ** 4) / (1 + (f / hi) ** 4)
    return np.fft.irfft(spec * g, n)


def laser_crackle(seconds=12.0, seed=1102):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        fine = crackle_events(n, rng, 140, 0.2, 1.0, 0.0004, 0.0016, 1500, 9000)    # the sizzle
        pops = crackle_events(n, rng, 9, 0.5, 1.0, 0.002, 0.007, 300, 4500) * 1.6   # spitting slag
        grit = crackle_events(n, rng, 30, 0.2, 0.7, 0.001, 0.004, 600, 6000) * 0.7  # spalled grit on rock
        out.append(fine + pops + grit)
    return level(np.stack(out, axis=1), lufs=-25.0, peak_db=-3.0)


def laser_rumble(seconds=12.0, seed=1103):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        low = shaped_noise(n, rng, 22, 160, tilt=-2.0)
        low *= 0.7 + 0.2 * loop_lfo(n, 5, rng.uniform(0, 6)) + 0.1 * loop_lfo(n, 13, rng.uniform(0, 6))
        grind = shaped_noise(n, rng, 260, 900, tilt=-1.0) * 0.25
        grind *= loop_lfo(n, 17, rng.uniform(0, 6)) ** 2
        out.append(low + grind)
    return level(np.stack(out, axis=1), lufs=-26.0, peak_db=-3.0)


# ── the cave ────────────────────────────────────────────────────────────────

def cave_tone(seconds=30.0, seed=1201):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        hum = shaped_noise(n, rng, 18, 140, tilt=-2.4)
        hum = hum * (0.75 + 0.25 * loop_lfo(n, 2, rng.uniform(0, 6)))
        # a standing mode of the chamber, faint and slowly breathing
        mode = band_noise(n, rng, 64 * rng.uniform(0.97, 1.03), 18) * 0.35 * loop_lfo(n, 3, rng.uniform(0, 6))
        air = shaped_noise(n, rng, 300, 2200, tilt=-1.6) * 0.06 * loop_lfo(n, 4, rng.uniform(0, 6))
        out.append(hum + mode + air)
    return level(np.stack(out, axis=1), lufs=-31.0, peak_db=-8.0)


def cave_drip(seed):
    rng = np.random.default_rng(seed)
    n = int(0.25 * SR)
    t = np.arange(n) / SR
    # a drop into a pool: a rising "plink" (the bubble's resonance) and a tick
    f0 = rng.uniform(900, 1500)
    f1 = f0 * rng.uniform(1.6, 2.4)
    d = rng.uniform(0.018, 0.04)
    sweep = f0 + (f1 - f0) * np.clip(t / d, 0, 1)
    ph = 2 * np.pi * np.cumsum(sweep) / SR
    plink = np.sin(ph) * np.exp(-t / (d * 1.4))
    tick = rng.standard_normal(n) * np.exp(-t / 0.0015) * 0.35
    x = plink + highpass_fft(tick, 2500)
    x = fade(x, 0.0005, 0.05)
    p = pan(x, rng.uniform(-0.6, 0.6))
    w = reverb(p, seconds=2.4, mix=0.55, seed=seed, damp_hz=3200.0)
    return level(w, lufs=-25.0, peak_db=-6.0)


def cave_creak(seed):
    rng = np.random.default_rng(seed)
    secs = rng.uniform(1.4, 2.4)
    n = int(secs * SR)
    t = np.arange(n) / SR
    # stick-slip: an impulse train whose rate wanders (rock grinding on rock)
    x = np.zeros(n)
    pos = 0.0
    while pos < secs - 0.05:
        rate = 9 + 26 * (0.5 + 0.5 * np.sin(pos * rng.uniform(2, 5) + seed)) * rng.uniform(0.6, 1.2)
        i = int(pos * SR)
        m = int(0.012 * SR)
        x[i:i + m] += rng.standard_normal(min(m, n - i)) * np.exp(-np.arange(min(m, n - i)) / SR / 0.002)
        pos += 1.0 / rate
    e = np.sin(np.pi * np.clip(t / secs, 0, 1)) ** 1.5
    x = resonate(x * e, [(170 * rng.uniform(0.9, 1.1), 1.0), (410 * rng.uniform(0.9, 1.1), 0.6),
                         (880 * rng.uniform(0.9, 1.1), 0.25)], q=9)
    x = lowpass_fft(x, 2200)
    p = pan(x, rng.uniform(-0.9, 0.9))
    w = reverb(p, seconds=3.4, mix=0.6, seed=seed, damp_hz=1800.0)
    return level(w, lufs=-27.0, peak_db=-5.0)


def cave_groan(seed):
    rng = np.random.default_rng(seed)
    secs = rng.uniform(3.2, 4.4)
    n = int(secs * SR)
    t = np.arange(n) / SR
    f = 38 * rng.uniform(0.85, 1.15) * (1 + 0.18 * np.sin(2 * np.pi * t / secs * rng.uniform(0.6, 1.1)))
    ph = 2 * np.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.4 * np.sin(2 * ph + 0.7) + 0.15 * np.sin(3 * ph + 1.3)
    rumble = shaped_noise(n, rng, 20, 120, tilt=-2.0) * 0.8
    e = np.sin(np.pi * np.clip(t / secs, 0, 1)) ** 2
    x = (tone * 0.6 + rumble) * e
    # a trickle of grit at the end, from somewhere up in the roof
    for _ in range(int(rng.integers(5, 12))):
        at = int(rng.uniform(0.55, 0.95) * n)
        m = int(0.01 * SR)
        k = rng.standard_normal(m) * np.exp(-np.arange(m) / SR / 0.0018) * rng.uniform(0.05, 0.25)
        circ_add(x, highpass_fft(k, 1200), at)
    p = pan(lowpass_fft(x, 1600), rng.uniform(-0.8, 0.8))
    w = reverb(p, seconds=4.5, mix=0.65, seed=seed, damp_hz=1200.0)
    return level(w, lufs=-26.0, peak_db=-4.0)


# ── the suit ────────────────────────────────────────────────────────────────

def breath_cycle(rng, n_in, n_out, gap, hard):
    """One breath: an inhale and an exhale of shaped noise, mouth-and-nose
    formants, inside the helmet (its shell rings faintly)."""
    def puff(m, lo, hi, centre, q, shape_pow):
        x = shaped_noise(m, rng, lo, hi, tilt=-1.2) * 0.6 + band_noise(m, rng, centre, q) * 0.4
        t = np.linspace(0, 1, m)
        e = np.sin(np.pi * t) ** shape_pow
        return x * e
    a = puff(n_in, 350, 4200, 1300 if not hard else 1050, 2.5, 1.2) * (0.55 if not hard else 0.9)
    b = puff(n_out, 200, 3000, 780 if not hard else 640, 2.2, 0.9) * (0.75 if not hard else 1.0)
    return np.concatenate([a, np.zeros(int(0.08 * SR)), b, np.zeros(gap)])


def breath(hard, seed):
    rng = np.random.default_rng(seed)
    cyc = []
    count = 3 if hard else 2
    for _ in range(count):
        if hard:
            cyc.append(breath_cycle(rng, int(rng.uniform(0.5, 0.62) * SR), int(rng.uniform(0.6, 0.72) * SR),
                                    int(rng.uniform(0.12, 0.2) * SR), True))
        else:
            cyc.append(breath_cycle(rng, int(rng.uniform(1.2, 1.4) * SR), int(rng.uniform(1.5, 1.8) * SR),
                                    int(rng.uniform(0.55, 0.8) * SR), False))
    x = np.concatenate(cyc)
    # the helmet: close resonances and a very short, bright reflection off the visor
    x = resonate(x, [(900, 0.6), (1850, 0.5), (2900, 0.3), (420, 0.4)], q=4) + x * 0.6
    d = int(0.0021 * SR)
    x[d:] += x[:-d] * 0.35
    st = np.stack([x, x * 0.96], axis=1)
    return level(st, lufs=-27.0 if hard else -30.0, peak_db=-6.0)


def suit_hum(seconds=10.0, seed=1301):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = []
    for ch in range(2):
        f0 = 118.0   # whole cycles over the loop: 1180 in 10 s
        tone = 0.5 * np.sin(2 * np.pi * f0 * t) + 0.25 * np.sin(2 * np.pi * 2 * f0 * t + 0.4) \
            + 0.12 * np.sin(2 * np.pi * 3 * f0 * t + 1.1)
        fan = shaped_noise(n, rng, 160, 1800, tilt=-1.4) * 0.8
        fan *= 0.92 + 0.08 * loop_lfo(n, 7, rng.uniform(0, 6))
        hiss = shaped_noise(n, rng, 2500, 8000, tilt=-0.5) * 0.12
        out.append(tone * 0.35 + fan + hiss)
    return level(np.stack(out, axis=1), lufs=-34.0, peak_db=-12.0)


FILES = {
    "foley/laser_hiss.ogg": laser_hiss,
    "foley/laser_crackle.ogg": laser_crackle,
    "foley/laser_rumble.ogg": laser_rumble,
    "ambience/cave_tone.ogg": cave_tone,
    **{f"ambience/cave_drip_{i}.ogg": (lambda i=i: cave_drip(1210 + i)) for i in (1, 2, 3, 4)},
    **{f"ambience/cave_creak_{i}.ogg": (lambda i=i: cave_creak(1220 + i)) for i in (1, 2, 3)},
    **{f"ambience/cave_groan_{i}.ogg": (lambda i=i: cave_groan(1230 + i)) for i in (1, 2)},
    "sfx/breath_calm.ogg": lambda: breath(False, 1311),
    "sfx/breath_heavy.ogg": lambda: breath(True, 1312),
    "sfx/suit_hum.ogg": suit_hum,
}


def main():
    if "--stats" not in sys.argv:
        for rel, make in FILES.items():
            write_ogg(rel, make())
    for rel in FILES:
        stats(ROOT / rel)


if __name__ == "__main__":
    main()
