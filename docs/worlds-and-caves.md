# Worlds and caves: what planets are made of

The plan behind this is `work/worlds/PLAN.md` (the worlds planner, 2026-11-10). This doc holds
what has shipped. Section 1 is the geology provinces (slice W2). Cave kinds (W4) and their hooks
will get their own sections when they land.

## 1. Geology provinces (material generation 3)

Ty (2026-11-10): "planets are kind of just made of only a few materials … caves all made of the
same few rocks and formations so it gets boring fast."

### 1.1 Formations

`scripts/geology.lua` is pure: the luajit tests load it from disk, and in the game it is a script
on the System Generator node. For each of the 18 world types it holds two or three
**formations**. A formation is a named stack, the rock you would see in a road cut, a ravine
wall and a cave on that kind of world. It has these fields:

| Field | Meaning | Generator 4 mapping |
|---|---|---|
| `high` / `low` / `patch` | an optional surface layer that replaces the type's own (keeping the colour the type rolled) | `surfaceA` / `surfaceB` / ice caps |
| `subsoil` | the loose layer and its thickness range `d` | `subsoil`, `subsoilDepth` |
| `strata` | the sedimentary record, with a thickness range | `strata`, `strataDepth` |
| `cave` | the rock the cave zone is cut through | `deep` (the engine paints it below caveDepth/2) |
| `deep` | the basement | published only; generator 5 will paint it below the caves |
| `cliff` | the rock on steep faces | the type's first slope rule |
| `band` | the rock on the lower part of steep faces | a slope rule limited by altitude, placed before the cliff rule |
| `pocket`, `seam` | optional deposits (quartz druzy, a hematite, gossan or sulfur seam) | `pockets`, `seam` (worlds without glow only) |
| `hue`, `sat` | the rock tint ranges | `M()` colours |

Examples: a canyon world is red beds, a shale and limestone stack, or conglomerate and tuff. A
volcanic world is pahoehoe and a'a, columnar basalt, or tuff and scoria. A glacial world is clear
ice over basalt, firn over granite, or dirty ice over regolith. The full table is in the file.

The band rule runs from the sea, or from −0.3 of the relief where there is no sea, up to 30 % of
the relief (mountains included). So a ravine wall or a mesa skirt shows the band rock under the
cliff rock: two rocks, a cross-section.

The subsoil thickness only takes effect above the generator's floor (`geoOpts3`: at least two
voxels, and one voxel past the overhangs' reach). Without the floor, the layer underneath would
show through undug ground. So "thin regolith" still means about 3 m.

### 1.2 Versioning and the rng

- `MAT_GEN = 3`. It is written into fresh saves as `g_matGen`. A save with 1 or 2 keeps its
  tables, and its version-2 roll is byte-identical to before (checked against the old generator
  over 200 rolls).
- Version 3 consumes **exactly the draws version 2 did** (`rollFormation`): the three picks
  become uniform draws, the same pass of the stream. The formation comes from the strata pick.
  Where that draw fell inside the formation's share picks the strata. The deep-sat draw becomes
  the weathering, which darkens and greys the rock. The two thickness draws map into the
  formation's ranges. The band paint in `geoOpts3` keeps its four `q` draws. The home world and
  the alien home roll the same way.
- `tests/smoke_geology.lua` checks this two ways. Every type's roll leaves the stream where
  version 2 left it. Over 50 seeds, versions 2 and 3 roll identical bodies, orbits, air, seas,
  relief layers, caves and seeds. Only paint differs.

### 1.3 The palette: 24 fixed slots, 8 wildcards

The scene palette has 32 slots shared by every planet. Engine slot-materials stage 5 will give
each terrain its own palette. Until then:

- Eight slots are **wildcards** (`geology.WILD`): 4 onyx, 10 gravel regolith, 11 dust, 12 banded
  ice, 21 ash, 29 pahoehoe, 31 peat and 32 litter. These are the least central layers, and none
  of them has a commercial `local=` version. Their `terrain/system.palette` lines keep their
  flags and their own height map but name no picture, normal or ORM. `tools/import_textures.py`
  writes them that way (`WILDCARD_SLOTS`; keep it in step with `geology.WILD`).
- Each **star system's roll** decides which library layer each wildcard holds:
  - World paints carry a layer (`lib`) until the world's opts are done. `commit()` then claims
    the slots in roll order (home first). Old wildcard layers take their own slot first; a new
    layer then takes a free wildcard of its class (rock, loose or ice), then any free wildcard.
  - A layer that finds no free wildcard falls back to a fixed look-alike
    (`geology.FALLBACK`).
  - A wildcard that nobody claims keeps its own layer.
  - Neighbour systems built later read the home assignment, frozen.
- `system_generator.publishPalette` publishes the assignment to the save as `system.palette`
  (`layer`, `mat`, `wild`). It hands the same table to `materials.setPalette` (what a dig of a
  slot pays, and `VEIN_SLOTS` without wildcards that changed their look) and to
  `far_bodies.setPalette` (a slot's mean colour, from `LIB_PAL`).
- `applyPalette` hands the engine each wildcard's picture, normal map and ORM
  (`terrain.setSlotMaterial`). It is called from `regenerate` only, at the loading screen before
  the first world draws, because an editor Generate would save slot Materials into the scene. A
  pre-version-3 save gets every wildcard's own layer back.
- The engine takes a slot's height map only from its palette line (W0 finding (c)). So a wildcard
  holding a new layer blends at borders using its slot's old height map. The look is unchanged
  for old saves and is acceptable for new layers. Card note: `heightMap` in `setSlotMaterial`.

### 1.4 What the world record gains (version 3 only)

- `bio.mats.cliff`, `.band` and `.cave` (cave equals `deep`). `mineral_field` reserves these
  slots, so veins never paint into them.
- `bio.mats.pocket` and `.seam` are deposits. `mineral_field.worldReserved` skips them, so a
  copper vein may still lie in veinstone.
- `bio.formation = { id, label, weather, subsoilDepth, strataDepth, layers = { subsoil, strata,
  deep, cave, cliff, band, pocket, seam } }`: the library layer of each part, even where its slot
  fell back. W3 (ores), W4 (cave kinds) and W7 (generator 5 strata) read it.
- `bio.palette.cliff` is the cliff rock's tint.

A version-2 world publishes none of these keys, so its vein-slot choices do not move.

### 1.5 Cost

All of this runs at generation time:

- 0 ms per frame.
- 8 `setSlotMaterial` calls at load. W0 measured 12 calls at 0.04 ms of Lua, with the pictures
  read in the background.
- 0 extra GPU memory: the palette is a fixed 96-layer array.

### 1.6 Probes

`GEO=1 tools/perf/alienprobe.sh <engine> after <tag> canyon:1,volcanic:1,…` rolls each entry as the
first world of its system at material generation 3 (`MATGEN=2` gives the same world as it was),
gives the probe its palette, and with `AP_PARAMS='("pit", 1.0)'` digs a 10 m pit and shoots its
rim and wall plus the steepest face 30 m off (`_pitrim`, `_pitwall`, `_cliff`).
