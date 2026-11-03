-- ALIENPROBE (tools/perf/alienprobe.sh): the alien formations seen and timed.
-- `WORLDS` (prepended by the .sh from alienprobe_dump.lua) is a list of
-- { name, formation, reach, opts }. Each world is filled whole with
-- terrain.generatePlanet into terrain 1 (a static node at the origin, so a
-- world point is a planet point and nothing moves under the camera), timed
-- to the fill's end; the probe then looks for the most dramatic ground on the
-- sunlit side, frames it from eye height (1.7 m over the ground, 70 m off)
-- and from high and wide (130 m up, 240 m back), and sums the frame's
-- terrainMeshing / terrainLoad parts while each view's meshes settle.
--
-- params: first, last (world indices), tag (shot name prefix), settle (s).
defaults = { first = 1, last = 99, tag = "a", settle = 5, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("AP %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local CO
local pending = 0
local SUN = vec3(0.4, 0.9, 0.45):normalized()

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://alien/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  wait_for(function() return pending <= 0 end, 10)
end

-- Sum the terrain parts over `secs`, and the frame times, while meshes land.
local function measure(secs)
  local t1 = W() + secs
  local mesh, load, n, worst, ms = 0, 0, 0, 0, {}
  while W() < t1 do
    yield()
    local pt = perf.parts() or {}
    mesh = mesh + (pt.terrainMeshing or 0)
    load = load + (pt.terrainLoad or 0)
    worst = math.max(worst, pt.terrainMeshing or 0)
    local f = perf.frames(1)
    if f and f[1] then ms[#ms + 1] = f[1].ms end
    n = n + 1
  end
  table.sort(ms)
  return mesh, load, n, worst, ms[math.max(1, math.floor(#ms * 0.95))] or 0
end

-- The ground's radius in direction d (nil where the ray misses).
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

local function view(cam, eye, at, up)
  cam.x, cam.y, cam.z = eye.x, eye.y, eye.z
  cam:lookAt(at, up)
end

local function main()
  perf.enable(true)
  local cam = find("Camera")
  local tnode = find("Planet")
  for wi = params.first, math.min(params.last, #WORLDS) do
    local w = WORLDS[wi]
    local o = w.opts
    local R = o.radius
    local tag = string.format("%s%d_%s", params.tag, wi, w.name:gsub(":", "-"))
    -- park the camera far out while it fills
    view(cam, SUN * (R * 3), vec3(0, 0, 0), vec3(0, 1, 0))
    yield()
    local t0 = W()
    terrain.generatePlanet(1, o)
    yield(); yield()
    wait_for(function() return not terrain.busy() end, 240)
    local fill = W() - t0
    local c = perf.counts() or {}
    P("WORLD %d %s (%s) formation %s reach %.2f seed %d r %.0f voxel %.2f | fill %.1f s | fieldChunks %s",
      wi, w.name, w.label or "?", w.formation, w.reach, o.seed, R, o.voxel, fill, tostring(c.fieldChunks))
    local m0, l0, n0, wst0, p95_0 = measure(2)
    P("ORBIT %d meshing %.1f ms over %d frames (worst %.1f) load %.1f p95 %.1f ms chunks %s", wi, m0, n0, wst0, l0, p95_0, tostring((perf.counts() or {}).chunks))
    shot(tag .. "_orbit")
    -- The most dramatic ground on the sunlit side: the highest relief
    -- against its neighbours among directions 35–60° from the sun.
    local top = (w.peak or 100) + 60
    local best, bestd, besth
    local N = 900
    local hs = {}
    for i = 0, N - 1 do
      local d = fib(i, N)
      local s = d:dot(SUN)
      if s > 0.5 and s < 0.82 then
        local h = ground(d, R, top)
        if h then hs[#hs + 1] = { d = d, h = h } end
      end
    end
    -- score: height above the lowest ground within ~9° (a cliff or a tower)
    for _, a in ipairs(hs) do
      local lo = a.h
      for _, b in ipairs(hs) do
        if a.d:dot(b.d) > 0.988 then lo = math.min(lo, b.h) end
      end
      local sc = a.h - lo
      if not best or sc > best then best, bestd, besth = sc, a.d, a.h end
    end
    if not bestd then bestd, besth, best = SUN, R, 0 end
    local up = bestd
    local side = up:cross(SUN):normalized()
    local poi = up * besth
    P("POI %d relief %.1f m at h %.1f (%d candidates)", wi, best, besth - R, #hs)
    -- eye height, `arc` m off round the feature, at the first bearing from
    -- the shadow line with a clear view of it (not buried under a ledge)
    local fwd = up:cross(side)
    local function spot(arc, k0)
      local aim = up * (besth - best * 0.45)
      for k = 0, 11 do
        local ang = (k0 + k) * math.pi / 6
        local t = side * math.cos(ang) + fwd * math.sin(ang)
        local d = (up * math.cos(arc / R) + t * math.sin(arc / R)):normalized()
        local gr = ground(d, R, top)
        if gr then
          local e = d * (gr + 1.7)
          local dir = aim - e
          local dist = dir:length()
          local hit = terrain.raycast(e, dir * (1 / dist), dist)
          if not hit or hit.distance > dist * 0.6 then return e, aim, d end
        end
      end
      local d = (up * math.cos(arc / R) + side * math.sin(arc / R)):normalized()
      return d * ((ground(d, R, top) or besth) + 1.7), aim, d
    end
    local eye, aim, d2 = spot(70, 0)
    view(cam, eye, aim, d2)
    local m1, l1, n1, wst1, p95_1 = measure(params.settle)
    P("EYE %d meshing %.1f ms over %d frames (worst %.1f) load %.1f p95 %.1f ms chunks %s", wi, m1, n1, wst1, l1, p95_1, tostring((perf.counts() or {}).chunks))
    shot(tag .. "_eye")
    -- dig at the feet: the ground there must go down (voxel terrain, any shape)
    do
      local dn = eye:normalized()
      local h0 = ground(dn, R, top)
      if h0 then
        local p = dn * h0
        terrain.dig(p.x, p.y, p.z, 3)
        hold(0.6)
        local h1 = ground(dn, R, top)
        P("DIG %d ground %.2f -> %s m (%s)", wi, h0 - R, h1 and string.format("%.2f", h1 - R) or "nil",
          (h1 and h1 < h0 - 0.5) and "PASS" or "FAIL")
      end
    end
    -- the other way round, toward the sun's side (front-lit)
    local e3, a3, d3 = spot(110, 6)
    view(cam, e3, a3, d3)
    hold(2)
    shot(tag .. "_eye2")
    -- high and wide
    local d4 = (up * math.cos(240 / R) + side * math.sin(240 / R)):normalized()
    local g4 = ground(d4, R, top) or besth
    view(cam, d4 * (math.max(g4, besth) + 90), poi, d4)
    local m2, l2, n2, wst2, p95_2 = measure(params.settle)
    P("HIGH %d meshing %.1f ms over %d frames (worst %.1f) load %.1f p95 %.1f ms chunks %s", wi, m2, n2, wst2, l2, p95_2, tostring((perf.counts() or {}).chunks))
    shot(tag .. "_high")
    P("BENCH %d %s fill %.1f meshing %.1f %.1f %.1f", wi, w.name, fill, m0, m1, m2)
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
