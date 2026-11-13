-- SMOKE: the airlock cycle from every side (playtest 2026-11-11: "airlock
-- seems to only open door from one side", "sometimes it just takes forever to
-- open, others it won't open at all", Graveyard: "the first door opened and
-- the second one wouldn't"), against the real parts_kit, parts_base,
-- kit_snap, rooms and room_air on a stub engine (smoke_pressure's layout: an
-- airlock chamber with an Airlock Wall out and a Door Wall in, a hab, a door
-- to the moon, an Air Tank Rack; the outside is vacuum).
--
--   * FROM OUTSIDE: the outer door opens to the crew; in the chamber the outer
--     door shuts, the chamber fills from the hab, the inner door opens: in
--     seconds, never both doors open;
--   * FROM INSIDE (the hab): the inner door, then the pump-down, the outer;
--   * FROM THE CHAMBER: found in it with every door shut after coming in from
--     outside, it cycles ON to the hab (it used to guess the hab's door as the
--     way in and cycle back out); the panel's "Cycle to this door" from in
--     the chamber or anywhere;
--   * the door the crew came in by never shuts on them while they stand in it;
--   * the panel's states: CYCLING, EQUALISING, READY (and CLOSING, STANDBY);
--   * the MANUAL OVERRIDE opens a door against the pressure, with a warning;
--   * the cycle's sounds (the hiss, the pump, the bell) and vapour puffs.
--
--   luajit solar/tests/smoke_airlock.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

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
local PI2 = math.pi / 2
local function P(uid, id, x, y, z, yaw) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0 } end

local OUTER, INNER = 3, 9
local function scene(opts)
  opts = opts or {}
  local store, SS = {}, {}
  for k, v in pairs(S) do SS[k] = v end
  local planet = { x = 1000, y = 0, z = 0, name = "Moon" }
  local agency = 1000.0
  local doors = {}
  local astro = { x = 0, y = 0, z = 0, valid = true }
  local bp = { P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0),
    P(3, "airlockWall.steel", -1, 0.2, 0, PI2), P(4, "wall.steel", 3, 0.2, 0, PI2),
    P(5, "wall.steel", 0, 0.2, -1, 0), P(6, "wall.steel", 2, 0.2, -1, 0), P(7, "wall.steel", 0, 0.2, 1, 0), P(8, "doorWall.steel", 2, 0.2, 1, 0),
    P(9, "doorWall.steel", 1, 0.2, 0, PI2), P(10, "floor.steel", 0, 2.4, 0), P(11, "floor.steel", 2, 2.4, 0),
    P(12, "airTank.steel", 2.4, 0.2, -0.5) }
  local rec = { id = 1, b = "Moon", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp }
  local pstate = {}
  SS.structures = { version = 1, list = function() return { rec } end, get = function(id) if id == 1 then return rec end end,
    partState = function(sid, uid) return pstate[uid] end, setPartState = function(sid, uid, t) pstate[uid] = t end }
  SS.kit_live = { doorOpen = function(sid, uid) return doors[uid] or 0 end }
  SS.base_grid = { gridOfStruct = function() return { id = 1, bases = { 1 } } end,
    model = function() return { sources = 1, C = 10 } end, status = function() return { short = 0, stored = 5 } end, markDirty = function() end }
  SS.deployables = { agencyClock = function() return agency end }
  SS.climate = { worldOf = function() return { atmo = opts.atmo or 0, radius = 500 } end }
  local captions, logs = {}, {}
  SS.big_caption = { show = function() end }
  SS.sfx = { caption = function(t) captions[#captions + 1] = t end }
  SS.suit = { helmetOn = function() return true end }
  SS.base_log = { add = function(sid, k, txt) logs[#logs + 1] = txt end }
  SS.planet_walker = { onFoot = true, pull = function() end }
  local fx = {}
  SS.vfx = { emit = function(key, x, y, z, o) fx[#fx + 1] = { key = key, x = x, y = y, z = z, o = o } end }
  SS.kit_snap = setmetatable({ frameOf = function(r) return { O = { x = r.x, y = r.y, z = r.z }, R = { x = 1, y = 0, z = 0 }, U = { x = 0, y = 1, z = 0 }, F = { x = 0, y = 0, z = 1 } } end }, { __index = S.kit_snap })
  local sounds = {}
  local E = env(store, SS, {
    space = { body = function() return planet end, dominant = function() return "Moon" end },
    find = function(n) if n == "Astronaut" then return astro end end,
    audio = { play = function(path) sounds[#sounds + 1] = path; return { stop = function() end, setVolume = function() end, setPitch = function() end } end },
    app = { wallClock = os.clock },
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  })
  local A = load_script("room_air.lua", E)
  local W = { A = A, doors = doors, captions = captions, sounds = sounds, fx = fx, logs = logs }
  function W.at(lx, ly, lz) astro.x, astro.y, astro.z = planet.x + rec.x + lx, planet.y + rec.y + ly, planet.z + rec.z + lz end
  -- one frame: kit_live's door step for the doors in `wants` (a leaf takes 1 s)
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
  W.at(5, 1.0, 5)
  for _ = 1, 10 do W.frame(0.1) end
  local st = A.state(1)
  W.ch = RL.roomAt(st.R, 0, 1.2, 0)
  W.hab = RL.roomAt(st.R, 2, 1.2, 0)
  for _ = 1, 600 do W.frame(0.1) end        -- the tank brings the hab up
  return W
end
local function p(W, r) return W.A.airOf(1, r.id).p end
-- run frames until fn() or `secs`; → seconds taken | nil, both doors ever open
local function run(W, secs, wants, fn, seen)
  local t, both = 0, false
  while t < secs do
    W.frame(0.1, wants)
    t = t + 0.1
    if (W.doors[OUTER] or 0) > 0.02 and (W.doors[INNER] or 0) > 0.02 then both = true end
    if seen then local o = W.A.airlockStatus(1, seen.uid); if o then seen[o.label] = true end end
    if fn() then return t, both end
  end
  return nil, both
end

-- ── FROM OUTSIDE, then OUT FROM THE HAB ──────────────────────────────────────
do
  local W = scene()
  local A = W.A
  check(W.ch and W.ch.airlock and W.hab and p(W, W.hab) > 0.9 and p(W, W.ch) < 0.05,
    string.format("the chamber is an airlock at the moon's vacuum (%.2f atm), the hab at %.2f atm", p(W, W.ch), p(W, W.hab)))
  -- outside, by the outer door
  W.at(-1.8, 1.0, 0)
  local t1, b1 = run(W, 10, { [OUTER] = 1 }, function() return (W.doors[OUTER] or 0) > 0.99 end)
  check(t1 and t1 < 2.0 and not b1, string.format("from outside the outer door opens at once (the chamber holds the outside's vacuum): %.1f s", t1 or -1))
  -- into the chamber: the crew is within reach of both doors
  W.at(0, 1.0, 0)
  local seen = { uid = INNER }
  local t2, b2 = run(W, 60, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 end, seen)
  check(t2 and not b2, string.format("in the chamber: the outer door shuts, the chamber fills, the inner door opens (%.1f s), never both open", t2 or -1))
  check(t2 and t2 < 12, string.format("a %.1f m³ lock fills in seconds: the walk-in takes %.1f s (door 1 s, fill, door 1 s)", W.ch.m3, t2 or -1))
  check(math.abs(p(W, W.ch) - p(W, W.hab)) <= 0.05, string.format("…to the hab's own pressure (%.2f / %.2f atm)", p(W, W.ch), p(W, W.hab)))
  local Cf = A.chamberOf(1, W.ch.id)
  local ah = A.airOf(1, W.hab.id)
  check(ah.p > 0.9 and ah.breathable and (Cf.racked or 0) > 5,
    string.format("filled from the hab's Air Tank Rack (%.1f atm·m³), so the hab stays breathable (%.2f atm)", Cf.racked or 0, ah.p))
  check(seen.EQUALISING and seen.READY and seen.CLOSING, string.format("the inner door's panel read CLOSING, EQUALISING, then READY (%s)",
    table.concat((function() local l = {} for k in pairs(seen) do if k ~= "uid" then l[#l + 1] = k end end table.sort(l) return l end)(), ", ")))
  local hissed, chimed = false, false
  for _, sp in ipairs(W.sounds) do
    if sp:find("hiss_cylinder", 1, true) then hissed = true end
    if sp:find("airlock_chime", 1, true) then chimed = true end
  end
  check(hissed and chimed, "the cycle hissed and the bell struck when it was done")
  local fog = 0
  for _, f in ipairs(W.fx) do if f.key == "LockFog" then fog = fog + 1 end end
  check(fog >= 3, string.format("vapour in the chamber as the air rushed in (%d puffs)", fog))
  -- through to the hab, then let the regulator make up the chamber's share
  W.at(2.2, 1.0, 0.2)
  run(W, 3, { [INNER] = 0 }, function() return false end)
  run(W, 60, {}, function() return false end)
  -- OUT: from the hab by the inner door
  W.at(1.6, 1.0, 0)
  local t3 = run(W, 10, { [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 end)
  check(t3 and t3 < 6.0, string.format("from inside the hab the inner door opens (the chamber brought to the hab's pressure first): %.1f s", t3 or -1))
  W.at(0, 1.0, 0)
  local seen2 = { uid = OUTER }
  local n_fx = #W.fx
  local t4, b4 = run(W, 60, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[OUTER] or 0) > 0.99 end, seen2)
  check(t4 and not b4 and t4 < 14, string.format("in the chamber: the inner door shuts, the pump draws it down, the outer door opens (%.1f s), never both open", t4 or -1))
  check(seen2.CYCLING and seen2.READY, "the outer door's panel read CYCLING, then READY")
  local vent = 0
  for i = n_fx + 1, #W.fx do if W.fx[i].key == "LockVent" then vent = vent + 1 end end
  check(vent >= 1, string.format("the last of the chamber went overboard in a puff of frost at the vent (%d)", vent))
  local pumped = false
  for _, sp in ipairs(W.sounds) do if sp:find("pump_motor", 1, true) then pumped = true end end
  check(pumped, "the pump's motor ran while it pumped")
  check(A.lastCycleSecs and A.lastCycleSecs < 10, string.format("the pump-down itself: %.1f s (V/S · ln 10 = %.1f s, then the vent)", A.lastCycleSecs or -1, W.ch.m3 / A.PUMP_S * math.log(10)))
end

-- ── FROM THE CHAMBER: in it with every door shut, having come from outside ───
do
  local W = scene()
  local A = W.A
  -- the outer door opened to the crew outside, then they stepped in as it shut
  W.at(-1.8, 1.0, 0)
  run(W, 3, { [OUTER] = 1 }, function() return (W.doors[OUTER] or 0) > 0.99 end)
  run(W, 3, { [OUTER] = 0 }, function() return (W.doors[OUTER] or 0) < 0.001 end)
  W.at(5, 1.0, 5)
  run(W, 1, {}, function() return false end)
  -- (now found in the chamber, every door shut: crew.rid caught up late)
  W.at(0, 1.0, 0)
  local t, both = run(W, 30, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 or (W.doors[OUTER] or 0) > 0.5 end)
  check(t and (W.doors[INNER] or 0) > 0.99 and (W.doors[OUTER] or 0) < 0.02 and not both,
    string.format("found in the chamber with every door shut after coming in from outside, it cycles on to the hab (inner %.2f, outer %.2f)", W.doors[INNER] or 0, W.doors[OUTER] or 0))
end

-- ── the door never shuts on a crew member in it ──────────────────────────────
do
  local W = scene()
  local A = W.A
  W.at(-1.8, 1.0, 0)
  run(W, 3, { [OUTER] = 1 }, function() return (W.doors[OUTER] or 0) > 0.99 end)
  -- standing in the outer doorway, inside the chamber's cells
  W.at(-0.75, 1.0, 0)
  local _, crid = nil, nil
  run(W, 2, { [OUTER] = 1, [INNER] = 1 }, function() return false end)
  _, crid = A.crewRoom()
  local o = A.airlockStatus(1, INNER)
  check(crid == W.ch.id and (W.doors[OUTER] or 0) > 0.99 and o and o.label == "CLOSING",
    string.format("in the outer doorway (in room %s) the door stays open, the inner panel says %s", tostring(crid), o and o.label or "?"))
  W.at(0.1, 1.0, 0)
  local t = run(W, 30, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 end)
  check(t and (W.doors[OUTER] or 0) < 0.02, string.format("a step further in, it shuts and cycles to the hab (%.1f s)", t or -1))
end

-- ── the panel: cycle to a door from anywhere; the override ──────────────────
do
  local W = scene()
  local A = W.A
  -- (the crew in the hab, away from the doors: the chamber at vacuum)
  W.at(2.6, 1.0, -0.3)
  local ok = A.cycleTo(1, INNER)
  local t = run(W, 30, {}, function() local o = A.airlockStatus(1, INNER); return o and o.label == "READY" end)
  check(ok and t and t < 10 and math.abs(p(W, W.ch) - p(W, W.hab)) < 0.05,
    string.format("the inner panel's Cycle key from across the hab fills the chamber (%.1f s, %.2f / %.2f atm), READY", t or -1, p(W, W.ch), p(W, W.hab)))
  -- in the chamber with the inner door shut, its panel's key sends it back out
  run(W, 60, {}, function() return false end)
  W.at(1.6, 1.0, 0)
  run(W, 3, { [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 end)
  W.at(0, 1.0, 0)
  local t2 = run(W, 30, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[OUTER] or 0) > 0.99 end)
  check(t2, "walked into the chamber from the hab, it cycles out")
  A.cycleTo(1, INNER)
  local t3 = run(W, 30, { [OUTER] = 1, [INNER] = 1 }, function() return (W.doors[INNER] or 0) > 0.99 end)
  check(t3 and (W.doors[OUTER] or 0) < 0.02, string.format("changed their mind in the chamber: its inner panel's key cycles back in (%.1f s)", t3 or -1))
  -- the override: the chamber at vacuum, the inner door forced open against the hab
  W.at(2.2, 1.0, 0.2)
  run(W, 2, { [INNER] = 0 }, function() return false end)
  A.cycleTo(1, OUTER)
  run(W, 30, {}, function() local o = A.airlockStatus(1, OUTER); return o and o.label == "READY" end)
  W.at(1.6, 1.0, 0)
  check(A.gate(1, INNER, 1) == 0, "by the inner door with the chamber at vacuum: it holds")
  local ok2, warn = A.overrideDoor(1, INNER)
  check(ok2 and warn and warn:find("OVERRIDE", 1, true) and A.gate(1, INNER, 1) == 1,
    "the override is never refused: it opens, and says what it does: " .. tostring(warn))
  check(A.airlockStatus(1, INNER).label == "OVERRIDE", "the panel says OVERRIDE")
  local logged = false
  for _, l in ipairs(W.logs) do if l:find("overridden", 1, true) then logged = true end end
  check(logged, "the base log records the override")
end

-- ── (playtest 11-13, Dust Season) a stale hab still lets you in ─────────────
-- The chamber full of a CO2 world's gas, the hab behind it at 3 % CO2 (its
-- scrubbers behind): the purge used to refill from the hab, read the refill as
-- foreign and purge again, forever (CYCLING 0.01 atm). One purge per cycle.
do
  local W = scene()
  local A = W.A
  W.at(2.6, 1.0, -0.3)
  local st = A.state(1)
  local C, H = st.air[W.ch.id], st.air[W.hab.id]
  local Vc, Vh = W.ch.m3, W.hab.m3
  C.N, C.x, C.c = 0, 0, 0.5 * Vc          -- 0.5 atm of pure CO2
  local hp = p(W, W.hab)
  H.N, H.x, H.c = hp * Vh * 0.76, hp * Vh * 0.21, hp * Vh * 0.03
  A.cycleTo(1, INNER)
  local seen = { uid = INNER }
  local minp = 9
  local t0 = run(W, 90, {}, function() minp = math.min(minp, p(W, W.ch)); return minp < 0.05 end)
  local t = run(W, 90, {}, function() local o = A.airlockStatus(1, INNER); return o and o.label == "READY" end, seen)
  C = A.state(1).air[W.ch.id]
  local tot = C.N + C.x + C.c
  check(t0 and t and math.abs(p(W, W.ch) - p(W, W.hab)) < 0.05 and tot > 0 and C.c / tot < 0.1,
    string.format("CO2 in the chamber, a hab at 3 %% CO2: purged once, then READY (%.1f s, %.2f / %.2f atm, CO2 %.1f %%)",
      t or -1, p(W, W.ch), p(W, W.hab), tot > 0 and 100 * C.c / tot or -1))
end

-- ── a bigger chamber takes longer, in proportion; a small one is quick ──────
do
  local A0 = load_script("room_air.lua", env({}, S))
  local t9 = A0.equaliseTime(9, nil, A0.PUMP_S, 1, A0.P_RESID)
  check(t9 < 8 and math.abs(A0.equaliseTime(18, nil, A0.PUMP_S, 1, A0.P_RESID) - 2 * t9) < 1e-9,
    string.format("a 9 m³ lock pumps down to 0.1 atm in %.1f s, an 18 m³ one in twice that", t9))
end

if #failures > 0 then
  print(string.format("FAIL smoke_airlock: %d of %d", #failures, #failures + passed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print(string.format("smoke_airlock: %d checks passed", passed))
