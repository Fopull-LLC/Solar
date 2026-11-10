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
| hab | a ring's end / a top | the next ring (a cap or bulkhead turned to face out) / on the grid |

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
- **Burnt through:** a cable with no breaker at either end driven past 125 %
  of its rating burns through at the start of that slot. It carries nothing
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
  of a CO₂ world's air; venting it to the chamber's receiver and refilling it
  from an Air Tank Rack or an N₂ Compressor plus an O₂ source is quicker.

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
