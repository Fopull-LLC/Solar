#!/usr/bin/env python3
"""build_plant_audio.py — airlocks, alarms and machinery, cut from real recordings.

    python3 tools/build_plant_audio.py <source dir> [--stats]

The base's plant: the airlock's pump and its cycle-complete chime, the reactor
and depressurisation klaxon, the air and fire alarm bell, the coolant pump,
the turbo-generator, the reactor hall's transformer hum, steam leaking and a
relief valve lifting, a feed pump's failing bearing, ventilation fans, the
rock crusher, the smelter's burner and the roar of a breach. Every one is a
field or foley recording, CC0 1.0 on freesound.org (the licence was read on
each sound's own page and its description checked for a recording of the real
thing, 2026-11-11; audio/SOURCES.md has the table); nothing here is
synthesised.

    fs_480898.mp3   "Submarine submersion alarm_mono_wave.wav" by Guialgarve:
                    the dive alarm of an old Brazilian submarine. #480898
    fs_438239.mp3   "G20-24-Fire Alarm.wav" by craigsmith: a fire alarm bell,
                    long steady mechanical ringing with a slight buzz. #438239
    fs_172603.mp3   "20121228 kijjaz - Swimming Pool Pump 02.flac" by kijjaz:
                    a swimming pool's electric water pump (Zoom H1). #172603
    fs_637714.mp3   "motor turbine loud mono.flac" by kyles: an electric
                    motor-driven turbine, a steady whine near 1 kHz. #637714
    fs_675727.mp3   "S28-19 Engine room; high whine from turbines.wav" by
                    craigsmith: a ship's engine room, the turbines' whine. #675727
    fs_453445.mp3   "hum electric transformer in large room2.flac" by kyles:
                    an electrical transformer humming in a large room. #453445
    fs_686057.mp3   "d_s478_idlesteamhiss.wav" by relwin: steam locomotive 478
                    idling; from 23 s a valve is open and steam roars out
                    steadily. #686057
    fs_493558.mp3   "steam_safety_valve.wav" by Engineer_815: the safety valve
                    of an industrial 1000 hp boiler lifting at high pressure
                    (Samsung S9). #493558
    fs_613157.mp3   "MACHFan_industrial_fan_defect_bearing_rough_noise_Olympus
                    _LS-P4.wav" by DBS_Sounds: an industrial fan with a broken
                    bearing. #613157
    fs_384335.mp3   "Noisy Fan.wav" by Beethovenboy: a large industrial fan in a
                    powder-coating warehouse. #384335
    fs_59244.mp3    "quarry_close_up.aif" by f_ilippo: the machine breaking
                    rocks into gravel and sand at a quarry on the Sava near
                    Belgrade (Schoeps M/S). #59244
    fs_765947.mp3   "Gas Forge" by SoundDesigner0101: a gas forge burning.
                    #765947
    fs_708043.mp3   "air compressor hose" by mycompasstv: air released from an
                    industrial compressor's jackhammer hose. #708043
    fs_221515.mp3   "service bell ring" by AlaskaRobotics: one sustained ring of
                    a metal service bell (Marantz PMD660, Roland DR-20). #221515

Fetch each HQ preview into <source dir> (the originals need a freesound login;
the previews are the same recordings):

    curl -L -o fs_480898.mp3 https://cdn.freesound.org/previews/480/480898_10296283-hq.mp3
    curl -L -o fs_438239.mp3 https://cdn.freesound.org/previews/438/438239_2524442-hq.mp3
    curl -L -o fs_172603.mp3 https://cdn.freesound.org/previews/172/172603_26950-hq.mp3
    curl -L -o fs_637714.mp3 https://cdn.freesound.org/previews/637/637714_612689-hq.mp3
    curl -L -o fs_675727.mp3 https://cdn.freesound.org/previews/675/675727_2524442-hq.mp3
    curl -L -o fs_453445.mp3 https://cdn.freesound.org/previews/453/453445_612689-hq.mp3
    curl -L -o fs_686057.mp3 https://cdn.freesound.org/previews/686/686057_1024769-hq.mp3
    curl -L -o fs_493558.mp3 https://cdn.freesound.org/previews/493/493558_10345385-hq.mp3
    curl -L -o fs_613157.mp3 https://cdn.freesound.org/previews/613/613157_13589881-hq.mp3
    curl -L -o fs_384335.mp3 https://cdn.freesound.org/previews/384/384335_5931043-hq.mp3
    curl -L -o fs_59244.mp3 https://cdn.freesound.org/previews/59/59244_745228-hq.mp3
    curl -L -o fs_765947.mp3 https://cdn.freesound.org/previews/765/765947_15695818-hq.mp3
    curl -L -o fs_708043.mp3 https://cdn.freesound.org/previews/708/708043_3902754-hq.mp3
    curl -L -o fs_221515.mp3 https://cdn.freesound.org/previews/221/221515_1282865-hq.mp3

Outputs (MONO 44.1 kHz Ogg Vorbis q5, audio/plant/; 3D sources in the world):
loops at about -24 LUFS integrated, the two alarms at about -20 LUFS, the
one-shots at -20 LUFS, every true peak at or under -1 dBFS (where the peak
limit is reached first the file is quieter than its target; --stats shows it).
Loops are crossfaded tail-into-head (equal power), so they have no seam; the
klaxon's seam sits in the silence between two blasts.

--stats prints each output's length, true peak, integrated loudness and, for
loops, the half-second RMS through the seam against the spread inside the
loop. Check by numbers, never by playing them aloud.
"""
import os
import re
import subprocess
import sys

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio", "plant")

# Found from 0.1-1 s envelopes and spectra of each source: steady stretches for
# the loops (no voices, knocks or speed changes inside), the alarm's seam in a
# gap between blasts.
# (name, source, seam at s, seam at s, crossfade s, high-pass Hz, low-pass Hz, LUFS)
# The loop is t1 - t0 long; the crossfade's tail is cut from just after t1.
LOOPS = [
    ("alarm_klaxon", "fs_480898.mp3", 7.90, 12.30, 0.20, 150, 9000, -20.0),
    ("alarm_buzzer", "fs_438239.mp3", 8.00, 12.00, 0.50, 300, 12000, -20.0),
    ("pump_motor", "fs_172603.mp3", 1.00, 11.00, 1.00, 60, 9000, -24.0),
    ("pump_whine", "fs_637714.mp3", 0.50, 10.50, 1.00, 80, 10000, -24.0),
    ("turbine_whine", "fs_675727.mp3", 3.00, 13.00, 1.00, 50, 10000, -24.0),
    ("transformer_hum", "fs_453445.mp3", 6.00, 16.00, 1.00, 50, 6000, -24.0),
    ("steam_leak", "fs_686057.mp3", 24.00, 31.00, 1.00, 300, 15000, -24.0),
    ("bearing_rattle", "fs_613157.mp3", 4.00, 12.00, 1.00, 50, 10000, -24.0),
    ("fan_loop", "fs_384335.mp3", 3.00, 13.00, 1.00, 40, 8000, -24.0),
    ("crusher_loop", "fs_59244.mp3", 2.00, 14.00, 1.00, 35, 10000, -24.0),
    ("furnace_roar", "fs_765947.mp3", 3.00, 13.00, 1.00, 40, 10000, -24.0),
    ("vent_roar", "fs_708043.mp3", 0.80, 7.80, 1.00, 120, 14000, -24.0),
]
# (name, source, start s, length s, high-pass Hz, low-pass Hz, fade in s, fade out s, LUFS)
ONESHOTS = [
    ("relief_valve", "fs_493558.mp3", 1.35, 4.00, 120, 14000, 0.01, 0.6, -20.0),
    ("airlock_chime", "fs_221515.mp3", 0.15, 1.90, 200, 14000, 0.002, 0.5, -20.0),
]
PEAK = -1.0          # dBFS, true peak


# ── io ──────────────────────────────────────────────────────────────────────

def load(path):
    """Mono (the channels averaged; an M/S pair's sum is its mid), 44.1 kHz."""
    b = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR),
                        "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(b, dtype=np.float32).astype(np.float64)


def save(name, x):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1",
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


def cut(x, t, secs):
    a = int(round(t * SR))
    return x[a:a + int(round(secs * SR))].copy()


def fades(x, fin, fout):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a > 0:
        x[:a] *= np.linspace(0, 1, a) ** 2
    if b > 0:
        x[-b:] *= np.linspace(1, 0, b) ** 2
    return x


def loopify(x, xf):
    """Equal-power crossfade of the last `xf` seconds into the first: a seamless loop."""
    c = int(round(xf * SR))
    body, tail = x[:-c].copy(), x[-c:]
    t = np.linspace(0, np.pi / 2, c)
    body[:c] = body[:c] * np.sin(t) + tail * np.cos(t)
    return body


def level(name, x, lufs, peak_db):
    """Write, measure, then scale to `lufs` integrated with the true peak kept under `peak_db`."""
    p = save(name, x)
    i, pk = ebur(p)
    g = min(lufs - i, peak_db - pk)
    save(name, x * 10 ** (g / 20))
    i2, pk2 = ebur(p)
    if pk2 > peak_db:                       # vorbis can land a little over: trim once more
        save(name, x * 10 ** ((g + peak_db - pk2 - 0.05) / 20))
    return p


def build(src):
    cache = {}

    def get(f):
        if f not in cache:
            cache[f] = load(os.path.join(src, f))
        return cache[f]

    for name, f, t0, t1, xf, hp, lp, lufs in LOOPS:
        x = cut(get(f), t0, t1 - t0 + xf)
        x = fft_filter(x - np.mean(x), hp=hp, lp=lp)
        level(name, loopify(x, xf), lufs, PEAK)

    for name, f, t, secs, hp, lp, fin, fout, lufs in ONESHOTS:
        x = cut(get(f), t, secs)
        x = fft_filter(x - np.mean(x), hp=hp, lp=lp)
        level(name, fades(x - np.mean(x), fin, fout), lufs, PEAK)


def source_loudness(src):
    """Integrated loudness of each cut before levelling (mono, filtered, not yet scaled)."""
    for name, f, t0, t1, *_ in LOOPS:
        x = cut(load(os.path.join(src, f)), t0, t1 - t0)
        p = save("_probe", x)
        print("%-16s source cut %6.1f LUFS" % (name, ebur(p)[0]))
    for name, f, t, secs, *_ in ONESHOTS:
        x = cut(load(os.path.join(src, f)), t, secs)
        p = save("_probe", x)
        print("%-16s source cut %6.1f LUFS" % (name, ebur(p)[0]))
    os.remove(os.path.join(OUT, "_probe.ogg"))


def stats():
    loops = {c[0] for c in LOOPS}
    for name in [c[0] for c in LOOPS] + [c[0] for c in ONESHOTS]:
        p = os.path.join(OUT, name + ".ogg")
        x = load(p)
        i, pk = ebur(p)
        line = "%-16s %5.2f s  I %6.1f LUFS  true peak %5.1f dBFS" % (name, len(x) / SR, i, pk)
        if name in loops:
            # half-second RMS windows stepped by 0.25 s round the loop (wrapping),
            # the ones that straddle the seam against all of them
            w, s = SR // 2, SR // 4
            y = np.r_[x, x[:w]]
            rms = np.array([20 * np.log10(np.sqrt(np.mean(y[a:a + w] ** 2)) + 1e-12)
                            for a in range(0, len(x), s)])
            seam = [rms[-2], rms[-1], rms[0]]    # the last half second, the one across the seam, the first
            line += "  0.5 s RMS %.1f..%.1f dB, before/across/after the seam %s  step %.4f" % (
                rms.min(), rms.max(), "/".join("%.1f" % v for v in seam), abs(x[0] - x[-1]))
        print(line)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--stats" not in sys.argv or args:
        if not args:
            sys.exit(__doc__)
        build(args[0])
        if "--source" in sys.argv:
            source_loudness(args[0])
    stats()
