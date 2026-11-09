-- BASE_SNAP — where a part in the Engineer's hand goes, and what the ground
-- under it needs (deep-space addendum K5–K7; docs/base-building.md §7).
--
-- A pure RULEBOOK on the Build Kit node (scenes/system.ron): no scene access,
-- its globals are its API, and it loads from disk in a luajit test
-- (tests/smoke_base_build.lua). field_builder asks; this answers with poses.
-- Everything is in a BODY's frame (planet-relative, docs/positions-and-
-- frames.md rule 1) or in a STRUCTURE's frame (structures.lua: +X right,
-- +Y up, +Z front, at its founding ground point).
--
-- THREE WAYS A PART GOES DOWN (decided by what is under the cursor):
--
--   EDGE   a part with a `tile` (the Pad Plate) next to another of the same
--          tile: it takes the free neighbour slot nearest the cursor, edge to
--          edge, square to it, its deck level with it, and JOINS that
--          structure. (K5a: plates edge to edge.)
--   DECK   a part that stands `onDeck` (shed, hab) aimed at a part with a
--          `deck` (the plate): it stands on the deck's top, on a 0.5 m grid
--          in the structure's frame, square to it (90° steps toward you,
--          plus the turn you dialled), and joins the structure. It is
--          SUPPORTED only if every sample of its footprint is over a deck of
--          that structure at that height: a hab spans two plates edge to
--          edge, never one. (K5a: a shed on a plate, a hab on plates.)
--   GROUND anything else on the terrain starts a NEW structure. On a 0.5 m
--          grid and in 90° steps square to the nearest structure within
--          NEAR_R (or, with none, the frame field_builder hands in: the
--          spaceport's layout), plus the turn you dialled in YAW_STEP steps.
--          Shift frees both (mode "free"). (K5b, K6.)
--
-- THE GROUND (K7). A ground part samples the terrain under its footprint
-- (field_builder casts; `footPoints` says where) and `foundation` decides:
-- its base is the mean of the samples (cut and fill balance) plus the raise
-- you dialled, or, for a part that joins a structure, the structure's level.
-- More than the part's `grade` between the base and the ground anywhere is
-- refused; otherwise the ground under it is levelled to the base
-- (`gradeDiscs`: terrain.sculpt "flatten" discs in the part's plane), and
-- where the ground falls more than FOOTING_FROM (or the part's own skirt)
-- below the base a cast concrete footing fills it, down to the lowest sample
-- and FOOTING_KEY into the ground.

YAW_STEP = math.rad(15)
YAW_FINE = math.rad(5)
GRID = 0.5
NEAR_R = 30.0
JOIN_R = 12.0            -- ground this near a placed part joins its structure
EDGE_CAPTURE = 0.8       -- of a tile: how near the cursor must be to a free slot
DECK_INSET = 0.25        -- footprint samples sit this far inside its edge
FOOTING_FROM = 0.30
FOOTING_KEY = 0.30
RAISE_MAX, RAISE_STEP = 2.0, 0.25
QUARTER = math.pi / 2

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end
local function V(x, y, z) return { x = x, y = y, z = z } end
function quantize(a, step) return math.floor(a / step + 0.5) * step end
function wrap(a)
  a = (a + math.pi) % (2 * math.pi)
  return a - math.pi
end

-- ── frames ──────────────────────────────────────────────────────────────────

-- A structure's frame { O, U, F, R } from its record (re-orthonormalised as
-- structures.frame does: up, front flattened onto it, right = up × front).
function frameOf(r)
  local ux, uy, uz = norm(r.ux or 0, r.uy or 1, r.uz or 0)
  local fx, fy, fz = r.fx or 0, r.fy or 0, r.fz or 1
  local d = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-6 then fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz end
  fx, fy, fz = norm(fx, fy, fz)
  local rx, ry, rz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
  return { O = V(r.x, r.y, r.z), U = V(ux, uy, uz), F = V(fx, fy, fz), R = V(rx, ry, rz) }
end
function toLocal(fr, x, y, z)
  local d = V(x - fr.O.x, y - fr.O.y, z - fr.O.z)
  return dot(d, fr.R), dot(d, fr.U), dot(d, fr.F)
end
function toBody(fr, lx, ly, lz)
  return fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz,
         fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
         fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
end
-- the front a part turned `yaw` (about up, + from front toward right) faces
function yawDir(fr, yaw)
  local c, s = math.cos(yaw), math.sin(yaw)
  return V(fr.F.x * c + fr.R.x * s, fr.F.y * c + fr.R.y * s, fr.F.z * c + fr.R.z * s)
end
-- the yaw of a direction in a frame (its tangent part)
function yawOf(fr, d) return math.atan2(dot(d, fr.R), dot(d, fr.F)) end

-- ── footprints (in a structure's x, z) ──────────────────────────────────────

-- A point (px, pz) of a part's own frame → the structure's (x, z).
local function part_to(lx, lz, yaw, px, pz)
  local c, s = math.cos(yaw), math.sin(yaw)
  return lx + px * c + pz * s, lz - px * s + pz * c
end
-- The structure's (x, z) → the part's own frame.
local function to_part(part, x, z)
  local c, s = math.cos(part.yaw or 0), math.sin(part.yaw or 0)
  local dx, dz = x - (part.x or 0), z - (part.z or 0)
  return dx * c - dz * s, dx * s + dz * c
end

-- The footprint's sample points: a 3 x 3 grid (corners, edge middles,
-- centre) `inset` m inside its edge, in the structure's (x, z), or in the
-- part's own frame with lx = lz = yaw = 0.
function footPoints(def, lx, lz, yaw, inset)
  local hx, hz = math.max(0.05, def.half.x - (inset or 0)), math.max(0.05, def.half.z - (inset or 0))
  local out = {}
  for i = -1, 1 do
    for j = -1, 1 do
      local x, z = part_to(lx or 0, lz or 0, yaw or 0, i * hx, j * hz)
      out[#out + 1] = { x = x, z = z }
    end
  end
  return out
end

-- Is the structure point (x, z) over part `p` (def `d`), `pad` m of slack?
function over(d, p, x, z, pad)
  local px, pz = to_part(p, x, z)
  pad = pad or 0
  return math.abs(px) <= d.half.x + pad and math.abs(pz) <= d.half.z + pad
end

-- The deck of structure `rec` under (x, z) at height `top` (±tol): the part.
function deckUnder(rec, defs, x, z, top, tol)
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.deck and math.abs((p.y or 0) + d.deck - top) <= (tol or 0.05) and over(d, p, x, z, 0.02) then return p end
  end
  return nil
end

-- How many of the footprint's samples stand on a deck of `rec` at `top`.
-- → n_ok, n_total
function supported(rec, defs, def, lx, top, lz, yaw)
  local pts = footPoints(def, lx, lz, yaw, DECK_INSET)
  local ok = 0
  for _, q in ipairs(pts) do if deckUnder(rec, defs, q.x, q.z, top) then ok = ok + 1 end end
  return ok, #pts
end

-- A tile part of size `tile` already centred at (x, z) at level y in `rec`.
function slotTaken(rec, defs, tile, x, y, z)
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.tile == tile and math.abs((p.y or 0) - y) < 0.5
       and (p.x - x) ^ 2 + (p.z - z) ^ 2 < (tile * 0.45) ^ 2 then return p end
  end
  return nil
end

-- The parts that stand on part `uid`'s deck, and on theirs (what comes down
-- with it). → { uid … } (not uid itself)
function dependents(rec, defs, uid)
  local out, seen = {}, { [uid] = true }
  local queue = { uid }
  while #queue > 0 do
    local u = table.remove(queue, 1)
    local base = nil
    for _, p in ipairs(rec.bp or {}) do if p.uid == u then base = p end end
    local bd = base and defs(base.id)
    if bd and bd.deck then
      local top = (base.y or 0) + bd.deck
      for _, p in ipairs(rec.bp or {}) do
        local d = defs(p.id)
        if not seen[p.uid] and d and d.onDeck and math.abs((p.y or 0) - top) < 0.05 then
          for _, q in ipairs(footPoints(d, p.x, p.z, p.yaw, DECK_INSET)) do
            if over(bd, base, q.x, q.z, 0.02) then
              seen[p.uid] = true
              out[#out + 1] = p.uid
              queue[#queue + 1] = p.uid
              break
            end
          end
        end
      end
    end
  end
  return out
end

-- ── the snap ────────────────────────────────────────────────────────────────

-- q = { def, P = {x,y,z} (body-relative hit), U = {x,y,z} (radial up there),
--       toward = {x,y,z} (body-frame, toward the Engineer), hit = { rec, part }
--       (the ray stopped on a placed part) | nil, near = { { rec, part, d } … }
--       (placed parts round P, nearest first), defs = fn(id) → def,
--       free = Shift held, yawOff = the turn dialled (rad), ref = a frame
--       { O, U, F, R } for the ground grid when no structure is near | nil }
-- → pose { mode = "edge"|"deck"|"grid"|"free", rec (joined) | nil, lx, ly, lz,
--          yaw (in rec's frame), x, y, z (body ground point), up, fwd,
--          anchor = the part snapped to }
function snap(q)
  local def, P, U = q.def, q.P, q.U
  local yawOff = q.yawOff or 0
  local defs = q.defs
  local function joined(mode, rec, fr, lx, ly, lz, yaw, anchor)
    local x, y, z = toBody(fr, lx, ly, lz)
    return { mode = mode, rec = rec, lx = lx, ly = ly, lz = lz, yaw = yaw, x = x, y = y, z = z,
             up = V(fr.U.x, fr.U.y, fr.U.z), fwd = yawDir(fr, yaw), anchor = anchor }
  end
  -- EDGE: the free slot nearest the cursor beside a part of the same tile
  if def.tile and not q.free then
    local cands = {}
    if q.hit then cands[#cands + 1] = q.hit end
    for _, e in ipairs(q.near or {}) do cands[#cands + 1] = e end
    local best = nil
    local seen = {}
    for _, e in ipairs(cands) do
      local pd = e.part and defs(e.part.id)
      local key = e.rec and e.part and (tostring(e.rec.id) .. ":" .. tostring(e.part.uid))
      if pd and pd.tile == def.tile and key and not seen[key] then
        seen[key] = true
        local fr = frameOf(e.rec)
        local lx, _, lz = toLocal(fr, P.x, P.y, P.z)
        local p = e.part
        local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
        for _, ax in ipairs({ { c, -s }, { -c, s }, { s, c }, { -s, -c } }) do
          local sx, sz = p.x + ax[1] * def.tile, p.z + ax[2] * def.tile
          local dd = math.sqrt((lx - sx) ^ 2 + (lz - sz) ^ 2)
          if dd < def.tile * EDGE_CAPTURE and (not best or dd < best.dd)
             and not slotTaken(e.rec, defs, def.tile, sx, p.y or 0, sz) then
            best = { dd = dd, rec = e.rec, fr = fr, x = sx, z = sz, y = p.y or 0, yaw = p.yaw or 0, part = p }
          end
        end
      end
    end
    if best then return joined("edge", best.rec, best.fr, best.x, best.y, best.z, best.yaw, best.part) end
  end
  -- DECK: on the top of the part the ray stopped on
  if def.onDeck and q.hit and q.hit.part then
    local hd = defs(q.hit.part.id)
    if hd and hd.deck then
      local rec = q.hit.rec
      local fr = frameOf(rec)
      local lx, _, lz = toLocal(fr, P.x, P.y, P.z)
      local top = (q.hit.part.y or 0) + hd.deck
      local a = yawOf(fr, q.toward)
      if not q.free then lx, lz, a = quantize(lx, GRID), quantize(lz, GRID), quantize(a, QUARTER) end
      return joined("deck", rec, fr, lx, top, lz, wrap(a + yawOff), q.hit.part)
    end
  end
  -- GROUND NEAR A STRUCTURE (playtest 11-09: "not always snapping together
  -- cleanly, sometimes things are rotated a bit off"): within JOIN_R of a
  -- placed part the new part JOINS that structure, laid in its frame — its
  -- up, its 0.5 m grid, quarter turns square to it — at the ground's height
  -- there (the foundation adds the cut and fill). A new structure of its own
  -- would stand on the radial up a few metres on, tilted against its
  -- neighbour by the world's curvature (0.7° at 10 m on a 775 m world), and
  -- its pieces could never hold each other up.
  if not q.free then
    local e = (q.near or {})[1]
    if e and e.rec and (e.d or 0) <= JOIN_R then
      local fr = frameOf(e.rec)
      local lx, ly, lz = toLocal(fr, P.x, P.y, P.z)
      lx, lz = quantize(lx, GRID), quantize(lz, GRID)
      local a = quantize(yawOf(fr, q.toward), QUARTER)
      local pz = joined("grid", e.rec, fr, lx, ly, lz, wrap(a + yawOff), nil)
      pz.join = true
      return pz
    end
  end
  -- GROUND: a new structure, on the grid of the nearest one (or the layout's)
  local ref = nil
  if not q.free then
    for _, e in ipairs(q.near or {}) do
      if e.rec and (e.d or 0) <= NEAR_R then ref = frameOf(e.rec) break end
    end
    ref = ref or q.ref
  end
  local px, py, pz = P.x, P.y, P.z
  local fx, fy, fz
  if ref then
    local lx, _, lz = toLocal(ref, px, py, pz)
    local dx, dz = quantize(lx, GRID) - lx, quantize(lz, GRID) - lz
    local mx = ref.R.x * dx + ref.F.x * dz
    local my = ref.R.y * dx + ref.F.y * dz
    local mz = ref.R.z * dx + ref.F.z * dz
    local du = mx * U.x + my * U.y + mz * U.z
    px, py, pz = px + mx - U.x * du, py + my - U.y * du, pz + mz - U.z * du
    local a = quantize(yawOf(ref, q.toward), QUARTER)
    local d = yawDir(ref, a)
    fx, fy, fz = d.x, d.y, d.z
  else
    fx, fy, fz = q.toward.x, q.toward.y, q.toward.z
  end
  local d = fx * U.x + fy * U.y + fz * U.z
  fx, fy, fz = fx - U.x * d, fy - U.y * d, fz - U.z * d
  local _, _, _, l = norm(fx, fy, fz)
  if l < 1e-4 then fx, fy, fz = 1 - U.x * U.x, -U.x * U.y, -U.x * U.z end
  fx, fy, fz = norm(fx, fy, fz)
  if yawOff ~= 0 then
    local rx, ry, rz = U.y * fz - U.z * fy, U.z * fx - U.x * fz, U.x * fy - U.y * fx
    local c, s = math.cos(yawOff), math.sin(yawOff)
    fx, fy, fz = fx * c + rx * s, fy * c + ry * s, fz * c + rz * s
  end
  return { mode = q.free and "free" or "grid", rec = nil, x = px, y = py, z = pz, up = V(U.x, U.y, U.z),
           fwd = V(fx, fy, fz), lx = 0, ly = 0, lz = 0, yaw = 0 }
end

-- ── the ground under it (K7) ────────────────────────────────────────────────

-- heights = the ground at footPoints, m along up from the pose's ground point
-- (+ above). fixed = the base the part must sit at (a joined structure's
-- level) or nil; raise = the stilts dialled (m). → plan { ok, why, base,
-- spread, cut, fill, footing = { d, hx, hz } | nil, vol (m³), level = bool }
function foundation(def, heights, fixed, raise)
  local n, sum, lo, hi = 0, 0, math.huge, -math.huge
  for _, h in ipairs(heights) do
    if h then n = n + 1; sum = sum + h; lo = math.min(lo, h); hi = math.max(hi, h) end
  end
  if n < math.max(3, math.floor(#heights * 0.6)) then return { ok = false, why = "no ground under most of it" } end
  local base = fixed or (sum / n + (raise or 0))
  local cut, fill = math.max(0, hi - base), math.max(0, base - lo)
  local plan = { ok = true, base = base, spread = hi - lo, cut = cut, fill = fill, lo = lo, hi = hi }
  local g = def.grade or 1.5
  if cut > g + 1e-6 or fill > g + (raise or 0) + 1e-6 then
    plan.ok = false
    plan.why = string.format("the ground %s %.1f m %s it (%.1f m at most)", cut >= fill and "rises" or "falls",
      math.max(cut, fill), cut >= fill and "into" or "under", g)
    return plan
  end
  plan.level = (hi - lo) > 0.04 or math.abs(base - sum / n) > 0.04
  local from = math.max(FOOTING_FROM, def.skirt or 0)
  if fill > from then
    local pad = def.footPad or 0.15
    local d = fill + FOOTING_KEY
    plan.footing = { d = d, hx = def.half.x + pad, hz = def.half.z + pad }
    plan.vol = (2 * plan.footing.hx) * (2 * plan.footing.hz) * d
  else
    plan.vol = 0
  end
  return plan
end

-- The flatten discs that level a footprint: centres in the part's own (x, z)
-- and one radius, covering it and FOOTING_KEY round it. → { {x, z} … }, r
function gradeDiscs(def)
  local w, d = 2 * def.half.x + 0.6, 2 * def.half.z + 0.6
  local nx, nz = math.max(1, math.ceil(w / 2.6)), math.max(1, math.ceil(d / 2.6))
  local cw, cd = w / nx, d / nz
  local out = {}
  for i = 1, nx do
    for j = 1, nz do out[#out + 1] = { x = -w / 2 + cw * (i - 0.5), z = -d / 2 + cd * (j - 0.5) } end
  end
  return out, math.sqrt((cw / 2) ^ 2 + (cd / 2) ^ 2) + 0.6
end
