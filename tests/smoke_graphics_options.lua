-- SMOKE HARNESS: the Graphics tab's options reach what they promise.
--
--   luajit solar/tests/smoke_graphics_options.lua
--
-- settings.lua holds the options (GFX_OPTIONS: each level's value, and the
-- player's own on top); graphics.lua applies them, live. Held here:
--   * every level sets every option, and a single change is an override
--     ("Custom") that a preset clears again
--   * each option reaches its engine call or the script it drives (the
--     Lighting node, the Post Processing node, app.*, decals, terrain, the
--     flora and rock fields, vehicle effects, the crew portraits)
--   * another script's value set on purpose (a probe, a scene) is left alone
--   * the store is a FILE (user://settings.json), never a save-slot switch
--     (each switch waited for the game's save to reach the disk), and an
--     older install's settings slot is carried over once

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── engine ──────────────────────────────────────────────────────────────────
local slots = { slot1 = { big = true }, settings = { gfx_level = "High", opt_vol_Master = 0.5, opt_far_blur = false } }
local active = "slot1"
local switches = 0
local save = {
  slot = function(n) if n then if n ~= active then switches = switches + 1 end; active = n; slots[n] = slots[n] or {} end return active end,
  get = function(k, d) local v = slots[active][k]; if v == nil then return d end return v end,
  set = function(k, v) slots[active][k] = v end,
  delete = function(k) slots[active][k] = nil end,
  flush = function() return true end,
}
local files = {}
local assets = {
  readJson = function(p) local v = files[p]; if v == nil then return nil, "missing" end; return v end,
  writeJson = function(p, v) files[p] = v; return true end,
}
local A = { scale = 1, sharp = 0.4, aa = "Fxaa", dyn = nil }
local app = {
  setRenderScale = function(s) A.scale = s end, renderScale = function() return A.scale end,
  setRenderSharpness = function(s) A.sharp = s end,
  setAntialias = function(m) A.aa = m end, antialias = function() return A.aa end,
  setDynamicResolution = function(o) A.dyn = o end,
  setVsync = function() end, vsync = function() return "On" end, setFrameCap = function() end,
}
local decal_max, tbudget = 1024, "unset"
local light = { shadows = false, shadowDistance = 0, fogSteps = 0, contactShadows = false, reflections = false }
local post = { aoStrength = 0.85, bloom = true, bloomThreshold = 1, bloomIntensity = 0.25, motionBlur = 0 }
local lnode = { valid = true, getcomponent = function() return light end }
local pnode = { valid = true, getcomponent = function() return post end }
local flora = { valid = true, node = { id = 11 }, params = { reach = 1.0, max_props = 6000 } }
local rocks = { valid = true, node = { id = 12 }, params = { reach = 0.8 } }
local vfx = { valid = true, node = { id = 13 }, params = {} }
local strip = { valid = true, node = { id = 14 }, RT_BUDGET = 12 }
local flare_on = nil
local sunflare = { valid = true, setOn = function(on) flare_on = on end }

local scripts = {}
local function env_for(file)
  local env
  env = setmetatable({
    save = save, assets = assets, app = app, time = 0, params = {},
    decals = { setMax = function(n) decal_max = n end },
    terrain = { busy = function() return false end, setBudget = function(b) tbudget = b end },
    space = {}, camera = { screenSize = function() return 1920, 1080 end },
    find = function(name)
      if name == "Lighting" then return lnode end
      if name == "Post Processing" then return pnode end
      if name == "Astronaut" then return { valid = true } end
    end,
    findScript = function(kind)
      if kind == "flora_field" then return flora end
      if kind == "mineral_field" then return rocks end
      if kind == "vehicle_fx" then return vfx end
      if kind == "crew_strip" then return strip end
      if kind == "sun_flare" then return sunflare end
      local e = scripts[kind]
      if e then return setmetatable({ valid = true }, { __index = e, __newindex = e }) end
      return nil
    end,
  }, { __index = _G })
  local chunk = assert(loadfile(file))
  setfenv(chunk, env)
  chunk()
  env.params = env.defaults or {}
  return env
end
local st = env_for("solar/scripts/settings.lua")
scripts.settings = st
local gx = env_for("solar/scripts/graphics.lua")
scripts.graphics = gx
local function frames(n) for _ = 1, n do gx.time = gx.time + 0.5; st.update({}, 0.5); gx.update({}, 0.5) end end

-- ── 1. AN OLDER INSTALL: the settings slot carried over, once, into the file ──
gx.start({})
st.start({})
frames(4)
ok(gx.level() == "High", "the old slot's level is carried over (got " .. gx.level() .. ")")
ok(st.get("vol_Master") == 0.5, "...and its volumes")
ok(st.gfxOverride("dof") == false, "...and an Off distance blur becomes an override")
ok(type(files["user://settings.json"]) == "table" and files["user://settings.json"].gfx_level == "High",
  "the carried-over settings are written to user://settings.json")
local sw0 = switches
-- ── 2. A SCENE LOAD reads the file, never the slot ───────────────────────────
st = env_for("solar/scripts/settings.lua"); scripts.settings = st
gx = env_for("solar/scripts/graphics.lua"); scripts.graphics = gx
gx.start({})          -- graphics may start first: it asks settings to load
st.start({})
frames(4)
ok(switches == sw0, string.format("a scene load switches no save slot (%d switches)", switches - sw0))
ok(gx.level() == "High" and st.get("vol_Master") == 0.5, "...and reads the same settings from the file")

-- ── 3. THE LEVEL sets every option; one change is Custom; a preset clears it ──
st.set("gfx_level", "Ultra"); frames(3)
ok(not st.gfxCustom(), "a preset is not Custom (the old Off blur is cleared with it)")
ok(light.contactShadows == true and light.reflections == true, "Ultra: contact shadows and reflections on")
ok(light.fogSteps == 16 and gx.volumetric == true and gx.shafts == true, "Ultra: volumetric air, 16 steps, shafts")
ok(math.abs(light.shadowDistance - 400) < 1, "Ultra: 400 m of shadow (got " .. light.shadowDistance .. ")")
ok(decal_max == 2048, "Ultra: 2,048 ground marks (got " .. decal_max .. ")")
ok(math.abs(flora.params.reach - 1.2) < 1e-6 and flora.params.max_props == 9000, "Ultra: plants reach 1.2, 9,000 of them")
ok(math.abs(rocks.params.reach - 1.0) < 1e-6, "Ultra: rocks reach 1.0 (got " .. rocks.params.reach .. ")")
ok(vfx.params.tier == "Ultra" and strip.RT_BUDGET == 20, "Ultra: vehicle effects Ultra, portraits 20/s")
st.set("gfx_level", "Low"); frames(3)
ok(A.scale == 0.6 and light.contactShadows == false and gx.volumetric == false, "Low: 60% scale, no contact shadows, flat haze")
ok(flare_on == false, "Low: no flare (got " .. tostring(flare_on) .. ")"); ok(gx.dof == false, "Low: no distance blur (got " .. tostring(gx.dof) .. ")")
ok(math.abs(flora.params.reach - 0.65) < 1e-6 and flora.params.max_props == 3000, "Low: plants nearer and fewer")
ok(math.abs(post.aoStrength - 0.85 * 0.5) < 1e-6, "Low: AO at half the scene's strength")
ok(gx.levelFor("rain") == "Low", "rain_fx's tier follows the Rain and snow row")
-- one change
st.set("gfx_shadow_distance", 600); frames(2)
ok(st.gfxCustom() and math.abs(light.shadowDistance - 600) < 1, "one option changed: Custom, and applied live")
ok(A.scale == 0.6, "...the rest of the level stays")
st.set("gfx_motion_blur", 0.3); st.set("gfx_bloom", false); st.set("gfx_antialias", "Off"); frames(2)
ok(post.motionBlur == 0.3 and post.bloom == false and A.aa == "Off", "motion blur, bloom and anti-aliasing reach the engine")
st.set("gfx_terrain_memory", 1536); frames(3)
ok(tbudget == 1536 * 1048576, "the terrain memory budget reaches terrain.setBudget")
st.set("gfx_sharpen", 0.75); frames(1)
ok(math.abs(A.sharp - 0.75) < 1e-6, "the sharpening row reaches app.setRenderSharpness")
st.set("gfx_level", "Medium"); frames(3)
ok(not st.gfxCustom() and math.abs(light.shadowDistance - 140) < 1 and post.bloom == true and A.aa == "Fxaa",
  "a preset puts every changed option back")
ok(tbudget == nil, "...the terrain budget too (no limit)")

-- ── 4. SOMEONE ELSE'S VALUE is left alone ────────────────────────────────────
vfx.params.tier = "Low"           -- a probe pinned the effects tier
flora.params.reach = 0.4          -- a probe thinned the plants
st.set("gfx_level", "High"); frames(3)
ok(vfx.params.tier == "Low" and flora.params.reach == 0.4, "a value a probe set is not overwritten")

-- ── 5. THE SCREEN ───────────────────────────────────────────────────────────
st.showTab("graphics")
local rows = st.rows(580)
local n_opts, keyed = 0, true
local function walk(t, fn)
  if type(t) ~= "table" then return end
  fn(t)
  for i = 2, #t do if type(t[i]) == "table" then walk(t[i], fn) end end
  local build = t[#t]
  for _, item in ipairs(t.items or {}) do
    if type(build) == "function" then walk(build(item), fn) else walk(item, fn) end
  end
end
local scroll
for _, r in ipairs(rows) do walk(r, function(e)
  if e[1] == "scroll" then scroll = e end
  if type(e.key) == "string" and e.key:sub(1, 2) == "g_" then n_opts = n_opts + 1 end
  if (e[1] == "row" or e[1] == "col" or e[1] == "button" or e[1] == "scroll") and not e.key then keyed = false end
end) end
ok(scroll ~= nil and (scroll.maxH or 0) > 0, "the options are in a scroll view with a height limit")
ok(n_opts == #st.GFX_OPTIONS, string.format("a row for every option (%d of %d)", n_opts, #st.GFX_OPTIONS))
ok(keyed, "every row and button is keyed")
for _, o in ipairs(st.GFX_OPTIONS) do
  for _, lv in ipairs({ "Low", "Medium", "High", "Ultra" }) do
    local v = o.preset[lv]
    local found = false
    for _, c in ipairs(o.opts) do if c.value == v then found = true end end
    ok(found, string.format("%s at %s is one of its own choices (%s)", o.key, lv, tostring(v)))
  end
  ok(type(o.desc) == "string" and #o.desc > 10 and type(o.cost) == "string", o.key .. " says what it does and what it costs")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_graphics_options: %d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_graphics_options: %d checks passed", checks))
