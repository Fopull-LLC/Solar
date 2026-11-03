-- MINERAL FIELD — the rock lying on a planet's surface, and the ore you can
-- break off it without digging a hole.
--
-- Between the colony buildings, every world in this game used to be a bare
-- shell: terrain, and nothing standing on it. This puts gravel, stones,
-- boulder fields and the odd crystal outcrop on every rocky world, with the
-- engine's GPU-instanced `scatter` — no scene node per rock — and lets the
-- mining laser break them for ore.
--
-- HOW IT IS LAID OUT (the same scheme as flora_field, and for the same
-- reasons). The surface is cut into square PATCHES on a cube-face grid; each
-- patch is one small node, a child of the planet, lying in the tangent plane at
-- its centre and squared to the grid. Each rock kind is one Ground-region
-- scatter source per patch near you, whose density grid is the kind's own
-- placement rule sampled across the patch. The engine drops every rock onto
-- the real terrain below the plane.
--
-- WHY NOT ONE SPHERE SOURCE PER KIND (as this file once did). Engine 0.117
-- (card 0424) fixed the sphere region's face decode and made ids exact, so a
-- sphere source would place rocks correctly now. Patches stay because they
-- are what the flora uses too (one scheme, one set of seams), because a
-- sphere's density grid would have to cover the whole planet at declare time,
-- and because a patch that nobody walks near is never built. With `parent`,
-- a region's `center` is in the PARENT's frame: (0,0,0) here, the patch node.
--
-- BREAKING A ROCK is `scatter.remove(source, id)`: one instance, by its exact
-- id; the engine re-resolves that one chunk. The source's `scatter.removed()`
-- list is the save (per patch and kind), re-applied whenever the source is
-- declared again, and restored after `regrow` seconds. Saves from before kept
-- "holes" (positions in the patch plane); those become ids the first time the
-- patch is built, and the old record is deleted.
--
-- Cross-script:  local mf = findScript("mineral_field")
--                mf.nearest(x, y, z, radius)   mf.breakAt(hit, "astro")

defaults = {
  --@header Density
  -- Multiplies every kind's rocks per square metre. This is how CLUTTERED the
  -- ground looks.
  --@range 0 3
  density = 1.0,

  --@header Look
  -- Multiplies every kind's draw distance. Residency follows the outermost
  -- band; a resident rock costs ~0.1–0.2 µs a frame on engine 0.117 (was
  -- 1–4 µs on 0.116.1), so this is a look knob more than a budget now.
  --@range 0.3 1.5
  reach = 0.8,
  -- Metres over which one LOD band cross-dissolves into the next. Kept to a
  -- few metres: the engine's dissolve is a screen door, so every rock inside
  -- a window draws as a grid of dots (flora_gen.fadeBands).
  --@range 0 40 --@units m
  fade = 3.0,
  -- Dissolve rocks out at the edge of their reach (1) or cut them (0).
  fade_out = 1,
  -- Patch size as a fraction of the planet's radius (clamped to 150..260 m).
  --@range 0.3 0.9
  patch = 0.6,
  -- Density-grid resolution per patch side.
  --@range 6 24
  rows = 12,
  -- Above this height nothing new is laid out.
  --@range 100 1000 --@units m
  alt_max = 450.0,

  --@header Harvest
  -- How close the beam has to pass to a rock to break it.
  --@range 0.5 6 --@units m
  grab = 2.2,
  -- Seconds before a broken rock grows back. Long, because a base's
  -- surroundings SHOULD strip out — that's the reason to fly somewhere else.
  --@range 0 100000 --@units s
  regrow = 2400.0,

  --@header Ore pockets
  -- The rare pockets underground (climate.rareScan places them; flora_field
  -- keeps the answer in the save). Units of Star Geode each one holds.
  --@range 1 20
  pocket_units = 6,
  -- With the Terrain Laser out, ground within this range of a pocket shows a
  -- faint pulsing ring and how deep it lies: the suit's resonance sensor.
  --@range 0 80 --@units m
  pocket_hint = 35.0,

  --@header Ore veins
  -- Ore lies in VEINS running through the rock, most of them BURIED: you find
  -- them by digging or caving, and only some of the common ores crop out at
  -- the surface with outcrops (see "ore veins"). Veins per patch, on average,
  -- buried and surfaced together (0 = none).
  --@range 0 16
  vein_rate = 6.0,
  -- The share of veins that crop out at the surface (common ores only).
  --@range 0 1
  vein_surface = 0.2,
  -- A buried vein's walls are painted where a cave or a tunnel already opens
  -- onto it when you come this near (only ground near an open face takes paint).
  --@range 10 120 --@units m
  vein_cave = 45.0,
  -- A vein is painted into the ground when you come this near it (the paint
  -- is a terrain edit, kept in the save: only veins someone came near cost
  -- anything).
  --@range 20 150 --@units m
  vein_paint = 75.0,
  -- Its outcrops are drawn within this range.
  --@range 30 300 --@units m
  vein_show = 150.0,
  -- Outcrop nodes kept at once, all veins together.
  --@range 0 200
  outcrop_max = 72,
  -- Float: broken bits of the ore lying along a seam and just past it, the
  -- way a prospector finds a vein (an instanced scatter per vein, no nodes).
  -- Multiplies how thickly it lies (0 = none).
  --@range 0 3
  vein_float = 1.0,
  -- Float is laid out within this range of a vein, and drawn out to ~70 m.
  --@range 30 200 --@units m
  float_show = 90.0,
  -- Cubic metres of cut ground per unit in the pack: the laser pays out by
  -- the volume it actually removed, of the material it removed
  -- (terrain.yields), not by a timer. The laser takes out ~35–45 m³ a
  -- second at full power (measured, engine 0.117.1), so 30 m³ keeps the old
  -- pace of about a unit a second in plain ground; ore is 0.4 of it.
  --@range 0.05 20 --@units m3
  dig_unit = 30.0,

  enabled = 1,
}

-- Published for the HUD and the smoke harness.
bodyName = nil
sources = 0
patchCount = 0
anchored = false
count = 0

-- ── what lies where ─────────────────────────────────────────────────────────
-- One source per rock KIND per patch, because a scatter source draws one LOD
-- chain and nothing else. `area` is rocks per square metre at full density —
-- the same numbers the old field used (14 per 34 m chunk × the kind's share) —
-- and `chunk` is chosen so a chunk holds only a few: the engine drops a whole
-- chunk onto the ground at once, a raycast per rock, and a chunk of many is a
-- visible hitch as you walk.
--
-- `density` is a PURE function of the point on the unit sphere — the engine
-- samples it into the grid, and placement has to stay derivable.
local KINDS = {
  {
    id = "gravel", mat = "gravel", area = 14 * 1.0 / (34 * 34), chunk = 18, far = 60,
    scale = { 0.5, 1.1 },
    lod = { "models/flora/rock_pebbles_l0.gltf", "models/flora/rock_pebbles_l1.gltf" },
    yield = 1,
    -- Everywhere, thinning a little on the flats — loose surface material is
    -- the reason the ground stops reading as a bare shell.
    density = function(x, y, z)
      return 0.55 + 0.45 * math.abs(math.fbm(x * 3.0, y * 3.0, z * 3.0, 3))
    end,
  },
  {
    id = "stone", mat = "silica", host = true, area = 14 * 0.55 / (34 * 34), chunk = 22, far = 95,
    scale = { 0.8, 1.6 },
    lod = { "models/flora/rock_stone_l0.gltf", "models/flora/rock_stone_l1.gltf" },
    yield = 2,
    -- Broken ground: patchy at a coarser scale than the gravel.
    density = function(x, y, z)
      return math.saturate(math.fbm(x * 1.7 + 11.0, y * 1.7, z * 1.7, 3) * 1.6)
    end,
  },
  {
    id = "boulder", mat = "basalt", host = true, area = 14 * 0.22 / (34 * 34), chunk = 32, far = 170,
    scale = { 1.1, 2.4 },
    lod = { "models/flora/rock_boulder_l0.gltf", "models/flora/rock_boulder_l1.gltf" },
    yield = 3,
    -- Boulder fields, with real gaps between them.
    density = function(x, y, z)
      local n = math.fbm(x * 1.1 - 31.0, y * 1.1, z * 1.1, 2)
      return math.saturate((n - 0.15) * 2.2)
    end,
  },
  {
    id = "crystal", mat = "crystal", area = 14 * 0.05 / (34 * 34), chunk = 40, far = 170,
    scale = { 0.7, 1.4 },
    lod = { "models/flora/rock_crystal_l0.gltf", "models/flora/rock_crystal_l1.gltf" },
    yield = 2,
    -- The good stuff, and genuinely a PLACE: a handful of outcrops per world.
    density = function(x, y, z)
      local n = math.fbm(x * 2.3 + 77.0, y * 2.3, z * 2.3, 2)
      return math.saturate((n - 0.52) * 6.0)
    end,
  },
}
KIND_LIST = KINDS

-- ── colour ──────────────────────────────────────────────────────────────────
-- The rock meshes (tools/gen_flora.py: faceted, stratified stone with normal
-- and roughness maps) are painted in a neutral ramp; each kind's source is
-- tinted to the world's own geology — the strata colour its world record
-- publishes (`bio.palette.rock`), the ground colour on an older record. Gravel
-- leans to the low ground, boulders to the high, so the three never read as
-- one flat colour; crystals take a hue of their own per world and a faint
-- glow through their emissive map. The engine's per-prop roll shades each
-- rock ±15 % on top.
local ROCK_NEUTRAL = 0.42
local CRYSTAL_HUES = {
  { 0.35, 0.85, 0.75 }, { 0.62, 0.45, 0.95 }, { 0.95, 0.70, 0.35 }, { 0.95, 0.50, 0.70 }, { 0.65, 0.85, 1.00 },
}
local function rgb3(c) return type(c) == "table" and { c[1] or c.r, c[2] or c.g, c[3] or c.b } or nil end
local function mix3(a, b, t)
  if not b then return a end
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end
function lookOf(k, w)
  local pal = type(w.bio) == "table" and type(w.bio.palette) == "table" and w.bio.palette or {}
  local rock = rgb3(pal.rock) or rgb3(w.ground) or { 0.5, 0.45, 0.4 }
  -- keep it rock-coloured: no darker than dark basalt, no brighter than chalk
  local l = (rock[1] + rock[2] + rock[3]) / 3
  if l < 0.18 then rock = mix3(rock, { 0.25, 0.24, 0.23 }, 0.5) end
  local c
  if k.id == "gravel" then c = mix3(rock, rgb3(pal.low) or rgb3(w.ground), 0.45)
  elseif k.id == "boulder" then c = mix3(rock, rgb3(pal.high), 0.3)
  elseif k.id == "crystal" then
    local r = rng(((w.seed or 1) % 1000003) + 313)
    c = CRYSTAL_HUES[r:int(1, #CRYSTAL_HUES)]
    return { tint = { c[1] / 0.55, c[2] / 0.55, c[3] / 0.55 }, emissive = c, emissiveStrength = 0.25 }
  else c = rock end
  return { tint = { c[1] / ROCK_NEUTRAL, c[2] / ROCK_NEUTRAL, c[3] / ROCK_NEUTRAL } }
end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

-- Cinematic mode (planet_camera, F4 / F5): the interface is hidden, and the
-- markers this script paints straight onto the screen go with it.
function cinematicUp()
  local pc = ref("planet_camera")
  return pc ~= nil and pc.cinematic == true
end

local patches = {}  -- key → patch
local srcs = {}     -- scatter id → { patch = key, kind = k, fill = 0..1 }
local breaks = {}   -- "patch|kind" → { {id, t}, ... }, oldest first
local convert = {}  -- "patch|kind" → old hole positions to turn into ids
-- Ground edits waiting to re-drop the rocks on them (see "the ground moved"),
-- and the old sources of re-dropped rocks, still drawn until t.
local gw_regions, gw_queue, gw_queued = {}, {}, {}
local retiring = {}  -- { id, pk, t }
local swept = false
local cur_body = nil
local next_t = 0
local frame_checked = false

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
-- scatter.near as parallel arrays { ids, x, y, z, distance, scale, param, yaw,
-- settled, count } (engine 0.117.1-dev.1379, card 0596: no table and two vec3s
-- a hit). An older engine or a test stub answers rows: turned into the same
-- arrays (plus `up`). flora_field near_flat, the same.
local NEAR_FLAT = { flat = true }
local function near_flat(id, q, r)
  local res = scatter.near(id, q, r, NEAR_FLAT)
  if res and res.ids then return res end
  local F = { ids = {}, x = {}, y = {}, z = {}, distance = {}, scale = {}, param = {}, yaw = {}, settled = {}, up = {} }
  local n = 0
  for _, h in ipairs(res or {}) do
    n = n + 1
    F.ids[n], F.x[n], F.y[n], F.z[n] = h.id, h.pos.x, h.pos.y, h.pos.z
    F.distance[n], F.scale[n], F.param[n], F.yaw[n] = h.distance, h.scale, h.param, h.yaw
    F.settled[n], F.up[n] = h.settled, h.up
  end
  F.count = n
  return F
end
local outcrops_drop  -- (ore veins, below)
local vein_saved, outcrop_n, crystal_hue = {}, 0, nil
local oreslot_cache = {}

-- ── patch geometry (mirrors flora_field; see its notes) ─────────────────────
local AX = { { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 } }
local function comp(v, i) return v[i] end

local function project(rx, ry, rz, R)
  local v = { rx, ry, rz }
  local face, best = 1, math.abs(rx)
  if math.abs(ry) > best then face, best = 2, math.abs(ry) end
  if math.abs(rz) > best then face, best = 3, math.abs(rz) end
  local a = AX[face]
  local sgn = comp(v, a[1]) >= 0 and 1 or -1
  local t = R / math.max(1e-6, math.abs(comp(v, a[1])))
  return face, sgn, comp(v, a[2]) * t, comp(v, a[3]) * t
end

local function unproject(face, sgn, u, v, R)
  local a = AX[face]
  local q = { 0, 0, 0 }
  q[a[1]] = sgn * R
  q[a[2]] = u
  q[a[3]] = v
  local l = len(q[1], q[2], q[3])
  return q[1] / l, q[2] / l, q[3] / l
end

-- Up = radial, X along the face's u axis, Z = X × Y; as R = Ry·Rx·Rz angles.
local function patch_frame(face, ux, uy, uz)
  local a = AX[face][2]
  local tx, ty, tz = (a == 1) and 1 or 0, (a == 2) and 1 or 0, (a == 3) and 1 or 0
  local d = tx * ux + ty * uy + tz * uz
  tx, ty, tz = tx - ux * d, ty - uy * d, tz - uz * d
  local tl = len(tx, ty, tz)
  local ex = { tx / tl, ty / tl, tz / tl }
  local ey = { ux, uy, uz }
  local ez = { ex[2] * ey[3] - ex[3] * ey[2], ex[3] * ey[1] - ex[1] * ey[3], ex[1] * ey[2] - ex[2] * ey[1] }
  local pitch = math.asin(math.max(-1, math.min(1, -ez[2])))
  local roll = math.atan2(ex[2], ey[2])
  local yaw = math.atan2(ez[1], ez[3])
  return yaw, pitch, roll, ex, ey, ez
end

local function pkey(face, sgn, i, j)
  return string.format("%d%s%d,%d", face, sgn > 0 and "p" or "n", i, j)
end

local function hash(...)
  local s = 2166136261
  for _, v in ipairs({ ... }) do
    s = (s * 16777619 + math.floor(v) % 2147483647) % 4294967296
  end
  return s % 2147483647 + 1
end

-- Where the engine put a rock: dropped from its rolled place (on the patch's
-- plane) along the patch's -Y, sphere-traced with the cheap signed distance.
local function ground_along(body, px, py, pz, dx, dy, dz)
  local t = 0
  for _ = 1, 8 do
    local q = terrain.query(body.x + px + dx * t, body.y + py + dy * t, body.z + pz + dz * t)
    if not q then break end
    t = t + q
    if math.abs(q) < 0.02 then break end
  end
  return px + dx * t, py + dy * t, pz + dz * t
end

local function patch_dist(p, rx, ry, rz)
  local dx, dy, dz = rx - p.cx, ry - p.cy, rz - p.cz
  local lx = dx * p.ex[1] + dy * p.ex[2] + dz * p.ex[3]
  local lz = dx * p.ez[1] + dy * p.ez[2] + dz * p.ez[3]
  local ox = math.max(0, math.abs(lx) - p.half)
  local oz = math.max(0, math.abs(lz) - p.half)
  return math.sqrt(ox * ox + oz * oz)
end

-- ── sources ─────────────────────────────────────────────────────────────────

-- Save keys: "rocks2.<body>.<patch>.<kind>" holds the source's removed ids;
-- "rocks.<…>" is the old hole format (x, z pairs in the patch plane).
local function save_key(pk, kid)
  return string.format("rocks2.%s.%s.%s", cur_body or "?", pk, kid)
end
local function old_key(pk, kid)
  return string.format("rocks.%s.%s.%s", cur_body or "?", pk, kid)
end

-- Save values are capped near a kilobyte.
local MAX_BREAKS = 40

local function drop_source(id)
  local s = srcs[id]
  if not s then return end
  scatter.destroy(id)
  local p = patches[s.patch]
  if p and p.srcs[s.kind.id] == id then p.srcs[s.kind.id] = nil end
  srcs[id] = nil
end

-- Destroy retired sources whose hold is over (or a patch's, or all).
local function sweep_retiring(pk, all)
  local keep = {}
  for _, r in ipairs(retiring) do
    if all or r.pk == pk or time >= r.t then scatter.destroy(r.id) else keep[#keep + 1] = r end
  end
  retiring = keep
end

local function drop_patch(key)
  local p = patches[key]
  if not p then return end
  sweep_retiring(key)
  for _, id in pairs(p.srcs) do if id then drop_source(id) end end
  if outcrops_drop then outcrops_drop(p) end
  if p.node and p.node.valid then p.node:destroy() end
  patches[key] = nil
end

local function tear_down()
  for key in pairs(patches) do drop_patch(key) end
  for id in pairs(srcs) do drop_source(id) end
  sweep_retiring(nil, true)
  patches, srcs, breaks, convert = {}, {}, {}, {}
  vein_saved, outcrop_n, crystal_hue = {}, 0, nil
  oreslot_cache = {}
  gw_regions, gw_queue, gw_queued = {}, {}, {}
  sources, patchCount, count, cur_body, bodyName = 0, 0, 0, nil, nil
end

function clearAll() tear_down() end

local function breaks_of(pk, kid)
  local hk = pk .. "|" .. kid
  local list = breaks[hk]
  if list then return list end
  list = {}
  local saved = save.get(save_key(pk, kid))
  if type(saved) == "table" then
    for i = 1, #saved do
      local id = tonumber(saved[i])
      if id then list[#list + 1] = { id = id, t = time } end
    end
  end
  breaks[hk] = list
  local old = save.get(old_key(pk, kid))
  if type(old) == "table" and #old >= 2 then
    convert[hk] = { pk = pk, kid = kid, xz = old }
  elseif old ~= nil then
    save.set(old_key(pk, kid), nil)
  end
  return list
end

local function save_breaks(pk, kid)
  local list = breaks[pk .. "|" .. kid] or {}
  local p = patches[pk]
  local id = p and p.srcs[kid]
  local ids = (id and scatter.removed) and scatter.removed(id) or nil
  if not ids or #ids ~= #list then
    ids = {}
    for _, c in ipairs(list) do ids[#ids + 1] = c.id end
  end
  save.set(save_key(pk, kid), #ids > 0 and ids or nil)
end

-- The kind's placement rule across a patch, as a rows² grid (once per patch
-- and kind). Outside the patch's own cube cell the neighbour lays it.
-- The base's paving, pad and building lots grow nothing (base_facilities'
-- `keepClear` / `footprint`, the base agent's siting contract): true to keep
-- this body-relative ground point clear.
local function kept_clear(x, y, z)
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if type(fp) ~= "table" or fp.body ~= cur_body or type(fp.x) ~= "number" then return false end
  if len(x - fp.x, y - fp.y, z - fp.z) > (fp.radius or 200) + 4 then return false end
  if bf.keepClear then
    local ok, v = pcall(bf.keepClear, cur_body, x, y, z)
    if ok then return v == true end
  end
  return true
end

local function base_grid(p, k, R)
  p.base = p.base or {}
  if p.base[k.id] then return p.base[k.id] end
  local rows, half = p.rows, p.half
  local data = {}
  for r = 0, rows - 1 do
    for c = 0, rows - 1 do
      local x = (c / (rows - 1) - 0.5) * 2 * half
      local z = (r / (rows - 1) - 0.5) * 2 * half
      local px = p.cx + p.ex[1] * x + p.ez[1] * z
      local py = p.cy + p.ex[2] * x + p.ez[2] * z
      local pz = p.cz + p.ex[3] * x + p.ez[3] * z
      local f2, g2, u2, v2 = project(px, py, pz, R)
      local d = 0
      if f2 == p.face and g2 == p.sgn and math.floor(u2 / p.P) == p.i and math.floor(v2 / p.P) == p.j then
        local l = len(px, py, pz)
        d = math.max(0, math.min(1, k.density(px / l, py / l, pz / l)))
        if d > 0 and kept_clear(px / l * R, py / l * R, pz / l * R) then d = 0 end
      end
      data[r * rows + c + 1] = d
    end
  end
  p.base[k.id] = data
  return data
end

local function make_source(p, k, w, R)
  local rows = p.rows
  local data = base_grid(p, k, R)
  local sum = 0
  for i = 1, rows * rows do sum = sum + data[i] end
  if sum <= 0.01 then return false end
  local list = breaks_of(p.key, k.id)
  local look = lookOf(k, w)
  local far = k.far * params.reach
  local per = math.max(1, math.floor(k.area * k.chunk * k.chunk * params.density + 0.5))
  -- The bands cross-dissolve, and the last dissolves into nothing (an empty
  -- band just past the reach, flora_gen.emptyAsset): a rock never snaps in or
  -- out at the edge of its reach.
  local lod = { { asset = k.lod[1], distance = far * 0.35 }, { asset = k.lod[2], distance = far } }
  local fade = params.fade
  local fg = ref("flora_gen")
  local empty = params.fade_out > 0 and fg and fg.emptyAsset and fg.emptyAsset() or nil
  if empty then
    lod[#lod + 1] = { asset = empty, distance = far + 0.5 }
  end
  local ok, id = pcall(scatter.create, {
    seed = hash(w.seed or 1, p.face, p.sgn + 2, p.i + 50000, p.j + 50000, #k.id * 131 + k.chunk),
    center = vec3(0, 0, 0), halfX = p.half, halfZ = p.half,
    perChunk = per, chunk = k.chunk, align = "surface",
    scaleMin = k.scale[1], scaleMax = k.scale[2], fade = fade,
    lod = lod,
    density = data, densityRows = rows, parent = p.name,
    tint = look.tint, emissive = look.emissive, emissiveStrength = look.emissiveStrength,
  })
  if not ok then
    print("mineral field: scatter.create refused: " .. tostring(id))
    return false
  end
  -- What was broken here stays broken: the same id is the same rock in every
  -- declaration of this source.
  for _, c in ipairs(list) do scatter.remove(id, c.id) end
  srcs[id] = { patch = p.key, kind = k, fill = sum / (rows * rows), made = time }
  -- Rocks off the base's paving and lots, thinning at the edge (flora_field
  -- baseKeep: the same clearing the plants keep).
  local ff = ref("flora_field")
  local body = cur_body and space.body(cur_body)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if ff and ff.baseKeep and body and scatter.near and save.get("base.body") == cur_body and type(bx) == "number"
     and len(p.cx - bx, p.cy - by, p.cz - bz) < p.half * 1.5 + 260 then
    local F = near_flat(id, vec3(body.x + bx, body.y + by, body.z + bz), 230)
    local ids, X, Y, Z = F.ids, F.x, F.y, F.z
    for k = 1, F.count do
      local iid = ids[k]
      local keep = ff.baseKeep(X[k] - body.x, Y[k] - body.y, Z[k] - body.z, 0.6)
      if keep < 1 and (((iid % 2147483647) * 48271 + 7) % 2147483647) / 2147483647 >= keep then
        scatter.remove(id, iid)
      end
    end
  end
  return id
end

-- ── ore pockets ─────────────────────────────────────────────────────────────
--
-- A handful of pockets per world, 7–14 m down in solid rock, each a few units
-- of Star Geode. Where they are is climate.rareScan's answer, kept in the save
-- (`rare.<body>`.ores, body-relative centres); what has been taken out of each
-- is `rare.ore.<body>`. Nothing marks them on the surface: you find one by
-- digging, and the suit's resonance sensor (a ring on the ground above, while
-- the Terrain Laser is out) says when you are standing over one.
--
-- The laser asks `nearest` at its cut point before it asks the rock what it
-- is (tool_belt pop_unit), so a cut point inside a pocket answers here — and
-- `breakAt` pays it out a unit at a time. No change to the tool.

local POCKET_MAT = "geode"

local function pocket_list(bname)
  local d = bname and save.get("rare." .. bname)
  if type(d) ~= "table" or type(d.ores) ~= "table" then return nil end
  return d.ores
end

local function pocket_taken(bname)
  return save.get("rare.ore." .. bname) or {}
end

-- The world's pockets: { i, x, y, z (body-relative), r, depth, left }.
function pockets(bname)
  local out = {}
  local list = pocket_list(bname)
  if not list then return out end
  local taken = pocket_taken(bname)
  for i, o in ipairs(list) do
    out[#out + 1] = { i = i, x = o.x, y = o.y, z = o.z, r = o.r or 2.5, depth = o.d or 0,
                      left = math.max(0, params.pocket_units - (taken[i] or taken[tostring(i)] or 0)) }
  end
  return out
end

local function pocket_at(x, y, z, slack)
  local bname = space.dominant(x, y, z)
  local body = bname and space.body(bname)
  local list = body and pocket_list(bname)
  if not list then return nil end
  local taken = pocket_taken(bname)
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for i, o in ipairs(list) do
    local d = len(rx - o.x, ry - o.y, rz - o.z)
    if d <= (o.r or 2.5) + (slack or 0.6) and (taken[i] or 0) < params.pocket_units then
      return { pocket = i, body = bname, kind = { id = "pocket", mat = POCKET_MAT, yield = 1 },
               pos = vec3(body.x + o.x, body.y + o.y, body.z + o.z), distance = d }
    end
  end
  return nil
end

-- Published for the HUD: the last pocket unit taken ({ body, i, left, at }).
lastPocket = nil

local function pocket_break(hit, cid)
  local inv, rs = ref("inventory"), ref("research")
  if rs and rs.registerMaterials then rs.registerMaterials() end
  if not inv then return nil, 0 end
  local took = inv.add(cid or "astro", POCKET_MAT, 1)
  if took <= 0 then return POCKET_MAT, 0 end
  local taken = pocket_taken(hit.body)
  taken[hit.pocket] = (taken[hit.pocket] or 0) + took
  save.set("rare.ore." .. hit.body, taken)
  local left = math.max(0, params.pocket_units - taken[hit.pocket])
  lastPocket = { body = hit.body, i = hit.pocket, left = left, at = time }
  if taken[hit.pocket] == took then
    log(string.format("RARE FIND: an ore pocket on %s (pocket %d)", hit.body, hit.pocket))
  end
  return POCKET_MAT, took
end

-- ── the tool-facing API ─────────────────────────────────────────────────────

-- The rock nearest a point, within `radius` — or nil. Scattered props have no
-- colliders, so this proximity query IS the aim test: the laser drives a cut
-- point along its beam and asks here. Measured to where the rock actually
-- lies on the ground (the engine's settle, reproduced), not to where it was
-- rolled on the patch plane above it.
-- `kinds` (optional) is a set of kind ids to consider — the gravity gun asks
-- for { stone, boulder, crystal }: the rocks big enough to be a body, never
-- gravel, and never an ore pocket.
function nearest(x, y, z, radius, kinds)
  radius = radius or params.grab
  -- Inside an ore pocket the pocket is what the beam is cutting.
  if not kinds then
    local pk = pocket_at(x, y, z)
    if pk then return pk end
  end
  local body = cur_body and space.body(cur_body)
  if not body then return nil end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  local best = nil
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and (not kinds or kinds[s.kind.id]) and patch_dist(p, rx, ry, rz) <= radius + 3 then
      local dx, dy, dz = rx - p.cx, ry - p.cy, rz - p.cz
      local lx = dx * p.ex[1] + dy * p.ex[2] + dz * p.ex[3]
      local lz = dx * p.ez[1] + dy * p.ez[2] + dz * p.ez[3]
      local qx = body.x + p.cx + p.ex[1] * lx + p.ez[1] * lz
      local qy = body.y + p.cy + p.ex[2] * lx + p.ez[2] * lz
      local qz = body.z + p.cz + p.ex[3] * lx + p.ez[3] * lz
      local F = near_flat(id, vec3(qx, qy, qz), radius + 1.0)
      for n = 1, math.min(F.count, 8) do
        local h = { id = F.ids[n], scale = F.scale[n] }
        local hx, hy, hz = F.x[n] - body.x, F.y[n] - body.y, F.z[n] - body.z
        local gx, gy, gz = ground_along(body, hx, hy, hz, -p.ey[1], -p.ey[2], -p.ey[3])
        local d = len(gx - rx, gy - ry, gz - rz)
        if d <= radius and (not best or d < best.distance) then
          local hdx, hdy, hdz = hx - p.cx, hy - p.cy, hz - p.cz
          best = { source = id, kind = s.kind, id = h.id, patch = s.patch,
                   lx = hdx * p.ex[1] + hdy * p.ex[2] + hdz * p.ex[3],
                   lz = hdx * p.ez[1] + hdy * p.ez[2] + hdz * p.ez[3],
                   pos = vec3(body.x + gx, body.y + gy, body.z + gz),
                   distance = d, scale = h.scale }
        end
      end
    end
  end
  return best
end

-- The rocks big enough to bump into within `radius` of a WORLD point, for
-- flora_field's collider pool: { { x, y, z (world, where it settled), r
-- (collider sphere radius), key }, ... }. Gravel is stepped over; only
-- settled props are listed (one not near a camera yet has no place).
local BUMP_R = { stone = 0.5, boulder = 0.88, crystal = 0.72 }
function rocksNear(x, y, z, radius)
  local out = {}
  local body = cur_body and space.body(cur_body)
  if not (body and scatter and scatter.near) then return out end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for id, s in pairs(srcs) do
    local k = s.kind
    local br = k and BUMP_R[k.id]
    local p = patches[s.patch]
    if br and p and patch_dist(p, rx, ry, rz) <= radius + 3 then
      local F = near_flat(id, vec3(x, y, z), radius)
      for k = 1, F.count do
        local hid, hsc = F.ids[k], F.scale[k]
        local r = br * (hsc or 1)
        if F.settled[k] ~= false and r >= 0.3 then
          out[#out + 1] = { x = F.x[k], y = F.y[k], z = F.z[k], r = r, d = F.distance[k],
                            key = "r" .. id .. ":" .. tostring(hid), src = id, inst = hid, scale = hsc }
        end
      end
    end
  end
  return out
end

-- WHAT A ROCK IS MADE OF. A stone or a boulder is a piece of the bedrock it
-- lies on (the palette slot a few metres under it, the first that is rock
-- rather than soil); gravel is gravel and a crystal outcrop crystal. Read at
-- the rock's own place, once, when it is broken or plucked.
local SOFT = { soil = true, sand = true, clay = true, ash = true, gravel = true, regolith = true }
function rockMat(hit)
  local k = hit and hit.kind
  if not k then return "regolith" end
  if not k.host then return k.mat end
  local mats = ref("materials")
  local p = hit.pos
  if not (mats and mats.ofSlot and p and terrain.slotAt) then return k.mat end
  local name = space.dominant(p.x, p.y, p.z)
  local b = name and space.body(name)
  if not b then return k.mat end
  local dx, dy, dz = p.x - b.x, p.y - b.y, p.z - b.z
  local l = len(dx, dy, dz)
  if l < 1 then return k.mat end
  dx, dy, dz = dx / l, dy / l, dz / l
  local first
  for _, d in ipairs({ 2.5, 5.0, 8.0 }) do
    local sl = terrain.slotAt(p.x - dx * d, p.y - dy * d, p.z - dz * d)
    if sl then
      local m = mats.ofSlot(sl)
      first = first or m
      if not SOFT[m] and mats.isOre and not mats.isOre(m) then return m end
    end
  end
  return (first and not SOFT[first] and first) or k.mat
end

-- Break it: the yield goes to `cid`, the rock goes (`scatter.remove` by its
-- id, saved), and the field grows back on its timer.
--
-- Returns the material id and how many units were actually taken (0 when the
-- pack is full, and the rock is left standing — a break that pays nothing must
-- not also destroy the rock).
function breakAt(hit, cid)
  if not hit then return nil, 0 end
  if hit.pocket then return pocket_break(hit, cid) end
  local inv, mats = ref("inventory"), ref("materials")
  if not (inv and mats) then return nil, 0 end
  local k = hit.kind
  local units = k.yield or 1
  local mat = rockMat(hit)
  local took = inv.add(cid or "astro", mat, units)
  if took <= 0 then return mat, 0 end
  scatter.remove(hit.source, hit.id)
  local p = patches[hit.patch]
  if p then
    local list = breaks_of(hit.patch, k.id)
    list[#list + 1] = { id = hit.id, t = time }
    while #list > MAX_BREAKS do scatter.restore(hit.source, table.remove(list, 1).id) end
    save_breaks(hit.patch, k.id)
  end
  return mat, took
end

-- The record `pluck` (or breakAt) wants for a rock `rocksNear` listed: by its
-- source and instance, so it never depends on a proximity query — asked at a
-- rock's own place, `nearest` can still answer nothing where the patch plane
-- stands far off the ground (the height band `scatter.near` reads).
function rockRecord(rk)
  local s = rk and srcs[rk.src]
  if not (s and rk.inst) then return nil end
  return { source = rk.src, kind = s.kind, id = rk.inst, patch = s.patch, scale = rk.scale,
           pos = vec3(rk.x, rk.y, rk.z), distance = 0 }
end

-- Pluck it out WHOLE: the rock goes (saved as a break, so it grows back on the
-- field's timer) and nothing is paid out here — the gravity gun has it in hand
-- as a body now (tool_belt spawns the Loose* prefab), and what it is worth
-- comes when that is stowed or dropped at the depot. Returns the kind and
-- the material it is made of (rockMat).
function pluck(hit)
  if not (hit and hit.source and hit.kind) or hit.pocket then return nil end
  local mat = rockMat(hit)
  scatter.remove(hit.source, hit.id)
  local p = patches[hit.patch]
  if p then
    local list = breaks_of(hit.patch, hit.kind.id)
    list[#list + 1] = { id = hit.id, t = time }
    while #list > MAX_BREAKS do scatter.restore(hit.source, table.remove(list, 1).id) end
    save_breaks(hit.patch, hit.kind.id)
  end
  return hit.kind, mat
end

-- ── ore veins ───────────────────────────────────────────────────────────────
--
-- ORE IS A PLACE. A few veins per patch: a seam of the ore's own texture
-- (materials.VEIN_SLOTS: hematite for iron, the orange veinstone for copper,
-- sulfur, the glowing crystal and magma slots) painted into the ground along a
-- wandering strike line 3–15 m long, a lens reaching about two and a half of
-- its widths down, with outcrops of the ore standing out of it (iron as dark
-- metallic knobs, copper as green-stained stone, sulfur yellow, crystal and
-- uranite as glowing clusters). You see one from a hundred metres, walk over,
-- and cut INTO it: what the laser removes there is ore, by the volume of ore
-- removed (terrain.yields), and the rock round it is the rock it is.
--
-- DATA, NOT NODES. Where a patch's veins lie is a pure function of the world
-- seed and the patch (rng), laid out when the patch is; the ground under them
-- is read when someone is near (terrain.raycast, the ground's own field).
-- The paint is a terrain edit, made once, when someone comes within
-- `vein_paint` (the save remembers which veins are painted, `veins1.<body>.
-- <patch>`; painting again over a dug-out vein would grow the ore back on the
-- tunnel walls). Outcrops are plain model nodes under the planet, made within
-- `vein_show` and capped (`outcrop_max`), gone with their patch; a broken one
-- stays broken (the same record). Every point is body-relative: the planet
-- moves metres a tick (docs/positions-and-frames.md).

local VEIN_V = 2
-- vein_saved: patch key → { p = { v<i> = slot painted }, t = { v<i> = outcrops taken (bits) },
--                          h = { v<i> = 1 once the stain is painted } }

-- (v2: veins mostly buried and per-world ores. A v1 save's seams stay in
-- the ground as they were painted, and still pay by their slot, oreSlots.)
local function vein_key(pk) return string.format("veins%d.%s.%s", VEIN_V, cur_body or "?", pk) end
local function vein_rec(pk)
  local r = vein_saved[pk]
  if r then return r end
  r = save.get(vein_key(pk))
  if type(r) ~= "table" then r = {} end
  if type(r.p) ~= "table" then r.p = {} end
  if type(r.t) ~= "table" then r.t = {} end
  vein_saved[pk] = r
  return r
end
local function vein_save(pk)
  local r = vein_saved[pk]
  if r then save.set(vein_key(pk), (next(r.p) or next(r.t)) and r or nil) end
end
local function bit_on(mask, j) return math.floor((mask or 0) / 2 ^ (j - 1)) % 2 == 1 end

-- The outcrops' looks, by ore: the rock meshes (painted in a neutral ramp,
-- ROCK_NEUTRAL) tinted to the mineral, with its sheen or glow.
local OUT_LOOK = {
  iron     = { model = "models/flora/rock_boulder_l0.gltf", c = { 0.42, 0.13, 0.08 }, s = { 0.45, 0.85 }, sink = 0.3 },
  copper   = { model = "models/flora/rock_stone_l0.gltf", c = { 0.12, 0.50, 0.38 }, s = { 0.55, 1.0 }, sink = 0.3 },
  sulfur   = { model = "models/flora/rock_stone_l0.gltf", c = { 0.95, 0.80, 0.12 }, s = { 0.5, 0.95 }, sink = 0.3 },
  obsidian = { model = "models/flora/rock_stone_l0.gltf", c = { 0.07, 0.06, 0.08 }, rough = 0.15, s = { 0.35, 0.7 }, sink = 0.3 },
  crystal  = { model = "models/flora/rock_crystal_l0.gltf", c = nil, glow = 0.55, s = { 0.4, 0.85 }, sink = 0.2, cluster = true },
  uranium  = { model = "models/flora/rock_crystal_l0.gltf", c = { 0.22, 0.27, 0.12 }, e = { 0.45, 0.85, 0.2 }, glow = 0.35, s = { 0.3, 0.6 }, sink = 0.25, cluster = true },
}

-- An ore's look: materials.ORE[ore].look first (every ore, home and
-- off-world, keeps its look with its registry entry), these tables after.
local function look_of(ore)
  local m = ref("materials")
  return m and m.oreLook and m.oreLook(ore) or nil
end
local function out_look(ore)
  local l = look_of(ore)
  return (l and l.out) or OUT_LOOK[ore] or OUT_LOOK.copper
end

-- The world's veins in a patch: { i, key, ore, pts (unit-sphere points with a
-- width w and a depth dk under the ground), depth, buried, seed } — laid out
-- once per patch, a pure function of the seed. Most are buried (depth > 0):
-- they run through the rock, dipping along their strike, and are found by
-- digging or caving. `vein_surface` of them crop out, and only ores that do
-- (materials.ORE surface) — the common ones. Rarer ores lie deeper
-- (materials.pickVeinOre). Which ores at all is the world's own makeup
-- (materials.bodyOres).
local function veins_of(p, w, R)
  if p.veins then return p.veins end
  local out = {}
  p.veins = out
  local mats = ref("materials")
  if not (mats and mats.bodyOres and mats.pickVeinOre) or params.vein_rate <= 0 then return out end
  local ores, total = mats.bodyOres(cur_body, w.kind or "barren")
  if not total or total <= 0 then return out end
  local r = rng(hash(w.seed or 1, p.face, p.sgn + 2, p.i + 70000, p.j + 70000, 9173 + VEIN_V))
  local n = math.floor(params.vein_rate * (0.35 + 1.3 * r:next()) + 0.5)
  for vi = 1, n do
    local x = (r:next() * 2 - 1) * p.half * 0.85
    local z = (r:next() * 2 - 1) * p.half * 0.85
    -- surfaced or buried, then the ore that fits that depth
    local depth = 0
    if r:next() >= params.vein_surface then depth = 4 + 42 * r:next() ^ 1.4 end
    local ore = mats.pickVeinOre(ores, depth, r:next())
    if not ore and depth <= 0 then
      depth = 4 + 20 * r:next()
      ore = mats.pickVeinOre(ores, depth, r:next())
    end
    ore = ore or "iron"
    local gem = out_look(ore).cluster
    local buried = depth > 0
    local L = buried and r:range(10.0, 26.0) or (gem and r:range(3.0, 5.5) or r:range(6.0, 15.0))
    -- (wide enough to read on ground meshed at 1.5–2.4 m voxels: a seam
    -- narrower than a voxel or two never shows on the surface)
    local wd = buried and r:range(1.8, 3.0) or (gem and r:range(1.6, 2.1) or r:range(1.6, 2.6))
    -- a buried vein dips along its strike (so one end may lie much nearer the
    -- surface than the other), never closer than 3 m under the ground
    local dip = buried and r:range(-0.5, 0.5) or 0
    local ang = r:next() * math.pi * 2
    local ca, sa = math.cos(ang), math.sin(ang)
    local K = math.max(3, math.ceil(L / 1.1) + 1)
    local pts = {}
    for k = 0, K - 1 do
      local t = (k / (K - 1) - 0.5) * L
      -- a seam wanders a little off its strike, and pinches and swells
      local sway = math.sin(t * 0.45 + vi * 1.7) * 0.35 * wd
      local lx, lz = x + ca * t - sa * sway, z + sa * t + ca * sway
      local px = p.cx + p.ex[1] * lx + p.ez[1] * lz
      local py = p.cy + p.ex[2] * lx + p.ez[2] * lz
      local pz = p.cz + p.ex[3] * lx + p.ez[3] * lz
      local l = len(px, py, pz)
      local taper = 1 - 0.45 * math.abs(k / (K - 1) - 0.5) * 2
      local dk = buried and math.max(3.0, depth + dip * t) or 0
      pts[#pts + 1] = { px / l, py / l, pz / l, w = wd * taper * (0.8 + 0.4 * r:next()), lx = lx, lz = lz, dk = dk }
    end
    local c = pts[math.ceil(K / 2)]
    local f2, g2, u2, v2 = project(c[1] * R, c[2] * R, c[3] * R, R)
    local seed = r:int(1, 999983)
    if f2 == p.face and g2 == p.sgn and math.floor(u2 / p.P) == p.i and math.floor(v2 / p.P) == p.j
       and not kept_clear(c[1] * R, c[2] * R, c[3] * R) then
      out[#out + 1] = { i = vi, key = "v" .. vi, ore = ore, pts = pts, len = L, width = wd, seed = seed, lx = x, lz = z,
                        depth = depth, buried = buried }
    end
  end
  return out
end

-- The ground under a vein's points (body-relative), read from the ground's
-- own field; nil until all of it is made exactly.
local function vein_ground(v, body, R)
  if v.g then return v.g end
  if not terrain.raycast then return nil end
  local g = {}
  local top = R + 240
  for k, q in ipairs(v.pts) do
    local h = terrain.raycast(vec3(body.x + q[1] * top, body.y + q[2] * top, body.z + q[3] * top),
      vec3(-q[1], -q[2], -q[3]), 480)
    if not (h and h.pos) or h.exact == false then return nil end
    g[k] = { h.pos.x - body.x, h.pos.y - body.y, h.pos.z - body.z, w = q.w, ux = q[1], uy = q[2], uz = q[3] }
  end
  v.g = g
  -- the vein's own line: the ground's for a seam that crops out, `dk` under
  -- it for a buried one
  if v.buried then
    local b = {}
    for k, q in ipairs(g) do
      local d = v.pts[k].dk or 0
      b[k] = { q[1] - q.ux * d, q[2] - q.uy * d, q[3] - q.uz * d, w = q.w, ux = q.ux, uy = q.uy, uz = q.uz, dk = d }
    end
    v.b = b
  else
    v.b = g
  end
  return g
end

-- WHICH SLOTS ARE ORE ON THIS WORLD: `veinslots.<body>` = { ["27"] = "iron" },
-- written when a vein is first painted in a slot. A slot is only ever taken
-- for veins if the world's own ground (its surface paints and the layers
-- under them, bio.mats; and the slots found under the seam itself) never uses
-- it — so on this world every voxel of that slot IS a seam, and the cut reads
-- it as ore by the slot alone (no geometry: a bore deep through a lens, or a
-- wall cut from the side, pays exactly what was painted).
function oreSlots(bname)
  bname = bname or cur_body
  if not bname then return {} end
  local c = oreslot_cache[bname]
  if c then return c end
  c = save.get("veinslots." .. bname)
  if type(c) ~= "table" then c = {} end
  oreslot_cache[bname] = c
  return c
end
local function world_reserved(w)
  local r = {}
  local m = type(w) == "table" and type(w.bio) == "table" and w.bio.mats
  if type(m) == "table" then for _, sl in pairs(m) do if type(sl) == "number" then r[sl] = true end end end
  return r
end

-- The colour a seam is painted in (the texture is tinted by it, ×1.6 in the
-- shader: 0.62 is the texture as authored): iron's rusty hematite black,
-- copper's verdigris, sulfur's yellow, uranite's sickly green over the magma
-- glow. Dark and saturated enough to read against the ground round it at
-- eye level (the 0.26 grey it had drew paler than most ground).
SEAM_COLOUR = {
  iron = { 0.30, 0.15, 0.11 }, copper = { 0.24, 0.56, 0.44 }, sulfur = { 0.86, 0.76, 0.26 },
  obsidian = { 0.16, 0.15, 0.18 }, uranium = { 0.50, 0.66, 0.26 },
}
-- The stain a seam bleeds into the ground round it (a colour paint only, over
-- the ground's own tint, so the host rock keeps its texture; the brush's own
-- soft rim feathers it out): the rust of an iron gossan, copper's green wash,
-- sulfur's pale yellow bloom. It runs on past both ends of the seam along its
-- strike, fainter. What reads first from twenty metres is a discoloured streak
-- wider and longer than the seam, the seam a dark core inside it.
STAIN_COLOUR = {
  iron = { 0.66, 0.32, 0.16 }, copper = { 0.34, 0.60, 0.48 }, sulfur = { 0.84, 0.76, 0.36 },
  obsidian = { 0.30, 0.28, 0.30 }, uranium = { 0.62, 0.70, 0.34 },
}
local w_seed = nil

local function crystal_tone()
  local r = rng(((w_seed or 1) % 1000003) + 313)
  local h = CRYSTAL_HUES[r:int(1, #CRYSTAL_HUES)]
  return h
end

-- The radius a seam's core is painted at a point: never under 1.7 m, because
-- the ground meshes at 1.5–2.4 m voxels and a narrower paint shows as a dot or
-- not at all (veinAt reads the same width).
local function seam_r(q) return math.max(1.7, q.w * 1.1) end

-- KEPT OFF THE BASE. A seam point, its stain and its outcrops never land on
-- the base's paving, pad or lots (base_facilities `keepClear`, the same test
-- the rocks and the float use). A ball is dropped when its centre or any of
-- eight points round it, at the radius it shows over, is kept clear: the
-- slot paint is hard-edged (its whole radius), a colour paint shows over
-- about 0.4 of its radius (0.7 tested, for margin).
local COLOUR_SHOWS = 0.7
local function ball_clear(x, y, z, ux, uy, uz, r, clear)
  if clear(x, y, z) then return false end
  local ax, ay, az = 1, 0, 0
  if math.abs(ux) > 0.9 then ax, ay = 0, 1 end
  local ad = ax * ux + ay * uy + az * uz
  local tx, ty, tz = ax - ux * ad, ay - uy * ad, az - uz * ad
  local tl = len(tx, ty, tz)
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local bx, by, bz = uy * tz - uz * ty, uz * tx - ux * tz, ux * ty - uy * tx
  for k = 0, 7 do
    local a = k * math.pi / 4
    local c, sn = math.cos(a) * r, math.sin(a) * r
    if clear(x + tx * c + bx * sn, y + ty * c + by * sn, z + tz * c + bz * sn) then return false end
  end
  return true
end

-- THE BRUSHES (engine 0.117.1-dev.1402, terrain.paint's brush table). The
-- stain is the soft one: full over its inner quarter, then a square fall to
-- the rim (a long faint tail), on balls 1.3 times as wide, so over the
-- 1.5–2.4 m voxels it shades off through several of them into the ground
-- instead of stopping in a stepped ring at the old smoothstep's edge. Soft
-- with no full core at the old size read as a faint smear a third as wide;
-- linear at 1.3x kept a hard-looking rim (tools/perf mineprobe vseam). The
-- core keeps the engine's default (a third of its radius full, smoothstep
-- out): it is the ore itself and should read as a band.
STAIN_BRUSH = { hardness = 0.25, falloff = "soft" }
STAIN_REACH = 1.3
CORE_BRUSH = nil

-- THE SEAM'S PAINT, AS A PLAN: the ops that lay seam `ore` along ground points
-- `g` (body-relative, with up ux/uy/uz and width w), in order, each one
-- { op = "tex"|"col", x, y, z (body-relative), r, slot | c = {r,g,b}, s,
-- brush } (brush: terrain.paint's, nil the engine's default).
-- `slot` nil plans the colour only (an older seam's stain). `clear(x,y,z)`
-- → true where the ground is kept clear (the base). Pure: the smoke test
-- reads it (tests/smoke_minerals.lua).
function seamPlan(ore, g, slot, clear, opts)
  clear = clear or function() return false end
  opts = opts or {}
  local out = {}
  local function add(o)
    local shows = o.op == "tex" and o.r or o.r * COLOUR_SHOWS
    if ball_clear(o.x, o.y, o.z, o.ux, o.uy, o.uz, shows, clear) then
      o.ux, o.uy, o.uz = nil, nil, nil
      out[#out + 1] = o
    end
  end
  local lk = look_of(ore) or {}
  local col = lk.seam or SEAM_COLOUR[ore] or { 0.62, 0.62, 0.62 }
  local st = lk.stain or STAIN_COLOUR[ore] or col
  if ore == "crystal" then
    local h = crystal_tone()
    col = { 0.4 + h[1] * 0.4, 0.4 + h[2] * 0.4, 0.4 + h[3] * 0.4 }
    st = { 0.5 + h[1] * 0.25, 0.5 + h[2] * 0.25, 0.5 + h[3] * 0.25 }
  end
  -- A paint of the slot alone keeps the ground's own tint colour (the slot
  -- is the voxel's alpha byte, its RGB the colour the texture is tinted by),
  -- so a hematite seam laid in red soil drew as red soil: the seam is
  -- recoloured too, the ore's own colour in the core and a stain round it.
  if slot then
    for _, q in ipairs(g) do
      local wd = q.w
      -- the seam where it crops out (centred just under the ground, so its
      -- whole width reaches the surface), and the lens under it
      -- (a buried vein's line is its middle: the core round it, the lens
      -- reaching a width under it)
      local up0, lens = opts.buried and 0 or 0.2, opts.buried and 0.9 or 1.5
      add({ op = "tex", x = q[1] - q.ux * up0, y = q[2] - q.uy * up0, z = q[3] - q.uz * up0, r = seam_r(q), slot = slot, ux = q.ux, uy = q.uy, uz = q.uz })
      local bx, by, bz = q[1] - q.ux * wd * lens, q[2] - q.uy * wd * lens, q[3] - q.uz * wd * lens
      add({ op = "tex", x = bx, y = by, z = bz, r = wd * 0.9, slot = slot, ux = q.ux, uy = q.uy, uz = q.uz })
      if lk.seam or SEAM_COLOUR[ore] then add({ op = "col", x = bx, y = by, z = bz, r = wd * 0.9, c = col, s = 1.0, brush = CORE_BRUSH, ux = q.ux, uy = q.uy, uz = q.uz }) end
    end
  end
  -- The stain first, then the core. Brushes are soft (full only inside a
  -- third of the radius, smoothstep to the rim) and colour lives per voxel
  -- (1.5–2.4 m here): measured on engine 0.117.1 (mineprobe vpdiag), a
  -- colour paint reads over about 0.4 of its radius, so the radii are far
  -- larger than the look they give.
  -- The stain trails on past each end, along the strike: three balls, fading,
  -- so it reads as a streak along the seam's line, not a round patch.
  local n = #g
  for e = 1, ((n >= 2 and opts.trail ~= false) and 2 or 0) do
    local a, b = (e == 1) and g[1] or g[n], (e == 1) and g[2] or g[n - 1]
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    local dl = math.max(0.3, len(dx, dy, dz))
    dx, dy, dz = dx / dl, dy / dl, dz / dl
    for j = 1, 3 do
      local t = 2.4 * j
      add({ op = "col", x = a[1] + dx * t, y = a[2] + dy * t, z = a[3] + dz * t, r = (5.0 - 0.5 * j) * STAIN_REACH, c = st, s = 1.0 - 0.2 * j, brush = STAIN_BRUSH, ux = a.ux, uy = a.uy, uz = a.uz })
    end
  end
  for _, q in ipairs(g) do
    add({ op = "col", x = q[1], y = q[2], z = q[3], r = (seam_r(q) + 3.5) * STAIN_REACH, c = st, s = 1.0, brush = STAIN_BRUSH, ux = q.ux, uy = q.uy, uz = q.uz })
  end
  -- the core twice over (a soft brush gives half its colour at the core's
  -- edge; two coats give three quarters)
  for _ = 1, 2 do
    for _, q in ipairs(g) do
      add({ op = "col", x = q[1] - q.ux * 0.2, y = q[2] - q.uy * 0.2, z = q[3] - q.uz * 0.2, r = seam_r(q) * 2.0, c = col, s = 1.0, brush = CORE_BRUSH, ux = q.ux, uy = q.uy, uz = q.uz })
    end
  end
  return out
end

local function seam_apply(plan, body)
  for _, o in ipairs(plan) do
    if o.op == "tex" then terrain.paintTexture(body.x + o.x, body.y + o.y, body.z + o.z, o.r, o.slot)
    elseif terrain.paint then
      if o.brush then terrain.paint(body.x + o.x, body.y + o.y, body.z + o.z, o.r, o.c[1], o.c[2], o.c[3], o.s, o.brush)
      else terrain.paint(body.x + o.x, body.y + o.y, body.z + o.z, o.r, o.c[1], o.c[2], o.c[3], o.s) end
    end
  end
end

-- The slot a vein is painted in on this world, chosen once (the save says
-- so): the first of the ore's slots (materials.VEIN_SLOTS) that the world's
-- own ground does not use and no other ore has taken. -1 when every one is
-- the world's ground: the vein still pays by its geometry (veinAt), its
-- outcrops still stand, it is just not painted. → the slot, or nil (not yet).
local function vein_slot(p, v, body, R)
  local rec = vein_rec(p.key)
  if rec.p[v.key] then return rec.p[v.key] end
  if not terrain.slotAt then return nil end
  local mats = ref("materials")
  local slots = mats and mats.VEIN_SLOTS and mats.VEIN_SLOTS[v.ore]
  if not slots then rec.p[v.key] = -1; vein_save(p.key); return -1 end
  local g = vein_ground(v, body, R)
  if not g then return nil end
  local c = v.b[math.ceil(#v.b / 2)]
  local cl = ref("climate")
  local reserved = world_reserved(cl and cl.worldOf and cl.worldOf(cur_body))
  for _, dd in ipairs({ -3.0, 0.8, 3.0, 6.0 }) do
    local h = terrain.slotAt(body.x + c[1] - c.ux * dd, body.y + c[2] - c.uy * dd, body.z + c[3] - c.uz * dd)
    if h then reserved[h] = true end
  end
  local os = oreSlots(cur_body)
  local slot = -1
  for _, sl in ipairs(slots) do
    local taken = os[tostring(sl)]
    if taken == v.ore or (not taken and not reserved[sl]) then slot = sl break end
  end
  if slot > 0 and not os[tostring(slot)] then
    os[tostring(slot)] = v.ore
    save.set("veinslots." .. cur_body, os)
  end
  rec.p[v.key] = slot
  vein_save(p.key)
  return slot
end

-- Only ground near an open face takes paint, and asking the engine to paint
-- a ball buried in solid rock still makes it build that rock's voxels: a
-- buried vein's balls are kept only where a face (a cave, a tunnel, the
-- surface) comes within the ball (terrain.query, the distance to it).
local function near_face(plan, body)
  if not terrain.query then return plan end
  local out = {}
  for _, o in ipairs(plan) do
    local d = terrain.query(body.x + o.x, body.y + o.y, body.z + o.z)
    if d and math.abs(d) <= o.r then out[#out + 1] = o end
  end
  return out
end

-- Paint a seam that crops out, once, when someone comes near (the save says
-- so: `h`). → true when done.
local function vein_paint(p, v, body, R)
  local slot = vein_slot(p, v, body, R)
  if not slot then return false end
  v.slot = slot
  local rec = vein_rec(p.key)
  if rec.h and rec.h[v.key] then return true end
  local g = vein_ground(v, body, R)
  if not g then return false end
  if slot > 0 then
    if not terrain.paintTexture then return false end
    if terrain.capacity and terrain.capacity() < #g * 7 + 40 then return false end
    seam_apply(seamPlan(v.ore, g, slot, kept_clear), body)
    veinsPainted = (veinsPainted or 0) + 1
  end
  rec.h = rec.h or {}
  rec.h[v.key] = 1
  vein_save(p.key)
  return true
end

-- A buried vein's walls where something has opened onto it: a cave it runs
-- through, a tunnel dug into it. `near` (body-relative point, radius)
-- narrows it to the line's points within reach of a cut. No trailing stain;
-- only balls an open face reaches (near_face). Repainting a wall that is
-- inside the vein is right: that rock IS the vein.
local function vein_reveal(v, body, near)
  if not (v.b and v.slot and v.slot > 0 and terrain.paintTexture) then return 0 end
  local pts = v.b
  if near then
    pts = {}
    for _, q in ipairs(v.b) do
      if len(q[1] - near[1], q[2] - near[2], q[3] - near[3]) <= near[4] + seam_r(q) then pts[#pts + 1] = q end
    end
    if #pts == 0 then return 0 end
  end
  local plan = near_face(seamPlan(v.ore, pts, v.slot, kept_clear, { trail = false, buried = v.buried }), body)
  if terrain.capacity and terrain.capacity() < #plan + 40 then return 0 end
  seam_apply(plan, body)
  return #plan
end

local function outcrop_look(n, ore, w)
  local L = out_look(ore)
  local c, e = L.c or { 0.5, 0.5, 0.5 }, L.e
  if ore == "crystal" then
    if not crystal_hue then
      local r = rng(((w and w.seed or 1) % 1000003) + 313)
      crystal_hue = CRYSTAL_HUES[r:int(1, #CRYSTAL_HUES)]
    end
    c = { crystal_hue[1] * 0.55, crystal_hue[2] * 0.55, crystal_hue[3] * 0.55 }
    e = crystal_hue
  end
  local t = { color = { c[1] / ROCK_NEUTRAL, c[2] / ROCK_NEUTRAL, c[3] / ROCK_NEUTRAL } }
  if e then t.emissive, t.emissiveStrength = e, L.glow or 0.4 end
  if n.setTint then pcall(n.setTint, n, t) end
  -- (and once more a pass later, with the sheen: veins_tick)
  -- The sheen is a material patch over the rock's own parts, and it must
  -- wait a pass: in the pass a node is made a model, setMaterial lands before
  -- the model does and would give it a whole Material of its own, dropping
  -- the rock's textures (flora_field tint_whole). veins_tick lays it.
  return { tint = t, mat = (L.metallic or L.rough) and { shading = "physical", metallic = L.metallic or 0, roughness = L.rough or 0.8 } or nil }
end

-- Make a vein's outcrops (the ones not broken yet).
local function outcrops_make(p, v, w, planet)
  local L = out_look(v.ore)
  local g = v.g
  if not g or v.out then return end
  v.out = {}
  local taken = vein_rec(p.key).t[v.key]
  local r = rng(v.seed + 17)
  local count = L.cluster and r:int(5, 8) or math.max(3, math.floor(#g / 1.4))
  for j = 1, count do
    local k = L.cluster and math.ceil(#g / 2) + r:int(-1, 1) or math.max(1, math.min(#g, math.floor((j - 0.5) / count * #g) + 1))
    k = math.max(1, math.min(#g, k))
    local q = g[k]
    -- a sideways step off the seam's line, in the ground's plane
    local ax, ay, az = 1, 0, 0
    if math.abs(q.ux) > 0.9 then ax, ay = 0, 1 end
    local ad = ax * q.ux + ay * q.uy + az * q.uz
    local tx, ty, tz = ax - q.ux * ad, ay - q.uy * ad, az - q.uz * ad
    local tl = len(tx, ty, tz)
    tx, ty, tz = tx / tl, ty / tl, tz / tl
    local bx, by, bz = q.uy * tz - q.uz * ty, q.uz * tx - q.ux * tz, q.ux * ty - q.uy * tx
    local a = r:next() * math.pi * 2
    local off = r:range(0, q.w * 0.55)
    local sc = r:range(L.s[1], L.s[2]) * (L.cluster and 1 or (0.7 + 0.5 * q.w))
    local ox, oy, oz = math.cos(a) * off, math.sin(a) * off, 0
    local px = q[1] + tx * ox + bx * oy - q.ux * sc * (L.sink or 0.3)
    local py = q[2] + ty * ox + by * oy - q.uy * sc * (L.sink or 0.3)
    local pz = q[3] + tz * ox + bz * oy - q.uz * sc * (L.sink or 0.3)
    local rec = { x = px, y = py, z = pz, s = sc, k = k }
    v.out[j] = rec
    -- (none on the base's paving, pad or lots)
    if not bit_on(taken, j) and outcrop_n < params.outcrop_max and ball_clear(px, py, pz, q.ux, q.uy, q.uz, sc, kept_clear) then
      outcrop_n = outcrop_n + 1
      local tilt = r:range(-0.35, 0.35)
      local fa = r:next() * math.pi * 2
      createNode("Ore " .. v.ore, planet, function(n)
        if not v.out or v.out[j] ~= rec or rec.gone then n:destroy() outcrop_n = outcrop_n - 1 return end
        n.model = L.model
        n.x, n.y, n.z = px, py, pz
        n.scale_x, n.scale_y, n.scale_z = sc, sc * (L.cluster and 1.25 or 0.8), sc
        local ux, uy, uz = q.ux + tx * tilt, q.uy + ty * tilt, q.uz + tz * tilt
        local ul = len(ux, uy, uz)
        local fx, fy, fz = tx * math.cos(fa) + bx * math.sin(fa), ty * math.cos(fa) + by * math.sin(fa), tz * math.cos(fa) + bz * math.sin(fa)
        if n.setUp then n:setUp(vec3(ux / ul, uy / ul, uz / ul), vec3(fx, fy, fz)) end
        n.tags = { "rocks", "ore_outcrop" }
        rec.sheen = outcrop_look(n, v.ore, w)
        rec.n = n
      end)
    end
  end
end

-- FLOAT: broken bits of the ore strewn along the seam and a little past it,
-- the sign a prospector walks up a slope to find. Two GPU-instanced scatter
-- sources per vein near you (pebbly grit and fist-sized fragments), on a small
-- Ground region round the seam in its patch's frame, whose density grid is the
-- seam itself: 1 on the line, fading out ~2 m past the seam's edge. No nodes;
-- the engine drops each bit on the real ground and re-settles it when the
-- ground is dug. Tinted as the outcrops are (OUT_LOOK), a little toward the
-- world's rock so it stays stone, not paint. Decoration only: it does not
-- break for ore (the seam under it does).
local FLOAT_KINDS = {
  { id = "grit", lod = { "models/flora/rock_pebbles_l0.gltf", "models/flora/rock_pebbles_l1.gltf" },
    scale = { 0.45, 0.9 }, area = 0.45, chunk = 8, far = 45 },
  { id = "frag", lod = { "models/flora/rock_stone_l0.gltf", "models/flora/rock_stone_l1.gltf" },
    gem = { "models/flora/rock_crystal_l0.gltf", "models/flora/rock_crystal_l1.gltf" },
    scale = { 0.16, 0.42 }, area = 0.32, chunk = 8, far = 70 },
}
-- The bits' colour by ore: weathered, lighter than the outcrops' fresh faces
-- (iron's float is rusted through; dark tints draw blue-grey under the sky).
local FLOAT_COLOUR = {
  iron = { 0.64, 0.30, 0.14 }, copper = { 0.22, 0.58, 0.42 }, sulfur = { 0.92, 0.80, 0.22 },
  obsidian = { 0.09, 0.08, 0.10 }, uranium = { 0.40, 0.50, 0.18 },
}
local function float_make(p, v, w, R)
  if v.float or params.vein_float <= 0 or not (scatter and scatter.create and p.node and p.node.valid) then return end
  v.float = {}
  local L = out_look(v.ore)
  local half = v.len * 0.5 + 4.5
  local rows = math.max(8, math.min(24, math.ceil(half * 2 / 1.0) + 1))
  -- the grid: distance from each cell to the seam's line (patch-local), soft
  local data, pts = {}, v.pts
  for r = 0, rows - 1 do
    for c = 0, rows - 1 do
      local x = v.lx + (c / (rows - 1) - 0.5) * 2 * half
      local z = v.lz + (r / (rows - 1) - 0.5) * 2 * half
      local best, bw = 1e9, 1
      for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        local ex, ez = b.lx - a.lx, b.lz - a.lz
        local t = math.max(0, math.min(1, ((x - a.lx) * ex + (z - a.lz) * ez) / math.max(1e-6, ex * ex + ez * ez)))
        local dx, dz = x - (a.lx + ex * t), z - (a.lz + ez * t)
        local d = math.sqrt(dx * dx + dz * dz)
        if d < best then best, bw = d, a.w + (b.w - a.w) * t end
      end
      local core = math.max(1.2, bw)
      local d = best <= core * 0.6 and 1 or math.max(0, 1 - (best - core * 0.6) / (core * 0.6 + 2.2))
      if d > 0 then
        -- nothing on the base's paving, pad or lots
        local px, py, pz = p.cx + p.ex[1] * x + p.ez[1] * z, p.cy + p.ex[2] * x + p.ez[2] * z, p.cz + p.ex[3] * x + p.ez[3] * z
        local l = len(px, py, pz)
        if kept_clear(px / l * R, py / l * R, pz / l * R) then d = 0 end
      end
      data[r * rows + c + 1] = d * d
    end
  end
  -- the bits' colour: the ore's, a fifth toward the world's rock
  local lk = look_of(v.ore)
  local c = (lk and lk.float) or FLOAT_COLOUR[v.ore] or L.c or { 0.5, 0.5, 0.5 }
  local e = L.e
  if v.ore == "crystal" then
    local h = crystal_tone()
    c, e = { h[1] * 0.55, h[2] * 0.55, h[3] * 0.55 }, h
  end
  local rock = lookOf(KINDS[2], w).tint
  local tint = { c[1] / ROCK_NEUTRAL, c[2] / ROCK_NEUTRAL, c[3] / ROCK_NEUTRAL }
  tint = mix3(tint, rock, 0.15)
  local fg = ref("flora_gen")
  local empty = params.fade_out > 0 and fg and fg.emptyAsset and fg.emptyAsset() or nil
  for i, k in ipairs(FLOAT_KINDS) do
    local lod = (L.cluster and k.gem) or k.lod
    local bands = { { asset = lod[1], distance = k.far * 0.4 }, { asset = lod[2], distance = k.far } }
    if empty then bands[#bands + 1] = { asset = empty, distance = k.far + 0.5 } end
    local per = math.max(1, math.floor(k.area * k.chunk * k.chunk * params.vein_float + 0.5))
    local ok, id = pcall(scatter.create, {
      seed = hash(w.seed or 1, v.seed, 4241 + i),
      center = vec3(v.lx, 0, v.lz), halfX = half, halfZ = half,
      perChunk = per, chunk = k.chunk, align = "surface",
      scaleMin = k.scale[1], scaleMax = k.scale[2], fade = params.fade,
      lod = bands, density = data, densityRows = rows, parent = p.name,
      tint = tint, emissive = e, emissiveStrength = e and (L.glow or 0.4) * 0.5 or nil,
    })
    if ok and id then v.float[#v.float + 1] = id
    elseif not ok then print("mineral field: float scatter refused: " .. tostring(id)) end
  end
end
local function float_drop(v)
  for _, id in ipairs(v.float or {}) do scatter.destroy(id) end
  v.float = nil
end

local function outcrop_gone(rec)
  rec.gone = true
  if rec.n then
    if rec.n.valid then rec.n:destroy() end
    rec.n = nil
    outcrop_n = math.max(0, outcrop_n - 1)
  end
end

outcrops_drop = function(p)
  for _, v in ipairs(p.veins or {}) do
    float_drop(v)
    for _, rec in pairs(v.out or {}) do outcrop_gone(rec) end
    v.out = nil
  end
end

-- Paint the veins coming into reach and grow or put away their outcrops: a
-- little a tick (one vein's ground read, one paint, a few nodes).
local function veins_tick(w, R, body, planet, rx, ry, rz)
  if params.vein_rate <= 0 then return end
  w_seed = w.seed
  local grounds, reveals = 1, 1
  for _, p in pairs(patches) do
    local pd = p.dist or patch_dist(p, rx, ry, rz)
    if pd <= params.vein_show + 20 then
      for _, v in ipairs(veins_of(p, w, R)) do
        local c = v.pts[math.ceil(#v.pts / 2)]
        local d = len(c[1] * R - rx, c[2] * R - ry, c[3] * R - rz)
        if v.buried then
          -- nothing stands over a buried vein: its slot is chosen, and its
          -- walls painted where a cave already opens onto it, as you come near
          local reach = params.vein_cave + v.len * 0.5
          if d <= reach then
            if not v.g and grounds > 0 then grounds = grounds - 1; vein_ground(v, body, R) end
            if v.g and not v.slot then v.slot = vein_slot(p, v, body, R) end
            if v.slot and not v.caved and reveals > 0 then
              reveals = reveals - 1
              v.caved = true
              vein_reveal(v, body, nil)
            end
          elseif v.caved and d > reach + 30 then
            v.caved = nil
          end
        elseif d <= params.vein_show then
          if not v.g and grounds > 0 then grounds = grounds - 1; vein_ground(v, body, R) end
          if v.g and d <= params.vein_paint and not v.slot then vein_paint(p, v, body, R) end
          if v.g and not v.out then outcrops_make(p, v, w, planet) end
          -- (only once the ground under it is made: a bit settled onto
          -- missing ground keeps that height)
          if v.g and not v.float and d <= params.float_show then float_make(p, v, w, R)
          elseif v.float and d > params.float_show + 30 then float_drop(v) end
          for _, rec in pairs(v.out or {}) do
            if rec.sheen and rec.n and rec.n.valid then
              if rec.sheen.mat then pcall(rec.n.setMaterial, rec.n, rec.sheen.mat) end
              if rec.n.setTint then pcall(rec.n.setTint, rec.n, rec.sheen.tint) end
              rec.sheen = nil
            end
          end
        elseif (v.out or v.float) and d > params.vein_show + 30 then
          for _, rec in pairs(v.out or {}) do outcrop_gone(rec) end
          v.out = nil
          float_drop(v)
        end
      end
    end
  end
end

-- The vein a WORLD point lies in, or nil: { ore, slot, patch, vein, k }.
-- A seam that crops out: within its width of its line, down to the lens's
-- foot. A buried one: within its width of its line across, and about a width
-- above and below it. Painted or not (a buried vein's rock is ore before a
-- cut opens it: the laser's reticle reads it here, the payout too).
function veinAt(x, y, z, slack)
  local body = cur_body and space.body(cur_body)
  if not body then return nil end
  slack = slack or 0.4
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for _, p in pairs(patches) do
    if p.veins and patch_dist(p, rx, ry, rz) <= 20 then
      for _, v in ipairs(p.veins) do
        local g = v.b
        if g and v.slot then
          local top, foot = 0.6, 2.4
          if v.buried then top, foot = 1.2, 1.8 end
          for k = 1, #g do
            local q = g[k]
            -- the line (a little down, as the lens is): a ball round each
            -- point stretched down the radial
            local dx, dy, dz = rx - q[1], ry - q[2], rz - q[3]
            local du = dx * q.ux + dy * q.uy + dz * q.uz
            local hx, hy, hz = dx - q.ux * du, dy - q.uy * du, dz - q.uz * du
            local hd = len(hx, hy, hz)
            if hd <= seam_r(q) + slack and du <= q.w * top + slack and du >= -(q.w * foot + slack) then
              return { ore = v.ore, slot = v.slot, patch = p.key, vein = v, k = k }
            end
          end
        end
      end
    end
  end
  return nil
end

-- The outcrop (still standing) within r of a WORLD point.
local function outcrop_near(x, y, z, r)
  local body = cur_body and space.body(cur_body)
  if not body then return nil end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for _, p in pairs(patches) do
    if p.veins and patch_dist(p, rx, ry, rz) <= r + 20 then
      for _, v in ipairs(p.veins) do
        for j, rec in pairs(v.out or {}) do
          if rec.n and not rec.gone and len(rx - rec.x, ry - rec.y, rz - rec.z) <= r + rec.s * 0.8 then
            return p, v, j, rec
          end
        end
      end
    end
  end
  return nil
end

-- The veins near a WORLD point, for probes and the survey readout:
-- { { ore, slot, painted, x, y, z (world, the vein line's middle: under the
-- ground for a buried one), len, out = n standing, buried, depth } }.
function veinsNear(x, y, z, radius)
  local out = {}
  local body = cur_body and space.body(cur_body)
  if not body then return out end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for _, p in pairs(patches) do
    if p.veins and patch_dist(p, rx, ry, rz) <= radius then
      for _, v in ipairs(p.veins) do
        local g = v.b
        local c = g and g[math.ceil(#g / 2)]
        if c and len(c[1] - rx, c[2] - ry, c[3] - rz) <= radius then
          local n = 0
          for _, rec in pairs(v.out or {}) do if rec.n and not rec.gone then n = n + 1 end end
          out[#out + 1] = { ore = v.ore, slot = v.slot, painted = v.slot ~= nil, x = body.x + c[1], y = body.y + c[2],
                            z = body.z + c[3], ux = c.ux, uy = c.uy, uz = c.uz, len = v.len, width = v.width, out = n,
                            buried = v.buried == true, depth = c.dk or 0,
                            sx = g[#g][1] - g[1][1], sy = g[#g][2] - g[1][2], sz = g[#g][3] - g[1][3],
                            d = len(c[1] - rx, c[2] - ry, c[3] - rz) }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
end

-- Every vein laid out in the patches near you, read or not (probes, the
-- survey): { total, buried, surfaced, ores = { [ore] = n }, list = { { ore,
-- buried, depth, len, dir = { x, y, z } (unit, body frame, its middle) } } }.
function veinCensus()
  local c = { total = 0, buried = 0, surfaced = 0, ores = {}, list = {} }
  for _, p in pairs(patches) do
    for _, v in ipairs(p.veins or {}) do
      c.total = c.total + 1
      if v.buried then c.buried = c.buried + 1 else c.surfaced = c.surfaced + 1 end
      c.ores[v.ore] = (c.ores[v.ore] or 0) + 1
      local m = v.pts[math.ceil(#v.pts / 2)]
      c.list[#c.list + 1] = { ore = v.ore, buried = v.buried == true, depth = m.dk or 0, len = v.len,
                              dir = { x = m[1], y = m[2], z = m[3] } }
    end
  end
  return c
end

-- ── what a cut removed ──────────────────────────────────────────────────────
-- The laser hands every bite's receipt here (trackDig); the report arrives a
-- frame or more later through terrain.yields (drained once, here — no other
-- script reads it) with the volume taken out by palette slot. Each slot's
-- volume is that slot's material (materials.SLOT), the vein's ore inside a
-- vein, Star Geode inside a geode pocket; volume becomes units (`dig_unit` m³
-- each, ore 0.6 of that) carried over between bites. What came out is queued
-- for the tool (takeYields) to show, sound and knock loose.

local digs = {}           -- receipt → { cid, body, x, y, z (body-relative), t, from }
local acc = {}            -- material → m³ cut and not paid out yet
local events = {}         -- for the tool: { mat, n, took, full, outcrop, x, y, z (body-rel), body, depth }
-- true where the engine measures what a dig removed (terrain.yields): the
-- laser then pays by volume here, and its timer only breaks surface rocks
yieldsLive = (terrain ~= nil and terrain.yields ~= nil) or false
lastYield = nil
-- (probes) everything the cuts have removed this session: m³ and units by
-- material, and how many reports
yieldStats = { vol = {}, units = {}, reports = 0, removed = 0 }

function trackDig(id, x, y, z, cid)
  if not id or id == 0 or not terrain.yields then return false end
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return false end
  digs[id] = { cid = cid or "astro", body = name, x = x - b.x, y = y - b.y, z = z - b.z, t = time }
  return true
end

local function unit_of(mat)
  local mats = ref("materials")
  local u = params.dig_unit
  if mats and mats.isOre and mats.isOre(mat) then u = u * 0.4 end
  return math.max(0.01, u)
end

-- How far the next unit of `mat` has come (0..1).
function progressOf(mat)
  return mat and math.min(1, (acc[mat] or 0) / unit_of(mat)) or 0
end

-- Metres of ground over a body-relative point, read along its radial from the
-- ground's own field (not a collider: a tree, a roof or the crew above the
-- dig is not rock over it).
local function depth_of(body, rx, ry, rz)
  local l = len(rx, ry, rz)
  if l < 1 or not terrain.raycast then return 0 end
  local ux, uy, uz = rx / l, ry / l, rz / l
  local top = l + 260
  local h = terrain.raycast(vec3(body.x + ux * top, body.y + uy * top, body.z + uz * top), vec3(-ux, -uy, -uz), 520)
  if not (h and h.pos) then return 0 end
  return math.max(0, len(h.pos.x - body.x, h.pos.y - body.y, h.pos.z - body.z) - l)
end
depthAt = function(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return 0 end
  return depth_of(b, x - b.x, y - b.y, z - b.z)
end

-- WHAT THE GROUND IS AT A WORLD POINT, as the cut will pay it: material id,
-- depth (m of ground over it), and whether it is ore (a vein, a pocket or a
-- deposit slot). nil where the engine cannot say (no slotAt): the caller
-- falls back to its own survey.
function materialAt(x, y, z)
  local mats = ref("materials")
  if not (terrain.slotAt and mats and mats.ofSlot) then return nil end
  local pk = pocket_at(x, y, z, 0.2)
  local depth = depthAt(x, y, z)
  if pk then return POCKET_MAT, depth, true end
  -- The slot under the point, paint included (engine card 0602, 0.117.1
  -- dev.1385+): a vein's slot is that vein's ore on this world (oreSlots),
  -- the same answer the cut's payout reads from terrain.yields.
  local sl = terrain.slotAt(x, y, z)
  local m = slotMaterial(sl, space.dominant(x, y, z))
  if not (mats.isOre and mats.isOre(m)) then
    -- rock a buried vein runs through reads as its ore before any cut has
    -- opened it (there is no paint inside solid rock)
    local v = veinAt(x, y, z, 0.2)
    if v then return v.ore, depth, true end
  end
  return m, depth, mats.isOre and mats.isOre(m) or false
end

-- The material a palette slot is on body `bname`: a vein slot's ore, else
-- the registry's.
function slotMaterial(slot, bname)
  local mats = ref("materials")
  if slot then
    local o = oreSlots(bname)[tostring(slot)]
    if o then return o end
  end
  return mats and mats.ofSlot and mats.ofSlot(slot) or "regolith"
end

local POCKET_SLOT = { ice = 8, frost = 8 }
local pocket_painted = {}
local function pocket_reveal(hit)
  -- the walls of a broken-into pocket glow in its crystal: paint the pocket's
  -- ball (only the ground near the surface takes paint — the walls you cut)
  local key = hit.body .. hit.pocket
  if pocket_painted[key] and time - pocket_painted[key] < 1.5 then return end
  pocket_painted[key] = time
  if not terrain.paintTexture then return end
  local list = pocket_list(hit.body)
  local o = list and list[hit.pocket]
  local b = space.body(hit.body)
  if not (o and b) then return end
  local cl = ref("climate")
  local w = cl and cl.worldOf and cl.worldOf(hit.body)
  terrain.paintTexture(b.x + o.x, b.y + o.y, b.z + o.z, (o.r or 2.5) + 0.4, POCKET_SLOT[w and w.kind or ""] or 7)
end

local function pay(d, y)
  local inv, mats = ref("inventory"), ref("materials")
  local b = space.body(d.body)
  if not (inv and mats and b and mats.ofSlot) then return end
  local wx, wy, wz = b.x + d.x, b.y + d.y, b.z + d.z
  local got = {}
  local pk = pocket_at(wx, wy, wz, 0.6)
  if pk then
    got[POCKET_MAT] = (got[POCKET_MAT] or 0) + (y.removed or 0)
    pocket_reveal(pk)
  else
    for slot, vol in pairs(y.slots or {}) do
      local m = slotMaterial(slot, d.body)
      got[m] = (got[m] or 0) + vol
    end
    if (y.untextured or 0) > 0 then got.regolith = (got.regolith or 0) + y.untextured end
    -- A cut into a vein's rock: the plain rock it took out there was the
    -- vein's ore (a buried vein is not painted before the cut opens it), all
    -- of it inside the core, half of it at the edge. What was already
    -- painted is paid by its slot above. Then the walls the cut opened are
    -- painted, so the next bite (and the eye) sees the seam.
    local hit = veinAt(wx, wy, wz, 0.8)
    if hit and d.body == cur_body then
      local inner = veinAt(wx, wy, wz, -0.4) ~= nil
      local f = inner and 1.0 or 0.5
      for m, vol in pairs(got) do
        if mats.grade(m) == "bulk" then
          got[m] = vol * (1 - f)
          got[hit.ore] = (got[hit.ore] or 0) + vol * f
        end
      end
      local v = hit.vein
      if (v.revealT or 0) <= time then
        v.revealT = time + 0.4
        vein_reveal(v, b, { d.x, d.y, d.z, 2.5 })
      end
    end
  end
  local depth = nil
  yieldStats.reports = yieldStats.reports + 1
  yieldStats.removed = yieldStats.removed + (y.removed or 0)
  for m, vol in pairs(got) do
    yieldStats.vol[m] = (yieldStats.vol[m] or 0) + vol
    acc[m] = (acc[m] or 0) + vol
    local u = unit_of(m)
    local n = math.floor(acc[m] / u)
    if n > 0 then
      acc[m] = acc[m] - n * u
      local took
      if m == POCKET_MAT then
        took = 0
        for _ = 1, n do
          local _, t1 = pocket_break(pk, d.cid)
          took = took + (t1 or 0)
          if (t1 or 0) <= 0 then break end
        end
      else
        took = inv.add(d.cid, m, n)
      end
      if took > 0 and mats.isOre(m) and mats.noteOrigin then mats.noteOrigin(m, d.body) end
      if mats.isOre(m) or m == POCKET_MAT then depth = depth or depth_of(b, d.x, d.y, d.z) end
      -- STAR GEODES (missions.geodeFind): only resonant crystal out of the
      -- deep rock — a geode pocket, or the generator's crystal deposits under
      -- three metres of ground. A surface vein's crystal, a plant, a plucked
      -- outcrop are crystal, never a geode.
      if took > 0 and (m == POCKET_MAT or (m == "crystal" and not veinAt(wx, wy, wz, 0.6))) then
        local mi = ref("missions")
        if mi and mi.geodeFind then pcall(mi.geodeFind, d.body, m, took, depth or 0, m == POCKET_MAT and "pocket" or "deposit") end
      end
      yieldStats.units[m] = (yieldStats.units[m] or 0) + took
      local e = { mat = m, n = n, took = took, full = took < n, x = d.x, y = d.y, z = d.z, body = d.body, depth = depth }
      events[#events + 1] = e
      lastYield = e
      if took < n then acc[m] = math.min(acc[m], u * 0.99) end
    end
  end
  -- An outcrop where the cut is: it breaks out whole (a couple of units of
  -- its ore, and a chunk of it knocked loose for the tool to show).
  local p, v, j, rec = outcrop_near(wx, wy, wz, 1.0)
  if p then
    local took = inv.add(d.cid, v.ore, 2)
    if took > 0 and mats.noteOrigin then mats.noteOrigin(v.ore, d.body) end
    if took > 0 then
      local vr = vein_rec(p.key)
      local mask = vr.t[v.key] or 0
      if not bit_on(mask, j) then vr.t[v.key] = mask + 2 ^ (j - 1) end
      vein_save(p.key)
      outcrop_gone(rec)
      local e = { mat = v.ore, n = 2, took = took, full = took < 2, outcrop = true, x = rec.x, y = rec.y, z = rec.z, body = d.body }
      events[#events + 1] = e
      lastYield = e
    else
      events[#events + 1] = { mat = v.ore, n = 2, took = 0, full = true, outcrop = true, x = rec.x, y = rec.y, z = rec.z, body = d.body }
    end
  end
end

local function drain_yields()
  if not terrain.yields then return end
  local list = terrain.yields()
  if list and #list > 0 then
    for _, y in ipairs(list) do
      local d = y.id and digs[y.id]
      if d then
        digs[y.id] = nil
        pay(d, y)
      end
    end
  end
  for id, d in pairs(digs) do
    if time - d.t > 15 then digs[id] = nil end
  end
end

-- The tool's share: what came out since it last asked.
function takeYields()
  if #events == 0 then return nil end
  local e = events
  events = {}
  return e
end

-- ── loose resource bodies ───────────────────────────────────────────────────
-- Logs, chunks and plucked rocks are bodies that STAY: carried with the
-- gravity gun, loaded on a truck, dropped at the depot. Every one is tagged
-- with what it is (materials.tagResource: "resource", "mat:<id>",
-- "qty:<n>"; docs/resources.md) and adopted here, so it is in the save:
-- `loose.bodies` = { { b = body, pf = prefab, x, y, z (body-relative), m =
-- material, q = units, s = scale } }, written every few seconds, and the
-- bodies of the world you are on are spawned again when you come back to it
-- (when the ground under each is made). At most LOOSE_MAX, the oldest going.
LOOSE_MAX = 32
local LOOSE_KEY = "loose.bodies"
local loose = {}
local loose_seq = 0
local loose_t = 0
local loose_restored = {}
local loose_wait = 0

local function loose_live(e) return e.n and e.n.valid and e.n.name == e.name end

function adoptBody(n, pf, mat, qty, scale)
  if not (n and n.valid ~= false and pf and mat) then return end
  local mats = ref("materials")
  -- (where it came from: the world it was cut or picked up on)
  if mats and mats.tagResource then mats.tagResource(n, mat, qty, nil, cur_body) end
  for _, e in ipairs(loose) do if e.n == n and e.name == n.name then e.mat, e.qty = mat, qty return end end
  loose[#loose + 1] = { n = n, name = n.name, pf = pf, mat = mat, qty = qty or 1, s = scale }
  while #loose > LOOSE_MAX do
    local old = table.remove(loose, 1)
    if loose_live(old) then old.n:destroy() end
  end
end

function looseBodies()
  local out = {}
  for _, e in ipairs(loose) do if loose_live(e) then out[#out + 1] = e end end
  return out
end

local loose_pending = {}   -- body → saved entries not spawned yet
local loose_since = {}

local function copy_entry(e)
  return { b = e.b, pf = e.pf, x = e.x, y = e.y, z = e.z, m = e.m, q = e.q, s = e.s }
end

local function loose_tick()
  if time < loose_t then return end
  loose_t = time + 2.0
  if not (cur_body and spawn) then return end
  local body = space.body(cur_body)
  if not body then return end
  local saved = save.get(LOOSE_KEY)
  if type(saved) ~= "table" then saved = {} end
  -- Coming back to a world (a load, a scene hop, a flight home): its bodies
  -- again, each once the ground under it is made.
  if not loose_restored[cur_body] then
    loose_restored[cur_body] = true
    loose_since[cur_body] = time
    local list = {}
    for _, e in ipairs(saved) do
      if e.b == cur_body and type(e.x) == "number" and e.pf and e.m then list[#list + 1] = copy_entry(e) end
    end
    loose_pending[cur_body] = list
  end
  local pend = loose_pending[cur_body] or {}
  local keep = {}
  for _, e in ipairs(pend) do
    local wx, wy, wz = body.x + e.x, body.y + e.y, body.z + e.z
    if not terrain.ready or terrain.ready(wx, wy, wz, 3.0) then
      loose_wait = loose_wait + 1
      loose_seq = loose_seq + 1
      local nm = string.format("%s r%d", e.pf, loose_seq)
      spawn(e.pf, vec3(wx, wy, wz), function(n)
        loose_wait = math.max(0, loose_wait - 1)
        n.name = nm
        if e.s and e.s ~= 1 then n.scale = e.s end
        adoptBody(n, e.pf, e.m, e.q, e.s)
        if assembly and assembly.rebuild then assembly.rebuild(n) end
      end)
    else
      keep[#keep + 1] = e
    end
  end
  loose_pending[cur_body] = keep
  if loose_wait > 0 then return end
  -- The save: other worlds' bodies as they were, this world's as they are
  -- (and the ones still waiting for their ground).
  local out = {}
  for _, e in ipairs(saved) do
    if not loose_restored[e.b] then out[#out + 1] = copy_entry(e) end
  end
  for b, list in pairs(loose_pending) do
    for _, e in ipairs(list) do out[#out + 1] = copy_entry(e) end
  end
  local seen = {}
  for _, e in ipairs(loose) do
    if loose_live(e) and not seen[e.name] then
      seen[e.name] = true
      local n = e.n
      local bn = space.dominant(n.x, n.y, n.z)
      local bb = bn and space.body(bn)
      if bb then
        out[#out + 1] = { b = bn, pf = e.pf, x = n.x - bb.x, y = n.y - bb.y, z = n.z - bb.z, m = e.mat, q = e.qty, s = e.s }
      end
    end
  end
  while #out > LOOSE_MAX do table.remove(out, 1) end
  save.set(LOOSE_KEY, #out > 0 and out or nil)
end

-- ── driver ──────────────────────────────────────────────────────────────────

local function observer()
  local pw = ref("planet_walker")
  local astro = find("Astronaut")
  if astro and pw and pw.onFoot then return astro end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v.node end
  end
  return astro
end

-- (as flora_field's cuts: a list per kind per patch ever built, so the walk
-- looks only at lists whose OLDEST break is due, parses each key once, and
-- forgets an empty list whose patch has gone — breaks_of reads it back)
local break_keys = {}   -- hk → { pk, kid }
local function regrow()
  if params.regrow <= 0 then return end
  for hk, list in pairs(breaks) do
    local kk = break_keys[hk]
    if not kk then
      local pk, kid = hk:match("^(.*)|(%a+)$")
      kk = { pk, kid }
      break_keys[hk] = kk
    end
    local pk, kid = kk[1], kk[2]
    local p = patches[pk]
    if #list == 0 then
      if not p then breaks[hk], break_keys[hk] = nil, nil end
    elseif time - list[1].t >= params.regrow then
      local keep = {}
      for _, c in ipairs(list) do
        if time - c.t < params.regrow then
          keep[#keep + 1] = c
        elseif p and p.srcs[kid] then
          scatter.restore(p.srcs[kid], c.id)
        end
      end
      breaks[hk] = keep
      save_breaks(pk, kid)
    end
  end
end

-- Old saves' holes → ids: the rock nearest each saved position (in the
-- patch plane, where `near` measures) is the one that was broken. Runs as
-- soon as the source is declared: since engine 0.117.0-rc3 a parented source
-- answers `near` in its parent's frame from the frame it is created.
local function convert_holes(body)
  for hk, c in pairs(convert) do
    local p = patches[c.pk]
    local id = p and p.srcs[c.kid]
    if id and srcs[id] then
      local list = breaks[hk]
      for i = 1, #c.xz - 1, 2 do
        local x, z = c.xz[i], c.xz[i + 1]
        local q = vec3(body.x + p.cx + p.ex[1] * x + p.ez[1] * z, body.y + p.cy + p.ex[2] * x + p.ez[2] * z,
                       body.z + p.cz + p.ex[3] * x + p.ez[3] * z)
        local h = scatter.near(id, q, 0.35)[1]
        if h then
          scatter.remove(id, h.id)
          list[#list + 1] = { id = h.id, t = time }
        end
      end
      while #list > MAX_BREAKS do table.remove(list, 1) end
      save.set(old_key(c.pk, c.kid), nil)
      save_breaks(c.pk, c.kid)
      convert[hk] = nil
    elseif not p then
      convert[hk], breaks[hk] = nil, nil
    end
  end
end

-- ── the ground moved: drop the rocks on it again ────────────────────────────
-- flora_field "the ground moved" (it forwards every groundChanged here): a
-- rock settles once and keeps that height, so rocks round a dig, a fill or
-- the base's grade are declared again (same seed, same rocks, breaks kept)
-- once the edits there have landed and gone quiet, one source a tick, the
-- old source drawn for HOLD seconds while the new one's rocks settle.
local HOLD = 2.0
-- On an engine that re-drops the props under a script's edit itself
-- (flora_field ENGINE_RESETTLES_EDITS, 0.117.1) only a `force`d change is
-- taken: ground that changed with no edit the engine saw (see flora_field
-- groundChanged). Redeclaring after every bite swapped whole stands of rocks.
function groundChanged(x, y, z, r, force)
  local body = cur_body and space.body(cur_body)
  local ff = ref("flora_field")
  if not (body and x and ff and ff.groundMerge) then return false end
  if ff.ENGINE_RESETTLES_EDITS and not force then return false end
  local G = ff.GROUND or {}
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  if #gw_regions >= (G.most or 48) then
    ff.groundMerge(gw_regions, rx, ry, rz, r or 3.0, time, math.huge, math.huge)
  else
    ff.groundMerge(gw_regions, rx, ry, rz, r or 3.0, time, G.merge or 6.0, G.cap or 150.0)
  end
  return true
end

local function ground_tick(w, R)
  if #retiring > 0 then sweep_retiring() end
  local ff = ref("flora_field")
  if not (ff and ff.groundDue) then return end
  local G = ff.GROUND or {}
  if #gw_regions > 0 and not (terrain.pending and terrain.pending() > 0) then
    for _, g in ipairs(ff.groundDue(gw_regions, time, G.wait or 1.2)) do
      for key, p in pairs(patches) do
        if patch_dist(p, g.x, g.y, g.z) <= g.r + (G.pad or 3.0)
           and len(g.x - p.cx, g.y - p.cy, g.z - p.cz) <= g.r + p.half * 1.5 + (G.pad or 3.0) then
          for kid, id in pairs(p.srcs) do
            if id and srcs[id] then ff.groundQueue(gw_queue, gw_queued, key, kid) end
          end
        end
      end
    end
  end
  local j = table.remove(gw_queue, 1)
  if not j then return end
  gw_queued[j.key .. "|" .. tostring(j.id)] = nil
  local p = patches[j.key]
  local id = p and p.srcs[j.id]
  local s = id and srcs[id]
  if not s then return end
  retiring[#retiring + 1] = { id = id, pk = p.key, t = time + HOLD }
  srcs[id] = nil
  p.srcs[j.id] = make_source(p, s.kind, w, R)
end
function groundBusy() return #gw_regions + #gw_queue end

-- Rocks resting on something that is not the ground (a roof, the pad, a
-- craft) go, and rocks over open air or under it have their ground re-dropped
-- once: flora_field "props standing on something that is not the ground",
-- with its AUDIT numbers, a slice a frame round the observer.
local au = { t = -1e9, job = nil, tried = {} }
auditRemoved, auditRedropped = 0, 0
local function audit_tick(obs)
  local ff = ref("flora_field")
  local A = ff and ff.AUDIT
  if not (A and ff.nearPager and obs and cur_body and scatter.near and A.every > 0) then return end
  local body = space.body(cur_body)
  if not body then return end
  if not au.job then
    if time < au.t + A.every then return end
    au.t = time
    local list = {}
    local rx, ry, rz = obs.x - body.x, obs.y - body.y, obs.z - body.z
    for id, sr in pairs(srcs) do
      local p = patches[sr.patch]
      if p and patch_dist(p, rx, ry, rz) <= A.radius then list[#list + 1] = id end
    end
    if #list == 0 then return end
    au.job = { list = list, si = 1, pg = nil, F = nil, i = 1 }
  end
  local j = au.job
  local t0 = (app and app.wallClock and app.wallClock()) or os.clock()
  local n = 0
  while j.si <= #j.list do
    local sid = j.list[j.si]
    local sr = srcs[sid]
    if not sr then
      j.si, j.pg, j.F = j.si + 1, nil, nil
    else
      -- a page at a time, round the observer as it stands when this source's
      -- turn comes, body-relative: the job runs over frames on a moving planet
      -- (flora_field pager)
      if not j.pg then j.pg, j.F = ff.nearPager(sid, obs.x - body.x, obs.y - body.y, obs.z - body.z, A.radius), nil end
      if not j.F or j.i > j.F.count then j.F, j.i = ff.nearPagerNext(j.pg, body), 1 end
      local F = j.F
      while F and j.i <= F.count do
        local k = j.i
        j.i, n = k + 1, n + 1
        if F.settled[k] then
          local it = { id = F.ids[k] }
          local px, py, pz = body.x + F.rx[k], body.y + F.ry[k], body.z + F.rz[k]
          local d = terrain.query(px, py, pz)
          if d and math.abs(d) > A.tol then
            -- (flat answers carry no `up`: ask for this one rock)
            local up = F.up and F.up[k]
            if not up and d > 0 and scatter.instance then
              local row = scatter.instance(sid, it.id)
              up = row and row.up
            end
            up = up or vec3(0, 1, 0)
            local hit = d > 0 and raycast(vec3(px + up.x * 0.3, py + up.y * 0.3, pz + up.z * 0.3),
              vec3(-up.x, -up.y, -up.z), 0.6) or nil
            -- (once a session per stand, not per rock: flora_field AUDIT)
            local key = sr.patch .. "|" .. sr.kind.id
            -- (a ray that meets the terrain answers with the world's own node,
            -- named for the body: surveyor is_ground)
            local hn = hit and hit.node
            local solid = hn and hn.valid ~= false and hn.name and not space.body(hn.name)
            local hq = solid and terrain.query(hit.x, hit.y, hit.z)
            if hq and hq > 0.15 then
              scatter.remove(sid, it.id)
              auditRemoved = auditRemoved + 1
            elseif not au.tried[key] and math.abs(d) > (A.redrop or 0.8) then
              au.tried[key] = true
              auditRedropped = auditRedropped + 1
              groundChanged(px, py, pz, 3.0, true)
            end
          end
        end
        if n % 32 == 0 and (((app and app.wallClock and app.wallClock()) or os.clock()) - t0) * 1000 >= A.ms then return end
      end
      if not F then j.si, j.pg, j.F = j.si + 1, nil, nil end
      if (((app and app.wallClock and app.wallClock()) or os.clock()) - t0) * 1000 >= A.ms then return end
    end
  end
  au.job = nil
end

function update(node, dt)
  if params.enabled == 0 then
    if cur_body then tear_down() end
    return
  end
  drain_yields()
  if #events > 32 then for _ = 1, #events - 32 do table.remove(events, 1) end end
  if cur_body then audit_tick(observer()) end
  loose_tick()
  if time < next_t then return end
  next_t = time + 0.2
  local gm = ref("game_manager")
  if gm and gm.loading then return end
  if not (scatter and scatter.create) then return end

  local obs = observer()
  if not obs then return end
  local bname = space.dominant(obs.x, obs.y, obs.z)
  local body = bname and space.body(bname)
  local cl = ref("climate")
  if not (body and cl) then
    if cur_body then tear_down() end
    return
  end
  if bname ~= cur_body then
    tear_down()
    cur_body, bodyName = bname, bname
  end
  local w = cl.worldOf(bname)
  -- A world with no crust to speak of gets nothing: a gas body's "surface" is
  -- not somewhere rocks lie on.
  if not w or w.kind == "gas" or params.density <= 0 then return end
  local planet = find(bname)
  anchored = planet ~= nil and planet.valid == true
  if not anchored then return end
  -- A hot reload frees this script's sources (engine 0.117) but not its patch
  -- nodes: clear them once, or each patch would be made twice under one name.
  if not swept then
    swept = true
    for _, n in ipairs(findTagged("rocks") or {}) do
      if n.valid and n.name:sub(1, 6) == "Rocks " then n:destroy() end
    end
  end

  local rx, ry, rz = obs.x - body.x, obs.y - body.y, obs.z - body.z
  local rl = len(rx, ry, rz)
  if rl < 1e-3 then return end
  local R = w.radius or body.radius or 100
  if rl - R > params.alt_max then return end

  local maxFar = 0
  for _, k in ipairs(KINDS) do maxFar = math.max(maxFar, k.far * params.reach) end
  local P = math.max(150, math.min(260, R * params.patch))

  -- Patches near the observer (sampled in the tangent plane, so face seams
  -- take care of themselves), nearest first.
  local ux, uy, uz = rx / rl, ry / rl, rz / rl
  local _, _, _, t1, _, t2 = patch_frame(select(1, project(rx, ry, rz, R)), ux, uy, uz)
  local want, order = {}, {}
  local reachR = maxFar + P * 0.5
  local steps = math.ceil(reachR / (P * 0.5))
  for a = -steps, steps do
    for b = -steps, steps do
      local ox, oz = a * P * 0.5, b * P * 0.5
      if ox * ox + oz * oz <= reachR * reachR then
        local face, sgn, u, v = project(ux * R + t1[1] * ox + t2[1] * oz, uy * R + t1[2] * ox + t2[2] * oz,
          uz * R + t1[3] * ox + t2[3] * oz, R)
        local i, j = math.floor(u / P), math.floor(v / P)
        local key = pkey(face, sgn, i, j)
        if not want[key] then
          want[key] = { face, sgn, i, j }
          if not patches[key] then
            local cx, cy, cz = unproject(face, sgn, (i + 0.5) * P, (j + 0.5) * P, R)
            order[#order + 1] = { key = key, f = want[key], d = len(cx * R - rx, cy * R - ry, cz * R - rz) }
          end
        end
      end
    end
  end
  table.sort(order, function(a, b) return a.d < b.d end)
  local o = order[1]
  if o then
    local face, sgn, i, j = o.f[1], o.f[2], o.f[3], o.f[4]
    local cx, cy, cz = unproject(face, sgn, (i + 0.5) * P, (j + 0.5) * P, R)
    local yaw, pitch, roll, ex, ey, ez = patch_frame(face, cx, cy, cz)
    local ax, ay, az = unproject(face, sgn, i * P, (j + 0.5) * P, R)
    local bx, by, bz = unproject(face, sgn, (i + 1) * P, (j + 0.5) * P, R)
    local half = len(ax - bx, ay - by, az - bz) * R * 0.5 * 1.15
    local p = { key = o.key, face = face, sgn = sgn, i = i, j = j, P = P, rows = math.floor(params.rows),
                cx = cx * R, cy = cy * R, cz = cz * R, ex = ex, ey = ey, ez = ez, half = half, srcs = {},
                name = "Rocks " .. bname .. " " .. o.key }
    patches[o.key] = p
    createNode(p.name, planet, function(n)
      n.x, n.y, n.z = p.cx, p.cy, p.cz
      n.pitch, n.roll, n.yaw = pitch, roll, yaw
      n.tags = { "rocks" }
      p.node = n
    end)
  end

  -- A patch whose node went (the planet was rebuilt under it — a scene
  -- reload, or the system generator re-running) is dropped and made again:
  -- its sources would otherwise follow a parent that no longer exists.
  for key, p in pairs(patches) do
    if p.node and not p.node.valid then drop_patch(key) end
  end
  -- Sources: nearest patch first, one new one a tick (declaration is cheap,
  -- but every new source's chunks are settled onto the ground over the next
  -- frames — staggering them spreads that out).
  local near = {}
  for _, p in pairs(patches) do
    p.dist = patch_dist(p, rx, ry, rz)
    near[#near + 1] = p
  end
  table.sort(near, function(a, b) return a.dist < b.dist end)
  local built = 0
  for _, p in ipairs(near) do
    -- No terrain answering under it yet: lay nothing (a rock settled onto
    -- missing ground keeps that height for good).
    if p.node and built < 1 and terrain.query(body.x + p.cx, body.y + p.cy, body.z + p.cz) then
      for _, k in ipairs(KINDS) do
        local far = k.far * params.reach
        local id = p.srcs[k.id]
        if id == nil and p.dist < far + 5 and built < 1 then
          p.srcs[k.id] = make_source(p, k, w, R)
          built = built + 1
        elseif id and p.dist > far + 40 then
          drop_source(id)
          p.srcs[k.id] = nil
        end
      end
    end
  end
  local n = 0
  for key, p in pairs(patches) do
    if (p.dist or 0) > maxFar + 80 and not want[key] then drop_patch(key) else n = n + 1 end
  end
  patchCount = n
  local ns, props = 0, 0
  for id, s in pairs(srcs) do
    ns = ns + 1
    local c = scatter.cost(id)
    props = props + ((c and c.props) or 0) * (s.fill or 1)
  end
  sources, count = ns, math.floor(props)
  convert_holes(body)
  regrow()
  ground_tick(w, R)
  veins_tick(w, R, body, planet, rx, ry, rz)

  if not frame_checked then
    for _, p in pairs(patches) do
      if p.node and p.node.valid and p.node.toWorld then
        frame_checked = true
        local o0 = p.node:toWorld(vec3(0, 0, 0))
        local x1 = p.node:toWorld(vec3(1, 0, 0))
        local err = len(x1.x - o0.x - p.ex[1], x1.y - o0.y - p.ex[2], x1.z - o0.z - p.ex[3])
        if err > 0.02 then print(string.format("mineral field: PATCH FRAME MISMATCH %.3f", err)) end
        break
      end
    end
  end
end

-- ── the resonance sensor ─────────────────────────────────────────────────────
-- With the Terrain Laser in hand and on foot, a pocket within `pocket_hint`
-- metres shows as a faint ring on the ground above it, pulsing, with how far
-- down it lies. Drawn in the camera pass like every draw.*.
function lateUpdate(node, dt)
  if params.pocket_hint <= 0 or not (draw and draw.ring) then return end
  if cinematicUp() then return end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot) then return end
  local tb = ref("tool_belt")
  -- The suit's resonance sensor rides the Terrain Laser (the belt is built
  -- from the pack now, so its slot number says nothing).
  if not (tb and tb.toolId and tb.toolId() == "laser") then return end
  local a = find("Astronaut")
  if not a then return end
  local bname = space.dominant(a.x, a.y, a.z)
  local body = bname and space.body(bname)
  local list = body and pocket_list(bname)
  if not list then return end
  local taken = pocket_taken(bname)
  local rx, ry, rz = a.x - body.x, a.y - body.y, a.z - body.z
  local rl = len(rx, ry, rz)
  for i, o in ipairs(list) do
    if (taken[i] or 0) < params.pocket_units then
      local ol = len(o.x, o.y, o.z)
      local ux, uy, uz = o.x / ol, o.y / ol, o.z / ol
      -- Along the ground: the angle between the two radials, at your radius.
      local c = (rx * ux + ry * uy + rz * uz) / rl
      local d = math.acos(math.max(-1, math.min(1, c))) * rl
      if d < params.pocket_hint then
        -- The ground over the pocket, found from where its centre is.
        local gr = ol + (o.d or 8)
        for _ = 1, 6 do
          local q = terrain.query(body.x + ux * gr, body.y + uy * gr, body.z + uz * gr)
          if not q then break end
          gr = gr - q
          if math.abs(q) < 0.05 then break end
        end
        local gx, gy, gz = body.x + ux * (gr + 0.15), body.y + uy * (gr + 0.15), body.z + uz * (gr + 0.15)
        local k = 1 - d / params.pocket_hint
        local pulse = 0.5 + 0.5 * math.sin((time or 0) * 3.0 + i)
        local col = { 0.55, 0.85, 1.0 }
        draw.ring(gx, gy, gz, ux, uy, uz, 1.2 + pulse * 1.4, col[1], col[2], col[3], (0.25 + 0.55 * k) * (0.6 + 0.4 * pulse))
        draw.ring(gx, gy, gz, ux, uy, uz, 0.5, col[1], col[2], col[3], 0.35 + 0.5 * k)
        if camera and camera.worldToScreen and draw.text then
          local sx, sy, dep, on = camera.worldToScreen(gx + ux * 1.6, gy + uy * 1.6, gz + uz * 1.6)
          if on and sx and d < params.pocket_hint * 0.7 then
            local vx, vy, vw, vh = camera.screenRect()
            local s = (vh or 720) / uiDesignH()
            draw.text(sx, sy, string.format("resonance · %.0f m down", math.max(1, gr - ol - (o.r or 2.5))),
              13 * s, col[1], col[2], col[3], 0.5 + 0.5 * k, "center")
          end
        end
      end
    end
  end
end

-- ── ground audit (probes, the debug console) ────────────────────────────────
-- flora_field.groundAudit for the rocks: every settled rock within `radius`
-- of a WORLD point against the terrain where it lies (+ over, − under).
function groundAudit(x, y, z, radius, tol)
  tol = tol or 0.3
  local out = { checked = 0, floating = 0, buried = 0, worst = 0, examples = {}, props = {} }
  local body = cur_body and space.body(cur_body)
  if not (body and scatter and scatter.near) then return out end
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and patch_dist(p, x - body.x, y - body.y, z - body.z) <= radius then
      local F = near_flat(id, vec3(x, y, z), radius)
      for k = 1, F.count do
        if F.settled[k] then
          local hid, hx, hy, hz = F.ids[k], F.x[k], F.y[k], F.z[k]
          local d = terrain.query(hx, hy, hz)
          if d then
            out.checked = out.checked + 1
            if math.abs(d) > math.abs(out.worst) then out.worst = d end
            local bad = d > tol and "floating" or (d < -tol and "buried" or nil)
            if bad then
              out[bad] = out[bad] + 1
              if #out.examples < 12 then
                out.examples[#out.examples + 1] = { src = id, id = hid, d = d, kind = s.kind.id, x = hx, y = hy, z = hz }
              end
            end
            if #out.props < 400 then
              out.props[#out.props + 1] = { src = id, id = hid, d = d, kind = s.kind.id, x = hx, y = hy, z = hz }
            end
          end
        end
      end
    end
  end
  return out
end
