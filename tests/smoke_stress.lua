-- SMOKE HARNESS: the joint-stress model (vessel_controller.lua's stress tree,
-- stressSolve and its force bookkeeping), on the real functions, no engine.
--
-- Each joint is a cut that splits the craft in two; the load through it is
-- what its leaving side A needs to move with the craft, less the external
-- forces already on A:  L = Σ_A m a − F_A − R_A  (see stressSolve). What is
-- held here:
--   * a stack on the ground: the bottom joint carries the weight above it,
--     the top joint the least (the 1,000-part finned spine: it fails at the
--     bottom now, not at the top);
--   * under thrust in vacuum: the joint just above the engine carries the
--     most, the top the least — and the answer does not depend on which part
--     the builder started the tree from;
--   * a side booster on a radial decoupler pushes the core through it;
--   * a payload hanging under a chute: the payload's joint holds its weight,
--     the canopy's the whole craft;
--   * Newton's third law: every joint's load, worked from the other side, is
--     exactly the opposite (random craft, forces, spin, contact);
--   * a plane in a turn: the air booked part by part sums to aero.step's
--     total, and the wing roots carry the wings' lift;
--   * the starter rocket and the two-stage Skipper → Anvil stay inside their
--     joints in normal flight (pad, burnout, chute, a firm landing).
--
--   luajit solar/tests/smoke_stress.lua

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
local VC = load(here .. "/scripts/vessel_controller.lua")
local A = load(here .. "/scripts/aero.lua")
local PA = load(here .. "/scripts/parts_aero.lua")
local REG = load(here .. "/scripts/parts_registry.lua").REG
local FUEL_T = 0.01   -- tonnes per propellant unit
local KT = 9.8 / 7.0  -- the catalogue's thrust rating on a 9.8 m/s² home (smoke_aero)

-- ── a craft: part records (uid, parent, mass, centre, box) and its stress tree ──
-- parts: { uid, id = REG key (mass from the registry, tanks full unless
-- fuel = share) or m = tonnes, parent, x, y, z }
local function craft(parts, pod)
  local by, kids, M = {}, {}, 0
  local cx, cy, cz = 0, 0, 0
  for _, p in ipairs(parts) do
    local r = REG[p.id or ""] or {}
    p.m = p.m or ((r.mass or 0) + (r.fuel or 0) * FUEL_T * (p.fuel or 1))
    p.strength = p.strength or r.strength or 350
    p.hx, p.hy, p.hz = p.hx or r.rx or 0.5, p.hy or (r.h or 1) / 2, p.hz or r.rz or 0.5
    by[p.uid] = { uid = p.uid, parent = p.parent or 0, id = p.id }
    if (p.parent or 0) ~= 0 then
      kids[p.parent] = kids[p.parent] or {}
      table.insert(kids[p.parent], p.uid)
    end
    M = M + p.m
    cx, cy, cz = cx + p.m * p.x, cy + p.m * p.y, cz + p.m * p.z
  end
  cx, cy, cz = cx / M, cy / M, cz / M
  local T = VC.stressTreeBuild(by, kids, pod, {})
  local list = {}
  for _, p in ipairs(parts) do
    if (p.parent or 0) ~= 0 then
      local s = VC.stressJointSide(T, p.uid, p.parent)
      if s then list[#list + 1] = { uid = p.uid, s = s, p = p } end
    end
  end
  local byp = {}
  for _, p in ipairs(parts) do byp[p.uid] = p end
  return { parts = parts, by = byp, T = T, list = list, M = M, cx = cx, cy = cy, cz = cz, pod = pod }
end

-- The loads: kin { a = {x,y,z} proper acceleration, al, w }, forces uid →
-- {x,y,z} (kN), contact uid → weight (or nil: free flight). Returns
-- uid → { x, y, z, f, pct, s } for every joint.
local function solve(C, kin, forces, contact)
  local T = C.T
  local P = { m = {}, x = {}, y = {}, z = {}, fx = {}, fy = {}, fz = {} }
  local cw = contact and {} or nil
  for i = 1, T.n do
    local p = C.by[T.ord[i]]
    P.m[i], P.x[i], P.y[i], P.z[i] = p.m, p.x - C.cx, p.y - C.cy, p.z - C.cz
    local f = forces and forces[p.uid]
    P.fx[i], P.fy[i], P.fz[i] = f and f.x or 0, f and f.y or 0, f and f.z or 0
    if cw then cw[i] = contact[p.uid] or 0 end
  end
  local a, al, w = kin.a, kin.al or { x = 0, y = 0, z = 0 }, kin.w or { x = 0, y = 0, z = 0 }
  local out = VC.stressSolve(T, C.list, P, cw, { ax = a.x, ay = a.y, az = a.z, alx = al.x, aly = al.y, alz = al.z,
    wx = w.x, wy = w.y, wz = w.z }, {})
  local L = {}
  for k, j in ipairs(C.list) do
    local x, y, z = out.x[k], out.y[k], out.z[k]
    local f = math.sqrt(x * x + y * y + z * z)
    L[j.uid] = { x = x, y = y, z = z, f = f, pct = 100 * f / j.p.strength, s = j.s }
  end
  return L, P
end

-- The leaving side of joint u, as a set of uids (the tree's subtree at s).
local function side(C, s)
  local T, set = C.T, {}
  for i = 1, T.n do
    local k = i
    while k > 0 and k ~= s do k = T.pi[k] end
    if k == s then set[T.ord[i]] = true end
  end
  return set
end

-- What the OLD model loaded joint u with: the leaving side's mass times the
-- proper acceleration at its centre (no rotation here), whatever pushed on it.
local function old_load(C, u, a)
  local m = 0
  for v in pairs(side(C, C.T.idx[u] and VC.stressJointSide(C.T, u, C.by[u].parent))) do m = m + C.by[v].m end
  return m * math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

local UP = { x = 0, y = 1, z = 0 }
local function v3(x, y, z) return { x = x, y = y, z = z } end
local function scale(v, k) return { x = v.x * k, y = v.y * k, z = v.z * k } end

-- ── 1. a stack on the ground ────────────────────────────────────────────────
-- The bench's finned spine (tools/perf/perfbench.lua finned_spine(40, 24)):
-- an engine at the root, 40 FT-S tanks each ringed with 24 fins, a pod on
-- top; sitting on the pad on Naolol (0.9 g), the ground under the engine.
do
  local g = 9.2
  local parts, uid = { { uid = 1, id = "engineS", x = 0, y = 0.76, z = 0 } }, 1
  local y, prev = 1.41, 1
  for k = 1, 40 do
    uid = uid + 1
    local tu = uid
    parts[#parts + 1] = { uid = tu, id = "tankS", parent = prev, x = 0, y = y + 0.5, z = 0, k = k }
    for f = 0, 23 do
      uid = uid + 1
      local a = f * 2 * math.pi / 24
      parts[#parts + 1] = { uid = uid, id = "fins", parent = tu, x = math.cos(a) * 0.85, y = y + 0.5, z = -math.sin(a) * 0.85 }
    end
    prev, y = tu, y + 1.0
  end
  uid = uid + 1
  parts[#parts + 1] = { uid = uid, id = "pod", parent = prev, x = 0, y = y + 0.4, z = 0 }
  local C = craft(parts, uid)
  ok(#parts == 1002 and C.T.n == 1002, "the finned spine: 1,002 parts, all in one tree hung from the pod")
  local a = scale(UP, g)
  local L = solve(C, { a = a }, nil, { [1] = 1 })   -- (the ground holds the engine)
  local ring = REG.tankS.mass + REG.tankS.fuel * FUEL_T + 24 * REG.fins.mass
  local function tank(k) for _, p in ipairs(parts) do if p.k == k then return p.uid end end end
  local worst = 0
  print("FINNED SPINE on the pad (0.9 g):        model now        old model    limit")
  for _, k in ipairs({ 1, 2, 16, 17, 20, 39, 40 }) do
    local u = tank(k)
    local above = ((40 - k + 1) * ring + REG.pod.mass) * g
    worst = math.max(worst, math.abs(L[u].f - above))
    print(string.format("  tank %2d joint (to the part below)  %4.0f kN (%3.0f%%)   %4.0f kN (%3.0f%%)   %d kN",
      k, L[u].f, L[u].pct, old_load(C, u, a), 100 * old_load(C, u, a) / REG.tankS.strength, REG.tankS.strength))
  end
  ok(worst < 1e-6, string.format("each spine joint carries exactly the weight above it (worst diff %.2g kN)", worst))
  ok(L[tank(1)].pct > 150 and L[tank(40)].pct < 10,
    string.format("the bottom joint is the overloaded one (%.0f%%), the top one nearly idle (%.0f%%)", L[tank(1)].pct, L[tank(40)].pct))
  local over = 0
  for k = 1, 40 do if L[tank(k)].pct > 100 then over = over + 1 end end
  local mono = true
  for k = 2, 40 do if L[tank(k)].f >= L[tank(k - 1)].f then mono = false end end
  ok(mono and over >= 14 and over <= 18, string.format("load falls all the way up the stack; the lowest %d joints are past their limit", over))
  local fin = parts[3]
  ok(near(L[fin.uid].f, fin.m * g, 1e-9), string.format("a fin's mount holds the fin's own weight (%.2f kN)", L[fin.uid].f))
  -- a stack on the ground with nobody saying where it touches: the support
  -- goes on the lowest parts (stressLeading), the same answer
  local T = C.T
  local P = select(2, solve(C, { a = a }))
  local cw = {}
  local n = VC.stressLeading(nil, T, P, cw, 0, 1, 0, v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1),
    function(_, u) local p = C.by[u] return { ex = p.hx, ey = p.hy, ez = p.hz } end)
  ok(n == 1 and cw[T.idx[1]] == 1, string.format("with no contact reported, the support goes on the lowest part: the engine (%d parts)", n))
end

-- ── 2. under thrust in vacuum ───────────────────────────────────────────────
do
  local function stack(rooted_at_pod)
    -- engine, five FT-S, pod; uids bottom-up
    local parts = { { uid = 1, id = "engineS", x = 0, y = 0.65, z = 0 } }
    for k = 1, 5 do parts[#parts + 1] = { uid = k + 1, id = "tankS", x = 0, y = 1.3 + k - 0.5, z = 0 } end
    parts[#parts + 1] = { uid = 7, id = "pod", x = 0, y = 6.7, z = 0 }
    for i, p in ipairs(parts) do
      if rooted_at_pod then p.parent = i < #parts and p.uid + 1 or 0 else p.parent = i > 1 and p.uid - 1 or 0 end
    end
    return craft(parts, 7)
  end
  local T = REG.engineS.thrust * KT
  local res = {}
  for _, rp in ipairs({ true, false }) do
    local C = stack(rp)
    local a = scale(UP, T / C.M)
    res[rp] = solve(C, { a = a }, { [1] = scale(UP, T) })
    res[rp].C = C
  end
  local L, C = res[true], res[true].C
  -- the joint just above the engine (tank 2 ↔ engine) and the top one (pod ↔ tank 6)
  local low = L[1] or L[2]
  local top = L[6] or L[7]
  local a = T / C.M
  ok(near(low.f, (C.M - C.by[1].m) * a, 1e-9),
    string.format("under thrust the joint above the engine carries everything above it × a (%.1f kN)", low.f))
  ok(near(top.f, C.by[7].m * a, 1e-9), string.format("...and the top joint just the pod × a (%.1f kN), the least", top.f))
  local same = true
  local Lb = res[false]
  -- (the same physical joint has a different owner in the two trees: tank k ↔ k+1)
  local function between(Lx, Cx, u, v) return Lx[(Cx.by[u].parent == v) and u or v] end
  for u = 1, 6 do
    local x, y = between(L, C, u, u + 1), between(Lb, res[false].C, u, u + 1)
    if not (x and y and near(x.f, y.f, 1e-9)) then same = false end
  end
  ok(same, "the loads are the same whichever part the builder started the tree from")
  print(string.format("THRUST in vacuum (Sputter %.0f kN, %.1f t, %.1f g): above the engine %.0f kN, under the pod %.1f kN"
    .. " (the old model: %.1f and %.0f)", T, C.M, a / 9.81, low.f, top.f, old_load(C, 6, scale(UP, a)), old_load(C, 1, scale(UP, a))))
end

-- ── 3. a side booster on a radial decoupler ─────────────────────────────────
do
  local parts = {
    { uid = 1, id = "pod", x = 0, y = 3.4, z = 0 },
    { uid = 2, id = "tankS", parent = 1, x = 0, y = 2.5, z = 0 },
    { uid = 3, id = "engineS", parent = 2, x = 0, y = 1.35, z = 0 },
    { uid = 4, id = "radialDec", parent = 2, x = 0.6, y = 2.5, z = 0 },
    { uid = 5, id = "tankS", parent = 4, x = 1.2, y = 2.5, z = 0 },
    { uid = 6, id = "engineS", parent = 5, x = 1.2, y = 1.35, z = 0 },
  }
  local C = craft(parts, 1)
  local T = REG.engineS.thrust * KT
  local a = scale(UP, 2 * T / C.M)
  local L = solve(C, { a = a }, { [3] = scale(UP, T), [6] = scale(UP, T) })
  local mb = C.by[4].m + C.by[5].m + C.by[6].m
  local want = T - mb * a.y   -- the booster's thrust, less what it takes to carry itself
  ok(near(L[4].f, want, 1e-9) and L[4].y < 0,
    string.format("the radial decoupler takes the booster's push into the core (%.1f kN = %.0f − %.2f t × %.1f m/s²)",
      L[4].f, T, mb, a.y))
  print(string.format("SIDE BOOSTER: radial decoupler %.1f kN (%.0f%% of %d), its tank's joint %.1f kN; the old model %.1f kN",
    L[4].f, L[4].pct, REG.radialDec.strength, L[5].f, old_load(C, 4, a)))
end

-- ── 4. a payload hanging under a chute ──────────────────────────────────────
do
  local parts = {
    { uid = 1, id = "pod", x = 0, y = 3.0, z = 0 },
    { uid = 2, id = "chute", parent = 1, x = 0, y = 3.57, z = 0 },
    { uid = 3, id = "tankS", parent = 1, x = 0, y = 2.1, z = 0, fuel = 0 },
    { uid = 4, id = "engineS", parent = 3, x = 0, y = 0.95, z = 0 },
  }
  local C = craft(parts, 1)
  local g = 9.81
  -- at terminal speed: the canopy holds the whole craft up, a = g (proper)
  local L = solve(C, { a = scale(UP, g) }, { [2] = scale(UP, C.M * g) })
  local mp = C.by[3].m + C.by[4].m
  ok(near(L[3].f, mp * g, 1e-9) and L[3].y > 0,
    string.format("the payload's joint holds the payload's weight up (%.1f kN)", L[3].f))
  ok(near(L[2].f, (C.M - C.by[2].m) * g, 1e-9) and L[2].y < 0,
    string.format("the canopy's lines hold the rest of the craft (%.1f kN, pulled down)", L[2].f))
end

-- ── 5. Newton's third law ───────────────────────────────────────────────────
-- Random trees, masses, places, forces, spin and contact: the load worked
-- from side A by the tree is the brute-force sum over A, and the same sum
-- over the OTHER side is exactly its opposite.
do
  local rnd = 12345
  local function r() rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd / 2147483648 end
  local worst_sym, worst_tree = 0, 0
  for trial = 1, 25 do
    local N = 2 + math.floor(r() * 40)
    local parts = {}
    for u = 1, N do
      parts[u] = { uid = u, m = 0.05 + r() * 3, parent = u > 1 and (1 + math.floor(r() * (u - 1))) or 0,
                   x = r() * 8 - 4, y = r() * 8 - 4, z = r() * 8 - 4 }
    end
    local pod = 1 + math.floor(r() * N)
    local C = craft(parts, pod)
    local forces, contact = {}, (trial % 2 == 0) and {} or nil
    for u = 1, N do
      if r() < 0.4 then forces[u] = v3(r() * 200 - 100, r() * 200 - 100, r() * 200 - 100) end
      if contact and r() < 0.2 then contact[u] = r() end
    end
    local kin = { a = v3(r() * 40 - 20, r() * 40 - 20, r() * 40 - 20), al = v3(r() * 4 - 2, r() * 4 - 2, r() * 4 - 2),
                  w = v3(r() * 6 - 3, r() * 6 - 3, r() * 6 - 3) }
    local L, P = solve(C, kin, forces, contact)
    -- brute force, per part: m a_i − F_i, a_i = a + α×r + ω×(ω×r)
    local need = {}
    local Rx, Ry, Rz, Mt, Ct = 0, 0, 0, 0, 0
    local a, al, w = kin.a, kin.al, kin.w
    for _, p in ipairs(parts) do
      local rx, ry, rz = p.x - C.cx, p.y - C.cy, p.z - C.cz
      local wrx, wry, wrz = w.y * rz - w.z * ry, w.z * rx - w.x * rz, w.x * ry - w.y * rx
      local ax = a.x + (al.y * rz - al.z * ry) + (w.y * wrz - w.z * wry)
      local ay = a.y + (al.z * rx - al.x * rz) + (w.z * wrx - w.x * wrz)
      local az = a.z + (al.x * ry - al.y * rx) + (w.x * wry - w.y * wrx)
      local f = forces[p.uid] or v3(0, 0, 0)
      need[p.uid] = { p.m * ax - f.x, p.m * ay - f.y, p.m * az - f.z }
      Rx, Ry, Rz = Rx + need[p.uid][1], Ry + need[p.uid][2], Rz + need[p.uid][3]
      Mt, Ct = Mt + p.m, Ct + (contact and contact[p.uid] or 0)
    end
    for u, l in pairs(L) do
      local A_ = side(C, l.s)
      local sA = { 0, 0, 0 }
      local sB = { 0, 0, 0 }
      local mA, cA = 0, 0
      for _, p in ipairs(parts) do
        local t = A_[p.uid] and sA or sB
        for i = 1, 3 do t[i] = t[i] + need[p.uid][i] end
        if A_[p.uid] then mA, cA = mA + p.m, cA + (contact and contact[p.uid] or 0) end
      end
      local share = (Ct > 0) and cA / Ct or mA / Mt
      local LA = { sA[1] - share * Rx, sA[2] - share * Ry, sA[3] - share * Rz }
      local LB = { sB[1] - (1 - share) * Rx, sB[2] - (1 - share) * Ry, sB[3] - (1 - share) * Rz }
      for i = 1, 3 do
        worst_sym = math.max(worst_sym, math.abs(LA[i] + LB[i]))
      end
      worst_tree = math.max(worst_tree, math.abs(LA[1] - l.x), math.abs(LA[2] - l.y), math.abs(LA[3] - l.z))
      -- the pod is never on the leaving side
      if A_[pod] then worst_tree = math.huge end
    end
  end
  ok(worst_tree < 1e-8, string.format("the tree's sums are the brute-force sums over each joint's leaving side (worst %.2g kN)", worst_tree))
  ok(worst_sym < 1e-8, string.format("Newton's third law: from the other side every load is exactly opposite (worst %.2g kN)", worst_sym))
end

-- ── 6. a plane in a turn ────────────────────────────────────────────────────
-- smoke_aero's light jet (nose +X, top +Y), banked into a steady turn: the
-- air on it, booked part by part as the flight does (aeroStressForces), and
-- the joints that hold its wings on.
do
  local function eulerOf(X, Y, Z)
    local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
    if math.abs(Z.y) > 1 - 1e-10 then return math.atan2(-X.z, X.x), pitch, 0 end
    return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
  end
  local function cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
  local uid = 0
  local function place(id, x, y, z, X, Y, parent)
    local def = PA.PARTS[id]
    uid = uid + 1
    local Z = cross(X, Y)
    local yaw, pitch, roll = eulerOf(X, Y, Z)
    local r = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll, parent = parent or 0 }
    for k, v in pairs(def) do if r[k] == nil and type(v) ~= "table" then r[k] = v end end
    return r
  end
  local NOSE, TOP = v3(1, 0, 0), v3(0, 1, 0)
  local cX = cross(NOSE, v3(0, -1, 0))
  local Y0 = 1.5
  local list = {}
  local function add(r) list[#list + 1] = r return r end
  local cp = add(place("cockpit", 1.9, Y0, 0, cX, NOSE))
  local ft = add(place("fuseTank", -0.2, Y0, 0, cX, NOSE, cp.uid))
  local jt = add(place("jet", -2.1, Y0, 0, cX, NOSE, ft.uid))
  local roots = {}
  for _, s in ipairs({ 1, -1 }) do
    local out = v3(0, 0, s)
    local wl = add(place("wingL", -0.6, Y0, s * (0.5 + 1.75), out, NOSE, ft.uid))
    add(place("wingTip", -0.6, Y0, s * (0.5 + 3.5 + 0.6), out, NOSE, wl.uid))
    add(place("elevon", -2.35, Y0, s * (0.5 + 0.8), out, NOSE, jt.uid))
    roots[#roots + 1] = wl.uid
  end
  add(place("tailFin", -2.3, Y0 + 0.5 + 0.75, 0, TOP, NOSE, jt.uid))
  for _, r in ipairs(list) do if r.fuel then r.fuel_t = FUEL_T end end
  local M = A.build(list)
  local cmx, cmy, cmz, mass = A.centerOfMass(list)
  -- 70 m/s, 7° nose-up into the air, in the craft's frame
  local al = math.rad(7)
  local env = { vx = 70 * math.cos(al), vy = -70 * math.sin(al), vz = 0, cx = cmx, cy = cmy, cz = cmz,
                rho = 1.225, a = 340, dt = 1 / 60, ctl = { p = 0, y = 0, r = 0 } }
  local fx, fy, fz = A.step(M, env)
  VC.stressForcesDrop(true)
  VC.aeroStressForces(A, M, env, 1.0, v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1))
  local F = VC.STRESS_F
  local sx, sy, sz, forces = 0, 0, 0, {}
  for u, x in pairs(F.px) do
    sx, sy, sz = sx + x, sy + F.py[u], sz + F.pz[u]
    forces[u] = v3(x, F.py[u], F.pz[u])
  end
  ok(near(sx, fx, 1e-9) and near(sy, fy, 1e-9) and near(sz, fz, 1e-9),
    string.format("the air booked part by part sums to aero.step's total (%.2f, %.2f, %.2f kN)", sy, fy, fz))
  -- an aero.lua that keeps each body's and surface's force from its step
  -- (M.kept) is read as is, to the same numbers
  do
    local keep = {}
    for u, f in pairs(forces) do keep[u] = f end
    for _, list in ipairs({ M.bodies, M.surfs }) do
      for _, b in ipairs(list) do
        local f = keep[b.uid] or v3(0, 0, 0)
        b.fx, b.fy, b.fz = f.x, f.y, f.z
      end
    end
    local was = M.kept
    M.kept = true
    VC.stressForcesDrop(true)
    VC.aeroStressForces(A, M, env, 1.0, v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1))
    local worst = 0
    for u, f in pairs(keep) do
      worst = math.max(worst, math.abs((F.px[u] or 0) - f.x), math.abs((F.py[u] or 0) - f.y), math.abs((F.pz[u] or 0) - f.z))
    end
    M.kept = was
    ok(worst < 1e-12, "...and an aero model that kept each part's force from its step is booked the same")
  end
  -- the wings make the lift
  local wl = 0
  for _, u in ipairs(roots) do wl = wl + forces[u].y + forces[u + 1].y end
  ok(wl > 0.8 * fy, string.format("the wings make the lift (%.1f of %.1f kN)", wl, fy))
  -- free flight: the air is all that pushes (gravity is not a proper force)
  local parts = {}
  for _, r in ipairs(list) do
    parts[#parts + 1] = { uid = r.uid, m = r.mass + (r.fuel or 0) * FUEL_T, parent = r.parent, x = r.x, y = r.y, z = r.z,
                          strength = r.strength or 350 }
  end
  local C = craft(parts, cp.uid)
  local a = v3(fx / C.M, fy / C.M, fz / C.M)
  local n = fy / (C.M * 9.81)
  local L = solve(C, { a = a }, forces)
  local root = L[roots[1]]
  local mw = C.by[roots[1]].m + C.by[roots[1] + 1].m
  local lift_w = forces[roots[1]].y + forces[roots[1] + 1].y
  ok(root.y < 0 and near(-root.y, lift_w - mw * a.y, 1e-9),
    string.format("a wing root holds the wing down against its lift (%.1f kN = %.1f lift − %.3f t × %.1f m/s²)",
      -root.y, lift_w, mw, a.y))
  ok(root.f > 5 * old_load(C, roots[1], a),
    string.format("...far more than the wing's own mass × the turn (%.1f kN against the old model's %.2f)",
      root.f, old_load(C, roots[1], a)))
  ok(root.pct < 100, string.format("a %.1f g turn is inside the Wing Panel L's mount (%.0f%%)", n, root.pct))
  print(string.format("PLANE in a %.1f g pull at 70 m/s (%.2f t): wing root %.1f kN (%.0f%% of %d), the old model %.2f kN",
    n, C.M, root.f, root.pct, C.by[roots[1]].strength, old_load(C, roots[1], a)))
  VC.stressForcesDrop(true)
end

-- ── 7. the starter rocket and the two-stage Skipper → Anvil ─────────────────
local function report(name, C, L)
  local worst, wu = 0, nil
  for u, l in pairs(L) do if l.pct > worst then worst, wu = l.pct, u end end
  local p = wu and C.by[wu]
  print(string.format("  %-46s worst joint %-9s %6.1f kN  %5.1f%%", name, p and p.id or "-", wu and L[wu].f or 0, worst))
  return worst
end
do
  print("STARTER (chute, pod, FT-S, Sputter; pod at the root):")
  local function starter(fuel)
    return craft({
      { uid = 1, id = "pod", x = 0, y = 2.7, z = 0 },
      { uid = 2, id = "chute", parent = 1, x = 0, y = 3.27, z = 0 },
      { uid = 3, id = "tankS", parent = 1, x = 0, y = 1.8, z = 0, fuel = fuel },
      { uid = 4, id = "engineS", parent = 3, x = 0, y = 0.65, z = 0 },
    }, 1)
  end
  local T = REG.engineS.thrust * KT
  local g = 9.8
  local worst = 0
  -- on the pad, full throttle, not yet off the ground: thrust + the ground under the engine
  local C = starter(1)
  worst = math.max(worst, report("on the pad at full throttle", C,
    solve(C, { a = scale(UP, g) }, { [4] = scale(UP, T) }, { [4] = 1 })))
  -- climbing at burnout (the tank dry): the hardest push the engine gives
  C = starter(0)
  worst = math.max(worst, report(string.format("burnout in vacuum (%.1f g)", T / C.M / 9.81), C,
    solve(C, { a = scale(UP, T / C.M) }, { [4] = scale(UP, T) })))
  -- under the chute: at terminal speed, and a hard 15 g opening (the scale the
  -- model was tuned on); the booked forces are capped at 40 g (STRESS_SAMPLE_MAX)
  for _, ng in ipairs({ 1, 15, 40 }) do
    local L = solve(C, { a = scale(UP, ng * g) }, { [2] = scale(UP, C.M * ng * g) })
    local w = report(string.format("under the chute, %d g", ng), C, L)
    if ng <= 15 then
      -- (an open canopy's own lines are rated by pressure, not load)
      local wo = 0
      for u, l in pairs(L) do if u ~= 2 then wo = math.max(wo, l.pct) end end
      worst = math.max(worst, wo)
    end
  end
  -- a firm landing on the engine: 7 m/s stopped in 0.1 s (+1 g of weight)
  local L = solve(C, { a = scale(UP, 7 / 0.1 + g) }, nil, { [4] = 1 })
  worst = math.max(worst, report("a firm landing (7 m/s in 0.1 s, 8 g)", C, L))
  ok(worst < 100, string.format("the starter rocket stays inside every joint in normal flight (worst %.0f%%)", worst))
  -- a crash: 20 m/s stopped in 0.1 s (capped at 40 g) breaks the joint
  -- above the engine first
  L = solve(C, { a = scale(UP, 40 * g) }, nil, { [4] = 1 })
  local top = 0
  for u, l in pairs(L) do if l.pct > top then top = l.pct end end
  ok(L[4].pct == top and L[4].pct > 100,
    string.format("a 40 g crash onto the engine tears the engine off first (%.0f%%)", L[4].pct))
  report("a crash onto the engine (40 g)", C, L)
end
do
  print("SKIPPER → ANVIL (Skipper, 2 FT-M | decoupler | Anvil, 2 FT-M, pod, chute; rooted at the Skipper):")
  local function two(lower_fuel, upper_fuel, with_lower)
    local list, y, u = {}, 0, 0
    local function add(id, h, fuel)
      u = u + 1
      list[#list + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, parent = u - 1, fuel = fuel }
      y = y + h
    end
    if with_lower then
      add("skipper", 1.6); add("tankM", 1.5, lower_fuel); add("tankM", 1.5, lower_fuel); add("decoupler", 0.25)
    end
    add("engineM", 1.6); add("tankM", 1.5, upper_fuel); add("tankM", 1.5, upper_fuel); add("pod", 0.8); add("chute", 0.34)
    return craft(list, u - 1), list
  end
  local g = 9.8
  local worst = 0
  local C, list = two(1, 1, true)
  local Ts, Ta = REG.skipper.thrust * KT, REG.engineM.thrust * KT
  worst = math.max(worst, report("on the pad at full throttle", C,
    solve(C, { a = scale(UP, g) }, { [1] = scale(UP, Ts) }, { [1] = 1 })))
  C = two(0, 1, true)
  worst = math.max(worst, report(string.format("stage 1 burnout (%.1f g)", Ts / C.M / 9.81), C,
    solve(C, { a = scale(UP, Ts / C.M) }, { [1] = scale(UP, Ts) })))
  C = two(0, 0, false)
  worst = math.max(worst, report(string.format("stage 2 burnout (%.1f g)", Ta / C.M / 9.81), C,
    solve(C, { a = scale(UP, Ta / C.M) }, { [1] = scale(UP, Ta) })))
  local chute = C.list[#C.list].uid
  local L = solve(C, { a = scale(UP, 15 * g) }, { [chute] = scale(UP, C.M * 15 * g) })
  local wo = 0
  for u, l in pairs(L) do if u ~= chute then wo = math.max(wo, l.pct) end end
  report("the upper stage under its chute, 15 g", C, L)
  worst = math.max(worst, wo)
  ok(worst < 100, string.format("the two-stage Skipper → Anvil stays inside every joint in normal flight (worst %.0f%%)", worst))
end

if #failures > 0 then
  print("STRESS SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("STRESS SMOKE OK — %d checks", checks))
