-- SMOKE: the depot's item card and SELL counter, and the base's SUPPLY CRATES
-- (scripts/items.lua, inventory.lua, supply_crates.lua; playtest 2026-10-27):
--
--   * the depot buys gear back at 60 % of list (items.SELL_BACK), one piece a
--     click, paying the company; nothing to sell is refused; a tank's level
--     leaves with it;
--   * every shop item has a card: a kind line, a description, mass and bulk,
--     price and sell-back, and the numbers that matter for it (the Medkit's
--     heal and revive, the rifle's bolt and damage, live from its script when
--     there is one);
--   * a supply crate is a container of 400 kg and 480 L: items and materials
--     go in and come out, what doesn't fit stays where it was (with why), and
--     the contents are the SAVE's — a fresh inventory script over the same
--     store still sees them;
--   * the crate layout: five, named, ids → "crate:<n>", the nearest within
--     reach.
--
--   luajit solar/tests/smoke_depot_crates.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local T = 0
local store = {}
local API = {}
local envs = {}
API.findScript = function(kind) return envs[kind] end
API.findScripts = function() return {} end
API.log = function() end
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }

local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end

local I = load_script("scripts/items.lua", "items")
load_script("scripts/materials.lua", "materials")
local inv = load_script("scripts/inventory.lua", "inventory")
local money, earned, ledger = 10000, 0, {}
envs.company = { valid = true,
  spend = function(v) if v > money then return false end money = money - v return true end,
  earn = function(v, why) money = money + v; earned = earned + v; ledger[#ledger + 1] = why end }

-- ── selling back ────────────────────────────────────────────────────────────
ok(I.SELL_BACK == 0.6, "the depot buys back at 60 %")
ok(I.sellPrice("medkit") == 90 and I.sellPrice("surveyor") == 1440 and I.sellPrice("laser") == 540,
  "sell prices: medkit $90, rifle $1440, laser $540")
ok(I.sellPrice("nope") == 0 and not I.sellable("nope"), "an unknown item sells for nothing")
inv.addItem("astro", "medkit", 3)
inv.addItem("astro", "o2tank", 2)
local m0 = money
local n, paid, why = inv.sellItem("astro", "medkit", 1)
ok(n == 1 and paid == 90 and money == m0 + 90, "sold a medkit for $90 (" .. tostring(paid) .. ")")
ok(inv.itemCount("astro", "medkit") == 2, "…and it left the pack")
ok(ledger[#ledger]:find("Medkit", 1, true) ~= nil, "…and the ledger says what: " .. tostring(ledger[#ledger]))
n, paid = inv.sellItem("astro", "medkit", 5)
ok(n == 2 and paid == 180 and inv.itemCount("astro", "medkit") == 0, "selling more than is there sells what is there")
n, paid, why = inv.sellItem("astro", "medkit", 1)
ok(n == 0 and paid == 0 and why ~= nil, "none left: refused (" .. tostring(why) .. ")")
inv.drawFill("astro", "o2tank", 400)
n, paid = inv.sellItem("astro", "o2tank", 1)
ok(n == 1 and paid == 210, "a part-used tank sells at the same price ($210)")
ok(#inv.fills("astro", "o2tank") == 1, "…and its level went with it")
ok(earned == 90 + 180 + 210, "the company was paid every sale (" .. earned .. ")")
-- buy then sell back: a loss, never a profit
local before = money
inv.buyItem("astro", "laser", 1)
inv.sellItem("astro", "laser", 1)
ok(money < before and before - money == 900 - 540, "buying and selling back costs 40 % ($" .. (before - money) .. ")")

-- ── the item card ───────────────────────────────────────────────────────────
for _, s in ipairs(I.shopList()) do
  local c = I.card(s.id)
  ok(c and c.name == s.name and c.kind and #c.about > 0 and #c.rows >= 4, "a card for " .. s.id)
  ok(c and c.prefab ~= nil, "…with a model to show (" .. s.id .. ")")
  local has = {}
  for _, r in ipairs(c and c.rows or {}) do has[r[1]] = r[2] end
  ok(has.Mass and has.Bulk and has.Price and has["Sells back"], "…mass, bulk, price and sell-back (" .. s.id .. ")")
end
local function rows_of(c) local t = {} for _, r in ipairs(c.rows) do t[r[1]] = r[2] end return t end
local mk = rows_of(I.card("medkit"))
ok(mk.Treats and mk.Treats:find("50%", 1, true) and mk.Treats:find("4 s", 1, true), "medkit card: +50 % over 4 s — " .. tostring(mk.Treats))
ok(mk.Revives and mk.Revives:find("25%", 1, true) and mk.Revives:find("6 s", 1, true), "medkit card: revive at 25 % after 6 s — " .. tostring(mk.Revives))
ok(mk.Price == "$150" and mk["Sells back"]:find("$90", 1, true), "medkit card: $150, sells back $90")
local rf = rows_of(I.card("surveyor"))
ok(rf.Bolt and rf.Bolt:find("380 m/s", 1, true) and rf.Bolt:find("450 m", 1, true), "rifle card: 380 m/s, 450 m — " .. tostring(rf.Bolt))
ok(rf.Damage and rf.Damage:find("30 m", 1, true), "rifle card: damage at range — " .. tostring(rf.Damage))
-- live numbers win over the defaults
local rf2 = rows_of(I.card("surveyor", { bolt_speed = 500, dmg30 = 0.4, hits30 = 3 }))
ok(rf2.Bolt:find("500 m/s", 1, true) and rf2.Damage:find("40%", 1, true) and rf2.Damage:find("3 hits", 1, true),
  "the rifle's own script's numbers are quoted when it lends them")
-- the card's damage default agrees with the rifle's own rule
do
  local sv = load_script("scripts/surveyor.lua", "surveyor")
  if sv.crewDamage then
    local d30 = sv.crewDamage(1, 30, "body")
    ok(math.abs(d30 - 0.512) < 0.01, string.format("the default 30 m damage (51%%) is the rifle's: %.3f", d30))
    ok(sv.hitsToKill(30) == 2 and sv.hitsToKill(150) == 3, "…and so are its hit counts")
  end
end
ok(I.card("nope") == nil, "no card for an unknown item")

-- ── supply crates: containers ───────────────────────────────────────────────
ok(inv.cap("crate:1") == 400 and inv.volCap("crate:1") == 480, "a crate holds 400 kg and 480 L")
inv.addItem("astro", "repairkit", 2)
inv.addItem("astro", "beacon", 2)
inv.add("astro", "iron", 10)
local moved, mwhy = inv.moveItem("astro", "crate:1", "repairkit", 1)
ok(moved == 1 and inv.itemCount("crate:1", "repairkit") == 1 and inv.itemCount("astro", "repairkit") == 1,
  "a repair kit into the crate")
ok(inv.transfer("astro", "crate:1", "iron", 10) == 10 and inv.count("crate:1", "iron") == 10, "a stack of iron into the crate")
-- the litres bind: 26 beacons (18 L each) can't all go in
inv.addItem("astro", "beacon", 30, { force = true })
moved, mwhy = inv.moveItem("astro", "crate:1", "beacon", 32)
ok(moved == 26 and mwhy and mwhy:find("L free", 1, true), "litres bind a crate: " .. moved .. " beacons in, " .. tostring(mwhy))
ok(inv.itemCount("astro", "beacon") == 6, "…the rest stayed in the pack (nothing destroyed)")
ok(inv.volume("crate:1") <= 480, "…and the crate is not over its litres (" .. inv.volume("crate:1") .. ")")
-- the mass binds too
inv.add("base", "uranium", 200)
local u = inv.transfer("base", "crate:2", "uranium", 200)
ok(u == math.floor(400 / 3.2) and inv.mass("crate:2") <= 400, "mass binds a crate: " .. u .. " uranite (3.2 kg each) in")
-- tanks keep their levels through a crate
inv.drawFill("astro", "o2tank", 100)
local lv = inv.fills("astro", "o2tank")[1]
inv.moveItem("astro", "crate:3", "o2tank", 1)
ok(math.abs((inv.fills("crate:3", "o2tank")[1] or 0) - lv) < 1e-6, "a tank keeps its air in a crate")
-- and back out (once the forced-in beacons have gone to the warehouse)
inv.moveItem("astro", "base", "beacon", 99)
moved = inv.moveItem("crate:1", "astro", "repairkit", 1)
ok(moved == 1 and inv.itemCount("crate:1", "repairkit") == 0, "taken back out")

-- ── the save keeps them ─────────────────────────────────────────────────────
ok(type(store["inv.gear.crate:1"]) == "table" and store["inv.gear.crate:1"].beacon == 26, "the crate's items are save keys")
ok(type(store["inv.crate:1"]) == "table" and store["inv.crate:1"].iron == 10, "…and its materials")
envs.inventory = nil
local inv2 = load_script("scripts/inventory.lua", "inventory")
ok(inv2.itemCount("crate:1", "beacon") == 26 and inv2.count("crate:1", "iron") == 10
  and inv2.itemCount("crate:3", "o2tank") == 1, "a fresh session (same save) finds the crates' contents")
ok(math.abs((inv2.fills("crate:3", "o2tank")[1] or 0) - lv) < 1e-6, "…the tank's level too")

-- ── supply crates: the layout ───────────────────────────────────────────────
local SC = load_script("scripts/supply_crates.lua", "supply_crates")
ok(#SC.LAYOUT == 5, "five crates round the base")
local seen = {}
for _, e in ipairs(SC.LAYOUT) do
  ok(not seen[e.id] and e.name and (e.along == "u" or e.along == "v"), "crate " .. e.id .. " named, laid along an axis")
  seen[e.id] = true
end
ok(SC.cidOf(3) == "crate:3" and SC.isCrate("crate:3") and not SC.isCrate("locker:3") and not SC.isCrate(nil), "crate ids")
ok(SC.labelOf("crate:1") == "Depot crate A" and SC.labelOf("hold:x") == nil, "crate labels")
local pts = { { id = 1, x = 0, y = 0, z = 0 }, { id = 2, x = 1.5, y = 0, z = 0 } }
local e, d = SC.pick(pts, 1.2, 0, 0, 2.4)
ok(e and e.id == 2 and math.abs(d - 0.3) < 1e-9, "the nearest crate within reach")
ok(SC.pick(pts, 10, 0, 0, 2.4) == nil, "none out of reach")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_depot_crates: %d checks, %d FAILED", checks, #failures))
  os.exit(1)
end
print(string.format("✓ depot + crates: %d checks", checks))
