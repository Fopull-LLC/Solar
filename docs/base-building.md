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
- **Off the home world** (later steps), these rules are already written and
  tested:
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

- **Towers stand 1 km apart along the ground**, the spaceport's Tracking
  Station included (`base_tower.placeWhy`). This is the red ghost's reason:
  "14 m from Far Side's tower: towers stand 1.0 km apart".
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
- **Not modelled:** line losses. A 1.5 km low-voltage run would lose real
  power; the grid treats a cable as lossless.

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
| hab | a ring's end / a top | the next ring (a cap or bulkhead turned to face out) / on the grid |

- **R** turns a quarter, **Shift+R** pitches a quarter (a truss laid down),
  **T** rolls, **PgUp / PgDn** lift a face-snapped piece a storey, **Shift**
  frees it, **Backspace** resets them. `structures.partPose` turns a piece
  in pitch and roll in the engine's own order (yaw, then pitch, then roll).
- **The records rules** (`kit_snap.overlapIn`, `supported`, `fallsWith`):
  a piece may not stand inside another piece of its structure (wall corners
  may share their 0.1 m ends). In Career a piece must be held: on its
  structure's ground, resting on another's top (or a deck), or one module
  beside a held floor. A mount is held by its face. Deconstruct takes what
  is no longer held down with the piece (`fallsWith`), so the wall goes with
  its floor and the light with its wall. Creative (the sandbox save) skips
  the support check.
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

Paint and decals, blueprints in files and the BLUEPRINTS tab, the whole VAB
catalogue in the kit, and bake-when-idle (card 0655). Rooms and air are §14.

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
  short with its battery flat), their draw a grid load. The Oxygen Generator
  has no water feed yet: it runs as if fed (fluids are S7).
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
outside are at about the same pressure and doors open as before.

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
  takes about 25 s. Its menu row reads "depressurising · 0.42 atm".

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
