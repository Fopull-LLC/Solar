-- AUTO_DRIVE — the maths behind the auto-engineering parts (docs/
-- auto-engineering.md): suspension springs and dampers on the engine's wheel
-- joint, a raked steering axis, and how a two-wheeler stays up and leans.
--
-- A pure library on the AutoLib node (prefabs/AutoLib.prefab.ron): no scene
-- access, its globals are its API, loaded from disk by tests/smoke_moto.lua.
-- vessel_controller reaches it with findScript("auto_drive") (the moto patch)
-- and hands it numbers; everything that touches a node stays there.
--
-- UNITS: tonnes, metres, seconds, kN, kN·m (the game's). Angles in radians
-- unless a name says deg.

-- ── 1. THE SPRING ON THE ENGINE'S WHEEL JOINT ───────────────────────────────
-- The wheel joint's suspension is a SOFT constraint (floptle-physics
-- joints.rs soft_impulse, Box2D's soft step): a frequency f and a damping
-- ratio ζ, acting on the joint's effective mass along its axis — the light
-- TYRE's, not the hull's. Per step dt it is a spring and a damper of
--
--     k = m ω² / (1 + a2)        c = m a2 / ((1 + a2) dt)
--     ω = 2π f,  x = ω dt,  a2 = x (2ζ + x)
--
-- so a stiff f buys far less than m ω² (at 45 Hz and 60 Hz ticks, a thirtieth
-- of it), and no setting damps harder than m/dt (here, CMAX of it). suspJoint inverts that:
-- given the spring rate k (kN/m) and damping c (kN·s/m) a suspension wants,
-- it answers the f and ζ that make them — or the nearest the joint can give
-- (the damping capped at CMAX of m/dt, the stiffness at what that damping
-- allows: k ≤ m β / dt², β = c dt / m).
-- CMAX: how much of a tick's error the joint may take out at once. Near 1 the
-- joint is all but rigid each tick, and a light tyre chattered on the ground
-- against it (0.117.0-rc37: a parked bike's rear tyre at 30 Hz and 15 kN on a
-- 1.7 kN load, kicked to 7 m/s); at 0.6 the joint runs at 8–11 Hz, the
-- regime the stock rover's wheels have always used.
CMAX = 0.6
function suspJoint(k, c, m, dt)
  m = math.max(1e-4, m or 0.02)
  dt = (dt and dt > 0) and dt or (1 / 60)
  k = math.max(1e-3, k or 1)
  c = math.max(0, c or 0)
  local beta = math.min(CMAX, c * dt / m)
  -- the stiffest spring this much damping can carry
  local kmax = m * beta / (dt * dt)
  if beta < 1e-6 or k > kmax then
    -- not enough damping for this spring: the damping comes up to carry it
    -- (ζ = 0 and the spring alone sets a2), or both cap out
    local x2 = k * dt * dt / math.max(1e-9, m - k * dt * dt)
    if k * dt * dt >= m * CMAX then
      beta = CMAX
      local a2 = beta / (1 - beta)
      local w = math.sqrt(a2) / dt
      local kk = m * w * w / (1 + a2)
      return w / (2 * math.pi), 0, kk, m * a2 / ((1 + a2) * dt)
    end
    local x = math.sqrt(x2)
    local a2 = x2
    return (x / dt) / (2 * math.pi), 0, m * (x / dt) ^ 2 / (1 + a2), m * a2 / ((1 + a2) * dt)
  end
  local a2 = beta / (1 - beta)
  local w = math.sqrt(k * (1 + a2) / m)
  local x = w * dt
  local zeta = math.max(0, (a2 / x - x) / 2)
  return w / (2 * math.pi), zeta, k, m * beta / dt
end

-- What the engine's joint gives for a frequency and damping ratio (the
-- forward model above; the tests hold suspJoint to it).
function jointRates(f, zeta, m, dt)
  local w = 2 * math.pi * f
  local x = w * dt
  local a2 = x * (2 * zeta + x)
  return m * w * w / (1 + a2), m * a2 / ((1 + a2) * dt)
end

-- A suspension's spring rate and damping for the load on one wheel: the
-- craft's weight on it sits it `sag` of the way into `travel` (real bikes
-- and cars ride at a quarter to a third), damped at `zeta` of critical on the
-- sprung mass that corner carries. `ks`, `cs`: the wheel's Spring and
-- Damper settings (×, 0.25–4).
function springFor(load, travel, sag, zeta, g, ks, cs)
  travel = math.max(0.02, travel or 0.15)
  sag = math.max(0.1, math.min(0.8, sag or 0.3))
  g = math.max(0.1, g or 9.8)
  local k = math.max(0.05, load or 1) / (sag * travel) * (ks or 1)
  local mc = math.max(0.005, (load or 1) / g)
  local c = 2 * (zeta or 0.5) * math.sqrt(k * mc) * (cs or 1)
  return k, c
end

-- ── 2. AN AXIS THAT IS NOT UPRIGHT ──────────────────────────────────────────
-- The engine's wheel spins about the CHASSIS's Z turned by `steer` about the
-- joint's axis. A raked fork's axis leans back; the base steer that lines the
-- engine's axle up with the wheel's own (D, vessel frame) is the angle about
-- that axis from Z to D, both seen across it. D and −D are the same axle;
-- the smaller turn is taken. Returns steer0 (deg) and how far off the axle
-- still is (deg): Z can only be turned onto D if both sit at the same angle
-- to the axis — a fork on a craft built facing ±X, not one facing ±Z.
local function v3(x, y, z) return { x, y, z } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return v3(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]) end
local function unit(a)
  local l = math.sqrt(dot(a, a))
  if l < 1e-12 then return v3(0, 0, 0) end
  return v3(a[1] / l, a[2] / l, a[3] / l)
end
local function rot(v, k, a)
  local c, s = math.cos(a), math.sin(a)
  local d = dot(v, k)
  local cx = cross(k, v)
  return v3(v[1] * c + cx[1] * s + k[1] * d * (1 - c), v[2] * c + cx[2] * s + k[2] * d * (1 - c),
            v[3] * c + cx[3] * s + k[3] * d * (1 - c))
end
vec = { dot = dot, cross = cross, unit = unit, rot = rot }

function axleSteer(a, D)
  a, D = unit(a), unit(D)
  local Z = v3(0, 0, 1)
  local best, berr = 0, 180
  for _, sg in ipairs({ 1, -1 }) do
    local Dd = v3(D[1] * sg, D[2] * sg, D[3] * sg)
    local zp = unit(v3(Z[1] - a[1] * dot(a, Z), Z[2] - a[2] * dot(a, Z), Z[3] - a[3] * dot(a, Z)))
    local dp = unit(v3(Dd[1] - a[1] * dot(a, Dd), Dd[2] - a[2] * dot(a, Dd), Dd[3] - a[3] * dot(a, Dd)))
    local s = math.atan2(dot(cross(zp, dp), a), dot(zp, dp))
    local got = rot(Z, a, s)
    local err = math.deg(math.acos(math.max(-1, math.min(1, dot(got, Dd)))))
    if err < berr - 1e-6 or (math.abs(err - berr) < 1e-6 and math.abs(s) < math.abs(math.rad(best))) then
      best, berr = math.deg(s), err
    end
  end
  return best, berr
end

-- The way a positive spin rolls the wheel along the ground (vessel frame),
-- for an axle A and the vessel's up U: A × U (the contact patch runs the
-- other way under the centre).
function rollDir(A, U)
  return unit(cross(A, U or v3(0, 1, 0)))
end

-- The engine's axle for a joint axis and steer (deg): Z turned about a.
function axleOf(a, steerDeg)
  return rot(v3(0, 0, 1), unit(a), math.rad(steerDeg or 0))
end

-- A wheel's suspension axis and base steer: the part's axis (its own frame)
-- turned into the vessel frame by the suspension part's basis (X, Y, Z
-- columns as r2_basis gives them), pointing up the vessel; falling back to
-- the vessel's up when the raked axis can't carry this wheel's axle (more
-- than FALLBACK_DEG off). Returns axis, steer0 (deg), raked (bool).
FALLBACK_DEG = 4.0
function suspAxis(m, X, Y, Z, D)
  local ax = { m.ax or 0, m.ay or 1, m.az or 0 }
  local a = unit(v3(X[1] * ax[1] + Y[1] * ax[2] + Z[1] * ax[3], X[2] * ax[1] + Y[2] * ax[2] + Z[2] * ax[3],
                    X[3] * ax[1] + Y[3] * ax[2] + Z[3] * ax[3]))
  if a[2] < 0 then a = v3(-a[1], -a[2], -a[3]) end
  local s0, err = axleSteer(a, D)
  if a[2] > 0.2 and err <= FALLBACK_DEG then return a, s0, math.abs(a[2]) < 0.999 end
  local up = v3(0, 1, 0)
  local s1 = axleSteer(up, D)
  return up, s1, false
end

-- THE JOINT SLIDES ALONG THE PART'S OWN AXIS: a fork's rake, a swing arm
-- turned on its mount. From the playtest of 2026-10-27 ("the bike drives
-- much better BACKWARDS than forwards") to engine 0.117.1-dev.1374 every
-- joint slid along the craft's up instead (a `jointAxis` here): the wheel
-- joint's off-axle spin lock braked every wheel in proportion to its speed,
-- worst on two wheels in line and on a raked axis (floptle 0579; an in-line
-- rover went from 2.99 to 14.93 m/s with the fix). r2_scan uses suspAxis.

-- ── 3. A TWO-WHEELER ────────────────────────────────────────────────────────
-- A craft is a BIKE when it has two or more wheels and they all run in one
-- line: no two of them further apart across the craft than INLINE_TRACK (m).
-- It can't stand on its own; it stays up the way a rider keeps a real one up:
--   * at speed, by STEERING: the front wheel is turned under the fall (the
--     contact line is driven toward the side it leans to) so the lean goes
--     where the rider wants it — which is how a countersteer happens: to
--     lean left from upright the bars first go right;
--   * at a walk, by TORQUE: the rider's feet (a seated rider, at a crawl) or
--     a Balance Gyro (any speed, any crew, a probe core too).
-- A/D ask for a LEAN, and the turn follows from it: tan φ = v ψ̇ / g.
INLINE_TRACK = 0.3
function isBike(wheels)
  if not wheels or #wheels < 2 then return false end
  local lmin, lmax = math.huge, -math.huge
  for _, w in ipairs(wheels) do
    local l = w.l or 0
    lmin, lmax = math.min(lmin, l), math.max(lmax, l)
  end
  return (lmax - lmin) <= INLINE_TRACK
end

-- The lean φ (+ = leaning LEFT) and its rate, from the craft's axes: F its
-- front, B its own up, U the world's up (all world, unit), w its angular
-- velocity. A turn about +F tips the roof right, so φ̇ = −w·F.
function leanOf(F, B, U, w)
  local R = unit(cross(F, U))               -- right = front × up
  local phi = math.atan2(-dot(B, R), dot(B, U))
  local rate = w and -dot(w, F) or 0
  return phi, rate
end

-- How far the rider may ask it to lean at this speed: the grip's (a tyre
-- that slides out under the lean is a lowside) and the tightest turn the
-- fork's lock makes at this speed (asking for more would fall it in).
BIKE_MU_SHARE = 0.43   -- of R2_TYRE_MU 0.9: the 21° grip lean it gave at 0.55 of 0.7
BIKE_LEAN_MAX = math.rad(42)
function leanLimit(v, g, L, lockDeg, mu)
  g = math.max(0.1, g or 9.8)
  local grip = math.atan((mu or 0.9) * BIKE_MU_SHARE)
  local kap = math.tan(math.rad(lockDeg or 25)) / math.max(0.3, L or 1.4)
  local turn = math.atan((v or 0) * (v or 0) * kap / g)
  return math.min(BIKE_LEAN_MAX, grip, turn)
end

-- The lean the rider is asking for: the stick (−1…1, + left) of the limit.
function leanTarget(stick, v, g, L, lockDeg, mu)
  return math.max(-1, math.min(1, stick or 0)) * leanLimit(v, g, L, lockDeg, mu)
end

-- STEERING BALANCE (speed v > 0, forward): the sideways acceleration that
-- brings the lean to phiT like a damped spring (ω, ζ) — from the roll
-- equation h φ̈ = g sin φ − a cos φ (a = the contact line's acceleration to
-- the left) — and the fork angle that makes it on wheelbase L. Returns the
-- steer (deg, + left) clamped to the lock, and the acceleration asked.
BIKE_W, BIKE_Z = 1.6, 0.9
function bikeSteer(phi, rate, phiT, v, g, L, h, lockDeg)
  g = math.max(0.1, g or 9.8)
  h = math.max(0.2, h or 0.7)
  local w = BIKE_W * math.sqrt(g / h)
  local a = (g * math.sin(phi) + h * (w * w * (phi - phiT) + 2 * BIKE_Z * w * rate)) / math.max(0.3, math.cos(phi))
  local vv = math.max(0.5, math.abs(v or 0))
  local d = math.deg(math.atan(math.max(0.3, L or 1.4) * a / (vv * vv)))
  if (v or 0) < 0 then d = -d end
  local lock = lockDeg or 25
  return math.max(-lock, math.min(lock, d)), a
end

-- TORQUE BALANCE: the roll torque (kN·m, + leans it LEFT) that settles the
-- lean on phiT, with what gravity and the turn are doing cancelled — capped at
-- `tmax`. m the craft's mass, h its centre of mass over the tyres, alat the
-- sideways (left) acceleration it has now, I its roll inertia about the
-- contact line (m h² if not given).
BIKE_TW, BIKE_TZ = 3.0, 1.0
function bikeTorque(phi, rate, phiT, m, h, g, alat, tmax, I)
  g = math.max(0.1, g or 9.8)
  h = math.max(0.2, h or 0.7)
  m = math.max(0.01, m or 0.3)
  I = I or m * h * h
  local w = BIKE_TW * math.sqrt(g / h)
  local want = I * (w * w * (phiT - phi) - 2 * BIKE_TZ * w * rate)
  local fall = m * h * (g * math.sin(phi) - (alat or 0) * math.cos(phi))
  local t = want - fall
  tmax = tmax or 0
  return math.max(-tmax, math.min(tmax, t))
end

-- Who holds it up, and how hard (kN·m): a Balance Gyro's torque at any
-- speed; a seated rider's body (shifting their weight, at any speed) and
-- feet (below a fast walk). (The rider's share is a game's, not a physicist's:
-- the engine's ball tyres have no trail to self-steer a real bike upright,
-- and steering alone held it only on the probe's straights — see
-- docs/auto-engineering.md.)
RIDER_TORQUE = 1.0
FEET_TORQUE = 1.2
FEET_V = 2.5
function balanceAuthority(gyro, rider, v)
  local t = gyro or 0
  if rider then
    t = t + RIDER_TORQUE
    local s = math.abs(v or 0)
    if s < FEET_V then t = t + FEET_TORQUE * (1 - math.max(0, s - 0.6) / (FEET_V - 0.6)) end
  end
  return t
end

-- How much of the balancing the steering does: none at a walk (the bars are
-- the rider's to manoeuvre with), all of it from STEER_V1 up.
STEER_V0, STEER_V1 = 1.2, 3.5
function steerShare(v)
  local u = (math.abs(v or 0) - STEER_V0) / (STEER_V1 - STEER_V0)
  u = math.max(0, math.min(1, u))
  return u * u * (3 - 2 * u)
end

-- ── 4. DRAWING THE MOVING HALVES ────────────────────────────────────────────
-- `s` = how far the wheel has come up its axis from where it hangs unloaded
-- (m), steer (deg). A fork's lower legs slide s up the axis and its whole
-- steering half turns; a swing arm turns about its pivot so its end follows
-- the axle (asin(s/len)); a strut's knuckle slides and steers, and its
-- wishbone turns to meet it.
function poseOf(kind, s, steerDeg, len)
  s = s or 0
  if kind == "arm" or kind == "strut" then
    local L = math.max(0.05, len or 0.5)
    local ang = math.asin(math.max(-0.95, math.min(0.95, s / L)))
    return { slide = s, steer = math.rad(steerDeg or 0), arm = ang }
  end
  return { slide = s, steer = math.rad(steerDeg or 0), arm = 0 }
end

-- ── 5. GAS ENGINES (playtest 2026-11-03c: "a motor engine vs an electric
-- one … different-cc gas engines … a chain item which snaps to an engine on
-- one end and a wheel on the other") ─────────────────────────────────────────
-- A single-cylinder petrol engine with a clutch and a gearbox, driving a
-- wheel through a roller chain (parts_auto: the Gas Engines, the Drive
-- Chain, the Gas Tanks). Its module (`gasengine`, on the engine part) is the
-- engine's own figures, as a spec sheet gives them:
--
--   cc, stroke   displacement and 2 / 4 stroke (sound and exhaust only)
--   nm, rpk      peak torque (N·m, at the crank) and the rpm it comes at
--   idle, eng    idle rpm, and the rpm the clutch is fully in by: below it
--                the clutch slips, the engine held at `eng` and its torque
--                passed on (so it pulls away from a standstill and never
--                stalls)
--   red          the redline (rpm): the top of every gear
--   prim         primary reduction (crank to gearbox)
--   g1…g6        the gearbox's ratios (0 = no such gear); it shifts itself,
--                always to the gear that pulls hardest at the road speed
--   front        the gearbox sprocket's teeth (the chain's rear sprocket,
--                REAR_T teeth unless the chain is set otherwise, gives the
--                final drive: rear / front)
--   bsfc         fuel per energy delivered (L/kWh: a 4-stroke ~0.40, a
--                2-stroke ~0.70), lph its idle burn (L/h)
--
-- The torque curve is a parabola through the peak, down to LOW_K of it at
-- idle and HIGH_K at the redline: the shape of a small single's dyno sheet.
-- Torque at the wheel is crank torque × overall ratio × ETA; the wheel's
-- top speed is the redline in top gear.
GAS_ETA = 0.90        -- primary, gearbox and chain together
GAS_RHO = 0.74        -- kg of petrol a litre
GAS_LOW_K = 0.45      -- the torque curve's fall to idle (of the peak)…
GAS_HIGH_K = 0.38     -- …and to the redline
REAR_T = 48           -- a chain's rear sprocket unless it is set
TEETH_MIN, TEETH_MAX = 36, 62
GAS_BRAKE = 0.14      -- engine braking: of the peak torque at the crank, at the redline
local RPM = 60 / (2 * math.pi)

function gasGears(m)
  local out = {}
  for i = 1, 6 do
    local g = tonumber(m and m["g" .. i]) or 0
    if g > 0 then out[#out + 1] = g end
  end
  if #out == 0 then out[1] = 1 end
  return out
end

-- Crank torque (N·m) at rpm (0 past the redline: the limiter cuts it).
function gasTorque(m, rpm)
  local pk, rp = m.nm or 10, m.rpk or 7000
  local lo, hi = m.idle or 1500, m.red or 10000
  if rpm > hi + 1 then return 0 end
  local x
  if rpm < rp then x = (rpm - rp) / math.max(1, rp - lo); return pk * math.max(0.2, 1 - GAS_LOW_K * x * x) end
  x = (rpm - rp) / math.max(1, hi - rp)
  return pk * math.max(0.2, 1 - GAS_HIGH_K * x * x)
end

-- The overall ratio (crank turns per wheel turn) in gear i.
function gasOverall(m, i, teeth)
  local G = gasGears(m)
  local g = G[math.max(1, math.min(#G, i or 1))]
  return (m.prim or 3) * g * ((teeth or REAR_T) / (m.front or 14))
end

-- Peak power (kW) and the rpm it comes at, off the curve.
function gasPeak(m)
  local best, at = 0, m.rpk or 7000
  for rpm = m.idle or 1500, m.red or 10000, 50 do
    local p = gasTorque(m, rpm) * rpm / RPM / 1000
    if p > best then best, at = p, rpm end
  end
  return best, at
end

-- THE ENGINE AT THIS ROAD SPEED: v = the wheel's rim speed (m/s, its sign
-- ignored), r = its radius (m), teeth = the chain's rear sprocket. →
--   torque  kN·m the wheel can be driven with (the best gear's, the clutch
--           slipping below `eng`)
--   top     m/s: the redline in top gear
--   rpm     the engine's (the clutch's `eng` while it slips)
--   gear    which one it is in
--   kw      the power that torque is at this rpm (what full throttle burns)
--   ratio   the overall ratio in that gear
-- thr (0…1, optional): the throttle. A rider pulling away hard holds the
-- engine on the clutch where it pulls (the dirt-bike launch): the slipping
-- clutch holds it at `eng` on a whiff of throttle and up toward the torque
-- peak `rpk` wide open, and passes that torque on. (Held at `eng` always,
-- a 125 left the line on 79% of its torque.)
-- keep (optional): the gear it is in now. It stays there while that gear
-- still pulls within GAS_SHIFT_K of the best (and is under the redline), so a
-- road speed sitting on a shift point does not hunt between two gears.
GAS_SHIFT_K = 0.96
function gasWheel(m, v, r, teeth, thr, keep)
  r = math.max(0.05, r or 0.33)
  local w = math.abs(v or 0) / r                 -- wheel rad/s
  local G = gasGears(m)
  local eng, red = m.eng or 3000, m.red or 10000
  local slip = eng
  if thr and thr > 0 then
    slip = eng + (math.max(eng, math.min(red, m.rpk or eng)) - eng) * math.min(1, thr)
  end
  local best, bg, brpm, bratio = -1, 1, slip, gasOverall(m, 1, teeth)
  for i = 1, #G do
    local ratio = gasOverall(m, i, teeth)
    local rpm = w * ratio * RPM
    if rpm <= red or i == #G then
      local run = math.max(rpm, slip)
      local t = gasTorque(m, math.min(run, red)) * ratio
      if rpm > red then t = 0 end
      if t > best then best, bg, brpm, bratio = t, i, run, ratio end
    end
  end
  if keep and keep ~= bg and keep >= 1 and keep <= #G then
    local ratio = gasOverall(m, keep, teeth)
    local rpm = w * ratio * RPM
    if rpm <= red then
      local run = math.max(rpm, slip)
      local t = gasTorque(m, math.min(run, red)) * ratio
      if t >= best * GAS_SHIFT_K then best, bg, brpm, bratio = t, keep, run, ratio end
    end
  end
  local top = red / gasOverall(m, #G, teeth) / RPM * r
  local tq = math.max(0, best) * GAS_ETA / 1000
  local kw = gasTorque(m, math.min(brpm, red)) * math.min(brpm, red) / RPM / 1000
  return { torque = tq, top = top, rpm = brpm, gear = bg, kw = kw, ratio = bratio }
end

-- Engine braking at the wheel (kN·m) while the throttle is shut: the pumping
-- and friction losses, rising with the rpm, through the gear it is in.
function gasBrake(m, rpm, ratio)
  local k = math.max(0, math.min(1, ((rpm or 0) - (m.idle or 1500)) / math.max(1, (m.red or 10000) - (m.idle or 1500))))
  return GAS_BRAKE * (m.nm or 10) * k * (ratio or 1) * GAS_ETA / 1000
end

-- Litres burnt over dt at `effort` (0…1: the throttle times the share of the
-- available torque actually asked for) with kw available: the idle's, plus
-- the work done at its specific consumption.
function gasBurn(m, effort, kw, dt)
  effort = math.max(0, math.min(1, effort or 0))
  local lps = ((m.lph or 0.3) + effort * (kw or 0) * (m.bsfc or 0.4)) / 3600
  return lps * (dt or 0)
end

-- Hours a tank of `L` litres lasts: at full power, and at `share` of it.
function gasHours(m, L, share)
  local kw = gasPeak(m)
  local lph = (m.lph or 0.3) + (share or 1) * kw * (m.bsfc or 0.4)
  return L / math.max(1e-6, lph)
end

-- THE TANKS: a craft's gas tanks drain and fill together, each in proportion
-- (to what it holds when drawn from, to the room it has when filled), so no
-- tank runs dry while another is full. `tanks` = { { cap, left }, … }
-- (changed in place). → litres drawn / put in.
function gasDrawFrom(tanks, L)
  local have = 0
  for _, t in ipairs(tanks) do have = have + math.max(0, t.left or 0) end
  if have <= 0 or (L or 0) <= 0 then return 0 end
  local take = math.min(have, L)
  for _, t in ipairs(tanks) do
    local l = math.max(0, t.left or 0)
    t.left = math.max(0, l - take * l / have)
  end
  return take
end
function gasFillInto(tanks, L)
  local room = 0
  for _, t in ipairs(tanks) do room = room + math.max(0, (t.cap or 0) - (t.left or 0)) end
  if room <= 1e-9 or (L or 0) <= 0 then return 0 end
  local put = math.min(room, L)
  for _, t in ipairs(tanks) do
    local r = math.max(0, (t.cap or 0) - (t.left or 0))
    t.left = math.min(t.cap or 0, (t.left or 0) + put * r / room)
  end
  return put
end
