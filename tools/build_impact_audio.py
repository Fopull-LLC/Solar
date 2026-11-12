#!/usr/bin/env python3
"""build_impact_audio.py — impacts, failures and footsteps, cut from real recordings.

    python3 tools/build_impact_audio.py <source dir> [--stats]

Ty, 2026-11-12: "impacts and damage sound odd because the same sound effect gets
reused and doesn't fit the context ... when something goes wrong it plays
something like a can-drop sound". A hull knocking the ground played one sheet
steel bar falling on a path, a part grinding along the ground played a bird
scarer's gunshot, a torn-up part shorting out played radio interference, and
every footstep on every world was Kenney's concrete. scripts/sfx.lua now picks a
bank by what met what (metal, rock, soil, glass, plastic, the suit, a tyre), how
heavy it was and how fast; these are the banks. Every source is a field or foley
recording, CC0 1.0 on freesound.org; the licence was read on each sound's page
on 2026-11-12 (audio/SOURCES.md has the table). Nothing here is synthesised.

Fetch each HQ preview into <source dir> as fs_<id>.mp3 (the originals need a
login; the previews are the same recordings, 128 kb/s):

    curl -L -o fs_<id>.mp3 https://cdn.freesound.org/previews/<id // 1000>/<id>_<user id>-hq.mp3

    id      user id   what
    587443  5487341   SamsterBirdies, "Scrap metal dropping / crashing" (onto concrete, 6 takes)
    675461  2524442   craigsmith, "S10-14 Heavy metal objets crashing on stone floor; 3 takes"
    568816  97550     TRP, "200822 Metallic thud, boom, dull, mono PEC"
    669693  14100561  vestibule-door, "deep knocks on metal"
    640204  12131847  7of9Designs, "Heavy Metal Thud on Ground"
    489924  10570192  falcospizaetus, "MetalImpactAgainstRock07"
    109358  1868848   SoundCollectah, "rock lands on metal.aiff"
    859154  71257     qubodup, "Loud Bang Crashing Metal Chunk Dropped in Metal Dumpster"
    587442  5487341   SamsterBirdies, "Dropping sheet metal" (onto concrete)
    703247  13504080  xkeril, "Big falling debris (crash)" (tiles, stone and metal on concrete)
    703248  13504080  xkeril, "Fall debris (crash)"
    637988  612689    kyles, "wheelbarrow put down on concrete floor metal hits impacts thuds"
    451665  612689    kyles, "school bus truck destroy crush smash window break metal bend wreck"
    251401  1661766   felix.blume, "Dynamite explosion in the mountain"
    383794  7146007   deleted_user_7146007, "Metal Scraping on Concrete"
    392008  917043    burbujafilms, "HEAVY BAG DROP DIRT.wav"
    584891  13194852  KrystianPawlowski, "big log on dirt throwing.wav"
    369981  1196518   northern87, "Stone dropping to ground_northern87"
    179365  544580    lolamadeus, "Small Rock and Stone Hits.wav"
    504626  4437257   leonelmail, "BODY FALL - V HVY - DIRT"
    418194  3656686   deleted_user_3656686, "Hard Glass Impact"
    806423  13017680  Sanderboah, "Car windshield crack"
    212698  2585359   dasebr, "Breaking a glass bottle"
    272065  4683710   Bexhillcollege, "Thrown Object" (a cassette and case against a wall)
    133978  823769    EchoCinematics, "Item Falling (Plastic).mp3"
    401773  7687000   oztrum, "Plastic cup dropping"
    267921  59530     ChemiCatz, "tire_thump.wav"
    674021  11007330  mmmtoop, "230104-013_normalized_tire_hit.wav"
    776446  11318300  pryanic, "ELECArc_Electric arc hum and buzz"
    563765  6253486   florianreichelt, "Fire Auto - car on fire"
    138477  758593    JustInvoke, "Air Burst"
    384082  6892116   savataivanov, "Foot_Step_grit_Sand.wav"
    352870  4187409   PotatokingXII, "Footsteps Dirt Gravel"
    249933  389377    launemax, "walking slow, walking fast and running on sand"
    453168  6253486   florianreichelt, "footsteps in fresh snow"
    698697  9616576   IENBA, "Footsteps on Metal" (metal stairs, single steps)

Outputs: mono 44.1 kHz Ogg Vorbis in audio/impact/, each take's peak set per
bank (the game sets the level by energy and the engine's falloff does the rest).
`fire_loop` and `arc_loop` are crossfaded tail into head (seamless loops).

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
OUT = os.path.join(HERE, "..", "audio", "impact")


def takes(name, src, starts, secs, hp, fout, peak, fin=0.003, lead=0.02):
    """Takes for a bank: a cut per start (s). Numbered name_1..n across every
    takes() of the bank, in order (see numbered())."""
    return [(name + "#", src, max(0.0, t - lead), secs, hp, fin, fout, peak) for t in starts]


def numbered(cuts):
    count, out = {}, []
    for c in cuts:
        if c[0].endswith("#"):
            base = c[0][:-1]
            count[base] = count.get(base, 0) + 1
            c = ("%s_%d" % (base, count[base]),) + tuple(c[1:])
        out.append(c)
    return out


# (name, source, start s, length s, high-pass Hz, fade in s, fade out s, peak dBFS)
CUTS = numbered(
    # ── metal ──────────────────────────────────────────────────────────────
    # a light knock: a hull bumping something, a crate set down hard
    takes("metal_light", "fs_669693.mp3", [0.03, 0.92], 0.42, 50, 0.15, -3.0)
    + takes("metal_light", "fs_640204.mp3", [0.16], 0.55, 40, 0.2, -3.0)
    + takes("metal_light", "fs_489924.mp3", [0.46], 0.25, 80, 0.1, -4.0)
    # a dull, heavy hull meeting soil: low and short, no ring
    + takes("metal_dull", "fs_568816.mp3", [7.28, 11.13, 18.19, 19.74, 24.35], 1.5, 35, 0.6, -2.0)
    + takes("metal_dull", "fs_637988.mp3", [7.12], 1.0, 35, 0.4, -2.0)
    # metal on stone: a craft coming down on rock
    + takes("metal_rock", "fs_675461.mp3", [0.03, 2.22, 3.93], 1.0, 40, 0.4, -2.0)
    # metal on metal: a part against a deck or another craft
    + takes("metal_metal", "fs_859154.mp3", [0.04], 1.0, 40, 0.4, -2.0)
    + takes("metal_metal", "fs_587442.mp3", [2.94, 5.08], 1.6, 40, 0.6, -2.0)
    + takes("metal_metal", "fs_109358.mp3", [0.34], 1.0, 40, 0.4, -2.5)
    # a heavy crash: a lot of metal hitting hard ground at once
    + takes("metal_heavy", "fs_587443.mp3", [0.03, 7.99, 10.82, 15.25], 2.0, 35, 0.8, -1.5)
    + takes("crash", "fs_703247.mp3", [0.03], 2.6, 30, 1.0, -1.5)
    + takes("crash", "fs_703248.mp3", [0.03], 2.6, 30, 1.0, -1.5)
    + takes("crash", "fs_587443.mp3", [2.43], 2.2, 30, 0.9, -1.5)
    # a part giving way: metal bending, tearing and crunching (a real wreck)
    + takes("part_break", "fs_451665.mp3", [1.41, 7.60, 16.46, 49.23, 60.38], 1.4, 50, 0.5, -1.5)
    # a part grinding along the ground
    + takes("scrape", "fs_383794.mp3", [3.53, 4.75, 6.14, 10.85, 12.01], 1.1, 80, 0.35, -2.5)
    # an explosive part going off (one real blast; the game varies its pitch)
    + takes("explode", "fs_251401.mp3", [0.06], 4.5, 25, 2.0, -1.0, lead=0.0)
    # ── ground ─────────────────────────────────────────────────────────────
    + takes("soil_light", "fs_392008.mp3", [1.22, 12.76, 17.86, 34.93], 0.6, 40, 0.3, -3.0)
    + takes("soil_heavy", "fs_584891.mp3", [0.35, 8.53], 0.9, 30, 0.4, -2.0)
    + takes("soil_heavy", "fs_504626.mp3", [0.30], 1.2, 30, 0.4, -2.0)
    + takes("rock_soil", "fs_369981.mp3", [4.55, 13.14, 18.76, 24.50], 0.8, 30, 0.35, -2.0)
    + takes("rock_light", "fs_179365.mp3", [0.37, 6.04, 8.39, 11.61, 13.00, 14.33], 0.35, 80, 0.15, -3.0)
    # ── the suit, glass, plastic, tyres ───────────────────────────────────
    + takes("suit_fall", "fs_504626.mp3", [0.30], 1.2, 40, 0.4, -2.0)
    + takes("glass_knock", "fs_418194.mp3", [0.25], 0.45, 120, 0.15, -4.0)
    + takes("glass_break", "fs_212698.mp3", [0.46], 1.0, 150, 0.4, -2.0)
    + takes("glass_break", "fs_806423.mp3", [0.03], 1.3, 150, 0.4, -2.0)
    + takes("visor_crack", "fs_806423.mp3", [0.03], 0.7, 300, 0.3, -3.0)
    + takes("plastic", "fs_272065.mp3", [0.03, 1.01], 0.25, 100, 0.1, -3.0)
    + takes("plastic", "fs_133978.mp3", [0.19, 1.40], 0.5, 100, 0.2, -3.0)
    + takes("plastic", "fs_401773.mp3", [0.03], 0.5, 100, 0.2, -3.0)
    + takes("tyre", "fs_267921.mp3", [0.19, 2.14, 4.38], 0.7, 35, 0.3, -2.5)
    + takes("tyre", "fs_674021.mp3", [0.03, 1.85], 0.3, 35, 0.12, -2.5)
    # ── electrics and fire ─────────────────────────────────────────────────
    # a torn part shorting: an arc striking (77.5, 170.6) or dying (75.2, 166.0),
    # and short bursts out of its steady run
    + [("zap_1", "fs_776446.mp3", 77.48, 0.50, 200, 0.002, 0.08, -3.0),
       ("zap_2", "fs_776446.mp3", 170.58, 0.55, 200, 0.002, 0.12, -3.0),
       ("zap_3", "fs_776446.mp3", 75.20, 0.62, 200, 0.01, 0.10, -3.5),
       ("zap_4", "fs_776446.mp3", 165.95, 0.60, 200, 0.01, 0.10, -3.5),
       ("zap_5", "fs_776446.mp3", 40.00, 0.30, 200, 0.004, 0.10, -4.0)]
    # a battery on fire: the first swell of a car fire
    + [("fire_flare", "fs_563765.mp3", 0.0, 3.0, 60, 0.25, 1.2, -3.0)]
    # hull breach: a hull plate bursting under a blast of air
    + [("breach_1", "fs_568816.mp3", 11.11, 1.8, 30, 0.002, 0.8, -1.5),
       ("breach_2", "fs_568816.mp3", 19.72, 1.4, 30, 0.002, 0.6, -1.5)]
    # ── footsteps by surface ───────────────────────────────────────────────
    + takes("step_grit", "fs_384082.mp3", [2.21, 2.78, 3.36, 3.91, 4.46, 5.01], 0.36, 60, 0.14, -4.0)
    + takes("step_soil", "fs_352870.mp3", [5.66, 7.43, 8.79, 9.74, 16.84, 18.49], 0.36, 60, 0.14, -4.0)
    + takes("step_sand", "fs_249933.mp3", [2.64, 7.12, 8.68, 12.54, 13.48, 18.39], 0.40, 60, 0.16, -4.0)
    + takes("step_snow", "fs_453168.mp3", [0.53, 2.10, 5.04, 7.17, 13.49, 15.44], 0.40, 60, 0.16, -4.0)
    + takes("step_metal", "fs_698697.mp3", [1.49, 2.99, 4.50, 5.98, 7.48, 9.00], 0.45, 50, 0.18, -4.0)
)

# Layers mixed in after the cuts: (output, source, start s, gain dB) — the air
# blast of a breach under its plate.
LAYERS = [
    ("breach_1", "fs_138477.mp3", 0.0, -3.0),
    ("breach_2", "fs_138477.mp3", 0.0, -3.0),
]

# Seamless loops: (name, source, start s, length s, high-pass Hz, crossfade s, rms dBFS)
LOOPS = [
    ("fire_loop", "fs_563765.mp3", 2.0, 12.0, 50, 1.5, -20.0),
    ("arc_loop", "fs_776446.mp3", 120.0, 4.0, 200, 0.5, -20.0),
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

    def get(f):
        if f not in cache:
            cache[f] = load(os.path.join(src, f))
        return cache[f]

    made = {}
    for name, f, t, secs, hp, fin, fout, peak in CUTS:
        x = get(f)
        a = int(t * SR)
        y = x[a:a + int(secs * SR)]
        y = high_pass(y, hp)
        y = y - np.mean(y)
        made[name] = (y, fin, fout, peak)
    for name, f, t, gain in LAYERS:
        y, fin, fout, peak = made[name]
        z = get(f)[int(t * SR):]
        z = high_pass(z, 80)
        z = z / (np.max(np.abs(z)) + 1e-12) * np.max(np.abs(y)) * 10 ** (gain / 20)
        n = min(len(y), len(z))
        y = y.copy()
        y[:n] += z[:n]
        made[name] = (y, fin, fout, peak)
    for name, (y, fin, fout, peak) in made.items():
        y = fades(y, fin, fout)
        # Takes of one bank must sit at one level, or the variation is a volume
        # lottery: the loudest 50 ms of each goes to `peak` - 9 dB RMS, and the
        # peak is then held at `peak` (vorbis overshoots ~0.8 dB).
        w = int(0.05 * SR)
        loud = np.sqrt(np.max(np.convolve(y ** 2, np.ones(w) / w, mode="valid"))) if len(y) > w else np.max(np.abs(y))
        y *= 10 ** ((peak - 9.0) / 20) / (loud + 1e-12)
        top = np.max(np.abs(y))
        if top > 10 ** ((peak - 0.8) / 20):
            y *= 10 ** ((peak - 0.8) / 20) / top
        save(name, y)
    for name, f, t, secs, hp, xf, rms in LOOPS:
        x = get(f)
        a, n, k = int(t * SR), int(secs * SR), int(xf * SR)
        y = high_pass(x[a:a + n + k], hp)
        y = y - np.mean(y)
        head, tail = y[:k], y[n:n + k]
        w = np.linspace(0, 1, k)
        body = y[:n].copy()
        body[:k] = head * np.sqrt(w) + tail * np.sqrt(1 - w)        # equal power, tail into head
        body *= 10 ** (rms / 20) / (np.sqrt(np.mean(body ** 2)) + 1e-12)
        pk = np.max(np.abs(body))
        if pk > 10 ** (-1.8 / 20):
            body *= 10 ** (-1.8 / 20) / pk
        save(name, body)


def names():
    seen = []
    for c in CUTS:
        if c[0] not in seen:
            seen.append(c[0])
    return seen + [l[0] for l in LOOPS]


def stats():
    for name in names():
        p = os.path.join(OUT, name + ".ogg")
        x = load(p)
        print("%-14s %5.2f s  peak %6.1f dBFS  %6.1f LUFS" % (name, len(x) / SR,
              20 * np.log10(np.max(np.abs(x)) + 1e-12), lufs(p)))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        build(args[0])
    if "--stats" in sys.argv:
        stats()
