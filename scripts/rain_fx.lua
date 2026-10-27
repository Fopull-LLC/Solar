-- RAIN FX — rain on the ground: wet surfaces, puddles that mirror the sky,
-- ripples in them and the spray of drops landing round the camera.
--
-- All of it is one screen pass on the Post Processing node (system.ron), read
-- from the frame's depth: shaders/rainFx.flsl (Medium), rainFxHigh.flsl (High,
-- Ultra), rainWet.flsl (Low: the wet look and the puddles, no drops), written
-- by tools/gen_rain_fx.py, which says how. Nothing is spawned and nothing
-- collides: a splash is drawn wherever a drop would land on anything flat the
-- camera sees, the ground, the pad, a hull, a helmet, and the pass costs the
-- same in a drizzle as in a cloudburst. Out of the rain it is switched off and
-- costs nothing.
--
-- This script decides how much: how hard it is raining (weather.lua), how WET
-- things are (the ground takes the best part of a minute of heavy rain to wet
-- through, and minutes to dry once it stops), how big the puddles have grown
-- (they fill over minutes of rain), and where the drops land. The drops and
-- puddles are laid out in the PLANET's frame, not the world's: the home world
-- moves metres a tick, and a pattern in world space would slide across the
-- ground. So the anchor (a point on the ground near the camera, re-picked when
-- the camera has gone a hundred metres) is kept in the planet's frame and sent
-- through the planet node's pose every frame, in lateUpdate, which is the pose
-- the frame is drawn with.
--
-- Off: on the map, in the cockpit, in the VAB, under water, indoors (the
-- weather's roof ray), from 400 m up, and on a world (or in weather) with no
-- rain and nothing still wet.
--
-- Cross-script:  local rf = findScript("rain_fx")
--                rf.state   { on, rate, wet, puddles, shader }
--                rf.setWet(w, p)   wet and puddles now (probes; nil lets go)
--                rf.setOn(bool)    a switch for a settings screen
--                rf.field          the drop field this frame, flat (see build_field)
--                rf.setCompute(v)  the GPU rain rings on/off (nil: the param)

defaults = {
  --- Master switch.
  on = true,
  --- Seconds of the heaviest rain to wet the ground through.
  --@range 5 300
  wetIn = 40.0,
  --- Seconds for wet ground to dry once the rain stops.
  --@range 10 1200
  dryOut = 240.0,
  --- Seconds of the heaviest rain to fill the puddles.
  --@range 10 1200
  puddleIn = 150.0,
  --- How far out (m) the splashes are drawn, at Medium; High draws further.
  --@range 5 60
  reach = 22.0,
  --- Print the state once a second.
  debug = false,
  --- PROTOTYPE: rain rings simulated on the GPU (shaders/rainRipples.wgsl) and
  --- laid round the camera as a decal. Off by default.
  computeRipples = false,
}

local SHADERS = { "rainFx", "rainFxHigh", "rainWet" }
local BY_LEVEL = { Low = "rainWet", Medium = "rainFx", High = "rainFxHigh", Ultra = "rainFxHigh" }

local sqrt, max, min = math.sqrt, math.max, math.min
local function clamp01(x) return max(0.0, min(1.0, x)) end

state = { on = false, rate = 0, wet = 0, puddles = 0, shader = nil }
local wet, puddles = 0.0, 0.0
local forced = nil            -- { w, p } from setWet
local user_on = true
local shown = {}              -- shader name -> on (what was last sent)
local first = true

local refs, refs_t = {}, -100
local function refresh()
  if time - refs_t < 1.0 then return end
  refs_t = time
  for _, k in ipairs({ "weather", "graphics", "planet_camera", "orbit_map", "game_manager", "climate" }) do
    local r = refs[k]
    if not (r and r.valid ~= false) then refs[k] = findScript and findScript(k) or nil end
  end
end

function setWet(w, p)
  if w == nil then forced = nil; return end
  forced = { w = clamp01(w), p = clamp01(p or w) }
end

function setOn(v) user_on = v ~= false end

local function show(node, which)
  for _, n in ipairs(SHADERS) do
    local want = (n == which)
    if shown[n] ~= want then
      shown[n] = want
      pcall(node.setScreenShader, node, n, want)
    end
  end
  state.shader = which
end

-- ── the anchor, in the planet's frame ───────────────────────────────────────
-- anc = { body, lx, ly, lz (m, planet-local), ex.., nx.., ux.. (planet-local
-- unit axes of the tangent plane) }
local anc = nil
local lit = nil

local function planet_axes(n)
  local o = n:toWorld(vec3(0, 0, 0))
  local a = n:toWorld(vec3(1, 0, 0))
  local b = n:toWorld(vec3(0, 1, 0))
  local c = n:toWorld(vec3(0, 0, 1))
  local function unit(p)
    local x, y, z = p.x - o.x, p.y - o.y, p.z - o.z
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-9 then return 0, 0, 0 end
    return x / l, y / l, z / l
  end
  local xx, xy, xz = unit(a)
  local yx, yy, yz = unit(b)
  local zx, zy, zz = unit(c)
  return o, { xx, xy, xz }, { yx, yy, yz }, { zx, zy, zz }
end

local function to_world(X, Y, Z, lx, ly, lz)
  return X[1] * lx + Y[1] * ly + Z[1] * lz, X[2] * lx + Y[2] * ly + Z[2] * lz, X[3] * lx + Y[3] * ly + Z[3] * lz
end

local function place_anchor(name, b, cx, cy, cz, o, X, Y, Z)
  -- the camera in the planet's frame, metres
  local dx, dy, dz = cx - o.x, cy - o.y, cz - o.z
  local lx = dx * X[1] + dy * X[2] + dz * X[3]
  local ly = dx * Y[1] + dy * Y[2] + dz * Y[3]
  local lz = dx * Z[1] + dy * Z[2] + dz * Z[3]
  local l = sqrt(lx * lx + ly * ly + lz * lz)
  if l < 1 then return nil end
  local ux, uy, uz = lx / l, ly / l, lz / l
  -- a tangent pair: any axis not along up
  local hx, hy, hz = 0, 1, 0
  if math.abs(uy) > 0.9 then hx, hy, hz = 1, 0, 0 end
  local ex, ey, ez = hy * uz - hz * uy, hz * ux - hx * uz, hx * uy - hy * ux
  local el = sqrt(ex * ex + ey * ey + ez * ez)
  ex, ey, ez = ex / el, ey / el, ez / el
  local nx, ny, nz = uy * ez - uz * ey, uz * ex - ux * ez, ux * ey - uy * ex
  local r = b.radius or l
  return { body = name, lx = ux * r, ly = uy * r, lz = uz * r, e = { ex, ey, ez }, n = { nx, ny, nz }, u = { ux, uy, uz } }
end

-- ── the drop field: placement, as flat data ─────────────────────────────────
-- Everything that says WHERE and WHEN drops land is in one flat array of
-- numbers, built here and only uploaded by draw_field: the anchor and its
-- tangent frame (world), the planet's axes, the rate, wetness and reach, the
-- light, the haze, and the drop grids (cell size, period, offset). The shader
-- turns it into pictures; it holds no state of its own. A compute pass (the
-- engine's coming gpu.buffer / compute.run) can take this same array as its
-- input and simulate the drops into a buffer instead, with no change to how
-- the field is placed. GRIDS are the drop grids per shader: { cell m, period
-- s, offset x, offset y }, overlaid so no lattice shows.
GRIDS = {
  rainFx     = { { 0.45, 0.95, 0.0, 0.0 }, { 0.6, 1.27, 0.37, 0.71 } },
  rainFxHigh = { { 0.42, 0.9, 0.0, 0.0 }, { 0.56, 1.13, 0.37, 0.71 }, { 0.73, 1.41, 0.13, 0.53 } },
  rainWet    = {},
}
-- the slots of `field` (each a run of numbers)
ANCHOR, AXE, AXN, AXU, PX, PY, PZ, ALOC = 1, 4, 7, 10, 13, 16, 19, 22
RAIN, SKY, DROP, FOG, GRID = 25, 29, 32, 35, 38
field = {}
for i = 1, GRID + 3 * 4 - 1 do field[i] = 0 end
local UNIFORMS = {   -- name, slot, lanes
  { "anchor", ANCHOR, 3 }, { "axisE", AXE, 3 }, { "axisN", AXN, 3 }, { "axisU", AXU, 3 },
  { "planetX", PX, 3 }, { "planetY", PY, 3 }, { "planetZ", PZ, 3 }, { "anchorLocal", ALOC, 3 },
  { "rain", RAIN, 4 }, { "sky", SKY, 3 }, { "drop", DROP, 3 }, { "fog", FOG, 3 },
}

local function put3(at, x, y, z) field[at], field[at + 1], field[at + 2] = x, y, z end

-- The field for this frame, from the anchor (kept in the planet's frame),
-- the planet's pose this frame and the weather.
function build_field(which, rate, po, X, Y, Z)
  local ax, ay, az = to_world(X, Y, Z, anc.lx, anc.ly, anc.lz)
  put3(ANCHOR, po.x + ax, po.y + ay, po.z + az)
  put3(AXE, to_world(X, Y, Z, anc.e[1], anc.e[2], anc.e[3]))
  put3(AXN, to_world(X, Y, Z, anc.n[1], anc.n[2], anc.n[3]))
  put3(AXU, to_world(X, Y, Z, anc.u[1], anc.u[2], anc.u[3]))
  put3(PX, X[1], X[2], X[3]); put3(PY, Y[1], Y[2], Y[3]); put3(PZ, Z[1], Z[2], Z[3])
  put3(ALOC, anc.lx, anc.ly, anc.lz)
  -- the drops: a cell fires at the rain rate (a drizzle is a scatter, a
  -- downpour lands everywhere at once)
  field[RAIN], field[RAIN + 1], field[RAIN + 2] = min(1, rate * 1.1), wet, puddles
  field[RAIN + 3] = (params.reach or 22) * ((which == "rainFxHigh") and 1.35 or 1)
  -- what wet ground mirrors and the light the drops are seen by: the haze's
  -- colour, which atmosphere.lua keeps as the horizon's
  if not lit then
    local ln = find("Lighting")
    lit = ln and ln:getcomponent("Light") or nil
  end
  local fr, fg, fb = 0.5, 0.55, 0.6
  local fs, fe, fd = 1e5, 2e5, 0
  if lit then
    fr, fg, fb = lit.fogColorR or fr, lit.fogColorG or fg, lit.fogColorB or fb
    if lit.fog then
      if lit.fogVolumetric then fd = lit.fogDensity or 0
      else fs, fe = lit.fogStart or fs, lit.fogEnd or fe end
    end
  end
  put3(SKY, fr, fg, fb)
  put3(DROP, fr * 1.25, fg * 1.25, fb * 1.25)
  put3(FOG, fs, max(fe, fs + 1), fd)
  local g = GRIDS[which] or {}
  for i = 1, 3 do
    local e = g[i]
    for j = 1, 4 do field[GRID + (i - 1) * 4 + j - 1] = e and e[j] or 0 end
  end
  field.n = #g
end

-- The drawing: upload the field to the pass that draws it.
local unpack = table.unpack or unpack
function draw_field(node, which)
  local S = which .. "."
  for _, u in ipairs(UNIFORMS) do
    if which ~= "rainWet" or u[1] ~= "drop" then
      node:setShaderParam(S .. u[1], unpack(field, u[2], u[2] + u[3] - 1))
    end
  end
  for i = 1, field.n or 0 do
    local at = GRID + (i - 1) * 4
    node:setShaderParam(S .. "grid" .. (i - 1), field[at], field[at + 1], field[at + 2], field[at + 3])
  end
end

-- ── rain rings on the GPU (PROTOTYPE, `computeRipples`, off by default) ─────
-- A wave field (shaders/rainRipples.wgsl: `emit` + `step` 60 times a second, `shade`
-- once a frame into a gpu.texture) drawn as one decal RR_SIZE m across on the
-- ground under the camera, so the rings lie on the ground, the pad or a hull
-- and are lit like them. The patch is laid where the camera is and laid again
-- when the camera has gone a quarter of it away (the decal rides the planet on
-- its own); the new one replaces the old once it has landed, and the field
-- starts again then. setCompute(true/false/nil) overrides the param (probes).
local RR_N, RR_SIZE, RR_HZ, RR_CELLS = 512, 16.0, 60, 32   -- cells: a 0.5 m drop lattice
local RR, compute_on = nil, nil
local RR_SH = "shaders/rainRipples.wgsl"
function setCompute(v) compute_on = v end
function ripplesState() return RR end   -- (probes)
local rr_test = false
function setRippleTest(v) rr_test = v and true or false end   -- (probes: solid magenta)
local function rr_free()
  if not RR then return end
  if RR.decal then pcall(decals.remove, RR.decal) end
  if RR.next then pcall(decals.remove, RR.next) end
  for _, k in ipairs({ "cur", "prev", "tex" }) do if RR[k] then pcall(gpu.free, RR[k]) end end
  RR = nil
end
local function rr_frame(dt, rate, po, X, Y, Z, cx, cy, cz)
  if RR and RR.dead then return end
  if not RR then
    local cur = gpu and gpu.buffer and gpu.buffer { count = RR_N * RR_N, type = "f32" }
    if not cur then RR = { dead = true }; return end
    RR = { cur = cur, prev = gpu.buffer { count = RR_N * RR_N, type = "f32" }, tex = gpu.texture { w = RR_N, h = RR_N },
           acc = 0, t = 0, seed = 0, born = 0 }
  end
  -- (a decal laid the frame its gpu texture is made finds no such picture and
  -- never draws: the texture is registered after the decal pages are built)
  RR.born = RR.born + 1
  if RR.born < 3 then return end
  -- the ground under the camera, in the planet's frame
  local dx, dy, dz = cx - po.x, cy - po.y, cz - po.z
  local lx = dx * X[1] + dy * X[2] + dz * X[3]
  local ly = dx * Y[1] + dy * Y[2] + dz * Y[3]
  local lz = dx * Z[1] + dy * Z[2] + dz * Z[3]
  local l = sqrt(lx * lx + ly * ly + lz * lz)
  if l < 1 then return end
  local ux, uy, uz = lx / l, ly / l, lz / l
  local g = l
  -- the ground under the camera: the field's own surface (terrain.query is a
  -- clamped distance, and reads "inside" on graded ground), else the camera
  local wux, wuy, wuz = to_world(X, Y, Z, ux, uy, uz)
  local hit = terrain.raycast and terrain.raycast(vec3(cx + wux * 2, cy + wuy * 2, cz + wuz * 2), vec3(-wux, -wuy, -wuz), 60)
  if hit and hit.pos then
    local hx_, hy_, hz_ = hit.pos.x - po.x, hit.pos.y - po.y, hit.pos.z - po.z
    g = sqrt(hx_ * hx_ + hy_ * hy_ + hz_ * hz_)
  end
  local gx_, gy_, gz_ = ux * g, uy * g, uz * g
  local c = RR.centre
  local far = not c or (c[1] - gx_) ^ 2 + (c[2] - gy_) ^ 2 + (c[3] - gz_) ^ 2 > (RR_SIZE * 0.25) ^ 2
  if far and not RR.next then
    local wx, wy, wz = to_world(X, Y, Z, gx_, gy_, gz_)
    local nx, ny, nz = to_world(X, Y, Z, ux, uy, uz)
    local hx, hy, hz = 0, 1, 0
    if math.abs(uy) > 0.9 then hx, hy, hz = 1, 0, 0 end
    local tx, ty, tz = to_world(X, Y, Z, hy * uz - hz * uy, hz * ux - hx * uz, hx * uy - hy * ux)
    local ok, id = pcall(decals.add, { texture = RR.tex.name, pos = vec3(po.x + wx, po.y + wy, po.z + wz),
      normal = vec3(nx, ny, nz), up = vec3(tx, ty, tz), size = RR_SIZE, depth = 6 })
    RR.laid = { ok = ok, id = id, q = l - g }
    if ok and id then RR.next, RR.nextCentre = id, { gx_, gy_, gz_ } end
  end
  if RR.next and decals.landed(RR.next) ~= false then
    if RR.decal then pcall(decals.remove, RR.decal) end
    RR.decal, RR.centre, RR.next = (decals.landed(RR.next) and RR.next) or nil, RR.nextCentre, nil
    RR.seed = RR.seed + 1
    compute.run(RR_SH, "clear", { size = { RR_N, RR_N }, bind = { cur = RR.cur, prev = RR.prev }, params = { n = RR_N } })
  end
  if not RR.decal then return end
  -- the field: RR_HZ steps a second whatever the frame rate (at most 4 a frame)
  RR.acc = min(RR.acc + dt, 4 / RR_HZ)
  local sd = RR.seed * 17.31
  while RR.acc >= 1 / RR_HZ do
    RR.acc = RR.acc - 1 / RR_HZ
    compute.run(RR_SH, "emit", { size = { RR_CELLS, RR_CELLS }, bind = { cur = RR.cur }, params = {
      n = RR_N, cells = RR_CELLS, texel = RR_SIZE / RR_N, cell = RR_SIZE / RR_CELLS, period = 0.9,
      rate = min(1, rate * 1.1), amp = 1.0, rad = 0.07, t0 = RR.t, t1 = RR.t + 1 / RR_HZ, ox = sd, oy = sd * 0.5 } })
    compute.run(RR_SH, "step", { size = { RR_N, RR_N }, bind = { cur = RR.cur, prev = RR.prev }, params = {
      n = RR_N, c2 = 0.12, damp = 0.975 } })
    RR.cur, RR.prev = RR.prev, RR.cur
    RR.t = RR.t + 1 / RR_HZ
  end
  local F = field
  compute.run(RR_SH, "shade", { size = { RR_N, RR_N }, bind = { cur = RR.cur, out = RR.tex }, params = {
    n = RR_N, test = rr_test and 1 or 0, gain = 4.0, wet = min(1, 0.35 + 0.65 * max(wet, puddles)),
    sr = F[SKY], sg = F[SKY + 1], sb = F[SKY + 2], dr = F[DROP], dg = F[DROP + 1], db = F[DROP + 2] } })
end

-- ── the frame ───────────────────────────────────────────────────────────────
local dbg_t = -100

local function off(node)
  state.on, state.rate = false, 0
  show(node, nil)
  if RR then rr_free() end
end

local cam_node = nil
function lateUpdate(node, dt)
  dt = dt or 0
  refresh()
  local wx = refs.weather
  local o = wx and wx.current and wx.current() or nil
  -- how hard it is raining here (rain, the rain share of sleet; never snow,
  -- dust or ash)
  local rate = 0
  if o and o.kind == "wet" and not o.airless then
    rate = clamp01((o.precip or 0) * (1 - (o.snow or 0)) * (1 - 0.5 * (o.hail or 0)))
  end
  -- the ground wets through over `wetIn` of heavy rain and dries over `dryOut`
  local target = rate > 0.03 and 1 or 0
  if first then
    -- a load into weather that has been raining for a while: wet already
    wet, puddles = clamp01(rate * 1.6), clamp01(rate * 1.2)
    first = false
  elseif target > 0 then
    wet = min(1, wet + dt * rate / max(params.wetIn or 40, 1) * 1.5)
    puddles = min(clamp01(rate * 1.4), puddles + dt * rate / max(params.puddleIn or 150, 1))
  else
    wet = max(0, wet - dt / max(params.dryOut or 240, 1))
    puddles = max(0, puddles - dt / max(params.dryOut or 240, 1) * 1.4)
  end
  if forced then wet, puddles = forced.w, forced.p end
  state.rate, state.wet, state.puddles = rate, wet, puddles

  if params.on == false or not user_on or (wet < 0.01 and rate < 0.01) then return off(node) end
  local om, pc, gm = refs.orbit_map, refs.planet_camera, refs.game_manager
  if om and om.map_view then return off(node) end
  if pc and pc.cockpit then return off(node) end
  if gm and gm.inputOwner == "builder" then return off(node) end
  if o and o.sheltered then return off(node) end
  if not (cam_node and cam_node.valid) then cam_node = find("Camera 1") end
  if not (cam_node and cam_node.valid) then return off(node) end
  local cx, cy, cz = cam_node.x, cam_node.y, cam_node.z
  local cl = refs.climate
  if cl and cl.isUnderwater and cl.isUnderwater(cx, cy, cz) then return off(node) end
  local name = o and o.body or (space.dominant and space.dominant(cx, cy, cz))
  local b = name and space.body(name)
  local pn = name and find(name)
  if not (b and pn and pn.toWorld) then return off(node) end
  -- nothing to see from high up: the splashes are metres across and the wet
  -- look is under the haze
  local alt = sqrt((cx - b.x) ^ 2 + (cy - b.y) ^ 2 + (cz - b.z) ^ 2) - (b.radius or 0)
  if alt > 400 then return off(node) end

  local po, X, Y, Z = planet_axes(pn)
  -- re-anchor when the camera has gone a hundred metres (or changed worlds)
  local need = not anc or anc.body ~= name
  if not need then
    local ax, ay, az = to_world(X, Y, Z, anc.lx, anc.ly, anc.lz)
    local d2 = (po.x + ax - cx) ^ 2 + (po.y + ay - cy) ^ 2 + (po.z + az - cz) ^ 2
    need = d2 > (100 + alt) ^ 2
  end
  if need then anc = place_anchor(name, b, cx, cy, cz, po, X, Y, Z) end
  if not anc then return off(node) end

  local gx = refs.graphics
  local level = gx and gx.level and gx.level() or "Medium"
  local which = BY_LEVEL[level] or "rainFx"
  build_field(which, rate, po, X, Y, Z)
  show(node, which)
  state.on = true
  draw_field(node, which)
  local want_rr = compute_on
  if want_rr == nil then want_rr = params.computeRipples end
  if want_rr and rate > 0.01 then rr_frame(dt, rate, po, X, Y, Z, cx, cy, cz)
  elseif RR then rr_free() end

  if params.debug and time - dbg_t > 1.0 then
    dbg_t = time
    local F = field
    print(string.format("rain_fx: %s rate %.2f wet %.2f puddles %.2f fog %.0f..%.0f d %.4f", which, rate, wet, puddles, F[FOG], F[FOG + 1], F[FOG + 2]))
  end
end

function onDestroy(node)
  rr_free()
  for _, n in ipairs(SHADERS) do pcall(node.setScreenShader, node, n, false) end
end
