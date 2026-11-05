-- PLACEMENT — the world queries placing a part asks (deep-space addendum K7;
-- docs/base-building.md). One function per query, so the engine's own
-- version (EN12: a true oriented-box overlap) is a change here only.
--
--   placement.overlapObb(center, half, rot, opts) → hit | nil
--       Is anything solid inside the oriented box? center = world point (a
--       vec3 or {x,y,z}); half = { x, y, z } half-extents (m); rot = the box's
--       axes as world unit vectors { r = {x,y,z}, u = {…}, f = {…} } (right,
--       up, front); opts = { ignore = node | {nodes}, skip = fn(node) → true
--       to pass over it (the ground) }. → the first hit inside the box
--       ({ node, x, y, z, inside = metres in }) or nil.
--
-- THE FALLBACK (until EN12). overlapSphere around the box's centre with the
-- box's half-diagonal finds everything that might touch it; each hit's
-- contact point, and the hit node's own origin, are then put through the
-- builder's oriented-box test (builder_attach.lua `boxSdf`: the signed
-- distance to the box, negative inside) and anything deeper than `margin`
-- is in the way. A hit that only grazes the sphere's rim, or a body whose
-- origin and contact both sit outside the box, is not. It answers the same
-- question EN12 will, conservatively: a long thin thing crossing the box
-- with both its origin and its deepest contact outside slips through.
--
-- A pure-ish script on the Build Kit node: `obbSdf` is pure (luajit tests).

MARGIN = 0.05

local function V(p) return p.x, p.y, p.z end

-- Signed distance from the box (centre c, half h, axes R) to point p:
-- negative inside. (builder_attach.lua boxSdf, in world axes.)
function obbSdf(c, h, R, px, py, pz)
  local cx, cy, cz = V(c)
  local dx, dy, dz = px - cx, py - cy, pz - cz
  local lx = dx * R.r.x + dy * R.r.y + dz * R.r.z
  local ly = dx * R.u.x + dy * R.u.y + dz * R.u.z
  local lz = dx * R.f.x + dy * R.f.y + dz * R.f.z
  local qx, qy, qz = math.abs(lx) - h.x, math.abs(ly) - h.y, math.abs(lz) - h.z
  local ox, oy, oz = math.max(qx, 0), math.max(qy, 0), math.max(qz, 0)
  return math.sqrt(ox * ox + oy * oy + oz * oz) + math.min(math.max(qx, math.max(qy, qz)), 0)
end

function overlapObb(center, half, rot, opts)
  opts = opts or {}
  if not overlapSphere then return nil end
  local rad = math.sqrt(half.x * half.x + half.y * half.y + half.z * half.z)
  local cx, cy, cz = V(center)
  local ok, hits = pcall(overlapSphere, vec3(cx, cy, cz), rad, opts.ignore and { ignore = opts.ignore } or nil)
  if not ok or type(hits) ~= "table" then return nil end
  local margin = opts.margin or MARGIN
  for _, h in ipairs(hits) do
    local n = h.node
    if not (opts.skip and n and opts.skip(n)) then
      local d = obbSdf(center, half, rot, h.x, h.y, h.z)
      if n and n.valid ~= false then
        local okp, p = pcall(function() return n.worldPos end)
        if okp and p then d = math.min(d, obbSdf(center, half, rot, p.x, p.y, p.z)) end
      end
      if d < -margin then return { node = n, x = h.x, y = h.y, z = h.z, inside = -d } end
    end
  end
  return nil
end
