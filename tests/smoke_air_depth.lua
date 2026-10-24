-- SMOKE HARNESS: DEEP AIR (world scale 4, 2026-10-24).
--
-- "deeper atmospheres … it still feels like things are too small". Scale 4 is
-- scale 3's system, draw for draw, under air ~2.5× as deep with a real density
-- scale height (system_generator SCALES[4]; tests/smoke_world_scale.lua holds
-- the bodies). This flies that air, on the same maths the game uses
-- (aero.lua airAt, machDrag), for every air world of ten seeds at scales 3
-- and 4, and checks:
--   * the air: 1 on the ground, continuous and falling, exactly 0 at the
--     top; a scale-3 record keeps the engine's (1 − h/H)², bit for bit;
--   * PLANES: the ceiling of a light jet (the height where the air left,
--     against the gravity left, falls under what it needs at full power —
--     calibrated to the 70–100 m scale 3 gave in the engine) rises to
--     hundreds of metres;
--   * ASCENT: a rocket flown to the Made Orbit periapsis (which now clears
--     the air) spends a Δv within reach of scale 3's, drag a small share of
--     it, with a sea-level exhaust penalty (asl) taken over the deeper air;
--   * RE-ENTRY: from that orbit, and a fast interplanetary return, the loads
--     stay small and the deeper air brakes the craft harder; a powered dive
--     past the heating onset burns about what it did (more air column, less
--     of it dense).
--
--   luajit solar/tests/smoke_air_depth.lua

local bit = require("bit")

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end

-- ── the generator, offline (the engine's xorshift32, as smoke_world_scale) ──
local function U32(x) return x % 4294967296 end
local function rng(seed)
  local st = U32(math.floor(seed or 1))
  if st == 0 then st = 0x9E3779B9 end
  local function nxt()
    local x = bit.tobit(st)
    x = bit.bxor(x, bit.lshift(x, 13))
    x = bit.bxor(x, bit.rshift(x, 17))
    x = bit.bxor(x, bit.lshift(x, 5))
    st = U32(x)
    return st
  end
  local r = { seed = seed }
  function r:next() return math.floor(nxt() / 256) / 16777216 end
  function r:range(a, b) return a + (b - a) * self:next() end
  function r:int(a, b)
    local lo, hi = math.min(a, b), math.max(a, b)
    return lo + nxt() % (hi - lo + 1)
  end
  function r:pick(list) return list[self:int(1, #list)] end
  return r
end

local store, nodes = {}, {}
local function mknode(name)
  local n = { name = name, valid = true, tags = {} }
  function n:setTerrain() end
  function n:setTerrainGen(o) self.gen = o end
  function n:setCelestial(c) self.cel = c end
  function n:setPrimitive() end
  function n:setMaterial() end
  function n:destroy() self.valid = false end
  nodes[#nodes + 1] = n
  return n
end
local env = setmetatable({
  rng = rng, save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  print = function() end, log = function() end,
  terrain = { generatePlanet = function() end },
  createNode = function(name, a, b)
    local fn = type(a) == "function" and a or b
    local n = mknode(name)
    if fn then fn(n) end
    return n
  end,
  spawn = function(_, _, fn) local n = mknode("spawned") if fn then fn(n) end return n end,
  find = function() return nil end,
  findTagged = function(tag)
    local out = {}
    for _, n in ipairs(nodes) do
      if n.valid then for _, t in ipairs(n.tags or {}) do if t == tag then out[#out + 1] = n end end end
    end
    return out
  end,
  space = { time = function() return 0 end },
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/system_generator.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end

local A = setmetatable({}, { __index = _G })
local achunk = assert(loadfile("solar/scripts/aero.lua"))
setfenv(achunk, A)
achunk()

-- Every air world of a roll: its record, radius, µ, SOI and bodyRadius.
local function worlds(seed, scale)
  store, nodes = {}, {}
  env.regenerate(seed, { scale = scale, pregen = true })
  local out = {}
  for _, n in ipairs(nodes) do
    if n.valid and n.gen and n.cel and (n.cel.atmoHeight or 0) > 0 then
      out[#out + 1] = { name = n.name, w = store["world." .. n.name], R = n.gen.radius, mu = n.cel.mu,
        soi = n.cel.soi, bodyR = n.cel.bodyRadius, home = (store["system.home"].bodies[1].name == n.name) }
    end
  end
  return out
end

-- ── 1. the air curve ────────────────────────────────────────────────────────
do
  local deep = { atmo = 0.75, atmoHeight = 700, atmoScaleH = 280, radius = 800 }
  local flat = { atmo = 0.75, atmoHeight = 700, radius = 800 }
  local r0 = A.airAt(deep, 0, 9.8, 800)
  check(math.abs(r0 - A.RHO0) < 1e-9, "deep air: sea-level air on the ground")
  check(math.abs(A.airAt(flat, 0, 9.8, 800) - r0) < 1e-12, "the same ground air either way")
  local prev, smooth_ok = r0, true
  for h = 1, 699 do
    local r = A.airAt(deep, h, 9.8, 800)
    if not (r < prev and prev - r < r0 * 0.01) then smooth_ok = false end
    prev = r
  end
  check(smooth_ok, "deep air falls every metre, never by a step")
  check(A.airAt(deep, 700, 9.8, 800) == 0 and A.airAt(deep, 900, 9.8, 800) == 0, "nothing at or past the top")
  check(prev < r0 * 0.002, "…and next to nothing just under it")
  check(math.abs(A.airAt(deep, 280, 9.8, 800) / r0 - (math.exp(-1) - math.exp(-2.5)) / (1 - math.exp(-2.5))) < 1e-12,
    "one scale height up: e⁻¹, tapered")
  -- scale 1–3 records: exactly the engine's curve, as before
  for _, h in ipairs({ 0, 50, 175, 350, 600 }) do
    local f = 1 - h / 700
    check(A.airAt(flat, h, 9.8, 800) == A.RHO0 * f * f, "a record with no scale height keeps (1 − h/H)² at " .. h)
  end
  check(A.airAt(deep, -50, 9.8, 800) > r0 and A.airAt(deep, -1e6, 9.8, 800) < r0 * 2.2,
    "below the datum a little thicker, never unbounded")
  check(A.airAt({ atmo = 0, atmoHeight = 700, atmoScaleH = 280 }, 0, 9.8, 800) == 0, "an airless world has none")
end

-- ── 2. planes: the ceiling ──────────────────────────────────────────────────
-- A light jet at full power holds its weight where (air left) / (gravity
-- left) ≥ NEED. 0.55 is what the engine's flights at scale 3 say: the probe
-- jet topped out at 70–100 m under 0.25–0.45-radius (1 − h/H)² air.
local NEED = 0.55
local function ceiling(wd, R, mu)
  local g0 = mu / (R * R)
  local r0 = A.airAt(wd, 0, g0, R)
  for h = 0, 6000 do
    local g = mu / ((R + h) ^ 2)
    if A.airAt(wd, h, g0, R) / r0 < NEED * g / g0 then return h end
  end
  return 6000
end

-- ── 3. ascent: a 2-D gravity turn with drag and a sea-level exhaust penalty ──
local CDA_M = 1.25 / 4000   -- m²/kg: a 1.8 m stack, Cd ~0.5, 4 t
local ASL = tonumber(os.getenv("AIR_ASL") or "") or 0.6   -- thrust share at sea level (an Anvil-like engine)
local VE = 400              -- m/s, vacuum (only the Δv bookkeeping reads it)
local TWR = 1.8
local function ascend(wd, R, mu, target, turn, asl)
  asl = asl or ASL
  local g0 = mu / (R * R)
  local r0 = A.airAt(wd, 0, g0, R)
  local a_snd = A.soundSpeed(g0, R)
  local r, th, vr, vt, m = R, 0, 0, 0, 1.0
  local mdot = TWR * g0 / VE
  local dt = 0.02
  local dv_drag, t = 0, 0
  local burning
  for _ = 1, 200000 do
    local h = r - R
    local v = math.sqrt(vr * vr + vt * vt)
    local rho = A.airAt(wd, h, g0, R)
    local share = rho / r0
    local ar, at = -mu / (r * r) + vt * vt / r, -vr * vt / r
    if v > 1e-6 then
      local d = 0.5 * rho * v * v * CDA_M * A.machDrag(v / a_snd)
      ar, at = ar - d * vr / v, at - d * vt / v
      dv_drag = dv_drag + d * dt
    end
    -- the engine runs while the apoapsis is short of the target (it relights
    -- to make good what the drag takes on the coast up through the air)
    do
      local en = 0.5 * (vr * vr + vt * vt) - mu / r
      local hh = r * vt
      local a = -mu / (2 * en)
      local e = math.sqrt(math.max(0, 1 + 2 * en * hh * hh / (mu * mu)))
      burning = not (en < 0 and a * (1 + e) - R >= target)
    end
    if burning then
      local ve = VE * (asl + (1 - asl) * (1 - share))
      local acc = mdot * ve / m
      local pitch = math.rad(90) * math.min(1, (math.max(h, 0) / turn) ^ 0.55)
      ar, at = ar + acc * math.cos(pitch), at + acc * math.sin(pitch)
      m = m - mdot * dt
      if m < 0.05 then return nil end
    end
    vr, vt = vr + ar * dt, vt + at * dt
    r, th = r + vr * dt, th + vt / r * dt
    t = t + dt
    if r < R - 1 then return nil end
    if not burning and vr <= 0 then
      -- at apoapsis: circularise
      local circ = math.sqrt(mu / r) - vt
      return VE * math.log(1 / m) + math.abs(circ), dv_drag, t, r - R
    end
  end
  return nil
end
local function best_ascent(wd, R, mu, target, asl)
  local best
  for _, k in ipairs({ 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3 }) do
    local dv, drag, t, alt = ascend(wd, R, mu, target, target * k, asl)
    if dv and alt >= target * 0.98 and (not best or dv < best.dv) then
      best = { dv = dv, drag = drag, t = t, k = k }
    end
  end
  return best
end

-- ── 4. re-entry ─────────────────────────────────────────────────────────────
-- Ballistic (m/CdA 3200 kg/m²) from (alt, speed, flight-path angle) to the
-- ground: the peak deceleration (g0s), the peak of the heating law the flight
-- uses (ρ^1.5·v³, as a share of sea-level air at 100 m/s) and the speed left
-- 20 m up.
local function reentry(wd, R, mu, alt, v, gam, cda_m)
  cda_m = cda_m or CDA_M
  local g0 = mu / (R * R)
  local r0 = A.airAt(wd, 0, g0, R)
  local a_snd = A.soundSpeed(g0, R)
  local r = R + alt
  local vr, vt = v * math.sin(gam), v * math.cos(gam)
  local dt = 0.01
  local gmax, hmax, v20, burn, lost = 0, 0, nil, 0, 0
  for _ = 1, 400000 do
    local h = r - R
    local sp = math.sqrt(vr * vr + vt * vt)
    local rho = A.airAt(wd, h, g0, R)
    local d = 0.5 * rho * sp * sp * cda_m * A.machDrag(sp / a_snd)
    gmax = math.max(gmax, d / g0)
    lost = lost + d * dt
    hmax = math.max(hmax, (rho / r0) ^ 1.5 * (sp / 100) ^ 3)
    -- the flight's own heating law (vessel_controller: past 90·vk m/s,
    -- density^1.5 · (v / 130·vk)³ · 0.03 hp/s at the nose; vk 2.2 at scale 3–4)
    if sp > 90 * 2.2 then burn = burn + math.min(1, rho / r0) ^ 1.5 * (sp / (130 * 2.2)) ^ 3 * 0.03 * dt end
    if h < 20 and not v20 then v20 = sp end
    local ar = -mu / (r * r) + vt * vt / r - d * vr / math.max(sp, 1e-9)
    local at = -vr * vt / r - d * vt / math.max(sp, 1e-9)
    vr, vt = vr + ar * dt, vt + at * dt
    r = r + vr * dt
    if r <= R or (vr > 0 and r > R + alt + 1) then break end
  end
  return gmax, hmax, v20, burn, lost
end

-- ── fly every air world of ten seeds at both scales ─────────────────────────
local SEEDS = { 1911564384, 31337, 424242, 777001, 99, 1902723835, 7, 23, 5150, 8675309 }
local rows, home_c3, home_c4 = {}, {}, {}
local worst_dv, worst_drag, worst_g, worst_heat, n = 0, 0, 0, 0, 0
for _, seed in ipairs(SEEDS) do
  local w3, w4 = worlds(seed, 3), worlds(seed, 4)
  check(#w3 == #w4 and #w3 > 0, seed .. ": the same air worlds at both scales")
  for i, a in ipairs(w4) do
    local b = w3[i]
    n = n + 1
    local c3, c4 = ceiling(b.w, b.R, b.mu), ceiling(a.w, a.R, a.mu)
    if a.home then home_c3[#home_c3 + 1], home_c4[#home_c4 + 1] = c3, c4 end
    check(c4 >= 2.4 * c3 and c4 >= 120,
      string.format("seed %d %s: jet ceiling %d m (scale 3: %d m)", seed, a.name, c4, c3))
    -- the Made Orbit periapsis (missions target_of): 10 % of the room, and
    -- clear of the air
    local function target(x) return math.max(0.10 * (x.soi - x.bodyR), x.w.atmoHeight * 1.08) end
    local t3, t4 = target(b), target(a)
    local A3, A4 = best_ascent(b.w, b.R, b.mu, t3), best_ascent(a.w, a.R, a.mu, t4)
    check(A3 and A4, seed .. " " .. a.name .. ": both ascents reach orbit")
    if A3 and A4 then
      local ratio = A4.dv / A3.dv
      worst_dv = math.max(worst_dv, ratio)
      worst_drag = math.max(worst_drag, A4.drag / A4.dv)
      check(ratio <= 1.15, string.format("seed %d %s: ascent Δv %.0f m/s vs %.0f at scale 3 (×%.2f)", seed, a.name, A4.dv, A3.dv, ratio))
      -- what the builder's readout quotes as "orbit needs" (builder.lua
      -- orbitNeed: 1.5 × the ideal two-burn climb) still covers it
      local ro = a.R + t4
      local vp = math.sqrt(2 * a.mu * ro / (a.R * (a.R + ro)))
      local need = 1.5 * (vp + (math.sqrt(a.mu / ro) - vp * a.R / ro))
      -- (flown with the vacuum engine: the readout does not model asl,
      -- which is the balance's to price — see the report)
      local V4 = best_ascent(a.w, a.R, a.mu, t4, 1.0)
      check(V4 and V4.dv <= need, string.format("seed %d %s: the ascent's %.0f m/s fits the readout's %.0f", seed, a.name, V4 and V4.dv or -1, need))
      check(A4.drag / A4.dv < 0.08, string.format("seed %d %s: drag is %.1f%% of the ascent", seed, a.name, 100 * A4.drag / A4.dv))
    end
    -- re-entry from the contract orbit (a retro burn to a periapsis at the
    -- ground) and a fast return from another planet, both entering at the
    -- top of each scale's air
    local function deorbit(x, tgt)
      local ro = x.R + tgt
      local va = math.sqrt(2 * x.mu * x.R / (ro * (x.R + ro)))   -- apoapsis speed of a ro × R ellipse
      local top = x.R + x.w.atmoHeight
      -- speed and flight-path angle where that ellipse crosses the air's top
      local en = 0.5 * va * va - x.mu / ro
      local v = math.sqrt(2 * (en + x.mu / top))
      local hh = ro * va
      local gam = -math.acos(math.min(1, hh / (top * v)))
      return reentry(x.w, x.R, x.mu, x.w.atmoHeight, v, gam)
    end
    local g3, h3, v3 = deorbit(b, t3)
    local g4, h4, v4 = deorbit(a, t4)
    -- A FAST RETURN: from another planet at 1.2× the escape speed (a v∞ of
    -- ~2/3 escape), 20° down at the top of the air, in a light capsule
    -- (m/CdA 800 kg/m²) — and a POWERED DIVE at 250 m/s, 45° down, the only
    -- way past the heating onset (90·vk = 198 m/s) at these sizes.
    local CAP = 1 / 800
    -- the conic: a v∞ of 2/3 the surface escape speed, aimed at a periapsis
    -- 0.15 radii up (inside either air), entered where it crosses the top
    local function pass(x)
      local vinf = (2 / 3) * math.sqrt(2 * x.mu / x.R)
      local rp = x.R * 1.15
      local en = 0.5 * vinf * vinf
      local vp = math.sqrt(2 * (en + x.mu / rp))
      local top = x.R + x.w.atmoHeight
      local v = math.sqrt(2 * (en + x.mu / top))
      local gam = -math.acos(math.min(1, rp * vp / (top * v)))
      return reentry(x.w, x.R, x.mu, x.w.atmoHeight, v, gam, CAP)
    end
    local fg3, _, _, _, fl3 = pass(b)
    local fg4, _, _, _, fl4 = pass(a)
    local _, _, _, fb3 = reentry(b.w, b.R, b.mu, b.w.atmoHeight, 250, math.rad(-45), CAP)
    local _, _, _, fb4 = reentry(a.w, a.R, a.mu, a.w.atmoHeight, 250, math.rad(-45), CAP)
    worst_g = math.max(worst_g, fg4)
    worst_heat = math.max(worst_heat, fb4)
    check(g4 < 0.5 and fg4 < 3.0, string.format("seed %d %s: re-entry loads stay sane (orbit %.2f g, fast %.2f g)", seed, a.name, g4, fg4))
    check(fl4 >= fl3 * 0.95, string.format(
      "seed %d %s: the deeper air aerobrakes the pass at least as well (%.1f m/s off, scale 3: %.1f)",
      seed, a.name, fl4, fl3))
    check(fb4 <= math.max(fb3 * 1.6, 0.05), string.format(
      "seed %d %s: a 250 m/s dive burns %.3f hp off the nose (scale 3: %.3f)", seed, a.name, fb4, fb3))
    rows[#rows + 1] = string.format("  %-10s %s r %4.0f g %4.1f top %4.0f→%4.0f m  jet ceiling %3d→%3d m  orbit %4.0f→%4.0f m  ascent Δv %3.0f→%3.0f (drag %2.0f→%2.0f)  fast pass %.2f→%.2f g %.0f→%.0f m/s off, dive burns %.3f→%.3f hp",
      a.name, a.home and "H" or " ", a.R, a.mu / a.R ^ 2, b.w.atmoHeight, a.w.atmoHeight, c3, c4, t3, t4,
      A3 and A3.dv or -1, A4 and A4.dv or -1, A3 and A3.drag or -1, A4 and A4.drag or -1, fg3, fg4, fl3, fl4, fb3, fb4)
  end
end
check(n >= 15, "flew " .. n .. " air worlds")
table.sort(home_c4)
check(#home_c4 == #SEEDS and home_c4[1] >= 180, string.format("every home's jet ceiling ≥ 180 m (lowest %d)", home_c4[1] or -1))

if os.getenv("AIR_DEBUG") then for _, r in ipairs(rows) do print(r) end end
if #failures == 0 then
  table.sort(home_c3)
  print(string.format("SMOKE OK — deep air: %d checks over %d air worlds; home jet ceilings %d–%d m (scale 3: %d–%d m); ascent Δv ≤ ×%.2f scale 3's, drag ≤ %.1f%%; fast return ≤ %.2f g, a 250 m/s dive burns ≤ %.3f hp",
    checks, n, home_c4[1], home_c4[#home_c4], home_c3[1], home_c3[#home_c3], worst_dv, 100 * worst_drag, worst_g, worst_heat))
  os.exit(0)
else
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
