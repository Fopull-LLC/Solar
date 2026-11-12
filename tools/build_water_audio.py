#!/usr/bin/env python3
"""build_water_audio.py — the water pass's recorded sounds (streams, falls,
lapping, wading, strokes, splashes, bubbles, rain on water).

    python3 tools/build_water_audio.py <source dir> [--stats]

The sources are freesound.org previews (hq mp3, 48 kHz), every one CC0 1.0
(the licence read on each page; the ids and pages are in audio/SOURCES.md),
downloaded as fs_<id>.mp3 into <source dir>. Each RECIPE names a slice, how
it is cleaned (build_sfx.py's filters and fades) and whether it loops, and
writes one mono 44.1 kHz Ogg under audio/water/. Levels follow build_sfx.py:
loops at -18 dBFS RMS, one-shots peak -1 dBFS with the loud part no hotter
than -14 dBFS. The cut points come from the envelopes (50 ms RMS onsets and
the flattest 6 s windows, work/water/envelopes.txt): nothing here was chosen
by ear.
"""
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_sfx as B  # noqa: E402

SR = B.SR
OUT = os.environ.get("WATER_OUT") or os.path.join(HERE, "..", "audio", "water")

# name: (freesound id, start s, end s, options as build_sfx: hp lp pitch fin fout loop limit)
RECIPES = {
    # ── running water ──
    # A babbling brook (hoshisato #853672, 31 s): the steadiest 12 s.
    "stream_loop": ("853672", 8.0, 20.0, dict(hp=60, loop=1.0)),
    # A small brook round rocks (pepasystem #819768): closer, more trickle.
    "brook_loop": ("819768", 6.0, 18.0, dict(hp=70, loop=1.0)),
    # ── waterfalls ──
    # A hidden waterfall in the Scottish Borders (BassmanJourney #632107),
    # its flattest stretch: the close roar with the hiss on top.
    "waterfall_loop": ("632107", 82.0, 96.0, dict(hp=35, loop=1.5)),
    # The Meraner Höhenweg fall (datapopstar2 #650699): softer, further.
    "waterfall_soft_loop": ("650699", 48.0, 60.0, dict(hp=40, loop=1.5)),
    # ── standing water ──
    # Gentle waves on a lake in Eastern Washington (TheFlyFishingFilmmaker #614299).
    "lap_loop": ("614299", 140.0, 154.0, dict(hp=50, loop=1.5)),
    # Waves on a rocky Midwest lake shore (kvgarlic #326097): a bit livelier.
    "lap_rocks_loop": ("326097", 78.0, 90.0, dict(hp=50, loop=1.5)),
    # Rain on a pond (Mjeno #399281): very steady.
    "rain_water_loop": ("399281", 6.0, 18.0, dict(hp=80, loop=1.5)),
    # ── the crew ──
    # Steps into and out of a puddle (ChristopherJngs #861369): four steps.
    "wade_1": ("861369", 0.85, 1.55, dict(hp=80, fout=0.15)),
    "wade_2": ("861369", 3.30, 3.95, dict(hp=80, fout=0.15)),
    "wade_3": ("861369", 3.90, 4.60, dict(hp=80, fout=0.15)),
    "wade_4": ("861369", 5.05, 5.80, dict(hp=80, fout=0.15)),
    # A person swimming with short strokes (craigsmith #438845): four strokes.
    "stroke_1": ("438845", 6.55, 7.45, dict(hp=80, fout=0.2)),
    "stroke_2": ("438845", 7.45, 8.40, dict(hp=80, fout=0.2)),
    "stroke_3": ("438845", 17.15, 18.05, dict(hp=80, fout=0.2)),
    "stroke_4": ("438845", 20.15, 21.10, dict(hp=80, fout=0.2)),
    # A 5 m dive into a pool (bruno.auzet #529794): a body-sized splash.
    "splash_body_1": ("529794", 0.0, 2.6, dict(hp=60, fout=0.6)),
    # A large splash (Sheyvan #469608).
    "splash_body_2": ("469608", 0.0, 2.0, dict(hp=60, fout=0.4)),
    # ── under water ──
    # Scuba bubbles (sbvitug #634225): the steady stretch, as a loop.
    "bubbles_loop": ("634225", 72.0, 84.0, dict(hp=100, lp=9000, loop=1.0)),
    # A dive helmet's exhaust at 16 m (plaamook #409301): one exhale.
    "exhale_1": ("409301", 0.0, 3.0, dict(hp=80, lp=8000, fout=0.5)),
    "exhale_2": ("409301", 3.0, 6.4, dict(hp=80, lp=8000, fout=0.5)),
}


def find_src(d, sid):
    for ext in (".mp3", ".flac", ".ogg", ".wav"):
        p = os.path.join(d, "fs_" + sid + ext)
        if os.path.exists(p):
            return p
    raise FileNotFoundError("source fs_%s.* not in %s" % (sid, d))


def save(name, x):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1",
                    "-i", "-", "-c:a", "libvorbis", "-q:a", "5", p],
                   input=x.astype(np.float32).tobytes(), check=True)
    return p


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    src = sys.argv[1]
    cache = {}
    made = []
    for name, (sid, a, b, o) in RECIPES.items():
        if sid not in cache:
            cache[sid] = B.load(find_src(src, sid))
        x = cache[sid][int(a * SR):int(b * SR)]
        x = x - np.mean(x)
        x = B.fft_filter(x, hp=o.get("hp", 0), lp=o.get("lp", 0))
        x = B.repitch(x, o.get("pitch", 1.0))
        loop = o.get("loop", 0)
        if loop:
            x = B.loopify(x, loop)
        else:
            x = B.fades(x, o.get("fin", 0.004), o.get("fout", 0.05))
        x = B.level(x, bool(loop), o.get("limit", 0))
        made.append(save(name, x))
    if "--stats" in sys.argv:
        for p in made:
            print(B.stats(p))
    print("%d files under %s" % (len(made), os.path.abspath(OUT)))


if __name__ == "__main__":
    main()
