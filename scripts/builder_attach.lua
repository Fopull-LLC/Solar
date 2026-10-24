-- BUILDER_ATTACH — where a part in hand can go, and how it joins what it
-- touches (docs/builder-design.md §5.2–5.5). Owner: WP3.
--
-- A pure RULEBOOK on the "BuilderAttach" manager node of scenes/builder.ron:
-- no scene access (no input, camera, nodes or spawn), its globals are its API,
-- and it loads from disk in a luajit test (tests/smoke_attach.lua). The
-- builder (WP1) owns the parts and asks; this file answers with poses and
-- links. The contract is SCRATCH/wp3/ATTACH_API.md; the short form:
--
--   candidates(q) / best(q)   the snap for the part in hand, best first
--   visibleNodes(q)           the attach nodes worth drawing (hovered part and
--                             its neighbours only; never an occupied one)
--   autoWelds(rec, near, linked)  contact welds after a placement
--   occupied(rec, links, end) occupancy from LINKS, never from world Y
--   pointOn(q), memberBetween, panelOn, braceBetween, endLink
--                             the Beam, Panel and Brace tools
--   shapeOf(def, size), isMember(def), isPanel(def)
--
-- Everything is in BuildFrame-local coordinates. A vector is {x,y,z}; a basis
-- B is {X,Y,Z}, the local axes as columns (builder.basisOf). A part record is
-- { uid, id, def, x, y, z, B, size }.
--
-- WHY THIS EXISTS (the user's "everything is on a strut hub, it looks like
-- Lego"): the old rules gave a member nodes only at its ends and mid-flanks,
-- let a 52 px node magnet beat surface attach, and worked out "occupied" from
-- world Y. A flush corner was impossible, so every frame grew a hub at every
-- joint. Here a frame member is three REGIONS — end A, span, end B — and
-- aiming a member at another one makes the joint a fabricator would: a
-- splice on an end cap, a flush corner near an end, a tee on the span, a
-- clamp where two cross. Each joint gets a small generated gusset or plate
-- (builder_proc) and a link the stress model can load. Hubs are still a part
-- for when you WANT a node block.

local EX, EY, EZ = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
IDENT = { X = EX, Y = EY, Z = EZ }

-- ── tunables (§5.2–5.5) ─────────────────────────────────────────────────────
WELD_TOL = 0.02          -- an end within 2 cm of a surface welds
WELD_EMBED = 0.04        -- …or up to 4 cm inside it (a drawn member meets a face)
END_FRAC, END_MIN = 0.12, 0.15   -- end region: 12 % of the length or 0.15 m
NODE_HULL = { frac = 0.10, min = 12, max = 40 }   -- stack node capture (px)
NODE_FRAME = { frac = 0.06, min = 8, max = 24 }   -- …on a frame member
LEN_STEP, LEN_MIN, LEN_MAX = 0.05, 0.25, 12.0     -- drawn members
JOINT_MASS = 0.001       -- t: a gusset or splice plate set (~1 kg)
JOINT_BONUS = 1.25       -- a gusseted link is 25 % stronger
OVERLAP = 0.55           -- deep-overlap refusal, as the old builder

-- Member profiles (half-widths across X and Z; the length is local Y).
PROFILES = {
  tube  = { rx = 0.07, rz = 0.07 },
  box   = { rx = 0.12, rz = 0.07 },
  ibeam = { rx = 0.12, rz = 0.13 },
  truss = { rx = 0.20, rz = 0.18 },
  brace = { rx = 0.035, rz = 0.035 },
}

-- ── vector helpers ──────────────────────────────────────────────────────────
local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a)
  local l = len(a)
  if l < 1e-12 then return v(0, 0, 0) end
  return mul(a, 1 / l)
end
local function neg(a) return v(-a.x, -a.y, -a.z) end
local function apply(B, p) -- local -> world (direction)
  return v(B.X.x * p.x + B.Y.x * p.y + B.Z.x * p.z,
           B.X.y * p.x + B.Y.y * p.y + B.Z.y * p.z,
           B.X.z * p.x + B.Y.z * p.y + B.Z.z * p.z)
end
local function applyT(B, p) return v(dot(B.X, p), dot(B.Y, p), dot(B.Z, p)) end
local function bmul(A, B) return { X = apply(A, B.X), Y = apply(A, B.Y), Z = apply(A, B.Z) } end
local function clean(B)
  local X = norm(B.X)
  local Y = norm(sub(B.Y, mul(X, dot(B.Y, X))))
  return { X = X, Y = Y, Z = cross(X, Y) }
end
local function turn(p, k, a) -- Rodrigues
  local c, s = math.cos(a), math.sin(a)
  return add(add(mul(p, c), mul(cross(k, p), s)), mul(k, dot(k, p) * (1 - c)))
end
local function brot(k, a) return { X = turn(EX, k, a), Y = turn(EY, k, a), Z = turn(EZ, k, a) } end
local function toLocal(rec, P) return applyT(rec.B, sub(P, rec)) end
local function toWorld(rec, p) return add(v(rec.x, rec.y, rec.z), apply(rec.B, p)) end
local function snap(x, g) if not g or g <= 0 then return x end return math.floor(x / g + 0.5) * g end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
vec = { v = v, add = add, sub = sub, mul = mul, dot = dot, cross = cross, norm = norm, len = len,
        apply = apply, applyT = applyT, bmul = bmul, clean = clean, brot = brot, turn = turn }

-- ── shapes ──────────────────────────────────────────────────────────────────
function isMember(def)
  return def ~= nil and (def.member == true or def.axial_out == true or def.proc == "member" or def.proc == "brace")
end
function isPanel(def)
  return def ~= nil and (def.panel == true or def.proc == "panel")
end

-- { hx, hy, hz, member, panel, len, prof, endR } of a part at a size.
function shapeOf(def, size)
  size = size or {}
  local s = { member = isMember(def), panel = isPanel(def) }
  if def.proc == "member" or def.proc == "brace" then
    local P = PROFILES[size.prof or def.prof or "box"] or PROFILES.box
    s.prof = size.prof or def.prof or "box"
    s.len = size.len or def.h
    s.hx, s.hz = P.rx, P.rz
  elseif def.proc == "panel" then
    s.hx, s.hz = (size.w or 1) * 0.5, (size.d or 1) * 0.5
    s.len = size.t or def.h
  else
    s.hx, s.hz, s.len = def.rx, def.rz, def.h
  end
  s.hy = s.len * 0.5
  s.endR = math.min(s.hy, math.max(END_FRAC * s.len, END_MIN))
  return s
end
local function shapeOfRec(r) if not r.shape then r.shape = shapeOf(r.def, r.size) end return r.shape end

-- Half-extent of a box shape turned B along unit direction n.
local function support(sh, B, n)
  return math.abs(dot(n, B.X)) * sh.hx + math.abs(dot(n, B.Y)) * sh.hy + math.abs(dot(n, B.Z)) * sh.hz
end
supportAlong = function(def, B, n, size) return support(shapeOf(def, size), B, n) end

-- Signed distance from local point p to a box of half-extents (hx, hy, hz).
local function boxSdf(sh, p)
  local qx, qy, qz = math.abs(p.x) - sh.hx, math.abs(p.y) - sh.hy, math.abs(p.z) - sh.hz
  local ox, oy, oz = math.max(qx, 0), math.max(qy, 0), math.max(qz, 0)
  return math.sqrt(ox * ox + oy * oy + oz * oz) + math.min(math.max(qx, math.max(qy, qz)), 0)
end
local function boxClosest(sh, p)
  return v(clamp(p.x, -sh.hx, sh.hx), clamp(p.y, -sh.hy, sh.hy), clamp(p.z, -sh.hz, sh.hz))
end
sdf = function(rec, P) return boxSdf(shapeOfRec(rec), toLocal(rec, P)) end

-- ── mount frames (as builder.attachBasis, so old crafts place the same) ─────
local function perp_ref(n, refs)
  for _, r in ipairs(refs) do
    local d = dot(r, n)
    if math.abs(d) < 0.95 then return norm(sub(r, mul(n, d))) end
  end
  return nil
end
function mountBasis(def, side, n, hostB)
  hostB = hostB or IDENT
  if side == "top" or side == "bottom" then return hostB end
  if not n then return IDENT end
  if side == "radial" and not (def.radial_orient or def.radial or def.axial_out or isMember(def)) then return hostB end
  n = norm(n)
  if def.radial_orient then
    local Y = perp_ref(n, { hostB.Y, hostB.Z, EY })
    return { X = n, Y = Y, Z = cross(n, Y) }
  end
  local X = perp_ref(n, { hostB.Y, hostB.X, EX })
  return { X = X, Y = n, Z = cross(X, n) }
end

-- ── occupancy (from links, never from world Y) ──────────────────────────────
-- The point of `link` on `rec`, in rec's local frame (nil if rec isn't in it).
local function linkPointOn(rec, l)
  if l.a == rec.uid then return l.pa end
  if l.b == rec.uid then return l.pb end
  return nil
end
-- where: "top"/"b" (+Y end), "bottom"/"a" (−Y end). An end is occupied when a
-- link lands on its cap (or, on a member, a splice/stack/weld at that end).
function occupied(rec, links, where)
  local sh = shapeOfRec(rec)
  local sgn = (where == "top" or where == "b") and 1 or -1
  for _, l in ipairs(links or {}) do
    local p = linkPointOn(rec, l)
    if p and l.k ~= "brace" and p.y * sgn > sh.hy - 0.02
      and math.abs(p.x) <= sh.hx + 0.01 and math.abs(p.z) <= sh.hz + 0.01 then
      -- a corner or tee on the END REGION's flank doesn't block the cap
      if not (l.k == "corner" and (math.abs(p.x) > sh.hx - 0.005 or math.abs(p.z) > sh.hz - 0.005)) then
        return true
      end
    end
  end
  return false
end

-- ── nodes ───────────────────────────────────────────────────────────────────
-- The stack and flank nodes of `rec` the held part fits, free ones only.
-- Each: { uid, side, at (local frame of the build), n }.
local function nodesOf(rec, held, links)
  local out = {}
  local d, gd = rec.def, held.def
  local sh = shapeOfRec(rec)
  local hm, gm = sh.member, isMember(gd)
  -- Member on member: no nodes — the joint regions do it (a splice on a cap).
  if hm and gm then return out end
  if d.top and (gd.bottom or gm) and not occupied(rec, links, "top") then
    out[#out + 1] = { uid = rec.uid, side = "top", at = toWorld(rec, v(0, sh.hy, 0)), n = rec.B.Y }
  end
  if d.bottom and (gd.top or gm) and not occupied(rec, links, "bottom") then
    out[#out + 1] = { uid = rec.uid, side = "bottom", at = toWorld(rec, v(0, -sh.hy, 0)), n = neg(rec.B.Y) }
  end
  -- Flank nodes on HULLS only (boosters, wheels on a rover body). Members and
  -- panels take surface attach anywhere instead — no flank magnets on them.
  if d.side and not hm and not sh.panel then
    local dirs
    if d.radial then dirs = { { rec.B.Y, sh.hy } }
    else dirs = { { rec.B.X, sh.hx }, { neg(rec.B.X), sh.hx }, { rec.B.Z, sh.hz }, { neg(rec.B.Z), sh.hz } } end
    for _, dd in ipairs(dirs) do
      local at = add(v(rec.x, rec.y, rec.z), mul(dd[1], dd[2]))
      local lp = toLocal(rec, at)
      local taken = false
      for _, l in ipairs(links or {}) do
        local p = linkPointOn(rec, l)
        if p and len(sub(p, lp)) < 0.6 * math.max(sh.hx, sh.hz) then taken = true break end
      end
      if not taken then out[#out + 1] = { uid = rec.uid, side = "radial", at = at, n = dd[1] } end
    end
  end
  return out
end

-- On-screen size of a part (px), for the node capture radius.
local function screenSize(rec, project)
  local sh = shapeOfRec(rec)
  local ax, r = rec.B.Y, sh.hy
  if sh.hx > r then ax, r = rec.B.X, sh.hx end
  if sh.hz > r then ax, r = rec.B.Z, sh.hz end
  local ax1, ay1, on1 = project(rec.x + ax.x * r, rec.y + ax.y * r, rec.z + ax.z * r)
  local ax2, ay2, on2 = project(rec.x - ax.x * r, rec.y - ax.y * r, rec.z - ax.z * r)
  if not (on1 and on2) then return nil end
  return math.sqrt((ax1 - ax2) ^ 2 + (ay1 - ay2) ^ 2)
end
function nodeRadiusPx(rec, project)
  local px = screenSize(rec, project)
  if not px then return 0 end
  local R = shapeOfRec(rec).member and NODE_FRAME or NODE_HULL
  return clamp(R.frac * px, R.min, R.max)
end

-- ── the pieces of a candidate ───────────────────────────────────────────────
local function heldShape(held) return shapeOf(held.def, held.size) end

local function finish(c, held, A)
  c.B = clean(bmul(A, held.off or IDENT))
  return c
end

-- The held part on a stack or flank node.
local function nodeCandidate(node, host, held)
  local n = node.n
  local A = mountBasis(held.def, node.side, n, host.B)
  local c = finish({ kind = "stack", host = host.uid, node = true, side = node.side }, held, A)
  if node.side == "radial" then c.kind = "surface" end
  local r = support(heldShape(held), c.B, n)
  local P = add(node.at, mul(n, r))
  c.x, c.y, c.z = P.x, P.y, P.z
  c.at, c.n = node.at, n
  local gm = isMember(held.def)
  c.end_ = gm and (dot(c.B.Y, n) > 0 and "a" or "b") or nil
  c.link = { b = host.uid, k = c.kind, pa = applyT(c.B, sub(node.at, P)), pb = toLocal(host, node.at), n = applyT(host.B, n) }
  return c
end

-- A face of a box host from a local normal: the dominant axis.
local function faceAxis(nl)
  local ax, ay, az = math.abs(nl.x), math.abs(nl.y), math.abs(nl.z)
  if ay >= ax and ay >= az then return "y", nl.y >= 0 and 1 or -1 end
  if ax >= az then return "x", nl.x >= 0 and 1 or -1 end
  return "z", nl.z >= 0 and 1 or -1
end
local AXV = { x = EX, y = EY, z = EZ }

-- The joint visual for a member end meeting a host (held-local geometry).
-- style: "gusset" (one plate pair in the corner's inner angle), "gusset2"
-- (a pair each side of a tee), "splice" (plates across a splice), "clamp"
-- (a block round a crossing). builder_proc.jointArrays draws it.
local function jointVisual(style, held, B, P, host, endSign, inward)
  local gs = heldShape(held)
  local hs = shapeOfRec(host)
  local function loc(dw) return applyT(B, dw) end
  local j = { style = style }
  -- contact point: the touching end's cap centre (held local)
  j.c = v(0, -endSign * gs.hy, 0)
  j.ax = v(0, endSign, 0)                 -- along the held member, away from the joint
  if inward then j.u = norm(loc(inward)) end   -- along the host, toward its body
  if j.u then
    local w = norm(cross(j.ax, j.u))
    j.w = w
    -- plates sit just outside the wider of the two members across w
    local hw = support(gs, IDENT, w)
    local hostw = support(hs, host.B, apply(B, w))
    j.ow = math.max(hw, hostw) + 0.006
    -- how deep the host is behind the contact face (the plate laps its flank)
    j.hd = support(hs, host.B, apply(B, j.ax))
  end
  j.leg = clamp(0.22 * gs.len, 0.10, 0.24)
  j.t = 0.008
  j.held = { hx = gs.hx, hz = gs.hz, prof = gs.prof }
  local _ = P
  return j
end

-- Member held, member host: splice / corner / tee / cross by where the ray hit.
local function memberJoint(held, host, hitP, hitN, q)
  local hs, gs = shapeOfRec(host), heldShape(held)
  local pl = toLocal(host, hitP)
  local nl = applyT(host.B, hitN)
  local axis, sgn = faceAxis(nl)
  local g = (q.free and 0) or q.grid or 0.05
  if axis == "y" then
    -- END CAP: splice, colinear
    if occupied(host, q.links and q.links(host.uid) or {}, sgn > 0 and "b" or "a") then
      return { refused = true, why = "that end is already joined" }
    end
    local n = mul(host.B.Y, sgn)
    local A = { X = host.B.X, Y = n, Z = cross(host.B.X, n) }
    local c = finish({ kind = "splice", host = host.uid }, held, A)
    local at = toWorld(host, v(0, sgn * hs.hy, 0))
    local P = add(at, mul(n, support(gs, c.B, n)))
    c.x, c.y, c.z, c.at, c.n = P.x, P.y, P.z, at, n
    local es = dot(c.B.Y, n) > 0 and 1 or -1
    c.end_ = es > 0 and "a" or "b"
    c.joint = jointVisual("splice", held, c.B, P, host, es, nil)
    c.link = { b = host.uid, k = "splice", pa = applyT(c.B, sub(at, P)), pb = toLocal(host, at), n = mul(EY, sgn) }
    return c
  end
  -- SIDE FACE
  local fn = mul(AXV[axis], sgn)                  -- host-local face normal
  local d = apply(host.B, fn)                       -- world
  local half = axis == "x" and hs.hx or hs.hz
  local A = { X = host.B.Y, Y = d, Z = cross(host.B.Y, d) }
  local c = finish({ host = host.uid }, held, A)
  local along = dot(c.B.Y, d)
  local y = pl.y
  local region = (y > hs.hy - hs.endR) and "b" or ((y < -hs.hy + hs.endR) and "a" or "span")
  if math.abs(along) > 0.7 then
    -- the held member stands out of the face: CORNER near an end, TEE on the span
    local es = along > 0 and 1 or -1                       -- +1: the held's end A touches
    local ey = support(gs, c.B, host.B.Y)                  -- held half-width along the host
    local kind
    if region == "span" then
      kind = "tee"
      y = -hs.hy + snap(y + hs.hy, g)                      -- grid from end A
      y = clamp(y, -hs.hy + ey, hs.hy - ey)
    else
      kind = "corner"
      local s = region == "b" and 1 or -1
      y = s * (hs.hy - ey)                                 -- outer faces flush
    end
    local atl = mul(fn, half)
    atl.y = y
    local at = toWorld(host, atl)
    -- corner angle (A/D steps): turn the member about the joint toward the end
    if kind == "corner" and q.cornerAngle and math.abs(q.cornerAngle - math.pi / 2) > 1e-6 then
      local s = region == "b" and 1 or -1
      local k = norm(cross(d, mul(host.B.Y, s)))
      local da = (q.cornerAngle - math.pi / 2)
      local pivot = add(at, mul(host.B.Y, s * ey))
      c.B = clean(bmul(brot(k, da), c.B))
      local Pc = add(at, mul(d, gs.hy))
      local rel = turn(sub(Pc, pivot), k, da)
      local P = add(pivot, rel)
      c.x, c.y, c.z = P.x, P.y, P.z
    else
      local P = add(at, mul(d, support(gs, c.B, d)))
      c.x, c.y, c.z = P.x, P.y, P.z
    end
    c.kind, c.at, c.n = kind, at, d
    c.end_ = es > 0 and "a" or "b"
    local P = v(c.x, c.y, c.z)
    local inward
    if kind == "corner" then inward = mul(host.B.Y, region == "b" and -1 or 1) else inward = host.B.Y end
    c.joint = jointVisual(kind == "tee" and "gusset2" or "gusset", held, c.B, P, host, es, inward)
    c.link = { b = host.uid, k = kind, pa = applyT(c.B, sub(at, P)), pb = toLocal(host, at), n = fn }
    return c
  end
  -- the held member lies ON the face: a CROSS (clamped) — or a lap if parallel
  local atl = mul(fn, half)
  atl.y = clamp(-hs.hy + snap(pl.y + hs.hy, g), -hs.hy, hs.hy)
  local at = toWorld(host, atl)
  local P = add(at, mul(d, support(gs, c.B, d)))
  -- slide the held along its own axis to where the cursor is (grid on the held)
  local par = math.abs(dot(c.B.Y, host.B.Y)) > 0.7
  c.kind = par and "surface" or "cross"
  c.x, c.y, c.z, c.at, c.n = P.x, P.y, P.z, at, d
  if not par then
    c.joint = jointVisual("clamp", held, c.B, P, host, 1, host.B.Y)
    c.joint.c = applyT(c.B, sub(at, P))
  end
  c.link = { b = host.uid, k = c.kind, pa = applyT(c.B, sub(at, P)), pb = toLocal(host, at), n = fn }
  return c
end

-- Surface attach anywhere on any host, the point snapped to the HOST GRID.
local function surfaceCandidate(held, host, hitP, hitN, q)
  local hs = shapeOfRec(host)
  local pl = toLocal(host, hitP)
  local nl = norm(applyT(host.B, hitN))
  local g = 0
  if not q.free then
    if hs.member or hs.panel then g = q.grid or 0.05 else g = q.gridHull or 0.25 end
  end
  local round = q.round and q.round(host.id)
  local ax, sgn = faceAxis(nl)
  if round and ax ~= "y" then
    -- a surface of revolution: grid along the axis, angle snap about it
    local r = math.sqrt(pl.x * pl.x + pl.z * pl.z)
    local th = math.atan2(pl.z, pl.x)
    if not q.free and q.angle and q.angle > 0 then th = snap(th, q.angle) end
    local y = clamp(snap(pl.y, g), -hs.hy, hs.hy)
    local nr = math.sqrt(nl.x * nl.x + nl.z * nl.z)
    pl = v(r * math.cos(th), y, r * math.sin(th))
    nl = norm(v(nr * math.cos(th), nl.y, nr * math.sin(th)))
  else
    -- a box face: the two in-face coordinates on the grid, measured from the
    -- face's corner so a 1 m beam's grid points sit at 5 cm from its end
    local fn = mul(AXV[ax], sgn)
    local function s1(k, h)
      if k == ax then return sgn * h end
      return clamp(-h + snap(pl[k] + h, g), -h, h)
    end
    pl = v(s1("x", hs.hx), s1("y", hs.hy), s1("z", hs.hz))
    nl = fn
  end
  local at = toWorld(host, pl)
  local n = apply(host.B, nl)
  local A = mountBasis(held.def, "surface", n, host.B)
  local c = finish({ kind = "surface", host = host.uid }, held, A)
  local P = add(at, mul(n, support(heldShape(held), c.B, n)))
  c.x, c.y, c.z, c.at, c.n = P.x, P.y, P.z, at, n
  if isMember(held.def) then c.end_ = dot(c.B.Y, n) > 0 and "a" or "b" end
  c.link = { b = host.uid, k = "surface", pa = applyT(c.B, sub(at, P)), pb = pl, n = nl }
  return c
end

local function floorCandidate(held, q)
  local f, r = q.floor, q.ray
  if not (f and r and r.d.y < -1e-4) then return nil end
  local t = (f.y - r.o.y) / r.d.y
  if t <= 0 then return nil end
  local x, z = r.o.x + r.d.x * t, r.o.z + r.d.z * t
  if not q.free then x, z = snap(x, f.grid or 0.25), snap(z, f.grid or 0.25) end
  local c = finish({ kind = "floor" }, held, IDENT)
  local h = support(heldShape(held), c.B, EY)
  c.x, c.y, c.z = x, f.y + h, z
  c.at, c.n = v(x, f.y, z), EY
  return c
end

-- Deep overlap with a near part (OBB → AABB, the old forgiving 0.55 rule).
local function aabb(sh, B)
  return math.abs(B.X.x) * sh.hx + math.abs(B.Y.x) * sh.hy + math.abs(B.Z.x) * sh.hz,
         math.abs(B.X.y) * sh.hx + math.abs(B.Y.y) * sh.hy + math.abs(B.Z.y) * sh.hz,
         math.abs(B.X.z) * sh.hx + math.abs(B.Y.z) * sh.hy + math.abs(B.Z.z) * sh.hz
end
function blockedBy(c, held, near, get, skip)
  local ax, ay, az = aabb(heldShape(held), c.B)
  for _, u in ipairs(near or {}) do
    if not (skip and skip[u]) then
      local r = get(u)
      if r then
        local bx, by, bz = aabb(shapeOfRec(r), r.B)
        if math.abs(c.x - r.x) < (ax + bx) * OVERLAP and math.abs(c.y - r.y) < (ay + by) * OVERLAP
          and math.abs(c.z - r.z) < (az + bz) * OVERLAP then
          -- the AABB says maybe; the OBB centre test says surely
          if boxSdf(shapeOfRec(r), toLocal(r, v(c.x, c.y, c.z))) < -0.02 then return u end
        end
      end
    end
  end
  return nil
end

-- ── the snap ────────────────────────────────────────────────────────────────
function candidates(q)
  local held = q.held
  local out = {}
  local get = q.get
  local function linksOf(u) return q.links and q.links(u) or {} end
  -- 1. stack / flank nodes within their pixel radius
  if q.project and q.mouse then
    local seen = {}
    local list = {}
    if q.hit then list[#list + 1] = q.hit.uid end
    for _, u in ipairs(q.near or {}) do list[#list + 1] = u end
    local best, bd = nil, math.huge
    for _, u in ipairs(list) do
      if not seen[u] then
        seen[u] = true
        local r = get(u)
        if r then
          local rad = nodeRadiusPx(r, q.project)
          for _, nd in ipairs(nodesOf(r, held, linksOf(u))) do
            local sx, sy, on = q.project(nd.at.x, nd.at.y, nd.at.z)
            if on then
              local dd = math.sqrt((sx - q.mouse.x) ^ 2 + (sy - q.mouse.y) ^ 2)
              if dd <= rad and dd < bd then best, bd = { nd, r }, dd end
            end
          end
        end
      end
    end
    if best then out[#out + 1] = nodeCandidate(best[1], best[2], held) end
  end
  -- 2./3. joint regions or surface on the part under the cursor
  if q.hit then
    local host = get(q.hit.uid)
    if host then
      local P, N = v(q.hit.x, q.hit.y, q.hit.z), norm(v(q.hit.nx, q.hit.ny, q.hit.nz))
      local c
      if isMember(held.def) and shapeOfRec(host).member then c = memberJoint(held, host, P, N, q) end
      if not c or c.refused then
        local why = c and c.why
        c = surfaceCandidate(held, host, P, N, q)
        if why then c.why = why end
      end
      out[#out + 1] = c
    end
  end
  -- 4. the floor
  if q.floor and q.ray then
    local c = floorCandidate(held, q)
    if c then out[#out + 1] = c end
  end
  for _, c in ipairs(out) do
    c.blocked = blockedBy(c, held, q.near, get, { [c.host or -1] = true })
  end
  return out
end
function best(q) return candidates(q)[1] end

-- The nodes to DRAW: the hovered part and the parts linked to it, only the
-- ones the held part fits, never an occupied one. `captured` marks the snap.
function visibleNodes(q)
  local out = {}
  if not q.hit then return out end
  local get = q.get
  local function linksOf(u) return q.links and q.links(u) or {} end
  local list, seen = { q.hit.uid }, {}
  for _, l in ipairs(linksOf(q.hit.uid)) do
    list[#list + 1] = (l.a == q.hit.uid) and l.b or l.a
  end
  local snapC = q.snap
  for _, u in ipairs(list) do
    if u and not seen[u] then
      seen[u] = true
      local r = get(u)
      if r then
        for _, nd in ipairs(nodesOf(r, q.held, linksOf(u))) do
          local cap = snapC and snapC.node and snapC.host == u and snapC.at
            and len(sub(snapC.at, nd.at)) < 1e-4 or false
          out[#out + 1] = { x = nd.at.x, y = nd.at.y, z = nd.at.z, nx = nd.n.x, ny = nd.n.y, nz = nd.n.z,
                            uid = u, side = nd.side, captured = cap }
        end
      end
    end
  end
  return out
end

-- ── auto-weld ───────────────────────────────────────────────────────────────
-- The contact points of a placed part that may weld: a member's two end caps
-- (centre + 4 corners), a stack part's top/bottom node, a panel's edge middles.
local function contactSets(rec)
  local sh = shapeOfRec(rec)
  local sets = {}
  if sh.member then
    for _, s in ipairs({ -1, 1 }) do
      local y = s * sh.hy
      sets[#sets + 1] = { name = s > 0 and "b" or "a", n = v(0, s, 0),
        pts = { v(0, y, 0), v(sh.hx, y, sh.hz), v(-sh.hx, y, sh.hz), v(sh.hx, y, -sh.hz), v(-sh.hx, y, -sh.hz) } }
    end
  elseif sh.panel then
    for _, e in ipairs({ { "x", 1 }, { "x", -1 }, { "z", 1 }, { "z", -1 } }) do
      local p = v(0, 0, 0); p[e[1]] = e[2] * (e[1] == "x" and sh.hx or sh.hz)
      local n = v(0, 0, 0); n[e[1]] = e[2]
      sets[#sets + 1] = { name = e[1] .. e[2], n = n, pts = { p } }
    end
  else
    if rec.def.top then sets[#sets + 1] = { name = "top", n = EY, pts = { v(0, sh.hy, 0) } } end
    if rec.def.bottom then sets[#sets + 1] = { name = "bottom", n = neg(EY), pts = { v(0, -sh.hy, 0) } } end
  end
  return sets
end

-- Welds for `rec` against `near` records, skipping uids in linked (a set).
-- One weld per (contact set, neighbour). Returns { link… } with a = rec.uid.
function autoWelds(rec, near, linked)
  local out = {}
  linked = linked or {}
  for _, set in ipairs(contactSets(rec)) do
    for _, o in ipairs(near or {}) do
      if o.uid ~= rec.uid and not linked[o.uid] then
        local osh = shapeOfRec(o)
        local bestd, bp = math.huge, nil
        for _, p in ipairs(set.pts) do
          local P = toWorld(rec, p)
          local pl = toLocal(o, P)
          local d = boxSdf(osh, pl)
          if d <= WELD_TOL and d >= -WELD_EMBED and math.abs(d) < math.abs(bestd) then bestd, bp = d, { p, pl } end
        end
        -- the cap centre must face the neighbour (no weld along a beam's flank
        -- just because its corner grazes something)
        if bp then
          local c = set.pts[1]
          local Pc = toWorld(rec, c)
          local dc = boxSdf(osh, toLocal(o, Pc))
          if dc <= WELD_TOL + math.max(shapeOfRec(rec).hx, shapeOfRec(rec).hz) then
            out[#out + 1] = { a = rec.uid, b = o.uid, k = "weld", pa = c,
                              pb = boxClosest(osh, toLocal(o, Pc)), n = set.n, at = set.name }
          end
        end
      end
    end
  end
  return out
end

-- ── the Beam, Panel and Brace tools ─────────────────────────────────────────
-- A snapped point for a tool click: on a part (grid, nodes, member regions)
-- or the floor. { x,y,z, n, host, region = "a"|"b"|"span"|"cap"|nil, kind }
function pointOn(q)
  local held = q.held or { def = { proc = "member", h = 1, rx = 0.12, rz = 0.07 } }
  if q.hit then
    local host = q.get(q.hit.uid)
    if host then
      local hs = shapeOfRec(host)
      local P, N = v(q.hit.x, q.hit.y, q.hit.z), norm(v(q.hit.nx, q.hit.ny, q.hit.nz))
      local c = surfaceCandidate({ def = { h = 0, rx = 0, rz = 0 }, off = IDENT }, host, P, N, q)
      local pl = toLocal(host, c.at)
      local region
      if hs.member then
        local ax = faceAxis(applyT(host.B, c.n))
        if ax == "y" then region = "cap"; pl = v(0, pl.y > 0 and hs.hy or -hs.hy, 0)
        elseif pl.y > hs.hy - hs.endR then region = "b"
        elseif pl.y < -hs.hy + hs.endR then region = "a"
        else region = "span" end
        if region == "cap" then c.at = toWorld(host, pl) end
      end
      local _ = held
      return { x = c.at.x, y = c.at.y, z = c.at.z, n = c.n, host = host.uid, region = region, kind = "surface" }
    end
  end
  if q.floor and q.ray and q.ray.d.y < -1e-4 then
    local t = (q.floor.y - q.ray.o.y) / q.ray.d.y
    if t > 0 then
      local x, z = q.ray.o.x + q.ray.d.x * t, q.ray.o.z + q.ray.d.z * t
      if not q.free then x, z = snap(x, q.floor.grid or 0.25), snap(z, q.floor.grid or 0.25) end
      return { x = x, y = q.floor.y, z = z, n = EY, kind = "floor" }
    end
  end
  return nil
end

-- A basis with Y along d and X as level as it can be.
local function axisBasis(d)
  local ref = math.abs(d.y) < 0.95 and EY or EX
  local X = norm(sub(ref, mul(d, dot(ref, d))))
  return { X = X, Y = d, Z = cross(X, d) }
end

-- A drawn member from p0 to p1. The length snaps to LEN_STEP (clamped), the
-- direction to a frame axis when within opts.axisSnap (default 6°). When p0
-- or p1 sits in a host member's END REGION on a side face (pointOn region
-- "a"/"b"), that end is moved along the host so the outer faces are flush (a
-- clean corner). opts.get = record accessor (for the flush corner).
function memberBetween(p0, p1, prof, opts)
  opts = opts or {}
  local P = PROFILES[prof or "box"] or PROFILES.box
  local sh = { hx = P.rx, hz = P.rz, hy = 0 }
  local d = sub(p1, p0)
  local L = len(d)
  if L < 1e-6 then return nil end
  d = mul(d, 1 / L)
  local axes = opts.axes or { EX, EY, EZ }
  local lim = math.cos(opts.axisSnap or math.rad(6))
  for _, a in ipairs(axes) do
    local c = dot(a, d)
    if math.abs(c) >= lim then d = mul(a, c > 0 and 1 or -1) break end
  end
  local B = axisBasis(d)
  local q0 = v(p0.x, p0.y, p0.z)
  local function flush(pt, sgn)
    if not (opts.get and pt.host and (pt.region == "a" or pt.region == "b")) then return pt end
    local host = opts.get(pt.host)
    local hs = shapeOfRec(host)
    local ey = support(sh, B, host.B.Y)
    local pl = toLocal(host, pt)
    pl.y = (pt.region == "b" and 1 or -1) * (hs.hy - ey)
    local w = toWorld(host, pl)
    local _ = sgn
    return { x = w.x, y = w.y, z = w.z, host = pt.host, region = pt.region, n = pt.n }
  end
  q0 = flush(p0, -1)
  local Lq = clamp(snap(L, LEN_STEP), LEN_MIN, LEN_MAX)
  if opts.exactEnd and p1.host then
    -- the end is on a part: keep the end there (length = the real distance)
    local q1 = flush(p1, 1)
    local dd = sub(q1, q0)
    Lq = len(dd)
    if math.abs(dot(norm(dd), d)) > 0.999 then d = norm(dd); B = axisBasis(d) end
  end
  local c = add(q0, mul(d, Lq * 0.5))
  return { x = c.x, y = c.y, z = c.z, B = B, size = { len = Lq, prof = prof or "box" },
           ends = { a = { x = q0.x, y = q0.y, z = q0.z, host = p0.host, region = p0.region },
                    b = { x = c.x + d.x * Lq * 0.5, y = c.y + d.y * Lq * 0.5, z = c.z + d.z * Lq * 0.5,
                          host = p1.host, region = p1.region } } }
end

-- A drawn panel: the rectangle from corner p0 to corner p1 on a face with
-- normal n (the floor: n = up). Its sides snap to LEN_STEP. thick 0.04 / 0.10.
function panelOn(p0, p1, n, thick, ref)
  n = norm(n or EY)
  thick = thick or 0.04
  local X = perp_ref(n, { ref or EX, EZ, EY })
  local Z = cross(X, n)
  local d = sub(p1, p0)
  local w = snap(dot(d, X), LEN_STEP)
  local dd = snap(dot(d, Z), LEN_STEP)
  if math.abs(w) < LEN_STEP or math.abs(dd) < LEN_STEP then return nil end
  local c = add(add(p0, add(mul(X, w * 0.5), mul(Z, dd * 0.5))), mul(n, thick * 0.5))
  return { x = c.x, y = c.y, z = c.z, B = { X = X, Y = n, Z = Z },
           size = { w = math.abs(w), d = math.abs(dd), t = thick } }
end

-- The two-point Brace: a thin tube from p0 to p1 (both already snapped by
-- pointOn). No length snapping: a brace goes where it is told.
function braceBetween(p0, p1)
  -- the lugs sit ON the faces: stand each end off its face by the tube's radius
  local r = PROFILES.brace.rx
  if p0.n then p0 = add(p0, mul(p0.n, r)) end
  if p1.n then p1 = add(p1, mul(p1.n, r)) end
  local d = sub(p1, p0)
  local L = len(d)
  if L < 0.1 then return nil end
  d = mul(d, 1 / L)
  local c = add(p0, mul(d, L * 0.5))
  return { x = c.x, y = c.y, z = c.z, B = axisBasis(d), size = { len = L, prof = "brace" },
           ends = { a = p0, b = p1 } }
end

-- The link (and joint visual) for one end of a placed member against a host:
-- the joint is classified by where the end lands on it.
function endLink(rec, which, host)
  local sh = shapeOfRec(rec)
  local s = which == "b" and 1 or -1
  local at = toWorld(rec, v(0, s * sh.hy, 0))
  local hs = shapeOfRec(host)
  local pl = toLocal(host, at)
  local outN = mul(rec.B.Y, -s)                -- from the end toward the host
  local k = "surface"
  local style
  if rec.def.proc == "brace" then
    k = "brace"
  elseif hs.member and sh.member then
    local nl = applyT(host.B, neg(outN))
    local ax = faceAxis(nl)
    if ax == "y" and math.abs(dot(rec.B.Y, host.B.Y)) > 0.9 then k, style = "splice", "splice"
    elseif pl.y > hs.hy - hs.endR or pl.y < -hs.hy + hs.endR then k, style = "corner", "gusset"
    else k, style = "tee", "gusset2" end
  end
  local link = { a = rec.uid, b = host.uid, k = k, pa = v(0, s * sh.hy, 0), pb = boxClosest(hs, pl),
                 n = applyT(host.B, neg(outN)), at = which }
  local joint
  if style then
    local inward
    if style == "gusset" then inward = mul(host.B.Y, pl.y > 0 and -1 or 1)
    elseif style == "gusset2" then inward = host.B.Y end
    joint = jointVisual(style, { def = rec.def, size = rec.size }, rec.B, v(rec.x, rec.y, rec.z), host, -s, inward)
  end
  return link, joint
end

-- The visual-only prefab a builder stand spawns for a flight prefab.
function visPrefab(prefab) return "vis/" .. prefab end
