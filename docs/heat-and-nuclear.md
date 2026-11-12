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
| `scripts/reactor.lua` | S6 (§8): the rulebook of a reactor built from components: the layout, the neutronics, the kinetics, poisons, burnup, decay heat, the plant's heat, the stiff solver, the readouts. Pure. On the Build Kit node. |
| `scripts/reactor_plant.lua` | S6: the plants in the scene: found in the records, stepped at 5 Hz on the agency clock, on the base grid, a dose source, the console, the menus, the NUCLEAR overlay, the save. |
| `tools/gen_kit_nuclear.py` | S6: the 20 component pieces' meshes and prefabs (called by `tools/gen_kit_parts.py`). |
| `tests/smoke_reactor.lua`, `tests/smoke_reactor_scene.lua` | S6's rulebook (59 checks) and its scene half on stubs (18). |
| `tools/perf/kitprobe.sh <engine> reactor` | S6's engine probe (`tools/perf/reactorprobe_modes.lua`). |

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

- Ground reactors are now built from components (§8, sandbox S6). The
  Furnace and Station Core parts and the NTR's thrust coupling are still
  open; the rulebook carries them.
- The Intake's radiological wing has no model of its own yet: no placard and
  no hazard stripes on the shed. The press is its right-click.
- Rods dropped loose in the world: the body prefab exists; dropping and
  gravity-gun handling come with the item-drop work.
- A Tracking Station heat line per craft (B2 mentions it) is not built. The
  fleet record already carries `st.T`.

## 8. Reactors built from components (sandbox S6)

The plan is `work/sandbox/PLAN.md` §3.1, §3.6 and §8.3 (S6). Ty asked on
11-06 for full depth from the start: enrichment, burnup and xenon, not an
expert toggle. There is no one-click reactor. A plant is a layout of kit
pieces, and that layout sets its criticality, its heat, its efficiency, its
dose and the ways it can fail. The Ember (§2) is unchanged: it still flies on
step 3's one-loop model, and old craft and saves are as they were.

### 8.1 The pieces (`parts_kit` NUCLEAR, `tools/gen_kit_nuclear.py`)

All pieces are 1:1 with real masses, and research comes after the Ember (`tech`).

| Piece | Size | Mass | Price | What it is |
|---|---|---|---|---|
| Reactor Vessel Base 5 × 5 | 2.5 × 1.0 × 3.0 m | 9.5 t | $48,000 | the lower head and grid plate of a pressure-tube core: a 5 × 5 lattice of 0.5 m cells on its top; coolant in at −Z, out at +Z |
| Fuel Channel | 0.5 × 2.4 m column | 0.18 t | $6,500 | a zircaloy pressure tube for eight fuel rods |
| Graphite Moderator Column | 0.5 × 2.4 m | 1.02 t | $3,200 | graphite bricks |
| Light Water Moderator Column | 0.5 × 2.4 m | 0.67 t | $1,400 | a steel tank of water |
| Heavy Water Moderator Column | 0.5 × 2.4 m | 0.73 t | $38,000 | a tank of D₂O |
| Control Rod Column | 0.5 × 3.0 m | 0.42 t | $9,000 | a B₄C rod in its guide tube, its drive on top |
| Coolant Pipe 2 m / 1 m, Elbow, Tee | DN100 | 30–60 kg | $150–260 | bare pipe loses 0.25 % of the plant's rating a metre |
| Insulated Pipe 2 m | DN100, lagged | 80 kg | $520 | loses 0.004 % a metre; a fitting between two lagged runs is lagged too |
| Coolant Pump | 1 × 1.5 × 2 m | 0.65 t | $14,000 | 4 kg/s, 1.5 kW from the grid, pushes in → out |
| Pressuriser | 1 × 3.6 m | 1.9 t | $22,000 | holds 15.5 MPa (the primary boils at 618 K, not 373 K); 0.8 kW of heaters |
| Steam Generator | 1.5 × 3.8 × 2 m | 4.2 t | $38,000 | a U-tube heat exchanger, 30 kW/K: primary on −Z, secondary on +Z |
| Turbine-Generator 100 kW | 3.5 × 1.7 × 1.75 m | 3.6 t | $65,000 | makes 65 % of the Carnot limit; on the base grid |
| Radiator Panel 2 × 4 m | 3 × 4.4 m | 0.32 t | $6,800 | a condensing radiator, 16 m²; rows chain end to end |
| Cooling Tower Cell | 3 × 5.2 × 3.5 m | 6.5 t | $30,000 | 14 kW/K to the air, a 2 kW fan, nothing in vacuum |
| Reactor Control Console | 1.6 × 1.45 × 0.9 m | 0.25 t | $12,000 | the plant's screen and its controls |
| Heavy Shield Block 1 × 1 (SHIELD) | 1 m cube | 3.6 t | $2,200 | magnetite concrete, k 0.02 |
| Water Shield Tank (SHIELD) | 1 × 2 × 0.5 m | 1.08 t | $700 | k 0.25 |

- **Ports.** Every nozzle is at `PIPE_Y` (0.6 m over the piece's ground
  point), on the 0.5 m grid and flanged. A piece's ports with the same
  `loop` tag are joined inside it. A steam generator's primary side and
  secondary side are not joined, so they belong to two different loops.
- **Port snap** (`kit_snap.portSnap`). A piece with ports, aimed at a piece
  with ports, goes nozzle to nozzle: onto the nearest free port, facing it.
  **R** steps which of the held piece's ports goes on, which picks which end
  of a pipe and which way an elbow turns. Otherwise pipes place like blocks,
  on the grid.
- **Fuel rods.** The existing Fuel Rod is LEU at 3 %. Two new rods exist:
  Fuel Rod (natural U), at $900, and Fuel Rod (HALEU 19.75 %), at $7,500.
  The Depot sells both after the Ember's research. A channel holds eight
  rods, and each rod tracks its own U-235, Pu-239, fission products and
  fluence.
- **Rated power.** A full channel is rated at 40 kW(th), so a full eight-
  channel core is 320 kW and makes about 85 kW(e). That scale suits a base.

### 8.2 The layout (`reactor.layout`, `coreOf`)

- **The lattice.** Columns stand on the vessel's top, one to a cell, and
  can stack a storey up (a taller core). What stands beside what is the
  neutronics:
  - Each moderator column shares its atoms among the fuel channels beside
    it.
  - Light water counts only a 3 cm slowing-down skin of each face it
    shares, because its neutrons slow within 5 cm. Each channel's own
    coolant moderates a little too.
  - A moderator column that touches no fuel but borders the core is a
    reflector: it pushes the core's edge out.
  - A rod is worth its fuel faces. A rod that touches no fuel is worth
    nothing, and the console says so.
- **The loops** come from the port graph (a union of coincident, opposed
  nozzles):
  - The PRIMARY holds the vessel's ports, and is walked from the vessel's
    outlet back to its inlet. Its pumps (and which way each pushes), its
    steam generators, its pressuriser on a tee, and its pipe metres are
    read off that walk.
  - Each steam generator's secondary side starts a SECONDARY: its feed
    pump, the turbine and its heat sinks.
  - An open nozzle names itself: "the primary loop is open at the Reactor
    Vessel Base's in nozzle".
  - Two pumps pushing against each other fight: the flow falls to 60 %.
    Two pumps in line give 125 % of one, and either can fail without a
    low-flow trip.
- **S7 can absorb this.** The ports are the fluid network's nodes, and the
  loops are its first two systems.

### 8.3 The neutronics (one homogenised core, real cross sections)

    k∞ = ε · p · νΣf / Σa         p = exp(−N₂₃₈ · I(T_f) / ξΣs),  I = 32 b · (1 + 0.011 (√T_f − √300))
    k  = k∞ / (1 + B²M²)          M² = τ + L²(1 − f) of the mix; B² from the core region's plan and storeys
    ρ  = 1 − 1/k

- **Fuel data** (barns): U-235 σa 681, σf 585, ν 2.43; U-238 σa 2.68
  (with effective capture to Pu 10); Pu-239 σa 1011, σf 742, ν 2.87.
- **Moderators**, per atom or molecule:

  | Moderator | ξσs (b) | σa (b) | τ (m²) | L² (m²) |
  |---|---|---|---|---|
  | graphite | 0.743 | 0.0045 | 0.0368 | 0.25 |
  | light water | 41 | 0.664 | 0.0027 | 0.0008 |
  | heavy water | 5.5 | 0.003 | 0.0131 | 0.3 |

- **The moderator's feedback.** Water loses density as it heats. A
  channel's coolant runs at the primary's temperature. A moderator tank
  runs 30 % of the way from the room to the coolant, as a calandria's does.
- **What the smoke measures:**
  - Enrichment raises k: natural 0.81, LEU 3 % 1.29, HALEU 1.61.
  - More moderator beside the fuel raises it too: none 0.40, some 0.86, a
    ring 1.29.
  - Natural uranium never goes critical in light water.
  - Graphite needs LEU in a core this size (natural U: 0.73).
  - Heavy water takes natural uranium critical as a two-storey core: 1.009
    at one storey, 1.048 at two.
  - The feedback is negative: cold 1.293, hot fuel 1.239 (Doppler), with
    the coolant hot as well 1.215.
- **The refuelling rule** (`loadWhyNot`). A rod is refused if, with every
  rod in, cold and clean, the core would be over k 0.99 ("no shutdown
  margin: add a control rod first"). Without that rule, the rod that tips it
  over would make the core prompt critical in the Engineer's hands.

### 8.4 Kinetics, poisons, burnup, decay heat

- **Point kinetics** uses two delayed groups (the six collapsed: 1/λ_eff =
  13 s) and the prompt jump:
  `P = β (g₁y₁ + g₂y₂ + σ)/(β − ρ)`, `dyᵢ/dt = λᵢ (P − yᵢ)`.
  - β is weighted by fission, so a core rich in plutonium is touchier.
  - σ is the start-up source.
- **ρ ≥ 0.985 β is PROMPT CRITICAL**, an event. A Nordheim–Fuchs burst
  heats the fuel until its Doppler swings ρ back past β (ΔT = 2(ρ − 0.85β)/α_D,
  ending at 3,500 K). A share of the burst reaches the coolant, and the
  decay heat gets its share.
- **Poisons:**
  - I-135 → Xe-135: 6.57 h and 9.14 h, σ 2.65 Mb, yields 0.0639 and 0.00237.
  - Pm-149 → Sm-149: 53 h, σ 41 kb, yield 0.0113.
  - Both are driven by the flux φ = 7·10¹³ · P at the rating (a high-flux
    core's), scaled by the fuel's fission cross-section.
- **Burnup.** Each rod's U-235, Pu-239 and fission products are closed
  forms of its fluence, folded in between solver steps. A centre channel
  sees more flux than an edge channel (a cosine shape).
- **Decay heat** uses seven exponentials fitted to Way–Wigner (within 2 %
  from 1 s to 10 days): 8 % just after a SCRAM, 1.4 % at 17 min, 0.5 % at
  4 h (after ten days at power).
- **Game scale, in the open:**
  - Sizes and masses are 1:1, but the power is a few hundred kW, so the
    turbine makes tens of kW for a base.
  - The flux is a power reactor's, so xenon, samarium and burnup run on
    their real clocks (hours, days, months).
  - The plant's thermal inertia and its standing losses are a share of its
    rating, as a full-size plant's are of its own. The primary holds 1 J/K
    per W of rating (a PWR's is ~0.8) and boils dry on 100 s of rated power
    (TMI's ~107). The vessels' lagging loses 0.03 %.
  - With these numbers, a station blackout runs its real course of hours,
    instead of a few hundred kW of plant being passively cooled by its own
    bare pipes. A plant of bare pipes still is passively cooled, which is a
    real trade-off (§8.6).

### 8.5 The heat (thermal.lua's HEATNET link laws, real kelvin)

    fuel ─UA(ṁ)─▶ primary ─ε·ṁc─▶ steam generator ┄ secondary ─G─▶ turbine ─▶ condenser ─εσT⁴ | G_tower─▶ the world
                    └ pipes UL·(T − T_amb), pump work in, boil-off past T_sat

- **The fuel film.** `UA = P_r/350 K · (0.12 + 0.88 · flow^0.8)`. It falls
  to 0.2 % when the core is uncovered.
- **The steam generator.** `ε = 1 − exp(−UA/ṁc)`; the secondary boils.
- **Natural circulation** gives 4 % of design flow at 40 K.
- **The pumps** coast down over 5 s. Their work heats the water, which
  holds a tripped plant at hot standby.
- **The turbine's valve** holds the steam at 540 K, or 45 K under the
  primary's boiling point if that is lower. A tripped plant therefore sits
  hot on its decay heat, which is where the xenon pit bites. **Cool down**
  opens the steam dump. Shut, the valve passes 0.05 %.
- **Losing feedwater.** A steam generator whose feed pump has stopped boils
  dry and carries nothing on. That is the loss of heat sink, TMI's path.
- **Electricity** is `η (1 − T_k/T_s) Q` (η 0.65, with an L3 Engineer's
  +0.03). It needs 10 % of the turbine's steam to spin, and is capped at
  its 100 kW.
- **Heat sinks:**
  - A radiator sheds `ε σ A (T⁴ − T_sky⁴)`, 35 % less in sun, plus
    convection in air.
  - A tower sheds 14 kW/K to the air (nothing in vacuum).
  - So a hotter condenser sheds more, and the turbine makes less.
- **The link laws** live in `thermal.lua` (`linkConduct`, `linkExchange`,
  `linkRadiate`, `carnot`), bound once per model.
- **What the smoke measures:**
  - At full power: primary 556 K, steam 536 K, fuel 898 K. 84 kW(e) from
    319 kW(th), which is 26 %.
  - At 30 %: radiators run the condenser at 428 K (11 %), a tower at 292 K
    (23 %).
  - Without a pressuriser the plant reaches only 9 %.
  - Insulated pipes lose 0.5 kW against 21 kW bare.

### 8.6 The protection and the failures

- **Trips** (latched, with the rods dropped in 2 s):
  - high power, 118 %
  - short period, 10 s
  - fuel over 1,250 K
  - coolant within 12 K of boiling, at power
  - flow under 70 % of design, at power

  **Protection off** (a bypass) removes them all.
- **Measured:**
  - **Loss of flow:** the pump stops, and the plant trips on low flow at
    +1.989 s, the same instant at 30 s, 1 s and 0.1 s steps. The fuel peaks
    under its limit.
  - **A rod pull by hand:** the short-period trip catches it. With the
    protection bypassed, the power runs away to 15× and the core melts 19 s
    into the pull.
  - **A control rod column lifted out of a running core** (30 % power,
    rods 42 % in): PROMPT CRITICAL, a 13.5 MJ burst, the fuel to 2,733 K.
  - **A blackout on a lagged plant after a SCRAM** (every pump and the fan
    off, so the steam generator boils dry): hot standby rises on the decay
    heat, the primary boils off through its relief, the core uncovers, and
    it melts 16.5 h after the SCRAM. A plant of bare pipes rides out the same blackout, because its
    pipes shed the decay heat.
- **Damage.** Cladding fails past 1,300 K (`dmg` builds as the square of
  the excess). At 1 the core is MELTED: it is held at ρ −0.3 and still
  makes decay heat.
- **A release.** Damage vented through the relief valve is a release
  source on top of the core's dose (`REL_K`, with I-131's 8-day half-life),
  shielded by record like everything else.

### 8.7 The solver: warp-proof, E's rule

The kinetics with feedback are stiff and nonlinear. `advance(S, M, dt, now)`
works as follows:

- It takes L-stable Rosenbrock steps (Shampine's ode23s: one finite-
  difference Jacobian and one LU of the 23 states a step, with an embedded
  error estimate at rtol 2·10⁻⁵).
- The step size is controlled, with steps of at most an hour (the burn is
  folded in between).
- Trips and events are found inside a step at their own instant, by secant
  on each event function. The melt is latched by its event, never switched
  inside a stage.
- Each call takes at most MAXSTEPS steps (300 a tick in the scene). The
  rest carries to the next tick, which also catches a plant up on load
  (capped at 30 days).

**What the smoke measures:**
- 60 days at full power as one call (three calls once MAXSTEPS bites),
  60 one-day steps and 1,440 one-hour steps agree to 6.9·10⁻⁶ on U-235,
  burnup, Xe, Sm, the temperature and the rods.
- Two months take U-235 from 3 % to 2.29 % (0.66 % FIMA), the samarium to
  0.18 b, and cold k down 2.4 %.

### 8.8 The xenon pit

- **The lean core** has half its rods natural uranium. It runs at full
  power with its rods 21 % in, and its equilibrium xenon is worth 3.4 %.
- **After a SCRAM:** four hours on, the xenon is 2.57 b (it was 0.67), and
  with every rod out k is 0.9999. The forecast is a restart in 17 h, with
  the xenon peaking at 3.33 b at +6 h.
- **A restart attempt:** the controller pulls every rod and stays at P
  6·10⁻⁹. The console reads "LIMITED BY xenon: the rods are all out at 0 %
  (Xe −14.2 %)".
- **40 h later** the xenon has decayed, and the plant goes back up to 50 %.
- **A fresh full-LEU core** has the excess to restart through it, as a real
  BOC core does.

### 8.9 The scene (`reactor_plant.lua`)

- **Plants.** A plant is any structure with a vessel. It is re-found when
  the records change (debounced 0.5 s, never in a frame).
- **Stepping.** Each plant is stepped at 5 Hz on the agency clock and at
  once on a change.
- **The grid** (base_grid, kinds `plant` and `aux`):
  - The turbine is a source.
  - The pumps, the heaters and the tower's fan are loads.
  - A pump on a grid that is short and flat stops (`partServed`), which is
    the station-blackout chain. A black start needs batteries or arrays to
    run the pumps until the turbine is up.
  - The grid is rebuilt when what the plant publishes moves by 3 % or
    0.5 kW (at most every 3 s).
- **Dose.** The vessel is a dynamic `base_shield` source at its core's
  centre (`rad.dynamic`, `up`). Its strength is 0.083 lethal shares an hour
  at 5 m per kW of rating, times the heat it makes over its rating, plus
  any release. Walls count by record (the step-3 rule).
- **Engineers only refuel.** Rods are loaded from the base stores (6 s a
  rod × `refuel_time`), and unloading is the same.
- **Engineer perks** (`crew.PERKS`):
  - `refuel_time` ×1 / 0.7 / 0.5
  - `xe_forecast` from level 2: the console's "RESTART in ~N h"
  - `plant_trim` +3 % of Carnot at level 3, for the plant the Engineer
    founded
- **Readouts:**
  - **The console** is a 1024 × 576 CRT screen, repainted at 1 Hz with crew
    within 25 m. Since S7 it is made to be read at 1.5 m, in a screenshot
    too: four PAGES of at most five short lines in 52 px phosphor mono
    (56 mm of text on the 0.62 m screen, ≥ 13 px in a 720p picture from
    1.5 m), a 44 px header naming the page and its number, bright green,
    amber and red on near-black. The page turns every 6 s, or from the menu
    ("Console: next page"):
    - CORE: k and ρ (pcm), critical or not and the period, power, heat,
      rods and the shutdown margin
    - POISONS: xenon (UP/DN), samarium, burnup, the restart forecast
    - LOOPS: fuel, primary (and its flow), its boiling point (BROKEN), the
      coolant INVENTORY (with a break's loss or the makeup), steam and
      condenser
    - POWER: the turbine, net power and efficiency, the dose at 5 m,
      LIMITED BY (wrapped to two lines)
    - always: the annunciator (two rows of two tiles, 28 px) and the 24 h
      trend of power and xenon
  - **Menus** on every piece:
    - the controls: start up (AUTO 50 %), setpoint ±10 %, rods by hand,
      SCRAM / reset, protection, cool down, turbine online
    - each pump's switch
    - each channel's rods and their loading
  - **The NUCLEAR overlay** (F3 with the kit open):
    - the loops drawn by temperature on the CRT palette, with flow
      chevrons
    - each component's heat
    - the plant's card with LIMITED BY
    - the dose field at chest height: 36 rays, the walls by record, the
      contours where it falls to 1, 0.1 and 0.01 of a lethal dose an hour
- **Save.** The plant is stored in `rx.list`, `rx.<sid>:<uid>` and
  `rx.ch.<sid>`. An old save has none of them, so no plant exists and
  nothing is stepped.
- **Cost.**
  - In luajit (JIT): 0.054 ms a 5 Hz tick at power, 0.053 ms shut down.
  - In the engine, which runs its Lua without the JIT: about 0.43 ms a
    tick. A quiet plant (tripped or subcritical, untouched for 5 s)
    therefore ticks at 1 Hz, and the console repaints every 2 s with crew
    near.
  - Probe measurement: a tripped plant costs 0.05 ms a frame
    (`reactor_plant`), plus 0.014 ms for `base_shield`.
- **Catch-up.** A load's catch-up (or the probe's ten days) is taken 300
  solver steps a tick: 240 h in 1.3 s, one engine tick at a time.

### 8.10 The coolant as a fluid (sandbox S7)

`docs/base-building.md` §17. The primary's inventory is real kg from its
parts (1,661 kg in the fixture plant). A pipe broken open (its menu's "Cut
it open", or `reactor_plant.breakPipe`) loses the pressuriser. The primary
boils at 373 K, trips on subcooling at once, and blows down at two-phase
critical flow to the break's level. The core stands above the pipes, so it
uncovers. Once broken, what boils off is real water.

The fixture's 320 kW core, 12 h at power, peaks uncovered at 1,210 K on its
decay heat, just under damage. The pressuriser's DN25 makeup nozzle takes
water from the fluid network. A process pump stalls against 15.5 MPa, and a
Charging Pump gets in. After a break the process pump injects ~2 kg/s,
enough for a 5 % break but not a guillotine. The FLUIDS overlay shows the
primary's inventory and rings the break.

### 8.11 Open

- **Still to take over:** the secondary boiling dry is S6's own model (a
  steam generator whose feed pump has stopped). The moderator tanks' fill
  and the secondary's makeup are not fluid systems yet.
- **Vessels side by side** could make one big lattice (a natural-uranium
  graphite pile needs it). Each vessel is its own core today.
- **Pipe risers** between storeys (all ports are at one level today).
- **The press** makes only the 3 % rod. The other two come from the Depot.
- **S8 logic:** scram and pump sensors. The seams are `scram`,
  `setPump` and `page`.

## 9. Under warp, and at the console (playtest 11-11)

Ty: "you can't speed up the automatic transferring with the rods when you
change the setpoint... you just have to wait", and "can't time warp when
accessing computers".

- **The plant follows game time.** reactor_plant steps every plant on the
  agency clock, which includes warp. `smoke_reactor_warp` checks a setpoint
  change at ×1, ×10, ×100 and ×1000: after 600 game seconds the power and the
  rods agree to the solver's tolerance, and the per-tick step budget is never
  short. At ×10000 the budget runs out, and what is left over is carried to the
  next tick, so no game time is lost.
- **Why it felt real-time.** A console's terminal holds the keyboard, so the
  warp keys did nothing while it was open. warp_chip now reads `.` and `,` raw
  while a terminal is open: the warp works with the screen up, and the screen
  stays live. Its key line shows the rate.
- **What the plant sounds like** (`plant_av.lua`, docs/base-building.md §38):
  - the core's hum rises with its power;
  - the pumps' whine follows their flow, and they coast down when switched off;
  - the turbine's whine follows its load;
  - steam leaks as the primary nears boiling, and the relief valve lifts when it
    boils;
  - the pumps rattle when they cavitate;
  - the floor shakes near a stressed vessel;
  - two gauges sit on the vessel's face;
  - the annunciator's red lines sound the klaxon at the vessel, and the amber
    ones the bell.
