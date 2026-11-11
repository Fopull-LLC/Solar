-- SMOKE HARNESS: the generated contracts. Runs the real missions.lua +
-- company.lua + materials.lua + inventory.lua against a stubbed engine holding
-- a whole generated SYSTEM — home, its moon, two more planets, a moon of one of
-- them — and drives the generator end to end:
--
--   * nothing generated before the ladder and standing open a tier;
--   * every generated contract names a body that is ON the roster;
--   * rewards and reputation rise with the trip (Δv, distance, gravity);
--   * survey / orbit / land / beacon / haul / recovery / supply run each pay
--     when their goals are really met — and not before;
--   * the board is deterministic (a reload shows the same offers);
--   * the Charter is always visible and pays when every world has been stood on.
--
--   luajit solar/tests/smoke_contracts.lua          (add -v for the reward table)

local VERBOSE = arg and arg[1] == "-v"
local T = 0.0
local TICK = 1 / 60

-- ── the system: shaped like a real roll (system_generator's ranges) ─────────
local STAR_MU = 7.0e7
local ROSTER = {
  star = "Saelo", mu = STAR_MU,
  bodies = {
    { name = "Umunquo", kind = "canyon", parent = "Saelo",   a = 5500,  radius = 185, relief = 12, mu = 7.0 * 185 * 185, atmo = 0.7, sea = 180 },
    { name = "Ryethos", kind = "frost",  parent = "Umunquo", a = 1110,  radius = 40,  relief = 3,  mu = 3.5 * 40 * 40,   atmo = 0,   sea = 0 },
    { name = "Nami",    kind = "lava",   parent = "Saelo",   a = 12100, radius = 150, relief = 10, mu = 8.0 * 150 * 150, atmo = 0.6, sea = 0 },
    { name = "Oskal",   kind = "barren", parent = "Nami",    a = 900,   radius = 35,  relief = 2,  mu = 3.0 * 35 * 35,   atmo = 0,   sea = 0 },
    { name = "Velm",    kind = "ice",    parent = "Saelo",   a = 26600, radius = 210, relief = 11, mu = 5.0 * 210 * 210, atmo = 0.5, sea = 0 },
  },
}

-- Where each body sits (world frame), and its SOI — consistent with the roster.
local BODIES = {}
local function add_body(name, x, soi)
  for _, b in ipairs(ROSTER.bodies) do
    if b.name == name then
      BODIES[name] = { name = name, x = x, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
                       radius = b.radius, mu = b.mu, soi = soi }
    end
  end
end
add_body("Umunquo", 5500, 2200)
add_body("Ryethos", 5500 + 1110, 240)
add_body("Nami", -12100, 1800)
add_body("Oskal", -12100 + 900, 200)
add_body("Velm", 0, 3000)
BODIES.Velm.z = 26600
BODIES.Saelo = { name = "Saelo", x = 0, y = 0, z = 0, radius = 700, mu = STAR_MU, soi = -1 }

local API, store, logs = {}, {}, {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
}
function API.log(m) logs[#logs + 1] = tostring(m) end
local function dominant(x, y, z)
  local best, bs = nil, math.huge
  for _, b in pairs(BODIES) do
    local s = b.soi < 0 and math.huge or b.soi
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
    if d <= s and s < bs then best, bs = b.name, s end
  end
  return best
end
local ORBIT = nil   -- what space.elements reports for the craft, set by the tests
API.space = {
  bodies = function() local out = {} for _, b in pairs(BODIES) do out[#out + 1] = b end return out end,
  body = function(n) return BODIES[n] end,
  dominant = dominant,
  elements = function() return ORBIT end,
}
local ASM = { grounded = false, vel = { x = 0, y = 0, z = 0 } }
API.assembly = { info = function() return ASM end }

local craft = { node = { valid = true, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0 },
                piloting = false, hasFlown = true, holdId = "hold:Test" }
local astro = { valid = true, x = 0, y = 0, z = 0 }
local walker = { onFoot = true, valid = true }
function API.find(n) if n == "Astronaut" then return astro end end

-- Put a node on (or above) a body's surface.
local function put(n, body, alt)
  local b = BODIES[body]
  n.x, n.y, n.z = b.x, b.y + b.radius + (alt or 0), b.z
end

local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end
function API.findScript(kind)
  if kind == "planet_walker" then return walker end
  return envs[kind]
end
function API.findScripts(kind)
  if kind == "vessel_controller" then return { craft } end
  return envs[kind] and { envs[kind] } or {}
end

store["system.home"] = ROSTER
store["base.body"] = "Umunquo"
for _, b in ipairs(ROSTER.bodies) do
  store["world." .. b.name] = { name = b.name, kind = b.kind, radius = b.radius,
                                relief = b.relief, atmo = b.atmo, sea = b.sea }
end

local co = load_script("solar/scripts/company.lua", "company")
local mats = load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
local mi = load_script("solar/scripts/missions.lua", "missions")
co.start({})
mi.start({})
local MNODE = { x = 0, y = 0, z = 0 }
put(MNODE, "Umunquo", 0)
put(astro, "Umunquo", 1)

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    co.update({}, TICK)
    mi.update(MNODE, TICK)
  end
end
local function second() tick(70) end

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end
local function gen_offers()
  local out = {}
  for _, m in ipairs(mi.offers()) do if m.gen then out[#out + 1] = m end end
  return out
end

-- ── 1. nothing generated until a tier opens ─────────────────────────────────
second()
check("no generated work at the start of a save", #gen_offers() == 0, #gen_offers())
local up = mi.upcoming()
local saw_tier, saw_charter = nil, nil
for _, u in ipairs(up) do
  if u.m.tier then saw_tier = u end
  if u.m.charter then saw_charter = u end
end
check("the next contract tier is listed as coming up", saw_tier ~= nil
  and saw_tier.needs:find("Contractor") and saw_tier.needs:find("High Road"),
  saw_tier and saw_tier.needs)
check("the Charter is always on the board as the long-term goal", saw_charter ~= nil
  and saw_charter.m.title:find("1/5") and saw_charter.needs:find("Ryethos"),
  saw_charter and (saw_charter.m.title .. " / " .. saw_charter.needs))
check("...and it says what it pays", saw_charter and saw_charter.m.reward >= 100000)
check("standing on the home world already counts toward it", mi.charter().done == 1)

-- Standing alone isn't enough, nor the rung alone.
co.addRep(3, "test")
second()
check("standing without the High Road opens nothing", #gen_offers() == 0)
store["mission.done"] = { firstflight = true, highroad = true }
second()
local g1 = gen_offers()
check("Contractor + the High Road opens local-space work", #g1 == 2, #g1)
local names = {}
for _, b in ipairs(ROSTER.bodies) do names[b.name] = true end
for _, m in ipairs(g1) do
  check("generated contract names a real body: " .. m.title, names[m.body] == true
    and m.title:find(m.body, 1, true) ~= nil, m.body)
  check("local-space work is round the home moon: " .. m.title, m.body == "Ryethos", m.body)
end

-- Deterministic: a reload (fresh script, same save) shows the same board.
do
  local ids = {}
  for _, m in ipairs(g1) do ids[#ids + 1] = m.id end
  envs.missions = nil
  mi = load_script("solar/scripts/missions.lua", "missions")
  mi.start({})
  second()
  local again = {}
  for _, m in ipairs(gen_offers()) do again[#again + 1] = m.id end
  check("the board survives a reload unchanged", table.concat(ids, ",") == table.concat(again, ","),
    table.concat(ids, ",") .. " vs " .. table.concat(again, ","))
end

-- ── 2. pricing: every kind on every body, against the trip ──────────────────
local all = {}
for _, b in ipairs(ROSTER.bodies) do
  for _, k in ipairs({ "survey", "orbit", "land", "flag", "haul", "rescue", "cargo" }) do
    local s = mi.genSpec(k, b.name, 0)
    if s then all[k .. ":" .. b.name] = s end
  end
end
local function R(k, b) local s = all[k .. ":" .. b] return s and s.reward or 0 end
if VERBOSE then
  print(string.format("%-8s %-8s %8s %5s %4s  %s", "kind", "body", "reward", "dv", "rep", "title"))
  for _, b in ipairs(ROSTER.bodies) do
    for _, k in ipairs({ "survey", "orbit", "land", "flag", "haul", "rescue", "cargo" }) do
      local s = all[k .. ":" .. b.name]
      if s then
        print(string.format("%-8s %-8s %8d %5d %4d  %s", k, b.name, s.reward, s.dv, s.rep, s.title))
      end
    end
  end
end
check("a moon flyby pays less than landing on it", R("survey", "Ryethos") < R("land", "Ryethos"))
check("...which pays less than bringing a probe back from it", R("land", "Ryethos") < R("rescue", "Ryethos"))
check("the next planet pays more than your own moon", R("survey", "Nami") > R("survey", "Ryethos"))
check("the far planet pays more than the near one", R("survey", "Velm") > R("survey", "Nami"))
check("a moon of another planet pays more than the planet", R("land", "Oskal") > R("land", "Nami"))
check("a home-moon flyby pays about what Made Orbit does", R("survey", "Ryethos") >= 3000
  and R("survey", "Ryethos") <= 12000, R("survey", "Ryethos"))
check("haul asks for something home doesn't have", all["haul:Ryethos"] ~= nil
  and all["haul:Ryethos"].goals[2].mat == "ice", all["haul:Ryethos"] and all["haul:Ryethos"].goals[2].mat)
check("...and a world with nothing new isn't a haul", all["haul:Oskal"] == nil)
check("reputation rises with the trip", (all["survey:Ryethos"].rep <= all["rescue:Velm"].rep)
  and all["rescue:Velm"].rep >= 4, all["survey:Ryethos"].rep .. " / " .. all["rescue:Velm"].rep)

-- ── 3. each kind pays only when its goals are really met ────────────────────
local function take(kind, body)
  local s = mi.genSpec(kind, body, 99)
  -- put it on the board as the generator would, then sign it
  local b = store["mission.board"] or {}
  b[#b + 1] = s
  store["mission.board"] = b
  check("signing " .. s.title, mi.accept(s.id) == true)
  return s
end
local function paid(s) return mi.active == nil and mi.lastPaid and mi.lastPaid.id == s.id end

-- survey: being in the SOI is what counts
local s = take("survey", "Ryethos")
craft.piloting, walker.onFoot = true, false
put(craft.node, "Umunquo", 500)
tick(3)
check("a survey is not met from home's sky", mi.active == s.id)
put(craft.node, "Ryethos", 100)
local bal = co.balance()
tick(3)
check("flying into the moon's SOI pays the survey", paid(s) and co.balance() == bal + s.reward,
  tostring(mi.active))

-- orbit around a named body: an orbit of HOME at the same height doesn't count
s = take("orbit", "Ryethos")
ORBIT = { body = "Umunquo", e = 0.1, periapsis = 185 + 200 }
tick(3)
check("an orbit of the wrong body doesn't count", mi.active == s.id)
ORBIT = { body = "Ryethos", e = 1.3, periapsis = 40 + 60 }
tick(3)
check("an escape past the moon doesn't count", mi.active == s.id)
ORBIT = { body = "Ryethos", e = 0.2, periapsis = 40 + 60 }
tick(3)
check("a real orbit of the moon pays", paid(s), mi.goalLines()[1])
ORBIT = nil

-- land on a named body: the bug was comparing against HOME
s = take("land", "Ryethos")
put(craft.node, "Umunquo", 0)
ASM.grounded = true
tick(3)
check("landing at home doesn't count for the moon", mi.active == s.id)
put(craft.node, "Ryethos", 0)
tick(3)
check("landing on the moon pays", paid(s), mi.goalLines()[1])

-- flag: a flag of the agency's planted on the body (deployables.lua)
local dep = load_script("solar/scripts/deployables.lua", "deployables")
dep.start({})
s = take("flag", "Ryethos")
check("a flag contract asks for a planted flag", s.goals[1].v == 2 and s.goals[1].label:find("Plant a flag", 1, true),
  s.goals[1].label)
craft.piloting = false
walker.onFoot = true
put(astro, "Umunquo", 1)
second()
check("standing at home plants nothing on the moon", mi.active == s.id)
put(astro, "Ryethos", 1)
tick(3)
check("standing on the moon isn't planting a flag", mi.active == s.id)
local R = BODIES.Ryethos
local fid = dep.place("flag", "Ryethos", R.x, R.y + R.radius, R.z, { by = 1 })
check("a flag is planted on the moon", fid ~= nil and dep.hasFlagOn("Ryethos"))
tick(3)
check("planting the flag pays", paid(s))
second()
check("...and the Charter counts it", mi.charter().done == 2, mi.charter().done)

-- a contract signed before flags (its goal has no v = 2) still completes by
-- stepping out, the old way
local old = mi.genSpec("flag", "Oskal", 98)
old.goals = { { kind = "flag", body = "Oskal", label = "Set foot on Oskal (plants the beacon)" } }
old.title = "Plant a beacon: Oskal"
store["mission.board"] = { old }
check("signing an old beacon contract", mi.accept(old.id) == true)
put(astro, "Oskal", 1)
tick(3)
check("an old beacon contract still pays on stepping out", paid(old))
put(astro, "Ryethos", 1)
-- and an old one still on the board (unsigned) is rewritten as a flag contract
local old2 = mi.genSpec("flag", "Nami", 97)
old2.goals = { { kind = "flag", body = "Nami", label = "Set foot on Nami (plants the beacon)" } }
store["mission.board"] = { old2 }
mi.start({})
check("an unsigned beacon contract becomes 'Plant a flag'",
  store["mission.board"][1] and store["mission.board"][1].goals[1].v == 2, store["mission.board"][1] and store["mission.board"][1].title)
store["mission.board"] = {}
for _, m in ipairs(gen_offers()) do
  check("no second beacon is offered for the moon", not (m.kind == "flag" and m.body == "Ryethos"))
end

-- haul: the material, by kilogram, AFTER setting foot there
s = take("haul", "Ryethos")
put(astro, "Umunquo", 1)
inv.add("base", "ice", 40)
second()
check("ice in the warehouse before visiting the moon doesn't count", mi.active == s.id,
  mi.goalLines()[2])
check("...and the depot keeps it back for the contract", mi.reserves("ice"))
put(astro, "Ryethos", 1)
second()
check("with the ice already home, setting foot there pays", paid(s), tostring(mi.active))

-- rescue: land THEN recover; a recovery first doesn't count
s = take("rescue", "Ryethos")
store["mission.recovered"] = true            -- an unrelated recovery
craft.piloting, walker.onFoot = true, false
put(craft.node, "Umunquo", 0)
tick(3)
check("a recovery before the landing doesn't count", mi.active == s.id, mi.goalLines()[2])
store["mission.recovered"] = false
put(craft.node, "Ryethos", 0)
tick(3)
check("landing on the moon latches the first goal", mi.goalLines()[1]:sub(1, 3) == "✓")
put(craft.node, "Umunquo", 0)
tick(3)
store["mission.recovered"] = true            -- vessel_controller.recoverCraft
craft.piloting = false
tick(3)
check("recovering it at the base pays", paid(s), tostring(mi.active))

-- ── 4. interplanetary needs Trusted AND Made Orbit ──────────────────────────
co.addRep(20, "test")       -- plenty of standing
store["mission.done"] = { firstflight = true, highroad = true }
second()
local inter = false
for _, m in ipairs(gen_offers()) do if m.body == "Nami" or m.body == "Velm" then inter = true end end
check("standing without Made Orbit keeps you local", not inter)
store["mission.done"] = { firstflight = true, highroad = true, orbit = true }
for _ = 1, 3 do second() end
local bodies = {}
for _, m in ipairs(gen_offers()) do bodies[m.body] = true end
check("with Made Orbit, Prime standing fills a bigger board", #gen_offers() >= 4, #gen_offers())

-- supply run: orbit with the hold full
s = take("cargo", "Nami")
craft.piloting = true
inv.setCap("hold:Test", 250)
ORBIT = { body = "Nami", e = 0.1, periapsis = 150 + 300 }
tick(3)
check("an empty hold in orbit isn't a supply run", mi.active == s.id)
inv.add("hold:Test", "iron", 80)            -- 208 kg
tick(3)
check("a full hold in orbit is", paid(s), tostring(mi.active))
ORBIT = nil

-- abandoning costs standing and drops the contract
local r0 = co.rep()
s = take("survey", "Velm")
mi.abandon()
check("abandoning a generated contract costs standing", co.rep() == r0 - 1)
check("...and it's off the books", mi.active == nil and mi.byId(s.id) == nil)

-- ── 5. the Charter pays once every world has been stood on ──────────────────
craft.piloting, walker.onFoot = false, true
local before = co.balance()
for _, b in ipairs(ROSTER.bodies) do
  put(astro, b.name, 1)
  second()
end
check("the Charter is complete", mi.charter().done == 5 and mi.charter().paid, mi.charterLine())
check("...and pays", co.balance() >= before + 250000, co.balance() - before)
local twice = co.balance()
second()
check("...once", co.balance() == twice)

-- ── 6. a home world with no moon still has local work ──────────────────────
do
  local moonless = { star = ROSTER.star, mu = ROSTER.mu, bodies = {} }
  for _, b in ipairs(ROSTER.bodies) do
    if b.name ~= "Ryethos" then moonless.bodies[#moonless.bodies + 1] = b end
  end
  store["system.home"] = moonless
  store["mission.board"], store["mission.gdone"], store["mission.done"] = nil, nil,
    { firstflight = true, highroad = true }
  co.addRep(-co.rep() + 3, "test")
  second()
  local got = gen_offers()
  local nami = #got > 0
  for _, m in ipairs(got) do
    if m.body ~= "Nami" or (m.kind ~= "survey" and m.kind ~= "orbit") then nami = false end
  end
  check("no moon: the nearest planet stands in for local work", nami,
    (got[1] and got[1].title or "none") .. " / " .. (got[2] and got[2].title or "-"))
end

-- ── (progression P1) the programme's `feat` goal kind ───────────────────────
do
  local ms = { id = "test_feats", title = "Test Feats", reward = 100, rep = 0,
               goals = { { kind = "feat", id = "base_founded", label = "a base of your own" },
                         { kind = "feat", id = "ruin_stripped", n = 3, label = "strip three pieces" } } }
  table.insert(mi.PROGRAMME, ms)
  store["feats"] = nil
  mi.progTick()
  local perm = (store["prog.perm"] or {})["test_feats"] or {}
  check("a feat goal waits until the feat is done", not perm[1] and not perm[2])
  store["feats"] = { base_founded = { n = 1 }, ruin_stripped = { n = 2 } }
  mi.progTick()
  perm = (store["prog.perm"] or {})["test_feats"] or {}
  local lines = mi.progGoalLines("test_feats")
  check("…met once it is (read from the save's feats)", perm[1] == true and not perm[2])
  check("…a counted feat shows how far along it is", lines[2] and lines[2]:find("(2 of 3)", 1, true) ~= nil, lines[2])
  store["feats"].ruin_stripped.n = 3
  mi.progTick()
  check("…and the milestone completes on the last one", (store["prog.done"] or {}).test_feats == true)
  table.remove(mi.PROGRAMME)
end

-- ── (progression P2) THE ARC, walked feat by feat ───────────────────────────
-- A fresh career's programme from First Steps to Wheels and Wings: each
-- milestone opens when what it requires is done, each goal ticks on its feat
-- (or research, or contract), and each grant opens what PLAN §2.3 says, read
-- by research.lua straight from the save. Then old saves: nothing re-locked.
do
  local keep = {}
  for k, v in pairs(store) do keep[k] = v end
  local function clear(keepers)
    for k in pairs(store) do if not keepers[k] then store[k] = nil end end
  end
  local base_keys = { ["system.home"] = true, ["base.body"] = true }
  for _, b in ipairs(ROSTER.bodies) do base_keys["world." .. b.name] = true end
  clear(base_keys)
  local radio = {}
  envs.ops_strip = { valid = true, say = function(t, who) radio[#radio + 1] = { t = t, who = who } end }
  local caps = 0
  API.caption = function() caps = caps + 1 end
  local rs = load_script("solar/scripts/research.lua", "research")
  local F = load_script("solar/scripts/feats.lua", "feats")
  local function st(id) for _, e in ipairs(mi.programme()) do if e.m.id == id then return e.state, e.needs end end end
  local function done(id) return st(id) == "done" end
  local function step() mi.progTick() end
  local bal0 = co.balance()

  -- the order of the arc
  local order = {}
  for _, m in ipairs(mi.PROGRAMME) do order[#order + 1] = m.id end
  check("the arc's nine come first, in order", table.concat(order, ",", 1, 9)
    == "first_steps,homestead,lights_on,shelter,salvage,ironworks,underground,fission,wheels", table.concat(order, ","))
  check("…then Rare Finds, the comms ladder and Reach, as they were", table.concat(order, ",", 10)
    == "rare_finds,relay_net,sky,beyond,reach", table.concat(order, ",", 10))
  check("Fission requires Ironworks AND Underground", type(mi.progById("fission").requires) == "table"
    and #mi.progById("fission").requires == 2)
  local s, needs = st("fission")
  check("…and says both while it waits", s == "locked" and needs == "Ironworks and Underground", needs)

  -- 1. First Steps → the Build Kit
  step()
  check("a fresh career: First Steps open, no Build Kit, Homestead locked", st("first_steps") == "active"
    and not rs.isUnlocked("buildkit") and st("homestead") == "locked")
  store["inv.seen"] = { timber = true, iron = true }
  step()
  check("First Steps done grants the Build Kit", done("first_steps") and rs.isUnlocked("buildkit"))
  check("…and opens Homestead (and Rare Finds), not the Relay Network", st("homestead") == "active"
    and st("rare_finds") == "active" and st("relay_net") == "locked")

  -- 2. Homestead → the Solar Array and the Battery Bank
  check("no Solar Array before a base", not rs.isUnlocked("solarArray"))
  F.mark("wood_built", { n = 8 }); F.mark("ruin_found", { key = "near" })
  step()
  check("timber and the ruin found tick two goals", not done("homestead"))
  F.mark("base_founded", { key = 1 })
  check("a base opens the Solar Array and the Battery Bank at once (featGrant)", rs.isUnlocked("solarArray") and rs.isUnlocked("batteryBank"))
  check("…said on the radio, once, never as a caption", #radio == 1 and radio[1].who == "Ops" and caps == 0, radio[1] and radio[1].t)
  step()
  check("Homestead done: Lights On, Shelter and Salvage open", done("homestead") and st("lights_on") == "active"
    and st("shelter") == "active" and st("salvage") == "active" and st("relay_net") == "locked")
  check("…paid its goals and its reward", co.balance() - bal0 >= 400 + 300 + 300 + 600 + 800, co.balance() - bal0)

  -- 3. Lights On → the tower, heavy power; the Relay Network
  check("the tower and heavy power wait", not rs.isUnlocked("tower") and not rs.isUnlocked("powerCable35")
    and (rs.blockedBy("powerCable95") or ""):find("through a night", 1, true) ~= nil, rs.blockedBy("powerCable95"))
  F.mark("grid_served")
  check("a grid served opens the Base Station Tower", rs.isUnlocked("tower"))
  F.mark("cable_laid"); F.mark("night_held")
  check("a night held opens heavy power (the 35/95 mm² and HV drums by ALIAS)", rs.isUnlocked("power2")
    and rs.isUnlocked("powerCable35") and rs.isUnlocked("hvCable"))
  step()
  check("Lights On done: Ironworks, Wheels and the Relay Network open", done("lights_on") and st("ironworks") == "active"
    and st("wheels") == "active" and st("relay_net") == "active")

  -- 4. Shelter → life support, fluids
  F.mark("room_sealed")
  check("a sealed room opens life support", rs.isUnlocked("life") and not rs.isUnlocked("fluids"))
  F.mark("room_breathable")
  check("air you made opens the fluids", rs.isUnlocked("fluids") and not rs.isUnlocked("logic"))
  F.mark("fluid_moved")
  check("a pump that moved something opens the logic", rs.isUnlocked("logic"))
  F.mark("slept_in")
  step()
  check("Shelter done: Underground opens; Fission still waits on Ironworks", done("shelter") and st("underground") == "active"
    and st("fission") == "locked")

  -- 5. Salvage → the Probe Core from a core read
  F.mark("ruin_stripped", { n = 3 }); F.mark("lock_opened"); F.mark("core_read")
  step()
  check("a core read grants the Probe Core", rs.isUnlocked("probe") and not done("salvage"))
  F.mark("ruin_claimed")
  step()
  check("…a claimed ruin finishes Salvage", done("salvage"))

  -- 6. Ironworks
  check("the refinery wants an ore studied first", (rs.blockedBy("refinery") or ""):find("ore studied", 1, true) ~= nil, rs.blockedBy("refinery"))
  check("the Quarry wants a refinery run", (rs.blockedBy("quarry") or ""):find("refinery run", 1, true) ~= nil, rs.blockedBy("quarry"))
  F.mark("ore_studied", { key = "iron" })
  rs.grant("refinery", "test")
  F.addAmount("machine_worked", 120.6)
  step()
  local ln = mi.progGoalLines("ironworks")[3] or ""
  check("refining shows its kilograms", ln:find("(120 of 200 kg)", 1, true) ~= nil, ln)
  F.addAmount("machine_worked", 80.0)
  check("the Quarry: past the feat, a price", rs.blockedBy("quarry") == nil or not (rs.blockedBy("quarry") or ""):find("refinery run", 1, true), rs.blockedBy("quarry"))
  F.mark("part_fabricated")
  step()
  check("Ironworks done", done("ironworks"))

  -- 7. Underground → shoring
  F.mark("cave_kinds", { key = "lava" }); F.mark("cave_kinds", { key = "karst" })
  check("two cave kinds open the shoring", rs.isUnlocked("shoring"))
  F.mark("cave_cache")
  step()
  check("…not done without pitchblende", not done("underground"))
  store["inv.seen"].uranium = true
  step()
  check("a uranium sample stands in for the dose (any)", done("underground") and st("fission") == "active")

  -- 8. Fission
  check("the Ember wants an Isotope Skid's night first", (rs.blockedBy("ember") or ""):find("Isotope Skid", 1, true) ~= nil, rs.blockedBy("ember"))
  F.mark("rtg_night"); rs.grant("ember", "test"); F.mark("reactor_critical"); F.mark("scram_seen")
  step()
  check("Fission done", done("fission"))

  -- 9. Wheels and Wings → the Battery Pack
  check("the Cargo Bay wants a kilometre on wheels", (rs.blockedBy("cargo") or ""):find("1 km driven", 1, true) ~= nil, rs.blockedBy("cargo"))
  F.addAmount("drive_km", 1500)
  step()
  local wl = mi.progGoalLines("wheels")[1] or ""
  check("driving shows its kilometres", wl:find("(1.5 of 2 km)", 1, true) ~= nil, wl)
  check("…the Battery Pack still locked", not rs.isUnlocked("packB"))
  F.addAmount("drive_km", 600)
  step()
  check("2 km driven grants the Battery Pack", rs.isUnlocked("packB"))
  rs.grant("cargo", "test"); F.mark("bulk_hauled"); store["mission.done"] = { firstflight = true }; F.mark("run_cycle", { key = "r1" })
  step()
  check("Wheels and Wings done", done("wheels"))
  check("no milestone ever spoke as a big caption", caps == 0, caps)

  -- the wood goal while the kit has no timber (W1 not in this build)
  clear(base_keys)
  envs.parts_kit = { valid = true, MATS = { steel = {} }, PIECES = { wall = {} } }
  store["prog.done"] = { first_steps = true }
  local b1 = co.balance()
  step()
  local hl = mi.progGoalLines("homestead")[1] or ""
  check("no timber in the kit: the wood goal is waived, and says so", hl:find("waived", 1, true) ~= nil and hl:sub(1, 3) == "✓", hl)
  check("…paying nothing for it", co.balance() == b1, co.balance() - b1)
  check("…and the tower is open while there is no Camp Mast to found a base with", rs.isUnlocked("tower"))
  envs.parts_kit.MATS.wood = {}; envs.parts_kit.PIECES.campMast = {}
  check("with the Camp Mast in the kit, the tower waits for a served grid", not rs.isUnlocked("tower"))
  envs.parts_kit = nil

  -- OLD SAVES: nothing re-locked (feats.migrate's P2 half)
  -- (a) far along: the Relay Network done (the kit, the probe, the pack came from it)
  clear(base_keys)
  store["prog.done"] = { first_steps = true, rare_finds = true, relay_net = true }
  store["prog.perm"] = { relay_net = { true, true } }
  store["res.done"] = { probe = true, packB = true, buildkit = true, dish = true }
  store["feats.mig"] = 1
  F.migrate()
  local all = true
  for _, t in ipairs({ "buildkit", "packB", "probe", "dish", "tower", "power2", "life", "fluids", "logic", "quarry", "shoring" }) do
    if not rs.isUnlocked(t) then all = false; print("  (old save: " .. t .. " locked)") end
  end
  check("an old save past the Relay Network keeps every piece it could build", all)
  step()
  check("…its milestones stand; the arc opens beside them", done("relay_net") and st("sky") == "active" and st("homestead") == "active")
  -- (b) mid-way: the 10 % stage passed, the kit in hand
  clear(base_keys)
  store["prog.done"] = { first_steps = true }
  store["prog.perm"] = { relay_net = { true } }
  store["feats.mig"] = 1
  F.migrate()
  step()
  check("an old save on the Relay Network keeps it open (prog.open) and its kit's pieces", st("relay_net") == "active"
    and rs.isUnlocked("buildkit") and rs.isUnlocked("life") and rs.isUnlocked("tower"))
  -- (c) First Steps done, no kit yet: nothing was buildable, so nothing is granted
  clear(base_keys)
  store["prog.done"] = { first_steps = true }
  store["feats.mig"] = 1
  F.migrate()
  step()
  check("an old save before the kit: the kit now (First Steps), the arc's gates still to earn", rs.isUnlocked("buildkit")
    and not rs.isUnlocked("life") and st("relay_net") == "active" and st("homestead") == "active")

  -- restore
  envs.ops_strip, envs.research, envs.feats, API.caption = nil, nil, nil, nil
  clear({})
  for k, v in pairs(keep) do store[k] = v end
end

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("CONTRACTS SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("CONTRACTS SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
print("\n-- script logs --")
for i = math.max(1, #logs - 40), #logs do print("  " .. logs[i]) end
os.exit(1)
