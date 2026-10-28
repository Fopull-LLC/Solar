-- SMOKE HARNESS: the crew's faces (scripts/crew_faces.lua, scripts/face.lua):
-- looks are deterministic, varied and kept on the record; the emotion model
-- answers what a member lives through; the adapter turns channels into bones.
--
--   luajit solar/tests/smoke_faces.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local ROOT = "solar/"
local function exists(p) local f = io.open(p) if f then f:close() return true end return false end
if not exists(ROOT .. "scripts/crew_faces.lua") then ROOT = "" end

local function load(path, extra)
  local env = setmetatable(extra or {}, { __index = _G })
  local chunk = assert(loadfile(ROOT .. path))
  setfenv(chunk, env)
  chunk()
  return env
end

local F = load("scripts/crew_faces.lua", { time = 0 })
local FACE = load("scripts/face.lua", {})

-- ── looks: deterministic ────────────────────────────────────────────────────
local a = F.lookFor(1902723835, 4, "Mira Ito")
local b = F.lookFor(1902723835, 4, "Mira Ito")
ok(a.key == b.key and a.head == b.head and a.hairStyle == b.hairStyle and a.skin[1] == b.skin[1]
   and a.eye[1] == b.eye[1] and a.courage == b.courage, "the same seed, id and name give the same look")
local c2 = F.lookFor(1902723835, 5, "Mira Ito")
ok(c2.key ~= a.key, "another id: another person")
ok(a.fem == true and a.head >= 5, "Mira reads as a woman: a feminine structure [" .. tostring(a.head) .. "]")
local m = F.lookFor(7, 2, "Jonah Reyes")
ok(m.fem == false and m.head <= 4 and m.stubble >= 0, "Jonah: a masculine structure")
for _, l in ipairs({ a, m }) do
  ok(l.head >= 1 and l.head <= #FACE.RIG.heads, "the structure is one of the heads")
  local found = false
  for _, s in ipairs(FACE.RIG.hair) do if s == l.hairStyle then found = true end end
  ok(found, "the hair style has a model [" .. tostring(l.hairStyle) .. "]")
  ok(l.courage >= 0 and l.courage <= 1 and l.thrill >= 0 and l.thrill <= 1, "courage and thrill in 0..1")
  for i = 1, 3 do ok(l.skin[i] > 0 and l.skin[i] <= 1, "skin colour in range") end
end

-- ── looks: varied (a roster of twelve drawn as the game draws them) ────────
local taken = { heads = {}, styles = {}, skins = {} }
local heads, styles, keys, skins = {}, {}, {}, {}
local names = { "Dana Okafor", "Jonah Reyes", "Mira Ito", "Theo Lindqvist", "Imani Achebe", "Ravi Pillai",
                "Saga Kowalski", "Mateo Castillo", "Noor Haddad", "Bram Kerr", "Hana Tanaka", "Owen Halloran" }
local light, deep = 0, 0
for i, n in ipairs(names) do
  local l = F.lookFor(42, i, n, taken)
  taken.heads[l.head] = (taken.heads[l.head] or 0) + 1
  taken.styles[l.hairStyle] = (taken.styles[l.hairStyle] or 0) + 1
  taken.skins[#taken.skins + 1] = l.skinX
  heads[l.head] = true
  styles[l.hairStyle] = true
  keys[l.key] = true
  skins[#skins + 1] = l.skinX
  if l.skinX < 4 then light = light + 1 end
  if l.skinX > 6.5 then deep = deep + 1 end
end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
ok(count(keys) == #names, "twelve members: twelve different people")
ok(count(heads) >= 7, "…on at least seven of the eight structures [" .. count(heads) .. "]")
ok(count(styles) >= 6, "…with at least six hair styles [" .. count(styles) .. "]")
ok(light >= 2 and deep >= 2, "…light and deep skin both present [" .. light .. " light, " .. deep .. " deep]")
-- the first three (the starters) are three different structures and styles
do
  local t3 = { heads = {}, styles = {}, skins = {} }
  local hs, ss = {}, {}
  for i = 1, 3 do
    local l = F.lookFor(99, i, names[i], t3)
    t3.heads[l.head] = (t3.heads[l.head] or 0) + 1
    t3.styles[l.hairStyle] = (t3.styles[l.hairStyle] or 0) + 1
    t3.skins[#t3.skins + 1] = l.skinX
    hs[l.head], ss[l.hairStyle] = true, true
  end
  ok(count(hs) == 3, "three starters: three faces")
end

-- ── looks: persisted on the record, made once ───────────────────────────────
do
  local recs = { { id = 1, name = "Dana Okafor" }, { id = 2, name = "Jonah Reyes" }, { id = 3, name = "Mira Ito", look = a } }
  local patched = {}
  local C = {
    version = 1,
    roster = function() return recs end,
    get = function(id) for _, r in ipairs(recs) do if r.id == id then return r end end end,
    patch = function(id, f) patched[id] = (patched[id] or 0) + 1; for _, r in ipairs(recs) do if r.id == id then for k, v in pairs(f) do r[k] = v end end end return true end,
  }
  local G = load("scripts/crew_faces.lua", { time = 0, save = { get = function(k) return k == "g_seed" and 5 or nil end },
                                             findScript = function(k) return k == "crew" and C or nil end })
  G.ensure()
  ok(patched[1] == 1 and patched[2] == 1 and not patched[3], "members without a look get one patched on; a kept look stays")
  ok(recs[3].look == a, "…the kept look is untouched")
  G.ensure()
  ok(patched[1] == 1 and patched[2] == 1, "…and only once")
  ok(G.lookOf(1) == recs[1].look, "lookOf reads the record's")
  ok(recs[1].look.head ~= recs[2].look.head, "two members, two structures")
end

-- ── the emotion model ───────────────────────────────────────────────────────
local function run(inp, secs, look, st)
  st = st or F.newState()
  local t = 0
  while t < secs do
    local i = {}
    for k, v in pairs(inp) do i[k] = v end
    if t > 0 then i.events = nil end
    F.step(st, i, 0.1, look)
    F.mix(st, look, 0.1)
    t = t + 0.1
  end
  return st
end
local brave = { courage = 0.95, thrill = 0.3 }
local timid = { courage = 0.1, thrill = 0.3 }
local wild = { courage = 0.5, thrill = 0.95 }

local s = run({ g = 1, aboard = true }, 5, brave)
ok(s.mood == "neutral" or s.mood == "focus", "sitting quietly: calm [" .. s.mood .. "]")
s = run({ g = 4.2, jerk = 0.5, roar = 1, flying = true, aboard = true }, 4, brave)
ok(s.mood == "strain", "4 g under a roaring engine: straining [" .. s.mood .. "]")
ok((s.mix.brow_down_L or 0) > 0.3 and (s.mix.flush or 0) > 0.3, "…brows down, flushed")
s = run({ g = 1.4, roar = 1, flying = true, aboard = true, speed = 400 }, 6, wild)
ok(s.mood == "excited", "a thrill seeker on a gentle climb: excited [" .. s.mood .. "]")
ok((s.mix.smile_L or 0) > 0.4 and (s.mix.jaw_open or 0) > 0.15, "…grinning, mouth open")
local st_t = run({ g = 1, alarm = 0.8, aboard = true }, 3, timid)
local st_b = run({ g = 1, alarm = 0.8, aboard = true }, 3, brave)
ok(st_t.d.fear > st_b.d.fear + 0.2, string.format("the same alarm frightens the timid more (%.2f vs %.2f)", st_t.d.fear, st_b.d.fear))
ok(st_t.mood == "panic" or st_t.mood == "scared", "the timid one is scared [" .. st_t.mood .. "]")
ok((st_t.mix.wide_L or 0) > 0.4 and (st_t.mix.pale or 0) > 0.3, "…eyes wide, pale")
-- relief after fear: the landing
local st = run({ g = 1, alarm = 0.9, aboard = true }, 3, timid)
st = run({ g = 1, aboard = true, events = { "landed" } }, 0.2, timid, st)
st = run({ g = 1, aboard = true }, 2.5, timid, st)
ok(st.mood == "relief" or st.mood == "happy", "a landing after a fright: relief [" .. st.mood .. "]")
ok((st.mix.smile_L or 0) > 0.25, "…smiling")
-- orbit: joy
st = run({ g = 0.05, aboard = true, weightless = true, speed = 900, events = { "orbit" } }, 2, brave)
ok(st.mood == "happy" or st.mood == "delight", "reaching orbit: joy [" .. st.mood .. "]")
-- a long quiet coast: bored
st = run({ g = 0.05, aboard = true, weightless = true, speed = 900 }, 240, brave)
ok(st.mood == "bored", "four minutes of quiet coasting: bored [" .. st.mood .. "]")
-- pain
st = run({ g = 1, hurt = 1, hp = 0.4 }, 1.5, brave)
ok(st.mood == "pain", "a fresh wound: pain [" .. st.mood .. "]")
-- out cold
st = run({ g = 1, out = true }, 1.5, brave)
ok(st.mood == "out" and (st.mix.blink_L or 0) > 0.7, "blacked out: eyes shut [" .. st.mood .. "]")
-- g-LOC: too many gees too long
st = run({ g = 9.5, aboard = true, flying = true }, 6, timid)
ok(st.mood == "out", "9.5 g for six seconds: g-LOC [" .. st.mood .. "]")
-- smoothness: one step never jumps a channel far
do
  local s2 = run({ g = 1, aboard = true }, 3, timid)
  local before = s2.mix.wide_L or 0
  F.step(s2, { g = 1, alarm = 1, aboard = true }, 0.1, timid)
  F.mix(s2, timid, 0.1)
  ok(math.abs((s2.mix.wide_L or 0) - before) < 0.45, "a sudden alarm eases in, no flicker")
end

-- ── the adapter ─────────────────────────────────────────────────────────────
local head = FACE.RIG.heads[1]
local pos0, rot0 = FACE.pose({}, head)
ok(#pos0 == #FACE.RIG.bones * 3 and #rot0 == #FACE.RIG.bones * 3, "the adapter writes every bone")
for i = 1, #pos0 do ok(pos0[i] == head.rest[i], "no channels: the rest pose") end
local pos1, rot1 = FACE.pose({ jaw_open = 1, blink_L = 1 }, head)
local J, LUL = 2, 13
ok(rot1[J * 3 - 1] ~= 0, "jaw_open turns the jaw")
ok(math.abs(rot1[LUL * 3 - 1]) >= head.lidUp * 0.99 and math.abs(rot1[LUL * 3 - 1]) <= head.lidUp * 1.1,
   "blink_L shuts the left upper lid by the head's own angle")
local pos3, rot3 = FACE.pose({ blink_L = 1, brow_down_L = 1, squint_L = 1 }, head)
ok(math.abs(rot3[LUL * 3 - 1]) <= head.lidUp * 1.1, "…and never past shut, whatever else weighs on it")
local posR = FACE.pose({ smile_R = 1 }, head)
ok(posR[6 * 3 - 2] < head.rest[6 * 3 - 2], "smile_R moves the right corner out (to the crew's right, -x)")
ok(rot1[14 * 3 - 1] == 0, "…and not the right one")
local pos2 = FACE.pose({ smile_L = 1 }, head)
ok(pos2[5 * 3 - 1] > head.rest[5 * 3 - 1], "smile_L lifts the left corner")
-- every expression names only channels the adapter knows; every channel
-- (bar the colour ones) has bones in the map
local known = {}
for _, k in ipairs(FACE.CHANNELS) do known[k] = true end
for _, k in ipairs(FACE.CHANNELS) do
  if k ~= "flush" and k ~= "pale" and k ~= "pupil" then ok(FACE.RIG.map[k] ~= nil, "channel " .. k .. " has bones in the map") end
end
for name, e in pairs(F.EXPR) do
  for k in pairs(e) do ok(known[k], "expression " .. name .. ": channel " .. k .. " is known") end
end

print(string.format("smoke_faces: %d checks, %d failures", checks, #failures))
for _, f in ipairs(failures) do print("  FAIL: " .. f) end
os.exit(#failures == 0 and 0 or 1)
