-- SMOKE HARNESS: runs the real vessel_spawner.lua + vessel_controller.lua
-- against a stubbed engine API and drives the whole launch sequence offline —
-- spawn, assemble, clamp, board, release, thrust, flames, stage, EVA,
-- re-board from the ground. Any Lua runtime error in the scripts fails loudly
-- with a traceback, and the end-state assertions catch logic regressions.
--
--   luajit solar/tests/smoke_vessel.lua
--
-- Fidelity notes (bugs this stub is shaped to catch):
--  * node.x/y/z are PARENT-LOCAL, exactly like the engine — writing a world
--    number into a parented node's coords lands it in the wrong place (the
--    round-7 far-side launchpad).
--  * The planet MOVES on rails; planet-parented nodes ride it through the
--    hierarchy, the anchored assembly rides via the carry — anything
--    positioned in stale world coords drifts and fails the proximity checks.

local T = 0.0
local TICK = 1 / 60

-- ── node registry (parent-LOCAL coordinates, like the engine) ───────────────
local nodes = {}
local next_id = 1

local function make_node(name, x, y, z, parent)
  local n = {
    __id = next_id, id = next_id, name = name, valid = true, visible = true,
    x = x or 0, y = y or 0, z = z or 0,
    pitch = 0, roll = 0, yaw = 0,
    vx = 0, vy = 0, vz = 0,
    up_x = 0, up_y = 1, up_z = 0, grounded = false,
    components = {}, kids = {}, parent = parent,
    shader_params = {}, particles_state = nil,
  }
  n.children = function(self)
    local out = {}
    for _, k in ipairs(self.kids) do out[#out + 1] = k end
    return out
  end
  n.getcomponent = function(self, kind) return self.components[kind] end
  -- Whole-rotation setters (engine 0.117, floptle/0403). setAngles writes the
  -- triple as given; setUp stands +Y on a WORLD direction (this harness has
  -- no parent rotations), the heading taken from world X as nearly as it can.
  n.setAngles = function(self, yaw, pitch, roll)
    self.yaw, self.pitch, self.roll, self.up_set = yaw, pitch, roll, nil
  end
  n.setUp = function(self, u)
    local l = math.sqrt(u.x * u.x + u.y * u.y + u.z * u.z)
    self.up_set = { x = u.x / l, y = u.y / l, z = u.z / l }
  end
  local function axes(self)
    local u = self.up_set
    if u then
      local rx, ry, rz = 1 - u.x * u.x, -u.x * u.y, -u.x * u.z
      local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
      if rl < 1e-6 then rx, ry, rz, rl = 0, -u.z, u.y, math.sqrt(u.y * u.y + u.z * u.z) end
      rx, ry, rz = rx / rl, ry / rl, rz / rl
      -- Z = X × Y
      local zx, zy, zz = ry * u.z - rz * u.y, rz * u.x - rx * u.z, rx * u.y - ry * u.x
      return { x = rx, y = ry, z = rz }, { x = u.x, y = u.y, z = u.z }, { x = zx, y = zy, z = zz }
    end
    local cy, sy = math.cos(self.yaw or 0), math.sin(self.yaw or 0)
    local cx, sx = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
    local cz, sz = math.cos(self.roll or 0), math.sin(self.roll or 0)
    return { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
           { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
           { x = sy * cx, y = -sx, z = cy * cx }
  end
  n.worldRight = function(self) local r = axes(self) return r end
  n.worldUp = function(self) local _, u = axes(self) return u end
  n.worldForward = function(self)
    local _, _, z = axes(self)
    return { x = -z.x, y = -z.y, z = -z.z }
  end
  n.setShaderParam = function(self, key, a, b, c) self.shader_params[key] = { a, b, c } end
  n.particles = function(self)
    if not self.particles_state then return nil end
    local st = self.particles_state
    return {
      isPlaying = function() return st.playing end,
      play = function() st.playing = true end,
      stop = function() st.playing = false end,
      setIntensity = function(_, v) st.intensity = v end,
    }
  end
  if parent then parent.kids[#parent.kids + 1] = n end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end

local function world_of(n)
  local x, y, z = n.x, n.y, n.z
  local p = n.parent
  while p do
    x, y, z = x + p.x, y + p.y, z + p.z
    p = p.parent
  end
  return x, y, z
end

local function find_node(name)
  for _, n in ipairs(nodes) do
    if n.valid and n.name == name then return n end
  end
  return nil
end

-- ── world state ─────────────────────────────────────────────────────────────
-- One planet on rails: it moves +X at 90 u/s. Everything must be positioned
-- relative to it or drift bugs show as proximity failures.
local planet = { name = "Golil", x = 5000, y = 0, z = 0, soi = 30000, mu = 4.9e5, radius = 220,
                 vx = 90, vy = 0, vz = 0 }
local planet_node = make_node("Golil", planet.x, planet.y, planet.z)

local save_store = {}
local logs = {}
local spawn_queue = {}
local asm = nil
local force_calls = 0
local torque_calls = 0
local split_calls = {}

-- ── stub API ────────────────────────────────────────────────────────────────
local API = {}

function API.vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function API.distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end
function API.log(msg) logs[#logs + 1] = tostring(msg) end

-- CAPTIONS (v0.33.0). The engine draws these only while the player has captions
-- on, and `caption(...)` does nothing while they are off — so the game writes
-- them beside the sound with no `if` around them. Collected here because a
-- flight is mostly told to you in sound: staging, the chutes, touchdown, the
-- hull letting go. A player with captions on and the volume down should be able
-- to fly this.
local captions = {}
function API.caption(text) captions[#captions + 1] = tostring(text) end
local function captioned(needle)
  for _, c in ipairs(captions) do if c:find(needle, 1, true) then return true end end
  return false
end
API.print = API.log
function API.find(name) return find_node(name) end
function API.destroy(n) n.valid = false end

API.KEYS = { down = {}, edge = {} }
API.input = {
  key = function(k) return API.KEYS.down[k] or false end,
  pressed = function(k) return API.KEYS.edge[k] or false end,
  button = function() return false end,
  mouse = function() return 0, 0 end,
  mouse_delta = function() return 0, 0 end,
  scroll = function() return 0 end,
  setMouseLocked = function() end,
}

API.save = {
  get = function(k) return save_store[k] end,
  set = function(k, v) save_store[k] = v end,
  flush = function() end,
  slot = function() return "slot1" end,
}

API.space = {
  time = function() return T end,
  warp = function(m) return 1 end,
  bodies = function() return { planet } end,
  body = function(name) return name == planet.name and planet or nil end,
  -- SOI-honoring, like the engine: outside the planet's sphere of influence
  -- there is NO dominant body — deep space, far outside every SOI.
  dominant = function(x, y, z)
    if not x then return planet.name end
    local dx, dy, dz = x - planet.x, y - planet.y, z - planet.z
    if dx * dx + dy * dy + dz * dz < planet.soi * planet.soi then return planet.name end
    return nil
  end,
  elements = function()
    if T < 3.0 then return nil end
    return { body = planet.name, apoapsis = 400, periapsis = 250, period = 950 }
  end,
  propagate = function(x, y, z, vx, vy, vz, mu, dt)
    return x + vx * dt, y + vy * dt, z + vz * dt, vx, vy, vz
  end,
  gravity = function(x, y, z)
    local dx, dy, dz = planet.x - x, planet.y - y, planet.z - z
    local r2 = dx * dx + dy * dy + dz * dz
    if r2 < 1 then return 0, 0, 0 end
    local r = math.sqrt(r2)
    local g = planet.mu / r2
    return dx / r * g, dy / r * g, dz / r * g
  end,
}

API.CRATERS = {}
API.SCUFFS = {}
API.terrain = { warm = function() end, query = function() return 0.1 end,
  dig = function(x, y, z, r) API.CRATERS[#API.CRATERS + 1] = { x = x, y = y, z = z, r = r } end,
  paint = function(x, y, z, r) API.SCUFFS[#API.SCUFFS + 1] = { x = x, y = y, z = z, r = r } end,
  paintTexture = function() end }
-- Line recorder: update_map3d draws the subject craft's conic in cyan
-- (0.35, 0.85, 1.0) — the map assertions look for it here. Cleared per tick.
local tick_lines = {}
API.draw = {
  ring = function() end,
  line = function(x1, y1, z1, x2, y2, z2, r, g, b, a)
    tick_lines[#tick_lines + 1] = { r = r, g = g, b = b }
  end,
  conic = function(c, e1, e2, p, ecc, segs, r, g, b)
    tick_lines[#tick_lines + 1] = { r = r, g = g, b = b }
  end,
  polyline = function(pts, r, g, b)
    tick_lines[#tick_lines + 1] = { r = r, g = g, b = b }
  end,
  sphere = function() end, box = function() end,
}
-- ignorePair (engine 0.112) is recorded: every piece that leaves the craft must
-- pass through the hull it left for a moment rather than be shoved off it.
API.IGNORED = {}
API.physics = { pause = function() end, isPaused = function() return false end,
  ignorePair = function(a, b, secs)
    API.IGNORED[#API.IGNORED + 1] = { a = a, b = b, secs = secs }
  end }

-- Audio: record every clip played so we could assert on it; hand back a handle
-- with the full SoundHandle/TrackHandle surface the real API exposes so the
-- vessel's engine/reentry/bed loops and one-shots all no-op cleanly here.
API.SOUNDS = {}
local function sound_handle()
  return {
    stop = function() end, pause = function() end, resume = function() end,
    setVolume = function() end, setPitch = function() end, setPan = function() end,
    setTrack = function() end, setPosition = function() end, seek = function() end,
    isPlaying = function() return true end, position = function() return 0.0 end,
  }
end
API.audio = {
  play = function(clip)
    API.SOUNDS[#API.SOUNDS + 1] = clip
    return sound_handle()
  end,
  track = function()
    return { setVolume = function() end, setPan = function() end,
      setMuted = function() end, setSoloed = function() end }
  end,
  stopAll = function() end,
}

function API.raycast(ox, oy, oz)
  local dx, dy, dz = ox - planet.x, oy - planet.y, oz - planet.z
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  return { distance = d - planet.radius, node = planet_node }
end

function API.spawn(prefab, pos, cb, parent)
  spawn_queue[#spawn_queue + 1] = { prefab = prefab, pos = pos, cb = cb, parent = parent }
end
API.EFFECTS = {}
function API.spawnEffect(name, x, y, z)
  API.EFFECTS[#API.EFFECTS + 1] = { name = name, x = x, y = y, z = z }
end

API.assembly = {
  info = function(node)
    if not (asm and asm.root == node) then return nil end
    -- `origin` is the PHYSICS-fresh pose: model the rails-carry gap by
    -- reporting the node pos PLUS this tick's carry delta — controllers must
    -- base force/pod math on it, never on the (stale) node coords.
    return {
      mass = asm.mass or 8.0,
      com = { x = node.x + asm.carry_dx, y = node.y, z = node.z },
      origin = { x = node.x + asm.carry_dx, y = node.y, z = node.z },
      vel = { x = asm.vel.x, y = asm.vel.y, z = asm.vel.z },
      angVel = asm.angVel or { x = 0, y = 0, z = 0 },
      -- GROUNDED and ANCHORED are not the same thing and the harness used to
      -- say they were. Anchored is clamped to the pad; grounded is "there is
      -- ground under this craft", which is also true of one that has just
      -- LANDED — and landed-and-stopped is the state the whole end-of-flight
      -- loop turns on. Defaults to anchored so every older section still reads
      -- the way it was written.
      grounded = (asm.grounded == nil) and asm.anchored or asm.grounded,
      anchored = asm.anchored,
      parts = asm.parts,
      inertia = asm.inertia,
    }
  end,
  rebuild = function(node, fn)
    local parts = {}
    for _, k in ipairs(node.kids) do parts[#parts + 1] = k.__id end
    asm = { root = node, parts = parts, anchored = false,
            vel = { x = 0, y = 0, z = 0 }, carry_dx = 0 }
    if fn then fn(node) end
  end,
  setAnchored = function(node, on)
    assert(asm and asm.root == node, "setAnchored before rebuild")
    asm.anchored = on
  end,
  keepLive = function(node, on)
    assert(asm and asm.root == node, "keepLive before rebuild")
    asm.kept_live = on
  end,
  syncColliders = function(node)
    assert(asm and asm.root == node, "syncColliders before rebuild")
    asm.collider_syncs = (asm.collider_syncs or 0) + 1
  end,
  teleport = function(node, pos)
    assert(asm and asm.root == node, "teleport before rebuild")
    node.x, node.y, node.z = pos.x, pos.y, pos.z
  end,
  forceAt = function(node, force, at)
    force_calls = force_calls + 1
    API.LAST_FORCE = { x = force.x, y = force.y, z = force.z } -- (chute drag pulls at the canopy)
    -- The application point must be PHYSICS-consistent: computed from
    -- info.origin (node pos + carry), never the stale node pose. An offset
    -- of a carry-delta here was the constant SAS torque bias of round 10.
    -- Engines sit at known blueprint x-offsets (0 for the stack, 2.0 for
    -- the side booster) — the point must land on ONE of them, carried.
    if asm and asm.root == node and asm.carry_dx ~= 0 then
      local ok = false
      for _, ex in ipairs({ 0.0, 2.0 }) do
        if math.abs(at.x - (node.x + asm.carry_dx + ex)) < 0.5 then ok = true break end
      end
      if not ok then
        error(string.format(
          "forceAt point off the physics hull: at.x=%.2f, node.x=%.2f carry=%.2f (stale node pose?)",
          at.x, node.x, asm.carry_dx))
      end
    end
  end,
  force = function(node, f)
    force_calls = force_calls + 1
    API.LAST_FORCE = { x = f.x, y = f.y, z = f.z } -- through-CoM (chute drag)
  end,
  torque = function(_, t) torque_calls = torque_calls + 1; API.LAST_TORQUE = t end,
  -- Recorded: the safety net brakes a spin with an equal-and-opposite PAIR.
  impulseAt = function(node, imp, at)
    API.IMPULSES = API.IMPULSES or {}
    API.IMPULSES[#API.IMPULSES + 1] = { node = node, imp = imp, at = at }
  end,
  -- Faithful split: departing nodes leave the root's children (the engine
  -- re-parents them under a fresh stage root) and the compound's part list.
  split = function(node, parts, cb)
    split_calls[#split_calls + 1] = #parts
    for _, pn in ipairs(parts) do
      for i, k in ipairs(node.kids) do
        if k == pn then table.remove(node.kids, i) break end
      end
      pn.parent = nil
    end
    if asm and asm.root == node then
      local keep = {}
      for _, id in ipairs(asm.parts) do
        local gone = false
        for _, pn in ipairs(parts) do
          if pn.__id == id then gone = true break end
        end
        if not gone then keep[#keep + 1] = id end
      end
      asm.parts = keep
    end
    -- Like the engine: the departing parts come away under a fresh root, and
    -- the callback gets that root (the stub's assembly.info has nothing on it).
    if cb then
      local st = make_node("Vessel (stage)", node.x, node.y, node.z)
      for _, pn in ipairs(parts) do
        pn.parent = st
        st.kids[#st.kids + 1] = pn
      end
      local ok, err = xpcall(cb, debug.traceback, st)
      if not ok then error("split callback: " .. tostring(err)) end
    end
  end,
  -- Injectable per-part contact loads (the engine's per-tick attribution):
  -- push { part=, impulse=, x=, y=, z= } into API.IMPACTS to simulate a slam.
  -- Like the engine, this is LAST TICK's list and can be read more than once
  -- in a tick (the park check reads it before the damage model); the harness
  -- clears it at the end of each step.
  impacts = function(node)
    return API.IMPACTS or {}
  end,
}

-- ── script loading ──────────────────────────────────────────────────────────
-- kind → LIST of envs, in registration order: findScript returns the FIRST
-- (arbitrary, like the engine), findScripts returns them all — scripts that
-- need THE piloted vessel must scan, and the decoy below proves they do.
local script_envs = {}

local function handle_of(env)
  return setmetatable({ node = env.__node }, { __index = env })
end

function API.findScript(kind)
  local l = script_envs[kind]
  if not l or #l == 0 then return nil end
  return handle_of(l[1])
end
API.findScripts = function(kind)
  local out = {}
  for _, env in ipairs(script_envs[kind] or {}) do out[#out + 1] = handle_of(env) end
  return out
end

local function register_script(kind, env)
  script_envs[kind] = script_envs[kind] or {}
  table.insert(script_envs[kind], env)
end

local function load_script(path, kind, node)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  env.__node = node
  env.__kind = kind
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  register_script(kind, env)
  return env
end

local failures = {}
local function call(env, fn, ...)
  local f = env[fn]
  if not f then return end
  local ok, err = xpcall(f, debug.traceback, ...)
  if not ok then
    failures[#failures + 1] = string.format("%s.%s: %s", env.__kind or "?", fn, err)
  end
end

-- ── the simulated engine loop ───────────────────────────────────────────────
local spawner_env, controller_env, map_env

local function deliver_spawns()
  local batch = spawn_queue
  spawn_queue = {}
  for _, req in ipairs(batch) do
    -- Like the engine: spawn at the WORLD pos, then re-express as
    -- parent-local when a parent is given.
    local x, y, z = req.pos.x, req.pos.y, req.pos.z
    if req.parent then
      local pwx, pwy, pwz = world_of(req.parent)
      x, y, z = x - pwx, y - pwy, z - pwz
    end
    local n = make_node(req.prefab, x, y, z, req.parent)
    -- Every part carries a RigidBody whose mass the craft writes (0.117 rb.mass).
    if req.prefab:find("^Part") then n.components["RigidBody"] = { mass = 1.0 } end
    -- The landing-leg prefab is a hierarchy: the gear device rolls the two
    -- EMPTY pivot nodes (hip → knee), so the harness must spawn them too.
    if req.prefab == "PartLegs" then
      -- The real prefab's deployed-footprint collider reaches 0.4 m BELOW the
      -- stack's y = 0 when mounted at y = 0.65: the spawner must seat on it.
      n.components["RigidBody"] = { half_x = 0.95, half_y = 1.05, half_z = 0.45, mass = 1.0 }
      local up = make_node("LegUpperPivot", 0.12, 0.0, 0.0, n)
      make_node("LegKneePivot", 0.0, -0.84, 0.0, up)
    end
    -- Engine part prefabs carry an "Engine Flame" vfx child.
    if req.prefab:find("PartEngine") then
      local fl = make_node("Engine Flame", 0, -0.7, 0, n)
      fl.particles_state = { playing = false, intensity = 0 }
      fl.components["PointLight"] = { intensity = 0 }
    end
    if req.prefab == "Vessel" then
      controller_env = load_script("solar/scripts/vessel_controller.lua", "vessel_controller", n)
      call(controller_env, "start", n)
    end
    if req.cb then
      local ok, err = xpcall(req.cb, debug.traceback, n)
      if not ok then failures[#failures + 1] = "spawn cb: " .. err end
    end
  end
end

local function step(n)
  for _ = 1, n do
    T = T + TICK
    tick_lines = {}
    -- Rails: the planet moves; parented nodes ride via the hierarchy, the
    -- anchored assembly rides via the engine's carry (modeled here).
    local dx = 90 * TICK
    planet.x = planet.x + dx
    planet_node.x = planet_node.x + dx
    -- Model the fixedUpdate rails-carry gap: the sim carries the compound at
    -- the TOP of the tick but the node writes back after scripts run —
    -- info.origin is ahead of node.x by one carry delta during the script
    -- pass, and the post-tick writeback closes it.
    if asm then asm.carry_dx = dx end
    deliver_spawns()
    if spawner_env then call(spawner_env, "update", spawner_env.__node, TICK) end
    if controller_env then call(controller_env, "fixedUpdate", controller_env.__node, TICK) end
    -- Post-tick writeback closes the gap, then the camera pass runs.
    if asm then
      asm.root.x = asm.root.x + asm.carry_dx
      asm.carry_dx = 0
    end
    if controller_env then call(controller_env, "lateUpdate", controller_env.__node, TICK) end
    if map_env then call(map_env, "lateUpdate", map_env.__node, TICK) end
    API.KEYS.edge = {}
    API.IMPACTS = {}
  end
end

local function press(k) API.KEYS.edge[k] = true end

local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end

-- ── the scenario ────────────────────────────────────────────────────────────
save_store["shipyard.blueprint"] = { parts = {
  { uid = 1, id = "pod", prefab = "PartPod", x = 0, y = 3.0, z = 0, yaw = 0,
    h = 0.8, mass = 1.2, cost = 400, kind = "crewed", thrust = 0, burn = 0, fuel = 0, decouple = 0, legs = 0 },
  { uid = 2, id = "tankS", prefab = "PartTankS", x = 0, y = 2.1, z = 0, yaw = 0, parent = 1,
    h = 1.0, mass = 1.5, cost = 120, kind = "tank", thrust = 0, burn = 0, fuel = 60, fuel_t = 0.01,
    decouple = 0, legs = 0 },
  { uid = 3, id = "decoupler", prefab = "PartDecoupler", x = 0, y = 1.47, z = 0, yaw = 0, parent = 2,
    h = 0.25, mass = 0.15, cost = 60, kind = "structural", thrust = 0, burn = 0, fuel = 0, decouple = 1, legs = 0 },
  { uid = 4, id = "engineS", prefab = "PartEngineS", x = 0, y = 0.65, z = 0, yaw = 0, parent = 3,
    h = 1.3, mass = 0.8, cost = 150, kind = "engine", thrust = 55, burn = 0.9, fuel = 0, decouple = 0, legs = 0 },
  -- An UPPER-stage engine above the decoupler: it must stay cold (no thrust,
  -- no flame) until the stage below separates. Bolted to the POD (uid 1), so
  -- the axial cut below the tank must never sweep it away.
  { uid = 5, id = "engineS", prefab = "PartEngineS", x = 0, y = 2.5, z = 0, yaw = 0, parent = 1,
    h = 1.3, mass = 0.8, cost = 150, kind = "engine", thrust = 55, burn = 0.9, fuel = 0, decouple = 0, legs = 0 },
  -- A SIDE BOOSTER branch (builder v1.2 radial mounts): a radial decoupler
  -- on the tank's flank (disc rolled to face outward) + a booster engine on
  -- its outer face. Burns from ignition; SPACE kicks the whole branch away
  -- laterally BEFORE any axial stage fires.
  { uid = 6, id = "radialDec", prefab = "PartDecoupler", x = 1.02, y = 2.1, z = 0, yaw = 0,
    roll = -1.5708, h = 0.25, mass = 0.12, cost = 70, kind = "structural",
    thrust = 0, burn = 0, fuel = 0, decouple = 1, legs = 0, radial = 1, parent = 2, att = "radial" },
  { uid = 7, id = "engineS", prefab = "PartEngineS", x = 2.0, y = 2.1, z = 0, yaw = 0,
    h = 1.3, mass = 0.8, cost = 150, kind = "engine", thrust = 40, burn = 0.7,
    fuel = 0, decouple = 0, legs = 0, parent = 6 },
  -- LANDING LEGS: the first peripheral device — G toggles them in flight.
  -- Mounted LOW (y=0.65, beside the bottom engine) but bolted to the TANK
  -- (uid 2, on the pod/upper side): the tree-based axial cut below the tank
  -- must KEEP it, even though old bottom-up-y staging would have dropped it
  -- (a low part hung on an upper stage — exactly Ty's staging bug).
  { uid = 8, id = "legs", prefab = "PartLegs", x = 0, y = 0.65, z = 0.8, yaw = 0, parent = 2,
    h = 0.7, mass = 0.3, cost = 90, kind = "structural", thrust = 0, burn = 0,
    fuel = 0, decouple = 0, legs = 1 },
  -- A PARACHUTE on the nose: armed in staging, deploys to drag in atmosphere.
  { uid = 9, id = "chute", prefab = "PartChute", x = 0, y = 3.7, z = 0, yaw = 0, parent = 1,
    h = 0.61, mass = 0.1, cost = 80, kind = "canvas", thrust = 0, burn = 0,
    fuel = 0, decouple = 0, legs = 0, chute = 1 },
  -- A second TANK, higher up the stack: propellant has mass (fuel_t, tonnes per
  -- unit) and the pool drains from the LOWEST tank first, so this one stays
  -- full while the one below it feeds the engines.
  { uid = 11, id = "tankS", prefab = "PartTankS", x = 0, y = 2.6, z = 0.9, yaw = 0, parent = 1,
    h = 1.0, mass = 0.2, cost = 120, kind = "tank", thrust = 0, burn = 0, fuel = 40, fuel_t = 0.01,
    decouple = 0, legs = 0 },
  -- A SECOND chute on the pod's flank, so the over-pressure rip in the stress
  -- section has a live canopy after the crash tests have used up the first.
  { uid = 10, id = "chute", prefab = "PartChute", x = 0.8, y = 3.0, z = 0, yaw = 0, parent = 1,
    h = 0.61, mass = 0.1, cost = 80, kind = "canvas", thrust = 0, burn = 0,
    fuel = 0, decouple = 0, legs = 0, chute = 1, att = "radial" },
} }
save_store["shipyard.launch"] = 1
save_store["shipyard.pilot"] = 1

-- The crew stands 14 m short of the planet's top, so the pad (rolled out
-- `offset` = 14 m along +X) lands ON the top, where up is +Y. The spawner aims
-- the pad at the radial through its own ground point (a pad aimed by the crew's
-- radial leaned 18° on a small world); this harness re-expresses spawned
-- parts as parent-local without rotation, so an untilted pad keeps it honest.
local astro = make_node("Astronaut", planet.x - 14, planet.y + planet.radius + 6, planet.z)
-- A dynamic body, like the scene's. Seated, it must ride as KINEMATIC: a live
-- capsule parked inside the hull every tick is what flung launches (2026-10).
astro.components["RigidBody"] = { kinematic = 0 }
local map_node = make_node("Orbit Map", 0, 0, 0)
for _, nm in ipairs({ "Ship HUD Text", "Vessel HUD", "Navball", "Speed Tape",
                      "Alt Tape", "Speed Readout", "Alt Readout", "Heading Readout" }) do
  local n = make_node(nm, 0, 0, 0)
  n.components["UiElement"] = { visible = false }
  n.text = ""
end

-- A DECOY vessel: a second, unpiloted craft registered BEFORE the real one,
-- so findScript("vessel_controller") returns the WRONG instance — every
-- consumer that needs THE piloted vessel must scan findScripts (the
-- multi-craft world: landed ships, satellites, dropped stages).
local decoy_node = make_node("Vessel (parked)", planet.x + 40, planet.y + planet.radius, planet.z)
local decoy_env = { __node = decoy_node, __kind = "vessel_controller", piloting = false }
register_script("vessel_controller", decoy_env)

local sp_node = make_node("Vessel Spawner", 0, 0, 0)
spawner_env = load_script("solar/scripts/vessel_spawner.lua", "vessel_spawner", sp_node)
call(spawner_env, "start", sp_node)

-- The map: its own screen now, on its own node. Its lateUpdate drives the
-- whole 3D view for whatever craft is being flown.
map_env = load_script("solar/scripts/orbit_map.lua", "orbit_map", map_node)
register_script("orbit_map", map_env)
call(map_env, "start", map_node)

step(30) -- spawn pad + vessel + parts, rebuild, clamp, board

check(asm ~= nil, "assembly was rebuilt")
check(asm and asm.anchored, "vessel is CLAMPED after assembly")
check(controller_env and controller_env.piloting, "pilot auto-boarded from launch")
check(save_store["shipyard.pilot"] == 0, "pilot handoff flag consumed")
check(astro.visible == false, "astronaut rides hidden in the pod")
check(astro.components["RigidBody"].kinematic == 1,
  "...as a KINEMATIC passenger, not a body inside the hull (the launch fling)")
local seated_log = false
for _, l in ipairs(logs) do
  if l:find("lowest collider 0.40 m below the origin", 1, true) then seated_log = true end
end
check(seated_log, "the clamp seats the craft on its LOWEST COLLIDER (the legs' footprint), not on y = 0")
check(type(controller_env.releaseClamps) == "function",
  "the clamp release is one published function (SPACE and probes share it)")

-- The pad must be planet-parented and physically UNDER the vessel in WORLD
-- coordinates (round 7: its local position had the planet offset added twice,
-- putting it 5000 units away).
local pad = find_node("Launchpad")
check(pad ~= nil, "launchpad spawned")
if pad and asm then
  check(pad.parent == planet_node, "launchpad parented to the planet")
  local pwx, pwy, pwz = world_of(pad)
  local vwx, vwy, vwz = world_of(asm.root)
  local d = math.sqrt((pwx - vwx) ^ 2 + (pwy - vwy) ^ 2 + (pwz - vwz) ^ 2)
  check(d < 12, string.format("launchpad sits under the vessel (d=%.1f)", d))
  -- The pad is aimed at the radial through ITS OWN ground point (here the
  -- planet's top, so upright), not the crew's: 14 m away on a small world the
  -- crew's radial is several degrees off, and a leaning pad launched the
  -- First Flight sideways into a near-orbit.
  local rx, ry, rz = pwx - planet.x, pwy - planet.y, pwz - planet.z
  local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
  -- (Stood up with node:setUp, floptle/0403: no Euler angles to get wrong.)
  local pu = pad:worldUp()
  local dot = (pu.x * rx + pu.y * ry + pu.z * rz) / rl
  check(dot > 1 - 1e-6, string.format("the pad stands on its own local vertical (cos %.7f)", dot))
  local vu = asm.root:worldUp()
  check((vu.x * rx + vu.y * ry + vu.z * rz) / rl > 1 - 1e-6, "...and so does the vessel")
end

-- The cockpit is drawn by flight_hud from the controller's `tele` table.
local hudn = find_node("Ship HUD Text")
local function tele() return controller_env.tele or {} end
check(tele().anchored == true, "telemetry reports the CLAMPED state")
check(controller_env.hasFlown == false, "a craft on the pad has not flown")

-- The spawner honors the blueprint's full local rotation (v1.2 builds
-- sideways parts): the radial decoupler's disc must arrive rolled outward.
local rdec
for _, n in ipairs(nodes) do
  if n.name == "PartDecoupler" and math.abs((n.x or 0) - 1.02) < 0.1 then rdec = n end
end
check(rdec ~= nil and math.abs((rdec.roll or 0) + 1.5708) < 0.01,
  "radial decoupler spawns with its blueprint roll (sideways disc)")

-- Release, throttle: thrust + flames must fire.
press("space")
step(2)
check(asm and asm.anchored == false, "SPACE released the launch clamps")
API.KEYS.down["shift"] = true
step(30)
API.KEYS.down["shift"] = false
check(force_calls > 0, "throttle produced engine forceAt calls")
-- STAGE GATING: the bottom stack engine AND the attached side booster burn
-- (2 × ~30 ticks ≈ 60 calls); the upper-stage engine stays cold (3 burning
-- would be ~90).
check(force_calls >= 50 and force_calls <= 70,
  string.format("core + booster burn, upper stays cold (forceAt ×%d over 30 ticks)", force_calls))
check(torque_calls > 0, "attitude loop produced torque calls")
-- PROPELLANT: the burn came out of the LOWER tank only, the pool is the sum of
-- the tanks, the craft's mass is the dry hull plus what they hold, and every
-- push is scaled to that wet mass.
do
  local c = controller_env
  local l2, l11 = c.tankLeft(2), c.tankLeft(11)
  check(l2 and l2 < 60 and l11 == 40,
    string.format("the lowest tank feeds the engines first (low %.2f / 60, high %s / 40)", l2 or -1, tostring(l11)))
  check(l2 and math.abs(c.fuel - (l2 + l11)) < 1e-9, "the pool is what the tanks hold")
  local fm = c.fuelMass()
  check(math.abs(fm - (l2 + l11) * 0.01) < 1e-9, string.format("propellant has mass: %.3f t", fm))
  -- The TRUE mass is the blueprint's dry parts + propellant, and it is what
  -- the physics flies: every part's RigidBody carries its own dry mass plus
  -- what its tank still holds (massSync, floptle/0406 — no push is rescaled).
  local dry, wet = c.trueMass()
  check(math.abs(dry - 6.07) < 1e-9 and math.abs(wet - (6.07 + fm)) < 1e-9,
    string.format("true mass: the blueprint's dry parts + propellant (%.3f / %.3f t)", dry, wet))
  check(c.massK == nil, "no push is rescaled to a 'true' mass any more (massK is gone)")
  local function part_at(px, py, pz)
    local root = c.dock and c.dock.node
    for _, n in ipairs(nodes) do
      if n.valid and n.parent and n.parent.name == "Vessel" and n.name:find("^Part")
        and math.abs(n.x - px) < 0.05 and math.abs(n.y - py) < 0.05 and math.abs(n.z - pz) < 0.05 then
        return n
      end
    end
  end
  local tk2, tk11, pod = part_at(0, 2.1, 0), part_at(0, 2.6, 0.9), part_at(0, 3.0, 0)
  -- (written at the top of each tick, before that tick's burn: one tick behind)
  local m2 = tk2 and tk2.components.RigidBody.mass
  local m11 = tk11 and tk11.components.RigidBody.mass
  check(m2 and math.abs(m2 - (1.5 + c.tankLeft(2) * 0.01)) < 1e-3,
    string.format("the burning tank's rigidbody weighs its shell + what it still holds (%s t)", tostring(m2)))
  check(m11 and math.abs(m11 - (0.2 + 40 * 0.01)) < 1e-6,
    string.format("...and the full one its shell + 0.4 t (%s t)", tostring(m11)))
  check(pod and math.abs(pod.components.RigidBody.mass - 1.2) < 1e-9,
    "a part with no tank weighs its blueprint dry mass")
  step(6)   -- let the 10 Hz telemetry catch up
  local tm = tele()
  check(tm.mass and math.abs(tm.mass - (6.07 + c.fuelMass())) < 0.02,
    string.format("the HUD's mass is the true wet mass (%.2f t)", tm.mass or -1))
  check((tm.dv or 0) > 0 and (tm.burn_s or 0) > 0, "the HUD knows the Δv and burn time left")
  -- Pour it back and draw it again: the pool fills top-down and drains bottom-up.
  local was = c.fuel
  c.fuelFill(50)
  check(c.tankLeft(11) == 40 and math.abs(c.tankLeft(2) - 10) < 1e-9, "a refill tops up the upper tank first")
  c.fuelDraw(15)
  check(c.tankLeft(2) == 0 and math.abs(c.tankLeft(11) - 35) < 1e-9, "...and a burn empties the lower one first")
  c.fuelFill(was)
end
check(controller_env.throttle > 0, "throttle climbed under SHIFT")
local flame_lo, flame_hi, flame_boost
for _, n in ipairs(nodes) do
  if n.name == "Engine Flame" and n.parent then
    if (n.parent.x or 0) > 1.0 then flame_boost = n
    elseif n.parent.y < 1.5 then flame_lo = n
    else flame_hi = n end
  end
end
check(flame_lo ~= nil and flame_hi ~= nil and flame_boost ~= nil,
  "every engine prefab spawned a flame child")
check(flame_lo and flame_lo.particles_state.playing, "bottom-stage plume plays under throttle")
check(flame_lo and flame_lo.components["PointLight"].intensity > 0, "plume light follows throttle")
check(flame_hi and not flame_hi.particles_state.playing, "upper-stage plume stays COLD before staging")
check(flame_boost and flame_boost.particles_state.playing, "side-booster plume burns from ignition")

-- The flight stage list: separation EVENTS in firing order, next marked « —
-- the booster ring fires first by default. (The marker was ▶ until v0.4.1's
-- glyph sweep swapped it; this check kept looking for the old character and has
-- been failing ever since, which is how a suite teaches people to ignore it.)
local stages = tele().stages or {}
check(#stages == 3, string.format("telemetry lists every staging event (%d)", #stages))
check(stages[1] and stages[1].kind == "ring" and stages[1].eng == 1,
  "booster ring is the next event, taking its engine with it")
check(stages[2] and stages[2].kind == "axial" and stages[2].eng == 1,
  "...then the axial cut, which lights the upper engine")
check(stages[3] and stages[3].kind == "chute", "...and the chutes last")

-- PERIPHERALS: G folds the MULTI-JOINTED landing legs up (both pivots roll
-- toward the stowed pose), G again folds them back down to the deployed pose.
local leg_node, hip_pivot, knee_pivot
for _, n in ipairs(nodes) do
  if n.name == "PartLegs" then leg_node = n end
  if n.name == "LegUpperPivot" then hip_pivot = n end
  if n.name == "LegKneePivot" then knee_pivot = n end
end
check(leg_node ~= nil, "legs part spawned")
check(hip_pivot ~= nil and knee_pivot ~= nil, "leg spawned its hip + knee pivots")
step(2) -- let the device apply the initial (deployed) pose
local dep_hip, dep_knee = hip_pivot.roll or 0.0, knee_pivot.roll or 0.0
press("g")
step(90)
check(controller_env.gear_deployed == false, "G retracts the gear")
check(math.abs((hip_pivot.roll or 0.0) - dep_hip) > 1.0
    and math.abs((knee_pivot.roll or 0.0) - dep_knee) > 1.0,
  string.format("both joints fold when retracted (hip %.2f, knee %.2f)",
    hip_pivot.roll or 0, knee_pivot.roll or 0))
press("g")
step(90)
check(controller_env.gear_deployed == true, "G redeploys the gear")
check(math.abs((hip_pivot.roll or 0.0) - dep_hip) < 0.05
    and math.abs((knee_pivot.roll or 0.0) - dep_knee) < 0.05,
  "both joints fold back to the deployed pose")

-- SPACE #2: side boosters kick away FIRST — the whole radial branch (its
-- decoupler + engine) leaves as one lateral group.
press("space")
step(2)
check(#split_calls == 1 and split_calls[1] == 2,
  string.format("boosters away as one 2-part branch (splits: %d)", #split_calls))
local ig = API.IGNORED[#API.IGNORED]
check(ig ~= nil and ig.b == asm.root and ig.a ~= asm.root and (ig.secs or 0) > 0,
  "the booster branch passes through the hull for a moment as it leaves (physics.ignorePair)")
check(type(controller_env.stageNext) == "function",
  "staging is one published function (SPACE and probes share it)")
force_calls = 0
step(30)
check(force_calls >= 20 and force_calls <= 35,
  string.format("only the core engine burns after booster separation (forceAt ×%d)", force_calls))
check(flame_boost and not flame_boost.particles_state.playing,
  "booster plume dies with the separation")

-- SPACE #3: the AXIAL decoupler path. TREE-BASED separation: the decoupler's
-- subtree = the decoupler (uid 3) + the bottom engine (uid 4) bolted below it.
-- The landing legs (uid 8) sit just as LOW (y=0.65) but hang off the TANK on
-- the pod side — old bottom-up-y staging swept them off with the cut; the tree
-- keeps them. This is Ty's staging bug, pinned by a test.
press("space")
step(2)
check(#split_calls == 2, "axial stage fires after the boosters are gone")
check(split_calls[2] == 2,
  string.format("axial cut drops exactly its subtree (decoupler + bottom engine); got %d parts",
    split_calls[2] or -1))
local legs_after = find_node("PartLegs")
check(legs_after ~= nil and legs_after.parent ~= nil,
  "a LOW part on the UPPER stage survives the axial cut below it (tree, not y)")

-- SPACE #4: PARACHUTES — the last staging event. It doesn't split; it opens
-- the canopy, which then drags against velocity in the atmosphere. Put the
-- ship in a descent and check the drag force opposes the fall.
check(controller_env.chutes_deployed == false, "chutes start packed")
asm.vel = { x = 0, y = -40, z = 0 } -- falling toward the planet (which is +X)
controller_env.throttle = 0.0        -- engines off: any upward force now is the canopy
API.LAST_FORCE = nil
press("space")
step(2)
check(controller_env.chutes_deployed == true, "SPACE deploys the parachutes")
-- A canopy per chute part, spawned at the deploy (scripts/parachute.lua draws
-- it): each knows its chute by `canopy`.
local canopies = 0
for _, n in ipairs(nodes) do if n.name == "Parachute" then canopies = canopies + 1 end end
local claimed = 0
for _, c in ipairs(controller_env.chutes) do if c.canopy then claimed = claimed + 1 end end
check(canopies == #controller_env.chutes and claimed == canopies,
  string.format("one canopy spawned and claimed per chute (%d canopies, %d chutes, %d claimed)",
    canopies, #controller_env.chutes, claimed))
-- THE DEPLOY SEQUENCE: lines pay out first (only the pilot chute drags), then
-- the canopy fills through a reefed stage to full.
local fill = controller_env.chute_fill
check(fill.stretch > 0 and fill.stretch < 1 and fill.area <= 0.011,
  string.format("lines paying out, pilot chute only (stretch %.2f, area %.3f)", fill.stretch, fill.area))
step(14) -- 40 m/s: line stretch at ~0.2 s
fill = controller_env.chute_fill
check(fill.stretch == 1, "the lines are taut a quarter of a second after the mortar at 40 m/s")
check(API.LAST_FORCE ~= nil and API.LAST_FORCE.y > 0,
  string.format("chute drag opposes the fall (Fy=%s)",
    API.LAST_FORCE and string.format("%.1f", API.LAST_FORCE.y) or "nil"))
step(10)
local reef_area = controller_env.chute_fill.area
check(reef_area > 0.05 and reef_area <= 0.2 + 1e-6,
  string.format("the canopy holds its reefed area first (%.3f)", reef_area))
local fy_reef = API.LAST_FORCE and API.LAST_FORCE.y or 0
step(150)
check((tele().chute_open or 0) > 0.9, string.format("disreefed, it fills to full (%.2f)", tele().chute_open or 0))
check((API.LAST_FORCE and API.LAST_FORCE.y or 0) > fy_reef * 3,
  "drag ramps with the inflated area (full ≫ reefed)")
-- The air stops (landed, hovering): the canopy spills and collapses.
asm.vel = { x = 0, y = -0.2, z = 0 }
step(75)
check(controller_env.chute_fill.area < 0.05,
  string.format("no air through it: the canopy collapses (area %.3f)", controller_env.chute_fill.area))
asm.vel = { x = 0, y = -40, z = 0 }
step(120)
check(controller_env.chute_fill.area > 0.9, "moving air fills it again")
-- CUT: the canopies part from their risers (their canvas flies free) and
-- nothing drags any more.
local ids = {}
for i, c in ipairs(controller_env.chutes) do ids[i] = c.canopy end
check(controller_env.cutChutes() == true, "cutChutes() cuts open chutes")
API.LAST_FORCE = nil
step(3)
local released = true
for _, c in ipairs(controller_env.chutes) do if c.canopy ~= nil then released = false end end
check(released and controller_env.chute_fill.area == 0,
  "...every canopy is released and the drag area is gone")
check(API.LAST_FORCE == nil or API.LAST_FORCE.y <= 0, "...so nothing pulls up on the craft")
check(captioned("cut away"), "...and the cut is captioned")
check(controller_env.cutChutes() == false, "...a second cut does nothing")
-- (re-rig them for the drag-cap and over-pressure tests below)
controller_env.chute_fill.cut = nil
for i, c in ipairs(controller_env.chutes) do c.canopy = ids[i] end
step(150)
asm.vel = { x = 0, y = 0, z = 0 } -- settle before the EVA checks

-- EVA: F steps out (flames off, HUD hides); board again FROM THE GROUND —
-- the pod is ~3 units up, so boarding must measure to the vessel's spine.
press("f")
step(2)
check(controller_env.piloting == false, "F exits the pod")
check(astro.components["RigidBody"].kinematic == 0, "stepping out hands the crew back to physics")
check(astro.visible == true, "astronaut visible after EVA exit")
check(flame_lo and flame_lo.particles_state.playing == false, "plume stops on EVA exit")
check(flame_hi and flame_hi.particles_state.playing == false, "upper plume off on EVA exit")
local hud_el = hudn.components["UiElement"]
check(hud_el.visible == false, "HUD hidden on EVA")
astro.x = asm.root.x + 2.0 -- standing beside the stack, at BASE height
astro.y = asm.root.y
astro.z = asm.root.z
controller_env.tele = nil
press("f")
step(2)
check(controller_env.piloting == true, "F re-boards from the ground (spine reach)")
check(astro.components["RigidBody"].kinematic == 1, "...and re-boarding seats them as a passenger again")
step(10)
check(controller_env.tele ~= nil, "telemetry resumes after re-board")

-- ── ENDING A FLIGHT (round 13) ──────────────────────────────────────────────
-- Down and stopped is a STATE the rest of the game asks about — it's how the
-- flight card decides between "recover this" and "leave it here". And
-- `standDown` is the one teardown every way out of the pod now goes through, so
-- it has to leave the crew somewhere real: visible, at the coordinates given,
-- and not still carrying the landing's velocity.
asm.grounded = true
asm.vel = { x = 0, y = 0, z = 0 }
step(20)   -- the HUD repaints on its own cadence, not every tick
check(controller_env.parked() == true, "a landed, stopped craft reads as parked")
check(controller_env.hasFlown == true, "...and, having left the pad, counts as flown")
asm.vel = { x = 40, y = 0, z = 0 }
step(2)
check(controller_env.parked() == false, "...and a moving one does not")
asm.vel = { x = 0, y = 0, z = 0 }
step(2)

local hx, hy, hz = planet.x + 7, planet.y + planet.radius + 1, planet.z - 3
astro.vx, astro.vy, astro.vz = 12, 12, 12
controller_env.standDown(asm.root, hx, hy, hz, 0, 0, 0)
check(controller_env.piloting == false, "standDown ends the flight")
check(astro.visible == true and astro.x == hx and astro.y == hy and astro.z == hz,
  "...and puts the crew down exactly where it was told to")
check(astro.vx == 0 and astro.vy == 0 and astro.vz == 0,
  "...at rest, not still doing the landing's speed")
check(controller_env.throttle == 0.0, "...with the throttle shut")
-- PARKING is the engine's (floptle/0385): a resting assembly sleeps on its own
-- and wakes on any push. The controller no longer re-anchors a parked craft,
-- so nothing can mistake a park-anchor for the launch clamps.
step(150)
check(asm.anchored == false, "a craft left parked is left to the engine's sleep (never re-anchored)")
local parked_log = false
for _, l in ipairs(logs) do if l:find("vessel: parked", 1, true) then parked_log = true end end
check(not parked_log, "...and no stop-gap says it parked it")
-- Back in the pod for the map/breakup sections below.
astro.x, astro.y, astro.z = asm.root.x + 2.0, asm.root.y, asm.root.z
press("f")
step(2)
check(controller_env.piloting == true, "...and you can climb back in afterwards")
check(asm.anchored == false, "boarding a parked craft leaves it unclamped")
step(12)
check(tele().anchored == false, "...and the cockpit does not read it as clamped")

-- ── THE MAP flies the piloted vessel (round 11) ─────────────────────────────
-- Put the piloted vessel "in flight" with a real orbital velocity (the engine
-- mirror feeds node.vx on compound roots; modeled by hand here), open the map
-- with M, and demand the VESSEL'S conic is drawn + the info panel reads the
-- vessel as its subject.

asm.vel = { x = 47, y = 0, z = 0 }   -- ~circular at pad radius: sqrt(mu/r)
asm.root.vx, asm.root.vy, asm.root.vz = 47, 0, 0
asm.root.grounded = false
asm.grounded = false
step(9)

press("m")
step(9) -- past the 10 Hz map-HUD throttle

check(map_env.map_view == true, "M opens the map while flying a built vessel")
local conic_drawn = false
for _, l in ipairs(tick_lines) do
  if math.abs(l.r - 0.35) < 0.01 and math.abs(l.g - 0.85) < 0.01 and math.abs(l.b - 1.0) < 0.01 then
    conic_drawn = true
    break
  end
end
check(conic_drawn, string.format(
  "map draws the piloted vessel's orbit conic (%d lines drawn this tick)", #tick_lines))
check(hudn.text:find("FLYING") ~= nil and hudn.text:find("Orbiting") ~= nil,
  "map info panel reads the vessel's orbit (got: " .. tostring(hudn.text) .. ")")
press("m")
step(9) -- the vessel HUD repaints on its own 10 Hz clock
check(map_env.map_view == false, "M closes the map again")
check(controller_env.tele and controller_env.tele.stages ~= nil,
  "telemetry keeps flowing after closing the map")

-- ── DESTRUCTION (round 11): per-part impacts → damage → breakup ─────────────
-- The engine attributes every contact's impulse to the part that took it
-- (assembly.impacts). Inject a survivable hit on the tank (smoulders + HUD
-- damage line), then a killing blow (explosion + the part shears off), then
-- kill the POD (flight over, pilot thrown clear).
local tank_node, pod_node
for _, n in ipairs(nodes) do
  if n.parent == asm.root then
    if n.name == "PartTankS" then tank_node = n end
    if n.name == "PartPod" then pod_node = n end
  end
end
check(tank_node ~= nil and pod_node ~= nil, "tank + pod children located")

-- Damage ARMS 2.5s after clamp release. The crash metric is now the TOTAL
-- closing speed (assembly.impacts .speedAbs) — the energy, not just the normal
-- component — and surviving-but-overloaded parts WEAR at a dt-scaled rate, so a
-- real hit is a SUSTAINED contact (many ticks), not one frame. Simulate a
-- ~20-tick low-speed GRIND on the tank (mostly tangential slide: normal 0.5,
-- total 1.5 — under the wounded tolerance floor, so it wears via the dt-scaled
-- path and never instant-breaks): it smoulders and shows on the HUD, survives.
step(160)
local n_fx = #API.EFFECTS
for _ = 1, 20 do
  API.IMPACTS = { { part = tank_node.id, impulse = 0.0, speed = 0.5, speedAbs = 1.5,
                    x = tank_node.x, y = tank_node.y, z = tank_node.z } }
  step(1)
end
-- The grind throws sparks and kicks up gritty ScrapeDust (dust/scratch feedback,
-- not soft smoke circles); wounded parts additionally smoulder (Smoke) once they
-- drop below the smoulder threshold.
local scraped, sparked = false, false
for i = n_fx + 1, #API.EFFECTS do
  local nm = API.EFFECTS[i].name
  if nm == "ScrapeDust" then scraped = true end
  if nm == "Sparks" then sparked = true end
end
check(scraped and sparked, "a sustained survivable grind throws sparks + kicks up dust")
check(tele().hp and tele().hp < 1 and tele().hp_part ~= nil,
  "telemetry reports the damaged part (got: " .. tostring(tele().hp_part) .. ")")

-- ── THE LANDING THAT DISINTEGRATED ─────────────────────────────────────────
-- Reported after a chute-and-thrust touchdown: *"as soon as it touched the
-- ground it like dicintigrated and i got sent flying off infinitely into the
-- void and got softlocked."*
--
-- The airframe-failure test used to run on `speedAbs`, the TOTAL contact speed,
-- which counts the part of your motion that is ALONG the ground. Three metres a
-- second of sink and fourteen of lateral drift — an ordinary landing — summed
-- past the shatter threshold and destroyed the whole ship on contact. It has to
-- be judged on the NORMAL component: how fast you went INTO the surface.
-- The legs and the chute: DIRECT children of the compound root, because that is
-- the only place `assembly.impacts` attribution resolves a part id. Both are
-- parts a ship can lose and keep flying, which is what makes "one part shears"
-- distinguishable from "the airframe fails" at all.
local legs_node, chute_node
for _, n in ipairs(nodes) do
  if n.parent == asm.root and n.valid ~= false then
    if n.name == "PartLegs" then legs_node = n end
    if n.name == "PartChute" then chute_node = n end
  end
end
check(legs_node ~= nil and chute_node ~= nil, "legs + chute located for the landing tests")

-- Three metres a second of sink, fourteen of lateral drift. Judged on the total
-- that is 14.3 and the whole ship used to burst; judged on how fast it went INTO
-- the ground it is 3, and what happens is you lose a landing leg.
asm.vel = { x = 14, y = -3, z = 0 }
local n_split_land = #split_calls
API.IMPACTS = { { part = legs_node.id, impulse = 0.0, speed = 3.0, speedAbs = 14.0,
                  x = legs_node.x, y = legs_node.y, z = legs_node.z } }
step(2)
check(controller_env.piloting == true,
  "a landing with heavy lateral drift does not end the flight")
check(#split_calls - n_split_land <= 1, string.format(
  "...and shears at most the part that touched, not the airframe (splits: %d)",
  #split_calls - n_split_land))

-- ── A CONTACT THE CRAFT COULD NOT HAVE DELIVERED ───────────────────────────
-- Terrain collision drifts out of step with the drawn surface (floptle/0074),
-- and a deep penetration resolving in one tick reports a closing speed out of
-- nowhere. Judged at face value it shatters an intact ship — and then fires the
-- crew off at the ejection velocity, which is the "flying into the void" half
-- of the same report. A contact claiming far more than the craft's own speed is
-- an artifact, and is clamped to what the craft could actually have done.
asm.vel = { x = 0, y = -3, z = 0 }         -- three metres a second, straight down
-- ...for a couple of ticks first: the crash ceiling also remembers LAST tick's
-- speed (the impact tick has already eaten most of a real crash's speed by the
-- time a script reads it), and this harness changes speed instantly.
step(2)
local n_split_art, n_logs_art = #split_calls, #logs
API.IMPACTS = { { part = chute_node.id, impulse = 0.0, speed = 40.0, speedAbs = 40.0,
                  x = chute_node.x, y = chute_node.y, z = chute_node.z } }
step(2)
check(controller_env.piloting == true,
  "a 40 m/s contact on a craft doing 3 m/s does not destroy the ship")
check(#split_calls - n_split_art <= 1, string.format(
  "...and is not treated as a lithobrake (splits: %d)", #split_calls - n_split_art))
local said = false
for i = n_logs_art + 1, #logs do
  if tostring(logs[i]):find("out of step with the surface") then said = true end
end
check(said, "...and says what it ignored, rather than silently swallowing it")

-- ── STRESS AND THE SAFETY NET (the launch-fling round, 2026-10) ────────────
-- A SPIN no rocket should have is braked back with a pure couple — a pair of
-- equal and opposite impulses, so it slows the tumble without shoving the hull
-- — and it is LOGGED, never silent.
API.IMPULSES = {}
asm.vel = { x = 0, y = 0, z = 0 }
step(2)
asm.angVel = { x = 0, y = 30, z = 0 }
step(1)
asm.angVel = nil
local couple = #API.IMPULSES >= 2
if couple then
  local a, b = API.IMPULSES[#API.IMPULSES - 1].imp, API.IMPULSES[#API.IMPULSES].imp
  couple = math.abs(a.x + b.x) < 1e-6 and math.abs(a.y + b.y) < 1e-6 and math.abs(a.z + b.z) < 1e-6
end
check(couple, "a 30 rad/s tumble is braked by an equal-and-opposite impulse pair (a pure couple)")
check((controller_env.integrity().spin or 0) >= 1, "...and the safety net counts it")
local spin_logged = false
for _, l in ipairs(logs) do if l:find("SAFETY: spin clamp", 1, true) then spin_logged = true end end
check(spin_logged, "...and says so in the log")
-- With the solver's inertia tensor (assembly.info, floptle/0393) the couple is
-- EXACT: its angular impulse is I·Δω, taking the spin straight back to the
-- ceiling in one tick (no halved floor, no overshoot).
do
  API.IMPULSES = {}
  asm.inertia = { { x = 2, y = 0, z = 0 }, { x = 0, y = 3, z = 0 }, { x = 0, y = 0, z = 4 } }
  asm.angVel = { x = 0, y = 30, z = 0 }
  step(1)
  asm.angVel = nil
  local n = #API.IMPULSES
  local Lx, Ly, Lz = 0, 0, 0
  if n >= 2 then
    local c = asm.root
    for k = n - 1, n do
      local e = API.IMPULSES[k]
      local rx, ry, rz = e.at.x - (c.x + asm.carry_dx), e.at.y - c.y, e.at.z - c.z
      Lx = Lx + ry * e.imp.z - rz * e.imp.y
      Ly = Ly + rz * e.imp.x - rx * e.imp.z
      Lz = Lz + rx * e.imp.y - ry * e.imp.x
    end
  end
  local want = 3 * (12.0 - 30) -- (vessel_controller SPIN_MAX)
  check(n >= 2 and math.abs(Ly - want) < 1e-6 and math.abs(Lx) < 1e-6 and math.abs(Lz) < 1e-6,
    string.format("...sized by the solver's inertia tensor: ΔL = I·Δω exactly (%.3f, want %.3f)", Ly, want))
  -- THE WHEELS' GAIN never outruns a light craft's inertia: weighing what it
  -- really weighs, a pod-and-tank stack has so little that the full gain
  -- overshot every tick and span it up to 20 rad/s on the ground. Capped so a
  -- tick takes out at most half the rate error about the lightest axis.
  local was_mode = controller_env.sas_mode
  controller_env.setSAS("stability")
  asm.inertia = { { x = 0.05, y = 0, z = 0 }, { x = 0, y = 0.08, z = 0 }, { x = 0, y = 0, z = 0.06 } }
  asm.angVel = { x = 0, y = 2, z = 0 }
  API.LAST_TORQUE = nil
  step(1)
  local T1 = API.LAST_TORQUE
  local cap = 0.5 * 0.05 / TICK * 2
  check(T1 and math.abs(math.sqrt(T1.x ^ 2 + T1.y ^ 2 + T1.z ^ 2) - cap) < 1e-6,
    string.format("the reaction wheels' gain is capped by the lightest axis (|T| %.3f, cap %.3f)",
      T1 and math.sqrt(T1.x ^ 2 + T1.y ^ 2 + T1.z ^ 2) or -1, cap))
  asm.inertia = { { x = 50, y = 0, z = 0 }, { x = 0, y = 60, z = 0 }, { x = 0, y = 0, z = 70 } }
  API.LAST_TORQUE = nil
  step(1)
  local T2 = API.LAST_TORQUE
  check(T2 and math.abs(math.sqrt(T2.x ^ 2 + T2.y ^ 2 + T2.z ^ 2) - controller_env.params.torque * 2) < 1e-6,
    "...and a heavy craft feels the full gain")
  asm.angVel = nil
  controller_env.setSAS(was_mode or "stability")
  asm.inertia = nil
end
-- A one-tick speed GAIN no force on board explains (this harness teleports the
-- velocity, exactly like a depenetration kick does) is clamped back and logged.
check((controller_env.integrity().kick or 0) >= 1, "an unexplained one-tick speed gain is caught and counted")

-- DRAG NEVER REVERSES THE CRAFT: an open canopy on a LIGHT craft at speed used
-- to integrate to a Δv bigger than v itself and fire the ship back up. It is
-- capped at half the speed per tick.
asm.mass = 0.5
asm.grounded = false
asm.vel = { x = 0, y = -100, z = 0 }
API.LAST_FORCE = nil
step(3)
local cap = 0.5 * 0.5 * 100 / TICK
local fy = API.LAST_FORCE and API.LAST_FORCE.y or 0
check(fy > 0 and fy <= cap * 1.001, string.format(
  "chute drag is capped at half the speed per tick (Fy=%.0f, cap %.0f)", fy, cap))
asm.mass = nil

-- PRESSURE: an open canopy dragged at 150 m/s through thick air (12.8 kPa,
-- twice its safe 6.5) tears away — as its OWN body, velocity kept, while the
-- craft keeps flying and stops counting it as a chute.
local n_split_rip, n_logs_rip = #split_calls, #logs
local n_chutes_rip = #controller_env.chutes
asm.vel = { x = 0, y = -150, z = 0 }
step(4)
local ripped, shed = false, false
for i = n_logs_rip + 1, #logs do
  if logs[i]:find("chute ripped", 1, true) then ripped = true end
  if logs[i]:find("STRESS:", 1, true) then shed = true end
end
check(ripped and shed, "an open chute far past its safe pressure tears off (STRESS + chute ripped)")
check(#split_calls == n_split_rip + 1 and split_calls[#split_calls] == 1,
  "...as one part, its own body")
local ig2 = API.IGNORED[#API.IGNORED]
check(ig2 ~= nil and ig2.b == asm.root and (ig2.secs or 0) > 0,
  "...and passes through the hull for a moment instead of being shoved off it")
check(#controller_env.chutes == n_chutes_rip - 1,
  "...and the craft stops dragging a canopy it no longer has")
check(controller_env.piloting == true, "...while the craft (pod and all) keeps flying")
asm.vel = { x = 0, y = 0, z = 0 }
step(2)

-- (After the landing tests: those need the legs, which hang off this tank.)
-- A killing blow on the tank (>= tol 3.5, < shatter 13): it explodes, shears off
-- as its own single-part wreck, and — a fuel tank against the ground — craters.
-- (The tank's blast concusses neighbours but doesn't destroy them here, so it's
-- still exactly one split.)
local n_split = #split_calls
local n_crater = #API.CRATERS
local legs_aboard = false -- (the drift landing above may already have cost the legs)
for _, n in ipairs(nodes) do
  if n.parent == asm.root and n.name == "PartLegs" then legs_aboard = true end
end
API.IMPACTS = { { part = tank_node.id, impulse = 0.0, speed = 8.0, speedAbs = 8.0,
                  x = tank_node.x, y = tank_node.y, z = tank_node.z } }
step(2)
local exploded = false
for _, e in ipairs(API.EFFECTS) do
  if e.name == "Explosion" then exploded = true end
end
check(exploded, "a full-strength hit explodes the part")
-- The tank goes as its own one-part wreck — and the landing legs BOLTED TO IT
-- (uid 8, parent = the tank) have nothing holding them any more, so they come
-- away too, as a body of their own. A part's mount breaking used to leave its
-- children welded in mid-air to the craft by nothing.
local want = legs_aboard and 2 or 1
check(#split_calls == n_split + want and split_calls[n_split + 1] == 1
    and (not legs_aboard or split_calls[n_split + 2] == 1),
  string.format("the broken part shears off as its own wreck%s (splits: %d)",
    legs_aboard and ", and the legs it carried come away separately" or "",
    #split_calls - n_split))
local legs_gone = true
for _, n in ipairs(nodes) do
  if n.parent == asm.root and n.name == "PartLegs" then legs_gone = false end
end
check(legs_gone, "the legs bolted to the broken tank are no longer part of the craft")
check(#API.CRATERS > n_crater, "a tank blast against the ground digs a crater")

asm.vel = { x = 47, y = 0, z = 0 }         -- back to orbital speed for the ram

-- A CATASTROPHIC strike (>= shatter speed 20) fails the WHOLE airframe: every
-- surviving part bursts loose as wreckage (many splits, not one), a big crater,
-- and the pilot is thrown clear. A plain pod-break never splits anything, so any
-- split increase here proves the shatter path fired.
local n_split2 = #split_calls
local n_crater2 = #API.CRATERS
-- Counted against what is actually STILL ON the ship, not a fixed number: the
-- tests above legitimately cost it a tank, a leg and a chute, and "every
-- surviving part bursts loose" is the claim worth asserting anyway. `shatter`
-- leaves the last child in place so the compound stays valid, hence live − 1.
local live_before = 0
for _, n in ipairs(nodes) do
  if n.parent == asm.root and n.valid ~= false then live_before = live_before + 1 end
end
API.IMPACTS = { { part = pod_node.id, impulse = 0.0, speed = 26.0, speedAbs = 26.0,
                  x = pod_node.x, y = pod_node.y, z = pod_node.z } }
step(2)
check(live_before >= 2 and #split_calls - n_split2 == live_before - 1, string.format(
  "a catastrophic hit bursts every surviving part loose (splits: %d of %d live)",
  #split_calls - n_split2, live_before))
check(#API.CRATERS > n_crater2, "the breakup leaves a crater")
check(controller_env.piloting == false, "the breakup ends the flight")
check(astro.visible == true, "the pilot is thrown clear (astronaut visible)")
-- AT REST. The crew used to be stood down carrying the wreck's own velocity —
-- which at the moment of a breakup is the worst number in the flight — and an
-- astronaut ejected at it does not land near the crash, they leave. That is the
-- "sent flying off infinitely into the void and got softlocked" half of the
-- report, and losing the ship must not also cost the save.
check(astro.vx == 0 and astro.vy == 0 and astro.vz == 0, string.format(
  "...and thrown clear AT REST, not at the wreck's velocity (%.0f,%.0f,%.0f)",
  astro.vx or -1, astro.vy or -1, astro.vz or -1))

-- ── captions ────────────────────────────────────────────────────────────────
-- A whole flight has now been driven through this harness. Every event that a
-- hearing player is told about by SOUND ALONE — the engines, the clamps, the
-- stages, the chutes, the ground, the hull — must have said so in text as well.
check(captioned("engines light"), "the ignition is captioned")
check(captioned("launch clamps"), "the clamps releasing is captioned")
check(captioned("stage separates"), "staging is captioned")
check(captioned("parachutes"), "the chutes opening is captioned")
check(captioned("touchdown"), "touchdown is captioned")
check(captioned("hull breaks up"), "the breakup is captioned")

-- ── verdict ─────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("SMOKE OK — %d ticks, %d logs", math.floor(T / TICK + 0.5), #logs))
  os.exit(0)
else
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  print("\n-- script logs --")
  for _, l in ipairs(logs) do print("  " .. l) end
  os.exit(1)
end
