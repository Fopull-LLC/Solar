-- BEAM — the physics of a laser built from parts (expansion X9, "Energy
-- weapons I"; work/expansion/PLAN.md §4.1; docs/base-building.md §27).
--
-- PURE. No engine calls: it loads in a luajit test (tests/smoke_beam.lua).
-- The scene half is scripts/lasers.lua (the kit laser on a base grid) and
-- scripts/laser_turret.lua (the craft-mounted turret); what a beam does to
-- what it hits is scripts/damage.lua's.
--
-- ── THE CHAIN ───────────────────────────────────────────────────────────────
-- A laser is pieces joined by their ports (the S6 port rule: two ports meet
-- within 6 cm, facing): Capacitor Banks and Pulse Bus bars make a PULSE
-- GROUP; the beam runs Emitter → (Amplifier Stage | Lens Group)* → Beam
-- Director. Each emitter and each stage dumps its OWN group (shared evenly
-- when one group feeds several of them):
--
--     E_pulse = BUS_EFF · ( EMIT_EFF · ΣE_emitter's group + AMP_EFF · Σ ΣE_stage's group )
--
-- 1 EC = 1 kJ (base_power.lua): a 20 MJ bank is 20,000 EC. A 10-bank bus on
-- an emitter alone gives 0.92 × 0.30 × 200 MJ = 55 MJ ("60 MJ" in the plan's
-- rounding); the rest is waste heat in the emitter's coolant loop.
--
-- ── THE BEAM (λ = 1.06 µm, a diode-pumped Nd slab) ──────────────────────────
--   divergence   θ = 2.44 λ / D + jitter; jitter = the director's own (1 µrad
--                for the 0.5 m director, 0.05 µrad for X11's large one) plus
--                0.4 µrad a stage, divided by the beam expander's
--                magnification D / 0.5 m (an angle inside the train shrinks
--                by the expander's power: real optics, and the reason
--                magnification matters)
--   focus        the director focuses at the target's range up to its reach
--                (5 km; a Lens Group takes it to 50,000 km, or holds a set
--                range): off focus the geometric blur D·|1 − R/f| adds to
--                the diffraction spot in quadrature
--   spot         d = max(SPOT_MIN, √((R θ)² + (D (1 − R/f))²))
--   fluence      F = E / (π d² / 4)
--   air          T = exp(−∫ σ dl), σ = SIGMA0 · ρ / ρ0 (clear air at 1 µm,
--                ~0.1 /km at sea level); a CW beam over 10 kW in thick air
--                blooms: half again
--   occlusion    a segment-sphere test against every body of one
--                space.bodies() read
--
-- ── THE CINEMATIC REGIME (Ty 11-09, binding: continuous and earned) ─────────
-- Normal builds follow the physics above, all the way. Only an extreme build
-- crosses into an explosively destructive regime, and it does so smoothly:
--
--     c = s(xE) · s(xF) · kAmp · kMag          (s = smoothstep, all 0..1)
--     xE = (log10 E − 8.5) / 2      316 MJ → 0, 31.6 GJ → 1   (huge energy)
--     xF = (log10 F − 9) / 2        1e9 → 0, 1e11 J/m² → 1    (on a small spot)
--     kAmp = (1 + stages) / 7       none 1/7, six stages 1    (heavy amplification)
--     kMag = clamp(log2(D / 0.25) / 5, 0.2, 1)  0.5 m 0.2, 2 m 0.6, 8 m 1  (magnification)
--
-- c is 0 for every laser a player builds early; a 10-bank laser is 0 to five
-- places. damage.lua reads c: the absorbed energy couples into a blast
-- (laser-supported detonation: TNT equivalent c · E / 4.184 MJ) and the
-- ground is cratered at explosive efficiency (3 GJ/m³ melting → 30 MJ/m³ at
-- c = 1). Every step between is a build you can make: more banks, another
-- stage, a bigger director.
--
--   divergence(D, stages, jit)          → θ (rad)
--   spotAt(R, D, theta, focus)          → d (m)
--   focusFor(R, reach, fixed)           → f (m): where the optics focus
--   fluence(E, d)                       → J/m²
--   airTransmission(R, rhoMean, cw, kw) → T
--   rhoAlong(ax,ay,az, bx,by,bz, cx,cy,cz, radius, rhoAt, n) → mean ρ on the path
--   occluded(ax,ay,az, bx,by,bz, bodies, skip) → name | nil
--   pulseEnergy(chain)                  → E (J), wall (J drawn), heat (J)
--   cooldown(Emj, rate)                 → s
--   regime(E, F, stages, D)             → c 0..1
--   layout(pieces)                      → weapons (the chain and the groups)
--   predict(E, R, D, theta, focus, T)   → { d, F, Eon… } the fire-control readout

LAMBDA = 1.06e-6
SPOT_MIN = 0.02            -- m: the smallest spot a real train holds (thermal lensing, the mirror's figure)
BUS_EFF = 0.92             -- a pulse bus delivers this share of its banks' charge
EMIT_EFF = 0.30            -- a diode-pumped slab's wall-plug efficiency
AMP_EFF = 0.45             -- an amplifier stage adds this share of its own group's charge
MAX_STAGES = 6
JIT_DIR = 1.0e-6           -- rad: the 0.5 m director's pointing jitter
JIT_LARGE = 0.05e-6        -- rad: X11's large director (Hubble-class stabilisation)
JIT_STAGE = 0.4e-6         -- rad a stage, inside the train
D_REF = 0.5                -- m: the train's own beam, which the expander magnifies
SIGMA0 = 1.0e-4            -- /m: extinction at sea-level density for 1.06 µm
RHO0 = 1.225               -- kg/m³
BLOOM_KW = 10              -- a CW beam above this blooms in thick air
BLOOM_RHO = 0.3            -- kg/m³ (mean along the path) counts as thick
REACH_DIR = 5000           -- m: how far the director focuses by itself
REACH_LENS = 5.0e7         -- m: a Lens Group's (50,000 km)
FOCUS_MIN = 20             -- m
CD_BASE, CD_PER_MJ = 3.0, 0.1   -- s: cooldown after a pulse, at full cooling
RATE_MIN = 0.4             -- no coolant: the emitter cycles at 40 % of its rate

local log10 = function(x) return math.log(x) / math.log(10) end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function smooth(x) x = clamp(x, 0, 1); return x * x * (3 - 2 * x) end

-- ── the beam ────────────────────────────────────────────────────────────────
-- jit = the director's own jitter (JIT_DIR or JIT_LARGE)
function divergence(D, stages, jit)
  D = math.max(1e-3, D or D_REF)
  local j = (jit or JIT_DIR) + math.min(stages or 0, MAX_STAGES) * JIT_STAGE * (D_REF / D)
  return 2.44 * LAMBDA / D + j
end
-- the diffraction term alone (the plan's worked figures use it)
function diffraction(D) return 2.44 * LAMBDA / math.max(1e-3, D) end

-- where the optics focus for a target at range R: by itself the director
-- focuses up to its reach; `fixed` (a Lens Group's set range) holds there
function focusFor(R, reach, fixed)
  if fixed and fixed > 0 then return math.max(FOCUS_MIN, fixed) end
  return clamp(R or FOCUS_MIN, FOCUS_MIN, reach or REACH_DIR)
end

function spotAt(R, D, theta, focus)
  R = math.max(0, R or 0)
  local diff = R * (theta or divergence(D, 0))
  local blur = 0
  if focus and focus > 0 then blur = (D or D_REF) * math.abs(1 - R / focus) end
  return math.max(SPOT_MIN, math.sqrt(diff * diff + blur * blur))
end

function fluence(E, d)
  d = math.max(1e-6, d or SPOT_MIN)
  return (E or 0) / (math.pi * d * d / 4)
end

-- T over a path of R metres whose mean air density is rhoMean; a CW beam of
-- `kw` kW in thick air blooms (half again)
function airTransmission(R, rhoMean, cw, kw)
  local sigma = SIGMA0 * math.max(0, rhoMean or 0) / RHO0
  local T = math.exp(-sigma * math.max(0, R or 0))
  if cw and (kw or 0) > BLOOM_KW and (rhoMean or 0) > BLOOM_RHO then T = T * 0.5 end
  return T
end

-- The mean air density along a → b over a world centred at c of radius
-- `radius`; rhoAt(alt) gives the density at altitude alt (m). n samples.
function rhoAlong(ax, ay, az, bx, by, bz, cx, cy, cz, radius, rhoAt, n)
  if not rhoAt then return 0 end
  n = n or 8
  local s = 0
  for i = 0, n - 1 do
    local t = (i + 0.5) / n
    local x, y, z = ax + (bx - ax) * t - cx, ay + (by - ay) * t - cy, az + (bz - az) * t - cz
    s = s + (rhoAt(math.sqrt(x * x + y * y + z * z) - (radius or 0)) or 0)
  end
  return s / n
end

-- Does the segment a → b pass through a body? bodies = one space.bodies()
-- read ({ name, x,y,z, radius }); `skip` = a name never counted (the world
-- the target stands on, whose ground the ray itself meets). `margin` shrinks
-- each sphere (m) so a point on the surface is not inside it. → name | nil
function occluded(ax, ay, az, bx, by, bz, bodies, skip, margin)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local L2 = dx * dx + dy * dy + dz * dz
  if L2 < 1e-12 then return nil end
  for _, b in ipairs(bodies or {}) do
    if b.name ~= skip and (b.radius or 0) > 0 then
      local r = b.radius - (margin or 0)
      local t = ((b.x - ax) * dx + (b.y - ay) * dy + (b.z - az) * dz) / L2
      t = clamp(t, 0, 1)
      local px, py, pz = ax + dx * t - b.x, ay + dy * t - b.y, az + dz * t - b.z
      -- (the ends themselves inside a sphere are a start or a target ON it: not a wall)
      if t > 1e-6 and t < 1 - 1e-6 and px * px + py * py + pz * pz < r * r then return b.name end
    end
  end
  return nil
end

-- ── the pulse ───────────────────────────────────────────────────────────────
-- chain = { emitter = J (its share of its group's charge), stages = { J, … } }
-- → E (J into the beam), wall (J taken from the banks), heat (J into the coolant)
function pulseEnergy(chain)
  if not chain then return 0, 0, 0 end
  local ein = math.max(0, chain.emitter or 0)
  local E = BUS_EFF * EMIT_EFF * ein
  local wall = ein
  local n = 0
  for _, s in ipairs(chain.stages or {}) do
    n = n + 1
    if n > MAX_STAGES then break end
    E = E + BUS_EFF * AMP_EFF * math.max(0, s)
    wall = wall + math.max(0, s)
  end
  return E, wall, math.max(0, wall - E)
end

-- seconds before it can fire again; rate = its cooling share (0..1)
function cooldown(Emj, rate)
  return (CD_BASE + CD_PER_MJ * math.max(0, Emj or 0)) / math.max(RATE_MIN, math.min(1, rate or 1))
end

-- the cinematic regime, 0..1 (see the head)
function regimeParts(E, F, stages, D)
  local xe = ((E or 0) > 0) and (log10(E) - 8.5) / 2 or 0
  local xf = ((F or 0) > 0) and (log10(F) - 9) / 2 or 0
  local kAmp = (1 + clamp(stages or 0, 0, MAX_STAGES)) / (1 + MAX_STAGES)
  local kMag = clamp(math.log(math.max(1e-3, D or D_REF) / 0.25) / math.log(2) / 5, 0.2, 1)
  return smooth(xe), smooth(xf), kAmp, kMag
end
function regime(E, F, stages, D)
  local a, b, c, d = regimeParts(E, F, stages, D)
  return a * b * c * d
end

-- The fire-control readout at range R (no target size): spot, fluence on
-- arrival, the energy that arrives. T = the air's transmission.
function predict(E, R, D, theta, focus, T, stages)
  local d = spotAt(R, D, theta, focus)
  local Eon = (E or 0) * (T or 1)
  local F = fluence(Eon, d)
  return { d = d, F = F, E = Eon, T = T or 1, c = regime(Eon, F, stages, D) }
end

-- ── the layout: pieces → weapons ────────────────────────────────────────────
-- pieces = { { key, kind = "cap"|"bus"|"emitter"|"amp"|"lens"|"director"|…,
--   ports = { { x, y, z, nx, nz, pulse = bool, beam = "in"|"out" } } (in the
--   structure's frame, already turned by the piece's yaw), cap (J, a bank's),
--   D, jit, reach (a director's) } }
-- → weapons = { { director = key, emitter = key, stages = { key… }, lenses =
--   { key… }, path = { key… }, why } }, groups = { [key] = gid },
--   members = { [gid] = { banks = { key… }, devs = { key… } } }
local function meet(A, B)
  return math.abs(A.x - B.x) < 0.06 and math.abs(A.y - B.y) < 0.06 and math.abs(A.z - B.z) < 0.06
         and ((A.nx or 0) * (B.nx or 0) + (A.nz or 0) * (B.nz or 0)) < -0.9
end
function layout(pieces)
  local byKey = {}
  for _, p in ipairs(pieces or {}) do byKey[p.key] = p end
  -- the pulse groups: a union over the pulse ports
  local U = {}
  local function find(a) while U[a] ~= a do U[a] = U[U[a]]; a = U[a] end return a end
  local pp = {}
  for i, p in ipairs(pieces or {}) do
    U[i] = i
    for _, pt in ipairs(p.ports or {}) do if pt.pulse then pp[#pp + 1] = { i = i, pt = pt } end end
  end
  for a = 1, #pp do
    for b = a + 1, #pp do
      if pp[a].i ~= pp[b].i and meet(pp[a].pt, pp[b].pt) then
        local ra, rb = find(pp[a].i), find(pp[b].i)
        if ra ~= rb then U[rb] = ra end
      end
    end
  end
  local groups, members = {}, {}
  for i, p in ipairs(pieces or {}) do
    local has = false
    for _, pt in ipairs(p.ports or {}) do if pt.pulse then has = true end end
    if has then
      local g = find(i)
      groups[p.key] = g
      local m = members[g] or { banks = {}, devs = {} }
      members[g] = m
      if p.kind == "cap" then m.banks[#m.banks + 1] = p.key
      elseif p.kind == "emitter" or p.kind == "amp" then m.devs[#m.devs + 1] = p.key end
    end
  end
  -- the beam path: each emitter's out port, piece to piece through their in ports
  local ins = {}
  for _, p in ipairs(pieces or {}) do
    for _, pt in ipairs(p.ports or {}) do if pt.beam == "in" then ins[#ins + 1] = { p = p, pt = pt } end end
  end
  local weapons = {}
  for _, p in ipairs(pieces or {}) do
    if p.kind == "emitter" then
      local W = { emitter = p.key, stages = {}, lenses = {}, path = { p.key } }
      local cur, seen, steps = p, { [p.key] = true }, 0
      while cur and steps < 20 do
        steps = steps + 1
        local out = nil
        for _, pt in ipairs(cur.ports or {}) do if pt.beam == "out" then out = pt end end
        if not out then break end
        local nxt = nil
        for _, e in ipairs(ins) do if not seen[e.p.key] and meet(out, e.pt) then nxt = e.p end end
        if not nxt then
          W.why = W.why or (cur == p and "nothing on the emitter's beam port: an Amplifier Stage, a Lens Group or a Beam Director"
                            or "the beam leaves the chain into the open: end it on a Beam Director")
          break
        end
        seen[nxt.key] = true
        W.path[#W.path + 1] = nxt.key
        if nxt.kind == "amp" then
          if #W.stages < MAX_STAGES then W.stages[#W.stages + 1] = nxt.key
          else W.why = string.format("more than %d amplifier stages: the extra ones pass the beam unpumped", MAX_STAGES) end
        elseif nxt.kind == "lens" then W.lenses[#W.lenses + 1] = nxt.key
        elseif nxt.kind == "director" then W.director = nxt.key; W.why = nil; break
        else W.why = "something in the beam that is not optics"; break end
        cur = nxt
      end
      if W.director then
        if not groups[p.key] or #members[groups[p.key]].banks == 0 then W.why = "no Capacitor Bank on the emitter's pulse port (lay a Pulse Bus to the banks)" end
      elseif not W.why then W.why = "nothing on the emitter's beam port: an Amplifier Stage, a Lens Group or a Beam Director" end
      weapons[#weapons + 1] = W
    end
  end
  return weapons, groups, members, byKey
end

-- The charge a device takes from its group when it dumps: its even share.
-- groupJ = Σ the group's banks; ndev = the devices on it.
function shareOf(groupJ, ndev) return (groupJ or 0) / math.max(1, ndev or 1) end
