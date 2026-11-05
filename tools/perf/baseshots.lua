-- BASESHOTS: the spaceport's surfaces in the real game (tools/perf/baseshots.sh):
-- a NEW Career save, then the free camera at fixed points of the base layout
-- (base_facilities' u/v metres: u along the runway, v toward the pad) for the
-- realistic-texture waves. `BS` lines; pictures to user://baseshots/<name>.png.
--
-- Each view is (name, u, v, height over the ground, look-at u, look-at v,
-- look-at height). The ground under the camera is found by a collider ray down
-- (the paving's slabs, the buildings), so a view is a fixed height over what is
-- really there. Everything is kept body-relative (planets only translate) and
-- turned into world points in the pass that uses it (docs/positions-and-frames.md).
--
-- params: quit, slot (probe save slot, deleted first), seed, scale, w, h (picture size),
--   only (a view number to take alone; 0 = all), settle (s per view), clear (1 = clear weather)
defaults = { quit = 1, slot = 18, seed = 5150, scale = 4, w = 1600, h = 900, only = 0, settle = 2.5, clear = 1 }

local VIEWS = {
  -- by day from walking height: the apron toward the VAB
  { "01_walk_apron", 12, -20, 1.7, 0, 28, 8 },
  -- from a distance: the base from beyond the runway
  { "02_far", 70, -120, 32, -5, 30, 6 },
  -- grazing along the apron's concrete
  { "03_graze_apron", -22, -21, 0.55, 22, -14, 0.3 },
  -- grazing along the VAB's east wall (cladding)
  { "04_graze_wall", 28.5, -5, 1.7, 26.5, 50, 6 },
  -- the VAB's door from the apron, and into it
  { "05_vab_door", 0, -12, 1.7, 0, 30, 5 },
  { "06_vab_inside", 4, 8, 1.7, -4, 40, 9 },
  -- the depot's front and its yard
  { "07_depot_yard", -38, -6, 1.7, -50, 12, 3 },
  -- asphalt: the east road, the runway
  { "08_road", 30, -9.5, 1.7, 90, -8, 0 },
  { "09_runway", -40, -58, 1.7, 60, -62, 0 },
  -- at the feet: concrete, asphalt (looking down)
  { "10_feet_concrete", 6, -12, 1.6, 6.6, -11, 0 },
  { "11_feet_asphalt", 40, -8, 1.6, 40.6, -7, 0 },
  -- a footing and the command building's base up close
  { "12_command", 38, -6, 1.7, 50, 8, 3 },
  -- the launch pad from its access road
  { "13_pad", 14, 92, 2.0, 0, 125, 10 },
  -- the fuel farm's steel
  { "14_fuel", -24, 100, 1.7, -40, 112, 4 },
}

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("BS %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local VIEW = nil   -- the view the camera holds: body-relative eye and target
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = params.w, h = params.h, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://baseshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

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
  if app.setDisplayMode then pcall(app.setDisplayMode, { width = params.w, height = params.h, fullscreen = false }) end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 300, "the reveal")
  if params.clear == 1 then
    local wx = findScript("weather")
    if wx and wx.force then wx.force("clear") end
  end
end

-- Body-relative point at layout (u, v), `h` metres over whatever a ray down finds; a hit
-- more than 4 m over the apron (a roof) counts as the apron's level instead.
local REF = nil
local function layout_point(bf, b, Fr, u, v, h)
  local d = bf.dirAt(Fr, u, v)
  local R = Fr.R
  local top = R + 150
  local ox, oy, oz = b.x + d.x * top, b.y + d.y * top, b.z + d.z * top
  local hit = raycast(ox, oy, oz, -d.x, -d.y, -d.z, 400)
  local r = hit and (top - hit.distance) or R
  if REF and r > REF + 4 then r = REF end
  return vec3(d.x * (r + h), d.y * (r + h), d.z * (r + h)), hit ~= nil, r - R
end

local function main()
  boot()
  hold(4.0)
  local bf, cam = findScript("base_facilities"), findScript("planet_camera")
  local bname = save.get("base.body")
  local b = space.body(bname)
  local c = vec3(save.get("base.x"), save.get("base.y"), save.get("base.z"))
  local Fr = bf.frameOf({ x = c.x, y = c.y, z = c.z }, save.get("base.heading"), save.get("base.r"))
  P("base on %s R %.1f heading %.3f", tostring(bname), Fr.R, Fr.heading)
  local _, _, gref = layout_point(bf, b, Fr, 0, -20, 0)
  REF = Fr.R + gref
  cam.setFreecam(true)
  hold(0.5)
  if cam.setTimeFreeze then cam.setTimeFreeze(true) end
  for i, vw in ipairs(VIEWS) do
    if params.only == 0 or params.only == i then
      b = space.body(bname)
      local eye, ok1, g1 = layout_point(bf, b, Fr, vw[2], vw[3], vw[4])
      local tgt, ok2, g2 = layout_point(bf, b, Fr, vw[5], vw[6], vw[7])
      VIEW = { eye = eye, tgt = tgt }
      P("VIEW %s eye ground %+.2f (%s) target ground %+.2f (%s)", vw[1], g1, tostring(ok1), g2, tostring(ok2))
      hold(params.settle)
      shot(vw[1])
      hold(0.6)
    end
  end
  wait_for(function() return pending <= 0 end, 20, "the pictures")
  P("DONE")
end

-- The camera goes in lateUpdate (rule 6): the free camera's state is body-relative,
-- re-aimed every frame from the held eye and target.
function lateUpdate(node, dt)
  if not VIEW then return end
  local cam = findScript("planet_camera")
  local fc = cam and cam.freecamState and cam.freecamState()
  if not fc then return end
  local up = VIEW.eye:normalized()
  local d = VIEW.tgt - VIEW.eye
  local hz = d - up * d:dot(up)
  fc.body = save.get("base.body")
  fc.rel = VIEW.eye
  if hz:length() > 1e-4 then fc.ref = hz:normalized() end
  fc.pitch = math.atan2(d:dot(up), math.max(hz:length(), 1e-4))
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
