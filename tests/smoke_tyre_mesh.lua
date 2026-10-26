-- SMOKE HARNESS: a live tyre's mesh after getting off and back on
-- (vessel_controller.lua, r2TyreVisuals / r2Cleanup).
--
-- "wheels will often face the wrong direction when getting off and back on a
-- craft" (playtest 2026-10-26; a seated rover's rear wheel square across).
-- A script's node handle is the engine's bare slot number, and a destroyed
-- node's slot goes to the next node spawned. The TyreMesh handle kept from the
-- tyre before a get-off/get-on read `valid` again, now naming some OTHER new
-- node: the mesh writes went there, and the new tyre's own mesh was never laid
-- along its axle, so it turned with its free ball body. This holds that:
--
--   * a mesh handle that is valid but not the current tyre's child (a reused
--     slot) is dropped and the tyre's own TyreMesh is laid instead;
--   * the mesh is laid along the steered axle (base steer + steering);
--   * r2Cleanup drops the mesh handle with the tyre.
--
--   luajit solar/tests/smoke_tyre_mesh.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

local stub = setmetatable({}, { __index = function() return function() end end,
                                __call = function() return nil end })
local env = setmetatable({}, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
check("vessel_controller loads in a stub world", ok, tostring(err))

env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
env.assembly = { info = function() return nil end }
env.destroy = function(n) n.valid = false end

-- nodes: an id, a name, children, and the orientation last laid on them
local function node(id, name, kids)
  local n = { id = id, name = name, valid = true, yaw = 0, pitch = 0, roll = 0, kids = kids or {} }
  function n:children() return self.kids end
  function n:setUp(up, fwd) self.laid = { up = up, fwd = fwd } end
  return n
end
local function axle_of(n)
  -- the mesh's X (its axle) = Y × Z, Z = −forward
  if not n.laid then return 0, 0, 0 end
  local u, f = n.laid.up, n.laid.fwd
  local zx, zy, zz = -f.x, -f.y, -f.z
  return u.y * zz - u.z * zy, u.z * zx - u.x * zz, u.x * zy - u.y * zx
end

local R2 = env.R2
local hull = node(1, "Vessel")
R2.live = true

-- 1. the reused slot: the new tyre's own mesh is laid, not the stale handle's node
local other = node(41, "TyreMesh")            -- another wheel's new mesh, in the old mesh's slot
local mesh = node(42, "TyreMesh")
local tyre = node(40, "WheelTyreM", { mesh })
local w = { tyre = tyre, mesh = other, mesh_of = 30, steer0 = 0, steerNow = 0, r = 0.4 }
R2.wheels = { w }
env.r2TyreVisuals(hull, 1 / 60)
check("the tyre's own mesh is laid", mesh.laid ~= nil)
check("the stale handle's node is left alone", other.laid == nil)
check("the handle now names the tyre's mesh", w.mesh == mesh and w.mesh_of == tyre.id)

-- (a handle from before the fix's bookkeeping: valid, no owner recorded)
mesh.laid, other.laid = nil, nil
w.mesh, w.mesh_of = other, nil
env.r2TyreVisuals(hull, 1 / 60)
check("a handle with no owner recorded is looked up again", mesh.laid ~= nil and other.laid == nil)

-- 2. laid along the steered axle: chassis Z turned about +Y by steer0 + steerNow
for _, c in ipairs({ { 0, 0 }, { 0, 25 }, { 90, 0 }, { -30, -20 } }) do
  w.steer0, w.steerNow = c[1], c[2]
  mesh.laid = nil
  env.r2TyreVisuals(hull, 1 / 60)
  local s = math.rad(c[1] + env.R2_STEER_SIGN * c[2])
  local ax, ay, az = axle_of(mesh)
  local dx, dz = math.sin(s), math.cos(s)
  check(string.format("axle laid along steer %g%+g", c[1], c[2]),
    math.abs(ax - dx) < 1e-6 and math.abs(ay) < 1e-6 and math.abs(az - dz) < 1e-6,
    string.format("(%.3f, %.3f, %.3f) want (%.3f, 0, %.3f)", ax, ay, az, dx, dz))
end

-- 3. a destroyed tyre's mesh handle goes with it
env.r2Cleanup()
check("r2Cleanup drops the tyre and its mesh handle", w.tyre == nil and w.mesh == nil and w.mesh_of == nil)
check("…and the tyre is destroyed", tyre.valid == false)

if #failures > 0 then
  print(string.format("smoke_tyre_mesh: %d passed, %d FAILED", passes, #failures))
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_tyre_mesh: all %d checks passed", passes))
