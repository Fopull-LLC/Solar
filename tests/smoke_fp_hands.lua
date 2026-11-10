-- SMOKE: first person with the body drawn (playtest 2026-11-09d: "the fast
-- walking arm jitter in first person"; "the first person hands should be more
-- immersive and use things like ik").
--
--   * the walk bob follows the walker's gait phase as a smooth curve (the old
--     |cos| of speed / 1.6 m bounced 5.4 times a second at a sprint, with a
--     corner at every bounce), and its second difference stays small at a
--     sprint whatever the frame rate;
--   * fp_body is on the player's Astronaut, is posed from the camera's own
--     pass (after the view is placed), and costs nothing out of first person;
--   * suit.lua and item_hand ask it, so the helmet goes away and a case is
--     held in the view.
--
--   luajit solar/tests/smoke_fp_hands.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function read(p) local f = assert(io.open("solar/" .. p), p); local s = f:read("*a"); f:close(); return s end

local tb = read("scripts/tool_belt.lua")
local pw = read("scripts/planet_walker.lua")
local pc = read("scripts/planet_camera.lua")
local sys = read("scenes/system.ron")

-- 1. the bob: from the gait phase, no |cos| corner
check(tb:find("gaitPhase", 1, true) ~= nil, "tool_belt: the bob does not read the walker's gaitPhase")
check(tb:find("math.abs(math.cos(view.bob))", 1, true) == nil, "tool_belt: the |cos| bob (a corner at each bounce) is back")
check(pw:find("gaitPhase, gaitAmount = phase, gait_amt", 1, true) ~= nil, "planet_walker: gaitPhase is not published")
-- the curve itself (tool_belt view.springs): a sprint at 8.7 m/s over a
-- 5.58 m stride, sampled at 30, 60 and 144 fps; the old one for contrast
local function bob(ph, a) return (math.cos(ph * 4 * math.pi) * 0.5 + 0.5) * 0.008 * a end
local function old(ph) return math.abs(math.cos(ph)) * 0.008 end
for _, fps in ipairs({ 30, 60, 144 }) do
  local dt = 1 / fps
  local worst, worst_old, crossings = 0, 0, 0
  local prev = {}
  for i = 0, fps * 3 do
    local t = i * dt
    local ph = (t * 8.7 / 5.58) % 1
    local v, o = bob(ph, 1.35), old(t * (8.7 / 1.6) * math.pi)
    prev[#prev + 1] = { v, o }
    local n = #prev
    if n >= 3 then
      worst = math.max(worst, math.abs(prev[n][1] - 2 * prev[n - 1][1] + prev[n - 2][1]))
      worst_old = math.max(worst_old, math.abs(prev[n][2] - 2 * prev[n - 1][2] + prev[n - 2][2]))
    end
  end
  -- a smooth curve's second difference falls with the square of the frame time
  check(worst < 0.0105 * 0.008 * 1.35 * (60 / fps) ^ 2 * 10, string.format("bob at %d fps: d2 %.5f m", fps, worst))
  check(worst < worst_old, string.format("bob at %d fps: no smoother than the old (%.5f vs %.5f)", fps, worst, worst_old))
end
-- one dip per footfall: two a stride (3.1 a second at 8.7 m/s, not 5.4)
do
  local n, last = 0, nil
  for i = 0, 1000 do
    local ph = 0.1 + i / 1000
    local d = bob(ph, 1) - bob(ph - 0.001, 1)
    if last and last > 0 and d <= 0 then n = n + 1 end
    last = d
  end
  check(n == 2, "bob: " .. n .. " peaks a stride (want 2, one per footfall)")
end

-- 2. fp_body: on the player, posed after the camera, idle out of first person
check(sys:find('kind: "fp_body"', 1, true) ~= nil, "system.ron: the Astronaut has no fp_body")
local hook = pc:find("fpb.afterCamera(node, dt)", 1, true)
local place = pc:find("    place_camera(node, dt)\n", 1, true)
check(hook ~= nil and place ~= nil and hook > place, "planet_camera: fp_body.afterCamera is not called after place_camera")
check(read("scripts/suit.lua"):find("fpb.active == true", 1, true) ~= nil, "suit.lua: the helmet is not put away in first person")
check(read("scripts/item_hand.lua"):find("function fpCarry", 1, true) ~= nil, "item_hand: no fpCarry")
check(tb:find("function fpHold", 1, true) ~= nil, "tool_belt: no fpHold")

-- fp_body in a stub world: out of first person it does nothing and costs nothing
local env = setmetatable({}, { __index = _G })
local calls = 0
env.params = { enabled = true, back = 0.05, back_down = 0.13, press_reach = 2.4, press_in = 0.17, press_hold = 0.12,
               press_out = 0.32, arm_len = 0.62 }
env.time = 1.0
env.save = { get = function() return nil end, set = function() end }
local pcs = { firstPerson = false, valid = true }
local pws = { onFoot = true, valid = true }
env.findScript = function(k)
  calls = calls + 1
  if k == "planet_camera" then return pcs end
  if k == "planet_walker" then return pws end
  return nil
end
env.input = { pressed = function() return false end }
local chunk = assert(loadfile("solar/scripts/fp_body.lua", "t", env))
chunk()
local node = { valid = true, children = function() return {} end }
env.start(node)
env.update(node, 0.016)
check(env.active == false, "fp_body: active in third person")
env.afterCamera({ valid = true }, 0.016)
check(env.probe.on == false, "fp_body: posed in third person")
pcs.firstPerson = true
env.update(node, 0.016)
check(env.active == true, "fp_body: not active in first person on foot")
pws.onFoot = false
env.update(node, 0.016)
check(env.active == false, "fp_body: active off foot (aboard)")
pws.onFoot, pcs.cockpit = true, true
env.update(node, 0.016)
check(env.active == false, "fp_body: active in the cockpit's seat view")
pcs.cockpit = nil
env.setEnabled(false)
env.update(node, 0.016)
check(env.active == false, "fp_body: active while switched off")

-- 3. THE BODY UNDER THE EYE in every stance (playtest 2026-11-10: "crouching
-- in first person makes your body clip into the camera; jumping too"). A
-- stub rig: the Astronaut at the origin (up +Y, unrotated), the model under
-- it, its Head bone a fixed point in the model's frame (moved by a "stance");
-- the camera at the eye over the capsule, looking along +Z.
do
  local V = {}
  V.__index = V
  local function v3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
  V.__add = function(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
  V.__sub = function(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
  V.__mul = function(a, k) return v3(a.x * k, a.y * k, a.z * k) end
  V.__unm = function(a) return v3(-a.x, -a.y, -a.z) end
  function V.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
  function V.cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
  function V.length(a) return math.sqrt(a:dot(a)) end
  function V.normalized(a) local l = a:length(); return l > 0 and a * (1 / l) or a end
  local e2 = setmetatable({}, { __index = _G })
  e2.vec3 = v3
  e2.params = { enabled = true, back = 0.02, back_down = 0.13, press_reach = 2.4, press_in = 0.17, press_hold = 0.12,
                press_out = 0.32, arm_len = 0.62, neck_behind = 0.04, neck_below = 0.14, neck_max = 0.45,
                follow_down = 0.14, follow_up = 0.10, neck_ease = 8.0, neck_ease_max = 0.06, neck_rest = 0.21, drop_dead = 0.10 }
  e2.time = 1.0
  e2.save = { get = function() return nil end, set = function() end }
  local EYE_H = 0.73
  local pc2 = { firstPerson = true, valid = true, params = { eye_height = EYE_H } }
  local pw2 = { onFoot = true, valid = true, params = { face_offset = 0 }, eyeDrop = 0 }
  e2.findScript = function(k)
    if k == "planet_camera" then return pc2 end
    if k == "planet_walker" then return pw2 end
    return nil
  end
  e2.input = { pressed = function() return false end }
  local head = v3(0, 0.55, 0.04)            -- the Head joint in the model's frame (a stance moves it)
  local model = { name = "AstroModel", valid = true, x = 0, y = 0, z = 0, yaw = 0 }
  local function m_world(v)
    local c, s_ = math.cos(model.yaw), math.sin(model.yaw)
    return v3(v.x * c + v.z * s_ + model.x, v.y + model.y, -v.x * s_ + v.z * c + model.z)
  end
  function model.toWorld(_, v) return m_world(v) end
  function model.children() return {} end
  local an = { reach = function() end, lookAt = function() end, addBoneRot = function() end }
  function an.boneWorld(_, b) if b == "Head" then return m_world(head) end return nil end
  function model.animator() return an end
  local A = { valid = true, worldPos = v3(0, 0, 0) }
  function A.children() return { model } end
  function A.worldUp() return v3(0, 1, 0) end
  function A.toLocal(_, v) return v end
  local eye = v3(0, EYE_H, 0)
  local cn = { valid = true }
  cn.worldPos = eye
  function cn.worldForward() return v3(0, 0, 1) end
  function cn.worldRight() return v3(1, 0, 0) end
  function cn.worldUp() return v3(0, 1, 0) end
  assert(loadfile("solar/scripts/fp_body.lua", "t", e2))()
  e2.start(A)
  e2.update(A, 0.016)
  check(e2.active == true, "stance: fp_body not active in the stub")
  local function frame(walker_y)
    model.y = walker_y or model.y            -- (the walker writes the height each update)
    e2.afterCamera(cn, 0.016)
    local h = m_world(head) - cn.worldPos
    return h
  end
  -- standing: the neck behind and under the eye
  local h = frame(0)
  check(h.z <= -(0.04 + 0.02) + 1e-6 and h.z > -0.2, string.format("stance stand: neck %.3f m ahead of the eye", h.z))
  check(h.y <= -0.14 + 1e-6, string.format("stance stand: neck %.3f m under the eye", h.y))
  check(math.abs(h.x) < 1e-6, "stance stand: neck off to the side")
  check(math.abs(model.y) < 1e-6, "stance stand: the body moved up or down with nothing to fix")
  -- a crouch: the chest leans the neck 18 cm forward and the clip's drop is
  -- 8 cm short of the eye's 25: the neck stays behind and under the eye, and
  -- the soles are not lifted
  pw2.eyeDrop = 0.25
  cn.worldPos = v3(0, EYE_H - 0.25, 0)
  head = v3(0, 0.55 - 0.17, 0.22)
  h = frame(0)
  check(h.z <= -0.059, string.format("stance crouch: neck %.3f m ahead of the eye (clips)", h.z))
  check(h.y <= -0.14 + 1e-6, string.format("stance crouch: neck %.3f m under the eye (clips)", h.y))
  -- a bank sideways (a turn at a sprint): the neck back under the eye
  pw2.eyeDrop = 0
  cn.worldPos = eye
  head = v3(0.09, 0.55, 0.04)
  h = frame(0)
  check(math.abs(h.x) < 1e-6, string.format("stance bank: neck %.3f m to the side", h.x))
  -- a jump: the eye's ease lags the rise by 9 cm (the capsule is higher than
  -- the eye says): the body comes down to the eye, as far as its cap
  head = v3(0, 0.55, 0.04)
  cn.worldPos = v3(0, EYE_H - 0.09, 0)
  h = frame(0)
  check(h.y <= -0.14 + 1e-6, string.format("stance jump: neck %.3f m under the eye (clips)", h.y))
  check(math.abs(model.y + 0.09) < 0.02, string.format("stance jump: body moved %.3f m (want the eye's lag, -0.09)", model.y))
  -- a frame the walker did not rewrite the height: the shift does not build up
  local y1 = model.y
  frame(nil)
  check(math.abs(model.y - y1) < 0.005, string.format("stance: the height built up (%.3f then %.3f)", y1, model.y))
  -- a hard landing's dip (30 cm, past follow_down): the body goes down with
  -- the knees as far as the collar needs, never past neck_max
  cn.worldPos = v3(0, EYE_H - 0.30, 0)
  h = frame(0)
  check(h.y <= -0.14 + 1e-6, string.format("stance land: neck %.3f m under the eye (clips)", h.y))
  check(model.y >= -0.45 - 1e-6 and model.y <= -0.14 + 1e-6, string.format("stance land: body moved %.3f m", model.y))
  -- the steps: the skeleton zigzags 1.5 cm up and down frame to frame under
  -- the model (the walker's hips on its re-sampled ground): the neck under
  -- the eye moves less than a quarter of that
  cn.worldPos = eye
  local ys = {}
  for i = 1, 40 do
    head = v3(0, 0.55 + ((i % 2 == 0) and 0.015 or -0.015), 0.04)
    ys[#ys + 1] = frame(0).y
  end
  local zz = 0
  for i = 30, 39 do zz = math.max(zz, math.abs(ys[i + 1] - ys[i])) end
  check(zz < 0.03 * 0.25, string.format("stance steps: the neck still jumps %.4f m a frame (skeleton 0.030)", zz))
  head = v3(0, 0.55, 0.04)
  -- the holds dip with the body only past the stride's bob: a walk's 4 cm
  -- leaves them alone, a landing's 40 cm crouch brings them down
  for i = 1, 30 do head = v3(0, 0.55 - 0.04 * (i % 2), 0.04); frame(0) end
  check(e2.neckDrop < 0.005, string.format("stance: the holds bob with the stride (neckDrop %.3f)", e2.neckDrop))
  for _ = 1, 30 do head = v3(0, 0.55 - 0.40, 0.04); frame(0) end
  check(e2.neckDrop > 0.2, string.format("stance: the holds stay up in a landing's crouch (neckDrop %.3f)", e2.neckDrop))
  head = v3(0, 0.55, 0.04)
  for _ = 1, 30 do frame(0) end
  -- out of first person: the model goes back where the capsule has it
  cn.worldPos = eye
  frame(0)
  pc2.firstPerson = false
  e2.update(A, 0.016)
  check(math.abs(model.x) < 1e-6 and math.abs(model.z) < 1e-6, "stance: the body left set back after first person")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_fp_hands: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_fp_hands: %d passed", passed))
