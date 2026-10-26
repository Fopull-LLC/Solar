-- SMOKE HARNESS: graphics.lua's first-run level.
--
--   luajit solar/tests/smoke_graphics_default.lua
--
-- A new player (no gfx_level in the "settings" slot) starts on Medium at
-- every screen size — High's lit volumetric fog costs 24–30 ms of GPU at
-- 1080p on an RTX 4060 until the engine marches it at half resolution — and
-- a player's saved choice is never replaced by that default.

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local function boot(saved_level, w, h)
  local slots = { slot1 = {}, settings = { gfx_level = saved_level } }
  local active = "slot1"
  local scales = {}
  local light = { shadows = false, shadowDistance = 0, fogSteps = 0 }
  local env = setmetatable({
    save = {
      slot = function(n) if n then active = n; slots[n] = slots[n] or {} end return active end,
      get = function(k, d) local v = slots[active][k]; if v == nil then return d end return v end,
      set = function(k, v) slots[active][k] = v end,
      flush = function() return true end,
    },
    app = { setRenderScale = function(s) scales[#scales + 1] = s end },
    camera = { screenSize = function() return w, h end },
    find = function(name) if name == "Lighting" then return { getcomponent = function() return light end } end end,
    findScript = function() return nil end,
    space = {}, terrain = { busy = function() return false end },
    time = 0,
  }, { __index = _G })
  local chunk = assert(loadfile("solar/scripts/graphics.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = env.defaults
  env.start({})
  for _ = 1, 30 do env.time = env.time + 1 / 60; env.update({}, 1 / 60) end
  return env, slots
end

for _, sz in ipairs({ { 1280, 720 }, { 1920, 1080 }, { 1920, 1052 }, { 2560, 1440 }, { 3840, 2160 } }) do
  local gx, slots = boot(nil, sz[1], sz[2])
  ok(gx.level() == "Medium", string.format("a first run at %dx%d starts on Medium (got %s)", sz[1], sz[2], gx.level()))
  ok(slots.settings.gfx_level == nil, "...and the default is not written as if the player chose it")
end
for _, lv in ipairs({ "Low", "High", "Ultra" }) do
  local gx = boot(lv, 1920, 1080)
  ok(gx.level() == lv, "a saved " .. lv .. " is kept (got " .. gx.level() .. ")")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_graphics_default: %d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_graphics_default: %d checks passed", checks))
