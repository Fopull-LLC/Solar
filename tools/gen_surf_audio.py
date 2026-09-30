#!/usr/bin/env python3
"""Synthesize the sea's sounds into audio/water/ (Ogg Vorbis, via ffmpeg).

    surf_loop.ogg     24 s seamless loop: a low constant wash, waves breaking
                      every 5–8 s (a rising roar, then the hiss of foam drawing
                      back over sand)
    splash_1..3.ogg   short splashes, for a body hitting the water

Everything is noise shaped in the frequency domain and enveloped in time, so
the result is deterministic (fixed seeds) and needs nothing but numpy.

    python3 tools/gen_surf_audio.py
"""
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "audio" / "water"


def shaped_noise(n, rng, lo, hi, tilt=-1.0):
    """White noise band-passed to [lo, hi] Hz with a spectral tilt (dB/oct-ish)."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    f[0] = 1.0
    gain = (f / 1000.0) ** (tilt / 2.0)
    gain *= 1 / (1 + (lo / f) ** 4)          # soft high-pass
    gain *= 1 / (1 + (f / hi) ** 4)          # soft low-pass
    x = np.fft.irfft(spec * gain, n)
    return x / (np.abs(x).max() + 1e-9)


def env(n, attack, hold, decay):
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-3), 0, 1) ** 2
    d = np.exp(-np.clip(t - attack - hold, 0, None) / max(decay, 1e-3))
    return a * d


def surf_loop(seconds=24.0, xfade=3.0, seed=11):
    rng = np.random.default_rng(seed)
    n = int((seconds + xfade) * SR)
    t = np.arange(n) / SR
    # The bed: a slow-breathing low wash.
    bed = shaped_noise(n, rng, 60, 900, tilt=-2.0) * (0.22 + 0.06 * np.sin(t * 2 * np.pi / 9.0))
    out = bed.copy()
    at = 0.8
    while at < seconds + xfade - 1.0:
        size = rng.uniform(0.6, 1.0)
        m = int(7.5 * SR)
        s = int(at * SR)
        e = min(n, s + m)
        k = e - s
        roar = shaped_noise(k, rng, 120, 2600, tilt=-1.2) * env(k, rng.uniform(0.6, 1.1), 0.25, 1.1)
        hiss = shaped_noise(k, rng, 1800, 9000, tilt=-0.5) * env(k, 1.6, 0.4, 1.8) * 0.45
        out[s:e] += (roar * 0.75 + hiss) * size
        at += rng.uniform(5.0, 8.0)
    # Seamless: crossfade the tail over the head.
    L, X = int(seconds * SR), int(xfade * SR)
    w = np.linspace(0, 1, X)
    loop = out[:L].copy()
    loop[:X] = out[:X] * w + out[L:L + X] * (1 - w)
    return loop / (np.abs(loop).max() + 1e-9) * 0.8


def splash(seed):
    rng = np.random.default_rng(seed)
    n = int(1.6 * SR)
    body = shaped_noise(n, rng, 150, 5000, tilt=-1.0) * env(n, 0.012, 0.03, 0.22)
    spray = shaped_noise(n, rng, 2500, 12000, tilt=-0.3) * env(n, 0.05, 0.05, 0.45) * 0.5
    thump = np.sin(2 * np.pi * 70 * np.arange(n) / SR) * env(n, 0.004, 0.0, 0.07) * 0.5
    x = body + spray + thump
    return x / (np.abs(x).max() + 1e-9) * 0.9


def write_ogg(name, x):
    OUT.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        dst = OUT / name
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name,
                        "-c:a", "libvorbis", "-q:a", "4", str(dst)], check=True)
    Path(tmp.name).unlink()
    print(f"wrote {dst.relative_to(OUT.parent.parent)} ({dst.stat().st_size // 1024} KB)")


def main():
    write_ogg("surf_loop.ogg", surf_loop())
    for i in (1, 2, 3):
        write_ogg(f"splash_{i}.ogg", splash(100 + i))


if __name__ == "__main__":
    main()
