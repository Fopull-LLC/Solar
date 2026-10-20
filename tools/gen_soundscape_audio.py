#!/usr/bin/env python3
"""Synthesize Solar's ambience, music and the few effects no CC0 pack had.

Everything is made here from numbers — noise shaped in the frequency domain,
additive pads, decaying sine bells, a convolution reverb from decaying noise —
so the files are deterministic (fixed seeds), carry no licence but the
project's own, and need nothing but numpy and ffmpeg (for the Ogg Vorbis
encode).

    audio/ambience/wind_low.ogg     40 s seamless loop: the body of the wind
    audio/ambience/wind_gust.ogg    40 s seamless loop: whistling gusts, for thick air
    audio/ambience/underwater.ogg   30 s seamless loop: the sea, from inside it
    audio/music/drift.ogg           ~2 min calm pad pieces, faded both ends,
    audio/music/far_shore.ogg       meant to be played one at a time with long
    audio/music/low_orbit.ogg       silences between them (soundscape.lua)
    audio/sfx/swim_stroke_1..4.ogg  a hand pulling through water
    audio/sfx/bubbles_1..3.ogg      a breath's worth of bubbles
    audio/sfx/vessel_lost.ogg       the sting under "VESSEL LOST"

Nobody should audition these through speakers to check them: `--stats` prints
duration, sample peak, RMS, an approximate integrated loudness (K-weighted,
ungated) and the spectral centroid of every file, which is how they were
levelled.

    python3 tools/gen_soundscape_audio.py            # write everything
    python3 tools/gen_soundscape_audio.py --stats    # just measure what is on disk
"""
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 44100
ROOT = Path(__file__).resolve().parent.parent / "audio"


# ── building blocks ──────────────────────────────────────────────────────────

def shaped_noise(n, rng, lo, hi, tilt=-1.0):
    """White noise band-limited to [lo, hi] Hz with a spectral tilt. Circular:
    an irfft of a shaped spectrum is periodic in n, so it loops seamlessly."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    f[0] = 1.0
    g = (f / 1000.0) ** (tilt / 2.0)
    g *= 1 / (1 + (lo / f) ** 4)
    g *= 1 / (1 + (f / hi) ** 4)
    g[0] = 0.0
    x = np.fft.irfft(spec * g, n)
    return x / (np.abs(x).max() + 1e-9)


def band_noise(n, rng, centre, q):
    """A resonant band of noise — the whistle in a gust. Circular."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    bw = centre / q
    g = 1 / (1 + ((f - centre) / (bw / 2)) ** 2)
    x = np.fft.irfft(spec * g, n)
    return x / (np.abs(x).max() + 1e-9)


def loop_lfo(n, cycles, phase=0.0):
    """A sine with a whole number of cycles over n samples: 0..1, loop-safe."""
    t = np.arange(n) / n
    return 0.5 + 0.5 * np.sin(2 * np.pi * cycles * t + phase)


def env(n, attack, hold, decay):
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1) ** 2
    d = np.exp(-np.clip(t - attack - hold, 0, None) / max(decay, 1e-4))
    return a * d


def lowpass_fft(x, hz, order=2):
    spec = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(x.shape[0], 1 / SR)
    g = 1 / np.sqrt(1 + (f / hz) ** (2 * order))
    if x.ndim == 2:
        g = g[:, None]
    return np.fft.irfft(spec * g, x.shape[0], axis=0)


def reverb(x, seconds=3.6, mix=0.35, seed=3, damp_hz=3800.0):
    """Stereo convolution reverb: an impulse of decaying, darkening noise.
    x is (n, 2); returns (n + tail, 2)."""
    rng = np.random.default_rng(seed)
    m = int(seconds * SR)
    t = np.arange(m) / SR
    decay = np.exp(-6.9 * t / seconds)            # -60 dB at `seconds`
    ir = rng.standard_normal((m, 2)) * decay[:, None]
    ir = lowpass_fft(ir, damp_hz, order=1)
    ir[: int(0.012 * SR)] = 0.0                    # pre-delay
    ir /= np.sqrt((ir ** 2).sum(axis=0, keepdims=True)) + 1e-9
    n = x.shape[0] + m
    size = 1 << int(np.ceil(np.log2(n)))
    wet = np.fft.irfft(np.fft.rfft(x, size, axis=0) * np.fft.rfft(ir, size, axis=0), size, axis=0)[:n]
    dry = np.zeros((n, 2))
    dry[: x.shape[0]] = x
    return dry * (1 - mix) + wet * mix


def pan(mono, p):
    """Equal-power pan, p in -1..1."""
    a = (p + 1) * np.pi / 4
    return np.stack([mono * np.cos(a), mono * np.sin(a)], axis=1)


def fade(x, fin, fout):
    n = x.shape[0]
    g = np.ones(n)
    a, b = int(fin * SR), int(fout * SR)
    if a:
        g[:a] = np.sin(np.linspace(0, np.pi / 2, a)) ** 2
    if b:
        g[n - b:] = np.cos(np.linspace(0, np.pi / 2, b)) ** 2
    return x * (g[:, None] if x.ndim == 2 else g)


def k_loudness(x):
    """Approximate integrated loudness (LUFS): K-weighting applied in the
    frequency domain (38 Hz high-pass, +4 dB shelf above ~1.5 kHz), ungated
    mean square, summed over channels. Close to BS.1770 for steady material."""
    x = x if x.ndim == 2 else x[:, None]
    spec = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(x.shape[0], 1 / SR)
    f[0] = 1.0
    hp = 1 / np.sqrt(1 + (38.0 / f) ** 4)
    shelf = 10 ** ((4.0 / (1 + (1500.0 / f) ** 2)) / 20)
    y = np.fft.irfft(spec * (hp * shelf)[:, None], x.shape[0], axis=0)
    ms = (y ** 2).mean(axis=0).sum()
    return -0.691 + 10 * np.log10(ms + 1e-20)


def level(x, lufs=None, peak_db=-1.0):
    """Scale to a target loudness, never letting the sample peak past peak_db."""
    g = 1.0
    if lufs is not None:
        g = 10 ** ((lufs - k_loudness(x)) / 20)
    pk = np.abs(x).max() * g
    ceiling = 10 ** (peak_db / 20)
    if pk > ceiling:
        g *= ceiling / pk
    return x * g


# ── ambience ─────────────────────────────────────────────────────────────────

def wind_low(seconds=40.0, seed=21):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        body = shaped_noise(n, rng, 45, 700, tilt=-2.2)
        # Gusts: a few incommensurate (but whole-cycle, so loop-safe) swells.
        g = 0.45 + 0.25 * loop_lfo(n, 3, rng.uniform(0, 6)) + 0.18 * loop_lfo(n, 7, rng.uniform(0, 6)) \
            + 0.12 * loop_lfo(n, 11, rng.uniform(0, 6))
        air = shaped_noise(n, rng, 400, 2600, tilt=-1.0) * 0.18 * loop_lfo(n, 5, rng.uniform(0, 6))
        out.append(body * g + air)
    return level(np.stack(out, axis=1), lufs=-24.0, peak_db=-3.0)


def wind_gust(seconds=40.0, seed=33):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    out = []
    for ch in range(2):
        x = np.zeros(n)
        for centre, q, cyc in ((480, 9, 2), (690, 11, 3), (930, 13, 5), (1270, 15, 4)):
            c = centre * rng.uniform(0.96, 1.04)
            sw = loop_lfo(n, cyc, rng.uniform(0, 6)) ** 3          # mostly quiet, then a howl
            x += band_noise(n, rng, c, q) * sw * rng.uniform(0.6, 1.0)
        x += shaped_noise(n, rng, 900, 6000, tilt=-0.6) * 0.12 * loop_lfo(n, 6, rng.uniform(0, 6)) ** 2
        out.append(x)
    return level(np.stack(out, axis=1), lufs=-27.0, peak_db=-4.0)


def underwater(seconds=30.0, seed=45):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    base = []
    for ch in range(2):
        rumble = shaped_noise(n, rng, 25, 320, tilt=-2.5)
        rumble *= 0.7 + 0.3 * loop_lfo(n, 4, rng.uniform(0, 6))
        base.append(rumble)
    x = np.stack(base, axis=1)
    # A few distant bubbles, placed circularly so the loop seam is clean.
    for _ in range(14):
        b = bubble_burst(rng, count=rng.integers(1, 4), spread=0.25) * rng.uniform(0.05, 0.14)
        b = lowpass_fft(b, 1400.0)
        at = rng.integers(0, n)
        p = pan(b, rng.uniform(-0.8, 0.8))
        idx = (np.arange(p.shape[0]) + at) % n
        x[idx] += p
    return level(x, lufs=-27.0, peak_db=-4.0)


# ── effects ──────────────────────────────────────────────────────────────────

def one_bubble(rng):
    """A bubble is a sine whose pitch rises as it decays (Minnaert)."""
    f0 = rng.uniform(380, 1300)
    dur = rng.uniform(0.04, 0.11)
    n = int(dur * 3 * SR)
    t = np.arange(n) / SR
    f = f0 * (1 + 2.2 * t / dur * 0.35)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t / dur) * np.clip(t / 0.002, 0, 1)


def bubble_burst(rng, count=6, spread=0.5):
    n = int((spread + 0.5) * SR)
    x = np.zeros(n)
    for _ in range(count):
        b = one_bubble(rng) * rng.uniform(0.4, 1.0)
        at = int(rng.uniform(0, spread) * SR)
        x[at: at + b.size] += b[: n - at]
    return x


def bubbles(seed):
    rng = np.random.default_rng(seed)
    x = bubble_burst(rng, count=int(rng.integers(5, 10)), spread=0.55)
    st = np.stack([x, np.roll(x, int(0.004 * SR))], axis=1)
    return level(fade(st, 0.0, 0.08), peak_db=-8.0)


def swim_stroke(seed):
    rng = np.random.default_rng(seed)
    n = int(0.9 * SR)
    pull = shaped_noise(n, rng, 220, 3200, tilt=-1.4) * env(n, rng.uniform(0.06, 0.12), 0.05, 0.18)
    drip = shaped_noise(n, rng, 1800, 9000, tilt=-0.4) * env(n, 0.18, 0.02, 0.22) * 0.25
    slosh = shaped_noise(n, rng, 60, 500, tilt=-2.0) * env(n, 0.09, 0.04, 0.2) * 0.6
    x = pull + drip + slosh
    b = bubble_burst(rng, count=2, spread=0.3)[:n]
    x[: b.size] += b * 0.15
    p = rng.uniform(-0.25, 0.25)
    return level(fade(pan(x, p), 0.0, 0.1), peak_db=-6.0)


def vessel_lost(seed=77):
    """A low boom, then a slow falling minor figure under a long reverb."""
    rng = np.random.default_rng(seed)
    n = int(5.5 * SR)
    t = np.arange(n) / SR
    boom = np.sin(2 * np.pi * (52 - 14 * np.clip(t / 1.2, 0, 1)) * t) * env(n, 0.006, 0.05, 0.9)
    boom += shaped_noise(n, rng, 30, 260, tilt=-2.0) * env(n, 0.004, 0.02, 0.5) * 0.7
    mono = boom * 0.9
    st = pan(mono, 0.0)
    # Falling figure: A4 → F4 → D4 over an A minor drone, each a soft bell.
    notes = [(0.35, 440.00), (1.15, 349.23), (1.95, 293.66)]
    for at, f in notes:
        m = n - int(at * SR)
        tt = np.arange(m) / SR
        bell = (np.sin(2 * np.pi * f * tt) + 0.25 * np.sin(2 * np.pi * f * 2.0 * tt)
                + 0.08 * np.sin(2 * np.pi * f * 3.01 * tt)) * env(m, 0.01, 0.0, 1.6)
        s = int(at * SR)
        st[s:] += pan(bell * 0.32, rng.uniform(-0.3, 0.3))
    drone_f = [110.0, 164.81, 220.0]
    pad = sum(np.sin(2 * np.pi * f * t * (1 + d)) for f in drone_f for d in (-0.002, 0.002))
    st += pan(pad * env(n, 0.8, 1.6, 1.6) * 0.05, 0.0)
    wet = reverb(st, seconds=3.2, mix=0.32, seed=seed)
    return level(fade(wet, 0.0, 1.0), peak_db=-2.0)


# ── music ────────────────────────────────────────────────────────────────────

def hz(note):
    """'A3' / 'F#2' → Hz (A4 = 440)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    k = names[note[0]]
    rest = note[1:]
    if rest[0] == "#":
        k += 1
        rest = rest[1:]
    elif rest[0] == "b":
        k -= 1
        rest = rest[1:]
    return 440.0 * 2 ** ((k + 12 * (int(rest) - 4)) / 12)


def pad_voice(f, n, rng, bright=1.0):
    """Additive soft-saw: harmonics rolled off hard, three detuned copies."""
    t = np.arange(n) / SR
    x = np.zeros(n)
    for det in (-0.0016, 0.0, 0.0017):
        ff = f * (1 + det)
        for h in range(1, 9):
            fh = ff * h
            if fh > 5000:
                break
            amp = (1 / h ** 1.7) * (1 / (1 + (fh / (1400 * bright)) ** 2))
            x += amp * np.sin(2 * np.pi * fh * t + rng.uniform(0, 2 * np.pi))
    return x / 3


def bell(f, n, rng):
    t = np.arange(n) / SR
    x = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * f * 2.0 * t)
         + 0.1 * np.sin(2 * np.pi * f * 2.76 * t) + 0.04 * np.sin(2 * np.pi * f * 5.4 * t))
    return x * env(n, 0.006, 0.0, rng.uniform(1.8, 3.2))


def piece(chords, chord_s, bells_per, scale, seed, bright=1.0, cycles=2):
    rng = np.random.default_rng(seed)
    seq = chords * cycles
    total = len(seq) * chord_s + 8.0
    n = int(total * SR)
    out = np.zeros((n, 2))
    step = int(chord_s * SR)
    attack, release = 3.5, 5.0
    for i, ch in enumerate(seq):
        s = i * step
        m = min(n - s, step + int(release * SR))
        e = env(m, attack, chord_s - attack, release / 3.0)
        for j, note in enumerate(ch):
            v = pad_voice(hz(note), m, rng, bright) * e * (0.9 if j == 0 else 0.55)
            out[s: s + m] += pan(v, (j / max(1, len(ch) - 1) - 0.5) * 0.9)
        # Sparse bells over the chord: a few notes, never on the downbeat.
        k = rng.integers(bells_per[0], bells_per[1] + 1)
        for _ in range(k):
            at = s + int(rng.uniform(2.0, chord_s - 1.0) * SR)
            f = hz(scale[rng.integers(0, len(scale))])
            bm = min(n - at, int(4.0 * SR))
            out[at: at + bm] += pan(bell(f, bm, rng) * 0.22, rng.uniform(-0.6, 0.6))
    # A sub drone on the first chord's root, breathing slowly.
    root = hz(chords[0][0]) / 2 if hz(chords[0][0]) > 70 else hz(chords[0][0])
    t = np.arange(n) / SR
    drone = np.sin(2 * np.pi * root * t) * (0.5 + 0.5 * np.sin(2 * np.pi * t / 23.0)) * 0.12
    out += pan(drone, 0.0)
    out = lowpass_fft(out, 4200.0, order=1)
    out = reverb(out, seconds=4.2, mix=0.38, seed=seed + 1)
    out = fade(out, 6.0, 12.0)
    return level(out, lufs=-24.0, peak_db=-3.0)


def drift():
    chords = [["D3", "A3", "E4", "F#4", "A4"],
              ["G2", "D3", "F#3", "A3", "B3"],
              ["B2", "F#3", "D4", "A4", "C#5"],
              ["A2", "E3", "B3", "C#4", "E4"]]
    scale = ["D5", "E5", "F#5", "A5", "B5", "C#6"]
    return piece(chords, 14.0, (1, 3), scale, seed=101)


def far_shore():
    chords = [["E2", "B2", "G3", "D4", "F#4"],
              ["C3", "G3", "B3", "E4"],
              ["A2", "E3", "C4", "G4", "B4"],
              ["B2", "F#3", "A3", "E4"]]
    scale = ["E5", "G5", "A5", "B5", "D6"]
    return piece(chords, 13.0, (0, 2), scale, seed=202, bright=0.85)


def low_orbit():
    chords = [["F2", "C3", "G3", "A3"],
              ["F2", "C3", "B3", "E4"],
              ["D3", "A3", "C4", "E4"],
              ["C3", "G3", "A3", "D4"]]
    scale = ["C5", "D5", "E5", "G5", "A5"]
    return piece(chords, 16.0, (0, 2), scale, seed=303, bright=0.75)


# ── io ───────────────────────────────────────────────────────────────────────

def write_ogg(rel, x):
    dst = ROOT / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    x = x if x.ndim == 2 else x[:, None]
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(pcm.shape[1])
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name,
                        "-c:a", "libvorbis", "-q:a", "4", str(dst)], check=True)
    Path(tmp.name).unlink()
    print(f"wrote audio/{rel} ({dst.stat().st_size // 1024} KB)")


def decode(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "f32le",
                          "-ac", "2", "-ar", str(SR), "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)


def stats(path):
    x = decode(path)
    pk = 20 * np.log10(np.abs(x).max() + 1e-12)
    rms = 20 * np.log10(np.sqrt((x ** 2).mean()) + 1e-12)
    mono = x.mean(axis=1)
    mag = np.abs(np.fft.rfft(mono))
    f = np.fft.rfftfreq(mono.size, 1 / SR)
    cen = (f * mag).sum() / (mag.sum() + 1e-12)
    # Seam check for loops: the jump between the last and first sample.
    seam = np.abs(x[-1] - x[0]).max()
    print(f"{str(path.relative_to(ROOT.parent)):40s} {x.shape[0] / SR:7.2f} s  peak {pk:6.1f} dBFS"
          f"  rms {rms:6.1f} dBFS  ~{k_loudness(x):6.1f} LUFS  centroid {cen:6.0f} Hz  seam {seam:.3f}")


FILES = {
    "ambience/wind_low.ogg": wind_low,
    "ambience/wind_gust.ogg": wind_gust,
    "ambience/underwater.ogg": underwater,
    "music/drift.ogg": drift,
    "music/far_shore.ogg": far_shore,
    "music/low_orbit.ogg": low_orbit,
    "sfx/vessel_lost.ogg": vessel_lost,
    **{f"sfx/swim_stroke_{i}.ogg": (lambda i=i: swim_stroke(500 + i)) for i in (1, 2, 3, 4)},
    **{f"sfx/bubbles_{i}.ogg": (lambda i=i: bubbles(600 + i)) for i in (1, 2, 3)},
}


def main():
    if "--stats" not in sys.argv:
        for rel, make in FILES.items():
            write_ogg(rel, make())
    for rel in FILES:
        stats(ROOT / rel)


if __name__ == "__main__":
    main()
