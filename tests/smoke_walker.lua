-- SMOKE HARNESS: how it FEELS to walk around, which had no coverage at all.
--
-- Two reports, one file:
--
--   "I'm constantly flinging up into the air"
--   The controller read the up component of its own velocity every frame and
--   wrote it straight back out. So an ejection impulse — depenetration out of a
--   surface-nets seam, a crest taken at a run, the shove out of a tunnel wall —
--   was not merely tolerated, it was MAINTAINED. Section 1 fires a spike at the
--   capsule and demands it be absorbed, while still letting a jump be a jump and
--   a kerb be walkable.
--
--   "First person just doesn't feel right"
--   Three separate causes, all in section 2. The mouse needed a held right
--   button to turn your own head. The wall clip put you behind your own eyes
--   every time something was behind you, so a doorway was a camera cut. And the
--   walker's visibility self-heal ran against the camera every frame — the
--   camera turned the astronaut node off and the walker turned the AstroModel
--   child, the part you actually see, straight back on. You spent first person
--   inside your own head.
--
--   "not facing the right directions ... movement feels weird"
--   Section 4. The facing was worked out from WORLD axes and handed to a
--   model whose yaw is local to an astronaut the engine keeps upright by
--   turning it — right only near the spawn — and the strafe sign was flipped,
--   so D turned you left. Speed snapped on and off with the keys, sprint was a
--   double-tap, and the sprint key everyone reaches for toggled the camera.
--   Section 5 is the camera: a kerb jolting the view, and a roof.
--
--   "the astronaut looks stiff"
--   Section 6: the pose the walker writes onto the bones over the clips (engine
--   0.102: anim:reach / lookAt / addBoneRot). Feet planted on a slope with the
--   hips dropped to the lower one, and let go — faded, not snapped — for a jump
--   or a run; the head following the view and the tool's target, and letting
--   go of a view behind its back; a lean into a turn and a speed-up.
--
--   "swimming animations that reflect the way im actually moving"
--   Section 7. In the sea the astronaut stood upright in the idle pose. Now
--   three swim layers (stroke, side, vertical) are blended from the body's
--   real velocity in its own frame and played at a rate matched to its speed;
--   the whole rig is tipped level for a crawl, head-down for a dive, upright to
--   tread, and banked into turns; the feet stop planting and the look softens.
--
--   luajit solar/tests/smoke_walker.lua

local T, TICK = 0.0, 1 / 60
local API = {}

-- ── vec3, enough of it ──────────────────────────────────────────────────────
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
  return vec3(self.y * o.z - self.z * o.y,
              self.z * o.x - self.x * o.z,
              self.x * o.y - self.y * o.x)
end
function V:flatten(up)
  local k = self:dot(up)
  return vec3(self.x - up.x * k, self.y - up.y * k, self.z - up.z * k):normalized()
end
function V:angleTo(o)
  local d = math.max(-1, math.min(1, self:normalized():dot(o:normalized())))
  return math.acos(d)
end
function V:rotatedAround(axis, a)
  local u, c, s = axis:normalized(), math.cos(a), math.sin(a)
  return self * c + u:cross(self) * s + u * (u:dot(self) * (1 - c))
end
API.vec3 = vec3
function API.ease(a, b, rate, dt)
  local k = math.min(1.0, rate * dt)
  return a + (b - a) * k
end

API.math = setmetatable({
  clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
}, { __index = math })

-- ── the world ───────────────────────────────────────────────────────────────
-- A flat patch: up is +Y, the ground is y = 0, the crew stands on it.
local UP = vec3(0, 1, 0)

local MODEL = { name = "AstroModel", valid = true, visible = true, yaw = 0, y = -0.05 }
-- No animator until section 4 hands the model a fake one.
local animator = nil
function MODEL:animator() return animator end

local ASTRO = {
  id = 1, name = "Astronaut", valid = true, visible = true,
  x = 0, y = 1.0, z = 0, vx = 0, vy = 0, vz = 0,
  up_x = 0, up_y = 1, up_z = 0,
  grounded = true,
}
function ASTRO:getcomponent(k) return (k == "RigidBody") and { friction = 0 } or nil end
function ASTRO:children() return { MODEL } end
ASTRO.pos = vec3(0, 1.0, 0)
-- The engine keeps the astronaut upright with a shortest-arc turn, so its
-- heading drifts against the world as you walk. This is that drift, about up.
local astro_yaw = 0.0
function ASTRO:toLocal(p)
  local d = p - ASTRO.pos
  local c, s = math.cos(-astro_yaw), math.sin(-astro_yaw)
  return vec3(d.x * c + d.z * s, d.y, -d.x * s + d.z * c)
end
function ASTRO:toWorld(l)
  local c, s = math.cos(astro_yaw), math.sin(astro_yaw)
  return ASTRO.pos + vec3(l.x * c + l.z * s, l.y, -l.x * s + l.z * c)
end
ASTRO.up = UP

local CAMNODE = { id = 2, name = "Camera 1", valid = true, pos = vec3(0, 0, 0) }
function CAMNODE:lookAt() end

-- What the wall-clip sweep finds behind the camera. nil = clear sky.
local wall_at = nil
-- How high a roof is over the crew (the camera's look straight up). nil = sky.
local roof_at = nil
-- What the walker's ground probe finds under the crew. true = ground.
local ground_under = true
-- The ground's height under a point (section 6 tilts it), and its normal.
local slope = 0.0
local function ground_y(x) return slope * x end

function API.spherecast(origin, dir, radius, dist)
  -- Straight up is the roof (the camera keeps its pivot under it), anything
  -- else the wall behind.
  if dir.y > 0.9 then
    if roof_at and roof_at <= dist then return { node = { id = 98 }, distance = roof_at } end
    return nil
  end
  if wall_at and wall_at <= dist then
    return { node = { id = 99 }, distance = wall_at }
  end
  return nil
end
function API.raycast(a, ...)
  if type(a) == "table" then
    local dir, dist = ...
    if dir.y < 0 then
      -- The walker's foot probe, straight down onto the (maybe tilted) ground.
      local d = a.y - ground_y(a.x)
      if not ground_under or d < 0 or d > dist then return nil end
      local n = vec3(-slope, 1, 0):normalized()
      return { x = a.x, y = a.y - d, z = a.z, nx = n.x, ny = n.y, nz = n.z, distance = d }
    end
    -- The camera's vector form, looking for a roof.
    if roof_at and roof_at <= dist then return { node = { id = 98 }, distance = roof_at } end
    return nil
  end
  -- The walker's scalar form: raycast(x,y,z, dx,dy,dz, dist, ignore).
  if ground_under then return { x = 0, y = 0, z = 0, distance = 1.0 } end
  return nil
end

local keys, presses, scroll, buttons, clicks = {}, {}, 0.0, {}, {}
local mouse_locked = false
API.input = {
  key = function(k) return keys[k] == true end,
  pressed = function(k) return presses[k] == true end,
  clicked = function(b) return clicks[b] == true end,
  button = function(b) return buttons[b] == true end,
  scroll = function() return scroll end,
  mouse_delta = function() return 0, 0 end,
  setMouseLocked = function(v) mouse_locked = v end,
  aimYaw = function() return 0 end,
}
local reduced_motion = false
local shake = 0.0
API.save = { get = function(k) return (k == "cam.shake") and shake or nil end,
             set = function() end }
API.access = { reducedMotion = function() return reduced_motion end }
API.math.random = function() return 1.0 end   -- shake is deterministic here
local steps = 0
API.audio = { play = function(clip) if clip:find("footstep") then steps = steps + 1 end end }
-- The planet under the patch, far below: only its centre matters, to the
-- camera's pivot, which measures a step up as distance from it.
API.space = {
  dominant = function() return "Ground" end,
  body = function() return { x = 0, y = -1000, z = 0 } end,
}
API.net = { isMine = function() return true end }
API.log = function() end
API.find = function(n) return (n == "Astronaut") and ASTRO or nil end

-- ── script loading ──────────────────────────────────────────────────────────
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
API.findScripts = function(kind) return envs[kind] and { envs[kind] } or {} end

local walker = load_script("solar/scripts/planet_walker.lua", "planet_walker")
walker.node = ASTRO          -- the camera acquires its subject through this
local cam = load_script("solar/scripts/planet_camera.lua", "planet_camera")
-- Panels: present, and shut, unless a test opens one.
local fac_open, ops_open = false, false
envs.facility_menu = { isOpen = function() return fac_open end, node = { valid = true } }
envs.ops_board = { isOpen = function() return ops_open end, node = { valid = true } }
envs.inventory_panel = { open = false, node = { valid = true } }
envs.orbit_map = { map_view = false, node = { valid = true } }
envs.game_manager = { loading = false, node = { valid = true } }
-- The sea: nil (dry land) until section 7 floods the patch to `sea_y`.
local sea_y = nil
envs.climate = { seaDepth = function(x, y, z) return sea_y and (sea_y - y) or nil end, node = { valid = true } }

walker.start(ASTRO)

local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    ASTRO.pos = vec3(ASTRO.x, ASTRO.y, ASTRO.z)
    if animator then
      animator.last_pos = animator.pos
      animator.rot, animator.pos, animator.reaches, animator.looks, animator.set = {}, {}, {}, {}, {}
      animator.queued = false
    end
    walker.update(ASTRO, TICK)
    cam.lateUpdate(CAMNODE, TICK)
    presses, clicks = {}, {}
  end
end
local function press(k) presses[k] = true end

-- The up component of the crew's velocity — the number every fling is made of.
local function vup() return ASTRO.vx * 0 + ASTRO.vy * 1 + ASTRO.vz * 0 end

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

-- ── 1. THE FLING ────────────────────────────────────────────────────────────
tick(3)
check("standing still, nothing pushes the crew upward", vup() <= walker.params.step_pop,
  string.format("%.2f m/s", vup()))

-- The solver ejects the capsule out of a terrain seam at 18 m/s. Before the
-- fix, the next frame read that back and wrote it out again — and the frame
-- after that, and the frame after that. THIS is the bug.
ASTRO.vy = 18.0
tick(1)
check("a depenetration spike is absorbed, not maintained",
  vup() <= walker.params.step_pop + 1e-6, string.format("%.2f m/s", vup()))
tick(5)
check("...and does not come back on later frames",
  vup() <= walker.params.step_pop + 1e-6, string.format("%.2f m/s", vup()))

-- But a KERB still gets walked up. The clamp is a ceiling, not a floor: a small
-- contact impulse is how you get over a step, and pinning it to zero would catch
-- the capsule on every seam in the mesh.
ASTRO.vy = walker.params.step_pop * 0.5
tick(1)
check("a kerb-sized nudge is still allowed through",
  math.abs(vup() - walker.params.step_pop * 0.5) < 1e-6, string.format("%.2f m/s", vup()))

-- A JUMP IS STILL A JUMP, and it survives the ground probe. The probe reaches
-- 1.6 m down, so for the first fraction of a second the crew is still "grounded"
-- by it — and a naive clamp would take the jump straight back off.
ASTRO.vy = 0
press("space")
tick(1)
check("SPACE still jumps", math.abs(vup() - walker.params.jump) < 1e-6,
  string.format("%.2f m/s", vup()))
local held = true
for _ = 1, 12 do
  tick(1)
  if vup() < walker.params.jump - 1e-6 then held = false end
end
check("...and the ground probe does not cancel it a frame later", held,
  string.format("%.2f m/s after 12 frames", vup()))

-- Terminal velocity: a long fall that outruns the collider goes through it.
ground_under = false
ASTRO.grounded = false
ASTRO.vy = -900.0
tick(1)
check("a fall is capped at terminal velocity", vup() >= -walker.params.fall_max - 1e-6,
  string.format("%.0f m/s", vup()))

-- And a mid-air contact — scraping a cliff on the way down — cannot launch you
-- either. This is the same bug wearing the other hat, and it is how a crash
-- ended with the crew in the void.
ASTRO.vy = 55.0
tick(1)
check("an airborne contact cannot hand out more than a jump",
  vup() <= walker.params.jump + 1e-6, string.format("%.2f m/s", vup()))
ground_under, ASTRO.grounded, ASTRO.vy = true, true, 0
tick(20)

-- ── 2. FIRST PERSON IS A MODE ───────────────────────────────────────────────
check("the game starts in third person", cam.firstPerson == false)
check("...with the body drawn", ASTRO.visible == true and MODEL.visible == true)

-- Scroll all the way in. The camera must stop at its closest ORBIT first —
-- there is no mushy half-metre where it sits inside the character's chest.
scroll = 20.0
tick(1)
scroll = 0.0
tick(1)
check("scrolling in stops at the closest orbit, not inside the crew",
  cam.firstPerson == false
    and math.abs(cam.params.distance - cam.params.min_distance) < 1e-6,
  string.format("%.2f m", cam.params.distance))

-- One more click and you're behind the eyes.
scroll = 1.0
tick(1)
scroll = 0.0
tick(1)
check("one more click drops you into first person", cam.firstPerson == true)
check("...the mouse steers without holding a button", mouse_locked == true)
check("...the body is not drawn", ASTRO.visible == false)
-- The eyes, not the orbit pivot. The capsule is 2.0 m tip to tip about its
-- origin, so the crown is at +1.0 — put the camera at the third-person pivot
-- (1.2) and first person is a drone hovering over the character's head.
local eye = (CAMNODE.pos - ASTRO.pos):length()
check("...and the camera is at eye height, inside the capsule, not above it",
  eye > 0.5 and eye < 1.0, string.format("%.2f m up a 1.00 m half-capsule", eye))
-- THE ONE THAT SHIPPED BROKEN. The walker's self-heal turned the model child
-- back on every frame, and the model is the part with a face on it.
check("...and neither is the model child you would be inside of",
  MODEL.visible == false, tostring(MODEL.visible))

-- A panel needs a pointer. A grabbed mouse has none, so the panels take it back.
fac_open = true
tick(2)
check("a facility panel gets the cursor back", mouse_locked == false)
fac_open = false
tick(2)
check("...and first person takes it again when the panel closes", mouse_locked == true)

-- ESC IS A WAY OUT. First person holds the mouse, and the HUD's ☰ button — the
-- only route back to the main menu — needs a pointer. A mode you can only leave
-- by knowing about the scroll wheel is a trap.
press("escape")
tick(1)
check("Esc leaves first person", cam.firstPerson == false)
check("...and gives the cursor back", mouse_locked == false)
-- Back in, to finish the scroll test below.
scroll = 20.0; tick(1); scroll = 1.0; tick(1); scroll = 0.0; tick(1)
check("...and you can get straight back in", cam.firstPerson == true)

-- One click out and you are back on the shoulder — not stuck cycling through
-- the same click because the snap-in threshold keeps catching you.
scroll = -1.0
tick(1)
scroll = 0.0
tick(1)
check("one click out leaves first person", cam.firstPerson == false,
  string.format("%.2f m", cam.params.distance))
check("...and the body comes back", ASTRO.visible == true and MODEL.visible == true)

-- ── 3. A WALL IS NOT A CAMERA CUT ───────────────────────────────────────────
-- How far the camera actually sits behind the look-at point — the number the
-- wall clip moves, read off the node the way the renderer would.
local function camera_back()
  local head = ASTRO.pos + UP * cam.params.height
  return (CAMNODE.pos - head):length()
end

cam.params.distance = 7.0
tick(60)
check("third person sits at the requested distance",
  math.abs(camera_back() - 7.0) < 0.05, string.format("%.2f m", camera_back()))

wall_at = 0.5                      -- something right behind you: a doorway
tick(1)
check("a wall pulls the camera in IMMEDIATELY — one frame inside it is one too many",
  camera_back() < 0.5, string.format("%.2f m", camera_back()))
check("...and the body stops drawing", cam.hidesBody == true)
-- THE FIX. Being close to a wall is not a request to change camera modes, and
-- treating it as one is why walking through the base felt like the view was
-- flinching in and out of your own eye sockets.
check("...but it does NOT put you in first person", cam.firstPerson == false)
check("...so the mouse still needs a button", mouse_locked == false)

wall_at = nil
tick(1)
local eased = camera_back()
check("stepping clear does not pop the camera back in one frame",
  eased < 3.0, string.format("%.2f m of 7.00", eased))
tick(60)
check("...it glides back out", math.abs(camera_back() - 7.0) < 0.2,
  string.format("%.2f m", camera_back()))
check("...and the body is drawn again", ASTRO.visible == true and MODEL.visible == true)

-- ── 4. MOVING AND FACING ───────────────────────────────────────────────────
-- A fake animator: enough of one to see which layers the walker drives and
-- what the Base layer is showing.
local DUR = { idle = 4, walk = 1, run = 0.72, sprint = 0.62, jump = 0.5, fall = 1.6,
              land = 0.55, lean = 2, look = 2 }
animator = { weights = {}, seeks = {}, params = {}, base = "idle", base_t = 0,
             rot = {}, pos = {}, last_pos = {}, reaches = {}, looks = {}, set = {} }
function animator:clips() return { "idle", "walk", "run", "sprint", "jump", "fall", "land" } end
function animator:duration(n) return DUR[n] end
animator.layer_state, animator.speeds = {}, {}
function animator:state(layer)
  if layer and layer ~= "Base" then return self.layer_state[layer] end
  return self.base
end
function animator:time() return T - self.base_t end
function animator:restart(n) self.base, self.base_t = n, T end
function animator:crossfade(n, f, layer)
  if layer and layer ~= "Base" then self.layer_state[layer] = n return end
  if self.base ~= n then self.base, self.base_t = n, T end
end
function animator:setSpeed(v, layer) self.speeds[layer or ""] = v end
function animator:setLayerWeight(l, w) self.weights[l] = w end
function animator:seek(t, l) self.seeks[l] = t end
function animator:setParam(k, v) self.params[k] = v end
-- The per-frame pose calls, as the last frame made them (cleared each tick).
-- `queued`: whether this frame has made any pose call yet (see boneWorld).
function animator:addBoneRot(b, y, p, r, w) self.queued = true; self.rot[b] = { y = y, p = p, r = r } end
function animator:setBoneRot(b, y, p, r, w) self.queued = true; self.set[b] = { y = y, p = p, r = r, w = w or 1 } end
function animator:addBonePos(b, v) self.queued = true; self.pos[b] = (self.pos[b] or vec3(0, 0, 0)) + v end
function animator:reach(b, t, o) self.queued = true; self.reaches[b] = { t = t, pole = o and o.pole, w = o and o.weight or 1 } end
function animator:lookAt(bones, t, o)
  self.queued = true
  self.looks[bones[#bones]] = { t = t, w = o and o.weight or 1, limit = o and o.limit }
end
-- Where the posed bones are: the idle stance's ankles 14 cm either side of the
-- centre (the model's +X is its left), the head 0.6 m up — in the model's
-- frame, turned by its yaw and then the astronaut's.
-- MaleArm, the armature root, is where the walker finds the soles' plane: its
-- rest height over them, plus what the walker has moved it by so far this
-- frame — or, before this frame has made any pose call, last frame's drawn
-- pose with last frame's writes (what 0.117.0-rc2 does, card 0413). Here
-- the soles ride 6 cm over the capsule's bottom, as they do in the game.
local BONES = { ["Foot.Left"] = vec3(0.1389, -0.868, -0.0858), ["Foot.Right"] = vec3(-0.1389, -0.868, -0.0858),
                ["Thigh.Left"] = vec3(0.1, -0.03, 0), ["Thigh.Right"] = vec3(-0.1, -0.03, 0),
                Head = vec3(0, 0.6, 0), MaleArm = vec3(0, -0.94 + 1.61496, 0) }
function animator:boneWorld(b)
  local l = BONES[b]
  if not l then return nil end
  if b == "MaleArm" then
    l = l + ((self.queued and self.pos.MaleArm or (not self.queued and self.last_pos.MaleArm)) or vec3(0, 0, 0))
  end
  local c, s = math.cos(MODEL.yaw), math.sin(MODEL.yaw)
  return ASTRO:toWorld(vec3(l.x * c + l.z * s, l.y, -l.x * s + l.z * c))
end

-- The model's facing, in the astronaut's frame (+Z is yaw 0).
local function facing() return math.sin(MODEL.yaw), math.cos(MODEL.yaw) end
local function speed() return math.sqrt(ASTRO.vx ^ 2 + ASTRO.vz ^ 2) end
cam.params.follow_yaw = 0      -- its own test, below; here the view holds still
tick(30)

-- The camera looks down −Z, so D — to the right — is +X.
keys.d = true
tick(1)
check("a start picks up over a step or two, not in one frame",
  speed() > 0.1 and speed() < walker.params.walk * 0.5, string.format("%.2f m/s", speed()))
tick(90)
check("D walks right", ASTRO.vx > walker.params.walk * 0.95 and math.abs(ASTRO.vz) < 0.05,
  string.format("(%.2f, %.2f)", ASTRO.vx, ASTRO.vz))
local fx, fz = facing()
check("...and FACES right (the strafe sign was flipped: D turned you left)", fx > 0.99,
  string.format("facing (%.2f, %.2f)", fx, fz))
keys.d, keys.w = nil, true
tick(1)
fx, fz = facing()
check("a new heading is a turn, not a snap", fx > 0.3, string.format("facing (%.2f, %.2f)", fx, fz))
tick(60)
fx, fz = facing()
check("W faces away from the camera", fz < -0.99, string.format("facing (%.2f, %.2f)", fx, fz))
keys.w = nil
tick(60)
check("letting go stops", speed() < 0.05, string.format("%.2f m/s", speed()))
fx, fz = facing()
check("...and the crew keeps the heading they stopped on", fz < -0.99,
  string.format("facing (%.2f, %.2f)", fx, fz))

-- Away from the spawn the astronaut node has turned under us: the model's yaw
-- is in ITS frame, and a yaw computed from world axes points the wrong way.
astro_yaw = 1.2
keys.w = true
tick(90)
local lx, lz = facing()
local c, sn = math.cos(astro_yaw), math.sin(astro_yaw)
local wx, wz = lx * c + lz * sn, -lx * sn + lz * c
check("with the body's frame turned, it still faces the way it walks", wz < -0.99,
  string.format("world facing (%.2f, %.2f)", wx, wz))
astro_yaw = 0.0

-- Sprint is a HELD key now, and it is no longer the key that grabs the mouse.
keys.shift = true
tick(90)
check("holding SHIFT sprints", math.abs(speed() - walker.params.run) < 0.1,
  string.format("%.2f m/s", speed()))
check("...and the Gait blend slides toward the sprint", (animator.params.gait or 0) > 1.5,
  tostring(animator.params.gait))
check("...and SHIFT does not toggle the look lock", cam.shiftlock == false)
keys.shift = nil
tick(90)
check("letting SHIFT go drops back to the walk", math.abs(speed() - walker.params.walk) < 0.1,
  string.format("%.2f m/s", speed()))

-- The legs: at the default pace the Gait blend owns them, sitting on the run
-- clip, and scrubbed by the walker.
check("at a jog the Gait layer carries the legs", (animator.weights.Gait or 0) > 0.95,
  tostring(animator.weights.Gait))
check("...blended to the run", math.abs((animator.params.gait or -1) - 1.0) < 0.01,
  tostring(animator.params.gait))
check("...scrubbed to the walker's phase", animator.seeks.Gait ~= nil)
-- Footsteps on the heel strikes: two a stride, and the run stride (from
-- tools/gen_astronaut_anims.py) is 3.312 m.
steps = 0
tick(180)
local want = 3.0 * walker.params.walk / 3.312 * 2
check("footsteps fall on the heel strikes, two a stride", math.abs(steps - want) <= 1.5,
  string.format("%d steps, %.1f expected", steps, want))
keys.w = nil
tick(60)
check("standing, the gait lets go of the body", (animator.weights.Gait or 0) < 0.05,
  string.format("gait %.2f", animator.weights.Gait or 0))

-- Jump → fall → land, and a kerb is none of them.
press("space")
tick(1)
check("SPACE plays the jump", animator.base == "jump", animator.base)
ground_under, ASTRO.grounded = false, false
tick(40)
check("...which turns into a fall", animator.base == "fall", animator.base)
ground_under, ASTRO.grounded = true, true
ASTRO.vy = -8
tick(1)
check("touching down plays the landing", animator.base == "land", animator.base)
ASTRO.vy = 0
tick(60)
animator.base = "idle"
ground_under, ASTRO.grounded = false, false
tick(5)
ground_under, ASTRO.grounded = true, true
tick(1)
check("a moment with nothing underfoot (a kerb, a crest) is not a fall",
  animator.base == "idle", animator.base)

-- AIMING: the look lock (now MIDDLE MOUSE or ALT) turns the body to the view,
-- so a strafe is a strafe.
clicks[2] = true
tick(1)
check("MIDDLE MOUSE toggles the look lock", cam.shiftlock == true)
keys.d = true
tick(60)
fx, fz = facing()
check("...and with it on, strafing keeps facing the view", fz < -0.99 and ASTRO.vx > 4,
  string.format("facing (%.2f, %.2f) moving %.2f", fx, fz, ASTRO.vx))
keys.d = nil
press("alt")
tick(1)
check("ALT toggles it too", cam.shiftlock == false)
tick(60)

-- FOLLOW: walking sideways without holding the view, the orbit drifts round
-- behind the walk; backing toward the camera, it holds still.
cam.params.follow_yaw = 0.5
keys.a = true
tick(120)
check("walking sideways, the view drifts round behind you", cam.flat_x < -0.2,
  string.format("view (%.2f, %.2f)", cam.flat_x, cam.flat_z))
keys.a = nil
cam.face(0, 0, -1)
tick(2)
keys.s = true
tick(120)
check("...but backing up, it holds", math.abs(cam.flat_x) < 0.01 and cam.flat_z < -0.99,
  string.format("view (%.2f, %.2f)", cam.flat_x, cam.flat_z))
keys.s = nil
cam.params.follow_yaw = 0
tick(60)

-- ── 5. THE CAMERA ON UNEVEN GROUND, AND UNDER A ROOF ────────────────────────
local before = CAMNODE.pos
ASTRO.y = ASTRO.y + 0.3          -- the solver pops the capsule up a kerb
tick(1)
local moved = (CAMNODE.pos - before):length()
check("a kerb does not jolt the view: the pivot eases up after it", moved < 0.12,
  string.format("%.2f m in one frame", moved))
tick(40)
moved = (CAMNODE.pos - before):length()
check("...and catches up", math.abs(moved - 0.3) < 0.02, string.format("%.2f m", moved))

roof_at = 2.6
tick(120)
check("under a roof the orbit comes in", math.abs(camera_back() - cam.params.indoor_distance) < 0.1,
  string.format("%.2f m", camera_back()))
check("...without touching your zoom", cam.params.distance == 7.0)
-- A bore lower than the pivot (the laser at low charge cuts 2.2 m): the
-- pivot drops under the rock instead of looking out from inside it.
roof_at = 0.8
tick(5)
check("a roof lower than the pivot brings the pivot under it",
  cam.pivot_y - ASTRO.y < 0.8, string.format("pivot %.2f m above the crew, roof at 0.8", cam.pivot_y - ASTRO.y))
roof_at = nil
tick(120)
check("stepping outside, it goes back out", math.abs(camera_back() - 7.0) < 0.1,
  string.format("%.2f m", camera_back()))

-- ── 6. THE POSE OVER THE CLIPS ──────────────────────────────────────────────
ASTRO.y = 1.0                    -- back down off section 5's kerb: soles on y = 0
tick(120)
-- The pose-scrub layers that faked all of this before the engine could bend a
-- bone are gone, and nothing asks for them.
local stale = {}
for _, l in ipairs({ "Lean", "Look", "PlantLeft", "PlantRight", "Walk", "Run", "Sprint" }) do
  if animator.weights[l] or animator.seeks[l] then stale[#stale + 1] = l end
end
check("no pose-scrub layer is driven any more", #stale == 0, table.concat(stale, " "))

-- FEET. Standing on flat ground both feet reach for it, at full weight.
local function reach_h(side)
  local r = animator.reaches["Foot." .. side]
  return r and r.t.y, r and r.w
end
local ly, lw = reach_h("Left")
local ry, rw = reach_h("Right")
check("standing, both feet reach for the ground", lw and rw and lw > 0.95 and rw > 0.95,
  string.format("weights %s %s", tostring(lw), tostring(rw)))
check("...at the ankle's height over it", ly and math.abs(ly - 0.072) < 0.01 and math.abs(ry - 0.072) < 0.01,
  string.format("%.3f %.3f", ly or -1, ry or -1))
local lr = animator.reaches["Foot.Left"]
check("...knees bending forward, over the foot", lr and lr.pole and (lr.pole - lr.t):dot(UP) > 0.3,
  lr and lr.pole and tostring((lr.pole - lr.t):dot(UP)))

-- Tilt the ground: 30 degrees rising toward +X. The model faces −Z (W, above),
-- so its left foot (+X of the model = −X of the world, turned π) is downhill.
slope = math.tan(math.rad(30))
tick(60)
ly, lw = reach_h("Left")
ry, rw = reach_h("Right")
local fl = animator:boneWorld("Foot.Left")
local fr = animator:boneWorld("Foot.Right")
check("on a slope each foot reaches for the ground under IT",
  ly and ry and math.abs(ly - (ground_y(fl.x) + 0.072 * math.cos(math.rad(30)))) < 0.01
    and math.abs(ry - (ground_y(fr.x) + 0.072 * math.cos(math.rad(30)))) < 0.01,
  string.format("left %.3f want %.3f, right %.3f want %.3f", ly or -1, ground_y(fl.x), ry or -1, ground_y(fr.x)))
local drop = animator.pos.MaleArm and -animator.pos.MaleArm.y or 0
local sole = ASTRO.y - 0.94
local low = sole - math.min(ground_y(fl.x), ground_y(fr.x))
check("...and the hips drop so the LOWER foot gets there", math.abs(drop - low) < 0.01,
  string.format("dropped %.3f, the low foot is %.3f down", drop, low))
-- The knees are the reach's to bend (0.103 fixed a bent limb's reach); the
-- walker no longer sets them itself.
check("...and the knees are left to the reach",
  animator.set["Shin.Left"] == nil and animator.set["Shin.Right"] == nil)
local foot = animator.looks["Foot.Left"]
check("...with the sole turned to the slope", foot and foot.w > 0.95, foot and tostring(foot.w))

-- Start walking: the stride owns the feet, and the plant lets go — faded.
keys.w = true
tick(1)
ly, lw = reach_h("Left")
check("setting off, the planted feet fade out rather than snapping",
  lw and lw > 0.3 and lw < 0.999, tostring(lw))
tick(40)
ly, lw = reach_h("Left")
check("...and a stride's feet are the clip's", not lw or lw < 0.02, tostring(lw))
keys.w = nil
tick(90)
ly, lw = reach_h("Left")
check("stopping, they plant again", lw and lw > 0.95, tostring(lw))

-- A jump lets go of the ground at once — but by fading, never snapping.
press("space")
tick(1)
ground_under, ASTRO.grounded = false, false
ly, lw = reach_h("Left")
check("a jump starts letting go of the ground", lw and lw < 0.999, tostring(lw))
tick(30)
ly, lw = reach_h("Left")
check("...and in the air the feet are the clip's", not lw or lw < 0.02, tostring(lw))
ground_under, ASTRO.grounded, ASTRO.vy = true, true, 0
slope = 0.0
tick(90)

-- LOOK. The body faces −Z; the camera turns to look off to the right (−X of
-- the model facing −Z is... +X of the world is the model's right).
local function look_dir()
  local l = animator.looks.Head
  if not l then return nil, 0 end
  local head = animator:boneWorld("Head")
  return (l.t - head):normalized(), l.w
end
cam.face(1, 0, -1)
tick(60)
local d, w = look_dir()
check("the head turns toward where the camera looks",
  d and w > 0.8 and d.x > 0.6 and d.z < -0.6, d and string.format("(%.2f, %.2f, %.2f) w %.2f", d.x, d.y, d.z, w))
-- (Back hangs upside down, so a turn to the right is a + yaw of Back.)
local twist = animator.rot.Back and animator.rot.Back.y or 0
check("...the chest taking a share of the turn, the right way", twist > 0.05 and twist < 0.45,
  string.format("%.2f", twist))
cam.face(0, 0, 1)
tick(60)
d, w = look_dir()
check("a view behind the back lets the head go", w < 0.05, string.format("w %.2f", w))

-- With the tool running, the head looks at what it is working on: a spot on
-- the ground a few metres ahead (the camera sits 7 m back).
cam.face(0, -0.5, -1)
envs.tool_belt = { inUse = true, aimDist = 12.0, node = { valid = true } }
tick(60)
-- The belt publishes the point it is cutting (`aimX/Y/Z`): twelve metres down
-- the camera's ray. (The camera slides over the shoulder while a tool runs, so
-- that point is no longer straight ahead of the head — the head has to look at
-- the published point, not along the view.)
local spot = vec3(cam.cam_x, cam.cam_y, cam.cam_z) + vec3(cam.fwd_x, cam.fwd_y, cam.fwd_z) * 12.0
envs.tool_belt.aimX, envs.tool_belt.aimY, envs.tool_belt.aimZ = spot.x, spot.y, spot.z
tick(60)
d, w = look_dir()
local aim = (spot - animator:boneWorld("Head")):normalized()
check("mining, the head looks at the rock being cut", d and d:angleTo(aim) < math.rad(3) and w > 0.8,
  d and string.format("%.1f deg off, w %.2f", math.deg(d:angleTo(aim)), w))

-- OVER THE SHOULDER. With the crew dead centre, the body hides the face the
-- laser is cutting; while a tool runs the camera eases ~0.6 m to the right of
-- the crew (screen-right = forward × up), and back once it stops.
local function side_offset()
  local f = vec3(cam.fwd_x, cam.fwd_y, cam.fwd_z)
  local right = f:cross(vec3(0, 1, 0)):normalized()
  return (vec3(cam.cam_x, cam.cam_y, cam.cam_z) - ASTRO.pos):dot(right)
end
check("a tool in use puts the camera over the right shoulder",
  side_offset() > 0.45 and side_offset() < 0.7, string.format("%.2f m", side_offset()))
envs.tool_belt = nil
cam.face(0, 0, -1)
tick(60)
check("...not the instant the trigger lets go", side_offset() > 0.3, string.format("%.2f m", side_offset()))
tick(120)
check("...and back behind the crew once the tool has rested", math.abs(side_offset()) < 0.05,
  string.format("%.2f m", side_offset()))

-- LEAN. Setting off leans the chest forward; stopping sits it back.
keys.w = true
tick(8)
local p = animator.rot.Back and animator.rot.Back.p or 0
check("speeding up leans the chest forward", p > 0.03 and p < 0.26, string.format("%.3f rad", p))
tick(60)
keys.w = nil
tick(8)
p = animator.rot.Back and animator.rot.Back.p or 0
check("...stopping sits it back", p < -0.03 and p > -0.21, string.format("%.3f rad", p))
tick(60)
-- A turn to the right at a run banks the body right: + roll about the
-- skeleton's forward, which is a + yaw of the MaleArm root.
keys.w = true
tick(60)
keys.w, keys.d = nil, true
tick(6)
local bank = animator.rot.MaleArm and animator.rot.MaleArm.y or 0
check("turning right at a run banks the body into the turn", bank > 0.02 and bank < 0.3,
  string.format("%.3f rad", bank))
keys.d = nil
tick(120)
check("...and standing it comes back upright",
  not animator.rot.MaleArm or math.abs(animator.rot.MaleArm.y) < 0.01,
  animator.rot.MaleArm and string.format("%.3f", animator.rot.MaleArm.y))


-- ── 7. SWIMMING ─────────────────────────────────────────────────────────────
-- The patch floods: the sea's surface 0.75 m over the crew's middle (where
-- the float rests), nothing underfoot. The harness does not move the body, so
-- depth is whatever we set; velocities are the walker's own.
local function rot(b) return animator.rot[b] or { y = 0, p = 0, r = 0 } end
local function swim_state() return walker.swimState end
cam.face(0, 0, -1)
keys = {}
ground_under, ASTRO.grounded, ASTRO.vy = false, false, 0
sea_y = ASTRO.y + 0.75
tick(1)
check("in the water the swim layers start to come in — faded, not snapped",
  (animator.weights.Swim or 0) > 0.01 and (animator.weights.Swim or 0) < 0.5, tostring(animator.weights.Swim))
tick(120)
check("treading water, the Swim layer owns the body", (animator.weights.Swim or 0) > 0.95,
  tostring(animator.weights.Swim))
check("...on the surface state", animator.layer_state.Swim == "swim_surface", tostring(animator.layer_state.Swim))
check("...blended to the tread (swimF 0)", math.abs(animator.params.swimF or 1) < 0.05, tostring(animator.params.swimF))
check("...the gait lets go", (animator.weights.Gait or 0) < 0.05, tostring(animator.weights.Gait))
check("...upright, leaning a touch into the water", rot("MaleArm").p > 0.05 and rot("MaleArm").p < 0.3,
  string.format("%.2f rad", rot("MaleArm").p))
check("...lifted so the head clears the water", animator.pos.MaleArm and animator.pos.MaleArm.y > 0.1,
  animator.pos.MaleArm and string.format("%.2f", animator.pos.MaleArm.y))
local lw = animator.reaches["Foot.Left"]
check("...and the feet no longer reach for a ground that isn't there", not lw or lw.w < 0.02,
  lw and tostring(lw.w))
check("the walker says so (the tool belt holsters the laser)", walker.swimming == true)

-- Forward: the stroke takes over as the speed builds — not on the key.
keys.w = true
tick(1)
check("setting off, a swimmer picks up speed slowly (water is thick)",
  speed() < walker.params.swim * 0.1, string.format("%.2f m/s", speed()))
check("...and the stroke blends in with it, not on the key", (animator.params.swimF or 0) < 0.2,
  tostring(animator.params.swimF))
tick(180)
check("swimming forward, the blend is the stroke (swimF +1)", (animator.params.swimF or 0) > 0.95,
  tostring(animator.params.swimF))
-- Rate: speed / the metres a crawl cycle covers, times the clock clip's length.
local want_rate = walker.params.swim / 3.0 * 1.4
check("...played at the rate the speed asks for (no slipping hands)",
  math.abs((animator.speeds.Swim or 0) - want_rate) < 0.08,
  string.format("%.2f, want %.2f", animator.speeds.Swim or -1, want_rate))
check("...the body level in the water", rot("MaleArm").p > 1.3 and rot("MaleArm").p < 1.6,
  string.format("%.2f rad", rot("MaleArm").p))
check("...riding at the surface", animator.pos.MaleArm and animator.pos.MaleArm.y > -0.3,
  animator.pos.MaleArm and string.format("%.2f", animator.pos.MaleArm.y))
local look = animator.looks.Head
check("...the head only leans toward the view, so the stroke keeps its breath",
  look and look.w < 0.35 and look.limit <= 40, look and string.format("w %.2f limit %.0f", look.w, look.limit))
keys.shift = true
tick(120)
check("faster is a faster stroke", (animator.speeds.Swim or 0) > want_rate * 1.3,
  string.format("%.2f", animator.speeds.Swim or -1))
keys.shift = nil

-- A turn rolls the swimmer into it: the view swings right, the body follows.
local turned = 0
for i = 1, 30 do
  cam.face(math.sin(i * 0.03), 0, -math.cos(i * 0.03))
  tick(1)
  turned = math.max(turned, rot("MaleArm").y)
end
check("turning right, the swimmer banks right (+ roll tips right)", turned > 0.05 and turned < 0.65,
  string.format("%.2f rad", turned))
cam.face(0, 0, -1)
tick(120)

-- Under the surface, the stroke is a breaststroke.
sea_y = ASTRO.y + 3.0
tick(2)
check("deeper, the Swim layer crossfades to the underwater state",
  animator.layer_state.Swim == "swim_under", tostring(animator.layer_state.Swim))
tick(60)

-- Dive: CTRL. Straight down turns the swimmer head-first.
keys.w = nil
keys.ctrl = true
tick(150)
check("diving straight down, the vertical layer comes in", (animator.weights.SwimVert or 0) > 0.8,
  tostring(animator.weights.SwimVert))
check("...blended to the dive (swimV -1)", (animator.params.swimV or 0) < -0.9, tostring(animator.params.swimV))
check("...and the body goes over, head-first", rot("MaleArm").p > 2.3, string.format("%.2f rad", rot("MaleArm").p))
keys.ctrl = nil
keys.space = true
tick(150)
check("climbing (SPACE), the haul up (swimV +1)", (animator.params.swimV or 0) > 0.9, tostring(animator.params.swimV))
check("...upright", math.abs(rot("MaleArm").p) < 0.3, string.format("%.2f rad", rot("MaleArm").p))
keys.space = nil
tick(120)

-- Aiming (the look lock), a strafe is a side stroke and S is a back-scull.
clicks[2] = true
tick(1)
keys.d = true
tick(150)
check("aiming, swimming sideways is the side stroke", (animator.weights.SwimSide or 0) > 0.8,
  tostring(animator.weights.SwimSide))
check("...toward the right (swimS -1)", (animator.params.swimS or 0) < -0.9, tostring(animator.params.swimS))
check("...leaning into it", rot("MaleArm").y > 0.02, string.format("%.2f rad", rot("MaleArm").y))
check("...and slower than a crawl", speed() < walker.params.swim * 0.8, string.format("%.2f m/s", speed()))
keys.d = nil
keys.s = true
tick(150)
check("aiming, backing up is the back-scull (swimF -1)", (animator.params.swimF or 0) < -0.9,
  tostring(animator.params.swimF))
check("...tipped back", rot("MaleArm").p < 0.0, string.format("%.2f rad", rot("MaleArm").p))
keys.s = nil
press("alt")
tick(120)

-- Falling in is not a dive: sinking from the splash stays feet-first.
sea_y = ASTRO.y - 3
tick(30)
ASTRO.vy = -8
tick(3)
sea_y = ASTRO.y + 1.5
local worst = 0
for _ = 1, 40 do tick(1); worst = math.max(worst, rot("MaleArm").p) end
check("sinking after a fall in stays feet-first (only a dive turns you over)", worst < 0.7,
  string.format("%.2f rad at most", worst))
sea_y = ASTRO.y + 0.75
tick(120)

-- Out: feet on the bottom in the shallows, walking up the beach.
keys.w = true
tick(60)
ground_under, ASTRO.grounded = true, true
sea_y = ASTRO.y + 0.3
tick(90)
check("climbing out, the swim lets go", (animator.weights.Swim or 1) < 0.05, tostring(animator.weights.Swim))
check("...and the gait takes the legs back", (animator.weights.Gait or 0) > 0.9, tostring(animator.weights.Gait))
check("...standing up straight", math.abs(rot("MaleArm").p) < 0.05, string.format("%.2f rad", rot("MaleArm").p))
check("...and the walker says so", walker.swimming == false)
keys.w = nil
sea_y = nil
tick(60)

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("WALKER SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("WALKER SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
os.exit(1)
