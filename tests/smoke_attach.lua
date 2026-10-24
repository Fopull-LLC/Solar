-- SMOKE: the attachment rulebook (scripts/builder_attach.lua), the procedural
-- meshes (scripts/builder_proc.lua) and the drawn parts in the registry —
-- pure rulebooks, loaded from disk with nothing of the engine around them.
--
--   luajit solar/tests/smoke_attach.lua
--
-- The acceptance list of docs/builder-design.md §11.2 WP3, on fixed geometry:
-- a flush corner 5 cm under a post's top, a tee on the grid, a 4-member
-- rectangle that closes with 2 welds, no occupied joint offered on a lying
-- beam, the surface between a beam's middle and end reachable at 6 m, plus the
-- splice, the crossing, the brace, sizeOf and every generated mesh's winding.

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-3) end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local A = load("solar/scripts/builder_attach.lua")
local P = load("solar/scripts/builder_proc.lua")
local R = load("solar/scripts/parts_registry.lua")
local V = A.vec
local REG = R.REG
local I = A.IDENT
local EX, EY, EZ = V.v(1, 0, 0), V.v(0, 1, 0), V.v(0, 0, 1)

-- a world of records and links
local recs, links = {}, {}
local function add(uid, id, x, y, z, B, size)
  recs[uid] = { uid = uid, id = id, def = REG[id], x = x, y = y, z = z, B = B or I, size = size }
  return recs[uid]
end
local function linksOf(u)
  local out = {}
  for _, l in ipairs(links) do if l.a == u or l.b == u then out[#out + 1] = l end end
  return out
end
local function get(u) return recs[u] end
local function reset() recs, links = {}, {} end
local function nearAll() local t = {} for u in pairs(recs) do t[#t + 1] = u end table.sort(t) return t end

-- A basis with local Y along d (as the Beam tool lays a member).
local function along(d)
  local ref = math.abs(d.y) < 0.95 and EY or EX
  local X = V.norm(V.sub(ref, V.mul(d, V.dot(ref, d))))
  return { X = X, Y = d, Z = V.cross(X, d) }
end

-- a pinhole camera for the pixel rules: 1280 × 720, fov_y 1.08 (the builder's)
local function camera(C, T)
  local f = V.norm(V.sub(T, C))
  local r = V.norm(V.cross(f, EY))
  local u = V.cross(r, f)
  local foc = 360 / math.tan(0.54)
  return function(x, y, z)
    local d = V.sub(V.v(x, y, z), C)
    local zc = V.dot(d, f)
    if zc <= 0.01 then return 0, 0, false end
    return 640 + V.dot(d, r) / zc * foc, 360 - V.dot(d, u) / zc * foc, true
  end
end

local function held(id, off, size) return { def = REG[id], id = id, off = off or I, size = size } end
local function q(h, hit, extra)
  local t = { held = h, hit = hit, get = get, links = linksOf, near = nearAll(), grid = 0.05, gridHull = 0.25 }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local function hit(uid, x, y, z, nx, ny, nz) return { uid = uid, x = x, y = y, z = z, nx = nx, ny = ny, nz = nz } end
local function top(c, h) return c.y + A.supportAlong(h.def, c.B, EY, h.size) end

-- ── 1. CORNER: aiming 5 cm under a post's top gives a flush L ────────────────
reset()
add(1, "beam2", 0, 1.0, 0)                                -- a 2 m post, top at y = 2
local hb = held("beam2")
local c = A.best(q(hb, hit(1, 0.12, 1.95, 0, 1, 0, 0)))
check(c and c.kind == "corner", "5 cm under the top of a post offers a corner (got " .. tostring(c and c.kind) .. ")")
check(c and near(top(c, hb), 2.0, 1e-3), string.format("the corner member's top is flush with the post's top (%.4f)", c and top(c, hb) or -1))
check(c and near(c.x, 0.12 + 1.0, 1e-3) and near(V.dot(c.B.Y, EX), 1, 1e-6), "the corner member runs straight out of the face")
check(c and c.joint and c.joint.style == "gusset", "a corner gets a gusset")
check(c and c.link and c.link.k == "corner" and c.link.b == 1, "the corner is a link to the post")
-- same, a box beam turned so its narrow side is up: still flush
local hb2 = held("beam2", V.brot(EY, math.pi / 2))
local c2 = A.best(q(hb2, hit(1, 0.12, 1.95, 0, 1, 0, 0)))
check(c2 and c2.kind == "corner" and near(top(c2, hb2), 2.0, 1e-3), "a turned member's corner is flush too")
-- an I-beam on a strut: flush whatever the profiles
reset(); add(1, "strut2", 0, 1.0, 0)
local hi = held("ibeam2")
local ci = A.best(q(hi, hit(1, 0.07, 1.96, 0, 1, 0, 0)))
check(ci and ci.kind == "corner" and near(top(ci, hi), 2.0, 1e-3), "an I-beam corner on a strut post is flush")

-- ── 2. TEE on the span, at the grid point ───────────────────────────────────
reset(); add(1, "beam2", 0, 1.0, 0)
c = A.best(q(hb, hit(1, 0.12, 0.43, 0.01, 1, 0, 0)))
check(c and c.kind == "tee", "the span gives a tee (got " .. tostring(c and c.kind) .. ")")
-- grid from end A (y = 0): 1.43 m → 1.45 m → y = 0.45
check(c and near(c.y, 0.45, 1e-6), string.format("the tee sits on the 5 cm grid from the post's end (y %.4f)", c and c.y or -1))
check(c and near(c.z, 0, 1e-9), "the tee is centred on the face")
check(c and c.joint and c.joint.style == "gusset2", "a tee gets a gusset pair")
-- free (Shift): no grid
c = A.best(q(hb, hit(1, 0.12, 0.43, 0, 1, 0, 0), { free = true }))
check(c and near(c.y, 0.43, 1e-6), "Shift places the tee where aimed")

-- ── 3. SPLICE on an end cap, and CROSS on a face ────────────────────────────
c = A.best(q(hb, hit(1, 0.03, 2.0, -0.02, 0, 1, 0)))
check(c and c.kind == "splice" and near(c.y, 3.0) and near(c.x, 0) and near(c.z, 0), "an end cap gives a colinear splice")
check(c and c.joint and c.joint.style == "splice", "a splice gets splice plates")
local lying = held("beam2", V.brot(EX, math.pi / 2))        -- its axis now lies across the +X face
c = A.best(q(lying, hit(1, 0.12, 1.0, 0, 1, 0, 0)))
check(c and c.kind == "cross" and c.joint and c.joint.style == "clamp", "a member turned to lie across a face crosses with a clamp")
local lap = A.best(q(held("beam2", V.brot(EZ, math.pi / 2)), hit(1, 0.12, 1.0, 0, 1, 0, 0)))
check(lap and lap.kind == "surface", "a member laid along a face is a lap (surface), not a crossing")
check(c and near(c.x, 0.12 + 0.07, 1e-6), "the crossing member lies on the face")

-- ── 4. OCCUPANCY from links: an occupied joint on a LYING beam is never offered
reset()
local lay = along(V.v(0, 0, 1))                              -- lying along +Z
add(1, "beam2", 0, 1.0, 0, lay)
add(2, "beam2", 0, 1.0, -2.0, lay)                          -- on beam 1's END A (−Z)
links[#links + 1] = { a = 2, b = 1, k = "splice", pa = V.v(0, 1, 0), pb = V.v(0, -1, 0) }
check(A.occupied(recs[1], linksOf(1), "a") and not A.occupied(recs[1], linksOf(1), "b"),
  "a lying beam's occupied end is the linked one (not worked out from world Y)")
local proj = camera(V.v(4, 3, 1.5), V.v(0, 1, -0.8))
local jx, jy = proj(0, 1, -1)
local hub = held("hub")
local qq = q(hub, hit(1, 0.0, 1.07, -0.95, 0, 1, 0), { project = proj, mouse = { x = jx, y = jy } })
local vis = A.visibleNodes(qq)
local bad = false
for _, n in ipairs(vis) do if math.abs(n.z + 1.0) < 0.02 then bad = true end end
check(not bad, "no node is drawn on the occupied joint")
local cands = A.candidates(qq)
check(not (cands[1] and cands[1].node and math.abs(cands[1].at.z + 1) < 0.02), "the occupied joint is not offered as a snap")
-- the free ends are offered, and only on the hovered part and its neighbours
local ends = 0
for _, n in ipairs(vis) do if math.abs(math.abs(n.z + 1) - 2) < 0.02 then ends = ends + 1 end end
check(ends == 2, "the two free ends are the nodes drawn (got " .. ends .. " of " .. #vis .. ")")
-- a member aimed at the occupied cap is refused the splice
c = A.best(q(hb, hit(1, 0.0, 1.0, -1.0, 0, 0, -1)))
check(c and c.kind ~= "splice", "an occupied end cap offers no splice")

-- ── 5. a 2 m beam seen at 6 m: between the middle and the end is reachable ───
reset(); add(1, "beam2", 0, 1.0, 0)
proj = camera(V.v(0, 1.0, 6.0), V.v(0, 1.0, 0))
for _, h in ipairs({ held("hub"), held("tankS"), held("beam1") }) do
  local sx, sy = proj(0, 1.5, 0.07)
  local cs = A.candidates(q(h, hit(1, 0, 1.5, 0.07, 0, 0, 1), { project = proj, mouse = { x = sx, y = sy } }))
  local b1 = cs[1]
  check(b1 and not b1.node and near(b1.at.y, 1.5, 0.026),
    string.format("%s: the surface at 1.5 m is reachable (got %s at y %.2f)", h.id, tostring(b1 and b1.kind), b1 and b1.at.y or -1))
end
local rad = A.nodeRadiusPx(recs[1], proj)
check(rad <= 24 and rad >= 8, string.format("a frame member's node radius is 6 %% and at most 24 px (%.1f px)", rad))
-- and right on the end, the node still captures a stack part
do
  local sx, sy = proj(0, 2.0, 0)
  local cs = A.candidates(q(held("hub"), hit(1, 0, 1.97, 0.07, 0, 0, 1), { project = proj, mouse = { x = sx, y = sy + 3 } }))
  check(cs[1] and cs[1].node and cs[1].kind == "stack" and near(cs[1].y, 2.12, 1e-6), "aiming at a beam's end puts a hub on it")
end

-- ── 6. a 4-member rectangle drawn with the Beam tool closes with 2 welds ─────
reset()
local function draw(uid, p0, p1, exact)
  local m = A.memberBetween(p0, p1, "box", { get = get, exactEnd = exact })
  local r = add(uid, "beamP", m.x, m.y, m.z, m.B, m.size)
  return r, m
end
local function pt(uid, x, y, z, nx, ny, nz)
  return A.pointOn(q(nil, hit(uid, x, y, z, nx, ny, nz)))
end
local m1 = draw(1, V.v(0, 0.5, 0), V.v(2, 0.5, 0))
check(near(m1.size.len, 2.0) and near(m1.x, 1.0), "the first member is 2 m along X")
-- m1's +Z face is at z = 0.07; start near its end B, run +Z
local s2 = pt(1, 1.95, 0.5, 0.07, 0, 0, 1)
check(s2 and s2.region == "b", "a click near the end on the flank is the end region")
local m2 = draw(2, s2, V.v(1.95, 0.5, 2.02))
local lk, jt = A.endLink(m2, "a", m1)
links[#links + 1] = lk
check(lk.k == "corner" and jt and jt.style == "gusset", "the second member's start is a gusseted corner")
check(near(m2.x + 0.07, 2.0, 1e-6), string.format("…flush with the first member's end (outer face x %.4f)", m2.x + 0.07))
local s3 = pt(2, m2.x - 0.07, 0.5, m2.z + m2.size.len / 2 - 0.05, -1, 0, 0)
local m3 = draw(3, s3, V.v(-0.0, 0.5, s3.z))
links[#links + 1] = (A.endLink(m3, "a", m2))
-- the last member: from m3's end region to m1's end region (exact both ends)
local s4 = pt(3, -0.05, 0.5, m3.z - 0.07, 0, 0, -1)
local e4 = pt(1, 0.05, 0.5, 0.07, 0, 0, 1)
local m4 = draw(4, s4, e4, true)
local la = A.endLink(m4, "a", m3)
local lb = A.endLink(m4, "b", m1)
check(la.k == "corner" and lb.k == "corner", "the closing member makes a corner at each end (" .. la.k .. ", " .. lb.k .. ")")
local w4 = A.autoWelds(m4, { m1, m2, m3 }, {})
local wb = {}
for _, w in ipairs(w4) do wb[w.b] = (wb[w.b] or 0) + 1 end
check(#w4 == 2 and wb[1] == 1 and wb[3] == 1,
  string.format("the closing member welds at both ends: %d welds (to 1: %s, to 3: %s)", #w4, tostring(wb[1]), tostring(wb[3])))
-- placed the catalogue way (a primary corner link to m3), the far end still welds
local w4b = A.autoWelds(m4, { m1, m2, m3 }, { [3] = true })
check(#w4b == 1 and w4b[1].b == 1, "with its corner link to the third, the far end welds to the first")
-- a member whose end is nowhere near anything welds to nothing
local lone = add(9, "beamP", 10, 0.5, 10, along(EX), { len = 1, prof = "box" })
check(#A.autoWelds(lone, { m1, m2, m3, m4 }, {}) == 0, "a member touching nothing welds to nothing")

-- ── 7. drawn members, panels and the Brace ──────────────────────────────────
local mm = A.memberBetween(V.v(0, 0, 0), V.v(3.237, 0.2, 0), "tube")
check(mm and near(mm.size.len, 3.25, 1e-9), "a drawn member's length snaps to 5 cm")
check(mm and near(V.dot(mm.B.Y, EX), 1, 1e-9), "…and its direction to the axis within 6°")
check(near(A.memberBetween(V.v(0, 0, 0), V.v(0.05, 0, 0), "box").size.len, A.LEN_MIN), "a drawn member is at least 0.25 m")
check(near(A.memberBetween(V.v(0, 0, 0), V.v(40, 0, 0), "box").size.len, A.LEN_MAX), "…and at most 12 m")
local pn = A.panelOn(V.v(0, 0.11, 0), V.v(2.02, 0.11, 1.49), EY, 0.04)
check(pn and near(pn.size.w, 2.0) and near(pn.size.d, 1.5) and near(pn.y, 0.13), "a drawn panel snaps its sides to 5 cm and sits on the face")
reset(); add(1, "beam2", 0, 1, 0); add(2, "beam2", 2, 1, 0)
local br = A.braceBetween(V.v(0.12, 1.8, 0), V.v(1.88, 0.2, 0))
check(br and near(br.size.len, math.sqrt(1.76 ^ 2 + 1.6 ^ 2), 1e-9), "a brace runs exactly between its two points")
local brr = add(3, "brace", br.x, br.y, br.z, br.B, br.size)
check(A.endLink(brr, "a", recs[1]).k == "brace" and A.endLink(brr, "b", recs[2]).k == "brace", "a brace's ends are brace links")

-- ── 8. the registry's drawn parts ───────────────────────────────────────────
local sz = R.sizeOf("beamP", { len = 3.25, prof = "ibeam" })
check(sz and near(sz.mass, 0.03 * 3.25, 1e-9) and sz.cost == math.floor(23 * 3.25 + 0.5) and sz.strength == 650,
  "a drawn I-beam's mass and cost scale with its length")
local sp = R.sizeOf("panelP", { w = 2, d = 1.5, t = 0.10 })
check(sp and near(sp.mass, 0.025 * 3 * 2.4, 1e-9), "a drawn deck's mass scales with its area")
check(R.sizeOf("beam2").mass == REG.beam2.mass, "a fixed part answers its catalogue figures")
check(A.isMember(REG.beamP) and A.isMember(REG.strut1) and A.isMember(REG.brace) and not A.isMember(REG.tankS), "members are the struts, beams, drawn beams and braces")
check(A.isPanel(REG.panel1) and A.isPanel(REG.panelP) and not A.isPanel(REG.beam1), "panels are panels")
local inFrame = {}
for _, s in ipairs(R.catalogue()) do if s.title == "FRAME" then for _, id in ipairs(s.ids) do inFrame[id] = true end end end
check(inFrame.beamP and inFrame.panelP and inFrame.brace and inFrame.hub, "the FRAME section sells the drawn beam, panel, brace and the (optional) hub")

-- ── 9. every generated mesh is valid and wound outward ──────────────────────
local function validMesh(M, what)
  local np = #M.positions / 3
  local ok = #M.positions % 3 == 0 and #M.indices % 3 == 0 and #M.indices > 0
    and #M.normals == #M.positions and #M.uvs / 2 == np and #M.colors / 4 == np
  for _, i in ipairs(M.indices) do if i < 1 or i > np then ok = false end end
  for _, x in ipairs(M.positions) do if x ~= x or x == math.huge or x == -math.huge then ok = false end end
  check(ok, what .. ": lists are whole and indices in range")
  local wrong = 0
  local Pp, N = M.positions, M.normals
  for t = 1, #M.indices, 3 do
    local a, b, c3 = M.indices[t], M.indices[t + 1], M.indices[t + 2]
    local function p(i) return V.v(Pp[3 * i - 2], Pp[3 * i - 1], Pp[3 * i]) end
    local fn = V.cross(V.sub(p(b), p(a)), V.sub(p(c3), p(a)))
    local vn = V.v(N[3 * a - 2], N[3 * a - 1], N[3 * a])
    if V.len(fn) > 1e-12 and V.dot(fn, vn) <= 0 then wrong = wrong + 1 end
  end
  check(wrong == 0, string.format("%s: every triangle is counter-clockwise from outside (%d wrong of %d)", what, wrong, #M.indices / 3))
  return np
end
for _, prof in ipairs({ "tube", "box", "ibeam", "truss" }) do
  local n1 = validMesh(P.memberArrays(prof, 2.0), "member " .. prof)
  check(n1 < 6000, prof .. ": a 2 m member is a light mesh (" .. n1 .. " vertices)")
end
validMesh(P.memberArrays("truss", 12.0), "member truss 12 m")
validMesh(P.braceArrays(2.37), "brace")
validMesh(P.panelArrays(2, 1.5, 0.04), "panel sheet")
validMesh(P.panelArrays(2, 1.5, 0.10), "panel deck")
-- the joints builder_attach hands out
reset(); add(1, "beam2", 0, 1.0, 0)
for _, h in ipairs({ { 0.12, 1.95, 0, 1, 0, 0 }, { 0.12, 0.43, 0, 1, 0, 0 }, { 0, 2, 0, 0, 1, 0 } }) do
  local cc = A.best(q(hb, hit(1, h[1], h[2], h[3], h[4], h[5], h[6])))
  check(cc and cc.joint, "joint visual for " .. tostring(cc and cc.kind))
  if cc and cc.joint then validMesh(P.jointArrays(cc.joint), "joint " .. cc.joint.style) end
end
do
  local cl = A.best(q(lying, hit(1, 0.12, 1.0, 0, 1, 0, 0)))
  check(cl and cl.joint, "a crossing has a joint visual")
  if cl and cl.joint then validMesh(P.jointArrays(cl.joint), "joint clamp") end
end
-- the cache key quantises to 5 cm: lengths a hair apart share one mesh
check(P.keyOf({ def = REG.beamP, size = { len = 3.251, prof = "box" } }) == P.keyOf({ def = REG.beamP, size = { len = 3.249, prof = "box" } }),
  "members a hair apart share a mesh")
local hx, hy, hz = P.collider({ def = REG.beamP, size = { len = 3.25, prof = "truss" } })
check(near(hx, 0.2) and near(hy, 1.625) and near(hz, 0.18), "a drawn member's collider is its profile by half its length")
-- dress() with a fake engine: mesh built once, collider written, child made
do
  local built, made = 0, 0
  local env = { mesh = { build = function() built = built + 1 return "mesh:" .. built end },
                createNode = function(_, _, fn) made = made + 1; fn({ setMaterial = function() end }) end }
  local rb = { half_x = 0.12, half_y = 0.5, half_z = 0.07 }
  local node = { getComponent = function(_, k) return k == "RigidBody" and rb or nil end }
  P.dress(node, { def = REG.beamP, size = { len = 4.0, prof = "box" } }, env)
  P.dress(node, { def = REG.beamP, size = { len = 4.01, prof = "box" } }, env)
  check(built == 1 and made == 2, "two members of one length build ONE mesh and get a child each")
  check(near(rb.half_y, 2.005, 1e-9), "dress writes the collider before the rebuild")
end

-- ── 10. the corner angle (A/D steps) keeps the joint at the corner ───────────
reset(); add(1, "beam2", 0, 1.0, 0)
local ca = A.best(q(hb, hit(1, 0.12, 1.95, 0, 1, 0, 0), { cornerAngle = math.rad(135) }))
check(ca and ca.kind == "corner" and V.dot(ca.B.Y, EY) > 0.69 and V.dot(ca.B.Y, EY) < 0.72,
  "a 135° corner leans the member 45° up from the post's top")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_attach: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_attach: all %d checks passed", passed))
