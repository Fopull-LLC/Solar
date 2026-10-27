#!/usr/bin/env python3
"""The TL-5 Surveyor plasma rifle's sounds (scripts/surveyor.lua) and the
crew's HIT warning (scripts/crew_alerts_hud.lua), synthesised: nothing
recorded, nothing downloaded.

    python3 tools/gen_weapon_audio.py [--stats]

    audio/sfx/surveyor_charge.ogg   the capacitor charging: a rising whine over
                                    a buzz, 0.9 s (the full-charge time)
    audio/sfx/surveyor_ready.ogg    the charge held at full: a seamless 1 s loop
    audio/sfx/surveyor_fire.ogg     the shot: a hard crack, a falling plasma
                                    "zap", a low thump and a short tail
    audio/sfx/surveyor_hit.ogg      a bolt landing: a sizzling snap, spatter
    audio/sfx/crew_hit.ogg          the HUD's HIT: a dull thud through the suit
                                    and a short two-pip warning

Levels as audio/SOURCES.md asks: one-shots peak -1 dBFS with RMS no hotter
than -14 dBFS; loops RMS -18 dBFS. Check with --stats, never by speakers.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_crew_audio import SR, env, level, lowpass, stats, write  # noqa: E402

RNG = np.random.default_rng(55)


def highpass(x, cutoff):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 - 1 / (1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))


def sweep(f0, f1, secs, shape=1.0):
    t = np.arange(int(secs * SR)) / SR
    k = (t / secs) ** shape
    f = f0 + (f1 - f0) * k
    return np.sin(2 * np.pi * np.cumsum(f) / SR), t


def charge():
    s, t = sweep(220, 1900, 0.9, 0.7)
    buzz = np.sign(np.sin(2 * np.pi * 120 * t)) * 0.12 * (0.3 + t / 0.9)
    h, _ = sweep(440, 3800, 0.9, 0.7)
    x = (s * 0.8 + h * 0.25) * (0.2 + 0.8 * t / 0.9) + buzz
    x *= env(len(t), 0.03, 0.05)
    return level(lowpass(x, 6000), -1.0, -18)


def ready():
    # 1 s exactly: 1900 Hz and 120 Hz are both whole cycles in 1 s, so it loops
    t = np.arange(SR) / SR
    x = np.sin(2 * np.pi * 1900 * t) * 0.6 + np.sin(2 * np.pi * 3800 * t) * 0.15
    x *= 0.8 + 0.2 * np.sin(2 * np.pi * 6 * t)
    x += np.sign(np.sin(2 * np.pi * 120 * t)) * 0.1
    return level(lowpass(x, 6000), -1.0, -22)


def fire():
    n = int(1.1 * SR)
    t = np.arange(n) / SR
    crack = highpass(RNG.normal(0, 1, n), 1800) * np.exp(-t / 0.012)
    z, _ = sweep(2600, 180, 1.1, 0.35)
    zap = z * np.exp(-t / 0.11)
    thump = np.sin(2 * np.pi * 58 * t) * np.exp(-t / 0.09) + 0.5 * np.sin(2 * np.pi * 37 * t) * np.exp(-t / 0.16)
    tail = lowpass(RNG.normal(0, 1, n), 900) * np.exp(-t / 0.35) * 0.35
    x = crack * 1.2 + zap * 0.7 + thump * 0.9 + tail
    return level(x * env(n, 0.0005, 0.2), -1.8, -14)   # (vorbis overshoots a hard crack ~0.6 dB)


def hit():
    n = int(0.7 * SR)
    t = np.arange(n) / SR
    snap = highpass(RNG.normal(0, 1, n), 2500) * np.exp(-t / 0.008)
    sizzle = highpass(RNG.normal(0, 1, n), 4000) * np.exp(-t / 0.18) * (0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 37 * t)))
    body = np.sin(2 * np.pi * 90 * t) * np.exp(-t / 0.05)
    x = snap * 1.0 + sizzle * 0.35 + body * 0.8
    return level(lowpass(x * env(n, 0.0005, 0.15), 9000), -1.0, -15)


def crew_hit():
    n = int(0.6 * SR)
    t = np.arange(n) / SR
    thud = np.sin(2 * np.pi * 70 * t) * np.exp(-t / 0.06) + lowpass(RNG.normal(0, 1, n), 300) * np.exp(-t / 0.05)
    pips = np.zeros(n)
    for t0 in (0.12, 0.26):
        k = (t >= t0) & (t < t0 + 0.08)
        pips[k] = np.sin(2 * np.pi * 1320 * (t[k] - t0)) * 0.5
    x = thud * 1.0 + lowpass(pips, 4000)
    return level(x * env(n, 0.001, 0.05), -1.0, -15)


if __name__ == "__main__":
    made = [write("surveyor_charge", charge()), write("surveyor_ready", ready()), write("surveyor_fire", fire()),
            write("surveyor_hit", hit()), write("crew_hit", crew_hit())]
    if "--stats" in sys.argv:
        for p in made:
            stats(p)
