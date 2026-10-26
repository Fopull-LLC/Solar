-- DEPLOYABLES — everything the crew plants in the world that isn't a relay
-- beacon (docs/crew-and-items.md §5.5, §7): the agency's flags today, the
-- fallen crew's remains, and whatever is deployed later. Relay beacons stay
-- comms.lua's (their records and the relay solve live there).
--
-- Lives on the DeployLib node (prefabs/DeployLib), spawned by whoever needs it
-- when the scene has none (the Tracking Station, missions, the tool belt's
-- deploy mode). Reach it with findScript("deployables").
--
-- ── RECORDS (in the save) ───────────────────────────────────────────────────
--
--   dep.list        the ids, in planting order
--   dep.seq         the last id handed out (never reused)
--   dep.<id>        { k = "flag", b = body, x, y, z (body-relative ground),
--                     fx, fy, fz (the way it faces, body-relative: toward
--                     whoever planted it), by = memberId, n = name,
--                     st = space.time(), d = "Day 41, Y2",
--                     photo = "user://flags/<slot>/<id>.jpg" }
--
-- ── THE API ─────────────────────────────────────────────────────────────────
--
--   place(kind, body, gx, gy, gz, opts) → id | nil, why
--        opts = { by = memberId, yaw, name, fx, fy, fz (a world facing),
--                 ceremony = true (plant animation, salute and photo) }
--   remove(id) → true                    (the node goes with it)
--   near(x, y, z, r) → entry | nil, dist (the nearest within r m, any kind)
--   get(id) → entry                      list([kind]) → { entry … }
--   rename(id, name) → ok, why
--   hasFlagOn(body) → bool               flagBodies() → { [body] = n }
--   photoTex(id, fn)                     fn(tex) once the photo is a texture
--   nodeOf(id)                           its live node (or nil, not spawned)
--   snapshot() / restore(snap)           a revert to launch (vessel_spawner)
--   onChanged(fn) → unsubscribe          fn(version) after any change
--   version                              bumps on every change
--
-- An entry is the record plus id, kind, name, body, and gx, gy, gz (the
-- ground point in world space, now).
--
-- Nodes are spawned parented to their planet (as beacons and salvage crates
-- are), but only for records on the world the focus is on, or within 20 km
-- of it: a flag on a world nobody is near costs nothing.

defaults = {
  --@range 1000 100000 --@units m
  spawn_range = 20000.0,
}

-- The flag pole's centre above the ground (tools/gen_flag.py prints it: the
-- engine centres the pole model, the Flag prefab's root).
FLAG_ORIGIN = 0.9425

-- What each kind is: its prefab, how high its origin sits, and its default
-- name. `item` is what a "Pick up" gives back (nil: it can't be carried).
KINDS = {
  flag = { prefab = "Flag", origin = FLAG_ORIGIN, item = "flag", label = "Flag" },
  remains = { prefab = "Remains", origin = 0.18, item = nil, label = "Remains" },
}

version = 0

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local recs = nil       -- id → record (plus node, spawning)
local order = {}       -- ids in planting order
local listeners = {}

local function bump()
  version = version + 1
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, version)
    if not ok and log then log("deployables: a listener failed: " .. tostring(err)) end
  end
end

function onChanged(fn)
  listeners[#listeners + 1] = fn
  return function()
    for i, f in ipairs(listeners) do if f == fn then table.remove(listeners, i) return end end
  end
end

-- The fields a record keeps in the save.
local KEEP = { "k", "b", "x", "y", "z", "fx", "fy", "fz", "by", "n", "st", "d", "photo" }
local function plain(r)
  local o = {}
  for _, k in ipairs(KEEP) do o[k] = r[k] end
  return o
end

local function load()
  recs, order = {}, {}
  for _, id in ipairs((save and save.get and save.get("dep.list")) or {}) do
    local r = save.get("dep." .. tostring(id))
    if type(r) == "table" and r.b and r.x and KINDS[r.k or "flag"] then
      local rec = plain(r)
      rec.k = rec.k or "flag"
      rec.id = id
      recs[id] = rec
      order[#order + 1] = id
    end
  end
end

local function ensure() if not recs then load() end end

local function write_index() save.set("dep.list", order) end
local function write(r) save.set("dep." .. tostring(r.id), plain(r)) end
local function forget(id)
  if save.delete then save.delete("dep." .. tostring(id)) else save.set("dep." .. tostring(id), false) end
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

-- THE AGENCY'S CLOCK: game seconds since the save began, warp included. The
-- sim clock (space.time) starts at 0 every session, so it is accumulated
-- here and kept in the save (`agency.clock`); a flag's date is read off it.
local clock_s, clock_last, clock_saved = nil, nil, -100
local function agency_clock()
  if clock_s == nil then clock_s = tonumber(save and save.get and save.get("agency.clock")) or 0 end
  return clock_s
end
agencyClock = agency_clock

local function tick_clock()
  local now = space and space.time and space.time()
  if type(now) ~= "number" then return end
  agency_clock()
  if clock_last and now > clock_last then clock_s = clock_s + math.min(now - clock_last, 86400 * 30) end
  clock_last = now
  local t = time or 0
  if t - clock_saved > 5 and save and save.set then
    clock_saved = t
    save.set("agency.clock", math.floor(clock_s))
  end
end

-- "Day 41, Y2": 24-hour days, 365-day years, from the agency's clock.
function dateOf(t)
  t = tonumber(t) or 0
  local day = math.floor(t / 86400)
  return string.format("Day %d, Y%d", day % 365 + 1, math.floor(day / 365) + 1)
end

local function game_time() return agency_clock() end

local function entry(r)
  local e = {}
  for k, v in pairs(r) do if k ~= "node" and k ~= "spawning" then e[k] = v end end
  e.kind, e.name, e.body = r.k, r.n, r.b
  local b = space and space.body and space.body(r.b)
  if b then e.gx, e.gy, e.gz = b.x + r.x, b.y + r.y, b.z + r.z end
  e.node = (r.node and r.node.valid) and r.node or nil
  return e
end

function get(id)
  ensure()
  local r = recs[id]
  return r and entry(r) or nil
end

function list(kind)
  ensure()
  local out = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    if r and (not kind or r.k == kind) then out[#out + 1] = entry(r) end
  end
  return out
end

function near(x, y, z, r)
  ensure()
  local best, bd = nil, r or 2.0
  for _, id in ipairs(order) do
    local rec = recs[id]
    local b = space.body(rec.b)
    if b then
      local d = math.sqrt((x - b.x - rec.x) ^ 2 + (y - b.y - rec.y) ^ 2 + (z - b.z - rec.z) ^ 2)
      -- the pole stands up from the ground point: measure to the pole too
      local ux, uy, uz = norm(rec.x, rec.y, rec.z)
      local k = KINDS[rec.k]
      local h = (k and k.origin or 0) * 2
      local px, py, pz = x - b.x - rec.x, y - b.y - rec.y, z - b.z - rec.z
      local along = math.max(0, math.min(h, px * ux + py * uy + pz * uz))
      local dp = math.sqrt((px - ux * along) ^ 2 + (py - uy * along) ^ 2 + (pz - uz * along) ^ 2)
      if dp < d then d = dp end
      if d < bd then best, bd = rec, d end
    end
  end
  if not best then return nil end
  return entry(best), bd
end

function hasFlagOn(body)
  ensure()
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.k == "flag" and r.b == body then return true end
  end
  return false
end

function flagBodies()
  ensure()
  local out = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.k == "flag" then out[r.b] = (out[r.b] or 0) + 1 end
  end
  return out
end

function nodeOf(id)
  ensure()
  local r = recs[id]
  return r and r.node and r.node.valid and r.node or nil
end

-- ── nodes ───────────────────────────────────────────────────────────────────

local function facing_of(r)
  local ux, uy, uz = norm(r.x, r.y, r.z)
  local fx, fy, fz = r.fx or 0, r.fy or 0, r.fz or 0
  -- flatten onto the ground plane
  local d = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-4 then
    -- any tangent
    fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
    if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
  end
  fx, fy, fz = norm(fx, fy, fz)
  return ux, uy, uz, fx, fy, fz
end

local function despawn(r)
  if r.node and r.node.valid then r.node:destroy() end
  r.node = nil
end

local fresh = {}   -- id → true: a node to be spawned with its planting ceremony

-- A flag's script asks which record it is: → id, entry, fresh (the planting
-- ceremony to play, once) — nil when the node isn't one of ours.
function claim(node)
  ensure()
  if not node then return nil end
  for _, id in ipairs(order) do
    local r = recs[id]
    if r.node and r.node.valid and r.node.id == node.id then
      local f = fresh[id]
      fresh[id] = nil
      return id, entry(r), f
    end
  end
  return nil
end


local function spawn_node(r)
  if r.node and r.node.valid then return true end
  if r.spawning then return false end
  local k = KINDS[r.k]
  if not k then return false end
  local planet = find and find(r.b)
  local b = space.body(r.b)
  if not (planet and b) then return false end
  local ux, uy, uz, fx, fy, fz = facing_of(r)
  local h = k.origin
  local lx, ly, lz = r.x + ux * h, r.y + uy * h, r.z + uz * h
  r.spawning = true
  local ok = pcall(spawn, k.prefab, vec3(b.x + lx, b.y + ly, b.z + lz), function(inst)
    r.spawning = false
    if not recs or recs[r.id] ~= r then inst:destroy() return end
    -- +Z toward the planter: the cloth's printed face (its +Z side, in the
    -- flag's XY plane) faces them (setUp points -Z along the forward given)
    inst:setUp(vec3(ux, uy, uz), vec3(-fx, -fy, -fz))
    inst.x, inst.y, inst.z = lx, ly, lz
    inst.name = (k.prefab == "Flag") and "Flag" or k.prefab
    r.node = inst
    -- (the flag's own script has not run yet this frame: it claims its
    -- record from start(), through claim(node))
  end, planet)
  if not ok then r.spawning = false end
  return ok
end

-- ── place / remove / rename ─────────────────────────────────────────────────

local function slot_name()
  local s = save and save.slot and save.slot()
  return (type(s) == "string" and s ~= "") and s or "slot"
end

local function member_name(id)
  local c = ref("crew")
  if c and c.get and id then
    local ok, r = pcall(c.get, id)
    if ok and type(r) == "table" and r.name then return r.name end
  end
  return nil
end
memberName = member_name

function place(kind, body, gx, gy, gz, opts)
  ensure()
  opts = opts or {}
  local k = KINDS[kind or ""]
  if not k then return nil, "nothing of that kind can be placed" end
  local b = space.body(body or "")
  if not b then return nil, "no world there" end
  if not (gx and gy and gz) then return nil, "no ground point" end
  local seq = (save.get("dep.seq") or 0) + 1
  save.set("dep.seq", seq)
  local st = game_time()
  local r = { id = seq, k = kind, b = body, x = gx - b.x, y = gy - b.y, z = gz - b.z, by = opts.by, st = st,
              d = dateOf(st) }
  -- It faces whoever planted it (the photo is taken from that side).
  local fx, fy, fz = opts.fx, opts.fy, opts.fz
  if not fx then
    local a = find and find("Astronaut")
    if a then fx, fy, fz = a.x - gx, a.y - gy, a.z - gz end
  end
  r.fx, r.fy, r.fz = fx or 0, fy or 0, fz or 0
  if kind == "flag" then
    r.n = opts.name or string.format("%s · %s", body, r.d)
    if opts.ceremony ~= false then
      r.photo = string.format("user://flags/%s/%d.jpg", slot_name(), seq)
    end
  else
    r.n = opts.name or string.format("%s · %s", k.label, body)
  end
  recs[seq] = r
  order[#order + 1] = seq
  write(r)
  write_index()
  if kind == "flag" then fresh[seq] = { ceremony = opts.ceremony ~= false, by = opts.by } end
  spawn_node(r)
  if log then log(string.format("deployables: %s planted on %s (#%d)", r.n, body, seq)) end
  -- The missions board and the Charter hear about a flag at once.
  if kind == "flag" then
    local m = ref("missions")
    if m and m.flagPlanted then pcall(m.flagPlanted, body, seq) end
  end
  bump()
  return seq
end

function remove(id)
  ensure()
  local r = recs[id]
  if not r then return false end
  despawn(r)
  recs[id] = nil
  for i, v in ipairs(order) do if v == id then table.remove(order, i) break end end
  write_index()
  forget(id)
  if r.photo and assets and assets.remove then pcall(assets.remove, r.photo) end
  photo_cache_drop(id)
  if log then log(string.format("deployables: %s taken up (#%d)", tostring(r.n), id)) end
  bump()
  return true
end

function rename(id, name)
  ensure()
  local r = recs[id]
  if not r then return false, "no such flag" end
  local s = tostring(name or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return false, "a name can't be empty" end
  if #s > 40 then s = s:sub(1, 40) end
  r.n = s
  write(r)
  local fs = r.node and r.node.valid and r.node.getScript and r.node:getScript("flag")
  if fs and fs.renamed then pcall(fs.renamed, s) end
  bump()
  return true
end

-- The photo flag.lua took: the record keeps its path.
function setPhoto(id, path)
  ensure()
  local r = recs[id]
  if not r then return false end
  r.photo = path
  write(r)
  photo_cache_drop(id)
  bump()
  return true
end

-- ── photos as textures (cached per id) ──────────────────────────────────────

local photos = {}   -- id → { tex = "img:N" } | { waiting = true } | { failed = why }

function photo_cache_drop(id)
  local p = photos[id]
  if p and p.tex and assets and assets.release then pcall(assets.release, p.tex) end
  photos[id] = nil
end

function photoTex(id, fn)
  ensure()
  local r = recs[id]
  if not (r and r.photo) then return nil, "no photo" end
  local p = photos[id]
  if p and p.tex then if fn then fn(p.tex) end return p.tex end
  if p and (p.waiting or p.failed) then return nil, p.failed end
  if not (assets and assets.readBytes and assets.textureFromBytes) then return nil, "no pictures here" end
  local ok, bytes = pcall(assets.readBytes, r.photo)
  if not ok or type(bytes) ~= "string" then
    photos[id] = { failed = "the photo is still being taken" }
    -- try again in a few seconds (the capture answers a frame or two later)
    if after then after(3.0, function() if photos[id] and photos[id].failed then photos[id] = nil end end) end
    return nil, "no photo yet"
  end
  photos[id] = { waiting = true }
  assets.textureFromBytes(bytes, function(tex, err)
    if tex then photos[id] = { tex = tex }; if fn then fn(tex) end
    else photos[id] = { failed = tostring(err) } end
  end)
  return nil, "loading"
end

-- ── revert ──────────────────────────────────────────────────────────────────

function snapshot()
  ensure()
  local snap = { order = {}, rec = {}, seq = save.get("dep.seq") }
  for _, id in ipairs(order) do
    snap.order[#snap.order + 1] = id
    snap.rec[id] = plain(recs[id])
  end
  return snap
end

-- Returns how many were taken up and how many stood again.
function restore(snap)
  if type(snap) ~= "table" or type(snap.order) ~= "table" then return 0, 0 end
  ensure()
  local gone, back = 0, 0
  local was = {}
  for i, id in ipairs(order) do was[i] = id end
  for _, id in ipairs(was) do
    if not snap.rec[id] then
      despawn(recs[id])
      recs[id] = nil
      forget(id)
      gone = gone + 1
    end
  end
  local new_order = {}
  for _, id in ipairs(snap.order) do
    if not recs[id] then
      local r = plain(snap.rec[id])
      r.id = id
      recs[id] = r
      write(r)
      back = back + 1
    end
    new_order[#new_order + 1] = id
  end
  order = new_order
  write_index()
  if gone + back > 0 then
    if log then log(string.format("deployables: revert — %d taken up, %d standing again", gone, back)) end
    bump()
  end
  return gone, back
end

-- ── the right-click menu on a planted flag ─────────────────────────────────
-- (context_providers' "Pick up" serves every deployable; these are the
-- flag's own rows: what it is, and a rename.)

local renaming = nil
local function flag_rows(t, ctx)
  if not (t and t.wx) then return {} end
  local e = near(t.wx, t.wy, t.wz, 2.5)
  if not (e and e.k == "flag") then return {} end
  local who = member_name(e.by) or "the agency"
  local out = {
    { type = "info", id = "planted", group = "FLAG", label = "Planted", value = e.d or "—" },
    { type = "info", id = "by", group = "FLAG", label = "By", value = who },
    { type = "action", id = "rename", group = "FLAG", label = "Rename…",
      act = function()
        local ts = ref("tracking_station")
        if ts and ts.renameFlag then ts.renameFlag(e.id) end
        renaming = e.id
        if ctx.toast then ctx.toast("Rename it at the Tracking Station (FLAGS)") end
        return true
      end },
  }
  return out, e.n, "the agency's flag"
end

local registered = false
local function register_menu()
  if registered then return end
  local reg = ref("context_registry")
  if reg and reg.register then
    local ok = pcall(reg.register, "prop", flag_rows, { id = "flag.info", order = 15 })
    registered = ok
  end
end

-- ── the node ────────────────────────────────────────────────────────────────

local check_t = -100

function start(node)
  if findScripts then
    local all = findScripts("deployables")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  load()
end

-- Which records want a node: on the world the focus is on, or near it.
local function focus()
  local a = find and find("Astronaut")
  if a then return a.x, a.y, a.z end
  return nil
end

function update(node, dt)
  ensure()
  register_menu()
  tick_clock()
  local t = time or 0
  if t - check_t < 1.0 then return end
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
        if b then
          local d = math.sqrt((b.x + r.x - fx) ^ 2 + (b.y + r.y - fy) ^ 2 + (b.z + r.z - fz) ^ 2)
          want = d < range
        end
      end
    end
    if want then
      if not (r.node and r.node.valid) then spawn_node(r) end
    elseif r.node and r.node.valid then
      despawn(r)
    end
  end
end

-- For probes and tests: forget the cache and read the save again.
function reloadFromSave()
  if recs then for _, id in ipairs(order) do despawn(recs[id]) end end
  recs = nil
  load()
  bump()
end
