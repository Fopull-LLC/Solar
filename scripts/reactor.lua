-- REACTOR — the rulebook of a reactor BUILT FROM COMPONENTS (sandbox plan S6,
-- work/sandbox/PLAN.md §3.1, §3.6; docs/heat-and-nuclear.md §8). Ty, 11-06:
-- reactors at FULL depth from the start: enrichment, burnup and xenon.
--
-- Pure, like thermal.lua: no scene access, its globals are its API, it loads
-- from disk in a luajit test (tests/smoke_reactor.lua). reactor_plant.lua
-- (the scene half) finds the plants in the structures' records, steps them on
-- its clock and couples them to the base grid.
--
-- ── THE LAYOUT (`layout(rec, defs)`) ─────────────────────────────────────────
-- A Reactor Vessel Base carries a 5 × 5 lattice of 0.5 m cells. Columns stand
-- on it (and on each other: a second storey of columns makes the core taller):
-- fuel channels, moderator (graphite, light water, heavy water) and control
-- rods. What stands NEXT TO WHAT is the neutronics:
--   moderation   each moderator column shares its atoms among the fuel
--                channels beside it (light water only within a slowing-down
--                skin of the face it shares: its neutrons slow in 5 cm);
--                each channel's own coolant water moderates a little
--   reflector    a moderator column that touches no fuel but the core region
--                sends neutrons back: it pushes the core's edge out
--   rods         a rod is worth its fuel faces
--   size         the core region's plan and its storeys give the buckling
-- Pipes and components join by their PORTS (parts_kit): coincident nozzles
-- facing each other. The port graph's sets are the loops: the PRIMARY holds
-- the vessel, its pumps, the pressuriser, the steam generator's primary side
-- and its pipes; each steam generator's secondary side starts a SECONDARY with
-- its pumps, the turbine and the heat sinks (radiators, cooling towers).
-- (S7's fluid network takes this graph over: the ports are its nodes.)
--
-- ── THE NEUTRONICS (one homogenised core, real cross sections) ──────────────
--   k∞  = ε · p · νΣf / Σa          (four factors with the fuel's real data)
--         p = exp(−N₂₃₈ · I(T_f) / ξΣs)   resonance escape; I grows with √T_f
--                                         (Doppler: the fuel's own feedback)
--         Σa = fuel + moderator + coolant + structure + Xe + Sm + fission
--              products + control rods
--   k   = k∞ / (1 + B²M²)            leakage; M² = τ + L²(1 − f) of the mix
--   ρ   = 1 − 1/k
-- Light and heavy water lose density as they heat (ρ_w(T)): an under-
-- moderated core (the usual one) loses k as it warms: the moderator's feedback.
--
-- ── THE KINETICS (point kinetics, two delayed groups, the prompt jump) ──────
--   P   = β (g₁y₁ + g₂y₂ + σ) / (β − ρ)       (the prompt jump: no prompt term
--   dyᵢ/dt = λᵢ (P − yᵢ)                       to integrate, so no 10⁻⁴ s steps)
-- P is the fission power over the rating (1 = 100 %); yᵢ are the precursors in
-- power units (yᵢ = P at steady state). σ is the start-up source. ρ ≥ β (prompt
-- critical) is an EVENT: a Nordheim–Fuchs burst heats the fuel until the
-- Doppler takes it back, and anything over the melting point is damage.
--
-- ── POISONS, BURNUP, DECAY HEAT (real decay constants and yields) ───────────
--   I-135 → Xe-135 (6.6 h, 9.1 h; σ_Xe 2.65 Mb): the post-shutdown PIT
--   Pm-149 → Sm-149 (53 h; σ_Sm 41 kb): it builds after a shutdown and stays
--   each rod's U-235, Pu-239 and fission products as closed forms of its
--   fluence (σ_a5 Φ …): it burns down over months at a high-flux core's flux
--   decay heat: seven exponentials fitted to Way–Wigner (8 % just after a
--   SCRAM, 1.4 % at 17 min, 0.8 % at 3 h, 0.2 % at 12 days)
-- GAME SCALE (documented): a core's thermal rating is a few hundred kW (a
-- fuel channel is rated 40 kW) so a base's turbine makes tens of kW, while
-- its FLUX is a high-flux core's (φ = 7·10¹³ at the rating): xenon, samarium
-- and burnup run on their real clocks (hours, days, months).
--
-- ── THE HEAT (thermal.lua's network, real temperatures) ─────────────────────
--   fuel ─UA(ṁ)→ primary ─ε·ṁc→ steam generator ┄ secondary ─G→ turbine →
--   condenser ─εσT⁴ / G_tower→ the world;  pipes leak UL·(T − T_amb)
--   ε = 1 − exp(−UA/ṁc) (the secondary boils);  the turbine makes
--   η · (1 − T_k / T_s) of the heat it admits (η its share of Carnot)
-- Loss of flow: the pumps coast down (5 s), the fuel's film falls to natural
-- circulation's; past the pressuriser's boiling point the primary boils off,
-- and an uncovered core heats on its decay heat until it is damaged.
--
-- ── WARP-PROOF (E's rule) ───────────────────────────────────────────────────
-- The kinetics with feedback are stiff and nonlinear, so `advance` takes an
-- L-stable Rosenbrock step (Shampine's ode23s: one Jacobian and one LU a
-- step, an embedded error estimate) with step-size control, events found
-- inside the step (the trip's own instant, by secant on the event function),
-- and steps of at most HMAX (an hour: burnup is folded in between steps, by
-- its closed form). One long call and many short ones land within the error
-- control's tolerance of each other (the smoke checks it), and a load catches
-- a plant up the same way, bounded at MAXSTEPS a call (the rest carries over).

RX = {
  -- constants
  NA = 6.02214e23,
  rod_kgU = 26.4,          -- kg of U in a 40 kg rod (30 kg of UO2 in its cladding)
  rods_full = 8,           -- a fuel channel's slots
  channel_kw = 40,         -- kW(th) a full channel is rated
  phi_ref = 7e13,          -- n/cm²/s at the rating (a high-flux core)
  -- the fuel (b)
  nu5 = 2.43, sf5 = 585, sa5 = 681, beta5 = 0.0065,
  nu9 = 2.87, sf9 = 742, sa9 = 1011, beta9 = 0.0021,
  sa8 = 2.68, sc8 = 10.0,  -- U-238 thermal absorption; its effective capture to Pu (resonances in)
  sfp = 40,                -- b of slow fission products per fission
  eps = 1.03,              -- fast fission
  I0 = 32, betaD = 0.011,  -- U-238's effective resonance integral (b) at 300 K and its √T growth
  -- poisons
  sX = 2.65e6, sSm = 4.1e4,
  gI = 0.0639, gX = 0.00237, gPm = 0.0113,
  lI = 2.931e-5, lX = 2.106e-5, lPm = 3.63e-6,
  -- kinetics: two delayed groups (the six collapsed: 1/λ_eff = 13 s)
  g1 = 0.252, l1 = 0.0256, g2 = 0.748, l2 = 0.234,
  src = 1e-8,              -- the start-up source, in power units
  -- decay heat (Way–Wigner, seven groups): shares of the rating and rates
  aD = { 0.03107, 0.01941, 0.01304, 0.00677, 0.00664, 0.00065, 0.00481 },
  lD = { 1.0, 0.1, 1e-2, 1e-3, 1e-4, 1e-5, 1e-6 },
  -- the heat
  cp_p = 5000,             -- J/(kg·K), pressurised water
  cp_s = 4500,
  hfg = 1.2e6,             -- J/kg: what boils the primary off
  dTfc = 350,              -- K fuel over coolant at the rating, full flow
  tau_f = 6.0,             -- s: the fuel's own time constant
  nc = 0.04,               -- natural circulation, a share of the design flow at 40 K
  tau_pump = 5.0,          -- s: coast-down and spin-up
  sigma = 5.670374e-8,
  h_air = 6.0,             -- W/(m²·K): a radiator panel's convection in 1 atm of air
  G_sec = 4186 * 4,        -- W/K per kg/s: the secondary's steam transport
  dT_turb = 230,           -- K: a turbine's design steam-to-condenser drop
  T_steam = 540,           -- K: the steam the turbine's valve holds (6 MPa saturated)
  -- the rods: a bank, 0 withdrawn … 1 in
  W_rod = 15.0,            -- b per U atom of a full channel, per fuel face, fully in
  v_rod = 1 / 90,          -- per s, the drives (a full stroke in 90 s)
  v_auto = 1 / 240,        -- per s, the automatic controller
  v_scram = 1 / 2.0,       -- per s, dropped
  -- the protection (trips)
  trip_P = 1.18,           -- 118 % power
  trip_period = 10,        -- s
  trip_Tf = 1250,          -- K
  trip_sub = 12,           -- K below the boiling point
  trip_flow = 0.70,        -- share of the design flow, at power
  prompt = 0.985,          -- of β: the prompt jump stops holding
  T_damage = 1300,         -- K the cladding starts to fail
  -- the integrator
  rtol = 2e-5, HMAX = 3600, HMIN = 1e-4, MAXSTEPS = 4000,
  catch_max = 30 * 86400,
}

-- The moderators (per column of 0.6 m³: atoms or molecules, ξσs and σa in b,
-- τ and L² in m²; skin = the share of a column a fuel face sees).
MOD = {
  graphite = { label = "graphite", N = 5.11e28, xs = 0.743, sa = 0.0045, tau = 0.0368, L2 = 0.25, skin = 1.0, refl = 0.5, water = false },
  water    = { label = "light water", N = 1.84e28, xs = 41.0, sa = 0.664, tau = 0.0027, L2 = 0.00081, skin = 0.06, refl = 0.08, water = true },
  heavy    = { label = "heavy water", N = 1.83e28, xs = 5.5, sa = 0.003, tau = 0.0131, L2 = 0.3, skin = 1.0, refl = 0.5, water = true },
}
COOL = { x = 0.5, xs = 41.0, sa = 0.664, tau = 0.0027, L2 = 0.00081 }   -- a channel's coolant: H2O per U atom of a full channel
A_STRUCT = 0.25        -- b per U atom of a full channel: the tubes and the grid
MOD_WARM = 0.3         -- a moderator tank runs this share of the way from the room to the coolant
-- GAME SCALE of the heat: the pieces are 1:1, the power is a few hundred kW,
-- and the plant's THERMAL INERTIA and LOSSES are its rating's, as a full-size
-- plant's are to its own (a primary heats in 4.4 min of full power from cold,
-- boils dry on 100 s of it; a station blackout runs its real course of hours)
CAP = { pri = 1.0, sec = 0.6, cond = 0.6 }   -- J/K per W of rating (a PWR's primary is ~0.8)
BOIL_S = 100           -- s of rated power that boils the primary's water off (TMI's: ~107)
SHELL_LOSS = 0.0003    -- share of the rating the lagged vessels lose, at the design ΔT
LAGGED_LOSS = 0.00004  -- a lagged metre of pipe (bare: the piece's own, 0.25 %)
DT_DESIGN = 265        -- K: the primary over the room at the design temperature
-- (S7) the primary's water (m³ of each part) at its hot density, and a break
WATER_HOT = 740        -- kg/m³ at 556 K, 15.5 MPa
PIPE_A = 0.00745       -- m²: DN100 schedule 80's bore (97.2 mm)
PLENUM_V, CHANNEL_V, SG_V, PRESS_V, PUMP_V = 0.6, 0.019, 0.35, 1.0, 0.05
GC_HOT = 1.0e4         -- kg/(m²·s): critical two-phase flow out of a break, flashing
GC_COLD = 2.5e3        -- …and the drain once the water is under 100 °C
BREAK_DEP = 1.0e-4     -- m²: a break this big loses the pressuriser (a small one it rides out)
BREAK_FLOOR = 0.15     -- the share of the water below the loop's pipes (the vessel base's lower plenum, under its
                       -- nozzles): a break at pipe height drains everything above it, the core included
HFG_REAL = 2.26e6      -- J/kg at 1 atm: once broken, what boils off is real water
-- The rods the press and the Depot make: the U-235 share of their uranium.
RODS = { fuelRodNU = 0.0072, fuelRod = 0.03, fuelRodHALEU = 0.1975 }
ROD_LABEL = { fuelRodNU = "natural U", fuelRod = "LEU 3 %", fuelRodHALEU = "HALEU 19.75 %" }

local NA = RX.NA
local function atoms_rod() return RX.rod_kgU * 1000 / 238.03 * NA end
local U_ROD = atoms_rod()
local U_FULL = U_ROD * RX.rods_full
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function softplus(x) if x > 30 then return x end if x < -30 then return 0 end return math.log(1 + math.exp(x)) end
local function smooth01(x) x = clamp(x, 0, 1); return x * x * (3 - 2 * x) end
function rodAtoms() return U_ROD end
function fullAtoms() return U_FULL end

-- light (and heavy) water's density over its room-temperature density at T (K),
-- compressed liquid at 15 MPa (0.74 at 300 °C)
function waterDensity(T) return clamp(1 - 3.0e-6 * (T - 277) ^ 2, 0.5, 1.0) end
-- a rod bank's integral worth at insertion x (an S curve: worth most mid-core)
function rodWorth(x) x = clamp(x, 0, 1); return x - math.sin(2 * math.pi * x) / (2 * math.pi) end

-- ── a fuel rod's composition and its burnup (closed form in its fluence) ────
-- rod = { id (item), e0, e (U-235 per U atom), p9 (Pu-239), fp (fissions per
-- U atom so far), phi (n/cm²) }
function newRod(item)
  local e = RODS[item or "fuelRod"] or RODS.fuelRod
  return { id = item or "fuelRod", e0 = e, e = e, p9 = 0, fp = 0, phi = 0 }
end
-- Burn a rod through dPhi (n/cm²): U-235 by its absorption, Pu-239 bred from
-- U-238 toward its balance and burnt, fissions counted. Exact for any dPhi
-- (the U-238 left changes by a few % over a whole life: held at the step's).
function burnRod(r, dPhi)
  if dPhi <= 0 then return r end
  local u = dPhi * 1e-24
  local e, p = r.e, r.p9
  local n8 = math.max(0, 1 - e - p - r.fp)
  local x5 = math.exp(-RX.sa5 * u)
  local x9 = math.exp(-RX.sa9 * u)
  local peq = RX.sc8 * n8 / RX.sa9
  local e1 = e * x5
  local p1 = peq + (p - peq) * x9
  local f5 = RX.sf5 * e * (1 - x5) / RX.sa5
  local f9 = RX.sf9 * (peq * u + (p - peq) * (1 - x9) / RX.sa9)
  r.e, r.p9, r.fp, r.phi = e1, p1, r.fp + f5 + f9, (r.phi or 0) + dPhi
  return r
end
-- A rod's burnup as FIMA (fissions per initial heavy atom).
function fima(r) return r.fp or 0 end
-- Is it spent? (its own reactivity worth gone: less fissile than 40 % of what it began with)
function rodSpent(r) return (r.e + 0.75 * r.p9) < 0.4 * (r.e0 or r.e) end

-- ── THE LAYOUT ──────────────────────────────────────────────────────────────
PIPE_Y = 0.6
CELL = 0.5
STOREY = 2.4
local function rot(yaw, x, z)
  local c, s = math.cos(yaw or 0), math.sin(yaw or 0)
  return x * c + z * s, -x * s + z * c
end
-- a part's port in its structure's frame: x, y, z, nx, nz
function portAt(p, pt)
  local dx, dz = rot(p.yaw, pt.x, pt.z)
  local nx, nz = rot(p.yaw, pt.nx, pt.nz)
  return (p.x or 0) + dx, (p.y or 0) + (pt.y or PIPE_Y), (p.z or 0) + dz, nx, nz
end

-- The cells of the core on vessel V: → { [key "i,j,l"] = { i, j, l, uid, role, mod } }
local function cells_on(rec, defs, V, vd)
  local out = {}
  local top = (vd.nuclear and vd.nuclear.top) or 1.0
  local half = math.floor(((vd.nuclear and vd.nuclear.cells) or 5) / 2)
  local c, s = math.cos(V.yaw or 0), math.sin(V.yaw or 0)
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    local nu = d and d.nuclear
    if nu and nu.role ~= "vessel" and math.abs(p.pitch or 0) < 1e-3 then
      local dx, dz = (p.x or 0) - (V.x or 0), (p.z or 0) - (V.z or 0)
      local u, v = dx * c - dz * s, dx * s + dz * c
      local i, j = math.floor(u / CELL + 0.5), math.floor(v / CELL + 0.5)
      local l = math.floor(((p.y or 0) - ((V.y or 0) + top)) / STOREY + 0.5)
      local ry = ((p.y or 0) - ((V.y or 0) + top)) - l * STOREY
      if math.abs(i) <= half and math.abs(j) <= half and math.abs(u - i * CELL) < 0.06 and math.abs(v - j * CELL) < 0.06
         and l >= 0 and math.abs(ry) < 0.06 then
        out[i .. "," .. j .. "," .. l] = { i = i, j = j, l = l, uid = p.uid, role = nu.role, mod = nu.mod, rods = nu.rods, label = d.label }
      end
    end
  end
  return out
end

-- The port graph of a structure. → ports (list), find (union root of a port),
-- partner (port → port it meets), byUid
local function port_graph(rec, defs)
  local ports, byUid = {}, {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    -- (S7: the fluid network's DN25 pieces and nozzles are fluids.lua's, never a loop's)
    if d and d.ports and not d.fl and math.abs(p.pitch or 0) < 1e-3 then
      local list = {}
      for k, pt in ipairs(d.ports) do
        if not pt.fluid then
        local x, y, z, nx, nz = portAt(p, pt)
        local P = { uid = p.uid, name = pt.name, loop = pt.loop, x = x, y = y, z = z, nx = nx, nz = nz, part = p, def = d, k = #ports + 1 }
        ports[#ports + 1] = P
        list[#list + 1] = P
        end
      end
      byUid[p.uid] = { part = p, def = d, ports = list }
    end
  end
  local U = {}
  local function find(a) while U[a] and U[a] ~= a do U[a] = U[U[a]] or U[a]; a = U[a] end return a end
  local function join(a, b) local ra, rb = find(a), find(b); if ra ~= rb then U[rb] = ra end end
  for i = 1, #ports do U[i] = i end
  -- inside a piece: the ports of one loop tag
  for _, e in pairs(byUid) do
    for a = 1, #e.ports do for b = a + 1, #e.ports do
      if e.ports[a].loop == e.ports[b].loop then join(e.ports[a].k, e.ports[b].k) end
    end end
  end
  -- between pieces: nozzles that meet, facing each other
  local partner = {}
  for a = 1, #ports do
    local A = ports[a]
    for b = a + 1, #ports do
      local B = ports[b]
      if A.uid ~= B.uid and math.abs(A.x - B.x) < 0.06 and math.abs(A.z - B.z) < 0.06 and math.abs(A.y - B.y) < 0.06
         and (A.nx * B.nx + A.nz * B.nz) < -0.9 then
        partner[a], partner[b] = b, a
        join(a, b)
      end
    end
  end
  return ports, find, partner, byUid
end

-- Walk a loop from port `from` (a component's outlet) back to port `to`:
-- the cycle the coolant runs. → { { uid, inP, outP } … } | nil
local function walk(ports, partner, byUid, from, to)
  local best = nil
  local seen = {}
  local path = {}
  local function dfs(pk, depth)
    if best or depth > 400 then return end
    local q = partner[pk]
    if not q then return end
    if q == to then best = {}; for i, x in ipairs(path) do best[i] = x end return end
    local Q = ports[q]
    if seen[Q.uid] then return end
    local e = byUid[Q.uid]
    seen[Q.uid] = true
    for _, out in ipairs(e.ports) do
      if out.k ~= q and out.loop == Q.loop then
        path[#path + 1] = { uid = Q.uid, inP = Q, outP = out }
        dfs(out.k, depth + 1)
        path[#path] = nil
        if best then break end
      end
    end
    seen[Q.uid] = nil
  end
  dfs(from, 0)
  return best
end

-- Everything about one structure's reactors that comes from its records.
-- → { plants = { plant … } }, plant = { vessel uid, cells, core (geometry),
-- pri, sec (loops), why (what is missing), graph (polylines for the overlay) }
function layout(rec, defs)
  local out = { plants = {}, consoles = {} }
  local vessels = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.nuclear and d.nuclear.role == "vessel" then vessels[#vessels + 1] = { p = p, d = d } end
    if d and d.console then out.consoles[#out.consoles + 1] = p.uid end
  end
  if #vessels == 0 then return out end
  local ports, find, partner, byUid = port_graph(rec, defs)
  -- which pipe pieces are lagged: an insulated pipe; a fitting or a short pipe
  -- whose every neighbour is lagged (a lagged pipe, a component's lagged
  -- shell, a lagged fitting), found to a fixed point along a run of fittings
  -- (the greatest fixed point: every fitting starts lagged and loses it if a
  -- neighbour is a bare pipe, an open end or a bare fitting)
  local lagged = {}
  for uid, e in pairs(byUid) do
    if e.def.pipe and (e.def.pipe.lagged or e.def.pipe.len <= 1.2) then lagged[uid] = true end
  end
  for _ = 1, 64 do
    local changed = false
    for uid, e in pairs(byUid) do
      if lagged[uid] and not e.def.pipe.lagged then
        for _, q in ipairs(e.ports) do
          local o = partner[q.k] and ports[partner[q.k]]
          if not (o and (lagged[o.uid] or not o.def.pipe)) then lagged[uid] = nil; changed = true break end
        end
      end
    end
    if not changed then break end
  end
  for _, V in ipairs(vessels) do
    local pl = { uid = V.p.uid, sid = rec.id, why = {}, warn = {} }
    pl.cells = cells_on(rec, defs, V.p, V.d)
    pl.vx, pl.vy, pl.vz, pl.vyaw = V.p.x or 0, V.p.y or 0, V.p.z or 0, V.p.yaw or 0
    pl.top = (V.d.nuclear and V.d.nuclear.top) or 1.0
    -- ── the loops ──
    local ve = byUid[V.p.uid]
    local pin, pout
    for _, pt in ipairs(ve and ve.ports or {}) do if pt.name == "in" then pin = pt elseif pt.name == "out" then pout = pt end end
    local function members(root)
      local m = {}
      for _, P in ipairs(ports) do if find(P.k) == root then m[#m + 1] = P end end
      return m
    end
    local function loop_of(entry, exit, label)
      local L = { label = label, pumps = {}, pipes = 0, ul = 0, water = 0, open = {}, parts = {}, sgs = {}, turbines = {}, rejects = {},
                  press = nil, cycle = nil, fwd = 0, rev = 0, design = 0 }
      if not (entry and exit) then L.closed = false return L end
      local root = find(entry.k)
      for _, P in ipairs(members(root)) do
        if not partner[P.k] then L.open[#L.open + 1] = P end
        if not L.parts[P.uid] then
          L.parts[P.uid] = true
          local d = P.def
          if d.pipe then
            -- (a fitting or a short pipe between two lagged neighbours — a
            -- lagged run or a component, whose shells are lagged — is lagged)
            local lag = lagged[P.uid] == true
            L.pipes = L.pipes + d.pipe.len
            L.loss = (L.loss or 0) + d.pipe.len * (lag and LAGGED_LOSS or (d.pipe.loss or 0.0025))
            if lag then L.lagged = (L.lagged or 0) + d.pipe.len end
          end
          if d.press then L.press = { uid = P.uid, def = d } end
        end
      end
      -- the press's surge nozzle open is no leak if nothing is on it: it is a
      -- dead end only once connected (a lone pressuriser isn't in this set)
      local cyc = walk(ports, partner, byUid, exit.k, entry.k)
      L.cycle = cyc
      L.closed = (cyc ~= nil) and #L.open == 0
      for _, st in ipairs(cyc or {}) do
        local d = byUid[st.uid].def
        if d.pump then
          local fwd = st.inP.name == "in" and st.outP.name == "out"
          L.pumps[#L.pumps + 1] = { uid = st.uid, def = d, fwd = fwd }
          if fwd then L.fwd = L.fwd + 1 else L.rev = L.rev + 1 end
        end
        if d.hx then L.sgs[#L.sgs + 1] = { uid = st.uid, def = d } end
        if d.turbine then L.turbines[#L.turbines + 1] = { uid = st.uid, def = d } end
        if d.reject then L.rejects[#L.rejects + 1] = { uid = st.uid, def = d } end
      end
      local n = #L.pumps
      local f1 = (n > 0) and L.pumps[1].def.pump.flow or 4.0
      L.design = (n > 0) and f1 * (1 + 0.25 * (n - 1)) or f1
      return L
    end
    pl.pri = loop_of(pin, pout, "primary")
    if not pl.pri.closed then
      if not (pin and pout) then pl.why[#pl.why + 1] = "the vessel's nozzles are missing"
      elseif #pl.pri.open > 0 then
        local o = pl.pri.open[1]
        pl.why[#pl.why + 1] = string.format("the primary loop is open at the %s's %s nozzle", o.def.label or "piece", o.name)
      else pl.why[#pl.why + 1] = "the primary loop doesn't come back to the vessel" end
    end
    if #pl.pri.pumps == 0 and pl.pri.closed then pl.why[#pl.why + 1] = "no coolant pump in the primary loop" end
    -- the secondary: from each steam generator on the primary
    pl.sec = { label = "secondary", pumps = {}, pipes = 0, ul = 0, open = {}, parts = {}, turbines = {}, rejects = {}, fwd = 0, rev = 0, design = 4.0, closed = false }
    for _, sg in ipairs(pl.pri.sgs) do
      local e = byUid[sg.uid]
      local si, so
      for _, pt in ipairs(e.ports) do if pt.name == "sec_in" then si = pt elseif pt.name == "sec_out" then so = pt end end
      local S = loop_of(si, so, "secondary")
      if S.closed or not pl.sec.closed then S.sg = sg.uid; pl.sec = S end
    end
    if #pl.pri.sgs == 0 then pl.warn[#pl.warn + 1] = "no steam generator on the primary: nothing takes the heat out"
    elseif not pl.sec.closed then pl.warn[#pl.warn + 1] = "the secondary loop isn't closed"
    elseif #pl.sec.rejects == 0 then pl.warn[#pl.warn + 1] = "the secondary has no radiator or cooling tower: no heat sink"
    elseif #pl.sec.pumps == 0 then pl.warn[#pl.warn + 1] = "no feed pump in the secondary loop" end
    -- the overlay's polylines (structure frame)
    local function lines(L)
      local seg = {}
      for _, st in ipairs(L.cycle or {}) do
        seg[#seg + 1] = { uid = st.uid, a = { st.inP.x, st.inP.y, st.inP.z }, b = { st.outP.x, st.outP.y, st.outP.z },
                          c = { byUid[st.uid].part.x or 0, (byUid[st.uid].part.y or 0) + PIPE_Y, byUid[st.uid].part.z or 0 },
                          pipe = byUid[st.uid].def.pipe ~= nil, label = byUid[st.uid].def.label }
      end
      return seg
    end
    pl.graph = { pri = lines(pl.pri), sec = lines(pl.sec) }
    out.plants[#out.plants + 1] = pl
  end
  return out
end

-- ── THE CORE: the static coefficients from the cells and the rods ───────────
-- ch = { [uid] = { rods = { rod … } } } (the plant state's channels).
-- → core = { channels = { { uid, i, j, l, rods, w (flux shape) } }, faces,
--            S/A sums (b·atoms) by bucket, rodFull, B2, R, H, refl, ratedW … }
function coreOf(pl, ch)
  local C = { channels = {}, nfuel = 0, nrod = 0, nmod = 0, why = {}, warn = {} }
  local cells = pl.cells
  local function at(i, j, l) return cells[i .. "," .. j .. "," .. l] end
  local fuelFaces = {}         -- moderator / rod cell key → its fuel faces
  local D4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for k, c in pairs(cells) do
    if c.role == "fuel" then
      C.nfuel = C.nfuel + 1
      for _, d in ipairs(D4) do
        local n = at(c.i + d[1], c.j + d[2], c.l)
        if n and n.role ~= "fuel" then
          local nk = n.i .. "," .. n.j .. "," .. n.l
          fuelFaces[nk] = (fuelFaces[nk] or 0) + 1
        end
      end
    elseif c.role == "rod" then C.nrod = C.nrod + 1
    elseif c.role == "mod" then C.nmod = C.nmod + 1 end
  end
  -- the moderation each moderator column gives (b·atoms) and its bucket
  local Sx = { graphite = 0, water = 0, heavy = 0, cool = 0 }
  local Sa = { graphite = 0, water = 0, heavy = 0, cool = 0 }
  C.rodFull = 0
  C.rods = {}
  for k, c in pairs(cells) do
    local nf = fuelFaces[k] or 0
    if c.role == "mod" and nf > 0 then
      local m = MOD[c.mod] or MOD.graphite
      local share = math.min(m.skin, 1 / nf) * nf     -- of the column, over all its fuel faces
      if m.skin < 1 then share = math.min(1, m.skin * nf) end
      Sx[c.mod] = Sx[c.mod] + share * m.N * m.xs
      Sa[c.mod] = Sa[c.mod] + share * m.N * m.sa
    elseif c.role == "rod" then
      C.rodFull = C.rodFull + nf * RX.W_rod * U_FULL
      C.rods[#C.rods + 1] = { uid = c.uid, faces = nf }
      if nf == 0 then C.warn[#C.warn + 1] = "a control rod touches no fuel: it is worth nothing" end
    end
  end
  -- the fuel channels: their rods, the coolant in each
  local U, nrods = 0, 0
  local ci, cj, cn = 0, 0, 0
  local levels = {}
  for k, c in pairs(cells) do
    if c.role == "fuel" then
      local st = ch and ch[c.uid] or nil
      local rods = st and st.rods or {}
      local e = { uid = c.uid, i = c.i, j = c.j, l = c.l, rods = rods, slots = c.rods or RX.rods_full }
      C.channels[#C.channels + 1] = e
      nrods = nrods + #rods
      U = U + #rods * U_ROD
      Sx.cool = Sx.cool + COOL.x * U_FULL * COOL.xs
      Sa.cool = Sa.cool + COOL.x * U_FULL * COOL.sa
      ci, cj, cn = ci + c.i, cj + c.j, cn + 1
      levels[c.l] = true
    end
  end
  table.sort(C.channels, function(a, b) if a.l ~= b.l then return a.l < b.l end if a.i ~= b.i then return a.i < b.i end return a.j < b.j end)
  C.U, C.nrods = U, nrods
  C.Sx, C.Sa = Sx, Sa
  C.Astruct = A_STRUCT * U_FULL * C.nfuel
  -- the geometry: the core region (fuel, and what touches fuel) and its reflector
  local region, plan = {}, {}
  local nplan = 0
  for k, c in pairs(cells) do
    if c.role == "fuel" or (fuelFaces[k] or 0) > 0 then
      region[k] = true
      local pk = c.i .. "," .. c.j
      if not plan[pk] then plan[pk] = true; nplan = nplan + 1 end
    end
  end
  local faces, refl = 0, 0
  for k, c in pairs(cells) do
    if region[k] then
      for _, d in ipairs(D4) do
        local nk = (c.i + d[1]) .. "," .. (c.j + d[2]) .. "," .. c.l
        if not region[nk] then
          faces = faces + 1
          local n = cells[nk]
          if n and n.role == "mod" then refl = refl + (MOD[n.mod] or MOD.graphite).refl end
        end
      end
    end
  end
  local nlev = 0
  for _ in pairs(levels) do nlev = nlev + 1 end
  C.R = math.sqrt(math.max(nplan, 1) * CELL * CELL / math.pi)
  C.delta = (faces > 0) and refl / faces or 0
  C.H = STOREY * math.max(nlev, 1) + 0.2
  C.B2 = (2.405 / (C.R + C.delta)) ^ 2 + (math.pi / C.H) ^ 2
  C.nplan, C.nlev = nplan, nlev
  -- the flux shape: each channel's share by its distance from the fuel's centre
  if cn > 0 then
    local mi, mj = ci / cn, cj / cn
    local Re = C.R + C.delta
    local sw = 0
    for _, e in ipairs(C.channels) do
      local r = math.sqrt(((e.i - mi) * CELL) ^ 2 + ((e.j - mj) * CELL) ^ 2)
      e.w = math.max(0.25, math.cos(1.2 * math.min(r / Re, 1.3)))
      sw = sw + e.w * #e.rods
    end
    local nr = math.max(1, nrods)
    for _, e in ipairs(C.channels) do e.w = (sw > 0) and e.w * nr / sw or 1 end
  end
  -- the rating: a full channel's 40 kW, by the rods in it
  C.ratedW = RX.channel_kw * 1000 * nrods / RX.rods_full
  if C.nfuel == 0 then C.why[#C.why + 1] = "no fuel channel on the vessel's lattice" end
  if C.nfuel > 0 and nrods == 0 then C.why[#C.why + 1] = "no fuel loaded" end
  if C.nrod == 0 and C.nfuel > 0 then C.warn[#C.warn + 1] = "no control rods: nothing to shut it down but its own heat" end
  aggregate(C)
  return C
end

-- The fuel's sums from its rods' compositions (after every burn).
function aggregate(C)
  local Fnu, Af, N8, Afp, F, B = 0, 0, 0, 0, 0, 0
  for _, e in ipairs(C.channels) do
    for _, r in ipairs(e.rods) do
      local n8 = math.max(0, 1 - r.e - r.p9 - r.fp)
      Fnu = Fnu + U_ROD * (RX.nu5 * RX.sf5 * r.e + RX.nu9 * RX.sf9 * r.p9)
      Af = Af + U_ROD * (RX.sa5 * r.e + RX.sa9 * r.p9 + RX.sa8 * n8)
      N8 = N8 + U_ROD * n8
      Afp = Afp + U_ROD * r.fp * RX.sfp
      local f = RX.sf5 * r.e + RX.sf9 * r.p9
      F = F + U_ROD * f
      B = B + U_ROD * (RX.beta5 * RX.sf5 * r.e + RX.beta9 * RX.sf9 * r.p9)
    end
  end
  C.Fnu, C.Af, C.N8, C.Afp, C.F = Fnu, Af, N8, Afp, F
  C.beta = (F > 0) and B / F or RX.beta5
  C.sigf = (C.U > 0) and F / C.U or 0                 -- b of fission per U atom
  C.fluxK = (C.sigf > 0) and clamp((RX.sf5 * 0.03) / C.sigf, 0.25, 4) or 1
  return C
end

-- k and ρ of core C with the rods at x, the fuel at Tf, the coolant at Tp,
-- xenon X and samarium Sm (b per U atom). → rho, k, kinf, parts
function reactivity(C, x, Tf, Tp, X, Sm, melt, lite)
  if C.U <= 0 then return -1, 0, 0, nil end
  if melt then return -0.3, 0.77, 0.77, nil end
  -- (the channels' coolant is at the primary's temperature; a moderator tank
  -- is lagged and cooled apart, as a calandria's is: it runs MOD_WARM of the
  -- way from the room to the coolant)
  local w = waterDensity(Tp or 300)
  local ta = C.tamb or 288
  local wm = waterDensity(ta + MOD_WARM * ((Tp or 300) - ta))
  local Sx, Sa = C.Sx, C.Sa
  local sxw = (Sx.water + Sx.heavy) * wm + Sx.cool * w
  local S = Sx.graphite + sxw
  local Amod = Sa.graphite + (Sa.water + Sa.heavy) * wm + Sa.cool * w
  local Arod = C.rodFull * rodWorth(x or 0)
  local Apois = C.U * ((X or 0) + (Sm or 0))
  local A = C.Af + Amod + C.Astruct + C.Afp + Apois + Arod
  local I = RX.I0 * (1 + RX.betaD * (math.sqrt(math.max(Tf or 300, 1)) - math.sqrt(300)))
  local p = math.exp(-C.N8 * I / math.max(S, 1e-30))
  local kinf = RX.eps * p * C.Fnu / A
  -- the migration area of the mix (shares of the slowing-down power)
  local tau, L2 = 0, 0
  if S > 0 then
    tau = (Sx.graphite * MOD.graphite.tau + Sx.water * wm * MOD.water.tau + Sx.heavy * wm * MOD.heavy.tau + Sx.cool * w * COOL.tau) / S
    L2 = (Sx.graphite * MOD.graphite.L2 + Sx.water * wm * MOD.water.L2 + Sx.heavy * wm * MOD.heavy.L2 + Sx.cool * w * COOL.L2) / S
  end
  local f = C.Af / A
  local M2 = tau + L2 * (1 - f)
  local k = kinf / (1 + C.B2 * M2)
  if lite then return 1 - 1 / k, k, kinf, nil end
  return 1 - 1 / k, k, kinf, { p = p, f = f, M2 = M2, PNL = 1 / (1 + C.B2 * M2), eta = C.Fnu / math.max(C.Af, 1e-30), Arod = Arod, A = A, Apois = Apois }
end

-- The heat network's link laws: thermal.lua's (S6's HEATNET section), bound
-- once a model; the same formulas here if thermal isn't loaded (a bare test).
local LINKS_LOCAL = {
  conduct = function(G, a, b) return G * (a - b) end,
  exchange = function(UA, m, cp, h, c) local mc = m * cp; if mc <= 1e-12 or UA <= 0 then return 0 end return (1 - math.exp(-UA / mc)) * mc * (h - c) end,
  radiate = function(e, A, T, Ts) return e * 5.670374e-8 * A * (T ^ 4 - Ts ^ 4) end,
  carnot = function(h, c) if h <= 0 then return 0 end return math.max(0, 1 - c / h) end,
  from = "local",
}
local LINKS
function heatLinks()
  if LINKS then return LINKS end
  local TH = findScript and findScript("thermal") or nil
  if TH and TH.linkExchange and TH.linkRadiate and TH.carnot and TH.linkConduct then
    LINKS = { conduct = TH.linkConduct, exchange = TH.linkExchange, radiate = TH.linkRadiate, carnot = TH.carnot, from = "thermal" }
    return LINKS
  end
  return LINKS_LOCAL
end

-- ── THE PLANT MODEL (the core plus its loops; rebuilt on a layout change) ───
-- env = { tamb (K), atm (atm), sun (0..1) }; run = { pumps = { [uid] = on and
-- powered }, press (heaters powered), tower (fans powered), turbine (online) }
function model(pl, ch, env, run)
  local C = coreOf(pl, ch)
  local M = { core = C, pl = pl, env = env or {}, why = {}, warn = {} }
  for _, w in ipairs(pl.why) do M.why[#M.why + 1] = w end
  for _, w in ipairs(C.why) do M.why[#M.why + 1] = w end
  for _, w in ipairs(pl.warn) do M.warn[#M.warn + 1] = w end
  for _, w in ipairs(C.warn) do M.warn[#M.warn + 1] = w end
  local tamb = (env and env.tamb) or 288
  local atm = (env and env.atm) or 1
  M.tamb, M.atm = tamb, atm
  C.tamb = tamb
  M.tsky = (atm > 0.05) and (tamb - 20) or 0.84 * tamb
  local Pr = math.max(C.ratedW, 1000)
  M.Pr = Pr
  M.UAfc0 = Pr / RX.dTfc
  M.Cf = M.UAfc0 * RX.tau_f
  run = run or {}
  M.run = run
  M.heat = heatLinks()
  -- the primary
  local P = pl.pri
  local function flow_of(L)
    local nrun, fwd, rev = 0, 0, 0
    for _, pu in ipairs(L.pumps) do
      if run.pumps == nil or run.pumps[pu.uid] then
        nrun = nrun + 1
        if pu.fwd then fwd = fwd + 1 else rev = rev + 1 end
      end
    end
    local f1 = (#L.pumps > 0) and L.pumps[1].def.pump.flow or 4.0
    local net = math.abs(fwd - rev)
    local q = 0
    if nrun > 0 then q = f1 * (1 + 0.25 * (net - 1)) * ((fwd > 0 and rev > 0) and 0.6 or 1) end
    if net == 0 then q = 0 end
    return q, nrun, (fwd > 0 and rev > 0)
  end
  M.mp_design = P.design or 4.0
  M.mp_target, M.npri, M.fight_p = 0, 0, false
  if P.closed then M.mp_target, M.npri, M.fight_p = flow_of(P) end
  -- (a coolant pump's work ends up in the water: what holds a tripped plant hot)
  M.Qpump = 0
  for _, pu in ipairs(P.pumps or {}) do
    if run.pumps == nil or run.pumps[pu.uid] then M.Qpump = M.Qpump + (pu.def.pump.kw or 1.5) * 1000 end
  end
  if M.fight_p then M.warn[#M.warn + 1] = "the primary's pumps push against each other" end
  -- (W/K: the pipes, and the lagged shells of the vessel and the generator,
  -- as shares of the rating at the design ΔT)
  M.ULp = ((P.loss or 0) + SHELL_LOSS) * Pr / DT_DESIGN
  M.press = P.press ~= nil
  M.tsat = (M.press and run.press ~= false) and (P.press.def.press.tsat or 618) or (M.press and 540 or 373)
  -- (S7) THE COOLANT INVENTORY, a fluid system: the primary's real water
  -- (its pipes' bore, the vessel's plenum and channels, the steam generators'
  -- tubes, the pressuriser's water, the pumps' casings) in kg at its hot
  -- density; a BREAK (run.brkA, m² of the bore opened) blows it down and
  -- depressurises it (it boils at 100 °C); MAKEUP (M.mk, kg/s, set by
  -- fluid_net through the pressuriser's nozzle) refills it. Boil-off keeps
  -- S6's rating-scaled figure (BOIL_S): the break and the makeup are real kg.
  local nch = 0
  for _, cell in pairs(pl.cells or {}) do if cell.role == "fuel" then nch = nch + 1 end end
  M.Mw = WATER_HOT * (PIPE_A * (P.pipes or 0) + PLENUM_V + CHANNEL_V * nch + SG_V * #(P.sgs or {}) + (P.press and PRESS_V or 0) + PUMP_V * #(P.pumps or {}))
  M.brkA = run.brkA or 0
  M.mk = run.mk or 0
  if M.brkA > BREAK_DEP then M.tsat = 373; M.broken = true end
  local ua = 0
  for _, sg in ipairs(P.sgs or {}) do ua = ua + (sg.def.hx.ua or 30) * 1000 end
  M.UAhx = P.closed and ua or 0
  -- (the primary's water and steel: its rating's, 70 % of it the water)
  M.Cp_w = 0.7 * CAP.pri * Pr
  M.Cp_s = 0.3 * CAP.pri * Pr
  M.Mp = BOIL_S * Pr / RX.hfg
  M.Gb = math.max(2e5, 5 * Pr)
  -- the secondary
  local S = pl.sec
  M.ms_design = S.design or 4.0
  M.ms_target, M.nsec = 0, 0
  if S.closed then M.ms_target, M.nsec = flow_of(S) end
  M.ULs = ((S.loss or 0) + SHELL_LOSS * 0.5) * Pr / DT_DESIGN
  M.Cs = CAP.sec * Pr
  local tb = S.closed and S.turbines[1] or nil
  M.turb = tb and tb.def.turbine or nil
  M.turb_uid = tb and tb.uid or nil
  M.turb_on = tb ~= nil and run.turbine ~= false
  M.eta = M.turb and (M.turb.eta + (run.trim or 0)) or 0
  M.qmax = M.turb and M.turb.qmax * 1000 or 0
  M.kwe = M.turb and M.turb.kwe * 1000 or 0
  M.Gpath = M.turb and (M.qmax / RX.dT_turb) or 4e4
  M.tset = math.min(RX.T_steam, M.tsat - 45)
  -- the sinks
  M.radA, M.radEps, M.towerG, M.tower_ok = 0, 0.88, 0, true
  local ck = CAP.cond * Pr
  for _, r in ipairs(S.closed and S.rejects or {}) do
    local j = r.def.reject
    if j.kind == "rad" then M.radA = M.radA + j.area; M.radEps = j.eps or 0.88
    elseif j.kind == "tower" then
      local air = clamp(atm / 0.3, 0, 1)
      M.towerG = M.towerG + (j.g or 14) * 1000 * air * ((run.tower ~= false) and 1 or 0.15)
      if atm < 0.1 then M.tower_ok = false end
    end
  end
  if not M.tower_ok then M.warn[#M.warn + 1] = "a cooling tower on an airless world blows nothing" end
  M.Ck = ck
  return M
end

-- ── THE STATE ───────────────────────────────────────────────────────────────
-- y: 1 y1, 2 y2 (precursors, power units), 3 x (rods in), 4 Tf, 5 Tp, 6 Ts,
-- 7 Tk (K), 8 Iq, 9 X, 10 Pq, 11 Sm (b per U atom: I·σX, Xe·σX, Pm·σSm,
-- Sm·σSm), 12..18 D1..D7 (decay heat, shares of the rating), 19 E (∫P dt, s),
-- 20 mp, 21 ms (kg/s), 22 inv (the primary's water left, 0..1), 23 dmg
NY = 23
local IY1, IY2, IX, ITF, ITP, ITS, ITK, II, IXE, IPM, ISM, ID1, IE, IMP, IMS, IINV, IDMG = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 19, 20, 21, 22, 23
IDX = { y1 = 1, y2 = 2, x = 3, Tf = 4, Tp = 5, Ts = 6, Tk = 7, I = 8, Xe = 9, Pm = 10, Sm = 11, D1 = 12, E = 19, mp = 20, ms = 21, inv = 22, dmg = 23 }
-- A cold, shut-down, unfuelled-history plant at ambient.
function newState(tamb)
  local y = {}
  for i = 1, NY do y[i] = 0 end
  y[IX] = 1
  y[ITF], y[ITP], y[ITS], y[ITK] = tamb or 288, tamb or 288, tamb or 288, tamb or 288
  y[IINV] = 1
  return { y = y, mode = "manual", set = 0.5, xt = 1, scram = false, cause = nil, prot = true, h = 1.0, t = 0, ev = {}, melt = false, rel = 0, bursts = 0 }
end

-- the rods' rate (per s) for state S at insertion x, power P, reactivity rho
local function rod_rate(S, M, x, P, rho)
  local v
  if S.scram or S.melt then
    v = RX.v_scram * math.tanh((1 - x) / 0.01)
  elseif S.mode == "auto" then
    local set = math.max(1e-6, S.set or 0.5)
    local lp = math.log(math.max(P, 1e-14) / set)
    v = RX.v_auto * math.tanh(lp / 0.03)
    if v < 0 then
      -- (withdrawing: never past a tenth of β of reactivity, so the period
      -- stays long and the controller can't make it prompt)
      local b = M.core.beta
      v = v * (1 - smooth01((rho - 0.04 * b) / (0.08 * b)))
    end
  else
    v = RX.v_rod * math.tanh(((S.xt or 1) - x) / 0.01)
  end
  -- (the stops, smoothly: a rate with a kink at the stop makes the stiff
  -- solver chatter against it)
  if v > 0 then v = v * smooth01((1 - x) / 0.004) else v = v * smooth01(x / 0.004) end
  return v
end

-- What the plant is doing at state y: everything the readouts and the events
-- read, and the rates. → out (filled), dy (filled when given)
local SCR = {}
function derive(M, S, y, dy, out, lite)
  out = out or {}
  local C = M.core
  local x = clamp(y[IX], 0, 1)
  local Tf, Tp, Ts, Tk = y[ITF], y[ITP], y[ITS], y[ITK]
  -- (the melt is latched by its event, never switched inside a stage: a jump in
  -- the rates there would stall the stiff solver short of it)
  local melt = S.melt == true
  local rho, k, kinf, parts = reactivity(C, x, Tf, Tp, y[IXE], y[ISM], melt, lite)
  local beta = C.beta or RX.beta5
  local den = math.max(beta - rho, 0.002 * beta)
  local P = 0
  if C.U > 0 then P = beta * (RX.g1 * y[IY1] + RX.g2 * y[IY2] + RX.src) / den end
  if P < 0 then P = 0 end
  local Pr = M.Pr
  local sumD, sumA = 0, 0
  for i = 1, 7 do sumD = sumD + y[ID1 + i - 1]; sumA = sumA + RX.aD[i] end
  local Qfis = Pr * P * (1 - sumA)
  local Qdec = Pr * sumD
  local Qcore = Qfis + Qdec
  -- the flows: the pumps, and natural circulation on the primary's warmth
  local mp, ms = math.max(0, y[IMP]), math.max(0, y[IMS])
  local mnc = 0
  if M.UAhx > 0 then mnc = RX.nc * M.mp_design * math.sqrt(softplus((Tp - Ts) / 4) * 4 / 40) end
  local mpe = mp + mnc
  local fx = mpe / math.max(M.mp_design, 1e-6)
  local fh = 0.12 + 0.88 * (fx * fx + 1e-4) ^ 0.4
  local inv = clamp(y[IINV], 0, 1)
  -- (uncovered, the fuel has only steam and its own glow to the vessel)
  local cov = 0.002 + 0.998 * smooth01((inv - 0.25) / 0.3)
  local UAfc = M.UAfc0 * fh * cov
  local H = M.heat
  local Qfc = H.conduct(UAfc, Tf, Tp)
  local Qhx = 0
  if M.UAhx > 0 and mpe > 1e-9 then
    local mc = mpe * RX.cp_p
    Qhx = H.exchange(M.UAhx, mpe, RX.cp_p, Tp, Ts)
  end
  local Qlp = H.conduct(M.ULp, Tp, M.tamb)
  local Qpump = (M.mp_target > 0) and M.Qpump * math.min(1, mp / M.mp_target) or 0
  local Qboil = M.Gb * 2 * softplus((Tp - M.tsat) / 2)
  local Cp = M.Cp_w * math.max(inv, 0.05) + M.Cp_s
  -- (S7) the break: two-phase critical flow while the water is hot, a drain
  -- once it isn't; the makeup, cut off as the loop fills
  local brk, mk = 0, 0
  if (M.brkA or 0) > 0 then brk = (GC_HOT * smooth01((Tp - 380) / 60) + GC_COLD) * M.brkA * smooth01((inv - BREAK_FLOOR) / 0.03) end
  if (M.mk or 0) > 0 then mk = M.mk * smooth01((1.0005 - inv) / 0.002) end
  -- the secondary: steam to the turbine (or its bypass) and the condenser
  -- (no feedwater, no steam: a steam generator its feed pump has stopped boils
  -- dry and carries nothing on, the loss of heat sink; a trickle keeps it defined)
  local mse = ms + 1e-7 * M.ms_design
  local Gflow = mse * RX.G_sec
  -- (steam pressure control: the turbine's valve opens as the steam passes its
  -- set temperature, so the plant runs at its design steam and, tripped, sits
  -- at HOT STANDBY on its decay heat; COOL DOWN opens the dump to the condenser)
  local Gp = M.Gpath
  if M.turb and not S.cooldown then Gp = M.Gpath * (0.0005 + 0.9995 * smooth01((Ts - (M.tset - 20)) / 25)) end
  local Geff = 1 / (1 / Gp + 1 / math.max(Gflow, 1e-9))
  local Qst = Geff * (Ts - Tk)
  local Qls = H.conduct(M.ULs, Ts, M.tamb)
  -- the turbine: η of Carnot on what it admits, spinning only on enough steam
  local Pe = 0
  local Qt = 0
  if M.turb and M.turb_on and Qst > 0 then
    Qt = Qst
    local spin = smooth01((Qt / M.qmax - (M.turb.min or 0.1) + 0.02) / 0.04)
    local car = H.carnot(Ts, Tk)
    local raw = M.eta * car * Qt * spin
    -- (its generator's rating: a soft cap)
    Pe = raw / (1 + (raw / M.kwe) ^ 20) ^ (1 / 20)
    out.carnot = car
  end
  -- the sinks
  local Qrad = 0
  if M.radA > 0 then
    Qrad = H.radiate(M.radEps, M.radA, Tk, M.tsky) * (1 - 0.35 * (M.env.sun or 0))
           + RX.h_air * M.radA * clamp(M.atm, 0, 1) * (Tk - M.tamb)
  end
  local Qtow = M.towerG * (Tk - M.tamb)
  local Qrej = Qrad + Qtow
  -- the poisons and the burnup clock
  local phi = RX.phi_ref * P * C.fluxK
  local Rf = C.sigf * 1e-24 * phi
  local dmgRate = 0
  if Tf > RX.T_damage and not melt then dmgRate = 2e-4 * ((Tf - RX.T_damage) / 100) ^ 2 end
  if dy then
    dy[IY1] = RX.l1 * (P - y[IY1])
    dy[IY2] = RX.l2 * (P - y[IY2])
    dy[IX] = rod_rate(S, M, x, P, rho)
    dy[ITF] = (Qcore - Qfc) / M.Cf
    dy[ITP] = (Qfc + Qpump - Qhx - Qlp - Qboil) / Cp
    dy[ITS] = (Qhx - Qst - Qls) / M.Cs
    dy[ITK] = (Qst - Pe - Qrej) / M.Ck
    dy[II] = RX.gI * Rf * RX.sX - RX.lI * y[II]
    dy[IXE] = RX.gX * Rf * RX.sX + RX.lI * y[II] - RX.lX * y[IXE] - RX.sX * 1e-24 * phi * y[IXE]
    dy[IPM] = RX.gPm * Rf * RX.sSm - RX.lPm * y[IPM]
    dy[ISM] = RX.lPm * y[IPM] - RX.sSm * 1e-24 * phi * y[ISM]
    for i = 1, 7 do dy[ID1 + i - 1] = RX.lD[i] * (RX.aD[i] * P - y[ID1 + i - 1]) end
    dy[IE] = P * C.fluxK
    dy[IMP] = (M.mp_target - mp) / RX.tau_pump
    dy[IMS] = (M.ms_target - ms) / RX.tau_pump
    -- (S6's boil-off is rating-scaled (BOIL_S); a broken loop's water is real kg)
    local boilI = M.broken and Qboil / (HFG_REAL * math.max(M.Mw or 1, 1)) or Qboil / (RX.hfg * math.max(M.Mp, 1))
    dy[IINV] = -boilI + (mk - brk) / math.max(M.Mw or 1, 1)
    dy[IDMG] = dmgRate
  end
  out.rho, out.k, out.kinf, out.parts, out.beta = rho, k, kinf, parts, beta
  out.P, out.Qfis, out.Qdec, out.Qcore, out.Qfc, out.Qhx, out.Qlp, out.Qboil = P, Qfis, Qdec, Qcore, Qfc, Qhx, Qlp, Qboil
  out.Qst, out.Qls, out.Qt, out.Pe, out.Qrej, out.Qrad, out.Qtow = Qst, Qls, Qt, Pe, Qrej, Qrad, Qtow
  out.Qpump = Qpump
  out.brk, out.mk = brk, mk
  out.mp, out.mpe, out.ms, out.mnc, out.UAfc, out.phi, out.inv, out.x = mp, mpe, ms, mnc, UAfc, phi, inv, x
  out.Tf, out.Tp, out.Ts, out.Tk, out.melt, out.dmg = Tf, Tp, Ts, Tk, melt, y[IDMG]
  return out, dy
end

-- The trips and the physical events, as functions that cross zero upward.
-- → { { name, g } … }
local EVENTS = { "power", "period", "fuel", "subcool", "flow", "prompt", "melt" }
EVENT_TEXT = {
  power = "high power", period = "short period", fuel = "fuel overtemperature", subcool = "coolant near boiling",
  flow = "low coolant flow", prompt = "PROMPT CRITICAL", melt = "MELTDOWN", hand = "SCRAM by hand",
}
local function events_of(M, S, o)
  local g = {}
  local armed = S.prot and not S.scram and not S.melt
  local b = o.beta
  -- (the period trip: the stable period from ρ, one-group inhour)
  local rho_p = b * (1 / RX.trip_period) / (1 / RX.trip_period + 0.077)
  g.power = armed and (o.P - RX.trip_P) or -1
  g.period = armed and (o.rho - rho_p) or -1
  g.fuel = armed and (o.Tf - RX.trip_Tf) or -1
  g.subcool = armed and math.min(o.Tp - (M.tsat - RX.trip_sub), o.P - 0.02) or -1
  g.flow = (armed and M.mp_design > 0) and math.min(RX.trip_flow - o.mpe / M.mp_design, o.P - 0.05) or -1
  g.prompt = (not S.melt) and (o.rho - RX.prompt * b) or -1
  g.melt = (not S.melt) and (o.dmg - 1) or -1
  return g
end

-- ── the linear algebra (dense, small) ───────────────────────────────────────
local function lu(A, n)
  local P = {}
  for i = 1, n do P[i] = i end
  for k = 1, n do
    local p, best = k, math.abs(A[k][k])
    for i = k + 1, n do local v = math.abs(A[i][k]); if v > best then p, best = i, v end end
    if best < 1e-300 then return nil end
    if p ~= k then A[k], A[p] = A[p], A[k]; P[k], P[p] = P[p], P[k] end
    local Ak, akk = A[k], A[k][k]
    for i = k + 1, n do
      local Ai = A[i]
      local f = Ai[k] / akk
      Ai[k] = f
      if f ~= 0 then for j = k + 1, n do Ai[j] = Ai[j] - f * Ak[j] end end
    end
  end
  return { A = A, P = P, n = n }
end
local function solve(F, b, x)
  local A, P, n = F.A, F.P, F.n
  x = x or {}
  for i = 1, n do
    local s = b[P[i]]
    local Ai = A[i]
    for j = 1, i - 1 do s = s - Ai[j] * x[j] end
    x[i] = s
  end
  for i = n, 1, -1 do
    local s = x[i]
    local Ai = A[i]
    for j = i + 1, n do s = s - Ai[j] * x[j] end
    x[i] = s / Ai[i]
  end
  return x
end

-- (the error scale of each state)
local ATOL = { 1e-9, 1e-9, 1e-6, 1e-3, 1e-3, 1e-3, 1e-3, 1e-6, 1e-6, 1e-6, 1e-6,
               1e-8, 1e-8, 1e-8, 1e-8, 1e-8, 1e-8, 1e-8, 1e-2, 1e-5, 1e-5, 1e-6, 1e-6 }
local TYP = { 1e-6, 1e-6, 1e-3, 1, 1, 1, 1, 1e-3, 1e-3, 1e-3, 1e-3, 1e-6, 1e-6, 1e-6, 1e-6, 1e-6, 1e-6, 1e-6, 1, 1e-3, 1e-3, 1e-3, 1e-3 }
local D23 = 1 / (2 + math.sqrt(2))
local E32 = 6 + math.sqrt(2)

local function clamp_state(y)
  y[IX] = clamp(y[IX], 0, 1)
  y[IINV] = clamp(y[IINV], 0, 1)
  if y[IDMG] < 0 then y[IDMG] = 0 end
  if y[IMP] < 0 then y[IMP] = 0 end
  if y[IMS] < 0 then y[IMS] = 0 end
  for i = II, ID1 + 6 do if y[i] < 0 then y[i] = 0 end end
  if y[IY1] < 0 then y[IY1] = 0 end
  if y[IY2] < 0 then y[IY2] = 0 end
end

-- One Rosenbrock step of h from y (F0 = f(y)). → ynew, err (scaled), F2
local function ros_step(M, S, y, F0, h, J)
  local n = NY
  local f = function(yy, dd) local _, d = derive(M, S, yy, dd, SCR, true); return d end
  -- W = I − h·d·J
  local W = {}
  for i = 1, n do
    local row, Ji = {}, J[i]
    for j = 1, n do row[j] = -h * D23 * Ji[j] end
    row[i] = row[i] + 1
    W[i] = row
  end
  local F = lu(W, n)
  if not F then return nil end
  local k1 = solve(F, F0, {})
  local y1 = {}
  for i = 1, n do y1[i] = y[i] + 0.5 * h * k1[i] end
  local F1 = f(y1, {})
  local r = {}
  for i = 1, n do r[i] = F1[i] - k1[i] end
  local k2 = solve(F, r, {})
  for i = 1, n do k2[i] = k2[i] + k1[i] end
  local yn = {}
  for i = 1, n do yn[i] = y[i] + h * k2[i] end
  local F2 = f(yn, {})
  for i = 1, n do r[i] = F2[i] - E32 * (k2[i] - F1[i]) - 2 * (k1[i] - F0[i]) end
  local k3 = solve(F, r, {})
  local err = 0
  for i = 1, n do
    local e = h / 6 * (k1[i] - 2 * k2[i] + k3[i])
    local sc = ATOL[i] + RX.rtol * math.max(math.abs(y[i]), math.abs(yn[i]))
    local q = math.abs(e) / sc
    if q > err then err = q end
  end
  return yn, err, F2
end

local function jacobian(M, S, y, F0)
  local n = NY
  local J = {}
  for i = 1, n do J[i] = {} end
  local yy = {}
  for i = 1, n do yy[i] = y[i] end
  local dd = {}
  for j = 1, n do
    if j == IE or j == IDMG then
      for i = 1, n do J[i][j] = 0 end
    else
      local d = 1e-7 * math.max(math.abs(y[j]), TYP[j])
      yy[j] = y[j] + d
      local _, Fd = derive(M, S, yy, dd, SCR, true)
      for i = 1, n do J[i][j] = (Fd[i] - F0[i]) / d end
      yy[j] = y[j]
    end
  end
  return J
end

-- Fold the fluence of a step into the rods (their closed form) and the sums.
local function burn(M, dE)
  if dE <= 0 then return end
  local C = M.core
  local dPhi = RX.phi_ref * dE         -- (E already carries the flux factor)
  for _, e in ipairs(C.channels) do
    for _, r in ipairs(e.rods) do burnRod(r, dPhi * (e.w or 1)) end
  end
  aggregate(C)
end

-- Apply an event at the state's moment. → the report line
local function apply_event(M, S, y, name, t_at, o)
  if name == "prompt" then
    -- a Nordheim–Fuchs burst: the Doppler swings ρ back past β, the fuel takes
    -- the energy, a share reaches the coolant at once
    local b = o.beta
    local d = 1.0
    local r2 = reactivity(M.core, clamp(y[IX], 0, 1), y[ITF] + d, y[ITP], y[IXE], y[ISM], false)
    local aD = math.max(1e-7, (o.rho - r2) / d)
    -- (past ~3,500 K the fuel has vaporised out of its lattice: the burst ends there)
    local dT = math.min(math.max(50, 2 * (o.rho - 0.85 * b) / aD), 3500 - y[ITF] + 50)
    local Ej = M.Cf * dT
    y[ITF] = y[ITF] + dT * 0.85
    local Cp = M.Cp_w * math.max(y[IINV], 0.05) + M.Cp_s
    y[ITP] = y[ITP] + Ej * 0.15 / Cp
    for i = 1, 7 do y[ID1 + i - 1] = y[ID1 + i - 1] + RX.lD[i] * RX.aD[i] * Ej / M.Pr end
    S.bursts = (S.bursts or 0) + 1
    S.scram = true
    S.cause = S.cause or "prompt"
    return { t = t_at, kind = "prompt", text = string.format("PROMPT CRITICAL: a burst of %.1f MJ, the fuel to %.0f K", Ej / 1e6, y[ITF]), E = Ej }
  elseif name == "melt" then
    S.melt, S.scram = true, true
    S.cause = "melt"
    return { t = t_at, kind = "melt", text = "MELTDOWN: the core has lost its shape" }
  else
    S.scram = true
    S.cause = name
    return { t = t_at, kind = "trip", cause = name, text = "SCRAM: " .. (EVENT_TEXT[name] or name) }
  end
end

-- ── ADVANCE: the one step (any dt) ──────────────────────────────────────────
-- Steps plant state S (y, the controls) through dt game seconds with model
-- M from game time `now`. Writes the rods' compositions in place. → rep =
-- { events = { … }, steps, left (s not taken: MAXSTEPS reached), peakTf, peakP }
function advance(S, M, dt, now)
  local rep = { events = {}, steps = 0, rejected = 0, left = 0, peakTf = S.y[ITF], peakP = 0, evals = 0 }
  local y = S.y
  local t, tend = 0, math.max(0, dt or 0)
  local t0 = now or 0
  if M.core.U <= 0 and not S.melt then
    -- (no fuel: the loops just relax to the room, exactly)
    local k = 1 / 600
    local f = math.exp(-k * tend)
    for _, i in ipairs({ ITF, ITP, ITS, ITK }) do y[i] = M.tamb + (y[i] - M.tamb) * f end
    for i = ID1, ID1 + 6 do y[i] = y[i] * math.exp(-RX.lD[i - ID1 + 1] * tend) end
    y[IMP] = M.mp_target + (y[IMP] - M.mp_target) * math.exp(-tend / RX.tau_pump)
    y[IMS] = M.ms_target + (y[IMS] - M.ms_target) * math.exp(-tend / RX.tau_pump)
    return rep
  end
  local h = clamp(S.h or 1.0, RX.HMIN, RX.HMAX)
  local o = derive(M, S, y, nil, {})
  -- events already true at the start (a layout change, a pump stopped)
  do
    local g = events_of(M, S, o)
    for _, nm in ipairs(EVENTS) do
      if g[nm] > 0 then
        rep.events[#rep.events + 1] = apply_event(M, S, y, nm, t0, o)
        o = derive(M, S, y, nil, {})
        g = events_of(M, S, o)
      end
    end
  end
  local F0 = {}
  derive(M, S, y, F0, {})
  while t < tend - 1e-12 do
    if rep.steps >= RX.MAXSTEPS then rep.left = tend - t break end
    local hh = math.min(h, tend - t)
    local J = jacobian(M, S, y, F0)
    local yn, err, F2 = ros_step(M, S, y, F0, hh, J)
    rep.steps = rep.steps + 1
    if not yn or err ~= err then
      h = hh * 0.25
      rep.rejected = rep.rejected + 1
      if h < RX.HMIN then h = RX.HMIN end
    elseif err > 1 and hh > RX.HMIN * 1.01 then
      rep.rejected = rep.rejected + 1
      h = math.max(RX.HMIN, hh * math.max(0.2, 0.9 * err ^ (-1 / 3)))
    else
      -- accepted: an event inside it?
      local g0 = events_of(M, S, o)
      local on = derive(M, S, yn, nil, {})
      local g1 = events_of(M, S, on)
      local first, theta = nil, 1
      for _, nm in ipairs(EVENTS) do
        if g0[nm] <= 0 and g1[nm] > 0 then
          local th = g0[nm] / (g0[nm] - g1[nm])
          if th < theta or not first then first, theta = nm, th end
        end
      end
      if first then
        -- the crossing's own instant: secant steps from y on the event function
        local lo, hi = 0, hh
        local glo, ghi = g0[first], g1[first]
        local ybest, Fbest, obest = yn, F2, on
        for _ = 1, 8 do
          local th = (glo - 0) / (glo - ghi)
          local hc = lo + (hi - lo) * clamp(th, 0.05, 0.95)
          if hi - lo < 1e-3 then break end
          local yc, _, Fc = ros_step(M, S, y, F0, hc, J)
          if not yc then break end
          local oc = derive(M, S, yc, nil, {})
          local gc = events_of(M, S, oc)[first]
          if gc > 0 then hi, ghi, ybest, Fbest, obest = hc, gc, yc, Fc, oc else lo, glo = hc, gc end
        end
        hh = hi
        yn, F2, on = ybest, Fbest, obest
      end
      clamp_state(yn)
      local dE = yn[IE] - y[IE]
      for i = 1, NY do y[i] = yn[i] end
      t = t + hh
      burn(M, dE)
      if y[ITF] > rep.peakTf then rep.peakTf = y[ITF] end
      if on.P > rep.peakP then rep.peakP = on.P end
      o = on
      if first then
        rep.events[#rep.events + 1] = apply_event(M, S, y, first, t0 + t, on)
        o = derive(M, S, y, nil, {})
        derive(M, S, y, F0, {})
        h = math.max(RX.HMIN * 10, math.min(h, 0.05))
      else
        F0 = F2
        if dE > 0 then derive(M, S, y, F0, {}) end   -- (the sums moved with the burn)
        local fac = (err > 0) and math.min(4, math.max(0.2, 0.9 * err ^ (-1 / 3))) or 4
        h = clamp(hh * fac, RX.HMIN, RX.HMAX)
        -- (a tiny last bite toward tend says nothing of the next step's size)
        if hh < h * 0.25 and t >= tend - 1e-12 then h = math.max(h, S.h or h) end
      end
    end
  end
  S.h = h
  S.t = (S.t or 0) + (tend - rep.left)
  for _, e in ipairs(rep.events) do S.ev[#S.ev + 1] = e; while #S.ev > 12 do table.remove(S.ev, 1) end end
  return rep
end

-- ── CONTROLS ────────────────────────────────────────────────────────────────
-- Why the reactor can't be started now (nil: it can). `o` = derive's out.
function startWhyNot(M, S, o)
  if S.melt then return "the core has melted" end
  if #M.why > 0 then return M.why[1] end
  if M.mp_target <= 0 then return "no coolant flow: start a primary pump (and power it)" end
  if S.scram then return "the reactor is tripped: reset the trip first" end
  return nil
end
-- Why a trip can't be reset now (nil: it can).
function resetWhyNot(M, S, o)
  if S.melt then return "the core has melted" end
  if not S.scram then return "it isn't tripped" end
  if (o.x or 1) < 0.99 then return "the rods are still going in" end
  local g = events_of(M, { prot = true, scram = false }, o)
  for _, nm in ipairs({ "power", "fuel", "subcool", "flow" }) do
    if g[nm] > 0 and nm ~= "flow" then return "still past its limit: " .. EVENT_TEXT[nm] end
  end
  return nil
end
function scram(S, now)
  if S.scram then return false end
  S.scram, S.cause = true, "hand"
  S.ev[#S.ev + 1] = { t = now or 0, kind = "trip", cause = "hand", text = "SCRAM by hand" }
  return true
end
function resetTrip(S) S.scram, S.cause = false, nil; S.xt = 1; S.mode = "manual" end
-- Go critical: the automatic controller to `set` (0..1 of the rating).
function startUp(S, set) S.mode, S.set = "auto", clamp(set or S.set or 0.5, 0.01, 1.1) end

-- ── READOUTS ────────────────────────────────────────────────────────────────
-- The period (s) from the rates: P's own e-folding time; nil = steady or falling slowly.
function period(M, S, y)
  local dy = {}
  local o = derive(M, S, y, dy, {})
  local yy = {}
  for i = 1, NY do yy[i] = y[i] + dy[i] * 0.05 end
  local o2 = derive(M, S, yy, nil, {})
  if o.P <= 1e-14 then return nil end
  local w = (o2.P - o.P) / (o.P * 0.05)
  if math.abs(w) < 1 / 36000 then return nil end
  return 1 / w
end

-- k with the rods all out at the plant's state now (what's in hand).
function kRodsOut(M, S, y)
  local _, k = reactivity(M.core, 0, y[ITF], y[ITP], y[IXE], y[ISM], S.melt)
  return k
end
-- The shutdown margin: ρ with every rod in, cold (room temperature), no xenon.
function shutdownMargin(M)
  local r = reactivity(M.core, 1, M.tamb, M.tamb, 0, 0, false)
  return -r
end

-- Can rod `item` go into channel `uid`? The refuelling rule: with every rod
-- in, cold and clean, the core must stay under SDM_MIN of critical, or the
-- rod that tips it would make it prompt critical in the Engineer's hands.
-- → nil | why, the k with that rod (rods in, cold)
SDM_MIN = 0.99
function loadWhyNot(pl, ch, uid, item, env)
  local c = ch[uid] or { rods = {} }
  local slots = RX.rods_full
  if #c.rods >= slots then return "the channel is full (eight rods)" end
  local trial = {}
  for k, v in pairs(ch) do trial[k] = v end
  local rods = {}
  for i, r in ipairs(c.rods) do rods[i] = r end
  rods[#rods + 1] = newRod(item)
  trial[uid] = { rods = rods }
  local C = coreOf(pl, trial)
  C.tamb = (env and env.tamb) or 288
  local _, k = reactivity(C, 1, C.tamb, C.tamb, 0, 0, false, true)
  if k >= SDM_MIN then
    return string.format("with every rod in it would be critical (k %.3f): no shutdown margin · add a control rod first", k), k
  end
  return nil, k
end

-- When a restart could reach critical again: steps the poisons forward with
-- no flux (I and Pm decay into Xe and Sm; Xe decays) and asks k with the
-- rods out at today's temperatures. → hours until restart (0 = now), the
-- xenon's peak (b, hours from now) | nil (never in 72 h)
function xenonForecast(M, S, y)
  local I, X, Pm, Sm = y[II], y[IXE], y[IPM], y[ISM]
  local peak, tpk = X, 0
  local hit = nil
  for hr = 0, 96 do
    local t = hr * 3600
    local eI, eX = math.exp(-RX.lI * t), math.exp(-RX.lX * t)
    local Xt = X * eX + I * RX.lI / (RX.lX - RX.lI) * (eI - eX)
    local St = Sm + Pm * (1 - math.exp(-RX.lPm * t))
    if Xt > peak then peak, tpk = Xt, hr end
    if not hit then
      local _, k = reactivity(M.core, 0, y[ITF], y[ITP], Xt, St, S.melt)
      if k >= 1.002 then hit = hr end
    end
  end
  return hit, peak, tpk
end

-- What limits the plant now: one line, the element. (the plan's §3.6)
function limitedBy(M, S, o)
  if S.melt then return "the core has melted", "melt" end
  if #M.why > 0 then return M.why[1], "layout" end
  if S.scram then return "tripped: " .. (EVENT_TEXT[S.cause or ""] or "SCRAM"), "trip" end
  local P = o.P or 0
  -- the poison pit, the fuel
  if S.mode == "auto" and P < (S.set or 0) * 0.97 and (o.x or 0) <= 0.01 then
    if xenonWorth(M, S.y) > 0.01 then
      return string.format("xenon: the rods are all out at %.0f %% (Xe −%.1f %%)", P * 100, xenonWorth(M, S.y) * 100), "xenon"
    end
    return string.format("fuel: the rods are all out at %.0f %%: the core can't hold %.0f %% (burnup)", P * 100, (S.set or 0) * 100), "fuel"
  end
  -- the heat path
  if M.turb and o.Qt and o.Qt > 0.95 * M.qmax then return string.format("the turbine: it admits %.0f kW of steam", M.qmax / 1000), "turbine" end
  if M.turb and o.Pe and o.Pe > 0.97 * M.kwe then return string.format("the generator's rating (%.0f kW)", M.kwe / 1000), "generator" end
  if o.Tk and o.Tk > 400 and M.radA + M.towerG > 0 then return string.format("the heat sink: the condenser at %.0f K (more radiators, or a tower)", o.Tk), "sink" end
  if o.Tk and o.Tk > 400 then return "no heat sink on the secondary", "sink" end
  if M.tsat < 400 and P > 0.05 then return "no pressuriser: the primary boils at 100 °C", "press" end
  if o.Qcore and o.Qcore > 1 and (o.Qlp + o.Qls) / o.Qcore > 0.1 then
    return string.format("pipe losses: %.0f %% of the heat leaks (insulate)", (o.Qlp + o.Qls) / o.Qcore * 100), "pipes"
  end
  if o.Qcore and o.Qcore > 1 and o.Tp - o.Ts > 60 then return string.format("the steam generator: %.0f K between the loops (a second one)", o.Tp - o.Ts), "hx" end
  if o.mpe and M.mp_design > 0 and o.mpe < 0.9 * M.mp_design then return string.format("coolant flow %.1f of %.1f kg/s", o.mpe, M.mp_design), "flow" end
  if S.mode == "auto" then return string.format("the setpoint (%.0f %%)", (S.set or 0) * 100), "set" end
  return "the rods (manual)", "rods"
end
-- The annunciator: what is wrong now, worst first. → { { text, level } … }
-- (level 2 red, 1 amber)
function alarms(M, S, o)
  local A = {}
  local function add(t, l) A[#A + 1] = { t, l } end
  if S.melt then add("MELTDOWN · the core has lost its shape", 2) end
  if (o.inv or 1) < 0.5 then add(string.format("CORE UNCOVERED · %d %% of the primary's water left", math.floor((o.inv or 0) * 100)), 2) end
  if (S.y[IDMG] or 0) > 0.05 and not S.melt then add(string.format("FUEL DAMAGE %d %%", math.floor(S.y[IDMG] * 100)), 2) end
  if (o.Qboil or 0) > 0.002 * M.Pr then add("RELIEF VALVE OPEN · the primary is boiling off", 2) end
  if o.Tf and o.Tf > RX.trip_Tf then add(string.format("FUEL OVERTEMPERATURE %.0f K", o.Tf), 2) end
  if S.scram then add("TRIPPED · " .. (EVENT_TEXT[S.cause or ""] or "SCRAM"), 2) end
  if o.Tp and o.Tp > M.tsat - 25 then add(string.format("PRIMARY %.0f K · %.0f K from boiling", o.Tp, M.tsat - o.Tp), 1) end
  if M.mp_design > 0 and (o.mpe or 0) < 0.8 * M.mp_design and ((o.Qcore or 0) > 0.002 * M.Pr) then add(string.format("LOW COOLANT FLOW %.1f kg/s", o.mpe or 0), 1) end
  if not S.prot then add("PROTECTION BYPASSED", 1) end
  if (o.Tk or 0) > 420 then add(string.format("CONDENSER HOT %.0f K", o.Tk), 1) end
  return A
end

-- Xenon's worth now (Δk/k, positive).
function xenonWorth(M, y)
  local C = M.core
  if C.U <= 0 then return 0 end
  local r0 = reactivity(C, clamp(y[IX], 0, 1), y[ITF], y[ITP], 0, y[ISM], false)
  local r1 = reactivity(C, clamp(y[IX], 0, 1), y[ITF], y[ITP], y[IXE], y[ISM], false)
  return r0 - r1
end
function samariumWorth(M, y)
  local C = M.core
  if C.U <= 0 then return 0 end
  local r0 = reactivity(C, clamp(y[IX], 0, 1), y[ITF], y[ITP], y[IXE], 0, false)
  local r1 = reactivity(C, clamp(y[IX], 0, 1), y[ITF], y[ITP], y[IXE], y[ISM], false)
  return r0 - r1
end
-- The core's mean burnup (FIMA) and its most-burnt channel.
function burnup(M)
  local s, n, hi = 0, 0, 0
  for _, e in ipairs(M.core.channels) do
    for _, r in ipairs(e.rods) do s = s + r.fp; n = n + 1; if r.fp > hi then hi = r.fp end end
  end
  return n > 0 and s / n or 0, hi
end
-- The dose share for base_shield (its `rad` is lethal shares an hour at 5 m at
-- full output): the heat the core makes over its rating, and its rad.
function radOf(M, o)
  local share = (o.Qcore or 0) / math.max(M.Pr, 1)
  return 0.083 * M.Pr / 1000, share
end
function pct(x) return math.floor((x or 0) * 100 + 0.5) end
