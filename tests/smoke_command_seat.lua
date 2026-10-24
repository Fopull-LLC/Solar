-- SMOKE: the COMMAND SEAT's rider (scripts/command_seat.lua) and the crew's
-- on-foot test (vessel_controller.lua crewOnFoot), against stubs.
--
--   * crewed from this seat, the rider is shown (and its model child), sits at
--     the seat's drawn position and is stood along the seat's up — every
--     frame, whatever hid them on the way in;
--   * a seat whose craft is crewed from ANOTHER command part, or not crewed,
--     leaves the astronaut alone;
--   * on foot = aboard no craft and not this instant stepping out of one —
--     NOT `astronaut.visible`, which the camera clears in first person (F
--     refused to board from there) and an open seat keeps set.
--
--   luajit solar/tests/smoke_command_seat.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- ── command_seat.lua ───────────────────────────────────────────────────────
local model = { name = "AstroModel", valid = true, visible = false, yaw = 0, pitch = 0, roll = 0 }
local reaches = {}
local anim = { reach = function(_, bone, at) reaches[bone] = at end }
model.animator = function() return anim end
local astro = { name = "Astronaut", valid = true, visible = false, x = 0, y = 0, z = 0 }
astro.children = function() return { model } end
astro.setUp = function(self, u, f) self.up_set, self.fwd_set = u, f end

local vessel_node = { id = 7, valid = true }
local vessel = { crewAboard = true, podSeat = true, podLX = 0.25, podLY = 1.17, podLZ = 0.0 }
vessel.node = vessel_node
vessel_node.getScript = function(_, kind) if kind == "vessel_controller" then return vessel end end

local seat = { id = 9, valid = true, x = 0.25, y = 1.17, z = 0.0, parent = vessel_node,
               worldPos = vec3(100, 50, -20) }
seat.worldUp = function() return vec3(0, 1, 0) end
seat.worldRight = function() return vec3(1, 0, 0) end
seat.worldForward = function() return vec3(0, 0, -1) end

local SE = setmetatable({ vec3 = vec3, find = function(n) if n == "Astronaut" then return astro end end },
  { __index = _G })
local sc = assert(loadfile("solar/scripts/command_seat.lua"))
setfenv(sc, SE)
sc()
SE.params = {}
for k, v in pairs(SE.defaults) do SE.params[k] = v end

SE.lateUpdate(seat, 1 / 60)
check(SE.riding == true, "crewed from this seat: the script seats the rider")
check(astro.visible == true, "the rider is shown, whatever hid them on the way in")
check(model.visible == true, "and the model child (visibility isn't inherited)")
local sf = SE.params.sit_forward
check(math.abs(astro.x - (100 + sf)) < 1e-9 and astro.y == 50 and astro.z == -20,
  "the rider sits where the seat is drawn, forward along its +X by the backpack")
check(astro.up_set and astro.up_set.y == 1 and astro.fwd_set and astro.fwd_set.x == 1,
  "upright along the seat's up, facing its +X")
check(reaches["Foot.Left"] and reaches["Hand.Right"], "feet and hands go to the footrest and the stick")

-- a frame later something hides them again (a pod transfer, the launch handoff)
astro.visible, model.visible = false, false
seat.worldPos = vec3(101, 50, -20)
SE.lateUpdate(seat, 1 / 60)
check(astro.visible == true and model.visible == true, "re-shown every frame while seated")
check(math.abs(astro.x - (101 + sf)) < 1e-9, "and follows the seat every frame")

-- crewed from another command part (a pod elsewhere on the craft)
vessel.podLX = -0.4
astro.visible = false
SE.lateUpdate(seat, 1 / 60)
check(SE.riding == false, "a seat the crew isn't in poses nobody")
check(astro.visible == false, "and leaves a pod's crew hidden")
vessel.podLX = 0.25

-- not crewed (stood up)
vessel.crewAboard = false
astro.x = 5
SE.lateUpdate(seat, 1 / 60)
check(SE.riding == false and astro.x == 5, "an empty seat leaves the astronaut where they are")

-- ── vessel_controller.lua crewOnFoot ───────────────────────────────────────
local crafts = {}
local VE = setmetatable({}, { __index = function(_, k)
  if k == "find" then return function(n) if n == "Astronaut" then return astro end end end
  if k == "findScripts" then return function() return crafts end end
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local vc = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(vc, VE)
vc()
check(type(VE.crewOnFoot) == "function", "vessel_controller publishes crewOnFoot")
VE.time = 50.0
astro.visible = false -- the camera hid the body: first person
crafts = { { crewAboard = false, leftAt = -100 }, { crewAboard = false } }
check(VE.crewOnFoot() == true, "first person (body hidden) is still on foot: F boards")
crafts[2].crewAboard = true
astro.visible = true -- an open seat keeps its rider in view
check(VE.crewOnFoot() == false, "a rider in an open seat is not on foot: no 'F — board' from the next craft")
crafts[2].crewAboard = false
crafts[1].leftAt = 49.9
crafts[1].node = { id = 3 }
check(VE.crewOnFoot(4) == false, "the F that stood you up doesn't seat you in the craft next door")
check(VE.crewOnFoot(3) == true, "...but you may climb straight back into the one you left")
crafts[1].leftAt = 49.0
check(VE.crewOnFoot() == true, "a moment later, on foot")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_command_seat: all %d checks passed", passed))
