-- SMOKE HARNESS: a rover's keys in the air (vessel_controller.lua,
-- r2AirMode / r2AirStick).
--
-- "when driving a rover you are holding w to go forward but as soon as you
-- get any air w is making the craft tilt to the right ... you would expect
-- accelerating forwards in the air would make the craft tilt backwards like a
-- dirtbike" (playtest 2026-10-26). Off its tyres a rover fell through to the
-- SHIP's stick, whose pitch axis (ship right = −Z × +Y = +X) is a rover's
-- default FRONT, so W rolled it right. This holds that:
--
--   * a rover (driven wheels, not landing gear) just off the ground is in
--     rover-air mode; on its tyres, a plane on its gear, a craft with no
--     wheels, or one aloft for longer than ROVER_AIR_HOLD is not;
--   * W tips the front DOWN and S up, about the rover's own right axis, with
--     no roll and no yaw in it, at the gentle ROVER_AIR_RATE — and, with the
--     local up known, only as far as ROVER_AIR_LEAN from the pitch it left
--     the ground with, where a held W holds it;
--   * A/D lean the roof left/right, Q/E turn the front left/right;
--   * off the keys, SAS on holds the rover still, SAS off lets it coast;
--   * all of it on the rover's axes whatever way the craft is turned.
--
--   luajit solar/tests/smoke_rover_air.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

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

local function v(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function near(a, b, e) return math.abs(a - b) < (e or 1e-9) end
local ZERO = v(0, 0, 0)
local RATE = env.ROVER_AIR_RATE

-- 1. which craft is a rover in the air
local R2 = env.R2
env.time = 100
R2.wheels, R2.gear, R2.driving, R2.onWheels, R2.ground_t = {}, false, false, false, nil
check("no wheels: not a rover", env.r2AirMode({}) == false)
R2.wheels = { { uid = 2 }, { uid = 3 } }
R2.driving = true
check("on its tyres: driving, not rover-air", env.r2AirMode({}) == false)
R2.driving = false
env.time = 101
check("just off the ground: rover-air", env.r2AirMode({}) == true)
env.time = 100 + env.ROVER_AIR_HOLD + 0.5
check("long aloft (a cliff, a lander drop): the ship's stick again", env.r2AirMode({}) == false)
check("grounded by its hull: not rover-air", env.r2AirMode({ grounded = true }) == false)
env.time = env.time + 0.5
check("…and just after, rover-air again", env.r2AirMode({}) == true)
check("clamped: not rover-air", env.r2AirMode({ anchored = true }) == false)
R2.gear = true
env.time = env.time + 0.1
check("a plane on its landing gear keeps the ship's (aero) stick", env.r2AirMode({}) == false)
R2.gear = false

-- 2. the cause: the ship stick's pitch axis for an upright pod is the rover's
-- front (+X by default, r2FrontOf)
local ship_right = cross(v(0, 0, -1), v(0, 1, 0))
check("(the old bug) ship pitch axis = the rover's front +X", near(ship_right.x, 1) and near(ship_right.y, 0) and near(ship_right.z, 0))

-- 3. the keys on the rover's axes, for a level rover and for one turned and tilted
local function rot(yaw, pitch, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cx, sx = math.cos(pitch), math.sin(pitch)
  local cz, sz = math.cos(roll), math.sin(roll)
  return v(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz),
         v(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz),
         v(sy * cx, -sx, cy * cx)
end
for _, pose in ipairs({ { 0, 0, 0, "level" }, { 1.1, 0.3, -0.4, "turned and tilted" }, { -2.5, -0.6, 0.9, "upside-ish" } }) do
  local rx, up, rz = rot(pose[1], pose[2], pose[3])
  for _, F in ipairs({ { x = 1, z = 0 }, { x = 0, z = -1 } }) do
    local tag = pose[4] .. string.format(" front (%d,%d)", F.x, F.z)
    local Fw = v(rx.x * F.x + rz.x * F.z, rx.y * F.x + rz.y * F.z, rx.z * F.x + rz.z * F.z)
    local Rt = cross(Fw, up)
    local function stick(k, w, hold) return v(env.r2AirStick(k, rx, up, rz, w or ZERO, hold ~= false, F)) end
    local W = stick({ p = 1 })
    local dF = cross(W, Fw)        -- how the front moves
    check(tag .. ": W lifts the front (lean back, like a dirt bike)", dot(dF, up) > 0.99 * RATE, string.format("%.3f", dot(dF, up)))
    check(tag .. ": W neither rolls nor yaws", near(dot(W, Fw), 0, 1e-9) and near(dot(W, up), 0, 1e-9))
    check(tag .. ": W is gentle (ROVER_AIR_RATE)", near(math.sqrt(dot(W, W)), RATE, 1e-9) and RATE <= 0.8)
    local S = stick({ p = -1 })
    check(tag .. ": S tips the front down", dot(cross(S, Fw), up) < -0.99 * RATE)
    local A = stick({ y = 1 })
    check(tag .. ": A leans the roof left", dot(cross(A, up), Rt) < -0.99 * RATE and near(dot(A, Rt), 0, 1e-9))
    local D = stick({ y = -1 })
    check(tag .. ": D leans the roof right", dot(cross(D, up), Rt) > 0.99 * RATE)
    local E = stick({ r = 1 })
    check(tag .. ": E turns the front right", dot(cross(E, Fw), Rt) > 0.99 * RATE and near(dot(E, Fw), 0, 1e-9))
    local spin = v(0.3, -0.7, 1.1)
    local held = stick({}, spin, true)
    check(tag .. ": off the keys, SAS holds it still", near(held.x, 0) and near(held.y, 0) and near(held.z, 0))
    local free = stick({}, spin, false)
    check(tag .. ": off the keys, SAS off lets it coast", near(free.x, spin.x, 1e-9) and near(free.y, spin.y, 1e-9) and near(free.z, spin.z, 1e-9))
    local Wspin = stick({ p = 1 }, spin, true)
    check(tag .. ": W with SAS on leaves the other axes held", near(dot(Wspin, Fw), 0, 1e-9) and near(dot(Wspin, up), 0, 1e-9))
  end
end

-- 4. the keys LEAN it (the live path: the local up known): W asks for
-- ROVER_AIR_LEAN nose-down from the pitch it left the ground with and holds
-- there — a held W (it is the drive key) must not pitch the rover over
do
  local LEAN = env.ROVER_AIR_LEAN
  check("the lean is gentle (10-20 deg)", LEAN >= math.rad(10) and LEAN <= math.rad(20))
  local U = v(0, 1, 0)
  local F = { x = 1, z = 0 }
  local function posed(pitch, roll)   -- a rover pitched (nose up +) and leaned (roof left +)
    -- front +X tipped up by `pitch` about +Z, then the roof leaned about the front
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local Fw = v(cp, sp, 0)
    local up0 = v(-sp, cp, 0)
    local R0 = cross(Fw, up0)
    local cr, sr = math.cos(roll), math.sin(roll)
    -- lean left: the roof turns toward −right
    local up = v(up0.x * cr - R0.x * sr, up0.y * cr - R0.y * sr, up0.z * cr - R0.z * sr)
    local rz = cross(Fw, up)     -- the vessel's +Z = X × Y with X = front
    return Fw, up, rz
  end
  local ref = {}
  local rx, up, rz = posed(0, 0)
  local W = v(env.r2AirStick({ p = 1 }, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: the reference is the attitude it left the ground with", ref.th and math.abs(ref.th) < 1e-9)
  check("lean: W starts the nose up", dot(cross(W, rx), U) > 0.1)
  rx, up, rz = posed(LEAN, 0)
  W = v(env.r2AirStick({ p = 1 }, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: at the lean, a held W holds it there", math.sqrt(dot(W, W)) < 1e-6, string.format("%.4f", math.sqrt(dot(W, W))))
  rx, up, rz = posed(-0.5, 0)
  W = v(env.r2AirStick({ p = 1 }, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: past it, a held W brings the nose back up", dot(cross(W, rx), U) > 0)
  local off = v(env.r2AirStick({}, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: off the keys, SAS takes it back to its take-off pitch", dot(cross(off, rx), U) > 0)
  local held = v(env.r2AirStick({ p = 1 }, rx, up, rz, v(0, 0, 9), true, F, U, ref))
  check("lean: never faster than ROVER_AIR_RATE", math.sqrt(dot(held, held)) <= env.ROVER_AIR_RATE * math.sqrt(3) + 1e-9)
  rx, up, rz = posed(0, 0)
  local A = v(env.r2AirStick({ y = 1 }, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: A starts the roof left", dot(cross(A, up), cross(rx, up)) < -0.1)
  rx, up, rz = posed(0, LEAN)
  A = v(env.r2AirStick({ y = 1 }, rx, up, rz, ZERO, true, F, U, ref))
  check("lean: at the lean, a held A holds it", math.sqrt(dot(A, A)) < 1e-6, string.format("%.4f", math.sqrt(dot(A, A))))
  local ref2 = {}
  rx, up, rz = posed(0.3, 0)
  local none = v(env.r2AirStick({}, rx, up, rz, ZERO, true, F, U, ref2))
  check("lean: off a ramp nose-up, SAS holds that pitch (no fight)", math.sqrt(dot(none, none)) < 1e-6)
end

if #failures > 0 then
  print(string.format("smoke_rover_air: %d passed, %d FAILED", passes, #failures))
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_rover_air: all %d checks passed", passes))
