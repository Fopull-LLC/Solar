-- SMOKE: the auto-engineering maths and parts (scripts/auto_drive.lua,
-- scripts/parts_auto.lua; docs/auto-engineering.md). Both are pure libraries,
-- loaded from disk with nothing of the engine around them.
--
--   luajit solar/tests/smoke_moto.lua
--
-- Holds:
--   * suspJoint gives the engine's soft wheel joint exactly the spring and
--     damper asked for (its forward model, jointRates, agrees), and never
--     more than the joint can carry on a light tyre;
--   * springFor sits a corner a third into its travel;
--   * a raked fork's base steer lines the engine's axle up with the wheel's,
--     and a rake the engine can't carry falls back to an upright axis;
--   * the balance: a bike leaning right is pushed back left by the torque,
--     steered right (under the fall) by the bars; a lean asked for at speed
--     is held as an equilibrium; a countersteer starts a turn;
--   * the parts register into the ROVER section once, each with the keys
--     the builder and the flight read; the Moto Saddle is a crewed open
--     seat whose prefab sits its rider astride (command_seat's params).

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local A = load("solar/scripts/auto_drive.lua")
local P = load("solar/scripts/parts_auto.lua")

-- ── 1. the spring on the engine's joint ─────────────────────────────────────
local dt = 1 / 60
for _, c in ipairs({ { 40, 1.0, 0.021 }, { 25, 0.6, 0.021 }, { 41, 3.0, 0.072 }, { 120, 4.0, 0.15 } }) do
  local k, cd, m = c[1], c[2], c[3]
  local f, z, ke, ce = A.suspJoint(k, cd, m, dt)
  local k2, c2 = A.jointRates(f, z, m, dt)
  check(string.format("suspJoint k %g c %g m %g: the joint's forward model agrees", k, cd, m),
    near(k2, ke, 1e-3 * ke) and near(c2, ce, 1e-3 * math.max(ce, 0.01)), string.format("%g/%g vs %g/%g", k2, c2, ke, ce))
  check(string.format("suspJoint k %g: the spring asked for when the joint can carry it", k), near(ke, k, 1e-3 * k) or ke < k,
    string.format("got %g", ke))
  check(string.format("suspJoint c %g: never more damping than m/dt", cd), ce <= m / dt * A.CMAX + 1e-9, tostring(ce))
  check(string.format("suspJoint f %g / ζ %g sane", f, z), f > 0 and f < 200 and z >= 0 and z < 50)
end
-- a spring too stiff for a feather-light tyre is capped, not wound up past it
local f, z, ke = A.suspJoint(500, 1, 0.021, dt)
check("a spring past the light tyre's limit is capped at the most the joint can give", ke < 500 and ke > 20, tostring(ke))

local k, c = A.springFor(1.7, 0.12, 0.33, 0.5, 9.8, 1, 1)
check("springFor: the corner's weight sits it a third into its travel (3 g bottoms it)", near(1.7 / k, 0.0396, 1e-6), tostring(1.7 / k))
local k2 = A.springFor(1.7, 0.12, 0.33, 0.5, 9.8, 2, 1)
check("springFor: the wheel's Spring setting scales the rate", near(k2, 2 * k, 1e-9))
check("springFor: damping near half critical on the corner's sprung mass", near(c, 2 * 0.5 * math.sqrt(k * 1.7 / 9.8), 1e-9))

-- ── 2. the steering axis ────────────────────────────────────────────────────
local rk = math.rad(24)
local a = { -math.sin(rk), math.cos(rk), 0 }
local s0, err = A.axleSteer(a, { 0, 0, 1 })
check("raked fork on a craft facing ±X: no base steer, axle exact", near(s0, 0, 1e-6) and err < 1e-3, s0 .. " " .. err)
local s1, e1 = A.axleSteer(a, { 0, 0, -1 })
check("…mounted the other way round: the same axle (D and −D)", near(s1, 0, 1e-6) and e1 < 1e-3)
local up = { 0, 1, 0 }
local s2 = A.axleSteer(up, { 1, 0, 0 })
local ax2 = A.axleOf(up, s2)
check("upright axis: a wheel with its axle along X gets a 90° base steer", near(math.abs(ax2[1]), 1, 1e-6), table.concat(ax2, ","))
-- a fork on a craft built facing ±Z: its rake can't carry the axle → upright
local Xf, Yf, Zf = { 0, 0, 1 }, { 0, 1, 0 }, { -1, 0, 0 }    -- fork +X along vessel +Z
local axis, st0, raked = A.suspAxis({ ax = a[1], ay = a[2], az = a[3] }, Xf, Yf, Zf, { 1, 0, 0 })
check("rake the engine can't carry (craft facing Z) falls back to upright", not raked and near(axis[2], 1, 1e-9))
local axis3, _, raked3 = A.suspAxis({ ax = a[1], ay = a[2], az = a[3] }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 0, 0, 1 })
check("…and a craft facing X keeps the raked axis", raked3 and near(axis3[1], a[1], 1e-9))
-- the joint itself always slides upright (the raked axis only draws): on a
-- leaning axis the engine's grip budget let a tyre push far harder in
-- reverse than forward (playtest 2026-10-27)
local ja, js0, jown = A.jointAxis({ ax = a[1], ay = a[2], az = a[3] }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 0, 0, 1 })
check("jointAxis: the spring slides along the craft's up", near(ja[2], 1, 1e-9) and near(js0, 0, 1e-6))
check("jointAxis: …and hands back the part's raked axis for the drawing", near(jown[1], a[1], 1e-9))
local ja2, js2 = A.jointAxis({ ax = 0, ay = 1, az = 0 }, { 0.7071, -0.7071, 0 }, { 0.7071, 0.7071, 0 }, { 0, 0, 1 }, { 0, 0, -1 })
check("jointAxis: a swing arm turned 45° on its mount still slides upright", near(ja2[2], 1, 1e-9) and near(js2, 0, 1e-6))
local gf, gr = A.gripShare(1.13, math.rad(45), 1), A.gripShare(1.13, math.rad(45), -1)
check("gripShare: on a 45° axis forward grip is a fraction of reverse (why the joint is upright)", gf < 0.5 and gr > 3, gf .. " " .. gr)
check("gripShare: upright, forward and reverse are the same", near(A.gripShare(1.13, 0, 1), A.gripShare(1.13, 0, -1), 1e-12))
local rd = A.rollDir(A.axleOf(up, 0), up)
check("rollDir: a positive spin about +Z rolls toward −X", near(rd[1], -1, 1e-9))

-- ── 3. the bike ─────────────────────────────────────────────────────────────
check("isBike: two wheels in line", A.isBike({ { l = 0 }, { l = 0.02 } }))
check("isBike: a car is not", not A.isBike({ { l = 0.8 }, { l = -0.8 }, { l = 0.8 }, { l = -0.8 } }))
check("isBike: a trike is not", not A.isBike({ { l = 0 }, { l = 0.86 }, { l = -0.86 } }))
check("isBike: one wheel is not", not A.isBike({ { l = 0 } }))
-- lean: front +X, world up +Y; the body's up tipped toward −Z (left) = + lean
local F, U = { 1, 0, 0 }, { 0, 1, 0 }
local phi = A.leanOf(F, { 0, math.cos(0.2), -math.sin(0.2) }, U)
check("leanOf: tipped left reads + lean", near(phi, 0.2, 1e-9), tostring(phi))
local _, rate = A.leanOf(F, U, U, { 1, 0, 0 })
check("leanOf: a turn about +front tips the roof right (− rate)", rate < 0)

local g, h, m = 9.8, 0.8, 0.3
local tq = A.bikeTorque(-0.2, 0, 0, m, h, g, 0, 10)
check("torque balance: leaning right is pushed back left", tq > 0, tostring(tq))
local tq0 = A.bikeTorque(0, 0, 0, m, h, g, 0, 10)
check("torque balance: upright and still asks nothing", near(tq0, 0, 1e-9))
-- in a steady turn at the lean it asks for, gravity and the turn cancel
local phiT = 0.3
local alat = g * math.tan(phiT)
local tqe = A.bikeTorque(phiT, 0, phiT, m, h, g, alat, 10)
check("torque balance: a steady turn at the asked lean needs no torque", near(tqe, 0, 1e-6), tostring(tqe))
check("torque balance: capped at its authority", math.abs(A.bikeTorque(-1, 0, 0, m, h, g, 0, 0.5)) <= 0.5 + 1e-9)
-- steering balance: falling right → bars right (− steer), into the fall
local st = A.bikeSteer(-0.15, 0, 0, 8, g, 1.5, h, 25)
check("steering balance: falling right steers right, under the fall", st < 0, tostring(st))
-- countersteer: upright, asked to lean left → the bars go RIGHT first
local cs = A.bikeSteer(0, 0, 0.3, 8, g, 1.5, h, 25)
check("steering balance: a lean to the left starts with a countersteer right", cs < 0, tostring(cs))
-- holding a left lean at its equilibrium steers left (the turn holds it up)
local hold = A.bikeSteer(0.3, 0, 0.3, 8, g, 1.5, h, 25)
check("steering balance: holding a left lean steers left", hold > 0, tostring(hold))
check("lean limit: none at a standstill", near(A.leanLimit(0, g, 1.5, 25, 0.7), 0, 1e-9))
check("lean limit: grip-bound at speed", near(A.leanLimit(20, g, 1.5, 25, 0.7), math.atan(0.7 * A.BIKE_MU_SHARE), 1e-9))
check("lean target: the stick's share of the limit", near(A.leanTarget(-0.5, 20, g, 1.5, 25, 0.7), -0.5 * math.atan(0.7 * A.BIKE_MU_SHARE), 1e-9))
check("feet hold it at a standstill, not at speed",
  A.balanceAuthority(0, true, 0) > A.balanceAuthority(0, true, 5) and A.balanceAuthority(0, true, 5) > 0)
check("no rider, no gyro: nothing holds it", A.balanceAuthority(0, false, 0) == 0)
check("a gyro holds it at any speed", A.balanceAuthority(1.5, false, 10) == 1.5)
check("steering share: none at a walk, all at speed", A.steerShare(1) == 0 and A.steerShare(10) == 1)

-- a crude roll simulation: the torque balance alone (gyro) holds a still bike
-- up from a 10° lean and settles it
do
  local p, w = math.rad(-10), 0
  local I = m * h * h
  for _ = 1, 600 do
    local t = A.bikeTorque(p, w, 0, m, h, g, 0, 1.5, I)
    local acc = (m * g * h * math.sin(p) + t) / I
    w = w + acc * dt
    p = p + w * dt
  end
  check("gyro sim: a still bike leaning 10° stands up within 10 s", math.abs(p) < math.rad(0.5), math.deg(p))
end
-- …and the steering balance alone holds a moving one (contact line
-- acceleration a = v² tan δ / L, roll h φ̈ = g sin φ − a cos φ)
do
  local p, w, v, L = math.rad(5), 0, 8, 1.5
  local lean_max = 0
  for k = 1, 600 do
    local tgt = (k > 120 and k < 360) and 0.25 or 0
    local d = math.rad(A.bikeSteer(p, w, tgt, v, g, L, h, 25))   -- (w: the lean rate, + left, as leanOf gives it)
    local a2 = v * v * math.tan(d) / L
    local acc = (g * math.sin(p) - a2 * math.cos(p)) / h
    w = w + acc * dt
    p = p + w * dt
    lean_max = math.max(lean_max, math.abs(p))
    if k == 340 then check("steering sim: an asked lean of 14° is reached and held", math.abs(p - 0.25) < 0.03, math.deg(p)) end
  end
  check("steering sim: back upright after", math.abs(p) < 0.02, math.deg(p))
  check("steering sim: never falls", lean_max < 0.6)
end

-- ── 4. the parts ────────────────────────────────────────────────────────────
local REG, CAT = { roverBody = {}, wheelM = {} }, { { "COMMAND", { "pod" } }, { "ROVER", { "roverBody", "wheelM" } } }
local n = P.register(REG, CAT)
check("register adds every auto part", n == #P.ORDER, tostring(n))
check("…into the ROVER section, after its own", CAT[2][2][1] == "roverBody" and CAT[2][2][3] == "wheelB" and #CAT[2][2] == 2 + #P.ORDER)
check("register twice adds nothing", P.register(REG, CAT) == 0 and #CAT[2][2] == 2 + #P.ORDER)
for _, id in ipairs(P.ORDER) do
  local d = REG[id]
  check(id .. " has a prefab, label, box, mass, cost and a catalogue line",
    d and d.prefab and d.label and d.h and d.rx and d.rz and d.mass and d.cost and d.desc)
  local f = io.open("solar/prefabs/" .. d.prefab .. ".prefab.ron")
  check(id .. "'s prefab exists", f ~= nil)
  if f then f:close() end
  local v = io.open("solar/prefabs/vis/" .. d.prefab .. ".prefab.ron")
  check(id .. "'s builder-stand (vis) prefab exists", v ~= nil)
  if v then v:close() end
end
local function mod(d, ty) for _, m in ipairs(d.mods or {}) do if m.type == ty then return m end end end
for _, id in ipairs({ "forkT", "swingArm", "strutS" }) do
  local s = mod(REG[id], "susp")
  check(id .. " carries a suspension with travel, sag, damping and an axis",
    s and s.travel > 0 and s.sag > 0 and s.zeta > 0 and (s.ax or s.ay or s.az))
  check(id .. " stands upright on whatever it is mounted on", REG[id].upright == true and REG[id].radial_orient == true)
end
check("the fork steers, the swing arm never, the strut by its wheel's rule",
  mod(REG.forkT, "susp").steer == 1 and mod(REG.swingArm, "susp").steer == 0 and mod(REG.strutS, "susp").steer == -1)
check("fork and swing arm take a wheel centred in a hub", REG.forkT.hubs[1].kind == "hub" and REG.swingArm.hubs[1].kind == "hub")
check("the strut's flange takes any part", REG.strutS.hubs[1].kind == "end")
local wb = REG.wheelB
local ends = 0
for _, hb in ipairs(wb.hubs) do if hb.kind == "end" then ends = ends + 1 end end
check("the moto wheel is a through-axle: a hub and two ends", ends == 2 and wb.hubpt and wb.hubax)
local dm = mod(wb, "drive")
check("the moto wheel drives, centred on its own part", dm and dm.centred == true and dm.r and dm.r > 0.2)
check("the gyro carries a gyro module", mod(REG.gyro, "gyro") and mod(REG.gyro, "gyro").torque > 0)
check("the battery pack holds charge", mod(REG.packB, "battery") and mod(REG.packB, "battery").ec > 0)
-- the Moto Saddle: a crew part that commands like the Command Seat
local sd = REG.saddle
local cm = sd and mod(sd, "command")
check("the saddle is a crewed open seat for one (F to ride, the rider in view)",
  sd and sd.kind == "crewed" and sd.seat == true and cm and cm.crew == 1 and cm.seat == true)
check("the saddle stacks by its bottom and takes nothing on top", sd and sd.bottom == true and sd.top == false)
check("the saddle is light and cheap", sd and sd.mass <= 0.05 and sd.cost <= 160)
do
  local f = io.open("solar/prefabs/PartSaddle.prefab.ron")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  check("the saddle's prefab seats its rider (command_seat, astride: pegs, grips)",
    src:find('kind: "command_seat"', 1, true) and src:find('("grips", 1.0)', 1, true) and src:find('("sit_up",', 1, true)
    and src:find("models/parts/moto_saddle.glb", 1, true))
  local v = io.open("solar/prefabs/vis/PartSaddle.prefab.ron")
  local vs = v and v:read("*a") or ""
  if v then v:close() end
  check("…and its builder-stand copy has no scripts or body", vs ~= "" and not vs:find('kind: "command_seat"', 1, true) and not vs:find("rigidbody", 1, true))
  local S = load("solar/scripts/command_seat.lua")
  check("command_seat: the Command Seat's pose is unchanged by default (no lift, no lean, stick hand up)",
    S.defaults.sit_up == 0 and S.defaults.lean_fwd == 0 and S.defaults.grips == 0 and S.defaults.hand_lift == 0.1)
end

if #failures > 0 then
  print(("smoke_moto: %d/%d FAILED"):format(#failures, #failures + passes))
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print(("smoke_moto: all %d checks passed"):format(passes))
