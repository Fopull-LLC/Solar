-- SMOKE: alarms and machinery feedback (playtest 2026-11-11: "the alarms
-- don't make any sound or have lights", "reactors and big machinery ... you
-- can inspect and visually and auditorily see if things are stressed"),
-- scripts/plant_av.lua against the real reactor.lua and the fixture plant,
-- room_air and the structures stubbed.
--
--   * reactorCues from a real plant's state: cold and shut down it is quiet;
--     at power the core hums, the pumps run at full speed, the turbine is
--     loaded; with the pumps cut the primary nears boiling: steam, the
--     relief valve, cavitation, the vessel shaking;
--   * pickLoops keeps the loudest n at the crew;
--   * the alarms: a room venting and a reactor's red line are raised from
--     what the systems say, each sounds a recorded loop at its piece, the
--     structure's alarm level goes to the beacons, SILENCE stops the sound
--     (not the alarm), a cleared cause clears it, a new one sounds again;
--   * every sound plant_av plays is a file in audio/.
--
--   luajit solar/tests/smoke_plant_av.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if os.getenv("VERBOSE") then print((ok and "  ok   " or "  FAIL ") .. tostring(msg)) end
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
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
local F = dofile("solar/tests/lib/reactor_fixture.lua")
local CORE = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
local rec, U, cells = F.plant(CORE, {})
local L = R.layout(rec, function(id) return SC.parts_base.partInfo(id) end)
local ch = F.fuel(R, cells, "fuelRod", 8)
local M = R.model(L.plants[1], ch, { tamb = 288, atm = 1 }, {})

local PA = load_script("plant_av.lua", env({}, SC))

-- ── the cues ────────────────────────────────────────────────────────────────
local S = R.newState(288)
local o = R.derive(M, S, S.y, nil, {})
local c0 = PA.reactorCues(M, S, o, R.RX)
check(c0.hum < 0.1 and c0.steam == 0 and not c0.relief and c0.shake == 0, string.format("cold and shut down: a faint hum (%.2f), no steam, no shake", c0.hum))
R.startUp(S, 1.0)
local t = 0
for _ = 1, 1800 do local r = R.advance(S, M, 1, t); t = t + 1 - r.left end
for _ = 1, 6 do local r = R.advance(S, M, 3600, t); t = t + 3600 - r.left end
o = R.derive(M, S, S.y, nil, {})
M.turb_kwe = 100
local c1 = PA.reactorCues(M, S, o, R.RX)
check(c1.hum > 0.8 and c1.pri > 0.9 and c1.sec > 0.9 and c1.load > 0.3, string.format("at %.0f %%: the core hums (%.2f), the pumps at speed (%.2f / %.2f), the turbine loaded (%.2f)", o.P * 100, c1.hum, c1.pri, c1.sec, c1.load))
check(c1.steam == 0 and not c1.relief and c1.cav == 0 and c1.shake == 0, string.format("…and nothing stressed (%.0f K from boiling)", M.tsat - o.Tp))
-- the primary pumps cut with the protection bypassed: it heats toward boiling
local Mcut = R.model(L.plants[1], ch, { tamb = 288, atm = 1 }, { pumps = {} })
Mcut.turb_kwe = 100
S.prot = false
local peak = { steam = 0, relief = false, cav = 0, shake = 0 }
for _ = 1, 600 do
  local r = R.advance(S, Mcut, 1, t); t = t + 1 - r.left
  local oc = R.derive(Mcut, S, S.y, nil, {})
  local c = PA.reactorCues(Mcut, S, oc, R.RX)
  peak.steam = math.max(peak.steam, c.steam); peak.cav = math.max(peak.cav, c.cav); peak.shake = math.max(peak.shake, c.shake)
  peak.relief = peak.relief or c.relief
end
check(peak.steam > 0.5 and peak.relief and peak.shake > 0.3, string.format("the pumps cut at power: steam off the pressuriser (%.2f), its relief valve lifts (%s), the vessel shakes (%.2f)", peak.steam, tostring(peak.relief), peak.shake))
-- cavitation: a pump that flows with the primary near boiling
local Sc = { y = {} }
for i = 1, R.NY do Sc.y[i] = 0 end
Sc.y[20], Sc.y[21] = 1, 1
local cc = PA.reactorCues(M, Sc, { P = 0.6, Tf = 700, Tp = M.tsat - 4, Pe = 50000, Qboil = 0 }, R.RX)
check(cc.cav > 0.5 and cc.steam > 0.8 and cc.shake > 0.3, string.format("the primary 4 K from boiling with the pumps running: they cavitate (%.2f), steam (%.2f), shake (%.2f)", cc.cav, cc.steam, cc.shake))

-- ── the loop pool ───────────────────────────────────────────────────────────
local keep = PA.pickLoops({ { k = "a", gain = 0.1 }, { k = "b", gain = 0.9 }, { k = "c", gain = 0.5 }, { k = "d", gain = 0 } }, 2)
check(keep.b and keep.c and not keep.a and not keep.d, "the loop pool keeps the loudest two at the crew")
check(PA.alarmKindOf("depress", 2) == "klaxon" and PA.alarmKindOf("reactor", 2) == "klaxon" and PA.alarmKindOf("air", 1) == "bell" and PA.alarmKindOf("reactor", 1) == "bell",
  "the klaxon for a room venting and a reactor's warning, the bell for air, fire and a caution")

-- ── the alarms ──────────────────────────────────────────────────────────────
do
  local played, stopped = {}, 0
  local node = { valid = true, worldPos = { x = 0, y = 0, z = 0 } }
  local ra_alarms, plants = {}, {}
  local logs = {}
  local S2 = {
    room_air = { alarms = function() return ra_alarms end, airAlarms = function() return {} end,
      state = function() return { R = { byId = setmetatable({}, { __index = function() return { doors = { 31 } } end }), doors = { [31] = { label = "Door Wall" } } }, life = {} } end },
    reactor_plant = { plants = function() return plants end },
    reactor = R,
    structures = { nodeOf = function() return node end, list = function() return {} end, version = 1 },
    base_log = { add = function(sid, k, txt) logs[#logs + 1] = txt end },
  }
  local E = env({}, S2, {
    find = function(n) if n == "Astronaut" then return { x = 5, y = 0, z = 0, valid = true } end end,
    audio = { play = function(path, ...) played[#played + 1] = path; return { stop = function() stopped = stopped + 1 end } end },
    space = { body = function() return { x = 0, y = 0, z = 0 } end },
  })
  local P2 = load_script("plant_av.lua", E)
  P2.start({ id = 1 })
  local function step(dt) E.time = E.time + dt; P2.update({ id = 1 }, dt) end
  step(0.6)
  check(next(P2.alarms()) == nil and P2.alarmLevel(7) == nil, "no alarm: nothing sounds, no beacon")
  ra_alarms["7:2"] = { sid = 7, rid = 2, cause = "the Door Wall is open" }
  step(0.6)
  local klax = 0
  for _, p in ipairs(played) do if p:find("alarm_klaxon", 1, true) then klax = klax + 1 end end
  check(klax == 1 and P2.alarmLevel(7) == 2, string.format("a room venting: the klaxon sounds at its door (%d), the structure's beacons go red (level %s)", klax, tostring(P2.alarmLevel(7))))
  check(#logs > 0 and logs[1]:find("DEPRESSURISATION", 1, true), "the base log records it: " .. tostring(logs[1]))
  -- a reactor's red line too
  local So = R.newState(288); So.scram = true; So.cause = "hand"
  plants["7:5"] = { key = "7:5", sid = 7, uid = 5, M = M, S = So, o = R.derive(M, So, So.y, nil, {}) }
  step(0.6)
  local n = 0
  for _ in pairs(P2.alarms()) do n = n + 1 end
  check(n == 2, string.format("a tripped reactor raises its own alarm (%d standing)", n))
  local rows, any = P2.terminalRows({ 7 }, 1)
  local sil = nil
  for _, r in ipairs(rows) do if r.id == "pa_silence" then sil = r end end
  check(any and sil and tostring(sil.label):find("SILENCE", 1, true), "the terminal lists them with a SILENCE key: " .. tostring(sil and sil.label))
  local st0 = stopped
  local ok = sil and sil.act()
  check(ok and stopped > st0 and P2.alarmLevel(7) == 2, string.format("SILENCE stops the sound (%d stopped), the alarms and beacons stay", stopped - st0))
  local np = #played
  step(0.6)
  check(#played == np, "silenced, they don't sound again")
  ra_alarms["7:3"] = { sid = 7, rid = 3, cause = "the hab's seal has BLOWN" }
  step(0.6)
  check(#played > np, "a new alarm sounds again")
  ra_alarms = {}
  plants["7:5"] = nil
  step(0.6)
  check(next(P2.alarms()) == nil and P2.alarmLevel(7) == nil, "the causes gone: the alarms clear and the beacons stop")
end

-- ── every file it plays exists ──────────────────────────────────────────────
for k, p in pairs(PA.SND) do
  local f = io.open("solar/" .. p, "rb")
  check(f ~= nil, "plant_av's " .. k .. " sound is in the project: " .. p)
  if f then f:close() end
end

if #failures > 0 then
  print(string.format("FAIL smoke_plant_av: %d of %d", #failures, #failures + passed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print(string.format("smoke_plant_av: %d checks passed", passed))
