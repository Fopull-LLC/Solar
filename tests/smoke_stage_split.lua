-- SMOKE: where a craft comes apart (vessel_controller's SPLIT rulebook) and
-- what the builder's staging stack looks like (builder.lua's STAGE model).
--
--   luajit solar/tests/smoke_stage_split.lua   (from the Floptle repo root)
--
-- The 2026-10-26 playtest: a jet hung on a rocket's radial decoupler, the
-- crew in the jet's cockpit. Firing the decoupler sent the jet away WITHOUT
-- its cockpit, which stayed on the rocket and kept the controls. The cockpit
-- was welded to the fuselage (a builder link that is not the record's
-- `parent`), so the flight's tree saw it as a second root. SPLIT.normalize
-- hangs it back on, and SPLIT.sides keeps the crew's side.
--
-- The SPLIT block is read straight out of scripts/vessel_controller.lua
-- (between its BEGIN and END markers), so this tests the shipped code.

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end
local function root_dir()
  local f = io.open("solar/scripts/vessel_controller.lua", "r")
  if f then f:close() return "solar/" end
  return ""
end
local R = root_dir()

local function load_split()
  local f = assert(io.open(R .. "scripts/vessel_controller.lua", "r"))
  local src = f:read("*a")
  f:close()
  local a = src:find("-- ══ SPLIT RULEBOOK BEGIN", 1, true)
  local b = src:find("-- ══ SPLIT RULEBOOK END", 1, true)
  assert(a and b, "SPLIT markers in vessel_controller.lua")
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadstring(src:sub(a, b - 1), "SPLIT"))
  setfenv(chunk, env)
  chunk()
  return env.SPLIT
end
local SPLIT = load_split()

local function rec(uid, parent, att, o)
  local d = { uid = uid, parent = parent or 0, att = att or "" }
  for k, v in pairs(o or {}) do d[k] = v end
  return d
end
local function by_of(list) local by = {} for _, d in ipairs(list) do by[d.uid] = d end return by end
local function set_eq(set, want)
  local n = 0
  for u in pairs(set) do
    n = n + 1
    local hit = false
    for _, w in ipairs(want) do if w == u then hit = true end end
    if not hit then return false end
  end
  return n == #want
end
local function keys(set)
  local o = {}
  for u in pairs(set) do o[#o + 1] = u end
  table.sort(o)
  return table.concat(o, ",")
end

-- ── 1. the playtest craft (save/user/library/slot2/untitled.json, uids kept) ──
local function rocketjet()
  local parts = {
    rec(29, 0, "", { id = "cockpit", kind = "crewed" }),
    rec(30, 49, "surface", { id = "fuseTank" }),
    rec(31, 30, "bottom", { id = "jet" }),
    rec(32, 31, "surface", { id = "wingSwept" }), rec(33, 31, "surface", { id = "wingSwept" }),
    rec(34, 31, "surface", { id = "tailFin" }),
    rec(38, 33, "surface"), rec(39, 32, "surface"), rec(40, 32, "surface"), rec(41, 33, "surface"),
    rec(42, 32, "surface"), rec(43, 33, "surface"),
    rec(46, 0, "", { id = "tankM" }), rec(47, 46, "bottom", { id = "tankM" }),
    rec(48, 47, "bottom", { id = "engineS" }), rec(49, 47, "surface", { id = "radialDec", radial = 1, decouple = 1 }),
    rec(53, 46, "top", { id = "nose" }),
  }
  local links = {
    { a = 30, b = 31, k = "stack", sa = "bottom", sb = "top", prim = 1 },
    { a = 31, b = 32, k = "surface", sa = "surface", sb = "surface", prim = 1 },
    { a = 31, b = 33, k = "surface", sa = "surface", sb = "surface", prim = 1 },
    { a = 31, b = 34, k = "surface", sa = "surface", sb = "surface", prim = 1 },
    { a = 33, b = 38, k = "surface", prim = 1 }, { a = 32, b = 39, k = "surface", prim = 1 },
    { a = 32, b = 40, k = "surface", prim = 1 }, { a = 33, b = 41, k = "surface", prim = 1 },
    { a = 32, b = 42, k = "surface", prim = 1 }, { a = 33, b = 43, k = "surface", prim = 1 },
    { a = 46, b = 47, k = "stack", sa = "bottom", sb = "top", prim = 1 },
    { a = 47, b = 48, k = "stack", sa = "bottom", sb = "top", prim = 1 },
    { a = 47, b = 49, k = "surface", sa = "surface", sb = "surface", prim = 1 },
    { a = 46, b = 53, k = "stack", sa = "top", sb = "bottom", prim = 1 },
    { a = 49, b = 30, k = "surface", sa = "surface", sb = "surface", prim = 1 },
    { a = 30, b = 29, k = "weld" },
  }
  return parts, links
end
local JET = { 29, 30, 31, 32, 33, 34, 38, 39, 40, 41, 42, 43 }
local ROCKET = { 46, 47, 48, 53 }
do
  -- the bug, as the flight saw it before: the cockpit is a root of its own
  local parts = rocketjet()
  local by = by_of(parts)
  local old = SPLIT.sides(by, SPLIT.kids(parts), 49, nil)
  check(not old[29], "before the fix the cockpit stayed behind (it is no part of the decoupler's tree)")
  -- the fix: the weld hangs the cockpit on its fuselage
  local links
  parts, links = rocketjet()
  local n = SPLIT.normalize(parts, links, 30)
  by = by_of(parts)
  check(n >= 1 and by[29].parent == 30, "normalize: the welded cockpit hangs off its fuselage (parent " .. tostring(by[29].parent) .. ")")
  check(by[29].att == "surface", "normalize: a weld attaches as a surface joint")
  local kids = SPLIT.kids(parts)
  -- the crew in the cockpit: the ROCKET is what leaves, the jet stays with them
  local dep = SPLIT.sides(by, kids, 49, 29)
  check(set_eq(dep, ROCKET), "crew in the jet: the rocket leaves (" .. keys(dep) .. ")")
  -- no crew aboard, the controls on the rocket (a probe there): the jet leaves whole
  dep = SPLIT.sides(by, kids, 49, 46)
  local want = { 49 }
  for _, u in ipairs(JET) do want[#want + 1] = u end
  check(set_eq(dep, want), "command on the rocket: the jet leaves WITH its cockpit (" .. keys(dep) .. ")")
  -- no keep side at all: the decoupler leaves with what is built on it
  dep = SPLIT.sides(by, kids, 49, nil)
  check(dep[29] and dep[30] and not dep[47], "no command: the decoupler's own side leaves")
  -- normalize twice changes nothing
  check(SPLIT.normalize(parts, links, 30) == 0, "normalize is idempotent")
end

-- ── 2. a three-stage stack, built top-down and bottom-up ────────────────────
do
  -- top-down: pod 1 (root) ← tank 2 ← dec 3 ← tank 4 ← engine 5 ← dec 6 ← tank 7 ← engine 8
  local td = { rec(1, 0, "", { kind = "crewed" }), rec(2, 1, "bottom"), rec(3, 2, "bottom", { decouple = 1 }),
               rec(4, 3, "bottom"), rec(5, 4, "bottom"), rec(6, 5, "bottom", { decouple = 1 }),
               rec(7, 6, "bottom"), rec(8, 7, "bottom") }
  local by, kids = by_of(td), SPLIT.kids(td)
  check(set_eq(SPLIT.sides(by, kids, 6, 1), { 6, 7, 8 }), "top-down: the first cut drops the bottom stage")
  check(set_eq(SPLIT.sides(by, kids, 3, 1), { 3, 4, 5, 6, 7, 8 }), "top-down: the second cut drops everything under it")
  -- after the first cut the second drops only what is left
  local gone = { [6] = true, [7] = true, [8] = true }
  check(set_eq(SPLIT.sides(by, kids, 3, 1, function(u) return not gone[u] end), { 3, 4, 5 }), "top-down: nested, after the first cut")
  -- bottom-up: engine 1 (root) → tank 2 → dec 3 → engine 4 → tank 5 → dec 6 → tank 7 → pod 8
  local bu = { rec(1, 0, ""), rec(2, 1, "top"), rec(3, 2, "top", { decouple = 1 }), rec(4, 3, "top"),
               rec(5, 4, "top"), rec(6, 5, "top", { decouple = 1 }), rec(7, 6, "top"), rec(8, 7, "top", { kind = "crewed" }) }
  by, kids = by_of(bu), SPLIT.kids(bu)
  check(set_eq(SPLIT.sides(by, kids, 3, 8), { 1, 2 }), "bottom-up: the first cut drops the stage below, the decoupler stays up")
  gone = { [1] = true, [2] = true }
  check(set_eq(SPLIT.sides(by, kids, 6, 8, function(u) return not gone[u] end), { 3, 4, 5 }), "bottom-up: the second cut")
end

-- ── 3. radial boosters, a symmetric pair, and a booster on a booster ───────
do
  -- core: pod 1 ← tank 2 ← engine 3; radial decs 4, 5 on the tank, boosters 6, 7
  -- (tank + engine each: 6 ← 8, 7 ← 9); a second radial dec 10 on booster 6 with booster 11
  local l = { rec(1, 0, "", { kind = "crewed" }), rec(2, 1, "bottom"), rec(3, 2, "bottom"),
              rec(4, 2, "surface", { radial = 1, decouple = 1, sym = 1 }), rec(5, 2, "surface", { radial = 1, decouple = 1, sym = 1 }),
              rec(6, 4, "surface"), rec(7, 5, "surface"), rec(8, 6, "bottom"), rec(9, 7, "bottom"),
              rec(10, 6, "surface", { radial = 1, decouple = 1 }), rec(11, 10, "surface") }
  local by, kids = by_of(l), SPLIT.kids(l)
  check(set_eq(SPLIT.sides(by, kids, 4, 1), { 4, 6, 8, 10, 11 }), "booster 4 leaves with what hangs on it (and its own booster)")
  check(set_eq(SPLIT.sides(by, kids, 5, 1), { 5, 7, 9 }), "booster 5")
  check(set_eq(SPLIT.sides(by, kids, 10, 1), { 10, 11 }), "the booster's booster leaves alone")
end

-- ── 4. a re-attached sub-assembly: its demoted root is re-rooted ───────────
do
  -- main: 1 (root) ← 2 (radial dec); a lander built apart: 10 (pod, root) ←
  -- 11 (tank) ← 12 (engine), then moved by its tank onto the decoupler: the
  -- link 2→11 became 11's primary, so 11.parent = 2 and the old 10→11 link is
  -- demoted (10 lost nothing, but 11 lost its parent 10 — here: 10 is left
  -- the root of {10}, 11's subtree hangs on 2)
  local l = { rec(1, 0, ""), rec(2, 1, "surface", { radial = 1, decouple = 1 }),
              rec(10, 0, "", { kind = "crewed" }), rec(11, 2, "surface"), rec(12, 11, "bottom"), rec(13, 10, "top") }
  local links = { { a = 1, b = 2, k = "surface", prim = 1 }, { a = 2, b = 11, k = "surface", prim = 1 },
                  { a = 11, b = 12, k = "stack", sa = "bottom", sb = "top", prim = 1 },
                  { a = 10, b = 11, k = "stack", sa = "bottom", sb = "top" },
                  { a = 10, b = 13, k = "stack", sa = "top", sb = "bottom", prim = 1 } }
  SPLIT.normalize(l, links, 1)
  local by = by_of(l)
  check(by[10].parent == 11 and by[10].att == "top", "the lander's pod hangs back on its tank's top (" .. tostring(by[10].parent) .. "/" .. tostring(by[10].att) .. ")")
  check(by[13].parent == 10, "and what was built on the pod stays on it")
  local dep = SPLIT.sides(by, SPLIT.kids(l), 2, 10)
  check(set_eq(dep, { 1 }), "crew in the lander: the carrier leaves (" .. keys(dep) .. ")")
  -- a tree hung by a part deep inside it turns round on the way to its root
  local m = { rec(1, 0, ""), rec(20, 0, ""), rec(21, 20, "top"), rec(22, 21, "top") }
  SPLIT.normalize(m, { { a = 1, b = 22, k = "surface", sa = "surface", sb = "surface" } }, 1)
  by = by_of(m)
  check(by[22].parent == 1 and by[21].parent == 22 and by[20].parent == 21 and by[21].att == "bottom",
    "re-rooting reverses the path (22→1, 21→22 bottom, 20→21)")
end

-- ── 5. broken records: a cycle, a parent that is gone, a lone island ───────
do
  local l = { rec(1, 0, ""), rec(2, 3, "top"), rec(3, 2, "top"), rec(4, 99, "top"), rec(5, 0, "") }
  SPLIT.normalize(l, { { a = 1, b = 2, k = "surface" } }, 1)
  local by = by_of(l)
  check(by[4].parent == 0, "a parent that is not aboard is cut")
  local reach = 0
  for _, d in ipairs(l) do
    local x, g = d.uid, 0
    while (by[x].parent or 0) ~= 0 and g < 10 do x = by[x].parent; g = g + 1 end
    if g < 10 then reach = reach + 1 end
  end
  check(reach == 5, "no cycle is left")
  check(by[2].parent == 1 or by[3].parent == 1, "the cycle hangs on the main tree by its link")
  check(by[5].parent == 0, "an island no link joins stays a root")
end

-- ── 6. a decoupler at the tree's root ──────────────────────────────────────
do
  local l = { rec(1, 0, "", { decouple = 1 }), rec(2, 1, "top"), rec(3, 2, "top", { kind = "crewed" }), rec(4, 1, "bottom"), rec(5, 4, "bottom") }
  local by, kids = by_of(l), SPLIT.kids(l)
  check(set_eq(SPLIT.sides(by, kids, 1, 3), { 4, 5 }), "root decoupler: the crew's piece stays, the other leaves")
end

-- ── 7. the builder's staging stack (builder.lua STAGE model, pure) ──────────
do
  local f = io.open(R .. "scripts/builder.lua", "r")
  local src = f and f:read("*a") or ""
  if f then f:close() end
  local a = src:find("-- ══ STAGE MODEL BEGIN", 1, true)
  local b = src:find("-- ══ STAGE MODEL END", 1, true)
  check(a and b, "STAGE MODEL markers in builder.lua")
  if a and b then
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadstring(src:sub(a, b - 1), "STAGE"))
    setfenv(chunk, env)
    chunk()
    local SM = env.STAGEM
    -- items: a booster ring g1, an axial decoupler u3 (low), u7 (high), the chutes, a fairing u9
    local items = {
      g1 = { key = "g1", ring = true, y = 1.0, uids = { 4, 5 } },
      u3 = { key = "u3", y = 2.0, uids = { 3 } },
      u7 = { key = "u7", y = 6.0, uids = { 7 } },
      c = { key = "c", chute = true, y = 9.0, uids = { 10 } },
      u9 = { key = "u9", fair = true, y = 8.0, uids = { 9 } },
    }
    local st = SM.sync({}, items, {})
    -- default: rings, then axial bottom-up, fairings, chutes last; one event a stage
    local order = {}
    for i, g in ipairs(st) do order[i] = table.concat(g, "+") end
    check(table.concat(order, " ") == "g1 u3 u7 u9 c", "default stages: " .. table.concat(order, " "))
    -- merge the fairing into the stage of u7, move the chutes to the first stage, new stage
    st = SM.move(st, "u9", 3, false)
    order = {}
    for i, g in ipairs(st) do order[i] = table.concat(g, "+") end
    check(table.concat(order, " ") == "g1 u3 u7+u9 c", "fairing joined stage 3: " .. table.concat(order, " "))
    st = SM.move(st, "c", 1, true)
    order = {}
    for i, g in ipairs(st) do order[i] = table.concat(g, "+") end
    check(table.concat(order, " ") == "c g1 u3 u7+u9", "chutes as a new first stage: " .. table.concat(order, " "))
    -- an item that is gone drops, an empty stage closes, a new part slots in by default
    items.u3 = nil
    items.u11 = { key = "u11", y = 4.0, uids = { 11 } }
    st = SM.sync(st, items, {})
    order = {}
    for i, g in ipairs(st) do order[i] = table.concat(g, "+") end
    check(table.concat(order, " ") == "c g1 u11 u7+u9", "sync after edits: " .. table.concat(order, " "))
    -- saved stage numbers come back (a blueprint reloaded): u7 and u9 shared stage 2
    st = SM.sync({}, items, { [7] = 2, [9] = 2, [10] = 1, [4] = 3, [5] = 3 })
    order = {}
    for i, g in ipairs(st) do order[i] = table.concat(g, "+") end
    check(table.concat(order, " ") == "c u7+u9 g1 u11", "from saved stages: " .. table.concat(order, " "))
    -- the per-uid stage index the blueprint carries
    local idx = SM.index(st, items)
    check(idx[10] == 1 and idx[7] == 2 and idx[9] == 2 and idx[4] == 3 and idx[11] == 4, "stage index per part")
  end
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_stage_split: %d/%d checks FAILED", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_stage_split: all %d checks passed", checks))
