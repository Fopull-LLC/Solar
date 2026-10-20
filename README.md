# Floptle Solar

The engine's space-demo project (see `docs/engine-roadmap.md`, Workstream D): the
long-term goal is a procedurally generated solar system — fly a ship between seeded
planets, land, explore, dig, build. This is its first slice.

## The game

**`scenes/menu.ron` is the entry scene, and `scenes/system.ron` is the game.**
Pick a save slot in the menu and it rolls that slot's galaxy from its seed —
star, planets, moons, orbits, climates, whatever grows there — and drops you on
the first world with a colony around you.

### The first twenty minutes

The **objectives card** in the top-right corner is the thread. It reads the same
state the game runs on — the ledger, the mission board, what's in your pack — so
it can only ever tell you something that is actually true, and it names the
building you want, how far away it is and which way to turn. The same building
carries a marker in the world (a diamond with its name and distance, pinned to
the screen edge on the side to turn to when it is behind you), and every
building names itself once you are close.

```
new save  →  land at the colony  →  Command Centre: sign a contract
   →  Vehicle Assembly: build a rocket  →  launch, fly it, land
   →  END FLIGHT  →  get paid  →  mine and harvest
   →  Commerce Depot: sell it (one press)
   →  research better parts  →  a bigger contract
```

**How a flight ends.** The moment a craft is down and stopped, the **flight card**
comes up in the bottom-left with the contract's goals ticked and one key —
`ENTER` — and what that key does depends on where you parked:

* **near the base** → **RECOVER CRAFT**: the crane strips the hull and refunds
  most of what it cost, the hold empties into the warehouse, and you're standing
  at the colony. This is the money loop closing.
* **anywhere else** → **END FLIGHT**: the craft stays exactly where it is, still
  loaded and still on the Tracking Station's board, and the crew comes home to
  the tracking dish. It is written to the save (`fleet.craft`) and rebuilt
  where you left it next session; the Tracking Station lists every craft out
  there and **TAKES CONTROL** of the one you pick (free over a powered comms
  dish's link, a billed crew transfer without one).

And from **anywhere** — mid-air, in orbit, leaving the system with dry tanks —
`ESC` ▸ **Abort flight** brings the crew home for a fee (two clicks, pay what
you can, never refused) and leaves the craft flying where it is.

**Rockets fly real rocket physics, scaled to these worlds.** Propellant has mass
(a fuel unit is 10 kg; a full FT-S is 0.8 t of it in a 0.2 t tank), so a stack is
heavy on the pad, lightens as it burns, and its Δv is Tsiolkovsky's —
`Δv = ve · ln(wet / dry)`. A second tank adds less than the first did (it has to
lift the first), which is what staging is for. The tanks drain from the ones that
leave soonest (boosters, then the bottom stage, upward), so a stage drops empty
tanks and nothing else. Legs, chutes, cones and fins weigh tens of kilos.

**World scale.** New saves get the bigger worlds (scale 2): planets 240–380 m in
radius with 3.5–8.5 m/s² of gravity, moons 60–120 m, the first planet's orbit
from ~24 km round a heavier star, so orbital speed is ~35–55 m/s and a stock
ascent to orbit takes 25–50 s instead of 10–15. A save keeps the scale it was
made at (`g_scale`; a save from before scales existed is scale 1 — planets
100–230 m, orbits from 5 km — and regenerates exactly as it was). How big a
planet can be is capped by the engine's terrain fill, which costs the planet's
volume: a scale-2 body's voxel grows with its radius (1.5 m up to ~2.4 m) so no
first load takes more than about twice the old one. Escape speed runs from
~30 m/s to ~85 across both scales. No single set of engine figures fits that whole range,
so **the catalogue is built once per save, for its home world**: thrust scales
with home gravity (every craft has the same TWR on every save), and exhaust
velocity is set once so the stock starter (Pod, Parachute, FT-S, Sputter) flown
straight up at full throttle peaks at 1.8× the First Flight's height. That is
frozen in the save and printed on every catalogue card; the same Sputter is just
as strong on a moon, and nothing is re-rated at the pad. Burns are as long as the
worlds are big: a world's natural time is sqrt(r/g) — about five seconds at scale
1, seven to ten at scale 2 — so a full-throttle starter hop lasts 4–8 s there and
an orbiter burns 10–17 s.
The builder quotes Δv, TWR (wet, in the launch world's g), burn time per stage,
where full throttle straight up peaks, and what the orbit the contracts ask for
costs flown well — with a verdict ("a suborbital hop", "enough for orbit", "too
heavy to lift off") — from the same model the flight flies.
The Sputter's collider is a skirt wider than its bell, so that stack stays
upright after it lands; bigger craft want landing legs.

| part | dry t | fuel | thrust · ve (reference g 7) | cost | for |
|---|---|---|---|---|---|
| Pod Mk1 | 1.30 | | | $400 | the seat |
| Parachute | 0.08 | | | $80 | landing |
| Nose Cone / Aero Fin | 0.08 / 0.04 | | | $50 / $35 | drag, stability |
| Landing Legs | 0.015 each | | | $40 | standing up |
| FT-S Tank | 0.20 | 80 (0.8 t) | | $120 | the starter |
| FT-M Tank | 0.35 | 160 (1.6 t) | | $220 | twice the fuel, lighter tankage |
| Radial Tank | 0.15 | 60 (0.6 t) | | $110 | strap-on |
| Sputter | 0.45 | | 35 kN · 160 m/s | $150 | the starter |
| Anvil | 0.90 | | 85 kN · 173 m/s | $380 | orbit, moons |
| Skipper | 1.60 | | 170 kN · 184 m/s | $520 | first stages, other planets |
| Decoupler / Radial Dec. | 0.06 / 0.05 | | | $60 / $60 | staging |
| Battery · Solar · Dish | 0.10 · 0.05 · 0.06 | | | $130 · $200 · $120 | power, comms |
| RCS Block | 0.04 | (pool) | 3 kN, unscaled | $80 | docking |
| Docking Port · Cargo Bay | 0.10 · 0.40 | | | $180 · $300 | payload |

What that buys, in units of the home world's escape speed (the same on every
save; `SOLAR_BALANCE_TABLE=1 luajit solar/tests/smoke_balance.lua` prints m/s):

| craft | TWR | Δv | burn | does |
|---|---|---|---|---|
| starter (Pod, Chute, FT-S, Sputter) | 1.77 | ≈1.2 esc | 3–5 s (scale 2: 4–8 s) | First Flight with margin; not The High Road, not orbit |
| …with four legs | 1.73 | ≈1.2 | same | still the First Flight, with a third to spare |
| Sputter + FT-M (or two FT-S) | 1.32 | ≈1.9 | 2× | The High Road; orbit flown well; escape |
| Sputter + two FT-M | 0.87 | | | too heavy — LAUNCH warns; the Anvil's job |
| Anvil + FT-M + legs | 2.8 | ≈1.75 | | comfortable orbit |
| Anvil + two FT-M + legs, or staged | 1.9 / 1.55 | 2.7 / 3.2 | | a moon round trip (the planner wants ≈2) |
| Skipper + five FT-M ∣ Anvil + FT-M | 1.55 | ≈4.7 | | a round trip to another planet (≈3.3–4.6) |

`F` still steps out at the hatch, because walking around your landing site is a
different intention from being finished. Before this existed, landing anywhere
that wasn't your own launchpad left you standing in a desert next to a rocket
with no route back into the game.

Money comes from exactly two places, and both are at the base: **contracts**
(the Ops Board — `E` at the Command Centre opens it; click a contract to read
its brief, goals and pay in the detail pane, then **SIGN** it there; **ABANDON**
arms on the first press and acts on the second, because it costs reputation.
The first one pays $2,500 for climbing a good way up and landing in one piece; the altitude is quoted against
the world you are actually on, because the system is generated and its planets
are a couple of hundred metres across) and **the Commerce Depot**, which buys
whatever you fly home. A material's *first* sale is a discovery: a premium (and,
for a rare material, a point of reputation), and usually a part that just became
researchable. A new company opens with $500 — not quite a rocket — so the first
few minutes are mining and harvesting, and the first launch is paid for.

**Contracts.** Eight fixed contracts (the ladder) teach the game, paying more as
they get harder, from *Bring It Home* ($1,800) to *Rendezvous* ($16,000). After
and between them, `missions.lua` **generates** work from the system you actually
rolled — survey, orbit, land on, plant a beacon on, haul a material home from,
recover a probe from, or deliver cargo into orbit of a real body named on the
generator's roster — priced by the trip (Δv, distance, landing gravity). It
opens in tiers by **standing** (`company.lua`: Unknown → Contractor 3 → Trusted
8 → Prime 15 → Legend 25), which also sets how many offers the board holds, what
generated work pays, what the depot pays, and the late research. Over all of it
sits the **Charter**: set foot on every world in the system ($250,000).

| key | |
|---|---|
| `ESC` | **pause** — the world stops, and the CONTROLS page lists every key below |
| `E` | use the building you're standing at (or the mapped `Interact` action): the Ops Board at the Command Centre, the builder at the Vehicle Assembly |
| `O` | hide/show the objectives card |
| `TAB` / `I` | inventory — the suit pack |
| `1` `2` `3` | mining laser · harvest cutter · terrain spade |
| `F` | board / step out of a craft |
| `V` | flying: **the pilot's seat** — first person from inside the pod, looking out of its window (scrolling in past the closest orbit does the same; `V`, a scroll out or `ESC` leaves) |
| `M` | the orbit map — from the pod or on foot |
| `ENTER` | end the flight — leave the craft and come home; near the base, HOLD it for a second to recover the craft |
| `☰` | the same pause menu, for anyone who has not found `ESC` yet |

**Esc backs out one level, everywhere.** A panel closes, then first person (on
foot or in the pilot's seat), then
the pause menu opens. The ladder is written down in one place (`pause_menu.lua`)
rather than implied by five scripts each polling the key and hoping, and
`tests/smoke_pause.lua` drives every rung — a press answered twice is exactly
what makes a game feel like it is getting away from you.

**The controls page is checked against the code.** Every key it advertises is
held against what the scripts actually poll, so it cannot rot into a list that
tells you to press `G` and then ignores you.

**Accessibility.** The engine's ⚙ Settings → ♿ panel drives text scale, colour
filtering, reduced motion and captions. This game honours the two only a game
can: camera shake stands down under reduced motion, and everything a flight
tells you by sound alone — ignition, the clamps, staging, the chutes, touchdown,
the hull letting go — is captioned.

### The ships, and the pilot's seat

Every rocket part is real hardware now: a capsule with an ablative heat shield,
black tile skirt, a bolted window and a hatch; tanks with ring frames, weld lands,
feed lines and stencilled names; engines with gold-foil thrust structures,
gimbal actuators, turbopumps and nozzles in heat-tint bands; gold-blanketed
tanks, solar cells, a dish with a feed horn, landing legs with dampers.
They are built, not imported: `tools/gen_part_meshes.py` lathes and assembles
every part (proper UVs, bevels, bolts) and `tools/gen_part_textures.py` paints a
small shared library in `textures/parts/` — painted skin, brushed metal, tiles,
heat shield, nozzle, insulation, solar cells, a decal atlas and the cabin — with
albedo, normal and packed occlusion/roughness/metal maps on the engine's
Physical shading. Every part draws from the same few maps (≈ 51 MB of GPU
texture in all), so the whole fleet costs about what one set does. Rerun both
scripts after changing them; the mesh script rewrites each part prefab's
`object_materials` and refuses a mesh whose box would move a part off its
collider. Sources and licences: `textures/parts/SOURCES.md`. A damaged part
darkens toward soot (a tint, `set_part_damage` in `vessel_controller.lua`).

**`V` while flying puts you in the commander's couch.** The pod carries a
cabin — quilted walls, a switch console with its displays lit, the crew's legs
and gloves on the controllers, a cabin lamp — that is switched on only while you
sit in it, so it costs nothing otherwise. The window is a real opening in the
hull: you look out of it at the pad, the sky going dark on the way up, and the
ground under the chute. The mouse turns your head (about 110° either way, and
up and down as far as a helmet in a couch allows); launch shake rattles the cabin
by centimetres. The flight HUD stays on top, and every flight key works as
usual. `tests/smoke_cockpit.lua` holds it.

### The map, and planning a burn

`M` opens the orbit map from anywhere: every body's conic, its sphere of
influence, and — while you're flying — your own trajectory walked forward
through every SOI crossing between here and wherever it ends.

Navigation is Blender's, not KSP's. The mouse does nothing until you hold
**right-click**, and then dragging orbits whatever is focused; `CTRL`+right-drag
pans off it, scroll or `↑`/`↓` zooms, `TAB` cycles focus, and `1` `2` `3` toggle
orbit lines, SOI rings and markers.

**You keep flying while it's open** — throttle, stick, SAS and staging all stay
live, because watching the trajectory bend as you burn is the entire reason to
fly on instruments.

The panel top-left is a legend: what the view is centred on, how to move it,
and which of `1` `2` `3` are on (●) or off (○). Opened on foot it frames your
world inside its SOI ring. The map narrows the camera's lens while it is open
(40° rather than the walking camera's 66°), because a wide lens drew the star
as an egg near the edge of the view.

**`N` enters PLAN mode**, and it is a mode for a reason: the flight stick and the
burn tuner both want `W/S/A/D/Q/E`. In plan mode those six move ΔV instead of
the craft, `←`/`→` slide the node along the orbit, left-click puts it somewhere
else, `X` zeroes it and `⌫` drops it. The craft's stick is frozen until you press
`N` again, and the HUD says which mode you're in on its first line.

Once a burn is planned, SAS mode `9` (**NODE**) points the nose down it.

### Testing keys

`scripts/cheats.lua`, on the **Debug** node in `system.ron` and `builder.ron`.
Set its `enabled` param to 0 to ship a build without them. A pink badge in the
corner admits when the account is cheated.

| key | |
|---|---|
| `F6` | re-site the colony where you're standing |
| `F7` | teleport to the base |
| `F8` | +$25,000 |
| `F9` | **infinite funds** on/off — a flag, not a deposit, so it can't run out mid-session |
| `F10` | unlock every part in the catalogue |
| `F11` | complete the contract on the books |

### Seas, where you land, and graphics

**Seas** are the `Sea` prefab (`SeaIce` on frozen worlds): a fine icosphere
(`models/water/ocean_sphere.glb`, from `tools/gen_ocean_sphere.py`) wearing
`shaders/ocean.flsl` — rippled normals, sky reflection and sun glint, depth
colour through `surfaceGap`, and surf that rolls in and runs up the beach where
the water shallows — over a hidden engine **Water Volume** of the same radius.
`scripts/ocean.lua` feeds it the star's direction and the world's air colour,
fires `SeaSpray` along shores near you and places a surf loop at the nearest one
(`audio/water/`, synthesized by `tools/gen_surf_audio.py`). The volume's
density is **1.03, in tonnes per m³**, because every mass in this game is in
tonnes: craft float low, tanks sink, and the crew floats at swimming depth.

**A new save never starts in the water — or in a snowfield.** `game_manager.lua`
scores the spawn world by climate (what grows, how mild it is, how far from the
pole — `climate.lua`'s own model), then takes the best-scoring direction with
dry, not-too-steep ground and room for the whole colony, and the base is sited
there. It used to prefer the north pole, which the climate reads as Snowfield:
nothing to harvest at spawn. A save that already has a colony is never re-sited.

**Graphics** — ESC ▸ Settings: Low / Medium / High / Ultra (`scripts/graphics.lua`,
remembered in the `settings` store slot; with nothing saved, High up to 1080p and
Medium above). The expensive things on a world with air were volumetric fog with
sun shafts (≈ 25 ms of a 1080p frame on an RTX 4060) and the terrain's marched
sun shadow; the levels trade those against render scale. If the game can't hold
the level it's on (a smoothed frame time over 42 ms for 8 s, not counting loading,
time warp or the map) it steps down once, for that session only, and says so.

`scenes/fps_probe.ron` plays a real save in a window and reports the frame rate
and cost buckets (point a scratch copy's `entry_scene` at it and `floptle play`).
`scenes/ui_probe.ron` opens a given panel for `floptle shot`; its `perfEvery` and
`zoomSweep` params report frame costs while it sweeps the orbit map's zoom.
Run either with `ALSA_CONFIG_PATH` pointing at a config whose default PCM is
`type null`, so a test run makes no sound.

## Life, tools and the material economy

Planets grow their own plants and pay for their own rocks. The whole loop:

```
mine / harvest  →  suit pack  →  a craft's Cargo Bay  →  land at base
     →  Commerce Depot unloads + sells  →  money  →  research  →  better parts
```

**On foot**

| key | |
|---|---|
| `1` | **Mining Laser** — hold `LMB` to cut rock |
| `2` | **Harvest Cutter** — hold `LMB` on the plant you're pointing at |
| `3` | **Terrain Spade** — `LMB` lowers ground, `Q` raises it. Shaping only: it yields nothing |
| `TAB` / `I` | **Inventory** — the suit pack (90 kg, and mass is the only limit). Click a row to move that stack into a craft's hold or the warehouse when you're standing by one |
| `W A S D` | walk; hold `SHIFT` to sprint |
| `MIDDLE MOUSE` / `ALT` | shift-lock: the view keeps turning without a button held, and you face where you look |
| `SPACE` / `CTRL` | jump · swim up / dive, in water |
| scroll | zoom. All the way in and one more click is **first person** — the mouse steers on its own, and `ESC` or one click out brings you back |

A small ring on screen is the crosshair: it sits on the cursor while the mouse
is free and in the middle of the view while the mouse turns it — the same
pixel the tool fires through — teal with something in reach, grey without,
amber with a full pack. While a tool is firing, the third-person camera eases
0.6 m over the crew's right shoulder so the body stops hiding the work.

The HUD line always shows all three tools with the one in your hand marked, so
you never have to already know that `2` is a key. Above it, top-left, sit the
three numbers you are playing for — balance, reputation (`REP`), and how full
your pack is. They used to live inside two buildings, so you could mine for five minutes
and watch nothing change.

Only `LMB` fires a tool. `E` used to as well, but `E` is the door, the console
and "close": opening the Commerce Depot fired the mining laser into the plaza.

**The mining laser digs tunnels.** It cuts **where the cursor points** while
the mouse is free, and through the middle of the view while the mouse turns it
(first person, shift lock, a held right button). A ring at the hit shows exactly
how wide the next bite will be, and the astronaut turns to face it. A cursor
outside the view aims down the middle. Range is measured from *you*, not from
the camera, so scrolling the third-person view out changes nothing.

Nothing in reach says so. Every refusal the belt can make now names itself on the
HUD line, including the ones that take the tools away entirely — a panel holding
the keys, or the crew being aboard a craft.

Hold the trigger and the cut **bores forward along that ray** at about 1.8 m/s
until it reaches arm's length, at which point it says so and you walk into the
hole you just made. Four seconds of trigger is roughly eight metres of tunnel,
and the deeper you go the better the rock — resonant crystal only forms twenty
metres down.

That the cut point is *driven* rather than re-read from the raycast every frame
is the whole trick, and it fixes two complaints at once. `terrain.dig` subtracts
an analytic ball (CSG, so a held brush can't wreck the distance field), which
means a second dab at the same point does nothing at all — a laser that aimed
itself at wherever the collider currently said the surface was dug one dish and
stopped. And that collider is remeshed a few frames behind the edit, so the hit
flipped between the old face and the new one and the beam's end snapped about by
a metre every frame. Driving the point ourselves means every bite lands somewhere
new *and* nothing lurches.

The bore is held **body-relative**: the planet is orbiting a star at tens of
units a second, so a cut point remembered as a world position is, one frame later,
a point in the sky behind the planet.

**The cut has to be bigger than a voxel.** Planets generate at
`PlanetFill::voxel` = 1.5 units and `terrain.dig` subtracts a ball of
radius × strength — so the original 1.6 × 0.85 carved a hole 1.36 units across,
*smaller than one voxel*. Surface nets cannot represent that: you get a lumpy
pocket that only roughly agrees with where you pointed. That was the other half
of "the digging alignment is glitchy and offset". It cuts a 2.0-unit ball now,
which the grid can actually round-trip, and the aiming ring draws that ball
rather than the radius param so the sight can't over-promise.

The tool is a real object bone-attached to the astronaut's right hand — the beam
leaves its barrel and it swings with the walk cycle. Holstered when you pick a
different tool.

**The beam's five layers.** A `Beam` track maps **V along the ribbon** and U
across its width, so a beam texture has to be a bright vertical streak — the
first version used a starburst, which smears into a blob with a band across it.
`Core` is a hard line, `Pulse` is a tapered spindle scrolled three times faster
so you see packets fed into the rock, `Arc` is a kinked bolt rippling out of
phase and scrolling backwards, `Bloom` is the haze, `Muzzle` is the aperture.

**The harvest cutter** aims at the *plant*, not at the point on the ground it
grows out of. It measures how close your aim line passes to the plant's own axis
— root to tip — so pointing at a trunk at chest height or a canopy above you
works, which is what you actually do when you walk up to something. A ring round
its base and a stem filling up its trunk show what you're about to cut. The old
cone test measured the direction to the root from your navel and went quiet
exactly when you got close to the thing you wanted.

The readout under it names what you're about to get and how deep it is, *before*
you fire: the ring and the cut ask the same `survey()`, so the crosshair cannot
promise something the beam doesn't deliver. What comes out depends on the world's
archetype, your depth, and the ore vein you're standing in; veins are places, so
a rich pocket is worth walking back to. And when the pack has no room left it
says so in as many words — a full pack is the one condition that makes a working
laser look broken.

Holding the trigger spins up over a third of a second, then cuts continuously;
the bar counts out the next unit. Keep the beam within a couple of metres of
where it already is and **focus** builds, up to +60% cut rate. The optics **heat**
and throttle to about half speed when glowing, cooling whenever you let go — so
short bursts beat one long one. It never locks you out.

**The base buildings are walk-in.** The command centre, the assembly gantry and
the depot carry a *shell* collider generated from the model's own geometry
rather than one box around the whole thing, so their doorways are doorways —
walk in, stand under the roof, and the facility prompt still answers. The power
plant and the tracking dish are machines and stay solid. The shell boxes are in
centred **model** units, so changing a prefab's scale rescales them with the
mesh — regenerate only when the model changes, and check that a 2 m astronaut
still fits through the opening:

```
python3 solar/tools/shell_collider.py models/space-kit/hangar_largeA.glb --scale 6.0 --check
```

They are sized to read as a base rather than a row of sheds: the command centre
is 12 × 18 m on the ground, the assembly frame 10 m tall (a rocket has to stand
inside it), the depot 8 × 8. Prompt reach is per-building, measured from the
origin, so it clears the building's own footprint before it clears any ground.

**The base is a place.** It is sited once — around the crew's landing site, after
the loading screen hands the world over — and then remembered body-relative in
the save (`base.body` + `base.x/y/z`), so reloading rebuilds the same colony on
the same ground however far you have wandered. It used to be re-cut around
wherever the astronaut stood when the terrain first answered, which on a loaded
save is the *loading hover* over the spawn planet's north pole: the buildings
went up there and the player woke up hundreds of metres away with nothing to walk
up to. If a prompt ever goes missing again, the Console says why — `facilities:`
reports how many are standing and how far the nearest one is.

**And the ring is drawn on the sphere.** A facility 36 m from the base on a
214 m planet sits ten degrees round the curve, so it has its own local up. The
ring used to be laid across the tangent *plane* and each site probed for ground
from 12 m up — which leans every building by that ten degrees and, on a world
with 18 m of dune relief, starts the probe inside the hill. A ray that begins
underground reports nothing (the building is never placed) or reports zero (it
is placed at the probe height, buried or hanging). That is why the base behaved
in the little test scene and misbehaved in a generated system.

**At the base** — the **Commerce Depot** (the fifth building) is **one press**:
*Sell everything — $1,240*, with the money on the button (discovery premiums
included), and under it one row per material — click a row to sell just that.
Rows marked **NEW** have never been sold: their first sale pays the premium. It unloads any craft
parked within 140 m and your suit pack into the warehouse, then sells what isn't
spoken for — whatever a delivery contract on the books still needs is kept in
the warehouse rather than sold, and the button says so ("Sell the rest"). It
used to be two presses, unload then sell, and a player with a full pack pressed
once, read "12 units into the warehouse" and walked away with no money. A
material's **first** sale ever is a discovery: a premium, a point of reputation
for a rare one, and usually a part that just became researchable. In the **builder**, a locked catalogue card shows what
it costs and what it wants (and a prerequisite, on the card); clicking it arms
the purchase and a second click on the same card buys it.

The **Vehicle Assembly** has three doors, not two. `SAVE` keeps the blueprint,
`LAUNCH` buys the hull and rolls it onto the pad — and `LEAVE` (or `ESC`) goes
back to the base having bought nothing, keeping the blueprint you were drawing.
Until it existed, walking into the Vehicle Assembly to look at the parts meant
buying a rocket to get back out.

The action button always carries a real label, including "Nothing to sell yet".
It used to be written only when there *was* an action, which left the scene's
authored placeholder — the literal word "Action" — on screen for every other
path, and for any error earlier in the repaint.

**What generates**

- `scripts/climate.lua` — temperature, moisture, elevation and biome anywhere on
  any world, from the record the generator publishes (`save.world.<name>`).
  Also owns the sea: where it is, and whether you're in it.
- `scripts/flora_gen.lua` — a world's species, rolled from its seed: silhouette,
  branch pattern, palette, glow, and what harvesting one gives you. The climate
  picks which forms a world can grow; the seed makes them unlike anywhere else's.
- `scripts/flora_field.lua` — streams them in around you, deterministically, so
  the same ground always grows the same stand. Cut plants regrow.
- `scripts/mineral_field.lua` — the rock lying on the surface, and the ore you
  break off it without digging. Entirely `scatter.*`: a rule per rock type, and
  the engine derives and draws every instance with no scene node in it. Which is
  why it is two hundred lines and reaches the horizon while the flora field
  beside it is nine hundred and manages ninety plants in a fifty-five-metre
  bubble. Flora cannot move over yet — its plants are built from primitives, and
  a scatter prototype has to be a mesh file (`floptle/0065`).

  **Every source is anchored to its planet, and this is not optional.** A scatter
  region is fixed in world space when it is declared, and every world here orbits
  on rails at around 99 units a second — so an unanchored field is entirely
  behind its planet within three seconds, which is exactly what shipped once.
  `parent` (`floptle/0073`, engine v0.32.0) moves placement into the body's frame
  instead, so following an orbit costs one transform per source per frame and no
  rock is reseeded, re-settled or forgotten. A world with no scene node to anchor
  to gets no field at all, and says so — an unanchored field must not be able to
  come back by quietly failing to find its planet.

  Read the header before changing `far` or `chunk`. A scatter field's real cost
  is set by the outermost LOD distance, not by how many props you asked for, and
  this file is the reason the engine has `scatter.cost` (`floptle/0071`) — the
  first version of it reached 700 metres, swept four and a half thousand chunks,
  and made the game unplayable. It now asks the engine what a source will cost
  and shortens its own reach until the answer fits, printing what it settled on.
- `scripts/orbit_map.lua` — the map screen and the maneuver node.
- `scripts/materials.lua` / `inventory.lua` / `research.lua` — the registry, the
  containers, and what's still locked.
- `scripts/flight_ops.lua` — how a flight ends: the card, and the three ways
  out. Two of them end a flight (recover at the base, or leave the craft where
  it sits); the third is **CALL FOR PICKUP**, for a crew on foot with nothing
  left to fly. That one exists because a landing went wrong, the ship broke up,
  and the astronaut who walked away from it had no route back into the game.
  It bills the company and it bills what you can afford — a fee that can refuse
  is a fee that softlocks, which is the thing it was written to prevent.
- `vfx/MiningBeam` / `MiningImpact` / `OreBreak` — the laser's three effects: a
  ribbon Beam track the script aims with `setBeamEnd`, a looping contact patch
  (sparks under `gravity_mode: Field`, so they fall toward the world you're on),
  and the one-shot that fires when a unit actually comes loose.

**Tests** (offline, no engine needed):

```
luajit solar/tests/smoke_flora.lua        # climate, species, plant build, scatter, harvest
luajit solar/tests/smoke_minerals.lua     # the scattered rock fields: aim, break, save, regrow
luajit solar/tests/smoke_toolgate.lua     # can the crew use their tools right now
luajit solar/tests/smoke_walker.lua       # how it feels to walk: the up axis, first person
luajit solar/tests/smoke_cockpit.lua      # the pilot's seat: in and out, the pod's frame, the head clamp
luajit solar/tests/smoke_pause.lua        # the Esc ladder, and that the controls card is true
luajit solar/tests/smoke_api_reserved.lua # no script shadows a handle key
luajit solar/tests/smoke_resources.lua    # registry, containers, tools, depot, research
luajit solar/tests/smoke_inventory.lua    # the suit pack panel, and where cargo can go
luajit solar/tests/smoke_company.lua      # ledger, standing, the ladder, deliveries
luajit solar/tests/smoke_contracts.lua    # generated contracts, tiers, the Charter
luajit solar/tests/smoke_siting.lua       # a new save sites somewhere temperate; old bases stay
luajit solar/tests/smoke_base.lua         # colony siting: one place, on the sphere, remembered
luajit solar/tests/smoke_facilities.lua   # walk-up prompts, both coordinate frames
luajit solar/tests/smoke_objectives.lua   # the opening flow, step by step
luajit solar/tests/smoke_flight.lua       # how a flight ends: recover, or leave it and come home
luajit solar/tests/smoke_vessel.lua       # the whole launch → fly → stage → land → stand down
luajit solar/tests/smoke_builder.lua      # the builder, and that the catalogue covers the registry
luajit solar/tests/smoke_balance.lua      # ten craft on seven worlds: TWR, Tsiolkovsky Δv, apex, orbit, planner budgets, LAUNCH checks, research confirm
luajit solar/tests/smoke_dock.lua         # docking, undocking, peripherals
luajit solar/tests/smoke_scene_params.lua # the scenes' authored params vs the scripts
```

**`smoke_scene_params.lua` is worth knowing about.** A params list in a `.ron`
scene silently overrides the script's `defaults`, and an unknown param name is
not an error anywhere — it is just a value nobody reads. `system.ron` pinned the
mining laser to its original tuning (plus a `laser_range` the script had stopped
having two versions earlier), so two rounds of tuning never reached the game. The
lint checks that every authored param exists, that it is inside its own
`--@range`, that every texture a `.vfx.ron` names is on disk, and that the
laser's **effective** numbers still make consecutive bites overlap into a bore.

## How the code is arranged

Two conventions run through every script here, and both are worth knowing before
you change one.

**A screen whose shape depends on data is described, not authored.** The
objectives card, the suit pack, the ops board and the builder's catalogue are
`ui.make` trees built from Lua; the scene holds one empty node saying where each
one sits. They used to be fixed rows — eight inventory rows, six contract rows,
nineteen catalogue buttons — each with its own script, each hiding itself when
there was nothing to show. That is a list pretending to be a layout, and it
capped what the game could say: a ninth material was invisible, a sixth contract
was invisible, and the catalogue's part order lived in three places that had to
agree. `ui.make` reconciles rather than rebuilds, so a row that stays is the same
element frame to frame and keeps its hover and its keyboard focus.

Hand-designed screens — the flight HUD, the navball cluster, the menu — stay
authored in the scene, which is what the scene is for.

Their look comes from `ui/solar.tokens.ron` and `ui/solar.uistyle.ron`: five
spacing steps, four type steps, four radii, and colour that means something —
teal for the base and the company, blue for instruments, and warm colours
reserved for state. One caveat worth repeating from the engine docs: **a style
wins wherever it speaks.** A style that named `text_color` would silently
overwrite a row that tints itself by material tier, every frame, forever — so
`panel/row` deliberately does not name one.

**Cross-script lookups are resolved once and kept.**

```lua
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end
```

`findScript` walks every node in the scene comparing script names. `find(name)`
is O(1) against an index; these are not (`floptle/0063`). Weighted by the
instance counts the scenes actually carry, this project was issuing **126 full
scene scans per frame** before the pass that introduced the idiom above, and
issues **5** after. The five that remain are `findScripts("vessel_controller")`
asking "is any craft being flown?" — craft are spawned from blueprints at
runtime, so there is no handle to hold and nothing to wire in the Inspector.

While you're here: `planet_walker.onFoot` is the single place that decides
whether the crew is out and about. Four panels used to re-derive it, each with
its own fleet scan under a fallback chain that could never run. Ask the walker.

## Regenerating the planet

```
cargo run --release -p floptle-field --example gen_planetoid -- solar/terrain [seed]
```

Different seed = different planet (relief, colour patches, caves). Knobs via env:
`RELIEF=6 CAVES=0 ...`. A headless render of the current field:

```
cargo run --release -p floptle-render --example solar_probe
```

writes `solar_orbit.png` / `solar_surface.png`.

## Where this is going (roadmap D1–D6)

Planets on Kepler rails + inverse-square gravity + patched conics for the ship,
nested reference frames, on-rails time-warp, an orbital trajectory map rendered to a
UI viewport, per-planet atmospheres via the Sky stage, water volumes. Each stage
lands as an engine feature first — this project is the proving ground.
