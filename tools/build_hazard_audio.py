#!/usr/bin/env python3
"""build_hazard_audio.py — the cave hazards' sounds, cut from real recordings.

    python3 tools/build_hazard_audio.py <source dir> [--stats]

Worlds W5 (scripts/cave_hazards.lua): a rockfall is telegraphed by a crack,
a trickle of grit while the dust comes down, then the slabs; an unstable roof
ticks before it goes; a methane pocket lit by the laser goes off with a dull
whump. Every one is a field or foley recording, CC0 on freesound.org
(audio/SOURCES.md has the pages); nothing here is synthesised.

    fs_109360.mp3   "stone falls and breaks low pitch.aiff" by SoundCollectah:
                    a stone landing and breaking into pieces. #109360
    fs_489905.mp3   "RockCrack03" by falcospizaetus: cracks appearing in a
                    rock (small, close). #489905
    fs_500638.mp3   "Cathedral Mountain rock slide, slow blocky chunks" by
                    betchkal (Denali): a small slide, separate pops. #500638
    fs_389303.mp3   "rockfall2a.wav" by AlanCat: rocks falling down a cliff,
                    a cascade of smaller rocks after (Olympus LS-14). #389303
    fs_381645.mp3   "RockFall1b.wav" by AlanCat: small boulders crashing and
                    rolling down a short slope. #381645
    fs_145400.mp3   "gasExplosion.wav" by Zabuhailo: an old gas stove's
                    accumulated gas going off when the valve closed. #145400

Fetch each HQ preview into <source dir> (the originals need a login; the
previews are the same recordings):

    curl -L -o fs_109360.mp3 https://cdn.freesound.org/previews/109/109360_1868848-hq.mp3
    curl -L -o fs_489905.mp3 https://cdn.freesound.org/previews/489/489905_10570192-hq.mp3
    curl -L -o fs_500638.mp3 https://cdn.freesound.org/previews/500/500638_339183-hq.mp3
    curl -L -o fs_389303.mp3 https://cdn.freesound.org/previews/389/389303_5486695-hq.mp3
    curl -L -o fs_381645.mp3 https://cdn.freesound.org/previews/381/381645_5486695-hq.mp3
    curl -L -o fs_145400.mp3 https://cdn.freesound.org/previews/145/145400_2580450-hq.mp3

Outputs (mono 44.1 kHz Ogg Vorbis, audio/ambience/; 3D sources on the rock):
  * cave_crack:        the roof letting go (the rockfall's warning), 2.2 s
  * cave_tick_1..3:    an unstable roof ticking, small and close, 0.25-0.3 s
  * cave_trickle:      grit and pebbles pattering down (the 1.5 s of dust), 3 s
  * cave_rockfall_1..2: the slabs coming down, 3.6-4 s
  * cave_slab_hit_1..2: a block landing and rolling, 1.8-2 s
  * cave_gas_whump:    a methane pocket going off, 0.7 s (played pitched down)

--stats prints each output's length, peak and integrated loudness (ffmpeg
ebur128). Check by numbers, never by playing them aloud.
"""
import os
import re
import subprocess
import sys

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio", "ambience")

# (name, source, start s, length s, high-pass Hz, fade in s, fade out s, peak dBFS)
CUTS = [
    ("cave_crack", "fs_109360.mp3", 0.0, 2.2, 60, 0.002, 0.5, -1.5),
    ("cave_tick_1", "fs_489905.mp3", 0.84, 0.30, 600, 0.003, 0.12, -6.0),
    ("cave_tick_2", "fs_489905.mp3", 1.72, 0.25, 600, 0.003, 0.10, -6.0),
    ("cave_tick_3", "fs_489905.mp3", 2.02, 0.25, 600, 0.003, 0.10, -6.0),
    ("cave_trickle", "fs_500638.mp3", 7.5, 3.0, 150, 0.05, 0.6, -4.0),
    ("cave_rockfall_1", "fs_389303.mp3", 0.5, 4.0, 40, 0.02, 1.0, -1.5),
    ("cave_rockfall_2", "fs_389303.mp3", 6.9, 3.6, 40, 0.02, 1.0, -1.5),
    ("cave_slab_hit_1", "fs_381645.mp3", 0.25, 2.0, 40, 0.005, 0.6, -1.5),
    ("cave_slab_hit_2", "fs_381645.mp3", 20.0, 1.8, 40, 0.005, 0.6, -1.5),
    ("cave_gas_whump", "fs_145400.mp3", 0.0, 0.72, 30, 0.002, 0.25, -1.5),
]


def load(path):
    b = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR),
                        "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(b, dtype=np.float32).astype(np.float64)


def save(name, x):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1",
                    "-i", "-", "-c:a", "libvorbis", "-q:a", "5", p],
                   input=x.astype(np.float32).tobytes(), check=True)
    return p


def high_pass(x, hp, slope=12.0):
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    r = np.maximum(f, 1.0) / hp
    X *= np.where(r < 1, r ** (slope / 6.02), 1.0)
    return np.fft.irfft(X, n)


def fades(x, fin, fout):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a > 0:
        x[:a] *= np.linspace(0, 1, a) ** 2
    if b > 0:
        x[-b:] *= np.linspace(1, 0, b) ** 2
    return x


def lufs(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+([-\d.]+) LUFS", r)
    return float(m[-1]) if m else float("nan")


def build(src):
    cache = {}
    for name, f, t, secs, hp, fin, fout, peak in CUTS:
        if f not in cache:
            cache[f] = load(os.path.join(src, f))
        x = cache[f]
        a = int(t * SR)
        y = x[a:a + int(secs * SR)]
        y = high_pass(y, hp)
        y = y - np.mean(y)
        y = fades(y, fin, fout)
        y *= 10 ** ((peak - 0.8) / 20) / (np.max(np.abs(y)) + 1e-12)   # vorbis overshoots ~0.8 dB
        save(name, y)


def stats():
    for name, *_ in CUTS:
        p = os.path.join(OUT, name + ".ogg")
        x = load(p)
        print("%-18s %5.2f s  peak %6.1f dBFS  %6.1f LUFS" % (name, len(x) / SR,
              20 * np.log10(np.max(np.abs(x)) + 1e-12), lufs(p)))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        build(args[0])
    if "--stats" in sys.argv:
        stats()
