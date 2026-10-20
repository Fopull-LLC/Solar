-- SMOKE HARNESS: where a new save puts the colony, and that an OLD save's
-- colony never moves. Runs the real game_manager.lua (its `spawnPoint`) and the
-- real climate.lua against a stubbed round world.
--
--   1. A new save sites the crew (and so the base) in a TEMPERATE band with
--      something growing — not at the pole, which climate.lua reads as
--      Snowfield (flora ×0.08) and which on a dune world sat under a
--      "Snowfield −30 °C" label over red sand.
--   2. It stays out of the sea and off cliffs, as before.
--   3. A save that already HAS a sited base goes home to it — on whatever
--      body it is on — even when the new rule would pick somewhere else, or
--      another world entirely. No re-siting, so no new flatten.
--
--   luajit solar/tests/smoke_siting.lua

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

local STORE = {}
local BODIES = {}
local W = { name = "Tami", x = 1000, y = -50, z = 300, radius = 185, mu = 2.4e5, soi = 2200 }
local MOON = { name = "Kaol", x = 2100, y = -50, z = 300, radius = 40, mu = 5600, soi = 240 }
BODIES.Tami, BODIES.Kaol = W, MOON

-- The ground: a sphere with a sea in one hemisphere's low band (z < -0.6 is
-- ocean basin) and a steep ridge along x > 0.85, so the search has places to
-- refuse.
local function ground_radius(dx, dy, dz)
  local r = W.radius
  if dz < -0.6 then r = r - 8 end            -- the basin the sea fills
  if dx > 0.85 then r = r + 30 * (dx - 0.85) / 0.15 end   -- a cliff band
  return r
end
_G.terrain = {
  query = function(x, y, z)
    local dx, dy, dz = x - W.x, y - W.y, z - W.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    return d - ground_radius(dx / d, dy / d, dz / d)
  end,
}
_G.space = {
  body = function(n) return BODIES[n] end,
  bodies = function() return { W, MOON } end,
  dominant = function() return "Tami" end,
}
_G.save = { get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
            slot = function() return "slot12" end }
_G.log = function() end
_G.time = 0
local printed = {}
_G.print = function(s) printed[#printed + 1] = tostring(s) end
_G.math.noise = _G.math.noise or function() return 0 end

-- A canyon world with air and a sea at r 180: temperate at the equator, frozen
-- at the poles (climate.lua's own latitude model).
STORE["world.Tami"] = { name = "Tami", kind = "canyon", seed = 7, radius = 185, relief = 12,
                        sea = 180, atmo = 0.7, insol = 1.0 }

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local f = assert(loadfile(path))
  setfenv(f, env)
  f()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end
local climate = load("solar/scripts/climate.lua")
_G.findScript = function(k) if k == "climate" then return climate end end
local gm = load("solar/scripts/game_manager.lua")

-- ── 1. a new save: no base yet ───────────────────────────────────────────────
local x, y, z = gm.spawnPoint(W.x, W.y, W.z, "Tami", W.radius + 12)
local rx, ry, rz = x - W.x, y - W.y, z - W.z
local r = math.sqrt(rx * rx + ry * ry + rz * rz)
local s = climate.sampleRel(STORE["world.Tami"], rx, ry, rz)
check("a new save is not sited at the pole", math.abs(ry / r) < 0.75,
  string.format("latitude %.2f", math.abs(ry / r)))
check("...but somewhere things grow", s.density >= 0.3, s.label .. " ×" .. s.density)
check("...and not in a snowfield", s.biome ~= "snow", s.label)
check("...temperate", s.temp > 0.3 and s.temp < 0.85, string.format("temp %.2f", s.temp))
check("...above the sea", r - 2.5 > 180 + 1.0, string.format("r %.1f", r))
check("...and off the cliff band", rx / r <= 0.85, string.format("x %.2f", rx / r))
-- The label the HUD prints is the same model, so it matches what was chosen.
local line = string.format("%s · %.0f°C", s.label, -40 + s.temp * 90)
check("the survey label there is not a snowfield's", not line:find("Snowfield"), line)

-- ── 2. a save that already HAS a base: it goes home, wherever home is ────────
-- The colony is on the moon Kaol (a real report: a seed whose new rule would
-- now site on Tami). Its body-relative position must come back exactly.
STORE["base.body"] = "Kaol"
STORE["base.x"], STORE["base.y"], STORE["base.z"] = 0, 40, 0
local hx, hy, hz = gm.spawnPoint(W.x, W.y, W.z, "Tami", W.radius + 12)
local dk = math.sqrt((hx - MOON.x) ^ 2 + (hy - MOON.y) ^ 2 + (hz - MOON.z) ^ 2)
check("an existing base on another body brings the crew home to IT",
  dk < MOON.radius + 5 and math.abs(hx - MOON.x) < 1e-6,
  string.format("%.1f m from Kaol's centre", dk))
check("...and the saved base itself is untouched (no re-siting)",
  STORE["base.body"] == "Kaol" and STORE["base.y"] == 40)
-- …and on the same body as the new rule, still the saved spot, not the new one.
STORE["base.body"] = "Tami"
STORE["base.x"], STORE["base.y"], STORE["base.z"] = 0, 185, 0   -- the old polar site
hx, hy, hz = gm.spawnPoint(W.x, W.y, W.z, "Tami", W.radius + 12)
check("an existing polar base stays polar", math.abs(hx - W.x) < 1e-6 and math.abs(hz - W.z) < 1e-6
  and hy > W.y + 185, string.format("%.1f %.1f %.1f", hx - W.x, hy - W.y, hz - W.z))

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  io.write(string.format("SITING SMOKE OK — %d checks passed\n", #checks))
  os.exit(0)
end
io.write("SITING SMOKE FAILURES:\n")
for _, b in ipairs(bad) do io.write(b .. "\n") end
for _, p in ipairs(printed) do io.write("  " .. p .. "\n") end
os.exit(1)
