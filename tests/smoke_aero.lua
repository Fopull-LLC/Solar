-- SMOKE HARNESS: aero.lua — per-part aerodynamics, and the aircraft parts.
--
-- What is held here:
--   * the spec strings parse and pack back
--   * the air: density from the world record, thinning to nothing at the top
--     of the shell; the world's speed of sound; oxygen by planet type
--   * the transonic drag rise and the lift slope (Helmbold, compressibility)
--   * a lifting surface: lift across the flow, linear to the stall near 15°,
--     a stall that keeps some lift and costs drag, odd in α, and a deflected
--     control surface that turns the craft the way the stick asks, on every
--     axis, wherever it is mounted (mirrored and ringed copies too)
--   * body drag from frontal area and shape; a part behind another hides its
--     end; a faired part has none
--   * a finned rocket weathervanes into the wind (the fins' torque restores
--     it), a bare one does not
--   * centre of lift behind the centre of mass on the test plane; the centre
--     of thrust on its axis
--   * the turbojet: no thrust without an intake, oxygen or air; it spools;
--     its thrust curve over Mach
--   * THE TEST PLANE, flown in a pitch-plane simulation on the same maths:
--     it leaves the 250 m runway, climbs, cruises, stalls with the stick
--     held back and recovers when it is let go
--
--   luajit solar/tests/smoke_aero.lua

local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "solar"
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local A = load(here .. "/scripts/aero.lua")
local PA = load(here .. "/scripts/parts_aero.lua")
local D = math.rad

-- ── spec strings ────────────────────────────────────────────────────────────
do
  local t = A.parse("wing span=3 root=1.6 ctl=pr")
  ok(t.wing == true and t.span == 3 and t.root == 1.6 and t.ctl == "pr", "parse reads flags, numbers and words")
  ok(A.parse("wing span=3 root=1.6 ctl=pr") == t, "parse memoises by string")
  local s = A.pack(t)
  local u = A.parse(s)
  ok(u.span == 3 and u.root == 1.6 and u.ctl == "pr" and u.wing == true, "pack round-trips: " .. s)
  ok(A.parse(nil) == nil and A.parse("") == nil, "no spec is nil")
  for id, d in pairs(PA.PARTS) do
    ok(type(d.af) == "string" and A.parse(d.af) ~= nil, "every aircraft part has an af spec: " .. id)
    ok(d.prefab and d.label and d.h and d.rx and d.rz and d.mass and d.cost and d.kind, "registry keys present: " .. id)
  end
  local REG, CAT = { pod = {} }, { { "COMMAND", { "pod" } } }
  local n = PA.register(REG, CAT)
  ok(n == #PA.SECTION[2] and REG.cockpit and REG.cockpit ~= PA.PARTS.cockpit, "register copies every part into the registry")
  ok(#CAT == 2 and CAT[2][1] == "AIRCRAFT", "register adds the AIRCRAFT section")
  ok(PA.register(REG, CAT) == 0 and #CAT == 2, "register is idempotent")
  for _, id in ipairs(PA.SECTION[2]) do ok(PA.PARTS[id] ~= nil, "catalogue id is a part: " .. id) end
end

-- ── the air ─────────────────────────────────────────────────────────────────
local HOME = { atmo = 0.75, atmoHeight = 300, radius = 850, geo = { type = "verdant", home = true } }
do
  local r0, a0, o0 = A.airAt(HOME, 0, 9.8, 850)
  ok(near(r0, A.RHO0, 1e-9), "sea-level density is RHO0 on a reference world")
  ok(near(a0, 0.9 * math.sqrt(9.8 * 850), 1e-6) or near(a0, A.SOUND_K * math.sqrt(9.8 * 850), 1e-6), "speed of sound is the world's")
  ok(o0 == 1, "home air has oxygen")
  local prev = r0
  local mono = true
  for h = 10, 300, 10 do
    local r = A.airAt(HOME, h, 9.8, 850)
    if r > prev + 1e-12 then mono = false end
    prev = r
  end
  ok(mono, "density falls with height")
  ok(A.airAt(HOME, 300, 9.8, 850) == 0 and A.airAt(HOME, 400, 9.8, 850) == 0, "no air at or past the top of the shell")
  ok(near(A.airAt(HOME, 150, 9.8, 850), A.RHO0 * 0.25, 1e-9), "the engine's curve: (1 − h/H)²")
  ok(A.airAt({ atmo = 0 }, 0, 5, 300) == 0, "an airless world has no air")
  ok(A.airAt({ atmo = 0.5, radius = 400 }, 0, 5, 400) > 0, "a world with no atmoHeight falls back to 0.35·R")
  ok(A.oxygen({ atmo = 0.8, geo = { type = "titan" } }) == 0, "a hydrocarbon world has no oxygen")
  ok(A.oxygen({ atmo = 0.8, geo = { type = "greenhouse" } }) == 0, "a greenhouse world has no oxygen")
  ok(A.oxygen({ atmo = 0.5, geo = { type = "steppe" } }) == 1, "a steppe world breathes")
  local rh = A.airAt({ atmo = 0.75, atmoHeight = 300 }, -500, 9.8, 850)
  ok(rh < A.RHO0 * 1.6, "below the datum the air is thicker, not unbounded")
end

-- ── Mach and lift slope ─────────────────────────────────────────────────────
do
  ok(A.machDrag(0.5) == 1 and near(A.machDrag(1.05), 3, 1e-9) and near(A.machDrag(3), 2, 1e-9), "transonic drag rise ×3 at Mach 1.05, ×2 supersonic")
  local cont = true
  for k = 1, 400 do
    local m = k / 100
    if math.abs(A.machDrag(m) - A.machDrag(m - 0.01)) > 0.12 then cont = false end
  end
  ok(cont, "the drag rise is continuous")
  local big = A.liftSlope(1000, 0, 0)
  ok(near(big, 2 * math.pi, 0.05), "an infinite wing has the thin-airfoil slope 2π (" .. big .. ")")
  local a6 = A.liftSlope(6, 0, 0)
  ok(a6 > 4.2 and a6 < 4.9, "AR 6 slope ≈ 4.5/rad (" .. a6 .. ")")
  ok(A.liftSlope(6, D(35), 0) < a6, "sweep lowers the slope")
  ok(A.liftSlope(6, 0, 0.7) > a6, "compressibility raises it subsonic")
  ok(A.liftSlope(6, 0, 2.0) < A.liftSlope(6, 0, 0.85), "supersonic it falls")
end

-- ── a lifting surface ───────────────────────────────────────────────────────
local function surf(X, Y, Z, extra)
  local s = { X = X, Y = Y, Z = Z, x = 0, y = 0, z = 0, S = 2, AR = 6, sweep = 0, cd0 = 0.008, e = 0.8, stall = A.STALL, a0 = 0 }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
do
  local s = surf({ x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = -1 }, { x = 0, y = 1, z = 0 })
  -- flying along −Z (the surface's +Y), the air from slightly below
  local function at(deg)
    local a = D(deg)
    return A.surfaceForce(s, 0, -40 * math.sin(a), -40 * math.cos(a), 1.225, 0, 0)
  end
  local fx, fy, fz = at(5)
  ok(fy > 0, "air from below lifts the surface up")
  ok(math.abs(fx) < 1e-9, "no force along the span")
  local q = 0.5 * 1.225 * 1600 * 2 / 1000
  local CL5 = A.coeffs(D(5), s, 0)
  ok(near(CL5, A.liftSlope(6, 0, 0) * math.sin(D(5)), 0.02), "attached CL = slope · sin α")
  local best, at_best = 0, 0
  for k = 0, 60 do
    local cl = A.coeffs(D(k * 0.5), s, 0)
    if cl > best then best, at_best = cl, k * 0.5 end
  end
  ok(at_best >= 12 and at_best <= 16, "the stall comes at ~15° (peak at " .. at_best .. "°)")
  local cl20, cd20 = A.coeffs(D(20), s, 0)
  local cl10, cd10 = A.coeffs(D(10), s, 0)
  ok(cl20 < best * 0.85, "past the stall the lift falls away (" .. cl20 .. " of " .. best .. ")")
  ok(cl20 > 0.4, "a stalled wing still lifts (it is recoverable)")
  ok(cd20 > 3 * cd10, "and the drag climbs (" .. cd10 .. " → " .. cd20 .. ")")
  local clm, cdm = A.coeffs(D(-7), s, 0)
  local clp, cdp = A.coeffs(D(7), s, 0)
  ok(near(clm, -clp, 1e-9) and near(cdm, cdp, 1e-9), "a symmetric section is odd in α")
  local _, cd0 = A.coeffs(0, s, 0)
  local _, cdM = A.coeffs(0, s, 1.05)
  ok(near(cdM, 3 * cd0, 1e-9), "profile drag rises through Mach 1")
  local V5 = 40
  local ux, uy, uz = 0, math.sin(D(5)), math.cos(D(5))
  ok(fx * ux + fy * uy + fz * uz > 0, "drag acts downstream")
  -- induced drag ∝ CL²
  local _, cda = A.coeffs(D(4), s, 0)
  local _, cdb = A.coeffs(D(8), s, 0)
  ok(cdb - 0.008 > 3 * (cda - 0.008), "induced drag grows as CL²")
  -- a deflected surface: positive deflection = more lift
  local _, fy1 = A.surfaceForce(s, 0, 0, -40, 1.225, 0, D(10))
  ok(fy1 > 0, "positive deflection lifts")
  ok(near(A.flapTau(0.35), 0.71, 0.02) and A.flapTau(nil) == 1 and A.flapTau(1) == 1, "a 35 % flap turns the section by ~0.71 of its travel; none is all-moving")
  -- camber: lift at zero angle
  local c = surf({ x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = -1 }, { x = 0, y = 1, z = 0 }, { a0 = 0.25 / 4.5 })
  ok(A.coeffs(0, c, 0) > 0.2, "a cambered panel lifts at zero angle")
end

-- ── geometry and building ───────────────────────────────────────────────────
local function eulerOf(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
  if math.abs(Z.y) > 1 - 1e-10 then return math.atan2(-X.z, X.x), pitch, 0 end
  return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function unit(v) local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) return { x = v.x / l, y = v.y / l, z = v.z / l } end
-- a part record as the builder saves it: the registry entry, placed (X, Y)
local uid = 0
local function place(id, x, y, z, X, Y, def)
  def = def or PA.PARTS[id]
  uid = uid + 1
  local Z = cross(X, Y)
  local yaw, pitch, roll = eulerOf(X, Y, Z)
  local r = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll }
  for k, v in pairs(def) do if r[k] == nil and type(v) ~= "table" then r[k] = v end end
  return r
end
do
  for _, B in ipairs({ { { x = 0, y = 0, z = 1 }, { x = 1, y = 0, z = 0 } }, { { x = 0, y = -1, z = 0 }, { x = 1, y = 0, z = 0 } },
                       { { x = 0, y = 1, z = 0 }, { x = 1, y = 0, z = 0 } }, { { x = 0.6, y = 0.8, z = 0 }, { x = 0, y = 0, z = 1 } } }) do
    local Z = cross(B[1], B[2])
    local X2, Y2, Z2 = A.axes(eulerOf(B[1], B[2], Z))
    ok(near(X2.x, B[1].x, 1e-9) and near(X2.y, B[1].y, 1e-9) and near(X2.z, B[1].z, 1e-9)
       and near(Y2.x, B[2].x, 1e-9) and near(Y2.y, B[2].y, 1e-9) and near(Y2.z, B[2].z, 1e-9)
       and near(Z2.z, Z.z, 1e-9), "axes() inverts the builder's eulerOf")
  end
  local pf = A.planform({ span = 3.5, root = 1.6, tip = 1.6, le = 0.8 })
  ok(near(pf.S, 5.6, 1e-9) and near(pf.AR, 2 * 3.5 * 3.5 / 5.6, 1e-9), "a rectangular panel: area and root-reflected AR")
  ok(near(pf.cpx, 0, 1e-9) and near(pf.cpy, 0.4, 1e-9), "its centre of pressure is mid-span at the quarter chord")
  local sw = A.planform({ span = 3.0, root = 1.8, tip = 0.8, lsw = 1.2, le = 1.0 })
  ok(sw.cpx < 0 and sw.cpy < 0.5 and sw.sweep > D(15), "a swept panel's CP moves in and back, and it is swept")
end

-- ── body drag and shielding ─────────────────────────────────────────────────
local UPX, UPY, UPZ = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
local function tank(id, y, extra)
  local d = { uid = 0, id = id or "tankS", kind = "tank", x = 0, y = y or 0, z = 0, yaw = 0, pitch = 0, roll = 0,
              h = 1.0, rx = 0.5, rz = 0.5, mass = 0.2 }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end
do
  local one = A.build({ tank() })
  local fx, fy, fz = A.step(one, { vx = 0, vy = 50, vz = 0, rho = 1.225, a = 300 })
  local cda = -fy / (0.5 * 1.225 * 2500 / 1000)
  ok(near(cda, 0.8 * math.pi * 0.25, 0.01), "a tank flying end-on: Cd 0.8 on its round end (CdA " .. cda .. ")")
  local nose = A.build({ tank("nose", 0, { kind = "structural", aero = 1, top = false }) })
  local _, fyn = A.step(nose, { vx = 0, vy = 50, vz = 0, rho = 1.225, a = 300 })
  ok(-fyn < -fy * 0.3, "a nose cone flying point-first has a fraction of that")
  local _, fyb = A.step(nose, { vx = 0, vy = -50, vz = 0, rho = 1.225, a = 300 })
  ok(fyb > -fyn * 3, "...and a blunt base flying backwards")
  local two = A.build({ tank(nil, 0, { uid = 1 }), tank(nil, -1.0, { uid = 2 }) })
  local _, fy2 = A.step(two, { vx = 0, vy = 50, vz = 0, rho = 1.225, a = 300 })
  ok(-fy2 < -fy * 1.2, "a tank behind another hides its end (2 tanks: " .. (-fy2) .. " kN vs one " .. (-fy) .. ")")
  ok(two.bodies[2].sh > 0.85 and two.bodies[1].sh == 0, "the front tank is unshielded, the one behind it shielded")
  local _, fys = A.step(two, { vx = 50, vy = 0, vz = 0, rho = 1.225, a = 300 })
  local fxs = A.step(two, { vx = 50, vy = 0, vz = 0, rho = 1.225, a = 300 })
  ok(-fxs > 2 * 0.6 * 1.0 * 0.5 * 1.225 * 2500 / 1000 * 0.95, "crossflow hits both side by side")
  local fair = A.build({ tank(nil, 0, { uid = 1 }) }, { faired = function() return true end })
  ok(#fair.bodies == 0, "a faired part meets no air")
  local hot = A.build({ tank() })
  local _, fyh = A.step(hot, { vx = 0, vy = 50, vz = 0, rho = 1.225, a = 50 / 1.05 })
  ok(near(fyh, 3 * fy, 1e-6), "body drag rises ×3 through Mach 1")
  local still = A.build({ tank() })
  local f0x, f0y, f0z = A.step(still, { vx = 0, vy = 0, vz = 0, rho = 1.225, a = 300 })
  ok(f0x == 0 and f0y == 0 and f0z == 0, "no wind, no force")
  local vac = A.step(A.build({ tank() }), { vx = 0, vy = 90, vz = 0, rho = 0, a = 300 })
  ok(vac == 0, "no air, no force")
end

-- ── a finned rocket weathervanes ────────────────────────────────────────────
local STOCK = {
  pod = { id = "pod", kind = "crewed", h = 0.8, rx = 0.5, rz = 0.5, mass = 1.3 },
  tankS = { id = "tankS", kind = "tank", h = 1.0, rx = 0.5, rz = 0.5, mass = 0.2, fuel = 80 },
  engineS = { id = "engineS", kind = "engine", h = 1.3, rx = 0.9, rz = 0.9, mass = 0.45, thrust = 35 },
  chute = { id = "chute", kind = "canvas", h = 0.34, rx = 0.22, rz = 0.22, mass = 0.08 },
  fins = { id = "fins", kind = "structural", h = 0.95, rx = 0.35, rz = 0.03, mass = 0.04, aero = 1 },
}
local function rocket(with_fins)
  uid = 0
  local P = {
    place("engineS", 0, 0.65, 0, UPX, UPY, STOCK.engineS), place("tankS", 0, 1.8, 0, UPX, UPY, STOCK.tankS),
    place("pod", 0, 2.7, 0, UPX, UPY, STOCK.pod), place("chute", 0, 3.27, 0, UPX, UPY, STOCK.chute),
  }
  if with_fins then
    for k = 0, 3 do
      local a = k * math.pi / 2
      local X = { x = math.cos(a), y = 0, z = math.sin(a) }
      P[#P + 1] = place("fins", X.x * 0.85, 0.7, X.z * 0.85, X, UPY, STOCK.fins)
    end
  end
  return P
end
do
  for _, fins in ipairs({ true, false }) do
    local P = rocket(fins)
    local cx, cy, cz = A.centerOfMass(P)
    local M = A.build(P)
    -- climbing at 60 m/s, the nose 8° off the flight path toward +X
    local a = D(8)
    local vx, vy = -60 * math.sin(a), 60 * math.cos(a)
    local fx, fy, fz, tx, ty, tz = A.step(M, { vx = vx, vy = vy, vz = 0, cx = cx, cy = cy, cz = cz, rho = 1.225, a = 85 })
    -- the restoring sense turns the nose (+Y) toward the velocity (−X side): about −Z... ω × ŷ ∝ −x̂ ⇒ ω along +z
    if fins then
      ok(tz > 0.05, string.format("fins turn a rocket's nose back into the wind (Tz %.3f kN·m)", tz))
      FIN_TZ = tz
      local lx, ly = A.centerOfLift(P, { nose = UPY, top = { x = -1, y = 0, z = 0 } })
      ok(lx and ly < cy, string.format("the finned rocket's centre of lift (y %.2f) is under its CoM (y %.2f)", ly or -1, cy))
    else
      ok(tz < FIN_TZ - 0.5, string.format("a bare stack, far less (Tz %.3f against %.3f)", tz, FIN_TZ))
    end
  end
end

-- ── the test plane ──────────────────────────────────────────────────────────
-- Built the way the builder lays a runway plane down: nose along +X, top +Y,
-- the cockpit pitched over. Tyre bottoms stand at y = 0.
local NOSE, TOP, SIDE = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
local KT = 9.8 / 7.0     -- the catalogue's thrust rating on a 9.8 m/s² home
local function plane()
  uid = 0
  local Y0, P = 1.5, {}
  local function add(r) P[#P + 1] = r return r end
  -- the cockpit's own axes: +Y the nose, −Z the top ⇒ X = Y × Z
  local cZ = { x = 0, y = -1, z = 0 }
  local cX = cross(NOSE, cZ)
  add(place("cockpit", 1.9, Y0, 0, cX, NOSE))
  add(place("fuseTank", -0.2, Y0, 0, cX, NOSE))
  local j = add(place("jet", -2.1, Y0, 0, cX, NOSE))
  j.thrust = PA.PARTS.jet.thrust * KT
  for _, s in ipairs({ 1, -1 }) do
    local out = { x = 0, y = 0, z = s }
    add(place("wingL", -0.6, Y0, s * (0.5 + 1.75), out, NOSE))
    add(place("wingTip", -0.6, Y0, s * (0.5 + 3.5 + 0.6), out, NOSE))
    add(place("elevon", -2.35, Y0, s * (0.5 + 0.8), out, NOSE))
    local ia = unit({ x = 0, y = 0.707, z = s * 0.707 })
    add(place("intake", 0.5, Y0 + ia.y * 0.7, ia.z * 0.7, ia, NOSE))
    add(place("gearM", -0.45, 0.75, s * 1.4, { x = 0, y = -1, z = 0 }, NOSE))
  end
  add(place("tailFin", -2.3, Y0 + 0.5 + 0.75, 0, TOP, NOSE))
  add(place("gearS", 2.3, 0.5, 0, { x = 0, y = -1, z = 0 }, NOSE))
  for _, r in ipairs(P) do if r.fuel then r.fuel_t = 0.01 end end
  return P
end

local PLANE = plane()
local cmx, cmy, cmz, mass = A.centerOfMass(PLANE)
do
  ok(mass > 1.5 and mass < 2.2, string.format("the light jet weighs %.2f t", mass))
  local n, t = A.frameOf(PLANE)
  ok(near(n.x, 1, 1e-9) and near(t.y, 1, 1e-9), "the cockpit flies the plane: nose +X, top +Y")
  local lx, ly, lz, L = A.centerOfLift(PLANE)
  ok(lx and lx < cmx - 0.1, string.format("centre of lift (x %.2f) sits behind the centre of mass (x %.2f)", lx or 0, cmx))
  ok(lz and math.abs(lz) < 1e-6, "a symmetric plane lifts on its centreline")
  local margin, chords = A.staticMargin(PLANE)
  ok(margin and margin > 0.15 and chords < 0.6, string.format("static margin %.2f m (%.2f chords): stable, not a brick", margin or 0, chords or 0))
  local tx, ty, tz, T, dir = A.centerOfThrust(PLANE)
  ok(tx and near(ty, 1.5, 1e-6) and near(dir.x, 1, 1e-9), "the jet pushes along the fuselage axis")
  local vs, S, CL = A.stallSpeed(PLANE, mass, 9.8, 1.225)
  ok(vs > 25 and vs < 50, string.format("stall speed %.1f m/s on %.1f m² at CLmax %.2f", vs, S, CL))
  print(string.format("PLANE  mass %.2f t  CoM x %.2f  CoL x %.2f  margin %.2f m  wing %.1f m²  CLmax %.2f  Vs %.1f m/s",
    mass, cmx, lx or 0, margin or 0, S, CL, vs))
end

-- control: every axis turns the craft the way the stick says, whatever copy
do
  local M = A.build(PLANE)
  local base = { vx = 50, vy = 0, vz = 0, cx = cmx, cy = cmy, cz = cmz, rho = 1.225, a = 85, dt = 1,
                 ap = { x = 0, y = 0, z = -1 }, ay = TOP, ar = NOSE }
  local function torque(p, y, r)
    local e = {}
    for k, v in pairs(base) do e[k] = v end
    e.ctl = { p = p, y = y, r = r }
    local _, _, _, tx, ty, tz = A.step(M, e)
    return tx, ty, tz
  end
  local x0, y0, z0 = torque(0, 0, 0)
  local x1, y1, z1 = torque(1, 0, 0)
  ok(-(z1 - z0) > 0.3, string.format("W (pitch +1) pitches the nose down (ΔT about −Z %.2f)", -(z1 - z0)))
  local x2, y2, z2 = torque(0, 1, 0)
  ok((y2 - y0) > 0.1, string.format("A (yaw +1) yaws the nose left (ΔT about +Y %.2f)", y2 - y0))
  local x3, y3, z3 = torque(0, 0, 1)
  ok((x3 - x0) > 0.3, string.format("E (roll +1) rolls right (ΔT about the nose %.2f)", x3 - x0))
  ok(math.abs(x1 - x0) < 0.05 and math.abs(y1 - y0) < 0.05, "pitch does not roll or yaw a symmetric plane")
  ok(math.abs(z3 - z0) < 0.05, "roll does not pitch it")
end

-- the jet
do
  local M = A.build(PLANE)
  local j = M.jets[1]
  ok(j and #M.intakes == 2, "one jet, two intakes")
  local env = { vx = 0, vy = 0, vz = 0, cx = cmx, cy = cmy, cz = cmz, rho = 1.225, a = 85, dt = 0.02, throttle = 1, o2 = 1 }
  local t = 0
  while t < 2.2 do A.step(M, env); t = t + 0.02 end
  ok(j.jk > 0.55 and j.jk < 0.72, string.format("spooled ~63%% after its spool time (%.2f)", j.jk))
  for _ = 1, 600 do A.step(M, env) end
  ok(near(j.jk, 1, 0.01), string.format("full static thrust on two intakes (%.3f)", j.jk))
  local env0 = {}
  for k, v in pairs(env) do env0[k] = v end
  env0.o2 = 0
  for _ = 1, 50 do A.step(M, env0) end
  ok(j.jk == 0, "no oxygen, no thrust")
  local bare = A.build({ PLANE[3] })
  for _ = 1, 300 do A.step(bare, env) end
  ok(bare.jets[1].jk == 0, "no intake, no thrust")
  local thin = A.build(PLANE)
  local envv = {}
  for k, v in pairs(env) do envv[k] = v end
  envv.rho = 0
  for _ = 1, 300 do A.step(thin, envv) end
  ok(thin.jets[1].jk == 0, "no air, no thrust")
  local half = A.build(PLANE)
  local envh = {}
  for k, v in pairs(env) do envh[k] = v end
  envh.throttle = 0.5
  for _ = 1, 600 do A.step(half, envh) end
  ok(near(half.jets[1].jk, 0.5, 0.01), "half throttle, half thrust")
  local curve = {}
  for _, m in ipairs({ 0, 0.5, 1.0, 1.5, 2.0 }) do curve[#curve + 1] = string.format("M%.1f %.2f", m, A.jetMach(m, 1.8)) end
  ok(A.jetMach(1.0, 1.8) > 1.0 and A.jetMach(2.2, 1.8) < 0.3, "the jet holds to Mach 1 and dies past ~2")
  print("JET    thrust share by Mach: " .. table.concat(curve, "  "))
end

-- ── the test plane, flown (pitch plane, 3 DOF, on the same aero.step) ──────
-- Ground: each tyre a spring under its bottom point, rolling friction 0.015.
-- The pilot: full throttle; past VR, the stick back to a 10° attitude; then a
-- climb, a level cruise, a power-off stall held to the stick's stop, and the
-- stick let go.
local function fly(P, opts)
  opts = opts or {}
  local M = A.build(P)
  local cx, cy, cz, m = A.centerOfMass(P)
  local I = 0
  for _, d in ipairs(P) do
    local dm = (d.mass or 0) + (d.fuel or 0) * 0.01
    I = I + dm * ((d.x - cx) ^ 2 + (d.y - cy) ^ 2) + dm * ((d.h or 1) ^ 2) / 12
  end
  local wheels = {}
  for _, d in ipairs(P) do
    if d.id == "gearS" or d.id == "gearM" then wheels[#wheels + 1] = { x = d.x - cx, y = 0 - cy } end
  end
  local g, dt = 9.8, 1 / 240
  local th = 0.0                          -- pitch (rad), nose up +
  local px, py = 0, cy                    -- CoM in the world (x along the runway)
  local vx, vy, q = 0, 0, 0
  local T = (P[3].thrust or 0)
  local k = m * g / (#wheels * 0.03)
  local c = 2 * math.sqrt(k * m / #wheels) * 0.6
  local t, log = 0, {}
  local phase, p_cmd = "roll", 0
  local R = {}
  local ctl = { p = 0, y = 0, r = 0 }
  local env = { cx = cx, cy = cy, cz = cz, a = A.soundSpeed(g, 850), o2 = 1, ctl = ctl,
                ap = { x = 0, y = 0, z = -1 }, ay = TOP, ar = NOSE, dt = dt }
  local alt0 = py
  local maxstall, stall_t = 0, nil
  while t < (opts.tmax or 160) do
    local cth, sth = math.cos(th), math.sin(th)
    local alt = py - alt0
    local rho = A.airAt(HOME, math.max(alt, 0), g, 850)
    -- body-frame air velocity
    env.vx, env.vy, env.vz = vx * cth + vy * sth, -vx * sth + vy * cth, 0
    env.wx, env.wy, env.wz = 0, 0, q
    env.rho = rho
    env.throttle = R.thr or 1
    local fx, fy, fz, tx, ty, tz = A.step(M, env)
    local jk = M.jets[1] and M.jets[1].jk or 0
    fx = fx + T * jk
    -- to the world
    local Fx, Fy = fx * cth - fy * sth, fx * sth + fy * cth
    local Tz = tz
    Fy = Fy - m * g
    local onground = 0
    for _, w in ipairs(wheels) do
      local wx = px + w.x * cth - w.y * sth
      local wy = py + w.x * sth + w.y * cth
      if wy < 0 then
        onground = onground + 1
        local vpy = vy + q * (w.x * cth - w.y * sth)
        local vpx = vx - q * (w.x * sth + w.y * cth)
        local N = math.max(0, -k * wy - c * vpy)
        local f = -0.015 * N * (vpx > 0 and 1 or -1)
        if R.brake then f = -0.6 * N * (vpx > 0 and 1 or (vpx < 0 and -1 or 0)) end
        Fx, Fy = Fx + f, Fy + N
        local rx, ry = wx - px, wy - py
        Tz = Tz + rx * N - ry * f
      end
    end
    -- the pilot
    local V = math.sqrt(vx * vx + vy * vy)
    local gamma = math.atan2(vy, vx)
    local function attitude(target, kp, kd)
      return math.max(-1, math.min(1, -(kp * (target - th) - kd * q)))
    end
    if phase == "roll" then
      R.thr = 1
      ctl.p = 0
      if V > (opts.vr or 38) then phase = "rotate"; R.vr, R.xr = V, px end
    elseif phase == "rotate" then
      ctl.p = attitude(D(11), 10, 3)
      if onground == 0 then
        R.air = (R.air or 0) + dt
        if R.air > 0.4 and not R.lof then R.lof, R.vlof, R.tlof = px, V, t; phase = "climb"; R.tc = t end
      else R.air = 0 end
      if px > 400 then phase = "fail" end
    elseif phase == "climb" then
      ctl.p = attitude(D(10), 10, 3)
      if alt > 100 then R.climb = (alt - 0) / (t - R.tlof); phase = "cruise"; R.tcr = t end
    elseif phase == "cruise" then
      -- level at ~105 m: the nose set to hold the height
      local want = math.max(D(-4), math.min(D(8), 0.02 * (105 - alt) - 0.08 * vy + D(2)))
      ctl.p = attitude(want, 5, 2)
      if t - R.tcr > 20 then R.vcruise = V; R.altc = alt; phase = "stall"; R.ts = t; R.thr = 0; R.tht = th end
    elseif phase == "stall" then
      -- power off and a zoom climb: the nose held 20° up as the speed bleeds
      -- away, until the wing lets go near the top
      R.thr = 0
      ctl.p = attitude(D(20), 10, 3)
      local st = M.diag and M.diag.stall or 0
      if st > 0.5 and not R.vstall then
        R.vstall, R.astall, R.tst = V, alt, t
        R.vstall0 = V * math.sqrt(rho / A.RHO0)   -- the same stall at sea level (equivalent airspeed)
      end
      maxstall = math.max(maxstall, st)
      if R.tst and t - R.tst > 1 then phase = "recover"; R.trc = t; R.arc = R.astall end
      if t - R.ts > 40 then phase = "end" end
    elseif phase == "recover" then
      -- let go of the stick, full power; once the nose is down and the wing
      -- flying again, ease back to level
      R.thr = 1
      local st0 = M.diag and M.diag.stall or 0
      -- unload: the nose to 4° over the flight path (the wing flies again),
      -- full power, then ease out of the dive
      if st0 > 0.05 and not R.flying then ctl.p = attitude(gamma + D(4), 6, 2.5)
      else R.flying = true; ctl.p = attitude(math.min(D(4), gamma + D(13)), 20, 3) end
      local st = M.diag and M.diag.stall or 0
      R.minalt = math.min(R.minalt or alt, alt)
      if st < 0.1 and vy > -0.5 and not R.trec then R.trec = t - R.trc end
      if R.trec and t - R.trc > R.trec + 3 then phase = "end" end
      if t - R.trc > 30 then phase = "end" end
    else
      break
    end
    if os.getenv("AERO_DEBUG") and t - (R.lt or -1) >= 0.5 then
      R.lt = t
      print(string.format("  %5.1f %-8s x %6.1f alt %6.1f V %5.1f th %5.1f gam %5.1f aoa %5.1f p %5.2f q %5.2f gnd %d stall %.2f L %.1f D %.1f",
        t, phase, px, alt, V, math.deg(th), math.deg(gamma), math.deg(th - gamma), ctl.p, q, onground,
        M.diag and M.diag.stall or 0, M.diag and M.diag.lift or 0, M.diag and M.diag.drag or 0))
    end
    -- integrate
    vx, vy = vx + Fx / m * dt, vy + Fy / m * dt
    q = q + Tz / I * dt
    px, py = px + vx * dt, py + vy * dt
    th = th + q * dt
    t = t + dt
    if py < cy - 1.2 then R.crash = t break end
  end
  R.maxstall = maxstall
  R.mach = M.diag and M.diag.mach
  return R
end

do
  local R = fly(PLANE)
  ok(not R.crash, "the test plane never hits the ground")
  ok(R.lof and R.lof < 230, string.format("it leaves the runway in %.0f m (of 250) at %.1f m/s", R.lof or -1, R.vlof or 0))
  ok(R.climb and R.climb > 3, string.format("it climbs at %.1f m/s", R.climb or 0))
  ok(R.vcruise and R.vcruise > 55, string.format("full-power level speed %.1f m/s", R.vcruise or 0))
  ok(R.vstall and R.vstall0 < 50, string.format("held back with the power off it stalls at %.1f m/s (%.1f at sea level)", R.vstall or 0, R.vstall0 or 0))
  ok(R.trec and R.trec < 10, string.format("let go, it recovers in %.1f s", R.trec or -1))
  ok(R.minalt and R.arc and (R.arc - R.minalt) < 90 and R.minalt > 5, string.format("losing %.1f m (lowest %.1f m)", (R.arc or 0) - (R.minalt or 0), R.minalt or -1))
  print(string.format("FLIGHT rotate %.1f m/s at %.0f m · liftoff %.0f m at %.1f m/s · climb %.1f m/s · full-power level %.1f m/s at %.0f m (Mach %.2f) · stall %.1f m/s at %.0f m (%.1f at sea level) · recovered in %.1f s, %.1f m lost",
    R.vr or 0, R.xr or 0, R.lof or 0, R.vlof or 0, R.climb or 0, R.vcruise or 0, R.altc or 0, (R.vcruise or 0) / A.soundSpeed(9.8, 850),
    R.vstall or 0, R.astall or 0, R.vstall0 or 0, R.trec or -1, (R.arc or 0) - (R.minalt or 0)))
end

-- ── verdict ─────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("SMOKE OK — aero: %d checks", checks))
  os.exit(0)
else
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
