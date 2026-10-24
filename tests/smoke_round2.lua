-- ROUND-TWO SMOKE: the real builder.lua and electronics.lua against the same
-- stubbed engine as smoke_builder (copied, so each test stands alone):
-- structure, rovers, robotics, fairings, the claw and the drill — catalogue,
-- surface attach, mirror symmetry, rover axles, motor rating, fairing shells,
-- actuator actions, and that every new part has its prefab and meshes.
--
-- (The original header follows.) SMOKE HARNESS: runs the real builder.lua against a stubbed engine API and
-- drives the SYMMETRY feature end-to-end — pick, free-place, stack-snap,
-- ×4 radial ring, auto-mirrored stacking, ring scrap, undo. Any Lua error in
-- the builder fails loudly with a traceback; the assertions catch geometry
-- regressions (the ring math is easy to break silently).
--
--   luajit solar/tests/smoke_builder.lua
--
-- The stub camera projects orthographically (screen = world × 100 + 500), so
-- "moving the mouse onto an attach node" is just projecting the node's world
-- position — the same math find_snap uses to capture the ghost.

local T = 0.0
local TICK = 1 / 60

-- ── nodes ────────────────────────────────────────────────────────────────────
local nodes = {}
local next_id = 1
local function make_node(name, x, y, z)
  local n = { __id = next_id, id = next_id, name = name, valid = true,
              visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {},
              ui_rect = nil }
  n.getcomponent = function(self, kind) return self.components[kind] end
  -- node:uiRect() → x,y,w,h physical px (0,0,0,0 when it has no rect). The
  -- StagePanel gets a real rect so the panel hit-test can be exercised.
  n.uiRect = function(self)
    local r = self.ui_rect
    if not r then return 0, 0, 0, 0 end
    return r[1], r[2], r[3], r[4]
  end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end

-- ── stub API ─────────────────────────────────────────────────────────────────
local API = {}
local save_store = {}

function API.vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function API.destroy(n) n.valid = false end
function API.find(name)
  for _, n in ipairs(nodes) do
    if n.valid and n.name == name then return n end
  end
  return nil
end
API.print = function() end
API.log = API.print

-- Spawns land SYNCHRONOUSLY (the builder tolerates async; sync keeps the
-- test linear).
function API.spawn(prefab, pos, cb)
  local n = make_node(prefab, pos.x, pos.y, pos.z)
  if cb then cb(n) end
end

API.KEYS = { down = {}, edge = {} }
local MOUSE = { x = 500, y = 500, lmb = false }
API.input = {
  key = function(k) return API.KEYS.down[k] or false end,
  pressed = function(k) return API.KEYS.edge[k] or false end,
  button = function(b) return b == 0 and MOUSE.lmb or false end,
  mouse = function() return MOUSE.x, MOUSE.y end,
  mouse_delta = function() return 0, 0 end,
  scroll = function() return 0 end,
  setMouseLocked = function() end,
}

-- Orthographic-ish camera: screen = world × 100 + 500 (Y flipped), and the
-- cursor ray drops straight down at the un-projected XZ.
API.camera = {
  worldToScreen = function(x, y, z)
    return x * 100 + 500 + z * 3, -y * 100 + 500 + z * 3, 1.0, true
  end,
  screenSize = function() return 1920, 1080 end,
  screenToRay = function(mx, my)
    return (mx - 500) / 100, 10.0, 0.0, 0.0, -1.0, 0.0
  end,
}

-- Raycast returns nothing — the builder's part_under_cursor then falls back
-- to the nearest projected part center, which the ortho camera resolves
-- exactly (worldToScreen carries z), so aiming the mouse at a part's
-- projected center selects it.
API.RAY = nil   -- set by the surface-attach checks: function(...) → hit
function API.raycast(...) if API.RAY then return API.RAY(...) end return nil end
API.draw = {
  line = function() end, ring = function() end,
  sphere = function() end, box = function() end,
  cone = function() end, disc = function() end, tri = function() end,
}
API.save = {
  get = function(k) return save_store[k] end,
  set = function(k, v) save_store[k] = v end,
  flush = function() end,
}
API.scene = { load = function() end }

-- Cross-script handles. The builder asks for the COMPANY ledger (it prices the
-- build against the balance and charges at rollout); a scene without one must
-- degrade to "no money system", which is exactly what a nil handle means.
-- `API.COMPANY` is set by the money tests below to wire a real one in.
-- The part registry (scripts/parts_registry.lua) is its own pure script now,
-- reached with findScript("parts_registry"): load it from disk.
local REGENV = setmetatable({}, { __index = _G })
do
  local rc = assert(loadfile("solar/scripts/parts_registry.lua"))
  setfenv(rc, REGENV)
  rc()
end
API.COMPANY = nil
function API.findScript(kind)
  if kind == "company" then return API.COMPANY end
  if kind == "electronics" then return API.ELEC end
  if kind == "parts_registry" then return REGENV end
  return nil
end
function API.findScripts(kind)
  local h = API.findScript(kind)
  return h and { h } or {}
end

-- Audio: the builder plays UI clicks + a hangar bed; hand back a handle with
-- the SoundHandle surface (stop() is used on the bed) so it all no-ops here.
API.SOUNDS = {}
API.audio = {
  play = function(clip)
    API.SOUNDS[#API.SOUNDS + 1] = clip
    return {
      stop = function() end, pause = function() end, resume = function() end,
      setVolume = function() end, setPitch = function() end, setPan = function() end,
      setTrack = function() end, setPosition = function() end, seek = function() end,
      isPlaying = function() return true end, position = function() return 0.0 end,
    }
  end,
  track = function()
    return { setVolume = function() end, setPan = function() end,
      setMuted = function() end, setSoloed = function() end }
  end,
  stopAll = function() end,
}

-- The electronics rulebook, loaded for real (the builder asks it for modules).
do
  local eenv = setmetatable({}, { __index = _G })
  local ec = assert(loadfile("solar/scripts/electronics.lua"))
  setfenv(ec, eenv)
  ec()
  eenv.valid = true
  API.ELEC = eenv
end

-- ── load the builder ─────────────────────────────────────────────────────────
local stats_n = make_node("BuildStats", 0, 0, 0)
make_node("BuildHint", 0, 0, 0)
local stage_panel = make_node("StagePanel", 0, 0, 0)
stage_panel.components["UiElement"] = { visible = false }
-- The panel's solved screen rect (physical px) — what node:uiRect() returns.
stage_panel.ui_rect = { 16, 200, 256, 384 }
-- STAGING is now a POOL of per-row nodes (each with its OWN solved rect) plus a
-- floating drag ghost — the builder hit-tests each row's real uiRect instead of
-- guessing a pitch off the whole panel. Lay 14 rows under a 34px title + 10 pad,
-- 24px tall on a 27px pitch (matches builder.ron's stack), x = panel + 10 pad.
local STAGE_ROW_TOP = 200 + 10 + 34 + 3
for k = 1, 14 do
  local rn = make_node(string.format("StageRow%02d", k), 0, 0, 0)
  rn.components["UiElement"] = { visible = false }
  rn.ui_rect = { 26, STAGE_ROW_TOP + (k - 1) * 27, 232, 24 }
end
local stage_ghost = make_node("StageDragGhost", 0, 0, 0)
stage_ghost.components["UiElement"] = { visible = false }
local function stage_row_center(k) return STAGE_ROW_TOP + (k - 1) * 27 + 12 end

local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end

local builder_node = make_node("Builder", 0, 0, 0)
env.start(builder_node)

local failures = {}
local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end

local function step(n)
  for _ = 1, n or 1 do
    T = T + TICK
    local ok, err = xpcall(env.update, debug.traceback, builder_node, TICK)
    if not ok then failures[#failures + 1] = "update: " .. err end
    API.KEYS.edge = {}
  end
end

local function press(k) API.KEYS.edge[k] = true end
local function mouse_to_world(x, y, z)
  local sx, sy = API.camera.worldToScreen(x, y, z)
  MOUSE.x, MOUSE.y = sx, sy
end
local function click()
  MOUSE.lmb = true
  step(1)
  MOUSE.lmb = false
  step(14) -- let the click cooldown lapse
end

-- The builder's internal registry, read back through the saved blueprint.
local function saved_parts()
  env.doSave()
  local bp = save_store["shipyard.blueprint"]
  local out = {}
  for _, d in pairs(bp.parts) do out[#out + 1] = d end
  return out
end


-- ── scenario ─────────────────────────────────────────────────────────────────
step(2)
local E = API.ELEC

local function node_of(name)
  for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end
end
local function all_of(name)
  local out = {}
  for _, n in ipairs(nodes) do if n.valid and n.name == name then out[#out + 1] = n end end
  return out
end
local function file_exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

-- 1. THE CATALOGUE carries every round-two part, each with a prefab on disk
--    and the meshes that prefab names.
do
  local listed = {}
  for _, sec in ipairs(env.catalogue()) do for _, id in ipairs(sec.ids) do listed[id] = sec.title end end
  for _, id in ipairs({ "strut1", "strut2", "strut3", "beam1", "beam2", "ibeam2", "ibeam3", "panel1", "panel2",
                        "panel3", "plate", "hub", "adapter", "roverBody", "wheelS", "wheelM", "wheelL",
                        "fairingS", "fairingM", "hinge", "piston", "rotor", "claw", "drill" }) do
    local def = env.partInfo(id)
    check(def ~= nil and listed[id] ~= nil, "catalogue lists " .. id)
    if def then
      check(def.desc ~= nil, id .. " says what it is for")
      check((def.strength or 0) > 0 and (def.mass or 0) > 0 and (def.cost or 0) > 0, id .. " has mass, cost and strength")
      local pf = "solar/prefabs/" .. def.prefab .. ".prefab.ron"
      check(file_exists(pf), "prefab on disk: " .. pf)
      local f = io.open(pf, "r")
      if f then
        local txt = f:read("*a"); f:close()
        for glb in txt:gmatch('asset_path: "([^"]+)"') do
          check(file_exists("solar/" .. glb), id .. " mesh on disk: " .. glb)
        end
      end
    end
  end
  for _, sz in ipairs({ "S", "M", "L" }) do
    check(file_exists("solar/prefabs/WheelTyre" .. sz .. ".prefab.ron"), "live tyre prefab " .. sz)
  end
  check(file_exists("solar/prefabs/FairingHalf.prefab.ron"), "fairing half debris prefab")
  -- light and cheap: a 1 m strut is a hundredth of a tank
  check(env.partInfo("strut1").mass < 0.02 and env.partInfo("strut1").cost <= 20, "struts are light and cheap")
end

-- 2. ELECTRONICS: the actuators, wheels, claw, drill and fairing act.
do
  local hinge = { uid = 1, mods = { { type = "hinge", torque = 3, rate = 30 } } }
  local inc = E.actionOf(hinge, "angle.inc")
  check(inc and inc.rate == 30 and inc.max == 90, "hinge angle.inc carries its rate and travel")
  local st = E.stateOf(hinge)
  E.applyAction(st, inc, nil, 200)
  check(st.angle == 90, "a hinge setpoint stops at its +90° limit (got " .. tostring(st.angle) .. ")")
  E.applyAction(st, E.actionOf(hinge, "angle.center"))
  check(st.angle == 0, "angle.center returns it to 0")
  check(st.speed == 100, "a hinge starts at full speed (speed setting 100 %)")
  local piston = { uid = 2, mods = { { type = "piston" } } }
  check(E.actionOf(piston, "extended.on") and E.actionOf(piston, "extended.on").label == "Extend", "piston Extend")
  check(E.actionOf(piston, "extended.off").label == "Retract", "piston Retract")
  check(E.actionOf({ uid = 3, mods = { { type = "rotor" } } }, "spin.toggle") ~= nil, "rotor motor on/off")
  check(E.stateOf({ uid = 3, mods = { { type = "rotor" } } }).rpm == 20, "a rotor starts at 20 rpm")
  local wheel = { uid = 4, mods = { { type = "drive", draw = 0.25 } } }
  check(E.actionOf(wheel, "brakes.toggle") ~= nil, "wheel brakes action")
  local g = E.defaultGroups({ [4] = wheel })
  check(E.isBound(g, "brakes", 4, "brakes.toggle"), "wheel brakes are on the Brakes group (B) by default")
  check(E.actionOf({ uid = 5, mods = { { type = "claw" } } }, "armed.on").label == "Arm claw", "claw arm")
  check(E.actionOf({ uid = 5, mods = { { type = "claw" } } }, "release").kind == "trigger", "claw release")
  check(E.actionOf({ uid = 6, mods = { { type = "drill" } } }, "drilling.on") ~= nil, "drill start")
  check(E.actionOf({ uid = 7, mods = { { type = "fairing" } } }, "jettison").kind == "trigger", "fairing jettison")
  for _, ty in ipairs({ "hinge", "piston", "rotor", "drill", "drive" }) do
    check(not E.MODULES[ty].future, ty .. " is no longer marked future")
  end
  local s = E.summary({ [4] = wheel })
  check(math.abs((s.motors or 0) - 0.25) < 1e-9 and s.idle == 0, "motors count at peak, not idle")
end

-- 3. FAIRING SHELL geometry: valid lists, both halves.
do
  for half = 0, 1 do
    local m = E.fairingShell(0.8, 0.1, 2.0, 0.9, half, 24)
    local nv = #m.positions / 3
    check(nv > 0 and #m.normals == #m.positions and #m.uvs / 2 == nv, "fairing shell lists line up (half " .. half .. ")")
    local ok = #m.indices % 3 == 0
    for _, i in ipairs(m.indices) do if i < 1 or i > nv then ok = false end end
    check(ok, "fairing shell indices in range (half " .. half .. ")")
    local zmin, zmax = 1e9, -1e9
    for k = 3, #m.positions, 3 do zmin = math.min(zmin, m.positions[k]); zmax = math.max(zmax, m.positions[k]) end
    if half == 0 then check(zmin > -0.01, "half 0 is the +Z half") else check(zmax < 0.01, "half 1 is the −Z half") end
  end
end

-- 4. A ROVER: body placed free, a wheel SURFACE-attached on its +Z flank
--    with MIRROR on — two wheels, a left/right pair.
env.pick("roverBody")
step(12)
mouse_to_world(0, 0.6, 0)
click()
check(env.partCount == 1, "rover body placed")
local body = node_of("PartRoverBody")
check(body ~= nil, "rover body node")
press("m"); step(1)
check(env.sym_mirror == true, "M turns mirror symmetry on")
env.pick("wheelM")
step(12)
-- the cursor over the body's +Z face, 0.5 forward of centre: the ray hits it there
local hx, hy, hz = body.x + 0.5, body.y, body.z + 0.5
API.RAY = function(ox, oy, oz, dx, dy, dz, max, ignore)
  return { x = hx, y = hy, z = hz, nx = 0, ny = 0, nz = 1, distance = 3.0, node = body }
end
-- far from every attach node on screen: aim the mouse at empty space and let
-- the surface ray answer
MOUSE.x, MOUSE.y = 1500, 1500
step(2)
click()
API.RAY = nil
local wheels = all_of("PartWheelM")
check(#wheels == 2, "mirror made a pair of wheels (got " .. #wheels .. ")")
if #wheels == 2 then
  local a, b = wheels[1], wheels[2]
  check(math.abs(a.x - b.x) < 1e-6 and math.abs(a.z + b.z - 2 * body.z) < 1e-6, "the pair mirror across the body's Z plane")
  check(math.abs(math.abs(a.z - body.z) - (0.5 + 0.2)) < 1e-3, "a wheel stands its own reach off the face (0.2 m)")
  -- radial_orient: +X outward on each side
  local ya = math.cos(a.yaw) ; local yb = math.cos(b.yaw)
  check(math.abs(ya) < 1e-6 and math.abs(yb) < 1e-6 and math.abs(math.sin(a.yaw) + math.sin(b.yaw)) < 1e-6,
    "each wheel's axle (+X) faces out of its own side")
end
press("m"); step(1)
check(env.sym_mirror == false, "M again turns it off")
do
  local bp = nil
  env.doSave(); bp = save_store["shipyard.blueprint"]
  check(bp.turned == nil, "a rover with axles on Z is not turned at rollout")
  local w
  for _, d in ipairs(bp.parts) do if d.id == "wheelM" then w = d end end
  check(w and (w.mir == "z") and (w.wheel == "M"), "the wheel record carries its mirror plane and size")
  check(w and type(w.mods) == "table" and w.mods[1].type == "drive" and math.abs(w.mods[1].torque - 0.5 * env.rating().thrust) < 1e-9,
    "the drive motor is rated for the home world like engine thrust")
  local chk = env.launchCheck()
  check(chk.block == nil, "a rover body is a command part: it may launch")
end

-- 5. FRAME: a hub, and a strut snapped onto its flank points straight out.
env.pick("hub")
step(12)
mouse_to_world(4, 0.3, 0)
API.KEYS.down.alt = true
click()
API.KEYS.down.alt = false
local hub = node_of("PartHub")
check(hub ~= nil, "hub placed free")
env.pick("strut2")
step(12)
-- the hub's +X flank node
mouse_to_world(hub.x + 0.12, hub.y, hub.z)
step(2)
click()
local strut = node_of("PartStrut2")
check(strut ~= nil, "strut placed on the hub's flank")
if strut and hub then
  -- its +Y (stack axis) points along +X, and its centre is half its length out
  local cx, sx = math.cos(strut.pitch), math.sin(strut.pitch)
  local cz, sz = math.cos(strut.roll), math.sin(strut.roll)
  local cy, sy = math.cos(strut.yaw), math.sin(strut.yaw)
  local Yx = -cy * sz + sy * sx * cz
  check(Yx > 0.99, string.format("the strut points straight out of the flank (Y·X = %.3f)", Yx))
  check(math.abs(strut.x - (hub.x + 0.12 + 1.0)) < 1e-3, "and stands its half-length off it")
end

-- 6. FAIRING: a base with a probe on top grows a shell that fits it, and the
--    payload rides inside (heat and air stay off it).
env.pick("fairingS")
step(12)
mouse_to_world(-4, 0.1, 0)
API.KEYS.down.alt = true
click()
API.KEYS.down.alt = false
local fb = node_of("PartFairingS")
env.pick("probe")
step(12)
mouse_to_world(fb.x, fb.y + 0.1, fb.z)
step(2)
click()
do
  env.doSave()
  local bp = save_store["shipyard.blueprint"]
  local f, p
  for _, d in ipairs(bp.parts) do if d.id == "fairingS" then f = d end; if d.id == "probe" then p = d end end
  check(f and (f.fr or 0) >= 0.625 and (f.fhc or 0) > 0.42 and (f.shellm or 0) > 0, "the fairing record carries its fitted shell")
  check(p and p.faired == f.uid, "the probe rides inside the fairing")
  local items = 0
  for _, d in ipairs(bp.parts) do if (d.fairing or 0) > 0 then items = items + 1 end end
  check(items == 1, "one fairing on the stand")
end

-- 7. ROVER AXLES: wheels built on the ±X flanks are turned onto Z at
--    rollout, and come back to the stand the way they were built.
do
  local bp = { parts = {
    { uid = 1, id = "roverBody", x = 0, y = 0.6, z = 0, yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0 },
    { uid = 2, id = "wheelM", x = 1.0, y = 0.4, z = 0.3, yaw = 0, pitch = 0, roll = 0, parent = 1, att = "surface", sym = 0 },
    { uid = 3, id = "wheelM", x = -1.0, y = 0.4, z = 0.3, yaw = math.pi, pitch = 0, roll = 0, parent = 1, att = "surface", sym = 0 },
  } }
  save_store["shipyard.blueprint"] = bp
  press("f5"); step(2)
  env.doSave()
  local out = save_store["shipyard.blueprint"]
  check(out.turned ~= nil, "axles along X: the rover is turned at rollout")
  for _, d in ipairs(out.parts) do
    if d.id == "wheelM" then
      local X = math.cos(d.yaw)
      check(math.abs(X) < 1e-6, "every wheel axle is on Z after the turn")
    end
  end
  press("f5"); step(2)
  local w2 = {}
  for _, n in ipairs(nodes) do if n.valid and n.name == "PartWheelM" then w2[#w2 + 1] = n end end
  local back = false
  for _, n in ipairs(w2) do if math.abs(math.abs(n.x - (env.centerX or 0)) - 1.0) < 0.6 and math.abs(math.cos(n.yaw)) > 0.99 then back = true end end
  check(back, "reloaded onto the stand, the wheels are where they were built")
end

-- ── verdict ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print("ROUND-TWO SMOKE OK — catalogue + prefabs, actuator actions, fairing shells, surface attach, mirror pairs, outward struts, rover axles, rated motors")
  os.exit(0)
else
  print("ROUND-TWO SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
