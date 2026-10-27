-- SMOKE: SUSTAINED relay coverage (the sky goals) — the rules in
-- scripts/electronics.lua ("sustained coverage") and the history comms.lua
-- keeps per world. No engine: the scene, the save, space and the satellites
-- (circular orbits, exact) are stubs.
--
--   * the rules: window from the relay periods (5 to 30 min), the grid step,
--     the warp plan (skip what a window forgets, spread past the budget), the
--     stats (time-weighted, `full` only on a full window), the save string,
--     the gap patches, the footprint;
--   * a LUCKY SPIKE: one satellite on a polar orbit lifts the snapshot to
--     ~30 % while it is over the base, but nothing is held — no latch;
--   * a STEADY constellation (five relays round the equator) is held, and
--     only latches once a full window of history exists;
--   * one DIP (the ground station down for one snapshot) is tolerated;
--   * WARP: the same constellation at ×200 and ×2000 (frames of 3 and 33 s
--     of game time) reads within a few % of ×1;
--   * SAVE AND LOAD: a fresh comms on a restarted game clock reads the same
--     numbers from the save and carries on; a satellite lost wipes nothing.
--
--   luajit solar/tests/smoke_sustain.lua     (SUSTAIN_VERBOSE=1 for numbers)

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local VERBOSE = os.getenv("SUSTAIN_VERBOSE")
local function say(...) if VERBOSE then print(string.format(...)) end end

local E = setmetatable({}, { __index = _G })
do
  local chunk = assert(loadfile("solar/scripts/electronics.lua"))
  setfenv(chunk, E)
  chunk()
end
local S = E.COMMS.sustain

-- ── the rules ───────────────────────────────────────────────────────────────
do
  local W, h = E.sustainWindow({})
  check(W == 300 and math.abs(h - 300 / 48) < 1e-9, "no satellites: a 5-minute window, 48 snapshots")
  W, h = E.sustainWindow({ 560, 200 })
  check(math.abs(W - 560) < 1e-9, "the window is the longest period (560 s)")
  check(math.abs(h - 200 / 24) < 1e-9, "...the step resolves the fastest relay (24 to its orbit)")
  W, h = E.sustainWindow({ 3 * 3600 })
  check(W == S.maxWindow and math.abs(h - S.maxWindow / 48) < 1e-9, "a far relay's period is clamped to 30 min")
  W, h = E.sustainWindow({ 1800, 30 })
  check(math.abs(h - 1800 / S.maxPerWindow) < 1e-9, "...and the step never packs more than 240 into a window")
  local P = E.orbitPeriod(2000, 0, 0, 0, 0, math.sqrt(1e6 / 2000), 1e6)
  check(P and math.abs(P - 2 * math.pi * math.sqrt(2000 ^ 3 / 1e6)) < 1e-6, "orbitPeriod: a circular orbit")
  check(E.orbitPeriod(2000, 0, 0, 0, 0, 40, 1e6) == nil, "...nil on an escape")

  -- the plan
  local pl, last = E.sustainPlan(nil, 50, 10, 300, 4)
  check(#pl == 1 and pl[1].t == 50 and last == 50, "the first snapshot is taken at once")
  pl, last = E.sustainPlan(50, 55, 10, 300, 4)
  check(#pl == 0 and last == 50, "none before a step has passed")
  pl, last = E.sustainPlan(50, 85, 10, 300, 4)
  check(#pl == 3 and pl[1].t == 60 and pl[3].t == 80 and last == 80 and pl[1].w == 10, "every grid instant due, each a step")
  pl, last = E.sustainPlan(50, 50 + 200, 10, 300, 4)
  local sumw = 0
  for _, p in ipairs(pl) do sumw = sumw + p.w end
  check(#pl == 4 and last == 250 and math.abs(sumw - 200) < 1e-9 and math.abs(pl[4].t - 250) < 1e-9
    and math.abs(pl[2].t - pl[1].t - 50) < 1e-9, "past the budget: spread evenly, the weights add up to the span")
  pl, last = E.sustainPlan(50, 50 + 5000, 10, 300, 4)
  sumw = 0
  for _, p in ipairs(pl) do sumw = sumw + p.w end
  check(#pl == 4 and pl[1].t > 5050 - 300 and math.abs(sumw - 300) < 1e-9,
    "a jump past a whole window samples only the last window")

  -- stats: time-weighted, full only on a full window
  local tr = E.sustainNew(4)
  local ON, OFF, HALF = { 1, 1, 1, 1 }, { 0, 0, 0, 0 }, { 1, 1, 0, 0 }
  for k = 1, 10 do E.sustainAdd(tr, k * 10, 10, ON) end
  local st = E.sustainStats(tr, 100, 200)
  check(st.held == 100 and not st.full and st.sustained == 1, "half a window: held 100 s, all held, not full")
  for k = 11, 20 do E.sustainAdd(tr, k * 10, 10, k == 15 and OFF or HALF) end
  st = E.sustainStats(tr, 200, 200)
  check(st.full and st.held == 200, "a full window")
  check(math.abs(st.frac[1] - 190 / 200) < 1e-9 and math.abs(st.frac[3] - 100 / 200) < 1e-9, "fractions are time-weighted")
  check(st.ok[1] and not st.ok[3] and st.sustained == 0.5, "held at ≥ 75 %: two of four")
  check(E.sustainMeets(st, 0.5) and not E.sustainMeets(st, 0.51), "sustainMeets on a full window")
  check(not E.sustainMeets(E.sustainStats(tr, 100, 200), 0.1), "...never on a part one")
  check(not E.sustainAdd(tr, 200, 10, ON), "a snapshot no newer than the last is ignored")
  E.sustainPrune(tr, 150)
  check(#tr.snaps == 5 and tr.snaps[1].t == 160, "prune drops what ended before")

  -- the save string
  local big = E.sustainNew(200)
  local f1, f2 = {}, {}
  for i = 1, 200 do f1[i] = (i % 3 == 0) and 1 or 0; f2[i] = (i % 7 < 4) and 1 or 0 end
  for k = 1, 96 do E.sustainAdd(big, 1000 + k * 6.25, 6.25, (k % 5 == 0) and f2 or f1) end
  local enc = E.sustainEncode(big, big.snaps[#big.snaps].t)
  check(#enc < 4500, "96 snapshots of 200 samples fit in " .. #enc .. " characters")
  local back = E.sustainDecode(enc, 0, 200)
  check(back and #back.snaps == 96, "the history decodes")
  local same = back ~= nil
  for k = 1, 96 do
    local a, b = big.snaps[k], back.snaps[k]
    if math.abs((a.t - big.snaps[96].t) - b.t) > 0.051 or math.abs(a.w - b.w) > 0.051 then same = false end
    for i = 1, 200 do if a.f[i] ~= b.f[i] then same = false end end
  end
  check(same, "...to the same flags, ages and weights (against a restarted clock)")
  check(E.sustainDecode(enc, 0, 100) == nil and E.sustainDecode("junk", 0) == nil, "a wrong grid or junk is refused")

  -- gaps
  local dirs = E.surfaceGrid(200)
  local ok = {}
  for i, u in ipairs(dirs) do ok[i] = not (u[2] > 0.6 or (u[2] < -0.7 and u[1] > 0)) end
  local g = E.sustainGaps(dirs, ok)
  check(#g.clusters == 2, "two separate gaps are two patches (got " .. #g.clusters .. ")")
  check(g.clusters[1].lat > 60 and g.clusters[1].n > g.clusters[2].n, "...the biggest first, centred on the north cap")
  check(g.clusters[2].lat < -60, "...the second in the south")

  -- footprint: horizon-limited high up, range-limited far out
  local R = 807
  local th = E.footprintAngle(R, 2000, 2.25e5)
  -- the horizon: the line may run down to `occlude` of the radius (grazing),
  -- from a receiver 1 m up to the relay
  local rc = R * E.COMMS.occlude
  local hz = math.acos(rc / (R + 1)) + math.acos(rc / 2000)
  check(math.abs(th - hz) < 0.01, string.format("a relay 2 km up sees to its horizon (%.1f° vs %.1f°)",
    math.deg(th), math.deg(hz)))
  check(E.footprintAngle(R, 2000, 2000) < th, "...a weak antenna less far")
  check(E.footprintAngle(R, 1e5, 2.25e5) == 0, "out of range: no footprint")
end

-- ── the stub world ──────────────────────────────────────────────────────────
-- Vever (r 807, mu 1e6) with its base on the EQUATOR (+X).
local R, MU = 807, 1e6
local VX, VY, VZ = 5.0e6, 0, 0
local BODIES = {
  { name = "Sol", x = 0, y = 0, z = 0, radius = 5000, mu = 1e12, soi = -1 },
  { name = "Vever", x = VX, y = VY, z = VZ, radius = R, mu = MU, soi = 3e4 },
}
local function body(n) for _, b in ipairs(BODIES) do if b.name == n then return b end end end
local STORE = {}
local save = {
  get = function(k, d) local v = STORE[k]; if v == nil then return d end return v end,
  set = function(k, v) STORE[k] = v end,
  delete = function(k) local had = STORE[k] ~= nil; STORE[k] = nil; return had end,
}
local GT = 0     -- the game clock (space.time)
local space = {
  bodies = function() return BODIES end,
  body = function(n) return body(n) end,
  time = function() return GT end,
  dominant = function(x, y, z)
    local v = body("Vever")
    local d = math.sqrt((x - v.x) ^ 2 + (y - v.y) ^ 2 + (z - v.z) ^ 2)
    return d < v.soi and "Vever" or "Sol"
  end,
}
local BF = { valid = true, sited = true, baseBody = "Vever", baseX = VX + R, baseY = VY, baseZ = VZ }

-- SATELLITES: circular orbits, exact at any game time. Each { a, phase,
-- e1, e2 (the plane), id, on }.
local SATS = {}
local function sat_state(s, t)
  local n = math.sqrt(MU / s.a ^ 3)
  local th = n * t + s.phase
  local c, sn = math.cos(th), math.sin(th)
  local px = s.a * (c * s.e1[1] + sn * s.e2[1])
  local py = s.a * (c * s.e1[2] + sn * s.e2[2])
  local pz = s.a * (c * s.e1[3] + sn * s.e2[3])
  local k = s.a * n
  return px, py, pz, k * (-sn * s.e1[1] + c * s.e2[1]), k * (-sn * s.e1[2] + c * s.e2[2]), k * (-sn * s.e1[3] + c * s.e2[3])
end
local VESSELS = {}
local function set_sats(list)
  SATS = list
  VESSELS = {}
  for _, s in ipairs(list) do
    local node = { id = s.id, valid = true, name = s.id }
    local v = { node = node, craftName = s.id }
    v.commsNode = function()
      local px, py, pz, vx, vy, vz = sat_state(s, GT)
      node.vx, node.vy, node.vz = vx, vy, vz
      return { x = VX + px, y = VY + py, z = VZ + pz, any = 2.25e5, relay = 2.25e5, rate = 12 }
    end
    VESSELS[#VESSELS + 1] = v
  end
end

local function new_comms()
  local env = setmetatable({}, { __index = _G })
  env.save, env.space = save, space
  env.time = 0
  env.log = function(m) if VERBOSE then print("log: " .. m) end end
  env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  env.find = function(n) if n == "Vever" then return { name = "Vever", valid = true } end return nil end
  env.findScript = function(k)
    if k == "electronics" then return E end
    if k == "base_facilities" then return BF end
    return nil
  end
  env.findScripts = function(k) if k == "vessel_controller" then return VESSELS end return {} end
  env.spawn = function(_, _, cb) local n = { valid = true }; function n:setUp() end; function n:destroy() end; cb(n) end
  local chunk = assert(loadfile("solar/scripts/comms.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = setmetatable({}, { __index = env.defaults })
  env.start({})
  return env
end

-- Run `secs` of game time in frames of `frame` real seconds at `warp`.
local function run(net, secs, warp, frame, each)
  frame, warp = frame or 0.25, warp or 1
  local t_end = GT + secs
  while GT < t_end - 1e-9 do
    GT = GT + frame * warp
    net.time = net.time + frame
    net.update({}, frame)
    if each then each(net.coverage("Vever")) end
  end
end

local EQ1, EQ2 = { 1, 0, 0 }, { 0, 0, -1 }      -- the equator
local PO1, PO2 = { 1, 0, 0 }, { 0, 1, 0 }       -- a polar orbit through the base
local A = 2000
local P = 2 * math.pi * math.sqrt(A ^ 3 / MU)    -- ~562 s
-- the constellation flies lower (a smaller footprint, ~53°: five round the
-- equator leave the poles open, and still see each other over the horizon) and faster than the 5-minute floor: its window is 300 s
local A4 = 1000
local P4 = 2 * math.pi * math.sqrt(A4 ^ 3 / MU)  -- ~199 s
local W4 = 300

-- ── a LUCKY SPIKE: one relay on a polar orbit ──────────────────────────────
do
  GT = 0
  set_sats({ { id = "solo", a = A, phase = 0, e1 = PO1, e2 = PO2 } })
  local net = new_comms()
  local peak, sky_now = 0, 0
  net.coverage("Vever")
  run(net, P * 2.2, 1, 0.5, function(c) peak = math.max(peak, c.sky); sky_now = c.sky end)
  local c = net.coverage("Vever")
  say("spike: snapshot peak %.3f, now %.3f, sustained %.3f, window %.0f s held %.0f s, gaps %d (%d patches)",
    peak, sky_now, c.sustained, c.window, c.held, c.gaps and c.gaps.n or -1, c.gaps and #c.gaps.clusters or -1)
  check(math.abs(c.window - P) < 1, string.format("the window is the satellite's orbit (%.0f s)", c.window))
  check(c.full, "a full window of history after two orbits")
  check(peak >= 0.25, string.format("the snapshot spikes while it is overhead (peak %.0f%%)", peak * 100))
  check(c.sustained < 0.12, string.format("...but almost nothing is HELD (%.0f%%)", c.sustained * 100))
  check(not E.sustainMeets({ full = c.full, sustained = c.sustained }, 0.25),
    "a goal at 25% the snapshot crossed does not latch")
  check(c.gaps and c.gaps.n > 150 and #c.gaps.clusters >= 1, "the gaps are most of the world")
  STORE["comms.sustain.Vever"] = nil
end

-- ── a STEADY constellation: five relays round the equator ──────────────────
local function five(phase0)
  local l = {}
  for k = 1, 5 do l[k] = { id = "eq" .. k, a = A4, phase = (phase0 or 0) + (k - 1) * math.pi * 2 / 5, e1 = EQ1, e2 = EQ2 } end
  return l
end

local steady_sustained
do
  GT = 1000
  set_sats(five())
  local net = new_comms()
  net.coverage("Vever")
  local half = net.coverage("Vever")
  run(net, W4 * 0.5, 1, 0.5)
  half = net.coverage("Vever")
  say("steady at half a window: sustained %.3f held %.0f/%.0f full %s", half.sustained, half.held, half.window, tostring(half.full))
  check(not half.full and half.held > W4 * 0.4 and half.held < W4 * 0.6 and half.window == W4, "half an orbit in: half a window held, not full")
  check(not E.sustainMeets(half, 0.3), "...so no goal latches yet, however good it looks")
  run(net, W4 * 0.6, 1, 0.5)
  local c = net.coverage("Vever")
  steady_sustained = c.sustained
  say("steady after a window: sustained %.3f snapshot sky %.3f held %.0f/%.0f, %d satellites, gaps %d",
    c.sustained, c.sky, c.held, c.window, c.satellites, c.gaps and c.gaps.n or -1)
  check(c.full and c.satellites == 5, "a full window, five connected relays")
  check(c.sustained > 0.45 and c.sustained < 0.9, string.format("the equatorial band is held (%.0f%%)", c.sustained * 100))
  check(E.sustainMeets(c, 0.45), "...and a 45% goal latches")
  local g = c.gaps
  check(g and #g.clusters >= 2 and math.abs(g.clusters[1].lat) > 45 and math.abs(g.clusters[2].lat) > 45,
    "the gaps left are the two polar caps")
  local grid = net.coverageGrid("Vever")
  check(grid and grid.held and #grid.held == 200 and grid.full, "the map gets the held flags")
  local sats = net.relaySats("Vever")
  check(#sats == 5 and sats[1].foot > 0.8 and sats[1].linked and math.abs(sats[1].period - P4) < 1,
    "relaySats: five, linked, with a footprint and their period")

  -- ONE DIP: the ground station down for one snapshot
  local before = c.sustained
  BF.sited = false
  net.refreshNow()
  local low = 1
  run(net, W4 / 48 * 1.01, 1, 0.5, function(cv) low = math.min(low, cv.sky) end)
  check(low < 0.01, "the dip is real: nothing links home while the station is down")
  BF.sited = true
  net.refreshNow()
  local dip = net.coverage("Vever")
  run(net, W4 / 48 * 2, 1, 0.5)
  local after = net.coverage("Vever")
  say("dip: %.3f → %.3f → %.3f", before, dip.sustained, after.sustained)
  check(dip.sustained >= before - 0.03 and E.sustainMeets(dip, 0.45), string.format(
    "one dip is tolerated (%.0f%% → %.0f%%)", before * 100, dip.sustained * 100))

  -- A SATELLITE LOST wipes nothing: the window stays (the others share its
  -- orbit) and the history is still there
  local s3 = {}
  for k = 1, 4 do s3[k] = SATS[k] end
  set_sats(s3)
  net.refreshNow()
  run(net, 1, 1, 0.5)
  local lost = net.coverage("Vever")
  check(lost.full and lost.satellites == 4 and lost.sustained >= after.sustained - 0.03,
    string.format("a satellite lost keeps the history (held %.0f s, %.0f%%)", lost.held, lost.sustained * 100))

  -- ── SAVE AND LOAD ─────────────────────────────────────────────────────────
  set_sats(five(math.sqrt(MU / A4 ^ 3) * GT))  -- put the fifth back, in phase
  net.refreshNow()
  run(net, 30, 1, 0.5)
  local was = net.coverage("Vever")
  net.params.sustain_save = 0
  net.time = net.time + 1
  net.update({}, 0)
  local enc = STORE["comms.sustain.Vever"]
  check(type(enc) == "string" and #enc > 100 and #enc < 12000, "the history is in the save (" .. tostring(enc and #enc) .. " chars)")
  -- a new session: the game clock starts again at 0; the satellites resume
  -- where they were (the rails don't run while the game is closed)
  local offset = GT
  local saved_sats = SATS
  for _, s in ipairs(saved_sats) do s.phase = s.phase + math.sqrt(MU / s.a ^ 3) * offset end
  GT = 0
  set_sats(saved_sats)
  local net2 = new_comms()
  local c2 = net2.coverage("Vever")
  net2.time = 1
  net2.update({}, 0.5)
  c2 = net2.coverage("Vever")
  say("reload: sustained %.3f → %.3f, held %.0f → %.0f", was.sustained, c2.sustained, was.held, c2.held)
  check(c2.full and math.abs(c2.sustained - was.sustained) < 0.02 and math.abs(c2.held - was.held) < 1,
    "a reload on a restarted clock reads the same held coverage")
  run(net2, W4 * 0.5, 1, 0.5)
  local c3 = net2.coverage("Vever")
  check(c3.full and c3.sustained > 0.45, "...and carries on from there")
  STORE["comms.sustain.Vever"] = nil
end

-- ── WARP: the same constellation, frames of 3 and 33 s of game time ────────
do
  for _, w in ipairs({ 200, 2000 }) do
    GT = 5000
    set_sats(five())
    local net = new_comms()
    net.coverage("Vever")
    run(net, W4 * 2.5, w, 1 / 60)
    local c = net.coverage("Vever")
    local snaps = 0
    say("warp ×%d: sustained %.3f (×1 %.3f) held %.0f/%.0f", w, c.sustained, steady_sustained, c.held, c.window)
    check(c.full and math.abs(c.sustained - steady_sustained) < 0.05, string.format(
      "at ×%d the held coverage matches ×1 (%.0f%% vs %.0f%%)", w, c.sustained * 100, steady_sustained * 100))
    STORE["comms.sustain.Vever"] = nil
  end
  -- a frame of 10,000 s (a whole stack of orbits): still a fair average
  GT = 9000
  set_sats({ { id = "solo", a = A, phase = 0, e1 = PO1, e2 = PO2 } })
  local net = new_comms()
  net.coverage("Vever")
  run(net, 10000 * 6, 10000, 1)
  local c = net.coverage("Vever")
  say("warp ×10000 one polar relay: sustained %.3f held %.0f", c.sustained, c.held)
  check(c.full and c.sustained < 0.12, "at ×10000 a lone relay is still not 'held' everywhere it passes")
  STORE["comms.sustain.Vever"] = nil
end

-- ── a relay OFF the scene (a fleet record not rebuilt yet) moves on ────────
-- With the velocity and its time on the record (flight_ops fleetOffline),
-- comms carries it along its conic instead of leaving it where it was saved.
do
  GT = 100
  set_sats({})
  local s = { a = A4, phase = 0.3, e1 = EQ1, e2 = EQ2 }
  local px, py, pz, vx, vy, vz = sat_state(s, 40)
  local FO = { valid = true }
  function FO.fleetOffline()
    return { { fid = "c9", name = "Far Relay", charge = 50, landed = false, stime = 40,
               parts = { { id = "dish", mods = { { type = "antenna", power = 2.25e5, relay = true, rate = 12 } }, st = {} } },
               wx = VX + px, wy = VY + py, wz = VZ + pz, vx = vx, vy = vy, vz = vz } }
  end
  local net = new_comms()
  local fs = net.findScript
  net.findScript = function(k) if k == "flight_ops" then return FO end return fs(k) end
  for _ = 1, 3 do GT = GT + 5; net.time = net.time + 0.5; net.update({}, 0.5) end
  local nd = net.nodeOf("f:c9")
  local ex, ey, ez = sat_state(s, GT)
  local err = nd and math.sqrt((nd.x - VX - ex) ^ 2 + (nd.y - VY - ey) ^ 2 + (nd.z - VZ - ez) ^ 2) or math.huge
  say("offline relay: %.3f m from its orbit after %.0f s", err, GT - 40)
  check(err < 0.5, string.format("an off-scene relay is where its orbit has taken it (%.2f m off)", err))
  check(#net.relaySats("Vever") == 1, "...and the map lists it as a relay satellite")
  STORE["comms.sustain.Vever"] = nil
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_sustain: all %d checks passed", passed))
