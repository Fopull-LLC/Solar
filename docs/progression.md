# Progression: feats, and the ruin near home

The progression rework (work/progression/PLAN.md) as built. Slices P1 (feats)
and R1 (the ruin near home) are in; P2 (the nine milestones), the wood tier
and the load model come later.

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
| `wood_built` (n) | field_builder `place` | the piece is a `*.wood` one (the wood tier, later) |
| `base_founded` | base_tower `reconcile` | a tower founds a base: one placed, or a claimed ruin's (key: the base id) |
| `ruin_found` | ruins `discover` | any way a ruin is found (key: the site) |
| `ruin_claimed` | ruins `claim` | |
| `core_read` | ruins `readCores` | |
| `ruin_stripped` (n) | loot `strip` | a ruin's piece (key: site and piece) |
| `lock_opened` | loot `enterCode`, `forceLock` | by its code or forced: both count (key: the piece) |
| `ore_studied` | research `study` | an ore kind's first study (key: the material) |
| `cave_kinds` (n) | cave_hazards `first_entry` | a cave kind's first entry (key: the kind) |
| `run_cycle` (n) | route_ops | a run's cycle done |

Still to be marked (they need a new detection, not a line): `grid_served`,
`night_held`, `room_sealed`, `room_breathable`, `fluid_moved`, `logic_fired`,
`machine_worked`, `part_fabricated`, `reactor_critical`, `storm_held`,
`rtg_night`, `dose_taken`, `cave_cache`, `drive_km` (PLAN §2.1).

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
