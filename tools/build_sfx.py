#!/usr/bin/env python3
"""build_sfx.py — cut, clean and level the game's recorded sound effects.

    python3 tools/build_sfx.py <source dir> [--stats]

The sources are real recordings, downloaded by hand (or by the curl lines in
audio/SOURCES.md) into <source dir>:

    bsb_NNNN.flac / .ogg   BigSoundBank.com sound #NNNN (Joseph Sardin, CC0)
    nasa_artemis2_pad_cs4.wav   NASA, Artemis II launch, Pad Camera Site 4
                                (public domain, via Wikimedia Commons)

Each RECIPE below names a slice of one source, how to clean it (filters, a
pitch shift by resampling, fades) and how to level it, and writes one mono
44.1 kHz Ogg Vorbis file under audio/foley/. Loops get an equal-power
crossfade of their tail into their head, so they repeat with no click and no
gap. The wind roar is synthesised (noise shaped in the frequency domain is
periodic by construction, so it loops perfectly).

Levels, so a swap keeps the volumes the scripts already pass:
  * one-shots: peak -1 dBFS, and the loud part's RMS no hotter than -14 dBFS
    (the Kenney clips they replace sit at -10..-19 dBFS RMS);
  * loops: RMS -18 dBFS, peak at most -1 dBFS.
--stats prints each output's length, peak, RMS and integrated LUFS (ffmpeg
ebur128) — check by numbers, never by playing them through speakers.
"""
import os
import subprocess
import sys

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio", "foley")


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
    """Gentle high/low pass (dB per octave beyond the corner)."""
    if not hp and not lp:
        return x
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


def repitch(x, k):
    """Play `k` times faster (k > 1 higher and shorter), by resampling."""
    if k == 1.0:
        return x
    idx = np.arange(0, len(x) - 1, k)
    return np.interp(idx, np.arange(len(x)), x)


def fades(x, fin=0.004, fout=0.05):
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


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)


def loud_rms_db(x):
    """RMS of the loud part (the top 25 % of 10 ms frames) — a click's body."""
    h = int(0.01 * SR)
    n = max(1, len(x) // h)
    fr = np.sqrt(np.mean(x[:n * h].reshape(n, h) ** 2, axis=1))
    top = np.sort(fr)[-max(1, n // 4):]
    return 20 * np.log10(np.sqrt(np.mean(top ** 2)) + 1e-12)


def level(x, loop, limit=0.0):
    if limit:
        # a soft limiter for crackly beds (gravel, an arc): `limit` dB of the
        # transients folded down, so the bed is not 15 dB under its crackles
        x = x / (np.max(np.abs(x)) + 1e-12) * 10 ** (limit / 20)
        x = np.tanh(x)
    pk = np.max(np.abs(x)) + 1e-12
    if loop:
        g = 10 ** ((-18.0 - rms_db(x)) / 20)
    else:
        g = 10 ** ((-14.0 - loud_rms_db(x)) / 20)
    g = min(g, 10 ** (-1.8 / 20) / pk)   # vorbis overshoots ~0.8 dB: -1 dBFS after encoding
    return x * g


def wind_roar(secs=8.0, seed=7):
    """The air tearing past a hull: pink-brown noise with a broad 250-900 Hz
    body and a slow periodic surge, built in the frequency domain so the
    file is exactly periodic (a perfect loop)."""
    rng = np.random.default_rng(seed)
    n = int(secs * SR)
    f = np.fft.rfftfreq(n, 1 / SR)
    mag = 1.0 / np.maximum(f, 20.0) ** 0.75
    mag *= 1.0 + 2.5 * np.exp(-((np.log(np.maximum(f, 1) / 480.0)) ** 2) / 0.5)
    mag *= np.where(f > 3500, (3500 / np.maximum(f, 1)) ** 1.5, 1.0)
    mag[f < 25] = 0
    ph = rng.uniform(0, 2 * np.pi, len(f))
    x = np.fft.irfft(mag * np.exp(1j * ph), n)
    t = np.arange(n) / SR
    surge = 1.0 + 0.18 * np.sin(2 * np.pi * 2 * t / secs) + 0.10 * np.sin(2 * np.pi * 5 * t / secs + 1.3)
    return x * surge


# name: (source id, start s, end s, options)
#   hp/lp Hz, pitch (playback rate), fin/fout fades (s), loop crossfade (s)
RECIPES = {
    # ── rover ──
    # The drive motor: an electric window motor of a Kia Carnival, its steady
    # run between the start and stop clunks. Pitch rides the wheel speed.
    "rover_motor": ("1504", 0.45, 3.05, dict(hp=80, loop=0.35)),
    # The tyres: a mountain bike rolling on a gravel road, recorded on board.
    "rover_gravel": ("1284", 4.0, 12.0, dict(hp=60, loop=0.6, limit=9)),
    # A bump: the chassis landing on its springs (industrial switch, low).
    "rover_bump": ("3061", 0.0, 0.7, dict(pitch=0.75, lp=2500, fout=0.25)),
    # ── rocket ──
    # Artemis II's SLS at full thrust (Pad Camera Site 4), the steady part.
    "rocket_roar": ("nasa", 12.0, 17.6, dict(hp=25, loop=0.6)),
    # The engines lighting: the boosters' ignition and the climb to full roar.
    "rocket_ignite": ("nasa", 7.0, 11.5, dict(hp=25, fin=0.05, fout=1.2)),
    # ── separations, clamps, the end of things ──
    "pyro_bang": ("1808", 0.0, 0.34, dict(fout=0.15)),
    "pyro_far": ("1807", 0.0, 0.26, dict(fout=0.12)),
    "explosion_far": ("1023", 0.0, 3.2, dict(fout=1.0)),
    "clamp_clunk": ("3061", 0.0, 1.0, dict(fout=0.4)),
    "latch_clunk": ("3062", 0.0, 1.0, dict(fout=0.4)),
    "steel_drop": ("1774", 0.08, 1.2, dict(fout=0.5)),
    # ── pneumatics and servos ──
    "hiss_short": ("1490", 0.12, 0.70, dict(fout=0.2)),
    "hiss_seal": ("1491", 0.08, 0.95, dict(fout=0.25)),
    "hiss_cylinder": ("1493", 0.10, 1.20, dict(fout=0.25)),
    "servo_run": ("1502", 0.05, 3.40, dict(fout=0.3)),
    "servo_short": ("1505", 0.05, 1.40, dict(pitch=1.15, fout=0.35)),
    # ── tools ──
    "weld_arc": ("0950", 3.0, 11.0, dict(hp=120, loop=0.5, limit=12)),
    "ratchet_1": ("0964", 0.27, 0.75, dict(fout=0.08)),
    "ratchet_2": ("0964", 2.44, 2.88, dict(fout=0.08)),
    "ratchet_3": ("0964", 4.22, 4.75, dict(fout=0.08)),
    "ratchet_4": ("0964", 6.33, 7.00, dict(fout=0.08)),
    "ratchet_5": ("0964", 8.48, 9.02, dict(fout=0.08)),
    # ── interface: switches, relays, the ledger printer, the radio ──
    "switch_1": ("0321", 0.26, 0.42, dict(fout=0.05)),
    "switch_2": ("0321", 0.78, 0.94, dict(fout=0.05)),
    "switch_3": ("0321", 1.26, 1.42, dict(fout=0.05)),
    "switch_4": ("0321", 1.76, 1.92, dict(fout=0.05)),
    "switch_5": ("0321", 2.34, 2.52, dict(fout=0.05)),
    "toggle_on": ("0036", 0.08, 0.30, dict(fout=0.06)),
    "toggle_off": ("0036", 0.31, 0.52, dict(fout=0.06)),
    "rocker_on": ("0025", 0.26, 0.40, dict(fout=0.05)),
    "rocker_off": ("0025", 0.41, 0.62, dict(fout=0.06)),
    "relay_tick": ("2191", 0.0, 0.09, dict(fout=0.03)),
    "key_strike": ("2842", 0.12, 0.45, dict(fout=0.12)),
    "ticket_print": ("3264", 0.0, 1.45, dict(fout=0.15)),
    "ticket_short": ("3264", 0.0, 0.62, dict(fout=0.18)),
    "buzz_denied": ("3442", 0.0, 0.42, dict(fout=0.08, lp=6000)),
    "quindar_in": ("2380", 0.0, 0.25, dict(fout=0.01, fin=0.003)),
    "quindar_out": ("2381", 0.0, 0.25, dict(fout=0.01, fin=0.003)),
    "radio_crackle": ("2514", 0.15, 1.10, dict(hp=300, lp=5000, fin=0.03, fout=0.3)),
    "radio_squelch": ("2511", 0.22, 0.85, dict(hp=300, lp=5000, fin=0.02, fout=0.2)),
}


def find_src(d, sid):
    if sid == "nasa":
        return os.path.join(d, "nasa_artemis2_pad_cs4.wav")
    for ext in (".flac", ".ogg", ".wav", ".mp3"):
        p = os.path.join(d, "bsb_" + sid + ext)
        if os.path.exists(p):
            return p
    raise FileNotFoundError("source bsb_%s.* not in %s" % (sid, d))


def stats(p):
    x = load(p)
    r = subprocess.run(["ffmpeg", "-nostats", "-i", p, "-af", "ebur128", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    lufs = "?"
    for line in r.splitlines()[::-1]:
        if line.strip().startswith("I:"):
            lufs = line.split()[1]
            break
    h = int(0.1 * SR)
    n = len(x) // h
    fr = 20 * np.log10(np.sqrt(np.mean(x[:n * h].reshape(n, h) ** 2, axis=1)) + 1e-12)
    seam = abs(x[-1] - x[0]) / (np.sqrt(np.mean(x ** 2)) + 1e-12)
    extra = "  100ms-env sd %.1f dB, seam jump %.2f rms" % (np.std(fr), seam)
    return extra + "  %-22s %6.2fs peak %6.1f dBFS rms %6.1f dBFS  %s LUFS" % (
        os.path.basename(p), len(x) / SR, 20 * np.log10(np.max(np.abs(x)) + 1e-12), rms_db(x), lufs)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    src = sys.argv[1]
    cache = {}
    made = []
    for name, (sid, a, b, o) in RECIPES.items():
        if sid not in cache:
            cache[sid] = load(find_src(src, sid))
        x = cache[sid][int(a * SR):int(b * SR)]
        x = x - np.mean(x)
        x = fft_filter(x, o.get("hp", 30.0), o.get("lp", 0.0))
        x = repitch(x, o.get("pitch", 1.0))
        if o.get("loop"):
            x = loopify(x, o["loop"])
        else:
            x = fades(x, o.get("fin", 0.003), o.get("fout", 0.05))
        made.append(save(name, level(x, bool(o.get("loop")), o.get("limit", 0.0))))
    w = wind_roar()
    made.append(save("wind_roar", level(w, True)))
    # The bore's hum: the arc's crackle over a heavy transformer buzz (100 Hz
    # and its harmonics, the sound of a big current), hot enough to sit where
    # the clip it replaces sat (-12 dBFS RMS), so the tool's volumes hold.
    arc = load(os.path.join(OUT, "weld_arc.ogg"))
    n = len(arc)
    t = np.arange(n) / SR
    f0 = round(100 * n / SR) * SR / n          # whole cycles: the loop stays seamless
    buzz = sum(a * np.sin(2 * np.pi * f0 * k * t + k) for k, a in ((1, 1.0), (2, 0.6), (3, 0.45), (4, 0.25), (6, 0.15)))
    hum = np.tanh(2.5 * (arc / (np.max(np.abs(arc)) + 1e-12)) + 0.35 * buzz / np.max(np.abs(buzz)))
    hum = hum / np.sqrt(np.mean(hum ** 2)) * 10 ** (-12.0 / 20)
    hum = hum / max(1.0, np.max(np.abs(hum)) / 10 ** (-2.6 / 20))
    made.append(save("bore_hum", hum))
    if "--stats" in sys.argv:
        for p in made:
            print(stats(p))
    else:
        print("wrote %d files to %s" % (len(made), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
