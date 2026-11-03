-- MATERIALS — the registry every harvested, mined, hauled and sold thing is
-- weighed and valued by. One table, one truth: the inventory weighs a unit
-- through here, the depot prices it through here, and the tool that produced
-- it only ever names an id.
--
-- A unit is "one handful you can carry" — the numbers are per unit, and mass is
-- what actually limits you (a suit carries ~45 kg; a cargo hold hundreds).
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
  silica   = { name = "Silica",           kg = 1.6, value = 5,   tier = 1, class = "ore" },
  iron     = { name = "Iron Ore",         kg = 2.6, value = 8,   tier = 1, class = "ore" },
  copper   = { name = "Copper Ore",       kg = 2.4, value = 12,  tier = 1, class = "ore" },
  ice      = { name = "Water Ice",        kg = 1.0, value = 4,   tier = 1, class = "ice" },
  water    = { name = "Water",            kg = 1.0, value = 3,   tier = 1, class = "liquid" },
  sulfur   = { name = "Sulfur",           kg = 1.4, value = 14,  tier = 2, class = "ore" },
  obsidian = { name = "Obsidian",         kg = 2.2, value = 22,  tier = 2, class = "ore" },
  crystal  = { name = "Resonant Crystal", kg = 1.1, value = 60,  tier = 3, class = "ore" },
  uranium  = { name = "Uranite",          kg = 3.2, value = 110, tier = 3, class = "ore" },

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

-- ── loose resource bodies (logs, rocks, chunks) ─────────────────────────────
-- A body you can carry with the gravity gun, load on a truck and drop at the
-- depot carries what it is in its TAGS, so any script can read it without
-- knowing who made it (docs/resources.md):
--   "resource"          every such body
--   "mat:<id>"          the material (an id of REG)
--   "qty:<n>"           units of it (whole units)
-- plus the prefab's own kind tag ("log", "loose_rock", "boulder", "crystal").
function tagResource(n, mat, qty, extra)
  if not (n and mat) then return end
  local keep = {}
  for _, t in ipairs(n.tags or {}) do
    if t ~= "resource" and t:sub(1, 4) ~= "mat:" and t:sub(1, 4) ~= "qty:" then keep[#keep + 1] = t end
  end
  keep[#keep + 1] = "resource"
  keep[#keep + 1] = "mat:" .. mat
  keep[#keep + 1] = "qty:" .. tostring(math.max(1, math.floor((qty or 1) + 0.5)))
  for _, t in ipairs(extra or {}) do keep[#keep + 1] = t end
  n.tags = keep
end

-- What a resource body is: { mat, qty, name, kg, value, grade, kind } or nil.
-- `value` is the depot's base price for the lot at reputation 0 (a hint: the
-- depot applies standing and the discovery premium); `kg` the lot's mass.
function resourceOf(n)
  if not (n and n.valid ~= false and n.tags) then return nil end
  local mat, qty, kind
  for _, t in ipairs(n.tags) do
    if t:sub(1, 4) == "mat:" then mat = t:sub(5)
    elseif t:sub(1, 4) == "qty:" then qty = tonumber(t:sub(5))
    elseif t == "log" or t == "loose_rock" or t == "boulder" or t == "crystal" then kind = t end
  end
  if not mat then return nil end
  qty = qty or 1
  return { mat = mat, qty = qty, name = label(mat), kg = massOf(mat, qty), value = valueOf(mat, qty),
           grade = grade(mat), kind = kind }
end
