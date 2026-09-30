-- SMOKE HARNESS for THE TOOL GATE — "can the crew use their tools right now?"
--
-- Reported twice, the second time after everything else had been fixed: *"i
-- still wasnt able to use my tools after launching and landing and exiting my
-- pod."*
--
-- That question is answered by two scripts talking to each other, and nothing
-- tested the pair. `planet_walker` publishes `onFoot`; `tool_belt` reads it,
-- plus the three panels that own the keys when they are up. Every existing
-- harness that touches the belt stubs the walker as `{ onFoot = true }` — so
-- the belt's half is covered, the walker's half is covered nowhere, and the
-- handoff between them is exactly where a launch leaves its mark.
--
-- What this drives is the WHOLE round trip, because that is the reported bug:
-- standing at the base → the builder's hand-off flag → in the pod → landed →
-- out of the pod → tools back. Plus the panel gates, which can each strand the
-- belt on their own.
--
--   luajit solar/tests/smoke_toolgate.lua

local T = 0.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── stub engine ─────────────────────────────────────────────────────────────
local API = {}
local store = {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             slot = function() return "slot1" end }
local LOGS = {}
API.log = function(m) LOGS[#LOGS + 1] = tostring(m) end
API.print = API.log
local function logged(pat, from)
  for i = (from or 1), #LOGS do
    if LOGS[i]:find(pat, 1, true) then return true end
  end
  return false
end

local BODY = { name = "Golil", x = 3000, y = 0, z = 0, radius = 200 }
API.space = { dominant = function() return BODY.name end,
              body = function(n) return n == BODY.name and BODY or nil end,
              bodies = function() return { BODY } end }
API.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
API.raycast = function() return { x = 0, y = 0, z = 0, distance = 1.0 } end
API.audio = { play = function() return { stop = function() end, setVolume = function() end,
                                         setPitch = function() end } end }
API.terrain = { query = function() return 0.5 end, dig = function() end,
                paint = function() end, warm = function() end }
API.draw = { line = function() end, ring = function() end, sphere = function() end }
API.spawnEffect = function() end
API.destroy = function() end
API.physics = { pause = function() end }
-- The belt and the status chips are described with `ui.make`; what they say is
-- read back from their published text (`hudText`, `line`), so the tree itself
-- is not kept.
API.ui = { make = function() end }

local KEYS = {}
API.input = {
  key = function(k) return KEYS[k] == true end,
  pressed = function(k) return KEYS["!" .. k] == true end,
  button = function() return false end,
  aimYaw = function() return 0.0 end,
  mouse = function() return 0, 0 end,
  setMouseLocked = function() end,
}

-- The engine's math extensions the scripts lean on.
local mathx = setmetatable({
  clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
  lerp = function(a, b, t) return a + (b - a) * t end,
  saturate = function(v) return math.max(0, math.min(1, v)) end,
  approach = function(a, b) return b end,
  smoothstep = function(_, _, t) return t end,
  fbm = function() return 0.3 end,
  atan2 = math.atan2 or math.atan,
}, { __index = math })

-- ── nodes ───────────────────────────────────────────────────────────────────
local function make_node(name)
  local els = {}
  return {
    name = name, valid = true, visible = true, text = "",
    x = BODY.x, y = BODY.y + BODY.radius, z = BODY.z,
    vx = 0, vy = 0, vz = 0, up_x = 0, up_y = 1, up_z = 0, grounded = true,
    yaw = 0, pitch = 0, roll = 0,
    els = els,
    children = function() return {} end,
    getcomponent = function(self, kind)
      if kind == "UiElement" then
        els.ui = els.ui or { visible = false }
        return els.ui
      end
      if kind == "RigidBody" then
        els.rb = els.rb or { friction = 0 }
        return els.rb
      end
      return nil
    end,
    animator = function() return nil end,
    setShaderParam = function() end,
    particles = function() return nil end,
  }
end

local ASTRO = make_node("Astronaut")
local TOOLHUD = make_node("Tool HUD")
local NODES = { Astronaut = ASTRO, ["Tool HUD"] = TOOLHUD }
API.find = function(n) return NODES[n] end

-- ── the vessel, as `planet_walker` sees it ──────────────────────────────────
-- Only the field that matters: whether it is currently flying the crew.
local VESSEL = { piloting = false, node = make_node("Vessel") }

-- ── script loading ──────────────────────────────────────────────────────────
local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    if k == "math" then return mathx end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end
API.findScript = function(k) return envs[k] end
API.findScripts = function(k)
  if k == "vessel_controller" then return { VESSEL } end
  return envs[k] and { envs[k] } or {}
end

-- The panels that own the keys while they are up. Stubbed to their published
-- contract, because what is under test is the BELT's reaction to them.
local fac_open, ops_open = false, false
envs.facility_menu = { valid = true, isOpen = function() return fac_open end }
envs.ops_board = { valid = true, isOpen = function() return ops_open end,
                   closeBoard = function() ops_open = false end }
envs.inventory_panel = { valid = true, open = false }
local pack_kg = 0.0
envs.inventory = { valid = true, add = function() return 0 end,
                   countOf = function() return 0 end,
                   mass = function() return pack_kg end,
                   cap = function() return 90.0 end,
                   line = function() return "pack empty" end }
envs.company = { valid = true, balance = function() return 12450 end,
                 rep = function() return 3 end,
                 money = function(v) return "$" .. tostring(math.floor(v)) end }
envs.game_manager = { valid = true, loading = false }
envs.climate = { valid = true, seaDepth = function() return nil end,
                 worldOf = function() return { kind = "rock", seed = 1, radius = BODY.radius } end }
-- The camera publishes the view basis the belt aims with; without it the belt
-- bails before it ever gets to the gate, which would make every check below
-- pass for the wrong reason.
envs.planet_camera = { valid = true,
  cam_x = BODY.x, cam_y = BODY.y + BODY.radius + 2, cam_z = BODY.z,
  fwd_x = 0, fwd_y = -1, fwd_z = 0,
  flat_x = 1, flat_y = 0, flat_z = 0 }

local walker = load_script("solar/scripts/planet_walker.lua", "planet_walker")
local belt = load_script("solar/scripts/tool_belt.lua", "tool_belt")
-- The top-left readout rides along here because it answers the same question
-- the belt does — is the crew on their feet — from the same publisher.
local STATUS = make_node("Status HUD")
local status = load_script("solar/scripts/status_hud.lua", "status_hud")
walker.start(ASTRO)
belt.start(TOOLHUD)
status.start(STATUS)

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + 1 / 60
    walker.update(ASTRO, 1 / 60)
    belt.update(TOOLHUD, 1 / 60)
    status.update(STATUS, 1 / 60)
    for k in pairs(KEYS) do if k:sub(1, 1) == "!" then KEYS[k] = nil end end
  end
end

-- The belt's own published answer: it shows its HUD exactly when the tools are
-- live, and hides it otherwise. Reading that is reading the gate.
-- ARE THE TOOLS IN HAND? The HUD's visibility is no longer the answer: it stays
-- up while the belt is gated so it can say WHY, because a player whose tools had
-- been taken used to get no tools, no belt and no reason — and the belt is the
-- only place the game ever mentions that a harvester and a spade exist. The
-- belt's own published verdict is the answer.
local function tools_live()
  return belt.gate == "in hand"
end

-- Is the belt telling the player anything at all?
local function hud_up()
  return TOOLHUD.els.ui ~= nil and TOOLHUD.els.ui.visible == true
end

-- ── 1. standing at the base, nothing flying ─────────────────────────────────
tick(2)
ok(walker.onFoot == true, "on foot with nothing flying")
ok(tools_live(), "…and the tools are live")

-- ── 2. THE BUILDER HAND-OFF ─────────────────────────────────────────────────
-- `builder.lua` sets `shipyard.pilot = 1` on LAUNCH, meaning "the crew starts
-- in the pod, not standing beside the rocket". The walker parks itself on it so
-- the crew cannot walk around during the hand-off.
store["shipyard.pilot"] = 1
tick(2)
ok(walker.onFoot == false, "the builder hand-off parks the walker")
ok(not tools_live(), "…and the tools go away with it")

-- ── 3. IN THE POD ───────────────────────────────────────────────────────────
-- `vessel_controller.start` clears the hand-off flag as it boards the crew.
-- Whether the flag is cleared is the thing: a hand-off flag that survives its
-- own hand-off parks the walker for the rest of the session, and the crew never
-- gets their tools back however far they walk.
store["shipyard.pilot"] = 0
VESSEL.piloting = true
tick(2)
ok(walker.onFoot == false, "flying a craft parks the walker")
ok(not tools_live(), "…and the tools stay away in flight")

-- ── 4. LANDED, AND OUT OF THE POD ───────────────────────────────────────────
-- THE REPORTED BUG. F stands the crew down: `piloting` goes false and nothing
-- else about the world changes. The tools must come back.
VESSEL.piloting = false
tick(2)
ok(walker.onFoot == true, "stepping out of the pod puts the crew back on foot")
ok(tools_live(), "…and the tools work again after a launch, a landing and an EVA")

-- 4b. And they survive the craft being cleaned up underneath them — a recovered
-- or destroyed vessel leaves a script instance behind for a frame, and a stale
-- `piloting` on it would park the walker forever.
VESSEL.node.valid = false
tick(2)
ok(walker.onFoot == true, "a craft that no longer exists does not hold the crew hostage")
ok(tools_live(), "…tools still live")
VESSEL.node.valid = true

-- ── 5. THE PANELS THAT OWN THE KEYS ─────────────────────────────────────────
-- Each of these can strand the belt on its own, and each is a separate script's
-- flag — so each is a separate way to end up unable to mine with no clue why.
fac_open = true
tick(2)
ok(not tools_live(), "a facility panel takes the tools")
fac_open = false
tick(2)
ok(tools_live(), "…and gives them back when it closes")

ops_open = true
tick(2)
ok(not tools_live(), "the ops board takes the tools")
ops_open = false
tick(2)
ok(tools_live(), "…and gives them back")

envs.inventory_panel.open = true
tick(2)
ok(not tools_live(), "the suit pack takes the tools")
envs.inventory_panel.open = false
tick(2)
ok(tools_live(), "…and gives them back")

-- ── 5b. AND IT SAYS SO, ON SCREEN ───────────────────────────────────────────
-- Every gate above is a way to end up unable to mine. The Console line that
-- names them is not on screen, and the HUD used to hide itself along with the
-- belt — the least informative of the three possible screens.
fac_open = true
tick(2)
ok(hud_up(), "the belt's readout stays up while a panel holds the keys")
ok(belt.hudText:find("stowed") ~= nil, "…and says the tools are stowed [" .. belt.hudText .. "]")
ok(belt.hudText:find("facility panel") ~= nil, "…and names what is holding them")
fac_open = false
tick(2)
ok(belt.hudText:find("stowed") == nil, "…and goes back to the belt when it clears")

-- ── 6. LOADING ──────────────────────────────────────────────────────────────
-- While the world streams in the crew is parked in the sky over the spawn
-- planet, not standing anywhere they could point a laser at.
envs.game_manager.loading = true
tick(2)
ok(walker.onFoot == false, "the crew is not on foot while the world loads")
envs.game_manager.loading = false
tick(2)
ok(tools_live(), "…and is again once it is up")

-- ── 7. THE SILENT ONE ───────────────────────────────────────────────────────
-- Every gate above hides the HUD, so at least the game LOOKS unarmed. This one
-- did not: the HUD is written before the aim is resolved, so a camera that had
-- stood down (the orbit map owns it while open) or never started following
-- anyone left the belt looking completely ready and doing nothing at all when
-- you pulled the trigger.
--
-- It cannot be caught by asking whether the camera published a view, either:
-- `planet_camera` declares `cam_x = 0` and `fwd_z = -1` at load, which are
-- perfectly non-nil and aim from the middle of the solar system. The question
-- is whether the eye is anywhere near the crew.
local n_logs = #LOGS
envs.planet_camera.cam_x = 0
envs.planet_camera.cam_y = 0
envs.planet_camera.cam_z = 0
tick(2)
ok(logged("following something else", n_logs),
  "a camera that is not on the crew is reported, not silently obeyed")

n_logs = #LOGS
envs.planet_camera.cam_x = BODY.x
envs.planet_camera.cam_y = BODY.y + BODY.radius + 2
envs.planet_camera.cam_z = BODY.z
tick(2)
ok(tools_live(), "…and the belt recovers when the camera comes back")

-- 7b. Every OTHER refusal says which one it was. Four causes, one symptom —
-- "I can't use my tools" — and no way to tell them apart from inside the game
-- was most of why this took three reports to pin down.
local function refuses_with(setup, teardown, pat)
  local mark = #LOGS
  setup()
  tick(2)
  local said = logged(pat, mark)
  teardown()
  tick(2)
  return said
end
ok(refuses_with(function() fac_open = true end, function() fac_open = false end,
  "facility panel"), "a facility panel says so")
ok(refuses_with(function() ops_open = true end, function() ops_open = false end,
  "ops board"), "the ops board says so")
ok(refuses_with(function() envs.inventory_panel.open = true end,
  function() envs.inventory_panel.open = false end,
  "suit pack"), "the suit pack says so")
ok(refuses_with(function() VESSEL.piloting = true end,
  function() VESSEL.piloting = false end,
  "aboard a craft"), "being aboard says so")

-- ── THE NUMBERS YOU ARE PLAYING FOR ─────────────────────────────────────────
-- Balance, standing and pack lived inside two buildings — the Ops Board and the
-- Commerce Depot — so you could mine for five minutes, walk back with a full
-- pack, and have watched no number change. They are top-left now, on foot.
tick(2)
ok(STATUS.els.ui ~= nil and STATUS.els.ui.visible == true,
  "the status line is up while the crew is on their feet")
ok(status.line:find("12450") ~= nil, "it shows the balance [" .. status.line .. "]")
ok(status.line:find("rep %+3") ~= nil, "...and standing")
ok(status.line:find("90") ~= nil, "...and how much the pack holds")

-- FULL is the one pack state that reads as a broken tool: you keep firing, rock
-- keeps coming off, and nothing arrives. It has to say so where you are looking.
pack_kg = 90.0
tick(2)
ok(status.line:find("PACK FULL") ~= nil, "a full pack says so [" .. status.line .. "]")
ok(status.line:find("Commerce Depot") ~= nil, "...and where to take it")
pack_kg = 0.0

VESSEL.piloting = true
tick(2)
ok(STATUS.els.ui.visible == false,
  "it stands down while flying — that corner is the flight HUD's")
VESSEL.piloting = false
tick(2)
ok(STATUS.els.ui.visible == true, "...and comes back when you get out")

if #failures == 0 then
  print("TOOL GATE SMOKE OK — " .. checks .. " checks passed")
  os.exit(0)
end
print("TOOL GATE SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  \xe2\x9c\x97 " .. f) end
os.exit(1)
