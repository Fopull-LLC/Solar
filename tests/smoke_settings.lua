-- SMOKE HARNESS: settings.lua — the player's preferences, the screen that
-- changes them, and that they come back.
--
-- What is held here is the set of ways a settings screen lies:
--
--   * a slider that moves and changes nothing (each control reaches the engine
--     call it promises: the bus fader, the frame cap, the camera's FOV…)
--   * a setting that is gone on the next launch (the store is the player's
--     "settings" slot, never the loaded game's, and a restart reads it back)
--   * a volume slider that REPLACES the mix instead of offsetting it (the
--     faders in project.ron are the sound designer's; 100% is that mix)
--   * a store written every frame while a slider is dragged
--
--   luajit solar/tests/smoke_settings.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine ──────────────────────────────────────────────────────────────────
-- A save store with real slots, so "the game's slot is untouched" is testable.
local slots = { slot11 = { progress = 42 }, settings = {} }
local active = "slot11"
local flushes = 0
local save = {
  slot = function(name) if name then active = name; slots[name] = slots[name] or {} end return active end,
  get = function(k, d) local v = slots[active][k]; if v == nil then return d end return v end,
  set = function(k, v) slots[active][k] = v end,
  flush = function() flushes = flushes + 1; return true end,
}

local faders, muted = {}, {}
local audio = {
  track = function(name)
    return {
      setVolume = function(_, db) faders[name] = db end,
      setMuted = function(_, m) muted[name] = m end,
    }
  end,
}
local app_state = { cap = nil, vsync = "On", fullscreen = false, dyn = nil }
local app = {
  refreshRate = function() return 143.9 end,
  setFrameCap = function(n)
    assert(n == 0 or (n >= 10 and n <= 1000), "setFrameCap out of range: " .. tostring(n))
    app_state.cap = n
  end,
  setVsync = function(m)
    assert(m == "On" or m == "Adaptive" or m == "Off", "setVsync: " .. tostring(m))
    app_state.vsync = m
  end,
  vsync = function() return app_state.vsync end,
  setFullscreen = function(on) app_state.fullscreen = on end,
  fullscreen = function() return app_state.fullscreen end,
}
local acc = { scale = 1.0, captions = false, motion = false, filter = "none" }
local access = {
  setTextScale = function(s) assert(s >= 0.5 and s <= 3.0); acc.scale = s end,
  textScale = function() return acc.scale end,
  setCaptions = function(b) acc.captions = b end,
  captions = function() return acc.captions end,
  setReducedMotion = function(b) acc.motion = b end,
  reducedMotion = function() return acc.motion end,
  setColorFilter = function(n) acc.filter = n end,
  colorFilter = function() return acc.filter end,
  filters = function() return { { name = "none" }, { name = "protanopia" },
                                { name = "deuteranopia" }, { name = "tritanopia" } } end,
}
local cam = { fovY = 1.1519173 }
local cam_node = { valid = true, getcomponent = function(_, k) if k == "Camera" then return cam end end }
local gx_dynamic = nil
local envs = {
  planet_camera = { valid = true, node = cam_node },
  graphics = { valid = true, LEVELS = { "Low", "Medium", "High", "Ultra" },
               level = function() return "High" end, set = function() end,
               describe = function() return "x" end,
               setDynamic = function(on) gx_dynamic = on end },
}

local function load_settings(opts)
  opts = opts or {}
  local env = setmetatable({}, { __index = function(_, k)
    if k == "save" then return save end
    if k == "audio" then return audio end
    if k == "app" then return app end
    if k == "access" then return access end
    if k == "find" then return function(name)
      if name == "Astronaut" and not opts.bare then return { valid = true } end
    end end
    if k == "findScript" then return function(kind)
      if opts.bare then return nil end
      return envs[kind]
    end end
    return _G[k]
  end })
  local chunk = assert(loadfile("solar/scripts/settings.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  return env
end

local function run(env, secs)
  for _ = 1, math.floor(secs * 60 + 0.5) do env.update({}, 1 / 60) end
end

-- ── 1. FIRST LAUNCH: the defaults reach the engine ──────────────────────────
local st = load_settings()
st.start({})
ok(active == "slot11", "starting up leaves the game's own slot active")
ok(faders.Master == 0 and faders.SFX == 0, "Master and SFX at 100% sit on their project faders")
ok(faders.UI == -3 and faders.Ambient == -9,
  "UI and Ambient keep project.ron's -3 / -9 dB under a 100% slider, not 0 dB")
ok(faders.Music == nil, "Music is not driven through a fader (there is no Music bus to drive)")
ok(math.abs(st.volume("Music") - 0.8) < 1e-9, "...its slider starts at 80%")
ok(app_state.cap == 0, "the frame cap starts off")
ok(app_state.vsync == "On", "vsync starts On")
ok(math.abs(cam.fovY - math.rad(66)) < 1e-3, "the player camera gets the 66° field of view")
ok(acc.captions == false and acc.scale == 1.0,
  "accessibility nobody has chosen yet is left alone (the editor's panel drives it too)")
ok(st.lookScale == 1.0 and st.invertY == false, "mouse: ×1, not inverted")

-- ── 2. CHANGING THINGS: every control reaches its engine call ───────────────
st.set("vol_SFX", 0.5)
ok(math.abs(faders.SFX - (-12.0)) < 0.05, "half the SFX slider is -12 dB on the SFX fader")
st.set("vol_Ambient", 0.5)
ok(math.abs(faders.Ambient - (-21.0)) < 0.05, "...and an offset from Ambient's own -9 dB")
st.set("vol_UI", 0)
ok(muted.UI == true, "a slider at zero mutes the bus")
st.set("vol_Music", 0.4)
ok(faders.Music == nil and math.abs(st.volume("Music") - 0.4) < 1e-9,
  "the Music slider is read by the music player, still not a fader")
st.set("frame_cap", "half")
ok(app_state.cap == 72, "frame cap 'half' on a 143.9 Hz display is 72 fps")
st.set("frame_cap", "refresh")
ok(app_state.cap == 144, "...'refresh' is 144")
st.set("vsync", "Adaptive")
ok(app_state.vsync == "Adaptive", "vsync reaches app.setVsync")
st.set("fov", 80)
ok(math.abs(cam.fovY - math.rad(80)) < 1e-6, "the FOV reaches the player camera, in radians")
st.set("look", 1.5); st.set("invert_y", true)
ok(st.lookScale == 1.5 and st.invertY == true, "sensitivity and invert-Y are published for planet_camera")
st.set("dynamic_res", true)
ok(gx_dynamic == true, "dynamic resolution goes through graphics.lua (it owns the render scale)")
st.set("text_scale", 1.25); st.set("captions", true); st.set("color_filter", "deuteranopia")
ok(acc.scale == 1.25 and acc.captions == true and acc.filter == "deuteranopia",
  "text size, captions and the colour filter reach access.*")
st.set("fullscreen", true)
ok(app_state.fullscreen == true, "fullscreen reaches app.setFullscreen")

-- ── 3. THE STORE: debounced, and in the settings slot ───────────────────────
local f0 = flushes
for i = 1, 30 do st.set("vol_Master", 0.5 + i / 100); st.update({}, 1 / 60) end
ok(flushes == f0, "dragging a slider does not write the store every frame")
run(st, 1.0)
ok(flushes == f0 + 1, "...it is written once the slider rests")
ok(slots.settings.opt_vol_Master ~= nil and slots.slot11.opt_vol_Master == nil,
  "...into the settings slot, never the game's")
ok(active == "slot11" and slots.slot11.progress == 42, "...and the game's slot is active and intact after")

-- ── 4. A RESTART reads it all back ──────────────────────────────────────────
faders, muted = {}, {}
app_state = { cap = nil, vsync = "On", fullscreen = false }
acc = { scale = 1.0, captions = false, motion = false, filter = "none" }
cam.fovY = 1.1519173
local st2 = load_settings()
st2.start({})
ok(math.abs(faders.SFX - (-12.0)) < 0.05 and muted.UI == true, "volumes survive a restart")
ok(app_state.cap == 144 and app_state.vsync == "Adaptive", "frame cap and vsync survive a restart")
ok(math.abs(cam.fovY - math.rad(80)) < 1e-6, "the FOV survives a restart")
ok(st2.lookScale == 1.5 and st2.invertY == true, "mouse settings survive a restart")
ok(acc.scale == 1.25 and acc.captions == true and acc.filter == "deuteranopia",
  "accessibility choices survive a restart")
ok(app_state.fullscreen == true, "fullscreen survives a restart")

-- ── 4b. THE NEXT SCENE: the mixer already holds the levels ─────────────────
-- The engine keeps a track change across scene loads (0.117, floptle/0390), so
-- a scene's settings script that finds the player's levels in the mixer does
-- not write them again; one that finds project.ron's mix (a session's first
-- scene) does.
local BASE = { Master = 0, SFX = 0, UI = -3, Ambient = -9, Music = 0 }
local writes = 0
local real_track = audio.track
audio.tracks = function()
  local out = {}
  for _, n in ipairs({ "Master", "SFX", "UI", "Ambient", "Music" }) do
    local db = faders[n]
    if db == nil then db = BASE[n] end
    out[#out + 1] = { name = n, gainDb = db, muted = muted[n] == true }
  end
  return out
end
audio.track = function(name)
  local t = real_track(name)
  local sv = t.setVolume
  t.setVolume = function(self, db) writes = writes + 1; sv(self, db) end
  return t
end
local st3 = load_settings()
st3.start({})
ok(writes == 0, string.format("the next scene finds the levels held and writes no fader (%d)", writes))
ok(math.abs(cam.fovY - math.rad(80)) < 1e-6, "...but still sets its own camera's field of view")
faders, muted = {}, {}
local st4 = load_settings()
st4.start({})
ok(writes > 0 and math.abs(faders.SFX - (-12.0)) < 0.05,
  "a session's first scene (the mixer at project.ron's mix) applies the player's levels")
-- A bus project.ron does not have: audio.track answers nil, nothing breaks.
audio.track = function(name) if name == "UI" then return nil end return real_track(name) end
ok(pcall(st4.set, "vol_UI", 0.5), "a slider for a bus the mixer lacks changes nothing and raises nothing")
audio.track, audio.tracks = real_track, nil

-- ── 5. THE SCREEN ───────────────────────────────────────────────────────────
-- Every tab draws, every row has a key, and the sliders are draggable ones
-- that write back through onChanged.
local function walk(t, fn)
  if type(t) ~= "table" then return end
  fn(t)
  for i = 2, #t do if type(t[i]) == "table" then walk(t[i], fn) end end
  local build = t[#t]
  for _, item in ipairs(t.items or {}) do
    if type(build) == "function" then walk(build(item), fn) else walk(item, fn) end
  end
end
for _, tab in ipairs({ "display", "camera", "controls", "audio", "access" }) do
  st2.showTab(tab)
  local rows = st2.rows(580)
  local n, sliders, unkeyed = 0, 0, 0
  for _, r in ipairs(rows) do
    walk(r, function(e)
      n = n + 1
      if e[1] == "slider" then
        sliders = sliders + 1
        if not (e.interact and e.onChanged) then unkeyed = unkeyed + 100 end
      end
      if (e[1] == "row" or e[1] == "col" or e[1] == "button" or e[1] == "slider") and not e.key then
        unkeyed = unkeyed + 1
      end
    end)
  end
  ok(n > 5, tab .. " tab draws something")
  ok(unkeyed == 0, tab .. " tab: every container is keyed and every slider is draggable")
  if tab == "audio" then ok(sliders == 5, "the audio tab has a slider per bus (5), got " .. sliders) end
  if tab == "camera" then ok(sliders == 2, "the camera tab has FOV and sensitivity sliders") end
end
ok(st2.currentTab() == "access", "showTab switches the page")

-- A slider drag writes back through onChanged.
st2.showTab("audio")
local hit
for _, r in ipairs(st2.rows(580)) do
  walk(r, function(e) if e[1] == "slider" and not hit then hit = e end end)
end
local fake = { getcomponent = function(_, k) if k == "UiSlider" then return { value = 0.25 } end end }
hit.onChanged(fake)
ok(math.abs(faders.Master - (40 * math.log10(0.25))) < 1e-6, "dragging the Master slider moves the Master fader")

-- ── 6. THE MIX ON DISK ──────────────────────────────────────────────────────
-- BASE_DB mirrors project.ron's faders: a slider at 100% must mean the mix the
-- project ships, and a bus renamed there must not leave a slider steering
-- nothing.
local fh = assert(io.open("solar/project.ron", "r"))
local ron = fh:read("*a")
fh:close()
local disk = {}
for name, db in ron:gmatch('name:%s*"([%w ]+)",%s*gain_db:%s*(%-?[%d%.]+)') do disk[name] = tonumber(db) end
local PENDING = { Music = true }   -- buses the code expects that project.ron does not have yet
for _, b in ipairs(st2.BUSES) do
  if disk[b] then
    ok(math.abs(disk[b] - st2.BASE_DB[b]) < 1e-6,
      string.format("BASE_DB.%s (%s) matches project.ron (%s)", b, st2.BASE_DB[b], disk[b]))
  else
    ok(PENDING[b], "the " .. b .. " bus is missing from project.ron")
  end
end
if not disk.Music then
  print("  note: project.ron has no Music bus yet — music plays through Master, scaled per voice")
end

-- ── 6b. RESOLUTION AND MONITOR (0.117: app.monitors / displayModes) ─────────
local modes_set = {}
app.monitors = function()
  -- (as 0.117.0-rc2 answers on a two-monitor desktop: each one twice)
  return { { index = 1, name = "DP-1", x = 0, y = 0, width = 2560, height = 1440, refresh = 144, current = true },
           { index = 2, name = "HDMI-A-1", x = 2560, y = 0, width = 1920, height = 1080, refresh = 60 },
           { index = 3, name = "DP-1", x = 0, y = 0, width = 2560, height = 1440, refresh = 144, current = true },
           { index = 4, name = "HDMI-A-1", x = 2560, y = 0, width = 1920, height = 1080, refresh = 60 } }
end
app.displayModes = function(mon)
  if mon == 2 then return { { width = 1920, height = 1080, refresh = 60, monitor = 2 },
                            { width = 1280, height = 720, refresh = 60, monitor = 2 } } end
  return { { width = 2560, height = 1440, refresh = 144, monitor = 1 },
           { width = 2560, height = 1440, refresh = 60, monitor = 1 },
           { width = 1920, height = 1080, refresh = 144, monitor = 1 } }
end
app.setDisplayMode = function(t) modes_set[#modes_set + 1] = t end
_G.camera = { screenSize = function() return 2560, 1440 end }
local st5 = load_settings()
st5.start({})
ok(#modes_set == 0, "nothing chosen yet: the display mode is left alone")
st5.showTab("display")
local function find_el(rows, key)
  local hit2
  for _, r in ipairs(rows) do walk(r, function(e) if e.key == key and not hit2 then hit2 = e end end) end
  return hit2
end
local res = find_el(st5.rows(580), "res")
ok(res ~= nil, "the Display tab has a Resolution row when there is a window")
ok(find_el(st5.rows(580), "mon") ~= nil, "...and a Monitor choice with two monitors")
local nmon = 0
walk(find_el(st5.rows(580), "mon"), function(e) if e[1] == "button" then nmon = nmon + 1 end end)
ok(nmon == 2, "...each monitor once, though the engine lists each twice (" .. nmon .. ")")
local function res_text() local v = find_el(st5.rows(580), "res"); local t; walk(v, function(e) if e.key == "v" then t = e.text end end); return t end
ok(res_text():find("2560 × 1440") and res_text():find("144 Hz"), "...showing the size in use, at its highest refresh: " .. res_text())
find_el(st5.rows(580), "dn").onClicked()
ok(res_text():find("1920 × 1080"), "‹ steps to the next size down: " .. res_text())
ok(#modes_set == 0, "...without switching the screen mode")
find_el(st5.rows(580), "go").onClicked()
ok(#modes_set == 1 and modes_set[1].width == 1920 and modes_set[1].height == 1080 and modes_set[1].monitor == 1,
  "Apply sets that display mode")
-- the second monitor lists its own modes
local monrow = find_el(st5.rows(580), "mon")
local second
walk(monrow, function(e) if e.text == "HDMI-A-1" then second = e end end)
second.onClicked()
ok(res_text():find("1920 × 1080") and res_text():find("60 Hz"), "picking the other monitor lists its modes: " .. res_text())
-- a restart in a window of another size applies the saved mode once
run(st5, 1.0)
modes_set = {}
local st6 = load_settings()
st6.start({})
ok(#modes_set == 1 and modes_set[1].width == 1920, "the chosen resolution comes back on the next launch")
_G.camera = { screenSize = function() return 1920, 1080 end }
modes_set = {}
load_settings().start({})
ok(#modes_set == 0, "...and a scene load in a window already that size does not switch it again")
app.monitors = function() return {} end
ok(find_el(st5.rows(580), "res") == nil and find_el(st5.rows(580), "resn") ~= nil,
  "no window (floptle run): no Resolution row, a line saying it follows the window")
app.monitors, app.displayModes, app.setDisplayMode, _G.camera = nil, nil, nil, nil

-- ── 6c. THE ENGINE'S PAGES (0.117: ui.engineSettings) in a repeater host ─────
local built, polled = {}, 0
local host = { valid = true }
_G.ui = { engineSettings = function(container, page, opts)
  built[#built + 1] = { container = container, page = page, opts = opts }
  return { update = function() polled = polled + 1 end }
end }
local st7 = load_settings()
st7.start({})
rawset(st7, "find", function(name) if name == "Settings Host" then return host end end)
st7.showTab("controls")
local crow = st7.rows(580)
ok(find_el(crow, "engineHost") and find_el(crow, "engineHost").template == "SettingsHost",
  "the Controls tab hosts the engine's page in a one-row repeater")
st7.update({}, 1 / 60)
ok(#built == 1 and built[1].page == "controls" and built[1].container == host,
  "...and builds the engine's Controls page into it")
ok(built[1].opts.styles.button == "panel/choice", "...in Solar's styles")
st7.rows(580); st7.update({}, 1 / 60)
ok(#built == 1 and polled >= 1, "...once, then polls it every frame (press-to-bind)")
st7.showTab("access")
st7.rows(580); st7.update({}, 1 / 60)
ok(#built == 2 and built[2].page == "accessibility", "the Accessibility tab is the engine's page")
built[2].opts.onChanged("textScale", 1.5)
built[2].opts.onChanged("captions", false)
run(st7, 1.0)
ok(slots.settings.opt_text_scale == 1.5 and slots.settings.opt_captions == false,
  "a change made on the engine's page is kept in the settings store")
local n_before = #built
run(st7, 0.5)
ok(#built == n_before, "the screen closed (no rows asked for): the page is let go, not rebuilt")
_G.ui = nil

-- ── 7. NO ENGINE CALLS AVAILABLE: still no error ────────────────────────────
local bare = load_settings({ bare = true })
ok(pcall(bare.start, {}), "starts in a scene with no camera or graphics script")
ok(pcall(bare.set, "fov", 70) and pcall(bare.rows, 580), "...and its rows still draw")

if #failures == 0 then
  print(string.format("SETTINGS SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("SETTINGS SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
