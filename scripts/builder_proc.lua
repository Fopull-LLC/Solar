-- BUILDER_PROC — procedural part meshes: drawn members (tube, box, I-beam,
-- truss), drawn panels, the Brace, and the small joint pieces (gussets,
-- splice plates, crossing clamps) builder_attach asks for (§5.3–5.5). Owner: WP3.
--
-- A pure RULEBOOK: the array builders touch nothing of the engine and load in
-- luajit (tests/smoke_attach.lua). Only meshName / dress / dressJoint call the
-- engine (mesh.build, createNode, getComponent), and only when it is there.
-- It serves BOTH the builder stand (a visual-only prefab, dressed) and the
-- flight (vessel_spawner dresses the flight prefab and sets its collider
-- BEFORE assembly.rebuild, so the compound has the drawn member's real box —
-- engine 0.117: RigidBody half_* writes are read by the rebuild).
--
--   memberArrays(prof, len)      mesh.build lists for a member along local Y
--   panelArrays(w, d, t)         a panel in its X–Z plane
--   braceArrays(len)             the Brace: a tube with a lug each end
--   jointArrays(j)               a builder_attach joint visual (held-local)
--   meshName(key, fn)            mesh.build once per key (cached), fn() → lists
--   keyOf(rec)                   the cache key of a procedural part's mesh
--   arraysOf(rec)                its lists
--   collider(rec)                half_x, half_y, half_z of its box
--   dress(node, rec [, env])     give a spawned procedural part its mesh and
--                                collider; env = { createNode, mesh } (globals)
--   dressJoint(node, j [, env])  hang a joint visual on a part's node
--   MATERIAL                     the one material they wear (vertex-coloured)
--   stats()                      { meshes, builds } for the budget readout
--
-- One material and vertex colours: a member is ONE draw (the catalogue beams
-- are three or four), and every member of a profile and length (5 cm steps)
-- shares one mesh, so instancing holds on a 1,000-member frame.

STEP = 0.05

MATERIAL = { texture = "textures/parts/metal_albedo.png", normalMap = "textures/parts/metal_normal.png",
             roughnessMap = "textures/parts/metal_orm.png", occlusionMap = "textures/parts/metal_orm.png",
             shading = "physical", roughness = 0.9, metallic = 0.5 }

local ANOD = { 0.50, 0.56, 0.66, 1 }
local METAL = { 0.86, 0.86, 0.88, 1 }
local DARK = { 0.30, 0.30, 0.32, 1 }
local YELLOW = { 0.95, 0.72, 0.12, 1 }
local TREAD = { 0.62, 0.62, 0.64, 1 }
local GUSSET = { 0.74, 0.76, 0.80, 1 }
COLORS = { anod = ANOD, metal = METAL, dark = DARK, yellow = YELLOW, tread = TREAD, gusset = GUSSET }

-- ── a mesh under construction ───────────────────────────────────────────────
local function newMesh() return { positions = {}, normals = {}, uvs = {}, colors = {}, indices = {}, n = 0 } end
local function vtx(M, p, nrm, u, vv, c)
  local P, N, U, C = M.positions, M.normals, M.uvs, M.colors
  P[#P + 1], P[#P + 2], P[#P + 3] = p[1], p[2], p[3]
  N[#N + 1], N[#N + 2], N[#N + 3] = nrm[1], nrm[2], nrm[3]
  U[#U + 1], U[#U + 2] = u, vv
  C[#C + 1], C[#C + 2], C[#C + 3], C[#C + 4] = c[1], c[2], c[3], c[4]
  M.n = M.n + 1
  return M.n
end
local function tri(M, a, b, c) local I = M.indices I[#I + 1], I[#I + 2], I[#I + 3] = a, b, c end
local function vadd(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function vmul(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function vdot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function vcross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function vnorm(a)
  local l = math.sqrt(vdot(a, a))
  if l < 1e-12 then return { 0, 0, 0 } end
  return vmul(a, 1 / l)
end

-- A flat quad a→b→c→d, counter-clockwise seen from its normal side. UVs in
-- metres along t1/t2 (so the brushed grain keeps its size on every length).
local function quad(M, a, b, c, d, nrm, col, t1, t2)
  t1 = t1 or vnorm(vsub(b, a)); t2 = t2 or vnorm(vsub(d, a))
  local i1 = vtx(M, a, nrm, vdot(a, t1), vdot(a, t2), col)
  local i2 = vtx(M, b, nrm, vdot(b, t1), vdot(b, t2), col)
  local i3 = vtx(M, c, nrm, vdot(c, t1), vdot(c, t2), col)
  local i4 = vtx(M, d, nrm, vdot(d, t1), vdot(d, t2), col)
  tri(M, i1, i2, i3); tri(M, i1, i3, i4)
end

-- A box: centre c, unit axes ax (3 vectors), half sizes h (3 numbers).
local function obox(M, c, ax, h, col)
  for k = 1, 3 do
    local k1, k2 = k % 3 + 1, (k + 1) % 3 + 1      -- ax[k1] × ax[k2] = ax[k]
    for _, s in ipairs({ 1, -1 }) do
      local n = vmul(ax[k], s)
      local fc = vadd(c, vmul(ax[k], s * h[k]))
      local t1, t2 = vmul(ax[k1], h[k1]), vmul(ax[k2], h[k2])
      if s < 0 then t1, t2 = t2, t1 end
      quad(M, vsub(vsub(fc, t1), t2), vsub(vadd(fc, t1), t2), vadd(vadd(fc, t1), t2), vadd(vsub(fc, t1), t2),
           n, col, vnorm(t1), vnorm(t2))
    end
  end
end
local AX = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
local function box(M, cx, cy, cz, hx, hy, hz, col) obox(M, { cx, cy, cz }, AX, { hx, hy, hz }, col) end

-- An n-sided prism from p0 to p1 of radius r (caps optional).
local function prism(M, p0, p1, r, sides, col, caps)
  local d = vsub(p1, p0)
  local L = math.sqrt(vdot(d, d))
  if L < 1e-6 then return end
  local a = vmul(d, 1 / L)
  local ref = math.abs(a[2]) < 0.9 and { 0, 1, 0 } or { 1, 0, 0 }
  local e1 = vnorm(vcross(a, ref))
  local e2 = vcross(a, e1)
  local ring = {}
  for i = 0, sides - 1 do
    local th = (i + 0.5) / sides * 2 * math.pi
    ring[#ring + 1] = vadd(vmul(e1, math.cos(th)), vmul(e2, math.sin(th)))
  end
  local circ = 2 * math.pi * r
  for i = 1, sides do
    local j = i % sides + 1
    local na, nb = ring[i], ring[j]
    local A0, B0 = vadd(p0, vmul(na, r)), vadd(p0, vmul(nb, r))
    local A1, B1 = vadd(p1, vmul(na, r)), vadd(p1, vmul(nb, r))
    local u0, u1 = (i - 1) / sides * circ, i / sides * circ
    local i1 = vtx(M, A0, na, u0, 0, col)
    local i2 = vtx(M, B0, nb, u1, 0, col)
    local i3 = vtx(M, B1, nb, u1, L, col)
    local i4 = vtx(M, A1, na, u0, L, col)
    -- outward: ring goes counter-clockwise about +a
    tri(M, i1, i2, i3); tri(M, i1, i3, i4)
  end
  if caps then
    for _, e in ipairs({ { p0, vmul(a, -1) }, { p1, a } }) do
      local c, n = e[1], e[2]
      local ic = vtx(M, c, n, 0, 0, col)
      local ids = {}
      for i = 1, sides do
        local p = vadd(c, vmul(ring[i], r))
        ids[i] = vtx(M, p, n, vdot(p, e1), vdot(p, e2), col)
      end
      for i = 1, sides do
        local j = i % sides + 1
        if vdot(n, a) > 0 then tri(M, ic, ids[i], ids[j]) else tri(M, ic, ids[j], ids[i]) end
      end
    end
  end
end

-- A flat convex polygon (2D points in the u,v plane of frame o,eu,ev) extruded
-- by thickness t along ew = eu × ev (centred on the plane).
local function plate(M, o, eu, ev, pts, t, col)
  local ew = vnorm(vcross(eu, ev))
  -- the faces below assume the outline runs counter-clockwise in (u, v)
  local area = 0
  for i = 1, #pts do local p, q = pts[i], pts[i % #pts + 1]; area = area + p[1] * q[2] - q[1] * p[2] end
  if area < 0 then
    local r = {}
    for i = #pts, 1, -1 do r[#r + 1] = pts[i] end
    pts = r
  end
  local function P(p, s) return vadd(vadd(vadd(o, vmul(eu, p[1])), vmul(ev, p[2])), vmul(ew, s * t * 0.5)) end
  for _, s in ipairs({ 1, -1 }) do
    local n = vmul(ew, s)
    local ids = {}
    for i, p in ipairs(pts) do local q = P(p, s); ids[i] = vtx(M, q, n, p[1], p[2], col) end
    for i = 2, #pts - 1 do
      if s > 0 then tri(M, ids[1], ids[i], ids[i + 1]) else tri(M, ids[1], ids[i + 1], ids[i]) end
    end
  end
  for i = 1, #pts do
    local a, b = pts[i], pts[i % #pts + 1]
    local A0, B0, A1, B1 = P(a, -1), P(b, -1), P(a, 1), P(b, 1)
    local edge = vnorm(vsub(B0, A0))
    local n = vnorm(vcross(edge, ew))
    -- face outward from the polygon's centre
    local cx, cy = 0, 0
    for _, p in ipairs(pts) do cx, cy = cx + p[1], cy + p[2] end
    local mid = P({ (a[1] + b[1]) * 0.5 - cx / #pts, (a[2] + b[2]) * 0.5 - cy / #pts }, 0)
    if vdot(n, vsub(mid, o)) < 0 then n = vmul(n, -1); A0, B0, A1, B1 = B0, A0, B1, A1 end
    quad(M, A0, B0, B1, A1, n, col)
  end
end

local function bolts(M, y, pts, up, col)
  for _, p in ipairs(pts) do
    prism(M, { p[1], y, p[2] }, { p[1], y + (up and 0.008 or -0.008), p[2] }, 0.007, 6, col or DARK, true)
  end
end

-- ── members ─────────────────────────────────────────────────────────────────
local function endPlates(M, h, w, d, t)
  t = t or 0.016
  box(M, 0, h - t / 2, 0, w / 2, t / 2, d / 2, METAL)
  box(M, 0, -h + t / 2, 0, w / 2, t / 2, d / 2, METAL)
  local bx, bz = w / 2 - 0.018, d / 2 - 0.018
  local pts = { { bx, bz }, { -bx, bz }, { bx, -bz }, { -bx, -bz } }
  bolts(M, h, pts, true); bolts(M, -h, pts, false)
end

local BUILD = {}
BUILD.tube = function(M, L)
  local h = L / 2
  prism(M, { 0, -h + 0.03, 0 }, { 0, h - 0.03, 0 }, 0.055, 12, ANOD, false)
  prism(M, { 0, h - 0.03, 0 }, { 0, h, 0 }, 0.07, 12, METAL, true)
  prism(M, { 0, -h, 0 }, { 0, -h + 0.03, 0 }, 0.07, 12, METAL, true)
end
BUILD.box = function(M, L)
  local h = L / 2
  box(M, 0, 0, 0, 0.1, h - 0.02, 0.05, ANOD)
  for _, s in ipairs({ 1, -1 }) do box(M, 0, 0, s * 0.052, 0.015, h - 0.04, 0.003, METAL) end
  endPlates(M, h, 0.24, 0.14)
end
BUILD.ibeam = function(M, L)
  local h = L / 2
  local hs = h - 0.02
  for _, s in ipairs({ 1, -1 }) do box(M, 0, 0, s * 0.11, 0.1, hs, 0.01, YELLOW) end
  box(M, 0, 0, 0, 0.007, hs, 0.1, YELLOW)
  local n = math.max(1, math.floor(L / 0.5 + 0.5))
  for k = 1, n - 1 do
    local y = -h + L * k / n
    for _, s in ipairs({ 1, -1 }) do box(M, s * 0.05, y, 0, 0.043, 0.006, 0.1, YELLOW) end
  end
  endPlates(M, h, 0.24, 0.26)
end
local TRUSS = { { -0.17, -0.13 }, { 0.17, -0.13 }, { 0.0, 0.15 } }
BUILD.truss = function(M, L)
  local h = L / 2
  local y0, y1 = -h + 0.016, h - 0.016
  for _, c in ipairs(TRUSS) do prism(M, { c[1], y0, c[2] }, { c[1], y1, c[2] }, 0.022, 6, ANOD, false) end
  local n = math.max(1, math.floor((y1 - y0) / 0.4 + 0.5))
  for k = 0, n do
    local y = y0 + (y1 - y0) * k / n
    for i = 1, 3 do
      local a, b = TRUSS[i], TRUSS[i % 3 + 1]
      prism(M, { a[1], y, a[2] }, { b[1], y, b[2] }, 0.012, 5, METAL, false)
    end
  end
  for k = 0, n - 1 do
    local ya, yb = y0 + (y1 - y0) * k / n, y0 + (y1 - y0) * (k + 1) / n
    for i = 1, 3 do
      local a, b = TRUSS[i], TRUSS[i % 3 + 1]
      if (k + i) % 2 == 0 then a, b = b, a end
      prism(M, { a[1], ya, a[2] }, { b[1], yb, b[2] }, 0.011, 5, METAL, false)
    end
  end
  for _, s in ipairs({ 1, -1 }) do
    plate(M, { 0, s * (h - 0.008), 0 }, { 1, 0, 0 }, { 0, 0, -1 },
          { { -0.2, 0.17 }, { 0.2, 0.17 }, { 0.05, -0.18 }, { -0.05, -0.18 } }, 0.016, METAL)
  end
end
BUILD.brace = function(M, L)
  local h = L / 2
  prism(M, { 0, -h + 0.05, 0 }, { 0, h - 0.05, 0 }, 0.022, 10, DARK, false)
  for _, s in ipairs({ 1, -1 }) do
    prism(M, { 0, s * (h - 0.09), 0 }, { 0, s * (h - 0.05), 0 }, 0.03, 10, METAL, true)
    box(M, 0, s * (h - 0.025), 0, 0.035, 0.025, 0.012, METAL)      -- the lug
    prism(M, { 0, s * (h - 0.022), -0.022 }, { 0, s * (h - 0.022), 0.022 }, 0.009, 6, DARK, true) -- its pin
  end
end

local function quantLen(L) return math.max(STEP, math.floor(L / STEP + 0.5) * STEP) end

function memberArrays(prof, L)
  local M = newMesh()
  local f = BUILD[prof or "box"] or BUILD.box
  f(M, L)
  return M
end
function braceArrays(L) return memberArrays("brace", L) end

function panelArrays(w, d, t)
  local M = newMesh()
  t = t or 0.04
  local e = 0.05
  local hw, hd, ht = w / 2, d / 2, t / 2
  if t >= 0.08 then
    -- a deck: tread top, boxed frame, belly plate
    box(M, 0, ht - 0.01, 0, hw, 0.01, hd, TREAD)
    box(M, 0, -0.01, 0, hw - 0.01, ht - 0.01, hd - 0.01, DARK)
    box(M, 0, -ht + 0.008, 0, hw, 0.008, hd, METAL)
  else
    box(M, 0, 0, 0, hw - e + 0.002, ht * 0.6, hd - e + 0.002, TREAD)
    for _, s in ipairs({ 1, -1 }) do
      box(M, 0, 0, s * (hd - e / 2), hw, ht, e / 2, METAL)
      box(M, s * (hw - e / 2), 0, 0, e / 2, ht, hd - e, METAL)
    end
  end
  return M
end

-- ── joints (builder_attach joint visuals, in the held part's local frame) ───
local function V(p) return { p.x, p.y, p.z } end
function jointArrays(j)
  local M = newMesh()
  local c, ax = V(j.c), V(j.ax)
  local t = j.t or 0.008
  local leg = j.leg or 0.2
  if j.style == "gusset" or j.style == "gusset2" then
    local u, w = V(j.u), V(j.w)
    local hd = j.hd or 0.07
    local pts
    if j.style == "gusset" then
      pts = { { -hd, 0 }, { -hd, leg }, { 0, leg }, { leg, 0 } }
    else
      pts = { { -hd, -leg }, { -hd, leg }, { 0, leg }, { leg * 0.8, 0 }, { 0, -leg } }
    end
    -- the plates' own grid: first coord along ax, second along u
    for _, s in ipairs({ 1, -1 }) do
      local o = vadd(c, vmul(w, s * (j.ow + t / 2)))
      plate(M, o, ax, u, pts, t, GUSSET)
      -- three bolts through each leg
      for _, b in ipairs({ { leg * 0.55, 0.035 }, { -hd * 0.5, leg * 0.6 }, { 0.035, leg * 0.3 } }) do
        local p = vadd(vadd(o, vmul(ax, b[1])), vmul(u, b[2]))
        prism(M, p, vadd(p, vmul(w, s * (t / 2 + 0.006))), 0.007, 6, DARK, true)
      end
    end
  elseif j.style == "splice" then
    local hx, hz = j.held.hx, j.held.hz
    for _, s in ipairs({ 1, -1 }) do
      box(M, c[1] + s * (hx + t / 2), c[2], c[3], t / 2, 0.2, hz * 0.8, GUSSET)
      for _, dy in ipairs({ -0.12, -0.05, 0.05, 0.12 }) do
        local p = { c[1] + s * (hx + t), c[2] + dy, c[3] }
        prism(M, p, { p[1] + s * 0.006, p[2], p[3] }, 0.007, 6, DARK, true)
      end
    end
  elseif j.style == "clamp" then
    local hx, hz = j.held.hx, j.held.hz
    box(M, c[1], c[2], c[3], hx + 0.02, 0.05, hz + 0.02, METAL)
    for _, s in ipairs({ 1, -1 }) do
      local p = { c[1] + s * (hx + 0.02), c[2], c[3] }
      prism(M, p, { p[1] + s * 0.012, p[2], p[3] }, 0.012, 6, DARK, true)
    end
  end
  return M
end

-- ── what a procedural part is ───────────────────────────────────────────────
local function sizeOfRec(rec)
  local def = rec.def or {}
  local s = rec.size or {}
  return def, s
end
function keyOf(rec)
  local def, s = sizeOfRec(rec)
  if def.proc == "member" then return "m:" .. (s.prof or def.prof or "box") .. ":" .. string.format("%.2f", quantLen(s.len or def.h)) end
  if def.proc == "brace" then return "b:" .. string.format("%.2f", quantLen(s.len or def.h)) end
  if def.proc == "panel" then
    return "p:" .. string.format("%.2f:%.2f:%.2f", quantLen(s.w or 1), quantLen(s.d or 1), s.t or def.h or 0.04)
  end
  return nil
end
function arraysOf(rec)
  local def, s = sizeOfRec(rec)
  if def.proc == "member" then return memberArrays(s.prof or def.prof or "box", quantLen(s.len or def.h)) end
  if def.proc == "brace" then return braceArrays(quantLen(s.len or def.h)) end
  if def.proc == "panel" then return panelArrays(quantLen(s.w or 1), quantLen(s.d or 1), s.t or def.h or 0.04) end
  return nil
end
local PROF = { tube = { 0.07, 0.07 }, box = { 0.12, 0.07 }, ibeam = { 0.12, 0.13 }, truss = { 0.20, 0.18 }, brace = { 0.035, 0.035 } }
function collider(rec)
  local def, s = sizeOfRec(rec)
  if def.proc == "member" or def.proc == "brace" then
    local p = PROF[s.prof or def.prof or "box"] or PROF.box
    return p[1], (s.len or def.h) * 0.5, p[2]
  end
  if def.proc == "panel" then return (s.w or 1) * 0.5, (s.t or def.h or 0.04) * 0.5, (s.d or 1) * 0.5 end
  return def.rx, (def.h or 1) * 0.5, def.rz
end

-- ── engine side (only when the engine is there) ─────────────────────────────
local cache, builds = {}, 0
local function strip(M) return { positions = M.positions, normals = M.normals, uvs = M.uvs, colors = M.colors, indices = M.indices } end
function meshName(key, fn, env)
  local m = (env and env.mesh) or mesh
  if cache[key] then return cache[key] end
  if not (m and m.build) then return nil end
  local arr = fn()
  if not arr or #arr.indices == 0 then return nil end
  local name = m.build(strip(arr))
  builds = builds + 1
  cache[key] = name
  return name
end
function stats()
  local n = 0
  for _ in pairs(cache) do n = n + 1 end
  return { meshes = n, builds = builds }
end

-- Give a spawned procedural part (`node`, a PartMember / PartPanelP /
-- PartBrace prefab, flight or vis/) its mesh, and its collider when it has a
-- body. Call it in the spawn callback, before any assembly.rebuild.
-- Returns the mesh child's name (or nil for a fixed part).
function dress(node, rec, env)
  local key = keyOf(rec)
  if not (key and node) then return nil end
  env = env or {}
  local cn = env.createNode or createNode
  local name = meshName(key, function() return arraysOf(rec) end, env)
  local getc = node.getComponent or node.getcomponent
  local rb = getc and getc(node, "RigidBody") or nil
  if rb then
    local hx, hy, hz = collider(rec)
    rb.half_x, rb.half_y, rb.half_z = hx, hy, hz
  end
  if name and cn then
    cn("ProcMesh", node, function(c)
      c.model = name
      if c.setMaterial then c:setMaterial(MATERIAL) end
    end)
  end
  return name
end

-- Hang a joint visual (builder_attach's cand.joint / endLink's joint, in the
-- part's local frame) on that part's node.
-- A blueprint carries each joint as ONE string (save.set holds four tables
-- deep; bp -> parts -> rec -> joints is already four). builder.lua's
-- encodeJoint writes it: style|c|ax|u|w|ow|leg|t|hd|hx|hz|prof, vectors "x,y,z".
function decodeJoint(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" then return nil end
  local f = {}
  for x in (s .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
  local function vec(t)
    local a, b, c = (t or ""):match("^([^,]+),([^,]+),([^,]+)$")
    if not a then return nil end
    return { x = tonumber(a), y = tonumber(b), z = tonumber(c) }
  end
  return { style = f[1], c = vec(f[2]), ax = vec(f[3]), u = vec(f[4]), w = vec(f[5]),
           ow = tonumber(f[6]), leg = tonumber(f[7]), t = tonumber(f[8]), hd = tonumber(f[9]),
           held = { hx = tonumber(f[10]), hz = tonumber(f[11]), prof = (f[12] ~= "" and f[12]) or nil } }
end

function dressJoint(node, j, env)
  if type(j) == "string" then j = decodeJoint(j) end
  if not (node and j and j.style) then return nil end
  env = env or {}
  local cn = env.createNode or createNode
  local function r(x) return string.format("%.3f", x or 0) end
  local key = "j:" .. j.style
  for _, f in ipairs({ "c", "ax", "u", "w" }) do
    local p = j[f]
    if p then key = key .. ":" .. r(p.x) .. "," .. r(p.y) .. "," .. r(p.z) end
  end
  key = key .. ":" .. r(j.ow) .. ":" .. r(j.leg) .. ":" .. r(j.hd)
    .. ":" .. r(j.held and j.held.hx) .. ":" .. r(j.held and j.held.hz)
  local name = meshName(key, function() return jointArrays(j) end, env)
  if name and cn then
    cn("Joint", node, function(c)
      c.model = name
      if c.setMaterial then c:setMaterial(MATERIAL) end
    end)
  end
  return name
end
