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

if failed == 0 then
  print(string.format("FEATS SMOKE OK — %d checks passed", count))
  os.exit(0)
end
print(string.format("FEATS SMOKE: %d of %d checks failed", failed, count))
os.exit(1)
