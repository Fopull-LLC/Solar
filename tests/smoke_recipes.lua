-- SMOKE: the material layer (expansion X4: deep-space N2, N3, N5, N6, N8;
-- docs/base-building.md §22, docs/resources.md §7).
--
--   * materials (N3): the six refined materials and the propellant, counted in
--     kilograms (a unit is 1 kg), real densities, the litres they take, two
--     kept in tanks; refined stock teaches the lab nothing;
--   * recipes (N5): every part of the VAB catalogue, the BASE section and the
--     kit (in each material) has a recipe whose materials all exist; the
--     worked numbers of N6 (Pod Mk1 780/130/130 + $100, the FT-S tank's 40 %,
--     the Anvil's Alloy and Wiring, the Shield Wall all Regocrete); the kit
--     piece is its own material; what is made at home only says so;
--   * part items (N2): "part:<id>" resolves to a crated item that weighs the
--     part and takes recipes.crateLitres; the pack and a hold weigh it; a
--     scene without the parts (the VAB) reads it from the save;
--   * containers (N8): fab/silo/hopper capacities, a silo's one material,
--     propellant refused in a pack; the reach rule's order (nearest first, the
--     pack last, 30 m) and drawFrom's plan;
--   * base_economy: the off-world quote is "item" with a crate in reach,
--     "away" with the recipe without one; the card lines; the crated quote.
--
--   luajit solar/tests/smoke_recipes.lua   (prints every recipe with -v)

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local VERBOSE = arg and arg[1] == "-v"

local store = {}
local scripts = {}
local function env(extra)
  local E = setmetatable({
    time = 1.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load(path, E)
  E = E or env()
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local M = load("materials.lua"); scripts.materials = M
local R = load("recipes.lua"); scripts.recipes = R
local PR = load("parts_registry.lua")
local PK = load("parts_kit.lua"); scripts.parts_kit = PK
local PB = load("parts_base.lua"); scripts.parts_base = PB
local BE = load("base_economy.lua"); scripts.base_economy = BE

-- ── materials ───────────────────────────────────────────────────────────────
for _, id in ipairs(M.REFINED) do
  local d = M.REG[id]
  check(d and d.class == "refined" and d.kg == 1.0 and (d.density or 0) > 100 and d.from, "refined " .. id .. " is registered by the kg")
  check(M.grade(id) == "refined" and M.isRefined(id), id .. " grades as refined")
  check(M.researchValue(id, nil, true) == 0, id .. " earns no research")
end
check(#M.REFINED == 8, "six refined materials, the propellant and planks (W1)")
check(M.density("steel") == 7850 and M.density("iron") == 4200, "densities: steel 7850, iron ore a litre of 4.2 kg")
check(math.abs(M.litresOf("steel", 785) - 100) < 1e-9, "785 kg of steel is 100 L")
check(M.inTank("propellant") and M.inTank("gas") and not M.inTank("steel"), "propellant and gas live in tanks")
check(M.amountText("steel", 780) == "780 kg" and M.amountText("iron", 12) == "12 ×", "refined reads in kg, ore in units")
check(M.codex("steel") and #M.codex("steel").facts >= 3, "steel has a codex entry")

-- ── recipes over every part ────────────────────────────────────────────────
local all, bad = 0, {}
local function judge(id, def, section)
  local r = R.recipeFor(def, section, id)
  if not r then bad[#bad + 1] = id .. ": no recipe" return end
  all = all + 1
  for _, e in ipairs(r.mats) do
    if not (M.REG[e.mat] and M.isRefined(e.mat)) then bad[#bad + 1] = id .. ": " .. tostring(e.mat) end
    if not (e.kg > 0) then bad[#bad + 1] = id .. ": zero kg" end
  end
  if not r.perMetre and r.total > (def.mass or 0) * 1000 + 1 then bad[#bad + 1] = id .. ": more material than mass" end
  if VERBOSE then print(string.format("%-22s %-10s %8.1f kg  %s%s", id, section or "", r.kg, R.lineOf(r), r.shipOnly and ("  [home: " .. r.shipOnly .. "]") or "")) end
  return r
end
for _, s in ipairs(PR.CATALOGUE) do for _, id in ipairs(s[2]) do if PR.REG[id] then judge(id, PR.REG[id], s[1]) end end end
for _, id in ipairs(PB.ORDER) do judge(id, PB.partInfo(id), "BASE") end
local nkit = 0
for piece, P in pairs(PK.PIECES) do
  for _, mat in ipairs(P.mats) do
    local id = PK.idOf(piece, mat)
    local d = PK.partInfo(id)
    if d then judge(id, d, d.section); nkit = nkit + 1 end
  end
end
for _, id in ipairs(PK.LIVE_ORDER) do judge("vab." .. id, PK.partInfo("vab." .. id), "FITTINGS") end
check(#bad == 0, "every recipe names real refined materials: " .. table.concat(bad, "; "))
check(all > 150 and nkit > 80, string.format("recipes for %d parts (%d kit pieces)", all, nkit))

local function rec(id, sec) return R.recipeFor(PR.REG[id], sec, id) end
local pod = rec("pod", "COMMAND")
check(R.kgOf(pod, "steel") == 780 and R.kgOf(pod, "wiring") == 130 and R.kgOf(pod, "glass") == 130 and pod.fittings == 100,
  "N6: Pod Mk1 = 780 kg Steel, 130 Wiring, 130 Glass, $100 fittings: " .. R.lineOf(pod))
local tank = rec("tankS", "PROPULSION")
check(R.kgOf(tank, "steel") == math.floor(0.4 * PR.REG.tankS.mass * 1000 + 0.5) and #tank.mats == 1, "N5: a tank is 40 % Steel: " .. R.lineOf(tank))
local anvil = rec("engineM", "PROPULSION")
check(R.kgOf(anvil, "alloy") == 540 and R.kgOf(anvil, "wiring") == 90 and R.kgOf(anvil, "steel") == 0, "N6: the Anvil is 540 kg Alloy, 90 Wiring: " .. R.lineOf(anvil))
local wheel = rec("wheelM", "ROVER")
check(R.kgOf(wheel, "alloy") > 0 and R.kgOf(wheel, "steel") == 0, "a ROVER part is Alloy")
local sw = R.recipeFor(PB.partInfo("shieldWall"), "BASE", "shieldWall")
check(R.kgOf(sw, "regocrete") == PB.partInfo("shieldWall").mass * 1000 and #sw.mats == 1 and sw.fittings == math.floor(1100 * 0.10 + 0.5),
  "the Shield Wall is all Regocrete, 10 % fittings: " .. R.lineOf(sw))
local skid = R.recipeFor(PB.partInfo("isotopeSkid"), "BASE", "isotopeSkid")
check(skid.shipOnly ~= nil, "the Isotope Skid is made at home only")
local ws = R.recipeFor(PK.partInfo("wall.steel"), "WALL", "wall.steel")
check(#ws.mats == 1 and ws.mats[1].mat == "steel" and math.abs(ws.mats[1].kg - PK.partInfo("wall.steel").mass * 1000) <= 0.5,
  "a steel wall is its own steel: " .. R.lineOf(ws))
local wr = PK.partInfo("wall.regocrete") and R.recipeFor(PK.partInfo("wall.regocrete"), "WALL", "wall.regocrete")
check(wr == nil or (wr.mats[1].mat == "regocrete"), "a regocrete wall is Regocrete")
local cab = R.recipeFor(PB.partInfo("powerCable"), "BASE", "powerCable")
check(cab.perMetre and R.kgOf(cab, "wiring") > 0, "a cable's recipe is a metre's: " .. R.lineOf(cab))
check(R.lineOf(pod) == "780 kg Steel · 130 kg Wiring · 130 kg Glass + $100", "the card line: " .. R.lineOf(pod))
local rows, ok = R.needHave(pod, function(m) return m == "steel" and 800 or 0 end)
check(not ok and rows[1].short == 0 and rows[2].short == 130, "need / have")

-- ── part items ──────────────────────────────────────────────────────────────
check(R.partItemId("wall.steel") == "part:wall.steel" and R.partIdOf("part:vab.pod") == "vab.pod" and R.partIdOf("gravgun") == nil, "part item ids")
local it = R.partItemDef("wall.steel", PK.partInfo("wall.steel"))
check(it.kind == "part" and math.abs(it.kg - PK.partInfo("wall.steel").mass * 1000) < 0.06 and it.L >= 1 and it.name:find("crated"), "a crated wall")
local lt = R.crateLitres({ h = 13.5, rx = 1.3, rz = 1.3, mass = 1.5 })
check(lt == 6000, "a lattice tower packs at 0.25 kg/L at least: " .. lt)

local I = load("items.lua"); scripts.items = I
-- the registry resolves a crated part through parts_base + recipes, and keeps it
check(I.ITEMS["part:wall.steel"] and I.ITEMS["part:wall.steel"].kind == "part", "ITEMS resolves part:wall.steel")
check(type(store["items.partdefs"]) == "table" and store["items.partdefs"]["part:wall.steel"], "and remembers it in the save")
check(I.ITEMS["part:nothing.here"] == nil and I.ITEMS.flag ~= nil, "unknown parts stay unknown")
local seenPart = false
for k in pairs(I.ITEMS) do if type(k) == "string" and k:sub(1, 5) == "part:" then seenPart = true end end
check(not seenPart, "crated parts never show in pairs(ITEMS)")
local onShop = false
for _, e in ipairs(I.shopList()) do if e.id:sub(1, 5) == "part:" then onShop = true end end
check(not onShop and #I.belt(function(id) return id == "part:wall.steel" and 1 or 0 end) == 0, "not on the shop or the belt")
check(I.card("part:wall.steel") and I.card("part:wall.steel").kind == "Part · in its crate", "the item card")

local V = load("inventory.lua"); scripts.inventory = V
V.setCap("hold:Test", 1000)
local n = V.addItem("hold:Test", "part:wall.steel", 2)
check(n == 2 and math.abs(V.mass("hold:Test") - 2 * it.kg) < 0.1, "a hold weighs two crated walls: " .. V.mass("hold:Test"))
local np, why = V.addItem("crew:1", "part:wall.steel", 1)
check(np == 0 and why, "a 110 kg crated wall won't go in a 90 kg pack: " .. tostring(why))
-- the VAB scene: no parts_base; the save remembers
local I2 = load("items.lua", env({ findScript = function(k) return nil end }))
check(I2.ITEMS["part:wall.steel"] and I2.ITEMS["part:wall.steel"].kg == it.kg, "a scene without the parts reads the crated wall from the save")

-- ── containers ──────────────────────────────────────────────────────────────
check(V.cap("silo:1") == 8000 and V.cap("fab:2") == 2000 and V.cap("hopper:3") == 4000, "silo / fab / hopper capacities")
check(V.add("silo:1", "steel", 500) == 500 and V.add("silo:1", "glass", 10) == 0 and V.whyNot("silo:1", "glass"), "a silo holds one material")
check(V.add("crew:1", "propellant", 10) == 0 and V.add("base", "steel", 100) == 100, "propellant refused in a pack; steel in the warehouse")
check(V.mass("base") >= 100 - 1e-9, "100 kg of steel weighs 100 kg")
local order = R.reachOrder({ { id = "hold:A", d = 12 }, { id = "crate:1", d = 4 }, { id = "crew:1", pack = true }, { id = "hold:far", d = 31 } })
check(table.concat(order, ",") == "crate:1,hold:A,crew:1", "reach: nearest first, the pack last, 30 m: " .. table.concat(order, ","))
local order2 = BE.containersInReach({ { id = "hold:A", d = 12 }, { id = "crate:1", d = 4 }, { id = "crew:1", pack = true } })
check(table.concat(order2, ",") == "crate:1,hold:A,crew:1", "base_economy agrees with a measured d")
local bags = { ["crate:1"] = 0, ["hold:A"] = 3, ["crew:1"] = 1 }
local got, from = R.drawFrom(order, "x", 2, function(c) return bags[c] end, function(c, _, k) bags[c] = bags[c] - k; return k end)
check(got == 2 and from[1].cid == "hold:A" and from[1].n == 2 and bags["crew:1"] == 1, "drawFrom takes the nearest, the pack last")

-- ── quotes ──────────────────────────────────────────────────────────────────
local wdef = PK.partInfo("wall.steel")
local qa = BE.quote(wdef, "WALL", "Moon", "Home", 0, { crated = 0, recipe = ws })
check(qa.mode == "away" and qa.why:find("crated") and qa.recipe == ws, "off-world, nothing in reach: away, with the recipe")
local qi = BE.quote(wdef, "WALL", "Moon", "Home", 0.5, { crated = 2, from = "Rover hold", recipe = ws })
check(qi.mode == "item" and qi.n == 2 and qi.total == BE.footingCost(0.5), "off-world, a crate in reach: item (only the footing paid)")
local p1, r1 = BE.cardLines(qi)
check(p1 == "2 crated" and r1:find("Rover hold"), "the card: " .. tostring(p1) .. " / " .. tostring(r1))
local p2, r2 = BE.cardLines(qa)
check(p2 == "no crate" and r2:find("Steel"), "the card without one: " .. tostring(r2))
local qh = BE.quote(wdef, "WALL", "Home", "Home", 0)
check(qh.mode == "money", "at home: money, as before")
local qc = BE.crateQuote(wdef, "WALL")
check(qc.total == qc.cost + BE.shipping(qc.cost) and qc.foot == 0, "a crated order is price + shipping")
check(BE.deconstructRefund({ cost = 0, ship = 0, foot = 0, total = 0, t = 0, item = "hold:A" }, 1000) == 0, "a crated part's take-down refunds no money")

if #failures > 0 then
  print("RECIPES SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("RECIPES SMOKE: all %d checks passed (%d recipes)", passed, all))
