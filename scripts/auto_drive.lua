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
