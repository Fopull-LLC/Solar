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
--               its side and SETTLED along the great circle between (see "the
--               settle"): a catenary of its pull and weight where it hangs
--               free, lying on the ground (the terrain's distance field,
--               sampled every 0.5 m when it is laid and kept in its record, so
--               a load does no terrain work), on the parts it crosses and on
--               the rocks. Solved again only when the ground under it is dug
--               or a part is set down on its line. Parented to its planet like
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
--   cable.<id> = { id, b, a = { sid, uid }, z = { sid, uid }, len (m), ty, burnt,
--                  h = { radius at each ground sample, m (every `step` between
--                  the ends; v = 2, before it every 3 m between the old
--                  touchdowns) }, v, rk = { { x, y, z, r } rocks }, t, d, by,
--                  paid = { cost, ship, total, t, supplier, by } }
--
-- S5 (power networks II; docs/base-building.md §16): a cable has a TYPE, the
-- drum it was laid from (`ty`: lv16 / lv35 / lv95 at 400 V, hv35 at 11 kV;
-- base_power.CABLES has their copper, rating, mass and price), and carries
-- real losses and a rating in base_grid's network. An 11 kV cable runs only
-- between two Transformers; a transformer takes nothing else. A cable made
-- off at a Power Pole leaves the pole's crossarm and is STRUNG (pulled tight:
-- its sag about 2.5 % of the span) instead of laid slack on the ground. A
-- cable driven far past its rating with no breaker at either end BURNS
-- THROUGH (`burnt`, base_grid): it carries nothing until it is spliced.
--
-- Probes: list(), get(id), version, pending, lastLay, ends(rec), path(rec),
-- pathOf(id), validity(end, hit, body, ty), lay(a, z), takeUp(id), nodeOf(id),
-- quote(len, by, ty), setBurnt(id), splice(id).

defaults = {
  --@range 0.25 3 --@units m
  step = 0.5,
}
-- The ground's sample spacing for a run of `L` m: `step`, at most ~3,000
-- samples on the longest.
function groundStep(L)
  return math.max((params and params.step) or 0.5, (L or 0) / 3000)
end

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
-- A cable type's figures: base_power.CABLES (the copper, the rating) over
-- the drum's own card (max, kgm, perm, lift, r). `ty` nil = the 16 mm² drum.
local DRUM = { lv16 = "powerCable", lv35 = "powerCable35", lv95 = "powerCable95", hv35 = "hvCable", lv2 = "flexLead" }
local function cdef(ty)
  -- (scn_dust) a type no drum lays (a 2.5 mm² flex run): base_power's own card
  if ty and not DRUM[ty] then
    local BP = ref("base_power")
    local c = BP and BP.CABLES and BP.CABLES[ty]
    if c then return { max = c.max or 200, kgm = c.kgm or 0.35, perm = c.perm or 1, lift = 0.4, r = c.r or 0.009, label = c.label, type = ty } end
  end
  local d = defs(DRUM[ty or "lv16"] or "powerCable")
  local C = d and d.cable or { max = 1500, kgm = 1.4, perm = 3.0, lift = 0.6, r = 0.018 }
  return C
end
function typeOf(r) return (r and r.ty) or "lv16" end
-- (a held drum's cable type)
function heldType()
  local fb = ref("field_builder")
  local d = fb and fb.heldPart and defs(fb.heldPart)
  return d and d.cable and (d.cable.type or "lv16") or nil
end
local function money(v) local E = ref("base_economy"); return E and E.money(v) or ("$" .. tostring(v)) end
local function len3(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len3(x, y, z)
  if l < 1e-12 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

-- ── the records ─────────────────────────────────────────────────────────────
local recs, order = nil, {}
local KEEP = { "id", "b", "a", "z", "len", "h", "v", "rk", "t", "d", "by", "paid", "ty", "burnt" }
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
  -- (S5) a part that names where cables leave it: a pole's crossarm, a
  -- transformer's bushings: on its own axis at that height
  if def and def.cableAt then
    up = def.cableAt
    if def.pole then ox, oy, oz = gx, gy, gz end
  end
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

HANG = 1.6        -- m from a part's side to where the cable touches the ground (the rules' estimate)

-- Both ends of a cable record: where it leaves each part and touches down.
-- → E | nil, why
function ends(r)
  local ST = ref("structures")
  if not ST then return nil, "no structures" end
  local ra, rz = ST.get(r.a.sid), ST.get(r.z.sid)
  local pa, pz = ra and ST.getPart(r.a.sid, r.a.uid), rz and ST.getPart(r.z.sid, r.z.uid)
  if not (pa and pz) then return nil, "an end is gone" end
  local da, dz = defs(pa.id), defs(pz.id)
  local C = cdef(r.ty)
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
           la = da and da.label or "part", lz = dz and dz.label or "part",
           strung = (da and da.pole) or (dz and dz.pole) or false }
end

-- ── the settle: how a heavy cable lies (playtest 2026-11-06) ───────────────
-- A laid cable is a catenary wherever it hangs free and lies on whatever holds
-- it up where it touches: the ground (the terrain's distance field, sampled
-- along its whole length), the parts it crosses (their boxes) and the rocks.
-- With a horizontal pull H on a cable of λ kg/m under gravity g, every free
-- span is y'' = √(1 + y'²) / a with a = H / (λ g); where the curve would dip
-- into a support, the support carries it. That is an obstacle problem, solved
-- ONCE when the cable is laid (or its ground or the parts under it change) by
-- relaxation on fixed stations along the great circle between its ends:
-- projected Gauss-Seidel with over-relaxation, coarse to fine (a long free span
-- settles on the coarse levels, the touchdowns on the fine ones). Pure Lua on
-- the CPU, a few milliseconds once, and nothing at all per frame afterwards:
-- the result is one static mesh. (A GPU solver only pays for a simulation run
-- every frame, which a cable lying still never needs.)
--
-- S = { support height at each station (m, the cable's centre may not go
-- under it) }, ds the station spacing (m), yA / yZ the ends (held), a the
-- catenary parameter (m). → y = { height at each station }, sweeps
local SETTLE_TOL = 2e-5
function settle(S, ds, yA, yZ, a, opts)
  local n = #S
  local y = {}
  if n < 2 then return { yA }, 0 end
  a = math.max(a or 3.0, 0.05)
  local it_max = (opts and opts.iters) or 600
  -- the levels: strides 2^k down to 1, the coarsest with ~16 stations
  local stride = 1
  while (n - 1) / (stride * 2) >= 16 do stride = stride * 2 end
  -- the starting guess: a straight line between the ends, lifted onto the supports
  for i = 1, n do
    local f = (i - 1) / (n - 1)
    y[i] = math.max(yA + (yZ - yA) * f, S[i])
  end
  y[1], y[n] = yA, yZ
  local sweeps = 0
  while true do
    -- the stations on this level (and the last one, held)
    local idx = {}
    for i = 1, n, stride do idx[#idx + 1] = i end
    if idx[#idx] ~= n then idx[#idx + 1] = n end
    local m = #idx
    -- a coarse station stands for its window: it may not go under any support in it
    local Sc = {}
    local hw = math.floor(stride / 2)
    for j = 1, m do
      local i0, i1 = math.max(1, idx[j] - hw), math.min(n, idx[j] + hw)
      local top = S[idx[j]]
      for i = i0, i1 do if S[i] > top then top = S[i] end end
      Sc[j] = top
    end
    local w = 1.7
    for _ = 1, it_max do
      local most = 0
      for j = 2, m - 1 do
        local i, il, ir = idx[j], idx[j - 1], idx[j + 1]
        local hl, hr = (i - il) * ds, (ir - i) * ds
        local yl, yr = y[il], y[ir]
        local slope = (yr - yl) / (hl + hr)
        -- the catenary's equilibrium between its neighbours: y'' = √(1+y'²)/a
        local free = (yl * hr + yr * hl) / (hl + hr) - (hl * hr / (2 * a)) * math.sqrt(1 + slope * slope)
        local v = y[i] + w * (free - y[i])
        if v < Sc[j] then v = Sc[j] end
        local dv = v - y[i]
        if dv < 0 then dv = -dv end
        if dv > most then most = dv end
        y[i] = v
      end
      sweeps = sweeps + 1
      if most < SETTLE_TOL then break end
    end
    if stride == 1 then break end
    -- down a level: the new stations between, on the line between their neighbours
    local half = stride / 2
    for j = 1, m - 1 do
      local i0, i1 = idx[j], idx[j + 1]
      local i = i0 + half
      while i < i1 do
        local f = (i - i0) / (i1 - i0)
        y[i] = math.max(y[i0] + (y[i1] - y[i0]) * f, S[i])
        i = i + half
      end
    end
    stride = half
  end
  return y, sweeps
end

-- A polyline in (s, y) thinned where it is straight to within `tol` m
-- (Douglas-Peucker): a cable lying on flat ground is a few long segments, the
-- hangs and the bumps keep their stations; never a segment over `most` m
-- (the ground under a long straight run still bends with the world).
-- → { the indices kept, in order }
function thin(y, ds, tol, most)
  local n = #y
  most = most or 8
  local keep = { [1] = true, [n] = true }
  local stack = { { 1, n } }
  while #stack > 0 do
    local seg = table.remove(stack)
    local i0, i1 = seg[1], seg[2]
    if i1 - i0 > 1 then
      local x0, y0 = (i0 - 1) * ds, y[i0]
      local dx, dy = (i1 - i0) * ds, y[i1] - y0
      local L = math.sqrt(dx * dx + dy * dy)
      local worst, wi = -1, nil
      for i = i0 + 1, i1 - 1 do
        local px, py = (i - 1) * ds - x0, y[i] - y0
        local d = math.abs(px * dy - py * dx) / math.max(L, 1e-9)
        if d > worst then worst, wi = d, i end
      end
      if worst > tol or dx > most then
        if worst <= tol then wi = math.floor((i0 + i1) / 2) end
        keep[wi] = true
        stack[#stack + 1] = { i0, wi }
        stack[#stack + 1] = { wi, i1 }
      end
    end
  end
  local out = {}
  for i = 1, n do if keep[i] then out[#out + 1] = i end end
  return out
end

-- The settle's knobs: the horizontal pull a cable is laid with (N: a hand's
-- pull on a 32 mm armoured cable, so it lies slack and meets the ground about
-- 1.5 m out from a part's side, about where a hand lays it), its weight a metre and the world's gravity.
-- → a = H / (λ g), m
PULL = 30.0
-- (S5) a cable strung from a Power Pole is pulled tight: its catenary's a is
-- STRUNG times the span (a sag of span / (8·STRUNG): 2.5 %), never less than
-- the hand's lay
STRUNG = 5.0
function tensionA(b, C, E)
  local a = catenaryA(b, C)
  if E and E.strung then
    local d = len3(E.ax - E.zx, E.ay - E.zy, E.az - E.zz)
    a = math.max(a, STRUNG * d)
  end
  return a
end
function catenaryA(b, C)
  local g = 9.81
  if b and b.mu and b.radius and b.radius > 0 then g = b.mu / (b.radius * b.radius) end
  if not (g > 0.05) then g = 0.05 end
  return PULL / ((((C and C.kgm) or 1.4)) * g)
end

-- The line a cable's stations run along: from over where it leaves part A to
-- over where it leaves part Z (unit directions from the body's centre); `old`:
-- a record from before the settle, whose samples run between the touchdowns.
local function line_dirs(E, old)
  if old then
    local ax, ay, az = norm(E.tax, E.tay, E.taz)
    local bx, by, bz = norm(E.tzx, E.tzy, E.tzz)
    return ax, ay, az, bx, by, bz
  end
  local ax, ay, az = norm(E.ax, E.ay, E.az)
  local bx, by, bz = norm(E.zx, E.zy, E.zz)
  return ax, ay, az, bx, by, bz
end

-- The ground radii under a cable between two ends (laying; terrain work):
-- the distance field every `step` m along the line between its ends.
-- → h = { radius … }, n, ground length
function sampleGround(b, E, R, step)
  local ax, ay, az, bx, by, bz = line_dirs(E)
  local n, dir, d = span({ x = ax, y = ay, z = az }, { x = bx, y = by, z = bz }, R, step)
  local h = {}
  local ra, rb = len3(E.tax, E.tay, E.taz), len3(E.tzx, E.tzy, E.tzz)
  local r = ra
  for i = 0, n do
    local ux, uy, uz = dir(i)
    local g = groundR(b.x, b.y, b.z, ux, uy, uz, r + 2.0)
    -- (no distance field here: the straight line between the ends' ground)
    if not g then g = ra + (rb - ra) * i / n end
    h[i + 1] = g
    r = g
  end
  return h, n, d
end

-- What else holds a cable up where it crosses: the placed parts' boxes (not
-- the two it is made off at), from the structures' records (pure: no scene
-- read), those within reach of the line between its ends.
-- → { { gx.. (ground point), ux.. (up), rx.. fx.. (its axes), hx, hz, top, key } }
function obstaclesFor(r, E)
  local ST = ref("structures")
  local boxes = {}
  if not (ST and ST.list and ST.partPose) then return boxes end
  local ax, ay, az, bx, by, bz = line_dirs(E)
  local Rr = len3(E.ax, E.ay, E.az)
  local th = math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
  local nx, ny, nz, nl = norm(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
  for _, rec in ipairs(ST.list()) do
    if rec.b == r.b and type(rec.bp) == "table" then
      for _, p in ipairs(rec.bp) do
        local mine = (rec.id == r.a.sid and p.uid == r.a.uid) or (rec.id == r.z.sid and p.uid == r.z.uid)
        local d = (not mine) and defs(p.id) or nil
        if d and p.id ~= "powerCable" then
          local gx, gy, gz, U, F = ST.partPose(rec, p, 0)
          local hx = (d.half and d.half.x) or d.rx or 0.5
          local hz = (d.half and d.half.z) or d.rz or 0.5
          local reach = math.sqrt(hx * hx + hz * hz) + 0.5
          local off = nl > 1e-9 and math.abs(gx * nx + gy * ny + gz * nz) or 0
          local ux, uy, uz = norm(gx, gy, gz)
          local ta = math.acos(math.max(-1, math.min(1, ux * ax + uy * ay + uz * az)))
          local tb = math.acos(math.max(-1, math.min(1, ux * bx + uy * by + uz * bz)))
          if off <= reach and (ta + tb - th) * Rr <= 2 * reach then
            local Rx, Ry, Rz = U.y * F.z - U.z * F.y, U.z * F.x - U.x * F.z, U.x * F.y - U.y * F.x
            boxes[#boxes + 1] = { gx = gx, gy = gy, gz = gz, ux = U.x, uy = U.y, uz = U.z, rx = Rx, ry = Ry, rz = Rz,
                                  fx = F.x, fy = F.y, fz = F.z, hx = hx, hz = hz, top = d.h or 1.0,
                                  key = tostring(rec.id) .. ":" .. tostring(p.uid) }
          end
        end
      end
    end
  end
  return boxes
end
-- A signature of the boxes a cable lies over (what changed under it).
function boxesKey(boxes)
  local ks = {}
  for _, b in ipairs(boxes or {}) do ks[#ks + 1] = string.format("%s@%.2f,%.2f,%.2f", b.key, b.gx, b.gy, b.gz) end
  table.sort(ks)
  return table.concat(ks, ";")
end

-- The rocks along a cable (laying only: a rock is known where it has settled,
-- round the crew). World points read once, kept body-relative.
-- → { { x, y, z, r } }
function rocksAlong(b, E, R)
  local mf = ref("mineral_field")
  local out = {}
  if not (mf and mf.rocksNear and b) then return out end
  local ax, ay, az, bx, by, bz = line_dirs(E)
  local n, dir = span({ x = ax, y = ay, z = az }, { x = bx, y = by, z = bz }, R, 16)
  local seen = {}
  local m = math.min(n, 100)
  for k = 0, m do
    local ux, uy, uz = dir(math.floor(k * n / math.max(1, m) + 0.5))
    local ok, list = pcall(mf.rocksNear, b.x + ux * R, b.y + uy * R, b.z + uz * R, 12)
    if ok and type(list) == "table" then
      for _, q in ipairs(list) do
        if q.key and not seen[q.key] and #out < 96 and q.x then
          seen[q.key] = true
          out[#out + 1] = { x = q.x - b.x, y = q.y - b.y, z = q.z - b.z, r = q.r or 0.5 }
        end
      end
    end
  end
  return out
end

-- The support under one station (unit direction u, ground radius g): the
-- ground, or the top of a box or a rock it crosses.
local function support_at(ux, uy, uz, g, boxes, rocks, rad)
  local best = g
  local px, py, pz = ux * g, uy * g, uz * g
  if boxes then
    for _, bx in ipairs(boxes) do
      local dx, dy, dz = px - bx.gx, py - bx.gy, pz - bx.gz
      local lx = dx * bx.rx + dy * bx.ry + dz * bx.rz
      local lz = dx * bx.fx + dy * bx.fy + dz * bx.fz
      if math.abs(lx) <= bx.hx + rad and math.abs(lz) <= bx.hz + rad then
        local t = bx.gx * ux + bx.gy * uy + bx.gz * uz + bx.top * (bx.ux * ux + bx.uy * uy + bx.uz * uz)
        if t > best then best = t end
      end
    end
  end
  if rocks then
    for _, k in ipairs(rocks) do
      local dot = k.x * ux + k.y * uy + k.z * uz
      local hx, hy, hz = k.x - ux * dot, k.y - uy * dot, k.z - uz * dot
      local dh = len3(hx, hy, hz)
      local rr = k.r + rad
      if dh < rr and dot > 0 then
        -- a dome over where it settled (a boulder sits partly in the ground)
        local t = dot + math.sqrt(rr * rr - dh * dh) * 0.85
        if t > best then best = t end
      end
    end
  end
  return best
end

-- The polyline of a cable in its body's frame, settled: from where it leaves
-- part A to where it leaves part Z, hanging free between supports and lying on
-- them where it touches. `h`: the ground's radii every step along the line
-- between the ends (sampleGround). opts = { old (h runs between the
-- touchdowns: a record from before the settle), boxes, rocks, a }.
-- → { {x,y,z} … } (thinned), length (m), { S, y, ds, n }
local LIFT = 0.006      -- m between the ground and the sheath
function polyline(E, h, R, opts)
  opts = opts or {}
  local C = cdef(opts.ty)
  local rad = C.r or 0.016
  local ax, ay, az, bx, by, bz = line_dirs(E)
  local hax, hay, haz, hbx, hby, hbz = line_dirs(E, opts.old)
  local th = math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
  local Rr = (len3(E.tax, E.tay, E.taz) + len3(E.tzx, E.tzy, E.tzz)) / 2
  local D = th * Rr
  -- the stations: 0.25 m apart on a short cable, ~2,000 on a long one
  local n = math.max(2, math.ceil(D / math.max(0.25, D / 2000)))
  local ds = D / n
  local thh = math.acos(math.max(-1, math.min(1, hax * hbx + hay * hby + haz * hbz)))
  local nh = #h - 1
  local S, U = {}, {}
  for i = 0, n do
    local ux, uy, uz = slerp(ax, ay, az, bx, by, bz, i / n)
    U[i + 1] = { ux, uy, uz }
    -- the ground here: the sample line's radius at this station's place along it
    local g
    if nh < 1 then
      g = h[1] or Rr
    else
      local ta = math.acos(math.max(-1, math.min(1, ux * hax + uy * hay + uz * haz)))
      local tb = math.acos(math.max(-1, math.min(1, ux * hbx + uy * hby + uz * hbz)))
      local f = (thh > 1e-12) and (ta / thh) or 0
      if tb > thh then f = 0 end                     -- (before the line's start: its first sample)
      local x = math.max(0, math.min(nh, f * nh))
      local i0 = math.min(nh - 1, math.floor(x))
      g = h[i0 + 1] + (h[i0 + 2] - h[i0 + 1]) * (x - i0)
    end
    S[i + 1] = support_at(ux, uy, uz, g, opts.boxes, opts.rocks, rad) + rad + LIFT
  end
  local yA, yZ = len3(E.ax, E.ay, E.az), len3(E.zx, E.zy, E.zz)
  local y = settle(S, ds, yA, yZ, opts.a or 2.2)
  local keep = thin(y, ds, 0.004)
  local pts = {}
  for _, i in ipairs(keep) do
    local u = U[i]
    pts[#pts + 1] = { x = u[1] * y[i], y = u[2] * y[i], z = u[3] * y[i] }
  end
  local Ltot = 0
  for i = 2, n + 1 do
    local dy = y[i] - y[i - 1]
    Ltot = Ltot + math.sqrt(ds * ds + dy * dy)
  end
  return pts, Ltot, { S = S, y = y, ds = ds, n = n }
end

-- J6: a cable run is an Engineer's job (the kit is theirs already; this is
-- the rule itself, for any other way in). → why | nil
ENGINEERS_ONLY = "Engineers only: laying a Power Cable is an Engineer's job"
local FREE = false       -- (scn_dust) layFree: a scenario's staged run, no hand and no bill
function layerWhyNot(id)
  if FREE then return nil end
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
local function perm_for(by, ty)
  local C = cdef(ty)
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

-- (playtest 11-12b) OFF THE HOME WORLD A CABLE IS CUT FROM YOUR OWN STOCK:
-- its copper and its armour by the metre (recipes.recipeFor's cable recipe:
-- half Wiring, half Steel), out of the stores in the Build Kit's reach. A
-- ruin on another world could not be wired at all before: nothing ships
-- there. → { { mat, kg, label } … } for a run of L metres
function stockNeed(L, ty)
  local Rc, M = ref("recipes"), ref("materials")
  local d = defs(DRUM[ty or "lv16"] or "powerCable")
  local r = Rc and Rc.recipeFor and d and Rc.recipeFor(d, "BASE", DRUM[ty or "lv16"] or "powerCable") or nil
  local out = {}
  for _, m in ipairs(r and r.mats or { { mat = "wiring", kg = 0.7 }, { mat = "steel", kg = 0.7 } }) do
    out[#out + 1] = { mat = m.mat, kg = math.max(1, math.ceil(m.kg * (L or 0) - 1e-9)), label = M and M.label and M.label(m.mat) or m.mat }
  end
  return out
end
local function away(body)
  local home = save and save.get and save.get("base.body")
  local co = ref("company")
  if co and co.isSandbox and co.isSandbox() == true then return false end
  return home ~= nil and body ~= nil and body ~= home
end
-- the stock in reach (field_builder's scan): → have(mat), order = { cid … }
local function stock_reach()
  local fb = ref("field_builder")
  local st = fb and fb.reachScan and fb.reachScan(true) or { order = {}, mats = {} }
  return function(mat) return (st.mats and st.mats[mat]) or 0 end, st.order or {}
end
local function stock_take(need)
  local inv = ref("inventory")
  local have, order = stock_reach()
  if not inv then return false end
  for _, e in ipairs(need) do if have(e.mat) + 1e-9 < e.kg then return false end end
  for _, e in ipairs(need) do
    local left = e.kg
    for _, cid in ipairs(order) do
      if left <= 0 then break end
      local h = inv.count(cid, e.mat) or 0
      if h > 0 then left = left - (inv.remove(cid, e.mat, math.min(h, left)) or 0) end
    end
  end
  return true
end
local function stock_give(need)
  local inv = ref("inventory")
  local _, order = stock_reach()
  if not inv then return end
  for _, e in ipairs(need or {}) do
    local left = e.kg
    for _, cid in ipairs(order) do
      if left <= 0 then break end
      left = left - (inv.add(cid, e.mat, left) or 0)
    end
  end
end
function stockLine(need)
  local t = {}
  for _, e in ipairs(need or {}) do t[#t + 1] = string.format("%d kg of %s", e.kg, e.label or e.mat) end
  return table.concat(t, " and ")
end
function quote(L, by, ty, body)
  local E = ref("base_economy")
  -- (off the home world: no bill, its metres out of the stock in reach)
  if away(body) then
    local C0 = cdef(ty)
    return { mode = "stock", cost = 0, ship = 0, foot = 0, total = 0, mats = stockNeed(L, ty), mass = (L or 0) * (C0.kgm or 1.4) / 1000 }
  end
  local perm, k = perm_for(by, ty)
  local cost = math.ceil((L or 0) * perm)
  local q = E and E.quote({ cost = cost, label = "Power Cable" }, "BASE", nil, nil, 0)
                 or { mode = "money", cost = cost, ship = 0, foot = 0, total = cost }
  local C = cdef(ty)
  -- (W2) a flex lead is a coil carried out by hand: nothing to ship
  if C.flex and q.mode == "money" and (q.ship or 0) > 0 then q.total = q.total - q.ship; q.ship = 0 end
  q.mass = (L or 0) * (C.kgm or 1.4) / 1000
  q.perk = k < 1 and k or nil
  return q
end

-- ── the placement rules ─────────────────────────────────────────────────────
-- `e1` = the end made off ({ sid, uid }) or nil; `hit` = { rec, part } under
-- the cursor (structures.partOfNode) or nil, `body`. → { bad, len, quote, E }
function validity(e1, hit, body, ty)
  ty = ty or (e1 and e1.ty) or heldType() or "lv16"
  local ST, BG = ref("structures"), ref("base_grid")
  local home = save and save.get and save.get("base.body")
  local r = {}
  r.bad = layerWhyNot()
  if r.bad then return r end
  if not (hit and hit.rec and hit.part) then
    r.bad = e1 and "aim at a part on another structure to make the far end off" or "aim at a placed part to make the cable off there"
    return r
  end
  local hv = (ty == "hv35")
  -- (an 11 kV line runs from a Transformer to a Transformer, over Power
  -- Poles between; a transformer's high side takes nothing else; a pole
  -- carries one voltage)
  local function endWhy(d, sid, uid)
    local xf = d and d.power and d.power.kind == "xfmr"
    if hv and not (xf or (d and d.pole)) then
      return "an 11 kV cable runs between Transformers, over Power Poles (this end is a " .. tostring(d and d.label or "part") .. ")"
    end
    if xf and not hv then return "a Transformer's high side takes the HV Cable 11 kV, not a 400 V cable" end
    if d and d.pole and sid then
      for _, c in ipairs(at(sid, uid)) do
        if (typeOf(c) == "hv35") ~= hv then return hv and "this pole carries 400 V lines: 11 kV needs its own poles" or "this pole carries an 11 kV line: a 400 V cable needs its own poles" end
      end
    end
    return nil
  end
  if not e1 then
    local d = defs(hit.part.id)
    r.label = d and d.label
    r.bad = endWhy(d, hit.rec.id, hit.part.uid)
    return r
  end
  -- (W2) a cable joins two TERMINALS: a piece of equipment's own, or a
  -- structure's circuit (base_grid.nodeKeyOf). Two pieces of one building's
  -- circuit are joined already; a machine, a source or a battery beside them
  -- is not, and may be cabled to it.
  local na = BG and BG.nodeKeyOf and BG.nodeKeyOf(e1.sid, e1.uid) or ("s" .. tostring(e1.sid))
  local nz = BG and BG.nodeKeyOf and BG.nodeKeyOf(hit.rec.id, hit.part.uid) or ("s" .. tostring(hit.rec.id))
  if na == nz then
    r.bad = (hit.rec.id == e1.sid and hit.part.uid == e1.uid) and "the same part: aim at what this cable should feed"
      or "the same circuit: this structure's pieces already share its wiring (cable a source, a battery or a machine to it)"
    return r
  end
  local dz = defs(hit.part.id)
  r.bad = endWhy(dz, hit.rec.id, hit.part.uid)
  if r.bad then return r end
  -- (S5) poles, junctions, breakers and transformers may close a loop or
  -- double a line; anything else joins two grids that aren't one yet
  local pa = ST and ST.getPart(e1.sid, e1.uid)
  local da = pa and defs(pa.id)
  local gear = (da and da.netgear) or (dz and dz.netgear)
  local ga = BG and BG.gridOfStruct and BG.gridOfStruct(e1.sid, e1.uid)
  local gz = BG and BG.gridOfStruct and BG.gridOfStruct(hit.rec.id, hit.part.uid)
  if ga and gz and ga == gz and not gear then r.bad = "those two are already on one grid (a breaker, pole or junction may close a loop)" return r end
  local rec = { a = { sid = e1.sid, uid = e1.uid }, z = { sid = hit.rec.id, uid = hit.part.uid }, ty = ty }
  local E, why = ends(rec)
  if not E then r.bad = why return r end
  local b = space and space.body and space.body(hit.rec.b)
  local R = b and b.radius
  local _, _, d = span({ x = E.tax, y = E.tay, z = E.taz }, { x = E.tzx, y = E.tzy, z = E.tzz }, R, 1)
  local L = d + 2 * HANG + 1.2
  r.len, r.E, r.ty = L, E, ty
  r.quote = quote(L, nil, ty, hit.rec.b)
  if r.quote.mode == "stock" and not FREE then
    local have = stock_reach()
    for _, e in ipairs(r.quote.mats) do
      if have(e.mat) + 1e-9 < e.kg then
        r.bad = string.format("off the home world a cable is cut from your own stock: this run wants %s within the kit's reach (%d kg of %s there)",
          stockLine(r.quote.mats), math.floor(have(e.mat)), e.label or e.mat)
        return r
      end
    end
  end
  local C = cdef(ty)
  if L > (C.max or 1500) then
    r.bad = string.format("%.2f km: a run is at most %.1f km (a Power Pole or a Junction Box between, and run two)", L / 1000, (C.max or 1500) / 1000)
    return r
  end
  local co = ref("company")
  if not FREE and co and co.afford and not co.afford(r.quote.total) then r.bad = "can't afford it: " .. money(r.quote.total) return r end
  -- (W2) what the run would join, in words: the hint's last clause
  if BG and BG.wiring then
    local wa, wz = BG.wiring(e1.sid, e1.uid), BG.wiring(hit.rec.id, hit.part.uid)
    local la, lz = (da and da.label) or "part", (dz and dz.label) or "part"
    if not (da and BG.isEquipment(da)) and not (pa and ST.get(e1.sid).aw) then la = la .. "'s building" end
    if not (dz and BG.isEquipment(dz)) and not hit.rec.aw then lz = lz .. "'s building" end
    local live = (wa.live and 1 or 0) + (wz.live and 1 or 0)
    r.joins = string.format("joins the %s to the %s%s", la, lz,
      live == 0 and " (neither reaches a source yet)" or (live == 1 and " (it goes live)" or ""))
  end
  return r
end

-- ── laying, taking up ───────────────────────────────────────────────────────
-- Lay a cable from end a to end z ({ sid, uid } each). → id | nil, why
function lay(a, z, opts)
  opts = opts or {}
  local ty = opts.ty or a.ty or heldType() or "lv16"
  local gate = layerWhyNot()
  if gate then return nil, gate end
  local ST, co, EC = ref("structures"), ref("company"), ref("base_economy")
  if not (ST and co and EC) then return nil, "the building rules aren't in this scene" end
  local ra = ST.get(a.sid)
  if not ra then return nil, "that structure is gone" end
  local pz = ST.getPart(z.sid, z.uid)
  local v = validity(a, { rec = ST.get(z.sid), part = pz }, ra.b, ty)
  if v.bad then return nil, v.bad end
  local b = space.body(ra.b)
  if not b then return nil, "not on a world" end
  local c0 = ref("crew")
  local h = sampleGround(b, v.E, b.radius, groundStep(v.len))
  local rk = rocksAlong(b, v.E, b.radius)
  local rec0 = { b = ra.b, a = a, z = z, ty = ty }
  local pts, L = polyline(v.E, h, b.radius, { boxes = obstaclesFor(rec0, v.E), rocks = rk, a = tensionA(b, cdef(ty), v.E), ty = ty })
  local q = quote(L, c0 and c0.activeId and c0.activeId() or nil, ty, ra.b)
  if q.mode == "stock" then
    q.mats = stockNeed(L, ty)
    if not FREE and not stock_take(q.mats) then return nil, "the stock in reach is short: " .. stockLine(q.mats) end
  elseif not FREE and not co.spend(q.total, EC.ledgerWhy("Power Cable", q) .. string.format(" · %.0f m", L)) then return nil, "can't afford it: " .. money(q.total) end
  local t = agency_now()
  local c = ref("crew")
  local by = c and c.activeId and c.activeId() or nil
  local dp = ref("deployables")
  local rec = { id = opts.id, b = ra.b, a = { sid = a.sid, uid = a.uid }, z = { sid = z.sid, uid = z.uid }, len = L, h = h, ty = ty,
                v = 2, rk = (#rk > 0) and rk or nil, t = t, d = dp and dp.dateOf and dp.dateOf(t) or nil, by = by,
                paid = { cost = q.cost, ship = q.ship, foot = 0, total = q.total, t = t, supplier = q.supplier, by = by,
                         mats = (q.mode == "stock" and not FREE) and q.mats or nil } }
  local id = add(rec)
  if spawn_mesh then spawn_mesh(rec) end
  if (L or 0) >= 40 then local FT = ref("feats"); if FT and FT.once then pcall(FT.once, "cable_laid", { b = ra.b }) end end   -- (progression P2)
  -- (W2) a source's first cable to a store or a load
  do
    local FT = ref("feats")
    local pa2 = ST.getPart(a.sid, a.uid)
    local da2, dz2 = pa2 and defs(pa2.id), pz and defs(pz.id)
    local function src(d) local k = d and d.power and d.power.kind; return k == "solar" or k == "rtg" or k == "plant" end
    if FT and FT.once and not FREE and ((src(da2) and not src(dz2)) or (src(dz2) and not src(da2))) then pcall(FT.once, "source_wired", { b = ra.b }) end
  end
  if c and c.credit and by then pcall(c.credit, by, "built", 1, { body = ra.b }) end
  lastLay = { id = id, len = L, total = q.total, t = t, n = #pts, mass = q.mass }
  -- the ring: undo = a full refund within the minute; redo = lay it again
  local fb = ref("field_builder")
  if fb and fb.pushHistory and not opts.noHistory then
    local e = { label = "lay the " .. tostring(cdef(ty).label or "Power Cable"), kind = "cable", t = t, cable = id }
    e.undo = function()
      local r2 = get(e.cable)
      if not r2 then e.res, e.why = nil, "it's gone" return end
      remove(e.cable)
      local amt = math.floor((r2.paid and r2.paid.total) or 0)
      if r2.paid and r2.paid.mats then stock_give(r2.paid.mats)   -- (cut from stock: coiled back into it)
      elseif co.refund then co.refund(amt, "returned: Power Cable (undone within a minute)") else co.earn(amt, "returned: Power Cable") end
      if c and c.credit and by then pcall(c.credit, by, "built", -1) end
      e.res = amt
    end
    e.redo = function()
      local id2, w = lay(a, z, { id = e.cable, noHistory = true, ty = ty })
      if not id2 then e.res, e.why = nil, w return end
      e.t = agency_now()
      e.res = lastLay and lastLay.total or 0
    end
    fb.pushHistory(e)
  end
  return id, nil, q, L
end

-- (scn_dust) A scenario's start: a run already laid, by nobody, paid for
-- long ago (no Engineer's hand, no bill, no undo step). → id | nil, why
function layFree(a, z, opts)
  opts = opts or {}
  opts.noHistory = true
  FREE = true
  local ok, id, why, q, L = pcall(lay, a, z, opts)
  FREE = false
  if not ok then return nil, tostring(id) end
  return id, why, q, L
end

-- Take a cable up: the deconstruct rule (within its minute all of it, later
-- the price). → refund | nil, why
function takeUp(id, why)
  local r = get(id)
  if not r then return nil, "it's gone" end
  local EC, co = ref("base_economy"), ref("company")
  local amt = (EC and EC.deconstructRefund) and EC.deconstructRefund(r.paid, agency_now()) or 0
  -- (a cable cut from your own stock is coiled back into the stores in reach)
  if r.paid and r.paid.mats then stock_give(r.paid.mats) end
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
  local S = 8
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
-- The settle's inputs for a record: its ends, its body, the boxes it crosses.
-- A record from before the settle (no `v`) has its samples between the
-- touchdowns and no rocks; it settles the same way on what it has.
local function settle_inputs(r)
  local E = ends(r)
  local b = space and space.body and space.body(r.b)
  if not (E and b and type(r.h) == "table" and #r.h >= 2) then return nil end
  return E, b, obstaclesFor(r, E)
end
-- The drawn path of a record (body-relative points), settled. → pts, L, info | nil
function path(r)
  local E, b, boxes = settle_inputs(r)
  if not E then return nil end
  return polyline(E, r.h, b.radius, { old = (r.v or 1) < 2, boxes = boxes, rocks = r.rk, a = tensionA(b, cdef(r.ty), E), ty = r.ty })
end

drop_mesh = function(id)
  local L = live[id]
  if L and L.node and L.node.valid ~= false then L.node:destroy() end
  if L and L.old and L.old.valid ~= false then L.old:destroy() end
  live[id] = nil
end

-- (re)build a cable's mesh: once at load or lay, and again only when what it
-- lies on changed (`force`: the old mesh stays until the new one is placed).
spawn_mesh = function(r, force)
  local prev = live[r.id]
  if prev and not force then return end
  local planet = find and find(r.b)
  if not (planet and createNode) then return end
  local E, _, boxes = settle_inputs(r)
  if not E then return end
  local pts = path(r)
  if not pts then return end
  local m = tube_mesh(pts, cdef(r.ty).r or 0.016)
  if not m then return end
  local L = { making = true, key = boxesKey(boxes), old = prev and (prev.node or prev.old) or nil, pts = pts }
  live[r.id] = L
  local o = pts[1]
  createNode("PowerCable", planet, function(n)
    L.making = false
    if live[r.id] ~= L or not (recs and recs[r.id] == r) then n:destroy() return end
    n.x, n.y, n.z = o.x, o.y, o.z
    n.model = m
    pcall(n.setMaterial, n, CABLE_MAT)
    L.node = n
    if L.old and L.old.valid ~= false then L.old:destroy() end
    L.old = nil
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
  local v = validity(pending, hrec and { rec = hrec, part = hpart } or nil, body, pending and pending.ty or heldType())
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
        local ax, ay, az = endPoint(ST, ra, pa, defs(pa.id), hx, hy, hz, cdef(pending.ty).lift)
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
  pending = { sid = rec.id, uid = part.uid, b = rec.b, label = d and d.label or "part", ty = heldType() or "lv16" }
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
    out[#out + 1] = { id = "cb_info" .. i, type = "info", label = tostring(cdef(c.ty).label or "Power Cable") .. " " .. tostring(cid), group = "Cable", value = function()
        return string.format("to the %s%s · %.0f m · %.1f t", odef and odef.label or "part", bname and (" (" .. bname .. ")") or "",
          c.len or 0, (c.len or 0) * cdef(c.ty).kgm / 1000)
      end }
    -- (S5) what it carries now, against its rating
    out[#out + 1] = { id = "cb_load" .. i, type = "info", label = "Load", group = "Cable", value = function()
        local f = BG and BG.cableFlow and BG.cableFlow(cid)
        if not f then return "no grid on it" end
        if f.dead then return string.upper(f.why or "off") end
        local BP = ref("base_power")
        local kw = BP and BP.fmtKW or function(v) return string.format("%.1f kW", v) end
        return string.format("%s · %d %% of %s · loss %s", kw(f.P), math.floor(f.share * 100 + 0.5), kw(f.cap), kw(f.loss))
      end }
    if c.burnt then
      out[#out + 1] = { id = "cb_splice" .. i, type = "action", label = "Splice the burnt cable", group = "Cable",
        value = function() return money(spliceCost(c)) end, hint = "4 s",
        enabled = function() return layerWhyNot() == nil end,
        why = function() return layerWhyNot() and "Engineers only" or nil end,
        job = { secs = 4.0, label = "Splicing the cable",
          check = function() if not get(cid) then return false, "it's gone" end return true end,
          tick = function() end,
          done = function()
            local ok, w = splice(cid)
            if ctx and ctx.toast then ctx.toast(ok and "cable spliced" or tostring(w), not ok) end
            return ok, w
          end } }
    end
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

-- (S5) the drawn path of a cable as it was last built (body-relative
-- points; the POWER overlay draws over it), or nil while it isn't spawned
function pathOf(id) local L = live[id]; return L and L.pts or nil end
-- A cable burnt through by base_grid (the agency time), or spliced (nil).
function setBurnt(id, t)
  local r = get(id)
  if not r then return false end
  r.burnt = t
  write(r)
  bump()
  return true
end
-- What a splice costs: a quarter of what the run cost.
function spliceCost(r) return math.max(20, math.floor(((r.paid and r.paid.cost) or (r.len or 0) * 3) * 0.25 + 0.5)) end
function splice(id)
  local r = get(id)
  if not (r and r.burnt) then return false, "it isn't burnt" end
  local co = ref("company")
  local amt = spliceCost(r)
  if co and co.spend and not co.spend(amt, string.format("splice: %s %s", tostring(cdef(r.ty).label or "cable"), tostring(id))) then
    return false, "can't afford it: " .. money(amt)
  end
  setBurnt(id, nil)
  return true
end
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
  -- a part set down on a cable's line (or lifted off it): the cable settles again
  for _, id in ipairs(order) do
    local L, r = live[id], recs[id]
    if L and not L.making and r then
      local E = ends(r)
      if E and boxesKey(obstaclesFor(r, E)) ~= L.key then spawn_mesh(r, true); resettled = resettled + 1 end
    end
  end
  return #gone
end

-- THE GROUND CHANGED (flora_field.groundChanged forwards every dig, crater
-- and scrape: a world point and a radius). A cable whose line passes there is
-- sampled again once the ground has been quiet for `QUIET` s, and settles on
-- what is there now. → how many cables were marked
resettled = 0
local QUIET = 1.5
local dirty = {}        -- id → time of the last edit near it
function groundChanged(x, y, z, r)
  ensure()
  if #order == 0 or not (space and space.dominant and x) then return 0 end
  local bname = space.dominant(x, y, z)
  local b = bname and space.body(bname)
  if not b then return 0 end
  local px, py, pz = x - b.x, y - b.y, z - b.z
  local ux, uy, uz, pr = norm(px, py, pz)
  local n = 0
  for _, id in ipairs(order) do
    local rec = recs[id]
    if rec.b == bname then
      local E = ends(rec)
      if E then
        local ax, ay, az = norm(E.ax, E.ay, E.az)
        local bx, by, bz = norm(E.zx, E.zy, E.zz)
        local th = math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
        local ta = math.acos(math.max(-1, math.min(1, ux * ax + uy * ay + uz * az)))
        local tb = math.acos(math.max(-1, math.min(1, ux * bx + uy * by + uz * bz)))
        -- (near the line between its ends: within the edit's reach plus a hang)
        local nx, ny, nz, nl = norm(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
        local off = nl > 1e-9 and math.abs(px * nx + py * ny + pz * nz) or 0
        local reach = (r or 3) + 2.0
        if off <= reach and (ta + tb - th) * pr <= 2 * reach then dirty[id] = now(); n = n + 1 end
      end
    end
  end
  return n
end
-- Cables whose ground has gone quiet: sampled again and settled. → count
function settleDirty(force)
  local n = 0
  if terrain and terrain.pending and not force then
    local ok, p = pcall(terrain.pending)
    if ok and type(p) == "number" and p > 0 then return 0 end
  end
  for id, t in pairs(dirty) do
    local rec = recs and recs[id]
    if not rec then dirty[id] = nil
    elseif force or now() - t >= QUIET then
      dirty[id] = nil
      local E = ends(rec)
      local b = space.body(rec.b)
      if E and b then
        rec.h = sampleGround(b, E, b.radius, groundStep(rec.len))
        rec.v = 2
        write(rec)
        if live[id] then spawn_mesh(rec, true) end
        resettled = resettled + 1
        n = n + 1
      end
    end
  end
  if n > 0 then bump() end
  return n
end

local check_t = -10
function start(node)
  if findScripts then
    local all = findScripts("base_cable")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  recs, live, pending, preview, st_ver = nil, {}, nil, nil, nil
  for k in pairs(dirty) do dirty[k] = nil end
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
    if not (fb and fb.isOpen and fb.isOpen() and heldType() == pending.ty) then clearPending() end
  end
  local t = now()
  if t - check_t < 1.0 or #order == 0 then return end
  check_t = t
  if next(dirty) then settleDirty() end
  local a = find and find("Astronaut")
  local dom = a and space.dominant(a.x, a.y, a.z) or nil
  for _, id in ipairs(order) do
    local r = recs[id]
    if dom == r.b then spawn_mesh(r) elseif live[id] then drop_mesh(id) end
  end
end
