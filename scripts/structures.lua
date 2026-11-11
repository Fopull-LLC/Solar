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
-- Step 5 (K5, K7, K9, K10): a structure grows and shrinks part by part.
--   addPart(id, part) → uid            join a part (a bp entry; uid assigned)
--   removeParts(id, { uid … }) → { part … }   take parts out (the record goes
--                                       with its last part)
--   partOfNode(node) → rec, part        a hit node (or a child of one: a
--                                       "Wall N" collider) → its structure part
--   partsNear(body, x, y, z, r) → { { rec, part, d } … }  nearest first, from
--                                       a 32 m cell index kept on add/remove
--                                       (never a scan of every structure)
--   nodeOf(id, uid)                     a part's live node
-- Step 6 (L1, L2): parts with behaviour (parts_base `script`).
--   partState(id, uid) / setPartState(id, uid, t)   rec.st[tostring(uid)]
--   respawnPart(id, uid)                a part's node made again (its fields
--                                       changed: a stand's height)
--   the part's script hears `spawned(rec, part, node)` as its node lands and
--   `gone(sid, uid)` as it goes (unloaded or taken out).
-- A bp entry may carry `h` (a stand's deck height, step 6), `paid` (what placing it charged: its undo and
-- deconstruct read it) and `ft` = { d, hx, hz } (a cast footing under it: a
-- concrete block from its ground point d m down, hx × hz half-size).
--
-- STREAMING. A structure's parts are spawned, parented to their planet (as
-- the base facilities and deployables are), only while the focus is on that
-- world or within 20 km of it, and unloaded otherwise; the check is once a
-- second for every structure together. A placed part is a plain static
-- prefab: no script, no body that moves, so it costs nothing a tick.
-- (X8) A record with a `ru` (an abandoned base's site, ruins.lua) streams by
-- DISTANCE instead: spawned within ruin_in of the focus, unloaded past
-- ruin_out (hysteresis), so a ruin across the world costs no draws.
-- PACED (X8, the spawn budget): a structure streaming in is spawned
-- `pace` parts a frame, not all at once (a 150-piece ruin over ~13 frames;
-- a placement's spawnNow is still immediate).
--
-- (Step 5's snapping joins a part to an existing structure: `bp` is already a
-- list, so it only appends. K11's anchored-assembly structure, for parts that
-- carry electronics, replaces the static prefabs when the base grid (M6)
-- needs a power step.)

defaults = {
  --@range 1000 100000 --@units m
  spawn_range = 20000.0,
  --@range 100 5000 --@units m
  ruin_in = 650.0,
  --@range 100 5000 --@units m
  ruin_out = 800.0,
  --@range 1 200
  pace = 12,
}

version = 0

local recs = nil      -- id → record
local order = {}      -- ids, in building order
local live = {}       -- id → { nodes = { [uid] = node }, feet = { [uid] = node }, spawning = n }
local owner = {}      -- live node id → { sid, uid }
local cells = {}      -- index cell key → { [sid .. ":" .. uid] = { sid, uid } }
local held = {}       -- id → true: suspended (the Base Hub's builder has it; suspend)
local CELL = 32.0

local function S() return save end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

local KEEP = { "id", "b", "x", "y", "z", "ux", "uy", "uz", "fx", "fy", "fz", "n", "by", "t", "d", "bp", "st", "paid", "ru" }
local function plain(r)
  local o = {}
  for _, k in ipairs(KEEP) do o[k] = r[k] end
  return o
end

local reindex
local join_pending = false
local function load()
  recs, order = {}, {}
  cells = {}
  join_pending = true
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
  reindex()
end
-- (Ty 11-10) HAB JOINS: a hab segment's shape (straight, T, cross, corner) is
-- derived from its neighbours by kit_snap.habShapes, which writes the
-- segment's `hj` (a cache: an old save rebuilds it on load, a placement, a
-- removal, an undo, a hub commit re-shape only the segments near the change).
-- A live segment whose code changed is drawn again as its variant (reshape).
local reshape
local function rejoin(r, pts)
  local KS = findScript and findScript("kit_snap")
  local PB = findScript and findScript("parts_base")
  if not (r and KS and KS.habShapes and PB and PB.partInfo) then return nil end
  local ok, changed = pcall(KS.habShapes, r, PB.partInfo, pts)
  if not ok then
    if log then log("structures: habShapes: " .. tostring(changed)) end
    return nil
  end
  if reshape then for _, p in ipairs(changed) do reshape(r, p) end end
  return changed
end
local function pts_of(parts)
  local out = {}
  for _, p in ipairs(parts) do out[#out + 1] = { x = p.x or 0, z = p.z or 0 } end
  return out
end
-- every record's segments, once the rulebook is there (after a load)
local function join_all()
  if not join_pending or not recs then return end
  if not (findScript and findScript("kit_snap") and findScript("parts_base")) then return end
  join_pending = false
  for _, id in ipairs(order) do rejoin(recs[id], nil) end
end
local function ensure() if not recs then load() end; if join_pending then join_all() end end
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
  local pitch, roll = p.pitch or 0, p.roll or 0
  if pitch == 0 and roll == 0 then
    local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
    local pfx, pfy, pfz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s
    return x, y, z, { x = ux, y = uy, z = uz }, { x = pfx, y = pfy, z = pfz }
  end
  -- (the sandbox kit, S1: a piece turned in pitch and roll too — the
  -- engine's own order, node:setAngles: yaw about up, then pitch about the
  -- part's X, then roll about its Z; `seat` stays along the structure's up)
  local lu, lf = localAxes(p.yaw or 0, pitch, roll)
  local function body(v) return { x = rx * v[1] + ux * v[2] + fx * v[3], y = ry * v[1] + uy * v[2] + fy * v[3],
                                   z = rz * v[1] + uz * v[2] + fz * v[3] } end
  return x, y, z, body(lu), body(lf)
end

-- A part's up (+Y) and front (+Z) in its structure's frame for yaw, pitch,
-- roll (rad; M = Ry(yaw)·Rx(pitch)·Rz(roll), its columns). (pure)
function localAxes(yaw, pitch, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local cr, sr = math.cos(roll), math.sin(roll)
  -- Rx·Rz columns: Y' = (-sr, cr·cp, cr·sp), Z' = (0, -sp, cp); then Ry
  local function ry(v) return { cy * v[1] + sy * v[3], v[2], -sy * v[1] + cy * v[3] } end
  local up = ry({ -sr, cr * cp, cr * sp })
  local fw = ry({ 0, -sp, cp })
  return up, fw
end

-- A structure record from a list of pieces in its frame (a blueprint's, a
-- ruin's build, a scenario's start): pieces = { { id, x, y, z, yaw, pitch,
-- roll, … any other field kept on the bp entry (paint, paintIn, ri, rl, wr,
-- o_*, fill, text) } … }; g = { x, y, z (the ground point, body-relative),
-- ux, uy, uz (up), fx, fy, fz (front) }; opts = { st, t, d, extra } (extra:
-- fields set on the record, e.g. `ru`). uids are 1..n in order. (pure)
function recordFromPieces(pieces, body, g, name, by, opts)
  opts = opts or {}
  local bp = {}
  for i, e in ipairs(pieces) do
    local p = {}
    for k, v in pairs(e) do if type(v) ~= "table" then p[k] = v end end
    p.uid, p.yaw, p.pitch, p.roll = i, e.yaw or 0, e.pitch or 0, e.roll or 0
    p.x, p.y, p.z = e.x or 0, e.y or 0, e.z or 0
    p.parent, p.att, p.sym, p.mir, p.stage = 0, "", 0, "", 0
    bp[i] = p
  end
  local r = { b = body, x = g.x, y = g.y, z = g.z, ux = g.ux, uy = g.uy, uz = g.uz, fx = g.fx, fy = g.fy, fz = g.fz,
              n = name, by = by, t = opts.t or 0, d = opts.d, bp = bp, st = opts.st or {} }
  for k, v in pairs(opts.extra or {}) do r[k] = v end
  return r
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

-- ── the index (where parts are, by 32 m cell of their body's frame) ──────────

local function cell_of(b, x, y, z)
  return string.format("%s|%d|%d|%d", tostring(b), math.floor(x / CELL), math.floor(y / CELL), math.floor(z / CELL))
end
local function index_part(r, p, on)
  local x, y, z = partPose(r, p, 0)
  local k = cell_of(r.b, x, y, z)
  local c = cells[k]
  local key = tostring(r.id) .. ":" .. tostring(p.uid)
  if on then
    if not c then c = {}; cells[k] = c end
    c[key] = { sid = r.id, uid = p.uid }
  elseif c then
    c[key] = nil
    if next(c) == nil then cells[k] = nil end
  end
end
reindex = function()
  cells = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    for _, p in ipairs(r.bp) do index_part(r, p, true) end
  end
end

local function part_in(r, uid)
  for i, p in ipairs(r.bp) do if p.uid == uid then return p, i end end
  return nil
end

-- The placed parts round a body-relative point, nearest first (by their
-- ground points). → { { rec, part, d } … }
function partsNear(body, x, y, z, rad)
  ensure()
  rad = rad or 10.0
  local n = math.ceil(rad / CELL)
  local cx, cy, cz = math.floor(x / CELL), math.floor(y / CELL), math.floor(z / CELL)
  local out = {}
  for i = cx - n, cx + n do
    for j = cy - n, cy + n do
      for k = cz - n, cz + n do
        local c = cells[string.format("%s|%d|%d|%d", tostring(body), i, j, k)]
        if c then
          for _, e in pairs(c) do
            local r = recs[e.sid]
            local p = r and part_in(r, e.uid)
            if p then
              local px, py, pz = partPose(r, p, 0)
              local d = math.sqrt((px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2)
              if d <= rad then out[#out + 1] = { rec = r, part = p, d = d } end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
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
  for _, p in ipairs(r.bp) do index_part(r, p, true) end
  rejoin(r, nil)
  write(r)
  write_index()
  bump()
  return r.id
end

local spawn_part, despawn_part
-- Join a part to structure `id` (a bp entry in its frame; uid is assigned).
-- Spawned at once when the structure is. → uid | nil
function addPart(id, part)
  ensure()
  local r = recs[id]
  if not r then return nil end
  local u = 0
  for _, p in ipairs(r.bp) do u = math.max(u, p.uid or 0) end
  part.uid = part.uid and not part_in(r, part.uid) and part.uid or (u + 1)
  part.yaw, part.pitch, part.roll = part.yaw or 0, part.pitch or 0, part.roll or 0
  part.parent, part.att, part.sym, part.mir, part.stage = part.parent or 0, part.att or "", part.sym or 0, part.mir or "", part.stage or 0
  r.bp[#r.bp + 1] = part
  index_part(r, part, true)
  rejoin(r, pts_of({ part }))
  write(r)
  bump()
  if live[id] and spawn_part then spawn_part(r, live[id], part) end
  return part.uid
end

-- Take parts out of structure `id`; the record goes with its last part.
-- → { part … } (the entries taken, for an undo), rec_gone
function removeParts(id, uids)
  ensure()
  local r = recs[id]
  if not r then return {}, false end
  local out = {}
  for _, u in ipairs(uids or {}) do
    local p, i = part_in(r, u)
    if p then
      index_part(r, p, false)
      if despawn_part then despawn_part(id, u) end
      table.remove(r.bp, i)
      if r.st then r.st[tostring(u)] = nil end
      out[#out + 1] = p
    end
  end
  if #r.bp == 0 then
    remove(id)
    return out, true
  end
  if #out > 0 then rejoin(r, pts_of(out)) end
  write(r)
  bump()
  return out, false
end

function getPart(id, uid) ensure() local r = recs[id]; return r and part_in(r, uid) or nil end

-- Re-write a record already in the store (a part state, a rename).
function put(r)
  ensure()
  if not (r and recs[r.id]) then return false end
  recs[r.id] = r
  rejoin(r, nil)
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
  for _, p in ipairs(r.bp) do index_part(r, p, false) end
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

-- (a part node, or its footing, leaves: its owner entry goes with it)
local function drop_node(n)
  if not n then return end
  pcall(function() owner[n.id] = nil end)
  if n.valid then n:destroy() end
end

-- A part with behaviour (parts_base `script`, e.g. the Build Stand's
-- craft_stand): its script hears when the part's node lands and goes.
local function hook_of(p)
  local pb = parts_lib()
  local def = pb and p and pb.partInfo(p.id)
  local s = def and def.script and findScript and findScript(def.script) or nil
  return s
end
-- (builderperf) a plain two-faced wall has no script, but kit_live hides its
-- inside face from outside it: it hears the wall come and go
local function is_cull_wall(def) return def and def.kit and def.faces2 and def.snap == "wall" and def.script ~= "kit_live" end
local function hook_gone(id, uid)
  local r = recs and recs[id]
  local p = r and part_in(r, uid)
  local h = p and hook_of(p)
  if h and h.gone then pcall(h.gone, id, uid) end
  if p and not h then
    local pb = parts_lib()
    if is_cull_wall(pb and pb.partInfo(p.id)) then
      local KL = findScript and findScript("kit_live")
      if KL and KL.wallGone then pcall(KL.wallGone, id, uid) end
    end
  end
end

despawn = function(id)
  local L = live[id]
  if not L then return end
  for uid, n in pairs(L.nodes) do drop_node(n); hook_gone(id, uid) end
  for _, n in pairs(L.feet or {}) do drop_node(n) end
  live[id] = nil
end

despawn_part = function(id, uid)
  local L = live[id]
  if not L then return end
  if L.nodes[uid] then hook_gone(id, uid) end
  if L.asked then L.asked[uid] = nil end
  drop_node(L.nodes[uid]); L.nodes[uid] = nil
  if L.feet then drop_node(L.feet[uid]); L.feet[uid] = nil end
end

-- Spawn a part's node again (its bp fields changed: a stand's height). The
-- old node goes at once; the new one lands a frame later.
function respawnPart(id, uid)
  ensure()
  local r, L = recs[id], live[id]
  local p = r and part_in(r, uid)
  if not (p and L and spawn_part) then return false end
  despawn_part(id, uid)
  spawn_part(r, L, p)
  return true
end

-- A part's own state (machines, a stand's craft): rec.st[tostring(uid)], a
-- plain table of plain values (the save holds four tables deep: rec → st →
-- the part's → one more). → table | nil
function partState(id, uid)
  ensure()
  local r = recs[id]
  local st = r and r.st
  return st and st[tostring(uid)] or nil
end
-- Write (t) or clear (nil) a part's state; saved at once. → ok
function setPartState(id, uid, t)
  ensure()
  local r = recs[id]
  if not (r and part_in(r, uid)) then return false end
  r.st = r.st or {}
  r.st[tostring(uid)] = t
  write(r)
  bump()
  return true
end

-- (S2) a node another script made for part `uid` of structure `sid` (a live
-- part under the structure's vessel): partOfNode finds it, as a prefab's.
function adopt(node, sid, uid)
  if node and node.valid ~= false then owner[node.id] = { sid = sid, uid = uid } end
end
-- Is structure `id` spawned (its world in focus or within spawn_range)?
function isLive(id) return live[id] ~= nil end
function unadopt(node) if node then pcall(function() owner[node.id] = nil end) end end

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
function nodeOf(id, uid) local L = live[id]; local n = L and L.nodes[uid]; return (n and n.valid) and n or nil end
function footOf(id, uid) local L = live[id]; local n = L and L.feet and L.feet[uid]; return (n and n.valid) and n or nil end

-- A hit node, or one of its children up to three deep (a "Wall N" collider,
-- the hab's Shell), → its structure record and part, or nil.
function partOfNode(n)
  ensure()
  for _ = 0, 3 do
    if not n then return nil end
    local ok, nid = pcall(function() return n.id end)
    local e = ok and owner[nid]
    if e then
      local r = recs[e.sid]
      local p = r and part_in(r, e.uid)
      if p then return r, p end
      return nil
    end
    local okp, par = pcall(function() return n.parent end)
    n = okp and par or nil
  end
  return nil
end

-- THE FOOTING: a cast concrete block under a part on sloping ground, built
-- once per size (mesh.build, UVs in metres so the concrete keeps its scale),
-- drawn on a node parented to the planet like the part. Visual: the ground
-- under it is levelled to the part's base, which is what holds it up.
local foot_mesh = {}
local FOOT_MAT = { texture = "textures/base/concrete_albedo.png", normalMap = "textures/base/concrete_normal.png",
                   roughnessMap = "textures/base/concrete_orm.png", occlusionMap = "textures/base/concrete_orm.png",
                   color = { 0.92, 0.91, 0.88 }, roughness = 1.0, metallic = 0.0, shading = "physical" }
local function footing_mesh(ft)
  local key = string.format("%.2f|%.2f|%.2f", ft.hx, ft.hz, ft.d)
  if foot_mesh[key] then return foot_mesh[key] end
  if not (mesh and mesh.build) then return nil end
  local hx, hz, top, bot = ft.hx, ft.hz, -0.02, -ft.d
  local P, I, N, UV = {}, {}, {}, {}
  local function quad(a, b, c, d, n, uw, vh)
    local base = #P / 3
    for _, v in ipairs({ a, b, c, d }) do P[#P + 1] = v[1]; P[#P + 1] = v[2]; P[#P + 1] = v[3]; N[#N + 1] = n[1]; N[#N + 1] = n[2]; N[#N + 1] = n[3] end
    for _, t in ipairs({ { 0, 0 }, { uw, 0 }, { uw, vh }, { 0, vh } }) do UV[#UV + 1] = t[1] / 2; UV[#UV + 1] = t[2] / 2 end
    for _, k in ipairs({ 1, 2, 3, 1, 3, 4 }) do I[#I + 1] = base + k end
  end
  local h = top - bot
  quad({ -hx, top, hz }, { hx, top, hz }, { hx, top, -hz }, { -hx, top, -hz }, { 0, 1, 0 }, 2 * hx, 2 * hz)
  quad({ -hx, top, hz }, { -hx, bot, hz }, { hx, bot, hz }, { hx, top, hz }, { 0, 0, 1 }, h, 2 * hx)
  quad({ hx, top, -hz }, { hx, bot, -hz }, { -hx, bot, -hz }, { -hx, top, -hz }, { 0, 0, -1 }, h, 2 * hx)
  quad({ hx, top, hz }, { hx, bot, hz }, { hx, bot, -hz }, { hx, top, -hz }, { 1, 0, 0 }, h, 2 * hz)
  quad({ -hx, top, -hz }, { -hx, bot, -hz }, { -hx, bot, hz }, { -hx, top, hz }, { -1, 0, 0 }, h, 2 * hz)
  local ok, name = pcall(mesh.build, { positions = P, indices = I, normals = N, uvs = UV, scene = true })
  if not ok then if log then log("structures: footing mesh failed: " .. tostring(name)) end return nil end
  foot_mesh[key] = name
  return name
end

spawn_part = function(r, L, p, noFoot)
  L.asked = L.asked or {}
  L.asked[p.uid] = true
  local pb = parts_lib()
  local planet = find and find(r.b)
  local b = space and space.body and space.body(r.b)
  local def = pb and pb.partInfo(p.id)
  if not (def and def.prefab and planet and b and spawn) then return end
  -- (S2: a live part — a VAB part placed with the kit — is drawn as a part of
  -- its structure's anchored vessel, struct_live.lua: not a static prefab)
  if def.live then
    local SL = findScript and findScript("struct_live")
    if SL and SL.changed then pcall(SL.changed, r.id) end
    return
  end
  local x, y, z, U, F = partPose(r, p, def.seat)
  local function mine() return live[r.id] == L and recs and recs[r.id] == r and part_in(r, p.uid) == p end
  -- (Ty 11-10) a hab segment that is a junction is drawn as its variant
  local prefab = def.prefab
  if def.join and p.hj then
    local PK = findScript and findScript("parts_kit")
    local vd = PK and PK.joinId and pb.partInfo(PK.joinId(p.id, p.hj))
    if vd and vd.prefab then prefab = vd.prefab end
  end
  -- (only the newest spawn of a part lands: a re-shape swaps the node in place,
  -- the old one going as the new one arrives, so nothing blinks)
  L.gen = L.gen or {}
  local gen = (L.gen[p.uid] or 0) + 1
  L.gen[p.uid] = gen
  L.spawning = L.spawning + 1
  local ok = pcall(spawn, prefab, vec3(b.x + x, b.y + y, b.z + z), function(inst)
    L.spawning = L.spawning - 1
    if not mine() or L.gen[p.uid] ~= gen then inst:destroy() return end
    local prev = L.nodes[p.uid]
    if prev and prev ~= inst then drop_node(prev) end
    -- (setUp points −Z along the vector given: +Z, the part's front, faces F)
    inst:setUp(vec3(U.x, U.y, U.z), vec3(-F.x, -F.y, -F.z))
    inst.x, inst.y, inst.z = x, y, z
    inst.name = def.prefab
    L.nodes[p.uid] = inst
    owner[inst.id] = { sid = r.id, uid = p.uid }
    -- (X8) a film or a wall-mounted fitting (a decal, grime, a light, a
    -- rack) casts nothing worth the sun map's draw: off, it and its meshes
    if def.kit and (def.film or def.snap == "mount") then
      local function noshadow(n, depth)
        pcall(function() n.castShadow = false end)
        if depth > 0 then
          local okc, kids = pcall(n.children, n)
          if okc and kids then for _, k in ipairs(kids) do noshadow(k, depth - 1) end end
        end
      end
      noshadow(inst, 2)
    end
    -- (S4: its paint and the dust it has gathered; kit_paint.lua)
    if def.kit then
      local KP = findScript and findScript("kit_paint")
      if KP and KP.applyPart then pcall(KP.applyPart, r, p, def, inst) end
    end
    if def.script then
      local h = findScript and findScript(def.script)
      if h and h.spawned then
        local okh, err = pcall(h.spawned, r, p, inst)
        if not okh and log then log("structures: " .. tostring(def.script) .. ".spawned: " .. tostring(err)) end
      end
    elseif is_cull_wall(def) then
      local KL = findScript and findScript("kit_live")
      if KL and KL.wallSpawned then pcall(KL.wallSpawned, r, p, inst) end
    end
  end, planet)
  if not ok then L.spawning = L.spawning - 1 end
  local ft = (not noFoot) and p.ft or nil
  if type(ft) == "table" and ft.d and ft.d > 0.05 and createNode then
    local m = footing_mesh(ft)
    if m then
      local gx, gy, gz = partPose(r, p, 0)
      createNode("BaseFooting", planet, function(n)
        if not mine() then n:destroy() return end
        n:setUp(vec3(U.x, U.y, U.z), vec3(-F.x, -F.y, -F.z))
        n.x, n.y, n.z = gx, gy, gz
        n.model = m
        pcall(n.setMaterial, n, FOOT_MAT)
        L.feet = L.feet or {}
        L.feet[p.uid] = n
        owner[n.id] = { sid = r.id, uid = p.uid }
      end)
    end
  end
end

-- (Ty 11-10) a segment's junction code changed: its node is drawn again as
-- the variant, swapped in place (spawn_part drops the old node as the new one
-- lands). Only a part already asked for: a new part spawns by addPart.
reshapes = 0          -- probes: segments re-drawn for a new junction code
reshape = function(r, p)
  local L = live[r.id]
  if not (L and L.asked and L.asked[p.uid]) then return end
  reshapes = reshapes + 1
  spawn_part(r, L, p, true)
end

-- (X8) the paced queue: { { r, L, i } … } drained `pace` parts a frame
local paceq = {}
pacedParts = 0        -- probes: parts spawned through the queue
local function spawn_rec(r, paced)
  if live[r.id] then return end
  if join_pending then join_all() end
  local pb = parts_lib()
  local planet = find and find(r.b)
  local b = space and space.body and space.body(r.b)
  if not (pb and planet and b and spawn) then return end
  local L = { nodes = {}, feet = {}, spawning = 0 }
  live[r.id] = L
  if paced and #r.bp > ((params and params.pace) or 12) then
    paceq[#paceq + 1] = { r = r, L = L, i = 1 }
    return
  end
  for _, p in ipairs(r.bp) do spawn_part(r, L, p) end
end
local function drain_pace()
  local left = (params and params.pace) or 12
  while left > 0 and #paceq > 0 do
    local q = paceq[1]
    -- (unloaded, removed or respawned meanwhile: its queue goes with it)
    if live[q.r.id] ~= q.L or not recs or recs[q.r.id] ~= q.r then
      table.remove(paceq, 1)
    else
      local p = q.r.bp[q.i]
      if not p then table.remove(paceq, 1)
      else
        q.i = q.i + 1
        if not (q.L.asked and q.L.asked[p.uid]) then spawn_part(q.r, q.L, p); pacedParts = pacedParts + 1 end
        left = left - 1
      end
    end
  end
end
function pacing() return #paceq end

-- Spawn this one now (a placement: no waiting for the 1 Hz check).
function spawnNow(id) ensure() local r = recs[id]; if r and not held[id] then spawn_rec(r) end end

-- (playtest 11-09: the Base Hub's builder) A structure held out of the world
-- while the full builder edits it: its nodes (and its live vessel, which
-- struct_live drops when isLive goes false) go, so the builder's copies are
-- the only ones drawn and the camera meets no invisible walls; released, it
-- is spawned again from its records as they now stand. → ok
function suspend(id, on)
  ensure()
  if not recs[id] then held[id] = nil return false end
  if on then
    held[id] = true
    despawn(id)
  else
    held[id] = nil
    spawn_rec(recs[id])
  end
  bump()
  return true
end
function suspended(id) return held[id] == true end

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
  owner = {}
  paceq = {}
  load()
end

function update(node, dt)
  ensure()
  if #paceq > 0 then drain_pace() end
  local t = time or 0
  if t - check_t < 1.0 or #order == 0 then return end
  check_t = t
  local fx, fy, fz = focus()
  local dom = fx and space.dominant(fx, fy, fz) or nil
  local range = (params and params.spawn_range) or 20000
  local rin, rout = (params and params.ruin_in) or 650, (params and params.ruin_out) or 800
  for _, id in ipairs(order) do
    local r = recs[id]
    local want = false
    if fx then
      if r.ru then
        -- (X8) a ruin: by distance from the focus, with hysteresis
        local b = r.b == dom and space.body(r.b)
        if b then
          local d = math.sqrt((b.x + r.x - fx) ^ 2 + (b.y + r.y - fy) ^ 2 + (b.z + r.z - fz) ^ 2)
          want = d < (live[id] and rout or rin)
        end
      elseif r.b == dom then want = true
      else
        local b = space.body(r.b)
        if b then want = math.sqrt((b.x + r.x - fx) ^ 2 + (b.y + r.y - fy) ^ 2 + (b.z + r.z - fz) ^ 2) < range end
      end
    end
    if want and not held[id] then spawn_rec(r, true) elseif live[id] and not want then despawn(id) end
  end
end
