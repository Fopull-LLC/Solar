-- SMOKE HARNESS: rover wheels (vessel_controller.lua, wheel_spec: `wcfg`).
--
-- "theyre kind of swivelling in opposite directions weirdly and rolling when
-- im just turning. turning should move the direction theyre tilting and
-- forward or back makes them go forward or back." This holds that:
--
--   * a wheel's settings come from its craft record's `wcfg`, with defaults
--     for an old craft and clamps for nonsense;
--   * every wheel's spin sign rolls it toward the craft's front, however it
--     is mounted (mirrored pairs, a wheel on the front face);
--   * A/D steers the wheels ahead of the centre of mass the same way (toward
--     the turn), the inside one more (Ackermann), the rear ones not at all,
--     and no wheel is driven against another;
--   * steering eases off with speed; skid steer is opt-in.
--
--   luajit solar/tests/smoke_wheels.lua

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

local HP = math.pi / 2
-- the vessel-frame basis of a part (same formula the controller uses)
local function basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end

-- 1. settings
local c0 = env.r2WheelCfg({ id = "wheelM" })
check("an old craft's wheel gets the defaults", c0.steer == "auto" and c0.steerMax == 25 and c0.drive == "auto"
  and c0.motor == 1 and c0.brake == 1 and c0.spring == 1 and c0.friction == 1 and c0.skid == false)
local c1 = env.r2WheelCfg({ wcfg = { steer = "INVERT", steerMax = 200, spring = 9, friction = 0.1, drive = "sideways", skid = true } })
check("settings are read and clamped", c1.steer == "invert" and c1.steerMax == 60 and c1.spring == 4
  and c1.friction == 0.5 and c1.drive == "auto" and c1.skid == true)

-- 2. a four-wheel rover as the builder lays it out (r2 probe's build):
-- body at the origin, front +X, wheels on the ±Z flanks, their axles out.
local bp = {
  [1] = { x = 0, y = 0.62, z = 0, mass = 0.35, front = 1, yaw = 0, pitch = 0, roll = 0 },
  [2] = { x = 0.66, y = 0.42, z = 0.7, mass = 0.12, yaw = -HP },
  [3] = { x = 0.66, y = 0.42, z = -0.7, mass = 0.12, yaw = HP },
  [4] = { x = -0.66, y = 0.42, z = 0.7, mass = 0.12, yaw = -HP },
  [5] = { x = -0.66, y = 0.42, z = -0.7, mass = 0.12, yaw = HP },
  [6] = { x = 0.05, y = 1.17, z = 0, mass = 1.0 },
}
local function bpbasis(yaw, pitch, roll) return basis(yaw, pitch, roll) end
local F = env.r2FrontOf(bp, {}, 6, bpbasis)
check("the rover body's +X is the front", math.abs(F.x - 1) < 1e-6 and math.abs(F.z) < 1e-6,
  string.format("%.2f %.2f", F.x, F.z))

local function wheels_of(bpt, Fv)
  local ws = {}
  for u = 1, 10 do
    local d = bpt[u]
    if d and u ~= 1 and u ~= 6 and not d.notwheel then
      local X = basis(d.yaw, d.pitch, d.roll)
      local w = { uid = u, d = d, axle = X, r = 0.4, cx = d.x + X[1] * 0.07, cy = d.y, cz = d.z + X[3] * 0.07 }
      env.r2WheelSetup(w, Fv)
      ws[#ws + 1] = w
    end
  end
  env.r2SteerPlan(ws, Fv, bpt, {})
  return ws
end
local ws = wheels_of(bp, F)
local same = true
for _, w in ipairs(ws) do if w.rs ~= ws[1].rs or w.rs == 0 then same = false end end
check("mirrored wheels all roll the same way (toward the front)", same)
local n_front, rear_steer = 0, false
for _, w in ipairs(ws) do
  if w.a > 0 then n_front = n_front + (w.steers and 1 or 0) else rear_steer = rear_steer or w.steers end
end
check("the two front wheels steer, the rear ones don't", n_front == 2 and not rear_steer)

-- a left turn at a crawl
local cmd = env.r2WheelCmd(ws, env.R2.plan, 0.5, 1, 1.0)
local fl, fr
for k, w in ipairs(ws) do
  if w.a > 0 and w.l > 0 then fl = cmd[k] elseif w.a > 0 then fr = cmd[k] end
  check("wheel " .. w.uid .. " is driven forward, not against the others", cmd[k].drive > 0, tostring(cmd[k].drive))
end
check("both front wheels turn toward the turn (left = +)", fl.steer > 0 and fr.steer > 0,
  string.format("%.1f %.1f", fl.steer, fr.steer))
check("the inside wheel turns more (Ackermann), to the lock", fl.steer > fr.steer and math.abs(fl.steer - 25) < 1e-6,
  string.format("%.1f %.1f", fl.steer, fr.steer))
local outer_faster = true
for k, w in ipairs(ws) do
  for k2, w2 in ipairs(ws) do
    if math.abs(w.a - w2.a) < 1e-6 and w.l > w2.l and cmd[k].drive >= cmd[k2].drive then outer_faster = false end
  end
end
check("the outside wheels run faster than the inside ones", outer_faster)
local right = env.r2WheelCmd(ws, env.R2.plan, 0.5, -1, 1.0)
local mirrored = true
for k, w in ipairs(ws) do
  for k2, w2 in ipairs(ws) do
    if math.abs(w.a - w2.a) < 1e-6 and math.abs(w.l + w2.l) < 1e-6 and math.abs(right[k].steer + cmd[k2].steer) > 1e-6 then mirrored = false end
  end
end
check("a right turn mirrors it", mirrored)
local fast = env.r2WheelCmd(ws, env.R2.plan, 1, 1, 9.0)
local fast_max = 0
for _, c in ipairs(fast) do fast_max = math.max(fast_max, math.abs(c.steer)) end
check("steering eases off with speed", fast_max < 14, string.format("%.1f°", fast_max))
local straight = env.r2WheelCmd(ws, env.R2.plan, 1, 0, 3.0)
local all_one = true
for _, c in ipairs(straight) do if c.steer ~= 0 or math.abs(c.drive - 1) > 1e-9 then all_one = false end end
check("no steering: every wheel straight and at the same speed", all_one)
local pivot = env.r2WheelCmd(ws, env.R2.plan, 0, 1, 0)
local still = true
for _, c in ipairs(pivot) do if math.abs(c.drive) > 1e-9 then still = false end end
check("A alone turns the wheels and drives none of them (no skid steer by default)", still)

-- 2b. useful speed (playtest 2026-10-23: "about as fast as walking")
local wm = { size = "M", m = { torque = 0.5, speed = 7.0 } }      -- an old craft's record
check("a medium wheel tops out at 15-25 m/s on a 9.8 world, whatever its old record says",
  env.r2TopSpeed(wm, 9.8) >= 15 and env.r2TopSpeed(wm, 9.8) <= 25, string.format("%.1f", env.r2TopSpeed(wm, 9.8)))
check("small < medium < large", env.r2TopSpeed({ size = "S", m = {} }, 9.8) < env.r2TopSpeed(wm, 9.8)
  and env.r2TopSpeed(wm, 9.8) < env.r2TopSpeed({ size = "L", m = {} }, 9.8))
check("a catalogue that rates a wheel faster wins", env.r2TopSpeed({ size = "M", m = { speed = 40 } }, 9.8) == 40)
check("a light world slows it (less grip), never below 60 %",
  env.r2TopSpeed(wm, 3.5) < env.r2TopSpeed(wm, 9.8) and env.r2TopSpeed(wm, 1.0) >= 0.6 * env.r2TopSpeed(wm, 9.8) - 1e-9)
check("an old record's weak motor gets the size's torque floor, rated like thrust",
  math.abs(env.r2FullTorque(wm, 1.4) - env.R2_WHEEL_TORQUE.M * 1.4) < 1e-9)
check("the tyres stay out well past a medium wheel's top speed", env.R2_TYRES_VMAX > env.r2TopSpeed({ size = "L", m = {} }, 9.8))
-- a light rover on M wheels at 0.8 t pushes 0.55 g with its floors at 1×
check("four floored M motors can push a 0.8 t rover at the traction control's 0.55 g",
  4 * env.r2FullTorque(wm, 1) / 0.4 >= 0.8 * 9.8 * env.R2_TC)

-- 2c. speed-sensitive steering by the turn it pulls (r2Lateral)
local plan = env.R2.plan
check("the plan knows the track and how tall the rover stands", (plan.track or 0) > 1.2 and (plan.hcg or 0) > 0.2,
  string.format("track %.2f hcg %.2f", plan.track or -1, plan.hcg or -1))
local alat = env.r2Lateral(9.8, plan, env.R2_TYRE_MU)
check("a turn may use no more than the tyres' grip, with margin", alat <= 9.8 * env.R2_TYRE_MU + 1e-9 and alat >= 0.15 * 9.8,
  string.format("%.2f", alat))
local tall = { track = plan.track, hcg = plan.hcg * 3 }
check("a tall rover is allowed less (rollover threshold)", env.r2Lateral(9.8, tall, env.R2_TYRE_MU) < alat)
local function lock_at(v)
  local c = env.r2WheelCmd(ws, env.R2.plan, 1, 1, v, alat)
  local mx = 0
  for _, cc in ipairs(c) do mx = math.max(mx, math.abs(cc.steer)) end
  return mx
end
check("full lock at a crawl", math.abs(lock_at(1.0) - 25) < 1e-6, string.format("%.1f", lock_at(1.0)))
-- the turn it asks for at 20 m/s pulls no more than alat: v² tan δ / wheelbase
local wb = 0
for _, w in ipairs(ws) do if w.steers then wb = math.max(wb, math.abs(w.a - plan.pivot)) end end
local d20 = math.rad(lock_at(20))
check("at 20 m/s the inside wheel's lock pulls at most alat sideways",
  400 * math.tan(d20) / wb <= alat * 1.0001 and lock_at(20) > 0.3, string.format("%.2f° → %.2f m/s²", lock_at(20), 400 * math.tan(d20) / wb))
check("steering always eases with speed", lock_at(5) >= lock_at(10) and lock_at(10) >= lock_at(20))

-- 2d. a parked rover can time-warp (the engine never counts a chassis on its
-- tyres grounded, so it is pinned for the warp and let go after)
env.R2.wheels, env.R2.live, env.R2.warp_pin = ws, true, false
env.r2WarpPin({}, { anchored = false, vel = { x = 0.4, y = 0, z = 0.3 } })
check("a parked rover on its tyres is pinned for warp", env.R2.warp_pin == true)
env.R2.warp_pin = false
env.r2WarpPin({}, { anchored = false, vel = { x = 12, y = 0, z = 0 } })
check("a rover driving at speed is not", env.R2.warp_pin == false)
env.r2WarpPin({}, { anchored = true, vel = { x = 0, y = 0, z = 0 } })
check("a craft on its launch clamps is left to them", env.R2.warp_pin == false)
env.R2.live = false

-- 3. options: skid steer, a flipped wheel, rear steer, a wheel on the front face
bp[2].wcfg = { skid = true }
bp[4].wcfg = { drive = "invert", steer = "on" }
bp[5].wcfg = { steer = "on" }
local ws2 = wheels_of(bp, F)
local by = {}
for k, w in ipairs(ws2) do by[w.uid] = w end
check("drive invert flips a wheel's spin sign", by[4].rs == -by[2].rs)
check("steer on makes a rear wheel steer", by[5].steers == true and by[3].steers == true)
local c2 = env.r2WheelCmd(ws2, env.R2.plan, 0, 1, 0)
local skid_spin = 0
for k, w in ipairs(ws2) do if w.uid == 2 then skid_spin = c2[k].drive end end
check("skid steer drives a wheel on the spot when asked for", skid_spin ~= 0)
local c3 = env.r2WheelCmd(ws2, env.R2.plan, 0.5, 1, 1.0)
local s3, s5
for k, w in ipairs(ws2) do if w.uid == 3 then s3 = c3[k].steer elseif w.uid == 5 then s5 = c3[k].steer end end
check("a steering rear wheel turns opposite the front ones", s3 > 0 and s5 < 0, string.format("%.1f %.1f", s3, s5))

local bpf = {
  [1] = { x = 0, y = 0.6, z = 0, mass = 0.35, front = 1 },
  [2] = { x = 0.9, y = 0.4, z = 0, mass = 0.12, yaw = 0 },        -- on the front face, axle along +X
}
local Ff = env.r2FrontOf(bpf, {}, nil, bpbasis)
local wf = wheels_of(bpf, Ff)
check("a wheel with its axle along the front gets a 90° base steer", math.abs(math.abs(wf[1].steer0) - 90) < 1e-6
  or (wf[1].rs == 0), tostring(wf[1].steer0))

-- a seat facing −X is the front when there is no rover body
local bps = { [1] = { x = 0, y = 0, z = 0, mass = 0.1, seat = 1, yaw = math.pi } }
local Fs = env.r2FrontOf(bps, {}, nil, bpbasis)
check("a command seat's facing is the front", Fs.x < -0.99, string.format("%.2f %.2f", Fs.x, Fs.z))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("%d passed, %d failed", passes, #failures))
  os.exit(1)
end
print(string.format("smoke_wheels: %d passed", passes))
