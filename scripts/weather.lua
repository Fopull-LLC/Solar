-- WEATHER — what the air over a world is doing, and what that looks and
-- sounds like where you stand.
--
-- Every world with air has a CLIMATE already (climate.lua, from the record the
-- generator publishes: archetype, sunlight, air, sea). This turns that climate
-- into weather, the way a real one does: what kind of weather a world gets,
-- and how often, follows from how warm and how wet it is.
--
--   warm and wet      (a canyon world with a sea)   rain, thunderstorms, hail
--   cold              (ice worlds, polar ground)    snow, blizzards
--   hot and dry       (dune worlds)                 dust storms, the odd shower
--   molten            (lava worlds)                 ash fall, ash storms with
--                                                   volcanic lightning
--   no air            (every moon)                  nothing, ever
--
-- Snow or rain is decided where you stand, from climate.lua's temperature
-- there (the freezing point is temp ≈ 0.44 on its scale, −40 + 90·t °C), so
-- the poles of a temperate world snow while its equator rains, with sleet in
-- between.
--
-- ── the state machine ───────────────────────────────────────────────────────
-- Each world's weather is a pure function of (its seed, the weather clock):
-- the clock is cut into spells of `spell` seconds, and each spell boundary
-- rolls (by hash, not by a random generator) whether a front comes through
-- and how strong it is at its height. Between two boundaries the intensity
-- eases from one to the next over most of a spell — minutes, not frames —
-- and the STATE is read off it and which way it is going:
--
--   clear → overcast → precipitation → storm → clearing → clear
--
-- Nothing is stored but the clock, so the weather survives save and load
-- exactly: load a save and the front that was coming is still coming. The
-- clock runs on rails time (space.time), so time warp brings the weather on
-- with the orbits.
--
-- ── what it drives ──────────────────────────────────────────────────────────
--   * the cloud deck (CelestialBody `clouds`, `cloudDarkness`, `cloudColor`,
--     setCelestial), per world: thicker, darker and greyer as a front builds
--   * the sky and the haze, through atmosphere.lua: `sky` below is read there
--     every frame (greyer and darker air, thicker haze, a lightning flash)
--   * the sun's shadows soften and the picture's exposure falls under
--     overcast — under cloud the light is the sky's, not the sun's
--   * precipitation around the camera: patches of rain, snow, hail, dust or
--     ash fired a few metres overhead and upwind (vfx/RainPatch etc., made
--     by tools/gen_vfx.py), drifting with the wind; never indoors (a ray
--     straight up finds a roof), in the cockpit, under the sea, on the orbit
--     map, or at speed
--   * lightning: a bolt (vfx/Lightning, a jagged channel of jittered beams,
--     engine 0.117, core and glow on one seed so they line up, thrown once
--     and held), the cloud base lit where it leaves it, a flash of real
--     light, the sky and haze lit up, all on ONE smooth envelope (FLASH), and
--     the thunder after it, late by the distance over the speed of sound
--   * soundscape.lua reads `current()` for the rain, hail and dust beds
--
-- The wind is declared to the engine (weather.addWind, v0.117): a cell
-- around the camera in the world's own frame, blowing the speed and heading
-- worked out here, with gusts and eddies that grow with the storm. Anything
-- may read it with weather.windAt(point). The precipitation patches start
-- with it as their velocity, and their tracks (like the game's smoke and
-- dust) opt into the engine's wind (`Wind(coupling)` in the .vfx.ron), so a
-- gust carries what is already falling.
--
-- Cross-script:
--   local wx = findScript("weather")
--   wx.current()   → { type, state, intensity, precip, storm, coverage,
--                      wind (m/s), windFrom (degrees, 0 = north), windX/Y/Z
--                      (world, relative to the planet), windNow (m/s, the
--                      engine's wind at the camera this frame, gusts and
--                      all), tempC, sheltered, body, label }
--                      — or nil off every world
--   wx.line()      → "Rain · wind 6 m/s from the SW", for a HUD
--   wx.force(type, k)   hold a weather (probes, tests); force(nil) lets go
--   wx.sky         { body, cover, dim, grey, haze, flash, tint, cloudDark,
--                    cloudColor } for atmosphere.lua

defaults = {
  --- Master switch.
  on = true,
  --- Seconds of weather clock between two possible fronts. A front builds and
  --- clears over most of one.
  --@range 60 3600
  spell = 360.0,
  --- Precipitation particles around the camera.
  particles = true,
  --- Lightning in thunderstorms and ash storms.
  lightning = true,
  --- Strikes a minute at the height of a storm.
  --@range 0 30
  strikeRate = 6.0,
  --- Multiplies every particle count (a quality knob).
  --@range 0 2
  density = 1.0,
  --- How far (m) the patch centres scatter around the camera.
  --@range 0 30
  scatter = 9.0,
  --- Exposure (stops) the darkest storm takes off the picture.
  --@range 0 2
  gloom = 1.0,
  --- Print the weather once every few seconds.
  debug = false,
}

local sqrt, floor, max, min, exp = math.sqrt, math.floor, math.max, math.min, math.exp
local dt_now = 0
local function clamp01(x) return max(0.0, min(1.0, x)) end
local function smooth(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end

-- ── pure: the climate's weather ─────────────────────────────────────────────

-- A deterministic hash of (seed, spell, salt) → [0, 1). No random generator:
-- the same arguments are the same weather on every load.
function hash(seed, k, salt)
  local x = (seed % 100003) * 0.0137 + k * 1.6180339 + (salt or 0) * 7.3127
  local h = math.sin(x * 12.9898 + 78.233) * 43758.5453
  return h - floor(h)
end

-- Archetype character, matching climate.lua's KIND table: base warmth and
-- wetness before sunlight and air have their say.
local KIND = {
  canyon  = { temp = 0.55, moist = 0.45 },
  dune    = { temp = 0.78, moist = 0.12 },
  ice     = { temp = 0.16, moist = 0.55 },
  frost   = { temp = 0.12, moist = 0.40 },
  lava    = { temp = 0.95, moist = 0.05 },
  crystal = { temp = 0.45, moist = 0.25 },
  barren  = { temp = 0.40, moist = 0.02 },
}

-- What weather a world gets, from its record (save.world.<name>):
--   wet    share of spells that bring a front of rain or snow
--   dust   share that bring a dust storm (dry, windy, warm worlds)
--   ash    a molten world: its fronts are ash
--   storm  how likely a front is to build into a storm (convection wants
--          warmth AND moisture)
--   hail   how likely a thunderstorm is to drop hail (strong updrafts, a
--          cold upper air: temperate worlds most)
--   cover  the cloud cover of a clear day
--   wind   the mean wind, m/s (thicker air, more of it)
--   temp   the world's mean temperature on climate.lua's 0..1 scale
function profile(w)
  local atmo = w and (w.atmo or 0) or 0
  if atmo < 0.05 then return { airless = true, wet = 0, dust = 0, storm = 0, hail = 0, cover = 0, wind = 0, temp = 0.4 } end
  local k = KIND[w.kind] or KIND.barren
  local temp = k.temp * (0.55 + 0.45 * (w.insol or 1.0))
  local moist = k.moist * (0.5 + 0.5 * atmo) + (((w.sea or 0) > 0) and 0.3 or 0)
  local p = { airless = false, temp = temp, moist = moist }
  p.ash = (w.kind == "lava")
  p.wet = p.ash and 0 or max(0.04, min(0.45, moist * 0.6))
  -- Dust wants dry ground, heat and wind: the deserts.
  p.dust = p.ash and 0 or clamp01((0.35 - moist) * 2.2) * smooth(0.35, 0.7, temp) * 0.5
  if p.ash then p.wet, p.dust = 0, 0 end
  -- Convective potential: warm, moist air rising. Cold worlds still get
  -- blizzards (wind-driven, not convective), so they keep a floor.
  p.storm = clamp01(smooth(0.3, 0.7, temp) * moist * 1.2 + 0.15)
  if p.ash then p.storm = 0.8 end
  -- Hail is a minority of thunderstorms: the updraft has to be strong and
  -- the air above cold, and most storms drop rain.
  p.hail = clamp01(smooth(0.3, 0.55, temp) * (1 - smooth(0.7, 0.95, temp)) * moist * 1.6) * 0.3
  p.cover = max(0.04, min(0.55, 0.06 + 0.5 * moist))
  p.wind = 1.5 + 5.0 * atmo
  return p
end

-- The front rolled for spell `k` of a world with seed `seed` and profile `p`:
-- its peak intensity (0..1) and what it is made of ("wet", "dust", "ash").
-- Peaks over 0.74 are storms and only a storm-capable front may reach them.
function front(seed, p, k)
  if p.airless then return 0, "none", false end
  local chance = p.ash and 0.6 or min(0.9, p.wet + p.dust)
  local h = hash(seed, k, 1)
  local kind = p.ash and "ash" or "wet"
  if not p.ash and p.dust > 0 and hash(seed, k, 2) < p.dust / max(p.wet + p.dust, 1e-6) then kind = "dust" end
  local v
  if h < chance then
    v = 0.45 + 0.55 * hash(seed, k, 4) ^ 0.8
  else
    -- No front: clear, or a grey day that never comes to anything.
    v = 0.38 * hash(seed, k, 4) ^ 1.5
  end
  local stormy = hash(seed, k, 3) < p.storm
  if v > 0.74 and not stormy then v = 0.70 + 0.04 * hash(seed, k, 5) end
  local hail = kind == "wet" and stormy and hash(seed, k, 6) < p.hail
  return v, kind, hail
end

-- The weather at clock `t`: intensity and the trend (+1 building, −1
-- clearing), and the front it belongs to. The intensity eases between two
-- spell boundaries over the middle 70% of the spell, so a front takes
-- minutes to build and minutes to clear.
function at(seed, p, t, spell)
  spell = spell or 360
  local u = t / spell
  local k = floor(u)
  local f = u - k
  local v0, k0, h0 = front(seed, p, k)
  local v1, k1, h1 = front(seed, p, k + 1)
  local s = smooth(0.15, 0.85, f)
  local I = v0 + (v1 - v0) * s
  local trend = (s > 0 and s < 1) and ((v1 > v0) and 1 or -1) or 0
  -- The front that is making the weather: whichever end is contributing more.
  local kind, hail = k0, h0
  if v1 * s > v0 * (1 - s) then kind, hail = k1, h1 end
  return I, trend, kind, hail
end

-- Everything the scene needs, from an intensity, a front kind, and the
-- temperature where you stand (climate.lua's 0..1).
FREEZE = 0.444
function derive(p, I, trend, kind, hail, temp)
  local o = { intensity = I }
  if p.airless then
    o.type, o.state, o.precip, o.storm, o.cover, o.snow = "none", "none", 0, 0, 0, 0
    o.coverage, o.hail, o.lightning, o.kind = 0, 0, 0, "none"
    return o
  end
  o.cover = (p.cover or 0.1) + (1 - (p.cover or 0.1)) * smooth(0.12, 0.5, I)
  o.coverage = o.cover
  o.precip = smooth(0.42, 0.66, I)
  o.storm = smooth(0.74, 0.92, I)
  -- Snow below freezing, rain above, sleet in a narrow band between.
  temp = temp or p.temp or 0.5
  o.snow = (kind == "wet") and (1 - smooth(FREEZE - 0.03, FREEZE + 0.02, temp)) or 0
  o.hail = (hail and kind == "wet" and o.snow < 0.5) and smooth(0.3, 0.8, o.storm) or 0
  o.kind = kind
  -- The state, off the intensity and its direction.
  if I < 0.16 then o.state = "clear"
  elseif o.storm > 0.3 then o.state = "storm"
  elseif o.precip > 0.08 then o.state = (trend < 0 and I < 0.55) and "clearing" or "precipitation"
  else o.state = (trend < 0) and "clearing" or "overcast" end
  -- The type a person would name it by.
  if o.state == "clear" then o.type = "clear"
  elseif o.precip <= 0.08 then o.type = "overcast"
  elseif kind == "dust" then o.type = o.storm > 0.3 and "duststorm" or "dust"
  elseif kind == "ash" then o.type = o.storm > 0.3 and "ashstorm" or "ash"
  elseif o.snow >= 0.5 then o.type = o.storm > 0.3 and "blizzard" or "snow"
  elseif o.hail > 0.3 then o.type = "hail"
  else o.type = o.storm > 0.3 and "thunderstorm" or "rain" end
  o.lightning = ((kind == "wet" and o.snow < 0.5) or kind == "ash") and o.storm or 0
  return o
end

-- The wind: a slow random walk in direction and strength, one key per half
-- spell, plus what the weather adds (a storm's gusts). Heading is the
-- direction the wind blows FROM, radians clockwise from north.
function wind(seed, p, t, spell, o)
  if p.airless then return 0, 0 end
  spell = (spell or 360) * 0.5
  local u = t / spell
  local k = floor(u)
  local s = smooth(0, 1, u - k)
  local a0, a1 = hash(seed, k, 11) * 6.2832, hash(seed, k + 1, 11) * 6.2832
  local da = (a1 - a0 + 3.14159) % 6.28318 - 3.14159
  local heading = (a0 + da * s) % 6.28318
  local m = 0.6 + 0.8 * (hash(seed, k, 12) + (hash(seed, k + 1, 12) - hash(seed, k, 12)) * s)
  local gust = (o and o.kind == "dust") and 15 or 9
  local speed = p.wind * m + 3.0 * (o and o.cover or 0) + gust * (o and o.storm or 0)
  return speed, heading
end

-- How the weather leans on the light. Bad weather is DARK: under a closed
-- deck the sun's direct beam is mostly gone (a thick storm cloud passes a
-- few percent of it) and what lights the ground is the diffuse sky, so the
-- picture falls by a stop or two — which is what an eye reads as a storm,
-- not a pale haze. The deck itself darkens and greys (`cloudDark`,
-- `cloudColor`: the engine's per-world cloud style, v0.117), so a storm sky
-- is dark of its own accord; the sun's own light (`sun`, a multiplier on the
-- star's colour) dims the ground under it, and a smaller exposure fall
-- (`stops`) and the haze, which goes to a dark slate (`tint`), do the rest.
--   dim    how much the air's own colour darkens (atmosphere.lua)
--   grey   how much it loses its colour
--   haze   how much thicker the haze is (rain hides the far hills, snow
--          more, a dust storm almost everything)
--   stops  exposure, negative
--   sun    the direct light's share left
--   amb    diffuse sky light added to the ambient (a share of daylight)
--   tint   { r, g, b, amount } the haze's colour
--   cloudDark   the deck's darkness, 0..1 (1 = almost no light through)
--   cloudColor  { r, g, b } the deck's daylight colour (white = fair weather)
local HAZE = { wet = 3.0, snow = 7.0, dust = 12.0, ash = 6.0 }
local GLOOM = { wet = 1.0, snow = 0.65, dust = 0.8, ash = 1.15 }
function skyOf(o)
  local c = o.cover or 0
  local overcast = smooth(0.45, 1.0, c)
  local p, st, sn = o.precip or 0, o.storm or 0, o.snow or 0
  local kind = o.kind or "wet"
  local dim = min(0.9, 0.25 * overcast + 0.3 * p + 0.35 * st)
  local grey = min(0.9, 0.55 * overcast + 0.3 * p)
  local hz = (kind == "dust" and HAZE.dust) or (kind == "ash" and HAZE.ash)
    or (HAZE.wet + (HAZE.snow - HAZE.wet) * sn)
  local haze = 1 + p * hz * 0.6 + st * hz * 0.4
  local g = (kind == "dust" and GLOOM.dust) or (kind == "ash" and GLOOM.ash)
    or (GLOOM.wet + (GLOOM.snow - GLOOM.wet) * sn)
  -- A little less than before the deck could darken (0.75 / 0.45 / 0.9):
  -- some of the storm's dark is the clouds' own now. (At 0.6 / 0.35 / 0.65
  -- a storm measured 11% brighter than the look the player approved.)
  local stops = -(0.7 * overcast + 0.42 * p + 0.85 * st) * g
  local sun = max(0.04, 1 - 0.72 * overcast - 0.14 * p - 0.1 * st)
  local amb = 0.16 * overcast
  -- The haze: blue-grey under rain, slate under a thunderstorm, a pale
  -- grey white-out in snow, dark in ash (dust is the ground's colour, set
  -- by the caller, which knows the world).
  local tr, tg, tb
  if kind == "ash" then tr, tg, tb = 0.2, 0.19, 0.18
  else
    tr, tg, tb = 0.40 - 0.16 * st, 0.44 - 0.16 * st, 0.50 - 0.15 * st
    tr, tg, tb = tr + (0.76 - tr) * sn, tg + (0.78 - tg) * sn, tb + (0.82 - tb) * sn
  end
  local ta = min(0.95, max(0.7 * overcast, 0.9 * p))
  -- The deck: a grey day's cloud is pale, rain cloud is a heavy blue-grey and
  -- a thunderhead is nearly black from below; snow cloud stays light, ash
  -- cloud is brown-black, and dust is the haze's own colour (the caller).
  local cd = min(0.95, 0.2 * overcast + 0.3 * p + 0.45 * st)
  local cr, cg, cb = 1.0 - 0.2 * overcast - 0.12 * st, 1.0 - 0.17 * overcast - 0.1 * st, 1.0 - 0.1 * overcast - 0.06 * st
  if kind == "ash" then cr, cg, cb = 0.55, 0.5, 0.46
  elseif sn > 0 then
    cr, cg, cb = cr + (0.94 - cr) * sn, cg + (0.95 - cg) * sn, cb + (0.98 - cb) * sn
    cd = cd * (1 - 0.45 * sn)
  end
  return { cover = c, dim = dim, grey = grey, haze = haze, stops = stops, sun = sun, amb = amb,
           tint = { tr, tg, tb, ta }, cloudDark = cd, cloudColor = { cr, cg, cb } }
end

-- ── the scene ───────────────────────────────────────────────────────────────

sky = nil            -- published for atmosphere.lua
local cur = nil      -- the last current() table
local clock = nil    -- the weather clock, seconds
local last_rails = nil
local save_t = 0
local forced = nil   -- { type, k, I, eased }

local refs, missed = {}, {}
local function ref(kind)
  local r = refs[kind]
  if r and r.valid then return r end
  if missed[kind] and time - missed[kind] < 2.0 then return nil end
  r = findScript and findScript(kind) or nil
  refs[kind], missed[kind] = r, (r == nil) and time or nil
  return r
end

-- The world records are read through a small cache: save.get hands back a
-- fresh table each call, and this is asked every frame.
local wcache, wcache_t = {}, -100
local gseed = nil
local function world_of(name)
  if not name then return nil end
  if time - wcache_t > 5.0 then wcache, wcache_t, gseed = {}, time, nil end
  local w = wcache[name]
  if w == nil then
    w = save.get("world." .. name) or false
    wcache[name] = w
  end
  return w or nil
end

-- A world's own weather seed: its terrain seed, folded with the save's.
local function seed_of(name, w)
  if gseed == nil then gseed = save.get("g_seed") or 0 end
  return ((w and w.seed or 1) + gseed * 31) % 1000003
end

-- The camera: planet_camera's pose, or the camera node.
local cam_node
local function eye()
  local pc = ref("planet_camera")
  if pc and pc.cam_x then return pc.cam_x, pc.cam_y, pc.cam_z end
  if not (cam_node and cam_node.valid) then cam_node = find("Camera 1") end
  if cam_node and cam_node.valid then return cam_node.x, cam_node.y, cam_node.z end
  return nil
end

-- Forced weather (probes, tests): the front kind, intensity and temperature
-- that make each named type.
local FORCE = {
  clear        = { I = 0.05, kind = "wet" },
  overcast     = { I = 0.36, kind = "wet" },
  rain         = { I = 0.62, kind = "wet", temp = 0.6 },
  storm        = { I = 0.96, kind = "wet", temp = 0.6 },
  thunderstorm = { I = 0.96, kind = "wet", temp = 0.6 },
  hail         = { I = 0.96, kind = "wet", temp = 0.55, hail = true },
  snow         = { I = 0.62, kind = "wet", temp = 0.25 },
  blizzard     = { I = 0.96, kind = "wet", temp = 0.2 },
  dust         = { I = 0.62, kind = "dust" },
  duststorm    = { I = 0.96, kind = "dust" },
  ash          = { I = 0.62, kind = "ash" },
  ashstorm     = { I = 0.96, kind = "ash" },
}

function force(kind, k)
  if not kind then forced = nil; return end
  local f = FORCE[kind]
  if not f then print("weather: no such weather '" .. tostring(kind) .. "'"); return end
  k = k or 1
  forced = { def = f, I = 0.3 + (f.I - 0.3) * k, name = kind }
  if kind == "clear" or kind == "overcast" then forced.I = f.I end
end

-- ── what the camera's world is doing ────────────────────────────────────────
local temp_t, temp_v, temp_body = -100, nil, nil
local function temp_here(name, x, y, z, p)
  if time - temp_t > 2.0 or temp_body ~= name then
    temp_t, temp_body = time, name
    local cl = ref("climate")
    local s = cl and cl.sampleAt and cl.sampleAt(name, x, y, z)
    temp_v = s and s.temp or p.temp
  end
  return temp_v or p.temp
end

-- The local frame at a point on body b: up, north, east.
local function frame(b, x, y, z)
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-6 then return 0, 1, 0, 0, 0, 1, 1, 0, 0, 0 end
  ux, uy, uz = ux / l, uy / l, uz / l
  -- North: the body's +Y axis (its pole, as climate.lua reads latitude),
  -- flattened onto the ground; at a pole, any direction will do.
  local nx, ny, nz = -ux * uy, 1 - uy * uy, -uz * uy
  local nl = sqrt(nx * nx + ny * ny + nz * nz)
  if nl < 1e-4 then nx, ny, nz, nl = 1, 0, 0, 1 end
  nx, ny, nz = nx / nl, ny / nl, nz / nl
  -- East = north × up.
  local ex, ey, ez = ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux
  return ux, uy, uz, nx, ny, nz, ex, ey, ez, l
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local NAMES = {
  clear = "Clear", overcast = "Overcast", rain = "Rain", thunderstorm = "Thunderstorm",
  snow = "Snow", blizzard = "Blizzard", hail = "Hail", dust = "Blowing dust",
  duststorm = "Dust storm", ash = "Ash fall", ashstorm = "Ash storm", none = "No air",
}

local function compute(name, b, w, x, y, z)
  local p = profile(w)
  local seed = seed_of(name, w)
  local I, trend, kind, hail = at(seed, p, clock or 0, params.spell)
  local temp
  if forced then
    local f = forced.def
    forced.eased = forced.eased or I
    forced.eased = forced.eased + (forced.I - forced.eased) * min(1, (dt_now or 0) * 3)
    I, trend, kind, hail = forced.eased, 1, f.kind, f.hail
    temp = f.temp
    if p.airless then p = profile({ atmo = 0.7, kind = "canyon", insol = 1 }) end
  end
  temp = temp or temp_here(name, x, y, z, p)
  local o = derive(p, I, trend, kind, hail, temp)
  local spd, heading = wind(seed, p, clock or 0, params.spell, o)
  local ux, uy, uz, nx, ny, nz, ex, ey, ez = frame(b, x, y, z)
  -- The wind blows FROM `heading`: its velocity points the other way.
  local sh, ch = math.sin(heading), math.cos(heading)
  o.windX = -(nx * ch + ex * sh) * spd
  o.windY = -(ny * ch + ey * sh) * spd
  o.windZ = -(nz * ch + ez * sh) * spd
  o.wind, o.windFrom = spd, math.deg(heading) % 360
  o.up = { ux, uy, uz }
  o.tempC = -40 + 90 * temp
  o.body = name
  o.airless = p.airless
  local d = DIRS[floor((o.windFrom + 22.5) / 45) % 8 + 1]
  o.label = (NAMES[o.type] or o.type) .. (p.airless and "" or string.format(" · wind %.0f m/s from the %s", spd, d))
  return o, p, seed
end

-- ── the clouds, on every world with air ─────────────────────────────────────
-- A dust storm's deck is the dust: the ground's colour, lifted toward white.
local function dust_deck(w)
  local g = w and w.ground
  if not (g and g[1]) then return { 0.86, 0.76, 0.62 } end
  return { 0.45 + 0.55 * g[1], 0.45 + 0.55 * g[2], 0.45 + 0.55 * g[3] }
end

local clouds_sent = {}
local clouds_t = -100
local function send_clouds(name, cover, dark, col)
  local s = clouds_sent[name]
  local n = find(name)
  if not (n and n.setCelestial) then return end
  dark, col = dark or 0, col or { 1, 1, 1 }
  if s and s.node == n and math.abs(s.c - cover) < 0.006 and math.abs(s.d - dark) < 0.006
    and math.abs(s.r - col[1]) + math.abs(s.g - col[2]) + math.abs(s.b - col[3]) < 0.01 then return end
  n:setCelestial { clouds = cover, cloudDarkness = dark, cloudColor = { col[1], col[2], col[3] } }
  clouds_sent[name] = { node = n, c = cover, d = dark, r = col[1], g = col[2], b = col[3] }
end

local function clouds_all(here, here_sky)
  if here and here_sky then send_clouds(here, here_sky.cover, here_sky.cloudDark, here_sky.cloudColor) end
  if time - clouds_t < 4.0 then return end
  clouds_t = time
  for _, b in ipairs(space.bodies() or {}) do
    if b.name ~= here then
      local w = world_of(b.name)
      if w and (w.atmo or 0) > 0.05 then
        local p = profile(w)
        local I, trend, kind, hail = at(seed_of(b.name, w), p, clock or 0, params.spell)
        local sk = skyOf(derive(p, I, trend, kind, hail, p.temp))
        if kind == "dust" then sk.cloudColor = dust_deck(w) end
        send_clouds(b.name, sk.cover, sk.cloudDark, sk.cloudColor)
      end
    end
  end
end

-- ── the light: shadows, ambient, the sun, exposure ──────────────────────────
local lit, post, base_shadow, base_exposure, base_amb
local function light_and_post()
  if not lit then
    local ln = find("Lighting")
    lit = ln and ln:getcomponent("Light") or nil
    if lit then
      base_shadow = lit.shadowStrength or 1.0
      base_amb = { lit.ambientR or 0, lit.ambientG or 0, lit.ambientB or 0 }
    end
  end
  if not post then
    local pn = find("Post Processing")
    post = pn and pn:getcomponent("PostProcess") or nil
    if post then base_exposure = post.exposure or 0 end
  end
  return lit, post
end

-- The home star's light. In stars mode the ground is lit by the star's
-- CelestialBody colour × its luminosity (the Lighting node's intensity does
-- not reach it), so cloud dims the sun by scaling that colour. The colour it
-- was given is its material's (system_generator sets both from the class).
local star = { node = nil, base = nil, k = 1 }
local function star_node()
  if star.node and star.node.valid ~= false then return star.node end
  local h = save.get("system.home")
  local n = h and h.star and find(h.star)
  if not (n and n.setCelestial) then return nil end
  local m = n.material and n:material()
  local c = m and m.color
  if not c then return nil end
  star.node = n
  star.base = { c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1 }
  star.k = 1
  return n
end
local function star_light(k)
  local n = star_node()
  if not n then return end
  if math.abs(k - star.k) < 0.01 and not (k == 1 and star.k ~= 1) then return end
  star.k = k
  local b = star.base
  n:setCelestial { starColor = { b[1] * k, b[2] * k, b[3] * k } }
end

-- Put the light back as the scene had it (off every world, out of the air).
local function restore()
  if lit and base_shadow then lit.shadowStrength = base_shadow end
  if lit and base_amb then lit.ambientR, lit.ambientG, lit.ambientB = base_amb[1], base_amb[2], base_amb[3] end
  if post and base_exposure then post.exposure = base_exposure end
  if star.node and star.k ~= 1 then star_light(1) end
end

-- ── the wind, declared to the engine ────────────────────────────────────────
-- One cell around the camera, in the frame of the world it is on (so it turns
-- with the world), blowing the speed and heading `compute` worked out. A
-- cell, not a world-wide wind: one vector in a round world's frame would blow
-- straight down into the ground a quarter of the way round it. It follows the
-- camera, and its gusts and eddies grow with the storm. weather.windAt reads
-- it back — the patches below, the soundscape's gusts, anything else.
local wind_id, wind_at = nil, nil
local function wind_off()
  if wind_id and weather and weather.removeWind then weather.removeWind(wind_id) end
  wind_id, wind_at = nil, nil
end

local function engine_wind(o, name, b, x, y, z)
  if not (weather and weather.addWind) then return end
  local n = find(name)
  if not (n and n.toLocal) or o.airless or (o.wind or 0) <= 0 then wind_off(); return end
  local c = n:toLocal(vec3(x, y, z))
  local tip = n:toLocal(vec3(x + o.windX, y + o.windY, z + o.windZ))
  local v = vec3(tip.x - c.x, tip.y - c.y, tip.z - c.z)
  local st = o.storm or 0
  local opts = {
    velocity = v,
    gust = 0.2 + 0.5 * st,
    gustPeriod = 7 - 3 * st,
    turbulence = 0.1 + 0.25 * st,
    scale = 25,
    center = c,
    radius = max(40, (b.radius or 300) * 0.35),
  }
  local w = wind_at
  -- Re-sent when the world, the wind or the camera's place has moved on
  -- enough to matter, not every frame.
  local fresh = w and w.name == name and w.node == n
  if fresh then
    local dv = (w.vx - v.x) ^ 2 + (w.vy - v.y) ^ 2 + (w.vz - v.z) ^ 2
    local dc = (w.cx - c.x) ^ 2 + (w.cy - c.y) ^ 2 + (w.cz - c.z) ^ 2
    if dv < 0.01 and dc < (opts.radius * 0.2) ^ 2 and math.abs(w.st - st) < 0.05 then return end
  end
  if fresh and wind_id then
    if not weather.setWind(wind_id, opts) then wind_id = nil end
  end
  if not (fresh and wind_id) then
    wind_off()
    opts.parent = name
    local okw, id = pcall(weather.addWind, opts)
    wind_id = okw and id or nil
  end
  wind_at = { name = name, node = n, vx = v.x, vy = v.y, vz = v.z, cx = c.x, cy = c.y, cz = c.z, st = st }
end

-- The wind at a point this frame, as the engine blows it (gusts and eddies
-- in it), or the weather's own steady value without one.
local function wind_here(o, px, py, pz)
  if wind_id and weather and weather.windAt then
    local okw, v = pcall(weather.windAt, vec3(px, py, pz))
    if okw and v then return v.x, v.y, v.z end
  end
  return o.windX, o.windY, o.windZ
end

-- ── precipitation around the camera ─────────────────────────────────────────
-- key → seconds between patches, height of the patch over the camera, fall
-- speed (to lead it upwind), and whether the ground colour tints it.
-- `light`: the patch is unlit and takes the day's light as its tint (rain
-- and snow are seen by the sky light they scatter); dust and ash are lit
-- billboards and take the ground's colour or none.
local PATCH = {
  rain = { key = "RainPatch", every = 0.12, h = 8.0, fall = 8.0, light = true },
  snow = { key = "SnowPatch", every = 0.32, h = 5.0, fall = 1.0, light = true },
  drift = { key = "SnowDrift", every = 0.3, h = 2.5, fall = 1.0, light = true },
  hail = { key = "HailPatch", every = 0.22, h = 6.0, fall = 17.0, light = true },
  dust = { key = "DustPatch", every = 0.3, h = 1.5, fall = 0, tint = true, light = true },
  ash  = { key = "AshPatch", every = 0.5, h = 5.0, fall = 0.8 },
}
local next_patch = {}
local shelter = { t = -100, on = false }
local cam_last, cam_vel = nil, { 0, 0, 0 }
local cam_fwd = { 0, 0, 0 }   -- the camera's facing, flattened onto the ground
local day_light = 1.0         -- the light rain and snow are seen by, 0..1
local spawned = 0

local astro_ref = nil
local function sheltered(x, y, z, up)
  if time - shelter.t < 0.3 then return shelter.on end
  shelter.t = time
  -- A camera chasing a craft (fast, or in the cockpit) is under no roof, and
  -- no precipitation is drawn round it anyway (particles_ok): no ray. Up
  -- there the ray crosses ground the collision has not meshed, and one cost
  -- 3 ms a frame in flight.
  local v = cam_vel
  local pc = ref("planet_camera")
  if (pc and pc.cockpit) or v[1] * v[1] + v[2] * v[2] + v[3] * v[3] > 15 * 15 then
    shelter.on = false
    return false
  end
  if not (astro_ref and astro_ref.valid) then astro_ref = find("Astronaut") end
  local a = astro_ref
  local hit = raycast and raycast(vec3(x, y, z), vec3(up[1], up[2], up[3]), 30, a and { ignore = a } or nil)
  shelter.on = hit ~= nil
  return shelter.on
end

-- Somewhere for the particles to be: not on the map, not in the cockpit, not
-- under the sea, not indoors, not flying.
local function particles_ok(o, x, y, z, b, w)
  if params.particles == false then return false end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return false end
  local pc = ref("planet_camera")
  if pc and pc.cockpit then return false end
  local cl = ref("climate")
  if cl and cl.isUnderwater and cl.isUnderwater(x, y, z) then return false end
  local alt = sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - (b.radius or 0)
  local H = (w and w.atmoHeight and w.atmoHeight > 0) and w.atmoHeight or (b.radius or 100) * 0.35
  -- Precipitation falls BELOW the cloud deck (the engine's sits at a third of
  -- the air's height).
  if alt > H * 0.4 then return false end
  local v = cam_vel
  if v[1] * v[1] + v[2] * v[2] + v[3] * v[3] > 60 * 60 then return false end
  if shelter.on then return false end
  return true
end

local dust_tint = {}
local function tint_of(name, w)
  if dust_tint[name] ~= nil then return dust_tint[name] or nil end
  local g = w and w.ground
  local t = false
  if g and g[1] then
    -- Relative to the tan the effect is authored in, part of the way.
    local r = 0.45 + 0.55 * g[1] / 0.72
    local gg = 0.45 + 0.55 * g[2] / 0.64
    local bb = 0.45 + 0.55 * g[3] / 0.54
    local m = max(r, gg, bb)
    if m > 1.25 then r, gg, bb = r * 1.25 / m, gg * 1.25 / m, bb * 1.25 / m end
    t = { r, gg, bb }
  end
  dust_tint[name] = t
  return t or nil
end

local function patch(kind, amount, o, x, y, z, w, name)
  local P = PATCH[kind]
  if amount < 0.02 then next_patch[kind] = nil; return end
  local now = time
  if next_patch[kind] and now < next_patch[kind] then return end
  next_patch[kind] = now + P.every
  local up = o.up
  -- Lead it: upwind by however far the wind carries it while it falls, and
  -- ahead of a moving camera by half the fall.
  local tf = (P.fall > 0) and (P.h + 2) / P.fall or 1.5
  local lead = tf * 0.55
  local ang = math.random() * 6.2832
  local r = sqrt(math.random()) * (params.scatter or 9)
  -- A tangent pair for the scatter: up × a helper that is not parallel to it.
  local hx, hy, hz = 0, 1, 0
  if math.abs(up[2]) > 0.9 then hx, hy, hz = 1, 0, 0 end
  local tx, ty, tz = up[2] * hz - up[3] * hy, up[3] * hx - up[1] * hz, up[1] * hy - up[2] * hx
  local tl = sqrt(tx * tx + ty * ty + tz * tz)
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local bx, by, bz = up[2] * tz - up[3] * ty, up[3] * tx - up[1] * tz, up[1] * ty - up[2] * tx
  local ca, sa = math.cos(ang), math.sin(ang)
  local ox, oy, oz = (tx * ca + bx * sa) * r, (ty * ca + by * sa) * r, (tz * ca + bz * sa) * r
  -- Most of it in front of the camera: what falls behind it is never seen.
  local fb = (params.scatter or 9) * 1.0
  local px = x + up[1] * P.h + ox - o.windX * lead + cam_vel[1] * tf * 0.5 + cam_fwd[1] * fb
  local py = y + up[2] * P.h + oy - o.windY * lead + cam_vel[2] * tf * 0.5 + cam_fwd[2] * fb
  local pz = z + up[3] * P.h + oz - o.windZ * lead + cam_vel[3] * tf * 0.5 + cam_fwd[3] * fb
  local wx, wy, wz = wind_here(o, px, py, pz)
  local opts = {
    normal = vec3(up[1], up[2], up[3]),
    vel = vec3(wx, wy, wz),
    intensity = min(2.0, amount * (params.density or 1)),
  }
  local L = P.light and day_light or 1
  local t = P.tint and tint_of(name, w)
  if t then opts.tint = { t[1] * L, t[2] * L, t[3] * L }
  elseif P.light then opts.tint = { L, L, L } end
  spawned = spawned + 1
  spawnEffect(P.key, vec3(px, py, pz), opts)
end

-- ── lightning ───────────────────────────────────────────────────────────────
local thunder = {}       -- { at, dist }
-- A strike's light over time (seconds, peak 1): a faint leader, the return
-- stroke, a steady decay, one restrike surge down the same channel and an
-- afterglow. The bolt and cloud-glow effects are authored on these same keys
-- (tools/gen_vfx.py FLASH: change both together), and so are the point light
-- and the sky here, so nothing pulses out of step with the bolt and nothing
-- strobes: the only dip is the small one before the restrike.
FLASH = { { 0.0, 0.0 }, { 0.03, 0.16 }, { 0.05, 0.2 }, { 0.067, 1.0 }, { 0.15, 0.85 }, { 0.25, 0.58 },
  { 0.31, 0.5 }, { 0.35, 0.8 }, { 0.45, 0.6 }, { 0.6, 0.3 }, { 0.8, 0.1 }, { 1.0, 0.0 } }
local function flash_at(dt)
  if dt <= 0 or dt >= FLASH[#FLASH][1] then return 0 end
  for i = 2, #FLASH do
    local b = FLASH[i]
    if dt < b[1] then
      local a = FLASH[i - 1]
      return a[2] + (b[2] - a[2]) * (dt - a[1]) / (b[1] - a[1])
    end
  end
  return 0
end
-- Live strikes' flashes ({ t0, k }); two strikes close together overlap
-- rather than the second cutting the first off.
local flashes = {}
local strike_next = nil
strikes = 0              -- published for probes
local THUNDER = { "audio/weather/thunder_1.ogg", "audio/weather/thunder_2.ogg", "audio/weather/thunder_3.ogg" }

local function strike(o, x, y, z, b, w, ahead)
  local up = o.up
  local H = (w and w.atmoHeight and w.atmoHeight > 0) and w.atmoHeight or (b.radius or 100) * 0.35
  -- Somewhere within a few horizons: on a world this size the horizon from
  -- head height is tens of metres away, and lightning is seen well past it.
  local R = b.radius or 300
  -- Near enough to be seen: on a world a few hundred metres round, a bolt
  -- more than a third of the radius away has its whole height under the
  -- horizon, and only its flash would show.
  local dist = 30 + math.random() ^ 1.5 * R * 0.35
  local ang = math.random() * 6.2832
  -- The ground point: round the planet by dist along a random bearing (or,
  -- asked for one `ahead`, the camera's).
  local ux, uy, uz, nx, ny, nz, ex, ey, ez, rc = frame(b, x, y, z)
  local th = dist / max(rc, 1)
  local dx, dy, dz = nx * math.cos(ang) + ex * math.sin(ang), ny * math.cos(ang) + ey * math.sin(ang),
    nz * math.cos(ang) + ez * math.sin(ang)
  if ahead and (cam_fwd[1] ~= 0 or cam_fwd[2] ~= 0 or cam_fwd[3] ~= 0) then
    local j = (math.random() - 0.5) * 0.5
    dx, dy, dz = cam_fwd[1] + ex * j, cam_fwd[2] + ey * j, cam_fwd[3] + ez * j
    local l = sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / l, dy / l, dz / l
  end
  local gx = ux * math.cos(th) + dx * math.sin(th)
  local gy = uy * math.cos(th) + dy * math.sin(th)
  local gz = uz * math.cos(th) + dz * math.sin(th)
  -- Cloud base: where the engine draws the deck.
  local top = R + H * 0.35
  local cx, cy, cz = b.x + gx * (b.radius + H * 0.35), b.y + gy * (b.radius + H * 0.35), b.z + gz * (b.radius + H * 0.35)
  local hit = raycast and raycast(vec3(cx, cy, cz), vec3(-gx, -gy, -gz), H * 0.35 + 200)
  local sx, sy, sz
  if hit then sx, sy, sz = hit.x, hit.y, hit.z
  else sx, sy, sz = b.x + gx * b.radius, b.y + gy * b.radius, b.z + gz * b.radius end
  local len = sqrt((cx - sx) ^ 2 + (cy - sy) ^ 2 + (cz - sz) ^ 2)
  strikes = strikes + 1
  if spawnEffect and len > 2 then
    -- No two channels alike: each leans its own way off the vertical, and
    -- each spawn throws its own jitter (the instance seeds the beam), so the
    -- channel is new every strike. The effect is 40 m tall, scaled to the
    -- cloud base; its jitter scales with it.
    local lx, ly, lz = gx + (math.random() - 0.5) * 0.45, gy + (math.random() - 0.5) * 0.45,
      gz + (math.random() - 0.5) * 0.45
    spawnEffect("Lightning", vec3(sx, sy, sz), { normal = vec3(lx, ly, lz):normalized(), scale = len / 40 })
    spawnEffect("LightningGlow", vec3(cx, cy, cz), { normal = vec3(gx, gy, gz), scale = 0.6 + len / 80 })
  end
  local fx = ref("vfx")
  if fx and fx.flash then
    fx.flash(cx * 0.5 + sx * 0.5, cy * 0.5 + sy * 0.5, cz * 0.5 + sz * 0.5, 0.75, 0.8, 1.0,
      9.0, dist * 1.3 + 40, FLASH[#FLASH][1], FLASH)
  end
  -- The sky lights up: a near strike more than a far one.
  local d = sqrt((sx - x) ^ 2 + (sy - y) ^ 2 + (sz - z) ^ 2)
  if #flashes >= 4 then table.remove(flashes, 1) end
  flashes[#flashes + 1] = { t0 = time, k = clamp01(1.0 / (1 + d / max(R * 0.3, 40))) }
  -- The thunder, late by the distance over the speed of sound in air.
  thunder[#thunder + 1] = { at = time + d / 343, dist = d }
end

-- A strike now, wherever the camera is (probes and tests; the storm makes
-- its own).
function strikeNow(ahead)
  local x, y, z = eye()
  if not x then return false end
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not (b and cur and cur.up) then return false end
  strike(cur, x, y, z, b, world_of(name), ahead)
  return true
end

-- The sky's flash now: the brightest live strike on the FLASH envelope.
local function flash_now()
  local f, i = 0, 1
  while i <= #flashes do
    local e = flashes[i]
    local dt = time - e.t0
    if dt >= FLASH[#FLASH][1] then
      table.remove(flashes, i)
    else
      f = max(f, e.k * flash_at(dt))
      i = i + 1
    end
  end
  return f
end

local function play_thunder(dt)
  local i = 1
  while i <= #thunder do
    local th = thunder[i]
    if time >= th.at then
      table.remove(thunder, i)
      if audio and audio.play then
        local d = th.dist
        local vol = 0.95 / (1 + d / 140)
        -- Distance eats the high end first: a far roll is all rumble.
        local lp = 14000 / (1 + d / 50)
        audio.play(THUNDER[math.random(1, #THUNDER)], { track = "Ambient", volume = vol, mode = "Flat",
          lowpass = lp, pitch = 0.9 + math.random() * 0.15 })
      end
    else
      i = i + 1
    end
  end
end

-- ── the driver ──────────────────────────────────────────────────────────────

function current() return cur end

function line()
  return cur and cur.label or nil
end

function start(node)
  clock = save.get("weather.clock")
  if type(clock) ~= "number" then
    -- A fresh save starts somewhere in the weather, not at spell 0 of every
    -- save alike.
    clock = ((save.get("g_seed") or 0) % 977) * 61.0
  end
  last_rails = nil
  if audio and audio.preload then audio.preload(THUNDER) end
end

local dbg_t = -100
function update(node, dt)
  dt_now = dt or 0
  -- The clock: rails time (warp brings the weather on), clamped against a
  -- rails clock that restarts with each Play.
  local rt = space.time and space.time() or nil
  local step = dt or 0
  if rt then
    if last_rails then step = rt - last_rails end
    last_rails = rt
  end
  if step < 0 or step > 3600 then step = 0 end
  clock = (clock or 0) + step
  if time - save_t > 5.0 then
    save_t = time
    save.set("weather.clock", clock)
  end

  if params.on == false then cur, sky = nil, nil; restore(); wind_off(); return end
  local x, y, z = eye()
  if not x then cur, sky = nil, nil; restore(); wind_off(); return end
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b or (b.soi or 0) < 0 then cur, sky = nil, nil; restore(); wind_off(); return end
  local w = world_of(name)

  -- The camera's velocity over the ground, to lead the patches.
  local rx, ry, rz = x - b.x, y - b.y, z - b.z
  if cam_last and cam_last.name == name and dt and dt > 0 then
    cam_vel = { (rx - cam_last.x) / dt, (ry - cam_last.y) / dt, (rz - cam_last.z) / dt }
  else
    cam_vel = { 0, 0, 0 }
  end
  cam_last = { name = name, x = rx, y = ry, z = rz }

  local o, p = compute(name, b, w, x, y, z)
  o.sheltered = shelter.on
  if wind_id then
    local wx, wy, wz = wind_here(o, x, y, z)
    o.windNow = sqrt(wx * wx + wy * wy + wz * wz)
  else
    o.windNow = o.wind
  end
  o.particles = false
  cur = o
  if o.airless and not forced then
    sky = { body = name, cover = 0, dim = 0, grey = 0, haze = 1, flash = 0 }
    restore()
    wind_off()
    return
  end

  local s = skyOf(o)
  s.body = name
  -- A dust storm's haze is the ground's colour.
  if o.kind == "dust" then
    local t = tint_of(name, w) or { 1, 1, 1 }
    s.tint = { 0.62 * t[1], 0.53 * t[2], 0.42 * t[3], s.tint[4] }
    s.cloudColor = dust_deck(w)
  end
  s.flash = flash_now()
  sky = s
  clouds_all(name, s)
  engine_wind(o, name, b, x, y, z)

  -- Under cloud the light is the sky's, not the sun's: shadows soften, and
  -- the picture darkens (a storm at noon is not a sunny noon), lit up for an
  -- instant by a flash.
  -- All of it fades with the air overhead, as the sky does: from orbit the
  -- clouds are below you and the sun is the sun.
  local at = ref("atmosphere")
  local air = (at and at.rho_now) or 1
  -- The light precipitation is seen by: the day's, under the cloud's gloom,
  -- with a floor for a moonless night (it is still faintly there).
  local sun = (at and at.sun_now) or 1
  -- Brighter than the haze behind it, or a pale streak on a pale sky is not
  -- there at all: rain and snow are seen by the light they catch and bend.
  -- The exposure falls under cloud; the particles are lifted against it, or
  -- a storm's rain would vanish into its own gloom.
  local lift = min(3.0, 2 ^ (-s.stops * 0.6 * air))
  local daylight = smooth(-0.25, 0.3, sun)
  day_light = (0.07 + 0.93 * daylight) * 1.25 * lift + 0.8 * s.flash
  if not (cam_node and cam_node.valid) then cam_node = find("Camera 1") end
  if cam_node and cam_node.valid and cam_node.worldForward then
    local f = cam_node:worldForward()
    local u = o.up
    local d = f.x * u[1] + f.y * u[2] + f.z * u[3]
    local fx, fy, fz = f.x - u[1] * d, f.y - u[2] * d, f.z - u[3] * d
    local fl = sqrt(fx * fx + fy * fy + fz * fz)
    if fl > 1e-3 then cam_fwd = { fx / fl, fy / fl, fz / fl } else cam_fwd = { 0, 0, 0 } end
  end
  local l, pp = light_and_post()
  if l and base_shadow then
    l.shadowStrength = base_shadow * (1 - 0.8 * smooth(0.5, 0.98, o.cover) * air)
  end
  if l and base_amb then
    local a = s.amb * air * daylight
    l.ambientR, l.ambientG, l.ambientB = base_amb[1] + a * 0.85, base_amb[2] + a * 0.9, base_amb[3] + a
  end
  star_light(1 - (1 - s.sun) * air)
  if pp and base_exposure then
    pp.exposure = base_exposure + ((params.gloom or 1.0) * s.stops + 1.0 * s.flash) * air
  end

  -- Precipitation. A roof overhead (a ray straight up, a few times a
  -- second) means indoors, or under a ledge: nothing falls there, and the
  -- soundscape muffles the rain.
  if o.precip > 0.02 then sheltered(x, y, z, o.up) else shelter.on = false end
  o.sheltered = shelter.on
  local ok = particles_ok(o, x, y, z, b, w)
  o.particles = ok
  if ok then
    local amt = o.precip
    if o.kind == "dust" then
      patch("dust", amt * (0.5 + 0.5 * o.storm), o, x, y, z, w, name)
    elseif o.kind == "ash" then
      patch("ash", amt, o, x, y, z, w, name)
    else
      patch("rain", amt * (1 - o.snow) * (1 - 0.5 * o.hail), o, x, y, z, w, name)
      patch("snow", amt * o.snow, o, x, y, z, w, name)
      patch("drift", o.snow * smooth(0.25, 0.8, o.storm), o, x, y, z, w, name)
      patch("hail", o.hail, o, x, y, z, w, name)
    end
  end

  -- Lightning: a Poisson process at the storm's rate.
  if params.lightning ~= false and (o.lightning or 0) > 0.2 then
    local rate = (params.strikeRate or 6) / 60 * o.lightning
    if not strike_next then strike_next = time + (-math.log(1 - math.random() * 0.999)) / rate end
    if time >= strike_next then
      strike(o, x, y, z, b, w)
      strike_next = time + (-math.log(1 - math.random() * 0.999)) / rate
    end
  else
    strike_next = nil
  end
  play_thunder(dt)

  if params.debug and time - dbg_t > 3.0 then
    dbg_t = time
    print(string.format("weather: %s %s/%s I %.2f precip %.2f storm %.2f cover %.2f snow %.2f wind %.1f m/s from %.0f° %s",
      name, o.type, o.state, o.intensity, o.precip, o.storm, o.cover, o.snow, o.wind, o.windFrom,
      ok and "particles" or "-"))
  end
end

-- What the weather costs, for probes.
function stats()
  return { spawned = spawned, strikes = strikes, clock = clock }
end

function onDestroy(node)
  restore()
  wind_off()
end
