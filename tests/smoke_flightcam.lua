-- SMOKE HARNESS: the flight camera over a big craft (planet_camera.lua).
--
-- "when flying a ship also you are stuck to the pod position but it would be
-- nice if somehow i could move the camera up or down the span of the craft too
-- as well as left or right when it's a larger craft". This holds:
--
--   * the maths: a craft's bounds and main axis, the pivot clamp, the slide
--     along the axis, and a zoom range that frames a 60 m rocket whole and
--     still fills the frame with a probe core;
--   * flying a tall rocket: the pivot starts mid-stack (not at the pod), the
--     zoom starts framing the whole stack, a drag or ALT+wheel slides the
--     pivot from top to bottom and no further, Home brings it back;
--   * a wide craft: the drag slides the pivot across it, side to side;
--   * C cycles Auto → Free orbit → Chase → Horizon, and each behaves: chase
--     turns with the craft, horizon follows its yaw with the sky up, auto
--     swings round behind the way it is going;
--   * F6's photo orbit circles the craft, and Esc stops it;
--   * however the pivot is slid, the view stays outside the hull.
--
--   luajit solar/tests/smoke_flightcam.lua

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
API.math = setmetatable({ clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end },
  { __index = math })

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

-- ── a craft: a vessel node whose pose the test turns, and its parts ─────────
local VPOS = vec3(100, 50, -20)
local YAW, TILT, ROLL = 0.0, 0.0, 0.0        -- the craft's pose: yaw about Y, then tilt about X
local function rot(l)
  local c, s = math.cos(ROLL), math.sin(ROLL)
  local v = vec3(l.x * c - l.y * s, l.x * s + l.y * c, l.z)
  c, s = math.cos(TILT), math.sin(TILT)
  v = vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
  c, s = math.cos(YAW), math.sin(YAW)
  return vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
end
local PARTS = {}
local function part(x, y, z, hx, hy, hz)
  local rb = { half_x = hx, half_y = hy, half_z = hz }
  local p = { valid = true, x = x, y = y, z = z, name = "Part" }
  function p:getcomponent(k) return (k == "RigidBody") and rb or nil end
  function p:children() return {} end
  return p
end
local VNODE = { id = 10, name = "Vessel", valid = true, pos = VPOS, vx = 0, vy = 0, vz = 0 }
function VNODE:children() return PARTS end
function VNODE:toWorld(l) return VPOS + rot(l) end
VNODE.up = vec3(0, 1, 0)
local VESSEL = { piloting = true, node = VNODE, valid = true }

-- The tall rocket: an engine, ten 1.5 m tanks and a pod on top (≈ 17 m).
local function tall_rocket()
  PARTS = { part(0, 0.65, 0, 0.9, 0.65, 0.9) }
  for k = 1, 10 do PARTS[#PARTS + 1] = part(0, 1.3 + 1.5 * (k - 0.5), 0, 0.5, 0.75, 0.5) end
  PARTS[#PARTS + 1] = part(0, 16.7, 0, 0.5, 0.4, 0.5)
  VESSEL.podLX, VESSEL.podLY, VESSEL.podLZ = 0, 16.7, 0
end
-- The wide craft: a body with a 16 m span of side booms along Z.
local function wide_craft()
  PARTS = { part(0, 1.0, 0, 0.8, 0.15, 0.5) }
  for k = 1, 5 do
    PARTS[#PARTS + 1] = part(0, 1.2, 0.5 + 1.5 * k, 0.5, 0.5, 0.75)
    PARTS[#PARTS + 1] = part(0, 1.2, -0.5 - 1.5 * k, 0.5, 0.5, 0.75)
  end
  VESSEL.podLX, VESSEL.podLY, VESSEL.podLZ = 0, 1.4, 0
end

local ASTRO = { id = 1, name = "Astronaut", valid = true, visible = false, x = 100, y = 52, z = -20,
  vx = 0, vy = 0, vz = 0, up = vec3(0, 1, 0), pos = vec3(100, 52, -20) }
local CAMNODE = { id = 2, name = "Camera", valid = true, pos = vec3(0, 0, 0) }
local look_target, look_up
function CAMNODE:lookAt(p, up) look_target, look_up = p, up end

local presses, held, scroll, mdx, mdy, buttons = {}, {}, 0.0, 0, 0, {}
API.input = {
  key = function(k) return held[k] == true end,
  pressed = function(k) return presses[k] == true end,
  clicked = function() return false end,
  button = function(b) return buttons[b] == true end,
  scroll = function() return scroll end,
  mouse_delta = function() return mdx, mdy end,
  setMouseLocked = function() end,
}
API.save = { get = function(k)
  if k == "world.Ground" then return { atmo = 1.0, atmoHeight = 5000 } end
  return nil
end, set = function() end }
API.access = { reducedMotion = function() return false end }
API.space = { dominant = function() return "Ground" end,
  body = function() return { x = 0, y = -1000, z = 0, vx = 0, vy = 0, vz = 0, radius = 1000 } end }
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
local function pivot() return vec3(cam.pivot_x, cam.pivot_y, cam.pivot_z) end
local function view() return (look_target - CAMNODE.pos):normalized() end

-- ── 1. the maths ────────────────────────────────────────────────────────────
local b = cam.craftBounds({ { x = 0, y = 0, z = 0, r = 1 }, { x = 0, y = 59, z = 0, r = 1 },
                            { x = 2, y = 30, z = 0, r = 1 } })
check("bounds: a 60 m stack's main axis is its length", b.axis == "y")
check("...the box spans the parts' balls", near(b.lo.y, -1) and near(b.hi.y, 60) and near(b.hi.x, 3))
check("...the pivot box spans their centres", near(b.clo.y, 0) and near(b.chi.y, 59) and near(b.chi.x, 2))
check("...centre mid-stack", near(b.centre.y, 29.5) and near(b.centre.x, 1))
check("...radius half the diagonal", near(b.radius, 0.5 * math.sqrt(4 * 4 + 61 * 61 + 2 * 2), 1e-6))
check("no parts, no bounds", cam.craftBounds({}) == nil)
local wb = cam.craftBounds({ { x = 0, y = 0, z = -8, r = 0.5 }, { x = 0, y = 0, z = 8, r = 0.5 } })
check("a wide craft's main axis is across it", wb.axis == "z")

local p = cam.clampPivot(b, vec3(-10, 100, 5))
check("clamp: a pivot dragged off the craft stops at its edge", near(p.x, 0) and near(p.y, 59) and near(p.z, 0))
p = cam.clampPivot(b, vec3(1, 20, 0))
check("clamp: a pivot inside is untouched", near(p.x, 1) and near(p.y, 20))
p = cam.slideAlongAxis(b, vec3(1, 29.5, 0), 10)
check("slide: along the main axis", near(p.y, 39.5) and near(p.x, 1))
p = cam.slideAlongAxis(b, vec3(1, 29.5, 0), -1000)
check("slide: stops at the bottom of the stack", near(p.y, 0))
p = cam.slideAlongAxis(wb, vec3(0, 0, 0), 1000)
check("slide: across a wide craft to its tip", near(p.z, 8))

local FOV = 1.1519173
local half = math.tan(FOV / 2)
local mind, maxd, fit = cam.zoomRange(30.5, FOV)      -- a 60 m rocket
check("zoom: a 60 m rocket can be framed whole", fit * half >= 30.5, string.format("fit %.1f m", fit))
check("...and pulled back past that", maxd >= fit * 2, string.format("max %.1f m", maxd))
check("...and approached, but not to its middle", mind > 8 and mind < 20, string.format("min %.1f m", mind))
local pm, pM, pf = cam.zoomRange(0.6, FOV)            -- a probe core
check("zoom: a probe can be filled (closest orbit 3 m)", near(pm, 3.0), string.format("min %.1f", pm))
check("...framing it is close", pf <= 4.0, string.format("fit %.1f", pf))
check("...the far limit never shrinks below the old 40 m", pM >= 40)
local okm = true
local last = 0
for r = 0.5, 80, 0.5 do
  local a, z, f = cam.zoomRange(r, FOV)
  if not (a <= f and f <= z and a >= 3.0 and f >= last) then okm = false end
  last = f
end
check("zoom: min <= fit <= max, and the fit grows with the craft", okm)

-- ── 2. flying the tall rocket ───────────────────────────────────────────────
tall_rocket()
tick(5)
local cf = cam.craftFrame
check("flying: the craft's frame is published", cf ~= nil and cf.axis == "y")
local mid = VNODE:toWorld(cf.centre)
check("the pivot starts mid-stack, not at the pod", (pivot() - mid):length() < 0.05 and math.abs(pivot().y - VPOS.y - 16.7) > 5,
  string.format("pivot y %.2f, middle %.2f", pivot().y - VPOS.y, mid.y - VPOS.y))
check("the view starts framing the whole stack", near(cam.params.distance, cf.fit, 1e-3),
  string.format("%.1f m (fit %.1f)", cam.params.distance, cf.fit))
local back = (CAMNODE.pos - pivot()):length()
check("...and is placed out there", back > cf.fit * 0.9, string.format("%.1f m", back))

-- A long middle-button drag upward: the pivot climbs to the top part, no further.
buttons[2] = true
mdy = -400; tick(20); mdy = 0
buttons[2] = false; tick(60)
local top = VNODE:toWorld(vec3(0, 16.7, 0))
check("a middle drag up slides the pivot to the top of the stack", (pivot() - top):length() < 0.1,
  string.format("%.2f m off the top", (pivot() - top):length()))
-- And down past the bottom: the engine's centre.
buttons[2] = true
mdy = 600; tick(30); mdy = 0
buttons[2] = false; tick(60)
local bot = VNODE:toWorld(vec3(0, 0.65, 0))
check("a drag down slides it to the bottom, and stops there", (pivot() - bot):length() < 0.1,
  string.format("%.2f m off the bottom", (pivot() - bot):length()))
check("panning does not turn the view's pitch", near(math.asin(view():dot(vec3(0, 1, 0))), cam.params.start_pitch, 0.05))
-- The view stays outside every part however the pivot is slid.
local inside = 0
for _, pt in ipairs(PARTS) do
  local c = VNODE:toWorld(vec3(pt.x, pt.y, pt.z))
  local rb = pt:getcomponent("RigidBody")
  local r = math.sqrt(rb.half_x ^ 2 + rb.half_y ^ 2 + rb.half_z ^ 2)
  if (CAMNODE.pos - c):length() < r then inside = inside + 1 end
end
check("the view is outside the hull with the pivot at the bottom", inside == 0)

-- Home: back to the middle.
press("home"); tick(90)
check("Home brings the pivot back to the middle", (pivot() - mid):length() < 0.05)
-- ALT + the wheel slides along the stack, and does not zoom.
local d0 = cam.params.distance
held.alt = true; scroll = 3; tick(1); scroll = 0; held.alt = false; tick(90)
check("ALT + wheel slides the pivot along the stack", pivot().y > mid.y + 2,
  string.format("%.2f m up", pivot().y - mid.y))
check("...without zooming", near(cam.params.distance, d0, 1e-6))
press("home"); tick(90)
-- The wheel alone zooms, by a factor, over the craft's whole range.
scroll = -40; tick(1); scroll = 0; tick(1)
check("zooming out reaches the craft's far limit", near(cam.params.distance, cf.maxd, 1e-3),
  string.format("%.1f m", cam.params.distance))
scroll = 40; tick(1); scroll = 0; tick(1)
check("zooming in stops at the closest orbit", near(cam.params.distance, cf.mind, 1e-3) and cam.cockpit == false,
  string.format("%.1f m", cam.params.distance))

-- ── 3. the modes ────────────────────────────────────────────────────────────
check("the default mode is Auto", cam.camMode == "auto")
press("c"); tick(1)
check("C: Free orbit", cam.camMode == "free")
press("c"); tick(1)
check("C: Chase", cam.camMode == "chase")
-- Chase: tilt and yaw the craft; the view, in the craft's frame, is unchanged.
tick(2)
local function in_craft(v)
  local o = VNODE:toWorld(vec3(0, 0, 0))
  local ex = (VNODE:toWorld(vec3(1, 0, 0)) - o):normalized()
  local ey = (VNODE:toWorld(vec3(0, 1, 0)) - o):normalized()
  local ez = (VNODE:toWorld(vec3(0, 0, 1)) - o):normalized()
  return vec3(v:dot(ex), v:dot(ey), v:dot(ez))
end
local v0 = in_craft(view())
YAW, TILT = 0.6, 0.5; tick(3)
local v1 = in_craft(view())
check("Chase: the view turns with the craft", (v1 - v0):length() < 0.02,
  string.format("drift %.3f", (v1 - v0):length()))
check("...and rolls with it (its up is the craft's)", look_up and in_craft(look_up):dot(in_craft(vec3(0, 1, 0))) < 0.99)
YAW, TILT = 0.0, 0.0; tick(3)
press("c"); tick(1)
check("C: Locked to the horizon", cam.camMode == "horizon")
tick(120)    -- the up eases back level after the chase
local flat0 = view():flatten(vec3(0, 1, 0))
YAW = 0.5; tick(2)
local flat1 = view():flatten(vec3(0, 1, 0))
local turned = math.atan2(flat0:cross(flat1).y, flat0:dot(flat1))
check("Horizon: the view yaws with the craft", near(turned, 0.5, 0.02), string.format("%.3f rad", turned))
local WUP = (VPOS - vec3(0, -1000, 0)):normalized()
check("...and the sky stays up", look_up and look_up:dot(WUP) > 0.999, look_up and string.format("cos %.4f", look_up:dot(WUP)))
press("c"); tick(1)
check("C: back to Auto", cam.camMode == "auto")
-- Auto: moving fast over the ground, the view swings round behind.
local vel = vec3(-20, 0, 6):normalized()
VNODE.vx, VNODE.vy, VNODE.vz = vel.x * 20, 0, vel.z * 20
local a0 = view():flatten(vec3(0, 1, 0)):dot(vel)
tick(300)
local a1 = view():flatten(vec3(0, 1, 0)):dot(vel)
check("Auto: in the air and moving, the view swings round behind the craft", a1 > 0.98 and a1 > a0,
  string.format("cos %.2f -> %.2f", a0, a1))
VNODE.vx, VNODE.vz = 0, 0
-- Free orbit: the craft yaws, the view does not.
press("c"); tick(1)
local f0 = view():flatten(vec3(0, 1, 0))
YAW = 1.2; tick(3)
check("Free orbit: the craft turns under a still view", view():flatten(vec3(0, 1, 0)):dot(f0) > 0.999)
YAW = 0.0
press("c"); tick(1); press("c"); tick(1); press("c"); tick(1)
check("...and C goes round to Auto again", cam.camMode == "auto")

-- ── 4. photo orbit ──────────────────────────────────────────────────────────
local g0 = view():flatten(vec3(0, 1, 0))
press("f6"); tick(1)
check("F6 starts the photo orbit", cam.photoOrbit == true)
tick(120)
local g1 = view():flatten(vec3(0, 1, 0))
local swept = math.deg(math.acos(math.max(-1, math.min(1, g0:dot(g1)))))
check("...which circles the craft slowly (about 9°/s)", swept > 14 and swept < 22, string.format("%.1f° in 2 s", swept))
press("escape"); tick(1)
check("Esc stops it", cam.photoOrbit == false)
check("...and keeps the Esc from the pause menu", cam.escTakenAt == T)

-- ── 5. the wide craft: side to side ────────────────────────────────────────
VESSEL.piloting = false; tick(2)
wide_craft()
VNODE.id = 11
VESSEL.piloting = true; tick(5)
cf = cam.craftFrame
check("a wide craft's main axis is across it", cf and cf.axis == "z")
-- Look at it from the side (view along +X... i.e. from the craft's −X side)
cam.face(1, 0, 0, -0.2); tick(30)
local c0 = pivot()
buttons[2] = true
mdx = 800; tick(20); mdx = 0
buttons[2] = false; tick(60)
local function local_z() return (pivot() - VPOS).z end   -- the craft is unturned here
local z1 = local_z()
check("a sideways drag slides the pivot out to a wingtip", near(math.abs(z1), 8, 0.05),
  string.format("z %.2f", z1))
buttons[2] = true
mdx = -1600; tick(30); mdx = 0
buttons[2] = false; tick(60)
local z2 = local_z()
check("...and back across to the other one", near(z2, -z1, 0.05), string.format("z %.2f", z2))
check("...never off the craft (the height stays within its parts)", pivot().y - VPOS.y >= 1.0 - 1e-6 and pivot().y - VPOS.y <= 1.2 + 1e-6)
press("home"); tick(90)
check("Home: back to the middle of the wide craft", (pivot() - c0):length() < 0.05)

-- ── 6. the free camera has the keys, not the craft ──────────────────────────
-- vessel_controller reads its keys through a proxy that answers "nothing
-- pressed" while planet_camera.freecam is up (W A S D, SHIFT, T, the wheel
-- and the mouse all move the free camera instead).
do
  local PC = { valid = true, freecam = true }
  local raw = { key = function() return true end, pressed = function() return true end,
    released = function() return true end, button = function() return true end,
    clicked = function() return true end, scroll = function() return 2 end,
    mouse_delta = function() return 5, 5 end, setMouseLocked = function() end }
  local env = setmetatable({ input = raw, time = 0,
    findScript = function(k) return k == "planet_camera" and PC or nil end }, { __index = _G })
  local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
  setfenv(chunk, env)
  local ok = pcall(chunk)
  check("vessel_controller loads in the harness", ok)
  local I = env.input
  check("free camera: the craft sees no W, SHIFT or T", I.key("w") == false and I.key("shift") == false
    and I.pressed("t") == false)
  check("...no wheel and no mouse", I.scroll() == 0 and select(1, I.mouse_delta()) == 0 and I.button(1) == false)
  PC.freecam = false
  check("out of it, the craft has its keys back", I.key("w") == true and I.pressed("t") == true and I.scroll() == 2)
end

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_flightcam: %d checks passed", passes))
