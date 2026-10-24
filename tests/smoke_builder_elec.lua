-- SMOKE: the builder's electronics (builder.lua + the real electronics.lua).
--
--   * the new parts are in the catalogue: Probe Core, Comm Whip, Relay Dish,
--     Deep Space Dish, Floodlight — each with its modules;
--   * a craft with only a probe core may launch (a command part is a pod OR a
--     probe core), and one with nothing to command it may not;
--   * the POWER and COMMS lines quote the craft's battery store, solar supply,
--     idle draw and how far its antennas reach home;
--   * the ACTION GROUPS editor: the standard set until you edit, then yours;
--     ticking an action on a symmetry ring binds every member; clearing and
--     resetting; the saved blueprint carries the groups and every part's
--     modules — as strings, inside save.set's four-table depth limit — and a
--     reload brings the groups back.
--
--   luajit solar/tests/smoke_builder_elec.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local Eenv = setmetatable({}, { __index = _G })
local ec = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(ec, Eenv)
ec()
local E = Eenv
E.valid = true
-- The part registry (scripts/parts_registry.lua) is its own pure script now,
-- reached with findScript("parts_registry"): load it from disk.
local REGENV = setmetatable({}, { __index = _G })
do
  local rc = assert(loadfile("solar/scripts/parts_registry.lua"))
  setfenv(rc, REGENV)
  rc()
end

local T = 0
local nodes = {}
local function make_node(name, x, y, z)
  local n = { id = #nodes + 1, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  nodes[#nodes + 1] = n
  return n
end
local store = {}
local stub = setmetatable({}, { __index = function() return function() end end })
local API = {
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  destroy = function(n) n.valid = false end,
  find = function(name) for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end end,
  print = function() end, log = function() end,
  spawn = function(prefab, pos, cb) local n = make_node(prefab, pos.x, pos.y, pos.z) if cb then cb(n) end end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k)
    if k == "electronics" then return E end
    if k == "parts_registry" then return REGENV end
    return nil
  end,
  findScripts = function() return {} end,
  input = { key = function() return false end, pressed = function() return false end, button = function() return false end,
            mouse = function() return 0, 0 end },
  camera = { worldToScreen = function() return 0, 0, 1, true end, screenSize = function() return 1280, 720 end,
             screenToRay = function() return 0, 10, 0, 0, -1, 0 end },
  draw = stub, audio = stub, scene = { load = function() end }, raycast = function() return nil end,
}
make_node("BuildStats"); make_node("BuildHint")
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })

-- A blueprint on the stand: probe core on a battery, two solar panels in a
-- symmetry ring, a whip, a light, a relay dish on top.
local function P(t)
  local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0 }
  for k, v in pairs(t) do d[k] = v end
  return d
end
store["shipyard.blueprint"] = { parts = {
  P{ uid = 1, id = "probe", x = 0, y = 1.21, z = 0, parent = 2, att = "top" },
  P{ uid = 2, id = "battery", x = 0, y = 0.5, z = 0 },
  P{ uid = 3, id = "solar", x = 0.95, y = 0.5, z = 0, parent = 2, att = "radial", sym = 1 },
  P{ uid = 4, id = "solar", x = -0.95, y = 0.5, z = 0, yaw = math.pi, parent = 2, att = "radial", sym = 1 },
  P{ uid = 5, id = "antenna", x = 0, y = 0.5, z = 0.62, parent = 2, att = "radial" },
  P{ uid = 6, id = "light", x = 0, y = 0.5, z = -0.65, parent = 2, att = "radial" },
  P{ uid = 7, id = "dish", x = 0, y = 1.82, z = 0, parent = 1, att = "top" },
} }

local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
env.start(make_node("Builder"))

-- ── the catalogue ───────────────────────────────────────────────────────────
for _, id in ipairs({ "probe", "antenna", "dish", "dishL", "light" }) do
  local d = env.partInfo(id)
  check(d and d.mods and #d.mods > 0, "the catalogue has " .. id .. " with its modules")
end
local elec_section = nil
for _, s in ipairs(env.catalogue()) do if s.title == "ELECTRICAL" then elec_section = s end end
check(elec_section and #elec_section.ids >= 5, "an ELECTRICAL section in the catalogue")
check(E.modOf(env.partInfo("dishL"), "antenna").power > E.modOf(env.partInfo("dish"), "antenna").power * 10,
  "the deep space dish out-reaches the relay dish by an order of magnitude")
check(math.sqrt(E.modOf(env.partInfo("dishL"), "antenna").power * E.COMMS.station) > 2.0e6,
  "the deep space dish reaches the next star from home (sqrt(P·station) > 2,000 km)")

-- ── launching a probe ───────────────────────────────────────────────────────
local chk = env.launchCheck()
check(not chk.block and chk.has.probe and chk.has.command, "a probe-only craft may launch")

-- ── power & comms readout ───────────────────────────────────────────────────
local ps = env.powerStats()
check(ps and ps.store == 200 and math.abs(ps.solar - 2.0) < 1e-6, "power: 150 + 50 EC stored, 2 × 1 EC/s of panels")
check(ps.idle > 0.6 and ps.relay and ps.reachHome > 2e5, "comms: the dish relays and reaches home over 200 km")
local stats = nodes[1].text or ""
check(stats:find("POWER", 1, true) and stats:find("COMMS", 1, true), "the header card quotes POWER and COMMS")

-- ── action groups ───────────────────────────────────────────────────────────
local g = env.groupsNow()
check(E.isBound(g, "deploy", 3, "deployed.toggle") and E.isBound(g, "deploy", 7, "deployed.toggle"),
  "until edited, Deploy holds the panels and the antennas")
check(not env.groupsEdited(), "...and the groups read as the standard set")
check(env.groupsToggle("1", 3, "deployed.on") == true, "tick Extend on one panel for group 1")
g = env.groupsNow()
check(E.isBound(g, "1", 3, "deployed.on") and E.isBound(g, "1", 4, "deployed.on"), "...and its ring partner is bound too")
check(env.groupsEdited(), "editing makes the groups the player's own")
env.groupsToggle("2", 6, "lit.toggle")
env.groupsRename("2", "Night ops")
env.doSave()
local bp = store["shipyard.blueprint"]
local function depth_ok(v, d)
  d = d or 0
  if type(v) ~= "table" then return true end
  if d > 15 then return false end
  for _, x in pairs(v) do if not depth_ok(x, d + 1) then return false end end
  return true
end
check(depth_ok(bp), "the saved blueprint fits save.set's 16-table limit")
local probe_rec
for _, d in ipairs(bp.parts) do if d.id == "probe" then probe_rec = d end end
check(probe_rec and type(probe_rec.mods) == "table" and #E.modsOf(probe_rec) == 4,
  "each part carries its modules (a plain table)")
local back = E.unpackGroups(bp.groups)
check(E.isBound(back, "1", 4, "deployed.on") and back["2"] and back["2"].name == "Night ops",
  "the blueprint carries the edited groups, names and all")
-- reload: the groups come back
env.groupsReset()
check(not env.groupsEdited(), "Standard set throws the edits away")
env.groupsClear("1")
check(env.groupsEdited() and #(env.groupsNow()["1"] or { binds = {} }).binds == 0, "Clear group empties one group")

-- a craft with nothing to command it can't launch
store["shipyard.blueprint"] = { parts = { P{ uid = 1, id = "battery", x = 0, y = 0.5, z = 0 } } }
env.start(make_node("Builder"))
-- (start re-reads the blueprint; the old parts are replaced)
local chk2 = env.launchCheck()
check(chk2.block and chk2.block:find("command part", 1, true), "no pod and no probe core: LAUNCH is refused")

if #failures == 0 then
  print(string.format("BUILDER ELECTRONICS SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("BUILDER ELECTRONICS SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
