-- BASE CABLE — the Power Cable (deep-space proposal B9b, addendum M6;
-- docs/base-building.md §12). Q19: within 150 m of a tower every structure is
-- on its base's grid already; a cable joins two grids beyond that.
--
-- A cable is a RUN laid on the ground from one placed part to another, not a
-- part set down: the Engineer takes the Power Cable (its drum) from the BASE
-- column, clicks a placed part (the cable is made off there), walks or drives
-- to the other end paying it out, and clicks a part on another structure. It
-- is billed by the metre (plus shipping) when the second end is made off.
--
--   THE RULES   both ends on placed parts of two different structures that
--               are not already on one grid; a run at most `cable.max` m along
--               the ground (1.5 km: three 500 m drums spliced); on the home
--               world (off-world building is step 13's). Its mass (1.4 kg a
--               metre) is on the card and the hint.
--   THE DRAWING one mesh a cable (mesh.build, built once at load or lay): a
--               4-core armoured cable 32 mm across, leaving each part 0.6 m up
--               its side, sagging down to the ground in a hanging curve and
--               laid along the great circle between, on the ground the
--               terrain's own distance field gives (terrain.query, sampled
--               every 3 m when it is laid; the heights are kept in its record,
--               so a load does no terrain work). Parented to its planet like
--               a structure's parts; spawned only while the focus is on that
--               world (the same 1 Hz check as structures.lua).
--   UNDO        Ctrl+Z within a minute takes it up for a full refund (it is a
--               step in field_builder's ring). Right-click either end part →
--               Take up the cable: the price back past the minute, the fee
--               kept (base_economy.deconstructRefund). A part taken down takes
--               its cables up with it, on the same rule.
--
-- RECORDS (in the save; every point in its body's frame):
--   cable.list, cable.seq
--   cable.<id> = { id, b, a = { sid, uid }, z = { sid, uid }, len (m),
--                  h = { radius at each ground sample, m }, t, d, by,
--                  paid = { cost, ship, total, t, supplier, by } }
--
-- Probes: list(), get(id), version, pending, lastLay, ends(rec), path(rec),
-- validity(end, hit), lay(a, z), takeUp(id), nodeOf(id), quote(len).

defaults = {
  --@range 1 10 --@units m
  step = 3.0,
}

version = 0
pending = nil       -- the end made off, while the drum is in hand: { sid, uid, b, label }
lastLay = nil       -- { id, len, total, t }
preview = nil       -- { b, pts = { {x,y,z} … } body-relative, len, bad }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function say(s)
  if caption then pcall(caption, s) end
  if log then log("cable: " .. s) end
end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function cdef() local d = defs("powerCable"); return d and d.cable or { max = 1500, kgm = 1.4, perm = 3.0, lift = 0.6, r = 0.018 } end
local function money(v) local E = ref("base_economy"); return E and E.money(v) or ("$" .. tostring(v)) end
local function len3(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len3(x, y, z)
  if l < 1e-12 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

-- ── the records ─────────────────────────────────────────────────────────────
local recs, order = nil, {}
local KEEP = { "id", "b", "a", "z", "len", "h", "t", "d", "by", "paid" }
local function plain(r) local o = {} for _, k in ipairs(KEEP) do o[k] = r[k] end return o end
local function load()
  recs, order = {}, {}
  if not (save and save.get) then return end
  for _, id in ipairs(save.get("cable.list") or {}) do
    local r = save.get("cable." .. tostring(id))
    if type(r) == "table" and r.b and type(r.a) == "table" and type(r.z) == "table" then
      local rec = plain(r)
      rec.id = id
      recs[id] = rec
      order[#order + 1] = id
    end
  end
end
local function ensure() if not recs then load() end end
local function bump() version = version + 1 end
local function write(r) if save and save.set then save.set("cable." .. tostring(r.id), plain(r)) end end
local function write_index() if save and save.set then save.set("cable.list", order) end end

function list() ensure() local out = {} for _, id in ipairs(order) do out[#out + 1] = recs[id] end return out end
function get(id) ensure() return recs[id] end
function count() ensure() return #order end
function reloadFromSave() recs = nil; load(); bump() end

local spawn_mesh, drop_mesh
function add(r)
  ensure()
  if r.id == nil then
    local seq = ((save and save.get and save.get("cable.seq")) or 0) + 1
    if save and save.set then save.set("cable.seq", seq) end
    r.id = seq
  end
  recs[r.id] = r
  order[#order + 1] = r.id
  write(r)
  write_index()
  bump()
  return r.id
end
function remove(id)
  ensure()
  local r = recs[id]
  if not r then return nil end
  if drop_mesh then drop_mesh(id) end
  recs[id] = nil
  for i = #order, 1, -1 do if order[i] == id then table.remove(order, i) end end
  if save then
    if save.delete then save.delete("cable." .. tostring(id)) elseif save.set then save.set("cable." .. tostring(id), false) end
  end
  write_index()
  bump()
  return r
end
-- The cables made off at a structure (or one of its parts).
function at(sid, uid)
  ensure()
  local out = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    if (r.a.sid == sid and (uid == nil or r.a.uid == uid)) or (r.z.sid == sid and (uid == nil or r.z.uid == uid)) then out[#out + 1] = r end
  end
  return out
end

-- ── pure: the geometry ──────────────────────────────────────────────────────
-- Where a cable leaves a part: on its side toward `toward` (a body-relative
-- point), `lift` m up. ST = structures (partPose). → x, y, z, U, the side's
-- ground point gx, gy, gz (body-relative)
function endPoint(ST, rec, p, def, tx, ty, tz, lift)
  local gx, gy, gz, U, F = ST.partPose(rec, p, 0)
  local R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }
  local dx, dy, dz = tx - gx, ty - gy, tz - gz
  local du = dx * U.x + dy * U.y + dz * U.z
  dx, dy, dz = dx - U.x * du, dy - U.y * du, dz - U.z * du
  local _, _, _, l = norm(dx, dy, dz)
  local hx = (def and def.half and def.half.x) or 0.3
  local hz = (def and def.half and def.half.z) or 0.3
  local sx, sz = 0, 0
  if l > 1e-6 then
    -- the box's edge along that direction, in its own axes
    local ux, uz = (dx * R.x + dy * R.y + dz * R.z) / l, (dx * F.x + dy * F.y + dz * F.z) / l
    local s = math.min(hx / math.max(math.abs(ux), 1e-6), hz / math.max(math.abs(uz), 1e-6))
    sx, sz = ux * s, uz * s
  end
  local ox, oy, oz = gx + R.x * sx + F.x * sz, gy + R.y * sx + F.y * sz, gz + R.z * sx + F.z * sz
  local up = math.min(lift or 0.6, ((def and def.h) or 1.0) * 0.8)
  -- (a part on a raised deck: the end leaves at its own base, p.y over the plate)
  return ox + U.x * up, oy + U.y * up, oz + U.z * up, U, ox, oy, oz
end

-- Unit direction along the great circle from a to b at fraction f.
local function slerp(ax, ay, az, bx, by, bz, f)
  local c = math.max(-1, math.min(1, ax * bx + ay * by + az * bz))
  local th = math.acos(c)
  if th < 1e-9 then return ax, ay, az end
  local s = math.sin(th)
  local wa, wb = math.sin((1 - f) * th) / s, math.sin(f * th) / s
  return norm(ax * wa + bx * wb, ay * wa + by * wb, az * wa + bz * wb)
end

-- The touchdown points and the samples between: given the two ends' ground
-- points (body-relative) and the sample spacing. → n, function(i) → unit dir
-- (i = 0..n), and the ground distance between the touchdowns.
function span(ga, gz, R, step)
  local ax, ay, az, ra = norm(ga.x, ga.y, ga.z)
  local bx, by, bz, rb = norm(gz.x, gz.y, gz.z)
  local th = math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
  local d = th * (R or (ra + rb) / 2)
  local n = math.max(1, math.ceil(d / (step or 3.0)))
  return n, function(i) return slerp(ax, ay, az, bx, by, bz, i / n) end, d
end

-- The ground radius along a direction (the terrain's distance field: the
-- same sphere-trace the probes use). `r0` a guess. → r | nil
function groundR(bx, by, bz, ux, uy, uz, r0, q)
  q = q or (terrain and terrain.query)
  if not q then return nil end
  local r = r0
  for _ = 1, 60 do
    local ok, d = pcall(q, bx + ux * r, by + uy * r, bz + uz * r)
    if not ok or not d then return nil end
    if math.abs(d) < 0.03 then return r end
    r = r - d * 0.85
  end
  return r
end

-- The polyline of a cable in its body's frame: the end on part A, its hang
-- down to the ground, the run along the samples' heights, the hang up to
-- part B. `ends` = { ax,ay,az (leaving A), gax.. (A's touchdown), zx.., gzx.. },
-- `h` the sample radii (n+1). → { {x,y,z} … }, length
local HANG = 1.6        -- m from a part's side to where the cable touches the ground
function polyline(E, h, R)
  local pts = {}
  local function push(q) pts[#pts + 1] = q end
  local n = #h - 1
  local LIFT = 0.03                      -- (its centre over the ground)
  local ax, ay, az = norm(E.tax, E.tay, E.taz)
  local bx, by, bz = norm(E.tzx, E.tzy, E.tzz)
  local function d_at(i) return slerp(ax, ay, az, bx, by, bz, n > 0 and i / n or 0) end
  -- the hang: from where it leaves a part down to its touchdown, meeting the
  -- ground tangentially (radius r_ground + rise·(1 − t)²)
  local function hang(px, py, pz, gx, gy, gz, r_ground)
    local seq, K = {}, 6
    local rp = len3(px, py, pz)
    for k = 0, K do
      local t = k / K
      local ux, uy, uz = norm(px + (gx - px) * t, py + (gy - py) * t, pz + (gz - pz) * t)
      local rr = r_ground + (rp - r_ground) * (1 - t) * (1 - t)
      seq[#seq + 1] = { x = ux * rr, y = uy * rr, z = uz * rr }
    end
    return seq
  end
  local A = hang(E.ax, E.ay, E.az, E.tax, E.tay, E.taz, h[1] + LIFT)
  for k = 1, #A - 1 do push(A[k]) end      -- (its touchdown is the run's first sample)
  for i = 0, n do
    local ux, uy, uz = d_at(i)
    local r = h[i + 1] + LIFT
    push({ x = ux * r, y = uy * r, z = uz * r })
  end
  local Z = hang(E.zx, E.zy, E.zz, E.tzx, E.tzy, E.tzz, h[n + 1] + LIFT)
  for k = #Z - 1, 1, -1 do push(Z[k]) end
  local Ltot = 0
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    Ltot = Ltot + len3(b.x - a.x, b.y - a.y, b.z - a.z)
  end
  return pts, Ltot
end

-- Both ends of a cable record: where it leaves each part and touches down.
-- → E | nil, why
function ends(r)
  local ST = ref("structures")
  if not ST then return nil, "no structures" end
  local ra, rz = ST.get(r.a.sid), ST.get(r.z.sid)
  local pa, pz = ra and ST.getPart(r.a.sid, r.a.uid), rz and ST.getPart(r.z.sid, r.z.uid)
  if not (pa and pz) then return nil, "an end is gone" end
  local da, dz = defs(pa.id), defs(pz.id)
  local C = cdef()
  local gax, gay, gaz = ST.partPose(ra, pa, 0)
  local gzx, gzy, gzz = ST.partPose(rz, pz, 0)
  local ax, ay, az, Ua, oax, oay, oaz = endPoint(ST, ra, pa, da, gzx, gzy, gzz, C.lift)
  local zx, zy, zz, Uz, ozx, ozy, ozz = endPoint(ST, rz, pz, dz, gax, gay, gaz, C.lift)
  -- the touchdowns: HANG m out from each side, toward the other end
  local function out(ox, oy, oz, U, tx, ty, tz)
    local dx, dy, dz = tx - ox, ty - oy, tz - oz
    local du = dx * U.x + dy * U.y + dz * U.z
    local nx, ny, nz = norm(dx - U.x * du, dy - U.y * du, dz - U.z * du)
    return ox + nx * HANG, oy + ny * HANG, oz + nz * HANG
  end
  local tax, tay, taz = out(oax, oay, oaz, Ua, gzx, gzy, gzz)
  local tzx, tzy, tzz = out(ozx, ozy, ozz, Uz, gax, gay, gaz)
  return { ax = ax, ay = ay, az = az, zx = zx, zy = zy, zz = zz, tax = tax, tay = tay, taz = taz, tzx = tzx, tzy = tzy, tzz = tzz,
           la = da and da.label or "part", lz = dz and dz.label or "part" }
end

-- The ground heights for a cable between two ends (laying; terrain work).
-- → h = { radius … }, n, ground length | nil, why
function sampleGround(b, E, R, step)
  local ga, gz = { x = E.tax, y = E.tay, z = E.taz }, { x = E.tzx, y = E.tzy, z = E.tzz }
  local n, dir, d = span(ga, gz, R, step)
  local h = {}
  local r = len3(ga.x, ga.y, ga.z)
  for i = 0, n do
    local ux, uy, uz = dir(i)
    local g = groundR(b.x, b.y, b.z, ux, uy, uz, r + 2.0)
    if not g then
      -- (no distance field here: the straight line between the touchdowns)
      local ra, rb = len3(ga.x, ga.y, ga.z), len3(gz.x, gz.y, gz.z)
      g = ra + (rb - ra) * i / n
    end
    h[i + 1] = g
    r = g
  end
  return h, n, d
end

-- J6: a cable run is an Engineer's job (the kit is theirs already; this is
-- the rule itself, for any other way in). → why | nil
ENGINEERS_ONLY = "Engineers only: laying a Power Cable is an Engineer's job"
function layerWhyNot(id)
  local c = ref("crew")
  if not (c and c.hasRole) then return nil end
  id = id or (c.activeId and c.activeId())
  if id == nil then return ENGINEERS_ONLY end
  local ok, yes = pcall(c.hasRole, id, "engineer")
  if ok and yes == true then return nil end
  return ENGINEERS_ONLY
end
-- The layer's price a metre: an Engineer from level 2 wastes less of the
-- drum (crew.perk "cable_cost": ×0.9, ×0.8 at level 3).
local function perm_for(by)
  local C = cdef()
  local c = ref("crew")
  local k = 1
  if c and c.perk then
    by = by or (c.activeId and c.activeId())
    if by ~= nil then
      local ok, v = pcall(c.perk, by, "cable_cost")
      if ok and type(v) == "number" then k = v end
    end
  end
  return (C.perm or 3) * k, k
end

function quote(L, by)
  local E = ref("base_economy")
  local perm, k = perm_for(by)
  local cost = math.ceil((L or 0) * perm)
  local q = E and E.quote({ cost = cost, label = "Power Cable" }, "BASE", nil, nil, 0)
                 or { mode = "money", cost = cost, ship = 0, foot = 0, total = cost }
  local C = cdef()
  q.mass = (L or 0) * (C.kgm or 1.4) / 1000
  q.perk = k < 1 and k or nil
  return q
end

-- ── the placement rules ─────────────────────────────────────────────────────
-- `e1` = the end made off ({ sid, uid }) or nil; `hit` = { rec, part } under
-- the cursor (structures.partOfNode) or nil, `body`. → { bad, len, quote, E }
function validity(e1, hit, body)
  local ST, BG = ref("structures"), ref("base_grid")
  local home = save and save.get and save.get("base.body")
  local r = {}
  r.bad = layerWhyNot()
  if r.bad then return r end
  if home and body and body ~= home then r.bad = "off the home world a cable is made, not shipped: step 13" return r end
  if not (hit and hit.rec and hit.part) then
    r.bad = e1 and "aim at a part on another structure to make the far end off" or "aim at a placed part to make the cable off there"
    return r
  end
  if not e1 then
    local d = defs(hit.part.id)
    r.label = d and d.label
    return r
  end
  if hit.rec.id == e1.sid then r.bad = "the same structure: its parts already share a grid" return r end
  local ga = BG and BG.gridOfStruct and BG.gridOfStruct(e1.sid)
  local gz = BG and BG.gridOfStruct and BG.gridOfStruct(hit.rec.id)
  if ga and gz and ga == gz then r.bad = "those two are already on one grid" return r end
  local rec = { a = { sid = e1.sid, uid = e1.uid }, z = { sid = hit.rec.id, uid = hit.part.uid } }
  local E, why = ends(rec)
  if not E then r.bad = why return r end
  local b = space and space.body and space.body(hit.rec.b)
  local R = b and b.radius
  local _, _, d = span({ x = E.tax, y = E.tay, z = E.taz }, { x = E.tzx, y = E.tzy, z = E.tzz }, R, 1)
  local L = d + 2 * HANG + 1.2
  r.len, r.E = L, E
  r.quote = quote(L)
  local C = cdef()
  if L > (C.max or 1500) then
    r.bad = string.format("%.2f km: a run is at most %.1f km (set a Pad Plate between and run two)", L / 1000, (C.max or 1500) / 1000)
    return r
  end
  local co = ref("company")
  if co and co.afford and not co.afford(r.quote.total) then r.bad = "can't afford it: " .. money(r.quote.total) return r end
  return r
end

-- ── laying, taking up ───────────────────────────────────────────────────────
-- Lay a cable from end a to end z ({ sid, uid } each). → id | nil, why
function lay(a, z, opts)
  opts = opts or {}
  local gate = layerWhyNot()
  if gate then return nil, gate end
  local ST, co, EC = ref("structures"), ref("company"), ref("base_economy")
  if not (ST and co and EC) then return nil, "the building rules aren't in this scene" end
  local ra = ST.get(a.sid)
  if not ra then return nil, "that structure is gone" end
  local pz = ST.getPart(z.sid, z.uid)
  local v = validity(a, { rec = ST.get(z.sid), part = pz }, ra.b)
  if v.bad then return nil, v.bad end
  local b = space.body(ra.b)
  if not b then return nil, "not on a world" end
  local c0 = ref("crew")
  local h, n, d = sampleGround(b, v.E, b.radius, (params and params.step) or 3.0)
  local pts, L = polyline(v.E, h, b.radius)
  local q = quote(L, c0 and c0.activeId and c0.activeId() or nil)
  if not co.spend(q.total, EC.ledgerWhy("Power Cable", q) .. string.format(" · %.0f m", L)) then return nil, "can't afford it: " .. money(q.total) end
  local t = agency_now()
  local c = ref("crew")
  local by = c and c.activeId and c.activeId() or nil
  local dp = ref("deployables")
  local rec = { id = opts.id, b = ra.b, a = { sid = a.sid, uid = a.uid }, z = { sid = z.sid, uid = z.uid }, len = L, h = h,
                t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, by = by,
                paid = { cost = q.cost, ship = q.ship, foot = 0, total = q.total, t = t, supplier = q.supplier, by = by } }
  local id = add(rec)
  if spawn_mesh then spawn_mesh(rec) end
  if c and c.credit and by then pcall(c.credit, by, "built", 1, { body = ra.b }) end
  lastLay = { id = id, len = L, total = q.total, t = t, n = #pts, mass = q.mass }
  -- the ring: undo = a full refund within the minute; redo = lay it again
  local fb = ref("field_builder")
  if fb and fb.pushHistory and not opts.noHistory then
    local e = { label = "lay the Power Cable", kind = "cable", t = t, cable = id }
    e.undo = function()
      local r2 = get(e.cable)
      if not r2 then e.res, e.why = nil, "it's gone" return end
      remove(e.cable)
      local amt = math.floor((r2.paid and r2.paid.total) or 0)
      if co.refund then co.refund(amt, "returned: Power Cable (undone within a minute)") else co.earn(amt, "returned: Power Cable") end
      if c and c.credit and by then pcall(c.credit, by, "built", -1) end
      e.res = amt
    end
    e.redo = function()
      local id2, w = lay(a, z, { id = e.cable, noHistory = true })
      if not id2 then e.res, e.why = nil, w return end
      e.t = agency_now()
      e.res = lastLay and lastLay.total or 0
    end
    fb.pushHistory(e)
  end
  return id, nil, q, L
end

-- Take a cable up: the deconstruct rule (within its minute all of it, later
-- the price). → refund | nil, why
function takeUp(id, why)
  local r = get(id)
  if not r then return nil, "it's gone" end
  local EC, co = ref("base_economy"), ref("company")
  local amt = (EC and EC.deconstructRefund) and EC.deconstructRefund(r.paid, agency_now()) or 0
  remove(id)
  if co and amt > 0 then
    if co.refund then co.refund(amt, why or "taken up: Power Cable") else co.earn(amt, why or "taken up: Power Cable") end
  end
  return amt
end

-- ── the mesh (one a cable) ──────────────────────────────────────────────────
local live = {}       -- id → { node, making }
-- (a black PVC sheath: plain, no texture: at 32 mm across a texture is noise)
local CABLE_MAT = { color = { 0.035, 0.035, 0.037 }, roughness = 0.95, metallic = 0.0, shading = "physical" }

-- A tube along the polyline (points relative to the first), 6 sides. → mesh name
local function tube_mesh(pts, rad)
  if not (mesh and mesh.build) or #pts < 2 then return nil end
  local P, N, UV, I = {}, {}, {}, {}
  local o = pts[1]
  local S = 6
  local v = 0
  local px, py, pz = 0, 1, 0       -- a side vector carried along (no twist)
  for i, p in ipairs(pts) do
    local q0 = pts[math.max(1, i - 1)]
    local q1 = pts[math.min(#pts, i + 1)]
    local tx, ty, tz = norm(q1.x - q0.x, q1.y - q0.y, q1.z - q0.z)
    -- side = (previous side) made square to the tangent
    local d = px * tx + py * ty + pz * tz
    local sx, sy, sz, sl = norm(px - tx * d, py - ty * d, pz - tz * d)
    if sl < 1e-6 then sx, sy, sz = norm(ty, -tx + tz, -ty) end
    local bx, by, bz = ty * sz - tz * sy, tz * sx - tx * sz, tx * sy - ty * sx
    px, py, pz = sx, sy, sz
    if i > 1 then local a = pts[i - 1]; v = v + len3(p.x - a.x, p.y - a.y, p.z - a.z) end
    for k = 0, S do
      local ang = k / S * 2 * math.pi
      local c, s = math.cos(ang), math.sin(ang)
      local nx, ny, nz = sx * c + bx * s, sy * c + by * s, sz * c + bz * s
      P[#P + 1] = p.x - o.x + nx * rad; P[#P + 1] = p.y - o.y + ny * rad; P[#P + 1] = p.z - o.z + nz * rad
      N[#N + 1] = nx; N[#N + 1] = ny; N[#N + 1] = nz
      UV[#UV + 1] = k / S * 0.25; UV[#UV + 1] = v * 2.0
    end
  end
  local ring = S + 1
  for i = 0, #pts - 2 do
    for k = 0, S - 1 do
      local a, b = i * ring + k, i * ring + k + 1
      local c2, d2 = (i + 1) * ring + k, (i + 1) * ring + k + 1
      -- (indices are 1-based for mesh.build, as structures.lua's footing)
      I[#I + 1] = a + 1; I[#I + 1] = c2 + 1; I[#I + 1] = b + 1
      I[#I + 1] = b + 1; I[#I + 1] = c2 + 1; I[#I + 1] = d2 + 1
    end
  end
  local ok, name = pcall(mesh.build, { positions = P, indices = I, normals = N, uvs = UV, scene = true })
  if not ok then if log then log("cable: mesh failed: " .. tostring(name)) end return nil end
  return name
end

-- The drawn path of a record (body-relative points). → pts, L | nil
function path(r)
  local E = ends(r)
  local b = space and space.body and space.body(r.b)
  if not (E and b and type(r.h) == "table" and #r.h >= 2) then return nil end
  return polyline(E, r.h, b.radius)
end

drop_mesh = function(id)
  local L = live[id]
  if L and L.node and L.node.valid ~= false then L.node:destroy() end
  live[id] = nil
end

spawn_mesh = function(r)
  if live[r.id] then return end
  local planet = find and find(r.b)
  if not (planet and createNode) then return end
  local pts = path(r)
  if not pts then return end
  local m = tube_mesh(pts, cdef().r or 0.018)
  if not m then return end
  local L = { making = true }
  live[r.id] = L
  local o = pts[1]
  createNode("PowerCable", planet, function(n)
    L.making = false
    if live[r.id] ~= L or not (recs and recs[r.id] == r) then n:destroy() return end
    n.x, n.y, n.z = o.x, o.y, o.z
    n.model = m
    pcall(n.setMaterial, n, CABLE_MAT)
    L.node = n
  end)
end
function nodeOf(id) local L = live[id]; return L and L.node and L.node.valid ~= false and L.node or nil end

-- ── the preview while the drum is in hand (field_builder's lateUpdate) ──────
-- The cursor's hit → this frame's request, and a polyline to draw.
local pv = { key = nil, t = -10 }
function aimTick(hit)
  local ST = ref("structures")
  local hrec, hpart = nil, nil
  if hit and hit.node and ST and ST.partOfNode then hrec, hpart = ST.partOfNode(hit.node) end
  local body = hit and space.dominant(hit.x, hit.y, hit.z) or nil
  local v = validity(pending, hrec and { rec = hrec, part = hpart } or nil, body)
  v.hitRec, v.hitPart, v.body = hrec, hpart, body
  -- the preview line: from the end made off to the cursor (body-relative;
  -- re-sampled when the cursor moves a metre or every 0.3 s)
  if pending and hit and body == pending.b then
    local b = space.body(body)
    local key = string.format("%.0f|%.0f|%.0f", hit.x - b.x, hit.y - b.y, hit.z - b.z)
    if key ~= pv.key or now() - pv.t > 0.3 then
      pv.key, pv.t = key, now()
      local ra = ST.get(pending.sid)
      local pa = ra and ST.getPart(pending.sid, pending.uid)
      if pa then
        local hx, hy, hz = hit.x - b.x, hit.y - b.y, hit.z - b.z
        local ax, ay, az = endPoint(ST, ra, pa, defs(pa.id), hx, hy, hz, cdef().lift)
        local n, dir, d = span({ x = ax, y = ay, z = az }, { x = hx, y = hy, z = hz }, b.radius, 25)
        local pts = { { x = ax, y = ay, z = az } }
        local r = len3(ax, ay, az)
        for i = 1, n do
          local ux, uy, uz = dir(i)
          local g = groundR(b.x, b.y, b.z, ux, uy, uz, r + 2.0) or r
          pts[#pts + 1] = { x = ux * (g + 0.15), y = uy * (g + 0.15), z = uz * (g + 0.15) }
          r = g
        end
        preview = { b = body, pts = pts, len = d }
      end
    end
  elseif not pending then
    preview = nil
  end
  if preview then preview.bad = v.bad end
  return v
end

-- Draw the preview (lateUpdate: this frame's body read, drawn poses).
function drawPreview()
  if not (preview and draw and draw.line) then return end
  local b = space.body(preview.b)
  if not b then return end
  local ok = not preview.bad
  local r, g, bl = ok and 0.30 or 1.0, ok and 0.95 or 0.28, ok and 0.65 or 0.20
  local P = preview.pts
  for i = 2, #P do
    local a, c = P[i - 1], P[i]
    draw.line(b.x + a.x, b.y + a.y, b.z + a.z, b.x + c.x, b.y + c.y, b.z + c.z, r, g, bl, 0.9)
  end
end

function clearPending() pending, preview, pv.key = nil, nil, nil end
-- The first end (a click on a part with the drum in hand).
function makeOff(rec, part)
  local d = defs(part.id)
  pending = { sid = rec.id, uid = part.uid, b = rec.b, label = d and d.label or "part" }
  pv.key = nil
  return pending
end

-- ── the context menu on a part a cable is made off at ───────────────────────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local mine = at(rec.id, part.uid)
  if #mine == 0 then return {} end
  local out = {}
  for i, c in ipairs(mine) do
    local cid = c.id
    local other = (c.a.sid == rec.id and c.a.uid == part.uid) and c.z or c.a
    local od = ST.getPart(other.sid, other.uid)
    local odef = od and defs(od.id)
    local BS, BG = ref("bases"), ref("base_grid")
    local g = BG and BG.gridOfStruct and BG.gridOfStruct(other.sid)
    local bname = nil
    if g and g.bases and g.bases[1] and BS then local br = BS.get(g.bases[1]); bname = br and br.n end
    out[#out + 1] = { id = "cb_info" .. i, type = "info", label = "Power Cable", group = "Cable", value = function()
        return string.format("to the %s%s · %.0f m · %.1f t", odef and odef.label or "part", bname and (" (" .. bname .. ")") or "",
          c.len or 0, (c.len or 0) * cdef().kgm / 1000)
      end }
    out[#out + 1] = { id = "cb_up" .. i, type = "action", label = "Take up the cable", group = "Cable", danger = true,
      value = function()
        local EC = ref("base_economy")
        local amt = EC and EC.deconstructRefund and EC.deconstructRefund(c.paid, agency_now()) or 0
        return money(amt) .. " back"
      end, hint = "3 s",
      enabled = function() return layerWhyNot() == nil end,
      why = function() return layerWhyNot() and "Engineers only" or nil end,
      job = { secs = 3.0, label = "Taking up the cable",
        check = function() if not get(cid) then return false, "it's gone" end return true end,
        tick = function() end,
        done = function()
          local amt, w = takeUp(cid)
          if ctx and ctx.toast then ctx.toast(amt and ("cable taken up · " .. money(amt) .. " back") or tostring(w), amt == nil) end
          return amt ~= nil, w
        end } }
  end
  return out, "Power Cable"
end
providerFn = provider
local provider_on, provider_t = false, -10
local function register_provider()
  if provider_on or now() - provider_t < 1.0 then return end
  provider_t = now()
  local reg = ref("context_registry")
  if reg and reg.register then
    reg.register("prop", provider, { id = "base_cable", order = 5 })
    provider_on = true
  end
end

-- ── keeping in step ─────────────────────────────────────────────────────────
-- A part taken down takes its cables up with it (the deconstruct rule).
local st_ver = nil
function reconcile()
  local ST = ref("structures")
  if not ST then return 0 end
  ensure()
  local gone = {}
  for _, id in ipairs(order) do
    local r = recs[id]
    if not (ST.getPart(r.a.sid, r.a.uid) and ST.getPart(r.z.sid, r.z.uid)) then gone[#gone + 1] = id end
  end
  for _, id in ipairs(gone) do takeUp(id, "taken up with the part it was made off at: Power Cable") end
  st_ver = ST.version
  return #gone
end

local check_t = -10
function start(node)
  if findScripts then
    local all = findScripts("base_cable")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  recs, live, pending, preview, st_ver = nil, {}, nil, nil, nil
  load()
end

function update(node, dt)
  register_provider()
  ensure()
  local ST = ref("structures")
  if ST and ST.version ~= st_ver and #order > 0 then reconcile() elseif ST then st_ver = ST.version end
  -- the drum put away: the end made off is let go
  if pending then
    local fb = ref("field_builder")
    if not (fb and fb.heldPart == "powerCable" and fb.isOpen and fb.isOpen()) then clearPending() end
  end
  local t = now()
  if t - check_t < 1.0 or #order == 0 then return end
  check_t = t
  local a = find and find("Astronaut")
  local dom = a and space.dominant(a.x, a.y, a.z) or nil
  for _, id in ipairs(order) do
    local r = recs[id]
    if dom == r.b then spawn_mesh(r) elseif live[id] then drop_mesh(id) end
  end
end
