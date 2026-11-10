#!/usr/bin/env python3
"""build_weather_audio.py — rain, hail, thunder, the surf and the splashes, cut
from real recordings.

    python3 tools/build_weather_audio.py <source dir> [--stats]

Ty, 2026-11-10: "I'd rather you try and find real sound effects instead of
synthesizing ones, especially more complex ones." The weather loops and the
thunder (tools/gen_weather_audio.py) and the sea's surf and splashes
(tools/gen_surf_audio.py) and the sea from inside it (gen_soundscape_audio.py)
were synthesised; these are cut from field
recordings instead, all CC0 1.0 on freesound.org (the licence was read on each
sound's page, 2026-11-10; audio/SOURCES.md has the table):

    fs_200273.mp3   "Rain light 2 (rural)" by jmbphilmes: light rain on open
                    land in Brazil, nothing else (Sennheiser ME66, Tascam
                    HD-P2, mono). freesound #200273
    fs_200272.mp3   "Rain heavy 2 (rural)" by jmbphilmes: the same place, heavy
                    rain (and a thunderclap at 44 s, not used). freesound #200272
    fs_685618.mp3   "hail in the city.wav" by misternormmedia: a flash hail
                    storm on a balcony in London, Ontario, bouncing off the
                    rails and the concrete. freesound #685618
    fs_522025.mp3   "THREE MIGHTY THUNDERS IN ROW" by Nimlos (LCT 440 pure A-B
                    stereo, MixPre-D). freesound #522025
    fs_827530.mp3   "Ocean_coast_04_092025_0659AM" by YevgVerh: light ocean
                    waves on the Outer Banks' sand beach. freesound #827530
    fs_737644.mp3   "Rocks Thrown in Water" by Kraftaggregat (Zoom H6, SGH-6).
                    freesound #737644
    fs_705058.mp3   "Sea waves underwater, back and forth, close to the rocks
                    with water bubbles" by felix.blume: Ilo harbour, Peru
                    (Schoeps CCM41 MS, Sound Devices 744T). freesound #705058

Fetch each source's HQ preview into <source dir> (the originals need a
freesound login; the previews are the same recordings):

    curl -L -o fs_200273.mp3 https://cdn.freesound.org/previews/200/200273_2322692-hq.mp3
    curl -L -o fs_200272.mp3 https://cdn.freesound.org/previews/200/200272_2322692-hq.mp3
    curl -L -o fs_685618.mp3 https://cdn.freesound.org/previews/685/685618_10556713-hq.mp3
    curl -L -o fs_522025.mp3 https://cdn.freesound.org/previews/522/522025_4710044-hq.mp3
    curl -L -o fs_827530.mp3 https://cdn.freesound.org/previews/827/827530_2718606-hq.mp3
    curl -L -o fs_737644.mp3 https://cdn.freesound.org/previews/737/737644_9268998-hq.mp3
    curl -L -o fs_705058.mp3 https://cdn.freesound.org/previews/705/705058_1661766-hq.mp3

Outputs (44.1 kHz Ogg Vorbis), at the levels the synthesised files had so the
mix does not move (--stats prints them; check by numbers, never by speakers):
  * weather/rain_light, weather/rain_heavy: 30 s stereo loops (soundscape.lua,
    Ambient bus). The recordings are mono and steady, so the left and right
    channels are two different stretches of the same rain: a wide, natural
    stereo with no phasing. -28.1 / -24.2 LUFS.
  * weather/hail: 30 s stereo loop. -26 LUFS.
  * weather/thunder_1..3: 10 s stereo one-shots, the three strikes, each from
    just before the crack to its rolling tail (weather.lua plays them flat,
    late by the strike's distance, pitched and muffled per strike). Peak
    -1.5 dBFS, loudness as before where the peak allows.
  * water/surf_loop: 26 s MONO loop (ocean.lua plays it as a 3D source at the
    shore): waves breaking and washing, the seam in a lull. -19 LUFS.
  * water/splash_1..3: 1.6 s MONO one-shots (falling into the sea, wading).
    About -20 LUFS, peak -1 dBFS.
  * ambience/underwater: 16.9 s stereo loop (soundscape.lua, the camera under
    a sea): the sea surging back and forth among rocks, heard from inside it,
    the seam in a lull. -29 LUFS.

Loops are crossfaded tail-into-head (equal power), so they have no seam.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_grit_audio import SR, AUDIO, load, ebur, fft_filter, cut, fades, loopify, dc, level  # noqa: E402

RAIN_LIGHT = ("fs_200273.mp3", 2.0, 48.0, 30.0, 2.0)    # source, left from, right from, loop length, crossfade
RAIN_HEAVY = ("fs_200272.mp3", 1.0, 10.0, 30.0, 2.0)    # (the thunderclap at 44-52 s left out)
HAIL = ("fs_685618.mp3", 6.0, 30.0, 2.0)                # source, start, loop length, crossfade
THUNDER = [(27.5, 10.0), (60.5, 10.0), (95.3, 10.0)]    # fs_522025: start (0.5 s before the crack), length
SURF = (38.454, 64.597, 1.0)                            # fs_827530: seam at, seam at (both in a lull), crossfade
SPLASH = [0.03, 4.85, 7.72]                             # fs_737644: onsets, 1.6 s each
UNDERWATER = (4.600, 21.479, 0.5)                       # fs_705058: seam at, seam at (lulls), crossfade

OUTPUTS = ["weather/rain_light.ogg", "weather/rain_heavy.ogg", "weather/hail.ogg",
           "weather/thunder_1.ogg", "weather/thunder_2.ogg", "weather/thunder_3.ogg",
           "water/surf_loop.ogg", "water/splash_1.ogg", "water/splash_2.ogg", "water/splash_3.ogg",
           "ambience/underwater.ogg"]
LOOPS = {"weather/rain_light.ogg", "weather/rain_heavy.ogg", "weather/hail.ogg", "water/surf_loop.ogg",
         "ambience/underwater.ogg"}
# what the synthesised files measured (integrated LUFS)
TARGET = {"weather/rain_light.ogg": -28.1, "weather/rain_heavy.ogg": -24.2, "weather/hail.ogg": -26.0,
          "weather/thunder_1.ogg": -18.9, "weather/thunder_2.ogg": -23.0, "weather/thunder_3.ogg": -17.2,
          "water/surf_loop.ogg": -19.0, "water/splash_1.ogg": -19.1, "water/splash_2.ogg": -20.7,
          "water/splash_3.ogg": -20.3, "ambience/underwater.ogg": -29.0}


def build(src):
    cache = {}

    def get(name, ch=2):
        k = (name, ch)
        if k not in cache:
            cache[k] = load(os.path.join(src, name), ch)
        return cache[k]

    for rel, (name, tl, tr, secs, xf) in (("weather/rain_light.ogg", RAIN_LIGHT), ("weather/rain_heavy.ogg", RAIN_HEAVY)):
        x = get(name, 1)
        st = np.stack([cut(x, tl, secs + xf), cut(x, tr, secs + xf)], axis=1)
        st = fft_filter(dc(st), hp=80)
        level(rel, loopify(st, xf), TARGET[rel], -3.0)

    name, t, secs, xf = HAIL
    x = fft_filter(dc(cut(get(name), t, secs + xf)), hp=80)
    level("weather/hail.ogg", loopify(x, xf), TARGET["weather/hail.ogg"], -3.0)

    for i, (t, secs) in enumerate(THUNDER, 1):
        x = fft_filter(dc(cut(get("fs_522025.mp3"), t, secs)), hp=25)
        x = fades(x, 0.3, 2.5)
        rel = "weather/thunder_%d.ogg" % i
        level(rel, x, TARGET[rel], -1.5)

    t0, t1, xf = SURF
    x = fft_filter(dc(cut(get("fs_827530.mp3", 1), t0, t1 - t0 + xf)), hp=40)
    level("water/surf_loop.ogg", loopify(x, xf), TARGET["water/surf_loop.ogg"], -1.5)

    for i, t in enumerate(SPLASH, 1):
        x = fft_filter(dc(cut(get("fs_737644.mp3", 1), t, 1.6)), hp=60)
        x = fades(x, 0.004, 0.3)
        rel = "water/splash_%d.ogg" % i
        level(rel, x, TARGET[rel], -1.0)

    t0, t1, xf = UNDERWATER
    x = fft_filter(dc(cut(get("fs_705058.mp3"), t0, t1 - t0 + xf)), hp=20)
    level("ambience/underwater.ogg", loopify(x, xf), TARGET["ambience/underwater.ogg"], -6.0)


def stats():
    for rel in OUTPUTS:
        p = os.path.join(AUDIO, rel)
        x = load(p, 2)
        m = x.mean(axis=1)
        i, pk = ebur(p)
        rms = 20 * np.log10(np.sqrt(np.mean(m ** 2)) + 1e-12)
        line = "%-24s %6.2f s  I %6.1f LUFS (was %5.1f)  true peak %6.1f dBFS  rms %6.1f" % (
            rel, len(m) / SR, i, TARGET[rel], pk, rms)
        if rel in LOOPS:
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
