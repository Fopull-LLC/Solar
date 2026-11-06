-- DEBRIS PACK — far, spent pieces leave the scene and come back when you do.
--
-- A staging, a booster ring, a part torn off: each leaves a bare assembly (the
-- split's root and its part nodes, CRAFT_TAG and the flight's tag on every
-- part; vessel_controller separateAt) with no controller, and a wreck whose
-- pod is gone is a craft that is lost (isLost). Nobody flies them. Far away
-- the engine already takes their physics off (distant-craft LOD, 700 m from
-- the camera), but every one still costs its nodes, its draws and every scan
-- that walks the tagged parts. So once a piece is more than PACK_DIST from
-- the camera AND from the craft being flown (or the crew on foot), for
-- PACK_HOLD seconds, it is written down and taken out of the scene; closer
-- than UNPACK_DIST it is built again where it is now, the way flight_ops
-- rebuilds a parked craft (a DebrisRoot, the parts spawned under it at their
-- places, one assembly.rebuild, the velocity given once it has its mass).
--
-- Where it is now (docs/positions-and-frames.md: body-relative, never a world
-- point kept):
--   landed     down and stopped: it stays where it lies, on its body
--   orbit      its conic clears the ground: carried along it to now
--              (space.propagate), as the fleet carries a parked craft
--   otherwise  (a piece the LOD froze mid-fall) its state is kept as it was
--
-- Packed pieces live in the save (`debris.packed`, the oldest dropped past
-- PACK_MAX), so they outlast a reload as the fleet does. A revert takes back
-- the ones its flight shed (forgetTag, from vessel_spawner's clear_flight).
-- A piece with a command part of its own leaves as a craft (r2SplitCraft) and
-- is the fleet's: dormant and cheap already, and on the Tracking Station's board.
--
-- Fast-falling debris rides on spheres (FALLING DEBRIS ROLLS ON SPHERES below).
--
-- Globals (probes, tests): active (false: nothing is packed, everything packed
-- comes back, nothing rides on spheres), PACK_DIST, UNPACK_DIST, PACK_HOLD, packedCount(), packedList(),
-- forgetTag(tag), packAll() (every candidate now, whatever the distance),
-- unpackAll(), stats = { packed, unpacked, scanned, last_ms }.

local KEY = "debris.packed"
local CRAFT_TAG = "craftpart"

active = true
PACK_DIST = 1000.0     -- m from the camera and the flown craft before a piece packs
UNPACK_DIST = 800.0    -- m: closer than this it is built again (hysteresis below PACK_DIST)
PACK_HOLD = 5.0        -- s a piece must have been far (and a stage at least this old)
PACK_MAX = 200         -- packed pieces kept; the oldest go first
SCAN_EVERY = 1.0       -- s between scans
stats = { packed = 0, unpacked = 0, scanned = 0, last_ms = 0 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- YXZ Euler → the frame's axes (as flight_ops / vessel_controller).
local function basis_of(pitch, yaw, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cx, sx = math.cos(pitch), math.sin(pitch)
  local cz, sz = math.cos(roll), math.sin(roll)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end

local store = nil          -- the packed records, { [id] = rec }, as last read or written
local function packed()
  if not store then
    local s = save.get(KEY)
    store = type(s) == "table" and s or {}
  end
  return store
end
local function put()
  -- the oldest go once there are too many
  local ids = {}
  for id in pairs(store) do ids[#ids + 1] = id end
  if #ids > PACK_MAX then
    table.sort(ids, function(a, b) return (store[a].stime or 0) < (store[b].stime or 0) end)
    for i = 1, #ids - PACK_MAX do store[ids[i]] = nil end
  end
  save.set(KEY, store)
  packVersion = (packVersion or 0) + 1
end

local seq = 0
local function next_id()
  seq = (save.get("debris.seq") or seq) + 1
  save.set("debris.seq", seq)
  return "d" .. seq
end

-- Where to measure from: the camera, and the craft flown or the crew on foot.
local function viewpoints()
  local out = {}
  if cam_x then out[#out + 1] = { cam_x, cam_y, cam_z } end
  local pc = ref("planet_camera")
  if pc and pc.cam_x then out[#out + 1] = { pc.cam_x, pc.cam_y, pc.cam_z } end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    local n = v.node
    if v.piloting and n and n.valid ~= false then out[#out + 1] = { n.x, n.y, n.z } end
  end
  local a = find and find("Astronaut")
  if a and a.visible ~= false then out[#out + 1] = { a.x, a.y, a.z } end
  return out
end
local function nearest(vp, x, y, z)
  local d = math.huge
  for _, p in ipairs(vp) do d = math.min(d, len(x - p[1], y - p[2], z - p[3])) end
  return d
end

-- The bare roots in the scene a piece of debris sits under: top level, not a
-- craft with a live controller (a lost one is debris), not a world.
local function debris_roots()
  local crafts = {}
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    local n = v.node
    if n and n.valid ~= false and not (v.isLost and v.isLost()) then crafts[n.id] = true end
  end
  local roots = {}
  for _, p in ipairs(findTagged and findTagged(CRAFT_TAG) or {}) do
    local r = p.valid ~= false and p.parent
    if r and r.valid ~= false and r.parent == nil and not crafts[r.id] and not roots[r.id]
      and not (r.name and space.body(r.name)) then
      roots[r.id] = r
    end
  end
  return roots
end

-- A root as a record, or nil when it can't be described (a part with no
-- prefab name, no body under it).
local function describe(r)
  local info = assembly.info(r)
  local ox, oy, oz = r.x, r.y, r.z
  local bname = space.dominant(ox, oy, oz)
  local b = bname and space.body(bname)
  if not b then return nil end
  local parts, tags = {}, {}
  for _, c in ipairs(r:children()) do
    if c.valid ~= false and c.hasTag and c:hasTag(CRAFT_TAG) then
      for _, t in ipairs(c.tags or {}) do if t ~= CRAFT_TAG then tags[t] = true end end
      parts[#parts + 1] = { prefab = c.name, x = c.x, y = c.y, z = c.z, yaw = c.yaw or 0, pitch = c.pitch or 0, roll = c.roll or 0 }
    end
  end
  if #parts == 0 then return nil end
  local vx, vy, vz = 0, 0, 0
  if info and info.vel then vx, vy, vz = info.vel.x, info.vel.y, info.vel.z end
  local rx, ry, rz = ox - b.x, oy - b.y, oz - b.z
  local speed = len(vx, vy, vz)
  local kind = "kept"
  if info and info.grounded and speed < 1.5 then
    kind = "landed"
  elseif space.elements and (b.mu or 0) > 0 then
    local o = space.elements(ox, oy, oz, vx, vy, vz)
    if o and o.periapsis and o.periapsis > (b.radius or 0) * 1.02 + 5 then kind = "orbit" end
  end
  local tl = {}
  for t in pairs(tags) do tl[#tl + 1] = t end
  table.sort(tl)
  return { name = r.name, body = bname, x = rx, y = ry, z = rz,
           vx = (kind == "landed") and 0 or vx, vy = (kind == "landed") and 0 or vy, vz = (kind == "landed") and 0 or vz,
           pitch = r.pitch or 0, yaw = r.yaw or 0, roll = r.roll or 0,
           kind = kind, stime = space.time and space.time() or 0, tags = tl, parts = parts }
end

-- Where a record is now (world, as space.body reads this pass) and its velocity.
local function where(rec)
  local b = space.body(rec.body)
  if not b then return nil end
  local x, y, z, vx, vy, vz = rec.x, rec.y, rec.z, rec.vx or 0, rec.vy or 0, rec.vz or 0
  if rec.kind == "orbit" and space.propagate and space.time and (b.mu or 0) > 0 then
    local dt = space.time() - (rec.stime or 0)
    if dt > 0 and dt < 1e7 then
      local px, py, pz, pvx, pvy, pvz = space.propagate(x, y, z, vx, vy, vz, b.mu, dt)
      if pvx then x, y, z, vx, vy, vz = px, py, pz, pvx, pvy, pvz end
    end
  end
  return b.x + x, b.y + y, b.z + z, vx, vy, vz, b
end

local far_since = {}       -- root id → when it was first seen far
local on_spheres = {}      -- root id → true while its parts ride on spheres (FALLING DEBRIS below)
local building = {}        -- packed id → true while its parts are spawning

local function pack(r)
  local rec = describe(r)
  if not rec then return false end
  local id = next_id()
  packed()[id] = rec
  put()
  far_since[r.id] = nil
  on_spheres[r.id] = nil
  destroy(r)
  stats.packed = stats.packed + 1
  log(string.format("debris: packed %s (%d parts, %s, %s)", tostring(rec.name), #rec.parts, rec.kind, rec.body))
  return true
end

local function unpack(id, rec)
  local wx, wy, wz, vx, vy, vz, b = where(rec)
  if not wx then return false end
  if rec.kind == "landed" then
    -- the ground has to be there first, or it falls through a world that
    -- hasn't streamed in yet (flight_ops respawn waits the same way)
    local ux, uy, uz = rec.x, rec.y, rec.z
    local ul = len(ux, uy, uz)
    if ul < 1e-3 then return false end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    if terrain and terrain.warm then terrain.warm(rec.body) end
    local fo = ref("flight_ops")
    local hit = fo and fo.landing_surface and fo.landing_surface(wx, wy, wz, ux, uy, uz)
    if not hit then return false end
    local above = (wx - hit.x) * ux + (wy - hit.y) * uy + (wz - hit.z) * uz
    if above > 1.0 or above < -0.05 then wx, wy, wz = wx - ux * above, wy - uy * above, wz - uz * above end
    wx, wy, wz = wx + ux * 0.05, wy + uy * 0.05, wz + uz * 0.05
  end
  building[id] = true
  local rx, up, rz = basis_of(rec.pitch or 0, rec.yaw or 0, rec.roll or 0)
  local total, landed = #rec.parts, 0
  -- (a plain node is no compound: the root is DebrisRoot, the Vessel's
  -- dynamic assembly body with no controller)
  spawn("DebrisRoot", vec3(wx, wy, wz), function(root)
    root:setAngles(rec.yaw or 0, rec.pitch or 0, rec.roll or 0)
    root.name = rec.name or "Debris"
    for _, d in ipairs(rec.parts) do
      local px = wx + rx[1] * d.x + up[1] * d.y + rz[1] * d.z
      local py = wy + rx[2] * d.x + up[2] * d.y + rz[2] * d.z
      local pz = wz + rx[3] * d.x + up[3] * d.y + rz[3] * d.z
      spawn(d.prefab, vec3(px, py, pz), function(part)
        part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
        if part.addTag then
          part:addTag(CRAFT_TAG)
          for _, t in ipairs(rec.tags or {}) do part:addTag(t) end
        end
        landed = landed + 1
        if landed == total then
          assembly.rebuild(root, function(s)
            building[id] = nil
            local i = assembly.info(s)
            if i and rec.kind ~= "landed" then
              assembly.impulseAt(s, vec3(vx * i.mass, vy * i.mass, vz * i.mass), i.com)
            end
          end)
        end
      end, root)
    end
  end)
  packed()[id] = nil
  put()
  stats.unpacked = stats.unpacked + 1
  log(string.format("debris: back in the scene: %s (%d parts, %s)", tostring(rec.name), #rec.parts, rec.kind))
  return true
end

-- Every candidate packed now, whatever the distance (probes); → how many.
function packAll()
  local n = 0
  for _, r in pairs(debris_roots()) do if pack(r) then n = n + 1 end end
  return n
end
-- Everything packed built again now (probes, `active = false`); → how many.
function unpackAll()
  local n = 0
  for id, rec in pairs(packed()) do if unpack(id, rec) then n = n + 1 end end
  return n
end
function packedCount()
  local n = 0
  for _ in pairs(packed()) do n = n + 1 end
  return n
end
function packedList()
  local out = {}
  for id, rec in pairs(packed()) do out[#out + 1] = { id = id, name = rec.name, kind = rec.kind, body = rec.body, parts = #rec.parts } end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
-- Every packed piece with its pose as written (body-relative, the game time
-- it was written, and whether it rides a conic): the Tracking Station
-- carries an orbiting one to now itself, against the frame's own body read.
-- Changes only when a piece packs or unpacks (`packVersion`).
packVersion = 0
function packedPoses()
  local out = {}
  for id, rec in pairs(packed()) do
    out[#out + 1] = { id = id, name = rec.name, kind = rec.kind, body = rec.body, parts = #(rec.parts or {}),
                      x = rec.x, y = rec.y, z = rec.z, vx = rec.vx or 0, vy = rec.vy or 0, vz = rec.vz or 0,
                      stime = rec.stime or 0, prefab = rec.parts and rec.parts[1] and rec.parts[1].prefab or nil }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
-- Probes: read the packed records from the save again (one written by hand).
function reloadStore() store = nil; packVersion = (packVersion or 0) + 1 end
-- The Tracking Station's FORGET: a packed piece's record goes (it is never
-- built again). → ok, why
function forget(id)
  if not packed()[id] then return false, "no such piece" end
  packed()[id] = nil
  put()
  return true
end
-- A revert takes back what its flight shed, packed or not.
function forgetTag(tag)
  if not tag then return 0 end
  local n = 0
  for id, rec in pairs(packed()) do
    for _, t in ipairs(rec.tags or {}) do
      if t == tag then packed()[id] = nil; n = n + 1; break end
    end
  end
  if n > 0 then put() end
  return n
end

-- ── FALLING DEBRIS ROLLS ON SPHERES ─────────────────────────────────────────
-- (2026-11-03, tools/perf/sweepprobe.sh) A compound that moves more than half
-- its thinnest part in a tick is swept against the ground so it stops at the
-- first touch, and the engine sweeps every box from its eight corners and its
-- centre, the ground's distance field read at each, every tick, however high
-- it is: a falling 8-part stage cost 2.7 ms of physics a frame, four of them
-- 31 ms (the frame then ran slow and every tick cost more). The same stage on
-- a sphere inside each part's box sweeps one point a part: 0.28 ms, four of
-- them 1.2 ms. So a bare piece of debris that is moving fast in the open
-- (over FALL_SPEED, not grounded, nothing along its path for FALL_LOOK
-- seconds) has its parts' boxes made spheres, and gets them back before it
-- reaches anything (the ground, a roof, a craft) or once it slows: it lands,
-- tumbles and lies on its real boxes. A switch is one assembly.rebuild.
FALL_SPEED = 12.0      -- m/s: faster than this a piece is swept every tick
FALL_LOOK = 1.5        -- s of travel that must be clear before it rides on spheres
FALL_EVERY = 0.25      -- s between looks
fallStats = { spheres = 0, boxes = 0 }

local function set_shapes(r, sphere)
  for _, c in ipairs(r:children()) do
    local rb = c.getcomponent and c:getcomponent("RigidBody")
    if rb then
      if sphere and rb.shape == 2 then
        rb.radius = math.max(0.05, math.min(rb.half_x or 0.5, rb.half_y or 0.5, rb.half_z or 0.5))
        rb.shape = 0
      elseif not sphere and rb.shape == 0 and c.hasTag and c:hasTag(CRAFT_TAG) then
        rb.shape = 2
      end
    end
  end
  assembly.rebuild(r)
  if sphere then on_spheres[r.id] = true; fallStats.spheres = fallStats.spheres + 1
  else on_spheres[r.id] = nil; fallStats.boxes = fallStats.boxes + 1 end
end

-- Is there anything within `secs` of travel along v (or a margin round it)?
local function path_clear(r, info, secs)
  local v = info.vel
  local sp = len(v.x, v.y, v.z)
  if sp < 1e-3 or not raycast then return false end
  local c = info.com or { x = r.x, y = r.y, z = r.z }
  local reach = sp * secs + 25.0
  local skip = r:children()
  skip[#skip + 1] = r
  local hit = raycast(c.x, c.y, c.z, v.x / sp, v.y / sp, v.z / sp, reach, { ignore = skip })
  return hit == nil
end

function fallTick()
  local alive = {}
  for id, r in pairs(debris_roots()) do
    local info = assembly.info(r)
    if info and info.vel then
      alive[id] = true
      local sp = len(info.vel.x, info.vel.y, info.vel.z)
      local open = sp > FALL_SPEED and not info.grounded and not info.anchored
      if on_spheres[id] then
        if not open or not path_clear(r, info, FALL_LOOK * 0.6) then set_shapes(r, false) end
      elseif open and path_clear(r, info, FALL_LOOK) then
        set_shapes(r, true)
      end
    end
  end
  for id in pairs(on_spheres) do if not alive[id] then on_spheres[id] = nil end end
end

local scan_t, fall_t = 0.0, 0.0
function start(node)
  store = nil
  seq = save.get("debris.seq") or 0
end

function update(node, dt)
  fall_t = fall_t + (dt or 0)
  if fall_t >= FALL_EVERY then
    fall_t = 0.0
    if active then fallTick() end
  end
  scan_t = scan_t + (dt or 0)
  if scan_t < SCAN_EVERY then return end
  scan_t = 0.0
  local gm = ref("game_manager")
  if gm and gm.loading then return end
  local t0 = app and app.wallClock and app.wallClock() or 0
  local vp = viewpoints()
  if #vp == 0 then return end
  local now = time or 0
  if active then
    local n, seen = 0, {}
    for id, r in pairs(debris_roots()) do
      n = n + 1
      seen[id] = true
      local d = nearest(vp, r.x, r.y, r.z)
      if d > PACK_DIST then
        far_since[id] = far_since[id] or now
        if now - far_since[id] >= PACK_HOLD then pack(r) end
      else
        far_since[id] = nil
      end
    end
    stats.scanned = n
    for id in pairs(far_since) do if not seen[id] then far_since[id] = nil end end
  end
  for id, rec in pairs(packed()) do
    if not building[id] then
      if not active then
        unpack(id, rec)
      else
        local wx, wy, wz = where(rec)
        if wx and nearest(vp, wx, wy, wz) < UNPACK_DIST then unpack(id, rec) end
      end
    end
  end
  stats.last_ms = ((app and app.wallClock and app.wallClock() or 0) - t0) * 1000
end
