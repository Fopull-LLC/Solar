-- FLUIDS — the rulebook of a base's pipes and tanks (sandbox plan S7,
-- work/sandbox/PLAN.md §3.3, §3.6; docs/base-building.md §17).
--
-- Pure, like reactor.lua and rooms.lua: no scene access, its globals are its
-- API, it loads from disk in a luajit test (tests/smoke_fluids.lua).
-- fluid_net.lua (the scene half) finds the networks in the structures'
-- records, steps them on its clock and couples them to the rooms, the
-- reactors and the base grid.
--
-- ── WHAT FLOWS ──────────────────────────────────────────────────────────────
-- Water, coolant (demineralised borated water), fuel (RP-1, 10 kg a unit),
-- oxygen, nitrogen and hydrogen, with their real densities and molar masses.
-- A network carries one substance: the one its tanks hold (two in one
-- network is a mistake the readouts name, and nothing flows).
--
-- ── THE NETWORK (union-find over the pieces' ports, on change) ──────────────
-- Ports that meet (the S6 port snap: coincident, facing) are one NODE. A piece
-- is an ELEMENT between its ports' nodes, or a NODE of its own:
--   pipe, elbow, tee, riser  a conductance g = q_r / Δp_r for its length and
--                   bore (Darcy at its rated velocity, linearised there)
--   tank (liquid)   a node holding x kg; its outlet pressure p = P_ATM + ρgh
--                   (a nitrogen-blanketed tank, h = x / ρA): p = a·x + c
--   bottle (gas)    a node holding x kg; p = x·R·T / (M·V)
--   pump            q = g·(p_in − p_out + H0) on a straight-line curve from
--                   its shut-off head H0 to its free delivery q0, never
--                   backwards (it stalls: the pressure it faces is over H0);
--                   off, it blocks
--   valve           shut: blocks; open: a conductance
--   check valve     a conductance that never flows backwards
--   regulator       holds its outlet at its set pressure while its inlet is
--                   over it (an unknown flow and a pinned pressure), wide open
--                   under it, shut if the outlet is over it
--   gauge           an inline fitting that reads its node's pressure
--   room outlet     discharges into the room it stands in (a node at the
--                   room's pressure; it shuts while the room is at 1 atm)
--   vent            discharges to the outside
--   consumer        a small tank with a drain the scene sets: the O2
--                   Generator's water cell, a reactor's primary (its makeup
--                   nozzle: the primary's pressure, its inventory, the coolant
--                   it boils off and loses at a break)
--
-- ── THE SOLVE (closed form between events; E's rule) ────────────────────────
-- Every element's flow is affine in the node pressures and every tank's
-- pressure is affine in its contents, so for a given set of MODES (each
-- tank normal / full / starved / dry, each pump running / stalled, each check
-- valve open / closed, each regulator throttling / open / shut) the tanks obey
-- x' = A·x + b exactly. `advance` takes that linear ODE's exact solution (the
-- matrix exponential of [[A, b], [0, 0]] by scaling and squaring), finds the
-- first instant any mode's guard crosses zero along it (sampled, then
-- bisected to 1e-12 of the step), switches that mode and carries on. One call
-- of any dt lands where any number of small calls do (smoke_fluids checks a
-- day in one step against 86,400 steps), and a structure is caught up on
-- load in one call (capped at CATCH_MAX).
--
-- Units: SI. Pressures in Pa, contents in kg, flows in kg/s.

P_ATM = 101325
G0 = 9.81
RGAS = 8.314462
T_GAS = 293.15
CATCH_MAX = 30 * 86400
PIPE_Y = 0.6

SUB = {
  water   = { label = "Water", kind = "liquid", rho = 998, col = { 0.30, 0.62, 1.0 } },
  coolant = { label = "Coolant", kind = "liquid", rho = 998, col = { 0.35, 0.95, 0.95 }, desc = "demineralised borated water" },
  fuel    = { label = "Fuel", kind = "liquid", rho = 810, col = { 1.0, 0.70, 0.25 }, desc = "RP-1 kerosene" },
  o2      = { label = "Oxygen", kind = "gas", M = 0.031999, col = { 0.40, 0.75, 1.0 } },
  n2      = { label = "Nitrogen", kind = "gas", M = 0.028013, col = { 0.75, 0.75, 0.80 } },
  h2      = { label = "Hydrogen", kind = "gas", M = 0.002016, col = { 1.0, 0.45, 0.45 } },
}
-- kg in one atm·m³ (room_air's unit) of a gas at 0 °C: O2 1.429, N2 1.251
ATM_M3 = { o2 = 1.429, n2 = 1.251, h2 = 0.0899 }

-- Pipe bores: inside diameter (m), rated flow at 2 m/s of water (kg/s), and
-- the Darcy drop per metre at that flow (f 0.022): g·L = q_r / (Δp/m).
-- Gases at a line's few bar carry about 1 % of the mass for the same drop.
BORE = {
  DN25 = { label = "DN25", id = 0.0266 },
  DN50 = { label = "DN50", id = 0.0525 },
}
for _, b in pairs(BORE) do
  local A = math.pi * b.id * b.id / 4
  b.area = A
  b.qr = 998 * 2.0 * A
  b.dpm = 0.022 * 998 * 2.0 * 2.0 / (2 * b.id)
  b.gm = b.qr / b.dpm            -- kg·m / (s·Pa)
end
GAS_K = 0.01

local min, max, abs, exp, log, sqrt, floor = math.min, math.max, math.abs, math.exp, math.log, math.sqrt, math.floor

function subOf(name) return SUB[name] end
-- a pipe run's conductance (kg/s per Pa) for `len` m of `bore` carrying `sub`
function pipeG(bore, len, sub)
  local b = BORE[bore] or BORE.DN25
  local g = b.gm / max(len or 1, 0.05)
  if SUB[sub] and SUB[sub].kind == "gas" then g = g * GAS_K end
  return g
end
-- a liquid tank's (a, c): p = a·x + c at its outlet
function liquidAC(sub, area) return G0 / max(area, 1e-6), P_ATM end
-- a gas vessel's a: p = a·x
function gasA(sub, V) local s = SUB[sub] or SUB.o2; return RGAS * T_GAS / ((s.M or 0.032) * max(V, 1e-6)) end
-- saturation pressure of water (Pa) at T (K): a fit good to a few % from 300 to 620 K
-- 2 H2O → 2 H2 + O2: the water a mass of O2 takes, and the hydrogen it makes (kg)
function electrolysis(kgO2)
  local mol = (kgO2 or 0) / 0.031999
  return mol * 2 * 0.018015, mol * 2 * 0.002016
end
function psatWater(T)
  if T <= 280 then return 1000 end
  return 101325 * exp(13.1 * (1 - 373.15 / T)) * (1 - 0.00028 * max(0, T - 373.15))
end

-- ── the linear algebra (dense, small) ───────────────────────────────────────
local function lu(A, n)
  local P = {}
  for i = 1, n do P[i] = i end
  for k = 1, n do
    local p, best = k, abs(A[k][k])
    for i = k + 1, n do local v = abs(A[i][k]); if v > best then p, best = i, v end end
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
local function lusolve(F, b)
  local A, P, n = F.A, F.P, F.n
  local x = {}
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
local function matmul(A, B, n)
  local C = {}
  for i = 1, n do
    local Ai, Ci = A[i], {}
    for j = 1, n do
      local s = 0
      for k = 1, n do s = s + Ai[k] * B[k][j] end
      Ci[j] = s
    end
    C[i] = Ci
  end
  return C
end
-- exp(t·M) for an n×n M: scaling and squaring of an 18-term Taylor series
function expm(M, n, t)
  local nrm = 0
  for i = 1, n do
    local s = 0
    for j = 1, n do s = s + abs(M[i][j]) end
    if s > nrm then nrm = s end
  end
  nrm = nrm * abs(t)
  local sq = 0
  if nrm > 0.25 then sq = math.ceil(log(nrm / 0.25) / log(2)) end
  local h = t / (2 ^ sq)
  local X = {}
  for i = 1, n do X[i] = {}; for j = 1, n do X[i][j] = M[i][j] * h end end
  local E, T = {}, {}
  for i = 1, n do E[i], T[i] = {}, {}; for j = 1, n do local v = (i == j) and 1 or 0; E[i][j] = v; T[i][j] = v end end
  for k = 1, 18 do
    T = matmul(T, X, n)
    local inv = 1 / k
    local small = true
    for i = 1, n do for j = 1, n do T[i][j] = T[i][j] * inv; E[i][j] = E[i][j] + T[i][j]; if abs(T[i][j]) > 1e-18 then small = false end end end
    if small then break end
  end
  for _ = 1, sq do E = matmul(E, E, n) end
  return E
end

-- ── the network's instantaneous solve for a set of modes ────────────────────
-- net = { nodes = { { kind = "junction"|"tank"|"fixed", a, c, cap, p (fixed), r (drain kg/s) } },
--         els = { { kind = "cond"|"pump"|"check"|"valve"|"reg"|"open", u, v, g, H, pset, on } } }
-- st = { x = { [node] = kg }, tm = { [node] = "N"|"F"|"S"|"D" }, em = { [el] = mode } }
-- A pump's mode: "on" | "stall"; a check valve's: "open" | "shut"; a
-- regulator's: "T" (throttling) | "O" (wide open) | "X" (shut).
local function el_active(e, m)
  if e.kind == "cond" then return "g" end
  if e.kind == "valve" then return e.on and "g" or nil end
  if e.kind == "check" then if m == "shut" then return nil end return "g" end
  if e.kind == "pump" then if not e.on or m == "stall" then return nil end return "pump" end
  if e.kind == "reg" then if m == "X" then return nil elseif m == "T" then return "T" end return "g" end
  if e.kind == "switch" then return e.on and "g" or nil end
  return nil
end

-- The unknowns and the matrix for these modes. → plan (or nil, why)
local function plan_of(net, st)
  local nodes, els = net.nodes, net.els
  local idx, free = {}, {}
  for i, N in ipairs(nodes) do
    local m = st.tm[i]
    local known
    if N.kind == "fixed" then known = true
    elseif N.kind == "tank" then known = (m == "N" or m == "S" or m == nil)
    else known = false end
    if not known then free[#free + 1] = i; idx[i] = #free end
  end
  local nf = #free
  local regs = {}
  for k, e in ipairs(els) do
    if el_active(e, st.em[k]) == "T" then
      if idx[e.v] then regs[#regs + 1] = k else st.em[k] = "O" end
    end
  end
  local n = nf + #regs
  local A = {}
  for i = 1, n do A[i] = {}; for j = 1, n do A[i][j] = 0 end end
  local function stamp(i, j, g)
    local ii, jj = idx[i], idx[j]
    if ii then A[ii][ii] = A[ii][ii] + g end
    if jj then A[jj][jj] = A[jj][jj] + g end
    if ii and jj then A[ii][jj] = A[ii][jj] - g; A[jj][ii] = A[jj][ii] - g end
  end
  for k, e in ipairs(els) do
    local act = el_active(e, st.em[k])
    if act == "g" or act == "pump" then stamp(e.u, e.v, e.g) end
  end
  for r, k in ipairs(regs) do
    local e = els[k]
    local row = nf + r
    if idx[e.u] then A[idx[e.u]][row] = A[idx[e.u]][row] + 1 end       -- KCL: q leaves u
    A[idx[e.v]][row] = A[idx[e.v]][row] - 1                            -- and enters v
    A[row][idx[e.v]] = 1                                                -- p_v = pset
  end
  -- (a free node with nothing joined: pin it so the matrix is whole)
  for i = 1, nf do if A[i][i] == 0 then A[i][i] = 1; free.lone = free.lone or {}; free.lone[i] = true end end
  local F = (n > 0) and lu(A, n) or { n = 0 }
  if n > 0 and not F then return nil, "singular" end
  return { idx = idx, free = free, nf = nf, regs = regs, n = n, F = F }
end

-- Solve at contents x (a table node → kg): → p (node → Pa), q (el → kg/s), inflow (node → kg/s)
local function solve_at(net, st, pl, x)
  local nodes, els = net.nodes, net.els
  local p = {}
  for i, N in ipairs(nodes) do
    if not pl.idx[i] then
      if N.kind == "fixed" then p[i] = N.p or P_ATM
      elseif st.tm[i] == "S" then p[i] = N.c or 0
      else p[i] = (N.a or 0) * (x[i] or 0) + (N.c or 0) end
    end
  end
  if pl.n > 0 then
    local rhs = {}
    for i = 1, pl.n do rhs[i] = 0 end
    for k, e in ipairs(els) do
      local act = el_active(e, st.em[k])
      if act == "g" or act == "pump" then
        local iu, iv = pl.idx[e.u], pl.idx[e.v]
        if iu and not iv then rhs[iu] = rhs[iu] + e.g * p[e.v] end
        if iv and not iu then rhs[iv] = rhs[iv] + e.g * p[e.u] end
        if act == "pump" then
          -- q = g (pu − pv + H): +gH leaves u, enters v
          if iu then rhs[iu] = rhs[iu] - e.g * e.H end
          if iv then rhs[iv] = rhs[iv] + e.g * e.H end
        end
      end
    end
    for r, k in ipairs(pl.regs) do
      local e = els[k]
      if not pl.idx[e.u] then end
      rhs[pl.nf + r] = e.pset
      -- (an upstream that is known: the flow still leaves it; nothing to stamp)
    end
    -- free nodes' own injections: a full tank absorbs its drain r; a dry one nothing
    for j, i in ipairs(pl.free) do
      local N = nodes[i]
      if N.kind == "tank" and st.tm[i] == "F" then rhs[j] = rhs[j] - (N.r or 0) end
      if pl.free.lone and pl.free.lone[j] then rhs[j] = (N.kind == "tank") and ((N.a or 0) * (x[i] or 0) + (N.c or 0)) or 0 end
    end
    local sol = lusolve(pl.F, rhs)
    for j, i in ipairs(pl.free) do p[i] = sol[j] end
    pl.regq = {}
    for r, k in ipairs(pl.regs) do pl.regq[k] = sol[pl.nf + r] end
  end
  local q, inflow = {}, {}
  for i = 1, #nodes do inflow[i] = 0 end
  for k, e in ipairs(els) do
    local act = el_active(e, st.em[k])
    local f = 0
    if act == "g" then f = e.g * (p[e.u] - p[e.v])
    elseif act == "pump" then f = e.g * (p[e.u] - p[e.v] + e.H)
    elseif act == "T" then f = pl.regq and pl.regq[k] or 0 end
    q[k] = f
    inflow[e.u] = inflow[e.u] - f
    inflow[e.v] = inflow[e.v] + f
  end
  return p, q, inflow
end

-- The tanks' rates and every guard as affine maps of the normal tanks'
-- contents: x' = A x + b; guard_k = G_k·x + h_k (≥ 0 while the modes hold).
-- → lin = { T (normal tank nodes), A, b, guards = { { h, G, what, k } } }
local function linear(net, st, pl)
  local T = {}
  for i, N in ipairs(net.nodes) do if N.kind == "tank" and (st.tm[i] == "N" or st.tm[i] == nil) then T[#T + 1] = i end end
  local n = #T
  local base = {}
  for i, N in ipairs(net.nodes) do base[i] = st.x[i] or 0 end
  for _, i in ipairs(T) do base[i] = 0 end
  local runs = {}
  local function run(x)
    local p, q, inflow = solve_at(net, st, pl, x)
    local rate = {}
    for a, i in ipairs(T) do rate[a] = inflow[i] - (net.nodes[i].r or 0) end
    local g = {}
    -- the guards of the modes now held
    for i, N in ipairs(net.nodes) do
      local m = st.tm[i]
      if N.kind == "tank" then
        if m == "F" then g[#g + 1] = { p[i] - ((N.a or 0) * (N.cap or 0) + (N.c or 0)) + 1e-9 * (1 + abs(p[i])), "unfull", i }
        elseif m == "S" then
          g[#g + 1] = { inflow[i], "dry", i }
          g[#g + 1] = { (N.r or 0) - inflow[i], "fill", i }
        elseif m == "D" then g[#g + 1] = { (N.c or 0) - p[i], "wet", i }
        end
      end
    end
    for k, e in ipairs(net.els) do
      local m = st.em[k]
      local act = el_active(e, m)
      if e.kind == "pump" and e.on then
        if m == "stall" then g[#g + 1] = { -(p[e.u] - p[e.v] + e.H), "unstall", k, true }
        else g[#g + 1] = { q[k], "stall", k, true } end
      elseif e.kind == "check" then
        if m == "shut" then g[#g + 1] = { -(p[e.u] - p[e.v]), "ckopen", k, true }
        else g[#g + 1] = { q[k], "ckshut", k, true } end
      elseif e.kind == "reg" then
        if m == "T" then
          g[#g + 1] = { q[k], "regX", k, true }
          g[#g + 1] = { p[e.u] - e.pset, "regO", k, true }
        elseif m == "X" then
          -- (shut: stays while the outlet is at or over its set, or the inlet under the outlet)
          g[#g + 1] = { max(p[e.v] - e.pset, p[e.v] - p[e.u]), "regOpen", k, true }
        else
          g[#g + 1] = { e.pset - p[e.v], "regT", k, true }
          g[#g + 1] = { q[k], "regX2", k, true }
        end
      end
    end
    return rate, g, p, q, inflow
  end
  local r0, g0, p0, q0, in0 = run(base)
  local A = {}
  for a = 1, n do A[a] = {} end
  local Gm = {}
  for k = 1, #g0 do Gm[k] = {} end
  for b, i in ipairs(T) do
    local x = {}
    for k, v in pairs(base) do x[k] = v end
    x[i] = 1
    local r1, g1 = run(x)
    for a = 1, n do A[a][b] = r1[a] - r0[a] end
    for k = 1, #g0 do Gm[k][b] = g1[k][1] - g0[k][1] end
  end
  local guards = {}
  for k, gg in ipairs(g0) do guards[k] = { h = gg[1], G = Gm[k], what = gg[2], at = gg[3], el = gg[4] } end
  -- the normal tanks' own bounds: empty, full
  for a, i in ipairs(T) do
    local N = net.nodes[i]
    local G1, G2 = {}, {}
    for b = 1, n do G1[b] = (a == b) and 1 or 0; G2[b] = (a == b) and -1 or 0 end
    guards[#guards + 1] = { h = 0, G = G1, what = "empty", at = i }
    if N.cap then guards[#guards + 1] = { h = N.cap, G = G2, what = "full", at = i } end
  end
  return { T = T, n = n, A = A, b = r0, guards = guards }
end

local function gval(gd, xv)
  local s = gd.h
  for b = 1, #xv do s = s + gd.G[b] * xv[b] end
  return s
end

-- Make the modes consistent with the state now (an instant: no time passes).
local function settle(net, st, rep)
  for _ = 1, 40 do
    local pl = plan_of(net, st)
    if not pl then return nil end
    local lin = linear(net, st, pl)
    local xv = {}
    for a, i in ipairs(lin.T) do xv[a] = st.x[i] or 0 end
    local flip = nil
    for _, gd in ipairs(lin.guards) do
      local v = gval(gd, xv)
      local tol = 1e-9 * (1 + abs(gd.h))
      if gd.what == "empty" then
        -- at empty and still falling → starved
        local a = nil
        for k, i in ipairs(lin.T) do if i == gd.at then a = k end end
        local rate = lin.b[a]
        for b = 1, lin.n do rate = rate + lin.A[a][b] * xv[b] end
        if v <= 1e-9 and rate < -1e-12 then flip = gd break end
      elseif gd.what == "full" then
        local a = nil
        for k, i in ipairs(lin.T) do if i == gd.at then a = k end end
        local rate = lin.b[a]
        for b = 1, lin.n do rate = rate + lin.A[a][b] * xv[b] end
        if v <= 1e-9 * (1 + (net.nodes[gd.at].cap or 0)) and rate > 1e-12 then flip = gd break end
      elseif v < -tol then flip = gd break end
    end
    if not flip then return pl, lin end
    local w = flip.what
    if w == "empty" then st.tm[flip.at] = "S"; st.x[flip.at] = 0
    elseif w == "full" then st.tm[flip.at] = "F"; st.x[flip.at] = net.nodes[flip.at].cap
    elseif w == "unfull" then st.tm[flip.at] = "N"
    elseif w == "dry" then st.tm[flip.at] = "D"
    elseif w == "fill" then st.tm[flip.at] = "N"
    elseif w == "wet" then st.tm[flip.at] = "S"
    elseif w == "stall" then st.em[flip.at] = "stall"
    elseif w == "unstall" then st.em[flip.at] = "on"
    elseif w == "ckshut" then st.em[flip.at] = "shut"
    elseif w == "ckopen" then st.em[flip.at] = "open"
    elseif w == "regX" or w == "regX2" then st.em[flip.at] = "X"
    elseif w == "regO" then st.em[flip.at] = "O"
    elseif w == "regT" then st.em[flip.at] = "T"
    elseif w == "regOpen" then
      local e = net.els[flip.at]
      st.em[flip.at] = "T"
    end
    if rep then rep.events[#rep.events + 1] = w end
  end
  -- (40 flips and still not consistent: take the modes as they stand)
  local pl = plan_of(net, st)
  if not pl then return nil end
  return pl, linear(net, st, pl)
end

-- A fresh state for a network: tanks at x0 (or empty), every mode at rest.
function newState(net)
  local st = { x = {}, tm = {}, em = {} }
  for i, N in ipairs(net.nodes) do
    if N.kind == "tank" then st.x[i] = math.min(N.cap or math.huge, N.x0 or 0); st.tm[i] = "N" end
  end
  for k, e in ipairs(net.els) do
    if e.kind == "pump" then st.em[k] = "on" elseif e.kind == "check" then st.em[k] = "open" elseif e.kind == "reg" then st.em[k] = "T" end
  end
  return st
end

local SAMPLES = 24
-- Advance network `net` in state `st` through dt s. → rep = { events, segs, moved (kg through
-- each element), q (the flows at the end), p (the pressures at the end) }
function advance(net, st, dt, rep)
  rep = rep or { events = {}, segs = 0 }
  rep.events = rep.events or {}
  rep.segs = rep.segs or 0
  rep.moved = rep.moved or {}
  if not dt or dt < 0 then dt = 0 end
  local left = dt
  local guard = 0
  while true do
    guard = guard + 1
    local pl, lin = settle(net, st, rep)
    if not pl then rep.err = "singular"; return rep end
    -- the flows now (the readouts, and what each element moves this segment)
    if left <= 0 or guard > 400 then
      local p, q, inflow = solve_at(net, st, pl, st.x)
      rep.p, rep.q, rep.inflow = p, q, inflow
      return rep
    end
    local n = lin.n
    -- [[A b] [0 0]]
    local M = {}
    for i = 1, n + 1 do M[i] = {}; for j = 1, n + 1 do M[i][j] = 0 end end
    for a = 1, n do for b = 1, n do M[a][b] = lin.A[a][b] end; M[a][n + 1] = lin.b[a] end
    local x0 = {}
    for a, i in ipairs(lin.T) do x0[a] = st.x[i] or 0 end
    local function at(t)
      local E = expm(M, n + 1, t)
      local x = {}
      for a = 1, n do
        local s = E[a][n + 1]
        for b = 1, n do s = s + E[a][b] * x0[b] end
        x[a] = s
      end
      return x
    end
    local still = true
    for a = 1, n do
      if abs(lin.b[a]) > 1e-15 then still = false end
      for b = 1, n do if abs(lin.A[a][b]) > 1e-15 then still = false end end
    end
    -- the first guard to cross
    local te, which = left, nil
    if not still then
      local h = left / SAMPLES
      local Eh = expm(M, n + 1, h)
      local xa = x0
      local ga = {}
      for k, gd in ipairs(lin.guards) do ga[k] = gval(gd, xa) end
      for s = 1, SAMPLES do
        local xb = {}
        for a = 1, n do
          local v = Eh[a][n + 1]
          for b = 1, n do v = v + Eh[a][b] * xa[b] end
          xb[a] = v
        end
        local hit, hk = nil, nil
        for k, gd in ipairs(lin.guards) do
          local gb = gval(gd, xb)
          local tol = 1e-12 * (1 + abs(gd.h) + abs(ga[k]))
          if ga[k] >= -tol and gb < -tol then
            -- the crossing in (t_a, t_b]: bisect
            local lo, hi = (s - 1) * h, s * h
            for _ = 1, 60 do
              local mid = 0.5 * (lo + hi)
              if gval(gd, at(mid)) < -tol then hi = mid else lo = mid end
              if hi - lo <= 1e-12 * max(1, dt) then break end
            end
            if not hit or hi < hit then hit, hk = hi, k end
          end
          ga[k] = gb
        end
        if hit then te, which = hit, lin.guards[hk] break end
        xa = xb
      end
    end
    -- go to te
    local xe = still and x0 or ((te == left and which == nil) and at(te) or at(te))
    -- what each element moved: the flow at the ends, averaged (exact for a
    -- straight line; a curve's error is bounded by the guard steps)
    local p0, q0 = solve_at(net, st, pl, st.x)
    for a, i in ipairs(lin.T) do
      local N = net.nodes[i]
      st.x[i] = math.max(0, math.min(N.cap or math.huge, xe[a]))
    end
    local p1, q1 = solve_at(net, st, pl, st.x)
    for k = 1, #net.els do rep.moved[k] = (rep.moved[k] or 0) + 0.5 * ((q0[k] or 0) + (q1[k] or 0)) * te end
    -- drains served: a full tank or a starved one passes what it gets
    rep.served = rep.served or {}
    local _, _, in1 = solve_at(net, st, pl, st.x)
    for i, N in ipairs(net.nodes) do
      if N.kind == "tank" and (N.r or 0) ~= 0 then
        local m = st.tm[i]
        local got = (m == "S") and max(0, in1[i]) or ((m == "D") and 0 or (N.r or 0))
        rep.served[i] = (rep.served[i] or 0) + got * te
      end
    end
    left = left - te
    rep.segs = rep.segs + 1
    if which then
      rep.events[#rep.events + 1] = which.what
      local w, i = which.what, which.at
      if w == "empty" then st.tm[i] = "S"; st.x[i] = 0
      elseif w == "full" then st.tm[i] = "F"; st.x[i] = net.nodes[i].cap
      end
      -- (the rest flip in settle at the top of the next segment)
    end
    if left <= 1e-12 * max(1, dt) then left = 0 end
  end
end

-- ── the network from a structure's records ──────────────────────────────────
local function rot(yaw, x, z)
  local c, s = math.cos(yaw or 0), math.sin(yaw or 0)
  return x * c + z * s, -x * s + z * c
end
-- a fluid port in its structure's frame: x, y, z, nx, nz
function portAt(p, pt)
  local dx, dz = rot(p.yaw, pt.x, pt.z)
  local nx, nz = rot(p.yaw, pt.nx, pt.nz)
  return (p.x or 0) + dx, (p.y or 0) + (pt.y or PIPE_Y), (p.z or 0) + dz, nx, nz
end
-- the fluid ports of a piece (a fluid piece's every port; another piece's `fluid` ones)
function fluidPorts(d)
  if not (d and d.ports) then return nil end
  local out = nil
  for _, pt in ipairs(d.ports) do
    if d.fl or pt.fluid then out = out or {}; out[#out + 1] = pt end
  end
  return out
end

-- Build every fluid network of one structure. ext(kind, part, def) gives the
-- scene's live figures (a room's pressure, a primary's, a consumer's drain).
-- → { nets = { net … }, byUid = { [uid] = { net, node | el } }, open = { port … } }
-- net = { nodes, els, sub, parts = { uid … }, why, segs (overlay polylines) }
function build(rec, defs, ext)
  local ports, pieces = {}, {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    local fp = d and math.abs(p.pitch or 0) < 1e-3 and fluidPorts(d)
    if fp then
      -- a fluid piece is one element or node; another piece's fluid ports are
      -- one each, grouped by their `loop` tag (an O2 Generator's water and
      -- its hydrogen are two networks), their kind their `role`
      local groups, order = {}, {}
      for _, pt in ipairs(fp) do
        local x, y, z, nx, nz = portAt(p, pt)
        local P = { uid = p.uid, name = pt.name, x = x, y = y, z = z, nx = nx, nz = nz, k = #ports + 1, part = p, def = d, bore = pt.bore or (d.fl and d.fl.bore) or "DN25" }
        ports[#ports + 1] = P
        local key = d.fl and "f" or (pt.loop or pt.name)
        if not groups[key] then groups[key] = { part = p, def = d, ports = {}, role = (not d.fl) and pt.role or nil, port = pt.name }; order[#order + 1] = key end
        local L = groups[key].ports
        L[#L + 1] = P
      end
      for _, key in ipairs(order) do pieces[#pieces + 1] = groups[key] end
    end
  end
  -- ports that meet: one node (union-find)
  local U = {}
  for i = 1, #ports do U[i] = i end
  local function find(a) while U[a] ~= a do U[a] = U[U[a]]; a = U[a] end return a end
  local partner = {}
  for a = 1, #ports do
    local A = ports[a]
    for b = a + 1, #ports do
      local B = ports[b]
      if A.uid ~= B.uid and abs(A.x - B.x) < 0.06 and abs(A.z - B.z) < 0.06 and abs(A.y - B.y) < 0.06 and (A.nx * B.nx + A.nz * B.nz) < -0.9 then
        partner[a], partner[b] = b, a
        local ra, rb = find(a), find(b)
        if ra ~= rb then U[rb] = ra end
      end
    end
  end
  -- the pieces' own joins: which ports are one network (every port of a piece
  -- is, except a steam generator-like split: none of the fluid pieces split)
  local PU = {}
  for i = 1, #ports do PU[i] = find(i) end
  local NU = {}
  for i = 1, #ports do NU[i] = PU[i] end
  local function nfind(a) while NU[a] ~= a do NU[a] = NU[NU[a]]; a = NU[a] end return a end
  for _, pc in ipairs(pieces) do
    for i = 2, #pc.ports do
      local ra, rb = nfind(pc.ports[1].k), nfind(pc.ports[i].k)
      if ra ~= rb then NU[rb] = ra end
    end
  end
  local netOf = {}
  local out = { nets = {}, byUid = {}, open = {} }
  local function net_for(k)
    local r = nfind(k)
    local n = netOf[r]
    if not n then
      n = { nodes = {}, els = {}, parts = {}, nodeOfPort = {}, subs = {}, segs = {}, why = {}, open = {}, labels = {} }
      netOf[r] = n
      out.nets[#out.nets + 1] = n
    end
    return n
  end
  local function node_of(n, k)
    local r = PU[k]
    local i = n.nodeOfPort[r]
    if not i then
      local P = ports[k]
      n.nodes[#n.nodes + 1] = { kind = "junction", x = P.x, y = P.y, z = P.z, port = true }
      i = #n.nodes
      n.nodeOfPort[r] = i
    end
    return i
  end
  for _, pc in ipairs(pieces) do
    local p, d = pc.part, pc.def
    local n = net_for(pc.ports[1].k)
    n.parts[#n.parts + 1] = p.uid
    local fl = d.fl or {}
    local kind = fl.kind or pc.role or "pipe"
    if pc.role == "consumer" then fl = { kind = "consumer", sub = "water", V = (d.life and d.life.water or 20) / 1000, A = 0.05 } end
    local pn = {}
    for i, P in ipairs(pc.ports) do
      pn[i] = node_of(n, P.k)
      -- (an O2 Generator's unpiped hydrogen port vents by design: no open end)
      if not partner[P.k] and kind ~= "h2" and kind ~= "src" then n.open[#n.open + 1] = P; out.open[#out.open + 1] = P end
    end
    local cx, cy, cz = p.x or 0, (p.y or 0) + PIPE_Y, p.z or 0
    local ent = { net = n, kind = kind, part = p, def = d, ports = pn, port = pc.port }
    if pc.role then
      out.byPort = out.byPort or {}
      out.byPort[tostring(p.uid) .. ":" .. tostring(pc.port)] = ent
      if not out.byUid[p.uid] then out.byUid[p.uid] = ent end
    else
      out.byUid[p.uid] = ent
    end
    if kind == "h2" then ent.node = pn[1]; n.h2 = n.h2 or {}; n.h2[#n.h2 + 1] = ent end
    -- (X6) a machine's product into the network's tanks (the electrolyser's fuel nozzle): fluid_net couples it
    if kind == "src" then ent.node = pn[1]; n.src = n.src or {}; n.src[#n.src + 1] = ent end
    local function add_el(e) n.els[#n.els + 1] = e; e.uid = p.uid; return #n.els end
    local function add_node(N) n.nodes[#n.nodes + 1] = N; N.uid = p.uid; N.x, N.y, N.z = cx, cy, cz; return #n.nodes end
    local bore = fl.bore or "DN25"
    if kind == "pipe" then
      -- a run between its ports (a tee: a hub node, a run to each port)
      local len = fl.len or 1
      if #pn == 2 then
        ent.el = add_el({ kind = "cond", u = pn[1], v = pn[2], len = len, bore = bore })
        n.segs[#n.segs + 1] = { uid = p.uid, el = ent.el, a = { pc.ports[1].x, pc.ports[1].y, pc.ports[1].z }, b = { pc.ports[2].x, pc.ports[2].y, pc.ports[2].z } }
      else
        local hub = add_node({ kind = "junction" })
        ent.node = hub
        ent.els = {}
        for i = 1, #pn do
          local e = add_el({ kind = "cond", u = pn[i], v = hub, len = len / #pn, bore = bore })
          ent.els[#ent.els + 1] = e
          n.segs[#n.segs + 1] = { uid = p.uid, el = e, a = { pc.ports[i].x, pc.ports[i].y, pc.ports[i].z }, b = { cx, pc.ports[i].y, cz } }
        end
      end
    elseif kind == "pump" or kind == "valve" or kind == "check" or kind == "reg" or kind == "gauge" then
      local e = { kind = (kind == "gauge") and "cond" or kind, u = pn[1], v = pn[2] or pn[1], len = fl.len or 0.4, bore = bore,
                  q0 = fl.q0, H0 = fl.H0, pset = fl.pset, gv = fl.g, on = true }
      local live = ext and ext("element", p, d) or {}
      if kind == "pump" or kind == "valve" then e.on = live.on ~= false end
      if kind == "reg" and live.pset then e.pset = live.pset end
      ent.el = add_el(e)
      n.segs[#n.segs + 1] = { uid = p.uid, el = ent.el, a = { pc.ports[1].x, pc.ports[1].y, pc.ports[1].z },
                              b = { (pc.ports[2] or pc.ports[1]).x, (pc.ports[2] or pc.ports[1]).y, (pc.ports[2] or pc.ports[1]).z }, kind = kind }
    elseif kind == "tank" or kind == "bottle" or kind == "consumer" or kind == "primary" then
      local live = ext and ext(kind, p, d, ent) or {}
      local N = { kind = "tank", sub = live.sub or fl.sub, cap = live.cap or fl.cap, x0 = live.x, r = live.r or 0, label = d.label }
      local s = SUB[N.sub or "water"] or SUB.water
      if kind == "bottle" then
        N.cap = live.cap or (fl.pmax or 200e5) / gasA(N.sub, fl.V or 0.15)
        N.a, N.c = gasA(N.sub, fl.V or 0.15), 0
      elseif kind == "primary" then
        N.a, N.c = 0, live.p or P_ATM
        N.cap = live.cap or 1000
      else
        N.cap = N.cap or (fl.V or 1) * s.rho
        N.a, N.c = liquidAC(N.sub, fl.A or 1)
      end
      N.tk = kind
      N.ybot = p.y or 0
      -- (a bottle rack comes charged, a tank empty: fill it from the stores)
      if N.x0 == nil then N.x0 = (kind == "bottle" and not fl.empty) and N.cap or 0 end
      -- (a primary takes water or coolant alike)
      if kind == "primary" then N.sub = nil end
      ent.node = add_node(N)
      for i = 1, #pn do add_el({ kind = "cond", u = ent.node, v = pn[i], len = 0.3, bore = bore, nozzle = true }) end
      if N.sub then n.subs[N.sub] = true end
    elseif kind == "outlet" or kind == "vent" then
      local live = ext and ext(kind, p, d) or {}
      local N = { kind = "fixed", p = live.p or P_ATM, room = live.room, label = d.label, out = kind }
      ent.node = add_node(N)
      ent.el = add_el({ kind = "switch", u = pn[1], v = ent.node, len = 0.5, bore = bore, on = live.on ~= false, gv = fl.g })
    end
  end
  -- conductances now the substance is known
  for _, n in ipairs(out.nets) do
    local subs = {}
    for s in pairs(n.subs) do subs[#subs + 1] = s end
    table.sort(subs)
    n.sub = subs[1]
    if #subs > 1 then n.why[#n.why + 1] = "it joins " .. table.concat(subs, " and ") .. ": nothing flows until they're parted"; n.mixed = true end
    for _, e in ipairs(n.els) do
      local g = pipeG(e.bore, e.len, n.sub)
      if e.gv then g = math.min(g, e.gv) end
      if e.kind == "pump" then
        -- the curve's slope q0/H0 in series with its casing's run
        local gp = (e.q0 or 1) / (e.H0 or 3e5)
        e.g = 1 / (1 / gp + 1 / g)
        e.H = e.H0 or 3e5
      else
        e.g = g
      end
      if n.mixed then e.on = false; if e.kind == "cond" then e.kind = "valve" end end
    end
    -- (a liquid's ELEVATION: every pressure is solved as piezometric, p + ρgy,
    -- so a pump lifts water up a riser and a tank upstairs feeds down; zh is
    -- each node's ρgy, taken off again for the readouts' static pressure)
    local s_ = SUB[n.sub or ""]
    local rho = (s_ and s_.kind == "liquid") and s_.rho or 0
    n.rho = rho
    for _, N in ipairs(n.nodes) do
      N.zh = rho * G0 * (N.y or 0)
      if N.kind == "tank" and N.tk ~= "primary" and N.tk ~= "bottle" then N.c = (N.c or 0) + rho * G0 * (N.ybot or 0)
      elseif N.kind == "tank" and N.tk == "primary" then N.c = (N.c or 0) + N.zh
      elseif N.kind == "fixed" then N.p = (N.p or 0) + N.zh end
    end
    if #n.open > 0 then
      local P = n.open[1]
      n.why[#n.why + 1] = string.format("an open end at the %s's %s nozzle (capped: it holds, but it goes nowhere)", P.def.label or "piece", P.name)
    end
  end
  return out
end

-- ── readouts ────────────────────────────────────────────────────────────────
function bar(p) return (p or 0) / 1e5 end
-- What limits a network now: → text | nil
function limitedBy(net, st, rep)
  if net.mixed then return net.why[1] end
  if not (rep and rep.q) then return nil end
  local q, p = rep.q, rep.p
  -- a starved consumer first
  for i, N in ipairs(net.nodes) do
    if N.kind == "tank" and (N.r or 0) > 0 and (st.tm[i] == "S" or st.tm[i] == "D") then
      local got = max(0, rep.inflow and rep.inflow[i] or 0)
      local why = "nothing reaches it"
      for k, e in ipairs(net.els) do
        if e.kind == "pump" and st.em[k] == "stall" then why = string.format("the pump stalls: %.1f bar against its %.1f", bar(p[e.v] - p[e.u]), bar(e.H)) end
        if e.kind == "pump" and not e.on then why = "the pump is off" end
        if e.kind == "valve" and not e.on then why = "a valve is shut" end
      end
      for j, M in ipairs(net.nodes) do
        if M.kind == "tank" and (M.r or 0) == 0 and st.tm[j] == "D" then why = string.format("the %s is empty", M.label or "tank") end
      end
      return string.format("the %s is starved (%.3f of %.3f kg/s): %s", N.label or "consumer", got, N.r, why)
    end
  end
  for k, e in ipairs(net.els) do
    if e.kind == "pump" and e.on and st.em[k] == "stall" then
      return string.format("the pump can't beat %.1f bar (its shut-off head is %.1f)", bar(p[e.v] - p[e.u]), bar(e.H))
    end
  end
  -- the biggest drop over a pipe run while something flows
  local worst, wk = 0, nil
  for k, e in ipairs(net.els) do
    if e.kind == "cond" and not e.nozzle and abs(q[k] or 0) > 1e-6 then
      local d = abs(p[e.u] - p[e.v])
      if d > worst then worst, wk = d, k end
    end
  end
  if wk and worst > 0.5e5 then
    local e = net.els[wk]
    return string.format("pipe friction: %.1f bar over %.1f m of %s (a wider bore)", bar(worst), e.len, e.bore)
  end
  return nil
end
