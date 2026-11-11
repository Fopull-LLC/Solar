# Worlds and caves: what planets are made of

The plan behind this is `work/worlds/PLAN.md` (the worlds planner, 2026-11-10). This doc holds
what has shipped. Section 1 is the geology provinces (slice W2), section 2 the ores and crystals
(slice W3), section 3 the cave kinds and their dressing (slice W4).

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

## 3. Cave kinds and their dressing (material generation 5)

Ty (2026-11-10): "I dig and find cool caves but they're all made of the same few rocks and
formations so it gets boring fast... make more scary feeling and unique caves." Generator 4 cuts
every cave with one recipe. Until generator 5 (engine card 0676) gives each kind its own shape,
a cave's **kind** is what Solar makes of it: its walls, what hangs from its roof and stands on
its floor, its marks, its darkness, haze and sound, its air and hazards.

### 3.1 The eight kinds (`scripts/cave_kinds.lua`, pure)

| Kind | Walls (principal) | Formations | Feel | Bed | Hazard | Air |
|---|---|---|---|---|---|---|
| lava tube | pahoehoe, soot, basalt | lavacicles, ropy pahoehoe slabs, breakdown | red-black, heat haze, dead (900 Hz) | the ground's rumble | rockfall 0.35, +12 K | CO2 |
| ice cave | clear, banded, dirty ice, frost | ice curtains with icicles, hoarfrost | cold blue glow, breath mist | ice cracking in the walls (3D) | cold 248 K, slippery, drops | world's |
| karst | cave wall, dripstone, flowstone | stalactites, soda straws, stalagmites, flowstone drapes | pitch black (2 %), long drips on any world | none (drips) | sumps, flooding | CO2 0.025 bar |
| geode | quartz druzy, tuff | quartz point clusters, selenite | close, glassy (3.5 kHz) | none | enclosed | CO2 |
| salt | halite, chalk | selenite blades, hopper-cube crusts, salt straws | white throw-back (12 %), dust, dead (1.6 kHz) | none, bone dry | brittle 0.25, dust | world's |
| vent | sulfur crust, soot, sinter | sulfur needles, crusts | yellow murk (near fog 38 m), steam | steam and spitting mud | SO2/H2S, +35 K | SO2 40 µbar, H2S |
| collapse | the world's (no principal) | breakdown, stalactites | grey daylight-ish, dust | wind | rockfall 0.5, 20 m drops | world's |
| chasm | the formation's strata | breakdown, stalactites | cold blue-grey | water far below | 30 m drops | world's |

Each kind also lists decals, a depth band (vents and tubes deep, collapses shallow), rewards
(ores, first-entry RP) and three real speleology facts for the codex (W6).

- `kindsFor(formation, depth, type)` gives the kinds a world's caves may be: per W2 formation
  (`FORMATION_KINDS`, all 45), else per type (worlds rolled before formations), else per family.
  Collapse is always possible. Weights fall off outside each kind's depth band.
- `principalOf(formation, type, u)` is the world's main kind (never collapse), chosen among kinds
  within 25 % of the heaviest by a draw the generator already made.
- `regionOf(seed, x, y, z, R, caveDepth, formation, type)` is the kind of the 120 m region (about
  one chamber system) a body-local point lies in. The hash is integer arithmetic in doubles with a
  non-linear step (a linear one striped the map), the same under luajit and the engine.

### 3.2 Version 5

`MAT_GEN = 5` rolls exactly what version 4 rolls (no new rng draws: checked for every type, and
shapes equal over 30 seeds). Each world gets `g.caveKind` from its formation and the deep-hue
draw, and `deep` (the cave zone's paint) becomes the kind's wall rock when the formation's own
cave rock is not one of the kind's (`wallFor`, using the weathering draw). Chasm and collapse keep
the formation's. A geode world's pockets are quartz druzy hollows, more of them (threshold −0.05,
from 4 m). The world record gains `bio.caves = { depth, principal }` and `bio.palette.cave`. Over
30 systems: 177 worlds, 152 in their kind's wall rock, 29 with new rock; the new wall layers cost
about 0.3 more look-alike fallbacks per system (4.9 → 5.2). A save made before keeps version 4
and its cave rock; `cave_field` dresses its caves by kind all the same.

### 3.3 The cave field (`scripts/cave_field.lua`, on the Weather node)

- **Probe**, twice a second: the enclosure (underground.lua's rays, not cast twice), a ray up and
  one down from the eye (`height`), one down from 600 m above the ground to the first rock
  (`depth`), one down from 2.5 m ahead (`hazard.drop`). In a cave when a roof is within 30 m
  with 7 m of rock over it, or underground's enclosure is past 0.55 (out at 5 m / 0.35). The
  kind is `regionOf` the eye.
- **Hooks** (`findScript("cave_field")`): `caveKind` (PLAN §5.3's `cave.kind`; a script handle's
  `kind` is the engine's own and cannot be shadowed), `label`, `enclosure`, `height`, `depth`,
  `roofDepth`, `air` (bar the cave adds), `hazard`, `cells()`, `kindAt(x, y, z)`,
  `airAt(x, y, z)` (W5 wires atmo to it), `worldInfo(name)`, `stats`, `reset()` (probes).
- **Formations**: in a cave, the 10 m cells round the eye are dressed once each: nine candidate
  points per cell (a point in the cave's air, a ray up to the roof and down to the floor, a ray
  out to a wall), two a frame. A placement is a model, a body-local base, its up and facing, a
  scale and its kind; hanging ones keep 2.2 m of headroom. The cells are saved
  (`cave.cells.<body>`, at most 700, farthest dropped first), so a cave keeps its stalactites.
  Nodes are children of the planet's node (positions-and-frames rule 1): the nearest 48 within
  70 m, LOD 0 under 25 m (±10 % hysteresis), four made a pass. A formation whose rock is dug
  away goes and is saved gone. Tint per kind (`KINDS.tint/tints`; collapse and chasm take the
  world's cave rock); a crystal world's geode points glow faintly (the declared fiction).
- **Marks**: up to three per cell on roofs and walls, none within 6 m of an ore vein; the nearest
  40 within 40 m are laid (`decals.add`), the rest lifted.
- **No paint**: nothing here paints terrain (`fieldEdited` is flat while walking a cave).

### 3.4 Ambience by kind (`scripts/underground.lua`)

underground.lua reads `cave_field.caveKind` and eases every knob to the kind's `amb` over about
2.5 s: the ambient's floor and colour, the haze over atmosphere.lua's (colour, volumetric density
or the flat ramp's reach; deferred through planet_camera so it lands after atmosphere writes;
nothing in vacuum), the motes' colour and amount, the room tone's level and low-pass, the drips
(karst drips on any world; lava, salt and vents are dry), how often the rock creaks and the share
of groans, the ice cave's own cracks, and a recorded bed faded in with the enclosure (only the
rumble reaches you in vacuum, muffled). A deep cave whose tipped sky rays run off along passages
is still dark: `cave_field.roofDepth` firms up the enclosure. New recordings (all CC0, real):
`cave_vent`, `cave_rumble`, `cave_water_far`, `cave_ice_crack_1..3` (`audio/SOURCES.md`,
`tools/build_cave_audio.py`).

### 3.5 Formations as models (`tools/gen_cave_props.py`)

Thirteen props and the flare, two LODs each (`models/cave/`, 50–2700 triangles): stalactite
clusters with drapery rings and a flowstone boss, candle-stack stalagmites, soda straws, flowstone
drapes, ice curtains with icicles, hoarfrost plates, lavacicles, ropy pahoehoe slabs, breakdown
blocks, quartz geode clusters, selenite blades, hopper-cube halite crusts, sulfur needles. Five
neutral PBR sets (`textures/cave/`: calcite, ice, crystal, basalt, sulfur; picture, normal map,
metal-roughness map, mean 0.77 so a tint can reach yellow) and ambient occlusion in the vertex
colour. Seven RGBA decals (`textures/vfx/decal/cave_*.png`).

**No sky in a cave.** A physical model reflects the sky's picture, and underground that sheen
was all a prop showed past the lamp: pale blue-grey whatever its tint (W3's open finding).
cave_field sets `reflectivity = 0` on each prop a beat after its model lands. Without that sheen
a model's only fill is the scene's ambient, of which it takes a darker share than the terrain, so
each prop's tint also lifts its ambient ×3 (as dim as its wall, never a black cut-out), and the
clear ones (selenite, ice, hoarfrost, quartz, halite, straws) carry a faint pale rim, the glassy
edge a lamp finds on a crystal. The same fix for W3's surface outcrops: `mineral_field`
outcrop_look gives rock reflectivity 0.15 and metal ores 0.6.

**The least light.** Each kind has `amb.dim`, an absolute ambient floor (× its tint) that
underground.lua keeps whatever the sky: 0.008 in karst to 0.022 in salt. Enough to sense a
chamber's shape, never its detail.

### 3.6 Rationed light

- **Lamp Cell** (`items.cell`, $15, 0.15 kg): a flat torch takes one from the pack when L is
  pressed (`flashlight.swapCell`): 4 more hours. Nothing swaps by itself.
- **Flare** (`items.flare`, $6): G on foot throws one (`scripts/cave_flares.lua`): it arcs under
  the world's gravity, lands where the rock stops it and burns 90 s as a flickering red point
  light with a glowing end and smoke; at most six burn at once (the oldest goes out).
- **One lamp cell for both lamps** (`flashlight.cellLevel`): the torch's battery when a torch is
  in the pack, else the suit's own lamp cell (save `crew.lampcell.<pack>`). The helmet lamps
  draw on it at `HELMET_DRAW` (0.4) of the torch's rate, so a cell is 4 h of torch or 10 h of
  helmet lamps. Under 10 % they brown out and flicker; flat, they fall to an **emergency glow**
  (suit.lua: 14 % intensity, 5 m, sputtering), never darkness. L swaps a spare cell into
  whichever lamp feeds it. Both charge aboard or at the base.
- **The Lamp chip** (status_hud): in a cave, on foot: which lamp draws ("Torch", "Helmet
  lamps"), its minutes left at that draw, the cells and flares in the pack; caution under
  30 min; "Emergency glow" in warning red when the cell is flat.

### 3.7 Probes and tests

- `tests/smoke_cave_kinds.lua`: the tables complete and on disk, coverage of every formation and
  type, determinism and no striping of regions; cave_field in a stub cave (kind, depth, height,
  dressing within caps, headroom, saved and re-read, dug away); underground's ambience per kind;
  spare cells.
- `tests/smoke_geology.lua`: the version-5 block.
- `tools/perf/caveprobe.sh <engine> <seed…>` (`caveprobe_modes.lua`): finds a natural cave under
  a fresh save's home world, stands in it, logs `CV STATE` (kind, air, hazards, nodes, marks),
  `CV COST` (cave_field, underground, rays, field edits), and shoots the lamps, the torch, flares
  and the HUD; `sweep=1` dresses the same cave as each kind, `tintlab=1` the tint A/B.
