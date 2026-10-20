-- ATMOSPHERE — the air, drawn.
--
-- Every world in this game already HAS an atmosphere: the generator rolls its
-- colour, its height and its density, and publishes them to the engine as the
-- body's CelestialBody shell. Since engine 0.116.1 (card 0411) the engine draws
-- that air from the inside too: a daytime sky in the air's colour, whiter at
-- the horizon, a halo round the star, thinning with the camera's height to
-- exactly nothing at the top of the shell, with space dimmed behind it by the
-- same opacity — so the stars come out as you climb.
--
-- This script does two things on top of that.
--
-- 1. THE AIR'S COLOUR, as the engine is given it. The generator rolls a pastel
--    (HSV saturation 0.5, value 0.85) and the engine draws the zenith at ~0.6×
--    that colour and the horizon at 1.12× it with a fifth of white mixed in, so
--    a pastel tint made a sky that was pale all over — the overhead no deeper
--    than the horizon, the whole dome near white. Real skies are the other way
--    round: the zenith is the deep, saturated colour of single scattering, and
--    the horizon is pale because the long path there scatters every colour
--    many times over. `skyAir` re-saturates the rolled colour (keeping its hue,
--    so every world keeps its own air) and takes a little off the density, so
--    more of space's black shows through overhead. It is applied to every body
--    with air, once, from the world record — idempotent, so the generator's
--    data stays the source of truth. The weather greys and darkens the air of
--    the world you are on (a storm sky is not a blue one) through the same call.
--
-- 2. THE HAZE: the scene's fog, as AERIAL PERSPECTIVE — light scattered into
--    the line of sight by the air between you and what you look at, so far
--    ground fades toward the colour of the horizon, the band of sky along the
--    ground is milky, and the sky overhead is left alone.
--
--   rho   how much air is overhead, as a share of the ground's: (1 − alt/H)²,
--         the engine's own curve (its overhead optical depth is
--         2·density·rho), so it is exactly 0 at the top of the shell and
--         arrives there flat — the haze dies with the sky, not after it
--
--   * the haze is a thin SHELL hugging the ground (`fogFollowsBody`: heights
--     are altitudes over the body) a fifth of the air's height deep: a ray
--     along the ground crosses a long way of it and one straight up very
--     little, which is what thickens it toward the horizon and keeps it out
--     of the zenith. (It used to fill the whole shell, so a sky ray crossed
--     as much lit fog as the sky was deep — the dome was the fog's colour, and
--     the sun a blown-out white disc of forward-scattered fog the size of a
--     hand.)
--   * its density is set from the world's SIZE. On a small world (up to
--     ~400 m) the horizon from head height is tens of metres away and that is
--     about all you see, so the extinction is picked so the ground at the
--     eye's horizon is about a quarter hazed under the thickest air. A
--     scale-3 world (600–950 m) is seen across hundreds of metres from any
--     hill and from low flight, and tuned the same way it was a milk wall
--     (the far ridges 70–90% fogged): there the haze is tuned to the world's
--     RADIUS instead — ground one radius away is `farHaze` hazed under the
--     thickest air — which leaves the near and middle ground crisp and the
--     far ridges blue with distance. Between 400 and 600 m the two blend.
--   * the flat ramp (Low/Medium) draws the same air as a distance ramp, its
--     length stretched as 1/rho with height, and `fogSky` (how much of the
--     horizon it takes) falls with the air — a climb out of the air is a fade
--   * the colour is the sky's own horizon colour; at dusk it warms toward the
--     star; at night it is a dim BLUE (night air is lit by starlight and
--     airglow, and dark-adapted eyes see blue; a grey night haze reads as
--     smoke)
--   * an airless world gets no fog at all, and the engine draws it no sky
--
-- The eye is the CAMERA — whatever is driving it: the crew's camera, the
-- cockpit, or the orbit map pulled out to space. planet_camera calls
-- `follow()` the moment it has placed the camera, so this reads the camera's
-- pose for THIS frame; the order two nodes' lateUpdates run in is load order,
-- which the engine says not to rely on. While the orbit map owns the camera
-- planet_camera still calls it (the map's pose may then be a frame old, which
-- the ease covers).
--
-- The weather (weather.lua) publishes `sky = { body, cover, dim, grey, haze,
-- flash }` and this folds it in for the world it names: thicker, greyer,
-- darker haze under a storm, the air's colour greyed with it, and a lightning
-- flash lighting the haze for a frame or two.

defaults = {
  --- Master switch, so a scene can turn the whole effect off without unwiring.
  on = true,
  --- The longest the flat ramp may reach, in metres, at ground level. Only a
  --- world big enough to want more than this is capped by it.
  --@range 200 20000
  range = 2600.0,
  --- Where the flat ramp starts, as a share of the haze's own scale length
  --- (1/extinction). Below this nothing hazes, so the thing in front of you
  --- stays crisp.
  --@range 0.0 0.9
  nearFrac = 0.04,
  --- Where the flat ramp is full, in scale lengths.
  --@range 0.5 6
  farLengths = 1.7,
  --- How much of the horizon the flat fog takes at the ground (fogSky),
  --- before it fades with the air. Horizon-weighted by the engine, so the
  --- zenith keeps the sky's own colour.
  --@range 0 1
  skyFog = 0.42,
  --- Haze at the eye's horizon, under the thickest air (atmo 1): the share of
  --- the ground's colour the haze replaces there. Sets the extinction.
  --@range 0.02 0.8
  horizonHaze = 0.3,
  --- Height the extinction is tuned for (m above the ground): a third-person
  --- eye. Its horizon is sqrt(2·R·h) away. (Small worlds.)
  --@range 1 50
  eyeHeight = 6.0,
  --- Big worlds (scale 3): haze one RADIUS away under the thickest air.
  --@range 0.05 0.9
  farHaze = 0.5,
  --- Radii (m) over which the tuning moves from the eye's horizon (small
  --- worlds) to the world's radius (big ones).
  bigFrom = 400.0,
  bigTo = 600.0,
  --- The haze shell's depth, as a share of the atmosphere's height.
  --@range 0.05 1
  hazeTop = 0.2,
  --- Re-saturate the rolled air colour: 1 keeps it, 1.6 takes the generator's
  --- saturation 0.5 to 0.8. Hue is kept.
  --@range 1 2.5
  airSat = 1.6,
  --- Scale the rolled air colour's value (brightness).
  --@range 0.5 1.2
  airValue = 0.92,
  --- Scale the rolled density: less air overhead, deeper zenith.
  --@range 0.4 1.2
  airDensity = 0.9,
  --- Volumetric scattering: real light marched through the media. Prettier and
  --- more expensive; the shafts through a valley are worth it.
  volumetric = true,
  --- Sun shafts (god rays) where the light is broken by terrain.
  shafts = true,
  --- How much the media throws light toward the sun. Haze aerosol is
  --- forward-scattering (Mie), but a strong lobe on a medium this thick turns
  --- the whole sun side white.
  --@range -0.9 0.9
  anisotropy = 0.3,
  --- How much of the scene's light the volumetric haze scatters (fogLight).
  --@range 0 2
  fogLight = 0.75,
  --- How fast the haze follows the world, per second. The altitude curve is
  --- already continuous; this smooths the jumps that are not — the camera
  --- cutting to the map and back, an SOI hand-off to a world of another colour.
  --@range 0.1 20
  ease = 4.0,
  --- Print what the air is doing, once a second. For tuning and for `run`.
  debug = false,
}

-- ── the curve (pure; tests/smoke_atmosphere.lua holds it) ───────────────────

-- How much air is overhead at `alt` metres above the surface, as a share of
-- the ground's, 0..1: the engine's own curve (shading.rs `overhead_air`), so
-- the fog fades exactly as the sky does. 1 at (or below) the ground, exactly 0
-- at and above the top of the shell `top`, with a flat tangent there.
function density(alt, top)
  if not top or top <= 0 then return 0.0 end
  if alt <= 0 then return 1.0 end
  if alt >= top then return 0.0 end
  local t = 1.0 - alt / top
  return t * t
end

-- The air at the eye for a world record `w` (save.world.<name>), the eye `alt`
-- metres above its radius: the share of air overhead and the shell height.
-- (0, 0) for a world with no air.
function airAt(w, alt, radius)
  if not (w and (w.atmo or 0) > 0.01) then return 0.0, 0.0 end
  -- The published height, or a sane fraction of the radius for a record
  -- written before the height was published.
  local h = w.atmoHeight or 0
  if h <= 0 then h = (radius or 100) * 0.35 end
  return density(alt, h), h
end

local function clamp01(x) return math.max(0.0, math.min(1.0, x)) end

local function smooth(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end

-- The air's colour and density as the ENGINE is given them, from the rolled
-- ones: saturation pushed out from the colour's own grey axis (max channel
-- held, the others pulled away from it — the hue is unchanged), value scaled,
-- density trimmed. `grey` (0..1) and `dim` (0..1) are the weather's: a storm
-- sky loses its colour and some of its light (the rest of the gloom is the
-- exposure, weather.lua, so sky and ground darken together).
function skyAir(r, g, b, atmo, sat, val, dens, grey, dim)
  sat, val, dens = sat or 1.6, val or 0.92, dens or 0.9
  local mx = math.max(r, g, b)
  local function s(c) return math.max(0.0, mx - (mx - c) * sat) * val end
  local r2, g2, b2 = s(r), s(g), s(b)
  grey, dim = clamp01(grey or 0), clamp01(dim or 0)
  if grey > 0 or dim > 0 then
    local y = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2
    local k = 1.0 - 0.3 * dim
    r2 = (r2 + (y - r2) * grey) * k
    g2 = (g2 + (y - g2) * grey) * k
    b2 = (b2 + (y - b2) * grey) * k
  end
  return r2, g2, b2, clamp01((atmo or 0) * dens)
end

-- The colour of the engine's sky AT the horizon with the star's halo left out
-- (field.wgsl `atmo_composite`, inside the air) — the haze colour, so the far
-- ground meets the sky without a seam. `sunUp` is the star's elevation over
-- the local horizon (a cosine). Dusk warms it toward the low sun; night takes
-- it to a dim blue rather than a dim copy of the day colour.
NIGHT = { 0.030, 0.042, 0.075 }
function horizonColor(r, g, b, sunUp)
  sunUp = sunUp or 1
  local light = 0.05 + 0.95 * smooth(-0.3, 0.25, sunUp)
  local k = 1.12 * light
  local hr, hg, hb = (r + (1 - r) * 0.22) * k, (g + (1 - g) * 0.22) * k, (b + (1 - b) * 0.22) * k
  -- Twilight: the sun within a few degrees of the horizon reddens the band
  -- of air along it (the long path strips the blue out of its light).
  local tw = math.exp(-(sunUp / 0.12) ^ 2) * 0.45 * light
  hr, hg, hb = hr + (1.0 * k - hr) * tw, hg + (0.62 * k - hg) * tw, hb + (0.38 * k - hb) * tw
  -- Night: starlight and airglow, seen by dark-adapted (blue-shifted) eyes.
  local night = 1.0 - smooth(-0.35, 0.05, sunUp)
  return hr + NIGHT[1] * night, hg + NIGHT[2] * night, hb + NIGHT[3] * night
end

-- The haze's extinction per metre at the ground, for a world of radius R and
-- air `atmo` (0..1): the ground at the eye's horizon, sqrt(2·R·h) away, is
-- `horizonHaze` hazed under atmo 1, in proportion to the air below that.
--
-- A big world (radius past `bigFrom`, all of it past `bigTo`) is tuned to its
-- radius instead: ground one radius away is `farHaze` hazed under atmo 1.
function extinction(radius, atmo, horizonHaze, eyeH, farHaze, bigFrom, bigTo)
  radius = math.max(radius or 100, 1)
  local d = math.sqrt(2 * radius * (eyeH or 6))
  local hz = (horizonHaze or 0.3)
  local big = smooth(bigFrom or 400, bigTo or 600, radius)
  if big > 0 then
    d = d + (radius - d) * big
    hz = hz + ((farHaze or 0.5) - hz) * big
  end
  hz = math.min(0.95, hz * clamp01(atmo or 0))
  if hz <= 0 then return 0 end
  return -math.log(1 - hz) / d
end

-- ── the scene ───────────────────────────────────────────────────────────────

-- Published for probes and other scripts: the eased share of air overhead,
-- the atmo-weighted fog amount and the star's elevation at the eye.
rho_now, fog_now, sun_now = 0.0, 0.0, 1.0

local lightNode, lit
local gx_ref, wx_ref
local wx_t = -100
local cam_node, cam_ref

-- The ACTIVE camera's position, whichever camera that is (a probe's, a
-- cutscene's, the builder's), read through the engine's own projection; nil
-- before a camera is being fed. With only "Camera 1" followed, a picture
-- taken through any other camera wore the haze of wherever the crew stood —
-- a moon photographed from orbit came out in its parent planet's air.
local function active_camera()
  if not (camera and camera.exists and camera.screenToRay and camera.exists()) then return nil end
  local ok, w, h = pcall(camera.screenSize)
  if not ok or not w or w <= 0 then return nil end
  local ok2, ox, oy, oz = pcall(camera.screenToRay, w * 0.5, h * 0.5)
  if ok2 and ox then return ox, oy, oz end
  return nil
end

local function eye()
  local ax, ay, az = active_camera()
  if ax then return ax, ay, az end
  if not (cam_node and cam_node.valid) then cam_node = find("Camera 1") end
  if cam_node and cam_node.valid then return cam_node.x, cam_node.y, cam_node.z end
  if not cam_ref or not cam_ref.valid then cam_ref = findScript("planet_camera") end
  if cam_ref and cam_ref.valid and cam_ref.cam_x then
    return cam_ref.cam_x, cam_ref.cam_y, cam_ref.cam_z
  end
  local a = find("Astronaut")
  if a and a.valid then return a.x, a.y, a.z end
  return nil
end

-- The star lighting this system: a body with an infinite sphere of influence,
-- or failing that the heaviest one. Looked up once a second, not every frame.
local star_name, star_t = nil, -100
local function star()
  if time - star_t > 1.0 or not star_name then
    star_t = time
    local best, bmu = nil, -1
    for _, b in ipairs(space.bodies() or {}) do
      local key = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
      if key > bmu then best, bmu = b.name, key end
    end
    star_name = best
  end
  return star_name and space.body(star_name)
end

-- ── the air's colour, given to the engine ───────────────────────────────────
-- name → { node, r, g, b, d } of what was last sent, so a body is written once
-- and then only when the weather moves its colour by a visible amount.
local sent = {}
local scan_t = -100

local function send_air(name, w, grey, dim)
  local n = find(name)
  if not (n and n.valid ~= false and n.setCelestial) then return end
  local r, g, b, d = skyAir(w.atmoR or 0.55, w.atmoG or 0.68, w.atmoB or 0.92, w.atmo or 0,
    params.airSat, params.airValue, params.airDensity, grey, dim)
  local s = sent[name]
  if s and s.node == n and math.abs(s.r - r) + math.abs(s.g - g) + math.abs(s.b - b) < 0.004
      and math.abs(s.d - d) < 0.002 then
    return
  end
  n:setCelestial { atmoColor = { r, g, b }, atmoDensity = d }
  sent[name] = { node = n, r = r, g = g, b = b, d = d }
end

-- Every body with air gets its colour once (and again if its node is rebuilt
-- — a neighbour system streaming back in). Twice a second at most.
local function scan_air(here, wsky)
  if time - scan_t < 0.5 then return end
  scan_t = time
  for _, b in ipairs(space.bodies() or {}) do
    local w = save.get("world." .. b.name)
    if w and (w.atmo or 0) > 0.01 then
      local grey, dim = 0, 0
      if wsky and wsky.body == b.name then grey, dim = wsky.grey or 0, wsky.dim or 0 end
      send_air(b.name, w, grey, dim)
    end
  end
end

-- Blended state, so nothing snaps.
local cur = { rho = 0.0, atmo = 0.0, h = 0.0, r = 0.55, g = 0.68, b = 0.92, sun = 1.0, sig = 0.0,
              cover = 0.0, dim = 0.0, grey = 0.0, haze = 1.0 }
local dbg_t = -100
local done_at = nil   -- the `time` of the frame already followed

local warned = false
local function lighting()
  if lit and lightNode and lightNode.valid then return lit end
  lightNode = find("Lighting")
  lit = lightNode and lightNode:getcomponent("Light") or nil
  if not lit and not warned and time > 5.0 then
    warned = true
    print("atmosphere: the scene's Lighting node is not reachable from Lua — the haze is not drawn")
  end
  return lit
end

local function fog_off(l)
  l.fog = false
  l.fogVolumetric = false
  l.fogShafts = false
  l.fogSky = 0
end

-- The air at the eye: share overhead, the world record, its radius, shell
-- height, the star's elevation over the local horizon and the body's name.
local function air_here(x, y, z)
  local dom = space.dominant(x, y, z)
  local b = dom and space.body(dom)
  if not b then return 0 end
  local dx, dy, dz = x - b.x, y - b.y, z - b.z
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  local w = save.get("world." .. dom)
  local rho, h = airAt(w, d - (b.radius or 1), b.radius)
  local sunUp = nil
  local s = star()
  if s and d > 1e-6 then
    local qx, qy, qz = s.x - x, s.y - y, s.z - z
    local ql = math.sqrt(qx * qx + qy * qy + qz * qz)
    if ql > 1e-6 then sunUp = (dx * qx + dy * qy + dz * qz) / (d * ql) end
  end
  return rho, w, b.radius or 100, h, sunUp, dom
end

-- What the weather says about the sky over `dom` (weather.lua), or nil.
local function weather_sky(dom)
  if not wx_ref or not wx_ref.valid then
    if time - wx_t < 2.0 then return nil end
    wx_t = time
    wx_ref = findScript and findScript("weather") or nil
  end
  local s = wx_ref and wx_ref.sky
  if s and (dom == nil or s.body == dom) then return s end
  return nil
end

-- Read the eye and set the haze for this frame. Called by planet_camera right
-- after it places the camera (and while the orbit map has it); this node's
-- own lateUpdate covers a scene with no planet_camera.
function follow(dt)
  if done_at == time then return end
  done_at = time
  local l = lighting()
  if not l then return end
  l.fogFollowsBody = true
  if params.on == false then
    if cur.rho > 0 then cur.rho = 0; fog_off(l) end
    return
  end

  local ex, ey, ez = eye()
  if not ex then return end
  local rho, w, rad, h, sunUp, dom = air_here(ex, ey, ez)
  rho = rho or 0
  local wsky = weather_sky(dom)
  scan_air(dom, wsky)

  -- Ease toward the target. Colour eases too, so crossing an SOI from a green
  -- world to a red one is a fade rather than a cut.
  local k = 1.0 - math.exp(-(params.ease or 4.0) * math.max(dt or 0, 0))
  cur.rho = cur.rho + (rho - cur.rho) * k
  if rho > 0 and w then
    local atmo = clamp01(w.atmo or 0)
    cur.atmo = cur.atmo + (atmo - cur.atmo) * k
    cur.h = cur.h + ((h or cur.h) - cur.h) * k
    local r, g, b = skyAir(w.atmoR or 0.55, w.atmoG or 0.68, w.atmoB or 0.92, atmo,
      params.airSat, params.airValue, params.airDensity)
    cur.r = cur.r + (r - cur.r) * k
    cur.g = cur.g + (g - cur.g) * k
    cur.b = cur.b + (b - cur.b) * k
    local sig = extinction(rad, atmo, params.horizonHaze, params.eyeHeight, params.farHaze, params.bigFrom, params.bigTo)
    cur.sig = cur.sig + (sig - cur.sig) * k
  end
  -- The weather's part, eased the same way (it already moves over minutes;
  -- this only covers the cut to another world).
  local wc, wd, wg, wh = 0, 0, 0, 1
  if wsky then wc, wd, wg, wh = wsky.cover or 0, wsky.dim or 0, wsky.grey or 0, wsky.haze or 1 end
  cur.cover = cur.cover + (wc - cur.cover) * k
  cur.dim = cur.dim + (wd - cur.dim) * k
  cur.grey = cur.grey + (wg - cur.grey) * k
  cur.haze = cur.haze + (wh - cur.haze) * k
  if sunUp then cur.sun = cur.sun + (sunUp - cur.sun) * k end
  -- An eased value creeps toward zero and never gets there; the fog is cut
  -- once what is left could not move a pixel.
  if rho <= 0 and cur.rho < 1e-5 then cur.rho = 0 end
  local amt = cur.rho * cur.atmo
  rho_now, fog_now, sun_now = cur.rho, amt, cur.sun

  if amt < 1e-4 then
    fog_off(l)
    if params.debug and time - dbg_t > 1.0 then
      dbg_t = time
      print("atmosphere: vacuum")
    end
    return
  end

  -- The haze's colour: the horizon's, then the weather's grey and gloom, and
  -- a lightning flash lighting it for an instant.
  local fr, fg, fb = horizonColor(cur.r, cur.g, cur.b, cur.sun)
  if cur.grey > 0 or cur.dim > 0 or cur.cover > 0 then
    -- Under a closing deck the horizon is the CLOUD's colour: the engine
    -- draws its deck as a quarter the air's colour and three quarters the
    -- daylight's white (field.wgsl), so the haze goes to that, or the far
    -- ground, the sun's disc and every distant thing would be fogged to a
    -- grey darker than the sky around them. The storm's gloom itself is
    -- the exposure's job (weather.lua), which darkens sky and ground alike.
    local lt = 0.05 + 0.95 * smooth(-0.3, 0.25, cur.sun)
    local ov = smooth(0.4, 1.0, cur.cover) * 0.9
    local cr, cg, cb = (0.25 * cur.r + 0.71) * lt, (0.25 * cur.g + 0.71) * lt, (0.25 * cur.b + 0.71) * lt
    fr, fg, fb = fr + (cr - fr) * ov, fg + (cg - fg) * ov, fb + (cb - fb) * ov
    local y = 0.2126 * fr + 0.7152 * fg + 0.0722 * fb
    local kd = 1.0 - 0.2 * cur.dim
    fr, fg, fb = (fr + (y - fr) * cur.grey) * kd, (fg + (y - fg) * cur.grey) * kd, (fb + (y - fb) * cur.grey) * kd
  end
  local tint = wsky and wsky.tint
  if tint and (tint[4] or 0) > 0 then
    -- Dust or ash in the air: the haze takes its colour, lit as the day is.
    local lt = 0.08 + 0.92 * smooth(-0.3, 0.25, cur.sun)
    local a = clamp01(tint[4])
    fr, fg, fb = fr + (tint[1] * lt - fr) * a, fg + (tint[2] * lt - fg) * a, fb + (tint[3] * lt - fb) * a
  end
  local flash = wsky and wsky.flash or 0
  if flash > 0 then
    fr, fg, fb = fr + 0.5 * flash, fg + 0.53 * flash, fb + 0.65 * flash
  end

  -- Extinction at the ground, thickened by the weather (rain and snow are
  -- what most of a storm's murk is), and the scale length that goes with it.
  local sig = math.max(cur.sig * cur.haze, 1e-6)
  local len = 1.0 / sig
  -- Above the ground the whole ramp is stretched by 1/rho, so the haze at any
  -- distance falls in proportion to the air and reaches nothing at the top of
  -- the shell.
  local base_far = math.min(len * (params.farLengths or 1.7), params.range or 2600)
  local far = base_far / math.max(cur.rho, 1e-4)
  local near = math.min(len * (params.nearFrac or 0.04), base_far * 0.5)
  -- Never fog closer than the world is big: on a 100 m moon a 300 m near plane
  -- would put the whole planet inside the clear zone and nothing would show.
  if rad and near > rad * 0.5 then near = rad * 0.5 end

  l.fog = true
  l.fogColorR, l.fogColorG, l.fogColorB = fr, fg, fb
  l.fogStart, l.fogEnd = near, far
  -- The horizon band the flat fog takes: more under overcast (the whole sky
  -- is the cloud's grey then), all of it fading with the air.
  -- (A fair day's scattered cumulus — the deck's cover is 0.3–0.5 on a wet
  -- world in clear weather — is not overcast: only a closing deck counts, or
  -- every clear day on a wet world wore a storm's milky horizon.)
  local ovc = smooth(0.4, 1.0, cur.cover)
  local skyf = (params.skyFog or 0.42) + (1 - (params.skyFog or 0.42)) * 0.75 * ovc
  l.fogSky = clamp01(skyf * cur.rho)
  l.fogDither = true
  l.fogDitherStrength = 0.6

  -- The graphics level has the last word: volumetric fog with sun shafts was
  -- 46 ms of a 1080p frame on a mid-range card (see graphics.lua), so Low and
  -- Medium draw the same air as a distance ramp instead.
  if not gx_ref or not gx_ref.valid then gx_ref = findScript("graphics") end
  local gx_vol = (not gx_ref) or gx_ref.volumetric
  local gx_shafts = (not gx_ref) or gx_ref.shafts
  if params.volumetric ~= false and gx_vol then
    l.fogVolumetric = true
    -- A thin shell hugging the ground (fogFollowsBody: an altitude over the
    -- body), its top softened over its upper third. Under weather it deepens
    -- toward the cloud base, where precipitation hangs.
    local top = math.max(cur.h, 1.0) * ((params.hazeTop or 0.2) + 0.15 * ovc)
    l.fogHeight = top * 0.65
    l.fogFalloff = top * 0.35
    -- The march's fence: far enough to cross the shell along the ground,
    -- shrunk with the air so the optical depth marched to the sky falls away
    -- as the sky does.
    l.fogEnd = math.max(math.min(len * 4.0, params.range or 2600) * cur.rho, 1.0)
    l.fogDensity = sig * cur.rho
    l.fogAnisotropy = (params.anisotropy or 0.3) * (1 - 0.7 * ovc)
    -- Overcast: no direct beam to scatter, only the sky's diffuse light.
    l.fogLight = (params.fogLight or 0.75) * (1 - 0.5 * ovc)
    l.fogShafts = (params.shafts ~= false) and gx_shafts and ovc < 0.3
  else
    l.fogVolumetric = false
    l.fogShafts = false
  end

  if params.debug and time - dbg_t > 1.0 then
    dbg_t = time
    print(string.format("atmosphere: rho %.3f sig %.5f fog %.0f..%.0f sky %.2f rgb %.2f %.2f %.2f cover %.2f",
      cur.rho, sig, near, far, l.fogSky, fr, fg, fb, cur.cover))
  end
end

-- Only when no planet_camera is driving it (a scene without one): there, the
-- camera calls follow() itself, in the same frame, after the camera is placed.
function lateUpdate(node, dt)
  if not cam_ref or not cam_ref.valid then cam_ref = findScript("planet_camera") end
  if cam_ref and cam_ref.valid then return end
  follow(dt)
end
