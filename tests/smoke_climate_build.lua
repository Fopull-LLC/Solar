-- SMOKE HARNESS: climate.lua builds a lake as a time-sliced job.
--
--   luajit solar/tests/smoke_climate_build.lua
--
-- A lake's lattice is a few thousand field reads; built in one go it was a
-- 50–230 ms frame on a scale-3 world (engine 0.117.0-rc7). It is a job now,
-- resumed for BUILD_MS of wall time a frame. Pins:
--  * the lake is built (a "Lake" node wearing a mesh) once the eye is near;
--  * no frame reads the field much past its budget (a fake wall clock that
--    advances 0.05 ms a read: 2 ms = 40 reads, checked every 8);
--  * the planet moving on its rails between frames does not tear the lake:
--    every read is against the body's position that frame.

local T = 0.0
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- A 100 m world with a bowl at its north pole (a lake's basin).
local BODY = { x = 0, y = 0, z = 0, radius = 100, name = "W" }
local function sdf_local(x, y, z)
  local ball = len(x, y, z) - 100
  local bowl = len(x, y - 100, z) - 15
  return math.max(ball, -bowl)
end
local reads, clock = 0, 0
local misaimed = 0
local function sdf(x, y, z)
  reads = reads + 1
  clock = clock + 0.00005
  local lx, ly, lz = x - BODY.x, y - BODY.y, z - BODY.z
  if len(lx, ly, lz) > 200 then misaimed = misaimed + 1 end
  return sdf_local(lx, ly, lz)
end

local nodes, meshes = {}, {}
local API = {
  space = {
    dominant = function() return "W" end,
    body = function(n) return n == "W" and { x = BODY.x, y = BODY.y, z = BODY.z, radius = 100, name = "W" } or nil end,
  },
  save = {
    get = function(k)
      if k == "world.W" then
        return { sea = 0, radius = 100, relief = 6, kind = "temperate", atmo = 1, hydro = true, shape = { low = 10 } }
      end
      if k == "hydro.W" then
        return { lakes = { { x = 0, y = 100, z = 0, level = -3, reach = 10, depth = 5 } }, rivers = {} }
      end
    end,
    set = function() end,
  },
  terrain = { query = sdf, busy = function() return false end },
  mesh = { build = function(t) meshes[#meshes + 1] = t; return "mesh:" .. #meshes end, free = function() end },
  createNode = function(name, parent, fn)
    local n = { name = name, valid = true }
    function n:setShaderParam() end
    function n:material() return {} end
    function n:setMaterial() end
    nodes[#nodes + 1] = n
    if fn then fn(n) end
  end,
  app = { wallClock = function() return clock end },
  findScript = function() return nil end,
  find = function(n) if n == "Astronaut" then return { x = 0, y = 102, z = 0 } end end,
  log = function() end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/climate.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end

local fails = 0
local function check(ok, msg)
  print((ok and "ok   " or "FAIL ") .. msg)
  if not ok then fails = fails + 1 end
end

local worst, frames_building, lake = 0, 0, nil
for f = 1, 600 do
  T = T + 1 / 60
  -- the planet on its rails: 30 m a frame, the eye riding it
  BODY.x = BODY.x + 30
  env.setEye(BODY.x, 102, 0)
  reads = 0
  env.update({}, 1 / 60)
  worst = math.max(worst, reads)
  for _, n in ipairs(nodes) do if n.name == "Lake" then lake = n end end
  if not lake and reads > 0 then frames_building = frames_building + 1 end
  if lake then break end
end

check(lake ~= nil and lake.model ~= nil, "the lake is built: a Lake node wearing a mesh")
check(frames_building > 1, string.format("over several frames (%d), not one", frames_building))
check(worst <= 40 + 8 + 20, string.format("no frame reads the field far past its 2 ms (worst %d reads, budget ~40)", worst))
check(misaimed == 0, "every read is at the planet's position that frame (" .. misaimed .. " aimed at where it was)")
local m = meshes[#meshes]
local wet = m and #m.indices / 3 or 0
check(wet >= 8, "the lake has a surface (" .. wet .. " triangles)")

if fails > 0 then print(fails .. " FAILED"); os.exit(1) end
print("all climate build checks passed")
