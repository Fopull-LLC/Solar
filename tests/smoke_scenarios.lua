-- SMOKE: SCENARIOS (scripts/scenario.lua, scripts/scenario_run.lua,
-- scenarios/*.lua; work/scenarios/PLAN.md §1.11 step 4, docs/scenarios.md).
-- Pure and against stubs.
--
--   * every scenario file in scenarios/ loads and validates: kinds, fields,
--     refs, piece ids (parts_base + parts_kit), research ids, craft files in
--     the launch format, blueprint codes that check, medal/par consistency;
--     the menu's list leaves out the "_" files;
--   * a broken scenario is refused with errors that name the field;
--   * the step machine: order, optional steps, parallel groups, done;
--   * every slice-1 goal kind against a stub world: met and its reading,
--     `hold`, the event kinds (airlock_cycled), the fail kinds, the missions
--     pass-through;
--   * score, medals, the profile; the slot keys (worldKeys) and PLAY
--     (prepareSlot) touching slot `scn` only — no code path names slot<n>;
--   * geometry: the ground frame, offsets set down on the ground, siting
--     rules over a ground query, a circular orbit from elements;
--   * F12's serialiser round-trips;
--   * THE SCENE HALF over stubs with the real structures.lua, blueprints.lua
--     and company.lua: a scenario staged through the APIs (crew renamed and
--     placed, marks, a structure from a SOLBP1 code, a crate, a flag), the
--     body MOVING every frame (nothing kept in world space), steps latched,
--     beats fired, a camera pivot that rides the body, the finish with a
--     medal in the profile, a fail, and the cost of an idle runner.
--
--   luajit solar/tests/smoke_scenarios.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function loadlib(path, extra)
  local e = extra or {}
  if not getmetatable(e) then setmetatable(e, { __index = _G }) end
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end

local SCN = loadlib("scenario.lua")
local KIT = loadlib("parts_kit.lua")
local PB = loadlib("parts_base.lua", { findScript = function(k) return k == "parts_kit" and KIT or nil end })
local BPS = loadlib("blueprints.lua")
local RS = loadlib("research.lua", { save = { get = function() return nil end, set = function() end }, findScript = function() return nil end })

local ITM = loadlib("items.lua")
local MAT = loadlib("materials.lua")
local CTX = {
  partExists = function(id) return PB.partInfo(id) ~= nil end,
  -- (S6) the items, materials and pieces a start's containers and locks name
  itemExists = function(id) return ITM.known(id) end,
  matExists = function(m) return MAT.REG == nil or MAT.REG[m] ~= nil end,
  pieceKind = function(prefix)
    local d = PB.partInfo(prefix) or PB.partInfo(prefix .. ".steel") or PB.partInfo(prefix .. ".concrete")
    if not d then return nil end
    return { container = d.container ~= nil, lockable = d.container ~= nil or d.door ~= nil }
  end,
  techExists = function(id) return RS.TECH[id] ~= nil end,
  readFile = function(p) return slurp("solar/" .. p) end,
  decodeBp = function(code) return BPS.decode(code) end,
  readJson = function(p)
    local t = slurp("solar/" .. p)
    if not t then return nil, "no file" end
    if t:find('"fmt"%s*:%s*1') and t:find('"parts"') then return { bp = { parts = {} } } end
    return {}, "not the launch format"
  end,
}

-- ── every scenario file ─────────────────────────────────────────────────────
do
  local list = SCN.ids()
  local all = {}
  local h = io.popen('ls solar/scenarios/*.lua solar/scenarios/*/scenario.lua 2>/dev/null')
  for line in h:lines() do all[#all + 1] = line:match("([%w_%-]+)/scenario%.lua$") or line:match("([%w_%-]+)%.lua$") end
  h:close()
  check("the scenarios folder has files", #all >= 2, #all)
  for _, id in ipairs(all) do
    local sc, err = SCN.load(id)
    check("loads: " .. id, sc ~= nil, err)
    if sc then
      local ok, errs = SCN.validate(sc, CTX)
      check("validates: " .. id, ok or id == "_template", table.concat(errs or {}, " | "))
      if id ~= "_template" then check("its id is its file name: " .. id, sc.id == id, sc.id) end
    end
  end
  local listed = {}
  for _, id in ipairs(list) do listed[id] = true end
  check("the menu never lists a _ file", not listed._template and not listed._probe)
  local L = SCN.listAll()
  local okL = true
  for _, e in ipairs(L) do if e.id:sub(1, 1) == "_" or (not e.err and not e.title) then okL = false end end
  check("listAll: titles, no templates", okL)
  local probe = SCN.load("_probe")
  check("a _ scenario still loads by id (the probe)", probe and probe.title == "Framework Probe")
end

-- ── the data reader (the engine's Luau has no loadstring) ───────────────────
do
  local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local h = io.popen('ls solar/scenarios/*.lua solar/scenarios/*/scenario.lua 2>/dev/null')
  local n = 0
  for path in h:lines() do
    local t = slurp(path)
    local viaParse, err = SCN.parseData(t, path)
    local f = loadstring(t)
    setfenv(f, {})
    local viaLua = f()
    n = n + 1
    check("the data reader reads " .. path .. " exactly as Lua would", viaParse and same(viaParse, viaLua), err)
  end
  h:close()
  check("the data reader saw every scenario file", n >= 3, n)
  local v = SCN.parseData("-- c\n--[[ long\n comment ]] return { a = 1, [\"b.c\"] = -2.5e1, 'x', \"y\\n\", [[long]], t = { true, false }, h = 0x10; }")
  check("comments, keys, escapes, long strings, hex, ;", v and v.a == 1 and v["b.c"] == -25 and v[1] == "x" and v[2] == "y\n" and v[3] == "long" and v.t[2] == false and v.h == 16)
  local bad, why = SCN.parseData("return {\n  a = math.pi,\n}", "x.lua")
  check("an expression is refused, with the file and line", bad == nil and why:find("x.lua:2:", 1, true) and why:find("math.pi", 1, true), why)
  bad, why = SCN.parseData("return { f = function() end }", "y.lua")
  check("a function is refused (data only, no code)", bad == nil and why:find("function", 1, true), why)
  bad, why = SCN.parseData("return { a = 1", "z.lua")
  check("an unfinished table says so", bad == nil and why:find("unfinished", 1, true), why)
end

-- ── a broken scenario is refused, every error naming its field ──────────────
do
  local bad = {
    id = "bad", title = "Bad", world = { seed = "x" },
    start = { crew = { { name = "A", where = { site = "nowhere" } } }, research = { "notatech" },
              crates = { { at = "crew:B", parts = { ["nope.steel"] = 1 } } } },
    steps = {
      { id = "a", text = "a", goals = { { kind = "roms", struct = "X" } } },
      { id = "a", text = "b", goals = { { kind = "at", who = "crew:A" } }, on_done = { { explode = true } } },
      { id = "c", text = "c", goals = { { kind = "step_done", step = "zz" } } },
    },
    fail = { { kind = "rooms", struct = "X" } },
    score = { par = -1, medals = { bronze = { time = 2 }, gold = { time = 3 }, silver = { time = 2 } } },
  }
  local ok, errs = SCN.validate(bad, CTX)
  local txt = table.concat(errs, "\n")
  check("a broken scenario is refused", not ok)
  for _, want in ipairs({ "world.seed", "start.crew[1].where.site", "start.research[1]", "start.crates[1].at",
                          "start.crates[1].parts.nope.steel", "steps[1].goals[1].kind: unknown kind 'roms'", "steps[2].id: duplicate",
                          "steps[2].goals[1].at: missing", "steps[2].on_done[1]: unknown beat", "steps[3].goals[1].step",
                          "fail[1].kind", "score.par", "score.medals.bronze", "score.medals: gold", "debrief" }) do
    check("the error names " .. want, txt:find(want, 1, true) ~= nil, txt)
  end
end

-- ── the step machine ────────────────────────────────────────────────────────
do
  local sc = { steps = {
    { id = "a" }, { id = "opt", optional = true }, { id = "b", parallel = "p" }, { id = "c", parallel = "p" }, { id = "d" } } }
  local open, cur = SCN.openSteps(sc, {})
  check("the first step is current", cur == 1 and #open == 1)
  open, cur = SCN.openSteps(sc, { a = 1 })
  check("an optional step opens with the next required one", cur == 3 and open[1] == 2 and open[2] == 3 and open[3] == 4, table.concat(open, ","))
  open, cur = SCN.openSteps(sc, { a = 1, b = 2 })
  check("a parallel group stays open until all of it is done", cur == 4)
  open, cur = SCN.openSteps(sc, { a = 1, b = 2, c = 3 })
  check("then the next", cur == 5)
  check("done ignores optional steps", SCN.finished(sc, { a = 1, b = 1, c = 1, d = 1 }) and not SCN.finished(sc, { a = 1, b = 1, c = 1 }))
  local d, n = SCN.progress(sc, { a = 1, opt = 1 })
  check("progress counts required steps", d == 1 and n == 4)
  local pre = SCN.beforeCheckpoint(sc, "c")
  check("a checkpoint pre-latches the steps before it", #pre == 3 and pre[3] == "b")
end

-- ── goal kinds against a stub world ─────────────────────────────────────────
do
  local Wd = { rooms = { { id = 1, sealed = true, m3 = 30 }, { id = 2, sealed = true, airlock = true, m3 = 6 }, { id = 3, sealed = false, m3 = 8 } },
               crewRoom = { nil, nil }, air = { p = 0.7, o2 = 0.15, co2 = 0.001, breathable = true }, helmetOff = false,
               grid = { supply = 2, need = 3, powered = false }, flag = false, dead = false, o2 = 0.5, alive = true, mission = false }
  local W = {
    pos = function(r)
      if r == "crew:A" then return { body = "H", x = 0, y = 600, z = 0 } end
      if r == "mark:m" then return { body = "H", x = 30, y = 600, z = 0 } end
      return nil
    end,
    structId = function(n) return n == "S" and 7 or nil end,
    rooms = function(sid) return Wd.rooms end,
    roomOf = function() return Wd.crewRoom[1], Wd.crewRoom[2] end,
    roomAir = function() return Wd.air end,
    helmetOff = function() return Wd.helmetOff end,
    grid = function() return Wd.grid end,
    parts = function() return { { id = "solarArray.steel" }, { id = "solarArray.steel" }, { id = "wall.steel" } } end,
    flagOn = function() return Wd.flag end,
    crewDead = function() return Wd.dead end,
    suitO2 = function() return Wd.o2 end,
    craftAlive = function() return Wd.alive end,
    mission = function() return Wd.mission end,
  }
  local function ev(g, mem, ctx) return SCN.evalGoal(g, W, mem or {}, ctx or { now = 0 }) end
  local m, r = ev({ kind = "at", who = "crew:A", at = "mark:m", r = 20 })
  check("at: not there, with the distance to go", not m and r == "10 m to go", r)
  m = ev({ kind = "at", who = "crew:A", at = "mark:m", r = 31 })
  check("at: there", m)
  m, r = ev({ kind = "rooms", struct = "S", sealed = 2 })
  check("rooms: two sealed", m and r == "2 of 2 sealed", r)
  m, r = ev({ kind = "rooms", struct = "S", sealed = 3 })
  check("rooms: the reading says how many", not m and r == "2 of 3 sealed", r)
  m = ev({ kind = "rooms", struct = "Nope", sealed = 1 })
  check("rooms: an unknown structure is not met", not m)
  m = ev({ kind = "airlock", struct = "S", count = 1 })
  check("airlock: the chamber counts", m)
  local mem = {}
  m = ev({ kind = "airlock_cycled", struct = "S" }, mem)
  check("airlock_cycled: nothing yet", not m)
  Wd.crewRoom = { 7, 2 }; ev({ kind = "airlock_cycled", struct = "S" }, mem)
  Wd.crewRoom = { 7, 1 }; m, r = ev({ kind = "airlock_cycled", struct = "S" }, mem)
  check("airlock_cycled: through the chamber into the hab", m, r)
  m, r = ev({ kind = "room_air", struct = "S", room = "largest", p = 0.95, o2 = 0.19 })
  check("room_air: the reading names both", not m and r:find("p 0.70 of 0.95", 1, true) and r:find("O2 0.15 of 0.19", 1, true), r)
  Wd.air = { p = 1.0, o2 = 0.21, co2 = 0.001, breathable = true }
  local hm, cx = {}, { now = 0 }
  m, r = ev({ kind = "room_air", struct = "S", room = "largest", p = 0.95, o2 = 0.19, hold = 60 }, hm, cx)
  check("hold: true but not held yet", not m and r:find("held 0 of 60", 1, true), r)
  cx.now = 59.5; m = ev({ kind = "room_air", struct = "S", room = "largest", p = 0.95, hold = 60 }, hm, cx)
  check("hold: 59.5 s is not 60", not m)
  cx.now = 60.1; m = ev({ kind = "room_air", struct = "S", room = "largest", p = 0.95, hold = 60 }, hm, cx)
  check("hold: held", m)
  Wd.air = { p = 0.3, o2 = 0.05, co2 = 0, breathable = false }
  cx.now = 61; m = ev({ kind = "room_air", struct = "S", room = "largest", p = 0.95, hold = 60 }, hm, cx)
  check("hold: a lapse resets it", not m and hm.since == nil)
  m, r = ev({ kind = "grid", struct = "S" })
  check("grid: short, by how much", not m and r == "1.0 kW short", r)
  Wd.grid = { supply = 4, need = 3, powered = true }
  check("grid: served", (ev({ kind = "grid", struct = "S" })))
  m, r = ev({ kind = "helmet", who = "crew:A", off = true })
  check("helmet: on", not m and r == "helmet on")
  Wd.helmetOff = true
  check("helmet: off", (ev({ kind = "helmet", who = "crew:A" })))
  m, r = ev({ kind = "struct_has", struct = "S", part = "solarArray", count = 2 })
  check("struct_has: a part id by its kind prefix", m, r)
  check("flag_on", not ev({ kind = "flag_on", body = "home" }))
  check("crew_dead (fail): alive", not ev({ kind = "crew_dead", any = true }))
  Wd.dead = true
  check("crew_dead (fail): dead", (ev({ kind = "crew_dead", any = true })))
  Wd.o2 = 0
  check("suit_air (fail): ran dry", (ev({ kind = "suit_air", who = "crew:A", below = 0 })))
  local cm = {}
  check("craft_lost: alive is not lost", not ev({ kind = "craft_lost", craft = "K" }, cm))
  Wd.alive = false
  check("craft_lost: gone after being seen", (ev({ kind = "craft_lost", craft = "K" }, cm)))
  check("craft_lost: never seen is not lost", not ev({ kind = "craft_lost", craft = "K" }, {}))
  check("timer: from the start", (ev({ kind = "timer", secs = 10 }, {}, { now = 15, t0 = 4 })) and not ev({ kind = "timer", secs = 12 }, {}, { now = 15, t0 = 4 }))
  check("step_done", (ev({ kind = "step_done", step = "x" }, {}, { now = 0, done = { x = 3 } })))
  check("the missions kinds pass through", not ev({ kind = "orbit", value = 1 }))
  Wd.mission = true
  check("…and read the tracker", (ev({ kind = "land" })))
  m, r = ev({ kind = "nope" })
  check("an unknown kind is never met", not m and r:find("unknown", 1, true))
  W.rooms = function() error("boom") end
  m, r = ev({ kind = "rooms", struct = "S" })
  check("an erroring reader is a reading, not a crash", not m and r:find("error", 1, true), r)
end

-- ── score, medals, profile ──────────────────────────────────────────────────
do
  local sc = { score = { par = 100, budget = { funds = 1000 }, medals = { gold = { time = 1.0, funds = 0.8 }, silver = { time = 1.5 }, bronze = "done" } } }
  check("gold: under par and the budget", SCN.medal(sc, { secs = 90, spent = 700 }) == "gold")
  check("silver: over the budget's 80 %", SCN.medal(sc, { secs = 90, spent = 900 }) == "silver")
  check("bronze: slow is never a wall", SCN.medal(sc, { secs = 500, spent = 5000 }) == "bronze")
  local rows = SCN.score(sc, { secs = 125, spent = 900, hints = 1 })
  check("the debrief rows: time against par", rows[1].value == "2:05" and rows[1].par == "1:40" and rows[1].ok == false)
  check("…money against the budget", rows[2].value == "$900" and rows[2].ok == true)
  local p = SCN.profileRecord(nil, "x", "done", "silver", 120)
  p = SCN.profileRecord(p, "x", "fail", nil, 30)
  p = SCN.profileRecord(p, "x", "done", "gold", 140)
  p = SCN.profileRecord(p, "x", "done", "bronze", 90)
  local e = SCN.profileEntry(p, "x")
  check("profile: best medal, best time, plays, last outcome", e.best == "gold" and e.bestTime == 90 and e.plays == 4 and e.lastOutcome == "done")
  check("unlocked: requires a medal", not SCN.unlocked(p, { requires = { "y" } }) and SCN.unlocked(p, { requires = { "x", medal = "gold" } }) and SCN.unlocked(p, {}))
end

-- ── the slot ────────────────────────────────────────────────────────────────
do
  local sc = SCN.load("_probe")
  local k = SCN.worldKeys(sc)
  check("worldKeys: the seed, the scale, the mode, the id", k.g_seed == 1911564384 and k.g_scale == 4 and k["game.mode"] == "scenario"
    and k.g_scenario == "_probe" and k.g_planets == 3 and k["crew.safety"] == "rescue" and k.g_air == "earth")
  local alien = SCN.worldKeys({ id = "z", world = { seed = 5, home = "alien", homeSeed = 77, air = "none", gen = { moonchance = 1.0 } } })
  check("an alien home and a generator override", alien.g_homeKind == "alien" and alien.g_homeSeed == 77 and alien.g_air == "none" and alien.g_moonchance == 1.0)
  local slots, deleted, dirs, writes = {}, {}, {}, {}
  local cur = "slot1"
  local api = { save = { slot = function(s) if s then cur = s; slots[#slots + 1] = s end return cur end,
                         deleteSlot = function(s) deleted[#deleted + 1] = s end,
                         set = function(kk, v) writes[#writes + 1] = cur .. ":" .. kk end },
                terrain = { saveDir = function() return "saves/slot1/terrain" end, deleteSaveDir = function(d) dirs[#dirs + 1] = d end } }
  local ok = SCN.prepareSlot("_probe", api)
  local only = true
  for _, w in ipairs(writes) do if w:sub(1, 4) ~= "scn:" then only = false end end
  check("PLAY wipes slot scn and its terrain only", ok and deleted[1] == "scn" and #deleted == 1 and dirs[1] == "saves/scn/terrain" and #dirs == 1)
  check("…and writes nothing but slot scn", only and #writes > 10 and slots[1] == "scn")
  for _, f in ipairs({ "solar/scripts/scenario.lua", "solar/scripts/scenario_run.lua" }) do
    local t = slurp(f) or ""
    check("no scenario code names a career slot: " .. f, not t:find('"slot" *%.%.') and not t:find("slot%d", 1, true) and not t:find('"slot1"', 1, true))
  end
  local vals = { g_scenario = "_probe", ["scn.done"] = { walk = 3 } }
  local s = SCN.slotSummary(function(kk) return vals[kk] end)
  check("CONTINUE: the scenario and its step", s and s.title == "Framework Probe" and s.step == 2 and s.steps == 3, s and (s.step .. "/" .. s.steps))
end

-- ── geometry ────────────────────────────────────────────────────────────────
do
  local F = SCN.groundFrame(0.3, 0.9, 0.2)
  local function d(a, b, c, x, y, z) return a * x + b * y + c * z end
  check("the ground frame is orthonormal", math.abs(d(F.ux, F.uy, F.uz, F.fx, F.fy, F.fz)) < 1e-9 and math.abs(d(F.rx, F.ry, F.rz, F.fx, F.fy, F.fz)) < 1e-9
    and math.abs(d(F.fx, F.fy, F.fz, F.fx, F.fy, F.fz) - 1) < 1e-9)
  check("front leans toward the north pole", F.fy > 0)
  local R = 600
  local ground = function(dir) return R + 2 + 0.5 * dir.x end      -- a gentle slope
  local g = { x = 0, y = R + 2, z = 0 }
  local p = SCN.offsetPoint(g, { 10, 0, 0 }, ground)
  local l = math.sqrt(p.x ^ 2 + p.y ^ 2 + p.z ^ 2)
  check("an offset with up 0 is set down on the ground", math.abs(l - ground({ x = p.x / l, y = p.y / l, z = p.z / l })) < 1e-6)
  local dd = math.sqrt((p.x - g.x) ^ 2 + (p.y - g.y) ^ 2 + (p.z - g.z) ^ 2)
  check("…about the distance asked", math.abs(dd - 10) < 0.3, dd)
  local p2 = SCN.offsetPoint(g, { 0, 3, 0 }, ground)
  check("up lifts it off the ground", math.abs(math.sqrt(p2.x ^ 2 + p2.y ^ 2 + p2.z ^ 2) - (ground({ x = 0, y = 1, z = 0 }) + 3)) < 1e-6)
  local py = SCN.offsetPoint(g, { 0, 0, 0 }, ground, 90)
  check("yaw turns the front toward the right", math.abs(py.fx - F.rx * 0 - SCN.groundFrame(0, 1, 0).rx) < 1e-6)
  -- siting over a sphere with a bump and a sea
  local C = { R = R, u = { x = 0, y = 1, z = 0 }, t1 = { x = 1, y = 0, z = 0 }, t2 = { x = 0, y = 0, z = 1 },
              ground = function(dir) return R + 30 * math.max(0, dir.x) ^ 4 end,
              wet = function(dir) return dir.z > 0.6 end, sun = { x = 0, y = -1, z = 0 } }
  local s = SCN.findSpot("far_flat_lit", C)
  check("far_flat_lit: on the far side, lit, dry", s and s.dir.y < -0.5 and s.lit > 0.25 and s.dir.z <= 0.6, s and s.dir.y)
  local nb = SCN.findSpot("near_base", C, 100)
  local ang = nb and math.acos(nb.dir.y) * R
  check("near_base: the distance asked from the spaceport", nb and math.abs(ang - 100) < 1, ang)
  local ll = SCN.findSpot("lat:-10,lon:40", C)
  check("lat/lon: near that point", ll and math.abs(math.deg(math.asin(ll.dir.y)) + 10) < 20)
  local bad, why = SCN.findSpot("moonbase", C)
  check("an unknown rule says so", bad == nil and why:find("unknown", 1, true))
  -- an orbit from elements
  local mu = 600 * 600 * 5
  local r, v = SCN.orbitState(mu, { R = 600, alt = 300 })
  local rl, vl = math.sqrt(r.x ^ 2 + r.y ^ 2 + r.z ^ 2), math.sqrt(v.x ^ 2 + v.y ^ 2 + v.z ^ 2)
  check("orbit: the radius", math.abs(rl - 900) < 1e-6)
  check("orbit: circular speed", math.abs(vl - math.sqrt(mu / 900)) < 1e-6)
  local hy = r.z * v.x - r.x * v.z
  check("orbit: equatorial and prograde about +Y", math.abs(r.y) < 1e-9 and math.abs(v.y) < 1e-9 and hy > 0, hy)
  local r2, v2 = SCN.orbitState(mu, { R = 600, alt = 300, e = 0.2, nu = 0, inc = 30 })
  check("orbit: periapsis speed of an ellipse", math.abs(math.sqrt(v2.x ^ 2 + v2.y ^ 2 + v2.z ^ 2) - math.sqrt(mu * (1 + 0.2) / 900)) < 1e-6)
end

-- ── the serialiser ──────────────────────────────────────────────────────────
do
  local t = { funds = 9000, crew = { { name = "Okafor \"O\"", role = "engineer", control = true, where = { site = "lat:1.5,lon:-2" } } },
              research = { "battery", "tankM" }, ["odd key"] = 1.25 }
  local s = SCN.serialize(t)
  local f = loadstring("return " .. s)
  local back = f and f()
  check("serialize round-trips", back and back.funds == 9000 and back.crew[1].name == "Okafor \"O\"" and back.research[2] == "tankM" and back["odd key"] == 1.25, s)
end

-- ── the scene half over stubs ───────────────────────────────────────────────
do
  local store = {}
  local SAVE = { slot = function() return "scn" end, get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
                 delete = function(k) store[k] = nil end }
  local T = 0                -- game time
  local HOME = { name = "Home", x = 1e6, y = 0, z = 0, radius = 600, mu = 1.8e6, soi = 2e5 }
  local function body_now() return { name = HOME.name, x = HOME.x, y = HOME.y, z = HOME.z, radius = HOME.radius, mu = HOME.mu, soi = HOME.soi } end
  local space = { body = function(n) if n == "Home" then return body_now() end return nil end,
                  bodies = function() return { body_now() } end,
                  dominant = function() return "Home" end, time = function() return T end }
  local terrain = { query = function(x, y, z) return math.sqrt((x - HOME.x) ^ 2 + (y - HOME.y) ^ 2 + (z - HOME.z) ^ 2) - HOME.radius end }
  local ASTRO = { x = HOME.x, y = 650, z = 0, valid = true }
  local log_lines = {}
  local caught = { caption = {}, ops = {}, shot = nil, cine = nil, drops = {}, flags = {}, items = {} }
  local roster = {
    { id = 1, name = "Dana Hale", role = "pilot", status = "afoot", body = "Home" },
    { id = 2, name = "Theo Ito", role = "engineer", status = "base" },
    { id = 3, name = "Rina Vance", role = "scientist", status = "base" },
  }
  local C
  C = {
    ensure = function() end, activeId = function() return 1 end, roster = function() return roster end,
    get = function(id) for _, r in ipairs(roster) do if r.id == id then return r end end end,
    rename = function(id, s) for _, r in ipairs(roster) do if r.id == id then r.name = s end end return true end,
    patch = function(id, f) for _, r in ipairs(roster) do if r.id == id then for k, v in pairs(f) do r[k] = v end end end return true end,
    hire = function() local id = #roster + 1; roster[id] = { id = id, name = "Hire", role = "pilot", status = "base" }; return id end,
    setDown = function(id, x, y, z) local b = body_now(); C.patch(id, { status = "afoot", body = "Home", x = x - b.x, y = y - b.y, z = z - b.z }) end,
    craftOf = function() return nil end,
    alerts = function() return { o2 = 1 } end,
  }
  local INV = { setCap = function() end,
                addItem = function(cid, id, n) caught.items[#caught.items + 1] = cid .. ":" .. id .. "x" .. n; return n end,
                add = function(cid, mat, n) caught.items[#caught.items + 1] = cid .. ":" .. mat .. "x" .. n; return n end }
  local DEP = { agencyClock = function() return T end,
                place = function(k, b, x, y, z, o) local bb = body_now(); caught.flags[#caught.flags + 1] = { k = k, x = x - bb.x, y = y - bb.y, z = z - bb.z, name = o.name }; return #caught.flags end,
                hasFlagOn = function() return #caught.flags > 0 end }
  local SV = { drop = function(b, x, y, z, ig, o) local bb = body_now(); caught.drops[#caught.drops + 1] = { x = x - bb.x, y = y - bb.y, z = z - bb.z, from = o.from, label = o.label }; return #caught.drops end }
  local SCRIPTS = {}
  local ST = loadlib("structures.lua", { save = SAVE })
  local CO = loadlib("company.lua", { save = SAVE, params = { start_funds = 500 }, log = function() end, findScript = function() return nil end })
  local granted = {}
  SCRIPTS = {
    scenario = SCN, crew = C, inventory = INV, deployables = DEP, salvage = SV, structures = ST, blueprints = BPS, company = CO,
    research = { grant = function(id) granted[#granted + 1] = id; return true end, addPoints = function() end },
    planet_walker = { onFoot = true },
    game_manager = { loading = false, saveGame = function() store.saved = (store.saved or 0) + 1 end },
    base_facilities = { sited = true, grading = function() return false end },
    big_caption = { show = function(t, s) caught.caption[#caught.caption + 1] = t end },
    warp_chip = { say = function(s) caught.ops[#caught.ops + 1] = s end },
    planet_camera = { setShot = function(fn) caught.shot = fn end, clearShot = function() caught.shot = nil end,
                      setCinematic = function(on) caught.cine = on end },
    room_air = { roomsOf = function() return { rooms = { { id = 1, sealed = true, m3 = 20 } } } end, crewRoom = function() return nil end,
                 pressurise = function() return 1 end },
    missions = { goalNow = function() return false end },
  }
  store["base.body"], store["base.x"], store["base.y"], store["base.z"] = "Home", 0, 600, 0
  store.g_scenario = "_probe"
  local env = { save = SAVE, space = space, terrain = terrain, findScript = function(k) return SCRIPTS[k] end,
                findScripts = function(k) return (FIND_SCRIPTS or {})[k] or {} end, find = function(n) return n == "Astronaut" and ASTRO or nil end,
                scene = { load = function(n) SCENE_LOADS = (SCENE_LOADS or 0) + 1 end },
                log = function(s) log_lines[#log_lines + 1] = s end, vec3 = function(x, y, z) return { x = x, y = y, z = z } end }
  setmetatable(env, { __index = function(_, k) if k == "time" then return T end return _G[k] end })
  local RUN = loadlib("scenario_run.lua", env)
  local node = { x = 0, y = 0, z = 0 }
  local function frame(dt)
    T = T + (dt or 1 / 60)
    HOME.x = HOME.x + 3.0              -- the planet moves metres a tick
    ASTRO.x = ASTRO.x + 3.0            -- (and carries what stands on it, as the engine does)
    RUN.update(node, dt or 1 / 60)
  end
  RUN.start(node)
  check("the runner wakes up in slot scn with g_scenario", RUN.isActive() and RUN.phaseNow() == "loading")
  for _ = 1, 400 do frame() if RUN.phaseNow() == "running" then break end end
  check("staged, then running (no UI: GO by itself)", RUN.phaseNow() == "running", RUN.phaseNow())
  for _ = 1, 3 do frame() end
  check("scn.staged and a checkpoint save", store["scn.staged"] == true and (store.saved or 0) >= 1, table.concat(log_lines, " | "))
  check("funds staged through the company", CO.balance() == 7000, CO.balance())
  check("research granted", granted[1] == "battery" and granted[2] == "tankM")
  local map = store["scn.crew"] or {}
  check("the controlled member is the active one, renamed", map.Okafor == 1 and C.get(1).name == "Okafor" and C.get(1).role == "engineer")
  check("a second starter renamed and placed on foot", map.Reyes and C.get(map.Reyes).name == "Reyes" and C.get(map.Reyes).status == "afoot")
  local spot = store["scn.spots"].Okafor
  local b = body_now()
  local ax, ay, az = ASTRO.x - b.x, ASTRO.y - b.y, ASTRO.z - b.z
  local sd = math.sqrt((ax - spot.x) ^ 2 + (ay - spot.y) ^ 2 + (az - spot.z) ^ 2)
  check("the astronaut stands on the spot (body-relative, while the body moved)", sd < 1.5, sd)
  local sang = math.acos(spot.y / math.sqrt(spot.x ^ 2 + spot.y ^ 2 + spot.z ^ 2)) * 600
  check("…120 m from the spaceport, on the ground", math.abs(sang - 120) < 2 and math.abs(math.sqrt(spot.x ^ 2 + spot.y ^ 2 + spot.z ^ 2) - 600) < 0.1, sang)
  local marks = store["scn.marks"]
  local mp = marks.post
  local md = math.sqrt((mp.x - spot.x) ^ 2 + (mp.y - spot.y) ^ 2 + (mp.z - spot.z) ^ 2)
  check("marks are body-relative, 25 m from the crew's spot", mp.b == "Home" and math.abs(md - 25) < 0.5, md)
  local sid = (store["scn.structs"] or {})["Probe Hut"]
  local rec = sid and ST.get(sid)
  check("the structure from its SOLBP1 code, through structures.add", rec and #rec.bp == 31 and rec.n == "Probe Hut" and rec.by == "scenario")
  local hd = rec and math.sqrt((rec.x - marks.hut.x) ^ 2 + (rec.y - marks.hut.y) ^ 2 + (rec.z - marks.hut.z) ^ 2)
  check("…standing on its mark", hd and hd < 0.5, hd)
  check("a crate dropped as a salvage crate with the parts", caught.drops[1] and caught.drops[1].label == "Probe drop" and caught.drops[1].from == "scnstage:1")
  local found = false
  for _, it in ipairs(caught.items) do if it == "scnstage:1:part:wall.stee lx2" or it == "scnstage:1:part:wall.steelx2" then found = true end end
  check("…its parts crated (part:<id> items)", found, table.concat(caught.items, " "))
  check("the pack issued", (function() for _, it in ipairs(caught.items) do if it == "crew:1:repairkitx1" then return true end end end)())
  check("a flag planted through deployables", caught.flags[1] and caught.flags[1].name == "Probe flag")
  check("on_start beats: the Ops line is on screen (no UI: the built-in subtitle)", RUN.state().line and RUN.state().line.text == "Probe live." and RUN.state().line.name == "Ops", RUN.state().line and RUN.state().line.text)
  local st = RUN.state()
  check("state(): step 1 of 3, its goal with a reading", st.step == 1 and st.steps == 3 and st.stepId == "walk" and st.goals[1] and st.goals[1].reading:find("to go", 1, true), st.goals[1] and st.goals[1].reading)
  check("the card step names the scenario and has a spot", (function() local c = RUN.cardStep(); return c and c.task == "Walk to the post." and c.spot and c.spot.x end)())
  -- walk: put the astronaut on the post (body-relative → world now)
  local function stand(m)
    local bb = body_now()
    ASTRO.x, ASTRO.y, ASTRO.z = bb.x + m.x, bb.y + m.y, bb.z + m.z
  end
  for _ = 1, 30 do stand(mp); frame() end
  check("step 1 latched with its time", (store["scn.done"] or {}).walk ~= nil)
  check("the optional room step latched alongside", (store["scn.done"] or {}).hut ~= nil)
  for _ = 1, 120 do stand(mp); frame() end
  check("hold: not before 5 s", (store["scn.done"] or {}).wait == nil)
  -- (scnfix, Ty 11-12) a step only waiting on a hold says so: the bar, the time left
  local wst = RUN.state().wait
  check("wait: a running hold shows a bar with the time left", wst and wst.eta > 0.5 and wst.eta < 4.5 and wst.frac > 0.1 and wst.frac < 0.9 and wst.id == "wait",
    wst and string.format("%s eta %.2f frac %.2f", tostring(wst.label), wst.eta, wst.frac) or "no wait")
  for _ = 1, 240 do stand(mp); frame() end
  for _ = 1, 60 do stand(mp); frame() end
  check("on_done: a mark beat added a mark (after the lines before it)", store["scn.marks"].beyond ~= nil)
  check("hold: latched after 5 s on the post", (store["scn.done"] or {}).wait ~= nil)
  -- the camera beat: the pivot rides the body
  for _ = 1, 10 do frame() end
  check("caption beat", caught.caption[1] == "PROBE")
  check("camera beat: cinematic on and a shot", caught.cine == true and caught.shot ~= nil, tostring(caught.cine) .. " " .. tostring(caught.shot) .. " " .. table.concat(caught.caption, ",") .. " :: " .. table.concat(log_lines, " | "):sub(-600))
  if caught.shot then
    local cx, cy, cz, px, py, pz = caught.shot()
    local bb = body_now()
    local d1 = math.sqrt((px - bb.x - rec.x) ^ 2 + (py - bb.y - rec.y) ^ 2 + (pz - bb.z - rec.z) ^ 2)
    frame(); frame()
    local _, _, _, qx, qy, qz = caught.shot()
    bb = body_now()
    local d2 = math.sqrt((qx - bb.x - rec.x) ^ 2 + (qy - bb.y - rec.y) ^ 2 + (qz - bb.z - rec.z) ^ 2)
    check("the pivot is the structure, placed against this frame's body", d1 < 3 and math.abs(d1 - d2) < 1e-6, d1 .. " " .. d2)
  end
  for _ = 1, 400 do frame() if RUN.phaseNow() ~= "running" then break end end
  check("the flag step and the finish", RUN.phaseNow() == "done" or RUN.phaseNow() == "freeplay", RUN.phaseNow() .. " q " .. (function() local a,b,c,d = RUN.debugQueue(); return tostring(a)..tostring(b)..tostring(c)..tostring(d) end)())
  check("a medal in the slot", store["scn.medal"] == "gold" or store["scn.medal"] == "silver", store["scn.medal"])
  check("no UI: the medal as a caption, then freeplay", caught.caption[#caught.caption]:find(string.upper(store["scn.medal"] or "x"), 1, true) and RUN.phaseNow() == "freeplay")
  check("camera handed back", caught.cine == false)
  check("allows(): contracts back in freeplay", RUN.allows("contracts") == true)
  -- a fail: a fresh runner, crew dead
  for k in pairs(store) do if k:sub(1, 4) == "scn." then store[k] = nil end end
  roster[1].status = "afoot"
  local RUN2 = loadlib("scenario_run.lua", env)
  RUN2.start(node)
  for _ = 1, 400 do frame(); RUN2.update(node, 1 / 60) if RUN2.phaseNow() == "running" then break end end
  check("allows(): contracts off while running", RUN2.allows("contracts") == false and RUN2.allows("programme") == false)
  check("allows(): always true outside a scenario", (function() local e2 = {}; for k, v in pairs(env) do e2[k] = v end
    e2.save = { slot = function() return "slot1" end, get = function() return nil end, set = function() end }
    setmetatable(e2, getmetatable(env)); local R3 = loadlib("scenario_run.lua", e2); R3.start(node); return R3.allows("contracts") and not R3.isActive() end)())
  roster[1].status = "dead"
  for _ = 1, 30 do frame(); RUN2.update(node, 1 / 60) end
  check("a fail condition ends the run", RUN2.phaseNow() == "failed" and store["scn.outcome"] == "fail" and store["scn.failText"] == "Okafor did not make it.")
  local s2 = RUN2.state()
  check("state() after a fail: the debrief line and the score rows", s2.debrief == "Probe failed." and type(s2.score) == "table" and s2.score[1].label == "Time")
  -- idle cost: a runner in a career slot does nothing a frame
  local e3 = {}; for k, v in pairs(env) do e3[k] = v end
  e3.save = { slot = function() return "slot2" end, get = function() error("an idle runner read the save") end, set = function() error("wrote") end }
  e3.findScript = function() error("an idle runner looked something up") end
  setmetatable(e3, getmetatable(env))
  local okIdle = pcall(function()
    local R4 = loadlib("scenario_run.lua", e3)
    e3.save.get = function(k) if k == "g_scenario" then return nil end error("read " .. k) end
    R4.start(node)
    e3.save.get = function(k) error("read " .. k) end
    for _ = 1, 100 do R4.update(node, 1 / 60) end
  end)
  check("an idle runner reads nothing and finds nothing a frame", okIdle)
  -- listeners: a UI claims the briefing and the strip
  for k in pairs(store) do if k:sub(1, 4) == "scn." then store[k] = nil end end
  roster[1].status = "afoot"
  local RUN5 = loadlib("scenario_run.lua", env)
  local heard, phases = {}, {}
  RUN5.listen("ops", function(t, who) heard[#heard + 1] = (who or "Ops") .. ":" .. t end)
  RUN5.listen("phase", function(p) phases[#phases + 1] = p end)
  RUN5.wantBriefing(true)
  RUN5.start(node)
  for _ = 1, 400 do frame(); RUN5.update(node, 1 / 60) if RUN5.phaseNow() == "briefing" then break end end
  check("a UI's briefing holds the run", RUN5.phaseNow() == "briefing")
  RUN5.go()
  for _ = 1, 200 do frame(); RUN5.update(node, 1 / 60) end
  check("GO runs it; the Ops strip hears the lines, with who", RUN5.phaseNow() == "running" and heard[1] == "Ops:Probe live." and heard[2] == "Reyes:I'm here too.", heard[2])
  check("the phase listener heard every phase", table.concat(phases, ","):find("staging,briefing,running", 1, true) ~= nil, table.concat(phases, ","))
  RUN5.completeStep()
  for _ = 1, 20 do frame(); RUN5.update(node, 1 / 60) end
  check("F11 latches the current step", (store["scn.done"] or {}).walk ~= nil)

  -- (scnfix, Ty 11-12: "I drove past the first relay marker straight to
  -- Asha and was stuck") ordered waypoints: a later step met passes the
  -- ones before it; their on_done does not play, their on_skip does; a
  -- step met from the start is no reason to skip
  do
    local PS = SCN.load("_probe")
    local keep = PS.steps
    PS.steps = {
      { id = "a", text = "To the post.", mark = "mark:post", goals = { { kind = "at", who = "crew:Okafor", at = "mark:post", r = 4 } },
        on_done = { { var = { a_done = true } } }, on_skip = { { var = { a_skipped = true } } } },
      { id = "b", text = "To the hut.", mark = "mark:hut", goals = { { kind = "at", who = "crew:Okafor", at = "mark:hut", r = 4 } } },
      { id = "c", text = "Plant the flag.", goals = { { kind = "flag_on", body = "home" } } },
    }
    for k in pairs(store) do if k:sub(1, 4) == "scn." then store[k] = nil end end
    store.g_scenario = "_probe"
    roster[1].status = "afoot"
    local RS = loadlib("scenario_run.lua", env)
    RS.start(node)
    for _ = 1, 400 do frame(); RS.update(node, 1 / 60) if RS.phaseNow() == "running" then break end end
    for _ = 1, 30 do frame(); RS.update(node, 1 / 60) end
    check("skip: the flag met from the start passes nothing", (store["scn.done"] or {}).a == nil, table.concat(log_lines, " | "):sub(-300))
    local hm = store["scn.marks"].hut
    for _ = 1, 40 do stand(hm); frame(); RS.update(node, 1 / 60) end
    local dn = store["scn.done"] or {}
    check("skip: standing at the second marker latches the first with it", dn.a ~= nil and dn.b ~= nil, tostring(dn.a) .. " " .. tostring(dn.b))
    for _ = 1, 400 do frame(); RS.update(node, 1 / 60) end      -- (the opening's line holds the beats behind it)
    check("skip: the passed step's on_skip plays, its on_done does not", RS.var("a_skipped") == true and RS.var("a_done") == nil, tostring(RS.var("a_skipped")) .. " " .. tostring(RS.var("a_done")) .. " " .. table.concat(log_lines, " | "):sub(-500))
    PS.steps = keep
  end

  -- ── v2: the story probe (scenarios/_story/: a folder scenario with hooks) ──
  local function fresh_run(id)
    for k in pairs(store) do if k:sub(1, 4) == "scn." then store[k] = nil end end
    store.g_scenario = id
    roster[1].status, roster[2].status = "afoot", "base"
    local R = loadlib("scenario_run.lua", env)
    R.start(node)
    return R
  end
  local steers = {}
  SCRIPTS.planet_walker = { onFoot = true, steer = function(f, s) steers[#steers + 1] = f == nil and "nil" or (tostring(f) .. "," .. tostring(s)) end }
  local GM = SCRIPTS.game_manager
  local S = fresh_run("_story")
  local function tick(n) for _ = 1, n or 1 do frame(); S.update(node, 1 / 60) end end
  for _ = 1, 400 do tick() if S.phaseNow() == "running" then break end end
  tick(3)
  local sst = S.state()
  check("story: the folder scenario loaded with its hooks", S.scenario()._hooks and S.scenario()._dir == "scenarios/")
  check("story: the intro is a cutscene: the keys held, the interface hidden", sst.cutscene == true and GM.inputOwner == "scenario" and caught.cine == true, table.concat(log_lines, " | "):sub(-900))
  check("story: the walker is steered to a standstill", steers[#steers] == "0,0", steers[#steers])
  check("story: a line from the cast, named and tagged", sst.line and sst.line.name == "Dr. Hale" and sst.line.tag == "SITE CHIEF", sst.line and sst.line.name)
  local hut = (store["scn.structs"] or {})["Story Hut"]
  local hrec = ST.get(hut)
  local doorm = store["scn.marks"].door
  check("story: a mark on a structure (the second marks pass)", doorm ~= nil)
  local rp = C.get(store["scn.crew"].Reyes)
  local dd = doorm and rp.x and math.sqrt((rp.x - doorm.x) ^ 2 + (rp.y - doorm.y) ^ 2 + (rp.z - doorm.z) ^ 2)
  check("story: Reyes at her post by the door", dd and dd < 2, dd)
  -- the shot's pivot rides the body
  if caught.shot then
    local _, _, _, px, py, pz = caught.shot()
    local bb = body_now()
    local d1 = math.sqrt((px - bb.x - hrec.x) ^ 2 + (py - bb.y - hrec.y) ^ 2 + (pz - bb.z - hrec.z) ^ 2)
    check("story: the orbit's pivot is the hut, this frame", d1 < 3, d1)
  end
  -- Esc held: skip, the walk still lands
  S.skipCutscene()
  tick(2)
  local ridge = store["scn.marks"].ridge
  rp = C.get(store["scn.crew"].Reyes)
  local rd = math.sqrt((rp.x - ridge.x) ^ 2 + (rp.y - ridge.y) ^ 2 + (rp.z - ridge.z) ^ 2)
  check("story: a skipped cutscene still moves Reyes to the ridge", rd < 2, rd)
  check("story: the keys and the camera are handed back", GM.inputOwner ~= "scenario" and caught.cine == false and steers[#steers] == "nil", tostring(GM.inputOwner) .. " " .. tostring(steers[#steers]))
  tick(5)
  sst = S.state()
  check("story: the choice is up, with its options", sst.choice and sst.choice.name == "Dr. Hale" and #sst.choice.options == 2)
  S.choose(1)
  tick(2)
  check("story: the choice set its variable", S.var("trust") == 1 and S.state().vars.trust == 1)
  check("story: and ran its sequence", S.state().line and S.state().line.text == "Good. Walk over.")
  -- the fault fires on its timer: a cutscene, an alarm, a knock, a hook
  for _ = 1, 600 do tick() if S.var("faulted") then break end end
  local lp
  for _, p in ipairs(ST.get(hut).bp) do if p.id:match("^lightFitting") then lp = p end end
  check("story: the timed event knocked the light (the X8 look)", lp and lp.wr == true)
  check("story: the hook beat set a variable", S.var("faulted") == true)
  check("story: the alarm is on during the fault", S.state().alarm == true)
  -- walk to the door
  for _ = 1, 30 do local bb = body_now(); ASTRO.x, ASTRO.y, ASTRO.z = bb.x + doorm.x, bb.y + doorm.y, bb.z + doorm.z; tick() end
  check("story: walk latched", (store["scn.done"] or {}).walk ~= nil)
  for _ = 1, 400 do tick() if not S.state().cutscene then break end end
  check("story: the fault cutscene ends by itself (its last shot does not hold it open)", not S.state().cutscene)
  tick(30)
  local fr = S.readingsNow()
  local fi = SCN.stepIndex(S.scenario(), "fix") or 2
  check("story: the fix step reads the knocked piece and the hook goal", fr[fi] and fr[fi][1].reading == "knocked" and fr[fi][2].reading == "the fault happened", fr[fi] and (fr[fi][1].reading .. " / " .. fr[fi][2].reading))
  lp.wr = nil
  ST.put(ST.get(hut))
  for _ = 1, 600 do tick() if S.phaseNow() ~= "running" then break end end
  check("story: repaired, the done beat after its line finishes the run", S.phaseNow() == "freeplay" and store["scn.outcome"] == "done", S.phaseNow())
  check("story: the alarm off again", S.state().alarm == false)
  -- the other branch: "After the shift" jumps to `late`
  local S2 = fresh_run("_story")
  S = S2
  for _ = 1, 400 do tick() if S.phaseNow() == "running" then break end end
  tick(3); S.skipCutscene()
  for _ = 1, 900 do tick() if S.state().choice then break end end
  S.choose(2)
  for _ = 1, 600 do tick() if S.phaseNow() ~= "running" then break end end
  check("story: choice 2 jumps the steps (goto) and its variable ends it", (store["scn.done"] or {}).late ~= nil and (store["scn.done"] or {}).walk ~= nil and S.var("trust") == -1, S.phaseNow() .. " " .. tostring(S.var("trust")) .. " :: " .. table.concat(log_lines, " | "):sub(-700))
  local heardGrumble = false
  for _, l in ipairs(log_lines) do if l:find("Fine. After.", 1, true) then heardGrumble = true end end
  check("story: the variable's event spoke", heardGrumble)

  -- ── FW-C (work/scenarios2/PLAN.md §2): the story framework pack ──────────
  -- a CrewBody stub for Reyes: it records what steerSelf is handed each frame
  local steer_calls = {}
  local reyes_cb = { doll = false, steerSelf = function(b, x, y, z) steer_calls[#steer_calls + 1] = { b = b, x = x, y = y, z = z, T = T }; return true end,
                     arrived = function() return false end, steerStop = function() end, walkDist = function() return 99 end,
                     lookSelf = function(fn) reyes_look = fn end }
  local forced = {}
  SCRIPTS.crew_faces = { force = function(id, name, w, secs) forced[#forced + 1] = tostring(id) .. ":" .. name end }
  local S3 = fresh_run("_story")
  S = S3
  reyes_cb.memberId = nil
  FIND_SCRIPTS = { crew_body = { reyes_cb } }
  for _ = 1, 400 do tick() if S.phaseNow() == "running" then break end end
  reyes_cb.memberId = store["scn.crew"].Reyes
  -- the first line is two-speaker: Hale with Okafor beside her
  tick(3)
  local l1 = S.state().line
  check("FW-C: say.with puts the listener on the line", l1 and l1.name == "Dr. Hale" and l1.with and l1.with.name == "Dele Okafor", l1 and l1.with and l1.with.name)
  check("FW-C: the radio voice is not on screen yet (delay 3)", S.pendingLines() == 1, S.pendingLines())
  -- play the intro through without skipping: Reyes's walk steers her body
  for _ = 1, 900 do tick() if #steer_calls > 30 then break end end
  check("FW-C: walk hands crew_body.steerSelf a target every frame", #steer_calls > 30, #steer_calls)
  local ridge = store["scn.marks"].ridge
  local okRel = #steer_calls > 0
  for _, c in ipairs(steer_calls) do
    if math.abs(c.x - ridge.x) > 0.6 or math.abs(c.y - ridge.y) > 0.6 or math.abs(c.z - ridge.z) > 0.6 or c.b ~= "Home" then okRel = false end
  end
  check("FW-C: …body-relative, the same point while the planet moved metres a tick (never a kept world point)", okRel,
    steer_calls[1] and string.format("%.1f %.1f %.1f vs %.1f %.1f %.1f", steer_calls[1].x, steer_calls[1].y, steer_calls[1].z, ridge.x, ridge.y, ridge.z))
  local rp3 = C.get(store["scn.crew"].Reyes)
  check("FW-C: …and she is not teleported while she walks", math.abs((rp3.x or 0) - ridge.x) > 2 or math.abs((rp3.z or 0) - ridge.z) > 2)
  check("FW-C: the look beat gave her body a per-frame point", type(reyes_look) == "function" and select(1, reyes_look()) ~= nil)
  -- the radio line arrives 3 game seconds after its beat
  local heardVance, vT = false, nil
  for _ = 1, 4000 do
    tick()
    if S.state().choice then S.choose(1) end
    local ln = S.state().line
    if ln and ln.name == "Mara Vance" then heardVance, vT = true, T; break end
  end
  check("FW-C: the radio voice spoke after its delay, marked as radio", heardVance and S.state().line.radio == true, vT)
  -- the fault: the meter counts the dark, the model cools the hut, a face is forced
  for _ = 1, 600 do tick() if S.var("faulted") then break end end
  for _ = 1, 30 do local bb = body_now(); ASTRO.x, ASTRO.y, ASTRO.z = bb.x + doorm.x, bb.y + doorm.y, bb.z + doorm.z; tick() end
  for _ = 1, 400 do tick() if not S.state().cutscene then break end end
  check("FW-C: the face beat forced Reyes's expression", forced[#forced] == tostring(store["scn.crew"].Reyes) .. ":worried", forced[#forced])
  local cold = false
  for _ = 1, 60 * 20 do tick() if (S.var("hut_c") or 99) < 12 then cold = true break end end
  check("FW-C: a meter integrated the seconds in the dark", (S.var("dark_secs") or 0) > 5, S.var("dark_secs"))
  check("FW-C: the model cooled the hut below 12 °C while the light was out", cold, S.var("hut_c"))
  check("FW-C: …and its min meter followed it", (S.var("hut_min") or 99) <= (S.var("hut_c") or 0) + 0.5, S.var("hut_min"))
  local said12 = false
  for _ = 1, 600 do tick(); for _, l in ipairs(log_lines) do if l:find("getting cold", 1, true) then said12 = true end end if said12 then break end end
  check("FW-C: the model's crossing spoke its line", said12)
  check("FW-C: the checkpoint snapshot was taken as the fix opened", store["scn.cpSnap"] and store["scn.cpSnap"].id == "fix" and store["scn.cpSnap"].vars.trust == 1)
  -- a SETBACK: a fail goes back to the checkpoint, the story kept
  local loads0 = SCENE_LOADS or 0
  SAVE.deleteSlot = function() for k in pairs(store) do if k:sub(1, 4) == "scn." then store[k] = nil end end end
  -- (storypolish) the fail screen listens: the setback carries its words and
  -- waits for CONTINUE (no auto-advance)
  local sbk = nil
  S.listen("setback", function(sb) sbk = sb end)
  S.fail("Okafor fell through the floor.", { kind = "crew_dead", any = true, text = "Okafor fell through the floor.", hint = "Mind the hatch." })
  tick(2)
  check("FW-C: a fail in a story scenario is a setback, not the debrief", S.phaseNow() == "setback" and store["scn.outcome"] == nil, S.phaseNow())
  check("storypolish: the setback carries the fail screen's words and where it goes back to",
    sbk and sbk.title == "MISSION FAILED" and sbk.text == "Okafor fell through the floor." and sbk.hint == "Mind the hatch." and sbk.to == "fix"
    and type(sbk.act) == "string" and type(sbk.clock) == "number" and S.state().setback == sbk, sbk and (tostring(sbk.title) .. " / " .. tostring(sbk.act)))
  for _ = 1, 600 do tick() if (SCENE_LOADS or 0) > loads0 then break end end
  check("storypolish: nothing moves on by itself while the fail screen is up", (SCENE_LOADS or 0) == loads0 and S.phaseNow() == "setback")
  check("storypolish: CONTINUE puts it back", S.continueSetback() == true and S.continueSetback() == false)
  for _ = 1, 60 do tick() if (SCENE_LOADS or 0) > loads0 then break end end
  check("FW-C: …then the run is put back (the slot restaged, the scene loaded)", (SCENE_LOADS or 0) > loads0)
  check("FW-C: the restore kept the story: vars, the steps before, no opening again, the setback counted",
    store["scn.vars"] and store["scn.vars"].trust == 1 and store["scn.vars"].faulted == true and (store["scn.done"] or {}).walk ~= nil
    and (store["scn.done"] or {}).fix == nil and store["scn.started"] == true and store["scn.setbacks"] == 1 and store["scn.retryFrom"] == "fix",
    tostring(store["scn.vars"] and store["scn.vars"].trust) .. " " .. tostring(store["scn.setbacks"]))
  SAVE.deleteSlot = nil
  FIND_SCRIPTS = nil
  SCRIPTS.crew_faces = nil
end

-- ── storypolish: a slow model steps from its unrounded value ───────────────
do
  local md = { var = "km", start = 8, rate = -0.005, min = 0, round = 0.01 }
  local v, raw = 0.2, 0.2
  for _ = 1, 40 do local nv, _, rv = SCN.stepModel(md, raw, true, 0.25); v, raw = nv, rv end
  check("model: 0.005/s at 1x, rounded to 0.01, still moves when stepped from its raw value", v <= 0.15 and math.abs(raw - 0.15) < 1e-9, v)
end
-- ── storypolish: the fail screen's words, pure ─────────────────────────────
do
  local w = SCN.failWords({ kind = "crew_dead", any = true }, { who = "Imre Szabo", cause = "oxygen", player = true, clock = 2467 })
  check("fail words: the player's own death is YOU DIED, the cause in the second person, with its hint",
    w.title == "YOU DIED" and w.text == "Your suit ran out of air." and w.hint:find("half a tank", 1, true) and w.cause == "Imre Szabo  ·  out of oxygen", w.title .. " / " .. tostring(w.text))
  w = SCN.failWords({ kind = "crew_dead", any = true, text = "Kerne Station lost its night engineer." }, { who = "Dana Kovac", cause = "radiation", player = false })
  check("fail words: someone else's death is MISSION FAILED, the author's line kept",
    w.title == "MISSION FAILED" and w.text == "Kerne Station lost its night engineer." and w.cause == "Dana Kovac  ·  radiation sickness", w.title)
  w = SCN.failWords({ kind = "core_melted", struct = "X" }, { clock = 192 })
  check("fail words: a kind's default, {clock} filled", w.title == "MELTDOWN" and w.text == "3:12 in, the core melted. Nothing was cooling it.", w.text)
  w = SCN.failWords({ kind = "core_melted", title = "KERNE IS DARK", text = "At {clock} the core uncovered.", hint = "Feed it." }, { clock = 61 })
  check("fail words: the author's title, text and hint win", w.title == "KERNE IS DARK" and w.text == "At 1:01 the core uncovered." and w.hint == "Feed it.", w.text)
  w = SCN.failWords("Probe setback.", {})
  check("fail words: a plain fail beat", w.title == "MISSION FAILED" and w.text == "Probe setback." and type(w.hint) == "string", w.title)
  local _, bad = SCN.validate({ id = "x", title = "X", steps = { { id = "a", text = "a", goals = { { kind = "var", name = "v", is = true } } } },
    score = { par = 10 }, debrief = { bronze = "b", fail = "f" }, fail = { { kind = "timer", secs = 5, text = "t", title = 3 } } }, CTX)
  local hit = false
  for _, e in ipairs(bad or {}) do if tostring(e):find("fail%[1%]%.title") then hit = true end end
  check("fail words: validation names a title that is not a string", hit, bad and table.concat(bad, "; "):sub(1, 200))
end

-- ── FW-C: the new kinds, pure ───────────────────────────────────────────────
do
  local Wst = {
    structId = function(n) return n == "Base" and 7 or nil end,
    grid = function() return { supply = 4, need = 3, powered = true, stored = 30, cap = 100 } end,
    breaker = function(t) return t.part == "breaker" and "tripped" or nil end,
    partHp = function(g) return g.craft == "Kite" and 0.42 or nil end,
    piece = function(g) return g.part == "pump" and { pumpOn = false, knocked = false, temp = 71 } or nil end,
    rooms = function() return { { id = 1, sealed = true, m3 = 30 } } end,
    roomAir = function() return { breathable = false, why = "CO2" } end,
  }
  local m, r = SCN.evalGoal({ kind = "power_read", struct = "Base", battery_below = 0.35, need_above = 2 }, Wst, {}, {})
  check("power_read: battery share and draw", m == true and r:find("battery 30%%") and r:find("3.0 kW drawn"), r)
  m, r = SCN.evalGoal({ kind = "power_read", struct = "Base", breaker = "breaker", state = "closed" }, Wst, {}, {})
  check("power_read: a breaker's state", m == false and r == "breaker tripped", r)
  m, r = SCN.evalGoal({ kind = "part_hp", craft = "Kite", part = "dish", below = 0.5 }, Wst, {}, {})
  check("part_hp: a craft part's health", m == true and r == "hp 0.42", r)
  m, r = SCN.evalGoal({ kind = "piece_state", struct = "Base", part = "pump", on = false, field = "temp", gt = 60 }, Wst, {}, {})
  check("piece_state: running, and a field", m == true and r:find("off") and r:find("temp = 71"), r)
  local mem = {}
  m = SCN.evalGoal({ kind = "room_unbreathable", struct = "Base", secs = 10 }, Wst, mem, { now = 0 })
  local m2, r2 = SCN.evalGoal({ kind = "room_unbreathable", struct = "Base", secs = 10 }, Wst, mem, { now = 11 })
  check("room_unbreathable: true only after secs of bad air", m == false and m2 == true and r2:find("CO2"), r2)
  -- meters
  check("meter: integrate", SCN.stepMeter({ mode = "integrate", scale = 2 }, 1, 3, 0.5) == 4)
  check("meter: peak and min", SCN.stepMeter({ mode = "peak" }, 5, 3, 1) == 5 and SCN.stepMeter({ mode = "min" }, 5, 3, 1) == 3)
  check("meter: delta from the first reading, rounded", SCN.stepMeter({ delta = true, round = 0.1 }, nil, 1.234, 1, 1.0) == 0.2)
  -- models: Graveyard's bearing as data reproduces its hook (scn_graveyard_shift_hooks.lua tick)
  local md = { var = "brg", start = 61, rate = 0.085, accel = 0.008333, base = 58, at = { { value = 115 } } }
  local T1, T2, crossedAt = 61, 61, nil
  for k = 1, 4000 do
    T1 = T1 + 0.085 * 0.25 * (1 + (T1 - 58) / 120)
    local c
    T2, c = SCN.stepModel(md, T2, true, 0.25)
    if #c > 0 and not crossedAt then crossedAt = k end
  end
  check("model: Graveyard's bearing as a model follows its hook's curve", math.abs(T1 - T2) < 0.05 * T1, T1 .. " vs " .. T2)
  check("model: …and fires its seize beat at 115", crossedAt ~= nil, crossedAt)
  local v = SCN.stepModel({ rest = 40, tau = 300 }, 100, false, 300)
  check("model: settles toward rest with its time constant", math.abs(v - (40 + 60 * math.exp(-1))) < 0.01, v)
  -- radio, time, faces, portraits
  check("garble: every third word lost, the rest kept", SCN.garble("one two three four five six", 0) == "one two — four five —", SCN.garble("one two three four five six", 0))
  local x, y, z = SCN.heldSun({ x = 0, y = 1, z = 0 }, 30, { x = 1, y = 0, z = 0 })
  check("heldSun: the held elevation, toward the star's azimuth", math.abs(math.deg(math.asin(y)) - 30) < 0.01 and x > 0.8, string.format("%.3f %.3f %.3f", x, y, z))
  check("elevationOf: names and degrees", SCN.elevationOf("night") < 0 and SCN.elevationOf(12) == 12 and SCN.elevationOf("teatime") == nil)
  check("portraitOf: auto is the booth's file", SCN.portraitOf({ id = "x" }, "hale", { portrait = "auto" }) == "x/hale.png")
  -- the validator names every new field it refuses
  local bad = SCN.load("_story", true)
  local c2 = SCN.deepCopy(bad)
  c2._file = "scenarios/_story/scenario.lua"
  c2.cast.hale.radoi = true
  c2.cast.vance.delay = -1
  c2.cast.vance.link = "mark:x"
  c2.world.time.at = "teatime"
  c2.meters[1].read = "bogus.x"
  c2.models[1].when = { kind = "nope" }
  c2.sequences.intro[3] = { say = { who = "hale", with = "nobody", text = "x" } }
  c2.sequences.fault[6] = { face = { who = "Reyes", emotion = "smug" } }
  c2.sequences.fault[5] = { light = { ambient = "dim" } }
  c2.sequences.now[2] = { weather = { kind = "sharknado" } }
  c2.sequences.now[3] = { music = "loud" }
  c2.failure = "maybe"
  local okv, errs = SCN.validate(c2, CTX)
  local txt = table.concat(errs, "\n")
  for _, want in ipairs({ "scenarios/_story/scenario.lua: cast.hale.radoi", "cast.vance.delay", "cast.vance.link", "world.time.at",
                          "meters[1].read", "models[1].when.kind", "sequences.intro[3].say.with", "sequences.fault[6].face.emotion",
                          "sequences.fault[5].light.ambient", "sequences.now[2].weather.kind", "sequences.now[3].music", "failure" }) do
    check("FW-C validation names " .. want, not okv and txt:find(want, 1, true) ~= nil, txt:sub(1, 300))
  end
  -- graveyard2: turn, pose, gesture, walk's near/face/pose, an event's `also`, a crew title, stage beats
  local c3 = SCN.deepCopy(bad)
  c3._file = "scenarios/_story/scenario.lua"
  c3.sequences.intro[3] = { turn = { who = "hale" } }
  c3.sequences.fault[6] = { pose = { who = "hale", kind = "nap", at = "mark:nowhere" } }
  c3.sequences.fault[5] = { gesture = { who = "hale", clip = "moonwalk" } }
  c3.sequences.now[2] = { walk = { who = "hale", to = "mark:hut", near = -1, face = "mark:nowhere", pose = { kind = "float" } } }
  c3.events = c3.events or {}
  c3.events[#c3.events + 1] = { id = "x", when = { kind = "var", name = "a", is = true }, also = { kind = "nope" }, beats = {} }
  c3.start.crew[1].title = 7
  local okg, errg = SCN.validate(c3, CTX)
  local tg = table.concat(errg, "\n")
  for _, want in ipairs({ "sequences.intro[3].turn.to", "sequences.fault[6].pose.kind", "sequences.fault[6].pose.at",
                          "sequences.fault[5].gesture.clip", "sequences.now[2].walk.near", "sequences.now[2].walk.face",
                          "sequences.now[2].walk.pose", ".also.kind", "start.crew[1].title" }) do
    check("graveyard2 validation names " .. want, not okg and tg:find(want, 1, true) ~= nil, tg:sub(1, 400))
  end
  local gs = SCN.load("graveyard_shift", true)
  local okgs, egs = SCN.validate(gs, CTX)
  check("graveyard_shift validates with Dana's walks, poses, gestures and the wake event", okgs, table.concat(egs or {}, " | "))
  local hasWake, hasPose = false, false
  for _, e in ipairs(gs.events or {}) do if e.id == "wake" and e.also then hasWake = true end end
  for _, b in ipairs(gs.sequences.dana_off or {}) do if b.walk and b.walk.pose and b.walk.pose.kind == "lie" then hasPose = true end end
  check("Graveyard: Dana walks to her bunk and lies down; walking up to her wakes her", hasWake and hasPose)
  local nohint = {}
  for _, s in ipairs(gs.steps) do if not s.hint then nohint[#nohint + 1] = s.id end end
  check("Graveyard: every step has a hint", #nohint == 0, table.concat(nohint, ","))
  SCN.forget()
end

-- (gy3, Ty 2026-11-11) goals that read the world whatever the player does,
-- cast members who are not playable, names that agree
do
  local P = { me = { body = "H", x = 0, y = 600, z = 0 } }
  local using = false
  local W = {
    pos = function(r)
      if r == "crew:A" then return P.me end
      if r == "mark:c" then return { body = "H", x = 0, y = 598.5, z = 1.2 } end   -- the console's mark: terrain 1.5 m under the capsule's centre
      return nil
    end,
    using = function(g) if using then return true, "at its terminal" end return false, "not in use" end,
  }
  local function ev(g, mem) return SCN.evalGoal(g, W, mem or {}, { now = 0 }) end
  local m, r = ev({ kind = "at", who = "crew:A", at = "mark:c", r = 1.6 })
  check("gy3 at: along the ground (1.2 m), not through the floor (1.9 m)", m, r)
  P.me = { body = "H", x = 0, y = 605, z = 1.2 }
  m, r = ev({ kind = "at", who = "crew:A", at = "mark:c", r = 1.6 })
  check("gy3 at: a storey up is not there (dy 3)", not m and r:find("above", 1, true), r)
  m = ev({ kind = "at", who = "crew:A", at = "mark:c", r = 1.6, dy = 8 })
  check("gy3 at: dy widens it", m)
  P.me = { body = "H", x = 4, y = 600, z = 0 }
  local anyG = { kind = "any", goals = { { kind = "at", who = "crew:A", at = "mark:c", r = 1.8 }, { kind = "using", struct = "S", part = "reactorConsole" } } }
  local mem = {}
  m = ev(anyG, mem)
  check("gy3 any: neither (4 m off, not using it)", not m)
  using = true
  m, r = ev(anyG, mem)
  check("gy3 any: using the console from across the room", m and r == "at its terminal", r)
  using = false
  m, r = ev(anyG, mem)
  check("gy3 using: once used while the step is open it stays met", m, r)
  check("gy3 labels", SCN.goalLabel({ kind = "using", part = "reactorConsole" }) == "Use reactorConsole" and SCN.goalLabel(anyG) == "Reach c")
  -- playable and names
  local gs = SCN.load("graveyard_shift", true)
  local byName = {}
  for _, c in ipairs(gs.start.crew) do byName[c.name] = c end
  check("gy3 playable: the one you control", SCN.playableOf(gs, byName.Halloran))
  check("gy3 playable: Dana and Priya are not (cast, default false)", not SCN.playableOf(gs, byName.Kowalczyk) and not SCN.playableOf(gs, byName.Anand))
  local g2 = SCN.load("graveyard_shift", true)
  g2.cast.dana.playable = true
  check("gy3 playable: cast playable = true", SCN.playableOf(g2, byName.Kowalczyk))
  check("gy3 playable: start.crew playable wins", not SCN.playableOf(g2, { name = "Kowalczyk", playable = false }))
  check("gy3 names: the record wears the cast's name", SCN.crewDisplayName(gs, "Kowalczyk") == "Dana Kowalczyk" and SCN.crewDisplayName(gs, "Anand") == "Dr Priya Anand"
    and SCN.crewDisplayName(gs, "Halloran") == "Halloran" and SCN.crewDisplayName(gs, "Nobody") == "Nobody")
  local tk = SCN.load("thirty_km", true)
  local kk = SCN.castOfCrew(tk, "Nakamura")
  check("gy3 names: of three voices the one in person", kk == "kit", tostring(kk))
  -- validation
  g2.cast.dana.playable = "yes"
  g2.cast.ops.playable = true
  g2.steps[3].goals = { { kind = "any", goals = {} } }
  g2.steps[4].goals = { { kind = "using", struct = "Kerne Station" } }
  g2.sequences.q_bed[1] = { say = { who = "dana", text = "Bed.", look = "mark:nowhere" } }
  local okv, errs = SCN.validate(g2, CTX)
  local te = table.concat(errs or {}, "\n")
  for _, want in ipairs({ "cast.dana.playable", "cast.ops.playable", "steps[3].goals[1].goals", "steps[4].goals[1]", "q_bed[1].say.look" }) do
    check("gy3 validation names " .. want, not okv and te:find(want, 1, true) ~= nil, te:sub(1, 400))
  end
  -- Graveyard: she goes to bed when she says so; the console ticks on use
  local qe = false
  for _, b in ipairs(gs.sequences.q_end or {}) do if b.run == "dana_off" then qe = true end end
  check("gy3 Graveyard: the hand-over ends with Dana going to her bunk", qe)
  local cg = nil
  for _, s in ipairs(gs.steps) do if s.id == "console" then cg = s.goals[1] end end
  local hasUse = false
  for _, g in ipairs((cg and cg.goals) or {}) do if g.kind == "using" then hasUse = true end end
  check("gy3 Graveyard: the console step ticks on walking up to it OR using it", cg and cg.kind == "any" and hasUse)
  SCN.forget()
end

print(string.format("smoke_scenarios: %d checks, %d failed", count, failed))
os.exit(failed == 0 and 0 or 1)
