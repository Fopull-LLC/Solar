-- SMOKE HARNESS: soundscape.lua — the wind, the sea, and the music.
--
-- The rules that make ambience and music bearable rather than wallpaper:
--
--   * vacuum is silent; air is wind, and thicker air is more of it
--   * under the sea the wind goes and the sea comes, and the music is muffled
--   * the music is sparse: a long quiet after loading, minutes between pieces,
--     never during the loading hold, never at a muted slider
--   * it ducks under a burning engine and is gone after a lost vessel
--
--   luajit solar/tests/smoke_soundscape.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine ──────────────────────────────────────────────────────────────────
local sounds = {}
local function new_handle(clip, opts)
  local h = { clip = clip, opts = opts, vol = opts.volume or 1, lp = 0, playing = true, stopped = false }
  function h:setVolume(v) self.vol = v end
  function h:setLowpass(v) self.lp = v end
  function h:stop() self.playing, self.stopped = false, true end
  function h:isPlaying() return self.playing end
  sounds[#sounds + 1] = h
  return h
end
local audio = {
  play = function(clip, opts) return new_handle(clip, opts) end,
  preload = function() end,
}
local function live(pat)
  for i = #sounds, 1, -1 do
    local h = sounds[i]
    if not h.stopped and h.clip:find(pat, 1, true) then return h end
  end
end

-- One world, Oria: 200 m radius, a sea at 190 m, air of 0.9 up to 80 m.
local body = { x = 0, y = 0, z = 0, radius = 200 }
local world = { atmo = 0.9, atmoHeight = 80 }
local space = {
  dominant = function() return "Oria" end,
  body = function() return body end,
}
local save = { get = function(k) if k == "world.Oria" then return world end end }
local cam = { valid = true, cam_x = 0, cam_y = 202, cam_z = 0 }
local sea_r = 190
local climate = { valid = true, isUnderwater = function(x, y, z)
  return math.sqrt(x * x + y * y + z * z) < sea_r end }
local gm = { valid = true, loading = false }
local pm = { valid = true, open = false }
local music_slider = 0.8
local st = { valid = true, volume = function(b) if b == "Music" then return music_slider end return 1 end }
local craft = { piloting = false, throttle = 0, fuel = 10 }
local SCRIPTS = { planet_camera = cam, climate = climate, game_manager = gm, pause_menu = pm, settings = st }

local env = setmetatable({}, { __index = function(_, k)
  if k == "audio" then return audio end
  if k == "space" then return space end
  if k == "save" then return save end
  if k == "findScript" then return function(kind) return SCRIPTS[kind] end end
  if k == "findScripts" then return function(kind)
    if kind == "vessel_controller" then return { craft } end
    return {}
  end end
  return _G[k]
end })
local chunk = assert(loadfile("solar/scripts/soundscape.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end
env.start({})
local function run(secs) for _ = 1, math.floor(secs * 20 + 0.5) do env.update({}, 0.05) end end

-- ── 1. AIR ──────────────────────────────────────────────────────────────────
run(4)
local wind = live("wind_low")
ok(wind and wind.opts.track == "Ambient" and wind.opts.loop, "standing in air: a wind loop on the Ambient bus")
local ground_wind = wind and wind.vol or 0
ok(ground_wind > 0.3 and ground_wind <= 0.6, "...at a sensible level (" .. ground_wind .. ")")
ok(live("wind_gust") ~= nil, "thick air gusts too")

cam.cam_y = 255          -- 55 m up: thinner air
run(4)
ok(wind.vol < ground_wind * 0.8, "higher up the wind thins")

world.atmo = 0           -- the same place, no atmosphere
run(10)
ok(live("wind_low") == nil and live("wind_gust") == nil, "vacuum is silent: the wind loops are stopped")
world.atmo = 0.9

-- ── 2. THE SEA ──────────────────────────────────────────────────────────────
cam.cam_y = 185          -- under the surface
run(4)
local sea = live("underwater")
ok(sea and sea.vol > 0.3, "under the sea: the underwater bed")
local w2 = live("wind_low")
ok(not w2 or (w2.vol < 0.15 and w2.lp > 0), "...the wind all but gone, and muffled")
ok(env.underwater == true, "...published")
cam.cam_y = 202
run(10)
ok(live("underwater") == nil, "out of the water, the bed stops")

-- ── 3. MUSIC IS SPARSE ──────────────────────────────────────────────────────
-- (start() was 20 s ago in sim time.)
ok(live("audio/music/") == nil, "no music in the first minute of a world")
gm.loading = true
run(120)
ok(live("audio/music/") == nil, "...nor at any time during the loading hold")
gm.loading = false
run(60)
ok(live("audio/music/") == nil, "...and the quiet after loading is counted from when it ended")
run(30)
local m = live("audio/music/")
ok(m and m.opts.track == "Music", "a piece comes in after the quiet, on the Music track")
run(10)
ok(m and math.abs(m.vol - 0.85 * 0.8) < 0.05, "...scaled by the player's Music slider (80%)")

-- Ducking: a burning engine pulls it down, quickly; it comes back slowly.
craft.piloting, craft.throttle = true, 1.0
run(3)
ok(m.vol < 0.4, "it ducks under a burning engine (" .. m.vol .. ")")
craft.throttle = 0
run(1)
ok(m.vol < 0.55, "...and creeps back rather than lurching")
run(15)
ok(m.vol > 0.6, "...all the way, once the burn is over")
craft.piloting = false

-- Underwater the music is muffled.
cam.cam_y = 185
run(1)
ok(m.lp > 0 and m.lp < 2000, "the music is muffled under the sea")
cam.cam_y = 202
run(1)
ok(m.lp == 0, "...and clear again above it")

-- The piece ends, and a long quiet follows.
local played_clip = m.clip
run(200)
ok(m.stopped, "the piece is let go when it has played out")
local again = live("audio/music/")
ok(again == nil, "minutes of quiet between pieces, not a playlist")
local waited, nxt = 0, nil
while waited < 500 and not nxt do run(5); waited = waited + 5; nxt = live("audio/music/") end
ok(waited >= 150, "...at least a few minutes of it (" .. waited .. " s after the first ended)")
ok(nxt ~= nil and nxt.clip ~= played_clip, "the next piece comes eventually, and it is a different one")
if not nxt then nxt = new_handle("none", {}) end

-- A lost vessel: the music is gone and stays gone for a while.
env.hush(12)
run(3)
ok(nxt.vol < 0.05, "a hush takes the music out")
run(12)
ok(nxt.stopped, "...and the piece is stopped")
run(40)
ok(live("audio/music/") == nil, "...and nothing new starts straight after")

-- A muted slider means no music at all, not music at zero volume.
music_slider = 0
run(1500)
ok(live("audio/music/") == nil, "a Music slider at 0 never starts a piece")

-- ── 4. THE MENU ─────────────────────────────────────────────────────────────
sounds = {}
local menu = setmetatable({}, { __index = function(_, k)
  if k == "audio" then return audio end
  if k == "findScript" then return function() return nil end end
  if k == "findScripts" then return function() return {} end end
  return _G[k]
end })
local c2 = assert(loadfile("solar/scripts/soundscape.lua"))
setfenv(c2, menu)
c2()
menu.params = {}
for k, v in pairs(menu.defaults) do menu.params[k] = v end
menu.params.menu = 1.0
menu.start({})
for _ = 1, 80 do menu.update({}, 0.05) end
ok(live("audio/music/") ~= nil, "the main menu starts its music within a few seconds")
ok(live("wind_") == nil, "...and has no wind (there is no world)")

if #failures == 0 then
  print(string.format("SOUNDSCAPE SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("SOUNDSCAPE SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
