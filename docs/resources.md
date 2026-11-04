# Resources: what the ground is made of, ore veins, and loose resource bodies

This is the contract between mining (the Terrain Laser, `mineral_field.lua`,
`materials.lua`), felling (`flora_field.lua`) and anything that takes
resources in: the depot, the processing drop-off, a truck's bed, a crane.

Read `docs/positions-and-frames.md` before you keep any position from here.
Every point below is either a node you read now, or body-relative.

## 1. Materials (`scripts/materials.lua`)

One registry, `REG[id] = { name, kg, value, tier, class, grade }`.

- `kg` is per unit and `value` is dollars per unit at reputation 0.
- `class` is `"ore"` for everything dug, including rock and soil, so the depot,
  the fill canister and old contracts treat all dug rock alike. The others are
  `"ice"`, `"flora"`, `"liquid"` and `"refined"`.
- `grade` tells dug things apart: `"bulk"` (rock and soil: the spoil), `"ore"`
  (what veins and deposits hold) or the class for the rest. Use
  `materials.grade(id)` and `materials.isOre(id)`.

| Grade | Ids |
|---|---|
| bulk (rock and soil) | soil, sand, clay, gravel, ash, basalt, granite, sandstone, limestone, shale, slate, rustrock, veinstone, hematite, salt, onyx, regolith |
| ore | iron, copper, sulfur, obsidian, crystal, uranium, silica, geode (Star Geode, registered by research.lua); off-world: ilmenite, he3, kreep, kamacite, sperrylite, monazite, ammonia_ice, clathrate, tholin, phasite, cryovolt |
| flora | timber, fiber, biomass, resin, spores, kelp, glowsap |

Calls: `label(id)`, `kg(id)`, `value(id)`, `massOf(id, n)`, `valueOf(id, n)`,
`hardness(id)`, `grade(id)`, `isOre(id)`, `list()`. For ores: `oreInfo(id)`,
`oreLook(id)`, `bodyOres(body)`, `researchValue(id, origin, first)`,
`originOf(id)` and `codex(id)` (section 6).

## 2. What the laser gives: the material you can see

The terrain palette (`terrain/system.palette`) maps to materials in
`materials.SLOT[slot]`, and `materials.ofSlot(slot)` reads it. Untextured
ground is regolith. The palette and its layers (textures/env/terrain/) are
written by `tools/import_textures.py` from the realistic texture library; each
slot keeps the geology below, whatever photograph it is baked from.

| Slot | Texture | Material |
|---|---|---|
| 1 | rust rock | rustrock |
| 2, 20, 28, 31, 32 | pebbly soil, moss, tundra, peat, leaf litter | soil |
| 3, 9 | flagstone, slate | slate |
| 4 | banded onyx | onyx |
| 5 | veinstone (dark rock, orange seams) | veinstone |
| 6 | magma veins (glow) | uranium |
| 7, 8 | amethyst, blue crystal (faceted geode lining, glow) | crystal |
| 10, 11, 17 | gravel regolith, crater dust, regolith | regolith |
| 12, 22, 23 | banded ice, snow, glacier | ice |
| 13, 29 | basalt, pahoehoe | basalt |
| 14 | granite | granite |
| 15 | sandstone | sandstone |
| 16 | sand | sand |
| 18 | salt | salt |
| 19 | mudcrack | clay |
| 21 | ash | ash |
| 24 | scree | gravel |
| 25 | limestone | limestone |
| 26 | sulfur | sulfur |
| 27 | hematite | hematite (bulk "Hematite Earth") |
| 30 | shale | shale |

How a cut is paid:

1. Each laser bite's receipt (`terrain.dig`) goes to
   `mineral_field.trackDig(id, x, y, z, cid)`.
2. The engine reports what the bite actually removed, by slot, through
   `terrain.yields()`. Only `mineral_field` drains it; no other script may call
   it.
3. Each slot's volume becomes that slot's material. Inside a painted vein, the
   vein's slot is the vein's ore. Inside a geode pocket, the whole cut is Star
   Geode.
4. Volume becomes units: `params.dig_unit` m³ per unit (30), and ore takes 0.4 of
   that. The remainder carries over between bites.

The reticle shows the same answer, from `mineral_field.materialAt(x, y, z)`
(material, depth, isOre).

`materialAt` reads `terrain.slotAt`, which sees paint and paintTexture from
the next call on (engine card 0602, 0.117.1-dev.1385 and later). A vein's
slot is that vein's ore on its world (`oreSlots`), so the reticle and the
payout (`terrain.yields`) give the same answer.

The laser's bite and bore are divided by `materials.hardness(mat)`. Soil is
about 0.7, rock 1.0–1.2, ore 1.3–1.55 and crystal 1.65, so cutting into a
vein is felt as the beam slows.

Surface rocks (`mineral_field` scatter) break into the rock they lie on:
stones and boulders are the bedrock slot a few metres under them
(`mineral_field.rockMat`), gravel is gravel and crystal outcrops are crystal.

## 3. Ore veins (`scripts/mineral_field.lua`, "ore veins")

Ore is underground. Most veins are buried and you find them by digging or
caving. Only some of the common ores crop out at the surface, and the rarer
an ore, the deeper it lies.

- **Layout.** About `vein_rate` (6) veins per patch, laid out from the world
  seed and the patch. Which ores at all is the world's own makeup
  (`materials.bodyOres`, section 6).
  - `vein_surface` (0.2) of the veins crop out. These are picked only among
    ores with `surface = true`, the common ones.
  - The rest are buried 4–46 m down, biased shallow, and picked by
    `materials.pickVeinOre`: an ore lies only inside its
    `minDepth`–`maxDepth` band, and rarer ores weigh more the deeper the vein.
    A buried vein is 10–26 m long and dips along its strike, so one end can
    lie much nearer the surface, but never closer than 3 m.
- **Slot.** Each vein is painted in its ore's own slot
  (`materials.VEIN_SLOTS`). The slot is chosen once per world (the first slot
  neither the world's ground nor another ore uses; `veinslots.<body>`). The
  save records it as `veins2.<body>.<patch>` = `{ p = { v<i> = slot }, t = {
  v<i> = outcrops broken (bits) }, h = { v<i> = 1 } }`. `-1` means every slot
  the ore could wear is the world's own ground: the vein still pays by its
  geometry, it just isn't painted. A v1 save's seams stay in the ground as
  they were painted and still pay by their slot.
- **Surfaced veins** are painted once, when someone comes within
  `vein_paint` m (`h` set).
  - The core is painted at least 1.7 m wide (`seam_r`), because the ground
    meshes at 1.5–2.4 m voxels.
  - It carries a stain and float (below) and outcrops: model nodes (tag
    `ore_outcrop`) within `vein_show` m, up to `outcrop_max`. A cut within 1 m
    of an outcrop breaks it out: 2 units of the ore and a loose chunk.
- **Buried veins** have nothing standing over them. They are painted lazily
  and only where something has opened onto them:
  - when you come within `vein_cave` m, where a cave already runs through
    the vein;
  - after every laser bite that cuts into the vein, around the bite
    (`vein_reveal`), so the tunnel walls show the seam.
  
  Only ground near an open face takes paint, and asking the engine to paint a
  ball inside solid rock still makes it build those voxels. So each ball is
  kept only where `terrain.query` finds a face within its radius. Repainting a
  wall inside the vein is correct: that rock is the vein.
- **Payout and reticle.** A bite inside a vein's rock pays the plain rock it
  removed as the vein's ore: all of it inside the core, half at the edge.
  Voxels already painted pay by their slot. `materialAt` (the reticle) reads
  the slot (`terrain.slotAt` sees paint since engine 0602), and where that is
  plain rock, the vein's geometry, so a buried vein reads as ore before any
  cut has opened it.
- **Kept off the base.** No seam ball, stain ball or outcrop lands on the
  base's paving, pad or lots (`base_facilities.keepClear`, the same test the
  rocks and float use).
  - A ball is dropped when its centre or any of eight points around it is
    kept clear, measured at the radius it shows over: a slot ball over its
    whole radius, a colour ball over 0.7 of it.
  - The plan is `mineral_field.seamPlan(ore, g, slot, clear, opts)`, a pure
    function the smoke test checks.
  - Paint an older save already laid onto paving is left as it is.
- **How a surfaced seam reads at eye level:**
  - the core, in the ore's slot, recoloured dark (`ORE[id].look.seam`);
  - a stain bled into the ground around it and on past both ends along the
    strike (`look.stain`). It is a colour paint only, so the host rock keeps
    its texture. A soft colour brush reads over only about 0.4 of its radius
    on 0.117.1, so the radii are large;
  - **float**: broken bits of the ore along the seam (`look.float`). Two
    GPU-instanced scatter sources per vein within `float_show` m, on a small
    Ground region whose density grid is the seam's line, kept off the base.
    Float is decoration only. `vein_float` scales it, and 0 turns it off.
- **Queries:**
  - `mineral_field.veinAt(x, y, z)` returns the vein a world point lies in,
    buried or not;
  - `veinsNear(x, y, z, r)` lists the veins near a point, with `buried` and
    `depth`, for probes and readouts.

## 4. Loose resource bodies: the physical item format

Logs, chunks knocked loose by the laser, and rocks plucked with the gravity gun
are dynamic bodies (assemblies) that stay where they lie. You can carry them
with the gravity gun, load them on a truck and drop them at the depot.

**Prefabs** (`tools/gen_props.py`): `LooseLog` (tag `log`), `LooseRock`
(tag `loose_rock`), `LooseBoulder` (tag `boulder`) and `LooseCrystal` (tag
`crystal`).

**Tags.** Every resource body carries:

| Tag | Meaning |
|---|---|
| `resource` | It is a resource body. Find them all with `findTagged("resource")`. |
| `mat:<id>` | Its material, an id of `materials.REG` (`mat:timber`, `mat:granite`, `mat:iron` …). |
| `qty:<n>` | Whole units of that material. |

The prefab's own kind tag (`log`, `loose_rock`, `boulder`, `crystal`) is kept
alongside.

**Reading one.** Read a body through `materials.resourceOf(node)`:

```lua
local mats = findScript("materials")
for _, n in ipairs(findTagged("resource")) do
  local r = mats.resourceOf(n)
  -- r = { mat = "timber", qty = 12, name = "Timber", kg = 14.4, value = 48,
  --       grade = "flora", kind = "log" }
end
```

`value` is a hint: the depot's base price for the lot at reputation 0. The
depot applies standing and the one-off discovery premium itself, so price a
lot by `mat` and `qty` through `materials.valueOf` and the company's rules,
not by `value`. `kg` is the material's mass, not the body's physics mass. The
body's physics mass is `assembly.info(n).mass`, in tonnes.

**Making one.** Spawn the prefab, then in the spawn callback call
`findScript("mineral_field").adoptBody(n, prefabName, mat, qty, scale)`. That
tags it (`materials.tagResource`) and keeps it in the save. To tag a body
without keeping it in the save, call `materials.tagResource(n, mat, qty)`.

**Taking one in.** Read `resourceOf`, credit it, then `n:destroy()`. The
registry notices the node is gone. A script's handle is reused by the next
node spawned (engine card 0552), so check `n.valid` and the node's name
before you act on a handle you kept.

**Persistence.**
- Every 2 s the save key `loose.bodies` is rewritten: `{ { b = body, pf =
  prefab, x, y, z (body-relative), m = mat, q = qty, s = scale } }`.
- When you come back to a world (a load, a scene hop, a flight home), its
  bodies are spawned again once the ground under each one is made.

**Caps.** At most `mineral_field.LOOSE_MAX` (32) bodies are kept, and the
oldest goes first. The laser keeps `rocks_max` chunks (tool_belt) and felling
keeps 16 log sections (flora_field `LOG_MAX`).

**How much a felled tree leaves.** A tree leaves one 3 m section per ~4.5 m
of height, up to four. Each is scaled 0.6–1.6 to the tree and is worth
`3·scale³` timber.

## 5. Star Geodes

Only resonant crystal out of the deep rock counts
(`missions.geodeFind(body, mat, n, depth, src)`), and the source must be one
of:

- `"pocket"`: volume cut out of a geode pocket (`rare.<body>.ores`, the
  resonance ring);
- `"deposit"`: crystal-slot rock that the generator laid, cut out under at
  least `GEODE_DEPTH` (3 m) of ground, outside the surface veins. The depth is
  read from the terrain's own field, so a tree, a roof or the crew over the
  cut does not count as rock.

Plants, plucked or broken outcrops, surface veins and callers that give no
source are refused.

## 6. Ores by world, research and the codex (`scripts/materials.lua`)

**Each world has its own ores.** `bodyOres(name)` returns `{ { mat, w } … },
total`. It is read from the world's makeup, `bodyTraits(name)` = `{ home,
moon, airless, temp, dense, type, family }`. The traits come from the world
record (`world.<name>`: geo type, family, air, climate temperature) and the
system roster (`system.home`: parent and µ/r³ against the system's middle
body). Rules:

| World | Ores |
|---|---|
| home | iron, copper, sulfur (more on dune or lava), obsidian (lava), crystal and uranite deep |
| cold (frost/ice family, glacial, titan) | ammonia ice, methane clathrate; with air (titan): tholin tar, cryovolt glass; airless: kamacite |
| airless rock (moons, cratered regolith, maria) | ilmenite (most on maria), helium-3 regolith, kamacite, KREEP basalt |
| other planets with air | iron, copper, monazite; lava: sulfur, obsidian, uranite; dune: sulfur; crystal: resonant crystal, phasite |
| dense (over 1.25× the system's middle density), not home | kamacite and sperrylite added |

Weights vary per world (seeded), so two maria moons hold the same ores in
different measure. A world with no record (scale 1, a test) falls back on
its archetype's `BANDS` (`veinOres`).

**An ore's entry**, `ORE[id]`:
- `minDepth` and `maxDepth`: the band of depths its veins lie in. Helium-3
  stays in the top 5 m, where the solar wind put it.
- `surface`: whether it may crop out (only common ores do).
- `rarity`, from 1 to 5.
- `research`: base points, by rarity `RESEARCH_BY_RARITY` = 4, 10, 25, 60, 140.
- `look`: `seam`, `stain`, `float` and `out` (the outcrop's model, tint and
  glow).

Each also has a `REG` entry (value, mass, tier), a `HARD` hardness and
`VEIN_SLOTS`.

**Origin.** `noteOrigin(mat, body)` records the first world an ore was mined
on (`ore.origin` = `{ [mat] = body }`). `mineral_field` calls it on every ore
payout and broken outcrop, and `originOf(mat)` reads it back. A loose
resource body carries the world it came from as an `origin:<body>` tag
(`tagResource(n, mat, qty, extra, origin)`). `resourceOf` returns `origin` and
`research` (the lot's points).

**Research.** `researchValue(mat, originBody, firstTime)` is the points one
unit is worth to the lab:
- the ore's base points;
- ×3 when `originBody` (default `originOf(mat)`) is not the home world;
- ×5 more when `firstTime` (the lab knows whether the kind has been brought
  home before).

Bulk rock is worth 0, and other materials 1 point per tier. The lab and its
research-points stat belong to another script and read only this number.

**Codex.** The lab's codex is `scripts/codex.lua`: `CODEX`, `entry(id)` and
"the rules of this universe" that every fictional entry keeps to. It holds
the home materials.
- The off-world ores' entries live in `materials.ORE_CODEX`, in the same shape
  `{ name, summary, facts, fictional }`.
- `materials.codex(mat)` answers from the codex first, then from
  `ORE_CODEX`. `materials.codexInto(cx)` copies the ore entries into a codex
  that lacks them.
- Real minerals carry real facts: where they occur, how they are refined,
  what spacecraft do with them, and missions.
- Phasite and cryovolt glass are fictional, flagged `fictional = true`. They
  keep to codex.lua's rules: Vey's law, sympathy and phase density.
