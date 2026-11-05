-- THERMAL — the rulebook for heat, reactors, fuel rods, radiators, the
-- isotope cell and radiation (deep-space addendum step 3: B1 B2 B3 B5 B6 A4 A6).
--
-- One file, no scene access, no state of its own, like electronics.lua: the
-- builder (the VAB's heat budget, the radiation cone it draws), the flight
-- (scripts/vessel_thermal.lua, which runs a craft's heat inside its 10 Hz
-- electrical tick), the crew (dose), the Materials Intake (fuel fabrication)
-- and the HUD all ask it the same questions. It is hosted on the Electronics
-- node beside electronics.lua and reached with findScript("thermal"); the
-- smoke test loads it straight from disk (tests/smoke_thermal.lua).
--
-- ── THE HEAT MODEL (B2) ─────────────────────────────────────────────────────
--
-- A craft has ONE heat loop, its temperature T: 0 = cold, 1 = 100 % (the
-- loop's rating). Heat SOURCES Q pour heat in (heat units, hu), SINKS reject
-- it in proportion to T (S hu at T = 1: a radiator rejects more the hotter it
-- runs), and the loop has a heat CAPACITY C (hu·s per unit T, the cores' and
-- the coolant's thermal mass):
--
--     C·dT/dt = Q − S·T      →      T_eq = Q / S,   k = S / C
--
-- With Q and S fixed over a step this has an exact solution, so a step of any
-- length is taken in one go, never by forward Euler (which overshoots at
-- 1000× warp and SCRAMs at random):
--
--     T(t + dt) = T_eq + (T − T_eq)·e^(−k·dt)                     (approach)
--
-- What changes Q inside a step is an EVENT: the loop crossing the SCRAM line,
-- a core's rods burning out, an NTR's governor band. `advance` finds the
-- first event's exact time (the closed form solved for T), steps to it,
-- applies it and carries on with the rest of the step — so ONE big step
-- lands exactly where many small ones do (the smoke test checks it), and the
-- same function catches a craft up on the save clock when it is loaded.
--
-- Sources:  a reactor core   heat × output while critical (fuel in it), or
--                            decay × heat while shut down with fuel aboard
--           an NTR core      the same, throttled down by its governor (A6)
--           the isotope cell heat (a little), always
--           a running engine engine_heat × throttle — but it carries its
--                            own nozzle sink, so engines alone settle at
--                            engine_heat / engine_sink (40 %) at most
-- Sinks:    the hull         hull_sink, every craft
--           a core's shell   its own `sink`; the isotope cell's fins
--           radiators        sink × deployed × health × pump × sunlight
--
-- 90 %: every critical reactor SCRAMs (control rods in, output 0) and stays
-- down until someone restarts it (A6: the restart waits restart_s game
-- seconds and a core under restart_T, and costs restart_rod seconds of rod
-- life). 100 % sustained: the hot parts take damage (vessel_thermal through
-- the vessel's set_part_damage).
--
-- ── RADIATION (A4) ──────────────────────────────────────────────────────────
--
-- Every reactor has `rad`: the share of a lethal dose an hour it gives a
-- crew member 5 m away in its cone at full output. The cone opens along the
-- core's +Y (up the stack it is built into: where the crew rides on a
-- rocket), 30° from the axis. The check is a dot product first; only crew in
-- the cone are traced. What stands between core and crew is counted by PART
-- RECORD — a part with a `shield` module (the Shadow Shield) lets through
-- shield_k, a full propellant tank tank_k — never by "a ray hit a solid", so
-- it holds when parts become hollow. The flight adds the ground (a ray
-- against the terrain); the VAB draws the cone from the same rule.
-- Dose is a number on the crew record (0..1, 1 = death, "radiation"); it
-- heals slowly at the base (dose_heal_half), with the same closed form.

THERMAL = {
  scram = 0.90,          -- T at which every critical reactor scrams
  damage = 1.00,         -- T above which the hot parts are damaged
  damage_rate = 0.004,   -- hp a game second, while above `damage`
  restart_T = 0.50,      -- a scrammed core restarts only below this
  restart_s = 60,        -- … and this many game seconds after the scram
  restart_rod = 90,      -- full-power seconds of rod life a start costs
  decay = 0.05,          -- a shut-down core with fuel still makes this share of its heat
  hull_sink = 0.5,       -- hu at T = 1: what any hull sheds on its own
  hull_cap = 60,         -- hu·s: the loop's own capacity
  engine_heat = 0.4,     -- hu from a running engine at full throttle
  engine_sink = 1.0,     -- … and its nozzle's own sink
  engine_cap = 20,
  sun_k = 0.35,          -- a radiator in full sunlight sheds this much less
  stowed = 0.15,         -- a folded radiator still sheds this share
  dry_pump = 0.25,       -- a radiator whose pump has no power: conduction only
  dead_hp = 0.25,        -- a radiator worn below this sheds nothing
  derate_lo = 0.75,      -- an NTR's governor starts throttling here …
  derate_hi = 0.90,      -- … and is closed here (A6: thrust fades, no scram)
  cone_deg = 30,         -- half-angle of a core's radiation cone
  dose_r0 = 5.0,         -- m: the distance `rad` is quoted at (closer is worse, 1/r²)
  dose_near = 1.0,       -- m: no closer than this in the inverse square
  dose_range = 120,      -- m: beyond this nobody is traced
  shield_k = 0.02,       -- a Shadow Shield lets through 2 %
  tank_k = 0.30,         -- a full propellant tank 30 % (two: 9 %)
  tank_full = 0.95,      -- "full" = at least this share of its propellant
  dose_heal_half = 172800, -- game seconds for half the dose to heal at the base (two days)
  catch_max = 30 * 86400,  -- the most a load catches up (game seconds)
}

-- Reactor and NTR cores, as data. Step 3 flies the Ember; the Furnace and
-- the Station Core are here for the rulebook's tests and for B4 (step 11).
--   ec    EC/s at full output        heat  hu at full output
--   sink  the core's own shell, hu   cap   its thermal mass, hu·s
--   rack  fuel rods it holds         life  full-power seconds per rod
--   rad   lethal-dose share an hour, 5 m in its cone, at full output
--   ntr   true: a rocket core with a governor (A6), never scrams on heat
CORES = {
  ember   = { ec = 6,   heat = 6,   sink = 1.0, cap = 800,  rack = 1,  life = 3600, rad = 0.5 },
  furnace = { ec = 25,  heat = 25,  sink = 1.5, cap = 3000, rack = 4,  life = 3600, rad = 2.0 },
  station = { ec = 100, heat = 100, sink = 4.0, cap = 9000, rack = 12, life = 5400, rad = 6.0 },
  pile    = { ec = 0.3, heat = 30,  sink = 2.0, cap = 1200, rack = 1,  life = 3600, rad = 3.0, ntr = true },
}

-- THE ISOTOPE CELL (B1): a radioisotope generator. Its output falls with the
-- isotope's decay: gen × 2^(−age / half). Game-compressed (Pu-238 halves in
-- 88 years): 400 game hours, so over a long career it loses a few per cent
-- and an old probe still has most of its power.
RTG = { gen = 0.5, heat = 0.25, sink = 0.6, cap = 30, half = 400 * 3600 }

-- B6: FUEL FABRICATION at the Materials Intake's radiological wing. 20 units
-- of uranium ore from the warehouse, $400 of power and consumables, ten game
-- minutes in the press; two rods in the queue at most. An Engineer sets the
-- press up (crew roles, J6: the fabrication gate).
FUEL_FAB = { ore = "uranium", units = 20, cost = 400, secs = 600, queue = 2, item = "fuelRod" }
-- A spent rod in someone's PACK doses them (hot: B5); in a locker, a hold or
-- the base store it doesn't.
SPENT_DOSE = 0.10 / 3600   -- dose a game second for each spent rod carried

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- ── the closed form ─────────────────────────────────────────────────────────
-- x stepped toward its balance point `eq` at rate k for dt (exact; k = 0
-- leaves x where it is). Heat, dose healing and the catch-up all use this.
function approach(x, eq, k, dt)
  if k <= 0 or dt <= 0 then return x end
  return eq + (x - eq) * math.exp(-k * dt)
end

-- The time the closed form takes from x to level L (nil if it never gets
-- there: L is not between x and eq).
function timeTo(x, eq, k, L)
  if k <= 0 then return nil end
  local a, b = eq - x, eq - L
  if a == 0 then return nil end
  if (L - x) * a <= 0 then return nil end    -- L is behind us
  if b * a <= 0 then return nil end          -- L is at or past the balance point
  return math.log(a / b) / k
end

-- ── what a part is, thermally ───────────────────────────────────────────────
-- A part's modules (electronics `mods`) tell everything: reactor, rtg,
-- radiator, shield. These answer with numbers the model and the HUD use.
function coreOf(m)
  if not m or m.type ~= "reactor" then return nil end
  local base = CORES[m.core or "ember"] or CORES.ember
  return {
    ec = m.ec or base.ec, heat = m.heat or base.heat, sink = m.sink or base.sink,
    cap = m.cap or base.cap, rack = m.rack or base.rack, life = m.life or base.life,
    rad = m.rad or base.rad, ntr = (m.ntr == true or m.ntr == 1 or m.ntr == "t") or base.ntr == true,
  }
end

-- Is a module type one of ours (a part the heat loop has to run for)?
HEAT_TYPES = { reactor = true, rtg = true, radiator = true }

-- A radiator's sink now: `m` the module (sink), `deploy` 0..1 (a fixed fin is
-- always 1), `hp` 0..1, `pump` 0..1 (its loop's pump served), `sun` 0..1
-- (direct sunlight on it).
function radiatorSink(m, deploy, hp, pump, sun)
  local s = m.sink or 1
  if hp ~= nil and hp < THERMAL.dead_hp then return 0 end
  local d = deploy == nil and 1 or clamp(deploy, 0, 1)
  local fold = THERMAL.stowed + (1 - THERMAL.stowed) * d
  local p = 1
  if (m.draw or 0) > 0 then p = THERMAL.dry_pump + (1 - THERMAL.dry_pump) * clamp(pump or 1, 0, 1) end
  return s * fold * clamp(hp or 1, 0, 1) * p * (1 - THERMAL.sun_k * clamp(sun or 0, 0, 1))
end

-- The isotope cell's output at `age` game seconds (B1).
function rtgOutput(m, age)
  local gen = (m and m.gen) or RTG.gen
  local half = (m and m.half) or RTG.half
  return gen * 2 ^ (-math.max(0, age or 0) / half)
end

-- ── the vessel's model ──────────────────────────────────────────────────────
-- From what is aboard now: `entries` = list of
--   { m = module, st = part state (reactor), deploy, hp, pump, throttle }
-- and `sun` (0..1, the craft's sunlight). → model:
--   S, C        sinks and capacity (fixed over a step)
--   base        heat from the non-core sources (isotope cells, engines)
--   cores       { { c = coreOf(m), st = st, out = 0..1 } … }  (st is live)
--   n           thermal parts (reactor, rtg, radiator) counted
function vesselModel(entries, sun)
  local M = { S = THERMAL.hull_sink, C = THERMAL.hull_cap, base = 0, cores = {}, n = 0,
              sinks = { hull = THERMAL.hull_sink, rad = 0, core = 0, engine = 0, rtg = 0 } }
  for _, e in ipairs(entries or {}) do
    local m, ty = e.m, e.m and e.m.type
    if ty == "reactor" then
      local c = coreOf(m)
      local hp = e.hp or 1
      M.S = M.S + c.sink * clamp(hp, 0, 1)
      M.sinks.core = M.sinks.core + c.sink * clamp(hp, 0, 1)
      M.C = M.C + c.cap
      local st = e.st or {}
      M.cores[#M.cores + 1] = { c = c, st = st, out = clamp((tonumber(st.output) or 100) / 100, 0, 1), uid = e.uid }
      M.n = M.n + 1
    elseif ty == "rtg" then
      M.base = M.base + (m.heat or RTG.heat)
      M.S = M.S + (m.sink or RTG.sink)
      M.sinks.rtg = M.sinks.rtg + (m.sink or RTG.sink)
      M.C = M.C + (m.cap or RTG.cap)
      M.n = M.n + 1
    elseif ty == "radiator" then
      local s = radiatorSink(m, e.deploy, e.hp, e.pump, sun)
      M.S = M.S + s
      M.sinks.rad = M.sinks.rad + s
      M.C = M.C + (m.cap or 10)
      M.n = M.n + 1
    elseif ty == "engine" then
      M.base = M.base + THERMAL.engine_heat * clamp(e.throttle or 0, 0, 1)
      M.S = M.S + THERMAL.engine_sink
      M.sinks.engine = M.sinks.engine + THERMAL.engine_sink
      M.C = M.C + THERMAL.engine_cap
    end
  end
  return M
end

-- Is this core making power and full heat? (critical with fuel in it)
local function live(k)
  local st = k.st
  return st.critical == true and (tonumber(st.life) or 0) > 0
end
local function fuelled(k) return (tonumber(st_rods(k.st)) or 0) > 0 end
function st_rods(st) return tonumber(st and st.rods) or 0 end

-- An NTR's governor at temperature T: the share of its throttle it allows.
function governor(T)
  local lo, hi = THERMAL.derate_lo, THERMAL.derate_hi
  if T <= lo then return 1 end
  if T >= hi then return 0 end
  return (hi - T) / (hi - lo)
end

-- The linear pieces of Q(T) = a − b·T over the band T sits in (with the
-- direction it is moving, for a T exactly on a band edge). Returns a, b and
-- the band's edges [lo, hi).
local function q_linear(M, T, dir)
  local lo, hi = THERMAL.derate_lo, THERMAL.derate_hi
  local band
  local t = T + (dir or 0) * 1e-12
  if t < lo then band = 0 elseif t < hi then band = 1 else band = 2 end
  local a, b = M.base, 0
  for _, k in ipairs(M.cores) do
    if live(k) then
      local q = k.c.heat * k.out
      if k.c.ntr then
        if band == 0 then a = a + q
        elseif band == 1 then a = a + q * hi / (hi - lo); b = b + q / (hi - lo) end
      else
        a = a + q
      end
    elseif fuelled(k) then
      a = a + k.c.heat * THERMAL.decay
    end
  end
  local e0, e1 = -math.huge, math.huge
  for _, k in ipairs(M.cores) do
    if k.c.ntr and live(k) then
      if band == 0 then e1 = lo elseif band == 1 then e0, e1 = lo, hi else e0 = hi end
      break
    end
  end
  return a, b, e0, e1, band
end

-- The share of throttle a core gives right now (its governor for an NTR).
function coreShare(k, T)
  if not live(k) then return 0 end
  if k.c.ntr then return k.out * governor(T) end
  return k.out
end

-- Where the loop settles with what is running now (the HUD's "settles at").
function settle(M, T)
  local a, b = q_linear(M, T or 0, 0)
  return a / math.max(1e-9, M.S + b)
end

-- Rod life burnt over t by core k in governor band `band` (0 open, 1 the
-- governor's linear band, 2 shut): ∫ share dt, T on its exponential.
local function burn_over(k, T0, Teq, kk, t, band)
  if not live(k) or t <= 0 then return 0 end
  if not k.c.ntr or band == 0 then return k.out * t end
  if band == 2 then return 0 end
  local L, H = THERMAL.derate_lo, THERMAL.derate_hi
  local intT = Teq * t + (T0 - Teq) * (kk > 0 and (1 - math.exp(-kk * t)) / kk or t)
  return k.out * (H * t - intT) / (H - L)
end

-- ── ADVANCE: the one step ───────────────────────────────────────────────────
-- Step the loop `state` (T, plus `dir`, its last motion) through `dt` game
-- seconds with model M, starting at game time `now` (for scram stamps).
-- Writes the cores' st (life, critical, scram) in place. Returns a report:
--   scram   the game time of a scram in this step (nil: none)
--   spent   { core index → true } whose rods ran out in it
--   over    game seconds above THERMAL.damage
--   peak    the highest T in the step
function advance(state, M, dt, now)
  local rep = { over = 0, peak = state.T or 0, spent = {}, scram = nil }
  local T = state.T or 0
  local dir = state.dir or 0
  local left = math.max(0, dt or 0)
  local t_at = now or 0
  local guard = 0
  while left > 1e-12 and guard < 64 do
    guard = guard + 1
    local a, b, e0, e1, band = q_linear(M, T, dir)
    local SS = M.S + b
    local k = SS / math.max(1e-9, M.C)
    local Teq = a / math.max(1e-9, SS)
    -- the first event in what is left of the step
    local t_ev, ev, lvl = left, nil, nil
    local function try(t, e, L)
      if t and t >= 0 and t < t_ev then t_ev, ev, lvl = t, e, L end
    end
    local any_crit = false
    for _, kc in ipairs(M.cores) do if live(kc) and not kc.c.ntr then any_crit = true end end
    if any_crit and T < THERMAL.scram then try(timeTo(T, Teq, k, THERMAL.scram), "scram", THERMAL.scram) end
    if e1 < math.huge and T < e1 then try(timeTo(T, Teq, k, e1), "band", e1) end
    if e0 > -math.huge and T > e0 then try(timeTo(T, Teq, k, e0), "band", e0) end
    if T < THERMAL.damage then try(timeTo(T, Teq, k, THERMAL.damage), "hot", THERMAL.damage)
    elseif T > THERMAL.damage then try(timeTo(T, Teq, k, THERMAL.damage), "cool", THERMAL.damage) end
    -- rods running out (the burn is linear outside the governor band; in it,
    -- found by bisection on the closed-form integral)
    for i, kc in ipairs(M.cores) do
      if live(kc) then
        local life = tonumber(kc.st.life) or 0
        if burn_over(kc, T, Teq, k, t_ev, band) >= life then
          local hit
          if not kc.c.ntr or band == 0 then
            hit = life / math.max(1e-12, kc.out)
          else
            local lo_t, hi_t = 0, t_ev
            for _ = 1, 64 do
              local mid = 0.5 * (lo_t + hi_t)
              if burn_over(kc, T, Teq, k, mid, band) >= life then hi_t = mid else lo_t = mid end
            end
            hit = hi_t
          end
          if hit <= t_ev then t_ev, ev, lvl = hit, "rods", i end
        end
      end
    end
    -- step to it
    local T1 = approach(T, Teq, k, t_ev)
    if ev == "scram" or ev == "band" or ev == "hot" or ev == "cool" then T1 = lvl end
    for i, kc in ipairs(M.cores) do
      if live(kc) then
        local used = (ev == "rods" and lvl == i) and (tonumber(kc.st.life) or 0) or burn_over(kc, T, Teq, k, t_ev, band)
        kc.st.life = math.max(0, (tonumber(kc.st.life) or 0) - used)
      end
    end
    if T >= THERMAL.damage and T1 >= THERMAL.damage - 1e-12 then rep.over = rep.over + t_ev end
    if T1 > rep.peak then rep.peak = T1 end
    if T1 ~= T then dir = (T1 > T) and 1 or -1 end
    T = T1
    t_at = t_at + t_ev
    left = left - t_ev
    if ev == "scram" then
      for _, kc in ipairs(M.cores) do
        if live(kc) and not kc.c.ntr then kc.st.critical = false; kc.st.scram = t_at end
      end
      rep.scram = t_at
      dir = 1
    elseif ev == "rods" then
      local kc = M.cores[lvl]
      kc.st.life = 0
      kc.st.critical = false
      rep.spent[lvl] = true
    end
  end
  state.T, state.dir = T, dir
  return rep
end

-- ── A6: starting a core ─────────────────────────────────────────────────────
-- Why core state `st` can't go critical now (nil: it can). `T` the loop,
-- `now` game time.
function startWhyNot(st, T, now)
  if (tonumber(st.life) or 0) <= 0 then
    return st_rods(st) > 0 and "the fuel rods are spent — swap them" or "no fuel rods loaded"
  end
  local sc = tonumber(st.scram)
  if sc and now and now - sc < THERMAL.restart_s then
    return string.format("cooling after the scram — %d s", math.ceil(THERMAL.restart_s - (now - sc)))
  end
  if (T or 0) > THERMAL.restart_T then
    return string.format("core too hot to restart (%d%%, under %d%%)", math.floor(T * 100 + 0.5),
      math.floor(THERMAL.restart_T * 100 + 0.5))
  end
  return nil
end

-- Take a start: its cost in rod life. Returns the life left.
function startCost(st)
  st.life = math.max(0, (tonumber(st.life) or 0) - THERMAL.restart_rod)
  return st.life
end

-- Rods: `st.rods` loaded (count), `st.life` full-power seconds left in all of
-- them together. A rod is spent once the life left would no longer fill it.
function rodsLive(st, c)
  local per = (c and c.life) or 3600
  return math.min(st_rods(st), math.ceil(math.max(0, tonumber(st.life) or 0) / per - 1e-9))
end
function rodsSpent(st, c) return st_rods(st) - rodsLive(st, c) end

-- Load one fresh rod into core `c`'s rack. → ok, why
function loadRod(st, c)
  if st_rods(st) >= (c.rack or 1) then return false, "the rack is full" end
  st.rods = st_rods(st) + 1
  st.life = (tonumber(st.life) or 0) + (c.life or 3600)
  return true
end

-- Take one spent rod out. → ok, why
function unloadSpent(st, c)
  if rodsSpent(st, c) <= 0 then return false, "no spent rod in the rack" end
  if st.critical then return false, "shut the core down first" end
  st.rods = st_rods(st) - 1
  return true
end

-- ── A4: the radiation cone ──────────────────────────────────────────────────
-- core: { x,y,z  ax,ay,az (unit, the cone's axis), rad, share (0..1 output
-- now; a shut-down fuelled core gives its `decay`) }. A point p. Returns
-- (in the cone, the DIRECT dose rate a game second before shielding,
-- cos of the angle). The cheap test: one dot product.
function coneAt(core, px, py, pz)
  local dx, dy, dz = px - core.x, py - core.y, pz - core.z
  local r2 = dx * dx + dy * dy + dz * dz
  if r2 > THERMAL.dose_range * THERMAL.dose_range then return false, 0, -1 end
  local r = math.sqrt(math.max(r2, 1e-12))
  local c = (dx * core.ax + dy * core.ay + dz * core.az) / r
  if c < math.cos(math.rad(THERMAL.cone_deg)) then return false, 0, c end
  local rr = math.max(r, THERMAL.dose_near)
  local rate = (core.rad or 0) * (core.share or 0) * (THERMAL.dose_r0 / rr) ^ 2 / 3600
  return true, rate, c
end

-- Does the segment a→b pass through the oriented box (centre c, axes X Y Z,
-- half-extents h)? Slab test in the box's frame.
function segHitsBox(ax, ay, az, bx, by, bz, box)
  local X, Y, Z = box.X or { x = 1, y = 0, z = 0 }, box.Y or { x = 0, y = 1, z = 0 }, box.Z or { x = 0, y = 0, z = 1 }
  local ox, oy, oz = ax - box.x, ay - box.y, az - box.z
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local t0, t1 = 0, 1
  local axes = { { X, box.hx }, { Y, box.hy }, { Z, box.hz } }
  for _, A in ipairs(axes) do
    local u, h = A[1], A[2]
    local o = ox * u.x + oy * u.y + oz * u.z
    local d = dx * u.x + dy * u.y + dz * u.z
    if math.abs(d) < 1e-12 then
      if math.abs(o) > h then return false end
    else
      local ta, tb = (-h - o) / d, (h - o) / d
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return false end
    end
  end
  return true
end

-- What the parts between a core and a point let through: the product of the
-- `k` of every blocker box the segment crosses (`skip` a uid set to leave
-- out: the core itself, the seat the crew is in). → factor, count.
function shieldFactor(cx, cy, cz, px, py, pz, blockers, skip)
  local f, n = 1, 0
  for _, b in ipairs(blockers or {}) do
    if not (skip and b.uid and skip[b.uid]) and (b.k or 1) < 1 then
      if segHitsBox(cx, cy, cz, px, py, pz, b) then f = f * b.k; n = n + 1 end
    end
  end
  return f, n
end

-- The whole rule for one point: cone, inverse square, shielding by record.
-- → rate (dose a game second), in cone, blockers counted.
function doseRate(core, px, py, pz, blockers, skip)
  local inside, rate = coneAt(core, px, py, pz)
  if not inside or rate <= 0 then return 0, inside, 0 end
  local f, n = shieldFactor(core.x, core.y, core.z, px, py, pz, blockers, skip)
  return rate * f, true, n
end

-- What a part is as a blocker (from its modules and record): its shielding
-- share, or nil when it lets everything through. `fill` 0..1 for a tank.
function blockerK(mods, rec, fill)
  for _, m in ipairs(mods or {}) do
    if m.type == "shield" then return m.k or THERMAL.shield_k end
  end
  if rec and (rec.kind == "tank") and (rec.fuel or 0) > 0 and (fill or 1) >= THERMAL.tank_full then
    return THERMAL.tank_k
  end
  return nil
end

-- A core's share for the dose: its output now, or its decay heat's share
-- while shut down with fuel in it.
function radShare(k, T)
  if live(k) then return coreShare(k, T or 0) end
  if fuelled(k) then return THERMAL.decay end
  return 0
end

-- ── dose (crew records) ─────────────────────────────────────────────────────
-- One member's dose over dt game seconds: `rate` (a second, from the cones
-- and any spent rods carried) and `heal` (at the base). Linear while exposed;
-- toward 0 by the closed form while healing. → the new dose (0..1+).
function doseStep(dose, rate, heal, dt)
  dose = (dose or 0) + math.max(0, rate or 0) * math.max(0, dt or 0)
  if heal then
    dose = approach(dose, 0, math.log(2) / THERMAL.dose_heal_half, dt)
    if dose < 1e-5 then dose = 0 end
  end
  return dose
end

-- ── B6: fuel fabrication ────────────────────────────────────────────────────
-- Why a rod can't be started now (nil: it can). `have` units of ore in the
-- warehouse, `money`, the queue, and whether an Engineer is there.
function fabWhyNot(have, money, queue, engineer, unlocked)
  if unlocked == false then return "research the Ember Reactor first" end
  if not engineer then return "an Engineer has to set up the press" end
  if #(queue or {}) >= FUEL_FAB.queue then return "the press is full — two rods at a time" end
  if (have or 0) < FUEL_FAB.units then
    return string.format("needs %d units of uranium ore in the warehouse (have %d)", FUEL_FAB.units, math.floor(have or 0))
  end
  if money and money < FUEL_FAB.cost then return "not enough funds" end
  return nil
end

-- A new job in the queue at game time `now`: it starts when the one before
-- it finishes. → the job.
function fabQueue(queue, now, by)
  local start = now
  for _, j in ipairs(queue) do start = math.max(start, j.t1 or now) end
  local j = { t0 = start, t1 = start + FUEL_FAB.secs, by = by }
  queue[#queue + 1] = j
  return j
end

-- The jobs done by `now`, taken off the queue (order kept). → done list.
function fabTake(queue, now)
  local done, i = {}, 1
  while queue[i] do
    if (queue[i].t1 or math.huge) <= now then
      done[#done + 1] = table.remove(queue, i)
    else
      i = i + 1
    end
  end
  return done
end

-- Share of the head job done (the board's bar).
function fabProgress(queue, now)
  local j = queue and queue[1]
  if not j then return nil end
  return clamp((now - j.t0) / math.max(1, j.t1 - j.t0), 0, 1)
end

-- ── one line for the HUD / the inspector ────────────────────────────────────
function pct(x) return math.floor(math.max(0, x or 0) * 100 + 0.5) end
