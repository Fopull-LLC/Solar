-- SMOKE HARNESS for the orbit map's per-craft trajectories (orbit_map.lua TRAJ).
--
-- Every craft on the map shows the conic it is on about its dominant body:
-- the whole ellipse in orbit, an arc to the ground when suborbital, an arc to
-- the edge of the sphere of influence when escaping, nothing when landed.
-- This holds the maths against a brute-force integration of the same
-- two-body motion, so "where it hits the ground" is where it actually would.
--
--   luajit solar/tests/smoke_trajectory.lua

local failures, passed = {}, 0
local function ok(c, msg)
  if c then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end

local env = setmetatable({}, { __index = _G })
env.time = 0
local chunk = assert(loadfile("solar/scripts/orbit_map.lua"))
setfenv(chunk, env)
chunk()
local T = env.TRAJ
ok(type(T) == "table" and type(T.track) == "function", "orbit_map publishes TRAJ.track")

-- A Kerbin-sized world (9.8 m/s² at the surface).
local MU, R, SOI = 3.5316e12, 600000.0, 8.4e7

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- Two-body motion, RK4, until it meets the ground (or `tmax`). Returns where.
local function integrate(rx, ry, rz, vx, vy, vz, tmax, dt)
  local function acc(x, y, z)
    local r = len(x, y, z)
    local k = -MU / (r * r * r)
    return x * k, y * k, z * k
  end
  local t = 0
  while t < tmax do
    local ax1, ay1, az1 = acc(rx, ry, rz)
    local x2, y2, z2 = rx + vx * dt / 2, ry + vy * dt / 2, rz + vz * dt / 2
    local vx2, vy2, vz2 = vx + ax1 * dt / 2, vy + ay1 * dt / 2, vz + az1 * dt / 2
    local ax2, ay2, az2 = acc(x2, y2, z2)
    local x3, y3, z3 = rx + vx2 * dt / 2, ry + vy2 * dt / 2, rz + vz2 * dt / 2
    local vx3, vy3, vz3 = vx + ax2 * dt / 2, vy + ay2 * dt / 2, vz + az2 * dt / 2
    local ax3, ay3, az3 = acc(x3, y3, z3)
    local x4, y4, z4 = rx + vx3 * dt, ry + vy3 * dt, rz + vz3 * dt
    local vx4, vy4, vz4 = vx + ax3 * dt, vy + ay3 * dt, vz + az3 * dt
    local ax4, ay4, az4 = acc(x4, y4, z4)
    rx = rx + dt / 6 * (vx + 2 * vx2 + 2 * vx3 + vx4)
    ry = ry + dt / 6 * (vy + 2 * vy2 + 2 * vy3 + vy4)
    rz = rz + dt / 6 * (vz + 2 * vz2 + 2 * vz3 + vz4)
    vx = vx + dt / 6 * (ax1 + 2 * ax2 + 2 * ax3 + ax4)
    vy = vy + dt / 6 * (ay1 + 2 * ay2 + 2 * ay3 + ay4)
    vz = vz + dt / 6 * (az1 + 2 * az2 + 2 * az3 + az4)
    t = t + dt
    if len(rx, ry, rz) <= R then return rx, ry, rz, t end
  end
  return nil
end

-- ── 1. landed and below-ground craft draw nothing ───────────────────────────
ok(T.track(R + 2, 0, 0, 0, 0, 0, MU, R, SOI, true).kind == "landed", "a grounded craft has no trajectory")
ok(T.track(R - 50, 0, 0, 0, 300, 0, MU, R, SOI, false).kind == "landed",
  "a craft under the surface (a cave, a glitch) draws no arc")
ok(T.track(R + 5, 0, 0, 0, 1.0, 0, MU, R, SOI, false).kind == "landed",
  "a craft sitting just above the ground at walking speed: its arc is all underground, nothing drawn")

-- ── 2. a circular orbit: the whole ellipse, Pe and Ap ───────────────────────
local r0 = R + 100000
local vc = math.sqrt(MU / r0)
local t = T.track(r0, 0, 0, 0, 0, vc, MU, R, SOI, false)
ok(t.kind == "orbit" and t.closed, "circular speed at 100 km is a closed orbit")
ok(t.e < 1e-6, "...with eccentricity ~0 (got " .. tostring(t.e) .. ")")
ok(near(t.peR, r0, 1) and near(t.apR, r0, 1), "...Pe and Ap both at the orbit's radius")
ok(t.pe == 0.0 and t.ap == math.pi, "...both marked")

-- ── 3. an ellipse: vis-viva apoapsis ────────────────────────────────────────
local v1 = vc * 1.1
t = T.track(r0, 0, 0, 0, v1, 0, MU, R, SOI, false)
local a = 1 / (2 / r0 - v1 * v1 / MU)
ok(t.kind == "orbit", "10% over circular speed is still an orbit")
ok(near(t.peR, r0, 1), "...periapsis where the burn was (got " .. math.floor(t.peR) .. ")")
ok(near(t.apR, 2 * a - r0, 1), "...apoapsis at 2a − r (vis-viva)")
local px, py, pz = T.point(t, t.nu0)
ok(near(px, r0, 1) and near(len(px, py, pz), r0, 1), "TRAJ.point(ν0) is the craft's own position")

-- ── 4. suborbital, going up: arc over the top and down to an impact ────────
local h0 = 2000
local rx, ry, rz = R + h0, 0, 0
local vx, vy, vz = 600, 0, 900          -- up and along
t = T.track(rx, ry, rz, vx, vy, vz, MU, R, SOI, false)
ok(t.kind == "suborbital", "a hop up at 600 m/s is suborbital (got " .. tostring(t.kind) .. ")")
ok(t.ap ~= nil and t.pe == nil, "...its apoapsis is ahead and marked, its periapsis is underground and not")
ok(t.a1 > t.a0 and t.a1 > math.pi, "...the arc runs forward, over the top")
local sx, sy, sz = T.point(t, t.a0)
ok(near(sx, rx, 1) and near(sy, ry, 1) and near(sz, rz, 1), "...and starts at the craft")
local ix, iy, iz = T.point(t, t.impact)
ok(near(len(ix, iy, iz), R, 1), "...and ends on the ground (|impact| = R)")
local gx, gy, gz = integrate(rx, ry, rz, vx, vy, vz, 4000, 0.05)
ok(gx ~= nil, "the brute-force flight lands too")
if gx then
  local miss = len(ix - gx, iy - gy, iz - gz)
  ok(miss < 50, string.format("the impact mark is where it really lands (off by %.1f m)", miss))
end
local apx, apy, apz = T.point(t, t.ap)
ok(near(len(apx, apy, apz), t.apR, 1), "the Ap mark sits at the apoapsis radius")

-- ── 5. suborbital, coming down: no apoapsis left, impact ahead ─────────────
vx, vy, vz = -300, 0, 400
t = T.track(rx, ry, rz, vx, vy, vz, MU, R, SOI, false)
ok(t.kind == "suborbital" and t.ap == nil, "falling at 300 m/s: suborbital, apoapsis behind it")
ix, iy, iz = T.point(t, t.impact)
gx, gy, gz = integrate(rx, ry, rz, vx, vy, vz, 4000, 0.02)
if gx then
  local miss = len(ix - gx, iy - gy, iz - gz)
  ok(miss < 20, string.format("...and it lands where the mark says (off by %.1f m)", miss))
else
  ok(false, "the brute-force fall never landed")
end

-- ── 6. the arc runs the way the craft moves (both senses of rotation) ──────
for _, sgn in ipairs({ 1, -1 }) do
  local qx, qy, qz, wx, wy, wz = R + 5000, 0, 0, 200, 0, 700 * sgn
  local tt = T.track(qx, qy, qz, wx, wy, wz, MU, R, SOI, false)
  local ax, ay, az = T.point(tt, tt.a0 + 0.01)
  local dot = (ax - qx) * wx + (ay - qy) * wy + (az - qz) * wz
  ok(dot > 0, "the arc leaves the craft along its velocity (sense " .. sgn .. ")")
end

-- ── 7. escape: open arc to the edge of the sphere of influence ─────────────
local vesc = math.sqrt(2 * MU / r0)
t = T.track(r0, 0, 0, 0, vesc * 1.2, 0, MU, R, SOI, false)
ok(t.kind == "escape" and t.e > 1, "20% over escape speed is a hyperbolic escape")
ok(t.pe == 0.0, "...burning at periapsis, which is marked")
local ex, ey, ez = T.point(t, t.a1)
ok(near(len(ex, ey, ez), SOI, SOI * 1e-6), "...and the arc stops at the SOI")
-- An ellipse whose apoapsis is outside the SOI also leaves it.
t = T.track(r0, 0, 0, 0, vesc * 0.999, 0, MU, R, SOI, false)
ok(t.kind == "escape" and t.e < 1, "a bound ellipse reaching past the SOI is drawn as leaving it")
ex, ey, ez = T.point(t, t.a1)
ok(near(len(ex, ey, ez), SOI, SOI * 1e-6), "...out to the SOI, not round a far apoapsis")
-- Straight up: no angular momentum, no conic.
ok(T.track(R + 100, 0, 0, 50, 0, 0, MU, R, SOI, false).kind == "falling",
  "straight up or down has no conic to draw")

-- ── 8. the arc as world points ─────────────────────────────────────────────
t = T.track(R + h0, 0, 0, 600, 0, 900, MU, R, SOI, false)
local pts = T.arc(t, 1000, 2000, 3000, 40)
ok(#pts == 41 * 3, "TRAJ.arc gives segs + 1 points")
ok(near(pts[1], 1000 + R + h0, 1) and near(pts[2], 2000, 1), "...offset by the body's centre")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL  " .. f) end
  print(string.format("TRAJECTORY SMOKE FAILED — %d of %d checks", #failures, #failures + passed))
  os.exit(1)
end
print(string.format("TRAJECTORY SMOKE OK — %d checks passed", passed))
