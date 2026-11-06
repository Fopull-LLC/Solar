-- SMOKE: a reactor plant in the scene (sandbox plan S6; docs/heat-and-nuclear.md
-- §8), on the real structures / bases / base_tower / base_cable / base_power /
-- base_grid / base_shield / thermal / reactor / reactor_plant with stubs for
-- the engine:
--   * an old base (a tower, a hab) has no plant and the grid is as it was;
--   * the fixture's plant on the tower's structure is found; the refuelling
--     rule holds; it starts up and its turbine feeds the base grid while its
--     pumps, heaters and fan are the grid's loads;
--   * a pump switched off: the plant trips on low flow; the console's page
--     and the menu read it; the dose source follows the core's heat;
--   * the save: a new reactor_plant reads the plant back as it was.
--
--   luajit solar/tests/smoke_reactor_scene.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
  return ok
end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local MU, RS = 9.75e10, 2.0e5
local V = math.sqrt(MU / RS)
local R = 800
local bodies = {
  { name = "Sun", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 1.0e4, mu = MU, soi = -1, star = true },
  { name = "Vever", x = RS, y = 0, z = 0, vx = 0, vy = V, vz = 0, radius = R, mu = 1e5, soi = 5e4 },
}
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
  dominant = function() return "Vever" end,
  time = function() return 0 end,
}
local s = { ["base.body"] = "Vever" }
local clock = { a = 1000 }
local scripts = {}
local X = { space = SPACE, terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - R end } }
scripts.thermal = load_script("thermal.lua", env({}, scripts))
local PK = load_script("parts_kit.lua", env({}, scripts)); scripts.parts_kit = PK
local PB = load_script("parts_base.lua", env({}, scripts)); scripts.parts_base = PB
scripts.electronics = load_script("electronics.lua", env({}, {}))
scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
scripts.company = { spend = function() return true end, refund = function() end, earn = function() end, afford = function() return true end }
local STORE = { base = { fuelRod = 40 } }
scripts.inventory = {
  itemCount = function(c, id) return (STORE[c] or {})[id] or 0 end,
  removeItem = function(c, id, n) local h = (STORE[c] or {})[id] or 0; local k = math.min(h, n); STORE[c][id] = h - k; return k end,
  addItem = function(c, id, n) STORE[c] = STORE[c] or {}; STORE[c][id] = (STORE[c][id] or 0) + n; return n end,
}
scripts.crew = { activeId = function() return 2 end, credit = function() end, roster = function() return {} end,
                 hasRole = function() return true end, perk = function() return nil end, bestPerk = function() return nil end }
scripts.field_builder = { pushHistory = function() end }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, X)); scripts.structures = ST
local CB = load_script("base_cable.lua", env(s, scripts, X)); scripts.base_cable = CB
local BPw = load_script("base_power.lua", env(s, scripts, X)); scripts.base_power = BPw
local BG = load_script("base_grid.lua", env(s, scripts, X)); scripts.base_grid = BG
scripts.base_facilities = { setGuards = function() end }
local BT = load_script("base_tower.lua", env(s, scripts, X)); scripts.base_tower = BT
local BS = load_script("base_shield.lua", env(s, scripts, X)); scripts.base_shield = BS
local RXs = load_script("reactor.lua", env(s, scripts, X)); scripts.reactor = RXs
local RP = load_script("reactor_plant.lua", env(s, scripts, X)); scripts.reactor_plant = RP
BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 }); BPw.start({ id = 4 }); BS.start({ id = 5 }); RP.start({ id = 6 })
local F = dofile("solar/tests/lib/reactor_fixture.lua")

local function struct(x, y, z, part)
  local l = math.sqrt(x * x + y * y + z * z)
  local U = { x = x / l, y = y / l, z = z / l }
  local Fv = { x = -U.y, y = U.x, z = 0 }
  return ST.add(ST.newRecord(nil, "Vever", x, y, z, U, Fv, part))
end
local function settime(dt_real)
  for _, sc in ipairs({ BG, RP, BS }) do local e = getfenv(sc.update); e.time = e.time + dt_real end
end
local function frame(dt_real, dt_game)
  clock.a = clock.a + (dt_game or dt_real)
  settime(dt_real)
  RP.update({}, dt_real)
  BG.update({}, dt_real)
end
local function run(seconds_game, ticks)
  for _ = 1, ticks do frame(0.6, seconds_game / ticks) end
end

-- ── an old base: a tower and a hab ──────────────────────────────────────────
local tA = struct(-R, 0, 0, "tower")
BT.update({}, 0.016)
local bA = ST.getPart(tA, 1).base
for k = 1, 8 do ST.addPart(tA, { id = "batteryBank", x = -20 - 3 * k, y = 0, z = 0 }) end   -- (a black start: the plant's pumps run on them until the turbine is up)
ST.addPart(tA, { id = "slab2.concrete", x = -12, y = 0, z = 0 })
run(10, 4)
check(next(RP.plants()) == nil, "an old base: no reactor plant, nothing stepped")
local p0 = BT.power(bA)
check(p0 and (p0.plant or 0) == 0, "…and its grid has no plant on it")

-- ── the fixture's plant, on the tower's structure (offset clear of the tower) ──
local rows = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
local rec0, U0, cells0 = F.plant(rows, {})
local map = {}
for _, p in ipairs(rec0.bp) do
  local u = ST.addPart(tA, { id = p.id, x = p.x + 14, y = p.y, z = p.z + 8, yaw = p.yaw, pitch = 0, roll = 0 })
  map[p.uid] = u
end
run(10, 4)
local key = RP.keyOf(tA, map[U0.vessel])
local e = RP.plant(key)
check(e ~= nil and e.M ~= nil, "the plant is found on the structure: " .. tostring(key))
check(e and #e.M.why > 0 and e.M.why[1]:find("fuel", 1, true), "…unfuelled, it says so: " .. tostring(e and e.M.why[1]))
-- the fuel from the stores
local loaded = 0
for _, c in ipairs(cells0) do
  if c.ch == "F" then loaded = loaded + RP.loadRods(tA, map[c.uid], "fuelRod", 4, "base") end
end
check(loaded == 32 and STORE.base.fuelRod == 8, string.format("32 rods from the stores into the channels (%d left)", STORE.base.fuelRod))
e = RP.plant(key)
check(#e.M.why == 0, "fuelled, nothing is missing: " .. table.concat(e.M.why, "; "))
local ok, why = RP.startUp(key, 0.8)
check(ok, "start-up: " .. tostring(why))
-- an hour of game time in 600 ticks, then a day in 400 (1,000× warp)
run(3600, 600)
run(86400, 400)
e = RP.plant(key)
local o = e.o
check(math.abs(o.P - 0.8) < 0.01 and not e.S.scram, string.format("…the plant holds 80 %% (P %.3f, Tp %.0f K)", o.P, o.Tp))
local pw = BT.power(bA)
check(pw.plant > 10 and math.abs(pw.plant - o.Pe / 1000) < 3, string.format("the turbine feeds the base grid: %.1f kW (the plant %.1f kW)", pw.plant, o.Pe / 1000))
check(pw.need >= 1.5 + 0.8 + 2, string.format("…and the pumps, heaters and fan are its loads: the grid draws %.1f kW", pw.need))
local rad, share = RP.radOf(tA, map[U0.vessel])
check(rad > 1 and share == 1, string.format("the core is a dose source: %.1f lethal shares an hour at 5 m", rad))
BS.update({}, 0.016)
check(#BS.sources() >= 1, "…base_shield has it among its sources")
-- the console's page and the vessel's menu
local pg = RP.page(e)
local txt = pg.title
for _, l in ipairs(pg.lines) do txt = txt .. " | " .. l[1] end
check(txt:find("XENON", 1, true) and txt:find("TURBINE", 1, true) and txt:find("LIMITED BY", 1, true), "the console page: " .. txt:sub(1, 160))
-- a primary pump switched off at power: low flow, a trip
local pumpUid = map[U0.pump]
RP.setPump(tA, pumpUid, false)
run(30, 60)
e = RP.plant(key)
check(e.S.scram and e.S.cause == "flow", "the primary pump switched off: SCRAM on low flow (" .. tostring(e.S.cause) .. ")")
local fl = false
for _, l in ipairs(RP.lastEvents) do if l.text:find("low coolant flow", 1, true) then fl = true end end
check(fl, "…the event is logged")
run(600, 20)
local rad2 = RP.radOf(tA, map[U0.vessel])
check(rad2 < 0.2 * rad, string.format("…the dose falls with the heat: %.2f (was %.1f)", rad2, rad))
-- the save, read back by a fresh reactor_plant
RP.saveNow()
local y0 = e.S.y[RXs.IDX.Xe]
local RP2 = load_script("reactor_plant.lua", env(s, scripts, X))
scripts.reactor_plant = RP2
RP2.start({ id = 7 })
RP2.update({}, 0.016)
getfenv(RP2.update).time = 10
RP2.update({}, 0.6)
local e2 = RP2.plant(key)
check(e2 and e2.S.scram and math.abs(e2.S.y[RXs.IDX.Xe] - y0) < 1e-3 * math.max(y0, 1e-9) + 0.05 and #RP2.channelRods(tA, map[cells0[1].uid]) >= 0,
  string.format("the save read back: tripped, xenon %.3f (was %.3f)", e2 and e2.S.y[RXs.IDX.Xe] or -1, y0))
local rods = 0
for _, c in ipairs(cells0) do if c.ch == "F" then rods = rods + #RP2.channelRods(tA, map[c.uid]) end end
check(rods == 32, string.format("…and its 32 rods (%d)", rods))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_reactor_scene: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_reactor_scene: %d passed", passed))
