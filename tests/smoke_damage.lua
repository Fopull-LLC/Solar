-- SMOKE: what a beam does (expansion X9; scripts/damage.lua; PLAN §4.1's table).
--
--   * the plan's table: each craft class burns through at its fluence, a 0.3
--     ratio wears 0.3; each kit material likewise;
--   * the energy floor: a CW pinhole does not fell a wall in a tick; a pulse
--     is the plan's rule exactly;
--   * a concrete wall is armour: one 10-bank pulse wears it, two fell it; a
--     steel sandwich wall goes in one;
--   * intercept: a spot wider than the target puts only its share on it;
--   * the crater: 60 MJ → 0.27 m, 1.2 GJ → 0.74 m (plan), and the regime's
--     explosive cratering; the blast is zero at c = 0;
--   * old saves: no hp is 1.0.
--
--   luajit solar/tests/smoke_damage.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) * math.max(1, math.abs(a), math.abs(b)) end
local function load(path)
  local E = setmetatable({ save = { get = function() end, set = function() end }, findScript = function() end, log = function() end },
                         { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  return E
end
local D = load("damage.lua")
local B = load("beam.lua")

-- ── 1. the table (a pulse: energy is never the limit) ───────────────────────
do
  for cls, Fth in pairs(D.F_PART) do
    check(D.partAmount(Fth, 1e9, cls) == 1, cls .. ": burns through at its fluence")
    check(near(D.partAmount(0.3 * Fth, 1e9, cls), 0.3), cls .. ": 0.3 of it wears 0.3")
    check(D.partAmount(10 * Fth, 1e9, cls) == 1, cls .. ": clamped to 1")
  end
  check(D.F_PART.tank == 2e6 and D.F_PART.structural == 5e6 and D.F_PART.pod == 4e6 and D.F_PART.engine == 8e6 and D.F_PART.shield == 5e7, "the plan's craft figures")
  check(D.F_MAT.steel == 5e6 and D.F_MAT.concrete == 2e7 and D.F_MAT.glass == 5e5 and D.F_MAT.regocrete == 1e7, "the plan's material figures")
  for mat, Fth in pairs({ steel = 5e6, concrete = 2e7, glass = 5e5, regocrete = 1e7 }) do
    check(D.pieceAmount(Fth, 1e12, mat, 1, 2) == 1, mat .. ": a piece burns through at its fluence")
    check(near(D.pieceAmount(0.3 * Fth, 1e12, mat, 1, 2), 0.3), mat .. ": 0.3 wears")
  end
  check(D.partClass({ kind = "engine" }) == "engine" and D.partClass({ kind = "crewed" }) == "pod" and D.partClass({ kind = "probe" }) == "pod", "classes: engine, pod")
  check(D.partClass({ kind = "structural", fuel = 120 }) == "tank" and D.partClass({ kind = "structural" }) == "structural", "a part with fuel is a tank")
  check(D.partClass({ id = "shieldBlock" }) == "shield", "a shield block")
end

-- ── 2. the energy floor ─────────────────────────────────────────────────────
do
  -- a 30 kW CW beam for one 0.1 s tick on a 2 cm spot: F = 9.5e6 J/m², E 3 kJ
  local E = 30e3 * 0.1
  local F = B.fluence(E, 0.02)
  check(F > D.F_MAT.concrete * 0.4, string.format("the CW tick's fluence is high: %.3g", F))
  local cw = D.pieceAmount(F, E, "concrete", 2.02, 2.2)
  check(cw < 1e-3, string.format("but it melts a pinhole, not the wall: %.5f a tick", cw))
  local steel = D.pieceAmount(F, E, "steel", 0.11, 2.2)
  check(steel > 1e-3 and steel < 0.01, string.format("a steel sandwich wall: %.4f a tick (%.0f s of CW)", steel, 0.1 / steel))
  local tank = D.partAmount(F, E, "tank")
  check(tank > 0.1 and tank < 0.2, string.format("a tank under CW: %.3f a tick (vents in under a second)", tank))
  check(near(D.pieceCut("concrete", 2.02, 2.2), 3e9 * 0.05 * (2020 / 2300) / 2.2, 1e-6), "E_cut = e_vol · kerf · V / L")
  check(near(D.pieceCut("concrete", 2.02, 2.2) / 1e6, 60.2, 0.01), string.format("a concrete wall: %.1f MJ to cut", D.pieceCut("concrete", 2.02, 2.2) / 1e6))
  check(near(D.pieceCut("steel", 0.11, 2.2) / 1e6, 2.52, 0.02), string.format("a steel wall: %.2f MJ", D.pieceCut("steel", 0.11, 2.2) / 1e6))
end

-- ── 3. walls as armour ──────────────────────────────────────────────────────
do
  local E10 = B.pulseEnergy({ emitter = 10 * 20e6 })
  local F = B.fluence(E10, 0.02)
  local a = D.pieceAmount(F, E10, "concrete", 2.02, 2.2)
  local hp = D.hpAfter(nil, a)
  check(hp > 0.05 and hp < 0.15, string.format("a 10-bank pulse wears a concrete wall to %.2f", hp))
  check(D.hpAfter(hp, a) == 0, "the second fells it")
  check(D.pieceAmount(F, E10, "steel", 0.11, 2.2) == 1, "a steel wall goes in one")
  local E2 = B.pulseEnergy({ emitter = 2 * 20e6 })
  check(D.pieceAmount(B.fluence(E2, 0.02), E2, "steel", 0.11, 2.2) == 1, string.format("two banks (%.1f MJ) are enough for steel", E2 / 1e6))
  check(D.pieceAmount(B.fluence(E2, 0.02), E2, "concrete", 2.02, 2.2) < 0.25, "but not for concrete")
end

-- ── 4. intercept ────────────────────────────────────────────────────────────
do
  check(D.intercept(0.02, 1) == 1, "a 2 cm spot lands whole on a 1 m² target")
  check(near(D.intercept(4, 2), 2 / (math.pi * 4)), "a 4 m spot on 2 m²: its share")
  -- wear at range: a spot wide enough that F = 0.3 F_tank
  local E = 11e6
  local d = math.sqrt(4 * E / (math.pi * 0.3 * D.F_PART.tank))
  local F = B.fluence(E, d)
  local Eon = E * D.intercept(d, 1.9)
  check(near(D.partAmount(F, Eon, "tank"), 0.3, 1e-6), string.format("a %.1f m spot on a tank wears it 0.3", d))
end

-- ── 5. ground and the regime ────────────────────────────────────────────────
do
  check(near(D.crater(60e6, 0), 0.271, 2e-3), string.format("60 MJ: a %.3f m crater (plan 0.27)", D.crater(60e6, 0)))
  check(near(D.crater(1.2e9, 0), 0.737, 2e-3), string.format("1.2 GJ: %.3f m (plan 0.74)", D.crater(1.2e9, 0)))
  check(near(D.craterEnergy(D.crater(5e7, 0), 0), 5e7), "craterEnergy inverts crater")
  check(near(D.crater(1e9, 1) / D.crater(1e9, 0), 100 ^ (1 / 3), 1e-6), "at c = 1 the ground goes at explosive efficiency (×4.6 the radius)")
  local W, rb = D.blast(1e9, 0)
  check(W == 0 and rb == 0, "c = 0: no blast at all")
  local W1, rb1 = D.blast(4.184e9, 1)
  check(near(W1, 1000) and near(rb1, 20), string.format("c = 1, 4.2 GJ: %.0f kg TNT, r_b %.1f m", W1, rb1))
  check(D.blastAmount(0, 20) == 1 and near(D.blastAmount(10, 20), 0.75) and D.blastAmount(20, 20) == 0, "blast falloff")
  local c1, c2 = D.crater(1e9, 0.2), D.crater(1e9, 0.21)
  check(c2 > c1 and c2 - c1 < 0.05, "the crater grows smoothly with c")
end

-- ── 6. the rest ─────────────────────────────────────────────────────────────
do
  check(D.hpAfter(nil, 0.25) == 0.75, "an old save's piece (no hp) is at 1.0")
  check(D.hpAfter(0.1, 0.5) == 0, "hp floors at 0")
  check(D.verdict(1) == "BURN THROUGH" and D.verdict(0.3) == "WEAR 0.30" and D.verdict(0) == "NO EFFECT", "the fire-control verdicts")
  check(D.matOf("wall.concrete") == "concrete" and D.matOf("shed") == nil, "the material from a kit id")
  check(near(D.crewHurt(1e5, 1), 1), "crew: F / 1e5 a second")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_damage: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_damage: %d passed", passed))
