-- SMOKE: suit air and Oxygen Tanks (scripts/crew.lua's air rule, which
-- planet_walker breathes by; docs/crew-and-items.md §2.3, §5.8).
--
--   * with no tanks the suit's built-in air lasts SUIT_AIR_SECS of EVA;
--   * a carried, full tank extends it by the tank's capacity (tanks first,
--     then the built-in supply), and two tanks by both;
--   * with the helmet ON under water the crew breathes suit air, not held
--     breath: 90 s down costs 90 s of suit air and nobody blacks out (held
--     breath is 60 s, 20 s bare-headed at breath_hold 3);
--   * bare-headed under water it is held breath; helmet on in breathable air
--     draws nothing; helmet on in vacuum draws suit air;
--   * with no items library at all (a harness, or before WS3) there are no
--     tanks and the suit behaves as before.
--
--   luajit solar/tests/smoke_crew_air.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local store = { g_seed = 1 }
local scripts = {}
local E = setmetatable({
  time = 0,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
           delete = function(k) store[k] = nil end },
  findScript = function(k) return scripts[k] end,
  findScripts = function() return {} end,
  find = function() return nil end,
}, { __index = _G })
local f = assert(loadfile("solar/scripts/crew.lua"))
setfenv(f, E)
f()
E.params = {}
for k, v in pairs(E.defaults) do E.params[k] = v end
local C = E

-- A stand-in for items.lua's tank interface (o2Reserve / drawO2 / refillO2):
-- per-tank fills in seconds, emptiest drawn first.
local function tank_lib(fills)
  -- the handle it replaces goes invalid, as a real script handle does
  if scripts.items then scripts.items.valid = false end
  return { valid = true,
    o2Reserve = function() local t = 0; for _, v in ipairs(fills) do t = t + v end; return t end,
    drawO2 = function(_, secs)
      table.sort(fills)
      local got = 0
      for i = 1, #fills do
        if got >= secs then break end
        local take = math.min(fills[i], secs - got)
        fills[i] = fills[i] - take
        got = got + take
      end
      return got
    end,
    refillO2 = function() for i = 1, #fills do fills[i] = 900 end; return 0 end,
  }
end

-- Breathe suit air at 10 Hz until it is gone → seconds lasted.
local function eva_lasts(tanks)
  local o2, t, dt = 1.0, 0, 0.1
  while t < 10000 do
    local left
    o2, left = C.drawAir(o2, dt, tanks)
    t = t + dt
    if left <= 1e-6 then return t, o2 end
  end
  return t, o2
end

-- ── no items library: today's suit ─────────────────────────────────────────
local t0 = eva_lasts(C.tanksOf("crew:1"))
check(math.abs(t0 - C.SUIT_AIR_SECS) < 0.2, string.format("no tanks: the suit lasts %.1f s (want %d)", t0, C.SUIT_AIR_SECS))

-- ── one full tank ──────────────────────────────────────────────────────────
scripts.items = tank_lib({ 900 })
local t1 = eva_lasts(C.tanksOf("crew:1"))
check(math.abs(t1 - (C.SUIT_AIR_SECS + 900)) < 0.2, string.format("a full 900 s tank: %.1f s (want %d)", t1, C.SUIT_AIR_SECS + 900))

-- tanks first: after 600 s the built-in supply is untouched
local fills = { 900 }
scripts.items = tank_lib(fills)
local tk = C.tanksOf("crew:1")
local o2 = 1.0
for _ = 1, 6000 do o2 = C.drawAir(o2, 0.1, tk) end
check(o2 == 1.0 and math.abs(fills[1] - 300) < 0.5, string.format("tanks first: built-in %.3f, tank %.1f s left", o2, fills[1]))

-- two tanks, one half empty
scripts.items = tank_lib({ 900, 450 })
local t2 = eva_lasts(C.tanksOf("crew:1"))
check(math.abs(t2 - (C.SUIT_AIR_SECS + 1350)) < 0.3, string.format("two tanks (900 + 450 s): %.1f s", t2))

-- ── where the air comes from ───────────────────────────────────────────────
check(C.airSource(true, true, false) == "suit", "helmet on, under water: suit air")
check(C.airSource(false, true, true) == "hold", "bare-headed under water: held breath")
check(C.airSource(true, false, false) == "suit", "helmet on in vacuum: suit air")
check(C.airSource(true, false, true) == "ambient", "helmet on in breathable air: no drain")
check(C.airSource(false, false, true) == "ambient", "helmet off in breathable air: no drain")

-- ── under water with the helmet on: 90 s down, nobody blacks out ───────────
if scripts.items then scripts.items.valid = false end
scripts.items = nil
local o, held, BREATH, HOLD_MULT = 1.0, 1.0, 60.0, 3.0
local out_suit, out_bare = false, false
local held_bare = 1.0
for _ = 1, 900 do
  local src = C.airSource(true, true, false)
  local left
  if src == "suit" then o, left = C.drawAir(o, 0.1, C.tanksOf("crew:1")); if left <= 0 then out_suit = true end
  else held = held - 0.1 / BREATH end
  -- the same dive bare-headed
  if C.airSource(false, true, false) == "hold" then held_bare = held_bare - 0.1 / BREATH * HOLD_MULT end
  if held_bare <= 0 then out_bare = true end
end
check(not out_suit and held == 1.0, "helmet on: 90 s under water on suit air, held breath untouched")
check(math.abs(o * C.SUIT_AIR_SECS - (C.SUIT_AIR_SECS - 90)) < 0.2, string.format("...it cost 90 s of suit air (%.1f s left)", o * C.SUIT_AIR_SECS))
check(out_bare, "bare-headed the same dive runs out of held breath")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_air: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_air: all %d checks passed", passed))
