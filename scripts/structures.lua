-- STRUCTURES — what an Engineer has built in the world (deep-space addendum
-- K13; docs/base-building.md). A structure is a BLUEPRINT AT A POSE: a list
-- of part records in the builder's own shape, standing at an origin and a
-- facing kept in its BODY's frame (the planet moves metres a tick; nothing
-- here keeps a world point, docs/positions-and-frames.md rule 1).
--
-- On the Build Kit node (scenes/system.ron) beside field_builder.lua. The
-- records half is pure (it loads in a luajit test with a stand-in `save`);
-- the scene half (update) spawns and unloads the parts.
--
-- ── RECORDS (in the save) ───────────────────────────────────────────────────
--
--   struct.list   the ids, in building order
--   struct.seq    the last id handed out (never reused)
--   struct.<id>   { id, b = body, x, y, z (body-relative ground point under
--                   the origin), ux, uy, uz (its up), fx, fy, fz (its front,
--                   the parts' +Z), n = name, by = member id, t = agency
--                   clock when founded, d = "Day 41, Y2",
--                   bp = { { uid, id, x, y, z, yaw, pitch, roll, parent, att,
--                            sym, mir, stage } … }   (builder blueprint parts,
--                         in the structure's frame: +X right, +Y up, +Z front;
--                         x, y, z = the part's ground point, its seat added
--                         when it is posed),
--                   st = { [uid] = { … } } (part states, for machines later),
--                   paid = { cost, ship, total, t, supplier, by } (what the
--                         last placement charged: the 60 s undo reads it) }
--
-- ── THE API ─────────────────────────────────────────────────────────────────
--
--   newRecord(id, body, x, y, z, up, fwd, partId, opts) → rec        (pure)
--   frame(rec) → ux,uy,uz, fx,fy,fz, rx,ry,rz   orthonormal, body frame (pure)
--   partPose(rec, p, seat) → x, y, z, up{}, fwd{}  a part's prefab origin and
--                             axes in the body frame                  (pure)
--   add(rec) → id    remove(id) → rec|nil    get(id)    list()    count()
--   near(body, x, y, z, r) → rec, d   (body-relative point)
--   nodesOf(id) → { node … } | nil     the live part nodes
--   reloadFromSave()                    forget the cache, read the save again
--   version                             bumps on every change
--
-- STREAMING. A structure's parts are spawned, parented to their planet (as
-- the base facilities and deployables are), only while the focus is on that
-- world or within 20 km of it, and unloaded otherwise; the check is once a
-- second for every structure together. A placed part is a plain static
-- prefab: no script, no body that moves, so it costs nothing a tick.
--
-- (Step 5's snapping joins a part to an existing structure: `bp` is already a
-- list, so it only appends. K11's anchored-assembly structure, for parts that
-- carry electronics, replaces the static prefabs when the base grid (M6)
-- needs a power step.)

defaults = {
  --@range 1000 100000 --@units m
  spawn_range = 20000.0,
}

version = 0

local recs = nil      -- id → record
local order = {}      -- ids, in building order
local live = {}       -- id → { nodes = { [uid] = node }, spawning = n }

local function S() return save end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

local KEEP = { "id", "b", "x", "y", "z", "ux", "uy", "uz", "fx", "fy", "fz", "n", "by", "t", "d", "bp", "st", "paid" }
local function plain(r)
  local o = {}
  for _, k in ipairs(KEEP) do o[k] = r[k] end
  return o
end

local function load()
  recs, order = {}, {}
  local sv = S()
  if not (sv and sv.get) then return end
  for _, id in ipairs(sv.get("struct.list") or {}) do
    local r = sv.get("struct." .. tostring(id))
    if type(r) == "table" and r.b and r.x and type(r.bp) == "table" then
      local rec = plain(r)
      rec.id = id
      recs[id] = rec
      order[#order + 1] = id
    end
  end
end
local function ensure() if not recs then load() end end
local function bump() version = version + 1 end
local function write_index() local sv = S(); if sv and sv.set then sv.set("struct.list", order) end end
local function write(r) local sv = S(); if sv and sv.set then sv.set("struct." .. tostring(r.id), plain(r)) end end
local function forget(id)
  local sv = S()
  if not sv then return end
  if sv.delete then sv.delete("struct." .. tostring(id)) elseif sv.set then sv.set("struct." .. tostring(id), false) end
end

-- ── pure ────────────────────────────────────────────────────────────────────

-- The structure's frame, re-orthonormalised: up, front (+Z), right (+X = up × front).
function frame(r)
  local ux, uy, uz = norm(r.ux or 0, r.uy or 1, r.uz or 0)
  local fx, fy, fz = r.fx or 0, r.fy or 0, r.fz or 1
  local d = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-6 then
    fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
    local _, _, _, l2 = norm(fx, fy, fz)
    if l2 < 1e-6 then fx, fy, fz = 0, 0, 1 end
  end
  fx, fy, fz = norm(fx, fy, fz)
  local rx, ry, rz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
  return ux, uy, uz, fx, fy, fz, rx, ry, rz
end

-- A part's prefab origin and axes, in the body frame. `seat` = the prefab's
-- origin height over its ground point (parts_base PARTS[id].seat). Step 4
-- places parts upright, so only `yaw` (about the structure's up, + = from
-- front toward right) is read; pitch and roll are kept in the record for
-- step 5's rotations.
function partPose(r, p, seat)
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = frame(r)
  local lx, ly, lz = p.x or 0, (p.y or 0) + (seat or 0), p.z or 0
  local x = r.x + rx * lx + ux * ly + fx * lz
  local y = r.y + ry * lx + uy * ly + fy * lz
  local z = r.z + rz * lx + uz * ly + fz * lz
  local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  local pfx, pfy, pfz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s
  return x, y, z, { x = ux, y = uy, z = uz }, { x = pfx, y = pfy, z = pfz }
end

-- A new one-part structure: the part `partId` on the ground point (x, y, z)
-- (body-relative), up `up` and front `fwd` (body-frame vectors).
-- opts = { by, name, t, d, paid, st }
function newRecord(id, body, x, y, z, up, fwd, partId, opts)
  opts = opts or {}
  local r = { id = id, b = body, x = x, y = y, z = z, ux = up.x, uy = up.y, uz = up.z, fx = fwd.x, fy = fwd.y, fz = fwd.z,
              by = opts.by, n = opts.name, t = opts.t or 0, d = opts.d, paid = opts.paid, st = opts.st or {},
              bp = { { uid = 1, id = partId, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0, parent = 0, att = "",
                       sym = 0, mir = "", stage = 0 } } }
  local ux, uy, uz, fx, fy, fz = frame(r)
  r.ux, r.uy, r.uz, r.fx, r.fy, r.fz = ux, uy, uz, fx, fy, fz
  return r
end

-- ── the store ───────────────────────────────────────────────────────────────

function nextId()
  local sv = S()
  local seq = ((sv and sv.get and sv.get("struct.seq")) or 0) + 1
  if sv and sv.set then sv.set("struct.seq", seq) end
  return seq
end

function add(r)
  ensure()
  if r.id == nil then r.id = nextId() end
  recs[r.id] = r
  order[#order + 1] = r.id
  write(r)
  write_index()
  bump()
  return r.id
end

-- Re-write a record already in the store (a part state, a rename).
function put(r)
  ensure()
  if not (r and recs[r.id]) then return false end
  recs[r.id] = r
  write(r)
  bump()
  return true
end

local despawn
function remove(id)
  ensure()
  local r = recs[id]
  if not r then return nil end
  if despawn then despawn(id) end
  recs[id] = nil
  for i = #order, 1, -1 do if order[i] == id then table.remove(order, i) end end
  forget(id)
  write_index()
  bump()
  return r
end

function get(id) ensure() return recs[id] end
function count() ensure() return #order end
function list()
  ensure()
  local out = {}
  for _, id in ipairs(order) do out[#out + 1] = recs[id] end
  return out
end

function near(body, x, y, z, rad)
  ensure()
  local best, bd = nil, rad or 5.0
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.b == body then
      local d = math.sqrt((r.x - x) ^ 2 + (r.y - y) ^ 2 + (r.z - z) ^ 2)
      if d < bd then best, bd = r, d end
    end
  end
  return best, best and bd or nil
end

function reloadFromSave()
  if recs and despawn then for _, id in ipairs(order) do despawn(id) end end
  recs = nil
  load()
  bump()
end

-- ── the scene half: spawning and unloading ──────────────────────────────────

local function parts_lib()
  return findScript and findScript("parts_base") or nil
end

despawn = function(id)
  local L = live[id]
  if not L then return end
  for _, n in pairs(L.nodes) do if n and n.valid then n:destroy() end end
  live[id] = nil
end

function nodesOf(id)
  local L = live[id]
  if not L then return nil end
  local out = {}
  for _, p in ipairs((recs and recs[id] and recs[id].bp) or {}) do
    local n = L.nodes[p.uid]
    if n and n.valid then out[#out + 1] = n end
  end
  return out
end

local function spawn_rec(r)
  if live[r.id] then return end
  local pb = parts_lib()
  local planet = find and find(r.b)
  local b = space and space.body and space.body(r.b)
  if not (pb and planet and b and spawn) then return end
  local L = { nodes = {}, spawning = 0 }
  live[r.id] = L
  for _, p in ipairs(r.bp) do
    local def = pb.partInfo(p.id)
    if def and def.prefab then
      local x, y, z, U, F = partPose(r, p, def.seat)
      L.spawning = L.spawning + 1
      local ok = pcall(spawn, def.prefab, vec3(b.x + x, b.y + y, b.z + z), function(inst)
        L.spawning = L.spawning - 1
        if live[r.id] ~= L or not (recs and recs[r.id] == r) then inst:destroy() return end
        -- (setUp points −Z along the vector given: +Z, the part's front, faces F)
        inst:setUp(vec3(U.x, U.y, U.z), vec3(-F.x, -F.y, -F.z))
        inst.x, inst.y, inst.z = x, y, z
        inst.name = def.prefab
        L.nodes[p.uid] = inst
      end, planet)
      if not ok then L.spawning = L.spawning - 1 end
    end
  end
end

-- Spawn this one now (a placement: no waiting for the 1 Hz check).
function spawnNow(id) ensure() local r = recs[id]; if r then spawn_rec(r) end end

local check_t = -10
local function focus()
  local a = find and find("Astronaut")
  if a then return a.x, a.y, a.z end
  return nil
end

function start(node)
  if findScripts then
    local all = findScripts("structures")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  recs = nil
  live = {}
  load()
end

function update(node, dt)
  ensure()
  local t = time or 0
  if t - check_t < 1.0 or #order == 0 then return end
  check_t = t
  local fx, fy, fz = focus()
  local dom = fx and space.dominant(fx, fy, fz) or nil
  local range = (params and params.spawn_range) or 20000
  for _, id in ipairs(order) do
    local r = recs[id]
    local want = false
    if fx then
      if r.b == dom then want = true
      else
        local b = space.body(r.b)
        if b then want = math.sqrt((b.x + r.x - fx) ^ 2 + (b.y + r.y - fy) ^ 2 + (b.z + r.z - fz) ^ 2) < range end
      end
    end
    if want then spawn_rec(r) elseif live[id] then despawn(id) end
  end
end
