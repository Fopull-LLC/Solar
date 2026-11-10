-- SMOKE: BASE ROLES and REACH (expansion X7; scripts/base_roles.lua, the
-- reach kinds and the Reach stage in missions.lua). Pure and against stubs.
--
--   * the rules: each role from what a census counted (an Electrolyser is a
--     FUEL base, a hose stand with 500 kg too, a Quarry Drive a MINE, 10 kW
--     spare a POWER base, …); a Build Stand alone is no PORT; strengths rise
--     at once and fade over three game days (one long step equals many
--     short); the shown roles strongest first; the role line and glyph;
--   * the stats: in, out, mined, worked and run cycles by agency day, and
--     the rolling 24 h line;
--   * THE SCENE HALF: the real bases.lua and base_roles.lua over stubbed
--     structures, parts and grid: a census reads each base's roles and keeps
--     them on its record (and an old record without them loads as an
--     outpost); a part beyond 150 m belongs to no base; the roles fade when
--     the electrolyser goes; logistics' step and a run's actions credit the
--     right base; stockOf and cyclesOf;
--   * THE CONTRACTS: establish, layer, supply and pipeline are offered only
--     where they can be done, signed with their baselines, and pay when met;
--     the Reach stage ticks from bases, runs and surveys;
--   * every role glyph is in the UI fonts (the map and the station draw them).
--
--   luajit solar/tests/smoke_base_roles.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function near(a, b, e) return a and b and math.abs(a - b) <= (e or 1e-9) end
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end

local BR0 = loadlib("base_roles.lua")

-- ── the rules ───────────────────────────────────────────────────────────────
do
  local t = BR0.targetsOf({ electro = 1 })
  check("an Electrolyser makes a FUEL base", t.fuel == 1)
  t = BR0.targetsOf({ hoses = 1, fuelTanks = 2, fuelKg = 800 })
  check("a hose stand with 800 kg in its tanks: FUEL", t.fuel == 1)
  t = BR0.targetsOf({ hoses = 1, fuelTanks = 1, fuelKg = 100 })
  check("…with 100 kg: FUEL, weaker but shown", t.fuel == 0.6 and BR0.shown(t, "fuel"))
  t = BR0.targetsOf({ hoses = 1 })
  check("…a hose stand with no tank: not FUEL", not BR0.shown(t, "fuel"))
  t = BR0.targetsOf({ stands = 1 })
  check("a Build Stand alone is no PORT", not BR0.shown(t, "port"), t.port)
  t = BR0.targetsOf({ stands = 1, runs = 1 })
  check("…with a run through it, a PORT", t.port == 1)
  t = BR0.targetsOf({ runs = 2 })
  check("a run's stop (no stand) is a PORT too", BR0.shown(t, "port"))
  t = BR0.targetsOf({ drives = 1 })
  check("a Quarry Drive: MINE (idle 0.6)", t.mine == 0.6 and BR0.shown(t, "mine"))
  t = BR0.targetsOf({ drives = 1, mined24 = 300 })
  check("…digging: 1", t.mine == 1)
  t = BR0.targetsOf({ supply = 30, need = 18 })
  check("12 kW spare: POWER", t.power == 1)
  t = BR0.targetsOf({ supply = 12, need = 6 })
  check("6 kW spare: not POWER", not BR0.shown(t, "power"), t.power)
  t = BR0.targetsOf({ machines = 2, worked24 = 0 })
  check("two idle machines: REFINERY 0.6", t.refinery == 0.6)
  t = BR0.targetsOf({ survey = 1 })
  check("an instrument and no Scientist: SCIENCE 0.6", t.science == 0.6)
  t = BR0.targetsOf({ survey = 1, scientist = true })
  check("…with a Scientist: 1", t.science == 1)
  t = BR0.targetsOf({ storeCap = 8000 })
  check("8 t of silo room: DEPOT", BR0.shown(t, "depot"))
  t = BR0.targetsOf({ storeCap = 4000, storeKg = 2500 })
  check("2.5 t held: DEPOT 1", t.depot == 1)
  local t2, why = BR0.targetsOf({ electro = 1, drives = 1, mined24 = 50 })
  check("each role says why", why.fuel:find("Electrolyser") and why.mine:find("50 kg"), why.mine)
  -- decay
  check("a role rises at once", BR0.decay(0.2, 1, 10) == 1)
  check("…and fades by a third a day", near(BR0.decay(1, 0, 86400), 1 - 1 / 3, 1e-9))
  local s = 1
  for _ = 1, 1440 do s = BR0.decay(s, 0.3, 60) end
  check("one long fade equals 1,440 short ones (1e-9)", near(s, BR0.decay(1, 0.3, 86400), 1e-9), s)
  check("…never under the target", BR0.decay(1, 0.6, 10 * 86400) == 0.6)
  local roles, changed = BR0.step({ fuel = 1, mine = 0.6 }, { mine = 1 }, 86400)
  check("step: FUEL fading, MINE up", near(roles.fuel, 0.667, 1e-3) and roles.mine == 1 and changed)
  roles = BR0.step(roles, {}, 3 * 86400)
  check("…three days on, both gone", roles.fuel == nil and roles.mine == nil)
  local r3 = { fuel = 0.7, mine = 1, power = 0.3, depot = 0.7 }
  local st = BR0.strongest(r3)
  check("strongest first, unshown left out, ties in order", st[1] == "mine" and st[2] == "fuel" and st[3] == "depot" and #st == 3,
    table.concat(st, ","))
  check("the role line", BR0.roleLine(r3, 2) == "⚒ MINE · ⛁ FUEL", BR0.roleLine(r3, 2))
  check("an outpost's line", BR0.roleLine({}, 2) == "⌂ OUTPOST" and BR0.glyphOf({}) == "⌂")
end

-- ── the stats ───────────────────────────────────────────────────────────────
do
  local st = {}
  local D = 86400
  BR0.statsAdd(st, "i", 100, 10 * D + 3600)
  BR0.statsAdd(st, "o", 40, 10 * D + 7200)
  BR0.statsAdd(st, "r", 1, 10 * D + 7200)
  check("today's in and out", st.di == 100 and st["do"] == 40 and st.i == 100 and st.r == 1)
  check("the 24 h line on the day", near(BR0.stats24(st, "i", 10 * D + 43200), 100))
  BR0.statsAdd(st, "i", 50, 11 * D + 21600)
  check("a new day: yesterday kept", st.pi == 100 and st.di == 50 and st.i == 150)
  check("…and the 24 h line takes the part of yesterday still in the window",
    near(BR0.stats24(st, "i", 11 * D + 21600), 50 + 100 * 0.75), BR0.stats24(st, "i", 11 * D + 21600))
  check("two days of nothing: 0 in 24 h", BR0.stats24(st, "i", 13 * D + 10) == 0)
  BR0.statsAdd(st, "i", 5, 14 * D)
  check("…and a gap of days forgets yesterday", st.pi == 0 and st.di == 5)
end

-- ── the scene half ──────────────────────────────────────────────────────────
local store = {}
local SAVE = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end }
local agency = 1000 * 86400
local T = 0
local R = 800
local BODIES = { Home = { name = "Home", x = 0, y = 0, z = 0, radius = 800, mu = 1e6 },
                 Moon = { name = "Moon", x = 60000, y = 0, z = 0, radius = 200, mu = 1e5 } }
store["system.home"] = { star = "Sun", bodies = { { name = "Home" }, { name = "Moon", parent = "Home" } } }
store["base.body"] = "Home"
-- an OLD save's base: no roles, no stats
store["bases.list"] = { 1 }
store["bases.seq"] = 1
store["bases.1"] = { id = 1, b = "Moon", x = 0, y = 200, z = 0, n = "Far Side", t = 0, sid = 10, uid = 1 }
local DEFS = {
  ["mcElectro.steel"] = { label = "Electrolyser", it = { kind = "electro" } },
  ["flHose.steel"] = { label = "Fuel Hose Stand", fl = { kind = "consumer", sub = "fuel", hose = 30 } },
  ["flTankFuel.steel"] = { label = "Fuel Tank", fl = { kind = "tank", sub = "fuel" } },
  ["lgDrive.steel"] = { label = "Quarry Drive", it = { kind = "drive" } },
  ["lgHopper.steel"] = { label = "Hopper", it = { kind = "hopper", kg = 4000 } },
  ["mcCrusher.steel"] = { label = "Crusher", it = { kind = "machine", m = "crusher" } },
  tower = { label = "Base Station Tower", tower = {} },
  ["telescope.steel"] = { label = "Telescope", survey = { kind = "telescope" } },
}
-- the structure at Far Side: parts at body-relative points (partPose adds p.x/p.z to the record's point)
local recs = {
  { id = 10, b = "Moon", x = 0, y = 200, z = 0, bp = {
      { uid = 1, id = "tower", x = 0, z = 0 },
      { uid = 2, id = "mcElectro.steel", x = 10, z = 0 },
      { uid = 3, id = "flTankFuel.steel", x = 14, z = 0 },
      { uid = 4, id = "lgDrive.steel", x = 0, z = 20 },
      { uid = 5, id = "lgHopper.steel", x = 4, z = 20 } } },
  -- a structure 400 m round the moon: no base's
  { id = 11, b = "Moon", x = 0, y = 0, z = 200, bp = { { uid = 1, id = "mcCrusher.steel", x = 0, z = 0 } } },
}
local ST = { valid = true, version = 1 }
function ST.list() return recs end
function ST.partPose(r, p) return r.x + (p.x or 0), r.y, r.z + (p.z or 0) end
function ST.get(id) for _, r in ipairs(recs) do if r.id == id then return r end end end
local PB = { valid = true, partInfo = function(id) return DEFS[id] end }
local FN = { valid = true, content = function(sid, uid) return (sid == 10 and uid == 3) and 900 or nil end }
local BT = { valid = true, power = function(id) return { supply = 25, need = 4 } end }
local INV = { valid = true, bags = {} }
function INV.count(cid, mat) local b = INV.bags[cid]; return b and b[mat] or 0 end
function INV.mass(cid) local n = 0; for _, v in pairs(INV.bags[cid] or {}) do n = n + v end return n end
local LX = { valid = true, worlds = {} }
function LX.storeCid(it, sid, uid) return "hopper:" .. sid .. "." .. uid end
LX.worlds.Moon = { body = "Moon", pieces = { { key = "10.5", cid = "hopper:10.5", gx = 4, gy = 200, gz = 20 } } }
local RUNS = {}
local RO = { valid = true, version = 1, list = function() return RUNS end }
local MATS = { valid = true, kg = function(m) return 10 end }
local SCR = { structures = ST, parts_base = PB, fluid_net = FN, base_tower = BT, inventory = INV, logistics = LX,
              route_ops = RO, materials = MATS,
              deployables = { valid = true, agencyClock = function() return agency end },
              comms = { valid = true, station = function() return 0, 801, 0 end },
              base_facilities = { valid = true, baseBody = "Home" },
              crew = { valid = true, roster = function() return {} end } }
local API = {
  save = SAVE, log = function() end,
  findScript = function(k) return SCR[k] end,
  space = { body = function(n) return BODIES[n] end, bodies = function() return { BODIES.Home, BODIES.Moon } end },
}
local function with_api() local e = {} for k, v in pairs(API) do e[k] = v end return e end
local Bases = loadlib("bases.lua", with_api())
Bases.valid = true
SCR.bases = Bases
local BR = loadlib("base_roles.lua", with_api())
BR.valid = true
SCR.base_roles = BR
BR.start({ id = 1 })
check("an old save's base loads, with no roles: an outpost", Bases.get(1) and Bases.get(1).roles == nil and BR.roleLine(BR.rolesOf(1)) == "⌂ OUTPOST")
local n = BR.censusNow()
local far = Bases.get(1)
check("the census reads two places (the spaceport and Far Side)", n == 2, n)
check("Far Side: FUEL (an Electrolyser, 900 kg in a tank), MINE (a drive), POWER (21 kW spare)",
  far.roles and far.roles.fuel == 1 and far.roles.mine == 0.6 and far.roles.power == 1, far.roles and BR.roleLine(far.roles, 4))
check("…kept on its record in the save", type(store["bases.1"].roles) == "table" and store["bases.1"].roles.fuel == 1)
check("…the crusher 400 m away is no base's", not BR.shown(far.roles, "refinery"))
check("…the census counted 5 pieces in one structure", BR.census[1].parts == 5 and BR.census[1].structures == 1, BR.census[1].parts)
check("its why", BR.why[1].fuel:find("Electrolyser") ~= nil)
-- a run through it: PORT; its actions credit the base
local run = { stand = { body = "Home", x = 0, y = 800, z = 0 }, stops = { { body = "Moon", x = 2, y = 200, z = 2 } },
              phases = { { k = "dwell" }, { k = "leg" }, { k = "stop", at = 1 }, { k = "leg" } }, acts = {}, cycles = 0 }
local unload = { op = "unload", mat = "iron", n = 20, dst = "hopper:10.5" }
local load = { op = "load", mat = "ice", n = 5, src = "hopper:10.5" }
run.acts[3] = { unload, load }
local home_unload = { op = "unload", mat = "ice", n = 5, dst = "intake" }
run.acts[4] = { home_unload }
RUNS[1] = run
BR.creditRun(run, { unload, load, home_unload }, 1)
local st = BR.statsOf(1)
check("a run's unload is IN at Far Side, its load OUT, its cycle a RUN (kept until written)",
  (BR.cyclesOf(1) == 1) and true, BR.cyclesOf(1))
BR.flush()
st = BR.statsOf(1)
check("…written: in 200 kg, out 50 kg, 1 cycle", st.i == 200 and st.o == 50 and st.r == 1, string.format("%s %s %s", tostring(st.i), tostring(st.o), tostring(st.r)))
check("…the Intake's unload is the spaceport's IN", (BR.statsOf(0).i or 0) == 50, BR.statsOf(0).i)
-- logistics' step: the quarry's made and a machine's worked
local w = { body = "Moon", net = { nodes = { { key = "10.4" }, { key = "10.9", kind = "chute" } } },
            byKey = { ["10.4"] = { key = "10.4", gx = 0, gy = 200, gz = 20 }, ["10.9"] = { key = "10.9", gx = 1, gy = 200, gz = 1 } } }
BR.creditStep(w, { made = { [1] = { regolith = 30 } }, conv = {}, moved = { ["1|2|regolith"] = 12 } })
BR.flush()
st = BR.statsOf(1)
check("logistics: the quarry's 30 kg MINED, 12 kg down the chute OUT", st.m == 30 and st.o == 62, string.format("%s %s", tostring(st.m), tostring(st.o)))
RO.version = 2
T = T + 5
BR.censusNow()
check("with the run through it: PORT (a stop, no stand)", BR.shown(Bases.get(1).roles, "port"))
check("…and MINE at full strength: it dug today", Bases.get(1).roles.mine == 1)
-- stock and cycles
INV.bags["hopper:10.5"] = { iron = 12 }
check("stockOf: 12 units of iron × 10 kg in Far Side's hopper", BR.stockOf(1, "iron") == 120, BR.stockOf(1, "iron"))
local bw = BR.basesWith("fuel", nil, true)
check("basesWith: Far Side is the FUEL base off the home world", #bw == 1 and bw[1].id == 1)
check("…the spaceport is not off the home world", #BR.basesWith(nil, "Home", true) == 0)
-- the electrolyser goes: FUEL fades over days, not at once (the tank still holds fuel, but no hose)
table.remove(recs[1].bp, 2)
FN.content = function() return 0 end
agency = agency + 86400
BR.censusNow()
local fz = Bases.get(1).roles.fuel
check(string.format("the Electrolyser gone a day: FUEL fading (%.2f), still shown", fz or 0), fz and fz < 1 and BR.shown(Bases.get(1).roles, "fuel"))
agency = agency + 3 * 86400
BR.censusNow()
check("…three days more: gone", not BR.shown(Bases.get(1).roles, "fuel"))
-- a reload keeps the roles
Bases.reloadFromSave()
check("a reload keeps the roles and stats", Bases.get(1).roles and Bases.get(1).roles.mine and Bases.get(1).stats and Bases.get(1).stats.m == 30)

-- ── the contracts and the Reach stage (missions.lua with stubs) ─────────────
do
  local mstore = {}
  local MT = 0
  local ROSTER = { star = "Saelo", mu = 7e7, bodies = {
    { name = "Umunquo", kind = "canyon", parent = "Saelo", a = 5500, radius = 185, relief = 12, mu = 7.0 * 185 * 185, atmo = 0.7, sea = 180 },
    { name = "Ryethos", kind = "frost", parent = "Umunquo", a = 1110, radius = 40, relief = 3, mu = 3.5 * 40 * 40, atmo = 0, sea = 0 } } }
  mstore["system.home"] = ROSTER
  mstore["base.body"] = "Umunquo"
  for _, b in ipairs(ROSTER.bodies) do
    mstore["world." .. b.name] = { name = b.name, kind = b.kind, radius = b.radius, relief = b.relief, atmo = b.atmo, sea = b.sea }
  end
  local MB = { Umunquo = { name = "Umunquo", x = 5500, y = 0, z = 0, radius = 185, mu = 7.0 * 185 * 185, soi = 2200 },
               Ryethos = { name = "Ryethos", x = 6610, y = 0, z = 0, radius = 40, mu = 3.5 * 40 * 40, soi = 240 },
               Saelo = { name = "Saelo", x = 0, y = 0, z = 0, radius = 700, mu = 7e7, soi = -1 } }
  -- the reach scripts, stubbed
  local bases_on = {}
  local stock, cycles = 0, 0
  local BRS = { valid = true, LABEL = BR0.LABEL, HOW = BR0.HOW, worked = 0 }
  function BRS.basesWith(r, body, off)
    local out = {}
    for _, p in ipairs(bases_on) do
      if (not body or p.b == body) and not (off and p.b == "Umunquo") and (not r or (p.roles[r] or 0) >= 0.5) then out[#out + 1] = p end
    end
    return out
  end
  function BRS.rolesOf(id) for _, p in ipairs(bases_on) do if p.id == id then return p.roles end end return {} end
  function BRS.stockOf() return stock end
  function BRS.cyclesOf() return cycles end
  function BRS.workedOffHome() return BRS.worked end
  local SVR = { Ryethos = { L = { grav = 1, atmo = 0.4, temp = 0.5, comp = 0.3, mag = 0, res = 0.2 } },
                Umunquo = { L = { grav = 1, atmo = 1, temp = 1, comp = 1, mag = 1, res = 1 } } }
  local SVS = { valid = true, LABEL = { res = "RESOURCES", mag = "MAGNETOSPHERE", comp = "COMPOSITION" },
                record = function(n) return SVR[n] end,
                bodies = function() return { { name = "Umunquo" }, { name = "Ryethos" } } end,
                isSurveyed = function(n) for _, v in pairs(SVR[n].L) do if v < 1 then return false end end return true end }
  local RUNS2 = {}
  local ROS = { valid = true, list = function() return RUNS2 end }
  local envs = { base_roles = BRS, survey = SVS, route_ops = ROS }
  local MAPI = {
    save = { get = function(k) return mstore[k] end, set = function(k, v) mstore[k] = v end },
    log = function() end,
    space = { bodies = function() local o = {} for _, b in pairs(MB) do o[#o + 1] = b end return o end, body = function(n) return MB[n] end,
              dominant = function() return "Umunquo" end, elements = function() return nil end },
    assembly = { info = function() return { grounded = true, vel = { x = 0, y = 0, z = 0 } } end },
    find = function() return nil end,
  }
  local function load_script(path, kind)
    local env = setmetatable({}, { __index = function(_, k) if k == "time" then return MT end return MAPI[k] or _G[k] end })
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    chunk()
    env.params = {}
    for k, v in pairs(env.defaults or {}) do env.params[k] = v end
    env.valid = true
    envs[kind] = env
    return env
  end
  MAPI.findScript = function(k) return envs[k] end
  MAPI.findScripts = function(k) return envs[k] and { envs[k] } or {} end
  local co = load_script("solar/scripts/company.lua", "company")
  load_script("solar/scripts/materials.lua", "materials")
  load_script("solar/scripts/inventory.lua", "inventory")
  local mi = load_script("solar/scripts/missions.lua", "missions")
  co.start({})
  mi.start({})
  local MN = { x = 5500, y = 186, z = 0 }
  local function second() for _ = 1, 70 do MT = MT + 1 / 60; co.update({}, 1 / 60); mi.update(MN, 1 / 60) end end
  -- the Interplanetary standing, the ladder flown, Ryethos reached
  co.addRep(10, "test")
  mstore["mission.done"] = { firstflight = true, highroad = true, orbit = true }
  mstore["mission.visited"] = { Ryethos = true }
  second()
  local function spec(kind) return mi.genSpec(kind, "Ryethos", 3) end
  check("no base on Ryethos: no supply or pipeline to offer", spec("supply") == nil and spec("pipeline") == nil)
  local es = spec("establish")
  check("establish: a role for Ryethos with what makes it", es and es.goals[1].kind == "establish" and BR0.LABEL[es.goals[1].role] ~= nil
    and es.brief:find("Base Station Tower") ~= nil and es.reward > 0, es and es.title)
  local ls = spec("layer")
  check("layer: the least-known of res / mag / comp (the field, by the gravimeter)", ls and ls.goals[1].layer == "mag"
    and ls.brief:find("gravimeter") ~= nil, ls and ls.title)
  -- the board offers reach work once the tier opens
  local kinds = {}
  for _, m in ipairs(mi.offers()) do if m.gen then kinds[m.kind] = true end end
  local seen = false
  for _ = 1, 30 do
    for _, m in ipairs(mi.offers()) do if m.gen and (m.kind == "establish" or m.kind == "layer") then seen = true end end
    if seen then break end
    mstore["mission.board"] = {}
    mstore["mission.genSeq"] = (mstore["mission.genSeq"] or 0) + 3
    second()
  end
  check("the Reach tier puts an establish or a layer contract on the board", seen)
  -- a base on Ryethos: supply and pipeline open; establish no longer
  bases_on[1] = { id = 4, b = "Ryethos", x = 0, y = 40, z = 0, roles = {} }
  check("a base on Ryethos: establish there no longer offered", mi.reachOkFor("establish", "Ryethos") == false)
  local ss, ps = spec("supply"), spec("pipeline")
  check("supply: kg of an ore the home world has and Ryethos lacks, into the base's stores",
    ss and ss.goals[1].base == 4 and ss.goals[1].kg == 200 and ss.goals[1].mat ~= nil, ss and ss.title)
  check("pipeline: 3 cycles through the base", ps and ps.goals[1].n == 3 and ps.goals[1].base == 4, ps and ps.title)
  -- sign the supply contract: it counts from now
  stock = 500
  mstore["mission.board"] = { ss }
  check("signed", mi.accept(ss.id))
  check("…its baseline stamped (500 kg there already)", mi.byId(ss.id).goals[1].b0 == 500)
  local m0 = co.balance()
  second()
  check("…500 kg already there pays nothing", mi.active == ss.id)
  stock = 650
  second()
  check("…150 kg more: not yet", mi.active == ss.id)
  stock = 710
  second()
  check("…210 kg more: paid", mi.active == nil and co.balance() > m0, co.balance() - m0)
  -- pipeline
  mstore["mission.board"] = { ps }
  cycles = 2
  mi.accept(ps.id)
  check("pipeline signed with 2 cycles behind it", mi.byId(ps.id).goals[1].c0 == 2)
  cycles = 4
  second()
  check("…two more: not yet", mi.active == ps.id)
  cycles = 5
  second()
  check("…three more: paid", mi.active == nil)
  -- establish: the role shows
  mstore["mission.board"] = { es }
  mi.accept(es.id)
  second()
  check("establish: a base there without the role does not pay", mi.active == es.id)
  bases_on[1].roles[es.goals[1].role] = 0.6
  second()
  check("…the role shown: paid", mi.active == nil)
  -- layer
  mstore["mission.board"] = { ls }
  mi.accept(ls.id)
  second()
  check("layer: unknown field, not paid", mi.active == ls.id)
  SVR.Ryethos.L.mag = 1
  second()
  check("…the gravimeter's field known: paid", mi.active == nil)
  -- THE REACH STAGE
  mstore["prog.done"] = { first_steps = true, relay_net = true }
  bases_on = {}
  mi.progTick()
  local function ticked(i) return (mi.progGoalLines("reach")[i] or ""):sub(1, 3) == "✓" end
  check("Reach: nothing off the home world, nothing ticked", not ticked(1) and not ticked(2) and not ticked(3))
  bases_on[1] = { id = 4, b = "Ryethos", x = 0, y = 40, z = 0, roles = {} }
  mi.progTick()
  check("…a base on Ryethos: the first goal", ticked(1) and not ticked(2))
  bases_on[1].roles.fuel = 1
  mi.progTick()
  check("…it becomes a FUEL base: the second", ticked(2))
  RUNS2[1] = { cycles = 1 }
  BRS.worked = 12
  mi.progTick()
  check("…a run's first cycle and ore refined there: the third and fourth", ticked(3) and ticked(4))
  SVR.Ryethos.L = { grav = 1, atmo = 1, temp = 1, comp = 1, mag = 1, res = 1 }
  local before = co.balance()
  mi.progTick()
  check("…Ryethos SURVEYED: the stage is done and pays", ticked(5) and (mstore["prog.done"] or {}).reach == true and co.balance() > before)
end

-- ── the glyphs are in the fonts ─────────────────────────────────────────────
do
  local src = io.open("solar/tests/smoke_ui_font.lua"):read("*a")
  local cut = src:find("local env = setmetatable", 1, true)
  local lib = assert(loadstring(src:sub(1, cut - 1) .. " return cmap_of, codepoints"))
  local cmap_of, codepoints = lib()
  local label, ui = cmap_of("solar/fonts/SolarLabel.ttf"), cmap_of("solar/fonts/SolarUI.ttf")
  for r, g in pairs(BR0.GLYPH) do
    for _, c in ipairs(codepoints(g)) do
      check(string.format("the %s glyph %s is in both UI fonts", r, g), label[c.cp] and ui[c.cp])
    end
  end
end

if failed > 0 then
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
print(string.format("✓ base roles: %d checks — the rules, decay, stats, the census, credits, the contracts, the Reach stage, the glyphs", count))
