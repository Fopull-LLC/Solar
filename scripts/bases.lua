-- BASES — the places the agency has founded (deep-space addendum M1, M3, M5,
-- M9; docs/base-building.md §11). A BASE is a Base Station Tower and every
-- structure within 150 m of it. The home base is base #0: the spaceport, its
-- tower the Tracking Station (nothing in `base.*` changes shape; it is not
-- stored here). Every other base is founded by placing a tower with the
-- Build Kit (base_tower.lua keeps the records in step with the towers).
--
-- On the Build Kit node (scenes/system.ron). The records half is pure: it
-- loads in a luajit test with a stand-in `save`. Every point is kept in its
-- BODY's frame (docs/positions-and-frames.md: the planet moves metres a tick).
--
-- ── RECORDS (in the save) ───────────────────────────────────────────────────
--
--   bases.list   the ids, in founding order        bases.seq   the last id given
--   bases.<id>   { id, b = body, x, y, z (the tower's ground point, body-relative),
--                  n = name, t = agency clock when founded, d = "Day 41, Y2",
--                  by = member id, sid, uid (the tower: structure and part),
--                  down = true while the tower is taken down (a minute's undo
--                  puts it back under the same name),
--                  roles = { fuel = 0.6, … }, rt = when they were last read,
--                  stats = { … } (expansion X7, base_roles.lua; an old
--                  save's bases have none: OUTPOSTs until the first read) }
--
-- ── THE API ─────────────────────────────────────────────────────────────────
--
--   found(body, x, y, z, sid, uid, opts) → id     opts = { name, t, d, by }
--   rename(id, name) → ok, why          get(id)   list() (standing ones)   count()
--   byTower(sid, uid) → rec             setDown(id, down)   forget(id)
--   defaultName() → "Outpost <n>"       cleanName(s) → s | nil, why
--   groundDist(R, a, b) → m along the ground of a world of radius R (pure)
--   spacingWhy(body, x, y, z, R, home, skipId) → nil | why   (towers 300 m apart,
--                                       the home base's Tracking Station too)
--   baseAt(body, x, y, z, R) → rec, d   the base a body-relative point belongs to
--   setRoles(id, roles, t)  setStats(id, stats)   (X7, base_roles.lua; no
--                                       version bump: base_roles has its own)
--   version                             bumps on every change
--
-- The station's and the map's list is base_tower.bases() (the records plus
-- what each tower is doing: power, link, coverage), not this file.

RADIUS = 150.0       -- every structure within this of a tower belongs to its base
-- (playtest 11-09: "the base station can't be placed anywhere". It was 1 km,
-- the spaceport's Tracking Station included, so no tower could stand within a
-- kilometre of home: on a 922 m world that is most of the ground a player
-- builds on first. Two bases only need to keep their 150 m from overlapping.)
SPACING = 2 * RADIUS -- towers at least this far apart, along the ground (300 m)
NAME_MAX = 32

version = 0

local recs, order = nil, {}

local function S() return save end
local KEEP = { "id", "b", "x", "y", "z", "n", "t", "d", "by", "sid", "uid", "down", "roles", "rt", "stats" }
local function plain(r)
  local o = {}
  for _, k in ipairs(KEEP) do o[k] = r[k] end
  return o
end
local function load()
  recs, order = {}, {}
  local sv = S()
  if not (sv and sv.get) then return end
  for _, id in ipairs(sv.get("bases.list") or {}) do
    local r = sv.get("bases." .. tostring(id))
    if type(r) == "table" and r.b and r.x then
      local rec = plain(r)
      rec.id = id
      recs[id] = rec
      order[#order + 1] = id
    end
  end
end
local function ensure() if not recs then load() end end
local function bump() version = version + 1 end
local function write(r) local sv = S(); if sv and sv.set then sv.set("bases." .. tostring(r.id), plain(r)) end end
local function write_index() local sv = S(); if sv and sv.set then sv.set("bases.list", order) end end

function reloadFromSave() recs = nil; load(); bump() end

-- ── pure ────────────────────────────────────────────────────────────────────

-- Metres along the ground between two body-relative points of a world of
-- radius R (the arc of their directions; R nil = the straight line).
function groundDist(R, ax, ay, az, bx, by, bz)
  local la = math.sqrt(ax * ax + ay * ay + az * az)
  local lb = math.sqrt(bx * bx + by * by + bz * bz)
  if not R or la < 1e-6 or lb < 1e-6 then
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
  end
  local c = (ax * bx + ay * by + az * bz) / (la * lb)
  c = math.max(-1, math.min(1, c))
  return math.acos(c) * R
end

function cleanName(s)
  if type(s) ~= "string" then return nil, "a base needs a name" end
  s = s:gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
  if #s == 0 then return nil, "a base needs a name" end
  if #s > NAME_MAX then s = s:sub(1, NAME_MAX):gsub("%s+$", "") end
  return s
end

-- ── the store ───────────────────────────────────────────────────────────────

function defaultName()
  local sv = S()
  local n = ((sv and sv.get and sv.get("bases.seq")) or 0) + 1
  return "Outpost " .. tostring(n)
end

function found(body, x, y, z, sid, uid, opts)
  ensure()
  opts = opts or {}
  local sv = S()
  local seq = ((sv and sv.get and sv.get("bases.seq")) or 0) + 1
  if sv and sv.set then sv.set("bases.seq", seq) end
  local name = cleanName(opts.name) or ("Outpost " .. tostring(seq))
  local r = { id = seq, b = body, x = x, y = y, z = z, n = name, t = opts.t or 0, d = opts.d, by = opts.by,
              sid = sid, uid = uid }
  recs[seq] = r
  order[#order + 1] = seq
  write(r)
  write_index()
  bump()
  return seq
end

function rename(id, name)
  ensure()
  local r = recs[id]
  if not r then return false, "no such base" end
  local s, why = cleanName(name)
  if not s then return false, why end
  for _, o in pairs(recs) do
    if o.id ~= id and not o.down and o.n == s then return false, "another base is called " .. s end
  end
  r.n = s
  write(r)
  bump()
  return true, s
end

-- Taken down (deconstructed, or its placement undone): kept a while under its
-- name, so an undo puts the same base back. `down` = false stands it again
-- (its ground point moved with the tower, if it did).
function setDown(id, down, x, y, z)
  ensure()
  local r = recs[id]
  if not r then return false end
  r.down = down and true or nil
  if x then r.x, r.y, r.z = x, y, z end
  write(r)
  bump()
  return true
end

-- (X7) what the base is for, and what it moved (base_roles.lua). No version
-- bump: the census reads the bases, and base_roles.version tells the station.
function setRoles(id, roles, t)
  ensure()
  local r = recs[id]
  if not r then return false end
  r.roles, r.rt = roles, t
  write(r)
  return true
end
function setStats(id, st)
  ensure()
  local r = recs[id]
  if not r then return false end
  r.stats = st
  write(r)
  return true
end

function forget(id)
  ensure()
  if not recs[id] then return false end
  recs[id] = nil
  for i = #order, 1, -1 do if order[i] == id then table.remove(order, i) end end
  local sv = S()
  if sv then
    if sv.delete then sv.delete("bases." .. tostring(id)) elseif sv.set then sv.set("bases." .. tostring(id), false) end
  end
  write_index()
  bump()
  return true
end

function get(id) ensure() return recs[id] end
function byTower(sid, uid)
  ensure()
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.sid == sid and r.uid == uid then return r end
  end
  return nil
end
-- The standing bases, in founding order (`all` = the taken-down ones too).
function list(all)
  ensure()
  local out = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    if all or not r.down then out[#out + 1] = r end
  end
  return out
end
function count() return #list() end

-- Is a tower allowed here? `home` = { b, x, y, z } the home base's tower (the
-- Tracking Station's ground point, body-relative) or nil. → nil | why
function spacingWhy(body, x, y, z, R, home, skipId)
  ensure()
  local sp = SPACING
  local function fmt(d) return d >= 1000 and string.format("%.1f km", d / 1000) or string.format("%.0f m", d) end
  if home and home.b == body then
    local d = groundDist(R, x, y, z, home.x, home.y, home.z)
    if d < sp then
      return string.format("%s from the spaceport's Tracking Station: towers stand %s apart (%s further out)", fmt(d), fmt(sp), fmt(sp - d))
    end
  end
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.id ~= skipId and not r.down and r.b == body then
      local d = groundDist(R, x, y, z, r.x, r.y, r.z)
      if d < sp then
        return string.format("%s from %s's tower: towers stand %s apart (%s further away)", fmt(d), r.n, fmt(sp), fmt(sp - d))
      end
    end
  end
  return nil
end

-- The base a body-relative point belongs to (within RADIUS of its tower).
function baseAt(body, x, y, z, R)
  ensure()
  local best, bd = nil, RADIUS
  for _, id in ipairs(order) do
    local r = recs[id]
    if not r.down and r.b == body then
      local d = groundDist(R, x, y, z, r.x, r.y, r.z)
      if d <= bd then best, bd = r, d end
    end
  end
  return best, best and bd or nil
end

function start(node)
  if findScripts then
    local all = findScripts("bases")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  recs = nil
  load()
end
