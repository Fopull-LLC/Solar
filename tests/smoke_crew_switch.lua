-- SMOKE: switching to any crew member (docs/tracking-station.md §2),
-- scripts/crew.lua against stubs.
--
--   * canSwitch: dead, downed, retraining, yourself; on foot near (instant),
--     on foot far and on another world (GO TO); at base near (stand up at the
--     crew home) and far (GO TO); seated in a live craft (FLY), in a craft not
--     in the scene (GO TO), in a lost one (a rescue, not a switch);
--   * switchToMember queues the right switch; spawnAtBase stands them up at
--     the crew home, body-relative; goTo leaves the one you are where they
--     stand, then asks game_manager.travelTo for a body and an OFFSET (never
--     a world point), and the arrival makes them active where their record is;
--   * recordStep: an airless world drains the suit at its rate, breathable air
--     not at all; tanks first; one 10,000 s step equals 10,000 one-second
--     steps; the blackout grace, then death; rest heals;
--   * recordTick: the left-behind record carries o2, helmet, leftAt, and the
--     O2 25 % / 10 % / LAST AIR alerts; switchTargets labels each row.
--
--   luajit solar/tests/smoke_crew_switch.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return a and b and math.abs(a - b) <= (eps or 1e-6) end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local store = { g_seed = 7, ["agency.clock"] = 1000 }
local HOME = { name = "Home", x = 1000, y = 0, z = 0, radius = 100 }
local MOON = { name = "Moon", x = 90000, y = 0, z = 0, radius = 40 }
local astro = { name = "Astronaut", valid = true, visible = true, id = 99, x = 1000, y = 101, z = 0, vx = 0, vy = 0, vz = 0,
                children = function() return {} end }
local travels, caps = {}, {}
local SEATS = {}
local V = { valid = true, craftName = "Kestrel", node = { id = 5, valid = true, x = 1000, y = 120, z = 0 },
            seatsOf = function() return SEATS end, isLost = function() return false end }
local VESSELS = {}
local RECS = {}
local scripts = {
  flight_ops = { valid = true, fleetRecords = function() return RECS end, liveOf = function(fid) return fid == "c9" and V or nil end,
                 requestRestore = function() return true end },
  tracking_station = { valid = true, crewHome = function() return 1000, 101.6, 10 end },
  base_facilities = { valid = true, sited = true, baseBody = "Home", baseX = 1000, baseY = 100, baseZ = 10,
                      footprint = { body = "Home", x = 0, y = 100, z = 10 } },
  game_manager = { valid = true, travelTo = function(b, x, y, z, label, done, opts)
    travels[#travels + 1] = { body = b, x = x, y = y, z = z, label = label, done = done, opts = opts } return true end },
  sfx = { valid = true, caption = function(t) caps[#caps + 1] = t end },
  suit = { valid = true, breathableAt = function(x) return x < 50000 end },
}
local E = setmetatable({
  time = 10.0, vec3 = vec3,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end },
  findScript = function(k) return scripts[k] end,
  findScripts = function(k) if k == "vessel_controller" then return VESSELS end return {} end,
  find = function(n) if n == "Astronaut" then return astro end end,
  spawn = function(prefab, pos, cb) cb({ valid = true, x = pos.x, y = pos.y, z = pos.z, name = prefab }) return true end,
  destroy = function(n) n.valid = false end,
  space = { dominant = function(x) return x > 50000 and "Moon" or "Home" end,
            body = function(n) return n == "Moon" and MOON or (n == "Home" and HOME or nil) end, time = function() return 500 end },
  log = function() end,
}, { __index = _G })
local f = assert(loadfile("solar/scripts/crew.lua"))
setfenv(f, E)
f()
E.params = {}
for k, v in pairs(E.defaults) do E.params[k] = v end
local C = E
C.ensure()
local R = C.roster()
check(#R == 3, "three starters (" .. #R .. ")")
local A, B, D = R[1].id, R[2].id, R[3].id
store["crew.active"] = A
C.patch(A, { status = "afoot", body = "Home", x = 0, y = 101, z = 0 })

-- ── the matrix ──────────────────────────────────────────────────────────────
check(select(2, C.canSwitch(A)) == "that's you", "yourself: no")
C.patch(B, { status = "base" })
local ok, why, mode = C.canSwitch(B)
check(ok and mode == "base", "at base, the base in range: stand up there (" .. tostring(mode) .. ")")
astro.x = 1000 + 9000                                          -- walk 9 km off
ok, why, mode = C.canSwitch(B)
check(ok and mode == "travel", "at base, the base far: GO TO")
astro.x = 1000
C.setDown(D, 1000, 101, 300)                                   -- 300 m off, a body spawned
ok, why, mode = C.canSwitch(D)
check(ok and mode == "near", "on foot in range: instant")
C.patch(D, { downed = { left = 60, secs = 60 } })
ok, why = C.canSwitch(D)
check(not ok and why:find("Medkit"), "down: bring a Medkit")
C.patch(D, { downed = false, retrain = { to = "pilot", done = 1000 + 3600 * 5 } })
ok, why = C.canSwitch(D)
check(not ok and why:find("retraining"), "retraining: greyed with the hours (" .. tostring(why) .. ")")
C.patch(D, { retrain = false })
-- on another world, a record only
local bodies = C._debug().bodies
if bodies[D] then bodies[D].valid = false; bodies[D] = nil end
C.patch(D, { status = "afoot", body = "Moon", x = 0, y = 41, z = 0 })
ok, why, mode, det = C.canSwitch(D)
check(ok and mode == "travel" and det == "Moon", "on another world: GO TO · Moon")
-- seated in a live craft
SEATS = { { uid = 1, slot = 1, taken = B, command = true } }
VESSELS = { V }
E.time = E.time + 1                                            -- (the craft list is kept a quarter second)
C.patch(B, { status = "aboard", craft = "Kestrel" })
ok, why, mode, det = C.canSwitch(B)
check(ok and mode == "craft" and det == "Kestrel", "seated in a live craft: FLY · Kestrel")
V.isLost = function() return true end
ok, why = C.canSwitch(B)
check(not ok and why:find("lost with"), "seated in a lost craft: a rescue, not a switch")
V.isLost = function() return false end
-- seated in a craft not in the scene
VESSELS = {}
E.time = E.time + 1
RECS = { c9 = { name = "Far Lander", body = "Moon", x = 0, y = 42, z = 0, parts = { { uid = 1, id = "pod", kind = "crewed", st = { crew1 = B } } } } }
ok, why, mode, det = C.canSwitch(B)
check(ok and mode == "travel" and det == "Moon", "seated in a craft off the scene: GO TO · Moon")
C.patch(R[3].id, {})
store["crew.m." .. D].status = "dead"
ok, why = C.canSwitch(D)
check(not ok and why:find("lost"), "dead: no")
store["crew.m." .. D].status = "afoot"

-- ── switchToMember: base near ───────────────────────────────────────────────
C.patch(B, { status = "base", craft = false })
VESSELS = {}
ok = C.switchToMember(B)
local q = C._debug().queue
check(ok and q[#q].kind == "base" and q[#q].body == "Home" and near(q[#q].y, 101.6), "a base member: a base switch, body-relative")
C.fixedUpdate(nil, 1 / 60)
check(C.activeId() == B and C.get(B).status == "afoot" and near(astro.y, 101.6) and near(astro.z, 10),
  "...they stand up at the crew home and you are them")
local left = C.get(A)
check(left.status == "afoot" and left.body == "Home" and left.leftAt ~= nil and left.o2 ~= nil and left.helmet ~= nil,
  "the one left behind keeps o2, helmet, leftAt and a place on Home")

-- ── goTo: a member on the Moon ──────────────────────────────────────────────
ok, why = C.switchToMember(D)
check(ok and why == "travel", "far: a GO TO")
C.fixedUpdate(nil, 1 / 60)
local T = travels[#travels]
check(T and T.body == "Moon" and T.x == 0 and T.y == 41, "travelTo gets a body and an offset (no world point)")
check(T.label:find(C.get(D).name, 1, true), "the curtain names who you go to")
check(C.get(B).status == "afoot" and C.get(B).leftAt, "the one you were is left standing, with their clock")
astro.x, astro.y, astro.z = 90000, 120, 0
T.done(true)
C.fixedUpdate(nil, 1 / 60)
check(C.activeId() == D and near(astro.y, 41) and near(astro.x, 90000), "arrived: you are them, where their record is")

-- ── recordStep ──────────────────────────────────────────────────────────────
local airless = { breathable = false, helmet = true, tanks = 0 }
local s1 = C.recordStep({ o2 = 1.0, hp = 1 }, 600, airless)
check(near(s1.o2, 1.0 - 600 / C.SUIT_AIR_SECS), "airless: the suit drains at its rate")
check(near(C.recordStep({ o2 = 0.5, hp = 1 }, 600, { breathable = true, helmet = true }).o2, 0.5), "breathable air: no drain")
local s2 = C.recordStep({ o2 = 1.0 }, 300, { breathable = false, tanks = 200 })
check(s2.tank == 200 and near(s2.o2, 1.0 - 100 / C.SUIT_AIR_SECS), "tanks first, then the suit")
local one = { o2 = 1.0, hp = 1 }
for _ = 1, 10000 do
  local st = C.recordStep(one, 1, airless)
  one.o2, one.blackout = st.o2, st.blackout
  if st.dead then one.dead = st.dead break end
end
local big = C.recordStep({ o2 = 1.0, hp = 1 }, 10000, airless)
check(big.dead == "air" and one.dead == "air", "10,000 s airless: dead either way (one step or ten thousand)")
local mid1 = { o2 = 1.0 }
for _ = 1, 1000 do local st = C.recordStep(mid1, 1, airless); mid1.o2 = st.o2 end
check(near(mid1.o2, C.recordStep({ o2 = 1.0 }, 1000, airless).o2, 1e-6), "1,000 s: one step = a thousand (within 1e-6)")
local bo = C.recordStep({ o2 = 1.0 }, C.SUIT_AIR_SECS + 5, airless)
check(bo.o2 == 0 and near(bo.blackout, C.params.grace_suit - 5) and not bo.dead, "the suit empty: a blackout with the grace left")
local bo2 = C.recordStep({ o2 = 0, blackout = 3 }, 4, airless)
check(bo2.dead == "air", "...and death when it runs out")
check(near(C.recordStep({ hp = 0.5 }, 600, { rest = true }).hp, 0.5 + C.params.heal_per_min * 10), "rest heals")

-- ── recordTick ──────────────────────────────────────────────────────────────
-- B stands on Home (breathable) out of range; give A a record on the Moon (airless)
for id, b in pairs(C._debug().bodies) do b.valid = false; C._debug().bodies[id] = nil end
C.patch(A, { status = "afoot", body = "Moon", x = 30, y = 41, z = 0, o2 = 0.3, leftAt = 1000 })
store["agency.clock"] = 1000 + C.SUIT_AIR_SECS * 0.1
C.recordTick(true)
local ra = C.get(A)
check(near(ra.o2, 0.2, 1e-6) and ra.leftAt == store["agency.clock"], "out of range on the Moon: the record breathes by the agency clock")
check(C.recordAlerts[A] and C.recordAlerts[A].level == "warn" and C.recordAlerts[A].text == "O2 20 %", "...and raises O2 20 % (amber)")
store["agency.clock"] = store["agency.clock"] + C.SUIT_AIR_SECS * 0.15
C.recordTick(true)
check(C.recordAlerts[A] and C.recordAlerts[A].level == "danger", "under 10 %: red")
local o2b = C.get(B).o2
store["agency.clock"] = store["agency.clock"] + 5000
C.recordTick(true)
check(near(C.get(B).o2, o2b), "in breathable air the left-behind does not drain")
check(C.get(A).status == "dead", "left too long on an airless world: the suit runs out (death on)")

-- ── the picker's rows ───────────────────────────────────────────────────────
local rows = C.switchTargets()
local by = {}
for _, r in ipairs(rows) do by[r.id] = r end
check(by[D] and by[D].you and by[D].label == "YOU", "you: YOU")
check(by[B] and by[B].ok and by[B].label:find("^GO TO") or (by[B] and by[B].label:find("^SWITCH")), "the one left on Home: GO TO / SWITCH")
check(by[A] == nil, "the dead are not offered")

if #failures == 0 then
  print(string.format("CREW SWITCH SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("CREW SWITCH SMOKE FAILURES:")
for _, x in ipairs(failures) do print("  ✗ " .. x) end
os.exit(1)
