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
| ore | iron, copper, sulfur, obsidian, crystal, uranium, silica, geode (Star Geode, registered by research.lua) |
| flora | timber, fiber, biomass, resin, spores, kelp, glowsap |

Calls: `label(id)`, `kg(id)`, `value(id)`, `massOf(id, n)`, `valueOf(id, n)`,
`hardness(id)`, `grade(id)`, `isOre(id)`, `list()`.

## 2. What the laser gives: the material you can see

The terrain palette (`terrain/system.palette`) maps to materials in
`materials.SLOT[slot]`, and `materials.ofSlot(slot)` reads it. Untextured
ground is regolith.

| Slot | Texture | Material |
|---|---|---|
| 1 | rust rock | rustrock |
| 2, 20, 28, 31, 32 | purple dirt, moss, tundra, peat, leaf litter | soil |
| 3, 9 | slate | slate |
| 4 | banded onyx | onyx |
| 5 | orange veinstone | veinstone |
| 6 | magma veins (glow) | uranium |
| 7, 8 | amethyst, blue crystal (glow) | crystal |
| 10, 11, 17 | regolith, crater dust | regolith |
| 12, 22, 23 | teal ice, snow, glacier | ice |
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

On engine 0.117.1, `terrain.slotAt` cannot see paint. It reads the physics
copy of the field, which a paint op does not refresh (an engine card draft
covers this). So `materialAt` finds a painted seam by its geometry
(`veinAt`), while the payout uses `terrain.yields`, which does see the paint.

The laser's bite and bore are divided by `materials.hardness(mat)`. Soil is
about 0.7, rock 1.0–1.2, ore 1.3–1.55 and crystal 1.65, so cutting into a
vein is felt as the beam slows.

Surface rocks (`mineral_field` scatter) break into the rock they lie on:
stones and boulders are the bedrock slot a few metres under them
(`mineral_field.rockMat`), gravel is gravel and crystal outcrops are crystal.

## 3. Ore veins (`scripts/mineral_field.lua`, "ore veins")

- **Layout.** A few veins per patch (`vein_rate`, default 2.2), laid out from
  the world seed and the patch. Which ores a world carries comes from
  `materials.veinOres(kind)`: the archetype's `BANDS`, without the bulk
  fillers.
- **Paint.** Each vein is a seam painted in the ore's own slot
  (`materials.VEIN_SLOTS`: hematite for iron, veinstone for copper, sulfur,
  amethyst or blue crystal, magma for uranite). The seam runs 3–15 m along a
  wandering strike and its lens reaches about 2.5 widths down. It is painted
  once, when someone comes within `vein_paint` m. The core is painted at
  least 1.7 m wide (`seam_r`), since the ground meshes at 1.5–2.4 m voxels and
  anything narrower vanishes. The save records this as
  `veins1.<body>.<patch>` = `{ p = { v<i> = slot }, t = { v<i> = outcrops
  broken (bits) }, h = { v<i> = 1 } }`.
- **How it reads at eye level.** Three layers, all made once or instanced:
  - the core, in the ore's slot, recoloured dark in the ore's colour
    (`SEAM_COLOUR`);
  - a stain bled into the ground round it and on past both ends along the
    strike (`STAIN_COLOUR`: an iron gossan's rust, copper's green, sulfur's
    yellow). It is a colour paint only, so the host keeps its texture. A soft
    colour brush reads over only about 0.4 of its radius on 0.117.1, so the
    radii are large. A seam painted before the stain existed (`p` set, `h`
    not) gets the stain and core colour once, colour only, so a dug-out
    seam's tunnel walls are tinted but never turned back into ore;
  - **float**: broken bits of the ore strewn along the seam and just past it.
    Two GPU-instanced scatter sources per vein within `float_show` m (grit and
    fragments, drawn to 45 and 70 m), on a small Ground region round the seam
    whose density grid is the seam's own line. They are kept off the base's
    paving and lots, and tinted by `FLOAT_COLOUR`. Float is decoration only:
    it doesn't break for ore, but the seam under it does. `vein_float` scales
    how thickly it lies, and 0 turns it off.
- **Outcrops.** Model nodes under the planet (tag `ore_outcrop`) stand along
  the seam within `vein_show` m, up to `outcrop_max` at once. A cut within 1 m
  of an outcrop breaks it out: 2 units of the ore, and a chunk body is knocked
  loose.
- **Queries:**
  - `mineral_field.veinAt(x, y, z)` returns the vein a world point lies in;
  - `veinsNear(x, y, z, r)` lists the veins near a point, for probes and
    readouts.

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
