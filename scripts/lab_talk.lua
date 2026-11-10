-- LAB TALK — talking to a scientist in the Research Lab (lab.lua).
--
-- Right-click a scientist (the context menu's "Talk" row), or E standing at
-- one (facility_menu's prompt): the camera eases into a medium shot of them
-- and a small plate comes up beside them —
--
--   RESEARCH · the lab's points (research.lua), the materials studied so
--   far (with units and the points each earned), and the research tree's
--   placeholder: the tree that will spend the points is still to come.
--
-- Click a material and the camera moves in to a close-up of the scientist,
-- who tells you about it (their mouth moving to a talking rhythm: face.lua's
-- jaw and lip channels); on the left a strip shows the material itself —
-- its real in-game model (a rock tinted to the ore, a log, a crystal, a piece
-- of wreckage) slowly turning on a lit stand — and under it its name and the
-- codex's write-up (scripts/codex.lua: data, not UI), scrollable.
--
--   ESC or "◂ Back" returns to the list; ESC again (or walking off, or
--   "Close") ends the talk.
--
-- BODIES (expansion X1, scripts/survey.lua): a second page beside MATERIALS,
-- one row per world of the home system with what the agency knows (SURVEYED
-- or the share of its six layers). Click one: the close-up shows the world
-- as a GLOBE turning on the stand (a 0.3 m sphere in its ground's colour
-- under a shell of its air's), and under it the six layers — the value, or
-- the band and the instrument that would fill it — and the RP earned there.
--
-- COST. The stand (the sample, its key/fill/rim lights and a render-target
-- camera at 256² × 30 Hz, on the "offstage" layer the main camera never
-- draws, 400 m over the lab) exists only while a material is open; the
-- camera node is switched off with it. Nothing runs while no talk is open.
--
-- Runs on the "Lab Talk" UI layer in scenes/system.ron.

defaults = {
  --@range 0.3 3 --@units s
  blend = 0.9,           -- the camera's ease in and out
  --@range 2 8 --@units m
  leave = 4.0,           -- walking this far from the scientist ends the talk
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local el, self_node
local S = { open = false, sci = nil, staff = nil, mat = nil, t0 = 0, talk_until = 0, last_v = nil, scroll = 0,
            page = "mats", body = nil }
viewBody = nil            -- (probes) the world open in the close-up
escTakenAt = -1
openedAt = -10
viewMat = nil             -- (probes) the material open in the close-up

function isOpen() return S.open end
-- (scientist.lua) the station index of who you are talking to, or nil
function talkingTo() return S.open and S.sci and S.sci.idx or nil end

-- ── the shots (drawn poses, this frame) ─────────────────────────────────────
-- The scientist's head (the Face node rides the Head bone) and their facing.
local function head_of(sci)
  local n = sci and sci.node
  if not valid(n) then return nil end
  local face = nil
  for _, c in ipairs(n:children() or {}) do
    if c.name == "LabModel" then
      for _, k in ipairs(c:children() or {}) do if k.name == "Face" then face = k end end
    end
  end
  local h = face and face.worldPos or n:toWorld(vec3(0, 0.72, 0))
  local o = n.worldPos
  local f = n:toWorld(vec3(0, 0, 1))
  local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
  local u = n:toWorld(vec3(0, 1, 0))
  local ux, uy, uz = u.x - o.x, u.y - o.y, u.z - o.z
  local r = n:toWorld(vec3(1, 0, 0))
  local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
  return h, { x = fx, y = fy, z = fz }, { x = ux, y = uy, z = uz }, { x = rx, y = ry, z = rz }
end

-- The facing sign of the model (scientist.lua publishes which way the model
-- looks in its root's frame): +1 = the root's +Z.
local function facing(sci)
  local sc = sci and valid(sci.node) and sci.node.getScript and sci.node:getScript("scientist")
  return (sc and sc.faceSign) or 1
end

-- WHERE THE CAMERA STANDS, per scientist: every one of them faces a bench,
-- a hood or a wall, so a fixed spot in front of them put the camera in the
-- fume hood or through the wall (playtest 2026-11-03). Candidates, in the
-- scientist's own frame (forward, side, rise from the head; preferred
-- first), are tried with a sphere cast from the head out to each spot (and
-- a little past it): the first clear one is the shot. With none clear, the
-- one with the most room, pulled in short of what it hit (a tighter shot).
-- Picked when a shot starts and kept as those three numbers (never a world
-- point); the shot function places it every frame from the head as drawn.
CLOSE_SPOTS = {
  { 0.95, 0.30, 0.02 }, { 0.95, -0.30, 0.02 }, { 0.80, 0.55, 0.02 }, { 0.80, -0.55, 0.02 },
  { 0.55, 0.80, 0.02 }, { 0.55, -0.80, 0.02 }, { 0.25, 0.92, 0.03 }, { 0.25, -0.92, 0.03 },
  { 0.0, 0.95, 0.04 }, { 0.0, -0.95, 0.04 }, { 0.60, 0.15, 0.0 }, { 0.40, 0.55, 0.0 }, { 0.40, -0.55, 0.0 },
}
MEDIUM_SPOTS = {
  { 1.75, -1.25, 0.12 }, { 1.75, 1.25, 0.12 }, { 1.30, -1.60, 0.12 }, { 1.30, 1.60, 0.12 },
  { 0.70, -1.90, 0.14 }, { 0.70, 1.90, 0.14 }, { 0.15, -2.0, 0.16 }, { 0.15, 2.0, 0.16 },
  { -0.40, -1.90, 0.20 }, { -0.40, 1.90, 0.20 }, { 1.10, -0.80, 0.10 }, { 1.10, 0.80, 0.10 },
}
SHOT_R = 0.16                -- the camera's clearance (m)
local function ignore_list(sci)
  local ig = {}
  if sci and valid(sci.node) then
    ig[#ig + 1] = sci.node
    local sc = sci.node.getScript and sci.node:getScript("scientist")
    if sc and valid(sc.board) then ig[#ig + 1] = sc.board end
  end
  local a = find and find("Astronaut")
  if valid(a) then ig[#ig + 1] = a end
  return ig
end
-- The camera point for spot `sp` from head `h` along the scientist's axes.
local function spot_point(h, f, r, u, sp)
  return { x = h.x + f.x * sp[1] + r.x * sp[2] + u.x * sp[3], y = h.y + f.y * sp[1] + r.y * sp[2] + u.y * sp[3],
           z = h.z + f.z * sp[1] + r.z * sp[2] + u.z * sp[3] }
end
-- How far a ball can go from the head toward a spot (its length if clear).
-- (On engine .1406 a cast's `ignore` does not skip the scientist's own static
-- capsule, which the ball starts inside: a hit on an ignored node is stepped
-- past and the cast goes on from there.)
local function room_to(h, c, ig)
  local dx, dy, dz = c.x - h.x, c.y - h.y, c.z - h.z
  local L = len(dx, dy, dz)
  if L < 1e-3 then return 0, 0 end
  dx, dy, dz = dx / L, dy / L, dz / L
  local reach = L + 0.15
  local skip = {}
  for _, n in ipairs(ig) do skip[n.id or n] = true end
  local from = 0
  for _ = 1, 4 do
    local ox, oy, oz = h.x + dx * from, h.y + dy * from, h.z + dz * from
    local ok, hit = pcall(spherecast, vec3(ox, oy, oz), vec3(dx, dy, dz), SHOT_R, reach - from, { ignore = ig, ignoreStart = true })
    if not ok then return 0, L, "err " .. tostring(hit) end
    if not (hit and hit.distance) then return reach, L, "clear" end
    local hn = hit.node
    if hn and skip[hn.id or hn] then
      from = from + hit.distance + 0.5
      if from >= reach then return reach, L, "clear" end
    else
      return from + hit.distance, L, hn and hn.name
    end
  end
  return from, L, "?"
end
-- (probes) the last choice: { close = {i, spot, clear}, medium = {...} }
shotPick = {}
tries = {}           -- (probes) the last pick's casts
function pickSpot(sci, close)
  local h, f, u, r = head_of(sci)
  local list = close and CLOSE_SPOTS or MEDIUM_SPOTS
  if not h then return list[1], 1, false end
  local s = facing(sci)
  f = { x = f.x * s, y = f.y * s, z = f.z * s }
  r = { x = r.x * s, y = r.y * s, z = r.z * s }
  local ig = ignore_list(sci)
  local best, bi, broom = nil, 1, -1
  tries = {}
  -- (the medium shot shows them to the waist: the chest must be in view too,
  -- not only the head; a receiver bell between hid Dr Okafor)
  local chest = { x = h.x - u.x * 0.42, y = h.y - u.y * 0.42, z = h.z - u.z * 0.42 }
  for i, sp in ipairs(list) do
    local c = spot_point(h, f, r, u, sp)
    local room, L, what = room_to(h, c, ig)
    if room >= L + 0.15 - 1e-3 and not close then
      local r2, L2, w2 = room_to(chest, c, ig)
      if r2 < L2 - 0.05 then room, what = math.min(room, r2 * L / math.max(L2, 1e-3)), "chest:" .. tostring(w2) end
    end
    tries[#tries + 1] = string.format("%d:%.2f/%.2f %s", i, room, L, tostring(what))
    if room >= L + 0.15 - 1e-3 then
      shotPick[close and "close" or "medium"] = { i = i, spot = sp, clear = true }
      return sp, i, true
    end
    local frac = room / math.max(L, 1e-3)
    if frac > broom then best, bi, broom = { sp, room, L }, i, frac end
  end
  -- none clear: the roomiest, pulled in short of what it met
  local sp, room, L = best[1], best[2], best[3]
  local k = math.max(0.35, (room - SHOT_R - 0.05) / math.max(L, 1e-3))
  local t = { sp[1] * k, sp[2] * k, sp[3] }
  shotPick[close and "close" or "medium"] = { i = bi, spot = t, clear = false }
  return t, bi, false
end

local function shot_for(close)
  local sp = pickSpot(S.sci, close)
  return function()
    local h, f, u, r = head_of(S.sci)
    if not h then return nil end
    local s = facing(S.sci)
    f = { x = f.x * s, y = f.y * s, z = f.z * s }
    r = { x = r.x * s, y = r.y * s, z = r.z * s }
    local c = spot_point(h, f, r, u, sp)
    -- the framing, along the CAMERA's own right (whichever side it stands):
    -- close, the face on the right third (the strip is on the left); medium,
    -- the scientist on the left third (the plate is on the right)
    local vx, vy, vz = h.x - c.x, h.y - c.y, h.z - c.z
    local cx_, cy_, cz_ = vy * u.z - vz * u.y, vz * u.x - vx * u.z, vx * u.y - vy * u.x
    local cl = len(cx_, cy_, cz_)
    if cl < 1e-6 then cx_, cy_, cz_, cl = r.x, r.y, r.z, 1 end
    cx_, cy_, cz_ = cx_ / cl, cy_ / cl, cz_ / cl
    local d = len(vx, vy, vz)
    local aside, adrop
    if close then aside, adrop = -0.21 * d / 0.99, 0.06 else aside, adrop = 0.47 * d / 2.15, 0.30 end
    local px = h.x + cx_ * aside - u.x * adrop
    local py = h.y + cy_ * aside - u.y * adrop
    local pz = h.z + cz_ * aside - u.z * adrop
    return c.x, c.y, c.z, px, py, pz, u.x, u.y, u.z
  end
end

-- ── the stand: the material turning in front of its own camera ──────────────
local STAND = { alt = 400.0, px = 256, layer = "offstage", bit = 5, dist = 1.15, fov = 0.55 }
local st = { cam = nil, nodes = {}, sample = nil, sample_mat = nil, making = 0, spin = 0, on = false }
local function planet_of_lab()
  local lab = ref("lab")
  local root = lab and lab.ROOT
  return valid(root) and root.parent or nil, root
end
-- The stand's frame: over the lab, along the lab's own up, body-relative.
local function stand_point(lx, ly, lz)
  local planet, root = planet_of_lab()
  if not root then return nil end
  local up = root:toWorld(vec3(0, 1, 0))
  local o = root.worldPos
  local ux, uy, uz = up.x - o.x, up.y - o.y, up.z - o.z
  local f = root:toWorld(vec3(0, 0, 1))
  local fx, fy, fz = f.x - o.x, f.y - o.y, f.z - o.z
  local r = root:toWorld(vec3(1, 0, 0))
  local rx, ry, rz = r.x - o.x, r.y - o.y, r.z - o.z
  local base = { x = root.x + ux * STAND.alt, y = root.y + uy * STAND.alt, z = root.z + uz * STAND.alt }
  return { x = base.x + rx * lx + ux * ly + fx * lz, y = base.y + ry * lx + uy * ly + fy * lz, z = base.z + rz * lx + uz * ly + fz * lz },
         { x = ux, y = uy, z = uz }, { x = fx, y = fy, z = fz }
end
local function set_layer(n, depth)
  depth = depth or 0
  pcall(function() n.layer = STAND.layer end)
  if depth < 4 then
    local ok, kids = pcall(function() return n:children() end)
    if ok and type(kids) == "table" then for _, c in ipairs(kids) do set_layer(c, depth + 1) end end
  end
end

local RIG = {
  { "LabStandKey",  -0.9, 0.9, 0.9, { 1.00, 0.95, 0.86 }, 3.2, 4.0 },
  { "LabStandFill",  1.0, 0.1, 0.8, { 0.80, 0.88, 1.00 }, 1.6, 4.0 },
  { "LabStandRim",   0.3, 0.8, -1.1, { 1.00, 1.00, 1.00 }, 2.6, 4.0 },
}
local function stand_make()
  local planet = planet_of_lab()
  if not (planet and createNode) or st.making > 0 then return end
  if not valid(st.cam) then
    st.making = st.making + 1
    createNode("LabStandCam", planet, function(n)
      st.making = st.making - 1
      st.cam = n
      pcall(function()
        n:setCamera { target = "labsample", width = STAND.px, height = STAND.px, hz = 30, fovY = STAND.fov, active = false,
                      cullMask = 2 ^ STAND.bit, shadows = false, terrain = false, fog = false }
      end)
      n.enabled = st.on
    end)
  end
  for i, L in ipairs(RIG) do
    if not valid(st.nodes[i]) then
      st.making = st.making + 1
      createNode(L[1], planet, function(n)
        st.making = st.making - 1
        st.nodes[i] = n
        pcall(function() n:setPointLight { color = L[5], intensity = L[6], range = L[7] } end)
        n.enabled = st.on
      end)
    end
  end
  local bi = #RIG + 1
  if not valid(st.nodes[bi]) then
    st.making = st.making + 1
    createNode("LabStandBackdrop", planet, function(n)
      st.making = st.making - 1
      st.nodes[bi] = n
      pcall(function()
        n:setPrimitive("Cube", { 0.12, 0.13, 0.13 })
        n:setMaterial { color = { 0.12, 0.13, 0.13 }, unlit = true }
      end)
      set_layer(n)
      n.enabled = st.on
    end)
  end
end

-- Which model shows a material: its codex's `sample`, else by class.
function sampleOf(mat)
  local cx = ref("codex")
  local e = cx and cx.entry and cx.entry(mat)
  if e and e.sample then return e.sample end
  local m = ref("materials")
  local cls = m and m.class and m.class(mat) or "ore"
  if mat == "scrap" then return "Debris" end
  if cls == "flora" then return mat == "timber" and "LooseLog" or "LooseRock" end
  if mat == "crystal" or mat == "geode" then return "LooseCrystal" end
  return "LooseRock"
end

-- How each sample model sits on the stand: its scale, the camera's distance.
SAMPLE_FIT = {
  LooseRock = { scale = 1.0, dist = 1.15 },
  LooseLog = { scale = 0.42, dist = 2.1 },
  LooseCrystal = { scale = 0.55, dist = 1.15 },
  Debris = { scale = 0.6, dist = 2.4 },
}
local function stand_sample(mat)
  if st.sample_mat == mat and valid(st.sample) then return end
  if valid(st.sample) then st.sample:destroy() end
  if valid(st.shell) then st.shell:destroy(); st.shell = nil end
  st.sample, st.sample_mat = nil, mat
  local planet = planet_of_lab()
  local p = stand_point(0, 0, 0)
  if not (planet and p and spawn) then return end
  local b = space.body(planet.name)
  if not b then return end
  local pf = sampleOf(mat)
  spawn(pf, vec3(b.x + p.x, b.y + p.y, b.z + p.z), function(n)
    if st.sample_mat ~= mat then n:destroy() return end
    st.sample = n
    if n.setParent then n:setParent(planet, { keepWorld = false }) end
    n.x, n.y, n.z = p.x, p.y, p.z
    set_layer(n)
    n.castShadow = false
    -- tint the rock to the material (its own texture stays: the grain)
    local lab = ref("lab")
    local c = lab and lab.sampleColour and lab.sampleColour(mat)
    if c and pf == "LooseRock" then
      pcall(n.setMaterial, n, { color = { math.min(1, c[1] * 1.6 + 0.08), math.min(1, c[2] * 1.6 + 0.08), math.min(1, c[3] * 1.6 + 0.08) } })
    end
    -- frame it: each model's size on the stand (a log is cut to a length
    -- that fits; the others as they lie)
    local fit = SAMPLE_FIT[pf] or SAMPLE_FIT.LooseRock
    if fit.scale ~= 1 then n.scale_x, n.scale_y, n.scale_z = fit.scale, fit.scale, fit.scale end
    STAND.dist = fit.dist
  end, { body = false })
end

-- (X1) THE GLOBE: the world on the stand, a sphere in its ground's colour
-- and a thin shell of its air's (no air: none), turning like a sample.
local function stand_globe(name)
  if st.sample_mat == "body:" .. name and valid(st.sample) then return end
  if valid(st.sample) then st.sample:destroy() end
  if valid(st.shell) then st.shell:destroy() end
  st.sample, st.shell, st.sample_mat = nil, nil, "body:" .. name
  local planet = planet_of_lab()
  if not (planet and createNode) then return end
  local w = save and save.get and save.get("world." .. name) or {}
  local pal = type(w.bio) == "table" and type(w.bio.palette) == "table" and w.bio.palette or {}
  local g = (type(w.ground) == "table" and w.ground) or pal.low or pal.rock or { 0.45, 0.42, 0.38 }
  local col = { g[1] or 0.45, g[2] or 0.42, g[3] or 0.38 }
  local key = st.sample_mat
  createNode("LabGlobe", planet, function(n)
    if st.sample_mat ~= key then n:destroy() return end
    st.sample = n
    pcall(function()
      n:setPrimitive("Sphere", col)
      -- the world's own ground: its terrain slot's material (the photo set,
      -- its normals and roughness), else its colour
      local mats = type(w.bio) == "table" and type(w.bio.mats) == "table" and w.bio.mats or {}
      local slot = mats.high or mats.low or mats.rock
      local m = slot and terrain and terrain.slotMaterial and terrain.slotMaterial(slot)
      if type(m) == "table" and m.texture then
        m.shading = m.shading or "physical"
        n:setMaterial(m)
      else
        n:setMaterial { color = { col[1] * 0.7, col[2] * 0.7, col[3] * 0.7 }, roughness = 0.9, shading = "physical",
                        texture = "textures/props/rock_albedo.png", normalMap = "textures/props/rock_normal.png" }
      end
    end)
    n.scale_x, n.scale_y, n.scale_z = 0.36, 0.36, 0.36
    set_layer(n)
    n.castShadow = false
    n.enabled = st.on
  end)
  if (w.atmo or 0) > 0.05 and w.atmoR then
    createNode("LabGlobeAir", planet, function(n)
      if st.sample_mat ~= key then n:destroy() return end
      st.shell = n
      local a = math.min(0.35, 0.12 + 0.25 * (w.atmo or 0))
      pcall(function()
        n:setPrimitive("Sphere", { w.atmoR, w.atmoG, w.atmoB })
        n:setMaterial { color = { w.atmoR, w.atmoG, w.atmoB }, alpha = a, unlit = true }
      end)
      n.scale_x, n.scale_y, n.scale_z = 0.385, 0.385, 0.385
      set_layer(n)
      n.castShadow = false
      n.enabled = st.on
    end)
  end
  STAND.dist = 1.15
end

local function stand_tick(dt, on)
  st.on = on
  if on then stand_make() end
  local planet = planet_of_lab()
  if not planet then return end
  for _, n in ipairs({ st.cam, st.nodes[1], st.nodes[2], st.nodes[3], st.nodes[4], st.sample, st.shell }) do
    if valid(n) and n.enabled ~= on then n.enabled = on end
  end
  if valid(st.shell) then
    local p = stand_point(0, 0, 0)
    if p then st.shell.x, st.shell.y, st.shell.z = p.x, p.y, p.z end
  end
  if not on then return end
  st.spin = (st.spin + (dt or 0) * 0.45) % (2 * math.pi)
  local d = STAND.dist
  local p, up, fwd = stand_point(0, 0, 0)
  if not p then return end
  if valid(st.sample) then
    st.sample.x, st.sample.y, st.sample.z = p.x, p.y, p.z
    local c, s = math.cos(st.spin), math.sin(st.spin)
    local rx, ry, rz = fwd.y * up.z - fwd.z * up.y, fwd.z * up.x - fwd.x * up.z, fwd.x * up.y - fwd.y * up.x
    local fx, fy, fz = fwd.x * c + rx * s, fwd.y * c + ry * s, fwd.z * c + rz * s
    -- a slight tilt so the top shows as it turns
    pcall(st.sample.setUp, st.sample, vec3(up.x + fx * 0.25, up.y + fy * 0.25, up.z + fz * 0.25), vec3(fx, fy, fz))
  end
  if valid(st.cam) then
    local cp = stand_point(0, 0.18 * d, d)
    st.cam.x, st.cam.y, st.cam.z = cp.x, cp.y, cp.z
    local b = space.body(planet.name)
    if b and st.cam.lookAt then
      pcall(st.cam.lookAt, st.cam, vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(up.x, up.y, up.z))
    end
  end
  for i, L in ipairs(RIG) do
    local n = st.nodes[i]
    if valid(n) then
      local q = stand_point(L[2] * d, L[3] * d, L[4] * d)
      n.x, n.y, n.z = q.x, q.y, q.z
    end
  end
  local bd = st.nodes[#RIG + 1]
  if valid(bd) then
    local q = stand_point(0, 0, -1.6 * d)
    bd.x, bd.y, bd.z = q.x, q.y, q.z
    pcall(bd.setUp, bd, vec3(up.x, up.y, up.z), vec3(fwd.x, fwd.y, fwd.z))
    bd.scale_x, bd.scale_y, bd.scale_z = 6 * d, 6 * d, 0.02 * d
  end
end

-- (probes) where the stand's pieces are, lab-relative metres
function standInfo()
  local planet, root = planet_of_lab()
  local function at(n)
    if not valid(n) then return "none" end
    return string.format("(%.1f %.1f %.1f) on=%s layer=%s", n.x - (root and root.x or 0), n.y - (root and root.y or 0),
      n.z - (root and root.z or 0), tostring(n.enabled), tostring(n.layer))
  end
  return string.format("cam %s · sample %s [%s] · dist %.2f", at(st.cam), at(st.sample), tostring(st.sample_mat), STAND.dist)
end

-- ── a soft fill on the scientist's face while you talk (a portrait's fill:
-- the lab's ceiling light alone leaves a face under a brow in shadow) ─────
local fill = { node = nil, making = false }
local function fill_tick(on)
  local planet = planet_of_lab()
  if on and not valid(fill.node) and not fill.making and planet and createNode then
    fill.making = true
    createNode("LabTalkFill", planet, function(n)
      fill.making, fill.node = false, n
      pcall(function() n:setPointLight { color = { 1.0, 0.95, 0.88 }, intensity = 1.1, range = 3.2 } end)
      n.enabled = false
    end)
  end
  local n = fill.node
  if not valid(n) then return end
  if n.enabled ~= on then n.enabled = on end
  if not on or not planet then return end
  local h, f, u, r = head_of(S.sci)
  if not h then return end
  local sg = facing(S.sci)
  local pw = planet.worldPos
  n.x = h.x + f.x * sg * 0.9 + u.x * 0.35 + r.x * 0.25 - pw.x
  n.y = h.y + f.y * sg * 0.9 + u.y * 0.35 + r.y * 0.25 - pw.y
  n.z = h.z + f.z * sg * 0.9 + u.z * 0.35 + r.z * 0.25 - pw.z
end

-- ── talking: the scientist's mouth ──────────────────────────────────────────
local function face_of(sci)
  local n = sci and sci.node
  if not valid(n) then return nil end
  for _, c in ipairs(n:children() or {}) do
    if c.name == "LabModel" then
      for _, k in ipairs(c:children() or {}) do
        if k.name == "Face" then return k.getScript and k:getScript("face") or nil end
      end
    end
  end
  return nil
end
-- (pure, tests) a talking rhythm: syllables of ~0.18 s, phrases of 1.5–3 s
-- with a breath between, jaw and lips; t in seconds, seed per speaker.
function visemes(t, seed)
  seed = seed or 0
  local phrase = 2.2 + 0.8 * math.sin(seed * 1.7)
  local pt = t % (phrase + 0.45)
  if pt > phrase then return { jaw_open = 0.03, lip_up = 0.0, lip_down = 0.0, smile_L = 0.04, smile_R = 0.04 } end
  local syl = 5.6 + 1.2 * math.sin(seed)
  local a = math.abs(math.sin(t * syl * math.pi * 0.5 + math.sin(t * 1.3 + seed) * 0.8))
  local b = 0.5 + 0.5 * math.sin(t * 2.3 + seed * 2)
  local jaw = 0.05 + 0.32 * a * (0.6 + 0.4 * b)
  return {
    jaw_open = jaw,
    lip_down = 0.25 * a,
    lip_up = 0.12 * (1 - a) * b,
    stretch_L = 0.10 * b * (1 - a), stretch_R = 0.10 * b * (1 - a),
    smile_L = 0.06 + 0.05 * b, smile_R = 0.06 + 0.05 * b,
    brow_out_up_L = 0.08 * b, brow_out_up_R = 0.08 * b,
  }
end
local function talk_tick()
  local f = face_of(S.sci)
  if not f then return end
  local now = time or 0
  if S.open and now < S.talk_until then
    local seed = S.staff and S.staff.seed or 0
    f.override = visemes(now - S.t0, seed)
  else
    f.override = nil
  end
end

-- ── the plates ──────────────────────────────────────────────────────────────
local function layer_size()
  local st_ = ref("settings")
  local H = (st_ and st_.designHeight and st_.designHeight()) or 720
  local W = 1280
  if camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw and sh and sh > 0 then W = H * sw / sh end
  end
  return W, H
end

local function money(n) return string.format("%d", math.floor(n + 0.5)) end

-- A wrapped text's height, from its length (a scroll lays its children out
-- by the heights they ask for; "fit" on a wrapped run inside one overlapped
-- the next). per = characters a line at the plate's width, lh = line height.
local function chars(t) local _, n = (t or ""):gsub("[^\128-\191]", ""); return n end
function wrapH(text, per, lh)
  local lines, line = 0, 0
  for word in (text or ""):gmatch("%S+") do
    local w = chars(word) + 1
    if line + w > per and line > 0 then lines = lines + 1; line = 0 end
    line = line + w
  end
  if line > 0 then lines = lines + 1 end
  return math.max(1, lines) * lh + 4
end

-- MATERIALS | BODIES (X1): the two pages of the list
local function page_tabs()
  return { "row", key = "tabs", w = "100%", h = 24, gap = 4, pad = 0, align = "center",
    { "button", key = "tm", style = "panel/choice", w = "grow", h = 24, text = "Materials", textAlign = "center",
      textValign = "center", selected = S.page ~= "bodies" or nil, onClicked = function() S.page = "mats" end },
    { "button", key = "tb", name = "LabTalkBodies", style = "panel/choice", w = "grow", h = 24, text = "Bodies",
      textAlign = "center", textValign = "center", selected = S.page == "bodies" or nil,
      onClicked = function() S.page = "bodies" end } }
end

-- The BODIES list: a row a world of the home system.
local function bodies_rows(sc, H)
  local sv = ref("survey")
  local list = sv and sv.bodies and sv.bodies() or {}
  if #list == 0 then
    local t = "No worlds on record yet."
    sc[#sc + 1] = { "text", key = "none", style = "panel/hint", w = "100%", h = wrapH(t, 62, 15.5), wrap = true, text = t }
  end
  for i, b in ipairs(list) do
    local r = sv.record and sv.record(b.name)
    local k, n = 0, 0
    for _, l in ipairs(sv.LAYERS or {}) do n = n + 1; k = k + ((r and r.L and r.L[l]) or 0) end
    local known = n > 0 and k / n or 0
    local done = known >= 1 - 1e-9
    local name = b.name
    sc[#sc + 1] = { "button", key = "b" .. i, name = i == 1 and "LabTalkBody1" or nil, style = "panel/row", w = "100%", h = 26,
      dir = "row", gap = 6, pad = 4, align = "center",
      onClicked = function() openBody(name) end,
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = (b.parent and "   " or "") .. name, textValign = "center",
        maxLines = 1, overflow = "ellipsis" },
      { "text", key = "p", style = done and "panel/keys" or "panel/cellMuted", w = 92, h = 18,
        text = done and "◆ SURVEYED" or string.format("%d %% known", math.floor(known * 100 + 0.5)),
        textAlign = "end", textValign = "center" },
      { "text", key = "r", style = "panel/keys", w = 54, h = 18, text = (r and (r.rp or 0) >= 1) and string.format("+%d RP", math.floor(r.rp + 0.5)) or "",
        textAlign = "end", textValign = "center" } }
  end
end

local function list_tree(W, H)
  local rs, mats = ref("research"), ref("materials")
  local pts = rs and rs.points and rs.points() or 0
  local list = rs and rs.studiedList and rs.studiedList() or {}
  local staff = S.staff or { name = "Scientist", role = "" }
  local PW = 360
  local rows = {
    { "text", key = "title", style = "panel/heading", w = "100%", h = 20, text = "RESEARCH LAB" },
    { "text", key = "who", style = "panel/label", w = "100%", h = 14,
      text = string.upper("Dr " .. staff.name .. "  ·  " .. (staff.role or "")) },
    { "box", key = "rule0", style = "panel/rule", w = "100%", h = 1 },
    { "col", key = "crt", style = "hud/instrument", w = "100%", h = "fit", gap = 2, pad = 8,
      { "text", key = "l", style = "hud/micro", w = "100%", h = 14, text = "RESEARCH POINTS" },
      { "text", key = "v", style = "hud/valueLg", w = "100%", h = 30, text = money(pts) .. " RP" },
      { "text", key = "l2", style = "hud/micro", w = "100%", h = 14,
        text = string.format("%d KIND%s STUDIED", #list, #list == 1 and "" or "S") } },
    page_tabs(),
    { "text", key = "ml", style = "panel/label", w = "100%", h = 16,
      text = S.page == "bodies" and "WORLDS ON RECORD  ·  click one for its survey" or "MATERIALS STUDIED  ·  click one to ask about it",
      textValign = "end" },
  }
  local sc = { "scroll", key = "list", w = "100%", h = "fit", maxH = math.max(90, H - 590), gap = 2, pad = 0, dir = "column" }
  if S.page == "bodies" then
    bodies_rows(sc, H)
    list = {}
  elseif #list == 0 then
    local t = "Nothing yet. Drop rocks, logs or scrap on the Materials Intake's belt and a sample comes up the tube."
    sc[#sc + 1] = { "text", key = "none", style = "panel/hint", w = "100%", h = wrapH(t, 62, 15.5), wrap = true, text = t }
  end
  for i, r in ipairs(list) do
    local nm = (r.mat == "scrap" and "Scrap & wreckage") or (mats and mats.label and mats.label(r.mat)) or r.mat
    local units = r.mat == "scrap" and string.format("%.0f kg", r.n) or string.format("%d u", math.floor(r.n + 0.5))
    sc[#sc + 1] = { "button", key = "m" .. i, name = i == 1 and "LabTalkFirst" or nil, style = "panel/row", w = "100%", h = 26,
      dir = "row", gap = 6, pad = 4, align = "center",
      onClicked = function() openMaterial(r.mat) end,
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = nm, textValign = "center", maxLines = 1, overflow = "ellipsis" },
      { "text", key = "u", style = "panel/keys", w = 54, h = 18, text = units, textAlign = "end", textValign = "center" },
      { "text", key = "p", style = "panel/keys", w = 58, h = 18, text = string.format("+%d RP", math.floor(r.rp + 0.5)),
        textAlign = "end", textValign = "center" } }
  end
  rows[#rows + 1] = sc
  rows[#rows + 1] = { "box", key = "rule1", style = "panel/rule", w = "100%", h = 1 }
  -- (X6, PLAN §7.4) WHAT RP BUYS: the research that costs points as well as
  -- money. A row's button researches it (two clicks: the first arms it).
  local tree = rs and rs.rpTree and rs.rpTree() or {}
  rows[#rows + 1] = { "text", key = "treel", style = "panel/label", w = "100%", h = 16, textValign = "end",
    text = string.format("WHAT RP BUYS  ·  %d RP spent", rs and rs.rpSpent and rs.rpSpent() or 0) }
  local co = ref("company")
  local tr = { "scroll", key = "tree", w = "100%", h = "fit", maxH = 190, gap = 2, pad = 0, dir = "column" }
  for i, t in ipairs(tree) do
    local price = (rs.priceText and rs.priceText(t.id, co and co.money)) or (t.rp .. " RP")
    local armed = S.armed and S.armed.id == t.id and (time or 0) - S.armed.t < 5
    local btn
    if t.done then
      btn = { "text", key = "s", style = "panel/keys", w = 96, h = 18, text = "✓ RESEARCHED", textAlign = "end", textValign = "center" }
    elseif t.why then
      btn = { "text", key = "s", style = "panel/cellMuted", w = 96, h = 18, text = "LOCKED", textAlign = "end", textValign = "center" }
    else
      btn = { "button", key = "s", name = "LabTree" .. t.id, style = armed and "panel/action" or "panel/secondary", w = 96, h = 22,
        text = armed and "Confirm" or "Research", textAlign = "center", textValign = "center",
        onClicked = function() researchRow(t.id) end }
    end
    local sub = t.done and price or (t.why or price)
    tr[#tr + 1] = { "col", key = "t" .. i, style = "panel/row", w = "100%", h = "fit", gap = 1, pad = 4,
      { "row", key = "a", w = "100%", h = 22, gap = 6, pad = 0, align = "center",
        { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = t.label, textValign = "center", maxLines = 1, overflow = "ellipsis" },
        btn },
      { "text", key = "b", style = "panel/hint", w = "100%", h = wrapH(sub, 62, 15.5), wrap = true, text = sub } }
  end
  if #tree == 0 then tr[#tr + 1] = { "text", key = "none", style = "panel/hint", w = "100%", h = 16, text = "Nothing costs RP yet." } end
  rows[#rows + 1] = tr
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = 26, gap = 6, pad = 0,
    { "text", key = "k", style = "panel/hint", w = "grow", h = 22, text = "ESC  close", textValign = "center" },
    { "button", key = "close", style = "panel/secondary", w = 90, h = 24, text = "Close", textAlign = "center", textValign = "center",
      onClicked = function() close() end } }
  local x = W - PW - 24
  return { "col", key = "labtalk", style = "panel/frame", pin = "topLeft", x = x, y = 70, w = PW, h = "fit",
    gap = 4, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

local function detail_tree(W, H)
  local cx = ref("codex")
  local e = cx and cx.entry and cx.entry(S.mat) or { name = S.mat, summary = "", facts = {} }
  local rs = ref("research")
  local rec = rs and rs.studied and rs.studied()[S.mat]
  local PW = 380
  local img = 300
  local facts = { "scroll", key = "facts", w = "100%", h = "fit", maxH = math.max(120, H - img - 250), gap = 6, pad = 0, dir = "column" }
  for i, f in ipairs(e.facts or {}) do
    local t = "▸  " .. f
    facts[#facts + 1] = { "text", key = "f" .. i, style = "panel/body", w = "100%", h = wrapH(t, 50, 18.5), wrap = true, text = t }
  end
  local sub = e.summary or ""
  local rows = {
    { "col", key = "screen", style = "hud/instrument", w = "100%", h = "fit", pad = 6, align = "center",
      { "image", key = "img", texture = "rt:labsample", w = img, h = img } },
    { "text", key = "name", style = "panel/heading", w = "100%", h = 22, text = string.upper(e.name or S.mat) },
    { "text", key = "stat", style = "panel/label", w = "100%", h = 14,
      text = rec and string.format("STUDIED  ·  %s  ·  +%d RP", S.mat == "scrap" and string.format("%.0f kg", rec.n or 0)
        or string.format("%d units", math.floor((rec.n or 0) + 0.5)), math.floor((rec.rp or 0) + 0.5)) or "" },
    { "box", key = "rule0", style = "panel/rule", w = "100%", h = 1 },
    { "text", key = "sum", style = "panel/title", w = "100%", h = wrapH(sub, 44, 18.5), wrap = true, text = sub },
    facts,
    { "box", key = "rule1", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "foot", w = "100%", h = 26, gap = 6, pad = 0,
      { "button", key = "back", name = "LabTalkBack", style = "panel/secondary", w = 100, h = 24, text = "◂ Back", textAlign = "center",
        textValign = "center", onClicked = function() back() end },
      { "text", key = "k", style = "panel/hint", w = "grow", h = 22, text = "ESC  back to the list", textValign = "center",
        textAlign = "end" } },
  }
  return { "col", key = "labmat", style = "panel/frame", pin = "topLeft", x = 24, y = 40, w = PW, h = "fit",
    gap = 5, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

-- The close-up of a world (X1): the globe, its six layers, the RP earned.
local function detail_body(W, H)
  local sv = ref("survey")
  local list, rec, t = {}, nil, nil
  if sv and sv.rows then
    local ok, l, r, tr = pcall(sv.rows, S.body)
    if ok then list, rec, t = l or {}, r, tr end
  end
  local PW = 380
  local img = 260
  local done = sv and sv.surveyed and rec and sv.surveyed(rec)
  local facts = { "scroll", key = "facts", w = "100%", h = "fit", maxH = math.max(140, H - img - 220), gap = 4, pad = 0, dir = "column" }
  for i, r in ipairs(list) do
    local full = r.v >= 1 - 1e-9
    local line = r.text or "unknown"
    local head = string.format("%s  ·  %s", r.label, full and "measured" or string.format("%d %%", math.floor(r.v * 100 + 0.5)))
    facts[#facts + 1] = { "text", key = "h" .. i, style = "panel/label", w = "100%", h = 15, text = head }
    facts[#facts + 1] = { "text", key = "f" .. i, style = r.text and "panel/body" or "panel/hint", w = "100%", h = wrapH(line, 50, 18.5),
                          wrap = true, text = line }
    if not full then
      local ln = "learn: " .. (r.learn or "")
      facts[#facts + 1] = { "text", key = "l" .. i, style = "panel/hint", w = "100%", h = wrapH(ln, 62, 15.5), wrap = true, text = ln }
    end
  end
  local sub = (t and t.type) and string.format("%s  ·  %s", t.type, done and "SURVEYED" or "being surveyed") or ""
  local rows = {
    { "col", key = "screen", style = "hud/instrument", w = "100%", h = "fit", pad = 6, align = "center",
      { "image", key = "img", texture = "rt:labsample", w = img, h = img } },
    { "text", key = "name", style = "panel/heading", w = "100%", h = 22, text = string.upper(S.body or "") },
    { "text", key = "stat", style = "panel/label", w = "100%", h = 14,
      text = string.upper(sub) .. ((rec and (rec.rp or 0) >= 1) and string.format("  ·  +%d RP", math.floor(rec.rp + 0.5)) or "") },
    { "box", key = "rule0", style = "panel/rule", w = "100%", h = 1 },
    facts,
    { "box", key = "rule1", style = "panel/rule", w = "100%", h = 1 },
    { "row", key = "foot", w = "100%", h = 26, gap = 6, pad = 0,
      { "button", key = "back", name = "LabTalkBack", style = "panel/secondary", w = 100, h = 24, text = "◂ Back", textAlign = "center",
        textValign = "center", onClicked = function() back() end },
      { "text", key = "k", style = "panel/hint", w = "grow", h = 22, text = "ESC  back to the list", textValign = "center",
        textAlign = "end" } },
  }
  return { "col", key = "labbody", style = "panel/frame", pin = "topLeft", x = 24, y = 40, w = PW, h = "fit",
    gap = 5, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

local function redraw(force)
  if not (el and self_node and ui and ui.make) then return end
  local W, H = layer_size()
  local rs = ref("research")
  local sv = ref("survey")
  local v = table.concat({ tostring(S.open), tostring(S.mat), tostring(rs and rs.points and rs.points() or 0),
    tostring(rs and rs.rpSpent and rs.rpSpent() or 0), tostring(S.armed and S.armed.id), tostring(S.armed and math.floor(((time or 0) - S.armed.t) / 5)),
    math.floor(W), math.floor(H), tostring(S.page), tostring(S.body), tostring(sv and sv.version or 0) }, "|")
  if v == S.last_v and not force then return end
  S.last_v = v
  if math.abs((el.width or 0) - W) > 0.5 then el.width = W end
  if math.abs((el.height or 0) - H) > 0.5 then el.height = H end
  if not S.open then
    ui.make(self_node, {})
    return
  end
  ui.make(self_node, { (S.body and detail_body(W, H)) or (S.mat and detail_tree(W, H)) or list_tree(W, H) })
end

-- (X6) a WHAT RP BUYS row's button: the first click arms it, the second researches
function researchRow(id)
  local rs = ref("research")
  if not (rs and rs.unlock) then return false end
  if not (S.armed and S.armed.id == id and (time or 0) - S.armed.t < 5) then
    S.armed = { id = id, t = time or 0 }
    redraw(true)
    return false
  end
  S.armed = nil
  local ok, why = rs.unlock(id)
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, ok and "open" or "denied") end
  if caption then pcall(caption, ok and ("RESEARCH COMPLETE · " .. tostring(why)) or (rs.labelOf(id) .. ": " .. tostring(why)), 4) end
  redraw(true)
  return ok, why
end

-- ── opening and closing ─────────────────────────────────────────────────────
function open(sci)
  if not (sci and valid(sci.node)) then return false end
  local lab = ref("lab")
  if lab then lab.forceInside = true end
  S.open, S.sci, S.staff, S.mat, S.body = true, sci, sci.staff, nil, nil
  viewBody = nil
  S.t0 = time or 0
  S.talk_until = (time or 0) + 2.2         -- a greeting
  openedAt = time or 0
  viewMat = nil
  local pc = ref("planet_camera")
  if pc and pc.setShot then pc.setShot(shot_for(false), params.blend or 0.9) end
  local cm = ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() and cm.close then cm.close() end
  if el then el.visible = true end
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, "open") end
  redraw(true)
  log("lab talk: Dr " .. tostring(S.staff and S.staff.name))
  return true
end

function openMaterial(mat)
  if not S.open then return end
  S.mat = mat
  viewMat = mat
  S.t0 = time or 0
  local cx = ref("codex")
  local e = cx and cx.entry and cx.entry(mat)
  local nchar = #(e and e.summary or "")
  for _, f in ipairs(e and e.facts or {}) do nchar = nchar + #f end
  S.talk_until = (time or 0) + math.min(16, 2.5 + nchar * 0.035)
  local pc = ref("planet_camera")
  if pc and pc.setShot then pc.setShot(shot_for(true), params.blend or 0.9) end
  stand_sample(mat)
  redraw(true)
end

-- (X1) a world's close-up: the globe on the stand, its survey beside it
function openBody(name)
  if not S.open or not name then return end
  S.body, S.mat, S.page = name, nil, "bodies"
  viewBody, viewMat = name, nil
  S.t0 = time or 0
  S.talk_until = (time or 0) + 6
  local pc = ref("planet_camera")
  if pc and pc.setShot then pc.setShot(shot_for(true), params.blend or 0.9) end
  stand_globe(name)
  redraw(true)
end
-- (probes) the BODIES page
function showBodies() if S.open then S.page = "bodies"; S.mat, S.body = nil, nil; redraw(true) end end

function back()
  if not S.open then return end
  S.mat, viewMat = nil, nil
  S.body, viewBody = nil, nil
  S.talk_until = (time or 0) + 0.8
  local pc = ref("planet_camera")
  if pc and pc.setShot then pc.setShot(shot_for(false), params.blend or 0.9) end
  redraw(true)
end

function close()
  if not S.open then return end
  local f = face_of(S.sci)
  if f then f.override = nil end
  S.open, S.mat, viewMat = false, nil, nil
  S.body, viewBody = nil, nil
  local lab = ref("lab")
  if lab then lab.forceInside = false end
  local pc = ref("planet_camera")
  if pc and pc.clearShot then pc.clearShot(params.blend or 0.9) end
  if el then el.visible = false end
  redraw(true)
end

-- The right-click row on a scientist (context_registry "prop", via lab.lua).
function provider(t, ctx)
  local lab = ref("lab")
  local s = lab and lab.scientistOf and t and lab.scientistOf(t.node)
  if not s then return {} end
  local rs = ref("research")
  return {
    { type = "action", id = "talk", label = "Talk — research progress", hint = "E",
      act = function() open({ node = s.node, idx = s.idx, staff = s.staff }) end },
    { type = "info", id = "rp", label = "RESEARCH", value = function()
        return string.format("%d RP", rs and rs.points and rs.points() or 0) end },
  }, "DR " .. string.upper(s.staff and s.staff.name or ""), s.staff and s.staff.role or "Research Lab"
end

-- ── each frame ──────────────────────────────────────────────────────────────
function start(node)
  self_node = node
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
end

function update(node, dt)
  self_node = node
  if not el then el = node:getcomponent("UiElement") end
  stand_tick(dt, S.open and (S.mat ~= nil or S.body ~= nil))
  fill_tick(S.open)
  if not S.open then return end
  talk_tick()
  -- walked off, the scientist gone, the builder or the pause menu up: end it
  local a = find and find("Astronaut")
  local n = S.sci and S.sci.node
  if not (valid(n) and a) then close() return end
  local d = a.distanceTo and a:distanceTo(n) or len(a.x - n.x, a.y - n.y, a.z - n.z)
  if d > (params.leave or 4.0) then close() return end
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then close() return end
  if input and input.pressed and input.pressed("escape") then
    escTakenAt = time
    if S.mat or S.body then back() else close() end
    return
  end
  redraw(false)
end
