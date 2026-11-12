-- OCEAN — the living part of a sea (prefabs/Sea.prefab.ron, SeaIce.prefab.ron).
--
-- The shader draws the water (lit by the engine's key light, the system's
-- star); this feeds it what only the scene knows and adds what a shader cannot:
--
--   * the SKY — the world's own air colour (published by the generator), so a
--     rust sky gives rust water and an airless world reflects black
--   * SPRAY — waves breaking where the sea meets the land near you. A shore
--     point is found the honest way: a point ON the sea sphere whose distance
--     to the terrain field is small but positive is water lapping at ground.
--     Spray is fired along the local up and falls back under the planet's own
--     gravity (the effect's gravity mode is Field).
--   * SURF — a looping breaking-wave bed placed at the nearest shore found, so
--     it swells as you walk down to the water and is gone inland
--   * SPLASH — the crew hitting the water at speed
--
-- Everything but the sky is skipped unless the eye is near this sea: a
-- galaxy has many, and only the one you are standing beside is worth a query.

defaults = {
  --- Only within this height (m) above the sea do spray and surf run.
  --@range 20 1000
  near = 160.0,
  --- Spray bursts a second along the shores near you, at most.
  --@range 0 10
  sprayRate = 3.0,
  --- How far from the eye (m) spray and the surf search look.
  --@range 10 150
  reach = 55.0,
  --- Surf loop volume at the waterline.
  --@range 0 1
  surfVolume = 0.6,
}

local body, world
local R = 0
local frozen = false
local sky_set = false
local spray_acc = 0
local surf, surf_level = nil, 0
local shore_t, shore_x, shore_y, shore_z, shore_d = 0, nil, nil, nil, 1e9
local shore_rx, shore_ry, shore_rz = nil, nil, nil
local crew_depth = nil
local pc_ref

-- The effects director (cached: findScript walks the whole scene).
local vfx_ref = nil
local function vfx_dir()
  if not (vfx_ref and vfx_ref.valid) then vfx_ref = findScript and findScript("vfx") or nil end
  return vfx_ref
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- Every shader parameter pushed to the sea, by name, so the near cap (made
-- later, see `cap_tick`) can be dressed the same.
local params_now = {}
local function remember(k, ...) params_now[k] = { ... } end

-- Is the crew ON FOOT (aboard no craft)? vessel_controller's `crewOnFoot` says
-- so; `astronaut.visible` used to stand in for it, and stopped meaning it once
-- the camera hid the body in first person and an open Command Seat kept its
-- rider in view (a rider driving through a ford splashed as if swimming). Any
-- controller answers for every craft; with none in the scene, nobody is aboard.
local vc_ref, vc_t = nil, -10.0
local function crew_on_foot()
  if not (vc_ref and vc_ref.valid) and time - vc_t > 0.5 then
    vc_t = time
    vc_ref = findScript("vessel_controller")
  end
  if vc_ref and vc_ref.valid and vc_ref.crewOnFoot then return vc_ref.crewOnFoot() == true end
  return true
end

local function resolve(node)
  if body and body.valid then return true end
  body = node.parent
  if not body then return false end
  local cl = findScript("climate")
  world = cl and cl.worldOf(body.name) or save.get("world." .. body.name)
  R = (world and world.sea) or (node.scale or 0)
  frozen = node.name == "SeaIce"
  sky_set = false
  return R > 0
end

-- Where the eye is: planet_camera publishes it; the crew is the fallback.
local function eye()
  if not pc_ref or not pc_ref.valid then pc_ref = findScript("planet_camera") end
  if pc_ref and (pc_ref.cam_x ~= 0 or pc_ref.cam_y ~= 0 or pc_ref.cam_z ~= 0) then
    return pc_ref.cam_x, pc_ref.cam_y, pc_ref.cam_z
  end
  local a = find("Astronaut")
  if a then return a.x, a.y, a.z end
  return nil
end

-- A random point on the sea sphere within `reach` of the point below (ux,uy,uz).
local function near_point(ux, uy, uz, reach)
  -- Any vector not parallel to up gives a tangent basis.
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l1 = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l1, t1y / l1, t1z / l1
  local t2x, t2y, t2z = uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
  local a = math.random() * 6.2832
  local r = math.sqrt(math.random()) * reach
  local k = math.tan(r / R)
  local dx = ux + (t1x * math.cos(a) + t2x * math.sin(a)) * k
  local dy = uy + (t1y * math.cos(a) + t2y * math.sin(a)) * k
  local dz = uz + (t1z * math.cos(a) + t2z * math.sin(a)) * k
  local l = len(dx, dy, dz)
  return dx / l, dy / l, dz / l, r
end

-- Is the sea point in direction (dx,dy,dz) water lapping at ground?
local function shore_at(dx, dy, dz)
  local px, py, pz = body.x + dx * R, body.y + dy * R, body.z + dz * R
  local q = terrain.query(px, py, pz)
  if q and q > 0.05 and q < 1.4 then return px, py, pz end
  return nil
end

local push_sky_to
local function push_sky(node)
  if sky_set then return end
  sky_set = true
  push_sky_to(node)
end
push_sky_to = function(node)
  local function sp(k, ...) node:setShaderParam(k, ...); remember(k, ...) end
  local atmo = world and world.atmo or 0
  -- The sky as the engine draws it, horizon and zenith (climate.waterSky):
  -- thin air reflects a darker sky; none reflects space.
  local cl = findScript("climate")
  if cl and cl.waterSky then
    local hr, hg, hb, zr, zg, zb = cl.waterSky(world)
    sp("skyColor", hr, hg, hb, 1)
    sp("zenithColor", zr, zg, zb, 1)
  else
    local k = math.min(1, atmo * 1.6)
    sp("skyColor", 0.03 + (world and world.atmoR or 0.55) * k,
      0.04 + (world and world.atmoG or 0.7) * k, 0.07 + (world and world.atmoB or 0.9) * k, 1)
  end
  -- The WATER ITSELF, by the world's chemistry (system_generator's geology
  -- publishes `world.water`): a clear tropical sea, an algal green one, a
  -- tannin-brown bog sea, milky glacial flour, iron-red, or a hydrocarbon
  -- lake. Its absorption (climate.waterAbsorb) sets how far the eye sees down to the shelf, and the
  -- air's thickness sets the chop (no wind, no waves: a methane sea under a
  -- still sky is a mirror).
  local wt = world and world.water
  if wt and not frozen then
    if wt.deep then sp("deepColor", wt.deep[1], wt.deep[2], wt.deep[3], 1) end
    if wt.shallow then sp("shallowColor", wt.shallow[1], wt.shallow[2], wt.shallow[3], 1) end
    if cl and cl.waterLight then sp("bodyLight", cl.waterLight(wt)) end
    if cl and cl.waterAbsorb then sp("absorb", cl.waterAbsorb(wt)) end
    local calm = (wt.state == "methane") and 0.25 or 1.0
    sp("bump", (0.14 + 0.26 * math.min(1, atmo)) * calm)
  elseif frozen then
    -- Sea ice is blue-white: old ice is blue where it is clear and white
    -- where it is crazed with air, and only a hint of the water it froze
    -- from. A warm star lights it peach; with the water's own tint mixed in
    -- as well (an iron sea's ice was a pinkish grey), it read as a sand flat.
    local s = wt and wt.shallow or { 0.2, 0.5, 0.6 }
    sp("iceColor", 0.36 + s[1] * 0.06, 0.58 + s[2] * 0.06, 0.82 + s[3] * 0.05, 1)
    sp("frostColor", 0.80, 0.88, 0.96, 1)
  end
end

-- How far the eye is above this sea, as the shader's 0..1 far fade.
-- ── the near cap ───────────────────────────────────────────────────────────
-- The sphere's vertices are ~28 m apart: too coarse to carry a wave. Near
-- the eye the sea is drawn on a CAP as well: a disc of the sea sphere under
-- the eye, rings growing outward (2 m at the centre, 420 m at the rim), in
-- the planet's frame under the body like a lake sheet, wearing the same
-- shader with geomWaves = 1 so the swell moves its vertices. uv = (depth/16,
-- rim): the water over the bed under each vertex within DEPTH_REACH (one
-- field read; the distance field is roughly the vertical depth over a bed),
-- so the swell shoals and dies at the waterline; the rim fades over the
-- outer quarter of the rings, and the sphere hides under the cap (capHide).
-- Built as a coroutine, CAP_SLICE reads a frame; built again when the eye
-- has moved CAP_MOVE m from the centre it was built under, freed when the
-- eye climbs past CAP_ALT.
local CAP_RINGS, CAP_SEGS = 44, 80
local CAP_R0, CAP_R1 = 2.0, 420.0
local CAP_MOVE, CAP_ALT = 45.0, 320.0
local DEPTH_REACH = 140.0
local CAP_SLICE = 300
local cap = { node = nil, mesh = nil, ux = 0, uy = 0, uz = 0, co = nil, t = -100 }
capStats = { builds = 0, reads = 0, frames = 0 }
waveNow = nil   -- the swell the wind set last (probes)

local function cap_free()
  if cap.co then cap.co = nil end
  if cap.node and cap.node.valid then cap.node:destroy() end
  if cap.mesh then pcall(mesh.free, cap.mesh) end
  cap.node, cap.mesh = nil, nil
end

-- The swell's size from the wind: JONSWAP, fetch-limited (Hasselmann 1973;
-- docs/research/water.md §1.1). U m/s, fetch F m, gravity g. → amplitude
-- of the biggest of the six Gerstner waves (m), peak wavelength (m). At
-- U 10, F 2000, g 9.81: Hs 0.23 m, λ 4.5 m — a choppy lake, which is what
-- a few-km sea is. Low g: longer, slower, taller.
function spectrum(U, F, g)
  U = math.max(U or 0, 0.8)
  g = math.max(g or 9.81, 0.1)
  local x = g * F / (U * U)
  local Hs = 1.6e-3 * math.sqrt(x) * U * U / g
  local Tp = 0.286 * x ^ (1 / 3) * U / g
  local lam = g * Tp * Tp / 6.2832
  return math.min(1.2, Hs * 0.5 * 0.8), math.max(1.5, math.min(40, lam))
end

local function tangent_basis(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  return t1x, t1y, t1z, uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
end

local function cap_build_co(ux, uy, uz)
  local b = body
  local t1x, t1y, t1z, t2x, t2y, t2z = tangent_basis(ux, uy, uz)
  local pos, uvs, idx = {}, {}, {}
  local reads = 0
  local function q_at(dx, dy, dz)
    reads = reads + 1
    if reads % CAP_SLICE == 0 then coroutine.yield() end
    return terrain.query(b.x + dx * R, b.y + dy * R, b.z + dz * R)
  end
  pos[1], pos[2], pos[3] = ux * R, uy * R, uz * R
  local q0 = q_at(ux, uy, uz)
  uvs[1], uvs[2] = math.min(1, math.max(0, (q0 or 16) / 16)), 1
  local grow = (CAP_R1 / CAP_R0) ^ (1 / (CAP_RINGS - 1))
  for ring = 1, CAP_RINGS do
    local rad = CAP_R0 * grow ^ (ring - 1)
    local rim = 1 - math.max(0, (ring - CAP_RINGS * 0.75) / (CAP_RINGS * 0.25))
    for s = 0, CAP_SEGS - 1 do
      local a = s / CAP_SEGS * 6.2832
      local ca, sa = math.cos(a), math.sin(a)
      local dx = ux + (t1x * ca + t2x * sa) * rad / R
      local dy = uy + (t1y * ca + t2y * sa) * rad / R
      local dz = uz + (t1z * ca + t2z * sa) * rad / R
      local l = len(dx, dy, dz)
      dx, dy, dz = dx / l, dy / l, dz / l
      pos[#pos + 1], pos[#pos + 2], pos[#pos + 3] = dx * R, dy * R, dz * R
      local depth = 1
      if rad < DEPTH_REACH then
        local q = q_at(dx, dy, dz)
        depth = math.min(1, math.max(0, (q or 16) / 16))
      end
      uvs[#uvs + 1], uvs[#uvs + 2] = depth, rim
    end
  end
  -- (mesh.build's indices are 1-based, as climate's lakes number them:
  -- the centre is vertex 1, ring r's segment s is 2 + (r-1)·SEGS + s)
  for s = 0, CAP_SEGS - 1 do
    idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = 1, 2 + s, 2 + (s + 1) % CAP_SEGS
  end
  for ring = 1, CAP_RINGS - 1 do
    local b0, b1 = 2 + (ring - 1) * CAP_SEGS, 2 + ring * CAP_SEGS
    for s = 0, CAP_SEGS - 1 do
      local s1 = (s + 1) % CAP_SEGS
      idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = b0 + s, b1 + s, b1 + s1
      idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = b0 + s, b1 + s1, b0 + s1
    end
  end
  capStats.reads = capStats.reads + reads
  local ok, name = pcall(mesh.build, { positions = pos, indices = idx, uvs = uvs })
  if not ok then
    if not capStats.failed then print("ocean: the cap's mesh.build failed: " .. tostring(name)) end
    capStats.failed = (capStats.failed or 0) + 1
    return nil
  end
  return name
end

local function cap_dress()
  local n = cap.node
  if not (n and n.valid) then return end
  for k, v in pairs(params_now) do n:setShaderParam(k, unpack(v)) end
  n:setShaderParam("geomWaves", 1)
  n:setShaderParam("capDir", cap.ux, cap.uy, cap.uz)
  n:setShaderParam("capR", CAP_R1 * 0.92)
  n:setShaderParam("capHide", 0)
end

local function cap_tick(node, ux, uy, uz, alt)
  if frozen or not (mesh and mesh.build and terrain and terrain.query) then return end
  if cap.redress and cap.redress > 0 and cap.node and cap.node.valid then
    cap.redress = cap.redress - 1
    cap_dress()
    if cap.hide_pending then
      cap.hide_pending = nil
      node:setShaderParam("capDir", cap.ux, cap.uy, cap.uz)
      node:setShaderParam("capR", CAP_R1 * 0.92)
      remember("capR", CAP_R1 * 0.92)
      node:setShaderParam("capHide", 1)
    end
  end
  if alt > CAP_ALT then
    if cap.node or cap.co then cap_free(); node:setShaderParam("capHide", 0) end
    return
  end
  if cap.co then
    capStats.frames = capStats.frames + 1
    local ok, res = coroutine.resume(cap.co)
    if not ok then print("ocean: cap build failed: " .. tostring(res)); cap.co = nil return end
    if coroutine.status(cap.co) == "dead" then
      cap.co = nil
      if res then
        if cap.node and cap.node.valid then cap.node:destroy() end
        if cap.mesh then pcall(mesh.free, cap.mesh) end
        cap.mesh = res
        local cux, cuy, cuz = cap.bux, cap.buy, cap.buz
        -- The WaterSheet prefab carries the material and the shader (a node
        -- made with createNode and dressed from a script has no Material of
        -- its own to put a shader on: it drew in the default look).
        spawn("WaterSheet", vec3(0, 0, 0), function(n)
          n.name = "SeaCap"
          -- (spawn's pos is a WORLD point: every sheet spawned at vec3(0,0,0)
          -- stood at the world's origin, kilometres from its planet. A
          -- child's x/y/z are its LOCAL offset: the planet's own frame.)
          n.x, n.y, n.z = 0, 0, 0
          n.model = res
          n.visible = node.visible
          cap.node = n
          -- (the parameters are pushed on the frames after, cap_dress)
          cap.redress = 3
        end, body)
        cap.ux, cap.uy, cap.uz = cux, cuy, cuz
        cap.hide_pending = true
        capStats.builds = capStats.builds + 1
      end
    end
    return
  end
  local moved = len(ux - cap.ux, uy - cap.uy, uz - cap.uz) * R
  if (not cap.node or moved > CAP_MOVE) and time - cap.t > 1.0 then
    cap.t = time
    cap.bux, cap.buy, cap.buz = ux, uy, uz
    cap.co = coroutine.create(function() return cap_build_co(ux, uy, uz) end)
  end
end

-- How far the eye is above this sea, as the shader's 0..1 far fade.
local far_set = -1
local function push_far(node, alt)
  local f = math.max(0, math.min(1, (alt - 120) / math.max(R * 1.2, 1)))
  if math.abs(f - far_set) > 0.02 then
    far_set = f
    node:setShaderParam("farFade", f)
    remember("farFade", f)
    if cap.node and cap.node.valid then cap.node:setShaderParam("farFade", f) end
  end
end

-- The wind on the sea (weather.lua, the camera's world), twice a second: the
-- shader runs its waves downwind and breaks whitecaps past a fresh breeze;
-- the swell is sized from it (spectrum) and the world's own gravity.
local wind_t, wx_ref = -100, nil
local grav = nil
local swell_dir = nil
local function push_wind(node)
  if frozen or time - wind_t < 0.5 then return end
  wind_t = time
  if not (wx_ref and wx_ref.valid) then wx_ref = findScript("weather") end
  local c = wx_ref and wx_ref.current and wx_ref.current()
  if not (c and body and c.body == body.name) then return end
  if not grav then
    local bn = space and space.body and space.body(body.name)
    grav = (bn and bn.mu and R > 0) and (bn.mu / (R * R)) or 9.81
  end
  local U = c.windNow or c.wind or 0
  local amp, lam = spectrum(U, 2000, grav)
  waveNow = { U = U, amp = amp, lam = lam, g = grav, R = R }
  -- The swell's direction is set ONCE (the first wind read; a planet-frame
  -- vector) and held: the shader's wave phase is k·dot(d, p), and a
  -- direction that followed the gusts slid the whole pattern (see
  -- ocean.flsl `swellDir`).
  if not swell_dir then
    local sx, sy, sz = c.windX or 0.6, c.windY or 0, c.windZ or 0.8
    local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
    if sl < 1e-6 then sx, sy, sz, sl = 0.6, 0, 0.8, 1 end
    swell_dir = { sx / sl, sy / sl, sz / sl }
    node:setShaderParam("swellDir", swell_dir[1], swell_dir[2], swell_dir[3])
    remember("swellDir", swell_dir[1], swell_dir[2], swell_dir[3])
  end
  local calm = (world and world.water and world.water.state == "methane") and 0.25 or 1.0
  local vals = {
    windDir = { c.windX or 0, c.windY or 0, c.windZ or 1 },
    wind = { U },
    waveAmp = { amp * calm },
    waveLen = { lam },
    gAccel = { grav },
  }
  for k, v in pairs(vals) do
    node:setShaderParam(k, unpack(v))
    remember(k, unpack(v))
    if cap.node and cap.node.valid then cap.node:setShaderParam(k, unpack(v)) end
  end
end

-- ── dry caves ──────────────────────────────────────────────────────────────
-- The engine's Sea Volume (the prefab's hidden child) gives the view its
-- underwater look anywhere inside the sea's sphere — so every cave below sea
-- level was murky water, "all caves / underground treated as underwater".
-- Water is a CONNECTED body (climate.seaDepth: open to the sea's surface, or a
-- flooded cave), so whenever the eye is under the sea's radius somewhere that
-- rule calls dry, the volume is frozen (a frozen volume has no inside: no look,
-- no state) and thawed again the moment the eye is in real water.
--
-- And in a dry cave the sea's surface sphere runs through the rock and
-- would show as a sheet of water across a grotto that spans sea level, so it
-- is hidden while the eye is roofed over and walled in on every side (a cave,
-- not an overhang on a beach, where the sea is in view).
local vol, vol_frozen = nil, false
local dry_t = 0      -- seconds the eye has been dry under the sea's level
local look_t, surf_hidden = 0, false
caveDry = false      -- published: the eye is in a dry spot under the sea's level

local function sea_volume(node)
  if vol and vol.valid then return vol end
  vol = nil
  local kids = node.children and node:children() or {}
  for _, k in ipairs(kids) do
    if k.valid and k.name == "Sea Volume" then vol = k end
  end
  return vol
end

local function walled(ex, ey, ez, ux, uy, uz)
  -- Horizontal sphere-traces in six directions: all hit rock within 40 m?
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  local t2x, t2y, t2z = uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
  for k = 0, 5 do
    local a = k * math.pi / 3
    local dx = t1x * math.cos(a) + t2x * math.sin(a)
    local dy = t1y * math.cos(a) + t2y * math.sin(a)
    local dz = t1z * math.cos(a) + t2z * math.sin(a)
    local t, hit = 0.5, false
    for _ = 1, 14 do
      local q = terrain.query(ex + dx * t, ey + dy * t, ez + dz * t)
      if q == nil then return false end
      if q < 0.1 then hit = true break end
      t = t + math.max(q, 0.5)
      if t > 40 then break end
    end
    if not hit then return false end
  end
  return true
end

local function look_tick(node, ex, ey, ez, dc, dt)
  if frozen then return end
  look_t = look_t - dt
  if look_t > 0 then return end
  look_t = 0.15
  local cl = findScript("climate")
  local v = sea_volume(node)
  local dry, wet = false, false
  local hide = false
  if dc < R + 4 and cl and cl.isUnderwater and terrain and terrain.query then
    wet = cl.isUnderwater(ex, ey, ez)
    dry = (dc < R) and not wet
    if not wet and cl.columnOpen then
      local rx, ry, rz = ex - body.x, ey - body.y, ez - body.z
      if cl.columnOpen(body.x, body.y, body.z, rx, ry, rz, R + 30) == false then
        hide = walled(ex, ey, ez, rx / dc, ry / dc, rz / dc)
      end
    end
  end
  caveDry = dry
  -- Each flip costs the engine a physics rebuild (rc37: every terrain collider
  -- made again), and digging round sea level flipped it every look: thawed
  -- at once in real water, frozen after half a second dry under the sea's
  -- level, and left as it is above it, where the volume holds nothing anyway.
  -- (frozen after one dry look, 0.15 s: a pit dug under the sea's radius
  -- showed the murky look for half a second each time its reach was asked)
  local want = vol_frozen
  if wet then want, dry_t = false, 0
  elseif dry then dry_t = dry_t + 0.15; if dry_t >= 0.15 then want = true end
  else dry_t = 0 end
  if v and water and water.setFrozen and want ~= vol_frozen then
    vol_frozen = want
    water.setFrozen(v, want)
  end
  if hide ~= surf_hidden then
    surf_hidden = hide
    node.visible = not hide
    if cap.node and cap.node.valid then cap.node.visible = not hide end
  end
end

function update(node, dt)
  if not resolve(node) then return end
  push_sky(node)
  push_wind(node)

  local ex, ey, ez = eye()
  if not ex then return end
  local rx, ry, rz = ex - body.x, ey - body.y, ez - body.z
  local dc = len(rx, ry, rz)
  look_tick(node, ex, ey, ez, dc, dt)
  if not frozen then push_far(node, dc - R) end
  if dc > 1 then cap_tick(node, rx / dc, ry / dc, rz / dc, dc - R) end
  local near = (not frozen) and dc - R < params.near and dc > 1
  if not near then
    if surf then surf:stop(); surf, surf_level = nil, 0 end
    crew_depth = nil
    return
  end
  local ux, uy, uz = rx / dc, ry / dc, rz / dc

  -- Spray where the sea meets the land near you.
  spray_acc = spray_acc + dt * params.sprayRate
  local tries = 0
  while spray_acc >= 1 and tries < 8 do
    tries = tries + 1
    local dx, dy, dz = near_point(ux, uy, uz, params.reach)
    local px, py, pz = shore_at(dx, dy, dz)
    if px then
      spray_acc = spray_acc - 1
      local v = 2.2 + math.random() * 2.6
      -- vfx.lua adds the planet's own velocity, so the spray stays on the shore
      -- instead of streaking off at orbital speed.
      local fx = vfx_dir()
      if fx then fx.spray(px + dx * 0.2, py + dy * 0.2, pz + dz * 0.2, dx * v, dy * v, dz * v)
      else spawnEffect("SeaSpray", px + dx * 0.2, py + dy * 0.2, pz + dz * 0.2, dx * v, dy * v, dz * v) end
    end
  end
  if spray_acc > 2 then spray_acc = 2 end

  -- The surf bed: every half second, look for the nearest shore and put it there.
  if time - shore_t > 0.5 then
    shore_t = time
    local best = shore_d * 1.15 + 2  -- the last one found, a little stale
    local bx, by, bz = shore_x, shore_y, shore_z
    for _ = 1, 14 do
      local dx, dy, dz, r = near_point(ux, uy, uz, params.reach)
      if r < best then
        local px, py, pz = shore_at(dx, dy, dz)
        if px then best, bx, by, bz = r, px, py, pz end
      end
    end
    shore_x, shore_y, shore_z, shore_d = bx, by, bz, bx and best or 1e9
    -- (kept body-relative: a world point read here and set as the surf's
    -- position for the next half second trailed the planet by metres)
    if bx then shore_rx, shore_ry, shore_rz = bx - body.x, by - body.y, bz - body.z else shore_rx = nil end
    shoreDist = shore_d   -- published: how far the nearest shore is from the eye (climate.waterNearEye)
  end
  local want = 0
  if shore_x then
    want = params.surfVolume * math.max(0, 1 - shore_d / params.reach)
  end
  surf_level = surf_level + (want - surf_level) * math.min(1, dt * 1.5)
  if surf_level > 0.02 then
    if not surf then
      surf = audio.play("audio/water/surf_loop", shore_x, shore_y, shore_z,
        { loop = true, volume = 0, track = "SFX", mode = "Spatial", minDistance = 10, maxDistance = 110 })
    end
    if surf then
      surf:setVolume(surf_level)
      if shore_rx then surf:setPosition(body.x + shore_rx, body.y + shore_ry, body.z + shore_rz) end
    end
  elseif surf then
    surf:stop()
    surf = nil
  end

  -- The crew hitting the water.
  local a = find("Astronaut")
  if a and crew_on_foot() then
    local ax, ay, az = a.x - body.x, a.y - body.y, a.z - body.z
    local al = len(ax, ay, az)
    local depth = R - al
    -- In a dry cave under the sea's level there is no water to hit.
    if depth >= 0 then
      local cl = findScript("climate")
      if cl and cl.isUnderwater and not cl.isUnderwater(a.x, a.y, a.z) then depth = -1 end
    end
    if crew_depth and crew_depth < 0 and depth >= 0 then
      local vr = ((a.vx or 0) * ax + (a.vy or 0) * ay + (a.vz or 0) * az) / math.max(al, 1e-6)
      if vr < -2.0 then
        local nx, ny, nz = ax / al, ay / al, az / al
        local px, py, pz = body.x + nx * R, body.y + ny * R, body.z + nz * R
        local v = math.min(6, 1.5 - vr * 0.5)
        local fx = vfx_dir()
        if fx then fx.splash(px, py, pz, math.min(2.5, -vr * 0.3)) else spawnEffect("SeaSpray", px, py, pz, nx * v, ny * v, nz * v) end
        -- A body hitting the water (audio/water/splash_body_1..2, a dive and
        -- a big splash, CC0): the rock splashes past 6 m/s stay for the
        -- heavier hit on top.
        audio.play("audio/water/splash_body_" .. math.random(1, 2), px, py, pz,
          { track = "SFX", volume = math.min(1, 0.4 - vr * 0.08), maxDistance = 80 })
        if vr < -6 then
          audio.play("audio/water/splash_" .. math.random(1, 3), px, py, pz,
            { track = "SFX", volume = math.min(1, 0.2 - vr * 0.05), maxDistance = 60 })
        end
        if fx then fx.emit("WaterRing", px, py, pz) else spawnEffect("WaterRing", px, py, pz) end
      end
    end
    crew_depth = depth
  end
end

-- The scene goes: the cap's mesh with it (a built mesh outlives the scene).
function onDestroy()
  pcall(cap_free)
end
