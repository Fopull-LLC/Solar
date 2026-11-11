#!/usr/bin/env python3
"""build_cave_audio.py — cut the cave's drips and room tone from real recordings.

    python3 tools/build_cave_audio.py <source dir> [--stats]

Ty, 2026-11-10: "there's this weird new cave ambience that sounds like a really
resonant water drop but it doesn't sound spatially accurate or realistic at
all, it sounds very synthesized; I'd rather you find real sound effects
instead of synthesizing them." The drips and the room tone that
tools/gen_grit_audio.py synthesised are now cut from field recordings made in
real caves, all CC0 on freesound.org (audio/SOURCES.md has the pages):

    fs_402929.mp3   "Drops in the small cave" by Selector: the Ledyanaya cave
                    near Staritsa, Russia (Zoom H6, XYH-6). freesound #402929
    fs_164785.mp3   "INT Cave Room tone.wav": the room tone of a cave in Kent,
                    England (mono, directional). freesound #164785

Fetch each source's HQ preview into <source dir> (the originals need a
freesound login; the previews are the same recordings, 48 kHz):

    curl -L -o fs_402929.mp3 https://cdn.freesound.org/previews/402/402929_270868-hq.mp3
    curl -L -o fs_164785.mp3 https://cdn.freesound.org/previews/164/164785_2104797-hq.mp3

The cave KINDS (worlds W4, scripts/cave_kinds.lua; Ty 2026-11-10: "make more
scary feeling and unique caves") each add a real recording, all CC0:

    fs_352904.mp3   "Bubbling Mud with Steam" by ProductionNow: the Artist
                    Paintpots, Yellowstone (steam hiss, spitting mud). #352904
    fs_613617.mp3   "Rocket Launch Rumble (Geofon recording)" by felix.blume:
                    the ground itself through a geophone, 20 km out. #613617
    fs_552485.mp3   "Water Flowing into Underground Sinkhole" by hinchinbrook:
                    a stream gurgling down into a cave, the chamber's bass. #552485
    fs_369982.mp3   "Ice cracking_northern87" (Oktava MK-012). #369982
    fs_169897.mp3   "ice_cracking_01.flac" by Mooe (Zoom H2N). #169897

    curl -L -o fs_352904.mp3 https://cdn.freesound.org/previews/352/352904_3646900-hq.mp3
    curl -L -o fs_613617.mp3 https://cdn.freesound.org/previews/613/613617_1661766-hq.mp3
    curl -L -o fs_552485.mp3 https://cdn.freesound.org/previews/552/552485_9847211-hq.mp3
    curl -L -o fs_369982.mp3 https://cdn.freesound.org/previews/369/369982_1196518-hq.mp3
    curl -L -o fs_169897.mp3 https://cdn.freesound.org/previews/169/169897_27124-hq.mp3

Outputs (mono 44.1 kHz Ogg Vorbis, audio/ambience/):
  * cave_drip_1..6: single drops that land in the cave's own pool, each with the
    real cave's short tail and nothing of the next drop. MONO, because
    underground.lua plays each as a 3D source where the drop lands (distance
    falloff and direction from the engine; the SFX bus adds its room).
    Peak -3 dBFS each (the script varies the level per drop).
  * cave_tone: 30 s seamless loop (equal-power crossfade of its tail into its
    head). The recording's sub-30 Hz handling rumble and its preamp hiss
    above 7 kHz are filtered off; levelled to about -33 LUFS integrated, as the
    synthesised tone was, peak under -12 dBFS.
  * cave_vent (13 s loop): a sulfur vent's bed, steam hissing and mud spitting
    (the vent kind); 60 Hz-9 kHz, -30 LUFS.
  * cave_rumble (28 s loop): the ground's own rumble through a geophone, the
    lava tube's (and the deep magma's); 20-160 Hz, -32 LUFS.
  * cave_water_far (18 s loop): water somewhere below, gurgling into rock,
    with the chamber's bass (the chasm); 40 Hz-6 kHz, -33 LUFS.
  * cave_ice_crack_1..3: single cracks of ice under stress, MONO one-shots
    played as 3D sources in the ice cave's walls; peak -3.8 dBFS.

--stats prints each output's length, peak, RMS and integrated loudness (ffmpeg
ebur128). Check by numbers, never by playing them through speakers.
"""
import os
import re
import subprocess
import sys

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio", "ambience")

# (source, onset s, length s): drops with no other drop above -20 dB of them
# inside the cut (found with an onset detector on the 800 Hz high-passed track)
DRIPS = [
    ("fs_402929.mp3", 14.59, 1.30),
    ("fs_402929.mp3", 17.48, 1.30),
    ("fs_402929.mp3", 20.91, 1.30),
    ("fs_402929.mp3", 22.34, 1.05),
    ("fs_402929.mp3", 74.30, 0.72),
    ("fs_402929.mp3", 110.67, 0.64),
]
TONE = ("fs_164785.mp3", 40.0, 32.0, 2.0)   # source, start s, length s, crossfade s
# the kinds' beds: (name, source, start s, length s, crossfade s, hp, lp, LUFS, peak cap dBFS)
BEDS = [
    ("cave_vent", "fs_352904.mp3", 0.0, 13.0, 1.5, 60, 9000, -30.0, -6.0),
    ("cave_rumble", "fs_613617.mp3", 70.0, 28.0, 2.0, 20, 160, -32.0, -6.0),
    ("cave_water_far", "fs_552485.mp3", 2.0, 18.0, 2.0, 40, 6000, -33.0, -10.0),
]
# single ice cracks (onsets found on the 400 Hz high-passed track, nothing
# within 18 dB of them in the half second before): (source, onset s, length s)
CRACKS = [
    ("fs_369982.mp3", 9.18, 1.30),
    ("fs_369982.mp3", 32.81, 1.20),
    ("fs_169897.mp3", 8.30, 1.50),
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


def fft_filter(x, hp=0.0, lp=0.0, slope=12.0):
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    g = np.ones_like(f)
    if hp:
        r = np.maximum(f, 1.0) / hp
        g *= np.where(r < 1, r ** (slope / 6.02), 1.0)
    if lp:
        r = f / lp
        g *= np.where(r > 1, np.maximum(r, 1e-9) ** (-slope / 6.02), 1.0)
    return np.fft.irfft(X * g, n)


def fades(x, fin, fout):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a > 0:
        x[:a] *= np.linspace(0, 1, a) ** 2
    if b > 0:
        x[-b:] *= np.linspace(1, 0, b) ** 2
    return x


def loopify(x, xf):
    """Equal-power crossfade of the last `xf` seconds into the first."""
    c = int(xf * SR)
    body, tail = x[:-c].copy(), x[-c:]
    t = np.linspace(0, np.pi / 2, c)
    body[:c] = body[:c] * np.sin(t) + tail * np.cos(t)
    return body


def lufs(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+([-\d.]+) LUFS", r)
    return float(m[-1]) if m else float("nan")


def build(src):
    cache = {}

    def get(name):
        if name not in cache:
            cache[name] = load(os.path.join(src, name))
        return cache[name]

    for i, (name, t, secs) in enumerate(DRIPS, 1):
        x = get(name)
        a = int((t - 0.04) * SR)
        y = x[a:a + int(secs * SR)]
        y = fft_filter(y, hp=120)
        y = y - np.mean(y)
        y = fades(y, 0.003, min(0.15, secs * 0.25))
        y *= 10 ** (-3.8 / 20) / (np.max(np.abs(y)) + 1e-12)   # vorbis overshoots ~0.8 dB
        save("cave_drip_%d" % i, y)
    name, t, secs, xf = TONE
    x = get(name)
    a = int(t * SR)
    y = x[a:a + int((secs + xf) * SR)]
    y = fft_filter(y, hp=35, lp=7000, slope=18)
    y = loopify(y - np.mean(y), xf)
    p = save("cave_tone", y)
    # level by loudness: measure, then scale to -33 LUFS (peak kept under -12 dBFS)
    g = 10 ** ((-33.0 - lufs(p)) / 20)
    g = min(g, 10 ** (-12.8 / 20) / (np.max(np.abs(y)) + 1e-12))
    save("cave_tone", y * g)
    for name, srcf, t, secs, xf, hp, lp, target, cap in BEDS:
        x = get(srcf)
        a = int(t * SR)
        y = x[a:a + int((secs + xf) * SR)]
        y = fft_filter(y, hp=hp, lp=lp, slope=18)
        y = loopify(y - np.mean(y), xf)
        p = save(name, y)
        g = 10 ** ((target - lufs(p)) / 20)
        g = min(g, 10 ** ((cap - 0.8) / 20) / (np.max(np.abs(y)) + 1e-12))
        save(name, y * g)
    for i, (srcf, t, secs) in enumerate(CRACKS, 1):
        x = get(srcf)
        a = int((t - 0.03) * SR)
        y = x[a:a + int(secs * SR)]
        y = fft_filter(y, hp=150)
        y = y - np.mean(y)
        y = fades(y, 0.004, min(0.3, secs * 0.3))
        y *= 10 ** (-3.8 / 20) / (np.max(np.abs(y)) + 1e-12)
        save("cave_ice_crack_%d" % i, y)


def stats():
    for n in ["cave_drip_%d" % i for i in range(1, len(DRIPS) + 1)] + ["cave_tone"] + [b[0] for b in BEDS] \
            + ["cave_ice_crack_%d" % i for i in range(1, len(CRACKS) + 1)]:
        p = os.path.join(OUT, n + ".ogg")
        x = load(p)
        pk = 20 * np.log10(np.max(np.abs(x)) + 1e-12)
        rms = 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)
        seam = ""
        if n == "cave_tone" or n in [b[0] for b in BEDS]:
            seam = "  seam step %.4f (median step %.4f)" % (abs(x[0] - x[-1]), np.median(np.abs(np.diff(x))))
        print("%-12s %6.2f s  peak %6.1f dBFS  rms %6.1f dBFS  I %6.1f LUFS%s" % (n, len(x) / SR, pk, rms, lufs(p), seam))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--stats" not in sys.argv:
        if not args:
            sys.exit(__doc__)
        build(args[0])
    stats()
