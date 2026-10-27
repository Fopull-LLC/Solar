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
-- bundles of those knobs, cheapest first.
--
-- A NEW PLAYER STARTS ON MEDIUM, at every screen size. (It used to be High up
-- to 1080p.) Until the engine marches its volumetric fog at half resolution,
-- High's lit fog alone costs 24–30 ms of GPU at 1080p on an RTX 4060, so High
-- missed 60 fps on exactly the screens it was picked for; Medium holds 60.
-- There is no hardware probe here: a machine too weak even for Medium is
-- caught by the auto-lower below, which is allowed down to Low only when the
-- game is badly slow. A saved choice is always the player's and is never
-- changed by this default.
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
--   gx.setScale(v)       the player's render scale over the level's (nil = the level's)
--   gx.scaleOf(name)     the render scale a level runs at, the player's included
--   gx.volumetric        read by atmosphere.lua: may it march volumetric fog?
--   gx.shafts            … and the sun shafts through it?
--   gx.notice            a sentence to show the player, or nil (+ gx.noticeAt)
--   gx.shadowScale       the world-size factor on the level's shadow distance
--   gx.flare, gx.dof     does this level draw the sun flare / the far-field blur?
--   gx.setLook(k, on)    the player's switches: "flare", "dof" (settings.lua)
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
-- THE LENS (post, on the scene's Post Processing node, re-asserted here so a
-- level is one bundle). See the LOOK section below for what each one is for.
--   bloom      { threshold, intensity }: only light past `threshold` glows
--   flare      the sun flare pass (sun_flare.lua, shaders/sunFlare.flsl)
--   dof        the depth of field: max px at 1080p, and taps; nil = off
local PRESETS = {
  Low    = { scale = 0.60, sharpen = 0.6, shadows = true, shadowDistance = 70,  volumetric = false, shafts = false, fogSteps = 8,
             bloom = { 1.6, 0.30 }, flare = false, dof = nil,
             text = "For older or integrated graphics. Softer image, short shadows, plain haze." },
  Medium = { scale = 0.90, sharpen = 0.25, shadows = true, shadowDistance = 140, volumetric = false, shafts = false, fogSteps = 12,
             bloom = { 1.6, 0.35 }, flare = true, dof = { 3.25, 10 },
             text = "Balanced. Sharp enough for most screens, holds 60 fps on a mid-range card." },
  High   = { scale = 1.00, shadows = true, shadowDistance = 220, volumetric = true,  shafts = false, fogSteps = 12,
             bloom = { 1.6, 0.35 }, flare = true, dof = { 4.0, 14 },
             text = "Full resolution, volumetric air and a soft far distance. Wants a strong graphics card." },
  Ultra  = { scale = 1.00, shadows = true, shadowDistance = 400, volumetric = true,  shafts = true,  fogSteps = 16,
             bloom = { 1.6, 0.35 }, flare = true, dof = { 4.5, 16 },
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
flare, dof = false, false
local look_on = { flare = true, dof = true }   -- the player's switches
notice, noticeAt = nil, -1

local current = nil
local lit = nil
shadowScale = 1.0
local scale_t = -100
local slow_for, lowered = 0, false
local ema = nil            -- smoothed frame time, seconds
local map_ref, bf_ref = nil, nil

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

-- The player's render scale (Settings ▸ Display ▸ Render scale), over every
-- level's own: nil = the level's. A level still sets everything else.
local scale_pick = nil
local function scale_of(p)
  local s = scale_pick or p.scale
  return math.max(0.25, math.min(1.0, s))
end
-- The upscale's sharpening for a scale: the level's at its own scale, else
-- harder the bigger the stretch (Medium's 0.25 at 90%, Low's 0.6 at 60%),
-- none at native.
local function sharpen_of(p, s)
  if not scale_pick then return p.sharpen or 0.4 end
  if s >= 0.999 then return 0.0 end
  return math.max(0.2, math.min(0.7, 0.25 + (0.9 - s) * (0.35 / 0.3)))
end

local function apply_dynamic(p)
  if not app.setDynamicResolution then return end
  local s = scale_of(p)
  if dynamic then
    pcall(app.setDynamicResolution, { min = math.max(0.25, s * 0.5), max = s })
  else
    pcall(app.setDynamicResolution, false)
    if app.setRenderScale then app.setRenderScale(s) end
  end
end


-- ── THE LOOK: bloom, the sun flare, the far-field blur ──────────────────────
--
-- BLOOM is for light, not for daylight. The bright-pass is a hard threshold on
-- luminance in the scene's own (linear, pre-tonemap) light, so the threshold
-- says what counts as a light source. At 1.0 a sunlit pale rock, a snowfield
-- or a white hangar wall passed it and the whole day wore a milky halo; at 1.6
-- they do not, and what does is what makes its own light — the star's disc,
-- the tools' energy parts (tool_energy `power` 3), lamps, exhaust, the
-- lightning flash. The intensity went up a little to give those their glow.
--
-- THE FAR FIELD. "Grainy at distance" (measured 2026-10-26, engine rc33,
-- tools/perf/gfx.sh): a still frame shows a per-pixel speckle on the ground
-- from ~40 m out, the same with AO off, the fog dither off, the upscale's
-- sharpening off and at render scale 1, and nothing changes between two
-- frames of a still camera, so it is spatial aliasing that crawls as the
-- camera moves. Its cause is the terrain's textures: the engine keeps the
-- terrain palette as a texture array with ONE mip level, and a palette
-- texture with no import setting is sampled nearest-neighbour, so a 256 px
-- tile 4.5 m across, seen 60 m off, puts 3–4 texels in every pixel and picks
-- one of them at random. The engine has no anti-aliasing pass to hide it.
-- (Engine card: mipmapped terrain palette; .floptle/textures.ron can at least
-- ask for linear filtering.) Here: Medium and up add a depth of field that
-- focuses on what the camera is looking at: the crew (or the craft) it
-- orbits, or in first person and the free camera what is in the middle of the
-- view. Nothing nearer than the focus is touched (the near range is set
-- beyond anything on screen, and the engine leaves an in-focus pixel exactly
-- alone, not filtered). Past it the blur ramps over `range` to 3–4.5 px at
-- 1080p: the focus is the subject's distance × 1.25 + 6 m (12–60 m) in third
-- person, or the distance the view's middle meets (at least 12 m) in first
-- person and the free camera; the range 2.2× that and at least 140 m, so on foot the middle distance
-- (80–300 m) softens and the far hills are fully soft. (It was a fixed 65 m
-- focus and a 160 m range to 1.75 px, which did next to nothing on the
-- ground and showed only from the air.) The focus moves out with height
-- (0.6 × the altitude), and it fades out in thin air and at night (a blurred
-- star field is wrong, and in space everything is far). In the VAB the focus
-- follows the builder camera's distance to its pivot at the old gentle
-- strength, so the craft is sharp and the hangar softens a touch. The upscale's sharpening
-- at Medium is gentler too (0.25, was 0.4): it was sharpening the speckle.
--
-- Measured costs are in tools/perf/results/gfx_look.md.
local post_ref, post_level = nil, nil
local cam_node = nil       -- "Camera 1" (world_scale finds it)
local flare_ref = nil
local at_ref2, bc_ref, gm_ref2, look_t = nil, nil, nil, -100
local dof_cur = nil        -- what was last written: focus, range, blur

local function post()
  if not (post_ref and post_ref.node and post_ref.node.valid) then
    local n = find and find("Post Processing")
    local c = n and n:getcomponent("PostProcess")
    post_ref = c and { node = n, c = c } or nil
    post_level, dof_cur = nil, nil      -- a new node: everything is written again
  end
  return post_ref and post_ref.c
end

function setLook(k, on)
  if look_on[k] == nil then return end
  look_on[k] = on ~= false
  post_level = nil
end

-- Bloom and the flare: once per level change (and on a scene rebuild).
local function apply_post(p)
  local pc = post()
  if not pc then return end
  local key = level() .. tostring(look_on.flare)
  if post_level == key and math.abs((pc.bloomThreshold or 0) - p.bloom[1]) < 1e-3 then return end
  post_level = key
  pc.bloom = true
  pc.bloomThreshold = p.bloom[1]
  pc.bloomIntensity = p.bloom[2]
  if not (flare_ref and flare_ref.valid ~= false) then flare_ref = findScript and findScript("sun_flare") or nil end
  if flare_ref and flare_ref.setOn then flare_ref.setOn(p.flare == true and look_on.flare) end
end

local function smooth01(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end

-- What the camera is looking at, in metres: the crew (or the craft) it
-- orbits in third person; in first person, the cockpit and the free camera,
-- whatever is in the middle of the view (a ray, four times a second, eased).
local pc_ref3, astro_ref, look_ray_t, look_d = nil, nil, -100, 20
local function subject_distance(cx, cy, cz)
  if not (pc_ref3 and pc_ref3.valid ~= false) then pc_ref3 = findScript and findScript("planet_camera") or nil end
  local pc = pc_ref3
  if pc and not pc.firstPerson and not pc.cockpit and not pc.freecam and pc.pivot_x then
    local dx, dy, dz = (pc.pivot_x or cx) - cx, (pc.pivot_y or cy) - cy, (pc.pivot_z or cz) - cz
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d > 0.5 then return d, false end
  end
  if pc and pc.cockpit then return 25, false end
  if time - look_ray_t > 0.25 and raycast and cam_node.worldForward then
    look_ray_t = time
    local f = cam_node:worldForward()
    if not (astro_ref and astro_ref.valid) then astro_ref = find("Astronaut") end
    local hit = raycast(vec3(cx, cy, cz), f, 400, astro_ref and { ignore = astro_ref } or nil)
    local want = hit and math.max(2, hit.distance or 400) or 400
    look_d = look_d + (want - look_d) * 0.5
  end
  return look_d, true
end

-- The far-field blur for this frame: focus, range (m) and blur (px), or nil.
local function dof_want(p)
  if not (p.dof and look_on.dof) then return nil end
  if time - look_t > 1.0 then
    look_t = time
    if not (at_ref2 and at_ref2.valid ~= false) then at_ref2 = findScript("atmosphere") end
    if not (gm_ref2 and gm_ref2.valid ~= false) then gm_ref2 = findScript("game_manager") end
    if not (bc_ref and bc_ref.valid ~= false) then bc_ref = findScript("builder_camera") end
    if not (map_ref and map_ref.valid ~= false) then map_ref = findScript("orbit_map") end
  end
  if map_ref and map_ref.map_view then return nil end
  -- (The seat view's cabin is a stacked camera drawn after depth of field,
  -- post = "after" in planet_camera, so the blur reaches only the world
  -- outside the windows.)
  local px = p.dof[1]
  if camera and camera.screenSize then
    local _, h = camera.screenSize()
    if h and h > 0 then px = px * h / 1080 end
  end
  -- The VAB: the craft sharp, the hangar behind it a touch soft (as gentle
  -- as it always was: the builder is a workbench, not a photograph).
  if gm_ref2 and gm_ref2.inputOwner == "builder" and bc_ref and bc_ref.dist then
    local d = math.max(1, bc_ref.dist)
    return d * 1.3, d * 2.0 + 10, math.min(px * 0.8, px / p.dof[1] * 1.4)
  end
  if not (cam_node and cam_node.valid) then return nil end
  local at = at_ref2
  local rho = at and (at.rho_now or 0) or 0
  local day = at and smooth01(-0.15, 0.15, at.sun_now or 1) or 1
  local k = smooth01(0.05, 0.4, rho) * day
  if k < 0.02 then return nil end
  local cx, cy, cz = cam_node.x, cam_node.y, cam_node.z
  local alt = 0
  if space and space.dominant then
    local d = space.dominant(cx, cy, cz)
    local b = d and space.body(d)
    if b and b.radius then
      local dx, dy, dz = cx - b.x, cy - b.y, cz - b.z
      alt = math.max(0, math.sqrt(dx * dx + dy * dy + dz * dz) - b.radius)
    end
  end
  local sub, looked = subject_distance(cx, cy, cz)
  -- The subject sharp, and everything from just past it softening over a
  -- few hundred metres: the middle distance (80–300 m on foot) goes soft,
  -- the far hills fully, and the subject and the ground round it are left
  -- exactly alone. Up in the air the focus moves out with the height, so
  -- the ground under a craft is softer than a walker's but still reads.
  -- (in first person and the free camera the subject is what the view's
  -- middle meets, however far: that is what is focused on)
  local focus
  if looked then focus = math.max(12, sub) + 0.2 * alt
  else focus = math.max(12, math.min(60, sub * 1.25 + 6)) + 0.6 * alt end
  local range = math.max(140, focus * 2.2)
  return focus, range, px * k
end

local function apply_dof(p)
  local pc = post()
  if not pc then return end
  local f, r, b = dof_want(p)
  if not f or b < 0.75 then
    if dof_cur ~= false then pc.dofFocus = 0; pc.dofBlur = 0; dof_cur = false end
    return
  end
  local c = dof_cur
  if c and math.abs(c[1] - f) < f * 0.03 and math.abs(c[2] - r) < r * 0.03 and math.abs(c[3] - b) < 0.05 then return end
  dof_cur = { f, r, b }
  pc.dofFocus = f
  pc.dofRange = r
  pc.dofNearRange = 1e6          -- nothing in front of the focus ever blurs
  pc.dofBlur = b
  pc.dofSamples = p.dof[2]
  pc.dofHighlight = 0
end

local function apply(name)
  local p = PRESETS[name] or PRESETS[DEFAULT]
  current = PRESETS[name] and name or DEFAULT
  volumetric, shafts = p.volumetric, p.shafts
  flare, dof = p.flare == true, p.dof ~= nil
  post_level = nil
  local sc = scale_of(p)
  if app.setRenderScale then app.setRenderScale(sc) end
  -- The upscale from a lowered scale sharpens edges (0.102); a bigger stretch
  -- wants a harder hand, and at 1.0 there is nothing to sharpen.
  if app.setRenderSharpness then app.setRenderSharpness(sharpen_of(p, sc)) end
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

function scaleOf(name) return scale_of(PRESETS[name or level()] or PRESETS[DEFAULT]) end

-- Called by settings.lua (the Render scale row): a number 0.25–1, or nil for
-- the level's own. Applied at once; settings.lua keeps it in the store.
function setScale(v)
  v = tonumber(v)
  if v then v = math.max(0.25, math.min(1.0, v)) end
  if v == scale_pick then return end
  scale_pick = v
  apply(level())
end

function set(name)
  if not PRESETS[name] then return false end
  apply(name)
  with_settings(function() save.set("gfx_level", name); save.flush() end)
  slow_for = 0
  return true
end

function start(node)
  local got = with_settings(function()
    return { level = save.get("gfx_level", nil), dyn = save.get("opt_dynamic_res", false),
             rscale = save.get("opt_render_scale", nil),
             flare = save.get("opt_lens_flare", true), dof = save.get("opt_far_blur", true) }
  end) or {}
  look_on.flare = got.flare ~= false
  look_on.dof = got.dof ~= false
  local saved = got.level
  dynamic = got.dyn == true
  scale_pick = tonumber(got.rscale)
  if scale_pick then scale_pick = math.max(0.25, math.min(1.0, scale_pick)) end
  -- nothing saved: a first run, on Medium whatever the screen (see the header)
  apply(saved or DEFAULT)
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
  apply_post(p)
  apply_dof(p)


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
