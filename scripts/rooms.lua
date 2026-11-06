-- ROOMS — the rooms a structure's pieces close (sandbox plan S3, PLAN §1.5;
-- docs/base-building.md §14). A pure rulebook on the Build Kit node: it loads
-- in a luajit test (tests/smoke_rooms.lua) and room_air.lua calls it. Nothing
-- here runs per frame: a structure is solved when its pieces change.
--
-- ── THE CELL GRID ───────────────────────────────────────────────────────────
-- Each structure has an implicit grid in its own frame (+X right, +Y up, +Z
-- front, metres): CELL (1 m) columns in X and Z, and in Y the LAYERS between
-- the planes its floors and roofs lie in (a storey is 2.4 m, so a fixed 1 m
-- step in Y would cut every room through the middle; the planes are the
-- structure's own, merged within MERGE). The X and Z grids are offset 0 or
-- 0.5 m, whichever puts more of the walls on cell faces (walls stand on the
-- 2 m modules' edge lines, which are whole metres from a structure's first
-- piece).
--
-- ── WHAT A PIECE CLOSES (parts_kit `seals`) ─────────────────────────────────
-- Every sealing piece is a set of flat QUADS in its own frame, turned into the
-- structure's frame by its yaw, pitch and roll (90° steps; a piece turned off
-- the grid seals nothing and is counted in `skipped`):
--   "z"     a wall: the quad through its middle, its width by its height
--   "y"     a floor or a slab: the quad through its thickness; a pitched roof
--           closes the plane at its eave
--   "door"  as the piece's class ("z" for a wall, "y" for a hatch floor, the
--           can's section for a hab bulkhead), sealed while its door is shut
--   "ring"  a hab can: a segment closes its four sides along its length (the
--           2.5 m can as the 2.5 x 2.5 m tube the grid can hold), an end cap
--           its section
--   nil     never: an open frame, a vent louvre, a rail. Wall-class pieces
--           that don't seal are kept as NAMED OPENINGS, so a leak can say
--           "the Vent Louvre Wall lets air through".
-- A vertical quad closes the faces of the cells it spans by at least half a
-- cell along the wall, in every layer it stands floor to ceiling in (within
-- TOL: a wall stands on a floor's top and stops under the next one's
-- underside). A half wall is short of the ceiling, so it closes nothing.
--
-- ── THE FILL ────────────────────────────────────────────────────────────────
-- Doors count as shut. The outside is filled first, from the grid's border
-- (one empty cell round everything) and from any open face at the lowest and
-- highest planes; every cell it doesn't reach is in a SEALED ROOM (one fill
-- each). Then the leaky rooms: outside cells under a roof and over a floor of
-- their own structure, filled among themselves; a set closed on more than
-- twice as many faces as it is open on is a LEAKY room (a box with a wall
-- missing), its open faces its LEAKS; anything more open (a canopy on posts)
-- is no room at all. A door face joins the two rooms (or a room and the
-- outside, 0) either side of it: the doors are what room_air opens.
--
-- ── THE RESULT ──────────────────────────────────────────────────────────────
--   R = { rooms = { room … }, byId, doors = { [uid] = { uid, a, b, label, airlock, x, y, z } },
--         ox, oz, ix0, iz0, NX, NZ, P = { planes }, NL, cells = n, skipped,
--         ms (the solve's time when a clock is given) }
--   room = { id, key, sealed, leaky, m3, cells = { cid … }, ncell, doors = { uid … },
--            leaks = { { x, y, z, label, uid } … }, cx, cy, cz, y0, y1,
--            airlock (a small sealed room with two doors, one an Airlock Wall),
--            seg = { x1,y1,z1, x2,y2,z2, … } (its outline, the structure frame) }
--   roomAt(R, lx, ly, lz) → room | nil      cellOf(R, lx, ly, lz) → cid | nil
--   cellKey(R, cid) → a number naming that cell in the structure (stable
--   across solves while the planes stay), cellV(R, cid) → its m³
--
-- COST: one pass over the pieces, one fill over the grid. ~2,000 cells (a
-- 4-room hab) is well under a millisecond in LuaJIT.

CELL = 1.0
TOL = 0.3          -- a wall's reach short of a layer's planes that still closes it
MERGE = 0.25       -- planes closer than this are one
MAX_CELLS = 300000 -- a structure bigger than this is not solved (it says so)
-- the hab can's section as the grid holds it (tools/gen_kit_parts.py HR 1.25, axis 1.65)
CAN = { x0 = -1.25, x1 = 1.25, y0 = 0.40, y1 = 2.90 }
AIRLOCK_M3 = 24.0  -- a chamber bigger than this is a room with two doors, not an airlock

local floor, ceil, abs, min, max = math.floor, math.ceil, math.abs, math.min, math.max

-- A part's up (+Y) and front (+Z) in its structure's frame (structures.localAxes,
-- the engine's own order: yaw about up, then pitch about X, then roll about Z).
local function localAxes(yaw, pitch, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local cr, sr = math.cos(roll), math.sin(roll)
  local function ry(v) return { cy * v[1] + sy * v[3], v[2], -sy * v[1] + cy * v[3] } end
  return ry({ -sr, cr * cp, cr * sp }), ry({ 0, -sp, cp })
end

-- The flat quads a piece closes, in its own ground frame:
-- { { ax = 1|2|3 (the local axis it is flat across), c, r = { lo, hi } per other
--   axis (r[1], r[2], r[3] with r[ax] unused), door = bool, open = bool } … }
function localQuads(d)
  local b = d.box
  if not b then return {} end
  local s, out = d.seals, {}
  local function Q(ax, c, x0, x1, y0, y1, z0, z1, door, open)
    out[#out + 1] = { ax = ax, c = c, r = { { x0, x1 }, { y0, y1 }, { z0, z1 } }, door = door, open = open }
  end
  local snap = d.snap
  if s == "z" or (s == "door" and snap == "wall") then
    Q(3, (b[5] + b[6]) / 2, b[1], b[2], b[3], b[4], 0, 0, s == "door")
  elseif s == "y" or (s == "door" and snap == "floor") then
    local c = d.slopeZ and (b[3] + 0.1) or (b[3] + b[4]) / 2
    Q(2, c, b[1], b[2], 0, 0, b[5], b[6], s == "door")
  elseif s == "ring" or (s == "door" and snap == "hab") then
    local C = CAN
    if s == "ring" and (b[6] - b[5]) >= 1.5 then
      -- a segment: its two sides, its floor and its crown, along its length
      Q(1, C.x0, 0, 0, C.y0, C.y1, b[5], b[6])
      Q(1, C.x1, 0, 0, C.y0, C.y1, b[5], b[6])
      Q(2, C.y0, C.x0, C.x1, 0, 0, b[5], b[6])
      Q(2, C.y1, C.x0, C.x1, 0, 0, b[5], b[6])
    else
      -- an end cap or a door bulkhead: its section
      Q(3, (b[5] + b[6]) / 2, C.x0, C.x1, C.y0, C.y1, 0, 0, s == "door")
    end
  elseif s == nil and snap == "wall" then
    -- (doesn't seal: kept to name the leak it is)
    Q(3, (b[5] + b[6]) / 2, b[1], b[2], b[3], b[4], 0, 0, false, true)
  end
  return out
end

-- A local quad turned into the structure's frame at piece `p` (seat `seat`):
-- → { A (structure axis it is flat across), c, lo = {x,y,z}, hi = {x,y,z} } | nil
-- (nil: turned off the 90° grid)
local function place_quad(q, p, seat, U, F, X)
  local ox, oy, oz = p.x or 0, (p.y or 0) + (seat or 0), p.z or 0
  local r = q.r
  local ax = q.ax
  -- (the box's AABB in the structure: per axis, the sum of each local axis's
  -- reach; exact for any turn, the quad flat across its own axis)
  local a0, a1 = r[1][1], r[1][2]
  local b0, b1 = r[2][1], r[2][2]
  local c0, c1 = r[3][1], r[3][2]
  if ax == 1 then a0, a1 = q.c, q.c elseif ax == 2 then b0, b1 = q.c, q.c else c0, c1 = q.c, q.c end
  local lo, hi = { ox, oy, oz }, { ox, oy, oz }
  for k = 1, 3 do
    local u, v = X[k] * a0, X[k] * a1
    if u < v then lo[k], hi[k] = lo[k] + u, hi[k] + v else lo[k], hi[k] = lo[k] + v, hi[k] + u end
    u, v = U[k] * b0, U[k] * b1
    if u < v then lo[k], hi[k] = lo[k] + u, hi[k] + v else lo[k], hi[k] = lo[k] + v, hi[k] + u end
    u, v = F[k] * c0, F[k] * c1
    if u < v then lo[k], hi[k] = lo[k] + u, hi[k] + v else lo[k], hi[k] = lo[k] + v, hi[k] + u end
  end
  -- the axis it is flat across, in the structure: the local one's column
  local n = (ax == 1 and X) or (ax == 2 and U) or F
  local A = nil
  for k = 1, 3 do if abs(abs(n[k]) - 1) < 1e-3 then A = k end end
  if not A then return nil end
  return { A = A, c = (lo[A] + hi[A]) / 2, lo = lo, hi = hi }
end

-- Every quad of structure `rec`'s pieces in its frame.
-- defs(id) → the part record (parts_base.partInfo). → quads, skipped
local lq_cache = setmetatable({}, { __mode = "k" })
function quadsOf(rec, defs)
  local out, skipped = {}, 0
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.kit and not d.live then
      local lq = lq_cache[d]
      if not lq then lq = localQuads(d); lq_cache[d] = lq end
      if #lq > 0 then
        local U, F = localAxes(p.yaw or 0, p.pitch or 0, p.roll or 0)
        local X = { U[2] * F[3] - U[3] * F[2], U[3] * F[1] - U[1] * F[3], U[1] * F[2] - U[2] * F[1] }
        for _, q in ipairs(lq) do
          local w = place_quad(q, p, d.seat or 0, U, F, X)
          if w then
            w.door, w.open, w.uid = q.door, q.open, p.uid
            w.label = d.label
            w.airlock = d.door and d.door.airlock == true or nil
            out[#out + 1] = w
          else skipped = skipped + 1 end
        end
      end
    end
  end
  return out, skipped
end

-- The seal signature of a structure: what makes a new solve needed (the
-- pieces that seal or name an opening, where they stand). → string
function signatureOf(rec, defs)
  local t = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.kit and (d.seals or d.snap == "wall" or d.life or d.eqv) then
      t[#t + 1] = string.format("%d:%s:%.2f:%.2f:%.2f:%.3f:%.3f:%.3f", p.uid, p.id, p.x or 0, p.y or 0, p.z or 0, p.yaw or 0, p.pitch or 0, p.roll or 0)
    end
  end
  table.sort(t)
  return table.concat(t, "|")
end

local function overlap(a0, a1, b0, b1) return min(a1, b1) - max(a0, b0) end

-- THE SOLVE. rec = a structure record; defs = partInfo; clock() → seconds
-- (optional, for the time it took). → R (above)
function solve(rec, defs, clock)
  local t0 = clock and clock()
  local quads, skipped = quadsOf(rec, defs)
  local R = { rooms = {}, byId = {}, doors = {}, roomOf = {}, skipped = skipped, NL = 0, cells = 0 }
  -- the planes: the floors' and roofs' (and the cans')
  local ys = {}
  for _, q in ipairs(quads) do if q.A == 2 and not q.open then ys[#ys + 1] = q.c end end
  table.sort(ys)
  local P = {}
  for _, y in ipairs(ys) do
    if #P == 0 or y - P[#P] > MERGE then P[#P + 1] = y end
  end
  R.P = P
  if #P < 2 then return R end
  local function plane_of(y)
    local best, bd = nil, MERGE + 1e-6
    for j, v in ipairs(P) do local d = abs(v - y); if d <= bd then best, bd = j, d end end
    return best
  end
  -- the grid's offsets: 0 or 0.5 m, whichever puts more walls on cell faces
  local vx0, vx5, vz0, vz5 = 0, 0, 0, 0
  local minx, maxx, minz, maxz = 1e18, -1e18, 1e18, -1e18
  for _, q in ipairs(quads) do
    if not q.open then
      local f = (q.c % CELL) / CELL
      if q.A == 1 then if abs(f - 0.5) < 0.1 then vx5 = vx5 + 1 elseif f < 0.1 or f > 0.9 then vx0 = vx0 + 1 end end
      if q.A == 3 then if abs(f - 0.5) < 0.1 then vz5 = vz5 + 1 elseif f < 0.1 or f > 0.9 then vz0 = vz0 + 1 end end
      minx, maxx = min(minx, q.lo[1]), max(maxx, q.hi[1])
      minz, maxz = min(minz, q.lo[3]), max(maxz, q.hi[3])
    end
  end
  if minx > maxx then return R end
  local ox = (vx5 > vx0) and 0.5 * CELL or 0
  local oz = (vz5 > vz0) and 0.5 * CELL or 0
  local ix0 = floor((minx - ox) / CELL + 1e-6) - 1
  local ix1 = ceil((maxx - ox) / CELL - 1e-6) + 1
  local iz0 = floor((minz - oz) / CELL + 1e-6) - 1
  local iz1 = ceil((maxz - oz) / CELL - 1e-6) + 1
  local NX, NZ, NL = ix1 - ix0, iz1 - iz0, #P - 1
  R.ox, R.oz, R.ix0, R.iz0, R.NX, R.NZ, R.NL = ox, oz, ix0, iz0, NX, NZ, NL
  if NX * NZ * NL > MAX_CELLS then R.err = string.format("too big to solve (%d cells)", NX * NZ * NL) return R end
  R.cells = NX * NZ * NL
  -- faces: X (the low-x side of cell i), Z (the low-z side), Y (under layer j
  -- at plane j; j = #P is over the top layer). value 1 = sealed, 2 = a door.
  local fX, fZ, fY = {}, {}, {}
  local dX, dZ, dY = {}, {}, {}    -- a door face's uid
  local nX, nZ = {}, {}            -- a named opening's uid on a face
  local qlab = {}                  -- uid → { label, airlock }
  local function fid(i, j, k) return (j * NZ + k) * NX + i end
  local function put(F_, D_, key, q)
    if q.open then return end
    if q.door then
      if F_[key] ~= 1 then F_[key] = 2; D_[key] = q.uid end
    else F_[key] = 1; D_[key] = nil end
  end
  local function cells_along(a0, a1, o, i0, n)
    local out = {}
    local lo_, hi_ = floor((a0 - o) / CELL) - i0 - 1, ceil((a1 - o) / CELL) - i0 + 1
    for i = max(0, lo_), min(n - 1, hi_) do
      local c0 = o + (i0 + i) * CELL
      if overlap(c0, c0 + CELL, a0, a1) >= 0.5 * CELL - 1e-6 then out[#out + 1] = i end
    end
    return out
  end
  local function layers_of(y0, y1)
    local out = {}
    for j = 1, NL do
      if y0 <= P[j] + TOL and y1 >= P[j + 1] - TOL then out[#out + 1] = j end
    end
    return out
  end
  for _, q in ipairs(quads) do
    qlab[q.uid] = qlab[q.uid] or { label = q.label, airlock = q.airlock }
    if q.A == 1 or q.A == 3 then
      local o, i0, n = (q.A == 1) and ox or oz, (q.A == 1) and ix0 or iz0, (q.A == 1) and NX or NZ
      local fi = floor((q.c - o) / CELL + 0.5) - i0
      if fi >= 1 and fi <= n - 1 then
        local along = (q.A == 1) and cells_along(q.lo[3], q.hi[3], oz, iz0, NZ) or cells_along(q.lo[1], q.hi[1], ox, ix0, NX)
        -- (a sealing piece short of a layer it stands in — a half wall — names
        -- the gap over it)
        if not q.open then
          for j = 1, NL do
            local ov = overlap(P[j], P[j + 1], q.lo[2], q.hi[2])
            if ov > 0.3 and not (q.lo[2] <= P[j] + TOL and q.hi[2] >= P[j + 1] - TOL) then
              qlab[q.uid].short = true
              for _, a in ipairs(along) do
                if q.A == 1 then local key = fid(fi, j, a); nX[key] = nX[key] or q.uid
                else local key = fid(a, j, fi); nZ[key] = nZ[key] or q.uid end
              end
            end
          end
        end
        for _, j in ipairs(layers_of(q.lo[2], q.hi[2])) do
          for _, a in ipairs(along) do
            if q.A == 1 then
              local key = fid(fi, j, a)
              if q.open then nX[key] = nX[key] or q.uid else put(fX, dX, key, q) end
            else
              local key = fid(a, j, fi)
              if q.open then nZ[key] = nZ[key] or q.uid else put(fZ, dZ, key, q) end
            end
          end
        end
      end
    elseif q.A == 2 and not q.open then
      local pj = plane_of(q.c)
      if pj then
        local xs = cells_along(q.lo[1], q.hi[1], ox, ix0, NX)
        local zs = cells_along(q.lo[3], q.hi[3], oz, iz0, NZ)
        for _, i in ipairs(xs) do for _, k in ipairs(zs) do put(fY, dY, fid(i, pj, k), q) end end
      end
    end
  end
  R.qlab = qlab
  -- ── the fill ──
  -- cells: cid = ((j - 1) * NZ + k) * NX + i, j = 1..NL
  local function cid(i, j, k) return ((j - 1) * NZ + k) * NX + i end
  local function ijk(c) local i = c % NX; local r = (c - i) / NX; local k = r % NZ; return i, (r - k) / NZ + 1, k end
  local total = NX * NZ * NL
  local comp = {}           -- cid → 0 (outside) | room number
  -- a cell's six neighbours (doors shut), into NB (cid, -1 = the outside),
  -- FV (the face's value: nil open, 1 sealed, 2 a door), FK (the face's key)
  -- and KD (1 x, 2 z, 3 y). No closures: this is the fill's inner loop.
  local NB, FV, FK = {}, {}, {}
  local KD = { 1, 1, 2, 2, 3, 3 }
  local function nbs(c)
    local i = c % NX
    local r = (c - i) / NX
    local k = r % NZ
    local j = (r - k) / NZ + 1
    local f0 = (j * NZ + k) * NX + i
    FK[1] = f0;          FV[1] = fX[f0];          NB[1] = (i >= 1) and c - 1 or -1
    FK[2] = f0 + 1;      FV[2] = fX[f0 + 1];      NB[2] = (i + 1 <= NX - 1) and c + 1 or -1
    FK[3] = f0;          FV[3] = fZ[f0];          NB[3] = (k >= 1) and c - NX or -1
    FK[4] = f0 + NX;     FV[4] = fZ[f0 + NX];     NB[4] = (k + 1 <= NZ - 1) and c + NX or -1
    FK[5] = f0;          FV[5] = fY[f0];          NB[5] = (j >= 2) and c - NX * NZ or -1
    FK[6] = f0 + NX * NZ; FV[6] = fY[f0 + NX * NZ]; NB[6] = (j + 1 <= NL) and c + NX * NZ or -1
    -- (a border face in X or Z: no wall can stand there, the grid has a margin)
    if NB[1] < 0 then FV[1], FK[1] = nil, nil end
    if NB[2] < 0 then FV[2], FK[2] = nil, nil end
    if NB[3] < 0 then FV[3], FK[3] = nil, nil end
    if NB[4] < 0 then FV[4], FK[4] = nil, nil end
  end
  local KN = { "x", "x", "z", "z", "y", "y" }
  -- the outside: every cell with an open face to the out
  local queue, qh = {}, 1
  for c = 0, total - 1 do
    nbs(c)
    for q = 1, 6 do if NB[q] == -1 and FV[q] == nil then comp[c] = 0; queue[#queue + 1] = c break end end
  end
  while qh <= #queue do
    local c = queue[qh]; qh = qh + 1
    nbs(c)
    for q = 1, 6 do
      local nb = NB[q]
      if nb >= 0 and FV[q] == nil and comp[nb] == nil then comp[nb] = 0; queue[#queue + 1] = nb end
    end
  end
  -- the sealed rooms
  local rooms = {}
  local function cellV(c) local _, j = ijk(c); return CELL * CELL * max(0.1, (P[j + 1] - P[j]) - 0.2) end
  local function new_room(sealed)
    local r = { id = #rooms + 1, sealed = sealed, leaky = not sealed, cells = {}, m3 = 0, doors = {}, leaks = {} }
    rooms[#rooms + 1] = r
    return r
  end
  for c = 0, total - 1 do
    if comp[c] == nil then
      local r = new_room(true)
      comp[c] = r.id
      local q2, h2 = { c }, 1
      while h2 <= #q2 do
        local x = q2[h2]; h2 = h2 + 1
        r.cells[#r.cells + 1] = x
        nbs(x)
        for q = 1, 6 do
          local nb = NB[q]
          if nb >= 0 and FV[q] == nil and comp[nb] == nil then comp[nb] = r.id; q2[#q2 + 1] = nb end
        end
      end
    end
  end
  -- the leaky rooms: outside cells with a floor under and a roof over them
  local below, above = {}, {}  -- column → lowest / highest sealed plane index
  for i = 0, NX - 1 do
    for k = 0, NZ - 1 do
      local lo_, hi_ = nil, nil
      for j = 1, #P do
        if fY[fid(i, j, k)] then lo_ = lo_ or j; hi_ = j end
      end
      local col = k * NX + i
      below[col], above[col] = lo_, hi_
    end
  end
  local function covered(c)
    local i, j, k = ijk(c)
    local col = k * NX + i
    local lo_, hi_ = below[col], above[col]
    if not lo_ or lo_ > j or hi_ < j + 1 then return false end
    -- (a floor at or under this layer, a roof at or over its top: not just the plane under it)
    local okb, oka = false, false
    for jj = 1, j do if fY[fid(i, jj, k)] then okb = true end end
    for jj = j + 1, #P do if fY[fid(i, jj, k)] then oka = true end end
    return okb and oka
  end
  local cand = {}
  for c = 0, total - 1 do if comp[c] == 0 and covered(c) then cand[c] = true end end
  local seen = {}
  for c = 0, total - 1 do
    if cand[c] and not seen[c] then
      local set, q2, h2 = {}, { c }, 1
      seen[c] = true
      local closed, open_, leakf = 0, 0, {}
      while h2 <= #q2 do
        local x = q2[h2]; h2 = h2 + 1
        set[#set + 1] = x
        nbs(x)
        for q = 1, 6 do
          local nb, v = NB[q], FV[q]
          if v ~= nil then closed = closed + 1
          elseif nb >= 0 and cand[nb] then
            if not seen[nb] then seen[nb] = true; q2[#q2 + 1] = nb end
          else
            open_ = open_ + 1
            leakf[#leakf + 1] = { x, KN[q], FK[q], nb }
          end
        end
      end
      if 2 * open_ < closed then
        local r = new_room(false)
        for _, x in ipairs(set) do comp[x] = r.id; r.cells[#r.cells + 1] = x end
        r.leakFaces = leakf
      end
    end
  end
  -- volumes, centres, keys
  for _, r in ipairs(rooms) do
    local sx, sy, sz, sv = 0, 0, 0, 0
    local y0, y1 = 1e18, -1e18
    local kmin = nil
    for _, c in ipairs(r.cells) do
      local i, j, k = ijk(c)
      local v = cellV(c)
      r.m3 = r.m3 + v
      local cx, cz = ox + (ix0 + i + 0.5) * CELL, oz + (iz0 + k + 0.5) * CELL
      sx, sy, sz, sv = sx + cx * v, sy + (P[j] + P[j + 1]) / 2 * v, sz + cz * v, sv + v
      y0, y1 = min(y0, P[j]), max(y1, P[j + 1])
      local key = cellKey(R, c)
      if not kmin or key < kmin then kmin = key end
    end
    r.cx, r.cy, r.cz = sx / sv, sy / sv, sz / sv
    r.y0, r.y1 = y0, y1
    r.key = kmin
    r.ncell = #r.cells
  end
  for c, id in pairs(comp) do if id > 0 then R.roomOf[c] = id end end
  -- the doors: the rooms either side of every door face
  local function door_face(key, kind)
    local uid = (kind == "x" and dX[key]) or (kind == "z" and dZ[key]) or dY[key]
    return uid
  end
  for c = 0, total - 1 do
    nbs(c)
    for q = 1, 6 do
      local nb, v, kind, key = NB[q], FV[q], KN[q], FK[q]
      if v == 2 then
        local uid = door_face(key, kind)
        local a = comp[c] or 0
        local b = (nb >= 0) and (comp[nb] or 0) or 0
        if uid and a ~= b then
          local d = R.doors[uid]
          if not d then
            local ql = qlab[uid] or {}
            d = { uid = uid, a = min(a, b), b = max(a, b), label = ql.label, airlock = ql.airlock, faces = 0, fc = { c, kind, key } }
            R.doors[uid] = d
          end
          d.faces = d.faces + 1
        end
      end
    end
  end
  for uid, d in pairs(R.doors) do
    for _, id in ipairs({ d.a, d.b }) do
      local r = rooms[id]
      if r then
        local have = false
        for _, u in ipairs(r.doors) do if u == uid then have = true end end
        if not have then r.doors[#r.doors + 1] = uid end
      end
    end
  end
  for _, r in ipairs(rooms) do table.sort(r.doors) end
  -- the leaks: where each leaky room is open, named by the piece there
  local function face_centre(c, kind, key, nb)
    local i, j, k = ijk(c)
    local x, y, z = ox + (ix0 + i + 0.5) * CELL, (P[j] + P[j + 1]) / 2, oz + (iz0 + k + 0.5) * CELL
    if not key then return x, y, z end
    if kind == "x" then
      local fi = key % NX
      x = ox + (ix0 + fi) * CELL
    elseif kind == "z" then
      local fk = ((key - key % NX) / NX) % NZ
      z = oz + (iz0 + fk) * CELL
    else
      local fj = floor(key / (NX * NZ))
      y = P[fj]
    end
    return x, y, z
  end
  -- (where each door is: the middle of its first face, for the overlay)
  for _, d in pairs(R.doors) do
    if d.fc then d.x, d.y, d.z = face_centre(d.fc[1], d.fc[2], d.fc[3]); d.fc = nil end
  end
  for _, r in ipairs(rooms) do
    if r.leakFaces then
      local got = {}
      for _, lf in ipairs(r.leakFaces) do
        local c, kind, key, nb = lf[1], lf[2], lf[3], lf[4]
        local named = key and ((kind == "x" and nX[key]) or (kind == "z" and nZ[key])) or nil
        local x, y, z = face_centre(c, kind, key, nb)
        if named then
          if not got[named] then
            got[named] = true
            local ql = qlab[named] or {}
            r.leaks[#r.leaks + 1] = { x = x, y = y, z = z, uid = named, n = 1,
                                      label = ql.short and ("the " .. (ql.label or "wall") .. " stops short of the ceiling")
                                        or ((ql.label or "an opening") .. " lets air through") }
          end
        else
          local merged = false
          for _, l in ipairs(r.leaks) do
            if not l.uid and abs(l.x - x) + abs(l.y - y) + abs(l.z - z) < 2.6 then
              l.n = l.n + 1
              l.sx, l.sy, l.sz = l.sx + x, l.sy + y, l.sz + z
              l.x, l.y, l.z = l.sx / l.n, l.sy / l.n, l.sz / l.n
              merged = true
              break
            end
          end
          if not merged and #r.leaks < 12 then
            r.leaks[#r.leaks + 1] = { x = x, y = y, z = z, sx = x, sy = y, sz = z, n = 1,
                                      label = kind == "y" and (y < r.cy and "a gap in the floor" or "a gap in the roof") or "a gap in the wall" }
          end
        end
      end
      r.leakFaces = nil
    end
  end
  -- airlocks: a small sealed room with two doors or more, one an Airlock Wall's
  for _, r in ipairs(rooms) do
    if r.sealed and #r.doors >= 2 and r.m3 <= AIRLOCK_M3 then
      for _, u in ipairs(r.doors) do if R.doors[u].airlock then r.airlock = true end end
    end
  end
  -- outlines: each room's footprint edges on its floor and under its ceiling
  for _, r in ipairs(rooms) do
    local seg = {}
    local inr = {}
    for _, c in ipairs(r.cells) do inr[c] = true end
    local lowest, highest = {}, {}
    for _, c in ipairs(r.cells) do
      local i, j, k = ijk(c)
      local col = k * NX + i
      if not lowest[col] or j < lowest[col] then lowest[col] = j end
      if not highest[col] or j > highest[col] then highest[col] = j end
    end
    local function add(x1, y1, z1, x2, y2, z2) local n = #seg; seg[n + 1], seg[n + 2], seg[n + 3], seg[n + 4], seg[n + 5], seg[n + 6] = x1, y1, z1, x2, y2, z2 end
    for _, c in ipairs(r.cells) do
      local i, j, k = ijk(c)
      local col = k * NX + i
      local x0_, z0_ = ox + (ix0 + i) * CELL, oz + (iz0 + k) * CELL
      local x1_, z1_ = x0_ + CELL, z0_ + CELL
      local yl, yh = P[j] + 0.16, P[j + 1] - 0.08
      local function side(nb, xa, za, xb, zb)
        if nb ~= nil and inr[nb] then return end
        if lowest[col] == j then add(xa, yl, za, xb, yl, zb) end
        if highest[col] == j and #seg < 2400 then add(xa, yh, za, xb, yh, zb) end
      end
      side(i >= 1 and cid(i - 1, j, k) or nil, x0_, z0_, x0_, z1_)
      side(i + 1 <= NX - 1 and cid(i + 1, j, k) or nil, x1_, z0_, x1_, z1_)
      side(k >= 1 and cid(i, j, k - 1) or nil, x0_, z0_, x1_, z0_)
      side(k + 1 <= NZ - 1 and cid(i, j, k + 1) or nil, x0_, z1_, x1_, z1_)
    end
    r.seg = seg
  end
  R.rooms = rooms
  for _, r in ipairs(rooms) do R.byId[r.id] = r end
  if t0 then R.ms = (clock() - t0) * 1000 end
  return R
end

-- ── lookups ──────────────────────────────────────────────────────────────────

-- The cell at structure-local (lx, ly, lz): → cid | nil
function cellOf(R, lx, ly, lz)
  if not R or not R.NX or R.NL < 1 then return nil end
  local i = floor((lx - R.ox) / CELL) - R.ix0
  local k = floor((lz - R.oz) / CELL) - R.iz0
  if i < 0 or i >= R.NX or k < 0 or k >= R.NZ then return nil end
  local P, j = R.P, nil
  for jj = 1, R.NL do if ly >= P[jj] and ly < P[jj + 1] then j = jj break end end
  if not j then return nil end
  return ((j - 1) * R.NZ + k) * R.NX + i
end
function roomAt(R, lx, ly, lz)
  local c = cellOf(R, lx, ly, lz)
  local id = c and R.roomOf[c]
  return id and R.byId[id] or nil
end
-- A number that names cell `c` in its structure: the same cell keeps it from
-- one solve to the next while the planes stay where they are.
function cellKey(R, c)
  local i = c % R.NX
  local r = (c - i) / R.NX
  local k = r % R.NZ
  local j = (r - k) / R.NZ + 1
  local ai, ak = R.ix0 + i + 4096, R.iz0 + k + 4096
  local ay = floor(R.P[j] * 10 + 0.5) + 4096
  return (ay * 8192 + ak) * 8192 + ai
end
function cellV(R, c)
  local i = c % R.NX
  local r = (c - i) / R.NX
  local k = r % R.NZ
  local j = (r - k) / R.NZ + 1
  return CELL * CELL * max(0.1, (R.P[j + 1] - R.P[j]) - 0.2)
end
