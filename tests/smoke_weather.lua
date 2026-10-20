-- SMOKE HARNESS: weather.lua — each world's weather, from its climate.
--
-- What is held here:
--
--   * the climate picks the weather: a warm wet world rains and storms, a
--     cold one snows, a desert raises dust, a molten one drops ash, and a
--     world with no air has none at all — and over many spells each gets
--     its share in sensible proportion
--   * the state machine goes clear → overcast → precipitation → storm →
--     clearing, and every change is smooth: the intensity never steps, and a
--     front takes minutes to build
--   * it is a pure function of seed and clock: the same world twice is the
--     same weather, and a save loaded again carries on where it was
--   * snow or rain is decided by the temperature where you stand
--   * the scene: the cloud deck follows the weather (setCelestial), the sky
--     table atmosphere.lua reads darkens with it, shadows soften and the
--     exposure falls, precipitation patches are fired around the camera with
--     the wind as their velocity — and none indoors, in the cockpit, under
--     the sea, on the map, or above the clouds
--   * lightning: a bolt and a flash, and the thunder arriving late by the
--     distance over the speed of sound (played into a stub: tests are silent)
--   * the wind is exposed as a speed, a compass direction and a vector, and
--     declared to the engine (weather.addWind) as a cell round the camera in
--     the world's frame, its gusts growing with the storm
--   * the deck darkens and greys with the weather (cloudDarkness/cloudColor)
--   * it is cheap: a frame of the script costs well under a tenth of a ms
--
--   luajit solar/tests/smoke_weather.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine stand-ins ────────────────────────────────────────────────────────
local T = 0.0
local RAILS = 0.0
math.randomseed(7)

local vec3mt = {}
vec3mt.__index = vec3mt
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vec3mt) end
function vec3mt:normalized()
  local l = math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2)
  return vec3(self.x / l, self.y / l, self.z / l)
end

local store = {}
local save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
}

-- Worlds: a warm wet canyon world with a sea, a dune desert, an ice world, a
-- lava world and an airless moon; and their star.
local bodies = {
  Sol = { name = "Sol", x = 0, y = 90000, z = 0, radius = 300, mu = 1e9, soi = -1 },
  Verd = { name = "Verd", x = 0, y = 0, z = 0, radius = 300, mu = 1e5, soi = 3000 },
  Sand = { name = "Sand", x = 20000, y = 0, z = 0, radius = 320, mu = 1e5, soi = 3000 },
  Rime = { name = "Rime", x = 40000, y = 0, z = 0, radius = 280, mu = 1e5, soi = 3000 },
  Pyre = { name = "Pyre", x = 60000, y = 0, z = 0, radius = 340, mu = 1e5, soi = 3000 },
  Husk = { name = "Husk", x = 80000, y = 0, z = 0, radius = 100, mu = 4e4, soi = 1500 },
}
store["g_seed"] = 4242
store["world.Verd"] = { name = "Verd", kind = "canyon", seed = 11, radius = 300, atmo = 0.75, atmoHeight = 100,
                        sea = 290, insol = 1.0, atmoR = 0.4, atmoG = 0.6, atmoB = 0.85 }
store["world.Sand"] = { name = "Sand", kind = "dune", seed = 22, radius = 320, atmo = 0.7, atmoHeight = 110,
                        sea = 0, insol = 1.3, ground = { 0.8, 0.62, 0.45 } }
store["world.Rime"] = { name = "Rime", kind = "ice", seed = 33, radius = 280, atmo = 0.6, atmoHeight = 90,
                        sea = 0, insol = 0.8 }
store["world.Pyre"] = { name = "Pyre", kind = "lava", seed = 44, radius = 340, atmo = 0.8, atmoHeight = 120,
                        sea = 0, insol = 1.5 }
store["world.Husk"] = { name = "Husk", kind = "barren", seed = 55, radius = 100, atmo = 0, sea = 0, insol = 1 }

local function dominant(x, y, z)
  for _, n in ipairs({ "Verd", "Sand", "Rime", "Pyre", "Husk" }) do
    local b = bodies[n]
    if math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) < b.soi then return n end
  end
  return "Sol"
end

-- Nodes: each body records the setCelestial calls it gets.
local celestial = {}
local function body_node(name)
  -- toLocal: the world's frame is its position, unrotated, in this stand-in.
  return { valid = true, toLocal = function(_, v)
    local b = bodies[name]
    return vec3(v.x - b.x, v.y - b.y, v.z - b.z)
  end, setCelestial = function(_, t)
    celestial[name] = celestial[name] or {}
    for k, v in pairs(t) do celestial[name][k] = v end
    celestial[name].calls = (celestial[name].calls or 0) + 1
  end }
end
local nodes = {}
for n in pairs(bodies) do nodes[n] = body_node(n) end
local light = { shadowStrength = 1.0, ambientR = 0.012, ambientG = 0.012, ambientB = 0.018 }
store["system.home"] = { star = "Sol" }
nodes.Sol.material = function() return { color = { r = 1.0, g = 0.9, b = 0.7 } } end
local postc = { exposure = 0.0 }
nodes.Lighting = { valid = true, getcomponent = function(_, k) if k == "Light" then return light end end }
nodes["Post Processing"] = { valid = true, getcomponent = function(_, k) if k == "PostProcess" then return postc end end }
nodes.Astronaut = { valid = true, x = 0, y = 0, z = 0 }
local fwd = vec3(0, 0, -1)
nodes["Camera 1"] = { valid = true, x = 0, y = 0, z = 0, worldForward = function() return fwd end }

-- Scripts the weather reads.
local cam = { valid = true, cam_x = 0, cam_y = 302, cam_z = 0, cockpit = false }
local map_open = false
local orbit_map = { valid = true, isOpen = function() return map_open end }
local underwater = false
local temp_here = nil       -- nil: the world's own
local climate = { valid = true,
  sampleAt = function(name, x, y, z) return temp_here and { temp = temp_here } or nil end,
  isUnderwater = function() return underwater end }
local atmosphere = { valid = true, rho_now = 1.0, sun_now = 0.8 }
local flashes = {}
local vfx = { valid = true, flash = function(...) flashes[#flashes + 1] = { ... } end }
local SCRIPTS = { planet_camera = cam, orbit_map = orbit_map, climate = climate, atmosphere = atmosphere, vfx = vfx }

local effects = {}
local roof = false
-- The engine's wind: what was declared, and windAt answering it back.
local winds, wind_n = {}, 0
local weather_api = {
  addWind = function(o)
    wind_n = wind_n + 1
    local w = {}
    for k, v in pairs(o) do w[k] = v end
    winds[wind_n] = w
    return wind_n
  end,
  setWind = function(id, o)
    if not winds[id] then return false end
    for k, v in pairs(o) do winds[id][k] = v end
    return true
  end,
  removeWind = function(id) local had = winds[id] ~= nil; winds[id] = nil; return had end,
  windAt = function(p)
    local x, y, z = 0, 0, 0
    for _, w in pairs(winds) do x, y, z = x + w.velocity.x, y + w.velocity.y, z + w.velocity.z end
    return vec3(x, y, z)
  end,
}
local sounds = {}
local API = {
  vec3 = vec3,
  save = save,
  find = function(name) return nodes[name] end,
  findScript = function(kind) return SCRIPTS[kind] end,
  weather = weather_api,
  spawnEffect = function(key, pos, opts) effects[#effects + 1] = { key = key, pos = pos, opts = opts, t = T } end,
  raycast = function(o, d, max)
    -- A roof 4 m over the eye when asked for; the ground (a sphere) otherwise.
    if roof and d.y > 0.5 then return { x = o.x, y = o.y + 4, z = o.z } end
    return nil
  end,
  audio = { play = function(clip, opts) sounds[#sounds + 1] = { clip = clip, opts = opts, t = T } end,
            preload = function() end },
  space = {
    dominant = dominant,
    body = function(n) return bodies[n] end,
    bodies = function() return { bodies.Sol, bodies.Verd, bodies.Sand, bodies.Rime, bodies.Pyre, bodies.Husk } end,
    time = function() return RAILS end,
  },
}
local function load()
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile("solar/scripts/weather.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults) do env.params[k] = v end
  return env
end
local W = load()

-- ── 1. the climate picks the weather ────────────────────────────────────────
local P = {}
for _, n in ipairs({ "Verd", "Sand", "Rime", "Pyre", "Husk" }) do P[n] = W.profile(store["world." .. n]) end
ok(P.Husk.airless, "a world with no air has no weather")
ok(P.Pyre.ash, "a molten world's fronts are ash")
ok(P.Sand.dust > P.Sand.wet, "a desert raises more dust than it rains")
ok(P.Verd.wet > P.Sand.wet and P.Verd.wet > 0.4, "a warm world with a sea is the wettest")
ok(P.Verd.storm > P.Rime.storm, "...and the stormiest (convection wants heat and moisture)")
ok(P.Verd.hail > 0, "a temperate world's thunderstorms can drop hail")

-- Tally a long run of each world's weather, a sample a minute.
local function tally(name, hours)
  local w = store["world." .. name]
  local p = W.profile(w)
  local seed = (w.seed + 4242 * 31) % 1000003
  local n, types, states = 0, {}, {}
  for t = 0, hours * 3600, 60 do
    local I, trend, kind, hail = W.at(seed, p, t, 360)
    local o = W.derive(p, I, trend, kind, hail, p.temp)
    types[o.type] = (types[o.type] or 0) + 1
    states[o.state] = (states[o.state] or 0) + 1
    n = n + 1
  end
  for k, v in pairs(types) do types[k] = v / n end
  for k, v in pairs(states) do states[k] = v / n end
  return types, states
end
local tv, sv = tally("Verd", 200)
local ts = tally("Sand", 200)
local tr = tally("Rime", 200)
local tp = tally("Pyre", 200)
local th = tally("Husk", 20)
local wet_v = (tv.rain or 0) + (tv.thunderstorm or 0) + (tv.hail or 0)
ok(wet_v > 0.12 and wet_v < 0.6, string.format("the wet world rains a believable share of the time (%.2f)", wet_v))
ok((tv.thunderstorm or 0) + (tv.hail or 0) > 0.02, "...with thunderstorms among it")
ok((tv.clear or 0) > 0.15, string.format("...and clear spells too (%.2f)", tv.clear or 0))
ok((tv.snow or 0) == 0, "a warm world does not snow")
ok((ts.dust or 0) + (ts.duststorm or 0) > 0.1, "the desert has dust storms")
ok((ts.dust or 0) + (ts.duststorm or 0) > 2 * ((ts.rain or 0) + (ts.thunderstorm or 0)), "...far more than rain")
ok((tr.snow or 0) + (tr.blizzard or 0) > 0.1, "the ice world snows")
ok((tr.rain or 0) == 0, "...and never rains")
ok((tp.ash or 0) + (tp.ashstorm or 0) > 0.1, "the lava world drops ash")
ok((th.none or 0) == 1, "the airless moon: nothing, ever")
for _, s in ipairs({ "clear", "overcast", "precipitation", "storm", "clearing" }) do
  ok((sv[s] or 0) > 0.01, "the wet world passes through '" .. s .. "'")
end

-- ── 2. smooth, minutes-long, and in order ───────────────────────────────────
local wv = store["world.Verd"]
local pv = W.profile(wv)
local seedv = (wv.seed + 4242 * 31) % 1000003
local prev, maxstep = nil, 0
local built = nil
local order_ok, last_state, seen = true, nil, {}
local RANK = { clear = 0, overcast = 1, precipitation = 2, storm = 3 }
for t = 0, 40 * 3600, 1 do
  local I, trend, kind, hail = W.at(seedv, pv, t, 360)
  if prev then maxstep = math.max(maxstep, math.abs(I - prev)) end
  prev = I
  local o = W.derive(pv, I, trend, kind, hail, pv.temp)
  if last_state and o.state ~= last_state then
    -- Building, a state only ever moves one rung at a time.
    local a, b = RANK[last_state], RANK[o.state]
    if a and b and math.abs(a - b) > 1 then order_ok = false end
    seen[last_state .. ">" .. o.state] = true
  end
  last_state = o.state
end
ok(maxstep < 0.01, string.format("the intensity never steps (largest change in a second %.4f)", maxstep))
ok(order_ok, "the state climbs and falls one rung at a time (no clear → storm)")
ok(seen["clear>overcast"] and seen["overcast>precipitation"] and seen["precipitation>storm"],
  "the build-up goes clear → overcast → precipitation → storm")
ok(seen["storm>clearing"] or seen["storm>precipitation"], "...and a storm passes")
ok(seen["clearing>clear"], "...through clearing back to clear")
-- How long a front takes to build: from the first rain to the storm's peak
-- is minutes, not seconds.
local min_build = math.huge
do
  local start_t, was_low = nil, false
  for t = 0, 40 * 3600, 2 do
    local I = W.at(seedv, pv, t, 360)
    if I > 0.45 and not start_t and was_low then start_t = t end
    if I < 0.3 then start_t, was_low = nil, true end
    if start_t and I > 0.9 then min_build = math.min(min_build, t - start_t); start_t, was_low = nil, false end
  end
end
ok(min_build > 60, string.format("a storm takes minutes to build from the first rain (fastest %.0f s)", min_build))

-- ── 3. deterministic: the same seed and clock is the same weather ───────────
local a1 = { W.at(seedv, pv, 12345.6, 360) }
local a2 = { W.at(seedv, pv, 12345.6, 360) }
ok(a1[1] == a2[1] and a1[3] == a2[3], "same seed, same clock, same weather")
local diff = 0
for t = 0, 36000, 600 do
  if math.abs(W.at(seedv, pv, t, 360) - W.at(seedv + 1, pv, t, 360)) > 0.05 then diff = diff + 1 end
end
ok(diff > 10, "another world (seed) has its own weather")

-- ── 4. snow or rain, by the ground's temperature ────────────────────────────
local o_warm = W.derive(pv, 0.62, 1, "wet", false, 0.6)
local o_cold = W.derive(pv, 0.62, 1, "wet", false, 0.3)
local o_mid = W.derive(pv, 0.62, 1, "wet", false, W.FREEZE)
ok(o_warm.type == "rain" and o_warm.snow == 0, "above freezing it rains")
ok(o_cold.type == "snow" and o_cold.snow == 1, "below freezing it snows")
ok(o_mid.snow > 0 and o_mid.snow < 1, "...and at freezing it sleets (both, in part)")
ok(W.derive(pv, 0.96, 1, "wet", false, 0.3).type == "blizzard", "a cold storm is a blizzard")
ok(W.derive(pv, 0.96, 1, "wet", false, 0.6).type == "thunderstorm", "a warm one a thunderstorm")
ok(W.derive(pv, 0.96, 1, "wet", true, 0.55).type == "hail", "...that can hail")

-- ── 5. the scene ────────────────────────────────────────────────────────────
W.start({})
local function frames(n, dt)
  dt = dt or 1 / 60
  for _ = 1, n do
    T = T + dt
    RAILS = RAILS + dt
    W.update({}, dt)
  end
end
frames(30)
local c = W.current()
ok(c and c.body == "Verd", "on the wet world, current() answers for it")
ok(c and type(c.wind) == "number" and c.windFrom >= 0 and c.windFrom < 360, "the wind is a speed and a compass bearing")
ok(c and c.windX and math.abs(c.windX * 0 + c.windY * 1 + c.windZ * 0) < 1e-6,
  "...and a vector along the ground (no vertical part at the pole)")
ok(c and math.abs(math.sqrt(c.windX ^ 2 + c.windY ^ 2 + c.windZ ^ 2) - c.wind) < 1e-6, "...of that speed")
ok(type(W.line()) == "string" and W.line():find("wind"), "line() is a readout for the HUD: " .. tostring(W.line()))
ok(celestial.Verd and celestial.Verd.clouds ~= nil, "the cloud deck is set on the world")
ok(celestial.Sand and celestial.Sand.clouds ~= nil, "...and on the other worlds with air")
ok(not (celestial.Husk and celestial.Husk.clouds), "...but not on the airless one")
local function the_wind()
  local id, w = next(winds)
  return w, id
end
local wd = the_wind()
ok(wd and wd.parent == "Verd" and wd.radius and wd.radius >= 40 and wd.center,
  "the wind is declared to the engine: a cell round the camera, in the world's frame")
ok(wd and math.abs(wd.velocity.x - c.windX) + math.abs(wd.velocity.y - c.windY) + math.abs(wd.velocity.z - c.windZ) < 0.3,
  "...blowing the weather's own wind")
ok(wd and math.abs(wd.center.y - 302) < 1e-6, "...centred on the camera")
ok(c and math.abs(c.windNow - c.wind) < 0.2, "current().windNow is the engine's wind at the camera")
local calm_gust = wd and wd.gust or 0
local clear_dark = celestial.Verd and celestial.Verd.cloudDarkness or 1

-- Force a thunderstorm: clouds close, the sky darkens, the exposure falls,
-- shadows soften, rain falls around the camera with the wind.
W.force("thunderstorm", 1)
effects = {}
frames(240)
c = W.current()
ok(c.type == "thunderstorm" and c.state == "storm", "forced: a thunderstorm (" .. c.type .. ")")
ok(celestial.Verd.clouds > 0.95, "overcast: the deck is closed (" .. celestial.Verd.clouds .. ")")
ok(W.sky and W.sky.body == "Verd" and W.sky.dim > 0.5 and W.sky.grey > 0.5 and W.sky.haze > 2,
  "the sky table atmosphere.lua reads is dark, grey and hazy")
ok(postc.exposure < -1.5, "a thunderstorm is DARK: well over a stop down (exposure " .. postc.exposure .. ")")
ok(celestial.Sol and celestial.Sol.starColor and celestial.Sol.starColor[1] < 0.2,
  "...the sun's direct light is mostly gone behind the deck")
ok(light.ambientB > 0.1, "...and the diffuse sky light fills in")
local storm_stops = W.skyOf(W.derive(pv, 0.96, 1, "wet", false, 0.6)).stops
local rain_stops = W.skyOf(W.derive(pv, 0.62, 1, "wet", false, 0.6)).stops
local oc_stops = W.skyOf(W.derive(pv, 0.36, 1, "wet", false, 0.6)).stops
local bl_stops = W.skyOf(W.derive(pv, 0.96, 1, "wet", false, 0.2)).stops
ok(oc_stops < 0 and rain_stops < oc_stops and storm_stops < rain_stops,
  string.format("gloom grows with the weather: overcast %.2f, rain %.2f, storm %.2f stops", oc_stops, rain_stops, storm_stops))
ok(bl_stops > storm_stops, "a blizzard is a white-out, not as dark as a thunderstorm")
ok(light.shadowStrength < 0.4, "the sun's shadows soften under cloud (" .. light.shadowStrength .. ")")
ok(celestial.Verd.cloudDarkness and celestial.Verd.cloudDarkness > 0.8 and celestial.Verd.cloudDarkness > clear_dark,
  string.format("a thunderhead is dark from below (cloudDarkness %.2f, %.2f before)", celestial.Verd.cloudDarkness or -1, clear_dark))
local cc = celestial.Verd.cloudColor
ok(cc and cc[1] < 0.85 and cc[3] > cc[1], "...and a heavy blue-grey (cloudColor)")
local sk_snow = W.skyOf(W.derive(pv, 0.96, 1, "wet", false, 0.2))
local sk_storm = W.skyOf(W.derive(pv, 0.96, 1, "wet", false, 0.6))
ok(sk_snow.cloudDark < sk_storm.cloudDark and sk_snow.cloudColor[1] > sk_storm.cloudColor[1],
  "a blizzard's deck is lighter than a thunderstorm's")
local ws = the_wind()
ok(ws and ws.gust > calm_gust and ws.turbulence > 0.2, "the storm's wind gusts harder (gust " .. tostring(ws and ws.gust) .. ")")
local nwinds = 0
for _ in pairs(winds) do nwinds = nwinds + 1 end
ok(nwinds == 1, "...one wind, updated, not one per frame (" .. nwinds .. ")")
local rain = 0
local lead_ok, last = true, nil
for _, e in ipairs(effects) do
  if e.key == "RainPatch" then
    rain = rain + 1
    if not (e.pos.y > 302 + 4) then lead_ok = false end
    last = e
  end
end
-- (The wind rose as the storm was forced in; the latest patch has today's.)
local v = last and last.opts.vel
if not v or math.abs(v.x - c.windX) + math.abs(v.y - c.windY) + math.abs(v.z - c.windZ) > 0.2 then lead_ok = false end
ok(rain >= 20 and rain < 60, "rain patches are fired around the camera, a few a second (" .. rain .. " in 4 s)")
ok(lead_ok, "...over the camera, carried by the wind (the patch's velocity is the wind)")

-- Lightning, and the thunder after it.
sounds, flashes = {}, {}
local strikes0 = W.strikes
for _ = 1, 60 * 90 do
  T = T + 1 / 60; RAILS = RAILS + 1 / 60
  W.update({}, 1 / 60)
end
local ns = W.strikes - strikes0
ok(ns >= 3 and ns <= 25, "a storm throws lightning, a few a minute (" .. ns .. " strikes in 90 s)")
ok(#flashes >= 1, "...each a flash of real light")
local thunder = 0
for _, s in ipairs(sounds) do if s.clip:find("thunder") then thunder = thunder + 1 end end
ok(thunder >= 1, "...and thunder (into a stub — the harness is silent)")
-- The delay: strike now, ahead of the camera, and time the thunder.
sounds = {}
local t0 = T
ok(W.strikeNow(true), "strikeNow() for probes")
local heard = nil
for _ = 1, 60 * 3 do
  T = T + 1 / 60; RAILS = RAILS + 1 / 60
  W.update({}, 1 / 60)
  for _, s in ipairs(sounds) do if s.clip:find("thunder") and not heard then heard = s.t end end
end
ok(heard and heard - t0 > 0.05 and heard - t0 < 1.0,
  "the thunder comes late, by distance over 343 m/s (" .. tostring(heard and (heard - t0)) .. " s)")
ok(W.sky.flash ~= nil, "the flash is published for the haze")

-- No precipitation where there should be none.
local function rained(setup, undo)
  setup()
  frames(30)           -- the roof ray is cast a few times a second
  effects = {}
  frames(120)
  local n = 0
  for _, e in ipairs(effects) do if e.key:find("Patch") then n = n + 1 end end
  undo()
  return n
end
ok(rained(function() roof = true end, function() roof = false end) == 0, "indoors (a roof overhead): no rain")
ok(rained(function() cam.cockpit = true end, function() cam.cockpit = false end) == 0, "in the cockpit: none")
ok(rained(function() map_open = true end, function() map_open = false end) == 0, "on the orbit map: none")
ok(rained(function() underwater = true end, function() underwater = false end) == 0, "under the sea: none")
ok(rained(function() cam.cam_y = 300 + 100 end, function() cam.cam_y = 302 end) == 0, "above the cloud deck: none")
ok(rained(function() end, function() end) > 0, "...and back in the open, it rains again")
roof = true; frames(30)
ok(W.current().sheltered == true, "current().sheltered says a roof is overhead (the soundscape muffles)")
roof = false; frames(30)

-- Snow where it is cold, dust on the desert, ash on the lava world.
W.force("snow", 1); effects = {}; frames(120)
local kinds = {}
for _, e in ipairs(effects) do kinds[e.key] = true end
ok(kinds.SnowPatch and not kinds.RainPatch, "forced snow: snow patches, no rain")
W.force("hail", 1); effects = {}; frames(120)
kinds = {}
for _, e in ipairs(effects) do kinds[e.key] = true end
ok(kinds.HailPatch, "forced hail: hail patches")
W.force(nil)
-- Natural weather on the desert: force-free, go there and look at the tint.
cam.cam_x, cam.cam_y, cam.cam_z = 20000, 322, 0
W.force("duststorm", 1); effects = {}; frames(120)
local dust = nil
for _, e in ipairs(effects) do if e.key == "DustPatch" then dust = e end end
ok(dust and dust.opts.tint and dust.opts.tint[1] > dust.opts.tint[3], "dust is tinted to the desert's ground")
ok(W.sky.tint and W.sky.tint[4] > 0.5, "...and the haze takes the dust's colour")
W.force(nil)

-- The airless moon: nothing at all, and the light is put back.
cam.cam_x, cam.cam_y, cam.cam_z = 80000, 102, 0
effects = {}
frames(120)
c = W.current()
ok(c and c.type == "none" and c.airless, "on the airless moon the weather is 'none'")
ok(#effects == 0, "...nothing falls")
ok(postc.exposure == 0 and light.shadowStrength == 1.0 and light.ambientR == 0.012,
  "...and the exposure, shadows and ambient are the scene's own again")
ok(celestial.Sol.starColor[1] == 1.0, "...and the sun its own colour")

-- ── 6. save and load ────────────────────────────────────────────────────────
cam.cam_x, cam.cam_y, cam.cam_z = 0, 302, 0
frames(400)          -- past a save tick
local clock_saved = store["weather.clock"]
ok(type(clock_saved) == "number" and clock_saved > 0, "the weather clock is saved (" .. tostring(clock_saved) .. ")")
local before = W.current()
local W2 = load()      -- a fresh load of the script, the rails clock restarted
RAILS = 0
W2.start({})
W2.update({}, 0)
local after = W2.current()
local Ia = W.at(seedv, pv, clock_saved, 360)
ok(after and math.abs(after.intensity - Ia) < 1e-9, "a loaded save carries on from the saved clock")
ok(after and after.type == W.derive(pv, Ia, 1, select(3, W.at(seedv, pv, clock_saved, 360)), false, pv.temp).type
  or false, "...with the same weather")

-- The bolt from the engine's lightning geometry (weather.bolt): drawn as
-- ribbons for the flash's span, instead of the Lightning beam effect.
local quads = 0
weather_api.bolt = function(from, to, o)
  return { { points = { from.x, from.y, from.z, (from.x + to.x) / 2 + 1, (from.y + to.y) / 2, (from.z + to.z) / 2,
                        to.x, to.y, to.z }, width = 1 },
           { points = { from.x, from.y + 5, from.z, from.x + 3, from.y + 9, from.z }, width = 0.5, parent = 1 } }
end
API.draw = { quad = function() quads = quads + 1 end }
effects = {}
ok(W.strikeNow(true), "a strike with the engine's bolt")
W.lateUpdate({}, 1 / 60)
local beam = 0
for _, e in ipairs(effects) do if e.key == "Lightning" then beam = beam + 1 end end
ok(quads == 2 * (2 + 1), "...draws its channel and fork as ribbons, a core and a glow (" .. quads .. " quads)")
ok(beam == 0, "...instead of the Lightning beam effect")
quads = 0
for _ = 1, 30 do T = T + 1 / 60; W.lateUpdate({}, 1 / 60) end
quads = 0
W.lateUpdate({}, 1 / 60)
ok(quads == 0, "...and is gone once the flash is over")
API.draw, weather_api.bolt = nil, nil

-- ── 7. cheap ────────────────────────────────────────────────────────────────
W.force("thunderstorm", 1)
local c0 = os.clock()
frames(600)
local per = (os.clock() - c0) / 600 * 1000
ok(per < 0.1, string.format("a frame of weather costs %.4f ms of script (in a storm, stubbed engine)", per))
print(string.format("  (weather.lua: %.4f ms a frame in a storm)", per))

if #failures == 0 then
  print(string.format("WEATHER SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("WEATHER SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
