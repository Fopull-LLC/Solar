-- SMOKE HARNESS: the programme (missions.lua PROGRAMME) — the milestone arc
-- that runs alongside the contracts. Runs the real missions.lua + company.lua
-- + materials.lua + inventory.lua + research.lua against a stubbed engine and
-- drives every state transition:
--
--   * a new save opens First Steps and nothing else; it pays once both
--     materials have been held, and opens Rare Finds and the Relay Network;
--   * a rare goal resolves to the niches the home world actually has (and is
--     waived when it has none), and ticks on the specimen's first sight;
--   * the relay goals wait (and say so) while comms does not report, react to
--     coverage stage by stage, pay each stage ONCE, latch through a dip, and
--     grant the research they promise; the Relay Dish stays locked behind the
--     milestone and opens with it;
--   * Eyes in the Sky and Beyond tick off orbit relays, sky coverage HELD over
--     a full window (never a snapshot) and linked moons / planets;
--   * everything survives a reload (fresh script, same save) without paying
--     twice, and a comms script that throws never takes the game down.
--
--   luajit solar/tests/smoke_programme.lua

local T = 0.0
local TICK = 1 / 60

local ROSTER = {
  star = "Saelo", mu = 7.0e7,
  bodies = {
    { name = "Umunquo", kind = "canyon", parent = "Saelo",   a = 5500,  radius = 185, relief = 12, mu = 7.0 * 185 * 185, atmo = 0.7, sea = 180 },
    { name = "Ryethos", kind = "frost",  parent = "Umunquo", a = 1110,  radius = 40,  relief = 3,  mu = 3.5 * 40 * 40,   atmo = 0,   sea = 0 },
    { name = "Nami",    kind = "lava",   parent = "Saelo",   a = 12100, radius = 150, relief = 10, mu = 8.0 * 150 * 150, atmo = 0.6, sea = 0 },
    { name = "Oskal",   kind = "barren", parent = "Nami",    a = 900,   radius = 35,  relief = 2,  mu = 3.0 * 35 * 35,   atmo = 0,   sea = 0 },
  },
}
local BODIES = {
  Umunquo = { name = "Umunquo", x = 5500, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 185, mu = 7.0 * 185 * 185, soi = 2200 },
  Ryethos = { name = "Ryethos", x = 6610, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 40, mu = 3.5 * 1600, soi = 240 },
  Nami = { name = "Nami", x = -12100, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 150, mu = 8.0 * 22500, soi = 1800 },
  Oskal = { name = "Oskal", x = -11200, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 35, mu = 3.0 * 1225, soi = 200 },
  Saelo = { name = "Saelo", x = 0, y = 0, z = 0, radius = 700, mu = 7.0e7, soi = -1 },
}

local API, store, logs = {}, {}, {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
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
API.space = {
  bodies = function() local out = {} for _, b in pairs(BODIES) do out[#out + 1] = b end return out end,
  body = function(n) return BODIES[n] end,
  dominant = dominant,
  elements = function() return nil end,
}
API.assembly = { info = function() return { grounded = false, vel = { x = 0, y = 0, z = 0 } } end }
local astro = { valid = true, x = 5500, y = 186, z = 0 }
local walker = { onFoot = true, valid = true }
function API.find(n) if n == "Astronaut" then return astro end end

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
  if kind == "vessel_controller" then return {} end
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
local rs = load_script("solar/scripts/research.lua", "research")
local mi = load_script("solar/scripts/missions.lua", "missions")
co.start({})
rs.start({})
mi.start({})
local MNODE = { x = 5500, y = 185, z = 0 }

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    co.update({}, TICK)
    rs.update({}, TICK)
    mi.update(MNODE, TICK)
  end
end
local function second() tick(70) end

local failed = 0
local count = 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function state_of(id)
  for _, e in ipairs(mi.programme()) do if e.m.id == id then return e.state end end
end
local function ticked(id, i)
  return (mi.progGoalLines(id)[i] or ""):sub(1, 3) == "✓"
end

-- ── 1. a new save ───────────────────────────────────────────────────────────
second()
check("research registers the rare materials", mats.REG.geode ~= nil and mats.label("rare_peak") ~= "rare_peak")
check("a new save opens First Steps", state_of("first_steps") == "active", state_of("first_steps"))
check("…and nothing else", state_of("rare_finds") == "locked" and state_of("relay_net") == "locked"
  and state_of("sky") == "locked" and state_of("beyond") == "locked")
check("the first active milestone is First Steps", (mi.progActive()[1] or {}).id == "first_steps")
check("Relay Dish is locked behind the Relay Network milestone",
  (rs.blockedBy("dish") or ""):find("Relay Network", 1, true) ~= nil, rs.blockedBy("dish"))
local f0 = co.balance()

-- The card (objectives.lua) on a new save leads with the programme.
local drawn = nil
API.ui = { make = function(_, tree) drawn = tree end }
API.input = { pressed = function() return false end }
envs.base_facilities = { sited = true, valid = true }
local ob = load_script("solar/scripts/objectives.lua", "objectives")
local card_node = { getcomponent = function() return { visible = false } end }
ob.start(card_node)
local function card_text()
  ob.update(card_node, TICK)
  local out = {}
  for _, row in ipairs((drawn or {}).items or {}) do out[#out + 1] = row.text or "" end
  return table.concat(out, " | ")
end
local ct = card_text()
check("a new save's card shows the first milestone", ct:find("Programme · First Steps", 1, true) ~= nil, ct)
check("…with its first step and both goals", ct:find("Cut a plant.", 1, true) ~= nil
  and ct:find("Mine some ore", 1, true) ~= nil, ct)
check("…and still points at paid contracts", ct:find("Ops Board", 1, true) ~= nil, ct)

-- ── 2. first steps ──────────────────────────────────────────────────────────
inv.add("astro", "fiber", 1)
second()
check("a cut plant ticks goal 1", ticked("first_steps", 1) and not ticked("first_steps", 2))
check("…without finishing the milestone", state_of("first_steps") == "active")
inv.add("astro", "regolith", 1)
second()
check("mined ore finishes First Steps", state_of("first_steps") == "done", state_of("first_steps"))
check("…and pays its reward once", co.balance() == f0 + 400, co.balance() - f0)
check("the card announces the milestone first", card_text():find("MILESTONE", 1, true) ~= nil)
T = T + 10   -- the banner's moment passes
ct = card_text()
check("with a little in the pack the card still follows the programme", ct:find("Rare Finds", 1, true) ~= nil
  and ct:find("Sell what", 1, true) == nil, ct)
check("…and says where to look", ct:find("ravine", 1, true) ~= nil, ct)
check("…and what the milestone pays", ct:find("Completes for", 1, true) ~= nil, ct)
check("…and what else is open", ct:find("Also open: Relay Network", 1, true) ~= nil, ct)
check("…and stops wanting to sell", ct:find("Sell what", 1, true) == nil, ct)
check("…and opens Rare Finds and the Relay Network", state_of("rare_finds") == "active"
  and state_of("relay_net") == "active" and state_of("sky") == "locked")
check("the card's announcement names the milestone", mi.lastPaid and mi.lastPaid.label == "MILESTONE"
  and mi.lastPaid.title == "First Steps")
second()
check("no second payment on the next tick", co.balance() == f0 + 400)

-- ── 3. rare finds ───────────────────────────────────────────────────────────
check("before the world is scanned a rare goal asks for its own niche", mi.progNiche("rare_finds", 1) == "ravine")
-- The scan says this world has peaks, lakes and riverbanks, but no ravines.
store["rare.Umunquo"] = { v = 1, seed = 1, plants = {
  { niche = "peak", x = 0, y = 190, z = 0 }, { niche = "lake", x = 0, y = 186, z = 3 },
  { niche = "river", x = 3, y = 186, z = 0 } }, ores = {} }
check("no ravines: the ravine goal falls back to its first alternative that exists",
  mi.progNiche("rare_finds", 1) == "river", mi.progNiche("rare_finds", 1))
check("the peak goal keeps its own niche", mi.progNiche("rare_finds", 2) == "peak")
check("the goal line says where", (mi.progGoalLines("rare_finds")[1] or ""):find("riverbank", 1, true) ~= nil,
  mi.progGoalLines("rare_finds")[1])
-- Programme goals count HOME finds only (flora_field `rare.cut.<home>`,
-- mineral_field `rare.ore.<home>`); a find anywhere else is a discovery.
local f1 = co.balance()
inv.add("astro", "rare_lake", 1)
store["rare.cut.Umunquo"] = { lake1 = true }
second()
check("a specimen from another niche does not count", not ticked("rare_finds", 1))
inv.add("astro", "rare_river", 1)
store["rare.cut.Ryethos"] = { river1 = true }
second()
check("a riverbank plant cut on a MOON does not tick the home goal", not ticked("rare_finds", 1))
check("…nor pay its stage", co.balance() == f1, co.balance() - f1)
store["rare.cut.Umunquo"] = { lake1 = true, river2 = true }
second()
check("the home world's riverbank plant ticks goal 1", ticked("rare_finds", 1))
check("…and pays the goal's stage", co.balance() == f1 + 500, co.balance() - f1)
inv.add("astro", "rare_peak", 1)
store["rare.cut.Umunquo"].peak1 = true
inv.add("astro", "geode", 1)
store["rare.ore.Ryethos"] = { [2] = 1 }
second()
check("a Star Geode dug on a moon does not tick the home geode goal", not ticked("rare_finds", 3)
  and state_of("rare_finds") == "active", mi.progGoalLines("rare_finds")[3])
-- STAR GEODES (playtest 2026-10-27): resonant crystal dug out of the deep
-- rock is a geode find; a surface crystal or a shallow scrape is not.
check("the rule: a pocket's geode always counts", mi.isGeodeFind("geode", 0))
check("…crystal from 3 m down or deeper counts", mi.isGeodeFind("crystal", 3.0) and mi.isGeodeFind("crystal", 22))
check("…a surface scrape of crystal doesn't", not mi.isGeodeFind("crystal", 0.5))
check("…and nothing else counts at any depth", not mi.isGeodeFind("iron", 40) and not mi.isGeodeFind("uranium", 40))
check("shallow crystal on home is no find", mi.geodeFind("Umunquo", "crystal", 1, 1.0) == false and mi.geodeFinds("Umunquo") == 0)
check("deep crystal on a MOON is a find there", mi.geodeFind("Ryethos", "crystal", 2, 21) == true)
second()
check("…but does not tick the home geode goal", not ticked("rare_finds", 3))
check("deep crystal dug on home counts as a Star Geode find", mi.geodeFind("Umunquo", "crystal", 1, 8.5) == true
  and mi.geodeFinds("Umunquo") == 1 and store["rare.geo.Umunquo"].deep == 8.5)
second()
check("peak + a home geode (deep crystal) finish Rare Finds", state_of("rare_finds") == "done", state_of("rare_finds"))
store["rare.ore.Umunquo"] = { [4] = 2 }
check("pockets and deep crystal add up", mi.geodeFinds("Umunquo") == 3)
do
  local keep = store["rare.geo.Umunquo"]; store["rare.geo.Umunquo"] = nil
  check("a pocket alone is a find (as before)", mi.geodeFinds("Umunquo") == 2)
  store["rare.geo.Umunquo"] = keep
end
second()
check("peak + a home geode finish Rare Finds", state_of("rare_finds") == "done", state_of("rare_finds"))
check("…paying both stages and the milestone", co.balance() == f1 + 500 + 500 + 700 + 1200, co.balance() - f1)
check("…and granting the Battery", rs.isUnlocked("battery"))
-- An airless home waives the plant goals rather than stranding them.
do
  local w = store["world.Umunquo"]
  w.atmo = 0
  check("an airless home waives its rare-plant goals", mi.progNiche("rare_finds", 1) == false)
  w.atmo = 0.7
end

-- ── 4. the relay network ────────────────────────────────────────────────────
check("without comms the relay goals wait", not ticked("relay_net", 1))
check("…and say why", (mi.progGoalLines("relay_net")[1] or ""):find("not reporting", 1, true) ~= nil,
  mi.progGoalLines("relay_net")[1])
local NET = { ground = 0.05, sky = 0, orbit = 0, linked = {}, calls = 0 }
local comms = { valid = true }
function comms.coverage(b)
  NET.calls = NET.calls + 1; NET.asked = b
  return { ground = NET.ground, sky = NET.sky, sustained = NET.sustained, window = NET.window, held = NET.held, full = NET.full }
end
function comms.relayStats() return { ground = { Umunquo = 3 }, orbit = { Umunquo = NET.orbit }, total = 3 + NET.orbit } end
function comms.linkedBodies() return NET.linked end
local hooked = nil
function comms.onNetworkChanged(fn) hooked = fn end
envs.comms = comms
local f2 = co.balance()
second()
check("comms is asked about the HOME world", NET.asked == "Umunquo", NET.asked)
check("…and its change hook is taken", type(hooked) == "function")
check("5% covers no stage", not ticked("relay_net", 1) and co.balance() == f2)
check("the line shows the live number", (mi.progGoalLines("relay_net")[1] or ""):find("now 5%", 1, true) ~= nil,
  mi.progGoalLines("relay_net")[1])
check("the Relay Network asks a quarter of the ground, in two stages", #mi.progById("relay_net").goals == 2
  and mi.progById("relay_net").goals[1].frac == 0.10 and mi.progById("relay_net").goals[2].frac == 0.25)
NET.ground = 0.12
second()
check("12% ticks the 10% stage", ticked("relay_net", 1) and not ticked("relay_net", 2))
check("…and pays it", co.balance() == f2 + 800, co.balance() - f2)
check("…and grants the Probe Core (a satellite needs one)", rs.isUnlocked("probe"))
second(); second()
check("…once", co.balance() == f2 + 800)
check("the Relay Dish is still locked", not rs.isUnlocked("dish"))
NET.ground = 0.06
second()
check("a dip in coverage never takes a stage back", ticked("relay_net", 1) and not ticked("relay_net", 2))
-- satellites are no help with the GROUND stages (there are none before the dish)
NET.sky = 0.4
second()
check("sky coverage doesn't stand in for the ground network", not ticked("relay_net", 2))
NET.sky = 0
-- A change event re-polls at once rather than on the next second.
NET.ground = 0.26
hooked()
tick(1)
check("the change hook re-polls on the next frame", ticked("relay_net", 2))
check("25% completes the Relay Network", state_of("relay_net") == "done")
check("…granting the Relay Dish (satellite relays)", rs.isUnlocked("dish") and rs.blockedBy("dish") == nil)
check("…and opens Eyes in the Sky", state_of("sky") == "active")
check("Deep Space Dish is locked behind Eyes in the Sky",
  (rs.blockedBy("dishL") or ""):find("Eyes in the Sky", 1, true) ~= nil, rs.blockedBy("dishL"))
check("total paid for the network: 2 stages + the milestone",
  co.balance() == f2 + 800 + 1500 + 3000, co.balance() - f2)

-- ── 5. reload: fresh script, same save ──────────────────────────────────────
do
  local before = co.balance()
  envs.missions = nil
  mi = load_script("solar/scripts/missions.lua", "missions")
  mi.start({})
  second(); second()
  check("a reload keeps every milestone's state", state_of("first_steps") == "done" and state_of("rare_finds") == "done"
    and state_of("relay_net") == "done" and state_of("sky") == "active")
  check("…and pays nothing twice", co.balance() == before, co.balance() - before)
end

-- ── 6. the sky and beyond ───────────────────────────────────────────────────
local f3 = co.balance()
NET.orbit = 1
NET.sky = 0.4
second()
check("one relay in orbit ticks the first sky goal", ticked("sky", 1) and not ticked("sky", 2))
-- SUSTAINED: the sky stages count ground HELD over a full window, not the
-- snapshot (comms coverage().sustained / full; a comms without it: the snapshot)
NET.sky, NET.sustained, NET.window, NET.held, NET.full = 0.62, 0.30, 300, 300, true
second()
check("a 62% snapshot with only 30% held does not tick the half-planet stage", not ticked("sky", 2))
local sl = mi.progGoalLines("sky")[2] or ""
check("…and the line shows what is held, and the live number", sl:find("30% held · 5:00 window", 1, true) ~= nil
  and sl:find("62% now", 1, true) ~= nil, sl)
NET.sustained, NET.held, NET.full = 0.55, 190, false
second()
check("55% held over only part of the window does not tick it yet", not ticked("sky", 2))
sl = mi.progGoalLines("sky")[2] or ""
check("…and the line shows the window filling", sl:find("55% held · 3:10 / 5:00 window", 1, true) ~= nil, sl)
check("progNet publishes the sustained numbers", mi.progNet.sustained == 0.55 and mi.progNet.window == 300
  and mi.progNet.held == 190 and mi.progNet.full == false)
NET.held, NET.full = 300, true
second()
check("satellites holding 55% over a full window tick the half-planet stage", ticked("sky", 2) and not ticked("sky", 3))
NET.sky, NET.sustained = 0.81, 0.81
second()
check("80% held (ground + satellites) completes Eyes in the Sky", state_of("sky") == "done")
NET.sustained, NET.window, NET.held, NET.full = nil, nil, nil, nil
check("…granting the Deep Space Dish", rs.isUnlocked("dishL"))
check("…and opens Beyond", state_of("beyond") == "active")
NET.linked = { "Umunquo" }
second()
check("home alone links nothing new", not ticked("beyond", 1))
NET.linked = { "Umunquo", "Oskal" }
second()
check("a moon of another planet counts as a moon", ticked("beyond", 1) and not ticked("beyond", 2))
NET.linked = { "Umunquo", "Oskal", "Nami" }
second()
check("a linked planet completes Beyond", state_of("beyond") == "done")
check("Beyond's rewards: 2 sky stages + 1 + milestone + 2 links + milestone",
  co.balance() == f3 + 3000 + 3000 + 5000 + 12000 + 8000 + 15000 + 30000, co.balance() - f3)
check("nothing left in progress", #mi.progActive() == 0)

-- ── 7. a comms script that throws ───────────────────────────────────────────
comms.coverage = function() error("boom") end
comms.linkedBodies = function() error("boom") end
local ok = pcall(second)
check("a throwing comms script never takes the tick down", ok)
check("…and reads as not reporting", mi.progNet.api == true and mi.progNet.ground == 0)

if failed > 0 then
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
print(string.format("✓ programme: %d checks", count))
