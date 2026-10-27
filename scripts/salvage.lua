-- SALVAGE — what the sea keeps when the crew runs out of air, and how they get
-- it back.
--
-- Running out of air under water used to delete the suit pack: the company
-- fished the crew out, and an afternoon's ore was simply gone. That is a pure
-- loss with nothing to do about it. Now the pack is DROPPED where the crew went
-- down: it sinks to the bottom as a bright salvage crate, a marker over it says
-- where it is and how far, and swimming down to it and pressing E puts the
-- contents back in the pack. A death drop — tension and a trip back, not a
-- deletion. (The rescue fee still stands: planet_walker charges it.)
--
-- THE CRATES ARE IN THE SAVE, one record each, body-relative like the relay
-- beacons (comms.lua) — "salvage.list" = the id list, "salvage.<id>" = one
-- crate { b = body, x,y,z = where it lies (body-relative), sx,sy,sz = where it
-- was dropped, kg, n = label } — and the CONTENTS are an ordinary inventory
-- container, "salvage:<id>" (inventory.lua), so nothing about materials,
-- masses, discovery or the save store is duplicated here. A crate is spawned
-- as a SalvageCrate node parented to its planet whenever that planet is in the
-- scene, and goes when it is emptied.
--
--   local sv = findScript("salvage")
--   sv.drop(body, x, y, z [, ignore [, opts]])
--                                       the suit pack's materials into a new crate
--                                       on the bottom under (x,y,z) → id, kg, entry;
--                                       opts.items = true takes the ITEMS too (a
--                                       death drop: the whole pack), opts.from =
--                                       the container (default "astro")
--   sv.list()                           { { id, body, x,y,z (world), kg, n, dist? } }
--   sv.nearest(x, y, z [, r])           the nearest crate within r m → entry, distance
--   sv.recover(id)                      as much as fits back into the pack →
--                                       kg moved, kg still in the crate
--   sv.prompting()                      the E prompt is up (E means "recover")
--
-- Runs on the SalvageLib node, which planet_walker spawns when the scene has
-- none. Pure enough for a luajit test (tests/smoke_salvage.lua).

defaults = {
  --- How close (m, crew to crate centre) the E prompt comes up.
  --@range 1 10
  reach = 3.2,
  --- How fast a fresh crate sinks to the bottom (m/s).
  --@range 0.2 10
  sink = 1.6,
  --- The furthest (m) a crate's marker is drawn from.
  --@range 50 5000
  marker_range = 3000,
  --- 0 hides the markers (the prompt still works).
  --@range 0 1
  markers = 1,
}

local LIST = "salvage.list"
local SEQ = "salvage.seq"
local function rec_key(id) return "salvage." .. tostring(id) end
function containerOf(id) return "salvage:" .. tostring(id) end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

-- ── the records ─────────────────────────────────────────────────────────────
local crates = nil     -- id → { id, body, x,y,z (bed, body-relative), sx,sy,sz, kg, n, node, born }
local order = {}

local function load_all()
  crates, order = {}, {}
  for _, id in ipairs(save.get(LIST) or {}) do
    local r = save.get(rec_key(id))
    if type(r) == "table" and r.b and r.x then
      crates[id] = { id = id, body = r.b, x = r.x, y = r.y, z = r.z,
                     sx = r.sx or r.x, sy = r.sy or r.y, sz = r.sz or r.z, kg = r.kg or 0, n = r.n }
      order[#order + 1] = id
    end
  end
end
local function all()
  if not crates then load_all() end
  return crates, order
end
local function write(c)
  save.set(rec_key(c.id), { b = c.body, x = c.x, y = c.y, z = c.z, sx = c.sx, sy = c.sy, sz = c.sz,
                            kg = c.kg, n = c.n })
end
local function write_index() save.set(LIST, order) end

-- Reload from the save (a probe, or a test standing in for a reload).
function reload()
  for _, c in pairs(crates or {}) do
    if c.node and c.node.valid and c.node.destroy then c.node:destroy() end
  end
  crates = nil
  load_all()
end

local function unit(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

-- Where a crate is in the world now (planets ride their rails).
local function world(c, bx, by, bz)
  local b = space.body(c.body)
  if not b then return nil end
  return b.x + (bx or c.x), b.y + (by or c.y), b.z + (bz or c.z)
end

-- The bottom under a point: a ray down the local vertical (terrain and the
-- sea floor both), the point itself if nothing answers within reach.
local CRATE_HALF = 0.4
local function seabed(b, x, y, z, ignore)
  local ux, uy, uz = unit(x - b.x, y - b.y, z - b.z)
  if raycast then
    local ok, hit = pcall(raycast, x, y, z, -ux, -uy, -uz, 600, ignore)
    if ok and hit and hit.x then
      return hit.x + ux * CRATE_HALF, hit.y + uy * CRATE_HALF, hit.z + uz * CRATE_HALF
    end
  end
  return x, y, z
end

-- ── drop ────────────────────────────────────────────────────────────────────
-- Move a pack's MATERIALS into a new crate on the bottom under the world point
-- (x,y,z) on `bodyName`. A drowning keeps the gear on the crew — the tools and
-- beacons were never what the water took — so items come along only when
-- asked (`opts.items`: a death drop is the whole pack). Nothing is destroyed:
-- whatever would not move stays in the pack. Returns id, kg, entry — or nil, 0
-- for an empty pack.
function drop(bodyName, x, y, z, ignore, opts)
  local inv = ref("inventory")
  local b = bodyName and space.body(bodyName)
  if not (inv and inv.items and b) then return nil, 0 end
  opts = opts or {}
  local from = opts.from or "astro"
  local items = inv.items(from)
  local kg = 0
  for _, it in ipairs(items) do kg = kg + (it.kg or 0) end
  local gear = (opts.items and inv.itemList) and inv.itemList(from) or {}
  for _, g in ipairs(gear) do kg = kg + (g.kg or 0) end
  if (#items == 0 and #gear == 0) or kg <= 0 then return nil, 0 end
  all()
  local id = (save.get(SEQ) or 0) + 1
  save.set(SEQ, id)
  local cid = containerOf(id)
  if inv.setCap then inv.setCap(cid, kg + 1.0) end
  local moved = 0
  for _, it in ipairs(items) do
    local n = inv.transfer(from, cid, it.mat, it.n)
    if n > 0 then moved = moved + (it.kg or 0) * n / math.max(it.n, 1) end
  end
  for _, g in ipairs(gear) do
    local n = inv.moveItem(from, cid, g.id, g.n, { force = true })
    if n > 0 then moved = moved + (g.kg or 0) * n / math.max(g.n, 1) end
  end
  local gx, gy, gz = seabed(b, x, y, z, ignore)
  local c = { id = id, body = bodyName, x = gx - b.x, y = gy - b.y, z = gz - b.z,
              sx = x - b.x, sy = y - b.y, sz = z - b.z, kg = moved, n = opts.label or "Suit pack",
              born = time or 0 }
  crates[id] = c
  order[#order + 1] = id
  write(c)
  write_index()
  if log then log(string.format("salvage: the suit pack (%.1f kg) sank on %s, %.1f m down to the bottom",
    moved, bodyName, math.sqrt((gx - x) ^ 2 + (gy - y) ^ 2 + (gz - z) ^ 2))) end
  return id, moved, entry(c)
end

function entry(c)
  local x, y, z = world(c)
  return { id = c.id, body = c.body, x = x, y = y, z = z, kg = c.kg, n = c.n }
end

function list()
  local cs, ord = all()
  local out = {}
  for _, id in ipairs(ord) do out[#out + 1] = entry(cs[id]) end
  return out
end

function nearest(x, y, z, r)
  local best, bd = nil, r or math.huge
  for _, e in ipairs(list()) do
    if e.x then
      local d = math.sqrt((x - e.x) ^ 2 + (y - e.y) ^ 2 + (z - e.z) ^ 2)
      if d < bd then best, bd = e, d end
    end
  end
  return best, best and bd or nil
end

local function forget(id)
  local cs = all()
  local c = cs[id]
  if not c then return end
  if c.node and c.node.valid and c.node.destroy then c.node:destroy() end
  cs[id] = nil
  for i, v in ipairs(order) do if v == id then table.remove(order, i) break end end
  write_index()
  if save.delete then save.delete(rec_key(id)) else save.set(rec_key(id), false) end
  local inv = ref("inventory")
  if inv and inv.setCap then inv.setCap(containerOf(id), 0) end
end

-- Back into the pack, as much as fits. Returns kg moved, kg left in the crate.
function recover(id)
  local cs = all()
  local c = cs[id]
  local inv = ref("inventory")
  if not (c and inv) then return 0, 0 end
  local cid = containerOf(id)
  local moved = 0
  for _, it in ipairs(inv.items(cid)) do
    local n = inv.transfer(cid, "astro", it.mat, it.n)
    if n > 0 then moved = moved + (it.kg or 0) * n / math.max(it.n, 1) end
  end
  -- the items a death drop carried: what fits (mass and litres) comes back
  for _, g in ipairs(inv.itemList and inv.itemList(cid) or {}) do
    local n = inv.moveItem(cid, "astro", g.id, g.n)
    if n > 0 then moved = moved + (g.kg or 0) * n / math.max(g.n, 1) end
  end
  local left = inv.mass(cid)
  local has_items = inv.itemList and #inv.itemList(cid) > 0
  if left <= 1e-6 or (inv.isEmpty(cid) and not has_items) then
    forget(id)
    left = 0
  else
    c.kg = left
    write(c)
  end
  if log then log(string.format("salvage: %.1f kg back in the pack, %.1f kg left in the crate", moved, left)) end
  return moved, left
end

-- ── in the world ────────────────────────────────────────────────────────────
-- A crate's node, parented to its planet (local = body-relative) like the
-- relay beacons, its +Y up the radial. A fresh one starts where it was dropped
-- and sinks; a loaded one lies on the bottom.
local function spawn_node(c)
  if c.node and c.node.valid then return end
  if c.spawning or not spawn then return end
  local planet = find and find(c.body)
  if not planet then return end
  local ux, uy, uz = unit(c.x, c.y, c.z)
  local fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
  if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
  local fresh = c.born and (c.sx ~= c.x or c.sy ~= c.y or c.sz ~= c.z)
  local lx, ly, lz = c.x, c.y, c.z
  if fresh then lx, ly, lz = c.sx, c.sy, c.sz end
  local wx, wy, wz = world(c, lx, ly, lz)
  if not wx then return end
  c.spawning = true
  spawn("SalvageCrate", vec3(wx, wy, wz), function(inst)
    c.spawning = false
    if not crates or crates[c.id] ~= c then inst:destroy() return end
    if inst.setUp then inst:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz)) end
    inst.x, inst.y, inst.z = lx, ly, lz
    inst.name = "Salvage " .. tostring(c.id)
    c.node = inst
    c.at = { lx, ly, lz }
  end, planet)
end

-- A fresh crate sinks (body-relative, so it rides the planet).
local function sink(c, dt)
  local n = c.node
  if not (n and n.valid and c.at) then return end
  local ax, ay, az = c.at[1], c.at[2], c.at[3]
  local dx, dy, dz = c.x - ax, c.y - ay, c.z - az
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < 1e-3 then return end
  local s = math.min(d, (params.sink or 1.6) * dt)
  ax, ay, az = ax + dx / d * s, ay + dy / d * s, az + dz / d * s
  c.at = { ax, ay, az }
  n.x, n.y, n.z = ax, ay, az
end

local function crew()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  return pw.node or (find and find("Astronaut")) or nil
end

local function interact_pressed()
  if input.pressed("e") then return true end
  return input.justPressed ~= nil and input.justPressed("Interact") == true
end

local near = nil         -- the crate entry the prompt is offering
local near_d = nil
local scan_t = -10

-- Is the E prompt up (E means "recover" right now)?
function prompting() return near ~= nil end

local function blocked()
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ip = ref("inventory_panel")
  if ip and ip.open then return true end
  return false
end

-- ONE LIBRARY. planet_walker spawns a SalvageLib when the scene has none; a
-- second instance (a spawn racing a scene that already had one) would draw
-- every marker again and keep a crate node of its own. Only the first
-- instance findScripts lists does anything; asked once a second.
local sole_t, sole_ok = -10, true
local function sole(node)
  if not (findScripts and node) then return true end
  local t = time or 0
  if t - sole_t < 1.0 then return sole_ok end
  sole_t = t
  local all_s = findScripts("salvage") or {}
  sole_ok = #all_s <= 1 or all_s[1].node == nil or all_s[1].node == node
  if not sole_ok and log then log("salvage: a second SalvageLib is standing down") end
  return sole_ok
end

function update(node, dt)
  if not sole(node) then near = nil return end
  local cs = all()
  -- every crate whose planet is here has a node (a second's cadence: a
  -- spawn is asynchronous and a planet streams in when it streams in)
  if (time or 0) - scan_t > 1.0 then
    scan_t = time or 0
    for _, id in ipairs(order) do spawn_node(cs[id]) end
  end
  for _, id in ipairs(order) do sink(cs[id], dt or 0) end
  -- the prompt, and E
  near, near_d = nil, nil
  local a = crew()
  if not a or blocked() then return end
  local e, d = nearest(a.x, a.y, a.z, params.reach)
  if not e then return end
  near, near_d = e, d
  if interact_pressed() then
    local moved, left = recover(e.id)
    local msg
    if moved <= 0 and left > 0 then
      msg = string.format("no room in the pack — %.0f kg still in the crate", left)
    elseif left > 0 then
      msg = string.format("%.0f kg back in the pack · %.0f kg won't fit, still in the crate", moved, left)
    else
      msg = string.format("suit pack recovered · %.0f kg", moved)
    end
    local bc = ref("big_caption")
    if bc and bc.show then bc.show(left > 0 and "SALVAGE" or "PACK RECOVERED", msg .. ".", 3.5)
    elseif caption then caption(msg) end
    local fx = ref("sfx")
    if fx and fx.play then fx.play(moved > 0 and "pickup" or "leave") end
    near = nil
  end
end

-- ── the marker and the prompt (screen) ──────────────────────────────────────
-- objectives.lua's look: a diamond on a dark tag with the name and the
-- distance; pinned to the screen edge on the side to turn to when it is off
-- screen or behind; and "E  Recover the suit pack" under the middle of the
-- screen while the crew is at it.
local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end
local function tag(x, y, text, size, r, g, b, a)
  local w = chars(text) * size * 0.5 + size
  local h = size * 1.5
  draw.rect(x - w / 2, y - h / 2, w, h, 0.05, 0.03, 0.02, 0.66 * a, size * 0.35)
  draw.text(x, y - size * 0.62, text, size, r, g, b, a, "center")
end
local function fmt_m(d)
  if d >= 1000 then return string.format("%.1f km", d / 1000) end
  return string.format("%.0f m", d)
end

-- The craft being piloted, for the markers in the seat: a pack is usually
-- fetched with a vehicle, and the marker used to vanish the moment you got in
-- one (playtest). Asked only while the crew is not on foot.
local function rider()
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting and v.node and v.node.valid ~= false then return v.node end
  end
  return nil
end

-- The crate the objectives card follows (its switcher, objectives.lua): drawn
-- brighter, named as the objective, and from any distance on its world.
local function picked_id()
  local ob = ref("objectives")
  return ob and ob.selectedPack and ob.selectedPack() or nil
end

-- What the markers do for one crate, from an observer `d` metres away: nil
-- (not drawn), "mark" (an ordinary marker) or "goal" (the card's objective).
-- Pure, for the test.
function markerKind(d, picked, range)
  if picked then return "goal" end
  if d <= (range or 3000) then return "mark" end
  return nil
end

-- ONE MARKER PER PACK (playtest: the SUIT PACK label drawn twice over itself,
-- a little offset). Crates lying within MERGE_R of each other on the same
-- world — a death drop beside a drowning's, or a double drop — are one place
-- to go and get one marker, their kilograms summed. Pure, for the test:
-- the crates to mark from (ox,oy,oz) on world `here` → { at = entry, d, kg,
-- n, label, goal }, the picked one (the objectives card's) first, then
-- nearest first. `skip` is the crate the E prompt is already about.
MERGE_R = 25.0
function markerGroups(entries, ox, oy, oz, here, pid, range, skip)
  local groups = {}
  for _, e in ipairs(entries or {}) do
    if e.x and e.body == here and e.id ~= skip then
      local d = math.sqrt((ox - e.x) ^ 2 + (oy - e.y) ^ 2 + (oz - e.z) ^ 2)
      local picked = pid ~= nil and pid == e.id
      local g = nil
      for _, h in ipairs(groups) do
        local a = h.at
        if (a.x - e.x) ^ 2 + (a.y - e.y) ^ 2 + (a.z - e.z) ^ 2 <= MERGE_R * MERGE_R then g = h break end
      end
      if g then
        g.kg, g.n = g.kg + (e.kg or 0), g.n + 1
        g.goal = g.goal or picked
        if picked or d < g.d then g.at, g.d = e, d end
      else
        groups[#groups + 1] = { at = e, d = d, kg = e.kg or 0, n = 1, goal = picked }
      end
    end
  end
  local out = {}
  for _, g in ipairs(groups) do
    local kind = markerKind(g.d, g.goal, range)
    if kind then
      local e = g.at
      g.goal = kind == "goal"
      g.label = (g.n > 1 and string.format("%d PACKS", g.n))
        or ((e.n and e.n ~= "Suit pack") and e.n:upper() or "SUIT PACK")
      out[#out + 1] = g
    end
  end
  table.sort(out, function(a, b)
    if a.goal ~= b.goal then return a.goal end
    return a.d < b.d
  end)
  return out
end

function lateUpdate(node, dt)
  if not sole(node) then return end
  if not (camera and camera.worldToScreen and camera.screenRect and draw and draw.text) then return end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return end
  local a = crew()
  if blocked() then return end
  -- In a seat (a rover, a bike, a lander) the markers measure from the craft.
  local seat = nil
  if not a then seat = rider(); if not seat then return end end
  local o = a or seat
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / uiH()
  if near then
    tag(vx + vw * 0.5, vy + vh * 0.70, string.format("E   Recover the suit pack  ·  %.0f kg", near.kg or 0),
        16 * k, 1.0, 0.86, 0.62, 1.0)
  end
  if (params.markers or 1) < 0.5 then return end
  local here = space.dominant and space.dominant(o.x, o.y, o.z)
  local groups = markerGroups(list(), o.x, o.y, o.z, here, picked_id(), params.marker_range,
    near and near.id or nil)
  local pins = { left = 0, right = 0 }       -- edge pins stacked down each side
  for _, g in ipairs(groups) do
    local goal, e, d = g.goal, g.at, g.d
    local b = space.body(e.body)
    local ux, uy, uz = 0, 1, 0
    if b then ux, uy, uz = unit(e.x - b.x, e.y - b.y, e.z - b.z) end
    local sx, sy, dep, on = camera.worldToScreen(e.x + ux * 1.5, e.y + uy * 1.5, e.z + uz * 1.5)
    local text = string.format("%s%s  ·  %.0f kg  ·  %s", goal and "◆ " or "", g.label, g.kg, fmt_m(d))
    local tr, tg, tb = 1.0, 0.80, 0.55
    if goal then tr, tg, tb = 1.0, 0.90, 0.70 end
    local front = sx and ((dep and dep > 0) or on)
    if front and sx >= vx + 40 * k and sx <= vx + vw - 40 * k and sy >= vy + 40 * k and sy <= vy + vh - 120 * k then
      tag(sx, sy - 24 * k, text, (goal and 15 or 14) * k, tr, tg, tb, 1.0)
      draw.circle(sx, sy, 5 * k, 1.0, 0.45, 0.10, 0.95)
      draw.circleOutline(sx, sy, (goal and 12 or 10) * k, 1.0, 0.45, 0.10, 0.8, 2 * k)
    else
      -- off screen or behind: on the edge, on the side to turn to. Each
      -- side's pins stack downwards (the objective first: groups come
      -- sorted), so two packs off the same side never print on each other —
      -- that read as one label drawn twice, a little offset (playtest).
      local right
      if sx and front then right = sx > vx + vw * 0.5 else right = not (sx and sx > vx + vw * 0.5) end
      local side = right and "right" or "left"
      local ex = right and (vx + vw - 170 * k) or (vx + 170 * k)
      local ey = vy + vh * 0.36 + pins[side] * 26 * k
      pins[side] = pins[side] + 1
      tag(ex, ey, right and (text .. "  ›") or ("‹  " .. text), 14 * k, tr, tg, tb, 1.0)
    end
  end
end

-- Where a crate lies as a sentence from the base, for the caption: "312 m
-- from the base" (nil without a base on that world).
function fromBase(e)
  if not (e and e.x) then return nil end
  local name = save.get("base.body")
  if name ~= e.body then return nil end
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local b = space.body(name)
  if not (b and bx and by and bz) then return nil end
  local d = math.sqrt((b.x + bx - e.x) ^ 2 + (b.y + by - e.y) ^ 2 + (b.z + bz - e.z) ^ 2)
  return fmt_m(d) .. " from the base"
end
