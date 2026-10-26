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
-- vec3, enough of it for the walker's swim (it reads its facing in the water).
local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
function V.__add(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
function V.__sub(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function V.__mul(a, b)
  if type(b) == "number" then return vec3(a.x * b, a.y * b, a.z * b) end
  return vec3(a * b.x, a * b.y, a * b.z)
end
function V:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:length() return math.sqrt(self:dot(self)) end
function V:normalized()
  local l = self:length()
  return l < 1e-9 and vec3(0, 0, 0) or vec3(self.x / l, self.y / l, self.z / l)
end
function V:cross(o)
  return vec3(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
end
API.vec3 = vec3
-- Ground under the crew, unless section 8 puts them out of their depth.
local seabed = true
-- The hit is the ground a metre under the crew: what the walker's probe finds,
-- and in laser reach, so the aim ring has something to sit on.
API.raycast = function()
  if not seabed then return nil end
  local a = API.find and API.find("Astronaut")
  if not a then return { x = 0, y = 0, z = 0, distance = 1.0 } end
  return { x = a.x, y = a.y - 1.0, z = a.z, nx = 0, ny = 1, nz = 0, distance = 1.0 }
end
API.audio = { play = function() return { stop = function() end, setVolume = function() end,
                                         setPitch = function() end } end }
API.terrain = { query = function() return 0.5 end, dig = function() end,
                paint = function() end, warm = function() end }
-- The aim mark is a particle effect on a pooled node (prefabs/FxAimMark) that
-- the belt plays while it shows and stops when it does not; `rings` counts
-- the frames it was placed, so a test can ask.
local rings = 0
local PS = {}   -- prefab → its particle handle stub
local function particles_of(prefab)
  local ps = PS[prefab]
  if not ps then
    ps = { on = false }
    function ps:play() self.on = true end
    function ps:stop() self.on = false end
    function ps:isPlaying() return self.on end
    function ps:setIntensity() if self.on and prefab == "FxAimMark" then rings = rings + 1 end end
    function ps:setBeamEnd() end
    function ps:setTint() end
    PS[prefab] = ps
  end
  return ps
end
API.draw = { line = function() end, ring = function() end, sphere = function() end, disc = function() end,
             rect = function() end, circle = function() end, circleOutline = function() end, text = function() end }
API.spawnEffect = function() end
API.destroy = function() end
API.physics = { pause = function() end }
-- The belt and the status chips are described with `ui.make`; what they say is
-- read back from their published text (`hudText`, `line`), so the tree itself
-- is not kept.
local MADE = {}
API.ui = { make = function(n, tree) MADE[n] = tree end }

local KEYS = {}
API.input = {
  key = function(k) return KEYS[k] == true end,
  pressed = function(k) return KEYS["!" .. k] == true end,
  button = function(b) return b == 0 and KEYS.lmb == true end,
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
-- Its frame (unturned) — the walker reads the body's facing in the water.
function ASTRO:toWorld(v) return vec3(self.x + v.x, self.y + v.y, self.z + v.z) end
function ASTRO:toLocal(v) return vec3(v.x - self.x, v.y - self.y, v.z - self.z) end
-- The animated model the third-person tools are held in (no animator here, so
-- the hold itself stands down; what is under test is which tool shows).
local ASTROMODEL = make_node("AstroModel")
ASTRO.children = function() return { ASTROMODEL } end
local TOOLHUD = make_node("Tool HUD")
-- The tool in the astronaut's hand (scenes/system.ron: bone-attached to
-- Hand.Right). Authored visible, so anything that skips the holster leaves it out.
local LASER = make_node("Laser Tool")
local NODES = { Astronaut = ASTRO, ["Tool HUD"] = TOOLHUD, ["Laser Tool"] = LASER }
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
local GEAR = { gravgun = 1, laser = 1, beacon = 0 }
envs.inventory = { valid = true, add = function() return 0 end,
                   gearCount = function(_, id) return GEAR[id] or 0 end,
                   ensureKit = function() end,
                   countOf = function() return 0 end,
                   mass = function() return pack_kg end,
                   cap = function() return 90.0 end,
                   line = function() return "pack empty" end }
envs.company = { valid = true, balance = function() return 12450 end,
                 rep = function() return 3 end,
                 money = function(v) return "$" .. tostring(math.floor(v)) end }
envs.game_manager = { valid = true, loading = false }
local sea_depth = nil
envs.climate = { valid = true, seaDepth = function() return sea_depth end,
                 worldOf = function() return { kind = "rock", seed = 1, radius = BODY.radius } end }
-- The camera publishes the view basis the belt aims with; without it the belt
-- bails before it ever gets to the gate, which would make every check below
-- pass for the wrong reason.
envs.planet_camera = { valid = true,
  cam_x = BODY.x, cam_y = BODY.y + BODY.radius + 2, cam_z = BODY.z,
  fwd_x = 0, fwd_y = -1, fwd_z = 0,
  flat_x = 1, flat_y = 0, flat_z = 0 }

-- Prefab spawns land at once (the held tools are spawned on first use).
local SPAWNED = {}
API.spawn = function(prefab, _, cb)
  local n = make_node(prefab)
  n.parent_ = nil
  if prefab:sub(1, 2) == "Fx" then n.particles = function() return particles_of(prefab) end end
  function n:setUp() end
  function n:setParent(p) self.parent_ = p end
  function n:setAngles() end
  function n:toWorld(v) return vec3(self.x + v.x, self.y + v.y, self.z + v.z) end
  function n:hasTag() return false end
  SPAWNED[#SPAWNED + 1] = n
  NODES[prefab] = n
  if cb then cb(n) end
end
-- The held model of a tool, in the body's hands (third person: a child of the
-- AstroModel) or in front of the eye (the first-person view model).
local function held(prefab, where)
  for _, n in ipairs(SPAWNED) do
    if where == "eye" and n.name == prefab .. "FP" and n.parent_ ~= nil and n.parent_.name == "Camera" then return n end
    if where ~= "eye" and n.name == prefab and n.parent_ == ASTROMODEL then return n end
  end
end

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
    ASTRO.pos = vec3(ASTRO.x, ASTRO.y, ASTRO.z)
    walker.update(ASTRO, 1 / 60)
    belt.update(TOOLHUD, 1 / 60)
    if belt.lateUpdate then belt.lateUpdate(TOOLHUD, 1 / 60) end   -- the aim ring draws here
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
-- A full facility panel is the exception: it covers the screen and says why
-- itself, so the hotbar goes under it (it drew through the Tracking Station).
fac_open = true
tick(2)
ok(not hud_up(), "a full facility panel covers the belt's readout")
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

-- ── 8. THE BELT IS THE PACK, AND THE TOOL IN THE HAND ───────────────────────
-- No hard-coded slots: the hotbar is the gear the pack holds, tools first.
-- The tool picked is a real model in the hand; the others are put away —
-- including while the aim gates hold the belt (the loading sweep, the orbit
-- map), which used to return before the holster ran.
local function slots()
  local out = {}
  for _, b in ipairs(belt.belt()) do out[#out + 1] = b.id end
  return table.concat(out, ",")
end
ok(slots() == "gravgun,laser", "with no beacon in the pack the belt is the two tools [" .. slots() .. "]")
GEAR.beacon = 2
tick(1)
ok(slots() == "gravgun,laser,beacon", "a beacon in the pack puts it on the belt [" .. slots() .. "]")
ok(belt.hudLine():find("Relay Beacon ×2", 1, true) ~= nil, "...with how many [" .. belt.hudLine() .. "]")
KEYS["!3"] = true
tick(2)
ok(belt.toolId() == "beacon", "its number key picks it")
GEAR.beacon = 0
tick(2)
ok(belt.toolId() == "gravgun" and slots() == "gravgun,laser",
  "planting the last one takes it off the belt and the hand goes back to the gravity gun")

store["tool.id"] = "gravgun"
belt.start(TOOLHUD)
tick(3)
ok(LASER.model == "models/tools/socket.glb", "the hand node wears the socket, not the old rifle")
ok(held("ToolGravGun") and held("ToolGravGun").visible == true, "the gravity gun picked: it is in your hand")
ok(not (held("ToolLaser") and held("ToolLaser").visible), "...and the laser is not")
store["tool.id"] = "laser"
belt.start(TOOLHUD)
tick(3)
ok(held("ToolLaser") and held("ToolLaser").visible == true, "the laser picked: it is in your hand")
ok(held("ToolGravGun").visible == false, "...and the gravity gun is put away")
envs.planet_camera.cam_x = 0               -- the camera still swinging in from the sweep
tick(2)
ok(held("ToolLaser").visible == false, "...the aim gates holding the belt put it away")
envs.planet_camera.cam_x = BODY.x
VESSEL.piloting = true
tick(2)
ok(held("ToolLaser").visible == false and held("ToolGravGun").visible == false, "aboard a craft, every tool is put away")
VESSEL.piloting = false
tick(2)
ok(held("ToolLaser").visible == true, "...and back in hand on stepping out")
-- Old saves picked a slot by NUMBER: they still land on a real tool.
store["tool.id"] = nil
store["tool.equipped"] = 3                 -- the old Terrain Spade
belt.start(TOOLHUD)
tick(2)
ok(belt.toolId() == "laser", "an old save's spade slot opens on the Terrain Laser [" .. belt.toolId() .. "]")

-- In the water out of your depth: no firing, no aim ring, no beam.
KEYS.lmb = true
tick(2)
ok(belt.inUse == true and rings > 0, "on foot, the trigger fires and the aim mark is placed ["
  .. tostring(belt.inUse) .. " " .. rings .. " " .. tostring(belt.gate) .. "]")
sea_depth, seabed, ASTRO.grounded = 3.0, false, false
tick(30)
ok(walker.swimming == true, "out of their depth, the crew is swimming")
rings = 0
tick(5)
ok(belt.gate == "swimming", "swimming gates the belt, and says so [" .. tostring(belt.gate) .. "]")
ok(belt.inUse == false, "...the trigger does nothing")
ok(rings == 0 and not (PS.FxAimMark and PS.FxAimMark.on), "...no aim mark is placed")
ok(held("ToolLaser").visible == false, "...and the laser is put away")
ok(TOOLHUD.els.ui ~= nil and TOOLHUD.els.ui.visible == true and belt.hudText:find("swimming") ~= nil,
  "...while the belt still says why [" .. tostring(belt.hudText) .. "]")
sea_depth, seabed, ASTRO.grounded = nil, true, true
tick(40)
ok(walker.swimming == false and belt.gate == "in hand" and belt.inUse == true,
  "ashore again, the tools are back [" .. tostring(belt.gate) .. "]")
ok(held("ToolLaser").visible == true, "...laser in hand")
KEYS.lmb = nil
tick(2)

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

-- ── THE READOUT IS SHOWN ─────────────────────────────────────────────────────
-- The hotbar's hint line is where the belt says what it is pointed at and why
-- it refuses. It was described at the TOP of update, from a `prompt` cleared one
-- line earlier and only filled in by the firing code below — so "no target",
-- "no plant in reach" and the laser's material readout were computed every
-- frame and never once drawn. Read back the tree the HUD was actually given.
local function hint_text()
  local tree = MADE[TOOLHUD]
  local function walk(t, under)
    if type(t) ~= "table" then return nil end
    if under and t.key == "t" then return t.text end
    for _, c in ipairs(t) do
      local r = walk(c, under or (type(c) == "table" and c.key == "hint"))
      if r then return r end
    end
    return nil
  end
  return walk(tree, false)
end
KEYS["!1"] = true                  -- the gravity gun, with nothing loose in this scene
tick(200)                          -- past the "picked the gravity gun" line
ok(belt.toolId() == "gravgun" and belt.prompt ~= "" and (hint_text() or ""):find(belt.prompt, 1, true) ~= nil,
  "the gravity gun's refusal reaches the HUD [" .. tostring(hint_text()) .. " / " .. tostring(belt.prompt) .. "]")
KEYS["!2"] = true
tick(200)
ok((hint_text() or "") == belt.prompt and belt.prompt ~= "",
  "the laser's aim readout reaches the HUD [" .. tostring(hint_text()) .. "]")

-- ── 9. FIRST PERSON: A VIEW MODEL ON ITS OWN LAYER, FILMED BY ITS OWN CAMERA ──
-- In first person the tool shown is a second model, with the gloved hands
-- built in, riding the camera on the view-model render layer; a camera of its
-- own, stacked on the main one, films that layer alone (so it never pushes
-- into a wall), and the main camera leaves the layer out. Back in third
-- person the stack and the cull go, and the tool is in the body's hands.
local CAMNODE = make_node("Camera")
CAMNODE.calls = {}
function CAMNODE:setCamera(o) self.calls[#self.calls + 1] = o end
function CAMNODE:worldRight() return vec3(1, 0, 0) end
function CAMNODE:worldUp() return vec3(0, 1, 0) end
local VMCAM = nil
API.createNode = function(name, parent, cb)
  local n = make_node(name)
  n.parent_ = parent
  n.calls = {}
  function n:setCamera(o) self.calls[#self.calls + 1] = o end
  function n:setAngles() end
  if name == "ViewModel Cam" then VMCAM = n end
  if cb then cb(n) end
end
envs.planet_camera.node = CAMNODE
envs.planet_camera.firstPerson = true
KEYS["!2"] = true
tick(30)
local fpl = held("ToolLaser", "eye")
ok(fpl ~= nil and fpl.visible == true, "first person: the laser's view model is in front of the eye")
ok(fpl and fpl.layer == "viewmodel", "...on the view-model layer [" .. tostring(fpl and fpl.layer) .. "]")
ok(held("ToolLaser").visible == false, "...and the third-person laser is not drawn")
ok(VMCAM ~= nil and VMCAM.parent_ == CAMNODE and VMCAM.calls[1] and VMCAM.calls[1].cullMask == 8
  and VMCAM.calls[1].fovY and VMCAM.calls[1].fovY < 1.15,
  "a view-model camera rides the main one, filming only that layer, with a narrower lens")
local last = CAMNODE.calls[#CAMNODE.calls]
ok(last and last.stack and last.stack[1] == "ViewModel Cam" and last.cullMask == 4294967295 - 8,
  "...stacked on the main camera, which leaves the layer out")
envs.planet_camera.firstPerson = false
tick(30)
last = CAMNODE.calls[#CAMNODE.calls]
ok(last and last.stack and #last.stack == 0 and last.cullMask == 4294967295,
  "third person again: no stack, nothing culled")
ok(held("ToolLaser").visible == true and fpl.visible == false, "...and the laser is back in the body's hands")
-- The layer's bit is its place in project.ron's list, after the implicit
-- Default at 0: tool_belt's VM_LAYERS must agree with the file.
do
  local f = io.open("solar/project.ron") or io.open("project.ron")
  local txt = f and f:read("*a") or ""
  if f then f:close() end
  local list = txt:match("layers:%s*%[(.-)%]") or ""
  local names = { "Default" }
  for n in list:gmatch('"([^"]+)"') do names[#names + 1] = n end
  local idx = {}
  for i, n in ipairs(names) do idx[n] = i - 1 end
  ok(idx.viewmodel == 3 or (idx.viewmodel == nil and idx.entity == 1),
    "the view-model layer's bit matches project.ron [" .. table.concat(names, ",") .. "]")
end

if #failures == 0 then
  print("TOOL GATE SMOKE OK — " .. checks .. " checks passed")
  os.exit(0)
end
print("TOOL GATE SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  \xe2\x9c\x97 " .. f) end
os.exit(1)
