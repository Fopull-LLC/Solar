-- SMOKE HARNESS: a jet's landing gear (vessel_controller.lua: gearOleo,
-- r2UprightGear, wheelReal, hang_tyre).
--
-- "sometimes my wheels on my jets were bouncing like they were fighting"
-- (playtest 2026-11-04). Three causes, measured with motoprobe jetland:
--   * a spaceplane built standing up (the player's: nose +Y, gear legs +Z)
--     had its tyres laid across the "front" a rover would have (the wing), so
--     once it lay level each tyre turned about the vertical: it could not
--     roll, and a 0.05 m/s touchdown at 55 m/s threw the jet over;
--   * the climb cap (the gear may not lift the craft) fought every lift-off,
--     slamming every leg onto its stop for the last 0.3 s of the roll;
--   * the script oleo read a stroke the engine refreshes once a frame, 0 then
--     twice the rate at 30 fps, smoothed on top: ~80 ms late.
-- This holds that:
--   * r2UprightGear lays a standing craft's gear axle across its nose and the
--     leg, and such gear does not steer;
--   * the climb cap acts only below R2_GEAR_THR of throttle (a landing's
--     rebound, not a take-off's or a touch-and-go's climb); the pitch cap acts
--     on the ground throughout;
--   * with R2_REAL_GEAR (off: measured worse at a touchdown) a gear leg is a
--     real-unit spring and damper sized by the lever rule, its nose leg for a
--     braking stop, and gearOleo adds nothing to it; a rover's wheel is sized
--     as before.
--
--   luajit solar/tests/smoke_gear_legs.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end
local function near(a, b, tol) return math.abs((a or 1e9) - (b or -1e9)) <= (tol or 1e-9) end

local impulses = 0
local stub = setmetatable({}, { __index = function() return function() end end,
                                __call = function() return nil end })
local env = setmetatable({}, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
check("vessel_controller loads in a stub world", ok, tostring(err))

local G = 8.87
env.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
env.space = { gravity = function() return 0, -G, 0 end }
env.assembly = { impulseAt = function() impulses = impulses + 1 end, torque = function() end }
env.stressForce, env.stressLead = function() end, function() end
env.v2w = function(_, _, x, y, z) return x, y, z end
env.basis = function() return { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 } end
env.gearIsUp = function() return false end
env.time = 100

-- the probe jet's gear: two mains 0.36 m behind the centre of mass, 1.4 m
-- out, and a nose leg 2.39 m ahead; 3 t, its centre of mass 1.4 m up
local info = { mass = 3.0, com = env.vec3(0, 1.4, 0), origin = env.vec3(0, 0, 0), vel = env.vec3(0, 0, 0),
               angVel = env.vec3(0, 0, 0), right = env.vec3(1, 0, 0), up = env.vec3(0, 1, 0) }
local function leg(uid, id, size, a, l, r)
  local d = { id = id, mass = (size == "M") and 0.08 or 0.035, wheel = size }
  return { uid = uid, d = d, gear = true, size = size, a = a, l = l, r = r, cx = a, cy = 0.5, cz = l,
           cfg = env.r2WheelCfg(d), m = { torque = 0.5 } }
end
local R2 = env.R2
R2.wheels = { leg(8, "gearM", "M", -0.36, -1.4, 0.4), leg(13, "gearM", "M", -0.36, 1.4, 0.4), leg(15, "gearS", "S", 2.39, 0, 0.25) }
R2.nOut, R2.gear, R2.plan = 3, true, { hcg = 1.4 }
local W = info.mass * G
local sum = 0
local K = {}
for _, w in ipairs(R2.wheels) do
  local k, cb, cr, lo, hi = env.wheelReal(w, info, G, w.cfg)
  K[w.uid] = { k = k, cb = cb, cr = cr, lo = lo, hi = hi, load = w.realLoad }
  sum = sum + w.realLoad
end
check("the legs' loads are the craft's weight", near(sum, W, 1e-6), string.format("%.2f of %.2f kN", sum, W))
local front = 0.36 / (2.39 + 0.36)
check("the lever rule: the nose carries its share", near(K[15].load, W * front, 1e-6), string.format("%.2f kN", K[15].load))
local m8 = K[8]
local travel = env.R2_GEAR_TRAVEL.M
check("a main leg sits R2_GEAR_SAG into its travel", near(m8.load / m8.k, env.R2_GEAR_SAG * travel, 1e-9),
  string.format("%.1f mm", m8.load / m8.k * 1000))
local crit = 2 * math.sqrt(m8.k * m8.load / G)
check("a main leg's bump and rebound are R2_GEAR_BUMP and R2_GEAR_REBOUND of critical",
  near(m8.cb / crit, env.R2_GEAR_BUMP, 1e-9) and near(m8.cr / crit, env.R2_GEAR_REBOUND, 1e-9),
  string.format("%.2f %.2f", m8.cb / crit, m8.cr / crit))
check("the rebound is damped harder than the bump", m8.cr > m8.cb)
check("bump stops at the travel's ends", near(m8.hi, travel) and m8.lo < 0 and m8.lo > -travel)
local n = K[15]
local brake = W * env.R2_GEAR_BRAKE_G * 1.4 / 2.75
check("the nose leg takes a braking stop in R2_GEAR_FULL of its travel",
  (n.load + brake) / n.k <= env.R2_GEAR_FULL * env.R2_GEAR_TRAVEL.S + 1e-9,
  string.format("%.0f mm of %.0f", (n.load + brake) / n.k * 1000, env.R2_GEAR_TRAVEL.S * 1000))
check("…and is stiffer than its static share alone asks", n.k > n.load / (env.R2_GEAR_SAG * env.R2_GEAR_TRAVEL.S))

-- hang_tyre: what the engine is handed
local spec
local function tyre()
  local rb = { mass = 0 }
  return { valid = true, id = 77,
           getcomponent = function(_, kind) if kind == "RigidBody" then return rb end end,
           setJoint = function(_, s) spec = s end }
end
local w = R2.wheels[1]
w.tyre, w.jointed = tyre(), false
env.R2_REAL_SUSP = true
local was_real = env.R2_REAL_GEAR
check("landing gear stays on the frequency path by default", was_real == false)
env.R2_REAL_GEAR = true
env.hang_tyre({}, w, info)
env.R2_REAL_GEAR = was_real
check("with R2_REAL_GEAR a gear leg is hung in real units", spec and spec.springRate and near(spec.springRate, K[8].k, 1e-9)
  and near(spec.damperBump, K[8].cb, 1e-9) and near(spec.damperRebound, K[8].cr, 1e-9), spec and tostring(spec.springRate))
check("…with its bump stops", spec and spec.limit == true and near(spec.max, K[8].hi) and near(spec.min, K[8].lo))
check("…and not on the frequency path", spec and spec.stiffness == nil)
check("the leg is marked real", w.real == true)

-- a rover's wheel on the same craft kind of setup: sized by its own sag and ζ
R2.gear = false
local rw = { uid = 2, d = { id = "wheelM", mass = 0.12, wheel = "M" }, size = "M", a = 0.66, l = 0.7, r = 0.4, cx = 0.66, cy = 0.42, cz = 0.7 }
rw.cfg = env.r2WheelCfg(rw.d)
local saved = R2.wheels
R2.wheels, R2.nOut = { rw }, 1
local k, cb, cr = env.wheelReal(rw, info, G, rw.cfg)
local load = rw.realLoad
local cd = 2 * env.R2_WHEEL_ZETA * math.sqrt(k * load / G)
check("a rover's wheel keeps its own sizing", near(k, load / (env.R2_WHEEL_SAG * env.R2_WHEEL_TRAVEL.M), 1e-9)
  and near(cb, cd * env.R2_REAL_BUMP, 1e-9) and near(cr, cd * env.R2_REAL_REBOUND, 1e-9))
R2.wheels, R2.nOut, R2.gear = saved, 3, true

-- THE CLIMB CAP IS A LANDING'S. On the frequency path (the default) the
-- climb cap acts only with the throttle under R2_GEAR_THR: a take-off roll
-- lifting off at 4 m/s on full throttle with a tyre still down is left alone
-- (the probe jet's legs were slammed onto their stops at every lift-off); a
-- landing's rebound at idle is capped. The pitch cap acts on the ground
-- throughout.
local node = { yaw = 0, pitch = 0, roll = 0 }
info.inertia = { env.vec3(5, 0, 0), env.vec3(0, 5, 0), env.vec3(0, 0, 5) }
local function legs(down, real)
  for _, x in ipairs(R2.wheels) do
    x.real, x.jointed, x.down, x.joint_age = real, true, down, 1.0
    x.tyre = { valid = true, getcomponent = function() return { position = 0.03 * 57.29578 } end }
  end
end
local function ticks(n, vu, q)
  info.vel, info.angVel = env.vec3(0, vu, 0), env.vec3(0, 0, q)
  for _ = 1, n do
    env.time = env.time + 1 / 60
    local okg, eg = pcall(env.gearOleo, node, info, 1 / 60, { x = 0, y = 1, z = 0 }, G)
    if not okg then check("gearOleo runs", false, tostring(eg)); return end
  end
end
legs(true, nil)
env.throttle = 1.0
ticks(600, 0, 0)               -- ten seconds of take-off roll on full throttle
impulses = 0
ticks(20, 4.0, 0.2)            -- lifting off at 4 m/s, rotating at 0.2 rad/s, a tyre still down
check("a take-off's lift-off is not capped", impulses == 0, tostring(impulses) .. " impulses")
env.throttle = 0.0
legs(false, nil)
ticks(60, -2.0, 0)             -- a landing: a second in the air at idle
legs(true, nil)
ticks(1, -2.0, 0)              -- the touchdown
impulses = 0
ticks(5, 4.0, 0.2)             -- thrown back up at 4 m/s
check("a landing's rebound is capped", impulses > 0, tostring(impulses) .. " impulses")
env.throttle = 1.0
impulses = 0
ticks(5, 4.0, 0.2)
check("…but not a touch-and-go's climb on full throttle", impulses == 0, tostring(impulses) .. " impulses")
impulses = 0
ticks(3, 0, 1.0)               -- pitching at 1 rad/s on the ground (a nose-over under the brakes)
check("the pitch cap holds on the ground, throttle or not", impulses > 0, tostring(impulses) .. " impulses")
env.throttle = 0.0
-- THE OLEO'S STROKE RATE when the engine hands the stroke over once a frame
-- (two ticks a frame: every other tick reads the same stroke): the rate is
-- the stroke's change over the time it took, not 0 then twice it
local w1 = R2.wheels[1]
w1.oleo_s, w1.oleo_t, w1.oleo_sd = nil, nil, nil
local sds, pos = {}, 0.03
for k = 1, 40 do
  if k % 2 == 1 then pos = pos + 0.002 end   -- 0.002 m a frame = 0.06 m/s
  local p = pos
  for _, x in ipairs(R2.wheels) do x.tyre = { valid = true, getcomponent = function() return { position = p * 57.29578 } end } end
  env.time = env.time + 1 / 60
  env.gearOleo(node, info, 1 / 60, { x = 0, y = 1, z = 0 }, G)
  if k > 20 then sds[#sds + 1] = w1.oleo_sd end
end
local lo, hi = math.huge, -math.huge
for _, v in ipairs(sds) do lo, hi = math.min(lo, v), math.max(hi, v) end
check("a stroke read every other tick gives a steady rate", lo > 0.045 and hi < 0.075, string.format("%.3f..%.3f m/s", lo, hi))
for _ = 1, 4 do env.time = env.time + 1 / 60; env.gearOleo(node, info, 1 / 60, { x = 0, y = 1, z = 0 }, G) end
check("…and a stroke that stops reads still within a few ticks", math.abs(w1.oleo_sd) < 0.03, string.format("%.3f", w1.oleo_sd))

-- on real-unit legs (R2_REAL_GEAR) neither the script's damper nor the caps push
legs(false, true)
ticks(60, 2.0, 0)
legs(true, true)
ticks(1, -2.0, 0)
impulses = 0
ticks(5, 4.0, 1.0)
check("real-unit legs: gearOleo pushes nothing (no damper, no climb or pitch cap)", impulses == 0, tostring(impulses) .. " impulses")

-- A CRAFT BUILT STANDING UP (a VAB spaceplane: nose +Y, gear legs along +Z):
-- each tyre's axle is laid across the nose and the leg, so it rolls along
-- the runway once the craft lies level, and it does not steer
local up = { uid = 33, d = { id = "gearS", wheel = "S" }, gear = true, size = "S", r = 0.25, axle = { 0, 0, 1 } }
up.cfg = env.r2WheelCfg(up.d)
env.r2WheelSetup(up, { x = 1, z = 0 })   -- (the front read level in X-Z: the wing)
check("laid across the wing, a standing craft's gear axle is its Z (it cannot roll)", near(up.steer0, 0, 1e-9))
env.r2UprightGear(up, { 0, 0, 1 })       -- the leg along +Z
local a = math.rad(up.steer0)
check("r2UprightGear: the axle across the nose and the leg (the hull's X)", near(math.sin(a), 1, 1e-9) or near(math.sin(a), -1, 1e-9),
  string.format("steer0 %.1f", up.steer0))
local side = { uid = 34, d = { id = "gearM", wheel = "M" }, gear = true, size = "M", r = 0.4, axle = { 0, 0, 1 } }
env.r2UprightGear(side, { 1, 0, 0 })     -- a leg along +X (the gear on a flank)
check("…and the hull's Z for a leg along X", near(side.steer0, 0, 1e-9), string.format("%.1f", side.steer0))
local plan_ws = { up, side }
up.cx, up.cy, up.cz, side.cx, side.cy, side.cz = 2.5, 0, 0, -0.3, 0, 1
env.r2SteerPlan(plan_ws, { x = 1, z = 0 }, { [1] = { x = 0, y = 0, z = 0, mass = 1 } }, {})
check("an upright craft's gear does not steer", not up.steers and not side.steers)

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("%d passed, %d failed", passes, #failures))
  os.exit(1)
end
print(string.format("smoke_gear_legs: %d passed", passes))
