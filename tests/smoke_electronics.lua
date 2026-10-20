-- SMOKE: the electronics rulebook (scripts/electronics.lua) — pure logic, no
-- engine. Part modules and the actions they declare, action groups (binding,
-- the save format, docking renumbering, firing a group as one), the power flow
-- (surplus, deficit, brownout order, a battery switched off), sunlight (angle,
-- shadow, distance) and the comms network (range, strength, relays, a moon in
-- the way).
--
--   luajit solar/tests/smoke_electronics.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(chunk, env)
chunk()
local E = env

-- ── modules & actions ───────────────────────────────────────────────────────
local pod = { uid = 1, id = "pod", kind = "crewed" }
local mods = E.modsOf(pod)
local has = {}
for _, m in ipairs(mods) do has[m.type] = true end
check(has.command and has.wheel and has.battery, "a legacy crewed part reads as command + wheel + battery")

local oldDish = { uid = 2, id = "dish", comms = 1 }
local dm = E.modsOf(oldDish)
check(E.modOf(oldDish, "antenna") and E.modOf(oldDish, "antenna").relay, "a legacy comms dish is a relay antenna")
check(E.modOf(oldDish, "deploy") ~= nil, "...and it folds")

local solar = { uid = 3, id = "solar", mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } }
local acts = E.actionsOf(solar)
local ids = {}
for _, a in ipairs(acts) do ids[a.id] = a end
check(ids["deployed.on"] and ids["deployed.off"] and ids["deployed.toggle"], "a folding panel has extend / retract / toggle")
check(ids["deployed.on"].label == "Extend", "the verbs come from the module type")

local st = E.stateOf(solar)
check(st.deployed == false, "panels default stowed")
local v, ch = E.applyAction(st, ids["deployed.toggle"])
check(v == true and ch and st.deployed == true, "toggle extends")
v, ch = E.applyAction(st, ids["deployed.on"])
check(v == true and not ch, "extend on an extended panel changes nothing")
v, ch = E.applyAction(st, ids["deployed.toggle"], true)
check(v == true and not ch, "a forced toggle sets, it doesn't flip")

local legs = { uid = 4, legs = 1 }
check(E.stateOf(legs).deployed == true, "legs default DOWN (the pad needs them)")

local dec = { uid = 5, decouple = 1 }
local da = E.actionOf(dec, "decouple")
check(da and da.kind == "trigger", "a decoupler has a Decouple trigger, not tied to staging")
local eng = { uid = 6, thrust = 30 }
check(E.actionOf(eng, "running.off") and E.actionOf(eng, "running.off").label == "Shut down",
  "engines can be shut down and activated by action")

-- actuators are declared (0420) with axes
local hinge = { uid = 7, mods = { { type = "hinge" } } }
local ha = E.actionOf(hinge, "angle.inc")
check(ha and ha.kind == "axis", "a hinge declares Angle +/− actions")
local hs = E.stateOf(hinge)
E.applyAction(hs, ha, nil, 5)
check(hs.angle == 5, "an axis action moves the setpoint by rate·dt")
E.applyAction(hs, E.actionOf(hinge, "angle.center"))
check(hs.angle == 0, "centre resets it")

-- ── groups ──────────────────────────────────────────────────────────────────
local L1 = { uid = 10, legs = 1 }
local L2 = { uid = 11, legs = 1 }
local P1 = { uid = 12, mods = { { type = "solar", gen = 1 }, { type = "deploy", anim = "solar" } } }
local A1 = { uid = 13, mods = { { type = "antenna", power = 3e4, draw = 0.1 }, { type = "deploy", anim = "whip" } } }
local LT = { uid = 14, mods = { { type = "light", draw = 0.2 } } }
local recs = { [10] = L1, [11] = L2, [12] = P1, [13] = A1, [14] = LT, [5] = dec }
local g = E.defaultGroups(recs)
check(E.isBound(g, "gear", 10, "deployed.toggle") and E.isBound(g, "gear", 11, "deployed.toggle"),
  "default Gear holds the landing legs")
check(E.isBound(g, "deploy", 12, "deployed.toggle") and E.isBound(g, "deploy", 13, "deployed.toggle"),
  "default Deploy holds panels and antennas")
check(not E.isBound(g, "gear", 12, "deployed.toggle"), "...and panels are not landing gear")
check(E.isBound(g, "lights", 14, "lit.toggle"), "default Lights holds the light")
check(not g["1"], "custom group 1 starts empty")

check(E.bind(g, "1", 5, "decouple"), "bind a decoupler to group 1")
check(not E.bind(g, "1", 5, "decouple"), "binding twice is a no-op")
check(E.toggleBind(g, "1", 14, "lit.on") == true and E.isBound(g, "1", 14, "lit.on"), "toggleBind adds")
check(E.toggleBind(g, "1", 14, "lit.on") == false and not E.isBound(g, "1", 14, "lit.on"), "...and removes")
local gs = E.groupsOf(g, 10, "deployed.toggle")
check(#gs == 1 and gs[1] == "gear", "groupsOf names the groups an action is in")

-- save format round trip
local packed = E.packGroups(g)
check(type(packed) == "table" and #packed >= 4, "groups pack to a list")
local back = E.unpackGroups(packed)
check(E.isBound(back, "1", 5, "decouple") and E.isBound(back, "gear", 11, "deployed.toggle"),
  "...and unpack to the same bindings")
check(type(packed[1]) == "table" and packed[1].id and type(packed[1].binds) == "table",
  "...each group a plain table (save.set keeps 16 deep since 0.117)")

-- saves written before 0.117 hold strings: they still read
local old = E.unpackGroups({ "gear|Gear|10@deployed.toggle;11@deployed.toggle", "1|Night ops|5@decouple" })
check(E.isBound(old, "gear", 11, "deployed.toggle") and old["1"].name == "Night ops",
  "an old save's group strings still unpack")
local om = E.modsOf({ mods = "antenna:power=2250,rate=4,draw=0.12,omni=t;deploy:anim=whip" })
check(#om == 2 and om[1].type == "antenna" and om[1].power == 2250 and om[1].omni == true and om[2].anim == "whip",
  "an old save's module string still decodes")
local ost = E.stateOf({ mods = {}, st = "deployed=t,charge=37.25" })
check(ost.deployed == true and ost.charge == 37.25, "an old save's state string still decodes")
local live = { uid = 3, mods = { { type = "battery", ec = 40 } }, st = { charge = 12, deployed = true, note = "x" } }
local pr = E.packRecord(live)
check(type(pr.mods) == "table" and pr.mods ~= live.mods and pr.mods[1] ~= live.mods[1] and pr.mods[1].ec == 40,
  "packRecord copies the modules as tables, sharing nothing")
check(type(pr.st) == "table" and pr.st.charge == 12 and pr.st.deployed == true and pr.st.note == nil,
  "...and the state's switches and numbers")

-- firing as one: gear starts DOWN (both legs), one press sends both UP
local ran = {}
local n = E.fireGroup(back, "gear", recs, function(uid, act, force)
  local s = E.stateOf(recs[uid])
  E.applyAction(s, act, force)
  ran[#ran + 1] = uid
end)
check(n == 2 and E.stateOf(L1).deployed == false and E.stateOf(L2).deployed == false,
  "G raises the whole gear ring")
-- desync one leg by hand, then fire: the group sets both to its state, never half
E.stateOf(L1).deployed = true
E.fireGroup(back, "gear", recs, function(uid, act, force) E.applyAction(E.stateOf(recs[uid]), act, force) end)
check(E.stateOf(L1).deployed == E.stateOf(L2).deployed, "a group toggle never leaves a ring half down")
local fired = 0
E.fireGroup(back, "1", recs, function(uid, act) if act.kind == "trigger" then fired = fired + 1 end end)
check(fired == 1, "group 1 fires the decoupler's trigger")

-- remap (docking) / prune (staging) / merge / subset
local rm = E.remapGroups(back, { [10] = 110, [5] = 105 })
check(E.isBound(rm, "gear", 110, "deployed.toggle") and not E.isBound(rm, "gear", 11, "deployed.toggle"),
  "remap renumbers and drops unmapped parts")
local pr = E.pruneGroups(E.deepCopy(back), { [11] = true })
check(#pr.gear.binds == 1 and pr.gear.binds[1].uid == 11 and #pr["1"].binds == 0,
  "prune keeps only parts still aboard")
local host = { ["1"] = { name = "Group 1", binds = { { uid = 1, act = "x" } } } }
E.mergeGroups(host, rm)
check(E.isBound(host, "1", 1, "x") and E.isBound(host, "1", 105, "decouple"), "merge unions a docked module's groups")
check(E.groupKey("gear") == "g" and E.groupKey("abort") == "backspace" and E.groupKey("0") == "0",
  "group keys: G, Backspace, 1–0")

-- ── power ───────────────────────────────────────────────────────────────────
local cells = { { cap = 100, charge = 50 }, { cap = 100, charge = 50 } }
local r = E.powerStep({ supply = 2.0, loads = { { id = "a", rate = 1.0 } }, cells = cells }, 10)
check(near(r.charge, 110) and near(cells[1].charge, 55), "a surplus charges every battery in proportion")
check(r.served.a == 1 and not r.brownout, "...and every load is served")
r = E.powerStep({ supply = 0.0, loads = { { id = "a", rate = 1.0 } }, cells = cells }, 10)
check(near(r.charge, 100), "a deficit drains the batteries")
-- brownout: 0.5 EC/s supply, no charge; the core (pri 9) keeps power before lights (pri 2)
local flat = { { cap = 100, charge = 0 } }
r = E.powerStep({ supply = 0.5, loads = { { id = "light", rate = 0.4, pri = 2 }, { id = "core", rate = 0.3, pri = 9 } },
  cells = flat }, 1)
check(r.served.core == 1 and r.served.light < 0.6 and r.brownout, "brownout sheds the lights before the core")
-- a battery switched off neither drains nor charges
local off = { { cap = 100, charge = 80, on = false }, { cap = 50, charge = 10 } }
r = E.powerStep({ supply = 0, loads = { { id = "a", rate = 5 } }, cells = off }, 10)
check(off[1].charge == 80 and off[2].charge == 0 and r.served.a < 1, "an isolated battery keeps its charge")
check(E.endurance(100, -0.5) == 200 and E.endurance(10, 1) == math.huge, "endurance")

-- ── sunlight ────────────────────────────────────────────────────────────────
local star = { name = "Sun", x = 0, y = 0, z = 0, radius = 50, mu = 1e9, soi = -1 }
local planet = { name = "P", x = 1000, y = 0, z = 0, radius = 100, mu = 1e5, soi = 300 }
local bodies = { star, planet }
local ref = star.mu / (1000 * 1000)
-- day side (between star and planet), panel axis vertical: full exposure
local out, ex, fx, blk = E.solarOutput(1.0, 850, 0, 0, 0, 1, 0, bodies, ref)
check(near(ex, 1) and blk == nil and out > 1.0, "a panel on the day side at full exposure (closer than home = brighter)")
-- axis pointing at the sun: tracking about it gains nothing
out, ex = E.solarOutput(1.0, 850, 0, 0, 1, 0, 0, bodies, ref)
check(near(ex, 0, 1e-6) and near(out, 0, 1e-6), "a panel whose axis points at the sun makes nothing")
-- night side, behind the planet
out, ex, fx, blk = E.solarOutput(1.0, 1150, 0, 0, 0, 1, 0, bodies, ref)
check(blk == "P" and out == 0, "in the planet's shadow: no power")
-- twice as far: a quarter of the light
out = E.solarOutput(1.0, 2000, 500, 0, 0, 0, 1, bodies, ref)
check(near(out, 0.25, 0.02), "inverse square: twice as far, a quarter of the power")

-- ── comms ───────────────────────────────────────────────────────────────────
check(near(E.linkRange(100, 400), 200), "range = sqrt(P1·P2)")
check(E.linkStrength(0, 100) == 1 and E.linkStrength(100, 100) == 0 and near(E.linkStrength(50, 100), 0.5),
  "strength 1 → 0, half at mid-range")

-- antennaSummary: a stowed whip doesn't count; extended does; a powered-off craft has none
local whip = { uid = 20, mods = { { type = "antenna", power = 3e4, rate = 4, draw = 0.1 }, { type = "deploy", anim = "whip" } } }
local relayDish = { uid = 21, mods = { { type = "antenna", power = 1e6, relay = true, dish = true, rate = 12, draw = 0.6 },
  { type = "deploy", anim = "dish" } } }
local core = { uid = 22, mods = { { type = "command", draw = 0.1 }, { type = "antenna", power = 2000, rate = 1 } } }
local s0 = E.antennaSummary({ whip, core })
check(near(s0.any, 2000) and s0.relay == 0, "a stowed whip doesn't count; the core's internal one does")
E.stateOf(whip).deployed = true
local s1 = E.antennaSummary({ whip, core })
check(s1.any > 3e4 and s1.relay == 0, "extended, the whip leads (and combines with the core)")
E.stateOf(relayDish).deployed = true
local s2 = E.antennaSummary({ relayDish })
check(s2.relay > 0, "a dish is a relay")
check(E.antennaSummary({ relayDish }, nil, false).any == 0, "no power, no radio")

-- Network: home on a planet surface; sat A in low orbit; sat B far out beyond
-- A's direct reach of home but within relay range of A; a moon parks between.
local home = { id = "home", x = 0, y = 100, z = 0, home = true, power = 2500 }
local world = { name = "W", x = 0, y = 0, z = 0, radius = 100, mu = 1e6, soi = 5e4 }
local moon = { name = "Moon", x = 0, y = 3000, z = 0, radius = 200, mu = 1e4, soi = 600 }
local satA = { id = "A", x = 0, y = 600, z = 0, any = 1e4, relay = 1e4, rate = 4 }
local satB = { id = "B", x = 5600, y = 600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st1, links1 = E.solveNetwork({ home, satA, satB }, { world })
check(st1.A.connected and st1.A.hops == 1, "A talks to home directly")
check(st1.B.connected and st1.B.hops == 2 and st1.B.parent == "A", "B reaches home THROUGH A (relay)")
check(st1.B.strength < st1.A.strength, "a relayed path is weaker than a direct one")
local used = 0
for _, l in ipairs(links1) do if l.used then used = used + 1 end end
check(used == 2, "the two hops on the best paths are marked used")
-- A without relay capability: B is cut off
local satA2 = { id = "A", x = 0, y = 600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st2 = E.solveNetwork({ home, satA2, satB }, { world })
check(not st2.B.connected, "an omni-only craft does not relay")
-- the moon occludes A–B: move B behind the moon as seen from A
local satB2 = { id = "B", x = 0, y = 5600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st3 = E.solveNetwork({ home, satA, satB2 }, { world })
check(st3.B.connected, "B above A, clear sky: linked through A")
local st4 = E.solveNetwork({ home, satA, satB2 }, { world, moon })
check(not st4.B.connected, "a moon between A and B breaks the chain")
-- the planet occludes: a sat on the far side of the world can't see the station
local far = { id = "F", x = 0, y = -600, z = 0, any = 1e5, relay = 0 }
local st5 = E.solveNetwork({ home, far }, { world })
check(not st5.F.connected, "a craft behind the planet has no line of sight to home")
-- a landed craft right beside the station on the same world links fine
local nextdoor = { id = "N", x = 30, y = 99, z = 0, any = 2000 }
local st6 = E.solveNetwork({ home, nextdoor }, { world })
check(st6.N.connected, "a craft landed next to the station has a link")

-- summary: what the builder quotes
local sm = E.summary({ core, whip, { uid = 30, mods = { { type = "battery", ec = 100 } } },
  { uid = 31, mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } } })
check(sm.store == 100 and near(sm.solar, 1.0) and sm.probe == 1 and sm.crew == 0, "summary: store, solar, command")
check(sm.reachHome > sm.reachCraft and sm.reachCraft > 3e4, "summary: reach home vs reach another craft")
check(near(sm.idle, 0.2), "summary: idle draw = core + radios")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("ELECTRONICS SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("ELECTRONICS SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
