#!/usr/bin/env python3
"""The vehicle feedback effects, as data: `python3 tools/gen_vfx_vehicle.py`
writes ONLY the effects below into vfx/*.vfx.ron (tools/gen_vfx.py keeps the
rest). They are played by scripts/vehicle_fx.lua and scripts/vfx.lua; the
design, triggers, costs and quality tiers are in docs/vfx-feedback.md.

Node effects ride prefabs/FxJet.prefab.ron (on a turbojet's nozzle, local +Y
= out of the nozzle) and prefabs/FxReentryWake.prefab.ron. Their World tracks
are left in the planet's frame (the engine carries them with the world the
node is over), so smoke and contrails stay over the ground they were laid
on; none of them inherit the emitter's velocity, which would be the world's
orbital speed. One-shots are fired through spawnEffect with a velocity
relative to the planet (vfx.lua's rule).
"""
from vfx_ron import *  # the tiny RON DSL beside this file

TX = "textures/vfx/"
PLATE = "models/parts/plate.glb"
RAD = (0, 0, 6.2832)
G = 8.5


def wind(c):
    return f"Wind(coupling: {fnum(c)})"


# =====================================================================================
# TURBOJET (prefabs/FxJet: Jet Plume, Jet Haze, Jet Smoke, Jet Contrail, Contrail Puffs)
# =====================================================================================
def jet():
    L = 0.5
    # A turbojet's exhaust is nearly clear: what tells you it runs is the heat
    # shimmer, the glow down the tailpipe and, at power, a faint orange core
    # you see best at dusk. setIntensity = spool (0..1).
    tracks = [
        # The tailpipe glowing: a warm disc at the nozzle face.
        T("Pipe", TX + "glow/soft.png", blend="Additive", clips=burst(1, 0, L, cj=0),
          size=K([(0, 0.95), (0.5, 1.05), (1, 0.95)]),
          color=K([(0, (1.5, 0.55, 0.18, 0.42)), (0.5, (1.6, 0.6, 0.2, 0.5)), (1, (1.5, 0.55, 0.18, 0.42))]), soft=0.15),
        # The hot core: short, fast, pale orange, thinning as it cools.
        T("Core", TX + "fire/tongue.png", blend="Additive", orient="Velocity", stretch=2.6,
          clips=stream(70, 0.13, 0, L, 0.2), shape=cone(2.5, 0.12), vel=R((0, 42, 0), (0, 52, 0)),
          size=K([(0, 0.55), (0.5, 0.75), (1, 0.9)]),
          color=K([(0, (1.8, 0.85, 0.35, 0.34)), (0.4, (1.4, 0.5, 0.16, 0.18)), (1, (0.8, 0.25, 0.06, 0))]),
          soft=0.15),
        # The hot gas spreading out of the core: barely there by day.
        T("Gas", TX + "glow/soft.png", blend="Additive", clips=stream(46, 0.28, 0, L, 0.2), shape=cone(4, 0.2),
          vel=R((0, 30, 0), (0, 40, 0)), drag=1.0, size=K([(0, 0.7), (1, 2.2)]),
          color=K([(0, (1.1, 0.5, 0.22, 0.14)), (0.5, (0.8, 0.3, 0.1, 0.06)), (1, (0.4, 0.12, 0.04, 0))]), soft=0.3),
    ]
    effect("JetPlume", L, tracks, looping=True, header="""
Turbojet exhaust: the glowing tailpipe, a short pale-orange core and the hot
gas thinning behind it. On prefabs/FxJet's "Jet Plume" node (local +Y = out of
the nozzle); vehicle_fx.lua drives setIntensity by the spool.""")

    # The shimmer: the clearest sign by day that the engine is running, and
    # how hard (setIntensity = spool). Its own node so Low can leave it off.
    tracks = [
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.045, clips=stream(36, 0.55, 0, L, 0.25),
          shape=cone(5, 0.3), vel=R((0, 16, 0), (0, 26, 0)), drag=0.8, size=K([(0, 0.8), (1, 3.2)]),
          rot=R((0, 0, 0), RAD), color=K([(0, (1, 1, 1, 0)), (0.12, (1, 1, 1, 1)), (1, (1, 1, 1, 0))]), soft=0.4),
    ]
    effect("JetHaze", L, tracks, looping=True, header="""
Heat shimmer behind a running turbojet (Distortion blend: bends the scene
behind it). prefabs/FxJet's "Jet Haze" node; off on Low.""")

    # Soot: an early turbojet smokes as it spools up and lays a thin brown-grey
    # trail at power. World track: left over the ground in the wind.
    tracks = [
        T("Soot", TX + "smoke/billow_b.png", space="World", clips=stream(24, 3.2, 0, 3.2, 0.3), shape=cone(4, 0.25),
          vel=R((0, 14, 0), (0, 22, 0)), forces=[wind(1.6), turb(0.3, 0.6)], gravity=-0.02,
          size=K([(0, 0.6), (0.25, 1.8), (1, 4.2)]), rot=R((0, 0, 0), RAD), spin=R((0, 0, -0.5), (0, 0, 0.5)),
          color=K([(0, (0.3, 0.28, 0.25, 0)), (0.06, (0.32, 0.3, 0.27, 0.34)), (0.5, (0.42, 0.41, 0.39, 0.16)),
                   (1, (0.5, 0.5, 0.5, 0))]), soft=1.0),
    ]
    effect("JetSmoke", 3.2, tracks, looping=True, header="""
Turbojet soot (World track, wind-borne): heavy at spool-up, a thin trail at
power. setIntensity = the smoke vehicle_fx.lua works out.""")

    # Contrail: a crisp ribbon along the jet's path (emitter-path trail; each
    # particle's ribbon covers its own age, so the newest metres are the
    # densest) that thins out over ~6 s.
    tracks = [
        T("Ribbon", TX + "smoke/soft.png", clips=stream(1.2, 6.0, 0, 6.0, 0.1), shape=point(), vel=(0, 0, 0),
          size=0.01, color=K([(0, (0.95, 0.96, 0.98, 0.5)), (0.6, (0.93, 0.94, 0.96, 0.3)), (1, (0.9, 0.9, 0.92, 0))]),
          trail_=trail(6.0, 1.4, TX + "smoke/soft.png", True, 1.5, True)),
    ]
    effect("JetContrail", 6.0, tracks, looping=True, header="""
Condensation trail: ribbons along the jet's path through cold air
(setIntensity 0..1 by how far past the frost point the air is).""")

    tracks = [
        T("Puff", TX + "smoke/soft.png", space="World", clips=stream(16, 7.0, 0, 7.0, 0.3), shape=sphere(0.4),
          vel=R((-0.3, 2, -0.3), (0.3, 5, 0.3)), forces=[wind(0.4), turb(0.08, 0.4)],
          size=K([(0, 1.0), (0.3, 3.0), (1, 6.5)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.95, 0.96, 0.98, 0)), (0.05, (0.95, 0.96, 0.98, 0.2)), (0.5, (0.93, 0.94, 0.96, 0.1)),
                   (1, (0.9, 0.9, 0.92, 0))]), soft=2.0),
    ]
    effect("ContrailPuffs", 7.0, tracks, looping=True, header="""
The contrail spreading and breaking up behind the ribbon (World track, wind).
High and Ultra only.""")


# =====================================================================================
# TYRES (one-shots, +Y = the ground's up)
# =====================================================================================
def tyres():
    # Dust thrown off a tyre on loose ground: low, rolling, settling. Fired
    # with the tyre's throw (a share of its velocity) so it trails behind.
    tracks = [
        T("Dust", TX + "smoke/clump_a.png", forces=[wind(1.4)], clips=burst(2, 0, 2.2, 0.3), shape=sphere(0.2),
          vel=R((-0.5, 0.4, -0.5), (0.5, 1.4, 0.5)), gravity=0.05, inherit=0.35, space="World",
          size=K([(0, 0.35), (0.3, 1.2), (1, 2.4)]), rot=R((0, 0, 0), RAD), squash=R(0.7, 1.3),
          color=K([(0, (0.66, 0.6, 0.52, 0)), (0.08, (0.64, 0.58, 0.5, 0.5)), (1, (0.62, 0.58, 0.52, 0))]),
          soft=0.6),
        T("Grit", TX + "debris/chip_a.png", clips=burst(3, 0, 0.8, 0.3, cj=0.6), shape=sphere(0.12),
          vel=R((-0.8, 1.0, -0.8), (0.8, 2.6, 0.8)), inherit=0.5, space="World", gravity=1.0,
          size=R(0.04, 0.09), rot=R((0, 0, 0), RAD), spin=R((0, 0, -12), (0, 0, 12)),
          color=C((0.38, 0.34, 0.3, 1)), collide=(0.2, 0.7), land_fade=True),
    ]
    effect("TyreDust", 2.2, tracks, header="Dust and grit off a tyre on loose ground (vehicle_fx.lua, pooled by rate).")

    # Rubber smoke off a sliding tyre on paving or the pad: pale blue-grey,
    # thick at the patch, drifting in the wind.
    tracks = [
        T("Smoke", TX + "smoke/soft.png", forces=[wind(1.0), turb(0.4, 0.5)], clips=burst(2, 0, 2.6, 0.3),
          shape=sphere(0.15), vel=R((-0.4, 0.3, -0.4), (0.4, 1.0, 0.4)), inherit=0.25, space="World",
          gravity=-0.02, size=K([(0, 0.4), (0.3, 1.5), (1, 3.2)]), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -0.5), (0, 0, 0.5)),
          color=K([(0, (0.82, 0.83, 0.85, 0)), (0.06, (0.8, 0.81, 0.83, 0.42)), (1, (0.78, 0.79, 0.8, 0))]),
          soft=0.8),
    ]
    effect("TyreSmoke", 2.6, tracks, header="Rubber smoke off a tyre sliding on paving (vehicle_fx.lua).")

    # Touchdown: the tyre spun up from rest by the runway in a blink, a puff
    # of burnt rubber.
    tracks = [
        T("Puff", TX + "smoke/soft.png", forces=[wind(1.4)], clips=burst(6, 0, 1.8, 0.3), shape=sphere(0.25),
          vel=R((-1.2, 0.3, -1.2), (1.2, 1.4, 1.2)), inherit=0.5, space="World",
          size=K([(0, 0.4), (0.25, 1.4), (1, 2.6)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.86, 0.86, 0.88, 0)), (0.04, (0.84, 0.84, 0.86, 0.6)), (1, (0.8, 0.8, 0.82, 0))]),
          soft=0.6),
    ]
    effect("TyreTouch", 1.8, tracks, header="A tyre touching down fast: the puff of rubber as it spins up (vehicle_fx.lua).")


# =====================================================================================
# REENTRY WAKE (prefabs/FxReentryWake, on the craft's tail, local +Y = downstream)
# =====================================================================================
def reentry_wake():
    L = 1.0
    tracks = [
        # The ionised wake: a glowing ribbon along the craft's path.
        T("Wake", TX + "glow/soft.png", blend="Additive", clips=stream(3, 1.4, 0, 3.0, 0.1), shape=point(),
          vel=(0, 0, 0), size=0.01,
          color=K([(0, (2.2, 0.9, 0.55, 0.5)), (0.5, (1.4, 0.45, 0.4, 0.25)), (1, (0.6, 0.2, 0.35, 0))]),
          trail_=trail(1.4, 2.6, TX + "glow/streak.png", True, 1.0, True)),
        # Ablator and paint burning off: sparks left behind in the air.
        T("Sparks", TX + "spark/dot.png", blend="Additive", space="World", clips=stream(60, 1.1, 0, 3.0, 0.5),
          shape=sphere(0.9), vel=R((-3, 4, -3), (3, 18, 3)), drag=1.2, gravity=0.3, size=R(0.07, 0.16),
          color=K([(0, (3.2, 2.0, 1.0, 1)), (0.5, (2.4, 0.9, 0.25, 0.9)), (1, (1.0, 0.25, 0.05, 0))])),
        # A few big burning flakes tumbling away.
        T("Flakes", TX + "spark/streak.png", blend="Additive", orient="Velocity", speed_stretch=0.05,
          space="World", clips=stream(10, 1.6, 0, 3.0, 0.4), shape=sphere(0.8), vel=R((-4, 6, -4), (4, 22, 4)),
          drag=0.8, gravity=0.4, size=R(0.12, 0.3),
          color=K([(0, (2.8, 1.5, 0.6, 1)), (0.6, (1.8, 0.5, 0.12, 0.7)), (1, (0.6, 0.15, 0.04, 0))])),
        # Smoke from the cooked hull, grey-brown, left behind.
        T("Smoke", TX + "smoke/billow_b.png", space="World", clips=stream(10, 3.0, 0, 3.0, 0.3), shape=sphere(1.0),
          vel=R((-1, 1, -1), (1, 4, 1)), forces=[wind(1.2)], size=K([(0, 1.2), (1, 5.0)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.3, 0.27, 0.25, 0)), (0.1, (0.34, 0.31, 0.29, 0.3)), (1, (0.45, 0.44, 0.43, 0))]),
          soft=1.5),
    ]
    effect("ReentryWake", 3.0, tracks, looping=True, header="""
Behind a craft in the plasma: the glowing ionised wake, sparks and burning
flakes shed into the air, a smudge of smoke. prefabs/FxReentryWake, placed on
the craft's lee side by vfx.lua and driven by the heating (setIntensity).""")


# =====================================================================================
# DAMAGE (one-shots)
# =====================================================================================
def damage():
    # A shorting, torn-up part: a crackle of blue-white electrical sparks.
    tracks = [
        T("Arc", TX + "glow/star.png", blend="Additive", clips=burst(1, 0, 0.09, cj=0), size=R(0.5, 0.9),
          rot=R((0, 0, 0), RAD), color=K([(0, (2.2, 2.6, 3.4, 0.9)), (1, (1.2, 1.4, 2.4, 0))])),
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.05, space="World",
          inherit=1.0, clips=burst(14, 0, 0.7, 0.5, cj=0.5), shape=sphere(0.08), vel=R((-3, -1, -3), (3, 5, 3)),
          gravity=1.0, size=0.06, collide=(0.35, 0.4),
          color=K([(0, (3.2, 3.0, 2.6, 1)), (0.3, (3.0, 2.0, 0.8, 1)), (1, (1.2, 0.35, 0.06, 0))])),
    ]
    effect("ShortSpark", 0.7, tracks, header="A heavily damaged part shorting out: an arc flash and a spit of sparks (vehicle_fx.lua).")

    # Metal meeting rock or metal hard: a bright fan of sparks and a flash,
    # sized by setIntensity (the closing speed).
    tracks = [
        T("Sparks", TX + "spark/dot.png", blend="Additive", orient="Velocity", speed_stretch=0.07, space="World",
          inherit=0.8, clips=burst(26, 0, 0.9, 0.5), shape=cone(80, 0.15), vel=R((0, 3, 0), (0, 14, 0)),
          gravity=1.0, size=0.09, collide=(0.3, 0.5),
          color=K([(0, (3.4, 2.9, 2.0, 1)), (0.4, (2.6, 1.2, 0.3, 1)), (1, (1.0, 0.25, 0.04, 0))])),
        T("Flash", TX + "glow/tight.png", blend="Additive", clips=burst(1, 0, 0.12, cj=0), size=2.2,
          color=K([(0, (2.6, 2.1, 1.5, 0.85)), (1, (1, 0.5, 0.2, 0))])),
    ]
    effect("ImpactSparks", 0.9, tracks, header="A hard knock, metal on rock or metal: sparks and a flash (vehicle_fx.lua).")

    # A part torn off: shards of plate and skin, tumbling, bouncing.
    tracks = [
        T("Shards", mesh=PLATE, space="World", inherit=1.0, clips=burst(9, 0, 3.0, 0.3), shape=sphere(0.5, True),
          vel=R((0, 4, 0), (0, 12, 0)), gravity=1.0, size=R(0.08, 0.26),
          rot=R((0, 0, 0), (6.28, 6.28, 6.28)), spin=R((-11, -11, -11), (11, 11, 11)),
          color=C((0.55, 0.55, 0.57, 1)), lit=True, collide=(0.35, 0.5), land_fade=True),
        T("Bits", TX + "debris/chip_b.png", space="World", inherit=1.0, clips=burst(16, 0, 1.6, 0.4),
          shape=sphere(0.4, True), vel=R((0, 3, 0), (0, 10, 0)), gravity=1.0, size=R(0.05, 0.12),
          rot=R((0, 0, 0), RAD), spin=R((0, 0, -14), (0, 0, 14)), color=C((0.45, 0.45, 0.47, 1)),
          collide=(0.3, 0.6), land_fade=True),
    ]
    effect("PartDebris", 3.0, tracks, header="A part breaking off: metal shards and bits that tumble and bounce (vfx.lua explode).")


# =====================================================================================
# ENGINES: ignition and shutdown, and the shimmer over a hot nozzle
# =====================================================================================
def engines():
    tracks = [
        T("Flash", TX + "glow/flash.png", blend="Additive", clips=burst(1, 0, 0.16, cj=0),
          size=K([(0, 1.5), (0.3, 3.2), (1, 2.2)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (3, 2.2, 1.3, 0.9)), (1, (1.6, 0.6, 0.15, 0))])),
        T("Smoke", TX + "smoke/billow_b.png", forces=[wind(1.4)], clips=burst(8, 0, 2.6, 0.3), shape=cone(25, 0.3),
          vel=R((0, 3, 0), (0, 9, 0)), drag=0.5, size=K([(0, 0.6), (0.3, 1.8), (1, 3.2)]), rot=R((0, 0, 0), RAD),
          spin=R((0, 0, -0.6), (0, 0, 0.6)),
          color=K([(0, (0.36, 0.33, 0.3, 0)), (0.06, (0.38, 0.35, 0.32, 0.6)), (1, (0.55, 0.54, 0.53, 0))]),
          soft=0.8),
    ]
    effect("IgnitionPuff", 2.6, tracks, header="An engine lighting: a flash in the bell and a gout of startup smoke out of it (+Y = out of the nozzle).")

    tracks = [
        T("Vapour", TX + "smoke/soft.png", forces=[wind(1.6)], clips=burst(5, 0, 2.0, 0.3), shape=cone(20, 0.25),
          vel=R((0, 1.5, 0), (0, 4, 0)), drag=0.6, size=K([(0, 0.5), (1, 2.2)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (0.85, 0.86, 0.88, 0)), (0.08, (0.85, 0.86, 0.88, 0.32)), (1, (0.85, 0.86, 0.88, 0))]),
          soft=0.6),
    ]
    effect("ShutdownPuff", 2.0, tracks, header="An engine cutting off: the last propellant flashing to vapour out of the bell (+Y = out of the nozzle).")

    tracks = [
        T("Haze", TX + "distort/haze.png", blend="Distortion", distortion=0.03, clips=burst(3, 0, 1.2, 0.3),
          shape=sphere(0.35), vel=R((-0.2, 1.0, -0.2), (0.2, 2.2, 0.2)), forces=[wind(1.0)],
          size=K([(0, 0.7), (1, 1.8)]), rot=R((0, 0, 0), RAD),
          color=K([(0, (1, 1, 1, 0)), (0.2, (1, 1, 1, 0.9)), (1, (1, 1, 1, 0))]), soft=0.3),
    ]
    effect("HeatShimmer", 1.2, tracks, header="Shimmer rising off a hot nozzle after the burn (Distortion; +Y = up).")


def main():
    jet()
    tyres()
    reentry_wake()
    damage()
    engines()


if __name__ == "__main__":
    main()
