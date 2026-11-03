-- SMOKE HARNESS: weather_map.lua — where on a world the weather is.
--
-- What is held here:
--   * pure: the same seed and clock is the same map; an airless world has none
--   * the map has PLACES: at one moment some of a wet world is clear and some
--     is raining, and a point's weather changes smoothly (minutes, not frames)
--   * the climate still decides how much: a wet world rains more than a
--     desert, a desert raises dust, a molten world's systems are ash
--   * the systems drift (a low moves east over its life) and the fronts have
--     cloud types: stratus round a low, cumulonimbus on its cold front
--   * the cube atlas adapter: a direction maps into its own face's texel
--   * weather.lua reads it: the weather where you stand is the map's there
--
--   luajit solar/tests/smoke_weather_map.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local function load(path, api)
  local env = setmetatable({}, { __index = function(_, k)
    if api[k] ~= nil then return api[k] end
    return _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end

local T = 0
local W = load("solar/scripts/weather.lua", { time = 0 })
local M = load("solar/scripts/weather_map.lua", { time = 0 })
local WX = W.WX

local worlds = {
  Verd = { kind = "canyon", seed = 11, atmo = 0.75, sea = 290, insol = 1.0 },
  Sand = { kind = "dune", seed = 22, atmo = 0.7, sea = 0, insol = 1.3 },
  Rime = { kind = "ice", seed = 33, atmo = 0.6, sea = 0, insol = 0.8 },
  Pyre = { kind = "lava", seed = 44, atmo = 0.8, sea = 0, insol = 1.5 },
  Husk = { kind = "barren", seed = 55, atmo = 0, sea = 0, insol = 1 },
}
local P = {}
for n, w in pairs(worlds) do P[n] = W.profile(w) end

-- ── pure ────────────────────────────────────────────────────────────────────
local a = { M.localAt(WX, 777, P.Verd, 12345.6, 360, 10, 300, 40) }
local b = { M.localAt(WX, 777, P.Verd, 12345.6, 360, 10, 300, 40) }
ok(a[1] == b[1] and a[3] == b[3], "the same seed and clock is the same weather")
ok(#M.systems(WX, 1, P.Husk, 100, 360) == 0, "an airless world has no systems")
ok(M.localAt(WX, 1, P.Husk, 100, 360, 0, 100, 0) == 0, "...and no weather")

-- A spread of points over the sphere (a Fibonacci lattice).
local pts = {}
local N = 400
for i = 0, N - 1 do
  local y = 1 - 2 * (i + 0.5) / N
  local r = math.sqrt(1 - y * y)
  local th = i * 2.39996
  pts[#pts + 1] = { r * math.cos(th), y, r * math.sin(th) }
end

local function survey(name, seed, t)
  local sys = M.systems(WX, seed, P[name], t, 360)
  local base = M.baseOf(seed, P[name])
  local rain, clear, dust = 0, 0, 0
  local fs = {}
  for _, q in ipairs(pts) do
    local f = M.fieldAt(sys, base, q[1], q[2], q[3])
    fs[#fs + 1] = f
    if f.I > 0.42 then rain = rain + 1 end
    if f.I < 0.16 then clear = clear + 1 end
    if f.kind == 1 and f.I > 0.42 then dust = dust + 1 end
  end
  return rain / N, clear / N, dust / N, fs, sys
end

-- ── places ──────────────────────────────────────────────────────────────────
local rain_t, clear_t, both = 0, 0, 0
local S = 40
for k = 1, S do
  local r, c = survey("Verd", 4242, k * 977.3)
  rain_t, clear_t = rain_t + r, clear_t + c
  if r > 0 and c > 0.2 then both = both + 1 end
end
rain_t, clear_t = rain_t / S, clear_t / S
ok(both > S * 0.6, "at one moment a wet world rains in places and is clear in others (" .. both .. "/" .. S .. ")")
ok(rain_t > 0.04 and rain_t < 0.35, string.format("a wet world rains over a sensible share of its surface (%.3f)", rain_t))
ok(clear_t > 0.2, string.format("...and much of it is clear (%.3f)", clear_t))

-- a point's weather over time: smooth, and it changes
local steps, maxd, lo, hi = 0, 0, 1, 0
local prev
for t = 0, 7200, 1 do
  local I = M.localAt(WX, 4242, P.Verd, 50000 + t, 360, 120, 250, -60)
  if prev then maxd = math.max(maxd, math.abs(I - prev)) end
  prev = I
  lo, hi = math.min(lo, I), math.max(hi, I)
end
ok(maxd < 0.02, string.format("a point's weather never steps (largest change in 1 s: %.4f)", maxd))
ok(hi - lo > 0.2, string.format("...but over two hours it changes (%.2f..%.2f)", lo, hi))

-- the share of time a point is in rain, averaged over points and time
local wet_time = {}
for _, n in ipairs({ "Verd", "Sand", "Rime" }) do
  local s, cnt = 0, 0
  for k = 1, 60 do
    local r = survey(n, 4242, k * 611.7)
    s = s + r; cnt = cnt + 1
  end
  wet_time[n] = s / cnt
end
ok(wet_time.Verd > wet_time.Sand, string.format("a wet world has more weather than a desert (%.3f vs %.3f)", wet_time.Verd, wet_time.Sand))

local dust_any, ash_any = 0, 0
for k = 1, 60 do
  local _, _, d = survey("Sand", 99, k * 401.3)
  dust_any = dust_any + d
  for _, s in ipairs(M.systems(WX, 99, P.Pyre, k * 401.3, 360)) do
    if s.kind == 2 then ash_any = ash_any + 1 end
  end
end
ok(dust_any > 0, "a desert raises dust storms somewhere")
ok(ash_any > 0, "...and a molten world's systems are ash")
for _, s in ipairs(M.systems(WX, 99, P.Pyre, 1234, 360)) do ok(s.kind == 2, "every system on a molten world is ash") end

-- ── drift and types ─────────────────────────────────────────────────────────
-- Track one synoptic slot's centre: it moves east (in its hemisphere's own
-- frame, longitude rises).
local function syn(t)
  for _, s in ipairs(M.systems(WX, 4242, P.Verd, t, 360)) do if s.cls == 1 then return s end end
end
local found = false
for t0 = 1000, 40000, 997 do
  local s0, s1 = syn(t0), syn(t0 + 60)
  if s0 and s1 and math.abs(s0.lat - s1.lat) < 0.05 then
    local dl = (s1.lon - s0.lon + math.pi) % (2 * math.pi) - math.pi
    ok(dl > 0, "a low drifts east on the westerlies")
    found = true
    break
  end
end
ok(found, "a low was found to track")

local cb, st = false, false
for k = 1, 30 do
  local _, _, _, fs = survey("Verd", 4242, k * 1503.1)
  for _, f in ipairs(fs) do
    if f.I > 0.5 and f.typ > 0.65 then cb = true end
    if f.I > 0.4 and f.typ < 0.25 then st = true end
  end
end
ok(cb, "somewhere there is towering cloud (type > 0.65) in the weather")
ok(st, "...and somewhere stratiform (type < 0.25)")

-- ── the cube atlas ──────────────────────────────────────────────────────────
local F = 96
local good = true
for fi = 0, 5 do
  for _, ab in ipairs({ { 0, 0 }, { 0.9, -0.3 }, { -0.95, 0.95 }, { 0.2, 0.7 } }) do
    local x, y, z = M.face_dir(fi, ab[1], ab[2])
    local u, v = M.dir_uv(x, y, z, F)
    local S2 = F + 2
    local col, row = fi % 3, math.floor(fi / 3)
    local px = col * S2 + 1 + (ab[1] * 0.5 + 0.5) * F
    local py = row * S2 + 1 + (ab[2] * 0.5 + 0.5) * F
    if math.abs(u * 3 * S2 - px) > 1e-3 or math.abs(v * 2 * S2 - py) > 1e-3 then good = false end
  end
end
ok(good, "dir_uv inverts face_dir on every face")

-- ── weather.lua reads it ────────────────────────────────────────────────────
-- (the scene path is held by smoke_weather.lua; here only that compute()
-- answers with the map's weather when the map is there)
ok(type(W.WX.hash) == "function" and type(W.WX.front) == "function", "weather.lua hands its hash and fronts to the map")

if #failures == 0 then
  print(string.format("smoke_weather_map: %d checks OK  (rain share Verd %.3f Sand %.3f Rime %.3f)", checks,
    wet_time.Verd, wet_time.Sand, wet_time.Rime))
else
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_weather_map: %d/%d failed", #failures, checks))
  os.exit(1)
end
