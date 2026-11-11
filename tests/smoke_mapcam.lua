-- SMOKE HARNESS for the map's camera modes (orbit_map.lua CAMM: FREE,
-- HORIZON, ORBIT BALL, FOLLOW; Ty's playtest 2026-11-11).
--
-- The pure rules (tangent frames, HORIZON's pose, the ball's turn, FOLLOW's
-- frame, the blend's eye), then CAMM.place driven frame by frame against a
-- stub camera and a world that moves between frames: HORIZON's up is the
-- world's up at the look point and its horizon level, the ball turns through
-- the poles, FOLLOW lines up with the velocity, a mode change blends without
-- passing through the world, the view rides the world (rule 1: nothing held
-- as a world point), FREE is exactly the old facing, and the mode is kept.
--
--   luajit solar/tests/smoke_mapcam.lua

local failures, passed = {}, 0
local function ok(c, msg)
  if c then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return a and b and math.abs(a - b) <= tol end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function len(a) return math.sqrt(dot(a, a)) end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end

-- ── a stub engine ───────────────────────────────────────────────────────────
local SAVED = {}
local SETTINGS = { get = function(k) return SAVED[k] end, set = function(k, v) SAVED[k] = v end }
local LOOK = nil
local env = setmetatable({}, { __index = _G })
env.time = 0
env.params = { gizmo_size = 1.0, gizmo_stroke = 1, recompute = 0.15, segments = 140 }
local BODIES = {}
env.space = {
  time = function() return 0 end,
  warp = function() return 1 end,
  bodies = function() return BODIES end,
  body = function(n) for _, b in ipairs(BODIES) do if b.name == n then return b end end end,
  dominant = function(x, y, z)
    local best, bd = nil, math.huge
    for _, b in ipairs(BODIES) do
      local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
      if b.soi and (b.soi < 0 or d < b.soi) and (b.soi < 0 and 1e30 or b.soi) < bd then best, bd = b.name, (b.soi < 0 and 1e30 or b.soi) end
    end
    return best
  end,
}
env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
env.lookRotation = function(f, u) LOOK = { f = { f.x, f.y, f.z }, u = { u.x, u.y, u.z } }; return 1, 2, 3 end
env.input = setmetatable({ mouse_delta = function() return 0, 0 end }, { __index = function() return function() return false end end })
local function stub() end
env.draw = setmetatable({}, { __index = function() return stub end })
env.findScript = function(kind) if kind == "settings" then return SETTINGS end end
env.findScripts = function() return {} end
env.log = stub
local chunk = assert(loadfile("solar/scripts/orbit_map.lua"))
setfenv(chunk, env)
chunk()
local CAMM = env.CAMM
ok(type(CAMM) == "table" and type(CAMM.place) == "function", "orbit_map publishes CAMM and CAMM.place")

-- ── 1. THE PURE RULES ───────────────────────────────────────────────────────
do
  for _, U in ipairs({ { 0, 1, 0 }, { 1, 0, 0 }, { 0.6, 0.0, 0.8 }, { 0, -1, 0 }, { 0.01, 0.99995, 0 } }) do
    local l = len(U); U = { U[1] / l, U[2] / l, U[3] / l }
    local nx, ny, nz, ex, ey, ez = CAMM.tangent(U[1], U[2], U[3])
    local N, E = { nx, ny, nz }, { ex, ey, ez }
    ok(near(len(N), 1, 1e-9) and near(len(E), 1, 1e-9) and near(dot(N, U), 0, 1e-9) and near(dot(E, U), 0, 1e-9) and near(dot(N, E), 0, 1e-9),
      "north and east are a square frame on the ground at up " .. table.concat(U, ","))
  end
  -- HORIZON's pose: the camera's up is the local up as far as a level view
  -- allows, its right lies along the ground (the horizon level), the eye is
  -- `dist` off the point at `pitch` above the horizon
  local U = { 0.6, 0.0, 0.8 }
  for _, p in ipairs({ 0.06, 0.35, 1.0, 1.48 }) do
    for _, yaw in ipairs({ 0, 1.3, -2.5 }) do
      local ex, ey, ez, fx, fy, fz, ux, uy, uz = CAMM.horizonPose(10, 20, 30, U[1], U[2], U[3], yaw, p, 500)
      local d = { ex - 10, ey - 20, ez - 30 }
      local F, Up = { fx, fy, fz }, { ux, uy, uz }
      local R = cross(F, Up)
      ok(near(len(d), 500, 1e-6), "HORIZON: the eye is the zoom off the point")
      ok(near(math.asin(dot(d, U) / 500), p, 1e-9), "HORIZON: the eye stands at the pitch above the horizon")
      ok(near(dot(R, U), 0, 1e-9), string.format("HORIZON: the horizon is level (right ⟂ local up) at pitch %.2f yaw %.1f", p, yaw))
      ok(dot(Up, U) > 0 and near(dot(Up, F), 0, 1e-9), "HORIZON: the camera's up leans with the local up and is square to the view")
      ok(near(dot(F, { -d[1] / 500, -d[2] / 500, -d[3] / 500 }), 1, 1e-9), "HORIZON: it looks at the point")
    end
  end
  -- the ball: dragging right moves the eye to the camera's left (the near face
  -- follows the hand), dragging down moves the eye up; the basis stays square
  local f, u = { 0, 0, -1 }, { 0, 1, 0 }
  local r = cross(f, u)
  local f2, u2 = CAMM.ballTurn(f, u, 0.1, 0)
  local de = { -(f2[1] - f[1]), -(f2[2] - f[2]), -(f2[3] - f[3]) }   -- the eye is −f·d
  ok(dot(de, r) < 0, "BALL: a drag right takes the eye left (the ball's face moves with the hand)")
  local f3, u3 = CAMM.ballTurn(f, u, 0, 0.1)
  local de3 = { -(f3[1] - f[1]), -(f3[2] - f[2]), -(f3[3] - f[3]) }
  ok(dot(de3, u) > 0, "BALL: a drag down takes the eye up (the face moves down)")
  local fa, ua = f, u
  local sq = true
  for _ = 1, 400 do
    fa, ua = CAMM.ballTurn(fa, ua, 0.013, 0.031)
    if not (near(len(fa), 1, 1e-9) and near(len(ua), 1, 1e-9) and near(dot(fa, ua), 0, 1e-9)) then sq = false end
  end
  ok(sq, "BALL: four hundred turns about two axes keep the view's basis square")
  -- through the poles: no clamp; a whole turn comes back to where it began
  local fb, ub = f, u
  local steps = 200
  local overPole = false
  for _ = 1, steps do
    fb, ub = CAMM.ballTurn(fb, ub, 0, 2 * math.pi / steps)
    if dot(fb, { 0, -1, 0 }) > 0.99 or dot(fb, { 0, 1, 0 }) > 0.99 then overPole = true end
  end
  ok(overPole and near(dot(fb, f), 1, 1e-6) and near(dot(ub, u), 1, 1e-6), "BALL: a vertical drag goes over the poles and a whole turn comes home")
  -- FOLLOW's frame
  local fx, fy, fz, ux, uy, uz, vel = CAMM.followFrame(0, 1000, 0, 50, 0, 0, nil, false)
  ok(vel and near(fx, 1, 1e-9) and near(uy, 1, 1e-9), "FOLLOW: moving, it looks along the velocity with up radial")
  local _, _, _, _, _, _, v2 = CAMM.followFrame(0, 1000, 0, 2.0, 0, 0, { 1, 0, 0 }, true)
  local _, _, _, _, _, _, v3 = CAMM.followFrame(0, 1000, 0, 2.0, 0, 0, { 1, 0, 0 }, false)
  ok(v2 == true and v3 == false, "FOLLOW: between 1.5 and 3 m/s it keeps the frame it had (hysteresis)")
  local gx, gy, gz = CAMM.followFrame(0, 1000, 0, 0, 0, 0, { 0.6, 0.8, 0 }, false)
  ok(near(gy, 0, 1e-9) and near(gx, 1, 1e-9), "FOLLOW: nearly still, the last facing is laid flat on the ground")
  -- the blend's eye never passes through the world
  local R0 = 1000
  for _, pair in ipairs({ { { 3000, 0, 0 }, { -1500, 10, 0 } }, { { 0, 5000, 0 }, { 0, -1100, 0 } }, { { 2000, 0, 0 }, { 0, 0, 1200 } } }) do
    local a, c = pair[1], pair[2]
    local lo = math.huge
    for i = 0, 50 do
      local x, y, z = CAMM.blendEye(a[1], a[2], a[3], c[1], c[2], c[3], i / 50)
      lo = math.min(lo, math.sqrt(x * x + y * y + z * z))
    end
    ok(lo >= math.min(len(a), len(c)) - 1e-6 and lo > R0, string.format("the blend goes round the world, never through it (closest %.0f m)", lo))
    local x1, y1, z1 = CAMM.blendEye(a[1], a[2], a[3], c[1], c[2], c[3], 1)
    ok(near(x1, c[1], 1e-6) and near(y1, c[2], 1e-6) and near(z1, c[3], 1e-6), "…and lands exactly on the new view")
  end
end

-- ── 2. MODES, CYCLED AND KEPT ───────────────────────────────────────────────
ok(CAMM.mode == "free", "the map starts in FREE")
ok(CAMM.set("nonsense") == false and CAMM.mode == "free", "an unknown mode is refused")
CAMM.cycle(); ok(CAMM.mode == "horizon" and SAVED.map_cam == "horizon", "V: FREE → HORIZON, and the settings keep it")
CAMM.cycle(); ok(CAMM.mode == "ball", "V: → ORBIT BALL")
CAMM.cycle(); ok(CAMM.mode == "follow", "V: → FOLLOW")
CAMM.cycle(); ok(CAMM.mode == "free" and SAVED.map_cam == "free", "V: → back to FREE")
SAVED.map_cam = "ball"
CAMM.loaded = false
CAMM.load()
ok(CAMM.mode == "ball" and CAMM.blend == nil, "a remembered mode comes back when the map opens, with nothing to blend from")
CAMM.set("free")

-- ── 3. CAMM.place, FRAME BY FRAME, ON A MOVING WORLD ────────────────────────
local PLANET = { name = "Taquo", x = 1.0e6, y = 2000, z = -3.0e5, radius = 900, soi = 40000, mu = 1e9, vx = 0, vy = 0, vz = 0 }
local STAR = { name = "Sun", x = 0, y = 0, z = 0, radius = 50000, soi = -1, mu = 1e15, vx = 0, vy = 0, vz = 0 }
BODIES[1], BODIES[2] = STAR, PLANET
local cam = {}
local function free_pose(focus, yaw, pitch, zoom)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local dx, dy, dz = cp * math.sin(yaw), sp, cp * math.cos(yaw)
  return focus.x + dx * zoom, focus.y + dy * zoom, focus.z + dz * zoom, dx, dy, dz
end
local function frame(focus, isBody, subj, dt, fname)
  local ex, ey, ez, dx, dy, dz = free_pose(focus, 0.6, 0.45, 5400)
  LOOK = nil
  return CAMM.place(cam, focus, fname or (isBody and focus.name or "SHIP"), isBody and focus.radius or 6, isBody, subj, BODIES, dt or 1 / 60,
    ex, ey, ez, dx, dy, dz)
end
CAMM.reset()
-- FREE: exactly the old facing
frame(PLANET, true)
ok(near(cam.yaw, math.atan2(math.cos(0.45) * math.sin(0.6), math.cos(0.45) * math.cos(0.6)), 1e-12) and near(cam.pitch, -0.45, 1e-12) and cam.roll == 0 and LOOK == nil,
  "FREE sets the camera exactly as the map always did")
-- HORIZON on the world: starts under the camera, level, then the blend lands
CAMM.set("horizon")
for _ = 1, 60 do frame(PLANET, true) end
local U = CAMM.hz.dir
local eye = { cam.x - PLANET.x, cam.y - PLANET.y, cam.z - PLANET.z }
local look = { U[1] * 909, U[2] * 909, U[3] * 909 }
local d = { eye[1] - look[1], eye[2] - look[2], eye[3] - look[3] }
ok(CAMM.blend == nil and LOOK ~= nil, "HORIZON: the blend from FREE has landed after a second")
ok(near(len(d), env.CAMM and len(d), 1) and dot(d, U) > 0, "HORIZON: the eye is above the ground point")
ok(near(dot(cross(LOOK.f, LOOK.u), U), 0, 1e-6), "HORIZON: the horizon is level on the camera")
ok(len(eye) > PLANET.radius, "HORIZON: the eye is outside the world")
-- the world moves 6 m a tick: the view moves with it, exactly (rule 1)
local before = { cam.x - PLANET.x, cam.y - PLANET.y, cam.z - PLANET.z }
PLANET.x, PLANET.y, PLANET.z = PLANET.x + 3500, PLANET.y - 40, PLANET.z + 900
frame(PLANET, true)
ok(near(cam.x - PLANET.x, before[1], 1e-6) and near(cam.y - PLANET.y, before[2], 1e-6) and near(cam.z - PLANET.z, before[3], 1e-6),
  "HORIZON: the world moved 3.6 km and the view rode with it (held from the world's centre)")
-- the look round: right-drag turns the heading, the eye stays off the point
local y0 = CAMM.hz.yaw
CAMM.drag(100, 0, false, 1 / 60)
ok(near(CAMM.hz.yaw - y0, 100 * CAMM.DRAG, 1e-12), "HORIZON: a drag turns the heading")
CAMM.drag(0, 100000, false, 1 / 60)
ok(CAMM.hz.pitch >= 0.06 - 1e-12, "HORIZON: never under the horizon")
-- walking the point: the ground point moves, still a unit direction
local d0 = { U[1], U[2], U[3] }
CAMM.drag(200, 0, true, 1 / 60)
local d1 = CAMM.hz.dir
ok(near(len(d1), 1, 1e-9) and dot(d0, d1) < 1 - 1e-9, "HORIZON: Ctrl+drag walks the point over the ground")
-- HORIZON on the craft: up is the world's up at the craft
local craft = { x = PLANET.x + 0, y = PLANET.y + 950, z = PLANET.z, vx = 30, vy = 0, vz = 0 }
CAMM.reset()
frame(craft, false, craft)
frame(craft, false, craft)
for _ = 1, 60 do frame(craft, false, craft) end
ok(LOOK and near(dot(cross(LOOK.f, LOOK.u), { 0, 1, 0 }), 0, 1e-6) and LOOK.u[2] > 0, "HORIZON on a craft: level with the ground under it")
-- ORBIT BALL: a drag turns the ball, a flick keeps it turning, then it stops
CAMM.set("ball")
for _ = 1, 60 do frame(PLANET, true) end
local f0 = { CAMM.ball.f[1], CAMM.ball.f[2], CAMM.ball.f[3] }
for _ = 1, 10 do CAMM.drag(15, 4, false, 1 / 60); CAMM.coast(1 / 60, true, true); frame(PLANET, true) end
local f1 = { CAMM.ball.f[1], CAMM.ball.f[2], CAMM.ball.f[3] }
ok(dot(f0, f1) < 0.999, "BALL: a drag spins the world")
for _ = 1, 5 do CAMM.coast(1 / 60, false); frame(PLANET, true) end
local f2 = { CAMM.ball.f[1], CAMM.ball.f[2], CAMM.ball.f[3] }
ok(dot(f1, f2) < 1 - 1e-6, "BALL: let go mid-drag, it keeps turning (a flick)")
for _ = 1, 600 do CAMM.coast(1 / 60, false) end
ok(CAMM.ball.wa == 0 and CAMM.ball.wb == 0, "BALL: …and comes to rest")
local dist = len({ cam.x - PLANET.x, cam.y - PLANET.y, cam.z - PLANET.z })
ok(dist > PLANET.radius * 1.5, "BALL: the eye goes round the ball, outside it")
ok(near(PLANET.radius, 900, 0), "BALL: nothing about the world itself is touched")
-- FOLLOW: a craft moving east is followed from behind with up radial
CAMM.set("follow")
CAMM.reset()
craft.vx, craft.vy, craft.vz = 40, 0, 0
for _ = 1, 90 do frame(craft, false, craft) end
local e2 = { cam.x - craft.x, cam.y - craft.y, cam.z - craft.z }
ok(CAMM.sub == "VELOCITY" and e2[1] < 0 and e2[2] > 0, "FOLLOW: behind the craft along its velocity, a little above")
ok(LOOK and near(dot(LOOK.f, { -e2[1] / len(e2), -e2[2] / len(e2), -e2[3] / len(e2) }), 1, 1e-6), "FOLLOW: the craft is centred")
-- the craft turns north: the view swings round smoothly, not in one frame
craft.vx, craft.vz = 0, -40
frame(craft, false, craft)
local sw = CAMM.fol.f
ok(sw[1] > 0.5, "FOLLOW: a turn of the craft eases the view round (no snap)")
for _ = 1, 240 do frame(craft, false, craft) end
ok(CAMM.fol.f[3] < -0.99, "FOLLOW: …and settles on the new heading")
craft.vx, craft.vz = 0, 0
frame(craft, false, craft)
ok(CAMM.sub == "SURFACE", "FOLLOW: stopped, it holds to the ground")
-- a mode change mid-flight blends round the world from the old view
CAMM.set("free")
local seen = {}
for i = 1, 40 do
  frame(PLANET, true)
  seen[#seen + 1] = len({ cam.x - PLANET.x, cam.y - PLANET.y, cam.z - PLANET.z })
end
local lo = math.huge
for _, v in ipairs(seen) do lo = math.min(lo, v) end
ok(lo > PLANET.radius, string.format("FOLLOW → FREE blends round the world (closest %.0f m, radius 900)", lo))
ok(CAMM.blend == nil, "…and lands within the blend's time")
ok(CAMM.label() == "FREE", "the key's legend says the mode")
CAMM.set("follow"); frame(craft, false, craft)
ok(CAMM.label():find("FOLLOW", 1, true) == 1, "…FOLLOW says its frame too (" .. CAMM.label() .. ")")
CAMM.set("free")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("MAPCAM SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print(string.format("MAPCAM SMOKE FAILURES (%d passed):", passed))
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
