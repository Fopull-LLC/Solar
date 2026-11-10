# Worlds and caves: what planets are made of

The plan behind this is `work/worlds/PLAN.md` (the worlds planner, 2026-11-10). This doc holds
what has shipped. Section 1 is the geology provinces (slice W2), section 2 the ores and crystals
(slice W3). Cave kinds (W4) and their hooks will get their own sections when they land.

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

## 2. Ores and crystals that look like their minerals (material generation 4)

Slice W3 (`work/worlds/PLAN.md` §3.4, §5.1). Every ore reads as the mineral it is, realistic
except the declared fictions (Resonant Crystal, phasite, cryovolt glass), which alone glow. Only
magma glows otherwise, and only because it is hot.

### 2.1 Version 4

`MAT_GEN = 4` (`system_generator.lua`). Version 4 rolls exactly what version 3 rolls: the same
draws, shapes, seas, caves and formations (`smoke_geology`: 30/30 seeds equal). What changes:

- **Slot 6 pays magma rock** (`materials.REG.magma`, bulk, 2.7 kg/L, $3), not uranite. The slot
  keeps its glowing magma picture: the hot worlds' magma pockets and seams and every world's
  core paint.
- **Uranite is pitchblende**: black, pitchy, botryoidal, with an autunite-yellow stain. It does
  not glow; the dosimeter finds it (§2.5).
- **Galena** (`materials.REG.galena`, lead-zinc ore, 5.0 kg/L, $30, tier 2) is a new ore id with
  library layer 61. A renamed off-world ore would have kept the id count down, but it would also
  have changed what every save's existing stock of that ore *is*, so it is a new id.
- The wildcards no world claimed go to **ore layers** (§2.2).
- Each world's ores follow its **formation** (§2.3).

A save made before keeps version 3 (`g_matGen` is written once, for fresh saves only). Its
published palette says `gen = 3`, and `materials.setPalette` then gives slot 6 back to uranite and
uranite's veins their old slot 6 (`VEIN_LEGACY`). `bodyOres` adds nothing (`oreGen4()` is false),
so every vein is laid with the ore it always had. A vein an old save painted in slot 6 is recorded
in `veinslots.<body>` and pays uranite on that world whatever the generation
(`mineral_field.slotMaterial`). No deposit is lost.

### 2.2 Ore layers in the palette

`geology.ORE_LAYERS`: uranite → pitchblende (43), galena → galena (61), sulfur → native sulfur
vein (59), obsidian → obsidian glass (48). `materials.ORE_LAYERS` holds the same numbers.

- **Pitchblende is reserved**: at version 4, `regenerate` gives it a wildcard before any world
  claims ground (`geology.reserveOres`). Every home world carries uranite, and a black vein in
  borrowed slate reads as slate. It costs the system's last-rolled world a look-alike fallback,
  typically a moon's: 4.0 → 4.9 fallbacks per system, while the home world keeps every layer it
  names (`smoke_geology`).
- The **others take leftovers**: after the home system's worlds have claimed their ground,
  `publishPalette` hands the free wildcards (`Assign:claimFree`, never displacing, never falling
  back) to galena, sulfur and obsidian, for the ores the system's worlds carry
  (`system_generator.oreNeeds`). Over 30 seeds: galena 3, sulfur 2, obsidian 7 systems.
- `materials.setPalette` puts an ore's own layer first in its `VEIN_SLOTS` where the palette holds
  it. Elsewhere a vein is painted in a fixed look-alike and recoloured to its mineral (uranite in
  slate, basalt or flagstone; galena in flagstone, slate or granite).
- `materials.veinSlots(ore)` reads the save's palette first, so an old save's uranite gets slot 6
  even before the generator republishes. `mineral_field.vein_slot` uses it.

### 2.3 Ores reconciled with the formation

W2's formations named deposits that the ore table did not know about: quartz druzy pockets (paying
silica), hematite, gossan and sulfur-vein seams (replacing the copper veinstone seam), and obsidian
as a band rock. At version 4, `materials.bodyOres` reads the world's `bio.formation.layers`
through `LAYER_ORE` (`formationOres`):

- A deposit layer is its ore: a hematite or gossan seam means iron, a sulfur-vein seam or band
  means sulfur, an obsidian band means obsidian.
- The country rock carries the ores that form in it: galena in limestone, chalk, marble, cave
  limestone and shales (Mississippi-Valley type); uranite in granite, gneiss and red-bed sandstone
  (roll fronts); copper in basalt.
- A cold or airless body keeps its own ices and impact metals.
- The home world adds galena (0.7) beside its iron, copper, sulfur, crystal and uranite.

The deposits' own materials are unchanged: a quartz-druzy pocket pays silica, a hematite or
gossan seam pays hematite earth, and a sulfur-vein seam pays sulfur. A hematite seam that an iron
vein also uses pays iron on that world (`veinslots`).

### 2.4 The looks (`materials.ORE[*].look`, `mineral_field`)

| Ore | Vein slot (layer first) | Seam / stain | Outcrop | Float |
|---|---|---|---|---|
| iron | hematite 27 | rust black / ochre-red gossan stain | rusted boulder | red scree (stone) |
| copper | veinstone 5 | verdigris / green wash | green-stained stone | malachite chips (nodule) |
| sulfur | sulfur vein 59, sulfur 26 | yellow / pale efflorescence | crust slab | yellow crust flakes |
| obsidian | obsidian 48, onyx 4, basalt 13 | glass black / grey | glass blades (rough 0.12) | blades (shard) |
| galena | galena 61, flagstone 3, slate 9 | lead grey / grey-white | metallic cubes | little cubes |
| uranite | pitchblende 43, slate 9, basalt 13 | pitch black / autunite lemon-green | black botryoidal nodules, cluster | nodules |
| crystal | amethyst 7, blue crystal 8 | the world's crystal hue | glowing crystal cluster | crystals |
| ilmenite | basalt 13 … | black | dark boulder | platy blades (shard) |
| kamacite | slate 9 … | steel / rust | metallic nodules | nodules |
| sperrylite | slate 9 … | tin white | metallic cubes | cubes |
| tholin, clathrate | peat 31 / glacier 23 … | orange-brown / white | crust slab | crust flakes |

- `look.fk` names the float's shape (`mineral_field.FLOAT_MODELS`: stone, nodule, shard, crust,
  cube, gem). `mineral_field.floatKindOf(ore)` and `oreLookOf(ore)` gather it all.
  `OUT_LOOK`, `SEAM_COLOUR`, `STAIN_COLOUR`, `FLOAT_COLOUR` and `FLOAT_KIND` hold the home ores'
  own looks as fallbacks behind the registry's.
- The new rock models, `tools/gen_flora.py write_minerals` (`python3 tools/gen_flora.py minerals`):
  - `rock_nodule`: botryoidal lobes, 814/250 triangles.
  - `rock_shard`: plane-broken glass blades, flat-shaded, 602/170.
  - `rock_crust`: a blistered plate with a broken edge, 548/128.
  - `rock_cube`: interpenetrating cubes on a matrix, 266/170.
  - They share one neutral mineral picture (`textures/flora/rock_mineral_{l0,n,mr}.png`),
    box-projected at 2.5 repeats a metre. Its mean is 0.80, not the rocks' 0.42: a node or
    scatter tint only multiplies (it is clamped at 1), so on the rock picture sulfur yellow or
    clathrate white could never come out brighter than mid-grey. `mineral_field.neutralOf(model)`
    gives the neutral a model's tint is worked out against (`MINERAL_NEUTRAL` 0.80 or
    `ROCK_NEUTRAL` 0.42).
- Library layer 61 `galena`: `tools/import_textures.py make_galena` (CC0 Rock051 limestone host;
  lead-grey cubes, each a turned square with a lit top and two side strips, sphalerite between,
  calcite rims). It is stamped by its own code (`OWN_HASH`), so adding it re-bakes nothing else.
- Codex: galena (`materials.ORE_CODEX`); pitchblende facts in uranite's entry; magma rock
  (`codex.lua`).

Open question: in the veinlook pictures, outcrop and float tints barely show. A sulfur slab or a
pitchblende nodule renders sky-lit blue-grey, and this happens on the old rock model too. The
seams, stains and paint carry the looks. The probe's `vl_nofloat`, `vl_mat` and `vl_oldmodel`
switches reproduce it (`work/worlds_w3/NOTES.md`).

### 2.5 The dosimeter

`mineral_field` samples a ground-gamma reading with its 0.2 s tick (no per-frame work): `dose`
(µSv/h), `doseOre` (the veins' share), `doseRising` and `doseT`. The reading is a background of
0.12 µSv/h plus each radioactive vein's share, `DOSE_A · k · min(1.5, width/2) · e^(-d/4.5 m)`,
where `d` is the distance to the vein's line. `k` is 1 for uranite, 0.06 for monazite and 0.03
for KREEP; `DOSE_A` is 28 µSv/h.

Real gamma is stopped by a metre of rock. The 4.5 m length stands for the radon that seeps up
fractures from a uranium body, which carries its signal further. At the face of a rich vein the
reading is about 28 µSv/h, a few hundred times background. From the surface over a vein 20 m down
it is a faint rise of about 0.3 µSv/h; at 45 m it is nothing.

`status_hud` shows a **Dose** chip while the veins' share is at least 0.15 µSv/h: `0.84 µSv/h ▲`,
in caution yellow from 2.5 µSv/h. `mineral_field.doseAt(x, y, z)` is for probes. The radiation
does not harm the crew yet: that is W5.

### 2.6 Probes

`tools/perf/veinlook.sh <engine>` (`veinlook_modes.lua`, with `WORK` and `LOCK` as for `bench.sh`)
starts a fresh save. It lays every ore in `ores` (a string param; default the home ores and five off-world
ones) as a 12 m seam on a 260 m ring round the base, painted as `mineral_field` paints one, with
its outcrops and float. It shoots each one from 5 m and 20 m at eye height and from 60 m at 4 m
(`veinlook_<ore>_{5m,20m,60m}.png`). It then walks out to a real uranite vein and reads the
dosimeter over it, 15 m off and 40 m off.
