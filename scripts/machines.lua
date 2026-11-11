-- MACHINES — the refineries and the Fabricator as rules (expansion X6;
-- work/expansion/PLAN.md §3.4, N4/N7; docs/base-building.md §24).
--
-- PURE. No engine calls: it loads from disk in a luajit test
-- (tests/smoke_machines.lua). The scene half is scripts/refinery.lua; the
-- material flow through a machine is item_net's (a machine is two nodes, its
-- inlet and its outlet, and a conversion between them).
--
-- WHAT EACH MACHINE DOES, by real energy per kilogram (the S6/S7 rule: the
-- numbers are physics, the arrangement sets how much of them you get):
--
--   Crusher       bulk rock and ore → its minerals (a jaw crusher and a
--                 magnetic/density split): 2 kJ a kg (primary crushing is
--                 1–4 kJ/kg), 4 kW → 2 kg/s. Hematite Earth gives 45 % iron
--                 ore, Rust Rock 25 %, basalt 10 % (its FeO) and 10 % silica,
--                 sand 85 % silica; the rest regolith. Ore passes through.
--   Furnace       iron ore → Steel (65 % by mass: Fe2O3 is 70 % iron, less
--                 slag), kamacite → Alloy Steel (90 %: meteoric iron-nickel),
--                 copper ore → Copper Wire (30 %: smelted, refined, drawn).
--                 An induction melt at 1.5 MJ a kg of steel (an arc furnace's
--                 1.4–1.6), 3 MJ a kg of copper; 12 kW, 10 kW of it heat to
--                 shed: Steel at 8 g/s (29 kg an hour).
--   Kiln          silica → Glass (95 %) at 2.8 MJ/kg of glass (soda-lime's
--                 melt is 2.5–3); regolith → sintered Regocrete (95 %) at
--                 1 MJ/kg (microwave sintering). 9 kW, 6 kW of heat.
--   Mixer         regolith + water (5:1) → Regocrete (1.2 kg a kg of
--                 regolith): 2 kJ a kg, 2 kW → 1 kg/s; the water from a
--                 pipe (a consumer on the fluid network, 0.2 kg a kg).
--   Electrolyser  water → Propellant (0.78 kg a kg: 2 H2O → 2 H2 + O2, kept
--                 at LOX/LH2's O/F 6, the 0.22 kg of oxygen over it vented)
--                 at 20 MJ a kg of water (55 kWh a kg of H2, a PEM stack's
--                 real figure); 20 kW → 1 g/s of water. Its outlet is a fuel
--                 port: the Fuel Tanks on it are the FUEL base's.
--   Fabricator    refined kg → a crated part (recipes.recipeFor): 10 s + 20 s
--                 a tonne, 3 kW, a queue of four.
--
-- COOLING (the furnace and the kiln). A hot machine sheds its heat through
-- its heat port into what is chained to it: Radiator Panels (S6), Jacket
-- Radiators, coolant pipes between, a Cooling Tower Cell in air. Its duty is
--     duty = min(1, PASSIVE + C / H)
-- where H is the heat of every hot machine on that loop and C what the loop's
-- sinks shed at the jacket water's JACKET_T (330 K, 57 °C):
--     radiator  ε σ A η (T⁴ − T_sky⁴) · (1 − 0.35 · sun)  + h A η (T − T_air) in air
--     tower     g (T − T_air), in air only
-- A machine with no sink runs at PASSIVE (20 %: its shell sheds a fifth); two
-- on one radiator row share it.
--
--   MACH[kind]                    the table above
--   convOf(kind)                  → { [mat] = { outs = { mat = kg/kg }, tot, e } }, rate (kg/s of input at duty 1)
--   rejectKW(reject, env)         → kW a sink sheds at JACKET_T (env = { air, tamb, sun })
--   coolLoops(pieces)             → { [key] = { cool = 0..1, H, C, n, sinks } } (union-find on heat ports)
--   duty(kind, ctx)               → 0..1, why (the first thing holding it back)
--   fabAdvance(F, dt, duty, env)  the Fabricator's queue, event to event → why | nil
--   waterFor(kind, kgIn)          kg of water a mixer takes with kgIn of regolith

SIGMA = 5.670374e-8
JACKET_T = 330          -- K: the jacket water a hot machine runs its loop at
T_SKY = 4               -- K
FIN = 0.4               -- a panel's fin efficiency at the jacket's temperature
H_CONV = 8              -- W/m²K: a panel's convection in air
SUN_CUT = 0.35          -- a radiator sheds 35 % less in full sun (S6)
SUN_MEAN = 0.5          -- the closed form's day-night mean
PASSIVE = 0.2           -- a hot machine's shell sheds a fifth of its heat
FAB_QUEUE = 4
SPEED = 1.0             -- one knob on every machine's rate (balance; 1 = the physics)

-- What the crusher splits each ground material into (kg a kg; what is not
-- named passes through 1:1, what the shares leave over is regolith).
CRUSH = {
  hematite  = { iron = 0.45 },
  rustrock  = { iron = 0.25 },
  basalt    = { iron = 0.10, silica = 0.10 },
  granite   = { silica = 0.30, iron = 0.03 },
  sand      = { silica = 0.85 },
  sandstone = { silica = 0.80 },
  veinstone = { copper = 0.15 },
  onyx      = { silica = 0.60 },
  slate     = { silica = 0.10 },
  shale     = { silica = 0.05 },
  soil = {}, clay = {}, gravel = {}, ash = {}, limestone = {}, salt = {}, regolith = {},
}
-- the ground and ore classes a crusher takes (everything dug)
CRUSH_PASS = { iron = true, copper = true, silica = true, sulfur = true, obsidian = true, ilmenite = true, kamacite = true,
               kreep = true, he3 = true, monazite = true, sperrylite = true, uranium = true, crystal = true }

-- kJ per kg of OUTPUT (the product's specific energy), the yield in kg out a kg in
MACH = {
  crusher = { label = "Crusher", kw = 4, heat = 0, ej = 2, capIn = 400, capOut = 400,
              desc = "bulk rock and ore → iron ore, silica, copper ore and regolith · 2 kg/s" },
  furnace = { label = "Furnace", kw = 12, heat = 10, capIn = 200, capOut = 200,
              recipes = { iron = { steel = 0.65, e = 1500 }, kamacite = { alloy = 0.90, e = 1500 }, copper = { wiring = 0.30, e = 3000 } },
              desc = "iron ore → Steel · kamacite → Alloy Steel · copper ore → Copper Wire" },
  kiln    = { label = "Kiln", kw = 9, heat = 6, capIn = 200, capOut = 200,
              recipes = { silica = { glass = 0.95, e = 2800 }, regolith = { regocrete = 0.95, e = 1000 } },
              desc = "silica → Glass · regolith → sintered Regocrete" },
  mixer   = { label = "Mixer", kw = 2, heat = 0, capIn = 300, capOut = 300, water = 0.2, cell = 50,
              recipes = { regolith = { regocrete = 1.2, e = 2 / 1.2 } },
              desc = "regolith + water (5:1) → Regocrete" },
  electrolyser = { label = "Electrolyser", kw = 20, heat = 0, ej = 20000, yield = 0.78, cell = 40,
              desc = "water → Propellant (LOX/LH2) into the Fuel Tanks on its outlet" },
  fabricator = { label = "Fabricator", kw = 3, heat = 0, cap = 2000,
              desc = "refined kg → crated parts: 10 s + 20 s a tonne, a queue of four" },
  -- (progression W1) the Sawbench: timber → planks. A timber is a sawlog
  -- length (its 1.2 kg is the pack's weight for one): it saws to `plank` kg of
  -- boards. Not on the belts: its own menu runs it (scripts/timber.lua), by
  -- hand at `hand` kg of planks a minute (an Engineer twice that) or on the
  -- base grid at `powered` (`kw` while it saws). The arithmetic is timber's.
  sawbench = { label = "Sawbench", kw = 0.6, heat = 0, hand = 10, powered = 40,
              -- (e: 0.9 kJ a kg of boards: 0.6 kW rips 40 kg a minute)
              recipes = { timber = { plank = 25, e = 0.9 } },
              desc = "timber → planks: by hand 10 kg a minute, on the grid 40 (0.6 kW)" },
}
-- what a Fabricator's store takes (the refined solids)
FAB_TAKES = { steel = true, alloy = true, wiring = true, glass = true, regocrete = true, plank = true }

-- The conversion of `kind`: { [mat in] = { outs = { [mat out] = kg/kg }, tot = Σ outs, e = kJ a kg in } },
-- and its rate at duty 1 in kg/s of input for each input (the energy sets it).
local conv_memo = {}
function convOf(kind)
  if conv_memo[kind] then return conv_memo[kind] end
  local M = MACH[kind]
  if not M then return nil end
  local out = {}
  if kind == "crusher" then
    for m, sh in pairs(CRUSH) do
      local outs, s = {}, 0
      for om, v in pairs(sh) do outs[om] = v; s = s + v end
      if 1 - s > 1e-9 then outs.regolith = (outs.regolith or 0) + (1 - s) end
      out[m] = { outs = outs, tot = 1, e = M.ej }
    end
    for m in pairs(CRUSH_PASS) do out[m] = { outs = { [m] = 1 }, tot = 1, e = M.ej } end
  elseif M.recipes then
    for m, r in pairs(M.recipes) do
      local outs, s, e = {}, 0, r.e
      for om, v in pairs(r) do if om ~= "e" then outs[om] = v; s = s + v end end
      -- e is a kg of output's: a kg of input takes e · s
      out[m] = { outs = outs, tot = s, e = e * s }
    end
  end
  for _, c in pairs(out) do c.rate = SPEED * M.kw / math.max(1e-9, c.e) end   -- kg/s of input at full power
  conv_memo[kind] = out
  return out
end
-- The machine's inlet acceptance set and its largest output a kg (for item_net)
function acceptOf(kind)
  local c = convOf(kind)
  if not c then return nil end
  local a = {}
  for m in pairs(c) do a[m] = true end
  return a
end

-- kg of water a mixer takes with kgIn of regolith
function waterFor(kind, kgIn)
  local M = MACH[kind]
  return (M and M.water or 0) * (kgIn or 0)
end
-- the electrolyser at duty 1: kg/s of water, kg/s of propellant
function electrolysis()
  local M = MACH.electrolyser
  local q = SPEED * M.kw / M.ej
  return q, q * M.yield
end

-- ── COOLING ─────────────────────────────────────────────────────────────────
-- kW a heat sink sheds at the jacket temperature. reject = a part's `reject`
-- (S6 { kind = "rad", area, eps } | { kind = "tower", g }); env = { air (bool),
-- tamb (K), sun (0..1) }.
function rejectKW(reject, env)
  if type(reject) ~= "table" then return 0 end
  env = env or {}
  local T = JACKET_T
  local tamb = env.tamb or 288
  local sun = env.sun or SUN_MEAN
  if reject.kind == "rad" then
    local A, eps = reject.area or 16, reject.eps or 0.88
    local q = eps * SIGMA * A * FIN * (T ^ 4 - T_SKY ^ 4) * (1 - SUN_CUT * sun)
    if env.air then q = q + H_CONV * A * FIN * math.max(0, T - tamb) end
    return q / 1000
  elseif reject.kind == "tower" then
    if not env.air then return 0 end
    return (reject.g or 14) * math.max(0, T - tamb)
  end
  return 0
end

-- The cooling loops. pieces = { { key, ports = { { x, y, z, nx, nz } }, heat
-- (kW, a hot machine), sink (kW, a radiator or tower), reactor (true: the
-- piece belongs to a reactor plant's loops, so the loop's sinks are the
-- plant's) } … }. Ports that meet (within 0.06 m, facing) join; a piece's
-- own ports are one. → { [key] = { cool, H, C, n, sinks } } for each hot piece.
function coolLoops(pieces)
  local ports = {}
  for pi, p in ipairs(pieces) do
    for _, pt in ipairs(p.ports or {}) do ports[#ports + 1] = { pi = pi, x = pt.x, y = pt.y, z = pt.z, nx = pt.nx or 0, nz = pt.nz or 0 } end
  end
  local U = {}
  for i = 1, #pieces do U[i] = i end
  local function find(a) while U[a] ~= a do U[a] = U[U[a]]; a = U[a] end return a end
  for a = 1, #ports do
    local A = ports[a]
    for b = a + 1, #ports do
      local Bp = ports[b]
      if A.pi ~= Bp.pi and math.abs(A.x - Bp.x) < 0.06 and math.abs(A.y - Bp.y) < 0.06 and math.abs(A.z - Bp.z) < 0.06
         and (A.nx * Bp.nx + A.nz * Bp.nz) < -0.9 then
        local ra, rb = find(A.pi), find(Bp.pi)
        if ra ~= rb then U[rb] = ra end
      end
    end
  end
  local G = {}
  for pi, p in ipairs(pieces) do
    local r = find(pi)
    local g = G[r] or { H = 0, C = 0, n = 0, sinks = 0, reactor = false }
    G[r] = g
    if p.heat and p.heat > 0 then g.H = g.H + p.heat; g.n = g.n + 1 end
    if p.sink and p.sink > 0 then g.C = g.C + p.sink; g.sinks = g.sinks + 1 end
    if p.reactor then g.reactor = true end
  end
  local out = {}
  for pi, p in ipairs(pieces) do
    if p.heat and p.heat > 0 then
      local g = G[find(pi)]
      local C = g.reactor and 0 or g.C
      out[p.key] = { cool = math.min(1, PASSIVE + C / math.max(1e-9, g.H)), H = g.H, C = C, n = g.n, sinks = g.reactor and 0 or g.sinks,
                     reactor = g.reactor }
    end
  end
  return out
end

-- ── DUTY ────────────────────────────────────────────────────────────────────
-- ctx = { on (false: switched off), served (base_grid: false = the grid is
-- short), cool (0..1, a hot machine's), water (0..1, a mixer's or an
-- electrolyser's), room (false: an electrolyser with no tank room) }
-- → duty 0..1, why (plain words, or nil at full duty)
function duty(kind, ctx)
  ctx = ctx or {}
  local M = MACH[kind]
  if not M then return 0, "not a machine" end
  if ctx.on == false then return 0, "switched off (its RUN terminal, or its menu)" end
  if ctx.served == false then return 0, string.format("no power: the grid is short (%g kW)", M.kw) end
  if ctx.room == false then return 0, "no room in a Fuel Tank on its outlet (or none piped to it)" end
  local d, why = 1, nil
  if (M.heat or 0) > 0 then
    local c = ctx.cool or PASSIVE
    if c < d - 1e-9 then
      d = c
      why = (c <= PASSIVE + 1e-9) and string.format("cooling: nothing on its heat port sheds its %g kW, so it runs at %d %% (chain Radiator Panels or Jacket Radiators to it)", M.heat, math.floor(c * 100 + 0.5))
            or string.format("cooling: its loop sheds %d %% of the heat (add radiators, or part it from the other machines on the row)", math.floor(c * 100 + 0.5))
    end
  end
  if M.water or kind == "electrolyser" then
    local w = ctx.water
    if w and w < d - 1e-9 then d = w; why = (w <= 1e-9) and "no water: pipe water to its water nozzle" or string.format("water: its pipe brings %d %% of what it needs", math.floor(w * 100 + 0.5)) end
  end
  return math.max(0, math.min(1, d)), why
end

-- ── THE FABRICATOR'S QUEUE (event to event) ─────────────────────────────────
-- F = { q = { { id, n, t, started, done } … } }. env:
--   recipe(id) → { mats = { { mat, kg } }, fittings, secs } | nil
--   have(mat) → kg in the store; take(mats) → true (removes them)
--   pay(fittings) → true | false; put(id) → true | false (a crate into the store)
-- Runs `dt` seconds at `duty`. → why the head of the queue waits (or nil),
-- and the number of parts finished.
function fabAdvance(F, dt, d, env)
  F.q = F.q or {}
  local made, why = 0, nil
  local guard = 0
  while #F.q > 0 and guard < 64 do
    guard = guard + 1
    local j = F.q[1]
    local r = env.recipe(j.id)
    if not r then table.remove(F.q, 1); why = "it can't make that part"
    elseif j.done then
      if env.put(j.id) then
        made = made + 1
        j.done, j.started, j.t = nil, nil, 0
        j.n = (j.n or 1) - 1
        if j.n <= 0 then table.remove(F.q, 1) end
      else why = "its store has no room for the crate"; break end
    elseif not j.started then
      local short = nil
      for _, e in ipairs(r.mats or {}) do
        if (env.have(e.mat) or 0) + 1e-9 < e.kg then short = short or e end
      end
      if short then why = string.format("waiting for %s: %d of %d kg in its store", short.label or short.mat, math.floor(env.have(short.mat) or 0), short.kg); break end
      if (r.fittings or 0) > 0 and not env.pay(r.fittings) then why = string.format("fittings: $%d short", r.fittings); break end
      env.take(r.mats or {})
      j.started, j.t = true, 0
    else
      if d <= 1e-9 or dt <= 1e-12 then why = why or (d <= 1e-9 and "stopped" or nil); break end
      local need = (r.secs or 10) - (j.t or 0)
      local can = dt * d
      if can + 1e-9 >= need then
        dt = dt - need / d
        j.t = r.secs
        j.done = true
      else
        j.t = (j.t or 0) + can
        dt = 0
        break
      end
    end
  end
  return why, made
end

-- the queue's length in parts
function queued(F)
  local n = 0
  for _, j in ipairs((F and F.q) or {}) do n = n + (j.n or 1) end
  return n
end
