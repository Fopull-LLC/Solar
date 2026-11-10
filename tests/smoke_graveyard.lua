-- SMOKE: the Graveyard Shift scenario's station and its plant
-- (scenarios/graveyard_shift/, tools/gen_graveyard_station.lua), against the
-- real reactor.lua, rooms.lua, blueprints.lua and the kit:
--   * station.bp.txt is the generator's output (regenerate it if this fails)
--   * both loops close nozzle to nozzle; two pumps on each; a pressuriser
--   * the rooms seal: the hall, the control room, the bunk room, the airlock
--   * the night: twenty days at 60 %, a trip, parked at 2 %; 2 → 30 → 60 %
--     inside the act's few minutes; FW-2 out at 40 % costs nothing
--   * PL-7 at 15 % of its bore: with the protection in it trips at once and
--     the fuel stays cool; makeup alone can't hold it, makeup and the weld
--     refill it; with the protection bypassed and no SCRAM the core melts
--     inside five minutes (the scenario's fail is real)
--
--   luajit solar/tests/smoke_graveyard.lua
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end return ok end
local function env(store, scripts)
  return setmetatable({ time = 5.0, save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end, findScripts = function() return {} end, find = function() return nil end, log = function() end }, { __index = _G })
end
local function load_script(path, E) local f = assert(loadfile("solar/scripts/" .. path)); setfenv(f, E); f(); E.params = {}; for k, v in pairs(E.defaults or {}) do E.params[k] = v end; return E end
local SC = {}
SC.thermal = load_script("thermal.lua", env({}, SC))
SC.parts_kit = load_script("parts_kit.lua", env({}, SC))
SC.parts_base = load_script("parts_base.lua", env({}, SC))
SC.reactor = load_script("reactor.lua", env({}, SC))
SC.rooms = load_script("rooms.lua", env({}, SC))
SC.blueprints = load_script("blueprints.lua", env({}, SC))
local defs = function(id) return SC.parts_base.partInfo(id) end
local G = dofile("solar/tools/gen_graveyard_station.lua")
local P, U = G.build(defs)
local R, I = SC.reactor, SC.reactor.IDX

-- ── the file is the generator's ──
do
  local f = io.open("solar/scenarios/graveyard_shift/station.bp.txt", "rb")
  local code = f and f:read("*a") or ""
  if f then f:close() end
  local bp = SC.blueprints.decode(code)
  check(bp ~= nil and SC.blueprints.same(bp, { pieces = P }), "station.bp.txt is the generator's output (" .. tostring(bp and bp.n) .. " vs " .. #P .. " pieces)")
  check(#code < SC.blueprints.CODE_MAX, string.format("the code fits (%d of %d)", #code, SC.blueprints.CODE_MAX))
  for _, k in ipairs({ "pl7", "fw2", "mu1", "p3", "beaconHall", "beaconCtl" }) do check(U[k] ~= nil, "named piece " .. k) end
  check(U.pl7 == 109 and U.fw2 == 147 and U.mu1 == 114 and U.p3 == 116 and U.beaconHall == 378 and U.beaconCtl == 379,
    string.format("the scenario's uids: PL-7 %s FW-2 %s MU-1 %s P-3 %s beacons %s %s", U.pl7, U.fw2, U.mu1, U.p3, U.beaconHall, U.beaconCtl))
end

local rec = { id = 7, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = P, st = {} }
-- ── the loops and the rooms ──
local L = R.layout(rec, defs)
local pl = L.plants[1]
check(#L.plants == 1 and pl.pri.closed and pl.sec.closed, "both loops close")
check(#pl.pri.pumps == 2 and #pl.sec.pumps == 2 and pl.pri.press ~= nil and #pl.sec.rejects == 8 and #pl.sec.turbines == 1,
  string.format("two coolant pumps, two feed pumps, a pressuriser, eight radiators, a turbine (%d %d %d %d)", #pl.pri.pumps, #pl.sec.pumps, #pl.sec.rejects, #pl.sec.turbines))
do
  local Rm = SC.rooms.solve(rec, defs, os.clock)
  local sealed, lock, big = 0, 0, 0
  for _, r in ipairs(Rm.rooms) do
    if r.sealed then sealed = sealed + 1 end
    if r.airlock then lock = lock + 1 end
  end
  check(sealed == 4 and lock == 1, string.format("four sealed rooms, one an airlock (%d sealed, %d airlocks)", sealed, lock))
end

-- ── the night ──
local ch = {}
for _, c in ipairs(U.cells) do if c.ch == "F" then local rods = {} for k = 1, 8 do rods[k] = R.newRod("fuelRod") end ch[c.uid] = { rods = rods } end end
local ENV = { tamb = 210, atm = 0.1 }
local run = { pumps = {}, press = true, tower = true, turbine = true, brkA = 0, mk = 0 }
for _, L2 in ipairs({ pl.pri, pl.sec }) do for _, pu in ipairs(L2.pumps) do run.pumps[pu.uid] = true end end
local M = R.model(pl, ch, ENV, run)
check(#M.why == 0, "nothing missing: " .. table.concat(M.why, "; "))
local S = R.newState(ENV.tamb)
local t = 0
local function rebuild() M = R.model(pl, ch, ENV, run) end
local peak = 0
local function adv(dt, n)
  for _ = 1, n do
    local rep = R.advance(S, M, dt, t); t = t + dt - rep.left
    local o = R.derive(M, S, S.y, nil, {})
    if o.Tf > peak then peak = o.Tf end
  end
  return R.derive(M, S, S.y, nil, {})
end
R.startUp(S, 0.6); adv(1, 1800); adv(3600, 24 * 20)
local o = adv(0, 0)
check(not S.scram and math.abs(o.P - 0.6) < 0.01 and o.Pe > 25e3, string.format("twenty days at 60 %%: %.1f kW(e), condenser %.0f K", (o.Pe or 0) / 1000, o.Tk))
R.scram(S, t); adv(60, 25); R.resetTrip(S); R.startUp(S, 0.02); adv(10, 180)
o = adv(0, 0)
check(math.abs(o.P - 0.02) < 0.005, string.format("parked at 2 %% (%.3f)", o.P))
S.set = 0.3; o = adv(10, 24)
check(o.P > 0.28, string.format("2 → 30 %% inside four minutes (%.3f)", o.P))
S.set = 0.6; o = adv(10, 12)
check(o.P > 0.57 and not S.scram, string.format("30 → 60 %% inside two (%.3f)", o.P))
S.set = 0.4; adv(10, 12)
run.pumps[pl.sec.pumps[1].uid] = false; rebuild(); o = adv(10, 30)
check(not S.scram and math.abs(o.P - 0.4) < 0.02, "FW-2 out at 40 %: no trip")
run.pumps[pl.sec.pumps[1].uid] = true; rebuild(); S.set = 0.6; adv(10, 30)
local base = { y = {}, mode = S.mode, set = S.set, t = t }
for i, v in ipairs(S.y) do base.y[i] = v end
local function restore(prot)
  for i, v in ipairs(base.y) do S.y[i] = v end
  S.mode, S.set, S.scram, S.cause, S.melt, S.prot, S.cooldown, t = base.mode, base.set, false, nil, nil, prot, nil, base.t
  run.brkA, run.mk = 2 * 0.15 * (R.PIPE_A or 0.00745), 0; rebuild(); peak = 0
end
-- the protection in, makeup at 60 s, the weld at 300 s
restore(true)
local tripped
for k = 1, 900 do
  if k == 60 then run.mk = 2.0; rebuild() end
  if k == 300 then run.brkA = 0; rebuild() end
  adv(1, 1)
  if S.scram and not tripped then tripped = k end
end
o = adv(0, 0)
check(tripped and tripped <= 2 and S.cause == "subcool", "the break trips it at once on subcooling (" .. tostring(S.cause) .. " at " .. tostring(tripped) .. " s)")
check(S.y[I.inv] > 0.9 and o.Tf < 400 and peak < 760, string.format("makeup and the weld refill it: inventory %.2f, fuel %.0f K, peak %.0f K", S.y[I.inv], o.Tf, peak))
-- makeup alone: the core uncovers anyway
restore(true)
for k = 1, 600 do if k == 60 then run.mk = 2.0; rebuild() end adv(1, 1) end
check(S.y[I.inv] < 0.3, string.format("makeup alone can't hold a 15 %% break: inventory %.2f after 10 min", S.y[I.inv]))
-- bypassed and nobody SCRAMs: it melts
restore(false)
local melt
for k = 1, 420 do adv(1, 1); if S.melt and not melt then melt = k end end
check(melt ~= nil and melt < 300, "protection bypassed, no SCRAM: MELTDOWN at " .. tostring(melt) .. " s")
-- bypassed, a SCRAM by hand at 20 s: it lives
restore(false)
for k = 1, 600 do if k == 20 then R.scram(S, t) end if k == 90 then run.mk = 2.0; rebuild() end adv(1, 1) end
check(not S.melt and peak < 1250, string.format("bypassed, SCRAM by hand at 20 s: no melt, peak %.0f K", peak))

print(string.format("smoke_graveyard: %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL " .. f) end
os.exit(#failures == 0 and 0 or 1)
