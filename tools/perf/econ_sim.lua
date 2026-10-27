-- ECONOMY SIMULATION — pure Lua, no engine.
--
-- Loads a Solar tree's REAL economy scripts (company, missions, materials,
-- research, the three part registries) into a stubbed environment and plays
-- three scripted players against them, in game minutes:
--
--   A  a new player's first 30 minutes (mine → First Flight → the ladder,
--      ground work between flights where the tree has it)
--   B  a mid-game company that crashes three expensive rockets in a row, and
--      how long it takes to get back to the balance it had
--   C  a rover-focused player who never flies: 30 minutes of ground work
--
-- Prices, rewards, research costs, the recovery rate, the freight rate and the
-- advance all come from the tree, so running it on the old scripts (a `git
-- show HEAD:` copy) and on the working tree gives a before/after on the same
-- player model. The PLAYER MODEL (how long a trip takes, what a pack holds) is
-- here, stated once, and is the same for both trees.
--
--   luajit tools/perf/econ_sim.lua <before-root> <after-root>
--   (each root holds scripts/; with one root it prints just that tree)
--
-- tests/smoke_economy.lua runs it on the working tree and holds it to targets.

local M = {}

-- ── the player model (minutes, kilograms) ──────────────────────────────────
M.MODEL = {
  hand_min = 2.5,     -- fill a 90 kg suit pack at 2–6 m depth, walk back, sell
  hand_kg = 90,
  rover_min = 3.5,    -- fill a rover's hold, drive back, park at the depot
  rover_kg = 240,     -- three Stowage Lockers (or a Cargo Bay's 250)
  drive_mps = 7.0,    -- a rover on Wheel M; a bike does 16
  trek_extra = 1.0,   -- getting going and parking, minutes
  build_min = 1.0,    -- the builder, per flight
  flight_min = { starter = 2.0, highroad = 3.0, orbiter = 5.0, moonship = 8.0 },
}

-- What a craft is made of. Costs are summed from the tree's registries.
M.CRAFT = {
  starter  = { "pod", "chute", "tankS", "engineS" },
  highroad = { "pod", "chute", "tankM", "engineS", "legs", "legs", "legs" },
  orbiter  = { "pod", "chute", "engineM", "tankM", "tankM", "legs", "legs", "legs", "legs",
               "decoupler", "engineS", "tankS", "fins", "fins", "fins", "nose" },
  moonship = { "pod", "chute", "engineM", "tankM", "tankM", "legs", "legs", "legs", "legs",
               "decoupler", "skipper", "tankM", "tankM", "tankM", "fins", "fins", "fins", "fins" },
  probe    = { "probe", "dish", "battery", "solar", "solar", "engineM", "tankM", "decoupler",
               "skipper", "tankM", "tankM", "nose" },
  docking  = { "pod", "chute", "dockPort", "rcs", "rcs", "rcs", "rcs", "tankM", "engineS",
               "pod", "chute", "dockPort", "rcs", "rcs", "rcs", "rcs", "tankM", "engineS" },
  bike     = { "wheelB", "wheelB", "forkT", "swingArm", "saddle", "packB", "gyro", "beam2" },
  rover    = { "roverBody", "wheelM", "wheelM", "wheelM", "wheelM", "seat", "locker", "locker", "locker" },
  plane    = { "cockpit", "fuseTank", "jet", "intake", "intake", "wingL", "wingL", "wingTip",
               "wingTip", "elevon", "elevon", "tailFin", "gearS", "gearS", "gearS" },
}

-- ── a stubbed engine, one per tree ─────────────────────────────────────────
local function world(root)
  local store, T = {}, 0
  local W = { store = store }
  local API = {}
  API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
               flush = function() end }
  API.log = function() end
  API.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local BODIES = {
    Sol  = { name = "Sol", x = 0, y = 0, z = 0, radius = 5000, mu = 1e9, soi = -1 },
    Home = { name = "Home", x = 60000, y = 0, z = 0, radius = 700, mu = 2.5e6, soi = 8400 },
    Moon = { name = "Moon", x = 66000, y = 0, z = 0, radius = 220, mu = 2.0e5, soi = 1200 },
  }
  API.space = {
    bodies = function() return { BODIES.Sol, BODIES.Home, BODIES.Moon } end,
    body = function(n) return BODIES[n] end,
    dominant = function() return "Home" end,
  }
  store["base.body"] = "Home"
  store["system.home"] = { star = "Sol", mu = 1e9, bodies = {
    { name = "Home", kind = "canyon", parent = "Sol", a = 60000, radius = 700, relief = 40,
      mu = 2.5e6, atmo = 0.8 },
    { name = "Moon", kind = "barren", parent = "Home", a = 6000, radius = 220, relief = 12,
      mu = 2.0e5, atmo = 0 },
  } }
  local envs = {}
  W.API, W.envs, W.BODIES = API, envs, BODIES
  W.scripts = {}      -- kind → { handles } a test adds (a vessel_controller)
  API.findScript = function(k) return envs[k] or (W.scripts[k] and W.scripts[k][1]) end
  API.findScripts = function(k)
    if W.scripts[k] then return W.scripts[k] end
    return envs[k] and { envs[k] } or {}
  end
  local function load(rel, kind)
    local path = root .. "/" .. rel
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local env = setmetatable({}, { __index = function(_, k)
      if k == "time" then return T end
      return API[k] or _G[k]
    end })
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    chunk()
    env.params = {}
    for k, v in pairs(env.defaults or {}) do env.params[k] = v end
    envs[kind] = env
    return env
  end
  W.co = load("scripts/company.lua", "company")
  W.mats = load("scripts/materials.lua", "materials")
  W.inv = load("scripts/inventory.lua", "inventory")
  W.rs = load("scripts/research.lua", "research")
  W.mi = load("scripts/missions.lua", "missions")
  W.reg = load("scripts/parts_registry.lua", "parts_registry")
  W.auto = load("scripts/parts_auto.lua", "parts_auto")
  W.aero = load("scripts/parts_aero.lua", "parts_aero")
  W.co.start({})
  W.mi.start({})
  -- Figures that live in scripts the harness doesn't load whole.
  local function grab(rel, pat)
    local f = io.open(root .. "/" .. rel, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return tonumber(s:match(pat))
  end
  W.recover = grab("scripts/vessel_controller.lua", "local RECOVER_RATE = ([%d%.]+)") or 0.65
  W.freight = grab("scripts/facility_menu.lua", "\nFREIGHT_RATE = ([%d%.]+)") or 0
  W.hire = grab("scripts/crew.lua", "hire_base = (%d+)")
  W.cost = function(id)
    local d = W.reg.REG[id] or (W.auto and W.auto.PARTS[id]) or (W.aero and W.aero.PARTS[id])
    assert(d, "no part " .. id)
    return d.cost
  end
  W.craft = function(name)
    local c = 0
    for _, id in ipairs(M.CRAFT[name]) do c = c + W.cost(id) end
    return c
  end
  local here = { x = 60000, y = 0, z = 0 }
  W.time = function() return T end
  W.tick = function(n)
    for _ = 1, n or 1 do T = T + 1 / 60; W.co.update({}, 1 / 60) end
    W.mi.update(here, 1 / 60)      -- the board refills once a second
  end
  return W
end
M.world = world

-- ── a company being played ─────────────────────────────────────────────────
local function player(W)
  local P = { t = 0.0, W = W, log = {}, marks = {}, rover = false, sold = {}, launches = 0 }
  local co, mats = W.co, W.mats
  local function note(fmt, ...) P.log[#P.log + 1] = string.format("%5.1f  ", P.t) .. string.format(fmt, ...) end
  P.note = note
  local function pass(min)
    -- the clock, sampling the balance at whole minutes
    local t1 = P.t + min
    for m = math.floor(P.t) + 1, math.floor(t1) do
      if not P.marks[m] then P.marks[m] = co.balance() end
    end
    P.t = t1
    W.tick(math.floor(4.0 / (1 / 60)))   -- the advance looks for a few seconds of being broke
  end
  P.pass = pass

  -- A load of home ground at 2–6 m (canyon: regolith, silica, iron by weight),
  -- or plant matter: $ for `kg`, and its discovery premiums the first time.
  local function load_value(kg, flora)
    local mix = flora and { { "timber", 1 }, { "fiber", 1 }, { "biomass", 1 } }
                      or  { { "regolith", 6.0 }, { "silica", 2.5 }, { "iron", 3.0 } }
    local wsum, kgu = 0, 0
    for _, e in ipairs(mix) do wsum = wsum + e[2]; kgu = kgu + e[2] * mats.kg(e[1]) end
    local units = kg / (kgu / wsum)
    local v, bonus = 0, 0
    for _, e in ipairs(mix) do
      v = v + units * e[2] / wsum * mats.value(e[1])
      if not P.sold[e[1]] then
        P.sold[e[1]] = true
        bonus = bonus + (mats.discoveryBonus and mats.discoveryBonus(e[1]) or 0)
      end
    end
    return v * co.priceMult(), bonus
  end
  P.load_value = load_value

  local trips = 0
  function P.hand_trip()
    trips = trips + 1
    local flora = (trips % 3 == 2)
    local v, b = load_value(M.MODEL.hand_kg, flora)
    pass(M.MODEL.hand_min)
    co.earn(math.floor(v), "materials sold")
    if b > 0 then co.earn(b, "discovery premium") end
    -- First Steps: a plant and some ore
    if trips == 2 then P.first_steps() end
    return v + b
  end
  function P.rover_trip()
    trips = trips + 1
    local v = load_value(M.MODEL.rover_kg, false)
    pass(M.MODEL.rover_min)
    if trips >= 2 then P.first_steps() end
    v = v * (1 + W.freight)
    co.earn(math.floor(v), "materials sold (rover)")
    return v
  end
  function P.first_steps()
    local pd = W.store["prog.done"] or {}
    if pd.first_steps then return end
    pd.first_steps = true
    W.store["prog.done"] = pd
    for _, m in ipairs(W.mi.PROGRAMME or {}) do
      if m.id == "first_steps" then co.earn(m.reward or 0, "milestone") end
    end
  end
  function P.buy(name, why)
    local c = W.craft(name)
    if not co.spend(c, why or name) then return false end
    return true
  end
  function P.research(id)
    if W.rs.isUnlocked(id) then return true end
    local d = W.store["res.done"] or {}
    if not co.spend(W.rs.costOf(id), "research " .. id) then return false end
    d[id] = true
    W.store["res.done"] = d
    return true
  end
  -- Fly a hull: buy it, fly it, get paid, recover it (or lose it).
  function P.fly(hull, reward, title, lost)
    local c = W.craft(hull)
    if not co.spend(c, "hull " .. hull) then return false end
    P.launches = P.launches + 1
    if not P.first_launch then P.first_launch = P.t end
    pass(M.MODEL.build_min + (M.MODEL.flight_min[hull] or 4))
    if lost then
      note("%-28s LOST  −%s", title, co.money(c))
      return true
    end
    if reward and reward > 0 then co.earn(reward, "contract " .. title) end
    co.earn(math.floor(c * W.recover), "recovered")
    note("%-28s +%s  (hull %s, refund %s)", title, co.money(reward or 0), co.money(c),
      co.money(math.floor(c * W.recover)))
    return true
  end
  -- The generated ground work on offer right now (empty in a tree without it).
  function P.ground_offers()
    local out = {}
    if not (W.mi.GROUND) then return out end
    for _, s in ipairs(W.mi.offers()) do if s.ground then out[#out + 1] = s end end
    return out
  end
  -- Do the best ground job on the board, or the best plain earning; returns
  -- what it earned.
  function P.ground_work()
    local best, best_rate, how = nil, -1, nil
    -- plain depot runs
    local hv = load_value(M.MODEL.hand_kg, false)
    best_rate, how = hv / M.MODEL.hand_min, "hand"
    if P.rover then
      local rv = load_value(M.MODEL.rover_kg, false) * (1 + W.freight)
      if rv / M.MODEL.rover_min > best_rate then best_rate, how = rv / M.MODEL.rover_min, "rover" end
    end
    for _, s in ipairs(P.ground_offers()) do
      local g = s.goals[1]
      local min
      if s.kind == "trek" then
        min = P.rover and (g.value / M.MODEL.drive_mps / 60 + M.MODEL.trek_extra) or nil
      elseif g.kg and g.kg <= M.MODEL.hand_kg then
        min = M.MODEL.hand_min
      elseif P.rover then
        min = M.MODEL.rover_min * math.ceil(g.kg / M.MODEL.rover_kg)
      end
      if min and s.reward / min > best_rate then best, best_rate, how = s, s.reward / min, s.kind end
    end
    if best then
      local min
      local g = best.goals[1]
      if best.kind == "trek" then min = g.value / M.MODEL.drive_mps / 60 + M.MODEL.trek_extra
      elseif g.kg <= M.MODEL.hand_kg then min = M.MODEL.hand_min
      else min = M.MODEL.rover_min * math.ceil(g.kg / M.MODEL.rover_kg) end
      W.mi.accept(best.id)
      pass(min)
      W.mi.forceComplete()
      note("ground: %-36s +%s  (%.1f min)", best.title, co.money(best.reward), min)
      P.jobs = (P.jobs or 0) + 1
      return best.reward
    end
    if how == "rover" then return P.rover_trip() end
    return P.hand_trip()
  end
  -- earn by the ground until the balance reaches `want` (or time runs out)
  function P.raise(want, until_t)
    while co.balance() < want and P.t < (until_t or 1e9) do P.ground_work() end
  end
  return P
end
M.player = player

-- What a ground contract of each kind pays at this standing (nil without).
local function ground_table(W)
  if not W.mi.GROUND then return nil end
  W.store["prog.done"] = { first_steps = true }
  local out = {}
  for _, k in ipairs({ "order", "bulk", "trek" }) do
    local sp = W.mi.genSpec(k, "Home", 1)
    out[k] = sp and { reward = sp.reward, title = sp.title } or nil
  end
  W.store["prog.done"] = nil
  return out
end

-- ── scenario A: the first 30 minutes ───────────────────────────────────────
function M.scenarioA(root)
  local W = world(root)
  local P = player(W)
  local co, mi = W.co, W.mi
  local LADDER = {}
  for _, m in ipairs(mi.offers()) do LADDER[m.id] = m end
  local function reward(id)
    local m = mi.byId(id)
    return m and m.reward or 0
  end
  P.raise(W.craft("starter"))
  P.fly("starter", reward("firstflight"), "First Flight")
  W.store["co.rep"] = 1
  W.store["mission.done"] = { firstflight = true }
  -- Then the ladder, cheapest flight work first, ground work between.
  local function want_rover()
    -- a rover once it pays for itself within the session
    if P.rover or P.t > 20 then return end
    local rc = W.craft("rover")
    local gain = P.load_value(M.MODEL.rover_kg, false) * (1 + W.freight) / M.MODEL.rover_min
      - P.load_value(M.MODEL.hand_kg, false) / M.MODEL.hand_min
    if mi.GROUND then gain = gain + 300 end    -- bulk hauls and drives open up
    if gain * (30 - P.t) > rc * 1.5 and co.balance() > rc + 300 then
      co.spend(rc, "rover")
      P.rover = true
      P.note("bought a rover %s", co.money(rc))
    end
  end
  local steps = {
    { id = "prospect", ground = true },
    { id = "botany", ground = true },
    { id = "highroad", hull = "highroad", tech = { "tankM" } },
    { id = "recovery", hull = "starter" },
    { id = "deepcore", ground = true, extra = 2 },
    { id = "orbit", hull = "orbiter", tech = { "tankM", "engineM" } },
  }
  for _, st in ipairs(steps) do
    if P.t >= 30 then break end
    want_rover()
    if st.ground then
      -- a delivery: a trip or two of the right stuff, plus the sale
      P.pass(M.MODEL.hand_min * (st.extra or 1))
      co.earn(reward(st.id), "contract " .. st.id)
      P.note("%-28s +%s", st.id, co.money(reward(st.id)))
    else
      local need = W.craft(st.hull)
      for _, t in ipairs(st.tech or {}) do
        if not W.rs.isUnlocked(t) then need = need + W.rs.costOf(t) end
      end
      P.raise(need, 30)
      if P.t >= 30 then break end
      for _, t in ipairs(st.tech or {}) do P.research(t) end
      P.fly(st.hull, reward(st.id), st.id)
    end
    local d = W.store["mission.done"] or {}
    d[st.id] = true
    W.store["mission.done"] = d
  end
  while P.t < 30 do want_rover(); P.ground_work() end
  return { first_launch = P.first_launch, marks = P.marks, log = P.log, rover = P.rover,
           jobs = P.jobs or 0, bal = co.balance() }
end

-- ── scenario B: three crashed rockets ──────────────────────────────────────
-- A company at Made Orbit, a rover in the shed, `start` in the bank, crashes
-- three orbiters (the two-stage Anvil rocket a moon contract wants) in a row.
-- How long until it's back where it was? The way back is ground work and the
-- board's best moon contract, flown with the same rocket.
function M.scenarioB(root, start)
  local W = world(root)
  local P = player(W)
  local co, mi = W.co, W.mi
  W.store["mission.done"] = { firstflight = true, recovery = true, botany = true, prospect = true,
                              highroad = true, deepcore = true, orbit = true }
  W.store["prog.done"] = { first_steps = true }
  W.store["res.done"] = { tankM = true, engineM = true, battery = true, cargo = true,
                          skipper = true }
  W.store["co.rep"] = 8                                         -- Trusted
  for k in pairs(P.sold) do P.sold[k] = true end
  for _, m in ipairs({ "regolith", "silica", "iron", "timber", "fiber", "biomass" }) do P.sold[m] = true end
  co.spend(co.balance(), "reset")
  co.earn(start, "the company so far")
  P.rover = true
  local hull = W.craft("orbiter")
  for i = 1, 3 do P.fly("orbiter", 0, "orbiter #" .. i, true) end
  local low = co.balance()
  P.t0 = P.t
  -- one good contract: the board's best moon work, flown with a moonship
  local function good()
    local best
    for _, k in ipairs({ "survey", "orbit", "land" }) do
      local sp = mi.genSpec(k, "Moon", 1)
      if sp and (not best or sp.reward > best.reward) and not (P.flown or {})[k] then best = sp end
    end
    return best
  end
  P.flown = {}
  local guard = 0
  while co.balance() < start and guard < 200 do
    guard = guard + 1
    local g = good()
    if g and co.balance() >= hull then
      P.flown[g.kind] = true
      P.fly("orbiter", g.reward, g.title)
    else
      P.ground_work()
    end
  end
  return { hull = hull, loss = 3 * hull, low = low, minutes = P.t - P.t0, log = P.log,
           loans = W.store["co.loans"] or 0, jobs = P.jobs or 0, owed = co.owed and co.owed() or 0 }
end

-- ── scenario B2: the early crash ───────────────────────────────────────────
-- The playtest's case: a young company (First Flight, Prospector and Field
-- Botany done, standing Unknown, no rover) with `start` in the bank tries The
-- High Road three times and crashes all three. Back to `start`, and the High
-- Road flown, is the way out — by hand, by rover if it pays, by ground work
-- and Mission Control's advance where the tree has them.
function M.scenarioB2(root, start, ground_only)
  local W = world(root)
  local P = player(W)
  local co, mi = W.co, W.mi
  W.store["mission.done"] = { firstflight = true, prospect = true, botany = true }
  W.store["prog.done"] = { first_steps = true }
  W.store["res.done"] = { tankM = true }
  W.store["co.rep"] = 3
  for _, m in ipairs({ "regolith", "silica", "iron", "timber", "fiber", "biomass" }) do P.sold[m] = true end
  co.spend(co.balance(), "reset")
  co.earn(start, "the company so far")
  local hull = W.craft("highroad")
  for i = 1, 3 do P.fly("highroad", 0, "High Road attempt #" .. i, true) end
  local low = co.balance()
  W.tick(600)                       -- broke for a while: does anyone step in?
  local after_wait = co.balance()
  P.t0 = P.t
  local rc = W.craft("rover")
  local flew = false
  local guard = 0
  if ground_only then flew = true end
  while (co.balance() < start or not flew) and guard < 400 do
    guard = guard + 1
    -- a rover, once it is a small share of what's in the bank
    if not P.rover and co.balance() > rc * 1.6 and rc < 1000 then
      co.spend(rc, "rover"); P.rover = true; P.note("bought a rover %s", co.money(rc))
    end
    if not flew and co.balance() >= hull + 200 then
      flew = true
      P.fly("highroad", mi.byId("highroad").reward, "The High Road")
    else
      P.ground_work()
    end
  end
  return { hull = hull, loss = 3 * hull, low = low, after_wait = after_wait, minutes = P.t - P.t0,
           log = P.log, loans = W.store["co.loans"] or 0, jobs = P.jobs or 0,
           owed = co.owed and co.owed() or 0, rover = P.rover }
end

-- ── scenario C: the rover player ───────────────────────────────────────────
function M.scenarioC(root)
  local W = world(root)
  local P = player(W)
  local co = W.co
  P.raise(W.craft("rover") + 100)
  co.spend(W.craft("rover"), "rover")
  P.rover = true
  P.bought = P.t
  P.note("bought a rover %s", co.money(W.craft("rover")))
  W.store["mission.done"] = {}
  while P.t < 30 do P.ground_work() end
  return { bought = P.bought, marks = P.marks, log = P.log, jobs = P.jobs or 0, bal = co.balance() }
end

function M.prices(root)
  local W = world(root)
  local out = {}
  for name in pairs(M.CRAFT) do out[name] = W.craft(name) end
  out._recover, out._freight, out._hire = W.recover, W.freight, W.hire
  out._ground = ground_table(W)
  out._cost = W.cost
  return out
end

-- ── CLI ────────────────────────────────────────────────────────────────────
local function money(v)
  v = math.floor(v or 0)
  local s, out = tostring(math.abs(v)), ""
  while #s > 3 do out = "," .. s:sub(-3) .. out; s = s:sub(1, -4) end
  return (v < 0 and "-$" or "$") .. s .. out
end
M.money = money

function M.report(roots, names)
  local P, A, B, C, E = {}, {}, {}, {}, {}
  for i, r in ipairs(roots) do
    P[i], A[i], B[i], C[i] = M.prices(r), M.scenarioA(r), M.scenarioB(r, 15000), M.scenarioC(r)
    E[i] = M.scenarioB2(r, 5000)
    E[i].ground_minutes = M.scenarioB2(r, 5000, true).minutes
  end
  local function row(label, f)
    local cells = {}
    for i = 1, #roots do cells[i] = string.format("%14s", f(i)) end
    print(string.format("%-34s%s", label, table.concat(cells)))
  end
  local hdr = {}
  for i = 1, #roots do hdr[i] = string.format("%14s", names[i]) end
  print(string.format("%-34s%s", "", table.concat(hdr)))
  print("CRAFT COSTS")
  for _, n in ipairs({ "bike", "rover", "starter", "highroad", "plane", "orbiter", "moonship", "probe", "docking" }) do
    row("  " .. n, function(i) return money(P[i][n]) end)
  end
  row("  recovery refund rate", function(i) return string.format("%.0f%%", P[i]._recover * 100) end)
  row("  depot freight rate", function(i) return string.format("+%.0f%%", P[i]._freight * 100) end)
  for _, k in ipairs({ "order", "bulk", "trek" }) do
    row("  ground " .. k .. " (Unknown)", function(i)
      local g = P[i]._ground and P[i]._ground[k]
      return g and money(g.reward) or "—"
    end)
  end
  print("A  NEW PLAYER, FIRST 30 MIN")
  row("  first launch at (min)", function(i) return string.format("%.1f", A[i].first_launch or -1) end)
  for _, m in ipairs({ 5, 10, 15, 20, 25, 30 }) do
    row(string.format("  balance at %d min", m), function(i) return money(A[i].marks[m] or A[i].bal) end)
  end
  row("  ground contracts done", function(i) return tostring(A[i].jobs) end)
  print("B  THREE ORBITERS CRASHED (from $15,000)")
  row("  orbiter hull", function(i) return money(B[i].hull) end)
  row("  lost in three crashes", function(i) return money(B[i].loss) end)
  row("  balance after the third", function(i) return money(B[i].low) end)
  row("  minutes back to $15,000", function(i) return string.format("%.1f", B[i].minutes) end)
  row("  ground jobs on the way", function(i) return tostring(B[i].jobs) end)
  row("  Mission Control advances", function(i) return tostring(B[i].loans) end)
  print("B2 EARLY: THREE HIGH ROAD CRASHES (from $5,000)")
  row("  High Road hull", function(i) return money(E[i].hull) end)
  row("  lost in three crashes", function(i) return money(E[i].loss) end)
  row("  balance after the third", function(i) return money(E[i].low) end)
  row("  ...ten seconds later", function(i) return money(E[i].after_wait) end)
  row("  minutes back to $5,000, ground only", function(i) return string.format("%.1f", E[i].ground_minutes) end)
  row("  ...with the High Road flown", function(i) return string.format("%.1f", E[i].minutes) end)
  row("  Mission Control advances", function(i) return tostring(E[i].loans) end)
  row("  ground jobs on the way", function(i) return tostring(E[i].jobs) end)
  row("  bought a rover on the way", function(i) return E[i].rover and "yes" or "no" end)
  row("  advance still owed at the end", function(i) return money(E[i].owed) end)
  print("C  ROVER PLAYER, NO FLIGHTS")
  row("  rover bought at (min)", function(i) return string.format("%.1f", C[i].bought) end)
  for _, m in ipairs({ 10, 20, 30 }) do
    row(string.format("  balance at %d min", m), function(i) return money(C[i].marks[m] or C[i].bal) end)
  end
  row("  ground contracts done", function(i) return tostring(C[i].jobs) end)
  if os.getenv("ECON_LOG") then
    for i = 1, #roots do
      for _, sc in ipairs({ { "A", A[i] }, { "B", B[i] }, { "B2", E[i] }, { "C", C[i] } }) do
        print(string.format("\n-- %s %s --", names[i], sc[1]))
        for _, l in ipairs(sc[2].log) do print(l) end
      end
    end
  end
  return P, A, B, C, E
end

if arg and arg[0] and arg[0]:match("econ_sim%.lua$") and arg[1] then
  local roots, names = {}, {}
  for i = 1, #arg do roots[i] = arg[i]; names[i] = (#arg == 2) and (i == 1 and "before" or "after") or arg[i]:match("[^/]+$") end
  M.report(roots, names)
end

return M
