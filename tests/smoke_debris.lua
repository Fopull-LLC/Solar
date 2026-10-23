-- SMOKE HARNESS: debris that hangs in the air (vessel_controller.lua DEBRIS).
--
-- "debris often left floating" (playtest 2026-10-23). Every piece a craft
-- sheds is watched by the craft it came from: kept out of the distant-craft
-- LOD until it rests on the ground, and let go (unanchored, woken, nudged
-- down) if it is ever still in the air.
--
--   luajit solar/tests/smoke_debris.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

local stub = setmetatable({}, { __index = function() return function() end end,
                                __call = function() return nil end })
local ground = 0.5   -- what a ray down from a piece finds
local field = 0.5    -- the terrain field's distance from its centre (terrain.query)
local teleports = 0
local infos, kept, anchored, kicks = {}, {}, {}, {}
local assembly = {
  info = function(n) return infos[n] end,
  keepLive = function(n, on) kept[n] = on end,
  setAnchored = function(n, on) anchored[n] = on; if infos[n] then infos[n].anchored = on end end,
  teleport = function(n, p) teleports = teleports + 1; n.tp = p end,
  impulseAt = function(n, imp) kicks[n] = (kicks[n] or 0) + 1; n.lastImp = imp end,
}
local space = { dominant = function() return "P" end, body = function() return { x = 0, y = 0, z = 0 } end }
local env = setmetatable({ assembly = assembly, space = space,
  raycast = function() return { distance = ground } end,
  terrain = { query = function() return field end },
  log = function() end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end }, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, env)
local ok, err = pcall(chunk)
check("vessel_controller loads in a stub world", ok, tostring(err))
check("the debris watch is published", type(env.debrisTrack) == "function" and type(env.debrisTick) == "function")

local function piece(name, y, vy, grounded)
  local n = { name = name, valid = true, asleep = true }
  infos[n] = { com = { x = 0, y = y, z = 0 }, origin = { x = 0, y = y, z = 0 }, vel = { x = 0, y = vy, z = 0 },
               mass = 0.4, grounded = grounded, anchored = false }
  return n
end
local falling = piece("falling", 120, -8, false)
local hanging = piece("hanging", 130, 0, false)
local resting = piece("resting", 100, 0, true)
for _, n in ipairs({ falling, hanging, resting }) do env.debrisTrack(n) end
check("a fresh piece is kept out of the distant-craft LOD", kept[falling] == true and kept[hanging] == true)
infos[hanging].anchored = true        -- the LOD froze it on an anchor
for _ = 1, 120 do env.debrisTick(1 / 60) end   -- 2 s
check("a falling piece is left alone", not kicks[falling])
check("a piece hanging still in the air is let go: unanchored, woken, pushed down",
  kicks[hanging] == 1 and anchored[hanging] == false and hanging.asleep == false and hanging.lastImp.y < 0,
  tostring(kicks[hanging]))
for _ = 1, 120 do env.debrisTick(1 / 60) end   -- 4 s: resting > 3 s
check("a piece at rest on the ground goes back to the LOD", kept[resting] == false)
-- the ground under a settled piece drops away (dug out, or its collider
-- rebuilt at another detail): it is woken
resting.asleep = true
ground = 3.5
for _ = 1, 150 do env.debrisTick(1 / 60) end
check("a settled piece whose ground has dropped away is woken", resting.asleep == false)
ground = 0.5
-- …or it went through a coarse collider into the ground: it is put back on it
for _ = 1, 400 do env.debrisTick(1 / 60) end   -- settle again
field = -6.5
local tp0 = teleports
for _ = 1, 150 do env.debrisTick(1 / 60) end
check("a settled piece found inside the ground is put back on top", teleports == tp0 + 1 and resting.tp.y > 100,
  string.format("%d teleports", teleports - tp0))
field = 0.5
local n_left = #env.DEBRIS
for _ = 1, 600 do env.debrisTick(1 / 60) end
check("a piece that will not come down is given up on after a few pushes (no endless nudging)",
  (kicks[hanging] or 0) <= 4 and (function() for _, d in ipairs(env.DEBRIS) do if d.node == hanging then return false end end return true end)(),
  string.format("%d kicks, %d left of %d", kicks[hanging] or 0, #env.DEBRIS, n_left))
hanging.valid = false
resting.valid = false
infos[falling] = nil
for _ = 1, 2 do env.debrisTick(1 / 60) end
check("gone pieces drop off the list", #env.DEBRIS == 0, tostring(#env.DEBRIS))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("%d passed, %d failed", passes, #failures))
  os.exit(1)
end
print(string.format("smoke_debris: %d passed", passes))
