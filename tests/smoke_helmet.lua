-- SMOKE: the HELMET that comes off (scripts/suit.lua), against stubs.
--
--   * it comes off only in air a person can breathe: on foot, not under
--     water, on a world with oxygen, thick enough where the crew stands, not
--     too cold or hot — and anywhere else it is refused WITH the reason;
--   * off, the state is saved and the helmet, visor and lamps nodes hide;
--     bare-headed under water the tank drains `breath_hold` times faster;
--   * bare-headed where the air stops being breathable, it goes back on;
--   * the hands-to-the-neck-ring animation flips the helmet at its middle,
--     and a caller passing a node where the options go is not an error.
--
--   luajit solar/tests/smoke_helmet.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- the world: home (breathable, radius 800, air to 300 m), a moon (no air), a
-- frozen world (air with oxygen, −63 °C)
local WORLDS = {
  Home = { atmo = 0.8, atmoHeight = 300, radius = 800, geo = { home = true, type = "verdant" }, bio = { tempK = 290 } },
  Moon = { atmo = 0, radius = 200 },
  Ice = { atmo = 0.7, atmoHeight = 250, radius = 600, geo = { type = "tundra" }, bio = { tempK = 210 } },
  Venus = { atmo = 0.9, atmoHeight = 250, radius = 600, geo = { type = "greenhouse" }, bio = { tempK = 300 } },
}
local BODIES = { Home = { name = "Home", x = 0, y = 0, z = 0, radius = 800 },
                 Moon = { name = "Moon", x = 5000, y = 0, z = 0, radius = 200 },
                 Ice = { name = "Ice", x = 0, y = 9000, z = 0, radius = 600 },
                 Venus = { name = "Venus", x = 0, y = 0, z = 9000, radius = 600 } }
local function dominant(x, y, z)
  for n, b in pairs(BODIES) do
    local dx, dy, dz = x - b.x, y - b.y, z - b.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) < b.radius * 3 then return n end
  end
end

local saved = {}
local walker = { onFoot = true, downed = false, headUnder = false, swimming = false, valid = true }
local climate = { valid = true, worldOf = function(n) return WORLDS[n] end }
local captions = {}
local bc = { valid = true, show = function(t, s) captions[#captions + 1] = t .. ": " .. (s or "") end }
local SCRIPTS = { planet_walker = walker, climate = climate, big_caption = bc }

local function node(name, kids)
  local n = { name = name, valid = true, visible = true }
  n.children = function() return kids or {} end
  return n
end
local visor_n, lamps_n = node("Helmet Visor"), node("Helmet Lamps")
local helmet_n = node("Helmet", { visor_n, lamps_n })
local reaches = 0
local model = node("AstroModel", { helmet_n })
local BONES = { Head = vec3(0, 801.6, 0), Hip = vec3(0, 801.2, 0), ["Upperarm.Left"] = vec3(0.17, 801.5, 0),
                ["Upperarm.Right"] = vec3(-0.17, 801.5, 0), ["Forearm.Left"] = vec3(0.47, 801.5, 0),
                ["Hand.Left"] = vec3(0.72, 801.5, 0) }
model.bonePos = function(_, n) return BONES[n] end
model.animator = function() return { reach = function() reaches = reaches + 1 end } end
local crew = node("Astronaut", { model })
crew.x, crew.y, crew.z = 0, 801, 0

local SE = setmetatable({
  vec3 = vec3,
  findScript = function(k) return SCRIPTS[k] end,
  save = { get = function(k) return saved[k] end, set = function(k, v) saved[k] = v end },
  space = { dominant = dominant, body = function(n) return BODIES[n] end },
  audio = { play = function() end },
  math = math, string = string,
}, { __index = _G })
local sc = assert(loadfile("solar/scripts/suit.lua"))
setfenv(sc, SE)
sc()
SE.params = {}
for k, v in pairs(SE.defaults) do SE.params[k] = v end
SE.start(crew)
SE.update(crew, 1 / 60)

-- here: on foot, home, at the ground
local ok, why = SE.canRemoveHelmet()
check(ok == true and why == nil, "home, on foot, at the ground: the helmet may come off (" .. tostring(why) .. ")")
check(SE.helmetRefusal(false) == nil and SE.helmetRefusal(true) == nil, "helmetRefusal says nil both ways at home")
-- refused, with words
local function refused(setup, undo, what, want)
  setup()
  local a, w = SE.canRemoveHelmet()
  local r = SE.helmetRefusal(false)
  local s_ok, s_why = SE.setHelmet(false, { instant = true })
  check(a == false and type(w) == "string" and #w > 8, what .. ": refused with a reason (" .. tostring(w) .. ")")
  check(r == w and s_ok == false and s_why == w and SE.helmetOn() == true, what .. ": setHelmet refuses the same way")
  if want then check(w:find(want, 1, true) ~= nil, what .. ": the reason says " .. want .. " (" .. tostring(w) .. ")") end
  undo()
end
refused(function() walker.headUnder = true end, function() walker.headUnder = false end, "head under water", "water")
refused(function() walker.onFoot = false end, function() walker.onFoot = true end, "aboard a craft", "on foot")
refused(function() walker.downed = true end, function() walker.downed = false end, "blacked out")
refused(function() crew.x, crew.y = 5000, 201 end, function() crew.x, crew.y = 0, 801 end, "an airless moon", "no air")
refused(function() crew.y = 801 + 230 end, function() crew.y = 801 end, "high in thin air", "thin")
refused(function() crew.x, crew.y = 0, 9601 end, function() crew.x, crew.y = 0, 801 end, "a frozen world", "cold")
refused(function() crew.x, crew.y, crew.z = 0, 0, 9601 end, function() crew.x, crew.y, crew.z = 0, 801, 0 end,
  "a world with no oxygen", "oxygen")

-- off, at once
local s_ok = SE.setHelmet(false, { instant = true, quiet = true })
SE.lateUpdate(crew, 1 / 60)
check(s_ok == true and SE.helmetOn() == false, "off: setHelmet(false) takes it off")
check(saved["crew.helmet"] == 0, "off: the save says so (crew.helmet = 0)")
check(helmet_n.visible == false and visor_n.visible == false and lamps_n.visible == false,
  "off: the helmet, its visor and its lamps are hidden")
check(SE.breathMult() == SE.params.breath_hold and SE.params.breath_hold > 1, "bare-headed under water the tank drains faster")
check(SE.setVisor(false) == false, "no visor to raise with the helmet off")
-- back on where the air ends
crew.x, crew.y = 5000, 201
SE.update(crew, 1 / 60)
check(SE.helmetOn() == true and saved["crew.helmet"] == 1, "bare-headed on an airless moon: the helmet goes back on")
check(#captions == 1 and captions[1]:find("HELMET ON", 1, true) ~= nil, "and a caption says why")
crew.x, crew.y = 0, 801
SE.update(crew, 1 / 60)
check(SE.breathMult() == 1, "helmeted, the tank drains as ever")

-- the animation: a node where the options go is ignored, the helmet flips
-- at the middle, the hands are driven, and nothing else may start meanwhile
local a_ok = SE.setHelmet(false, helmet_n)
check(a_ok == true and SE.busy == true and SE.helmetOn() == true, "animated: under way, the helmet still on at the start")
check(SE.setHelmet(true) == false, "animated: a second change waits for the first")
local T = SE.params.anim_secs
local t = 0
while t < T * 0.45 do SE.lateUpdate(crew, 1 / 30); t = t + 1 / 30 end
check(SE.helmetOn() == true, "animated: still on before the middle")
while t < T * 1.1 do SE.lateUpdate(crew, 1 / 30); t = t + 1 / 30 end
check(SE.helmetOn() == false and SE.busy == false, "animated: off by the end")
check(reaches > 10, "animated: the hands were driven to the neck ring")
-- the visor and the lamps, helmet on
SE.setHelmet(true, { instant = true, quiet = true })
SE.setVisor(false)
SE.lateUpdate(crew, 1 / 60)
check(SE.visorDown() == false and visor_n.visible == false and helmet_n.visible == true, "visor raised: hidden, helmet shown")
SE.setVisor(true)
SE.setLamps(false)
SE.lateUpdate(crew, 1 / 60)
check(lamps_n.visible == false and visor_n.visible == true and saved["crew.lamps"] == 0, "lamps off: their glow hidden, saved")
-- first person: the body hidden, so is the helmet
model.visible = false
SE.lateUpdate(crew, 1 / 60)
check(helmet_n.visible == false, "the body hidden (first person): the helmet with it")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL " .. m) end
  print(string.format("smoke_helmet: %d of %d checks failed", #failures, #failures + passed))
  os.exit(1)
end
print(string.format("smoke_helmet: all %d checks passed", passed))
