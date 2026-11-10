-- DAMAGE — what a beam (later a blast or an impact) does to what it meets
-- (expansion X9; work/expansion/PLAN.md §4.1's damage table; docs/base-building.md §27).
--
-- PURE. No engine calls: tests/smoke_damage.lua loads it in luajit. The beam's
-- fluence and energy are beam.lua's; lasers.lua and laser_turret.lua apply
-- the amounts (vessel_controller.hitPart, the structure's hp, terrain.dig).
--
-- ── THE TABLE (incident fluence, J/m², that burns through) ─────────────────
--   craft part    tank 2e6 · structural 5e6 · pod 4e6 · engine 8e6 · shield block 5e7
--   kit piece     steel 5e6 · concrete 2e7 · glass 5e5 · regocrete 1e7
--   ground        a crater r = (E_abs / e_vol)^(1/3), e_vol = 3 GJ/m³ (rock melts)
--   crew          hurt F / 1e5 a second of exposure
--
-- THE PLAN'S RULE, with the floor it needs. The plan's amount is F / F_th
-- clamped to 1 (a 0.3 hit wears, ≥ 1 burns through). Fluence alone says a
-- 30 kW beam on a 2 cm spot burns through a concrete wall in a tenth of a
-- second, because fluence is per square metre and the spot is tiny: it has
-- melted a 2 cm hole, not the wall. So the amount is the plan's fluence ratio
-- times an ENERGY ratio, which is 1 for every pulse worth the name:
--
--   craft part   amount = min(1, F/F_part) · min(1, E_on / E_hole)
--                E_hole = F_part · A_HOLE (a 10 cm hole: a tank vents, an
--                engine's chamber fails, a pod loses its pressure)
--   kit piece    amount = min(1, F/F_mat) · min(1, E_on / E_cut)
--                E_cut  = e_vol(mat) · KERF · (V_mat / L): melting a 5 cm kerf
--                right through the piece's section (its material's volume
--                over its longest side). A steel sandwich wall is two 1.6 mm
--                skins: ~2.6 MJ. A concrete wall is 0.2 m of solid: ~60 MJ,
--                so one 10-bank pulse wears it to 8 % and a second fells it.
--   E_on         the energy that lands ON the target: E · min(1, A_target / A_spot)
--
-- ── THE CINEMATIC REGIME (beam.regime, c 0..1, continuous) ─────────────────
--   crater       e_vol falls from 3e9 toward 3e7 J/m³ (10^(−2c)): melting,
--                then explosive ejection (a TNT crater in rock is 1e7–4e7)
--   blast        TNT equivalent W = c · E_abs / 4.184e6 kg; pieces and parts
--                within r_b = 2 · W^(1/3) m take 1.5 · (1 − d/r_b) (capped)
--   c = 0        no blast term at all: the physics, unchanged
--
--   partClass(d)                    → "tank" | "engine" | "pod" | "shield" | "structural"
--   partAmount(F, Eon, cls)         → 0..1
--   pieceCut(mat, massT, L)         → J (E_cut)
--   pieceAmount(F, Eon, mat, massT, L) → 0..1
--   intercept(dSpot, area)          → share of the beam that lands on a target of `area` m²
--   crater(Eabs, c)                 → r (m)
--   craterEnergy(r, c)              → J for a crater of r
--   blast(Eabs, c)                  → W (kg TNT), r_b (m)
--   blastAmount(d, rb)              → 0..1
--   crewHurt(F, secs)               → hp
--   verdict(amount)                 → "BURN THROUGH" | "WEAR 0.30" | "NO EFFECT"
--   matOf(id)                       → the kit material from "<piece>.<mat>"
--   hpAfter(hp, amount)             → hp (old saves have none: 1.0)

F_PART = { tank = 2e6, structural = 5e6, pod = 4e6, engine = 8e6, shield = 5e7 }
F_MAT = { steel = 5e6, concrete = 2e7, glass = 5e5, regocrete = 1e7, graphite = 1e7, film = 1e4 }
-- J/m³ to melt (and blow out) the material: ρ × (heat to melt + latent)
E_VOL = { steel = 7.9e9, concrete = 3.0e9, glass = 3.75e9, regocrete = 2.6e9, graphite = 2.0e10, film = 1e8, rock = 3.0e9 }
RHO = { steel = 7850, concrete = 2300, glass = 2500, regocrete = 2000, graphite = 1700, film = 1200 }
A_HOLE = 0.01              -- m²: a 10 cm hole
KERF = 0.05                -- m: a cut's width (the spot and its melt zone)
CRATER_EV = 3.0e9          -- J/m³: rock melts (the plan)
CRATER_MIN = 1.0           -- m: smaller than this, the energy waits on the spot (lasers.lua accumulates it). The
                           -- engine's ground takes no dig under ~1 m (measured: a 0.5 m hard dig changes nothing,
                           -- 1 m carves), so a 0.27 m melt pit is a scorch mark, honestly, until 3 GJ have landed
TNT = 4.184e6              -- J/kg
BLAST_K = 2.0              -- r_b = 2 m · W^(1/3)
CREW_F = 1e5               -- J/m² a second of exposure per hp

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- the class of a craft part record (parts_registry: kind, fuel, shield)
function partClass(d)
  if type(d) ~= "table" then return "structural" end
  if d.shieldBlock or (d.id and tostring(d.id):find("^shield")) then return "shield" end
  if d.kind == "engine" then return "engine" end
  if d.kind == "crewed" or d.kind == "probe" then return "pod" end
  if d.kind == "tank" or (d.fuel or 0) > 0 then return "tank" end
  return "structural"
end

function partAmount(F, Eon, cls)
  local Fth = F_PART[cls or "structural"] or F_PART.structural
  local a = math.min(1, (F or 0) / Fth) * math.min(1, (Eon or 0) / (Fth * A_HOLE))
  return clamp(a, 0, 1)
end

-- the energy to cut a kit piece through (J): massT tonnes of `mat`, L its longest side (m)
function pieceCut(mat, massT, L)
  local ev = E_VOL[mat] or E_VOL.steel
  local rho = RHO[mat] or RHO.steel
  local V = math.max(1e-4, (massT or 0.1) * 1000 / rho)
  return ev * KERF * V / math.max(0.2, L or 1)
end
function pieceAmount(F, Eon, mat, massT, L)
  local Fth = F_MAT[mat] or F_MAT.steel
  local a = math.min(1, (F or 0) / Fth) * math.min(1, (Eon or 0) / pieceCut(mat, massT, L))
  return clamp(a, 0, 1)
end

-- the share of a spot of diameter d that lands on a target of `area` m²
function intercept(d, area)
  local A = math.pi * (d or 0.02) ^ 2 / 4
  if A <= 1e-12 then return 1 end
  return clamp((area or 1) / A, 0, 1)
end

local function ev_of(c) return CRATER_EV * 10 ^ (-2 * clamp(c or 0, 0, 1)) end
function crater(Eabs, c) return (math.max(0, Eabs or 0) / ev_of(c)) ^ (1 / 3) end
function craterEnergy(r, c) return ev_of(c) * (r or 0) ^ 3 end

function blast(Eabs, c)
  c = clamp(c or 0, 0, 1)
  if c <= 0 then return 0, 0 end
  local W = c * math.max(0, Eabs or 0) / TNT
  return W, BLAST_K * W ^ (1 / 3)
end
function blastAmount(d, rb)
  if not rb or rb <= 0 or d >= rb then return 0 end
  return clamp(1.5 * (1 - d / rb), 0, 1)
end

function crewHurt(F, secs) return (F or 0) / CREW_F * (secs or 1) end

function verdict(a)
  if (a or 0) >= 0.999 then return "BURN THROUGH" end
  if (a or 0) < 0.005 then return "NO EFFECT" end
  return string.format("WEAR %.2f", a)
end

function matOf(id)
  if type(id) ~= "string" then return nil end
  local _, m = id:match("^([%w]+)%.([%w]+)$")
  return m
end

function hpAfter(hp, amount) return math.max(0, (tonumber(hp) or 1.0) - math.max(0, amount or 0)) end
