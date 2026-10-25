-- GRAPHICS — one quality setting, and what it costs.
--
-- Measured on the home world of a real save (sea, flora, thick air) in a
-- 1920×1052 window on an RTX 4060, fps_probe, vsync off:
--
--   volumetric fog + sun shafts      46 ms   ← what every save used to get
--   volumetric fog, no shafts        22 ms
--   distance fog                     21 ms
--     + shadow distance 150          18 ms
--     + render scale 0.75            12 ms
--   no sun shadows at all             4 ms
--
-- So the frame was almost all lighting: the shaft march alone was half of it,
-- and the terrain's distance-field sun shadow is most of what remains. Both
-- are per-pixel costs, which is why render scale is the strong lever and why a
-- 1440p editor view fell to a few frames a second. (Engine 0.117.0-rc25, with
-- the sun shadow MAP: shadows are 1–2 ms; the lit volumetric fog is now the
-- whole difference between High and Medium — 13–20 ms of a 20–30 ms GPU frame
-- at 1920×1052, see tools/perf/results/gpu_rc25.md.) The level names below are
-- bundles of those knobs, cheapest first. With nothing saved, a screen up to
-- 1080p starts on High and a larger one on Medium, the level that holds 60 fps
-- at 1440p on a mid-range card.
--
-- The choice is the PLAYER'S, not the save's, so it lives in its own store
-- slot ("settings") rather than in whichever save slot is loaded.
--
-- If the machine cannot hold the level it is on (frames over ~33 ms for a few
-- seconds, once the world has loaded), this steps down ONE level, once per
-- session, and says so through `notice` — a game that silently plays at
-- 5 fps reads as broken, one that tells you it lowered a setting reads as
-- looked after. The step is for this session only: one bad stretch (a
-- streaming spike, another program busy) must not ratchet the saved level down
-- a notch every time the game is played. Choosing a level in Settings saves it.
--
-- Cross-script:
--   local gx = findScript("graphics")
--   gx.LEVELS            { "Low", "Medium", "High", "Ultra" }
--   gx.level()           the current level's name
--   gx.set("High")       apply + remember
--   gx.describe(name)    one line for a settings screen
--   gx.setDynamic(on)    engine dynamic resolution, capped at the level's scale
--   gx.volumetric        read by atmosphere.lua: may it march volumetric fog?
--   gx.shafts            … and the sun shafts through it?
--   gx.notice            a sentence to show the player, or nil (+ gx.noticeAt)
--   gx.shadowScale       the world-size factor on the level's shadow distance
--
-- SHADOW DISTANCE AND WORLD SIZE. The levels' distances were set on 250–400 m
-- worlds. A scale-3 world is 600–950 m across: from a hill or low flight the
-- ground in view runs out to many hundreds of metres, and past the shadow
-- distance it went flat (no relief shading on the far ridges, which is half
-- of what reads as haze). The distance is the level's, times the radius of
-- the world under the camera over 320 m (never less than 1, at most 2.6), so
-- a small world keeps exactly the distances that were measured above. With
-- the shadow MAP (system.ron) a longer reach costs map texels, not frame time.

LEVELS = { "Low", "Medium", "High", "Ultra" }

-- fogSteps: samples along each pixel's volumetric fog ray (the engine's
-- quality/cost dial; only the volumetric levels pay it). Measured on engine
-- 0.117.0-rc25 at 1920×1052 on the home world (tools/perf/results/gpu_rc25.md):
-- the lit march is 13–20 ms of a 20–30 ms GPU frame at 16 steps, and 12 steps
-- are 3–5 ms cheaper with no pixel of a daylight meadow changed; 8 would save
-- twice that but thins thick ground mist. Ultra keeps the full 16.
local PRESETS = {
  Low    = { scale = 0.60, sharpen = 0.6, shadows = true, shadowDistance = 70,  volumetric = false, shafts = false, fogSteps = 8,
             text = "For older or integrated graphics. Softer image, short shadows, plain haze." },
  Medium = { scale = 0.90, shadows = true, shadowDistance = 140, volumetric = false, shafts = false, fogSteps = 12,
             text = "Balanced. Sharp enough for most screens, holds 60 fps on a mid-range card." },
  High   = { scale = 1.00, shadows = true, shadowDistance = 220, volumetric = true,  shafts = false, fogSteps = 12,
             text = "Full resolution and volumetric air. Wants a strong graphics card." },
  Ultra  = { scale = 1.00, shadows = true, shadowDistance = 400, volumetric = true,  shafts = true,  fogSteps = 16,
             text = "Adds sun shafts through the air. Very expensive at high resolutions." },
}
local DEFAULT = "Medium"

defaults = {
  --- Step down a level on its own when the frame rate cannot be held.
  autoLower = true,
  --- Smoothed frame time (ms) that counts as "not holding it". Above 33.3 on
  --- purpose: under vsync a frame that just misses one refresh is shown for
  --- two (33.3 ms at 60 Hz), and a game that misses the odd refresh is not a
  --- game that needs a blurrier picture.
  --@range 20 100
  slowMs = 42.0,
}

volumetric, shafts = false, false
notice, noticeAt = nil, -1

local current = nil
local lit = nil
shadowScale = 1.0
local scale_t = -100
local slow_for, lowered = 0, false
local ema = nil            -- smoothed frame time, seconds
local map_ref, bf_ref = nil, nil
local pick_default = false -- no saved choice: pick one for this screen once it is known

local function light()
  if not lit then
    local ln = find("Lighting")
    lit = ln and ln:getcomponent("Light") or nil
  end
  return lit
end

-- The settings slot, read or written without losing the save that is loaded.
local function with_settings(fn)
  local cur = save.slot()
  if cur == "settings" then return fn() end
  save.slot("settings")
  local ok, r = pcall(fn)
  save.slot(cur)
  if not ok then print("graphics: " .. tostring(r)) end
  return r
end

-- Dynamic resolution (the Settings screen's switch, settings.lua): the engine
-- picks the render scale per frame from the GPU time. The level's own scale is
-- its ceiling, so High never renders above native and Low never above 0.6;
-- the floor is half of that. `app.setRenderScale` turns it off (a scale chosen
-- outright is the game's decision), so it is switched back on after every
-- apply.
local dynamic = false

local function apply_dynamic(p)
  if not app.setDynamicResolution then return end
  if dynamic then
    pcall(app.setDynamicResolution, { min = math.max(0.25, p.scale * 0.5), max = p.scale })
  else
    pcall(app.setDynamicResolution, false)
    if app.setRenderScale then app.setRenderScale(p.scale) end
  end
end

local function apply(name)
  local p = PRESETS[name] or PRESETS[DEFAULT]
  current = PRESETS[name] and name or DEFAULT
  volumetric, shafts = p.volumetric, p.shafts
  if app.setRenderScale then app.setRenderScale(p.scale) end
  -- The upscale from a lowered scale sharpens edges (0.102); a bigger stretch
  -- wants a harder hand, and at 1.0 there is nothing to sharpen.
  if app.setRenderSharpness then app.setRenderSharpness(p.sharpen or 0.4) end
  if dynamic then apply_dynamic(p) end
  local l = light()
  if l then
    l.shadows = p.shadows
    l.shadowDistance = p.shadowDistance * shadowScale
    if p.fogSteps then l.fogSteps = p.fogSteps end
  end
end

-- The world under the camera: its radius sets `shadowScale` (see the header).
-- Once a second; nil-safe off every world.
local cam_node = nil
local function world_scale()
  if time - scale_t < 1.0 then return end
  scale_t = time
  if not (cam_node and cam_node.valid) then cam_node = find and find("Camera 1") or nil end
  local k = 1.0
  if cam_node and cam_node.valid and space and space.dominant then
    local d = space.dominant(cam_node.x, cam_node.y, cam_node.z)
    local b = d and space.body(d)
    if b and (b.soi or 0) >= 0 and b.radius then
      k = math.max(1.0, math.min(2.6, b.radius / 320))
    end
  end
  shadowScale = k
end

function level() return current or DEFAULT end

-- Called by settings.lua when the player flips the switch (and at startup).
function setDynamic(on)
  on = on == true
  if on == dynamic then return end
  dynamic = on
  apply_dynamic(PRESETS[level()] or PRESETS[DEFAULT])
end

function describe(name) return (PRESETS[name] or PRESETS[DEFAULT]).text end

function set(name)
  if not PRESETS[name] then return false end
  apply(name)
  with_settings(function() save.set("gfx_level", name); save.flush() end)
  slow_for = 0
  return true
end

function start(node)
  local got = with_settings(function()
    return { level = save.get("gfx_level", nil), dyn = save.get("opt_dynamic_res", false) }
  end) or {}
  local saved = got.level
  dynamic = got.dyn == true
  pick_default = saved == nil
  apply(saved or DEFAULT)
end

-- A first run with no saved choice: full resolution up to 1080p, where it is
-- cheap and where a softened picture shows most; Medium above that.
local function choose_default()
  if not pick_default or not (camera and camera.screenSize) then return end
  local _, h = camera.screenSize()
  if not h or h <= 0 then return end
  pick_default = false
  apply(h <= 1100 and "High" or "Medium")
end

function update(node, dt)
  -- Scene nodes can be rebuilt under us (a scene load keeps this script only
  -- if it rides the swap), so the light is re-asserted rather than trusted.
  world_scale()
  local l = light()
  local p = PRESETS[level()]
  local want = p.shadowDistance * shadowScale
  if l and (math.abs((l.shadowDistance or 0) - want) > 0.5 or l.shadows ~= p.shadows) then
    l.shadows = p.shadows
    l.shadowDistance = want
  end
  if l and p.fogSteps and l.fogSteps ~= p.fogSteps then l.fogSteps = p.fogSteps end

  choose_default()

  if not params.autoLower or lowered then return end
  ema = ema and (ema + (dt - ema) * math.min(1, dt * 2)) or dt
  -- Only judge steady play: the loading hold and the first streamed-in
  -- seconds, the base going up, time warp (the whole galaxy fast-forwarding)
  -- and the orbit map are slow on every machine and say nothing about this one.
  if not (map_ref and map_ref.valid ~= false) and findScript then map_ref = findScript("orbit_map") end
  local map = map_ref
  if not (bf_ref and bf_ref.valid ~= false) and findScript then bf_ref = findScript("base_facilities") end
  local landing = bf_ref and bf_ref.sited == false
  if (terrain.busy and terrain.busy()) or time < 20 or (space.warp and space.warp() > 1)
      or (map and map.map_view) or landing then
    slow_for = 0
    return
  end
  if ema * 1000 > (params.slowMs or 42.0) then slow_for = slow_for + dt else slow_for = 0 end
  if slow_for > 8.0 then
    local i = 1
    for k, n in ipairs(LEVELS) do if n == level() then i = k end end
    -- Medium is as far as it goes on its own unless the game is badly slow:
    -- Low is a picture the player should choose, not wake up to.
    local floor = ema * 1000 > 70 and 1 or 2
    lowered = true
    if i > floor then
      local was = level()
      apply(LEVELS[i - 1])
      notice = string.format("Graphics lowered from %s to %s to keep the game smooth. Choose a level in Settings (ESC) to keep one.",
        was, level())
      noticeAt = time
      print("graphics: " .. notice)
    end
  end
end
