-- SETTINGS — the player's preferences: what they are, where they live, and the
-- screen that changes them.
--
-- Before this the only setting was the graphics level. Anything else a player
-- expects from the first menu they open — a quieter music bus, a slower mouse,
-- a wider view, captions, vsync — either did not exist or lived in the editor's
-- own settings panel, which a player of an exported build never sees.
--
-- Three rules:
--
--   * IT IS THE PLAYER'S, NOT THE SAVE'S. Everything is kept in the "settings"
--     store slot (the one graphics.lua already uses), never in a game slot, so
--     a new galaxy does not reset your mouse.
--   * IT APPLIES AT STARTUP. This script sits in the menu, the system and the
--     builder, and `start` applies the store. The mixer keeps a change for the
--     whole play session, across scene loads (0.117, floptle/0390), so the
--     buses are only written when the mixer does not already hold the
--     player's levels: the first scene of a session. The rest (the camera's
--     field of view, the look scale) belongs to each scene.
--   * EVERY ROW SAYS WHAT IT DOES NOW. A setting that only takes effect after a
--     restart, or does nothing in the editor, says so on its row.
--
-- The screen is described, not authored: `rows(w)` returns ui.make rows that
-- the pause menu (pause_menu.lua) and the main menu (menu_settings.lua) both
-- put inside their own frame, so there is one settings screen, not two.
--
-- Cross-script:
--   local st = findScript("settings")
--   st.get(key)  st.set(key, value)       read / change (applies + persists)
--   st.volume("Music")                    a bus's slider, 0..1
--   st.lookScale, st.invertY              read by planet_camera every frame
--   st.rows(w)                            the settings screen's rows
--   st.flush()                            write anything pending now
--   st.resetAllBindings()                 every input action back to input.ron's key
--   st.rebinding()                        a rebind is waiting for its key (Esc is its)

-- The mixer's buses, in the order the screen shows them, and each one's fader
-- in project.ron. A volume slider is an OFFSET from that fader, not a
-- replacement for it: the mix in project.ron is the sound designer's, and the
-- player's 100% is that mix. `tests/smoke_settings.lua` holds these numbers
-- against project.ron.
BUSES = { "Master", "Music", "SFX", "Ambient", "UI" }
BASE_DB = { Master = 0.0, SFX = 0.0, UI = -3.0, Ambient = -9.0, Music = 0.0 }
-- Music is applied on the VOICE (soundscape.lua multiplies every music sound
-- by its slider), not on a fader: project.ron has no Music bus yet, a sound
-- routed to a missing bus plays through Master, and a fader that is not there
-- ignores setVolume. Doing it per voice works with or without the bus.
local PER_VOICE = { Music = true }

local LEVELS = { "Low", "Medium", "High", "Ultra" }   -- graphics.lua's, for the menu

-- key → default. A nil default means "leave the engine's own value alone until
-- the player has chosen one" (fullscreen, the accessibility options — the
-- editor's ♿ panel drives those too, and must not be stamped over).
local DEFAULTS = {
  vol_Master = 1.0, vol_Music = 0.8, vol_SFX = 1.0, vol_Ambient = 1.0, vol_UI = 1.0,
  vsync = "On",
  frame_cap = "off",          -- "off" | "refresh" | "half"
  dynamic_res = false,
  fov = 66,                   -- vertical degrees (the scene camera's 1.152 rad)
  look = 1.0,                 -- mouse sensitivity multiplier
  invert_y = false,
}
-- …and the ones whose default is "leave it alone" (a nil can't sit in a table).
local OPTIONAL = { "fullscreen", "display", "text_scale", "captions", "reduced_motion", "color_filter",
                   "bindings" }
local KEYS = {}
for k in pairs(DEFAULTS) do KEYS[#KEYS + 1] = k end
for _, k in ipairs(OPTIONAL) do KEYS[#KEYS + 1] = k end

-- Published for planet_camera (read every frame, so they are plain values).
lookScale = 1.0
invertY = false
dynamicRes = false

local values = {}
local pending = {}            -- keys changed but not yet written
local pending_at = nil        -- our own clock when the last change happened
local clock = 0.0             -- dt-driven: `time` may stand still while paused
local tab = "display"

-- Cached, and a script missing from this scene is asked for again only every
-- few seconds: each ask walks the scene (floptle/0063).
local refs, missed = {}, {}
-- planet_camera and graphics exist only in the system scene (the one with a
-- crew in it). Asked for anywhere else, each miss is a Console line.
local GAME_ONLY = { planet_camera = true, graphics = true }
local function ref(kind)
  if GAME_ONLY[kind] and not (find and find("Astronaut")) then return nil end
  local r = refs[kind]
  if r and r.valid then return r end
  if missed[kind] and clock - missed[kind] < 3.0 then return nil end
  r = findScript and findScript(kind) or nil
  refs[kind], missed[kind] = r, (r == nil) and clock or nil
  return r
end

-- ── the store ───────────────────────────────────────────────────────────────

-- The settings slot, read or written without losing the save that is loaded.
local function with_settings(fn)
  if not (save and save.slot) then return nil end
  local cur = save.slot()
  if cur == "settings" then return fn() end
  save.slot("settings")
  local ok, r = pcall(fn)
  save.slot(cur)
  if not ok then print("settings: " .. tostring(r)) end
  return r
end

local function load_all()
  with_settings(function()
    for _, k in ipairs(KEYS) do
      local v = save.get("opt_" .. k, nil)
      if v ~= nil then values[k] = v end
    end
    values.gfx_level = save.get("gfx_level", nil)
  end)
end

function flush()
  if not next(pending) then return end
  local keys = pending
  pending, pending_at = {}, nil
  with_settings(function()
    for k in pairs(keys) do
      if k == "gfx_level" then save.set("gfx_level", values[k])
      elseif values[k] == nil then save.delete("opt_" .. k)
      else save.set("opt_" .. k, values[k]) end
    end
    save.flush()
  end)
end

function get(k)
  local v = values[k]
  if v == nil then v = DEFAULTS[k] end
  return v
end

function volume(bus) return get("vol_" .. bus) or 1.0 end

-- ── applying ────────────────────────────────────────────────────────────────

-- 0..1 → dB. Square-law: half the slider is -12 dB, which is what "half as
-- loud" sounds like; a linear fader crams all the useful range into its top
-- fifth.
function sliderDb(v)
  if v <= 0.001 then return -80.0 end
  return 40.0 * math.log10(v)
end

local function bus_db(bus) return (BASE_DB[bus] or 0.0) + sliderDb(volume(bus)) end

local function apply_bus(bus)
  if PER_VOICE[bus] or not (audio and audio.track) then return end
  local t = audio.track(bus)        -- nil when project.ron has no such bus
  if not t then return end
  local v = volume(bus)
  t:setVolume(bus_db(bus))
  t:setMuted(v <= 0.001)
end

-- Does the mixer already hold the player's levels? It keeps them across scene
-- loads, so only a session's first scene finds it at project.ron's mix.
local function buses_held()
  if not (audio and audio.tracks) then return false end
  local have = {}
  for _, t in ipairs(audio.tracks()) do have[t.name] = t end
  for _, b in ipairs(BUSES) do
    local t = have[b]
    if t and not PER_VOICE[b] then
      local want = bus_db(b)
      if math.abs((t.gainDb or 0) - want) > 0.01 or (t.muted == true) ~= (volume(b) <= 0.001) then
        return false
      end
    end
  end
  return true
end

-- The game view's size in pixels, or nil (no camera API, no window).
local function screen_size()
  if not (camera and camera.screenSize) then return nil, nil end
  return camera.screenSize()
end

local function refresh_hz()
  local r = app and app.refreshRate and app.refreshRate() or nil
  if type(r) ~= "number" or r < 20 then return nil end
  return r
end

local function apply_cap()
  if not (app and app.setFrameCap) then return end
  local mode = get("frame_cap")
  local hz = refresh_hz() or 60
  local cap = 0
  if mode == "refresh" then cap = math.floor(hz + 0.5)
  elseif mode == "half" then cap = math.floor(hz / 2 + 0.5) end
  if cap ~= 0 then cap = math.max(10, math.min(1000, cap)) end
  pcall(app.setFrameCap, cap)
end

-- The field of view is the PLAYER camera's: the one planet_camera drives (on
-- foot and in flight). The builder's orbit camera and the menu's backdrop are
-- framed shots and keep their own.
local cam_node, cam_comp = nil, nil
local function apply_fov()
  if not (cam_node and cam_node.valid ~= false) then
    local pc = ref("planet_camera")
    cam_node = pc and pc.node or nil
    cam_comp = cam_node and cam_node:getcomponent("Camera") or nil
  end
  if cam_comp then
    local want = math.rad(get("fov"))
    if math.abs((cam_comp.fovY or 0) - want) > 1e-4 then cam_comp.fovY = want end
  end
end

local APPLY = {
  vsync = function()
    if app and app.setVsync then pcall(app.setVsync, get("vsync")) end
  end,
  frame_cap = apply_cap,
  dynamic_res = function()
    dynamicRes = get("dynamic_res") == true
    -- graphics.lua owns the render scale (each quality level is a scale), so
    -- it is the one that turns the engine's dynamic resolution on, capped at
    -- the level's own scale. Without it (the menus) there is nothing to scale.
    local gx = ref("graphics")
    if gx and gx.setDynamic then gx.setDynamic(dynamicRes) end
  end,
  fov = apply_fov,
  look = function() lookScale = get("look") end,
  invert_y = function() invertY = get("invert_y") == true end,
  fullscreen = function()
    local v = get("fullscreen")
    if v ~= nil and app and app.setFullscreen then pcall(app.setFullscreen, v) end
  end,
  -- The resolution (and monitor) the player picked: { w, h, hz, mon }. Set
  -- only when the window is not already that size, so a scene load does not
  -- switch the display mode again. Nothing to do without a window.
  display = function()
    local d = get("display")
    if type(d) ~= "table" or not (app and app.setDisplayMode and app.monitors) then return end
    if #app.monitors() == 0 then return end
    local sw, sh = screen_size()
    if sw == d.w and sh == d.h then return end
    local ok, err = pcall(app.setDisplayMode, { width = d.w, height = d.h, refresh = d.hz, monitor = d.mon })
    if not ok then print("settings: display mode " .. tostring(err)) end
  end,
  text_scale = function()
    local v = get("text_scale")
    if v and access and access.setTextScale then pcall(access.setTextScale, v) end
  end,
  captions = function()
    local v = get("captions")
    if v ~= nil and access and access.setCaptions then access.setCaptions(v) end
  end,
  reduced_motion = function()
    local v = get("reduced_motion")
    if v ~= nil and access and access.setReducedMotion then access.setReducedMotion(v) end
  end,
  color_filter = function()
    local v = get("color_filter")
    if v and access and access.setColorFilter then pcall(access.setColorFilter, v) end
  end,
  -- The player's rebinds (input.saveBindings text). Actions input.ron no
  -- longer has are skipped, and ones the text leaves out keep input.ron's.
  bindings = function()
    local v = get("bindings")
    if type(v) == "string" and input and input.loadBindings then
      local ok, err = input.loadBindings(v)
      if not ok then print("settings: bindings " .. tostring(err)) end
    end
  end,
}
for _, b in ipairs(BUSES) do APPLY["vol_" .. b] = function() apply_bus(b) end end

function set(k, v)
  if k == "gfx_level" then
    local gx = ref("graphics")
    if gx and gx.set then gx.set(v)          -- graphics.lua applies and saves it
    else values.gfx_level = v; pending.gfx_level = true; pending_at = clock end
    return
  end
  if DEFAULTS[k] == nil and APPLY[k] == nil then return end
  values[k] = v
  if APPLY[k] then APPLY[k]() end
  pending[k] = true
  pending_at = clock
end

-- Everything, or (`skip_buses`) everything but the mixer.
function applyAll(skip_buses)
  for k, f in pairs(APPLY) do
    if not (skip_buses and k:sub(1, 4) == "vol_") then f() end
  end
end

-- ── the screen ──────────────────────────────────────────────────────────────

local LABEL_W = 150
local VALUE_W = 58

local function label(text)
  return { "text", key = "l", style = "panel/body", w = LABEL_W, h = "fit", text = text }
end

local function line(key, kids)
  return { "row", key = key, w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
           items = kids, function(x) return x end }
end

-- A segmented choice: one button per option, the one in force lit.
local function choice(key, text, opts, cur, pick)
  local btns = {}
  for i, o in ipairs(opts) do
    btns[#btns + 1] = { "button", key = "o" .. i, style = "panel/choice", w = "grow", h = 30,
      textAlign = "center", selected = (o.value == cur), text = o.label,
      onClicked = function()
        if o.value ~= cur then
          local fx = ref("sfx"); if fx then fx.play("click") end
        end
        pick(o.value)
      end }
  end
  return line(key, {
    label(text),
    { "row", key = "c", w = "grow", h = "fit", gap = 6, pad = 0, items = btns, function(x) return x end },
  })
end

local function on_off(key, text, cur, pick)
  return choice(key, text, { { label = "On", value = true }, { label = "Off", value = false } },
    cur == true, pick)
end

-- A draggable slider and its value. `show` formats the number. A fader: a
-- groove, an orange strip for the value and a light cap to drag ("ctl/*"
-- styles); the number is set in the mono face so it holds still as it moves.
local function slider(key, text, lo, hi, cur, show, pick)
  return line(key, {
    label(text),
    { "slider", key = "s", style = "ctl/track", w = "grow", h = 14, min = lo, max = hi, value = cur,
      interact = true,
      onChanged = function(n)
        local sl = n and n:getcomponent("UiSlider")
        if sl and sl.value then pick(sl.value) end
      end,
      { "box", key = "f", style = "ctl/fill", part = "fill", w = "100%", h = "100%" },
      { "box", key = "h", style = "ctl/handle", part = "handle", w = 12, h = 22 },
    },
    { "text", key = "v", style = "ctl/value", w = VALUE_W, h = "fit", textAlign = "end",
      text = show(cur) },
  })
end

local function hint(key, text)
  return { "text", key = key, style = "panel/hint", w = "100%", h = "fit", wrap = true, text = text }
end

local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

-- ── resolution and monitor ──────────────────────────────────────────────────
-- What the Display tab is about to apply: a monitor and a mode on it, stepped
-- through with ‹ › and applied with Apply (a click must not switch the screen
-- mode on every step).
local pick = { mon = nil, i = nil }

-- The monitor's modes, one per size (the highest refresh at each, which is
-- what app.setDisplayMode takes when none is named), largest first.
local function sizes_of(mon)
  local out, seen = {}, {}
  for _, m in ipairs(app.displayModes(mon) or {}) do
    local k = m.width .. "x" .. m.height
    local s = seen[k]
    if not s then
      s = { w = m.width, h = m.height, hz = m.refresh }
      seen[k], out[#out + 1] = s, s
    elseif (m.refresh or 0) > (s.hz or 0) then
      s.hz = m.refresh
    end
  end
  return out
end

local function mode_rows(out)
  local mons = {}
  if app and app.monitors and app.displayModes and app.setDisplayMode then
    mons = app.monitors()
  end
  if #mons == 0 then
    out[#out + 1] = hint("resn", "Resolution follows the window here (the editor, or a run with no window).")
    return
  end
  local saved = get("display")
  if not pick.mon then
    pick.mon = type(saved) == "table" and saved.mon or nil
    for _, m in ipairs(mons) do if not pick.mon and m.current then pick.mon = m.index end end
    pick.mon = pick.mon or mons[1].index
  end
  if #mons > 1 then
    local opts = {}
    for i, m in ipairs(mons) do
      local name = (m.name and m.name ~= "") and m.name or ("Display " .. i)
      opts[#opts + 1] = { label = name, value = m.index }
    end
    out[#out + 1] = choice("mon", "Monitor", opts, pick.mon, function(v)
      if v ~= pick.mon then pick.mon, pick.i = v, nil end
    end)
  end
  local sizes = sizes_of(pick.mon)
  if #sizes == 0 then return end
  if not pick.i then
    local sw, sh = screen_size()
    local want_w = type(saved) == "table" and saved.w or sw
    local want_h = type(saved) == "table" and saved.h or sh
    for i, z in ipairs(sizes) do if z.w == want_w and z.h == want_h then pick.i = i end end
    pick.i = pick.i or 1
  end
  pick.i = math.max(1, math.min(#sizes, pick.i))
  local z = sizes[pick.i]
  local function step(d)
    return function()
      local fx = ref("sfx"); if fx then fx.play("click") end
      pick.i = math.max(1, math.min(#sizes, pick.i + d))
    end
  end
  local sw, sh = screen_size()
  local live = (sw == z.w and sh == z.h)
  out[#out + 1] = line("res", {
    label("Resolution"),
    { "button", key = "dn", style = "panel/choice", w = 30, h = 30, textAlign = "center",
      text = "‹", disabled = pick.i >= #sizes, onClicked = step(1) },
    { "text", key = "v", style = "panel/cellStrong", w = "grow", h = "fit", textAlign = "center",
      text = string.format("%d × %d  ·  %d Hz", z.w, z.h, math.floor((z.hz or 60) + 0.5)) },
    { "button", key = "up", style = "panel/choice", w = 30, h = 30, textAlign = "center",
      text = "›", disabled = pick.i <= 1, onClicked = step(-1) },
    { "button", key = "go", style = "panel/choice", w = 76, h = 30, textAlign = "center",
      text = live and "In use" or "Apply", selected = live, onClicked = function()
        if live then return end
        local fx = ref("sfx"); if fx then fx.play("click") end
        set("display", { w = z.w, h = z.h, hz = z.hz, mon = pick.mon })
      end },
  })
end

local function display_rows(out)
  local gx = ref("graphics")
  local cur = (gx and gx.level and gx.level()) or values.gfx_level or "Medium"
  local opts = {}
  for _, n in ipairs((gx and gx.LEVELS) or LEVELS) do opts[#opts + 1] = { label = n, value = n } end
  out[#out + 1] = choice("gfx", "Graphics quality", opts, cur, function(v) set("gfx_level", v) end)
  if gx and gx.describe then out[#out + 1] = hint("gfxd", gx.describe(cur)) end

  local fs = app and app.fullscreen and app.fullscreen()
  out[#out + 1] = choice("fs", "Window", { { label = "Fullscreen", value = true },
    { label = "Windowed", value = false } }, fs == true, function(v) set("fullscreen", v) end)
  mode_rows(out)
  out[#out + 1] = choice("vs", "Vsync", { { label = "On", value = "On" },
    { label = "Adaptive", value = "Adaptive" }, { label = "Off", value = "Off" } },
    (app and app.vsync and app.vsync()) or get("vsync"), function(v) set("vsync", v) end)
  local hz = refresh_hz()
  out[#out + 1] = choice("cap", "Frame cap", {
    { label = "Off", value = "off" },
    { label = hz and string.format("%d fps", math.floor(hz + 0.5)) or "Display", value = "refresh" },
    { label = hz and string.format("%d fps", math.floor(hz / 2 + 0.5)) or "Half", value = "half" },
  }, get("frame_cap"), function(v) set("frame_cap", v) end)
  out[#out + 1] = on_off("dyn", "Dynamic resolution", get("dynamic_res"),
    function(v) set("dynamic_res", v) end)
  out[#out + 1] = hint("dh", "Dynamic resolution lowers the render scale on its own when a frame "
    .. "runs long, up to the quality level's own. Full screen switches the monitor to the "
    .. "resolution; windowed, the window takes that size. F11 or Alt+Enter also switch "
    .. "fullscreen, and the editor's own window ignores all of it.")
end

local function camera_rows(out)
  out[#out + 1] = slider("fov", "Field of view", 50, 90, get("fov"),
    function(v) return string.format("%d°", math.floor(v + 0.5)) end,
    function(v) set("fov", math.floor(v + 0.5)) end)
  out[#out + 1] = slider("look", "Mouse sensitivity", 0.25, 3.0, get("look"),
    function(v) return string.format("×%.2f", v) end,
    function(v) set("look", math.floor(v * 20 + 0.5) / 20) end)
  out[#out + 1] = on_off("inv", "Invert mouse Y", get("invert_y"), function(v) set("invert_y", v) end)
  out[#out + 1] = hint("ch", "The field of view is vertical. Sensitivity turns the on-foot "
    .. "and flight camera; the orbit map keeps its own drag.")
end

local BUS_LABEL = { Master = "Master", Music = "Music", SFX = "Effects", Ambient = "Ambience",
                    UI = "Interface" }
local function audio_rows(out)
  for _, b in ipairs(BUSES) do
    out[#out + 1] = slider("v" .. b, BUS_LABEL[b] or b, 0, 1, volume(b), pct,
      function(v) set("vol_" .. b, math.floor(v * 100 + 0.5) / 100) end)
  end
  out[#out + 1] = hint("ah", "Music comes and goes: a piece now and then, with long quiet "
    .. "stretches between. Ambience is the wind on worlds with air, and the sea when you are in it.")
end

-- ── the engine's own pages ──────────────────────────────────────────────────
-- Controls (press-to-bind, one row per input action) and Accessibility are the
-- engine's (ui.engineSettings), in Solar's styles. This screen is described
-- every frame, so the page is built with no container of its own and its
-- description (`panel:tree()`) is placed among this tab's rows (0.117.0-rc3).
-- A slot takes ui.make properties as well as a style, so the page is laid out
-- the way every other row here is: a label column, then the value.
local ENGINE_STYLES = {
  page = { gap = 9, pad = 0, w = "100%", h = "fit", align = "start" },
  row = { gap = 10, pad = 0, w = "100%", h = "fit", align = "center" },
  label = { style = "panel/body", w = LABEL_W, h = "fit" },
  button = { style = "panel/choice", w = "grow", h = 30 },
  value = { style = "panel/cell", inset = 0, textAlign = "center", textValign = "center" },
}
-- The engine's names for what it changed → this store's keys.
local ENGINE_KEY = { textScale = "text_scale", colorFilter = "color_filter",
                     reducedMotion = "reduced_motion", captions = "captions" }
local eng = { page = nil, panel = nil }

-- The player's bindings, as input.saveBindings() wrote them, are kept in the
-- store with everything else; `start` puts them back. A rebind on the page, or
-- Reset, writes them (Reset forgets them, so a later input.ron is followed).
local function keep_bindings()
  if not (input and input.saveBindings) then return end
  values.bindings = input.saveBindings()
  pending.bindings = true
  pending_at = clock
end

-- The rebind page told us an action changed (published for a test probe too).
function bindingsChanged(action) keep_bindings() end

-- Every action back to input.ron's binding.
function resetAllBindings()
  if not (input and input.resetBindings) then return end
  input.resetBindings()
  values.bindings = nil
  pending.bindings = true
  pending_at = clock
  if eng.panel and eng.panel.refresh then eng.panel:refresh() end
end

function storedBindings() return values.bindings end

-- Is a rebind waiting for its key (or did Esc just call one off)? The screens
-- that close on Esc ask, so the Esc that cancels a rebind doesn't also shut
-- the settings screen. (A rebind cancelled by Esc is seen by the page a frame
-- later, so the frame it was last seen waiting counts too.)
local waited_at = -1
function rebinding()
  return (eng.panel ~= nil and eng.panel.waiting ~= nil) or clock - waited_at < 0.1
end

-- The page this tab wants (made once; its rows are described every frame).
local function engine_panel(page)
  if eng.panel and eng.page == page then return eng.panel end
  eng.panel, eng.page = nil, page
  if not (ui and ui.engineSettings) then return nil end
  local ok, p = pcall(ui.engineSettings, nil, page, {
    styles = ENGINE_STYLES,
    filter = page == "controls" and "keyboard" or nil,
    onChanged = function(key, value)
      if key == "binding" then keep_bindings() return end
      local k = ENGINE_KEY[key]
      if k then values[k] = value; pending[k] = true; pending_at = clock end
    end,
  })
  if not ok then print("settings: " .. tostring(p)) return nil end
  eng.panel = p
  return p
end

-- The engine page's rows, or nil when this build has none.
local function engine_rows(page)
  local p = engine_panel(page)
  if not (p and p.tree) then return nil end
  return p:tree()
end

-- Actions Solar's scripts read (input.ron also carries the template's fighting
-- motions — qcf, dp… — which nothing here uses and nobody should rebind).
local REBINDABLE = { Jump = true, Interact = true, Sprint = true, Crouch = true, Fire = true,
                     Pause = true, LookEnable = true, ShiftLock = true, Zoom = true }

local function controls_rows(out)
  local page = engine_rows("controls")
  if not page then
    out[#out + 1] = hint("kn", "Rebinding is not available on this engine build.")
    return
  end
  local kept = {}
  for i = 2, #page do
    local r = page[i]
    if type(r) == "table" and REBINDABLE[r.key] then kept[#kept + 1] = r end
  end
  for i = #page, 2, -1 do page[i] = nil end
  for _, r in ipairs(kept) do page[#page + 1] = r end
  out[#out + 1] = page
  out[#out + 1] = line("kreset", {
    label(""),
    { "button", key = "reset", style = "panel/choice", w = "grow", h = 30, textAlign = "center",
      text = "Reset to defaults", disabled = values.bindings == nil, onClicked = function()
        local fx = ref("sfx"); if fx then fx.play("click") end
        resetAllBindings()
      end },
  })
  out[#out + 1] = hint("kh", "Click an action, then press its new key; Esc cancels. The new key "
    .. "replaces the old one and is kept for next time. This reaches the input actions only: "
    .. "most of Solar's keys are fixed for now, and the Controls page of the pause menu lists them.")
end

local function access_rows(out)
  if not access then
    out[#out + 1] = hint("na", "Accessibility options are not available on this engine build.")
    return
  end
  local page = engine_rows("accessibility")
  if page then
    out[#out + 1] = page
    out[#out + 1] = hint("xh", "Click a value to step through it. Captions name the sounds a "
      .. "flight tells you by ear alone; reduced motion stills the camera shake; the colour "
      .. "filter corrects for protanopia, deuteranopia or tritanopia.")
    return
  end
  local ts = (access.textScale and access.textScale()) or 1.0
  out[#out + 1] = choice("ts", "Text size", {
    { label = "90%", value = 0.9 }, { label = "100%", value = 1.0 },
    { label = "125%", value = 1.25 }, { label = "150%", value = 1.5 },
  }, math.floor(ts * 100 + 0.5) / 100, function(v) set("text_scale", v) end)
  out[#out + 1] = on_off("cc", "Captions", access.captions and access.captions(),
    function(v) set("captions", v) end)
  out[#out + 1] = on_off("rm", "Reduced motion", access.reducedMotion and access.reducedMotion(),
    function(v) set("reduced_motion", v) end)
  local opts = {}
  local SHORT = { none = "Off", protanopia = "Protan", deuteranopia = "Deutan", tritanopia = "Tritan" }
  for _, f in ipairs((access.filters and access.filters()) or {}) do
    opts[#opts + 1] = { label = SHORT[f.name] or f.name, value = f.name }
  end
  if #opts > 0 then
    out[#out + 1] = choice("cf", "Colour filter", opts,
      (access.colorFilter and access.colorFilter()) or "none", function(v) set("color_filter", v) end)
  end
  out[#out + 1] = hint("xh", "Captions name the sounds a flight tells you by ear alone. Reduced "
    .. "motion stills the camera shake. The colour filter corrects for protanopia, "
    .. "deuteranopia or tritanopia. Keys are listed on the pause menu's Controls page.")
end

local TABS = {
  { id = "display", label = "Display", build = display_rows },
  { id = "camera", label = "Camera", build = camera_rows },
  { id = "controls", label = "Controls", build = controls_rows, engine = "controls" },
  { id = "audio", label = "Audio", build = audio_rows },
  { id = "access", label = "Accessibility", build = access_rows, engine = "accessibility" },
}
local rows_at = -1   -- our clock when a screen last asked for the rows (it is up)

function showTab(id) for _, t in ipairs(TABS) do if t.id == id then tab = id end end end
function currentTab() return tab end

-- The screen's rows, for a frame `w` design units wide. A table of ui.make
-- element tables; the caller adds its own heading and Back button.
function rows(w)
  rows_at = clock
  local bar = {}
  for _, t in ipairs(TABS) do
    if not t.hidden then bar[#bar + 1] = { "button", key = t.id, style = "panel/choice", w = "grow", h = 30,
      textAlign = "center", selected = (t.id == tab), text = t.label,
      onClicked = function()
        if tab ~= t.id then local fx = ref("sfx"); if fx then fx.play("click") end end
        tab = t.id
      end } end
  end
  local out = {
    { "row", key = "tabs", w = "100%", h = "fit", gap = 6, pad = 0, items = bar, function(x) return x end },
    { "box", key = "tabgap", w = 1, h = 4 },
  }
  for _, t in ipairs(TABS) do
    if t.id == tab then
      local body = {}
      t.build(body)
      out[#out + 1] = { "col", key = "body_" .. t.id, w = "100%", h = "fit", gap = 9, pad = 0,
                        align = "start", items = body, function(x) return x end }
    end
  end
  out[#out + 1] = hint("saved", "Saved as you change them, for every save on this machine.")
  return out
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  values, pending, pending_at = {}, {}, nil
  load_all()
  applyAll(buses_held())
end

function update(node, dt)
  clock = clock + (dt or 0)
  -- The engine page of the open tab is polled every frame (a key pressed to
  -- bind arrives between frames) and let go when the screen closes or the tab
  -- changes; a rebind still waiting for its key is called off then.
  local want = nil
  if clock - rows_at < 0.25 then
    for _, t in ipairs(TABS) do if t.id == tab then want = t.engine end end
  end
  if eng.panel and eng.page == want then
    if eng.panel.waiting then waited_at = clock end
    eng.panel:update()
  elseif eng.panel then
    if eng.panel.waiting and input and input.cancelRebind then input.cancelRebind() end
    eng.panel, eng.page = nil, nil
  end
  -- A slider fires every frame it moves; the store is written once it rests.
  if pending_at and clock - pending_at > 0.5 then flush() end
  -- The scene camera can be rebuilt under us (a craft's own camera taking
  -- over and handing back); re-assert the field of view now and then.
  if math.floor(clock * 2) ~= math.floor((clock - (dt or 0)) * 2) then apply_fov() end
end

function onDestroy(node) flush() end
