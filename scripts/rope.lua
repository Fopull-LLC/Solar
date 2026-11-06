-- ROPE — a planted Rope Kit's line, drawn (prefabs/RopePylon's script).
--
-- The davit is a deployables record (kind "rope"); this script finds which
-- one it is (deployables.claim), asks scripts/rope_climb.lua for the line's
-- layout (where it fell: straight down, along a face, onto the ground), and
-- builds the line as one mesh (mesh.build: a tube with its braid texture's v
-- along the length) on a child node in the davit's own frame, so the planet
-- carries it with the davit and nothing here is a world point. A line that
-- lies on the ground ends in a short tail across it; one that ends in the air
-- has a stopper knot and swings a little, slow as a pendulum its length.
--
-- It also makes sure the climbing library is in the scene (a RopeLib node).

defaults = {
  -- The line drawn a touch fatter than its 11 mm, so it holds together at a
  -- distance instead of breaking into pixels.
  --@range 0.003 0.03 --@units m
  draw_r = 0.0075,
  --@range 0 3 --@units deg
  sway = 0.5,
}

local SIDES = 6
local V_M = 0.12          -- m of line per texture repeat (tools/gen_rope.py ROPE_V_M)
local MAT = { texture = "textures/items/rope_static_albedo.png", normalMap = "textures/items/rope_static_normal.png",
              roughnessMap = "textures/items/rope_static_orm.png", occlusionMap = "textures/items/rope_static_orm.png",
              shading = "physical", roughness = 1.0, metallic = 0.0, color = { 1, 1, 1 } }

local id = nil
local built = nil         -- { ver, node, mesh, free }
local building = false
local lib_t = -10
local seen_t = -10

local function lib()
  return findScript and findScript("rope_climb") or nil
end

local function ensure_lib()
  if (time or 0) - lib_t < 2.0 then return end
  lib_t = time or 0
  if find and find("RopeLib") then return end
  if lib() then return end
  pcall(spawn, "RopeLib", vec3(0, 0, 0))
end

local function v3(x, y, z) return { x, y, z } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function unit(a)
  local l = math.sqrt(dot(a, a))
  if l < 1e-9 then return { 0, 1, 0 }, 0 end
  return { a[1] / l, a[2] / l, a[3] / l }, l
end

-- The tube's lists along `pts` (local frame), radius r.
local function tube(pts, r)
  local P, N, UV, I = {}, {}, {}, {}
  local n = #pts
  local T = {}
  for i = 1, n do
    T[i] = unit(sub(pts[math.min(n, i + 1)], pts[math.max(1, i - 1)]))
  end
  local ref = math.abs(T[1][2]) < 0.9 and { 0, 1, 0 } or { 1, 0, 0 }
  local nrm = unit(cross(T[1], ref))
  local s = 0
  for i = 1, n do
    if i > 1 then
      local _, l = unit(sub(pts[i], pts[i - 1]))
      s = s + l
      local d = dot(nrm, T[i])
      nrm = unit({ nrm[1] - T[i][1] * d, nrm[2] - T[i][2] * d, nrm[3] - T[i][3] * d })
    end
    local bi = cross(T[i], nrm)
    for k = 0, SIDES do
      local a = 2 * math.pi * k / SIDES
      local c, sn = math.cos(a), math.sin(a)
      local dx, dy, dz = nrm[1] * c + bi[1] * sn, nrm[2] * c + bi[2] * sn, nrm[3] * c + bi[3] * sn
      local p = pts[i]
      P[#P + 1], P[#P + 2], P[#P + 3] = p[1] + dx * r, p[2] + dy * r, p[3] + dz * r
      N[#N + 1], N[#N + 2], N[#N + 3] = dx, dy, dz
      UV[#UV + 1], UV[#UV + 2] = k / SIDES, s / V_M
    end
  end
  local row = SIDES + 1
  for i = 0, n - 2 do
    for k = 0, SIDES - 1 do
      local a0 = i * row + k + 1
      local b0 = (i + 1) * row + k + 1
      -- counter-clockwise seen from outside
      I[#I + 1], I[#I + 2], I[#I + 3] = a0, a0 + 1, b0 + 1
      I[#I + 1], I[#I + 2], I[#I + 3] = a0, b0 + 1, b0
    end
  end
  return P, N, UV, I
end

local function drop_old()
  if built and built.node and built.node.valid ~= false then built.node:destroy() end
  if built and built.mesh and mesh and mesh.free then pcall(mesh.free, built.mesh) end
  built = nil
end

local function build(node, L, ver)
  if not (mesh and mesh.build and createNode and node.toWorld) then return end
  -- the davit's own axes (its rotation only: the planet translates, never turns)
  local o = node:toWorld(vec3(0, 0, 0))
  local X = node:toWorld(vec3(1, 0, 0)) - o
  local Y = node:toWorld(vec3(0, 1, 0)) - o
  local Z = node:toWorld(vec3(0, 0, 1)) - o
  local root = { node.x, node.y, node.z }   -- body-relative (a child of its planet)
  local function loc(p)
    local d = sub(p, root)
    return { d[1] * X.x + d[2] * X.y + d[3] * X.z, d[1] * Y.x + d[2] * Y.y + d[3] * Y.z, d[1] * Z.x + d[2] * Z.y + d[3] * Z.z }
  end
  local p = L.p
  local pts = {}
  for i = 1, #p, 3 do pts[#pts + 1] = loc({ p[i], p[i + 1], p[i + 2] }) end
  local first = pts[1]
  for i, q in ipairs(pts) do pts[i] = sub(q, first) end
  -- the end: a tail across the ground, or a stopper knot in the air
  local n = #pts
  local last = pts[n]
  if L.g and n >= 2 then
    local a = L.a
    local j = #a - 2
    local away = loc({ root[1] + a[j], root[2] + a[j + 1], root[3] + a[j + 2] })
    local up = loc({ root[1] + L.u[1], root[2] + L.u[2], root[3] + L.u[3] })
    local side = cross(up, away)
    pts[#pts + 1] = { last[1] + away[1] * 0.35 + up[1] * 0.01, last[2] + away[2] * 0.35 + up[2] * 0.01,
                      last[3] + away[3] * 0.35 + up[3] * 0.01 }
    pts[#pts + 1] = { last[1] + away[1] * 0.75 + side[1] * 0.25 + up[1] * 0.01,
                      last[2] + away[2] * 0.75 + side[2] * 0.25 + up[2] * 0.01,
                      last[3] + away[3] * 0.75 + side[3] * 0.25 + up[3] * 0.01 }
  end
  local r = (params and params.draw_r) or 0.0075
  local P, N, UV, I = tube(pts, r)
  if not L.g and n >= 2 then
    -- the stopper knot: a fat little barrel just above the end
    local knot = { { last[1], last[2] + 0.25, last[3] }, { last[1], last[2] + 0.12, last[3] } }
    local P2, N2, UV2, I2 = tube(knot, r * 2.6)
    local base = #P / 3
    for _, v in ipairs(P2) do P[#P + 1] = v end
    for _, v in ipairs(N2) do N[#N + 1] = v end
    for _, v in ipairs(UV2) do UV[#UV + 1] = v end
    for _, v in ipairs(I2) do I[#I + 1] = v + base end
  end
  local ok, name = pcall(mesh.build, { positions = P, normals = N, uvs = UV, indices = I, owner = node })
  if not ok or not name then
    if log then log("rope: the line's mesh wouldn't build: " .. tostring(name)) end
    return
  end
  drop_old()
  building = true
  built = { ver = ver, mesh = name, free = not L.g, len = L.total }
  createNode("Rope Line", node, function(c)
    building = false
    if not (built and built.mesh == name) then c:destroy() return end
    c.model = name
    c:setMaterial(MAT)
    c.x, c.y, c.z = first[1], first[2], first[3]
    built.node = c
  end)
end

function start(node)
  ensure_lib()
end

function update(node, dt)
  ensure_lib()
  local dep = findScript and findScript("deployables")
  if not dep then return end
  if not id then
    if dep.claim then id = dep.claim(node) end
    if not id then return end
  end
  local rc = lib()
  if not rc then return end
  local ver = rc.version or 0
  if built and built.ver == ver then
    -- sway, only a line that hangs free and that nobody is on
    local c = built.node
    if c and c.valid ~= false and built.free then
      local st = rc.state and rc.state()
      local amp = (st and st.id == id) and 0 or math.rad((params and params.sway) or 0.5)
      local w = math.sqrt(9.8 / math.max(2, built.len or 10))
      local t = time or 0
      c.pitch = amp * math.sin(w * t + id)
      c.roll = amp * 0.6 * math.sin(w * 0.83 * t + id * 2.1)
    end
    return
  end
  if building then return end
  if (time or 0) - seen_t < 0.5 then return end
  seen_t = time or 0
  local L = rc.layoutOf and rc.layoutOf(id)
  if L then build(node, L, ver) end
end

function onDestroy(node)
  if built and built.mesh and mesh and mesh.free then pcall(mesh.free, built.mesh) end
  built = nil
end
