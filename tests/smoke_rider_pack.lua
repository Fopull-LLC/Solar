-- SMOKE: what the crew carries weighs on them, and a bike reads the ground it
-- is on (2026-11-04: "whatever's in your backpack should affect the weight";
-- "tune the climbing and acceleration"). Against stubs.
--
--   * a seated member weighs CREW_T (the suit and its wearer) plus their
--     pack's contents (inventory.mass of their pack) on the seat they sit
--     in (vessel_controller crewSeatT / crewMassScan), re-read as the pack
--     changes, to the kilogram;
--   * on foot the capsule weighs the suited crew (planet_walker `mass`, 100
--     kg) plus the pack (bodyMass);
--   * the Gas Can weighs its petrol: 3 kg empty, 10.4 kg full; the pack's
--     room is checked against a full can (inventory itemMass, roomForItem,
--     itemList);
--   * ores weigh a litre of a rich ore (materials REG), their price per kg
--     kept;
--   * the ground's grade under a bike comes from its tyres, not its frame:
--     a bike built nose up on level ground reads level (r2TyreSlope).
--
--   luajit solar/tests/smoke_rider_pack.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs((a or 1e9) - (b or -1e9)) <= (tol or 1e-9) end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function path(p) return io.open("solar/" .. p) and ("solar/" .. p) or p end

-- ── the inventory, items and materials (real scripts, stub save) ───────────
local T = 0
local store = {}
local envs = {}
local API = {
  findScript = function(kind) return envs[kind] end,
  findScripts = function() return {} end,
  log = function() end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
}
local function load_script(p, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path(p)))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end
local I = load_script("scripts/items.lua", "items")
local M = load_script("scripts/materials.lua", "materials")
local inv = load_script("scripts/inventory.lua", "inventory")

-- ── the Gas Can weighs what it holds ───────────────────────────────────────
local can = I.ITEMS.gascan
check(can and near(can.kg, 3.0) and can.fill and near(can.fill.kg, 0.74), "the Gas Can: 3 kg of empty can and 0.74 kg a litre of petrol")
inv.addItem("crew:7", "gascan", 1)
check(near(inv.itemMass("crew:7"), 3.0 + 10 * 0.74, 1e-6), string.format("a full can weighs 10.4 kg (%.2f)", inv.itemMass("crew:7")))
inv.drawFill("crew:7", "gascan", 6)
check(near(inv.itemMass("crew:7"), 3.0 + 4 * 0.74, 1e-6), string.format("4 L left: 5.96 kg (%.2f)", inv.itemMass("crew:7")))
check(near(inv.mass("crew:7"), inv.itemMass("crew:7"), 1e-9), "the pack's mass carries it")
local list = inv.itemList("crew:7")
check(list[1] and near(list[1].kg, 3.0 + 4 * 0.74, 1e-6), "itemList shows the can's weight with its petrol")
-- room is checked against a full can: 90 kg pack, 60 L; fill it to 85 kg
inv.add("crew:8", "iron", math.floor(85 / M.kg("iron")))
local free = inv.free("crew:8")
local n = inv.roomForItem("crew:8", "gascan", 1)
check((free >= 10.4 and n == 1) or (free < 10.4 and n == 0),
  string.format("a can goes in only if a full one fits (%.1f kg free: %d)", free, n))

-- ── ores weigh a litre of rich ore, priced by the kg as before ─────────────
local dens = { iron = { 3.5, 5.3 }, copper = { 2.8, 4.2 }, uranium = { 6.0, 9.5 }, kamacite = { 7.0, 7.9 },
               sperrylite = { 6.5, 10.6 }, monazite = { 3.5, 5.3 }, ilmenite = { 3.4, 4.7 }, sulfur = { 1.9, 2.1 },
               silica = { 2.5, 2.7 }, obsidian = { 2.3, 2.6 }, ice = { 0.9, 0.95 }, granite = { 2.6, 2.8 },
               basalt = { 2.8, 3.0 }, water = { 0.99, 1.01 } }
for id, r in pairs(dens) do
  local kg = M.kg(id)
  check(kg >= r[1] and kg <= r[2], string.format("%s: %.2f kg a unit (a litre: %.1f-%.1f)", id, kg, r[1], r[2]))
end
local perkg = { iron = 3.1, copper = 5.0, sulfur = 10.0, uranium = 34.4, crystal = 54.5, kamacite = 8.7, sperrylite = 43.3 }
for id, want in pairs(perkg) do
  local got = M.value(id) / M.kg(id)
  check(math.abs(got - want) / want < 0.04, string.format("%s: $%.1f a kg (was $%.1f)", id, got, want))
end

-- ── the crew's mass on the seat: CREW_T and the pack ───────────────────────
local astro = { name = "Astronaut", valid = true, visible = true, x = 0, y = 0, z = 0, id = 99 }
local BP = { parts = {
  { uid = 1, id = "pod", kind = "crewed", x = 0, y = 1.0, z = 0, mass = 1.2 },
  { uid = 3, id = "seat", kind = "crewed", seat = 1, x = 0, y = 1.0, z = 1.2, parent = 1, mass = 0.025 },
} }
local vstore = { ["shipyard.blueprint"] = BP }
local info = { origin = vec3(10, 20, 30), right = vec3(1, 0, 0), up = vec3(0, 1, 0), vel = vec3(0, 0, 0),
               angVel = vec3(0, 0, 0), com = vec3(10, 21, 30), parts = {}, mass = 1.225 }
local crewStub = { valid = true, activeId = function() return 7 end, packOf = function(id) return "crew:" .. tostring(id) end }
envs.crew = crewStub   -- (the roster: "astro" is crew 7's pack)
local started = false   -- (the inventory is offered once the craft is up: its hold is no part of this)
local VE
VE = setmetatable({
  vec3 = vec3, time = 10.0,
  find = function(nm) if nm == "Astronaut" then return astro end end,
  findScripts = function() return {} end,
  findScript = function(kind)
    if not started then return nil end
    if kind == "inventory" then return inv elseif kind == "crew" then return crewStub end
  end,
  save = { get = function(k) return vstore[k] end, set = function(k, v) vstore[k] = v end },
  overlapSphere = function() return {} end,
  assembly = { info = function() return info end, rebuild = function() end, syncColliders = function() end },
  log = function() end,
}, { __index = function(_, k)
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local vc = assert(loadfile(path("scripts/vessel_controller.lua")))
setfenv(vc, VE)
vc()
VE.params = {}
for k, v in pairs(VE.defaults) do VE.params[k] = v end
local node = { id = 5, valid = true, x = 10, y = 20, z = 30, yaw = 0, pitch = 0, roll = 0, name = "Vessel",
               children = function() return {} end }
VE.start(node)
started = true
VE.setStation(3)
VE.crewAboard = true
local packKg = inv.mass("crew:7")
VE.time = VE.time + 1
check(VE.crewMassScan(node, info) == true, "boarding is read at once")
local want = VE.CREW_T + math.floor(packKg + 0.5) / 1000
check(near(VE.CREW_TU[3], want, 1e-9), string.format("the rider and their pack on the seat: %.3f t (want %.3f)", VE.CREW_TU[3] or -1, want))
check(near(VE.crewSeatT(nil), VE.CREW_T), "no member known: the suit and wearer alone")
-- the pack is loaded at the base: the next scan carries it
inv.add("crew:7", "iron", 10)
VE.time = VE.time + VE.CREW_SCAN_S + 0.01
check(VE.crewMassScan(node, info) == true, "a heavier pack is read at the next scan")
local want2 = VE.CREW_T + math.floor(inv.mass("crew:7") + 0.5) / 1000
check(near(VE.CREW_TT, want2, 1e-9) and VE.CREW_TT > want, string.format("…%.0f kg aboard now", VE.CREW_TT * 1000))
VE.time = VE.time + VE.CREW_SCAN_S + 0.01
check(VE.crewMassScan(node, info) == false, "nothing changed: nothing written")

-- ── the ground's grade from the tyres ──────────────────────────────────────
-- level ground (up = +Y), a bike 1.8 m long, the rear tyre's centre 0.21 m
-- higher in the frame (built nose up) but both tyres on the ground: the
-- tyres' centres are level, so the grade is 0 whatever the frame's pitch
local gdir = vec3(0, -9.8, 0)
local function wheel(a, x, y, r)
  return { a = a, r = r or 0.33, down = true, tyre = { valid = true, tickPos = vec3(x, y, 0) } }
end
VE.R2.wheels = { wheel(1.0, 1.0, 0.33), wheel(-0.8, -0.8, 0.33) }
check(near(VE.r2TyreSlope(gdir, 9.8), 0, 1e-9), "level ground reads level from the tyres")
-- a 30 degree climb: the front tyre higher by 1.8 tan 30
local s30 = math.sin(math.rad(30))
VE.R2.wheels = { wheel(1.0, 1.0 * math.cos(math.rad(30)), 0.33 + 1.8 * s30), wheel(-0.8, -0.8 * math.cos(math.rad(30)), 0.33) }
local h = 1.8 * s30
local hl = 1.8 * math.cos(math.rad(30))
check(near(VE.r2TyreSlope(gdir, 9.8), h / math.sqrt(h * h + hl * hl), 1e-9), "a climb reads its grade")
-- a bigger front tyre on level ground: its centre higher by the radii's difference, still level
VE.R2.wheels = { wheel(1.0, 1.0, 0.40, 0.40), wheel(-0.8, -0.8, 0.33, 0.33) }
check(near(VE.r2TyreSlope(gdir, 9.8), 0, 1e-9), "tyres of two sizes: the radii are taken off")
VE.R2.wheels[1].down = false
check(VE.r2TyreSlope(gdir, 9.8) == nil, "one tyre down: no reading (the rear's contact normal serves)")

-- ── on foot: the suited crew and the pack ──────────────────────────────────
local WE = setmetatable({
  vec3 = vec3, time = 50.0,
  findScript = function(kind) if kind == "inventory" then return inv end end,
  findScripts = function() return {} end,
  log = function() end,
  save = API.save,
}, { __index = function(_, k)
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local wk = assert(loadfile(path("scripts/planet_walker.lua")))
setfenv(wk, WE)
local okw = pcall(wk)
check(okw and type(WE.bodyMass) == "function", "planet_walker loads and has bodyMass")
if okw and WE.bodyMass then
  WE.params = {}
  for k, v in pairs(WE.defaults or {}) do WE.params[k] = v end
  check(near(WE.params.mass, 0.10), "the suited crew, before the pack: 100 kg")
  local m = WE.bodyMass()
  local wantw = 0.10 + math.floor(inv.mass("crew:7") + 0.5) / 1000
  check(near(m, wantw, 1e-9), string.format("on foot: %.0f kg with the pack (want %.0f)", m * 1000, wantw * 1000))
  inv.remove("crew:7", "iron", 10)
  check(near(WE.bodyMass(), m, 1e-9), "read at most every PACK_MASS_S")
  WE.time = WE.time + 1
  check(WE.bodyMass() < m, "…and lighter once the ore is out of the pack")
end

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("SMOKE OK — %d checks", passed))
