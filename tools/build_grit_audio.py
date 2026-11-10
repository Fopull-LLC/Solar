#!/usr/bin/env python3
"""build_grit_audio.py — the Terrain Laser's bite, the cave's creaks and groans
and the suit you breathe in, cut from real recordings.

    python3 tools/build_grit_audio.py <source dir> [--stats]

Ty, 2026-11-10: "I'd rather you try and find real sound effects instead of
synthesizing ones, especially more complex ones." Everything that
tools/gen_grit_audio.py synthesised (the gritty-realism pass) is now cut from
field recordings, all CC0 1.0 on freesound.org (the licence was read on each
sound's page, 2026-11-10; audio/SOURCES.md has the table):

    fs_733483.mp3   "Plasma Cutter 01" by C-V: a plasma cutter cutting sheet
                    metal in a metal shop. freesound #733483
    fs_453690.mp3   "welder sparks good detail2 long straight weld" by kyles.
                    freesound #453690
    fs_613617.mp3   "Rocket Launch Rumble (Geofon recording)" by felix.blume:
                    the ground shaking 20 km from Cape Canaveral, a geophone in
                    the sand (Lom geofon, MixPre6). freesound #613617
    fs_850191.mp3   "STONEMILL1" by Nordliecht: a massive granite saw cutting
                    slabs in a Swiss stone mill. freesound #850191
    fs_481892.mp3   "R22-45-Big Wood Creaks" by craigsmith: big creaking wood,
                    many versions. freesound #481892
    fs_847807.mp3   "rumbling_ice" by aerror: the ice of a frozen lake
                    rumbling. freesound #847807
    fs_179341.mp3   "Gravel Impacts and Falls" by lolamadeus: a pile of gravel
                    hit and pushed, trickling down. freesound #179341
    fs_426297.mp3   "Mask breathing 1" by Diramus: a man breathing through an
                    ABC (respirator) mask. freesound #426297
    fs_256519.mp3   "Mask Breathing Sound" by Kodack: breathing in a heavy mask
                    (Sony HDR-PJ260V, edited in Audacity). freesound #256519
    fs_165530.mp3   "Quiet Computer Fan" by EagleStealthTeam (Shure SM57).
                    freesound #165530

Fetch each source's HQ preview into <source dir> (the originals need a
freesound login; the previews are the same recordings):

    curl -L -o fs_733483.mp3 https://cdn.freesound.org/previews/733/733483_8956746-hq.mp3
    curl -L -o fs_453690.mp3 https://cdn.freesound.org/previews/453/453690_612689-hq.mp3
    curl -L -o fs_613617.mp3 https://cdn.freesound.org/previews/613/613617_1661766-hq.mp3
    curl -L -o fs_850191.mp3 https://cdn.freesound.org/previews/850/850191_17216918-hq.mp3
    curl -L -o fs_481892.mp3 https://cdn.freesound.org/previews/481/481892_2524442-hq.mp3
    curl -L -o fs_847807.mp3 https://cdn.freesound.org/previews/847/847807_2472895-hq.mp3
    curl -L -o fs_179341.mp3 https://cdn.freesound.org/previews/179/179341_544580-hq.mp3
    curl -L -o fs_426297.mp3 https://cdn.freesound.org/previews/426/426297_5690194-hq.mp3
    curl -L -o fs_256519.mp3 https://cdn.freesound.org/previews/256/256519_2276808-hq.mp3
    curl -L -o fs_165530.mp3 https://cdn.freesound.org/previews/165/165530_2915633-hq.mp3

Outputs (44.1 kHz Ogg Vorbis), at the levels the synthesised files had so the
mix does not move (--stats prints them; check by numbers, never by speakers):
  * foley/laser_hiss: 12 s stereo loop, the Terrain Laser's bite (tool_belt
    SFX.cs): the plasma cutter's hiss, 300 Hz-8 kHz. -23.8 LUFS.
  * foley/laser_crackle: 12 s stereo loop: the weld's sparks, 700 Hz-9 kHz.
    -25 LUFS.
  * foley/laser_rumble: 12 s stereo loop: the geophone's ground shake under
    160 Hz, the granite saw's grind (200-900 Hz) on top. -28 LUFS.
  * ambience/cave_creak_1..3: MONO one-shots (underground.lua plays each as
    a 3D source on the rock): single timber creaks, played at 0.62-0.72x (a
    bigger beam, deeper), 250 Hz-3.5 kHz. -23.7 LUFS.
  * ambience/cave_groan_1..2: MONO one-shots: a deep rumble swelling and dying
    (the lake ice; the geophone), grit trickling down gravel after it.
    -24.5 LUFS.
  * sfx/breath_calm: 12.4 s stereo loop, two slow breaths in the respirator
    mask, the seam in a pause. -29.1 LUFS.
  * sfx/breath_heavy: 9.7 s stereo loop, three hard breaths in the heavy
    mask. -27.2 LUFS.
  * sfx/suit_hum: 10 s stereo loop, the fan. -34.6 LUFS, peak under -12 dBFS.

Loops are crossfaded tail-into-head (equal power), so they have no seam.
"""
import os
import re
import subprocess
import sys

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(HERE, "..", "audio")


# (source, start s, length s[, ...]): found from 100-250 ms envelopes and
# spectrograms of each source (steady stretches for loops, single events with
# nothing else inside the cut for one-shots, loop seams in a breath's pause)
HISS = (30.0, 12.0, 1.0)                         # fs_733483: start, loop length, crossfade
CRACKLE = (8.5, 12.0, 1.0)                       # fs_453690
RUMBLE_GEO = (14.0, 12.0, 1.0, 2.5)              # fs_613617: start, length, crossfade, its fade over the cut (dB)
RUMBLE_SAW = ("fs_850191.mp3", 10.0, 12.0, 0.5)  # the granite saw: start, length, its level against the ground's
CREAKS = [                                       # (source, start, length, playback rate)
    ("fs_481892.mp3", 84.25, 3.40, 0.70),        # one long, slow creak
    ("fs_481892.mp3", 38.35, 1.45, 0.62),
    ("fs_481892.mp3", 48.15, 1.45, 0.72),
]
GROANS = [                                       # (rumble source, start, length, (grit source, start, length), grit at, grit level)
    ("fs_847807.mp3", 33.9, 3.8, ("fs_179341.mp3", 3.40, 1.50), 0.62, 0.10),   # lake ice under stress
    ("fs_613617.mp3", 41.0, 4.2, ("fs_179341.mp3", 8.05, 1.00), 0.58, 0.10),   # the ground (geophone)
]
BREATH_CALM = (3.58, 15.97, 0.25)                # fs_426297: seam at, seam at, crossfade
BREATH_HEAVY = (3.00, 12.72, 0.25)               # fs_256519
SUIT = (2.0, 10.0, 1.0)                          # fs_165530: start, loop length, crossfade

OUTPUTS = ["foley/laser_hiss.ogg", "foley/laser_crackle.ogg", "foley/laser_rumble.ogg",
           "ambience/cave_creak_1.ogg", "ambience/cave_creak_2.ogg", "ambience/cave_creak_3.ogg",
           "ambience/cave_groan_1.ogg", "ambience/cave_groan_2.ogg",
           "sfx/breath_calm.ogg", "sfx/breath_heavy.ogg", "sfx/suit_hum.ogg"]
LOOPS = {"foley/laser_hiss.ogg", "foley/laser_crackle.ogg", "foley/laser_rumble.ogg",
         "sfx/breath_calm.ogg", "sfx/breath_heavy.ogg", "sfx/suit_hum.ogg"}


# ── io ──────────────────────────────────────────────────────────────────────

def load(path, ch=2):
    b = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", str(ch), "-ar", str(SR),
                        "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(b, dtype=np.float32).astype(np.float64)
    return x.reshape(-1, ch) if ch == 2 else x


def save(rel, x):
    p = os.path.join(AUDIO, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    ch = 1 if x.ndim == 1 else x.shape[1]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(ch),
                    "-i", "-", "-c:a", "libvorbis", "-q:a", "5", p],
                   input=np.ascontiguousarray(x, dtype=np.float32).tobytes(), check=True)
    return p


def ebur(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true",
                        "-f", "null", "-"], capture_output=True, text=True).stderr
    i = re.findall(r"I:\s+([-\d.]+) LUFS", r)
    pk = re.findall(r"Peak:\s+([-\d.]+) dBFS", r)
    return (float(i[-1]) if i else float("nan")), (float(pk[-1]) if pk else float("nan"))


# ── processing ──────────────────────────────────────────────────────────────

def fft_filter(x, hp=0.0, lp=0.0, slope=12.0):
    """High/low-pass by a smooth gain curve in the frequency domain (slope dB/oct)."""
    n = x.shape[0]
    X = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(n, 1 / SR)
    g = np.ones_like(f)
    if hp:
        r = np.maximum(f, 1.0) / hp
        g *= np.where(r < 1, r ** (slope / 6.02), 1.0)
    if lp:
        r = f / lp
        g *= np.where(r > 1, np.maximum(r, 1e-9) ** (-slope / 6.02), 1.0)
    if x.ndim == 2:
        g = g[:, None]
    return np.fft.irfft(X * g, n, axis=0)


def cut(x, t, secs):
    a = int(t * SR)
    return x[a:a + int(secs * SR)].copy()


def fades(x, fin, fout):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    sh = (slice(None),) if x.ndim == 1 else (slice(None), None)
    if a > 0:
        x[:a] *= (np.linspace(0, 1, a) ** 2)[sh]
    if b > 0:
        x[-b:] *= (np.linspace(1, 0, b) ** 2)[sh]
    return x


def loopify(x, xf):
    """Equal-power crossfade of the last `xf` seconds into the first: a seamless loop."""
    c = int(xf * SR)
    body, tail = x[:-c].copy(), x[-c:]
    t = np.linspace(0, np.pi / 2, c)
    if x.ndim == 2:
        t = t[:, None]
    body[:c] = body[:c] * np.sin(t) + tail * np.cos(t)
    return body


def slow(x, k):
    """Play back at rate k (<1: slower and lower, as a tape would): a bigger timber."""
    n = x.shape[0]
    m = int(n / k)
    src = np.arange(m) * k
    if x.ndim == 1:
        return np.interp(src, np.arange(n), x)
    return np.stack([np.interp(src, np.arange(n), x[:, c]) for c in range(x.shape[1])], axis=1)


def dc(x):
    return x - np.mean(x, axis=0)


def level(rel, x, lufs, peak_db):
    """Write, measure, then scale to `lufs` integrated with the true peak kept under `peak_db`."""
    p = save(rel, x)
    i, pk = ebur(p)
    g = lufs - i
    g = min(g, peak_db - pk)
    save(rel, x * 10 ** (g / 20))
    return p


def mix_at(dst, src, at, gain=1.0):
    a = int(at * SR)
    n = min(src.shape[0], dst.shape[0] - a)
    dst[a:a + n] += src[:n] * gain
    return dst


# ── the cuts ────────────────────────────────────────────────────────────────
# Levels: what the synthesised files measured (ffmpeg ebur128, integrated), so
# the game's gains (tool_belt SFX.cs, underground creakGain, soundscape
# breathGain/suitGain) keep the mix where it was. The creaks and groans are
# mono now (3D sources); they are written at the stereo files' number, which
# leaves a few dB in hand for the distance falloff they now get.

def build(src):
    cache = {}

    def get(name, ch=2):
        k = (name, ch)
        if k not in cache:
            cache[k] = load(os.path.join(src, name), ch)
        return cache[k]

    out = {}

    # laser_hiss: a plasma cutter cutting sheet metal, one long steady cut; the hiss above 300 Hz (the shop's floor below it filtered off)
    x = cut(get("fs_733483.mp3"), HISS[0], HISS[1] + HISS[2])
    x = fft_filter(dc(x), hp=300, lp=8000)
    out["foley/laser_hiss.ogg"] = level("foley/laser_hiss.ogg", loopify(x, HISS[2]), -23.8, -3.0)

    # laser_crackle: a long straight weld's sparks; the crackle, 700 Hz-9 kHz
    x = cut(get("fs_453690.mp3"), CRACKLE[0], CRACKLE[1] + CRACKLE[2])
    x = fft_filter(dc(x), hp=700, lp=9000, slope=18)
    out["foley/laser_crackle.ogg"] = level("foley/laser_crackle.ogg", loopify(x, CRACKLE[2]), -25.0, -2.0)

    # laser_rumble: the ground itself shaking (a geophone in the sand), under
    # 160 Hz, with a granite saw's grind in the stone, 200-900 Hz, on top
    g = cut(get("fs_613617.mp3"), RUMBLE_GEO[0], RUMBLE_GEO[1] + RUMBLE_GEO[2])
    g = fft_filter(dc(g), hp=22, lp=160, slope=18)
    g *= np.linspace(10 ** (-RUMBLE_GEO[3] / 40), 10 ** (RUMBLE_GEO[3] / 40), g.shape[0])[:, None]   # its slow fade evened
    s = cut(get(RUMBLE_SAW[0]), RUMBLE_SAW[1], RUMBLE_SAW[2] + RUMBLE_GEO[2])
    s = fft_filter(dc(s), hp=200, lp=900, slope=18)
    s *= np.sqrt(np.mean(g ** 2)) / (np.sqrt(np.mean(s ** 2)) + 1e-12) * RUMBLE_SAW[3]
    out["foley/laser_rumble.ogg"] = level("foley/laser_rumble.ogg", loopify(g + s, RUMBLE_GEO[2]), -28.0, -3.0)

    # cave_creak_1..3: heavy old timbers creaking under load, slowed (a bigger
    # beam, deeper); the room's rumble under 250 Hz filtered off before
    for i, (name, t, secs, k) in enumerate(CREAKS, 1):
        x = cut(get(name, 1), t, secs)
        x = fft_filter(dc(x), hp=250, lp=3500, slope=18)
        x = fades(slow(x, k), 0.01, 0.25)
        out["ambience/cave_creak_%d.ogg" % i] = level("ambience/cave_creak_%d.ogg" % i, x, -23.7, -3.0)

    # cave_groan_1..2: a deep rumble swelling and dying (lake ice under
    # stress; the ground itself through a geophone), and grit trickling down a
    # pile of gravel after it
    for i, (rname, gt, secs, (gname, tt, ts), at, gain) in enumerate(GROANS, 1):
        x = cut(get(rname, 1), gt, secs)
        x = fft_filter(dc(x), hp=20, lp=220 if rname == "fs_613617.mp3" else 700, slope=18)
        e = np.sin(np.pi * np.clip(np.arange(x.shape[0]) / x.shape[0], 0, 1)) ** 1.6
        x *= e
        grit = cut(get(gname, 1), tt, ts)
        grit = fades(fft_filter(dc(grit), hp=900, slope=12), 0.02, 0.3)
        grit *= np.sqrt(np.mean(x ** 2)) / (np.sqrt(np.mean(grit ** 2)) + 1e-12) * gain
        x = mix_at(x, grit, at * secs)
        x = fades(x, 0.05, 0.4)
        out["ambience/cave_groan_%d.ogg" % i] = level("ambience/cave_groan_%d.ogg" % i, x, -24.5, -1.5)

    # breath_calm: a man breathing slowly through a respirator mask, two
    # whole breaths; the loop's seam in the pause after an exhale
    t0, t1, xf = BREATH_CALM
    x = cut(get("fs_426297.mp3"), t0, t1 - t0 + xf)
    x = fft_filter(dc(x), hp=90, lp=6000)
    out["sfx/breath_calm.ogg"] = level("sfx/breath_calm.ogg", loopify(x, xf), -29.1, -6.0)

    # breath_heavy: hard breathing in a heavy mask, three breaths
    t0, t1, xf = BREATH_HEAVY
    x = cut(get("fs_256519.mp3"), t0, t1 - t0 + xf)
    x = fft_filter(dc(x), hp=90)
    out["sfx/breath_heavy.ogg"] = level("sfx/breath_heavy.ogg", loopify(x, xf), -27.2, -6.0)

    # suit_hum: a quiet computer fan, close
    t0, secs, xf = SUIT
    x = cut(get("fs_165530.mp3"), t0, secs + xf)
    x = fft_filter(dc(x), hp=60, lp=6000)
    out["sfx/suit_hum.ogg"] = level("sfx/suit_hum.ogg", loopify(x, xf), -34.6, -12.0)
    return out


def stats():
    for rel in OUTPUTS:
        p = os.path.join(AUDIO, rel)
        x = load(p, 2)
        m = x.mean(axis=1)
        i, pk = ebur(p)
        rms = 20 * np.log10(np.sqrt(np.mean(m ** 2)) + 1e-12)
        mag = np.abs(np.fft.rfft(m))
        f = np.fft.rfftfreq(m.size, 1 / SR)
        cen = (f * mag).sum() / (mag.sum() + 1e-12)
        ch = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=channels", "-of", "csv=p=0", p],
                            capture_output=True, text=True).stdout.strip()
        line = "%-28s %s ch %6.2f s  I %6.1f LUFS  true peak %6.1f dBFS  rms %6.1f  centroid %5.0f Hz" % (
            rel, ch, len(m) / SR, i, pk, rms, cen)
        if rel in LOOPS:
            # 100 ms envelope across the seam vs. its spread inside the loop
            w = int(0.1 * SR)
            env = 20 * np.log10(np.sqrt(np.convolve(np.r_[m, m[:w]] ** 2, np.ones(w) / w, "valid")) + 1e-9)
            line += "  seam step %.4f  env %.1f dB spread" % (abs(m[0] - m[-1]), np.percentile(env, 95) - np.percentile(env, 5))
        print(line)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--stats" not in sys.argv or args:
        if not args:
            sys.exit(__doc__)
        build(args[0])
    stats()
