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

-- ── underground: drips heard where they land (Ty 2026-11-10) ───────────────
-- A chamber 6 m high on a world racing along its rails (100 m a step): the
-- drops play as 3D sources on the floor under the roof, near the crew, and
-- the ones still sounding move with the planet.
do
  local R = 1000
  local B = { name = "Home", x = 0, y = 0, z = 0, radius = R, mu = 9.0 * R * R, soi = 1e9 }
  local astro = { x = 0, y = R, z = 0, valid = true }
  local plays, moves = {}, {}
  local function handle(rec)
    return { setVolume = function() end, setLowpass = function() end, stop = function() end,
             setPosition = function(_, x, y, z) moves[#moves + 1] = { rec = rec, x = x, y = y, z = z, bx = B.x } end }
  end
  local api = {
    time = 0, vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
    find = function(n) if n == "Astronaut" then return astro end end,
    findScript = function(k)
      if k == "planet_walker" then return { valid = true, onFoot = true } end
      if k == "vfx" then return { valid = true, airAt = function() return 1.0 end } end
    end,
    save = { get = function() return { climMoist = 0.8 } end },
    space = { dominant = function() return "Home" end, body = function() return B end },
    -- the cave: floor at R, roof at R + 6, walls 10 m off every level ray
    terrain = { raycast = function(o, d, far)
      local px, py, pz = o.x - B.x, o.y - B.y, o.z - B.z
      local r = math.sqrt(px * px + py * py + pz * pz)
      local radial = (px * d.x + py * d.y + pz * d.z) / r
      local dist
      if radial > 0.99 then dist = R + 6 - r elseif radial < -0.99 then dist = r - R else dist = 10 end
      if dist <= 0 or dist > far then return nil end
      return { distance = dist, pos = { x = o.x + d.x * dist, y = o.y + d.y * dist, z = o.z + d.z * dist } }
    end },
    audio = { play = function(clip, a, b, c, o)
      local rec = { clip = clip, x = type(a) == "number" and a or nil, y = b, z = c, o = type(a) == "table" and a or o, bx = B.x }
      plays[#plays + 1] = rec
      return handle(rec)
    end },
  }
  local G = load("solar/scripts/underground.lua", api)
  G.params.effects = false
  for step = 1, 1200 do                      -- 60 s at 20 Hz
    api.time = step * 0.05
    B.x = B.x + 100; astro.x = astro.x + 100
    G.update({}, 0.05)
  end
  local drops, onfloor, near, spatial = 0, 0, 0, 0
  for _, p in ipairs(plays) do
    if p.clip:find("cave_drip_") then
      drops = drops + 1
      local rx, ry, rz = p.x - p.bx, p.y - B.y, p.z - B.z
      local r = math.sqrt(rx * rx + ry * ry + rz * rz)
      if math.abs(r - (R + 0.03)) < 0.05 then onfloor = onfloor + 1 end
      local ex, ey, ez = p.x - (p.bx + 0), p.y - (R + 1.6), p.z
      if math.sqrt(ex * ex + ey * ey + ez * ez) < 16.5 then near = near + 1 end
      if p.o and p.o.mode == "Spatial" and p.o.track == "SFX" and (p.o.minDistance or 0) > 0 then spatial = spatial + 1 end
    end
  end
  ok(G.cave, "the test chamber reads as a cave")
  ok(drops >= 6, "a damp cave drips (" .. drops .. " drops in 60 s)")
  ok(drops > 0 and onfloor == drops, "every drop lands on the floor (" .. onfloor .. "/" .. drops .. ")")
  ok(drops > 0 and near == drops, "within reach of the crew (" .. near .. "/" .. drops .. ")")
  ok(drops > 0 and spatial == drops, "as 3D sources with a distance falloff (" .. spatial .. "/" .. drops .. ")")
  local rode = #moves > 0
  for _, m in ipairs(moves) do
    if math.abs((m.x - m.bx) - (m.rec.x - m.rec.bx)) > 1e-6 then rode = false end
  end
  ok(rode, "a drop still sounding moves with the planet (" .. #moves .. " moves)")
  -- the creaks and groans (real recordings) come from the rock, as 3D sources
  local cr, crsp, crnear = 0, 0, 0
  for _, p in ipairs(plays) do
    if p.clip:find("cave_creak_") or p.clip:find("cave_groan_") then
      cr = cr + 1
      if p.x and p.o and p.o.mode == "Spatial" and p.o.track == "SFX" and (p.o.minDistance or 0) > 0 then crsp = crsp + 1 end
      if p.x then
        local ex, ey, ez = p.x - p.bx, p.y - (R + 1.6), p.z
        if math.sqrt(ex * ex + ey * ey + ez * ez) < 30 then crnear = crnear + 1 end
      end
    end
  end
  ok(cr >= 1 and G.creakLog.played == cr, "the cave creaks or groans within a minute (" .. cr .. ")")
  ok(cr >= 1 and crsp == cr, "every creak is a 3D source on the rock (" .. crsp .. "/" .. cr .. ")")
  ok(cr >= 1 and crnear == cr, "within reach of the eye (" .. crnear .. "/" .. cr .. ")")
  ok(G.dripRadius(0) >= 1.5 and G.dripRadius(1) <= 11.0, "drip spots 1.5 to 11 m out")
  ok(G.dripPeriod(0.8, 0) > 1.5 and G.dripPeriod(0.35, 1) < 15, "each drips every few seconds")
  -- a dry world: no drips
  local G2 = load("solar/scripts/underground.lua", api)
  api.save = { get = function() return { climMoist = 0.1, kind = "dune" } end }
  local n0 = #plays
  for step = 1, 400 do api.time = 100 + step * 0.05; G2.update({}, 0.05) end
  local dry = 0
  for i = n0 + 1, #plays do if plays[i].clip:find("cave_drip_") then dry = dry + 1 end end
  ok(dry == 0, "a dry cave does not drip (" .. dry .. ")")
  -- an airless cave: no creaks, only groans, flat and muffled (through the boots)
  local G3 = load("solar/scripts/underground.lua", api)
  G3.params.effects = false
  api.findScript = function(k)
    if k == "planet_walker" then return { valid = true, onFoot = true } end
    if k == "vfx" then return { valid = true, airAt = function() return 0.0 end } end
  end
  n0 = #plays
  for step = 1, 1200 do api.time = 200 + step * 0.05; G3.update({}, 0.05) end
  local vg, vbad = 0, 0
  for i = n0 + 1, #plays do
    local p = plays[i]
    if p.clip:find("cave_creak_") then vbad = vbad + 1 end
    if p.clip:find("cave_groan_") then
      vg = vg + 1
      if p.x or not (p.o and p.o.mode == "Flat" and (p.o.lowpass or 0) > 0) then vbad = vbad + 1 end
    end
  end
  ok(vg >= 1 and vbad == 0, "in vacuum only muffled groans, through the boots (" .. vg .. " groans, " .. vbad .. " wrong)")
end
for _, f in ipairs({ "cave_creak_1", "cave_creak_2", "cave_creak_3", "cave_groan_1", "cave_groan_2" }) do
  local h = io.open("solar/audio/ambience/" .. f .. ".ogg", "rb")
  ok(h ~= nil, "missing audio/ambience/" .. f .. ".ogg")
  if h then h:close() end
end
for i = 1, 6 do
  local h = io.open("solar/audio/ambience/cave_drip_" .. i .. ".ogg", "rb")
  ok(h ~= nil, "missing audio/ambience/cave_drip_" .. i .. ".ogg")
  if h then h:close() end
end

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
