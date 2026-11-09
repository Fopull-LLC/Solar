-- SMOKE: RUNS (expansion X3; scripts/routes.lua pure, scripts/route_ops.lua
-- and the hooks against stubs). Ty's rules (plan §14) are the spec:
--
--   * THE LEDGER: a hold's load knows its source through the crew's packs (a
--     crate → pack → hold load is the crate's; ore dug into the pack is
--     "hand"); an unload knows where it went (hold → base, hold → pack →
--     crate); real inventory.lua, its new move ring;
--   * fromLog: a hand-written log with two stops → the phases (dwell, legs,
--     stops), the manifest, the fuel a cycle, the surplus to the Intake;
--   * EVERY REFUSAL says why: not back yet, another stand, parts lost, no
--     stop, the log full, a probe run's hand-dug load, an off-world refuel,
--     a crewed run off the home world, cargo left in the hold away from the
--     Intake, nothing delivered, cargo taken out by hand; check(): no Pilot,
--     the member you play, a store gone;
--   * THE SCHEDULE: no failure roll anywhere; 30 days in one advance equals
--     2,592,000 one-second calls exactly (cycles, phase, clock, every store,
--     what was moved, the RP); a store short → WAITING with the numbers,
--     refilled → on again; pause keeps the time left; poseAt walks the path
--     (body-relative); NEXT events;
--   * THE SCENE HALF: a flight recorded through the hooks (commission,
--     release, a stop, a crate load through the pack, return) is judged
--     automatable and Automate makes a run that unloads at the Intake: the
--     RP equal research.study's for the same lot (material_intake's path);
--     the stand's rows (Automate enabled, or the why); the crew go busy;
--   * THE RESPAWN CLOCK FIX: flight_ops carries a record by the agency
--     clock (`at`), not space.time() across a reload;
--   * THE STATION: a run is a RUNS entry with its situation line.
--
--   luajit solar/tests/smoke_routes.lua

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

-- an in-memory save
local STORE = {}
local function deep(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deep(v) end return o end
local SAVE = { get = function(k) return deep(STORE[k]) end, set = function(k, v) STORE[k] = deep(v) end,
               delete = function(k) STORE[k] = nil end }
-- a JSON stand-in (route_ops keeps runs as strings): a Lua literal
local function ser(v)
  local t = type(v)
  if t == "table" then
    local p = {}
    for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
    return "{" .. table.concat(p, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  else return tostring(v) end
end
local JSON = { encode = function(t) return ser(t) end,
               decode = function(s) local f = loadstring("return " .. s); return f and f() or nil end }

local RT = loadlib("routes.lua")

-- ── THE LEDGER (real inventory.lua, its move ring) ─────────────────────────
local INV = loadlib("inventory.lua", { save = SAVE, log = function() end, time = 0,
  findScript = function() return nil end, findScripts = function() return {} end })
INV.params = INV.defaults
do
  INV.setCap("hold:Mule", 500)
  INV.add("crate:1", "iron", 100)
  local s0 = INV.moveSeq
  INV.transfer("crate:1", "crew:1", "iron", 30)     -- from the crate into the pack
  INV.add("crew:1", "iron", 8)                       -- dug by hand (no move)
  INV.transfer("crew:1", "hold:Mule", "iron", 38)   -- all of it into the hold
  INV.transfer("hold:Mule", "base", "iron", 10)     -- the depot's crane
  INV.transfer("hold:Mule", "crew:1", "iron", 5)    -- out by hand…
  INV.transfer("crew:1", "crate:2", "iron", 5)      -- …into another crate
  local mv = INV.movesSince(s0)
  check("the move ring: five moves, in order", #mv == 5 and mv[1].from == "crate:1" and mv[5].to == "crate:2", #mv)
  local got = {}
  local led = {}
  for _, m in ipairs(mv) do
    RT.ledger(led, m, function(c) return c == "hold:Mule" end, function(c) return c:sub(1, 5) == "crew:" end,
      function(mat, n, peer) got[#got + 1] = string.format("%+d %s %s", n, mat, peer) end)
  end
  check("a load through the pack is the crate's, the rest by hand", got[1] == "+30 iron crate:1" and got[2] == "+8 iron hand",
    table.concat(got, " | "))
  check("the crane's unload into the warehouse", got[3] == "-10 iron base", got[3])
  check("out by hand and into a crate: an unload into the crate", got[4] == "-5 iron crate:2" and #got == 4, got[4])
  local s1 = INV.moveSeq
  for _ = 1, 300 do INV.transfer("crate:1", "crew:2", "iron", 0) end
  check("an empty transfer moves nothing and notes nothing", INV.moveSeq == s1)
end

-- ── A HAND-WRITTEN LOG ──────────────────────────────────────────────────────
local function log2(over)
  local L = RT.newLog({ sid = 7, uid = 1, body = "Home", name = "Mule", n = 7, fuel = 400, hold = {}, t = 0, home = true,
    intake = true, stand = { body = "Home", x = 1000, y = 0, z = 0 } })
  L.tDep = 100
  RT.addPath(L, { body = "Home", x = 1000, y = 0, z = 0, t = 100 })
  RT.addPath(L, { body = "Home", x = 1000, y = 200, z = 0, t = 150 })
  RT.addStop(L, { body = "Home", x = 1000, y = 400, z = 0, t = 200, fuel = 380, home = true })
  L.stops[1].tL, L.stops[1].fuelL = 260, 380
  RT.addXfer(L, 1, "iron", 20, "crate:1")
  RT.addStop(L, { body = "Home", x = 1200, y = 400, z = 0, t = 320, fuel = 360, home = true })
  L.stops[2].tL, L.stops[2].fuelL = 350, 360
  RT.addXfer(L, 2, "iron", -5, "crate:2")
  L.ended = { t = 500, fuel = 330, n = 7, cmd = true, hold = { iron = 15 }, sid = 7, uid = 1 }
  for k, v in pairs(over or {}) do L[k] = v end
  return L
end
local run, why = RT.fromLog(log2())
check("a closed log becomes a run", run ~= nil, why)
if run then
  local kinds = {}
  for _, p in ipairs(run.phases) do kinds[#kinds + 1] = p.k end
  check("dwell, leg, stop, leg, stop, leg", table.concat(kinds, ",") == "dwell,leg,stop,leg,stop,leg", table.concat(kinds, ","))
  check("the durations as flown (+ the 120 s dwell)", run.phases[2].dur == 100 and run.phases[3].dur == 60 and run.phases[4].dur == 60
    and run.phases[5].dur == 30 and run.phases[6].dur == 150 and run.dur == 520, run.dur)
  check("fuel a cycle: what it burned (400 → 330)", near(run.fuel, 70), run.fuel)
  check("stop 1 loads 20 iron from crate 1", run.acts[3][1].op == "load" and run.acts[3][1].n == 20 and run.acts[3][1].src == "crate:1")
  check("stop 2 unloads 5 into crate 2", run.acts[5][1].op == "unload" and run.acts[5][1].dst == "crate:2")
  check("back on the stand: the 15 it brought go to the Intake", run.arrive[1] and run.arrive[1].dst == "intake" and run.arrive[1].n == 15)
  check("it delivers 20 a cycle (5 to the crate, 15 to the Intake)", run.delivers.iron == 20, run.delivers.iron)
  check("the acts are a dense list (the save's JSON keeps no holes)", #run.acts == #run.phases)
  check("the leg's path keeps its samples, body-relative", #run.phases[2].path == 3 and run.phases[2].path[2].y == 200)
  check("a probe run", run.crewed == false and #run.crew == 0)
  check("its name and summary", run.name:find("Mule run") ~= nil and RT.summary(run):find("70 kg fuel") ~= nil, RT.summary(run))
  local m = RT.manifest(run)
  check("the manifest by place", #m == 3 and m[1].where == "At stop 1" and m[3].where == "Back on the stand", m[1] and m[1].where)
end

-- ── EVERY REFUSAL SAYS WHY ──────────────────────────────────────────────────
local function refused(desc, L, pat)
  local r, w = RT.fromLog(L)
  check("refused: " .. desc, r == nil and w ~= nil and w:find(pat) ~= nil, w)
end
local L = log2(); L.ended = nil
refused("not back yet", L, "hasn't come back")
L = log2(); L.ended.sid = 8
refused("back on another stand", L, "different stand")
L = log2(); L.ended.n = 5
refused("came back with parts missing", L, "5 of its 7 parts")
L = log2(); L.stops, L.xfers = {}, {}
refused("never stopped", L, "never stopped")
L = log2(); L.full = true
refused("the log filled up", L, "filled up")
L = log2(); L.xfers[1].src = "hand"
refused("a probe run's hand-dug load", L, "crew's pack")
L = log2(); L.stops[1].home = false; L.stops[1].fuelL = 500
refused("refuelled off the home world", L, "off the home world")
L = log2(); L.home = false; L.crew = { ["3"] = true }
refused("a crewed run off the home world", L, "restock at home")
L = log2(); L.intake = false
refused("cargo left in the hold out of the Intake's reach", L, "out of reach of the Intake")
L = log2(); L.xfers = {}; L.ended.hold = {}
refused("nothing delivered", L, "nothing was delivered")
L = log2(); L.xfers[2].dst = "hand"
refused("cargo taken out by hand", L, "by hand")
L = log2(); L.tDep = nil
refused("never left the stand", L, "never left")
check("the log stops at 64 stops and transfers", (function()
  local L2 = log2()
  for _ = 1, 80 do RT.addXfer(L2, 1, "iron", 1, "crate:1") end
  return L2.full == true and #L2.stops + #L2.xfers == RT.MAX_EVENTS
end)())
check("the map path keeps at most 16 samples", (function()
  local L2 = log2()
  for i = 1, 100 do RT.addPath(L2, { body = "Home", x = i, y = 0, z = 0, t = 100 + i }) end
  return #L2.path <= RT.PATH_MAX and L2.path[#L2.path].x == 100
end)())

-- crewed runs: the crew dig it again; a Pilot among them; not the one you play
do
  local Lc = log2(); Lc.xfers[1].src = "hand"; Lc.crew = { ["3"] = true }
  local rc, w = RT.fromLog(Lc)
  check("a crewed run may load what its crew dug", rc ~= nil and rc.crewed and rc.crew[1] == "3", w)
  local Wc = { crewOk = function(id) return id ~= "9", "you're playing them" end, isPilot = function(id) return id == "3" end }
  check("check: a Pilot flew it → ok", RT.check(rc, Wc) == true)
  Wc.isPilot = function() return false end
  local ok, w2 = RT.check(rc, Wc)
  check("check: no Pilot → refused, says so", not ok and w2:find("Pilot"), w2)
  rc.crew = { "9" }
  local ok3, w3 = RT.check(rc, Wc)
  check("check: the member you play → refused, says so", not ok3 and w3:find("playing"), w3)
  local ok4, w4 = RT.check(run, { exists = function(c) return c ~= "crate:2" end })
  check("check: a store it used is gone → refused", not ok4 and w4:find("gone"), w4)
end

-- ── THE SCHEDULE ────────────────────────────────────────────────────────────
local function world(stock)
  local S = { ["crate:1"] = { iron = stock or 1e9 }, ["crate:2"] = { iron = 0 }, ["hold:Mule"] = { iron = 15 }, base = {} }
  local W = { rp = 0, home = "Home" }
  local function bag(c) S[c] = S[c] or {}; return S[c] end
  W.count = function(c, m) return bag(c)[m] or 0 end
  W.room = function() return 1e12 end
  W.move = function(a, b, m, n) bag(a)[m] = (bag(a)[m] or 0) - n; bag(b)[m] = (bag(b)[m] or 0) + n; return n end
  W.add = function(c, m, n) bag(c)[m] = (bag(c)[m] or 0) + n; return n end
  W.intake = function(h, m, n) W.move(h, "base", m, n); return n * 0.5 end
  return W, S
end
do
  local A = RT.deepCopy(run)
  local WA, SA = world()
  RT.begin(A, WA, 1000, 1)
  check("Automate unloads what the flight brought back first", SA.base.iron == 15 and SA["hold:Mule"].iron == 0 and A.rp == 7.5,
    tostring(SA.base.iron))
  local B = RT.deepCopy(run)
  local WB, SB = world()
  RT.begin(B, WB, 1000, 1)
  local DAYS = 30 * 86400
  RT.MAX_STEPS = 1e9
  RT.advance(A, WA, 1000 + DAYS)
  for t = 1001, 1000 + DAYS do RT.advance(B, WB, t) end
  check(string.format("30 days in one call = 2,592,000 one-second calls: %d cycles", A.cycles),
    A.cycles == B.cycles and A.ph == B.ph and A.t0 == B.t0 and A.cycles == math.floor(DAYS / run.dur), A.cycles .. " vs " .. B.cycles)
  check("…every store the same, exactly", SA["crate:1"].iron == SB["crate:1"].iron and SA["crate:2"].iron == SB["crate:2"].iron
    and SA.base.iron == SB.base.iron and SA["hold:Mule"].iron == SB["hold:Mule"].iron, SA.base.iron .. " vs " .. SB.base.iron)
  check("…what it moved and the RP", A.moved.iron == B.moved.iron and near(A.rp, B.rp, 1e-6), A.moved.iron)
  -- (the cycle under way has done what its phases so far do)
  local l1 = A.cycles + (A.ph > 3 and 1 or 0)
  local u2 = A.cycles + (A.ph > 5 and 1 or 0)
  check("each cycle costs exactly the flight: 20 out of crate 1, 5 into crate 2, 15 to the Intake",
    SA["crate:1"].iron == 1e9 - 20 * l1 and SA["crate:2"].iron == 5 * u2 and SA.base.iron == 15 + 15 * A.cycles,
    string.format("ph %d, crate1 %d, crate2 %d, base %d", A.ph, 1e9 - SA["crate:1"].iron, SA["crate:2"].iron, SA.base.iron))
  check("never a failure: the state is run, nothing lost", A.state == "run" and A.lost == nil)
end
do
  -- a store runs short: it waits, with the numbers; refilled, it goes on
  local A = RT.deepCopy(run)
  local W, S = world(50)
  RT.begin(A, W, 0, 1)
  RT.advance(A, W, 10 * run.dur)
  check("crate 1 short: WAITING, with the numbers", A.state == "waiting" and A.why:find("10 of 20") ~= nil and A.cycles == 2, A.why)
  check("…at stop 1 (the craft drawn there)", select(3, RT.poseAt(A, 10 * run.dur)) == 400)
  check("…and the station's line says why", RT.situation(A, 10 * run.dur):find("^WAITING") ~= nil)
  S["crate:1"].iron = 100
  RT.advance(A, W, 10 * run.dur + 1)
  check("refilled: on again", A.state == "run" and A.ph == 4, A.state)
end
do
  -- pause keeps the time left; poseAt along the path; events
  local A = RT.deepCopy(run)
  local W = world()
  RT.begin(A, W, 0, 1)
  RT.advance(A, W, 120 + 25)   -- 25 s into the first leg (100 s)
  local b, x, y = RT.poseAt(A, 145)
  check("poseAt: a quarter of the way along the first leg, body-relative", b == "Home" and near(y, 100, 1e-6) and x == 1000, y)
  RT.pause(A, 145)
  local _, _, y2 = RT.poseAt(A, 99999)
  check("paused: it stays where it was", near(y2, 100, 1e-6) and RT.situation(A, 99999):find("PAUSED"))
  RT.advance(A, W, 99999)
  RT.resume(A, 99999)
  check("resumed: the same 75 s left", near(A.t0 + A.phases[A.ph].dur - 99999, 75, 1e-6))
  local ev = RT.events(A, 99999)
  check("NEXT: arrives at stop 1 in 75 s, then leaves it 60 s later", #ev == 2 and near(ev[1].t, 75) and ev[1].what:find("arrives")
    and near(ev[2].t, 135) and ev[2].what:find("leaves"), ev[1] and ev[1].what)
  local b0, x0 = RT.poseAt(RT.begin(RT.deepCopy(run), world(), 0, 2), 5)
  check("in the dwell it is on its stand", b0 == "Home" and x0 == 1000)
  check("cancel while waiting at a stop: it skips what it can't do and comes home", (function()
    local C = RT.begin(RT.deepCopy(run), world(0), 0, 4)
    local Wd = world(0)
    RT.advance(C, Wd, 400)
    local w1 = C.state == "waiting"
    C.cancel = true
    RT.advance(C, Wd, 401)
    RT.advance(C, Wd, 401 + run.dur)
    return w1 and C.state == "cancelled" and RT.onStand(C)
  end)())
  check("cancel on the way: done when it is back on the stand", (function()
    local C = RT.begin(RT.deepCopy(run), world(), 0, 3)
    RT.advance(C, world(), 200); C.cancel = true
    RT.advance(C, world(), 200 + run.dur)
    return C.state == "cancelled" and RT.onStand(C)
  end)())
end

-- ── THE SCENE HALF (route_ops with stubs) ──────────────────────────────────
do
  for k in pairs(STORE) do STORE[k] = nil end
  STORE["base.body"] = "Home"
  STORE["base.x"], STORE["base.y"], STORE["base.z"] = 1000, 0, 0
  local clock = 1000
  local DEP = { valid = true, agencyClock = function() return clock end }
  local RS = { valid = true, n = 0 }
  local RS2 = loadlib("research.lua", { save = SAVE, log = function() end, time = 0,
    findScript = function() return nil end, space = { time = function() return 0 end } })
  RS.study = function(m, q, o) RS.n = RS.n + 1; RS.last = { m, q, o }; return RS2.study(m, q, o) end
  local CREW = { valid = true, get = function(id) return { id = id, name = "Dana", status = "base" } end, activeId = function() return 1 end,
                 role = function() return "pilot" end, noteHome = function() end, aboard = function() return {} end }
  local NODE = { valid = true, id = 5 }
  local VC = { valid = true, craftName = "Mule", node = NODE, fuel = 40, crewCount = function() return 0 end }
  local POS = { x = 1000, y = 0, z = 0, vx = 0, down = true }
  local STAND = { valid = true, st = nil }
  STAND.framePose = function() return { body = "Home", top = { x = 1000, y = 0, z = 0 } } end
  STAND.stateOf = function() return STAND.st end
  STAND.setRun = function(_, _, id) STAND.st.s = id and "run" or "built"; STAND.st.run = id; return true end
  STAND.showRunCraft = function(_, _, on) STAND.shown = on end
  local ST = { valid = true, get = function() return { id = 7 } end }
  INV.findScript = function() return nil end
  local RO
  local scripts = { inventory = INV, routes = RT, deployables = DEP, research = RS, crew = CREW, craft_stand = STAND,
                    structures = ST, materials = { valid = true, label = function(m) return m == "iron" and "Iron Ore" or m end } }
  RO = loadlib("route_ops.lua", { save = SAVE, json = JSON, log = function() end, caption = function(s) RO_CAPTION = s end, time = 0,
    findScript = function(k) return scripts[k] end, findScripts = function(k) return k == "vessel_controller" and { VC } or {} end,
    assembly = { info = function() return { origin = { x = POS.x, y = POS.y, z = POS.z }, vel = { x = POS.vx, y = 0, z = 0 }, grounded = POS.down } end },
    space = { dominant = function() return "Home" end, body = function() return { x = 0, y = 0, z = 0 } end, time = function() return 0 end } })
  scripts.route_ops = RO
  local function tick(dt) for _ = 1, math.floor(dt * 4) do clock = clock + 0.25; RO.time = (RO.time or 0) + 0.25; RO.update(nil, 0.25) end end
  INV.setCap("hold:Mule", 500)
  for k in pairs(STORE) do if k:find("^inv%.") and k ~= "inv.cap" then STORE[k] = nil end end
  INV.add("crate:1", "iron", 200)
  RO.start()
  -- (a move made before this flight — the last one's unload — is not this flight's)
  INV.add("hold:Mule", "iron", 4)
  RO.onCommission(7, 1, { fuel = 40, parts = { { prefab = "A" }, { prefab = "B" } } }, "Old")
  RO.onGone(7, 1, "Old")
  INV.transfer("hold:Mule", "base", "iron", 4)
  INV.transfer("base", "crate:9", "iron", 4)
  RO.onCommission(7, 1, { fuel = 40, parts = { { prefab = "A" }, { prefab = "B" } } }, "Mule")
  check("commission starts a log, kept by the craft's name", RO.liveLog("Mule") ~= nil and RO.liveLog("Mule").fuel0 == 400)
  tick(2)
  RO.onRelease(7, 1, "Mule")
  POS.vx, POS.down = 5, false
  for i = 1, 20 do POS.y = POS.y + 20; tick(1) end
  POS.vx, POS.down = 0, true
  tick(7)
  local Lv = RO.liveLog("Mule")
  check("a stop: down and still 5 s, 400 m out", Lv and #Lv.stops == 1 and Lv.stops[1].y == 400 and Lv.open == 1, Lv and #Lv.stops)
  INV.transfer("crate:1", "crew:1", "iron", 25)
  INV.transfer("crew:1", "hold:Mule", "iron", 25)
  tick(1)
  check("the crate's load through the pack is logged at the stop (moves from before the flight are not)", #Lv.xfers == 1 and Lv.xfers[1].src == "crate:1" and Lv.xfers[1].at == 1,
    Lv.xfers[1] and Lv.xfers[1].src)
  POS.vx, POS.down, VC.fuel = 5, false, 37
  for i = 1, 20 do POS.y = POS.y - 20; tick(1) end
  POS.vx, POS.down = 0, true
  tick(2)
  check("the stop closed when it drove off", Lv.stops[1].tL ~= nil and Lv.open == nil)
  STAND.st = { s = "built", name = "Mule", ret = true }
  local runv, w = RO.onReturn(7, 1, "Mule", { fuel = 37, parts = { { prefab = "A" }, { prefab = "B" } } }, true)
  check("returned to its stand: automatable", runv ~= nil, w)
  check("…the discovery hint (once)", RO_CAPTION and RO_CAPTION:find("That's a route now") ~= nil, RO_CAPTION)
  local rows = RO.standRows(7, 1, STAND.st, {})
  local auto = nil
  for _, r in ipairs(rows) do if r.id == "rn_auto" then auto = r end end
  check("the stand's rows: Automate, enabled, with the cycle's numbers", auto and auto.enabled() and auto.value():find("25 Iron Ore a cycle"),
    auto and auto.value())
  local rp0 = STORE["res.pts"] or 0
  local ok, r = RO.automate(7, 1)
  check("Automate: a run, the stand serves it, drawn on the stand", ok and r and STAND.st.s == "run" and STAND.shown == true, r)
  check("…the Intake took the 25 it brought (warehouse, freight)", INV.count("base", "iron") == 25 and INV.count("hold:Mule", "iron") == 0
    and (STORE["depot.freight"] or {}).iron == 25)
  -- material_intake's path: research.study(mat, qty, origin) for the same lot
  local RS3 = loadlib("research.lua", { save = { get = function() return nil end, set = function() end }, log = function() end,
    time = 0, findScript = function() return nil end, space = { time = function() return 0 end } })
  check("…the RP are research.study's for that lot (the Intake's own path)", RS.n == 1 and RS.last[1] == "iron" and RS.last[2] == 25
    and (STORE["res.pts"] or 0) - rp0 == RS3.study("iron", 25, nil) and r.rp == (STORE["res.pts"] or 0) - rp0, (STORE["res.pts"] or 0) - rp0)
  check("…no Automate twice", not RO.automate(7, 1))
  local c0 = INV.count("crate:1", "iron")
  tick(r.dur * 3 / 1 + 5)
  check("three cycles later: 25 from the crate and 25 to the Intake each", r.cycles >= 3 and INV.count("crate:1", "iron") == c0 - 25 * r.cycles
    and INV.count("base", "iron") == 25 + 25 * r.cycles, r.cycles)
  check("it is saved (JSON) and comes back after a reload", (function()
    RO.start()
    local r2 = RO.get(r.id)
    return r2 and r2.cycles == r.cycles and r2.ph == r.ph and #r2.phases == #r.phases
  end)())
  local r2 = RO.get(r.id)
  local cy0 = r2.cycles
  tick(r2.dur * 2 + 5)
  check("…and keeps cycling after the reload", RO.get(r.id).cycles >= cy0 + 2, RO.get(r.id).cycles .. " " .. tostring(RO.get(r.id).state) .. " " .. tostring(RO.get(r.id).why))
  local ev = RO.events()
  check("NEXT: two events a run, glyph ⇄", #ev == 2 and ev[1].glyph == "⇄" and ev[1].id == "R:" .. r.id)
  check("a crew member is not busy on a probe run", RO.memberBusy(1) == nil)
  -- cancel on the stand: the craft is the stand's again
  local ok2, how = RO.cancelRun(r.id)
  if how ~= "now" then
    tick(r2.dur + 2)
  end
  check("cancel: the run ends, the stand holds the craft again", RO.get(r.id) == nil and STAND.st.s == "built", STAND.st.s)
end

-- ── THE RESPAWN CLOCK FIX ───────────────────────────────────────────────────
do
  local AG = 5000
  local FO = loadlib("flight_ops.lua", { save = SAVE, log = function() end, time = 0,
    findScript = function(k) if k == "deployables" then return { valid = true, agencyClock = function() return AG end } end end,
    space = { time = function() return 12 end } })
  check("a record with `at`: carried by the agency clock (a reload restarted space.time)",
    FO.carryDt({ at = 4000, stime = 900 }) == 1000, FO.carryDt({ at = 4000, stime = 900 }))
  check("an old record without it: by space.time, as before", FO.carryDt({ stime = 2 }) == 10)
  check("…and the map's sim time for it: now − its agency age", FO.simTimeOf({ at = 4000 }) == 12 - 1000)
end

-- ── THE STATION ─────────────────────────────────────────────────────────────
do
  local FV = loadlib("fleet_view.lua", { time = 0 })
  local e = { kind = "route", rsub = "Leg 1/3 · to stop 1 · 1 m 15 s", cycles = 2 }
  check("a run's group is RUNS", FV.groupOf(e) == "RUNS" and FV.GLYPHS.route == "⇄" and FV.situation(e):find("Leg 1/3"))
  check("…between PROBES and LANDED", (function()
    local i = {}
    for k, g in ipairs(FV.GROUPS) do i[g] = k end
    return i.RUNS == i.PROBES + 1 and i.LANDED == i.RUNS + 1
  end)())
  check("…a waiting run is ATTENTION", FV.groupOf({ kind = "route", attn = { level = "warn" } }) == "ATTENTION")
  check("…its key number: the cycle", FV.keyNumber(e) == "cycle 3")
end

print(string.format("smoke_routes: %d checks, %d failed", count, failed))
os.exit(failed == 0 and 0 or 1)
