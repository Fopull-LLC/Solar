# Base building: the Engineer's Build Kit

This is the field version of the VAB. You stand in the world and the ground is
the craft: the same parts column, a ghost of the part under the cursor, and a
click to buy it, ship it out and set it down. This doc covers **deep-space
steps 4 and 5**: addendum items K1–K10, K13 and N1. Step 4 opened the kit and
placed single parts; step 5 (§7) snaps parts to each other, lays them on a
grid, levels the ground and casts footings, judges every placement in full,
keeps an undo ring and takes parts down for a refund. Steps 6–8 (stands, the
tower, the base grid) build on the hooks named at the end.

Read `docs/positions-and-frames.md` first. Everything here is kept in a body's
frame.

## 1. Who can build, and how it opens

- **The Build Kit** (`items.lua` `buildkit`) is a field tablet in a hard carry
  frame: 1.6 kg, 3 L, carried by its handle (grip `left`). It is a `device`, so
  it sits on the belt after the tools.
- **Issue.** Every Engineer gets one Build Kit, once per member.
  `field_builder.issue_tick` checks every 3 s and stamps
  `inv.issued.buildkit.<cid>`. That covers hires, retrains and old saves. It is
  not part of the standard `issue` (that goes to everyone), and it isn't sold
  yet. The Depot stocks it once the 10 % coverage unlock lands (M3, step 7).
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
  - **Doors are closed.** Nobody walks inside a placed module before EN1/EN2,
    and there are no kinematic interior fakes.

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
                         ft = { d, hx, hz } } },                                -- step 5: a footing
                st = { [uid] = {} }, paid = { … the founding part's … } }
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

## 8. Hooks for step 6 (L1–L2, L4: craft stands)

- **A stand is a BASE part with a deck and a height** (L1). It can be another
  `tile` (stands edge to edge) or `deck` part in `parts_base`, which gets
  snapping, footings, the ring and deconstruct for free. Its height (L1's
  slider) is a per-part `bp` field like `ft`.
- **`field_builder.place(sid, partId, pose, payer)`** takes `pose.lx/ly/lz/yaw`
  in a structure's frame. A craft under construction (L2) can be a structure
  part whose `st[uid]` holds the blueprint.
- **`structures.partOfNode` / `nodeOf` / `partsNear`** are the lookups a
  stand's "build here" needs.
- **`placement.overlapObb`** becomes EN12's one call; `ghost.apply` becomes
  EN10's.
- **Open from step 5:**
  - the mineral-vein keep-out;
  - pitch and roll for parts that may lie down;
  - a "crew in the footprint" check, which only covers bodies with colliders
    (`overlapObb` sees the Astronaut and CrewBody capsules);
  - the depot stocking the kit (M3).
- **Machines and power (M6, N4):** a structure whose parts carry electronics
  becomes an anchored assembly with a 10 Hz power step. Static prefabs stay
  for slabs and sheds.
