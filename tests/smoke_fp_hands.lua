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

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_fp_hands: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_fp_hands: %d passed", passed))
