#!/usr/bin/env python3
"""Synthesize the weather's sounds (scripts/weather.lua, scripts/soundscape.lua).

Built the same way as tools/gen_soundscape_audio.py (whose building blocks this
borrows): noise shaped in the frequency domain, deterministic seeds, nothing
but numpy and ffmpeg. Loops are circular (made in the frequency domain, events
placed modulo the length), so they repeat without a seam.

    audio/weather/rain_light.ogg   30 s loop: a steady shower — a soft hiss and
                                   a scatter of drops on the ground near you
    audio/weather/rain_heavy.ogg   30 s loop: a downpour — denser, louder, a
                                   low roar of water everywhere
    audio/weather/hail.ogg         30 s loop: ice stones ticking and clacking
    audio/weather/dust.ogg         30 s loop: a dust storm — sand hissing past
                                   on a hard, gusting wind
    audio/weather/thunder_1..3.ogg a crack and the long roll after it; the
                                   game lowpasses and quietens them by distance

Nobody should audition these through speakers to check them: `--stats` prints
duration, sample peak, RMS, an approximate loudness and the spectral centroid.

    python3 tools/gen_weather_audio.py            # write everything
    python3 tools/gen_weather_audio.py --stats    # just measure what is on disk
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_soundscape_audio import (SR, ROOT, shaped_noise, loop_lfo, env, lowpass_fft, reverb,  # noqa: E402
                                  pan, fade, level, write_ogg, stats)


def scatter(n, rng, count, make, gain=(0.3, 1.0), width=0.9):
    """Place `count` short stereo events made by make(rng) at random points,
    wrapping round the end so the loop is seamless."""
    x = np.zeros((n, 2))
    for _ in range(count):
        e = make(rng) * rng.uniform(*gain)
        p = pan(e, rng.uniform(-width, width))
        at = rng.integers(0, n)
        idx = (np.arange(p.shape[0]) + at) % n
        x[idx] += p
    return x


def drop(rng, lo=900, hi=6000, dur=(0.004, 0.02)):
    """One raindrop on the ground: a tiny click of bright noise."""
    d = rng.uniform(*dur)
    m = int(d * 6 * SR)
    t = np.arange(m) / SR
    tick = rng.standard_normal(m) * np.exp(-t / d)
    return lowpass_fft(tick - lowpass_fft(tick, lo, 1), hi, 1)


def rain(seconds, seed, drops, hiss, roar, lufs):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    bed = []
    for ch in range(2):
        h = shaped_noise(n, rng, 500, 7000, tilt=-1.3) * hiss
        r = shaped_noise(n, rng, 80, 1400, tilt=-1.6) * roar
        sw = 0.8 + 0.2 * loop_lfo(n, 3, rng.uniform(0, 6))
        bed.append((h + r) * sw)
    x = np.stack(bed, axis=1)
    x += scatter(n, rng, drops, drop, gain=(0.15, 0.6)) * 0.5
    return level(x, lufs=lufs, peak_db=-3.0)


def rain_light():
    return rain(30.0, 701, drops=1400, hiss=0.5, roar=0.15, lufs=-28.0)


def rain_heavy():
    return rain(30.0, 702, drops=5000, hiss=0.8, roar=0.55, lufs=-24.0)


def hail():
    rng = np.random.default_rng(703)
    n = int(30.0 * SR)

    def stone(r):
        # A hard tick with a short resonant ring: ice on rock and on metal.
        d = r.uniform(0.003, 0.012)
        m = int(0.08 * SR)
        t = np.arange(m) / SR
        f = r.uniform(1800, 5200)
        ring = np.sin(2 * np.pi * f * t) * np.exp(-t / (d * 2.5)) * 0.6
        click = r.standard_normal(m) * np.exp(-t / d)
        return lowpass_fft(click, 9000, 1) + ring

    x = scatter(n, rng, 2600, stone, gain=(0.1, 1.0))
    x += np.stack([shaped_noise(n, rng, 600, 8000, tilt=-1.0) for _ in range(2)], axis=1) * 0.05
    return level(x, lufs=-26.0, peak_db=-2.0)


def dust():
    rng = np.random.default_rng(704)
    n = int(30.0 * SR)
    out = []
    for ch in range(2):
        gust = 0.5 + 0.3 * loop_lfo(n, 4, rng.uniform(0, 6)) + 0.2 * loop_lfo(n, 9, rng.uniform(0, 6))
        body = shaped_noise(n, rng, 50, 900, tilt=-2.0) * gust
        sand = shaped_noise(n, rng, 2500, 12000, tilt=-0.3) * 0.35 * gust ** 2
        out.append(body + sand)
    x = np.stack(out, axis=1)
    # Grit: a fine crackle of grains striking things.
    x += scatter(n, rng, 6000, lambda r: drop(r, 4000, 12000, (0.0008, 0.003)), gain=(0.05, 0.3)) * 0.4
    return level(x, lufs=-25.0, peak_db=-3.0)


def thunder(seed):
    """The crack of the return stroke, then the roll: the same bang arriving
    along a kilometre of channel, each part a little later and further off."""
    rng = np.random.default_rng(seed)
    secs = rng.uniform(5.5, 7.5)
    n = int(secs * SR)
    t = np.arange(n) / SR
    crack = shaped_noise(n, rng, 300, 9000, tilt=-0.6) * env(n, 0.002, 0.03, 0.12)
    roll = np.zeros(n)
    k = rng.integers(10, 18)
    for i in range(k):
        at = rng.uniform(0.05, secs * 0.55)
        dur = rng.uniform(0.4, 1.6)
        g = rng.uniform(0.3, 1.0) * np.exp(-at / (secs * 0.5))
        e = np.clip((t - at) / 0.06, 0, 1) ** 2 * np.exp(-np.clip(t - at, 0, None) / dur)
        roll += e * g
    rumble = shaped_noise(n, rng, 20, 420, tilt=-2.4) * roll
    x = crack * 0.9 + rumble * 1.6
    st = np.stack([x, np.roll(x, int(0.011 * SR))], axis=1)
    wet = reverb(st, seconds=2.6, mix=0.3, seed=seed, damp_hz=2200.0)
    return level(fade(wet, 0.0, 1.2), peak_db=-1.5)


FILES = {
    "weather/rain_light.ogg": rain_light,
    "weather/rain_heavy.ogg": rain_heavy,
    "weather/hail.ogg": hail,
    "weather/dust.ogg": dust,
    **{f"weather/thunder_{i}.ogg": (lambda i=i: thunder(800 + i)) for i in (1, 2, 3)},
}


def main():
    if "--stats" not in sys.argv:
        for rel, make in FILES.items():
            write_ogg(rel, make())
    for rel in FILES:
        stats(ROOT / rel)


if __name__ == "__main__":
    main()
