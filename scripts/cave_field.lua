-- CAVE FIELD — which kind of cave you are in, and what it is dressed with
-- (worlds plan W4, work/worlds/PLAN.md §4.3 and §5.3; docs/worlds-and-caves.md
-- §3).
--
-- Ty (2026-11-10): "I dig and find cool caves but they're all made of the same
-- few rocks and formations so it gets boring fast... make more scary feeling
-- and unique caves." Generator 4 cuts every cave with one recipe, so on it a
-- cave's KIND (scripts/cave_kinds.lua: lava tube, ice, karst, geode, salt,
-- vent, collapse, chasm) is what this script makes of it:
--
--   PROBE       twice a second round the crew's eye: the enclosure
--               (underground.lua's rays, not cast twice), the roof and floor
--               (two rays: `height`), the rock overhead (one ray down from
--               above the ground: `depth`), the drop ahead (one ray), and the
--               kind of the ~120 m region the eye is in (cave_kinds.regionOf,
--               from the world's formation, depth and seed). Publishes the
--               hooks below.
--   FORMATIONS  nodes from models/cave/ (tools/gen_cave_props.py) hung from
--               the roof, stood on the floor and laid on the walls of the cave
--               round you: at most MAX_NODES within REACH m, the nearest,
--               each a model at LOD 0 near and LOD 1 past LOD_FAR, tinted by
--               its kind. They are found by rays from points in 10 m cells
--               (a point in the cave's air, then up to its roof, down to its
--               floor, out to a wall), a few rays a frame, ONCE per cell:
--               the placements are saved (`cave.cells.<body>`), so a cave keeps
--               its stalactites where they were. Held body-local and drawn as
--               children of the planet's node (docs/positions-and-frames.md
--               rule 1: the planet moves metres a tick). A formation whose
--               rock is dug away goes, and stays gone.
--   MARKS       decals on the walls: drip stains, soot, frost, sulfur, salt,
--               cracks, by kind; at most MAX_DECALS within DECAL_REACH m, none
--               within 6 m of an ore vein (the player digs there).
--   NO PAINT    nothing here paints the terrain (0658: a paint pins its chunk).
--
-- Hooks (findScript("cave_field")), PLAN §5.3:
--   caveKind    "lava_tube" | "ice" | "karst" | "geode" | "salt" | "vent" |
--               "collapse" | "chasm" | nil (not in a cave). PLAN §5.3 calls it
--               `cave.kind`; a script handle's `kind` is the engine's (the
--               script's own name) and cannot be shadowed.
--   label       its name ("Lava tube")
--   enclosure   0 open sky … 1 sealed (underground.enclosed)
--   height      roof − floor at the eye (m), nil where either is out of reach
--   depth       metres of rock over the eye (to the undisturbed ground above)
--   air         { CO2=, SO2=, H2S=, … } bar the cave adds (nil: the world's)
--   hazard      { unstable, cold, heat, dose, drop, gas, flood, … }
--   cells()     the region cells visited on this body (the map's trail, W6)
--   airAt(x, y, z), kindAt(x, y, z)   at a world point (W5's atmo hook:
--               cave_hazards' air cells where it runs)
--   stats       { nodes, records, decals, rays, ms } (probes)
--   (W5, for cave_hazards on the same probe, no rays of its own) probeN
--   (counts probes), eyeLocal, roofLocal (the up ray's hit), aheadLocal (the
--   drop ray's hit), all BODY-LOCAL {x, y, z} on probeBody

defaults = {
  on = true,
  --- Formation nodes kept at most, the nearest.
  --@range 0 96
  maxNodes = 48,
  --- How far (m) formations are drawn.
  --@range 20 120
  reach = 70.0,
  --- Beyond this (m) a formation draws its far model.
  --@range 5 60
  lodFar = 25.0,
  --- Wall marks kept at most, and how far (m).
  --@range 0 80
  maxDecals = 40,
  --@range 10 60
  decalReach = 40.0,
  --- Candidate points tried per frame while a cell is being dressed (each
  --- costs a query and up to three rays).
  --@range 1 8
  perFrame = 2,
  --- Probes: dress every cave as this kind ("" = the region's own).
  forceKind = "",
  debug = false,
}

caveKind, label, enclosure, height, depth, air, hazard = nil, nil, 0, nil, nil, nil, nil
roofDepth = nil   -- depth while a roof is within 30 m (underground.lua)
probeN, probeBody, eyeLocal, roofLocal, aheadLocal = 0, nil, nil, nil, nil
stats = { nodes = 0, records = 0, decals = 0, rays = 0, ms = 0, cells = 0, gen = 0 }

local sqrt, max, min, floor = math.sqrt, math.max, math.min, math.floor
local CELL = 10.0            -- formation cells (m)
local CANDS = 9              -- candidate points per cell
local NEUTRAL = 0.77         -- the props' picture mean (gen_cave_props NEUTRAL, measured)
local MAX_RECORDS_SAVED = 700  -- cells kept per body in the save

local refs = {}
local function ref(k)
  local r = refs[k]
  if r and r.valid ~= false then return r end
  r = findScript and findScript(k, { quiet = true }) or nil
  refs[k] = r
  return r
end
local function P(k) return (params and params[k] ~= nil) and params[k] or defaults[k] end
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end
-- wall-clock seconds (os.clock counts the process's CPU across threads)
local function wall() return (app and app.wallClock and app.wallClock()) or (os and os.clock and os.clock()) or 0 end

-- the kinds table (cave_kinds.lua on the System Generator node, else from disk)
local CK
local function kinds()
  if CK and CK.KINDS then return CK end
  CK = ref("cave_kinds")
  if not (CK and CK.KINDS) and loadfile and setfenv then
    local f = loadfile("scripts/cave_kinds.lua") or loadfile("solar/scripts/cave_kinds.lua")
    if f then
      local e = setmetatable({}, { __index = _G })
      setfenv(f, e)
      if pcall(f) then CK = e end
    end
  end
  return CK
end

-- ── the world ───────────────────────────────────────────────────────────────
local worlds = {}
-- What the region hashing needs from a world record: { seed, R, cdepth, f, ty,
-- fam, principal, rock = {r,g,b}, crystal }
function worldInfo(name)
  local wi = worlds[name]
  if wi then return wi end
  local w = save and save.get and save.get("world." .. name) or nil
  if type(w) ~= "table" then return nil end
  local bio = type(w.bio) == "table" and w.bio or {}
  local geo = type(w.geo) == "table" and w.geo or {}
  local R = w.radius or 100
  local caves = type(bio.caves) == "table" and bio.caves or {}
  local pal = type(bio.palette) == "table" and bio.palette or {}
  local rock = pal.cave or pal.rock or { 0.45, 0.42, 0.4 }
  wi = {
    name = name, seed = w.seed or 1, R = R,
    cdepth = caves.depth or min(R * 0.3, 100),
    f = type(bio.formation) == "table" and bio.formation.id or nil,
    ty = geo.type, fam = geo.family or w.kind,
    principal = caves.principal,
    rock = { rock[1] or 0.45, rock[2] or 0.42, rock[3] or 0.4 },
    crystal = (geo.family == "crystal") or w.kind == "crystal",
    gas = w.kind == "gas",
  }
  worlds[name] = wi
  return wi
end

-- The kind at a BODY-LOCAL point (nil when the world has no record).
local function kind_at_local(wi, x, y, z)
  local ck = kinds()
  if not (ck and wi) then return nil end
  local fk = P("forceKind")
  if fk and fk ~= "" and ck.KINDS[fk] then return fk, "forced", 0.5 end
  local k, cell, d = ck.regionOf(wi.seed, x, y, z, wi.R, wi.cdepth, wi.f, wi.ty, wi.fam)
  -- the principal kind's walls are the world's cave walls (version 5): a
  -- region of another kind in them still reads as it, but a kind whose walls
  -- cannot be on this world (ice in a hot basalt, salt in granite) does not
  -- arise: kindsFor only offers the formation's kinds
  return k, cell, d
end

-- ── state ───────────────────────────────────────────────────────────────────
local cur = { body = nil, planet = nil, store = nil, dirty = false, save_t = 0 }
local active = {}         -- rec → node record { n, lod, making }
local nactive = 0
local decal_on = {}       -- drec → decal id
local ndecals = 0
local jobs = {}           -- cells being dressed: { key, i, j, k, n, recs = {}, decs = {} }
local jobset = {}
local probe_t, manage_t, decal_t = -10, -10, -10
local visited = {}        -- region cell key → true (this body)
local rays_frame = 0
local vein_cache = { t = -10, list = {} }

local function cast(o, d, far)
  rays_frame = rays_frame + 1
  local ok, h = pcall(terrain.raycast, o, d, far)
  if ok then return h end
  return nil
end

local function astro()
  local a = find and find("Astronaut")
  if a and a.valid ~= false then return a end
  return nil
end

local function cell_key(i, j, k) return i .. "," .. j .. "," .. k end

local function load_store(name)
  local s = save and save.get and save.get("cave.cells." .. name) or nil
  if type(s) ~= "table" then s = {} end
  local v = save and save.get and save.get("cave.visit." .. name) or nil
  visited = {}
  if type(v) == "table" then for _, k in ipairs(v) do visited[k] = true end end
  return s
end

local function persist(force)
  if not (cur.body and cur.store and save and save.set) then return end
  if not (cur.dirty or force) then return end
  if not force and time - cur.save_t < 4 then return end
  cur.save_t = time
  cur.dirty = false
  -- keep the save bounded: the cells farthest from the eye go first
  local n, list = 0, {}
  for k, c in pairs(cur.store) do n = n + 1; list[#list + 1] = { k, c } end
  if n > MAX_RECORDS_SAVED and cur.eye then
    local e = cur.eye
    table.sort(list, function(a, b)
      local ca, cb = a[2].c or { 0, 0, 0 }, b[2].c or { 0, 0, 0 }
      return len(ca[1] - e[1], ca[2] - e[2], ca[3] - e[3]) > len(cb[1] - e[1], cb[2] - e[2], cb[3] - e[3])
    end)
    for i = 1, n - MAX_RECORDS_SAVED do cur.store[list[i][1]] = nil end
  end
  pcall(save.set, "cave.cells." .. cur.body, cur.store)
  local vl = {}
  for k in pairs(visited) do vl[#vl + 1] = k end
  table.sort(vl)
  pcall(save.set, "cave.visit." .. cur.body, vl)
end

local function drop_node(rec)
  local a = active[rec]
  if not a then return end
  if a.n and a.n.valid then pcall(a.n.destroy, a.n) end
  active[rec] = nil
  nactive = nactive - 1
end
local function drop_decal(d)
  local id = decal_on[d]
  if id then pcall(decals.remove, id) end
  decal_on[d] = nil
  ndecals = ndecals - 1
end

local function tear_down()
  for rec in pairs(active) do drop_node(rec) end
  for d in pairs(decal_on) do drop_decal(d) end
  active, decal_on, nactive, ndecals = {}, {}, 0, 0
  jobs, jobset = {}, {}
  persist(true)
  cur.store, cur.body, cur.planet = nil, nil, nil
end

-- ── dressing a cell ─────────────────────────────────────────────────────────
-- The axes at a body-local point: up (radial), and two tangents.
local function frame_at(x, y, z)
  local l = len(x, y, z)
  local ux, uy, uz = x / l, y / l, z / l
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local tx, ty, tz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
  local tl = len(tx, ty, tz)
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local bx, by, bz = uy * tz - uz * ty, uz * tx - ux * tz, ux * ty - uy * tx
  return ux, uy, uz, tx, ty, tz, bx, by, bz
end

local function pick(list, u)
  local sum = 0
  for _, e in ipairs(list) do sum = sum + (e.w or 1) end
  local x = u * sum
  for _, e in ipairs(list) do
    x = x - (e.w or 1)
    if x <= 0 then return e end
  end
  return list[#list]
end

local function near_vein(bx, by, bz, wx, wy, wz)
  local mf = ref("mineral_field")
  if not (mf and mf.veinsNear) then return false end
  if time - vein_cache.t > 3 then
    vein_cache.t = time
    local ok, l = pcall(mf.veinsNear, wx, wy, wz, 60)
    vein_cache.list = ok and l or {}
    vein_cache.b = { bx = wx - bx, by = wy - by, bz = wz - bz }
  end
  return vein_cache.list
end

-- One candidate point of cell job `jb`: a formation and maybe a mark.
-- `b` the body as read this frame (positions are body-local throughout).
local function try_candidate(jb, b, wi)
  local ck = kinds()
  jb.n = jb.n + 1
  local h = ck.hash
  local s = wi.seed + jb.n * 7919
  local ux0, uy0, uz0 = h(s, jb.i, jb.j, jb.k), h(s + 1, jb.i, jb.j, jb.k), h(s + 2, jb.i, jb.j, jb.k)
  local px, py, pz = (jb.i + ux0) * CELL, (jb.j + uy0) * CELL, (jb.k + uz0) * CELL
  local q = terrain.query(b.x + px, b.y + py, b.z + pz)
  if not q or q < 0.8 then return end
  local kd = kind_at_local(wi, px, py, pz)
  if not kd then return end
  local K = ck.KINDS[kd]
  local ux, uy, uz, tx, ty, tz, bx, by, bz = frame_at(px, py, pz)
  local wp = vec3(b.x + px, b.y + py, b.z + pz)
  local hu = cast(wp, vec3(ux, uy, uz), 22)
  local hd = cast(wp, vec3(-ux, -uy, -uz), 22)
  -- in a cave: rock above and below
  if not (hu and hd and hu.pos and hd.pos and (hu.distance or 0) > 0.3 and (hd.distance or 0) > 0.3) then return end
  local room = hu.distance + hd.distance
  local p = pick(K.props, h(s + 3, jb.i, jb.j, jb.k))
  local sc = p.s[1] + (p.s[2] - p.s[1]) * h(s + 4, jb.i, jb.j, jb.k)
  local yaw = h(s + 5, jb.i, jb.j, jb.k) * 6.2832
  local hit, nx, ny, nz
  if p.at == "ceil" then
    hit = hu
    -- headroom: a hanging prop never closes a passage you walk
    if p.orient == "hang" and (room < 3.0 or sc * 1.3 > room - 2.2) then sc = (room - 2.2) / 1.3 end
  elseif p.at == "floor" then
    hit = hd
    if room < 2.2 then return end
  else
    local a = yaw
    local dx = tx * math.cos(a) + bx * math.sin(a)
    local dy = ty * math.cos(a) + by * math.sin(a)
    local dz = tz * math.cos(a) + bz * math.sin(a)
    hit = cast(wp, vec3(dx, dy, dz), 9)
    if not (hit and hit.pos and (hit.distance or 0) > 0.3) then return end
    -- a drip hung off a wall hangs over the floor with headroom under it
    if p.orient == "hang" and hd.distance < 2.2 + sc * 1.3 then return end
  end
  if sc < 0.25 then return end
  local n = hit.normal
  nx, ny, nz = n and n.x or -ux, n and n.y or -uy, n and n.z or -uz
  local hx, hy, hz = hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z
  -- the prop's up and forward (its +Y and the way its face looks)
  local mux, muy, muz, fx, fy, fz
  local ndu = nx * ux + ny * uy + nz * uz
  if p.orient == "hang" then
    mux, muy, muz = -ux, -uy, -uz
    fx, fy, fz = tx * math.cos(yaw) + bx * math.sin(yaw), ty * math.cos(yaw) + by * math.sin(yaw), tz * math.cos(yaw) + bz * math.sin(yaw)
  elseif p.orient == "stand" then
    mux, muy, muz = ux, uy, uz
    fx, fy, fz = tx * math.cos(yaw) + bx * math.sin(yaw), ty * math.cos(yaw) + by * math.sin(yaw), tz * math.cos(yaw) + bz * math.sin(yaw)
  elseif p.orient == "drape" then
    -- down the wall, its face out of it
    if math.abs(ndu) > 0.7 then return end
    mux, muy, muz = -ux, -uy, -uz
    local hx2, hy2, hz2 = nx - ux * ndu, ny - uy * ndu, nz - uz * ndu
    local hl = len(hx2, hy2, hz2)
    fx, fy, fz = hx2 / hl, hy2 / hl, hz2 / hl
    -- hung from the wall a little above where the ray met it
    hx, hy, hz = hx + ux * sc * 0.6, hy + uy * sc * 0.6, hz + uz * sc * 0.6
  else
    mux, muy, muz = nx, ny, nz
    -- any tangent of the surface
    local ax, ay, az = tx, ty, tz
    if math.abs(nx * tx + ny * ty + nz * tz) > 0.9 then ax, ay, az = bx, by, bz end
    local d = ax * nx + ay * ny + az * nz
    fx, fy, fz = ax - nx * d, ay - ny * d, az - nz * d
    local fl = len(fx, fy, fz)
    fx, fy, fz = fx / fl, fy / fl, fz / fl
  end
  -- sunk a little into the rock, so a rough wall never shows daylight under it
  local sink = 0.08 * sc
  local rx, ry, rz = hx - mux * sink, hy - muy * sink, hz - muz * sink
  jb.recs[#jb.recs + 1] = { p.id, floor(rx * 100 + 0.5) / 100, floor(ry * 100 + 0.5) / 100, floor(rz * 100 + 0.5) / 100,
    floor(mux * 1000 + 0.5) / 1000, floor(muy * 1000 + 0.5) / 1000, floor(muz * 1000 + 0.5) / 1000,
    floor(fx * 1000 + 0.5) / 1000, floor(fy * 1000 + 0.5) / 1000, floor(fz * 1000 + 0.5) / 1000,
    floor(sc * 100 + 0.5) / 100, kd }
  -- a mark on the rock the ray met (walls and roofs), by the kind's list
  local dl = K.decals or {}
  if #dl > 0 and #jb.decs < 3 and h(s + 6, jb.i, jb.j, jb.k) < 0.6 and p.at ~= "floor" then
    local veins = near_vein(b.x, b.y, b.z, b.x + hx, b.y + hy, b.z + hz)
    local clear = true
    for _, v in ipairs(veins or {}) do
      if len(v.x - b.x - hx, v.y - b.y - hy, v.z - b.z - hz) < 6 + (v.len or 0) * 0.5 then clear = false break end
    end
    if clear then
      local d = pick(dl, h(s + 7, jb.i, jb.j, jb.k))
      local ds = d.size[1] + (d.size[2] - d.size[1]) * h(s + 8, jb.i, jb.j, jb.k)
      jb.decs[#jb.decs + 1] = { d.tex, floor(hx * 100 + 0.5) / 100, floor(hy * 100 + 0.5) / 100, floor(hz * 100 + 0.5) / 100,
        floor(nx * 1000 + 0.5) / 1000, floor(ny * 1000 + 0.5) / 1000, floor(nz * 1000 + 0.5) / 1000,
        floor(ds * 100 + 0.5) / 100, floor(yaw * 100) / 100 }
    end
  end
end

local function finish_job(jb)
  cur.store[jb.key] = { c = { (jb.i + 0.5) * CELL, (jb.j + 0.5) * CELL, (jb.k + 0.5) * CELL }, p = jb.recs, d = jb.decs }
  cur.dirty = true
  stats.gen = stats.gen + 1
end

local function run_jobs(b, wi)
  local budget = floor(P("perFrame") or 2)
  while budget > 0 and #jobs > 0 do
    local jb = jobs[1]
    try_candidate(jb, b, wi)
    budget = budget - 1
    if jb.n >= CANDS then
      table.remove(jobs, 1)
      jobset[jb.key] = nil
      finish_job(jb)
    end
  end
end

-- Cells round the eye to dress (only while in a cave: the rays need a roof).
local function queue_cells(ex, ey, ez)
  local ci, cj, ck_ = floor(ex / CELL), floor(ey / CELL), floor(ez / CELL)
  for di = -1, 1 do
    for dj = -1, 1 do
      for dk = -1, 1 do
        local i, j, k = ci + di, cj + dj, ck_ + dk
        local key = cell_key(i, j, k)
        if not cur.store[key] and not jobset[key] and #jobs < 30 then
          local jb = { key = key, i = i, j = j, k = k, n = 0, recs = {}, decs = {} }
          -- the eye's own cell first
          if di == 0 and dj == 0 and dk == 0 then table.insert(jobs, 1, jb) else jobs[#jobs + 1] = jb end
          jobset[key] = jb
        end
      end
    end
  end
end

-- ── nodes ───────────────────────────────────────────────────────────────────
local function tint_of(r, wi)
  local ck = kinds()
  local K = ck.KINDS[r[12]] or {}
  local t = (K.tints and K.tints[r[1]]) or K.tint
  if not t then
    -- the world's own rock (collapse, chasm), a little darker and greyer
    local c = wi.rock
    local l = 0.3 * c[1] + 0.59 * c[2] + 0.11 * c[3]
    t = { (c[1] * 0.7 + l * 0.3) * 0.75, (c[2] * 0.7 + l * 0.3) * 0.75, (c[3] * 0.7 + l * 0.3) * 0.75 }
  end
  return { min(1.3, t[1] / NEUTRAL), min(1.3, t[2] / NEUTRAL), min(1.3, t[3] / NEUTRAL) }
end

GLASSY = { selenite = 0.22, ice_curtain = 0.18, hoarfrost = 0.16, geode_cluster = 0.14, salt_crust = 0.10, soda_straws = 0.08 }

local function make_node(rec, wi, lod)
  local ck = kinds()
  local a = { lod = lod, making = true }
  active[rec] = a
  nactive = nactive + 1
  createNode("Cave " .. rec[1], cur.planet, function(n)
    a.making = false
    if active[rec] ~= a then pcall(n.destroy, n) return end
    a.n = n
    n.model = ck.propModel(rec[1], a.lod)
    n.x, n.y, n.z = rec[2], rec[3], rec[4]
    local s = rec[11]
    n.scale_x, n.scale_y, n.scale_z = s, s, s
    if n.setUp then n:setUp(vec3(rec[5], rec[6], rec[7]), vec3(rec[8], rec[9], rec[10])) end
    n.tags = { "cave_prop" }
    n.castShadow = false
    -- ambient: with the sky's reflection off (below), a model's only fill
    -- is the scene's ambient, and its share of it reads darker than the
    -- terrain's beside it: lifted so a formation is as dim as its wall, never
    -- a black cut-out. Clear and crystalline ones (ice, selenite, quartz,
    -- salt) get a faint pale rim, the glassy edge a lamp finds on a crystal.
    local t = { color = tint_of(rec, wi), ambient = 3.0 }
    if GLASSY[rec[1]] then t.rim, t.rimStrength = { 0.85, 0.9, 0.95 }, GLASSY[rec[1]] end
    -- the one declared fiction: a crystal world's geode points glow faintly
    if wi.crystal and rec[1] == "geode_cluster" then t.emissive, t.emissiveStrength = { 0.55, 0.4, 0.9 }, 0.35 end
    if n.setTint then pcall(n.setTint, n, t) end
    a.tint, a.t = t, time
  end)
end

-- Gone when the rock it stood on is dug away: a point just inside the
-- surface it grew from is air now.
local function anchored(rec, b)
  local q = terrain.query(b.x + rec[2] - rec[5] * 0.25, b.y + rec[3] - rec[6] * 0.25, b.z + rec[4] - rec[7] * 0.25)
  return q == nil or q < 0.35
end

local check_i = 0
local function manage(b, wi, ex, ey, ez)
  local reach, far = P("reach"), P("lodFar")
  local maxn = floor(P("maxNodes"))
  -- every record in a cell within reach
  local cand = {}
  local nrec = 0
  local rr = reach + CELL
  for key, c in pairs(cur.store) do
    local cc = c.c
    if cc and len(cc[1] - ex, cc[2] - ey, cc[3] - ez) < rr then
      for _, r in ipairs(c.p or {}) do
        if (r[11] or 0) > 0 then
          local d = len(r[2] - ex, r[3] - ey, r[4] - ez)
          nrec = nrec + 1
          if d < reach then cand[#cand + 1] = { r, d } end
        end
      end
    end
  end
  table.sort(cand, function(x, y) return x[2] < y[2] end)
  local want = {}
  for i = 1, min(#cand, maxn) do want[cand[i][1]] = cand[i][2] end
  -- out of reach or pushed out by nearer ones
  for rec in pairs(active) do
    if not want[rec] then drop_node(rec) end
  end
  -- new ones (a few a pass) and LOD switches (hysteresis: 0.9×far in, 1.1× out)
  local made = 0
  for i = 1, min(#cand, maxn) do
    local rec, d = cand[i][1], cand[i][2]
    local a = active[rec]
    if not a then
      if made < 4 then
        made = made + 1
        make_node(rec, wi, d < far and 0 or 1)
      end
    elseif a.n and a.n.valid and not a.making then
      local lod = a.lod
      if lod == 0 and d > far * 1.1 then lod = 1 elseif lod == 1 and d < far * 0.9 then lod = 0 end
      if lod ~= a.lod then
        a.lod = lod
        a.n.model = kinds().propModel(rec[1], lod)
        if a.n.setTint and a.tint then pcall(a.n.setTint, a.n, a.tint) end
        a.lit, a.t = false, time
      end
      -- NO SKY IN A CAVE: a physical (metal-rough) model reflects the sky's
      -- picture (lua-api "Under physical shading a surface also REFLECTS the
      -- sky"), and underground that cold blue-grey sheen was all a formation
      -- showed past the lamp, whatever its tint. reflectivity 0 a beat after
      -- the model lands (in the pass a node is made a setMaterial lands
      -- before its model and would replace the model's own Material: see
      -- mineral_field outcrop_look); it also skips the screen-space march.
      if not a.lit and time - (a.t or 0) > 0.3 then
        a.lit = true
        if a.n.setMaterial then pcall(a.n.setMaterial, a.n, { reflectivity = 0 }) end
      end
    end
  end
  -- a few anchors checked a pass: dug away → gone for good
  -- (round-robin over the nearest: six a pass)
  local nc = min(#cand, maxn)
  for k = 1, min(6, nc) do
    check_i = check_i % nc + 1
    local rec = cand[check_i][1]
    if active[rec] and not anchored(rec, b) then
      rec[11] = 0
      drop_node(rec)
      cur.dirty = true
    end
  end
  stats.records = nrec
  stats.nodes = nactive
end

local function manage_decals(b, ex, ey, ez)
  if not (decals and decals.add) then return end
  local ck = kinds()
  local reach = P("decalReach")
  local maxd = floor(P("maxDecals"))
  local cand = {}
  for _, c in pairs(cur.store) do
    local cc = c.c
    if cc and len(cc[1] - ex, cc[2] - ey, cc[3] - ez) < reach + CELL then
      for _, d in ipairs(c.d or {}) do
        local dd = len(d[2] - ex, d[3] - ey, d[4] - ez)
        if (d[8] or 0) > 0 and dd < reach * (decal_on[d] and 1.1 or 1.0) then cand[#cand + 1] = { d, dd } end
      end
    end
  end
  table.sort(cand, function(x, y) return x[2] < y[2] end)
  local want = {}
  for i = 1, min(#cand, maxd) do want[cand[i][1]] = true end
  for d in pairs(decal_on) do if not want[d] then drop_decal(d) end end
  local laid = 0
  for i = 1, min(#cand, maxd) do
    local d = cand[i][1]
    if not decal_on[d] and laid < 3 then
      laid = laid + 1
      local K = ck.KINDS[caveKind or ""] or {}
      local ok, id = pcall(decals.add, { texture = ck.decalTexture(d[1]), pos = vec3(b.x + d[2], b.y + d[3], b.z + d[4]),
        normal = vec3(d[5], d[6], d[7]), size = d[8], depth = 0.6, rotation = d[9], alpha = 0.85 })
      if ok and id then
        decal_on[d] = id
        ndecals = ndecals + 1
      else
        d[8] = 0   -- nothing there takes a mark: never asked again this run
        decal_on[d] = nil
      end
    end
  end
  stats.decals = ndecals
end

-- ── the probe ───────────────────────────────────────────────────────────────
local in_cave = false
local function probe(a, name, b, wi)
  local ug = ref("underground")
  enclosure = (ug and ug.enclosed) or 0
  local lx, ly, lz = a.x - b.x, a.y - b.y, a.z - b.z
  local l = len(lx, ly, lz)
  if l < 1 then return end
  local ux, uy, uz = lx / l, ly / l, lz / l
  local ex, ey, ez = lx + ux * 1.6, ly + uy * 1.6, lz + uz * 1.6
  local we = vec3(b.x + ex, b.y + ey, b.z + ez)
  local hu = cast(we, vec3(ux, uy, uz), 40)
  local hd = cast(we, vec3(-ux, -uy, -uz), 40)
  height = (hu and hd and hu.distance and hd.distance) and (hu.distance + hd.distance) or nil
  -- the rock over the eye: down from well above the ground to the first rock
  local top = (wi.R + 600) - (l + 1.6)
  local hz = cast(vec3(b.x + ex + ux * top, b.y + ey + uy * top, b.z + ez + uz * top), vec3(-ux, -uy, -uz), top + 2)
  if hz and (hz.distance or 0) > 0.01 then depth = max(0, top - hz.distance) else depth = max(0, wi.R - l) end
  if hu == nil then depth = 0 end
  -- a roof within reach and real rock over it: under ground whatever the
  -- side rays say (a tall chamber's tipped sky rays run off along tunnels).
  -- underground.lua reads this to darken a deep cave the rays half-miss.
  roofDepth = (hu and (hu.distance or 99) < 30) and depth or nil
  -- the drop ahead: from 2.5 m in front of the eye, straight down
  local pc = ref("planet_camera")
  local fx, fy, fz = (pc and pc.fwd_x) or 0, (pc and pc.fwd_y) or 0, (pc and pc.fwd_z) or 0
  local fd = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * fd, fy - uy * fd, fz - uz * fd
  local fl = len(fx, fy, fz)
  local drop = 0
  aheadLocal = nil
  if fl > 0.1 then
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local hf = cast(vec3(we.x + fx * 2.5, we.y + fy * 2.5, we.z + fz * 2.5), vec3(-ux, -uy, -uz), 40)
    drop = hf and max(0, (hf.distance or 0) - 1.6) or 40
    if hf and hf.pos then aheadLocal = { hf.pos.x - b.x, hf.pos.y - b.y, hf.pos.z - b.z } end
  end
  -- (W5) the probe's points for cave_hazards, body-local (rule 1)
  roofLocal = (hu and hu.pos) and { hu.pos.x - b.x, hu.pos.y - b.y, hu.pos.z - b.z } or nil
  eyeLocal = { ex, ey, ez }
  probeBody = name
  probeN = probeN + 1
  -- in a cave: enclosed and under real rock (hysteresis, as underground's flag)
  local deep = (roofDepth or 0) > (in_cave and 5 or 7)
  if in_cave then in_cave = deep or (enclosure > 0.35 and (depth or 0) > 2)
  else in_cave = deep or (enclosure > 0.55 and (depth or 0) > 3) end
  local ck = kinds()
  local k, cell = nil, nil
  if in_cave and ck then k, cell = kind_at_local(wi, ex, ey, ez) end
  caveKind = k
  label = k and ck.labelOf(k) or nil
  if k then
    air = ck.airOf(k)
    hazard = ck.hazardsOf(k)
    hazard.drop = drop
    if cell and cell ~= "forced" and not visited[cell] then visited[cell] = true; cur.dirty = true end
  else
    air, hazard = nil, nil
  end
  cur.eye = { ex, ey, ez }
end

-- ── public reads ────────────────────────────────────────────────────────────
function cells()
  local out = {}
  for k in pairs(visited) do out[#out + 1] = k end
  table.sort(out)
  return out
end
function kindAt(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  local wi = name and worldInfo(name)
  if not (b and wi) then return nil end
  return (kind_at_local(wi, x - b.x, y - b.y, z - b.z))
end
-- The cave's air at a world point while you are in that cave (W5 wires
-- atmo.airHere to it); nil: the world's.
function airAt(x, y, z)
  if not caveKind then return nil end
  local ch = ref("cave_hazards")
  if ch and ch.airAtWorld then return ch.airAtWorld(x, y, z) end
  return air
end

-- Probes: forget this body's dressing (nodes, marks, the saved cells) so the
-- cave round you is dressed again (with params.forceKind, as another kind).
function reset()
  for rec in pairs(active) do drop_node(rec) end
  for d in pairs(decal_on) do drop_decal(d) end
  active, decal_on, nactive, ndecals = {}, {}, 0, 0
  jobs, jobset = {}, {}
  if cur.body then cur.store = {}; cur.dirty = true; persist(true) end
  stats.gen = 0
end

-- ── the frame ───────────────────────────────────────────────────────────────
local function body_of(a)
  local wk = ref("planet_walker")
  if wk and wk.onFoot == false then return nil end
  local name = space.dominant(a.x, a.y, a.z)
  local b = name and space.body(name)
  if not b or (b.soi or 0) < 0 then return nil end
  return name, b
end

function update(node, dt)
  local t0 = wall()
  rays_frame = 0
  if params.on == false or not (terrain and terrain.raycast and terrain.query) then
    caveKind = nil
    return
  end
  local a = astro()
  local name, b
  if a then name, b = body_of(a) end
  if not name then
    caveKind, air, hazard, roofDepth = nil, nil, nil, nil
    if cur.body and nactive > 0 then for rec in pairs(active) do drop_node(rec) end end
    return
  end
  local wi = worldInfo(name)
  if not wi or wi.gas then caveKind = nil return end
  if name ~= cur.body then
    tear_down()
    cur.body = name
    cur.store = load_store(name)
  end
  if not (cur.planet and cur.planet.valid) then
    cur.planet = find and find(name) or nil
    if not (cur.planet and cur.planet.valid) then return end
    -- a planet rebuilt under us: its children went with it
    for rec in pairs(active) do active[rec] = nil end
    nactive = 0
  end
  if time - probe_t > 0.5 then
    probe_t = time
    probe(a, name, b, wi)
  end
  local e = cur.eye
  if not e then return end
  -- dress the cells round you while you are in a cave
  if caveKind and (P("maxNodes") or 0) > 0 then queue_cells(e[1], e[2], e[3]) end
  if #jobs > 0 then run_jobs(b, wi) end
  if time - manage_t > 0.25 then
    manage_t = time
    manage(b, wi, e[1], e[2], e[3])
  end
  if time - decal_t > 0.5 then
    decal_t = time
    manage_decals(b, e[1], e[2], e[3])
  end
  persist(false)
  stats.rays = rays_frame
  stats.cells = 0
  for _ in pairs(cur.store) do stats.cells = stats.cells + 1 end
  stats.ms = stats.ms + ((wall() - t0) * 1000 - stats.ms) * 0.1
  if params.debug and time % 2 < (dt or 0) then
    print(string.format("cave_field: kind %s encl %.2f height %s depth %s nodes %d recs %d decals %d jobs %d",
      tostring(caveKind), enclosure or 0, tostring(height), tostring(depth), nactive, stats.records, ndecals, #jobs))
  end
end

function onDestroy(node)
  tear_down()
end
