#!/usr/bin/env python3
"""Solar's particle effects, as data: `python3 tools/gen_vfx.py` rewrites vfx/*.vfx.ron.

How they are played (engine v0.112+, see scripts/vfx.lua):

* One-shots are fired with spawnEffect(key, pos, {normal = up, ...}). They
  ride the planet whose sphere of influence they are in, so Local and World
  tracks alike stay with the ground; +Y is the `normal`, so cones fire off
  the surface and rings lie on it. Gravity is the planet's (Field mode).
* Smoke, dust, grit and leaves are lit billboards and vary puff to puff
  (CurveRange); dust is tinted per world by vfx.lua.
* Heat haze is a Distortion track (visible in play, not in `floptle shot`).
* Node effects: Flame/FlameVac/RcsPuff on engines, MiningBeam/MiningImpact on
  the laser, PadBlast on a planet-parented node, Reentry on the craft.
"""
from vfx_ron import *  # the tiny RON DSL beside this file

TX = "textures/vfx/"
ROCK = "models/space-kit/rocks_smallA.glb"
ROCK_B = "models/space-kit/rocks_smallB.glb"
RAD = (0, 0, 6.2832)  # full roll range for billboards

# A lightning strike's light over time (seconds, peak 1). The bolt, the cloud
# glow, weather.lua's sky flash and vfx.lua's point light all play these keys
# (weather.lua carries a copy as FLASH: change both together).
FLASH = [(0.0, 0.0), (0.03, 0.16), (0.05, 0.2), (0.067, 1.0), (0.15, 0.85), (0.25, 0.58), (0.31, 0.5),
         (0.35, 0.8), (0.45, 0.6), (0.6, 0.3), (0.8, 0.1), (1.0, 0.0)]


def fade(rgb, a_peak, t_in=0.08, t_hold=0.4, a_hold=None):
    """Colour curve: fade in quickly, hold, fade out."""
    r, g, b = rgb
    ah = a_peak if a_hold is None else a_hold
    return K([(0, (r, g, b, 0)), (t_in, (r, g, b, a_peak)), (t_hold, (r, g, b, ah)), (1, (r, g, b, 0))])


def wind(coupling):
    """The game's wind (engine 0.117 Force::Wind; weather.lua feeds the field).

    The particle's velocity relative to the AIR decays at `coupling` per
    second. It replaces a track's drag one for one: in still air the track
    relaxes to rest exactly as its drag did, and in wind it settles on the
    wind instead. Light smoke couples loosely and streams far downwind; heavy
    dust couples more tightly and carries a little gravity, so it drifts and
    settles. The wind relaxes all three axes, so a falling track needs gravity
    to fall: its fall through the air settles at gravity x g / coupling (rain
    1.2 x 6 / 1.0 = 7 m/s on a 6 m/s2 world)."""
    return f"Wind(coupling: {fnum(coupling)})"


def jitter(track, amount, seed, rate=0.0):
    """A Beam track thrown into a jagged channel (engine 0.117 beam jitter).

    Tracks with the same seed and segment count draw the same channel. A rate
    of 0 throws it once per instance: the shape holds for the whole effect."""
    i = track.index("\n", track.index("beam_end:")) + 1
    return (track[:i] + f"            jitter: {fnum(amount)},\n            jitter_rate: {fnum(rate)},\n"
            f"            jitter_seed: {int(seed)},\n" + track[i:])


def grow(a, b, c=None):
    if c is None:
        return K([(0, a), (1, b)])
    return K([(0, a), (0.35, b), (1, c)])


# =====================================================================================
# ROCKET ENGINE
# =====================================================================================
def flame():
    L = 0.5
    tracks = [
        # The white-hot core right out of the throat — short, fast, stretched.
        T("Core", TX + "glow/core.png", blend="Additive", orient="Velocity", stretch=3.2, speed_stretch=0.02,
          clips=stream(150, 0.11, 0, L), shape=cone(2, 0.22), vel=(0, 30, 0),
          size=K([(0, 0.85), (0.4, 0.75), (1, 0.25)]),
          color=K([(0, (3.2, 2.9, 2.4, 0.9)), (0.45, (2.6, 1.7, 0.8, 0.75)), (1, (1.4, 0.6, 0.2, 0))]), soft=0.1),
        # The flame body: rolling fire, widening as it slows.
        T("Flame", TX + "fire/fireball_a.png", blend="Alpha", clips=stream(90, 0.42, 0, L, 0.25),
          shape=cone(5, 0.3), vel=R((0, 24, 0), (0, 34, 0)), drag=1.2,
          size=K([(0, 0.8), (0.4, 1.7), (1, 2.6)]),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -4), (0, 0, 4)),
          color=K([(0, (2.6, 1.7, 0.8, 0.8)), (0.3, (2.2, 0.95, 0.28, 0.6)), (0.7, (1.3, 0.4, 0.1, 0.3)),
                   (1, (0.5, 0.2, 0.1, 0))]), soft=0.3),
        T("Tongue", TX + "fire/tongue.png", blend="Additive", orient="Velocity", stretch=2.2,
          clips=stream(60, 0.2, 0, L, 0.2), shape=cone(3, 0.2), vel=R((0, 28, 0), (0, 34, 0)),
          size=K([(0, 1.0), (1, 1.6)]),
          color=K([(0, (2.6, 1.9, 1.0, 0.6)), (0.5, (2.2, 1.0, 0.3, 0.45)), (1, (1.2, 0.35, 0.08, 0))]), soft=0.2),
        # Shock diamonds: every particle has the SAME speed and life, so a size
        # and brightness pattern over life is a pattern frozen in space — Mach
        # disks standing in the exhaust.
        T("Diamonds", TX + "glow/tight.png", blend="Additive", clips=stream(110, 0.42, 0, L), shape=point(),
          vel=(0, 22, 0),
          size=K([(0, 0.3), (0.10, 0.85), (0.18, 0.3), (0.32, 0.7), (0.41, 0.25), (0.55, 0.55),
                  (0.64, 0.2), (0.78, 0.4), (1, 0.1)]),
          color=K([(0, (2.6, 2.0, 1.4, 0.2)), (0.10, (3.0, 2.3, 1.5, 0.75)), (0.18, (2.2, 1.3, 0.6, 0.12)),
                   (0.32, (2.6, 1.8, 1.0, 0.55)), (0.41, (2.0, 1.0, 0.4, 0.08)), (0.55, (2.2, 1.3, 0.6, 0.35)),
                   (0.64, (1.6, 0.7, 0.2, 0.05)), (0.78, (1.8, 0.9, 0.3, 0.2)), (1, (1, 0.4, 0.1, 0))])),
        # The bell lighting up: one big soft glow at the nozzle, flickering.
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0), vel=(0, 0, 0),
          size=K([(0, 3.4), (0.25, 3.9), (0.5, 3.2), (0.75, 4.0), (1, 3.4)]),
          color=K([(0, (1.8, 0.95, 0.4, 0.55)), (0.3, (1.8, 0.9, 0.35, 0.65)), (0.6, (1.7, 0.85, 0.35, 0.5)),
                   (1, (1.8, 0.95, 0.4, 0.55))]), soft=0.2),
        # A few incandescent flecks: soot burning, never the same twice.
        T("Flecks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.035,
          clips=stream(14, 0.4, 0, L, 0.4), shape=cone(9, 0.2), vel=R((0, 18, 0), (0, 32, 0)), size=0.09,
          color=K([(0, (3, 2.2, 1.2, 1)), (1, (1.5, 0.4, 0.05, 0))])),
        # Heat shimmer over the hot exhaust (Distortion blend: bends the scene).
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.02, clips=stream(30, 0.5, 0, L, 0.2),
          shape=cone(8, 0.3), vel=R((0, 10, 0), (0, 16, 0)), size=K([(0, 1.2), (1, 3.4)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (1, 1, 1, 0)), (0.2, (1, 1, 1, 0.9)), (1, (1, 1, 1, 0))]), soft=0.5),
    ]
    effect("Flame", L, tracks, looping=True, header="""
Rocket exhaust in AIR: white core, rolling flame, standing shock diamonds,
nozzle glow and burning flecks. Rides the engine's "Engine Flame" node (local
+Y = out of the nozzle). vfx.lua crossfades it with FlameVac by air density
and drives both by throttle through setIntensity.""")

    tracks = [
        T("Core", TX + "glow/core.png", blend="Additive", orient="Velocity", stretch=2.6,
          clips=stream(110, 0.1, 0, L), shape=cone(4, 0.25), vel=(0, 28, 0), size=K([(0, 0.9), (1, 0.35)]),
          color=K([(0, (2.4, 2.4, 2.8, 0.85)), (1, (1.2, 0.9, 1.4, 0))]), soft=0.1),
        # In vacuum the plume has nothing to hold it together: a wide, pale,
        # translucent bell that fans out and thins to nothing.
        T("Bell", TX + "glow/soft.png", blend="Additive", clips=stream(220, 0.45, 0, L, 0.2),
          shape=cone(24, 0.35), vel=R((0, 18, 0), (0, 26, 0)), size=K([(0, 1.0), (0.6, 3.2), (1, 4.4)]),
          color=K([(0, (1.5, 1.3, 1.4, 0.22)), (0.4, (0.9, 0.7, 0.9, 0.1)), (1, (0.4, 0.3, 0.5, 0))])),
        T("Tongue", TX + "fire/tongue.png", blend="Additive", orient="Velocity", stretch=2.5,
          clips=stream(70, 0.22, 0, L, 0.2), shape=cone(6, 0.2), vel=R((0, 24, 0), (0, 30, 0)),
          size=K([(0, 1.0), (1, 2.0)]), color=K([(0, (1.8, 1.7, 2.2, 0.45)), (1, (0.8, 0.6, 1.2, 0))])),
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 2.8), (0.5, 3.1), (1, 2.8)]), color=C((1.5, 1.1, 1.0, 0.45)), soft=0.2),
    ]
    effect("FlameVac", L, tracks, looping=True, header="""
Rocket exhaust in VACUUM: the under-expanded plume blooms into a wide pale
bell with no shock structure. Crossfaded against Flame by vfx.lua.""")

    # RCS: a tight, pale, cold-gas puff. Authored for the RCS block's 0.3 scale
    # (local units ×0.3 in the world).
    tracks = [
        T("Jet", TX + "smoke/soft.png", blend="Alpha", clips=stream(70, 0.22, 0, 0.44), shape=cone(8, 0.1),
          vel=R((0, 22, 0), (0, 32, 0)), size=K([(0, 0.4), (1, 2.6)]),
          color=K([(0, (0.95, 0.96, 1.0, 0.6)), (1, (0.9, 0.92, 0.95, 0))]), drag=2.5, soft=0.1),
        T("Core", TX + "glow/tight.png", blend="Additive", clips=stream(40, 0.08, 0, 0.44), shape=point(),
          vel=(0, 20, 0), size=0.8, color=K([(0, (1.5, 1.6, 1.8, 0.5)), (1, (1, 1, 1, 0))])),
    ]
    effect("RcsPuff", 0.44, tracks, looping=True, header="RCS cold-gas jet (looping, on the RCS block's 'RCS Plume' node).")

    # Exhaust smoke left hanging in the air behind a climbing rocket (detached,
    # fired by vfx.lua at the nozzle with the AIR's velocity).
    tracks = [
        T("Smoke", TX + "smoke/billow_b.png", clips=burst(2, 0, 3.6, 0.3), shape=sphere(0.4),
          vel=R((-0.6, -0.6, -0.6), (0.6, 0.6, 0.6)), gravity=-0.03,
          size=K([(0, 1.2), (0.3, 3.6), (1, 6.5)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.4), (0, 0, 0.4)),
          color=K([(0, (0.95, 0.9, 0.85, 0)), (0.06, (0.92, 0.9, 0.88, 0.42)), (0.5, (0.86, 0.85, 0.84, 0.25)),
                   (1, (0.8, 0.8, 0.8, 0))]), soft=1.5, forces=[wind(0.8), turb(0.25, 0.8)]),
        T("Smoke2", TX + "smoke/billow_a.png", forces=[wind(0.8)], clips=burst(1, 0, 3.6, 0.3), shape=sphere(0.5),
          vel=R((-0.4, -0.4, -0.4), (0.4, 0.4, 0.4)), gravity=-0.04,
          size=K([(0, 1.5), (0.4, 4.5), (1, 8.0)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.3), (0, 0, 0.3)),
          color=K([(0, (0.9, 0.88, 0.85, 0)), (0.08, (0.88, 0.87, 0.86, 0.3)), (1, (0.82, 0.82, 0.82, 0))]),
          soft=1.5),
    ]
    effect("ExhaustPuff", 3.6, tracks, header="Exhaust smoke left in the air behind a burning engine (pooled, planet-parented).")


# =====================================================================================
# LAUNCH PAD / GROUND INTERACTION (pooled, node +Y = planet up)
# =====================================================================================
G = 8.5  # local gravity for pooled effects


def pad_blast():
    L = 1.0
    tracks = [
        # The cloud the exhaust bulldozes out across the ground: big, slow, rolling.
        T("Billow", TX + "smoke/billow_a.png", clips=stream(26, 3.4, 0, L, 0.3), shape=ring(1.4),
          vel=R((-1, 7, -1), (1, 15, 1)), forces=[wind(1.1), push(0, 1, 0, 1.4), turb(0.3, 1.2)],
          size=K([(0, 1.4), (0.25, 4.0), (1, 7.0)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.5), (0, 0, 0.5)),
          color=K([(0, (0.85, 0.8, 0.74, 0)), (0.06, (0.84, 0.8, 0.75, 0.62)), (0.5, (0.8, 0.77, 0.73, 0.4)),
                   (1, (0.78, 0.76, 0.73, 0))]), soft=2.0),
        T("Billow2", TX + "smoke/billow_b.png", clips=stream(8, 4.0, 0, L, 0.3), shape=ring(1.0),
          vel=R((-1, 4, -1), (1, 9, 1)), forces=[wind(0.9), push(0, 1, 0, 2.2)],
          size=K([(0, 2.0), (0.3, 5.0), (1, 8.5)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.3), (0, 0, 0.3)),
          color=K([(0, (0.9, 0.87, 0.82, 0)), (0.08, (0.86, 0.83, 0.78, 0.32)), (1, (0.8, 0.78, 0.76, 0))]),
          soft=2.0),
        # The fast skirt of dust racing out along the ground ahead of the cloud.
        T("Skirt", TX + "smoke/clump_a.png", clips=stream(34, 1.3, 0, L, 0.3), shape=ring(0.9),
          vel=R((-1, 14, -1), (1, 24, 1)), forces=[wind(1.8), push(0, 1, 0, 0.6)],
          size=K([(0, 0.6), (1, 3.0)]), rot=R((0, 0, 0), RAD), squash=R(0.7, 1.4),
          color=K([(0, (0.72, 0.64, 0.52, 0)), (0.1, (0.7, 0.62, 0.5, 0.55)), (1, (0.66, 0.6, 0.5, 0))]),
          soft=0.8),
        # Grit thrown up and raining back down.
        T("Grit", TX + "debris/chip_a.png", clips=stream(28, 1.4, 0, L, 0.4), shape=cone(55, 1.2),
          vel=R((0, 5, 0), (0, 12, 0)), forces=[push(0, -1, 0, G)], size=R(0.08, 0.2),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -12), (0, 0, 12)), color=C((0.42, 0.37, 0.32, 1))),
        # The exhaust itself splashing on the ground lights it orange.
        T("Splash", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 6.0), (0.5, 7.0), (1, 6.0)]), color=C((1.6, 0.75, 0.3, 0.5)), soft=0.6),
        T("Fire", TX + "fire/fireball_a.png", blend="Additive", clips=stream(30, 0.45, 0, L, 0.3),
          shape=ring(0.6), vel=R((0, 6, 0), (0, 12, 0)), drag=2.0, size=K([(0, 1.0), (1, 2.6)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (2.2, 1.2, 0.5, 0.7)), (1, (0.8, 0.25, 0.05, 0))]), soft=0.5),
    ]
    effect("PadBlast", L, tracks, looping=True, header="""
Exhaust hitting the ground under a rocket: smoke bulldozed out across the
ground, a fast dust skirt, grit, and the orange splash of the flame. Pooled
on a planet-parented node, +Y = up; vfx.lua drives setIntensity by thrust
and height above the ground.""")


def touch_dust():
    tracks = [
        T("Billow", TX + "smoke/billow_a.png", clips=burst(30, 0, 2.6, 0.3), shape=ring(0.8),
          vel=R((-0.5, 3, -0.5), (0.5, 8, 0.5)), forces=[wind(2.0), push(0, 1, 0, 0.8)],
          size=K([(0, 0.8), (0.3, 2.4), (1, 3.6)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.6), (0, 0, 0.6)),
          color=K([(0, (0.8, 0.74, 0.66, 0)), (0.06, (0.78, 0.72, 0.64, 0.58)), (1, (0.74, 0.7, 0.64, 0))]),
          soft=1.0),
        T("Skirt", TX + "smoke/billow_b.png", gravity=0.05, forces=[wind(3.0)], clips=burst(30, 0, 1.1, 0.3), shape=ring(0.6),
          vel=R((-0.5, 8, -0.5), (0.5, 14, 0.5)), size=K([(0, 0.4), (1, 1.9)]), squash=R(0.7, 1.4),
          rot=R((0, 0, 0), RAD), color=K([(0, (0.7, 0.62, 0.52, 0.4)), (1, (0.66, 0.6, 0.52, 0))]), soft=0.5),
        T("Grit", TX + "debris/chip_b.png", clips=burst(16, 0, 1.0, 0.3), shape=cone(60, 0.8),
          vel=R((0, 2, 0), (0, 6, 0)), forces=[push(0, -1, 0, G)], size=R(0.06, 0.16), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -10), (0, 0, 10)), color=C((0.4, 0.36, 0.31, 1))),
    ]
    effect("TouchDust", 2.6, tracks, header="Landing-leg touchdown: a ring of dust and grit (pooled, +Y up).")


def ground_shock():
    tracks = [
        # The dust wall a blast drives out along the ground.
        T("Wall", TX + "smoke/billow_a.png", clips=burst(48, 0, 2.8, 0.3), shape=ring(1.0),
          vel=R((-0.5, 12, -0.5), (0.5, 22, 0.5)), forces=[wind(2.4), push(0, 1, 0, 1.0)],
          size=K([(0, 1.0), (0.3, 3.4), (1, 5.0)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.5), (0, 0, 0.5)),
          color=K([(0, (0.55, 0.5, 0.45, 0)), (0.05, (0.55, 0.5, 0.45, 0.5)), (1, (0.5, 0.48, 0.45, 0))]),
          soft=1.5),
        # Flat shock ring skimming the surface (Edge emits +Z, so WorldFixed
        # lays the quad in the node's XZ plane: flat on the ground).
        T("Ring", TX + "ring/dust.png", blend="Alpha", orient="WorldFixed", clips=burst(1, 0, 0.7, cj=0),
          shape=edge(0), size=K([(0, 1.0), (1, 22.0)]),
          color=K([(0, (0.6, 0.55, 0.48, 0.35)), (1, (0.55, 0.5, 0.45, 0))]), soft=0.2),
        T("Debris", mesh=ROCK, clips=burst(10, 0, 1.6, 0.3), shape=cone(50, 0.6), vel=R((0, 6, 0), (0, 14, 0)),
          forces=[push(0, -1, 0, G)], size=R(0.12, 0.3), rot=R((0, 0, 0), (6.28, 6.28, 6.28)),
          spin=R((-8, -8, -8), (8, 8, 8)), color=C((0.35, 0.32, 0.3, 1)), lit=True),
    ]
    effect("GroundShock", 2.8, tracks, header="The ground part of an explosion near the surface (pooled, +Y up).")


def water_ring():
    tracks = [
        T("Foam", TX + "water/foam.png", orient="WorldFixed", clips=burst(1, 0, 1.8, cj=0), shape=edge(0),
          size=K([(0, 0.6), (1, 4.0)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.95, 0.97, 1.0, 0.8)), (1, (0.9, 0.95, 1.0, 0))]), soft=0.1),
        T("Ripple", TX + "ring/shock.png", orient="WorldFixed", clips=burst(3, 0, 1.4, pulses=3, interval=0.25, cj=0),
          shape=edge(0), size=K([(0, 0.5), (1, 6.0)]),
          color=K([(0, (0.9, 0.95, 1.0, 0.28)), (1, (0.85, 0.92, 1.0, 0))]), soft=0.05),
    ]
    effect("WaterRing", 1.9, tracks, header="Foam and ripples spreading on the water where something broke the surface (pooled, +Y up).")


# Sparks skip off the ground instead of falling through it (v0.117, card 0410:
# a landed particle stops asking the level, so colliding sparks, grit and
# debris cost little once they are down).
SPARK_HIT = (0.35, 0.4)


# =====================================================================================
# EXPLOSIONS
# =====================================================================================
def explosion(name, k, header):
    s = k  # size scale
    n = lambda x: max(1, int(round(x * (0.4 + 0.6 * k))))
    tracks = [
        T("Flash", TX + "glow/flash.png", blend="Additive", clips=burst(1, 0, 0.14, cj=0),
          size=K([(0, 6 * s), (0.3, 15 * s), (1, 10 * s)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (4, 3.6, 3, 1)), (1, (2, 1, 0.4, 0))])),
        T("Core", TX + "glow/core.png", blend="Additive", clips=burst(1, 0, 0.5, cj=0),
          size=K([(0, 3 * s), (0.4, 7 * s), (1, 5 * s)]),
          color=K([(0, (3.5, 3.0, 2.2, 1)), (0.5, (2.4, 1.2, 0.4, 0.6)), (1, (1, 0.3, 0.05, 0))]), soft=1.0),
        # The fireball: a boiling mass that swells, reddens and chokes into smoke.
        T("Fireball", TX + "fire/fireball_a.png", blend="Additive", clips=burst(n(34), 0, 1.3, 0.35),
          shape=sphere(0.9 * s), vel=R((0, 2 * s, 0), (0, 9 * s, 0)), drag=3.0, gravity=-0.25,
          size=K([(0, 2.0 * s), (0.35, 4.6 * s), (1, 6.0 * s)]), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -1.5), (0, 0, 1.5)),
          color=K([(0, (3.4, 2.8, 1.8, 1)), (0.18, (2.8, 1.4, 0.4, 0.95)), (0.45, (1.6, 0.45, 0.08, 0.7)),
                   (0.75, (0.6, 0.12, 0.03, 0.35)), (1, (0.2, 0.05, 0.02, 0))]), soft=1.0),
        T("Fireball2", TX + "fire/fireball_c.png", blend="Additive", clips=burst(n(14), 0.05, 1.7, 0.3),
          shape=sphere(1.2 * s), vel=R((0, 1 * s, 0), (0, 4 * s, 0)), drag=2.0, gravity=-0.35,
          size=K([(0, 3.0 * s), (1, 7.0 * s)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -1), (0, 0, 1)),
          color=K([(0, (2.2, 1.0, 0.3, 0.8)), (0.4, (1.2, 0.35, 0.06, 0.45)), (1, (0.2, 0.05, 0.02, 0))]),
          soft=1.2),
        # Black, oily smoke boiling out of the fire, then greying as it climbs.
        T("Smoke", TX + "smoke/billow_a.png", clips=burst(n(20), 0.18, 5.5, 0.3), shape=sphere(1.4 * s),
          vel=R((0, 0.8 * s, 0), (0, 3.5 * s, 0)), gravity=-0.16,
          size=K([(0, 3.0 * s), (0.35, 6.5 * s), (1, 10.0 * s)]), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -0.3), (0, 0, 0.3)),
          color=K([(0, (0.08, 0.07, 0.06, 0)), (0.07, (0.1, 0.09, 0.08, 0.92)), (0.45, (0.2, 0.19, 0.18, 0.7)),
                   (1, (0.34, 0.33, 0.32, 0))]), soft=2.5, forces=[wind(1.2), turb(0.15, 1.0)]),
        T("Smoke2", TX + "smoke/billow_b.png", forces=[wind(0.8)], clips=burst(n(10), 0.3, 6.0, 0.3), shape=sphere(1.0 * s),
          vel=R((0, 0.5 * s, 0), (0, 2.0 * s, 0)), gravity=-0.3,
          size=K([(0, 3.0 * s), (1, 11.0 * s)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.25), (0, 0, 0.25)),
          color=K([(0, (0.12, 0.11, 0.1, 0)), (0.1, (0.14, 0.13, 0.12, 0.8)), (1, (0.36, 0.35, 0.34, 0))]),
          soft=2.5),
        # Lit from inside for the first moments: smoke glowing orange over the fire.
        T("Underglow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0.05, 1.6, cj=0),
          size=K([(0, 8 * s), (1, 11 * s)]),
          color=K([(0, (1.6, 0.7, 0.2, 0.55)), (0.5, (1.0, 0.3, 0.06, 0.3)), (1, (0.4, 0.1, 0.02, 0))]), soft=1.5),
        # The pressure front: barely there, gone in a blink.
        T("Shock", TX + "ring/shock.png", blend="Additive", clips=burst(1, 0, 0.22, cj=0),
          size=K([(0, 2.0 * s), (1, 26 * s)]), color=K([(0, (1.2, 1.15, 1.1, 0.22)), (1, (1, 1, 1, 0))])),
        # WORLD tracks: ballistic, inherit the blast's velocity, Field gravity.
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.05,
          space="World", inherit=1.0, clips=burst(n(44), 0, 1.6, 0.5), shape=sphere(0.6 * s, True),
          vel=R((0, 8, 0), (0, 28 * s, 0)), gravity=1.0, size=0.12,
          color=K([(0, (3.4, 2.6, 1.6, 1)), (0.4, (2.4, 0.9, 0.25, 1)), (1, (0.8, 0.2, 0.04, 0))]),
          collide=SPARK_HIT),
        T("Streamers", TX + "spark/dot.png", blend="Additive", space="World", inherit=1.0,
          clips=burst(n(8), 0, 1.6, 0.3), shape=sphere(0.6 * s, True), vel=R((0, 9, 0), (0, 18 * s, 0)),
          gravity=1.0, size=0.4,
          color=K([(0, (3, 2, 1, 1)), (0.4, (2.0, 0.7, 0.15, 0.9)), (1, (0.5, 0.35, 0.3, 0))]),
          trail_=trail(0.9, 0.55 * s, TX + "smoke/soft.png", True, 0.12)),
        T("Debris", mesh=ROCK, space="World", inherit=1.0, clips=burst(n(16), 0, 2.4, 0.3),
          shape=sphere(0.6 * s, True), vel=R((0, 5, 0), (0, 16 * s, 0)), gravity=1.0, size=R(0.15 * s, 0.4 * s),
          rot=R((0, 0, 0), (6.28, 6.28, 6.28)), spin=R((-9, -9, -9), (9, 9, 9)),
          color=C((0.2, 0.19, 0.18, 1)), lit=True, collide=(0.3, 0.5), land_fade=True),
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.03, clips=burst(n(8), 0.05, 1.6, 0.3),
          shape=sphere(1.0 * s), vel=R((0, 1 * s, 0), (0, 3 * s, 0)), drag=1.5, gravity=-0.3,
          size=K([(0, 3 * s), (1, 7 * s)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (1, 1, 1, 0.9)), (0.5, (1, 1, 1, 0.5)), (1, (1, 1, 1, 0))]), soft=1.0),
    ]
    effect(name, 6.3, tracks, header=header)


# =====================================================================================
# STAGING / DOCKING / CHUTES / DAMAGE
# =====================================================================================
def sep_puff():
    tracks = [
        T("Flash", TX + "glow/star.png", blend="Additive", clips=burst(1, 0, 0.14, cj=0),
          size=K([(0, 1.5), (0.3, 3.2), (1, 2.0)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (3, 2.8, 2.5, 1)), (1, (1.5, 1.0, 0.6, 0))])),
        # Pyro gas and the pneumatic pusher's breath: a white puff ring, fast drag.
        T("Gas", TX + "smoke/soft.png", forces=[wind(4.0)], clips=burst(30, 0, 1.3, 0.3), shape=sphere(0.5, True),
          vel=R((0, 3, 0), (0, 8, 0)), size=K([(0, 0.5), (0.3, 1.6), (1, 2.4)]),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -1), (0, 0, 1)),
          color=K([(0, (0.85, 0.85, 0.87, 0)), (0.05, (0.85, 0.85, 0.87, 0.4)), (1, (0.8, 0.8, 0.82, 0))]),
          soft=0.4),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.05,
          space="World", inherit=1.0, clips=burst(18, 0, 0.7, 0.5), shape=sphere(0.4, True),
          vel=R((0, 5, 0), (0, 14, 0)), gravity=1.0, size=0.07,
          color=K([(0, (3, 2.6, 1.8, 1)), (1, (1.6, 0.5, 0.1, 0))])),
        T("Bolts", mesh=ROCK_B, space="World", inherit=1.0, clips=burst(5, 0, 1.4, 0.3), shape=sphere(0.4, True),
          vel=R((0, 3, 0), (0, 7, 0)), gravity=1.0, size=R(0.04, 0.08), rot=R((0, 0, 0), (6.28, 6.28, 6.28)),
          spin=R((-12, -12, -12), (12, 12, 12)), color=C((0.55, 0.55, 0.58, 1)), lit=True),
    ]
    effect("SepPuff", 1.4, tracks, header="Decoupler firing / dock latch: pyro flash, gas puff, sparks and bolts.")


def chute_puff():
    tracks = [
        T("Puff", TX + "smoke/billow_b.png", forces=[wind(3.0)], clips=burst(18, 0, 1.4, 0.3), shape=sphere(0.4, True),
          vel=R((0, 2, 0), (0, 5, 0)), size=K([(0, 0.4), (1, 2.2)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.92, 0.9, 0.86, 0.65)), (1, (0.9, 0.88, 0.85, 0))]), soft=0.4),
        T("Lint", TX + "debris/grit.png", forces=[wind(2.0)], clips=burst(6, 0, 1.0, 0.3), shape=sphere(0.3, True),
          vel=R((0, 1, 0), (0, 3, 0)), size=0.25, rot=R((0, 0, 0), RAD),
          color=K([(0, (0.9, 0.88, 0.85, 0.8)), (1, (0.9, 0.88, 0.85, 0))])),
    ]
    effect("ChutePuff", 1.4, tracks, header="Parachute mortar firing: packing dust and lint blown out of the canister.")


def smoke_puff():
    tracks = [
        T("Smoke", TX + "smoke/soot.png", forces=[wind(1.0)], clips=burst(2, 0, 2.8, 0.3), shape=sphere(0.25),
          vel=R((-0.4, -0.4, -0.4), (0.4, 0.4, 0.4)), gravity=-0.12,
          size=K([(0, 0.5), (0.3, 1.6), (1, 3.2)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.6), (0, 0, 0.6)),
          color=K([(0, (0.2, 0.19, 0.18, 0)), (0.08, (0.22, 0.21, 0.2, 0.75)), (1, (0.4, 0.4, 0.4, 0))]),
          soft=0.8),
        T("Ember", TX + "spark/dot.png", blend="Additive", clips=burst(1, 0, 0.5, 0.4, cj=0.9), shape=sphere(0.2),
          vel=R((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), gravity=-0.05, size=0.08,
          color=K([(0, (3, 1.4, 0.4, 1)), (1, (1, 0.2, 0.0, 0))])),
    ]
    effect("SmokePuff", 2.8, tracks, header="One puff of a damaged part's smoke trail (pooled, planet-parented; vfx.lua lays them along the flight path).")


# =====================================================================================
# REENTRY
# =====================================================================================
def reentry():
    L = 0.5
    tracks = [
        # The shock cap glowing ahead of the craft.
        T("Cap", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 4.2), (0.3, 4.8), (0.6, 4.0), (1, 4.2)]),
          color=K([(0, (2.2, 0.95, 0.5, 0.65)), (0.5, (2.4, 1.0, 0.55, 0.75)), (1, (2.2, 0.95, 0.5, 0.65))]),
          soft=0.5),
        T("Sheath", TX + "fire/fireball_b.png", blend="Additive", clips=stream(70, 0.26, 0, L, 0.3),
          shape=cone(28, 0.9), vel=R((0, 22, 0), (0, 38, 0)), size=K([(0, 1.2), (1, 2.8)]),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -3), (0, 0, 3)),
          color=K([(0, (2.6, 1.3, 0.7, 0.75)), (0.5, (1.8, 0.6, 0.6, 0.4)), (1, (0.8, 0.25, 0.5, 0))])),
        # Plasma streaming off in long pink-orange streaks.
        T("Streaks", TX + "spark/streak.png", blend="Additive", orient="Velocity", stretch=7.0,
          clips=stream(46, 0.3, 0, L, 0.3), shape=cone(14, 1.1), vel=R((0, 40, 0), (0, 62, 0)),
          size=0.32, color=K([(0, (2.4, 1.6, 1.2, 0.8)), (1, (1.4, 0.4, 0.8, 0))])),
        # Ablator flecks, burning off and tumbling back.
        T("Ablation", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.04,
          clips=stream(26, 0.7, 0, L, 0.5), shape=cone(22, 0.9), vel=R((0, 14, 0), (0, 30, 0)), size=0.1,
          color=K([(0, (3, 1.8, 0.8, 1)), (1, (1.2, 0.3, 0.05, 0))])),
    ]
    effect("Reentry", L, tracks, looping=True, header="""
Atmospheric reentry plasma (node, local +Y = downstream). vfx.lua places it at
the craft's leading face each frame and drives it by the heating.""")


# =====================================================================================
# GROUND CONTACT: scraping, footsteps
# =====================================================================================
def scrape():
    tracks = [
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.06,
          space="World", inherit=1.0, clips=burst(22, 0, 0.8, 0.5), shape=cone(70, 0.1),
          vel=R((0, 3, 0), (0, 12, 0)), gravity=1.0, size=0.07,
          color=K([(0, (3.4, 2.8, 1.8, 1)), (0.5, (2.4, 1.0, 0.25, 1)), (1, (1.0, 0.25, 0.04, 0))])),
        # No collide here: a belly slide fires this ten times a second, and the
        # sparks spend their whole life in the air, where each still costs a ray
        # a frame (measured 0.45-1.2 ms with it on against 0.03 ms off).
        T("Flash", TX + "glow/tight.png", blend="Additive", clips=burst(1, 0, 0.1, cj=0), size=1.6,
          color=K([(0, (2.5, 2.0, 1.4, 0.8)), (1, (1, 0.5, 0.2, 0))])),
    ]
    effect("Sparks", 0.8, tracks, header="Metal grinding on rock: a fan of sparks riding the hull's motion.")
    tracks = [
        T("Dust", TX + "smoke/clump_a.png", forces=[wind(2.0)], clips=burst(8, 0, 1.6, 0.3), shape=sphere(0.4),
          vel=R((0, 1, 0), (0, 3, 0)), gravity=0.03, size=K([(0, 0.5), (1, 2.4)]),
          rot=R((0, 0, 0), RAD), squash=R(0.7, 1.3),
          color=K([(0, (0.62, 0.56, 0.48, 0)), (0.08, (0.6, 0.55, 0.47, 0.72)), (1, (0.58, 0.55, 0.5, 0))]),
          soft=0.6),
        T("Grit", TX + "debris/chip_a.png", clips=burst(12, 0, 0.9, 0.3), shape=sphere(0.3, True),
          vel=R((0, 2, 0), (0, 5, 0)), gravity=1.0, size=R(0.05, 0.12), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -12), (0, 0, 12)), color=C((0.38, 0.34, 0.3, 1)), collide=(0.2, 0.7), land_fade=True),
    ]
    effect("ScrapeDust", 1.6, tracks, header="Dust and grit kicked out of the ground by a scraping hull (air frame).")



# =====================================================================================
# THE TOOLS (scripts/tool_belt.lua) — every beam, mark and hold is a particle
# effect on a pooled node (prefabs/Fx*.prefab.ron), never a drawn line.
# =====================================================================================
def vortex(cx, cy, cz, ax, ay, az, s):
    return f"Vortex(center: ({fnum(cx)}, {fnum(cy)}, {fnum(cz)}), axis: ({fnum(ax)}, {fnum(ay)}, {fnum(az)}), strength: {fnum(s)})"


def pull(cx, cy, cz, s):
    return f"Point(center: ({fnum(cx)}, {fnum(cy)}, {fnum(cz)}), strength: {fnum(s)})"


def tools():
    BEAM = (24, (0, 0, -10), 0.0, 0, 0)
    # FILL: the same tool laying rock back down — a cooler, denser beam, a
    # slurry of pale blue in a soft glow, slow scroll.
    L = 0.3
    tracks = [
        T("Core", TX + "beam/core.png", blend="Additive", beam=BEAM, clips=[],
          size=K([(0, 0.055), (0.5, 0.065), (1, 0.055)], repeat=True), color=C((2.2, 2.6, 3.0, 1.0))),
        T("Glow", TX + "beam/glow.png", blend="Additive", beam=BEAM, clips=[],
          size=K([(0, 0.26), (0.5, 0.3), (1, 0.26)], repeat=True),
          color=K([(0, (0.45, 0.8, 1.6, 0.55)), (0.5, (0.5, 0.85, 1.7, 0.65)), (1, (0.45, 0.8, 1.6, 0.55))], repeat=True)),
        T("Slurry", TX + "beam/shimmer.png", blend="Additive", beam=(32, (0, 0, -10), 0.02, 4.0, 6.0), clips=[],
          size=0.42, color=C((0.6, 0.9, 1.4, 0.3))),
        T("Muzzle", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.4), (0.5, 0.5), (1, 0.4)]), color=C((1.2, 2.0, 2.8, 0.7)), soft=0.05),
    ]
    effect("FillBeam", L, tracks, looping=True, header="""
The terrain laser laying rock back down (FILL): a cool blue-white core in a
soft blue glow, a slow slurry scroll. tool_belt aims it with setBeamEnd.""")

    # CUT: a hair-thin white-hot cutting line with a faint halo and a fast
    # scroll, a pinpoint star at the barrel.
    tracks = [
        T("Core", TX + "beam/core.png", blend="Additive", beam=BEAM, clips=[],
          size=K([(0, 0.014), (0.5, 0.017), (1, 0.014)], repeat=True), color=C((3.6, 3.5, 3.3, 1.0))),
        T("Halo", TX + "beam/glow.png", blend="Additive", beam=BEAM, clips=[],
          size=K([(0, 0.07), (0.5, 0.085), (1, 0.07)], repeat=True),
          color=K([(0, (1.8, 1.7, 1.5, 0.35)), (0.5, (1.9, 1.8, 1.6, 0.45)), (1, (1.8, 1.7, 1.5, 0.35))], repeat=True)),
        T("Scroll", TX + "beam/shimmer.png", blend="Additive", beam=(32, (0, 0, -10), 0.004, 11.0, 30.0), clips=[],
          size=0.11, color=C((1.6, 1.5, 1.3, 0.25))),
        T("MuzzleStar", TX + "glow/star.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.26), (0.5, 0.2), (1, 0.26)]), rot=R((0, 0, 0), RAD), color=C((2.8, 2.7, 2.4, 0.7)), soft=0.05),
    ]
    effect("CutBeam", L, tracks, looping=True, header="""
The terrain laser's CUT (E held): a hair-thin white-hot cutting line with a
faint halo and a fast scroll, a pinpoint star at the barrel.""")

    # Where the cut bites a plant: a fan of sparks and embers thrown back up
    # the beam (the node's +Y points back at the gun), sap and leaf bits,
    # a thread of smoke, a white-hot point.
    L = 0.4
    tracks = [
        T("Point", TX + "glow/core.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.16), (0.5, 0.2), (1, 0.16)]), color=C((3.4, 3.0, 2.4, 1.0)), soft=0.08),
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.7), (0.5, 0.85), (1, 0.7)]), color=C((1.6, 1.1, 0.6, 0.45)), soft=0.3),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.07,
          space="World", clips=stream(70, 0.45, 0, L, 0.5), shape=cone(38, 0.03), vel=R((0, 2.5, 0), (0, 6.5, 0)),
          gravity=1.0, size=0.045, collide=SPARK_HIT,
          color=K([(0, (3.4, 2.8, 1.8, 1)), (0.4, (2.6, 1.2, 0.3, 1)), (1, (1.0, 0.25, 0.04, 0))])),
        T("Embers", TX + "spark/dot.png", blend="Additive", space="World", clips=stream(10, 1.2, 0, L, 0.4),
          shape=cone(70, 0.05), vel=R((0, 0.8, 0), (0, 2.2, 0)), gravity=0.35, drag=1.5, forces=[wind(1.5), turb(1.5, 0.8)],
          size=K([(0, 0.05), (1, 0.02)]),
          color=K([(0, (2.6, 1.4, 0.5, 1)), (0.6, (1.8, 0.6, 0.1, 0.8)), (1, (0.4, 0.1, 0.02, 0))])),
        T("Sap", TX + "water/droplet.png", space="World", clips=stream(12, 0.7, 0, L, 0.3), shape=cone(55, 0.04),
          vel=R((0, 1.0, 0), (0, 2.8, 0)), gravity=1.0, size=R(0.02, 0.045), collide=(0.0, 0.9, True),
          color=C((0.55, 0.62, 0.3, 0.9)), lit=False),
        T("Leaf", TX + "leaf/leaf.png", orient="WorldFixed", space="World", clips=stream(7, 1.4, 0, L, 0.35),
          shape=cone(80, 0.1), vel=R((0, 0.6, 0), (0, 2.0, 0)), gravity=0.25, drag=2.0, forces=[turb(0.9, 2.5), wind(1.2)],
          size=R(0.06, 0.12), rot=R((0, 0, 0), RAD), spin=R((-4, -4, -6), (4, 4, 6)),
          color=K([(0, (0.42, 0.6, 0.26, 1)), (0.8, (0.45, 0.56, 0.25, 1)), (1, (0.45, 0.55, 0.25, 0))]), collide=(0, 0.95)),
        T("Smoke", TX + "smoke/wisp.png", space="World", clips=stream(6, 1.6, 0, L, 0.3), shape=cone(20, 0.08),
          vel=R((0, 0.4, 0), (0, 0.9, 0)), forces=[wind(1.2), turb(1.0, 0.5)], size=K([(0, 0.15), (1, 0.7)]),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.6), (0, 0, 0.6)),
          color=K([(0, (0.5, 0.48, 0.45, 0)), (0.15, (0.5, 0.48, 0.45, 0.35)), (1, (0.5, 0.48, 0.45, 0))]), soft=0.3),
    ]
    effect("CutBite", L, tracks, looping=True, header="""
Where the cutting beam bites a plant (the node's +Y points back up the beam
toward the gun): a fan of sparks and embers, sap, leaf bits, a thread of smoke
and a white-hot point. tool_belt scales it with setIntensity.""")

    # The GRAVITY GUN's tether: a blue-white core in a soft glow with two
    # crackling arcs thrown round it (beam jitter re-thrown 16 times a second),
    # and the claws flaring at the origin. Intensity follows the strain.
    L = 0.25
    arc = lambda name, seed, w, a: jitter(
        T(name, TX + "beam/core.png", blend="Additive", beam=(26, (0, 0, -10), 0, 0, 0), clips=[],
          size=K([(0, w), (0.5, w * 1.4), (1, w)], repeat=True), color=C((1.4, 2.2, 3.2, a))), 0.09, seed, 16.0)
    tracks = [
        T("Core", TX + "beam/core.png", blend="Additive", beam=BEAM, clips=[],
          size=K([(0, 0.03), (0.5, 0.036), (1, 0.03)], repeat=True), color=C((2.4, 2.9, 3.4, 1.0))),
        T("Glow", TX + "beam/glow.png", blend="Additive", beam=(24, (0, 0, -10), 0.03, 2.5, 3.0), clips=[],
          size=K([(0, 0.18), (0.5, 0.21), (1, 0.18)], repeat=True),
          color=K([(0, (0.5, 0.95, 1.8, 0.5)), (0.5, (0.55, 1.0, 1.9, 0.6)), (1, (0.5, 0.95, 1.8, 0.5))], repeat=True)),
        arc("ArcA", 11, 0.012, 0.9),
        arc("ArcB", 23, 0.009, 0.7),
        T("Claws", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.3), (0.5, 0.38), (1, 0.3)]), color=C((1.0, 1.9, 2.8, 0.8)), soft=0.05),
        T("ClawSparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.04,
          clips=stream(16, 0.3, 0, L, 0.4), shape=sphere(0.05), vel=R((0, 0.4, 0), (0, 1.4, 0)), drag=2.0,
          size=0.03, color=K([(0, (1.6, 2.4, 3.2, 1)), (1, (0.8, 1.4, 2.4, 0))])),
    ]
    effect("GravTether", L, tracks, looping=True, header="""
The gravity gun's hold: a blue-white core in a soft glow, two crackling arcs
thrown round it, the claws flaring at the origin. tool_belt aims it with
setBeamEnd and scales it with the strain (setIntensity).""")

    # The gun out and idle: a cold glow between the claws, breathing, with the
    # odd spark crawling across it.
    L = 1.4
    tracks = [
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.11), (0.5, 0.15), (1, 0.11)]), color=K([(0, (0.6, 1.2, 2.0, 0.5)), (0.5, (0.7, 1.4, 2.2, 0.7)), (1, (0.6, 1.2, 2.0, 0.5))]), soft=0.03),
        T("Crawl", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.05,
          clips=stream(5, 0.3, 0, L, 0.5), shape=sphere(0.04, True), vel=R((0, 0.2, 0), (0, 0.8, 0)), drag=3.0,
          size=0.022, color=K([(0, (1.6, 2.4, 3.2, 1)), (1, (0.8, 1.4, 2.4, 0))])),
    ]
    effect("GravIdle", L, tracks, looping=True, header="""
The gravity gun out and idle: a cold glow breathing between the claws, the
odd spark crawling across it. Rides the muzzle.""")

    # What the gun holds: an energy shell round the grab point and small
    # motes orbiting it, pulled in and whirled.
    L = 1.0
    tracks = [
        T("Shell", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.55), (0.5, 0.65), (1, 0.55)]), color=K([(0, (0.5, 0.9, 1.6, 0.35)), (0.5, (0.55, 1.0, 1.8, 0.45)), (1, (0.5, 0.9, 1.6, 0.35))]), soft=0.25),
        T("Spot", TX + "glow/tight.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.16), (0.5, 0.2), (1, 0.16)]), color=C((1.8, 2.6, 3.4, 0.9)), soft=0.05),
        T("Motes", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.06,
          clips=stream(26, 1.0, 0, L, 0.3), shape=sphere(0.42, True), vel=R((0, 0.1, 0), (0, 0.5, 0)),
          forces=[vortex(0, 0, 0, 0, 1, 0, 7.0), pull(0, 0, 0, 2.5)], drag=0.6, size=K([(0, 0.0), (0.15, 0.035), (0.85, 0.03), (1, 0)]),
          color=K([(0, (1.2, 2.0, 3.0, 1)), (1, (0.8, 1.6, 2.6, 0.6))])),
        T("Arcs", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.09,
          clips=stream(12, 0.25, 0, L, 0.5), shape=sphere(0.12), vel=R((0, 1.2, 0), (0, 3.0, 0)), drag=5.0,
          size=0.03, color=K([(0, (1.8, 2.6, 3.4, 1)), (1, (0.8, 1.4, 2.4, 0))])),
    ]
    effect("GravHold", L, tracks, looping=True, header="""
What the gravity gun holds: an energy shell round the grab point, motes
whirled round it and pulled in, short arcs crawling over it.""")

    # The punt (R): a shock ring across the aim at the muzzle, a flash, a cone
    # of sparks down the aim.
    tracks = [
        T("Ring", TX + "ring/shock.png", blend="Additive", orient="Horizontal", clips=burst(1, 0, 0.3, cj=0),
          size=K([(0, 0.12), (0.4, 0.7), (1, 1.0)]), color=K([(0, (1.4, 2.2, 3.0, 0.9)), (0.4, (1.0, 1.8, 2.8, 0.45)), (1, (0.8, 1.4, 2.4, 0))])),
        T("Flash", TX + "glow/tight.png", blend="Additive", clips=burst(1, 0, 0.14, cj=0),
          size=K([(0, 0.3), (0.3, 0.6), (1, 0.2)]), color=K([(0, (2.4, 3.0, 3.6, 1)), (1, (1.0, 1.6, 2.6, 0))])),
        T("Bolt", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.08, space="World",
          clips=burst(18, 0, 0.45, 0.4), shape=cone(16, 0.08), vel=R((0, 9, 0), (0, 20, 0)), drag=2.5,
          size=0.06, color=K([(0, (1.8, 2.6, 3.4, 1)), (1, (0.8, 1.4, 2.4, 0))])),
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.015, clips=burst(1, 0, 0.3, cj=0),
          size=K([(0, 0.3), (1, 1.2)]), color=K([(0, (1, 1, 1, 0.9)), (1, (1, 1, 1, 0))]), soft=0.2),
    ]
    effect("GravPunt", 0.5, tracks, header="""
The gravity gun's punt (R): a shock ring across the aim at the muzzle (+Y = the
aim), a flash, a bolt of sparks down the line, a kick of heat haze.""")

    # The thrown object: a streak of motes that keeps the throw and arcs down
    # with it, each with a short trail.
    tracks = [
        T("Streak", TX + "spark/dot.png", blend="Additive", space="World", inherit=1.0, clips=burst(9, 0, 0.7, 0.4),
          shape=sphere(0.25), vel=R((-0.6, -0.6, -0.6), (0.6, 0.6, 0.6)), gravity=1.0, drag=0.4,
          size=K([(0, 0.05), (1, 0.0)]), trail_=trail(0.25, 0.05, TX + "spark/streak.png", True, 0.03),
          color=K([(0, (1.6, 2.4, 3.2, 1)), (1, (0.8, 1.4, 2.4, 0))])),
    ]
    effect("GravTrail", 0.7, tracks, header="""
A thrown object's wake: motes that keep the throw's velocity and arc down
with it, each trailing a short streak.""")

    # Letting go: the shell pops, a few sparks, motes drifting off.
    tracks = [
        T("Pop", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, 0.25, cj=0),
          size=K([(0, 0.5), (1, 0.9)]), color=K([(0, (0.8, 1.4, 2.4, 0.5)), (1, (0.6, 1.0, 2.0, 0))]), soft=0.2),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.06, space="World",
          clips=burst(8, 0, 0.4, 0.4), shape=sphere(0.1, True), vel=R((0, 0.8, 0), (0, 2.4, 0)), gravity=0.8, drag=1.0,
          size=0.03, color=K([(0, (1.6, 2.4, 3.2, 1)), (1, (0.8, 1.4, 2.4, 0))])),
    ]
    effect("GravFizzle", 0.4, tracks, header="The gravity gun letting go: the shell pops, a few sparks drift off.")

    # The AIM MARK: a thin ring laid flat on the ground where the laser will
    # bite (a Horizontal billboard on a node stood up on the surface normal),
    # a faint glow under it. Tinted by the tool's state (setTint).
    L = 0.6
    tracks = [
        T("Ring", TX + "ring/mark.png", blend="Additive", orient="Horizontal", clips=burst(1, 0, L, cj=0),
          size=K([(0, 1.0), (0.5, 1.03), (1, 1.0)]), color=K([(0, (1, 1, 1, 0.85)), (0.5, (1, 1, 1, 1.0)), (1, (1, 1, 1, 0.85))]), soft=0.02),
        T("Wash", TX + "glow/soft.png", blend="Additive", orient="Horizontal", clips=burst(1, 0, L, cj=0),
          size=1.3, color=C((1, 1, 1, 0.12)), soft=0.1),
    ]
    effect("AimMark", L, tracks, looping=True, header="""
The terrain laser's aim mark: a thin ring laid flat on the ground at the bite
(the node is stood up on the surface normal), a faint wash under it. The tool
belt sizes it with the node's scale and colours it with setTint.""")

    # The PLANT MARK: the plant the tool has locked onto. Motes rise along its
    # whole body (the node is scaled to the plant: width across, height up) and
    # a faint sleeve of light stands round the stem. Tinted by state.
    L = 1.6
    tracks = [
        T("Motes", TX + "spark/dot.png", blend="Additive", clips=stream(14, 1.6, 0, L, 0.3),
          shape=cone(12, 0.5), vel=R((0, 0.45, 0), (0, 0.75, 0)), forces=[turb(2.0, 0.12)],
          size=K([(0, 0.0), (0.1, 0.028), (0.8, 0.024), (1, 0.0)]),
          color=K([(0, (1, 1, 1, 0.9)), (1, (1, 1, 1, 0.5))])),
    ]
    effect("PlantMark", L, tracks, looping=True, header="""
The plant the tool is locked onto: motes rising through its whole body (the
node is scaled to the plant: its spread across, its height up; the ring at its
foot is the AimMark node). The tool belt colours it with setTint.""")

    # COLLECTED: what a cut plant or a stowed chunk gives flies into the pack
    # — a bright mote with a streak and a few leaf bits, thrown at the crew
    # (the emitter velocity is the throw; everything inherits it).
    tracks = [
        T("Mote", TX + "glow/tight.png", blend="Additive", space="World", inherit=1.0, clips=burst(1, 0, 0.42, cj=0),
          size=K([(0, 0.12), (0.7, 0.16), (1, 0.0)]), trail_=trail(0.3, 0.09, TX + "spark/streak.png", True, 0.02),
          color=K([(0, (1.6, 2.4, 2.2, 1)), (1, (1.0, 1.6, 1.4, 0))])),
        T("Bits", TX + "leaf/leaf.png", orient="WorldFixed", space="World", inherit=0.85, clips=burst(6, 0, 0.5, 0.3),
          shape=sphere(0.2), vel=R((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), drag=1.0,
          size=R(0.05, 0.1), rot=R((0, 0, 0), RAD), spin=R((-6, -6, -8), (6, 6, 8)),
          color=K([(0, (0.5, 0.65, 0.3, 1)), (1, (0.5, 0.6, 0.3, 0))])),
    ]
    effect("Collect", 0.5, tracks, header="""
Something going into the pack: a bright mote with a streak and a few bits,
thrown at the crew (spawnEffect's vel is the throw; the tracks inherit it).""")

    # FILL's deposit: where the slurry lands — a cool plasma pool, drops of
    # slurry falling off it, steam.
    L = 0.5
    tracks = [
        T("Pool", TX + "glow/core.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.8), (0.5, 0.95), (1, 0.8)]), color=C((0.9, 1.6, 2.6, 1.0)), soft=0.15),
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 2.4), (0.5, 2.8), (1, 2.4)]), color=C((0.5, 0.9, 1.6, 0.4)), soft=0.4),
        T("Drops", TX + "water/droplet.png", space="World", clips=stream(24, 0.7, 0, L, 0.4), shape=cone(50, 0.3),
          vel=R((0, 1.5, 0), (0, 3.5, 0)), gravity=1.0, size=R(0.03, 0.07), collide=(0.0, 0.9, True),
          color=K([(0, (1.2, 1.8, 2.6, 1.0)), (0.5, (0.5, 0.55, 0.6, 1.0)), (1, (0.4, 0.42, 0.45, 0.8))]), lit=False),
        T("Steam", TX + "smoke/soft.png", clips=stream(10, 1.4, 0, L, 0.3), shape=cone(30, 0.3),
          vel=R((0, 0.5, 0), (0, 1.2, 0)), forces=[wind(1.0), push(0, 1, 0, 0.6), turb(1.2, 0.6)],
          size=K([(0, 0.3), (1, 1.6)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.7, 0.74, 0.78, 0)), (0.15, (0.7, 0.74, 0.78, 0.35)), (1, (0.7, 0.74, 0.78, 0))]), soft=0.4),
    ]
    effect("FillDeposit", L, tracks, looping=True, header="""
Where FILL lays its rock: a cool plasma pool, slurry drops falling off it,
steam. The node's +Y is the surface normal.""")


def step_dust():
    tracks = [
        T("Puff", TX + "smoke/billow_b.png", forces=[wind(2.5)], clips=burst(3, 0, 1.1, 0.3), shape=sphere(0.12),
          vel=R((-0.35, 0.1, -0.35), (0.35, 0.5, 0.35)), gravity=0.04,
          size=K([(0, 0.18), (1, 0.75)]), rot=R((0, 0, 0), RAD), squash=R(0.75, 1.3),
          color=K([(0, (0.66, 0.6, 0.52, 0)), (0.1, (0.64, 0.58, 0.5, 0.62)), (1, (0.62, 0.58, 0.52, 0))]),
          soft=0.25),
        T("Grains", TX + "debris/grit.png", clips=burst(1, 0, 0.5, 0.3, cj=0.5), shape=sphere(0.08),
          vel=R((-0.3, -0.3, -0.3), (0.3, 0.3, 0.3)), gravity=1.0, size=0.18, rot=R((0, 0, 0), RAD),
          color=K([(0, (0.45, 0.4, 0.35, 0.9)), (1, (0.45, 0.4, 0.35, 0))]), collide=(0, 0.9)),
    ]
    effect("StepDust", 1.1, tracks, header="A boot scuffing dusty ground (air frame).")


# =====================================================================================
# MINING LASER
# =====================================================================================
def mining_beam():
    L = 0.3
    tracks = [
        T("Core", TX + "beam/core.png", blend="Additive", beam=(24, (0, 0, -10), 0.0, 0, 0), clips=[],
          size=K([(0, 0.05), (0.33, 0.062), (0.66, 0.046), (1, 0.05)], repeat=True),
          color=C((3.2, 3.0, 2.7, 1.0))),
        T("Glow", TX + "beam/glow.png", blend="Additive", beam=(24, (0, 0, -10), 0.0, 0, 0), clips=[],
          size=K([(0, 0.24), (0.5, 0.28), (1, 0.24)], repeat=True),
          color=K([(0, (1.7, 0.62, 0.22, 0.6)), (0.5, (1.8, 0.7, 0.26, 0.7)), (1, (1.7, 0.62, 0.22, 0.6))],
                  repeat=True)),
        T("Shimmer", TX + "beam/shimmer.png", blend="Additive", beam=(32, (0, 0, -10), 0.012, 7.0, 14.0),
          clips=[], size=0.5, color=C((1.2, 0.5, 0.2, 0.2))),
        T("Muzzle", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.45), (0.5, 0.6), (1, 0.45)]), color=C((2.4, 1.3, 0.6, 0.8)), soft=0.05),
        T("MuzzleStar", TX + "glow/star.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.5), (0.5, 0.42), (1, 0.5)]), rot=R((0, 0, 0), RAD), color=C((2.4, 1.8, 1.3, 0.6)),
          soft=0.05),
    ]
    effect("MiningBeam", L, tracks, looping=True, header="""
The mining laser: a white-hot core inside an orange glow, a scrolling heat
shimmer, and the emitter flaring at the barrel. tool_belt aims it with
setBeamEnd and scales it with setIntensity (charge, heat, focus).""")


def mining_impact():
    L = 0.5
    tracks = [
        T("Molten", TX + "glow/core.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.9), (0.3, 1.1), (0.6, 0.85), (1, 0.9)]),
          color=K([(0, (3.2, 1.8, 0.7, 1)), (0.5, (3.4, 2.0, 0.8, 1)), (1, (3.2, 1.8, 0.7, 1))]), soft=0.15),
        T("Glow", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 3.0), (0.5, 3.5), (1, 3.0)]), color=C((1.5, 0.55, 0.18, 0.55)), soft=0.4),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.09,
          clips=stream(80, 0.5, 0, L, 0.5), shape=cone(70, 0.12), vel=R((0, 3, 0), (0, 8, 0)), drag=0.4,
          forces=[push(0, -1, 0, 9.0)], size=0.08,
          color=K([(0, (3.4, 2.5, 1.4, 1)), (0.4, (2.4, 0.9, 0.2, 1)), (1, (1.0, 0.25, 0.04, 0))])),
        T("Spatter", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.03,
          clips=stream(18, 0.8, 0, L, 0.4), shape=cone(45, 0.1), vel=R((0, 2, 0), (0, 5, 0)),
          forces=[push(0, -1, 0, 9.0)], size=0.11,
          color=K([(0, (3, 1.6, 0.5, 1)), (0.6, (1.6, 0.4, 0.05, 1)), (1, (0.3, 0.08, 0.02, 0))])),
        T("Vapour", TX + "smoke/soft.png", clips=stream(16, 1.3, 0, L, 0.3), shape=cone(25, 0.2),
          vel=R((0, 0.6, 0), (0, 1.5, 0)), forces=[wind(1.0), push(0, 1, 0, 0.8), turb(1.2, 0.8)],
          size=K([(0, 0.3), (1, 1.8)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.62, 0.58, 0.55, 0)), (0.15, (0.58, 0.55, 0.52, 0.45)), (1, (0.55, 0.53, 0.5, 0))]),
          soft=0.4),
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.012, clips=stream(10, 0.9, 0, L, 0.2),
          shape=cone(15, 0.15), vel=R((0, 0.8, 0), (0, 1.6, 0)), size=K([(0, 0.4), (1, 1.4)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (1, 1, 1, 0)), (0.2, (1, 1, 1, 0.9)), (1, (1, 1, 1, 0))]), soft=0.3),
    ]
    effect("MiningImpact", L, tracks, looping=True, header="""
Where the laser meets rock: molten glow, a fountain of sparks and molten
spatter, and rock vapour. The 'Laser Impact' node is turned by vfx.lua so +Y
is the planet's up (local gravity is a Directional force).""")

    tracks = [
        T("Chips", mesh=ROCK, space="World", inherit=1.0, clips=burst(3, 0, 1.3, 0.3, cj=0.5),
          shape=cone(50, 0.1), vel=R((0, 2.5, 0), (0, 5.5, 0)), gravity=1.0, size=R(0.04, 0.1),
          rot=R((0, 0, 0), (6.28, 6.28, 6.28)), spin=R((-14, -14, -14), (14, 14, 14)),
          color=C((0.3, 0.27, 0.25, 1)), lit=True, collide=(0.3, 0.5), land_fade=True),
        T("Hot", TX + "chip_glow.png", space="World", enabled=False, clips=[], size=0.1),
        T("Grit", TX + "debris/chip_b.png", space="World", inherit=1.0, clips=burst(5, 0, 0.9, 0.3),
          shape=cone(55, 0.08), vel=R((0, 2.5, 0), (0, 6, 0)), gravity=1.0, size=R(0.03, 0.07),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -15), (0, 0, 15)),
          color=K([(0, (1.6, 0.7, 0.3, 1)), (0.25, (0.35, 0.3, 0.27, 1)), (1, (0.33, 0.3, 0.27, 1))]),
          collide=(0.2, 0.6), land_fade=True),
    ]
    tracks = [t for t in tracks if '"Hot"' not in t]
    effect("LaserChips", 1.3, tracks, header="Rock chips spalled off by the laser, thrown off the surface normal (vfx.lua adds it).")


def ore_break():
    tracks = [
        T("Glint", TX + "glow/star.png", blend="Additive", clips=burst(1, 0, 0.22, cj=0),
          size=K([(0, 0.6), (0.3, 2.2), (1, 1.4)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (2.6, 2.6, 2.4, 1)), (1, (1.6, 1.4, 1.0, 0))])),
        T("Chunks", mesh=ROCK, space="World", inherit=1.0, clips=burst(9, 0, 1.6, 0.3), shape=cone(55, 0.2),
          vel=R((0, 2, 0), (0, 6, 0)), gravity=1.0, size=R(0.12, 0.28), rot=R((0, 0, 0), (6.28, 6.28, 6.28)),
          spin=R((-10, -10, -10), (10, 10, 10)), color=C((0.45, 0.42, 0.38, 1)), lit=True, collide=(0.3, 0.5), land_fade=True),
        T("Shards", TX + "debris/chip_a.png", space="World", inherit=1.0, clips=burst(14, 0, 1.1, 0.4),
          shape=cone(60, 0.15), vel=R((0, 3, 0), (0, 8, 0)), gravity=1.0, size=R(0.04, 0.1),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -14), (0, 0, 14)), color=C((0.45, 0.42, 0.38, 1)), collide=(0.2, 0.6), land_fade=True),
        T("Sparkle", TX + "glow/star.png", blend="Additive", space="World", inherit=1.0,
          clips=burst(6, 0, 0.9, 0.4), shape=cone(50, 0.15), vel=R((0, 2, 0), (0, 5, 0)), gravity=1.0,
          size=K([(0, 0.35), (0.5, 0.15), (0.7, 0.3), (1, 0)]), rot=R((0, 0, 0), RAD),
          color=C((1.8, 2.0, 2.2, 0.9))),

        T("Dust", TX + "smoke/billow_a.png", forces=[wind(2.5)], clips=burst(12, 0, 1.8, 0.3), shape=sphere(0.3),
          vel=R((0, 0.5, 0), (0, 2.5, 0)), gravity=0.03, size=K([(0, 0.4), (1, 2.0)]),
          rot=R((0, 0, 0), RAD), squash=R(0.7, 1.3),
          color=K([(0, (0.6, 0.56, 0.5, 0)), (0.07, (0.58, 0.55, 0.5, 0.78)), (1, (0.56, 0.54, 0.5, 0))]),
          soft=0.5),
    ]
    effect("OreBreak", 1.8, tracks, header="A unit of rock or ore breaking free: chunks, shards, a glint and dust.")


# =====================================================================================
# HARVEST CUTTER / SPADE
# =====================================================================================
def cutter():
    tracks = [
        T("Chips", TX + "debris/chip_b.png", space="World", inherit=1.0, clips=burst(4, 0, 0.8, 0.3, cj=0.4),
          shape=cone(60, 0.06), vel=R((0, 1.5, 0), (0, 4, 0)), gravity=1.0, size=R(0.025, 0.06),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -15), (0, 0, 15)), color=C((0.55, 0.42, 0.26, 1)), collide=(0.2, 0.7), land_fade=True),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.05,
          space="World", inherit=1.0, clips=burst(5, 0, 0.35, 0.4), shape=cone(60, 0.05),
          vel=R((0, 2, 0), (0, 5, 0)), gravity=1.0, size=0.04,
          color=K([(0, (3, 2.2, 1.2, 1)), (1, (1.2, 0.4, 0.05, 0))]), collide=SPARK_HIT),
    ]
    effect("CutChips", 0.8, tracks, header="Harvest cutter biting into a stem: wood chips, sparks, sap steam.")
    tracks = [
        T("Leaves", TX + "leaf/leaf.png", orient="WorldFixed", clips=burst(26, 0, 3.0, 0.35),
          shape=sphere(0.8), vel=R((0, 1, 0), (0, 3.5, 0)), gravity=0.22, drag=2.2,
          forces=[turb(0.8, 3.5)], size=R(0.09, 0.17), rot=R((0, 0, 0), RAD), spin=R((-4, -4, -6), (4, 4, 6)),
          color=K([(0, (0.42, 0.62, 0.26, 1)), (0.8, (0.45, 0.58, 0.25, 1)), (1, (0.45, 0.55, 0.25, 0))]), collide=(0, 0.95)),
        T("LeavesDry", TX + "leaf/leaf.png", orient="WorldFixed", clips=burst(10, 0, 3.0, 0.35),
          shape=sphere(0.6), vel=R((0, 1, 0), (0, 3, 0)), gravity=0.25, drag=2.0, forces=[turb(0.8, 3.0)],
          size=R(0.08, 0.14), rot=R((0, 0, 0), RAD), spin=R((-4, -4, -6), (4, 4, 6)),
          color=K([(0, (0.62, 0.5, 0.25, 1)), (0.8, (0.6, 0.48, 0.25, 1)), (1, (0.6, 0.48, 0.25, 0))]), collide=(0, 0.9)),
        T("Dust", TX + "smoke/clump_b.png", forces=[wind(2.0)], clips=burst(6, 0, 1.6, 0.3), shape=sphere(0.4),
          vel=R((0, 0.3, 0), (0, 1.5, 0)), gravity=0.03, size=K([(0, 0.4), (1, 1.6)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (0.58, 0.55, 0.46, 0)), (0.1, (0.56, 0.53, 0.45, 0.45)),
                                         (1, (0.55, 0.52, 0.45, 0))]), soft=0.5),
        T("Chips", TX + "debris/chip_b.png", clips=burst(10, 0, 1.0, 0.3), shape=sphere(0.25, True),
          vel=R((0, 1.5, 0), (0, 4, 0)), gravity=1.0, size=R(0.03, 0.07), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -15), (0, 0, 15)), color=C((0.5, 0.38, 0.24, 1)), collide=(0.05, 0.85), land_fade=True),
    ]
    effect("PlantFall", 3.0, tracks, header="A plant harvested: leaves fluttering down, chips and dust.")


def dig():
    tracks = [
        T("Clods", mesh=ROCK, space="World", inherit=1.0, clips=burst(7, 0, 1.2, 0.3), shape=cone(50, 0.3),
          vel=R((0, 2.0, 0), (0, 4.0, 0)), gravity=1.0, size=R(0.06, 0.16),
          rot=R((0, 0, 0), (6.28, 6.28, 6.28)), spin=R((-8, -8, -8), (8, 8, 8)),
          color=C((0.32, 0.26, 0.2, 1)), lit=True, collide=(0.15, 0.8), land_fade=True),
        T("Crumbs", TX + "debris/chip_a.png", space="World", inherit=1.0, clips=burst(14, 0, 0.9, 0.3),
          shape=cone(55, 0.3), vel=R((0, 2, 0), (0, 4.5, 0)), gravity=1.0, size=R(0.03, 0.07),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -12), (0, 0, 12)), color=C((0.36, 0.3, 0.24, 1)),
          collide=(0.15, 0.8), land_fade=True),

        T("Dust", TX + "smoke/clump_a.png", forces=[wind(2.0)], clips=burst(6, 0, 1.6, 0.3), shape=sphere(0.6),
          vel=R((0, 0.3, 0), (0, 1.2, 0)), gravity=0.03, size=K([(0, 0.6), (1, 2.2)]),
          rot=R((0, 0, 0), RAD), squash=R(0.7, 1.3),
          color=K([(0, (0.55, 0.48, 0.4, 0)), (0.1, (0.53, 0.47, 0.4, 0.72)), (1, (0.52, 0.47, 0.42, 0))]),
          soft=0.6),
    ]
    effect("DigClods", 1.6, tracks, header="Terrain spade: clods and crumbs thrown up, a puff of dust.")


# =====================================================================================
# WATER
# =====================================================================================
def water():
    tracks = [
        T("Droplets", TX + "water/droplet.png", orient="Velocity", stretch=1.6, speed_stretch=0.05,
          space="World", inherit=1.0, clips=burst(36, 0, 1.4, 0.4), shape=cone(35, 0.35),
          vel=R((0, 2.0, 0), (0, 5.5, 0)), gravity=1.0, size=R(0.05, 0.11),
          color=K([(0, (0.9, 0.95, 1.0, 0.9)), (0.8, (0.85, 0.92, 1.0, 0.7)), (1, (0.85, 0.92, 1.0, 0))])),
        T("Sheet", TX + "water/splat_a.png", space="World", inherit=0.6, clips=burst(4, 0, 0.6, 0.3),
          shape=cone(40, 0.3), vel=R((0, 1.0, 0), (0, 2.5, 0)), gravity=0.6, size=K([(0, 0.6), (1, 1.6)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (0.9, 0.95, 1.0, 0.75)), (1, (0.9, 0.95, 1.0, 0))])),

        T("Mist", TX + "smoke/soft.png", forces=[wind(1.5)], clips=burst(6, 0, 2.2, 0.3), shape=sphere(0.6),
          vel=R((-0.3, 0, -0.3), (0.3, 0.6, 0.3)), gravity=-0.02, size=K([(0, 0.6), (1, 2.8)]),
          color=K([(0, (0.9, 0.94, 1.0, 0)), (0.12, (0.9, 0.94, 1.0, 0.35)), (1, (0.9, 0.94, 1.0, 0))]),
          soft=0.6),
    ]
    effect("SeaSpray", 2.2, tracks, header="Spray where a wave breaks or something hits the water (droplets ballistic off the given velocity).")
    tracks = [
        T("Bubbles", TX + "water/bubble.png", clips=burst(5, 0, 1.6, 0.4, cj=0.5), shape=sphere(0.2),
          vel=R((-0.15, -0.15, -0.15), (0.15, 0.15, 0.15)), gravity=-0.12, drag=1.5, forces=[turb(2.0, 1.2)],
          size=R(0.03, 0.08), color=K([(0, (0.85, 0.95, 1.0, 0.85)), (0.85, (0.85, 0.95, 1.0, 0.7)),
                                       (1, (0.85, 0.95, 1.0, 0))])),
    ]
    effect("Bubbles", 1.6, tracks, header="Air escaping a swimmer under water; rises toward the surface.")
    tracks = [
        T("Foam", TX + "water/foam.png", clips=burst(2, 0, 1.6, 0.3), shape=sphere(0.25),
          vel=R((-0.2, 0, -0.2), (0.2, 0.1, 0.2)), drag=2.0, size=K([(0, 0.4), (1, 1.4)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.95, 0.97, 1.0, 0.0)), (0.1, (0.95, 0.97, 1.0, 0.55)), (1, (0.92, 0.96, 1.0, 0))]),
          soft=0.15),
        T("Drops", TX + "water/droplet.png", orient="Velocity", stretch=1.4, clips=burst(3, 0, 0.6, 0.4, cj=0.6),
          shape=sphere(0.15), vel=R((0, 0.8, 0), (0, 1.8, 0)), gravity=1.0, size=0.05,
          color=K([(0, (0.9, 0.95, 1.0, 0.8)), (1, (0.9, 0.95, 1.0, 0))])),
    ]
    effect("Wake", 1.6, tracks, header="Foam and drops churned up by a swimmer at the surface.")



# =====================================================================================
# WEATHER (scripts/weather.lua)
# =====================================================================================
# Precipitation is not one big emitter glued to the camera: weather.lua drops a
# PATCH of it a few metres over the camera several times a second, upwind by
# however far the wind will carry it before it lands, and each patch rides the
# planet like every spawnEffect one-shot. So the drops fall through the world,
# not with the camera, and turning round does not swing the rain. Every track
# is World space with inherit_velocity 1: the patch is fired with the WIND as
# its velocity (relative to the planet), so drops and flakes drift and slant
# with it. Counts here are the full-intensity ones; the script scales them with
# spawnEffect's `intensity`.
#
# Physical numbers, so it looks like weather rather than a screensaver:
#   rain      2 mm drops fall at ~6.5 m/s, 4 mm at ~9 m/s (terminal velocity)
#   hail      1-2 cm stones at 15-20 m/s, and they bounce
#   snow      flakes at 0.5-1.5 m/s, tumbling, carried almost entirely by wind
#   ash       volcanic ash flakes: slower and darker than snow
#   dust      a haboob is a wall of suspended dust moving with the wind
def weather():
    # ── rain ──────────────────────────────────────────────────────────────────
    L = 2.4
    tracks = [
        # Streaks: what a drop looks like in a 1/60 s look — a short line along
        # its fall. Unlit: rain is seen by the sky light it refracts, which the
        # script hands each patch as its tint (bright by day, almost nothing at
        # night). A rounded-normal lit billboard shades a hair-thin streak
        # as a ball and it vanishes against the sky.
        T("Drops", TX + "water/droplet.png", orient="Velocity", stretch=3.5, speed_stretch=0.75, lit=False,
          vary=False, space="World", inherit=1.0, gravity=1.2, forces=[wind(1.0)], clips=burst(120, 0, 2.0, 0.12, pulses=4, interval=0.03),
          shape=box(14, 10, 14), vel=R((0, -9.5, 0), (0, -6.5, 0)), size=R(0.03, 0.05),
          color=K([(0, (0.82, 0.86, 0.92, 0)), (0.06, (0.82, 0.86, 0.92, 0.75)), (0.85, (0.82, 0.86, 0.92, 0.75)),
                   (1, (0.82, 0.86, 0.92, 0))])),
        # Curtains: the grey veils a heavy shower hangs in, sweeping by on the wind.
        T("Veil", TX + "smoke/soft.png", space="World", inherit=1.0, gravity=0.4, forces=[wind(1.0)], clips=burst(2, 0, L, 0.2, cj=0.5),
          shape=box(30, 4, 30), vel=R((0, -3.5, 0), (0, -2.5, 0)), size=R(5.0, 9.0), rot=R((0, 0, 0), RAD),
          # unlit and faint: a lit veil caught the sky light and showed as
          # bright white blobs against a dark storm (most of all at the pad)
          color=K([(0, (0.42, 0.45, 0.49, 0)), (0.3, (0.42, 0.45, 0.49, 0.045)), (1, (0.42, 0.45, 0.49, 0))]),
          soft=1.5, lit=False),
    ]
    effect("RainPatch", L, tracks, header="""
A patch of rain, fired a few metres over the camera by weather.lua several
times a second (with the wind as its velocity): lit streaks falling at
terminal velocity and a faint veil.""")

    # ── snow ──────────────────────────────────────────────────────────────────
    L = 6.0
    tracks = [
        T("Flakes", TX + "glow/tight.png", lit=False, vary=False, space="World", inherit=1.0,
          gravity=0.35, clips=burst(60, 0, 4.5, 0.25, pulses=4, interval=0.1), shape=box(15, 7, 15),
          vel=R((-0.25, -1.6, -0.25), (0.25, -0.8, 0.25)), forces=[wind(2.0), turb(0.5, 1.1)], size=R(0.11, 0.2),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -2), (0, 0, 2)),
          color=K([(0, (0.92, 0.94, 0.98, 0)), (0.06, (0.92, 0.94, 0.98, 0.95)), (0.88, (0.92, 0.94, 0.98, 0.95)),
                   (1, (0.92, 0.94, 0.98, 0))])),
        # The white-out of a blizzard: snow too fine and too dense to see as flakes.
        T("Drift", TX + "smoke/soft.png", space="World", inherit=1.0, gravity=0.12, forces=[wind(1.5)], clips=burst(2, 0, 4.0, 0.3, cj=0.5),
          shape=box(30, 4, 30), vel=R((0, -0.8, 0), (0, -0.3, 0)), size=R(6.0, 11.0), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.85, 0.87, 0.9, 0)), (0.3, (0.85, 0.87, 0.9, 0.09)), (1, (0.85, 0.87, 0.9, 0))]),
          soft=1.5),
    ]
    effect("SnowPatch", L, tracks, header="""
A patch of snow over the camera (weather.lua): tumbling flakes falling at
about a metre a second, which the wind carries more than gravity does, and
in a blizzard a drifting white-out.""")
    # A blizzard: the same snow, but driven sideways by a gale — flakes drawn
    # along their motion, so the wind itself is visible. Fired beside
    # SnowPatch only once the storm is up.
    tracks = [
        T("Driven", TX + "glow/tight.png", orient="Velocity", stretch=1.0, speed_stretch=0.35, lit=False,
          vary=False, space="World", inherit=1.0, gravity=0.25, clips=burst(30, 0, 2.2, 0.2, pulses=3, interval=0.1),
          shape=box(14, 5, 14), vel=R((-0.5, -1.5, -0.5), (0.5, -0.6, 0.5)), forces=[wind(2.0), turb(0.8, 2.0)],
          size=R(0.06, 0.11),
          color=K([(0, (0.92, 0.94, 0.98, 0)), (0.1, (0.92, 0.94, 0.98, 0.85)), (0.85, (0.92, 0.94, 0.98, 0.85)),
                   (1, (0.92, 0.94, 0.98, 0))])),
    ]
    effect("SnowDrift", 2.4, tracks, header="""
Blizzard snow (weather.lua): flakes driven sideways by the gale and drawn
along their motion, fired beside SnowPatch once a cold storm is up.""")


    # ── hail ──────────────────────────────────────────────────────────────────
    L = 2.0
    tracks = [
        T("Stones", TX + "spark/dot.png", orient="Velocity", stretch=1.2, speed_stretch=0.07, lit=False,
          vary=False, space="World", inherit=1.0, gravity=1.0, forces=[wind(0.4)], clips=burst(40, 0, 1.4, 0.1, pulses=3, interval=0.05),
          shape=box(14, 8, 14), vel=R((0, -20, 0), (0, -15, 0)), size=R(0.06, 0.1),
          color=K([(0, (0.9, 0.93, 0.96, 0)), (0.05, (0.9, 0.93, 0.96, 0.85)), (0.9, (0.9, 0.93, 0.96, 0.85)),
                   (1, (0.9, 0.93, 0.96, 0))])),
        # A few of them meet the ground (rc6 particle collision) and bounce —
        # the thing that tells hail from rain at a glance. Only a few: each
        # costs a ray a frame.
        T("Bouncers", TX + "spark/dot.png", lit=False, vary=False, space="World", inherit=0.6,
          clips=burst(3, 0, 1.8, 0.2), shape=box(8, 3, 8), vel=R((-0.5, -15, -0.5), (0.5, -11, 0.5)),
          gravity=1.0, size=R(0.08, 0.12), color=C((0.95, 0.97, 1.0, 1.0)), collide=(0.5, 0.3),
          land_fade=True),
    ]
    effect("HailPatch", L, tracks, header="""
A patch of hail (weather.lua): ice stones falling at 15-20 m/s, a few of which
hit the ground and bounce (particle collision).""")

    # ── dust ──────────────────────────────────────────────────────────────────
    L = 4.5
    tracks = [
        # Sheets of suspended dust riding the wind. Tinted to the ground by the
        # script (spawnEffect tint), the way vfx.lua tints a footstep's dust.
        T("Sheets", TX + "smoke/billow_a.png", lit=False, vary=True, space="World", inherit=1.0,
          forces=[wind(1.0)], clips=burst(7, 0, 4.2, 0.25, cj=0.4), shape=box(30, 5, 30), vel=R((-0.5, -0.3, -0.5), (0.5, 0.5, 0.5)),
          size=K([(0, 6.0), (1, 11.0)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.15), (0, 0, 0.15)),
          color=K([(0, (0.95, 0.9, 0.82, 0)), (0.25, (0.95, 0.9, 0.82, 0.16)), (0.7, (0.95, 0.9, 0.82, 0.13)),
                   (1, (0.95, 0.9, 0.82, 0))]), soft=2.0),
        # Grit: the sand actually in the air, streaking past.
        T("Grit", TX + "debris/grit.png", orient="Velocity", stretch=1.5, speed_stretch=0.25, lit=False,
          vary=False, space="World", inherit=1.0, gravity=0.1, forces=[wind(1.5)], clips=burst(60, 0, 1.6, 0.2, pulses=3, interval=0.1),
          shape=box(20, 3, 20), vel=R((-0.6, -0.8, -0.6), (0.6, 0.4, 0.6)), size=R(0.03, 0.05),
          color=K([(0, (0.85, 0.78, 0.66, 0)), (0.1, (0.85, 0.78, 0.66, 0.8)), (1, (0.85, 0.78, 0.66, 0))])),
    ]
    effect("DustPatch", L, tracks, header="""
A patch of a dust storm (weather.lua): billowing sheets and grit carried on
the wind (the patch's velocity). Unlit: the script tints each patch with the
world's ground colour times the day's light.""")

    # ── ash ───────────────────────────────────────────────────────────────────
    L = 8.0
    tracks = [
        T("Flakes", TX + "smoke/soot.png", lit=True, vary=False, space="World", inherit=1.0,
          gravity=0.17, clips=burst(30, 0, 7.5, 0.25, pulses=3, interval=0.2), shape=box(30, 9, 30),
          vel=R((-0.2, -1.0, -0.2), (0.2, -0.45, 0.2)), forces=[wind(1.5), turb(0.4, 0.8)], size=R(0.07, 0.14),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -3), (0, 0, 3)),
          color=K([(0, (0.24, 0.23, 0.22, 0)), (0.06, (0.24, 0.23, 0.22, 0.9)), (0.9, (0.24, 0.23, 0.22, 0.9)),
                   (1, (0.24, 0.23, 0.22, 0))])),
        # The odd ember still glowing as it comes down.
        T("Embers", TX + "glow/tight.png", blend="Additive", space="World", inherit=1.0,
          gravity=0.1, clips=burst(2, 0, 5.0, 0.3, cj=0.8), shape=box(24, 8, 24), vel=R((-0.3, -0.9, -0.3), (0.3, -0.4, 0.3)),
          forces=[wind(1.0), turb(0.6, 1.0)], size=R(0.04, 0.07),
          color=K([(0, (2.2, 0.8, 0.25, 0)), (0.1, (2.2, 0.8, 0.25, 0.8)), (0.7, (1.4, 0.4, 0.1, 0.5)),
                   (1, (0.6, 0.15, 0.05, 0))])),
    ]
    effect("AshPatch", L, tracks, header="""
A patch of volcanic ash fall (weather.lua, lava worlds): dark tumbling flakes
and the odd ember.""")

    # ── lightning ─────────────────────────────────────────────────────────────
    # Authored as a bolt 40 m tall from the ground point up (+Y is the planet's
    # up); weather.lua scales it to the cloud base. One strike is one channel,
    # thrown once (jitter_rate 0) and held for the whole effect, so its shape
    # never changes while it is seen. Its light follows FLASH (seconds, peak 1):
    # a faint leader for three frames, the return stroke, a steady decay, one
    # restrike surge down the same channel (no dark gap: a surge, not a
    # strobe), and an afterglow. weather.lua's sky flash and vfx.lua's point
    # light play the SAME keys (weather.lua FLASH), so nothing in the scene
    # pulses out of step with the bolt.
    L = FLASH[-1][0]
    env = [(t / L, v) for t, v in FLASH]
    tracks = [
        # The channel: a thin white-hot core.
        jitter(T("Bolt", TX + "beam/core.png", blend="Additive", beam=(32, (0, 40, 0), 0, 0, 0), clips=[],
                 size=K([(t, 0.55 + 0.35 * v) for t, v in env]),
                 color=K([(t, (3.2 * v, 3.3 * v, 4.0 * v, min(1.0, v))) for t, v in env])), 3.0, 7),
        # Its glow, on the same channel (same seed and segments), drawn with
        # the core's own texture at four times the width: beam/core.png is
        # clear at its edges, so the wedge the engine leaves at each kink of
        # a jittered chain (segments are separate quads, card 0465) falls
        # where nothing is drawn. A soft-edged glow texture shows every one.
        jitter(T("Glow", TX + "beam/core.png", blend="Additive", beam=(32, (0, 40, 0), 0, 0, 0), clips=[],
                 size=K([(t, 2.4 + 1.0 * v) for t, v in env]),
                 color=K([(t, (0.6 * v, 0.65 * v, 1.0 * v, 0.45 * v)) for t, v in env])), 3.0, 7),
        # The air lit round it: one straight, wide, faint column, wider than
        # the channel strays (jitter 3 m), so it has no kinks to break.
        T("Haze", TX + "beam/glow.png", blend="Additive", beam=(1, (0, 40, 0), 0, 0, 0), clips=[],
          size=K([(t, 9.0 + 2.0 * v) for t, v in env]),
          color=K([(t, (0.22 * v, 0.24 * v, 0.38 * v, 0.3 * v)) for t, v in env])),
    ]
    effect("Lightning", L, tracks, header="""
A cloud-to-ground lightning stroke (weather.lua): one jagged white-violet
channel 40 m tall from the ground point up, scaled by the script to the cloud
base. The channel is beam jitter thrown once per strike and held: a faint
leader, the return stroke, a steady decay, one restrike surge down the same
channel and an afterglow (tools/gen_vfx.py FLASH; weather.lua plays the same
keys for the sky and the point light).""")
    tracks = [
        T("Cloud", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0), shape=point(),
          vel=(0, 0, 0), size=K([(0, 26), (1, 30)]),
          color=K([(t, (1.0 * v, 1.05 * v, 1.3 * v, 0.55 * v)) for t, v in env]), soft=4.0),
    ]
    effect("LightningGlow", L, tracks, header="""
The cloud base lit from inside where a lightning bolt leaves it (weather.lua
fires it at the top of the bolt, in step with Lightning, on the same FLASH).""")


def main():
    import sys
    if "weather" in sys.argv[1:]:
        weather()
        return
    flame()
    pad_blast()
    touch_dust()
    ground_shock()
    water_ring()
    explosion("Explosion", 1.25, "A tank or engine detonating: flash, fireball, black smoke column, shock, sparks, burning streamers, debris.")
    explosion("ExplosionSmall", 0.6, "A structural part failing: a smaller flash, fire and smoke, fewer fragments.")
    sep_puff()
    chute_puff()
    smoke_puff()
    reentry()
    scrape()
    step_dust()
    mining_beam()
    mining_impact()
    ore_break()
    cutter()
    dig()
    tools()
    water()
    weather()


if __name__ == "__main__":
    main()
