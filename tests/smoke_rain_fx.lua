-- SMOKE HARNESS: rain_fx.lua — rain on the ground (the screen pass's driver).
--
--   * no rain and nothing wet: every pass off (it costs nothing)
--   * rain: the level's pass on (Low the wet look only, Medium rainFx, High and
--     Ultra rainFxHigh), every uniform it reads sent, and only one pass on
--   * the ground wets through over tens of seconds of heavy rain, the puddles
--     fill slower, and both dry over minutes once it stops
--   * the drop field is anchored in the PLANET's frame: the planet moving and
--     turning under the camera carries the anchor with it, and the anchor is
--     re-picked only when the camera has gone far
--   * off on the map, in the cockpit, in the VAB, indoors, high up, under
--     snow, and on the player's switch
--
--   luajit solar/tests/smoke_rain_fx.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local T = 0.0
local R = 900
-- the planet: a node that can move and turn (about +y) under the camera
local planet = { valid = true, x = 0, y = 0, z = 0, ang = 0 }
function planet:toWorld(v)
  local c, s = math.cos(self.ang), math.sin(self.ang)
  return { x = self.x + c * v.x + s * v.z, y = self.y + v.y, z = self.z - s * v.x + c * v.z }
end
local cam = { valid = true, x = 0, y = R + 2, z = 0 }
local wx_cur = nil
local weather = { valid = true, current = function() return wx_cur end }
local graphics = { valid = true, lv = "Medium", level = function(self) return graphics.lv end }
graphics.level = function() return graphics.lv end
local pcam = { valid = true, cockpit = false }
local omap = { valid = true, map_view = false }
local gm = { valid = true, inputOwner = nil }
local light = { fog = true, fogVolumetric = false, fogStart = 10, fogEnd = 400, fogColorR = 0.4, fogColorG = 0.45, fogColorB = 0.5 }
local API = {
  find = function(n)
    if n == "Camera 1" then return cam end
    if n == "Home" then return planet end
    if n == "Lighting" then return { getcomponent = function() return light end } end
  end,
  findScript = function(k)
    return ({ weather = weather, graphics = graphics, planet_camera = pcam, orbit_map = omap, game_manager = gm })[k]
  end,
  space = {
    dominant = function() return "Home" end,
    body = function() return { name = "Home", x = planet.x, y = planet.y, z = planet.z, radius = R } end,
  },
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/rain_fx.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end

local shown, uni = {}, {}
local node = {
  setScreenShader = function(_, n, on) shown[n] = on end,
  setShaderParam = function(_, k, ...) uni[k] = { ... } end,
}
local DT = 1 / 60
local function frame(n)
  for _ = 1, n or 1 do T = T + DT; env.lateUpdate(node, DT) end
end
local function on_passes()
  local l = {}
  for k, v in pairs(shown) do if v then l[#l + 1] = k end end
  table.sort(l)
  return table.concat(l, ",")
end
local function rain(p, extra)
  wx_cur = { kind = "wet", precip = p, snow = 0, hail = 0, body = "Home", sheltered = false }
  for k, v in pairs(extra or {}) do wx_cur[k] = v end
end

-- 1. dry
rain(0)
frame(10)
ok(on_passes() == "", "no rain, nothing wet: every pass off (" .. on_passes() .. ")")

-- 2. rain starts: the ground wets through, slower than at once
rain(1)
frame(60)
ok(on_passes() == "rainFx", "rain at Medium: rainFx alone (" .. on_passes() .. ")")
ok(env.state.wet > 0 and env.state.wet < 0.2, string.format("...and a second of rain only begins to wet the ground (%.3f)", env.state.wet))
frame(60 * 40)
ok(env.state.wet > 0.99, string.format("40 s of heavy rain wets it through (%.3f)", env.state.wet))
ok(env.state.puddles > 0.1 and env.state.puddles < env.state.wet, string.format("...the puddles fill slower (%.3f)", env.state.puddles))
for _, u in ipairs({ "anchor", "axisE", "axisN", "axisU", "planetX", "planetY", "planetZ", "anchorLocal", "rain", "sky", "drop", "fog", "grid0", "grid1" }) do
  ok(uni["rainFx." .. u] ~= nil, "rainFx." .. u .. " is sent")
end
ok(uni["rainFx.rain"][1] > 0.9 and uni["rainFx.rain"][2] > 0.99, "the rate and the wetness reach the pass")
ok(uni["rainFx.grid0"][1] == env.GRIDS.rainFx[1][1], "the drop grids are the script's data (GRIDS)")

-- 3. levels
graphics.lv = "High"; frame(2)
ok(on_passes() == "rainFxHigh", "High: rainFxHigh alone (" .. on_passes() .. ")")
graphics.lv = "Ultra"; frame(2)
ok(on_passes() == "rainFxHigh", "Ultra: rainFxHigh")
graphics.lv = "Low"; frame(2)
ok(on_passes() == "rainWet", "Low: the wet look only (" .. on_passes() .. ")")
graphics.lv = "Medium"; frame(2)

-- 4. the anchor rides the planet
local a0 = uni["rainFx.anchor"]
local l0 = uni["rainFx.anchorLocal"]
planet.x, planet.z = planet.x + 6, planet.z - 3       -- a tick of the orbit
cam.x, cam.z = cam.x + 6, cam.z - 3                   -- the camera rides along
frame(1)
local a1 = uni["rainFx.anchor"]
ok(math.abs(a1[1] - a0[1] - 6) < 1e-6 and math.abs(a1[3] - a0[3] + 3) < 1e-6, "the planet moves 6 m: the anchor moves with it, exactly")
ok(uni["rainFx.anchorLocal"][1] == l0[1], "...and keeps its place on the planet")
planet.ang = 0.01; frame(1)
local px = uni["rainFx.planetX"]
ok(math.abs(px[1] - math.cos(0.01)) < 1e-9 and math.abs(px[3] + math.sin(0.01)) < 1e-9, "the planet turns: its axes go to the pass")
planet.ang = 0
cam.x = cam.x + 30; frame(1)
ok(uni["rainFx.anchorLocal"][1] == l0[1], "a 30 m walk keeps the anchor")
cam.x = cam.x + 200; frame(1)
ok(uni["rainFx.anchorLocal"][1] ~= l0[1], "a 230 m walk re-picks it")
local al = uni["rainFx.anchorLocal"]
ok(math.abs(math.sqrt(al[1] ^ 2 + al[2] ^ 2 + al[3] ^ 2) - R) < 1e-6, "...on the ground sphere under the camera")

-- 5. where it is off
local function off_when(label, set, unset)
  set(); frame(2)
  ok(on_passes() == "", label .. ": off (" .. on_passes() .. ")")
  unset(); frame(2)
  ok(on_passes() == "rainFx", label .. ": back on after")
end
off_when("the map", function() omap.map_view = true end, function() omap.map_view = false end)
off_when("the cockpit", function() pcam.cockpit = true end, function() pcam.cockpit = false end)
off_when("the VAB", function() gm.inputOwner = "builder" end, function() gm.inputOwner = nil end)
off_when("indoors", function() wx_cur.sheltered = true end, function() wx_cur.sheltered = false end)
off_when("500 m up", function() cam.y = cam.y + 500 end, function() cam.y = cam.y - 500 end)
off_when("the switch", function() env.setOn(false) end, function() env.setOn(true) end)

-- 6. snow is not rain; then the rain stops and the ground dries over minutes
rain(1, { snow = 1 }); frame(2)
ok(env.state.rate == 0, "snow lands no drops")
rain(0)
frame(60 * 30)
ok(env.state.wet > 0.8 and on_passes() == "rainFx", string.format("30 s after the rain the ground is still wet (%.2f), still drawn", env.state.wet))
frame(60 * 300)
ok(env.state.wet == 0 and env.state.puddles == 0, "five minutes on it has dried")
ok(on_passes() == "", "...and the pass is off again")

-- 7. probes
env.setWet(1, 0.5); frame(1)
ok(env.state.wet == 1 and env.state.puddles == 0.5 and on_passes() == "rainFx", "setWet holds a wetness (and draws it)")
env.setWet(nil)

if #failures > 0 then
  print("RAIN_FX SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("RAIN_FX SMOKE OK — %d checks passed", checks))
