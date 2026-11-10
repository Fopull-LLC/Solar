-- SMOKE HARNESS: the gritty-realism pass (2026-11-10).
--
--   * underground.lua: the enclosure from the terrain rays (a chamber reads
--     fully, an overhang a little, open ground not at all), the cave flag's
--     hysteresis, the ambient scale; the ambient it writes is a share of
--     what the weather wrote, and handed back whole on the surface
--   * atmosphere.lua: an air's character from its gases (methane smogs orange,
--     sulfur yellows, a CO2 desert takes its ground's dust, ammonia greens
--     its night), Earth-like air and a world with no air record unchanged;
--     the night haze takes the air's own night colour
--   * weather.lua: fog pools in the low ground on a calm, damp night as well
--     as at dawn; never on a dry, windy night; never at noon
--   * the new effects and sounds exist on disk
--
--   luajit solar/tests/smoke_grit.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function load(path, api)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return api.time or 0 end
    return api[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end

-- ── underground ────────────────────────────────────────────────────────────
local light = { ambientR = 0.012, ambientG = 0.012, ambientB = 0.018 }
local UAPI = { time = 0, find = function(n) if n == "Lighting" then return { getcomponent = function() return light end } end end,
               findScript = function() return nil end, space = { dominant = function() return nil end } }
local U = load("solar/scripts/underground.lua", UAPI)
local full = U.enclosure(5, 5, 6, 6)
local overhang = U.enclosure(2, 5, 1, 6)
local open = U.enclosure(0, 5, 0, 6)
ok(full > 0.95, "a chamber (every ray meets rock) is fully enclosed: " .. full)
ok(overhang < 0.3 and overhang >= 0, "an overhang reads a little at most: " .. overhang)
ok(open == 0, "open ground is not enclosed")
ok(U.caveFlag(false, 0.65) and not U.caveFlag(false, 0.5), "the cave flag turns on past 0.6")
ok(U.caveFlag(true, 0.5) and not U.caveFlag(true, 0.35), "and off under 0.4 (hysteresis)")
ok(math.abs(U.ambientScale(1, 0.07) - 0.07) < 1e-9 and U.ambientScale(0, 0.07) == 1, "ambient: the floor in a cave, all of it outside")
-- the ambient write: a share of the weather's, and the weather's own writes stay the base
U.enclosed = 1.0
U.lateUpdate({}, 1 / 60)
ok(math.abs(light.ambientR - 0.012 * 0.07) < 1e-9, "a cave keeps 7 % of the ambient: " .. light.ambientR)
U.lateUpdate({}, 1 / 60)
ok(math.abs(light.ambientR - 0.012 * 0.07) < 1e-9, "and does not compound it frame on frame")
light.ambientR, light.ambientG, light.ambientB = 0.05, 0.05, 0.06   -- the weather writes a brighter sky
U.lateUpdate({}, 1 / 60)
ok(math.abs(light.ambientR - 0.05 * 0.07) < 1e-9, "a new write from the weather is the new base")
U.enclosed = 0
U.lateUpdate({}, 1 / 60)
ok(math.abs(light.ambientR - 0.05) < 1e-9, "out of the cave the ambient is handed back whole")

-- ── atmosphere: the air's character ────────────────────────────────────────
local A = load("solar/scripts/atmosphere.lua", { time = 0, find = function() return nil end, findScript = function() return nil end,
  save = { get = function() return nil end }, space = { bodies = function() return {} end } })
ok(A.airCharacter(nil) == nil and A.airCharacter({ atmo = 0.7 }) == nil, "no air record: the old look")
ok(A.airCharacter({ air = { gases = { N2 = 0.78, O2 = 0.21 } } }) == nil, "an Earth-like air keeps its look")
local titan = A.airCharacter({ air = { gases = { N2 = 0.947, CH4 = 0.049 } } })
ok(titan and titan.tint[1] > titan.tint[3] * 2 and titan.haze > 1.8, "methane: a thick orange-brown smog")
local sulf = A.airCharacter({ air = { gases = { SO2 = 0.62, CO2 = 0.33, N2 = 0.05 } } })
ok(sulf and sulf.tint[2] > sulf.tint[3] * 1.5, "sulfur: a yellow murk")
local mars = A.airCharacter({ air = { gases = { CO2 = 0.95, N2 = 0.03 } }, ground = { 0.7, 0.35, 0.2 } })
ok(mars and mars.tint[1] > mars.tint[2] and mars.tint[2] > mars.tint[3], "a CO2 desert: its ground's dust")
local nh3 = A.airCharacter({ air = { gases = { N2 = 0.58, CO2 = 0.31, NH3 = 0.0002, O2 = 0.03 } } })
ok(nh3 and nh3.night[2] > nh3.night[1], "ammonia: a green night")
local nr, ng, nb = A.horizonColor(0.4, 0.6, 0.9, -0.8, titan.night)
local br, bg, bb = A.horizonColor(0.4, 0.6, 0.9, -0.8)
ok(nr > br and nb < bb, "the night haze takes the air's own night colour")

-- ── weather: night fog ─────────────────────────────────────────────────────
local W = load("solar/scripts/weather.lua", { time = 0, find = function() return nil end, findScript = function() return nil end,
  save = { get = function() return nil end, set = function() end }, space = { time = function() return 0 end } })
local p = { airless = false, temp = 0.5, moist = 0.7 }
local calm = { kind = "wet", wind = 1.0, precip = 0, cover = 0.3, state = "clear" }
local best_night, best_noon = 0, 0
for seed = 1, 40 do
  best_night = math.max(best_night, W.mistOf(calm, p, -0.4, 0.7, seed, 0, 360))
  best_noon = math.max(best_noon, W.mistOf(calm, p, 0.9, 0.7, seed, 0, 360))
end
ok(best_night > 0.5, "a calm, damp night pools fog: " .. best_night)
ok(best_noon == 0, "never at noon")
local windy = { kind = "wet", wind = 12.0, precip = 0, cover = 0.3, state = "clear" }
ok(W.mistOf(windy, p, -0.4, 0.7, 3, 0, 360) == 0, "never on a windy night")
ok(W.mistOf(calm, { airless = false, temp = 0.5, moist = 0.02 }, -0.4, 0.02, 3, 0, 360) < 0.05, "barely on a dry one")

-- ── the files ──────────────────────────────────────────────────────────────
for _, f in ipairs({ "vfx/MiningBeam.vfx.ron", "vfx/MiningImpact.vfx.ron", "vfx/LaserChips.vfx.ron", "vfx/LaserChipsVac.vfx.ron",
                     "vfx/DigSmoke.vfx.ron", "vfx/CutGlow.vfx.ron", "vfx/LaserMuzzle.vfx.ron", "vfx/CaveMotes.vfx.ron",
                     "vfx/CaveMist.vfx.ron", "vfx/CaveDrip.vfx.ron", "prefabs/FxLaserMuzzle.prefab.ron" }) do
  local h = io.open("solar/" .. f, "r")
  ok(h ~= nil, "missing " .. f)
  if h then h:close() end
end
local beam = io.open("solar/vfx/MiningBeam.vfx.ron"):read("*a")
ok(not beam:find("star.png") and not beam:find("Muzzle"), "the dig beam has no starburst at the barrel")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_grit: %d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_grit: all %d checks passed", checks))
