-- SMOKE HARNESS: sfx.lua's impacts, failures and footsteps (Ty 2026-11-12:
-- "the same sound effect gets reused and doesn't fit the context ... when
-- something goes wrong it plays something like a can-drop sound").
--
-- Holds: what met what picks the bank (a hull on rock is not a hull on soil,
-- a tyre is not a hull, glass is glass), energy picks the weight, takes never
-- repeat back to back, pitch and level are jittered, every failure has its own
-- sound and none of them is the old steel-bar drop, footsteps follow the
-- ground's material, and every clip a bank names is on disk.
--
--   luajit solar/tests/smoke_impact_sfx.lua

local T = 0.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local played = {}
local SLOT = 1                       -- what terrain.slotAt answers
local MATS = { [1] = "regolith", [2] = "soil", [12] = "ice", [16] = "sand", [14] = "granite" }
local materials = { valid = true, ofSlot = function(s) return MATS[s] or "regolith" end }
local SCRIPTS = { materials = materials }
local logs = {}
local API = {
  audio = {
    play = function(clip, a, b, c, d)
      local node, x, opts = nil, nil, a
      if type(a) == "table" and a.__id then node, opts = a, b
      elseif type(a) == "number" then x, opts = a, d end
      played[#played + 1] = { clip = clip, opts = opts, node = node, x = x }
    end,
    preload = function() end,
  },
  terrain = { slotAt = function() return SLOT end },
  findScript = function(kind) return SCRIPTS[kind] end,
  log = function(s) logs[#logs + 1] = s end,
  find = function() return nil end,
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end, __newindex = function(t, k, v) rawset(t, k, v) end })
local chunk = assert(loadfile("solar/scripts/sfx.lua"))
setfenv(chunk, env)
chunk()
env.start({})
local function tick(s) T = T + (s or 0.2) end
local function last() return played[#played] end

-- ── every clip a bank names exists ─────────────────────────────────────────
local missing = {}
for name, B in pairs(env.BANKS) do
  for _, c in ipairs(B[1]) do
    local f = io.open("solar/" .. c, "rb")
    if f then f:close() else missing[#missing + 1] = name .. ": " .. c end
  end
end
ok(#missing == 0, "every bank's clips are on disk: " .. table.concat(missing, ", "))

-- ── what met what ──────────────────────────────────────────────────────────
local B = env.bankFor
ok(B("metal", "rock", 2, 50) == "metal_light", "a light knock of metal on rock is a light metal knock")
ok(B("metal", "rock", 8, 2000) == "metal_rock", "a rover coming down on rock is metal on stone")
ok(B("metal", "soil", 8, 2000) == "metal_dull", "…and on soil a dull thud, not the same clip")
ok(B("metal", "metal", 8, 2000) == "metal_metal", "metal on metal is metal on metal")
ok(B("metal", "rock", 15, 8000) == "metal_heavy", "a lander hitting hard is the heavy crash")
ok(B("rock", "metal", 15, 8000) == "metal_heavy", "…in either order")
ok(B("tyre", "rock", 10, 300) == "tyre", "a tyre is a tyre")
ok(B("glass", "metal", 1, 2) == "glass_knock" and B("glass", "rock", 6, 20) == "glass_break", "glass knocks, then breaks")
ok(B("suit", "soil", 4, 100) == "soil_light" and B("suit", "rock", 9, 120) == "suit_fall", "a person lands on the ground, then falls on it")
ok(B("suit", "metal", 4, 100) == "metal_light", "a person against a hull is a knock on metal")
ok(B("plastic", "rock", 3, 5) == "plastic", "plastic is plastic")
ok(B("rock", "rock", 2, 5) == "rock_light", "a pebble on rock")
ok(B("soil", "soil", 3, 40) == "soil_light", "soil on soil")
ok(env.familyOf("hull", "terrain") == "metal_rock", "names fold onto the classes (hull, terrain)")
ok(env.familyOf("whatever", "rock") == "metal_rock", "an unknown material reads as metal")

-- `terrain` asks the ground at the point
SLOT = 2
local bank = env.impact({ a = "metal", b = "terrain", speed = 8, mass = 2000, x = 1, y = 2, z = 3 })
ok(bank == "metal_dull" and last().clip:find("metal_dull_", 1, true), "a hull on soil plays the dull thud")
ok(last().x == 1 and last().opts.track == "SFX" and last().opts.mode == "Spatial", "…at the point, spatial, on the SFX bus")
tick()
SLOT = 14
bank = env.impact({ a = "metal", b = "terrain", speed = 8, mass = 2000, x = 1, y = 2, z = 3 })
ok(bank == "metal_rock", "…and on granite metal on stone")
tick()

-- heavier and faster is louder; heavier is lower
local function opts_of(s) env.impact(s); tick(); return last().opts end
local quiet = opts_of({ a = "metal", b = "rock", speed = 2, mass = 50, x = 0, y = 0, z = 0 })
local loud = opts_of({ a = "metal", b = "rock", speed = 9, mass = 3000, x = 0, y = 0, z = 0 })
ok(loud.volume > quiet.volume, "more energy, louder")
ok(loud.pitch < quiet.pitch + 0.05, "more mass, lower")

-- past a megajoule a crash rides on top
local n0 = #played
env.impact({ a = "metal", b = "rock", speed = 25, mass = 8000, x = 0, y = 0, z = 0 })
ok(#played == n0 + 2 and played[n0 + 2].clip:find("crash_", 1, true), "a big crash layers the debris")
tick()

-- ── variation ──────────────────────────────────────────────────────────────
for _, name in ipairs({ "metal_rock", "metal_dull", "scrape", "step_grit", "tyre", "zap" }) do
  local prev, repeats, seen, pitches = nil, 0, {}, {}
  for _ = 1, 60 do
    local c = env.playBank(name, nil, 0, 0, 0)
    tick(0.3)
    if c == prev then repeats = repeats + 1 end
    prev = c
    seen[c] = true
    pitches[#pitches + 1] = last().opts.pitch
  end
  local kinds = 0
  for _ in pairs(seen) do kinds = kinds + 1 end
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pitches) do lo, hi = math.min(lo, p), math.max(hi, p) end
  ok(repeats == 0, name .. ": never the same take twice running")
  ok(kinds >= 2, name .. ": more than one take heard")
  ok(hi - lo > 0.02 and lo > 0.8 and hi < 1.2, name .. ": pitch jittered, within reason")
end
-- one bank twice in the same instant is one sound (a pile of contacts in a tick)
n0 = #played
env.playBank("metal_light", nil, 0, 0, 0); env.playBank("metal_light", nil, 0, 0, 0)
ok(#played == n0 + 1, "the same bank twice in one frame plays once")
tick()

-- ── failures: each its own, none of them a dropped can ────────────────────
local firsts = {}
for _, kind in ipairs({ "part_break", "explode", "crash", "scrape", "short", "battery_fire",
                        "hull_breach", "suit_damage", "breaker_trip", "scram" }) do
  n0 = #played
  local b1 = env.fail(kind, { x = 5, y = 0, z = 0 })
  tick(0.5)
  ok(b1 ~= nil, kind .. " plays")
  local can = false
  for i = n0 + 1, #played do if played[i].clip:find("steel_drop", 1, true) then can = true end end
  ok(not can, kind .. " is not the steel-bar drop")
  firsts[kind] = b1
end
ok(firsts.part_break == "part_break" and firsts.short == "zap" and firsts.hull_breach == "breach"
   and firsts.suit_damage == "visor_crack" and firsts.battery_fire == "fire_flare"
   and firsts.scrape == "scrape" and firsts.crash == "crash", "each failure leads with its own bank")
ok(firsts.scrape ~= "blast" and firsts.part_break ~= "blast", "a scrape and a broken part are no longer a gunshot")
ok(env.fail("no-such-failure") == nil, "an unknown failure is silent, not an error")

-- ── footsteps follow the ground ───────────────────────────────────────────
SLOT = 1; ok(env.surfaceAt(0, 0, 0) == "grit", "regolith is grit underfoot")
SLOT = 2; ok(env.surfaceAt(0, 0, 0) == "soil", "soil is soil")
SLOT = 16; ok(env.surfaceAt(0, 0, 0) == "sand", "sand is sand")
SLOT = 12; ok(env.surfaceAt(0, 0, 0) == "snow", "ice crunches like snow")
SLOT = 255; ok(env.surfaceAt(0, 0, 0) == "grit", "untextured ground is regolith")
local astro = { valid = true, __id = 7 }
for _, s in ipairs({ "grit", "soil", "sand", "snow", "metal", "wood" }) do
  env.step(s, astro, 1.0)
  ok(last().clip:find(s == "wood" and "footstep_wood" or ("step_" .. s), 1, true) and last().node == astro,
     "a step on " .. s .. " sounds like " .. s .. ", following the crew")
  tick()
end
env.step("lava", astro); ok(last().clip:find("step_grit", 1, true), "an unknown surface falls back to grit")
tick()
for i = 1, 40 do env.step("grit", astro); tick(0.3) end
local concrete = false
for _, p in ipairs(played) do if p.clip:find("footstep_concrete", 1, true) then concrete = true end end
ok(not concrete, "no step on a world was Kenney's concrete")

-- ── the record probes read ────────────────────────────────────────────────
local h = env.history[#env.history]
ok(h and h.bank == "step_grit" and h.event == "step grit" and h.clip:find("step_grit"), "history names the event, bank and clip")
env.sfxLog = true
env.fail("short", { x = 0, y = 0, z = 0 })
ok(logs[#logs] and logs[#logs]:match("^SFX short zap audio/impact/zap_%d%.ogg$"), "sfxLog puts 'SFX <event> <bank> <clip>' in the Console")
ok((env.played.zap or 0) > 0, "plays are counted per bank")

-- ── result ────────────────────────────────────────────────────────────────
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_impact_sfx: %d/%d", checks - #failures, checks))
  os.exit(1)
end
print(string.format("smoke_impact_sfx: %d/%d OK", checks, checks))
