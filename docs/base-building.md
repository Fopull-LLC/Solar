# Base building: the Engineer's Build Kit

This is the field version of the VAB. You stand in the world and the ground is
the craft: the same parts column, a ghost of the part under the cursor, and a
click to buy it, ship it out and set it down. This doc covers **deep-space
steps 4 and 5**: addendum items K1–K10, K13 and N1. Step 4 opened the kit and
placed single parts; step 5 (§7) snaps parts to each other, lays them on a
grid, levels the ground and casts footings, judges every placement in full,
keeps an undo ring and takes parts down for a refund. Step 6 (§9) adds the
Build Stand: a craft put on it, commissioned into a live craft, released,
driven off and returned to it (L1, L2, L4). Step 7 (§11) adds the Base Station
Tower: founding a base, the relay tiers, the map and the 10 % unlock. Step 8
(§12) adds the shared base grid with its storage, the Power Cable and the
Shield Wall (M6, B9b, M6c).

Read `docs/positions-and-frames.md` first. Everything here is kept in a body's
frame.

## 1. Who can build, and how it opens

- **The Build Kit** (`items.lua` `buildkit`) is a field tablet in a hard carry
  frame: 1.6 kg, 3 L, carried by its handle (grip `left`). It is a `device`, so
  it sits on the belt after the tools.
- **Issue.** Every Engineer gets one Build Kit, once per member.
  `field_builder.issue_tick` checks every 3 s and stamps
  `inv.issued.buildkit.<cid>`. That covers hires, retrains and old saves. It is
  not part of the standard `issue` (that goes to everyone). Since step 7 (M3,
  §11) the kit is the Relay Network's 10 % unlock: nobody is issued one before
  it; after it the Depot stocks it and Engineers get theirs at the base.
- **The gate.** The kit opens only when all of these hold:
  - the active member is an Engineer (`crew.hasRole`, from the roles commit 578c13a);
  - they are on foot (`planet_walker.onFoot`) and not swimming;
  - no other panel is up (pause, pack, facility, ops board, map, lab talk);
  - the VAB doesn't have the keys;
  - the hands aren't at a job.
- **B or its number key** takes the kit out.
  - Non-Engineers have no kit, so B says "Build Kit: Engineers only".
  - With the kit up, **B** folds the parts column away and brings it back.
  - **Esc** drops the part in hand first; a second Esc closes the kit. Esc is
    on `pause_menu`'s ladder (`escTakenAt`).
  - **H**, or another number key, puts the kit away like any other item.
- **Free cursor.** While the kit is up, `planet_camera` leaves first person
  and shift-lock and won't scroll into first person. The cursor is then free.
  RMB held still looks round, and WASD still walks, so you can move, aim and
  place in one motion. Scroll still zooms the third-person view.

## 2. The parts column (K3)

- **`catalog_panel.lua`, re-hosted.** `field_builder` spawns a
  `FieldCatalogue` node under the Ship HUD while the kit is up and destroys it
  when the kit closes. A scene therefore holds one catalogue at most, either
  the VAB's or this one.
- **The host.** The panel finds its host with `host()`: the VAB's `builder`
  if it exists, otherwise `field_builder` while the kit is open.
  `field_builder` supplies the host methods: `catalogue`, `partInfo`, `hold`,
  `heldId`, `holding`, `dropHeld`, `previewPrefab`, `frameNodeOrNil`,
  `researchPending`, `hint`, `registerPanel`. It also supplies these optional
  hooks, all ignored by the VAB:
  - `cardLines(id, def, locked)` gives the price and role lines.
  - `noSubAssy` hides the SUB-ASSY tab.
  - `previewLayer()` names the layer the spinning preview and the card icons
    are photographed on: `offstage` (bit 5), the layer the main camera never
    draws (`planet_camera.cullBase`), as lab_talk's stand uses. The stand is
    2.4 km up the crew's frame, in open sky.
  - `layout(W, H)` places the column. It is the VAB's 228 px column, starting
    below the HUD's top-left chips.
  - `footText()` sets the footer line.
- **Kept from the VAB:** search (`/`), the tabs ALL · ★ · RECENT · BASE, the
  cards and the spinning preview plate.
- **The card icons (fixed in step 5).** Step 4's icons came back as plain sky
  because its stand was inside the planet. `camera.captureTexture` (and
  `camera.capture`) render through a camera node with every draw on: terrain,
  fog, sky and shadows, whatever the camera's own `setCamera{ terrain = false,
  fog = false }` says. The engine's `resolve_camera` keeps only the FOV and
  cull mask, and `render_frame_texture` passes `CameraDraws::default()`. The
  live render-target plate honours those flags, so it drew the part. Under the
  ground the capture saw only fog. The VAB's stand is 2.4 km up in open sky,
  so its icons were never hit. The stand now sits up there too, on
  `offstage`. The probe captures the same camera in both places
  (`icon_sky.png`, `icon_underground.png`). The engine card proposal is in
  step 5's NOTES.
- **Folded (K3).** B folds the column to a **36 px tab** in its corner
  (`catalog_panel` draws it when the host's `isCollapsed()` is true). The tab
  reads PARTS · B, and clicking its ▸ (`unfold()`) or pressing B brings the
  column back.
- **Hidden:** the toolbar, inspector, staging, symmetry and SUB-ASSY.
- **A card's lines** read `$1,040` and `$900 + $140 shipping · Pell Groundworks`.
  Off the home world they read `made here` and `needs materials + $180 fittings`.

### The BASE section (`scripts/parts_base.lua`)

| Part | Prefab | Real size | Mass | Price | Hull (EN1) |
|---|---|---|---|---|---|
| Pad Plate | `BasePadPlate` | 4 × 4 m precast slab, 0.30 m | 11.5 t | $900 | none |
| Equipment Shed | `BaseShed` | 3.0 × 2.4 × 2.6 m steel shelter on skids | 1.6 t | $1,400 | `subShape`: its `Wall N` boxes |
| Surface Hab | `BaseHab` | 4 m × 6 m pressure can on saddles | 7.5 t | $6,500 | `shell`: its `Shell` child mesh |
| Build Stand (step 6) | `BaseStand` | 0.9 m deck on a telescoping column, 0.5–4.0 m | 0.4 t | $650 | none |
| Base Hub (playtest 11-09, §19) | `BaseHub` | 2.6 × 1.8 m operations console on a skid: a sloped desk with two displays, a rack, a 3.4 m beacon pole | 0.9 t | $2,500 | none |

- **Every BASE part is `fieldOnly`.** The VAB never lists them, because the
  builder doesn't extend its registry with `parts_base`. `register(REG,
  CATALOGUE)` is there for a shared catalogue one day.
- **`tools/gen_base_parts.py`** writes the models (`models/base/parts/`) and
  prefabs. They use the spaceport's primitives and its CC0/procedural PBR sets
  (`textures/base`: concrete, cladding, steel). The Build Kit's model uses
  `textures/parts` (metal, rubber).
- **Each module is built 1:1 with its future interior** (E's direction). The
  engine's interiors Stage 1 then becomes a flag change:
  - **Flat modules** (the shed) carry floor, walls, roof and door as named
    static collider boxes (`Wall N`). Each becomes one `rb.subShape`.
  - **Curved modules** (the hab) carry their pressure hull as one child mesh,
    `Shell` (`hab_shell.glb`). It is a 0.10 m wall with its inner face
    modelled, and it becomes the `rb.shell`. Until then an octagon of four
    collider boxes closes it.
  - **Both** carry their fit-out as an `Interior` child mesh: racks, bench,
    deck, bunks.
  - **Doors open (sandbox S1, §13).** The shed's door is a steel leaf on an
    outside track and the hab's a pressure hatch in a collar cut through its
    hull, each a `Door` child with its own colliders that `kit_live.lua`
    slides open. Their interiors are static collider boxes on the planet
    (floor, walls, racks, bunks; the hab's hull a ring of 16 thin boxes), so
    the crew walks in as they do in the Research Lab. Static ground interiors
    are not kinematic fakes; EN1/EN2 matter only for moving compounds.

## 3. The ghost and the aim (K4)

- **The aim.**
  - It is a ray through the cursor (`camera.screenToRay`), cast in
    `lateUpdate`. The Build Kit node is last in `system.ron`, so its
    `lateUpdate` runs after the camera has placed itself for the frame.
  - The ray hits terrain and colliders, at most 24 m from the Engineer.
  - The hit becomes a **pose** in its planet's frame at once:
    - the body-relative ground point;
    - up = the radial up;
    - the front (+Z) turned toward the Engineer.
  - The raw world hit is kept only for that frame's physics queries.
- **The ghost** is the part's own prefab, spawned once per pick:
  - with `spawn{ body = false }`, so it has no collider and costs physics
    nothing;
  - parented to the planet, so its local position is the body-relative pose
    plus its `seat`, written every frame;
  - turned into a hologram by **`ghost.apply(node, color, alpha)`**
    (`scripts/ghost.lua`), the one function Solar owns for this. EN10 changes
    only that function.
- **The Lua fallback for the ghost material:**
  - it is one material, `materials/hologram.ron` with `shaders/hologram.flsl`:
    additive rim and fill, untextured;
  - it is assigned once per node, then tinted with the `tint` and `alpha`
    uniforms;
  - a colour change costs two uniform writes. Nothing rebuilds a mesh or a
    material per frame.
- **Green means it can go there; red means it can't.** The reason shows on
  the hint line, which is `field_builder.hintLine()` (`items.lua` `hintFrom`).

### What a placement must pass (`field_builder.validity`, step 5's full set)

In this order; the first that fails is the red ghost's reason.

- **Off the home world:** refused, with the reason (N2 comes at step 13).
- **Reach:** the snapped spot within the kit's 24 m (+2 m for a snap that
  moved it).
- **What the ray hit:** a placed part is snapping's (an edge or a deck,
  §7). Aimed at one that offers neither, the reason says why: "no free edge
  on that Pad Plate", "the Equipment Shed has no deck". Any other thing (a
  crate, a facility) is in the way.
- **Slope:** the ground normal at the cursor against up, at least 0.6 (the
  flag's gate). The footing judges the rest.
- **The ground (K7):** on a deck, every footprint sample must stand on a
  deck of that structure at that height (`base_snap.supported`). On the
  ground, the terrain under the footprint is sampled and the ground may
  rise into it or fall under it by at most the part's `grade` (§7).
- **Not under water** (`climate.seaDepth`, at the part's base).
- **Not on the spaceport's ground** (`base_facilities.keepClear`, at the
  centre and the four corners). That includes the runway's overruns.
- **Nothing in the way**, via **`placement.overlapObb(center, half, rot)`**
  (`scripts/placement.lua`). Its fallback until EN12:
  - it calls `overlapSphere` over the box's half-diagonal;
  - it then puts each hit's contact point, and the hit node's origin, through
    the builder's oriented-box signed distance (`builder_attach.boxSdf` in
    world axes);
  - the ground is skipped;
  - your own body names itself ("you're standing where it goes"), another
    crew member says "someone is standing where it goes", and a placed part
    names itself ("the Equipment Shed is in the way");
  - the box starts 0.25 m over the part's base, so the deck it stands on and
    the plate beside it are not in it;
  - the result is cached while the ghost holds still (0.5 s, or a move over
    0.1 m).
- **Affordable:** `company.afford`, for the part, its shipping and its
  footing's concrete.

## 4. Placing, money and shipping (K8, N1)

- **LMB places** a valid ghost (not over the column). The steps:
  1. `base_economy.quote` prices it: the part's price (the same REG cost the
     VAB charges at launch) plus **shipping at 10 % + $50**. Both are
     **charged at placement** (Q18) through `company.spend`, and the ledger
     says "… (shipped by Pell Groundworks)".
  2. A structure record is written.
  3. The part is spawned at once.
  4. The member is credited one `built` (crew levels count 20).
  5. A plain click empties the hand; **Shift+LMB** keeps a copy in hand.
- **RMB tapped** (under 0.25 s) drops the ghost.
- **Ctrl+Z** takes the newest step of the undo ring back if it is under 60 s
  old (Q18; the ring is §7's K9):
  - every dollar comes back, fee and footing included, through
    `company.refund`;
  - a refund isn't income, so an advance takes no share;
  - the `built` credit is taken back.
  - After 60 s an undo is refused with "deconstruct it instead".
- **The VAB still charges at launch, with no fee.** That's the agency's own yard.
- **The VAB's suppliers are already listed** (`base_economy.SUPPLIERS`), one
  per section, for step 13's part items: Marrow & Vance Propulsion, Teller
  Tankage, Halden Structural, Orbis Electrics, Kestrel Airframes, Burrow
  Automotive, Lindqvist Robotics, and Pell Groundworks for BASE.
- **Off the home world** a part is a crated part drawn from a container in
  reach (expansion X4, §22). The rules it runs on:
  - fittings cost 20 % of the price (Q22);
  - a part is drawn from any container within 30 m, nearest first, the pack
    last (Q16, `containersInReach`).

## 5. Structures (K13, `scripts/structures.lua`)

A structure is a **blueprint at a pose**, kept in its body's frame:

```
struct.list, struct.seq
struct.<id> = { id, b = body, x, y, z (body-relative ground point), ux, uy, uz (up),
                fx, fy, fz (front = the parts' +Z), n, by, t (agency clock), d,
                bp = { { uid, id, x, y, z, yaw, pitch, roll, parent, att, sym, mir, stage,
                         paid = { cost, ship, foot, total, t, supplier, by },   -- step 5
                         ft = { d, hx, hz },                                    -- step 5: a footing
                         h, lo } },                                             -- step 6: a stand's deck
                st = { ["<uid>"] = { … } }, paid = { … the founding part's … } }   -- st: a part's state (step 6)
```

- **Step 5: parts join and leave.** `addPart(id, part)` and
  `removeParts(id, uids)` do this; the record goes with its last part. Each
  part carries its own `paid`, which its undo and deconstruct read.
  - `partOfNode(node)` maps a hit node (or its `Wall N` child) to its part,
    through a node-id map kept at spawn.
  - `partsNear(body, x, y, z, r)` reads a 32 m cell index kept on add and
    remove, and on load. Nothing scans every structure.
  - A footing is a concrete block (`mesh.build`, one mesh per size, UVs in
    metres) on a node parented to the planet beside its part.

- **`bp` is the builder's blueprint part shape.** It is in the structure's
  frame (+X right, +Y up, +Z front), at the part's ground point.
  `partPose(rec, p, seat)` adds the seat along up and turns by `yaw`.
- **Streaming:**
  - each part is spawned as a plain static prefab, parented to its planet, as
    the base facilities and deployables are;
  - parts spawn only while the focus is on that world or within 20 km of it,
    and unload beyond that;
  - the check runs once a second for all structures together.
- **Cost:** a placed part has no script and no moving body, so it costs
  nothing a tick (see the probe's numbers). Rendering is one prefab instance
  per part.
- **Reload:** the records are read again and the parts stand where they were,
  on a planet that has moved kilometres meanwhile (the probe checks this).

## 6. Tests and probes

- `luajit solar/tests/smoke_base_build.lua` runs 107 checks. Step 4's 55:
  - the BASE parts;
  - shipping, quotes and card lines;
  - the 60 s refund and Q16's reach order;
  - records, frames and poses, the save round trip, ids never reused;
  - the Engineer gate on the real `crew.lua` (one kit, to the Engineer, once);
  - place → charge → record → credit, undo → refund, a refused spend that
    changes nothing, off-world refused;
  - the Build Kit on the belt.

  Step 5 adds 52:
  - footing costs and the deconstruct refund rule;
  - `base_snap`: frames, edge snap (a taken slot never offered), deck snap
    with the grid and 15° turns, a hab on one plate refused and on two
    supported, dependents, the ground grid square to the layout or the
    nearest structure, Shift free, foundations (flat, slope, too steep, a
    joined plate's skirt, raised), flatten discs covering the footprint;
  - `structures`: addPart / removeParts / partsNear, the reload rebuilding
    the index, the record going with its last part;
  - `field_builder`: joining by edge and deck, a footed part billed, the ring
    (four undos newest first, a redo bought again, refused after 60 s),
    deconstruct (the price back with the fee kept, the shed on the plate
    with it), the undo of a deconstruct, the last part down.
- `tools/perf/buildkitprobe.sh <engine>` (PATCHES=funds.patch) covers the
  whole flow in the engine. Step 4's run:
  1. the Pilot's B is refused, then the Engineer is issued a kit;
  2. B opens the kit and the column, and the card lines are checked;
  3. the Pad Plate ghost is checked green, with its foot on the ground every
     frame while the planet moves;
  4. it is placed ($1,040 charged, ledger checked) and Ctrl+Z refunds it;
  5. it is placed again with Shift held, a red ghost is shown over it, and a
     shed is placed beside it on the grid.

  Then step 5's run:
  6. a plate edge to edge (4.000 m between centres, level);
  7. a hab across the two plates;
  8. a third plate along the row, with a shed on its deck (1.548 m over the
     plate's origin) and a ray on the shed's roof resolving to its part;
  9. a mound raised beside the crew, with a shed on its flank: the footing,
     the bill, the ground levelled under it;
  10. Deconstruct from the context menu's entry: the third plate past its
      minute and the shed on it;
  11. the ring: Ctrl+Z puts them back, Ctrl+Z returns the footed shed,
      Ctrl+Shift+Z buys it again, and past its minute Ctrl+Z refuses;
  12. B folds the column to its tab;
  13. the icon camera is captured in the sky and underground;
  14. idle costs are measured;
  15. save and reload: every part stands on its record, the footing is
      drawn, and the shed is still on its deck.

  Look for `BK PASS|FAIL` and `BK RESULT`.

## 7. Step 5: snapping, the ground, undo and deconstruct (K5–K7, K9–K10)

### Snapping (K5, `scripts/base_snap.lua`)

`base_snap` is a pure rulebook. `field_builder.pose(hit)` asks it once per
frame with the part in hand, the hit (body frame), the radial up, the way
toward the Engineer, and the placed part the ray stopped on
(`structures.partOfNode`). It also passes the parts within 30 m
(`structures.partsNear`, memoised while the cursor stays in a 0.5 m cell and
nothing was built). Three answers:

| Mode | When | Where it goes |
|---|---|---|
| `edge` | A part with a `tile` (the Pad Plate) within 0.8 tile of a free slot beside one of the same tile | That slot: edge to edge, square, level. It joins that structure. |
| `deck` | An `onDeck` part (shed, hab) aimed at a part with a `deck` (the plate) | On the deck's top, on the structure's 0.5 m grid, square in 90° steps toward you plus the turn dialled. It joins the structure. Supported only if all 9 footprint samples stand on a deck of the structure at that height, so a hab needs two plates edge to edge. |
| `grid` | The ground | A new structure on the 0.5 m grid of the nearest structure within 30 m, or of the spaceport's layout frame. Square to it, plus the turn dialled. |
| `free` | Shift held | The cursor's point, its front toward you, plus the turn. No snap. |

Why not `builder_attach.candidates`: its nodes are a craft's stack and flank
nodes, captured in screen pixels on a hull. Base parts are slabs on a grid,
so the edge and deck rules are a page of their own. They are tested in luajit.

**Flat structures on a small world.** A structure's frame is the plane at its
first part. A home world is 600–950 m in radius, so a row of plates 20 m long
stands about 30 cm off the sphere at its far end. The parts stay level with
each other, which a hab across two plates needs. The ground under each is
levelled to its base, and footings take up the difference.

### Turning and raising (K6)

With a part in hand:
- the **wheel** turns it 15° (5° with Shift), and `planet_camera` leaves the
  zoom alone while `field_builder.wantsScroll` is set;
- **R** turns a quarter;
- **PgUp / PgDn** raise it 0–2 m in 0.25 m steps, standing it on a taller
  footing;
- **Backspace** resets.

Base parts stand upright, so the addendum's pitch (R) and roll (T) wait for
parts that can lie down (cables, catwalks). R is the quarter turn until then.

### The ground (K7)

A ground part (`grid`, `free`, or an `edge` plate) casts 9 terrain rays down
its footprint (`terrain.raycast`, only when the pose changes or every
0.25 s). `base_snap.foundation` then decides:

- **Base:** the mean of the samples plus the raise, or the structure's level
  for a part that joins one.
- **Refused** if the ground rises into the part or falls under it by more
  than its `grade`: 2.0 m for the slab and the hab, 1.6 m for the shed.
- **Levelled** at placement: flatten discs
  (`terrain.sculpt(…, "flatten", { normal = the part's up, hardness = 0.75 })`)
  cover the footprint and 0.3 m beyond it, centred on the base plane.
- **A footing** is cast where the ground falls more than 0.3 m under the
  base (or the slab's own 0.40 m skirt). It is a concrete block, footprint
  plus 0.15–0.25 m, reaching to the lowest sample and 0.3 m into the ground,
  billed at $160 a m³ with the part. The ghost shows it as a second
  hologram.

### The undo ring (K9)

`builder_history.newHistory(50)` holds placements and removals.
- **Ctrl+Z** undoes the newest step if it is under 60 s old; otherwise it is
  refused. An undone placement is a full refund. An undone deconstruct puts
  the parts back (the structure is re-made with the same id if it went) and
  takes the refund back.
- **Ctrl+Shift+Z** or **Ctrl+Y** redoes the step: a placement is bought
  again at today's price.
- The ring lives for the session. Nothing older than a minute can be undone,
  so there is nothing to save.

### Deconstruct (K10)

A tap of RMB on a placed part opens the context menu (a `prop` provider
registered by `field_builder`). It shows the part, its structure, and
**Deconstruct**: a 3 s job, Engineers only, whose row gives the refund and
the parts that come with it.

- **Dependents:** what stands on the part's deck comes down with it
  (`base_snap.dependents`, transitively).
- **Refund** (`base_economy.deconstructRefund`), per part: within its minute
  everything; later the price only, with the shipping fee and the footing
  kept.
- The parts go straight back to funds; nothing is left loose.
- The structure goes with its last part.

### Cost

Per tick, nothing is added for a placed structure: no script, no body that
moves. `structures.update` is the same 1 Hz streaming pass. With the kit
open, `pose` does one cell-index lookup when the cursor crosses a 0.5 m cell
(memoised), and `validity` casts 9 terrain rays when the snapped pose
changes. A snapped pose only moves when the cursor crosses a grid cell.

## 8. Step 5's hooks (used by step 6, §9)

- A stand is a BASE part (`onDeck`, so it stands on the ground or on a Pad
  Plate), and gets snapping, footings, the ring and Deconstruct for free.
  Its height is a per-part `bp` field (`h`), like `ft`.
- `structures.partOfNode` / `nodeOf` / `partsNear` are the lookups the stand
  and Return to stand use.
- `placement.overlapObb` becomes EN12's one call; `ghost.apply` becomes EN10's.
- **Still open from step 5:**
  - the mineral-vein keep-out;
  - pitch and roll for parts that may lie down;
  - a "crew in the footprint" check, which only covers bodies with colliders
    (`overlapObb` sees the Astronaut and CrewBody capsules);
  - the depot stocking the kit (M3: done in step 7, §11).
- **Machines and power (M6, N4):** a structure whose parts carry electronics
  becomes an anchored assembly with a 10 Hz power step. Static prefabs stay
  for slabs and sheds.

## 9. Step 6: the Build Stand (L1, L2, L4; `scripts/craft_stand.lua`)

### The stand (L1)

- **A BASE part** (`parts_base` `stand`, prefab `BaseStand`, 0.4 t, $650):
  - a 0.9 m steel base plate bolted down at its corners;
  - a collar with a ground sleeve, a jack gearbox and its crank;
  - a telescoping column under a 0.9 m deck with four rubber pads. The
    column has a yellow band every half metre.
- **Built 1:1** in `tools/gen_base_parts.py` (`write_stand`). The deck and its
  column are one child node, `Deck`, and its colliders ("Deck Wall N") are
  that node's own children. Moving the Deck moves them.
- **The deck height is the part's `h`** (0.5–4.0 m in 0.1 m steps; 1.0 m
  when it is placed, from `parts_base` `fields`).
  - `lo = true` means it is lowered to 0.28 m after letting a wheeled craft
    down.
  - When the stand's node lands, the Deck child is put at `h − deckOff − seat`
    (`craft_stand.spawned`).
- **Why 0.9 m, not the addendum's 1.2 m.** A small rover's tyres stand 0.5 m
  either side of its centre line, so a 1.2 m deck would sit under their
  corners. A 0.9 m deck fits between them.
- **Placed with the Build Kit** like any BASE part: on the ground (on the grid,
  with a footing on a slope) or on a Pad Plate's deck. The undo ring and
  Deconstruct work on it, but **not while a craft is on it**:
  `field_builder.removalBlocked` asks the part's script (`canRemove`), and the
  menu row greys out with the reason.
- **Parts with behaviour, in general.** A `parts_base` entry may name a
  `script`. `structures.lua` calls that script's `spawned(rec, part, node)` as
  the part's node lands and `gone(sid, uid)` as it goes. It also adds
  `partState` / `setPartState` (`rec.st[tostring(uid)]`) and `respawnPart`.
  The tower (step 7) and machines (N4) use the same hooks.

### A craft on the stand (L2)

- **The source is the VAB's library** (the stand's menu: Truck a saved craft out (as is)…; the editor, §10, is the main way).
  These are the launch-format blueprints `builder.make_blueprint` writes
  (`user://library/<slot>/<slug>.json`). `craft_stand.readDesign` decodes
  them the way `builder.libDecode` does.
- **The price** is the hull's (the VAB's `build_cost`), plus **one truck**:
  shipping at 10 % + $50 on the whole hull (N1). It is charged when the craft
  goes on, through `company.spend`, and the ledger says "on a Build Stand".
- **Kept in the save:**
  - the blueprint under its own key, `stand.bp.<sid>.<uid>` (the save holds
    four tables deep; a structure record is already three);
  - the stand's part state: `{ s = "built"|"held", key, name, n, cost, ship,
    total, t, by, ret, wheeled }`.
- **Where it rests:**
  - its centre of mass (the parts' masses in x and z) over the deck's centre;
  - its front along the stand's front (vessel_spawner's `craft_front` rule:
    a cockpit's nose, then a rover body, a seat, the command part);
  - its **belly**, the lowest part over the deck (`bounds`), 2 cm over the
    pads.
- **The stand raises itself to what the craft needs.** Whatever hangs below
  the belly (tyres, gear, legs) must clear the ground by 10 cm, plus however
  far the ground under the craft's footprint rises over the stand's base (five
  rays, `needFor`). A craft that would need more than 4 m is refused, and so
  is a craft nothing can command or one that rests on nothing.
- **Drawn, not simulated.** The parts are display copies: `spawn body = false`,
  the VAB's `prefabs/vis/` variants where they exist. They hang under one
  `StandCraft` node parented to the planet at the vessel's pose. There is no
  body and no script, so **an idle craft on a stand costs nothing a tick.**
- **Clear the stand** gives the parts back: all of it within a minute, the
  price after (`base_economy.deconstructRefund`). A craft that came back to
  the stand (below) returns what recovering it was worth.
- **The deck's height** steps from the menu (Raise / Lower the deck, 0.1 m a
  click). It never goes under what the craft on it needs. (The world's menu
  has no drag slider; Alt+scroll is not bound yet.)

### Commission, release, return (L4)

- **Commission** (Engineer, a job of 4 s + 0.15 s a part, capped at 20 s):
  - **The checks:** something aboard commands it (a pod, a seat or a probe
    core), the stand is in the scene, and nothing is in the craft's box from
    its belly up (`placement.overlapObb`, past the stand and the ground).
  - **The craft is made by the fleet's own rebuild path.** A `Vessel` root is
    spawned at the pose, the blueprint is handed over as
    `dock.handoff.<id>` (with `flown = false, held = true`), the parts are
    spawned as its children, then `assembly.rebuild` and
    `assembly.setAnchored(true)`.
  - **It is seated by its real colliders:** the RigidBody half-extents
    replace the blueprint's boxes for the belly.
  - **It is a normal vessel**, with its controller, fuel, charge and seats.
    It is **held**: each frame while the crew is within 600 m, its
    body-relative pin is re-applied (`assembly.teleport`), as the spawner
    does for a pad.
  - **The fleet board leaves it to the stand.** The handoff's `held` sets
    vessel_controller `leftPad = false` and `standHeld = true`, so
    `fleetSync` skips it. On a reload the stand puts it back (`spawned` sees
    `s = "held"`), so it is never built twice. `standHeld` also keeps
    flight_ops from taking the stand's radius for the launch pad's.
- **Release:**
  - **A craft on wheels or gear is jacked down.** The craft and the deck go
    down together at 0.35 m/s, `vessel_spawner.seatShift` measuring how far
    is left (rays under its lowest parts, looking past the craft, the crew
    and the stand). The deck stops at 0.28 m and the craft goes on to its
    wheels. Then the stand is made again lowered (`respawnPart`: its
    colliders are made down there), and `releaseClamps` lets it go.
  - **Anything else is let go where it stands** (a rocket lifts off the deck).
  - **SPACE in the cockpit** releases a held craft as it releases a pad's
    clamps. On wheels, the stand then drops its deck away.
  - `releaseClamps` skips the rover's roll-out beside the pad
    (`r2Rollout`) for a craft from a stand: it is already on its wheels.
  - Released, it is a craft in the world, and the fleet board keeps it.
- **Return to stand** (the craft's own menu; Engineer; a 4 s job): the craft
  must be landed, stopped and empty, with any of its parts within 3 m of an
  empty stand's deck.
  - It is put back on the stand as an uncommissioned craft. Its records go
    through `electronics.packRecord`, keeping its fuel, charge, wear,
    groups, controls and the parts it lost.
  - Its worth is `recoverValue` (85 % of its parts by their health); that is
    what Clear pays for it.
  - The live craft goes, and so does its fleet record (`flight_ops.forgetNodes`).
  - Commission makes it a craft again, with the fuel it had. This is the
    field Repair Bay's first half; refits come with L3.

### Cost

- **An empty stand, or one with a craft not commissioned:** static prefabs
  and display nodes. `craft_stand.update` returns at once when nothing is
  held; the menu's provider registration is looked up at most once a second.
- **A held craft:** the vessel's own costs (a dormant controller), plus one
  `assembly.teleport` a frame while the crew is near.
- **A release** casts its `seatShift` rays every 0.25 s while it comes down.
- The probe's numbers are in step 6's NOTES.

### The hook for L3 (step 17: the detail editor at a stand)

- `craft_stand.framePose(sid, uid)` is the deck as a body-frame pose:
  `{ G, R, U, F, h, top }`. `build_host.enter{ frame = stand }` puts its
  BuildFrame there.
- `craft_stand.blueprint(sid, uid)` is the craft to load into the builder.
  `putOn(sid, uid, bp, opts)` takes the edited one back (L3's diff charging
  goes in `opts.paid`).
- `bp.kind` rides in the blueprint untouched, through the library, the stand
  key and the handoff.

### Tests and the probe

- `luajit solar/tests/smoke_stand.lua` (60 checks) runs on the real
  `parts_registry` rover, with the real `structures`, `field_builder` and
  `base_economy` and a stub craft controller.
- `tools/perf/buildkitprobe.sh <engine> stand` (PATCHES=funds.patch) runs the
  whole flow in the engine:
  1. the VAB's rover is saved to the library;
  2. a stand is placed with the kit (its deck where its record says, a ray
     landing on it);
  3. the rover goes on from the stand's menu (charged, drawn), and the deck is
     lowered to what it needs;
  4. Commission (anchored, six parts, held within 2 cm while the planet moves,
     off the fleet board);
  5. Release (jacked down onto its wheels, the stand lowered, the clamps off);
  6. the rover is boarded, driven 14 m off and backed up to the stand;
  7. Return to stand from the rover's menu;
  8. commissioned again, saved and reloaded (held on its stand again, once);
  9. released once more.

  Look for `BK PASS|FAIL` and `BK RESULT stand`.

## 10. The editor at a stand (L3 pulled forward; work/standeditor/PLAN.md)

**Build here** is the stand's first menu row (Engineers; any stand that isn't
holding a commissioned craft). It opens the real VAB overlay (the camera, the
parts column, the inspector, staging, the CHECK, symmetry, undo, the library)
on the deck. **ESC** with nothing left to back out of, or LEAVE, saves the
work and steps back to the Engineer. "Truck a saved craft out (as is)…" stays
as the quick path.

### The host (`build_host.enter{ stand = { sid, uid } }`)

- **The BuildFrame is a child of the stand's PLANET**, not of the VAB. It is
  posed every frame from `craft_stand.framePose` (body frame: planets only
  translate), so nothing world-space is kept.
  - +Y is the stand's up and +X (the builder's craft front) is the stand's
    front (`craft_stand.vesselAxes(R, U, F, 1, 0)`), so a rover built facing
    the builder's front faces the stand's front when commissioned.
  - The builder's floor (frame y 0.11) sits at `deck + clear − fo`, where `fo`
    is how far the craft's belly sits over its lowest part
    (`craft_orient.floorOffset`). A rover built with its tyres on the floor
    therefore has its body resting on the deck, as Commission will seat it.
- **The deck raises itself.** At most twice a second, only when the craft
  changed and never during a drag, the host asks `craft_stand.needFor` (which
  counts the ground under the footprint) and raises the deck to that height
  (`setHeight`). It never lowers it while building. Past 4 m the CHECK blocks
  (S6).
- **No VAB dressing:** no lean, no fade (gated on `hostKind`, not on whether
  `vab_fade` exists).
- **The world's numbers:** `builder.hostContext().world` gives the stand's
  world (g from μ/r²), so TWR, Δv, jets and the air are read for here.
- **The astronaut** is pinned where they stood and stays **in view**. A hit
  (`crew.lastHit`) saves the work and exits.
- **The VAB's keys are untouched.** `shipyard.current / blueprint / lockerPlan
  / site / kit` are stashed on entry and put back on exit. The autosave goes
  to the stand (`craft_stand.saveWip`), never the library; SAVE / Ctrl+S
  still files the craft in the library.

### The camera (`builder_camera`)

- **The floor** (`floorY`) is 0.3 m over the stand's ground plane, not the
  deck.
- **The world clip** (`setWorldClip`):
  - a 0.25 m spherecast from the pivot toward the camera stops it 0.1 m
    short of a hill, a shed or a craft;
  - a camera still inside rock (`terrain.query`) is brought back along the
    line;
  - the drawn distance is smoothed in the frame (in at once, out at
    exp 12/s, 0.3 m hysteresis), and the player's zoom is kept.
- **The entry framing** is from where the Engineer stood, looking at the
  deck.
- **Outdoors** (a stand or a Base Hub; playtest 11-10, §28): the floor is the
  terrain itself, not a plane. The pivot never sinks into the ground, the
  orbit stops on it, the camera never ends inside a builder part, RMB orbits
  the selection or the pivot, MMB pans along the ground, the wheel eases,
  and HOME recentres.

### Orientation (`scripts/craft_orient.lua`, shared with the VAB)

- **A pure rulebook:**
  - `kindOf`: a set `bp.kind` wins, then craft_mode.autoOf;
  - `upAxis`:
    - a rover: the normal of its wheel plane, away from the wheels (a bike:
      square to its wheel line);
    - a plane: its gear plane, else its wings;
    - a rocket: the command part's +Y;
  - `noseAxis`: a cockpit's +Y, then a rover body's or a seat's +X, then the
    command part's;
  - `basisFor` gives nil within 5°, so a craft that already stands right is
    left alone.
- **`cmd("orient", { axis = "x"|"y"|"z", sign } | { auto } | { wheelsDown } |
  { noseLevel })`** is one history step:
  - it turns every part about the craft's centre of mass;
  - then sets the lowest box on the floor, centred on it.
- **Where it is in the UI:**
  - toolbar row 2: ORIENT ↻X ↻Y ↻Z AUTO (Shift: the other way);
  - the CRAFT tab: CRAFT KIND (AUTO, ROCKET, PLANE, ROVER, PROBE, STATION,
    BOAT → `bp.kind`) and WHEELS ▾, NOSE →, AUTO;
  - the CHECK's A3 has a LAY IT LEVEL fix.
- **OPEN at a stand** turns the craft it opens AUTO and says so. Ctrl+Z keeps
  it as saved.

### The site in the CHECK (`checkHook("stand", craft_orient.standRules)`)

`ctx.stand` is filled by the host at most twice a second. `ctx.site` reads the
release: a craft on wheels as the runway, anything else as the pad.

| Row | Severity | When |
|---|---|---|
| S1 | warn | the ground under the stand tilts more than 3° (rocket) or 12° (rover) |
| S2 | note | built on another world: g and the air |
| S3 | warn | a craft on wheels: something within 10 m ahead (spherecast; a structure is named) |
| S4 | warn | a craft that lifts off: a structure within 6 m |
| S5 | warn r0 | the Engineer in the craft's box: COMMISSION refuses |
| S6 | block | the stand can't hold it (`needHeight`'s sentence) |
| S7 | block | off the home world with parts added |

### Money (`craft_stand.commitQuote` / `payFor`)

- **Nothing is charged while editing.** COST shows the diff since the last
  commit, and a part that would take it past the budget is refused at
  placement.
- **On every exit** (ESC, LEAVE, COMMISSION):
  - parts added are charged once, with one truck (10 % + $50);
  - parts taken off come back by the deconstruct rule: all of it, their share
    of the truck included, within a minute of the last commit, otherwise the
    price;
  - a part whose price changed counts as off and on again;
  - no change costs $0.
- **What is paid for** is kept beside the blueprint (`bp.committed`, uid →
  cost). The hint says what was charged.
- **Off the home world** `payFor` refuses added parts (the step-13 hook).

### COMMISSION

The toolbar's LAUNCH reads COMMISSION ▸.
1. `launchCheck`: a stand block refuses, and S5 refuses; warnings arm the
   two-press confirm.
2. The craft is saved on the stand, the diff is charged, and the overlay
   comes down.
3. `craft_stand.commission` follows at once: the same held craft as step 6.

### Cost

- The editor adds `pin_frame` (one `partPose`) a frame, one spherecast and up
  to seven `terrain.query`s for the camera, and the site's few rays at
  ≤ 2 Hz.
- An idle WIP on a stand is the same static display copy as step 6: nothing a
  tick.
- Exit destroys the frame and every part under it.

### Tests and the probe

- `luajit solar/tests/smoke_stand_editor.lua` (74 checks) covers orientation,
  deckFit, commitQuote/payFor, WIP, the S rows and the host's flow on a stub
  engine.
- `tools/perf/buildkitprobe.sh <engine> standedit` (PATCHES=funds.patch,
  `tools/perf/standeditprobe_modes.lua`) writes pictures se1..se12 and logs
  `BK RESULT standedit`.

## 11. Step 7: the Base Station Tower and the bases (M1–M3, M5, M8–M9)

A **base** is a Base Station Tower and every structure within 150 m of it.
The home base is base #0: the spaceport, with the Tracking Station as its
tower. Nothing in `base.*` changes shape, and base #0 isn't stored anywhere.
Every other base is founded by placing a tower with the Build Kit.

### The parts (`parts_base`, `tools/gen_base_parts.py`)

| Part | Prefab | Real size | Mass | Price | What it does |
|---|---|---|---|---|---|
| Base Station Tower | `BaseTower` | 12 m galvanised lattice mast, 1.2 m square, on a 2.6 m base frame; a grated platform at 11 m; a 3 m dish on a yoke, tipped 35° up; a Yagi, a whip and an obstruction light; an equipment cabinet and a ladder | 1.5 t | $4,000 | founds a base; a relay (below) |
| Solar Array | `BaseSolar` | two 1.2 × 2.0 m modules on a single-axis tracker, 1.35 m up | 0.18 t | $1,800 | 3 EC/s in full sun, tracking about its +X; nothing in a planet's shadow |
| Isotope Skid | `BaseIsotope` | four Isotope Cells in a caged rack on a steel skid | 0.3 t | $10,000 | 2 EC/s, day and night; behind the Isotope Cell's research (`research.ALIAS`) |

- All three are `onDeck`: they stand on the ground or on a Pad Plate's deck.
- They are built 1:1 like the step-4 modules. Their collider boxes are
  `Wall N`: the tower's frame, mast, cabinet and platform.
- Nobody climbs the tower before EN2, and there are no kinematic interior fakes.

### Founding and naming (M1; `scripts/bases.lua`, `scripts/base_tower.lua`)

- **Every tower part in the structures is a base.** `base_tower.reconcile`
  runs whenever `structures.version` or `bases.version` changes. It founds a
  base for a new tower and keeps the base's id on the tower's bp entry
  (`base`).
- **The name field.** When the tower the player just placed founds its base
  (it matches `field_builder.lastPlace`), a name field opens:
  - the `BaseNamePrompt` node goes under the Ship HUD and is drawn with
    `ui.make`;
  - the default is "Outpost <n>";
  - **Found it** or Enter keeps what was typed; **Keep …** or Esc keeps the
    default.
  - While it is open, the kit's keys and clicks wait (`field_builder` asks
    `base_tower.prompting()`).
  - A focused `Field…` node keeps WASD, the belt's keys and the stranded
    card's Enter for itself (`planet_walker`, `tool_belt`, `item_hand`,
    `flight_ops`). The kit's part search had the same problem.
- **Renaming** is on the tower's menu ("Rename the base") and in the Tracking
  Station's BASES detail.
  - Names are trimmed and clipped to 32 characters.
  - Two standing bases never share a name.
- **Taken down.** A tower that is deconstructed, or whose placement is undone,
  marks its base `down` and keeps the record under its name. The minute's
  undo, or a redo, stands the same base again. A redo's copy of the part has
  no `base` id (it was copied before the base was founded), so the base
  standing down at that tower's sid/uid is reused.

```
bases.list, bases.seq
bases.<id> = { id, b, x, y, z (the tower's ground point, body-relative), n, t, d, by, sid, uid, down }
```

### The rules (M8, and the addendum's spacing)

- **Towers stand 300 m apart along the ground** (twice a base's 150 m, so
  two bases never overlap), the spaceport's Tracking Station included
  (`base_tower.placeWhy`, `bases.SPACING`). This is the red ghost's reason:
  "14 m from Far Side's tower: towers stand 300 m apart (286 m further
  away)". (Until playtest 11-09 it was 1 km: on a 922 m world no tower could
  stand within a kilometre of home, so to a player it could be placed
  nowhere; §19.)
- **No building within 30 m of a vein being mined.**
  - A vein is "being mined" once a cut has paid ore from it. That sets
    `veins2.<body>.<patch>.w[<vein>]`, which is saved.
  - A vein whose outcrops were broken also counts.
  - The check is `mineral_field.workedVeinNear`, in `field_builder.validity`.
- **No dig reaches under a structure.**
  - `base_tower` syncs one `base_facilities.setGuards("struct:<sid>", …)`
    owner per structure, on every records change.
  - Each part's guard box runs from 2 m under its footing to 1 m over its
    top, 0.5 m wider than its footprint.
  - The laser, craters, the drill and the surveyor already ask `digClamp`.
- Building inside the home base's footprint and building under water were
  already refused in step 5.

### The relay (M2; Q20 tiered)

`comms.solve` adds `base_tower.commsNodes(by, bodies, E)` after the beacons.
Each standing tower is a transmitter whose antenna is 11.6 m up its own up
axis. It is pinned to its world (`frame`, `rx..rz`), so the solve places it
against its single read of the bodies.

| Tower | Node | What it means |
|---|---|---|
| Unpowered (a mast) | `E.beaconNode`: `any = relay = 1500`, `beacon = true` | a beacon-class relay: it needs a path home through other relays. A probe core hears it from 387 m. |
| Powered, home world | `home = true, power = COMMS.station` (4.0e5) | a **second home root**: `solveNetwork` already gives every `home` a cost of 0 |
| Powered, another world | `any = relay = 4.0e5`, `landed = true` | home only through a path to the real home. Off-world building is refused until step 13. |

- `statusOf("t:<base id>")` gives a tower's link.
- `relayStats` counts towers as ground relays.
- `relay_sets` and the coverage treat a tower as ground (`tower`). It never
  makes the coverage "moving".
- `noLinkWhy` names the **nearest** home root.

### Power (step 7's rule, replaced by the base grid in step 8)

Step 7 counted only the sources on the tower's own structure, with no
storage. Step 8 (§12) replaced that: `base_tower.power(bid)` now reads the
tower's base grid (`base_grid.towerPower`), and `sourcesOf` is gone.

### On the map and in the station (M5)

- **`base_tower.bases(opts)` is the hook.** It returns the home base #0
  first, then each tower's base with:
  - its tier, power, link, path, why;
  - its world's ground coverage;
  - its structure count within 150 m (left out with `brief`);
  - when it was founded, and its tower's sid/uid.

  The station's rebuild can show this list as it is.
- **The map glyph** is `orbit_map.map_bases` (`mapBases`):
  - a beacon's ring and mast, bigger, with a small dish ring off the mast head;
  - a second ring round the foot when it is powered;
  - teal with a path home, red without;
  - the label "Far Side · ground station".
  In STATION mode the station draws the icon and tag itself, so the glyph
  is drawn without its label.
- **The station** (docs/tracking-station.md):
  - `fleet_view` adds a BASES group (before STRUCTURES) with one entry
    `"o:<base id>"` per tower's base (kind `outpost`), at the tower's ground
    point, body-relative. Its situation line is "base · ground station" or
    "base · mast".
  - The SELECTED card (`tracking_station` `base_card`) shows the tower's tier
    and power, its link, its world's ground coverage and when it was
    founded, with Rename (`base_rename`, through `bases.rename`) and Focus.
  - "Target" is not offered, because `targeting` has no ground-spot kind yet.

### The 10 % unlock (M3)

- `research.TECH.buildkit`:
  - `grantOnly`: it has no price and can't be bought;
  - `permGrant = { "relay_net", 1 }`: a save already past the goal has it.
- The Relay Network's 10 % goal grants `{ "probe", "buildkit" }`. A goal's
  `grant` may be a list.
- Ops says "You can hear us from a tenth of the ground. Time to build
  somewhere else." through `caption`.
- From then on:
  - the Depot stocks the kit (`items` `shop = true, tech = "buildkit"`;
    `shopList` hides it until the tech is open);
  - every Engineer is issued one the next time they are at the base (in it,
    or on foot within 400 m of it);
  - a save whose Engineers already had a kit keeps it.
- Past 10 %, the objectives card's ground-coverage hint points at the far
  side.

### Cost

- An idle tower is a static prefab like any placed part.
- `base_tower.update` compares two version numbers a frame; `bases` has no
  update.
- The solve's call is a cached list with power memoised for 2 s.
- The probe's numbers are in step 7's NOTES.

### Tests and the probe

- `luajit solar/tests/smoke_tower.lua` covers:
  - the parts;
  - `bases`: founding, names, spacing, the 150 m membership, down and up, the
    save round trip;
  - `base_tower`: founding, the name field, the undo and the redo copy;
  - power: none, an Isotope Skid, solar day and night;
  - the three relay tiers on the real `solveNetwork`, including a far-side
    probe that goes home through a powered tower, but not through a lone
    mast unless beacons chain it;
  - M4's row (below);
  - the dig guards, the idle cost, the research grant, the Depot and the
    goal's grant list.
- **M4, measured:** on a smooth 800 m world the station alone covers 6.5 % of
  the ground, and with a powered far-side tower 14.0 %. The tower doubles
  coverage, as the addendum guessed, but one outpost does not reach 25 %.
  That still needs beacons from both stations.
- `smoke_base_build` counts seven BASE parts.
- `tools/perf/buildkitprobe.sh <engine> tower` (PATCHES=funds.patch) covers:
  - the locked kit, its grant and issue;
  - the far side, with the rails warped on until the sun is over it for the
    pictures;
  - two plates and the tower: the base founded and the name typed;
  - the mast tier, then the skid and the station tier, and coverage up;
  - a second tower refused, the menu, the station's list, the map glyph, a
    dig refused, the cost;
  - save and reload.

  Pictures are t1..t7; the other modes call `BK.unlock()` first.

## 12. Step 8: the base grid, the Power Cable and the Shield Wall (M6, B9b, M6c)

Q19 is settled: **every structure within 150 m of a base's tower shares one
grid automatically; a Power Cable joins grids beyond that.**

### The parts (`parts_base`, `tools/gen_base_parts.py`)

| Part | Prefab | Real size | Mass | Price | What it does |
|---|---|---|---|---|---|
| Battery Bank | `BaseBattery` | 2.4 × 1.2 × 2.2 m outdoor battery cabinet on a skid: two pairs of doors, a thermal unit with its fan on one end, a DC junction box on the other | 2.6 t | $3,500 | stores 4,000 EC for its grid, charged at 92 %; arrives half charged |
| Shield Wall | `BaseShieldWall` | 2 × 2 × 0.5 m precast concrete block (2.3 t/m³): chamfered arrises, a shear key, two lifting loops, a stencilled plate | 4.6 t | $1,100 | `shield.k = 0.05`: lets 5 % of a core's dose through, by its record |
| Power Cable | `BaseCableDrum` (the card's drum) | 4-core 16 mm² steel-wire-armoured cable, 32 mm across | 1.4 kg/m | $3 a metre | a run from one placed part to another, up to 1.5 km (three 500 m drums spliced) |

- The bank and the wall are `onDeck` parts like the step-7 sources, with
  collider boxes (`Wall N`). The wall is one box; nobody hides inside it.
- The Isotope Skid gains `rad = { rad = 0.002, omni = true }`: its four cells
  in their cage give a weak field all round (about 0.3 % of a lethal dose an
  hour at 4 m, 2 % at the cage). That is the first ground source; step 11's
  ground reactors add cones.
- The addendum gave the wall 2.4 t; 2 m³ of ordinary concrete is 4.6 t, so
  the part weighs that.

### The grid (M6; `scripts/base_grid.lua`)

- **Members.** `buildGrids` is a union-find over structures. A structure
  with any part within 150 m of a standing tower joins that tower's base,
  and a cable joins the structures at its two ends. A grid is a connected
  set. A set with nothing that makes, stores or draws power is no grid.
- **The model** (`gridModel`):
  - sources: Isotope Skids (`rtg`, their EC/s always) and Solar Arrays
    (`solar`);
  - loads: each tower's 2 EC/s, in base order (and any part with
    `power.kind = "load"`: none yet, because the shed and the hab are not
    lived in);
  - storage: the Battery Banks, one pool. Every bank in a grid sits at the
    same state of charge.
- **The light is periodic.** These worlds don't turn, so a spot's day is its
  world's year. The year (from the world's conic round its sun) is cut into
  96 slots, anchored once on the agency clock (`grid.a0`). Each array's output
  in each slot is worked out once (`slotLight`: the world moved along its
  conic with `electronics.kepler`, then `electronics.solarOutput` there) and
  cached by the array's pose. The profile is rebuilt only when the grid
  changes.
- **The store is exact** (`advance`). Within a slot the supply is constant,
  so the charge is a straight line, clamped:
  - a surplus charges at the banks' efficiency up to full;
  - a deficit drains to empty, then the loads are shed (towers in base order)
    until the supply covers them again;
  - so one call of any length lands where any number of small calls do
    (to 1e-6 in the smoke test), the pattern of step 3's thermal `advance`;
  - a long step skips whole years: a year that comes back to where it began
    repeats, and one that never touches full or empty adds the same every year
    until it would.
- **Dust and sky on the panels (G4, scenarios2 PLAN §2).** Every solar
  piece delivers its clean light times `electronics.soilFactor(dust, sky)` =
  (1 − 0.92 · dust) · sky.
  - **sky** (`skyFactor`): cloud cover takes up to 55 % of the light, a dust
    or ash storm's dust aloft 35 % more and its haze 10 %; never under 6 %
    (a storm leaves a trickle).
  - **dust** (`dustStep`, exact for a fixed weather: dd/dt = dep·(1 − d) −
    clear·d): a dust storm lays it (0.25 % of the cells a second at full
    strength), rain washes it (2 % a second), a dry wind over 6 m/s scours a
    little; snow does neither. On top, the age dust kit_paint gives every
    exterior piece (since it was placed or last wiped): 30 % of it sits on
    the cells (a dry world's 0.55 cap costs 15 %).
  - **Where the weather is read:** a structure within 3 km of the camera on
    the camera's world reads `weather.current()`; farther off, its dust
    stays as it was and its sky reads clear.
  - Each panel's factor is quantised to 0.02 and the grids are rebuilt only
    when one steps (the profile and the network's flows are the light times
    it). Saved: `grid.dust` (each panel's storm dust) and `grid.wipe` (when
    it was last wiped).
  - **An Engineer wipes a panel:** its menu reads **Cells** (its share of
    output, the dust, the sky) and **Wipe the panel** (10 s, Engineers only),
    which clears both kinds of dust. The terminal's POWER page has a
    **Panels** row (the grid's mean share, dust and sky).
  - Probes: `soilInfo(sid, uid)`, `soilOfStruct(sid)`, `setDust(sid, d)`,
    `wipe(sid, uid)`, `SOIL.n_steps`. Test: `tests/smoke_panel_dust.lua`.
- **When it is solved.** On change (structures, bases or cables) and every
  2 s, never in a frame. A question asked right after a change
  (`towerPower`, `gridOfStruct`) rebuilds on the spot.
- **The catch-up.** On load, the grids advance from `grid.a` (the agency
  clock of the last advance) to now in one step, capped at 30 game days.
- **Save:** `grid.a0`, `grid.a`, and `grid.e = { ["sid:uid"] = EC }` for each
  bank.
- **The tower** (`base_tower.power(bid)` → `base_grid.towerPower`) is a
  ground station while its load is served and a mast while it is shed.
  `sourcesOf` is gone. The comms solve, the name field, the tower's menu
  (Power, and a new Grid row) and the station read it.
- **`bases()`** gains, per base: `grid`, `draw`, `stored`, `cap`,
  `gridStructures`, `cables`, `towers`, `solar`, `rtg`, `short`, a one-line
  `gridLine`, and `crew`. `crew` counts members on foot within 150 m of the
  tower, or at the spaceport for base #0.
- **The station's base card** (`tracking_station` `base_card`) shows the
  tower's tier and draw, a CRT block (GRID IN / OUT EC/s, BATTERY %, and how
  long the battery lasts with no sun), and the grid line with the crew count.
  Nothing else in the station changed.

### The Power Cable (B9b; `scripts/base_cable.lua`)

- **Laying it** is the Build Kit with the drum in hand. The first click on a
  placed part makes the cable off there. The Engineer walks or drives the
  run out, with a green or red preview line drawn from the end along the
  ground. A click on a part of another structure lays it, billed by the metre
  plus shipping (`base_economy.quote`), with its mass on the hint.
- **The rules:**
  - both ends on placed parts of two different structures not already on one
    grid;
  - at most 1.5 km along the ground;
  - on the home world.
- **The drawing** is one mesh per cable (`mesh.build`, an 8-sided tube in the
  rubber set), parented to its planet and spawned while the focus is on that
  world. It leaves each part's side 0.6 m up and **settles** (playtest
  2026-11-06) along the great circle between its ends:
  - **A catenary where it hangs free.** With the pull it is laid with
    (`PULL`, 30 N: a hand's pull) and its weight (1.4 kg/m × the world's
    gravity, `mu / R²`), every free span is y'' = √(1 + y'²) / a with
    a = H / (λ g), about 2.2 m at 1 g: from a part's side it
    meets the ground ~1.5 m out, tangentially; a span too short to touch down hangs free.
  - **Lying on whatever holds it up where it touches:** the ground, sampled
    from the terrain's distance field every 0.5 m along its whole length
    (`sampleGround`; at most ~3,000 samples on a 1.5 km run), the boxes of
    placed parts it crosses (a Pad Plate's top, a wall; not its own two
    ends; `obstaclesFor`, read from the records), and the rocks that have
    settled round the crew when it is laid (`rocksAlong`, kept in the
    record). It never goes under any of them.
  - **The solve** (`settle`) is projected Gauss-Seidel with over-relaxation
    on fixed stations 0.25 m apart (at most ~2,000), coarse to fine: an
    obstacle problem, exact to 2e-5 m, about a millisecond for a 150 m
    cable and a few for the longest, run ONCE when the cable is laid, when
    the ground under it is dug (`groundChanged`, forwarded by flora_field,
    re-sampled after 1.5 s of quiet) or when a part is set down on or lifted
    off its line (the structures' version, a key of the boxes it lies on).
    Never per frame: the result is one static mesh, thinned to 4 mm
    (`thin`). A GPU solver would only pay for a simulation run every frame,
    which a cable lying still never needs.
  - A record from before the settle (no `v`) has its ground every 3 m
    between the old touchdowns and settles on that.
- **Taking it up:**
  - Ctrl+Z within a minute takes it up for a full refund (a step in
    `field_builder`'s ring, through `pushHistory`), and Ctrl+Shift+Z lays it
    again.
  - Right-click either end part → **Take up the cable** (3 s) gives the price
    back past the minute, with the fee kept (`deconstructRefund`).
  - A part taken down takes its cables up with it, on the same rule.
- **Records:** `cable.list`, `cable.seq`,
  `cable.<id> = { id, b, a = { sid, uid }, z = { sid, uid }, len, h = { radius … }, v, rk, t, d, by, paid }`
  (`h` the ground's radii every 0.5 m between the ends, `v` = 2 since the
  settle, `rk` the rocks it lies over: `{ x, y, z, r }` body-relative).
- **Line losses** came with S5 (§16): every cable has a type, a rating and
  P²R/V² losses; breakers, transformers and poles are kit pieces.

### The Shield Wall (M6c; `scripts/base_shield.lua`)

- **The rule is step 3's.** What stands between a core and a crew member is
  counted **by part record**, never by a ray hitting a solid. A placed part
  with a `shield` is an oriented box in its body's frame:
  - `blockersOn(body, a, b)` returns the boxes near a segment;
  - `wallFactor` returns the product of their `k` through
    `thermal.shieldFactor`;
  - one wall lets 5 % through, two 0.25 %.
- **Crew on foot only.** A4 traces the terrain only for crew on foot. A
  seated member is behind their own craft's parts, which the craft's pass
  counts. The walls are added to the on-foot path:
  - **Craft reactors:** `vessel_thermal.radiation` multiplies the rate of
    each member on foot in a core's cone by `wallFactor`, the core and the
    member placed against one body read, before the terrain ray.
  - **Ground sources** (`base_shield.pass`, twice a second, only while one
    exists): each member on foot on the source's world gets a distance test,
    then the inverse square from the part's `rad`, the walls, and the terrain
    ray. It is written to the crew record every 2 s through `crew.addDose`.
- **The draw agrees with the dose by construction.** With the kit open,
  `base_shield.drawFields` draws:
  - every ground source within 80 m (an omni source as three rings, where the
    field falls to 1 %, 0.5 % and 0.2 % an hour);
  - every live craft core within 120 m, the VAB's way (eight lines, three
    rings). `vessel_thermal` publishes them body-relative.
  - a VAB marker on each member on foot that a pass reached: red in the
    open, amber behind shielding.

  The marker's colour is read from the numbers the dose pass just wrote
  (`noted`), so the draw and the dose cannot disagree.

### Cost

- **Per frame:** `base_grid` compares three version numbers. `base_cable`
  checks the structures' version and runs a 1 Hz spawn pass. `base_shield`
  costs nothing with no source and the kit closed.
- **Every 2 s**, the grids advance: a few multiplies per slot crossed. At 1x
  that is none or one slot; at 1000x about a hundred.
- **On a change**, the grids are rebuilt: `buildGrids` is parts × towers, and
  the profiles come from the cache. The probe's numbers are in step 8's NOTES.

### Tests and the probe

- `luajit solar/tests/smoke_base_grid.lua` covers:
  - the parts;
  - membership (150 m, a cable, two bases on one cable);
  - the year from the conic, and an array's year of slots;
  - one big step against thousands of uneven small ones (3.7 years; a short
    grid that sheds; 20 days with whole years skipped; a straight year);
  - night storage, with a bank and without;
  - the scene half: the solve only every 2 s, the catch-up on load, the
    charge saved, `bases()` with grid and crew;
  - cables: the geometry (ends on the parts' sides, the hang, the run on the
    ground), the rules, the bill, the ring's undo and redo, a part taken down
    taking its cable up, the save.
- `smoke_thermal` adds the walls: their boxes by record, one and two walls,
  past the wall's end, another world, the ground-source pass, the draw's
  numbers, and `vessel_thermal`'s pass with a craft core on its side and a
  member on foot behind two walls.
- `tools/perf/buildkitprobe.sh <engine> grid` (PATCHES=funds.patch; the mode
  is `tools/perf/gridprobe_modes.lua`) covers, on the far side:
  - a tower, two Solar Arrays and a Battery Bank on one grid;
  - the night under 50x warp, a ground station all night;
  - the station's card at night;
  - an Isotope Skid's dose in the open and behind a Shield Wall;
  - a second base 1.05 km on, with a cable walked back to the first: one grid;
  - the costs, save and reload.

  Pictures are g1..g7.

### Open for later steps

- **Off-world grids.** A moon's light needs its own slots, because its
  sunlight follows its own orbit. Off-world building is step 13's.
- **Reactors as ground sources** (step 11) join the grid's sources and
  `base_shield`'s cones; the rulebook already takes them.
- **Loads for the shed and the hab** come once they are lived in (EN1/EN2).

### Step 9: the Engineer's rules and perks (J6; docs/crew-and-items.md §2.6.1)

- **Gates in the actions.** Placing any part (`field_builder.validity` / `place`), laying
  or taking up a Power Cable (`base_cable.layerWhyNot`) is refused to anyone but an
  Engineer, with the reason ("Engineers only"; for a Shield Wall "a Shield Wall is set by
  an Engineer"). The kit itself was Engineers only from step 4.
- **Cable price.** A level-2 Engineer lays cable at ×0.9 a metre, level 3 at ×0.8
  (`quote(L, by)`; shipping unchanged).
- **Battery Bank.** A bank set up by a level-2 Engineer charges at +3 points (level 3: +5),
  capped at 99 %. The bonus is written on the part as `effk` when it is placed, so the
  grid's closed-form step stays exact: nothing about it changes with who is standing near.

## 13. Sandbox S1 and S2: habs from pieces, and anything placed works

The plan is `work/sandbox/PLAN.md` (§1, §2, §8.3). Ty's answers, 11-06: 2 m
modules on a 0.5 m grid; the Shed and the Hab stay as one-click prefabs
beside the kit, and they must work; the support check is on in Career and
off in Creative.

### The kit (`scripts/parts_kit.lua`, `tools/gen_kit_parts.py`)

- **A piece** is a part record like any other, its id `"<piece>.<mat>"`
  (`wall.steel`). `parts_base.partInfo` falls back to the kit, so
  `structures`, `base_snap`, `field_builder`, `base_grid` and `base_shield`
  read a piece as one more part.
- **Material is a property, not a part:** steel (a sandwich panel, the
  cladding set), concrete, regocrete (the concrete set in regolith brown) and
  glass (a laminated pane in a steel frame). Mass = gross volume × density ×
  the material's fill for the piece's class; price = the steel price ×
  `COSTK`. **M** cycles the material of the piece in hand and of the next
  ones (the map's M stands down while a kit piece is in hand). Concrete and
  regocrete walls, floors and slabs shield by record (`shield.k` = the
  material's `k`).
- **The grid:** a storey is 2.4 m: a 0.2 m floor and a 2.2 m wall, so a
  0.9 × 2.05 m door fits under a lintel. Walls stand on the edge lines of the
  floors and slabs, centred on them.
- **The first release** (46 pieces, 88 prefabs, 103 models in `models/kit/`):
  - FOUNDATION: Slab 2 × 2 (tiles edge to edge like the Pad Plate), Footing
    Pier, Ramp 2 × 4, Stairs (one storey, 12 risers), Steps 0.8 m, Ship's
    Ladder (a 47° stair: the walker climbs nothing steeper than 52°), Grating Deck.
  - FLOOR: Floor 2 × 2 / 2 × 1 / 1 × 1, Hatch Floor (a 0.9 m deck hatch that
    slides open).
  - WALL: Wall, Half Wall, Wall 1 m, Door Wall (a pocket door), Double Door
    Wall (4 m, two leaves), Window Wall (double glazed), Porthole Wall,
    Airlock Wall (a heavy pressure door; its interlock and cycling are S3),
    Open Frame, Vent Louvre Wall, Corner Post.
  - ROOF: Pitched Roof 2 × 2 (30°, glass makes a skylight), Roof Ridge, Gable.
  - FRAME: Pillar 2.2 / 4.4 m, Beam 2 / 4 m, Truss 2 / 4 / 6 m, Truss Node,
    Catwalk 1 × 2, Handrail.
  - HAB: the 2.5 m pressure can, along its Z on its saddles, a deck inside at
    0.8 m: Hab Segment, Hab Window Segment, Hab End Cap, Hab Door Bulkhead
    (a sliding door at deck level).
  - SHIELD: Shield Block 1 × 1, Lead-lined Wall.
  - UTILITY: Light Fitting, Switch Plate, Wall Screen, Wall Cable Tray, Floor Duct.
  - FITTINGS: VAB parts placed live (below).
- **A prefab** has an Empty root at the ground point (`seat` 0), a `Mesh`
  child, its static colliders (`Wall N`) and what a live piece moves or
  lights (`Door`, `Door2`, `Light`, `Screen`). One model per piece and
  material, so identical pieces batch. `tests/fixtures/kit_shapes.lua` holds
  each prefab's generated bounds; `smoke_kit` checks them against the boxes.

### Snapping (`scripts/kit_snap.lua`)

A pure rulebook beside `base_snap`. With a kit piece in hand,
`field_builder.pose` asks `kit_snap.face` first. The hit face and point pick
the adjoining place in the hit part's frame, on its 0.5 m grid:

| Piece | Aimed at | Goes |
|---|---|---|
| wall | a floor's or slab's top, within 0.6 m of an edge | on the edge line, its outside out |
| wall | a floor's middle | across it at the cursor, facing you (a partition) |
| wall | a wall's end / top / face | the line continued / stacked / square off it |
| floor | a floor's or slab's side | beside it, level |
| floor | a top face | laid on it |
| floor | a wall | on its top, its edge on the wall's centre line, out over the side you face (from outside, aimed at the top: the roof over the room) |
| pitched roof | a wall | its eave on the wall, rising over the room |
| post | a top | on the nearest corner, or the grid; on a post: stacked; at a wall's end: a corner post |
| block (stairs, blocks, fittings) | a top | on the grid, square toward you |
| mount (light, screen, switch, tray) | any face | flush, facing out of it (pitch 90° on a wall, 180° under a ceiling) |
| hab | a ring's end / a segment's side / a top | the next ring (a cap or bulkhead turned to face out) / a branch, the host turning into a T, cross or corner (§29) / on the grid |

- **R** turns a quarter, **Shift+R** pitches a quarter (a truss laid down),
  **T** rolls, **PgUp / PgDn** lift a face-snapped piece a storey, **Shift**
  frees it, **Backspace** resets them. `structures.partPose` turns a piece
  in pitch and roll in the engine's own order (yaw, then pitch, then roll).
- **The records rules** (`kit_snap.overlapIn`, `supported`, `fallsWith`):
  a piece may not stand inside another piece of its structure (wall corners
  may share their 0.1 m ends). In Career a piece must be held through what
  it touches (since playtest 11-09 a structural graph, §19): on its
  structure's ground, resting on a held piece's top (or a deck), or within
  two modules of one side to side. A mount is held by its face. Deconstruct
  takes what is no longer held down with the piece (`fallsWith`), so the
  wall goes with its floor and the light with its wall. Creative (the
  sandbox save) skips the support check.
- **Anything else in the way** (the crew, a crate, a rover) is
  `placement.overlapObb` on the piece's own box, skipping the structures.
- **Ctrl+drag lays a run:** pieces go down as the snapped ghost moves along
  the first one's line (a wall's) or level (a floor's), up to 64, as one step
  in the undo ring (`pushGroup`).
- **G mirrors:** off, then about the structure's X plane through the piece
  under the cursor, then its Z plane. Each placement places its mirrored
  twin in the same structure if it fits (`mirrorPose`, the VAB's mirror on a
  structure). Since S3 it is a true reflection (§14): a piece symmetric
  left-right or front-back is its own reflection turned, and the Door Wall,
  symmetric in neither, is placed as its mirrored variant.
- **Copy and paste:** Alt+click toggles pieces in a selection (tinted).
  **Ctrl+C** copies them, or the piece under the cursor. **Ctrl+V** holds
  the copy as a composite ghost (one `BuildGhost` root, a hologram per
  piece), placed with one bill and one undo; pieces that wouldn't fit are
  skipped and counted. **Ctrl+D** copies and holds. Blueprints in files are S4.

### Doors, lights, screens (`scripts/kit_live.lua`)

- structures calls `spawned` and `gone` for every piece whose def names
  `kit_live`: doors, lights, switches, screens, the Shed and the Hab.
- **Doors** slide open while a crew member on foot is near (in the door's
  parent frame, drawn poses, this frame) and shut behind them, with the
  servo and, for a pressure door, the seal's hiss. Their colliders follow
  them, because a Collidable a script moves keeps its collider.
- **Lights:** on/off is the part's state (`st.off`), switched from the
  fitting's menu or a switch plate (every light of the structure). A pool of
  the 8 nearest lit fittings within 45 m holds point lights; the rest give
  their slot back and show by their lens (card 0656: 16 lights reach the
  shader). On a grid that is short with its battery empty they drop to an
  emergency glow. A fitting is a 0.03 EC/s load on the base grid.
- **A wall screen** shows its base every 2 s while the crew is within 30 m:
  the grid in and out, the battery, the hours with no sun, a short, the
  lights, the crew, the funds. It is drawn with `img:text` in the project's
  fonts.

### Live placed parts (`scripts/struct_live.lua`; plan §2)

- **FITTINGS** are VAB parts the kit places live: Pod Mk1 and Mk2, Crew
  Cabin, Command Seat, Swift Cockpit (it lies on its belly), Stowage Locker
  and Small Locker, Floodlight, Battery, Solar Panel, Isotope Cell.
  `parts_kit.LIVE` copies their registry figures, because the world scene
  carries no registry; `smoke_kit` checks every copied field.
- **One anchored vessel per structure**, made the way a stand commissions:
  a `Vessel` root at the structure's origin with its axes, the live parts
  handed over as `dock.handoff.<id>` with `held = true, structure = sid`,
  each spawned as its child, then `assembly.rebuild` and `setAnchored`.
  Walls and floors are never in it.
- **The `structure` mode** (vessel_controller `structureMode`,
  `structureSid`): SPACE releases nothing, it can't be recovered or returned
  to a stand, the navball stays off, and it is off the fleet board
  (`standHeld`). It is dormant (a light tick a second); with the crew within
  6 m of one of its seats (`DORM_STRUCT`) it stays dormant and runs the SEAT
  TICK (S3 follow-up, §14), and only F wakes it. It never moves, so physics
  never needs it awake. Its seats, hatches, IVA, lockers, lights, electronics and
  part menus are a craft's: **F boards a placed cockpit**, a locker's
  Take / Put are its menu's, a floodlight switches from its menu or the
  Lights group. Its part nodes are adopted by `structures`, so Deconstruct
  finds them on their menu.
- **Held** body-relative every frame while the crew is within 600 m
  (`assembly.teleport`), as a stand holds its craft. **Rebuilt** when the
  live parts change; their state (a locker's number and contents, charge) is
  saved every 5 s and before a rebuild (`slive.<sid>`). A battery, panel,
  cell or floodlight placed live is a member of the base grid by its record
  (`parts_kit.LIVE_POWER`), and since S3 it counts ONCE: the vessel carries
  it without that module (§14).
- **The stand's uncommissioned craft** is drawn in blueprint blue
  (`setTint` with a blue rim on every display node). F beside it says
  "… is not commissioned yet: COMMISSION on the stand to use it", and so does
  the stand's menu.

### The Shed and the Hab

Both stay one-click, and both now work: a door that opens, a walkable
interior with its fit-out, and a light (§2). The hab is entered by a landing
and six closed steps straight out from it, away from the hull; the stair's
collider is a ramp along its nosings, as the spaceport's are, because the
walker climbs a slope and stalls on a stack of step boxes. Both prefabs now
have their root at the ground point (`seat` 0), as the kit's pieces do, so a
model whose box is not centred on its footprint (the hab's steps) still
stands where its record says.

### Tests and the probe

- `luajit solar/tests/smoke_kit.lua` (1,154 checks): every piece and
  material, the generated bounds, the plan's masses and prices, the
  FITTINGS against the registries, every snap rule, overlap, support,
  `fallsWith`, a pitched pose, and, on the real `field_builder`, a group of
  placements as one undo, the mirror twin, a copy turned, Creative, and a
  Deconstruct with what falls.
- `luajit solar/tests/smoke_struct_live.lua`: the structure vessel's
  blueprint (root, parents, frame, modules, a locker's number kept), its
  signature, the stub scene (spawned once, adopted, anchored, pinned as the
  planet moves, rebuilt for a locker but not for a wall, gone with its last
  live part), and kit_live's door, light pool, switch and screen.
- `tools/perf/kitprobe.sh <engine> kit|kitperf` (PATCHES=funds.patch). Look
  for `BK PASS|FAIL`, `KIT` and `BK RESULT`. Pictures go to
  `save/user/buildshots/k*.png`. The numbers are in
  `work/sandbox_s1/NOTES.md`.

### Open for S4 and later

The whole VAB catalogue in the kit, and bake-when-idle (card 0655). Rooms and
air are §14; paint, decals, props and blueprints are §15.

## 14. Sandbox S3: rooms and air

The plan is `work/sandbox/PLAN.md` §1.5 and §8.3 (S3). A room is found from
the pieces, holds air only when it is truly closed, and the crew breathe it.

### The rooms (`scripts/rooms.lua`, pure)

- **The cell grid.** Each structure has its own grid in its frame: 1 m
  columns in X and Z, and in Y the LAYERS between the planes its floors,
  slabs and roofs lie in (a storey is 2.4 m, so a fixed 1 m Y step would cut
  every room in half). The X and Z grids sit at 0 or 0.5 m, whichever puts
  more walls on cell faces.
- **What a piece closes** is its `seals` field as flat quads in its own
  frame, turned by its yaw, pitch and roll (90° steps only; a piece turned
  off the grid seals nothing):

  | `seals` | closes |
  |---|---|
  | `"z"` | a wall: its middle plane, its width by its height |
  | `"y"` | a floor or slab: its middle plane (a pitched roof: its eave's) |
  | `"door"` | as its class, while its door is shut (a door wall, the Hatch Floor, a Hab Door Bulkhead) |
  | `"ring"` | a hab segment: its four sides along its length (the can held as a 2.5 × 2.5 m tube); a cap: its section |
  | nil | nothing. A wall-class piece that doesn't seal (an Open Frame, a Vent Louvre) is kept to name the leak |

  A wall closes a cell face when it spans at least half the cell and stands
  floor to ceiling in that layer (within 0.3 m: walls stand on a floor's top
  and stop under the next one). A Half Wall stops short of the ceiling: it
  closes nothing, and the leak says so.
- **The fill, doors shut.** The outside is filled first from the grid's
  border and any open face at its lowest and highest planes. What it can't
  reach are the SEALED rooms. Then the LEAKY rooms: outside cells with a floor
  under and a roof over them, filled among themselves, closed on more than
  twice as many faces as they are open on (a box with a wall missing; a
  canopy on posts is no room). Their open faces are their LEAKS, each named
  ("a gap in the wall", "Vent Louvre Wall lets air through", "the Half Wall
  stops short of the ceiling").
- **Doors** join the two rooms (or a room and the outside) either side of
  them; the air opens them. An **airlock** is a sealed room of at most 24 m³
  with two doors or more, one of them an Airlock Wall's.
- **When:** a structure is solved when its seal signature (`signatureOf`: the
  pieces that seal, name an opening or carry life support, where they stand)
  changes, compared when `structures.version` moves, 0.5 s after the last
  change. A light switched or a locker opened changes nothing. Cost, warm:
  a hab is well under 0.1 ms; 676 pieces in 169 one-tile rooms (the worst
  case) 2.0 ms; 2,700 pieces 7.8 ms.

### The air (`scripts/room_air.lua`)

- **Per room** in atm·m³ (a cubic metre at one atmosphere): N (nitrogen and
  the rest), x (O2), c (CO2). p = (N + x + c) / V. A crew member breathes
  6.8e-6 of O2 a second and makes 5.85e-6 of CO2 (0.84 and 1.0 kg a day).
  A NETWORK is rooms joined by open doors (they mix at once).
- **Breathable:** p ≥ 0.5 atm, O2 ≥ 0.16 atm, CO2 ≤ 0.02 atm.
- **A new room holds the air it closed round:** vacuum on a moon, the
  world's air on the home world. A rebuilt room keeps its air by the cells it
  shares with the old rooms.
- **Leaks vent:** a network with an open door to the outside, or a leaky room
  in it, relaxes to the outside's air, e^(-t/τ), τ = 0.5 s × V / openings (a
  9 m³ room loses 95 % in about 13 s through one door: the plan's D6). The
  machines and the regulator stand down while it does.
- **Life support (the LIFE section; on the base grid):**

  | Piece | Does | Power |
  |---|---|---|
  | CO2 Scrubber | takes CO2 out up to 2.4e-5 atm·m³/s (four crew), down to none | 0.4 EC/s |
  | Oxygen Generator | makes O2 up to 2.8e-5 atm·m³/s (four crew) while under 21 % of an atmosphere, holds it there, idles over 105 % | 1.5 EC/s |
  | Air Tank Rack | 60 m³ of air at 200 bar on a regulator: opens under 0.97 atm, closes at 1 atm, 0.25 m³/s; refilled from its menu ($4 a m³) | none (a valve) |

  The machines run while their structure's base grid is up (a real grid not
  short with its battery flat), their draw a grid load. Since S7 the Oxygen
  Generator makes O2 only while its 20 L water cell has water, piped to its
  back from the fluid network (§17).
- **The closed form.** Between events every rate is constant, so the state is
  a straight line (venting the exponential). `advance(st, M, dt)` steps to the
  next event (O2 at 21 % or 105 %, the CO2 clear, the O2 gone, the regulator
  opening or closing, a tank empty), applies it and carries on: one call of
  any dt equals any number of small ones (`smoke_rooms` checks an hour against
  3,600 steps, and 30 h of a regulator cycling against 108,000, to 1e-6). The
  air advances every second on the agency clock, at once when a door opens or
  shuts, the crew moves room or the power changes, and a structure loading is
  caught up in one call per network (capped at 30 game days). Never per frame.
- **The crew** in a breathable room breathe it: `suit.breathableAt` asks
  `room_air.airAt` first, so the helmet may come off there (even on an
  airless moon), `planet_walker` draws no suit air, and a room whose air goes
  puts the helmet back on at once. Crew records off-screen (`crew.recordTick`)
  ask the same.
- **Alarms.** A room that held air (0.8 atm or more) and vents sounds
  DEPRESSURISATION with its cause ("the Door Wall is open", the gap), the
  caption and the crew alarm every 2.5 s within 45 m, until it is down to the
  outside's pressure or sealed again. Air going bad with the crew in a sealed
  room is said once ("CO2 2.3 %: the scrubbers aren't keeping up").
- **SAVE:** `air.<sid>` = { a (agency clock), rooms = { { k, N, x, c, V, f } … },
  tanks = { { u, q } … } }, every 5 s and on a solve; a room's key `k` is its
  lowest cell's. Lists, not tables keyed by number (the save does not hand a
  12-digit string key back as one).

### Doors hold against pressure

Any door that is not an airlock's is **held shut** while more than 0.1 atm
stands across it (19 kN on the leaf; a room at 1 atm against vacuum is
190 kN): walking up to it says "held shut: 1.00 atm against 0.00 · its menu
forces it" and it stays shut. Its menu's **Force it open (vents Room 2)**
frees it until it shuts again, and the room vents with the alarm. (Without
this, walking past a door to the outside on a moon emptied the hab: the
probe found it.) On a world whose air you can breathe, a room and the
outside are at about the same pressure and doors open as before. Since S7
its menu also opens the door's own equalising valve (the slow, safe way),
and forcing it is a timed job with a warning, a gust, a pull and a damaged
seal (§17).

### The airlock

- Its doors are **interlocked**: kit_live asks `room_air.gate(sid, uid, want)`
  for each, every frame it steps it, and only the chamber's chosen door may
  open, with every other door of the chamber shut and the chamber at the
  pressure on that door's far side.
- **Which door:** a crew member outside by a door asks for it; in the chamber,
  for the door they did not come in by.
- **The cycle:** while the pressures differ, a pump moves 0.35 atm·m³/s
  between the chamber and the hab behind it (depressurising pumps the air
  back into the hab; repressurising draws it from the room ahead), with the
  pump's hiss looping and a seal hiss and chime at the end. A 2 × 2 m chamber
  takes about 25 s. Its menu row reads "depressurising · 0.42 atm". (S7: the
  pump now runs on the base grid, into an Airlock Receiver when there is one,
  and the chamber vents when it can't: §17.)

### The ROOMS overlay

F1 with the kit open. Each room's outline on its floor and under its
ceiling, drawn from this frame's body read (the planet moves), green sealed
with air, amber sealed and thin, red unsealed or venting, a label at its
middle ("ROOM 2 SEALED · AIR · 17.6 m³ · 1.00 atm · O2 21 % · CO2 0.0 %",
"AIRLOCK"), and a red ring and "GAP · …" on every leak. The wall screen's
ROOMS, AIR, LEAK and LIFE SUPP lines read the same.

### S1/S2 follow-ups

- **The seat tick.** A structure vessel with the crew within 6 m of a seat
  no longer runs the whole controller (0.12–0.20 ms a frame for a vessel
  that never moves). It stays dormant and runs `structSeatTick` each tick: F
  boards (`boardNow` wakes it), and ten times a second the prompt and the
  ring's station from `board_dist`; `lateUpdate` draws the ring from the
  drawn pose. It is never script-slept while the crew is at a seat.
- **Power counted once.** A battery, panel or cell placed live is the base
  grid's by record; the vessel carries it without that module
  (`struct_live.GRID_MODS`). A floodlight's and a crewed part's draw are grid
  loads (`LIVE_POWER`: pod 0.05, Mk2 0.08, cockpit 0.04 EC/s), so their
  modules draw nothing in the vessel, and the vessel's own cells (a pod's
  battery) are topped up every 5 s while the grid is up.
- **Mirror (G) reflects.** The twin of a piece at Ry(yaw)·Rx(pitch)·Rz(roll)
  reflected in the structure's X plane is Ry(-yaw)·Rx(pitch)·Rz(-roll) on the
  piece flipped left for right; in its Z plane Ry(-yaw)·Rx(-pitch)·Rz(roll)
  on it flipped front for back. A piece's `sym` says which of its own planes
  it is symmetric in ("x" default; "z" the gable, Airlock Wall, Hab Door
  Bulkhead, Hatch Floor, pods and the cabin), and one symmetric in the other
  is that flip turned half round. The Door Wall is symmetric in neither (its
  door at one end, its lamp outside): G places `doorWallM`, a hidden variant
  the generator builds reflected (`mirrored()` in `tools/gen_kit_parts.py`).
  `smoke_kit` checks every point of the twin is the mirror image of a point
  of the piece, for both planes and turned poses.

### Tests and the probe

- `luajit solar/tests/smoke_rooms.lua`: the flood fill (a sealed box of
  8.8 m³, a door shut and its door to the outside, the mirrored door, a
  window and a glass wall, a gap, an open frame, a vent louvre, a half wall,
  no roof, a canopy, two rooms and their door, an airlock, a hab of three
  segments and two caps, an open can, a bulkhead, the box turned, a 10 × 10 m
  hall, the signature), the closed form (one step against many, the
  regulator, venting, a breathable world's air, the O2 running out), and the
  scene half on a stub engine (solved once, a tank pressurises a moon's
  room, the crew breathe it, the airlock out and back in never both doors
  open with the air pumped back, a door to the moon held shut by the
  pressure until forced, then venting with the alarm, the regulator refilling
  it, the save, a capped catch-up).
- `tools/perf/kitprobe.sh <engine> rooms` (PATCHES=funds.patch): a sealed
  hab with an airlock built through the kit, pressurised, the overlay from
  outside, walked into through the airlock, the room's air breathed with the
  helmet off, the seat tick's cost, the far door held shut by the pressure,
  then forced open from its menu (the leak alarm, the helmet back on),
  refilled, save and reload. Pictures
  `save/user/buildshots/r*.png`; numbers in `work/sandbox_s3/NOTES.md`.

## 15. Sandbox S4: bases get character

The plan is `work/sandbox/PLAN.md` §5, §1.4 and §6 (S4). Ty, 11-06: "building
a base right now basically feels like it has no character"; a curated palette
of about 12 swatches; the Shed and the Hab stay one-click prefabs. Four new
tabs in the kit's column: **PAINT**, **PROPS**, **DECALS** and **BLUEPRINTS**.

### Paint (`scripts/kit_paint.lua`, pure + a small driver)

- **The palette:** twelve enamels drawn from the UI tokens
  (`ui/solar.tokens.ron`), reworked in S5 for real value and hue range (§16,
  "S4 polish"): Hull White (bezel), Cream (ink), Light Grey, Safety Yellow
  (warn), Signal Orange (accent), Oxide Red (accentDim), Hab Green (phosDim),
  Olive Drab, Signal Blue (signal), Primer Grey, Anthracite, and the **Agency
  Colour**, the company emblem's field colour worn to an enamel (it follows a
  new emblem). Each swatch is named by its sRGB colour and kept as the linear
  albedo the painted surface should average.
- **How it sits:** `node:setTint` multiplies over what a node draws and keeps
  its textures, so paint is the tint that turns the piece's material average
  into the swatch (`tintFor` = swatch / `BASE[mat]`, per channel, at most
  8×). The normal, roughness and AO maps and the albedo's own stains, seams
  and pitting all show through: an orange coat on concrete still looks like
  concrete under paint. Tint never splits a draw (engine `perf.counts`), so a
  painted wall row still batches; the probe measures it (below).
- **Two faces:** `tools/gen_kit_parts.py` splits every wall-class piece's
  model at its middle plane after building it: what is behind (z < 0) is a
  `MeshIn` child, and a hab can's lining and deck (inside its hull) likewise.
  `paint` is the outside (or the whole piece), `paintIn` the inside. Panes
  and lamp lenses go into a `Glass` child on every paintable piece: a painted
  window is never orange glass. No piece function changed for it.
- **What takes paint:** kit pieces and props. Not a light's lens, a wall
  screen, a switch, a lamp, a decal or a VAB fitting (`paintable`).
- **The tool:** a swatch card in hand. LMB paints what the cursor is on: a
  wall's face (the side you see), any other piece whole; **Shift** both
  faces; **Ctrl** every piece of that kind on the structure; a piece in the
  Alt-selection paints the whole selection. **I** held (or the Eyedropper
  card) takes the face's colour into the hand; **Strip Paint** takes it off.
  The piece under the cursor is rimmed orange. A coat is $30 a piece
  (`PAINT_COST`), free in Creative, one step in the undo ring, refunded
  within the minute like a placement.
- **The record:** a structure's bp entry carries `paint`, `paintIn` and `pt`
  (when it was painted), so paint saves with the structure, copies with
  Ctrl+C and travels in a blueprint. `structures.spawn_part` calls
  `kit_paint.applyPart` as a piece's node lands.

### Weather, the light pass (`kit_paint` `dustOf`)

An exterior piece (the structural sections: foundation, floor, wall, roof,
frame, hab, shield) gathers dust with its age since it was placed or last
painted: `cap × (1 − e^(−days/60))`, cap 0.55 on a dry world, 0.28 where rain
washes it (`climate.worldOf`: air and seas), toward the world's own dust
colour (by its kind). It goes on the outside skin only (a wall's `MeshIn`,
props and fittings stay clean). Levels are quantised to 1/20 and a piece is
re-tinted only when its level steps: a few times a game month at 1×. The
driver knows when each piece's level next steps (`nextStepDays`, closed
form), so a structure is looked at again only when its earliest step is due
or the structures change; idle, that is one comparison a structure every 2 s.
Repainting is washing.

### Props (`PROPS`; `tools/gen_kit_props.py`)

Cargo Crate, Small Crate, Drum, Shelving (stocked), Table, Chair, Bunk (two
berths, mattresses and blankets in the lab's cloth), Workbench (drawers, a
vice, a pegboard of tools), Coffee Maker, Desk Monitor, Potted Plant (the
flora atlas's leafy shrub on crossed cards), Cable Reel; on walls and
ceilings Tool Rack, Pipe Run, Cable Run, Fire Extinguisher; and two lamps,
the warm Desk Lamp and the 5,000 K Work Light, pooled with the kit's lights
(`kit_live`, their lens a `Lens` child) and loads on the base grid.

- Snap class **`prop`**: a block on a 0.25 m grid (a monitor on a desk, a
  crate in a corner), on any top face (a table's, a crate's), square toward
  you; R and the wheel turn it. Wall things are `mount`s.
- **Colliders** where the crew would bump into them (one box, or a table's
  top and its two leg frames); none for small clutter (`clutter`: the lamps,
  the monitor, the coffee maker, the plant). One model each, so they batch.

### Decals and signs (`DECALS`)

- **Films, not engine decals.** `decals.add` lays a mark only on the collider
  of a node that draws, and a kit piece's colliders are Empties beside its
  Mesh. So a decal is a thin quad a piece of its own (`mount` snap, material
  `film`, `film = true`): it saves, copies, mirrors and travels in a
  blueprint, overlaps nothing (paint goes over paint: `kit_snap.overlapIn`),
  nothing blocks it, and every quad of a kind batches.
- **Stock (29: 24 marks, 5 grime):** Hazard Stripe 2 m and 1 m, Hazard Panel, Arrow, Chevrons,
  NO ENTRY, AIRLOCK, PRESSURE DOOR, Load Rating, O2 Line Marker, DANGER 400 V,
  EXIT, the Halden Structural and Pell Groundworks marks (the game's own
  suppliers), numbers 0–9, and grime: Streaks, Floor Scuffs, Rust Run,
  Scorch, Oil Stain. One atlas (`textures/kit/decals.png`, 512 px a metre,
  cutout) drawn by the generator in the project's fonts to `ui-style.md`'s
  signage rules, and the grime's own (`grime.png`, blended); both with a
  paint-film normal, ORM and height from `tools/detail_maps.decals`.
- **T turns a mount on its face** (a decal, a sign, a rack):
  `kit_snap.spinPose` composes Ry(yaw)·Rx(pitch)·Ry(spin) back into the
  record's yaw, pitch and roll (on a wall a quarter spin is pitch 0 and a
  quarter roll).
- **Signs:** Sign Plate (riveted, 1.4 × 0.45 m since S5), Name Board
  (2.4 × 0.6 m) and Stencilled Words (2 × 0.4 m, sprayed on, cut out); the
  words fill them and a plate narrows to its words (§16, "S4 polish"). `kit_live` draws each into a picture
  (`img:text` in SolarStencil / SolarLabel) once: the part state's `text`, or
  with none **the base's name** (`bases.baseAt`), redrawn when either changes
  (a rename reaches the board within 2 s while the crew is near). Right-click:
  **Write the words…** (a prompt; empty = the base's name). Each sign is its
  own texture, so its own draw. **Agency Emblem**: the emblem's texture
  (`emblem.tex()`), sprayed on.
- **Clicking one:** a ray passes through a film to the wall, so
  `field_builder.pickAt` / `pickTarget` find the mount at the hit point
  (`kit_snap.mountAt`, the smallest wins); `context_menu` now keeps a prop
  target's click point body-relative at the pick. Deconstruct, the sign's
  words, Alt-select and the eyedropper all use it.

### Blueprints (`scripts/blueprints.lua`, pure + the library)

- **A blueprint** `{ v, name, by, made, n, mass, cost, pieces = { { id, x, y,
  z, yaw, pitch, roll, paint, paintIn, text } } }` in the frame of its
  anchor (the lowest piece, then the first placed), exactly the shape of the
  Ctrl+C clipboard: a blueprint in hand is a paste, with its composite ghost,
  R and the wheel turning it, the anchor snapping as a piece would.
- **One bill:** the pieces' prices and **one delivery's** shipping (10 % +
  $50 on the sum), charged once before anything goes down; each piece's
  `paid` carries its share, so one Ctrl+Z refunds the whole bill; pieces that
  don't fit are refunded and named. Pastes (Ctrl+V) now bill the same way.
- **Saving:** the **Save as Blueprint** card (the Alt-selection, else the
  structure you stand at), or right-click a piece → **Save structure as
  blueprint** / **Save the N selected as blueprint**. A name prompt, then the
  code, shown and written beside the file.
- **Files:** `user://blueprints/<slug>.json` (one library for every save) and
  `<slug>.code.txt`. A `.json` or a code file dropped on the window joins the
  library (`filesDropped`); **Import a Code** takes a pasted one.
- **The code:** `SOLBP1.<payload>.<check>`: base64url of a compact text (the
  name, each piece id once, one line a piece in centimetres, degrees and
  palette keys), and four base36 digits of an Adler-32, so a code mistyped or
  cut short in a chat is refused instead of building half a hab. Pure Lua
  (luajit checks it). The 31-piece stock hut is 1.3 kB.
- **Stock:** Crew Hut 4 × 4 (furnished, a name board, a kick stripe, grime)
  and Tool Shack 2 × 2 beside the Shed and the Hab, which stay one-click
  prefabs. The card's picture is a plan drawing of its pieces.
- **The engine has no clipboard API** for a game: the code is shown in a
  read-only field and written to a file. A general `clipboard.get/set` would
  make sharing one keystroke (proposed in work/sandbox_s4/NOTES.md).

### Tests and the probe

- `luajit solar/tests/smoke_character.lua`: the palette and its tint maths,
  what takes paint, faces, dust; spin and the mount pick; paint through
  field_builder (a face, both, a selection, the cost, undo/redo, Creative,
  the saved records after a reload); a sign's words; the tool cards;
  blueprints (from a structure with paint and words, the code and back, a
  damaged code refused, the JSON file and the library, the stock hut's code
  under 4 kB, one bill and each share); placing the stock hut (every piece,
  charged once, its paint, turned, one undo refunds it), every stock
  blueprint whole, and a saved one built again with its sign's words.
- `tools/perf/kitprobe.sh <engine> character` (PATCHES=funds.patch;
  `tools/perf/charprobe_modes.lua`): a hab built through the kit, the base
  named, painted through the paint tool's own functions, signs and decals,
  props inside, pictures, a blueprint saved and placed again, a 500-piece
  base + 100 props + 20 decals in view painted and then bare (tint keeps the
  batches), save and reload. Pictures `save/user/buildshots/c*.png`; numbers
  in `work/sandbox_s4/NOTES.md`.

## 16. Sandbox S5: power networks II and cables

The plan is `work/sandbox/PLAN.md` §3.2, §3.6, §4 and §12 (S5). A base's
grid stops being one lossless pool: the cables carry real I²R losses and have
ratings, breakers trip on overload and need a hand to reset them, and a long
line wants a transformer at each end and 11 kV between. The base grid's
closed-form battery step (§12) is unchanged: the losses are one more load on
it, slot by slot.

### Units

A base reads **1 EC/s as 1 kW**: a strip light's 0.03 EC/s is 30 W, a
tower's 2 EC/s 2 kW, a Solar Array a 3 kW array, an O2 generator 1.5 kW. The
network's readouts (the POWER overlay, the cable and breaker menus, the
screen's LOSSES line, the station card's LOSS line) are in kW.

### The network of a grid (`scripts/base_power.lua`, pure + the overlay)

- **Buses.** A structure is one bus: its parts share its busbar. Structures
  within 150 m of a tower share the tower's bus (the base's own low-voltage
  ring, lossless as before): `base_grid.buildGrids` keeps a second union for
  that, without the cables (`g.bus[sid]`). A structure of network gear
  alone (a pole, a junction) never joins a tower's ring: it is on the line
  its cables make (the probe caught a pole 40 m from the tower swallowing
  its HV spans' flow).
- **Edges** are the grid's live cables between two buses: R = ρL/A (annealed
  copper, ρ = 1.72e-8 Ω·m, per conductor), at their voltage, with a rating
  V·I. A cable is live unless it is burnt through or a breaker at either end
  is open or tripped (`split_cables`).
- **Sources and loads** sit at their structure's bus; the **batteries are
  the slack**: they take a surplus and cover a shortfall, shared by size.
  With no battery the sources are turned down to what is drawn, or the loads
  are shed in proportion.
- **The flow** is a DC load flow in per-unit: each edge's admittance is
  V²/R (a transformer adds its 4 % impedance in series at each end it is
  plugged into), the reduced Laplacian is factored once (dense LU with
  partial pivoting) and back-substituted for each slot. On a tree that is
  exactly "push the loads up to the sources"; on a cycle the flow splits by
  conductance (the smoke checks a 2 : 1 split). The losses are drawn where
  the loads are and the slack covers them; the solve repeats until they
  settle (to 1e-9 kW, warm-started from the last slot's).
- **Losses:** each cable P²R/V²; each transformer P0 + Pk·(S/S_rated)²
  (0.25 kW idle, 1.6 kW more at its full 100 kVA). 1 km of 16 mm² at 400 V
  carrying 20 kW loses 13 %; the same at 11 kV loses about 2 W.
- **The year** (`yearOf`): each slot of the light's year is solved once
  (slots whose arrays give the same, the nights, share one solve), giving
  `M.lossP[k]` (the kW lost in slot k), `M.trip[k]` (what trips in it) and
  each cable's peak. `base_grid.advance` adds `lossP` to the slot's draw, so
  one long step still equals many short ones (smoke: 37 years to 1e-6).
- **When it is solved:** with the grid, on change and on the 2 s clock,
  never in a frame. The flows of the current slot are kept for the overlay
  and the menus (`base_grid.cableFlow(id)`, `partFlow(sid, uid)`).

### The cables and their types (`base_cable.lua`, `parts_base` drums)

| Drum | Cable | Rating | Mass | Price | Longest run |
|---|---|---|---|---|---|
| Power Cable 16 mm² | 4-core SWA, 400 V | 80 A, 32 kW | 1.4 kg/m | $3/m | 1.5 km |
| Power Cable 35 mm² | 4-core SWA, 400 V | 125 A, 50 kW | 2.6 kg/m | $6/m | 1.5 km |
| Power Cable 95 mm² | 4-core SWA, 400 V | 230 A, 92 kW | 5.8 kg/m | $14/m | 1.5 km |
| HV Cable 11 kV | 3-core 35 mm² XLPE | 140 A, 1.5 MW | 2.3 kg/m | $9/m | 6 km |

- A cable's record carries `ty` (nil = 16 mm², every cable before S5) and
  `burnt`. The drum in hand decides the type; the hint shows what the run
  would lose at 10 kW, so the gauge is a choice.
- **The 11 kV cable** runs only between Transformers, over Power Poles
  between; a transformer's high side takes nothing else, and a pole carries
  one voltage (`validity`).
- **Loops:** a cable to a pole, a junction, a breaker or a transformer
  (`netgear`) may close a loop or double a line; anything else still joins
  only two grids that aren't one yet.
- **Strung from a pole:** a cable made off at a Power Pole leaves its
  crossarm (`cableAt`, 7.7 m) and is pulled tight: its catenary's a is 5× the
  span (`tensionA`, a sag of 2.5 %), never less than the hand's lay. The
  settle (§12) is otherwise the same: where even the tight line would dip
  into the ground it lies on it.
- **Burnt through:** a cable driven past 125 % of its rating burns through at
  the start of that slot unless a breaker on it trips first (scn_dust: a
  breaker rated, or dialled, over what its cable carries guards nothing). It carries nothing
  until it is spliced: right-click its end → **Splice the burnt cable** (4 s,
  a quarter of its price). Between 100 and 125 % it only runs hot (the
  overlay is red and the limit line names it).
- The end part's menu gains the cable's **Load** (kW, % of its rating, loss).

### The POWER pieces (`parts_kit` POWER section, `tools/gen_kit_parts.py`)

| Piece | Size | Mass | Price | What it does |
|---|---|---|---|---|
| Breaker Panel 63 A | 0.4 × 0.5 × 0.14 m, wall-hung | 14 kg | $180 | guards the cables plugged into it: trips past 25.2 kW; with none, its structure's main |
| Breaker Panel 160 A | 0.56 × 0.72 × 0.2 m | 32 kg | $420 | the same at 64 kW |
| Transformer 100 kVA | 1.44 × 1.12 × 1.66 m pad-mount | 0.8 t | $2,400 | 400 V ↔ 11 kV; three HV bushings on top where the HV cable lands (1.62 m) |
| Power Pole 8 m | steel tube or spun concrete, 1.4 m crossarm | 0.24 / 0.95 t | $650 / $480 | a cable made off at it is strung overhead |
| Junction Box | feeder pillar, 0.64 × 1.0 × 0.44 m | 45 kg | $150 | a cheap part to branch or splice runs at |

- **Breakers.** A cable plugged into a breaker is **guarded** by it: the
  breaker opens (a TRIP) at the start of the first slot whose flow on that
  cable passes its rating, and stays open until a hand resets it. A breaker
  with no cable is its structure's **main**: open, the structure's own loads
  are off the grid; it trips when they draw more than its rating. Open or
  tripped, a guarded cable carries nothing, so the grid may split in two;
  each half keeps its banks' charge (every bank at the grid's state of
  charge). A trip is logged (`base_power.lastTrips`), captioned, and clacks.
  Its lamp (a `Lens` child) is green, amber past 80 %, red tripped, dark open.
- **The menu:** Breaker (its load of its rating, what it guards), **Breaker
  closed** (a toggle), **Reset the breaker** when tripped. Transformer: its
  load of 100 kVA, its loss, its HV lines.
- **The logic seam (S8):** `base_power.setBreaker(sid, uid, closed, by)`
  with `by` = "hand" | "logic" | "trip"; hooks in `base_power.onBreaker`
  hear every change (fn(sid, uid, state, by)). S8's actuators call the one
  and sensors read `breakerState` / `base_grid.partFlow`.
- **The trip dial (scn_dust).** A breaker's long-time pickup, **Ir**, is a
  share of its frame's amps (0.3 to 1; 1 when never set), kept in the part's
  state (`st.ir`): a 63 A panel at Ir 0.4 trips over 10.1 kW. The menu shows
  it (**Trip setting**) with **Turn the trip setting up** and **down** (10 %
  a turn). Turning it up is never refused: the warning names what the
  guarded cable burns at (`base_power.irWarn`), because a dial over a light
  cable moves the fire from the breaker into the cable. `breakerIr`,
  `setBreakerIr(sid, uid, ir, by)` (its hooks hear `"ir"`).
- **The 2.5 mm² flex (scn_dust).** `base_power.CABLES.lv2`: 24 A, 9.6 kW,
  burns through over 12 kW, 200 m at most. No drum lays it (a scenario's
  start does: `start.cables`); `base_cable.layFree` lays a staged run with no
  hand and no bill.
- **Trips in time.** `base_grid.advance` stops a grid at the start of a slot
  that trips (or at once when it is already in one: a load added, a reset
  under load); `advance_all` opens what tripped, rebuilds the grids (keeping
  each grid's own clock) and goes on from that moment, so a long catch-up and
  a series of 2 s steps trip at the same instant (smoke, to 1e-9 s).

### The readouts

- **POWER overlay** (F2 with the kit open; `base_power.drawOverlay`, in
  `lateUpdate` from body-relative cable paths and this frame's body read):
  each cable within 700 m drawn over its settled path, green under half its
  rating, amber to full, red over it, grey off; chevrons along it the way the
  power flows; a label at its middle (`CABLE 3 · 35 mm² · 18.4 kW · 37 % ·
  loss 0.6 kW`, or `OFF (breaker tripped)`, or `BURNT THROUGH`); each breaker
  and transformer's load; and each grid's card over its first structure:
  `GRID b1 · IN · OUT · LOSS · BATTERY`, with the **LIMITED BY** line under it.
- **Limited by** (`base_power.limitedBy`): the element nearest its limit
  when one is past 80 % ("cable 3 at 140 % — upgrade the gauge to 35 mm²",
  "breaker at 96 % of its rating — near its trip", "transformer at 120 % — a
  second line, or shed load", "main breaker at …"), else the line losing the
  most when it loses 5 % or more ("cable 3 loses 14 % — a transformer at each
  end (11 kV)").
- **The wall screen** gains LOSSES (kW and % of the draw), LIMIT and TRIPPED
  lines; **the station's base card** LOSS and LIMIT lines in its CRT block;
  the tower's grid line counts breakers and transformers.

### Cost

- Per frame: nothing new but the overlay while it is on, and the breaker
  lamps once a second (a tint only when a lamp's state changes).
- On change: the topology, then each network's year (one LU, one
  back-substitution per distinct slot). The smoke's three networks with 40
  cables and 10 breakers rebuild in 3–7 ms in luajit (light profiles
  included when cold), a 2 s step 0.05–0.08 ms. The probe's numbers are in
  `work/sandbox_s5/NOTES.md`.

### Tests and the probe

- `luajit solar/tests/smoke_netpower.lua`: the cable maths (R, P²R/V², the
  plan's 1 km figures, ratings, gauges, breaker and transformer figures); a
  tree's flow and its balance at every bus; a cycle's 2 : 1 split; a trip, a
  burn, a main breaker, the limit lines; a year of losses on the battery step
  (one step = many to 1e-6) and a noon trip at the same moment either way;
  two bases 1.2 km apart at 400 V and then at 11 kV through two
  transformers, the HV rules, a far breaker tripped by the overload (the grid
  splits), reset under load (trips again), the load cut (holds), opened by
  logic (the hook), a main breaker, a cable burnt and spliced, the save; and
  the cost of 3 networks, 40 cables and 10 breakers.
- `smoke_base_grid` / `smoke_base_build`: the BASE column's three new drums.
- `tools/perf/kitprobe.sh <engine> power` (PATCHES=funds.patch;
  `tools/perf/powerprobe_modes.lua`): base A built and painted in the light
  swatches, a 1.1 km 11 kV line over two poles to base B, a plant fed through
  a breaker and overloaded until it trips, reset, held; the overlay at both
  ends and over the line (two angles); the inside, a plate and a board read
  from 8 m, the palette; 3 networks / 40 cables / 10 breakers measured; save
  and reload. `interior` is the diagnostic behind the polish below.

### S4 polish (from the screenshot review)

- **The palette** (`kit_paint.PALETTE`) was picked as if its numbers were
  screen colours, but they are linear albedo, so every swatch came out a pale
  mid-tone pastel and they read alike. Each swatch is now named by the sRGB
  colour a real enamel shows (RAL-like) and converted to linear once: Hull
  White, Cream (key `bone`), Light Grey, Safety Yellow, Signal Orange, Oxide
  Red, Hab Green, Olive Drab, Signal Blue, Primer Grey, Anthracite (key
  `gunmetal`) and the Agency Colour: luminance 0.03 to 0.83. A key from the
  first palette (`sand`) resolves to Cream (`ALIAS`). The tint's ceiling went
  from 3 to 8, so white on dark regocrete is no longer clamped grey (the smoke
  checks no swatch is clamped on any material).
- **Inside colour.** The probe's diagnostic (`interior`): with the new paint
  the lamp-lit walls already read clean; the pink and the blue ceiling came
  from the **sky reflection** (a physical surface reflects the sky map, whose
  lower half is the red ground). On a world on rails a reflection probe would
  re-capture every frame (its key is its world position), so the room can't
  be captured instead; the generator writes `reflectivity: 0.12` on every
  `MeshIn` (a wall's or hab can's inside) and 0.35 on floor and roof panels
  (their undersides are ceilings). A material in the prefab, so it batches.
  The strip light is a neutral 4,300 K white as the eye adapted to it sees it
  (1.0, 0.91, 0.79), cooler than before.
- **Signs** (`kit_live.signLayout`, pure): the plates grew (Sign Plate
  1.4 × 0.45 m, Name Board 2.4 × 0.6 m, Stencilled Words 2.0 × 0.4 m); the
  words are set from the fonts' own advance widths, on one line or two when
  that sets them bigger, in light ink on a near-black enamel; the plate
  narrows to its words (its Mesh and Face scaled along their width, never
  under `fit`). "HAB 1 · CREW 2" on a plate is ~0.13 m capitals.

## 17. Sandbox S7: fluids, and pressure you can work with

The plan is `work/sandbox/PLAN.md` §3.3, §3.6 and §8.3 (S7). Water, coolant,
fuel and gases run in pipes between tanks, by pressure difference, through
pumps, valves and regulators. The O2 Generator needs water, a reactor's loop
has an inventory a break can lose, and the doors of §14 can be equalised,
cycled without losing the air, or forced, at a price. Ty asked about
pressurisation chambers as a mechanic: this is that.

### The network (`scripts/fluids.lua`, pure)

- **What flows**, by real density and molar mass: water (998 kg/m³),
  coolant (demineralised borated water, 998), fuel (RP-1, 810; a fuel unit
  is 10 kg), oxygen, nitrogen and hydrogen (ideal gases at 293 K). A network
  carries the one substance its tanks hold. Two in one network is refused
  and named ("it joins fuel and water: nothing flows until they're parted").
- **Found** by union-find over the pieces' ports when the records change
  (debounced 0.5 s, never in a frame). Ports that meet (the S6 port snap:
  coincident, facing) are one node.
  - Each fluid piece is an element between its nodes, or a node of its own.
  - A piece without `fl` gives the network its ports flagged `fluid`, by
    their `role`: the O2 Generator's water nozzle (a consumer) and its
    hydrogen nozzle (kept apart, by its `loop` tag), and the pressuriser's
    makeup nozzle (a reactor's primary).
  - Ports carry a `bore`. The reactor's DN100 coolant nozzles meet only
    DN100, the process line only DN25 (`kit_snap.boreOf`).
- **The elements:**

  | Element | Law |
  |---|---|
  | pipe, elbow, tee, riser | a conductance g = q_r / Δp_r: Darcy (f 0.022) at 2 m/s of water for its bore and length, linearised there; gases carry 1 % of the mass for the same drop |
  | pump | q = g (p_in − p_out + H0) on a straight curve from its free delivery q0 to its shut-off head H0, in series with its casing; never backwards: it STALLS against more than H0; off, it blocks |
  | valve | shut: blocks; open: a conductance |
  | check valve | a conductance that never flows backwards |
  | regulator | THROTTLING (its outlet pinned at its set pressure, the flow an unknown) while its inlet is over the set; WIDE OPEN under it; SHUT while its outlet is over it |
  | gauge | an inline fitting that reads its node |
  | room outlet, vent | into the room it stands in (at the room's pressure; shut while the room is at 1 atm), or to the outside |

- **The nodes:** a liquid tank holds x kg under a nitrogen blanket, so its
  outlet is at 1 atm + ρgh with h = x / ρA. A gas bottle rack is at x·R·T /
  (M·V). A consumer is a small tank the scene drains. Liquids are solved in
  piezometric pressure (p + ρgy), so a pump lifts water up a riser and a tank
  a storey up feeds the floor below. Readouts show the static pressure.
- **The closed form (E's rule).** For a given set of modes (each tank normal,
  full, starved or dry; each pump running or stalled; each check valve open
  or shut; each regulator throttling, open or shut), every flow is affine in
  the tanks' contents, so x' = A·x + b exactly.
  - `advance` takes that ODE's exact solution, the matrix exponential of
    [[A, b], [0, 0]] by scaling and squaring.
  - It samples every mode's guard along the trajectory, bisects the first
    crossing to 1e-12 of the step, switches that mode and carries on.
  - One call of any dt equals any number of small calls. `smoke_fluids`
    checks a day in one step against 86,400 one-second steps, and 30 days
    across a regulator's change against thirty one-day steps, to 1e-6.
- **Shut in.** A section with no path to a known pressure once shut valves,
  stopped or stalled pumps and shut check valves are taken as open circuits
  (a pipe between a shut gate valve and a stopped pump; a lone node; a full
  cell behind a shut valve) is an ISLAND: its equations alone are singular.
  `plan_of` finds islands by union-find over the free nodes and pins one
  node of each (a full tank in it at a·cap + c, else a dry one at c, else its
  lowest node at the pressure it last had, `st.pk`, i.e. the pressure it was
  shut in at; 1 atm static on a fresh state). The rest of the island is
  solved from that node, so a trapped liquid or gas line holds its pressure,
  nothing crosses its shut ends, and it rejoins at the next solve when a
  valve opens or a pump starts. A full tank shut in leaves full as soon as
  its drain isn't served. `rep.shut` names the shut-in nodes. `fluid_net`
  runs each network's step under `pcall`: a failing step is skipped with
  the state put back and one logged warning per network per kind of error.
- **Limited by** (`limitedBy`): a starved consumer first, with why ("the
  O2 Generator is starved (0.000 of 0.000045 kg/s): the Water Tank 2 m³ is
  empty"); else a stalled pump ("the pump can't beat 154.0 bar (its shut-off
  head is 6.0)"); else the pipe run dropping the most bar.

### The scene (`scripts/fluid_net.lua`)

- Each structure's networks are stepped at 5 Hz on the agency clock, and at
  once on a change. A load catches them up in hour-long pieces, with the
  rooms' air brought to the same moment between pieces, so a generator's
  water cell is refilled as it would have been.
- **The couplings:**
  - **The O2 Generator** (§14) makes O2 only while its 20 L cell has water
    (`room_air.advance` has a `water_out` event). Each atm·m³ of O2 takes
    1.608 kg of water and makes 0.180 kg of hydrogen (2 H2O → 2 H2 + O2, by
    mass). The network fills the cell (`fillCell`) by what flowed in. The
    hydrogen goes to the bottles piped to its H2 nozzle, or is vented.
  - **A reactor's primary** (`reactor_plant.primaryOf` / `makeupTo`) is a
    node at the primary's pressure, holding its inventory in kg and drained
    by what it boils off and loses at a break. What flows in is the makeup.
  - **A Room Gas Outlet** brings O2 or N2 into its room (`room_air.setInject`,
    with a `full` event at 1 atm).
  - **The pumps** are base-grid loads while on (`gridAux`). A pump on a grid
    that is short and flat stops.
  - **A Fuel Hose Stand** fills a craft parked within 30 m (not one held on
    a stand: the stand fuels that).
- **The menus:** a tank's level, kg and outlet pressure, and "Fill from the
  base stores" (water $0.6/kg, coolant $4, fuel $1.1). A bottle rack's charge
  and its recharge (the H2 rack is emptied). A pump's or valve's switch and
  its flow. A regulator's set ±1 bar. A gauge's reading. Each piece's
  network and its LIMITED BY line.
- **The FLUIDS overlay** (F7 with the kit open; F4 is the camera's
  cinematic mode), `fluid_net.drawOverlay` in `lateUpdate` from this frame's
  body read:
  - each pipe in its substance's colour, amber where a valve is shut or a
    pump is off or stalled;
  - chevrons the way it flows, more of them the more it carries;
  - each tank's level, kg and pressure, each pump's flow and its in and out
    pressures, each gauge, a consumer's cell, and STARVED in red;
  - each network's card with LIMITED BY;
  - and from `reactor_plant.drawFluids`, each plant's primary as a fluid
    system ("PRIMARY COOLANT · 15.5 MPa · inventory 100 % of 1661 kg") and
    every BREAK ringed red on its pipe with what it loses.
- **Save:** `fl.<sid>` = { a, x = { { u, x } … } } (each tank's and bottle's
  contents, by part, as a list). A pump's off, a valve's shut and a
  regulator's set are part states.

### The FLUID pieces (`parts_kit` FLUID, `tools/gen_kit_fluids.py`)

| Piece | Size | Mass | Price | What it is |
|---|---|---|---|---|
| Process Pipe 2 m / 1 m, Elbow, Tee | DN25 (33.7 mm) | 4–9 kg | $55–90 | stainless on stands, ports at 0.6 m |
| Pipe Riser (one storey) | 3.06 m tall | 12 kg | $140 | its low port at this floor's pipe height, its high port 2.4 m up |
| Water / Coolant / Fuel Tank 2 m³ | Ø1.2 × 2.3 m | 0.42 t | $2,200–2,600 | under a nitrogen blanket, a level glass; filled from the stores |
| Oxygen / Nitrogen / Hydrogen Bottle Rack | 1.2 × 1.8 m | 0.24–0.26 t | $1,500–2,100 | three 50 L cylinders to 200 bar (39 kg O2, 34 kg N2, 2.5 kg H2); the H2 rack comes empty |
| Process Pump | 0.6 × 0.9 × 1 m | 60 kg | $1,400 | 2 kg/s free, nothing past 6 bar, 0.75 kW |
| Charging Pump | 0.9 × 1.1 × 1.5 m | 0.35 t | $9,800 | a triplex plunger pump to 18 MPa, 0.5 kg/s, 4 kW: the only pump that beats a pressurised primary |
| Gate Valve, Check Valve, Pressure Regulator, Pressure Gauge | inline | 3–6 kg | $80–260 | the regulator set at 5 bar |
| Room Gas Outlet, Vent Stack | | 10–15 kg | $150–180 | into the room it stands in / to the outside |
| Fuel Hose Stand | 0.8 × 1.6 m | 90 kg | $1,600 | a reel of hose and a 50 L day tank |

The Pressuriser gains a DN25 makeup nozzle on its +X (its model too). The O2
Generator gains its water and H2 nozzles at its back.

### The reactor's coolant, a fluid system (`reactor.lua`, `reactor_plant.lua`)

S6's loops keep their thermal-hydraulics (`reactor.derive`, unchanged with
no break and no makeup: `smoke_reactor` still passes all 59 checks). What S7
adds is the coolant as a substance in the loop:

- **Inventory in kg:** the primary's real water from its parts: the pipes'
  DN100 bore, the vessel's plenum (0.6 m³), 0.019 m³ a fuel channel, 0.35 m³
  a steam generator, the pressuriser's 1.0 m³, 0.05 m³ a pump, all at 740
  kg/m³ (hot, 15.5 MPa). The fixture plant holds 1,661 kg. S6's boil-off
  keeps its rating-scaled figure (`BOIL_S`) while the loop is whole; once
  broken, what boils off is real water (2.26 MJ/kg against the real kg).
- **A break** (a pipe's part state `brk`, the share of its bore; both ends
  of a guillotine break flow):
  - Over 1 cm² of bore it loses the pressuriser, so the primary boils at
    373 K and the subcooling trip fires at once.
  - The water leaves at two-phase critical flow while it is hot (10⁴
    kg/m²·s), then drains (2,500 kg/m²·s).
  - It drains what lies above the break. The pipes run at 0.6 m and the
    core stands on the vessel base above them, so a pipe-level break drains
    all but the 15 % in the lower plenum and uncovers the core (in ~10 s for
    a guillotine break).
  - Uncovered, the fuel heats on its decay heat. This 320 kW core, 12 h at
    power, peaks at 1,210 K, just under the cladding's 1,300 K, cooled by
    the steam and its own glow. A bigger or longer-run core, with more
    decay heat, is damaged.
  - A primary pipe's menu has "Cut it open (a loss-of-coolant test)" (8 s)
    and, for an Engineer, "Weld the break" (30 s).
- **Makeup** through the pressuriser's nozzle refills it, cut off as it
  fills. A process pump stalls against 15.5 MPa, and a Charging Pump gets
  in at 0.07 kg/s. After a break the same process pump injects ~2 kg/s, as
  a low-pressure injection would. That keeps a 5 % break's core covered
  (it drains 1.9 kg/s cold) but not a guillotine break's (37 kg/s): bigger
  breaks want bigger injection.
- The console's LOOPS page reads INVENTORY (with the break's kg/s) and
  BROKEN. `smoke_fluids` measures the trip, the blowdown to the break's
  level, the uncovered heat-up, and a small break kept covered by its
  makeup.

### The pressure mechanics (`scripts/room_air.lua`; §14's doors)

- **Equalise valves.**
  - Every door that isn't an airlock's has its own equalising valve:
    0.1 m³/s per atm for a door, 0.5 for a Pressure Bulkhead, 0.4 for a
    Pressure Hatch. Its menu opens it, and it shuts with the door.
  - The **Equalise Valve** piece (LIFE, 0.25 m³/s per atm) is mounted on a
    wall and joins the rooms either side of it (or the outside).
  - Open, the two sides' pressures meet as e^(−k t), k = C (1/Va + 1/Vb), with
    the gas leaving with its side's mix (`equalise`, exact).
  - The door can open once the difference is under 0.1 atm: after
    `equaliseTime` = ln(Δp/0.1) / k, which the menu shows ("~243 s").
  - Between two networks a valve is a link, stepped after each network's
    own closed form. To the outside it is a slow leak.
- **Leaks and the regulator.** A network venting only through valves and
  seal leaks that its regulators can match at 1 atm keeps them feeding: the
  slow-leak closed form with its `full`, `feed_on` and `tank_empty` events.
  A breach (an open door, a gap, a blown seal) trips their excess-flow
  valves and they shut, so a door left open doesn't empty the racks.
- **The airlock keeps its air.**
  - Its pump draws the chamber at 0.5 m³/s at the chamber's own pressure:
    p(t) = p0 e^(−S t / V). A bigger chamber takes longer; 9 m³ takes ~41 s
    to 0.1 atm.
  - The air goes into the chamber's **Airlock Receivers** (LIFE: 1.2 m³ to
    20 bar, 24 atm·m³; in the chamber or the room behind it) while they have
    room. With none, it goes back into the hab, as in S3.
  - Under its 0.1 atm floor the rest is vented, so about 90 % is kept.
  - The pump is a 2.5 kW load on the base grid while it runs.
  - Coming back, the receiver bleeds back through its check valve (REC_C)
    and the hab tops the chamber up through the chamber's valve (CYC_C).
  - **No power, or the receivers full:** the cycle vents the chamber
    through its vent valve, and the airlock says so ("airlock: NO POWER for
    its pump: venting the chamber, its air is lost"; "the receiver is FULL").
- **Forcing has consequences.**
  - "Force it open" is a timed job with the menu's progress bar:
    max(5 s, 3 s + 6 s per atm across it).
  - Its first tick warns the crew in the room about to vent (VENTING IN
    N s · Helmets on, the alarm).
  - When it is through, the door opens. A VentBurst effect (`vfx/VentBurst`:
    the blast, grit, the seal's flecks) leaves the high side, and the planet
    carries it. Crew on foot within 8 m are pulled toward the opening, a
    gentle 2.5 m/s per atm that fades over 0.8 s (`planet_walker.pull`).
  - The seal is damaged by Δp (1 − its strength) (0.25…0.55): a door forced
    once against 1 atm leaks. A Pressure Bulkhead's seal is 0.4 strong.
  - The leak is SEAL_C × the damage (0.03 m³/s per atm at worst) while the
    door is shut, named in the alarm.
  - "Re-seat the seal" is a 24 s job, halved for an Engineer, times the
    `repair_time` perk.
- **A failing door.** A seal damaged past 60 % with 0.5 atm or more across
  it fails. First comes the warning ("VENTING IN 5 s · the Door Wall's seal
  is failing"), then it BLOWS (a breach of 1 m³/s per atm) with the gust,
  until it is re-seated.
- **Bulkheads and hatches:** the **Pressure Bulkhead** (WALL) and the
  **Pressure Hatch Floor 2 × 2** (FLOOR). Each is a heavy door with its own
  equalising valve and a stronger seal, under the same rules. They are
  rooms' doors like any other, so they work on any structure. Stations wait
  on interiors Stage 2 for walking inside a moving one.
- **The suit rule.** Crew on foot with the helmet off (no sealed suit) don't
  pass a door to low pressure (its far side under 0.5 atm). This holds even
  forced, and inside an airlock its cycle to vacuum won't start. A SUIT
  caption says "Helmet off: the far side of the Pressure Bulkhead is at 0.00
  atm. Put your helmet on first."
- **Save:** `air.<sid>` gains `cells` (the generators' water) and `recv` (the
  receivers' air). A door's `seal`, `blown` and `eq` and a valve's `open`
  are part states.

### Tests and the probe

- `luajit solar/tests/smoke_fluids.lua` (36): flow is conductance × Δp; the
  pump's curve, its stall against 15.5 MPa, off blocks; a day in one step =
  86,400; pumped dry at the same moment either way; a check valve, a valve;
  the regulator holding 5 bar from 200, then wide open, 30 days one step = 30
  one-day steps; electrolysis's ratios; the cell filled, then starved, the
  limited-by line; the pieces into one network, the riser's lift, gravity
  from upstairs, two substances refused, the bores; the LOCA (the inventory
  from the parts, the trip, the blowdown to the break's level, the
  uncovered heat-up, a 5 % break kept covered by 2 kg/s); a process pump
  stalls at 15.5 MPa, the charging pump gets in, after the break the
  process pump injects.
- `luajit solar/tests/smoke_pressure.lua` (52): the slow leak with its
  regulator (one step = many), a breach shutting it; the valve's closed form;
  the door's equalising valve opening the door at the formula's time; an
  Equalise Valve piece; the airlock into its receiver (90 % kept, the time
  from its volume, back on the way in); vents with no power or a full
  receiver; the suit rule (in the chamber and at a door); forcing (the
  warning, the gust, the pull, the seal, the leak, the repair); a failing
  seal; the generator's water.
- `tools/perf/kitprobe.sh <engine> fluids` (`tools/perf/fluidsprobe_modes.lua`):
  the whole of it in the engine. The numbers are in
  `work/sandbox_s7/NOTES.md`; the pictures are `save/user/buildshots/f*.png`.

## 18. Sandbox S8: logic and automation

The plan is `work/sandbox/PLAN.md` §3.4 and §8.3 (S8). Minecraft redstone
meets real industrial controls: sensors, buttons and gates in DIN boxes on the
walls, a Signal Cable run from pin to pin, a small PLC with a 16-rung ladder,
and terminals on the doors, lights, pumps, valves, breakers and reactor
controls the earlier steps built. Ty, 11-06: cables by default, radio
channels for the runs a cable can't make.

### The rules (`scripts/logic.lua`, pure)

- **A signal** is a boolean with a value: a sensor's reading, a counter's
  count (a gate's value is 1 or 0). An input pin fed by several cables is
  their OR (redstone's wired-OR), its value the largest.
- **The network** is built from the pieces and the cables. The nodes are
  sorted by key, the strongly connected parts found (Tarjan), and the nodes
  ranked in the topological order of the parts. Anything without a loop
  settles in one pass.
- **Evaluated on change, never per frame.**
  - A node whose inputs or reading changed is marked. `evaluate` runs the
    marked nodes in rank order and marks what each changed output feeds.
  - A loop is iterated, but a node is evaluated at most `MAX_VISITS` (8)
    times a call. A loop that never settles (a NOT fed back into itself)
    stops there and is flagged `osc` (the overlay and the menu say "DOESN'T
    SETTLE"). It goes on at the next call, ticking like a redstone clock.
  - Nothing loops forever, and the answer never depends on the order the
    pieces came in. A latch made of two gates settles.
- **Time is game time.** `advance(net, st, a)` takes every timed event (a
  timer's delay, a button's pulse, a rung's delay) in time order up to agency
  time `a`, each evaluated at its own moment. One step of any length equals
  any number of short ones: an hour of a 10 s clock into a counter counts 361
  edges either way, and two delays in a chain end at their sum inside one
  five-hour step. At most `MAX_EVENTS` (2,000) events a call; past that the
  clocks jump to their phase (flagged `ff`). A load is caught up the same way.
- **Kinds:**
  - sensor: its reading against its setpoint, `above` or `below`, with
    hysteresis (on above `set`, off under `set − hys`);
  - AND, OR, XOR, NOT; timer (on-delay, off-delay, pulse, clock); latch (S, R;
    R wins); comparator (A's value against B's, or its setpoint); counter
    (IN's rising edges to its preset, R clears);
  - button and keypad (a pulse), lever, radio tx/rx, the ladder controller,
    and the devices (below).
- **The ladder (PLC):**
  - X1–X8 in, Y1–Y8 out, M1–M8 inner relays; 16 rungs `IF a [AND|OR b] THEN
    coil [after d s]`, each contact normally open or closed, each coil OUT,
    SET or RST.
  - A scan runs the rungs top to bottom on the registers as they change, as
    a real PLC's does. Scans repeat until nothing moves (at most 4 a call,
    else flagged). A rung's delay is an on-delay on its condition.
  - A rung is kept as text (`X1,0,AND,M2,1,SET,Y3,5`) in the part's state.
- **The save:** `pack` writes flat records (latches, counts, levers, timers'
  clocks, the relays as bit strings, what each device was last told), lists
  only, never deeper than the save holds.

### The pieces (`parts_kit` LOGIC, `tools/gen_kit_logic.py`)

| Piece | What it does |
|---|---|
| Signal Cable | the drum: 2-core 1.5 mm² screened control cable, $1.20 a metre, 45 g/m, up to 150 m a run |
| AND, OR, XOR, NOT Module | one function each in an 18 × 22 cm DIN enclosure (RAL 7035, a colour stripe per function), 0.8–0.9 kg |
| Timer Relay | on-delay, off-delay, pulse or clock, 0.5 s to an hour |
| Latching Relay | S sets, R resets; it holds through a power cut and a reload |
| Comparator | A's value against B's or its setpoint, with hysteresis |
| Counter Module | IN's pulses to its preset; R clears |
| Pressure Switch | the room it faces into, atm |
| Gas Analyser | the room's O2 or CO2 in % of an atmosphere |
| Temperature Transmitter | within 8 m of a reactor: its primary loop (or the fuel); else the outside air |
| Flow Switch | within 4 m: a reactor loop's coolant flow, or a pipe's, kg/s |
| Level Switch | the nearest tank, bottle rack or air tank within 4 m, % full |
| Battery Monitor | its base grid's charge, % |
| Area Radiation Monitor | the dose rate where it hangs, % of a lethal dose an hour, walls counted (`base_shield.doseAt`) |
| Presence Detector | the nearest crew member on foot, m |
| Daylight Sensor | the sun's height over its horizon, % of overhead light |
| Reactor Power Monitor | within 30 m: the plant's power % or k |
| Door Contact | the nearest door within 2.5 m, % open |
| Push Button, Lever Switch, Keypad | a 1 s pulse; a position; a 3 s pulse for the right code (an Engineer sets it) |
| Indicator Lamp | a 22 mm pilot lamp: green, amber, red or white |
| Alarm Beacon | a rotating red beacon and a klaxon |
| Radio Transmitter, Receiver | channel 1–16, to every receiver on it within 2 km |
| Ladder Controller | the PLC on its desk: its CRT, the 16-rung editor, X1–X8 and Y1–Y8 on a terminal rail at its back |

Wall-hung gear is a `mount`. Its cable glands, and so its pins, are on its +Z
end (down, on a wall): inputs left, outputs right.

**The old pieces' terminals** (`lg.kind = "device"`):

| Piece | In | Out |
|---|---|---|
| Door Wall, Double Door, Bulkhead, Hab Door Bulkhead, hatches | `open` (held open; still interlocked and pressure-held), `lock` (kept shut whoever walks up) | `state` |
| Airlock Wall | `cycle` (the chamber asked to cycle to this door while on), `lock` | `ready` (the chamber at this door's far side, every other door shut), `state` |
| Light Fitting | `on` | |
| Process Pump, Charging Pump | `run` | |
| Gate Valve | `open` | |
| Breaker Panel | `close` (off opens it; on recloses it, but never a TRIP: that waits for a hand) | `tripped` |
| Coolant Pump | `run` | |
| Reactor Control Console | `scram` (a rising edge), `setback` (while on, the setpoint drops to the console's setback %) | `tripped` |
| O2 Generator, CO2 Scrubber | `run` (off, it makes nothing and draws nothing: `room_air.setMachine`) | |

Pins are in the piece's frame. `logic_net.pinLocal` turns one into its
structure's frame through the piece's yaw, pitch and roll.

### The scene (`scripts/logic_net.lua`)

- **Built** when the logic signature changes: the logic pieces, their place
  and settings, and the cables. A light switched or a door opening never
  rebuilds it. Debounced 0.3 s; the state is kept by piece across a rebuild.
  A sensor's target (its room, the plant, the pipe, the tank, the door) is
  found once at the build, from the records.
- **The clock:** sensors are read every 0.25 s, and a reading that crosses
  nothing marks nothing. The network is stepped at most ten times a second,
  and only when something is due or marked. Idle, nothing is evaluated.
- **Devices:** a command goes out when an input changes.
  - Doors (`open`, `lock`) are LEVELS that kit_live asks every step it moves a
    door (`doorCmd`). A door a signal holds open is stepped wherever the crew is.
  - An airlock's `cycle` keeps `room_air.requestDoor` alive while it is on,
    as a crew member at that door would. `room_air.airlockReady` is its `ready`.
  - Lamps and beacons are levels (a beacon's lens flashes at 2 Hz, its klaxon
    loops).
  - Lights, pumps, valves, breakers (`base_power.setBreaker(…, "logic")`),
    reactor pumps and SCRAM (`reactor_plant`) are edges: a hand may switch
    them between edges.
  - A cable laid to a device applies its level once (it takes over); a cable
    taken up lets the hold go.
- **SAVE:** `lg.wires` (each cable's ends, its frame's structure, its settled
  points, the ground under it, what it cost), `lg.seq`, `lg.st` (the packed
  state) and `lg.a`. A piece's settings (`lp`: setpoint, mode, delay, preset,
  channel, colour, code) and a ladder's rungs (`prog`) are its part state.

### The Signal Cable

- **Laid as a Power Cable is.** With the drum in hand the cursor picks the
  piece and the pin nearest the cursor (`pinNear`; the far end must be the
  other kind: out → in). LMB makes it off; LMB on the other pin lays it. It is
  one step in the undo ring, refunded in full within the minute. A piece taken
  down takes its cables up; "Take up its signal cables" is on every piece's menu.
- **It settles the way base_cable's do** (`base_cable.settle`, `thin`):
  - in the frame of the structure its output end is on, with stations every
    0.1 m along the line between its pins;
  - a catenary laid slack by hand (`a` = 0.35 × the span, never stiffer than
    a 3 N pull in this gravity);
  - lying on what is under it: the tops of the floors, slabs, decks, blocks
    and props of any structure within reach (by record, the two end pieces
    skipped), and the ground sampled once at laying.
  - A 6 m run between two wall pins hangs from both and lies along the floor
    between. It is settled again when the floors under it change (a
    per-structure signature), never in a frame.
- **Drawn** as one mesh per structure (a 6-sided 9 mm tube, dark blue PVC),
  body-relative, spawned while the crew is on its world.

### The LOGIC overlay

F5 with the kit open (`drawOverlay` in `lateUpdate`, this frame's body read):

- every cable over its settled path, **orange while its signal is on** with
  chevrons running from the output to the input, grey-green while off, yellow
  in a loop that doesn't settle;
- a lamp at every pin, lit or dark;
- each piece's tag: its reading against its setpoint ("GAS ANALYSER · ON /
  18.5 % · < 19.0 %"), a timer's time left, a count, a radio's channel, the
  PLC's Y register, a device's wired terminals;
- dashed lines between radios on one channel.

### The Ladder Controller

- **Its CRT** (`img:text` in SolarMono on its Screen quad, the reactor
  console's way) shows the run state and X, Y, M as bits in the header, then
  the 16 rungs as ladder text (`-[ X1]---AND-[/M2]---(SET Y1) 5s`) between two
  power rails, an energised rung lit. It is repainted when the network moved,
  at most twice a second, while the crew is within 30 m.
- **The editor** (right-click → Program the ladder…; `LogicLadderPanel`, a
  `panel/frame` over a `hud/instrument` well of `crt/row` keys) shows the
  registers as lamps, then one row a rung: contact A, NO/NC, AND/OR, contact
  B, NO/NC, OUT/SET/RST, the coil, the delay, the rung in words, and ✕.
  **A click steps a cell, Shift+click steps it back**, each with a key
  strike, and the edit is live at once. Run/Stop; Esc or Done closes it.

### The examples (tested in `smoke_logic`, run in the probe)

- **Auto-airlock** on a Ladder Controller:
  - wiring: the button outside → X1, the outer door's `state` → X2, its
    `ready` → X3, the inner door's `state` → X4; Y1 → the outer door's
    `cycle`, Y2 → the READY lamp, Y3 → the inner door's `lock`, Y4 → the
    outer door's `lock`;
  - rungs: `X1 SET M1`, `X2 RST M1`, `M1 → Y1`, `X3 → Y2`, `X2 → Y3`,
    `X4 → Y4`;
  - pressed, the chamber pumps down and the lamp lights (and stays lit while
    the chamber is at the outside's pressure). An airlock cycled to a door
    opens it as soon as it is ready for crew within 6 m (as for crew who walk
    up), so the door opening is what serves the request (rung 02). The inner
    door is locked meanwhile; room_air's own interlock stands behind it.
- **Low O2:** a Gas Analyser (O2 under 19 %) → the O2 Generator's `run` and
  an Alarm Beacon.
- **Reactor protection:** a Temperature Transmitter on the primary → the
  console's `scram`; a Flow Switch (under 2 kg/s) → a standby Coolant Pump's
  `run`; both through an OR into a beacon. In a real plant put a Latching
  Relay between the switch and the standby pump (the probe does): the switch
  sees the flow the standby pump brings back, so wired straight the pump
  stops again and hunts round the switch's hysteresis.
- **Day/night lights:** a Daylight Sensor (under 5 %) → the lights' `on`.
- **Load shedding:** a Battery Monitor (on above 30 %, off under 25 %) → a
  Breaker Panel's `close`.

### Cost

- Idle: the sensors read every 0.25 s and one comparison a frame with the
  next timer's due time; nothing is evaluated.
- 200 gates switching: 0.02–0.05 ms an evaluation in luajit. The probe's
  numbers are in `work/sandbox_s8/NOTES.md`.

### Tests and the probe

- `luajit solar/tests/smoke_logic.lua`:
  - the gates, wired-OR, the comparator's and a sensor's hysteresis, the
    counter;
  - timers on game time: on-delay, off-delay, pulse, a chain of delays inside
    one long step, an hour of a clock in one step = 3,600 steps, the
    fast-forward bound;
  - pack/unpack and a rebuild in another order (a latch, a count, a lever, a
    timer half way);
  - loops: a NOT on itself bounded and flagged, a two-gate latch settling,
    order independence;
  - the ladder: text and back, NO/NC, AND/OR, SET/RST, a delayed rung, the
    editor's clicks, stop;
  - the Signal Cable: its pins, the price, lying on the floor, taken up with
    its piece;
  - the five examples on stub doors, rooms, plant and grid; a timer under
    1,000× warp; save and reload in the middle of a cycle (the relay, the
    airlock's hold, a half-run delay ending on time, the cables where they lay);
  - radio (channel, 2 km); 200 gates' cost; idle.
- `tools/perf/kitprobe.sh <engine> logic` (`tools/perf/logicprobe_modes.lua`):
  the examples built and triggered in the engine, the overlay, the CRT and the
  editor, the cost, save and reload. Pictures `save/user/buildshots/l*.png`;
  numbers in `work/sandbox_s8/NOTES.md`.

## 19. Playtest 11-09: the builder fixes, and the full builder for bases

Ty's playtest of the 11-06b build (3dd2f19): floors that touch what holds
them were refused, the tower could be placed nowhere, snaps were sometimes a
few degrees off, typing in the search drove the game, and the direction:
"the base building parts should all be in the vab categories … a main base
hub … full access builder so people can build their wildest creations".

### Support through connections (`kit_snap.supportMap`)

- **A structural graph.** Every piece of a structure is a node; two pieces
  are joined when their solids touch:
  - **on**: a rests on b's top (or a deck): it takes b's hang as it is;
  - **side**: they touch side to side (a floor beside a floor, a floor at a
    wall's face, wall corners): either takes the other's hang + 1;
  - **under**: a hangs under b: + 1.
- **Hang 0** is a piece on the structure's ground: its base at the
  structure's plane, or set on the terrain (`gnd`, written by every ground
  placement: the grid, Shift's free, a slab edge to edge; or a footing). A
  piece is held when its hang is at most `MAX_HANG` = 2: a floor, a slab, a
  hab ring, a laid beam or a block may reach two modules (4 m) from what
  holds it from below, so an 8 m room roofs over without a pillar and a
  balcony stands 4 m out (the old rule allowed one module beside a floor
  that rested, and nothing else). A wall only stands on something or hangs
  under it: a panel bolted at one end over air is still refused. Mounts are
  held by their face and hold nothing up.
- **Cost:** a 0-1 breadth-first search from the grounded pieces over a 2 m
  cell index (never all pairs), kept per structure until its parts change.
- `fallsWith` reads the same map, so a mezzanine floor hung on one wall
  comes down with that wall, but not when a pillar under it holds it too.

### Snaps exact

- **A joined piece turns in quarter turns** (`kit_snap.face`): the wheel's
  15° (5° with Shift) no longer adds to a wall on a floor's edge, a floor on
  a wall, a post, a hab ring; a block or a prop on a top keeps clean 15°
  steps. (The wheel's degrees went straight into the joined yaw: the "a bit
  off".)
- **Ground near a structure joins it** (`base_snap.snap`, `JOIN_R` = 12 m):
  laid in that structure's frame (its up exactly, its 0.5 m grid, quarter
  turns square to it) at the ground's height there; the foundation adds the
  cut and fill. A new structure of its own stood on the radial up a few
  metres on, tilted against its neighbour by the world's curvature (0.7° at
  10 m on a 775 m world), and its pieces could never hold the other's up.
  Farther out, a new structure square to the nearest as before; Shift still
  frees it.

### The tower

The rule was 1 km between towers, the Tracking Station included. Measured
(`fullbuildprobe.sh fbdiag`): a 922 m world; 210–230 m from the spaceport
every spot read "223 m from the spaceport's Tracking Station: towers stand
1.0 km apart", and 2.7 km round on the far side every spot was valid. So to
a player building near home it could go nowhere. Now 300 m (twice the base
radius), and the reason says how much further.

### Typing keeps its keys (`scripts/input_guard.lua`)

The step-7 fix asked each reader whether a "Field…" node had focus; the
inventory's Tab and I, the jump action, the belt's Q and R and the kit's
own keys never asked. The guard wraps the shared `input` table's readers
once (on the Build Kit node, the menu and the standalone builder): while a
text field is focused every raw key but Escape and Enter answers "not
pressed", and every keyboard action (Jump, Move, Interact, Sprint, Crouch,
Fly, Turn, ShiftLock, Context) answers nothing; the mouse's (Look,
LookEnable, LookFree, Zoom, Fire) and Pause still answer. `input.rawKey /
rawPressed / rawReleased` are the unwrapped readers. The focus is read once
a frame.

The root of "it selects previously selected parts": the engine's UI
navigation counts **Space as submit** even in a focused text field, so a
space typed into the part search fired its `submitted`, which picked the
first card and dropped the focus; every key after it drove the game. Every
field's `onSubmitted` now starts with `input.spaceSubmit(node)` (true when
Space, not Enter, fired it: ignored, the field keeps the focus). The engine
card is in work/fullbuilder/NOTES.md. Measured (`fbfix`): with the search
focused, I, Space, E, B, 3, W, M, G, R, Backspace and Tab leave the field
focused, the inventory shut, the crew on the ground, the kit open and the
part in hand.

### Two from the S8 probe

- **Grass through slabs after a reload** (`flora_field` struct_clear): the
  first 30 s of a scene pass every second instead of every 3 s, a plant still
  settling after the load counts by where it is (up to 3 m over the floor),
  and a slab or floor set on the terrain (`gnd`, joined at the ground's own
  height) counts at its own height, not only at the structure's plane.
- **Crew on the roof after a reload** came from the probes' `KIT.tp`: its ray
  started 4 m up and met a hab's roof first. It now starts 1.2 m over the
  floor asked for. The game's own restore (`game_manager` `p_*`) puts the
  crew back exactly where `saveGame` found them; a probe that reloads with
  `save.flush` alone gets the last autosave's spot.

### Every part in the builder

At a Build Stand or a Base Hub (the overlay on the world, where the Build
Kit's scripts are) `builder.registry()` joins `base_hub.register`: the BASE
section and every kit category, each piece in every material it comes in
("Wall · Concrete"), one section per category as `parts_kit.catalogue`
gives them, so a new category (S8's logic) appears without a change; a title
the VAB already uses reads "BASE FRAME", "BASE NUCLEAR" (tab "B·FRAM"). The
VAB itself keeps its list. A base piece's builder entry carries `base`, its
structure id and `npiv`: the prefab's root (its ground point, plus a BASE
part's seat) from the box centre the builder works in (`builder.nodeAt`),
and it is drawn without its colliders (`spawn{ body = false }`). A reactor
piece is behind its research as on the Build Kit.

In the builder a kit piece aimed at a base piece snaps as the Build Kit's do
(`builder.kitSnap` → `kit_snap.face`: exact, on the grid, quarter turns from
the part's keys, the kit's own overlap rule naming what is there); on the
floor its ground point goes on the 0.5 m grid (Shift frees it); on a VAB
part it surface-attaches like any part.

### The Base Hub (`scripts/base_hub.lua`, `build_host` hub session)

- **A BASE part** (`baseHub`, prefab `BaseHub`, 0.9 t, $2,500), placed with
  the Build Kit. Its menu's **Build the base** (Engineers) opens the VAB
  overlay anchored to the hub's structure: the BuildFrame is the structure's
  own frame (+X right, +Y up, +Z front; frame y 0.11 is its ground plane),
  posed every frame from the record, so a builder coordinate is a structure
  coordinate. Stands keep building crafts; the hub builds the base.
- **While you build** the structure is held out of the world
  (`structures.suspend`): its nodes go (the builder's copies are the only
  ones drawn and the camera meets no invisible walls), its live vessel
  stands down; every part of it is on the stand to edit. The camera starts
  from where the Engineer stood, looking at the hub. Nothing is loose in a
  base (every group stands on the ground), and the CHECK's craft rules don't
  gate anything.
- **In and out.** `base_hub.toBuilder(rec)` is the structure as a
  launch-format blueprint, its uids kept; `fromBuilder` turns the builder's
  parts back into entries (`builder.hubParts`: each at its own pose, the
  VAB's recentring and a rover's quarter turn undone). A base piece goes to
  its ground point. **Any VAB part** (struts, beams, engines, tanks, a
  cockpit, dishes, robotics) becomes a live part `vab.<id>` whose whole
  launch record is kept beside the structure (`slivebp.<sid>`), and whose
  figures are learned once (`vabdefs`, `parts_kit.learnVab`) for the world
  that carries no registry; struct_live builds the anchored structure vessel
  from those records (a drawn strut at its size, a cockpit turned as it was
  built, the crewed part its root): S2's rule, for every part.
- **LEAVE, ESC or BUILD IT ▸** commits (`base_hub.commit`): parts added are
  charged once, with one truck; parts taken off come back by the deconstruct
  rule (their own `paid`); moved parts are free; the hub never moves or
  goes, nor a part whose script refuses (a stand holding a craft). A part
  the agency can't pay for is refused at placement (`ctx.afford`), as at a
  stand. The structure is then spawned again from its records.
- **Blueprints** carry a hub-placed VAB part's launch record in the file
  (not in the code), and a paste writes it back.

### Tests and the probe

- `luajit solar/tests/smoke_fullbuild.lua` (50): support through
  connections (a mezzanine, two modules out but not three, an 8 m roof, a
  wall on air, `gnd`, what falls with a wall), snaps exact (quarter turns
  whatever the wheel, 15° blocks, the 12 m join in the frame, 20 m a new
  structure, Shift free), the input guard (keys, actions, the mouse, a
  button, installed once), the 300 m spacing, the hub's catalogue (sections,
  "BASE …" titles, materials, no fitting twice, hidden pieces, npiv), the
  round trip (to 1e-9 m, a laid truss, a seated tower), the diff, the commit
  (one truck, the refund, the records and the learned part), the structure
  vessel from the records, `suspend`.
- `tools/perf/fullbuildprobe.sh <engine> fbdiag|fbfix|fbhub|fbmake`
  (PATCHES=funds.patch; `tools/perf/fullbuildprobe_modes.lua`): the tower's
  reasons near and far; the fixes through the Build Kit's own path (a wall
  dialled 15° placed square, a slab 6 m off joining, a balcony three
  modules out in Career and a fourth refused, typing in the search with the
  keys that leaked, a tower 360 m out); the hub (placed, opened from its
  menu, every section, pieces through the builder's command and one through
  the ghost and a click, an I-beam, a cockpit, an engine and a dish,
  BUILD IT, the structure vessel, opened again and left for $0); and five
  creations (`params.set` 1: outpost, hab, reactor shed; 2: contraption,
  masts), each pictured and saved as a blueprint. Pictures
  `save/user/buildshots/fx*`, `fh*`, `m*`; the numbers in
  `work/fullbuilder/NOTES.md`.
## 20. Expansion X1/X2: the outside's air in a room, and the survey pieces

Built 2026-11-09 (`work/expansion/PLAN.md` §6.3, §7.2). The air itself is
`scripts/atmo.lua` (`docs/crew-and-items.md` §11).

### The outside (`scripts/room_air.lua`)

- On a world whose air was chosen (`world.<name>.air`, not an old save's),
  the outside is that air: pressure `p0 · share` (the aero model's density
  share at the structure's height), its O₂ share and its **CO₂ share** (CO₂
  plus SO₂, which an amine bed also takes). `outsideOf(air, share)` is the
  pure rule. An old save's outside is what it was (O₂N or none, no CO₂).
- A room that closes round the outside starts as it is: on a CO₂ world it is
  full of CO₂ and unbreathable (`CO2_MAX` 0.02 atm). A vent relaxes every
  amount, CO₂ included, to the outside's, exactly (`advance`'s `cout`; one
  step = many to 1e-6 in smoke_atmo).
- **Flushing is the work**: ten scrubbers take two days to clear a 30 m³ room
  of a CO₂ world's air; the Air Tank Rack's **Purge** (§36) pumps it overboard
  and refills the room with air in minutes.

### The new LIFE pieces

| piece | does | power | mass |
|---|---|---|---|
| N2 Compressor | pulls the outside air through a membrane: feeds the room the outside's mix less its O₂, 0.004 atm·m³/s (14 m³ an hour) up to 1 atm, as an outlet does (`life.n2`; `JN`, `Jc`). On an N₂ or N₂/CH₄ world that is inert makeup; on a CO₂ world it is mostly CO₂ and the scrubbers must run. Nothing under 0.05 atm outside. | 1.2 kW | 160 kg |
| O2 Concentrator | a pressure-swing unit: makes O₂ like the O2 Generator, holding the room at 21 %, from any outside air with 5 % O₂ and 0.01 atm of it: no water (`life.o2c`, added to the room's `G`) | 2 kW | 110 kg |

### The SCIENCE section (`scripts/survey.lua`)

| piece | does | power |
|---|---|---|
| Telescope 0.3 m | a reflector on a pier and an equatorial mount; a Scientist at it sweeps a world (right-click → Sweep): temperature and air 0.3 | 0.15 kW |
| Telescope 1 m | a Serrurier truss on a fork mount with a spectrograph: 0.6 | 1.2 kW |
| Survey Station | a weather mast, a buried seismometer and a magnetometer boom on its own panel: fills its world's composition (10 min), temperature and air (6 h) and field (a day) | its own |

Models: `tools/gen_kit_survey.py` (imported by `gen_kit_parts.py`:
`python3 tools/gen_kit_parts.py n2comp o2conc telescope telescope1m
surveyStation`); the bounds are in `tests/fixtures/kit_shapes.lua`.

## 21. Expansion X3: runs — fly it once, then automate it

Built 2026-11-09 (`work/expansion/PLAN.md` §2, with Ty's answers in §14,
which override §2 where they differ). The rules are `scripts/routes.lua`
(pure); the scene half is `scripts/route_ops.lua`.

### Ty's rules

- **An automated run never fails on its own.** There is no failure roll: a
  run replays a flight you flew, exactly. Each cycle costs what that flight
  cost (its time, its fuel, what it took from stores) and delivers what it
  delivered, so a better-flown route pays.
- **Only a flight that closed can be automated**: it came back to the stand it
  left from, whole, and it can start again from what it came back with.
  Anything else is refused, and the stand says why in plain words.
- A flight you fly by hand that goes wrong costs what it costs, as always.
- **Crewed runs need a Pilot** among the crew who flew it, and the crew go
  with the run. Their air and suits restock at home, so a crewed run's stand
  is on the home world.

### The flight log

Every craft commissioned on a Build Stand is logged (craft_stand calls
`route_ops.onCommission`, `onRelease`, `onReturn` and `onGone`). The log keeps
events, not telemetry, at 4 Hz while the craft is out:

- **stops**: down and still for 5 s, more than 30 m from the stand (they end
  when it moves over 1 m/s or 25 m), with the time and the fuel at each end;
- **who rides it** (seated crew make it a crewed flight);
- **every transfer into or out of its hold**: inventory.lua now keeps a move
  ring (`moveSeq`, `movesSince`), and `routes.ledger` traces each move through
  the crew's packs. A crate → pack → hold load is the crate's; ore dug into
  the pack and put in the hold is "by hand"; hold → pack → crate is an unload
  into the crate; the depot's crane is an unload into the warehouse;
- up to 16 **map samples** (body-relative) for the station's dashed track.

Points are body-relative (`docs/positions-and-frames.md` rule 1). The log of a
craft out in the field is kept in the save by its name (`rlog.live`), so a
reload mid-flight keeps it; a closed log is kept on its stand
(`rlog.<sid>.<uid>`). A log stops at 64 stops and transfers and says so.

### Repeatable or not (`routes.fromLog`, `routes.check`)

| refused when | the stand says |
|---|---|
| it isn't back on a stand, or came back to another one | a run starts and ends on the same stand |
| it came back without parts (stages dropped, parts lost) | "it came back with 5 of its 7 parts: …a run repeats only a craft that comes back whole" |
| it never stopped away from the stand | a run needs a stop to load or unload at |
| a **probe** flight loaded ore dug by hand | "…came out of the crew's pack (gathered by hand): a probe run can only load from a store that stays there…" |
| it refuelled off the home world | a run can't draw on a base's tanks yet |
| a crewed flight's stand is off the home world | a crewed run's air and suits restock at home |
| it came back with more or less in the hold, away from the spaceport | unload it into a store first (only a stand by the spaceport trades with the Intake and the warehouse) |
| nothing was delivered | a run has to carry something from one place to another |
| cargo left the hold by hand and wasn't put in a store | a run can only unload into a store or the Intake |
| (live) no Pilot flew a crewed run; you are playing one of its crew; a store it used is gone; its stand is gone | said by name |

The stand's own rule refuels a craft it holds (vessel_controller: an anchored
craft fills from the stand), so fuel restocks on the stand; the fuel a cycle
burns is shown on the card and the Automate row.

### The run

A run is a cycle of phases: the **dwell** on the stand (120 s), then each
**leg** and **stop** as flown (their recorded durations). The transfers happen
where they were made: a stop's at its end, the departure's (a load at the
stand) as the dwell ends; and when it is back on the stand by the spaceport,
whatever it brought home goes through **the Intake** (the warehouse, the
freight count, `research.study`'s RP, the lab's capsule: material_intake's
own path) and what it took out of the hold is restocked from the warehouse.

`routes.advance(run, W, now)` walks the phases on the agency clock, in closed
form: one long call equals many short ones exactly (30 days in one call =
2,592,000 one-second calls, smoke_routes). route_ops calls it once a second
and on load, so a run keeps going while you are anywhere else, and catches up
in one call. If a store is short when a transfer is due, the run **waits**
there and says so ("waiting for Depot crate A: 10 of 20 Iron Ore"), and goes
on once it can: that is never a failure. A cycle a run does is a real
`inventory.transfer`: the crate empties, the warehouse fills.

**Where the craft is.** On the stand during the dwell: the stand draws it
(its display copy, untinted: no body, no script, nothing a tick). On a leg or
a stop it is only on the map, where `routes.poseAt` places it (the stop, or
the leg's samples interpolated in the body frame: map only, never physics).
The stand is the run's while it lasts (state `run`): nothing else goes on it,
it can't be cleared, raised or removed.

### On the stand's right-click

- **FLIGHT LOG · This flight can be automated ▸** and **Automate ⇄** with the
  cycle's numbers ("4 m 33 s · 30 kg fuel · 25 Iron Ore a cycle"), or
  **Why it can't be automated ▸** (the reason, in full) and Automate greyed
  (its tooltip says why).
- While it runs: **RUN** (where it is in its cycle), **CYCLES** (done, and
  what it has moved), **Pause the run / Resume the run**, **Cancel the run**
  (at once while it is on the stand; otherwise when it is back there; a run
  waiting at a stop skips what it can't do there and comes home).
- The first automatable flight in a save gets Ops' caption: "That's a route
  now. Put it on the stand and I can run it for you." Until the first run the
  station's list says "RUNS · none yet · fly a cargo flight from a Build
  Stand and back".

### In the Tracking Station (`docs/tracking-station.md` §3)

- A **RUNS** group (glyph ⇄, kind `route`, between PROBES and LANDED), one
  entry a run, `R:<id>`, anchored each frame where `poseAt` puts it, with its
  situation line: "Leg 1/2 · to stop 1 · 1 m 12 s", "At stop 1 · loading 25
  Iron Ore · 40 s", "On the stand · departs in 1 m 30 s", "WAITING · …",
  "PAUSED · …". A waiting run is in ATTENTION.
- The selected or hovered run's leg is drawn dashed (its samples against this
  frame's body read).
- **NEXT** lists each run's next two events (departs the stand, arrives at
  stop 1, leaves it, back on its stand), so **▸▸ To next event** warps to one.
- **The card**: the cycle and its length, the fuel a cycle, where it is, the
  manifest by place ("At stop 1: load 25 Iron Ore from Depot crate A", "Back
  on the stand: unload 25 Iron Ore at the Intake"), PROBE or the crew, the
  cycles done, what it has moved and the RP, and Focus · Pause/Resume ·
  Cancel run (twice). The right-click on its icon or row has the same.
- The crew of a crewed run are busy while it lasts (`crew.busy`: "on an
  automated run (…)"): no switching to them, no seating them elsewhere.

### The respawn clock fix

`space.time()` restarts at 0 every session, and `flight_ops.respawn` carried
a craft in flight along its conic by `space.time() − rec.stime`: wrong after
a reload. A fleet record now carries `at` (the agency clock) and is carried by
`carryDt` (the agency difference); the station's and the comms network's
carries get the record's time as this session's sim time (`simTimeOf`).
Records written before keep the old rule.

The agency clock itself (deployables) was saved every 5 real seconds; at
×100 a save taken between two writes lost up to 500 game seconds, and a
reload ran the clock back behind the runs' schedules. It is now also saved
every 30 game seconds and when the scene changes, and a run whose clock went
back carries on from the clock rather than standing still.

### Cost

Nothing a frame while no craft is logged and no run exists (two table looks).
With runs: one `advance` a run a second; the station adds one entry a run and
one dashed line for the selected one. Measured in `tools/perf/runprobe.sh`
(the numbers below).

### Left for later

- Refuelling off the home world from a base's tanks (a hose stand's network),
  and loading from silos and chutes (X5) — today a probe run loads only from
  stores that stay put (the spaceport's supply crates, a locker, the
  warehouse).
- Re-record (fly the next cycle by hand and replace the legs) and "trim to
  the best of N cycles"; today: cancel, fly it again, Automate again.
- The live held craft during the dwell (hoses on, the silo emptying): the
  dwell draws the display copy, which costs nothing.
- The PROGRAMME's "Reach" stage naming runs.
- A run moves one craft between its stand and its stops; two runs can't share
  a stand.

### Tests and the probe

- `tests/smoke_routes.lua` (luajit): the ledger on the real inventory.lua, a
  hand-written log to a run, every refusal, check(), 30 days in one call
  against one-second calls, waiting and refilled, pause, poseAt, NEXT, the
  scene half against stubs (a flight through the hooks, Automate, the
  Intake's RP equal to `research.study`'s, three cycles, the JSON save and a
  reload, cancel), the respawn clock fix, the RUNS group.
- `tools/perf/runprobe.sh <engine>` (PATCHES=funds.patch): the whole slice in
  the engine; `RN PASS|FAIL` lines, pictures in `save/user/runshots/`.

## 22. Expansion X4: materials and crated parts (N2, N3, N5, N6, N8)

The material layer the quarries and belts (X5) and the refineries and the
Fabricator (X6) stand on. Nothing here refines or fabricates: it says what
things are made of, makes a part a thing you can carry, and lets an Engineer
build off the home world from what was carried there.

### What a player can do

- **At home, order a part crated.** In the Build Kit, with a part in hand,
  **K** buys it crated: the same price + shipping as placing it (the ledger
  says "Wall, crated · $600 + $110 shipping (shipped by …)"). The crate is
  loaded into the nearest container within 30 m with room: a craft's hold, a
  locker, a supply crate; the pack last. Nowhere with room: refused, nothing
  charged.
- **Carry it.** A crated part is an item, `part:<part id>` (kind `"part"`):
  it weighs the part's dry mass and takes `recipes.crateLitres` of room (the
  part knocked down to a quarter of its standing box, never lighter than
  0.25 kg a litre of crate). So a suit pack takes a light fitting, a supply
  crate (400 kg / 480 L) three steel walls, and a pod or a slab needs a
  lander's holds. The inventory panel puts items into and takes them out of
  a craft's hold as it does a crate's.
- **Build off the home world from it.** On any other world a placement draws
  one crated part from any container within 30 m of the Engineer, nearest
  first, the pack last (N8, Q16). The card reads "2 crated · in reach · Supply
  drop"; the hint "LMB places it from …". Only a footing's concrete is paid
  for. **Ctrl+Z** within the minute and **Deconstruct** later put the part
  back in its crate: into the container it came from if that is still in
  reach, else the nearest with room (refused, with the reason, when nothing
  in reach has room).
- **See what it is made of.** The parts column's preview plate shows the
  recipe: at home "CRATED · K ships one to you: $710 · 111 kg, 220 L" and
  "OFF-WORLD IT IS MADE OF 111 kg Steel + $60"; off-world "IN REACH" or "NONE
  IN REACH" and "A FABRICATOR MAKES IT FROM Steel 40 kg/119 kg + $48
  fittings", the have counting every container in reach. With no crate in
  reach the card says "no crate · made of …" and the ghost is red with the
  reason.
- Pastes and blueprints are one delivery: home world only. In the sandbox
  money is no object and the kit builds anywhere for money, as at home.

### The recipe (`scripts/recipes.lua`, pure)

`recipeFor(def, section, id)` → `{ kg, mats = { { mat, kg } … }, fittings,
secs, perMetre, shipOnly }`, in kg of the part's dry mass m (N5):

- **structure**: 60 % of m as Steel; Alloy for AIRCRAFT, ROVER and AUTO parts
  and engines; tanks 40 %; the Pad Plate and the Shield Wall all Regocrete.
- **Wiring** 10 % for anything with a command, battery, antenna, solar,
  light, drive, servo, claw, drill or RTG module, a power source or store,
  a door or a screen, and engines.
- **Glass** 10 % for crewed parts (not a bare seat), solar panels, kit pieces
  with a window or porthole, the Surface Hab and the Base Hub.
- **fittings** in money, 20 % of the price (Q22); 10 % for structural kit
  pieces and the BASE concrete.
- **A kit piece** is its own material (its mass is its material): steel →
  Steel, concrete and regocrete → Regocrete, glass → Glass; a wired piece
  gives 10 % to Wiring.
- A cable's recipe is a metre's (copper cores and steel armour).
- **Made at home only** (`shipOnly`): the Isotope Skid and Cell, graphite.
- A Fabricator's time (for X6): 10 s + 20 s a tonne.

N6's worked numbers hold: Pod Mk1 780 kg Steel · 130 Wiring · 130 Glass +
$100; the FT-S tank 80 kg Steel; the Anvil 540 kg Alloy · 90 Wiring; the
Shield Wall 4.6 t of Regocrete. `luajit solar/tests/smoke_recipes.lua -v`
prints all 311 recipes.

### The containers (N8)

`inventory.KINDS`: a Fabricator's store `fab:<id>` (2,000 kg, 4,000 L), a
silo `silo:<id>` (8,000 kg, one material at a time), a hopper `hopper:<id>`
(4,000 kg). Nothing makes them yet (X5, X6); the rules and capacities are in.
`recipes.reachOrder` and `recipes.drawFrom` are the reach rule as pure
functions, for runs that load at a stand without a chute (X5).

### Save keys and old saves

- Crated parts ride the existing item bags (`inv.gear.<cid>`) under
  `part:<id>`. `items.partdefs` remembers each one's name, kg and litres, so
  a scene without the Build Kit's scripts (the VAB) still weighs a hold of
  them.
- A part placed from a crate carries `paid.item` (the container it came
  from) in its structure record.
- Nothing old changes: no key is renamed, and a save without these keys
  loads as before (no crated parts, no refined stock).

### Cost

Nothing a frame while the kit is closed. While it is open off the home world
the reach scan runs at most twice a second (node-to-node distances, one item
list a container); recipes are memoised per part, and the column's section
lookup is now one table read (it scanned the catalogue for every card).
Measured in `tools/perf/matprobe.sh` (numbers in the X4 notes).

### Left for later

- The Fabricator and the refineries (X6) make crated parts and refined
  materials off-world; nothing makes refined stock yet, so it shows only in
  recipes, the plate's have and the codex.
- A footing off-world is still a shipped dry mix (money), not Regocrete.
- Cables and signal wire are still bought by the metre off-world.
- The full Base Hub builder and the stand editor still charge money
  everywhere; they don't draw crated parts.
- Placed Cargo Crate props are not containers yet.

### Tests and the probe

- `tests/smoke_recipes.lua` (luajit): the refined registry, every recipe
  names real materials, N6's numbers, part items through the real items.lua
  and inventory.lua (a hold weighs them, a pack refuses a wall, a scene
  without the parts reads the save), the containers, the reach order and the
  off-world quotes.
- `tools/perf/matprobe.sh <engine>` (PATCHES=funds.patch): crated at home
  into the Depot's crates, the crate's panel, then on the nearest moon: the
  reach (a supply drop and the pack), the cards and the plate, a red ghost, a
  wall placed out of its crate, undone back into it, placed and taken down;
  pictures from two angles; `MX PASS|FAIL` lines, pictures in
  `save/user/matshots/`.

## 23. Expansion X5: quarries, conveyors, tubes, silos and loading chutes

Built 2026-11-09 (`work/expansion/PLAN.md` §3.1–3.3 and §3.5; Ty, 11-09:
"quarries that hollow out the ground inside bounds, with conveyors, or tubes in
zero-g, loading a vessel"). The rules are `scripts/quarry.lua` and
`scripts/item_net.lua` (pure, luajit-tested); the scene half is
`scripts/logistics.lua`. The pieces are the kit's LOGISTICS section
(`tools/gen_kit_quarry.py`).

### What a player can do

- **Frame a quarry.** Four **Quarry Posts** on the corners of a rectangle
  (each side 4 to 32 m, square to within 0.9 m) and a **Quarry Drive** within
  14 m of it make a quarry. The posts size it. The gantry spans them: a bridge
  across the rectangle, the hoist cable and a bucket-wheel head that travels
  and lowers as it digs.
- **It digs inside its bounds.** The head cuts a serpentine of 1.2 m cells,
  one 0.6 m layer at a time, walls 1 m inside the posts, from the top of the
  ground down to 30 m (its cable), or to the floor set in the drive's menu
  (0.5 m steps). Soil goes at 0.5 m³/s, rock 0.25, the hard ores 0.12, and on a
  small body 1 m³/s. It needs the grid: a 6 kW load while it digs ("no power:
  the grid is short" stops it); with no grid at all it runs, as a pump does.
- **Near it, the hole is real.** With the crew on its world within 1.2 km, each
  cell is a real `terrain.dig` (a sharp 0.9 m ball that covers the cell), and
  the mineral field pays what the cut removed into the drive's 500 kg bin, by
  the material it was (a vein's ore where the cut crosses one): the same
  ground, the same save as the Terrain Laser's hole.
- **Away, it keeps going.** It runs in closed form on the agency clock on the
  survey's estimate (below). When the crew comes back the cells it claimed are
  dug, 30 a second, without paying twice; the hole catches up while you watch.
- **Carry it.** Conveyors (2 m, 1 m, a curved corner, a T merge, a 15° ramp)
  and Transfer Tubes (2 m, 1 m, an elbow, and a Tube Blower each line) snap
  port to port (a belt never meets a tube). Conveyors that meet are one line:
  8 kg/s, a ramp 5, a tube line 2 (any orientation, vacuum, zero-g). A line
  runs from where its tail meets a store to where its head meets one; the
  belt's direction is the way it was laid (R picks the end, the menu reverses
  it). A line draws 0.3 kW per 10 m from the grid while it joins two stores.
- **Store it.** A **Hopper** (4,000 kg of anything) and a **Silo** (8,000 kg,
  ONE material: the first in, or the one set in its menu; a line offering
  another passes it by and it waits upstream). Hands take from either
  ("Take what fits into your pack").
- **Load a craft.** A **Loading Chute**'s spout fills the hold of the craft
  under it: one held on a Build Stand, or parked within 6 m. Its line stops
  when the hold is full ("the craft's hold is full").
- **Automate it.** Every unit a line moves is an `inventory.transfer` between
  real containers, so a flight log sees a hold filled by the chute as loaded
  from the silo (or hopper) behind it. A run made from that flight loads from
  the silo each cycle (routes' load action, `W.move(silo, hold)`), waits when
  it is short, and the stand says why ("waiting for Silo 1: 10 of 25 Soil").
  A silo or hopper stands as long as its piece does (route_ops `W.exists`).
- **Wire it.** Every conveyor and the Tube Blower have a RUN terminal (S8): a
  Signal Cable off stops the line. The Level Switch reads the nearest hopper,
  silo or drive bin (% full), so a full silo can stop the belt that feeds it.
- **See it.** **F8** with the kit open: the LOGISTICS overlay.

### The quarry (`quarry.lua`)

- `fromPosts` turns the posts' ground points (body-relative) into the frame:
  centre, radial up, the rectangle's axes, half sizes, or the reason it isn't
  one (three posts, not a rectangle, not square, too small, too big).
- The cut: `cells` (nx × nz per layer, layers to the depth), `cellAt(i)` (the
  serpentine: odd rows run back, odd layers run the rows back, so a layer
  starts under where the last one ended).
- **The survey**, once, when the frame completes and the crew is near (a
  layer of 16 columns a frame): each column's ground height by a ray, then
  `mineral_field.materialAt` layer by layer: `mix[k] = { air, hard, comp }`.
  The cut starts at the highest ground over the rectangle; ground lower than a
  layer is air, swept at 4 m³/s.
- **The yield.** The hand laser's volume pays a trickle (its income is its
  bite), so the head has a bulk factor: `YIELD_K` (200) units for the laser's
  one per m³ (soil 10 kg a m³, iron ore 70, by `dig_unit` and the unit
  masses). A live dig passes the same factor to `mineral_field.trackDig` (its
  new `k`; a quarry's cut makes no caption, no loose chunk and keeps its own
  part units). The engine's yield volume measured about a real m³ a cell.
- `profile(prog)`: cells a second and kg a second by the layer's mix, and the
  cells to the next layer (an event for the closed form).
- At most four quarries a world (`MAX_QUARRIES`): a fifth stands but says
  "terrain budget: 4 quarries a world until the engine evicts edited ground
  (card 0658)". A quarry within the base's foundation guard
  (`base_facilities.digRefused`) won't dig and says so.

### The network (`item_net.lua`)

- `build` joins the pieces' ports (0.12 m, same bore) into lines (union-find
  over the conveyors) and finds each line's upstream and downstream stores; a
  head-on pair jams ("two belts run into each other head on"), a tube line
  without a blower stalls, a line back into its own store or round a loop
  stalls ("it loops back on itself"). The stores are ordered by the lines.
- `rates`: a store with stock offers what its lines carry, an empty one
  passes on what comes in (and what its quarry makes); materials drain in a
  fixed order (by name), so every flow is constant between events; a full
  store takes only what it passes on (a backward pass) and its quarry slows
  to what it can discharge; a T merge shares one belt's capacity; a silo takes
  one material; a chute takes anything while its craft has room.
- `advance` steps event to event exactly (a material running out, a store
  filling, a quarry's next layer, a hold full): a day in one call equals
  86,400 one-second calls to 1e-6 (`smoke_item_net`). `limitedBy` names the
  first thing holding a store or a line back.

### The scene (`logistics.lua`)

- One network a world, from every structure's `it` pieces (across
  structures: ports are matched body-relative), rebuilt when the records
  change (debounced 0.5 s, never in a frame).
- Stepped at 5 Hz on the agency clock while anything can move, 1 Hz when
  nothing can, caught up in one call on load (to 30 days). The stores are read
  from their containers each step (a hand or a run may have moved some);
  what moves goes as whole units, the fraction waiting on its edge.
- **No body rides a belt.** The belt's surface is `shaders/conveyor_run.flsl`
  and its load `shaders/conveyor_load.flsl` (a subdivided strip lifted into a
  lumpy ridge in the vertex stage, sunk out of sight when empty), both phased
  on the GPU's clock: their uniforms (speed, fill, the material's colour) are
  set only when a line's flow or material changes. A running line costs no
  Lua a frame. Dropping a loose rock on a belt doesn't carry it (EN11 below).
- The gantry: three static nodes on the planet per quarry within 450 m (the
  bridge scaled to the span, the cable to the depth, the head), moved in
  lateUpdate from the progress, smoothed in the quarry's frame.
- **The LOGISTICS overlay** (F8, `drawOverlay` in lateUpdate from this frame's
  body read): each line green while it carries (blue for a tube), grey idle,
  amber stopped, red jammed, with chevrons the way it runs and its kg/s and
  material; each hopper's and silo's fill as a bar with what it holds; each
  quarry's rectangle on the ground with its layer, depth and m³/h ("estimated"
  while away) and LIMITED BY; posts that aren't a frame yet say why; each
  chute's craft, with a line from the spout to it.
- **Menus** (right-click): a line's flow, Running, Reverse it; a store's
  contents, Take what fits, a silo's Material; the drive's quarry (layer,
  depth, rate, live or estimated), Digging, the floor; the chute's craft and
  its room; a post's frame; LIMITED BY on every piece.

### Save keys and old saves

- `lgx.<body>` = { a } (the world's clock); `qry.<sid>.<uid>` = JSON { sig
  (the posts), prog, dug, paid, q (the frame and its survey) }. Moving a post
  forgets the survey and starts again.
- Part states: a conveyor's `rev` and `off`, a silo's `mat`, a drive's `off`
  (paused) and `floor`.
- The stores are ordinary containers (`hopper:<sid>.<uid>`,
  `silo:<sid>.<uid>`; a drive's bin is a hopper of 500 kg). Nothing old
  changes.

### Cost

Measured in `tools/perf/quarryprobe.sh` (a 12 × 12 m quarry, four belts, a
hopper, a silo, a chute over a stand craft; `logistics` ms a frame):
nothing built 0.012; the quarry digging live and three lines carrying
0.06–0.11 (a 5 Hz step 0.25–0.55 ms, of which the closed form 0.04–0.11);
away 0.04–0.07; the overlay on 0.37–0.45 (kit open only). No body rides a
belt; a running belt costs no Lua a frame. In luajit a 30-belt network
builds in 0.13–0.22 ms and steps in 0.006–0.013 ms. The numbers and pictures
are in `work/expansion_x5/NOTES.md` and `shots/`.

### Left for later

- The laser cutter head, the Unloading Chute and the Intake as a node; the
  tower's THROUGHPUT card; the refineries (X6).
- Quarries on small bodies: the 1 m³/s zero-g rate is in `quarry.lua`, but the
  scene doesn't mark a small body's quarry yet.
- The fifth quarry is refused when it would run, not when its post is placed;
  the kit's ghost doesn't preview the rectangle.
- Dust, the bucket wheel's sound, the tube's capsule glints; the head on the
  S2 anchored vessel (it is a static node moved in lateUpdate).
- Loose bodies on belts (EN11, a card draft in the X5 notes).

### Tests and the probe

- `tests/smoke_quarry.lua` (luajit): the frame from posts and its refusals,
  the cells and the serpentine, the survey (air over low ground, a vein's
  layer), the rates, the profile, the catch-up list, pack and unpack.
- `tests/smoke_item_net.lua` (luajit): lines, bores, jams, the blower, loops;
  quarry → bin → hopper → silo; the one-material silo and the idle line's
  reason; the drain order; a T merge; an unpowered line stopping the quarry
  with LIMITED BY; a chute filling a hold; a day in one call = 86,400 calls;
  the cost; a run loading from a silo through the chute.
- `tools/perf/quarryprobe.sh <engine>` (PATCHES=funds.patch): the whole slice
  in the engine; `QX PASS|FAIL` lines, pictures in `save/user/quarryshots/`.

## 24. Expansion X6: refineries, the Fabricator, and RP as a currency

Built 2026-11-09 (`work/expansion/PLAN.md` §3.4, N4/N7, §7.4; Ty 11-09: "RP is
a currency on the expansion TECH"). The rules are `scripts/machines.lua` (pure,
luajit-tested) and machine nodes in `scripts/item_net.lua`; the scene half is
`scripts/refinery.lua` (hooked into logistics' build and step), the RECIPE
panel is `scripts/fab_panel.lua`. The pieces are the kit's REFINERY section
(`tools/gen_kit_refinery.py`).

### What a player can do

- **Research them with RP.** The Refinery (Crusher, Furnace, Jacket
  Radiator) costs $6,000 + 40 RP and an iron sample; Kiln and Mixer $3,500 +
  30 RP (a silica sample); the Electrolyser $9,000 + 120 RP; the Fabricator
  $12,000 + 150 RP, both after the Refinery. The Orbital Scanner now also
  costs 80 RP and the Space Telescope 200 RP. The points are spent. A locked
  REFINERY card says "unlock $6,000 + 40 RP"; its click arms it and a second
  click researches it, as in the VAB. The Research Lab's page lists WHAT RP
  BUYS, with a Research button on each row (two clicks). Short of points,
  the lock says how many are needed and how many the lab has. Nothing already
  researched changes, and a sandbox has everything.
- **Crush.** A **Crusher** takes what a quarry digs at 2 kg/s (4 kW: 2 kJ a kg)
  and splits the bulk rock into its minerals: Hematite Earth gives 45 % iron
  ore, Rust Rock 25 %, basalt 10 % iron ore and 10 % silica, granite 30 %
  silica, sand 85 % silica, veinstone 15 % copper ore; the rest is regolith.
  Ore passes through. Its outlet feeds every line it meets, the picky ones
  first: a furnace's line takes the ore, a line to a hopper takes the rest.
- **Smelt.** A **Furnace** makes Steel from iron ore (65 % by mass), Alloy Steel
  from kamacite (90 %) and Copper Wire from copper ore (30 %), at 1.5 MJ a kg
  of steel (an induction or arc melt) and 3 MJ a kg of copper. It draws 12 kW
  and sheds 10 kW of heat through its heat port. At full duty that is 8 g/s of
  Steel, 29 kg an hour.
- **Cool it.** The furnace and the **Kiln** run at `min(1, 0.2 + C/H)`. H is
  the heat of every hot machine on the loop, and C is what the loop's sinks
  shed at the jacket water's 330 K (57 °C). The sinks are Jacket Radiators
  (new, 2 × 3 m, 12 m²), the S6 Radiator Panels and a Cooling Tower Cell in
  air, joined by coolant pipes. A radiator sheds εσAη(T⁴ − T_sky⁴), 35 % less
  in sun (the day-night mean is used), plus convection in air. A Jacket
  Radiator sheds 2.3 kW in vacuum and about 4 kW in air at home; a Radiator
  Panel 3.1 / 5.2 kW. With nothing on its port a hot machine runs at 20 %.
  Three Jacket Radiators in air put a furnace at 100 % (11.9 kW measured);
  two put it at 99 %. A kiln on the same row shares them. A loop with a
  reactor's piece on it is the reactor's.
- **Glass and Regocrete.** The **Kiln** makes Glass from silica (95 %, 2.8 MJ a
  kg) and sintered Regocrete from regolith (95 %, 1 MJ a kg, no water); 9 kW,
  6 kW of heat. The **Regocrete Mixer** makes Regocrete from regolith and water
  at 5:1 (1.2 kg a kg of regolith) at 1 kg/s and 2 kW. Its water is piped to
  its −X nozzle from a Water Tank (a consumer on the fluid network). With no
  water it stops ("no water: pipe water to its water nozzle").
- **Make fuel.** The **Electrolyser** turns water piped to its −X nozzle into
  Propellant. It gives 0.78 kg a kg: 2 H₂O → 2 H₂ + O₂ at LOX/LH₂'s O/F of 6,
  the spare oxygen vented. It uses 20 MJ a kg of water, which is 55 kWh a kg
  of H₂, a PEM stack's real figure. At 20 kW that is 1 g/s of water and
  2.8 kg of propellant an hour. The propellant goes into the Fuel Tanks piped
  to its +X fuel nozzle. That is the FUEL base: the Fuel Hose Stand fills a
  craft from those tanks as before. With no tank room it stops.
- **Fabricate.** A **Fabricator**'s store (2,000 kg, 4,000 L) takes the
  refined solids from a belt or a tube: Steel, Alloy, Wire, Glass and
  Regocrete. Right-click → **RECIPE panel**: every part the kit's catalogue
  holds that can be made off-world, searchable. Each row shows the part's
  mass and a ✓ when the store holds its materials. Picking a part shows its
  materials (need / have), the fittings in money, and the time: 10 s + 20 s a
  tonne, at the duty now. **Queue 1 / Queue 5** adds it; the queue holds four
  jobs. A job takes its materials and fittings when it starts and runs at the
  Fabricator's duty (3 kW). Its crate goes into the store, where the Build
  Kit's reach finds it (§22: the Fabricator's store is a container in the
  Engineer's reach), so a part made off-world is placed off-world. ✕ cancels
  a job; a started job's materials go back to the store.
- **Wire them.** Every machine has a RUN terminal and a BUSY output (S8),
  and Running in its menu. Off stops it, and LIMITED BY says so.
- **See them.** Menus: State (duty %, the kg/s worked and of what, kW),
  Inlet, Outlet, Cooling (sinks against heat, and the duty), "Take its outlet
  into your pack", LIMITED BY. LIMITED BY names power, cooling, water or tank
  room first, then the belts: "its outlet is full (regolith): lay a belt or
  tube from its outlet to a hopper", "nothing feeds it", "waiting for feed".
  F8's LOGISTICS overlay labels each machine with its duty, rate and LIMITED
  BY.

### The rules

- `machines.convOf(kind)` gives each input's outputs (kg a kg), their total,
  and `e` (kJ a kg of input). The machine has `kw` × duty of power, so a kg
  of input takes e / kw seconds of the whole machine.
- `item_net`: a machine is two nodes, its inlet (`accept`: what it works) and
  its outlet. Each port has a `side`. The inlet works its materials in name
  order, as fast as the outlet takes them (a full outlet slows it; the
  backward pass carries it). It is piecewise constant like a store's drain.
  So `advance` stays exact: a day of hopper → crusher → furnace → Fabricator
  in one call equals 86,400 one-second calls to 1e-6. Any store can take
  `accept`; lines to picky stores are offered first.
  `machineWhy(net, st, rep, i)` is the item-side LIMITED BY.
- `machines.coolLoops(pieces)` is a union-find over the heat ports (the
  coolant side: ports with no bore, meeting within 0.06 m and facing).
  `rejectKW` is the radiator and tower law. `duty(kind, ctx)` combines the
  switch, the grid (`base_grid.partServed`), cooling, water and tank room.
- `machines.fabAdvance(F, dt, duty, env)`: the queue event to event. It waits
  for materials, takes them and the fittings, runs, and puts the crate (or
  waits for room).

### The scene

- logistics builds the machines into the world's network: the inlet
  `mach:<sid>.<uid>.in` and outlet `mach:<sid>.<uid>.out` as real containers
  (the machine's buffer: 200–400 kg), a Fabricator's `fab:<sid>.<uid>`.
- Before each step, `refinery.prepare` sets each machine's power from its
  duty. After it, what was worked comes out of the inlet in whole units, and
  what was made goes into the outlet (logistics' unit accumulators). Then
  `refinery.after` runs the Fabricators' queues on the same clock: 5 Hz while
  anything moves, 1 Hz idle, one call on load. Away, all of it runs in closed
  form on the agency clock, as the quarry does.
- The cooling loops are found when the network is built and refreshed every
  30 s (each structure's air and temperature: room_air's outside, else the
  world's traits).
- **The electrolyser is not on the belts.** fluid_net drains its water cell at
  the rate it asks (`waterDraw`) and reports what it drew (`waterServed`). It
  then puts the propellant made into the Fuel Tanks on its fuel nozzle, a new
  fluid role `src` (`takeMade`). `fluid_net.srcRoom` is the room left. The
  closed form is fluid_net's.
- The grid: a machine is an `aux` load of its rated kW while switched on (a
  Fabricator while its queue holds a job). A short grid stops it.

### Save keys and old saves

- `fabq.<sid>.<uid>` = JSON { q } (the queue). A machine's `off` is in its
  part state. `res.rpSpent` is the RP spent; `res.pts` goes down by what is
  spent.
- The containers are ordinary (`mach:`, `fab:`), with caps set by
  `inventory.setCap`.
- Nothing old changes. An old save has none of these keys and no refinery
  pieces. Researched techs stay researched (the RP prices apply only to what
  is still locked).

### Cost

Measured in `tools/perf/refineryprobe.sh` (engine 0.117.1-dev.1463, its Lua
without the JIT; ms a frame unless said):

- **Nothing built:** logistics 0.016 (X5's 0.012–0.013 plus the X6 hooks).
  `refinery`, `machines` and `fab_panel` have no update of their own, so
  they cost 0: logistics registers the refinery's menus and ticks an open
  panel.
- **Running** (six machines, two hoppers, four belts, three tanks): logistics
  0.07–0.11. A 5 Hz step is 0.64–0.77 ms. Of that, the closed form is
  0.05–0.08 ms, `refinery.prepare` 0.06–0.07 ms and `after` 0.01–0.02 ms. The
  cooling loops cost 0.17–0.20 ms when the network is built and every 30 s.
  fluid_net, with the mixer's and the electrolyser's water and the fuel tank,
  is 0.04–0.065.
- **Idle** (the machines off, the lines dry): logistics 0.032–0.076 over two
  runs. A settled network skips its step (28 skips in 30 s; the check is
  0.1 ms a second).
  The step is skipped when its last step moved, worked and made nothing, no
  container has changed since (`inventory.bagVer`, a new counter on every
  bag write), and the machines' power and the quarries' state are as they
  were.
- **The overlay on** (the kit open and F8 only): 0.76, of which the overlay
  is 0.62.
- **In luajit**, a day of hopper → crusher → furnace → Fabricator in one call
  takes 0.8–1.3 ms over 7 segments; a 5 Hz step takes 0.012–0.015 ms.

The numbers and pictures are in `work/expansion_x6/NOTES.md` and `shots/`.

### Balance numbers for Ty

- The rates are the physics: Steel at 29 kg an hour a furnace (the plan's
  sketch said 0.4 kg/s, which is about 200 times the energy a real melt
  needs), Glass at 12 kg an hour a kiln, propellant at 2.8 kg an hour an
  electrolyser.
- `machines.SPEED` (1) is one knob on every machine's rate if that is too
  slow.
- The power: the six machines draw about 50 kW (the probe ran them on 26
  Isotope Skids). A real refinery base wants a reactor (S6) or a big solar
  field.
- The Furnace's 65 % (iron ore to Steel) and the Electrolyser's 0.78 replace
  the plan's 1:1 and 0.9.
- The RP prices: 40 / 30 / 120 / 150, plus the Scanner's 80 and the Space
  Telescope's 200.
- Not gated, though the plan prices them in RP: the Quarry (X5) and the 1 m
  Telescope (X1) shipped open, and gating them now would lock what saves
  already use. Ty decides.

### Left for later

- Alloy from iron ore + ilmenite (3:1: a two-input recipe); clathrate and
  ammonia ice → Propellant Gas; an electrolyser fed ice from a belt.
- The Rod Press as a piece; the tower's THROUGHPUT card.
- A furnace's heat into a sealed room (`room_air`'s heat term).
- Sorting on a belt: the crusher's picky-first order and a silo set to one
  material are the only sorters.
- Dust, sound and glow on the machines; the Fabricator's crate doesn't ride a
  belt out (it waits in the store, in reach).
- The panel is opened from the menu (no E key at the machine yet).

### Tests and the probe

- `tests/smoke_machines.lua` (luajit): each machine's rate from its energy,
  the crusher's split conserves mass, a radiator's kW in vacuum and air, a
  tower only in air, loops (alone 20 %, three panels 100 %, a kiln sharing,
  a reactor's loop), the duty's order, the chain in item_net (the
  Fabricator's store takes no regolith, the spoil line, 20 % duty), a day in
  one call against 86,400, a full outlet's LIMITED BY, the Fabricator's
  queue, the cost.
- `tests/smoke_research_rp.lua` (luajit): refused short of RP, spent when
  bought, the lock line and price, money-only entries unchanged, rpTree, the
  sandbox, an old save's research kept.
- `tools/perf/refineryprobe.sh <engine>` (PATCHES=funds.patch): the whole
  slice in the engine. `RX PASS|FAIL` lines, pictures in
  `save/user/refineryshots/`.

## 25. Expansion X7: base roles, reach contracts and Survey II

Built 2026-11-09 (`work/expansion/PLAN.md` §1, §7.2, the X7 row of §11; Ty
11-09: "purposeful bases encourage expanding far: refuelling stations,
resource pipelines shipping home, mining/quarry bases, energy bases,
refineries, science labs, defense bases"). The rules are
`scripts/base_roles.lua` (pure half, luajit-tested) and the swath grid in
`scripts/survey.lua`; the contracts and the Reach stage are in
`scripts/missions.lua`; the station's part is in `docs/tracking-station.md` §6.

### What a player can do

- **Give a base a purpose by building it.** A role is never chosen; a census
  reads it off every piece within 150 m of a base's tower (and of the
  spaceport's Tracking Station, base 0):

  | role | glyph | what makes it |
  |---|---|---|
  | PORT | ⇆ | a run that starts, stops or ends there (a Build Stand alone is not enough) |
  | FUEL | ⛁ | an Electrolyser, or a Fuel Hose Stand with 500 kg in its Fuel Tanks (with less: weaker) |
  | MINE | ⚒ | a Quarry Drive (1.0 while it has dug in the last 24 h, 0.6 idle) |
  | POWER | ⚡ | the base grid's sources exceed its loads by 10 kW |
  | REFINERY | ⚙ | a Crusher, Furnace, Kiln, Regocrete Mixer or Fabricator (1.0 while it worked in the last 24 h) |
  | SCIENCE | ✦ | a telescope or a Survey Station (1.0 with a Scientist there or a sweep running) |
  | DEPOT | ▤ | hoppers and silos with 4 t of room (0.5), or 2 t held (1.0) |
  | DEFENCE | ✚ | a part with `defence`: a Beam Director (X9, §27; X10's launch rails later) |
  | OUTPOST | ⌂ | none of the above |

  A role shows from strength 0.5. It rises at once and fades by a third a
  game day, so a quarry idle for a day is still a MINE base (§1.1's
  hysteresis); three days of nothing and it goes.
- **See it.** The Tracking Station's BASES rows wear the strongest role's
  glyph and "FUEL · MINE · ground station"; the base card lists every role
  with its bar and why ("an Electrolyser makes propellant", "a quarry ·
  300 kg in 24 h"), what the base moved (24 h in and out, mined and worked;
  in all, and run cycles), its pieces and stores, and what would give it the
  roles it lacks. The role key (beside the world key) shows one role's bases
  at a time. The chart's base label reads "Far Side · ⛁ FUEL · ⚒ MINE". The
  BODY card lists each base on the world with its roles.
- **Base stats.** Credited by what moves things: a run's load at a base is
  OUT, its unload IN (an unload at the Intake is the spaceport's IN), each
  cycle a RUN for every base it touches (`route_ops` → `creditRun`); a
  quarry's dig is MINED, a machine's input WORKED, a loading chute's flow OUT
  (`logistics` step → `creditStep`).
- **Contracts that pay for reach** (the board's new **Reach** tier, standing 3
  with Made Orbit flown; offered only where they can be done):
  - **establish**: a base with role R on world W (a world the company has
    reached and has no base on; the role suits it: ice worlds lean to FUEL,
    airless ones to SCIENCE and MINE). Once a world.
  - **layer**: one survey layer of W known (resources to 80 % by the
    scanner, the field by the gravimeter, or composition). Once a world.
  - **supply**: 200 kg (a moon) or 400 kg more of an ore the home world has and
    W lacks in a base's hoppers and silos than when it was signed.
    Repeatable.
  - **pipeline**: three run cycles through a base since signing. Repeatable.
  Pay is the generator's: `base × difficulty` (Δv, distance, gravity) ×
  standing; establish 9,000, layer 4,000, supply 5,000 (+ twice the ore's
  depot value), pipeline 6,000 base.
- **The Reach stage** (PROGRAMME, after the Relay Network): found a base on
  another world ($3,000), a FUEL base off the home world ($6,000), an
  automated run's first cycle ($4,000), ore refined off the home world
  ($5,000), another world SURVEYED ($6,000); $25,000 and +3 reputation for the
  stage.
- **Survey II.** The Orbital Scanner maps the ground under its swath: a
  400-cell grid of each world (the comms coverage grid's layout), a cell
  marked when the swath (30° either side of nadir, to the horizon) passes
  over it; RES is the share marked. The worlds do not turn (the engine's
  rails bodies only translate), so one orbital plane maps one band: a
  scanner 0.75 R up maps 59 % in one orbit and no more in ten; a second
  plane maps most of the rest; a higher orbit maps a wider band. The
  **Gravimeter** (new VAB part, the scanner's housing, $5,200 + 60 RP after
  the scanner) gives gravity at once and the magnetic field over three
  orbits in the same band. **The res_map**: each mapped cell's patch is read
  for its veins from the world's seed (`mineral_field.patchOres`, the same
  rolls the ground makes), and the station draws a tinted disc on every
  mapped cell of the selected world, coloured by the ore the patch holds
  most of, with a key on the BODY card: where to put a MINE base.

### The rules

- `base_roles.targetsOf(census)` → target strengths and reasons;
  `decay(s, target, dt)` (up at once, down 1/DECAY a second: one long step
  equals many short); `step(prev, targets, dt)`; `strongest`, `roleLine`,
  `glyphOf`; `statsAdd(st, field, amount, t)` and `stats24(st, field, t)`
  (today plus the share of yesterday still inside the 24 h window).
- The census walks `structures.list()` once: a structure more than 550 m from
  every base on its world is skipped whole; each part goes to the nearest
  base within 150 m along the ground. It reads fuel in tanks
  (`fluid_net.content`), stores (`inventory.mass` of the hoppers and silos),
  the grid (`base_tower.power`), the runs (`route_ops.list`), sweeps
  (`survey.jobOf`) and Scientists (the crew roster).
- `survey.swathTrack(state, mu, dt, R, step, visit)` carries a body-relative
  state along its ellipse by Kepler's equation and visits points at most
  `step` radians of true anomaly apart, one revolution at most (the track
  repeats); `swathMark` marks the cells within the swath of a point
  (indexed by the grid's latitude bands, so a narrow swath checks few
  cells). A live craft is re-read from the engine each tick; an unloaded
  one is carried in closed form until its record is rewritten.

### Save keys and old saves

- `bases.<id>.roles`, `.rt` (when they were read), `.stats` (the base record;
  bases.lua keeps them); `bases.home` = { roles, rt, stats } for the
  spaceport. `survey.<body>.sw` (the marked cells, hex, 100 characters) and
  `.gm` (the gravimeter's field). `opt_trackFilter.role`. A supply or
  pipeline goal carries its baseline (`b0`, `c0`) in the signed spec.
- An old save has none of these: its bases are OUTPOSTs until the first
  census (two seconds after loading); its worlds' RES stays what X1's
  closed form gave (a layer only rises) and the swath grid starts empty; the
  Reach stage opens if the Relay Network is done, and ticks what is already
  true.

### Cost

Measured in `tools/perf/reachprobe.sh` (engine 0.117.1-dev.1466; ms a frame
unless said; `work/expansion_x7/NOTES.md`):

- **Nothing built:** `base_roles` 0.005 a frame (one compare a frame; the
  versions are looked at twice a second; the hook floor every script pays).
  `survey` 0.005–0.010 (its 1 Hz tick 0.09 ms).
- **A base with five roles:** a census 0.25–0.43 ms (2 places, 9 pieces), run
  when the structures, the bases or the number of runs change, and once a game
  hour. `base_roles` 0.005 a frame between censuses.
- **The station open on the base card:** `tracking_station` 0.07–0.18,
  `base_roles` 0.0065 (the card reads its tables).
- **The res_map:** 132 discs drawn (the facing half of 285 mapped cells) in
  0.24–0.27 ms a frame, only while a world is selected in the station and its
  disc is 60 px or more across; reading the cells' veins 12 a frame
  (0.002 ms a call once read). Marking two whole orbits of swath in one call:
  3 ms (a 1 Hz scanner tick at ×1 marks a few points: ~0.01 ms).
- **Credits:** a run's advance and logistics' step call one function each;
  the stats are written at most every 5 s.

### Balance numbers for Ty

- The thresholds: FUEL at 500 kg in a hose stand's tanks, POWER at 10 kW
  spare, DEPOT at 4 t of room or 2 t held; SHOW 0.5; a role fades over 3
  game days.
- The swath: 30° off nadir, 400 cells; the band 0.1–1.5 R up (X1's).
  Three orbital planes are about what a world takes.
- The contract pay (establish 9,000, layer 4,000, supply 5,000, pipeline
  6,000 base) and supply's 200 / 400 kg; the Reach stage's $24,000 in goals
  and $25,000 for the stage.
- The Gravimeter: $5,200 + 60 RP, three orbits for the field.

### Left for later

- The base name sign's role glyph (S4 signs); the run planner's "refuel at
  Far Side saves 1.9 t"; `kwh_exported` (HV export between base grids) and
  a POWER base's export line; LIMITED BY on the base card.
- A carried Weather Station deployable (the Survey Station kit piece fills
  temperature and air in 6 h meanwhile); the 4 m telescope.
- DEFENCE waits on X9's parts.
- The res_map draws one disc a cell (one engine call each): a batched
  immediate-mode shape call would make it nearly free (card draft in the
  notes).

### Tests and the probe

- `tests/smoke_base_roles.lua` (luajit): each role from a census, decay (one
  long fade equals 1,440 short), the stats and the 24 h line, the census
  over stubbed structures with the real bases.lua (an old record loads as an
  outpost; a part 400 m away is no base's; a fade over days; a reload keeps
  them), `creditRun` and `creditStep`, the four contract kinds (offered only
  where possible, baselines, paid when met), the Reach stage, every glyph in
  both UI fonts.
- `tests/smoke_survey.lua`: the swath grid (marks, the hex round trip, one
  long track step equals 700 short to 1e-6, one band an orbit, no more from
  the same plane, a second plane), the scene's scanner by plane, the
  res_map read under a budget.
- `tools/perf/reachprobe.sh <engine>` (PATCHES=funds.patch): `XR PASS|FAIL`
  lines, pictures in `save/user/reachshots/`.

## 26. Expansion X8: abandoned bases

Built 2026-11-09 (`work/expansion/PLAN.md` §5, the X8 row of §11, §14: ruins
are claimable; Ty 11-09: "abandoned bases on inhabited or previously
inhabited planets. There's no planet life system yet, so combat is pointless
for now."). The rules are `scripts/ruins.lua` (its pure half is
luajit-tested); the ruin entry and card are in `docs/tracking-station.md`
§6.2.

### What a player can do

- **Find the bases other companies left.** Every world of the home system
  rolls its sites from its seed, the same list every session:
  - an **inhabited** world (air over 0.15, or the home world): 1–3 sites, and
    one more kept back for the life system (pending: never stamped, never
    found);
  - a **once-habitable** world (an airless or thin barren, frost, canyon,
    dune, crystal or ice world whose seed rolled a warm past: 20 % of them):
    1–2;
  - any other world: a 10 % chance of one survey camp.
- **Five kinds**, each a grammar over the Build Kit's own pieces (so what you
  find is what you can build, repair and extend):

  | kind | what stands | the terminal (Data Core) | RP |
  |---|---|---|---|
  | survey camp | a 4 × 4 crew hut, a tool shack, crates, drums | a desk monitor in the hut | 60 |
  | mine head | a gantry over a hopper (its head gone), a bench shack | a monitor on the bench | 120 |
  | hab block | the two-storey hab: airlock, O2 generator, scrubber, air tank | a monitor upstairs | 150 |
  | power hall | the reactor shed, its core pulled; loops, turbine, radiator; shield blocks knocked over | the reactor console | 300 |
  | relay post | pads, a truss mast (one length fallen), a flat battery bank, two arrays blown over | the junction box | 90 |

  Every one has a dead Base Station Tower and crates.
- **See the years on it.** Roofs go first (30–60 % by age), then 10–30 % of
  the walls; half the windows are broken out to open frames; one piece in six
  leans 6–12°; chairs, drums and blocks topple; a third of the walls are
  rusted (oxide); grime runs down one standing wall in four; the record is
  back-dated by the site's age, so every piece wears its full dust at once
  (`kit_paint.dustOf`). Lights are off, the battery is flat, the tower is a
  mast with no grid: dead power.
- **Discover it** three ways: on the ground within 420 m; from orbit, when an
  Orbital Scanner's swath passes over its cell of the world's 400-cell grid
  (X7); or with a telescope sweep of its world (a 0.3 m finds one site a
  sweep, a 1 m every one). A caption names it ("ABANDONED BASE · Brannock
  Habitat 8 · a hab block, empty 2483 days"; "ANOMALY · a regular shape at
  41° N, 12° E on Golver"), and the Tracking Station lists it (▣, STRUCTURES).
- **Loot it.** "Search the crate" on a crate: o2 tanks, a repair kit, a
  medkit, a beacon, a few units of the world's ores (from the seed, once; what
  won't fit in the pack stays in the crate). A mine's hopper holds 200–2,000
  kg of the world's commonest ore once claimed.
- **Recover the Data Core.** "Pull the Data Core" at the terminal: a 6 kg item.
  Carried into the home Research Lab it is read: RP by kind (× the carrier's
  study multiplier if a Scientist carries it), the site's last log (three
  lines from 42 fragments, kept on its card), the site's blueprint as it was
  built saved to the BLUEPRINTS library ("Brannock Habitat 8 (recovered)"),
  and a survey layer for its world (a mine's vein map: resources 0.6; a
  hab's weather log: air and temperature; a camp: composition; a power hall:
  the field).
- **Claim it.** An Engineer's "Claim the site" on its tower: the tower founds
  a base under the site's name (`by = "claimed"`), so the grid, X7's roles,
  runs and comms treat it as yours. Then "Repair the <piece>" on any knocked
  piece (a Repair Kit, 4 s: it stands straight, its paint and window come
  back) and, at the tower, "Restore N missing pieces" (their kit price, one
  bill; every piece the decay took goes back where it was).

### The rules (`ruins.lua`, pure)

- `worldClass`, `sitesFor(name, w, home, R)`: a Park–Miller stream seeded by
  the world's name and seed; sites keep 300 m apart along the ground (or as
  far as a small moon allows). A site is a direction, a kind, an age (an
  inhabited world's 400–2,500 days, a once-habitable one's 2,500–6,000), a
  facing, its own seed and a company ("Pell", "Halden" — N1's suppliers —
  and eight more) with a number.
- `blueprintOf(site)` → pieces with a role (slab, floor, wall, roof, door,
  light, fix, prop, mount, decal, loot, core, silo, tower, power, array) and
  `dep` (what a light or a rack hangs on); `decay(pieces, site)` keeps
  `ri` (the index in the full build) on every standing piece and `o_p`,
  `o_r`, `o_c`, `o_id` (the pitch, roll, paint and piece before the damage)
  with `wr` on a knocked one; `missing(full, bp)` is what a restore puts back.
- `recordOf(site, g, kept, now)`: a structure record with `ru` = the site id.
- `occupant(site)` → nil: THE LIFE SEAM. A planet-life system fills it ("who
  lives here now"); sites carry `life = nil`; the pending site per inhabited
  world is where it starts. DEFENCE and any combat wait for it.

### The scene

- **Sited** once, the first time the crew comes within 600 m: nine field
  raycasts (`terrain.raycast`, exact ground; a stand-in is accepted after
  20 s or within 300 m) at the site and 11 m round it; the ground may rise
  1.6 m at most, dry, 450 m from the spaceport, 320 m from a base's tower,
  150 m from anything built; ten spots tried, 50 m further out each, else the
  site is dropped. The frame (ground point, radial up, the site's facing) is
  saved.
- **Stamped** then (0.3–0.9 ms) as a structure; `structures.lua` streams a
  `ru` record by distance (spawned within 650 m of the focus, unloaded past
  800 m) instead of "the focus's world", and spawns any structure streaming
  in 12 parts a frame (`pace`; a 108-piece power hall in ~0.5 s). Past 900 m
  an untouched ruin leaves the records (it comes back the same from its
  seed); a touched one (a crate, the core, a piece taken or mended, a claim)
  stays in the records, unloaded far away.
- `base_tower.reconcile` asks `ruins.towerHeld(rec)`: an unclaimed ruin's
  tower founds no base (no grid, no relay, no roles). `base_grid` reads a
  bank's own `fill` off its part (a ruin's battery arrives flat).
  `survey.credit` tells `ruins.telescopeSwept` after any telescope sweep.

### Save keys and old saves

- `ruins.s` = { [site id] = { g (the sited frame, body-relative), dsc, dt (how
  and when found), sid, n (the stamped structure and its piece count), tc
  (touched), core, read, cl (claimed), lf (crates filled), silo, drop } };
  `ruins.cores` (cores pulled, not yet read, in order). A stamped ruin is a
  `struct.<id>` with `ru`; its pieces carry `ri`, `rl`, `wr`, `o_*`, `fill`.
- An old save has none of these: every site is new and hidden, nothing
  happens until the crew comes near one; its structures load unchanged (`ru`
  absent).

### Cost

Measured in `tools/perf/ruinprobe.sh` (engine 0.117.1-dev.1468, High,
1280 × 720; `work/expansion_x8/NOTES.md`):

- `ruins` 0.005 ms a frame (its 1 Hz tick 0.02–0.04 ms: a few distances for
  the focus world's sites; a scanner look every 5 s). Nothing a frame.
- A stamp 0.2–0.9 ms once (the power hall the most); the paced stream-in
  (12 parts a frame) no frame over 25 ms.
- **The power hall (108 pieces, the biggest kind) 30 m from the camera
  against the same view with no ruin:** GPU 10.97 → 11.22 ms (+0.25: the sun
  map +0.10, the rest within noise); draws 845 → 892 (+47: kit pieces share
  their meshes), instances +261, sun-map draws +261, triangles +33 k; engine
  CPU work 16.1 → 18.1 ms mean (render +0.9, untimed +0.5, scripts +0.2,
  mirror +0.1: the engine's cost per static node, 432 nodes for 108 pieces).
  The smaller kinds are 20–47 pieces.
- 1.2 km away: an untouched ruin is out of the records; a touched one stays
  in them with no nodes (no draws, no CPU).

### Balance numbers for Ty

- Sites: inhabited 1–3 (+1 pending), once-habitable 1–2 (20 % of the rocky
  airless worlds), else 10 % of one camp. Ages 400–2,500 / 2,500–6,000 days.
- RP: camp 60, relay 90, mine 120, hab 150, power hall 300 (× a Scientist's
  study multiplier).
- Decay: roofs 30–60 %, walls 10–30 %, one piece in six knocked.
- Crates: a repair kit 50 %, an o2 tank 35 %, a medkit 25 %, a beacon 15 %,
  2–8 ore units. A mine's silo 200–2,000 kg.
- Restoring costs the missing pieces' kit price (a hab block's 7: $2,710).
- Distances: found at 420 m, stamped at 600 m, unstamped at 900 m, drawn
  within 650 m (hidden past 800 m).

### Left for later

- The reactor hall's spent rods and decay-heat dose field (a Geiger and a
  sign); the HALEU rack behind a jammed door; the hab's O2 generator needing
  water as its first repair.
- A wrecked rover beside a camp (debris roots), toppled props in the decay are
  pieces, not loose bodies.
- The Data Core's lore in the lab's codex (it is on the ruin's card and in the
  log); a TECH grant as a core reward; reading at a field lab bench.
- Discovery by scanner or telescope can name a site that turns out to have no
  room when the crew arrives (it is then dropped and leaves the station).
- Flora grows round a ruin (only under its slabs and floors is it cleared, as
  for any structure); an overgrown ring might be wanted.
- G0–G2 (EN13) for a dozen ruins in view.

### Tests and the probe

- `tests/smoke_ruins.lua` (luajit, 88 checks): sites per world by trait,
  determinism, spacing; every kind's pieces resolve; decay (roofs first, never
  the floor, dependents, age); the record through `structures.lua` (`ru`
  kept, poses finite, lights off, the battery flat, `missing`); core rewards
  and the log; the scene half over a smooth world (sited, stamped near,
  unstamped far, kept when touched, found by proximity, scanner and
  telescope, never the pending site, the tower held until claimed, claim,
  restore, repair, a crate once, the core pulled and read); the fleet_view
  entry; an old save.
- `tools/perf/ruinprobe.sh <engine>` (PATCHES=funds.patch): `RN PASS|FAIL`,
  pictures in `save/user/ruinshots/`.

## 27. Expansion X9: energy weapons I (lasers from components)

Built 2026-11-09 (`work/expansion/PLAN.md` §4.1 and its damage table, §4.5,
the X9 row of §11, §14 item 3). Ty's rule, binding: weapons follow real
physics; only an extreme late-game build crosses into a cinematic, explosive
regime, and the crossover is continuous and earned, never a toggle. There is
no planet life yet, so the targets are your own structures, old craft and the
ground, and later X7's DEFENCE role. The rules are `scripts/beam.lua` (the
physics) and `scripts/damage.lua` (what it does), both pure and
luajit-tested. The scene is `scripts/lasers.lua` (the kit laser) and
`scripts/laser_turret.lua` (the craft turret).

### 27.1 What a player can do

- **Build a laser from pieces** (Build Kit, DEFENCE section; research
  *Directed Energy* $18,000 + 120 RP and copper ore, *Amplifier Stages*
  $30,000 + 250 RP):

  | piece | size, mass, price | what it is |
  |---|---|---|
  | Capacitor Bank | 2 × 1 × 1 m, 1.4 t, $9,000 | 20 MJ; charges from the base grid at 50 kW while its laser is ARMED; leaks 0.1 %/h; pulse ports at ±X |
  | Pulse Bus 2 m / 1 m | $600 / $350 | busbars on insulators: join banks to one emitter or one stage |
  | Laser Emitter | 1 × 1.3 × 1.5 m, 1.2 t, $38,000 | a Nd:YAG slab at 30 %; beam out +Z, pulse port −X, coolant (heat) port +X; CW 30 kW optical from 90 kW |
  | Amplifier Stage | 1 × 1.3 × 2 m, 1.8 t, $52,000 | adds 45 % of its own banks' charge to the passing pulse; six at most |
  | Lens Group | 0.8 × 1.3 × 1 m, $12,000 | the director focuses to 50,000 km instead of 5 km, or holds a range you set |
  | Beam Director | 1.5 × 2.1 × 1.5 m, 0.9 t, $24,000 | a two-axis gimbal with a 0.5 m mirror, 10°/s; the beam's end; makes a DEFENCE base |
  | Fire Control Console | $6,000 | the weapon page and the logic terminals |
  | Targeting Radar | 2 × 2.6 × 2 m, $30,000, 3 kW | the lasers on its grid lock to 500 km (5 km by eye) |

  Pieces join port to port (the S6 snap: a held piece's port goes onto the
  hit piece's free port of the same bore). Banks go end to end onto the
  emitter's side; emitter → stages and lens → director along Z; Radiator
  Panels or Jacket Radiators on the emitter's and stages' heat ports.
- **Aim it with the targeting feature.** Right-click a craft or a part → Set
  target, or any structure piece or the ground near a laser → **Laser target
  here** (a new target kind, a spot held body-relative). ARMED directors slew
  onto the selection; ON TARGET when the miss there is under 0.3 m.
- **Fire.** The console's (or the director's) menu: ARMED, the charge, the
  target with its range, the PREDICTED effect (spot, fluence, and BURN THROUGH
  / WEAR n for tanks, pods, engines, steel and concrete walls, the crater),
  FIRE, CW, Limited by. Logic: `fire` (an edge) and `arm` (a level) in;
  `ready` and `ontgt` out, on the director and the console.
- **Mount a Laser Turret on a craft** (VAB, DEFENCE; research *Laser Turret*
  $14,000 + 80 RP): a radial part (a jet's spine, a lander's side). ARMED it
  charges its 0.5 MJ capacitor from the craft's batteries at 10 kW and tracks
  the TARGET by itself; FIRE from its menu, or AUTO: it fires the moment it is
  on target and charged (a sentry beside a landed pod).

### 27.2 The physics (`beam.lua`)

- The pulse: `E = 0.92 × (0.30 × ΣE_emitter's banks + 0.45 × Σ each stage's)`;
  a group feeding several devices is shared evenly. Ten banks on an emitter
  give **55.2 MJ** (the plan's "60 MJ" is rounded); the other 145 MJ is the
  emitter's heat.
- Divergence `θ = 2.44 λ / D + jitter`, λ = 1.06 µm. The jitter is the
  director's own (1 µrad; X11's large one 0.05) plus 0.4 µrad a stage,
  divided by the beam expander's magnification D / 0.5 m (an angle inside the
  train shrinks by the expander's power).
- Spot `d = max(2 cm, √((R θ)² + (D (1 − R/f))²))`: the optics focus at the
  target's range up to their reach, and off focus the geometric blur adds.
  Fluence `F = E / (π d² / 4)`.
- Air: `T = exp(−∫σ dl)`, σ = 1e-4 /m × ρ/1.225 (clear air at 1 µm), ρ from
  the world record along the path (`aero.airAt`, six samples). A CW beam over
  10 kW in air above 0.3 kg/m³ blooms (half again).
- Occlusion: a segment-sphere test against every body of one `space.bodies()`
  read, four times a second while a target is over 200 m away.
- Cooldown `(3 s + 0.1 s/MJ) / max(0.4, cooling)`. Cooling is
  `machines.coolLoops` over the heat ports (one Jacket Radiator on an
  emitter's 60 kW gives 0.27).
- The plan's worked figures hold (smoke_beam): the 0.5 m director at 100 km
  gives a 0.52 m spot and F 2.86e8 (plan 2.8e8); the 8 m dish at 10,000 km
  3.23 m and 1.46e8 (plan 1.5e8). Those figures leave out the plan's own
  1 µrad jitter: with it the 100 km spot is 0.62 m.

### 27.3 What it does (`damage.lua`)

| target | rule | measured (a 55 MJ pulse at 37 m: 2 cm spot, F 1.76e11) |
|---|---|---|
| craft part | `min(1, F/F_part) · min(1, E_on / (F_part · 0.01 m²))`; F_part tank 2e6, structural 5e6, pod 4e6, engine 8e6, shield 5e7; `vessel_controller.hitPart` (≥ 1 breaks it: its blast, chain, crater, debris) | see 27.6 (turret) |
| kit piece | `min(1, F/F_mat) · min(1, E_on / E_cut)`; F_mat steel 5e6, concrete 2e7, glass 5e5, regocrete 1e7; E_cut = melting a 5 cm kerf through its section | steel wall (E_cut 2.53 MJ) removed; concrete (60.0 MJ) worn to 0.08, felled by the second pulse; glass (7.5 MJ) removed; regocrete (52.0 MJ) removed |
| ground | `r = (E_abs / 3 GJ/m³)^(1/3)`; the energy waits on the spot (within 1 m) until r ≥ 1 m, the smallest dig the engine's ground takes (a 0.5 m dig changes nothing, measured); until then each pulse leaves a scorch | 0.264 m from one pulse (a scorch); a 1 m pit after 55 pulses on one spot (3 GJ) |
| crew | `F / 1e5` hp a second (in the rules; not cast in the scene yet) | — |

The energy factor is the plan's rule plus the floor it needs. By fluence
alone a 30 kW CW beam on a 2 cm spot "burns through" a concrete wall in a
tenth of a second, having melted a 2 cm hole. For every real pulse the factor
is 1 and the plan's rule stands exactly. A beam wider than its target puts
only its share on it (`intercept`). A piece's hp lives in its part state
(`hp`; none means 1.0). At 0 the piece leaves the record (rooms re-flood) and
throws up to 8 chunks of its material and a burst.

### 27.4 The cinematic regime (continuous, earned)

`c = s(xE) · s(xF) · kAmp · kMag` (s = smoothstep), where xE = (log10 E −
8.5)/2, xF = (log10 F − 9)/2, kAmp = (1 + stages)/7 and kMag =
clamp(log2(D/0.25)/5, 0.2, 1). At `c` the absorbed energy couples into a
blast: TNT equivalent `c · E / 4.184 MJ`, radius `2 m · W^(1/3)`, and pieces
and parts in it take `1.5 (1 − d/r)`. The ground's cratering energy falls
from 3 GJ/m³ (melting) toward 30 MJ/m³ (explosive ejection) as `10^(−2c)`.
Measured:

- laser A (10 banks, 0.5 m): c = 0 (the physics).
- the largest X9 build (0.5 m, six stages, 30 banks on every bus, 1.66 GJ,
  ~$2.2 M, ~12 h of a 100 kW turbine's charge): **c = 0.059**, just over the
  edge.
- X11's 8 m dish at 22 GJ on a 0.3 m spot: **c = 0.98**. Invoked directly in
  the probe (no such build exists yet): 5,165 kg TNT, a 34.6 m blast radius,
  three walls 14 m away flattened, a crater of 8.8 m (the physics alone:
  1.9 m).

One more bank on every bus moves c by under 0.02 anywhere along the way
(smoke_beam asserts it).

### 27.5 The scene (`lasers.lua`)

- **Layout**, on `structures.version`: `beam.layout` over each structure's
  DEFENCE pieces (pulse groups by union-find, the beam path port to port). A
  weapon is a director with its emitter, stages, lenses and the banks each
  dumps. Weapon tables persist across rescans, so their aim and cooldown
  carry over.
- **Charging**: a bank is a `base_grid` aux load (50 kW) while its laser is
  armed and the bank is not full; `partServed` says whether the grid carries
  it. The step runs on the agency clock every 0.5 s (one long step equals many
  short ones, so a reload or a warp catches up). Saved in `lz.e` / `lz.a`.
- **Aiming and firing in fixedUpdate**, from tick poses: the director's pivot
  from its record against `space.body` read in the tick, and the target from
  `targeting.resolve`. The yaw and elevation are in the director's own frame;
  nothing is kept in world. A pulse is one raycast from the muzzle along where
  the director points; CW is one raycast every 0.1 s.
- **Drawing in lateUpdate**, from drawn poses: the muzzle from the record
  against this pass's `space.body`, and the hit held body-relative (or in the
  struck part's frame, placed by the part node's `toWorld`). The head's Yoke
  and Head children are turned by `setAngles(yaw, −elevation, 0)`. Four
  pooled `FxWeaponBeam` nodes (vfx/WeaponBeam: core, halo, shimmer, muzzle
  star).
- `targeting.lua` gains the `spot` kind (resolve, store/restore, the marker).
- `logic_net` has dev `laser`; `base_grid`'s aux sum asks `lasers.gridAux`;
  `base_roles` counts a director (`defence`).

### 27.6 The craft turret (`laser_turret.lua`, `parts_weapons.lua`)

Turrets are found once a second on every live craft (`aboardRecs`, id
`laserTurret`). Capacitor 0.5 MJ (a 138 kJ pulse), D 0.3 m, slew 40°/s,
elevation −5° to 90°, lock 5 km. The gimbal frame is the part's: up is its +X
(out of the hull), front its +Z. It aims and fires in fixedUpdate from
`partFrameNow` (tick); the head is drawn from its own nodes (`Mount` →
`Yoke`, `Head`). Charge, ARM and AUTO are not saved and start empty each
session. Measured against a derelict's tank 14 m away: spot 9.6 cm (the
optics focus no nearer than 20 m), F 1.9e7, amount 1: the tank burns through
and blows; AUTO then fired by itself on the pod. Against a steel wall it
would wear 0.055 a shot. It is an anti-craft gun, not a siege laser.

### 27.7 Save keys and old saves

`lz.e` and `lz.a`; a director's `arm`, a lens's `focus` and any piece's `hp`
in their part states; `target.sel` may hold `{ kind = "spot", body, x, y, z }`.
An old save has none of these, and nothing changes (no hp means 1.0).

### 27.8 Cost

Engine 0.117.1-dev.1468 at 1280 × 720; the full table is in
`work/expansion_x9/NOTES.md`.

- `lasers` with nothing built: a version compare a frame (~0.02 ms smoothed,
  the script's own floor). Two lasers built and disarmed: +0.01 ms. Armed and
  tracking (two directors): 0.06 ms (fixedUpdate 0.035 ms).
- A pulse: 0.5 ms once (its raycast 0.12–0.14 ms). CW: one ray every 0.1 s.
- The beam on screen: GPU +0.07 ms (9.53 → 9.60 ms from the same camera).
- A layout rescan: 0.4–0.5 ms, only when the records change.
- The craft turret armed and tracking: 0.04–0.45 ms (aim at 20 Hz; the spread
  is the machine's load across runs; most of it is `targeting.resolve` on a
  part target). Disarmed: its 1 Hz craft scan, ~0.01–0.02 ms.

### 27.9 Balance numbers for Ty

- Bank 20 MJ, $9,000, 50 kW (6.7 min from flat); pulse share 0.92; emitter
  30 %, stage 45 %; ten banks give 55 MJ.
- Concrete is armour: a 10-bank pulse wears a concrete wall to 0.08, and two
  fell it. Steel and glass walls go in one. A 2-bank laser (11 MJ) fells steel
  and wears concrete 0.18.
- Cooldown 3 s + 0.1 s/MJ at full cooling (21 s after a 55 MJ pulse with one
  Jacket Radiator).
- The turret's 0.5 MJ capacitor costs 3.3 craft batteries (150 EC each) a
  shot: the game's craft EC scale, not a real battery's.
- Research: Directed Energy $18,000 + 120 RP + copper; Amplifier Stages
  $30,000 + 250 RP; Laser Turret $14,000 + 80 RP.

### 27.10 Left for later

- The "Vantage" scenario start (the moon, the hall, the target) and X11's
  Large Director, mirror segments and 8 m dish (the rules already carry them:
  `JIT_LARGE`, any D).
- A remote camera view for the turret (Ty's "remote-control turrets with
  cameras"); the turret has no hand control beyond FIRE and AUTO.
- Crew hit by a beam: the rule is in `damage.crewHurt`, but the scene does not
  cast against crew capsules yet.
- Felled pieces throw generic chunks, not the piece's own mesh (no engine call
  turns a static prefab into a body; a card draft is in NOTES). Asteroid
  fracturing (`0.1 J/kg × mass`) waits for X10's belt rocks.
- Repairing a burnt piece (X8's Repair Kit path reads `wr`, not `hp`).
- A sound of its own (it borrows the surveyor's crack and the pyro bangs).

### 27.11 Tests and the probe

- `tests/smoke_beam.lua` (450 checks): the plan's worked figures, the pulse,
  focus, air and blooming, occlusion, cooldown, the regime (0 for normal
  builds, monotonic, no step over 0.02 per bank, raised by amplification and
  magnification), the layout (chains, groups, open chains, gaps).
- `tests/smoke_damage.lua` (56 checks): the table, the energy floor, walls as
  armour, intercept, the crater and the blast, old saves.
- `tools/perf/laserprobe.sh <engine> [laser|turret]` (PATCHES=funds.patch):
  `LZ PASS|FAIL`, pictures in `save/user/lasershots/`.

## 28. Playtest 11-10: the open kit's frame time, and the outdoor builder camera

Ty, on the 11-09d demo: "base building seemed to be where I was getting
choppy frame rates the second I started placing my first base plate", and
"the camera in the full builder hub mode … gets stuck in the ground and [is]
hard to orientate".

### The chop was the parts column, not the base (`catalog_panel`)

Measured with `tools/perf/chopprobe.sh chop` and `chopab` (fresh save, the
home world, 210 m out; see the table in the probe's README entry):

- **Structures cost nothing measurable.** After a 32-40 piece base with the
  kit shut the frame was 15.9-16.1 ms p50, against 18.6-19.9 ms on foot
  before the first plate: no rise. `placeAt` itself takes 0.6-2.9 ms;
  struct_live, base_roles, base_grid, room_air and the support map never
  reached a slow frame's top scripts, and flora_field (the clear under the
  slabs included) stayed at 0.3-1.5 ms.
- **The open kit did.** With the column unfolded every frame was over
  33 ms: 47-54 ms p50, 136-166 ms p95, up to 600 ms. ALL listed 228 cards,
  about 2,000 UI elements (scene nodes 920 → 2,940): the ui bucket 0.5 →
  6 ms, render instancing +4.4 ms, `untimed` 3 → 20-50 ms, 3 GPU ms more,
  and the once-a-second refresh re-described all 228 cards (catalog_panel
  15-21 ms on that frame). Folded (B) the same scene ran at 19-21 ms; the
  live preview of the part in hand made no difference (preview camera off:
  50 ms p50 still).
- **The first opening of a session** also photographed every card's icon,
  one at a time, for 109 s (228 icons), re-describing the whole list every
  eight.

**The fix: only the rows in view are elements.** `catalog_panel.describe`
builds the cards from `window_of(n, h, scrollY)` (the rows the list's
height shows from its `scrollY`, and `VIEW_MARGIN` = 6 either side), with
two spacer boxes keeping the list its full height, so the scroll bar and
the scroll position are what they were. The window's first row is in the
plate's signature (coarse: every 3 rows), so a scroll re-describes ~25
cards, not 228. The VAB, a stand and a hub use the same panel and gain the
same. Measured after: the open kit 21-24 ms p50 (was 46-64), ui 0.9-1.3 ms,
1,125-1,240 nodes, GPU 8.3-11 ms (was 11.7-19.9); the kit shut after the
base 16.1-17.1 ms. (Both runs shared the machine with two other engines:
their 0.1-3.5 s `untimed` stalls land in every stretch, the shut kit's too.)

### The outdoor builder camera (`builder_camera`, at a stand or a hub)

The old floor at a hub was a plane 3 m UNDER the structure's ground plane,
so an orbit could take the camera 3 m into flat ground; the world clip then
spherecast from a pivot that a pan or a zoom-to-cursor had often put inside
the ground already, found nothing, and left the camera 0.5 m from a buried
pivot. Orbits turned about a point picked off the cursor (on open ground, a
point on the pivot's depth plane), so the pivot wandered away from the base
with every drag, and the wheel jumped.

Everything stays in the builder's frame, which is the structure's own (its
+Y is the radial up where it was founded), so the view is always upright on
the planet; only frame-local values are kept between frames, and the ground
is read in lateUpdate after `fr.refresh()` (planet and frame in one pose).

- **The ground, every frame** (`ground_pass`): the terrain's height under a
  frame point by `terrain.raycast` down the frame's up (the field itself,
  exact; a start in rock answers at once).
  - The pivot under the ground slides back along the view to where the
    ground starts (the picture does not jump); with the camera under too, it
    is lifted to `PIVOT_CLEAR` (0.35 m).
  - The pitch is held so the camera stays `CAM_CLEAR` (0.6 m) over the
    ground under it, and so the sight line clears the ground: a ray from the
    pivot toward the camera that meets a hill steepens the pitch to pass
    `SIGHT_CLEAR` (0.8 m) over that point, up to six times (each try 0.8 m
    more). An orbit down
    stops on the ground, and a hill between the pivot and the camera lifts
    the orbit over it instead of pulling the camera in to the hillside. The
    pitch stays where the ground put it (no spring back when the hill has
    passed: nothing moves that the player did not move).
  - The world clip's spherecast now ignores surfaces it starts against;
    `part_clip` keeps the camera out of the builder's own parts (they have
    no colliders at a hub); and the drawn camera is never under the ground.
- **RMB orbits the selection's centre, else the pivot** (never a point off
  the terrain). **MMB / Shift+RMB pans along the ground plane** at the
  pivot's height. **The wheel eases** (a goal at exp 14/s) toward a part
  under the cursor, or the pivot. **HOME recentres**: the whole base framed
  from a 25° look down along the current bearing. The hub's hint names them.
- The VAB's camera is unchanged (all of this is behind `worldClip`).
- Cost: builder_camera 0.28-0.34 ms a frame at a hub (3-4 terrain rays, a
  spherecast, two builder rays; more only while a hill hides the pivot).

### Tests and the probe

- `tools/perf/chopprobe.sh <engine> chop|chopab` (PATCHES=funds.patch): the
  frame time before, during and after building, every slow frame named.
- `tools/perf/chopprobe.sh <engine> cam`: Base Hubs on flat ground, on a
  raised hill's flank and on a dug pit's rim; the camera orbited low on eight
  bearings, its pivot pushed into the ground, zoomed hard, panned, HOME; each
  checked against the terrain and the local up (`CAMP` lines, pictures
  `save/user/buildshots/{flat,slope,cliff}_*.png`).

## 29. Playtest 11-10: hab segments that join (T, cross, corner)

Ty, on the 11-09d demo: "for surface hab segments they should recognize
what's put near them and change shape to make the connection properly … i
don't want to clog with pieces either so let's make it so it just recognizes
what's near it and forms the connection so you can place a hallway off the
side of a straight one and it will make the 3 way split naturally".

### What a player does

The HAB section is the same four pieces. Aim a Hab Segment (or a Window
Segment) at another segment's side: the ghost is the branch, its end on the
side's middle and square to it, and the segment it would join already shows
the junction it will become (a hologram over it). Click, and the host turns
into the T. A segment off the other side makes the cross; a segment off the
side of a run's last segment makes the corner, its free end plated over.
Taking the branch away gives the straight segment back. Nothing to pick or
swap.

### The rules (`kit_snap.habShapes`, pure)

- **A port** is another joinable segment (parts_kit `join`: the Hab Segment
  and the Window Segment), square to this one, with an END on this one's side
  (its box's side, ±1.35 m, at its ring's middle, within `JOIN_TOL` 0.12 m):
  L on its -X side, R on its +X.
- **The ends.** With a port, an end with no hab piece on it (a probe 0.1 m past
  the end in nobody's box) is plated: b (-Z), f (+Z). A cap or a bulkhead on
  that end opens it again. A straight segment's open end leaks until it is
  capped, as before.
- **The code** is the letters in that order (12 of them: L, R, LR, Lb … LRbf;
  a T is R or L, the cross LR, a corner Rf and so on). Only cans upright, on
  the quarter grid and on the same level join.
- **Derived, kept as a cache.** The record keeps `habSeg.steel` (its cost,
  mass, catalogue entry and refund); `structures.lua` writes the code to the
  part's `hj` (nil when straight) on every `addPart`, `removeParts`, `add` and
  `put` (a placement, a Deconstruct, an undo, a paste, the hub's commit, a
  ruin), re-shaping only the segments within `JOIN_R` (3.6 m) of the change,
  and once for every record after a load, so an old save rebuilds its
  junctions. `habCodes(rec, defs, pts, extra)` is the same rule with a part not
  placed yet (the preview), writing nothing.

### The pieces (`tools/gen_kit_parts.py` `hab_junction`)

- **Hidden variants** `habSegJ<code>` and `habWindowJ<code>` (20 prefabs; a
  window side with a port gives up its window, so a window junction with ports
  both sides is `habSegJLR*`), `parts_kit.joinId(id, hj)` names them. Same
  generator, same sets and paint as the segment (Clad lining and skin, the
  bulkhead's steel plate and hazard frame), its MeshIn split for interior paint.
- **A port** (the host carries it, the branch stays a plain segment): the hull
  cut through ±56.25° of the side and ±0.67 m along it, both skins' edges
  buried in a short trunk: the deck carried through as its floor, a lined
  ceiling at the bulkhead door's 1.8 m, its walls a hazard frame following the
  lining 5 cm proud and then lined inside and painted outside, out to a
  **berthing plate** at the box's side (the flanges' 1.30 m disc, x 1.31–1.35)
  with the 1.24 × 1.8 m passage through it. The branch's open ring butts on
  the plate (its flange on x 1.35), so the joint is flush and closed; the plate
  is clear of the run's neighbouring flanges. The host's saddles move to
  ±0.87 m, clear of the trunk.
- **A plated end**: the lining's disc inside at 0.95 m, a raised cover plate
  on the flange outside with two stiffeners and a data plate.
- **Colliders**: the ring boxes over the hole are split either side of it; the
  trunk's floor, ceiling and walls and the plate round the passage are boxes
  (a T has 32 colliders to the straight segment's 19). The generator's
  z-fight check finds no coplanar faces but the flange and kick-strip ends
  every segment already has.

### Drawing it (`structures.spawn_part`, `reshape`)

A segment with a code spawns its variant's prefab. A live segment whose code
changed is spawned again as its variant, and its old node goes only when the
new one lands (each part's newest spawn lands, an older one destroys itself),
so nothing blinks; its footing is not cast twice. Nothing runs per frame:
the work is on a placement or removal, and the variant is one more prefab,
not more nodes on the piece.

### Snapping and the preview

- `kit_snap.face`: a joinable segment aimed at a joinable segment's ±X face
  goes at that side's middle, (1.35 + 1) m out, turned a quarter; a cap is
  not offered the side. In the Base Hub's builder the same rule snaps a
  segment to a side (`builder.kitSnap`).
- `field_builder.join_preview`: with a segment in hand on a face pose, the
  codes are worked out with the ghost added (only when the pose or the
  structure changes). Each neighbour that would change is drawn as its
  variant, a hologram parented to the planet at the part's own pose (set
  once: the planet moving carries it), and the real can is hidden once its
  hologram is there; the ghost in hand is its own variant if it would be one.
  The hand emptied, the pose moved or the part placed, the holograms go and
  the cans are drawn again.

### Rooms and air (`rooms.lua`)

A segment's sides, floor and crown now run to ±1.25 m (`CAN_EXT`, the can's
own radius) instead of ±1.0, so a branch, which stands 0.35 m off the 1 m
grid, rounds onto the same cells as its host, and its far end meets its cap.
A junction (its `hj`) seals as its variant: no quad on a port's side (the
branch's walls close round it) and a section quad at ±1.25 m for a plated end.
A T, a cross or a corner with its branches capped is ONE sealed room that
holds air (a tank anywhere in it fills the whole thing); a branch's open end
leaks. The seal signature carries the code. Aligned runs solve exactly as
before (the extension only reaches a cell whose middle is past the end).

### Z-fighting and the joint seam (Ty, playtest 11-10: "standing in any room flickers")

The generator's coplanar-face check (`base_models.zcheck`) over every kit
piece found 4,090 overlapping same-facing face pairs; the ones in the pieces
rooms are made of are fixed, each face inset 2–5 mm or its hidden copy removed:

| Piece | The fight | Fix |
|---|---|---|
| every hab segment and junction | the deck plate's and the kick strips' ends in the flange's face at z ±1 | both stop 4 mm short (`KICKZ`); the deck's collider stays whole |
| Door Wall (and mirrored), Double Door, Open Frame, Window, Vent Louvre | the reveal lining's face in the panel's cut edge and the channels' ends; jambs overlapping the head and sill | linings stand 3 mm into the opening; jambs meet head and sill end to end, 2 mm off the floor line |
| Airlock Wall | the pressure frame's jambs over its head, in the wall's cut edge and its end stud | 3 mm into the opening and in from the wall's end, jambs under the head |
| Hab Door Bulkhead | the hazard frame 3 mm into the plate, its head over its jambs | on the plate's face, the head between the jambs |
| heavy door leaves (Airlock Wall, Bulkhead, pressure Bulkhead) | the top chevron ending on the leaf's top face | the chevrons stop 5 mm under it |
| Window Wall | the transom's ends in the panes' ends | the panes' edges sit inside the reveals, the transom stops on them |
| Porthole Wall | its flange discs faced the wall (see-through from outside), their bolts' feet in them | the discs face out |
| Roof Ridge, Lead-lined Wall, Wall Cable Tray | ends and stacked plates sharing planes | 2–5 mm apart |

Every hab piece and every wall-class piece now checks clean. What the check
still counts in them are undersides at y 0 pressed onto the floor or wall
they stand on (a corner post's, a handrail's, the tray's clips), never seen.
Elsewhere (props, trusses, machines, the reactor's and fluids' parts, in
their own generators) 3,321 pairs remain: a list for the next pass is in
`work/habjoin/zall_after.txt`.

**The joint seam.** A hab can is two skins; their gap was open at the ends,
so the hairline where two segments' linings meet showed back faces behind
it. `hull()` now closes the gap with a ring 1 cm in from each end (out of
sight behind the flanges) and backs the hairline with a 12 mm band of lining
4 mm behind it, facing in, so a sub-pixel crack shows lit lining. What is
still seen at a joint in the probe's pictures (`hj11b`) is a faint tick where
each dark corrugation stripe crosses it: the texture's seam, not a gap.

**Smooth arcs.** The port's frame and trunk walls are curved slabs with
smooth normals on their arcs (no facets catching the light in steps), and
no faces inside them.

### Left for later

- Ports on a can's top or bottom (a vertical can has no deck).
- The Base Hub's builder draws the segments straight while you edit; BUILD IT
  spawns them as their junctions.
- Fittings inside a can are still refused by the overlap rule.
- Ground plants grow up through a hab's deck (straight segments too, seen in
  the probe's pictures): `flora_field`'s clear doesn't count a hab's raised
  deck. Not changed here.

### Tests and the probe

- `luajit solar/tests/smoke_hab_join.lua`: the neighbour-to-shape rules
  (straight, T either way round, cross, corner both ends, a cap or a bulkhead
  opening a plated end, a lone segment's dead-end T, a branch that is a host
  too, removal changing only the host, nothing for another storey, an
  off-square can, a parallel can, a branch half a module along, a cap at the
  side; turned and moved half a module), the preview writing nothing, the side
  snap (and not for a cap), the variants (hidden, on disk, in the bounds, not
  in the column), structures (an OLD save rebuilding its junction, placing the
  cross and the corner, the code saved as a cache, undo, a record added whole,
  a record put), rooms (a T, a cross, an L and a long branch capped are one
  sealed room, an open branch leaks, each moved half a module and turned; the
  branch's volume; the signature) and the cost.
- `tools/perf/kitprobe.sh <engine> habjoin` (PATCHES=funds.patch;
  `tools/perf/habjoinprobe_modes.lua`). Pictures
  `save/user/buildshots/hj*.png`; numbers in `work/habjoin/NOTES.md`.

## 30. Playtest 11-10: z-fighting pass 2, gas racks, steps, doorways, plants under decks

Ty, 11-10: "please fix all the zfighting on base parts ... incomplete pipes
where they're not properly connected", "barely squeezing through doors",
"abandoned bases have too tight of doorways and things blocking them, and like
the stairs going up to the entrance doorway I had to get on it and crouch to
get inside". The engine's depth is not the cause (E: Depth32Float, near
0.05, ~0.02 mm at 4 m): coplanar or near-coplanar faces are, and on a turning
planet their winner re-rolls every frame, so they shimmer standing still.

**Every kit piece is clean.** §29 fixed the hab and wall pieces; this pass the
rest (props, trusses, machines, the plant, fluids, logic, conveyors, lasers):
zall 3,299 pairs → only the undersides at y = 0 that stand on a floor. A
stricter check (planes within 1.2 mm, across zcheck's bucket edges; inside-
solid per primitive) found 87 more (heavy door chevrons 1 mm off the kick
plate, crate posts, cable-tray clips, screen bracket) → 0. The rules used:
trim 2–3 mm proud, members ending 2–3 mm inside what they butt into, caps
offset, hidden faces buried. Bounds move ≤ 5 mm, ports never.

**Between pieces.** A slab's edge strips stop 2 mm inside its edge (their ends
lay in the end faces of walls standing on that edge); the Open Frame's opening
is 1.72 m (a 1.8 m hole put its jambs in the faces of the walls either side at
a room's corner). Ruins: the shack's workbench 5 mm off the back wall (its
pegboard lay in the wall's face), the mine's cross beams 3 mm over the long
ones, crates apart. Left: where two walls meet at a corner their top faces
overlap in a 0.1 m square outside the roof, seen only from above.

**Gas racks.** The Air Tank Rack's manifold sat tangent on the cylinder necks
and stopped short of the regulator: each valve now has a pigtail into a boss
on the header, the header is capped at one end and runs into the regulator,
which hangs on the right post, its outlet to a wall plate; the straps are
bands bolted to back rails (they were rods through the cylinders). The fluids
bottle racks (O2, N2, H2) the same, down to their port nozzle; the riser's
high nozzle had no flange (a missing `y`), the charge pump's header floated;
the O2 Generator's back stands 15 mm in so its nozzles' flanges show.

**Doors.** The capsule is 1.9 × 0.62 m. The Airlock Wall's and the Pressure
Bulkhead's openings are 2.08 m (were 1.95: 5 cm over the head). A door used
to start opening at `near` (2.2 m) and take `secs` (1 s), so a walker met a
leaf 39 % open. `kit_live` now adds to a door's reach the distance you close
in the time it takes to open, while you walk toward it (the first-person
pass's proposal), and the pocket doors slide faster (Door Wall 0.7 s, Double
0.9 s, hab door 1.2 s): walking up, a Door Wall's leaf is ~90 % open when
you reach it. `near` itself is unchanged: a longer one held an outside door
open while you stood in a small room, and an airlock's inner door with it
(kitprobe rooms). Not changed: the hab door and a junction's port are 1.8 m
(the can's 2.0 m inside height leaves no room).

**Stairs.** The handrail colliders of Stairs, Steps and the Ship's Ladder
stand square to the slope; full length, their ends reached ~0.4 m past the
foot and the top and fenced off the way on (a ladder by a wall couldn't be
reached at all). They are 0.8 m shorter.

**Steps and ruins.** Steps 0.8 m are for a hab's deck; at a slab's 0.2 m sill
they stood on the ground with their top 0.6 m over it. The Hab Block ruin's
steps now have their top tread flush with the slab, butted to its edge under
the door (the lower treads in the ground). Its airlock receiver stood across
the path between the two doors (now beside it); the ladder came up through a
0.9 m hatch (too short to climb standing, and its top went through the floor):
an open well x 1..3, z -3..0 with a rail, the ladder topping out at its edge.
The shack's drum is outside, the power hall's shield blocks west of the
double door. smoke_ruins checks every doorway clear a metre each side and
steps flush with the sill. (Graveyard's own steps: a patch for its scenario.)

**Plants under decks.** `flora_field`'s structure clear now counts hab pieces
(their deck is 0.8 m up), kit floors and slabs up to a storey over the ground
(rooted down to 1.5 m under them), and blocks standing on the ground. Same
budgeted job; no per-frame work.

Probe: `tools/perf/kitprobe.sh <engine> zfight` (`zfprobe_modes.lua`).

## 31. Consoles that do things: the base terminals (interaction slices S3, S4)

Ty, 2026-11-10: "the computers don't really let me do anything". Every console
piece is now a terminal you walk up to: a **Desk Monitor**, a **Wall Screen**,
the **Reactor Control Console**, a **Ladder Controller**'s desk, a **Fire
Control Console**, and any of them in a ruin. Within 1.9 m and facing it,
"Use the console · E" comes up; **E** opens a CRT screen over the running
world (`scripts/terminal.lua`, on the ContextLib prefab).

- **Keys:** 1–0 and TAB pick a page (a pad's bumpers); ↑ ↓ ENTER (the d-pad
  and A) walk and press the rows; the mouse clicks them; ESC backs out of a
  sub-page, then leaves (a pad's B). While it is open the keyboard is the
  terminal's (`input_guard.hold`: the crew stands at the desk) and the pointer
  is free (`planet_camera.panel_open`); the pause menu's Esc ladder, the belt,
  the context menu and the laser's E all stand down.
- **Pages are data:** `terminal.registerPage(id, fn, { order, title, scopes,
  orderFor })`, `fn(scope, ctx) → rows` in the right-click menus' entry
  contract (plus `line` and `image` rows). The game's pages live in
  `scripts/terminal_pages.lua`: STATUS, POWER (grids, breakers: open, close,
  trip test, reset; the lights per structure as load shedding), FLUIDS (every
  network, tanks, pumps, valves, regulators, the reactor's coolant pumps),
  DOORS (lock and unlock, hold open, cycle an airlock to a door), AIR (rooms,
  scrubbers, O2 generators, equalise valves), LOGIC (a PLC's RUN, levers,
  buttons, readings; a cable-driven device's Local control), CREW, LOG; on the
  reactor's desk REACTOR and ALARMS first; on a ruin's terminal its recovered
  LOG (the site's lore) and DATA (its Data Core; `terminal_pages.lootRows` is
  the hook for loot).
- **Every key is the piece's own switch:** a press goes through
  `context_registry.press` with the system's `whyNot` / `warnOf`, exactly as
  the part's menu. Refused only for a physical reason (not plumbed, knocked
  askew, a Signal Cable has it until Local control, a tripped breaker must be
  reset, the console is dark: no base grid at all); a dangerous choice is
  done and its consequence toasted ("protection bypassed: nothing will stop a
  meltdown").
- **Reach:** a console acts on its own structure and every structure on its
  base grid (wired), never further. The reactor's desk is hardwired to its
  plant (never dark).
- **REACTOR (S4):** power, period, rods, primary flow and temperature (margin
  to boiling), fuel and steam, the pressuriser, the protection (BYPASSED in
  red), what limits it; a trend picture painted in place at 2 Hz (power,
  primary temperature, flow over the last minute; the 24 h power under it);
  the keys SCRAM, reset, start-up, setpoint − / +, rods in / out, every
  coolant pump, the makeup pumps and valves that feed the primary, protection
  armed / bypassed, cool-down, turbine.
- **The base log** (`scripts/base_log.lua`): 200 events per structure, saved
  as `log.<sid>` every 30 s: breaker trips and switching (the
  `base_power.onBreaker` hook), SCRAMs and trips, start-ups, protection,
  pumps and valves worked by hand, doors locked, held, forced and cycled,
  life machines, air alarms, a player's own notes; each with the agency
  clock, who did it and at which console. A scenario's staging (no `by`) is
  not logged.
- **Doors** (`kit_live.setDoorHold(sid, uid, "lock" | "open" | nil, by)`,
  part state `dh`): a lock holds a door shut whatever walks up or signals;
  held open, an airlock's chamber and a pressure difference still rule it.
- **Scenarios:** the goal kind `terminal = { struct?, page? }` completes
  while that console is open (on that page).
- **Cost:** closed, a prompt check at 8 Hz over an index of console pieces
  (rebuilt when the structures change); open, the page's rows are kept for a
  second (their numbers are live) and the plate described at 4 Hz.
- Tests: `tests/smoke_terminal.lua`; `tools/perf/termprobe.sh <engine> scn`
  (Graveyard Shift staged: the prompt, E, every page pictured, a breaker
  trip-tested and reset, MU-1, SCRAM, the airlock, a door, the log, Esc, the
  desk monitor, the cost).

## 32. Builder performance, and a hab you walk into standing (11-10)

### Where a big base's frame went

`tools/perf/kitprobe.sh <engine> kitperf` (500 / 2,000 / 6,000 pieces in
view). Numbers in `work/builderperf/NOTES.md`.

- **Instances.** A wall-class piece is 4 instances (its Mesh and its MeshIn,
  each in two materials) since S4 gave a wall's inside face a node of its own
  (paint) and S5 a 12 % sky reflection; a floor is 1. That is the 50 % more
  instances per piece than the S1 measurement. Two material states a side
  cannot share a primitive (an engine card asks for per-primitive material
  numbers in one instance). What changed here:
  - **The inside is the faces that look into the room** (`paint_split`):
    facing −Z on or past the panel's inner face. A wall's top, ends, a
    doorway's reveals and a sill are the Mesh's. Split by centroid before,
    each of those faces was cut along its diagonal, half painted and lit as
    the inside, half as the outside: now they are the outside's.
  - **A wall's MeshIn casts no shadow** (the Mesh is its whole silhouette): one
    sun-map draw less a wall. A hab can's lining still casts.
  - **A concrete or regocrete panel's inside is the concrete alone** (its
    lifting inserts are on its top): 3 instances, was 4.
  - (11-11: the next two bullets are gone, see §34: a wall's inside is slots
    of its one model now.)
  - **A wall's inside is not drawn from outside it** (`kit_live`, "a wall's
    inside, seen from outside it"): from the wall's outer side every MeshIn
    face looks away and lies behind the wall's outer face and reveals. The
    camera is tested against each wall's plane in the camera pass,
    body-relative: walls within 10 m every frame, the rest a slice a frame
    (all in ~8 frames) with a margin for the camera's motion; a cut hides
    nothing that frame. `kit_live.setWallCull(false)` turns it off,
    `wallStats()` counts. Test: `tests/smoke_wall_cull.lua`.
  - Plain walls have no script, so structures tells kit_live as one lands
    and goes (`wallSpawned`, `wallGone`); kit_live's scans and its light pool
    walk only the pieces with a door, a light, a screen or a sign.
  - The base census (`base_roles`) keeps each part kind's def: it read every
    part's through two scripts, a 60 ms frame after a 2,000-piece structure
    landed.
- **flora_field's structure clear** made the 40-48 ms frames: each pass read
  every part's `partInfo` through two scripts, and tested every prop a near
  query answered against every floor box. A part kind is looked up once; a
  structure's boxes are built once per records change, a slice a frame, into
  a 4 m grid in the structure's frame; the near queries are paged under the
  same budget (smoke_flora).
- **tool_belt** polled for nodes that are not in the scene ("FacRepair", the
  laser's muzzle and impact while it is away); the engine's `find` walks every
  node for a name it does not hold, so its cost grew with the base. A miss is
  remembered for half a second (engine card: a missing name from the index).

### The walker (measured, partly fixed)

`tools/perf/jitterprobe.sh <engine> jitter` now records the Back bone and the
head in the model's own frame, the hips' drop, and two landings. Walking, the
Back's height jerks 4-6 cm between two frames at each heel strike (d2 rms
18-22 mm): the gait clips' own hips (24 keys a cycle), not the walker's drop
(0.2-0.7 mm). A landing folds 16-19 cm in 3 frames: the land clip's absorb at
0.09 s. Changed: the lean's acceleration is taken from an eased speed (the
tick-stepped speed spiked it), the land clip fades in over 0.14 s, the
landing dip eases down. Easing the hips in the walker (a MaleArm offset)
measured no change and was taken out; the fix is in the clips
(`tools/gen_astronaut_anims.py`: more keys or a smoothed pelvis in the gaits,
a later absorb in `land`).

### The hab's deck, 15 cm lower (Ty's decision)

The walker's capsule is 1.9 m; the hab door and a junction's passage were
1.8 m. The deck is at 0.65 m (was 0.8) in every segment, window segment and
junction, so both are 2.0 m clear. The can, its flanges, saddles, colliders
round the hull and its snap points are as they were; the deck is 1.14 m
between the kick strips (was 1.57). `deckTop` is 0.65, so what stands on the
deck stands on it.

- **The Door Bulkhead** has a centred 0.76 × 2.0 m opening closed by a pair of
  heavy leaves that slide apart (`door.pair`, 0.38 m each way, 0.9 s). One
  2 m leaf parked beside the opening would have to reach past the flanges'
  1.28 m: the pair parks inside them.
- **Hab Steps 0.65 m** (FOUNDATION, new): three risers from the ground to the
  deck at a Door Bulkhead. Steps 0.8 m are for a 0.8 m deck or door and stay
  as they were (ruins and scenarios use them at slab sills).
- `tools/perf/kitprobe.sh <engine> zfight` walks a capped run with a Door
  Bulkhead and Hab Steps at its end and a branch off its middle: up the steps,
  through the door, along the run and through the port into the branch,
  never crouching (`hab_door`, `hab_port`, `hab_stand`).

## 33. What pieces hold, keypads and stripping (interaction slices S5, S6)

Ty 2026-11-10: "a lot of depth with how you can interact with every individual part in a world that needs to extend to looting, exploration, your own bases, scenarios". The rules are `scripts/loot.lua`, the panel `scripts/loot_panel.lua` (both on ContextLib); tests `tests/smoke_loot.lua`, probe `tools/perf/lootprobe.sh`.

- **Containers.** Every kit piece with `container = { kg, L }` in parts_kit is an inventory container `piece:<sid>:<uid>`: Cargo Crate (400 kg, 480 L), Small Crate (90, 90), Shelving (250, 300), a Workbench's drawers (150, 120), a Bunk's footlocker (60, 80), and two new props, the Store Cabinet (200, 250) and the Personnel Locker (100, 150), both with a keypad on the door (`tools/gen_kit_storage.py`). Walk up and E (or "Open it" on the menu): a two-pane transfer, the container on the left and your pack on the right, each with its kilograms and litres. Click moves one, Shift+click all of an item, a material moves as a stack; what does not fit stays and the foot says why. Storage is real on your own base. A container taken down by any hand (Deconstruct, a laser, a strip) spills what it held into a salvage crate where it stood.
- **Ruin loot.** A ruin's containers are rolled once, all at once, when the first is opened (by the site's kind and age, from its seed; `ruins.s[id].lp`): rations, rusted tools, crated spare parts of the site's kind, cells and flares (W4's items, kept by id until they exist), oxygen tanks and cells part spent with age, medkits, ore samples of the world, and **data logs** (`datalog:<key>`): a shift note with every code on the site (never put in a locked box), diaries, a survey note with another site's position (reading it finds the site). Hab ruins gain a locker and a cabinet, power halls a cabinet and a locker, camps a locker (appended to the grammars: every older piece keeps its `ri`).
- **Keypads.** Part state `kp` (the code), `kpo` (opened), `kpb` (forced). A locked door is bolted (kit_live `dh = "lock"`), so a console that reaches its bolt can still release it. Ruin doors lock by kind (power hall 85 %, hab 55 %, camp 30 %, mine 35 %, relay never), cabinets and lockers three in five. Three wrong codes lock a keypad out for 30 s. A code read in a log or on a ruin terminal's DATA page (ACCESS CODES) is offered as a key. Fit a code on your own lockers and doors from the menu. **Force** any lock: the Terrain Laser 25 s, a Repair Kit's cutter 40 s, the Gravity Gun as a pry bar 60 s (an Engineer 60 %, a door 1.25×). It is loud (`loot.lastNoise`, 60 m), breaks the lock for good, knocks a container and wrecks a door's seal (room_air.forceDoor: it vents if it holds pressure).
- **Strip for parts** on any kit piece or machine: an Engineer with a Repair Kit or the Terrain Laser in the pack, 5–45 s by mass (the laser 0.7×). A sound fitting under 60 kg comes off crated (`part:<id>`); otherwise its material, 60 % back (rusted 45 %, knocked 40 %; concrete as regocrete). What stood only on it comes down too (a quarter of their material back). The pack takes what fits; the rest is a salvage crate beside it. Stripping a wall of a pressurised room vents it: allowed, warned on the menu ("If stripped: Room 2 (0.98 atm) VENTS").
- **Cost.** Closed: the panel's prompt check at 8 Hz over an index of container and keypad pieces (arithmetic, no rays; 0.05 ms a check); loot.lua looks at the structures' version twice a second for a container taken down. Open: described at 4 Hz, `ui.make` only when what it shows changed. A ruin's roll is one-off (under 1 ms).

## 34. One instance a wall: the inside folded into the model (meshfold, 11-11)

Engine 0685 draws a model whose parts differ only in material numbers
(colour, roughness, reflectivity, glow) as one instance: the parts are laid
end to end and each vertex reads its part's material from a slot table. It
merges only parts that bind the SAME texture set, and only within one model.
A wall was cladding (or concrete) plus steel (two sets) and its inside a
child node (`MeshIn`, §32) of two more parts: 4 instances, merging on or off.

- **The inside is slots of the wall's own model** (`tools/gen_kit_parts.py`
  `fold_inside`): the room-facing faces `paint_split` takes are added back as
  `CladIn`, `SteelIn`, `ConcreteIn`, with the outside's set and 12 % sky
  reflection. There is no `MeshIn` on a wall-class piece now (hab cans keep
  theirs: their faces wrap round the can and do not fit the atlas below).
- **One texture set for every wall-class piece**: `textures/kit/wallkit_*`
  (albedo, normal 2880 × 1024, ORM 1440 × 512), the cladding, steel and
  concrete sets side by side across U, each column with a gutter of its own
  wrapped edge. V still wraps (each set tiles over the atlas's full height);
  U cannot, so `wall_atlas_uv` moves every connected face into its set's
  column: a whole-tile shift when the face then fits (it samples exactly what
  it did), else centred in the tile (a whole wall's cladding panel straddled
  the wrap: its texture moved half a tile), and a face wider than a tile
  across U but not V is turned a quarter (a rotation, never a mirror, for the
  normal map). The generator refuses a face that fits neither way, and
  refuses to turn cladding (its ribs run along V). A glass wall (steel only)
  keeps the steel set and needs no atlas. Regenerate: `python3
  tools/gen_kit_parts.py` (the atlas is written with the kit's textures).
- **Paint goes to the slots** (`kit_paint.slotsOf`, `apply`): a folded wall's
  outside slots get the outside paint and dust, its inside slots the inside
  paint, each as that slot's colour through `node:material(slot)` (the
  prefab's override holds the slot's whole material, so only its colour
  changes). setTint would cover both faces. The door leaves still take a
  tint. A highlight sets the slots back to white for as long as it is on and
  the paint comes back after.
- **kit_live's wall cull is gone** (and `wallSpawned` / `wallGone`,
  `setWallCull`, `tests/smoke_wall_cull.lua`): there is no inside node left
  to hide. The inside faces now cast with the Mesh (the same instance).
- Instances: a plain wall 1 (was 4, 2 culled), a window wall 2 (its pane is
  glass), a door wall 4 (the leaf moves, its pane is glass, the lamp lens has
  its own set). kitperf numbers in `work/meshfold/NOTES.md`.

## 35. Wood: a timber tier for the Build Kit (progression W1)

Ty 2026-11-11: "we should also have cheaper building options like things made of wood for making bridges and simple structures and stuff. Obviously it shouldn't sustain crazy damage, like a storm on another planet, but on the home planet they'll last forever essentially, just not handle crazy heavy weights." The plan is `work/progression/PLAN.md` §3; this is slice W1 (the material and the pieces). The load model (W2: sag, creak, break) and weathering (W3: rot, fire) come later and read what is here.

### The material (`parts_kit.lua` MATS.wood)

- **Timber**: 550 kg/m³, `strength = 40` (a quarter of steel's 180: W2's capacities read it), `seal = false`, `rot = true` (W3's hook). `COSTK.wood = 0.22`; fills: a stud wall boarded both faces 22 %, joists and boards 25 %, rafters and shingles 20 %, sawn beams and posts solid, a framed truss 35 %; pieces whose class fill would be wrong name their own (a timber stair is stringers and treads: 0.105).
- **It never holds air.** `seal = false` drops a piece's `seals`, so in `rooms.lua` a timber wall is a named leak and a timber floor no plane: a hut is never a sealed room. The honest reason to go to steel for Shelter.
- **Worked numbers** (smoke_kit_wood): wall 106 kg $130 (steel 110 kg $600), floor 110 kg $110, beam4 176 kg $80, pillar2 $50, roofPitch $90, stairs $210.
- **On 24 existing pieces**: floor, floor21, floor11, wall, halfWall, wall12, doorWall (and its mirrored variant), windowWall (a timber sash, its pane glass), openFrame, roofPitch, roofRidge, gable, pillar2, pillar4, beam2, beam4, rail, stairs, steps, ladder, ramp, pier, catwalk. M cycles to timber last.

### The TIMBER pieces (first in the parts column)

| piece | what | kg | $ |
|---|---|---|---|
| Log Post 3 m / 5 m | a 0.3 m peeled log (Bark016); set on the ground it is held by it (`gnd`) | 117 / 194 | 60 / 95 |
| Timber Beam 6 m | 300 × 200 sawn, chamfered, through-bolted at its bearings | 198 | 120 |
| King-post Truss 4 m | tie, rafters, king post, struts, galvanised gussets | 150 | 110 |
| Bridge Deck 2 × 4 | planks across three runners, 2 cm gaps, nailed; wheels roll on it (one flat collider) | 240 | 170 |
| Plank Floor 2 × 2 | boards on bearers, 80 mm | 90 | 80 |
| Shingle Roof 2 × 2 | split shingles in staggered courses on battens and rafters, the pitched roof's frame | 70 | 90 |
| Fence 2 m | posts, two rails, pointed pickets | 25 | 25 |
| Plank Door Wall | a stud wall with a 1.0 × 2.05 m opening and a ledged-and-braced plank door on strap hinges | 95 | 150 |
| Camp Mast | an 8 m peeled pole on raking struts, a radio box, a whip antenna: **founds a base** | 170 | 450 ($350 of it the whip) |
| Mine Shoring Frame | a square set: two battered log legs, a cap, wedges; 1.5 m wide, 2 m clear | 140 | 110 |
| Sawbench | trestles, a slotted top, a 0.5 m rip saw, its crank wheel and motor | 60 | 490 ($450 the saw) |

- **The hinged door** (`door.swing = { hinge, deg }`, kit_live): the leaf turns about the vertical through its hinge, AWAY from whoever walks up (the side is picked while it is shut and kept until it shuts). Its strap hinges creak open and it shuts with a knock (CC0: the cave creak set, Kenney's wood impact). Its colliders turn with it. The clear opening is 0.95 × 2.03 m.
- **The Camp Mast** has `tower = { mast = 7.5, draw = 0.5, spacing = 300, radius = 150, station = false }` and `script = "base_tower"`: `base_tower.reconcile` founds a base for ANY part whose record has a `tower` (it keyed on the id "tower" before), with that part's mast height and draw (base_grid takes each base's draw through `base_tower.drawOf`). `station = false`: it is a beacon-class relay powered or not, never a ground station (the Base Station Tower keeps that). Founding marks the feat `base_founded`, so a Camp Mast unlocks the Solar Array and the Battery Bank (P1).
- **Shoring** is behind `research.TECH.shoring` (granted by the feat `cave_kinds`). `shore = true` is the hook for `cave_hazards` (the plan's ×0.15 on an unstable cell's fall odds and the frame taking a slab's hit): not wired in W1.

### Planks (`materials.lua` plank, `scripts/timber.lua`)

- A refined material counted in kg (density 550). A **timber** (what a tree yields, what the Intake took from a log) is a sawlog length: it saws to **25 kg** of planks, so a 4 × 4 m hut (~1.6 t) is ~64 timber, a dozen trees. (The timber's 1.2 kg is the pack's weight for one: its abstraction.)
- **The Sawbench** (right-click): saw 1, 5 or all the timber in your pack (then the warehouse at home); it saws on the game clock (warp saws a lot) by hand at 10 kg of planks a minute (20 if an Engineer set it up), or 40 when a base grid serves it: its 0.6 kW is an aux load while it saws (`timber.gridAux`, base_grid's `partServed`). Planks go to the warehouse at home, to the setter's pack elsewhere. Stop gives back the whole timber not yet sawn. `machines.MACH.sawbench` holds the same numbers (0.9 kJ a kg of boards).
- **The Depot**: the Materials Intake's menu sells planks in 100 and 500 kg lots at $0.60 a kg plus the usual shipping, into the warehouse (the Sawbench at home offers the same). The depot buys them back at $0.25 (they are for building).
- **Paying for a timber piece** (`base_economy.quote`, `field_builder` `home_opts`): at home, when the warehouse holds the piece's mass in planks (`def.planks`), they are taken and only its fittings are paid (`def.fit` = $10 + 2 % of the steel price + its hardware: the mast's whip, the saw); the card reads "106 kg of your planks + $22 fittings". With too few it ships ready-cut at its price. Undo and Deconstruct give the planks back. Off-world the crated rule holds: a Fabricator makes a timber piece from planks (`recipes.KIT_MAT.wood = "plank"`, `FAB_TAKES.plank`).
- **Strip** a timber piece: planks back (`loot.STRIP_MAT.wood`). The laser cuts wood faster than steel (`damage.F_MAT/E_VOL/RHO` rows), its sparks ember orange (`lasers.MAT_COL`). Paint on it is a stain (`kit_paint.BASE.wood`, dark).
- `wood_built` (P1) counts timber pieces placed.

### The look (`tools/gen_kit_wood.py`)

Every board is its own box, its grain along its length, at a random place in the CC0 Wood062 set with its own tint; gaps of 4–8 mm show the dark behind. A wall is a real stud frame (plates, studs at 600, framed openings) with lapped weatherboards outside (each tilted so its foot stands proud), vertical boards inside, linings and casings round its holes. Logs are Bark016 browned, with sawn end grain; iron is black, post bases galvanised. Rough (the set's roughness, metallic 0): wood never shines. The generator is imported by `gen_kit_parts.py` (`install`): wood is added to the existing pieces without touching their steel builders, and their colliders are the existing piece's, so a timber floor walks and snaps exactly like a steel one. A timber wall is folded like every wall (§34: its inside is its own model's `TimberIn`/`SteelIn` slots, painted apart, `kit_paint.FOLD_GUESS.wood`) but keeps its own two texture sets (the atlas has no timber column): two instances, not one. Wood reflects 0.3 of the sky (at 1.0 a rough dark board read as blue-grey concrete outdoors), and its albedo is `textures/kit/timber_albedo.png`, Wood062 warmed and lifted toward a weathered pine (made by `timber_albedo()` from the CC0 set). Z-fighting: every member of a frame stands at its own depth, alternate courses of laps and shingles stop short at their ends, shingle joints keep 2 cm from those below, nails stand 2.5 mm proud; `zall` over every timber prefab is 0 (`work/prog_w1/zall_w.py`, ZW=1).

**W2: the board set** (Ty 11-11: the W1 hut read as grey stone or concrete from 20 m: Wood062's fine grain had gone to a uniform noisy grey-brown and nothing showed a board). `textures/kit/timber_board_{albedo,normal,orm}.png` is a strip atlas made by `timber_board()` from the CC0 Wood062 set (so CC0 too): four boards one above the other, each 128 px across its width, the grain along U at the set's own scale (`UVW` 0.9 tiles a metre, unchanged: the scale was right). Each strip is weathered toward a grey-brown softwood (the pores softened along the grain, 22 % silvered, linear means 0.26-0.33 / 0.20-0.24 / 0.12-0.15: warm enough that a wall in shade, lit by the blue sky alone, reads as wood and not slate, one strip greyer, one warmer), its TOP a broad lap shadow and its FOOT a thin dark line under a lit arris, in albedo and AO, and an arris in the normal map; rougher than the set (0.84, 0.95 at the edges). `_shift_uv` puts every Timber face (a box's six, a prism's caps and sides; a peeled log and an end cap whole) into one strip of its own (v across the face 0..1), so every board, stud, shingle and plank has dark edges where a real one does, and the courses and planks read at 20-60 m. The boards' own tints spread 0.70-1.0 (W1: 0.80-1.0), one in five greyer. Normal strength 0.9. `kit_paint.BASE.wood` follows the new mean (0.252, 0.186, 0.115). The grain's normal detail is held to 0.45 of the set's (it only sparkled at 5-20 m).

### Save keys and old saves

New: `timber.saw` (the saw jobs), a part's `paid.planks`. Nothing old changes meaning: every existing piece keeps its materials, ids and prices, and a save without timber loads as it did.

### Left for later

- W2: the load model: done, §37 (the inspector's LOAD line is still to do).
- W3: weathering off-world (`rot`), fire where there is oxygen; the shoring's hold on a cave's roof.
- Sounds: plank footsteps, the saw running; a codex entry for planks.
- Depot "sell all" sells planks with the rest of the warehouse.

### Tests and the probe

- `tests/smoke_kit_wood.lua`: the material, masses and prices, the TIMBER pieces, planks-first quotes and their card and ledger lines, recipes, leaky rooms, the saw's rates and job arithmetic, the Depot's lots, strip and damage rows. `smoke_kit` checks every timber prefab's bounds; `smoke_recipes` every timber recipe.
- `tools/perf/woodprobe.sh <engine> wood` (20/20 on 0.118.3-dev.1496): the motorcycle ridden 150 m out and braked to a stop, both banks levelled and a 1.7 m gap dug 15 m ahead of it, a 6 m bridge built over it in its frame (two beams, three decks, six fences, four posts); ridden across at 4–8 m/s (its root 0.43 m over the bridge's base at mid-span, as on the run-up), stepped off and walked back (the walker 1.05 m over the deck); a 4 × 4 m hut (21 pieces) holds no air, its plank door swung 92° as the walker came in; 500 kg of planks ordered, a timber wall paid from them (106 kg + $22), the Sawbench sawing 2 timber by hand and stopped (timber back). Pictures `buildshots/wd*.png`. (The probe measures the bike by its tyres' drawn places, never `assembly.info`'s tick pose against `space.body`: that mix put the bridge 16 m off.)

## 36. Purging a room (the Air Tank Rack's purge pump, 11-11)

Found by the progression arc (P2): on a home world with 1.2 atm of oxygen-free air a newly sealed room closes round that air; an O2 Generator needs more than a game day to fill 18 m³, and the racks' regulator never opens over 0.97 atm. The Shelter milestone ("an hour of the room's own air") could not be done there.

**What it does** (`scripts/room_air.lua`, THE ROOM PURGE): pump-down and backfill, what a real habitat does. Every Air Tank Rack in the room has a purge pump (`life.purge` 0.3 m³/s at the room's pressure, `life.purgeKW` 2 kW from the base grid, the rack's `power = aux`). PURGE runs every rack's pump in the room's network and dumps the gas overboard down to `RP_P` (0.01 atm); the purge is then done and the racks' regulator refills the room to 1 atm with air. While it runs the regulator stays shut; without power the pumps stop and the room holds as it is (it carries on when the power returns). The pump-down is `advance`'s venting branch to a vacuum with an event at `pT` (one step = many to 1e-6), so a purge under warp or a catch-up lands where a step a second does.

| hut | pump-down | refill | air used | total |
|---|---|---|---|---|
| 17.6 m³ from 1.2 atm of CO₂, one rack | 4.7 min at 2 kW | 70 s | 17.4 of 60 m³ | 5.6 min to breathable |

The 0.01 atm left is ≤ 0.012 atm of CO₂ in the refilled room (under `CO2_MAX`), and a running scrubber takes the rest.

**When it refuses** (`purgeWhy`): no rack in the room, the room not sealed or open to the outside, an airlock (its cycle purges its chamber), no power, or the racks holding less air than the refill takes ("refill them or add a rack"). Never the crew: purging with people inside is allowed; it says "Room 1 has crew in it: the purge pumps their air out. Helmets on." (a big caption, an alarm when the active crew's helmet is off) and runs.

**Where it shows** (each worked out when the panel opens, `purgeInfo`/`purgeLine`):
- the rack's menu: a **Purge** row (the plan: "the room holds the outside's gas: purge it · 4.7 min to pump down (2.0 kW), 70 s to refill · 17 of 60 m³ of air", or PUMPING DOWN while it runs) and the **Purge Room N** switch (its hint the total time; off stops it by hand);
- the terminal's AIR page: the room's row says OUTSIDE GAS or PURGING, and a `[ PURGE ]` key under each sealed room with a rack;
- part_info's Air row: "· PURGING", or "· the outside's gas: purge it at an Air Tank Rack".
- the base log: started (with the warning), purged, stopped.

**Save**: `air.<sid>.purge` = the keys of the rooms being purged (a new session carries on). The arc probe's Shelter step now builds the hut with a rack and purges it (no direct fill).

Tests: `tests/smoke_room_purge.lua` (45: the pure pump-down and plan, a CO₂ world and an N₂ world to breathable in minutes, the crew warned, the grid draw, one step = many, no power, the refusals, stop, save, the rack's menu and the AIR page).

## 37. What a piece carries: the load model (progression W2)

Ty 2026-11-11 on wood: "obviously it shouldn't sustain crazy damage ... on the home planet they'll last forever essentially, just not handle crazy heavy weights." `scripts/kit_load.lua` (pure records half, tested in luajit; a 2 Hz driver on the Build Kit node). Placement is never refused: the load model only ever creaks, sags and breaks.

### Capacity

By how a piece carries (`kindOf`):

| kind | pieces | capacity |
|---|---|---|
| bend | snap `floor` (floors, beams, trusses, decks, roofs); a post or a wall laid flat | a point load at the middle of a clear span L: `cap = S × sec × (2/L)²` kN (L at least 1 m) |
| post | upright posts and pillars | `S × 0.2 × min(1, 3/L)` (a slender post less) |
| wall | upright walls | `S × 1.0` per metre of wall |
| solid | everything else | `S × 4` per m² of footprint |

- `S` is the material's carrying strength, `kit_load.STRENGTH` (not `MATS.strength`, which is a laser's and a joint's): timber 40, steel 600, concrete 1,500, regocrete 1,200, glass 150. `sec` is the piece's section (`kit_load.SEC`): beam2/beam4 0.6, beam6w 1.0, trussW4 2.0, deck24 0.6, floors and roofs 0.3.
- **Worked as moments.** A bending piece's bearings are what it rests on and, when the kit counts it as on the ground (`kit_snap.grounded`: its base within 6 cm of the structure's ground plane), the terrain under it, sampled every 0.5 m along its underside (`terrain.query`, kept 2 s): a beam laid across a dug gap spans the gap. Each span between two bearings (bearing centre to bearing centre) and each overhang past the last one (an overhang `a` counts as a span of `2a`) is asked `M × L / (S × sec × hp)`, with `M` the point loads' moments (`F (s − g0)(g1 − s) / L` in a span, `F × reach` on an overhang) plus its own weight's (`w L²/8`, `w a²/2`); the worst is the piece's `r`. A load right over a bearing bends nothing. A plate (sides within 1.5 of each other) spans whichever way does better. A beam's end against a post or a wall bears on it.
- **Founded pieces carry anything** (r 0, nothing handed on): a pile (`gnd`), a piece on a cast footing (`ft`), and a post, wall or block standing on the ground.
- **cap × hp**: a piece's capacity falls with its hp (the part state `hp`, the field lasers, damage and the Repair Kit use), so a cracked beam carries less.
- Worked numbers (`smoke_kit_load`): a 4 m timber beam on two log posts (3.7 m bearing to bearing) carries 6 kN at its middle: 150 kg r 0.32, 500 kg 0.81, 600 kg 0.95, 1.5 t 2.21, 1.5 t right over a post 0.11. A 4 m steel beam holds 6 t (r 0.57). The smoke's bridge (two 6 m beams across a gap sampled every 0.5 m, three decks, fences; 4.8 m bearing to bearing): a walker 0.48-0.54, the motorcycle (0.3 t with its rider) 0.65, a 450 kg quad 0.76 (creaks), an 850 kg rover over 1, a fuelled hopper (1.5 t) 1.50. In the probe the dug gap is wider (5.28 m bearing to bearing) and the motorcycle reads 0.74: it creaks and holds.

### Loads

- **Dead**: each piece's own weight (9.81 × mass), handed down to its bearings by the lever rule along its span (a post or a wall: by nearness), as one point per piece below at the loads' centroid where they enter it.
- **Live**: 1 kN for a walker on foot standing on a piece (its drawn place against this pass's body: docs/positions-and-frames.md rule 2), and each craft's true mass (`vessel_controller.trueMass`: dry, propellant, hold, crew) shared over its tyres that are down, or (legs, skids, tyres stowed on a parked craft) over its lowest parts within 1.2 m of a piece's top, each share given to the piece under it.
- **When**: at 2 Hz, and only for a load on a piece that is not founded. Only the pieces under the live loads and what rests on them are worked out. Nothing at all runs a frame while nobody is on such a piece; the 2 Hz tick itself is a sphere test per structure and a cell lookup under each walker and craft. kit_snap's graph is kept per `structures.version` (`graphOf` signs every part each call) and the load model (`g.kl`) on it.

### What happens

- **r > 0.7**: it creaks (the Big Wood Creaks recordings, spatial at the piece, every 3.2 s at 0.7 down to 0.8 s at 1.1, louder as r rises; steel groans) and it **sags**: its drawn mesh (the `Mesh` child, and a door's leaves) is lowered along the piece's up by up to min(12 cm, 2 % of its span) at r 1.3 (6 cm at r 1.0 on 6 m), eased in at 6/s, and what rests on it rides down with it by the same lever shares. Its colliders stay put: moving a static body every frame under a rolling tyre threw the probe's motorcycle off the end of the bridge. The engine has no per-instance bend (card draft below), so a sagging piece drops whole.
- **r > 1.0 for 2 s**: its hp falls 0.15 a second (written to the part state in 2 % steps), and splinters tick with each creak. Under 1.0 the 2 s starts again (a tick with no load at all — a parked craft's tyres stowing — runs it down instead); a piece that held keeps the hp it lost.
- **hp 0**: it breaks: a wood crack, chunks (`lasers.throwChunks`), and `kit_snap.fallsWith` takes down what it held (with `base_snap.dependents`); crew on it fall and a craft on it drops (their colliders are gone). Pieces the kit counts as on the ground that have nothing under them any more (`unheld`: no bearing and no terrain within 0.5 m under any of its footprint, `UNHELD_DROP`; a floor standing 0.3 m over a slope is not falling) break at once; what was round a broken piece is looked at for the next 3 s with no load of its own, so a deck left floating over the gap comes down.
- No popup and no caption: the creak and the sag are the warning.

### Tests and probes

- `tests/smoke_kit_load.lua` (53): the formula, the 4 m beam, steel's 6 t, cap × hp, load sums (four posts carry exactly the load, the deck, the beams and themselves), the bridge across a sampled gap (walker quiet, bike holds, a quad creaks, rover and hopper over, the bank takes a load, unbroken ground bends nothing, the decks unheld once the beams are gone), sag/creak/break thresholds and timing, a steel base under crew, a rover and a tonne (worst r 0.10, no sag), a hut's floors and walls, pieceUnder.
- `tools/perf/woodprobe.sh <engine> wood` (29/30 then 30/30 on 0.118.3-dev.1496; its bridge's beams are now sunk 0.35 so the deck stands 5 cm over the banks: the 10 cm lip flipped or stalled the bike in half the runs): the W1 run plus the load checks (the beams' r while the bike is on the bridge, the walker's), a steel floor on four steel pillars walked on, and the bike re-boarded, put back on the run-up, stopped at mid-span and weighed heavier (`kit_load.addMass`, a probe hook: 1.3 t, then 0.7 t more every 6 s until the beams are over 1, since the dug gap's width, 4.3-5.3 m bearing to bearing, differs run to run): over, sag (9.6 cm), creaks, hp falling, a beam breaks about 9 s after going over 1.0, the deck it held goes, the bike drops into the gap. Nothing breaks under the bike, the walker or the hut before that, and a walker on a steel floor on steel pillars reads r 0.006. `kitprobe.sh kitperf`: kit_load 0.005-0.014 ms a frame idle, 500 to 6,000 pieces. `woodlook`: the board look at 1.5, 5, 20 and 60 m, lit and shaded.

### Left for later

- The inspector's LOAD line and the ghost's amber hint (plan §3.4): `kit_load.lastResult(sid)[uid]` has `load` and `cap` for a piece under a live load.
- W3 reads `cap × hp` already: weathering only has to lower hp.
- Engine card draft: per-instance bend of a static instanced mesh (so a beam curves under load instead of dropping whole).
