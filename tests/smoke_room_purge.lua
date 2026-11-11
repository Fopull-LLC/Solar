-- SMOKE: the ROOM PURGE (scripts/room_air.lua; docs/base-building.md §14).
-- A hut sealed on a world whose air holds no oxygen (1.2 atm of CO2, or of
-- N2) closes round that air; the Air Tank Rack's regulator never opens over
-- 97 % of an atmosphere. PURGE pumps the gas overboard and the racks refill
-- the room with air, in minutes:
--
--   * pure: the pump-down is the venting branch to a vacuum with an event at
--     RP_P (one step = many, to 1e-6); purgePlan's times; foulAir;
--   * the scene on a stub engine (a powered base grid, a 17.6 m³ hut, one
--     rack, a scrubber): a CO2 world from 1.2 atm to breathable in minutes,
--     the crew inside warned and never refused, the rack's 2 kW while it
--     pumps and none after, a whole purge in one catch-up step equal to one a
--     second, no power pausing it (the room holds, the regulator waits), the
--     refusals (no rack, the racks short, a door open, no power), stopping it
--     by hand, the purge carried in the save, and an N2 world too.
--
--   luajit solar/tests/smoke_room_purge.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "ok   " or "FAIL ") .. msg) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
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

local S = {}
S.parts_kit = load_script("parts_kit.lua", env({}, S))
S.parts_base = load_script("parts_base.lua", env({}, S))
S.kit_snap = load_script("kit_snap.lua", env({}, S))
local RL = load_script("rooms.lua", env({}, S))
S.rooms = RL
local RA = load_script("room_air.lua", env({}, S))

-- ── pure ────────────────────────────────────────────────────────────────────
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
do
  local V = 17.6
  local st0 = { N = V * 1.2 * 0.04, x = 0, c = V * 1.2 * 0.96, q = 60, feed = false }
  local M = { V = V, tau = V / 0.3, slow = false, pout = 0, xout = 0, cout = 0, F = 0, pT = RA.RP_P }
  local _, rep = RA.advance(copy(st0), M, 3600)
  local one = RA.advance(copy(st0), M, 3600)
  local tpump = (V / 0.3) * math.log(1.2 / RA.RP_P)
  check(rep.purged and near(rep.left, 3600 - tpump, 1e-6), string.format("the pump-down stops at %.2f atm: %.1f s of the hour stepped (%.1f expected)", RA.RP_P, 3600 - (rep.left or 0), tpump))
  check(near((one.N + one.x + one.c) / V, RA.RP_P, 1e-9), string.format("and lands on it (%.5f atm)", (one.N + one.x + one.c) / V))
  local many, left, n = copy(st0), 3600, 0
  while left > 0 do
    local _, r = RA.advance(many, M, 1.0)
    n = n + 1
    if r.purged then break end
    left = left - 1
  end
  check(near(many.c, one.c, 1e-6) and near(many.N, one.N, 1e-6), string.format("one step = a step a second (%d steps; CO2 %.6f vs %.6f)", n, many.c, one.c))
  local pl = RA.purgePlan(V, V * 1.2, 0.3, 0.25, 60)
  check(near(pl.pump, tpump, 1e-9) and near(pl.need, V * (1 - RA.RP_P), 1e-9) and near(pl.fill, pl.need / 0.25, 1e-9) and not pl.short,
    string.format("purgePlan: %.0f s to pump down, %.0f s to refill, %.1f m³ of air", pl.pump, pl.fill, pl.need))
  check(pl.pump + pl.fill < 10 * 60, string.format("a 17.6 m³ hut with one rack: minutes, not days (%.1f min)", (pl.pump + pl.fill) / 60))
  check(RA.purgePlan(V, V, 0.3, 0.25, 10).short and RA.purgePlan(V, V, 0, 0.25, 60).pump == nil, "short of air; no pump")
  check(RA.foulAir({ N = 0.04, x = 0, c = 0.96 }) and RA.foulAir({ N = 1, x = 0, c = 0 }) and not RA.foulAir({ N = 0.79, x = 0.21, c = 0.0004 }),
    "foulAir: CO2, or no O2, is the outside's gas; normal air isn't")
end

-- ── the scene ───────────────────────────────────────────────────────────────
local PI2 = math.pi / 2
local function P(uid, id, x, y, z, yaw, pitch) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 } end
-- the arc probe's hut: 4 x 2 m inside, 2.2 m high (17.6 m³), its door at x 1
local function hut(opts)
  local T = 0.2
  local bp = { P(1, "floor.steel", 2, 0, 0), P(2, "floor.steel", 4, 0, 0),
    P(3, "doorWall.steel", 1, T, 0, PI2), P(4, "wall.steel", 5, T, 0, PI2),
    P(5, "wall.steel", 2, T, -1, 0), P(6, "wall.steel", 4, T, -1, 0), P(7, "wall.steel", 2, T, 1, 0), P(8, "wall.steel", 4, T, 1, 0),
    P(9, "floor.steel", 2, T + 2.2, 0), P(10, "floor.steel", 4, T + 2.2, 0),
    P(11, "scrubber.steel", 4.4, T, -0.62, 0) }
  if opts.rack ~= false then bp[#bp + 1] = P(12, "airTank.steel", 3.0, T, -0.6, 0) end
  return bp
end
local function scene(opts)
  opts = opts or {}
  local store = opts.store or {}
  local SS = {}
  for k, v in pairs(S) do SS[k] = v end
  local planet = { x = 1000, y = 0, z = 0, name = "Haldane" }
  local agency = opts.agency or 1000.0
  local doors = {}
  local astro = { x = 0, y = 0, z = 0, valid = opts.crew ~= false }
  local rec = { id = 1, b = "Haldane", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = hut(opts) }
  local pstate = {}
  SS.structures = { version = 1, list = function() return { rec } end, get = function(id) if id == 1 then return rec end end,
    partState = function(sid, uid) return pstate[uid] end, setPartState = function(sid, uid, t) pstate[uid] = t end,
    getPart = function(sid, uid) for _, p in ipairs(rec.bp) do if p.uid == uid then return p end end end,
    partOfNode = function(n) return rec, n.part end }
  local provider = nil
  SS.context_registry = { register = function(kind, fn) provider = fn end }
  SS.kit_live = { doorOpen = function(sid, uid) return doors[uid] or 0 end }
  local powered = opts.power ~= false
  local dirty = 0
  SS.base_grid = { gridOfStruct = function() return powered and { id = 1, bases = { 1 } } or nil end,
    model = function() return { sources = 1, C = 10 } end, status = function() return { short = 0, stored = 5 } end,
    markDirty = function() dirty = dirty + 1 end }
  SS.deployables = { agencyClock = function() return agency end }
  local gases = opts.gases or { CO2 = 0.96, N2 = 0.04 }
  SS.climate = { worldOf = function() return { atmo = 1.0, radius = 500, air = { p0 = 1.2, gases = gases } } end }
  local big, logged = {}, {}
  SS.big_caption = { show = function(a, b, _, kind) big[#big + 1] = { a, b, kind } end }
  SS.sfx = { caption = function() end }
  SS.base_log = { add = function(sid, k, t) logged[#logged + 1] = { k, t } end }
  local helmet = opts.helmet ~= false
  SS.suit = { helmetOn = function() return helmet end }
  SS.planet_walker = { onFoot = true }
  local E = env(store, SS, {
    space = { body = function() return planet end, dominant = function() return "Haldane" end },
    find = function(n) if n == "Astronaut" and astro.valid then return astro end end,
    audio = { play = function() return { stop = function() end } end },
    app = { wallClock = os.clock },
  })
  local A = load_script("room_air.lua", E)
  local W = { A = A, E = E, doors = doors, rec = rec, big = big, logged = logged, store = store, SS = SS }
  W.menu = function(uid) for _, p in ipairs(rec.bp) do if p.uid == uid then return provider({ node = { part = p } }, {}) end end end
  function W.at(lx, ly, lz) astro.x, astro.y, astro.z = planet.x + rec.x + lx, planet.y + rec.y + ly, planet.z + rec.z + lz end
  function W.frame(dt)
    E.time = E.time + dt
    agency = agency + dt
    A.update(nil, dt)
  end
  function W.skip(dt) agency = agency + dt end
  W.setPower = function(on) powered = on end
  W.dirty = function() return dirty end
  W.agency = function() return agency end
  if opts.crew ~= false then W.at(3.6, 1.3, 0) else W.at(30, 1, 30) end
  for _ = 1, 12 do W.frame(0.1) end
  local st = A.state(1)
  W.room = st and st.R and RL.roomAt(st.R, 3.0, 1.2, 0)
  return W
end

-- 1. A CO2 world: the hut closes round 1.2 atm of it
do
  local W = scene()
  local A, r = W.A, W.room
  check(r and r.sealed and near(r.m3, 17.6, 1e-6), string.format("the hut: one sealed room of 17.6 m³ (%.1f)", r and r.m3 or -1))
  local q0 = A.airOf(1, r.id)
  check(q0 and near(q0.p, 1.2, 1e-3) and not q0.breathable and q0.foul, string.format("it closed round the outside: %.2f atm, CO2 %.0f %% (%s)", q0.p, 100 * q0.co2 / q0.p, tostring(q0.why)))
  for _ = 1, 60 do W.frame(1.0) end
  local q1 = A.airOf(1, r.id)
  check(near(q1.p, 1.2, 1e-3) and not q1.breathable and near(A.state(1).tanks[12], 60, 1e-9),
    "a minute on: the rack's regulator never opens over 97 % of an atmosphere (the problem)")
  -- the plan, as the rack's menu works it out
  local pi = A.purgeInfo(1, r.id)
  check(pi and pi.foul and pi.racks == 1 and near(pi.kw, 2.0, 1e-9) and pi.plan.pump > 200 and pi.plan.pump < 400 and pi.plan.fill < 90,
    string.format("its plan: %s to pump down at %.1f kW, %s to refill · %s", A.fmtSecs(pi.plan.pump), pi.kw, A.fmtSecs(pi.plan.fill), A.purgeLine(pi)))
  check(A.purgeWhy(1, r.id) == nil, "nothing stands in its way")
  -- the rack's menu: the plan as a row, PURGE as a switch
  local rows, title = W.menu(12)
  local row = {}
  for _, e in ipairs(rows or {}) do row[e.id] = e end
  check(title == "Air Tank Rack" and row.ra_purge and row.ra_purge.type == "toggle" and row.ra_purge.enabled() and not row.ra_purge.on() and row.ra_purge.hint,
    string.format("the rack's menu: '%s' (%s)", row.ra_purge and row.ra_purge.label or "-", row.ra_purge and tostring(row.ra_purge.hint) or "-"))
  check(row.ra_purge_i and row.ra_purge_i.value():find("outside's gas", 1, true) and row.ra_purge_i.warn(), "and its plan: " .. (row.ra_purge_i and row.ra_purge_i.value() or "-"))
  -- the terminal's AIR page: the room's row says it, a PURGE key under it
  do
    local pages = {}
    local TS = {}
    for k, v in pairs(W.SS) do TS[k] = v end
    TS.room_air = A
    TS.terminal = { registerPage = function(id, fn) pages[id] = fn end, recName = function() return "Hut" end }
    local TP = load_script("terminal_pages.lua", env({}, TS))
    if TP.start then pcall(TP.start, {}) end
    local prow = {}
    for _, e in ipairs(TP.pageFns.AIR({ sid = 1, sids = { 1 }, kind = "desk" })) do
      if e.id then prow[e.id] = e end
      if e.label and tostring(e.label):find("^Room") then prow.room = e end
    end
    local key = prow["pg_1_" .. r.id]
    check(prow.room and prow.room.value():find("OUTSIDE GAS", 1, true), "the AIR page: " .. (prow.room and prow.room.value() or "-"))
    check(key and key.type == "toggle" and key.offText == "[ PURGE ]" and key.enabled() and key.tip():find("pump down", 1, true),
      string.format("a PURGE key (%s, %s)", key and key.label or "-", key and tostring(key.hint) or "-"))
  end
  -- the crew are inside, helmets on: warned, never refused
  local ok, warn = A.startPurge(1, r.id, "hand")
  check(ok and warn and warn:find("Helmets on", 1, true), "PURGE with the crew inside: it starts, with a warning: " .. tostring(warn))
  check(#W.big > 0 and W.big[#W.big][1] == "PURGE", "the crew in it see it said")
  check(A.purging(1, r.id) and A.airOf(1, r.id).purging, "the room is purging")
  check(near(A.gridAux(1, 12), 2.0, 1e-9) and W.dirty() > 0, "the rack's purge pump draws 2 kW from the grid (the grid told)")
  check(A.purgeWhy(1, r.id) ~= nil, "a second purge is refused while one runs")
  local t, tdone, tbreath, pmin = 0, nil, nil, 9
  while t < 900 do
    W.frame(1.0); t = t + 1
    local q = A.airOf(1, r.id)
    pmin = math.min(pmin, q.p)
    if not tdone and not q.purging then tdone = t end
    if tdone and not tbreath and q.breathable then tbreath = t end
    if tbreath and t > tbreath + 120 then break end
  end
  check(tdone and math.abs(tdone - pi.plan.pump) <= 2, string.format("pumped down in %s s (the plan said %.0f)", tostring(tdone), pi.plan.pump))
  check(pmin <= A.RP_P + 1e-3, string.format("to %.3f atm", pmin))
  check(near(A.gridAux(1, 12), 0, 1e-12), "and the pump stopped: no draw")
  local q2 = A.airOf(1, r.id)
  check(tbreath and tbreath < 10 * 60, string.format("breathable %s s after PURGE: %.1f minutes", tostring(tbreath), (tbreath or 0) / 60))
  check(q2.breathable and q2.p > 0.97 and q2.co2 <= 0.012 and q2.o2 > 0.19 and not q2.foul,
    string.format("then: %.2f atm, O2 %.2f atm, CO2 %.4f atm (the scrubber takes the last of it)", q2.p, q2.o2, q2.co2))
  local used = 60 - A.state(1).tanks[12]
  check(used > 16 and used < 20, string.format("the rack gave %.1f of its 60 m³", used))
  local done = false
  for _, l in ipairs(W.logged) do if l[2]:find("purged", 1, true) then done = true end end
  check(done and A.lastPurge and A.lastPurge.why == "done", "the base log says it was purged")
end

-- 2. A whole purge in one catch-up step = a step a second (no crew)
do
  local Wa, Wb = scene({ crew = false }), scene({ crew = false })
  local ra, rb = Wa.room, Wb.room
  check(Wa.A.startPurge(1, ra.id) and Wb.A.startPurge(1, rb.id), "two huts, both purging")
  for _ = 1, 500 do Wa.frame(1.0) end
  Wb.skip(500); Wb.A.advanceNow()
  local qa, qb = Wa.A.state(1).air[ra.id], Wb.A.state(1).air[rb.id]
  check(near(qa.N, qb.N, 1e-6) and near(qa.x, qb.x, 1e-6) and near(qa.c, qb.c, 1e-6) and near(Wa.A.state(1).tanks[12], Wb.A.state(1).tanks[12], 1e-6),
    string.format("500 s in one step = 500 steps (O2 %.6f / %.6f, CO2 %.6f / %.6f)", qa.x, qb.x, qa.c, qb.c))
  check(not Wb.A.purging(1, rb.id) and Wb.A.airOf(1, rb.id).breathable, "and the one-step hut is purged and breathable too")
end

-- 3. The power goes mid-purge: the pump stops, the room holds, the regulator waits
do
  local W = scene({ crew = false })
  local A, r = W.A, W.room
  A.startPurge(1, r.id)
  for _ = 1, 60 do W.frame(1.0) end
  W.setPower(false)
  for _ = 1, 3 do W.frame(1.0) end
  local p0 = A.airOf(1, r.id).p
  for _ = 1, 120 do W.frame(1.0) end
  local q = A.airOf(1, r.id)
  check(q.purging and near(q.p, p0, 1e-9) and near(A.gridAux(1, 12), 2.0, 1e-9) == false and A.state(1).tanks[12] == 60,
    string.format("no power: still purging, held at %.3f atm (%.3f), the regulator shut (tank %.2f), the pump off (%.1f kW)", q.p, p0, A.state(1).tanks[12], A.gridAux(1, 12)))
  W.setPower(true)
  for _ = 1, 600 do W.frame(1.0) end
  check(not A.purging(1, r.id) and A.airOf(1, r.id).breathable, "power back: it carries on to breathable")
end

-- 4. The refusals, and stopping by hand
do
  local W = scene({ rack = false, crew = false })
  local why = W.A.purgeWhy(1, W.room.id)
  check(why and why:find("Air Tank Rack", 1, true), "no rack: " .. tostring(why))
  local W2 = scene({ crew = false })
  W2.A.state(1).tanks[12] = 8
  why = W2.A.purgeWhy(1, W2.room.id)
  check(why and why:find("refill them", 1, true) and not W2.A.startPurge(1, W2.room.id), "the racks short of air: " .. tostring(why))
  W2.A.state(1).tanks[12] = 60
  W2.doors[3] = 1; W2.A.doorMoved(1, 3)
  why = W2.A.purgeWhy(1, W2.room.id)
  check(why and why:find("open", 1, true), "a door open: " .. tostring(why))
  W2.doors[3] = 0; W2.A.doorMoved(1, 3)
  W2.setPower(false); for _ = 1, 2 do W2.frame(1.0) end
  why = W2.A.purgeWhy(1, W2.room.id)
  check(why and why:find("power", 1, true), "no power: " .. tostring(why))
  W2.setPower(true); for _ = 1, 2 do W2.frame(1.0) end
  check(W2.A.startPurge(1, W2.room.id), "all well: it starts")
  for _ = 1, 30 do W2.frame(1.0) end
  -- the save carries it
  W2.A.saveNow()
  local sv = W2.store["air.1"]
  check(type(sv) == "table" and type(sv.purge) == "table" and sv.purge[1] == W2.room.key, "a purge under way is in the save")
  local W3 = scene({ crew = false, store = W2.store, agency = W2.agency() })
  check(W3.A.purging(1, W3.room.id), "and a new session carries on purging")
  local ok = W2.A.stopPurge(1, W2.room.id)
  check(ok and not W2.A.purging(1, W2.room.id) and W2.A.lastPurge.why == "stop", "stopped by hand")
  for _ = 1, 200 do W2.frame(1.0) end
  check(W2.A.airOf(1, W2.room.id).p > 0.97, "the regulator then fills what is there")
end

-- 5. An N2 world, the crew in it without a helmet: warned, it runs
do
  local W = scene({ gases = { N2 = 1.0 }, helmet = false })
  local A, r = W.A, W.room
  local q0 = A.airOf(1, r.id)
  check(near(q0.p, 1.2, 1e-6) and q0.foul and not q0.breathable, string.format("an N2 world: %.2f atm, no O2 (%s)", q0.p, tostring(q0.why)))
  local ok, warn = A.startPurge(1, r.id)
  check(ok and warn and W.big[#W.big][3] == "alarm", "helmet off inside: it still starts, and the warning is an alarm")
  for _ = 1, 600 do W.frame(1.0) end
  local q = A.airOf(1, r.id)
  check(q.breathable and near(q.o2, 0.21 * q.p, 0.01), string.format("purged and refilled: %.2f atm, O2 %.2f atm", q.p, q.o2))
end

if #failures > 0 then
  print("FAIL smoke_room_purge: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_room_purge: %d checks passed", passed))
