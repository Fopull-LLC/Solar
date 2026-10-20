-- SMOKE HARNESS: the pilot's seat (planet_camera.lua, `cockpit`).
--
-- "make sure theres a first person mode so you can see your astronauts
-- perspective looking out the window from inside the pod". While flying, V (or
-- one scroll click in past the closest orbit) sits the view in the commander's
-- couch, looking out of the pod's window; the cabin subtree the pod prefab
-- carries is switched on only while you are in there. This holds:
--
--   * V and the scroll wheel both get you in, and both get you out;
--   * the eye rides the POD's frame (a tilted, moving craft carries the view),
--     sits inside the hull, and looks out of the window on the pod's −Z;
--   * the head turns with the mouse, clamped like a helmet in a couch;
--   * Esc is a way out, the cabin is switched off again, and leaving the craft
--     (or losing the pod) drops the seat rather than leaving the view in it.
--
--   luajit solar/tests/smoke_cockpit.lua

local T, TICK = 0.0, 1 / 60
local API = {}

local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
function V.__add(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
function V.__sub(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function V.__mul(a, b)
  if type(b) == "number" then return vec3(a.x * b, a.y * b, a.z * b) end
  return vec3(a * b.x, a * b.y, a * b.z)
end
function V.__unm(a) return vec3(-a.x, -a.y, -a.z) end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:normalized()
  local l = self:length()
  if l < 1e-9 then return vec3(0, 0, 0) end
  return vec3(self.x / l, self.y / l, self.z / l)
end
function V:cross(o)
  return vec3(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
end
function V:flatten(up)
  local k = self:dot(up)
  return vec3(self.x - up.x * k, self.y - up.y * k, self.z - up.z * k):normalized()
end
function V:angleTo(o)
  return math.acos(math.max(-1, math.min(1, self:normalized():dot(o:normalized()))))
end
function V:rotatedAround(axis, a)
  local u, c, s = axis:normalized(), math.cos(a), math.sin(a)
  return self * c + u:cross(self) * s + u * (u:dot(self) * (1 - c))
end
API.vec3 = vec3
function API.ease(a, b, rate, dt) return a + (b - a) * math.min(1.0, rate * dt) end
API.math = setmetatable({ clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end },
  { __index = math })

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

-- ── a craft: a vessel node, its pod part (tilted 30° about X, sitting 2 m up
-- the stack) with the cabin subtree, a tank, and the crew parked inside ──────
local TILT = math.rad(30)
local function rotx(v, a)
  local c, s = math.cos(a), math.sin(a)
  return vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
end
local VPOS = vec3(100, 50, -20)
local INTERIOR = { name = "Pod Interior", valid = true, enabled = false }
local POD = { name = "PartPod", valid = true, x = 0, y = 2.0, z = 0 }
function POD:children() return { INTERIOR } end
function POD:toWorld(l) return VPOS + rotx(vec3(l.x, l.y + 2.0, l.z), TILT) end
local TANK = { name = "PartTankS", valid = true, x = 0, y = 1.0, z = 0 }
function TANK:children() return {} end
local VNODE = { name = "Vessel", valid = true, pos = VPOS, up = rotx(vec3(0, 1, 0), TILT) }
function VNODE:children() return { TANK, POD } end
function VNODE:toWorld(l) return VPOS + rotx(l, TILT) end
local VESSEL = { piloting = true, node = VNODE, podLX = 0, podLY = 2.0, podLZ = 0, valid = true }

local ASTRO = { id = 1, name = "Astronaut", valid = true, visible = false, x = 100, y = 52, z = -20,
  vx = 0, vy = 0, vz = 0, up = vec3(0, 1, 0), pos = vec3(100, 52, -20) }

local CAMNODE = { id = 2, name = "Camera", valid = true, pos = vec3(0, 0, 0) }
local look_target, look_up
function CAMNODE:lookAt(p, up) look_target, look_up = p, up end

local presses, scroll, mdx, mdy = {}, 0.0, 0, 0
local mouse_locked = false
API.input = {
  key = function() return false end,
  pressed = function(k) return presses[k] == true end,
  clicked = function() return false end,
  button = function() return false end,
  scroll = function() return scroll end,
  mouse_delta = function() return mdx, mdy end,
  setMouseLocked = function(v) mouse_locked = v end,
}
local shake = 0.0
API.save = { get = function(k) return (k == "cam.shake") and shake or nil end, set = function() end }
API.access = { reducedMotion = function() return false end }
API.math.random = function() return 1.0 end
API.space = { dominant = function() return "Ground" end, body = function() return { x = 0, y = -1000, z = 0 } end }
API.net = { isMine = function() return true end }
API.find = function(n) return (n == "Astronaut") and ASTRO or nil end
API.spherecast = function() return nil end
API.raycast = function() return nil end

local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    if k == "math" then return API.math end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  env.node = { valid = true }
  return env
end
API.findScript = function(kind) return envs[kind] end
API.findScripts = function(kind)
  if kind == "vessel_controller" then return VESSEL.piloting and { VESSEL } or {} end
  return envs[kind] and { envs[kind] } or {}
end

local cam = load_script("solar/scripts/planet_camera.lua", "planet_camera")
envs.orbit_map = { map_view = false, node = { valid = true } }
envs.planet_walker = { node = ASTRO, grounded = true }

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    cam.lateUpdate(CAMNODE, TICK)
    presses = {}
  end
end
local function press(k) presses[k] = true end

-- ── 1. flying starts in third person, outside the hull ──────────────────────
tick(5)
check("piloting starts on the orbit, not in the seat", cam.cockpit == false)
check("...and the cabin is off (it costs nothing out here)", INTERIOR.enabled == false)

-- ── 2. V puts you in the seat ───────────────────────────────────────────────
press("v"); tick(1); tick(1)
check("V sits you in the pilot's seat", cam.cockpit == true)
check("...and switches the cabin on", INTERIOR.enabled == true)
check("...and the mouse turns your head without a button", mouse_locked == true)
local pod_c = POD:toWorld(vec3(0, 0, 0))
local eye = CAMNODE.pos - pod_c
check("the eye is inside the pod (a 1 m capsule), not on an orbit",
  eye:length() < 0.3, string.format("%.2f m from the pod's centre", eye:length()))
-- The window faces the pod's −Z: the view must look along it, in the POD's
-- frame — the craft here is tilted 30°, and a view in world axes would miss.
local podfwd = (POD:toWorld(vec3(0, 0, -1)) - pod_c):normalized()
local look = (look_target - CAMNODE.pos):normalized()
check("...looking out of the window, in the pod's own (tilted) frame",
  look:dot(podfwd) > 0.98, string.format("cos %.3f", look:dot(podfwd)))
local podup = (POD:toWorld(vec3(0, 1, 0)) - pod_c):normalized()
check("...with the pod's up overhead", look_up and look_up:dot(podup) > 0.999)

-- ── 3. the head turns, and stops where a helmet would ──────────────────────
mdx = 4000; tick(3); mdx = 0; tick(1)
look = (look_target - CAMNODE.pos):normalized()
local yaw = math.deg(math.acos(math.max(-1, math.min(1, look:dot(podfwd)))))
check("the head turns with the mouse...", yaw > 60, string.format("%.0f°", yaw))
check("...but not round to the back of the couch", yaw < 115, string.format("%.0f°", yaw))
mdy = -4000; tick(3); mdy = 0; tick(1)
look = (look_target - CAMNODE.pos):normalized()
check("looking up is clamped short of straight overhead", look:dot(podup) < 0.9)

-- ── 4. launch shake rattles the cabin by centimetres ────────────────────────
shake = 1.0; tick(1)
local shaken = (CAMNODE.pos - POD:toWorld(vec3(0, 0, 0.06))):length()
check("launch shake moves the eye, but only by centimetres",
  shaken > 0.001 and shaken < 0.03, string.format("%.3f m", shaken))
shake = 0.0; tick(1)

-- ── 5. ways out ─────────────────────────────────────────────────────────────
press("escape"); tick(1)
check("Esc leaves the seat", cam.cockpit == false)
check("...and switches the cabin off", INTERIOR.enabled == false)
local d = (CAMNODE.pos - pod_c):length()
tick(30)
check("...and the view is back out on the orbit", (CAMNODE.pos - pod_c):length() > 3.0,
  string.format("%.1f m", (CAMNODE.pos - pod_c):length()))

-- Scroll in to the closest orbit, then one more click: the seat.
scroll = 40.0; tick(1); scroll = 0.0; tick(1)
check("scrolling in stops at the closest orbit first", cam.cockpit == false)
scroll = 1.0; tick(1); scroll = 0.0; tick(1)
check("one more click in is the seat", cam.cockpit == true and INTERIOR.enabled == true)
scroll = -1.0; tick(1); scroll = 0.0; tick(1)
check("one click out leaves it", cam.cockpit == false and INTERIOR.enabled == false)

-- V toggles.
press("v"); tick(1)
check("V again...", cam.cockpit == true)
press("v"); tick(1)
check("...and V back out", cam.cockpit == false)

-- ── 6. losing the craft drops the seat ──────────────────────────────────────
press("v"); tick(1)
VESSEL.piloting = false; tick(2)
check("stepping out of the craft leaves the seat", cam.cockpit == false and INTERIOR.enabled == false)
VESSEL.piloting = true; tick(2)
press("v"); tick(1)
POD.valid = false; tick(2)
check("a pod that is gone (staged, wrecked) drops you back on the orbit", cam.cockpit == false)
POD.valid = true

-- A craft with no cabin (its pod lost) refuses the seat instead of
-- putting the view somewhere arbitrary.
function POD:children() return {} end
press("v"); tick(1)
check("no pod, no seat", cam.cockpit == false)

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_cockpit: %d checks passed", passes))
