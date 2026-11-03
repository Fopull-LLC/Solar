-- ALIENHOME: a new save made the way the new-save panel makes one, with the
-- HOME WORLD choice (menu_newsave: Earth-like, or Alien with its seed), then
-- the spawn checked and photographed (tools/perf/alienhome.sh).
--
--   * the save: perfbench boot()'s keys, plus g_homeKind = "alien" and
--     g_homeSeed when alien = 1;
--   * the world: type, radius, gravity, air, sea; the crew's height over the
--     ground and distance from the base centre once the curtain lifts;
--   * pictures: from the crew's eye height toward the base and toward the pad,
--     and a wide one over the base (all body-relative, through the freecam);
--   * reload = 1: the system scene loaded again on the same slot (the menu's
--     CONTINUE), and the world record compared with the first load's;
--   * menu = 1: only a picture of the new-save panel with Alien picked.
-- The probe's slot is deleted at the end.
defaults = { slot = 14, seed = 1911564384, alien = 0, homeseed = 0, reload = 1, menu = 0, quit = 1, noon = 60 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("AH %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
  return nil
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local NODE, CO
local pending = 0
local TAG = "home"

local function shot(name, ui)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui == true, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://alienhome/" .. TAG .. "_" .. name .. ".png", bytes); P("SHOT %s_%s", TAG, name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  -- the capture draws a LATER frame: nothing may change until it has
  local t = W() + 10
  while pending > 0 and W() < t do coroutine.yield() end
end

local function slot_name() return "slot" .. math.floor(params.slot) end

local function make_save()
  local s = slot_name()
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", 4)
  if params.alien > 0 then
    save.set("g_homeKind", "alien")
    save.set("g_homeSeed", math.floor(params.homeseed))
  end
end

local function ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

-- The world as the save records it.
local function world_line()
  local name = save.get("base.body")
  local w = name and save.get("world." .. name) or {}
  local b = name and space.body(name)
  local geo = type(w.geo) == "table" and w.geo or {}
  local sg = findScript("system_generator")
  local f = sg and sg.homeFeatures and sg.homeFeatures(name) or {}
  local fl = {}
  for _, k in ipairs({ "air", "breathable", "sea", "rivers", "lakes", "ravines", "caves", "overhangs", "mountains", "flora", "moon" }) do
    fl[#fl + 1] = k .. "=" .. tostring(f[k])
  end
  return string.format("%s: %s (%s) r %.1f g %.2f atmo %.2f sea %.1f tempK %s seed %s kind %s | %s",
    tostring(name), tostring(geo.label), tostring(geo.type), b and b.radius or -1, b and b.mu / (b.radius * b.radius) or -1,
    w.atmo or -1, w.sea or -1, tostring(type(w.bio) == "table" and w.bio.tempK), tostring(w.seed), tostring(f.kind),
    table.concat(fl, " ")), { name = name, type = geo.type, seed = w.seed, radius = b and b.radius, mu = b and b.mu, atmo = w.atmo }
end

-- The crew: height over the ground under them, distance from the base centre.
local function crew_line()
  local b = space.body(save.get("base.body"))
  local a = find("Astronaut")
  local bf = findScript("base_facilities")
  if not (b and a and bf) then return "no crew/base" end
  local rx, ry, rz = a.x - b.x, a.y - b.y, a.z - b.z
  local r = len(rx, ry, rz)
  local ux, uy, uz = rx / r, ry / r, rz / r
  local top = vec3(a.x + ux * 4, a.y + uy * 4, a.z + uz * 4)
  local hit = terrain.raycast(top, vec3(-ux, -uy, -uz), 200)
  local over = hit and (4 - hit.distance) or nil
  local dx, dy, dz = bf.baseX - a.x, bf.baseY - a.y, bf.baseZ - a.z
  local pw = findScript("planet_walker")
  return string.format("crew r %.1f, %.2f m over the ground (exact %s), %.1f m from the base centre, onFoot %s, lat %.0f",
    r, over or -999, tostring(hit and hit.exact), len(dx, dy, dz), tostring(pw and pw.onFoot), math.deg(math.asin(uy)))
end

-- Point the freecam: at `rel` (body-relative) looking toward body-relative `at`.
local function aim(cam, bname, rel, at, pitch)
  local fc = cam.freecamState()
  fc.body = bname
  fc.rel = rel
  local up = rel:normalized()
  local d = (at - rel):flatten(up)
  if d:length() < 1e-3 then d = up:cross(vec3(1, 0, 0)) end
  fc.ref = d:normalized()
  fc.pitch = math.rad(pitch or 0)
end

-- Daylight for the pictures: warp until the sun stands high over the crew (or
-- at its highest there). The game drops a warp on the ground: asked every frame.
local function sun_up()
  local at = findScript("atmosphere")
  return at and at.sun_now or 0
end
local function to_noon()
  if params.noon <= 0 then return end
  local best, t0, prev, rose = -2, W(), nil, false
  while W() - t0 < 120 do
    space.warp(params.noon)
    yield()
    local s = sun_up()
    if s >= 0.8 or (rose and s > 0.3 and s < prev) then break end
    if prev and s > prev then rose = true end
    best = math.max(best, s); prev = s
  end
  space.warp(1)
  hold(1.5)
  P("NOON sun %.2f after %.0f s", sun_up(), W() - t0)
end

local function pictures()
  local b = space.body(save.get("base.body"))
  local a = find("Astronaut")
  local bf = findScript("base_facilities")
  local cam = findScript("planet_camera")
  if not (b and a and bf and cam and cam.setFreecam) then P("no camera"); return end
  local bp = vec3(b.x, b.y, b.z)
  local crew = vec3(a.x, a.y, a.z) - bp
  local base = vec3(bf.baseX, bf.baseY, bf.baseZ) - bp
  local pad = bf.launchSite and bf.launchSite("pad")
  local padv = pad and vec3(pad.x, pad.y, pad.z) or base
  cam.setFreecam(true)
  hold(0.3)
  local up = crew:normalized()
  local eye = crew + up * 1.6
  aim(cam, b.name, eye, padv, 0); hold(1.5); shot("eye_crew")
  -- outside, on the graded apron between the base and the pad (the crew
  -- spawns in the VAB), at eye height over the base's grade level
  local mid = (base + (padv - base) * 0.6)
  local eye2 = mid:normalized() * (base:length() + 1.7)
  local hit = terrain.raycast(vec3(bp.x + eye2.x, bp.y + eye2.y, bp.z + eye2.z) + mid:normalized() * 40, mid:normalized() * -1, 120)
  P("outside eye point %.1f m from the base centre; ground %s m under the eye", (eye2 - base):length(),
    hit and string.format("%.2f", hit.distance - 40) or "?")
  aim(cam, b.name, eye2, base, 3); hold(1.5); shot("eye_base")
  aim(cam, b.name, eye2, padv, 4); hold(1.5); shot("eye_pad")
  local bu = base:normalized()
  local away = (base - padv):flatten(bu)
  if away:length() < 1e-3 then away = bu:cross(vec3(1, 0, 0)) end
  away = away:normalized()
  local wide = base + bu * 110 + away * 230
  aim(cam, b.name, wide, base, -20); hold(2.0); shot("wide")
  local high = base + bu * 260 + away * 330
  aim(cam, b.name, high, base, -36); hold(2.5); shot("high")
  cam.setFreecam(false)
  hold(0.3)
end

local function menu_picture()
  scene.load("menu")
  yield()
  local ns = wait_for(function() return findScript("menu_newsave") end, 30)
  if not ns then P("no menu_newsave"); return end
  hold(1.0)
  ns.openFor(math.floor(params.slot))
  hold(0.5)
  if ns.setHome then ns.setHome("alien", "55555") end
  hold(1.5)
  shot("menu_alien", true)
  if ns.setHome then ns.setHome("earth") end
  hold(1.0)
  shot("menu_earth", true)
  hold(1.0)
end

local function main()
  NODE.persistent = true
  TAG = params.menu > 0 and "menu" or (params.alien > 0 and string.format("alien%d", math.floor(params.homeseed)) or "earth")
  if params.menu > 0 then menu_picture(); return end
  make_save()
  P("created %s: seed %d, home %s %s", save.slot(), params.seed, params.alien > 0 and "alien" or "earth", tostring(save.get("g_homeSeed")))
  scene.load("system")
  yield()
  local t0 = W()
  local ok = wait_for(ready, 260)
  P("READY %s after %.1f s", tostring(ok ~= nil), W() - t0)
  local wl, w1 = world_line()
  P("WORLD %s", wl)
  P("CREW %s", crew_line())
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  hold(2.0)
  P("CREW after 2 s: %s", crew_line())
  to_noon()
  P("CREW at noon: %s", crew_line())
  pictures()
  if params.reload > 0 then
    scene.load("system")
    yield()
    local t1 = W()
    local ok2 = wait_for(ready, 200)
    local wl2, w2 = world_line()
    P("RELOAD ready %s after %.1f s", tostring(ok2 ~= nil), W() - t1)
    P("RELOAD WORLD %s", wl2)
    P("RELOAD CREW %s", crew_line())
    local same = w1.name == w2.name and w1.type == w2.type and w1.seed == w2.seed and w1.radius == w2.radius
      and w1.mu == w2.mu and w1.atmo == w2.atmo
    P("RESULT RELOAD same world: %s", same and "PASS" or "FAIL")
  end
end

function start(node)
  NODE = node
  CO = coroutine.create(function()
    local ok, err = pcall(main)
    if not ok then P("ERROR %s", tostring(err)) end
    wait_for(function() return pending <= 0 end, 20)
    -- the probe's own slot goes
    local s = slot_name()
    if params.menu <= 0 then
      pcall(scene.load, "menu"); yield(); yield()
      pcall(terrain.deleteSaveDir, "saves/" .. s .. "/terrain")
      if save.deleteSlot then pcall(save.deleteSlot, s) end
      P("deleted %s", s)
    end
    P("DONE")
    if params.quit > 0 then app.quit() end
  end)
end

function update(node, dt)
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
