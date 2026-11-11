-- SMOKE: THIRTY KILOMETRES (scenarios/thirty_km; SC-5 of work/scenarios2/PLAN.md)
-- and the framework pieces it brought, pure:
--   * auto_drive.followLaw, the stick a crew member gives a rover nobody
--     flies: straight at a target it drives and does not steer; a target to
--     its left steers left (+, the A key); inside the gap it lets go and the
--     brakes park it; a target behind is turned toward at a crawl, never
--     reversed into; held on and not moving it backs off and tries again; a
--     `to` target is arrived at and stopped;
--   * scenario.alongPoint: the ends of the great circle, a point between at
--     its arc share, the route frame (front toward the far end, right to its
--     right), set down on the ground;
--   * the SC-5 beats' validation (drive, board, place, charge, give to a
--     craft's locker), start.beacons and marks `along`, craft.<field> meters;
--   * the scenario's hooks against a fake api: Ray's suit bleeds at 1.5×
--     until taped, at 1× after, fills on Asha-1, Kit's bottle once when he is
--     low and she is beside him, the fail at zero; the hub heats over 20 km/h
--     and lets go at 100 (the wear, the stop, the sequence); the odometer, the
--     battery's lowest, the lamps' energy; the cell goes in only mended,
--     carried and beside Asha-2;
--   * the scenario loads and validates.
--
--   luajit solar/tests/smoke_thirty_km.lua
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
local function near(a, b, t) return math.abs(a - b) <= (t or 1e-6) end

-- ── the follow law ──────────────────────────────────────────────────────────
local A = loadlib("auto_drive.lua")
local UP = { x = 0, y = 1, z = 0 }
local F = { x = 1, y = 0, z = 0 }        -- facing +X; with +Y up its left is −Z
local function law(d, v, extra)
  local s = { fwd = F, up = UP, d = d, v = v or { x = 0, y = 0, z = 0 }, speed = 7, gap = 14, dt = 0.1, mem = {} }
  for k, x in pairs(extra or {}) do s[k] = x end
  return A.followLaw(s)
end
do
  local dr, st, I = law({ x = 60, y = 0, z = 0 })
  check("ahead: drives forward", dr > 0.5, dr)
  check("ahead: no steer", near(st, 0, 1e-6), st)
  check("ahead: distance on the ground plane", near(I.dist, 60, 1e-6), I.dist)
  dr, st, I = law({ x = 30, y = 0, z = -30 })
  check("left: steers + (A)", st > 0.5 and I.err > 0, string.format("%s %s", st, I.err))
  dr, st, I = law({ x = 30, y = 0, z = 30 })
  check("right: steers − (D)", st < -0.5 and I.err < 0, st)
  dr, st, I = law({ x = 10, y = 0, z = 0 })
  check("inside the gap, at rest: the stick let go (parked)", dr == 0 and st == 0, string.format("%s %s", dr, st))
  dr = law({ x = 10, y = 0, z = 0 }, { x = 4, y = 0, z = 0 })
  check("inside the gap, rolling: braking", dr < 0, dr)
  dr, st, I = law({ x = -40, y = 0, z = -2 })
  check("behind: turned toward at a crawl, never reversed", dr >= 0 and I.vstar <= 1.2 and st > 0.5, string.format("%s %s %s", dr, I.vstar, st))
  -- slope: the target up a hill reads its ground distance
  dr, st, I = law({ x = 40, y = 30, z = 0 })
  check("up a slope: the ground plane", near(I.dist, 40, 1e-6) and near(st, 0, 1e-6), I.dist)
  -- leader speed lifts the wanted speed
  local _, _, I1 = law({ x = 20, y = 0, z = 0 })
  local _, _, I2 = law({ x = 20, y = 0, z = 0 }, nil, { lead = 6 })
  check("a moving leader is matched", I2.vstar > I1.vstar, string.format("%.2f %.2f", I1.vstar, I2.vstar))
  check("never over its speed", I2.vstar <= 7 + 1e-9, I2.vstar)
  -- stuck: pushed and not moving for FOLLOW_STUCK s → backs off
  local mem = {}
  local backed = false
  for _ = 1, math.ceil((A.FOLLOW_STUCK + 0.5) / 0.1) do
    local d2, s2, I3 = A.followLaw({ fwd = F, up = UP, d = { x = 50, y = 0, z = -5 }, v = { x = 0, y = 0, z = 0 }, speed = 7, gap = 14, dt = 0.1, mem = mem })
    if I3.stuck and d2 < 0 then backed = true end
  end
  check("stuck: it backs off and tries again", backed)
  -- arrive at a point
  local d3, s3, I4 = A.followLaw({ fwd = F, up = UP, d = { x = 3, y = 0, z = 0 }, v = { x = 0, y = 0, z = 0 }, speed = 5, r = 6, dt = 0.1, mem = {} })
  check("to: arrived and stopped", I4.arrived == true and d3 == 0, tostring(I4.arrived))
  d3 = A.followLaw({ fwd = F, up = UP, d = { x = 80, y = 0, z = 0 }, v = { x = 0, y = 0, z = 0 }, speed = 5, r = 6, dt = 0.1, mem = {} })
  check("to: on its way", d3 > 0.5, d3)
end

-- ── marks along a route ────────────────────────────────────────────────────
local SCN = loadlib("scenario.lua")
do
  local R = 885
  local p = { x = 0, y = R, z = 0 }
  local q = { x = R, y = 0, z = 0 }           -- a quarter round
  local ground = function() return R end
  local g0 = SCN.alongPoint(p, q, 0, nil, ground)
  local g1 = SCN.alongPoint(p, q, 1, nil, ground)
  check("along: frac 0 is the first ref", near(g0.x, 0, 1e-6) and near(g0.y, R, 1e-6))
  check("along: frac 1 is the second", near(g1.x, R, 1e-6) and near(g1.y, 0, 1e-6))
  local gh = SCN.alongPoint(p, q, 0.5, nil, ground)
  check("along: half way by arc", near(math.atan2(gh.x, gh.y), math.pi / 4, 1e-9))
  check("along: its front looks toward the far end", gh.fx > 0 and gh.fy < 0)
  local gr = SCN.alongPoint(p, q, 0.5, { 50, 0, 0 }, ground)
  local rx = gr.x - gh.x; local rz = gr.z - gh.z
  -- "right" as every scenario offset has it (groundFrame: up × front)
  local F2 = SCN.groundFrame(gh.x, gh.y, gh.z)
  local ex, ey, ez = gh.fy * F2.uz - gh.fz * F2.uy, gh.fz * F2.ux - gh.fx * F2.uz, gh.fx * F2.uy - gh.fy * F2.ux
  check("along: right of the route as offsets mean it", (rx * -ex + rz * -ez) > 40, string.format("%.1f %.1f", rx, rz))
  local len = math.sqrt(gr.x ^ 2 + gr.y ^ 2 + gr.z ^ 2)
  check("along: set down on the ground", near(len, R, 1e-6), len)
end

-- ── validation of the SC-5 pieces ───────────────────────────────────────────
do
  local function sc_with(extra_beats, start_extra, meters)
    local st = { crew = { { name = "A", role = "pilot", control = true, where = { site = "near_base" } } }, marks = { m = { at = "base" } } }
    for k, v in pairs(start_extra or {}) do st[k] = v end
    return { id = "t", title = "T", start = st, meters = meters, world = "any", score = { par = 60 },
             debrief = { gold = "g", silver = "s", bronze = "b", fail = "f" },
             steps = { { id = "s", text = "x", hint = "h", goals = { { kind = "var", name = "x", is = true } } } },
             on_start = extra_beats, cast = { a = { name = "A", crew = "A" } } }
  end
  local function errs(sc) local ok, e = SCN.validate(sc, {}); return ok, table.concat(e or {}, " | ") end
  local ok, e = errs(sc_with({ { drive = { craft = "Asha-2", follow = "craft:Asha-1", speed = 7, gap = 14 } },
                                { drive = { craft = "Asha-2", to = "mark:m", speed = 3 } },
                                { drive = { craft = "Asha-2", stop = true } },
                                { board = { who = "A", craft = "Asha-1", seat = 8 } }, { board = { who = "A", craft = false } },
                                { place = { craft = "Asha-1", at = "mark:m" } }, { place = { who = "A", at = "mark:m", offset = { 1, 0, 0 } } },
                                { charge = { craft = "Asha-2", frac = 0.8 } },
                                { give = { craft = "Asha-1", item = "tractionCell", n = 1 } } }))
  check("SC-5 beats validate", ok, e)
  ok, e = errs(sc_with({ { drive = { craft = "Asha-2", speed = 7 } } }))
  check("drive: follow or to is required", not ok and e:find("follow = ref or to = ref", 1, true), e)
  ok, e = errs(sc_with({ { charge = { craft = "Asha-2", frac = 2 } } }))
  check("charge: frac 0..1", not ok and e:find("frac", 1, true), e)
  ok, e = errs(sc_with({ { place = { at = "mark:m" } } }))
  check("place: craft or who", not ok and e:find("craft or who", 1, true), e)
  ok, e = errs(sc_with({ { give = { craft = "Asha-1", part = "battery" } } }))
  check("give to a craft: items only", not ok and e:find("items", 1, true), e)
  ok, e = errs(sc_with(nil, { beacons = { { at = "mark:m" } }, marks = { m = { at = "base" }, r = { along = { "base", "mark:m" }, frac = 0.5 } } }))
  check("beacons and along marks validate", ok, e)
  ok, e = errs(sc_with(nil, { marks = { r = { along = { "base" }, frac = 2 } } }))
  check("along: two refs and a frac", not ok and e:find("two refs", 1, true) and e:find("frac", 1, true), e)
  ok, e = errs(sc_with(nil, nil, { { var = "c", read = "craft.charge", craft = "Asha-1" } }))
  check("craft.<field> meters validate", ok, e)
  ok, e = errs(sc_with(nil, nil, { { var = "c", read = "craft.nonsense", craft = "Asha-1" } }))
  check("craft.<field>: a known field", not ok and e:find("craft.charge", 1, true), e)
end

-- ── the hooks against a fake api ────────────────────────────────────────────
local H = loadlib("scn_thirty_km_hooks.lua")
local function fake()
  local V, beats, runs = {}, {}, {}
  local W = { aboard = {}, crafts = { ["Asha-1"] = { speed = 0, charge = 800, cap = 1000, lit = 0, link = 1 }, ["Asha-2"] = { speed = 0, charge = 0, cap = 550, lit = 0 } },
              hp = {}, has = 0, dist = {} }
  local api = {
    var = function(n) return V[n] end, setVar = function(n, v) V[n] = v end,
    beat = function(b) beats[#beats + 1] = b end, run = function(s) runs[#runs + 1] = s end,
    fail = function(why) V._fail = why end, done = function() return false end,
    craft = function(n) return W.crafts[n] end,
    partHp = function(c, u) return W.hp[u] end,
    has = function() return W.has end,
    dist = function(a, b)
      local k = a .. "|" .. b
      if W.dist[k] then return W.dist[k] end
      if b:match("^craft:") then return W.aboard[a .. "|" .. b:sub(7)] and 0 or 30 end
      return 20
    end,
  }
  return api, V, W, beats, runs
end
do
  local api, V, W = fake()
  V.ray_air, V.air_on = 1000, true
  local function run(t0, t1) for t = t0, t1 do H.tick(api, t) end end
  run(0, 10)
  check("Ray's suit: 1.5× while the seal leaks", near(V.ray_air, 985, 0.11), V.ray_air)
  V.patched = true
  run(11, 20)
  check("Ray's suit: 1× once taped", near(V.ray_air, 975, 0.11), V.ray_air)
  W.aboard["crew:Castellanos|Asha-1"] = true
  run(21, 30)
  check("Ray's suit: fills on Asha-1's bottle", near(V.ray_air, 1005, 0.11), V.ray_air)
  check("the lowest is kept", V.ray_min == 975, V.ray_min)
  W.crafts["Asha-1"].charge = 0
  run(31, 40)
  check("not on a flat rover", V.ray_air < 1005, V.ray_air)
end
do
  local api, V, W, _, runs = fake()
  V.ray_air, V.air_on, V.patched = 230, true, true
  H.tick(api, 0); H.tick(api, 1)
  check("Kit's bottle: not when she isn't with him", not V.kit_bottle)
  W.dist["crew:Nakamura|crew:Castellanos"] = 1.2
  H.tick(api, 2)
  check("Kit's bottle: once, beside him and low", V.kit_bottle == true and V.ray_air > 500 and runs[1] == "kit_bottle", V.ray_air)
  V.ray_air = 1
  W.dist["crew:Nakamura|crew:Castellanos"] = nil
  H.tick(api, 4)
  check("Ray's suit dry: the run fails (a setback)", V.ray_out == true and type(V._fail) == "string", tostring(V._fail))
end
do
  local api, V, W, beats, runs = fake()
  V.convoy = true
  W.crafts["Asha-2"].speed = 4
  for tt = 0, 10 do H.tick(api, tt) end
  check("the hub stays cool under 20 km/h", (V.hub_heat or 0) == 0, V.hub_heat)
  W.crafts["Asha-2"].speed = 8
  local t = 10
  while not V.hub_failed and t < 200 do t = t + 1; H.tick(api, t) end
  check("over 20 km/h the hub heats and lets go", V.hub_failed == true and t > 20 and t < 40, t)
  local wore, stopped = false, false
  for _, b in ipairs(beats) do if b.wear and b.wear.uid == 2 and b.wear.hp < 0.2 then wore = true end if b.drive and b.drive.stop then stopped = true end end
  check("a failed hub: worn again, Kit stops, the sequence", wore and stopped and runs[#runs] == "hub_fails")
end
do
  local api, V, W = fake()
  W.crafts["Asha-1"].speed, W.crafts["Asha-1"].lit, W.crafts["Asha-1"].charge = 5, 3, 450
  for t = 0, 10 do H.tick(api, t) end
  check("odometer", V.dist_m == 50, V.dist_m)
  check("battery share and its lowest", V.a1_pct == 45 and V.a1_min == 45, V.a1_pct)
  check("the lamps' energy", near(V.lamp_ec, 6, 0.051), V.lamp_ec)
end
do
  local api, V, W = fake()
  local g = H.goals.cell_ready
  W.hp[8], W.has = 0.2, 1
  W.aboard["crew:Priestley|Asha-2"] = true
  check("the cell: not into a cooked cradle", not g({}, api))
  W.hp[8], W.has = 1.0, 0
  check("the cell: not without the cell", not g({}, api))
  W.has = 1
  W.aboard["crew:Priestley|Asha-2"] = false
  check("the cell: not from 30 m away", not g({}, api))
  W.aboard["crew:Priestley|Asha-2"] = true
  check("the cell: mended, carried, beside Asha-2", g({}, api) == true)
end

-- ── the scenario itself ─────────────────────────────────────────────────────
do
  local sc, err = SCN.load("thirty_km", { readFile = function(p) local f = io.open("solar/" .. p, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end })
  check("thirty_km loads", sc ~= nil, err)
  if sc then
    local fails = {}
    for _, s in ipairs(sc.steps) do if not s.hint then fails[#fails + 1] = s.id end end
    check("a hint on every step", #fails == 0, table.concat(fails, ","))
    local cps = 0
    for _, s in ipairs(sc.steps) do if s.checkpoint then cps = cps + 1 end end
    check("a checkpoint at each act after the first", cps == 2, cps)
    local autos = 0
    for _, c in pairs(sc.cast) do if c.portrait == "auto" then autos = autos + 1 end end
    check("every cast portrait is captured", autos == 7, autos)
  end
end

print(string.format("smoke_thirty_km: %d checks, %d failed", count, failed))
if failed > 0 then os.exit(1) end
