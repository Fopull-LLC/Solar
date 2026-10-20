-- SMOKE HARNESS: atmosphere.lua — the climb out of the air is a fade, not a cut.
--
-- The sky itself is the engine's (0.116.1: it thins with the camera's height
-- as optical depth 2·density·(1 − alt/H)², exactly 0 at the top of the
-- shell). What is held here is the HAZE this script lays over it, which has to
-- fade with that sky and never snap:
--
--   * the curve is the engine's: 1 at the ground, exactly 0 at the top of the
--     shell, arriving there flat, no step anywhere
--   * a climb at rocket speed, frame by frame: the fog on a hill, the share of
--     the horizon it takes (fogSky) and the volumetric density never jump
--     between consecutive frames, and the fog is cut only once it was drawing
--     nothing
--   * fog heights follow the planet (fogFollowsBody), and the volumetric layer
--     is a thin haze shell hugging the ground (aerial perspective: thick
--     along the ground, thin straight up)
--   * the way back down is the same curve
--   * an airless world never gets fog
--   * the camera cutting to the map (far out of the air) and back eases
--   * the fog colour is the sky's horizon, dark — and blue — at night
--   * the air's colour given to the engine is the rolled one re-saturated
--     (deeper zenith), hue kept; the weather greys and darkens it, and
--     thickens the haze
--   * planet_camera drives it after placing the camera; its own lateUpdate
--     only stands in when there is no planet_camera
--
--   luajit solar/tests/smoke_atmosphere.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine stand-ins ────────────────────────────────────────────────────────
local T = 0.0
local light = { colorR = 0.72, colorG = 0.82, colorB = 1.0 }
local cam = { valid = true, x = 0, y = 0, z = 0 }
local lightnode = { valid = true, getcomponent = function(_, k) if k == "Light" then return light end end }

-- Two worlds: Ember (air, radius 240, atmosphere 90 m) and Husk (no air),
-- and their star, straight overhead of Ember's +y pole. The eye moves along +y.
local bodies = {
  Sol = { name = "Sol", x = 0, y = 8000, z = 0, radius = 380, mu = 1e9, soi = -1 },
  Ember = { name = "Ember", x = 0, y = 0, z = 0, radius = 240, mu = 1e5, soi = 1500 },
  Husk = { name = "Husk", x = 50000, y = 0, z = 0, radius = 150, mu = 5e4, soi = 1200 },
}
local worlds = {
  ["world.Ember"] = { atmo = 0.74, atmoHeight = 90, atmoR = 0.85, atmoG = 0.6, atmoB = 0.42 },
  ["world.Husk"] = { atmo = 0, atmoHeight = 0 },
}
local function dominant(x, y, z)
  for _, n in ipairs({ "Ember", "Husk" }) do
    local b = bodies[n]
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
    if d < b.soi then return n end
  end
  return "Sol"
end
local graphics = { valid = true, volumetric = false, shafts = false }
local planet_camera = nil
local weather = nil
local celestial = {}
local function body_node(name)
  return { valid = true, setCelestial = function(_, t)
    celestial[name] = celestial[name] or { calls = 0 }
    for k, v in pairs(t) do celestial[name][k] = v end
    celestial[name].calls = celestial[name].calls + 1
  end }
end
local body_nodes = { Ember = body_node("Ember"), Husk = body_node("Husk") }
local API = {
  find = function(name)
    if name == "Lighting" then return lightnode end
    if name == "Camera 1" then return cam end
    return body_nodes[name]
  end,
  findScript = function(kind)
    if kind == "graphics" then return graphics end
    if kind == "planet_camera" then return planet_camera end
    if kind == "weather" then return weather end
  end,
  save = { get = function(k) return worlds[k] end },
  space = {
    dominant = dominant,
    body = function(n) return bodies[n] end,
    bodies = function() return { bodies.Sol, bodies.Ember, bodies.Husk } end,
  },
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/atmosphere.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end

local DT = 1 / 60
-- No planet_camera in this scene: the script's own lateUpdate drives it.
local function frame()
  T = T + DT
  env.lateUpdate({ x = 0, y = 0, z = 0 }, DT)
end

-- How much the flat fog paints a surface `d` metres away (the engine's ramp).
local function flat_fog_at(d)
  if not light.fog then return 0 end
  return math.max(0, math.min(1, (d - light.fogStart) / (light.fogEnd - light.fogStart)))
end

-- ── 1. the curve: the engine's (1 − alt/H)² ─────────────────────────────────
local top = 100
ok(env.density(0, top) == 1, "density is 1 at the ground")
ok(env.density(-5, top) == 1, "...and below it (a crater floor)")
ok(env.density(top, top) == 0, "density is exactly 0 at the top of the shell")
ok(env.density(top * 3, top) == 0, "...and above it")
ok(math.abs(env.density(top * 0.5, top) - 0.25) < 1e-12, "it is the engine's curve: a quarter of the air is left halfway up")
local prev, maxstep, mono = 1, 0, true
for i = 1, 2000 do
  local v = env.density(top * i / 2000, top)
  if v > prev then mono = false end
  maxstep = math.max(maxstep, prev - v)
  prev = v
end
ok(mono, "density never rises with altitude")
ok(maxstep < 0.002, "no step in the curve (largest of 2000 samples " .. maxstep .. ")")
local slope_top = env.density(top * 0.98, top) / 0.02
local slope_low = (1 - env.density(top * 0.02, top)) / 0.02
ok(slope_top < 0.03 * slope_low, "...and it arrives at zero flat")
ok(env.airAt(worlds["world.Husk"], 0, 150) == 0, "an airless world has no air even on the ground")
local r0, h0 = env.airAt(worlds["world.Ember"], 0, 240)
ok(r0 == 1 and h0 == 90, "the shell height is the world's published one")

-- ── 2. a climb at rocket speed, frame by frame ──────────────────────────────
local R, H = 240, 90
local function at_alt(a) cam.x, cam.y, cam.z = 0, R + a, 0 end
at_alt(1.5)
for _ = 1, 300 do frame() end
ok(light.fog == true, "standing on the ground of an air world, the fog is on")
ok(light.fogFollowsBody == true, "...measured from the planet, not world y")
ok(light.fogSky > 0.3 and light.fogSky < 0.6, "...and it seats the far ground into the horizon without taking the sky (fogSky " .. tostring(light.fogSky) .. ")")
ok(math.abs(env.rho_now - env.density(1.5, H)) < 1e-3, "the published air is the engine's share overhead")

local function climb(from, to, speed)
  local n = math.ceil(math.abs(to - from) / speed / DT)
  local last, mx = nil, { fog = 0, sky = 0, rho = 0 }
  local off_at = nil
  local was = light.fog
  for i = 1, n do
    at_alt(from + (to - from) * i / n)
    frame()
    local s = { fog = flat_fog_at(300), sky = light.fog and light.fogSky or 0, rho = env.rho_now }
    if last then
      for k in pairs(mx) do mx[k] = math.max(mx[k], math.abs(s[k] - last[k])) end
    end
    if was and not light.fog then off_at = last end
    was = light.fog
    last = s
  end
  return mx, off_at
end

-- A brisk climb: 60 m/s, so the whole atmosphere goes by in a second and a half.
-- The haze is sized to the world (a 240 m world's horizon is ~50 m from a
-- third-person eye), so a hill 300 m off starts most of the way hazed and
-- clears over those ninety frames: ~0.011 a frame on average. A step is a
-- frame that moves several times that.
local mx, off = climb(1.5, 3 * H, 60)
ok(mx.fog < 0.02, string.format("climbing, the fog on a hill 300 m away never jumps (max %.4f)", mx.fog))
ok(mx.sky < 0.02, string.format("climbing, the fog's share of the horizon never jumps (max %.4f)", mx.sky))
ok(mx.rho < 0.03, string.format("climbing, the air never jumps (max %.4f)", mx.rho))
ok(off and off.fog < 1e-3 and off.sky < 1e-3, "the fog is cut only once it was drawing nothing, on the hills and in the sky")
for _ = 1, 600 do frame() end
ok(not light.fog and light.fogSky == 0, "above the air: no fog — the engine's sky is all there is")
ok(env.rho_now == 0 and env.fog_now == 0, "...and the published air reads exactly zero")

-- The volumetric path (High/Ultra): a shell as tall as the air, density
-- falling with it.
graphics.volumetric = true
at_alt(1.5)
for _ = 1, 600 do frame() end
local d_ground = light.fogDensity
ok(light.fogVolumetric and light.fogFollowsBody, "on High the volumetric fog is a shell round the planet")
-- A thin shell hugging the ground, not the whole air: a sky ray straight up
-- crosses little of it and one along the ground a lot (aerial perspective),
-- and the zenith keeps the engine's sky.
local vtop = light.fogHeight + light.fogFalloff
ok(vtop > 0.1 * H and vtop < 0.4 * H, "...a haze layer hugging the ground (top " .. vtop .. " m of " .. H .. ")")
at_alt(H * 0.9)
for _ = 1, 600 do frame() end
ok(light.fogDensity < 0.02 * d_ground, "near the top of the air the volumetric density is nearly gone")
local tau = light.fogDensity * light.fogEnd
ok(tau < 5e-3, "...and the optical depth it marches to the sky with it (" .. tau .. ")")
graphics.volumetric = false

-- ── 3. back down ────────────────────────────────────────────────────────────
at_alt(3 * H)
for _ = 1, 120 do frame() end
local mxd = climb(3 * H, 1.5, 60)
ok(mxd.fog < 0.02 and mxd.sky < 0.02, string.format("descending, no jump (fog %.4f, horizon %.4f)", mxd.fog, mxd.sky))
ok(light.fog, "back on the ground the fog is back")

-- ── 4. the map: the camera cuts far out, then back ──────────────────────────
for _ = 1, 300 do frame() end
local before = env.rho_now
cam.x, cam.y, cam.z = 0, 5000, 0           -- the map, out in the star's space
frame()
ok(before - env.rho_now < 0.1 * before, "cutting to the map, the haze eases out rather than cutting")
for _ = 1, 600 do frame() end
ok(not light.fog, "...and is gone once the map has been open a moment")
at_alt(1.5)
frame()
ok(env.rho_now < 0.1 * before, "closing the map, the haze eases back in")
for _ = 1, 600 do frame() end
ok(math.abs(env.rho_now - before) < 0.01, "...to where it was")

-- ── 5. the colour: the sky's horizon, by day and by night ───────────────────
local dr = light.fogColorR
ok(dr > 0.8, "by day the fog is the bright horizon colour (" .. dr .. ")")
bodies.Sol.y = -8000                       -- the star under the planet: night
for _ = 1, 600 do frame() end
ok(light.fogColorR < 0.1, "at night the fog is dark (" .. light.fogColorR .. ")")
bodies.Sol.y = 8000

-- ── 6. an airless world ─────────────────────────────────────────────────────
cam.x, cam.y, cam.z = 50000, 152, 0
for _ = 1, 900 do frame() end
ok(not light.fog and env.fog_now == 0, "on an airless world: no fog, ever")
cam.y = 600
for _ = 1, 300 do frame() end
ok(not light.fog, "...and none climbing away from it")

-- ── 7. who drives it ────────────────────────────────────────────────────────
-- With a planet_camera in the scene, the script's own lateUpdate stands down
-- and the camera's call is what follows the eye — in the same frame.
planet_camera = { valid = true }
at_alt(1.5)
local r_before = env.rho_now
for _ = 1, 120 do T = T + DT; env.lateUpdate({}, DT) end
ok(env.rho_now == r_before, "with a planet_camera, lateUpdate alone does nothing")
for _ = 1, 600 do T = T + DT; env.lateUpdate({}, DT); env.follow(DT) end
ok(env.rho_now > 0.9, "...and planet_camera's follow() drives it")
local once = env.rho_now
cam.y = R + 3 * H
env.follow(DT)                             -- same frame: a second call is a no-op
ok(env.rho_now == once, "follow() runs once a frame however many times it is called")

-- ── 8. the air's colour, and the weather's hand on it ───────────────────────
local r, g, b, d = env.skyAir(0.85, 0.6, 0.42, 0.74)
ok(r > g and g > b, "the re-saturated air keeps its hue order (" .. r .. ", " .. g .. ", " .. b .. ")")
ok((r - b) / r > (0.85 - 0.42) / 0.85, "...and is more saturated than the rolled pastel (a deeper zenith)")
ok(d < 0.74 and d > 0.5, "...with a little less air overhead (" .. d .. ")")
local gr, gg, gb = env.skyAir(0.85, 0.6, 0.42, 0.74, nil, nil, nil, 1, 0)
ok(math.abs(gr - gg) < 1e-9 and math.abs(gg - gb) < 1e-9, "a storm's grey takes the colour out")
local dr = env.skyAir(0.85, 0.6, 0.42, 0.74, nil, nil, nil, 0, 1)
ok(dr < r * 0.8, "...and its gloom some of the light (the rest is the exposure's)")
local nr, ng, nb = env.horizonColor(0.85, 0.6, 0.42, -0.8)
ok(nb > nr and nb < 0.15, string.format("the night haze is dim and blue, not grey (%.3f %.3f %.3f)", nr, ng, nb))
local tr, tg, tb = env.horizonColor(0.4, 0.6, 0.9, 0.0)
local mr, mg, mb = env.horizonColor(0.4, 0.6, 0.9, 0.8)
ok(tr / tb > mr / mb, "at sunset the haze warms toward the low sun")
ok(celestial.Ember and celestial.Ember.atmoColor and celestial.Ember.atmoDensity,
  "the engine is given the re-saturated air for every world with some")
ok(not celestial.Husk, "...and nothing for the airless one")
local calls = celestial.Ember.calls
for _ = 1, 120 do frame() end
ok(celestial.Ember.calls == calls, "...once, not every frame")
-- A storm over Ember (planet_camera is in the scene now: it drives follow()).
local function pcframe() T = T + DT; env.follow(DT) end
cam.x, cam.y, cam.z = 0, R + 1.5, 0
for _ = 1, 600 do pcframe() end
local clear_end, clear_spread = light.fogEnd, light.fogColorR - light.fogColorB
weather = { valid = true, sky = { body = "Ember", cover = 1, dim = 0.8, grey = 0.8, haze = 4, flash = 0 } }
for _ = 1, 600 do pcframe() end
ok(light.fogEnd < clear_end * 0.5, "under a storm the haze closes in (fog end " .. light.fogEnd .. " from " .. clear_end .. ")")
ok(light.fogColorR - light.fogColorB < 0.4 * clear_spread,
  "...and goes the grey of the cloud deck rather than the air's colour")
ok(celestial.Ember.atmoColor[1] < r, "...and the sky's own colour greys and darkens with it")
weather.sky.flash = 1
pcframe()
ok(light.fogColorB > 0.3, "a lightning flash lights the haze")
weather = nil

if #failures == 0 then
  print(string.format("ATMOSPHERE SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("ATMOSPHERE SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
