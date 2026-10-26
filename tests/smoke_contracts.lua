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
