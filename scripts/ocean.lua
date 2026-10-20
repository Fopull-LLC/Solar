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
local crew_depth = nil
local pc_ref

-- The effects director (cached: findScript walks the whole scene).
local vfx_ref = nil
local function vfx_dir()
  if not (vfx_ref and vfx_ref.valid) then vfx_ref = findScript and findScript("vfx") or nil end
  return vfx_ref
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

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

local function push_sky(node)
  if sky_set then return end
  sky_set = true
  local atmo = world and world.atmo or 0
  -- The sky as the engine draws it, horizon and zenith (climate.waterSky):
  -- thin air reflects a darker sky; none reflects space.
  local cl = findScript("climate")
  if cl and cl.waterSky then
    local hr, hg, hb, zr, zg, zb = cl.waterSky(world)
    node:setShaderParam("skyColor", hr, hg, hb, 1)
    node:setShaderParam("zenithColor", zr, zg, zb, 1)
  else
    local k = math.min(1, atmo * 1.6)
    node:setShaderParam("skyColor", 0.03 + (world and world.atmoR or 0.55) * k,
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
    if wt.deep then node:setShaderParam("deepColor", wt.deep[1], wt.deep[2], wt.deep[3], 1) end
    if wt.shallow then node:setShaderParam("shallowColor", wt.shallow[1], wt.shallow[2], wt.shallow[3], 1) end
    if cl and cl.waterLight then node:setShaderParam("bodyLight", cl.waterLight(wt)) end
    if cl and cl.waterAbsorb then node:setShaderParam("absorb", cl.waterAbsorb(wt)) end
    local calm = (wt.state == "methane") and 0.25 or 1.0
    node:setShaderParam("bump", (0.14 + 0.26 * math.min(1, atmo)) * calm)
  elseif frozen then
    -- Sea ice is blue-white: old ice is blue where it is clear and white
    -- where it is crazed with air, and only a hint of the water it froze
    -- from. A warm star lights it peach; with the water's own tint mixed in
    -- as well (an iron sea's ice was a pinkish grey), it read as a sand flat.
    local s = wt and wt.shallow or { 0.2, 0.5, 0.6 }
    node:setShaderParam("iceColor", 0.36 + s[1] * 0.06, 0.58 + s[2] * 0.06, 0.82 + s[3] * 0.05, 1)
    node:setShaderParam("frostColor", 0.80, 0.88, 0.96, 1)
  end
end

-- How far the eye is above this sea, as the shader's 0..1 far fade.
local far_set = -1
local function push_far(node, alt)
  local f = math.max(0, math.min(1, (alt - 120) / math.max(R * 1.2, 1)))
  if math.abs(f - far_set) > 0.02 then
    far_set = f
    node:setShaderParam("farFade", f)
  end
end

-- The wind on the sea (weather.lua, the camera's world), twice a second: the
-- shader runs its waves downwind and breaks whitecaps past a fresh breeze.
local wind_t, wx_ref = -100, nil
local function push_wind(node)
  if frozen or time - wind_t < 0.5 then return end
  wind_t = time
  if not (wx_ref and wx_ref.valid) then wx_ref = findScript("weather") end
  local c = wx_ref and wx_ref.current and wx_ref.current()
  if not (c and body and c.body == body.name) then return end
  node:setShaderParam("windDir", c.windX or 0, c.windY or 0, c.windZ or 1)
  node:setShaderParam("wind", c.windNow or c.wind or 0)
end

function update(node, dt)
  if not resolve(node) then return end
  push_sky(node)
  push_wind(node)

  local ex, ey, ez = eye()
  if not ex then return end
  local rx, ry, rz = ex - body.x, ey - body.y, ez - body.z
  local dc = len(rx, ry, rz)
  if not frozen then push_far(node, dc - R) end
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
      if shore_x then surf:setPosition(shore_x, shore_y, shore_z) end
    end
  elseif surf then
    surf:stop()
    surf = nil
  end

  -- The crew hitting the water.
  local a = find("Astronaut")
  if a and a.visible ~= false then
    local ax, ay, az = a.x - body.x, a.y - body.y, a.z - body.z
    local al = len(ax, ay, az)
    local depth = R - al
    if crew_depth and crew_depth < 0 and depth >= 0 then
      local vr = ((a.vx or 0) * ax + (a.vy or 0) * ay + (a.vz or 0) * az) / math.max(al, 1e-6)
      if vr < -2.0 then
        local nx, ny, nz = ax / al, ay / al, az / al
        local px, py, pz = body.x + nx * R, body.y + ny * R, body.z + nz * R
        local v = math.min(6, 1.5 - vr * 0.5)
        local fx = vfx_dir()
        if fx then fx.splash(px, py, pz, math.min(2.5, -vr * 0.3)) else spawnEffect("SeaSpray", px, py, pz, nx * v, ny * v, nz * v) end
        audio.play("audio/water/splash_" .. math.random(1, 3), px, py, pz,
          { track = "SFX", volume = math.min(1, 0.35 - vr * 0.08), maxDistance = 60 })
      end
    end
    crew_depth = depth
  end
end
