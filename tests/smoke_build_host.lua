-- SMOKE: the in-world VAB host (WP6, docs/builder-design.md §9).
--
--   luajit solar/tests/smoke_build_host.lua
--
-- 1. scenes/builder_overlay.ron is what tools/gen_builder_overlay.lua makes of
--    scenes/builder.ron today (edit builder.ron, run the tool), with none of
--    the standalone-only nodes, its camera off, and every parent re-pointed.
-- 2. scripts/build_host.lua's flow on a stub engine: E parks the crew and
--    takes the keys, the overlay landing hands it the view, LEAVE gives all
--    of it back with no scene load, and LAUNCH fades to the in-place rollout.

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function read(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ── 1. the overlay is in step with builder.ron ──────────────────────────────
GEN_AS_LIB = true
local gen = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/tools/gen_builder_overlay.lua"))
setfenv(chunk, gen)
chunk()
local src = read("solar/scenes/builder.ron")
local have = read("solar/scenes/builder_overlay.ron")
check(gen.overlay(src) == have, "builder_overlay.ron is out of date — run luajit tools/gen_builder_overlay.lua")

local doc = gen.parse(have)
local names = {}
for i, n in ipairs(doc.nodes) do names[i - 1] = n.name end
for _, n in ipairs(doc.nodes) do
  check(not gen.STANDALONE[n.name], "the overlay carries standalone-only node " .. tostring(n.name))
  if n.parent then check(names[n.parent] ~= nil, "node " .. n.name .. " points at a parent index past the list") end
end
local byname = {}
for _, n in ipairs(doc.nodes) do byname[n.name] = n end
check(byname["Builder"] and byname["Builder UI"] and byname["Builder Camera"], "the overlay has the builder, its UI and its camera")
check(byname["BuilderGraph"] ~= nil, "the overlay has the rulebook managers")
local cam = byname["Builder Camera"] and table.concat(byname["Builder Camera"].lines, "\n") or ""
check(cam:find("active: false", 1, true) ~= nil, "the overlay's camera starts inactive (build_host hands it the view)")
-- every UI child still hangs off "Builder UI" by index as well as by id
for _, n in ipairs(doc.nodes) do
  local body = table.concat(n.lines, "\n")
  if body:find("parent_id: Some(38)", 1, true) then
    check(names[n.parent] == "Builder UI", n.name .. " re-pointed at " .. tostring(names[n.parent]))
  end
end
local full = gen.parse(src)
local has_host = false
for _, n in ipairs(full.nodes) do if n.name == "Build Host" then has_host = true end end
check(has_host, "standalone builder.ron carries its Build Host")
check(not src:find('name: "Hangar Floor"', 1, true), "the old box hangar is gone from builder.ron")
check(read("solar/scenes/system.ron"):find('kind: "build_host"', 1, true) ~= nil, "system.ron carries the world's Build Host")

-- ── 2. the flow on a stub engine ─────────────────────────────────────────────
local log_lines, loads, unloads = {}, {}, {}
local function V(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function node(name, extra)
  local n = { name = name, valid = true, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, visible = true, comps = {} }
  function n:getcomponent(k) return self.comps[k] end
  function n:destroy() self.valid = false end
  function n:toWorld(p) return V(p.x, p.y, p.z) end
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end
local nodes = {
  ["Astronaut"] = node("Astronaut", { x = 100, y = 5, z = 0 }),
  ["VabInterior"] = node("VabInterior"),
  ["Camera 1"] = node("Camera 1"),
  ["Game Manager"] = node("Game Manager"),
}
nodes["Camera 1"].comps.Camera = { active = true }
local host_ui = { visible = false, opacity = 1 }
local host_node = node("Build Host")
host_node.comps.UiElement = host_ui
local gm = { loading = false, inputOwner = nil }
local vs = { calls = 0 }
function vs.launchNow(site) vs.calls, vs.site = vs.calls + 1, site return true end
function vs.launchState() return "ready" end
local vc = { piloting = true }
local saved = {}
local env = setmetatable({
  params = { fade = 0.35, hold = 8.0, autosave = 2.0 },
  time = 0,
  log = function(s) log_lines[#log_lines + 1] = s end,
  find = function(n) local x = nodes[n]; if x and x.valid then return x end return nil end,
  findScript = function(k)
    if k == "game_manager" then return gm end
    if k == "vessel_spawner" then return vs end
    return nil
  end,
  findScripts = function(k) if k == "vessel_controller" then return { vc } end return {} end,
  createNode = function(name, parent, cb) local n = node(name); nodes[name] = n; cb(n) end,
  scene = { load = function(n, o) loads[#loads + 1] = { n, o } end, unload = function(n) unloads[#unloads + 1] = n end },
  space = { dominant = function() return "Vever" end, body = function() return { x = 0, y = 0, z = 0 } end },
  save = { set = function(k, v) saved[k] = v end, get = function(k) return saved[k] end, flush = function() end },
  input = {},
  vec3 = V,
}, { __index = _G })
local hc = assert(loadfile("solar/scripts/build_host.lua"))
setfenv(hc, env)
hc()
local H = env
H.start(host_node)
check(H.mode == "world", "with a Game Manager beside it the host is the world's")

check(H.enter() == true, "E at the VAB opens the builder")
check(gm.inputOwner == "builder", "the builder takes the keys")
check(not nodes["Astronaut"].visible, "the crew is parked out of sight")
check(nodes["BuildFrame"] and nodes["BuildFrame"].y == H.FRAME_Y, "the BuildFrame stands on the ML-1 deck")
check(loads[1] and loads[1][1] == "builder_overlay" and loads[1][2].additive == true, "the overlay is loaded ADDITIVELY")
check(H.inWorld() and H.frameNode() == nodes["BuildFrame"], "the builder finds its frame through the host")

-- the overlay lands
nodes["Builder"] = node("Builder")
nodes["Builder Camera"] = node("Builder Camera")
nodes["Builder Camera"].comps.Camera = { active = false }
env.time = 0.1
H.update(host_node, 0.1)
check(H.state == "building", "the host sees the overlay arrive")
check(nodes["Builder Camera"].comps.Camera.active == true and nodes["Camera 1"].comps.Camera.active == false,
  "the builder's camera has the view, the world's is off")

-- the crew stays put while the planet moves
nodes["Astronaut"].x = 140
env.time = 0.2
H.update(host_node, 0.1)
check(nodes["Astronaut"].x == 100, "the parked crew is pinned where they pressed E")

-- LEAVE
check(H.leave() == true, "LEAVE")
check(unloads[1] == "builder_overlay", "leaving unloads the overlay")
check(#loads == 1, "leaving loads no scene")
check(gm.inputOwner == nil and nodes["Astronaut"].visible, "the crew is back on foot with the keys")
check(nodes["Camera 1"].comps.Camera.active == true, "the world's camera has the view again")
check(not nodes["BuildFrame"].valid, "the BuildFrame (and the stand under it) went with the builder")

-- LAUNCH
H.enter()
nodes["Builder"].valid, nodes["Builder Camera"].valid = true, true
env.time = 1.0
H.update(host_node, 0.1)
check(H.state == "building", "back in the builder")
check(H.rollout("runway") == true, "LAUNCH ▸ RUNWAY")
local t = 1.0
for _ = 1, 40 do
  t = t + 0.05
  env.time = t
  H.update(host_node, 0.05)
end
check(vs.calls == 1 and vs.site == "runway", "the craft is rolled out in place by vessel_spawner")
check(saved["shipyard.pilot"] == 1, "the pilot seat is handed over as before")
check(#loads == 2, "no world reload on launch (only the two overlay loads)")
check(H.state == "idle" and not host_ui.visible, "the fade is back up and the host is idle")
check(gm.inputOwner == nil, "the world has its keys back after the rollout")

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("BUILD HOST SMOKE OK — %d checks passed", passed))
