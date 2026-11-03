-- SMOKE: the Research Lab (2026-11-03) — the research points stat
-- (scripts/research.lua), the codex (scripts/codex.lua), the lab's zones and
-- tube path (scripts/lab.lua) and the talk view's talking rhythm
-- (scripts/lab_talk.lua):
--
--   * studying a material earns points, more for a kind the lab has never
--     seen, at least FIRST_MIN for a first look even at worthless bulk rock;
--     fractions carry; the studied list keeps units and points per kind; it
--     uses materials.researchValue when the materials table has it and the
--     placeholder table when it does not;
--   * every codex entry has a summary and facts; the fictional ones say so;
--     an unknown material still gets an entry;
--   * the lab's interior is on inside the lab, the link and the depot and off
--     in the yard; a point along the tube is on it;
--   * the talking rhythm stays in the face channels' range.
--
--   luajit solar/tests/smoke_lab.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local store, envs = {}, {}
local API = {
  findScript = function(kind) return envs[kind] end,
  findScripts = function() return {} end,
  log = function() end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return 0 end
    return API[k] or _G[k]
  end })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end

-- ── research points, with the placeholder (no researchValue) ───────────────
local RS = load_script("scripts/research.lua", "research")
local fakeM = {
  grade = function(m) return (m == "basalt" or m == "soil") and "bulk" or ((m == "timber") and "flora" or "ore") end,
  tier = function(m) return ({ iron = 1, basalt = 0, timber = 1, crystal = 3 })[m] or 1 end,
  label = function(m) return m end,
}
envs.materials = fakeM
local g1, f1 = RS.study("iron", 4, nil)
ok(f1 == true and g1 > 0, "a first study of iron is new and earns points (" .. tostring(g1) .. ")")
local g2, f2 = RS.study("iron", 4, nil)
ok(f2 == false and g2 < g1, "a second iron study earns less than the first (" .. g1 .. " then " .. g2 .. ")")
local g3 = RS.study("basalt", 1, nil)
ok(g3 >= RS.FIRST_MIN, "a first look at bulk rock is worth at least FIRST_MIN (" .. g3 .. ")")
local before = RS.points()
for _ = 1, 10 do RS.study("basalt", 1, nil) end
ok(RS.points() >= before, "fractions carry, points never fall")
local rec = RS.studied().iron
ok(rec and rec.n == 8 and rec.rp > 0, "the studied record keeps units and points")
local sl = RS.studiedList()
ok(#sl == 2, "two kinds studied (" .. #sl .. ")")
local gs = RS.study("scrap", 120, nil)
ok(gs >= RS.FIRST_MIN, "wreckage is studied by weight")

-- …and with the materials table's researchValue when it has one
store = {}
fakeM.researchValue = function(mat, origin, first) return (first and 50 or 10) end
local h1 = RS.study("iron", 2, nil)
local h2 = RS.study("iron", 2, nil)
ok(h1 == 100 and h2 == 20, "researchValue is used when present (" .. h1 .. ", " .. h2 .. ")")
fakeM.researchValue = nil

-- ── the codex ───────────────────────────────────────────────────────────────
local CX = load_script("scripts/codex.lua", "codex")
local n, fict = 0, 0
for _, id in ipairs(CX.ids()) do
  local e = CX.entry(id)
  n = n + 1
  ok(e.summary and #e.summary > 10, "codex " .. id .. " has a summary")
  ok(e.facts and #e.facts >= 2, "codex " .. id .. " has facts")
  for _, f in ipairs(e.facts or {}) do ok(#f > 30 and #f < 330, "codex " .. id .. " fact length") end
  if e.fictional then fict = fict + 1 end
end
ok(n >= 35, "the codex covers the materials there are (" .. n .. ")")
ok(CX.entry("crystal").fictional and not CX.entry("iron").fictional, "crystal is fictional, iron is real")
ok(fict >= 5, "fictional entries follow the rules (" .. fict .. ")")
local u = CX.entry("no_such_thing")
ok(u and u.name and #u.facts >= 1, "an unknown material still has an entry")
for _, id in ipairs({ "iron", "copper", "sulfur", "timber", "basalt", "regolith", "geode", "scrap", "ice", "uranium" }) do
  ok(CX.CODEX[id] ~= nil, "codex has " .. id)
end

-- ── the lab: zones, the tube path ───────────────────────────────────────────
local LB = load_script("scripts/lab.lua", "lab")
local function z(gx, gy, gz) return LB.inZone(gx, gy + LB.GROUND_Y, gz - LB.GROUND_Z, 0) end
ok(z(0, 1.0, 0), "the lab's middle is inside")
ok(z(8, 1.0, 12), "the link corridor is inside")
ok(z(8, 1.0, 22), "the depot (the link shows through) is inside")
ok(not z(-17, 1.0, 36), "the intake yard is outside")
ok(not z(0, 1.0, -20), "north of the lab is outside")
ok(not z(0, 20.0, 0), "the roof's sky is outside")
local pts = { { x = 0, y = 0, z = 0 }, { x = 3, y = 0, z = 0 }, { x = 3, y = 4, z = 0 } }
local s = LB.arcLengths(pts)
ok(math.abs(s[3] - 7) < 1e-9, "arc lengths add up")
local p = LB.along(pts, s, 5)
ok(math.abs(p.x - 3) < 1e-9 and math.abs(p.y - 2) < 1e-9, "a point 5 m along is on the second leg")
local c = LB.sampleColour("iron")
ok(c and c[1] > c[3], "iron's sample is rust")

-- ── the talking rhythm ──────────────────────────────────────────────────────
local LT = load_script("scripts/lab_talk.lua", "lab_talk")
local maxj, minj = 0, 1
for i = 0, 400 do
  local v = LT.visemes(i * 0.05, 812)
  maxj, minj = math.max(maxj, v.jaw_open), math.min(minj, v.jaw_open)
  for k, w in pairs(v) do ok(w >= 0 and w <= 1, "viseme " .. k .. " in range") end
end
ok(maxj > 0.25 and maxj < 0.45 and minj < 0.08, string.format("the jaw opens and closes (%.2f..%.2f)", minj, maxj))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_lab: %d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_lab: %d checks passed", checks))
