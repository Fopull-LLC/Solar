#!/usr/bin/env python3
"""The crew warnings' sounds (docs/crew-and-items.md §2.3; scripts/crew_alerts_hud.lua),
synthesised: nothing recorded, nothing downloaded.

    python3 tools/gen_crew_audio.py [--stats]

    audio/sfx/crew_chime.ogg       caution: a two-note descending chime (O2 25 %)
    audio/sfx/crew_alarm.ogg       warning: a master-alarm warble burst (O2 10 %, HEAT)
    audio/sfx/crew_alarm_loop.ogg  the 1 MIN / blackout alarm, a seamless loop
    audio/sfx/crew_heartbeat.ogg   a slow heartbeat, a seamless loop (blackout)
    audio/sfx/crew_sting.ogg       a low, muted sting for a death

Levels as audio/SOURCES.md asks: one-shots peak -1 dBFS with RMS no hotter
than -14 dBFS; loops RMS -18 dBFS. Check with --stats, never by speakers.
"""
import os
import subprocess
import sys
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio", "sfx")


def env(n, a=0.005, r=0.05):
    e = np.ones(n)
    na, nr = int(a * SR), int(r * SR)
    if na:
        e[:na] = np.linspace(0, 1, na)
    if nr:
        e[-nr:] *= np.linspace(1, 0, nr)
    return e


def tone(f, secs, harmonics=((1, 1.0), (2, 0.35), (3, 0.12)), decay=None):
    t = np.arange(int(secs * SR)) / SR
    s = sum(a * np.sin(2 * np.pi * f * k * t) for k, a in harmonics)
    if decay:
        s *= np.exp(-t / decay)
    return s


def level(x, peak_db=-1.0, rms_db=None):
    x = x / max(np.max(np.abs(x)), 1e-9)
    if rms_db is not None:
        rms = np.sqrt(np.mean(x * x))
        x *= min(10 ** (rms_db / 20) / max(rms, 1e-9), 10 ** (peak_db / 20))
    else:
        x *= 10 ** (peak_db / 20)
    return x


def write(name, x):
    os.makedirs(OUT, exist_ok=True)
    wav = os.path.join(OUT, name + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    ogg = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", "5", ogg], check=True)
    os.remove(wav)
    return ogg


def lowpass(x, cutoff):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / (1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))


def chime():
    a = tone(880, 0.45, decay=0.18) * env(int(0.45 * SR), 0.003, 0.05)
    b = tone(660, 0.6, decay=0.25) * env(int(0.6 * SR), 0.003, 0.1)
    x = np.zeros(int(1.0 * SR))
    x[:len(a)] += a
    o = int(0.28 * SR)
    x[o:o + len(b)] += b
    return level(lowpass(x, 5000), -1.0, -16)


def warble(secs):
    t = np.arange(int(secs * SR)) / SR
    f = np.where((t * 4) % 1 < 0.5, 1000.0, 750.0)        # 4 Hz two-tone, like a master alarm
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) + 0.4 * np.sign(np.sin(ph)) * 0.3 + 0.2 * np.sin(2 * ph)
    return lowpass(s, 3500)


def alarm():
    x = warble(1.0) * env(int(1.0 * SR), 0.004, 0.06)
    return level(x, -1.0, -15)


def alarm_loop():
    # 2 s exactly: the 4 Hz warble is periodic in 0.25 s, so the loop is seamless
    x = warble(2.0)
    return level(x, -1.0, -18)


def heartbeat():
    # 60 bpm lub-dub, 2 beats = 2 s, periodic
    n = 2 * SR
    x = np.zeros(n)
    for beat in (0.0, 1.0):
        for off, amp in ((0.0, 1.0), (0.24, 0.65)):
            t0 = int((beat + off) * SR)
            k = np.arange(int(0.16 * SR)) / SR
            thump = np.sin(2 * np.pi * 52 * k) * np.exp(-k / 0.045) * amp
            thump += np.sin(2 * np.pi * 34 * k) * np.exp(-k / 0.07) * amp * 0.6
            x[t0:t0 + len(thump)] += thump[:max(0, min(len(thump), n - t0))]
    return level(lowpass(x, 240), -1.0, -18)


def sting():
    t = np.arange(int(3.0 * SR)) / SR
    s = (np.sin(2 * np.pi * 110 * t) + 0.6 * np.sin(2 * np.pi * 130.8 * t) + 0.4 * np.sin(2 * np.pi * 164.8 * t))
    s *= np.exp(-t / 1.1) * env(len(t), 0.4, 0.8)
    rng = np.random.default_rng(3)
    s += lowpass(rng.normal(0, 0.15, len(t)), 400) * np.exp(-t / 0.8)
    return level(lowpass(s, 900), -3.0, -18)


def stats(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "volumedetect,ebur128", "-f", "null", "-"],
                       capture_output=True, text=True)
    out = r.stderr
    peak = [l for l in out.splitlines() if "max_volume" in l]
    mean = [l for l in out.splitlines() if "mean_volume" in l]
    lufs = [l for l in out.splitlines() if l.strip().startswith("I:")]
    print(os.path.basename(path), (peak[-1].split(":")[-1] if peak else ""), (mean[-1].split(":")[-1] if mean else ""),
          (lufs[-1].strip() if lufs else ""))


if __name__ == "__main__":
    made = [write("crew_chime", chime()), write("crew_alarm", alarm()), write("crew_alarm_loop", alarm_loop()),
            write("crew_heartbeat", heartbeat()), write("crew_sting", sting())]
    if "--stats" in sys.argv:
        for p in made:
            stats(p)
