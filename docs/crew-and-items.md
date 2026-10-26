# Crew and items: the agency, its astronauts, and the things they carry

Design for the crew-and-items upgrade, 2026-10-25. Engine: Floptle 0.117.0-rc27.
Status: decision-ready. Each section recommends one way to build it. The user has
answered every open question; §9 records the answers.

## 0. Summary

The player is the **agency**, not one astronaut. The agency has a **name and an
emblem** (generated from the name, tweakable, or the player's own image), and they
appear on flags, crewed parts, suits and the HUD. A new save starts with **three free
astronauts**. More are hired for a one-time fee, with no wages. **Astronauts can die**:
from a destroyed cabin, oxygen, drowning, a fatal impact, crushing, or re-entry heat.
Every cause is telegraphed with warnings and a short grace. The pack drops as a
recoverable crate, the remains stay where they fell, and the roster keeps a memorial.
A "rescue instead" switch exists for players who want a pure sandbox.

The agency hires a **roster** of crew.
Any crewed part seats as many crew as it has **slots**. You control one thing at a
time: **a craft**, or **one crew member on foot**. A **crew strip** of live portraits in
the bottom-left corner shows the crew aboard the craft you are flying. Hover a
portrait and **EVA** sends that crew member out of the part's hatch. Every on-foot crew
member nearby is one click, `[`/`]`, or `` ` `` away.

Everything a crew member uses is a physical **item** with mass and bulk: the Gravity
Gun, the Terrain Laser, the **Repair Kit**, the **Relay Beacon**, the
**Company Flag**, and the **RCS Pack**. The RCS Pack works from the inventory: carrying
it lets a crew member fly on EVA in space with RCS thrusters. Items sit in a crew member's pack, a **stowage locker** part, a
craft's hold, or the base warehouse. In the VAB you hand items to crew or load them
into lockers. In the field you take them out of a locker through the right-click
menu, hold one in your hand, and use it.

A repair means going to the broken part with a kit in hand: walking on the ground, or
flying the RCS Pack to a damaged station in orbit. You right-click the part and choose
**Repair**. The crew member is then **held at the part** in a looping work animation,
locked in the part's own frame, so they ride a tumbling or orbiting station and can't
drift away. A progress bar fills. Movement keys don't stop the job; only an explicit
right-click → **Cancel repair** does. Deployables (beacon, flag) are placed from the
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
{ id = 3, name = "Dana Okafor", hired = <space.time()>, cost = 2400, starter = false,
  status = "afoot",          -- "base" | "aboard" | "afoot" | "dead"
  -- where (status decides which fields mean anything):
  craft = "Kestrel I",       -- aboard: display only (the truth is the part's st.crew, §3.2)
  body = "Vever", x = .., y = .., z = .., yaw = ..,   -- afoot: body-relative, like salvage/beacons
  -- the suit and the body:
  o2 = 1.0,                  -- the suit's own supply, 0..1 (§2.3)
  breath = 1.0,              -- held breath under water / helmet off in bad air, 0..1
  hp = 1.0,                  -- injuries, 0..1 (heals 0.02/min aboard or at base)
  heat = 0.0,                -- exposure to re-entry heating, 0..1
  helmet = true, rcs = 4.0,  -- helmet state; RCS Pack fill while carried (§5.7)
  hand = "repairkit",        -- the item in hand (nil = empty hands)
  task = nil,                -- a running job (§6.3), or nil
  flights = 4, eva_s = 1830, flags = 1, repairs = 2,  -- service record, for the roster panel
  -- once dead (§2.3):
  died = nil,                -- { st = space.time(), date = "Day 41 Y2", cause = "impact", body = "Nami",
                             --   x,y,z = body-relative, craft = "Kestrel I" | nil, remains = <dep id> }
}
```

**Roles and traits are not in this upgrade.** There is no `role` field until the
base crew system works. See §9, "Later".

Other keys:

- `crew.roster`: the id list in hire order, including the dead (the memorial reads it).
- `crew.seq`: the last id issued.
- `crew.active`: the id the `Astronaut` node is now, or `false` when it is unbound (§4.1).
- `crew.offers`: the three applicants on the board.
- `crew.version`: the migration stamp (`1`).
- `crew.death`: `true` by default; the forgiving option (§2.3).

Each crew member's pack is an ordinary inventory container, **`crew:<id>`**. Its
capacity rule is the suit's: `cap("crew:*") = suit_kg`.

### 2.2 Starting crew and hiring

**A new save starts with three free starter astronauts** (`starter = true`, cost 0).
Their names are generated from `g_seed`. Each gets the standard issue (§5.1).
Member #1 is put on foot at the colony as the avatar; the other two wait at base.

**Hiring.** The Command Centre gets a **CREW** button next to its Overview button. It
opens the **Astronaut Complex** panel (`crew_roster_panel.lua`):

- **Roster.** Each living member gets a row: name, status, where, and service record.
  The actions are:
  - **Rename**;
  - **Go to**: switch to an on-foot member in physics range (§4);
  - **Recall**: brings an on-foot member home for the pickup fee
    (`flight_ops.pickupFee`).
- **Applicants.** Three names, each deterministic from `g_seed` and `crew.seq`.
  - A **one-time hire fee** of `1500 + 600 × (living roster − 3)`, capped at 6000. So
    the fourth astronaut costs $1,500.
  - **No wages.** A crew member costs nothing after hiring.
  - Hiring spends through `company.spend`.
  - A hired member starts at base (`status = "base"`) with the standard issue, taken
    from the base warehouse or bought if the warehouse is short.
- **The free newbie.** When **every astronaut is dead**, the first applicant on the
  board is marked **FREE** ("a volunteer, $0") until hired.
  - The game also never leaves you with nobody to control. At the moment the last
    member dies, that free newbie is hired automatically.
  - They walk out of the Command Centre as the avatar, with the caption "The agency
    has a new volunteer: <name>".
  - Their issue kit is free as well, so a broke agency can still get back in the game.

A crew member at base has no body. They are "in the building". The game always has
someone to control on foot (§4.1).

### 2.3 Death: real, telegraphed, and fair

**Astronauts can die. This is on by default.** Every cause below has a visible warning
before it, a short grace in which the player can act, and a cause written on the
memorial. The thresholds are chosen so that ordinary play (a firm chute landing, a
jump off a ledge, a swim) never kills anyone.

**The causes:**

| Cause | Kills when | The warning before it | The grace |
|---|---|---|---|
| **Crew part destroyed** | The part a member sits in breaks (hp 0) or the craft is lost with them in it. Members in *other* parts that survive the breakup are set down beside the wreck alive, as today. | The part's health on the crew strip header. At < 35% the strip shows **"CABIN FAILING"** in amber, with the crash tolerance as a speed ("hold under 9 m/s"). The descent HUD's vertical speed turns red when above the crewed part's tolerance. | None at the moment of impact. The warning is the descent itself, and crewed pods are the toughest part (tolerance 9 m/s). |
| **Out of suit oxygen** | The suit's `o2` reaches 0, then the blackout grace runs out. The supply lasts **20 minutes on EVA** where the air can't be breathed (vacuum, toxic or thin air; climate tells). It refills fully aboard, at base, or at a locker ("Refill suit O2 from Kestrel I"). In breathable air with the helmet off there is no drain. | Chips on the portrait and the HUD: **O2 25%** (amber, chime), **O2 10%** (red, alarm every 10 s), **1 MIN** (continuous alarm, the HUD rim pulses). | **15 s BLACKOUT**: the screen dims, a heartbeat plays, and they can't move. Boarding, or a crewmate who reaches them and picks "Share O2" from the right-click menu, saves them. |
| **Drowning** | Today's held-breath rule (`o2_secs` = 60 s under water). At 0 they black out instead of waking at base. | The existing breath meter, plus the same 25% / 10% chips and alarm. | **10 s BLACKOUT** under water: surfacing (a swim stroke up, the buoyancy) or a crewmate pulling them out saves them. |
| **Impact on foot** (falls, being hit by a craft or boulder) | The body's velocity changes by more than **13 m/s within one tick** (Δv is read off the body each tick; that covers a fall and a hit the same way). **6–13 m/s** injures instead: `hp` drops by `(Δv − 6) / 7`, a limp and a hurt grunt play, and at hp 0 the member dies. | The fall indicator: while airborne, a chip shows the fall speed relative to the ground. It turns amber at 6 m/s and red at 12 m/s with a "FATAL FALL" warning. On a low-g moon it rarely gets there. Injured members show an hp bar on their portrait and chip. | None at the impact. The warning is the fall indicator, and the threshold is a 9 m drop at 9.8 m/s². |
| **Crushed** | Something solid fills the suit's middle: `overlapSphere` (r 0.15 at the capsule's centre) hits a dynamic body or craft for 0.4 s in a row. Examples: pinned under a toppled rover, under a dropped boulder. | The first tick of overlap: a "PINNED" chip, a strained breath, and a red vignette. | **0.4 s**. Anything that moves the weight or the body clears it. |
| **Burned on re-entry** | A member **exposed** to re-entry heating (in an open seat, or on EVA) gets `heat += vessel heating × 2 × dt`. They die at 1.0. A closed pod protects its crew until the pod itself fails (the first row). | **"HEAT"** on the portrait from heat 0.2, and an alarm from 0.6. The crew strip header shows the craft's heating rate whenever an open-seat rider is aboard. | Heat cools at 0.1/s once heating stops, so climbing out of the heat in time saves them. |

**What happens at the moment of death:**

- The camera holds on them for 2 s, with a muted sting, and the caption names them and
  the cause: "Dana Okafor was killed: impact, 17 m/s".
- Control passes, in this order:
  1. the nearest living on-foot member in range;
  2. the craft they were in, or the nearest crewed craft;
  3. a member at base (they walk out of the Command Centre);
  4. the free newbie (§2.2).

**The body and the pack:**

- **Remains.** A gritty, plain marker: the suit lies where they fell, in a still pose
  (the suit model, no ragdoll needed). It is a `deployables` record of kind `remains`
  (§5.5), so it persists, shows on the Tracking Station, and can be found.
  - Right-click it → **Recover the body**: another crew member carries them home (they
    take 80 kg against the pack, then RECOVER). The memorial records "brought home",
    and the agency gets back the reputation lost below.
  - Remains on a body you never return to just stay there as a monument.
- **Inventory.** The pack drops where they died as a **salvage crate**: the existing
  `salvage.drop`, which now carries items as well as materials.
  - Under water it sinks, as today.
  - In space it floats at the death point, moving with the craft's or the body's
    velocity (a deployable record in orbit coordinates is too much for this upgrade).
    A crate in space is kept relative to the craft it was nearest; if that craft is
    gone, the crate goes too, and the memorial notes "lost in space".
  - **Crew who die inside a destroyed part**: their packs drop as one crate at the
    wreck.
- **Reputation.** −2 for the agency per death, −1 more if the remains are never brought
  home (applied when the record is a year old).

**The memorial.** The Astronaut Complex panel has a **MEMORIAL** tab: name, hire date,
date and place of death, the cause in plain words, the craft, flights, EVA time, flags
planted, and "brought home" or "remains on Nami". The Command Centre's lobby has a
plaque. Generated in-world: one line per name on a dark plate, the agency emblem
(§2.5) at the top.

**The forgiving option.** Keep one switch, **"Crew death: ON / Rescue instead"**:

- set on the new-save panel, and changeable in Settings ▸ Game for that save;
- stored in `crew.death`, default **ON**;
- with Rescue, every cause above blacks out and the member wakes at base for the
  rescue fee. This is today's out-of-air rule, which already exists, so it costs
  almost nothing to keep, and it makes the game a pure sandbox for players who want one.

It is not the default, because the user asked for real death.

### 2.4 Migration of existing saves (runs once, `crew.lua`)

It runs when `crew.version` is nil and `g_played` is true (an existing save). New
saves are created at version 1 with the three starters already in place.

1. Create member #1 with a generated name and `hired` = 0. **Also create members #2 and
   #3 as free starters at base**, so every save has the same three-astronaut start.
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
5. The agency identity: `agency.name` = "Solar Exploration Agency", and an emblem
   generated from that name (§2.5). A one-time notice says "Name your agency in
   Settings ▸ Agency".
6. Set `crew.death = true` (death on, as for new saves), and `crew.version = 1`.

After this, `"astro"` keeps resolving to the active member's pack (§5.2), so the
objectives, salvage, the inventory panel, the depot and the mining code all keep
working without edits.

### 2.5 Agency identity: name and emblem

The player is the agency, so the agency has a **name** and an **emblem**. Both are
chosen on the new-save panel and can be changed later in Settings ▸ Agency. The emblem
is used everywhere:

- the flag cloth (§7);
- an **emblem plate** on every crewed part (Pod Mk1/Mk2, cabin, cockpit, Command Seat
  back);
- the suit's shoulder patch;
- the crew strip header, the Tracking Station and Astronaut Complex headers;
- the save-slot card on the main menu;
- the memorial plaque;
- the VAB's door sign.

**Save keys:**

- `agency.name` (string, 1–32 characters);
- `agency.emblem` = `{ v = 1, seed, shape, mono, motif, pal = { bg, ring, fg, accent }, image = nil | "user://emblems/<file>" }`.

The spec is small. The texture is rebuilt from it at load (§ below), so the save holds
no pixels. An uploaded image stays in the player's `user://` folder and the save holds
only its path.

**The generated emblem** (`emblem.lua`, a pure rulebook that loads in luajit):

- **Seed** = a hash of the agency name. Typing a different name gives a different
  emblem; **↻ Regenerate** steps the seed.
- **Monogram**: the initials of the name's significant words (up to 3: "Solar
  Exploration Agency" → "SEA"), drawn in a built-in stencil-style block alphabet
  (A–Z, 0–9 as filled polygons in the rulebook), so it needs no font.
- **Shape**, one of: roundel (NASA "meatball"), shield, hexagon mission patch, chevron
  badge, or rounded square.
- **Motif**, one of: an orbit ellipse, a rising rocket silhouette, a star, a ringed
  planet, or crossed swooshes. It is placed behind or around the monogram by the
  shape's layout rule.
- **Palette**, from 10 curated four-colour sets in the Flight Hardware style
  (docs/ui-style.md): navy and white with a red swoosh, olive and cream, black and safety
  orange, and so on. All sets are checked for contrast, so every seed looks finished.
- **Wear**: a light painted-metal grain, like base_tex.py's `wear()`, so it sits in the
  gritty art direction.
- **Rasterised** by `emblem.lua` into 256×256 RGBA pixels, with signed-distance shapes
  for edges at 2× supersampling. It goes to `assets.textureFromPixels(256, 256,
  pixels)` → `img:N`, published as `emblem.tex()`.
  - The flag texture (512×341) is composed the same way: the field colour, the emblem,
    and the agency name in the block alphabet.
  - Both are rebuilt at load (about 30 ms in LuaJIT, measured as acceptance) and
    whenever the spec changes.
- **Tweak**: the panel has the shape (◂ ▸), motif (◂ ▸) and palette (◂ ▸), plus a colour
  picker on each of the four colours. It previews live.

**A custom image file:**

- **The engine has no native file-open dialog** (lua-api.md: `assets.readBytes`,
  `assets.getContents` and `assets.textureFromBytes` exist, with `user://` paths, but
  there is no picker and no OS file drop). That is engine card **H11** (§8).
- **The fallback now: a folder the game scans.**
  - The panel's **Use my own image** button lists `assets.getContents("user://emblems")`.
  - It shows the folder's real path (`app.dataPath()` + `/emblems`) with "Put a PNG or
    JPG here, then press ↻".
  - The chosen file is read with `assets.readBytes` (≤ 8 MB) and turned into a texture
    with `assets.textureFromBytes`, centre-cropped to square.
  - The flag composes it the same way as a generated emblem.
  - If the file is later missing, the generated emblem from the same name is used, with
    a one-time notice.
- When H11 lands, the same button opens the native dialog and copies the picked file
  into `user://emblems/`, so saves still point inside `user://`.

**Where it's used in code:**

- A small `emblem_plate.lua` sits on an `EmblemPlate` quad child in each crewed part's
  prefab, and on the suit's shoulder.
- In `start` it calls `setMaterial{ texture = emblem.tex() }`. It also listens for
  `emblem.version` changes, so a rename in Settings repaints every plate, flag and
  header live.

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
- **When EVA is allowed.** There are two cases:
  - **On a surface:** the craft is landed or splashed and slower than 1 m/s relative
    to the ground.
  - **In space or in flight off the ground:** the throttle is 0, and the craft is not
    accelerating (under 0.2 m/s²: no engine, no staging in progress).
  - **Without an RCS Pack in space, the game warns but doesn't refuse.** A two-button
    confirm opens over the portrait:

    > **Dana has no RCS Pack.** Out there she can't steer or stop: she'll keep the
    > craft's speed and can only grab the hatch if she's still within reach. If she
    > drifts away, the way back is a billed pickup. (The Pod Mk2's locker has one.)
    >
    > **[ EVA anyway ]**   **[ Cancel ]**

    - The confirm defaults to **Cancel** (Enter cancels; the EVA anyway button has to
      be clicked).
    - "Don't ask again this save" is offered after the third time.
  - **Adrift without a pack:**
    - she leaves at rest relative to the craft (§3.5), so she floats beside the hatch
      unless something moves her;
    - F boards when she's within reach of a hatch;
    - more than 50 m from any craft, her portrait and her right-click menu offer **Call
      pickup**: the existing billed `flight_ops` pickup, which brings her home. Her
      suit oxygen (§2.3) runs meanwhile, so the O2 chips say how long she has.
- **The last member leaves.** The craft is left uncrewed:
  - the throttle is cut, and control goes to the member who left;
  - on the ground it is a parked fleet record; in space it keeps coasting on its orbit
    (with SAS holding if it has power);
  - you can board it again, and if it has a probe core and a link, `` ` `` flies it back.

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
  4. **In space**, the member leaves the hatch with the craft's velocity at the hatch
     point (`vel + angVel × r`), so they start at rest relative to the craft and 1 m
     out. The pack's **HOLD** (§5.7) is on for the first 2 s.
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
| Portrait hover → **EVA** | That member steps out of their part's hatch, and you control them. Shift-click: they step out and you stay on the craft. Greyed with the reason when not allowed (§3.3): "moving 12 m/s", "engines firing", "no hatch on a cabin buried in the stack". In space without an RCS Pack it asks first (§3.3). |
| EVA in space, with an RCS Pack | WASD / SPACE / CTRL translate (camera-relative). SHIFT is a stronger burst. **X** = HOLD: kill your velocity relative to the nearest craft. F near a hatch boards. See §5.7. |
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
  rcspack   = { name = "RCS Pack",      kind = "worn",       kg = 22.0, L = 30, cost = 1400, shop = true,
                worn = { prefab = "ItemRcsPack", bone = "Spine2" },     -- drawn on the back over the PLSS; never in hand
                rcs = { thrust = 90, burst = 1.6, prop = 4.0, isp_dv = 30, g_max = 2.0 } },     -- §5.7
}
-- later, same shape: sampler, drill, welder, spare parts, food/O2 canisters.
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
- **Worn items** (`kind = "worn"`, today only the RCS Pack) are not on the belt and
  never take the hand. Having one in the pack is enough for it to work. Its model is
  drawn on the back, and it counts against mass and litres like anything else.

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
│ ROSTER (at base)                  │  cards: name, flights; greyed if aboard elsewhere/away
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

### 5.7 The RCS Pack (EVA in space)

**What it is.** A worn item: 22 kg, 30 L, $1,400. Carrying it in the pack is enough;
it never takes the hand slot, so you can fly with the Repair Kit held. Every pack
carries **4.0 units** of the craft's propellant, about **30 m/s** of Δv for a loaded
suit. That is plenty for a station's length and back several times, and a real limit.

**When it works.** Thrust is live when the wearer is **not grounded**, and either:

- they are in space (no surface within 50 m below), or
- they are on a body with local gravity under `g_max` (2 m/s²).

On a heavier world it does nothing: it can't lift a suit, and pretending to would turn
it into a jump jet. The HUD chip says "RCS: no lift here".

**Controls** (`eva_pack.lua`, on foot only; the walker's ground controls are unchanged):

| Key | Does |
|---|---|
| W A S D | Translate forward/back/left/right, relative to the camera's view (not to "up"). |
| SPACE / CTRL | Up / down along the camera's up. |
| SHIFT (hold) | Burst: 1.6× thrust, 1.6× propellant. |
| X (toggle) | **HOLD**: null your velocity relative to the **reference craft** (the nearest loaded craft within 200 m, named on the chip), then keep it there. On by default for 2 s after an EVA. Any translation key suspends it, and it resumes 1 s after you let go. |
| Mouse (RMB look, as on foot) | The suit **yaws and pitches to face the view** with a smooth slew (2 rad/s, eased). There is no free roll: the suit's "up" is the camera's up, so the view always reads level. |

**How the body is driven** (the physics):

- The suit stays the same dynamic capsule. In free fall, the walker's grounded
  velocity-chase does not run (there is no ground to chase). Instead `eva_pack` adds a
  **Δv each tick** in `fixedUpdate`:
  - `dv = thrust / (suit + pack + cargo mass) × dt` along the commanded
    camera-relative direction;
  - `vx, vy, vz = vx + dvx, vy + dvy, vz + dvz`;
  - it **only ever adds** to the body's velocity and never writes an absolute one,
    because absolute numbers in this world are orbital (km/s) and frame-dependent.
- **HOLD** computes the reference craft's point velocity *this tick*,
  `info.vel + info.angVel × (suit − info.com)`, and thrusts against the difference,
  capped by the same thrust. So it costs propellant and takes a moment, like the real
  thing.
- The capsule's `align_up` is switched **off** while thrust is live (a suit floating
  in orbit has no "down") and back on when grounded. The suit's attitude is set by
  `setUp(camUp, camFwd)`, slewed.
- **The moving-frame caveat.** The home planet moves 1.5–6 m per tick, and craft in
  orbit move km/s:
  - the reference craft is kept as a **node id**, never as a position;
  - its relative position and velocity are recomputed from both nodes every tick;
  - the "distance to craft" readout and the hatch-board range are recomputed each
    frame;
  - nothing stores a world position across frames. Velocities are only ever compared
    within one tick.
- **Gravity still applies.** In orbit the suit falls along the same orbit as the
  station beside it, which is why relative motion is all that matters and why HOLD
  works on relative velocity.

**Propellant.**

- The fill is tracked **only while a crew member carries the pack**, as a crew-record
  field `crew.m.<id>.rcs`. Item stacks stay plain counts.
- A pack in a locker, a hold or the base is always full. Putting a used pack into a
  locker tops it up from that craft's propellant (`vessel_controller.fuelDraw`, the
  pool RCS thrusters already draw). The base and the VAB fill it for free.
- A worn pack **refills from the craft automatically when the wearer boards**. A locker
  part's context menu also offers "Refill RCS Pack (from Kestrel I's tanks)" without
  stowing it.
- **Empty pack.** A member adrift more than 50 m from any craft with an empty pack is
  never stranded: their portrait and context menu offer **Call pickup**, the existing
  billed `flight_ops` pickup, which brings them home.

**Feel.** Cold-gas puffs (small particle jets at the pack's eight nozzles, on whichever
axes are firing) and a hiss loop scaled by thrust. The HUD chip shows: propellant bar,
relative speed to the reference craft, its name and distance, and HOLD on or off.
Translation is deliberately gentle (90 N on ~120 kg, about 0.75 m/s²). Docking with a
hatch should feel like parking, not flying.

**Time warp.** Rails warp is refused while any crew member is on EVA in space (KSP's
rule). Physics warp up to 4× is allowed.

## 6. Repair as a task (E)

### 6.1 The flow (the same on the ground and in space)

1. **Get a kit.** It was put in the pack in the VAB, or taken from a locker
   (right-click the locker → Take ▸ Repair Kit). For a station, also take an **RCS
   Pack**.
2. **EVA** (portrait hover → EVA, or F). §3.3 says when EVA is allowed: on the ground,
   or in space with a pack.
3. **Hold the kit** (its belt slot). It hangs from the left hand. The RCS Pack is worn,
   so it doesn't compete with the kit.
4. **Get to the damaged part.** Walk there, or fly with the RCS Pack and use X (HOLD)
   to stop beside it. Damaged parts already show their wear (the hull `damage`
   uniform). While a kit is in hand, the hovered part's outline is tinted by its
   health.
5. **Right-click it → Repair (~14 s)**. The row shows the part's health and the time.
6. **Held at the work.** From the moment Repair starts, the crew member is **locked to
   the part** (§6.3):
   - they slide in over 0.4 s to a work spot 0.7 m off the surface, facing the
     right-clicked **hit point**;
   - on the ground they kneel or stand; in space they hang facing the hull with their
     legs trailing;
   - a looping work animation plays: both hands reach (`anim:reach`) to the hit
     point, the kit clamps to the hull beside the hands (a prop in the part's frame);
   - a spark and weld puff plays at the hands (the laser's `FxCutBite`, tinted), with
     a ratchet loop sound;
   - a progress ring is drawn over the part. The HUD reads "REPAIRING Pod Mk2 · 43% ·
     right-click → Cancel repair".
   - They ride the part however the craft moves: a tumbling station, an orbit, a
     planet moving 6 m per tick. They can't drift off and can't be knocked away.
7. **Done.** `vessel_controller.repairPart(uid, 1.0)` runs. The kit is consumed (removed
   from the pack), the wear paint clears, a caption reads "Pod Mk2 repaired — 100%",
   and the crew member is **released** (§6.3) at rest relative to the part.

### 6.2 Rules

| Rule | Value |
|---|---|
| Who | A crew member **on foot or on EVA**, with a Repair Kit **in hand**. No repairs from the seat: the point is the trip. |
| Which parts | `0 < hp < 0.999`. A broken part (hp 0, gone from the craft) is wreckage: "beyond a field repair" (`repairPart`'s rule). |
| Starting it | The crew is within `reach (2.6 m) + the part's half-size` of the hit point (the context-menu `crewAccess` rule), and moving under 1 m/s relative to the part. In space, coming in faster gives "slow down first (X holds)". |
| Duration | `secs = 6 + 16 × (1 − hp)`: a scuff is 7 s, a failing part 18 s. |
| Craft state | The craft's throttle is 0 and it isn't staging. Ground or orbit both count; parked isn't needed. |
| **Movement input** | **Doesn't cancel.** WASD, SPACE, CTRL and the RCS keys do nothing while held at the work. The hint line repeats how to cancel. |
| **Cancel** | Explicit only: **right-click → Cancel repair**. It is offered on the crew member (the `astro` target, and their CrewBody), on the part being repaired, and on their portrait or on-foot chip. **Esc does not cancel**: Esc opens the pause menu everywhere, and pausing must not throw away a long weld. |
| Forced stops | Only what makes the work impossible: the part breaks or leaves the craft; the craft is destroyed; the craft fires engines (throttle > 0 or > 0.5 m/s² of thrust: the crew is pushed off and released); the crew member runs out of air. Each one releases them with a caption saying why. |
| On cancel or stop | Progress is kept on the part for 120 s (`st.rprog`), so a re-click resumes. The kit is not used. |
| Switching away | The job **keeps running**. It belongs to the crew member, not the menu (§6.3), so you can start one member repairing, switch to another, and come back. If the member's body leaves physics range, the job pauses and resumes when they're respawned. |
| Results | `repairPart` restores `hp`, repaints, and the joint strength (`joint_strength(d, hp)`) comes back, so the structure is stronger again. |

### 6.3 Tasks belong to crew members, and the lock

`crew.setTask(id, task)` puts a job on a member, and `crew_task.lua` runs it. The record
holds the task as plain data, so it is saved:

```lua
task = { kind = "repair", craft = <vessel key: fleet fid or node id>, uid = 12,
         lx = 0.21, ly = 0.40, lz = -0.48,      -- hit point in the part's frame
         sx = 0.21, sy = 0.40, sz = -1.18,      -- the work spot (suit centre) in the part's frame
         secs = 14.2, done = 3.1, item = "repairkit" }
```

**The lock uses the kinematic-passenger path the seat already uses.** Seated crew have
ridden this way since engine 0.104 (`vessel_controller.seatCrew` and the boarding
block):

- **Attach** (`crew_task.attach(id)`):
  1. Store the work spot and hit point **in the part's local frame**, never in world.
  2. Set the body's `RigidBody.kinematic = 1`, the same write `seatCrew` does.
  3. Turn the capsule's `align_up` off for the hold.
  4. Set `crew.m.<id>.held = true`. planet_walker, eva_pack and the belt all stand down
     while `held` is set.
- **Each tick** (`fixedUpdate`):
  - vessel_controller publishes `partPointNow(uid, lx,ly,lz) → wx,wy,wz, vx,vy,vz`;
  - it is computed from **this tick's** assembly pose, with the same rails-carry
    compensation the seat uses (`pod_world` / `board_dist`'s lag note);
  - the point velocity is `info.vel + info.angVel × (p − info.com)`;
  - crew_task writes the body's position and velocity from it, and its attitude with
    `setUp(part normal, toward the hit point)`.
  - So the body is exactly where the part is this tick, however the station spins or
    the planet moves.
- **Each frame** (`lateUpdate`): the hands' IK targets (`anim:reach`) are recomputed from
  the part's **rendered** pose, so the hands sit on the hull the camera draws, the same
  reason `command_seat` poses in the camera pass.
- **Release** (done, cancel, or forced stop):
  1. `kinematic = 0`, and velocity = the part's point velocity this tick, so they start
     **at rest relative to the part**, not to the world.
  2. On the ground they are set down at the work spot's ground point; in space they
     float 0.7 m off the hull.
  3. `align_up` goes back on only if they are grounded.
  4. The **RCS Pack's state** on release: thrusters idle, **HOLD on** for 2 s with the
     part's craft as the reference. Even a station tumbling fast leaves them beside
     the hull, not flung off it.
  5. `held` is cleared, and the controls come back.
- **Why not a weld joint** (`setJoint{kind="fixed", to = part}`): the weld would also be
  exact, but it puts the suit's ~120 kg into the station's dynamics. It would wake a
  sleeping craft, load the joint-stress model, and fight `align_up`. The kinematic
  passenger touches nothing on the craft, and it is already proven by the seat.

**Who drives the task:**

- **The avatar:** tool_belt (pose, effects, kit prop) and crew_task (the lock).
- **An idle member:** `crew_body.lua`, with the same IK and the same lock.
- **The menu:** the context-menu `job` entry calls `crew.setTask` and shows progress
  while it is open. Closing the menu doesn't stop it.
- **Cancel** is a registered `astro`/`part` provider entry, `{ id = "task.cancel",
  label = "Cancel repair", act = crew.cancelTask }`. The portrait's right-click menu
  carries the same entry.

**Engine needs:** none new. Everything used is already exercised by the seated crew:
`RigidBody.kinematic`, writing a body's position and velocity, `assembly.info`
(`vel`, `angVel`, `com`), `setUp`, and `anim:reach`.

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

- **The texture** is the **agency's own** (§2.5), built at runtime by `emblem.lua`:
  - the palette's field colour, the emblem, and the agency name in the block alphabet,
    at 512 × 341, through `assets.textureFromPixels`;
  - with a custom image, that image composed onto the field;
  - all flags share one texture (`emblem.flagTex()`). A rename or a new emblem repaints
    every planted flag live.
  - A flag planted under an older emblem keeps the agency's *current* one. One identity
    is clearer than a history of logos.
  - `tools/base_tex.py`'s static `emblem()` roundel stays as the base's sign art and as
    the picture shown if the runtime texture is not ready yet.
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
| H11 | **A native file-open dialog**, and **files dropped on the window**: the player picks or drags in an image (a save to import, a mod, a custom emblem, a level), and the game gets its bytes. It is sandboxed: the script never sees arbitrary paths, only the chosen file's name and bytes. | No picker and no OS drop event in lua-api.md. What exists: `assets.readBytes`/`getContents` on `user://`, `assets.textureFromBytes` (≤ 8 MB, PNG/JPEG), and `app.dataPath()` to show the folder. | **Card (needed).** Proposed shape: `app.openFile({ title, filter = {"png","jpg"} }, function(name, bytes, err) end)` plus a `filesDropped(list)` hook. Fallback until then: a `user://emblems/` folder the game scans (§2.5). |
| H12 | **Contact impulse on any body**: `hit.impulse` (and a summed per-tick impulse) in `onCollisionEnter`/`Stay`, the way `assembly.impacts()` already reports it for vessels. For fall damage, crush detection and breakables in any game. | `onCollisionEnter(node, other, hit)` gives the point and normal only. `assembly.impacts` exists for assemblies. | Nice-to-have card. Solar uses the per-tick Δv of the body (impacts) and an `overlapSphere` at the capsule's centre (crushing), which are adequate (§2.3). |
| H10 | **Holding a character at a moving, tumbling part** (the repair lock), and **thrust on a free-floating character** (the RCS Pack). | `RigidBody.kinematic` and position/velocity writes (already used by the seated crew since 0.104); `assembly.info` `vel`/`angVel`/`com`; `setUp`; velocity increments on a dynamic body. | None. A weld (`setJoint{kind="fixed"}`) was considered and rejected for game reasons (§6.3), not because anything is missing. |

## 9. Decisions (all answered by the user, 2026-10-25)

1. **Death is real** and on by default (§2.3). There are six telegraphed causes, a pack
   that can be recovered, remains, and a memorial. A per-save "Rescue instead" switch is
   kept for players who want a pure sandbox.
2. **Space EVA** comes in now with the worn **RCS Pack** (§5.7). Without one, the game
   warns with "EVA anyway / Cancel" and lets them go. The billed pickup brings back
   anyone adrift (§3.3). Repair is a held task, locked to the part until it's done or
   cancelled from the right-click menu (§6).
3. **Agency identity**: the player names the agency on the new-save panel. The emblem is
   generated from the name and can be regenerated or tweaked, or replaced with the
   player's own image (§2.5). It is used on flags, parts, suits, the HUD and the
   memorial.
4. **Crew economy**: three free starters; a one-time hire fee after that; no wages; a
   free newbie when everyone is dead (§2.2).
5. **Roles and traits**: deferred (see "Later").

**Later (not in this upgrade):** crew roles and traits, once the base crew system works.
For example: engineers repair faster, pilots fly without a probe core, scientists get
more from samples. Also the expressive crew-cam faces. The record has room for both; no
code is reserved.

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
  - `planet_walker.lua`: suit-state load/save hooks, standing down while `held`, and
    handing free fall to the pack. The suit agent's helmet code lands first; WS1 then
    owns the file.
  - **the RCS Pack**: new `scripts/eva_pack.lua` (thrust, HOLD, attitude slew,
    propellant, its HUD chip, puffs and hiss), new `prefabs/ItemRcsPack` and its
    model. Its `items.lua` entry is written by WS3 on day 0 from §5.1; changes to it
    go to WS3 as patches.
  - the **repair lock** in `crew_task.lua` (attach, per-tick ride, release) and
    vessel_controller's `partPointNow`;
  - tests: new `smoke_crew.lua`, `smoke_crew_migrate.lua`, `smoke_crew_seats.lua`;
    updates to `smoke_command_seat.lua`, `smoke_crew_stations.lua`, `smoke_revert.lua`,
    `smoke_fleet_readout.lua`.
- **Does:** §2 (records, hiring logic, migration), §3 (slots, `st.crew`, dolls placed and
  posed, hatches, boarding), §4.1–4.3 (avatar binding, `crew.control`, EVA,
  Shift-EVA, quick swap, the switch list), EVA in space and §5.7 (the RCS Pack, the
  refill from craft propellant, the rails-warp refusal), the §6.3 lock, the revert keys
  (`crew.*`), the spawner's seat plan, and the locker plan at launch.
  - **§2.2:** the three starters, hiring logic, and the free newbie (including the
    auto-hire when the last member dies).
  - **§2.3, the death rules and their state:**
    - suit O2 and the EVA supply (planet_walker, with climate's breathability);
    - drowning's blackout;
    - the impact Δv and injury model;
    - the crush overlap test;
    - re-entry exposure (vessel_controller's `heating` × exposed crew);
    - the cabin-failing state;
    - the blackout graces and "Share O2";
    - the control handoff order;
    - `crew.death`, and the rescue path when it is off.
  - Each death calls `salvage.drop` (WS3) and `deployables.place("remains", …)` (WS4).
  - WS1 publishes every warning as **state**; WS2 draws it:
    `crew.alerts(id) → { o2 = 0..1, breath, hp, heat, fall = m/s, pinned = bool, blackout = secs left, cabin = hp }`.
  - For EVA without a pack, `crew.evaCheck(id) → ok, why, warn` returns `warn` instead
    of refusing; `eva(id, { confirmed = true })` goes ahead.
- **Publishes** (the interface every other workstream codes against, stubbed on day 0):

```lua
-- crew.lua
roster() -> {rec…}; get(id) -> rec; activeId() -> id|nil; packOf(id) -> "crew:"..id
where(id) -> status, detail; hire(i) -> id|nil, why; offers() -> {{name, cost}…}; rename(id, s)
control(id) -> ok, why; eva(id, {stay=bool}) -> ok, why; board(id, v, uid?, slot?) -> ok, why
quickSwap() -> ok; switchList() -> {{kind="crew"|"vessel", id|v, name, dist}…}
aboard(v) -> {{id, uid, slot, commander=bool}…}; dollOf(id) -> node|nil; bodyOf(id) -> node|nil
setTask(id, task) -> ok, why; task(id) -> task|nil; cancelTask(id, why)
alerts(id) -> {o2, breath, hp, heat, fall, pinned, blackout, cabin}; evaCheck(id) -> ok, why, warn
memorial() -> {{id, name, hired, died = {st, date, cause, body, craft, remains}, flights, eva_s, flags, home = bool}…}
deathOn() -> bool; setDeath(on)
held(id) -> bool                                -- locked at a task (§6.3): movement code stands down
-- crew_task.lua: attach(id), release(id, why)   -- the lock; WS3's repair calls these through setTask/cancelTask
-- eva_pack.lua: rcsLeft(id) -> units, cap; refill(id, from_vessel) -> units; hold(on); reference() -> node|nil
version  -- bumps on any change (panels poll it)
-- vessel_controller: seatsOf(), crewIds(), seatMember(uid, slot, id), hatchWorld(uid), commander(),
--                    partPointNow(uid, lx,ly,lz) -> wx,wy,wz, vx,vy,vz   (this tick's pose, rails-carry compensated)
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
    Shots go to `SCRATCH/ws1/`.
  - **In-engine probe, space** (`tools/perf/evaprobe.lua`):
    - put a two-module station in orbit (spawned from a blueprint) with a slow tumble
      (0.1 rad/s);
    - EVA without a pack is refused with the reason; take a pack from the locker, then
      EVA;
    - fly 20 m out and back: propellant falls by the Δv used, and HOLD brings the
      relative speed under 0.05 m/s within 3 s;
    - start a repair: for its whole length the suit's distance from the part's work
      spot stays under 0.05 m at every tick (logged), while the station tumbles and
      orbits;
    - press WASD and RCS keys mid-job: nothing moves, and the job continues;
    - right-click the crew member → Cancel repair: they are released at under 0.1 m/s
      relative to the part, and progress is kept;
    - re-click: the job resumes and finishes, hp is 1.0;
    - board: the pack refills from the craft's propellant.
    - EVA without a pack in space shows the warning; Cancel keeps them aboard; "EVA
      anyway" lets them out at rest relative to the craft; past 50 m, Call pickup
      brings them home.
  - **luajit:** `smoke_crew_death`, one case per cause:
    - the impact thresholds (6 / 13 m/s);
    - O2 drain to the alarm thresholds, then blackout, then death, and saved by
      boarding inside the grace;
    - crush after 0.4 s of overlap only;
    - heat accumulation and cooling;
    - a destroyed part kills only its own occupants;
    - the control handoff order;
    - the free-newbie auto-hire;
    - with `crew.death` off every cause rescues instead;
    - a new save and a migrated save both have three starters.
  - **In-engine probe, death** (`tools/perf/deathprobe.lua`):
    - a 20 m drop kills (crate and remains spawned, a memorial row written), and a 5 m
      drop doesn't;
    - a rover set on a crew member crushes them;
    - a fast re-entry kills an open-seat rider and spares the pod's crew;
    - a probe with death off rescues all three. The luajit sweep and `floptle check` (0 errors, 6
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
  - new `scripts/crew_alerts_hud.lua` (O2, breath, hp, HEAT, fall, PINNED, CABIN
    FAILING chips, alarm sounds, the blackout dim, and the death camera hold and
    caption);
  - tests: new `smoke_crew_strip.lua` and `smoke_builder_crew.lua`.
- **Does:** §4.4 and §5.6, the hire panel UI on WS1's `hire`/`offers`, and the strip's
  budget measurement (H1).
  - The **EVA-without-pack confirm** on the portrait (§3.3).
  - The **warnings** of §2.3, drawn from `crew.alerts`.
  - The Astronaut Complex **MEMORIAL** tab, and the lobby plaque in the scene (the
    emblem on it comes from WS4's `emblem.tex()`).
- **Depends on** WS1's stubbed API (day 0). It can build against a fake roster table
  until WS1 lands.
- **Acceptance:**
  - **luajit:** strip layout for 1, 3 and 7 crew (paging); the crew tab's drag rules
    (no double booking, a block without anyone at the controls).
  - **In-engine:** a shot of 3 portraits with the IVA visible and faces lit; hover
    reveals EVA and ⇄; `perf.cost('render')` with the strip on and off is ≤ 0.6 ms on
    `bench.sh … plane` (record `uptime`); V shows the IVA with the crew dolls; the VAB
    tab assigns 2 crew and a locker plan, and the launch seats them.
  - **In-engine:** the alarm chips at 25% / 10% / 1 MIN (shots); the EVA confirm, with
    its Cancel default; the memorial lists a probe death with its cause.

### WS3: Items, hands and tasks

- **Owns:**
  - new `scripts/items.lua`;
  - `inventory.lua`, `inventory_panel.lua`, `tool_belt.lua` (after the tools agent
    lands), `salvage.lua` (crates carry items as well as materials; a crate in space
    rides relative to its nearest craft, §2.3);
  - `context_providers.lua` (after the ctxmenu agent lands): locker take/put by item,
    `held.repair`, the deployable "Pick up", and the "Give" stub;
  - new prefabs `ItemRepairKit`, `ItemBeaconStowed`, `ItemFlagFurled`;
  - tests: new `smoke_items.lua` and `smoke_repair.lua`; updates to
    `smoke_inventory.lua`, `smoke_relay.lua`, `smoke_toolgate.lua`,
    `smoke_gravgun.lua`, `smoke_revert_beacons.lua`.
- **Does:** §5.1–5.5 (the registry, the alias, bulk, hand slot and grips, the generic
  deploy mode with the beacon moved onto it and comms untouched) and §6 (the repair
  job, IK, effects, the cancel entries and forced-stop rules, consumption), with the
  avatar's task driving in tool_belt. The lock itself (attach, ride, release) is WS1's
  `crew_task`; WS3 calls it through `crew.setTask`/`cancelTask`. On day 0, WS3 also
  writes the `rcspack` entry in `items.lua` and the `kind = "worn"` rule (not on the
  belt, never in hand).
- **Interface to WS4:** `items.ITEMS.flag.deploy.store = "deployables"`. Deploy mode
  calls `deployables.place(kind, body, gx,gy,gz, {by, yaw}) → id` and `deployables.near(x,y,z,r)`.
  The plant animation hook is `tool_belt.plantAnim(secs, kind)`.
- **Acceptance:**
  - **luajit:** `smoke_items`: mass and litre limits with honest partial moves; `astro`
    alias resolution; `moveItem` refusals with reasons; old `inv.gear.astro` beacons
    readable after migration.
  - **luajit:** `smoke_repair`: duration formula; movement input never cancels; only
    `cancelTask` and the forced stops (part broken, craft destroyed, thrust, out of
    air) end it; the kit is consumed only on `done`; resume within 120 s; "Cancel
    repair" is offered on the crew member, the part and the portrait while a task
    runs.
  - **In-engine probe:**
    1. wear a pod part to 0.4 (`wearPart`);
    2. EVA, take a kit from the locker through the menu, hold it, right-click → Repair;
    3. the hands land on the hit point (shot); 13–14 s later hp is 1.0 and the kit
       count went down by 1;
    4. WASD mid-job does nothing; right-click → Cancel repair releases them standing
       at the work spot, and a re-click resumes from the kept progress.
    5. Separately, plant and pick up a beacon by the new path. The relay solve and
       `comms.beacons` are unchanged, and an old save with planted beacons and 2
       carried ones loads them all.

### WS4: Agency identity, flags, deployables store, Tracking Station

- **Owns:**
  - new `scripts/deployables.lua`, `scripts/flag.lua`, `shaders/flag_cloth.flsl`;
  - new `tools/gen_flag.py`;
  - new `prefabs/Flag`, `FlagGhost`, `FlagGhostBad`, `DeployLib`, and `Remains` (the
    fallen suit, a still pose of the suit model);
  - **agency identity (§2.5):**
    - new `scripts/emblem.lua` (generator, rasteriser, `tex()`/`flagTex()`, the
      `user://emblems` scan) and new `scripts/emblem_plate.lua`;
    - new `prefabs/EmblemPlate`, and the plate child added to `PartPod`, `PartSeat` and
      `PartCockpit`;
    - WS1 adds the same child to its new `PartPodMk2`/`PartCabin`, and the suit's
      shoulder patch goes to the suit owner as a patch;
    - `menu_newsave.lua` (the agency name, the emblem editor, and the "Crew death /
      Rescue instead" switch);
    - `menu_settings.lua` (Settings ▸ Agency: rename, re-edit; the death switch for this
      save);
    - `menu_slot.lua` (the emblem on the save card);
  - `tracking_station.lua` (FLAGS, plus a CREW section listing the roster with
    GO TO/Recall on WS1's API);
  - `objectives.lua`, `missions.lua` (the flag goal);
  - tests: new `smoke_flags.lua`; updates to `smoke_tracking.lua` and
    `smoke_objectives.lua`.
- **Does:** §5.5's store, all of §7, §2.5, the `remains` deployable kind (and REMAINS in
  the Tracking Station, with "Recover the body"), and `dep.*` in the revert snapshot (a
  patch to WS1's vessel_spawner). WS4 publishes `emblem.tex()`, `emblem.flagTex()`,
  `emblem.version` and `agency.name()` for every header that shows the identity.
- **Acceptance:**
  - **luajit:** place, list, near and remove; snapshot and restore; the flag goal
    latches on a placed flag and old contracts still latch on stepping out.
  - **In-engine:**
    - plant a flag at the home meadow: the shot shows cloth motion between two frames
      0.5 s apart (pixel diff), and it faces downwind;
    - on an airless moon the cloth is static on its crossbar;
    - the Tracking Station row shows the photo;
    - reload, and the flag is still there.
  - **luajit:** `smoke_emblem`:
    - the same name gives the same emblem, and different names give different ones;
    - the monogram rule ("Solar Exploration Agency" → "SEA"; one-word names);
    - every palette passes the contrast check;
    - a spec round-trips through the save;
    - a missing custom image falls back to the generated emblem;
    - migration sets the default name.
  - **In-engine:**
    - the new-save panel previews the emblem live as the name is typed; ↻ changes it;
    - the generator, rasteriser and flag compose take ≤ 30 ms at load;
    - a PNG dropped in `user://emblems/` shows in the list and becomes the flag (shot);
    - a rename in Settings repaints a planted flag and a pod's plate without a reload.

### Order and the first playable slice

- **Day 0 (both together, ~2 h):** WS1 commits a stub of `crew.lua` that returns member
  #1 and the `activeId` alias. WS3 commits `items.lua` and the inventory alias. Every
  other workstream codes against these from then on.
- **Slice 1, "tactile items and identity"** (WS3 + WS4 on top of the stubs; the user can
  play this first). On today's single astronaut (member #1), still under today's rescue
  rule, because death waits for the three starters in slice 2:
  - the agency name and generated or custom emblem, on the new-save panel and in
    Settings;
  - the repair kit;
  - lockers with take/put;
  - the relay beacon as a held, deployable item;
  - the waving company flag, wearing the agency's emblem, with its photo and the
    Tracking Station list;
  - VAB loadout for the one astronaut, as a minimal version of the CREW tab with
    loadout only.
  The repair already uses the **held lock** (§6.3): WS1 delivers `crew_task`'s attach,
  ride and release and `partPointNow` as an early piece, alongside the day-0 stubs.
- **Slice 1b, "EVA in space"** (WS1, right after slice 1 and before multi-crew): the RCS
  Pack, EVA in orbit, HOLD, refills from craft propellant, and repairing a damaged
  station in orbit with the same held task. It still runs on the single astronaut.
- **Slice 2, "the crew"** (WS1 + WS2, with WS3's crates and WS4's remains):
  - three starters (migration adds two to existing saves), hiring, the free newbie;
  - **death on by default**: the six causes, their warnings, the crate and remains, the
    memorial, and the Rescue switch;
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
