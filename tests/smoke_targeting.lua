-- SMOKE for scripts/targeting.lua's maths (TM) and its save/menu plumbing:
--
--   * the frame error (a rotation taking our port's frame onto the wanted one)
--     is the rotation it should be, and zero when lined up;
--   * the PORT ALIGNMENT: our port's axis is held ANTI-PARALLEL to theirs and
--     the guide petals interleave (3 keys, 60° off), from any start, the hold
--     picking the nearest key so it never rolls more than 60°;
--   * integrating the SAS Target command from a crooked start settles under a
--     degree with no overshoot past zero;
--   * the approach: range, closing speed (+ = coming together), lateral miss
--     and the distance out along their axis;
--   * a marker on screen stays on its point; off screen or behind it is
--     pinned to the side to turn to, pins stacking down the side;
--   * the closest approach of two straight tracks is where it should be;
--   * set / clear write the save, and the providers register on the menus.
--
--   luajit solar/tests/smoke_targeting.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

local store = {}
local registered = {}
local API = {
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  findScripts = function() return {} end,
  log = function() end,
  space = { body = function(n) if n == "Pebble" then return { name = "Pebble", x = 0, y = 0, z = 0, radius = 100 } end end },
}
local reg = { valid = true, register = function(kind, fn, o) registered[kind] = fn; return o.id end }
API.findScript = function(kind) if kind == "context_registry" then return reg end end
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return 0 end
  return API[k] or _G[k]
end })
local path = io.open("solar/scripts/targeting.lua") and "solar/scripts/targeting.lua" or "scripts/targeting.lua"
local chunk = assert(loadfile(path))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end
local TM = env.TM

-- ── the frame error ─────────────────────────────────────────────────────────
do
  local ex, ey, ez, th = TM.frameError(0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0)
  ok(near(th, 0, 1e-9), "lined-up frames: no error")
  -- want = ours turned 90° about +Z (y → −x, x → y)
  local ax, ay, az = TM.rotate(0, 1, 0, 0, 0, 1, math.pi / 2)
  local kx, ky, kz = TM.rotate(1, 0, 0, 0, 0, 1, math.pi / 2)
  ex, ey, ez, th = TM.frameError(0, 1, 0, 1, 0, 0, ax, ay, az, kx, ky, kz)
  ok(near(th, math.pi / 2, 1e-6), "a 90° turn reads 90°: " .. th)
  ok(near(ez, math.pi / 2, 1e-6) and near(ex, 0, 1e-6) and near(ey, 0, 1e-6), "about +Z")
  -- a pure roll of 30° about the axis
  kx, ky, kz = TM.rotate(1, 0, 0, 0, 1, 0, math.rad(30))
  ex, ey, ez, th = TM.frameError(0, 1, 0, 1, 0, 0, 0, 1, 0, kx, ky, kz)
  ok(near(math.deg(th), 30, 1e-6) and near(ey, math.rad(30), 1e-6), "a pure roll is about the axis")
  -- point error, opposite: a half turn across
  ex, ey, ez, th = TM.pointError(0, 1, 0, 0, -1, 0)
  ok(near(th, math.pi, 1e-9) and near(ey, 0, 1e-9), "opposite: a half turn across the axis")
end

-- ── the port alignment: anti-parallel, petals interleaved ───────────────────
do
  local fold, off = env.PORT_KEY.fold, env.PORT_KEY.offset
  ok(fold == 3 and near(off, math.pi / 3), "the port key: 3 petals, 60° interleave")
  -- their port faces +X with its key along +Y; we must face −X
  local tax, tay, taz = 1, 0, 0
  local tkx, tky, tkz = 0, 1, 0
  local Ax, Ay, Az = -tax, -tay, -taz
  -- our key 10° past the 60° slot: the hold picks that slot (roll −10°)
  local mkx, mky, mkz = TM.rotate(tkx, tky, tkz, Ax, Ay, Az, math.rad(70))
  local Kx, Ky, Kz = TM.matchKey(Ax, Ay, Az, tkx, tky, tkz, mkx, mky, mkz, fold, off)
  local r = math.deg(TM.rollError(Ax, Ay, Az, Kx, Ky, Kz, mkx, mky, mkz))
  ok(near(math.abs(r), 10, 1e-6), "nearest petal slot: 10° of roll, got " .. r)
  ok(near(TM.dot(Kx, Ky, Kz, Ax, Ay, Az), 0, 1e-9), "the wanted key is across the axis")
  -- the wanted key is 60° (mod 120°) from theirs: interleaved
  local a = math.deg(TM.angle(Kx, Ky, Kz, tkx, tky, tkz))
  ok(near(a, 60, 1e-6) or near(a, 180, 1e-6), "interleaved with their petals: " .. a)
  -- no start ever needs more than 60° of roll
  local worst = 0
  for d = 0, 359, 7 do
    local qx, qy, qz = TM.rotate(tkx, tky, tkz, Ax, Ay, Az, math.rad(d))
    local K1, K2, K3 = TM.matchKey(Ax, Ay, Az, tkx, tky, tkz, qx, qy, qz, fold, off)
    worst = math.max(worst, math.abs(math.deg(TM.rollError(Ax, Ay, Az, K1, K2, K3, qx, qy, qz))))
  end
  ok(worst <= 60 + 1e-6, "never more than 60° of roll: " .. worst)
end

-- ── the hold settles: integrate the command from a crooked start ────────────
do
  -- our port frame (axis a, key k) as a rigid body turned by ω each step
  local function turn(v, w, dt)
    local wl = TM.len(w[1], w[2], w[3])
    if wl < 1e-12 then return v end
    local x, y, z = TM.rotate(v[1], v[2], v[3], w[1] / wl, w[2] / wl, w[3] / wl, wl * dt)
    return { x, y, z }
  end
  local Tax, Tkx = { 0.3, 0.2, 0.93 }, nil
  do local x, y, z = TM.norm(Tax[1], Tax[2], Tax[3]); Tax = { x, y, z } end
  do local x, y, z = TM.across(1, 0, 0, Tax[1], Tax[2], Tax[3]); Tkx = { x, y, z } end
  local a = { 0, 1, 0 }
  local k = { 1, 0, 0 }
  local A = { -Tax[1], -Tax[2], -Tax[3] }
  local dt, wcur = 1 / 60, { 0, 0, 0 }
  local angs, rolls = {}, {}
  local tau = 0.25    -- a wheel lag: the rate follows the command in ~0.25 s
  for i = 1, 60 * 20 do
    local K1, K2, K3 = TM.matchKey(A[1], A[2], A[3], Tkx[1], Tkx[2], Tkx[3], k[1], k[2], k[3], 3, math.pi / 3)
    local ex, ey, ez, th = TM.frameError(a[1], a[2], a[3], k[1], k[2], k[3], A[1], A[2], A[3], K1, K2, K3)
    local wx, wy, wz = TM.command(ex, ey, ez, th, 1.0, 2.5, 1.2)
    local f = dt / tau
    wcur = { wcur[1] + (wx - wcur[1]) * f, wcur[2] + (wy - wcur[2]) * f, wcur[3] + (wz - wcur[3]) * f }
    a = turn(a, wcur, dt)
    k = turn(k, wcur, dt)
    angs[i] = math.deg(TM.angle(a[1], a[2], a[3], A[1], A[2], A[3]))
    rolls[i] = math.deg(TM.rollError(A[1], A[2], A[3], K1, K2, K3, k[1], k[2], k[3]))
  end
  ok(angs[#angs] < 0.5, "the hold settles under 0.5°: " .. angs[#angs])
  ok(math.abs(rolls[#rolls]) < 0.5, "…and the roll too: " .. rolls[#rolls])
  -- no oscillation: once under 2°, it never climbs back over 2°
  local under = nil
  for i, v in ipairs(angs) do
    if not under and v < 2 then under = i end
    if under and v > 2.0 then ok(false, "climbed back over 2° at step " .. i) break end
  end
  ok(under ~= nil and under < 60 * 10, "under 2° within 10 s: step " .. tostring(under))
end

-- ── the rate law ────────────────────────────────────────────────────────────
ok(TM.rate(0, 1, 2.5, 1.2) == 0, "no error, no rate")
ok(near(TM.rate(3, 1, 2.5, 1.2), 1.0), "capped at max_rate")
ok(near(TM.rate(0.01, 1, 2.5, 1.2), 0.012), "linear near zero")

-- ── the approach ────────────────────────────────────────────────────────────
do
  -- their port at the origin facing +X; ours 10 m out and 0.5 m off to +Y,
  -- coming in at 0.3 m/s
  local r, c, lat, al = TM.approach(10, 0.5, 0, -0.3, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0)
  ok(near(r, math.sqrt(100.25)), "range")
  ok(c > 0.29 and c < 0.3, "closing is positive coming together: " .. c)
  ok(near(lat, 0.5, 1e-9), "lateral miss 0.5 m: " .. lat)
  ok(near(al, 10, 1e-9), "10 m out in front of their face")
  local _, c2 = TM.approach(10, 0, 0, 0.2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0)
  ok(near(c2, -0.2, 1e-9), "opening is negative")
  -- their velocity counts: both drifting together is no closing at all
  local _, c3 = TM.approach(10, 0, 0, 5, 1, 0, 0, 0, 0, 5, 1, 0, 1, 0, 0)
  ok(near(c3, 0, 1e-9), "a common drift is not closing")
end

-- ── the edge pin ────────────────────────────────────────────────────────────
do
  local w, x, y = TM.edgePin(640, 300, 10, true, 0, 0, 1280, 720, 1, 0.30, 0)
  ok(w == "on" and x == 640 and y == 300, "on screen: on its point")
  w, x, y = TM.edgePin(1270, 300, 10, true, 0, 0, 1280, 720, 1, 0.30, 0)
  ok(w == "right" and x == 1280 - 170 and near(y, 216), "past the right margin: pinned right")
  w = TM.edgePin(900, 300, -5, false, 0, 0, 1280, 720, 1, 0.30, 0)
  ok(w == "left", "behind on the right: turn left")
  w = TM.edgePin(200, 300, -5, false, 0, 0, 1280, 720, 1, 0.30, 0)
  ok(w == "right", "behind on the left: turn right")
  w, x, y = TM.edgePin(nil, nil, nil, false, 0, 0, 1280, 720, 2, 0.30, 1)
  ok(w == "right" and near(y, 216 + 52), "a second pin stacks below, × the interface scale")
  w = TM.edgePin(640, 700, 10, true, 0, 0, 1280, 720, 1, 0.30, 0)
  ok(w ~= "on", "under the console margin: pinned")
end

-- ── the closest approach ────────────────────────────────────────────────────
do
  local function lin(x, y, z, vx, vy, vz, t) return x + vx * t, y + vy * t, z + vz * t, vx, vy, vz end
  -- a passes the origin at t=50 along +X; b sits 3 m off it on +Y
  local t, d = TM.closestApproach({ -50, 0, 0, 1, 0, 0 }, { 0, 3, 0, 0, 0, 0 }, lin, 200, 64)
  ok(near(t, 50, 0.05) and near(d, 3, 1e-3), string.format("closest approach t %.3f d %.4f", t, d))
end

-- ── the selection rides the save; the menus are registered ──────────────────
do
  local okb = env.targetBody("Pebble")
  ok(okb and env.target and env.target.kind == "body", "a world targeted")
  ok(type(store["target.sel"]) == "table" and store["target.sel"].name == "Pebble", "…written to the save")
  env.clear(true)
  ok(env.target == nil and store["target.sel"] == false, "cleared, and the save says so")
  ok(env.targetBody("Nowhere") == false, "no such world: refused")
  env.update(nil, 0.016)
  ok(registered.part and registered.body and registered.craft and registered.dockchoice,
    "rows on the part, world, craft and port-choice menus")
  local rows = registered.body({ kind = "body", name = "Pebble" }, {})
  local set
  for _, e in ipairs(rows) do if e.id == "set" then set = e end end
  ok(set ~= nil and set.act ~= nil, "a world's menu has Set target")
  set.act()
  ok(env.target and env.target.name == "Pebble", "Set target from the menu targets it")
  rows = registered.body({ kind = "body", name = "Pebble" }, {})
  local has_clear = false
  for _, e in ipairs(rows) do if e.id == "clear" then has_clear = true end end
  ok(has_clear, "…and then offers Clear target")
end

-- ── the port key from a blueprint record ────────────────────────────────────
do
  local kx, ky, kz = TM.portKeyLocal({ yaw = 0, pitch = 0, roll = 0 })
  ok(near(kx, math.cos(0.3)) and near(ky, 0) and near(kz, math.sin(0.3)), "an axial port's key: its first petal")
  kx, ky, kz = TM.portKeyLocal({ yaw = 0, pitch = 0, roll = 0, att = "radial" })
  ok(near(ky, 1) and near(kx, 0), "a radial port's key: its +Y")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_targeting: %d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_targeting: %d checks ok", checks))
