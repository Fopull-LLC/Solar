# Progression: feats, and the ruin near home

The progression rework (work/progression/PLAN.md) as built. Slices P1 (feats),
R1 (the ruin near home), W1 (the wood tier: docs/base-building.md §35) and P2
(the nine milestones, §3) are in; the load model (W2) comes later.

Ty, 11-11: *"make solar panels unlock when you set up your first base, and in
general rework the whole progression to involve all the new mechanics"*;
*"at least one abandoned base should spawn near the home base."*

## 1. Feats (`scripts/feats.lua`)

A feat is a thing the player has **done in the world**, never a thing bought.
The system that already knows marks it, one guarded line where the thing
happens:

| Feat | Marked in | When |
|---|---|---|
| `kit_placed` (n) | field_builder `place` | a Build Kit piece paid and put down |
| `wood_built` (n) | field_builder `place` | the piece is a `*.wood` one (W1, base-building §35) |
| `base_founded` | base_tower `reconcile` | a tower founds a base: a Base Station Tower or a Camp Mast placed (W1), or a claimed ruin's (key: the base id) |
| `ruin_found` | ruins `discover` | any way a ruin is found (key: the site) |
| `ruin_claimed` | ruins `claim` | |
| `core_read` | ruins `readCores` | |
| `ruin_stripped` (n) | loot `strip` | a ruin's piece (key: site and piece) |
| `lock_opened` | loot `enterCode`, `forceLock` | by its code or forced: both count (key: the piece) |
| `ore_studied` | research `study` | an ore kind's first study (key: the material) |
| `cave_kinds` (n) | cave_hazards `first_entry` | a cave kind's first entry (key: the kind) |
| `run_cycle` (n) | route_ops | a run's cycle done |

P2 added the detections the arc needs (§3.3). Still unmarked: `storm_held`.

- **Save:** `feats = { [id] = { n, t (first, agency clock), b, k = { [key] = 1 } } }`.
- **API:** `mark(id, { key, b, n, quiet })`, `markAtLeast(id, n)`, `has(id, n)`,
  `count`, `when`, `LABEL[id]` (the lock line's words), `seed(list)`
  (a scenario's `start.feats`), `migrate()`.
- **The migration** runs once a save (`feats.mig`). An old save's bases,
  claimed ruin, read core and found ruin count, so nothing already built is
  locked again.
- **Research** (`research.lua`) reads the save's `feats` directly. The builder
  has no feats script to ask, and both scenes must agree.
  - `featGrant = "<feat>"`: unlocked the moment the feat is in the save.
  - `feat = "<feat>"`: a lock that names a thing to do (`"needs a refinery run"`).
    Once it is done, the price applies as usual.
- **Programme goals** (`missions.lua`): `{ kind = "feat", id, n }`. The card
  shows `(2 of 3)` for a counted feat.
- **Scenario goals** (`scenario.lua`): `{ kind = "feat", id, n }`, read
  through `W.featCount`.
- **The radio line:** the first mark of a feat that opens research gets one
  line from Ops on the strip, saying what the Depot ships now. A feat that
  opens nothing says nothing (few popups).

**The first grants:** `solarArray` and `batteryBank` are TECH ids now:
`grantOnly`, `featGrant = "base_founded"`. Founding a base with a Base
Station Tower, or claiming a ruin, opens both. A sandbox has them from the
start.

## 2. The ruin near home (`scripts/ruins.lua`, THE RUIN NEAR HOME)

Ty walked 500 m and met nothing. Sites were spread uniformly over the whole
sphere, at least 450 m from the spaceport with no maximum, and a site that
found no flat ground was dropped silently.

- **The site:** one extra home-world site, `<home>#near`. `sitesFor` is
  untouched, so every other site keeps its seed, id and kind.
  - Kind: a survey camp (3 in 5) or a relay post.
  - Empty 400–900 days.
  - Its name never repeats another site's.
  - Not in a scenario: the author's world is the author's.
- **Siting** (`nearPlan`, `nearStep`, `nearClear`): once the crew is within
  600 m of the pad, the site goes 330–400 m from the spaceport's middle. That
  keeps the 300 m tower spacing (claiming it founds a legal base) and keeps it
  inside STAMP_R, so it stands from the first minute. The search tries, in order:
  1. The flattest of 16 bearings at 365 m.
  2. The first flat spot of 36 bearings × 3 radii.
  3. The flattest spot under 3 m over 11 m.
  4. Rings out to 800 m.
  5. The flattest dry, clear spot of all.

  The site is **never dropped**: only an annulus with no dry ground at all
  waits for the next session. It stays clear of the player's structures
  (150 m), bases and the Tracking Station (320 m) and other ruins. Its door
  faces the pad. The search looks at 24 spots a tick.
- **Existing saves** get the site on load. The exception is a save with a
  site already within 450 m of the spaceport: that site is pointed at
  instead (`alias`).
- **The yard** (`nearExtras`):
  - two Solar Arrays, one standing and one knocked over (a Repair Kit
    stands it up once the site is claimed);
  - a flat Battery Bank;
  - a Personnel Locker always on a code, and never a locked door;
  - the outside crate (`loot.planSite`) holding the shift note with the
    code, the survey note, a crated Solar Panel (`part:vab.solar`) and a
    Repair Kit;
  - the terminal's Data Core.
- **The log** (`nearLore`) has three entries: the survey team, why they left,
  and where the others went. The last one names the next site. Its survey
  note finds that site, and so does reading the core.
- **Found** by walking up to it, within 120 m. From the pad it is already
  inside the usual 420 m.
- **The pointer:** once First Steps is done and the site is still unfound, Ops
  says one line on the radio, once (`ruins.s[id].ptr`). For example: "Survey
  flight logged a structure about 350 m north-east of the pad…". No marker
  is drawn in the world.
- **Claiming** works as for any ruin. Its tower founds a base, which marks
  `base_founded` and opens the Solar Array and the Battery Bank.

Tests: `tests/smoke_feats.lua`, `tests/smoke_ruins.lua` (the R1 blocks), and
`tests/smoke_contracts.lua` (the programme's `feat` kind). The engine probe is
`tools/perf/ruinprobe.sh <engine> near`.

## 3. The arc (`scripts/missions.lua` PROGRAMME, P2)

Ty, 11-11: *"rework the whole progression to involve all the new
mechanics"*. The career used to be a comms ladder; it is now nine milestones
of things done in the world, then the comms ladder as it was.

### 3.1 The milestones

| # | Milestone | Requires | Goals | Grants |
|---|---|---|---|---|
| 1 | First Steps | — | a plant cut, an ore mined | the Build Kit (`buildkit`: `progGrant`) |
| 2 | Homestead | First Steps | 8 timber pieces (`wood_built`; waived while the kit has no timber), the ruin near home found, a base of your own | `base_founded` → Solar Array, Battery Bank |
| 3 | Lights On | Homestead | `grid_served`, `cable_laid` (40 m), `night_held` | Base Station Tower, heavy power |
| 4 | Shelter | Homestead | `room_sealed`, `room_breathable`, `slept_in` | life support, fluids |
| 5 | Salvage | Homestead | 3 pieces stripped, a lock opened, a core read, a ruin claimed | the core: Probe Core |
| 6 | Ironworks | Lights On | an ore studied, the Refinery researched, 200 kg refined, a part fabricated | (the Quarry becomes a price) |
| 7 | Underground | Shelter | 2 cave kinds, a cave cache, a dose read or a uranium sample (`any`) | shoring |
| 8 | Fission | Ironworks and Underground | `rtg_night`, the Ember researched, `reactor_critical`, `scram_seen` | — (the reactor is the prize) |
| 9 | Wheels and Wings | Lights On | 2 km driven, the Cargo Bay researched, a bulk haul, the First Flight contract, a run | 2 km → Battery Pack |
| — | Rare Finds | First Steps | as before (a side milestone) | |
| — | Relay Network | **Lights On** | 10 % → Probe Core; 25 % | Relay Dish |
| — | Eyes in the Sky, Beyond, Reach | as before | as before | as before |

- **Goal kinds** added: `tech` (research done), `contract` (a ladder contract
  flown), `any` (one of a list), and `waive = "wood"` on a feat goal.
- **`requires`** takes one id or a list. `prog.open[id]` opens a milestone
  whatever it requires (the migration's, below).
- A goal's `ops` line goes to the Ops strip. A milestone never raises a big
  caption: its money shows on the objectives card's banner.
- **The card** (`objectives.lua`): every feat goal has a task and one hint
  (`FEAT_STEP`); "Find the abandoned camp" carries a survey bearing to the
  near site; a research goal says what still stands in its way. Counted goals
  read `(1.2 of 2 km)`, `(120 of 200 kg)`. The foot names two other open
  milestones and counts the rest ("and 3 more (/ switches)").

### 3.2 The gates (`research.lua`, `parts_kit.TECH_OF`)

Every gate is a catalogue card's lock line, never a refusal in the world.

| TECH | Opens on | Pieces |
|---|---|---|
| `tower` | `grid_served` | the Base Station Tower; **open while the kit has no Camp Mast** (`openWithout`), or a claimed ruin would be the only way to found a base |
| `power2` | `night_held` | Power Cable 35 / 95 mm², HV Cable (ALIAS), Transformer, Power Pole, Breaker Panel 160 A |
| `life` | `room_sealed` | Scrubber, O2 Generator, Air Tank Rack, N2 Compressor, O2 Concentrator, Airlock Receiver, Equalise Valve, Airlock Wall, Pressure Bulkhead, Pressure Hatch |
| `fluids` | `room_breathable` | the FLUID section (the Charging Pump stays `ember`) |
| `logic` | `fluid_moved` | the LOGIC section bar the Signal Cable, Push Button, Lever Switch and Indicator Lamp |
| `quarry` | bought ($2,500 + 20 RP) after `machine_worked` | Quarry Post, Quarry Drive |
| `shoring` | `cave_kinds` | the wood tier's shoring frame |
| `buildkit` | First Steps done (or the old Relay Network 10 %) | the Build Kit |
| `packB` | Wheels and Wings' 2 km goal (or finished) | the Battery Pack |

Existing research took a feat lock: `refinery` an ore studied, `fabrication`
a refinery run, `ember` an Isotope Skid's night, `cargo` 1 km driven
(`featN`). A sandbox has everything; a **scenario** has the gates marked
`scnOpen` (its world is the author's); the P1 grants stay the scenario's
`start.research` to give.

### 3.3 The detections (`feats.lua`, one line in each system)

| Feat | Hook | Rule |
|---|---|---|
| `grid_served` | base_grid `advance_all` → `gridTick` | a grid with an owned structure, a source and a load, every load served for 60 s of agency time |
| `night_held`, `rtg_night`, `slept_in` | the same | the grid's light profile (`M.prof`; a stand-in cell at its first part when it has no arrays) marks dark slots; from dusk to dawn with nothing shed (`s.short`) the night is held; with an Isotope Skid in the grid also `rtg_night`; the active crew member in a sealed room the whole night, `slept_in`. A night crossed in one advance at warp counts. State in `feats.gn`. |
| `room_sealed` | room_air `solve` → `roomsSolved` | a sealed room of 8 m³ or more in an owned structure |
| `room_breathable` | room_air `advance_struct` → `airStep` | a sealed network (no opening, 8 m³ or more) with breathable air counts its time while a scrubber in it runs (`n.S > 0`: on and powered), 3,600 s in all; a brownout pauses the count, bad air or an opening resets it. On an alien-air home the room closes round the outside's air: it needs air from tank racks (an O2 Generator alone makes 2.8e-5 atm·m³/s, a day and more for a hut) |
| `fluid_moved` | fluid_net `step_struct` → `fluidStep` | 100 kg moved in a network with a pump running |
| `logic_fired` | logic_net `apply` | a command on to a device, lamp or alarm |
| `machine_worked` (kg) | refinery `after` | kg/s worked × dt (`addAmount`) |
| `part_fabricated` | refinery `after` | a Fabricator's crate |
| `reactor_critical`, `scram_seen` | reactor_plant `publish` → `reactorTick` | k ≥ 0.9995 with power; a trip after that |
| `dose_taken` | cave_hazards (the dose step) | 60 s of dose read (`accrue`) |
| `cave_cache` | loot `prepare` → `cacheOpened` | a container in a ruin's cave (`cv`, `ri` ≥ 1000) |
| `cable_laid` | base_cable `lay` | a run of 40 m or more |
| `drive_km` (m) | missions `wheel_odo` | 4 Hz: the piloted craft on its wheels, the engine's planet-relative speed × game seconds |
| `bulk_hauled` | missions `payout` | a generated bulk haul paid |

"Owned" is anything but an unclaimed ruin's structure (`feats.owned`).

### 3.4 Old saves (`feats.migrate`, version 2)

- A save that had the Build Kit the old way (the Relay Network's 10 %, or
  `res.done.buildkit`) could place every kit piece: the arc's gates are
  written as researched, so nothing it could build is taken away.
- A save past First Steps keeps the Relay Network open (`prog.open`).
- The feats its records prove are marked: a power source with a base
  (`grid_served`; with a bank or an Isotope Skid, `night_held`; a skid,
  `rtg_night`), a refinery machine (`machine_worked` 200), a Fabricator, an
  ore studied (`res.studied`), the metres a contract odometer kept. Sealed
  rooms mark themselves when room_air solves them on load.
- The milestones then tick on their own and pay what they pay.

Tests: `tests/smoke_contracts.lua` walks the arc feat by feat, the waived
wood goal, the tower's `openWithout`, and three old saves; `tests/smoke_feats.lua`
covers the detectors against stand-ins, the migration and the gates;
`tests/smoke_programme.lua` keeps the comms ladder's checks. The engine
probe is `tools/perf/arcprobe.sh <engine> arc` (a fresh career through
Shelter) and `arcold` (an old save copied in).
