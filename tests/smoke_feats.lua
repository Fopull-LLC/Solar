-- SMOKE: FEATS (progression P1; scripts/feats.lua, research.lua's `feat` and
-- `featGrant`, scenario.lua's `feat` goal kind; the programme's kind is in
-- smoke_contracts.lua). Pure and against stubs.
--
--   * mark / has / count / when; a key counts once; markAtLeast never lowers;
--     seed (a scenario's start.feats);
--   * the first mark of a feat that opens research says so once on the radio
--     (Ops strip), never again, and a feat that opens nothing says nothing;
--   * the migration: an old save with a base, a claimed ruin, a read core and
--     a found ruin marks those (once; never twice);
--   * research: solarArray and batteryBank locked with the feat's words, open
--     the moment base_founded is in the save, read with NO feats script (the
--     builder's case); sandbox opens them; a `feat` lock says what to go and
--     do, then the price; grant() and the rest unchanged;
--   * research.study marks ore_studied on an ore kind's first study only;
--   * scenario.lua's `feat` goal: met at n, its reading, its label.
--   (progression P2)
--   * once, addAmount (fractions kept till a whole unit), accrue, labelOf at
--     a count ("1 km driven");
--   * the detectors, against stand-ins: gridTick (grid_served after a
--     minute; a night held from dusk to dawn with nothing shed, at one step
--     or many; rtg_night; slept_in; a short night; a ruin's grid; a grid
--     with no arrays through its stand-in cell), roomsSolved, airStep,
--     fluidStep, reactorTick, cacheOpened;
--   * the P2 migration: an old save with the kit keeps every piece (the
--     arc's gates written researched), the Relay Network kept open, the feats
--     its records prove; a save without the kit gets nothing;
--   * research: the arc's gates (featGrant), scnOpen in a scenario,
--     openWithout (the tower before the Camp Mast), a counted feat lock.
--
--   luajit solar/tests/smoke_feats.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end

local store = {}
local SAVE = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
local SCRIPTS = {}
local said = {}
SCRIPTS.ops_strip = { say = function(t, who) said[#said + 1] = { t = t, who = who } end }
local function fs(k) return SCRIPTS[k] end

-- ── mark / has / count ──────────────────────────────────────────────────────
local F = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
SCRIPTS.feats = F
do
  check("nothing done: has is false, count 0", not F.has("base_founded") and F.count("base_founded") == 0)
  store["agency.clock"] = 1234
  check("the first mark counts 1", F.mark("kit_placed") == 1 and F.has("kit_placed") and F.count("kit_placed") == 1)
  check("…when is the agency clock of the first", F.when("kit_placed") == 1234)
  store["agency.clock"] = 2000
  F.mark("kit_placed", { b = "Draethos" })
  check("a second mark counts 2, when stays the first", F.count("kit_placed") == 2 and F.when("kit_placed") == 1234)
  check("a key counts once", F.mark("ruin_found", { key = "A#1" }) == 1 and F.mark("ruin_found", { key = "A#1" }) == nil
    and F.mark("ruin_found", { key = "A#2" }) == 2 and F.count("ruin_found") == 2)
  F.markAtLeast("drive_m", 500)
  F.markAtLeast("drive_m", 300)
  check("markAtLeast raises a running total, never lowers it", F.count("drive_m") == 500)
  F.markAtLeast("drive_m", 1200)
  check("…and raises it again", F.count("drive_m") == 1200)
  check("has(id, n)", F.has("drive_m", 1000) and not F.has("drive_m", 2000))
  check("the save holds it all under `feats`", type(store.feats) == "table" and store.feats.kit_placed.n == 2)
  check("a bad id marks nothing", F.mark(nil) == nil and F.mark("") == nil)
  F.mark("wood_built"); F.mark("wood_built")
  check("unmark takes a piece back (undone: not standing)", F.unmark("wood_built") == 1 and F.count("wood_built") == 1)
  check("…never below nothing", F.unmark("wood_built", 5) == 0 and F.unmark("wood_built") == 0 and F.unmark("never_marked") == 0)
  check("every feat in LABEL reads as a lock line", F.LABEL.base_founded:find("base") ~= nil and F.labelOf("odd_one") == "odd one")
  local n = F.seed({ "room_sealed", { id = "cave_kinds", n = 2 }, { "lock_opened", 1 } })
  check("seed (a scenario's start.feats): ids and { id, n }", n == 3 and F.has("room_sealed") and F.count("cave_kinds") == 2 and F.has("lock_opened"))
  check("…quietly", #said == 0)
end

-- ── research: the feat grants and locks ─────────────────────────────────────
do
  store = {}
  said = {}
  local RS = loadlib("research.lua", { save = SAVE, findScript = function() return nil end, log = function() end })
  check("the Solar Array and the Battery Bank are research ids now", RS.TECH.solarArray and RS.TECH.batteryBank
    and RS.TECH.solarArray.featGrant == "base_founded" and RS.TECH.batteryBank.featGrant == "base_founded")
  check("no base: the Solar Array is locked", not RS.isUnlocked("solarArray") and not RS.isUnlocked("batteryBank"))
  local why = RS.blockedBy("solarArray")
  check("…and the lock says what to go and do", why and why:find("a base of your own", 1, true) ~= nil, why)
  check("…the card's line", (RS.lockLine("solarArray") or ""):find("^LOCKED · needs a base of your own") ~= nil, RS.lockLine("solarArray"))
  check("…it can't be bought", not RS.unlock("solarArray"))
  -- (Ty 11-12) the whole reason for the catalogue's plate: need, how, price
  local ld = RS.lockDetail("solarArray")
  check("lockDetail: the need, what to do about it, and that it isn't bought", ld and ld.need and ld.need:find("a base of your own", 1, true)
    and ld.how ~= nil and ld.price and ld.price:find("Not bought", 1, true) ~= nil, ld and (tostring(ld.need) .. " | " .. tostring(ld.how) .. " | " .. tostring(ld.price)))
  RS.TECH.testAfter = { cost = 900, label = "After Test", after = "solarArray" }
  local la = RS.lockDetail("testAfter")
  check("lockDetail of a research behind another: research that first, and why it is shut", la and la.how
    and la.how:find("Solar Array", 1, true) and la.how:find("base of your own", 1, true) and la.price:find("900", 1, true) ~= nil, la and la.how)
  RS.TECH.testAfter = nil
  store.feats = { base_founded = { n = 1, t = 5 } }
  check("base_founded in the save: both open, read without a feats script (the builder)", RS.isUnlocked("solarArray") and RS.isUnlocked("batteryBank"))
  check("…no lock line", RS.lockLine("solarArray") == nil and RS.blockedBy("batteryBank") == nil)
  store.feats = nil
  store["game.mode"] = "sandbox"
  check("a sandbox has them open from the start", RS.isUnlocked("solarArray"))
  store["game.mode"] = nil
  -- a `feat` lock (P2 will use it: a test entry here)
  RS.TECH.testQuarry = { cost = 2500, label = "Quarry", feat = "machine_worked" }
  local w2 = RS.blockedBy("testQuarry")
  check("a feat lock names the thing to do first", w2 and w2:find("needs", 1, true) == 1 and w2:find("refinery run", 1, true) == nil and w2:find("machine worked", 1, true) ~= nil, w2)
  store.feats = { machine_worked = { n = 1 } }
  check("…done, it is a price like any other", RS.blockedBy("testQuarry") == nil and not RS.isUnlocked("testQuarry")
    and (RS.lockLine("testQuarry") or ""):find("research $2500", 1, true) ~= nil, RS.lockLine("testQuarry"))
  RS.TECH.testQuarry = nil
  -- with the feats script there: its words
  local RS2 = loadlib("research.lua", { save = SAVE, findScript = fs, log = function() end })
  RS2.TECH.testQuarry = { cost = 2500, label = "Quarry", feat = "machine_worked" }
  store.feats = nil
  check("…in its own words where the feats script is", (RS2.blockedBy("testQuarry") or ""):find("a refinery run", 1, true) ~= nil, RS2.blockedBy("testQuarry"))
  -- ore_studied: on an ore kind's first study
  local mats = { class = function(m) return (m == "iron" or m == "copper") and "ore" or "flora" end, grade = function() return "ore" end, tier = function() return 1 end }
  local RS3 = loadlib("research.lua", { save = SAVE, findScript = function(k) if k == "materials" then return mats end return fs(k) end, log = function() end })
  store = {}
  RS3.study("timber", 3)
  check("studying a plant marks no ore feat", not F.has("ore_studied"))
  RS3.study("iron", 2)
  RS3.study("iron", 5)
  check("an ore kind's first study marks ore_studied, once", F.count("ore_studied") == 1)
  RS3.study("copper", 1)
  check("…a second ore kind counts again", F.count("ore_studied") == 2)
end

-- ── the radio line when a feat opens something ──────────────────────────────
do
  store = {}
  said = {}
  local RS = loadlib("research.lua", { save = SAVE, findScript = function() return nil end, log = function() end })
  SCRIPTS.research = RS
  F.mark("kit_placed")
  check("a feat that opens nothing says nothing (few popups)", #said == 0)
  F.mark("base_founded", { key = 1 })
  check("the first base: Ops says what it opened, once", #said == 1 and said[1].who == "Ops"
    and said[1].t:find("Battery Bank and Solar Array", 1, true) ~= nil, said[1] and said[1].t)
  F.mark("base_founded", { key = 2 })
  check("…a second base says nothing", #said == 1)
  check("…and the research opened", RS.isUnlocked("solarArray"))
  SCRIPTS.research = nil
end

-- ── the migration ───────────────────────────────────────────────────────────
do
  store = { ["bases.list"] = { 1, 2 }, ["ruins.s"] = { ["D#1"] = { dsc = "proximity", cl = 5, read = 7 }, ["D#2"] = {} } }
  said = {}
  local n = F.migrate()
  check("an old save: its bases, claimed ruin, read core and found ruin count", n == 4 and F.has("base_founded")
    and F.has("ruin_claimed") and F.has("core_read") and F.has("ruin_found"), n)
  check("…quietly", #said == 0)
  check("…once", F.migrate() == 0 and F.count("base_founded") == 1)
  store = { ["bases.list"] = {} }
  check("a save with nothing built migrates to nothing", F.migrate() == 0 and not F.has("base_founded"))
  -- with the bases script (its count)
  store = {}
  SCRIPTS.bases = { count = function() return 1 end }
  local F2 = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  check("…the bases script's count when it is there", F2.migrate() == 1 and F2.has("base_founded"))
  SCRIPTS.bases = nil
end

-- ── scenario.lua: the `feat` goal ───────────────────────────────────────────
do
  local SCN = loadlib("scenario.lua")
  local n = 0
  local W = { featCount = function(id) return id == "lock_opened" and n or 0 end }
  local ok, rd = SCN.evalGoal({ kind = "feat", id = "lock_opened", n = 2 }, W, {}, { now = 0 })
  check("a scenario's feat goal waits", not ok and rd == "0 of 2", rd)
  n = 2
  ok, rd = SCN.evalGoal({ kind = "feat", id = "lock_opened", n = 2 }, W, {}, { now = 0 })
  check("…met at n", ok and rd == "2 of 2", rd)
  check("…its label", SCN.goalLabel and SCN.goalLabel({ kind = "feat", id = "lock_opened" }) == "lock opened" or SCN.goalLabel == nil)
end

-- ── (P2) once, addAmount, accrue, labelOf ───────────────────────────────────
do
  store = {}
  said = {}
  check("once marks the first time", F.once("logic_fired") == 1)
  check("…and never again", F.once("logic_fired") == nil and F.count("logic_fired") == 1)
  F.addAmount("machine_worked", 0.4)
  check("addAmount keeps a fraction till it makes a unit", F.count("machine_worked") == 0)
  F.addAmount("machine_worked", 0.7)
  check("…then marks the whole units", F.count("machine_worked") == 1)
  F.addAmount("machine_worked", 198.95)
  check("…and adds them up", F.count("machine_worked") == 200, F.count("machine_worked"))
  check("a bad amount adds nothing", F.addAmount("machine_worked", -3) == nil and F.addAmount("machine_worked", 0 / 0) == nil)
  for _ = 1, 59 do F.accrue("dose_taken", 1, 60) end
  check("accrue waits for its seconds", not F.has("dose_taken"))
  F.accrue("dose_taken", 1, 60)
  check("…and marks at them", F.has("dose_taken"))
  check("labelOf at a count: 1 km driven", F.labelOf("drive_km", 1000) == "1 km driven" and F.labelOf("drive_km", 2500) == "2.5 km driven")
  check("…at one, its words", F.labelOf("drive_km") == "a kilometre driven")
end

-- ── (P2) gridTick ───────────────────────────────────────────────────────────
do
  store = {}
  said = {}
  local Fg = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  local BG = { slotOf = function(M, a) return math.floor((a - M.A0) / M.L + 1e-12) end }
  -- a year of 4 slots of 100 s: day, day, night, night
  local rec = { id = 1, b = "Home" }
  local g = { id = "s1", parts = { { rec = rec, p = { uid = 1 } } } }
  local M = { N = 4, L = 100, A0 = 0, prof = { 3, 3, 0, 0 }, sources = 1, need = 2, rtg = 0, C = 4000, body = "Home" }
  local S = { supply = 3, need = 2, powered = true, short = 0, dt = 2 }
  local function tick(a, s) S.dt = s and s.dt or 2; S.short = s and s.short or 0; S.powered = not (s and s.off); Fg.gridTick({ g }, { s1 = M }, { s1 = S }, a, BG) end
  tick(10); tick(40)
  check("a grid carrying its load: not served after 30 s", not Fg.has("grid_served"))
  tick(75)
  check("…served after a minute", Fg.has("grid_served"))
  tick(180)
  tick(250)
  check("dusk: a night under way, saved", type(store["feats.gn"]) == "table" and store["feats.gn"].s1.ph == "night")
  tick(330)
  check("…not held before dawn", not Fg.has("night_held"))
  tick(410)
  check("dawn with nothing shed: night_held", Fg.has("night_held"))
  check("…no Isotope Skid: no rtg_night; nobody indoors: no slept_in", not Fg.has("rtg_night") and not Fg.has("slept_in"))
  -- a second grid, an RTG, someone sleeping in a sealed room; the whole night in ONE step (warp)
  SCRIPTS.room_air = { crewRoom = function() return 7, 1 end, airOf = function() return { sealed = true, leaky = false } end }
  local g2 = { id = "s2", parts = { { rec = { id = 2, b = "Home" }, p = { uid = 1 } } } }
  local M2 = { N = 4, L = 100, A0 = 0, prof = { 3, 3, 0, 0 }, sources = 2, need = 2, rtg = 2, C = 0, body = "Home" }
  local S2 = { supply = 2, need = 2, powered = true, short = 0, dt = 2 }
  Fg.gridTick({ g2 }, { s2 = M2 }, { s2 = S2 }, 110, BG)
  S2.dt = 300
  Fg.gridTick({ g2 }, { s2 = M2 }, { s2 = S2 }, 410, BG)
  check("a night crossed in one step counts; an Isotope Skid held it: rtg_night", Fg.has("rtg_night"))
  check("…the crew in a sealed room dusk to dawn: slept_in", Fg.has("slept_in"))
  SCRIPTS.room_air = nil
  -- a night with a brownout counts nothing
  store = {}
  local Fs = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  local g3 = { id = "s3", parts = { { rec = { id = 3, b = "Home" }, p = { uid = 1 } } } }
  local S3 = { powered = true, short = 0, dt = 2 }
  Fs.gridTick({ g3 }, { s3 = M }, { s3 = S3 }, 150, BG)
  Fs.gridTick({ g3 }, { s3 = M }, { s3 = S3 }, 250, BG)
  S3.short, S3.powered = 40, false
  Fs.gridTick({ g3 }, { s3 = M }, { s3 = S3 }, 330, BG)
  S3.short, S3.powered = 0, true
  Fs.gridTick({ g3 }, { s3 = M }, { s3 = S3 }, 410, BG)
  check("a night with loads shed is not held", not Fs.has("night_held"))
  -- a grid first seen at night waits for the next dusk
  local g4 = { id = "s4", parts = { { rec = { id = 4, b = "Home" }, p = { uid = 1 } } } }
  local S4 = { powered = true, short = 0, dt = 2 }
  Fs.gridTick({ g4 }, { s4 = M }, { s4 = S4 }, 260, BG)
  Fs.gridTick({ g4 }, { s4 = M }, { s4 = S4 }, 410, BG)
  check("a grid first seen at night: that night is not a whole one", not Fs.has("night_held"))
  Fs.gridTick({ g4 }, { s4 = M }, { s4 = S4 }, 650, BG)
  Fs.gridTick({ g4 }, { s4 = M }, { s4 = S4 }, 810, BG)
  check("…the next whole one is", Fs.has("night_held"))
  -- an unclaimed ruin's grid counts nothing
  store = {}
  local Fr = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  SCRIPTS.ruins = { claimed = function() return false end }
  local gr = { id = "r1", parts = { { rec = { id = 9, b = "Home", ru = "Home#near" }, p = { uid = 1 } } } }
  local SR = { powered = true, short = 0, dt = 2 }
  for _, a in ipairs({ 10, 80, 150, 250, 410 }) do Fr.gridTick({ gr }, { r1 = M }, { r1 = SR }, a, BG) end
  check("an unclaimed ruin's yard lighting itself is not the player's grid", not Fr.has("grid_served") and not Fr.has("night_held"))
  SCRIPTS.ruins.claimed = function() return true end
  check("…claimed, it is the player's", Fr.owned(gr.parts[1].rec))
  SCRIPTS.ruins = nil
  -- no arrays: the stand-in cell at its first part
  store = {}
  local Fv = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  SCRIPTS.structures = { partPose = function() return 0, 600, 0, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 } end }
  local asked = 0
  local BGv = { slotOf = BG.slotOf, slotInfo = function() return { body = { name = "Home" } } end,
                slotLight = function(arr) asked = asked + 1; return { 1, 1, 0, 0 } end }
  local Mv = { N = 4, L = 100, A0 = 0, sources = 1, need = 2, rtg = 2, C = 0, body = "Home" }
  local gv = { id = "v1", parts = { { rec = { id = 5, b = "Home" }, p = { uid = 1 } } } }
  local Sv = { powered = true, short = 0, dt = 2 }
  for _, a in ipairs({ 110, 250, 410, 420 }) do Fv.gridTick({ gv }, { v1 = Mv }, { v1 = Sv }, a, BGv) end
  check("a grid of Isotope Skids alone: the night through a stand-in cell", Fv.has("rtg_night") and Fv.has("night_held"))
  check("…worked out once per model", asked == 1, asked)
  SCRIPTS.structures = nil
end

-- ── (P2) rooms, air, fluids, the reactor, a cave's cache ───────────────────
do
  store = {}
  local Fd = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  local small = { rec = { id = 1 }, R = { rooms = { { id = 1, sealed = true, leaky = false, m3 = 5 } } } }
  Fd.roomsSolved(1, small)
  check("a sealed cupboard (5 m³) is not shelter", not Fd.has("room_sealed"))
  SCRIPTS.ruins = { claimed = function() return false end }
  Fd.roomsSolved(2, { rec = { id = 2, ru = "x" }, R = { rooms = { { id = 1, sealed = true, m3 = 40 } } } })
  check("an unclaimed ruin's sealed room is not yours", not Fd.has("room_sealed"))
  SCRIPTS.ruins = nil
  Fd.roomsSolved(3, { rec = { id = 3 }, R = { rooms = { { id = 1, sealed = false, leaky = true, m3 = 40 }, { id = 2, sealed = true, leaky = false, m3 = 12 } } } })
  check("a sealed room of 12 m³: room_sealed", Fd.has("room_sealed"))
  -- air: a scrubber running in a sealed network, breathable, an hour
  local s = { rec = { id = 3 }, air = { [2] = { N = 9, x = 2.5, c = 0.01 } } }
  local nets = { { rooms = { 2 }, V = 12, S = 0.001, tau = nil } }
  local function ok_air() return { breathable = true } end
  Fd.airStep(3, s, nets, 1800, ok_air)
  check("half an hour of air: not yet", not Fd.has("room_breathable"))
  Fd.airStep(3, s, { { rooms = { 2 }, V = 12, S = 0, tau = nil } }, 600, ok_air)
  check("a brownout (the scrubber unpowered) pauses the count", not Fd.has("room_breathable"))
  Fd.airStep(3, s, nets, 600, function() return { breathable = false, why = "CO2" } end)
  Fd.airStep(3, s, nets, 1800, ok_air)
  check("…the air going bad resets it", not Fd.has("room_breathable"))
  Fd.airStep(3, s, { { rooms = { 2 }, V = 12, S = 0.001, tau = 13 } }, 1800, ok_air)
  check("…an open room counts nothing (and resets it)", not Fd.has("room_breathable"))
  Fd.airStep(3, s, nets, 1800, ok_air)
  Fd.airStep(3, s, nets, 1800, ok_air)
  check("an hour with it running: room_breathable", Fd.has("room_breathable"))
  -- fluids
  local E = { net = { els = { { kind = "pump", on = true }, { kind = "cond" } } }, st = { em = { "on" }, x = { 450, 50 } }, x0 = { 500, 0 } }
  Fd.fluidStep({ sid = 4, rec = { id = 4 } }, E)
  check("50 kg pumped: not yet", not Fd.has("fluid_moved"))
  E.st.x, E.x0 = { 380, 120 }, { 450, 50 }
  Fd.fluidStep({ sid = 4, rec = { id = 4 } }, E)
  check("120 kg pumped in all: fluid_moved", Fd.has("fluid_moved"))
  local E2 = { net = { els = { { kind = "pump", on = false } } }, st = { em = {}, x = { 0, 500 } }, x0 = { 500, 0 } }
  check("(a pump off moves nothing it counts)", (function() store = {}; local F2 = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end }); F2.fluidStep({ sid = 5, rec = {} }, E2); return not F2.has("fluid_moved") end)())
  -- the reactor
  store = {}
  local Fx = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  Fx.reactorTick({ o = { k = 0.98, P = 0 }, S = { scram = true } })
  check("a subcritical trip is no SCRAM seen", not Fx.has("reactor_critical") and not Fx.has("scram_seen"))
  Fx.reactorTick({ o = { k = 1.0, P = 0.2 }, S = {} })
  check("k at 1 with power: reactor_critical", Fx.has("reactor_critical"))
  Fx.reactorTick({ o = { k = 0.7, P = 0.05 }, S = { scram = true } })
  check("…then a trip: scram_seen", Fx.has("scram_seen"))
  -- a cave's cache
  SCRIPTS.structures = { get = function(sid) return sid == 8 and { id = 8, ru = "Home#3", b = "Home", bp = { { uid = 1, ri = 4 }, { uid = 2, ri = 1004, cv = true } } } or { id = sid, bp = { { uid = 1 } } } end }
  Fx.cacheOpened(7, 1)
  Fx.cacheOpened(8, 1)
  check("a crate in the open or on the surface of a ruin is no cave cache", not Fx.has("cave_cache"))
  Fx.cacheOpened(8, 2)
  check("a crate in the cave under a ruin: cave_cache", Fx.has("cave_cache"))
  SCRIPTS.structures = nil
end

-- ── (P2) the migration's second half ───────────────────────────────────────
do
  store = { ["feats.mig"] = 1, ["prog.done"] = { first_steps = true }, ["prog.perm"] = { relay_net = { true } },
            ["res.done"] = { probe = true }, ["res.studied"] = { iron = { n = 3 }, timber = { n = 1 } },
            ["mission.odo"] = { id = "trek", by = { ["c:Rover"] = 820.5, ["c:Bike"] = 400 } } }
  said = {}
  SCRIPTS.bases = { count = function() return 1 end }
  SCRIPTS.materials = { class = function(m) return m == "iron" and "ore" or "flora" end }
  SCRIPTS.parts_base = { partInfo = function(id)
    if id == "solarArray" then return { power = { kind = "solar" } } end
    if id == "batteryBank" then return { power = { kind = "store" } } end
    if id == "mcCrusher.steel" then return { piece = "mcCrusher" } end
    return {} end }
  SCRIPTS.structures = { list = function() return {
    { id = 1, b = "Home", bp = { { id = "solarArray" }, { id = "batteryBank" }, { id = "mcCrusher.steel" } } },
    { id = 2, b = "Home", ru = "Home#1", bp = { { id = "isotopeSkid" } } } } end }
  SCRIPTS.ruins = { claimed = function() return false end }
  local Fm = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  local n = Fm.migrate()
  local rd = store["res.done"]
  check("an old save with the kit: the arc's gates written researched", rd.tower and rd.power2 and rd.life and rd.fluids
    and rd.logic and rd.quarry and rd.shoring and rd.probe)
  check("…the Relay Network kept open", store["prog.open"] and store["prog.open"].relay_net == true)
  check("…its grid, its night storage, its refinery, its ore and its metres count", Fm.has("grid_served") and Fm.has("night_held")
    and Fm.count("machine_worked") >= 200 and Fm.has("ore_studied") and Fm.count("drive_km") == 1220, n)
  check("…an unclaimed ruin's Isotope Skid is not its own", not Fm.has("rtg_night"))
  check("…quietly, once", #said == 0 and Fm.migrate() == 0 and store["feats.mig"] == 2)
  -- a save that never had the kit (First Steps alone): nothing granted
  store = { ["feats.mig"] = 1, ["prog.done"] = { first_steps = true } }
  SCRIPTS.structures = { list = function() return {} end }
  SCRIPTS.bases = { count = function() return 0 end }
  local Fn = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  Fn.migrate()
  check("a save before the kit: no gate granted", not (store["res.done"] and store["res.done"].life))
  -- a fresh career: nothing at all
  store = {}
  local Ff = loadlib("feats.lua", { save = SAVE, findScript = fs, log = function() end })
  check("a fresh career migrates to nothing", Ff.migrate() == 0 and store["res.done"] == nil and store["prog.open"] == nil)
  SCRIPTS.bases, SCRIPTS.materials, SCRIPTS.parts_base, SCRIPTS.structures, SCRIPTS.ruins = nil, nil, nil, nil, nil
end

-- ── (P2) research: the arc's gates ──────────────────────────────────────────
do
  store = {}
  local RS = loadlib("research.lua", { save = SAVE, findScript = fs, log = function() end })
  for _, t in ipairs({ "tower", "power2", "life", "fluids", "logic", "shoring" }) do
    check("the arc's gate " .. t .. " is a grant, locked on a fresh career", RS.TECH[t] and RS.TECH[t].grantOnly and not RS.isUnlocked(t))
  end
  check("…saying what to do", (RS.blockedBy("life") or ""):find("a sealed room", 1, true) ~= nil, RS.blockedBy("life"))
  store.feats = { room_sealed = { n = 1 } }
  check("…open the moment the feat is in the save", RS.isUnlocked("life") and not RS.isUnlocked("fluids"))
  store.feats = nil
  store["game.mode"] = "scenario"
  check("a scenario's world never locks the arc's gates (scnOpen)", RS.isUnlocked("life") and RS.isUnlocked("quarry") and RS.isUnlocked("tower"))
  check("…but the P1 grants stay the scenario's to give", not RS.isUnlocked("solarArray"))
  store["game.mode"] = nil
  check("the cable drums are heavy power by ALIAS", RS.labelOf("powerCable95"):find("Heavy Power", 1, true) ~= nil and not RS.isUnlocked("hvCable"))
  -- the tower before the Camp Mast
  SCRIPTS.parts_kit = { PIECES = { wall = {} } }
  check("the tower is open while the kit has no Camp Mast", RS.isUnlocked("tower"))
  SCRIPTS.parts_kit.PIECES.campMast = {}
  check("…and waits for a served grid once it has one", not RS.isUnlocked("tower"))
  SCRIPTS.parts_kit = nil
  check("a counted feat lock: the Cargo Bay wants 1 km driven", (RS.blockedBy("cargo") or ""):find("needs 1 km driven", 1, true) == 1, RS.blockedBy("cargo"))
  store.feats = { drive_km = { n = 999 } }
  check("…999 m is not a kilometre", (RS.blockedBy("cargo") or ""):find("km driven", 1, true) ~= nil)
  store.feats = { drive_km = { n = 1000 } }
  check("…1000 m is", not (RS.blockedBy("cargo") or ""):find("km driven", 1, true))
  store.feats = nil
  check("the Build Kit comes with First Steps", not RS.isUnlocked("buildkit"))
  store["prog.done"] = { first_steps = true }
  check("…done, it is open", RS.isUnlocked("buildkit"))
  store["prog.done"] = nil
  store["prog.perm"] = { relay_net = { true } }
  check("…and a save that had it from the Relay Network keeps it", RS.isUnlocked("buildkit"))
end

if failed == 0 then
  print(string.format("FEATS SMOKE OK — %d checks passed", count))
  os.exit(0)
end
print(string.format("FEATS SMOKE: %d of %d checks failed", failed, count))
os.exit(1)
