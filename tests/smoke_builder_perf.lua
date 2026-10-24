-- SMOKE (WP1 performance, docs/builder-design.md §8.1–8.2): the real builder.lua
-- on a stubbed engine with a 1,000-part lattice (columns of ten 1 m beams, the
-- probe's craft) and then 3,000 parts.
--
--   * with a part in hand, find_snap + the node telegraphs examine fewer than
--     20,000 parts a frame (counted: perfCounters().visits) — the old builder
--     made ~8·n² extent tests (8 million at 1,000 parts)
--   * a load is time-sliced: at most 60 spawns a frame
--   * idle, holding, dragging 200 parts, and undo / redo of a 200-part delete
--     are timed (os.clock) and printed; the hard limits are generous (a CI
--     machine is not the engine), the printed figures are the evidence
--
--   luajit solar/tests/smoke_builder_perf.lua   (from the Floptle repo root)

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end

local T, TICK = 0.0, 1 / 60
local nodes, next_id = {}, 1
local spawns_this_frame, spawn_peak = 0, 0
local function make_node(name, x, y, z)
  local n = { id = next_id, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end
local API, store = {}, {}
API.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
API.destroy = function(n) n.valid = false end
local named = {}
API.find = function(name) return named[name] end
API.print, API.log = function() end, function() end
API.spawn = function(prefab, pos, cb)
  spawns_this_frame = spawns_this_frame + 1
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
}
-- a camera up and to the side looking down at 45° (rays slant through the
-- lattice, as the probe's camera does): screen = world x / (z − y) projection
local CAM = { x = 0, y = 40, z = 40 }
API.camera = {
  worldToScreen = function(x, y, z)
    local dz = (CAM.z - z) + (CAM.y - y)
    if dz <= 0.1 then return 0, 0, 0, false end
    local s = 900 / dz
    return 960 + (x - CAM.x) * s, 540 - ((y - CAM.y) - (z - CAM.z)) * s * 0.5, dz, true
  end,
  screenSize = function() return 1920, 1080 end,
  screenToRay = function(mx, my)
    local dx, dy, dz = (mx - 960) / 900, -1 - (540 - my) / 900, -1 + (540 - my) / 900
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    return CAM.x, CAM.y, CAM.z, dx / l, dy / l, dz / l
  end,
}
API.raycast = function() return nil end
API.draw = setmetatable({}, { __index = function() return function() end end })
API.audio = setmetatable({}, { __index = function() return function() end end })
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end }
API.scene = { load = function() end }
local REGENV = setmetatable({}, { __index = _G })
do
  local f = assert(loadfile("solar/scripts/parts_registry.lua"))
  setfenv(f, REGENV)
  f()
end
API.findScript = function(k) if k == "parts_registry" then return REGENV end end
API.findScripts = function() return {} end
named.BuildStats = make_node("BuildStats")
named.BuildHint = make_node("BuildHint")
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
local bnode = make_node("Builder")

local function step(n)
  local worst = 0
  for _ = 1, n or 1 do
    T = T + TICK
    spawns_this_frame = 0
    local c0 = os.clock()
    local ok, err = xpcall(env.update, debug.traceback, bnode, TICK)
    local ms = (os.clock() - c0) * 1000
    if ms > worst then worst = ms end
    if spawns_this_frame > spawn_peak then spawn_peak = spawns_this_frame end
    if not ok then failures[#failures + 1] = "update: " .. err end
    API.KEYS.edge = {}
  end
  return worst
end
local function avg_ms(n)
  local c0 = os.clock()
  step(n)
  return (os.clock() - c0) * 1000 / n
end

-- the probe's lattice: N parts, columns of ten 1 m beams (parent chains)
local function lattice(N)
  local list, uid = {}, 0
  local cols = math.ceil(N / 10)
  local side = math.ceil(math.sqrt(cols))
  for c = 0, cols - 1 do
    local gx, gz = (c % side) * 1.5 - side * 0.75, math.floor(c / side) * 1.5 - side * 0.75
    local prev = 0
    for k = 0, 9 do
      if uid >= N then break end
      uid = uid + 1
      list[#list + 1] = { uid = uid, id = "beam1", x = gx, y = 0.5 + k, z = gz, yaw = 0, pitch = 0, roll = 0,
                          parent = prev, att = prev ~= 0 and "top" or "", sym = 0, mir = "", stage = 0 }
      prev = uid
    end
  end
  return list
end

local function load_n(N)
  store["shipyard.blueprint"] = { parts = lattice(N) }
  local c0 = os.clock()
  env.reload()
  local frames = 0
  while env.loadProgress() and frames < 1000 do step(1); frames = frames + 1 end
  step(2)
  return (os.clock() - c0) * 1000, frames
end

env.start(bnode)
step(2)
local out = {}
for _, N in ipairs({ 1000, 3000 }) do
  spawn_peak = 0
  local load_ms, frames = load_n(N)
  check(env.partCount == N, N .. " parts on the stand (" .. env.partCount .. ")")
  check(spawn_peak <= 60, string.format("load is time-sliced: ≤ 60 spawns a frame (peak %d over %d frames)", spawn_peak, frames))
  -- idle
  local idle = avg_ms(30)
  -- a part in hand, the cursor over the middle of the lattice
  MOUSE.x, MOUSE.y = 960, 600
  env.pick("beam1")
  step(12)
  local visits = 0
  for _ = 1, 10 do
    step(1)
    visits = math.max(visits, env.perfCounters().visits)
  end
  local hand = avg_ms(30)
  check(env.held() ~= nil, "a part is in hand")
  if N == 1000 then
    check(visits < 20000, string.format("1,000 parts, part in hand: %d part visits a frame (< 20,000)", visits))
  end
  API.KEYS.edge.escape = true
  step(2)
  -- a 200-part selection dragged (lifted with hold, the cursor moving)
  local sel = {}
  for u = 1, 200 do sel[#sel + 1] = u end
  env.select(sel, "set")
  env.hold(sel)
  local drag = 0
  for i = 1, 20 do
    MOUSE.x = 900 + i * 4
    local c0 = os.clock()
    step(1)
    drag = drag + (os.clock() - c0) * 1000
  end
  drag = drag / 20
  local carried = env.held() and #env.held() or 0
  API.KEYS.edge.escape = true
  step(2)
  -- undo / redo of a 200-part delete
  env.cmd("delete", { uids = sel, only = true })
  local c0 = os.clock()
  env.undoStep()
  local undo_ms = (os.clock() - c0) * 1000
  c0 = os.clock()
  env.redoStep()
  local redo_ms = (os.clock() - c0) * 1000
  env.undoStep()
  while env.loadProgress() do step(1) end
  check(env.partCount == N, "undo brings the 200 back")
  out[#out + 1] = string.format("N=%d load %.0f ms (%d frames, ≤%d spawns/frame) · idle %.2f ms · hand %.2f ms (%d visits) · drag %d parts %.2f ms · undo %.1f ms · redo %.1f ms",
    N, load_ms, frames, spawn_peak, idle, hand, visits, carried, drag, undo_ms, redo_ms)
  check(hand < 50 and idle < 50, string.format("N=%d: no frame near the watchdog (idle %.1f, hand %.1f ms)", N, idle, hand))
end
for _, l in ipairs(out) do print("  " .. l) end

if #failures == 0 then
  print(string.format("BUILDER PERF SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("BUILDER PERF SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
