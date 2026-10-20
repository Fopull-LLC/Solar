-- SOUNDSCAPE — the air you are standing in, and now and then some music.
--
-- There was neither. The Ambient bus in project.ron had an EQ on it and nothing
-- playing through it, and there was no music at all, so a world with a thick
-- blue sky sounded exactly like an airless moon: footsteps on silence.
--
-- AMBIENCE follows the same air atmosphere.lua draws (`save.world.<name>`: how
-- much air the world has, how high it goes), at the camera:
--
--   * vacuum                nothing. An airless world is silent, and that
--                           silence is the difference you should hear
--   * in the air            a wind bed scaled by the density there, with
--                           whistling gusts on the thick worlds, louder the
--                           faster you move through it
--   * in the sea            the wind drops away under the surface and an
--                           underwater bed comes up; the music is muffled
--   * in weather            (weather.lua's current()) rain — a light shower
--                           or a downpour — hail, or a dust storm, and the
--                           wind rising with the weather's; muffled when a
--                           roof is over you. Thunder is weather.lua's own:
--                           it has to land late by the strike's distance
--
-- MUSIC is sparse on purpose. Three calm pieces (tools/gen_soundscape_audio.py)
-- with minutes of silence between them, each faded in and out in its own file.
-- It never starts during loading, ducks under a burning engine (rockets are
-- loud and the music is not the point then), dips while paused, and gets out
-- of the way entirely when a vessel is lost.
--
-- Both scale by the player's sliders (settings.lua): Ambient through its bus
-- fader, Music on the voice — see settings.lua for why.
--
-- Cross-script:
--   local ss = findScript("soundscape")
--   ss.hush(seconds)      music out now, nothing new for a while (a sting)
--   ss.air                the air amount at the camera, 0..1 (published)
--   ss.underwater         is the camera under a sea (published)
--   ss.musicPlaying       the piece playing, or nil (published)

defaults = {
  --- 1 on the main menu: music starts almost at once and the gaps are short.
  --@range 0 1
  menu = 0,
  --- Seconds of quiet after a world loads before the first piece.
  --@range 0 600
  firstDelay = 75.0,
  --- Quiet between pieces, seconds (a random span between the two).
  --@range 10 1200
  gapMin = 240.0,
  --@range 10 1200
  gapMax = 480.0,
  --- Music voice level before the player's slider.
  --@range 0 1
  musicGain = 0.85,
  --- Ambience voice levels before the Ambient bus.
  --@range 0 1
  windGain = 0.6,
  --@range 0 1
  gustGain = 0.45,
  --@range 0 1
  underwaterGain = 0.55,
  --- Weather beds (weather.lua): rain, hail, a dust storm.
  --@range 0 1
  rainGain = 0.55,
  --@range 0 1
  hailGain = 0.5,
  --@range 0 1
  dustGain = 0.6,
  --- Print the mix once every few seconds (for tuning under `floptle run`).
  debug = false,
}

local PIECES = {
  { clip = "audio/music/drift.ogg",     len = 124.2 },
  { clip = "audio/music/far_shore.ogg", len = 116.2 },
  { clip = "audio/music/low_orbit.ogg", len = 140.2 },
}
local WIND = "audio/ambience/wind_low.ogg"
local GUST = "audio/ambience/wind_gust.ogg"
local SEA = "audio/ambience/underwater.ogg"
local RAIN_L = "audio/weather/rain_light.ogg"
local RAIN_H = "audio/weather/rain_heavy.ogg"
local HAIL = "audio/weather/hail.ogg"
local DUST = "audio/weather/dust.ogg"

air, underwater, musicPlaying = 0.0, false, nil

local clock = 0.0
local music, music_i, music_t0, music_len = nil, nil, 0, 0
local music_gain = 0.0          -- eased voice volume
local next_at = nil
local hush_until = -1
local order, order_i = {}, 0
local loops = {}                -- name → { h = handle, v = eased volume, quiet = secs, lp = lowpass }
local dbg_t = 0
local lp_music = 0

local refs, missed = {}, {}
-- On the main menu there is no world, no crew and no flight, and asking for
-- their scripts would only put "found nothing" lines in the Console.
local WORLD_ONLY = { planet_camera = true, climate = true, game_manager = true,
                     pause_menu = true, orbit_map = true, weather = true }
local function ref(kind)
  if WORLD_ONLY[kind] and (tonumber(params.menu) or 0) >= 0.5 then return nil end
  local r = refs[kind]
  if r and r.valid then return r end
  if missed[kind] and clock - missed[kind] < 2.0 then return nil end
  r = findScript and findScript(kind) or nil
  refs[kind], missed[kind] = r, (r == nil) and clock or nil
  return r
end

local function smooth01(e0, e1, x)
  local t = math.max(0, math.min(1, (x - e0) / (e1 - e0)))
  return t * t * (3 - 2 * t)
end

-- ── the air (atmosphere.lua's rule, at the camera) ──────────────────────────

local function eye()
  local pc = ref("planet_camera")
  if pc and pc.cam_x then return pc.cam_x, pc.cam_y, pc.cam_z end
  return nil
end

local last_rel, speed = nil, 0.0
local held = { atmo = 0, spd = 0 }
local function air_at(x, y, z, dt)
  if not (space and space.dominant) then return 0, 0, 0 end
  local dom = space.dominant(x, y, z)
  local b = dom and space.body(dom)
  if not b then last_rel = nil; return 0, 0, 0 end
  -- Speed through the air is speed relative to the body: the planet itself
  -- is on rails at ~90 m/s, which is not a wind.
  local rx, ry, rz = x - b.x, y - b.y, z - b.z
  if last_rel and last_rel.dom == dom and dt > 0 then
    local dx, dy, dz = rx - last_rel.x, ry - last_rel.y, rz - last_rel.z
    local v = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
    if v < 2000 then speed = speed + (v - speed) * math.min(1, dt * 3) end
  end
  last_rel = { dom = dom, x = rx, y = ry, z = rz }
  local w = save and save.get and save.get("world." .. dom)
  if not (w and (w.atmo or 0) > 0.01) then return 0, 0, 0 end
  local alt = math.sqrt(rx * rx + ry * ry + rz * rz) - (b.radius or 1)
  local h = (w.atmoHeight or 0)
  if h <= 0 then h = (b.radius or 100) * 0.35 end
  h = h * 1.6
  local t = 1.0 - math.max(0.0, math.min(1.0, alt / h))
  local amt = t * t * math.max(0.0, math.min(1.0, w.atmo or 0))
  return amt, (w.atmo or 0), speed
end

-- ── loops ───────────────────────────────────────────────────────────────────

local function loop_to(name, clip, want, lowpass, dt)
  local L = loops[name]
  if not L then L = { v = 0, quiet = 0, lp = 0 }; loops[name] = L end
  L.v = L.v + (want - L.v) * math.min(1, dt * 1.2)
  if L.v > 0.004 then
    L.quiet = 0
    if not L.h then
      L.h = audio.play(clip, { track = "Ambient", loop = true, volume = 0, mode = "Flat" })
      L.sent, L.lp = nil, 0
    end
  else
    L.quiet = L.quiet + dt
    if L.h and L.quiet > 3.0 then L.h:stop(); L.h = nil end
  end
  if L.h then
    if not L.sent or math.abs(L.sent - L.v) > 0.003 then L.h:setVolume(L.v); L.sent = L.v end
    if (lowpass or 0) ~= L.lp then L.lp = lowpass or 0; L.h:setLowpass(L.lp) end
  end
end

-- ── music ───────────────────────────────────────────────────────────────────

local function next_piece()
  if order_i >= #order then
    -- A fresh shuffle, never starting with the piece that just played.
    local prev = order[#order]
    order = {}
    for i = 1, #PIECES do order[i] = i end
    for i = #order, 2, -1 do
      local j = math.random(1, i)
      order[i], order[j] = order[j], order[i]
    end
    if prev and order[1] == prev and #order > 1 then order[1], order[2] = order[2], order[1] end
    order_i = 0
  end
  order_i = order_i + 1
  return order[order_i]
end

local function on_menu() return (tonumber(params.menu) or 0) >= 0.5 end

local function gap()
  local lo, hi = params.gapMin or 240, params.gapMax or 480
  if on_menu() then lo, hi = 20, 40 end
  return lo + math.random() * math.max(0, hi - lo)
end

local function stop_music(fade_gap)
  if music then music:stop() end
  music, musicPlaying = nil, nil
  next_at = clock + (fade_gap or gap())
end

function hush(secs)
  hush_until = clock + (secs or 10)
  if next_at and next_at < hush_until + 60 then next_at = hush_until + 60 end
end

-- What the music should be doing right now, 0..1 of its own level.
local burning = nil
local function music_duck()
  if clock < hush_until then return 0.0 end
  local d = 1.0
  local pm = ref("pause_menu")
  if pm and pm.open then d = d * 0.7 end
  -- A burning engine. findScripts is a scene walk, so it is asked twice a
  -- second, not every frame (README: "Cross-script lookups").
  if math.floor(clock * 2) ~= math.floor((clock - 0.016) * 2) or burning == nil then
    burning = false
    if findScripts and not on_menu() then
      for _, v in ipairs(findScripts("vessel_controller")) do
        if v.piloting and (v.throttle or 0) > 0.05 and (v.fuel or 1) > 0 then burning = true end
      end
    end
  end
  if burning then d = d * 0.45 end
  return d
end

local function drive_music(dt, loading)
  local st = ref("settings")
  local user = st and st.volume and st.volume("Music") or 0.8
  if not next_at then next_at = clock + (on_menu() and 2.0 or (params.firstDelay or 75)) end
  if loading and not on_menu() then
    -- Nothing starts during the loading hold, and the clock waits for it.
    if not music then next_at = math.max(next_at, clock + (params.firstDelay or 75)) end
  end
  if not music and clock >= next_at and clock >= hush_until and not loading and user > 0.001 then
    music_i = next_piece()
    local p = PIECES[music_i]
    music = audio.play(p.clip, { track = "Music", volume = 0, mode = "Flat" })
    music_t0, music_len, music_gain, lp_music = clock, p.len, 0, 0
    musicPlaying = p.clip
  end
  if not music then return end
  -- Over: the file has played out (it fades itself), or it never could.
  local age = clock - music_t0
  if age > music_len + 1.0 or (age > 5.0 and music.isPlaying and not music:isPlaying()) then
    stop_music()
    return
  end
  if clock < hush_until and music_gain < 0.01 and age > 1 then
    stop_music(math.max(60, hush_until - clock + 60))
    return
  end
  local want = (params.musicGain or 0.85) * user * music_duck()
  -- Ducking eases down quickly and back up slowly, so a stage burn pulls it
  -- away and it creeps back after rather than lurching.
  local k = want < music_gain and 2.5 or 0.5
  music_gain = music_gain + (want - music_gain) * math.min(1, dt * k)
  music:setVolume(music_gain)
  local lp = underwater and 700 or 0
  if lp ~= lp_music then lp_music = lp; music:setLowpass(lp) end
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  clock, music, next_at, hush_until = 0, nil, nil, -1
  loops = {}
  local list = { WIND, GUST, SEA, RAIN_L, RAIN_H, HAIL, DUST }
  if audio and audio.preload then audio.preload(list) end
end

function update(node, dt)
  dt = dt or 0
  clock = clock + dt
  if not (audio and audio.play) then return end
  local gm = ref("game_manager")
  local loading = gm ~= nil and gm.loading == true

  local pm = ref("pause_menu")
  local om = ref("orbit_map")
  local map_open = om ~= nil and om.isOpen ~= nil and om.isOpen() == true

  -- The air at the eye. Not while the orbit map is up: its camera is pulled
  -- out to wherever the map is looking (through a sea, out of the air), and
  -- that is not where the player is standing — the last answer is held.
  if map_open then
    last_rel = nil
  else
    local amt, x, y, z = 0, eye()
    if x and not loading then amt, held.atmo, held.spd = air_at(x, y, z, dt) else held.atmo, held.spd = 0, 0 end
    air = amt
    local cl = ref("climate")
    underwater = (x ~= nil and cl ~= nil and cl.isUnderwater ~= nil and cl.isUnderwater(x, y, z)) == true
  end
  local amt, atmo, spd = air, held.atmo, held.spd
  local scale = 1.0
  if pm and pm.open then scale = scale * 0.5 end
  if map_open then scale = scale * 0.35 end

  local moving = smooth01(2, 60, spd)
  local wind = (params.windGain or 0.6) * (amt ^ 0.6) * (0.65 + 0.35 * moving) * scale
  local gust = (params.gustGain or 0.45) * amt * smooth01(0.3, 0.9, atmo) * (0.5 + 0.5 * moving) * scale
  local sea = underwater and (params.underwaterGain or 0.55) * scale or 0

  -- The weather at the camera (weather.lua). Its wind lifts the wind beds;
  -- rain, hail and dust have their own. A roof overhead muffles them all.
  local wx = (not on_menu()) and ref("weather") or nil
  local wc = wx and wx.current and wx.current() or nil
  local rain_l, rain_h, hail, dust = 0, 0, 0, 0
  local muffle = 0
  if wc and amt > 0 and not underwater then
    -- windNow is the engine's wind at the camera (weather.windAt), so the
    -- gust bed swells with the gusts the rain and smoke are blown by.
    local blow = smooth01(4, 22, wc.windNow or wc.wind or 0)
    wind = wind * (0.8 + 0.7 * blow)
    gust = gust * (0.6 + 1.4 * blow)
    local p = (wc.precip or 0) * scale * math.min(1, amt * 2)
    if wc.kind == "wet" then
      local rain = p * (1 - (wc.snow or 0)) * (1 - 0.5 * (wc.hail or 0))
      local heavy = smooth01(0.55, 0.95, wc.intensity or 0)
      rain_l = (params.rainGain or 0.55) * rain * (1 - 0.75 * heavy)
      rain_h = (params.rainGain or 0.55) * rain * heavy
      hail = (params.hailGain or 0.5) * (wc.hail or 0) * scale
    elseif wc.kind == "dust" then
      dust = (params.dustGain or 0.6) * p * (0.5 + 0.5 * (wc.storm or 0))
    end
    if wc.sheltered then
      rain_l, rain_h, hail, dust, muffle = rain_l * 0.6, rain_h * 0.6, hail * 0.7, dust * 0.5, 900
    end
  end
  if underwater then wind, gust = wind * 0.15, 0 end
  loop_to("wind", WIND, wind, underwater and 500 or 0, dt)
  loop_to("gust", GUST, gust, 0, dt)
  loop_to("sea", SEA, sea, 0, dt)
  loop_to("rain_l", RAIN_L, rain_l, muffle, dt)
  loop_to("rain_h", RAIN_H, rain_h, muffle, dt)
  loop_to("hail", HAIL, hail, muffle, dt)
  loop_to("dust", DUST, dust, muffle, dt)

  drive_music(dt, loading)

  if params.debug and clock - dbg_t > 3.0 then
    dbg_t = clock
    print(string.format("soundscape: air %.2f (atmo %.2f) speed %.1f  wind %.2f gust %.2f sea %.2f  music %s %.2f  next in %.0fs",
      amt, atmo, spd, loops.wind and loops.wind.v or 0, loops.gust and loops.gust.v or 0,
      loops.sea and loops.sea.v or 0, musicPlaying or "-", music_gain, (next_at or 0) - clock))
  end
end

function onDestroy(node)
  if music then music:stop() end
  for _, L in pairs(loops) do if L.h then L.h:stop() end end
end
