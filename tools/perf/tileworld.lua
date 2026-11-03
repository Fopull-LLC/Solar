-- TILEWORLD (tools/perf/tileworld.sh): the terrain textures' tiling on whole
-- worlds, no base, no save. `WORLDS` (prepended by the .sh from
-- alienprobe_dump.lua) is a list of { name, opts }. Each world is filled into
-- terrain 1 (a static node at the origin, so nothing moves under the camera)
-- and photographed on its sunlit side: the flattest ground (at the feet, eye
-- level 12 m out, toward the horizon, 25 m up) and the steepest (12 m and 3 m
-- off, eye height).
--
-- params: first, last (world indices), settle (s).
defaults = { first = 1, last = 99, settle = 3, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("TW %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local CO
local SUN = vec3(0.4, 0.9, 0.45):normalized()

local function shot(name)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://tworld/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 10) end
end

local function ground(d, R, top)
  local hit = terrain.raycast(d * (R + top), d * -1, top + R * 0.5)
  return hit and hit.pos:length() or nil, hit
end

local function fib(i, n)
  local y = 1 - (i + 0.5) / n * 2
  local r = math.sqrt(math.max(0, 1 - y * y))
  local a = i * 2.39996323
  return vec3(math.cos(a) * r, y, math.sin(a) * r)
end

-- a point `m` metres from unit direction d along tangent t, on the ground (+h)
local function along(d, t, m, R, top, h)
  local a = m / R
  local e = (d * math.cos(a) + t * math.sin(a)):normalized()
  local g = ground(e, R, top)
  return e * ((g or R) + (h or 0)), e
end

local function view(cam, eye, at, up, name)
  cam.x, cam.y, cam.z = eye.x, eye.y, eye.z
  cam:lookAt(at, up)
  hold(params.settle)
  shot(name)
end

local function main()
  local cam = find("Camera")
  for wi = params.first, math.min(params.last, #WORLDS) do
    local w = WORLDS[wi]
    local o = w.opts
    local R = o.radius
    local tag = string.format("w%d_%s", wi, (w.name:gsub(":", "-")))
    local far = SUN * (R * 3)
    cam.x, cam.y, cam.z = far.x, far.y, far.z
    cam:lookAt(vec3(0, 0, 0), vec3(0, 1, 0))
    yield()
    terrain.generatePlanet(1, o)
    yield(); yield()
    wait_for(function() return not terrain.busy() end, 240)
    local top = (w.peak or 100) + 60
    -- slope over ~6 m at directions 35-60 deg from the sun
    local flat, flat_s, steep, steep_s
    local N = 700
    for i = 0, N - 1 do
      local d = fib(i, N)
      local s = d:dot(SUN)
      if s > 0.55 and s < 0.85 then
        local h0 = ground(d, R, top)
        local t1 = d:cross(vec3(0, 1, 0)):normalized()
        local t2 = d:cross(t1)
        local h1 = ground((d + t1 * (6 / R)):normalized(), R, top)
        local h2 = ground((d + t2 * (6 / R)):normalized(), R, top)
        if h0 and h1 and h2 and (not w.seaAlt or h0 > R + w.seaAlt + 1) then
          local sl = math.sqrt(((h1 - h0) / 6) ^ 2 + ((h2 - h0) / 6) ^ 2)
          if not flat_s or sl < flat_s then flat, flat_s = d, sl end
          if not steep_s or sl > steep_s then steep, steep_s = d, sl end
        end
      end
    end
    if not flat then P("WORLD %d %s: no sunlit ground", wi, w.name) end
    if flat then
    P("WORLD %d %s (%s) r %.0f | flat slope %.2f | steep slope %.2f", wi, w.name, w.label or "?", R, flat_s, steep_s or -1)
    do
      -- flat ground: look away from the sun's azimuth (light from behind-left)
      local d = flat
      local t = (SUN - d * SUN:dot(d)):normalized() * -1
      local eye = along(d, t, 0, R, top, 1.7)
      view(cam, eye, along(d, t, 2.5, R, top, 0), d, tag .. "_feet")
      view(cam, eye, along(d, t, 12, R, top, 0), d, tag .. "_eye")
      view(cam, eye, along(d, t, 80, R, top, 0), d, tag .. "_far")
      view(cam, along(d, t, 0, R, top, 25), along(d, t, 60, R, top, 0), d, tag .. "_high")
    end
    if steep then
      local d = steep
      local t = (SUN - d * SUN:dot(d)):normalized()
      local aim = along(d, t, 0, R, top, 1.0)
      local e12, u12 = along(d, t, -12, R, top, 1.7)
      view(cam, e12, aim, u12, tag .. "_slope12")
      local e3, u3 = along(d, t, -3, R, top, 1.7)
      view(cam, e3, aim, u3, tag .. "_slope3")
    end
    end
  end
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function lateUpdate(node, dt)
  if not CO then CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
