-- MATERIALS — the registry every harvested, mined, hauled and sold thing is
-- weighed and valued by. One table, one truth: the inventory weighs a unit
-- through here, the depot prices it through here, and the tool that produced
-- it only ever names an id.
--
-- A unit is "one handful you can carry" — the numbers are per unit, and mass is
-- what actually limits you (a suit pack carries 90 kg; a cargo hold hundreds).
-- A unit of ground (ore, rock, ice, loose soil) is a LITRE of it, so its kg
-- is its density: solid rock at its own (granite 2.7, basalt 2.9), loose
-- ground at its bulk (soil 1.5, gravel 1.9, regolith 1.8), an ore at a rich
-- ore's, about 60% of the mineral in its rock (iron ore 4.2 of hematite's
-- 5.3, uranite 6.8 of uraninite's 9.5, sperrylite 7.4 of 10.6). Until the
-- audit of 2026-11-04 the ores weighed like common rock (iron ore 2.6,
-- uranite 3.2, kamacite metal 4.6, silica and resonant crystal at half of
-- quartz's 2.65); each one's price per unit moved with its weight, so a
-- pack of it is worth what it was. Flora is counted in pieces, not litres.
-- Value is what the depot pays at reputation 0; standing moves the price, the
-- registry doesn't.
--
--     local M = findScript("materials")
--     M.name("iron")            "Iron Ore"
--     M.massOf("iron", 12)      kg for twelve units
--     M.pickOre("canyon", 18.5, r)   what this planet yields at that depth
--
-- WHERE things come from is registry data too (`BANDS`): rock yields by planet
-- archetype and depth, so a canyon world's shallow dirt is iron and silica while
-- uranite only ever shows up 25 m down. Flora yields live with the species that
-- grow them (`flora_gen`), because those are rolled per planet.

defaults = {}

-- id → { name, kg (per unit), value ($/unit at rep 0), tier, class }
--
-- PRICED BY THE KILOGRAM, because the suit pack is limited by mass (90 kg) and
-- a trip home is one pack. The old table paid $590 for a pack of shallow canyon
-- rock and $1,500 for a pack of timber — against a $1,100 rocket, one minute of
-- harvest cutter bought a launch and the contract ladder stopped mattering.
--
-- Now a pack of common stuff is worth about $150–300 at reputation 0, a trip
-- (fill + walk + sell) takes two or three minutes, and the money that makes the
-- first five minutes feel earned is the DISCOVERY premium on each first sale
-- (facility_menu's depot). What's worth flying for is dense in $/kg: crystal,
-- uranite and glow sap, and the off-world materials the haul contracts ask for.
--
--   $/kg  regolith 1.1 · silica/iron 3.1 · copper 5 · ice 4 · sulfur/obsidian 10
--         crystal 55 · uranite 34 · timber/fiber/biomass 3.3 · kelp 6 · resin 9
--         spores 15 · glow sap 43
-- class: "ore" | "ice" | "flora" | "liquid" | "refined"
REG = {
  regolith = { name = "Regolith",         kg = 1.8, value = 2,   tier = 0, class = "ore" },
  silica   = { name = "Silica",           kg = 2.6, value = 8,   tier = 1, class = "ore" },
  iron     = { name = "Iron Ore",         kg = 4.2, value = 13,  tier = 1, class = "ore" },
  copper   = { name = "Copper Ore",       kg = 3.6, value = 18,  tier = 1, class = "ore" },
  ice      = { name = "Water Ice",        kg = 0.92, value = 4,   tier = 1, class = "ice" },
  water    = { name = "Water",            kg = 1.0, value = 3,   tier = 1, class = "liquid" },
  sulfur   = { name = "Sulfur",           kg = 2.0, value = 20,  tier = 2, class = "ore" },
  obsidian = { name = "Obsidian",         kg = 2.4, value = 24,  tier = 2, class = "ore" },
  crystal  = { name = "Resonant Crystal", kg = 2.6, value = 142, tier = 3, class = "ore" },
  uranium  = { name = "Uranite",          kg = 6.8, value = 234, tier = 3, class = "ore" },

  -- WHAT THE GROUND IS MADE OF (the terrain palette, `SLOT` below): what the
  -- laser cuts out of a hillside is the rock you can see in it. Bulk, cheap,
  -- heavy — the spoil a tunnel makes on the way to the ore. `grade` tells
  -- them apart from the ore proper (class stays "ore" so the depot, the fill
  -- canister and the old contracts treat all dug rock alike).
  soil      = { name = "Soil",             kg = 1.5, value = 1,   tier = 0, class = "ore", grade = "bulk" },
  sand      = { name = "Sand",             kg = 1.6, value = 1,   tier = 0, class = "ore", grade = "bulk" },
  clay      = { name = "Clay",             kg = 1.7, value = 2,   tier = 0, class = "ore", grade = "bulk" },
  gravel    = { name = "Gravel",           kg = 1.9, value = 1,   tier = 0, class = "ore", grade = "bulk" },
  ash       = { name = "Volcanic Ash",     kg = 0.9, value = 1,   tier = 0, class = "ore", grade = "bulk" },
  basalt    = { name = "Basalt",           kg = 2.9, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  granite   = { name = "Granite",          kg = 2.7, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  sandstone = { name = "Sandstone",        kg = 2.3, value = 2,   tier = 0, class = "ore", grade = "bulk" },
  limestone = { name = "Limestone",        kg = 2.5, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  shale     = { name = "Shale",            kg = 2.4, value = 2,   tier = 0, class = "ore", grade = "bulk" },
  slate     = { name = "Slate",            kg = 2.7, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  rustrock  = { name = "Rust Rock",        kg = 2.6, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  veinstone = { name = "Veinstone",        kg = 2.6, value = 4,   tier = 0, class = "ore", grade = "bulk" },
  hematite  = { name = "Hematite Earth",   kg = 3.0, value = 5,   tier = 0, class = "ore", grade = "bulk" },
  salt      = { name = "Rock Salt",        kg = 2.1, value = 3,   tier = 0, class = "ore", grade = "bulk" },
  onyx      = { name = "Banded Onyx",      kg = 2.6, value = 8,   tier = 1, class = "ore", grade = "bulk" },

  timber   = { name = "Timber",           kg = 1.2, value = 4,   tier = 1, class = "flora" },
  fiber    = { name = "Plant Fiber",      kg = 0.3, value = 1,   tier = 1, class = "flora" },
  biomass  = { name = "Biomass",          kg = 0.6, value = 2,   tier = 1, class = "flora" },
  resin    = { name = "Resin",            kg = 0.9, value = 8,   tier = 2, class = "flora" },
  spores   = { name = "Spore Pods",       kg = 0.4, value = 6,   tier = 2, class = "flora" },
  kelp     = { name = "Kelp",             kg = 0.8, value = 5,   tier = 2, class = "flora" },
  glowsap  = { name = "Glow Sap",         kg = 0.7, value = 30,  tier = 3, class = "flora" },

  -- OFF-WORLD ORES (`ORE` below says where each forms): what the moons and the
  -- other planets hold that the home world does not. Dense in $/kg and in
  -- research, because each one is a trip.
  ilmenite    = { name = "Ilmenite",             kg = 3.9, value = 42,  tier = 2, class = "ore" },
  he3         = { name = "Helium-3 Regolith",    kg = 1.6, value = 70,  tier = 3, class = "ore" },
  kreep       = { name = "KREEP Basalt",         kg = 2.9, value = 45,  tier = 2, class = "ore" },
  kamacite    = { name = "Kamacite",             kg = 7.5, value = 65,  tier = 2, class = "ore" },
  sperrylite  = { name = "Sperrylite",           kg = 7.4, value = 321, tier = 4, class = "ore" },
  monazite    = { name = "Monazite",             kg = 4.1, value = 123, tier = 3, class = "ore" },
  ammonia_ice = { name = "Ammonia Ice",          kg = 0.82, value = 16,  tier = 2, class = "ore" },
  clathrate   = { name = "Methane Clathrate",    kg = 0.9, value = 26,  tier = 2, class = "ore" },
  tholin      = { name = "Tholin Tar",           kg = 1.3, value = 50,  tier = 3, class = "ore" },
  -- (fictional, under scripts/codex.lua's rules of this universe)
  phasite     = { name = "Phasite",              kg = 2.1, value = 220, tier = 4, class = "ore" },
  cryovolt    = { name = "Cryovolt Glass",       kg = 1.4, value = 180, tier = 4, class = "ore" },
}

-- The DISCOVERY PREMIUM: what the depot adds the first time a material is ever
-- sold. Paid once per material per company, so it is the opening's money — six
-- or seven common materials on the home world are about $1,800 between them —
-- and the reason a strange rock from another world is worth a special trip.
function discoveryBonus(id)
  return 100 * (1 + 2 * tier(id))
end

-- Rock yields per planet archetype. `w` is the raw weight; `minDepth` gates a
-- material to below that depth (metres under the surface) and `deep` multiplies
-- its weight the further down you are, so the interesting stuff is genuinely
-- worth the tunnel. Every list keeps regolith as the always-available filler —
-- there is no such thing as a dig that yields nothing.
BANDS = {
  canyon = {
    { mat = "regolith", w = 6.0 },
    { mat = "silica",   w = 2.5 },
    { mat = "iron",     w = 3.0, minDepth = 2,  deep = 1.4 },
    { mat = "copper",   w = 1.4, minDepth = 6,  deep = 1.6 },
    { mat = "crystal",  w = 0.3, minDepth = 20, deep = 2.0 },
    { mat = "uranium",  w = 0.15, minDepth = 25, deep = 2.2 },
  },
  dune = {
    { mat = "regolith", w = 7.0 },
    { mat = "silica",   w = 4.5 },
    { mat = "iron",     w = 1.8, minDepth = 4,  deep = 1.4 },
    { mat = "sulfur",   w = 1.2, minDepth = 8,  deep = 1.5 },
    { mat = "copper",   w = 0.8, minDepth = 12, deep = 1.6 },
    { mat = "uranium",  w = 0.1,  minDepth = 28, deep = 2.2 },
  },
  ice = {
    { mat = "ice",      w = 7.0 },
    { mat = "regolith", w = 2.0 },
    { mat = "silica",   w = 1.2, minDepth = 3 },
    { mat = "iron",     w = 1.0, minDepth = 10, deep = 1.5 },
    { mat = "crystal",  w = 0.4, minDepth = 22, deep = 2.0 },
  },
  frost = {
    { mat = "ice",      w = 6.0 },
    { mat = "regolith", w = 3.0 },
    { mat = "iron",     w = 1.2, minDepth = 8,  deep = 1.5 },
    { mat = "copper",   w = 0.6, minDepth = 14, deep = 1.6 },
  },
  lava = {
    { mat = "regolith", w = 4.0 },
    { mat = "obsidian", w = 3.0 },
    { mat = "sulfur",   w = 2.6 },
    { mat = "iron",     w = 2.4, minDepth = 3,  deep = 1.5 },
    { mat = "copper",   w = 1.6, minDepth = 8,  deep = 1.7 },
    { mat = "uranium",  w = 0.35, minDepth = 18, deep = 2.4 },
  },
  crystal = {
    { mat = "regolith", w = 3.5 },
    { mat = "silica",   w = 3.0 },
    { mat = "crystal",  w = 2.2, deep = 2.0 },
    { mat = "copper",   w = 1.2, minDepth = 6 },
    { mat = "uranium",  w = 0.3, minDepth = 20, deep = 2.2 },
  },
  barren = {
    { mat = "regolith", w = 7.0 },
    { mat = "silica",   w = 2.0 },
    { mat = "iron",     w = 2.0, minDepth = 3, deep = 1.4 },
    { mat = "copper",   w = 0.7, minDepth = 10, deep = 1.6 },
    { mat = "uranium",  w = 0.2, minDepth = 22, deep = 2.2 },
  },
}

function byId(id)
  return REG[id]
end

-- The display name. Called `label` rather than `name` because for most of this
-- project's life a script handle answered `name` itself, so `materials.name(id)`
-- worked from inside this file and from nowhere else — every caller got the
-- string "materials" back and died on the call, which broke the mining laser's
-- readout, the pickup line, the depot's stock list and the research panel
-- (floptle/0085). v0.33.0 gave `name` back to the game, so this could be renamed
-- again; it is not, because `label` is the better name for what it returns and
-- because a rename buys nothing a player can see.
function label(id)
  local d = REG[id]
  return d and d.name or tostring(id)
end

function kg(id)
  local d = REG[id]
  return d and d.kg or 1.0
end

function value(id)
  local d = REG[id]
  return d and d.value or 0
end

function tier(id)
  local d = REG[id]
  return d and d.tier or 0
end

function class(id)
  local d = REG[id]
  return d and d.class or "ore"
end

function massOf(id, n)
  return kg(id) * (n or 0)
end

function valueOf(id, n)
  return value(id) * (n or 0)
end

-- Every id, ordered the one way panels list them: tier, then name. Stable —
-- a warehouse readout must never reshuffle between frames.
function list()
  local out = {}
  for id in pairs(REG) do out[#out + 1] = id end
  table.sort(out, function(a, b)
    local ta, tb = REG[a].tier, REG[b].tier
    if ta ~= tb then return ta < tb end
    return REG[a].name < REG[b].name
  end)
  return out
end

-- What a dig at `depth` metres under an archetype's surface turns up. `roll` is
-- a number in [0,1) — pass a seeded one (rng) and the same hole always yields
-- the same thing, which is what makes a rich seam a PLACE rather than a
-- slot machine you can stand still and pull.
function pickOre(kind, depth, roll)
  local bands = BANDS[kind] or BANDS.barren
  depth = math.max(0, depth or 0)
  local total, weights = 0, {}
  for i, b in ipairs(bands) do
    local w = 0
    if depth >= (b.minDepth or 0) then
      w = b.w
      if b.deep then
        -- Weight climbs with depth past the gate, saturating at 3× so a deep
        -- shaft is richer without ever making regolith impossible.
        local over = (depth - (b.minDepth or 0)) / 20.0
        w = w * (1.0 + math.min(2.0, over * (b.deep - 1.0) * 2.0))
      end
    end
    weights[i] = w
    total = total + w
  end
  if total <= 0 then return "regolith" end
  local pick = (roll or 0) * total
  for i, b in ipairs(bands) do
    pick = pick - weights[i]
    if pick <= 0 then return b.mat end
  end
  return bands[1].mat
end

-- The materials an archetype can produce at all — used by the survey readout
-- and by contracts that ask for something specific.
function oresOf(kind)
  local out = {}
  for _, b in ipairs(BANDS[kind] or BANDS.barren) do out[#out + 1] = b.mat end
  return out
end

-- ── what the ground is made of ──────────────────────────────────────────────
-- The terrain palette (terrain/system.palette, system_generator GEO_SLOT): each
-- slot is a texture, and the material a dig takes out of it is the one the
-- texture shows. The laser asks `terrain.slotAt` before it cuts (the reticle)
-- and `terrain.yields` after (what the cut actually removed, by slot), and both
-- answer through this table — so the crosshair never promises what the cut
-- does not deliver, and nothing comes out of a hillside that isn't in it.
--
-- Slots 5–8 are what the generator lays as DEPOSITS: veinstone seams (a low
-- copper-bearing rock) and the glow slots its ore pockets and seams are painted in (6 magma veins:
-- uranite; 7 amethyst, 8 blue crystal: resonant crystal). Everything else is
-- the country rock and soil. The ore veins mineral_field paints near the
-- surface use the slots in `VEIN_SLOTS`; a slot shared with a world's own
-- ground (hematite deserts, sulfur plains) reads as that ground everywhere
-- except inside a vein (mineral_field.veinAt), where it is the vein's ore.
SLOT = {
  [1] = "rustrock", [2] = "soil", [3] = "slate", [4] = "onyx", [5] = "veinstone",
  [6] = "uranium", [7] = "crystal", [8] = "crystal", [9] = "slate", [10] = "regolith",
  [11] = "regolith", [12] = "ice", [13] = "basalt", [14] = "granite", [15] = "sandstone",
  [16] = "sand", [17] = "regolith", [18] = "salt", [19] = "clay", [20] = "soil",
  [21] = "ash", [22] = "ice", [23] = "ice", [24] = "gravel", [25] = "limestone",
  [26] = "sulfur", [27] = "hematite", [28] = "soil", [29] = "basalt", [30] = "shale",
  [31] = "soil", [32] = "soil",
}

-- The material of a palette slot (nil / 0 = untextured ground: regolith).
function ofSlot(slot)
  return (slot and SLOT[slot]) or "regolith"
end

-- How hard a material is to cut, against plain rock (1). The laser's bite and
-- its pace are divided by it: soil goes fast, an ore seam a little slower than
-- the rock round it, crystal slowest — so breaking into a vein is felt.
local HARD_GRADE = { bulk = 1.0 }
HARD = {
  soil = 0.7, sand = 0.7, ash = 0.7, gravel = 0.8, clay = 0.85, regolith = 0.85, ice = 0.8,
  salt = 0.9, sandstone = 0.95, shale = 0.95, limestone = 1.0, rustrock = 1.0, slate = 1.05,
  veinstone = 1.1, hematite = 1.0, basalt = 1.15, granite = 1.2, onyx = 1.2, obsidian = 1.25,
  silica = 1.0, iron = 1.45, copper = 1.4, sulfur = 1.3, uranium = 1.55, crystal = 1.65, geode = 1.7,
  ilmenite = 1.5, he3 = 0.8, kreep = 1.3, kamacite = 1.6, sperrylite = 1.75, monazite = 1.5,
  ammonia_ice = 0.75, clathrate = 0.85, tholin = 0.9, phasite = 1.8, cryovolt = 1.7,
}
function hardness(id)
  return HARD[id] or HARD_GRADE[grade(id)] or 1.0
end

-- "bulk" (rock and soil), "ore" (what veins and pockets hold), or "flora"/
-- "liquid"/"refined" from the class.
function grade(id)
  local d = REG[id]
  if not d then return "ore" end
  if d.grade then return d.grade end
  if d.class == "ore" then return id == "regolith" and "bulk" or "ore" end
  return d.class
end
function isOre(id) return grade(id) == "ore" end

-- The palette slots an ore's VEINS are painted in, best first: the texture is
-- the ore's look (hematite for iron, the orange veinstone for copper, sulfur,
-- the glow crystal and magma slots for crystal and uranite). mineral_field
-- takes the first slot that is not the ground the vein crops out of.
VEIN_SLOTS = {
  iron = { 27, 4, 9, 1 }, copper = { 5, 1 }, sulfur = { 26, 5 }, obsidian = { 4, 13 },
  crystal = { 7, 8 }, uranium = { 6 },
  ilmenite = { 13, 4, 9, 29 }, he3 = { 11, 10, 17, 18 }, kreep = { 29, 13, 3 },
  kamacite = { 9, 27, 4, 14 }, sperrylite = { 9, 14, 4, 3 }, monazite = { 15, 1, 5, 25 },
  ammonia_ice = { 12, 23, 22 }, clathrate = { 23, 12, 18, 22 }, tholin = { 31, 21, 19, 2 },
  phasite = { 8, 7 }, cryovolt = { 8, 12, 7 },
}

-- The ores a world of archetype `kind` carries in its veins, with weights:
-- BANDS without the bulk fillers, the deep-gated ones rarer by their gate.
function veinOres(kind)
  local out, total = {}, 0
  for _, b in ipairs(BANDS[kind] or BANDS.barren) do
    if VEIN_SLOTS[b.mat] then
      local w = b.w / (1 + (b.minDepth or 0) / 8)
      out[#out + 1] = { mat = b.mat, w = w }
      total = total + w
    end
  end
  return out, total
end

-- ── ores by world: where each forms, how it looks, what it is worth to research ──
--
-- ORE IS UNDERGROUND. Most veins are buried: they run through the rock and
-- are found by digging or caving (mineral_field "ore veins"); a few of the
-- common ones crop out at the surface. `ORE[id]`:
--   minDepth, maxDepth  metres of rock over the vein's line it may lie at
--   surface             may crop out (only common ores do)
--   rarity              1 common … 5 exotic; rarer ores lie deeper and are
--                       picked less often
--   look                seam (core tint), stain (the colour it bleeds into the
--                       rock round it), float (its broken bits), out (the
--                       outcrop's model, tint c, emissive e, glow, cluster)
-- Which ores a world carries is `bodyOres(name)`: read from the world's own
-- makeup (its type, air, temperature, density and whether it is a moon), so
-- the home world has its familiar ores and every other body its own.
local BOULDER, STONE, GEM = "models/flora/rock_boulder_l0.gltf", "models/flora/rock_stone_l0.gltf", "models/flora/rock_crystal_l0.gltf"
ORE = {
  iron = { minDepth = 0, maxDepth = 30, surface = true, rarity = 1, look = {
    seam = { 0.30, 0.15, 0.11 }, stain = { 0.66, 0.32, 0.16 }, float = { 0.64, 0.30, 0.14 },
    out = { model = BOULDER, c = { 0.42, 0.13, 0.08 }, s = { 0.45, 0.85 }, sink = 0.3 } } },
  copper = { minDepth = 0, maxDepth = 35, surface = true, rarity = 1, look = {
    seam = { 0.24, 0.56, 0.44 }, stain = { 0.34, 0.60, 0.48 }, float = { 0.22, 0.58, 0.42 },
    out = { model = STONE, c = { 0.12, 0.50, 0.38 }, s = { 0.55, 1.0 }, sink = 0.3 } } },
  sulfur = { minDepth = 0, maxDepth = 25, surface = true, rarity = 2, look = {
    seam = { 0.86, 0.76, 0.26 }, stain = { 0.84, 0.76, 0.36 }, float = { 0.92, 0.80, 0.22 },
    out = { model = STONE, c = { 0.95, 0.80, 0.12 }, s = { 0.5, 0.95 }, sink = 0.3 } } },
  obsidian = { minDepth = 0, maxDepth = 25, surface = true, rarity = 2, look = {
    seam = { 0.16, 0.15, 0.18 }, stain = { 0.30, 0.28, 0.30 }, float = { 0.09, 0.08, 0.10 },
    out = { model = STONE, c = { 0.07, 0.06, 0.08 }, rough = 0.15, s = { 0.35, 0.7 }, sink = 0.3 } } },
  crystal = { minDepth = 14, maxDepth = 45, rarity = 3, look = {
    out = { model = GEM, glow = 0.55, s = { 0.4, 0.85 }, sink = 0.2, cluster = true } } },
  uranium = { minDepth = 20, maxDepth = 50, rarity = 4, look = {
    seam = { 0.50, 0.66, 0.26 }, stain = { 0.62, 0.70, 0.34 }, float = { 0.40, 0.50, 0.18 },
    out = { model = GEM, c = { 0.22, 0.27, 0.12 }, e = { 0.45, 0.85, 0.2 }, glow = 0.35, s = { 0.3, 0.6 }, sink = 0.25, cluster = true } } },
  ilmenite = { minDepth = 0, maxDepth = 30, surface = true, rarity = 2, look = {
    seam = { 0.14, 0.14, 0.16 }, stain = { 0.30, 0.30, 0.32 }, float = { 0.16, 0.16, 0.18 },
    out = { model = BOULDER, c = { 0.10, 0.10, 0.11 }, rough = 0.35, s = { 0.45, 0.85 }, sink = 0.3 } } },
  he3 = { minDepth = 0, maxDepth = 5, surface = true, rarity = 3, look = {
    seam = { 0.70, 0.68, 0.62 }, stain = { 0.74, 0.72, 0.66 }, float = { 0.62, 0.60, 0.56 },
    out = { model = STONE, c = { 0.55, 0.53, 0.50 }, s = { 0.4, 0.8 }, sink = 0.35 } } },
  kreep = { minDepth = 8, maxDepth = 40, rarity = 3, look = {
    seam = { 0.40, 0.26, 0.20 }, stain = { 0.50, 0.34, 0.26 }, float = { 0.44, 0.28, 0.22 },
    out = { model = BOULDER, c = { 0.30, 0.18, 0.14 }, s = { 0.45, 0.85 }, sink = 0.3 } } },
  kamacite = { minDepth = 0, maxDepth = 40, surface = true, rarity = 2, look = {
    seam = { 0.36, 0.36, 0.38 }, stain = { 0.56, 0.36, 0.24 }, float = { 0.42, 0.40, 0.40 },
    out = { model = BOULDER, c = { 0.30, 0.30, 0.32 }, metallic = 0.8, rough = 0.45, s = { 0.4, 0.8 }, sink = 0.3 } } },
  sperrylite = { minDepth = 20, maxDepth = 55, rarity = 5, look = {
    seam = { 0.58, 0.58, 0.60 }, stain = { 0.46, 0.46, 0.48 }, float = { 0.62, 0.62, 0.64 },
    out = { model = STONE, c = { 0.50, 0.50, 0.52 }, metallic = 0.9, rough = 0.3, s = { 0.3, 0.6 }, sink = 0.3 } } },
  monazite = { minDepth = 10, maxDepth = 45, rarity = 3, look = {
    seam = { 0.70, 0.46, 0.22 }, stain = { 0.70, 0.52, 0.32 }, float = { 0.76, 0.50, 0.24 },
    out = { model = STONE, c = { 0.62, 0.36, 0.14 }, s = { 0.4, 0.8 }, sink = 0.3 } } },
  ammonia_ice = { minDepth = 0, maxDepth = 30, surface = true, rarity = 2, look = {
    seam = { 0.80, 0.86, 0.92 }, stain = { 0.80, 0.84, 0.88 }, float = { 0.86, 0.90, 0.95 },
    out = { model = GEM, c = { 0.70, 0.78, 0.86 }, rough = 0.2, s = { 0.35, 0.7 }, sink = 0.25, cluster = true } } },
  clathrate = { minDepth = 10, maxDepth = 45, rarity = 3, look = {
    seam = { 0.88, 0.90, 0.86 }, stain = { 0.74, 0.76, 0.72 }, float = { 0.92, 0.92, 0.90 },
    out = { model = GEM, c = { 0.80, 0.82, 0.78 }, rough = 0.3, s = { 0.3, 0.6 }, sink = 0.25, cluster = true } } },
  tholin = { minDepth = 0, maxDepth = 25, surface = true, rarity = 2, look = {
    seam = { 0.40, 0.18, 0.08 }, stain = { 0.56, 0.30, 0.14 }, float = { 0.46, 0.22, 0.10 },
    out = { model = STONE, c = { 0.36, 0.14, 0.06 }, rough = 0.25, s = { 0.4, 0.8 }, sink = 0.35 } } },
  phasite = { minDepth = 18, maxDepth = 50, rarity = 5, look = {
    seam = { 0.52, 0.40, 0.70 }, stain = { 0.56, 0.48, 0.66 }, float = { 0.50, 0.40, 0.66 },
    out = { model = GEM, c = { 0.40, 0.30, 0.62 }, e = { 0.55, 0.35, 0.95 }, glow = 0.3, s = { 0.35, 0.7 }, sink = 0.2, cluster = true } } },
  cryovolt = { minDepth = 14, maxDepth = 45, rarity = 5, look = {
    seam = { 0.50, 0.70, 0.78 }, stain = { 0.56, 0.70, 0.76 }, float = { 0.52, 0.72, 0.80 },
    out = { model = GEM, c = { 0.36, 0.56, 0.66 }, e = { 0.30, 0.75, 1.0 }, glow = 0.25, s = { 0.35, 0.7 }, sink = 0.2, cluster = true } } },
}

-- The research a unit of an ore is worth, by rarity (the lab and its stat read
-- `researchValue`; these are its base points).
RESEARCH_BY_RARITY = { 4, 10, 25, 60, 140 }
for _, o in pairs(ORE) do o.research = o.research or RESEARCH_BY_RARITY[o.rarity or 1] end

function oreInfo(id) return ORE[id] end
function oreLook(id) local o = ORE[id]; return o and o.look end

-- What a world is made of, read from its records: { home, moon, airless,
-- temp (0 frozen … 1 scorching), dense (density over the system's middle
-- one), type (planet type, geo.type), family (the legacy archetype) }.
-- Every reader below keys on this, never on a body's name.
local function world_rec(bname) return bname and save and save.get and save.get("world." .. bname) or nil end
local function roster() local h = save and save.get and save.get("system.home"); return type(h) == "table" and h or nil end
function bodyTraits(bname)
  local w = world_rec(bname)
  if type(w) ~= "table" then return nil end
  local h = roster()
  local me, rhos = nil, {}
  for _, b in ipairs(h and h.bodies or {}) do
    if type(b.mu) == "number" and type(b.radius) == "number" and b.radius > 0 then rhos[#rhos + 1] = b.mu / b.radius ^ 3 end
    if b.name == bname then me = b end
  end
  table.sort(rhos)
  local mid = rhos[math.max(1, math.ceil(#rhos / 2))]
  local rho = me and me.mu and me.radius and me.radius > 0 and me.mu / me.radius ^ 3 or nil
  local home = (save.get("base.body") == bname) or (type(w.geo) == "table" and w.geo.home == true)
  local temp = w.climTemp
  if type(temp) ~= "number" then
    temp = ({ lava = 0.95, dune = 0.7, canyon = 0.55, crystal = 0.5, barren = 0.35, ice = 0.15, frost = 0.08 })[w.kind or "barren"] or 0.4
  end
  return {
    home = home == true,
    moon = me ~= nil and me.parent ~= nil and me.parent ~= (h and h.star),
    airless = (w.atmo or 0) < 0.05,
    temp = temp,
    dense = (rho and mid and mid > 0) and rho / mid or 1,
    type = type(w.geo) == "table" and w.geo.type or w.kind or "barren",
    family = w.kind or "barren",
    seed = w.seed or 1,
  }
end

-- A stable number in [0, 1) for a body and an ore: two worlds of the same
-- type carry the same ores in different measure.
local function jitter(seed, id)
  local h = (seed or 1) % 2147483647
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 2147483647 end
  local x = math.sin(h * 12.9898 + 78.233) * 43758.5453
  return x - math.floor(x)
end

-- The ores in a world's rock: { { mat, w } … }, total weight. Read from what
-- it is made of (bodyTraits). nil traits (no world record: a test world, a
-- scale-1 save) falls back on the archetype's bands (veinOres).
function bodyOres(bname, kind)
  local t = bodyTraits(bname)
  if not t then return veinOres(kind or "barren") end
  local pool = {}
  local function add(id, w) if ORE[id] and w > 0 then pool[id] = (pool[id] or 0) + w end end
  local fam, ty = t.family, t.type
  if t.home then
    -- the home world: the ores everyone starts on
    add("iron", 3.0); add("copper", 1.8)
    add("sulfur", (fam == "dune" or fam == "lava") and 1.4 or 0.6)
    if fam == "lava" then add("obsidian", 1.2) end
    add("crystal", 0.35); add("uranium", 0.25)
  elseif fam == "frost" or fam == "ice" or ty == "titan" or ty == "glacial" or ty == "frost" then
    -- cold bodies (by what they are made of, not the clamped temperature,
    -- which reads 0 for everything under 233 K): volatile ices, and on a
    -- hazy hydrocarbon world, tholins
    add("ammonia_ice", 2.2); add("clathrate", 1.2)
    if not t.airless or ty == "titan" then add("tholin", 1.6); add("cryovolt", 0.4) end
    if t.airless then add("kamacite", 0.5) end
  elseif t.airless then
    -- airless rock, a moon or a cratered world: solar-wind regolith over mare
    -- basalt, impact iron, and the magma ocean's last melt deep down
    add("ilmenite", ty == "maria" and 3.0 or 2.0); add("he3", 1.4)
    add("kamacite", 0.9); add("kreep", 0.7)
  else
    -- another planet with air: weathered ores, rare earths
    add("iron", 1.2); add("copper", 0.8); add("monazite", 0.9)
    if fam == "lava" then add("sulfur", 1.6); add("obsidian", 1.2); add("uranium", 0.3) end
    if fam == "dune" then add("sulfur", 0.8) end
    if fam == "crystal" then add("crystal", 1.6); add("phasite", 0.5) end
  end
  -- dense worlds hold the metals that sank in them
  if t.dense > 1.25 and not t.home then add("kamacite", 0.8); add("sperrylite", 0.35) end
  if fam == "crystal" and not t.home then add("phasite", 0.3) end
  local out, total = {}, 0
  for id, w in pairs(pool) do
    local wj = w * (0.65 + 0.7 * jitter(t.seed, id))
    out[#out + 1] = { mat = id, w = wj }
    total = total + wj
  end
  table.sort(out, function(a, b) return a.mat < b.mat end)
  return out, total
end

-- Pick an ore for a vein `depth` m down from a world's list (`bodyOres`):
-- an ore lies only inside its depth band, a surface vein (depth 0) only
-- among ores that crop out, and rarer ores weigh more the deeper you are.
-- `roll` in [0, 1). nil when nothing fits.
function pickVeinOre(list, depth, roll)
  local total, ws = 0, {}
  for i, e in ipairs(list) do
    local o = ORE[e.mat] or {}
    local ok = depth <= 0.5 and (o.surface == true) or (depth >= (o.minDepth or 0) and depth <= (o.maxDepth or 60))
    local w = ok and e.w or 0
    if w > 0 and depth > 0.5 then w = w * (1 + ((o.rarity or 1) - 1) * 0.35 * math.min(1, depth / 40)) end
    ws[i] = w
    total = total + w
  end
  if total <= 0 then return nil end
  local pick = (roll or 0) * total
  for i, e in ipairs(list) do
    pick = pick - ws[i]
    if pick <= 0 and ws[i] > 0 then return e.mat end
  end
  for i = #list, 1, -1 do if ws[i] > 0 then return list[i].mat end end
  return nil
end

-- WHERE AN ORE CAME FROM. The first body a material was mined on is kept
-- (`ore.origin` = { [mat] = body }); a loose resource body also carries
-- `origin:<body>` in its tags (tagResource). The lab reads both.
-- Every body a material has been mined on is kept too (`ore.minedOn` =
-- { [mat] = { [body] = true } }, `minedOn(mat, body)`): an ore haul from a
-- second moon that carries the same ore (missions.lua "orehaul") is checked
-- against that, not against the first moon it was ever dug on.
function noteOrigin(mat, body)
  if not (mat and body and save and save.get) then return end
  legacySnapshot()
  local m = save.get("ore.minedOn")
  if type(m) ~= "table" then m = {} end
  if type(m[mat]) ~= "table" then m[mat] = {} end
  if not m[mat][body] then
    m[mat][body] = true
    save.set("ore.minedOn", m)
  end
  local o = save.get("ore.origin")
  if type(o) ~= "table" then o = {} end
  if o[mat] then return end
  o[mat] = body
  save.set("ore.origin", o)
end
function originOf(mat)
  local o = save and save.get and save.get("ore.origin")
  return type(o) == "table" and o[mat] or nil
end
-- Has `mat` been mined on `body`? (A save from before `ore.minedOn`: its
-- recorded origin.)
function minedOn(mat, body)
  if not (mat and body and save and save.get) then return false end
  local m = save.get("ore.minedOn")
  if type(m) == "table" and type(m[mat]) == "table" and m[mat][body] then return true end
  return originOf(mat) == body
end

-- PER-LOT ORIGIN (inventory.lua `inv.org.<cid>`): ore mined from now on
-- carries the body it was dug on in every container, so a haul counts the
-- lot, not this record. Units with NO origin are home ore, stock — or a save
-- from before the lots were tagged, whose ore could have come from anywhere
-- it had been mined. For those the haul falls back to this record, but only
-- as it stood BEFORE the first tagged lot (`ore.minedOnLegacy`, written once
-- by `legacySnapshot` when inventory.add first sees an origin, or the next
-- noteOrigin): ore dug on moon B after the update is tagged B, and does not
-- make an old save's untagged moon-A ilmenite count as B's.
function legacySnapshot()
  if not (save and save.get and save.set) then return end
  if type(save.get("ore.minedOnLegacy")) == "table" then return end
  local snap = {}
  local m = save.get("ore.minedOn")
  if type(m) == "table" then
    for mat, by in pairs(m) do
      if type(by) == "table" then
        for body, yes in pairs(by) do
          if yes then snap[mat] = snap[mat] or {}; snap[mat][body] = true end
        end
      end
    end
  end
  local o = save.get("ore.origin")
  if type(o) == "table" then
    for mat, body in pairs(o) do
      if type(body) == "string" then snap[mat] = snap[mat] or {}; snap[mat][body] = true end
    end
  end
  save.set("ore.minedOnLegacy", snap)
end
-- Could an UNTAGGED unit of `mat` have been mined on `body`? (No snapshot
-- yet: nothing has been tagged in this save, so the whole record stands.)
function legacyMinedOn(mat, body)
  if not (mat and body and save and save.get) then return false end
  local s = save.get("ore.minedOnLegacy")
  if type(s) ~= "table" then return minedOn(mat, body) end
  return type(s[mat]) == "table" and s[mat][body] == true
end

-- RESEARCH. What one unit of `mat` from `originBody` is worth to the lab:
-- its base points (by rarity; bulk rock 0, other materials 1 per tier),
-- three times over when it came from another world than home, and five times
-- that the first time the kind is brought home (`firstTime`: the lab knows).
-- The lab and its research-points stat are another script's; this is the
-- one number they read.
function researchValue(mat, originBody, firstTime)
  local o = ORE[mat]
  local base
  if o then base = o.research or RESEARCH_BY_RARITY[o.rarity or 1]
  elseif grade(mat) == "bulk" then base = 0
  else base = tier(mat) end
  if base <= 0 then return 0 end
  local home = save and save.get and save.get("base.body")
  local origin = originBody or originOf(mat)
  if origin and home and origin ~= home then base = base * 3 end
  if firstTime then base = base * 5 end
  return base
end

-- ── CODEX: the off-world ores' entries (per-planet ores) ────────────────────
-- The lab's codex (scripts/codex.lua: CODEX, entry(id), and the RULES OF THIS
-- UNIVERSE the fictional entries keep to) holds the home materials. The ores
-- this file adds are written here, in its shape: { name, summary, facts,
-- fictional }. codex.lua reads them through `codex(mat)` or `ORE_CODEX`, and
-- `codexInto(cx)` copies them into its CODEX when it is mounted. Real minerals
-- carry real facts. Phasite and cryovolt glass are fictional and keep to
-- codex.lua's rules (1 Vey's law, 2 sympathy, 5 phase density).
ORE_CODEX = {
  ilmenite = { name = "Ilmenite",
    summary = "An iron-titanium oxide, abundant in the dark lunar maria and a leading source of oxygen on the Moon.",
    facts = {
      "Ilmenite (FeTiO3) is a major mineral of the high-titanium mare basalts returned by Apollo 11 and 17, making up a large fraction of some samples.",
      "Heating ilmenite with hydrogen at about 900 to 1000 degrees C reduces it to iron and titanium dioxide and gives off water, which can be split for oxygen: one of the best-studied lunar oxygen processes.",
      "It is the main ore of titanium on Earth; the metal is won through titanium tetrachloride by the Kroll process.",
      "Ilmenite grains hold on to solar-wind gases, including helium-3, better than most other lunar minerals.",
    } },
  he3 = { name = "Helium-3 Regolith",
    summary = "Surface regolith carrying helium-3 implanted by billions of years of solar wind.",
    facts = {
      "The solar wind implants helium-3 into the top few metres of airless regolith; lunar samples carry it at only a few parts per billion.",
      "Most of it is released by heating the regolith to about 600 to 700 degrees C, so mining it means processing enormous tonnages: roughly a hundred million tonnes of regolith per tonne of helium-3.",
      "Deuterium-helium-3 fusion produces far fewer neutrons than deuterium-tritium fusion, which is why helium-3 is talked about as a future fusion fuel.",
      "On Earth, helium-3 comes mainly from the decay of tritium and is scarce and expensive; it is used in dilution refrigerators and neutron detectors.",
      "China's Chang'e-5 mission returned fresh lunar samples in 2020 that have been studied for their helium-3 content.",
    } },
  kreep = { name = "KREEP Basalt",
    summary = "Lunar rock rich in potassium, rare-earth elements and phosphorus: the last melt of the Moon's magma ocean.",
    facts = {
      "KREEP is named for potassium (K), rare-earth elements (REE) and phosphorus (P), the elements left concentrated in the final liquid as the lunar magma ocean crystallised.",
      "Lunar Prospector's gamma-ray spectrometer mapped its thorium signature, concentrated in the Procellarum KREEP Terrane on the Moon's near side.",
      "Its uranium, thorium and potassium make it warm with radioactive decay, which may have kept near-side volcanism going longer than on the far side.",
      "It is a candidate lunar source of rare-earth elements and of phosphorus for growing crops.",
    } },
  kamacite = { name = "Kamacite (nickel-iron)",
    summary = "Metallic nickel-iron from the cores of shattered asteroids.",
    facts = {
      "Kamacite is an alloy of iron with roughly 5 to 7.5 percent nickel, the main metal of iron meteorites.",
      "With the nickel-rich alloy taenite it forms the Widmanstatten pattern, revealed when a cut meteorite is etched with acid; the band widths record cooling of only a few degrees per million years.",
      "NASA's Psyche spacecraft, launched in October 2023, is bound for the metal-rich asteroid 16 Psyche, possibly the exposed core of a protoplanet.",
      "Nickel can be separated from the iron with carbon monoxide as volatile nickel carbonyl (the Mond process), a route proposed for refining asteroid metal in space.",
      "Native metal needs no reduction step, so it is the most direct steel feedstock in the solar system.",
    } },
  sperrylite = { name = "Sperrylite (platinum ore)",
    summary = "Platinum arsenide, the commonest platinum mineral and a rare, dense prize.",
    facts = {
      "Sperrylite (PtAs2) was first described in 1889 from Sudbury, Ontario, and named for the chemist Francis L. Sperry.",
      "The Sudbury basin, one of the world's great nickel and platinum-group districts, is the remnant of a giant impact about 1.85 billion years ago.",
      "Sperrylite is very dense, about 10.6 grams per cubic centimetre.",
      "Platinum-group metals are spacecraft catalysts: hydrazine thrusters run on an iridium-on-alumina catalyst, and Gemini's fuel cells used platinum electrodes.",
      "Metallic asteroids may hold platinum-group metals at far higher grades than Earth's crust, the main lure of asteroid mining.",
    } },
  monazite = { name = "Monazite (rare earths)",
    summary = "A rare-earth phosphate: the cerium, lanthanum and neodymium in modern magnets and electronics.",
    facts = {
      "Monazite, (Ce,La,Nd,Th)PO4, is with bastnasite one of the two main ores of the rare-earth elements.",
      "It is mined from heavy-mineral beach and river sands, notably in India and Brazil, where it collects with other dense grains.",
      "It carries thorium, so processing it means handling radioactive residues.",
      "The ore is cracked with hot sulfuric acid or caustic soda, and the individual lanthanides are separated by solvent extraction.",
      "Neodymium from rare-earth ores goes into NdFeB permanent magnets, used in electric motors, actuators and reaction wheels.",
    } },
  ammonia_ice = { name = "Ammonia Ice",
    summary = "Frozen ammonia and ammonia hydrates from the cold outer bodies.",
    facts = {
      "New Horizons found ammonia-bearing ices on Pluto's moon Charon in 2015, and Cassini detected ammonia in the plumes of Saturn's moon Enceladus.",
      "Ammonia is a natural antifreeze: a water-ammonia mixture stays liquid down to about 176 K, which helps explain liquid layers inside icy moons.",
      "The International Space Station's external thermal control loops use liquid ammonia as their coolant.",
      "It is a source of nitrogen for life support and fertiliser, and has been flown as a resistojet propellant.",
    } },
  clathrate = { name = "Methane Clathrate",
    summary = "Methane locked in cages of water ice: ice that burns.",
    facts = {
      "In a methane clathrate, methane molecules are trapped inside cages of water-ice molecules; a cubic metre releases about 160 cubic metres of methane at surface conditions.",
      "It is stable only cold and under pressure, and set alight it burns, the 'burning ice' of seafloor and permafrost deposits.",
      "Methane with liquid oxygen is the propellant of SpaceX's Raptor and Blue Origin's BE-4 engines, so a methane source off-world means refuelling where you land.",
      "Clathrates have been proposed in the crusts of Titan and Mars as stores of their atmospheric methane.",
      "When clathrate warms it dissociates suddenly, and the escaping gas can destabilise the ground around it.",
    } },
  tholin = { name = "Tholin Tar",
    summary = "Reddish-brown organic polymers made by light acting on methane and nitrogen.",
    facts = {
      "Tholins form when ultraviolet light or charged particles break up methane and nitrogen and the fragments recombine into complex organics; Carl Sagan and Bishun Khare named them in 1979.",
      "They give Titan's haze its orange colour and darken Pluto's Cthulhu Macula and the Kuiper belt object Arrokoth to red-brown.",
      "They are rich in carbon, hydrogen and nitrogen, a feedstock for hydrocarbons and for growing things.",
      "NASA's Dragonfly rotorcraft is to fly on Titan to study this prebiotic chemistry.",
    } },
  phasite = { name = "Phasite", fictional = true,
    summary = "A deep crystal whose density answers to gravity: heavy on small worlds, light on big ones.",
    facts = {
      "Phasite obeys phase density (codex rule 5): its density goes as one over the square root of local gravity, so it is half as dense under four times the gravity, and a cargo weighs less than four times as much on the heavier world.",
      "It forms only deep in crystal-rich crust, where the lattice grew while the body's own gravity set its phase. That is why it is never found at the surface.",
      "Engineers use it as self-trimming ballast: a lander loaded with phasite on a light world carries less of its mass down to a heavy one.",
      "Hazard: a hold of phasite changes its mass as a craft climbs or lands, which shifts its centre of mass. Secure it low and central, and re-trim after every change of world.",
      "Below its Vey point it holds a standing mode like resonant crystal (rule 1), and it glows a pale violet where it is warm.",
    } },
  cryovolt = { name = "Cryovolt Glass", fictional = true,
    summary = "A frozen glass that holds a standing lattice mode far below zero and gives it back as electricity.",
    facts = {
      "Cryovolt glass forms where lightning fuses ice and organic sediment on cold hydrocarbon worlds. Its Vey point (codex rule 1) is about minus 185 degrees C, so it holds a lossless standing mode only in deep cold.",
      "The glass is strongly piezoelectric: its ringing lattice drives a steady voltage across its faces. That is the 'volt', and it is ordinary piezoelectric physics.",
      "Two pieces cut to the same length ring at the same pitch (rule 2) and pass energy between them across a gap. Cold-side outposts use matched pairs as wireless power links.",
      "Hazard: warmed past its Vey point, the stored mode leaks out as light and heat all at once (rule 1). Never bring it into a heated cabin: haul it in a cold hold.",
      "While it holds its charge it shows faint blue lines along its fractures, and the lines fade as it drains.",
    } },
}

function codex(mat)
  local cx = findScript and findScript("codex")
  local e = cx and cx.CODEX and cx.CODEX[mat]
  return e or ORE_CODEX[mat]
end

-- Copy the ore entries into the lab's codex (any script may add entries
-- there): the ones it does not already have.
function codexInto(cx)
  if not (cx and cx.CODEX) then return 0 end
  local n = 0
  for id, e in pairs(ORE_CODEX) do
    if not cx.CODEX[id] then cx.CODEX[id] = e; n = n + 1 end
  end
  return n
end

-- ── loose resource bodies (logs, rocks, chunks) ─────────────────────────────
-- A body you can carry with the gravity gun, load on a truck and drop at the
-- depot carries what it is in its TAGS, so any script can read it without
-- knowing who made it (docs/resources.md):
--   "resource"          every such body
--   "mat:<id>"          the material (an id of REG)
--   "qty:<n>"           units of it (whole units)
--   "origin:<body>"     the world it came from (when known)
-- plus the prefab's own kind tag ("log", "loose_rock", "boulder", "crystal").
function tagResource(n, mat, qty, extra, origin)
  if not (n and mat) then return end
  local keep = {}
  for _, t in ipairs(n.tags or {}) do
    if t ~= "resource" and t:sub(1, 4) ~= "mat:" and t:sub(1, 4) ~= "qty:" and t:sub(1, 7) ~= "origin:" then keep[#keep + 1] = t end
  end
  keep[#keep + 1] = "resource"
  keep[#keep + 1] = "mat:" .. mat
  keep[#keep + 1] = "qty:" .. tostring(math.max(1, math.floor((qty or 1) + 0.5)))
  if origin then keep[#keep + 1] = "origin:" .. origin end
  for _, t in ipairs(extra or {}) do keep[#keep + 1] = t end
  n.tags = keep
end

-- What a resource body is: { mat, qty, name, kg, value, grade, kind } or nil.
-- `value` is the depot's base price for the lot at reputation 0 (a hint: the
-- depot applies standing and the discovery premium); `kg` the lot's mass.
function resourceOf(n)
  if not (n and n.valid ~= false and n.tags) then return nil end
  local mat, qty, kind, origin
  for _, t in ipairs(n.tags) do
    if t:sub(1, 7) == "origin:" then origin = t:sub(8)
    elseif t:sub(1, 4) == "mat:" then mat = t:sub(5)
    elseif t:sub(1, 4) == "qty:" then qty = tonumber(t:sub(5))
    elseif t == "log" or t == "loose_rock" or t == "boulder" or t == "crystal" then kind = t end
  end
  if not mat then return nil end
  qty = qty or 1
  return { mat = mat, qty = qty, name = label(mat), kg = massOf(mat, qty), value = valueOf(mat, qty),
           grade = grade(mat), kind = kind, origin = origin,
           research = researchValue(mat, origin) * qty }
end
