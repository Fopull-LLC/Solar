-- WEATHER MAP — where on a world the weather is, and what its clouds are.
--
-- weather.lua decides how often a world gets fronts, storms, dust and ash,
-- from its climate. This turns that into a MAP: weather systems that are
-- somewhere on the sphere, drift with the winds of their latitude, grow and die,
-- and leave clear sky between them. The weather you stand in is the map
-- read where you stand, and the cloud layer (engine card 0589, a volumetric
-- cloud layer driven by a game map) draws the same map, so rain falls under
-- the storm you can see, and the sky is clear where the map is clear.
--
-- ── what is on it ───────────────────────────────────────────────────────────
--   * the climate's own bands, always there:
--       the tropical convergence (ITCZ), a wavy belt of cumulus over the
--         equator, thicker on a wet world;
--       the subtropical highs (~30°), dry and mostly clear;
--       the mid-latitude stratocumulus, and the polar stratus of a cold world.
--   * SYNOPTIC systems (`NS` slots): mid-latitude lows, each with a comma of
--     nimbostratus around its centre, a cold front trailing equatorward (a line
--     of cumulus and cumulonimbus: the squall line), a warm front ahead of it
--     under a stratus shield, and cirrus far ahead. They ride the westerlies
--     east and drift poleward over their life (a few spells).
--   * CONVECTIVE cells (`NC` slots): short-lived showers and thunderstorms,
--     mostly in the tropics of a warm, wet world, anywhere on a cold one (snow
--     squalls), ridden westward by the trade winds. A storm cell spreads
--     an anvil of cirrus. On a dry world some are dust storms; on a
--     molten one they are ash.
--   How strong and how common each is comes from weather.lua's own `front()`
--   and the world's profile, so the climate keeps the same say it always had.
--
-- ── pure ────────────────────────────────────────────────────────────────────
-- Everything is a pure function of (seed, profile, weather clock): no state,
-- so save/load and time warp give the same map, and nothing is stored but
-- weather.lua's clock. Systems are rolled by HASH in Lua (the GPU never hashes:
-- f32 sin-hashes do not match Lua's doubles), and their geometry is worked out
-- the same way on both sides: Lua for the weather where you stand and the debug
-- view, WGSL (shaders/weather_map.wgsl) for the texture the clouds read.
--
-- ── the texture ─────────────────────────────────────────────────────────────
-- A body-fixed CUBE ATLAS, 3×2 faces in the order +X −X +Y / −Y +Z −Z, each
-- face `face` texels square with a 1-texel gutter all round (E's layout for
-- card 0589). rgba8:
--   R coverage 0..1
--   G cloud type: 0 stratus, 0.5 cumulus, 1 cumulonimbus
--   B density / wetness (a dark, low, raining base)
--   A high cloud (cirrus) coverage
-- The face orientation is this file's `face_dir` adapter until the engine's
-- helper lands. Then that adapter is the one place to change.
--
-- Cross-script:
--   local M = findScript("weather_map")
--   M.localAt(W, seed, p, t, spell, rx, ry, rz) → I, trend, kind, hail, f
--        (W = weather.lua's hash/front; rx.. body-relative). weather.lua calls it.
--   M.fieldAt(sys, base, ux, uy, uz) → f { I, cov, typ, dens, cir, kind, hail }
--   M.systems(W, seed, p, t, spell) → the list of live systems
--   M.map  { tex, body, face, w, h, layout = "cube3x2" } once a map is drawn
--
-- Debug view: `debug = true` draws the map of the camera's world as an
-- equirect picture in the corner (R white, G hue, B blue tint, A pink tint),
-- the systems' centres, and where you are.

defaults = {
  --- Draw the weather map texture (for the cloud layer) at all.
  on = true,
  --- Texels per cube face (the atlas is 3·(face+2) × 2·(face+2)).
  --@range 16 512
  face = 96,
  --- Seconds between two redraws of the map (it changes over minutes).
  --@range 0.1 30
  period = 1.0,
  --- Draw the map in the corner of the screen.
  debug = false,
  --- The debug picture's width in pixels (height is half).
  --@range 128 1600
  debugWidth = 512,
  --- What the debug picture shows: "all", "cover", "type", "density", "cirrus", "intensity".
  debugMode = "all",
  --- Probes: draw the map (texture and debug view) this many seconds of
  --- weather clock ahead of now. The weather where you stand is never moved.
  debugAhead = 0,
}

local sqrt, floor, max, min, exp, abs = math.sqrt, math.floor, math.max, math.min, math.exp, math.abs
local sin, cos, pi = math.sin, math.cos, math.pi
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local function clamp01(x) return max(0.0, min(1.0, x)) end
local function smooth(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end

NS = 10     -- synoptic slots
NC = 24     -- convective slots
KIND_CODE = { wet = 0, dust = 1, ash = 2, none = 0 }
KIND_NAME = { [0] = "wet", [1] = "dust", [2] = "ash" }

-- The cold front trails equatorward of the low, the warm front ahead (east)
-- of it, in the low's tangent plane: x east, y poleward, in units of `len`.
COLD = { { 0, 0 }, { 0.06, -0.3 }, { -0.02, -0.62 }, { -0.22, -0.9 } }
WARM = { { 0, 0 }, { 0.3, -0.06 }, { 0.55, -0.2 } }

-- A unit direction and its local east and north (north = toward +Y, the
-- body's pole, as climate.lua reads latitude).
local function frame_of(lat, lon)
  local cl, sl, co, so = cos(lat), sin(lat), cos(lon), sin(lon)
  local cx, cy, cz = cl * co, sl, cl * so
  -- east = d(dir)/d(lon), north = d(dir)/d(lat)
  local ex, ey, ez = -so, 0, co
  local nx, ny, nz = -sl * co, cl, -sl * so
  return cx, cy, cz, ex, ey, ez, nx, ny, nz
end

-- The live systems on a world at clock `t`. `W` gives weather.lua's `hash`
-- and `front`. Each system: centre (cx..), east (ex..), north (nx..), I (its
-- intensity now, peak × life envelope), rc (core radius, radians), len (the
-- fronts' length), cls (1 synoptic, 2 convective), kind (0 wet, 1 dust, 2
-- ash), hail (0/1), sgn (+1 north, −1 south hemisphere).
function systems(W, seed, p, t, spell)
  local out = {}
  if not p or p.airless then return out end
  spell = spell or 360
  local hash, front = W.hash, W.front
  -- synoptic lows: a life of three spells, staggered by slot
  local Ls = spell * 3.0
  for i = 1, NS do
    local u = t / Ls + hash(seed, i, 101)
    local g = floor(u)
    local a = u - g
    local k = g * 31 + i * 7 + 1000
    local peak, kind, hail = front(seed, p, k)
    local env = smooth(0.0, 0.3, a) * (1 - smooth(0.7, 1.0, a))
    local I = peak * env
    if I > 0.02 then
      local sgn = hash(seed, k, 41) < 0.5 and -1 or 1
      local lat0 = 0.6 + 0.45 * hash(seed, k, 42)
      local lon0 = 2 * pi * hash(seed, k, 43)
      local travel = 1.0 + 0.6 * hash(seed, k, 45)
      local lat = sgn * (lat0 + 0.15 * (a - 0.5))
      local lon = lon0 + travel * (a - 0.5)
      local cx, cy, cz, ex, ey, ez, nx, ny, nz = frame_of(lat, lon)
      out[#out + 1] = { cx = cx, cy = cy, cz = cz, ex = ex, ey = ey, ez = ez, nx = nx, ny = ny, nz = nz,
        I = I, peak = peak, rc = 0.3 + 0.15 * hash(seed, k, 44), len = 0.6 + 0.35 * hash(seed, k, 46),
        cls = 1, kind = KIND_CODE[kind] or 0, hail = hail and 1 or 0, sgn = sgn, lat = lat, lon = lon }
    end
  end
  -- convective cells: a life of most of a spell
  local Lc = spell * 0.9
  local chance = clamp01((p.storm or 0) * 1.1 + 0.1)
  local cold = (p.temp or 0.5) < 0.35
  for j = 1, NC do
    local u = t / Lc + hash(seed, j, 201)
    local g = floor(u)
    local a = u - g
    local k = g * 53 + j * 11 + 5000
    if hash(seed, k, 60) < chance then
      local peak = 0.5 + 0.5 * hash(seed, k, 62) ^ 0.7
      local stormy = hash(seed, k, 63) < (p.storm or 0)
      if peak > 0.74 and not stormy then peak = 0.70 + 0.04 * hash(seed, k, 64) end
      local kind = "wet"
      if p.ash then kind = "ash"
      elseif (p.dust or 0) > 0 and hash(seed, k, 65) < (p.dust or 0) / max((p.wet or 0) + (p.dust or 0), 1e-6) then kind = "dust" end
      local hail = kind == "wet" and stormy and hash(seed, k, 66) < (p.hail or 0)
      local env = smooth(0.0, 0.25, a) * (1 - smooth(0.55, 1.0, a))
      local I = peak * env
      if I > 0.02 then
        local sgn = hash(seed, k, 67) < 0.5 and -1 or 1
        local alat = cold and 1.25 * hash(seed, k, 68) or 0.5 * hash(seed, k, 68) ^ 1.4
        local lon0 = 2 * pi * hash(seed, k, 69)
        -- the trades blow westward below ~30°, the westerlies east above
        local dir = (alat < 0.55) and -1 or 1
        local lat = sgn * alat
        local lon = lon0 + dir * 0.3 * (a - 0.5)
        local cx, cy, cz, ex, ey, ez, nx, ny, nz = frame_of(lat, lon)
        out[#out + 1] = { cx = cx, cy = cy, cz = cz, ex = ex, ey = ey, ez = ez, nx = nx, ny = ny, nz = nz,
          I = I, peak = peak, rc = 0.08 + 0.1 * hash(seed, k, 70), len = 1,
          cls = 2, kind = KIND_CODE[kind] or 0, hail = hail and 1 or 0, sgn = sgn, lat = lat, lon = lon }
      end
    end
  end
  return out
end

-- The climate's bands, per world (no clock): what the sky is without systems.
function baseOf(seed, p)
  if not p or p.airless then return nil end
  return {
    moist = clamp01((p.moist or 0) * 1.6),
    cover = p.cover or 0.1,
    polar = ((p.temp or 0.5) < 0.4) and 1.0 or 0.4,
    phase = (seed % 997) * 0.0063,
    dusty = p.ash and 0 or clamp01((p.dust or 0) * 2),
  }
end

-- Distance from (x, y) to a polyline scaled by `s`.
local function seg_d2(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local h = l2 > 0 and clamp01(((px - ax) * dx + (py - ay) * dy) / l2) or 0
  local qx, qy = px - ax - dx * h, py - ay - dy * h
  return qx * qx + qy * qy
end
local function line_d(px, py, P, s)
  local best = 1e9
  for i = 1, #P - 1 do
    local d = seg_d2(px, py, P[i][1] * s, P[i][2] * s, P[i + 1][1] * s, P[i + 1][2] * s)
    if d < best then best = d end
  end
  return sqrt(best)
end

-- What the map holds at unit direction (ux, uy, uz) of the body.
-- KEEP IN STEP with shaders/weather_map.wgsl `field` (probe: tools/perf/wxmap).
function fieldAt(sys, base, ux, uy, uz)
  local f = { I = 0, cov = 0, typ = 0.3, dens = 0, cir = 0, kind = 0, hail = 0, dust = 0 }
  if not base then return f end
  local lat = math.asin(max(-1, min(1, uy)))
  local lon = atan2(uz, ux)
  local alat = abs(lat)
  local itcz = exp(-((lat - 0.1 * sin(2 * lon + base.phase)) / 0.16) ^ 2)
  local sub = exp(-((alat - 0.52) / 0.16) ^ 2)
  local mid = smooth(0.6, 0.8, alat) * (1 - smooth(1.15, 1.4, alat))
  local polar = smooth(1.1, 1.4, alat)
  local Ib = 0.06 + 0.24 * itcz * base.moist + 0.16 * mid * base.moist + 0.12 * polar * base.polar - 0.05 * sub
  Ib = max(0, min(0.32, Ib))
  local tw = Ib + 1e-4
  local tsum = (0.5 * itcz + 0.3 * mid + 0.1 * polar + 0.35 * 0.2) / (itcz + mid + polar + 0.2) * tw
  local keep = 1 - Ib
  local cir = 0.25 * itcz * base.moist
  local best, bkind, bhail = Ib, 0, 0
  local dustw = 0
  for i = 1, #sys do
    local s = sys[i]
    local c = ux * s.cx + uy * s.cy + uz * s.cz
    if c > 0.3 then
      local dx = ux * s.ex + uy * s.ey + uz * s.ez
      local dy = (ux * s.nx + uy * s.ny + uz * s.nz) * s.sgn
      -- No two alike: the system's plane is warped by two waves on a phase
      -- of its own (sines, not a hash, so the GPU lands on the same numbers).
      local ph = s.cx * 13.1 + s.cy * 3.3 + s.cz * 7.7
      local wa = (s.cls == 1) and (0.1 * s.len) or (0.35 * s.rc)
      local qx = dx + wa * (sin(dy / wa * 1.3 + ph) + 0.5 * sin(dy / wa * 2.9 + ph * 2.3))
      local qy = dy + wa * (sin(dx / wa * 1.1 + ph * 1.7) + 0.5 * sin(dx / wa * 2.7 + ph * 0.6))
      dx, dy = qx, qy
      local v, typ, ci
      if s.cls == 1 then
        local L = s.len
        local core = exp(-(dx * dx + dy * dy) / (s.rc * s.rc))
        local dc = line_d(dx, dy, COLD, L)
        local dw = line_d(dx, dy, WARM, L)
        local cold = exp(-(dc / (0.09 * L)) ^ 2)
        local warm = 0.8 * exp(-(dw / (0.2 * L)) ^ 2)
        v = s.I * max(core, cold, warm)
        typ = (core * 0.12 + cold * 0.8 + warm * 0.2) / (core + cold + warm + 1e-4)
        local ax, ay = dx - 0.45 * L, dy - 0.1 * L
        ci = s.I * (0.9 * exp(-(ax * ax + ay * ay) / (0.16 * L * L)) + 0.3 * core)
      else
        local r2 = (dx * dx + dy * dy) / (s.rc * s.rc)
        local core = exp(-r2)
        v = s.I * core
        local st = smooth(0.55, 0.9, s.I)
        typ = 0.5 + 0.5 * st * core
        ci = st * exp(-r2 / 5)
      end
      if s.kind == 1 then dustw = max(dustw, v) end
      keep = keep * (1 - v)
      tsum = tsum + v * typ
      tw = tw + v
      if ci > cir then cir = ci end
      if v > best then best, bkind, bhail = v, s.kind, s.hail end
    end
  end
  local I = 1 - keep
  f.I = I
  f.typ = clamp01(tsum / tw)
  f.kind, f.hail = bkind, bhail
  f.dust = dustw
  -- coverage: the climate's fair-weather cover, closing as the weather builds
  -- (weather.lua `derive`'s own curve), thinner in the subtropical highs, and
  -- a dust storm is haze, not cloud
  local pc = base.cover * (1 - 0.6 * sub)
  local cov = pc + (1 - pc) * smooth(0.12, 0.5, I)
  cov = cov * (1 - 0.7 * dustw)
  f.cov = clamp01(cov)
  f.dens = smooth(0.3, 0.9, I) * (1 - 0.7 * dustw)
  f.cir = clamp01(cir)
  return f
end

-- The weather where you stand: weather.lua's (I, trend, kind, hail), off the
-- map at the body-relative point (rx, ry, rz). The trend is which way it is
-- going over the next half minute.
function localAt(W, seed, p, t, spell, rx, ry, rz)
  local r = sqrt(rx * rx + ry * ry + rz * rz)
  if r < 1e-6 then rx, ry, rz, r = 0, 1, 0, 1 end
  local ux, uy, uz = rx / r, ry / r, rz / r
  local base = baseOf(seed, p)
  local f = fieldAt(systems(W, seed, p, t, spell), base, ux, uy, uz)
  local f1 = fieldAt(systems(W, seed, p, t + 15, spell), base, ux, uy, uz)
  local f0 = fieldAt(systems(W, seed, p, t - 15, spell), base, ux, uy, uz)
  local d = f1.I - f0.I
  local trend = (d > 0.002) and 1 or ((d < -0.002) and -1 or 0)
  return f.I, trend, KIND_NAME[f.kind] or "wet", f.hail > 0, f
end

-- ── the cube atlas (adapter: E's helper replaces face_dir/dir_face) ─────────
-- Face index 0..5 = +X −X +Y −Y +Z −Z; (a, b) in −1..1 across the face.
function face_dir(fi, a, b)
  local x, y, z
  if fi == 0 then x, y, z = 1, -b, -a
  elseif fi == 1 then x, y, z = -1, -b, a
  elseif fi == 2 then x, y, z = a, 1, b
  elseif fi == 3 then x, y, z = a, -1, -b
  elseif fi == 4 then x, y, z = a, -b, 1
  else x, y, z = -a, -b, -1 end
  local l = sqrt(x * x + y * y + z * z)
  return x / l, y / l, z / l
end

-- Direction → (atlas u, v in 0..1) for a face of `F` texels plus gutter.
function dir_uv(x, y, z, F)
  local ax, ay, az = abs(x), abs(y), abs(z)
  local fi, a, b
  if ax >= ay and ax >= az then
    if x > 0 then fi, a, b = 0, -z / ax, -y / ax else fi, a, b = 1, z / ax, -y / ax end
  elseif ay >= az then
    if y > 0 then fi, a, b = 2, x / ay, z / ay else fi, a, b = 3, x / ay, -z / ay end
  else
    if z > 0 then fi, a, b = 4, x / az, -y / az else fi, a, b = 5, -x / az, -y / az end
  end
  local S = F + 2
  local col, row = fi % 3, floor(fi / 3)
  local px = col * S + 1 + (a * 0.5 + 0.5) * F
  local py = row * S + 1 + (b * 0.5 + 0.5) * F
  return px / (3 * S), py / (2 * S)
end

-- ── runtime: the texture, and the debug view ────────────────────────────────
map = nil
local SH = "shaders/weather_map.wgsl"
local sysbuf, tex, tex_face = nil, nil, nil
local last_t = -100
local dbg = nil     -- { name, t, grid, sys }
local WREF = nil
last_sys, last_base = nil, nil   -- what the texture was drawn from (probes)

local function weather()
  if WREF and WREF.valid then return WREF end
  WREF = findScript and findScript("weather") or nil
  return WREF
end

-- The systems as the shader's f32 array, 16 a system.
local function pack(sys)
  local v = {}
  for i = 1, #sys do
    local s = sys[i]
    local o = (i - 1) * 16
    v[o + 1], v[o + 2], v[o + 3], v[o + 4] = s.cx, s.cy, s.cz, s.I
    v[o + 5], v[o + 6], v[o + 7], v[o + 8] = s.ex, s.ey, s.ez, s.rc
    v[o + 9], v[o + 10], v[o + 11], v[o + 12] = s.nx, s.ny, s.nz, s.len
    v[o + 13], v[o + 14], v[o + 15], v[o + 16] = s.cls, s.kind, s.hail, s.sgn
  end
  return v
end

function start(node)
  map, sysbuf, tex, last_t, dbg = nil, nil, nil, -100, nil
end

local function draw_map(ctx, sys, base)
  local F = floor(params.face or 96)
  if not (gpu and compute) then return end
  if not sysbuf then
    sysbuf = gpu.buffer { count = (NS + NC) * 16, type = "f32" }
    if not sysbuf then return end
  end
  if not tex or tex_face ~= F then
    tex = gpu.texture { w = 3 * (F + 2), h = 2 * (F + 2) }
    tex_face = F
    if not tex then return end
  end
  local v = pack(sys)
  if #v == 0 then v = { 0 } end
  sysbuf:write(v)
  compute.run(SH, "atlas", { size = { 3 * (F + 2), 2 * (F + 2) }, bind = { sys = sysbuf, out = tex }, params = {
    n = #sys, face = F, moist = base.moist, cover = base.cover, polar = base.polar, phase = base.phase,
    seed = ctx.seed % 1009,
  } })
  map = { tex = tex.name, body = ctx.name, face = F, w = 3 * (F + 2), h = 2 * (F + 2), layout = "cube3x2", t = ctx.t or ctx.clock }
end

local DW, DH = 96, 48
local function debug_grid(sys, base)
  local g = {}
  for j = 0, DH - 1 do
    local lat = (0.5 - (j + 0.5) / DH) * pi
    for i = 0, DW - 1 do
      local lon = ((i + 0.5) / DW * 2 - 1) * pi
      local cl = cos(lat)
      g[j * DW + i + 1] = fieldAt(sys, base, cl * cos(lon), sin(lat), cl * sin(lon))
    end
  end
  return g
end

-- The Clouds setting (settings.lua row `clouds`, read through graphics.lua):
-- Off / Low / Medium / High / Ultra. Published for the cloud layer to take
-- once the engine's lands (card 0589); "High" without a settings script.
quality = "High"
local GX = nil
local function tier()
  if not (GX and GX.valid ~= false) then GX = findScript and findScript("graphics", { quiet = true }) or nil end
  local v = GX and GX.opt and GX.opt("clouds")
  return type(v) == "string" and v or "High"
end

function update(node, dt)
  if params.on == false then return end
  local W = weather()
  local ctx = W and W.map_ctx
  if not (ctx and ctx.p and not ctx.p.airless) then map = nil; return end
  if time - last_t < (params.period or 1.0) then return end
  last_t = time
  quality = tier()
  local t = ctx.clock + (tonumber(params.debugAhead) or 0)
  local sys = systems(W, ctx.seed, ctx.p, t, ctx.spell)
  local base = baseOf(ctx.seed, ctx.p)
  draw_map({ name = ctx.name, seed = ctx.seed, t = t }, sys, base)
  last_sys, last_base = sys, base
  if params.debug then
    dbg = { name = ctx.name, grid = debug_grid(sys, base), sys = sys, ctx = ctx }
  else
    dbg = nil
  end
end

local function hue(t)
  -- stratus blue → cumulus green → cumulonimbus red
  if t < 0.5 then local k = t / 0.5; return 0.3 * (1 - k), 0.5 + 0.4 * k, 1 - 0.7 * k end
  local k = (t - 0.5) / 0.5
  return 0.9 * k, 0.9 * (1 - k) + 0.1, 0.3 * (1 - k)
end

function lateUpdate(node, dt)
  if not (params.debug and dbg and draw and draw.rect) then return end
  local Wd = floor(params.debugWidth or 512)
  local cw = Wd / DW
  local x0, y0 = 12, 12
  local mode = params.debugMode or "all"
  draw.rect(x0 - 2, y0 - 2, Wd + 4, Wd / 2 + 4, 0, 0, 0, 0.8)
  for j = 0, DH - 1 do
    for i = 0, DW - 1 do
      local f = dbg.grid[j * DW + i + 1]
      local r, g, b
      if mode == "cover" then r, g, b = f.cov, f.cov, f.cov
      elseif mode == "type" then r, g, b = hue(f.typ); r, g, b = r * f.cov, g * f.cov, b * f.cov
      elseif mode == "density" then r, g, b = f.dens, f.dens, f.dens
      elseif mode == "cirrus" then r, g, b = f.cir, f.cir, f.cir
      elseif mode == "intensity" then r, g, b = f.I, f.I * (1 - f.dust), f.I * (1 - f.dust)
      else
        local hr, hg, hb = hue(f.typ)
        local c = f.cov
        r = c * (0.55 + 0.45 * hr) * (1 - 0.5 * f.dens) + 0.35 * f.cir
        g = c * (0.55 + 0.45 * hg) * (1 - 0.5 * f.dens) + 0.15 * f.cir
        b = c * (0.55 + 0.45 * hb) * (1 - 0.3 * f.dens) + 0.3 * f.cir
        if f.dust > 0.05 then r, g, b = r + 0.6 * f.dust, g + 0.4 * f.dust, b + 0.1 * f.dust end
      end
      draw.rect(x0 + i * cw, y0 + j * cw, cw + 0.5, cw + 0.5, min(1, r), min(1, g), min(1, b), 1)
    end
  end
  -- systems: a ring per centre (white lows, orange cells), sized by intensity
  for _, s in ipairs(dbg.sys) do
    local px = x0 + (s.lon / (2 * pi) % 1 + 0.5) % 1 * Wd
    local py = y0 + (0.5 - s.lat / pi) * Wd / 2
    local rr = 2 + 6 * s.I
    if s.cls == 1 then draw.circleOutline(px, py, rr, 1, 1, 1, 0.9, 1.5)
    else draw.circleOutline(px, py, rr, 1, 0.6, 0.1, 0.9, 1.5) end
  end
  -- you: a cross, at the camera's drawn place on its body (this frame's read)
  local W = weather()
  local cur = W and W.current and W.current()
  local c = find and find("Camera 1")
  local b = cur and space and space.body and space.body(cur.body)
  if c and c.valid and b then
    local rx, ry, rz = c.x - b.x, c.y - b.y, c.z - b.z
    local r = sqrt(rx * rx + ry * ry + rz * rz)
    if r > 1e-3 then
      local lat = math.asin(max(-1, min(1, ry / r)))
      local lon = atan2(rz, rx)
      local px = x0 + ((lon / (2 * pi)) % 1 + 0.5) % 1 * Wd
      local py = y0 + (0.5 - lat / pi) * Wd / 2
      draw.rect(px - 6, py - 1, 12, 2, 0.1, 1, 0.2, 1)
      draw.rect(px - 1, py - 6, 2, 12, 0.1, 1, 0.2, 1)
    end
  end
  if draw.text and cur then
    draw.text(x0, y0 + Wd / 2 + 6, string.format("%s  %s  I %.2f  cover %.2f", dbg.name, cur.type or "?",
      cur.intensity or 0, cur.cover or 0), 14, 1, 1, 1, 1)
  end
end
