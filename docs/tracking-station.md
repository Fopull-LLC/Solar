# The Tracking Station and crew switching

As built 2026-11-05 (phases P1 to P4 of the plan in
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
┌ top bar: emblem · TRACKING STATION · agency · counts · [Orbits · key][Debris] [Chart|Station] ✕ ┐
│ FLEET (276)                  the live map                   SELECTED (312) │
├ NEXT (events, soonest first, in a CRT inset)   WARP [▸▸ To next event] (rungs, ×N, the clock) ┤
```

- **FLEET** is grouped in this order: ATTENTION, CREW, CREWED, PROBES,
  LANDED, DEBRIS, RELAYS, FLAGS, BASES, STRUCTURES, WORLDS (§6). An entry appears in the first
  group that claims it.
  - **The header** (P3), three rows:
    - the search field and the sort key (A–Z · World · Altitude · From base ·
      Alerts, one click a step);
    - the kind keys: All · Craft · Crew · Infra · Debris;
    - the world key (each click the next world with anything of ours, then
      every world again), Crewed, Alerts.
  - The filters hide what fails them on the list **and** on the map. The
    search narrows the list and **dims** the rest of the map (alpha 0.35, no
    tag, never clustered). Kind, world, crewed, alerts and the sort are kept
    in the save (`opt_trackFilter`, with the map's two options); the search
    starts empty at each opening.
  - The search matches the name, world, kind, situation line, alert and the
    names of the crew aboard, case-blind (`fleet_view.searchHit`).
  - While the search field has focus, `typing()` is true: the map's keys (M,
    F2, Tab, 1–4, N) and the warp keys `,` `.` stand down
    (`warp_chip.typingNow`). The field is named `FieldStationSearch` (the
    rename field `FieldStationRename`), so step 7's rule for a focused
    `Field…` node keeps W A S D and the belt's keys out of the craft too.
  - Esc: the field first, then the search text, then the station.
  - DEBRIS and STRUCTURES start folded. **Pages** (P4): a group shows
    `PAGE` (40) rows with a pager (`◂ 41–80 of 200 ▸`) under it. A row picked
    on the map opens on its page (`reveal`); `scroll_to` uses the engine's
    `el:scrollTo` (card 0652) when it lands.
  - Each row: the glyph in its state colour, the name, the situation line,
    and on the right the alert, the link bars or `↺` when recoverable.
  - The craft you fly (or you, on foot) is `panel/rowActive`. The selection
    is the orange rim.
- **SELECTED** changes with the kind:
  - **Craft**: a CRT inset (ALT / AP / PE, INC, the countdown to PE or to
    impact, the period), the crew with ▸ switch keys, POWER and FUEL gauges,
    LINK, the alert placards, and the recovery badge (`↺ RECOVERABLE · +$N ·
    71 % · 4.1 km`, or `✕ Not recoverable:` followed by recoverRule's reason
    verbatim). **NEXT** with its next event and **▸▸ Warp**. Then the keys:
    **Fly** (orange), Recover, Focus, Target, Plan, Terminate (two presses).
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
- **WARP**: rungs `1 5 10 50 100 1k 10k` (greyed above the galaxy's cap).
  **▸▸ To next event** warps to the soonest event; while it runs the key reads
  `■ Stop · T−…`. The clock is the agency calendar (`Day 41, Y2 · 14:22:07`).
- **THE ONE WARP GATE** (P3): `warp_chip.request(w)`. The rungs, the craft's
  `,` `.` keys (vessel_controller), the same keys on foot, and warp to an
  event all ask it. It applies the galaxy's ceiling, the throttle, EVA in
  space, the 40 m rule (`vessel_controller.warpAltOk`) and footBlock on foot,
  and says each refusal on the warp chip. Going down is never refused.
- **Warp to an event**: `warp_chip.warpTo(t, label)` climbs the ladder
  through the gate and steps down as the time comes (`warpStep`, the rule of
  orbit_map's warp to node), landing about 10 s before it (up to 2.5 s more:
  the last rung keeps half a second of real time). Game time throughout. Any
  drop nobody asked for (a key, the stick, a refusal, the physics) ends it
  and says so. `warp_chip.warping` is published; `warpCancel(why)` stops it.
- **THE RIGHT-CLICK MENU** (P3): one `"fleet"` provider in context_registry,
  registered by the station and drawn by context_menu like every other menu
  in the game. A right-button tap on a map icon, on a name in an opened
  cluster, or on a FLEET row opens it (`openMenu(id, sx, sy)`, a map menu, so
  it stays up over the map). Rows: where, the alert, Fly / Switch to, Show
  its card, Focus, Target, Warp to its next event, Recover +$N, Rename…,
  Terminate… / Remove… / Forget… behind a red confirm. targeting.lua's own
  map menu asks `claimsTap(x, y)` first and leaves the station's taps alone.
- **The top bar's map keys** (P4): **Orbits · key / all** and **Debris**.

## 2. The map pass (frames)

`tracking_station.drawMap(ctx)` runs inside `orbit_map.update_map3d` in
lateUpdate, after the camera has been placed. `ctx.bodies` is the map's single
`space.bodies()` read for this frame; `ctx.cam` and `ctx.look` are where the
camera stands and the point it looks at this frame, `ctx.tanh` the lens.

- **Anchors are re-projected every frame.**
  - A live entry uses its node's drawn pose (`node.x/y/z`).
  - An offline entry uses `B[body] + offset`. A craft or debris on a conic is
    first carried to now with `space.propagate` from its record time (cached
    per game time, so a paused frame costs nothing). Between exact steps a
    second-order carry runs; the step grows with the view (P4,
    `carry_step`): as long as the carry stays inside a fifth of a pixel
    (its error is |j| h³ / 6, |j| ≤ 3 μ v / r³), from `CARRY_STEP` (1 s) up
    to `CARRY_MAX` (30 s).
  - Entries keep only body-relative offsets (`rx, ry, rz, st`). No world
    point is ever kept.
- **What is anchored**: what passes the filters, plus the selection, the
  hovered and an opened cluster's members. Entries on a body whose disc is
  under 2 px are skipped, except those. **The debris LOD** (P4): debris are
  anchored only when the Debris key is on and their world's disc is at least
  `DEBRIS_DISC` (40 × interface) px, so far out 200 debris cost nothing.
- **ONE PROJECTION FUNCTION** (P4): `project_many(pts, n, out, ctx)` takes a
  flat list of world points and fills a flat `{sx, sy, depth, on, …}`, the
  shape of the engine's batched call (card 0650,
  `camera.worldToScreenMany(points [, out])`), which it calls as is when it
  exists. Until then a Lua pinhole camera built from `ctx` (forward from
  `cam` to `look`, the map never rolls, `f = viewport height / 2 tanh`) is
  **checked every frame** against `camera.worldToScreen` at four of the
  points. If the lens as the map sets it misses by more than `PROJ_TOL`
  (0.25 px), the two gains and centres are fitted to those four answers (a
  camera whose FOV or viewport the map does not know: the probe's runs at the
  default 1.15 rad) and kept only if every one is within `PROJ_TOL`;
  otherwise that frame is projected one engine call a point. `proj.mode` is
  `engine`, `lua`, `lua-fit` or `single`.
- **Icons**: an enamel disc with a state-coloured rim and the glyph
  (`fleet_view.GLYPHS`: ◉ ◆ ◇ ✈ ⊡ ⊚ ⊕ ✕ ▲ ▮ ◌ ⌂).
  - Debris is a 3 px muted speck. Specks never cluster and never get a tag
    (unless selected or hovered): a debris field reads as specks, not as a
    pile of counts.
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
    selection, hover, filters, snapshot version, screen and interface size),
    and at least 4 times a second. Between runs only the offsets are kept.
  - Text widths are `draw.textWidth` (card 0651) when it lands, else the
    0.56 × size estimate.
- **Clusters**: 3 or more icons within 14 px become one disc with a count,
  rimmed in the dominant kind's colour.
  - Hovering one previews up to 8 names.
  - **A click (or a right-click) opens it** (P4): a riveted column of its
    names beside the cluster, in the map area and off the plates, `FAN_ROWS`
    (10) at a time; the wheel scrolls it. The name under the pointer lights,
    and a ring and a 1 px leader mark where that member is this frame. A
    click on a name selects it; a right-click opens its menu; a click
    elsewhere or Esc folds the column. The column is placed each frame from
    where its members are THIS frame (only the member list is kept).
  - Inside a disc, the disc is what the pointer means (it is drawn over the
    icons under it).
- **Pointer**: a click on an icon selects it. Over a plate, an icon, a disc
  or an opened column the map places no node and does not zoom
  (`pointerBusy`, `ownsPointer`).
- **Orbit lines** (P4, the clutter pass): in station mode the station draws
  the craft's lines itself (`draw_tracks`; orbit_map's `drawCraftTracks`
  stands down). By default only the ones that matter: the selection, the
  hovered, the craft you fly (bright), the crewed and ATTENTION craft (the
  quiet colour, a little stronger). The rest **fade out** (alpha eased at
  10 /s, real time). **Orbits · all** keeps them, faint. Each line is built
  from the same pose its icon is anchored with (the node's drawn pose, or
  the record carried to now) against this frame's body read (rule 2).
  `drawTrack` takes an optional `fade`.
- In station mode `mapComms` draws only the lines, coverage and ground
  station. The station draws the craft, relays and flags itself. The legend
  block is hidden; its keys are on the strip.

## 3. The snapshot (`fleet_view.lua`)

- `snapshot()` is rebuilt every 2 s (`RATE`; the live poses and the card's
  numbers are read every frame anyway), or as soon as one of these changes:
  - `flight_ops.fleetVersion` (new; bumped on every fleet write);
  - `comms.networkVersion`;
  - `structures.version`;
  - `deployables.version`;
  - `debris_pack.packVersion` (new);
  - `crew.version` (at most 4 Hz).
- The build is a coroutine stepped **only by the station's update**, one
  slice a frame. The map pass and the per-frame hooks (`focus_point`,
  `pickedNode`, the menu) read the last finished snapshot (`snap_now`); before
  P4 each of them stepped the build too, three slices a frame.
- A record's kind, seats and fuel capacity are decoded once per record write,
  keyed by `rec.t`.
- `flight_ops.fleetList` now caches each record's battery decode the same
  way. That was the per-frame 5,000-decode cost the old panel paid.
- Pure rules, tested in luajit: `kindOf`, `attention`, `situation`,
  `keyNumber`, `groupOf`, `orbitTimes`, `nextEvents`, `clockText`, and (P3)
  `passes`, `searchHit`, `sortList`, `filterSig`, `kindClass`.
- The bases (BASES group, kind `outpost`, and the spaceport) are `ALWAYS`:
  on the map whatever the filters, and never folded into a cluster.

### 3.1 The ATTENTION table (`fleet_view.attention`, pure)

An alert tints the icon's rim, puts the entry in ATTENTION, lifts its layout
priority, gives it a T2 tag and is listed on the card. The worst leads.

| source | rule | text |
|---|---|---|
| power | batteries under 10 % (amber), flat (red) | `POWER 6 %` / `NO POWER` |
| comms (antenna aboard) | a probe with no path home (red); a crewed craft (amber) | `NO SIGNAL · no path home` / `NO SIGNAL` |
| heat (live craft) | the reactor's T (`thermalHud().T`, 0..1) ≥ 0.75 amber; ≥ 0.90 (the scram line) or scrammed red | `HEAT 80 %` / `HEAT 93 % · SCRAM` |
| cabin (live craft) | the weakest seated crew part under 35 % hp (`partHp`) | `CABIN FAILING` |
| trajectory | crewed, in flight, sub-orbital (`orbitTimes().tImpact`), chutes not open; red inside 2 min | `IMPACT in 4:12` |
| crew aboard | a member's HP under half; dose ≥ 50 % (red ≥ 80 %) | `Dana HP 42 %` / `Dana DOSE 61 %` |
| member: air | the left-behind's record alert (`crew.recordAlerts`) first, else O2 < 25 % amber, < 10 % red | `LAST AIR` / `O2 18 %` |
| member: health | HP under half; DOWN with the seconds left | `HP 42 %` / `DOWN · 74 s` |
| member: dose | ≥ 50 % amber, ≥ 80 % red; rising now (the member you are) amber from 5 % | `DOSE 61 % ▲` |

Contract deadlines join when missions have them (P5).

### What keeps it cheap

- **One projection call** (`project_many`): a Lua pinhole checked against
  the engine at four points a frame, instead of ~250 `camera.worldToScreen`
  calls; the engine's batched call (card 0650) when it exists.
- **Script handles are read once a frame**: `fv.passes`, `fv.searchHit` are
  taken into locals before the loops (every read through a handle is a lookup
  in the engine).
- **Plates in one test**: a point is under a plate unless it is inside the
  map area between the four plates; only the few other rects that reach into
  it (the menu button, an open menu) are tested one by one.
- **The carry survives a rebuild** (`CARRY`, by id, while the record is the
  same): a new snapshot does not propagate every orbit again in one frame.
- **The debris LOD**: far out, 200 debris cost nothing.
- **The layout** runs at most 4 times a second. A new selection, hover or
  filter re-runs it at once. Between runs only the offsets are kept.
- **Between layouts**, only the seed of each cluster is anchored, which is
  all the disc's place needs. A craft is always anchored (it may draw its
  orbit).
- **The recovery verdict** (a raycast and a parts price) is kept 2 s per
  craft, staggered. It is asked again at once when the craft lands or lifts
  off, or after a recovery.
- **The FLEET list** is re-made only when what it shows changes (a signature
  of the filters, pages, ids, names, situation lines, alerts and links), and
  shows PAGE rows a group.
- **The other panels**: the card at 5 Hz; the strip at 2 Hz, its NEXT events
  worked out at most once a second and carried to now in between; the top bar
  when the snapshot or the map keys change.
- **Probe stats**: `stats` in tracking_station holds the smoothed ms of each
  part (anchors split into gather, project, points, tracks; layout, draw;
  update split into snapshot, hover, list signature; the makes) and the
  projection mode (`proj`). `fleet_view.stats` splits the snapshot build.
  `tools/perf/station_bench.lua` A/Bs two versions of the map pass in luajit.

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

## 6. The worlds: WORLDS and the BODY card (expansion X1)

Every planet and moon of the home system is an entry, `w:<name>`, kind
`body`, group **WORLDS** (the last group, open, in roster order: each planet
followed by its moons). Its situation line is "planet · 63 % known", "moon of
Naolol · surveyed" or "home world · surveyed"; the right column is the share
known or SURVEYED. A body is its own kind class (`world`): only **All** shows
it, and the world key filters to its own entry with everything on it.

- **The map** draws the bodies itself, so the station puts no icon at a
  body's centre (`drawMap` skips kind `body`). Focus frames the whole body
  (3.2 radii); Target makes it the target (`targeting.targetBody`).
- **The BODY card** (`card_body`): radius, SOI and the distance from you in
  the CRT inset; "⌂ 2 bases here" when the spaceport or a tower's base is on
  it; then **SURVEY** with the six layers of `survey.rows(name)`:
  - the label, a bar (green when full, amber while filling) and the share;
  - the value when full ("0.98 g · 9.6 m/s²", "0.94 bar · BREATHABLE · N₂ 78 %
    · O₂ 22 % · Ar 1 %", "288 K · 15 °C", "46 µT", "iron 41 % · copper 28 % ·
    …"), or the band of what is not yet known ("about 0.7–1.2 g"), which
    narrows as the layer fills;
  - while unfilled, a "learn:" line naming the instruments that fill it;
  - ◆ SURVEYED when all six are full, and the RP earned there.
  - Focus / Target / Plan.
- `survey.rows` caches its answer per survey version (the card asks five times
  a second); the snapshot rebuilds when `survey.version` moves (the seventh
  stamp).
- What the layers are, how they fill and what they earn: `scripts/survey.lua`
  and `docs/crew-and-items.md` §11.

### 6.1 Base roles and the res_map (expansion X7)

What each base is for and the scanner's map (`scripts/base_roles.lua`,
`docs/base-building.md` §25):

- **BASES rows** wear the glyph of the base's strongest role (⇆ ⛁ ⚒ ⚡ ⚙ ✦ ▤ ✚,
  ⌂ for an outpost) and the situation "FUEL · MINE · ground station" (the
  spaceport "spaceport · PORT"). `fleet_view` copies `roles` and `stats` from
  `base_tower.bases()` (the records) onto the entry; `base_roles.version` is
  the snapshot's ninth stamp.
- **The role key**: a third header row holds the world key and the role key
  (All roles → Port → Fuel → Mine → Power → Refinery → Science → Depot →
  Defence, one click a step); Crewed and Alerts moved to a fourth row. With a
  role set only the bases carrying it pass (`fleet_view.passes`'s `F.role`),
  on the list and on the map; it is kept in `opt_trackFilter`.
- **The base card** (and the spaceport's) gains ROLES: each role's glyph,
  label, strength bar and why; a CRT inset with the last 24 h (IN, OUT, MINED,
  WORKED) and all-time totals with run cycles; the pieces and stores counted;
  and the two first roles it lacks with what gives each.
- **The BODY card** lists each base on the world with its role line, and
  under the six layers an **ORE MAP** key: the share of the ground the
  scanners have swept and each ore found in the mapped cells, in its map
  colour, most cells first.
- **The res_map on the map**: with a world selected, a disc on every mapped
  cell of the hemisphere facing the camera, tinted by the ore its patch holds
  most (`survey.resMap`, 12 cells read a frame until all are; the palette is
  categorical, in the key's order), placed against this frame's body read.
  Nothing is drawn while the world's disc is under 60 px across.
- Probes: `pickEntry(id)`, `setFilter(k, v)`, `resmapStats`.

## 7. Left for later

- **P5**: the VAB board, EN6/EN14 swaps (cards 0651, 0652), per-craft nodes
  in NEXT, contract deadlines, tower-as-station recovery, and the ☰ TRACKING
  key.
- `project_many` keeps the seam for `camera.worldToScreenMany` (card 0650: E
  built it and held it, a single call is ~0.1 µs in a release build; the
  cost was ours, around the call). Nothing else would change.
