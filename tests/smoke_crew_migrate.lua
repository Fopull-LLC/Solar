-- SMOKE: the crew record and its one-time migration (scripts/crew.lua,
-- docs/crew-and-items.md §2.4), against a stub save.
--
--   * an OLD save (g_played, a suit pack, gear, a fleet craft with crew = true)
--     yields member #1 aboard that craft's station part (st.crew = {1}), with
--     the pack and gear moved to crew:1 once inventory's alias exists, and
--     the tool in hand on the record;
--   * an old save on foot puts member #1 at game_manager's saved position;
--   * running it twice is a no-op;
--   * a NEW save gets member #1 directly, on foot and active;
--   * before the alias exists the pack stays put (nothing reads an empty
--     pack), and moves the first time the alias is there;
--   * names are deterministic per seed; the hire fee rule; EVA checks
--     (no pack in space warns, never refuses; moving and firing refuse).
--
--   luajit solar/tests/smoke_crew_migrate.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function make(store, inv_alias)
  local inv = inv_alias and { resolve = function(c) return c end, valid = true,
    itemCount = function(cid, id) local g = store["inv.gear." .. cid] or {}; return g[id] or 0 end } or nil
  local scripts = { inventory = inv }
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return scripts["*" .. k] or {} end,
    find = function() return nil end,
  }, { __index = _G })
  local f = assert(loadfile("solar/scripts/crew.lua"))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  return E, scripts
end

-- ── an old save, crew aboard a fleet craft ─────────────────────────────────
local store = {
  g_played = 12, g_seed = 4242,
  ["inv.astro"] = { iron = 6, copper = 2 },
  ["inv.gear.astro"] = { gravgun = 1, laser = 1, beacon = 2 },
  ["tool.id"] = "laser",
  p_body = "Vever", p_x = 1, p_y = 2, p_z = 3,
  ["fleet.craft"] = {
    c1 = { name = "Kestrel I", crew = true, station = 6,
           parts = { { uid = 1, id = "tankM", kind = "tank" }, { uid = 6, id = "pod", kind = "crewed", st = { hp = 0.8 } } } },
    c2 = { name = "Probe 2", crew = false, parts = { { uid = 1, id = "probe", kind = "probe" } } },
  },
}
local C = make(store, true)
C.start()
check(store["crew.version"] == 1, "the migration stamps crew.version")
local r = C.get(1)
check(r ~= nil and r.id == 1, "member #1 exists")
check(r.status == "aboard" and r.craft == "Kestrel I", "aboard the craft that had crew = true (" .. tostring(r.status) .. ")")
local pod = store["fleet.craft"].c1.parts[2]
check(pod.st.crew and pod.st.crew[1] == 1 and pod.st.hp == 0.8, "st.crew = {1} on the station part, its other state kept")
check(store["fleet.craft"].c2.parts[1].st == nil, "the uncrewed probe is untouched")
check(store["inv.crew:1"].iron == 6 and store["inv.crew:1"].copper == 2, "the materials moved to crew:1")
check(store["inv.gear.crew:1"].beacon == 2 and store["inv.gear.crew:1"].laser == 1, "the gear moved to crew:1")
check(store["inv.astro"] == nil and store["inv.gear.astro"] == nil, "the old keys are gone")
check(r.hand == "laser", "the tool in hand is the record's hand")
check(C.activeId() == 1 and C.packOf(1) == "crew:1", "active member #1, pack crew:1")
check(C.deathOn() == true, "death defaults on")
check(type(r.name) == "string" and #r.name > 3, "a generated name (" .. tostring(r.name) .. ")")

-- twice is a no-op
local before = store["crew.m.1"]
local C2 = make(store, true)
C2.start()
check(store["crew.m.1"] == before and #store["crew.roster"] == 1, "running it again changes nothing")
check(store["inv.crew:1"].iron == 6, "...and doesn't move the pack twice")

-- ── an old save on foot ────────────────────────────────────────────────────
local s2 = { g_played = 3, g_seed = 7, p_body = "Vever", p_x = 10, p_y = 20, p_z = 30,
             ["inv.gear.astro"] = { gravgun = 1 } }
local C3 = make(s2, true)
local r3 = C3.get(1)
check(r3.status == "afoot" and r3.body == "Vever" and r3.x == 10 and r3.z == 30, "on foot at the saved position")
check(s2["crew.active"] == 1, "crew.active = 1")

-- ── a new save ─────────────────────────────────────────────────────────────
local s3 = { g_seed = 99 }
local C4 = make(s3, true)
local r4 = C4.get(1)
check(r4 and r4.status == "afoot" and r4.starter == true, "a new save gets member #1 directly")
check(s3["crew.version"] == 1, "...at the current version")

-- ── before inventory's alias exists ────────────────────────────────────────
local s4 = { g_played = 1, ["inv.astro"] = { iron = 4 } }
local C5, scripts5 = make(s4, false)
C5.start()
check(s4["crew.version"] == 1 and s4["inv.astro"].iron == 4, "no alias yet: the record is made, the pack stays in astro")
check(s4["crew.packMoved"] ~= true, "...and the move is still owed")
scripts5.inventory = { resolve = function(c) return c end }
C5.update()
check(s4["inv.crew:1"] and s4["inv.crew:1"].iron == 4 and s4["inv.astro"] == nil, "the alias arrives: the pack moves")

-- ── names and fees ─────────────────────────────────────────────────────────
check(C.nameFor(1, 1) == C.nameFor(1, 1), "a name is deterministic")
local differ = 0
for n = 1, 10 do if C.nameFor(1, n) ~= C.nameFor(2, n) then differ = differ + 1 end end
check(differ >= 8, "different seeds, different names (" .. differ .. "/10)")
check(C.hireFee(3) == 1500 and C.hireFee(4) == 2100 and C.hireFee(20) == 6000, "the hire fee: 1500, +600 a head, capped at 6000")
local o = C.offers()
check(#o == 3 and o[1].cost == 1500, "three applicants on the board")

-- ── tasks ride the record ──────────────────────────────────────────────────
check(C.setTask(1, { kind = "repair", uid = 6 }) == true and C.task(1).uid == 6, "setTask puts a task on the record")
check(select(1, C.setTask(1, { kind = "repair", uid = 7 })) == false, "one task at a time")
check(C.cancelTask(1, "test") == true and C.task(1) == nil, "cancelTask clears it")
check(C.patch(1, { o2 = 0.5 }) and C.get(1).o2 == 0.5, "patch merges a field")

-- ── EVA checks (§3.3) ──────────────────────────────────────────────────────
local s5 = { g_seed = 1, ["inv.gear.crew:1"] = {} }
local C6, sc6 = make(s5, true)
local st = { surface = false, space = true, speed = 0, throttle = 0, accel = 0 }
local v = { crewAboard = true, node = { valid = true }, evaState = function() return st end,
            evaNow = function() return true end }
sc6["*vessel_controller"] = { v }
local ok, why, warn = C6.evaCheck(1)
check(ok == true and warn ~= nil, "in space without a pack: allowed, with a warning")
local e1, e2, e3 = C6.eva(1)
check(e1 == false and e2 == "confirm" and e3 ~= nil, "eva() without confirming asks first")
check(C6.eva(1, { confirmed = true }) == true, "eva(confirmed) goes")
s5["inv.gear.crew:1"] = { rcspack = 1 }
ok, why, warn = C6.evaCheck(1)
check(ok and warn == nil, "with a pack: no warning")
st.throttle = 0.3
ok, why = C6.evaCheck(1)
check(not ok and why == "engines firing", "engines firing: refused")
st.throttle, st.surface, st.space, st.speed = 0, true, false, 4
ok, why = C6.evaCheck(1)
check(not ok and why:match("moving"), "landed but rolling: refused (" .. tostring(why) .. ")")
st.speed = 0.4
check(C6.evaCheck(1) == true, "landed and still: allowed")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_migrate: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_migrate: all %d checks passed", passed))
