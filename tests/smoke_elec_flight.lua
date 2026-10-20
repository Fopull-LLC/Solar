-- SMOKE: the electronics of a craft in flight (vessel_controller.lua + the real
-- scripts/electronics.lua), offline. A probe satellite — probe core, battery,
-- two solar panels, a whip, a relay dish, a floodlight, an engine — is rolled
-- out from a blueprint with edited action groups, and then:
--
--   * the parts' states come up (legs down, panels stowed, batteries full),
--     the groups load from the blueprint;
--   * control follows the rules: a probe with power AND a link answers; no
--     link → NO SIGNAL; flat batteries → NO POWER; groups refuse without control;
--   * Deploy (U) extends every panel/antenna as one, the panels then charge the
--     batteries in sunlight and stop in a planet's shadow;
--   * group 1 lights the floodlight (its lamp comes on), an engine action shuts
--     an engine down, a Decouple action fires its stage out of order;
--   * the radios add up (stowed whip off, extended on; the dish relays) and the
--     craft reports it to the comms network;
--   * the fleet record it hands flight_ops fits save.set's 16-table limit.
--
--   luajit solar/tests/smoke_elec_flight.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

-- ── the rulebook ────────────────────────────────────────────────────────────
local Eenv = setmetatable({}, { __index = _G })
local ec = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(ec, Eenv)
ec()
local E = Eenv
E.valid = true

-- ── a tiny world: a star, a planet; the craft on the planet's day side ──────
local T = 0
local star = { name = "Sun", x = 20000, y = 20000, z = 0, radius = 500, mu = 1e10, soi = -1, vx = 0, vy = 0, vz = 0 }
local planet = { name = "Home", x = 20000, y = 0, z = 0, radius = 300, mu = 7e5, soi = 3000, vx = 0, vy = 0, vz = 0 }
local bodies = { star, planet }

local function node(name, x, y, z)
  local n = { id = math.random(1, 1e6), name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              vx = 0, vy = 0, vz = 0, yaw = 0, pitch = 0, roll = 0, scale_x = 1, scale_y = 1, scale_z = 1,
              kids = {}, comps = {} }
  function n:children() return self.kids end
  function n:getcomponent(k) return self.comps[k] end
  return n
end

-- the craft sits 400 m sunward of the planet's centre (day side, the star
-- straight "up" +Y, square to the panels' long axes), nose up +Y
local craft = node("Sat One", 20000, 400, 0)
craft.id = 4242
local astro = node("Astronaut", 20000, 310, 0)

local function R(t)
  local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0, cost = 100, h = 0.5,
              mass = 0.1, kind = "structural", rx = 0.4, rz = 0.4 }
  for k, v in pairs(t) do d[k] = v end
  return d
end
local parts = {
  R{ uid = 1, id = "probe", kind = "probe", x = 0, y = 3.5, z = 0, parent = 2,
     mods = { { type = "command", crew = 0, draw = 0.06 }, { type = "wheel", torque = 0.6, draw = 0.35 },
              { type = "battery", ec = 50 }, { type = "antenna", power = 100, rate = 1, draw = 0.02 } } },
  R{ uid = 2, id = "battery", x = 0, y = 2.8, z = 0, parent = 3, mods = { { type = "battery", ec = 150 } } },
  R{ uid = 5, id = "solar", x = 0.95, y = 2.8, z = 0, parent = 2, sym = 1, att = "radial",
     mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } },
  R{ uid = 6, id = "solar", x = -0.95, y = 2.8, z = 0, yaw = math.pi, parent = 2, sym = 1, att = "radial",
     mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } },
  R{ uid = 7, id = "antenna", x = 0, y = 2.8, z = 0.62, yaw = -math.pi / 2, parent = 2, att = "radial", h = 0.9,
     mods = { { type = "antenna", power = 2250, rate = 4, draw = 0.12 }, { type = "deploy", anim = "whip" } } },
  R{ uid = 8, id = "light", x = 0, y = 2.8, z = -0.65, parent = 2, att = "radial", mods = { { type = "light", draw = 0.2 } } },
  R{ uid = 9, id = "dish", x = 0, y = 4.1, z = 0, parent = 1, comms = 1,
     mods = { { type = "antenna", power = 2.25e5, relay = true, dish = true, rate = 12, draw = 0.6 },
              { type = "deploy", anim = "dish" } } },
  R{ uid = 10, id = "decoupler", x = 0, y = 2.2, z = 0, parent = 3, decouple = 1, stage = 1 },
  R{ uid = 3, id = "tankS", kind = "tank", x = 0, y = 1.8, z = 0, parent = 4, fuel = 80, fuel_t = 0.005 },
  R{ uid = 4, id = "engineS", kind = "engine", x = 0, y = 0.65, z = 0, thrust = 30, burn = 0.6, ve = 160 },
}
-- the decoupler sits between the battery stack and the tank
parts[2].parent = 10; parts[10].parent = 3
for _, d in ipairs(parts) do
  local c = node("Part" .. d.id, d.x, d.y, d.z)
  c.yaw = d.yaw
  if d.id == "light" then
    local lamp = node("Lamp", 0.6, 0, 0)
    lamp.comps.PointLight = { intensity = 0 }
    c.kids[1] = lamp
  end
  craft.kids[#craft.kids + 1] = c
end
local groups = {}
E.bind(groups, "1", 8, "lit.toggle")
E.bind(groups, "2", 4, "running.off")
E.bind(groups, "3", 10, "decouple")
E.bind(groups, "deploy", 5, "deployed.toggle"); E.bind(groups, "deploy", 6, "deployed.toggle")
E.bind(groups, "deploy", 7, "deployed.toggle"); E.bind(groups, "deploy", 9, "deployed.toggle")
local bp = { parts = {}, groups = E.packGroups(groups) }
for i, d in ipairs(parts) do bp.parts[i] = E.packRecord(d) end

-- ── save.set's depth rule (16 tables since 0.117, floptle/0422) ─────────────
local function depth_ok(v, d)
  d = d or 0
  if type(v) ~= "table" then return true end
  if d > 15 then return false end
  for _, x in pairs(v) do if not depth_ok(x, d + 1) then return false end end
  return true
end
check(depth_ok(bp), "a blueprint with modules and groups fits save.set's depth limit")

-- ── the engine, stubbed ─────────────────────────────────────────────────────
local store = { ["shipyard.blueprint"] = bp, ["base.body"] = "Home" }
local link = { connected = true, strength = 0.8, hops = 1, names = { "Ground station" } }
local splits = 0
local caps = {}
local info = { origin = { x = craft.x, y = craft.y, z = craft.z }, vel = { x = 0, y = 0, z = 0 },
               angVel = { x = 0, y = 0, z = 0 }, grounded = false, anchored = false, mass = 1.5,
               com = { x = craft.x, y = craft.y + 2, z = craft.z }, parts = craft.kids }
local stub = setmetatable({}, { __index = function() return function() end end })
local env
env = setmetatable({
  time = 0,
  log = function() end, print = function() end,
  caption = function(s) caps[#caps + 1] = s end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  find = function(n) if n == "Astronaut" then return astro end return nil end,
  findScript = function(k)
    if k == "electronics" then return E end
    if k == "comms" then return { valid = true, statusOf = function() return link end } end
    return nil
  end,
  findScripts = function(k) if k == "vessel_controller" then return { env } end return {} end,
  space = {
    bodies = function() return bodies end,
    body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end end,
    dominant = function() return "Home" end,
    elements = function() return nil end, warp = function() return 1 end, time = function() return T end,
  },
  assembly = setmetatable({
    info = function() return info end,
    split = function(n, list, cb) splits = splits + 1 end,
  }, { __index = function() return function() end end }),
  input = { pressed = function() return false end, key = function() return false end, button = function() return false end,
            mouse = function() return 0, 0 end },
  audio = stub, terrain = stub, draw = stub, physics = stub, camera = stub, spawn = function() end,
  spawnEffect = function() end, destroy = function() end, raycast = function() return nil end,
}, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
env.node = craft
env.valid = true
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, env)
chunk()

local function late(n, dt)
  for _ = 1, n do
    T = T + (dt or 0.05)
    env.time = T
    env.lateUpdate(craft, dt or 0.05)
  end
end

env.start(craft)
check(env.podCrewed == false, "a probe-only craft: the probe core commands it, no seat")
local fp = env.fleetParts()
local recs = {}
for _, d in ipairs(fp.parts) do recs[d.uid] = d end
check(recs[1].st and recs[2].st.charge == 150 and recs[1].st.charge == 50, "batteries roll out full")
check(recs[5].st.deployed == false and recs[9].st.deployed == false, "panels and dishes roll out stowed")
check(E.isBound(env.ctlGroups, "1", 8, "lit.toggle") and E.isBound(env.ctlGroups, "deploy", 9, "deployed.toggle"),
  "the craft flies with the blueprint's action groups")

-- ── control ─────────────────────────────────────────────────────────────────
env.piloting = true
late(4)
local cs = env.controlState()
check(cs.can and cs.mode == "probe", "a powered probe with a link home is under command (" .. tostring(cs.why) .. ")")
link = { connected = false, strength = 0, hops = 0, names = {} }
late(4)
cs = env.controlState()
check(not cs.can and cs.why and cs.why:find("SIGNAL"), "no path home: NO SIGNAL (" .. tostring(cs.why) .. ")")
check(env.activateGroup("1") == false and recs[8].st.lit == false, "...and the groups don't answer")
link = { connected = true, strength = 0.8, hops = 1, names = { "Ground station" } }
late(4)

-- ── deploy as one, then the sun ─────────────────────────────────────────────
check(env.activateGroup("deploy") == true, "Deploy (U) fires with control")
check(recs[5].st.deployed and recs[6].st.deployed and recs[7].st.deployed and recs[9].st.deployed,
  "Deploy extends both panels, the whip and the dish together")
env.piloting = false -- unpiloted, the craft still folds out (lateUpdate)
late(40, 0.05)
check(env.partAnim(5) > 0.99 and env.partAnim(9) > 0.99, "...and they fold out (" .. env.partAnim(5) .. ")")
env.piloting = true
env.elecSetCharge(50)
local c0 = 0
for _, d in pairs(recs) do if d.st.charge then c0 = c0 + d.st.charge end end
late(40, 0.1)
local c1 = 0
for _, d in pairs(recs) do if d.st.charge then c1 = c1 + d.st.charge end end
check(c1 > c0 + 0.5, string.format("panels charge the batteries in sunlight (%.1f → %.1f EC)", c0, c1))
local node_out = env.commsNode()
check(node_out and node_out.relay > 0 and node_out.any > 2.25e5 * 0.99, "the dish is out: the craft is a relay")

-- into the planet's shadow (far side from the star)
craft.y = -400
info.origin.y = craft.y
late(20, 0.1)
local c2 = 0
for _, d in pairs(recs) do if d.st.charge then c2 = c2 + d.st.charge end end
check(c2 < c1, string.format("in the planet's shadow the batteries drain (%.1f → %.1f EC)", c1, c2))

-- flat: NO POWER, and the radios drop off the network
env.elecSetCharge(0)
late(4, 0.1)
cs = env.controlState()
check(not cs.can and cs.why and cs.why:find("POWER"), "flat batteries in the dark: NO POWER (" .. tostring(cs.why) .. ")")
check(env.commsNode().any == 0, "...and its radios go quiet")
craft.y = 400
info.origin.y = craft.y
env.elecSetCharge(150)
late(6, 0.1)
check(env.controlState().can, "power back, control back")

-- ── group 1: the light ──────────────────────────────────────────────────────
env.activateGroup("1")
check(recs[8].st.lit == true, "group 1 switches the floodlight on")
env.piloting = false
late(2)
local lamp = craft.kids[6].kids[1]
check(lamp and lamp.comps.PointLight.intensity > 1, "...and its lamp lights")
env.piloting = true

-- ── engines and decouplers off the staging ──────────────────────────────────
env.activateGroup("2")
check(recs[4].st.running == false, "group 2 shuts the engine down")
check(env.partAction(4, "running.on") and recs[4].st.forced == true, "Activate by hand forces it to burn")
local before = splits
env.activateGroup("3")
check(splits == before + 1, "group 3 fires the decoupler (a staging event, out of order)")

-- ── the whip alone: stowed off, extended on ─────────────────────────────────
local s1 = E.antennaSummary({ { uid = 7, mods = parts[5].mods and recs[7].mods, st = { deployed = false } } })
check(s1.n == 0, "a stowed whip doesn't transmit")

-- ── the fleet record fits the save ──────────────────────────────────────────
local fleetish = { c1 = { parts = {}, groups = env.fleetParts().groups } }
for i, d in ipairs(env.fleetParts().parts) do fleetish.c1.parts[i] = E.packRecord(d) end
check(depth_ok(fleetish), "a fleet record (modules + state as tables) fits save.set's 16-table limit")
check(type(fleetish.c1.parts[1].st) == "table" and fleetish.c1.parts[1].st ~= env.fleetParts().parts[1].st,
  "...its state a copy, not the live record's own table")
local back = E.decodeState(fleetish.c1.parts[1].st)
check(type(back) == "table" and back.charge ~= nil, "...and its state reads back")

if #failures == 0 then
  print(string.format("ELEC FLIGHT SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("ELEC FLIGHT SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
