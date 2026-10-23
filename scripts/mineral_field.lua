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
  -- Metres over which one LOD band cross-dissolves into the next.
  --@range 0 40 --@units m
  fade = 10.0,
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
  -- With the Mining Laser out, ground within this range of a pocket shows a
  -- faint pulsing ring and how deep it lies: the suit's resonance sensor.
  --@range 0 80 --@units m
  pocket_hint = 35.0,

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
    id = "gravel", mat = "regolith", area = 14 * 1.0 / (34 * 34), chunk = 18, far = 60,
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
    id = "stone", mat = "silica", area = 14 * 0.55 / (34 * 34), chunk = 22, far = 95,
    scale = { 0.8, 1.6 },
    lod = { "models/flora/rock_stone_l0.gltf", "models/flora/rock_stone_l1.gltf" },
    yield = 2,
    -- Broken ground: patchy at a coarser scale than the gravel.
    density = function(x, y, z)
      return math.saturate(math.fbm(x * 1.7 + 11.0, y * 1.7, z * 1.7, 3) * 1.6)
    end,
  },
  {
    id = "boulder", mat = "iron", area = 14 * 0.22 / (34 * 34), chunk = 32, far = 170,
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
local swept = false
local cur_body = nil
local next_t = 0
local frame_checked = false

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

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

local function drop_patch(key)
  local p = patches[key]
  if not p then return end
  for _, id in pairs(p.srcs) do if id then drop_source(id) end end
  if p.node and p.node.valid then p.node:destroy() end
  patches[key] = nil
end

local function tear_down()
  for key in pairs(patches) do drop_patch(key) end
  for id in pairs(srcs) do drop_source(id) end
  patches, srcs, breaks, convert = {}, {}, {}, {}
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
    fade = math.max(fade, math.min(far * 0.22, far * 0.65 * 0.5))
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
    for _, it in ipairs(scatter.near(id, vec3(body.x + bx, body.y + by, body.z + bz), 230) or {}) do
      local keep = ff.baseKeep(it.pos.x - body.x, it.pos.y - body.y, it.pos.z - body.z, 0.6)
      if keep < 1 and (((it.id % 2147483647) * 48271 + 7) % 2147483647) / 2147483647 >= keep then
        scatter.remove(id, it.id)
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
-- the Mining Laser is out) says when you are standing over one.
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
function nearest(x, y, z, radius)
  radius = radius or params.grab
  -- Inside an ore pocket the pocket is what the beam is cutting.
  local pk = pocket_at(x, y, z)
  if pk then return pk end
  local body = cur_body and space.body(cur_body)
  if not body then return nil end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  local best = nil
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and patch_dist(p, rx, ry, rz) <= radius + 3 then
      local dx, dy, dz = rx - p.cx, ry - p.cy, rz - p.cz
      local lx = dx * p.ex[1] + dy * p.ex[2] + dz * p.ex[3]
      local lz = dx * p.ez[1] + dy * p.ez[2] + dz * p.ez[3]
      local qx = body.x + p.cx + p.ex[1] * lx + p.ez[1] * lz
      local qy = body.y + p.cy + p.ex[2] * lx + p.ez[2] * lz
      local qz = body.z + p.cz + p.ex[3] * lx + p.ez[3] * lz
      local hits = scatter.near(id, vec3(qx, qy, qz), radius + 1.0)
      for n = 1, math.min(#hits, 8) do
        local h = hits[n]
        local hx, hy, hz = h.pos.x - body.x, h.pos.y - body.y, h.pos.z - body.z
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
      for _, h in ipairs(scatter.near(id, vec3(x, y, z), radius) or {}) do
        local r = br * (h.scale or 1)
        if h.settled ~= false and r >= 0.3 then
          out[#out + 1] = { x = h.pos.x, y = h.pos.y, z = h.pos.z, r = r, d = h.distance,
                            key = "r" .. id .. ":" .. tostring(h.id) }
        end
      end
    end
  end
  return out
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
  local took = inv.add(cid or "astro", k.mat, units)
  if took <= 0 then return k.mat, 0 end
  scatter.remove(hit.source, hit.id)
  local p = patches[hit.patch]
  if p then
    local list = breaks_of(hit.patch, k.id)
    list[#list + 1] = { id = hit.id, t = time }
    while #list > MAX_BREAKS do scatter.restore(hit.source, table.remove(list, 1).id) end
    save_breaks(hit.patch, k.id)
  end
  return k.mat, took
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

local function regrow()
  if params.regrow <= 0 then return end
  for hk, list in pairs(breaks) do
    local keep = {}
    local pk, kid = hk:match("^(.*)|(%a+)$")
    local p = patches[pk]
    for _, c in ipairs(list) do
      if time - c.t < params.regrow then
        keep[#keep + 1] = c
      elseif p and p.srcs[kid] then
        scatter.restore(p.srcs[kid], c.id)
      end
    end
    if #keep ~= #list then
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

function update(node, dt)
  if params.enabled == 0 then
    if cur_body then tear_down() end
    return
  end
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
-- With the Mining Laser in hand and on foot, a pocket within `pocket_hint`
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
