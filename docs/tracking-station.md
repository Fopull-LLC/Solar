# The Tracking Station and crew switching

As built 2026-11-05 (phases P1 and P2 of the plan in
`.floptle-shared/solar/work/tracking/PLAN.md`). Read
`docs/positions-and-frames.md` before changing anything that draws on the
map.

## 0. One screen, two densities

The Tracking Station is a mode of the orbit map, not a separate panel.

| | CHART | STATION |
|---|---|---|
| opens with | `M` | `F2` (anywhere), the pause menu's **Tracking Station**, E at the dish |
| closes with | `M`, `Esc` | `F2`, `M`, `Esc` (after the rename field), the ✕, E again if the dish opened it |
| draws | bodies, conics, links, the legend, the node | the same lines, plus icons by kind, tag layout, clusters, panels |
| pauses | no | no |

`orbit_map.mode` is `"chart"` or `"station"`; `openStation()`, `setMode(m)`,
`close()`, `focusOn(fn)` are its API. The station's script
(`tracking_station.lua`) owns the panels and the map pass; `fleet_view.lua`
owns the snapshot; `map_labels.lua` the tag layout. All three ride the
"Tracking Station" node in `scenes/system.ron`, with three sibling plates:
"Station Fleet", "Station Card" and "Station Strip" (full-screen Stretch
layers, invisible until the station opens).

`F2` is ignored while the VAB builder has the keys. The hangar board is P5.

## 1. The screen

```
┌ top bar: emblem · TRACKING STATION · agency · counts · [Chart|Station] ✕ ┐  (☰ stays free)
│ FLEET (276)                  the live map                   SELECTED (312) │
├ NEXT (events, soonest first, in a CRT inset)      WARP (rungs, ×N, the clock) ┤
```

- **FLEET** is grouped in this order: ATTENTION, CREW, CREWED, PROBES,
  LANDED, DEBRIS, RELAYS, FLAGS, STRUCTURES. An entry appears in the first
  group that claims it.
  - DEBRIS and STRUCTURES start folded. A group shows at most 60 rows.
  - Each row: the glyph in its state colour, the name, the situation line,
    and on the right the alert, the link bars or `↺` when recoverable.
  - The craft you fly (or you, on foot) is `panel/rowActive`. The selection
    is the orange rim.
- **SELECTED** changes with the kind:
  - **Craft**: a CRT inset (ALT / AP / PE, INC, the countdown to PE or to
    impact, the period), the crew with ▸ switch keys, POWER and FUEL gauges,
    LINK, the alert placards, and the recovery badge (`↺ RECOVERABLE · +$N ·
    71 % · 4.1 km`, or `✕ Not recoverable:` followed by recoverRule's reason
    verbatim). Then the keys: **Fly** (orange), Recover, Focus, Target, Plan,
    Terminate (two presses).
  - **Member**: O2/HP/DOSE, role, and **Switch to** / **Go to · Iru** /
    **At base · switch** / **Fly · Kestrel**, greyed with the reason when
    not allowed.
  - **Relay, flag, debris, structure, spaceport**: where they are, and Focus,
    plus Remove (flag) and Forget (packed debris).
- **NEXT** lists, soonest first:
  - the maneuver node;
  - Pe and Ap of every craft in orbit, or its impact if sub-orbital
    (`fleet_view.orbitTimes`, carried to now);
  - retraining finishing.

  Click an event to select and frame its craft.
- **WARP**: rungs `1 5 10 50 100 1k 10k` (greyed above the galaxy's cap),
  through `warp_chip.request(w)`, which applies the same refusals as the
  keys and says why. `,` `.` work as before. The clock is the agency
  calendar (`Day 41, Y2 · 14:22:07`).

## 2. The map pass (frames)

`tracking_station.drawMap(ctx)` runs inside `orbit_map.update_map3d` in
lateUpdate, after the camera has been placed. `ctx.bodies` is the map's single
`space.bodies()` read for this frame.

- **Anchors are re-projected every frame.**
  - A live entry uses its node's drawn pose (`node.x/y/z`).
  - An offline entry uses `B[body] + offset`. A craft or debris on a conic is
    first carried to now with `space.propagate` from its record time (cached
    per game time, so a paused frame costs nothing).
  - Entries keep only body-relative offsets (`rx, ry, rz, st`). No world
    point is ever kept.
- Entries on a body whose disc is under 2 px are skipped, except the selection.
- **Icons**: an enamel disc with a state-coloured rim and the glyph
  (`fleet_view.GLYPHS`: ◉ ◆ ◇ ✈ ⊡ ⊚ ⊕ ✕ ▲ ▮ ◌ ⌂).
  - Debris is a 4 px muted square.
  - The selection gets an orange ring, the hovered entry a lit ring.
  - The craft you fly gets an orange pip.
- **Tags** (`map_labels.layout`):
  - Priority order, with selected and hovered above everything else.
  - Each tag tries 8 spots round its icon, then 4 further out with a leader
    line.
  - A tag that fits nowhere drops a tier: T2 (name and situation line) to
    T1 (name) to icon only.
  - At most 40 tags. Tags avoid the four plates, every other icon and the
    names the map has already placed.
  - The selection may cover icons as a last resort.
  - The layout re-runs when its key changes (zoom bucket, yaw/pitch to 1°,
    selection, hover, snapshot version, screen and interface size), and at
    least 4 times a second. Between runs only the offsets are kept.
- **Clusters**: 3 or more icons within 14 px become one disc with a count,
  rimmed in the dominant kind's colour. Hovering one fans out up to 8 names;
  clicking selects its seed.
- **Pointer**: a click on an icon selects it. Over a plate or an icon the map
  places no node and does not zoom (`pointerBusy`, `ownsPointer`).
- **Lines**:
  - Live craft draw their conics through `drawCraftTracks`, now from the
    node's drawn pose (it was the tick pose before, so dot and conic could
    sit one tick apart).
  - Offline craft in flight get their own conic (dim, bright when selected).
- In station mode `mapComms` draws only the lines, coverage and ground
  station. The station draws the craft, relays and flags itself. The legend
  block is hidden; its keys are on the strip.

## 3. The snapshot (`fleet_view.lua`)

- `snapshot()` is rebuilt at 2 Hz, or as soon as one of these changes:
  - `flight_ops.fleetVersion` (new; bumped on every fleet write);
  - `comms.networkVersion`;
  - `structures.version`;
  - `deployables.version`;
  - `debris_pack.packVersion` (new);
  - `crew.version` (at most 4 Hz).
- A record's kind, seats and fuel capacity are decoded once per record write,
  keyed by `rec.t`.
- `flight_ops.fleetList` now caches each record's battery decode the same
  way. That was the per-frame 5,000-decode cost the old panel paid.
- The old 900-unit panel is gone. Nothing calls `ui.make` or `fleetList()`
  every frame:
  - the list is described when it changes;
  - the card at 10 Hz;
  - the strip at 4 Hz;
  - the top bar at 2 Hz.
- Pure rules, tested in luajit: `kindOf`, `attention`, `situation`,
  `keyNumber`, `groupOf`, `orbitTimes`, `nextEvents`, `clockText`.
- ATTENTION in P1 covers power (<10 % amber, flat red), signal (a probe with
  no path is red, a crewed craft amber; only with an antenna aboard), a
  member's O2 (<25 % amber, <10 % red), HP <50 %, DOWN, a crewed craft's
  members' HP, and the left-behind's LAST AIR.

### What keeps it cheap

- **The layout** runs at most 4 times a second. A new selection or hover
  re-runs it at once. Between runs only the offsets are kept.
- **Between layouts**, only three members of each cluster are projected,
  which is all the disc's place needs. A craft is always projected (it draws
  its conic).
- **The recovery verdict** (a raycast and a parts price) is kept 2 s per
  craft, staggered. It is asked again at once when the craft lands or lifts
  off, or after a recovery.
- **The FLEET list** is re-made only when what it shows changes (a signature
  of ids, names, situation lines, alerts and links). A new snapshot with the
  same rows costs one string.
- **The other panels**: the card at 5 Hz, the strip at 4 Hz, the top bar at
  2 Hz.
- **Probe stats**: `stats` in tracking_station holds the smoothed ms of each
  part (anchors, layout, draw, snapshot, list, card, strip, top) and the
  projection counts. `fleet_view.stats` splits the snapshot build.

## 4. Crew switching (`crew.lua`)

`crew.switchToMember(id)` is the single entry point. `canSwitch(id)` returns
`ok, why, mode, detail` and is what every picker greys rows from.

| mode | when | what happens |
|---|---|---|
| `near` | on foot in body range | `control(id)`: instant, with the camera handoff |
| `craft` | seated in a craft in the scene | `takeCraft(v, id)` |
| `base` | at base, base within 2.5 km | `spawnAtBase`: stands up at the station's crew home, body-relative, queued into the physics tick |
| `travel` | anything else (far, another world, a craft not rebuilt) | `goTo`: leave, curtain, arrive |

These are refused, with the reason: dead, yourself, down (bring a Medkit),
retraining (`busy()` text), and seated in a lost craft (a rescue, not a switch).

**GO TO** happens in three steps:

1. The one you are is left where they stand, through `free_avatar`, as
   always.
2. `game_manager.travelTo(body, rx, ry, rz, label, done, {wait})` raises the
   loading curtain ("Travelling to Dana Okafor · Iru"). It holds the
   Astronaut 40 m over the live spot, re-read every frame, and warms that
   world. It waits for the ground (`terrain.query` at the spot) and, for a
   seated member, for `flight_ops.requestRestore`'s craft to come back. It
   gives up after 60 s.
3. On arrival the member becomes active at their record, or the seated craft
   is taken. The impact monitor is quiet for the trip and 3 s after.

**The one left behind**, out of body range, is still ticked:
`crew.recordTick()` runs at 1 Hz on the agency clock, in closed form
(`recordStep`).

- In airless or unbreathable air the suit drains: tanks first, then
  `SUIT_AIR_SECS`.
- When it runs out: the `grace_suit` blackout, then `kill(id, "air")` per
  CREW SAFETY.
- A 10,000 s step equals 10,000 one-second steps.
- `recordAlerts[id]` carries `O2 25 %` / `O2 10 %` / `LAST AIR` for the
  pickers and the station.
- `rec.leftAt` is written when a member is parked, set afoot or leaves range.

**Camera**: `planet_camera.handoff(from, to)`. Under 60 m it sweeps the
body-relative camera over 0.35 s; past that it fades from black over 0.2 s.

**Entry points**:

- the crew strip's **CREW ▸** key (the picker, above the strip; the strip
  now stays up on foot whenever anyone else is alive);
- the pause menu's **Switch crew member…** page;
- the Astronaut Complex's **Go to** (any case `canSwitch` allows);
- the station card's switch keys.

**Saving**: no new shape, only `rec.leftAt` and `rec.blackout` on the
records. `crew.active` and the avatar pose are saved as before.

## 5. Tests and the probe

- **luajit**:
  - `smoke_tracking` (60 craft, 200 debris, panels, actions, cadence, the
    map pass: anchors, ≤ 40 non-overlapping tags off the plates, a click
    selects);
  - `smoke_fleet_view`, `smoke_map_labels`, `smoke_crew_switch`;
  - `smoke_ui_font` (every glyph in SolarLabel and SolarUI);
  - `smoke_flags` (the station's flag card), `smoke_pause` (F2 polled).
- **engine**: `tools/perf/trackprobe.sh <engine>` with `PATCHES=funds.patch`.
  - It builds a busy fleet (a rover template from the VAB; 49 clones on
    three orbits and on the ground; 200 packed debris; 4 relays; 3 flags;
    3 structures; 5 crew, one on a moon).
  - Shots at three zooms and in the chart.
  - 10 s at ×100 with every anchor checked against a fresh projection in the
    same frame (`probeHook`).
  - Label checks, the perf windows (station against chart), 30 open/close
    cycles, recovery, and the four crew-switch cases.

## 6. Left for later

- **P3**: filters, search (with `typing()` gating), sort, the full attention
  table (heat, cabin, trajectory), `warp_chip.request` for the `,` `.` keys
  too, `warpTo(t)` / TO NEXT EVENT, and the `"fleet"` context-menu provider
  shared by the list and the map.
- **P4**: fanned-cluster selection, hover tooltips on dense clusters, list
  paging past 60 rows, `perf.cost` instrumentation at 50 craft on the bench
  machine.
- **P5**: the VAB board, EN6/EN14 swaps, per-craft nodes in NEXT, contract
  deadlines, tower-as-station recovery, and the ☰ TRACKING key.
