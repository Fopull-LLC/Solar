-- FLORA FIELD — the living surface. Puts a planet's plants on the ground with
-- the engine's GPU-instanced scatter: thousands of plants, no scene node per
-- plant, the same forest in the same places on every visit.
--
-- WHAT IT DOES. `flora_gen` decides what grows (species, shapes, colours,
-- sizes). This script decides WHERE, and hands it to `scatter.create`:
--
--   PATCHES   The planet's surface is cut into square patches on a cube-face
--             grid (`patch` metres). A patch is one small scene node, a child
--             of the planet, lying in the tangent plane at the patch's centre
--             — so it rides the planet's orbit, and so does everything on it.
--   SOURCES   Each patch carries one scatter source per species that is close
--             enough to be seen (each species has its own reach: grass ~26 m,
--             trees ~150 m). A source is a Ground region in the patch's plane;
--             the engine drops every prop down onto the real terrain. A tree
--             has a TWIN source for its trunk (same seed, so the same
--             instances and ids), because a source's tint colours every part
--             of its props and a trunk is not the colour of its leaves.
--   DENSITY   Each source's density grid is the climate sampled across the
--             patch: biome × species preference × the species' own clumping
--             noise, zero under water for land plants and above it for kelp.
--   COLOUR    `tint` (and `emissive` for glowing species) from flora_gen: the
--             library is one neutral set of meshes and pictures.
--
-- WHY PATCHES AND NOT ONE SPHERE SOURCE PER SPECIES. Sphere regions work since
-- engine 0.117 (card 0424), but a sphere's density is one equirectangular grid
-- for the whole planet, sampled at declare time: the climate (and the ground
-- height it depends on) would have to be evaluated over the entire surface,
-- for every species, at a resolution fine enough for a meadow's edge — at a
-- kilometre-scale world, millions of samples. A patch samples only the ground
-- near you, a cell at a time, and a far patch is simply never built.
--
-- HARVEST: `nearestPlant` + `harvest` are the tool-facing API (tool_belt's
-- Harvest Cutter calls them unchanged). A cut plant is `scatter.remove`d by
-- its instance id (exact since 0.117), from the twin too, and the source's
-- `scatter.removed()` list is the save: a few ids per patch and species, put
-- back with `scatter.remove` whenever the source is declared again, and
-- restored after `regrow` seconds. Saves from before kept "holes" (positions
-- in the patch plane); those are converted to ids the first time the patch is
-- built, and the old record is deleted.

defaults = {
  --@header Field
  -- Patch size as a fraction of the planet's radius (clamped to 150..260 m).
  -- Bigger = fewer sources, but the far edge of the patch's plane rises off a
  -- small planet's curve (the engine drops props from 60 m above the plane,
  -- 150 m deep).
  --@range 0.3 0.9
  patch = 0.6,
  -- Density-grid resolution per patch side (the climate is sampled rows² times).
  --@range 6 24
  rows = 14,
  -- Seconds between field updates.
  interval = 0.15,
  -- Above this height nothing new is planted (flying, not walking).
  --@range 100 1000 --@units m
  alt_max = 450.0,
  -- Hard cap on resident props across every flora source (what `scatter.cost`
  -- says), so a dense world costs a known amount. The engine draws at most
  -- 20,000 scatter instances a frame across ALL sources (rocks included).
  --
  -- Measured on engine 0.117 (card 0424): the scatter walks a resident prop
  -- for ~0.1–0.2 µs a frame and settles arriving ones a few at a time inside
  -- 1 ms, so this is a look budget more than a frame budget now.
  --@range 1000 18000
  max_props = 2800,
  -- Multiplies every species' reach. Turn it down if the surface ever hitches.
  --@range 0.4 1.5
  reach = 1.0,

  --@header Harvest
  regrow = 900.0,   -- seconds before a cut plant grows back
  -- Seconds after a patch is planted at which its sources are re-declared
  -- once, so every prop is dropped again onto ground that has finished
  -- streaming in at full detail (0 = never).
  resettle = 25.0,

  --@header Ground wash
  -- Grass fields lay a tinted decal on the ground under themselves, so a
  -- meadow reads as a meadow from the air long after the blades have faded.
  -- 0 = off.
  tint = 1,
  --@range 40 250 --@units m
  tint_range = 130.0,
  --@range 8 40 --@units m
  tint_step = 18.0,
  --@range 0 400
  tint_max = 150,
  -- Above this height the wash is lifted entirely.
  --@range 20 400 --@units m
  tint_alt = 90.0,

  --@header Glow
  -- Small emissive motes around glowing plants near you: the plant keeps its
  -- own colour and shape, the air around it shimmers. 0 = off.
  --@range 0 24
  motes = 12,
  --@range 5 60 --@units m
  mote_range = 28.0,
  enabled = 1,
}

-- Published for the HUD / smoke harness.
count = 0          -- resident props across every flora source
sources = 0        -- live scatter sources
patchCount = 0
bodyName = nil

local patches = {}  -- key → patch
local srcs = {}     -- scatter id → { patch = key, sp = sp }
local cuts = {}     -- "key|spid" → { {id, t}, ... } cut plants, oldest first
local convert = {}  -- patch key → { sp, list of old hole positions } (old saves)
local preload = {}  -- body → "pending" | "done"
local settled = {}  -- "src:inst" → { x, y, z } body-relative ground point
local next_t = 0
local cur_body = nil
local last_diag = ""
local motes, mote_t = {}, 0
local washes = {}   -- "patch:i,j" → decal id (or false: nothing grows there)
local wash_n = 0
local wash_info = {}  -- key → { x, y, z (body-rel), base alpha }
local wash_fade_t = 0
local frame_checked = false
local wash   -- defined below update (ground wash)
local preload_t = 0
local swept = false

local AX = { { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 } }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function diag(msg)
  if msg ~= last_diag then
    last_diag = msg
    log("flora: " .. msg)
  end
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function comp(v, i)
  if i == 1 then return v[1] end
  if i == 2 then return v[2] end
  return v[3]
end

-- Body-relative position → (face, sign, u, v) on the cube of half-size R.
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

-- A patch's frame: up = the radial at its centre, X along the cube face's
-- u axis (so neighbouring squares share their edges instead of meeting at
-- angles and leaving diamond-shaped gaps at every corner), Z = X × Y. Returned
-- as the node's yaw/pitch/roll for R = Ry(yaw)·Rx(pitch)·Rz(roll), whose
-- columns are those three axes:
--   col Y·row = (sin r cos p, cos r cos p, −sin p),  col Z = (cos p sin y, −sin p, cos p cos y)
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

-- The patch frame for up = (ux,uy,uz), as the node's pitch/roll (yaw 0) and
-- the three axes that rotation produces: R = Rx(pitch)·Rz(roll), so
--   ex = (cos r, sin r cos p, sin r sin p)   ey = (-sin r, cos r cos p, cos r sin p)
--   ez = (0, -sin p, cos p)
-- Angles canonical (pitch within ±90°) — the engine stores a rotation, and a
-- non-canonical triple comes back different between writes (see vessel_spawner).
local function frame_for(ux, uy, uz)
  local roll = math.asin(math.max(-1, math.min(1, -ux)))
  if uy < 0 then
    roll = math.pi - roll
    if roll > math.pi then roll = roll - 2 * math.pi end
  end
  local c = math.cos(roll)
  local pitch = 0.0
  if math.abs(c) > 1e-6 then pitch = math.atan2(uz / c, uy / c) end
  local cr, sr, cp, sp = math.cos(roll), math.sin(roll), math.cos(pitch), math.sin(pitch)
  return pitch, roll,
    { cr, sr * cp, sr * sp }, { -sr, cr * cp, cr * sp }, { 0, -sp, cp }
end

-- ── observers ───────────────────────────────────────────────────────────────

local function observer()
  -- NOT `astro.visible`: the camera hides the body in first person, and a field
  -- that took that as "they're flying" would tear itself down and rebuild every
  -- time the player walked into a building.
  local astro = find("Astronaut")
  local pw = ref("planet_walker")
  if astro and pw and pw.onFoot then return astro end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v.node end
  end
  return astro
end

-- ── sources ─────────────────────────────────────────────────────────────────

-- Save keys: "flora2.<body>.<patch>.<species>" holds the source's removed
-- ids; "flora.<…>" is the old hole format (x, z pairs in the patch plane).
local function save_key(pk, spid)
  return string.format("flora2.%s.%s.%d", cur_body or "?", pk, spid)
end
local function old_key(pk, spid)
  return string.format("flora.%s.%s.%d", cur_body or "?", pk, spid)
end

-- Save values are capped near a kilobyte: at most this many cuts per patch and
-- species (the oldest grows back early).
local MAX_CUTS = 40

local function drop_source(id)
  local s = srcs[id]
  if not s then return end
  if scatter and scatter.destroy then scatter.destroy(id) end
  local p = patches[s.patch]
  if p then
    if s.part == "bark" then
      if p.bark[s.sp.id] == id then p.bark[s.sp.id] = nil end
    elseif p.srcs[s.sp.id] == id then
      p.srcs[s.sp.id] = nil
    end
  end
  srcs[id] = nil
end

-- A species' sources on a patch (its crown, and a tree's trunk twin).
local function drop_species(p, spid)
  if p.srcs[spid] then drop_source(p.srcs[spid]) end
  if p.bark[spid] then drop_source(p.bark[spid]) end
  p.srcs[spid], p.bark[spid] = nil, nil
end

local function drop_patch(key)
  local p = patches[key]
  if not p then return end
  for spid in pairs(p.srcs) do drop_species(p, spid) end
  for spid in pairs(p.bark) do drop_species(p, spid) end
  if p.node and p.node.valid then p.node:destroy() end
  patches[key] = nil
end

function clearAll()
  for key in pairs(patches) do drop_patch(key) end
  for id in pairs(srcs) do drop_source(id) end
  for _, m in ipairs(motes) do if m and m.valid then m:destroy() end end
  for _, d in pairs(washes) do if d and decals and decals.remove then decals.remove(d) end end
  washes, wash_n, wash_info = {}, 0, {}
  patches, srcs, settled, motes, cuts, convert = {}, {}, {}, {}, {}, {}
  count, sources, patchCount = 0, 0, 0
end

-- The cuts a patch's species carries, loaded from the save once.
local function cuts_of(pk, spid)
  local ck = pk .. "|" .. spid
  local list = cuts[ck]
  if list then return list end
  list = {}
  local saved = save.get(save_key(pk, spid))
  if type(saved) == "table" then
    for i = 1, #saved do
      local id = tonumber(saved[i])
      if id then list[#list + 1] = { id = id, t = time } end
    end
  end
  cuts[ck] = list
  -- An old save's holes: positions, turned into ids once the source stands.
  local old = save.get(old_key(pk, spid))
  if type(old) == "table" and #old >= 2 then
    convert[ck] = { pk = pk, spid = spid, xz = old }
  elseif old ~= nil then
    save.set(old_key(pk, spid), nil)
  end
  return list
end

local function save_cuts(pk, spid)
  local list = cuts[pk .. "|" .. spid] or {}
  local p = patches[pk]
  local id = p and p.srcs[spid]
  -- The engine's own list is the record; the Lua list only orders the cuts
  -- by age (for regrowth and the cap).
  local ids = (id and scatter.removed) and scatter.removed(id) or nil
  if not ids or #ids ~= #list then
    ids = {}
    for _, c in ipairs(list) do ids[#ids + 1] = c.id end
  end
  save.set(save_key(pk, spid), #ids > 0 and ids or nil)
end

-- Build one species' source on one patch — and a tree's trunk twin, same
-- seed and grid, so the two always stand together. Returns the id, or false
-- when the species has nothing to grow there (an all-zero density is never
-- declared).
local function make_source(p, sp, fg, w)
  local rows = p.rows
  local data, any = {}, false
  local sum = 0
  for i = 1, rows * rows do
    local s = p.samples[i]
    local d = s and fg.densityAt(sp, s, s.x, s.y, s.z, w.radius) or 0
    data[i] = d
    sum = sum + d
    if d > 0.01 then any = true end
  end
  if not any then return false end
  local far = sp.far * params.reach
  local seed = hash(w.seed or 1, p.face, p.sgn + 2, p.i + 50000, p.j + 50000, sp.id)
  local list = cuts_of(p.key, sp.id)
  local function declare(part)
    local lod = {}
    for l = 0, (sp.lods or 1) - 1 do
      local frac = sp.lodAt[l + 1] or 1.0
      lod[#lod + 1] = { asset = fg.assetFor(sp, l, part), distance = far * frac }
    end
    lod[#lod].distance = far
    local opts = {
      seed = seed,
      center = vec3(0, 0, 0), halfX = p.half, halfZ = p.half,
      perChunk = sp.per, chunk = sp.chunk, align = sp.upright and "world" or "surface",
      scaleMin = sp.scaleMin, scaleMax = sp.scaleMax,
      fade = math.max(3.0, far * 0.08), lod = lod,
      density = data, densityRows = rows,
      parent = p.name,
    }
    -- Each patch's stand of a species is shaded a little differently (a
    -- deterministic roll per patch): the engine already varies every prop's
    -- brightness ±15 %, and this keeps one hillside's grass from being the
    -- exact green of the next.
    local jr = rng(seed % 2147483647 + 77)
    local k = jr:range(0.92, 1.08)
    local function jit(t)
      return { t[1] * k * jr:range(0.96, 1.04), t[2] * k * jr:range(0.96, 1.04), t[3] * k * jr:range(0.96, 1.04) }
    end
    if part == "bark" then
      opts.tint = jit(sp.barkTint)
    else
      opts.tint = jit(sp.tint)
      if sp.emissive and (sp.emissiveStrength or 0) > 0 then
        opts.emissive, opts.emissiveStrength = sp.emissive, sp.emissiveStrength
      end
    end
    local ok, id = pcall(scatter.create, opts)
    if not ok then
      diag("scatter.create refused: " .. tostring(id))
      return nil
    end
    -- What was cut here stays cut: ids are (seed, chunk, index), so the same
    -- id names the same plant in every declaration of this source.
    for _, c in ipairs(list) do scatter.remove(id, c.id) end
    srcs[id] = { patch = p.key, sp = sp, fill = sum / (rows * rows), part = part, made = time }
    return id
  end
  local id = declare(nil)
  if not id then return false end
  if sp.twin then p.bark[sp.id] = declare("bark") or nil end
  return id
end

-- Sample the climate across a patch: one ground-height probe and one climate
-- sample per density cell, done once per patch. `terrain.query` is the cheap
-- signed distance; two steps of it find the ground under each cell.
local function sample_patch(p, body, w, cl)
  local rows, half = p.rows, p.half
  local R0 = p.r0
  -- No terrain field answering here yet (still generating, or streamed out):
  -- plant nothing. The engine settles a prop ONCE, when its chunk first
  -- streams, and keeps that height — planting before the ground exists is how
  -- plants end up hanging in the air.
  if not terrain.query(body.x + p.cx, body.y + p.cy, body.z + p.cz) then return false end
  p.samples = {}
  -- Rivers and lakes near this patch (scale 3): their banks and shores are
  -- wet ground, where the wet-loving species crowd in and the dry ones thin
  -- out (flora_gen.densityAt reads `riparian`), and a lake's water grows no
  -- land plants. One list per patch, so each sample tests only a few dozen
  -- segments.
  local wet = cl.wetNear and w.hydro and cl.wetNear(body.name or cur_body, p.cx, p.cy, p.cz, half * 1.5) or nil
  for r = 0, rows - 1 do
    for c = 0, rows - 1 do
      local x = (c / (rows - 1) - 0.5) * 2 * half
      local z = (r / (rows - 1) - 0.5) * 2 * half
      local px = p.cx + p.ex[1] * x + p.ez[1] * z
      local py = p.cy + p.ex[2] * x + p.ez[2] * z
      local pz = p.cz + p.ex[3] * x + p.ez[3] * z
      local l = len(px, py, pz)
      local ux, uy, uz = px / l, py / l, pz / l
      local rg = R0
      for _ = 1, 2 do
        local q = terrain.query(body.x + ux * rg, body.y + uy * rg, body.z + uz * rg)
        if not q then break end
        rg = rg - q
      end
      local s = cl.sampleRel(w, ux * rg, uy * rg, uz * rg)
      if s then
        s.x, s.y, s.z = ux * rg, uy * rg, uz * rg
        if wet then s.riparian, s.inLake = cl.wetness(wet, s.x, s.y, s.z, rg) end
        -- Outside this patch's own cube cell: the neighbour grows it.
        local f2, g2, u2, v2 = project(px, py, pz, R0)
        if f2 ~= p.face or g2 ~= p.sgn or math.floor(u2 / p.P) ~= p.i or math.floor(v2 / p.P) ~= p.j then
          s.density = 0
        end
      end
      p.samples[r * rows + c + 1] = s
    end
  end
  p.sampled_t = time
  return true
end

-- The ground under a body-relative point, straight down the radial: a few
-- steps of `terrain.query` (a signed distance — cheap) rather than a raycast.
-- Rays over a terrain field are a march, and measured 0.5–15 ms apiece on a
-- loaded machine; the field asks this a lot (washes, the aim test, motes).
local function ground_under(body, px, py, pz)
  local l = len(px, py, pz)
  if l < 1e-6 then return px, py, pz end
  local ux, uy, uz = px / l, py / l, pz / l
  local r = l
  for _ = 1, 4 do
    local q = terrain.query(body.x + ux * r, body.y + uy * r, body.z + uz * r)
    if not q then break end
    r = r - q
    if math.abs(q) < 0.02 then break end
  end
  return ux * r, uy * r, uz * r, ux, uy, uz
end

-- …and along a given direction (a patch's -Y, which is how the engine drops a
-- prop onto the ground: straight down its patch's plane normal). Sphere-traced
-- with the same signed distance.
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

-- Distance from a body-relative point to a patch's square (in its plane).
local function patch_dist(p, rx, ry, rz)
  local dx, dy, dz = rx - p.cx, ry - p.cy, rz - p.cz
  local lx = dx * p.ex[1] + dy * p.ex[2] + dz * p.ex[3]
  local lz = dx * p.ez[1] + dy * p.ez[2] + dz * p.ez[3]
  local ox = math.max(0, math.abs(lx) - p.half)
  local oz = math.max(0, math.abs(lz) - p.half)
  return math.sqrt(ox * ox + oz * oz)
end

-- ── the field ───────────────────────────────────────────────────────────────

-- Props resident across every flora source: what `scatter.cost` says each
-- asks for (chunks × perChunk) times the share its density grid lets through.
local function refresh_count()
  local n, k = 0, 0
  for id, s in pairs(srcs) do
    k = k + 1
    if s.part ~= "bark" then
      local c = scatter.cost(id)
      n = n + ((c and c.props) or 0) * (s.fill or 1)
    end
  end
  count, sources = math.floor(n), k
end

-- Re-declare one species' sources on one patch (the late re-settle): same
-- seed, so every plant stands where it stood, and the cuts are re-applied.
local function redeclare(p, sp)
  drop_species(p, sp.id)
  local cl, fg = ref("climate"), ref("flora_gen")
  local w = cl and cl.worldOf(cur_body)
  if not (fg and w) then return end
  p.srcs[sp.id] = make_source(p, sp, fg, w)
end

-- Old saves' holes → ids: the plant nearest each saved position (in the
-- patch plane, where `near` measures) is the one that was cut. Run a tick
-- after the source is declared: a new source answers `near` in its parent's
-- frame only from its first drawn frame on.
local function convert_holes()
  for ck, c in pairs(convert) do
    local p = patches[c.pk]
    local id = p and p.srcs[c.spid]
    local body = cur_body and space.body(cur_body)
    if id and body and srcs[id] and time - (srcs[id].made or 0) > 0.05 then
      local list = cuts[ck]
      local n = 0
      for i = 1, #c.xz - 1, 2 do
        local x, z = c.xz[i], c.xz[i + 1]
        local q = vec3(body.x + p.cx + p.ex[1] * x + p.ez[1] * z, body.y + p.cy + p.ex[2] * x + p.ez[2] * z,
                       body.z + p.cz + p.ex[3] * x + p.ez[3] * z)
        local h = scatter.near(id, q, 0.35)[1]
        if h then
          scatter.remove(id, h.id)
          if p.bark[c.spid] then scatter.remove(p.bark[c.spid], h.id) end
          list[#list + 1] = { id = h.id, t = time }
          n = n + 1
        end
      end
      while #list > MAX_CUTS do table.remove(list, 1) end
      save.set(old_key(c.pk, c.spid), nil)
      save_cuts(c.pk, c.spid)
      convert[ck] = nil
      diag(string.format("converted %d old cut%s on %s", n, n == 1 and "" or "s", c.pk))
    elseif not p then
      convert[ck] = nil   -- the patch went; it converts when it is built again
      cuts[ck] = nil
    end
  end
end

-- Cuts older than `regrow` grow back: restored in the engine (both twins).
local function regrow()
  for ck, list in pairs(cuts) do
    local keep = {}
    local pk, spid = ck:match("^(.*)|(%d+)$")
    spid = tonumber(spid)
    local p = patches[pk]
    for _, c in ipairs(list) do
      if time - c.t < params.regrow then
        keep[#keep + 1] = c
      elseif p then
        if p.srcs[spid] then scatter.restore(p.srcs[spid], c.id) end
        if p.bark[spid] then scatter.restore(p.bark[spid], c.id) end
      end
    end
    if #keep ~= #list then
      cuts[ck] = keep
      save_cuts(pk, spid)
    end
  end
end

function update(node, dt)
  if params.enabled == 0 then
    if cur_body then clearAll(); cur_body = nil end
    diag("switched off (enabled = 0)")
    return
  end
  if time < next_t then return end
  next_t = time + params.interval
  if not (scatter and scatter.create) then diag("this engine has no scatter") return end

  local gm = ref("game_manager")
  if gm and gm.loading then diag("waiting — the world is still loading") return end
  local obs = observer()
  if not obs then diag("no observer: no astronaut and nothing being piloted") return end
  local bname = space.dominant(obs.x, obs.y, obs.z)
  local body = bname and space.body(bname)
  local cl, fg = ref("climate"), ref("flora_gen")
  if not (body and cl and fg) then
    diag(string.format("nothing to grow on: body=%s climate=%s flora_gen=%s",
      tostring(bname), tostring(cl ~= nil), tostring(fg ~= nil)))
    if cur_body then clearAll(); cur_body = nil end
    return
  end
  if bname ~= cur_body then
    clearAll()
    cur_body, bodyName = bname, bname
  end
  local w = cl.worldOf(bname)
  local species = w and fg.speciesFor(bname) or {}
  if not w or #species == 0 then
    if not w then
      diag(bname .. ": no world record — climate has nothing to describe it")
    else
      diag(string.format("%s grows nothing: atmo %.2f, sea %.0f (needs atmo > 0.15 or a sea)",
        bname, w.atmo or 0, w.sea or 0))
    end
    if next(patches) then clearAll() end
    return
  end
  local planet = find(bname)
  if not planet then diag(bname .. ": no scene node to anchor plants to") return end
  -- A hot reload frees this script's scatter sources (engine 0.117) but not
  -- the patch nodes it made: clear them once, or every patch would be made a
  -- second time under the same name.
  if not swept then
    swept = true
    for _, n in ipairs(findTagged("flora") or {}) do
      if n.valid and n.name:sub(1, 6) == "Flora " then n:destroy() end
    end
  end
  -- Load every mesh this world's flora uses in the BACKGROUND first. A scatter
  -- prototype the engine has not seen is imported on the frame it is first
  -- drawn, synchronously — a palette atlas is a megabyte of PNG — and twenty of
  -- them arriving together was a one-second hitch.
  if preload[bname] ~= "done" then
    if preload[bname] == nil then
      local list = {}
      for _, sp in ipairs(species) do
        for l = 0, (sp.lods or 1) - 1 do list[#list + 1] = fg.assetFor(sp, l) end
      end
      preload[bname] = "pending"
      preload_t = time
      if assets and assets.preload then
        assets.preload(list, function(failed)
          preload[bname] = "done"
          if failed and #failed > 0 then diag("could not load " .. tostring(failed[1])) end
        end)
      else
        preload[bname] = "done"
      end
    end
    if preload[bname] == "pending" and time - (preload_t or 0) < 30 then
      diag(bname .. ": loading plant meshes")
      return
    end
    preload[bname] = "done"
  end

  local rx, ry, rz = obs.x - body.x, obs.y - body.y, obs.z - body.z
  local rl = len(rx, ry, rz)
  if rl < 1e-3 then return end
  local R = w.radius or body.radius or 100
  if rl - R > params.alt_max then
    diag(string.format("%s: %.0f m up — nothing planted above %.0f m", bname, rl - R, params.alt_max))
    return
  end
  diag(string.format("%s: growing (%d species, %d patches, %d sources, %d props)",
    bname, #species, patchCount, sources, count))

  local maxFar = 0
  for _, sp in ipairs(species) do maxFar = math.max(maxFar, sp.far * params.reach) end
  local P = math.max(150, math.min(260, R * params.patch))

  -- Which patches are near: sample the tangent plane around the observer and
  -- project each sample onto the cube grid, so face seams take care of
  -- themselves.
  local ux, uy, uz = rx / rl, ry / rl, rz / rl
  local _, _, t1, _, t2 = frame_for(ux, uy, uz)
  local want = {}
  local reachR = maxFar + P * 0.5
  local steps = math.ceil(reachR / (P * 0.5))
  for a = -steps, steps do
    for b = -steps, steps do
      local ox, oz = a * P * 0.5, b * P * 0.5
      if ox * ox + oz * oz <= reachR * reachR then
        local qx = ux * R + t1[1] * ox + t2[1] * oz
        local qy = uy * R + t1[2] * ox + t2[2] * oz
        local qz = uz * R + t1[3] * ox + t2[3] * oz
        local face, sgn, u, v = project(qx, qy, qz, R)
        local i, j = math.floor(u / P), math.floor(v / P)
        want[pkey(face, sgn, i, j)] = { face, sgn, i, j }
      end
    end
  end

  -- Open patches: node first (one a tick: a node is a scene change), then its
  -- climate grid (one a tick), then its sources.
  local made = 0
  local order = {}
  for key, f in pairs(want) do
    if not patches[key] then
      local cx, cy, cz = unproject(f[1], f[2], (f[3] + 0.5) * P, (f[4] + 0.5) * P, R)
      order[#order + 1] = { key = key, f = f, d = len(cx * R - rx, cy * R - ry, cz * R - rz) }
    end
  end
  table.sort(order, function(a, b) return a.d < b.d end)
  for _, o in ipairs(order) do
    local key, f = o.key, o.f
    if made < 1 then
      local face, sgn, i, j = f[1], f[2], f[3], f[4]
      local cx, cy, cz = unproject(face, sgn, (i + 0.5) * P, (j + 0.5) * P, R)
      local yaw, pitch, roll, ex, ey, ez = patch_frame(face, cx, cy, cz)
      -- Half-size: the patch's cube cell, measured on the sphere, plus a little
      -- overlap so neighbouring planes leave no gap at the seam.
      local ax, ay, az = unproject(face, sgn, i * P, (j + 0.5) * P, R)
      local bx, by, bz = unproject(face, sgn, (i + 1) * P, (j + 0.5) * P, R)
      -- Generous: the density grid below fades each patch out past its own
      -- cube cell, so the overlap blends instead of doubling up.
      local half = len(ax - bx, ay - by, az - bz) * R * 0.5 * 1.15
      local p = { key = key, face = face, sgn = sgn, i = i, j = j, rows = math.floor(params.rows),
                  r0 = R, cx = cx * R, cy = cy * R, cz = cz * R, ex = ex, ey = ey, ez = ez,
                  half = half, srcs = {}, bark = {}, P = P, name = "Flora " .. bname .. " " .. key }
      patches[key] = p
      made = made + 1
      createNode(p.name, planet, function(n)
        n.x, n.y, n.z = p.cx, p.cy, p.cz
        n.pitch, n.roll, n.yaw = pitch, roll, yaw
        n.tags = { "flora" }
        p.node = n
      end)
    end
  end
  -- Once per session: the engine's own idea of a patch's axes must be the one
  -- this file computed, or every plant is planted in the wrong plane.
  if not frame_checked then
    for _, p in pairs(patches) do
      if p.node and p.node.valid and p.node.toWorld then
        local o = p.node:toWorld(vec3(0, 0, 0))
        local x = p.node:toWorld(vec3(1, 0, 0))
        local z = p.node:toWorld(vec3(0, 0, 1))
        local errx = len(x.x - o.x - p.ex[1], x.y - o.y - p.ex[2], x.z - o.z - p.ex[3])
        local errz = len(z.x - o.x - p.ez[1], z.y - o.y - p.ez[2], z.z - o.z - p.ez[3])
        frame_checked = true
        if errx > 0.02 or errz > 0.02 then
          log(string.format("flora: PATCH FRAME MISMATCH x %.3f z %.3f — plants will sit in the wrong plane", errx, errz))
        end
        break
      end
    end
  end
  -- A patch whose node went (the planet was rebuilt under it — a scene
  -- reload, or the system generator re-running) is dropped and made again:
  -- its sources would otherwise follow a parent that no longer exists.
  for key, p in pairs(patches) do
    if p.node and not p.node.valid then drop_patch(key) end
  end
  local sampled = 0
  local nearest = {}
  for key, p in pairs(patches) do
    p.dist = patch_dist(p, rx, ry, rz)
    nearest[#nearest + 1] = p
  end
  table.sort(nearest, function(a, b) return a.dist < b.dist end)
  for _, p in ipairs(nearest) do
    if p.node and not p.samples and sampled < 1 and p.dist < maxFar then
      sample_patch(p, body, w, cl)
      sampled = sampled + 1
    end
  end

  -- Sources: each species on each patch it can be seen on. Nearest patch and
  -- shortest reach first, so the ground at your feet fills before the horizon,
  -- and the prop budget is spent where it is seen.
  local built = 0
  refresh_count()
  for _, p in ipairs(nearest) do
    if p.samples then
      for _, sp in ipairs(species) do
        local far = sp.far * params.reach
        local id = p.srcs[sp.id]
        if id == nil and p.dist < far + 5 and built < 1 then
          if count < params.max_props then
            p.srcs[sp.id] = make_source(p, sp, fg, w)
            built = built + 1
            if p.srcs[sp.id] then refresh_count() end
          end
        elseif id and p.dist > far + 40 then
          drop_species(p, sp.id)
        end
      end
    end
  end
  -- Close patches nothing can see from here.
  local n = 0
  for key, p in pairs(patches) do
    if p.dist and p.dist > maxFar + 80 and not want[key] then drop_patch(key) else n = n + 1 end
  end
  patchCount = n
  convert_holes()
  regrow()
  if params.resettle > 0 then
    local done = 0
    for _, p in ipairs(nearest) do
      -- One source a tick: each re-declaration re-settles its chunks, and
      -- doing a whole patch at once was a burst of drops in one frame.
      if done < 1 and p.sampled_t and time - p.sampled_t > params.resettle then
        p.resettled = p.resettled or {}
        for _, sp in ipairs(species) do
          if done < 1 and p.srcs[sp.id] and not p.resettled[sp.id] then
            p.resettled[sp.id] = true
            done = done + 1
            redeclare(p, sp)
          end
        end
      end
    end
  end
  wash(body, rx, ry, rz, species, fg, rl - R, w)
end

-- ── ground wash ─────────────────────────────────────────────────────────────
-- A tinted decal under every grassy cell near you: the ground itself turns
-- the colour of the grass growing on it, which is what a field looks like from
-- a hundred metres up. Decals follow the terrain and are lit and fogged like
-- it; every one shares a picture, so the lot is one draw.
--
-- KEPT FAINT ON PURPOSE. The first version laid every cell at up to 85 %
-- opacity in the raw grass colour, and around a grassy colony that summed to
-- one solid green disc 260 m across with a hard rim — a "slab" visible from
-- orbit (seeds 19 and 6). Now: the colour is the grass blended halfway into
-- the world's own ground colour, opacity tops out near 40 % and falls to zero
-- over the outer 40 % of the range (re-faded as you move), and above
-- `tint_alt` every wash is lifted, so from the air nothing has an edge.


wash = function(body, rx, ry, rz, species, fg, alt, w)
  if params.tint == 0 or not (decals and decals.add) or (alt or 0) > params.tint_alt then
    if wash_n > 0 or next(washes) then
      for _, d in pairs(washes) do if d then decals.remove(d) end end
      washes, wash_n, wash_info = {}, 0, {}
    end
    return
  end
  local grass
  for _, sp in ipairs(species) do
    if sp.role == "carpet" then grass = sp end
  end
  if not grass then return end
  local S = params.tint_step
  local range = params.tint_range
  local live = {}
  local added = 0
  for _, p in pairs(patches) do
    if p.samples and (p.dist or 1e9) < range then
      local n = math.floor(2 * p.half / S)
      for i = 0, n - 1 do
        for j = 0, n - 1 do
          local lx = -p.half + (i + 0.5) * S
          local lz = -p.half + (j + 0.5) * S
          local px = p.cx + p.ex[1] * lx + p.ez[1] * lz
          local py = p.cy + p.ex[2] * lx + p.ez[2] * lz
          local pz = p.cz + p.ex[3] * lx + p.ez[3] * lz
          local d = len(px - rx, py - ry, pz - rz)
          local key = p.key .. ":" .. i .. "," .. j
          if d < range then
            live[key] = true
            if washes[key] == nil and added < 2 and wash_n < params.tint_max then
              local rows = p.rows
              local c = math.floor((lx / (2 * p.half) + 0.5) * (rows - 1) + 0.5)
              local r = math.floor((lz / (2 * p.half) + 0.5) * (rows - 1) + 0.5)
              local smp = p.samples[r * rows + c + 1]
              local dens = smp and fg.densityAt(grass, smp, smp.x, smp.y, smp.z, 1e9) or 0
              washes[key] = false
              if dens > 0.25 then
                local gx, gy, gz, nx, ny, nz = ground_under(body, px, py, pz)
                local hit = { x = body.x + gx, y = body.y + gy, z = body.z + gz, nx = nx, ny = ny, nz = nz }
                if hit then
                  local col = grass.leafColor or { 0.3, 0.5, 0.2 }
                  local gr = (w and type(w.ground) == "table") and w.ground or col
                  local base = math.min(0.4, 0.12 + dens * 0.28)
                  local fade = math.max(0, math.min(1, (range - d) / (range * 0.4)))
                  local ok, id = pcall(decals.add, {
                    texture = "textures/flora/turf.png",
                    pos = vec3(hit.x, hit.y, hit.z), normal = vec3(hit.nx, hit.ny, hit.nz),
                    size = S * 1.6,
                    color = { (col[1] + (gr[1] or col[1])) * 0.5, (col[2] + (gr[2] or col[2])) * 0.5,
                              (col[3] + (gr[3] or col[3])) * 0.5 },
                    alpha = base * fade,
                    rotation = ((i * 7 + j * 13) % 12) * 0.52,
                  })
                  if ok and id then
                    washes[key] = id
                    wash_n = wash_n + 1
                    wash_info[key] = { gx, gy, gz, base }
                  end
                end
              end
              added = added + 1
            end
          end
        end
      end
    end
  end
  for key, id in pairs(washes) do
    if not live[key] then
      if id then decals.remove(id); wash_n = wash_n - 1 end
      washes[key] = nil
      wash_info[key] = nil
    end
  end
  -- Re-fade by distance once a second, so the edge of the wash moves with you
  -- and never shows as a rim.
  if time >= wash_fade_t and decals.set then
    wash_fade_t = time + 1.0
    for key, id in pairs(washes) do
      local inf = id and wash_info[key]
      if inf then
        local d = len(inf[1] - rx, inf[2] - ry, inf[3] - rz)
        decals.set(id, { alpha = inf[4] * math.max(0, math.min(1, (range - d) / (range * 0.4))) })
      end
    end
  end
end

-- ── glow motes ──────────────────────────────────────────────────────────────
-- A few small emissive specks hovering round glowing plants near you. A pool of
-- nodes made once and moved, never spawned per plant: a scene change rebuilds
-- every script's copy of the scene (floptle/0409), a position write does not.

local function settle_point(id, h, p)
  local k = id .. ":" .. tostring(h.id)
  local s = settled[k]
  if s then return s end
  local body = space.body(cur_body)
  if not body then return nil end
  -- Where the engine put it: dropped from its rolled place along the patch's
  -- -Y (NOT the radial — at a patch's edge the two differ by metres).
  local hp = h.pos
  local ey = p.ey
  local gx, gy, gz = ground_along(body, hp.x - body.x, hp.y - body.y, hp.z - body.z, -ey[1], -ey[2], -ey[3])
  s = { gx, gy, gz }
  settled[k] = s
  return s
end

function lateUpdate(node, dt)
  if params.motes <= 0 or not cur_body or time < mote_t then return end
  mote_t = time + 0.5
  local obs = observer()
  local body = space.body(cur_body)
  local planet = find(cur_body)
  if not (obs and body and planet) then return end
  local glowing = {}
  for id, s in pairs(srcs) do
    if s.part ~= "bark" and s.sp.glow and s.sp.glow > 0 then glowing[#glowing + 1] = id end
  end
  if #glowing == 0 then
    for _, m in ipairs(motes) do if m.valid and m.visible then m.visible = false end end
    return
  end
  -- Grow the pool, two a tick.
  for _ = 1, 2 do
    if #motes < params.motes then
      local slot = #motes + 1
      motes[slot] = false
      createNode("Flora Mote", planet, function(n)
        n:setPrimitive("Sphere", { 1, 1, 1 })
        n.visible = false
        n.tags = { "flora" }
        motes[slot] = n
      end)
    end
  end
  local spots = {}
  for _, id in ipairs(glowing) do
    local s = srcs[id]
    local p = patches[s.patch]
    if p then
      local hits = scatter.near(id, vec3(obs.x, obs.y, obs.z), params.mote_range + 20)
      for k = 1, math.min(#hits, 6) do
        spots[#spots + 1] = { id = id, h = hits[k], sp = s.sp, p = p, d = hits[k].distance }
      end
    end
  end
  table.sort(spots, function(a, b) return a.d < b.d end)
  local used = 0
  for _, s in ipairs(spots) do
    if used >= #motes then break end
    local m = motes[used + 1]
    if m and m.valid then
      local g = settle_point(s.id, s.h, s.p)
      local l = len(g[1], g[2], g[3])
      local ux, uy, uz = g[1] / l, g[2] / l, g[3] / l
      -- Deterministic per plant: a height up its body, a little off its axis.
      local r = rng((s.h.id % 2147483647) + 31)
      local hh = (s.sp.height or 1) * (s.h.scale or 1) * r:range(0.35, 0.85)
      local ox, oy, oz = r:range(-0.4, 0.4), r:range(-0.4, 0.4), r:range(-0.4, 0.4)
      m.x, m.y, m.z = g[1] + ux * hh + ox, g[2] + uy * hh + oy, g[3] + uz * hh + oz
      local gc = s.sp.glowColor or { 0.7, 1, 0.8 }
      local sc = 0.06 + 0.05 * r:next()
      m.scale_x, m.scale_y, m.scale_z = sc, sc, sc
      m:setMaterial { color = { gc[1] * 0.5, gc[2] * 0.5, gc[3] * 0.5 }, emissive = gc,
                      emissiveStrength = s.sp.glow or 0.5 }
      if not m.visible then m.visible = true end
      used = used + 1
    end
  end
  for i = used + 1, #motes do
    local m = motes[i]
    if m and m.valid and m.visible then m.visible = false end
  end
end

-- ── harvest API (the tool belt calls these) ─────────────────────────────────

-- The plant someone is aiming at. Scattered plants have no colliders, so this
-- IS the aim test: the AIM RAY against each candidate's own axis (root to
-- tip), with `grab` a radius in metres — "does the line go through the tree".
-- The old cone (dot >= cone) stays as a floor so a "roughly ahead" sweep with
-- cone = -1 finds anything in reach.
function nearestPlant(x, y, z, dx, dy, dz, reach, cone, grab)
  reach = reach or 4.5
  cone = cone or 0.55
  grab = grab or 1.4
  local body = cur_body and space.body(cur_body)
  if not body then return nil end
  local best, bestScore = nil, -1
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and s.part ~= "bark" and patch_dist(p, rx, ry, rz) <= reach + 2 then
      -- Ask in the patch's plane: `near` measures to where a prop was ROLLED
      -- (on the plane), not where it settled on the ground below it.
      local dx_, dy_, dz_ = rx - p.cx, ry - p.cy, rz - p.cz
      local lx = dx_ * p.ex[1] + dy_ * p.ex[2] + dz_ * p.ex[3]
      local lz = dx_ * p.ez[1] + dy_ * p.ez[2] + dz_ * p.ez[3]
      local qx = body.x + p.cx + p.ex[1] * lx + p.ez[1] * lz
      local qy = body.y + p.cy + p.ex[2] * lx + p.ez[2] * lz
      local qz = body.z + p.cz + p.ex[3] * lx + p.ez[3] * lz
      local hits = scatter.near(id, vec3(qx, qy, qz), reach + 1.0)
      for k = 1, math.min(#hits, 24) do
        local h = hits[k]
        local g = settle_point(id, h, p)
        local hdx, hdy, hdz = h.pos.x - body.x - p.cx, h.pos.y - body.y - p.cy, h.pos.z - body.z - p.cz
        local hl = { x = hdx * p.ex[1] + hdy * p.ex[2] + hdz * p.ex[3],
                     z = hdx * p.ez[1] + hdy * p.ez[2] + hdz * p.ez[3] }
        local wx, wy, wz = body.x + g[1], body.y + g[2], body.z + g[3]
        local ex, ey, ez = wx - x, wy - y, wz - z
        local d = len(ex, ey, ez)
        if d > 0.01 and d <= reach then
          local dot = (ex * dx + ey * dy + ez * dz) / d
          local gl = len(g[1], g[2], g[3])
          local ux, uy, uz = g[1] / gl, g[2] / gl, g[3] / gl
          local hgt = math.max(0.4, (s.sp.height or 1.0) * (h.scale or 1))
          local near_, nx, ny, nz = math.huge, wx, wy, wz
          for i = 0, 4 do
            local f = hgt * (i / 4)
            local px, py, pz = wx + ux * f, wy + uy * f, wz + uz * f
            -- Distance from this point on the trunk to the aim ray. Samples
            -- BEHIND the origin are skipped, not clamped: clamping makes
            -- "distance to the ray" mean "distance to the player".
            local t = (px - x) * dx + (py - y) * dy + (pz - z) * dz
            if t > 0 then
              local qd = len(px - (x + dx * t), py - (y + dy * t), pz - (z + dz * t))
              if qd < near_ then near_, nx, ny, nz = qd, px, py, pz end
            end
          end
          if (near_ <= grab and dot > 0) or dot >= cone then
            local score = (grab - math.min(near_, grab)) * 2.0 - d / reach
            if score > bestScore then
              bestScore = score
              best = { pid = id .. ":" .. tostring(h.id), dist = d, x = wx, y = wy, z = wz,
                       ax = nx, ay = ny, az = nz, height = hgt, ux = ux, uy = uy, uz = uz,
                       rec = { sp = s.sp, src = id, inst = h.id, patch = s.patch, lx = hl.x, lz = hl.z,
                               seedn = h.id % 2147483647, rx = g[1], ry = g[2], rz = g[3] } }
            end
          end
        end
      end
    end
  end
  return best
end

-- Cut it down: yields go to `cid`, the instance is removed for good (until it
-- regrows), and the loss is saved as an instance id. Returns the list of
-- {mat, n} actually taken and how many units were dropped for want of room.
function harvest(hitrec, cid)
  local rec = hitrec and hitrec.rec
  if not (rec and srcs[rec.src]) then return {}, 0 end
  local fg = ref("flora_gen")
  local inv = ref("inventory")
  local got, dropped = {}, 0
  for _, y in ipairs(fg and fg.harvestYield(rec.sp, rec.seedn) or {}) do
    local took = inv and inv.add(cid or "astro", y.mat, y.n) or 0
    if took > 0 then got[#got + 1] = { mat = y.mat, n = took } end
    dropped = dropped + (y.n - took)
  end
  -- One removal by id, in the crown's source and the trunk's twin: the
  -- engine re-resolves just that chunk, and every other plant stays put.
  scatter.remove(rec.src, rec.inst)
  local p = patches[rec.patch]
  if p then
    if p.bark[rec.sp.id] then scatter.remove(p.bark[rec.sp.id], rec.inst) end
    local list = cuts_of(rec.patch, rec.sp.id)
    list[#list + 1] = { id = rec.inst, t = time }
    while #list > MAX_CUTS do
      local old = table.remove(list, 1)
      scatter.restore(rec.src, old.id)
      if p.bark[rec.sp.id] then scatter.restore(p.bark[rec.sp.id], old.id) end
    end
    save_cuts(rec.patch, rec.sp.id)
  end
  settled[rec.src .. ":" .. tostring(rec.inst)] = nil
  return got, dropped
end

-- What's growing around here — the survey readout at a base or a landing site.
function surveyLines(x, y, z, radius)
  radius = radius or 40
  local body = cur_body and space.body(cur_body)
  if not body then return {} end
  local tally, order = {}, {}
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and s.part ~= "bark" and patch_dist(p, x - body.x, y - body.y, z - body.z) <= radius then
      local n = #scatter.near(id, vec3(x, y, z), radius)
      if n > 0 then
        local nm = s.sp.name
        if not tally[nm] then tally[nm] = 0; order[#order + 1] = nm end
        tally[nm] = tally[nm] + n
      end
    end
  end
  table.sort(order)
  local out = {}
  for _, nm in ipairs(order) do
    out[#out + 1] = string.format("%2d × %s", tally[nm], nm)
  end
  return out
end
