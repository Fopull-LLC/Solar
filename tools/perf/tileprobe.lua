-- TILEPROBE: how big the environment textures read (2026-11-03, the texture
-- tiling pass; tools/perf/tileprobe.sh). A NEW Career save with the player's
-- graphics settings copied in, clear weather, the same seed every run, so a
-- before and an after set line up shot for shot.
--
--   apron / runway / pad deck: 2 m (looking down at the feet) and 15 m
--   building walls (hangar, depot, command): 2 m and 15 m off the wall
--   inside the VAB: the floor and the walls
--   home ground: the grassiest flat spot 200-320 m out (feet, eye level,
--   horizon) and the steepest slope 200-450 m out (12 m off, eye height)
--
-- Every point is held in the base's layout frame (u, v, height over the
-- ground) and placed against the planet's drawn pose each frame through
-- planet_camera.setShot (docs/positions-and-frames.md).
-- Pictures: user://tiles/<name>.png; lines "TLP ".
defaults = { quit = 1, slot = 19, seed = 5150, scale = 4, w = 1280, h = 720, settle = 2.5 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("TLP %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO = nil, nil
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function astro() return find("Astronaut") end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- ── the base's layout frame ─────────────────────────────────────────────────
local BF, FR, BODY
local function frame()
  BF = findScript("base_facilities")
  BODY = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R = save.get("base.r") or len(bx, by, bz)
  FR = BF.frameOf({ x = bx, y = by, z = bz }, save.get("base.heading") or 0, R)
end
-- the ground's radius under layout (u, v): the graded terrain, or with `deck`
-- the first collider a ray down meets (the pad's deck)
local function ground_r(u, v, deck)
  local d = BF.dirAt(FR, u, v)
  local b = space.body(BODY)
  local top = FR.R + 80
  local ox, oy, oz = b.x + d.x * top, b.y + d.y * top, b.z + d.z * top
  local best
  local h = terrain.raycast(vec3(ox, oy, oz), vec3(-d.x, -d.y, -d.z), 200)
  if h then best = h.distance end
  if deck then
    local ok, hit = pcall(raycast, ox, oy, oz, -d.x, -d.y, -d.z, 200, { ignore = astro() })
    if ok and hit and hit.distance and (not best or hit.distance < best) then best = hit.distance end
  end
  return best and (top - best) or FR.R
end
-- layout (u, v, h over ground) → planet-local point, ground measured now
local function lp(u, v, h, deck)
  local d = BF.dirAt(FR, u, v)
  local r = ground_r(u, v, deck) + h
  return { x = d.x * r, y = d.y * r, z = d.z * r }
end
local function cam_at(c, t)
  local up = BF.dirAt(FR, c.u or 0, c.v or 0)
  findScript("planet_camera").setShot(function()
    local b = space.body(BODY)
    return b.x + c.x, b.y + c.y, b.z + c.z, b.x + t.x, b.y + t.y, b.z + t.z, up.x, up.y, up.z
  end, 0.05)
end
local function stand(u, v)
  local a = astro()
  local p = lp(u, v, 1.25)
  local b = space.body(BODY)
  a.x, a.y, a.z = b.x + p.x, b.y + p.y, b.z + p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(1.0) end
end
local function shot(name)
  local done = false
  local ok = pcall(camera.capture, { w = params.w, h = params.h, ui = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://tiles/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 10, "capture " .. name) end
end
-- one view: crew `crew` (u, v), camera at layout (cu, cv, ch), looking at (tu, tv, th)
local function view(name, crew, cu, cv, ch, tu, tv, th, deck)
  stand(crew[1], crew[2])
  local c = lp(cu, cv, ch, deck); c.u, c.v = cu, cv
  local t = lp(tu, tv, th, deck)
  cam_at(c, t)
  hold(params.settle)
  local slot = terrain.slotAt and terrain.slotAt(space.body(BODY).x + t.x, space.body(BODY).y + t.y, space.body(BODY).z + t.z)
  P("VIEW %s cam (%.1f, %.1f, %.1f) at (%.1f, %.1f, %.1f) slot under target %s", name, cu, cv, ch, tu, tv, th, tostring(slot))
  shot(name)
end

-- a wall: from (u0, v0) at eye height, a ray along (du, dv); the camera
-- `d` m back from where it lands, looking at it
local function wall(name, u0, v0, du, dv, dists)
  local p0 = lp(u0, v0, 1.6)
  local p1 = lp(u0 + du, v0 + dv, 1.6)
  local ex, ey, ez = p1.x - p0.x, p1.y - p0.y, p1.z - p0.z
  local el = len(ex, ey, ez)
  local b = space.body(BODY)
  local ok, hit = pcall(raycast, b.x + p0.x, b.y + p0.y, b.z + p0.z, ex / el, ey / el, ez / el, 150, { ignore = astro() })
  if not (ok and hit and hit.distance) then P("WALL %s: no hit", name) return end
  local nl = len(du, dv, 0)
  local hu, hv = u0 + du / nl * hit.distance, v0 + dv / nl * hit.distance
  P("WALL %s hits %s (%s) at %.1f m -> (%.1f, %.1f)", name, tostring(hit.node and hit.node.name),
    tostring(hit.node and hit.node.parent and hit.node.parent.name), hit.distance, hu, hv)
  for _, d in ipairs(dists) do
    local cu, cv = hu - du / nl * d, hv - dv / nl * d
    view(string.format("%s_%dm", name, d), { cu - du / nl * 2.5 + dv / nl * 1.2, cv - dv / nl * 2.5 + du / nl * 1.2 },
      cu, cv, 1.65, hu + dv / nl * 1.0, hv + du / nl * 1.0, d > 5 and 2.2 or 1.3)
  end
end

-- slope of the bare ground at (u, v): rise over 6 m each way
local function slope(u, v)
  local h0 = ground_r(u, v)
  local hu = ground_r(u + 6, v)
  local hv = ground_r(u, v + 6)
  return math.sqrt(((hu - h0) / 6) ^ 2 + ((hv - h0) / 6) ^ 2)
end

local function main()
  boot()
  local gx = findScript("graphics")
  if gx and gx.params then gx.params.autoLower = false end
  frame()
  P("BASE body %s R %.1f", BODY, FR.R)
  hold(3)

  -- paving
  view("apron_2m", { 8, -9 }, 10, -7, 1.85, 10, -4.8, 0.15)
  view("apron_15m", { -2, -22 }, 0, -20, 1.85, 0, -5, 0.6)
  view("runway_2m", { 18, -65 }, 20, -64, 1.85, 21.5, -62, 0.15)
  view("runway_15m", { -2, -60 }, 0, -62, 1.85, 15, -62, 0.15)
  view("runway_long", { -82, -60 }, -80, -62, 1.85, 40, -62, 0.15)
  view("pad_2m", { 8, 112 }, 9, 110, 1.7, 9, 112.5, 0.0, true)
  -- walls: the hangar's south front, the depot's south front, the command block's
  wall("hangar", 45, 20, -1, 0, { 2, 15 })
  wall("depot", -45, -6, 0, 1, { 2, 15 })
  wall("command", 54, -6, 0, 1, { 2, 15 })
  -- inside the VAB (the hangar's lot centre is (0, 28))
  view("vab_floor", { 6, 12 }, 6, 10, 1.85, 6, 12.5, 0.15)
  view("vab_hall", { 2, 8 }, 0, 6, 1.85, 0, 50, 4.0)
  view("vab_wall", { -10, 26 }, -12, 26, 1.85, -40, 26, 3.0)

  -- home ground: the grassiest flat spot and the steepest slope round the base
  local VEG = { [20] = true, [28] = true, [31] = true, [32] = true }
  local grass, steep, best_s
  for ring = 0, 3 do
    local r = 210 + ring * 35
    for k = 0, 35 do
      local a = k * math.pi / 18
      local u, v = math.cos(a) * r, math.sin(a) * r
      local p = lp(u, v, 0)
      local b = space.body(BODY)
      local sl = terrain.slotAt and terrain.slotAt(b.x + p.x * 0.9995, b.y + p.y * 0.9995, b.z + p.z * 0.9995)
      local s = slope(u, v)
      if not grass and VEG[sl or 0] and s < 0.12 then grass = { u, v, sl } end
      if not best_s or s > best_s then best_s, steep = s, { u, v, sl } end
      if ring == 0 and k % 6 == 0 then P("RING r %d a %d slot %s slope %.2f", r, k * 10, tostring(sl), s) end
    end
  end
  if not grass then grass = { 0, -230, -1 } end
  P("GRASS at (%.0f, %.0f) slot %s | STEEP at (%.0f, %.0f) slot %s slope %.2f", grass[1], grass[2], tostring(grass[3]),
    steep[1], steep[2], tostring(steep[3]), best_s or -1)
  local gu, gv = grass[1], grass[2]
  local gl = len(gu, gv, 0)
  local ou, ov = gu / gl, gv / gl                  -- outward from the base
  view("ground_feet", { gu - ou * 2, gv - ov * 2 }, gu, gv, 1.7, gu + ou * 2.5, gv + ov * 2.5, 0.0)
  view("ground_eye", { gu - ou * 2, gv - ov * 2 }, gu, gv, 1.7, gu + ou * 12, gv + ov * 12, 0.0)
  view("ground_far", { gu - ou * 2, gv - ov * 2 }, gu, gv, 1.7, gu + ou * 80, gv + ov * 80, 0.0)
  view("ground_high", { gu - ou * 2, gv - ov * 2 }, gu, gv, 25, gu + ou * 60, gv + ov * 60, 0.0)
  local su, sv = steep[1], steep[2]
  local sl_ = len(su, sv, 0)
  local iu, iv = -su / sl_, -sv / sl_             -- toward the base
  view("slope_12m", { su + iu * 14, sv + iv * 14 }, su + iu * 12, sv + iv * 12, 1.7, su, sv, 1.0)
  view("slope_3m", { su + iu * 5, sv + iv * 5 }, su + iu * 3, sv + iv * 3, 1.7, su, sv, 1.0)
  findScript("planet_camera").clearShot(0.05)
  P("DONE")
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt_)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
