-- SMOKE: the base works (playtest 2026-11-02) — the Materials Intake's rules
-- (scripts/material_intake.lua) and the Repair Bay's work order (scripts/
-- repair_bay.lua), plus the progression and storage fixes that rode with them:
--
--   * the intake reads a resource body's tags (docs/resources.md: "resource",
--     "mat:<id>", "qty:<n>", or materials.resourceOf), an untagged body by
--     its prefab's kind, a base prop as stock returned, anything else the gun
--     lifts as scrap — and never a craft, the crew, a beacon or a flag; bulk
--     rock is sold on the spot, ore and timber go to the warehouse;
--   * scrap pays by weight under a cap, and a lost craft's hull at most a
--     share of what it was worth;
--   * the belt frame: a point's along / across / up;
--   * the repair bay prices every line before the work (wear by the part's
--     price, propellant, charge, a minimum fee), nothing to do is free, a
--     broken-off part is named, and the bay floor is a box;
--   * the Battery Pack comes after the Battery (research.lua);
--   * a storage locker's menu has no separate "Contents" row.
--
--   luajit solar/tests/smoke_base_works.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local store, envs = {}, {}
local API = {
  findScript = function(kind) return envs[kind] end,
  findScripts = function() return {} end,
  log = function() end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return 0 end
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

local M = load_script("scripts/materials.lua", "materials")
local MI = load_script("scripts/material_intake.lua", "material_intake")
local RB = load_script("scripts/repair_bay.lua", "repair_bay")
local RS = load_script("scripts/research.lua", "research")

local grade = M.grade or function(m) return m == "regolith" and "bulk" or "ore" end
local function D(t) t.grade = t.grade or grade; t.label = t.label or M.label; return t end

-- ── what the intake takes ───────────────────────────────────────────────────
local e = MI.classify(D({ tags = { "log", "resource", "mat:timber", "qty:4" }, name = "LooseLog 3", mass = 0.4 }))
ok(e and e.kind == "mat" and e.mat == "timber" and e.qty == 4 and not e.sell, "a tagged log: 4 timber, to the warehouse")
ok(e and e.label == "Log", "…named as a log")
e = MI.classify(D({ tags = { "loose_rock" }, name = "LooseRock 9", mass = 0.09, res = { mat = "iron", qty = 3 } }))
ok(e and e.mat == "iron" and e.qty == 3 and not e.sell, "materials.resourceOf wins: 3 iron ore")
e = MI.classify(D({ tags = { "loose_rock", "resource", "mat:regolith", "qty:2" }, name = "LooseRock 2" }))
ok(e and e.mat == "regolith" and e.sell == (grade("regolith") == "bulk"), "bulk rock is sold on the spot")
e = MI.classify(D({ tags = { "log" }, name = "LooseLog 1", mass = 0.42, scale = 1.0 }))
ok(e and e.mat == "timber" and e.qty == 3, "an untagged log (an older save's) by its kind: 3 timber")
e = MI.classify(D({ tags = { "log" }, name = "LooseLog 1", scale = 1.5 }))
ok(e and e.qty == 10, "…and a bigger log by its wood (scale 1.5: 10)")
e = MI.classify(D({ tags = {}, name = "LooseRock 5", worth = { mat = "copper", n = 2, label = "Copper Ore chunk" } }))
ok(e and e.mat == "copper" and e.qty == 2, "tool_belt.worthOf for a chunk it priced")
e = MI.classify(D({ tags = { "prop", "can" }, name = "PropCan", mass = 0.07 }))
ok(e and e.kind == "stock", "the base's own cargo can: returned to stores")
e = MI.classify(D({ tags = {}, name = "Vessel", mass = 0.3 }))
ok(e and e.kind == "scrap" and math.abs(e.kg - 300) < 1e-6, "a sheared-off part: 300 kg of scrap")
ok(MI.classify(D({ tags = {}, name = "Rover", craft = true, mass = 2 })) == nil, "a craft is never taken")
ok(MI.classify(D({ tags = {}, name = "Astronaut", crew = true })) == nil, "the crew is never taken")
ok(MI.classify(D({ tags = {}, name = "RelayBeacon" })) == nil, "a relay beacon is left alone")
ok(MI.classify(D({ tags = { "flag" }, name = "Flag 2" })) == nil, "a flag is left alone")
e = MI.classify(D({ tags = {}, name = "Kestrel", craft = true, lost = true, mass = 1.5, wreckValue = 400 }))
ok(e and e.kind == "scrap" and e.cap == 400, "a lost craft's hull is scrap")

-- ── what scrap pays ─────────────────────────────────────────────────────────
ok(MI.quoteScrap({ kg = 300 }, 0.25, 300) == 75, "scrap: $0.25 a kg")
ok(MI.quoteScrap({ kg = 5000 }, 0.25, 300) == 300, "…capped")
ok(MI.quoteScrap({ kg = 1500, cap = 400 }, 0.25, 300, 0.25) == 100, "a wreck pays at most a quarter of its parts' worth")
ok(MI.quoteScrap({ kg = 0.5 }, 0.25, 300) == 1, "…and never nothing")

-- ── the receipt ─────────────────────────────────────────────────────────────
ok(MI.receiptText({ kind = "mat", what = "Log", qty = 4, took = 4, label = "Timber" }):match("%+4 Timber"), "a warehouse receipt")
ok(MI.receiptText({ kind = "mat", what = "Rock", qty = 2, label = "Regolith", cash = 5, money = "$5" }):match("sold"), "a sale receipt")
ok(MI.receiptText({ kind = "scrap", what = "Wreckage", kg = 300, cash = 75, money = "$75" }):match("%$75"), "a scrap receipt")

-- ── the belt's frame ────────────────────────────────────────────────────────
local B = { o = { x = 10, y = 0, z = 0 }, a = { x = 0, y = 0, z = -1 }, w = { x = 1, y = 0, z = 0 }, u = { x = 0, y = 1, z = 0 } }
local s, w, h = MI.beltLocal(B, 10.5, 0.3, -4)
ok(math.abs(s - 4) < 1e-9 and math.abs(w - 0.5) < 1e-9 and math.abs(h - 0.3) < 1e-9, "along / across / up the belt")

-- ── the repair bay's order ──────────────────────────────────────────────────
local P = RB.defaults
local q = RB.quote({ parts = { { uid = 1, hp = 0.5, cost = 200 }, { uid = 2, hp = 0.25, cost = 40, wheel = true } },
                     fuel = 100, charge = 150 }, P)
local mend = 200 * P.rate * 0.5 + 40 * P.rate * 0.75
ok(q.parts == 2 and q.wheels == 1 and math.abs(q.mend - mend) < 1e-9, "two worn parts, one a wheel, priced by wear")
ok(q.fuel == 100 and math.abs(q.fuelCost - 100 * P.fuel_price) < 1e-9, "propellant by the unit")
ok(q.charge == 150 and math.abs(q.chargeCost - 150 * P.charge_price) < 1e-9, "charge by the EC")
ok(q.total == math.max(P.min_fee, math.floor(mend + 100 * P.fuel_price + 150 * P.charge_price + 0.5)), "the total")
ok(q.total < 200 * 0.25, "cheap: well under a quarter of the part it mends")
q = RB.quote({ parts = {}, fuel = 0.2, charge = 0.1 }, P)
ok(q.nothing and q.total == 0, "nothing to do is free")
q = RB.quote({ parts = { { uid = 1, hp = 0.99, cost = 10 } } }, P)
ok(q.total == P.min_fee, "a scratch costs the minimum fee")
local lines = RB.orderLines(RB.quote({ parts = { { hp = 0.5, cost = 100, wheel = true } }, fuel = 10, lost = 1 }, P))
ok(#lines == 3 and lines[1][1]:match("1 wheel") and lines[3][1]:match("no mount aboard"), "the order's lines name wheels and parts that can't be refit")
-- REFIT: a part that broke off, at `refit_rate` of its price, one line each;
-- its tanks and batteries come empty and go on the propellant and charge lines
q = RB.quote({ parts = {}, refit = { { uid = 7, cost = 40, label = "Stowage Locker" },
                                     { uid = 10, cost = 150, label = "FT-S Tank", fuel = 80 },
                                     { uid = 12, cost = 60, label = "Battery", ec = 150 } }, fuel = 0, charge = 0 }, P)
ok(q.refit == 3 and math.abs(q.refitCost - 250 * P.refit_rate) < 1e-9, "three parts refit at their share of the price")
ok(q.fuel == 80 and q.charge == 150, "the new tank and battery are filled on the order")
ok(q.total == math.floor(250 * P.refit_rate + 80 * P.fuel_price + 150 * P.charge_price + 0.5), "…and priced in the total")
ok(not q.nothing and #q.refitUids == 3, "a refit is work")
lines = RB.orderLines(q)
ok(lines[1][1] == "Refit  FT-S Tank" and lines[1][2] == "$" .. math.floor(150 * P.refit_rate + 0.5), "the dearest refit first, priced")
ok(lines[2][1] == "Refit  Battery" and lines[3][1] == "Refit  Stowage Locker", "every refit part named")
local many = {}
for i = 1, 9 do many[i] = { uid = i, cost = 10 * i, label = "P" .. i } end
lines = RB.orderLines(RB.quote({ refit = many }, P), nil, 6)
ok(#lines == 6 and lines[6][1] == "Refit  4 more parts" and lines[6][2] == "$" .. math.floor((10 + 20 + 30 + 40) * P.refit_rate + 0.5),
  "past six, the cheapest are summed on one line")
ok(RB.inBay(0, 0.5, 0) and RB.inBay(5.0, 0.3, -7.0) and not RB.inBay(6.0, 0.3, 0) and not RB.inBay(0, 6, 0), "the bay floor box")

-- ── progression: the Battery Pack comes with 25 % relay coverage ───────────
-- (playtest 2026-11-04) no copper and no Battery needed; the big Battery
-- still wants copper.
ok(RS.TECH.packB and RS.TECH.packB.after == nil and RS.TECH.packB.mat == nil, "the Battery Pack needs neither the Battery nor copper")
ok(RS.TECH.battery.mat == "copper", "the Battery still needs copper")
store["res.done"] = {}
store["prog.done"] = {}
ok(not RS.isUnlocked("packB") and (RS.blockedBy("packB") or ""):find("Relay Network", 1, true) ~= nil, "…locked until the Relay Network, and says so")
store["prog.done"] = { relay_net = true }
ok(RS.isUnlocked("packB"), "…open in a save that already finished the Relay Network")
store["prog.done"] = {}
ok(RS.grant("packB", "test") and RS.isUnlocked("packB"), "…and granted by the 25 % goal")
store["res.done"] = {}

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_base_works: %d checks, %d FAILED", checks, #failures))
  os.exit(1)
end
print(string.format("✓ base works: %d checks", checks))
