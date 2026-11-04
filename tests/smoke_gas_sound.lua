-- SMOKE: the gas engine's running loop always stops (playtest 9e675fb: "the
-- motor sound gets stuck playing endlessly"). Runs the real
-- vessel_controller.lua's gasTick / gasFx / lateUpdate against a recording
-- audio stub, nothing else of the engine around them.
--
--   luajit solar/tests/smoke_gas_sound.lua
--
-- Holds, for a craft with one 250cc and a tank:
--   * W cranks it (the starter's one-shot, no loop yet), then it runs and its
--     loop plays;
--   * the loop runs down and is STOPPED (not left muted) when the ignition is
--     killed, when the rider gets off, when the tank runs dry, and when the
--     engine itself goes (torn off, the craft rebuilt);
--   * a frame with no tick (the pause menu's physics.pause, a craft gone
--     dormant) fades it within a quarter second and stops it within a second,
--     and the next tick that wants it plays it again;
--   * a rider still aboard with the wheels stowed (a long jump) keeps it
--     idling, and no stick cranks it there.

local fails, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else fails[#fails + 1] = name .. (detail and ("  (" .. tostring(detail) .. ")") or "") end
end

-- ── a recording audio stub ──────────────────────────────────────────────────
local sounds = {}
local audio = {
  play = function(file, node, opts)
    local h = { file = file, loop = opts and opts.loop, vol = opts and opts.volume or 1, stopped = false }
    function h:setVolume(v) self.vol = v end
    function h:setPitch(p) self.pitch = p end
    function h:stop() self.stopped = true end
    sounds[#sounds + 1] = h
    return h
  end,
}
local function loops(file)
  local n, vol = 0, 0
  for _, h in ipairs(sounds) do
    if h.loop and not h.stopped and (not file or h.file:find(file, 1, true)) then n, vol = n + 1, math.max(vol, h.vol or 0) end
  end
  return n, vol
end
local function cranks()
  local n = 0
  for _, h in ipairs(sounds) do if h.file:find("engine_crank", 1, true) then n = n + 1 end end
  return n
end

local ign = true
local E = { valid = true, stateOf = function() return { ign = ign } end }
local env = setmetatable({}, { __index = function(_, k)
  if k == "audio" then return audio end
  if k == "findScript" then return function(n) return n == "electronics" and E or nil end end
  if k == "findScripts" then return function() return {} end end
  if k == "log" or k == "caption" then return function() end end
  if k == "assembly" then return { info = function() return nil end } end
  if k == "save" then return { get = function() return nil end, set = function() end } end
  return _G[k]
end })
local f = io.open("solar/scripts/vessel_controller.lua") and "solar/scripts/vessel_controller.lua" or "scripts/vessel_controller.lua"
local chunk = assert(loadfile(f))
setfenv(chunk, env)
chunk()

local node = { valid = true, id = 7, x = 0, y = 0, z = 0 }
local DT = 1 / 60
local engine = { uid = 1, d = { uid = 1 }, m = { cc = 250, stroke = 4, idle = 1500, red = 10000 } }
local tank = { uid = 2, d = { uid = 2, st = { gas = 4 } }, cap = 4 }
local function reset()
  env.GAS.engines, env.GAS.tanks, env.GAS.cap = { [1] = engine }, { tank }, 4
  engine.run, engine.crank, engine.rpm, engine.ign_was = nil, nil, nil, nil
  tank.d.st.gas, ign = 4, true
end
-- one craft tick as r2Tick runs it: the engines, then their loop
local function tick(ctl, stick, n)
  for _ = 1, n or 1 do
    env.R2.dcmd = stick and 1 or 0
    env.gasTick(DT, ctl)
    env.gasFx(node, nil, DT)   -- (r2Tick: while it has engines, or its loop still plays)
    env.lateUpdate(node, DT)
  end
end
-- a frame with no tick before it (paused, dormant)
local function frame(n) for _ = 1, n or 1 do pcall(env.lateUpdate, node, DT) end end
local function start()
  reset()
  tick(true, true, 1)
  tick(true, true, 50)       -- 0.65 s of starter, then it catches
  tick(true, true, 10)
end

-- ── W cranks, then it runs ──────────────────────────────────────────────────
reset()
tick(true, true, 5)
check("W cranks it: the starter is heard", cranks() == 1, cranks())
check("…no running loop while it cranks", loops("engine_four") == 0, loops("engine_four"))
tick(true, true, 50)
local n, v = loops("engine_four")
check("it catches and its loop plays", n == 1 and v > 0.1, n .. " " .. v)

-- ── the kill switch ─────────────────────────────────────────────────────────
ign = false
tick(true, true, 30)
check("killed: the loop is stopped within half a second", loops("engine_four") == 0, loops("engine_four"))

-- ── the rider gets off ──────────────────────────────────────────────────────
start()
check("restarted", loops("engine_four") == 1)
tick(false, false, 30)
check("rider off: the loop is stopped", loops("engine_four") == 0, loops("engine_four"))
tick(false, false, 120)
check("…and stays stopped (pass 1 played it again from a stale run flag)", loops("engine_four") == 0, loops("engine_four"))

-- ── the tank runs dry ───────────────────────────────────────────────────────
start()
tank.d.st.gas = 0
tick(true, true, 30)
check("dry: the loop is stopped", loops("engine_four") == 0, loops("engine_four"))

-- ── the engine itself goes ──────────────────────────────────────────────────
start()
env.GAS.engines = {}
tick(true, true, 30)
check("engine gone: the loop is stopped", loops("engine_four") == 0, loops("engine_four"))

-- ── no tick: paused or dormant ──────────────────────────────────────────────
start()
local _, v0 = loops("engine_four")
frame(15)
local n1, v1 = loops("engine_four")
check("paused: faded within a quarter second", n1 == 0 or v1 < 0.5 * v0, v0 .. " -> " .. v1)
frame(45)
check("paused: stopped within a second", loops("engine_four") == 0, loops("engine_four"))
tick(true, false, 3)
check("unpaused: it plays again", loops("engine_four") == 1, loops("engine_four"))

-- ── a long jump: tyres stowed, the rider still on ───────────────────────────
start()
local c0 = cranks()
tick(true, false, 180)
check("aloft with a rider: it keeps idling", loops("engine_four") == 1 and engine.run == true)
env.GAS.engines[1].run = false
tick(true, false, 30)
check("…and a stale stick does not crank it there", cranks() == c0, cranks() - c0)

-- ── and with no tick at all, nothing is left playing ────────────────────────
frame(60)
check("no tick: nothing left playing", loops() == 0, loops())

if #fails > 0 then
  print("FAIL smoke_gas_sound: " .. #fails .. " of " .. (#fails + passes))
  for _, m in ipairs(fails) do print("  - " .. m) end
  os.exit(1)
end
print("PASS smoke_gas_sound: " .. passes .. " checks")
