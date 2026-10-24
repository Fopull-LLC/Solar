-- FAR BODIES — a far world drawn as ONE low-res mesh, in its own shape and
-- colours, instead of a grid of coarse terrain chunks or a plain ball.
--
-- The engine draws a celestial terrain three ways, by distance from its LOD
-- centre (the camera, or terrain.lodAnchor while the map is open):
--
--   inside ~42–60 body radii   streamed chunks. From far away they are coarse
--                              and the chunk grid shows (the user's "visible
--                              grid pattern"); on the map, a planet the camera
--                              flies to keeps the coarse chunks of wherever
--                              the ship is.
--   beyond that, or cold       one flat-coloured sphere at the body's radius
--                              ("they stay looking like balls").
--
-- Over either of those, this script draws an IMPOSTOR: an icosphere (level 4,
-- 5 120 triangles) displaced by the generator's own height function and
-- painted with the generator's own surface rules (biomes, ice caps, the A/B
-- patches, the sea), worked out in Lua from the body's genspec with the same
-- noise the engine uses (math.fbm / math.noise are floptle-core's). One mesh,
-- one draw, no seams. It is drawn nearer the camera than what is under it (and
-- shrunk to look the same size), a pixel proud at the limb, so it hides the
-- chunks or the ball, and cross-fades in and out (material alpha) at the
-- switch distance, so nothing pops:
--
--   * the body you are standing on, or any body the camera is within
--     `nearRadii` of, is left to its real chunked terrain;
--   * a body much farther from the LOD anchor than from the camera (the map
--     framing a planet while terrain detail stays with the ship) keeps its
--     impostor however close the camera goes, because the chunks there are
--     the anchor's coarse ones;
--   * a body smaller on screen than `minPixels` is left as the engine's dot.
--
-- A body big on screen, or the one the map focuses (far_bodies.focus(name)),
-- refines to level 5 (20 480 triangles) and, focused, level 6.
--
-- Meshes are built ONCE per body per level, time-sliced over frames (a few
-- hundred vertices a frame), and cached per save slot in
-- user://farlod/<slot>/<body>.L<n> keyed by the genspec, so a scene reload or
-- the next session reads them back instead of working them out again.
--
-- WHAT IT SAVES (engine 0.117.0-rc7, card 0479): a terrain body hidden with
-- `node.visible = false` (on it or an ancestor) draws nothing and plans no
-- meshing. So while a body's impostor is fully opaque the BODY NODE is hidden
-- (`hideChunks`) and its chunks, or the engine's ball, cost nothing; it is
-- shown again a little before the cross-fade starts (HIDE_SHOW, in body
-- radii), so its chunks are meshed by the time they fade in. Physics is not
-- touched (hiding keeps colliders; the sim meshes terrain on demand). Because
-- hiding a node hides everything under it, the impostor is NOT the body's
-- child: it hangs off the body's parent (the system group) and is placed in
-- the world every frame. Everything else under a body (its Core, its sea,
-- lakes, rivers, flora patches) hides with it, which is what is wanted: the
-- impostor paints the sea, and the rest is too small to see from there.
--
-- Cross-script:  local fb = findScript("far_bodies")
--                fb.focus("Taeth")   fb.focus(nil)   fb.stats()   fb.active

defaults = {
  --- On (1) or off (0). Off hides every impostor.
  on = 1,
  --- The camera within this many body radii of a world: its chunks show, the
  --- impostor fades out. It is fully in at 1.6× this.
  --@range 2 40
  nearRadii = 6,
  --- Smaller than this many pixels (radius) on screen: no impostor.
  --@range 0.5 20
  minPixels = 2.0,
  --- How far proud of the ground the impostor is drawn, in screen pixels, so
  --- the chunks or the engine's ball under it never poke through.
  --@range 0 6
  proudPixels = 1.5,
  --- How far toward the camera the impostor is drawn (body radii), shrunk to
  --- keep its size on screen, so it is in front of the chunks it covers. On a
  --- world with air, never more than half the cloud deck's height.
  --@range 0 1
  pullRadii = 0.4,
  --- Icosphere level for a far world (4 = 5 120 triangles).
  --@range 2 6
  level = 4,
  --- Level for a world that is big on screen (5 = 20 480 triangles).
  --@range 3 6
  bigLevel = 5,
  --- Level for the world the map focuses once it fills the view (3 × bigPixels;
  --- 6 = 81 920 triangles). Below that a focused world gets bigLevel first.
  --@range 3 7
  focusLevel = 6,
  --- Screen radius (px) above which a world refines to bigLevel.
  bigPixels = 70,
  --- Vertices worked out per frame (a vertex is ~10 noise calls, ~5–15 µs).
  --- The focused world's job gets 3× this.
  --@range 50 4000
  budget = 250,
  --- 1 = keep built meshes on disk per save slot.
  cache = 1,
  --- Brightness of the impostor's paint (the material colour it multiplies).
  --@range 0.2 4
  gain = 1.0,
  --- 1 = draw every impostor flat green (to see what it covers).
  debug = 0,
  --- 1 = hide a body's own terrain (its chunks or the engine's ball) while
  --- its impostor covers it fully, so it is neither drawn nor meshed.
  hideChunks = 1,
}

-- Published.
active = true
VERSION = 2

-- ── constants ────────────────────────────────────────────────────────────────

-- The engine's flip to its impostor ball (terrain_edit.rs IMPOSTOR_RADII 60,
-- back to chunks inside 0.7 of that). Between the two it depends on which way
-- the camera came, so the cover mesh is used from the lower one out.
local ENGINE_BALL_RADII = 42
-- hideChunks: a body's own terrain is shown again once the camera is within
-- HIDE_SHOW × (nearRadii × 1.6) — the distance the cross-fade starts at — so
-- its chunks have the camera's last stretch to mesh before they fade in, and
-- hidden again past HIDE_AGAIN × that (the gap keeps it from flickering).
local HIDE_SHOW, HIDE_AGAIN = 1.25, 1.4
-- The cover mesh stands this far outside the engine's ball.
local BALL_COVER = 1.004

-- Mean linear colour of each palette texture (terrain/system.palette, 32
-- slots), so a vertex reads like the textured ground it stands for: the
-- terrain shader draws triplanar(texture) × tint × 1.6. Worked out once from
-- the PNGs (64×64 mean, sRGB → linear).
PAL = {
  { 0.148, 0.055, 0.035 }, { 0.175, 0.151, 0.193 }, { 0.120, 0.104, 0.125 }, { 0.715, 0.433, 0.183 },
  { 0.349, 0.182, 0.078 }, { 0.220, 0.046, 0.000 }, { 0.422, 0.310, 0.552 }, { 0.088, 0.339, 0.721 },
  { 0.244, 0.263, 0.269 }, { 0.114, 0.099, 0.081 }, { 0.502, 0.421, 0.262 }, { 0.049, 0.399, 0.243 },
  { 0.056, 0.053, 0.052 }, { 0.196, 0.152, 0.135 }, { 0.344, 0.174, 0.075 }, { 0.349, 0.258, 0.134 },
  { 0.158, 0.150, 0.140 }, { 0.472, 0.451, 0.415 }, { 0.271, 0.177, 0.098 }, { 0.083, 0.083, 0.030 },
  { 0.068, 0.058, 0.053 }, { 0.444, 0.470, 0.507 }, { 0.248, 0.401, 0.494 }, { 0.158, 0.143, 0.129 },
  { 0.325, 0.301, 0.238 }, { 0.297, 0.239, 0.081 }, { 0.211, 0.048, 0.020 }, { 0.171, 0.146, 0.083 },
  { 0.053, 0.043, 0.044 }, { 0.100, 0.103, 0.111 }, { 0.063, 0.041, 0.021 }, { 0.145, 0.079, 0.025 },
}
-- procgen.rs tint(): 0.85 + 0.25 · vary, vary a small fbm averaging ~0.
local TINT_MEAN = 0.85
local SPLAT_GAIN = 1.6

local sqrt, abs, max, min, floor = math.sqrt, math.abs, math.max, math.min, math.floor
local asin, atan, deg = math.asin, math.atan, math.deg

-- ── the generator's ground, in Lua (relief.rs Layers::height) ────────────────

local function hrot(x, y, z)
  return 0.36 * x - 0.80 * y + 0.48 * z, 0.80 * x + 0.52 * y + 0.30 * z, -0.48 * x + 0.30 * y + 0.82 * z
end

-- floptle-core noise.rs `ridged`.
local function ridged(x, y, z, oct, sharp, seed)
  local amp, sum, norm = 1, 0, 0
  for i = 0, oct - 1 do
    local o = i * 19.19
    local n = min(1, abs(math.noise(x + o, y + o, z + o, seed)))
    sum = sum + (1 - n) ^ sharp * amp
    norm = norm + amp
    amp = amp * 0.5
    x, y, z = hrot(x, y, z)
    x, y, z = x * 2.03, y * 2.03, z * 2.03
  end
  return sum / max(norm, 1e-6)
end

local function sstep(a, b, x)
  local t = max(0, min(1, (x - a) / max(b - a, 1e-6)))
  return t * t * (3 - 2 * t)
end

local function smin(a, b, k)
  local h = max(0, min(1, 0.5 + 0.5 * (b - a) / k))
  return b + (a - b) * h - k * h * (1 - h)
end

local function terrace(h, step, sharp)
  local t = h / step
  local base = floor(t)
  local f = t - base
  local w = 0.5 * (1 - max(0, min(0.98, sharp)))
  return (base + sstep(0.5 - w, 0.5 + w, f)) * step
end

-- The engine's crater balls (procgen.rs Planet::new): rng(seed + 31), a
-- direction from three ranges, a radius between craterMin and craterMax.
local function craters_of(o)
  local n = floor(o.craters or 0)
  if n <= 0 or not rng then return nil end
  local R, relief = o.radius or 120, o.relief or 8
  local r = rng(((o.seed or 7) + 31) % 4294967296)
  local out = {}
  for i = 1, n do
    local x, y, z = r:range(-1, 1), r:range(-1, 1), r:range(-1, 1)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-9 then x, y, z, l = 1, 0, 0, 1 end
    x, y, z = x / l, y / l, z / l
    local cr = r:range(o.craterMin or 0.12, o.craterMax or 0.26) * R
    local k = R + relief * 0.3
    out[i] = { x * k, y * k, z * k, cr }
  end
  return out
end

-- Height of the ground above the radius in unit direction d, as the
-- generator works it out before carving rivers and ravines; craters as
-- Planet::ground_height takes them out.
function groundHeight(o, dx, dy, dz, crat)
  local seed = o.seed or 7
  local wx, wy, wz = dx, dy, dz
  local w = o.warp
  if w and (w.strength or 0) ~= 0 then
    local s = w.scale or 1
    local qx, qy, qz = dx * s, dy * s, dz * s
    wx = dx + math.fbm(qx + 311, qy + 311, qz + 311, 3, seed) * w.strength
    wy = dy + math.fbm(qx - 77, qy - 77, qz - 77, 3, seed) * w.strength
    wz = dz + math.fbm(qx + 19.5, qy + 19.5, qz + 19.5, 3, seed) * w.strength
  end
  local bf = o.bumpFreq or 4.3
  local h = math.fbm(wx * bf, wy * bf, wz * bf, 5, seed) * (o.relief or 8)
  local m = o.mountains
  if m then
    local edge = 1 - max(0, min(1, m.coverage or 0.5))
    local ms = (m.scale or 1) * 0.3
    local mask = sstep(edge - 0.12, edge + 0.12,
      0.5 + 0.5 * math.fbm(wx * ms + 241, wy * ms + 241, wz * ms + 241, 3, seed))
    if mask > 0 then
      local sc = m.scale or 1
      h = h + (m.height or 0) * mask * ridged(wx * sc + 57, wy * sc + 57, wz * sc + 57,
        max(1, min(8, m.octaves or 5)), max(0.1, m.sharpness or 2), seed)
    end
  end
  local p = o.plateau
  if p then h = smin(h, p.height or 0, max(0.01, p.smooth or 0.01)) end
  local t = o.terrace
  if t and (t.step or 0) > 0 then h = terrace(h, t.step, t.sharpness or 0.5) end
  if crat then
    local R = o.radius or 120
    local tt = R + h
    for i = 1, #crat do
      local c = crat[i]
      local b = dx * c[1] + dy * c[2] + dz * c[3]
      local disc = b * b - (c[1] * c[1] + c[2] * c[2] + c[3] * c[3]) + c[4] * c[4]
      if disc > 0 then
        local sd = sqrt(disc)
        if tt > b - sd and tt <= b + sd then tt = max(b - sd, 0) end
      end
    end
    h = tt - R
  end
  return h
end

-- ── the generator's paint (procgen.rs Planet::paint, at the surface) ─────────

local function within(rg, v) return rg == nil or (v >= rg[1] and v <= rg[2]) end

local function paint_color(p, dflt)
  local c = (p and p.color) or dflt
  local slot = p and p.slot or 0
  local pm = PAL[slot]
  if pm then
    return c[1] * pm[1] * SPLAT_GAIN * TINT_MEAN, c[2] * pm[2] * SPLAT_GAIN * TINT_MEAN, c[3] * pm[3] * SPLAT_GAIN * TINT_MEAN
  end
  return c[1] * TINT_MEAN, c[2] * TINT_MEAN, c[3] * TINT_MEAN
end

local A_DEFAULT = { slot = 1, color = { 0.72, 0.62, 0.58 } }
local B_DEFAULT = { slot = 2, color = { 0.66, 0.6, 0.74 } }

-- The paint at unit direction d, ground `h` above the radius, local slope in
-- degrees: the {slot, color} the generator would lay there. Crater floors wear
-- dust; nearRiver rules never match (no river polylines for a far world).
local DUST = { slot = 11, color = { 0.78, 0.74, 0.66 } }
local ICE = { slot = 0, color = { 0.9, 0.95, 1 } }
function surfacePaint(o, dx, dy, dz, h, slope, crat)
  local seed = o.seed or 7
  local biomes = o.biomes
  if biomes and #biomes > 0 then
    local lat = deg(asin(min(1, abs(dy))))
    local moist
    for i = 1, #biomes do
      local b = biomes[i]
      if within(b.latitude, lat) and within(b.altitude, h) and within(b.slope, slope) then
        local ok = b.nearRiver == nil
        if ok and b.moisture then
          if not moist then
            local s = o.moistureScale or 1.5
            moist = math.fbm(dx * s + 913, dy * s + 913, dz * s + 913, 3, seed)
          end
          ok = within(b.moisture, moist)
        end
        if ok then return b end
      end
    end
  end
  if crat then
    local R = o.radius or 120
    local px, py, pz = dx * (R + h), dy * (R + h), dz * (R + h)
    for i = 1, #crat do
      local c = crat[i]
      local ex, ey, ez = px - c[1], py - c[2], pz - c[3]
      if sqrt(ex * ex + ey * ey + ez * ez) < c[4] + 1.6 then return o.craterDust or DUST end
    end
  end
  local patch = math.fbm(dx * 9 + 37, dy * 9 + 37, dz * 9 + 37, 3, seed)
  local ic = o.iceCaps
  if ic and (abs(dy) > (ic.lat or 2) or patch < -0.42) then return ic.color and ic or ICE end
  local alt = h / max(o.relief or 8, 1)
  if patch + alt * (o.patchBias or 0.45) > (o.patchThr or 0.08) then return o.surfaceA or A_DEFAULT end
  return o.surfaceB or B_DEFAULT
end

function surfaceColor(o, dx, dy, dz, h, slope, crat)
  return paint_color(surfacePaint(o, dx, dy, dz, h, slope, crat), { 0.7, 0.7, 0.7 })
end

-- ── icospheres ───────────────────────────────────────────────────────────────

-- Level n: 10·4ⁿ + 2 vertices, 20·4ⁿ triangles. Built once per level, as a
-- job of its own (time-sliced like the rest), and shared by every body.
local TOPO, TOPO_JOB = {}, {}
local work -- (below: the time-slicing counter every job spends)

local function topo_job(level)
  return coroutine.create(function()
    local t = (1 + sqrt(5)) / 2
    local V = {
      { -1, t, 0 }, { 1, t, 0 }, { -1, -t, 0 }, { 1, -t, 0 },
      { 0, -1, t }, { 0, 1, t }, { 0, -1, -t }, { 0, 1, -t },
      { t, 0, -1 }, { t, 0, 1 }, { -t, 0, -1 }, { -t, 0, 1 },
    }
    local P = {}
    for i, v in ipairs(V) do
      local l = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
      P[i * 3 - 2], P[i * 3 - 1], P[i * 3] = v[1] / l, v[2] / l, v[3] / l
    end
    local F = {
      1, 12, 6, 1, 6, 2, 1, 2, 8, 1, 8, 11, 1, 11, 12,
      2, 6, 10, 6, 12, 5, 12, 11, 3, 11, 8, 7, 8, 2, 9,
      4, 10, 5, 4, 5, 3, 4, 3, 7, 4, 7, 9, 4, 9, 10,
      5, 10, 6, 3, 5, 12, 7, 3, 11, 9, 7, 8, 10, 9, 2,
    }
    local nv = 12
    for _ = 1, level do
      local mid = {}
      local function m(a, b)
        local k = a < b and (a * 1048576 + b) or (b * 1048576 + a)
        local i = mid[k]
        if i then return i end
        local x = P[a * 3 - 2] + P[b * 3 - 2]
        local y = P[a * 3 - 1] + P[b * 3 - 1]
        local z = P[a * 3] + P[b * 3]
        local l = sqrt(x * x + y * y + z * z)
        nv = nv + 1
        P[nv * 3 - 2], P[nv * 3 - 1], P[nv * 3] = x / l, y / l, z / l
        mid[k] = nv
        return nv
      end
      local F2 = {}
      for i = 1, #F, 3 do
        local a, b, c = F[i], F[i + 1], F[i + 2]
        local ab, bc, ca = m(a, b), m(b, c), m(c, a)
        local n = #F2
        F2[n + 1], F2[n + 2], F2[n + 3] = a, ab, ca
        F2[n + 4], F2[n + 5], F2[n + 6] = b, bc, ab
        F2[n + 7], F2[n + 8], F2[n + 9] = c, ca, bc
        F2[n + 10], F2[n + 11], F2[n + 12] = ab, bc, ca
        work(-0.15)
      end
      F = F2
    end
    -- Neighbours, for the slope a biome rule reads: each vertex's ring.
    local N = {}
    for i = 1, nv do N[i] = {} end
    local function link(a, b)
      local na = N[a]
      for j = 1, #na do if na[j] == b then return end end
      na[#na + 1] = b
    end
    for i = 1, #F, 3 do
      local a, b, c = F[i], F[i + 1], F[i + 2]
      link(a, b); link(b, a); link(b, c); link(c, b); link(c, a); link(a, c)
      work(-0.1)
    end
    TOPO[level] = { dirs = P, idx = F, nb = N, n = nv }
  end)
end

-- ── per-save cache ───────────────────────────────────────────────────────────

-- A stable string of what shapes and paints a world, so a cached mesh is only
-- read back for the genspec it was made from.
local function ser(v, out)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      out[#out + 1] = k .. "="
      ser(val, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "number" then
    out[#out + 1] = string.format("%.6g", v)
  else
    out[#out + 1] = tostring(v)
  end
end

function hashKey(o, sea, extra)
  local parts = {}
  ser(o, parts)
  parts[#parts + 1] = "|" .. string.format("%.3f", sea or 0) .. "|" .. tostring(extra or "")
  local s = table.concat(parts)
  local h1, h2 = 5381, 52711
  for i = 1, #s do
    local c = s:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 31 + c * 7) % 4294967296
  end
  return string.format("v%d-%08x%08x", VERSION, h1, h2)
end

-- Heights as 16-bit steps over [lo, hi], colours as bytes: 5 bytes a vertex.
function encode(key, H, C, n, tick)
  local lo, hi = math.huge, -math.huge
  for i = 1, n do lo = min(lo, H[i]); hi = max(hi, H[i]) end
  if hi <= lo then hi = lo + 1 end
  local sc = 65535 / (hi - lo)
  local out = { string.format("FLOD1 %s %d %.6f %.6f\n", key, n, lo, hi) }
  local buf = {}
  local char = string.char
  for i = 1, n do
    local q = floor((H[i] - lo) * sc + 0.5)
    local r = floor(max(0, min(1, C[i * 3 - 2])) * 255 + 0.5)
    local g = floor(max(0, min(1, C[i * 3 - 1])) * 255 + 0.5)
    local b = floor(max(0, min(1, C[i * 3])) * 255 + 0.5)
    buf[#buf + 1] = char(floor(q / 256), q % 256, r, g, b)
    if #buf >= 512 then out[#out + 1] = table.concat(buf); buf = {} end
    if tick then tick(-0.2) end
  end
  out[#out + 1] = table.concat(buf)
  return table.concat(out)
end

function decode(s, key, n, tick)
  if type(s) ~= "string" then return nil end
  local nl = s:find("\n", 1, true)
  if not nl then return nil end
  local tag, k, cnt, lo, hi = s:sub(1, nl - 1):match("^(%S+) (%S+) (%d+) (%S+) (%S+)$")
  if tag ~= "FLOD1" or k ~= key or tonumber(cnt) ~= n then return nil end
  lo, hi = tonumber(lo), tonumber(hi)
  if not (lo and hi) or #s < nl + n * 5 then return nil end
  local sc = (hi - lo) / 65535
  local H, C = {}, {}
  local byte = string.byte
  local p = nl + 1
  for i = 1, n do
    local a, b, r, g, bl = byte(s, p, p + 4)
    H[i] = lo + (a * 256 + b) * sc
    C[i * 3 - 2], C[i * 3 - 1], C[i * 3] = r / 255, g / 255, bl / 255
    p = p + 5
    if tick then tick(-0.1) end
  end
  return H, C
end

local function cache_path(body, level)
  local slot = (save and save.slot and save.slot()) or "noslot"
  return string.format("user://farlod/%s/%s.L%d", slot, body, level)
end

local function cache_read(body, level, key, n, tick)
  if params.cache <= 0 or not (assets and assets.readBytes) then return nil end
  local ok, s = pcall(assets.readBytes, cache_path(body, level))
  if not ok or type(s) ~= "string" then return nil end
  if data and data.inflate then
    local ok2, raw = pcall(data.inflate, s)
    if ok2 and type(raw) == "string" then s = raw end
  end
  return decode(s, key, n, tick)
end

local function cache_write(body, level, key, H, C, n, tick)
  if params.cache <= 0 or not (assets and assets.writeBytes) then return end
  local s = encode(key, H, C, n, tick)
  if data and data.deflate then
    local ok, z = pcall(data.deflate, s)
    if ok and type(z) == "string" then s = z end
  end
  pcall(assets.writeBytes, cache_path(body, level), s)
end

-- ── bodies ───────────────────────────────────────────────────────────────────

-- name → { name, node, o, R (terrain radius), Rb (celestial radius), sea,
--          water = {r,g,b}, lakes, crat, key, mesh = { [level] = { true=, cover= } },
--          imp (our node), shown, alpha, level, jobs }
local B = {}
local queue = {} -- pending build jobs: { body, level, co, prio }
local focused = nil
local gen_ref
local S = { built = 0, cached = 0, verts = 0, buildMs = 0, frames = 0, shown = 0, hides = 0, lastErr = nil }

local function genspec(name)
  if not (gen_ref and gen_ref.valid ~= false) then gen_ref = findScript and findScript("system_generator") end
  local gs = gen_ref and gen_ref.GENSPEC
  return gs and gs[name]
end

-- What a world is made from: its genspec, else what its world record says.
local function opts_of(name)
  local gs = genspec(name)
  local w = save.get("world." .. name)
  if gs and gs.opts then return gs.opts, w end
  if w and w.radius then
    return { radius = w.radius, relief = w.relief or 6, seed = w.seed or 7, bumpFreq = 4.3,
      surfaceA = w.ground and { slot = 0, color = w.ground } or nil,
      surfaceB = w.ground and { slot = 0, color = w.ground } or nil }, w
  end
  return nil, w
end

local function water_of(w)
  if not w then return nil end
  if w.water and w.water.state == "ice" then return { 0.80, 0.86, 0.92 } end
  local c = (w.water and (w.water.deep or w.water.shallow)) or (w.bio and w.bio.palette and w.bio.palette.water)
  if type(c) == "table" and c[1] then return { c[1] * 0.6, c[2] * 0.6, c[3] * 0.6 } end
  return { 0.05, 0.14, 0.24 }
end

local function lakes_of(name, R)
  local h = save.get("hydro." .. name)
  if not (h and h.lakes) then return nil end
  local out = {}
  for _, l in ipairs(h.lakes) do
    local x, y, z = l.x or (l.center and l.center.x), l.y or (l.center and l.center.y), l.z or (l.center and l.center.z)
    if x and l.level and l.reach then
      local d = sqrt(x * x + y * y + z * z)
      if d > 0 then out[#out + 1] = { x / d, y / d, z / d, math.cos(l.reach / R), l.level } end
    end
  end
  return #out > 0 and out or nil
end

local function track(sb)
  local e = B[sb.name]
  if e then return e end
  local o, w = opts_of(sb.name)
  if not o then return nil end
  local node = find and find(sb.name)
  if not (node and node.valid ~= false) then return nil end
  local R = o.radius or sb.radius
  e = {
    name = sb.name, node = node, o = o, R = R, Rb = sb.radius,
    sea = (w and (w.sea or 0) > 0) and w.sea or nil,
    water = water_of(w), lakes = lakes_of(sb.name, R), crat = craters_of(o),
    mesh = {}, level = 0, alpha = 0, jobs = {},
  }
  e.key = hashKey(o, e.sea, e.lakes and #e.lakes or 0)
  -- The air: the pull toward the camera (see lateUpdate) must stay under the
  -- cloud deck, or the impostor would be drawn in front of the clouds.
  local ok, cb = pcall(function() return node:getcomponent("CelestialBody") end)
  if ok and cb then
    local ah = tonumber(cb.atmoHeight) or 0
    if ah > 0 and (tonumber(cb.atmoDensity) or 1) > 0 then
      local deck = ah * (tonumber(cb.cloudHeight) or 0.35)
      e.pullMax = max(0, deck * 0.5)
    end
  end
  B[sb.name] = e
  return e
end

-- ── building a mesh (a job) ──────────────────────────────────────────────────

local units = 0
work = function(n)
  units = units + n
  if units <= 0 then
    local co, main = coroutine.running()
    if co and not main then coroutine.yield() end
  end
end

-- Does any biome rule of this world read the slope?
function slope_rules(o)
  for _, b in ipairs(o.biomes or {}) do if b.slope then return true end end
  return false
end

-- The ground's slope (as a tangent) at unit direction d, over an angular step
-- `e`: forward differences along two tangents (relief.rs slope_degrees uses
-- central ones on its grid; one-sided costs two samples, not four).
function fine_slope(o, dx, dy, dz, h0, e, R, crat)
  local ax, ay, az = 1, 0, 0
  if abs(dx) > 0.9 then ax, ay, az = 0, 1, 0 end
  local t1x, t1y, t1z = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
  local l1 = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
  t1x, t1y, t1z = t1x / l1, t1y / l1, t1z / l1
  local t2x, t2y, t2z = dy * t1z - dz * t1y, dz * t1x - dx * t1z, dx * t1y - dy * t1x
  local px, py, pz = dx + t1x * e, dy + t1y * e, dz + t1z * e
  local lp = sqrt(px * px + py * py + pz * pz)
  local qx, qy, qz = dx + t2x * e, dy + t2y * e, dz + t2z * e
  local lq = sqrt(qx * qx + qy * qy + qz * qz)
  local g1 = groundHeight(o, px / lp, py / lp, pz / lp, crat) - h0
  local g2 = groundHeight(o, qx / lq, qy / lq, qz / lq, crat) - h0
  return sqrt(g1 * g1 + g2 * g2) / (e * max(R, 1))
end

local function build_job(e, level)
  return coroutine.create(function()
    while not TOPO[level] do
      units = 0
      coroutine.yield()
    end
    local T = TOPO[level]
    local n, D = T.n, T.dirs
    local o, R = e.o, e.R
    local H, C = cache_read(e.name, level, e.key, n, work)
    if H then
      S.cached = S.cached + 1
    else
      H, C = {}, {}
      for i = 1, n do
        H[i] = groundHeight(o, D[i * 3 - 2], D[i * 3 - 1], D[i * 3], e.crat)
        work(-1)
      end
      -- Slope, then paint. A biome that reads slope (cliffs are rock) is
      -- asked at the ground's OWN scale, as the generator does (its relief
      -- grid's step, ~a voxel): a slope measured between this mesh's vertices,
      -- tens of metres apart, smooths every cliff away and paints a craggy
      -- world the colour of its plains. Two more ground samples a vertex, only
      -- on worlds with such a rule; otherwise the ring of neighbours will do.
      local NB = T.nb
      local fine = slope_rules(o)
      local fe = 2 / max(16, min(1024, math.ceil(2 * R / max(o.voxel or 1.5, 0.25))))
      for i = 1, n do
        local dx, dy, dz = D[i * 3 - 2], D[i * 3 - 1], D[i * 3]
        local sl = 0
        if fine then
          sl = fine_slope(o, dx, dy, dz, H[i], fe, R, e.crat)
          work(-2)
        else
          local ring = NB[i]
          for j = 1, #ring do
            local k = ring[j]
            local ex, ey, ez = D[k * 3 - 2] - dx, D[k * 3 - 1] - dy, D[k * 3] - dz
            local run = sqrt(ex * ex + ey * ey + ez * ez) * R
            if run > 0 then sl = max(sl, abs(H[k] - H[i]) / run) end
          end
        end
        local r, g, b = surfaceColor(o, dx, dy, dz, H[i], deg(atan(sl)), e.crat)
        -- standing water: the sea, and the lakes the hydro record knows
        local wet = e.sea and (R + H[i]) < e.sea
        if not wet and e.lakes then
          for _, l in ipairs(e.lakes) do
            if dx * l[1] + dy * l[2] + dz * l[3] > l[4] and H[i] < l[5] then wet = true; break end
          end
        end
        if wet and e.water then r, g, b = e.water[1], e.water[2], e.water[3] end
        C[i * 3 - 2], C[i * 3 - 1], C[i * 3] = r, g, b
        work(-1)
      end
      cache_write(e.name, level, e.key, H, C, n, work)
    end
    -- Two meshes from the one set of heights: TRUE (the ground, the sea's
    -- surface where it is under the sea) for where the engine draws chunks,
    -- and COVER (nothing lower than just outside the engine's ball) for where
    -- it draws its ball. Positions are body-local metres.
    local Pt, Pc, Cl = {}, {}, {}
    local floor_r = e.Rb * BALL_COVER
    local wl = e.sea or 0
    for i = 1, n do
      local r = max(R + H[i], wl)
      local dx, dy, dz = D[i * 3 - 2], D[i * 3 - 1], D[i * 3]
      Pt[i * 3 - 2], Pt[i * 3 - 1], Pt[i * 3] = dx * r, dy * r, dz * r
      local rc = max(r, floor_r)
      Pc[i * 3 - 2], Pc[i * 3 - 1], Pc[i * 3] = dx * rc, dy * rc, dz * rc
      Cl[i * 4 - 3], Cl[i * 4 - 2], Cl[i * 4 - 1], Cl[i * 4] = C[i * 3 - 2], C[i * 3 - 1], C[i * 3], 1
      work(-0.3)
    end
    -- the two uploads on frames of their own
    units = 0
    coroutine.yield()
    local mt = mesh.build { positions = Pt, indices = T.idx, colors = Cl }
    units = 0
    coroutine.yield()
    local mc = mesh.build { positions = Pc, indices = T.idx, colors = Cl }
    local old = e.mesh[level]
    e.mesh[level] = { ["true"] = mt, cover = mc, n = n }
    if old then
      pcall(mesh.free, old["true"]); pcall(mesh.free, old.cover)
    end
    S.built = S.built + 1
    S.verts = S.verts + n
  end)
end

local function want(e, level, prio)
  if e.mesh[level] or e.jobs[level] then
    if e.jobs[level] then e.jobs[level].prio = max(e.jobs[level].prio, prio) end
    return
  end
  if not TOPO[level] and not TOPO_JOB[level] then
    TOPO_JOB[level] = true
    queue[#queue + 1] = { level = level, co = topo_job(level), prio = math.huge, name = "topology" }
  end
  local j = { e = e, level = level, co = build_job(e, level), prio = prio, name = e.name }
  e.jobs[level] = j
  queue[#queue + 1] = j
end

local function run_jobs(dt)
  if #queue == 0 then return end
  table.sort(queue, function(a, b) return a.prio > b.prio end)
  local j = queue[1]
  local budget = params.budget * ((j.name == focused) and 3 or 1)
  units = budget
  local t0 = os and os.clock and os.clock()
  local ok, err = coroutine.resume(j.co)
  if t0 then S.buildMs = S.buildMs + (os.clock() - t0) * 1000 end
  if not ok then
    S.lastErr = tostring(err)
    print("far_bodies: building " .. j.name .. " L" .. j.level .. " failed: " .. tostring(err))
  end
  if not ok or coroutine.status(j.co) == "dead" then
    table.remove(queue, 1)
    if j.e then j.e.jobs[j.level] = nil elseif not ok then TOPO_JOB[j.level] = nil end
  end
end

-- ── the impostor node ────────────────────────────────────────────────────────

local function ensure_node(e)
  if e.imp ~= nil then return e.imp end
  e.imp = false
  -- Under the body's PARENT, not the body: the body node is hidden while the
  -- impostor covers it (hideChunks), and a hidden node hides its children.
  -- (Rails bodies do not turn, so the parent's frame is the body's.)
  local parent = e.node.parent
  if parent and parent.valid == false then parent = nil end
  createNode("FarLOD " .. e.name, parent, function(n)
    n.tags = { "farlod" }
    n.castShadow = false
    n.visible = false
    e.imp = n
  end)
  return false
end

local function set_look(e, model, alpha, scale, px, py, pz)
  local n = e.imp
  if not (n and n.valid ~= false) then return end
  if e.model ~= model then n.model = model; e.model = model end
  local qa = floor(alpha * 32 + 0.5) / 32
  local mk = qa + params.debug * 10 + params.gain * 100
  if e.qa ~= mk then
    local g = params.gain
    local m = { color = { g, g, g }, alpha = qa }
    if params.debug > 0 then m.color = { 0, 1, 0 }; m.unlit = true end
    n:setMaterial(m)
    e.qa = mk
  end
  if not e.scale or abs(e.scale - scale) > 1e-5 then n.scale = scale; e.scale = scale end
  -- (node.x is the LOCAL position: the body may be turned; place it in the world)
  if n.setWorldPos and vec3 then n:setWorldPos(vec3(px, py, pz)) end
  local vis = qa > 0
  if e.vis ~= vis then n.visible = vis; e.vis = vis end
end

local function hide(e)
  if e.imp and e.imp.valid ~= false and e.vis then e.imp.visible = false end
  e.vis = false
end

-- The body's own terrain drawn (true) or hidden under its impostor (false).
local function body_shown(e, on)
  if e.hidden == (not on) then return end
  if e.node and e.node.valid ~= false then e.node.visible = on end
  e.hidden = not on
  if not on then S.hides = S.hides + 1 end
end

-- Should the body's own terrain be hidden? `a` is the impostor's alpha, `dc`
-- and `dl` its distance from the camera and the LOD anchor, `was` whether it
-- is hidden now. Hidden only under a fully opaque impostor that is drawn
-- (`ready`); shown again from HIDE_SHOW × the fade's start, or at once if the
-- impostor goes. The map case (detail anchored far away) hides at any range:
-- the chunks there are the anchor's coarse ones and the impostor stays on.
function hideRule(dc, dl, Rb, a, ready, was)
  if params.hideChunks <= 0 or not ready or a < 0.999 then return false end
  if dl > dc * 2.5 then return true end
  local start = params.nearRadii * 1.6 * Rb
  if was then return dc > start * HIDE_SHOW end
  return dc > start * HIDE_AGAIN
end

-- ── the camera ───────────────────────────────────────────────────────────────

-- Camera position and pixels per radian, from the camera the player sees.
local function cam_state()
  if not (camera and camera.exists and camera.exists()) then return nil end
  local w, h = camera.screenSize()
  if not (w and h and h > 0) then return nil end
  local cx, cy = w * 0.5, h * 0.5
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(cx, cy)
  local _, _, _, ex, ey, ez = camera.screenToRay(cx, cy + h * 0.25)
  if not (ox and ex) then return nil end
  local c = max(-1, min(1, (dx * ex + dy * ey + dz * ez) / max(1e-9, sqrt(dx * dx + dy * dy + dz * dz) * sqrt(ex * ex + ey * ey + ez * ez))))
  local ang = math.acos(c)
  if ang < 1e-6 then return nil end
  return ox, oy, oz, (h * 0.25) / ang
end

local function lod_centre(cx, cy, cz)
  if terrain and terrain.lodAnchor then
    local ok, a = pcall(terrain.lodAnchor)
    if ok and a and a.x and (a.valid == nil or a.valid) then return a.x, a.y, a.z end
  end
  return cx, cy, cz
end

-- ── API ──────────────────────────────────────────────────────────────────────

-- The map (or anything framing a world) names the body it looks at; nil clears.
function focus(name)
  focused = name
end

function focusedBody() return focused end

function setActive(on)
  active = on and true or false
  if not active then for _, e in pairs(B) do hide(e); body_shown(e, true) end end
end

-- One line for probes and logs.
function stats()
  local n, shown, lv, nh = 0, 0, {}, 0
  for name, e in pairs(B) do
    n = n + 1
    if e.vis then shown = shown + 1 end
    if e.hidden then nh = nh + 1 end
    local ls = {}
    for l in pairs(e.mesh) do ls[#ls + 1] = l end
    table.sort(ls)
    local off = ""
    if e.vis and e.imp and e.imp.worldPos and e.node and e.node.worldPos then
      local a, b = e.imp.worldPos, e.node.worldPos
      off = string.format(" pull %.0f/%.0f m%s", sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2), e.pull or 0,
        e.pullMax and string.format(" (air: max %.0f)", e.pullMax) or "")
    end
    lv[#lv + 1] = string.format("%s[%s|L%s a%.2f %s%s%s]", name, table.concat(ls, ","), tostring(e.level), e.alpha or 0,
      e.cover and "cover" or "true", off, e.hidden and " terrain-hidden" or "")
  end
  table.sort(lv)
  return string.format("tracked %d shown %d hidden %d (hides %d) built %d cached %d verts %d buildMs %.0f queue %d focus %s err %s :: %s",
    n, shown, nh, S.hides, S.built, S.cached, S.verts, S.buildMs, #queue, tostring(focused), tostring(S.lastErr), table.concat(lv, " "))
end

-- The decision for one body, given the camera: (alpha, wanted level, cover?).
-- Exposed so the smoke test can pin the rules without an engine.
function decide(dc, dl, Rb, px, isFocus, resident)
  local near = params.nearRadii
  local a = sstep(near, near * 1.6, dc / Rb)
  -- terrain detail anchored far away (the map): the chunks here are coarse
  if dl > dc * 2.5 then a = max(a, sstep(2.5, 4, dl / max(dc, 1e-6))) end
  a = a * sstep(params.minPixels, params.minPixels * 2, px)
  local lvl = params.level
  if px > params.bigPixels then lvl = max(lvl, params.bigLevel) end
  if isFocus then lvl = max(lvl, px > params.bigPixels * 3 and params.focusLevel or params.bigLevel) end
  local cover = (not resident) or dl > ENGINE_BALL_RADII * Rb
  return a, lvl, cover
end

-- ── frame ────────────────────────────────────────────────────────────────────

local scan_t = -10

-- Is the body's field resident (its centre reads as inside rock)?
local function resident(sb)
  if not (terrain and terrain.query) then return false end
  local d = terrain.query(sb.x, sb.y, sb.z)
  return d ~= nil and d < 0
end

function lateUpdate(node, dt)
  S.frames = S.frames + 1
  active = params.on > 0 and active
  if not active then
    for _, e in pairs(B) do if e.vis or e.hidden then hide(e); body_shown(e, true) end end
    return
  end
  if not (space and space.bodies and mesh and mesh.build) then return end
  local cx, cy, cz, ppr = cam_state()
  if not cx then return end
  local lx, ly, lz = lod_centre(cx, cy, cz)

  local now = time or 0
  local rescan = now - scan_t > 1.0
  if rescan then scan_t = now end
  local shown = 0
  for _, sb in ipairs(space.bodies()) do
    if (sb.soi or 0) >= 0 and (sb.radius or 0) > 0 then
      local e = B[sb.name]
      if not e and rescan then e = track(sb) end
      if e and not (e.node and e.node.valid ~= false) then
        B[sb.name] = nil
        e = nil
      end
      if e then
        local Rb = sb.radius
        local dx, dy, dz = sb.x - cx, sb.y - cy, sb.z - cz
        local dc = sqrt(dx * dx + dy * dy + dz * dz)
        local ex, ey, ez = sb.x - lx, sb.y - ly, sb.z - lz
        local dl = sqrt(ex * ex + ey * ey + ez * ez)
        local px = ppr * asin(min(1, Rb / max(dc, Rb)))
        local isF = (focused == sb.name)
        if rescan or e.res == nil then e.res = resident(sb) end
        local a, lvl, cover = decide(dc, dl, Rb, px, isF, e.res)
        e.cover = cover
        -- Build what is wanted: the base level for anything near showing, and
        -- the refined one once it is big on screen or focused.
        if a > 0 or px > params.minPixels * 0.5 or isF then
          want(e, params.level, px + (isF and 1e6 or 0))
          if lvl > params.level then want(e, lvl, px + (isF and 2e6 or 0)) end
        end
        -- Draw the best level that is ready.
        local best
        for l = lvl, 1, -1 do if e.mesh[l] then best = l; break end end
        if not best then for l, _ in pairs(e.mesh) do best = max(best or 0, l) end end
        e.level = best or 0
        e.alpha = a
        if best and a > 0.001 and ensure_node(e) then
          local m = e.mesh[best]
          -- In FRONT of what the engine draws there, without looking any
          -- bigger: moved `pull` toward the camera and shrunk by the same
          -- ratio, so the silhouette is where it was and the whole surface is
          -- nearer than the chunks (a coarse chunk bulges up to a coarse
          -- voxel off the ground) or the ball. And a pixel or two proud at
          -- the limb, where the pull does not help.
          local proud = params.proudPixels * dc / max(ppr, 1)
          local base = cover and e.Rb * BALL_COVER or e.R
          local pull = min(params.pullRadii * Rb, (dc - Rb) * 0.5, e.pullMax or math.huge)
          if pull < 0 then pull = 0 end
          local k = pull / dc
          e.pull = pull
          set_look(e, cover and m.cover or m["true"], a, (1 + proud / max(base, 1)) * (dc - pull) / dc,
            sb.x - dx * k, sb.y - dy * k, sb.z - dz * k)
          shown = shown + 1
          body_shown(e, not hideRule(dc, dl, Rb, a, e.vis, e.hidden))
        else
          hide(e)
          body_shown(e, true)
        end
      end
    end
  end
  S.shown = shown
  run_jobs(dt)
end

function onDestroy()
  for _, e in pairs(B) do
    body_shown(e, true)
    for _, m in pairs(e.mesh) do
      pcall(mesh.free, m["true"]); pcall(mesh.free, m.cover)
    end
  end
end
