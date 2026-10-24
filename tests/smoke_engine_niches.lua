-- SMOKE: ENGINE NICHES — sea level against vacuum (rating version 3).
--
-- parts_registry.lua RATED[3] gives each engine a job instead of a rank:
--   Sputter  the lander / small-probe engine: light, cheap, fine anywhere
--   Anvil    the upper stage: the best vacuum ve, a weak vacuum bell at sea level
--   Skipper  the lifter: big thrust that holds up at sea level, heavy, so-so ve
-- An engine's thrust and ve are its vacuum figures times the nozzle factor
-- k(σ) = 1 − (1 − asl)·σ, σ the air's density over reference sea level
-- (aero.lua `airAt`), at a constant burn rate. vessel_controller applies the
-- same factor in flight.
--
-- This flies the arithmetic: a 2-D gravity turn from the pad to the contract
-- orbit (builder.lua `orbitAlt`), with the air from aero.lua's own `airAt`
-- (thrust by the nozzle factor, a body drag), staging when a stage runs dry,
-- and the turn chosen as a pilot would (the best of a handful). It reports the
-- Δv LEFT in orbit. On scale-3 worlds (system_generator SCALES[3], with the
-- gravity-v2 9.8 m/s² homes) and under scale 4's deep air when aero.lua has it:
--   * the sensible starter orbiter (Pod, Chute, FT-M, Sputter) still makes orbit;
--   * an Anvil on one FT-M still makes orbit (the Anvil is worth buying before
--     the Skipper), but an Anvil-only big stack can't lift off full;
--   * Skipper → Anvil, two stages, clearly beats a single-stage Skipper on the
--     same tanks and beats Anvil-only, and the Anvil is the best upper stage;
--   * version 2's figures are untouched (old saves fly as they did).
--
--   luajit solar/tests/smoke_engine_niches.lua
--   SOLAR_NICHE_TABLE=1 luajit solar/tests/smoke_engine_niches.lua   # the table

local failures = {}
local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end

-- ── the rulebooks, from disk ────────────────────────────────────────────────
local function load_env(path, extra)
  local env = setmetatable(extra or {}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local R = load_env("solar/scripts/parts_registry.lua")
local A = load_env("solar/scripts/aero.lua")
local store = {}
local B = load_env("solar/scripts/builder.lua", {
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k) if k == "parts_registry" then return R end end,
  findScripts = function() return {} end,
  print = function() end,
})
local U = B.FUEL_T_PER_UNIT or 0.01

-- ── the figures ─────────────────────────────────────────────────────────────
check(R.RATING_LATEST == 3 and R.RATED and R.RATED[3], "rating version 3 is the latest and has engine figures")
local E = {}
for _, id in ipairs({ "engineS", "engineM", "skipper" }) do
  E[id] = R.engineAt(id, 3)
  check(E[id] and E[id].asl < 1 and E[id].desc, id .. ": v3 has a sea-level share and a job line")
  local v2 = R.engineAt(id, 2)
  check(v2 and v2.asl == 1 and v2.thrust == R.REG[id].thrust and v2.ve == R.REG[id].ve,
    id .. ": version 2 keeps the plain registry figures, the same in air and vacuum")
end
-- the frozen v2 table itself (a v2 save's catalogue): never edited
check(R.REG.engineS.thrust == 35 and R.REG.engineS.ve == 160 and R.REG.engineM.thrust == 85
  and R.REG.engineM.ve == 173 and R.REG.skipper.thrust == 170 and R.REG.skipper.ve == 184,
  "the version-2 figures are untouched")
local S, An, K = E.engineS, E.engineM, E.skipper
check(An.ve > K.ve and An.ve > S.ve, "the Anvil has the best vacuum ve")
check(K.ve * K.asl > An.ve * An.asl and K.ve * K.asl > S.ve * S.asl, "the Skipper has the best sea-level ve")
check(K.thrust * K.asl > 3 * An.thrust * An.asl, "the Skipper out-pushes the Anvil at sea level by far")
check(An.asl < S.asl and An.asl < K.asl, "the Anvil's vacuum bell loses the most at sea level")
check(S.asl >= 0.9 and R.REG.engineS.mass < R.REG.engineM.mass and R.REG.engineS.cost < R.REG.engineM.cost,
  "the Sputter is decent everywhere, light and cheap")
check(R.REG.skipper.mass > R.REG.engineM.mass, "the Skipper is the heavy one")
-- the nozzle factor
check(R.nozzle(0.6, 0) == 1 and math.abs(R.nozzle(0.6, 1) - 0.6) < 1e-12 and R.nozzle(nil, 1) == 1
  and R.nozzle(1, 2) == 1 and R.nozzle(0.6, 100) >= R.NOZZLE_FLOOR,
  "nozzle: vacuum is 1, sea level is asl, an unrated part is 1, never under the floor")

-- the inspector reads both ways only when they differ
local I = load_env("solar/scripts/builder_inspector.lua", { findScript = function() return nil end })
check(I.pairText(1.18, 1.96, "%.2f") == "1.18 pad · 1.96 vac" and I.pairText(nil, 1.96, "%.2f") == "1.96"
  and I.pairText(1.96, 1.96, "%.2f") == "1.96" and I.pairText(166, 180, "%.0f", " kN", "sea") == "166 sea · 180 vac kN",
  "the inspector's figures read pad / sea against vacuum, one figure when they agree")

-- ── the flight ──────────────────────────────────────────────────────────────
local PAYLOAD = R.REG.pod.mass + R.REG.chute.mass
local function stack(list)
  -- list bottom-first: { eng, tanks = n FT-M (or tankS = n) }
  local out = {}
  for i, s in ipairs(list) do
    local e = E[s.eng]
    local dry, fu = R.REG[s.eng].mass, 0
    local cost = R.REG[s.eng].cost
    for _ = 1, s.m or 0 do dry, fu, cost = dry + R.REG.tankM.mass, fu + R.REG.tankM.fuel * U, cost + R.REG.tankM.cost end
    for _ = 1, s.s or 0 do dry, fu, cost = dry + R.REG.tankS.mass, fu + R.REG.tankS.fuel * U, cost + R.REG.tankS.cost end
    if i < #list then dry, cost = dry + R.REG.decoupler.mass, cost + R.REG.decoupler.cost end
    out[i] = { dry = dry, fu = fu, e = e, cost = cost }
  end
  return out
end

-- one ascent: straight up to h0, a linear pitch-over to h1, burn until the
-- apoapsis reaches `alt`, coast, and circularise from what is left. Returns
-- the Δv left in orbit (negative: short), or nil (never got there).
local function fly(st, w, h0, h1, kT, kV)
  local mu, Rb = w.g * w.r * w.r, w.r
  local m = PAYLOAD
  for _, s in ipairs(st) do m = m + s.dry + s.fu end
  local si, left = 1, st[1].fu
  local x, y, vx, vy, dt = 0.0, Rb, 0.0, 0.0, 0.01
  local burning = true
  local function vac_dv_left()
    local s = st[si]
    local dv = left > 0 and s.e.ve * kV * math.log(m / (m - left)) or 0
    local mm = m - left - s.dry
    for j = si + 1, #st do
      dv = dv + st[j].e.ve * kV * math.log(mm / (mm - st[j].fu))
      mm = mm - st[j].fu - st[j].dry
    end
    return dv
  end
  for _ = 1, 600000 do
    local r = math.sqrt(x * x + y * y)
    if r < Rb - 0.5 then return nil end
    local ux, uy = x / r, y / r
    local ex, ey = uy, -ux
    local h = r - Rb
    local ax, ay = -mu * x / r ^ 3, -mu * y / r ^ 3
    local rho = A.airAt(w.rec, h, w.g, Rb)
    local sigma = rho / A.RHO0
    local v = math.sqrt(vx * vx + vy * vy)
    if v > 0 and rho > 0 then
      -- a 1.25 m stack end-on: Cd 0.5 over ~1.2 m², kN
      local D = 0.5 * rho * v * v * 0.6 / 1000
      ax, ay = ax - D / m * vx / v, ay - D / m * vy / v
    end
    if burning then
      local v2, hh = vx * vx + vy * vy, x * vy - y * vx
      local En = 0.5 * v2 - mu / r
      local apo = math.huge
      if En < 0 then
        local a = -mu / (2 * En)
        apo = a * (1 + math.sqrt(math.max(0, 1 + 2 * En * hh * hh / (mu * mu))))
      end
      if left <= 1e-9 then
        if si < #st then m = m - st[si].dry; si = si + 1; left = st[si].fu else burning = false end
      end
      if burning and apo - Rb >= w.alt then
        burning = false
      elseif burning then
        local s = st[si]
        local p = (h < h0) and 0 or math.min(1, (h - h0) / math.max(1, h1 - h0))
        local ang = p * math.pi / 2 * 0.95
        local dx, dy = math.cos(ang) * ux + math.sin(ang) * ex, math.cos(ang) * uy + math.sin(ang) * ey
        local T = s.e.thrust * kT
        local F = T * R.nozzle(s.e.asl, sigma)          -- what this nozzle gives in this air
        local burn = math.min(left, T / (s.e.ve * kV) * dt)  -- the burn rate never changes
        left, m = left - burn, m - burn
        ax, ay = ax + F / m * dx, ay + F / m * dy
      end
    elseif (vx * ux + vy * uy) <= 0 and h > 1 then
      return vac_dv_left() - (math.sqrt(mu / r) - math.abs(vx * ex + vy * ey))
    end
    local nvx, nvy = vx + ax * dt, vy + ay * dt
    local nx, ny = x + nvx * dt, y + nvy * dt
    if math.sqrt(nx * nx + ny * ny) < Rb and h < 0.01 then
      vx, vy = 0, 0       -- on the pad: it sits there burning until it lifts
    else
      vx, vy, x, y = nvx, nvy, nx, ny
    end
  end
  return nil
end
local function best(st, w, kT, kV)
  local k = math.max(1, w.r / 310)
  local b
  for _, h0 in ipairs({ 2, 5, 10, 20, 40 }) do
    for _, h1 in ipairs({ 20, 40, 80, 120, 200, 300, 450, 700 }) do
      if h1 > h0 then
        local s = fly(st, w, h0 * k, h1 * k, kT, kV)
        if s and (not b or s > b) then b = s end
      end
    end
  end
  return b
end
local function pad_twr(st, w, kT)
  local m = PAYLOAD
  for _, s in ipairs(st) do m = m + s.dry + s.fu end
  local sigma = A.airAt(w.rec, 0, w.g, w.r) / A.RHO0
  local T = st[1].e.thrust * kT
  return T * R.nozzle(st[1].e.asl, sigma) / (m * w.g), T / (m * w.g)
end

local CRAFT = {
  { "starter", { { eng = "engineS", s = 1 } } },
  { "S+FT-M", { { eng = "engineS", m = 1 } } },
  { "A+FT-M", { { eng = "engineM", m = 1 } } },
  { "A+2FT-M", { { eng = "engineM", m = 2 } } },
  { "A+4FT-M", { { eng = "engineM", m = 4 } } },
  { "A+6FT-M", { { eng = "engineM", m = 6 } } },
  { "K+4FT-M", { { eng = "skipper", m = 4 } } },
  { "K+6FT-M", { { eng = "skipper", m = 6 } } },
  { "K3|A1", { { eng = "skipper", m = 3 }, { eng = "engineM", m = 1 } } },
  { "K4|A2", { { eng = "skipper", m = 4 }, { eng = "engineM", m = 2 } } },
  { "K4|S2", { { eng = "skipper", m = 4 }, { eng = "engineS", m = 2 } } },
  { "K4|K2", { { eng = "skipper", m = 4 }, { eng = "skipper", m = 2 } } },
  { "A4|A2", { { eng = "engineM", m = 4 }, { eng = "engineM", m = 2 } } },
}

-- Scale-3 homes (gravity v2 stands a new home at 9.8 m/s²; the scale's range
-- is 3.5–8.5) with their air: atmo 0.62–0.85, a top 0.28–0.40 radii, thinning
-- (1 − h/H)². Scale 4 (deep air) is the same worlds under a top 0.745–0.925
-- radii with an exponential profile, when aero.lua knows it (airShare).
local deep = A.airShare ~= nil
local WORLDS = {}
for _, base in ipairs({
  { name = "home small", g = 9.8, r = 600, atmo = 0.75 },
  { name = "home mid", g = 9.8, r = 775, atmo = 0.75 },
  { name = "home big thick", g = 9.8, r = 950, atmo = 0.85 },
  { name = "v3 typical", g = 6.0, r = 775, atmo = 0.62 },
  { name = "v3 big light", g = 3.5, r = 950, atmo = 0.75 },
}) do
  WORLDS[#WORLDS + 1] = { name = base.name .. " (s3 air)", g = base.g, r = base.r,
    rec = { atmo = base.atmo, atmoHeight = 0.34 * base.r, radius = base.r } }
  if deep then
    local H = 0.835 * base.r
    WORLDS[#WORLDS + 1] = { name = base.name .. " (s4 deep air)", g = base.g, r = base.r,
      rec = { atmo = base.atmo, atmoHeight = H, atmoScaleH = 0.4 * H, radius = base.r } }
  end
end

local TABLE = os.getenv("SOLAR_NICHE_TABLE")
for _, w in ipairs(WORLDS) do
  w.soi = 12 * (w.r + math.max(w.r * 0.035, 4))
  store["launch.world"] = { name = w.name, g = w.g, r = w.r, soi = w.soi }
  store["parts.rating"] = nil
  local W = B.launchWorld()
  local k = B.rating(W)
  local kT, kV = k.thrust, k.ve
  w.alt = B.orbitAlt(W)
  if TABLE then
    print(string.format("\n%s  g %.1f  r %d  orbit %.0f m up  air top %.0f m  (kT %.2f kV %.3f)",
      w.name, w.g, w.r, w.alt, w.rec.atmoHeight, kT, kV))
  end
  local res = {}
  for _, c in ipairs(CRAFT) do
    local st = stack(c[2])
    local cost = R.REG.pod.cost + R.REG.chute.cost
    for _, s in ipairs(st) do cost = cost + s.cost end
    local tsl, tvac = pad_twr(st, w, kT)
    local spare = best(st, w, kT, kV)
    res[c[1]] = { spare = spare, tsl = tsl, tvac = tvac, cost = cost }
    if TABLE then
      print(string.format("  %-9s $%5d  pad TWR %.2f (vac %.2f)  Δv left in orbit %s", c[1], cost, tsl, tvac,
        spare and string.format("%5.0f m/s", spare) or "   never"))
    end
  end
  local function ok(key) return res[key].spare and res[key].spare > 0 end
  local function sp(key) return res[key].spare or -math.huge end
  local n = w.name
  check(not ok("starter"), n .. ": the First Flight starter still can't make orbit")
  check(ok("S+FT-M"), string.format("%s: the starter orbiter (Sputter + FT-M) makes orbit (%.0f m/s left)", n, sp("S+FT-M")))
  check(ok("A+FT-M"), string.format("%s: an Anvil on one FT-M makes orbit (%.0f m/s left)", n, sp("A+FT-M")))
  check(res["A+FT-M"].tsl < 0.75 * res["A+FT-M"].tvac,
    string.format("%s: ...but its pad TWR %.2f is well under its vacuum %.2f", n, res["A+FT-M"].tsl, res["A+FT-M"].tvac))
  -- (it sits on the pad burning until it is light enough to lift, as in the game)
  check(res["A+4FT-M"].tsl < 1 and res["A+6FT-M"].tsl < 1 and res["A4|A2"].tsl < 1,
    n .. ": an Anvil-only big stack can't lift off with its tanks full")
  check(res["K+6FT-M"].tsl >= 1.4, string.format("%s: the Skipper lifts six FT-M at TWR %.2f", n, res["K+6FT-M"].tsl))
  -- the classic two-stage rocket
  check(sp("K3|A1") >= 1.2 * sp("K+4FT-M"), string.format(
    "%s: Skipper → Anvil beats a single-stage Skipper on the same four tanks by ≥ 20 %% (%.0f vs %.0f m/s)",
    n, sp("K3|A1"), sp("K+4FT-M")))
  check(sp("K4|A2") >= 1.3 * sp("K+6FT-M"), string.format(
    "%s: ...and on six tanks by ≥ 30 %% (%.0f vs %.0f m/s)", n, sp("K4|A2"), sp("K+6FT-M")))
  check(sp("K3|A1") >= sp("K+6FT-M"), string.format(
    "%s: ...and on two fewer tanks still matches it (%.0f vs %.0f m/s)", n, sp("K3|A1"), sp("K+6FT-M")))
  check(sp("K4|A2") > 2 * math.max(sp("A+2FT-M"), sp("A+4FT-M"), sp("A+6FT-M"), sp("A4|A2"), 0), string.format(
    "%s: Skipper → Anvil beats anything Anvil-only (%.0f vs %.0f m/s)", n, sp("K4|A2"), sp("A+2FT-M")))
  check(sp("K4|A2") > sp("K4|S2") and sp("K4|A2") > 1.2 * sp("K4|K2"), string.format(
    "%s: the Anvil is the best upper stage (%.0f vs Sputter %.0f, Skipper %.0f m/s)",
    n, sp("K4|A2"), sp("K4|S2"), sp("K4|K2")))
end

if #failures > 0 then
  print("ENGINE NICHE SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("ENGINE NICHE SMOKE OK — %d worlds%s, sea level against vacuum, Skipper → Anvil is the way up",
  #WORLDS, deep and " (scale-3 and deep air)" or ""))
