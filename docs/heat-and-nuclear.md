# Heat, reactors, rods and radiation

Deep-space addendum build step 3 (`B1 B2 B3 B5 B6 A4 A6`), built 2026-11-05.
The plan is `/mnt/disks/3tb/.floptle-shared/solar/work/deep-space/`
(`proposal.md` §2–3, `proposal-addendum-engineer.md` §6.3).

| File | What it is |
|---|---|
| `scripts/thermal.lua` | The rulebook: the heat model, cores, rods, radiators, the isotope cell, the radiation cone, dose, fuel fabrication. Pure, loads in luajit. On the Electronics node. |
| `scripts/vessel_thermal.lua` | The flight side: a craft's heat loop, its reactors and radiators, the dose pass, the reactor's right-click rows. A library on the Electronics node, called from `vessel_controller.power_tick`. |
| `scripts/parts_nuclear.lua` | The NUCLEAR catalogue section (a `parts_registry.extend` provider like `parts_aero`). |
| `tools/gen_nuclear_parts.py` | Meshes and prefabs for the six parts and the two rod items. |
| `tests/smoke_thermal.lua` | The rulebook's test (85 checks). |
| `tools/perf/nukeprobe.sh` | The engine probe (VAB and flight, screenshots, cost). |

## 1. The heat model (B2)

Each craft has one heat loop with temperature `T` (0 cold, 1 = 100 %):

    C·dT/dt = Q − S·T        T_eq = Q / S,   k = S / C

- `Q`: heat in. A reactor gives `heat × output` while critical, and 5 % of
  its heat while shut down with fuel in it. An isotope cell gives a little.
  A running engine gives 0.4 × throttle, but brings its own nozzle sink of
  1.0, so engines on their own settle at 40 % at most. Old craft never warm
  up: they have no heat part, so they never run the loop.
- `S`: what is shed at `T = 1`. The hull sheds 0.5, a core's shell its own
  `sink`, the cell's fins 0.6. A radiator sheds
  `sink × fold × health × pump × (1 − 0.35·sun)`. Folded it sheds 15 %. With
  no power for its pump it sheds 25 %. Below 25 % health it sheds nothing.
- `C`: thermal mass (the cores, the coolant, the hull).

**The closed form.** `advance(state, model, dt, now)` takes any `dt` in one
exact step: `T ← T_eq + (T − T_eq)·e^(−k·dt)`. It never uses forward Euler,
which overshoots at 1000× warp. What changes `Q` inside a step is an event:
the loop reaching 90 %, a rack running dry, an NTR's governor band. The
crossing time is solved from the closed form, the step goes to it, the event
is applied, and the step carries on. One step of an hour therefore lands where
36,000 steps of 0.1 s do. The smoke test checks scram time, T, rod life and
time over 100 % to 1e-6. The same function catches a craft up on the save
clock when it loads (`st.ht`, capped at 30 game days). Dose healing uses the
same `approach`.

**Thresholds.**
- **90 %**: every critical reactor SCRAMs. The rods go in, output drops to 0,
  and the scram is stamped in game time. It latches: nothing restarts it on
  its own, so it can't flap.
- **Restart (A6)**: allowed only 60 game seconds after the scram and with the
  loop under 50 %. Every start costs 90 full-power seconds of rod life.
- **100 % sustained**: the reactor and radiators wear at 0.004 hp per game
  second, through the vessel's own `wearPart` → `set_part_damage`.
- **NTR cores** (`ntr = true`, data only until step 11): a governor throttles
  them from 75 % to nothing at 90 %. Thrust fades, but it never scrams on heat.

**Figures** (hu = heat units, at T = 1):

| Core | EC/s | heat | shell sink | cap (hu·s) | rack | rod life | rad |
|---|---|---|---|---|---|---|---|
| Ember (flies now) | 6 | 6 | 1.0 | 800 | 1 | 60 min | 0.5 |
| Furnace (data, step 11) | 25 | 25 | 1.5 | 3000 | 4 | 60 min | 2.0 |
| Station Core (data) | 100 | 100 | 4.0 | 9000 | 12 | 90 min | 6.0 |
| Pile NTR (data, A1) | 0.3 | 30 | 2.0 | 1200 | 1 | 60 min | 3.0 |

An Ember with no radiators scrams at full output. One Radiator Panel isn't
quite enough on its own (92 %), and two settle at about 45 % in shade and about
55 % in sun. A Furnace with one Truss Radiator settles at 68 % at 60 % output.
At 100 % it scrams once in an hour of 1000× warp, as E asked.

## 2. Parts (B1, B3, A4; the Ember from B4)

The NUCLEAR section (`parts_nuclear.lua`). Each part's thermal behaviour
lives in its electronics modules, so the blueprint carries it with no new
record keys.

| Part | Mass | What it does |
|---|---|---|
| Isotope Cell (`rtg`) | 45 kg | `rtg` gen 0.5 EC/s. Output halves every 400 game hours (`rtgOutput`, from `st.born`). Heat 0.25, fins 0.6. |
| Radiator Fin (`radFin`) | 50 kg | `radiator` sink 1. Passive. |
| Radiator Panel (`radPanel`) | 0.3 t | sink 5. Its pump draws 0.05 EC/s at priority 8. It folds with the solar panel's deploy module (`anim = "solar"`, SolarWingPivot), on Deploy (U). |
| Truss Radiator (`radTruss`) | 1.0 t | sink 20. Pump 0.2 EC/s. Six panels on a folding arm. |
| Shadow Shield (`shadowShield`) | 0.8 t | `shield` k 0.02. |
| Ember Reactor (`ember`) | 1.8 t | `reactor` core "ember", plus a 20 EC start-up battery. |

Research (G1): the Isotope Cell needs $2,000 and uranium ore held. The
radiators come after the cell. The Ember needs $9,000, uranium, the Radiator
Panel and standing +6. The shield comes after the Ember. Until G2's
"Critical" milestone exists, the Ember's research also opens fuel
fabrication.

**Reactor controls** (electronics `reactor` module):
- `critical` toggle: "Start reactor" / "Shut down".
- `output` axis: 10–100 %, presets.
- Abort shuts every reactor down.
- An unedited craft gets the custom keys "Reactor", "Output +" and "Output −"
  (`ACTUATOR_KEYS`).

## 3. Fuel rods (B5) and fabrication (B6)

`items.lua` defines the rod items:
- **`fuelRod`**: 40 kg, 14 L, carried over the shoulder.
- **`spentRod`**: hot. Carried in a pack, it doses its carrier at 10 % of a
  lethal dose an hour per rod.

Each has a hold prefab (`ItemFuelRod`) and a loose physics body
(`FuelRodBody`: a 40 kg Dynamic box). The body is ready for the gravity gun;
nothing spawns it yet.

A reactor's rack is `st.rods` (count) plus `st.life` (full-power seconds left
across the rack). A rod is spent once the life left no longer fills it.

- **At rollout**: the VAB fills each rack from the base's stores
  (`builder.rodsAtLaunch`). In a sandbox the rods are free. The hint bar says
  when stores run short.
- **On EVA**: the Ember's right-click (`vessel_thermal` "part" provider) shows
  CORE and RODS. It also offers:
  - **Load fuel rod**, holding one: an 8 s job, 4 s for an Engineer.
  - **Take out the spent rod**, with the core shut down and room in the pack.
- **Fabrication**, at the Materials Intake's right-click: FUEL FABRICATION ·
  RADIOLOGICAL.
  - A rod takes 20 units of uranium ore from the warehouse, $400 and 10 game
    minutes.
  - Two rods at most in the press.
  - An Engineer on foot has to start it (J6's gate) and is credited
    `crafted` when it's done.
  - The queue (`fab.rods`) runs on the game clock, so warp and quitting don't
    lose it.
  - Spent rods go back here, for 4 units of ore each.

## 4. Radiation (A4) and dose

Every core has `rad`: the share of a lethal dose per hour that a crew member
takes 5 m away, in its cone, at full output. The cone opens along the core's
+Y (up its stack), with a 30° half-angle. The dose scales with the inverse
square of the distance, never closer than 1 m. A shut-down core with fuel in
it gives its decay share (5 %).

The dose pass runs twice a second per craft (staggered by node id), only
while a core gives any. The order of work:
1. **The dot product**: is the crew member in the cone? This covers every
   seated member and every member on foot within 140 m.
2. **Shielding by part record**, only for those inside: the product of `k`
   for every blocker box the core→crew segment crosses (`shieldFactor`). A
   `shield` module counts 0.02; a propellant tank at ≥ 95 % counts 0.3. This
   never counts "the ray hit a solid", so it keeps working once modules are
   hollow (engine interiors stage 1).
3. **Placed walls** (step 8, M6c), only for crew on foot: every BASE part
   with a `shield` (the Shield Wall, k 0.05) that the core→member segment
   crosses, by its record (`base_shield.wallFactor`, the same
   `shieldFactor`). See docs/base-building.md §12.
4. **The terrain**, only for crew on foot: a `terrain.raycast` from the core
   to them.

Since step 8 a BASE part can be a source of its own (`rad` in parts_base):
the Isotope Skid's cells give a weak field all round (0.002 at 5 m), traced
by `base_shield.pass` against members on foot with the same walls and
terrain ray. With the Build Kit open, every ground source and live craft core
nearby is drawn the VAB's way, with each member on foot marked red (in the
open) or amber (shielded) from the numbers the dose pass wrote.

All positions are drawn poses, read in lateUpdate.

`crew.addDose` adds to `rec.dose`:
- **Death**: at 1.0 the member dies of "radiation sickness". With CREW SAFETY
  on rescue they are rescued at 70 % instead. Invincible caps the dose at 99 %.
- **Healing**: at the base the dose heals by half every two game days (the
  closed form, game time).
- **Old records** have no dose; it reads as 0. Nothing is migrated.

The VAB draws the cone from the same `doseRate` (`builder.draw_thermal`):
eight red lines and three rings per core. Each seat in a cone gets a sphere:
red when an unshielded dose would kill in two hours, amber when it is behind
shielding. The inspector's HEAT block shows:
- where the loop settles at full output, every radiator out, in full sun;
- in and out;
- whether a seat is in the cone;
- the rods at rollout against the rods in stores.

## 5. The HUD

- **The HEAT row**, in the fuel and charge instrument: the loop's %, a red
  tick at the scram line, and SCRAM while it is scrammed. Its tooltip shows:
  - where the loop settles;
  - heat in and out;
  - the reactor's state and its rods;
  - the cool-down left;
  - the last event.

  The row appears only on a craft with a heat source.
- **A DOSE chip** (`crew_alerts_hud`), only once a member's dose is above 0:
  ▲ while it is rising, red past 50 %.
- **Big captions**: SCRAM, REACTOR (rods spent), OVERHEAT, FUEL ROD READY.

## 6. Cost

- **A craft without these parts**: nothing new. `elec.thermal` is nil, the
  power tick skips the call, and nothing else changes.
- **A craft with them**: `vessel_thermal.tick`, inside the 10 Hz electrical
  tick, does three things:
  - builds the model from its few thermal parts;
  - takes one `advance` (usually one iteration);
  - every 0.5 s, works out the sunlight and the dose pass.

  Measured (nukeprobe, Ember + 2 panels + cell + fin, 11 parts): 0.054 ms
  per 10 Hz call, 0.009 ms a frame. The part plan is cached per part-list
  generation, crew seats and crew on foot are re-read every 4 s, and dose is
  written to the records every 2 s. Without those, it was 0.40 ms a call.

## 7. What is open

- Reactors as BASE-placeable ground parts, the Furnace and Station Core parts,
  and the NTR's thrust coupling arrive with step 11. The rulebook already
  carries them.
- The Intake's radiological wing has no model of its own yet: no placard and
  no hazard stripes on the shed. The press is its right-click.
- Rods dropped loose in the world: the body prefab exists; dropping and
  gravity-gun handling come with the item-drop work.
- A Tracking Station heat line per craft (B2 mentions it) is not built. The
  fleet record already carries `st.T`.
