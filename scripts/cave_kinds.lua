-- CAVE KINDS — what a cave is, by kind (worlds plan W4, work/worlds/PLAN.md
-- §4; docs/worlds-and-caves.md §3).
--
-- PURE. No engine calls: cave_field.lua, underground.lua and
-- system_generator.lua find it (findScript) and the luajit tests load it from
-- disk (tests/smoke_cave_kinds.lua).
--
-- Ty (2026-11-10): "I dig and find cool caves but they're all made of the same
-- few rocks and formations so it gets boring fast... make more scary feeling
-- and unique caves." A cave is now a PLACE WITH A KIND: you know within ten
-- steps whether you are in a lava tube, a karst gallery, an ice cave or a
-- vent, from its walls, what hangs from its roof, its floor, its air and its
-- sound, and each kind has one thing that can hurt you and one thing worth
-- going in for.
--
--   KINDS          the eight kinds: walls, props, decals, ambience, hazards,
--                  air, rewards and real speleology facts
--   kindsFor(f, depth, type)    the kinds a formation's caves may be, weighted
--                               by depth (0 at the top of the cave zone, 1 at
--                               its floor); collapse is always possible
--   principalOf(f, type, u)     the world's main kind (never collapse: that is
--                               an entrance kind), from an existing draw `u`
--   wallFor(kind, caveName, u)  the library layer the principal kind's walls
--                               are painted in (generator 4 `deep`), or nil to
--                               keep the formation's own cave rock
--   regionOf(seed, x, y, z, R, caveDepth, f, type)  the kind of the ~120 m
--                               region a body-local point lies in, and its cell
--   hazardsOf(kind), airOf(kind), propsOf(kind), ambienceOf(kind)
--
-- On generator 4 every kind shares the engine's one cave shape; the region
-- decides the dressing, air, sound and hazards, and the principal kind the
-- world's cave walls. Generator 5 (engine card 0676) will take the same table
-- for each region's shape.

defaults = {}

ORDER = { "lava_tube", "ice", "karst", "geode", "salt", "vent", "collapse", "chasm" }

-- Region cells: the engine's chamber field has a ~120 m wavelength, so a
-- region is about one chamber system.
REGION = 120.0

-- ── THE KINDS ───────────────────────────────────────────────────────────────
-- walls     library layers (geology.LIB names) the principal kind paints its
--           walls in, the first the most typical
-- depth     { lo, hi } the band of the cave zone (0 top .. 1 floor) where
--           this kind is most at home; weight falls off outside it
-- props     { id, at, w, s = { min, max }, orient } — cave_field places them:
--           at "ceil" (hung from the roof), "floor", "wall"; orient "hang"
--           (straight down, gravity), "stand" (straight up), "normal" (off the
--           surface), "drape" (down the wall)
-- tint      the props' colour (multiplied over the neutral picture)
-- decals    marks laid on the walls near you (textures/cave/)
-- amb       the ambience underground.lua reads: `floor` the ambient share
--           left, `tint` its colour; `fog` { r, g, b, density ×, far × };
--           `dim` the least ambient a cave of the kind keeps whatever the
--           sky (absolute, × its tint: the shape of a chamber, never its
--           detail); `motes` tint and amount; `tone` room-tone gain ×, `toneLp` Hz
--           (dead acoustics), `drips` rate × (0 = dry), `dripsAlways`;
--           `creak` rate × and `creaks` (clip set), `groan` the share of
--           groans; `loop` a recorded bed (clip, gain)
-- hazards   unstable (rockfall chance on a dig, 0..1), cold (air K: nil = the
--           world's), heat (K over the world's), dose (Sv/h background),
--           drop (typical fall, m), gas (the bad air's main gas), flood
-- air       partial pressures in bar the cave adds (nil = the world's air)
-- rewards   ores this kind biases toward, survey RP on first entry
-- facts     real speleology (codex, W6)
KINDS = {
  lava_tube = {
    id = "lava_tube", label = "Lava tube", short = "a drained lava channel",
    walls = { "pahoehoe", "soot", "basalt" },
    depth = { 0.35, 1.0 },
    props = {
      { id = "lavacicle", at = "ceil", w = 5, s = { 0.84, 2 }, orient = "hang" },
      { id = "breakdown", at = "floor", w = 3, s = { 0.75, 2 }, orient = "normal" },
      { id = "ropy_slab", at = "floor", w = 3, s = { 1, 2 }, orient = "normal" },
      { id = "lavacicle", at = "wall", w = 1, s = { 0.46, 0.92 }, orient = "hang" },
    },
    tint = { 0.13, 0.11, 0.10 },
    tints = { breakdown = { 0.20, 0.18, 0.17 }, ropy_slab = { 0.10, 0.09, 0.085 } },
    decals = { { tex = "soot", w = 3, size = { 1.5, 3.5 } }, { tex = "crack", w = 1, size = { 1.0, 2.2 } } },
    amb = { dim = 0.010, floor = 0.035, tint = { 1.0, 0.62, 0.45 }, fog = { 0.10, 0.045, 0.03, 1.4, 0.55 },
            motes = { 1.0, 0.7, 0.5, 0.8 }, tone = 0.6, toneLp = 900, drips = 0, creak = 0.8, groan = 0.7,
            loop = { clip = "audio/ambience/cave_rumble.ogg", gain = 0.36 } },
    hazards = { unstable = 0.35, heat = 12, dose = 0, drop = 4, gas = "CO2" },
    air = { CO2 = 0.012, SO2 = 0.000004 },
    rewards = { ores = { "obsidian", "sulfur", "iron" }, rp = 25 },
    facts = {
      "A lava tube is the drained channel of a lava flow that crusted over: the roof froze while molten rock kept running underneath.",
      "Lavacicles are drips of remelted rock frozen on the roof, glassy and sharp; ropy pahoehoe floors are the last lava's skin.",
      "Skylights, where a roof has fallen in, mark lava tubes on the Moon (Marius Hills) and Mars (Arsia Mons).",
    },
  },
  ice = {
    id = "ice", label = "Ice cave", short = "meltwater tubes in glacier ice",
    walls = { "clearice", "bandedice", "dirtyice", "frost" },
    depth = { 0.0, 0.6 },
    props = {
      { id = "ice_curtain", at = "ceil", w = 5, s = { 0.84, 2.1 }, orient = "hang" },
      { id = "hoarfrost", at = "wall", w = 3, s = { 0.57, 1.3 }, orient = "normal" },
      { id = "hoarfrost", at = "ceil", w = 2, s = { 0.7, 1.4 }, orient = "normal" },
      { id = "ice_curtain", at = "floor", w = 1, s = { 0.62, 1.1 }, orient = "stand" },
    },
    tint = { 0.55, 0.72, 0.86 },
    tints = { hoarfrost = { 0.86, 0.92, 0.96 } },
    decals = { { tex = "frost", w = 4, size = { 1.2, 3.0 } }, { tex = "crack", w = 1, size = { 1.0, 2.5 } } },
    amb = { dim = 0.016, floor = 0.11, tint = { 0.55, 0.78, 1.0 }, fog = { 0.05, 0.08, 0.11, 1.0, 0.7 },
            motes = { 0.75, 0.88, 1.0, 1.0 }, tone = 0.45, toneLp = 2200, drips = 0.35, creak = 1.6, groan = 0.35,
            creaks = "ice" },
    hazards = { unstable = 0.15, cold = 248, dose = 0, drop = 18, gas = nil, slippery = true },
    air = nil,
    rewards = { ores = { "clathrate" }, rp = 25 },
    facts = {
      "Glacier caves are carved by meltwater running through and under the ice; their walls are scalloped by the flow.",
      "The blue is the ice itself: dense glacier ice absorbs red light, so thick ice glows blue in transmitted light.",
      "Moulins are vertical shafts where surface melt drops into a glacier; Vatnajokull's ice caves change every season.",
    },
  },
  karst = {
    id = "karst", label = "Karst cave", short = "dissolved limestone galleries",
    walls = { "cavewall", "dripstone", "flowstone" },
    depth = { 0.0, 0.6 },
    props = {
      { id = "stalactite", at = "ceil", w = 6, s = { 0.7, 2.2 }, orient = "hang" },
      { id = "soda_straws", at = "ceil", w = 3, s = { 0.7, 1.4 }, orient = "hang" },
      { id = "stalagmite", at = "floor", w = 5, s = { 0.62, 1.9 }, orient = "stand" },
      { id = "flowstone", at = "wall", w = 3, s = { 0.8, 1.8 }, orient = "drape" },
    },
    tint = { 0.80, 0.72, 0.60 },
    tints = { soda_straws = { 0.88, 0.82, 0.70 }, flowstone = { 0.70, 0.56, 0.42 } },
    decals = { { tex = "drip", w = 4, size = { 1.0, 2.6 } }, { tex = "calcite", w = 2, size = { 1.2, 2.8 } } },
    amb = { dim = 0.008, floor = 0.022, tint = { 0.9, 0.92, 1.0 }, fog = { 0.02, 0.022, 0.025, 0.7, 1.0 },
            motes = { 0.9, 0.9, 0.85, 1.0 }, tone = 1.0, drips = 1.8, dripsAlways = true, creak = 1.0, groan = 0.4 },
    hazards = { unstable = 0.1, dose = 0, drop = 14, gas = "CO2", flood = true },
    air = { CO2 = 0.025 },
    rewards = { ores = { "galena" }, rp = 35 },
    facts = {
      "Karst caves are dissolved out of limestone by groundwater made weakly acid by carbon dioxide from the soil.",
      "Each stalactite grows a few millimetres a century as dripping water gives up its calcite; soda straws are the hollow young ones.",
      "Low passages can hold 'bad air': carbon dioxide sinks and pools in sumps, where a lamp flame gutters and a caver pants.",
    },
  },
  geode = {
    id = "geode", label = "Geode hollow", short = "a crystal-lined hollow",
    walls = { "quartzdruzy", "tuff" },
    depth = { 0.2, 1.0 },
    props = {
      { id = "geode_cluster", at = "wall", w = 5, s = { 0.57, 1.5 }, orient = "normal" },
      { id = "geode_cluster", at = "ceil", w = 3, s = { 0.7, 1.5 }, orient = "normal" },
      { id = "geode_cluster", at = "floor", w = 3, s = { 0.75, 1.8 }, orient = "normal" },
      { id = "selenite", at = "floor", w = 1, s = { 0.62, 1.2 }, orient = "normal" },
    },
    tint = { 0.80, 0.80, 0.86 },
    tints = { selenite = { 0.86, 0.84, 0.80 } },
    decals = { { tex = "calcite", w = 1, size = { 1.0, 2.0 } } },
    amb = { dim = 0.010, floor = 0.03, tint = { 0.9, 0.85, 1.0 }, fog = { 0.02, 0.02, 0.03, 0.5, 1.0 },
            motes = { 0.9, 0.88, 1.0, 0.6 }, tone = 0.4, toneLp = 3500, drips = 0.2, creak = 0.5, groan = 0.2 },
    hazards = { unstable = 0.05, dose = 0, drop = 3, gas = "CO2" },
    air = { CO2 = 0.008 },
    rewards = { ores = { "crystal" }, rp = 30 },
    facts = {
      "A geode is a hollow in rock, often a gas bubble in lava or a dissolved nodule, lined by crystals grown inward from water.",
      "The bands round the lining are chalcedony laid down in pulses; the points inside are quartz, sometimes amethyst.",
      "The largest known, the Pulpi geode in Spain, is eight metres long and lined with clear gypsum blades.",
    },
  },
  salt = {
    id = "salt", label = "Salt cavern", short = "rooms dissolved in evaporites",
    walls = { "halite", "chalk" },
    depth = { 0.0, 1.0 },
    props = {
      { id = "selenite", at = "floor", w = 5, s = { 0.75, 2.2 }, orient = "normal" },
      { id = "salt_crust", at = "floor", w = 3, s = { 0.75, 1.8 }, orient = "normal" },
      { id = "salt_crust", at = "wall", w = 3, s = { 0.57, 1.4 }, orient = "normal" },
      { id = "soda_straws", at = "ceil", w = 2, s = { 0.7, 1.3 }, orient = "hang" },
    },
    tint = { 0.90, 0.88, 0.84 },
    tints = { selenite = { 0.84, 0.82, 0.76 }, soda_straws = { 0.92, 0.90, 0.86 } },
    decals = { { tex = "salt", w = 4, size = { 1.2, 3.2 } }, { tex = "crack", w = 1, size = { 1.0, 2.0 } } },
    amb = { dim = 0.022, floor = 0.12, tint = { 1.0, 0.97, 0.92 }, fog = { 0.12, 0.115, 0.11, 1.3, 0.6 },
            motes = { 1.0, 0.98, 0.94, 1.4 }, tone = 0.35, toneLp = 1600, drips = 0, creak = 0.6, groan = 0.3 },
    hazards = { unstable = 0.25, dose = 0, drop = 6, gas = nil, dust = true },
    air = nil,
    rewards = { ores = { "salt", "sperrylite" }, rp = 30 },
    facts = {
      "Salt caves are rare: halite dissolves so readily that they form only in deserts, where rain is too scarce to wash them away.",
      "Selenite is gypsum grown as clear blades; Naica's Cave of the Crystals in Mexico holds beams twelve metres long, at 58 C.",
      "White walls throw a lamp back from every side; with no shadows and no colour, distance is hard to judge.",
    },
  },
  vent = {
    id = "vent", label = "Sulfur vent", short = "fumarole chimneys over hot rock",
    walls = { "sulfurvein", "soot", "flowstone" },
    depth = { 0.4, 1.0 },
    props = {
      { id = "sulfur_needles", at = "wall", w = 5, s = { 0.57, 1.4 }, orient = "normal" },
      { id = "sulfur_needles", at = "floor", w = 3, s = { 0.75, 1.8 }, orient = "normal" },
      { id = "ropy_slab", at = "floor", w = 2, s = { 0.75, 1.5 }, orient = "normal" },
      { id = "sulfur_needles", at = "ceil", w = 2, s = { 0.56, 1.3 }, orient = "normal" },
    },
    tint = { 0.95, 0.80, 0.16 },
    tints = { ropy_slab = { 0.62, 0.58, 0.30 } },
    decals = { { tex = "sulfur", w = 4, size = { 1.2, 3.0 } }, { tex = "soot", w = 2, size = { 1.5, 3.0 } } },
    amb = { dim = 0.016, floor = 0.05, tint = { 1.0, 0.88, 0.45 }, fog = { 0.16, 0.13, 0.04, 2.6, 0.35 },
            motes = { 1.0, 0.9, 0.45, 1.6 }, tone = 0.5, toneLp = 1200, drips = 0, creak = 0.5, groan = 0.5,
            loop = { clip = "audio/ambience/cave_vent.ogg", gain = 0.5 } },
    hazards = { unstable = 0.2, heat = 35, dose = 0, drop = 10, gas = "SO2" },
    air = { SO2 = 0.00004, H2S = 0.00002, CO2 = 0.02 },
    rewards = { ores = { "sulfur" }, rp = 45 },
    facts = {
      "A fumarole is a vent where volcanic gas escapes: steam, carbon dioxide, sulfur dioxide and hydrogen sulfide.",
      "Native sulfur crystallises from the gas as yellow needles round the vent's mouth; at night burning sulfur glows blue at Kawah Ijen.",
      "Sulfur dioxide stings at a few parts per million and kills at a few hundred; volcanologists work in vents with respirators.",
    },
  },
  collapse = {
    id = "collapse", label = "Collapse sink", short = "a roof fallen in",
    walls = nil,
    depth = { 0.0, 0.35 },
    props = {
      { id = "breakdown", at = "floor", w = 6, s = { 0.88, 2.5 }, orient = "normal" },
      { id = "breakdown", at = "wall", w = 2, s = { 0.57, 1.1 }, orient = "normal" },
      { id = "stalactite", at = "ceil", w = 1, s = { 0.56, 1.1 }, orient = "hang" },
    },
    tint = nil,   -- the world's rock
    decals = { { tex = "crack", w = 3, size = { 1.2, 3.0 } }, { tex = "drip", w = 1, size = { 1.0, 2.0 } } },
    amb = { dim = 0.020, floor = 0.14, tint = { 0.95, 0.97, 1.0 }, fog = { 0.10, 0.10, 0.10, 1.2, 0.8 },
            motes = { 1.0, 1.0, 1.0, 1.6 }, tone = 0.6, drips = 0.6, creak = 1.4, groan = 0.6,
            loop = { clip = "audio/ambience/wind_low.ogg", gain = 0.32 } },
    hazards = { unstable = 0.5, dose = 0, drop = 20, gas = nil },
    air = nil,
    rewards = { ores = {}, rp = 15 },
    facts = {
      "A collapse sink forms when a cave's roof can no longer span its chamber and falls in: the breakdown pile below is the roof.",
      "Cenotes in Yucatan and the tiankeng of China are sinks into huge chambers, some deep enough to hold their own forests.",
      "A fresh collapse is the most dangerous ground in caving: the blocks above are the ones still deciding whether to fall.",
    },
  },
  chasm = {
    id = "chasm", label = "Deep chasm", short = "a fissure that keeps going",
    walls = nil,   -- the formation's own strata: the chasm is its cross-section
    depth = { 0.1, 1.0 },
    props = {
      { id = "breakdown", at = "floor", w = 4, s = { 1, 2.8 }, orient = "normal" },
      { id = "breakdown", at = "wall", w = 3, s = { 0.57, 1.4 }, orient = "normal" },
      { id = "stalactite", at = "ceil", w = 1, s = { 0.56, 1.3 }, orient = "hang" },
    },
    tint = nil,   -- the world's rock
    tints = { stalactite = { 0.55, 0.52, 0.48 } },
    decals = { { tex = "crack", w = 3, size = { 1.5, 3.5 } }, { tex = "drip", w = 2, size = { 1.0, 3.0 } } },
    amb = { dim = 0.010, floor = 0.06, tint = { 0.80, 0.88, 1.0 }, fog = { 0.04, 0.05, 0.065, 1.1, 0.75 },
            motes = { 0.9, 0.95, 1.0, 1.0 }, tone = 0.8, drips = 0.8, creak = 1.0, groan = 0.6,
            loop = { clip = "audio/ambience/cave_water_far.ogg", gain = 0.42 } },
    hazards = { unstable = 0.3, dose = 0, drop = 30, gas = nil },
    air = nil,
    rewards = { ores = { "uranium" }, rp = 30 },
    facts = {
      "A chasm is a fissure opened along a joint or fault, deepened by water: its walls are a cross-section through the rock record.",
      "Chockstones are boulders wedged between the walls; cavers climb past them, and sometimes they move.",
      "Uranium roll-fronts, crescent ore bodies where groundwater dropped its uranium, were first found exposed in such cuts.",
    },
  },
}

-- ── WHICH KINDS A FORMATION'S CAVES MAY BE ──────────────────────────────────
-- Weights per W2 formation (geology.FORMATIONS ids). Collapse is added to
-- every world; geodes appear as pockets where the rock makes vesicles.
FORMATION_KINDS = {
  basalt_shield = { lava_tube = 3, geode = 0.5 },
  granite_craton = { chasm = 2, geode = 1 },
  coral_limestone = { karst = 4 },
  peat_mudstone = { karst = 1.5, chasm = 1 },
  loess_karst = { karst = 4.5 },
  laterite_gneiss = { chasm = 2, geode = 0.5 },
  granite_schist = { chasm = 3, geode = 1 },
  slate_gneiss = { chasm = 3 },
  limestone_nappe = { karst = 3, chasm = 1.5 },
  redbeds = { chasm = 2.5, geode = 0.5 },
  greystack = { karst = 3, chasm = 1 },
  conglomerate_tuff = { geode = 1.5, chasm = 1.5 },
  loess_chalk = { karst = 2.5 },
  flood_basalt = { lava_tube = 3 },
  sandstone_platform = { chasm = 2 },
  quartz_erg = { chasm = 1.5, salt = 0.5 },
  gypsum_dunes = { salt = 3, karst = 1 },
  black_erg = { lava_tube = 2 },
  halite_mud = { salt = 4 },
  gypsum_clay = { salt = 3 },
  borate_crust = { salt = 2, geode = 1 },
  hematite_basalt = { lava_tube = 2.5, chasm = 1 },
  goethite_sandstone = { chasm = 2 },
  permafrost_shale = { ice = 3 },
  till_granite = { ice = 2.5, chasm = 1.5 },
  clearice_basalt = { ice = 4, chasm = 1 },
  firn_granite = { ice = 3.5, chasm = 1.5 },
  dirtyice_regolith = { ice = 3 },
  pahoehoe_aa = { lava_tube = 4, vent = 1 },
  columnar = { lava_tube = 3, vent = 1, chasm = 1 },
  tuff_scoria = { vent = 2, geode = 1, lava_tube = 1.5 },
  sulfur_basalt = { vent = 4, lava_tube = 1 },
  sinter_tuff = { vent = 3.5, geode = 1 },
  tesserae_basalt = { lava_tube = 2, vent = 2, chasm = 1 },
  anorthosite_highland = { chasm = 2, geode = 1 },
  quartz_slate = { geode = 3, chasm = 2 },
  geode_tuff = { geode = 4, lava_tube = 1 },
  tholin_ice = { ice = 4 },
  clathrate_dunes = { ice = 3.5, vent = 0.5 },
  banded_basalt = { ice = 3, lava_tube = 1 },
  dirty_regolith = { ice = 2.5 },
  highland_anorthosite = { chasm = 1.5, geode = 0.5 },
  mare_breccia = { lava_tube = 3 },
  kreep_basalt = { lava_tube = 4 },
  impact_melt = { lava_tube = 1.5, geode = 1 },
}
-- Worlds rolled before formations (material generation 1 and 2): by type.
TYPE_KINDS = {
  archipelago = { lava_tube = 2, karst = 2 },
  verdant = { karst = 3, chasm = 1 },
  alpine = { chasm = 3, karst = 1 },
  canyon = { chasm = 3, karst = 1 },
  steppe = { karst = 2, lava_tube = 1 },
  dune = { chasm = 1.5, salt = 1.5 },
  saltflat = { salt = 4 },
  ironred = { lava_tube = 2, chasm = 1.5 },
  tundra = { ice = 3 },
  glacial = { ice = 4 },
  volcanic = { lava_tube = 4, vent = 1 },
  sulfur = { vent = 4, lava_tube = 1 },
  greenhouse = { lava_tube = 2, vent = 2 },
  crystal = { geode = 4, chasm = 1 },
  titan = { ice = 4 },
  frost = { ice = 3 },
  regolith = { chasm = 1, geode = 0.5 },
  maria = { lava_tube = 4 },
}
-- And by legacy family, the last resort.
FAMILY_KINDS = {
  canyon = { chasm = 2, karst = 2 }, dune = { salt = 2, chasm = 1 }, ice = { ice = 3 }, frost = { ice = 3 },
  lava = { lava_tube = 3, vent = 1 }, crystal = { geode = 3 }, barren = { lava_tube = 1, chasm = 1 },
}
COLLAPSE_W = 0.7

local function clamp01(x) return math.max(0, math.min(1, x)) end

local function formation_id(f)
  if type(f) == "table" then return f.id end
  return f
end

-- The base weights for a formation (id or table with `.id`), else the type,
-- else the family; collapse always.
function baseWeights(f, ty, family)
  local src = FORMATION_KINDS[formation_id(f) or ""] or TYPE_KINDS[ty or ""] or FAMILY_KINDS[family or ""]
    or { chasm = 1, karst = 1 }
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  out.collapse = (out.collapse or 0) + COLLAPSE_W
  return out
end

-- How much a kind likes depth `d` (0 top of the cave zone .. 1 its floor).
function depthFit(kind, d)
  local K = KINDS[kind]
  if not (K and K.depth) or d == nil then return 1 end
  local lo, hi = K.depth[1], K.depth[2]
  d = clamp01(d)
  if d >= lo and d <= hi then return 1 end
  local off = (d < lo) and (lo - d) or (d - hi)
  return math.max(0.08, 1 - off * 2.5)
end

-- The kinds a formation's caves may be at depth `d`, as an ordered list of
-- { id, w } (ORDER order; weights sum to 1).
function kindsFor(f, d, ty, family)
  local base = baseWeights(f, ty, family)
  local out, sum = {}, 0
  for _, id in ipairs(ORDER) do
    local w = base[id]
    if w and w > 0 then
      w = w * depthFit(id, d)
      out[#out + 1] = { id, w }
      sum = sum + w
    end
  end
  for _, e in ipairs(out) do e[2] = e[2] / sum end
  return out
end

-- The world's principal kind: the heaviest at mid-depth, with a world-to-world
-- choice between kinds within 25 % of the heaviest from `u` (a draw the
-- generator already made: no new rng calls). Never collapse.
function principalOf(f, ty, u, family)
  local base = baseWeights(f, ty, family)
  local best = 0
  for _, id in ipairs(ORDER) do
    if id ~= "collapse" and (base[id] or 0) > best then best = base[id] end
  end
  local cand = {}
  for _, id in ipairs(ORDER) do
    if id ~= "collapse" and (base[id] or 0) >= best * 0.75 and best > 0 then cand[#cand + 1] = id end
  end
  if #cand == 0 then return "chasm" end
  local i = math.min(#cand, 1 + math.floor(clamp01(u or 0) * #cand))
  return cand[i]
end

-- The library layer the principal kind's walls take: the formation's own
-- cave rock if it is one of the kind's walls, else the kind's wall at `u`
-- (nil for chasm and collapse: they keep the formation's cave rock).
function wallFor(kind, caveName, u)
  local K = KINDS[kind]
  if not (K and K.walls) then return nil end
  for _, n in ipairs(K.walls) do if n == caveName then return n end end
  -- the kind's typical walls: its first two, chosen by u
  local n = math.min(#K.walls, 2)
  return K.walls[math.min(n, 1 + math.floor(clamp01(u or 0) * n))]
end

-- ── REGIONS ─────────────────────────────────────────────────────────────────
-- A deterministic integer hash in doubles (exact below 2^53: no bit library,
-- the same answer under luajit and the engine).
local M31 = 2147483647
-- (A product stays under 2^53, so every step is exact. The h·(h mod p) step
-- is what makes neighbouring cells unrelated: a purely linear mix gives
-- stripes of kinds across the map.)
local function mix(h, v)
  h = (h + (math.floor(v) % M31) * 2654435 + 1) % M31
  for _ = 1, 2 do
    h = (h * (h % 65521 + 1) + 12345) % M31
    h = (h * 48271) % M31
  end
  return h
end
function hash(seed, a, b, c)
  local h = mix(mix(mix(mix(97, seed or 0), a or 0), b or 0), c or 0)
  h = mix(h, 7)
  return h / M31
end

-- The region cell of a body-local point.
function cellOf(x, y, z, size)
  size = size or REGION
  return math.floor(x / size), math.floor(y / size), math.floor(z / size)
end
function cellKey(i, j, k) return i .. "," .. j .. "," .. k end

-- The kind of the region a BODY-LOCAL point lies in (planets only translate,
-- so a body-local point is fixed: docs/positions-and-frames.md rule 1).
-- `R` the radius, `caveDepth` the cave zone's depth; `f`, `ty` the formation
-- (id or table) and type. Returns kind id, cell key, depth fraction.
function regionOf(seed, x, y, z, R, caveDepth, f, ty, family)
  local i, j, k = cellOf(x, y, z)
  local r = math.sqrt(x * x + y * y + z * z)
  local d = (caveDepth and caveDepth > 0) and clamp01((R - r) / caveDepth) or 0.5
  local list = kindsFor(f, d, ty, family)
  local u = hash(seed, i, j, k)
  local acc = 0
  for _, e in ipairs(list) do
    acc = acc + e[2]
    if u < acc then return e[1], cellKey(i, j, k), d end
  end
  return list[#list][1], cellKey(i, j, k), d
end

-- ── TABLE READS ─────────────────────────────────────────────────────────────
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
-- { unstable, cold, heat, dose, drop, gas, flood, slippery, dust }
function hazardsOf(kind)
  local K = KINDS[kind]
  local h = copy(K and K.hazards or {})
  h.unstable = h.unstable or 0
  h.dose = h.dose or 0
  h.drop = h.drop or 0
  return h
end
-- The cave's own air (bar partial pressures), or nil for the world's.
function airOf(kind)
  local K = KINDS[kind]
  return K and copy(K.air) or nil
end
-- The props list (as in KINDS) with each one's tint resolved; `rock` is the
-- world's rock colour for kinds that take it.
function propsOf(kind, rock)
  local K = KINDS[kind]
  if not K then return {} end
  local out = {}
  for _, p in ipairs(K.props) do
    local e = copy(p)
    e.tint = copy((K.tints and K.tints[p.id]) or K.tint or rock or { 0.5, 0.48, 0.45 })
    out[#out + 1] = e
  end
  return out
end
function ambienceOf(kind) local K = KINDS[kind]; return K and K.amb or nil end
function decalsOf(kind) local K = KINDS[kind]; return K and K.decals or {} end
function labelOf(kind) local K = KINDS[kind]; return K and K.label or nil end

-- Every prop model id the kinds name (the generator writes these files:
-- tools/gen_cave_props.py; tests check them on disk).
function propIds()
  local seen, out = {}, {}
  for _, id in ipairs(ORDER) do
    for _, p in ipairs(KINDS[id].props) do
      if not seen[p.id] then seen[p.id] = true; out[#out + 1] = p.id end
    end
  end
  table.sort(out)
  return out
end
PROP_DIR = "models/cave/"
function propModel(id, lod) return string.format("%s%s_l%d.gltf", PROP_DIR, id, lod or 0) end
DECAL_DIR = "textures/vfx/decal/"
function decalTexture(name) return DECAL_DIR .. "cave_" .. name .. ".png" end
function decalNames()
  local seen, out = {}, {}
  for _, id in ipairs(ORDER) do
    for _, d in ipairs(KINDS[id].decals or {}) do
      if not seen[d.tex] then seen[d.tex] = true; out[#out + 1] = d.tex end
    end
  end
  table.sort(out)
  return out
end
