-- SMOKE: crew death (docs/crew-and-items.md §2.2, §2.3; crew slice 2):
-- scripts/crew.lua's death rules and what a death does, against stubs.
--
--   * the impact thresholds: under 6 m/s nothing, 6–13 injures by
--     (Δv − 6)/7, 13 and over kills; the monitor reads Δv off the avatar each
--     tick and ignores a teleport (a switch, a pickup);
--   * crush: only after 0.4 s of continuous overlap;
--   * heat: builds only while exposed to a heating craft, cools at 0.1/s;
--   * the air warnings: 25 % low, 10 % critical, the last minute; the
--     blackout grace (15 s suit, 10 s water);
--   * a death: the record is dead with its cause, the memorial lists it, the
--     pack drops as a crate (salvage.drop from crew:<id>), the remains are
--     placed (deployables "remains"), the agency loses 2 reputation, the
--     caption names them, and after the 2 s hold control passes on — in the
--     design's order (a member on foot, the craft, base, the free newbie);
--   * a part that breaks kills only its own occupants;
--   * everyone dead: the free newbie is hired at once, for $0;
--   * with `crew.death` off every cause rescues instead;
--   * a new save and a migrated save both have three starters.
--
--   luajit solar/tests/smoke_crew_death.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local function make(store)
  local astro = { name = "Astronaut", valid = true, visible = true, id = 99, x = 0, y = 101, z = 0, vx = 0, vy = 0, vz = 0 }
  local log = { drops = {}, places = {}, rep = 0, caps = {}, spent = 0 }
  local scripts = {
    salvage = { valid = true, drop = function(b, x, y, z, ign, o) log.drops[#log.drops + 1] = o; return 40 + #log.drops end },
    deployables = { valid = true, place = function(kind, b, x, y, z, o) log.places[#log.places + 1] = { kind = kind, by = o.by }; return 70 + #log.places end,
                    dateOf = function() return "Day 3" end },
    company = { valid = true, addRep = function(d) log.rep = log.rep + d end, afford = function() return true end,
                spend = function(n) log.spent = log.spent + n; return true end },
    big_caption = { valid = true, show = function(t, s) log.caps[#log.caps + 1] = t .. ": " .. s end },
    flight_ops = { valid = true, crewHome = function() return 5, 102, 5 end },
    planet_walker = { valid = true, breath = 1.0, airLeft = 1200, airCap = 1200, suitO2 = 1.0 },
  }
  local overlap = {}
  local E = setmetatable({
    time = 10.0, vec3 = vec3,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function(n) if n == "Astronaut" then return astro end end,
    space = { dominant = function() return "Vever" end, body = function() return { name = "Vever", x = 0, y = 0, z = 0 } end,
              time = function() return 500 end },
    overlapSphere = function() return overlap end,
    log = function() end,
  }, { __index = _G })
  local f = assert(loadfile("solar/scripts/crew.lua"))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  return E, astro, log, scripts, function(o) overlap = o end
end
local function tick(C, n, dt)
  for _ = 1, (n or 1) do C.time = C.time + (dt or 1 / 60); C.fixedUpdate(nil, dt or 1 / 60) end
end

-- ── the rules ──────────────────────────────────────────────────────────────
local C = make({ g_seed = 3 })
check(C.impactRule(5.9) == "ok", "5.9 m/s: nothing")
local v, loss = C.impactRule(9.5)
check(v == "injure" and math.abs(loss - 0.5) < 1e-9, "9.5 m/s injures by half (" .. tostring(loss) .. ")")
check(C.impactRule(13.0) == "kill", "13 m/s kills")
local t, dead = C.crushStep(0, true, 0.2)
check(not dead, "0.2 s pinned: alive")
t, dead = C.crushStep(t, true, 0.21)
check(dead, "0.41 s pinned: crushed")
t, dead = C.crushStep(0.39, false, 0.1)
check(t == 0 and not dead, "the weight moves: the count resets")
local h = C.heatStep(0, 0.1, true, 1.0)
check(math.abs(h - 0.2) < 1e-9, "exposed to heating 0.1: +0.2 a second")
check(C.heatStep(0.5, 0.3, false, 1.0) == 0.4, "in a closed pod: cools 0.1 a second")
check(select(2, C.heatStep(0.95, 0.1, true, 0.5)) == true, "heat 1.0: dead")
check(C.airLevel(0.3, 900) == nil and C.airLevel(0.2, 300) == "low" and C.airLevel(0.08, 100) == "crit"
  and C.airLevel(0.04, 50) == "min", "the O2 chips: 25 %, 10 %, the last minute")
check(C.blackoutGrace("suit") == 15 and C.blackoutGrace("hold") == 10, "the blackout grace: 15 s suit, 10 s water")
check(select(1, C.handoffPick({ { id = 4, dist = 30 }, { id = 5, dist = 10 } }, "V", {}, { 2 })) == "crew"
  and select(2, C.handoffPick({ { id = 4, dist = 30 }, { id = 5, dist = 10 } }, "V", {}, { 2 })) == 5,
  "handoff 1: the nearest member on foot")
check(select(2, C.handoffPick({}, "V", { { v = "W", dist = 1 } }, { 2 })) == "V", "handoff 2: the craft they were in")
check(select(2, C.handoffPick({}, nil, { { v = "W", dist = 9 }, { v = "X", dist = 2 } }, { 2 })) == "X", "...else the nearest crewed craft")
check(select(2, C.handoffPick({}, nil, {}, { 2, 3 })) == 2, "handoff 3: a member at base")
check(select(1, C.handoffPick({}, nil, {}, {})) == "newbie", "handoff 4: the free newbie")

-- ── a new save has three starters ──────────────────────────────────────────
local store = { g_seed = 3 }
local C1, astro, L = make(store)
C1.start()
C1.time = C1.time + 4  -- (the monitors wait 3 s after a scene starts)
check(#C1.roster() == 3 and C1.living() == 3 and C1.activeId() == 1, "a new save: three starters, #1 in control")
check(C1.hireFee() == 1000, "the 4th astronaut costs $1,000")

-- ── a fatal fall ───────────────────────────────────────────────────────────
astro.vy = 0
tick(C1, 2)
astro.vy = -4
tick(C1, 1)
check(C1.get(1).status ~= "dead" and (C1.get(1).hp or 1) == 1, "a 4 m/s landing: nothing")
astro.vy = -9.5
tick(C1, 1)
astro.vy = 0
tick(C1, 1)
check(C1.get(1).status ~= "dead" and math.abs(C1.get(1).hp - 0.5) < 0.01, "a 9.5 m/s landing: hurt to hp 0.5 (" .. tostring(C1.get(1).hp) .. ")")
-- a teleport (a switch) is not an impact
astro.x, astro.vy = 500, -30
tick(C1, 2)
astro.x, astro.vy = 0, 0
tick(C1, 1)
check(C1.get(1).status ~= "dead", "...but a tick that jumps position doesn't count: a teleport, a switch, a pickup")
tick(C1, 3)
astro.vy = -17
tick(C1, 1)
astro.vy = 0
tick(C1, 1)
local r1 = C1.get(1)
check(r1.status == "dead" and r1.died and r1.died.cause == "impact" and r1.died.detail == "17 m/s", "a 17 m/s landing kills: impact, 17 m/s")
check(#L.drops == 1 and L.drops[1].from == "crew:1" and L.drops[1].items == true, "the whole pack drops as a crate")
check(#L.places == 1 and L.places[1].kind == "remains" and L.places[1].by == 1, "the remains are placed")
check(r1.died.crate == 41 and r1.died.remains == 71, "the record knows its crate and remains")
check(L.rep == -2, "the agency loses 2 reputation")
check(C1.lastDeath and C1.lastDeath.text:match("was killed: impact, 17 m/s"), "the caption: " .. tostring(C1.lastDeath and C1.lastDeath.text))
check(astro.visible == false, "the camera holds on the fallen (the avatar hidden there)")
local mem = C1.memorial()
check(#mem == 1 and mem[1].id == 1 and mem[1].died.cause == "impact", "the memorial lists them")
check(C1.activeId() == 1, "during the 2 s hold control hasn't passed yet")
tick(C1, 150, 1 / 60)
check(C1.activeId() == 2 and C1.get(2).status == "afoot", "after the hold: #2 walks out of the base (" .. tostring(C1.activeId()) .. ")")
check(astro.x == 5 and astro.visible == true, "...at the crew's home")
check(C1.alerts(2).hp == 1.0, "alerts() answers for the new avatar")

-- ── crushed (0.4 s) ────────────────────────────────────────────────────────
local s2 = { g_seed = 4 }
local C2, a2, L2, sc2, set_overlap = make(s2)
C2.start()
C2.time = C2.time + 4  -- (the monitors wait 3 s after a scene starts)
tick(C2, 3)
set_overlap({ { node = { valid = true, id = 7, name = "LooseBoulder" } } })
tick(C2, 18)  -- 0.3 s
check(C2.get(1).status ~= "dead" and C2.alerts(1).pinned == true, "pinned 0.3 s: alive, the PINNED chip on")
tick(C2, 8)
check(C2.get(1).status == "dead" and C2.get(1).died.cause == "crushed", "pinned past 0.4 s: crushed")
set_overlap({})

-- ── a broken part kills its own occupants only, and the newbie ─────────────
local s3 = { g_seed = 5 }
local C3, a3, L3 = make(s3)
C3.start()
C3.time = C3.time + 4  -- (the monitors wait 3 s after a scene starts)
C3.patch(2, { status = "aboard", craft = "Kestrel" })
C3.patch(3, { status = "aboard", craft = "Kestrel" })
C3.cabinLost(nil, 4, { 2 }, 0, 100, 0)
check(C3.get(2).status == "dead" and C3.get(2).died.cause == "cabin", "the cabin's occupant died")
check(C3.get(3).status == "aboard", "the member in the other part lives")
check(C3.activeId() == 1, "a doll dying passes no control")
C3.kill(3, "heat")
check(C3.get(3).died.cause == "heat", "burned on re-entry")
local offers = C3.offers()
check(offers[1].cost > 0, "one alive: the applicants cost money")
C3.kill(1, "oxygen")
offers = C3.offers()
check(C3.living() == 0 and offers[1].cost == 0 and offers[1].free == true, "everyone dead: the first applicant is FREE")
tick(C3, 150)
check(C3.living() == 1 and C3.activeId() == 4, "the last one gone: the free newbie is hired and walks out (" .. tostring(C3.activeId()) .. ")")
check(C3.get(4).cost == 0 and L3.spent == 0, "...for $0")
check(#C3.memorial() == 3, "three on the memorial")

-- ── death off: rescue instead ──────────────────────────────────────────────
local s4 = { g_seed = 6 }
local C4, a4, L4 = make(s4)
C4.start()
C4.time = C4.time + 4  -- (the monitors wait 3 s after a scene starts)
C4.setDeath(false)
check(C4.deathOn() == false, "the Rescue switch")
tick(C4, 3)
a4.vy = -30
tick(C4, 1)
a4.vy = 0
tick(C4, 1)
check(C4.get(1).status == "afoot" and C4.living() == 3, "a fatal fall with death off: rescued, alive")
check(a4.x == 5 and L4.spent > 0, "...at the base, for the fee")
C4.patch(2, { status = "aboard" })
C4.cabinLost(nil, 4, { 2 }, 0, 0, 0)
check(C4.get(2).status == "base", "a destroyed cabin with death off: they wake at base")
check(C4.blackoutEnd("suit") == false, "out of air with death off: planet_walker's own rescue")
C4.setDeath(true)
check(C4.blackoutEnd("hold") == true and C4.get(1).died.cause == "drowned", "out of air with death on: drowned")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_death: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_death: all %d checks passed", passed))
