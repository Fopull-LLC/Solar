-- SMOKE: a reactor's control under time warp (playtest 2026-11-11: "the
-- reactor settings and stuff are not affected by warp, so you can't speed up
-- the automatic transferring with the rods when you change the setpoint"),
-- against the real reactor.lua, thermal.lua, parts_kit.lua and parts_base.lua
-- and the fixture plant.
--
-- reactor_plant steps every plant on the agency clock (game time, warp
-- included) at 5 Hz with at most STEPS solver steps a tick; warp ×N hands each
-- tick N times the game seconds. This checks that what the controller does
-- after a setpoint change lands in the same GAME time at every warp, with the
-- tick's step budget:
--   * 50 % → 100 %: after 600 game s the power and the rods are the same at
--     ×1, ×10, ×100 and ×1000 (one 0.2 s tick of game time each: 0.2, 2, 20,
--     200 s), to the solver's tolerance;
--   * a setpoint cut 100 % → 40 % the same;
--   * the budget never runs out at ×1000 (nothing carried), and at ×10000
--     (2,000 s a tick) what is carried is caught up the next ticks: no game
--     time lost;
--   * a SCRAM under warp trips at the same game instant.
--
--   luajit solar/tests/smoke_reactor_warp.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function env(store, scripts)
  return setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end
local SC = {}
SC.thermal = load_script("thermal.lua", env({}, SC))
SC.parts_kit = load_script("parts_kit.lua", env({}, SC))
SC.parts_base = load_script("parts_base.lua", env({}, SC))
local R = load_script("reactor.lua", env({}, SC)); SC.reactor = R
local RP = load_script("reactor_plant.lua", env({}, SC))
local F = dofile("solar/tests/lib/reactor_fixture.lua")
local CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
local rec, U, cells = F.plant(CORE, {})
local L = R.layout(rec, function(id) return SC.parts_base.partInfo(id) end)
local ch = F.fuel(R, cells, "fuelRod", 8)
local M = R.model(L.plants[1], ch, { tamb = 288, atm = 1 }, {})
local function copy(x) if type(x) ~= "table" then return x end local c = {} for k, v in pairs(x) do c[k] = copy(v) end return c end

-- at 50 % for a day
local S0 = R.newState(288)
R.startUp(S0, 0.5)
local t0 = 0
for _ = 1, 1800 do local r = R.advance(S0, M, 1, t0); t0 = t0 + 1 - r.left end
for _ = 1, 24 do local r = R.advance(S0, M, 3600, t0); t0 = t0 + 3600 - r.left end
local o0 = R.derive(M, S0, S0.y, nil, {})
check(math.abs(o0.P - 0.5) < 0.01, string.format("the plant holds 50 %% on the automatic controller (%.3f)", o0.P))

-- the plant's ticks at warp w for `game` seconds: each tick 0.2·w game s, at most STEPS steps
local function ticks(S, w, game)
  local saved = R.RX.MAXSTEPS
  R.RX.MAXSTEPS = RP.STEPS
  local t, done, carried, maxleft = t0, 0, 0, 0
  local due = 0
  while done < game - 1e-9 do
    due = due + math.min(0.2 * w, game - done - due)
    local rep = R.advance(S, M, due, t)
    local took = due - rep.left
    t, done, due = t + took, done + took, rep.left
    if rep.left > 0 then carried = carried + 1; maxleft = math.max(maxleft, rep.left) end
    if due <= 0 and done >= game - 1e-9 then break end
  end
  R.RX.MAXSTEPS = saved
  return R.derive(M, S, S.y, nil, {}), carried, maxleft, t
end

for _, set in ipairs({ 1.0, 0.4 }) do
  local ref_o = nil
  for _, w in ipairs({ 1, 10, 100, 1000 }) do
    local S = copy(S0)
    S.set = set
    local o, carried = ticks(S, w, 600)
    if not ref_o then ref_o = o end
    check(carried == 0, string.format("setpoint %d %% at ×%d: the tick's %d-step budget covers %.0f game s a tick (nothing carried)", set * 100, w, RP.STEPS, 0.2 * w))
    check(math.abs(o.P - ref_o.P) < 0.01 and math.abs(o.x - ref_o.x) < 0.005,
      string.format("setpoint %d %% at ×%d: after 600 game s the power %.3f and the rods %.3f (×1: %.3f, %.3f)", set * 100, w, o.P, o.x, ref_o.P, ref_o.x))
  end
  check(math.abs(ref_o.P - set) < 0.03, string.format("…and the controller has brought it to %d %% in those 10 minutes (%.3f)", set * 100, ref_o.P))
end
-- ×10000: 2,000 s a tick; whatever runs out of steps is carried, never lost
do
  local S = copy(S0)
  S.set = 1.0
  local o, carried, maxleft, t = ticks(S, 10000, 6000)
  check(math.abs(t - (t0 + 6000)) < 1e-6, string.format("at ×10000 every game second is stepped (%.1f s carried at most, %d ticks carried)", maxleft, carried))
  check(math.abs(o.P - 1.0) < 0.03, string.format("…and the plant is at 100 %% (%.3f)", o.P))
end
-- a SCRAM under warp: the same instant
do
  local Sa, Sb = copy(S0), copy(S0)
  R.scram(Sa, t0); R.scram(Sb, t0)
  local oa = ticks(Sa, 1, 120)
  local ob = ticks(Sb, 1000, 120)
  check(Sa.scram and Sb.scram and math.abs(oa.P - ob.P) < 0.002 + 0.02 * oa.P, string.format("a SCRAM's power after 2 min: %.4f at ×1, %.4f at ×1000", oa.P, ob.P))
end

if #failures > 0 then
  print(string.format("FAIL smoke_reactor_warp: %d of %d", #failures, #failures + passed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print(string.format("smoke_reactor_warp: %d checks passed", passed))
