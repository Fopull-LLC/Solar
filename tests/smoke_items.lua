-- SMOKE HARNESS for scripts/items.lua (the item registry) and the item half of
-- scripts/inventory.lua (docs/crew-and-items.md §5.1–5.3, §5.8):
--
--   * mass AND litres bind items; a move that half fits moves what fits and
--     says why the rest didn't (kilograms or litres, with the number);
--   * "astro" resolves to the active crew member's pack once the roster is in
--     the scene, and to its own container before it;
--   * moveItem refusals carry their reasons;
--   * an old save's carried beacons (inv.gear.astro) are still there after the
--     pack moves to crew member #1;
--   * the standard issue happens once (a tool left in a locker stays there);
--   * the belt is the pack's holdables in order, worn items never on it;
--   * the Oxygen Tank: draw order (emptiest first), several tanks stacking,
--     refills, levels moving with the tanks, and persistence across a reload.
--
--   luajit solar/tests/smoke_items.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs((a or 0) - (b or 0)) < (e or 1e-6) end

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
local money = 10000
envs.company = { valid = true, spend = function(v) if v > money then return false end money = money - v return true end }

-- ── the registry ────────────────────────────────────────────────────────────
ok(I.def("rcspack").kind == "worn" and not I.holdable("rcspack"), "the RCS Pack is worn, never held")
ok(I.def("o2tank").kind == "worn" and not I.holdable("o2tank"), "the Oxygen Tank is worn, never held")
ok(I.gripOf("repairkit") == "left" and I.gripOf("beacon") == "shoulder" and I.gripOf("laser") == "two", "grips")
ok(I.def("flag").deploy.store == "deployables" and I.def("beacon").deploy.store == "comms", "deploy stores")
ok(near(I.repairSecs(0.4), 15.6) and near(I.repairSecs(0.95), 6.8), "repair duration: 6 + 16 × (1 − hp)")
local belt = I.belt(function(id) return ({ repairkit = 2, gravgun = 1, beacon = 1, rcspack = 1, o2tank = 3, laser = 1 })[id] or 0 end)
local ids = {}
for _, b in ipairs(belt) do ids[#ids + 1] = b.id end
ok(table.concat(ids, ",") == "gravgun,laser,beacon,repairkit", "the belt: tools, deployables, consumables; worn never: " .. table.concat(ids, ","))
local issue = I.issueList()
ok(#issue == 2 and issue[1] == "gravgun" and issue[2] == "laser", "the standard issue is the two tools")

-- ── the pack: kilograms and litres ──────────────────────────────────────────
ok(inv.cap("astro") == 106 and inv.volCap("astro") == 60, "a pack is 106 kg and 60 L")
local got = inv.issueKit("astro")
ok(#got == 2 and inv.itemMass("astro") == 16 and inv.volume("astro") == 30, "the issue weighs 16 kg and fills 30 L")
ok(#inv.issueKit("astro") == 0, "the issue happens once")
inv.removeItem("astro", "laser", 1)
inv.ensureKit("astro")
ok(inv.itemCount("astro", "laser") == 0, "a tool left behind is not re-issued")
inv.addItem("astro", "laser", 1)

-- beacons: 18 L each. 30 L of tools leaves room for one (and 12 L over).
local n, why = inv.addItem("astro", "beacon", 3)
ok(n == 1 and why and why:match("^no room: 12 L free"), "litres bind items, honestly: " .. tostring(n) .. " " .. tostring(why))
-- kilograms bind too: fill the pack with iron, then a kit won't fit by mass
local room_kg = inv.free("astro")
inv.add("astro", "iron", 1000)
local n2, why2 = inv.addItem("astro", "repairkit", 1)
ok(n2 == 0 and why2 and why2:match("kg free"), "mass binds items: " .. tostring(why2))
inv.clear("astro")
ok(near(inv.free("astro"), room_kg), "materials out again")

-- ── lockers, moves, refusals ────────────────────────────────────────────────
inv.setCap("locker:1", 80)
ok(inv.volCap("locker:1") == 120, "a locker is 120 L")
inv.addItem("locker:1", "repairkit", 3)
local m, w = inv.moveItem("locker:1", "astro", "repairkit", 1)
ok(m == 1 and w == nil and inv.itemCount("locker:1", "repairkit") == 2 and inv.itemCount("astro", "repairkit") == 1, "take one kit from a locker")
m, w = inv.moveItem("locker:1", "astro", "repairkit", 5)
-- 30 + 18 + 6 = 54 L: room for one more 6 L kit
ok(m == 1 and w and w:match("L free"), "a partial take says why: " .. tostring(m) .. " " .. tostring(w))
ok(inv.itemCount("locker:1", "repairkit") == 1, "...and the rest stays in the locker")
m, w = inv.moveItem("locker:1", "astro", "flag", 1)
ok(m == 0 and w == "none to move", "refusal: none to move")
m, w = inv.moveItem("astro", "salvage:9", "laser", 1)
ok(m == 0 and w:match("salvage crate"), "refusal: a crate only gives back")
m, w = inv.moveItem("astro", "astro", "laser", 1)
ok(m == 0 and w, "refusal: same container")
m, w = inv.moveItem("astro", "locker:1", "nonesuch", 1)
ok(m == 0 and w == "no such item", "refusal: unknown item")
money = 100
local okb, whyb = inv.buyItem("base", "rcspack", 1)
ok(not okb and whyb == "not enough money", "buying spends money, all or nothing")
money = 10000
ok(inv.buyItem("base", "rcspack", 1) and inv.itemCount("base", "rcspack") == 1, "the warehouse buys")

-- ── the alias: "astro" → the active crew member's pack ─────────────────────
-- an old save: two carried beacons and planted ones (comms keys untouched)
store = {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
store["inv.gear.astro"] = { gravgun = 1, laser = 1, beacon = 2 }
store["inv.astro"] = { iron = 5 }
store["comms.beacons"] = { 1, 2 }
ok(inv.resolve("astro") == "astro" and inv.itemCount("astro", "beacon") == 2, "no roster: astro is its own pack")
-- the roster arrives (WS1's crew.lua, stubbed by its interface) and adopts the pack
local active = 1
T = T + 5   -- (inventory asks for the roster again at most every 2 s)
envs.crew = { valid = true, activeId = function() return active end, packOf = function(id) return "crew:" .. id end }
ok(inv.adoptPack("astro", "crew:1"), "the pack moves to member #1")
ok(inv.resolve("astro") == "crew:1", "astro resolves to crew:1")
ok(inv.itemCount("astro", "beacon") == 2 and inv.count("astro", "iron") == 5, "old carried beacons read through the alias")
ok(store["inv.gear.astro"] and next(store["inv.gear.astro"]) == nil, "the old key is emptied")
ok(store["comms.beacons"][2] == 2, "planted beacons are comms' and untouched")
ok(inv.cap("crew:1") == 106 and inv.volCap("astro") == 60, "a crew pack has the suit's limits")
active = nil
ok(inv.resolve("astro") == "astro", "nobody on foot and no commander: astro stays itself")
active = 1

-- ── the Oxygen Tank ─────────────────────────────────────────────────────────
-- (the two old beacons are 36 L: over the pack's 60 with the tools, which a
-- migrated save keeps — they go in the locker to make room for the tanks)
inv.setCap("locker:1", 80)
ok(inv.moveItem("astro", "locker:1", "beacon", 2) == 2, "stow the beacons")
local CAP = I.fillCap("o2tank")
ok(CAP == 900, "a tank is 15 minutes of air")
inv.addItem("crew:1", "o2tank", 2)
local total, list = I.o2Reserve("astro")
ok(near(total, 2 * CAP) and #list == 2, "two tanks stack their reserve")
ok(near(I.drawO2("astro", 100), 100), "the suit draws from the tanks")
_, list = I.o2Reserve("astro")
ok(near(list[1], CAP - 100) and near(list[2], CAP), "...from one tank, the other stays full")
I.drawO2("astro", 50)
_, list = I.o2Reserve("astro")
ok(near(list[1], CAP - 150) and near(list[2], CAP), "the emptiest tank is drawn first (finish an open bottle)")
-- a third tank, half used, arrives from a locker
inv.addItem("locker:1", "o2tank", 1, { force = true, fills = { 300 } })
inv.addItem("locker:1", "o2tank", 1)
ok(inv.moveItem("locker:1", "astro", "o2tank", 1) == 1, "take a tank from the locker")
_, list = I.o2Reserve("astro")
ok(#list == 3 and near(list[3], CAP), "the fullest tank in the locker is the one taken")
ok(near(inv.fills("locker:1", "o2tank")[1], 300), "...the half-used one stays behind")
-- draining across tanks: more than one tank's worth
local before = I.o2Reserve("astro")
local d = I.drawO2("astro", CAP + 50)
_, list = I.o2Reserve("astro")
ok(near(d, CAP + 50) and near(I.o2Reserve("astro"), before - CAP - 50), "a long draw runs across tanks")
ok(near(list[1], 0) and #list == 3, "an empty tank stays in the pack as an item, to refill")
-- more than everything: the shortfall is the suit's own supply
local all = I.o2Reserve("astro")
ok(near(I.drawO2("astro", all + 500), all) and near(I.o2Reserve("astro"), 0), "dry tanks give what they had; the suit's own supply covers the rest")
ok(inv.itemCount("astro", "o2tank") == 3, "empty tanks are still carried")
-- refills: a locker's menu / boarding (items.refillO2), and the warehouse for free
ok(near(I.refillO2("astro"), 3 * CAP) and near(I.o2Reserve("astro"), 3 * CAP), "a refill tops every tank up")
I.drawO2("astro", 400)
inv.moveItem("astro", "base", "o2tank", 3)
ok(near(inv.fills("base", "o2tank")[1], CAP), "tanks put in the warehouse are refilled")
inv.moveItem("base", "astro", "o2tank", 2)
-- the pack panel's view
local row
for _, e in ipairs(inv.itemList("astro")) do if e.id == "o2tank" then row = e end end
ok(row and #row.fills == 2 and near(row.fill, 2 * CAP) and row.fillCap == CAP, "itemList carries each tank's level")
-- persistence: a fresh inventory script over the same save store
I.drawO2("astro", 123)
local inv2 = load_script("scripts/inventory.lua", "inventory")
local _, l2 = I.o2Reserve("astro")
ok(inv2 == envs.inventory and near(l2[1], CAP - 123) and near(l2[2], CAP), "tank levels survive a reload")
-- an old save whose tanks have no levels (or a cheat) reads them full
store["inv.fill.crew:1"] = {}
local _, l3 = I.o2Reserve("astro")
ok(#l3 == 2 and near(l3[1], CAP), "missing levels read as full tanks")
-- a salvage crate keeps them (forced: a death drop)
ok(inv.moveItem("astro", "salvage:4", "o2tank", 1, { force = true }) == 1 and #inv.fills("salvage:4", "o2tank") == 1, "a crate carries a tank and its level")

if #failures > 0 then
  print("ITEMS SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("ITEMS SMOKE OK — %d checks passed", checks))
