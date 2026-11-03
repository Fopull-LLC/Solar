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
-- the gravity gun and the laser's cut call them unchanged). A cut plant is `scatter.remove`d by
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
  -- The engine bend's reach (m): every prop within it leans, rocks and trunks
  -- too, so it stays inside the distance the crew is held off them.
  --@range 0.3 2 --@units m
  touch_r_engine = 0.9,
  -- Most plants bent at once.
  --@range 0 40
  touch_cap = 14,
  -- 1 = bend with the engine's scatter interactors (engine 0.117.0-rc7: the
  -- props lean in the draw, no node, no remove/restore) where the engine has
  -- them; 0 = swap each bent plant for a node (see "touch"). Off for now:
  -- measured on Kail it costs about half (flora_field 0.5–1.0 ms against
  -- 0.9–2.2, worst 10–17 ms against 6–28), but up to rc9 the engine bent
  -- EVERY source in reach, rocks and trunks too, and had no easing of its own
  -- (the wake below stands in for it). rc10 bends only bend > 0 sources and
  -- springs them back; its look is not signed off yet.
  touch_engine = 0,
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
  -- ON since floptle 0.117.0-rc22 (card 0525), and held OFF by the script on
  -- older engines (WASH_RELAY_BUDGETED below): before rc22 every chunk the
  -- terrain streamed in marked the whole level edited, every wash was checked
  -- and laid again, one 28.8 m wash a frame at 12-34 ms, and with 70 washes
  -- in range that was every frame (walking a meadow on the user's save:
  -- rc19 36.6 ms/frame mean, rc20 24.5-27.5 with decalRelay 5.1 ms on the
  -- average frame; 16.5 with the washes off). rc22 re-lays only the marks
  -- whose ground changed, through the budgeted tiled lay: the same walk with
  -- 66-101 washes in range reads 16.6 ms mean, p95 22, max 34, decalRelay
  -- 0.00 on every frame, and 100 laser bites on the meadow cost decalRelay
  -- 2.0 ms at most (0.14 mean on the first 25, 0 after). Standing still costs
  -- nothing on any engine.
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
-- Washes lifted round a terrain edit (liftWash): key → when it may come back,
-- and the regions no new wash is laid in until then (body-relative).
local wash_lifted = {}
local wash_holds = {}   -- { x, y, z, r, t }
obs_speed = 0.0          -- the observer's speed over the ground (m/s), smoothed
local obs_last = nil      -- { body, x, y, z, t } at the last pass
local frame_checked = false
local wash                -- defined below update (ground wash)
local preload_t = 0
local swept = false
local retiring = {} -- { id, pk, spid, t }: re-settled stands' old sources, still drawn until t
local base_wait_t = nil     -- when the field began waiting for the base's layout
local BASE_WAIT = 30.0
local clear_q = {}  -- stands being judged against the base (JUDGED BEFORE IT IS DRAWN)
-- Ground edits waiting to re-drop the props on them (see "the ground moved").
local gw_regions = {}            -- { x, y, z, r, t }: body-relative, t = the last edit in it
local gw_queue, gw_queued = {}, {}

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

-- A source's seed, from (world seed, face, sign, i, j, species). EXACT 32-bit
-- arithmetic: Lua numbers are doubles, and the old `s * 16777619 + v` passed
-- 2^53 on every step, so the low bits — the small terms, the species id last
-- of all — were rounded away. Every species on a patch got the same seed (on
-- the new-game world, species 1–3 one seed and 4–12 another), so the engine
-- laid them out on the SAME places with the SAME instance ids: an elm stood
-- inside another elm, a bracket fungus inside a shroom. Cut one and the other
-- stayed exactly where it was — the "ghost" tree (probe 2026-10-27,
-- tools/perf/fellprobe.sh). The multiply is split in 16-bit halves so no
-- product passes 2^53, and the end is mixed so neighbouring ids scatter.
local function mul32(a, b)
  local ah, al = math.floor(a / 65536), a % 65536
  return ((ah * b) % 65536 * 65536 + al * b) % 4294967296
end
local function hash(...)
  local s = 2166136261
  for _, v in ipairs({ ... }) do
    s = (mul32(s, 16777619) + math.floor(v) % 2147483647) % 4294967296
  end
  s = mul32((s + math.floor(s / 65536)) % 4294967296, 2246822519)
  s = mul32((s + math.floor(s / 8192)) % 4294967296, 3266489917)
  s = (s + math.floor(s / 65536)) % 4294967296
  return s % 2147483647 + 1
end
seedHash = hash   -- for the smoke test: every species on a patch its own seed

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

-- Has the stand that replaces a retiring source dropped its props onto the
-- ground round the crew? The engine settles arriving props ~96 a frame across
-- every source, so a stand redeclared beside a dozen others can take longer
-- than the hold; the old source going first left a hole in the stand for the
-- frames until its replacement's props landed. A sample of the replacement's
-- props in reach (any order, one page) all settled is the sign.
local RETIRE_WAIT = 6.0   -- s past the hold at the most
local function replacement_settled(r)
  local p = patches[r.pk]
  local nid = p and (r.part == "bark" and p.bark[r.spid] or p.srcs[r.spid])
  local s = nid and srcs[nid]
  if not s then return true end
  local o = observer()
  if not (o and scatter.near) then return true end
  local reach = math.min((s.sp and s.sp.far or 60) * params.reach, 150)
  local ok, F = pcall(scatter.near, nid, vec3(o.x, o.y, o.z), reach, { flat = true, max = 256, sort = false, fields = { "settled" } })
  if not (ok and F and F.settled) then return true end
  for k = 1, F.count or #F.settled do
    if not F.settled[k] then return false end
  end
  return true
end

-- Destroy retiring sources whose hold is over (or all of a patch's, or all).
local function sweep_retiring(pk, all)
  local keep = {}
  for _, r in ipairs(retiring) do
    local due = all or r.pk == pk
    if not due and time >= r.t then due = time >= r.t + RETIRE_WAIT or replacement_settled(r) end
    if due then
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
  for i = #clear_q, 1, -1 do
    if scatter and scatter.destroy and clear_q[i].judge then scatter.destroy(clear_q[i].judge) end
    clear_q[i] = nil
  end
  for key in pairs(patches) do drop_patch(key) end
  for id in pairs(srcs) do drop_source(id) end
  for _, m in ipairs(motes) do if m and m.valid then m:destroy() end end
  for _, d in pairs(washes) do if d and decals and decals.remove then decals.remove(d) end end
  washes, wash_n, wash_info = {}, 0, {}
  patches, srcs, settled, motes, cuts, convert = {}, {}, {}, {}, {}, {}
  gw_regions, gw_queue, gw_queued = {}, {}, {}
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
local base_layout_read

-- What the base clearing (and the ground audit) took off a stand, by patch and
-- species: re-applied the moment the stand is declared again (make_source), the
-- way the cuts are. Ids are (seed, chunk, index), so the same id is the same
-- plant in every declaration. Without it a redeclared stand drew every plant
-- on the paving again until clear_tick, a few frames later, took them off one
-- by one: plants near the base blinking in and out (playtest 2026-10-27).
-- Tied to the layout it was judged against (base_l.key): a moved base starts
-- over.
local function keep_cleared(p, spid, iid)
  p.cleared = p.cleared or {}
  local c = p.cleared[spid]
  if not c or c.key ~= base_l.key then
    c = { key = base_l.key, ids = {}, done = false }
    p.cleared[spid] = c
  end
  c.ids[iid] = true
end
local function cleared_of(p, spid)
  local c = p.cleared and p.cleared[spid]
  if c and c.key == base_l.key then return c.ids end
  return nil
end

local function base_layout()
  -- Asked for every prop the clearing judges (baseKeep): its seven save
  -- reads once a frame, not once a prop.
  if base_l.at == time and base_l.key then return base_l.ok and base_l or nil end
  local L = base_layout_read()
  base_l.at, base_l.ok = time, L ~= nil
  return L
end
base_layout_read = function()
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

-- ── scatter.near, flat and paged ────────────────────────────────────────────
-- A row and two vec3s a hit: one query round the base cost 12.5 ms of a
-- 22.7 ms frame (perf pass 2026-11). Since engine 0.117.1-dev.1379 (card 0596)
-- `{ flat = true }` answers parallel arrays { ids, x, y, z, distance, scale,
-- param, yaw, settled, count } (no `up`), and `{ max, sort = false, after }`
-- hands a big query out a page at a time. An older engine, or a test stub,
-- answers rows and ignores the options: they are turned into the same arrays
-- here (plus `up`), one page holding everything and no cursor.
local NEAR_FLAT = { flat = true }
local function near_flat(id, q, r, opt)
  local res, cur = scatter.near(id, q, r, opt or NEAR_FLAT)
  if res and res.ids then return res, cur end
  local F = { ids = {}, x = {}, y = {}, z = {}, distance = {}, scale = {}, param = {}, yaw = {}, settled = {}, up = {} }
  local n = 0
  for _, h in ipairs(res or {}) do
    n = n + 1
    F.ids[n], F.x[n], F.y[n], F.z[n] = h.id, h.pos.x, h.pos.y, h.pos.z
    F.distance[n], F.scale[n], F.param[n], F.yaw[n] = h.distance, h.scale, h.param, h.yaw
    F.settled[n], F.up[n] = h.settled, h.up
  end
  F.count = n
  return F, nil
end

-- A paged query, read over frames: pager(id, rx, ry, rz, r) round a
-- BODY-RELATIVE centre, then pager_next(pg, body) → the next page (flat, with
-- F.rx/ry/rz body-relative), or nil once it is all handed out.
-- * The engine makes the query once, in the planet's frame, on the first page.
-- * Every page is handed out in the world frame of THIS call (engine 0603,
--   0.117.1-dev.1382): the engine keeps the query's held hits in the source's
--   own frame, so a page is placed against this frame's body read as-is.
-- * A cursor the engine has dropped (more than it keeps were paged since)
--   ends in one whole flat query: judging a prop twice is harmless.
local NEAR_PAGE = 256
local function pager(id, rx, ry, rz, r)
  return { id = id, qx = rx, qy = ry, qz = rz, r = r, cur = nil, done = false }
end
local function pager_next(pg, body)
  if pg.done then return nil end
  local q = vec3(body.x + pg.qx, body.y + pg.qy, body.z + pg.qz)
  local F, cur
  if pg.cur then
    local ok, a, b = pcall(scatter.near, pg.id, q, pg.r, { flat = true, max = NEAR_PAGE, sort = false, after = pg.cur })
    if ok and a then F, cur = a, b else F, cur = near_flat(pg.id, q, pg.r), nil end
  else
    F, cur = near_flat(pg.id, q, pg.r, { flat = true, max = NEAR_PAGE, sort = false })
  end
  pg.cur, pg.done = cur, cur == nil
  local X, Y, Z = F.x, F.y, F.z
  local bx, by, bz = body.x, body.y, body.z
  local rx, ry, rz = {}, {}, {}
  for k = 1, F.count do rx[k], ry[k], rz[k] = X[k] - bx, Y[k] - by, Z[k] - bz end
  F.rx, F.ry, F.rz = rx, ry, rz
  return F
end
-- (mineral_field's audit pages its rocks the same way)
nearPager, nearPagerNext = pager, pager_next

-- JUDGED BEFORE IT IS DRAWN (playtest 2026-11-03: "near the base, most when
-- you first spawn, plants and trees pop in and out rapidly"). A stand that
-- reaches the base is judged against the paving FIRST and declared after,
-- with what the judgement took off already removed, so no plant is ever drawn
-- on the paving and then taken away. Before this the real source was
-- declared, drawn, and cleared a page at a time over the next frames (a grass
-- stand by the base is a few thousand props): every stand round the spawn
-- showed its plants on the apron and the lots, then lost them by the hundred
-- a frame, and again whenever a stand was declared anew.
--
-- The judgement needs the stand's props, and only the engine knows where its
-- seed puts them, so it asks a JUDGE: a source with the stand's own seed,
-- region, density and chunking (the same ids in the same places: an id is
-- (seed, chunk, index), placement is a pure function of those) that draws
-- nothing (one empty band a centimetre deep, so it never even settles). Its
-- props are paged out (pager, above: one query of them all at once was
-- 22.7 ms) and judged CLEAR_MS of wall time a frame (`clear_tick`, every
-- frame; more under the loading curtain), one stand at a time, nearest first;
-- then the judge goes and the stand is declared (make_source applies
-- `cleared_of`). The judgement is kept per patch and species against the
-- layout it was made for (base_l.key), so a stand declared again (the ground
-- re-drop, a walk away and back) is declared at once, already clear.
-- A stand that was ALREADY drawing when it came to be judged (declared before
-- the base was sited, or a moved base) loses everything judged off it in ONE
-- frame, at the end, not a page at a time.
local CLEAR_MS, CLEAR_MS_CURTAIN = 2.0, 8.0
local function clear_wall() return (app and app.wallClock and app.wallClock()) or os.clock() end

-- Does this stand need judging against the base before it may be drawn?
local function needs_judging(p, sp)
  local L = base_layout()
  if not (L and scatter.near and scatter.create) then return false end
  -- Only a patch that reaches the base.
  if len(p.cx - L.x, p.cy - L.y, p.cz - L.z) > p.half * 1.5 + L.r then return false end
  local c = p.cleared and p.cleared[sp.id]
  return not (c and c.key == base_l.key and c.done)
end

-- Start judging a stand (opts: the stand's scatter.create options, from
-- make_source). → true when a judgement is under way.
local function judge_start(p, sp, opts, fg)
  p.judging = p.judging or {}
  if p.judging[sp.id] then return true end
  local L = base_layout()
  local body = cur_body and space.body(cur_body)
  if not (L and body) then return false end
  local empty = fg and fg.emptyAsset and fg.emptyAsset() or nil
  if not empty then return false end
  local ok, jid = pcall(scatter.create, {
    seed = opts.seed, center = opts.center, halfX = opts.halfX, halfZ = opts.halfZ,
    perChunk = opts.perChunk, chunk = opts.chunk, align = opts.align,
    scaleMin = opts.scaleMin, scaleMax = opts.scaleMax,
    density = opts.density, densityRows = opts.densityRows, parent = opts.parent,
    lod = { { asset = empty, distance = 0.01 } },
  })
  if not ok then
    diag("judge refused: " .. tostring(jid))
    return false
  end
  local h = (sp.height or 1) * (sp.scaleMax or 1)
  -- Grass and ground cover are the verge, however tall a blade: a clean edge.
  if sp.role == "carpet" or sp.kind == "grass" or sp.kind == "moss" then h = math.min(h, BASE_CLEAR.tall) end
  local foot0 = fg and fg.footprint and fg.footprint(sp) or nil
  -- a fresh judgement for this layout (keep_cleared keeps what the audit took)
  p.cleared = p.cleared or {}
  local c = p.cleared[sp.id]
  if not c or c.key ~= base_l.key then p.cleared[sp.id] = { key = base_l.key, ids = {}, done = false } end
  p.judging[sp.id] = true
  -- body-relative centre: the planet moves on its rails while the job runs
  clear_q[#clear_q + 1] = { judge = jid, p = p, sp = sp, pg = pager(jid, L.x, L.y, L.z, L.r), F = nil, i = 1,
                            h = h, foot0 = foot0, L = L, key = base_l.key }
  return true
end

local make_source, redeclare   -- (below)
-- A judgement finished: the judge goes; a stand already drawing loses what was
-- judged off it, all at once; one waiting for it is declared.
local function judge_done(j, ok)
  if scatter.destroy then scatter.destroy(j.judge) end
  local p, sp = j.p, j.sp
  if p.judging then p.judging[sp.id] = nil end
  if patches[p.key] ~= p then return end          -- the patch went meanwhile
  local c = p.cleared and p.cleared[sp.id]
  if not ok or not c or c.key ~= j.key then return end
  c.done = true
  local live = p.srcs[sp.id]
  if live and srcs[live] then
    for iid in pairs(c.ids) do
      scatter.remove(live, iid)
      if p.bark[sp.id] then scatter.remove(p.bark[sp.id], iid) end
    end
    if p.redeclare_after and p.redeclare_after[sp.id] then
      p.redeclare_after[sp.id] = nil
      redeclare(p, sp)
    end
  elseif live == nil and p.dist and p.dist < sp.far * params.reach + 40 then
    local cl, fg = ref("climate"), ref("flora_gen")
    local w = cl and cl.worldOf(cur_body)
    if fg and w then p.srcs[sp.id] = make_source(p, sp, fg, w) end
  end
end

-- Judge queued props for CLEAR_MS (one prop at the least).
local function clear_tick()
  if #clear_q == 0 then return end
  local t0 = clear_wall()
  local gm = ref("game_manager")
  local budget = (gm and gm.curtain) and CLEAR_MS_CURTAIN or CLEAR_MS
  local body = cur_body and space.body(cur_body)
  local n = 0
  while #clear_q > 0 do
    local j = clear_q[1]
    if not body or patches[j.p.key] ~= j.p then
      table.remove(clear_q, 1)            -- the patch went (or the world did)
      judge_done(j, false)
    else
      local p, sp, L = j.p, j.sp, j.L
      if not j.F or j.i > j.F.count then
        j.F, j.i = pager_next(j.pg, body), 1
      end
      local F = j.F
      if not F then
        table.remove(clear_q, 1)          -- every page judged
        judge_done(j, true)
      else
        local ids, sc, st, RX, RY, RZ = F.ids, F.scale, F.settled, F.rx, F.ry, F.rz
        while j.i <= F.count do
          local k = j.i
          j.i = k + 1
          n = n + 1
          local iid = ids[k]
          local px, py, pz = RX[k], RY[k], RZ[k]
          local foot = j.foot0 and j.foot0 * (sc[k] or 1)
          -- A prop not yet dropped answers on its patch's PLANE, which off the
          -- patch's centre stands metres over the ground; the engine drops it along
          -- the patch's -Y. Near an edge, where a metre decides it, drop it here
          -- the same way (a few signed-distance steps) before judging it.
          if not st[k] and foot then
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
          local keep = baseKeep(px, py, pz, j.h, foot)
          if keep < 1 then
            local roll = (((iid % 2147483647) * 48271 + 11) % 2147483647) / 2147483647
            if roll >= keep then keep_cleared(p, sp.id, iid) end
          end
          if n % 16 == 0 and (clear_wall() - t0) * 1000 >= budget then return end
        end
        -- (the next page, or the next stand, while the frame's time lasts)
        if (clear_wall() - t0) * 1000 >= budget then return end
      end
    end
  end
end

-- Stands declared before the base was sited (a new save's first patches), or
-- judged against a layout that has since changed: judged now, and what the
-- judgement takes off goes in one frame.
local function base_sweep()
  local L = base_layout()
  if not L or L.swept then return end
  L.swept = true
  local n = 0
  local fg = ref("flora_gen")
  for id, sr in pairs(srcs) do
    local p = patches[sr.patch]
    if p and sr.part ~= "bark" and sr.sp and p.srcs[sr.sp.id] == id and sr.opts and needs_judging(p, sr.sp)
       and judge_start(p, sr.sp, sr.opts, fg) then
      n = n + 1
    end
  end
  if n > 0 then diag(string.format("base sited: %d stands near its ground to judge", n)) end
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
      local F = near_flat(id, vec3(body.x + L.x, body.y + L.y, body.z + L.z), L.r)
      for k = 1, F.count do
        local px, py, pz = F.x[k] - body.x, F.y[k] - body.y, F.z[k] - body.z
        out.total = out.total + 1
        local clr = base_clearance(L, px, py, pz)
        local keep = baseKeep(px, py, pz, h)
        if F.settled[k] then
          out.settled = out.settled + 1
          if clr < foot0 * (F.scale[k] or 1) then out.overPaving = out.overPaving + 1 end
        end
        if clr < 0 then out.onBuilt = out.onBuilt + 1 end
        if keep <= 0 then out.inMargin = out.inMargin + 1 elseif keep < 1 then out.fading = out.fading + 1 end
      end
    end
  end
  return out
end

-- The kinds of plant that give way to a walker (bent in the draw or swapped
-- for a node, see "touch"); trunks, cacti and succulents do not.
local BEND_KIND = { grass = true, fern = true, reed = true, bush = true, shrub = true, moss = true }

function make_source(p, sp, fg, w)
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
  -- Where the stand's props are (the judge's options: JUDGED BEFORE IT IS
  -- DRAWN, above). A stand that reaches the base is declared once judged.
  local where = {
    seed = seed, center = vec3(0, 0, 0), halfX = p.half, halfZ = p.half,
    perChunk = sp.per, chunk = sp.chunk, align = sp.upright and "world" or "surface",
    scaleMin = sp.scaleMin, scaleMax = sp.scaleMax, density = data, densityRows = rows, parent = p.name,
  }
  if needs_judging(p, sp) and judge_start(p, sp, where, fg) then return nil end
  local list = cuts_of(p.key, sp.id)
  local function declare(part)
    -- Every band cross-dissolves into the next, and the last into nothing
    -- (flora_gen.fadeBands): nothing pops in or out at the edge of its reach.
    local bands = {}
    for l = 0, (sp.lods or 1) - 1 do
      bands[#bands + 1] = { asset = fg.assetFor(sp, l, part), at = sp.lodAt[l + 1] or 1.0 }
    end
    local lod, fade = fg.fadeBands(bands, far, params.fade_out > 0 and fg.emptyAsset and fg.emptyAsset() or nil)
    local opts = { fade = fade, lod = lod }
    for k, v in pairs(where) do opts[k] = v end
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
      -- Soft plants give way to the crew (scatter.setInteractors); since
      -- 0.117.0-rc10 only a source made with bend > 0 does, so trunks, cacti
      -- and succulents stay rigid.
      if BEND_KIND[sp.kind] then opts.bend = 1 end
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
    -- …and what the base clearing took off here stays off (keep_cleared).
    local gone = cleared_of(p, sp.id)
    if gone then for iid in pairs(gone) do scatter.remove(id, iid) end end
    srcs[id] = { patch = p.key, sp = sp, fill = sum / (rows * rows), part = part, made = time, tint = opts.tint,
                 opts = where }
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
-- The old sources keep drawing for `resettle_hold` seconds while the new
-- ones' props settle in, then go (sweep_retiring): drop-then-declare left the
-- stand missing for the frames its props took to arrive.
function redeclare(p, sp)
  -- Not judged against the base's layout yet: the stand keeps drawing as it
  -- is until it has been, and is declared again then (judge_done).
  local cur = p.srcs[sp.id] and srcs[p.srcs[sp.id]]
  if cur and cur.opts and needs_judging(p, sp) and judge_start(p, sp, cur.opts, ref("flora_gen")) then
    p.redeclare_after = p.redeclare_after or {}
    p.redeclare_after[sp.id] = true
    return
  end
  for _, id in ipairs({ p.srcs[sp.id], p.bark[sp.id] }) do
    if id then
      retiring[#retiring + 1] = { id = id, pk = p.key, spid = sp.id, t = time + params.resettle_hold,
                                  part = srcs[id] and srcs[id].part }
      srcs[id] = nil
    end
  end
  p.srcs[sp.id], p.bark[sp.id] = nil, nil
  local cl, fg = ref("climate"), ref("flora_gen")
  local w = cl and cl.worldOf(cur_body)
  if not (fg and w) then return end
  p.srcs[sp.id] = make_source(p, sp, fg, w)
end

-- ── the ground moved: drop what stood on it again ───────────────────────────
-- The engine drops a prop onto the ground once, when its chunk first settles,
-- and keeps that height for good (lua-api scatter.create). It forgets a chunk
-- when a script edit lands on it, but only round the point the edit was
-- SENT, in the world as it was then — a grade of thousands of flattens lands
-- over seconds while the planet moves metres a tick, so its own edges were
-- never re-dropped — and never when saved ground streams in under props
-- already settled. That left grass hanging 2–3 m over the base's feathered
-- edges and rocks a metre over the cut by the pad (playtest 2026-10-27).
--
-- So every script that edits the ground says where (`groundChanged`, a world
-- point and a radius; it also tells mineral_field), the edits are folded
-- into a few regions (a laser's hundreds of bites are one), and once a
-- region has been quiet for GROUND.wait seconds and the engine has landed
-- every edit, the sources of the patches it touches are declared again
-- (`redeclare`: same seed, same plants, cuts kept, the old source drawn for
-- resettle_hold seconds, so nothing blinks), one source a tick. A source
-- near the base is judged against the paving again when it is redeclared
-- (make_source: judged before it is drawn), so nothing is left on a lot or the paving.
GROUND = { wait = 1.2, merge = 6.0, cap = 150.0, pad = 3.0, most = 48 }

-- Fold an edit (centre, radius, time) into `list`: inside a region it only
-- moves the region's time on; touching one (within `merge`) grows that
-- region to the sphere round both, while that stays under `cap`; anything
-- else is a region of its own. Pure (luajit tests).
function groundMerge(list, x, y, z, r, t, merge, cap)
  merge, cap = merge or 0, cap or math.huge
  for _, g in ipairs(list) do
    local d = len(x - g.x, y - g.y, z - g.z)
    if d + r <= g.r then
      g.t = math.max(g.t, t)
      return g
    elseif d + g.r <= r then
      g.x, g.y, g.z, g.r, g.t = x, y, z, r, math.max(g.t, t)
      return g
    elseif d <= g.r + r + merge then
      local nr = (d + r + g.r) * 0.5
      if nr <= cap then
        local k = (nr - g.r) / d
        g.x, g.y, g.z = g.x + (x - g.x) * k, g.y + (y - g.y) * k, g.z + (z - g.z) * k
        g.r, g.t = nr, math.max(g.t, t)
        return g
      end
    end
  end
  local g = { x = x, y = y, z = z, r = r, t = t }
  list[#list + 1] = g
  return g
end

-- The regions quiet for `wait` seconds at `now`, taken out of `list`. Pure.
function groundDue(list, now, wait)
  local due = {}
  for i = #list, 1, -1 do
    if now - list[i].t >= wait then due[#due + 1] = table.remove(list, i) end
  end
  return due
end

-- Queue one job (a patch key and a layer id) once until it runs. Pure.
function groundQueue(queue, queued, key, id)
  local k = key .. "|" .. tostring(id)
  if queued[k] then return false end
  queued[k] = true
  queue[#queue + 1] = { key = key, id = id }
  return true
end

-- A WORLD point and radius where the ground was dug, raised, flattened or
-- graded. Cheap: call it per edit. Tells the rocks too.
--
-- ONLY WHERE THE ENGINE DOES NOT (playtest 2026-10-27, "plants near the base
-- phase into existence, speed by, and then disappear"). Since engine
-- 0.117.1 (91e97ff, "Scatter re-settles where an edit landed on a moving
-- planet") the engine itself re-drops the props under every script edit,
-- found through the planet's frame as it is when the edit lands, which is
-- the very thing this was written to stand in for. Redeclaring on top of it
-- swapped whole 150-260 m stands for fresh sources after every laser bite,
-- fill, crater and drill bite (and after every floating prop the audit saw):
-- each new source drew the props the base clearing had taken off the paving
-- (those removals were the old source's) until clear_tick took them off again
-- a few frames later, while the old source drew beside it for resettle_hold
-- seconds. So on such an engine an edit only tells the rocks (which do the
-- same check), and a redeclare happens only when `force` says the ground
-- changed WITHOUT an edit the engine saw: saved ground streaming in under
-- props that settled first (the base, once a session) and the audit's
-- floating props (once per stand per session).
function groundChanged(x, y, z, r, force)
  local mf = ref("mineral_field")
  if mf and mf.groundChanged then pcall(mf.groundChanged, x, y, z, r, force) end
  if ENGINE_RESETTLES_EDITS and not force then return false end
  local body = cur_body and space.body(cur_body)
  if not body or not x then return false end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  -- (a planet the field is not growing on: nothing of ours stands there)
  if len(rx, ry, rz) > (body.radius or 1e9) * 2 + 1000 then return false end
  if #gw_regions >= GROUND.most then
    groundMerge(gw_regions, rx, ry, rz, r or 3.0, time, math.huge, math.huge)
  else
    groundMerge(gw_regions, rx, ry, rz, r or 3.0, time, GROUND.merge, GROUND.cap)
  end
  return true
end

-- Regions that have gone quiet → their patches' sources, one redeclared a
-- tick. (`ground_tick` runs from update, every field pass.)
local function ground_tick()
  if #gw_regions > 0 and not (terrain.pending and terrain.pending() > 0) then
    for _, g in ipairs(groundDue(gw_regions, time, GROUND.wait)) do
      for key, p in pairs(patches) do
        -- (in the patch's plane, and not on the far side of the world under it)
        if patch_dist(p, g.x, g.y, g.z) <= g.r + GROUND.pad
           and len(g.x - p.cx, g.y - p.cy, g.z - p.cz) <= g.r + p.half * 1.5 + GROUND.pad then
          for spid, id in pairs(p.srcs) do
            if id and srcs[id] then groundQueue(gw_queue, gw_queued, key, spid) end
          end
        end
      end
    end
  end
  local j = table.remove(gw_queue, 1)
  if not j then return end
  gw_queued[j.key .. "|" .. tostring(j.id)] = nil
  local p = patches[j.key]
  local s = p and p.srcs[j.id] and srcs[p.srcs[j.id]]
  if s and s.sp then redeclare(p, s.sp) end
end
function groundBusy() return #gw_regions + #gw_queue end

-- ── props standing on something that is not the ground ─────────────────────
-- The engine's settling ray stops at the first thing under a prop — a
-- building's roof or ramp, a parked craft, debris — not only the terrain:
-- on the player's save ferns stood 2-4 m up on the fuel farm and the pad
-- (groundprobe, 2026-10-27). So the settled props round the observer are
-- checked a slice at a time (AUDIT.ms a frame, a pass every AUDIT.every s):
-- one more than AUDIT.tol over the terrain with something solid right under
-- it is taken off (scatter.remove — it comes back on the next declaration and
-- is judged again; it is not a cut and is not saved); one over open air or
-- under the ground stands on ground that has since changed, and that ground
-- is re-dropped (groundChanged), once per prop. Only a prop on something
-- that is not the terrain is ever removed.
-- A stand is re-dropped for a floating prop at most ONCE a session (`tried`
-- is keyed by patch and species, not by prop: keyed by prop, every one of a
-- stand's hundreds of props a few decimetres off the collision mesh asked for
-- the whole stand again, one after another, every pass), and only for a prop
-- more than AUDIT.redrop off the field.
AUDIT = { every = 3.0, radius = 60.0, ms = 0.35, tol = 0.35, redrop = 0.8 }
local au = { t = -1e9, job = nil, tried = {} }
auditRemoved, auditRedropped = 0, 0
local function audit_take(sid, it)
  local s = srcs[sid]
  local p = s and patches[s.patch]
  scatter.remove(sid, it.id)
  if p and s.sp and p.bark[s.sp.id] then scatter.remove(p.bark[s.sp.id], it.id) end
  if p and s.sp then keep_cleared(p, s.sp.id, it.id) end
  auditRemoved = auditRemoved + 1
end
local function audit_tick(obs)
  if not (obs and cur_body and scatter and scatter.near and AUDIT.every > 0) then return end
  local body = space.body(cur_body)
  if not body then return end
  if not au.job then
    if time < au.t + AUDIT.every then return end
    au.t = time
    local list = {}
    local rx, ry, rz = obs.x - body.x, obs.y - body.y, obs.z - body.z
    for id, sr in pairs(srcs) do
      local p = patches[sr.patch]
      if p and sr.part ~= "bark" and sr.sp and patch_dist(p, rx, ry, rz) <= AUDIT.radius then list[#list + 1] = id end
    end
    if #list == 0 then return end
    au.job = { list = list, si = 1, pg = nil, F = nil, i = 1 }
  end
  local j = au.job
  local t0 = clear_wall()
  local n = 0
  while j.si <= #j.list do
    local sid = j.list[j.si]
    local sr = srcs[sid]
    if not sr then
      j.si, j.pg, j.F = j.si + 1, nil, nil
    else
      -- a page at a time (pager): a grass source round the crew is thousands.
      -- Round the observer as it stands when this source's turn comes, kept
      -- body-relative: the job runs over frames and the planet moves metres
      -- a tick, so a world point read now is wrong next frame.
      if not j.pg then j.pg, j.F = pager(sid, obs.x - body.x, obs.y - body.y, obs.z - body.z, AUDIT.radius), nil end
      if not j.F or j.i > j.F.count then j.F, j.i = pager_next(j.pg, body), 1 end
      local F = j.F
      while F and j.i <= F.count do
        local k = j.i
        j.i = k + 1
        n = n + 1
        if F.settled[k] then
          local it = { id = F.ids[k] }
          local px, py, pz = body.x + F.rx[k], body.y + F.ry[k], body.z + F.rz[k]
          local d = terrain.query(px, py, pz)
          if d and math.abs(d) > AUDIT.tol then
            -- (flat answers carry no `up`: ask for this one prop)
            local up = F.up and F.up[k]
            if not up and d > 0 and scatter.instance then
              local row = scatter.instance(sid, it.id)
              up = row and row.up
            end
            up = up or vec3(0, 1, 0)
            local hit = d > 0 and raycast(vec3(px + up.x * 0.3, py + up.y * 0.3, pz + up.z * 0.3),
              vec3(-up.x, -up.y, -up.z), 0.6) or nil
            local key = sr.patch .. "|" .. tostring(sr.sp and sr.sp.id)
            -- a hit is something solid only where the ground is not (the
            -- settling ray reads the collision mesh, which can sit a few
            -- decimetres off the field in a fresh pit)
            -- (a ray that meets the terrain answers with the world's own node,
            -- named for the body: surveyor is_ground)
            local hn = hit and hit.node
            local solid = hn and hn.valid ~= false and hn.name and not space.body(hn.name)
            local hq = solid and terrain.query(hit.x, hit.y, hit.z)
            if hq and hq > 0.15 then
              audit_take(sid, it)             -- on a roof, a craft, debris
            elseif not au.tried[key] and math.abs(d) > AUDIT.redrop then
              au.tried[key] = true
              auditRedropped = auditRedropped + 1
              groundChanged(px, py, pz, 3.0, true)
            end
          end
        end
        if n % 32 == 0 and (clear_wall() - t0) * 1000 >= AUDIT.ms then return end
      end
      if not F then j.si, j.pg, j.F = j.si + 1, nil, nil end
      if (clear_wall() - t0) * 1000 >= AUDIT.ms then return end
    end
  end
  au.job = nil
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
-- Every species of every patch ever built has a list here (cuts_of), so the
-- table grows with the ground walked: an hour on one world is thousands of
-- lists, and this ran over all of them seven times a second, a string match
-- and a table each (the soak probe, 2026-11). Now a list is looked at only
-- when its OLDEST cut is due (lists are oldest first), its key is parsed
-- once, and an empty list whose patch has gone is forgotten (cuts_of reads
-- the save again if the patch comes back).
local cut_keys = {}   -- ck → { pk, spid }
local function regrow()
  for ck, list in pairs(cuts) do
    local kk = cut_keys[ck]
    if not kk then
      local pk, spid = ck:match("^(.*)|(%d+)$")
      kk = { pk, tonumber(spid) }
      cut_keys[ck] = kk
    end
    local pk, spid = kk[1], kk[2]
    local p = patches[pk]
    if #list == 0 then
      if not p then cuts[ck], cut_keys[ck] = nil, nil end
    elseif time - list[1].t >= params.regrow then
      local keep = {}
      for _, c in ipairs(list) do
        if time - c.t < params.regrow then
          keep[#keep + 1] = c
        elseif p then
          if p.srcs[spid] then scatter.restore(p.srcs[spid], c.id) end
          if p.bark[spid] then scatter.restore(p.bark[spid], c.id) end
        end
      end
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

local touch = { bent = {}, n = 0, t = 0, ct = 0 }
touchStats = { bent = 0, obstacles = 0, trunks = 0, rocks = 0 }

local function touch_release(key, b)
  if b.restored == nil and srcs[b.src] then pcall(scatter.restore, b.src, b.inst) end
  if b.node and b.node.valid then b.node:destroy() end
  touch.bent[key] = nil
  touch.n = touch.n - 1
end

-- ENGINE BENDING (touch_engine, rc7's scatter.setInteractors): the crew is a
-- point the props lean away from in the draw, foot planted, with a short wake
-- of fading points behind so the grass springs back over a second instead of
-- snapping up. No nodes, no scatter.remove/restore. Since 0.117.0-rc10 only
-- sources declared with bend > 0 (the BEND_KIND plants, see make_source) give
-- way; rc7-rc9 bent every source in reach, rocks and trunks too, so the radius
-- is still kept inside the bump distance planet_walker holds the crew off
-- trunks and rocks at.
local wake = {}          -- { x, y, z (body-relative), t }
local wake_on = false
local WAKE_STEP, WAKE_LIFE = 0.45, 1.1

-- THE TOOL'S BITE. While a cut or an uproot works at a plant the tool belt
-- calls sawAt every frame with the point it is working; the bendy plants
-- there (grass, ferns, reeds: the sources declared with `bend`) shiver away
-- from a point that jumps about it, so the plant visibly fights the cut.
-- Trunks and rocks never bend (bend = 0), so a tree is left to its felling.
local saw_pt = nil
function sawAt(x, y, z, strength)
  saw_pt = { x = x, y = y, z = z, s = strength or 0.6, t = time }
end

local function touch_engine(astro, body)
  local rx, ry, rz = astro.x - body.x, astro.y - body.y, astro.z - body.z
  local last = wake[#wake]
  if not last or len(rx - last.x, ry - last.y, rz - last.z) >= WAKE_STEP then
    wake[#wake + 1] = { x = rx, y = ry, z = rz, t = time }
  end
  while wake[1] and time - wake[1].t > WAKE_LIFE do table.remove(wake, 1) end
  while #wake > 6 do table.remove(wake, 1) end
  local s = math.tan(params.touch_bend)
  local r = params.touch_r_engine
  local pts = { { pos = vec3(astro.x, astro.y, astro.z), radius = r, strength = s } }
  for i = #wake, 1, -1 do
    local w = wake[i]
    local age = time - w.t
    -- the newest wake point sits on the crew: the live point covers it
    if len(rx - w.x, ry - w.y, rz - w.z) > 0.2 then
      local k = math.exp(-2.2 * age) * 0.5
      if k > 0.04 then
        pts[#pts + 1] = { pos = vec3(body.x + w.x, body.y + w.y, body.z + w.z), radius = r, strength = s * k }
      end
    end
  end
  if saw_pt and time - saw_pt.t < 0.2 and #pts < 30 then
    -- a point that darts round the bite, so the lean flips: a shiver
    local a = time * 37.0
    local jx, jz = math.cos(a) * 0.22, math.sin(a * 1.31) * 0.22
    pts[#pts + 1] = { pos = vec3(saw_pt.x + jx, saw_pt.y, saw_pt.z + jz), radius = 1.1,
                      strength = s * saw_pt.s * (0.55 + 0.45 * math.sin(time * 29.0)) }
  end
  scatter.setInteractors(pts)
  wake_on = true
end
local function touch_engine_off()
  if wake_on then scatter.setInteractors({}); wake_on = false end
  wake = {}
end

function touchClear()
  for key, b in pairs(touch.bent) do touch_release(key, b) end
  touch.bent, touch.n = {}, 0
  obstacles = {}
  if touch_engine_off then touch_engine_off() end
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
                -- A model drawn as it is: its own parts, shaded by the source's
                -- tint (tint_whole: a named part's override would start
                -- untextured).
                tint_whole(n, col)
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
    touch_engine_off()
    return
  end
  if params.touch_engine > 0 and scatter.setInteractors then
    if touch.n > 0 then for key, b in pairs(touch.bent) do touch_release(key, b) end end
    touch_engine(astro, body)
  else
    touch_engine_off()
    touch_drive(astro, body, dt)
    touch.t = touch.t - dt
    if touch.t <= 0 then
      touch.t = 0.1
      local fg = ref("flora_gen")
      local planet = find(cur_body)
      if fg and planet then touch_find(astro, body, fg, planet) end
    end
  end
  touch.ct = touch.ct - dt
  if touch.ct <= 0 and params.touch_bump > 0 then
    touch.ct = 0.2
    touch_obstacles(astro, body)
  end
  touchStats.bent = touch.n
end

function update(node, dt)
  clear_tick()
  if params.enabled ~= 0 and cur_body then audit_tick(observer()) end
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
  -- THE BASE FIRST. On a new save the field used to start a second or more
  -- before the base was laid out: the stands round the spawn were declared
  -- with no clearing, drawn, and then judged and declared again once the
  -- layout came (their density grids changed, so plants well off the paving
  -- went too). Where a base is still to be laid out on this world, the field
  -- waits for it (BASE_WAIT s at the most).
  local bf = ref("base_facilities")
  local bb = save.get("base.body")
  if bf and not (type(bf.footprint) == "table" and bf.footprint.body == bname) and (bb == nil or bb == bname) then
    base_wait_t = base_wait_t or time
    if time - base_wait_t < BASE_WAIT then
      diag("waiting for the base to be laid out")
      return
    end
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
  -- How fast the observer crosses the ground (body-relative), for the wash.
  if obs_last and obs_last.body == bname and time > obs_last.t then
    local v = len(rx - obs_last.x, ry - obs_last.y, rz - obs_last.z) / (time - obs_last.t)
    obs_speed = obs_speed + (v - obs_speed) * 0.5
  end
  obs_last = { body = bname, x = rx, y = ry, z = rz, t = time }
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
        if id == nil and p.dist < far + 5 and built < 1 and not (p.judging and p.judging[sp.id]) then
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
  ground_tick()
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
-- No new wash is laid while the observer crosses the ground faster than this (m/s).
WASH_MAX_SPEED = 12.0
local function wash_alpha(inf, d, range, kalt)
  local kd = math.max(0, math.min(1, (range - d) / (range * 0.4)))
  local ki = math.max(0, math.min(1, (time - (inf[5] or 0)) / WASH_IN))
  return inf[4] * kd * ki * kalt
end
wash = function(body, rx, ry, rz, species, fg, alt, w)
  if params.tint == 0 or not WASH_RELAY_BUDGETED or not (decals and decals.add) or (alt or 0) > params.tint_alt then
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
            if washes[key] == false and wash_lifted[key] and time >= wash_lifted[key] then
              washes[key], wash_lifted[key] = nil, nil
            end
            local held = false
            for _, hr in ipairs(wash_holds) do
              if time < hr.t and len(px - hr.x, py - hr.y, pz - hr.z) < hr.r then held = true break end
            end
            -- (Nothing new is laid while the observer races over the ground:
            -- laying a 29 m mark is the engine fitting it to the terrain in
            -- this call, 30–100 ms on a scale-3 world (rc7), and at speed the
            -- marks would be passed before they had faded in.)
            if washes[key] == nil and not held and added < 2 and wash_n < params.tint_max
               and obs_speed < WASH_MAX_SPEED then
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

-- ── "where is it?" marks only until the plant itself is in ──────────────────
-- The orbs over a rare plant and the glow motes round a glowing one were drawn
-- whether or not the plant was. Right after a load, before a plant's model has
-- streamed in, they are the only sign of it (the playtest found a rare plant
-- by its dot that way), but once the plant is drawn they read as a marker dot
-- hanging on it (playtest 2026-10-27). So each mark now shows only until the
-- plant's model and its textures are in (assets.warm calls back), then fades
-- out over MARK_FADE seconds. `markAlpha(path)` is 1 while loading, then 1 → 0.
MARK_FADE, MARK_GRACE = 1.5, 0.4
local MARK_TEX = { "textures/flora/foliage_l0.png", "textures/flora/foliage_n.png", "textures/flora/foliage_glow.png" }
local warm_at = {}      -- model path -> time it was ready (false while loading)
function markAlpha(path)
  if not path then return 1 end
  local w = warm_at[path]
  if w == nil then
    warm_at[path] = false
    local list = { path }
    for _, t in ipairs(MARK_TEX) do list[#list + 1] = t end
    local fn = assets and assets.warm
    local ok = fn and pcall(fn, list, function() warm_at[path] = time or 0 end)
    if not ok then warm_at[path] = time or 0 end
    return 1
  end
  if not w then return 1 end
  return math.max(0, math.min(1, 1 - ((time or 0) - w - MARK_GRACE) / MARK_FADE))
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

-- ── felling: a cut tree comes down ─────────────────────────────────────────
-- The scatter instance is gone the moment it is harvested. A stand-in from the
-- same prefab (a display copy: no body, no collider), at the same root, size
-- and tint, topples away from the cutter about its root — slow, then fast, as
-- a tree goes — lies a moment, and sinks away in a burst of leaves. At most a
-- few at once; anything that is not a tree simply pops (the tool's vfx).
local felled = {}
local FELL_T, FELL_HOLD, FELL_SINK, FELL_MAX = 1.5, 0.8, 0.7, 3
-- The LOGS a felling leaves: a LooseLog body (prefabs/LooseLog, an assembly
-- the gravity gun lifts and the depot takes as timber) laid along the fallen
-- trunk the moment the crown lands, sized to the tree. A few at a time; the
-- oldest goes when another falls.
-- EACH LOG IS KEPT BY ITS OWN NAME ("LooseLog <n>"), not by its handle alone:
-- the depot or the pack takes a log away (tool_belt destroys it), and a
-- script's handle is the engine's bare slot number, handed to the next node
-- spawned — the oldest's handle read `valid` again on some other node, which
-- was destroyed in its place (engine card 0552). A log goes only if the node
-- still answers to its name.
-- A tree leaves as many logs as its trunk makes (a 3 m section per ~4.5 m of
-- tree, up to four), each sized to the tree, tagged with what it is
-- (materials.tagResource: timber, units by its size) and adopted by
-- mineral_field, which keeps the world's loose bodies in the save. LOG_MAX
-- counts sections; the registry caps every loose body together.
local logs = {}
LOG_MAX = 16   -- (published: the stale-handle smoke fills it)
local log_seq = 0
function logCount() return #logs end

local function fell_pose(f, n, ang, sink)
  local c, s = math.cos(ang), math.sin(ang)
  local ux, uy, uz = f.ux * c + f.hx * s, f.uy * c + f.hy * s, f.uz * c + f.hz * s
  local fx, fy, fz = f.hx * c - f.ux * s, f.hy * c - f.uy * s, f.hz * c - f.uz * s
  n.x, n.y, n.z = f.rx - f.ux * sink * 0.6, f.ry - f.uy * sink * 0.6, f.rz - f.uz * sink * 0.6
  n:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz))
  local k = f.scale * (1 - 0.85 * sink)
  n.scale_x, n.scale_y, n.scale_z = k, k, k
end

-- A stand-in's tint, over its OWN look. NOT node:material("leaf"): a named
-- part's override "starts as the engine's default material, not as the part's
-- imported look" (lua-api node:material), so writing its colour drew a felled
-- tree in flat green leaves and a plain tan trunk, untextured (playtest
-- 2026-10-27). A flora prefab's node carries its own Material (the leaf or
-- bark texture and normal map the scatter draws it with, tools/
-- gen_flora_prefabs.py): its colour is set there and the rest is kept. A bare
-- model has none, and setMaterial on it changes only the keys given over each
-- part's own look (textures, cut-out leaves) — so the colour goes that way.
--
-- WHY IT IS A TINT NOW (playtest 2026-11: "brushing against a bush makes its
-- textures disappear"). A bush has no prefab: its bend node is createNode +
-- `n.model = …`, and the colour went through setMaterial in the same
-- callback. The engine applies a pass's setMaterial BEFORE that pass's model
-- swap (floptle-script host.rs flush_writes: rich sets, then model_changes),
-- so it met an Empty node, not a model, and gave it a whole default Material
-- of its own — which supersedes every part's imported look: the bush drew
-- flat, untextured, until it was handed back (engine card draft in the
-- report). node:setTint is a separate component, a multiply over whatever the
-- node draws, which is exactly what the scatter's `tint` does to the
-- instance it stands in for — so the stand-in now matches it, textures and
-- prefab colours kept, whatever order the engine applies things in.
function tint_whole(n, tint)
  local col = { tint[1], tint[2], tint[3] }
  if n.setTint and pcall(n.setTint, n, col) then return end
  local done = pcall(function()
    local m = n:material()
    if not (m and m.texture and m.texture ~= "") then error("no material of its own") end
    m.color = col
  end)
  if not done then pcall(n.setMaterial, n, { color = col }) end
end

-- `hit` is a nearestPlant answer (before or after harvest); (dx,dy,dz) the
-- way the cut went through it — the tree falls that way. Returns true when a
-- tree is coming down.
function fell(hit, dx, dy, dz)
  local rec = hit and hit.rec
  if not (rec and rec.sp and rec.sp.form == "tree") or rec.rare then return false end
  if #felled >= FELL_MAX or not spawn then return false end
  local planet = cur_body and find(cur_body)
  local body = cur_body and space.body(cur_body)
  local fg = ref("flora_gen")
  if not (planet and body and fg and fg.assetFor) then return false end
  local ux, uy, uz = hit.ux or 0, hit.uy or 1, hit.uz or 0
  local d = dx * ux + dy * uy + dz * uz
  local hx, hy, hz = dx - ux * d, dy - uy * d, dz - uz * d
  local hl = len(hx, hy, hz)
  if hl < 1e-3 then return false end
  local f = { rx = hit.x - body.x, ry = hit.y - body.y, rz = hit.z - body.z, ux = ux, uy = uy, uz = uz,
              hx = hx / hl, hy = hy / hl, hz = hz / hl, t0 = time, scale = rec.scale or 1,
              height = hit.height or 4, sp = rec.sp, parts = {}, body = cur_body }
  felled[#felled + 1] = f
  local list = { fg.assetFor(rec.sp, 0) }
  if rec.sp.twin then list[#list + 1] = fg.assetFor(rec.sp, 0, "bark") end
  for i, a in ipairs(list) do
    local tint = (i == 2) and rec.sp.barkTint or rec.sp.tint
    local function took(n)
      if f.done then n:destroy() return end
      if n.setParent and n.parent ~= planet then n:setParent(planet, { keepWorld = false }) end
      n.tags = { "flora" }
      if tint then tint_whole(n, tint) end
      fell_pose(f, n, 0, 0)
      f.parts[#f.parts + 1] = n
    end
    local pf = a:match("^prefabs/(.-)%.prefab%.ron$")
    if pf then
      spawn(pf, vec3(hit.x, hit.y, hit.z), took, { parent = planet, body = false })
    else
      createNode("Felled " .. tostring(rec.sp.name), planet, function(n) n.model = a; took(n) end)
    end
  end
  return true
end

-- For probes: trees coming down right now.
function felling() return #felled end
-- For probes: the stand-ins of the trees coming down.
function fellingParts()
  local out = {}
  for _, f in ipairs(felled) do
    for _, n in ipairs(f.parts) do if n.valid then out[#out + 1] = n end end
  end
  return out
end

local function fell_tick()
  if #felled == 0 then return end
  local fx = ref("vfx")
  local body = cur_body and space.body(cur_body)
  for i = #felled, 1, -1 do
    local f = felled[i]
    local k = time - f.t0
    local a = math.min(1, k / FELL_T)
    local ang = a * a * 1.48
    local sink = math.max(0, math.min(1, (k - FELL_T - FELL_HOLD) / FELL_SINK))
    if a >= 1 and not f.landed then
      f.landed = true
      -- the crown hits the ground: leaves and dust along the trunk
      if fx and fx.harvest and body then
        for _, t in ipairs({ 0.45, 0.8 }) do
          local h = f.height * t
          fx.harvest(body.x + f.rx + f.hx * h, body.y + f.ry + f.hy * h, body.z + f.rz + f.hz * h, 1.5)
        end
      end
      -- ...and the trunk is left lying there in logs, end to end along the
      -- fall: as many sections as the trunk was long (a 3 m log per ~4.5 m
      -- of tree, up to four), thicker for a bigger tree.
      if body and spawn and f.height >= 3.0 then
        local count = math.max(1, math.min(4, math.floor(f.height / 4.5 + 0.5)))
        local k = math.max(0.6, math.min(1.6, 0.45 + f.height / 14.0))
        local seg = 2.96 * k + 0.25
        local mats, mf = ref("materials"), ref("mineral_field")
        -- timber by the log's wood: a 3 m section at scale 1 is 3 units,
        -- growing with its volume (k³)
        local units = math.max(1, math.floor(3 * k * k * k + 0.5))
        for i = 1, count do
          while #logs >= LOG_MAX do
            local old = table.remove(logs, 1)
            if old and old.n.valid and old.n.name == old.name then old.n:destroy() end
          end
          local along = seg * (i - 0.5) + 0.6
          local lift = 0.35 * k + 0.05 * i
          local lx = body.x + f.rx + f.hx * along + f.ux * lift
          local ly = body.y + f.ry + f.hy * along + f.uy * lift
          local lz = body.z + f.rz + f.hz * along + f.uz * lift
          local slot = #logs + 1
          logs[slot] = false
          local ux, uy, uz, hx, hy, hz = f.ux, f.uy, f.uz, f.hx, f.hy, f.hz
          local kk = k * (1 - 0.12 * (i - 1))   -- the crown end is thinner
          spawn("LooseLog", vec3(lx, ly, lz), function(n)
            log_seq = log_seq + 1
            local nm = "LooseLog " .. log_seq
            n.name = nm
            logs[slot] = { n = n, name = nm }
            n.scale = kk
            -- the log's long axis is its X: setUp(up, fwd) puts Y up and Z on
            -- fwd, and X = up × fwd, so fwd = h × up lays X along the fall
            local fx_, fy_, fz_ = hy * uz - hz * uy, hz * ux - hx * uz, hx * uy - hy * ux
            if n.setUp then n:setUp(vec3(ux, uy, uz), vec3(fx_, fy_, fz_)) end
            if mf and mf.adoptBody then mf.adoptBody(n, "LooseLog", "timber", units, kk)
            elseif mats and mats.tagResource then mats.tagResource(n, "timber", units) end
            if assembly and assembly.rebuild then assembly.rebuild(n) end
          end)
        end
      end
      if audio and audio.play then
        audio.play("audio/kenney/impact/impactWood_heavy_00" .. tostring(math.random(0, 4)) .. ".ogg",
          { track = "SFX", volume = 0.6, pitch = 0.7 + math.random() * 0.15 })
      end
    end
    for _, n in ipairs(f.parts) do if n.valid then fell_pose(f, n, ang, sink) end end
    if sink >= 1 or f.body ~= cur_body then
      f.done = true
      for _, n in ipairs(f.parts) do if n.valid then n:destroy() end end
      table.remove(felled, i)
    end
  end
end

function lateUpdate(node, dt)
  fell_tick()
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
      local F = near_flat(id, vec3(obs.x, obs.y, obs.z), params.mote_range + 20)
      for k = 1, math.min(F.count, 6) do
        local h = { id = F.ids[k], pos = { x = F.x[k], y = F.y[k], z = F.z[k] }, scale = F.scale[k],
                    settled = F.settled[k], distance = F.distance[k] }
        spots[#spots + 1] = { id = id, h = h, sp = s.sp, p = p, d = h.distance }
      end
    end
  end
  table.sort(spots, function(a, b) return a.d < b.d end)
  local used = 0
  local fgm = ref("flora_gen")
  for _, s in ipairs(spots) do
    if used >= #motes then break end
    local m = motes[used + 1]
    -- (only a plant not drawn yet is marked: see markAlpha)
    local ma = 1
    if fgm and fgm.modelFor then
      ma = markAlpha(fgm.modelFor(s.sp, 0, srcs[s.id] and srcs[s.id].part))
      if s.h.settled == false then ma = 1 end
    end
    if ma <= 0.01 then m = nil end
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
                      emissiveStrength = s.sp.glow or 0.5, alpha = ma }
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
-- the scene goes: the beam mesh with it (the engine keeps a built mesh until
-- mesh.free or Stop, so every load used to leave one behind)
function onDestroy()
  if beam_mesh and mesh and mesh.free then pcall(mesh.free, beam_mesh) end
  beam_mesh = nil
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
    local r = { p = p, node = nil, model = ref("flora_gen") and ref("flora_gen").modelFor(sp, 0) or nil }
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
  -- The orbs: a mark only until the plant itself is drawn (markAlpha).
  for _, r in pairs(rare.nodes) do
    if r.orbs then
      local a = markAlpha(r.model)
      a = math.floor(a * 20 + 0.5) / 20
      if a ~= r.orb_a then
        r.orb_a = a
        for i, o in ipairs(r.orbs) do
          if o.valid then
            o.visible = a > 0
            if a > 0 then
              local ok, m = pcall(o.material, o)
              if ok and m then m.alpha = ((i == 1) and 0.8 or 0.9) * a end
            end
          end
        end
      end
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

-- The world's rare record, as rare_tick reads it EVERY FRAME: a save.get
-- copies the whole table (every plant and pocket) each time, so it is kept
-- here, written through by this script's own writes and read again from the
-- save every few seconds (or for another body).
local rare_rec = { body = nil, d = nil, t = -100 }
local function rare_saved(bname)
  if rare_rec.body ~= bname or time - rare_rec.t > 4.0 or time < rare_rec.t then
    rare_rec.body, rare_rec.d, rare_rec.t = bname, save.get("rare." .. bname), time
  end
  return rare_rec.d
end
local function rare_store(bname, d)
  save.set("rare." .. bname, d)
  rare_rec.body, rare_rec.d, rare_rec.t = bname, d, time
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
  local d = rare_saved(bname)
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
      rare_store(bname, res)
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
      rare_store(bname, d)
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
        -- One edit a frame: a grotto is two bites, and each is a terrain edit
        -- the engine applies on the spot, so the scan (a coroutine that
        -- already yields between field reads) yields after each bite too,
        -- rather than making both, and the reads after them, in one frame.
        dig = function(x, y, z, r)
          terrain.dig(rare.bx + x, rare.by + y, rare.bz + z, r)
          groundChanged(rare.bx + x, rare.by + y, rare.bz + z, r)
          if coroutine.isyieldable == nil or coroutine.isyieldable() then coroutine.yield("running") end
        end
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
      rare_store(bname, d)
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

-- The rare plant on the aim line, scored like a scattered one (see
-- `nearestPlant`: the same span, the same exact axis test).
local function rare_aim(body, x, y, z, dx, dy, dz, t0, t1, reach, cone, grab, opt)
  local best, bestScore = nil, -math.huge
  local from = opt and opt.from
  local lim = (opt and opt.reach) or reach
  for key, r in pairs(rare.nodes) do
    if r.node and r.node.valid and r.node.visible ~= false and not r.p.cut then
      local p = r.p
      local wx, wy, wz = body.x + p.x, body.y + p.y, body.z + p.z
      local ex, ey, ez = wx - x, wy - y, wz - z
      local d = len(ex, ey, ez)
      local fd = from and len(wx - from.x, wy - from.y, wz - from.z) or d
      if d > 0.01 and fd <= lim then
        local dot = (ex * dx + ey * dy + ez * dz) / d
        local hgt = math.max(0.5, p.sp.height or 1)
        local near_, t, s = axisDistance(x, y, z, dx, dy, dz, t0, t1, wx, wy, wz, p.ux, p.uy, p.uz, hgt)
        local g = grab * 1.3
        if (near_ <= g and (t > t0 + 0.05 or dot > 0)) or dot >= cone then
          -- A rare plant wins a tie with the grass round it.
          local score = (1 - math.min(near_, g) / g) * 2.0 - (t - t0) / (t1 - t0 + 1) + 0.5
          if score > bestScore then
            bestScore = score
            best = { pid = "rare:" .. key, dist = d, t = t, gap = near_,
                     x = wx, y = wy, z = wz, ax = wx + p.ux * s, ay = wy + p.uy * s, az = wz + p.uz * s,
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

-- ── terrain edits: keep the wash out of the way ─────────────────────────────
-- The engine lays every decal whose ground an edit touches again, and repacks
-- and re-uploads that picture's whole batch, OUTSIDE every perf bucket. A
-- turf wash is 29 m across, so every laser bite on a meadow re-laid several
-- of them against full-detail collision and rebuilt all ~150: measured in play
-- on rc6, 120–980 ms a frame while the trigger was held, against 1–2 ms with
-- the wash gone (tools agent, 2026-10-23). The tool belt calls this once per
-- place it starts cutting or filling: the washes within `r` of the point are
-- lifted (one batch rebuild), none is laid there for `hold` seconds after the
-- LAST call, and then the normal pass lays them again on the new ground.
function liftWash(x, y, z, r, hold)
  local body = cur_body and space.body(cur_body)
  if not body then return 0 end
  r, hold = r or 36.0, hold or 8.0
  local bx, by, bz = x - body.x, y - body.y, z - body.z
  local until_t = time + hold
  local kept = false
  for _, hr in ipairs(wash_holds) do
    if len(bx - hr.x, by - hr.y, bz - hr.z) < 6.0 then hr.t, kept = until_t, true end
  end
  if not kept then wash_holds[#wash_holds + 1] = { x = bx, y = by, z = bz, r = r, t = until_t } end
  for i = #wash_holds, 1, -1 do if time >= wash_holds[i].t then table.remove(wash_holds, i) end end
  local n = 0
  for key, id in pairs(washes) do
    local inf = wash_info[key]
    if id and inf and len(inf[1] - bx, inf[2] - by, inf[3] - bz) < r then
      decals.remove(id)
      washes[key], wash_info[key] = false, nil
      wash_lifted[key] = until_t   -- may be laid again once the region's hold is over
      wash_n = wash_n - 1
      n = n + 1
    end
  end
  return n
end

-- ── harvest API (the tool belt calls these) ─────────────────────────────────

-- ── the aim test (the gravity gun's uproot and the laser's CUT share it) ──
--
-- Scattered plants have no colliders, so this IS the aim test: the AIM LINE
-- against each candidate's own axis (root to tip), with `grab` a radius in
-- metres — "does the line go through the tree".

-- Closest approach between the aim segment o + d·t (t in [t0, t1], |d| = 1)
-- and a plant's axis r + u·s (s in [0, h], |u| = 1): the distance, t and s.
-- Exact. (It was five samples a quarter of the height apart: a 20 m tree
-- aimed at chest-high was 1.2 m from its nearest sample and never found.)
function axisDistance(ox, oy, oz, dx, dy, dz, t0, t1, rx, ry, rz, ux, uy, uz, h)
  local wx, wy, wz = ox - rx, oy - ry, oz - rz
  local b = dx * ux + dy * uy + dz * uz
  local dd = dx * wx + dy * wy + dz * wz
  local e = ux * wx + uy * wy + uz * wz
  local den = 1 - b * b
  local t = den > 1e-9 and (b * e - dd) / den or t0
  t = math.max(t0, math.min(t1, t))
  local s = math.max(0, math.min(h, e + b * t))
  t = math.max(t0, math.min(t1, b * s - dd))
  s = math.max(0, math.min(h, e + b * t))
  local qx, qy, qz = wx + dx * t - ux * s, wy + dy * t - uy * s, wz + dz * t - uz * s
  return len(qx, qy, qz), t, s
end

-- How far off its axis a plant still counts as hit: its WHOLE BODY, not its
-- stem. A tree's crown over its upper two thirds (aim at the leaves and you
-- have the tree), a shrub's or a fungus's spread, a grass tuft's blades; the
-- trunk itself a little wider than `grab`, the floor. (Playtest 2026-10-24:
-- "I can't cut plants anywhere but at their stems".) The aim scores by how
-- central the line passes, so among neighbours the one whose axis is nearest
-- still wins — the axis is the tiebreak, the body is the hit.
local SPREAD = { tree = 0.28, shrub = 0.5, grass = 0.45, succulent = 0.38, fungus = 0.45, spire = 0.22, kelp = 0.3 }
function girthOf(sp, hgt, s, grab)
  local f = (sp and sp.form) or "shrub"
  local k = SPREAD[f] or 0.4
  if f == "tree" then
    if s > hgt * 0.35 then return math.max(grab, math.min(4.0, hgt * k)) end
    return math.max(grab, 0.25 + hgt * 0.03)
  end
  return math.max(grab, math.min(2.5, hgt * k + 0.15))
end
local girth = girthOf

-- The span of the aim line to search: [0, reach] from its origin, or — given
-- `opt.from` (the crew) — the part of the line within `opt.reach` of the crew,
-- plus a crown's worth: a third-person camera's line starts metres behind.
local function aim_span(x, y, z, dx, dy, dz, reach, opt)
  if not (opt and opt.from) then return 0, reach end
  local f = opt.from
  local R = (opt.reach or reach) + (opt.crown or 3.0)
  local wx, wy, wz = x - f.x, y - f.y, z - f.z
  local b = dx * wx + dy * wy + dz * wz
  local disc = b * b - (wx * wx + wy * wy + wz * wz - R * R)
  if disc < 0 then return nil end
  local sq = math.sqrt(disc)
  local t0, t1 = math.max(0, -b - sq), -b + sq
  if t1 <= t0 then return nil end
  return t0, t1
end

-- WHERE TO ASK `scatter.near`. The engine picks a source's chunks by how high
-- the asking point stands over the region's PLANE, a whole chunk at a time
-- (floptle-core scatter.rs `chunks_near`, the draw's height band): a point
-- more than about radius + one chunk off the plane finds nothing — not even a
-- plant asked for at the very place `near` reported it. A flora patch is a
-- plane tangent at its centre, so on a hill, or out toward a patch's edge, the
-- ground and every plant on it stand tens of metres off it (measured on a
-- fresh save: 37–40 m in a forest, where every tree and shrub was
-- unharvestable — playtest 2026-10-24 "completely unable to mine plants").
-- Asking from the aim itself (2026-10-23's phantom-plant fix) hit that; asking
-- from the plane (before it) missed plants whose landed place was further
-- from the plane than the radius. So: ask from a point between the plane and
-- the ground, as near the ground as the band allows, with a radius that
-- reaches `rh` across the ground there (± `slack` of slope).
-- Since 0.117.0-rc20 the engine picks scatter chunks by where over the region
-- the point is, not by its height over the plane (card 0523): ask at the aim
-- point itself and the plane dance below is history. An older engine keeps it.
local function engine_at_least(maj, min, pat, rc)
  local v = app and app.version and app.version()
  if type(v) ~= "string" then return false end
  local a, b, c, r = v:match("^(%d+)%.(%d+)%.(%d+)%-rc(%d+)")
  if not a then a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)") end
  if not a then return false end
  local have = { tonumber(a), tonumber(b), tonumber(c), r and tonumber(r) or math.huge }
  local want = { maj, min, pat, rc or math.huge }
  for i = 1, 4 do
    if have[i] ~= want[i] then return have[i] > want[i] end
  end
  return true
end
NEAR_BY_POSITION = engine_at_least(0, 117, 0, 20)
-- The ground wash (params.tint, the "Ground wash" header) is only drawn on an
-- engine whose decal re-lay is budgeted and regional (0.117.0-rc22, card
-- 0525); before that, streaming re-laid every wash in range, one a frame at
-- 12-34 ms, so `wash` keeps the washes off however `tint` is set.
WASH_RELAY_BUDGETED = engine_at_least(0, 117, 0, 22)
-- The engine re-drops the props under a script's terrain edit itself, through
-- the planet's frame as it is when the edit lands (0.117.1, 91e97ff): an edit
-- needs no redeclare from here (see groundChanged). Read by mineral_field.
ENGINE_RESETTLES_EDITS = engine_at_least(0, 117, 1)

local function near_query(p, mx, my, mz, gx, gy, gz, rh, slack, chunk)
  if NEAR_BY_POSITION then return mx, my, mz, rh + slack end
  local dx, dy, dz = mx - p.cx, my - p.cy, mz - p.cz
  local lx = dx * p.ex[1] + dy * p.ex[2] + dz * p.ex[3]
  local lz = dx * p.ez[1] + dy * p.ez[2] + dz * p.ez[3]
  -- the ground's height over the plane, under the middle of the search
  local ly = (gx - p.cx) * p.ey[1] + (gy - p.cy) * p.ey[2] + (gz - p.cz) * p.ey[3]
  local a = math.abs(ly)
  local g = math.max(0, (a - chunk) * 0.5 + 0.5)      -- the gap left between the point and the ground
  local h = (a - g) * (ly < 0 and -1 or 1)
  local r = math.sqrt(rh * rh + (g + slack) * (g + slack))
  return p.cx + p.ex[1] * lx + p.ey[1] * h + p.ez[1] * lz,
         p.cy + p.ex[2] * lx + p.ey[2] * h + p.ez[2] * lz,
         p.cz + p.ex[3] * lx + p.ey[3] * h + p.ez[3] * lz, r
end
nearQuery = near_query   -- for the smoke test

-- The plant on the aim line (x,y,z + t·d). `cone` > 1 is an AIM: only a plant
-- the line passes within `grab` of; `cone` <= 1 is a SWEEP round the origin
-- that also takes anything within `reach` at least that far ahead.
-- `opt` (optional): { from = crew position, reach = metres from the crew to a
-- plant's root, tall = only plants at least this tall }; with `from` only the
-- part of the line near the crew is searched.
-- Returns { pid, x,y,z (root), ax,ay,az (where the line meets it), height,
-- ux,uy,uz, t, gap, rec } or nil.
function nearestPlant(x, y, z, dx, dy, dz, reach, cone, grab, opt)
  reach = reach or 4.5
  cone = cone or 0.55
  grab = grab or 1.4
  local dl = len(dx, dy, dz)
  if dl < 1e-9 then return nil end
  dx, dy, dz = dx / dl, dy / dl, dz / dl
  local body = cur_body and space.body(cur_body)
  if not body and rare.body then body = space.body(rare.body) end
  if not body then return nil end
  local t0, t1 = aim_span(x, y, z, dx, dy, dz, reach, opt)
  if not t0 then return nil end
  local from = opt and opt.from
  local lim = (opt and opt.reach) or reach
  local best, bestScore = nil, -math.huge
  if rare.body and next(rare.nodes) then
    best, bestScore = rare_aim(space.body(rare.body) or body, x, y, z, dx, dy, dz, t0, t1, reach, cone, grab, opt)
  end
  local rx, ry, rz = x - body.x, y - body.y, z - body.z
  -- Ask round the origin for a sweep, round the middle of the span for an aim.
  local mx, my, mz, rh
  if cone <= 1 then
    mx, my, mz, rh = rx, ry, rz, reach
  else
    local tm = (t0 + t1) * 0.5
    mx, my, mz = rx + dx * tm, ry + dy * tm, rz + dz * tm
    rh = (t1 - t0) * 0.5 + grab + 2.5
  end
  local gx, gy, gz = ground_under(body, mx, my, mz)
  local slack = 1.5 + 0.35 * rh
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and s.part ~= "bark" and patch_dist(p, mx, my, mz) <= rh + 2 then
      local qx, qy, qz, qr = near_query(p, mx, my, mz, gx, gy, gz, rh, slack, s.sp.chunk or 10)
      local F = near_flat(id, vec3(body.x + qx, body.y + qy, body.z + qz), qr)
      -- PHANTOM PLANTS (playtest 2026-10-23, "Ulmash Blade" harvested off bare
      -- rock). `near` answers instances that are not drawn: ones never
      -- settled (`settled = false`, at the region's nominal surface), and —
      -- engine side — ones whose re-settle after a dig found no ground, which
      -- keep their OLD landed place. So: only settled plants, at the engine's
      -- landed place, and only where there is still ground at its root.
      for k = 1, math.min(F.count, 160) do
        if F.settled[k] then
          local wx, wy, wz = F.x[k], F.y[k], F.z[k]
          local q = terrain and terrain.query and terrain.query(wx, wy, wz)
          if q and q < 0.7 and q > -1.2 then
            local hid, hsc = F.ids[k], F.scale[k] or 1
            local ex, ey, ez = wx - x, wy - y, wz - z
            local d = len(ex, ey, ez)
            local fd = from and len(wx - from.x, wy - from.y, wz - from.z) or d
            if d > 0.01 and fd <= lim then
              local dot = (ex * dx + ey * dy + ez * dz) / d
              local g1, g2, g3 = wx - body.x, wy - body.y, wz - body.z
              local gl = len(g1, g2, g3)
              local ux, uy, uz = g1 / gl, g2 / gl, g3 / gl
              local hgt = math.max(0.4, (s.sp.height or 1.0) * hsc)
              -- `opt.tall`: only plants at least this tall (a stem to cut,
              -- not the grass tuft the line also grazes on its way to it)
              local short = opt and opt.tall and hgt < opt.tall
              local near_, t, sa = axisDistance(x, y, z, dx, dy, dz, t0, t1, wx, wy, wz, ux, uy, uz, hgt)
              local gr = girth(s.sp, hgt, sa, grab)
              -- On the line ahead (not the root ahead: aimed up a trunk from
              -- beside it, the root is behind and below the eye).
              if not short and ((near_ <= gr and (t > t0 + 0.05 or dot > 0)) or dot >= cone) then
                local score = (1 - math.min(near_, gr) / gr) * 2.0 - (t - t0) / (t1 - t0 + 1)
                if score > bestScore then
                  bestScore = score
                  local dx_, dy_, dz_ = g1 - p.cx, g2 - p.cy, g3 - p.cz
                  best = { pid = id .. ":" .. tostring(hid), dist = d, t = t, gap = near_, x = wx, y = wy, z = wz,
                           ax = wx + ux * sa, ay = wy + uy * sa, az = wz + uz * sa,
                           height = hgt, ux = ux, uy = uy, uz = uz,
                           rec = { sp = s.sp, src = id, inst = hid, patch = s.patch,
                                   lx = dx_ * p.ex[1] + dy_ * p.ex[2] + dz_ * p.ex[3],
                                   lz = dx_ * p.ez[1] + dy_ * p.ez[2] + dz_ * p.ez[3],
                                   seedn = hid % 2147483647, rx = g1, ry = g2, rz = g3,
                                   scale = hsc, yaw = F.yaw[k] } }
                end
              end
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
  if not rec then return {}, 0 end
  -- THE STAND AS IT IS NOW, not as it was when the aim found the plant. An
  -- uproot or a cut takes seconds, and the stand can be declared again in
  -- them (a re-drop, a re-settle): the source the aim answered from is then
  -- retiring or gone, and asking only after it left the plant standing in
  -- the new source, harvested and still there (playtest 2026-10-27, "plants
  -- sometimes don't disappear after being pulled or cut"). The same id is the
  -- same plant in every declaration of the stand, so it is taken out of the
  -- current source, the trunk's twin, and every retiring one.
  local p = rec.patch and patches[rec.patch]
  local cur = p and rec.sp and p.srcs[rec.sp.id] or nil
  if cur and not srcs[cur] then cur = nil end
  if not (srcs[rec.src] or cur) then return {}, 0 end
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
  if srcs[rec.src] then scatter.remove(rec.src, rec.inst) end
  if cur and cur ~= rec.src then scatter.remove(cur, rec.inst) end
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
      if cur then scatter.restore(cur, old.id) end
      if p.bark[rec.sp.id] then scatter.restore(p.bark[rec.sp.id], old.id) end
    end
    save_cuts(rec.patch, rec.sp.id)
  end
  -- A plant swapped for a bending node (touch) is the instance this took:
  -- the node goes too, or it stands on where the plant was cut.
  for key, b in pairs(touch.bent) do
    if b.inst == rec.inst and (b.src == rec.src or b.src == cur) then
      b.restored = true      -- (nothing to hand back: it was cut)
      touch_release(key, b)
    end
  end
  settled[rec.src .. ":" .. tostring(rec.inst)] = nil
  return got, dropped
end

-- For probes: what a scatter source id is to this field (nil = not ours).
function sourceInfo(id)
  local s = srcs[id]
  if not s then
    for _, r in ipairs(retiring) do
      if r.id == id then return { retiring = true, patch = r.pk, spid = r.spid } end
    end
    return nil
  end
  local p = patches[s.patch]
  return { patch = s.patch, spid = s.sp.id, name = s.sp.name, part = s.part, made = s.made,
           current = p ~= nil and (p.srcs[s.sp.id] == id or p.bark[s.sp.id] == id) }
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
      local n = near_flat(id, vec3(x, y, z), radius).count
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

-- ── ground audit (probes, the debug console) ────────────────────────────────
-- Every settled prop within `radius` of a WORLD point, measured against the
-- terrain where it stands: terrain.query at the prop's root is its height
-- over (+) or under (−) the ground. → { checked, floating, buried, worst,
-- examples = { { src, id, d, kind, x, y, z }, ... } } (tol: metres, 0.3).
function groundAudit(x, y, z, radius, tol)
  tol = tol or 0.3
  local out = { checked = 0, floating = 0, buried = 0, worst = 0, examples = {}, props = {} }
  local body = cur_body and space.body(cur_body)
  if not (body and scatter and scatter.near) then return out end
  for id, s in pairs(srcs) do
    local p = patches[s.patch]
    if p and s.part ~= "bark" and patch_dist(p, x - body.x, y - body.y, z - body.z) <= radius then
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
                out.examples[#out.examples + 1] = { src = id, id = hid, d = d, kind = s.sp.kind, x = hx, y = hy, z = hz }
              end
            end
            if #out.props < 400 then
              out.props[#out.props + 1] = { src = id, id = hid, d = d, kind = s.sp.kind, x = hx, y = hy, z = hz,
                                            height = (s.sp.height or 1.0) * (F.scale[k] or 1), name = s.sp.name }
            end
          end
        end
      end
    end
  end
  return out
end
