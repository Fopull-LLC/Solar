#!/usr/bin/env python3
"""The gas engines' running loops (playtest 2026-11-03c), synthesised.

    audio/foley/engine_four.ogg   a four-stroke single at 3000 rpm: one
                                  firing every two turns (25 Hz) — a thump
                                  through the silencer, the valvetrain's
                                  tick, a little intake hiss
    audio/foley/engine_two.ogg    a two-stroke single at 3000 rpm: a firing
                                  every turn (50 Hz), the expansion chamber's
                                  ringing buzz and its crackle

vessel_controller (SFX.gas) plays one loop per craft, pitched by rpm / 3000
and opened by the throttle. Each loop is exactly 2 s (a whole number of
firings and of every partial's period), so it repeats seamlessly. Every
firing differs a little (a seeded jitter in level and timbre), as a real
engine's do.

    python3 tools/gen_engine_audio.py            # write both
    python3 tools/gen_engine_audio.py --stats    # just measure them
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_soundscape_audio import SR, ROOT, write_ogg, stats  # noqa: E402

SECS = 2.0


def bandnoise(n, rng, lo, hi):
    x = rng.standard_normal(n)
    f = np.fft.rfftfreq(n, 1 / SR)
    X = np.fft.rfft(x)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, n)


def periodic(x):
    """Wrap a tail past the end back onto the start (a seamless loop)."""
    n = int(SECS * SR)
    out = x[:n].copy()
    if len(x) > n:
        out[:len(x) - n] += x[n:]
    return out


def engine(fire_hz, seed, body_hz, ring_hz, crackle, tick):
    rng = np.random.default_rng(seed)
    n = int(SECS * SR)
    total = np.zeros(n + SR // 2)
    period = 1.0 / fire_hz
    k = int(round(SECS * fire_hz))
    t = np.arange(int(0.25 * SR)) / SR
    for i in range(k):
        t0 = i * period + rng.normal(0, period * 0.012)
        s0 = int(max(0, t0) * SR)
        g = 1.0 + rng.normal(0, 0.12)
        # the firing: a low thump (the silencer's body) and a short ringing
        # partial (the pipe), each with its own decay
        thump = np.sin(2 * np.pi * body_hz * t * (1 + 0.04 * rng.standard_normal())) * np.exp(-t / 0.018)
        ring = np.sin(2 * np.pi * ring_hz * (1 + 0.03 * rng.standard_normal()) * t) * np.exp(-t / 0.006)
        burst = bandnoise(len(t), rng, 180, 2400) * np.exp(-t / 0.004) * 0.8
        ev = g * (thump + 0.35 * ring + burst)
        total[s0:s0 + len(t)] += ev[:len(total) - s0]
        if crackle and rng.random() < crackle:
            c0 = s0 + int(rng.uniform(0.3, 0.7) * period * SR)
            ln = int(0.006 * SR)
            if c0 + ln < len(total):
                total[c0:c0 + ln] += bandnoise(ln, rng, 1500, 7000) * 0.5
        if tick:
            # the valvetrain: a dry tick halfway round
            c0 = s0 + int(0.5 * period * SR)
            ln = int(0.003 * SR)
            if c0 + ln < len(total):
                total[c0:c0 + ln] += bandnoise(ln, rng, 2500, 9000) * tick
    x = periodic(total)
    # under it all: the intake's hiss and the crank's whirr, both periodic
    tt = np.arange(n) / SR
    x += 0.03 * bandnoise(n, rng, 400, 3000)
    x += 0.06 * np.sin(2 * np.pi * fire_hz * 2 * tt) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.5 * tt))
    # a gentle low-pass: a silencer, not a starting pistol
    f = np.fft.rfftfreq(n, 1 / SR)
    X = np.fft.rfft(x)
    X *= 1 / np.sqrt(1 + (f / 3200.0) ** 4)
    X[f < 30] = 0
    x = np.fft.irfft(X, n)
    rms = np.sqrt(np.mean(x ** 2)) + 1e-12
    x *= 10 ** (-18 / 20) / rms
    pk = np.max(np.abs(x))
    if pk > 0.89:
        x *= 0.89 / pk
    return x


def main():
    out = {
        "foley/engine_four.ogg": lambda: engine(25.0, 41, body_hz=95.0, ring_hz=420.0, crackle=0.04, tick=0.12),
        "foley/engine_two.ogg": lambda: engine(50.0, 42, body_hz=150.0, ring_hz=900.0, crackle=0.12, tick=0.0),
    }
    if "--stats" in sys.argv:
        for rel in out:
            stats(ROOT / rel)
        return
    for rel, fn in out.items():
        write_ogg(rel, fn())
        stats(ROOT / rel)


if __name__ == "__main__":
    main()
