-- SMOKE HARNESS: the Repair Kit puts back what came off (vessel_controller
-- reattach, 2026-11-11; Ty: "if a part gets detached but it's still visibly
-- on it, it looks like something I can repair but I just can't").
--
--   * reattachVerdict (pure): a wreck goes back on only for want of a
--     physical reason, each said: the craft gone, a refit under way, docked,
--     its mount gone too, lying too far from its mount (said how far), the
--     craft moving; otherwise it can
--   * the reach and the health a broken part comes back at are what the
--     docs say (3 m, 35 %)
--   * the published names the menu and part_info use exist (lostOfNode,
--     reattachPlan, reattachDist, reattach, lostWrecks, lostRec, junkNote),
--     and lostOfNode on a world with no wrecks answers nothing at once
--
-- The whole job (a rover's torn and broken parts reattached through the
-- menu) is tools/perf/reattachshots.sh.
--
--   luajit solar/tests/smoke_reattach.lua

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
env.log = function() end

for _, k in ipairs({ "lostOfNode", "reattachPlan", "reattachDist", "reattach", "lostWrecks", "lostRec", "junkNote", "reattachVerdict" }) do
  check("publishes " .. k, type(rawget(env, k)) == "function")
end
check("the reach is 3 m and a broken part comes back at 35 %", env.REATTACH_REACH == 3.0 and env.REATTACH_HP == 0.35)

local V = env.reattachVerdict
local base = { mounted = true, dist = 1.2, speed = 0.05 }
local function with(t) local o = {} for k, v in pairs(base) do o[k] = v end for k, v in pairs(t) do o[k] = v end return o end
check("lying by its mount on a still craft: it goes back on", V(base) == nil)
check("the craft gone: said", V(with({ destroyed = true })) == "the craft is gone")
check("a refit under way: said", V(with({ refit = true })):find("already", 1, true) ~= nil)
check("docked: undock first", V(with({ docked = true })):find("undock", 1, true) ~= nil)
check("its mount gone too: put that back first", V(with({ mounted = false })):find("mounted on is gone", 1, true) ~= nil)
local far = V(with({ dist = 6.04 }))
check("too far: how far, and how near it must be", far == "it lies 6.0 m from its mount: bring it back (within 3 m)", far)
check("just inside the reach: it can", V(with({ dist = 2.99 })) == nil)
check("the craft rolling: stop it first", V(with({ speed = 2.0 })):find("moving", 1, true) ~= nil)
check("the order a player meets them: gone before far", V(with({ destroyed = true, dist = 9 })) == "the craft is gone")

-- no wrecks: nothing, at once (the menu asks this at 8 Hz)
local nodeish = { valid = true, id = 42, parent = nil }
check("no wrecks lying about: lostOfNode answers nothing", env.lostOfNode(nodeish) == nil)
check("no wrecks: an empty list", #env.lostWrecks() == 0)

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_reattach: %d passed, %d failed", passes, #failures))
  os.exit(1)
end
print(string.format("smoke_reattach: %d passed", passes))
