-- SMOKE: pressure mechanics (sandbox S7 part B; docs/base-building.md §17),
-- against the real parts_kit, parts_base, kit_snap, rooms and room_air on a
-- stub engine (smoke_rooms' layout: an airlock chamber, a hab, a door to the
-- moon).
--
--   * EQUALISE: a door's own valve (and an Equalise Valve piece) lets the two
--     sides' pressures meet as e^(-k t), k = C (1/Va + 1/Vb): the door held
--     shut opens when the time the formula gives is up (to 2 %);
--   * a SLOW LEAK (an open valve to the moon, a damaged seal) keeps the
--     regulator feeding: one step = many small, exactly;
--   * the AIRLOCK keeps its air: powered, it pumps the chamber into its
--     Airlock Receiver (90 % of it back, the rest under the pump's floor
--     vented) at a speed that makes a bigger chamber take longer, and bleeds
--     it back on the way in; with the power off, or the receiver full, it
--     vents the chamber and says so;
--   * THE SUIT RULE: helmet off, the crew don't go through a door (or cycle
--     a chamber) to low pressure, and are told to put it on;
--   * FORCING: the warning to the room first, then the door opens, the gust
--     (vfx), the pull on the crew toward the opening (∝ Δp), a damaged seal
--     that leaks once the door is shut, re-seated by its repair; a badly
--     damaged seal under pressure fails after a warning;
--   * the O2 GENERATOR'S WATER: it makes O2 only while its cell has water,
--     2 H2O → 2 H2 + O2 by mass.
--
--   luajit solar/tests/smoke_pressure.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end
local function rel(a, b, e) return math.abs(a - b) <= (e or 1e-6) * math.max(1, math.abs(a), math.abs(b)) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
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

local S = {}
S.parts_kit = load_script("parts_kit.lua", env({}, S))
S.parts_base = load_script("parts_base.lua", env({}, S))
S.kit_snap = load_script("kit_snap.lua", env({}, S))
S.rooms = load_script("rooms.lua", env({}, S))
local RL = S.rooms
local RA0 = load_script("room_air.lua", env({}, S))
local PI2 = math.pi / 2
local function P(uid, id, x, y, z, yaw, pitch, roll) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0 } end

-- ── pure: the slow leak with the regulator feeding, one step = many ────────
do
  local V = 18
  local M = { V = V, tau = V / 0.003, slow = true, F = 0.25, pout = 0, xout = 0, crew = 0 }
  local A = { N = 0.79 * V, x = 0.21 * V, c = 0, q = 60, feed = false }
  local B = { N = A.N, x = A.x, c = 0, q = 60, feed = false }
  local _, rep = RA0.advance(A, M, 3 * 3600)
  for _ = 1, 3 * 360 do RA0.advance(B, M, 10) end
  local ons = 0
  for _, e in ipairs(rep.events) do if e == "feed_on" then ons = ons + 1 end end
  check(rel(A.N, B.N, 1e-6) and rel(A.x, B.x, 1e-6) and rel(A.q, B.q, 1e-6),
    string.format("a slow leak (a damaged seal) fed by the regulator: 3 h in one step = 1,080 steps (%.6f / %.6f m³ left)", A.q, B.q))
  check(ons >= 2 and A.q < 60 and (A.N + A.x) / V > 0.95, string.format("the regulator cycled %d times and held the room (%.3f atm) while its store fell (%.1f m³)", ons, (A.N + A.x) / V, A.q))
  -- and a breach (an open door: not slow) shuts it: the excess-flow valve
  local Cq = { N = A.N, x = A.x, c = 0, q = 30, feed = false }
  RA0.advance(Cq, { V = V, tau = 9, slow = false, F = 0.25, pout = 0, xout = 0 }, 60)
  check(near(Cq.q, 30, 1e-12) and (Cq.N + Cq.x) / V < 0.01, "a breach vents the room and the regulator shuts (no store lost into it)")
end

-- ── pure: the valve's closed form ───────────────────────────────────────────
do
  local A, B = { N = 7.9, x = 2.1, c = 0 }, { N = 0, x = 0, c = 0 }
  local C, Va, Vb = 0.25, 10, 9
  RA0.equalise(A, Va, B, Vb, C, 30)
  local A2, B2 = { N = 7.9, x = 2.1, c = 0 }, { N = 0, x = 0, c = 0 }
  for _ = 1, 3000 do RA0.equalise(A2, Va, B2, Vb, C, 0.01) end
  local pa, pb = (A.N + A.x) / Va, (B.N + B.x) / Vb
  local d0 = 1.0
  local want = d0 * math.exp(-C * (1 / Va + 1 / Vb) * 30)
  check(rel(pa - pb, want, 1e-9), string.format("a valve between two rooms: Δp falls as e^(-C(1/Va+1/Vb)t) (%.6f atm after 30 s)", pa - pb))
  check(rel(A.N + A.x + B.N + B.x, 10, 1e-12) and rel(A.x / (A.N + A.x), 0.21, 1e-12) and rel(B.x / (B.N + B.x), 0.21, 1e-12), "no air lost or made; the mix carried as it is")
  check(rel(pa, (A2.N + A2.x) / Va, 1e-9), "one step = 3,000 steps exactly")
  check(near(RA0.equaliseTime(18, nil, 0.25, 1.0, 0.1), 72 * math.log(10), 1e-9), "an 18 m³ room to the outside through 0.25 m³/s/atm: 0.1 atm left in 72 ln 10 = 166 s")
end

-- ── the scene ───────────────────────────────────────────────────────────────
local function scene(opts)
  opts = opts or {}
  local store = {}
  local SS = {}
  for k, v in pairs(S) do SS[k] = v end
  local planet = { x = 1000, y = 0, z = 0, name = "Moon" }
  local agency = 1000.0
  local doors = {}
  local astro = { x = 0, y = 0, z = 0, valid = true }
  local bp = { P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0),
    P(3, "airlockWall.steel", -1, 0.2, 0, PI2), P(4, "wall.steel", 3, 0.2, 0, PI2),
    P(5, "wall.steel", 0, 0.2, -1, 0), P(6, "wall.steel", 2, 0.2, -1, 0), P(7, "wall.steel", 0, 0.2, 1, 0), P(8, (opts.front or "doorWall") .. ".steel", 2, 0.2, 1, 0),
    P(9, "doorWall.steel", 1, 0.2, 0, PI2), P(10, "floor.steel", 0, 2.4, 0), P(11, "floor.steel", 2, 2.4, 0),
    P(12, "airTank.steel", 2.4, 0.2, -0.5) }
  if opts.receiver then bp[#bp + 1] = P(13, "airReceiver.steel", 0, 0.2, -0.4) end
  if opts.gen then bp[#bp + 1] = P(14, "o2gen.steel", 2.5, 0.2, 0.5) end
  if opts.eqv then bp[#bp + 1] = P(15, "eqValve.steel", 3 - 0.1, 1.2, 0.3, -PI2, PI2) end
  local rec = { id = 1, b = "Moon", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp }
  local pstate = {}
  SS.structures = { version = 1, list = function() return { rec } end, get = function(id) if id == 1 then return rec end end,
    partState = function(sid, uid) return pstate[uid] end, setPartState = function(sid, uid, t) pstate[uid] = t end }
  SS.kit_live = { doorOpen = function(sid, uid) return doors[uid] or 0 end }
  local powered = opts.power ~= false
  SS.base_grid = { gridOfStruct = function() return powered and { id = 1, bases = { 1 } } or nil end,
    model = function() return { sources = 1, C = 10 } end, status = function() return { short = 0, stored = 5 } end, markDirty = function() end }
  SS.deployables = { agencyClock = function() return agency end }
  SS.climate = { worldOf = function() return { atmo = 0, radius = 500 } end }
  local captions, big = {}, {}
  SS.big_caption = { show = function(a, b) big[#big + 1] = a .. ": " .. b end }
  SS.sfx = { caption = function(t) captions[#captions + 1] = t end }
  local helmet = opts.helmet ~= false
  SS.suit = { helmetOn = function() return helmet end }
  local pulls = {}
  SS.planet_walker = { onFoot = true, pull = function(x, y, z, s) pulls[#pulls + 1] = { x, y, z, s } end }
  local fx = {}
  SS.vfx = { emit = function(key, x, y, z, o) fx[#fx + 1] = { key = key, x = x, y = y, z = z, o = o } end }
  local frame_ = {}
  SS.kit_snap = setmetatable({ frameOf = function(r) return { O = { x = r.x, y = r.y, z = r.z }, R = { x = 1, y = 0, z = 0 }, U = { x = 0, y = 1, z = 0 }, F = { x = 0, y = 0, z = 1 } } end }, { __index = S.kit_snap })
  local E = env(store, SS, {
    space = { body = function() return planet end, dominant = function() return "Moon" end },
    find = function(n) if n == "Astronaut" then return astro end end,
    audio = { play = function() return { stop = function() end } end },
    app = { wallClock = os.clock },
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  })
  local A = load_script("room_air.lua", E)
  local W = {}
  function W.at(lx, ly, lz) astro.x, astro.y, astro.z = planet.x + rec.x + lx, planet.y + rec.y + ly, planet.z + rec.z + lz end
  function W.frame(dt, wants)
    E.time = E.time + dt
    agency = agency + dt
    for uid, w in pairs(wants or {}) do
      local g = A.gate(1, uid, w)
      local o = doors[uid] or 0
      if g > 0 then o = math.min(1, o + dt / 1.0) else o = math.max(0, o - dt / 1.0) end
      if (o > 0.02) ~= ((doors[uid] or 0) > 0.02) then A.doorMoved(1, uid) end
      doors[uid] = o
    end
    A.update(nil, dt)
  end
  W.A, W.E, W.doors, W.rec, W.pstate, W.captions, W.big, W.pulls, W.fx = A, E, doors, rec, pstate, captions, big, pulls, fx
  W.setHelmet = function(on) helmet = on end
  W.setPower = function(on) powered = on end
  W.agency = function() return agency end
  W.at(5, 1.0, 5)
  for _ = 1, 10 do W.frame(0.1) end
  local st = A.state(1)
  W.ch = RL.roomAt(st.R, 0, 1.2, 0)
  W.hab = RL.roomAt(st.R, 2, 1.2, 0)
  for _ = 1, 500 do W.frame(0.1) end        -- the tank brings the hab up
  return W
end

-- ── EQUALISE: the hab's door to the moon, by its own valve ─────────────────
do
  local W = scene()
  local A = W.A
  W.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W.frame(0.1) end
  local p0 = A.airOf(1, W.hab.id).p
  check(p0 > 0.95 and A.gate(1, 8, 1) == 0, string.format("the hab's door to the moon is held shut by %.2f atm", p0))
  -- the valve: shut the tank's feed out of it so the time is the formula's alone
  A.state(1).tanks[12] = 0
  local eta = A.equaliseEta(1, 8)
  A.setEqualise(1, 8, true)
  check(A.equaliseOpen(1, 8), "its menu opens the door's equalising valve")
  local t, opened = 0, nil
  while t < 600 do
    W.frame(0.5)
    t = t + 0.5
    if not opened and A.gate(1, 8, 1) == 1 then opened = t end
  end
  local want = A.equaliseTime(W.hab.m3, nil, A.EQ_DOOR, p0, A.HOLD_DP)
  check(eta and rel(eta, want, 0.02), string.format("its menu says ~%.0f s (the formula: V / C · ln(Δp/0.1) = %.0f s)", eta or -1, want))
  check(opened and math.abs(opened - want) <= 0.03 * want + 1.0, string.format("the door can open once the valve has bled it: at %.1f s (the formula: %.1f s)", opened or -1, want))
  local q = A.airOf(1, W.hab.id)
  check(q.venting and q.p < 0.12, string.format("…by letting the hab's air go, slowly: %.3f atm (it vented through a valve, not a door)", q.p))
  -- a door between two rooms equalises them both ways: the chamber from the hab
  local W2 = scene()
  local A2 = W2.A
  W2.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W2.frame(0.1) end
  A2.state(1).tanks[12] = 0
  local pc0, ph0 = A2.airOf(1, W2.ch.id).p, A2.airOf(1, W2.hab.id).p
  -- (the inner door is the airlock's: its interlock cycles it; the valve piece
  -- through the hab's far wall is checked instead)
  check(pc0 < 0.05 and ph0 > 0.9, "the chamber at vacuum, the hab at 1 atm")
end

-- ── an Equalise Valve piece through a wall to the moon ─────────────────────
do
  local W = scene({ eqv = true })
  local A = W.A
  local st = A.state(1)
  local e = st.eqv[15]
  check(e and ((e.a == W.hab.id and e.b == 0) or (e.b == W.hab.id and e.a == 0)), string.format("the Equalise Valve on the hab's east wall joins the hab and the outside (%s / %s)", e and e.a, e and e.b))
  local p0 = A.airOf(1, W.hab.id).p
  local tq = A.state(1).tanks[12]
  A.setEqualise(1, 15, true)
  for i = 1, 60 do W.frame(1.0)
    if os.getenv("DBG") and i % 10 == 1 then
      for _, n in ipairs(A.state(1).nets or {}) do print("net", table.concat(n.rooms, ","), "V", n.V, "tau", n.tau, "slow", n.slow, "F", n.F, "open", n.openings, "Gv", n.Gv) end
      print("p", A.airOf(1, W.hab.id).p, "q", A.state(1).tanks[12], "feed", A.state(1).air[W.hab.id].f)
    end
  end
  local q = A.airOf(1, W.hab.id)
  local want = p0 * math.exp(-0.25 / W.hab.m3 * 60)
  check(q.venting and rel(q.p, want, 0.02) and math.abs(A.state(1).tanks[12] - tq) < 1e-9, string.format("open to the moon it bleeds the hab at the valve's rate (%.3f atm after a minute, the formula %.3f), its regulator standing down (%.1f m³ kept)", q.p, want, A.state(1).tanks[12]))
  local cause = q.causes and q.causes[1] or ""
  check(cause:find("Equalise Valve", 1, true), "the leak is named: " .. tostring(cause))
end

-- ── THE AIRLOCK KEEPS ITS AIR ───────────────────────────────────────────────
local function cycle_out(W, before)
  local A = W.A
  W.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W.frame(0.1) end
  W.at(1.6, 1.0, 0)
  for _ = 1, 400 do W.frame(0.1, { [9] = 1 }) end
  W.at(0, 1.0, 0)
  if before then before() end
  local both, t, pmin = false, 0, 1
  local C = A.chamberOf(1, W.ch.id)
  local n0 = nil
  for _ = 1, 3000 do
    W.frame(0.1, { [9] = 1, [3] = 1 })
    t = t + 0.1
    if not n0 and (W.doors[9] or 0) < 0.02 then local a = A.airOf(1, W.ch.id); n0 = a.p * W.ch.m3; t = 0 end
    if (W.doors[3] or 0) > 0.02 and (W.doors[9] or 0) > 0.02 then both = true end
    pmin = math.min(pmin, A.airOf(1, W.ch.id).p)
    if (W.doors[3] or 0) > 0.99 then break end
  end
  local a = A.airOf(1, W.ch.id)
  local a = A.airOf(1, W.ch.id); C = A.chamberOf(1, W.ch.id)
  n0 = (C.saved or 0) + (C.vented or 0) + a.p * W.ch.m3
  return { t = t, n0 = n0, saved = C.saved or 0, vented = C.vented or 0, both = both, pmin = pmin, C = C }
end
do
  local W = scene({ receiver = true })
  local A = W.A
  local r = cycle_out(W)
  local q = A.state(1).recv[13]
  local inRec = q.N + q.x + q.c
  check(not r.both and (W.doors[3] or 0) > 0.99, "out through the airlock: never both doors open")
  check(r.n0 > 7 and rel(inRec, r.saved, 1e-9) and inRec / r.n0 > 0.85, string.format("its pump put %.1f of the chamber's %.1f atm·m³ into the receiver (%.0f %%)", inRec, r.n0, 100 * inRec / math.max(r.n0, 1e-9)))
  check(r.vented / r.n0 < 0.13 and r.vented > 0, string.format("only what was under the pump's 0.1 atm floor was vented (%.2f atm·m³, %.0f %%)", r.vented, 100 * r.vented / r.n0))
  -- the pump-down's time follows from the volume: V / S · ln(p0 / 0.1), plus the last of it vented
  local tp = W.ch.m3 / A.PUMP_S * math.log((r.n0 / W.ch.m3) / A.P_RESID)
  check(r.t >= tp * 0.9 and r.t < tp + 40, string.format("a %.1f m³ chamber took %.0f s (its pump alone: %.0f s at %.1f m³/s)", W.ch.m3, r.t, tp, A.PUMP_S))
  local pump_kw = A.gridAux(1, 3)
  check(pump_kw == 0, "the pump draws nothing once it's done")
  -- and back in: the receiver bleeds back first
  W.at(-1.8, 1.0, 0)
  for _ = 1, 40 do W.frame(0.1, { [3] = 1 }) end
  W.at(0, 1.0, 0)
  local back0 = q.N + q.x + q.c
  for _ = 1, 900 do
    W.frame(0.1, { [3] = 1, [9] = 1 })
    if (W.doors[9] or 0) > 0.99 then break end
  end
  local back1 = q.N + q.x + q.c
  check((W.doors[9] or 0) > 0.99 and back0 - back1 > 5, string.format("back in: the receiver gave %.1f atm·m³ back to the chamber before the hab topped it up", back0 - back1))
  -- a bigger chamber takes longer: the same pump on a chamber twice the size
  check(math.abs(A.equaliseTime(9, nil, A.PUMP_S, 1, A.P_RESID) * 2 - A.equaliseTime(18, nil, A.PUMP_S, 1, A.P_RESID)) < 1e-9, "twice the chamber, twice the pump-down")
end
do
  -- no power: the cycle vents the chamber and says so
  local W = scene({ receiver = true, power = false })
  local A = W.A
  local r = cycle_out(W)
  local q = A.state(1).recv[13]
  local said = false
  for _, c in ipairs(W.captions) do if c:find("NO POWER", 1, true) then said = true end end
  check((W.doors[3] or 0) > 0.99 and (q.N + q.x + q.c) == 0 and r.vented > 0.9 * r.n0, string.format("with the power off the airlock still cycles, but vents its air (%.1f of %.1f atm·m³ lost)", r.vented, r.n0))
  check(said, "and says why (NO POWER for its pump)")
  -- a full receiver: vents, and says so
  local W2 = scene({ receiver = true })
  local A2 = W2.A
  local r2 = cycle_out(W2, function() A2.state(1).recv[13] = { N = 24 * 0.79, x = 24 * 0.21, c = 0 } end)
  local said2 = false
  for _, c in ipairs(W2.captions) do if c:find("FULL", 1, true) then said2 = true end end
  check((W2.doors[3] or 0) > 0.99 and r2.vented > 0.9 * r2.n0 and said2, string.format("a full receiver: the airlock vents the chamber and says the receiver is FULL (%.1f atm·m³ lost)", r2.vented))
end

-- ── THE SUIT RULE ───────────────────────────────────────────────────────────
do
  local W = scene({ receiver = true, helmet = false })
  local A = W.A
  -- in the chamber with the helmet off: it won't depressurise for the outer door
  W.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W.frame(0.1) end
  W.at(1.6, 1.0, 0)
  for _ = 1, 400 do W.frame(0.1, { [9] = 1 }) end
  W.at(0, 1.0, 0)
  for _ = 1, 300 do W.frame(0.1, { [9] = 1, [3] = 1 }) end
  local pc = A.airOf(1, W.ch.id).p
  check((W.doors[3] or 0) < 0.02 and pc > 0.8, string.format("helmet off in the chamber: it won't cycle to vacuum (outer door shut, chamber %.2f atm)", pc))
  check(A.lastSuitRefusal and A.lastSuitRefusal.uid == 3, "the refusal is the outer door's")
  local told = false
  for _, b in ipairs(W.big) do if b:find("SUIT", 1, true) and b:find("helmet on", 1, true) then told = true end end
  check(told, "and the crew are told to put the helmet on")
  W.setHelmet(true)
  for _ = 1, 1200 do W.frame(0.1, { [9] = 1, [3] = 1 }); if (W.doors[3] or 0) > 0.99 then break end end
  check((W.doors[3] or 0) > 0.99, "helmet on, it cycles and the outer door opens")
  -- a plain door to the moon, helmet off: refused even when forced
  local W2 = scene({ helmet = false })
  local A2 = W2.A
  W2.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W2.frame(0.1) end
  A2.forceOpen(1, 8)
  check(A2.gate(1, 8, 1) == 0, "helmet off: the hab's door to the moon won't open for them, forced or not")
  W2.setHelmet(true)
  check(A2.gate(1, 8, 1) == 1, "helmet on (and forced): it opens")
end

-- ── FORCING: a warning, the gust, the pull, the seal ───────────────────────
do
  local W = scene({ receiver = true })
  local A = W.A
  W.at(2.2, 1.0, 0.6)
  for _ = 1, 3 do W.frame(0.1) end
  A.seedRandom(7)
  local secs = A.forceSecs(1, 8)
  check(secs >= A.WARN_S and secs > 8, string.format("forcing a door against 1 atm takes %.1f s (a warning's worth at least)", secs))
  A.warnVent(1, 8, "the Door Wall is being forced", secs)
  check(A.lastWarning and A.lastWarning.crew and W.big[#W.big]:find("VENTING IN", 1, true), "the crew in the hab are warned first: " .. tostring(W.big[#W.big]))
  local ok, dmg = A.forceDoor(1, 8)
  check(ok and dmg > 0 and A.sealOf(1, 8) == dmg, string.format("forced: its seal is damaged (%.0f %%)", (dmg or 0) * 100))
  local b = A.lastBurst
  check(b and #W.fx == 1 and W.fx[1].key == "VentBurst" and b.dp > 0.9, "the gust: a VentBurst effect through the doorway")
  -- the hab is on the door's back (-Z): the gust goes out along +Z
  check(b and b.dz > 0.99, string.format("blowing out of the high side (%.2f, %.2f, %.2f)", b and b.dx or 0, b and b.dy or 0, b and b.dz or 0))
  local pl = W.pulls[1]
  check(pl and pl[3] > 0.5 and pl[4] > 0, string.format("the crew beside it are pulled toward the opening (%.2f m/s)", pl and math.sqrt(pl[1] ^ 2 + pl[2] ^ 2 + pl[3] ^ 2) or 0))
  check(A.gate(1, 8, 1) == 1, "and it opens for them")
  W.doors[8] = 1; A.doorMoved(1, 8)
  for _ = 1, 40 do W.frame(0.25) end
  check(A.airOf(1, W.hab.id).p < 0.2, "the hab vents through it")
  W.doors[8] = 0; A.doorMoved(1, 8)
  for _ = 1, 600 do W.frame(0.5) end
  local q = A.airOf(1, W.hab.id)
  local leak = false
  for _, c in ipairs(q.causes or {}) do if c:find("seal leaks", 1, true) then leak = true end end
  check(q.venting and leak, string.format("shut again, its damaged seal leaks (%s; %.2f atm)", tostring(q.causes and q.causes[1]), q.p))
  -- (the pull is gentle and scales with Δp)
  local W3 = scene()
  W3.at(2.2, 1.0, 0.6); for _ = 1, 3 do W3.frame(0.1) end
  W3.A.state(1).tanks[12] = 0
  W3.A.setEqualise(1, 8, true)
  for _ = 1, 60 do W3.frame(1.0) end
  W3.A.setEqualise(1, 8, false)
  W3.A.forceDoor(1, 8)
  local p3 = W3.pulls[1]
  local k1 = pl and math.sqrt(pl[1] ^ 2 + pl[2] ^ 2 + pl[3] ^ 2) or 0
  local k3 = p3 and math.sqrt(p3[1] ^ 2 + p3[2] ^ 2 + p3[3] ^ 2) or 0
  check(k1 < 4 and k3 < k1, string.format("gentle, and less at less Δp (%.2f m/s at 1 atm, %.2f once partly bled)", k1, k3))
  -- the repair
  A.repairSeal(1, 8)
  check(A.sealOf(1, 8) == 0, "re-seated, the seal holds again")
  for _ = 1, 200 do W.frame(1.0) end
  local q2 = A.airOf(1, W.hab.id)
  check(not q2.venting and q2.p > 0.9, string.format("and the regulator brings the hab back (%.2f atm)", q2.p))
end

-- ── a failing seal ──────────────────────────────────────────────────────────
do
  local W = scene()
  local A = W.A
  W.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W.frame(0.1) end
  W.pstate[8] = { seal = 0.8 }
  A.state(1).netsDirty = true
  for _ = 1, 15 do W.frame(0.1) end
  check(A.lastWarning and A.lastWarning.why:find("failing", 1, true), "a badly damaged seal with 1 atm on it: SEAL FAILING, the crew warned")
  local t = 0
  while not (W.pstate[8] and W.pstate[8].blown) and t < 20 do W.frame(0.1); t = t + 0.1 end
  check(W.pstate[8].blown and t > A.WARN_S - 1.5 and t < A.WARN_S + 1.5, string.format("…then it blows, %.1f s after the warning", t + 1.5))
  for _ = 1, 60 do W.frame(0.5) end
  check(A.airOf(1, W.hab.id).p < 0.3, "and the hab vents through it")
end

-- ── the O2 Generator's water ────────────────────────────────────────────────
do
  local W = scene({ gen = true })
  local A = W.A
  local st = A.state(1)
  check(st.cells[14] > 19.9, string.format("a new O2 Generator's water cell comes full (20 L; %.3f after the first minute)", st.cells[14]))
  W.at(2.2, 1.0, 0.2)
  for _ = 1, 3 do W.frame(0.1) end
  -- burn the hab's O2 down so it runs flat out
  local Ah = st.air[W.hab.id]
  Ah.x = Ah.x * 0.5
  st.netsDirty = true
  A.advanceNow()
  local w0, m0, h0 = st.cells[14], st.made[14] or 0, st.h2[14] or 0
  for _ = 1, 600 do W.frame(1.0) end
  A.advanceNow()
  local made = (st.made[14] or 0) - m0
  local used = w0 - st.cells[14]
  local h2 = (st.h2[14] or 0) - h0
  check(made > 0 and rel(used, made * A.KW, 1e-6) and rel(h2, made * A.KH, 1e-6),
    string.format("it made %.4f atm·m³ of O2 from %.3f kg of water and %.4f kg of H2 (2 H2O → 2 H2 + O2)", made, used, h2))
  check(rel(A.KW / A.KH, 36.031 / 4.032, 1e-9), "water to hydrogen by mass: 36 to 4")
  -- dry: no O2
  st.cells[14] = 0.001
  st.netsDirty = true
  local x0 = st.air[W.hab.id].x
  for _ = 1, 600 do W.frame(1.0) end
  check(st.cells[14] == 0 and A.genDraw(1, 14) == 0, "its cell dry, it stops (and draws no water)")
  local put = A.fillCell(1, 14, 50)
  check(near(put, 20, 1e-9) and st.cells[14] == 20, "the fluid network fills it, never past its 20 L")
end

if #failures > 0 then
  print("FAIL smoke_pressure: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_pressure: %d checks passed", passed))
