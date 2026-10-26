-- FLORAPROBE: how the plants read at eye height, near and far, on a copy of
-- the player's save (tools/perf/flora.sh). A free camera at the astronaut's
-- eye, up to four headings, each graphics level in `levels`; 1280x720 pictures
-- (res=1080: 1920x1080; keep those few, the GPU is shared) and
-- the GPU's own time per pass (perf.gpu, averaged over `gsecs`) per heading.
--
-- params: alt (m over the ground), pitch (deg, + = up), off (m along the
--   ground from the astronaut), levels (digits, 1-4 = Low..Ultra: 23 = Medium
--   then High), gsecs, quit.
--   res (720 or 1080: picture height), heads (how many of the four headings),
--   forest (m: stand at the densest forest about this far from the base; 0 =
--   at the astronaut).
defaults = { alt = 1.7, pitch = 4, off = 0, levels = 23, gsecs = 3, quit = 1, settle = 6, forest = 300, arrive = 12, res = 720, heads = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FP %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local NODE, CO
local pending = 0

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = params.res >= 1080 and 1920 or 1280, h = params.res >= 1080 and 1080 or 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://flora/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

-- Mean GPU ms per pass over `secs`.
local function gpu(secs)
  local sum, n, passes = 0, 0, {}
  local t = W() + secs
  while W() < t do
    local ok, g = pcall(perf.gpu)
    if ok and g and g.total then
      sum = sum + g.total; n = n + 1
      for _, p in ipairs(g.passes or {}) do passes[p.name] = (passes[p.name] or 0) + p.ms end
    end
    yield()
  end
  local ks = {}
  for k, v in pairs(passes) do ks[#ks + 1] = string.format("%s=%.2f", k, v / math.max(n, 1)) end
  table.sort(ks)
  return n > 0 and sum / n or -1, table.concat(ks, " ")
end

local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
-- The densest forest about `dist` m from the base (any bearing).
local function find_forest(b, dist)
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R = len(bx, by, bz)
  local u = { x = bx / R, y = by / R, z = bz / R }
  local ax = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, ax)); local t2 = unit(cross(u, t1))
  local cl = findScript("climate")
  local best, census = nil, {}
  for _, d in ipairs({ dist - 100, dist - 50, dist, dist + 50, dist + 100, dist + 200 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local a = d / R
      local dir = unit({ x = u.x * math.cos(a) + t.x * math.sin(a), y = u.y * math.cos(a) + t.y * math.sin(a), z = u.z * math.cos(a) + t.z * math.sin(a) })
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if gr then
        local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
        local smp = cl and cl.sampleAt and cl.sampleAt(b.name, p.x, p.y, p.z)
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        if smp and not wet then
          census[smp.biome or "?"] = (census[smp.biome or "?"] or 0) + 1
          local score = (smp.biome == "forest" and 10 or 0) + (smp.density or 0) - math.abs(d - dist) / 300
          if not best or score > best.score then best = { dir = dir, r = gr, biome = smp.biome, d = d, score = score, flora = smp.density or 0 } end
        end
      end
    end
  end
  local cs = {}
  for k, v in pairs(census) do cs[#cs + 1] = string.format("%s %d", k, v) end
  table.sort(cs)
  P("FOREST census: %s", table.concat(cs, ", "))
  return best
end

local function main()
  NODE.persistent = true
  pcall(perf.enable, true)
  save.slot("slot1")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 200)
  P("ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  local b = space.body(save.get("base.body"))
  if params.forest > 0 then
    local spot = find_forest(b, params.forest)
    if spot then
      P("FOREST %s (flora %.2f) %d m from the base", tostring(spot.biome), spot.flora, spot.d)
      local a = find("Astronaut")
      a.x, a.y, a.z = b.x + spot.dir.x * (spot.r + 1.0), b.y + spot.dir.y * (spot.r + 1.0), b.z + spot.dir.z * (spot.r + 1.0)
      a.vx, a.vy, a.vz = 0, 0, 0
      hold(params.arrive)
      b = space.body(save.get("base.body"))
    end
  end
  local cam = findScript("planet_camera")
  cam.setFreecam(true)
  hold(0.2)
  local fc = cam.freecamState()
  local a = find("Astronaut")
  local rx, ry, rz = a.x - b.x, a.y - b.y, a.z - b.z
  local r = len(rx, ry, rz)
  local up = vec3(rx / r, ry / r, rz / r)
  if params.off ~= 0 then
    local side = up:cross(vec3(0, 0, 1)):normalized()
    local ang = params.off / r
    up = (up * math.cos(ang) + side * math.sin(ang)):normalized()
  end
  local top = vec3(b.x, b.y, b.z) + up * (b.radius + 300)
  local hit = terrain.raycast(top, up * -1, 600)
  local gr = hit and len(hit.pos.x - b.x, hit.pos.y - b.y, hit.pos.z - b.z) or r
  fc.body = b.name
  fc.rel = up * (gr + params.alt)
  fc.pitch = math.rad(params.pitch)
  local gx = findScript("graphics")
  for dg in string.gmatch(tostring(math.floor(params.levels)), "%d") do
    local lv = gx.LEVELS[tonumber(dg)]
    gx.set(lv)
    P("graphics -> %s", lv)
    hold(params.settle)
    for h = 0, math.max(1, math.floor(params.heads)) - 1 do
      fc.ref = up:cross(vec3(1, 0, 0)):normalized():rotatedAround(up, h * math.pi / 2)
      hold(1.5)
      local tot, passes = gpu(params.gsecs)
      P("GPU %s h%d total %.2f | %s", lv, h, tot, passes)
      shot(string.format("%s_h%d", lv, h))
      hold(0.3)
    end
  end
  wait_for(function() return pending <= 0 end, 20)
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  if not CO then NODE = node; CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
