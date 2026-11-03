-- SMOKE: debris_pack.lua offline. Spent stages (bare roots of tagged parts)
-- far from the camera and the flown craft are packed into `debris.packed`
-- and taken out of the scene; near again they are built where they are now:
--   * a far landed stage packs after PACK_HOLD, body-relative, with its
--     parts' prefabs, local poses and the flight's tag; a near one does not;
--   * a craft with a live controller is never packed; a lost one is debris;
--   * the planet moves on: a landed piece comes back where it lay on its body;
--   * an orbiting piece is carried along its conic (space.propagate) to now;
--   * forgetTag (a revert) drops what the flight shed; active = false brings
--     everything back.
--
--   luajit solar/tests/smoke_debris_pack.lua

local failures, passed = {}, 0
local function ok(c, msg) if c then passed = passed + 1 else failures[#failures + 1] = msg end end

local T, ST = 0.0, 0.0
local next_id = 1
local all = {}
local function node(name, x, y, z, parent)
  local n = { id = next_id, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              yaw = 0, pitch = 0, roll = 0, parent = parent, _tags = {}, _kids = {} }
  next_id = next_id + 1
  function n:children() local o = {}; for _, c in ipairs(self._kids) do if c.valid then o[#o + 1] = c end end; return o end
  function n:addTag(t) self._tags[t] = true end
  function n:hasTag(t) return self._tags[t] == true end
  function n:setAngles(y, p, r) self.yaw, self.pitch, self.roll = y, p, r end
  setmetatable(n, { __index = function(t, k)
    if k == "tags" then local o = {}; for tg in pairs(t._tags) do o[#o + 1] = tg end; table.sort(o); return o end
  end })
  if parent then parent._kids[#parent._kids + 1] = n end
  all[#all + 1] = n
  return n
end
local function kill(n) n.valid = false; for _, c in ipairs(n._kids) do kill(c) end end

-- a planet that moves on its rails
local planet = { name = "Home", x = 10000, y = 0, z = 0, radius = 900, mu = 6e6, soi = 8000 }
local store = {}
local infos = {}
local queue = {}
local impulses = {}
local controllers = {}
local cam = { cam_x = planet.x, cam_y = planet.radius + 2, cam_z = 0, valid = true }
local fo = { valid = true, landing_surface = function(wx, wy, wz, ux, uy, uz)
  -- the ground at the radius under the point
  local b = planet
  local rx, ry, rz = wx - b.x, wy - b.y, wz - b.z
  local l = math.sqrt(rx * rx + ry * ry + rz * rz)
  return { x = b.x + rx / l * b.radius, y = b.y + ry / l * b.radius, z = b.z + rz / l * b.radius }
end }
local env = setmetatable({
  log = function() end, print = function() end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  findScript = function(k) if k == "planet_camera" then return cam end if k == "flight_ops" then return fo end end,
  findScripts = function(k) if k == "vessel_controller" then return controllers end return {} end,
  find = function() return nil end,
  findTagged = function(t)
    local o = {}
    for _, n in ipairs(all) do if n.valid and n._tags[t] then o[#o + 1] = n end end
    return o
  end,
  destroy = kill,
  space = {
    body = function(n) if n == "Home" then return planet end end,
    dominant = function() return "Home" end,
    time = function() return ST end,
    elements = function(x, y, z, vx, vy, vz)
      -- circular test orbits: periapsis = the distance when moving fast enough
      local r = math.sqrt((x - planet.x) ^ 2 + y ^ 2 + z ^ 2)
      local v = math.sqrt(vx * vx + vy * vy + vz * vz)
      return { periapsis = (v * v * r / planet.mu > 0.9) and r or 0 }
    end,
    -- a circle in the x-y plane about the body (enough to see it is used)
    propagate = function(x, y, z, vx, vy, vz, mu, dt)
      local r = math.sqrt(x * x + y * y)
      local w = math.sqrt(mu / r ^ 3)
      local a = math.atan2(y, x) + w * dt
      return r * math.cos(a), r * math.sin(a), z, -r * w * math.sin(a), r * w * math.cos(a), vz
    end,
  },
  assembly = {
    info = function(n) return infos[n.id] or { vel = { x = 0, y = 0, z = 0 }, grounded = false, mass = 1, com = { x = n.x, y = n.y, z = n.z } } end,
    rebuild = function(n, fn) if fn then fn(n) end end,
    impulseAt = function(n, j) impulses[#impulses + 1] = { n = n, j = j } end,
  },
  createNode = function(name, parent, fn) queue[#queue + 1] = function() fn(node(name, 0, 0, 0, parent)) end end,
  spawn = function(prefab, pos, fn, parent)
    queue[#queue + 1] = function()
      local p = node(prefab, pos.x, pos.y, pos.z, parent)
      fn(p)
    end
  end,
}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/debris_pack.lua"))
setfenv(chunk, env)
chunk()
env.start({})

local function drain() while #queue > 0 do local q = table.remove(queue, 1); q() end end
local function tick(secs)
  local n = math.floor(secs / 0.25 + 0.5)
  for _ = 1, n do
    T = T + 0.25; ST = ST + 0.25; env.time = T
    planet.x = planet.x + 1.5   -- on its rails, carrying what lies on it
    for _, n in ipairs(all) do if n.valid and n.parent == nil then n.x = n.x + 1.5 end end
    cam.cam_x = cam.cam_x + 1.5
    env.update({}, 0.25)
    drain()
  end
end

-- a spent stage lying on the ground 1.5 km round the planet from the camera
local function stage(name, bx, by, bz, tag)
  local r = node(name, planet.x + bx, by, bz)
  for i, id in ipairs({ "PartTankM", "PartSkipper" }) do
    local p = node(id, 0, (i - 1) * -1.5, 0, r)
    p:addTag("craftpart"); p:addTag(tag or "flight:1")
  end
  return r
end
local ang = 1.5 / 0.9      -- 1.5 km of arc on a 900 m world
local far = stage("Kestrel stage 1", 900 * math.sin(ang), 900 * math.cos(ang), 0)
infos[far.id] = { vel = { x = 0, y = 0, z = 0 }, grounded = true, mass = 2, com = { x = far.x, y = far.y, z = far.z } }
local near = stage("Kestrel booster", 0, 905, 30)
infos[near.id] = { vel = { x = 0, y = 0, z = 0 }, grounded = true, mass = 2, com = { x = near.x, y = near.y, z = near.z } }
-- a live craft out there: never packed
local craft = node("Probe", planet.x - 1800, 0, 0)
local cp = node("PartProbe", 0, 0, 0, craft); cp:addTag("craftpart")
controllers[1] = { node = craft, isLost = function() return false end }

tick(2.0)
ok(far.valid and env.packedCount() == 0, "a far stage is not packed before PACK_HOLD")
tick(5.0)
ok(not far.valid and env.packedCount() == 1, "a far landed stage packs after PACK_HOLD (" .. env.packedCount() .. ")")
ok(near.valid, "a stage near the camera stays")
ok(craft.valid, "a craft with a live controller is never packed")
local rec = nil
for _, r in pairs(store["debris.packed"] or {}) do rec = r end
ok(rec and rec.kind == "landed" and rec.body == "Home" and #rec.parts == 2 and rec.parts[1].prefab == "PartTankM"
  and rec.tags[1] == "flight:1", "the record: landed, on Home, two parts with prefabs and the flight's tag")
ok(rec and math.abs(rec.x - 900 * math.sin(ang)) < 1e-6, "...and body-relative (" .. tostring(rec and rec.x) .. ")")

-- the lost craft: its pod gone, it is debris
controllers[1].isLost = function() return true end
tick(7.0)
ok(not craft.valid and env.packedCount() == 2, "a lost craft far away is debris and packs")
controllers[1] = nil

-- walk over: the camera comes within UNPACK_DIST of the landed stage
local bx, by = planet.x + 900 * math.sin(ang), 900 * math.cos(ang)
cam.cam_x, cam.cam_y, cam.cam_z = bx, by + 2, 0
tick(1.0)
local back = nil
for _, n in ipairs(all) do if n.valid and n.name == "Kestrel stage 1" then back = n end end
ok(back ~= nil and env.packedCount() == 1, "near again, the stage is built again (" .. env.packedCount() .. " still packed)")
-- the planet moved ~1.5 m a tick all along: it comes back where it lay ON the body
if back then
  ok(math.abs((back.x - planet.x) - 900 * math.sin(ang)) < 0.2, string.format("...on the body where it lay (Δx %.3f m)", (back.x - planet.x) - 900 * math.sin(ang)))
  local kids = back:children()
  ok(#kids == 2 and kids[1]:hasTag("craftpart") and kids[1]:hasTag("flight:1"), "...its parts tagged as before (a revert still finds them)")
end
ok(#impulses == 0, "a landed piece is not pushed")

-- an orbiting piece is carried along its conic to now
store["debris.packed"] = store["debris.packed"] or {}
local r0, w = 1400, math.sqrt(planet.mu / 1400 ^ 3)
store["debris.packed"]["d99"] = { name = "Kestrel stage 2", body = "Home", x = r0, y = 0, z = 0, vx = 0, vy = r0 * w, vz = 0,
  pitch = 0, yaw = 0, roll = 0, kind = "orbit", stime = ST, tags = { "flight:2" }, parts = { { prefab = "PartTankS", x = 0, y = 0, z = 0 } } }
env.start({})   -- (the store read again, as after a reload)
local quarter = (math.pi / 2) / w
-- the camera waits where the piece will be a quarter-orbit on
cam.cam_x, cam.cam_y, cam.cam_z = planet.x + 0, r0, 0
local t_until = ST + quarter
local got = nil
for _ = 1, math.ceil(quarter / 0.25) + 8 do
  tick(0.25)
  for _, n in ipairs(all) do if n.valid and n.name == "Kestrel stage 2" then got = got or n end end
  if got then break end
end
ok(got ~= nil, "an orbiting piece comes back when the camera is near where its conic has carried it")
ok(#impulses >= 1 and math.abs(impulses[#impulses].j.x) > 0, "...and is given its orbital velocity once it has its mass")

-- a revert takes back what the flight shed
store["debris.packed"]["d100"] = { name = "x", body = "Home", x = -900, y = 0, z = 0, kind = "landed", tags = { "flight:7" }, parts = { { prefab = "PartTankS", x = 0, y = 0, z = 0 } } }
store["debris.packed"]["d101"] = { name = "y", body = "Home", x = -900, y = 0, z = 0, kind = "landed", tags = { "flight:8" }, parts = { { prefab = "PartTankS", x = 0, y = 0, z = 0 } } }
env.start({})
local before = env.packedCount()
ok(env.forgetTag("flight:7") == 1 and env.packedCount() == before - 1, "forgetTag drops only that flight's pieces")
-- switched off, everything comes back
cam.cam_x, cam.cam_y, cam.cam_z = planet.x, planet.radius + 2, 0
env.active = false
tick(1.0)
ok(env.packedCount() == 0, "active = false: every packed piece comes back (" .. env.packedCount() .. ")")

if #failures == 0 then
  print(string.format("DEBRIS PACK SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("DEBRIS PACK SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
