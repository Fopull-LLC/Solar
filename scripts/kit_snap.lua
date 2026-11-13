-- KIT_SNAP — where a modular kit piece in the Engineer's hand goes, and the
-- kit's record rules: overlap, support, what comes down with a piece
-- (sandbox plan S1 §1.2, §1.4; docs/base-building.md §13).
--
-- A pure RULEBOOK on the Build Kit node beside base_snap.lua (which keeps the
-- step-5 edge / deck / grid / free rules): no scene access, its globals are
-- its API, it loads from disk in a luajit test (tests/smoke_kit.lua).
-- field_builder.pose asks `face` first with a kit piece in hand; nil means
-- the old rules apply (the ground, a slab's edge, Shift's free).
-- Everything is in a STRUCTURE's frame (structures.lua: +X right, +Y up, +Z
-- front at its founding ground point) or its body's (docs/positions-and-
-- frames.md rule 1); nothing here is a world point.
--
-- ── FACE: the hit face and point pick the adjoining place ───────────────────
-- In the HIT PART's frame (its yaw), on a 0.5 m grid from its own edges. By
-- the piece's `snap` class (parts_kit.lua):
--   wall   on a floor/slab top: along its nearest edge (centred on the edge
--          line, its outside out) within EDGE_NEAR, else across it at the
--          cursor (a partition); on a wall's end: the line continued; on its
--          top: stacked; on its face: square off it
--   floor  beside a floor/slab: level with it; on a top: laid on it; on a
--          wall: on the wall's top, its edge on the wall's centre line, out
--          over the side you face (the top face: away from you — a roof from
--          outside); a pitched panel rises away from that wall
--   post   on a top: on the nearest corner (within CORNER_NEAR) or the grid;
--          on a post: stacked; on a wall's end: a corner post
--   block  on a top: on the grid, square toward you; beside one of its kind
--   mount  flush on the face hit, facing out of it (pitch 90° on a wall, 180°
--          under a ceiling), on a 0.25 m grid in that face
--   hab    on a can's end: the next ring (a cap or bulkhead turned to face
--          out); a segment on a segment's side: a branch, its end on the
--          side's middle (the host turns into a junction: HAB JOINS below);
--          on a top: on the grid, square toward you
--
-- ── SUPPORT (Career; Creative skips it) ─────────────────────────────────────
-- A piece is held if a chain of pieces it touches reaches the structure's
-- ground (supportMap below): resting on a top passes the hold on as it is,
-- touching side to side or hanging under adds one module of reach, and a
-- floor may reach MAX_HANG modules (4 m) from what holds it. A mount is held
-- by its face. No stress sim: a check on the records, run on a placement.
-- `fallsWith(rec, uids)` is what is no longer held once uids are gone: what a
-- Deconstruct takes down with the piece.

GRID = 0.5
QUARTER = math.pi / 2
EDGE_NEAR = 0.6
CORNER_NEAR = 0.5
MOUNT_GRID = 0.25

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function V(x, y, z) return { x = x, y = y, z = z } end
local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end
function quantize(a, step) return math.floor(a / step + 0.5) * step end
function wrap(a) a = (a + math.pi) % (2 * math.pi); return a - math.pi end
local function sgn(v) return v >= 0 and 1 or -1 end

-- a structure's frame { O, U, F, R } (structures.frame / base_snap.frameOf)
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
local function toLocal(fr, x, y, z)
  local d = V(x - fr.O.x, y - fr.O.y, z - fr.O.z)
  return dot(d, fr.R), dot(d, fr.U), dot(d, fr.F)
end
local function toBody(fr, lx, ly, lz)
  return fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz,
         fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
         fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
end

-- up and front of yaw, pitch, roll in a structure frame (structures.localAxes)
function localAxes(yaw, pitch, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local cr, sr = math.cos(roll), math.sin(roll)
  local function ry(v) return { cy * v[1] + sy * v[3], v[2], -sy * v[1] + cy * v[3] } end
  return ry({ -sr, cr * cp, cr * sp }), ry({ 0, -sp, cp })
end

-- A part's nominal solid in its own frame { x0, x1, y0, y1, z0, z1 }: a kit
-- piece's `box`; another part's from its footprint (a deck part's top is its deck).
function boxOf(d)
  if d.box then return d.box end
  local h = d.half or { x = 0.5, y = 0.5, z = 0.5 }
  if d.deck then return { -h.x, h.x, d.deck - 2 * h.y, d.deck, -h.z, h.z } end
  return { -h.x, h.x, 0, 2 * h.y, -h.z, h.z }
end
function classOf(d)
  if d.snap then return d.snap end
  if d.deck then return "slab" end
  return "block"
end
local function cq(v, lo, hi)
  if lo > hi + 1e-9 then return (lo + hi) / 2 end
  return math.max(lo, math.min(hi, quantize(v, GRID)))
end

-- ── S6: PORTS (a pipe, a pump, a steam generator: parts_kit `ports`) ───────
-- A piece with ports aimed at a piece with ports goes nozzle to nozzle: on
-- the hit piece's free port nearest the cursor, the held piece's port k (R
-- steps k: which end of a pipe, which way an elbow turns) on it, facing it.
-- All ports are at PIPE_Y over their piece's ground point, so the pieces
-- stand on one floor. reactor.lua's port graph reads the same positions.
PIPE_Y = 0.6
local function prot(yaw, x, z)
  local c, s = math.cos(yaw or 0), math.sin(yaw or 0)
  return x * c + z * s, -x * s + z * c
end
function portPose(p, pt)
  local dx, dz = prot(p.yaw, pt.x, pt.z)
  local nx, nz = prot(p.yaw, pt.nx, pt.nz)
  return (p.x or 0) + dx, (p.y or 0) + (pt.y or PIPE_Y), (p.z or 0) + dz, nx, nz
end
-- (S7) a port's bore: the reactor's DN100 coolant nozzles meet only DN100,
-- the fluid network's DN25 process line only DN25
function boreOf(def, pt)
  return pt.bore or ((def and def.fl) and (def.fl.bore or "DN25")) or (pt.fluid and "DN25") or "DN100"
end
-- Is there a port of `rec` at (x, y, z) facing (nx, nz)'s opposite (already joined)?
local function port_taken(rec, defs, skipUid, x, y, z, nx, nz)
  for _, p in ipairs(rec.bp or {}) do
    if p.uid ~= skipUid then
      local d = defs(p.id)
      if d and d.ports then
        for _, pt in ipairs(d.ports) do
          local px, py, pz, qx, qz = portPose(p, pt)
          if math.abs(px - x) < 0.06 and math.abs(pz - z) < 0.06 and math.abs(py - y) < 0.06 and qx * nx + qz * nz < -0.9 then return true end
        end
      end
    end
  end
  return false
end
-- → a face() pose on the nearest free port, or nil
function portSnap(q, fr, part, hd, hx, hy, hz)
  local def, rec = q.def, q.hit.rec
  local best, bd = nil, 1.6
  local n = #def.ports
  local k = (math.floor((q.yawOff or 0) / QUARTER + 0.5) % n) + 1
  local hp = def.ports[k]
  local hb = boreOf(def, hp)
  for _, pt in ipairs(hd.ports) do
    local x, y, z, nx, nz = portPose(part, pt)
    if boreOf(hd, pt) ~= hb then x = 1e9 end
    local d = math.sqrt((x - hx) ^ 2 + (y - hy) ^ 2 + (z - hz) ^ 2)
    if d < bd and not port_taken(rec, q.defs, part.uid, x, y, z, nx, nz) then best, bd = { x = x, y = y, z = z, nx = nx, nz = nz, name = pt.name }, d end
  end
  if not best then return nil end
  -- the yaw that turns the held port's direction onto the hit port's opposite
  local yaw = quantize(wrap(math.atan2(-best.nx, -best.nz) - math.atan2(hp.nx, hp.nz)), QUARTER)
  local ox, oz = prot(yaw, hp.x, hp.z)
  local lx, ly, lz = best.x - ox, best.y - (hp.y or PIPE_Y), best.z - oz
  local x, y, z = toBody(fr, lx, ly, lz)
  local lu, lf = localAxes(yaw, 0, 0)
  local function bodyv(v) return V(fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                                   fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3]) end
  return { mode = "face", rec = rec, lx = lx, ly = ly, lz = lz, yaw = wrap(yaw), pitch = 0, roll = 0,
           x = x, y = y, z = z, up = bodyv(lu), fwd = bodyv(lf), anchor = part, face = "port", port = best.name, portK = k }
end

-- q = { def (in hand), P, N (body-relative hit point and its normal),
--       toward (body frame, toward the Engineer), hit = { rec, part },
--       defs = fn(id) → def, yawOff }
-- → pose { mode = "face", rec, lx, ly, lz, yaw, pitch, roll, x, y, z (body
--          ground point), up, fwd (the piece's axes, body frame), anchor,
--          face = "y+" … } | nil
function face(q)
  local def, defs = q.def, q.defs
  local hit = q.hit
  if not (def and def.kit and hit and hit.part and hit.rec and q.N and q.P) then return nil end
  local hd = defs(hit.part.id)
  if not hd then return nil end
  local S, H = classOf(def), classOf(hd)
  local rec, part = hit.rec, hit.part
  local fr = frameOf(rec)
  local hx, hy, hz = toLocal(fr, q.P.x, q.P.y, q.P.z)
  -- (S6) nozzle to nozzle first
  if def.ports and hd.ports and math.abs(part.pitch or 0) < 1e-3 then
    local pp = portSnap(q, fr, part, hd, hx, hy, hz)
    if pp then return pp end
  end
  local nx, ny, nz = dot(q.N, fr.R), dot(q.N, fr.U), dot(q.N, fr.F)
  local tw = q.toward or V(0, 0, 1)
  local tx, tz = dot(tw, fr.R), dot(tw, fr.F)
  local yaw0 = part.yaw or 0
  local c, s = math.cos(yaw0), math.sin(yaw0)
  -- into the hit part's frame (its yaw; its pitch is a mount's, never snapped to)
  local dx, dz = hx - (part.x or 0), hz - (part.z or 0)
  local px, pz, py = dx * c - dz * s, dx * s + dz * c, hy - (part.y or 0)
  local pnx, pnz = nx * c - nz * s, nx * s + nz * c
  local ptx, ptz = tx * c - tz * s, tx * s + tz * c
  local hb = boxOf(hd)
  local ax, an
  if math.abs(ny) >= math.abs(pnx) and math.abs(ny) >= math.abs(pnz) then ax, an = "y", sgn(ny)
  elseif math.abs(pnx) >= math.abs(pnz) then ax, an = "x", sgn(pnx)
  else ax, an = "z", sgn(pnz) end
  if H == "mount" and S ~= "mount" then return nil end
  local nb = boxOf(def)
  local cx, cy, cz, dyaw, pitch = nil, nil, nil, 0, 0
  local top = hb[4]
  local function toward_yaw() return quantize(math.atan2(ptx, ptz), QUARTER) end
  if S == "mount" then
    local g = MOUNT_GRID
    if ax == "y" then
      cy = an > 0 and hb[4] or hb[3]
      cx, cz = quantize(px, g), quantize(pz, g)
      pitch = an > 0 and 0 or math.pi
    else
      pitch = QUARTER
      if ax == "z" then
        cz = an > 0 and hb[6] or hb[5]
        cx, cy = quantize(px, g), quantize(py, g)
        dyaw = an > 0 and 0 or math.pi
      else
        cx = an > 0 and hb[2] or hb[1]
        cz, cy = quantize(pz, g), quantize(py, g)
        dyaw = an > 0 and QUARTER or -QUARTER
      end
    end
  elseif S == "wall" then
    local whx = (nb[2] - nb[1]) / 2
    if ax == "y" and an > 0 and (H == "floor" or H == "slab" or H == "block") then
      cy = hd.deckTop or top
      local e = { { hb[2] - px, "x", 1 }, { px - hb[1], "x", -1 }, { hb[6] - pz, "z", 1 }, { pz - hb[5], "z", -1 } }
      table.sort(e, function(a, b) return a[1] < b[1] end)
      if e[1][1] <= EDGE_NEAR then
        local which, side = e[1][2], e[1][3]
        if which == "z" then
          cz = side > 0 and hb[6] or hb[5]
          cx = cq(px, hb[1] + whx, hb[2] - whx)
          dyaw = side > 0 and 0 or math.pi
        else
          cx = side > 0 and hb[2] or hb[1]
          cz = cq(pz, hb[5] + whx, hb[6] - whx)
          dyaw = side > 0 and QUARTER or -QUARTER
        end
      else
        cx, cz = quantize(px, GRID), quantize(pz, GRID)
        dyaw = toward_yaw()
      end
    elseif H == "wall" then
      if ax == "x" then
        cx = an > 0 and (hb[2] + whx) or (hb[1] - whx)
        cy, cz = 0, 0
      elseif ax == "y" and an > 0 then
        cy = top
        cx = cq(px, hb[1] + whx, hb[2] - whx)
        cz = 0
      elseif ax == "z" then
        cy = 0
        cz = an > 0 and (hb[6] + whx) or (hb[5] - whx)
        cx = cq(px, hb[1] + 0.1, hb[2] - 0.1)
        dyaw = QUARTER
      end
    end
  elseif S == "floor" then
    local fhx, fhz, fh = (nb[2] - nb[1]) / 2, (nb[6] - nb[5]) / 2, nb[4] - nb[3]
    if (H == "floor" or H == "slab") and ax ~= "y" then
      local ftop = hd.deckTop or top
      cy = ftop - (def.deckTop or fh)
      if def.slopeZ then cy = ftop end
      if ax == "x" then
        cx = an > 0 and (hb[2] + fhx) or (hb[1] - fhx)
        cz = cq(pz, hb[5] + fhz, hb[6] - fhz)
      else
        cz = an > 0 and (hb[6] + fhz) or (hb[5] - fhz)
        cx = cq(px, hb[1] + fhx, hb[2] - fhx)
      end
    elseif ax == "y" and an > 0 and (H == "floor" or H == "slab" or H == "block" or H == "hab") then
      cy = hd.deckTop or top
      cx = cq(px, hb[1] + fhx, hb[2] - fhx)
      cz = cq(pz, hb[5] + fhz, hb[6] - fhz)
    elseif H == "wall" then
      cy = top
      local side
      if ax == "z" then side = an else side = -sgn(ptz) end
      cx = cq(px, hb[1] + fhx, hb[2] - fhx)
      cz = side * fhz
      if def.slopeZ then dyaw = side > 0 and math.pi or 0 end
    elseif H == "post" and ax == "y" and an > 0 then
      cy = top
      cx, cz = -sgn(ptx) * fhx, -sgn(ptz) * fhz
    end
  elseif S == "post" then
    local phx = (nb[2] - nb[1]) / 2
    if ax == "y" and an > 0 then
      cy = hd.deckTop or top
      if H == "post" then cx, cz = 0, 0
      else
        local kx = math.abs(px - hb[1]) < math.abs(px - hb[2]) and hb[1] or hb[2]
        local kz = math.abs(pz - hb[5]) < math.abs(pz - hb[6]) and hb[5] or hb[6]
        if math.abs(px - kx) <= CORNER_NEAR and math.abs(pz - kz) <= CORNER_NEAR and H ~= "hab" then cx, cz = kx, kz
        else cx, cz = quantize(px, GRID), quantize(pz, GRID) end
      end
    elseif H == "wall" and ax == "x" then
      cx = an > 0 and (hb[2] + phx) or (hb[1] - phx)
      cy, cz = 0, 0
    end
  elseif S == "block" or S == "prop" or S == "pipe" then
    -- (S4: a prop is a block on a finer grid: a monitor on a desk, a crate in a corner)
    local g = S == "prop" and MOUNT_GRID or GRID
    if ax == "y" and an > 0 then
      cy = hd.deckTop or top
      cx, cz = quantize(px, g), quantize(pz, g)
      dyaw = toward_yaw()
    elseif hit.part.id == q.id and ax ~= "y" then
      if ax == "x" then cx = an > 0 and (hb[2] + (nb[2] - nb[1]) / 2) or (hb[1] - (nb[2] - nb[1]) / 2); cz = 0
      else cz = an > 0 and (hb[6] + (nb[6] - nb[5]) / 2) or (hb[5] - (nb[6] - nb[5]) / 2); cx = 0 end
      cy = 0
    end
  elseif S == "hab" then
    if H == "hab" and ax == "z" then
      cy, cx = 0, 0
      if an > 0 then dyaw = 0; cz = hb[6] - nb[5] else dyaw = math.pi; cz = hb[5] + nb[5] end
    elseif H == "hab" and ax == "x" and def.join and hd.join then
      -- (Ty 11-10) a segment against a segment's side: a branch, its end on
      -- the side's middle; the host becomes the T, the cross or the corner
      -- (habShapes below)
      cy, cz = 0, 0
      cx = an > 0 and (hb[2] - nb[5]) or (hb[1] + nb[5])
      dyaw = an > 0 and QUARTER or -QUARTER
    elseif ax == "y" and an > 0 and (H == "floor" or H == "slab" or H == "block") then
      cy = top
      cx, cz = quantize(px, GRID), quantize(pz, GRID)
      dyaw = toward_yaw()
    end
  end
  if cx == nil then return nil end
  local lx = (part.x or 0) + cx * c + cz * s
  local lz = (part.z or 0) - cx * s + cz * c
  local ly = (part.y or 0) + cy
  -- (playtest 11-09: "sometimes things are rotated a bit off". A joined
  -- piece turns only in quarter turns with its neighbour, so the wheel's 15°
  -- or 5° can't leave a wall a few degrees off its edge; a block or a prop on
  -- a top keeps the wheel's clean 15° steps.)
  local yo = q.yawOff or 0
  if S == "block" or S == "prop" then yo = quantize(yo, math.rad(15)) else yo = quantize(yo, QUARTER) end
  local yaw = wrap(yaw0 + dyaw + yo)
  local x, y, z = toBody(fr, lx, ly, lz)
  local lu, lf = localAxes(yaw, pitch, 0)
  local function bodyv(v) return V(fr.R.x * v[1] + fr.U.x * v[2] + fr.F.x * v[3], fr.R.y * v[1] + fr.U.y * v[2] + fr.F.y * v[3],
                                   fr.R.z * v[1] + fr.U.z * v[2] + fr.F.z * v[3]) end
  return { mode = "face", rec = rec, lx = lx, ly = ly, lz = lz, yaw = yaw, pitch = pitch, roll = 0,
           x = x, y = y, z = z, up = bodyv(lu), fwd = bodyv(lf), anchor = part, face = ax .. (an > 0 and "+" or "-") }
end

-- ── VACANT SLOTS (playtest 11-12b: "replacing one wall comes out misaligned
-- … you have to tear down and rebuild several walls") ────────────────────────
-- face() snaps to the piece under the cursor. Where a wall or a roof panel is
-- MISSING there is nothing under the cursor but the ground beyond the gap, or
-- the sky. A slot is the place a missing piece belongs, worked out from what
-- still stands, on the same edge lines and wall tops face() uses:
--   wall   a floor's or slab's edge with no wall on it, that an existing wall
--          ends at (a line to continue, a corner to close)
--   floor  the cell beside a wall's top, or beside a roof panel, with a floor
--          below it and no panel in it (a roof to close)
-- field_builder takes the slot the aim ray passes nearest. A leaning piece
-- (a ruin's) counts where it stands: its x, z and yaw are its grid pose.
-- → { { kind, lx, ly, lz, yaw, cx, cy, cz (its middle: what the ray is
--       measured to), anchor (the part it hangs on) } … }
SLOT_RAY_R = 0.9
local function near2(ax, az, bx, bz, r) return (ax - bx) ^ 2 + (az - bz) ^ 2 <= r * r end
function slots(rec, defs, def)
  local out = {}
  if not (rec and def and def.kit) then return out end
  local S = classOf(def)
  if S ~= "wall" and S ~= "floor" then return out end
  local nb = boxOf(def)
  local walls, floors = {}, {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d then
      local c = classOf(d)
      local b = boxOf(d)
      local yaw = p.yaw or 0
      if c == "wall" and d.kit then
        walls[#walls + 1] = { p = p, x = p.x or 0, y = p.y or 0, z = p.z or 0, yaw = yaw, hx = (b[2] - b[1]) / 2, top = (p.y or 0) + b[4],
                              c = math.cos(yaw), s = math.sin(yaw) }
      elseif (c == "floor" or c == "slab") and math.abs(p.pitch or 0) < 1e-3 and math.abs(p.roll or 0) < 1e-3 and not d.slopeZ then
        floors[#floors + 1] = { p = p, d = d, b = b, x = p.x or 0, y = p.y or 0, z = p.z or 0, yaw = yaw, top = (p.y or 0) + (d.deckTop or b[4]),
                                c = math.cos(yaw), s = math.sin(yaw) }
      end
    end
  end
  local seen = {}
  local function add(e)
    local k = string.format("%s|%.1f|%.1f|%.1f", e.kind, e.lx, e.ly, e.lz)
    if not seen[k] then seen[k] = true; out[#out + 1] = e end
  end
  -- is (x, z) inside floor f's footprint (its own frame)?
  local function over(f, x, z, pad)
    local dx, dz = x - f.x, z - f.z
    local px, pz = dx * f.c - dz * f.s, dx * f.s + dz * f.c
    pad = pad or 0
    return px >= f.b[1] - pad and px <= f.b[2] + pad and pz >= f.b[5] - pad and pz <= f.b[6] + pad
  end
  if S == "wall" then
    local whx, wh = (nb[2] - nb[1]) / 2, nb[4] - nb[3]
    -- a wall's two ends (structure frame)
    local function ends(x, z, c, s, hx) return x + hx * c, z - hx * s, x - hx * c, z + hx * s end
    for _, f in ipairs(floors) do
      local b = f.b
      local E = { { "z", 1, b[6], b[1], b[2], 0 }, { "z", -1, b[5], b[1], b[2], math.pi }, { "x", 1, b[2], b[5], b[6], QUARTER }, { "x", -1, b[1], b[5], b[6], -QUARTER } }
      for _, e in ipairs(E) do
        local L = e[5] - e[4]
        local n = math.floor(L / (2 * whx) + 1e-6)
        for k = 1, n do
          local t = e[4] + whx + (k - 1) * 2 * whx + (L - n * 2 * whx) / 2
          local ex, ez
          if e[1] == "z" then ex, ez = t, e[3] else ex, ez = e[3], t end
          local lx = f.x + ex * f.c + ez * f.s
          local lz = f.z - ex * f.s + ez * f.c
          local yaw = wrap(f.yaw + e[6])
          local yc, ys = math.cos(yaw), math.sin(yaw)
          local vacant, wanted = true, false
          local ax, az, bx, bz = ends(lx, lz, yc, ys, whx)
          for _, w in ipairs(walls) do
            if math.abs(w.y - f.top) < 0.3 then
              -- on this slot already: its centre here, or a wider wall's line over it
              local dx, dz = lx - w.x, lz - w.z
              local along, across = dx * w.c - dz * w.s, dx * w.s + dz * w.c
              if math.abs(across) < 0.3 and math.abs(along) <= math.max(0.3, w.hx - 0.1) then vacant = false break end
              local wax, waz, wbx, wbz = ends(w.x, w.z, w.c, w.s, w.hx)
              if near2(ax, az, wax, waz, 0.35) or near2(ax, az, wbx, wbz, 0.35) or near2(bx, bz, wax, waz, 0.35) or near2(bx, bz, wbx, wbz, 0.35) then wanted = true end
            end
          end
          if vacant and wanted then
            add({ kind = "wall", lx = lx, ly = f.top, lz = lz, yaw = yaw, cx = lx, cy = f.top + wh / 2, cz = lz, anchor = f.p })
          end
        end
      end
    end
  else
    local fhx, fhz = (nb[2] - nb[1]) / 2, (nb[6] - nb[5]) / 2
    local function free(lx, ly, lz)
      for _, f in ipairs(floors) do
        if math.abs(f.y - ly) < 0.3 and math.abs(f.x - lx) < 0.3 and math.abs(f.z - lz) < 0.3 then return false end
      end
      return true
    end
    -- a floor at least a metre below the cell's middle: it roofs something
    local function roofs(lx, ly, lz)
      for _, f in ipairs(floors) do if f.top < ly - 1.0 and over(f, lx, lz, 0.05) then return true end end
      return false
    end
    for _, w in ipairs(walls) do
      for _, side in ipairs({ 1, -1 }) do
        local cz = side * fhz
        local lx, lz = w.x + cz * w.s, w.z + cz * w.c
        if free(lx, w.top, lz) and roofs(lx, w.top, lz) then
          add({ kind = "floor", lx = lx, ly = w.top, lz = lz, yaw = w.yaw, cx = lx, cy = w.top, cz = lz, anchor = w.p })
        end
      end
    end
    for _, f in ipairs(floors) do
      if roofs(f.x, f.y, f.z) then
        for _, o in ipairs({ { 2 * fhx, 0 }, { -2 * fhx, 0 }, { 0, 2 * fhz }, { 0, -2 * fhz } }) do
          local lx, lz = f.x + o[1] * f.c + o[2] * f.s, f.z - o[1] * f.s + o[2] * f.c
          if free(lx, f.y, lz) and roofs(lx, f.y, lz) then
            add({ kind = "floor", lx = lx, ly = f.y, lz = lz, yaw = f.yaw, cx = lx, cy = f.y, cz = lz, anchor = f.p })
          end
        end
      end
    end
  end
  return out
end
-- The slot the ray (O + t·D, structure frame, D a unit vector) passes nearest,
-- within `R` m of its middle and no further along than `tmax`. → slot, t, dist
function slotOnRay(list, O, D, tmax, R)
  local best, bt, bd = nil, nil, R or SLOT_RAY_R
  for _, e in ipairs(list or {}) do
    local vx, vy, vz = e.cx - O.x, e.cy - O.y, e.cz - O.z
    local t = vx * D.x + vy * D.y + vz * D.z
    if t > 0.4 and t <= (tmax or 1e9) then
      local px, py, pz = vx - D.x * t, vy - D.y * t, vz - D.z * t
      local d = math.sqrt(px * px + py * py + pz * pz)
      if d < bd then best, bt, bd = e, t, d end
    end
  end
  return best, bt, bd
end
-- A ray into a structure's frame (body-relative origin and direction).
function rayLocal(rec, ox, oy, oz, dx, dy, dz)
  local fr = frameOf(rec)
  local lx, ly, lz = toLocal(fr, ox, oy, oz)
  return { x = lx, y = ly, z = lz }, { x = dx * fr.R.x + dy * fr.R.y + dz * fr.R.z, y = dx * fr.U.x + dy * fr.U.y + dz * fr.U.z, z = dx * fr.F.x + dy * fr.F.y + dz * fr.F.z }
end

-- ── the records rules ───────────────────────────────────────────────────────

-- A part's solid in its structure's frame { x, z, hx, hz, yaw, y0, y1 }.
-- A mount on a wall (pitch 90°) stands its face's height along up and its
-- depth along its facing; under a ceiling (180°) it hangs down.
function solid(p, d)
  local b = boxOf(d)
  local pitch = p.pitch or 0
  local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  local cxl, czl = (b[1] + b[2]) / 2, (b[5] + b[6]) / 2
  local x = (p.x or 0) + cxl * c + czl * s
  local z = (p.z or 0) - cxl * s + czl * c
  local y0, y1 = (p.y or 0) + b[3], (p.y or 0) + b[4]
  local hx, hz = (b[2] - b[1]) / 2, (b[6] - b[5]) / 2
  if d.live then pitch = 0 end   -- (a live part's box is already as it lies: a cockpit on its belly)
  if math.abs(pitch) > 1e-3 and d.snap ~= "mount" then
    -- (a piece turned a quarter about its X — a truss laid down: Rx(+90°)
    -- takes y to z and z to -y; the half-turn stands it on its head)
    local s1 = math.sin(pitch)
    local y0, y1, z0, z1 = b[3], b[4], b[5], b[6]
    local ny0, ny1, nz0, nz1
    if math.abs(s1) > 0.7 then
      if s1 > 0 then ny0, ny1, nz0, nz1 = -z1, -z0, y0, y1 else ny0, ny1, nz0, nz1 = z0, z1, -y1, -y0 end
    else ny0, ny1, nz0, nz1 = -y1, -y0, -z1, -z0 end
    local cz2 = (nz0 + nz1) / 2
    return { x = (p.x or 0) + cxl * c + cz2 * s, z = (p.z or 0) - cxl * s + cz2 * c, hx = hx, hz = (nz1 - nz0) / 2,
             yaw = p.yaw or 0, y0 = (p.y or 0) + ny0, y1 = (p.y or 0) + ny1 }
  end
  if math.abs(pitch) > 1e-3 then
    local depth = b[4] - b[3]
    if math.abs(math.abs(pitch) - math.pi) < 1e-3 then
      y0, y1 = (p.y or 0) - depth, (p.y or 0)
    else
      x, z = (p.x or 0) + s * depth / 2, (p.z or 0) + c * depth / 2
      y0, y1 = (p.y or 0) - hz, (p.y or 0) + hz
      hz = depth / 2
    end
  end
  return { x = x, z = z, hx = hx, hz = hz, yaw = p.yaw or 0, y0 = y0, y1 = y1 }
end

-- Do two yawed rectangles overlap by more than `m` (m)? (separating axes)
-- (no tables made: the support graph asks this tens of thousands of times,
-- and a menu's "what falls with it" with it — Ty 11-11, a part's menu at 1 fps)
local abs, cos, sin, min, max = math.abs, math.cos, math.sin, math.min, math.max
-- r's extent along axis (ax, az); r's own axes are (c, -s) and (s, c)
local function apart(a, ca, sa, b, cb, sb, ax, az, m)
  local ea = abs(ca * ax - sa * az) * a.hx + abs(sa * ax + ca * az) * a.hz
  local eb = abs(cb * ax - sb * az) * b.hx + abs(sb * ax + cb * az) * b.hz
  local pa, pb = a.x * ax + a.z * az, b.x * ax + b.z * az
  return min(pa + ea, pb + eb) - max(pa - ea, pb - eb) <= m
end
function rectOverlap(a, b, m)
  local ca, sa = cos(a.yaw), sin(a.yaw)
  local cb, sb = cos(b.yaw), sin(b.yaw)
  if apart(a, ca, sa, b, cb, sb, ca, -sa, m) or apart(a, ca, sa, b, cb, sb, sa, ca, m)
     or apart(a, ca, sa, b, cb, sb, cb, -sb, m) or apart(a, ca, sa, b, cb, sb, sb, cb, m) then return false end
  return true
end

-- The part of `rec` the new part `np` (def `nd`) would be inside, or nil.
-- Mounts only meet mounts; everything else meets everything but mounts.
-- (Wall-to-wall corners share their end 0.1 m: the margin lets them.)
-- (S4: a film — a decal, grime — meets nothing: paint goes over paint.)
OVERLAP_M = 0.11
function overlapIn(rec, defs, np, nd, skip)
  if nd.film then return nil end
  local a = solid(np, nd)
  local am = nd.snap == "mount"
  for _, p in ipairs(rec.bp or {}) do
    if not (skip and skip[p.uid]) then
      local d = defs(p.id)
      if d and not d.film and ((d.snap == "mount") == am) then
        local b = solid(p, d)
        if math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > 0.03 and rectOverlap(a, b, OVERLAP_M) then return p, d end
      end
    end
  end
  return nil
end

-- ── SUPPORT AS A STRUCTURAL GRAPH (playtest 11-09: "floating floors aren't
-- allowed even when touching parts connected to the floor") ────────────────
-- Every piece of the structure is a node; two pieces are joined when their
-- solids touch:
--   ON     a rests on b's top (or a deck): a takes b's hang as it is
--   SIDE   they touch side to side (a floor beside a floor, a floor at a
--          wall's face, wall corners): either takes the other's hang + 1
--   UNDER  a hangs under b (a's top on b's bottom): a takes b's hang + 1
-- A piece on the structure's ground (y0 at its plane, or placed on the
-- terrain: `gnd`, a footing) has hang 0. A piece is HELD when its hang is at
-- most MAX_HANG: a floor, a slab, a hab ring or a laid beam may reach two
-- modules (4 m) from what holds it from below, so an 8 m room roofs over
-- without a pillar and a balcony stands 4 m out; a wall only stands ON
-- something or hangs under it (a panel bolted at one end over air is not a
-- wall). Mounts are held by their face and hold nothing. The hang is found by
-- a 0-1 breadth-first search from the grounded pieces, over a 2 m cell index
-- (no all-pairs scan), and kept per structure until its parts change.
MAX_HANG = 2
local SIDE_OK = { floor = true, slab = true, hab = true, post = true, block = true, prop = true, pipe = true }
local function grounded(p, a) return p.gnd == true or p.ft ~= nil or a.y0 <= 0.06 end
local function side_ok(p, d)
  local c = classOf(d)
  -- (a wall laid flat — pitched a quarter — is a deck panel, and a laid post a beam)
  if c == "wall" then return math.abs(p.pitch or 0) > 1e-3 or math.abs(p.roll or 0) > 1e-3 end
  return SIDE_OK[c] == true
end
-- How solid a (part p, def d) touches solid b (part q, def e):
-- "on" | "under" | "side" | nil
local function contact(p, a, q, b, e)
  if rectOverlap(a, b, 0.02) then
    if math.abs(a.y0 - b.y1) <= 0.06 or (e.deckTop and math.abs(a.y0 - ((q.y or 0) + e.deckTop)) <= 0.06) then return "on" end
    if math.abs(b.y0 - a.y1) <= 0.06 then return "under" end
    if math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > 0.03 then return "side" end
    return nil
  end
  if math.min(a.y1, b.y1) - math.max(a.y0, b.y0) > 0.03 then
    local grow = { x = a.x, z = a.z, hx = a.hx + 0.06, hz = a.hz + 0.06, yaw = a.yaw }
    if rectOverlap(grow, b, 0.0) then return "side" end
  end
  return nil
end
local CELL = 2.0
-- the graph's nodes: { p, d, a (solid), r (xz reach) } and a cell index
local function nodes_of(rec, defs, gone)
  local list, cells = {}, {}
  for _, p in ipairs(rec.bp or {}) do
    if not (gone and gone[p.uid]) then
      local d = defs(p.id)
      if d and d.snap ~= "mount" and not d.film then
        local a = solid(p, d)
        local n = { p = p, d = d, a = a, r = math.sqrt(a.hx * a.hx + a.hz * a.hz) + 0.1 }
        list[#list + 1] = n
        for i = math.floor((a.x - n.r) / CELL), math.floor((a.x + n.r) / CELL) do
          for k = math.floor((a.z - n.r) / CELL), math.floor((a.z + n.r) / CELL) do
            local key = i * 65536 + k
            local c = cells[key]
            if not c then c = {}; cells[key] = c end
            c[#c + 1] = n
          end
        end
      end
    end
  end
  return list, cells
end
local function near_nodes(cells, a, r, f)
  local seen = {}
  for i = math.floor((a.x - r) / CELL), math.floor((a.x + r) / CELL) do
    for k = math.floor((a.z - r) / CELL), math.floor((a.z + r) / CELL) do
      for _, n in ipairs(cells[i * 65536 + k] or {}) do
        if not seen[n] then seen[n] = true; f(n) end
      end
    end
  end
end
-- the weight of the link that gives node `n` support from `m` (nil: none)
local function weight(n, m)
  local k = contact(n.p, n.a, m.p, m.a, m.d)
  if k == "on" then return 0 end
  if k == "under" then return 1 end
  if k == "side" and side_ok(n.p, n.d) then return 1 end
  return nil
end
local map_cache = setmetatable({}, { __mode = "k" })
local function sig_of(rec)
  local n, s = 0, 0
  for _, p in ipairs(rec.bp or {}) do
    n = n + 1
    s = s + (p.uid or 0) * 7 + (p.x or 0) * 13 + (p.y or 0) * 17 + (p.z or 0) * 19 + (p.yaw or 0) * 23 + (p.pitch or 0) * 29
      + (p.gnd and 31 or 0) + #tostring(p.id or "")
  end
  return n .. ":" .. string.format("%.6f", s)
end
-- THE GRAPH, kept per structure until its parts change: the nodes, the cell
-- index and each node's links (who it holds, and how: `adj` = { n, w, … },
-- n taking m's hang + w), so asking with pieces taken away (`gone`: a
-- menu's "what falls with it", a demolition) is a walk over links, not the
-- geometry again. (Ty 11-11: a piece's menu asked it five times a refresh,
-- 50-250 ms each, and the game ran at 1 fps.)
local function graph_of(rec, defs)
  local sig = sig_of(rec)
  local c = map_cache[rec]
  if c and c.sig == sig then return c end
  local list, cells = nodes_of(rec, defs, nil)
  for _, m in ipairs(list) do
    local adj = {}
    local ma = m.a
    near_nodes(cells, ma, m.r + 0.2, function(n)
      -- (two pieces further apart than their reaches cannot touch)
      local dx, dz, rr = n.a.x - ma.x, n.a.z - ma.z, n.r + m.r
      if n ~= m and dx * dx + dz * dz <= rr * rr then
        local w = weight(n, m)
        if w then adj[#adj + 1] = n; adj[#adj + 1] = w end
      end
    end)
    m.adj = adj
  end
  local films = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.film and d.snap ~= "mount" then films[#films + 1] = { p = p, d = d } end
  end
  c = { sig = sig, list = list, cells = cells, films = films }
  map_cache[rec] = c
  return c
end
-- the 0-1 breadth-first search from the grounded pieces over the links,
-- skipping `gone` → uid → hang
local function hang_map(list, gone)
  local hang = {}
  local dq, head, tail = {}, 0, 0   -- a deque: 0-weight links in front
  for _, n in ipairs(list) do
    if not (gone and gone[n.p.uid]) and grounded(n.p, n.a) then hang[n] = 0; dq[tail] = n; tail = tail + 1 end
  end
  while head < tail do
    local m = dq[head]
    dq[head] = nil
    head = head + 1
    local hm = hang[m]
    local adj = m.adj
    for i = 1, #adj, 2 do
      local n, w = adj[i], adj[i + 1]
      local h = hm + w
      if h <= MAX_HANG and not (gone and gone[n.p.uid]) then
        local hn = hang[n]
        if hn == nil or h < hn then
          hang[n] = h
          if w == 0 then head = head - 1; dq[head] = n else dq[tail] = n; tail = tail + 1 end
        end
      end
    end
  end
  local map = {}
  for n, h in pairs(hang) do map[n.p.uid] = h end
  return map
end
-- (W2, kit_load.lua) the cached graph read as it is — g = { list = { { p, d,
-- a, r, adj } … }, cells } (kit_load keeps its own model on it, `g.kl`, so a
-- change of parts drops both) — the cell walk round a structure-frame (x, z),
-- and the ground rule
function graphOf(rec, defs) return graph_of(rec, defs) end
function nodesNear(g, x, z, r, f) near_nodes(g.cells, { x = x, z = z }, r, f) end
function isGrounded(p, a) return grounded(p, a) end
-- uid → hang for every piece of `rec` that is held from the ground somehow
-- (absent: nothing reaches it). `gone` = uids taken away (not cached).
function supportMap(rec, defs, gone)
  local g = graph_of(rec, defs)
  if gone and next(gone) ~= nil then return hang_map(g.list, gone), g.list, g.cells end
  if not g.map then g.map = hang_map(g.list, nil) end
  return g.map, g.list, g.cells
end
-- The hang the new part `np` (def `nd`) would have in `rec`: 0 grounded, nil
-- held by nothing within MAX_HANG.
function hangOf(rec, defs, np, nd, gone)
  if nd.snap == "mount" or nd.film then return 0 end
  local a = solid(np, nd)
  if grounded(np, a) then return 0 end
  local map, _, cells = supportMap(rec, defs, gone)
  local me = { p = np, d = nd, a = a, r = math.sqrt(a.hx * a.hx + a.hz * a.hz) + 0.1 }
  local best = nil
  near_nodes(cells, a, me.r + 4.0, function(m)
    if m.p.uid ~= np.uid then
      local hm = map[m.p.uid]
      local w = hm and weight(me, m)
      if w and hm + w <= MAX_HANG and (not best or hm + w < best) then best = hm + w end
    end
  end)
  return best
end

-- Kit support (Career): held through what it touches (above). → bool, hang
function supported(rec, defs, np, nd, gone)
  local h = hangOf(rec, defs, np, nd, gone)
  return h ~= nil, h
end

-- What is no longer held once `uids` are gone (transitively): kit pieces
-- only; a mount goes with the piece its face is on. → { uid … } (not uids)
function fallsWith(rec, defs, uids)
  local gone, out = {}, {}
  for _, u in ipairs(uids) do gone[u] = true end
  -- (one walk: a piece nothing holds holds nothing, so taking it away too
  -- changes no other piece's hang; mounts hold nothing either)
  local g = graph_of(rec, defs)
  local map = hang_map(g.list, gone)
  local mounts = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = not gone[p.uid] and defs(p.id)
    if d and d.kit then
      if d.snap == "mount" then mounts[#mounts + 1] = p
      elseif not d.film and map[p.uid] == nil then gone[p.uid] = true; out[#out + 1] = p.uid end
    end
  end
  -- a mount goes when no solid that stays is at its face (the cell index
  -- names the few near it; films are few and looked at all)
  local function holds(a, b)
    local grow = { x = b.x, z = b.z, hx = b.hx + 0.06, hz = b.hz + 0.06, yaw = b.yaw }
    return math.min(a.y1, b.y1 + 0.06) - math.max(a.y0, b.y0 - 0.06) > 0 and rectOverlap(a, grow, 0.0)
  end
  for _, p in ipairs(mounts) do
    local d = defs(p.id)
    local a = solid(p, d)
    local held = false
    near_nodes(g.cells, a, math.sqrt(a.hx * a.hx + a.hz * a.hz) + 0.2, function(n)
      if not held and not gone[n.p.uid] and n.p.uid ~= p.uid and holds(a, n.a) then held = true end
    end)
    if not held then
      for _, f in ipairs(g.films) do
        if not gone[f.p.uid] and f.p.uid ~= p.uid and holds(a, solid(f.p, f.d)) then held = true break end
      end
    end
    if not held then gone[p.uid] = true; out[#out + 1] = p.uid end
  end
  return out
end

-- ── S4: turning a mount on its face, and finding one under a click ──────────

-- A mount's pose turned `spin` (quarter turns) about its own face normal:
-- M = Ry(yaw)·Rx(pitch)·Ry(spin), back in the record's yaw, pitch, roll
-- (M = Ry·Rx·Rz). On a wall (pitch 90°) a quarter spin is pitch 0 and a
-- quarter roll: Rx(90)·Ry(s) = Rz(s)·Rx(90). → yaw, pitch, roll (quantised)
function spinPose(yaw, pitch, spin)
  if not spin or math.abs(spin) < 1e-6 then return yaw, pitch, 0 end
  local function Ry(a) local c, s = math.cos(a), math.sin(a); return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } end
  local function Rx(a) local c, s = math.cos(a), math.sin(a); return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } end
  local function mul(A, B)
    local C = {}
    for i = 1, 3 do C[i] = {} for j = 1, 3 do C[i][j] = A[i][1] * B[1][j] + A[i][2] * B[2][j] + A[i][3] * B[3][j] end end
    return C
  end
  local M = mul(mul(Ry(yaw), Rx(pitch)), Ry(spin))
  -- M = Ry(a)Rx(b)Rz(c): M[2][3] = -sin b, M[1][3] = sin a cos b, M[3][3] = cos a cos b,
  -- M[2][1] = cos b sin c, M[2][2] = cos b cos c
  local sb = math.max(-1, math.min(1, -M[2][3]))
  local b = math.asin(sb)
  local a, c
  if math.abs(math.cos(b)) > 1e-6 then
    a = math.atan2(M[1][3], M[3][3])
    c = math.atan2(M[2][1], M[2][2])
  else
    a = math.atan2(-M[3][1], M[1][1])
    c = 0
  end
  return wrap(quantize(a, QUARTER / 6)), wrap(quantize(b, QUARTER / 6)), wrap(quantize(c, QUARTER / 6))
end

-- The mount of `rec` (a decal, a sign, a fitting: pieces with no collider of
-- their own, so a ray goes through them to the wall) whose face holds the
-- structure-local point (lx, ly, lz), nearest the face first; within `tol`
-- (m) of its face. → part, def | nil
function mountAt(rec, defs, lx, ly, lz, tol)
  tol = tol or 0.06
  local best, bd, bdef = nil, 1e9, nil
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.snap == "mount" then
      local b = boxOf(d)
      local up, fw = localAxes(p.yaw or 0, p.pitch or 0, p.roll or 0)
      local rt = { up[2] * fw[3] - up[3] * fw[2], up[3] * fw[1] - up[1] * fw[3], up[1] * fw[2] - up[2] * fw[1] }
      local dx, dy, dz = lx - (p.x or 0), ly - (p.y or 0), lz - (p.z or 0)
      local u = dx * rt[1] + dy * rt[2] + dz * rt[3]
      local v = dx * up[1] + dy * up[2] + dz * up[3]
      local w = dx * fw[1] + dy * fw[2] + dz * fw[3]
      if u >= b[1] - 0.02 and u <= b[2] + 0.02 and w >= b[5] - 0.02 and w <= b[6] + 0.02 and v >= b[3] - tol and v <= b[4] + tol then
        -- (the smallest one wins: a number on a hazard panel, a sign on grime)
        local area = (b[2] - b[1]) * (b[6] - b[5]) + (d.film and 0 or -100)
        if area < bd then best, bd, bdef = p, area, d end
      end
    end
  end
  return best, bdef
end

-- ── HAB JOINS (Ty 11-10: "it just recognizes what's near it and forms the
-- connection"; docs/base-building.md §29) ──────────────────────────────────
-- A joinable segment (parts_kit `join`: the Hab Segment, the Window Segment)
-- works out its shape from the hab pieces round it, in its structure:
--   PORT   another segment, square to it, with an END on its side's middle
--          (on its box's side, at its ring's middle, within JOIN_TOL): a
--          port on that side, L (-X) or R (+X), the branch meeting the
--          port's berthing plate flush;
--   ENDS   with a port, an end with no hab piece on it (a probe 0.1 m past
--          the end in nobody's box) is plated: b (-Z), f (+Z). A straight
--          segment's open end still leaks until a cap or bulkhead goes on.
-- The code (nil for a straight one) names the variant parts_kit.joinId draws
-- and rooms.lua seals. Only cans upright and on the quarter grid join.
-- Cost: one pass over the structure's parts and, per segment near the
-- change, one over its hab pieces (a 40-can base: well under 0.1 ms).
JOIN_TOL = 0.12
JOIN_R = 3.6     -- a change re-shapes the segments whose centres are this near it

local function hab_entry(p, d)
  local c, s = math.cos(p.yaw or 0), math.sin(p.yaw or 0)
  return { p = p, d = d, x = p.x or 0, y = p.y or 0, z = p.z or 0, fx = s, fz = c, rx = c, rz = -s, seg = d.join == true }
end
-- The hab pieces of rec (and `extra`, a part not placed yet), upright.
local function hab_list(rec, defs, extra)
  local out = {}
  local function one(p)
    local d = defs(p.id)
    if d and d.snap == "hab" and math.abs(p.pitch or 0) < 1e-3 and math.abs(p.roll or 0) < 1e-3 then out[#out + 1] = hab_entry(p, d) end
  end
  for _, p in ipairs(rec.bp or {}) do one(p) end
  if extra then one(extra) end
  return out
end
local function in_box(h, x, y, z)
  if math.abs(y - h.y) > 0.05 then return false end
  local dx, dz = x - h.x, z - h.z
  local lx, lz = dx * h.rx + dz * h.rz, dx * h.fx + dz * h.fz
  local b = h.d.box
  return lx >= b[1] - 1e-3 and lx <= b[2] + 1e-3 and lz >= b[5] - 1e-3 and lz <= b[6] + 1e-3
end
local function shape_of(A, list)
  local yaw = A.p.yaw or 0
  if math.abs(wrap(yaw - quantize(yaw, QUARTER))) > 1e-3 then return nil end
  local b = A.d.box
  local L, R, ob, of = false, false, false, false
  local bx0, bx1 = A.x + A.fx * (b[5] - 0.1), A.z + A.fz * (b[5] - 0.1)
  local fx0, fx1 = A.x + A.fx * (b[6] + 0.1), A.z + A.fz * (b[6] + 0.1)
  for _, B in ipairs(list) do
    if B ~= A and math.abs(B.y - A.y) < 0.05 and (B.x - A.x) ^ 2 + (B.z - A.z) ^ 2 < 16 then
      if B.seg and math.abs(B.fx * A.fx + B.fz * A.fz) < 0.1 then
        local cl = (B.x - A.x) * A.rx + (B.z - A.z) * A.rz
        for _, e in ipairs({ B.d.box[5], B.d.box[6] }) do
          local ex, ez = B.x + B.fx * e, B.z + B.fz * e
          local lx = (ex - A.x) * A.rx + (ez - A.z) * A.rz
          local lz = (ex - A.x) * A.fx + (ez - A.z) * A.fz
          if math.abs(lz - (b[5] + b[6]) / 2) < JOIN_TOL then
            if math.abs(lx - b[2]) < JOIN_TOL and cl > b[2] then R = true end
            if math.abs(lx - b[1]) < JOIN_TOL and cl < b[1] then L = true end
          end
        end
      end
      if in_box(B, bx0, A.y, bx1) then ob = true end
      if in_box(B, fx0, A.y, fx1) then of = true end
    end
  end
  if not (L or R) then return nil end
  return (L and "L" or "") .. (R and "R" or "") .. (ob and "" or "b") .. (of and "" or "f")
end

-- The codes of rec's joinable segments near the structure-frame points pts
-- ({ { x, z } … }; nil = every one), as they would be with `extra` (a part
-- not placed yet: the ghost) added. Writes nothing. → { { p, code } … }
function habCodes(rec, defs, pts, extra)
  local list = hab_list(rec, defs, extra)
  local out = {}
  for _, A in ipairs(list) do
    if A.seg then
      local near = pts == nil
      if not near then
        for _, q in ipairs(pts) do
          if (A.x - q.x) ^ 2 + (A.z - q.z) ^ 2 <= JOIN_R * JOIN_R then near = true break end
        end
      end
      if near then out[#out + 1] = { p = A.p, code = shape_of(A, list) } end
    end
  end
  return out
end

-- Re-shape rec's segments near pts (nil = all): writes each one's `hj` (nil
-- when straight). → { p … } whose code changed (structures re-draws those)
function habShapes(rec, defs, pts)
  local changed = {}
  for _, e in ipairs(habCodes(rec, defs, pts)) do
    if e.p.hj ~= e.code then
      e.p.hj = e.code
      changed[#changed + 1] = e.p
    end
  end
  return changed
end
