-- SMOKE: the crew's size agrees everywhere (playtest 2026-11-09: "makes my
-- character feel extremely tiny ... can maybe make the humans slightly
-- smaller ... always just barely able to fit through doorways").
--
-- HUMAN SCALE is the AstroModel node's scale. The suit rig is built 1:1 (soles
-- at 0, the helmet's top at RIG_HELMET_TOP); the node shrinks it to the crew's
-- real suited height. It must be the same on the Astronaut (scenes/system.ron)
-- and on every prefab that wears the suit (CrewBody, CrewDoll, Remains), the
-- capsule must hold the suited body and pass a kit door (2.05 m clear) with
-- room over the helmet, the kinematic scripts' half heights must be the
-- capsule's, and the first-person eye must sit at the model's eyes.
--
--   luajit solar/tests/smoke_human_scale.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function read(p) local f = assert(io.open("solar/" .. p), p); local s = f:read("*a"); f:close(); return s end

local RIG_HELMET_TOP = 1.918   -- models/astronaut/helmet_male.glb's top over the soles, rig units
local RIG_EYE = 1.76           -- the eyes over the soles, rig units (Head bone + the face mesh)
local DOOR = 2.05              -- the kit's Door Wall clear height (parts_kit.lua)

-- the AstroModel-like node's scale after `name: "<name>"`
local function scale_after(s, name)
  local i = s:find('name: "' .. name .. '"', 1, true)
  if not i then return nil end
  local x = s:match("scale: %(([%d%.]+),", i)
  return tonumber(x)
end
local function capsule_of(s, after)
  local i = s:find('name: "' .. after .. '"', 1, true)
  if not i then return nil end
  local j = s:find("capsule: true", i, true)
  if not j then return nil end
  return tonumber(s:match("radius: ([%d%.]+)", j)), tonumber(s:match("height: ([%d%.]+)", j))
end

local sys = read("scenes/system.ron")
local S = scale_after(sys, "AstroModel")
check(S ~= nil, "system.ron: no AstroModel scale")
S = S or 1
for _, p in ipairs({ { "prefabs/CrewBody.prefab.ron", "AstroModel" }, { "prefabs/CrewDoll.prefab.ron", "AstroModel" },
                     { "prefabs/Remains.prefab.ron", "Remains Suit" } }) do
  local v = scale_after(read(p[1]), p[2])
  check(v ~= nil and math.abs(v - S) < 1e-6, string.format("%s: %s scale %s, the Astronaut's is %.3f", p[1], p[2], tostring(v), S))
end

local r, h = capsule_of(sys, "Astronaut")
check(r and h, "system.ron: no Astronaut capsule")
r, h = r or 0.33, h or 2.0
local r2, h2 = capsule_of(read("prefabs/CrewBody.prefab.ron"), "CrewBody")
check(r2 == r and h2 == h, string.format("CrewBody capsule r %s h %s, the Astronaut's r %.2f h %.2f", tostring(r2), tostring(h2), r, h))

local suited = RIG_HELMET_TOP * S
check(suited >= 1.75 and suited <= 1.86, string.format("suited height %.3f m: want 1.75-1.86 (a real EVA suit and helmet)", suited))
check(h >= suited + 0.03, string.format("the capsule (%.2f m) must hold the suited body (%.3f m)", h, suited))
check(h <= DOOR - 0.12, string.format("the capsule (%.2f m) must pass a %.2f m door with a kerb's pop to spare", h, DOOR))
check(DOOR - suited >= 0.18, string.format("only %.2f m over the helmet in a door", DOOR - suited))
check(2 * r <= 0.9 - 0.25, string.format("the capsule's %.2f m width in a 0.9 m door", 2 * r))

-- the kinematic bodies' half heights are the capsule's
for _, p in ipairs({ "scripts/crew_body.lua", "scripts/crew_task.lua" }) do
  local v = tonumber(read(p):match("half_h = ([%d%.]+)"))
  check(v and math.abs(v - h / 2) < 1e-6, string.format("%s half_h %s, the capsule's half height %.3f", p, tostring(v), h / 2))
end

-- the first-person eye: the model's eyes over the capsule's centre
local cam = read("scripts/planet_camera.lua")
local eye = tonumber(cam:match("eye_height = ([%d%.]+)"))
local soles = -h / 2 + 0.01
local want = soles + RIG_EYE * S
check(eye and math.abs(eye - want) < 0.04, string.format("planet_camera eye_height %s, the model's eyes are at %.3f", tostring(eye), want))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_human_scale: %d failed, %d passed", #failures, passed))
  os.exit(1)
end
print(string.format("smoke_human_scale: %d checks passed (scale %.2f, suited %.2f m, capsule %.2f x %.2f m, eye %.2f m over the soles)",
  passed, S, suited, 2 * r, h, eye - soles))
