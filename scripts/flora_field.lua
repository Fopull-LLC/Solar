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
  -- Measured on engine 0.117.0-rc3 (card 0424, Kail, walking at 6 m/s): a
  -- resident prop costs ~0.15 µs a frame (2,900 flora + rocks: scatter 0.43 ms
  -- mean), and arriving chunks are rolled and settled inside a 1 ms slice, so
  -- this is a look budget more than a frame budget. 6,000 flora plus a
  -- world's ~1,400 rocks is about 1.1 ms. At reach 1 no world tried so far
  -- reaches it (Kail peaks near 2,100); it caps a dense world, and `reach`
  -- above 1 (4,400 flora at 1.5 cost 1.4–2.2 ms under load).
  --@range 1000 18000
  max_props = 6000,
  -- Multiplies every species' reach. Turn it down if the surface ever hitches.
  --@range 0.4 1.5
  reach = 1.0,
  --@header Touch
  -- Plants bend away as the crew walks through them; trunks and rocks stop
  -- the crew (see "touch"). 0 = off.
  touch = 1,
  -- How near (m) a plant starts to lean, and how far it leans (radians).
  --@range 0.4 3 --@units m
  touch_r = 1.1,
  --@range 0 1.2 --@units rad
  touch_bend = 0.75,
  -- Most plants bent at once.
  --@range 0 40
  touch_cap = 14,
  -- Trunks and rocks stop the crew (planet_walker reads `obstacles`), and
  -- how far round the crew they are gathered.
  touch_bump = 1,
  --@range 3 30 --@units m
  touch_reach = 9.0,

  -- Dissolve every layer out at the edge of its reach instead of cutting it
  -- (flora_gen.fadeBands). 0 = the old hard edge.
  fade_out = 1,

  --@header Harvest
  regrow = 900.0,   -- seconds before a cut plant grows back
  -- Seconds after a patch is planted at which its sources are re-declared
  -- once, so every prop is dropped again onto ground that has finished
  -- streaming in at full detail (0 = never). Off since engine 0.117.0-rc3: a
  -- settle ray meshes the collision cells it reaches (card 0452), so props
  -- land on full-detail ground the first time, and on Kail a re-settle moved
  -- nothing on screen (frames before and after differ no more than two
  -- frames of a still camera do). It was also the plants' flicker: every
  -- stand near the base blinked out once while its new source settled in.
  resettle = 0.0,
  -- Seconds the old source of a re-settled stand keeps drawing beside the new
  -- one. The new source's props arrive a few a frame (the engine settles them
  -- inside a 1 ms slice), so dropping the old one first blinked the whole
  -- stand out for a few frames: the "flicker" on plants near the base.
  resettle_hold = 2.0,

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

  --@header Rare plants
  -- The handful of rare plants per world (climate.rareScan finds their
  -- places, flora_gen.rareFor their look). 0 = off.
  rare = 1,
  -- Milliseconds a frame the rare-niche scan may take (once per world per
  -- save, the first seconds after landing; the answer is kept in the save).
  --@range 0.2 8 --@units ms
  rare_ms = 1.0,
  -- Terrain reads a frame instead, where the clock is not available.
  --@range 200 20000
  rare_budget = 800,
  -- Within this range a rare plant lights the ground round it (the two
  -- nearest; scene lights are a shared budget of sixteen).
  --@range 10 150 --@units m
  rare_light = 70.0,
  -- The beam over each rare plant (0 = none, 1 = full strength), how far it
  -- shows before the world is surveyed (or the plant spotted), and after.
  --@range 0 1.5
  rare_beam = 1.0,
  --@range 50 2000 --@units m
  rare_beam_near = 450.0,
  --@range 200 8000 --@units m
  rare_beam_far = 4000.0,
  -- Walk this close to a rare plant and it is spotted: its beam stays lit.
  --@range 20 600 --@units m
  rare_spot = 220.0,
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
local wash                -- defined below update (ground wash)
local preload_t = 0
local swept = false
local retiring = {} -- { id, pk, spid, t }: re-settled stands' old sources, still drawn until t

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

-- Destroy retiring sources whose hold is over (or all of a patch's, or all).
local function sweep_retiring(pk, all)
  local keep = {}
  for _, r in ipairs(retiring) do
    if all or r.pk == pk or time >= r.t then
      if scatter and scatter.destroy then scatter.destroy(r.id) end
    else
      keep[#keep + 1] = r
    end
  end
  retiring = keep
end

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
  sweep_retiring(key)
  if p.node and p.node.valid then p.node:destroy() end
  patches[key] = nil
end

function clearAll()
  if touchClear then touchClear() end
  sweep_retiring(nil, true)
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

-- THE BASE'S GROUND, PLANT BY PLANT. The density grid is ~35 m a cell, far
-- too coarse to keep a tree out of a building, so once a source near the base
-- is declared each of its props is checked against the base's layout
-- (base_facilities' frame, lots, strips, runway and taxiway, read from the
-- save, so an old save's base is cleared too): nothing stands on the paving or
-- a lot, a margin round them grows with the plant's height, and past it the
-- stand thins out over FADE metres (a deterministic share per prop id), so the
-- edge of the clearing looks grown, not cut. Trees and bushes stay out of the
-- fenced compound altogether. Placement only; the ground is untouched.
-- (homeworld_spec.md, Footprint: every building lot +6 m clear; nothing over
-- ~1 m tall inside the footprint radius; low grass between the strips.)
local BASE_CLEAR = { fade = 14.0, margin = 2.0, lot = 6.0, perM = 0.8, tall = 1.0, reach = 40.0 }
local base_l = { key = nil }

local function base_layout()
  local bf = ref("base_facilities")
  if not (bf and bf.frameOf and bf.uvOf and bf.FACILITIES) then return nil end
  if save.get("base.body") ~= cur_body then return nil end
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if type(bx) ~= "number" or type(by) ~= "number" or type(bz) ~= "number" then return nil end
  local R = save.get("base.r") or len(bx, by, bz)
  local hd = save.get("base.heading") or 0
  local key = table.concat({ cur_body, bx, by, bz, hd, R, tostring(save.get("base.runway")) }, ",")
  if base_l.key ~= key then
    local ok, F = pcall(bf.frameOf, { x = bx, y = by, z = bz }, hd, R)
    if not ok then return nil end
    base_l = { key = key, F = F, bf = bf, x = bx, y = by, z = bz,
               r = (bf.FOOTPRINT_RADIUS or 175) + BASE_CLEAR.reach }
  end
  return base_l
end

-- Distance along the ground from the nearest built thing (negative inside
-- one), and from the fenced compound.
local function base_clearance(L, rx, ry, rz)
  local bf = L.bf
  local u, v = bf.uvOf(L.F, { x = rx, y = ry, z = rz })
  local best = math.huge
  local function rect(cu, cv, hw, hd)
    local du, dv = math.abs(u - cu) - hw, math.abs(v - cv) - hd
    return math.sqrt(math.max(du, 0) ^ 2 + math.max(dv, 0) ^ 2) + math.min(math.max(du, dv), 0)
  end
  local function seg(u0, v0, u1, v1, half)
    local du, dv = u1 - u0, v1 - v0
    local L2 = du * du + dv * dv
    local t = L2 > 0 and math.max(0, math.min(1, ((u - u0) * du + (v - v0) * dv) / L2)) or 0
    return math.sqrt((u0 + du * t - u) ^ 2 + (v0 + dv * t - v) ^ 2) - half
  end
  -- A building's lot counts as BASE_CLEAR.lot bigger than it is.
  for _, f in ipairs(bf.FACILITIES or {}) do
    local w, d = f.lot[1] / 2, f.lot[2] / 2
    if f.face == "E" or f.face == "W" then w, d = d, w end
    best = math.min(best, rect(f.u, f.v, w, d) - BASE_CLEAR.lot)
  end
  for _, st in ipairs(bf.STRIPS or {}) do best = math.min(best, seg(st[2], st[3], st[4], st[5], st[6])) end
  local RW, TW = bf.RUNWAY, bf.TAXIWAY
  if RW and save.get("base.runway") ~= false then
    best = math.min(best, seg(RW.u0 - (RW.blast or 0), RW.v, RW.u1 + (RW.blast or 0), RW.v, RW.half + (RW.shoulder or 0)))
  end
  if TW then best = math.min(best, seg(TW.u, TW.v0, TW.u, TW.v1, TW.half)) end
  local fence = math.huge
  local FN = bf.FENCE
  if FN then fence = rect((FN.u0 + FN.u1) / 2, (FN.v0 + FN.v1) / 2, (FN.u1 - FN.u0) / 2, (FN.v1 - FN.v0) / 2) end
  return best, fence
end

-- How much of a stand of plants `h` metres tall keeps growing here, 0..1.
-- `foot`: how far the plant's leaves reach from its root (flora_gen.footprint
-- × its scale). A LOW plant (grass, ground cover) is kept that far plus a hand
-- off every strip and lot, and comes back in over CARPET_FADE metres — a clean
-- verge, not the ragged bites the 14 m thinning took out of the carpet at the
-- paving's edge.
local CARPET_FADE = 2.5
function baseKeep(rx, ry, rz, h, foot)
  local L = base_layout()
  if not L then return 1 end
  if len(rx - L.x, ry - L.y, rz - L.z) > L.r + 20 then return 1 end
  local clr, fence = base_clearance(L, rx, ry, rz)
  local C = BASE_CLEAR
  local margin = C.margin + math.min(h or 1, 14) * C.perM
  if (h or 1) <= C.tall and foot then
    return math.max(0, math.min(1, (clr - foot - 0.4) / CARPET_FADE))
  end
  if foot then margin = math.max(margin, foot + 0.4) end
  local keep = math.max(0, math.min(1, (clr - margin) / C.fade))
  if (h or 1) > C.tall then
    -- Trees and bushes: out of the fenced compound, and out of the whole
    -- footprint, thinning back in past its rim.
    keep = math.min(keep, math.max(0, math.min(1, (fence - margin) / C.fade)))
    local rim = (L.bf.FOOTPRINT_RADIUS or 175) + 4
    local d = len(rx - L.x, ry - L.y, rz - L.z)
    keep = math.min(keep, math.max(0, math.min(1, (d - rim) / C.fade)))
  end
  return keep
end

-- Take a freshly declared source's props off the base's ground (see above).
local function clear_base(id, p, sp)
  local L = base_layout()
  local body = cur_body and space.body(cur_body)
  if not (L and body and scatter.near) then return 0 end
  -- Only a patch that reaches the base.
  if len(p.cx - L.x, p.cy - L.y, p.cz - L.z) > p.half * 1.5 + L.r then return 0 end
  local hits = scatter.near(id, vec3(body.x + L.x, body.y + L.y, body.z + L.z), L.r) or {}
  local h = (sp.height or 1) * (sp.scaleMax or 1)
  -- Grass and ground cover are the verge, however tall a blade: a clean edge.
  if sp.role == "carpet" or sp.kind == "grass" or sp.kind == "moss" then h = math.min(h, BASE_CLEAR.tall) end
  local fg = ref("flora_gen")
  local foot0 = fg and fg.footprint and fg.footprint(sp) or nil
  local n = 0
  for _, it in ipairs(hits) do
    local px, py, pz = it.pos.x - body.x, it.pos.y - body.y, it.pos.z - body.z
    local foot = foot0 and foot0 * (it.scale or 1)
    -- A prop not yet dropped answers on its patch's PLANE, which off the
    -- patch's centre stands metres over the ground; the engine drops it along
    -- the patch's -Y. Near an edge, where a metre decides it, drop it here
    -- the same way (a few signed-distance steps) before judging it.
    if not it.settled and foot then
      local clr = select(1, base_clearance(L, px, py, pz))
      if clr < foot + 0.4 + CARPET_FADE + 4 then
        local t = 0
        for _ = 1, 8 do
          local q = terrain.query(body.x + px - p.ey[1] * t, body.y + py - p.ey[2] * t, body.z + pz - p.ey[3] * t)
          if not q then break end
          t = t + q
          if math.abs(q) < 0.03 then break end
        end
        px, py, pz = px - p.ey[1] * t, py - p.ey[2] * t, pz - p.ey[3] * t
      end
    end
    local keep = baseKeep(px, py, pz, h, foot)
    if keep < 1 then
      local roll = (((it.id % 2147483647) * 48271 + 11) % 2147483647) / 2147483647
      if roll >= keep then
        scatter.remove(id, it.id)
        if p.bark[sp.id] then scatter.remove(p.bark[sp.id], it.id) end
        n = n + 1
      end
    end
  end
  return n
end

-- Sources declared before the base was sited (a new save's first patches):
-- cleared once the layout appears, or when it changes.
local function base_sweep()
  local L = base_layout()
  if not L or L.swept then return end
  L.swept = true
  local n = 0
  for id, sr in pairs(srcs) do
    local p = patches[sr.patch]
    if p and sr.part ~= "bark" and sr.sp and p.srcs[sr.sp.id] == id then n = n + clear_base(id, p, sr.sp) end
  end
  if n > 0 then diag(string.format("base sited: %d plants kept off its ground", n)) end
end

-- What stands on the base's ground now (probes, the debug console): props of
-- every resident source within its reach, by how clear the spot should be.
-- → { total, onBuilt (clearance < 0), inMargin (keep = 0), fading (0 < keep < 1) }
function baseSurvey()
  local L = base_layout()
  local body = cur_body and space.body(cur_body)
  -- overPaving: settled props whose leaves (flora_gen.footprint × scale)
  -- reach over a strip or lot.
  local out = { total = 0, onBuilt = 0, inMargin = 0, fading = 0, overPaving = 0, settled = 0 }
  if not (L and body and scatter.near) then return out end
  local fg = ref("flora_gen")
  for id, sr in pairs(srcs) do
    if sr.part ~= "bark" and sr.sp then
      local h = (sr.sp.height or 1) * (sr.sp.scaleMax or 1)
      local foot0 = fg and fg.footprint and fg.footprint(sr.sp) or 0.6
      for _, it in ipairs(scatter.near(id, vec3(body.x + L.x, body.y + L.y, body.z + L.z), L.r) or {}) do
        local px, py, pz = it.pos.x - body.x, it.pos.y - body.y, it.pos.z - body.z
        out.total = out.total + 1
        local clr = base_clearance(L, px, py, pz)
        local keep = baseKeep(px, py, pz, h)
        if it.settled then
          out.settled = out.settled + 1
          if clr < foot0 * (it.scale or 1) then out.overPaving = out.overPaving + 1 end
        end
        if clr < 0 then out.onBuilt = out.onBuilt + 1 end
        if keep <= 0 then out.inMargin = out.inMargin + 1 elseif keep < 1 then out.fading = out.fading + 1 end
      end
    end
  end
  return out
end

local function make_source(p, sp, fg, w)
  local rows = p.rows
  local data, any = {}, false
  local sum = 0
  for i = 1, rows * rows do
    local s = p.samples[i]
    local d = s and fg.densityAt(sp, s, s.x, s.y, s.z, w.radius) or 0
    if d > 0 and kept_clear(s.x, s.y, s.z) then d = 0 end
    data[i] = d
    sum = sum + d
    if d > 0.01 then any = true end
  end
  if not any then return false end
  local far = sp.far * params.reach
  local seed = hash(w.seed or 1, p.face, p.sgn + 2, p.i + 50000, p.j + 50000, sp.id)
  local list = cuts_of(p.key, sp.id)
  local function declare(part)
    -- Every band cross-dissolves into the next, and the last into nothing
    -- (flora_gen.fadeBands): nothing pops in or out at the edge of its reach.
    local bands = {}
    for l = 0, (sp.lods or 1) - 1 do
      bands[#bands + 1] = { asset = fg.assetFor(sp, l, part), at = sp.lodAt[l + 1] or 1.0 }
    end
    local lod, fade = fg.fadeBands(bands, far, params.fade_out > 0 and fg.emptyAsset and fg.emptyAsset() or nil)
    local opts = {
      seed = seed,
      center = vec3(0, 0, 0), halfX = p.half, halfZ = p.half,
      perChunk = sp.per, chunk = sp.chunk, align = sp.upright and "world" or "surface",
      scaleMin = sp.scaleMin, scaleMax = sp.scaleMax,
      fade = fade, lod = lod,
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
    srcs[id] = { patch = p.key, sp = sp, fill = sum / (rows * rows), part = part, made = time, tint = opts.tint }
    return id
  end
  local id = declare(nil)
  if not id then return false end
  if sp.twin then p.bark[sp.id] = declare("bark") or nil end
  local nb = clear_base(id, p, sp)
  if nb > 0 then diag(string.format("kept %d %s off the base on %s", nb, sp.name or "plants", p.key)) end
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
-- The old sources keep drawing for `resettle_hold` seconds while the new
-- ones' props settle in, then go (sweep_retiring): drop-then-declare left the
-- stand missing for the frames its props took to arrive.
local function redeclare(p, sp)
  for _, id in ipairs({ p.srcs[sp.id], p.bark[sp.id] }) do
    if id then
      retiring[#retiring + 1] = { id = id, pk = p.key, spid = sp.id, t = time + params.resettle_hold }
      srcs[id] = nil
    end
  end
  p.srcs[sp.id], p.bark[sp.id] = nil, nil
  local cl, fg = ref("climate"), ref("flora_gen")
  local w = cl and cl.worldOf(cur_body)
  if not (fg and w) then return end
  p.srcs[sp.id] = make_source(p, sp, fg, w)
end

-- Old saves' holes → ids: the plant nearest each saved position (in the
-- patch plane, where `near` measures) is the one that was cut. Runs as soon
-- as the source is declared: since engine 0.117.0-rc3 a parented source
-- answers `near` in its parent's frame from the frame it is created.
local function convert_holes()
  for ck, c in pairs(convert) do
    local p = patches[c.pk]
    local id = p and p.srcs[c.spid]
    local body = cur_body and space.body(cur_body)
    if id and body and srcs[id] then
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

local rare_tick   -- defined below (rare plants)

-- ── touch: plants that bend, trunks and rocks that stop you ─────────────────
--
-- Scattered props are instanced draws with no node and no collider, and the
-- engine's sway is one wind for the whole field (a single uniform: weather's
-- wind at the camera), so neither "the grass parts round my legs" nor "I
-- bumped into that tree" could happen. Both are done here, near the crew only:
--
-- BENDING. The grass, ferns, reeds and bushes within `touch_r` of the crew are
-- SWAPPED for nodes wearing the same model, look and place (scatter.near gives
-- each one's ground point, up, spin and scale), the instance is taken out
-- (scatter.remove — a cheap retain on its chunk, not a re-settle), and the
-- node is tipped away from the crew about its root, eased in as you push
-- through and springing back after. Once upright and clear it is handed back
-- (scatter.restore) and the node goes. At most `touch_cap` at once. The
-- removals are never saved: save_cuts falls back to its own list whenever the
-- engine's removed list holds more than the cuts.
--
-- BUMPING. The tree trunks (a tree's bark source) and rocks
-- (mineral_field.rocksNear) within `touch_reach` of the crew are published as
-- `obstacles`, a few times a second, and planet_walker keeps the crew out of
-- them: you walk into a trunk and stop, and slide round a boulder.

local BEND_KIND = { grass = true, fern = true, reed = true, bush = true, shrub = true, moss = true }
local touch = { bent = {}, n = 0, t = 0, ct = 0 }
touchStats = { bent = 0, obstacles = 0, trunks = 0, rocks = 0 }

local function touch_release(key, b)
  if b.restored == nil and srcs[b.src] then pcall(scatter.restore, b.src, b.inst) end
  if b.node and b.node.valid then b.node:destroy() end
  touch.bent[key] = nil
  touch.n = touch.n - 1
end

function touchClear()
  for key, b in pairs(touch.bent) do touch_release(key, b) end
  touch.bent, touch.n = {}, 0
  obstacles = {}
end

-- New bends: what is within reach of the crew's feet.
local function touch_find(astro, body, fg, planet)
  local ax, ay, az = astro.x, astro.y, astro.z
  local rx, ry, rz = ax - body.x, ay - body.y, az - body.z
  local reach = params.touch_r + 1.2
  for id, s in pairs(srcs) do
    local sp = s.sp
    if s.part ~= "bark" and sp and BEND_KIND[sp.kind] and touch.n < params.touch_cap then
      local p = patches[s.patch]
      if p and patch_dist(p, rx, ry, rz) <= reach then
        for _, h in ipairs(scatter.near(id, vec3(ax, ay, az), reach) or {}) do
          local key = id .. ":" .. tostring(h.id)
          if not touch.bent[key] and touch.n < params.touch_cap and h.settled ~= false then
            local hx, hy, hz = h.pos.x - body.x, h.pos.y - body.y, h.pos.z - body.z
            local u = h.up or vec3(p.ey[1], p.ey[2], p.ey[3])
            local yaw = h.yaw or 0
            -- The instance's facing: spin about the patch's +Y, then tilt to
            -- its up (scatter's own order); setUp keeps the forward as near
            -- as the up allows.
            local fx = -math.sin(yaw) * p.ex[1] - math.cos(yaw) * p.ez[1]
            local fy = -math.sin(yaw) * p.ex[2] - math.cos(yaw) * p.ez[2]
            local fz = -math.sin(yaw) * p.ex[3] - math.cos(yaw) * p.ez[3]
            local b = { src = id, inst = h.id, x = hx, y = hy, z = hz, ux = u.x, uy = u.y, uz = u.z,
                        fx = fx, fy = fy, fz = fz, w = 0, born = time, sp = sp }
            touch.bent[key] = b
            touch.n = touch.n + 1
            local t = s.tint or sp.tint or { 1, 1, 1 }
            local k = 0.85 + 0.3 * (h.param or 0.5)
            createNode("Flora Bend", planet, function(n)
              n.model = fg.modelFor(sp, 0)
              n.x, n.y, n.z = hx, hy, hz
              local sc = h.scale or 1
              n.scale_x, n.scale_y, n.scale_z = sc, sc, sc
              if n.setUp then n:setUp(vec3(u.x, u.y, u.z), vec3(fx, fy, fz)) end
              local col = { t[1] * k, t[2] * k, t[3] * k }
              if tostring(fg.assetFor(sp, 0)):sub(-11) == ".prefab.ron" then
                -- A swaying plant's prefab is one leaf material (tools/gen_flora_prefabs.py).
                n:setMaterial { texture = "textures/flora/foliage_l0.png", normalMap = "textures/flora/foliage_n.png",
                                color = col, sway = 0.5, backlight = 0.5 }
              else
                -- A model drawn as it is: its own parts, each shaded by the source's tint.
                local ok, mats = pcall(n.materials, n)
                for _, m in ipairs(ok and type(mats) == "table" and mats or {}) do
                  local ok2, mm = pcall(n.material, n, m.material or m.object)
                  if ok2 and mm then mm.color = col end
                end
              end
              n.tags = { "flora" }
              b.node = n
            end)
          end
        end
      end
    end
  end
end

-- The bends this frame: lean away from the crew, spring back, hand back.
local function touch_drive(astro, body, dt)
  local rx, ry, rz = astro.x - body.x, astro.y - body.y, astro.z - body.z
  for key, b in pairs(touch.bent) do
    if not srcs[b.src] then
      if b.node and b.node.valid then b.node:destroy() end
      touch.bent[key] = nil
      touch.n = touch.n - 1
    elseif b.node and b.node.valid then
      -- The node is drawing: take the instance out (one frame of both is
      -- invisible; one frame of neither is a blink).
      if not b.removed then b.removed = true; scatter.remove(b.src, b.inst) end
      local dx, dy, dz = b.x - rx, b.y - ry, b.z - rz
      local du = dx * b.ux + dy * b.uy + dz * b.uz
      dx, dy, dz = dx - b.ux * du, dy - b.uy * du, dz - b.uz * du
      local d = len(dx, dy, dz)
      local want = math.max(0, math.min(1, 1 - (d - 0.25) / params.touch_r))
      if math.abs(du) > 2.5 then want = 0 end
      if d > 1e-3 then b.ax, b.ay, b.az = dx / d, dy / d, dz / d end
      local rate = want > b.w and 9.0 or 2.2
      b.w = b.w + (want - b.w) * (1 - math.exp(-rate * dt))
      if b.ax then
        local tilt = math.tan(b.w * params.touch_bend)
        local nx, ny, nz = b.ux + b.ax * tilt, b.uy + b.ay * tilt, b.uz + b.az * tilt
        local l = len(nx, ny, nz)
        if math.abs(b.w - (b.w_set or -1)) > 0.004 then
          b.w_set = b.w
          b.node:setUp(vec3(nx / l, ny / l, nz / l), vec3(b.fx, b.fy, b.fz))
        end
      end
      if want <= 0 and b.w < 0.02 and time - b.born > 0.4 then
        -- Upright and clear: the instance back, the node a moment later.
        if b.restored == nil then
          b.restored = time
          pcall(scatter.restore, b.src, b.inst)
        elseif time - b.restored > 0.25 then
          b.node:destroy()
          touch.bent[key] = nil
          touch.n = touch.n - 1
        end
      elseif b.restored then
        -- Walked back into it before it went: take it out again.
        b.restored = nil
        scatter.remove(b.src, b.inst)
      end
    elseif time - b.born > 3.0 then
      touch.bent[key] = nil       -- the node never came
      touch.n = touch.n - 1
    end
  end
end

-- The trunks and rocks round the crew, for planet_walker to bump into:
-- `obstacles` = { { x, y, z (body-relative ground point / rock centre), ux,
-- uy, uz (its up), r (radius), h (a trunk's height; 0 for a rock), key } },
-- refreshed a few times a second. (Not engine colliders: a Static or
-- Kinematic body spawned under a planet node and moved by script did not stop
-- the crew on rc6 — see the report — so the walker keeps the crew out of
-- them itself, the way it already owns its own up axis.)
obstacles = {}
obstaclesBody = nil
local function touch_obstacles(astro, body)
  local want = {}
  local ax, ay, az = astro.x, astro.y, astro.z
  local rx, ry, rz = ax - body.x, ay - body.y, az - body.z
  local R = params.touch_reach
  local nt, nr = 0, 0
  for id, s in pairs(srcs) do
    if s.part == "bark" then
      local p = patches[s.patch]
      if p and patch_dist(p, rx, ry, rz) <= R + 2 then
        for _, h in ipairs(scatter.near(id, vec3(ax, ay, az), R) or {}) do
          if h.settled ~= false then
            local sc = h.scale or 1
            local u = h.up or vec3(p.ey[1], p.ey[2], p.ey[3])
            want[#want + 1] = { key = "t" .. id .. ":" .. tostring(h.id), x = h.pos.x - body.x, y = h.pos.y - body.y,
                                z = h.pos.z - body.z, ux = u.x, uy = u.y, uz = u.z,
                                r = math.max(0.15, math.min(0.6, 0.28 * sc)), h = 3.2 * sc }
            nt = nt + 1
          end
        end
      end
    end
  end
  local mf = ref("mineral_field")
  if mf and mf.rocksNear then
    for _, rk in ipairs(mf.rocksNear(ax, ay, az, R)) do
      local x, y, z = rk.x - body.x, rk.y - body.y, rk.z - body.z
      local l = len(x, y, z)
      want[#want + 1] = { key = rk.key, x = x, y = y, z = z, ux = x / l, uy = y / l, uz = z / l, r = rk.r, h = 0 }
      nr = nr + 1
    end
  end
  obstacles, obstaclesBody = want, cur_body
  touchStats.obstacles, touchStats.trunks, touchStats.rocks = #want, nt, nr
end

local function touch_tick(dt)
  local pw = ref("planet_walker")
  local astro = find("Astronaut")
  local body = cur_body and space.body(cur_body)
  if not (pw and pw.onFoot and astro and body) then
    if touch.n > 0 then for key, b in pairs(touch.bent) do touch_release(key, b) end end
    return
  end
  touch_drive(astro, body, dt)
  touch.t = touch.t - dt
  if touch.t <= 0 then
    touch.t = 0.1
    local fg = ref("flora_gen")
    local planet = find(cur_body)
    if fg and planet then touch_find(astro, body, fg, planet) end
  end
  touch.ct = touch.ct - dt
  if touch.ct <= 0 and params.touch_bump > 0 then
    touch.ct = 0.2
    touch_obstacles(astro, body)
  end
  touchStats.bent = touch.n
end

function update(node, dt)
  if params.rare > 0 then rare_tick(dt) end
  if params.touch > 0 and params.enabled ~= 0 and scatter and scatter.near then touch_tick(dt) end
  if params.enabled == 0 then
    if cur_body then clearAll(); cur_body = nil end
    diag("switched off (enabled = 0)")
    return
  end
  if time < next_t then return end
  next_t = time + params.interval
  if #retiring > 0 then sweep_retiring() end
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
  base_sweep()
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
        for l = 0, (sp.lods or 1) - 1 do list[#list + 1] = fg.modelFor(sp, l) end
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


-- The engine keeps a wash on the ground: dig, sculpt or re-generate the
-- ground under it and it is laid again on the surface there, or goes if
-- nothing is left (engine 0.117.0-rc6, card 0464). A wash the engine took
-- is forgotten at the next re-fade and laid again by the pass that lays new
-- ones.
-- NOTHING POPS: a wash is laid at nothing and fades up over WASH_IN seconds,
-- fades with distance at the rim, and fades out with height over the last
-- third of `tint_alt` (it was lifted all at once on the way up).
local WASH_IN = 1.5
local function wash_alpha(inf, d, range, kalt)
  local kd = math.max(0, math.min(1, (range - d) / (range * 0.4)))
  local ki = math.max(0, math.min(1, (time - (inf[5] or 0)) / WASH_IN))
  return inf[4] * kd * ki * kalt
end
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
              -- No turf washes anywhere on the base: a decal lays on every
              -- static collider face under it, and the buildings' invisible
              -- collider boxes (stair ramps, tank and pedestal boxes) took the
              -- grass tint as floating translucent panes ("the yellow
              -- semi-transparent box on the tracking station").
              local bf = ref("base_facilities")
              local fp = bf and bf.footprint
              local on_base = type(fp) == "table" and fp.body == cur_body and type(fp.x) == "number"
                and len(px - fp.x, py - fp.y, pz - fp.z) < (fp.radius or 175) + S
              if dens > 0.25 and not on_base then
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
                    alpha = 0.0,
                    rotation = ((i * 7 + j * 13) % 12) * 0.52,
                  })
                  if ok and id then
                    washes[key] = id
                    wash_n = wash_n + 1
                    wash_info[key] = { gx, gy, gz, base, time, 0.0 }
                    wash_fade_t = math.min(wash_fade_t, time + 0.1)
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
  -- (A quarter second while anything is still fading in or the height is
  -- changing the look, a second otherwise.)
  if time >= wash_fade_t and decals.set then
    local kalt = math.max(0, math.min(1, (params.tint_alt - (alt or 0)) / (params.tint_alt * 0.35)))
    local busy = (alt or 0) > params.tint_alt * 0.5
    for key, id in pairs(washes) do
      local inf = id and wash_info[key]
      if inf then
        local d = len(inf[1] - rx, inf[2] - ry, inf[3] - rz)
        local a = wash_alpha(inf, d, range, kalt)
        if time - inf[5] < WASH_IN or kalt < 1 then busy = true end
        if math.abs(a - (inf[6] or -1)) > 0.004 then
          inf[6] = a
          if not decals.set(id, { alpha = a }) then
            wash_n = wash_n - 1
            washes[key] = nil      -- pairs() allows clearing the current key
            wash_info[key] = nil
          end
        end
      end
    end
    wash_fade_t = time + (busy and 0.25 or 1.0)
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

-- ── rare plants ─────────────────────────────────────────────────────────────
--
-- A few per world, each in its own niche (climate RARE NICHES): under an
-- overhang, on a high peak, on a ravine floor, at a lake's edge, on a
-- riverbank. Unlike the scatter they are placed one by one, so each is a scene
-- node (a model, tinted, glowing, with a small light that wakes when you are
-- near) — a handful per world is nothing next to the scatter's thousands.
--
-- WHERE is worked out ONCE per world per save: climate.rareScan reads the
-- generated ground (terrain.query) a few thousand reads a frame, and the answer
-- goes in the save (`rare.<body>`), so a hole dug next to a plant later never
-- moves it, and a reload finds the same plants. Cut ones are `rare.cut.<body>`.
-- They do not grow back: a rare find is a find.
--
-- Published: `rareStatus` (what the scan is doing), `lastRare` (the find just
-- made: { name, niche, mat, at }), and rarePlants(body) for the objectives
-- card's directions.

rareStatus = "idle"
lastRare = nil

local rare = { body = nil, scan = nil, retry_t = 0, quiet_t = nil, nodes = {}, made = nil,
               swept = false, bx = 0, by = 0, bz = 0, lights = {} }

local function rare_valid(d, w, cl)
  return type(d) == "table" and d.v == (cl and cl.RARE_SCAN_V or 1)
    and d.seed == math.floor((w and w.seed) or 1) and type(d.plants) == "table"
end

local function rare_clear()
  for _, r in pairs(rare.nodes) do
    if r.node and r.node.valid then r.node:destroy() end
  end
  rare.nodes, rare.made, rare.lights = {}, nil, {}
end

-- The world's rare plants: { key, niche, name, sp, x, y, z (body-relative),
-- ux, uy, uz, cut }. Empty until the world has been scanned.
function rarePlants(bname)
  local cl, fg = ref("climate"), ref("flora_gen")
  local w = cl and bname and cl.worldOf(bname)
  local d = bname and save.get("rare." .. bname)
  if not (w and fg and rare_valid(d, w, cl)) then return {} end
  -- Plants want air: an airless world keeps only its ore pockets.
  if cl.habitable and not cl.habitable(bname) then return {} end
  local sps = fg.rareFor and fg.rareFor(bname, w) or {}
  local cut = save.get("rare.cut." .. bname) or {}
  local out, count = {}, {}
  for _, p in ipairs(d.plants) do
    local sp = sps[p.niche]
    if sp then
      count[p.niche] = (count[p.niche] or 0) + 1
      local key = p.niche .. count[p.niche]
      local l = len(p.x, p.y, p.z)
      out[#out + 1] = { key = key, niche = p.niche, name = sp.name, sp = sp, x = p.x, y = p.y, z = p.z,
                        ux = p.x / l, uy = p.y / l, uz = p.z / l, cut = cut[key] == true }
    end
  end
  return out
end

-- Which niches this world has rare plants in (a set), or nil before its scan.
function rareNiches(bname)
  local cl = ref("climate")
  local w = cl and bname and cl.worldOf(bname)
  local d = bname and save.get("rare." .. bname)
  if not rare_valid(d, w, cl) then return nil end
  local out = {}
  for _, p in ipairs(d.plants) do out[p.niche] = true end
  return out
end

-- ── finding them: the beam and the survey ──────────────────────────────────
-- "Struggling to find the rare plants even after hours of wandering": a glow
-- the size of a lamp, on a world of a few square kilometres, is found by
-- tripping over it. So every rare plant stands under a BEAM — a tall column of
-- its own glow colour, drawn clear of the fog, fading out at its foot and its
-- top — that reads from far off, and two things make it reach further:
--
--   * the SURVEY: opening the Tracking Station at the base maps the base
--     world's rare plants (`rare.survey.<body>`). Surveyed, every beam on that
--     world is visible from kilometres away, and the objectives card gives the
--     distance and bearing of the nearest one of the kind it wants.
--   * SPOTTING: walk within `rare_spot` metres of one and it is marked
--     (`rare.seen.<body>`) — its beam stays lit for you from then on.
--
-- Unsurveyed and unspotted, a beam still shows within `rare_beam_near`, so a
-- player exploring finds them by their light. Close up (inside ~20 m) the beam
-- fades away so it never stands in the way of the plant itself.
local BEAM_H, BEAM_R, BEAM_SEG = 140.0, 1.4, 10
local beam_mesh = nil
local function beam()
  if beam_mesh ~= nil then return beam_mesh or nil end
  beam_mesh = false
  if not (mesh and mesh.build) then return nil end
  local pos, col, nrm, idx = {}, {}, {}, {}
  local rings = { { 0.0, 0.0 }, { 0.12, 1.0 }, { 0.55, 0.6 }, { 1.0, 0.0 } }
  for ri, rg in ipairs(rings) do
    local y, a = rg[1] * BEAM_H, rg[2]
    -- Narrowing to a point at the top, so the column ends as a fading ray
    -- rather than a cut-off pole (the engine draws vertex alpha as colour
    -- only, so the taper is what shows the fade).
    local rr = BEAM_R * (ri == #rings and 0.08 or (1.0 - rg[1] * 0.6))
    for k = 0, BEAM_SEG - 1 do
      local ang = k / BEAM_SEG * math.pi * 2
      local cx, cz = math.cos(ang), math.sin(ang)
      pos[#pos + 1], pos[#pos + 2], pos[#pos + 3] = cx * rr, y, cz * rr
      nrm[#nrm + 1], nrm[#nrm + 2], nrm[#nrm + 3] = cx, 0, cz
      col[#col + 1], col[#col + 2], col[#col + 3], col[#col + 4] = 1, 1, 1, a
    end
  end
  for ri = 0, #rings - 2 do
    for k = 0, BEAM_SEG - 1 do
      local a0 = ri * BEAM_SEG + k + 1
      local a1 = ri * BEAM_SEG + (k + 1) % BEAM_SEG + 1
      local b0, b1 = a0 + BEAM_SEG, a1 + BEAM_SEG
      -- Both windings: the column is seen from inside as well as out.
      for _, t in ipairs({ { a0, b0, a1 }, { a1, b0, b1 }, { a0, a1, b0 }, { a1, b1, b0 } }) do
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = t[1], t[2], t[3]
      end
    end
  end
  local ok, name = pcall(mesh.build, { positions = pos, indices = idx, normals = nrm, colors = col })
  if ok and name then beam_mesh = name end
  return beam_mesh or nil
end

-- Has the base world's survey mapped `bname`'s rare plants?
function surveyed(bname)
  return bname ~= nil and save.get("rare.survey." .. bname) == true
end

-- Which rare plants of `bname` the crew has spotted (a set of keys).
function spotted(bname)
  local t = bname and save.get("rare.seen." .. bname)
  return type(t) == "table" and t or {}
end

-- Run the survey of `bname` (the Tracking Station does this). Returns how
-- many rare plants it mapped, or nil when there was nothing to survey yet.
function survey(bname, quiet)
  if not bname or surveyed(bname) then return nil end
  local list = rarePlants(bname)
  if #list == 0 then return nil end
  save.set("rare.survey." .. bname, true)
  local n = 0
  for _, p in ipairs(list) do if not p.cut then n = n + 1 end end
  log(string.format("rare: survey of %s mapped %d rare plants", bname, n))
  if not quiet then
    local bc = ref("big_caption")
    if bc and bc.show then
      bc.show("SURVEY COMPLETE", string.format(
        "The Tracking Station mapped %d rare plants on %s. Look for the beams of light; the objectives card has the nearest.",
        n, bname), 6.0)
    end
  end
  return n
end

local function rare_make(bname, planet)
  local list = rarePlants(bname)
  rare.made = bname
  for _, p in ipairs(list) do
    local sp = p.sp
    local r = { p = p, node = nil }
    rare.nodes[p.key] = r
    if not p.cut then
      local fg = ref("flora_gen")
      createNode("Rare " .. p.key, planet, function(n)
        n.model = fg.modelFor(sp, 0)
        n.x, n.y, n.z = p.x, p.y, p.z
        if n.setUp then n:setUp(vec3(p.ux, p.uy, p.uz)) end
        local s = sp.scale or 1
        n.scale_x, n.scale_y, n.scale_z = s, s, s
        local t, gc = sp.tint, sp.glowColor
        local leaf = { texture = "textures/flora/foliage_l0.png", normalMap = "textures/flora/foliage_n.png",
                       color = { t[1], t[2], t[3] }, emissive = { gc[1], gc[2], gc[3] },
                       emissiveStrength = sp.glow or 1.2, emissiveMap = "textures/flora/foliage_glow.png" }
        if sp.stalk then
          -- Two parts (a cap on a stalk): each its own override, so the stalk
          -- keeps a stalk's picture and only the cap is the species' colour.
          local ok = pcall(function()
            local m = n:material("leaf")
            for k2, v in pairs(leaf) do m[k2] = v end
            local b = n:material("bark")
            b.texture, b.normalMap = "textures/flora/bark_stalk_l0.png", "textures/flora/bark_stalk_n.png"
            b.color = { 0.75 + t[1] * 0.25, 0.75 + t[2] * 0.25, 0.75 + t[3] * 0.25 }
            b.emissive, b.emissiveStrength = { gc[1], gc[2], gc[3] }, (sp.glow or 1.2) * 0.25
          end)
          if not ok then n:setMaterial(leaf) end
        else
          n:setMaterial(leaf)
        end
        n.tags = { "flora", "rare" }
        r.node = n
        -- The glow you spot it by: a small soft orb over the crown, drawn
        -- clear of the fog so it reads from a hill away, and two motes.
        local k = 1 / math.max(s, 0.05)
        local crown = (sp.height or 1.5) * 1.08 * k
        for m = 1, 3 do
          createNode("Rare Orb", n, function(o)
            o:setPrimitive("Sphere")
            local sz = (m == 1 and 0.2 or 0.08) * k
            o.scale_x, o.scale_y, o.scale_z = sz, sz, sz
            local ang = m * 2.1
            o.x = (m == 1) and 0 or math.cos(ang) * 0.45 * k
            o.z = (m == 1) and 0 or math.sin(ang) * 0.45 * k
            o.y = crown + (m == 1 and 0.15 or -0.35 * m) * k
            o:setMaterial { color = { gc[1], gc[2], gc[3] }, emissive = { gc[1], gc[2], gc[3] },
                            emissiveStrength = (m == 1) and 1.4 or 1.8, unlit = true, fog = false,
                            alpha = (m == 1) and 0.8 or 0.9 }
            o.tags = { "flora", "rare" }
            r.orbs = r.orbs or {}
            r.orbs[#r.orbs + 1] = o
          end)
        end
        -- The light: a child a little above the plant, dark until you are near.
        createNode("Rare Light", n, function(l)
          l.y = 0.6 / math.max(s, 0.05)
          if l.setPointLight then l:setPointLight { color = { gc[1], gc[2], gc[3] }, intensity = 0, range = 7 } end
          l.tags = { "flora", "rare" }
          r.light = l
        end)
        -- The beam (see "finding them"): built in metres, so scaled back out
        -- of the plant's own scale; dark until rare_lights sets its alpha.
        local bm = beam()
        if bm then
          createNode("Rare Beam", n, function(bn)
            bn.model = bm
            bn.y = crown + 1.5 * k
            bn.scale_x, bn.scale_y, bn.scale_z = k, k, k
            bn:setMaterial { color = { gc[1], gc[2], gc[3] }, emissive = { gc[1], gc[2], gc[3] },
                             emissiveStrength = 1.3, unlit = true, fog = false, alpha = 0.0 }
            bn.visible = false
            bn.tags = { "flora", "rare" }
            r.beam = bn
          end)
        end
      end)
    end
  end
end

-- The two nearest uncut plants within range light up; the rest give their
-- light slot back (intensity 0).
local function rare_lights(obs, body)
  local near = {}
  for _, r in pairs(rare.nodes) do
    if r.light and r.light.valid and r.node and r.node.valid and r.node.visible ~= false then
      local d = len(obs.x - body.x - r.p.x, obs.y - body.y - r.p.y, obs.z - body.z - r.p.z)
      near[#near + 1] = { r = r, d = d }
    end
  end
  table.sort(near, function(a, b) return a.d < b.d end)
  for i, e in ipairs(near) do
    local want = (i <= 2 and e.d < params.rare_light) and 2.2 * math.min(1, (params.rare_light - e.d) / 15) or 0
    if math.abs((e.r.lit or -1) - want) > 0.05 then
      e.r.lit = want
      if e.r.light.setPointLight then e.r.light:setPointLight { intensity = want } end
    end
  end
  -- The beams, and spotting.
  local bname = rare.body
  local mapped = surveyed(bname)
  local seen = spotted(bname)
  local seen_new = false
  for _, e in ipairs(near) do
    local r = e.r
    if e.d < params.rare_spot and not seen[r.p.key] then
      seen[r.p.key] = true
      seen_new = true
    end
    if r.beam and r.beam.valid then
      local reach = (mapped or seen[r.p.key]) and params.rare_beam_far or params.rare_beam_near
      local a = 0
      if params.rare_beam > 0 then
        a = math.max(0, math.min(1, (e.d - 18) / 30)) * math.max(0, math.min(1, (reach - e.d) / (reach * 0.3)))
        a = a * params.rare_beam
      end
      a = math.floor(a * 50 + 0.5) / 50
      if a ~= r.beam_a then
        r.beam_a = a
        r.beam.visible = a > 0
        if a > 0 then
          local ok, m = pcall(r.beam.material, r.beam)
          if ok and m then m.alpha = 0.24 * a end
        end
      end
    end
  end
  if seen_new then save.set("rare.seen." .. bname, seen) end
end

-- The survey: the Tracking Station, open at the base, maps the base world.
local function rare_survey_tick()
  local ts = ref("tracking_station")
  if not (ts and ts.isOpen and ts.isOpen()) then return end
  local home = save.get("base.body")
  if type(home) == "string" and not surveyed(home) then survey(home) end
end

-- THE HOME WORLD'S GUARANTEE (climate RARE_HOME_V). The base's ground, which
-- nothing rare is put on: base_facilities' footprint, else the sited base,
-- else (a new save before siting) the generator's base site.
local function home_avoid(bname, w)
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if type(fp) == "table" and fp.body == bname and fp.x then
    return { x = fp.x, y = fp.y, z = fp.z, r = math.max(200, (fp.radius or 180) + 20) }
  end
  if save.get("base.body") == bname and type(save.get("base.x")) == "number" then
    return { x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z"), r = 200 }
  end
  local sg = ref("system_generator")
  local d = sg and sg.lastBaseDir
  if type(d) == "table" and sg.lastSpawnBody == bname then
    local R = w.radius or 600
    return { x = d[1] * R, y = d[2] * R, z = d[3] * R, r = 200 }
  end
  return nil
end

-- Step a scan for a slice of this frame. → its status
local function rare_drive(scan)
  local c0 = os and os.clock and os.clock()
  local st
  if c0 then
    repeat st = scan.step(200) until st ~= "running" or (os.clock() - c0) * 1000 >= params.rare_ms
  else
    st = scan.step(params.rare_budget)
  end
  if c0 then
    local ms = (os.clock() - c0) * 1000
    rare.ms, rare.frames = (rare.ms or 0) + ms, (rare.frames or 0) + 1
    rare.worst = math.max(rare.worst or 0, ms)
  end
  return st
end

-- The world's channels and lakes for a scan, or nil while they are still
-- being worked out (→ "wait").
local function rare_hydro(bname, w, cl)
  local layers = w.shape and w.shape.layers
  if w.hydro or (layers and (layers.ravines or layers.rivers)) then
    local sg = ref("system_generator")
    if sg and sg.hydroWarm then sg.hydroWarm(bname) end
    if sg and sg.hydroPending and sg.hydroPending(bname) then return nil, "wait" end
    return cl.hydroOf(bname)
  end
  return nil
end

rare_tick = function(dt)
  local gm = ref("game_manager")
  if gm and gm.loading then rareStatus = "waiting for the world"; return end
  if not (terrain and terrain.query) then return end
  local obs = observer()
  if not obs then return end
  local bname = space.dominant(obs.x, obs.y, obs.z)
  local body = bname and space.body(bname)
  if not body then return end
  rare.bx, rare.by, rare.bz = body.x, body.y, body.z
  if not rare.swept then
    rare.swept = true
    for _, n in ipairs(findTagged("rare") or {}) do
      if n.valid and n.name:sub(1, 5) == "Rare " then n:destroy() end
    end
  end
  if rare.body ~= bname then
    rare_clear()
    rare.scan, rare.ens, rare.body, rare.quiet_t = nil, nil, bname, nil
  end
  local cl, fg = ref("climate"), ref("flora_gen")
  local w = cl and cl.worldOf(bname)
  if not (w and cl.rareScan and fg and fg.rareFor) then return end
  -- Too far up for the ground to be the one we are standing over: nothing.
  local alt = len(obs.x - body.x, obs.y - body.y, obs.z - body.z) - (w.radius or body.radius)
  local d = save.get("rare." .. bname)
  if not rare_valid(d, w, cl) then
    if alt > (w.radius or 300) * 2 then return end
    if time < rare.retry_t then return end
    -- The whole field has to be in: wait for the terrain worker to go quiet.
    if terrain.busy and terrain.busy() then rare.quiet_t = nil; rareStatus = "waiting for the terrain"; return end
    rare.quiet_t = rare.quiet_t or time
    if time - rare.quiet_t < 2.0 then return end
    if not rare.scan then
      -- Rivers, lakes AND ravines: a world of ravines alone has no `hydro`
      -- flag on its record (that marks water), but its channels are there.
      local hydro, wait = rare_hydro(bname, w, cl)
      if wait then rareStatus = "waiting for the rivers"; return end
      -- On the home world nothing rare goes on the base's ground.
      local home = cl.homeWorldName and cl.homeWorldName() == bname
      rare.scan = cl.rareScan(w, hydro, function(x, y, z)
        return terrain.query(rare.bx + x, rare.by + y, rare.bz + z)
      end, { avoid = home and home_avoid(bname, w) or nil })
      rare.scan_t0 = time
    end
    -- A slice of time a frame, not a count: a field read costs 1–5 µs
    -- depending on the world and the machine's load.
    local st = rare_drive(rare.scan)
    rareStatus = string.format("scanning %s (%d reads)", bname, rare.scan.reads)
    if st == "done" then
      local res = rare.scan.result
      save.set("rare." .. bname, res)
      local tally = {}
      for _, p in ipairs(res.plants) do tally[p.niche] = (tally[p.niche] or 0) + 1 end
      local parts = {}
      for _, n in ipairs(cl.RARE_NICHES or {}) do parts[#parts + 1] = string.format("%s %d", n, tally[n] or 0) end
      log(string.format("rare: %s scanned in %.1f s over %d frames (%.2f ms a frame, worst %.2f; %d reads, grid %d, peak line %+.0f m): %s; %d ore pockets",
        bname, time - (rare.scan_t0 or time), rare.frames or 0, (rare.ms or 0) / math.max(1, rare.frames or 1),
        rare.worst or 0, rare.scan.reads, rare.scan.grid or 0, rare.scan.peakLine or 0,
        table.concat(parts, ", "), #res.ores))
      rare.ms, rare.frames, rare.worst = 0, 0, 0
      rare.scan = nil
    elseif st == "fail" then
      log(string.format("rare: %s scan stopped (%s) — trying again shortly", bname, tostring(rare.scan.why)))
      rare.scan, rare.retry_t = nil, time + 6
      rareStatus = "retrying"
    end
    return
  end
  -- The home world's guarantee: every niche and the geodes, topped up once
  -- (an old save too — by placement only; a new save may dig a grotto).
  if cl.homeWorldName and cl.homeWorldName() == bname and (d.home or 0) < (cl.RARE_HOME_V or 1) then
    -- Already enough of everything: nothing to top up.
    local tally = {}
    for _, p in ipairs(d.plants) do tally[p.niche] = (tally[p.niche] or 0) + 1 end
    local short = #(d.ores or {}) < (cl.RARE_HOME_ORES or 3)
    for _, n in ipairs(cl.RARE_NICHES or {}) do
      if (tally[n] or 0) < (cl.RARE_HOME_KEEP or 3) then short = true end
    end
    if not short then
      d.home = cl.RARE_HOME_V or 1
      save.set("rare." .. bname, d)
      log(string.format("rare: %s home guarantee: every niche already has %d, %d pockets", bname,
        cl.RARE_HOME_KEEP or 3, #(d.ores or {})))
      return
    end
    if alt > (w.radius or 300) * 2 then return end
    if time < rare.retry_t then return end
    if not rare.ens then
      if terrain.busy and terrain.busy() then rare.quiet_t = nil; rareStatus = "waiting for the terrain"; return end
      rare.quiet_t = rare.quiet_t or time
      if time - rare.quiet_t < 2.0 then return end
      local hydro, wait = rare_hydro(bname, w, cl)
      if wait then rareStatus = "waiting for the rivers"; return end
      local dig = nil
      if (tonumber(save.get("g_homeGen")) or 1) >= 2 and terrain.dig then
        dig = function(x, y, z, r) terrain.dig(rare.bx + x, rare.by + y, rare.bz + z, r) end
      end
      rare.ens = cl.rareScan(w, hydro, function(x, y, z)
        return terrain.query(rare.bx + x, rare.by + y, rare.bz + z)
      end, { rules = cl.RARE_RELAXED, have = d, fallback = true, caves = true, dig = dig,
             avoid = home_avoid(bname, w), ores = cl.RARE_HOME_ORES, now = function() return time end })
      rare.scan_t0 = time
    end
    local st = rare_drive(rare.ens)
    rareStatus = string.format("securing %s's rare finds (%d reads)", bname, rare.ens.reads)
    if st == "done" then
      local res = rare.ens.result
      for _, p in ipairs(res.plants) do d.plants[#d.plants + 1] = p end
      d.ores = d.ores or {}
      for _, o in ipairs(res.ores) do d.ores[#d.ores + 1] = o end
      d.home = cl.RARE_HOME_V or 1
      d.forced = rare.ens.forced
      save.set("rare." .. bname, d)
      if (rare.ens.dug or 0) > 0 and terrain.flush then pcall(terrain.flush) end
      local tally = {}
      for _, p in ipairs(d.plants) do tally[p.niche] = (tally[p.niche] or 0) + 1 end
      local parts = {}
      for _, n in ipairs(cl.RARE_NICHES or {}) do parts[#parts + 1] = string.format("%s %d", n, tally[n] or 0) end
      log(string.format("rare: %s home guarantee in %.1f s: +%d plants (%s forced: %s), +%d pockets, %d grottoes dug → %s; %d ore pockets",
        bname, time - (rare.scan_t0 or time), #res.plants, #(rare.ens.forced or {}),
        table.concat(rare.ens.forced or {}, ", "), #res.ores, rare.ens.dug or 0, table.concat(parts, ", "), #d.ores))
      rare.ms, rare.frames, rare.worst = 0, 0, 0
      rare.ens = nil
      rare_clear()
    elseif st == "fail" then
      log(string.format("rare: %s home guarantee stopped (%s) — trying again shortly", bname, tostring(rare.ens.why)))
      rare.ens, rare.retry_t = nil, time + 6
      rareStatus = "retrying"
    end
    return
  end
  rareStatus = "ready"
  if rare.made ~= bname then
    local planet = find(bname)
    if planet then rare_make(bname, planet) end
  end
  rare_survey_tick()
  rare_lights(obs, body)
end

-- The rare plant on the aim ray, scored like a scattered one.
local function rare_aim(body, x, y, z, dx, dy, dz, reach, cone, grab)
  local best, bestScore = nil, -1
  for key, r in pairs(rare.nodes) do
    if r.node and r.node.valid and r.node.visible ~= false and not r.p.cut then
      local p = r.p
      local wx, wy, wz = body.x + p.x, body.y + p.y, body.z + p.z
      local ex, ey, ez = wx - x, wy - y, wz - z
      local d = len(ex, ey, ez)
      if d > 0.01 and d <= reach then
        local dot = (ex * dx + ey * dy + ez * dz) / d
        local hgt = math.max(0.5, p.sp.height or 1)
        local near_, nx, ny, nz = math.huge, wx, wy, wz
        for i = 0, 4 do
          local f = hgt * (i / 4)
          local px, py, pz = wx + p.ux * f, wy + p.uy * f, wz + p.uz * f
          local t = (px - x) * dx + (py - y) * dy + (pz - z) * dz
          if t > 0 then
            local qd = len(px - (x + dx * t), py - (y + dy * t), pz - (z + dz * t))
            if qd < near_ then near_, nx, ny, nz = qd, px, py, pz end
          end
        end
        if (near_ <= grab * 1.3 and dot > 0) or dot >= cone then
          -- A rare plant wins a tie with the grass round it.
          local score = (grab * 1.3 - math.min(near_, grab * 1.3)) * 2.0 - d / reach + 0.5
          if score > bestScore then
            bestScore = score
            best = { pid = "rare:" .. key, dist = d, x = wx, y = wy, z = wz, ax = nx, ay = ny, az = nz,
                     height = hgt, ux = p.ux, uy = p.uy, uz = p.uz,
                     rec = { sp = p.sp, rare = key, body = rare.body } }
          end
        end
      end
    end
  end
  return best, bestScore
end

local function rare_harvest(rec, cid)
  local r = rare.nodes[rec.rare]
  if not r or r.p.cut then return {}, 0 end
  local inv, fg, rs = ref("inventory"), ref("flora_gen"), ref("research")
  if rs and rs.registerMaterials then rs.registerMaterials() end
  local got, dropped = {}, 0
  local took_specimen = 0
  for _, y in ipairs(fg and fg.harvestYield(rec.sp, #rec.rare * 977 + 13) or {}) do
    local took = inv and inv.add(cid or "astro", y.mat, y.n) or 0
    if y.mat == rec.sp.mat then took_specimen = took end
    if took > 0 then got[#got + 1] = { mat = y.mat, n = took } end
    dropped = dropped + (y.n - took)
  end
  -- No room for the specimen itself: the plant stays where it is.
  if took_specimen <= 0 then return got, dropped end
  r.p.cut = true
  local cut = save.get("rare.cut." .. rare.body) or {}
  cut[rec.rare] = true
  save.set("rare.cut." .. rare.body, cut)
  if r.node and r.node.valid then r.node.visible = false end
  if r.light and r.light.valid and r.light.setPointLight then r.light:setPointLight { intensity = 0 } end
  lastRare = { name = rec.sp.name, niche = rec.sp.niche, mat = rec.sp.mat, at = time, body = rare.body }
  log(string.format("RARE FIND: %s (%s) on %s", rec.sp.name, rec.sp.niche, tostring(rare.body)))
  return got, dropped
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
  if not body and rare.body then body = space.body(rare.body) end
  if not body then return nil end
  local best, bestScore = nil, -1
  if rare.body and next(rare.nodes) then
    best, bestScore = rare_aim(space.body(rare.body) or body, x, y, z, dx, dy, dz, reach, cone, grab)
  end
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
  if rec and rec.rare then return rare_harvest(rec, cid) end
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
    -- …and from a re-settled stand's old sources while they still draw.
    for _, r in ipairs(retiring) do
      if r.pk == rec.patch and r.spid == rec.sp.id then scatter.remove(r.id, rec.inst) end
    end
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
