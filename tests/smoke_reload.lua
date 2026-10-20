-- SMOKE HARNESS: a RESUMED save gets off the loading screen.
--
-- The bug: loading a save that has played before (Continue, a save picked from
-- the menu after Pause → quit, back from the Vehicle Assembly) sat on the
-- loading screen forever with the base "waiting for terrain…". A resumed save
-- does not pre-generate its world — it streams back from the slot — and the
-- engine streams a cold world in only when a dynamic body comes near it. The
-- crew IS parked over it, but under physics.pause that is a script write the
-- engine's residency never sees, so nothing streamed and the surface never
-- answered.
--
-- Runs the real game_manager.lua against stubs and holds it to:
--   1. while the curtain is up, the spawn world is warmed BY NAME every frame
--      (terrain.warm — residency regardless of where the anchors are),
--      and on a resumed save as much as on a new one;
--   2. the moment its surface answers, loading ends and physics resumes;
--   3. a surface that never answers trips the fallback once (physics runs,
--      the crew stays pinned) instead of waiting forever;
--   4. loadGate's verdicts.
--
--   luajit solar/tests/smoke_reload.lua

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

local STORE = {}
local W = { name = "Vever", x = 62000, y = 0, z = 23000, radius = 803, soi = 9000 }
local warmed, pauses = {}, {}
local surface = false   -- does the spawn world's field answer yet?
_G.terrain = {
  saveDir = function() end,
  busy = function() return false end,
  warm = function(n) warmed[#warmed + 1] = n end,
  query = function() if surface then return 0.2 end return nil end,
}
_G.physics = { pause = function(on) pauses[#pauses + 1] = on end }
_G.space = {
  body = function(n) if n == W.name then return W end end,
  bodies = function() return { W } end,
  dominant = function() return W.name end,
}
_G.save = { get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
            slot = function() return "slot3" end, flush = function() end }
_G.log = function() end
_G.time = 0
local printed = {}
_G.print = function(s) printed[#printed + 1] = tostring(s) end
local ASTRO = { x = 28, y = 190, z = -4739, vx = 0, vy = 0, vz = 0 }
_G.find = function(n) if n == "Astronaut" then return ASTRO end end
_G.findScripts = function() return {} end
local GEN
GEN = {
  CURRENT_SCALE = 2, lastSeed = 1911564384,
  regenerate = function(seed, opts)
    GEN.opts = opts
    GEN.lastSpawnBody, GEN.lastSpawnRadius = W.name, W.radius
    GEN.lastSpawnX, GEN.lastSpawnY, GEN.lastSpawnZ = W.x, W.y, W.z
  end,
}
_G.findScript = function(k) if k == "system_generator" then return GEN end end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local f = assert(loadfile(path))
  setfenv(f, env)
  f()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end

local function run(seconds, gm)
  local dt = 1 / 30
  local t_end = _G.time + seconds
  while _G.time < t_end and gm.loading do
    _G.time = _G.time + dt
    gm.update({}, dt)
  end
end

-- ── 1+2. a RESUMED save: it has played, its colony stands ───────────────────
STORE.g_seed, STORE.g_played, STORE.g_scale = 1911564384, 3, 2
STORE["base.body"], STORE["base.x"], STORE["base.y"], STORE["base.z"] = "Vever", 300, 740, 0
STORE.p_body, STORE.p_x, STORE.p_y, STORE.p_z = "Vever", 300, 745, 0
local gm = load("solar/scripts/game_manager.lua")
gm.start({})
check("a resumed save does not pre-generate (it streams back from the slot)", GEN.opts.pregen == false)
check("loading starts with physics paused", gm.loading == true and pauses[1] == true)
run(5, gm)
local all_vever = #warmed > 0
for _, n in ipairs(warmed) do if n ~= "Vever" then all_vever = false end end
check("the spawn world is warmed by name every frame while the curtain is up",
  all_vever and #warmed >= 140, string.format("%d warm calls", #warmed))
check("...the crew is parked over the LIVE spawn world, not at the scene's spot",
  math.abs(ASTRO.x - W.x) < 1e-6 and ASTRO.y > W.radius, string.format("%.0f %.0f", ASTRO.x, ASTRO.y))
check("no surface, no reveal", gm.loading == true)
surface = true
run(1, gm)
check("the moment the surface answers, loading ends", gm.loading == false)
check("...and physics resumes", pauses[#pauses] == false)
check("...and the crew is put back where they were saved",
  math.abs(ASTRO.x - (W.x + 300)) < 1e-6 and math.abs(ASTRO.y - 745) < 1e-6)
local n_warm = #warmed
gm.update({}, 1 / 30)
check("once loaded, the warm stops (it is immediate mode: residency goes back to normal)", #warmed == n_warm)

-- ── 3. a surface that never answers trips the fallback, once ────────────────
warmed, pauses, surface, _G.time = {}, {}, false, 100
local gm2 = load("solar/scripts/game_manager.lua")
gm2.start({})
run(gm2.STALL_FREE - 1, gm2)
check("before the stall limit physics stays paused", #pauses == 1 and pauses[1] == true)
run(5, gm2)
local unpaused = 0
for _, p in ipairs(pauses) do if p == false then unpaused = unpaused + 1 end end
check("past it, physics is let run once", unpaused == 1, unpaused .. " unpauses")
check("...with the crew still pinned over the world, still",
  ASTRO.vx == 0 and ASTRO.vy == 0 and ASTRO.vz == 0 and math.abs(ASTRO.y - (W.radius + 60)) < 1e-6)
check("...and it says so", (function()
  for _, p in ipairs(printed) do if p:find("has not answered") then return true end end
end)())
surface = true
run(1, gm2)
check("the world arriving after the fallback still ends the screen", gm2.loading == false)

-- ── 4. loadGate ──────────────────────────────────────────────────────────────
check("gate: nothing yet → wait", gm.loadGate(3, nil, 800) == "wait")
check("gate: the first second always waits", gm.loadGate(0.5, 0.1, 800) == "wait")
check("gate: a far answer (another body's field) is not the surface", gm.loadGate(5, 900, 800) == "wait")
check("gate: the surface answers → ready", gm.loadGate(5, -0.3, 800) == "ready")
check("gate: still nothing past the limit → stalled", gm.loadGate(gm.STALL_FREE + 1, nil, 800) == "stalled")
check("gate: the surface wins over a stall", gm.loadGate(gm.STALL_FREE + 1, 0.1, 800) == "ready")
check("gate: a world still streaming in is not a stall", gm.loadGate(gm.STALL_FREE + 30, nil, 800, true) == "wait")

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  io.write(string.format("RELOAD SMOKE OK — %d checks passed\n", #checks))
  os.exit(0)
end
io.write("RELOAD SMOKE FAILURES:\n")
for _, b in ipairs(bad) do io.write(b .. "\n") end
for _, p in ipairs(printed) do io.write("  " .. p .. "\n") end
os.exit(1)
