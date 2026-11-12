# Sound design: what each event plays

Ty's playtest note, 2026-11-12: the game lacks sound design. Impacts and damage sound odd because one
sound effect is reused where it doesn't fit, and when something goes wrong the game plays something
like a can being dropped. He wants real recordings. This page lists every place the game makes a
sound, says what it plays, and flags the ones that don't fit. The fixes are in scripts/sfx.lua's
impact system (below); `docs/sound-shopping-list.md` lists the recordings still missing.

## The system (scripts/sfx.lua)

- **`impact{ a, b, speed, mass, node | x,y,z }`** picks a bank by **what met what**, then by energy
  (½mv²). The materials are metal, rock, soil (sand and snow count as soil), glass, plastic, wood,
  suit and tyre. `"terrain"` reads the ground at the point (`terrain.slotAt` → `materials.ofSlot`).
  Energy picks the light, medium or heavy bank: under 3 kJ, under 120 kJ, or above (glass: 50 J and
  2 kJ). More energy is louder and carries further, more mass sounds lower, and past 1 MJ a debris
  crash is layered on top.

  | pair | light | medium | heavy |
  |---|---|---|---|
  | metal + rock | metal_light | metal_rock | metal_heavy |
  | metal + soil | metal_light | metal_dull | metal_dull |
  | metal + metal | metal_light | metal_metal | metal_heavy |
  | rock + rock / soil | rock_light | rock_soil | rock_heavy |
  | soil | soil_light | soil_heavy | soil_heavy |
  | suit + ground | soil_light | suit_fall | suit_fall |
  | suit + metal | metal_light | suit_fall | suit_fall |
  | glass | glass_knock | glass_break | glass_break |
  | tyre, plastic, wood | tyre | plastic | wood_light / wood_heavy |

- **`fail(kind, { node | x,y,z })`** gives each failure its own sound. The kinds are part_break
  (metal bending and tearing, with a stone hit), explode (a real blast with a close bang), crash
  (debris over a heavy metal crash), scrape (metal dragged over concrete), short (an electric arc),
  battery_fire (a car fire flaring, with an arc), hull_breach (a plate bursting over a blast of air,
  then a hiss), suit_damage (a windscreen crack and a hiss), breaker_trip (a heavy clack and an arc's
  snap) and scram (the big contactor).
- **`step(surface, node)`** plays a footstep on grit, soil, sand, snow, metal, wood, grass or concrete.
  `surfaceAt(x,y,z)` turns the palette's material into a surface: rock and regolith are grit, soil and
  clay are soil, sand, ash and salt are sand, and ice is snow. planet_walker casts one ray down at each
  step. Where the terrain's own ray agrees, the step uses the ground; anything else is built, so timber
  plays wood and everything else a metal deck.
- **Variation.** Banks hold 3 to 6 takes and the same take never plays twice in a row. Volume varies
  ±10 % and pitch ±4–10 % per bank. A bank fires at most once per 50 ms, so a tick full of contacts
  plays one sound.
- **Proof by log.** `history` keeps the last 48 picks (event, bank, clip) and `played[bank]` counts
  them. With `sfxLog = true`, each pick is written to the Console as `SFX <event> <bank> <clip>`.
  `tests/smoke_impact_sfx.lua` covers the logic, and `tools/perf/sfxprobe.sh` checks the real events
  in the engine.

## Audit (2026-11-12): every call site

✗ marks a misfit. **Fixed** means this pass changed it. **Open** means it is still to do, usually
waiting on a recording from the shopping list.

### Damage, failures and impacts

| event (file) | played before | fit | now |
|---|---|---|---|
| a craft part hits something hard (vehicle_fx `knock`) | `foley/steel_drop`, a steel bar dropped on a path, whatever was hit | ✗ the "can drop" | **fixed**: `impact`, metal against the ground's material, another craft or a person, by mass and speed |
| a fast tyre lands (vehicle_fx `tyre`) | Kenney `impactSoft_heavy` | ✗ a generic thud | **fixed**: real tyre thumps (`tyre`) |
| a torn part shorts out (vehicle_fx `zap`) | `foley/radio_crackle` (radio interference) | ✗ | **fixed**: `fail("short")`, a real electric arc |
| a part breaks, not explosive (vessel_controller break_part) | `foley/pyro_bang`, a bird scarer's gunshot | ✗ a gunshot | **fixed**: `fail("part_break")`, metal bending and crunching from a real wreck |
| an explosive part goes off (same) | `foley/explosion_far`, the same gun far away | ✗ | **fixed**: `fail("explode")`, a real dynamite blast with the close bang |
| the whole airframe fails (vessel_controller) | the gun twice | ✗ | **fixed**: `fail("crash")` and `fail("explode")` |
| a part grinding on the ground (vessel_controller) | `foley/pyro_bang` at 1.2× | ✗ a gunshot per scrape | **fixed**: `fail("scrape")`, metal dragged over concrete |
| touchdown (vessel_controller) | `foley/rover_bump`, an industrial switch pitched down | ✗ the same on any ground and any mass | **fixed**: `impact`, metal on the ground under the craft, by its mass |
| a steel Build Kit piece breaks (kit_load) | Kenney wood crack at 0.55× | ✗ steel snapping like wood | **fixed**: `fail("part_break")` |
| a steel piece straining (kit_load) | Kenney wood ticks | ✗ | **fixed**: light metal pings (`metal_light` at 1.5×) |
| a timber piece creaks, strains or breaks (kit_load) | cave creaks, Kenney wood | ✓ | kept |
| a lock forced open (loot) | `foley/steel_drop` | ✗ the can again | **fixed**: `part_break` |
| a container stripped for parts (loot) | `foley/steel_drop` | ✗ | **fixed**: `metal_metal` clatter |
| ore dropped into the intake (material_intake) | Kenney plate at 0.6× | ✗ a game sound | **fixed**: stone on steel (`metal_rock`) |
| a room vents through a failed seal or a forced door (room_air ventBurst) | `hiss_cylinder` (a small pneumatic cylinder) and a latch | ✗ too small for a breach | **fixed**: `fail("hull_breach")` at a pressure difference of 0.3 atm or more |
| a breaker trips on a fault (base_power) | `switch_3`, a desk switch click on the UI bus | ✗ a fault as a click | **fixed**: `fail("breaker_trip")` at the breaker |
| a reactor SCRAM, prompt-critical burst or meltdown (reactor_plant) | `switch_3` for all three | ✗ | **fixed**: `scram`, `explode` and `part_break` |
| a crew member hurt (crew.hurt) | only the HUD's synthesised `crew_hit` | ✗ synthesised, and nothing from the suit | **fixed**: `fail("suit_damage")`, a real windscreen crack and a hiss, where it happened |
| plasma bolt hits the crew (surveyor) | `sfx/crew_hit` (synthesised) | ✗ | **open**: the suit's crack now plays as well; replace `crew_hit` with a real body hit (shopping list) |
| cave rockfall, slab, roof ticks, gas (cave_hazards) | real recordings | ✓ | kept |
| a hull leak (cabin_air) | `foley/leak_hiss`, real | ✓ | kept |
| a battery or cell catching fire | (no such event in the game yet) | | `fail("battery_fire")` and `audio/impact/fire_loop` are ready for the heat pass to call |

### The crew on foot

| event | played before | fit | now |
|---|---|---|---|
| footsteps (planet_walker) | Kenney `footstep_concrete` on every world and floor | ✗ | **fixed**: `step` by surface: grit, soil, sand, snow, a metal deck or timber |
| jump push-off | Kenney `impactSoft_medium` | ✗ the same thud everywhere | **fixed**: a step on the surface |
| landing | Kenney `impactSoft_heavy` | ✗ | **fixed**: a step on the surface, and from a real drop (over 3 m/s) `impact` of the suit on that ground |
| slide start | Kenney `impactSoft_heavy` at 0.35 | ~ | open: a slide scrape on grit (shopping list: "boot slide gravel") |
| helmet on and off (suit) | Kenney plate tap, a seal hiss | ✓ | kept |
| suit lamps, flashlight | real toggle switches | ✓ | kept |
| suit breathing, suit hum (soundscape) | real recordings | ✓ | kept |
| swimming, wading, bubbles | the water agent's | (n/a) | not this pass |

### Craft and machinery

| event | played before | fit | now |
|---|---|---|---|
| staging, decouplers (vessel_controller `stage`) | `foley/pyro_bang`, the bird scarer | ✗ a gunshot | open: needs a pyro bolt or a heavy metal slam (shopping list) |
| boosters away (`boosters`) | `foley/pyro_far` | ✗ | open, same |
| parachute (`chute`) | `foley/hiss_short`, a brake release | ✗ no canopy | open: shopping list "parachute deploy" |
| landing gear (`gear`) | `foley/servo_run`, a car window motor | ~ | open: shopping list "hydraulic actuator" |
| rover motor and gravel | a car window motor, a mountain bike on gravel | ~ | open, as audio/incoming/README.md already asks |
| rocket engine | NASA SLS recording | ✓ | kept |
| re-entry | `wind_roar`, synthesised | ~ | open: shopping list |
| gas engines | real recordings | ✓ | kept |
| launch clamps (`clamp`) | `foley/clamp_clunk` | ✓ | kept |
| plant machinery, alarms, airlocks (plant_av, room_air, logic_net) | real recordings (audio/plant) | ✓ | kept |
| crew alarms, chime, heartbeat, sting (crew_alerts_hud, cabin_air, room_air, scenario_run) | synthesised (`gen_crew_audio.py`) | ~ alarms may be tones, but they read as a game | open: shopping list "suit master alarm" |
| vessel lost sting (sfx `lost`) | synthesised | ~ | kept (music cue) |
| laser and turret shots (lasers, laser_turret, surveyor) | synthesised weapon sounds; `pyro_bang` for blasts | ~ | open (weapons pass) |
| a cave flare lit (cave_flares) | `toggle_on` at 0.6× | ✗ a switch | open: shopping list "road flare ignite" |
| repair bay pumping (repair_bay) | `servo_short` at 0.7× | ~ | open |
| a beacon or flag planted (item_hand `plant`) | Kenney `impactMetal_medium` | ~ a metal hit for a spike into soil | open: could use `impact{a="metal", b="terrain"}` |
| a sample set down in the lab (lab) | Kenney plate at 1.3× | ~ | open: `plastic` or `glass_knock` |

### Interface (UI bus): all real switch, relay and printer recordings

| event | plays | fit |
|---|---|---|
| clicks, panels, pause, map, cards, VAB select and place, contracts, cash (sfx `CLIPS`) | BigSoundBank switches, relays, a calculator printing, a typewriter key, the Quindar tones | ✓ |
| the bag closing (sfx `bag_close`) | Kenney `impactPlate_light_002` | ~ a metal tap for a soft pack: shopping list "backpack buckle" |
| VAB scrap (builder `scrap`) | `foley/steel_drop` | ~ the can, but on the UI bus and quiet; could use `metal_metal` |
| terminals, keypads, logic panels, loot panel | key strikes, switches, the door buzzer | ✓ |
