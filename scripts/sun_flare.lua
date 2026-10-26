-- SUN FLARE — the star seen through a lens, fed to shaders/sunFlare.flsl (a
-- screen pass on this node, the scene's Post Processing).
--
-- The shader draws and occludes (from the frame's depth, so a hill, a hangar,
-- a crewmate or the planet hides the sun and its flare goes with it). This
-- script decides how much there is to draw:
--
--   * WHERE: the star projected through the active camera, with its disc's
--     angular size, faded out as it leaves the frame (a sun just off the edge
--     still veils the frame; one behind you does not).
--   * HOW MUCH LIGHT: the star's light after the air between it and the eye.
--     Airmass grows toward the horizon (1/(sinElevation + 0.05), capped), and
--     the air takes blue first, so a low sun goes orange and then red and
--     weak, and a sun under thick cloud (weather.lua's cover) throws none.
--   * HOW MUCH IS LENS: in air the sky itself already glows round the sun
--     (the engine's forward scattering), so the glare is modest and the rays
--     and ghosts faint; in vacuum the black sky has nothing of its own, and the
--     glare, the rays and the ghosts are what a camera there shows.
--
-- Switched by graphics.lua (`flare` per level) and by the player's "Lens
-- flare" setting; when off the pass itself is turned off, so it costs nothing.
--
-- Cross-script:  local sf = findScript("sun_flare")
--                sf.setOn(bool)   sf.state  { vis = 0..1 light, uv = {x, y}, lens = 0..1 }

defaults = {
  --- Overall strength.
  --@range 0 3
  strength = 1.0,
  --- Glare round the disc in air / in vacuum.
  glareAir = 0.35, glareSpace = 0.7,
  --- Diffraction rays in air / in vacuum.
  raysAir = 0.12, raysSpace = 0.35,
  --- Ghosts in air / in vacuum.
  ghostsAir = 0.12, ghostsSpace = 0.25,
}

local SHADER = "sunFlare"
local on, shown = true, nil
local star_name, star_t = nil, -100
local at_ref, wx_ref, map_ref, refs_t = nil, nil, nil, -100
state = { vis = 0, uv = { 0.5, 0.5 }, lens = 0 }

local function smooth(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end

-- The star: the body with an infinite sphere of influence (atmosphere.lua's
-- rule), re-picked once a second.
local function star()
  if time - star_t > 1.0 or not star_name then
    star_t = time
    local best, bk = nil, -1
    for _, b in ipairs(space.bodies() or {}) do
      local k = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
      if k > bk then best, bk = b.name, k end
    end
    star_name = best
  end
  return star_name and space.body(star_name)
end

local function show(node, v)
  if shown == v then return end
  shown = v
  pcall(node.setScreenShader, node, SHADER, v)
end

function setOn(v) on = v ~= false end

local function refs()
  if time - refs_t < 1.0 then return end
  refs_t = time
  if not (at_ref and at_ref.valid ~= false) then at_ref = findScript("atmosphere") end
  if not (wx_ref and wx_ref.valid ~= false) then wx_ref = findScript("weather") end
  if not (map_ref and map_ref.valid ~= false) then map_ref = findScript("orbit_map") end
end

local function off(node)
  state.vis = 0
  node:setShaderParam(SHADER .. ".sunCol", 0, 0, 0)
  node:setShaderParam(SHADER .. ".sunUv", 0.5, 0.5, 0)
end

function start(node)
  shown = nil
  show(node, on)
end

-- The frame's work. lateUpdate runs it, and planet_camera calls follow()
-- again right after it has placed the camera, so the flare is projected
-- through THIS frame's camera rather than last frame's (the Post Processing
-- node comes before the camera in the scene, so its lateUpdate runs first).
local self_node = nil
function lateUpdate(node, dt)
  self_node = node
  follow(dt)
end

function follow(dt)
  local node = self_node
  if not node then return end
  show(node, on)
  if not on then return end
  if not (camera and camera.exists and camera.exists() and camera.screenToRay and camera.worldToScreen) then return off(node) end
  refs()
  if map_ref and map_ref.map_view then return off(node) end
  local s = star()
  if not s then return off(node) end
  local rx, ry, w, h = 0, 0, nil, nil
  if camera.screenRect then rx, ry, w, h = camera.screenRect() end
  if not w or w <= 0 then w, h = camera.screenSize() end
  if not w or w <= 0 or not h or h <= 0 then return off(node) end
  local ex, ey, ez, fx, fy, fz = camera.screenToRay(rx + w * 0.5, ry + h * 0.5)
  if not ex then return off(node) end
  local qx, qy, qz = s.x - ex, s.y - ey, s.z - ez
  local dist = math.sqrt(qx * qx + qy * qy + qz * qz)
  if dist < 1 then return off(node) end
  qx, qy, qz = qx / dist, qy / dist, qz / dist
  local facing = qx * fx + qy * fy + qz * fz
  if facing <= 0.05 then return off(node) end
  -- the vertical field of view, from the rays through the top and bottom edges
  local _, _, _, tx, ty, tz = camera.screenToRay(rx + w * 0.5, ry)
  local _, _, _, bx, by, bz = camera.screenToRay(rx + w * 0.5, ry + h)
  local fov = math.acos(math.max(-1, math.min(1, tx * bx + ty * by + tz * bz)))
  if fov < 1e-3 then return off(node) end
  local sx, sy = camera.worldToScreen(ex + qx * 1000, ey + qy * 1000, ez + qz * 1000)
  if not sx then return off(node) end
  local u, v = (sx - rx) / w, (sy - ry) / h
  local edge = math.max(math.abs(u - 0.5), math.abs(v - 0.5)) - 0.5
  local frame = 1 - smooth(0, 0.3, edge)
  if frame <= 0 then return off(node) end
  local rad = math.asin(math.min(1, (s.radius or 1) / dist))

  -- the air between the star and the eye
  local at = at_ref
  local air = at and math.max(0, math.min(1, at.fog_now or 0)) or 0
  local rho = at and math.max(0, math.min(1, at.rho_now or 0)) or 0
  local up = at and at.sun_now or 1
  local m = math.min(14, 1 / (math.max(up, 0) + 0.05))
  local tr = math.exp(-0.10 * air * m)
  local tg = math.exp(-0.24 * air * m)
  local tb = math.exp(-0.50 * air * m)
  -- No horizon test here: the frame's depth already hides a sun behind the
  -- ground (from a hill on a small world the sun shows well below the eye's
  -- horizontal), and the airmass above has already reddened and dimmed it.
  local horizon = 1
  local sky = wx_ref and wx_ref.sky
  local cloud = 1
  if sky and (sky.cover or 0) > 0 then cloud = 1 - smooth(0.3, 0.85, sky.cover) end
  local lens = 1 - rho
  local k = (params.strength or 1) * horizon * cloud
  local g = (params.glareAir or 0.35) + ((params.glareSpace or 0.7) - (params.glareAir or 0.35)) * lens
  local r = (params.raysAir or 0.12) + ((params.raysSpace or 0.35) - (params.raysAir or 0.12)) * lens
  local gh = (params.ghostsAir or 0.12) + ((params.ghostsSpace or 0.25) - (params.ghostsAir or 0.12)) * lens

  state.vis, state.uv[1], state.uv[2], state.lens = k * tg, u, v, lens
  node:setShaderParam(SHADER .. ".sunUv", u, v, frame)
  node:setShaderParam(SHADER .. ".sunDir", qx, qy, qz)
  node:setShaderParam(SHADER .. ".sunCol", 1.0 * tr * k, 0.94 * tg * k, 0.86 * tb * k)
  node:setShaderParam(SHADER .. ".sunSize", rad, rad / fov, 0)
  node:setShaderParam(SHADER .. ".occlFar", dist * 0.5)
  node:setShaderParam(SHADER .. ".glare", g)
  node:setShaderParam(SHADER .. ".rays", r)
  node:setShaderParam(SHADER .. ".ghosts", gh)
end
