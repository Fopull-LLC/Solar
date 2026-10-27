-- SMOKE HARNESS: the seat view (planet_camera.lua `cockpit`, iva.lua).
--
-- "make sure theres a first person mode so you can see your astronauts
-- perspective looking out the window from inside the pod" — and, since the
-- crew upgrade, "first person in all crew parts with realistic interiors in
-- all directions". While flying, V (or one scroll click in past the closest
-- orbit) sits the view in the commander's seat. The room is the part's
-- interior (prefabs/Iva*, human scale, on the `interior` layer) drawn by a
-- stacked "Iva Cam" at the seat's eye; the main camera looks out from the
-- hull's window point with the part's exterior hidden. This holds:
--
--   * V and the scroll wheel both get you in, and both get you out; V steps
--     through every occupied seat, then out;
--   * both eyes ride the PART's frame (a tilted, moving craft carries the
--     view): the main eye inside the hull, the room's eye at the couch's
--     head; they look the same way, out of the window on the pod's -Z;
--   * the head turns with the mouse far enough to look back over the
--     shoulder and up and down, clamped short of all the way round;
--   * the interior camera is stacked on the main one, which never draws the
--     interior layer itself;
--   * Esc is a way out, the exterior comes back, and leaving the craft (or
--     losing the pod) drops the seat rather than leaving the view in it.
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

-- ── a craft: a vessel node with a Pod Mk2 (uid 3, tilted 30° about X, 2 m up
-- the stack) and a tank; two of the crew aboard ─────────────────────────────
local TILT = math.rad(30)
local function rotx(v, a)
  local c, s = math.cos(a), math.sin(a)
  return vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
end
local VPOS = vec3(100, 50, -20)
local POD = { name = "PartPodMk2", valid = true, visible = true, x = 0, y = 2.0, z = 0 }
local EMBLEM = { name = "Emblem Plate", valid = true, visible = true }
function EMBLEM:children() return {} end
function POD:children() return { EMBLEM } end
local TANK = { name = "PartTankS", valid = true, visible = true, x = 0, y = 1.0, z = 0 }
function TANK:children() return {} end
local VNODE = { id = 77, name = "Vessel", valid = true, pos = VPOS, up = rotx(vec3(0, 1, 0), TILT) }
function VNODE:children() return { TANK, POD } end
function VNODE:toWorld(l) return VPOS + rotx(l, TILT) end
local PARTS = { [2] = { id = "tankS", x = 0, y = 1, z = 0 }, [3] = { id = "podMk2", x = 0, y = 2, z = 0 } }
local VESSEL = { piloting = true, crewAboard = true, node = VNODE, valid = true, craftName = "Kestrel" }
function VESSEL.partRec(uid) return PARTS[uid] end
function VESSEL.uidOfNode(n) if n == POD then return 3 elseif n == TANK then return 2 end end
function VESSEL.partFrameNow(uid)
  if not POD.valid or uid ~= 3 then return nil end
  local R, U, Z = rotx(vec3(1, 0, 0), TILT), rotx(vec3(0, 1, 0), TILT), rotx(vec3(0, 0, 1), TILT)
  local o = VPOS + rotx(vec3(0, 2, 0), TILT)
  return { ox = o.x, oy = o.y, oz = o.z, rx = R.x, ry = R.y, rz = R.z, ux = U.x, uy = U.y, uz = U.z, zx = Z.x, zy = Z.y, zz = Z.z }
end
local SEATS = { { uid = 3, slot = 1, taken = 1, command = true, label = "Pod Mk2" },
                { uid = 3, slot = 2, taken = 2, command = true, label = "Pod Mk2" },
                { uid = 3, slot = 3, taken = nil, command = true, label = "Pod Mk2" } }
local CREW = { valid = true, roster = function() return {} end, activeId = function() return 1 end,
               seatMap = function() return POD.valid and SEATS or {} end, dollOf = function() return nil end }

local ASTRO = { id = 1, name = "Astronaut", valid = true, visible = false, x = 100, y = 52, z = -20,
  vx = 0, vy = 0, vz = 0, up = vec3(0, 1, 0), pos = vec3(100, 52, -20) }
function ASTRO:children() return {} end

local cam_calls = {}
local CAMNODE = { id = 2, name = "Camera", valid = true, pos = vec3(0, 0, 0) }
local look_target, look_up
function CAMNODE:lookAt(p, up) look_target, look_up = p, up end
function CAMNODE:setCamera(t) cam_calls[#cam_calls + 1] = t end
local IVACAM = { id = 3, name = "Iva Cam", valid = true, pos = vec3(0, 0, 0) }
local iva_target, iva_up, iva_cam_set
function IVACAM:lookAt(p, up) iva_target, iva_up = p, up end
function IVACAM:setCamera(t) iva_cam_set = iva_cam_set or {}; for k, v in pairs(t) do iva_cam_set[k] = v end end
local IVANODE = { id = 4, name = "IvaPodMk2", valid = true, visible = true }
function IVANODE:children() return {} end
function IVANODE:setUp() end

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
API.createNode = function(name, parent, fn) if name == "Iva Cam" then fn(IVACAM) end end
API.spawn = function(prefab, pos, fn) fn(IVANODE) end
API.destroy = function() end

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
local iva = load_script("solar/scripts/iva.lua", "iva")
envs.crew = CREW
envs.orbit_map = { map_view = false, node = { valid = true } }
envs.planet_walker = { node = ASTRO, grounded = true }

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    cam.lateUpdate(CAMNODE, TICK)
    iva.lateUpdate(iva.node, TICK)
    presses = {}
  end
end
local function press(k) presses[k] = true end
local function last_stack()
  for i = #cam_calls, 1, -1 do if cam_calls[i].stack then return cam_calls[i] end end
end

-- ── 1. flying starts in third person, outside the hull ──────────────────────
tick(5)
check("piloting starts on the orbit, not in the seat", cam.cockpit == false)
check("...and the main camera never draws the interior layer",
  cam_calls[1] and cam_calls[1].cullMask == cam.cullBase() and (cam.cullBase() % 32) < 16)

-- ── 2. V puts you in the commander's seat ───────────────────────────────────
press("v"); tick(1); tick(1)
check("V sits you in the commander's seat", cam.cockpit == true and cam.seatView and cam.seatView.slot == 1)
check("...the Pod Mk2's exterior is hidden from the main camera", POD.visible == false and EMBLEM.visible == false)
check("...and the mouse turns your head without a button", mouse_locked == true)
local st = last_stack()
check("...the interior camera is stacked on the main one", st and st.stack[1] == "Iva Cam" and st.cullMask == cam.cullBase())
check("...and draws only the interior layer", iva_cam_set and iva_cam_set.cullMask == 16)
local pod_c = VPOS + rotx(vec3(0, 2, 0), TILT)
local eye = CAMNODE.pos - pod_c
check("the main eye is inside the hull (a 1 m capsule), at its window point",
  eye:length() < 0.3, string.format("%.2f m from the pod's centre", eye:length()))
local podfwd = rotx(vec3(0, 0, -1), TILT)
local podup = rotx(vec3(0, 1, 0), TILT)
local look = (look_target - CAMNODE.pos):normalized()
check("...looking out of the window, in the pod's own (tilted) frame",
  look:dot(podfwd) > 0.98, string.format("cos %.3f", look:dot(podfwd)))
check("...with the pod's up overhead", look_up and look_up:dot(podup) > 0.98)
local ieye = IVACAM.pos - pod_c
local want = iva.DEFS.podMk2.seats[1]
local wl = vec3(want[1], want[2] + iva.EYE_UP, want[3] - iva.EYE_FWD)
check("the room's eye is the couch's head, at human scale",
  (rotx(wl, TILT) - ieye):length() < 0.01, string.format("%.3f m off", (rotx(wl, TILT) - ieye):length()))
local ilook = (iva_target - IVACAM.pos):normalized()
check("...looking exactly the way the main eye looks", ilook:dot(look) > 0.9999)

-- ── 3. the head turns, round to the back and up and down ───────────────────
mdx = 4000; tick(3); mdx = 0; tick(1)
look = (look_target - CAMNODE.pos):normalized()
local yaw = math.deg(math.acos(math.max(-1, math.min(1, look:dot(podfwd)))))
check("the head turns with the mouse round to look back", yaw > 150, string.format("%.0f°", yaw))
check("...but not all the way round", yaw < 175, string.format("%.0f°", yaw))
mdy = -4000; tick(3); mdy = 0; tick(1)
look = (look_target - CAMNODE.pos):normalized()
check("looking up reaches nearly overhead", look:dot(podup) > 0.9)
cam.setSeatLook(0, -0.08); tick(1)

-- ── 4. launch shake rattles the cabin by centimetres ────────────────────────
local still = CAMNODE.pos
shake = 1.0; tick(1)
local shaken = (CAMNODE.pos - still):length()
check("launch shake moves the eye, but only by centimetres",
  shaken > 0.001 and shaken < 0.03, string.format("%.3f m", shaken))
shake = 0.0; tick(1)

-- ── 5. V steps through the seats, then out ─────────────────────────────────
press("v"); tick(1)
check("V again: the next occupied seat", cam.cockpit == true and cam.seatView.slot == 2)
press("v"); tick(1)
check("...and past the last one, back out", cam.cockpit == false)
check("...the exterior is back", POD.visible == true and EMBLEM.visible == true)
local st2 = last_stack()
check("...and the interior camera unstacked", st2 and #st2.stack == 0)

-- ── 6. ways out ─────────────────────────────────────────────────────────────
press("v"); tick(1)
press("escape"); tick(1)
check("Esc leaves the seat", cam.cockpit == false and POD.visible == true)
tick(30)
check("...and the view is back out on the orbit", (CAMNODE.pos - pod_c):length() > 2.0,
  string.format("%.1f m", (CAMNODE.pos - pod_c):length()))

-- Scroll in to the closest orbit, then one more click: the seat.
scroll = 40.0; tick(1); scroll = 0.0; tick(1)
check("scrolling in stops at the closest orbit first", cam.cockpit == false)
scroll = 1.0; tick(1); scroll = 0.0; tick(1)
check("one more click in is the seat", cam.cockpit == true)
scroll = -1.0; tick(1); scroll = 0.0; tick(1)
check("one click out leaves it", cam.cockpit == false)

-- ── 7. losing the craft drops the seat ──────────────────────────────────────
press("v"); tick(1)
VESSEL.piloting = false; tick(2)
check("stepping out of the craft leaves the seat", cam.cockpit == false and POD.visible == true)
VESSEL.piloting = true; tick(2)
press("v"); tick(1)
POD.valid = false; tick(2)
check("a pod that is gone (staged, wrecked) drops you back on the orbit", cam.cockpit == false)
press("v"); tick(1)
check("no crew part, no seat", cam.cockpit == false)
POD.valid = true

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_cockpit: %d checks passed", passes))
