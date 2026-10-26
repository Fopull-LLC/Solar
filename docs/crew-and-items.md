# Crew and items: the agency, its astronauts, and the things they carry

Design for the crew-and-items upgrade, 2026-10-25. Engine: Floptle 0.117.0-rc27.
Status: decision-ready. Each section recommends one way to build it. Open questions
that are the user's to answer are collected in §9.

## 0. Summary

The player is the **agency**, not one astronaut. The agency hires a **roster** of crew.
Any crewed part seats as many crew as it has **slots**. You control one thing at a
time: **a craft**, or **one crew member on foot**. A **crew strip** of live portraits in
the bottom-left corner shows the crew aboard the craft you are flying. Hover a
portrait and **EVA** sends that crew member out of the part's hatch. Every on-foot crew
member nearby is one click, `[`/`]`, or `` ` `` away.

Everything a crew member uses is a physical **item** with mass and bulk: the Gravity
Gun, the Terrain Laser, the **Repair Kit**, the **Relay Beacon**, and the
**Company Flag**. Items sit in a crew member's pack, a **stowage locker** part, a
craft's hold, or the base warehouse. In the VAB you hand items to crew or load them
into lockers. In the field you take them out of a locker through the right-click
menu, hold one in your hand, and use it.

A repair means walking to the broken part with a kit in hand, right-clicking the part
and choosing **Repair**. The crew member then works on the part with both hands for a
set time, and a progress bar fills. Deployables (beacon, flag) are placed from the
hand with a ghost preview. They are saved in the world, and the Tracking Station
lists them. A planted flag waves in the local wind, hangs straight on an airless
world, and is photographed at the moment it is planted.

The single-astronaut code keeps working throughout:

- the `Astronaut` node stays, as "the crew member you are controlling on foot";
- inventory container `"astro"` becomes an **alias** for that crew member's pack;
- old saves migrate once: the existing astronaut becomes crew member #1, and the
  `astro` pack becomes theirs.

## 1. What exists today (the constraints this design works within)

| Area | Today | Consequence |
|---|---|---|
| The astronaut | One scene node `Astronaut` (scenes/system.ron) with planet_walker, tool_belt and base_props. 35 scripts call `find("Astronaut")`. | Don't rename it or make several of them. It becomes the controlled on-foot avatar (§4.1). |
| Crew in a craft | `vessel_controller` keeps the booleans `crewAboard`/`piloting` and one `stationUid`. `crewSeats` lists crewed parts, and **every crewed part holds 1** (`mods.command.crew = 1`: pod, seat, Swift cockpit). The hidden astronaut rides as a kinematic body (`seatCrew`). `command_seat.lua` poses that astronaut in an open seat. | Seats need slots. Crew aboard become visual **dolls**, not bodies. |
| fixedUpdate | `vessel_controller.fixedUpdate` is at LuaJIT's 60-upvalue ceiling. | All new controller code is **globals** (the file's existing rule). |
| Packs | `inventory.lua` containers: `astro` (90 kg), `hold:<ship>`, `base`, `salvage:<id>`, and now `locker:<n>` (the context-menu work). Materials go in `inv.<cid>`; gear goes in `inv.gear.<cid>` from `inventory.GEAR` (`gravgun`, `laser` tools at 0 kg; `beacon` 6 kg, $80, sold at the depot). | GEAR becomes the item registry. Keep the key layout. |
| Belt | tool_belt builds the hotbar from the pack's gear every frame (`TOOL_ORDER`). The beacon has its own place/pick-up code (`fire_beacon`, Q picks up). | Generalise to "hold an item" plus "deploy mode". |
| Relays | comms.lua owns beacon records (`comms.beacons`, `comms.beacon.<id>`, body-relative), their nodes (parented to the planet), `beaconSnapshot/Restore` for revert, and the relay solve. | **comms stays the owner** of relay records. The item only calls `placeBeacon`/`removeBeacon`. |
| Right-click | `context_registry.lua` (providers by target kind: `astro`, `part`, `builder_part`, `crate`, `prop`). Entries may be a timed `job {secs,label,check,done,cancel}`. The in-progress `context_providers.lua` has suit, part health, tanks, lockers and holds. vessel_controller (patch in SCRATCH/ctxmenu) adds `LOCKERS`, `lockerOf`, `partHp`, `repairPart`, `wearPart`, `damagedParts`, and per-part wear persisted in `st.hp`. | Repair builds on `repairPart`. Held items register providers. |
| Fleet | flight_ops `fleet.craft` records carry `crew = bool`, `station`, and the parts (with their `st` state, which `electronics.packRecord` keeps). | Crew assignment rides **in the part's own state** (`st.crew`), like `st.locker` and `st.hp`. |
| Revert | vessel_spawner snapshots `REVERT_KEYS`, every inventory container, and the beacons. | Add `crew.*` and `dep.*` to the snapshot. |
| Engine | Render targets (`setCamera{target,width,height,hz,cullMask}`, at most 8 live per scene, `rt:<name>` on a UI image). Camera stacks. `ui.dragging`/`ui.dropTarget`/`ui.hovered`. `anim:reach`/`anim:lookAt` (IK). `weather.windAt`. Surface shaders with `output offset` (the docs' own example is "a flag that ripples"). `camera.capture`/`captureTexture`. `save.set` (16 deep, 10 000 keys). | Most of what this needs exists (§8). |

## 2. Agency and crew roster (A)

### 2.1 The crew record

There is one save key per member, `crew.m.<id>`, the same pattern as `comms.beacon.<id>`:

```lua
{ id = 3, name = "Dana Okafor", hired = <space.time()>, cost = 2400,
  role = "pilot",            -- "pilot" | "engineer" | "scientist" | "rookie" (traits later; unused in v1)
  status = "afoot",          -- "base" | "aboard" | "afoot" | "lost"
  -- where (status decides which fields mean anything):
  craft = "Kestrel I",       -- aboard: display only (the truth is the part's st.crew, §3.2)
  body = "Vever", x = .., y = .., z = .., yaw = ..,   -- afoot: body-relative, like salvage/beacons
  -- the suit:
  o2 = 1.0, helmet = true, hp = 1.0,
  hand = "repairkit",        -- the item in hand (nil = empty hands)
  task = nil,                -- a running job (§6.3), or nil
  flights = 4, eva_s = 1830, flags = 1,               -- service record, for the roster panel
}
```

Other keys:

- `crew.roster`: the id list in hire order.
- `crew.seq`: the last id issued.
- `crew.active`: the id the `Astronaut` node is now, or `false` when it is unbound (§4.1).
- `crew.offers`: the three applicants on the board.
- `crew.version`: the migration stamp (`1`).

Each crew member's pack is an ordinary inventory container, **`crew:<id>`**. Its
capacity rule is the suit's: `cap("crew:*") = suit_kg`.

### 2.2 Hiring

The Command Centre gets a **CREW** button next to its Overview button. It opens the
**Astronaut Complex** panel (`crew_roster_panel.lua`):

- **Roster.** Each crew member gets a row: name, status, where, and service record.
  The actions are **Rename**, **Go to** (an on-foot member in physics range; §4), and
  **Recall**. Recall brings an on-foot member home for the pickup fee
  (`flight_ops.pickupFee`).
- **Applicants.** Three names, each deterministic from `g_seed` and `crew.seq`, with
  a hire cost of `1500 + 600 × (roster size − 1)`, capped at 6000. Hiring spends
  through `company.spend`. A hired member starts at base (`status = "base"`) with the
  standard issue (§5.1) taken from the base warehouse, or bought if the warehouse is
  short.
- **The agency never runs out.** If no member is alive and free (none at base or on
  foot), the next applicant joins for free with a caption. The game can't
  softlock on crew.

A crew member at base has no body. They are "in the building". The game always has
someone to control on foot (§4.1).

### 2.3 Losing crew

Today's rule is "surviving a breakup costs you the ship, not the save" (vessel_controller
destruction comment). The new rule extends it: **every crew member in a lost
part survives** and is set down beside the wreck as an on-foot member. Out of air is
unchanged: they wake at the base and pay the fee. The `lost` status exists in the
schema so that permadeath can be added as a setting later (open question Q1).

### 2.4 Migration of existing saves (runs once, `crew.lua`)

It runs when `crew.version` is nil and `g_played` is true (an existing save). New
saves are created at version 1 with member #1 already in place.

1. Create member #1 with a generated name, role `pilot`, and `hired` = 0.
2. Move the pack: `inv.astro` → `inv.crew:1` and `inv.gear.astro` → `inv.gear.crew:1`.
   Then write `{}` to the old keys (the store has no delete for these;
   `save.delete` is used where it exists).
3. Find where they are:
   - If a `fleet.craft` record has `crew == true`, put `{1}` into the `st.crew` of the
     part whose uid is its `station` (or of the record's first crewed part), set
     `status = "aboard"`, and set `craft` to the record's name.
   - Otherwise set `status = "afoot"` at the saved crew position (game_manager's
     `p` keys), and set `crew.active = 1`.
4. `tool.id`/`tool.equipped` become the record's `hand`.
5. Set `crew.version = 1`.

After this, `"astro"` keeps resolving to the active member's pack (§5.2), so the
objectives, salvage, the inventory panel, the depot and the mining code all keep
working without edits.

## 3. Seats, pods and hatches (B)

### 3.1 Capacity and geometry in the registry

Every crewed part gains `seats` and `hatch` in `parts_registry.REG` (and in
`parts_aero` for the cockpit), in the part's local frame, the same frame the
blueprint's `x,y,z` use:

```lua
pod   = { ..., kind = "crewed", mods = { { type = "command", crew = 1, ... } },
          seats = { { x = 0, y = 0.05, z = 0.10, yaw = 0 } },
          hatch = { x = 0, y = 0.10, z = -0.52, nx = 0, ny = 0, nz = -1 }, iva = "IvaPodMk1" },
podMk2 = { prefab = "PartPodMk2", label = "Pod Mk2", ..., kind = "crewed",       -- NEW: 3 crew
          mods = { { type = "command", crew = 3, draw = 0.08 }, { type = "wheel", torque = 1.6, draw = 0.6 },
                   { type = "battery", ec = 80 } },
          seats = { {x=-0.38,y=0,z=0.1,yaw=0.2}, {x=0,y=0,z=0.12,yaw=0}, {x=0.38,y=0,z=0.1,yaw=-0.2} },
          hatch = { ... }, iva = "IvaPodMk2" },
cabin = { prefab = "PartCabin", label = "Crew Cabin", kind = "structural",        -- NEW: 4 passengers
          mods = { { type = "cabin", crew = 4 } }, seats = { ... }, hatch = { ... }, iva = "IvaCabin" },
seat  = { ..., seats = { { x = 0, y = 0, z = 0, yaw = 0, open = true } }, hatch = nil },  -- an open seat is its own exit
cockpit = { ..., seats = { { ... } }, hatch = { ... canopy ... }, iva = "IvaCockpit" },
```

The rules:

- **Slot count** = `#seats`, which must equal `mods.command.crew` (or `mods.cabin.crew`).
- **Only a `command` mod with crew > 0 can fly the craft.** A cabin carries people
  but commands nothing.
- A probe core keeps commanding over its link exactly as today. A craft with a probe
  core and a crewed pod can be flown either way.
- `rescanSeats` builds one entry per *slot*: `{ uid, slot, x,y,z (vessel frame,
  composed from part pose + seat offset), open, hatch }`.

### 3.2 Who sits where: the part's own state

The slot assignment lives on the part: `rec.st.crew = { [slot] = memberId }`. This is the
same mechanism `st.locker` and `st.hp` use, so it rides the fleet record
(`packRecord`), a docking (`dock_absorb` copies the record), an undock, a staging
split, a revert, and a reload, all with no extra code. The crew record's `status =
"aboard"` is a cache for menus. On scene start, `crew.lua` reconciles each record
against the live and fleet part states, and the part state wins.

The vessel_controller API (globals, the 60-upvalue rule):

```lua
seatsOf()               --> { { uid, slot, open, taken = id|nil, x,y,z } … }   every slot aboard
crewIds()               --> { id, … }                                         everyone aboard, slot order
seatMember(uid, slot, id_or_nil) --> ok, why                                   write st.crew (board/EVA/move)
hatchWorld(uid)         --> wx,wy,wz, nx,ny,nz | nil                           the hatch now (lateUpdate-safe)
commander()             --> id | nil       the member at the controls (§3.3); nil = nobody at a command part
```

`crewAboard` stays as a published boolean (`#crewIds() > 0`), so everything that
reads it today keeps working. `podCrewed` stays the "can carry crew" flag.

### 3.3 Flying with several crew

- **A craft answers the controls when** at least one member sits in a `command` slot
  (pod, seat, cockpit), **or** its probe core has power and a link (unchanged).
  Passengers in a cabin don't count. `controlState().why` gains "NO CREW AT THE
  CONTROLS".
- **The commander** is the member the controller treats as the pilot. That is the one
  in the highest-ranked command slot (today's pod-over-seat ranking, then lowest
  slot). There are no gameplay differences yet; it decides who **F** sends out (§4.3)
  and whose portrait is drawn first.
- **Crew in another craft** keep riding it. Switching control never moves anyone
  (as `remoteControl` does today).
- **The last member leaves.** The craft is a parked craft:
  - EVA is only offered when the craft is landed or splashed and slower than 1 m/s
    (there is no space EVA pack yet; it is a future item, §5.1);
  - the throttle is cut; control goes to the member who left;
  - the craft is a fleet record you can board again, and if it has a probe core and
    a link, `` ` `` flies it back.

### 3.4 Crew aboard are dolls, not bodies

No member aboard has a rigid body. Each one is a **CrewDoll**: the suit model
(`AstroModel` rig), an animator, and no collider.

- **Placement.** Dolls are top-level nodes, placed every `lateUpdate` from the part's
  rendered pose plus the seat offset. This is the camera-pass rule that
  `command_seat.lua` already follows. They are not children of the assembly, so no
  part scan ever sees them.
- **Pose.** Hips at the seat, the legs folded by `anim:reach` onto the footrest, and
  hands on the armrests. This is `command_seat`'s IK, generalised from "the
  astronaut" to "doll k".
- **Layer.** In a pod, cabin or cockpit, a doll is on the new **`interior`** layer:
  - the main camera does not draw `interior`;
  - the crew cams (§4.4) draw only `interior`;
  - V (the pilot's seat view) adds `interior` to the main camera's mask, so the seat
    view becomes a real IVA with the crew beside you.
- **Open seats.** A doll in an open seat (Command Seat) is on the default layer and
  is visible in the world. `command_seat.lua` poses dolls instead of the astronaut,
  so a rover with two seats shows two riders.
- **The hidden avatar.** When the controlled member is aboard, the `Astronaut` node
  keeps today's role: hidden, riding the active craft through `seatCrew`. This keeps
  objectives, residency and camera code unchanged. It is *unbound* (§4.1).

### 3.5 Boarding and the hatch

- **EVA** puts the member out at the hatch:
  1. Try `hatchWorld(uid)` + 0.9 m along the hatch normal, then 0.4 m up.
  2. Then fall back to today's `exitSpot` search (a clear capsule-sized spot around
     the hull).
  3. An open seat uses `exitSpot` from the seat.
- **Boarding (F on foot)** goes into the **nearest free slot** of the nearest crewed
  part within `board_range`. For pods this is measured to the hatch (not the spine);
  climbing the ladder still counts through today's spine rule.
- The prompt names the target: "F — board Pod Mk2 (2 free)", "F — sit in the seat",
  or "Pod Mk1 is full".

## 4. Control switching (C)

### 4.1 One avatar, many crew: how the `Astronaut` node is reused

- **The avatar.** The `Astronaut` node is always *the crew member you control on
  foot*. `crew.active` names them.
- **Idle crew.** Every other on-foot member in physics range is a **CrewBody**: the
  same capsule and suit as the astronaut, with a `crew_body.lua` script. That script
  stands, aligns to gravity, breathes (planet_walker's breath rule) and runs a task
  (§6.3). It takes no input.
- **Out of range.** Members further than 2.5 km from the camera's focus are records
  only. They are respawned as CrewBody nodes, parented to their planet, when the
  focus comes within 2 km. This is the fleet's rebuild pattern.

**Taking control of on-foot member B** (`crew.control(B)`):

1. If the avatar is bound to member A, spawn a CrewBody for A at the avatar's pose
   (position, velocity, facing, helmet, hand), and write A's suit state (o2, hand,
   helmet) into A's record.
2. Teleport the `Astronaut` node to B's CrewBody pose, despawn that CrewBody, and
   load B's suit state into planet_walker, tool_belt and the suit.
3. Drop anything the gravity gun was holding. Set `crew.active = B`.
4. planet_camera blends from the old pivot to the new one over 0.35 s. For a
   distance under 60 m this is a swept move; past that it is a 0.2 s fade.

**EVA of member X from the active craft:**

- If the avatar is unbound (hidden in the seat), it becomes X at the hatch.
- If the avatar is bound to Y on foot elsewhere, Y gets a CrewBody first, as in step 1.

**Shift+EVA** puts X out as a CrewBody beside the hatch and leaves you flying the craft.

**Boarding:**

- The avatar boards → its member becomes a doll. The node goes hidden and unbound
  (`crew.active = false`), and you control the craft (today's behaviour).
- An idle CrewBody boards (from its own context menu: "Board <craft>") → the body
  despawns into a doll, and control is unchanged.

None of the 35 `find("Astronaut")` callers change. Callers that need to know *who*
ask `crew.activeId()`.

### 4.2 What is switchable

The **switch list** contains:

- the craft you are near or flying;
- every crewed or probe craft within `vessel_switcher.range` (today's rule);
- **each on-foot member** within range, by name.

Crew aboard are reached through their craft's portraits, not the list.

### 4.3 Controls

| Key / action | Does |
|---|---|
| `[` / `]` | Step through the switch list (today's key, now per crew member). The caption names the target: "Dana Okafor · on foot" or "Kestrel I · 3 aboard". |
| `` ` `` (backquote) | **Quick swap**: back to whatever you controlled before (craft ⇄ last crew member). The fastest loop for "EVA, fix, back to the craft". |
| `F` (flying) | EVA **the commander** (today's single-crew F, unchanged in feel). |
| `F` (on foot) | Board the nearest free slot (§3.5). |
| Portrait hover → **EVA** | That member steps out of their part's hatch, and you control them. Shift-click: they step out and you stay on the craft. Greyed with the reason when not allowed: "moving 12 m/s", "in orbit: no EVA pack", "no hatch on a cabin buried in the stack". |
| Portrait hover → **⇄** | Move to another free slot aboard (an IVA transfer). |
| Portrait right-click | The context menu for that member: helmet, pack, hand. The same `astro` provider, now with the member as its target. |
| On-foot chip → **CONTROL** | `crew.control(id)`. A click on the chip does the same. |
| `\` | Crew strip size: small → large → hidden. Saved in `opt_crewStrip`. |
| Tracking Station ▸ crew row ▸ **GO TO** | Take control of an on-foot member out of range: the loading curtain, the same path as the game's scene restore. |

The pause menu's key list gets these rows. Digits stay action groups in flight and the
tool belt on foot. No modifier+digit chords are used, because Ctrl is held for
throttle.

### 4.4 The crew strip and crew cams

**Layout** (1280 × 720 design units, bottom-left; the Flight Ops card moves up above it
when both show):

```
                                                      ┌──────────────────────────┐
                                                      │  (stage stack, unchanged) │
┌─[ CREW · Kestrel I · 3/3 ]─────────────────────────┐ └──────────────────────────┘
│┌──────────┐┌──────────┐┌──────────┐                │
││ live cam ││ live cam ││ live cam │  ◂ ▸ (page)    │   portrait 128 × 96, gap 6
││  (face)  ││          ││          │                │   name plate 128 × 18 under it
│└──────────┘└──────────┘└──────────┘                │   hover: [EVA] [⇄] on the plate
│ D.OKAFOR ★  J.REYES     M.HALE                     │   ★ = commander, ● O2/hp chip
├─ ON FOOT ──────────────────────────────────────────┤
│ [▣ T.VANCE 42 m]  [▣ R.ITO 310 m]   (chips: CONTROL)│   chips only, no live cam
└────────────────────────────────────────────────────┘
```

- **Live portraits:**
  - drawn only for **crew aboard the craft you control**, at most **4 per page**;
  - each portrait is a UI image wearing `rt:crew<k>`;
  - its camera is a top-level node set in `lateUpdate` 0.55 m in front of the doll's
    face, looking back at it, `fovY 0.9`. The view is head and shoulders against the
    interior behind (the IVA model).
- **On foot** (the avatar's own portrait, plus a "◂ Kestrel I" chip to take the craft
  back): live cams aren't needed and aren't drawn.
- **Large mode** (`\`) doubles the portraits to 256 × 192 and the target to 384 × 288.
- **Budget:**
  - **4 live targets** (the engine allows 8 per scene; this upgrade uses 4 and
    leaves 4 for others);
  - 192 × 144 px each;
  - **8 Hz** each, staggered (`hz` set so no two redraw on the same frame); the
    hovered portrait gets 15 Hz;
  - `cullMask = interior` only: a pod interior and up to 4 dolls, a few thousand
    triangles each.
- **The targets switch off** (`hz` very low, and camera inactive where the engine
  allows it) while the strip is hidden, the map is open, the builder is up, or the
  game is in cinematic mode.
- **Acceptance:** the strip costs **≤ 0.6 ms** of GPU at 1080p on the bench's `plane`
  mode, measured with `perf.cost('render')` with the strip on and off. If a narrow
  `cullMask` target still pays for sky, terrain, shadows or volumetric fog, that is
  engine card H1, and the fallback until it lands is 4 Hz.
- **Open seats** (a rover rider) show the world behind them, so their camera needs
  world layers. Only the **hovered** open-seat portrait renders live (4 Hz); the
  others show their last picture. A target keeps its last frame, so this costs
  nothing.

**IVA interiors.** One prefab per crewed part, all on the `interior` layer: `IvaPodMk1`,
`IvaPodMk2`, `IvaCabin` and `IvaCockpit`. They are generated in Blender by
`tools/gen_iva.py`: padded walls, a panel with lit gauges, a window frame, and
`Seat1..N` empties that match `REG.seats`. Interiors are spawned only for the craft you
control, beside its dolls, in the same `lateUpdate` placement.

## 5. Physical items (D)

### 5.1 One item model: `items.lua` (a pure rulebook, loads in luajit)

`inventory.GEAR` becomes `items.ITEMS`. `inventory.GEAR` stays as an alias table for one
release.

```lua
ITEMS = {
  gravgun   = { name = "Gravity Gun",   kind = "tool",       kg = 7.0, L = 14, cost = 600,  shop = true,
                hold = { prefab = "ToolGravGun", fp = "ToolGravGunFP", grip = "two" }, issue = true },
  laser     = { name = "Terrain Laser", kind = "tool",       kg = 9.0, L = 16, cost = 900,  shop = true,
                hold = { prefab = "ToolLaser",   fp = "ToolLaserFP",   grip = "two" }, issue = true },
  repairkit = { name = "Repair Kit",    kind = "consumable", kg = 4.0, L = 6,  cost = 120,  shop = true,
                hold = { prefab = "ItemRepairKit", grip = "left" },
                use = { target = "part", provider = "repair" } },                  -- §6
  beacon    = { name = "Relay Beacon",  kind = "deployable", kg = 6.0, L = 18, cost = 80,   shop = true,
                hold = { prefab = "ItemBeaconStowed", grip = "shoulder" },
                deploy = { store = "comms", ghost = "RelayBeaconGhost", bad = "RelayBeaconGhostBad",
                           slope = 0.74, spacing = 4.0, pick = 3.5 } },
  flag      = { name = "Company Flag",  kind = "deployable", kg = 3.0, L = 12, cost = 50,   shop = true,
                hold = { prefab = "ItemFlagFurled", grip = "shoulder" },
                deploy = { store = "deployables", kind = "flag", ghost = "FlagGhost", bad = "FlagGhostBad",
                           slope = 0.6, spacing = 2.0, pick = 2.0, secs = 2.5 } },
}
-- later, same shape: evapack (space EVA), sampler, drill, welder, spare parts, food/O2 canisters.
```

**Tools are items.** The gun and the laser:

- have mass and can be left in a locker to save weight;
- are bought and replaced like anything else;
- come with the standard **issue** to every hire (`issue = true`).

To keep today's mining balance exact, `suit_kg` goes from 90 to **106** (90 + 7 + 9).
An old save's crew #1 is issued both tools during migration, so nothing changes for
the player on day one.

**Bulk.** `L` (litres) is a second limit that applies to *items only*. Materials stay
mass-only, as today. Capacities: pack 60 L, locker 120 L, hold 1000 L per Cargo Bay,
base unlimited. The reason for a second number: without it a pack fits nine beacons
(54 kg) and a 2.4 m flag pole, which reads wrong.

### 5.2 Where items live (containers) and the `"astro"` alias

| Container | Id | Capacity | Notes |
|---|---|---|---|
| A crew member's pack | `crew:<id>` | 106 kg, 60 L | The hotbar is built from it. |
| Stowage locker part | `locker:<n>` | `store` kg (80), 120 L | From the context-menu work, on `st.locker`. Mass sits on that part. |
| Cargo hold | `hold:<ship>` | Cargo Bays | Unchanged. |
| Base warehouse = **VAB stock** | `base` | unlimited | The depot BUY counter and the VAB buy into it. |
| Salvage crate | `salvage:<id>` | — | A drowned pack's items go here too. |
| The world | deployed records | — | `comms.beacon.<id>` and `dep.<id>` (§5.5). |

`inventory.resolve(cid)` maps `"astro"` → `"crew:" .. crew.activeId()`. When the avatar
is unbound, it maps to the commander of the active craft, so a pod's E-to-load-cargo
still finds a pack. Every public inventory function resolves first. This one rule keeps
all of today's callers correct.

Item API (inventory.lua), with the counts living in today's `inv.gear.<cid>` bags:

```lua
itemCount(cid, id)            addItem(cid, id, n) --> n_in, why     removeItem(cid, id, n) --> n_out
moveItem(from, to, id, n)     --> n_moved, why ("no room: 4 kg free", "no room: 2 L free", "a tool can't go in a crate")
itemList(cid)                 --> { { id, name, n, kg, L, kind } … }  (gearItems stays as an alias)
volume(cid), volCap(cid), roomForItem(cid, id)
buyItem(cid, id, n)           --> ok, why   (company.spend; all or nothing)
```

### 5.3 How items move

- **VAB** (§5.6): drag between the base stock, crew packs, and the craft's lockers.
- **In the field**, through the right-click menu of a locker or hold:
  - **Take ▸ <item>** and **Put ▸ <item>** (one) or **Take all**;
  - you must be on foot within reach, or aboard that craft;
  - the context-menu work already moves *gear* between a locker and `astro`; it becomes
    `moveItem`, and the row says why when it can't.
- **Hand to hand** (later): the right-click menu on another member's CrewBody gives
  "Give ▸ <item>". Its provider is the same pattern.
- **Depot BUY counter**: buys into the pack of the member standing at the counter.
  This keeps today's tactile buy.

### 5.4 Holding: one hand slot per crew member

- **The belt is the pack's holdables:**
  - tools first, then devices and deployables, then consumables with a `hold`;
  - number keys pick by position, as today;
  - the selected id is the record's `hand`.
- **One thing in the hands at a time.** Picking the repair kit puts the gun on the
  back. tool_belt already animates swaps ("the old tool dips out, the new one comes
  up").
- **`hold.grip`** decides the IK, using tool_belt's existing hand anchors:
  - `two`: the gun and the laser, as today;
  - `left`: a kit carried by its handle, right hand free;
  - `shoulder`: a beacon or furled flag over the right shoulder.
- **Empty hands** (H, or picking the selected slot again) put everything away. Running
  with empty hands is how you'd walk a long way.
- tool_belt publishes `held()` → id and `hold(id)` → ok, why, which the strip, the
  menus and probes use.

### 5.5 Deploying (beacon, flag, and anything later)

tool_belt gets one generic **deploy mode**, active whenever the item in hand has a
`deploy` field. It replaces `fire_beacon` and keeps its ghost, ring and link-preview
code for the beacon.

1. **The aim.** The laser's ray picks the ground, and the item's ghost prefab follows
   it, snapped to the ground and upright along local up. It is teal when it can stand
   and red with the reason when it can't (too steep `slope`, within `spacing` of
   another, under water, not on a world). The beacon keeps its relay-link preview.
2. **LMB places it.** The crew member performs a `secs` plant animation: the flag is
   driven in, and the beacon is set down. Then the store's place function runs:
   - `comms.placeBeacon(body, gx,gy,gz)` for `store = "comms"` (unchanged API and save
     keys, so the relay network and old saves are untouched);
   - `deployables.place(kind, body, gx,gy,gz, { by = id, yaw })` for everything else.
3. **The item leaves the pack** only when the place call returns an id, as today.
4. **Pick up** is a right-click on the deployed object → **Pick up** (needs reach and
   pack room). Q-to-pick-up is removed because Q is the laser's mode key, and the
   context menu is the general verb. The gravity gun's "pull a beacon up" stays.

`deployables.lua` is a manager on the `CommsLib`-style `DeployLib` node:

- **Records.** `dep.list` (the ids) and `dep.<id>` = `{ k = "flag", b = body, x,y,z
  (body-relative ground), yaw, by = memberId, n = name, st = space.time(), d = "Day 41
  Y2", photo = "user://flags/<slot>/<id>.png" }`.
- **Nodes.** Spawned parented to their planet, only for the dominant body's records
  plus anything within 20 km of the focus.
- **Revert.** `snapshot()` / `restore(snap)`, as comms does for beacons.

### 5.6 The VAB crew tab

The builder's right plate gets a fifth tab, **CREW**, after CRAFT. It is
`builder_crew.lua`, registered through `registerPanel`.

```
┌ CREW ─────────────────────────────┐
│ SEATS                     [AUTO]  │  one box per slot of every crewed part, in stack order:
│ Pod Mk2  [D.OKAFOR★][J.REYES][   ]│  drag a roster card in or out; ★ = commander
│ Seat     [   ]                    │
│───────────────────────────────────│
│ ROSTER (at base)                  │  cards: name, role; greyed if aboard elsewhere/away
│ [M.HALE] [R.ITO] [+ HIRE…]        │
│───────────────────────────────────│
│ LOADOUT ▾ D.OKAFOR  38/106 kg 22/60 L │  click a seat card to pick whose pack is shown
│ ▣ Gravity Gun  ▣ Terrain Laser    │  drag items between the pack, a locker and stock
│ ▣ Repair Kit ×2                   │
│ LOCKER  #1 (Pod Mk2)  12/80 kg    │  one row per locker part on the craft
│ ▣ Relay Beacon ×3  ▣ Flag         │
│ STOCK (base)              [BUY ▸] │  the warehouse's items; BUY opens the depot list
│ ▣ Repair Kit ×4  ▣ Beacon ×6      │
└───────────────────────────────────┘
```

- **Default.** When the craft is first given a crewed part, the active (or most recent)
  member is put in the commander slot. Building and launching therefore puts you in
  the pod exactly as today.
- **Drag and drop** uses `ui.dragging`/`ui.dropTarget`. Packs are moved immediately,
  since they are real containers. Lockers don't exist until launch, so the tab writes a
  **locker plan** `shipyard.lockerPlan = { [uid] = { id = n } }`. vessel_spawner applies
  it right after `lockerRegister()` assigns `st.locker`, moving the items from `base`.
  Anything the base is short of is bought at launch and itemised on the launch cost.
- **The seat plan** is `shipyard.crew = { [uid] = { [slot] = id } }`. Builder checks:
  - crewed command parts with nobody at the controls and no probe core → **block**:
    "nobody can fly it: put someone in the Pod Mk2";
  - a crew member planned on two craft → refused at drop;
  - **warn** if nobody carries a repair kit on a craft with more than 30 parts (a
    nudge, not a rule).
- **At launch**, vessel_spawner writes `st.crew` from the plan into the blueprint's part
  states, before the controller loads it. The crew records go to `aboard`. If the
  avatar is in the plan, it boards as today. If not, it stays on foot at the VAB door
  and the camera follows the craft (you control the craft).

## 6. Repair as a task (E)

### 6.1 The flow

1. **Get a kit.** It was put in the pack in the VAB, or taken from a locker
   (right-click the locker → Take ▸ Repair Kit).
2. **EVA** (portrait hover → EVA, or F). The craft must be landed or splashed and still
   (§3.3).
3. **Hold the kit** (its belt slot). It hangs from the left hand.
4. **Walk to the damaged part.** Damaged parts show their wear already (the hull
   `damage` uniform). While a kit is in hand, the hovered part's outline is tinted by
   its health.
5. **Right-click it → Repair (~14 s)**. The row shows the part's health and the time.
6. **The work.** The crew member faces the part and kneels or leans:
   - both hands reach (`anim:reach`) to the right-clicked **hit point**, stored in the
     part's local frame and converted each frame (the moving-planet rule);
   - the kit is set down at their feet as a prop;
   - a spark and weld puff (the laser's `FxCutBite`, tinted) plays at the hands, with a
     ratchet loop sound;
   - a progress ring is drawn over the part, and the menu's job bar fills.
7. **Done.** `vessel_controller.repairPart(uid, 1.0)` runs. The kit is consumed (removed
   from the pack), the wear paint clears, and a caption reads "Pod Mk2 repaired —
   100%".

### 6.2 Rules

| Rule | Value |
|---|---|
| Who | A crew member **on foot**, with a Repair Kit **in hand**. No repairs from the seat: the point is the trip. |
| Which parts | `0 < hp < 0.999`. A broken part (hp 0, gone from the craft) is wreckage: "beyond a field repair" (`repairPart`'s rule). |
| Reach | `reach (2.6 m) + the part's half-size`, measured to the hit point (the context-menu `crewAccess` rule). |
| Duration | `secs = 6 + 16 × (1 − hp)`: a scuff is 7 s, a failing part 18 s. |
| Craft state | The part's craft moves under 0.5 m/s relative to the crew, and is not being flown with throttle > 0. |
| Interruptions (`check`) | Walked out of reach + 0.5 m; took fall or impact damage; out of air or under water; the kit left the hand; the part broke. The job **cancels**: progress is kept on the part for 120 s (`st.rprog`, so a step back and a re-click resumes), and the kit is not used. |
| Switching away | The job **keeps running**. It belongs to the crew member, not the menu (§6.3), so you can start one member repairing, switch to another, and come back. If the member's body leaves physics range, the job pauses and resumes when they're respawned. |
| Results | `repairPart` restores `hp`, repaints, and the joint strength (`joint_strength(d, hp)`) comes back, so the structure is stronger again. |

### 6.3 Tasks belong to crew members

`crew.setTask(id, task)` puts a job on a member, and `crew_task.lua` (a pure rulebook
with a tick) runs it. The record holds the task as plain data, so it is saved:

```lua
task = { kind = "repair", craft = <vessel key: fleet fid or node id>, uid = 12,
         lx = 0.21, ly = 0.40, lz = -0.48,      -- hit point in the part's frame
         secs = 14.2, done = 3.1, item = "repairkit" }
```

The avatar's task is driven by tool_belt and planet_walker:

- **Pose.** They stop walking input while it runs. WASD **cancels** the job, after a
  0.5 s grace with a "keep working? (WASD again to stop)" hint, so a nudge doesn't
  throw away a long weld.
- **Idle members.** A CrewBody's task is driven by `crew_body.lua`, with the same IK.
- **The menu.** The context-menu `job` entry calls `crew.setTask` and shows the task's
  progress while it is open. Closing the menu doesn't stop it.

### 6.4 The provider

The held item contributes the entry, which `context_registry` supports as is:

```lua
reg.register("part", function(t, ctx)                -- in context_providers.lua, id "held.repair", order 15
  local id = crew.activeId(); if not id or tool_belt.held() ~= "repairkit" then
    -- not in hand: one dimmed row when the part is damaged, so the verb is discoverable
    return damaged(t) and { { type="action", id="repair", label="Repair", enabled=false,
             why = hasKit(id) and "hold the Repair Kit (" .. slotKey("repairkit") .. ")"
                               or "needs a Repair Kit — lockers, or the VAB" } } or {}
  end
  return { { type="action", id="repair", group="SERVICE", label="Repair",
             hint = string.format("%.0f s", repairSecs(hp)),
             enabled = function() return repairWhyNot(ctx, t) == nil end,
             why = function() return repairWhyNot(ctx, t) end,
             act = function() return crew.setTask(id, repairTask(t)) end } }
end, { id = "held.repair", order = 15 })
```

Item defs name their provider (`use.provider`), so later tools (welder, sampler) add
verbs the same way, with no menu code changes.

## 7. Flags (F)

- **The texture.** `tools/base_tex.py` gains `flag()`: the agency emblem (the existing
  `emblem()` roundel) on a navy field with the agency's name. The output is
  `textures/base/flag.png` at 512 × 341. "The company logo" is this emblem. A custom
  name or emblem is Q3.
- **The model** (`tools/gen_flag.py`, Blender):
  - a 2.2 m pole with a ground spike;
  - a cloth quad of 1.2 × 0.8 m, subdivided 24 × 12, with its UV origin at the pole;
  - an **Apollo crossbar** on top, so on an airless world it hangs extended.
- **Waving** (`shaders/flag_cloth.flsl`, a surface shader with `output offset`):
  - the displacement grows with distance from the pole (`uv.x`);
  - it is a travelling wave `sin(k·uv.x − ω·time + noise)` plus fbm flutter;
  - it is driven by uniforms `windLocal` (vec3, in the flag's frame) and `windSpeed`;
  - amplitude and frequency both rise with speed (limp under 1 m/s, a straight snap at
    15+ m/s), and the cloth swings round the pole to lie downwind.
- **Wind updates.** `flag.lua`, on each flag node, samples `weather.windAt(pole top)` at
  4 Hz and eases toward it. It writes the two uniforms (`setShaderParam`). On an airless
  body (`weather.profile(body).airless`) wind is 0, and the shader's `still` = 1 holds
  the cloth flat on the crossbar with a tiny settle. Flags beyond 300 m from the camera
  stop sampling (`script.sleep`).
- **Planting** is deploy mode (§5.5) with `secs = 2.5`:
  1. the crew member grips the pole with both hands (IK), drives it in with two
     downward pulses, a dust puff, and a thud;
  2. they step back half a metre and salute (a `reach` to the brow) for 1.5 s;
  3. during the salute a **photo** is taken: `camera.capture` from a camera 4 m out
     at chest height, framing the crew member and the flag, 640 × 360 JPEG, written to
     `user://flags/<slot>/<id>.jpg`. The record keeps the path.
  The flag's name defaults to "<Body> · <date>" and can be renamed from its context
  menu.
- **Persistence.** `dep.<id>`, spawned parented to its planet (as beacons and salvage
  crates are).
- **Missions.** The `flag` goal kind ("stand on that body … plants the company beacon")
  becomes **"Plant a flag on X"**: it latches when `deployables` places a flag on X.
  For one release, contracts accepted before the change still latch on stepping out
  (the goal record carries `v = 1`). Objectives' hint becomes "Bring a Company Flag:
  VAB ▸ CREW ▸ loadout."
- **Tracking Station.** A **FLAGS** section, under RELAYS, built with the same row
  builder:
  - each row shows: name, body, in-game date, planted by (the member's name);
  - the detail shows the **photo** (`assets.textureFromBytes` on the saved file, cached
    per id), the body and coordinates, and the distance from home;
  - **VIEW** shows the photo full-panel;
  - **MAP** opens the orbit map on the body with a pin (orbit_map's existing marker
    path);
  - **REMOVE** asks twice and forgets the record (the flag node goes).
  - A live camera fly-to is not offered: it would stream another world in from a
    building at the base. The photo is the memento, and the map gives location.

## 8. Engine needs (H), each checked against the docs

| # | Need (general) | What the docs say exists | Ask |
|---|---|---|---|
| H1 | **Cheap picture-in-picture cameras**: a render-target camera that draws only its `cullMask` layers, with switches for shadows, volumetric fog, post-processing, sky and terrain, so a security monitor or portrait costs what it draws. | `setCamera{target,width,height,hz,cullMask}` (render-targets.md). The docs say a target is "a whole extra render of the scene" and list no per-camera pass switches. | **Card, after measuring.** WS2 measures 4 interior-only targets with `perf.cost('render')`. If the sky, terrain, shadow or fog passes run for them, file "per-camera render features for render targets". |
| H2 | **Targets nobody is looking at skip drawing**: a target whose `rt:` texture is on no visible UI image or drawn material is not rendered. | Not mentioned. A game can lower `hz` by hand (render-targets.md "Reading it back"). | Nice-to-have card. Solar does it by hand meanwhile. |
| H3 | **Shaders can read the wind field**: a built-in `wind` input (the value of `weather.windAt` at the node's origin) in surface shaders, so flags, banners, grass and cloth agree with particles without per-node script updates. | `weather.windAt` exists for scripts. Surface shaders support `output offset` (shaders.md §4.5, "a flag that ripples"). | Card (small, general). The workaround (4 Hz `setShaderParam` per flag) is fine for tens of flags. |
| H4 | **A small cloth primitive** (a pinned grid solved per frame, wind-driven, cheap), for flags, banners and canopies. | animation.md mentions a cloth canopy as a procedural rig posed through bones. No cloth solver. | **Not now.** The vertex-shader flag is enough. Revisit if banners or parachute cloth want collision. |
| H5 | **Picking under the cursor**. | `camera.screenToRay` + `raycast` with `layers`/`ignore` (lua-api). The context-menu work uses them. | None. |
| H6 | **Holding items in a character's hand**. | `anim:reach`/`lookAt`, `anim:boneWorld`. setParent mentions bone-pinned nodes. tool_belt already places tools per frame. | None. |
| H7 | **Drag and drop in UI**. | `ui.dragging`, `ui.dropTarget`, `ui.hovered`, hoverStart/End. | None. |
| H8 | **Visual (non-physical) children of an assembly part**: a mesh child with no collider under a vessel part does not join the compound and does not change its mass. | Not documented either way. | **Doc clarification card only if** WS1 finds a problem. The design sidesteps it: dolls are top-level and placed in lateUpdate. |
| H9 | **Photo to a file**. | `camera.capture` → bytes → `assets.writeBytes`; `assets.textureFromBytes` to show it. | None. |

## 9. Open questions for the user (genuine design choices)

1. **Permadeath.** Today crew survive a breakup and are rescued after running out of air.
   Should crew be able to **die** (a lost pod kills its crew, and drowning is final),
   either always or as a "hardcore crew" setting? The recommendation is a setting, off
   by default.
2. **Space EVA.** This design allows EVA only when landed or splashed (there is no
   jetpack yet), so in-orbit repairs wait for an **EVA pack** item. Is that right for
   this upgrade, or should the EVA pack come in now?
3. **The company identity.** The flag uses the existing agency roundel and an agency
   name. Should players **name the agency and pick or edit its emblem** (colours, a
   symbol) when they start a save?
4. **Hiring economy.** Is a one-time hire fee (≈ $1.5k–6k) enough, or should crew draw
   **wages**, which make a big roster a running cost?
5. **Crew traits.** Roles are stored but unused. Should roles matter in a follow-up?
   For example: engineers repair faster, and only pilots fly without a probe core
   (KSP's rule).

## 10. Workstreams (G)

There are four agents. Ownership is strict: a file is edited only by its owner, and a
change anyone else needs is a patch in `SCRATCH/<ws>/…patch` sent to the owner. Three
files are being edited by agents running now. Each passes to its new owner only after
that agent's work is committed:

- vessel_controller (the ctxmenu patch);
- vessel_spawner and build_host (the spawner agent);
- tool_belt and the tool models (the tools agent).

### WS1: Crew spine (model, seats, switching, flight). Starts first.

- **Owns:**
  - new `scripts/crew.lua` (pure rulebook + manager on a new `CrewLib` node), new
    `scripts/crew_body.lua`, new `scripts/crew_task.lua`;
  - new `prefabs/CrewBody`, `prefabs/CrewDoll`;
  - `scripts/vessel_controller.lua`, `command_seat.lua`, `flight_ops.lua`,
    `vessel_spawner.lua`, `vessel_switcher.lua`, `game_manager.lua`, `build_host.lua`;
  - `parts_registry.lua` + `parts_aero.lua` (seats, hatches, Pod Mk2, Crew Cabin
    definitions);
  - `planet_walker.lua`: suit-state load/save hooks. The suit agent's helmet code lands
    first; WS1 then owns the file.
  - tests: new `smoke_crew.lua`, `smoke_crew_migrate.lua`, `smoke_crew_seats.lua`;
    updates to `smoke_command_seat.lua`, `smoke_crew_stations.lua`, `smoke_revert.lua`,
    `smoke_fleet_readout.lua`.
- **Does:** §2 (records, hiring logic, migration), §3 (slots, `st.crew`, dolls placed and
  posed, hatches, boarding), §4.1–4.3 (avatar binding, `crew.control`, EVA,
  Shift-EVA, quick swap, the switch list), the revert keys (`crew.*`), the spawner's
  seat plan, and the locker plan at launch.
- **Publishes** (the interface every other workstream codes against, stubbed on day 0):

```lua
-- crew.lua
roster() -> {rec…}; get(id) -> rec; activeId() -> id|nil; packOf(id) -> "crew:"..id
where(id) -> status, detail; hire(i) -> id|nil, why; offers() -> {{name, cost}…}; rename(id, s)
control(id) -> ok, why; eva(id, {stay=bool}) -> ok, why; board(id, v, uid?, slot?) -> ok, why
quickSwap() -> ok; switchList() -> {{kind="crew"|"vessel", id|v, name, dist}…}
aboard(v) -> {{id, uid, slot, commander=bool}…}; dollOf(id) -> node|nil; bodyOf(id) -> node|nil
setTask(id, task) -> ok, why; task(id) -> task|nil; cancelTask(id, why)
version  -- bumps on any change (panels poll it)
-- vessel_controller: seatsOf(), crewIds(), seatMember(uid, slot, id), hatchWorld(uid), commander()
```

- **Acceptance:**
  - **luajit:** `smoke_crew_migrate` takes a fixture of an old save's keys (pack, gear,
    fleet with crew = true) and checks that it yields member #1 aboard the station part
    with their pack moved and `"astro"` resolving to `crew:1`; that running it twice is
    a no-op; and that a new save gets member #1 directly.
  - **luajit:** `smoke_crew_seats`: a Pod Mk2 + Seat blueprint gives 4 slots; seat
    plans survive `packRecord` → fleet record → reload; and docking merges `st.crew`.
  - **In-engine probe** (`tools/perf/crewprobe.lua`): launch a Pod Mk2 with 3 crew,
    land, EVA #2 (they appear at the hatch, clear of the hull, under 0.3 m/s); quick
    swap ×10 (each switch < 1 frame of input dead time, and the camera blend completes);
    `[`/`]` reaches all 3; reboard; recover. All 3 are back at base with packs intact.
    Shots go to `SCRATCH/ws1/`. The luajit sweep and `floptle check` (0 errors, 6
    warnings) pass.

### WS2: Crew presentation (strip, cams, IVA, VAB tab, roster panel, scene files)

- **Owns:**
  - new `scripts/crew_strip.lua`, `scripts/builder_crew.lua`,
    `scripts/crew_roster_panel.lua`;
  - new `tools/gen_iva.py`, `models/iva/*`, `prefabs/Iva*`;
  - the crew-cam camera nodes;
  - `planet_camera.lua` (the switch blend; the `interior` mask on V);
  - `builder_inspector.lua` (the CREW tab), `facility_menu.lua` (the CREW button),
    `pause_menu.lua` (key rows);
  - **the scene files for this upgrade** (`scenes/system.ron`, `scenes/builder.ron` and
    the generated overlay via `tools/gen_builder_overlay.lua`) and the new `interior`
    layer in `project.ron`. Other workstreams send node additions as patches.
  - tests: new `smoke_crew_strip.lua` and `smoke_builder_crew.lua`.
- **Does:** §4.4 and §5.6, the hire panel UI on WS1's `hire`/`offers`, and the strip's
  budget measurement (H1).
- **Depends on** WS1's stubbed API (day 0). It can build against a fake roster table
  until WS1 lands.
- **Acceptance:**
  - **luajit:** strip layout for 1, 3 and 7 crew (paging); the crew tab's drag rules
    (no double booking, a block without anyone at the controls).
  - **In-engine:** a shot of 3 portraits with the IVA visible and faces lit; hover
    reveals EVA and ⇄; `perf.cost('render')` with the strip on and off is ≤ 0.6 ms on
    `bench.sh … plane` (record `uptime`); V shows the IVA with the crew dolls; the VAB
    tab assigns 2 crew and a locker plan, and the launch seats them.

### WS3: Items, hands and tasks

- **Owns:**
  - new `scripts/items.lua`;
  - `inventory.lua`, `inventory_panel.lua`, `tool_belt.lua` (after the tools agent
    lands), `salvage.lua`;
  - `context_providers.lua` (after the ctxmenu agent lands): locker take/put by item,
    `held.repair`, the deployable "Pick up", and the "Give" stub;
  - new prefabs `ItemRepairKit`, `ItemBeaconStowed`, `ItemFlagFurled`;
  - tests: new `smoke_items.lua` and `smoke_repair.lua`; updates to
    `smoke_inventory.lua`, `smoke_relay.lua`, `smoke_toolgate.lua`,
    `smoke_gravgun.lua`, `smoke_revert_beacons.lua`.
- **Does:** §5.1–5.5 (the registry, the alias, bulk, hand slot and grips, the generic
  deploy mode with the beacon moved onto it and comms untouched) and §6 (the repair
  job, IK, effects, interruption rules, consumption), with the avatar's task driving in
  tool_belt.
- **Interface to WS4:** `items.ITEMS.flag.deploy.store = "deployables"`. Deploy mode
  calls `deployables.place(kind, body, gx,gy,gz, {by, yaw}) → id` and `deployables.near(x,y,z,r)`.
  The plant animation hook is `tool_belt.plantAnim(secs, kind)`.
- **Acceptance:**
  - **luajit:** `smoke_items`: mass and litre limits with honest partial moves; `astro`
    alias resolution; `moveItem` refusals with reasons; old `inv.gear.astro` beacons
    readable after migration.
  - **luajit:** `smoke_repair`: duration formula; `check` cancels at reach + 0.5 m; the
    kit is consumed only on `done`; resume within 120 s.
  - **In-engine probe:**
    1. wear a pod part to 0.4 (`wearPart`);
    2. EVA, take a kit from the locker through the menu, hold it, right-click → Repair;
    3. the hands land on the hit point (shot); 13–14 s later hp is 1.0 and the kit
       count went down by 1;
    4. walking away mid-job cancels it.
    5. Separately, plant and pick up a beacon by the new path. The relay solve and
       `comms.beacons` are unchanged, and an old save with planted beacons and 2
       carried ones loads them all.

### WS4: Flags, deployables store, Tracking Station

- **Owns:**
  - new `scripts/deployables.lua`, `scripts/flag.lua`, `shaders/flag_cloth.flsl`;
  - new `tools/gen_flag.py`; the `flag()` addition to `tools/base_tex.py`;
  - new `prefabs/Flag`, `FlagGhost`, `FlagGhostBad`, `DeployLib`;
  - `tracking_station.lua` (FLAGS, plus a CREW section listing the roster with
    GO TO/Recall on WS1's API);
  - `objectives.lua`, `missions.lua` (the flag goal);
  - tests: new `smoke_flags.lua`; updates to `smoke_tracking.lua` and
    `smoke_objectives.lua`.
- **Does:** §5.5's store, all of §7, and `dep.*` in the revert snapshot (a patch to
  WS1's vessel_spawner).
- **Acceptance:**
  - **luajit:** place, list, near and remove; snapshot and restore; the flag goal
    latches on a placed flag and old contracts still latch on stepping out.
  - **In-engine:**
    - plant a flag at the home meadow: the shot shows cloth motion between two frames
      0.5 s apart (pixel diff), and it faces downwind;
    - on an airless moon the cloth is static on its crossbar;
    - the Tracking Station row shows the photo;
    - reload, and the flag is still there.

### Order and the first playable slice

- **Day 0 (both together, ~2 h):** WS1 commits a stub of `crew.lua` that returns member
  #1 and the `activeId` alias. WS3 commits `items.lua` and the inventory alias. Every
  other workstream codes against these from then on.
- **Slice 1, "tactile items"** (WS3 + WS4 on top of the stubs; the user can play this
  first). On today's single astronaut (member #1):
  - the repair kit;
  - lockers with take/put;
  - the relay beacon as a held, deployable item;
  - the waving company flag with its photo and the Tracking Station list;
  - VAB loadout for the one astronaut, as a minimal version of the CREW tab with
    loadout only.
- **Slice 2, "the crew"** (WS1 + WS2):
  - roster and hiring;
  - Pod Mk2 and the Crew Cabin;
  - seat assignment in the VAB;
  - EVA, boarding and switching;
  - the crew strip with live IVA portraits.
- **Slice 3 polish:** the "Give" hand-to-hand provider; tasks continuing out of range;
  the Tracking Station GO TO.

The merge order follows the in-flight agents: ctxmenu → WS3 takes `context_providers`;
spawner → WS1 takes `vessel_spawner`/`build_host`; tools → WS3 takes `tool_belt`; suit →
WS1 takes `planet_walker`. Each workstream ends with the luajit sweep from the Floptle
root and `floptle check` at the 6-warning baseline, as `agent_rules.md` requires.
