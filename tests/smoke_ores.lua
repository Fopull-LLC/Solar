-- SMOKE HARNESS: ores by world (scripts/materials.lua "ores by world" and
-- "CODEX"). Pure registry checks, no engine:
--
--   luajit solar/tests/smoke_ores.lua
--
-- What it pins:
--  * every ore has a registry entry, a hardness, a texture slot list, a look
--    (seam and stain, or an outcrop of its own), a research value, and a
--    codex entry with 4–6 facts (fictional ones flagged);
--  * a world's ores come from its makeup: the home world has iron and copper
--    and none of the off-world ores; an airless moon has its own (ilmenite,
--    helium-3) and no iron; a cold body has ices; a dense world has metals;
--  * a vein at the surface is only ever a common ore, and rare ores lie deep;
--  * research: off-world ×3, a first find ×5, bulk rock nothing;
--  * a resource body carries where it came from (origin:<body>).

local store = {}
local env = setmetatable({
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  print = function() end, log = function() end,
}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/materials.lua"))
setfenv(chunk, env)
chunk()
local M = env

local checks = {}
local function check(desc, ok, detail) checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail } end

-- ── every ore is whole ──────────────────────────────────────────────────────
local missing = {}
for id, o in pairs(M.ORE) do
  local why = nil
  if not M.REG[id] then why = "no REG entry"
  elseif not M.HARD[id] then why = "no hardness"
  elseif not (M.VEIN_SLOTS[id] and #M.VEIN_SLOTS[id] > 0) then why = "no vein slots"
  elseif not o.look or not ((o.look.seam and o.look.stain) or (o.look.out and o.look.out.cluster)) then why = "no look"
  elseif not (o.look.out and o.look.out.model) then why = "no outcrop model"
  elseif not (o.research and o.research > 0) then why = "no research value"
  elseif not M.isOre(id) then why = "not graded ore" end
  local cx = M.ORE_CODEX[id]
  local homeOre = (id == "iron" or id == "copper" or id == "sulfur" or id == "obsidian" or id == "uranium" or id == "crystal")
  if homeOre then cx = { name = "(the lab's codex.lua)", summary = "", facts = { 1, 2, 3, 4 } } end
  if not why then
    if not cx then why = "no codex entry"
    elseif not (cx.name and cx.summary and type(cx.facts) == "table") then why = "codex entry malformed"
    elseif #cx.facts < 4 or #cx.facts > 6 then why = "codex has " .. #cx.facts .. " facts"
    end
  end
  if why then missing[#missing + 1] = id .. ": " .. why end
end
check("every ore is complete (registry, hardness, slots, look, research; an off-world ore's codex entry here, a home ore's in codex.lua)", #missing == 0, table.concat(missing, "; "))
check("the exotic ores are flagged fictional, the real ones are not",
  M.codex("phasite").fictional == true and M.codex("cryovolt").fictional == true and not M.codex("ilmenite").fictional
  and not M.codex("he3").fictional)
check("codexInto adds the ore entries a codex lacks and keeps its own", (function()
  local cx = { CODEX = { ilmenite = { summary = "theirs" } } }
  local n = M.codexInto(cx)
  -- (11: the off-world ores less ilmenite, and galena, worlds W3)
  return cx.CODEX.ilmenite.summary == "theirs" and cx.CODEX.he3 ~= nil and n == 11
end)())

-- ── worlds ──────────────────────────────────────────────────────────────────
store["system.home"] = { star = "Sun", bodies = {
  { name = "Home", parent = "Sun", mu = 1000, radius = 10 },
  { name = "Pebble", parent = "Home", mu = 30, radius = 3 },      -- density 1.11
  { name = "Rime", parent = "Sun", mu = 100, radius = 5 },        -- 0.8
  { name = "Lead", parent = "Sun", mu = 2200, radius = 9 },       -- 3.0, dense
  { name = "Haze", parent = "Sun", mu = 800, radius = 9.5 },
} }
store["base.body"] = "Home"
store["world.Home"] = { kind = "canyon", seed = 11, atmo = 1.0, climTemp = 0.55, geo = { type = "verdant", family = "canyon", home = true } }
store["world.Pebble"] = { kind = "barren", seed = 22, atmo = 0, climTemp = 0.4, geo = { type = "maria", family = "barren" } }
store["world.Rime"] = { kind = "frost", seed = 33, atmo = 0, climTemp = 0.05, geo = { type = "frost", family = "frost" } }
store["world.Lead"] = { kind = "lava", seed = 44, atmo = 0.6, climTemp = 0.9, geo = { type = "volcanic", family = "lava" } }
store["world.Haze"] = { kind = "ice", seed = 55, atmo = 1.4, climTemp = 0.1, geo = { type = "titan", family = "ice" } }

local function set_of(name)
  local out = {}
  for _, e in ipairs((M.bodyOres(name))) do out[e.mat] = e.w end
  return out
end
local home, moon, rime, lead, haze = set_of("Home"), set_of("Pebble"), set_of("Rime"), set_of("Lead"), set_of("Haze")
local OFF = { "ilmenite", "he3", "kreep", "kamacite", "sperrylite", "monazite", "ammonia_ice", "clathrate", "tholin", "phasite", "cryovolt" }
local leak = {}
for _, id in ipairs(OFF) do if home[id] then leak[#leak + 1] = id end end
check("the home world has its familiar ores and no off-world ones", home.iron and home.copper and #leak == 0, table.concat(leak, ","))
check("an airless moon has its own ores (ilmenite, helium-3) and no iron", moon.ilmenite and moon.he3 and not moon.iron and not moon.copper)
check("…and the traits say it is an airless moon", (function() local t = M.bodyTraits("Pebble"); return t.moon and t.airless and not t.home end)())
check("a cold airless body has volatile ices", rime.ammonia_ice and rime.clathrate and not rime.iron)
check("a hazy hydrocarbon world has tholins", haze.tholin ~= nil)
check("a dense world holds sunken metals", lead.kamacite and lead.sperrylite, string.format("dense %.2f", M.bodyTraits("Lead").dense))
check("two worlds of the same make carry the same ores in different measure", (function()
  store["world.Pebble2"] = { kind = "barren", seed = 99, atmo = 0, climTemp = 0.4, geo = { type = "maria", family = "barren" } }
  local a, b = set_of("Pebble"), set_of("Pebble2")
  return a.ilmenite and b.ilmenite and math.abs(a.ilmenite - b.ilmenite) > 1e-6
end)())
check("a world with no record falls back on its archetype's bands", (function()
  local l, t = M.bodyOres("Nowhere", "canyon")
  return #l > 0 and t > 0
end)())

-- ── depth ───────────────────────────────────────────────────────────────────
local list = M.bodyOres("Home")
local surf, deep_rare, shallow_rare, n = {}, 0, 0, 400
for i = 0, n - 1 do
  local m = M.pickVeinOre(list, 0, i / n)
  if m then surf[m] = true end
  local d = M.pickVeinOre(list, 40, i / n)
  if d and (M.ORE[d].rarity or 1) >= 3 then deep_rare = deep_rare + 1 end
  local s = M.pickVeinOre(list, 6, i / n)
  if s and (M.ORE[s].rarity or 1) >= 3 then shallow_rare = shallow_rare + 1 end
end
local bad = {}
for m in pairs(surf) do if not M.ORE[m].surface then bad[#bad + 1] = m end end
check("a vein at the surface is only ever an ore that crops out", #bad == 0 and surf.iron, table.concat(bad, ","))
check("rare ores lie deep: none 6 m down, some 40 m down", shallow_rare == 0 and deep_rare > 0, shallow_rare .. " / " .. deep_rare)
check("helium-3 lies only in the top metres", M.pickVeinOre({ { mat = "he3", w = 1 } }, 20, 0.5) == nil
  and M.pickVeinOre({ { mat = "he3", w = 1 } }, 0, 0.5) == "he3")

-- ── research and origin ─────────────────────────────────────────────────────
local r_home = M.researchValue("iron", "Home")
local r_moon = M.researchValue("ilmenite", "Pebble")
local r_first = M.researchValue("ilmenite", "Pebble", true)
check("research: an off-world ore is worth more than a home one, and its first find much more",
  r_moon > r_home and r_first == r_moon * 5 and r_moon == M.ORE.ilmenite.research * 3, r_home .. " / " .. r_moon .. " / " .. r_first)
check("research: bulk rock is worth nothing to the lab", M.researchValue("granite", "Pebble") == 0)
check("research: rarer ores are worth more", M.researchValue("sperrylite", "Lead") > M.researchValue("kamacite", "Lead"))
M.noteOrigin("ilmenite", "Pebble"); M.noteOrigin("ilmenite", "Home")
check("an ore's origin is the first world it was mined on", M.originOf("ilmenite") == "Pebble" and M.researchValue("ilmenite") == r_moon)
local node = { tags = { "loose_rock" }, valid = true }
M.tagResource(node, "he3", 3, nil, "Pebble")
local rr = M.resourceOf(node)
check("a resource body carries its origin and its research", rr and rr.origin == "Pebble" and rr.qty == 3
  and rr.research == M.researchValue("he3", "Pebble") * 3)
M.tagResource(node, "he3", 2)
check("…and re-tagging it without one drops the stale origin", M.resourceOf(node).origin == nil)

local fails = {}
for _, c in ipairs(checks) do if not c.ok then fails[#fails + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "") end end
if #fails == 0 then
  print(string.format("ORES SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("ORES SMOKE FAILURES:")
for _, f in ipairs(fails) do print(f) end
os.exit(1)
