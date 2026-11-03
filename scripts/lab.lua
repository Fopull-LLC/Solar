-- RESEARCH LAB — the building north of the Commerce Depot where the samples
-- the Materials Intake takes in are studied (2026-11-03). Runs on FacLab's
-- root (tools/gen_base.py, base_buildings lab()); its interior is
-- prefabs/LabInterior (tools/gen_lab.py), spawned by base_facilities with
-- the same origin and rotation.
--
--   * THE TUBE. Every load the intake takes (material_intake.lua) sends a
--     sample up a glass pneumatic tube from the splitter on the intake's roof
--     to the receiving station inside the lab: `receive(mat, qty, rp, first)`
--     launches a capsule (prefabs/LabCapsule, its sample tinted to the
--     material) that you can watch go up the riser, along the outdoor run
--     and in through the wall, under the ceiling and down into the glass
--     receiver. The outdoor run is a mesh built here between the intake's
--     "Tube Out" marker and the lab's "Tube In" (two buildings on a curved
--     world: the exact ends, wherever the layout put them), with couplers
--     and a pipe-rack post.
--   * THE INTERIOR is drawn, lit and simulated only while the crew is in
--     the lab, its link corridor or the depot, or at the outside door; out
--     of doors the whole node is switched off (node.enabled), so the lab
--     costs nothing from the yard. `forceInside` (probes, the talk view)
--     keeps it on.
--   * THE DOORS slide open as the crew comes near them (the lab's pair from
--     the link, the vestibule's, the instrument room's, the link's outside
--     door), and shut behind.
--   * THE SCIENTISTS (prefabs/LabScientist, scripts/scientist.lua) are
--     spawned at their stations in the interior; right-click one, or E at
--     one, to talk (lab_talk.lua).
--
-- FRAMES (docs/positions-and-frames.md). The lab and the intake are
-- parented to their planet, so their node.x/y/z are body-relative and their
-- axes never turn: every point here (the tube's path, the doors' rails) is
-- kept body-relative, and placed against the planet's drawn position the
-- frame it is drawn. Nothing world is kept across frames.

defaults = {
  --- capsule speed along the tube (m/s)
  --@range 1 20 --@units m/s
  speed = 5.5,
  --- the most capsules in the tube at once
  --@range 1 6
  capsules = 4,
  --- a door opens with the crew this near (m)
  --@range 1 6 --@units m
  door_near = 2.8,
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function child(n, name)
  if not valid(n) then return nil end
  for _, c in ipairs(n:children() or {}) do if c.name == name then return c end end
  return nil
end

ROOT = nil
body_name = nil
interior = nil
inside = false            -- (published) the interior is on
forceInside = false       -- probes / the talk view keep it on
crewInLab = false         -- the crew stands in the lab itself (published)
scientists = {}           -- { node, idx } spawned
boards = {}               -- the clipboards they hold
lastReceived = nil        -- { mat, rp, first, t } (the receiving screen, probes)
received = 0              -- capsules that reached the receiver (probes)

-- ── the lab's frame, body-relative ──────────────────────────────────────────
local F = nil             -- { o, ex, ey, ez } (body-relative origin, axes)
local function frame_of(node)
  local w0 = node:toWorld(vec3(0, 0, 0))
  local function dir(x, y, z)
    local p = node:toWorld(vec3(x, y, z))
    return { x = p.x - w0.x, y = p.y - w0.y, z = p.z - w0.z }
  end
  return { o = { x = node.x, y = node.y, z = node.z }, ex = dir(1, 0, 0), ey = dir(0, 1, 0), ez = dir(0, 0, 1) }
end
local function to_body(Fr, lx, ly, lz)
  return { x = Fr.o.x + Fr.ex.x * lx + Fr.ey.x * ly + Fr.ez.x * lz,
           y = Fr.o.y + Fr.ex.y * lx + Fr.ey.y * ly + Fr.ez.y * lz,
           z = Fr.o.z + Fr.ex.z * lx + Fr.ey.z * ly + Fr.ez.z * lz }
end
local function to_local(Fr, p)
  local dx, dy, dz = p.x - Fr.o.x, p.y - Fr.o.y, p.z - Fr.o.z
  return dx * Fr.ex.x + dy * Fr.ex.y + dz * Fr.ex.z,
         dx * Fr.ey.x + dy * Fr.ey.y + dz * Fr.ey.z,
         dx * Fr.ez.x + dy * Fr.ez.y + dz * Fr.ez.z
end
-- (pure, tests) the lab's own box test: is a point (lab-local, the shell's
-- box centre as origin) in a place from which the interior can be seen?
-- The origin sits 4.24 m up and 2.05 m south of the floor's centre.
ZONES = {
  { -11.4, 11.4, -7.6, 7.6 },        -- the lab
  { 6.2, 9.8, 7.0, 17.0 },           -- the link corridor
  { -0.6, 16.6, 16.0, 28.8 },        -- the depot (the link door shows through)
  { 9.4, 16.0, 6.0, 12.5 },          -- outside the link's outside door
}
GROUND_Y = -4.24                     -- the slab's top in the box-centre frame
GROUND_Z = 2.05
function inZone(lx, ly, lz, margin)
  margin = margin or 0
  local gy, gz = ly - GROUND_Y, lz + GROUND_Z      -- from the floor, the ground frame's z
  if gy > 9 or gy < -4 then return false end
  for _, Z in ipairs(ZONES) do
    if lx >= Z[1] - margin and lx <= Z[2] + margin and gz >= Z[3] - margin and gz <= Z[4] + margin then return true end
  end
  return false
end

local function crew()
  local a = find and find("Astronaut")
  return valid(a) and a or nil
end

-- ── the tube ────────────────────────────────────────────────────────────────
local PATH = nil          -- { pts = { body-relative }, s = { cumulative m }, L, indoor_from }
local tube_built = nil    -- { nodes, meshes }

local function catmull(P, n)
  local out = {}
  local Q = { { x = 2 * P[1].x - P[2].x, y = 2 * P[1].y - P[2].y, z = 2 * P[1].z - P[2].z } }
  for _, p in ipairs(P) do Q[#Q + 1] = p end
  local m = #P
  Q[#Q + 1] = { x = 2 * P[m].x - P[m - 1].x, y = 2 * P[m].y - P[m - 1].y, z = 2 * P[m].z - P[m - 1].z }
  local segs = #P - 1
  for i = 0, n - 1 do
    local t = i / (n - 1) * segs
    local j = math.min(math.floor(t), segs - 1)
    local u = t - j
    local p0, p1, p2, p3 = Q[j + 1], Q[j + 2], Q[j + 3], Q[j + 4]
    local function c(a)
      return 0.5 * ((2 * p1[a]) + (-p0[a] + p2[a]) * u + (2 * p0[a] - 5 * p1[a] + 4 * p2[a] - p3[a]) * u * u
        + (-p0[a] + 3 * p1[a] - 3 * p2[a] + p3[a]) * u * u * u)
    end
    out[#out + 1] = { x = c("x"), y = c("y"), z = c("z") }
  end
  return out
end

-- (pure, tests) cumulative lengths of a polyline
function arcLengths(pts)
  local s = { 0 }
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    s[i] = s[i - 1] + len(b.x - a.x, b.y - a.y, b.z - a.z)
  end
  return s
end
-- (pure, tests) the point and direction s metres along it
function along(pts, s, d)
  if d <= 0 then return pts[1], 1 end
  local n = #pts
  if d >= s[n] then return pts[n], n - 1 end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if s[mid] <= d then lo = mid else hi = mid end
  end
  local a, b = pts[lo], pts[lo + 1]
  local t = (d - s[lo]) / math.max(1e-6, s[lo + 1] - s[lo])
  return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }, lo
end

local function unit(v)
  local l = len(v.x, v.y, v.z)
  if l < 1e-9 then return { x = 0, y = 1, z = 0 } end
  return { x = v.x / l, y = v.y / l, z = v.z / l }
end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end

-- The outdoor run: out of the splitter's riser, up, across, and in square
-- to the lab's south wall; then the indoor run from the interior's markers.
local function build_path()
  local intake = find and find("FacIntake")
  if not (valid(intake) and valid(interior) and F) then return nil end
  local to = child(intake, "Tube Out")
  local ti = child(ROOT, "Tube In")
  if not (to and ti) then return nil end
  local Fi = frame_of(intake)
  local P0 = to_body(Fi, to.x, to.y, to.z)
  local up_i = unit(Fi.ey)
  local P1 = to_body(F, ti.x, ti.y, ti.z)
  local ez = unit(F.ez)
  local up_l = unit(F.ey)
  local mid = { x = (P0.x + P1.x) / 2, y = (P0.y + P1.y) / 2, z = (P0.z + P1.z) / 2 }
  local upm = unit({ x = up_i.x + up_l.x, y = up_i.y + up_l.y, z = up_i.z + up_l.z })
  local ctrl = {
    P0,
    { x = P0.x + up_i.x * 1.0, y = P0.y + up_i.y * 1.0, z = P0.z + up_i.z * 1.0 },
    { x = mid.x + upm.x * 0.6, y = mid.y + upm.y * 0.6, z = mid.z + upm.z * 0.6 },
    { x = P1.x + ez.x * 1.6, y = P1.y + ez.y * 1.6, z = P1.z + ez.z * 1.6 },
    P1,
  }
  local pts = catmull(ctrl, 48)
  local outdoor_n = #pts
  for _, nm in ipairs({ "Tube P0", "Tube P1", "Tube P2", "Tube End" }) do
    local c = child(interior, nm)
    if c then pts[#pts + 1] = to_body(F, c.x, c.y, c.z) end
  end
  local s = arcLengths(pts)
  return { pts = pts, s = s, L = s[#s], outdoor_n = outdoor_n, mid = mid, upm = upm }
end

-- The outdoor run's mesh: a glass tube along it, steel couplers, the post.
local function tube_mesh(planet)
  if tube_built or not (PATH and mesh and mesh.build and createNode) then return end
  local O = PATH.pts[1]
  local G = { p = {}, n = {}, uv = {}, i = {}, nv = 0 }
  local S = { p = {}, n = {}, uv = {}, i = {}, nv = 0 }
  local function ring_tube(M, pts, r, segs, uvk)
    local prev_n = nil
    local base = M.nv
    local acc = 0
    for k, p in ipairs(pts) do
      local a = pts[math.max(1, k - 1)]
      local b = pts[math.min(#pts, k + 1)]
      local t = unit({ x = b.x - a.x, y = b.y - a.y, z = b.z - a.z })
      local ref_ = math.abs(t.y) < 0.9 and { x = 0, y = 1, z = 0 } or { x = 1, y = 0, z = 0 }
      local e1 = unit(cross(t, ref_))
      local e2 = cross(t, e1)
      if k > 1 then acc = acc + len(p.x - pts[k - 1].x, p.y - pts[k - 1].y, p.z - pts[k - 1].z) end
      for j = 0, segs do
        local ang = j / segs * 2 * math.pi
        local cx, cy = math.cos(ang), math.sin(ang)
        local nx, ny, nz = e1.x * cx + e2.x * cy, e1.y * cx + e2.y * cy, e1.z * cx + e2.z * cy
        local q = M.nv
        M.p[3 * q + 1], M.p[3 * q + 2], M.p[3 * q + 3] = p.x - O.x + nx * r, p.y - O.y + ny * r, p.z - O.z + nz * r
        M.n[3 * q + 1], M.n[3 * q + 2], M.n[3 * q + 3] = nx, ny, nz
        M.uv[2 * q + 1], M.uv[2 * q + 2] = j / segs, acc * (uvk or 1)
        M.nv = q + 1
      end
    end
    local ring = segs + 1
    for k = 0, #pts - 2 do
      for j = 0, segs - 1 do
        local a = base + k * ring + j + 1
        local b = a + 1
        local c = a + ring
        local d = c + 1
        local i = #M.i
        M.i[i + 1], M.i[i + 2], M.i[i + 3] = a, c, b
        M.i[i + 4], M.i[i + 5], M.i[i + 6] = b, c, d
      end
    end
  end
  local outdoor = {}
  for k = 1, PATH.outdoor_n do outdoor[k] = PATH.pts[k] end
  ring_tube(G, outdoor, 0.125, 20)
  -- couplers every ~2.5 m, and at both ends
  local s = arcLengths(outdoor)
  local L = s[#s]
  local d = 0.05
  while d <= L do
    local p1 = along(outdoor, s, math.max(0, d - 0.05))
    local p2 = along(outdoor, s, math.min(L, d + 0.05))
    ring_tube(S, { p1, p2 }, 0.15, 20)
    d = d + (d < 0.1 and 2.4 or 2.5)
  end
  -- the pipe-rack post under the run's middle: down the averaged vertical to
  -- the ground (a ray, now, kept body-relative), a cross-arm, a base plate
  local b = space.body(body_name)
  local mid = along(outdoor, s, L * 0.55)
  if b and raycast then
    local up = PATH.upm
    local wx, wy, wz = b.x + mid.x, b.y + mid.y, b.z + mid.z
    local ok, h = pcall(raycast, wx, wy, wz, -up.x, -up.y, -up.z, 20.0)
    local depth = (ok and h and h.distance) or 4.0
    local foot = { x = mid.x - up.x * (depth + 0.2), y = mid.y - up.y * (depth + 0.2), z = mid.z - up.z * (depth + 0.2) }
    local top = { x = mid.x - up.x * 0.12, y = mid.y - up.y * 0.12, z = mid.z - up.z * 0.12 }
    ring_tube(S, { foot, top }, 0.06, 12)
    local t = unit({ x = outdoor[#outdoor].x - outdoor[1].x, y = outdoor[#outdoor].y - outdoor[1].y, z = outdoor[#outdoor].z - outdoor[1].z })
    local side = unit(cross(t, up))
    ring_tube(S, { { x = top.x - side.x * 0.3, y = top.y - side.y * 0.3, z = top.z - side.z * 0.3 },
                   { x = top.x + side.x * 0.3, y = top.y + side.y * 0.3, z = top.z + side.z * 0.3 } }, 0.04, 10)
    local g0 = { x = foot.x + up.x * 0.2, y = foot.y + up.y * 0.2, z = foot.z + up.z * 0.2 }
    ring_tube(S, { { x = g0.x - up.x * 0.05, y = g0.y - up.y * 0.05, z = g0.z - up.z * 0.05 },
                   { x = g0.x + up.x * 0.02, y = g0.y + up.y * 0.02, z = g0.z + up.z * 0.02 } }, 0.22, 4)
  end
  tube_built = { nodes = {}, meshes = {} }
  -- (the outdoor run is blended glass, not transmissive: a capsule inside a
  -- refracting tube seen from 15 m was lost in it)
  for _, kv in ipairs({ { "Lab Tube Glass", G, { color = { 0.86, 0.93, 0.96 }, roughness = 0.05, metallic = 0.0,
                                                 alpha = 0.30, blend = "blend", reflectivity = 1.0, shading = "physical" } },
                        { "Lab Tube Steel", S, { texture = "textures/lab/steel_albedo.png",
                                                 roughnessMap = "textures/lab/steel_orm.png", metallicMap = "textures/lab/steel_orm.png",
                                                 color = { 0.85, 0.86, 0.87 }, roughness = 1.0, metallic = 0.85,
                                                 shading = "physical" } } }) do
    local name, M, mat = kv[1], kv[2], kv[3]
    if M.nv > 0 then
      local ok, mname = pcall(mesh.build, { positions = M.p, indices = M.i, normals = M.n, uvs = M.uv })
      if ok and mname then
        tube_built.meshes[#tube_built.meshes + 1] = mname
        createNode(name, planet, function(n)
          n.x, n.y, n.z = O.x, O.y, O.z
          n.model = mname
          pcall(n.setMaterial, n, mat)
          if name == "Lab Tube Glass" then n.castShadow = false end
          tube_built.nodes[#tube_built.nodes + 1] = n
        end)
      end
    end
  end
end

function onDestroy()
  if tube_built and mesh and mesh.free then
    for _, m in ipairs(tube_built.meshes) do pcall(mesh.free, m) end
  end
  tube_built = nil
end

-- ── capsules ────────────────────────────────────────────────────────────────
local pool = {}           -- { node, busy, mat, d, hold, rp, first }
local queue = {}
local pool_making = 0

-- What a material's sample looks like in a capsule (linear colours).
SAMPLE_COLOUR = {
  iron = { 0.30, 0.12, 0.07 }, copper = { 0.18, 0.40, 0.30 }, sulfur = { 0.80, 0.65, 0.10 }, silica = { 0.85, 0.85, 0.82 },
  timber = { 0.42, 0.26, 0.12 }, crystal = { 0.45, 0.30, 0.75 }, uranium = { 0.18, 0.25, 0.10 }, obsidian = { 0.04, 0.04, 0.05 },
  basalt = { 0.12, 0.12, 0.12 }, granite = { 0.55, 0.50, 0.48 }, regolith = { 0.45, 0.43, 0.40 }, soil = { 0.25, 0.17, 0.10 },
  sand = { 0.70, 0.60, 0.40 }, clay = { 0.55, 0.35, 0.22 }, ice = { 0.80, 0.90, 1.0 }, scrap = { 0.55, 0.56, 0.58 },
  geode = { 0.50, 0.40, 0.80 }, salt = { 0.92, 0.92, 0.90 }, hematite = { 0.40, 0.10, 0.06 }, rustrock = { 0.45, 0.20, 0.10 },
}
function sampleColour(mat)
  local c = SAMPLE_COLOUR[mat]
  if c then return c end
  local m = ref("materials")
  local lk = m and m.oreLook and m.oreLook(mat)
  if lk and lk.out and lk.out.c then return lk.out.c end
  if lk and lk.seam then return lk.seam end
  return { 0.5, 0.48, 0.45 }
end

local function free_capsule()
  for _, c in ipairs(pool) do if valid(c.node) and not c.busy then return c end end
  return nil
end

local function launch(job)
  local c = free_capsule()
  if not c then return false end
  c.busy, c.mat, c.d, c.hold, c.rp, c.first = true, job.mat, 0, 0, job.rp, job.first
  local col = sampleColour(job.mat)
  pcall(function()
    local m = c.node:material("LabCapsuleCore")
    if m then m.color = { col[1], col[2], col[3] } end
  end)
  c.node.visible = true
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, "place") end
  return true
end

-- material_intake.lua: a load was taken; a sample goes up the tube.
function receive(mat, qty, rp, first)
  queue[#queue + 1] = { mat = mat, qty = qty, rp = rp or 0, first = first == true }
  while #queue > 8 do table.remove(queue, 1) end
end

local function step_capsules(dt, planet, b)
  if not PATH then return end
  -- the pool, made once
  if #pool + pool_making < (params.capsules or 4) and spawn and planet then
    pool_making = pool_making + 1
    spawn("LabCapsule", vec3(b.x + PATH.pts[1].x, b.y + PATH.pts[1].y, b.z + PATH.pts[1].z), function(n)
      pool_making = pool_making - 1
      n.visible = false
      n.castShadow = false
      pool[#pool + 1] = { node = n, busy = false }
    end, planet)
  end
  if #queue > 0 and launch(queue[1]) then table.remove(queue, 1) end
  local speed = params.speed or 5.5
  for _, c in ipairs(pool) do
    if c.busy and valid(c.node) then
      if c.d < PATH.L then
        -- slower round the bends and into the receiver
        local _, seg = along(PATH.pts, PATH.s, c.d)
        local v = speed
        if c.d > PATH.L - 1.2 then v = math.max(0.8, speed * (PATH.L - c.d) / 1.2) end
        if c.d < 1.0 then v = math.max(1.5, speed * (0.3 + 0.7 * c.d)) end
        c.d = math.min(PATH.L, c.d + v * dt)
        if c.d >= PATH.L then
          received = received + 1
          lastReceived = { mat = c.mat, rp = c.rp, first = c.first, t = time or 0 }
          if audio and audio.play then
            pcall(audio.play, "audio/kenney/impact/impactPlate_light_001.ogg", { track = "SFX", volume = 0.35, pitch = 1.3 })
          end
        end
      else
        c.hold = c.hold + dt
        if c.hold > 2.2 then c.busy = false; c.node.visible = false end
      end
      local p, seg = along(PATH.pts, PATH.s, c.d)
      local a, bb = PATH.pts[seg], PATH.pts[seg + 1]
      local t = unit({ x = bb.x - a.x, y = bb.y - a.y, z = bb.z - a.z })
      c.node.x, c.node.y, c.node.z = p.x, p.y, p.z
      -- outdoors the carrier is the big one the wide run takes, readable from
      -- the yard; it steps down to the indoor bore inside the wall
      local sc = (c.d < PATH.s[PATH.outdoor_n]) and 1.7 or 1.0
      if c.node.scale_x ~= sc then c.node.scale_x, c.node.scale_y, c.node.scale_z = sc, sc, sc end
      local up = math.abs(t.y) < 0.95 and { x = 0, y = 1, z = 0 } or { x = 1, y = 0, z = 0 }
      local sx = unit(cross(up, t))
      local u2 = cross(t, sx)
      pcall(c.node.setUp, c.node, vec3(u2.x, u2.y, u2.z), vec3(t.x, t.y, t.z))
    end
  end
end

-- ── doors ───────────────────────────────────────────────────────────────────
-- { node, rest = {x,y,z} (parent-local), slide = {dx,dy,dz} (parent-local, open), centre (lab-local), open }
local DOORS = nil
local DOOR_DEF = {
  -- name, parent ("int" | "ext"), slide in its parent's frame (m)
  { "Lab Door L", "int", { -0.95, 0, 0.0 } },
  { "Lab Door R", "int", { 0.95, 0, 0.0 } },
  { "Inner Door", "int", { 0.06, 0, 1.12 } },
  { "Instr Door", "int", { 1.12, 0, 0.06 } },
  { "Link Door", "ext", { -0.07, 0, 1.30 } },
}
local function find_doors()
  local out = {}
  for _, d in ipairs(DOOR_DEF) do
    local par = d[2] == "int" and interior or ROOT
    local n = child(par, d[1])
    if n then
      out[#out + 1] = { node = n, rest = { x = n.x, y = n.y, z = n.z }, slide = d[3], open = 0 }
    end
  end
  return out
end
local function step_doors(dt, alx, aly, alz)
  if not DOORS then return end
  for _, d in ipairs(DOORS) do
    if valid(d.node) then
      local cx, cy, cz = d.rest.x, d.rest.y, d.rest.z
      local want = 0
      if alx then
        local dd = len(alx - cx, 0, alz - cz)
        if dd < (params.door_near or 2.8) and math.abs(aly - cy) < 3.0 then want = 1 end
      end
      if forceDoors then want = 1 end
      local k = 1 - math.exp(-6 * dt)
      d.open = d.open + (want - d.open) * k
      local o = d.open
      o = o * o * (3 - 2 * o)
      d.node.x, d.node.y, d.node.z = cx + d.slide[1] * o, cy + d.slide[2] * o, cz + d.slide[3] * o
    end
  end
end
forceDoors = false

-- ── scientists ──────────────────────────────────────────────────────────────
-- Who works here: name (drives the face: crew_faces.lookFor), role, and the
-- station's marker.
STAFF = {
  { name = "Imani Okafor", role = "Sample receiving", spot = "Sci 1", seed = 811 },
  { name = "Felix Haddad", role = "Petrography", spot = "Sci 2", seed = 812 },
  { name = "Hana Nakamura", role = "Wet chemistry", spot = "Sci 3", seed = 813 },
  { name = "Ravi Pillai", role = "Analytical chemistry", spot = "Sci 4", seed = 814, clipboard = true },
}
local sci_spawned = false
local function spawn_scientists()
  if sci_spawned or not (valid(interior) and spawn and F) then return end
  sci_spawned = true
  local b = space.body(body_name)
  if not b then sci_spawned = false return end
  local up = unit(F.ey)
  for i, st in ipairs(STAFF) do
    local spot = child(interior, st.spot)
    local look = child(interior, st.spot .. " Look")
    if spot and look then
      local p = to_body(F, spot.x, spot.y, spot.z)
      local q = to_body(F, look.x, look.y, look.z)
      local f = { x = q.x - p.x, y = q.y - p.y, z = q.z - p.z }
      local dv = f.x * up.x + f.y * up.y + f.z * up.z
      f = unit({ x = f.x - up.x * dv, y = f.y - up.y * dv, z = f.z - up.z * dv })
      local h = 0.99
      local planet = ROOT.parent
      spawn("LabScientist", vec3(b.x + p.x + up.x * h, b.y + p.y + up.y * h, b.z + p.z + up.z * h), function(n)
        n.x, n.y, n.z = p.x + up.x * h, p.y + up.y * h, p.z + up.z * h
        -- the rig looks along its node's +Z (tools/gen_suit.py); setUp's
        -- forward is the node's -Z, so it is handed the way they turn FROM
        pcall(n.setUp, n, vec3(up.x, up.y, up.z), vec3(-f.x, -f.y, -f.z))
        n.name = "LabScientist " .. i
        local sc = n.getScript and n:getScript("scientist")
        if sc and sc.bind then sc.bind(i, st, F, child(interior, st.spot .. " Hands"), look) end
        scientists[#scientists + 1] = { node = n, idx = i, staff = st }
        -- one of them reads a clipboard (theirs: placed in their hands by
        -- scientist.lua each frame)
        if st.clipboard and sc then
          spawn("LabClipboard", vec3(b.x + p.x, b.y + p.y + 1.2, b.z + p.z), function(cb)
            cb.castShadow = false
            sc.holds, sc.board = true, cb
            cb.enabled = inside
            boards[#boards + 1] = cb
          end)
        end
        -- they live in the interior's world: switched off with it
        n.enabled = inside
      end, planet)
    end
  end
end

-- (talk prompt, facility_menu) the scientist the crew stands at, if any:
-- { node, idx, staff, d }
function nearAstro(a, reach)
  a = a or crew()
  if not (a and inside) then return nil end
  local best, bd = nil, reach or 2.2
  for _, s in ipairs(scientists) do
    if valid(s.node) and s.node.enabled ~= false then
      local d = a.distanceTo and a:distanceTo(s.node) or len(a.x - s.node.x, a.y - s.node.y, a.z - s.node.z)
      if d < bd then best, bd = s, d end
    end
  end
  if best then return { node = best.node, idx = best.idx, staff = best.staff, d = bd } end
  return nil
end
function scientistOf(node)
  for _, s in ipairs(scientists) do
    if valid(s.node) and valid(node) and s.node.id == node.id then return s end
  end
  -- a hit on the scientist's model, face or hair: walk up
  local n, k = node, 0
  while valid(n) and k < 4 do
    for _, s in ipairs(scientists) do if valid(s.node) and s.node.id == n.id then return s end end
    n = n.parent
    k = k + 1
  end
  return nil
end

-- ── the frame ───────────────────────────────────────────────────────────────
local look_t = -10
local provider_on = false
function start(node)
  ROOT = node
end

local function find_interior()
  if valid(interior) then return interior end
  for _, n in ipairs((findTagged and findTagged("lab_interior")) or {}) do
    if valid(n) then
      local dx, dy, dz = n.x - ROOT.x, n.y - ROOT.y, n.z - ROOT.z
      if len(dx, dy, dz) < 0.5 then interior = n; return n end
    end
  end
  return nil
end

local function set_inside(on)
  if on == inside then return end
  inside = on
  if valid(interior) then interior.enabled = on end
  for _, s in ipairs(scientists) do if valid(s.node) then s.node.enabled = on end end
  for _, c in ipairs(boards) do if valid(c) then c.enabled = on end end
  if log then log("lab: interior " .. (on and "on" or "off")) end
end

function update(node, dt)
  ROOT = node
  if not body_name and node.parent and node.parent.name then body_name = node.parent.name end
  if not F then F = frame_of(node) end
  if not valid(interior) then
    if (time or 0) - look_t < 0.5 then return end
    look_t = time or 0
    find_interior()
    if not valid(interior) then return end
    -- found it switched on (base_facilities spawns it so): decide now
    inside = true
    set_inside(false)
  end
  if not DOORS then DOORS = find_doors() end
  if not PATH and (time or 0) - look_t > 0.5 then
    look_t = time or 0
    PATH = build_path()
    if PATH then log(string.format("lab: the sample tube is %.1f m (%.1f m outdoors)", PATH.L, PATH.s[PATH.outdoor_n])) end
  end
  if not provider_on then
    local reg = ref("context_registry")
    if reg and reg.register then
      reg.register("prop", function(t, ctx)
        local lt = ref("lab_talk")
        if lt and lt.provider then return lt.provider(t, ctx) end
        return {}
      end, { id = "lab_scientist", order = 3 })
      provider_on = true
    end
  end
  local b = space.body(body_name)
  if not b then return end
  if PATH and not tube_built then tube_mesh(node.parent) end
  -- where the crew is, in the lab's frame (drawn poses: this frame's read of
  -- the planet against this frame's crew)
  local a = crew()
  local alx, aly, alz
  if a then
    alx, aly, alz = to_local(F, { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  end
  local want = forceInside or (alx ~= nil and inZone(alx, aly, alz, inside and 1.5 or 0.0))
  -- (published) the crew is in the lab proper, not the link or the depot:
  -- the depot's prompt and the intake's board stand down in here
  crewInLab = alx ~= nil and alx > ZONES[1][1] and alx < ZONES[1][2] and (alz + GROUND_Z) > ZONES[1][3]
    and (alz + GROUND_Z) < ZONES[1][4] and (aly - GROUND_Y) < 6 and (aly - GROUND_Y) > -2
  set_inside(want)
  if inside then
    spawn_scientists()
    step_doors(dt, alx, aly, alz)
  else
    step_doors(dt, nil)
  end
  step_capsules(dt, node.parent, b)
end

-- ── the receiving station's screen (drawn poses) ────────────────────────────
local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
function lateUpdate(node, dt)
  if not (inside and lastReceived and camera and camera.worldToScreen and camera.screenRect and draw and draw.text) then return end
  local lt = ref("lab_talk")
  if lt and lt.isOpen and lt.isOpen() then return end
  local pm = ref("pause_menu")
  if pm and pm.open then return end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return end
  local endm = child(interior, "Tube End")
  local a = crew()
  if not (endm and a) then return end
  local now = time or 0
  local age = now - lastReceived.t
  if age > 12 then return end
  local pw = node.parent and node.parent.worldPos
  if not pw then return end
  local p = to_body(F, endm.x, endm.y + 0.55, endm.z)
  local wx, wy, wz = pw.x + p.x, pw.y + p.y, pw.z + p.z
  local d = len(a.x - wx, a.y - wy, a.z - wz)
  if d > 9 then return end
  local sx, sy, dep, on = camera.worldToScreen(wx, wy, wz)
  if not (sx and ((dep and dep > 0) or on)) then return end
  local _, _, _, vh = camera.screenRect()
  local k = vh / uiH()
  local mats = ref("materials")
  local nm = (lastReceived.mat == "scrap" and "Scrap") or (mats and mats.label and mats.label(lastReceived.mat)) or lastReceived.mat
  local fade = math.min(1, (12 - age) / 1.0)
  local txt = string.format("RECEIVED  ·  %s  ·  +%d RP%s", string.upper(nm), lastReceived.rp or 0,
    lastReceived.first and "  ·  NEW" or "")
  local size = 14 * k
  local w = #txt * size * 0.52 + size
  draw.rect(sx - w / 2, sy - size, w, size * 1.6, 0.04, 0.05, 0.04, 0.78 * fade, size * 0.3)
  draw.text(sx, sy - size * 0.62, txt, size, 0.64, 0.93, 0.56, fade, "center")
end
