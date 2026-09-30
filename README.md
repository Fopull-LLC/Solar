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
building you want and how far away it is.

```
new save  →  land at the colony  →  Command Centre: sign a contract
   →  Vehicle Assembly: build a rocket  →  launch, fly it, land
   →  END FLIGHT  →  get paid  →  mine and harvest
   →  Commerce Depot: unload, then sell
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
  the tracking dish. Fly back out to it whenever you like.

`F` still steps out at the hatch, because walking around your landing site is a
different intention from being finished. Before this existed, landing anywhere
that wasn't your own launchpad left you standing in a desert next to a rocket
with no route back into the game.

Money comes from exactly two places, and both are at the base: **contracts**
(the Ops Board inside the Command Centre — the first one pays $4,500 for
climbing a good way up and landing in one piece; the altitude is quoted against
the world you are actually on, because the system is generated and its planets
are a couple of hundred metres across) and **the Commerce Depot**, which buys
whatever you fly home. A material's *first* sale is a discovery: a premium, a
point of standing, and usually a part that just became researchable.

| key | |
|---|---|
| `ESC` | **pause** — the world stops, and the CONTROLS page lists every key below |
| `E` | enter the building you're standing at (or the mapped `Interact` action) |
| `O` | hide/show the objectives card |
| `TAB` / `I` | inventory — the suit pack |
| `1` `2` `3` | mining laser · harvest cutter · terrain spade |
| `F` | board / step out of a craft |
| `M` | the orbit map — from the pod or on foot |
| `ENTER` | end the flight — leave the craft and come home; near the base, HOLD it for a second to recover the craft |
| `☰` | the same pause menu, for anyone who has not found `ESC` yet |

**Esc backs out one level, everywhere.** A panel closes, then first person, then
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

**A new save never starts in the water.** `game_manager.lua` searches the spawn
world for dry, not-too-steep ground with room for the whole colony, nearest the
north pole first, and the base is sited there.

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

The HUD line always shows all three tools with the one in your hand marked, so
you never have to already know that `2` is a key. Above it, top-left, sit the
three numbers you are playing for — balance, standing, and how full your pack
is. They used to live inside two buildings, so you could mine for five minutes
and watch nothing change.

Only `LMB` fires a tool. `E` used to as well, but `E` is the door, the console
and "close": opening the Commerce Depot fired the mining laser into the plaza.

**The mining laser digs tunnels.** It cuts **through the middle of the view**,
with a ring at the hit showing exactly how wide the next bite will be — so where
you are looking is where it goes, whether or not the mouse is grabbed. (It used
to follow the free cursor, which meant it fired through whatever corner the last
menu had left the pointer in: no ring, no beam, no message, and a belt that
looked broken.) Range is measured from *you*, not from the camera, so scrolling
the third-person view out changes nothing.

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

**At the base** — the **Commerce Depot** (the fifth building) is **two presses,
and it says which one you're on**: first *Unload into the warehouse* (any craft
parked within 140 m, plus your suit pack), then *Sell everything — $1,240*, with
the money on the button. Selling from the warehouse rather than straight out of
your pack is deliberate — a delivery contract counts what's in the warehouse, so
you can put a haul through the depot without cashing it in. A material's **first**
sale ever is a discovery: a premium, a point of standing, and usually a part that
just became researchable. In the **builder**, a locked catalogue card shows what
it costs and what it wants; clicking it buys the research on the spot.

The **Vehicle Assembly** has three doors, not two. `SAVE` keeps the blueprint,
`LAUNCH` buys the hull and rolls it onto the pad — and `LEAVE` (or `ESC`) goes
back to the base having bought nothing, keeping the blueprint you were drawing.
Until it existed, walking into the hangar to look at the parts meant buying a
rocket to get back out.

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
luajit solar/tests/smoke_pause.lua        # the Esc ladder, and that the controls card is true
luajit solar/tests/smoke_api_reserved.lua # no script shadows a handle key
luajit solar/tests/smoke_resources.lua    # registry, containers, tools, depot, research
luajit solar/tests/smoke_inventory.lua    # the suit pack panel, and where cargo can go
luajit solar/tests/smoke_company.lua      # ledger, contracts, deliveries
luajit solar/tests/smoke_base.lua         # colony siting: one place, on the sphere, remembered
luajit solar/tests/smoke_facilities.lua   # walk-up prompts, both coordinate frames
luajit solar/tests/smoke_objectives.lua   # the opening flow, step by step
luajit solar/tests/smoke_flight.lua       # how a flight ends: recover, or leave it and come home
luajit solar/tests/smoke_vessel.lua       # the whole launch → fly → stage → land → stand down
luajit solar/tests/smoke_builder.lua      # the builder, and that the catalogue covers the registry
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
