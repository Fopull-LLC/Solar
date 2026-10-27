# Vehicle feedback effects

What a craft gives off while it works, so a player can see that it works and
how hard: the October 2026 playtest asked for it ("very little feedback when
the jet is working", no glow on hot engines, nothing on reentry, no sparks or
scuffs on damage, no tyre marks). Art direction: real hardware, NASA-era,
gritty — nothing glows that would not glow, nothing is bigger than it would
be, and every effect is cheap enough for Medium, the level new players get.

Code: `scripts/vehicle_fx.lua` (spawned by `scripts/vfx.lua` as
`prefabs/VehicleFx`), the effects in `tools/gen_vfx_vehicle.py`, the ground
marks in `tools/gen_vfx_marks.py`, the heat glow in `shaders/hullPanels.flsl`.
It READS the craft (the vessel controllers' `AERO`, `R2`, `throttle`,
`damagedParts`, `r2NodeOf`, `partRec`, and what the vessel already tells
`vfx.lua`: `flame`, `heat`, `scrape`) and never writes to it. Probe:
`tools/perf/vfxprobe.sh` (README there).

## What was there, verified in the engine

| asked for | before | now |
|---|---|---|
| jet feedback | **nothing**: the plume code (`set_flames`) only lights parts named `PartEngine*`; a turbojet had no exhaust, no light, no sound of its own beyond the loop | tailpipe glow + light, faint core, heat shimmer, soot at spool-up, contrail in cold air, nozzle heat, light-off puff |
| engines glowing hot | no thermal state anywhere; the part shader had no emissive term | a thermal model per engine, a blackbody glow on the bell, cooling after, a NOZZLE TEMP row on the part menu |
| reentry heat | the plasma cap (`FxReentry`) is there and works, from 45 m/s × air; nothing on the hull and nothing behind | windward faces of the hull glow and stay hot after; a wake (ribbon, sparks, burning flakes, smoke) and the plasma's light on the craft |
| scuffs, sparks on damage | sparks + dust while a hull grinds (`vfx.scrape`), scorch/gouges on the hull (`hullPanels damage`), a smoke trail from parts under 65 % | + a scuff mark where the hull bit (pad and ground), sparks on any hard knock, a torn-up part shorting out, metal shards when a part breaks off |
| tyre marks | none | tread prints on loose ground, black rubber on paving and the pad, dust, rubber smoke, touchdown puffs |

## The effects

Costs are per frame on the probe machine (0.117.0-rc37, Medium unless said);
the measured numbers are in the probe results below.

### 1. Turbojet (`prefabs/FxJet`, on the nozzle, local +Y out of it)

| piece | trigger | look | tiers |
|---|---|---|---|
| Jet Plume (`JetPlume`) + PointLight | spool > 4 % while lit | a warm disc down the tailpipe, a short pale-orange core and hot gas thinning to nothing; light 0.35 → 3.5 by spool^1.5, flickering | all |
| Jet Haze (`JetHaze`) | spool > 6 % | Distortion shimmer streaming 3 m back: the clearest daylight sign it runs, and how hard | Medium+ |
| Jet Smoke (`JetSmoke`, World) | lit: 0.1 × spool + 1.8 × (throttle − spool) | thin brown-grey soot at power, a heavy gout while it spools up; left in the wind | all (half on Low) |
| Jet Contrail (`JetContrail`, emitter-path ribbon) | spool > 0.3, > 25 m/s, air colder than −30 °C | a crisp white ribbon along the path, thinning over 6 s. Air temperature: `climate.sampleAt` (−40 + 90 × temp °C) lapsing 60 °C over the air's height | Medium+ |
| Contrail Puffs (`ContrailPuffs`, World) | with the ribbon | the trail spreading and breaking up in the wind | High+ |
| nozzle heat | spool | inner pipe + turbine face to 0.72 (orange-red) at full spool, the shroud 55 % of that | all |
| light-off | spool leaving 0 with throttle open | `IgnitionPuff` at half size | all |

There is **no afterburner** in the jet model (`aero.lua` jets spool to the
throttle); the plume has no reheat stage to show. If one is added, a second
plume node with shock diamonds belongs in `FxJet` (Flame's `Diamonds` track
is the pattern).

### 2. Engine heat (`hullPanels.flsl` `heat`, `flow`)

A temperature per part, 0 … 1.4 on the shader's scale (0.3 dull cherry,
0.7 orange-red, 1 bright orange, 1.4 yellow-white; the menu shows
290 + 1100·T kelvin):

* rocket engine: heats toward 0.36 + 0.52 × throttle while it burns
  (time constant 5.5 s), so a full burn reaches orange (0.88) in ~15 s;
* turbojet: toward 0.06 + 0.66 × spool²;
* cooling: time constant 26 s in vacuum (radiation only), down to ~5 s in a
  fast airstream: `26 / (1 + 4 · air · (0.4 + min(1, v/60)))`.

The glow is added on top of the lit surface (`litPbr(...) + colour × k`,
k = T²(0.35 + 3.2 T²)), broken up by the hull's own noise, and the metal
darkens under it (oxide). Only the nozzle's materials take an engine's heat
(rocket: Bell, BellIn; jet: BellIn, Dark, and Bell at 55 %). Shimmer
(`HeatShimmer`, Distortion) rises off a nozzle still over 0.3 after the burn,
in air (Medium+). Ignition and cut-off: `IgnitionPuff` (flash, startup
smoke) and `ShutdownPuff` (vapour).

**No consequences.** Nothing in the game damages an engine for heat, and this
adds no such rule: the temperature is shown, not enforced. (A rule would be
a gameplay change: overheat → thrust limit or damage over 1.3 for N s.)

Part menu: engines get NOZZLE TEMP, any other part that is warm gets SKIN
TEMP (a meter, `<K> K  cold / hot / glowing dull red / glowing orange / white
hot`, warning over 1,100 K), registered with `context_registry` (order 26).

### 3. Reentry

* The plasma cap (`FxReentry`) is unchanged: vfx.lua places it on the leading
  face from 45 m/s × air.
* Hull: every part heats toward min(1.35, 0.95 × glow) × k, k = 1 for the
  most windward part falling to 0.18 over 2.6 m back along the flow;
  `flow` = the velocity, so only faces turned into it glow. Rises in 2.2 s,
  cools over ~20 s: the nose glows on after the plasma has gone.
* Wake (`prefabs/FxReentryWake`, `ReentryWake`): an ionised ribbon along the
  path (emitter-path trail, additive), sparks and burning flakes shed into the
  air (World), a smudge of smoke; its PointLight lights the craft pink-orange
  by the glow, flickering. Medium+.
* Heating flux in the controller is ρ^1.5 · v³ (damage over 90 m/s); the glow
  the effects use is the controller's visual `glow` ((v − 45)/130 × ρ).

### 4. Damage

| effect | trigger | look |
|---|---|---|
| scuff (`textures/vfx/decal/scuff.png` decal) | `vfx.scrape` (a hull grinding), at most every 0.18 s | parallel gouges with a bare-metal smear, 0.9 m wide, 1.2–3.5 m long along the slide, on the ground or the pad |
| `ImpactSparks` | `assembly.impacts`: a contact over 4.5 m/s (legs: 9), once per 0.12 s per craft | a fan of sparks riding the craft's motion, a flash; by closing speed |
| `ShortSpark` | a part under 35 % health, a 35 % chance every 0.4 s, ≤ 3 a beat | blue-white arc flash and a spit of sparks; half of them flash a blue light |
| `PartDebris` | `vfx.explode` (a part breaking off) | metal shards (plate mesh) and bits, tumbling, bouncing |
| (existing) | | scrape sparks + dust, smoke trail, hull scorch/gouges/dents (`damage`) |

### 5. Tyres

Every grounded tyre of every craft within 400 m of the camera, every frame:
the contact patch, its speed over the ground, and its SLIP — the patch's own
speed, from the tyre's velocity and its spin (the ball's turn about its axle
between frames; the drawn tyre spins with the hull's speed, so it never
slips). Rolling: slip 0. A slide sideways, a locked or spinning wheel: slip.
Where the spin turns too far in a frame to read (> 1.3 rad), only the
sideways part counts.

| surface | while rolling | sliding (slip > 1.2 m/s) | hard stop (> 0.55 g) | touchdown (> 6 m/s after 0.4 s in the air) |
|---|---|---|---|---|
| loose ground | tread print decal every 1.5 m (Medium+), tinted by the world's dust; `TyreDust` by speed | the print darker; more dust | — | `TyreDust` ×1.6 |
| paving (runway, taxiway, aprons, roads) | nothing | black rubber strip every 0.9 m (alpha 0.25–0.85 by slip), `TyreSmoke` over 0.3 | light rubber | `TyreTouch` (rubber puff) + 0.35 s of rubber |
| the pad, anything over the ground | as paving, the rubber as a decal | | | |

**The paving is drawn, not decal-marked.** The base's asphalt and concrete
are a mesh 0.14 m over the graded ground with no collider, and decals lie on
colliders: a decal there lies under the asphalt, unseen. So rubber on the
paving is a strip of `draw.quad`s 0.155 m over the contact (unlit; black
rubber is black at any light), drawn each frame within 110 m and faded from
70 m. Where a point is paving comes from `base_facilities`' layout (runway,
taxiway, strips). An engine card (decals on drawn meshes) would retire this.

Marks fade with distance (70 → 115 m, before the drawn terrain coarsens
under them) and over the last quarter of their life, in quarter steps
(`decals.set` only when a step changes).

### 6. Other wins in this pass

* Rocket ignition flash and startup smoke, shutdown vapour (above).
* Heat shimmer off hot nozzles after the burn.
* Metal debris on part breaks.

Already there and kept: footstep dust (`StepDust`), touchdown dust
(`TouchDust`), RCS puffs (`RcsPuff` on the RCS block), the launch blast,
exhaust smoke, separation puffs, chute mortar, swimming wake and bubbles.
Not done (no mechanic to show): propellant venting (tanks do not boil off),
afterburner, brake glow (the brakes have no heat).

## Quality tiers

`graphics.lua` level, read every 2 s:

| | Low | Medium | High | Ultra |
|---|---|---|---|---|
| jet shimmer, nozzle shimmer | off | on | on | on |
| jet soot | ×0.5 | ×1 | ×1 | ×1 |
| contrail ribbon / puffs | off / off | on / off | on / on | on / on |
| tread prints on loose ground | off (skids only) | on | on | on |
| ground marks kept (decals) | 120 | 360 | 700 | 1,100 |
| paving strips kept (quads) | 60 | 160 | 260 | 360 |
| mark life | 40 s | 100 s | 200 s | 320 s |
| tyre dust rate | ×0.45 | ×0.8 | ×1 | ×1 |
| reentry wake | off | on | on | on |
| sparks | ×0.5 | ×1 | ×1 | ×1 |

Heat glow is a shader term (one `heat` uniform per part material; a write only
when it moves 0.012) and runs on every tier.

## Budget and evidence

Target: under ~0.4 ms of CPU a frame at Medium for each of: a jet at full
throttle, a rover drifting, a reentry. See "Results" (filled from
`tools/perf/vfxprobe.sh`).
