-- SMOKE HARNESS: THE CRAFT CHECK (scripts/craft_check.lua, builder.launchCheck)
-- — the VAB's warnings, read off the flight's own rules
-- (work/vabcheck/PLAN.md; docs/builder-design.md §7.2).
--
--   * every rule fires on the craft one change away from a good one, and is
--     quiet on the good one: jets with no / too little intake (A1), a plane
--     built standing up (A3), lift ahead of the mass (A4, wet and dry), no
--     pitch / roll control (A5), mains ahead of the mass or the nose gear
--     carrying 2 % (A6), jets with no fuel (A9), a stage whose engine has no
--     tank or whose tanks no engine (R7), the staging order (R8), a fairing
--     that doesn't cover its payload (R11, and FIT clears it), chutes too
--     small for what they land (R6), a probe with no antenna or power (C3),
--     a bike that can't climb (V2), a tall rover (V3), a wheel in the air (V9)
--   * NEVER A GUESS: the jets' air share and thrust the rows quote are
--     aero.step's at a standstill on the same records; the flight constants
--     craft_check mirrors equal vessel_controller.lua's (and base_facilities'
--     runway); its feedSec and r2Lateral are the flight's (same answers); its
--     tyres and steering plan give r2SteerPlan's track and CoM height; a
--     one-line integrator of v' = g − 1.3 n v² / m settles where R6 says; the
--     bike's climb equals asin(gasWheel torque / r / (m g))
--   * every row: a head of at most 60 characters, numbers formatted (no nan,
--     no inf), unique ids, sorted block → warn by rank → note
--   * perf: launchCheck on a 1,000-part craft under 4 ms (luajit)
--
--   luajit solar/tests/smoke_craft_check.lua

local failures, passes = {}, 0
local function check(ok, msg)
  if ok then passes = passes + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-6) end
local VERBOSE = os.getenv("VERBOSE")

local function envOf(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local c = assert(loadfile("solar/" .. path))
  setfenv(c, e); c(); e.valid = true
  return e
end
local A = envOf("scripts/aero.lua")
local CC = envOf("scripts/craft_check.lua")
local AD = envOf("scripts/auto_drive.lua")
local E = envOf("scripts/electronics.lua")
local REGENV = envOf("scripts/parts_registry.lua")
local PAERO = envOf("scripts/parts_aero.lua")
local PAUTO = envOf("scripts/parts_auto.lua")
local THERM = envOf("scripts/thermal.lua")
local PNUKE = envOf("scripts/parts_nuclear.lua")
local CRAFTS = assert(loadfile("solar/tests/fixtures/check/crafts.lua"))()

-- ── the flight, loaded in a stub world (for its constants and functions) ───
local stub = setmetatable({}, { __index = function() return function() end end, __call = function() return nil end })
local VC = setmetatable({}, { __index = function(_, k) local g = _G[k]; if g ~= nil then return g end return stub end })
do
  local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
  setfenv(chunk, VC)
  local ok, err = pcall(chunk)
  check(ok, "vessel_controller loads in a stub world: " .. tostring(err))
end
local function src(path) local f = assert(io.open("solar/" .. path)); local s = f:read("*a"); f:close(); return s end
local VSRC = src("scripts/vessel_controller.lua")

-- ── 1. the mirrored constants are the flight's ─────────────────────────────
do
  local F = CC.FLIGHT
  for _, k in ipairs({ "R2_TYRE_MU", "R2_GRIP_K", "R2_LAT_MU", "R2_LAT_SSF", "R2_G_REF", "CREW_T", "R2_LIFT_MAX" }) do
    check(rawget(VC, k) == F[k], string.format("FLIGHT.%s = %s, vessel_controller has %s", k, tostring(F[k]), tostring(rawget(VC, k))))
  end
  for _, sz in ipairs({ "S", "M", "L" }) do
    check(VC.R2_WHEEL_TORQUE[sz] == F.R2_WHEEL_TORQUE[sz], "R2_WHEEL_TORQUE." .. sz .. " mirrored")
    check(VC.R2_WHEEL_TOP[sz] == F.R2_WHEEL_TOP[sz], "R2_WHEEL_TOP." .. sz .. " mirrored")
  end
  check(VC.R2_BIKE.torque == F.R2_BIKE_TORQUE and VC.R2_BIKE.top == F.R2_BIKE_TOP, "R2_BIKE torque and top mirrored")
  check(VC.R2_BIKE.lean == F.R2_BIKE_LEAN and VC.R2_BIKE.leanMax == F.R2_BIKE_LEANMAX, "R2_BIKE lean and leanMax mirrored")
  -- the flight's locals, read from its source
  local tol = VSRC:match("local TOLERANCE = (%b{})")
  local T = assert(loadstring("return " .. tol))()
  for k, v in pairs(T) do check(F.TOLERANCE[k] == v, "TOLERANCE." .. k .. " mirrored") end
  for k in pairs(F.TOLERANCE) do check(T[k] ~= nil, "TOLERANCE." .. k .. " is the flight's") end
  check(tonumber(VSRC:match("local CHUTE_SAFE_KPA = ([%d%.]+)")) == F.CHUTE_SAFE_KPA, "CHUTE_SAFE_KPA mirrored")
  check(tonumber(VSRC:match("local drag_k = ([%d%.]+) %* #chutes %* chute_anim")) == F.CHUTE_K, "the canopy drag 1.3 · #chutes mirrored")
  local pt = VSRC:match("local function part_tolerance%(d%)(.-)\nend")
  check(pt and tonumber(pt:match('d%.wheel or ""%) ~= "" then return (%d+)')) == F.TOL_WHEEL, "part_tolerance: a wheel's")
  check(pt and tonumber(pt:match("d%.front or 0%) == 1 then return (%d+)")) == F.TOL_FRONT, "part_tolerance: a rover body's")
  local dep, up
  if pt then dep, up = pt:match("gear_deployed and (%d+) or (%d+)") end
  check(tonumber(dep) == F.TOL_LEGS and tonumber(up) == F.TOL_LEGS_UP, "part_tolerance: legs deployed and stowed")
  check(pt and tonumber(pt:match('TOLERANCE%[d%.kind or "structural"%] or (%d+)')) == F.TOL_OTHER, "part_tolerance: any other")
  check(tonumber(VSRC:match("local floor = tol %* ([%d%.]+)")) == F.DAMAGE_FLOOR, "damage floor 0.35 × tolerance mirrored")
  check(tonumber(VSRC:match("R2%.noseUp = an and math%.abs%(an%.y%) > ([%d%.]+)")) == F.NOSE_UP, "R2.noseUp's 0.7 mirrored")
  check(tonumber(VSRC:match('afHas%(d, "cockpit"%) or Y%[2%] < ([%d%.]+)')) == F.FRAME_TILT, "aeroScan's 0.866 mirrored")
  local tw = VSRC:match("local tyre_w = %((%b{})%)%[w%.size%]")
  local TW = assert(loadstring("return " .. tw))()
  for k, v in pairs(TW) do check(F.TYRE_W[k] == v, "tyre width " .. k .. " mirrored") end
  local BF = src("scripts/base_facilities.lua")
  local u0, u1 = BF:match("RUNWAY = {[^}]-u0 = (%-?[%d%.]+), u1 = (%-?[%d%.]+)")
  check(u0 and near(tonumber(u1) - tonumber(u0), F.RUNWAY_LEN), "the runway's length is base_facilities' RUNWAY")
  -- and the functions it shares
  local cuts = { 1.0, 2.5, 4.0 }
  local same = true
  for y = -1, 6, 0.137 do if CC.feedSec(y, cuts) ~= VC.feedSec(y, cuts) then same = false end end
  for _, y in ipairs({ 0.99, 1.0, 2.49, 2.5, 4.0 }) do if CC.feedSec(y, cuts) ~= VC.feedSec(y, cuts) then same = false end end
  check(same, "craft_check.feedSec is the flight's feedSec")
  local lsame = true
  for _, pl in ipairs({ { track = 1.1, hcg = 0.6 }, { track = 0.8, hcg = 1.4 }, { track = 2, hcg = 0.3 }, nil }) do
    for _, mu in ipairs({ 0.9, 1.35, 0.45 }) do
      if not near(CC.lateral(8.4, pl, mu), VC.r2Lateral(8.4, pl, mu), 1e-12) then lsame = false end
    end
  end
  check(lsame, "craft_check.lateral is the flight's r2Lateral")
  for _, d in ipairs({ { wheel = "M" }, { front = 1, kind = "probe" }, { legs = 1, kind = "structural" }, { kind = "engine" },
                       { kind = "tank" }, { kind = "crewed" }, { kind = "canvas" }, { kind = "weird" } }) do
    local mine = CC.tolerance({ wheel = d.wheel, front = d.front, legs = d.legs == 1 or nil, kind = d.kind })
    local theirs = (d.wheel and F.TOL_WHEEL) or (d.front and F.TOL_FRONT) or (d.legs and F.TOL_LEGS) or (T[d.kind] or F.TOL_OTHER)
    check(mine == theirs, "tolerance(" .. tostring(d.kind or d.wheel) .. ") = " .. tostring(mine))
  end
end

-- ── the builder harness ─────────────────────────────────────────────────────
local nodes = {}
local function make_node(name, x, y, z)
  local n = { id = #nodes + 1, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  nodes[#nodes + 1] = n
  return n
end
local store = {}
local T = 0
local API = {
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  destroy = function(n) n.valid = false end,
  find = function(name) for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end end,
  print = function() end, log = function(m) if VERBOSE then print("LOG " .. tostring(m)) end end,
  spawn = function(prefab, pos, cb) local n = make_node(prefab, pos.x, pos.y, pos.z) if cb then cb(n) end end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k)
    if k == "electronics" then return E end
    if k == "parts_registry" then return REGENV end
    if k == "parts_aero" then return PAERO end
    if k == "parts_auto" then return PAUTO end
    if k == "thermal" then return THERM end
    if k == "parts_nuclear" then return PNUKE end
    return nil
  end,
  findScripts = function() return {} end,
  input = { key = function() return false end, pressed = function() return false end, button = function() return false end,
            mouse = function() return 0, 0 end },
  camera = { worldToScreen = function() return 0, 0, 1, true end, screenSize = function() return 1280, 720 end,
             screenToRay = function() return 0, 10, 0, 0, -1, 0 end },
  mesh = { build = function() return "m" end, free = function() end },
  draw = stub, audio = stub, scene = { load = function() end }, raycast = function() return nil end,
}
make_node("BuildStats"); make_node("BuildHint")
-- the launch world: g 8.4 (the parachute comment's), air at the reference
store["launch.world"] = { name = "Testa", g = 8.4, r = 775, soi = 9600 }
store["world.Testa"] = { atmo = 0.75, atmoHeight = 270, radius = 775, geo = { home = true, type = "verdant" } }
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
do
  store["shipyard.blueprint"] = { parts = {} }
  local chunk = assert(loadfile("solar/scripts/builder.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
end
local REG = REGENV.REG
for id, d in pairs(PAERO.PARTS or {}) do if not REG[id] then REG[id] = d end end
for id, d in pairs(PNUKE.PARTS or {}) do if not REG[id] then REG[id] = d end end
local function load(bp, site)
  store["shipyard.blueprint"] = bp
  env.launchSiteChoice = site
  env.start(make_node("Builder"))
  for _ = 1, 4 do if env.spawnQueueTick then env.spawnQueueTick() end end
  return env.launchCheck()
end
local function byId(L, id)
  for _, r in ipairs(L.rows or {}) do if r.id == id then return r end end
  return nil
end
local function dump(name, L)
  if not VERBOSE then return end
  print("── " .. name .. (L.block and ("  BLOCK " .. L.block) or "") .. "  kind " .. tostring(L.kind))
  for _, r in ipairs(L.rows or {}) do
    print(string.format("  [%s %s r%d] %s  {%s}", r.id, r.sev, r.rank or 2, r.head, table.concat(r.uids or {}, ",")))
    if r.text then print("      " .. r.text) end
  end
end
-- every row: short head, real numbers, unique ids, sorted
local SEV = { block = 0, warn = 1, note = 2 }
local function wellFormed(name, L)
  local seen, ok, why = {}, true, ""
  local prev = nil
  for _, r in ipairs(L.rows or {}) do
    if seen[r.id] then ok, why = false, "duplicate id " .. r.id end
    seen[r.id] = true
    local txt = (r.head or "") .. " " .. (r.text or "")
    if txt:find("nan") or txt:find("inf") or txt:find("%-0%.00") then ok, why = false, r.id .. " has a bad number: " .. txt end
    if r.id:sub(1, 1) ~= "L" and r.id:sub(1, 1) ~= "H" and r.id ~= "B" and #r.head > 62 then
      ok, why = false, r.id .. " head too long (" .. #r.head .. "): " .. r.head
    end
    local key = { SEV[r.sev] or 1, r.rank or 2 }
    if prev and (key[1] < prev[1] or (key[1] == prev[1] and key[2] < prev[2])) then ok, why = false, "rows out of order at " .. r.id end
    prev = key
  end
  check(ok, name .. ": rows well formed — " .. why)
end

-- ── 2. the light jet, level: nothing to say about the aircraft ────────────
local jet = load(CRAFTS.lightjet())
dump("lightjet", jet)
wellFormed("lightjet", jet)
check(jet.kind == "aircraft", "the light jet flies as an aircraft: " .. tostring(jet.kind))
local c1 = byId(jet, "C1")
check(c1 and c1.head:find("AIRCRAFT") and c1.head:find("RUNWAY") and c1.sev == "note", "C1 says AIRCRAFT · RUNWAY")
for _, id in ipairs({ "A1", "A1f", "A3", "A4", "A4d", "A5p", "A5r", "A6", "A6m", "A6n", "A6l", "A9", "A2", "C1w" }) do
  check(byId(jet, id) == nil, "the light jet has no " .. id .. " row" .. (byId(jet, id) and (": " .. byId(jet, id).head) or ""))
end
check(jet.check and near(jet.check.airf, 1.0), "A1: the light jet's two intakes give the Wasp all its air (0.12 / 0.12)")

-- the "never a guess" cross-check: aero.step on the very records the builder hands the rule
local function step_air(L)
  local ctx = env.checkContext()
  local recs = {}
  for u, p in pairs(ctx.parts) do
    recs[#recs + 1] = { uid = u, id = p.id, def = p.def, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll }
  end
  local M = A.build(recs)
  A.step(M, { rho = A.RHO0 * ctx.sigma, a = 85, o2 = 1, throttle = 1, dt = 100 })
  local T0 = 0
  for _, j in ipairs(M.jets) do T0 = T0 + ctx.parts[j.uid].def.thrust * j.jk end
  return M.diag.air, T0, ctx
end

-- ── 3. A1: the intakes ──────────────────────────────────────────────────────
do
  local L = load(CRAFTS.lightjet({ intakes = 0 }))
  dump("no intakes", L)
  wellFormed("no intakes", L)
  local r = byId(L, "A1")
  check(r and r.sev == "warn" and r.rank == 0 and r.head:find("no intake"), "A1: no intake → it will not light (rank 0)")
  local air, T0 = step_air(L)
  check(air == 0 and T0 == 0, "…aero.step agrees: 0 air, 0 kN")
  local jets = {}
  for u, p in pairs(env.checkContext().parts) do if p.id == "jet" then jets[#jets + 1] = u end end
  check(r and #r.uids == 1 and r.uids[1] == jets[1], "…its uids are the jet")
  check(r and r.fix and r.fix.hold == "intake" and r.fix.label == "ADD INTAKE", "…and its fix puts a Ram Intake in the hand")
  check(L.warn[1] == r.head or (L.rows[1].rank == 0), "…and it is among the worst lines LAUNCH asks about")

  local L1 = load(CRAFTS.lightjet({ intakes = 1 }))
  dump("one intake", L1)
  local r1 = byId(L1, "A1")
  local air1, T01, ctx1 = step_air(L1)
  local Tj = 0
  for _, p in pairs(ctx1.parts) do if p.id == "jet" then Tj = p.def.thrust end end
  check(r1 and r1.rank == 2 and r1.head:find("0%.12 m² of intake, have 0%.06: 50 %% thrust"), "A1: one intake → 0.06 of 0.12 m², 50 % thrust: " .. tostring(r1 and r1.head))
  check(near(air1, 0.5, 1e-9) and near(L1.check.airf, air1, 1e-12), string.format("…the share quoted (%.3f) is aero.step's M.diag.air (%.3f)", L1.check.airf or -1, air1))
  check(near(L1.check.jetT0, T01, 1e-9) and r1 and r1.text:find(string.format("%.1f of %.1f kN", T01, Tj), 1, true),
    string.format("…and the kN it quotes are Σ jk·thrust off aero.step (%.1f of %.1f)", T01, Tj))
  check(r1 and r1.text:find("Add 1 more Ram Intake%."), "…and it asks for one more Ram Intake")
end

-- ── 4. A3: built standing up ────────────────────────────────────────────────
do
  local L = load(CRAFTS.lightjet({ upright = true }), "runway")
  dump("upright", L)
  wellFormed("upright", L)
  local r = byId(L, "A3")
  check(r and r.rank == 1 and r.head == "Built standing up: the gear can't spring or steer", "A3: the jet built standing up warns (rank 1)")
  -- the flight's test on the same frame: R2.noseUp = |an.y| > 0.7 (an = the cockpit's +Y, aeroScan)
  local ctx = env.checkContext()
  local ck
  for u, p in pairs(ctx.parts) do if p.id == "cockpit" then ck = p end end
  local _, Y = A.axes(ck.yaw, ck.pitch, ck.roll)
  check(math.abs(Y.y) > 0.7, string.format("…the cockpit's +Y is %.2f up: the flight's R2.noseUp", Y.y))
  local n = 0
  for _, u in ipairs(r and r.uids or {}) do
    local id = ctx.parts[u].id
    if id == "cockpit" or id:find("^gear") then n = n + 1 end
  end
  check(r and n == 4 and #r.uids == 4, "…its uids are the cockpit and the 3 gear")
  check(byId(L, "A6m") == nil and byId(L, "A6n") == nil and byId(L, "A7") == nil, "…and the level-gear checks stand aside")
  local Lp = load(CRAFTS.lightjet({ upright = true }), "pad")
  check(byId(Lp, "A3n") and byId(Lp, "A3n").sev == "note", "…on the pad it is also a spaceplane note")
end

-- ── 5. A4: the centre of lift ───────────────────────────────────────────────
do
  local L = load(CRAFTS.lightjet({ wingdx = 1.6 }))
  dump("wings forward", L)
  wellFormed("wings forward", L)
  local r = byId(L, "A4")
  local ctx = env.checkContext()
  local recs = {}
  for u, p in pairs(ctx.parts) do recs[#recs + 1] = { uid = u, id = p.id, def = p.def, x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll } end
  for u, t in pairs(ctx.crew) do local p = ctx.parts[u]; recs[#recs + 1] = { uid = -u, def = { mass = t }, x = p.x, y = p.y, z = p.z } end
  local d, mac = A.staticMargin(recs)
  check(r and r.rank == 1 and mac and mac <= 0, string.format("A4: wings 1.6 m forward → lift ahead of the mass (margin %.2f MAC)", mac or 99))
  check(r and r.head:find(string.format("%.2f m ahead", -d), 1, true), "…the metres quoted are aero.staticMargin's: " .. tostring(r and r.head))
  local ok_margin = load(CRAFTS.lightjet())
  check(ok_margin.check.margin and ok_margin.check.margin > 0.03, string.format("the light jet's own margin is stable (%.2f MAC)", ok_margin.check.margin or -1))
end

-- ── 6. A5: control surfaces ─────────────────────────────────────────────────
do
  local L = load(CRAFTS.lightjet({ elevons = false }))
  dump("no elevons", L)
  wellFormed("no elevons", L)
  check(byId(L, "A5p") and byId(L, "A5p").rank == 1 and byId(L, "A5p").text:find("0%.12 kN·m of reaction wheel"),
    "A5: no elevons → no pitch control, only the cockpit's 0.12 kN·m reaction wheel (rank 1)")
  check(byId(L, "A5r") and byId(L, "A5r").rank == 1, "…and no roll control (rank 1)")
  check(byId(L, "A5y") == nil, "…the tail fin still yaws it")
end

-- ── 7. A6: the gear ─────────────────────────────────────────────────────────
do
  local L = load(CRAFTS.lightjet({ maindx = 0.5 }))
  dump("mains forward", L)
  wellFormed("mains forward", L)
  local r = byId(L, "A6m")
  check(r and r.rank == 1 and r.head:find("sits on its tail"), "A6: mains ahead of the CoM → sits on its tail")
  -- the mains moved until the nose gear carries 2 % (statics: k = (cx − main) / (nose − main))
  local function nose_share(dx)
    load(CRAFTS.lightjet({ maindx = dx }))
    local ctx = env.checkContext()
    local m, cx = 0, 0
    for u, p in pairs(ctx.parts) do
      local dm = math.max(0.001, p.def.mass) + (p.def.fuel or 0) * 0.01 + (ctx.crew[u] or 0)
      m, cx = m + dm, cx + p.x * dm
    end
    cx = cx / m
    local mainx, nosex = 0, 0
    for _, p in pairs(ctx.parts) do
      if p.id == "gearM" then mainx = p.x end
      if p.id == "gearS" then nosex = p.x end
    end
    return (cx - mainx) / (nosex - mainx), cx, mainx, nosex
  end
  local dx = 0
  for _ = 1, 6 do
    local k, cx, mx, nx = nose_share(dx)
    local want = (cx - 0.02 * nx) / 0.98
    dx = dx + (want - mx)
  end
  local k2 = nose_share(dx)
  local L2 = env.launchCheck()
  dump("mains 2 %", L2)
  local r2 = byId(L2, "A6n")
  check(near(k2, 0.02, 1e-4) and r2 and r2.rank == 1 and r2.head:find("carries 2 %%"),
    string.format("A6: the nose gear carrying %.1f %% → ground-loops: %s", k2 * 100, tostring(r2 and r2.head)))
  local r3 = load(CRAFTS.lightjet())
  check(byId(r3, "A6n") == nil, "…the light jet's own gear carries its nose fairly")
end

-- ── 8. A9: jets with nothing to burn (the fuselage tank emptied) ───────────
do
  load(CRAFTS.lightjet())
  local ctx = env.checkContext()
  for u, p in pairs(ctx.parts) do
    if p.id == "fuseTank" then p.def = setmetatable({ fuel = 0 }, { __index = p.def }) end
  end
  local res = CC.run(ctx)
  local hit
  for _, r in ipairs(res.rows) do if r.id == "A9" then hit = r end end
  check(hit and hit.rank == 0 and #hit.uids == 1, "A9: a jet with no fuel in its section (feedSec) warns")
end

-- ── 9. R6: chutes ───────────────────────────────────────────────────────────
do
  check(near(CC.chuteSpeed(3.6, 8.4, 1), 4.8, 0.05), string.format("R6: the flight's own figure: 3.6 t on g 8.4 under one chute comes down at %.2f m/s (4.8 measured)", CC.chuteSpeed(3.6, 8.4, 1)))
  check(near(CC.chuteSpeed(3.6, 4.9, 1), 3.7, 0.05), "…and 3.7 m/s on Bryolru (g 4.9)")
  local L = load(CRAFTS.starter(REG))
  dump("starter", L)
  wellFormed("starter", L)
  local r = byId(L, "R6n")
  check(r and r.sev == "note", "the starter lands softly: a note, not a warning")
  local m = REG.pod.mass + REG.chute.mass + REG.tankS.mass + REG.engineS.mass + CC.FLIGHT.CREW_T
  check(r and near(L.check.chute_v, math.sqrt(m * 8.4 / 1.3), 1e-9), string.format("…at √(m g / 1.3 n) for its %.2f t dry (%.2f m/s)", m, L.check.chute_v or -1))
  -- the flight's drag, integrated: v' = g − 1.3 n v² / m settles where R6 says
  local v, dt = 0, 0.002
  for _ = 1, 20000 do v = v + (8.4 - 1.3 * 1 * v * v / m) * dt end
  check(near(v, L.check.chute_v, 0.01 * L.check.chute_v), string.format("…an integrator of the flight's canopy drag settles at %.3f m/s", v))
  -- two tanks and no engine: the tank touches first and breaks at 3.5
  local L2 = load(CRAFTS.starter(REG, { engine = false, tanks = { "tankM", "tankM" } }))
  dump("heavy tanks", L2)
  local r2 = byId(L2, "R6")
  check(r2 and r2.rank == 0 and r2.head:find("FT%-M Tank breaks at 3%.5"), "R6: a stack landing on a tank at 3.8 m/s breaks it (3.5): " .. tostring(r2 and r2.head))
  check(r2 and r2.fix and r2.fix.hold == "chute", "…its fix is a chute in the hand")
  local L3 = load(CRAFTS.starter(REG, { engine = false, tanks = { "tankM", "tankM" }, chutes = 2 }))
  dump("heavy tanks, 2 chutes", L3)
  check(byId(L3, "R6") == nil and byId(L3, "R6n"), "…two chutes bring it under: a note again")
  check(near(L3.check.chute_v, math.sqrt((REG.pod.mass + 2 * REG.chute.mass + 2 * REG.tankM.mass + 0.1) * 8.4 / (1.3 * 2)), 1e-9), "…at √(m g / (1.3 · 2))")
end

-- ── 10. R7 / R8: stages ─────────────────────────────────────────────────────
do
  local L = load(CRAFTS.twostage(REG))
  dump("twostage", L)
  wellFormed("twostage", L)
  check(byId(L, "R7e0") == nil and byId(L, "R7e1") == nil and byId(L, "R7t1") == nil and byId(L, "R8o") == nil, "a good two-stage rocket: no stage rows")
  local Ln = load(CRAFTS.twostage(REG, { upper = { "tankS" } }))
  dump("upper no engine", Ln)
  local rt = nil
  for _, r in ipairs(Ln.rows) do if r.id:find("^R7t") then rt = r end end
  check(rt == nil, "an upper stage of tank + probe (the top section) is not dead weight to the check")
  local Ln2 = load(CRAFTS.twostage(REG, { upper = { "tankS", "decoupler", "tankS" } }))
  dump("middle no engine", Ln2)
  local rt2 = nil
  for _, r in ipairs(Ln2.rows) do if r.id:find("^R7t") then rt2 = r end end
  check(rt2 and rt2.rank == 2 and rt2.head:find("no engine"), "R7: a middle stage of fuel and no engine is dead weight (rank 2)")
  local Le = load(CRAFTS.twostage(REG, { upper = { "engineS" } }))
  dump("upper no tank", Le)
  local re = nil
  for _, r in ipairs(Le.rows) do if r.id:find("^R7e") then re = r end end
  check(re and re.rank == 0 and re.head:find("no tank"), "R7: an upper engine with no tank in its section never burns (rank 0)")
  -- R8: the stack reversed (the upper decoupler... here the engine lit before) — the decoupler moved under its engine
  local bp = CRAFTS.twostage(REG, { upper = { "engineS", "tankS", "decoupler", "engineS", "tankS" } })
  load(bp)
  local v = env.stageView()
  -- fire the UPPER decoupler first: swap the two decoupler stages
  local dstages = {}
  for n, sg in ipairs(v.stages) do for _, e in ipairs(sg.items) do if e.kind == "axial" then dstages[#dstages + 1] = n end end end
  if #dstages >= 2 then env.cmd("stage", { op = "swap", i = dstages[1], j = dstages[2] }) end
  local Lo = env.launchCheck()
  dump("swapped", Lo)
  local ro = byId(Lo, "R8o") or byId(Lo, "R8e")
  check(ro and ro.fix and ro.fix.label == "DEFAULT ORDER", "R8: decouplers fired top-down warn, with DEFAULT ORDER: " .. tostring(ro and ro.head))
  if ro then env.checkFix(ro.id) end
  local Lf = env.launchCheck()
  check(byId(Lf, "R8o") == nil and byId(Lf, "R8e") == nil, "…and DEFAULT ORDER clears it")
end

-- ── 11. R11: the fairing ────────────────────────────────────────────────────
do
  local bp = CRAFTS.faired(REG)
  load(bp)
  check(byId(env.launchCheck(), "R11." .. bp.base) == nil, "a fitted fairing covers its payload")
  env.cmd("fairing", { uid = bp.base, op = "handles", hp = { rb = 0.66, rs = 0.7, hs = 0.15, rt = 0.55, ht = 0.6, hn = 0.4, open = false } })
  local L = env.launchCheck()
  dump("squat fairing", L)
  wellFormed("squat fairing", L)
  local r = byId(L, "R11." .. bp.base)
  check(r and r.rank == 2 and r.head:find("stick") and r.fix and r.fix.label == "FIT", "R11: a squat shell → parts stick out, FIT")
  check(r and #r.uids == env.fairingFit(bp.base).nout, "…its uids are what sticks out (fairingFit.out)")
  if r then env.checkFix(r.id) end
  check(byId(env.launchCheck(), "R11." .. bp.base) == nil, "…and FIT clears it")
end

-- ── 12. C3: probes ──────────────────────────────────────────────────────────
do
  local L = load(CRAFTS.probe(REG))
  dump("probe", L)
  check(byId(L, "C3a") == nil and byId(L, "C3p") == nil, "a probe core with its own radio and battery: no C3")
  load(CRAFTS.probe(REG))
  local ctx = env.checkContext()
  ctx.power = function() return { probe = 1, crew = 0, antenna = { any = 0 }, store = 0, solar = 0, rtg = 0, idle = 0.06 } end
  local res = CC.run(ctx)
  local a, p
  for _, r in ipairs(res.rows) do if r.id == "C3a" then a = r elseif r.id == "C3p" then p = r end end
  check(a and a.rank == 0 and p and p.rank == 0, "C3: no antenna and no power → the probe can't be flown (rank 0)")
end

-- ── 13. V2: the bikes climb (the flight's push) ─────────────────────────────
local function bike(name)
  local L = load(assert(loadfile("solar/tests/fixtures/check/" .. name .. ".lua"))())
  dump(name, L)
  wellFormed(name, L)
  return L
end
do
  local L = bike("bike125")
  check(L.kind == "rover", "the 125 rides as a rover (Auto): " .. tostring(L.kind))
  local r = byId(L, "V2") or byId(L, "V2n")
  check(r ~= nil, "V2: the 125's climb is read")
  -- cross-check: asin(gasWheel(first gear).torque · rating / r / (m g))
  local ctx = env.checkContext()
  local ch
  for _, c in pairs(ctx.chains) do ch = c end
  local rw = nil
  for u, p in pairs(ctx.parts) do if u == (function() for w in pairs(ctx.chains) do return w end end)() then rw = p end end
  local dm = E.modOf(ctx.rec(rw.uid), "drive")
  local q = AD.gasWheel(ch.mod, 0, dm.r, ch.teeth, 1)
  local m = 0
  for u, p in pairs(ctx.parts) do m = m + math.max(0.001, p.def.mass or 0.1) + (p.def.fuel or 0) * 0.01 + (ctx.crew[u] or 0) end
  local th = math.deg(math.asin(math.min(1, q.torque * ctx.rk / dm.r / (m * 8.4))))
  local quoted = tonumber((r and r.head or ""):match("(%d+)°"))
  check(quoted and math.abs(quoted - th) < 0.51, string.format("…the 125 climbs %s° = asin(gasWheel torque / r / m g) = %.1f°", tostring(quoted), th))
  if th < 30 then
    check(r.id == "V2" and r.rank == 1, "…under 30°: a warning (rank 1)")
    check(r.text:find("sprocket") or r.text:find("climbs"), "…naming a sprocket or a bigger engine")
  end
  local L5 = bike("bike500")
  local r5 = byId(L5, "V2") or byId(L5, "V2n")
  check(r5 and r5.id == "V2n", "the 500 clears 30°: " .. tostring(r5 and r5.head))
  -- a bike's front lifts before it tips (drive_tick's bike block): the
  -- climb where h sin θ − k a cos θ = k lean, k R2_LIFT_MAX (the 500 of
  -- 2026-11-05: a 0.74 m, h 1.17 m, the rider's 0.2 m reach: 37°)
  local kL = CC.FLIGHT.R2_LIFT_MAX
  local thl, whyl = CC.climbLimits(99, 1, 9, { back = 0.74, lean = 0.2 }, 1.17)
  check(whyl == "lift" and math.abs(1.17 * math.sin(thl) - kL * 0.74 * math.cos(thl) - kL * 0.2) < 1e-9,
    string.format("V2 lift: h sin θ − k a cos θ = k lean (%s, %.1f°)", tostring(whyl), math.deg(thl)))
  check(math.deg(thl) > 34 and math.deg(thl) < 40, string.format("…the tall 500 reaches %.1f° on its lean (34-40°)", math.deg(thl)))
  local tht, whyt = CC.climbLimits(99, 1, 9, { back = 0.74 }, 1.17)
  check(whyt == "tip" and math.abs(math.deg(tht) - math.deg(math.atan(0.74 / 1.17))) < 1e-6, "…a rover (no lean) still tips at atan(a / h)")
  local thg, whyg = CC.climbLimits(99, 1, 0.5, { all = true, back = 0.74, lean = 0.2 }, 1.17)
  check(whyg == "grip" and math.abs(thg - math.atan(0.5)) < 1e-9, "…and the least of the limits wins (grip, mu 0.5)")
  local q5 = tonumber((r5 and r5.head or ""):match("(%d+)°"))
  check(q5 and q5 <= 45, "the 500's climb is held to its front's lift: " .. tostring(r5 and r5.head))
  local Le = bike("bike_elec")
  check(byId(Le, "V2") or byId(Le, "V2n"), "the electric bike's climb is read")
end

-- ── 14. V3 / V9: rovers ─────────────────────────────────────────────────────
do
  local L = load(CRAFTS.rover(REG))
  dump("rover", L)
  wellFormed("rover", L)
  check(byId(L, "V3") == nil and byId(L, "V9") == nil, "a low rover on a 1.1 m track: no V3, no V9")
  local Lt = load(CRAFTS.rover(REG, { mast = 3, track = 0.8 }))
  dump("tall rover", Lt)
  local r = byId(Lt, "V3")
  check(r and r.rank == 1, "V3: three batteries stacked on a 0.8 m track → tips easily")
  -- the flight's r2SteerPlan on the same tyres: track and CoM height
  local ctx = env.checkContext()
  local ws = CC.tyres(ctx)
  local plan = CC.steerPlan(ctx, ws)
  local bp = {}
  for u, p in pairs(ctx.parts) do bp[u] = { x = p.x, y = p.y, z = p.z, mass = p.def.mass } end
  VC.CREW_TU = ctx.crew
  local vw = {}
  for _, w in ipairs(ws) do vw[#vw + 1] = { cx = w.cx, cy = w.cy, cz = w.cz, r = w.r, d = {}, cfg = { steer = "auto", steerMax = 25 } } end
  local vplan = VC.r2SteerPlan(vw, ctx.front, bp)
  check(near(plan.track, vplan.track, 1e-9) and near(plan.hcg, vplan.hcg, 1e-9),
    string.format("…its track %.3f and CoM height %.3f are r2SteerPlan's (%.3f, %.3f)", plan.track, plan.hcg, vplan.track, vplan.hcg))
  check(r and r.head:find(string.format("%.2f m up on a %.2f m track", vplan.hcg, vplan.track), 1, true), "…and the head quotes them")
end

-- ── 15. the UI plumbing: highlight, select, fix ────────────────────────────
do
  local L = load(CRAFTS.lightjet({ intakes = 0 }))
  local r = byId(L, "A1")
  env.checkHighlight(r.uids, "danger")
  check(env.checkSelect("A1") and #env.selection() == 1, "clicking a row selects its parts")
  check(env.checkFix("A1") and env.holding() == "part" and env.heldId() == "intake", "ADD INTAKE puts a Ram Intake in the hand")
  -- phase 4's hook: a rule from another script lands among the rows
  env.checkHook("probe_rule", function(ctx, out) out[#out + 1] = { id = "Z1", sev = "warn", rank = 2, head = "a hooked rule", uids = {} } end)
  env.craftVersion = env.craftVersion + 1
  check(byId(env.launchCheck(), "Z1"), "checkHook adds a rule's rows (phase 4: crew roles, heat)")
  env.checkHook("probe_rule", nil)
  env.craftVersion = env.craftVersion + 1
  check(byId(env.launchCheck(), "Z1") == nil, "…and nil takes it away")
end

-- ── 15b. phase 4: heat, the radiation cone, rods (thermal.lua), crew roles ─
do
  check(tonumber(src("scripts/vessel_thermal.lua"):match("local ROD_SECS = ([%d%.]+)")) == CC.FLIGHT.ROD_SECS, "ROD_SECS mirrored from vessel_thermal")
  local L = load(CRAFTS.nuclear(REG))
  dump("nuclear", L)
  wellFormed("nuclear", L)
  local tb = env.thermalBudget()
  local h1 = byId(L, "H1")
  check(tb and h1 and h1.head:find(string.format("settles at %d %%%%", math.floor(tb.eq * 100 + 0.5))),
    "H1: an Ember with no radiator settles over the scram line, at thermal.settle's figure: " .. tostring(h1 and h1.head))
  check(h1 and h1.rank == 0 and tb.eq >= THERM.THERMAL.damage, "…past 100 %: the hot parts cook (rank 0)")
  local need = tb.Q / THERM.THERMAL.scram - tb.S
  local each = THERM.radiatorSink({ type = "radiator", sink = 5, draw = 0.05 }, 1, 1, 1, 1)
  local n = math.ceil(need / each - 1e-9)
  check(h1 and h1.text:find(string.format("%d Radiator Panel", n), 1, true) and h1.fix and h1.fix.hold == "radPanel",
    string.format("…it asks for %.1f hu: %d Radiator Panels at %.2f hu in sunlight, ADD RADIATOR", need, n, each))
  local Lr = load(CRAFTS.nuclear(REG, { panels = n }))
  dump("nuclear + panels", Lr)
  check(byId(Lr, "H1") == nil and byId(Lr, "H1n") and env.thermalBudget().eq < THERM.THERMAL.scram,
    string.format("…and %d panels bring it under the line (%.0f %%)", n, env.thermalBudget().eq * 100))
  local h2 = byId(L, "H2")
  check(h2 and h2.rank == 0 and h2.fix and h2.fix.hold == "shadowShield", "H2: the pod in the core's cone, unshielded: a lethal dose (rank 0), ADD SHIELD")
  local seat
  for _, s in ipairs(tb.seats) do if s.inside then seat = s end end
  local hrs = seat and 1 / (seat.rate * 3600)
  check(seat and h2 and h2.head:find(hrs >= 1 and string.format("%.1f h", hrs) or string.format("%.0f min", hrs * 60), 1, true),
    "…in the time thermal.doseRate gives: " .. tostring(h2 and h2.head))
  local Ls = load(CRAFTS.nuclear(REG, { shield = true }))
  dump("nuclear + shield", Ls)
  check(byId(Ls, "H2") == nil, "…a Shadow Shield between them clears it")
  check(byId(L, "H3") and byId(L, "H3").head:find("No fuel rods"), "H3: no rods in the base store: it rolls out cold")
  store["game.mode"] = "sandbox"
  env.craftVersion = env.craftVersion + 1
  check(byId(env.launchCheck(), "H3") == nil, "…a sandbox has its rods")
  store["game.mode"] = nil
  -- crew roles: a reactor and nobody who swaps rods fast
  local ctx = env.checkContext()
  ctx.seated = function() return { { id = 1, uid = 1, role = "pilot", roleName = "Pilot", level = 1, name = "Val" } } end
  local res = CC.run(ctx)
  local c4, c4e
  for _, r in ipairs(res.rows) do if r.id == "C4" then c4 = r elseif r.id == "C4e" then c4e = r end end
  check(c4 and c4.text:find("Val %(Pilot L1%)") and c4e and c4e.text:find("8 s") and c4e.text:find("in 4"), "C4: the crew and their roles; no Engineer for the rods (8 s, 4 for one)")
  ctx.seated = function() return { { id = 2, uid = 1, role = "engineer", roleName = "Engineer", level = 2, name = "Bob" } } end
  res = CC.run(ctx)
  local e2 = false
  for _, r in ipairs(res.rows) do if r.id == "C4e" then e2 = true end end
  check(not e2, "…an Engineer aboard: nothing to say")
end

-- ── 16. perf: 1,000 parts, on an edit ──────────────────────────────────────
do
  -- (the best of five batches: the machine is shared, and a batch that met
  -- another process's burst says nothing about this code)
  local function per_edit(f, K)
    local best = math.huge
    for _ = 1, 5 do
      local t0 = os.clock()
      for _ = 1, K do env.craftVersion = env.craftVersion + 1; f() end
      best = math.min(best, (os.clock() - t0) * 1000 / K)
    end
    return best
  end
  local out = {}
  for _, c in ipairs({ { "lattice", CRAFTS.lattice(REG, 1000) }, { "jet + 985 hubs", CRAFTS.lightjet({ hubs = 985 }) } }) do
    load(c[2])
    local n = 0
    for _ in pairs(env.checkContext().parts) do n = n + 1 end
    per_edit(env.checkRun, 2)                       -- (warm)
    local chk = per_edit(env.checkRun, 10)
    local all = per_edit(env.launchCheck, 10)
    local real = env.checkRun
    env.checkRun = function() return nil end        -- the launch check as it was
    local old = per_edit(env.launchCheck, 10)
    env.checkRun = real
    local t1 = os.clock()
    for _ = 1, 50 do env.checkRun() end
    local cached = (os.clock() - t1) * 1000 / 50
    check(n >= 1000, c[1] .. ": 1,000 parts (" .. n .. ")")
    check(chk < 4.0, string.format("%s: the craft check costs %.2f ms an edit (< 4)", c[1], chk))
    check(cached < 0.25, string.format("%s: %.3f ms from its cache (nothing per frame)", c[1], cached))
    out[#out + 1] = string.format("%s: craft check %.2f ms · launchCheck %.2f ms (was %.2f) · cached %.3f ms", c[1], chk, all, old, cached)
  end
  print("  perf at 1,000 parts, per edit: " .. table.concat(out, "  |  "))
end

if #failures > 0 then
  print("CRAFT CHECK SMOKE FAILED (" .. #failures .. "):")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("CRAFT CHECK SMOKE OK — %d checks", passes))
