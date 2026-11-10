-- GEOLOGY — what each world type is made of, by FORMATION (worlds plan W2,
-- work/worlds/PLAN.md §3.2–3.6; docs/worlds-and-caves.md §1).
--
-- PURE. No engine calls: system_generator.lua finds it (findScript) and the
-- luajit tests load it from disk (tests/smoke_geology.lua).
--
-- Ty (2026-11-10): "planets are kind of just made of only a few materials …
-- caves all made of the same few rocks and formations so it gets boring
-- fast." Until material generation 3 every world's underground came from one
-- list per legacy family (seven lists for eighteen types). Now each TYPE has
-- two or three FORMATIONS, each a whole stack from the surface to the cave
-- wall, with its own thickness and colour ranges:
--
--   high/low/patch   optional: the surface paints the formation replaces
--   subsoil          { names…, d = { min, max } }   the loose layer (m)
--   strata           { names…, d = { min, max } }   the sedimentary record
--   deep             { names… }  the basement (published; painted by gen 5)
--   cave             { names… }  what the cave zone is cut through: on
--                    generator 4 this is the `deep` layer the engine paints
--                    below caveDepth/2, so the cave wall is the cave's, not
--                    the basement's (W7 hands both to generator 5)
--   cliff            the rock on faces over the type's slope (the slope rule)
--   band             the rock on the LOWER part of steep faces: ravine walls
--                    and mesa skirts show two rocks, the cross-section
--   pocket, seam     optional deposit layers (nil: the old crystal pockets
--                    and veinstone seam, which mining's economy rests on)
--   hue, sat         the rock tint ranges (system_generator M(): 0 sat = the
--                    photograph's own colour)
--
-- A name is a LIBRARY LAYER (LIB below: the 32 palette layers and the 28
-- W1 library layers 33–60, tools/import_textures.py TERRAIN). Twenty-four of
-- the 32 palette slots are FIXED; the other eight are WILDCARDS: their
-- palette lines carry flags and a height map but no picture, and each star
-- system's roll hands them the library layers its worlds name (an Assign,
-- below), given to the engine with terrain.setSlotMaterial at load. A layer
-- that finds no free wildcard falls back to a fixed slot that looks like it.
-- A save made before generation 3 keeps every wildcard on its own old layer
-- (identity), so its ground is the ground it had.

defaults = {}

-- ── THE LIBRARY ─────────────────────────────────────────────────────────────
-- [layer] = { name, role, material, normal, orm, height } (map files under
-- textures/env/terrain/maps/). The material is what a dig of it pays
-- (materials.lua REG); 60 quartz druzy pays silica. Generated from
-- tools/import_textures.py TERRAIN; tests/smoke_geology.lua checks every file.
LIB = {
  [1] = { "rust", "rock", "rustrock", "Rocks011_normal.png", "Rocks011_orm.png", "Rocks011_height.png" },
  [2] = { "soil", "loose", "soil", "Ground039_normal.png", "Ground039_orm.png", "Ground039_height.png" },
  [3] = { "flagstone", "rock", "slate", "Rock023_normal.png", "Rock023_orm.png", "Rock023_height.png" },
  [4] = { "onyx", "rock", "onyx", "Onyx006_normal.png", "Onyx006_orm.png", "Onyx006_height.png" },
  [5] = { "veinstone", "ore", "veinstone", "Rock058_normal.png", "Rock058_orm.png", "Rock058_height.png" },
  [6] = { "magma", "glow", "uranium", nil, nil, nil },
  [7] = { "amethyst", "crystal", "crystal", "07_amethyst_normal.png", "07_amethyst_orm.png", "07_amethyst_height.png" },
  [8] = { "bluecrystal", "crystal", "crystal", "08_bluecrystal_normal.png", "08_bluecrystal_orm.png", "08_bluecrystal_height.png" },
  [9] = { "slate", "rock", "slate", "dark_rock_normal.png", "dark_rock_orm.png", "dark_rock_height.png" },
  [10] = { "gravelregolith", "loose", "regolith", "Ground110_normal.png", "Ground110_orm.png", "Ground110_height.png" },
  [11] = { "dust", "loose", "regolith", "moon_dusted_01_normal.png", "moon_dusted_01_orm.png", "moon_dusted_01_height.png" },
  [12] = { "bandedice", "ice", "ice", "12_bandedice_normal.png", "12_bandedice_orm.png", "12_bandedice_height.png" },
  [13] = { "basalt", "rock", "basalt", "Rock050_normal.png", "Rock050_orm.png", "Rock050_height.png" },
  [14] = { "granite", "rock", "granite", "Rock060_normal.png", "Rock060_orm.png", "Rock060_height.png" },
  [15] = { "sandstone", "rock", "sandstone", "Onyx010_normal.png", "Onyx010_orm.png", "Onyx010_height.png" },
  [16] = { "sand", "sand", "sand", "16_sand_normal.png", "16_sand_orm.png", "16_sand_height.png" },
  [17] = { "regolith", "loose", "regolith", "moon_meteor_01_normal.png", "moon_meteor_01_orm.png", "moon_meteor_01_height.png" },
  [18] = { "salt", "sand", "salt", "Ground031_normal.png", "Ground031_orm.png", "Ground031_height.png" },
  [19] = { "mudcrack", "loose", "clay", "mud_cracked_dry_riverbed_002_normal.png", "mud_cracked_dry_riverbed_002_orm.png", "mud_cracked_dry_riverbed_002_height.png" },
  [20] = { "moss", "veg", "soil", "Ground037_normal.png", "Ground037_orm.png", "Ground037_height.png" },
  [21] = { "ash", "loose", "ash", "Gravel043_normal.png", "Gravel043_orm.png", "Gravel043_height.png" },
  [22] = { "snow", "snow", "ice", "Snow014_normal.png", "Snow014_orm.png", "22_snow_height.png" },
  [23] = { "glacier", "ice", "ice", "23_glacier_normal.png", "23_glacier_orm.png", "23_glacier_height.png" },
  [24] = { "scree", "loose", "gravel", "Rocks006_normal.png", "Rocks006_orm.png", "Rocks006_height.png" },
  [25] = { "limestone", "rock", "limestone", "Rock051_normal.png", "Rock051_orm.png", "Rock051_height.png" },
  [26] = { "sulfur", "ore", "sulfur", "Rock055_normal.png", "Rock055_orm.png", "Rock055_height.png" },
  [27] = { "hematite", "ore", "hematite", "Ground085_normal.png", "Ground085_orm.png", "Ground085_height.png" },
  [28] = { "tundra", "veg", "soil", "28_tundra_normal.png", "28_tundra_orm.png", "28_tundra_height.png" },
  [29] = { "pahoehoe", "rock", "basalt", "Rock041_normal.png", "Rock041_orm.png", "Rock041_height.png" },
  [30] = { "shale", "rock", "shale", "Rock022_normal.png", "Rock022_orm.png", "Rock022_height.png" },
  [31] = { "peat", "veg", "soil", "Rock063_normal.png", "Rock063_orm.png", "Rock063_height.png" },
  [32] = { "litter", "veg", "soil", "32_litter_normal.png", "32_litter_orm.png", "32_litter_height.png" },
  [33] = { "cavewall", "cavewall", "limestone", "33_cavewall_normal.png", "33_cavewall_orm.png", "33_cavewall_height.png" },
  [34] = { "flowstone", "flowstone", "limestone", "34_flowstone_normal.png", "34_flowstone_orm.png", "34_flowstone_height.png" },
  [35] = { "dripstone", "flowstone", "limestone", "35_dripstone_normal.png", "35_dripstone_orm.png", "35_dripstone_height.png" },
  [36] = { "soot", "cavewall", "basalt", "quarry_wall_02_normal.png", "quarry_wall_02_orm.png", "quarry_wall_02_height.png" },
  [37] = { "frost", "snow", "ice", "37_frost_normal.png", "37_frost_orm.png", "37_frost_height.png" },
  [38] = { "tuff", "volcanic", "basalt", "rock_05_normal.png", "rock_05_orm.png", "rock_05_height.png" },
  [39] = { "columnar", "volcanic", "basalt", "Rock050_normal.png", "Rock050_orm.png", "Rock050_height.png" },
  [40] = { "halite", "evaporite", "salt", "40_halite_normal.png", "40_halite_orm.png", "40_halite_height.png" },
  [41] = { "clearice", "ice", "ice", "41_clearice_normal.png", "41_clearice_orm.png", "41_clearice_height.png" },
  [42] = { "gossan", "ore", "hematite", "Rock056_normal.png", "Rock056_orm.png", "Rock056_height.png" },
  [43] = { "pitchblende", "ore", "uranium", "43_pitchblende_normal.png", "43_pitchblende_orm.png", "43_pitchblende_height.png" },
  [44] = { "redbeds", "rock", "sandstone", "cliff_side_normal.png", "cliff_side_orm.png", "cliff_side_height.png" },
  [45] = { "mudstone", "rock", "shale", "Ground105_normal.png", "Ground105_orm.png", "Ground105_height.png" },
  [46] = { "chalk", "rock", "limestone", "Rock018_normal.png", "Rock018_orm.png", "Rock018_height.png" },
  [47] = { "clinker", "volcanic", "basalt", "rocks_ground_09_normal.png", "rocks_ground_09_orm.png", "rocks_ground_09_height.png" },
  [48] = { "obsidian", "volcanic", "obsidian", "48_obsidian_normal.png", "48_obsidian_orm.png", "48_obsidian_height.png" },
  [49] = { "scoria", "volcanic", "basalt", "rock_06_normal.png", "rock_06_orm.png", "rock_06_height.png" },
  [50] = { "schist", "rock", "slate", "Rock045_normal.png", "Rock045_orm.png", "Rock045_height.png" },
  [51] = { "gneiss", "rock", "granite", "marble_cliff_04_normal.png", "marble_cliff_04_orm.png", "marble_cliff_04_height.png" },
  [52] = { "marble", "rock", "limestone", "52_marble_normal.png", "52_marble_orm.png", "52_marble_height.png" },
  [53] = { "blacksand", "sand", "sand", "53_blacksand_normal.png", "53_blacksand_orm.png", "53_blacksand_height.png" },
  [54] = { "redregolith", "loose", "regolith", "gravelly_sand_normal.png", "gravelly_sand_orm.png", "gravelly_sand_height.png" },
  [55] = { "loess", "loose", "soil", "Ground102_normal.png", "Ground102_orm.png", "Ground102_height.png" },
  [56] = { "laggravel", "loose", "gravel", "sandy_gravel_02_normal.png", "sandy_gravel_02_orm.png", "sandy_gravel_02_height.png" },
  [57] = { "dirtyice", "ice", "ice", "57_dirtyice_normal.png", "57_dirtyice_orm.png", "57_dirtyice_height.png" },
  [58] = { "firn", "snow", "ice", "snow_02_normal.png", "snow_02_orm.png", "snow_02_height.png" },
  [59] = { "sulfurvein", "ore", "sulfur", "rock_05_normal.png", "rock_05_orm.png", "rock_05_height.png" },
  [60] = { "quartzdruzy", "crystal", "silica", "60_quartzdruzy_normal.png", "60_quartzdruzy_orm.png", "60_quartzdruzy_height.png" },
}
LIB_COUNT = 60
TERRAIN_DIR = "textures/env/terrain/"
MAPS_DIR = "textures/env/terrain/maps/"

-- name → layer. The old names system_generator's GEO_SLOT still uses for the
-- first slots (the version-1 tables) are aliases.
LAYER = {}
for n, e in pairs(LIB) do LAYER[e[1]] = n end
LAYER.purpledirt, LAYER.purpleslate, LAYER.oldregolith, LAYER.tealice = 2, 3, 10, 12

-- A layer's picture and maps, as terrain.setSlotMaterial takes them (the ORM
-- file is the roughness map: the engine packs R occlusion, G roughness,
-- B metal from it).
function filesOf(n)
  local e = LIB[n]
  if not e then return nil end
  return {
    texture = string.format("%s%02d_%s.png", TERRAIN_DIR, n, e[1]),
    normalMap = e[4] and (MAPS_DIR .. e[4]) or nil,
    roughnessMap = e[5] and (MAPS_DIR .. e[5]) or nil,
    height = e[6] and (MAPS_DIR .. e[6]) or nil,
  }
end
function materialOf(n) local e = LIB[n] return e and e[3] or "regolith" end
function roleOf(n) local e = LIB[n] return e and e[2] or "rock" end
function nameOf(n) local e = LIB[n] return e and e[1] or nil end

-- ── THE PALETTE: fixed slots and wildcards ──────────────────────────────────
-- The eight wildcard slots, chosen as the palette's least central layers
-- that have no commercial (`local=`) version, so a staged build and a CC0
-- build agree on them: the duplicates and near-duplicates (gravel regolith
-- and dust beside regolith, onyx beside sandstone and limestone) and the
-- type-specific ones (banded ice, ash, pahoehoe, peat, litter). A layer
-- keeps its slot number as its name, so on an older save every wildcard
-- holds its own layer. `class` steers a library layer to a wildcard whose
-- line flags (blend, scale, height bias) were tuned for its kind.
WILD = { 4, 10, 11, 12, 21, 29, 31, 32 }
WILD_CLASS = { [4] = "rock", [29] = "rock", [12] = "ice",
  [10] = "loose", [11] = "loose", [21] = "loose", [31] = "loose", [32] = "loose" }
IS_WILD = {}
for _, s in ipairs(WILD) do IS_WILD[s] = true end
local ROLE_CLASS = { rock = "rock", volcanic = "rock", cavewall = "rock", flowstone = "rock",
  evaporite = "rock", ore = "rock", crystal = "rock", glow = "rock",
  loose = "loose", sand = "loose", veg = "loose", ice = "ice", snow = "ice" }
function classOf(n) return ROLE_CLASS[roleOf(n)] or "rock" end

-- A layer with no wildcard to stand in: the fixed slot that looks most like
-- it (its tint carries the rest).
FALLBACK = {
  onyx = 15, gravelregolith = 17, dust = 17, bandedice = 23, ash = 17, pahoehoe = 13, peat = 2, litter = 20,
  cavewall = 25, flowstone = 25, dripstone = 25, soot = 13, frost = 22, tuff = 3, columnar = 13,
  halite = 18, clearice = 23, gossan = 27, pitchblende = 9, redbeds = 15, mudstone = 30, chalk = 25,
  clinker = 13, obsidian = 13, scoria = 13, schist = 9, gneiss = 14, marble = 25, blacksand = 16,
  redregolith = 17, loess = 2, laggravel = 24, dirtyice = 23, firn = 22, sulfurvein = 26, quartzdruzy = 7,
}
function isFixed(n) return n ~= nil and n >= 1 and n <= 32 and not IS_WILD[n] end
function fallbackOf(n)
  if isFixed(n) then return n end
  return FALLBACK[nameOf(n) or ""] or 17
end

-- ── AN ASSIGNMENT: which layer each wildcard holds for one star system ─────
-- Claims are greedy in roll order (home first), so the batch answer
-- (paletteNeeds) and the incremental one (the generator claiming as it rolls)
-- agree. A wildcard nobody claims keeps its own layer. Frozen (a neighbour
-- system streamed in later): no new claims, a layer is found or falls back.
local Assign = {}
Assign.__index = Assign

function newAssign()
  local a = setmetatable({ layer = {}, slotOf = {}, frozen = false }, Assign)
  for s = 1, 32 do a.layer[s] = s end
  for s = 1, 32 do if not IS_WILD[s] then a.slotOf[s] = s end end
  a.taken = {}   -- wildcard slot → true once claimed
  return a
end

-- The slot layer `n` draws in now, without claiming (nil: none holds it).
function Assign:peek(n)
  if n == nil then return nil end
  if isFixed(n) then return n end
  return self.slotOf[n]
end

-- The slot for layer `n`, claiming a free wildcard if it has none. Order of
-- preference: its own slot (an old layer), a free wildcard of its class,
-- any free wildcard; else the fallback.
function Assign:claim(n)
  if n == nil then return nil end
  local s = self:peek(n)
  if s then return s end
  if self.frozen then return fallbackOf(n) end
  local pick
  if IS_WILD[n] and not self.taken[n] then pick = n end
  if not pick then
    local cls = classOf(n)
    for _, w in ipairs(WILD) do
      if not self.taken[w] and WILD_CLASS[w] == cls then pick = w break end
    end
  end
  if not pick then
    for _, w in ipairs(WILD) do if not self.taken[w] then pick = w break end end
  end
  if not pick then
    self.fell = (self.fell or 0) + 1
    self.fellBy = self.fellBy or {}
    self.fellBy[n] = true
    return fallbackOf(n)
  end
  -- the slot's own layer (if it was resting there unclaimed) moves out
  local old = self.layer[pick]
  if self.slotOf[old] == pick then self.slotOf[old] = nil end
  self.layer[pick] = n
  self.slotOf[n] = pick
  self.taken[pick] = true
  return pick
end

-- Wildcards still resting on their own layer answer for it too.
function Assign:settle()
  for _, w in ipairs(WILD) do
    if not self.taken[w] and self.layer[w] == w then self.slotOf[w] = w end
  end
end

function Assign:snapshot()
  local s = { layer = {}, slotOf = {}, taken = {}, fellBy = {} }
  for k, v in pairs(self.fellBy or {}) do s.fellBy[k] = v end
  for k, v in pairs(self.layer) do s.layer[k] = v end
  for k, v in pairs(self.slotOf) do s.slotOf[k] = v end
  for k, v in pairs(self.taken) do s.taken[k] = v end
  return s
end
function Assign:restore(s)
  self.layer, self.slotOf, self.taken, self.fellBy = {}, {}, {}, {}
  for k, v in pairs(s.fellBy or {}) do self.fellBy[k] = v end
  for k, v in pairs(s.layer) do self.layer[k] = v end
  for k, v in pairs(s.slotOf) do self.slotOf[k] = v end
  for k, v in pairs(s.taken) do self.taken[k] = v end
end
function Assign:freeze() self:settle(); self.frozen = true end

-- The published form: layer and material per slot (dense, 1..32), the
-- wildcards, and how many were claimed.
function Assign:publish(gen)
  local out = { gen = gen, layer = {}, mat = {}, wild = {}, claimed = 0, fell = 0 }
  for _ in pairs(self.fellBy or {}) do out.fell = out.fell + 1 end
  for s = 1, 32 do
    out.layer[s] = self.layer[s]
    out.mat[s] = materialOf(self.layer[s])
  end
  for i, w in ipairs(WILD) do
    out.wild[i] = w
    if self.taken[w] and self.layer[w] ~= w then out.claimed = out.claimed + 1 end
  end
  return out
end

-- ── THE FORMATIONS ──────────────────────────────────────────────────────────
-- Per type, 2–3 variants (`w` their weight). Geologically plausible stacks:
-- what you would see in a road cut, a ravine wall and a cave on such a world.
local F = {}
FORMATIONS = F

F.archipelago = {
  { id = "basalt_shield", label = "Basalt shield", w = 3, low = "blacksand",
    subsoil = { "soil", "gravelregolith", d = { 1.5, 3 } }, strata = { "basalt", "pahoehoe", d = { 4, 10 } },
    deep = { "basalt" }, cave = { "basalt", "clinker" }, cliff = "columnar", band = "pahoehoe",
    hue = { 0.55, 0.65 }, sat = { 0.0, 0.06 } },
  { id = "granite_craton", label = "Granite craton", w = 2,
    subsoil = { "soil", d = { 0.5, 2 } }, strata = { "granite", "gneiss", d = { 6, 12 } },
    deep = { "gneiss" }, cave = { "granite" }, cliff = "granite", band = "gneiss", pocket = "quartzdruzy",
    hue = { 0.0, 0.06 }, sat = { 0.06, 0.2 } },
  { id = "coral_limestone", label = "Coral limestone", w = 2,
    subsoil = { "sand", "soil", d = { 1, 3 } }, strata = { "limestone", "chalk", d = { 8, 16 } },
    deep = { "limestone", "marble" }, cave = { "cavewall", "flowstone" }, cliff = "chalk", band = "limestone",
    hue = { 0.08, 0.14 }, sat = { 0.02, 0.12 } },
}
F.verdant = {
  { id = "peat_mudstone", label = "Peat over mudstone", w = 3,
    subsoil = { "peat", "soil", d = { 2, 4 } }, strata = { "mudstone", "shale", d = { 6, 12 } },
    deep = { "slate" }, cave = { "mudstone", "cavewall" }, cliff = "mudstone", band = "shale",
    hue = { 0.08, 0.15 }, sat = { 0.05, 0.18 } },
  { id = "loess_karst", label = "Loess over karst limestone", w = 2,
    subsoil = { "loess", d = { 3, 6 } }, strata = { "limestone", d = { 8, 16 } },
    deep = { "limestone", "marble" }, cave = { "cavewall", "dripstone", "flowstone" }, cliff = "limestone", band = "chalk",
    hue = { 0.09, 0.14 }, sat = { 0.02, 0.12 } },
  { id = "laterite_gneiss", label = "Laterite over gneiss", w = 2,
    subsoil = { "redregolith", "soil", d = { 2, 5 } }, strata = { "gneiss", "schist", d = { 6, 12 } },
    deep = { "gneiss" }, cave = { "gneiss", "granite" }, cliff = "gneiss", band = "schist",
    hue = { 0.0, 0.05 }, sat = { 0.12, 0.28 } },
}
F.alpine = {
  { id = "granite_schist", label = "Granite and schist", w = 3,
    subsoil = { "scree", "soil", d = { 1, 2.5 } }, strata = { "schist", "granite", d = { 6, 12 } },
    deep = { "granite" }, cave = { "granite", "schist" }, cliff = "schist", band = "granite", pocket = "quartzdruzy",
    hue = { 0.55, 0.65 }, sat = { 0.0, 0.06 } },
  { id = "slate_gneiss", label = "Slate and gneiss", w = 2,
    subsoil = { "scree", d = { 1, 2.5 } }, strata = { "slate", "gneiss", d = { 6, 12 } },
    deep = { "gneiss" }, cave = { "slate" }, cliff = "slate", band = "gneiss",
    hue = { 0.55, 0.7 }, sat = { 0.0, 0.08 } },
  { id = "limestone_nappe", label = "Limestone nappes", w = 2,
    subsoil = { "scree", "soil", d = { 1, 3 } }, strata = { "limestone", "marble", d = { 8, 14 } },
    deep = { "gneiss", "schist" }, cave = { "cavewall", "flowstone" }, cliff = "limestone", band = "marble",
    hue = { 0.08, 0.14 }, sat = { 0.0, 0.08 } },
}
F.canyon = {
  { id = "redbeds", label = "Red beds", w = 3, high = "redbeds",
    subsoil = { "redregolith", "laggravel", d = { 1.5, 3.5 } }, strata = { "sandstone", "redbeds", d = { 6, 14 } },
    deep = { "granite" }, cave = { "sandstone" }, cliff = "redbeds", band = "sandstone", seam = "hematite",
    hue = { 0.02, 0.07 }, sat = { 0.25, 0.45 } },
  { id = "greystack", label = "Shale and limestone", w = 2, high = "limestone",
    subsoil = { "soil", "scree", d = { 1, 3 } }, strata = { "limestone", "shale", d = { 8, 16 } },
    deep = { "gneiss" }, cave = { "cavewall" }, cliff = "limestone", band = "shale", pocket = "quartzdruzy",
    hue = { 0.08, 0.14 }, sat = { 0.02, 0.14 } },
  { id = "conglomerate_tuff", label = "Conglomerate and tuff", w = 2, high = "tuff",
    subsoil = { "laggravel", "scree", d = { 1, 3 } }, strata = { "tuff", "flagstone", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "tuff" }, cliff = "tuff", band = "mudstone",
    hue = { 0.04, 0.1 }, sat = { 0.1, 0.25 } },
}
F.steppe = {
  { id = "loess_chalk", label = "Loess over chalk", w = 3,
    subsoil = { "loess", d = { 3, 6 } }, strata = { "chalk", "limestone", d = { 8, 16 } },
    deep = { "limestone" }, cave = { "chalk", "cavewall" }, cliff = "chalk", band = "limestone",
    hue = { 0.09, 0.14 }, sat = { 0.02, 0.1 } },
  { id = "flood_basalt", label = "Flood basalt plain", w = 2,
    subsoil = { "soil", "loess", d = { 1.5, 3.5 } }, strata = { "basalt", d = { 6, 14 } },
    deep = { "basalt" }, cave = { "basalt", "clinker" }, cliff = "columnar", band = "basalt",
    hue = { 0.05, 0.12 }, sat = { 0.0, 0.08 } },
  { id = "sandstone_platform", label = "Sandstone platform", w = 2,
    subsoil = { "soil", "sand", d = { 1.5, 3 } }, strata = { "sandstone", d = { 6, 14 } },
    deep = { "granite" }, cave = { "sandstone" }, cliff = "sandstone", band = "mudstone",
    hue = { 0.06, 0.11 }, sat = { 0.1, 0.25 } },
}
F.dune = {
  { id = "quartz_erg", label = "Quartz sand over sandstone", w = 3,
    subsoil = { "sandstone", d = { 1.5, 4 } }, strata = { "sandstone", "redbeds", d = { 6, 14 } },
    deep = { "granite" }, cave = { "sandstone" }, cliff = "sandstone", band = "redbeds",
    hue = { 0.07, 0.12 }, sat = { 0.18, 0.35 } },
  { id = "gypsum_dunes", label = "Gypsum dunes", w = 2, surfaceSat = 0.03,
    subsoil = { "chalk", d = { 1.5, 4 } }, strata = { "chalk", "halite", d = { 6, 12 } },
    deep = { "limestone" }, cave = { "halite", "flowstone" }, cliff = "chalk", band = "halite", pocket = "quartzdruzy",
    hue = { 0.1, 0.14 }, sat = { 0.0, 0.06 } },
  { id = "black_erg", label = "Black volcanic sand", w = 1.5, high = "blacksand", low = "blacksand",
    subsoil = { "ash", d = { 1, 3 } }, strata = { "basalt", "tuff", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "basalt" }, cliff = "basalt", band = "tuff",
    hue = { 0.0, 0.08 }, sat = { 0.0, 0.1 } },
}
F.saltflat = {
  { id = "halite_mud", label = "Halite over mud", w = 3,
    subsoil = { "mudcrack", d = { 1, 2.5 } }, strata = { "halite", "mudstone", d = { 4, 10 } },
    deep = { "mudstone", "shale" }, cave = { "halite" }, cliff = "mudstone", band = "halite", pocket = "quartzdruzy",
    hue = { 0.06, 0.12 }, sat = { 0.03, 0.15 } },
  { id = "gypsum_clay", label = "Gypsum over clay", w = 2,
    subsoil = { "mudcrack", d = { 1, 3 } }, strata = { "chalk", "mudstone", d = { 6, 12 } },
    deep = { "shale" }, cave = { "chalk" }, cliff = "chalk", band = "mudstone",
    hue = { 0.08, 0.13 }, sat = { 0.0, 0.08 } },
  { id = "borate_crust", label = "Borate crust over tuff", w = 1.5,
    subsoil = { "mudcrack", d = { 1, 2 } }, strata = { "tuff", "halite", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "tuff" }, cliff = "tuff", band = "redbeds",
    hue = { 0.04, 0.1 }, sat = { 0.05, 0.18 } },
}
F.ironred = {
  { id = "hematite_basalt", label = "Hematite regolith over basalt", w = 3,
    subsoil = { "redregolith", "hematite", d = { 1, 3 } }, strata = { "basalt", "rust", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "basalt", "scoria" }, cliff = "rust", band = "scoria", seam = "hematite",
    hue = { 0.0, 0.05 }, sat = { 0.22, 0.42 } },
  { id = "goethite_sandstone", label = "Duricrust over sandstone", w = 2,
    subsoil = { "redregolith", "laggravel", d = { 1.5, 3.5 } }, strata = { "redbeds", "sandstone", d = { 6, 14 } },
    deep = { "granite" }, cave = { "sandstone" }, cliff = "redbeds", band = "gossan", seam = "gossan",
    hue = { 0.03, 0.08 }, sat = { 0.28, 0.48 } },
}
F.tundra = {
  { id = "permafrost_shale", label = "Permafrost silt over shale", w = 3,
    subsoil = { "loess", "gravelregolith", d = { 2, 4 } }, strata = { "shale", "mudstone", d = { 6, 12 } },
    deep = { "slate" }, cave = { "frost" }, cliff = "shale", band = "mudstone",
    hue = { 0.55, 0.62 }, sat = { 0.0, 0.08 } },
  { id = "till_granite", label = "Glacial till over granite", w = 2,
    subsoil = { "scree", "gravelregolith", d = { 1.5, 3.5 } }, strata = { "granite", "gneiss", d = { 6, 12 } },
    deep = { "granite" }, cave = { "frost", "granite" }, cliff = "granite", band = "gneiss",
    hue = { 0.55, 0.62 }, sat = { 0.0, 0.06 } },
}
F.glacial = {
  { id = "clearice_basalt", label = "Clear ice over basalt", w = 3,
    subsoil = { "firn", d = { 2, 4 } }, strata = { "clearice", "bandedice", d = { 8, 16 } },
    deep = { "basalt" }, cave = { "clearice", "bandedice" }, cliff = "bandedice", band = "clearice",
    hue = { 0.52, 0.6 }, sat = { 0.04, 0.18 } },
  { id = "firn_granite", label = "Firn over granite", w = 2,
    subsoil = { "firn", "snow", d = { 2, 5 } }, strata = { "glacier", "firn", d = { 8, 16 } },
    deep = { "granite" }, cave = { "clearice", "frost" }, cliff = "granite", band = "bandedice",
    hue = { 0.54, 0.62 }, sat = { 0.02, 0.12 } },
  { id = "dirtyice_regolith", label = "Dirty ice over regolith", w = 2,
    subsoil = { "dirtyice", d = { 1.5, 3 } }, strata = { "dirtyice", "glacier", d = { 6, 14 } },
    deep = { "basalt" }, cave = { "dirtyice" }, cliff = "dirtyice", band = "bandedice",
    hue = { 0.08, 0.14 }, sat = { 0.02, 0.1 } },
}
F.volcanic = {
  { id = "pahoehoe_aa", label = "Pahoehoe and a'a", w = 3,
    subsoil = { "ash", "clinker", d = { 0.5, 1.5 } }, strata = { "pahoehoe", "clinker", d = { 4, 10 } },
    deep = { "basalt" }, cave = { "soot", "pahoehoe" }, cliff = "basalt", band = "clinker",
    hue = { 0.0, 0.06 }, sat = { 0.0, 0.1 } },
  { id = "columnar", label = "Columnar basalt", w = 2,
    subsoil = { "ash", d = { 0.5, 2 } }, strata = { "basalt", "columnar", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "basalt", "soot" }, cliff = "columnar", band = "obsidian",
    hue = { 0.55, 0.65 }, sat = { 0.0, 0.06 } },
  { id = "tuff_scoria", label = "Tuff and scoria", w = 2,
    subsoil = { "ash", "scoria", d = { 1, 2.5 } }, strata = { "tuff", "scoria", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "tuff" }, cliff = "tuff", band = "scoria",
    hue = { 0.0, 0.07 }, sat = { 0.06, 0.2 } },
}
F.sulfur = {
  { id = "sulfur_basalt", label = "Sulfur crust over basalt", w = 3,
    subsoil = { "ash", d = { 0.5, 2 } }, strata = { "basalt", "sulfurvein", d = { 4, 10 } },
    deep = { "basalt" }, cave = { "soot", "sulfurvein" }, cliff = "basalt", band = "sulfurvein", seam = "sulfurvein",
    hue = { 0.1, 0.15 }, sat = { 0.08, 0.28 } },
  { id = "sinter_tuff", label = "Sinter over tuff", w = 2,
    subsoil = { "ash", d = { 1, 2.5 } }, strata = { "tuff", "flowstone", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "flowstone", "sulfurvein" }, cliff = "tuff", band = "flowstone", seam = "sulfurvein",
    hue = { 0.1, 0.14 }, sat = { 0.06, 0.22 } },
}
F.greenhouse = {
  { id = "tesserae_basalt", label = "Tesserae basalt", w = 3,
    subsoil = { "ash", "scree", d = { 1, 2.5 } }, strata = { "basalt", "shale", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "basalt", "soot" }, cliff = "basalt", band = "scoria",
    hue = { 0.05, 0.1 }, sat = { 0.1, 0.28 } },
  { id = "anorthosite_highland", label = "Anorthosite highlands", w = 2,
    subsoil = { "dust", "regolith", d = { 1, 3 } }, strata = { "gneiss", "granite", d = { 6, 12 } },
    deep = { "granite" }, cave = { "granite" }, cliff = "gneiss", band = "flagstone",
    hue = { 0.07, 0.12 }, sat = { 0.06, 0.2 } },
}
F.crystal = {
  { id = "quartz_slate", label = "Quartz veins in slate", w = 3,
    subsoil = { "regolith", "scree", d = { 1, 3 } }, strata = { "slate", "schist", d = { 6, 12 } },
    deep = { "slate" }, cave = { "quartzdruzy", "slate" }, cliff = "schist", band = "slate",
    hue = { 0.6, 0.8 }, sat = { 0.04, 0.18 } },
  { id = "geode_tuff", label = "Geode-rich tuff", w = 2,
    subsoil = { "regolith", d = { 1, 3 } }, strata = { "tuff", "obsidian", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "tuff", "quartzdruzy" }, cliff = "tuff", band = "obsidian",
    hue = { 0.62, 0.82 }, sat = { 0.06, 0.2 } },
}
F.titan = {
  { id = "tholin_ice", label = "Tholin over water-ice bedrock", w = 3,
    subsoil = { "ash", "dirtyice", d = { 1, 3 } }, strata = { "bandedice", "dirtyice", d = { 6, 14 } },
    deep = { "clearice" }, cave = { "clearice", "bandedice" }, cliff = "dirtyice", band = "bandedice",
    hue = { 0.06, 0.1 }, sat = { 0.2, 0.4 } },
  { id = "clathrate_dunes", label = "Methane-clathrate dunes", w = 2,
    subsoil = { "ash", d = { 1.5, 3.5 } }, strata = { "glacier", "firn", d = { 6, 14 } },
    deep = { "clearice" }, cave = { "glacier", "frost" }, cliff = "bandedice", band = "glacier",
    hue = { 0.07, 0.11 }, sat = { 0.15, 0.32 } },
}
F.frost = {
  { id = "banded_basalt", label = "Banded ice over basalt", w = 3,
    subsoil = { "gravelregolith", "regolith", d = { 1, 3 } }, strata = { "bandedice", "clearice", d = { 6, 14 } },
    deep = { "basalt" }, cave = { "bandedice", "frost" }, cliff = "bandedice", band = "basalt",
    hue = { 0.52, 0.6 }, sat = { 0.04, 0.16 } },
  { id = "dirty_regolith", label = "Dirty ice over regolith", w = 2,
    subsoil = { "regolith", "dust", d = { 1, 3 } }, strata = { "dirtyice", d = { 6, 12 } },
    deep = { "slate" }, cave = { "dirtyice", "frost" }, cliff = "dirtyice", band = "slate",
    hue = { 0.08, 0.6 }, sat = { 0.0, 0.08 } },
}
F.regolith = {
  { id = "highland_anorthosite", label = "Highland anorthosite", w = 3,
    subsoil = { "regolith", "dust", d = { 2, 5 } }, strata = { "flagstone", "gneiss", d = { 6, 12 } },
    deep = { "granite" }, cave = { "flagstone" }, cliff = "flagstone", band = "gneiss",
    hue = { 0.0, 1.0 }, sat = { 0.0, 0.05 } },
  { id = "mare_breccia", label = "Mare basalt breccia", w = 2,
    subsoil = { "gravelregolith", "regolith", d = { 2, 4 } }, strata = { "basalt", "scoria", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "basalt" }, cliff = "basalt", band = "scoria",
    hue = { 0.0, 1.0 }, sat = { 0.0, 0.05 } },
}
F.maria = {
  { id = "kreep_basalt", label = "Basalt with KREEP", w = 3,
    subsoil = { "regolith", "dust", d = { 2, 4 } }, strata = { "basalt", "pahoehoe", d = { 6, 12 } },
    deep = { "basalt" }, cave = { "pahoehoe", "basalt" }, cliff = "basalt", band = "pahoehoe",
    hue = { 0.05, 0.12 }, sat = { 0.0, 0.06 } },
  { id = "impact_melt", label = "Impact-melt breccia", w = 2,
    subsoil = { "gravelregolith", d = { 2, 4 } }, strata = { "scoria", "basalt", d = { 6, 12 } },
    deep = { "granite" }, cave = { "scoria", "basalt" }, cliff = "scoria", band = "flagstone",
    hue = { 0.04, 0.1 }, sat = { 0.0, 0.08 } },
}

-- ── PICKING ─────────────────────────────────────────────────────────────────

local function lerp(a, b, t) return a + (b - a) * t end
local function clamp01(x) return math.max(0, math.min(1, x)) end
local function pickList(list, u)
  local n = #list
  if n == 0 then return nil end
  return list[math.min(n, 1 + math.floor(clamp01(u) * n))]
end

-- The formation a world of `type` rolls, from one uniform draw `u` in [0,1)
-- (the generator spends the draw version 2 spent on its strata pick, so the
-- rng sequence never moves), and where `u` fell inside that formation's share
-- (a second uniform in [0,1), which picks the strata). nil for a type with
-- no table.
function variantFor(u, type)
  local list = F[type]
  if not list then return nil end
  local total = 0
  for _, f in ipairs(list) do total = total + (f.w or 1) end
  local x = clamp01(u) * total
  for _, f in ipairs(list) do
    local w = f.w or 1
    if x < w then return f, clamp01(x / w) end
    x = x - w
  end
  return list[#list], 0.5
end

-- The layer stack of formation `f` for one world, from the world's draws
-- `d` (all uniform in [0,1); a missing one counts 0.5):
--   sub        which subsoil name          subH, subS   its tint
--   strata     which strata name           strataH, strataS   its tint
--   deep       which basement and cave     deepH        their tint
--   weather    weathering 0 fresh … 1 worn (darker, greyer rock)
--   subD, strataD                          the thicknesses
-- → { subsoil, strata, deep, cave, cliff, band, pocket, seam = { name, h, s, v } or nil,
--     high, low, patch (names or nil), surfaceSat, subsoilDepth, strataDepth, weather }
function stackOpts(f, d)
  d = d or {}
  local function u(k) local v = d[k]; return (v == nil) and 0.5 or clamp01(v) end
  local hue, sat = f.hue or { 0, 1 }, f.sat or { 0, 0.1 }
  local w = u("weather")
  local function tint(name, hu, su, v)
    if not name then return nil end
    local h = lerp(hue[1], hue[2], hu) % 1
    local s = lerp(sat[1], sat[2], su) * (1 - 0.35 * w)
    return { name = name, h = h, s = s, v = v - 0.06 * w }
  end
  local sub = f.subsoil or { "regolith", d = { 1.5, 4 } }
  local str = f.strata or { "shale", d = { 6, 14 } }
  local deepList, caveList = f.deep or { "granite" }, f.cave or f.deep or { "granite" }
  local out = {
    id = f.id, label = f.label,
    subsoil = tint(pickList(sub, u("sub")), u("subH"), u("subS"), 0.58),
    strata = tint(pickList(str, u("strata")), u("strataH"), u("strataS"), 0.6),
    deep = tint(pickList(deepList, u("deep")), u("deepH"), 0.5, 0.56),
    cave = tint(pickList(caveList, u("deep")), u("deepH"), 0.5, 0.56),
    cliff = tint(f.cliff, u("strataH"), u("strataS"), 0.62),
    band = tint(f.band, u("deepH"), u("subS"), 0.62),
    pocket = f.pocket and { name = f.pocket } or nil,
    seam = f.seam and { name = f.seam } or nil,
    high = f.high, low = f.low, patch = f.patch, surfaceSat = f.surfaceSat,
    weather = w,
  }
  local sd, td = sub.d or { 1.5, 4 }, str.d or { 6, 14 }
  out.subsoilDepth = lerp(sd[1], sd[2], u("subD"))
  out.strataDepth = lerp(td[1], td[2], u("strataD"))
  return out
end

-- Every layer name a formation can lay (for the tests and paletteNeeds).
function namesOf(f)
  local out, seen = {}, {}
  local function add(n) if n and not seen[n] then seen[n] = true; out[#out + 1] = n end end
  for _, k in ipairs({ "high", "low", "patch", "cliff", "band", "pocket", "seam" }) do add(f[k]) end
  for _, k in ipairs({ "subsoil", "strata", "deep", "cave" }) do
    for _, n in ipairs(f[k] or {}) do add(n) end
  end
  return out
end

-- The palette a system needs: given its worlds in roll order (each a stack
-- from stackOpts, or a list of layer names), the assignment greedy claims
-- give. The generator claims as it rolls and lands on the same answer.
local CLAIM_ORDER = { "high", "low", "cliff", "band", "strata", "cave", "subsoil", "pocket", "seam" }
function paletteNeeds(system)
  local a = newAssign()
  for _, w in ipairs(system or {}) do
    local list = {}
    if w[1] ~= nil then
      for _, n in ipairs(w) do list[#list + 1] = type(n) == "number" and n or LAYER[n] end
    else
      for _, k in ipairs(CLAIM_ORDER) do
        local e = w[k]
        local n = type(e) == "table" and e.name or e
        if n then list[#list + 1] = LAYER[n] end
      end
    end
    -- per world, as the generator commits: old wildcard layers first
    for _, n in ipairs(list) do if IS_WILD[n] then a:claim(n) end end
    for _, n in ipairs(list) do a:claim(n) end
  end
  a:settle()
  return a
end
