-- SMOKE HARNESS: the scene files' authored script params, checked against the
-- scripts they belong to.
--
--   luajit solar/tests/smoke_scene_params.lua
--
-- This exists because of a bug that was invisible from inside the code and
-- obvious from inside the game. `system.ron` pinned the mining laser to its
-- ORIGINAL tuning — `laser_radius: 0.95`, `laser_rate: 0.3`,
-- `laser_strength: 0.55`, and a `laser_range` the script had long since stopped
-- having — so every round of tuning done in `tool_belt.lua` was silently
-- overridden in the only scene that ships. Two rounds of "the laser still feels
-- wrong" were spent on a script whose numbers the game was never reading.
--
-- Two rules, and both of them are about the same thing: a param in a scene is a
-- claim about a script, and nothing was checking the claim.
--
--   1. every authored param NAME exists in that script's `defaults`
--   2. every authored param VALUE is inside its `--@range`, when it declares one
--
-- Neither can be enforced by the engine — an unknown param is not an error, it
-- is just a value nobody reads — so it is enforced here.

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

-- ── read a script's defaults + its --@range annotations ─────────────────────
-- The scripts are plain Lua chunks whose top level only builds tables, so they
-- load under a permissive env that answers anything with a no-op. Nothing in a
-- `defaults` block calls the engine.
local function load_defaults(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  local chunk = loadstring(src, path)
  if not chunk then return nil end
  local nop = setmetatable({}, { __index = function() return function() end end })
  local env = setmetatable({}, { __index = function(_, k) return _G[k] or nop end })
  setfenv(chunk, env)
  local ok = pcall(chunk)
  if not ok then return nil end

  -- The ranges live in comments right above each key: `--@range 4 60`, and
  -- `--@slider a b` for the same thing with a different widget.
  local ranges, pending_lo, pending_hi = {}, nil, nil
  for line in src:gmatch("[^\n]+") do
    local lo, hi = line:match("%-%-@ra?n?g?e?%s+([%-%d%.]+)%s+([%-%d%.]+)")
    if not lo then lo, hi = line:match("%-%-@slider%s+([%-%d%.]+)%s+([%-%d%.]+)") end
    if lo then
      pending_lo, pending_hi = tonumber(lo), tonumber(hi)
    else
      local key = line:match("^%s*([%a_][%w_]*)%s*=")
      if key and pending_lo then
        ranges[key] = { pending_lo, pending_hi }
        pending_lo, pending_hi = nil, nil
      end
    end
  end
  return env.defaults or rawget(env, "defaults"), ranges
end

-- ── pull (kind, params) pairs out of a .ron scene ───────────────────────────
local function scene_params(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local src = f:read("*a")
  f:close()
  local out = {}
  for kind, body in src:gmatch('kind:%s*"([%w_]+)",%s*\n%s*enabled:%s*%a+,%s*\n%s*params:%s*%[(.-)%]') do
    local ps = {}
    for name, value in body:gmatch('%("([%w_]+)",%s*([%-%d%.e]+)%)') do
      ps[#ps + 1] = { name = name, value = tonumber(value) }
    end
    if #ps > 0 then out[#out + 1] = { kind = kind, params = ps, scene = path } end
  end
  return out
end

local SCENES = { "solar/scenes/system.ron", "solar/scenes/builder.ron",
                 "solar/scenes/menu.ron" }

local unknown, out_of_range, seen_kinds, total = {}, {}, {}, 0
for _, scene in ipairs(SCENES) do
  for _, block in ipairs(scene_params(scene)) do
    local defaults, ranges = load_defaults("solar/scripts/" .. block.kind .. ".lua")
    if defaults then
      seen_kinds[block.kind] = true
      for _, p in ipairs(block.params) do
        total = total + 1
        if defaults[p.name] == nil then
          unknown[#unknown + 1] = string.format("%s → %s.%s",
            scene:match("[^/]+$"), block.kind, p.name)
        else
          local r = ranges[p.name]
          -- A hair of slack: these are authored by dragging a slider, and a
          -- float that lands a whisker outside its own stop is not a bug.
          if r and (p.value < r[1] - 1e-6 or p.value > r[2] + 1e-6) then
            out_of_range[#out_of_range + 1] = string.format("%s → %s.%s = %s (range %s..%s)",
              scene:match("[^/]+$"), block.kind, p.name, p.value, r[1], r[2])
          end
        end
      end
    end
  end
end

check("the scenes actually carry authored params to check", total > 20, total .. " params")
check("no scene pins a param the script doesn't have", #unknown == 0,
  table.concat(unknown, "; "))
check("...and none is authored outside its own declared range", #out_of_range == 0,
  table.concat(out_of_range, "; "))

-- ── the invariant a mining laser lives or dies by ───────────────────────────
-- Consecutive bites have to OVERLAP. `terrain.dig` subtracts a ball of
-- radius × strength, and the bore walks forward `bore_speed × laser_rate` metres
-- between them: if that step is longer than the ball, the balls never touch and
-- holding the trigger leaves a string of separate pockets instead of a tunnel.
-- That is precisely what the pinned params did, and it reads in-game as the dig
-- being "glitchy and kind of offset" rather than as a tuning problem.
--
-- Checked on the EFFECTIVE numbers — the script's defaults with the game
-- scene's overrides applied on top — because that is what the game runs, and
-- the whole reason this file exists is that those two were not the same thing.
local tb = load_defaults("solar/scripts/tool_belt.lua")
check("the tool belt's defaults load", tb ~= nil)
if tb then
  for _, block in ipairs(scene_params("solar/scenes/system.ron")) do
    if block.kind == "tool_belt" then
      for _, p in ipairs(block.params) do tb[p.name] = p.value end
    end
  end
  local step = tb.bore_speed * tb.laser_rate
  local ball = tb.laser_radius * tb.laser_strength
  check("the laser's bites overlap into a continuous bore", step < ball,
    string.format("%.2f m step vs a %.2f m ball", step, ball))
  -- And with room to spare: exactly-touching balls leave a scalloped wall the
  -- collider and the eye both notice.
  check("...with margin, not just barely", step < ball * 0.6,
    string.format("%.2f m step vs a %.2f m ball", step, ball))
  check("a tunnel is wide enough to walk down", ball * 2 > 2.0,
    string.format("%.2f m across", ball * 2))
end

-- ── every texture a VFX file names actually exists ──────────────────────────
-- A missing texture is not an error anywhere: the effect loads, the track runs,
-- and it draws nothing. So a typo in a path is invisible until someone says the
-- VFX look lacklustre — which is a slow way to find out.
local missing, refs = {}, 0
local vfx = io.popen('ls solar/vfx/*.vfx.ron 2>/dev/null')
for path in (vfx and vfx:lines() or function() return nil end) do
  local fh = io.open(path, "r")
  if fh then
    local src = fh:read("*a")
    fh:close()
    for tex in src:gmatch('texture:%s*Some%("([^"]+)"%)') do
      refs = refs + 1
      local f = io.open("solar/" .. tex, "r")
      if f then f:close() else
        missing[#missing + 1] = path:match("[^/]+$") .. " → " .. tex
      end
    end
  end
end
if vfx then vfx:close() end
check("the vfx files name some textures", refs > 20, refs .. " references")
check("every texture a vfx file names is on disk", #missing == 0,
  table.concat(missing, "; "))

local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and c.detail ~= ""
      and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  local kinds = 0
  for _ in pairs(seen_kinds) do kinds = kinds + 1 end
  print(string.format("SCENE PARAM SMOKE OK — %d checks, %d params across %d scripts",
    #checks, total, kinds))
  os.exit(0)
end
print("SCENE PARAM SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
os.exit(1)
