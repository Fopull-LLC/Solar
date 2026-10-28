-- DIGBLENDPROBE: how terrain materials meet where the ground is dug. On a
-- COPY of the player's save (tools/perf/digblend.sh): the crew is put `out` m
-- west of the base fence, a pit and a shallow scrape are cut with the laser's bites
-- (terrain.dig r 2.4, 0.85, the tool belt's numbers) until the subsoil shows,
-- then the slot at points across the rim is logged (terrain.slotAt) and the
-- pit is photographed from three stands (oblique, top-down, close). 1280x720.
--
-- params: out, out2 (m west of the fence: the two sites; 0 skips one),
--   bites (pit bites), trench (scrape bites), scrape (m the scrape's bite
--   centres sit over the ground), widen (bites in a ring round the pit's floor), v (m along the fence: both sites),
--   gpu (s: >0 measures at 1920x1080: frames while digging, perf.gpu passes over
--   the painted edge and a low vista for that long each, then the crew carried `fly` m
--   over new ground at 20 m/s; `M ` lines), paint (a palette slot painted in a 2.6 m disc 6 m north of the pit; 0 none), quit, noon (> 0: warp at that multiplier
--   until the sun stands highest over the first site, so the pit's floor is lit),
--   settle (s to wait after the digs before the slots and pictures: the shadow catching up). Pictures: save/user/digblend/<n>.png in the scratch project.
defaults = { out = 120, out2 = 30, bites = 8, trench = 9, scrape = -0.3, quit = 1, noon = 0, settle = 3, widen = 0, v = 20, paint = 0, gpu = 0, fly = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("DB %7.2f " .. fmt, W() - W0, ...)) end
local function yield() coroutine.yield() end
local function wait_for(fn, tmo)
  local t = W() + tmo
  while W() < t do local r = fn(); if r then return r end; yield() end
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end
-- ── measurement (params.gpu) ──
local function pct(t, q)
  if #t == 0 then return -1 end
  table.sort(t); return t[math.max(1, math.min(#t, math.floor(q * #t + 0.5)))]
end
local FR = { on = false }
local function fr_begin()
  local last = perf.frames(1) or {}
  FR = { on = true, from = last[1] and last[1].frame or 0, ms = {}, mesh = {}, terr = {} }
end
local function fr_pull()
  if not FR.on then return end
  for _, f in ipairs(perf.frames() or {}) do
    if f.frame and f.frame > FR.from then
      FR.from = f.frame
      FR.ms[#FR.ms + 1] = f.ms or 0
      FR.mesh[#FR.mesh + 1] = (f.parts or {}).terrainMeshing or 0
      FR.terr[#FR.terr + 1] = (f.buckets or {}).terrain or 0
    end
  end
end
local function fr_end(name)
  fr_pull(); FR.on = false
  local n, msum = #FR.ms, 0
  for _, v in ipairs(FR.mesh) do msum = msum + v end
  local hitch = 0
  for _, v in ipairs(FR.ms) do if v >= 50 then hitch = hitch + 1 end end
  P("M FRAMES [%s] n %d | ms p50 %.2f p95 %.2f p99 %.2f max %.2f | hitches>=50ms %d | terrainMeshing sum %.1f p95 %.2f max %.2f | terrain p95 %.2f",
    name, n, pct(FR.ms, 0.5), pct(FR.ms, 0.95), pct(FR.ms, 0.99), pct(FR.ms, 1), hitch, msum, pct(FR.mesh, 0.95), pct(FR.mesh, 1), pct(FR.terr, 0.95))
end
local function gpu_sample(name, secs)
  local acc, t = {}, nil
  local t1 = W() + secs
  local n = 0
  while W() < t1 do
    coroutine.yield()
    local ok, g = pcall(perf.gpu)
    if ok and g and g.total then
      n = n + 1
      acc.total = acc.total or {}; acc.total[#acc.total + 1] = g.total
      for _, e in ipairs(g.passes or {}) do acc[e.name] = acc[e.name] or {}; local l = acc[e.name]; l[#l + 1] = e.ms end
    end
  end
  local names = {}
  for k in pairs(acc) do names[#names + 1] = k end
  table.sort(names)
  local parts = {}
  for _, k in ipairs(names) do
    local l, sum = acc[k], 0
    for _, v in ipairs(l) do sum = sum + v end
    parts[#parts + 1] = string.format("%s mean %.3f p50 %.3f", k, sum / #l, pct(l, 0.5))
  end
  local w, h = 0, 0
  if camera and camera.screenSize then w, h = camera.screenSize() end
  P("M GPU [%s] %dx%d samples %d | %s", name, w or 0, h or 0, n, table.concat(parts, " | "))
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local NODE, CO
local pending = 0

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://digblend/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if math.abs(d) < 0.03 then return r end
    r = r - (d > 0 and math.max(d * 0.8, 0.02) or math.min(d * 0.8, -0.02))
  end
  return r
end


local F, BF
local function stand(b, u, v)
  local d = BF.dirAt(F, u, v)
  local gr = ground_r(b, d.x, d.y, d.z, F.R + 60)
  local a = find("Astronaut")
  a.x, a.y, a.z = b.x + d.x * (gr + 1.0), b.y + d.y * (gr + 1.0), b.z + d.z * (gr + 1.0)
  a.vx, a.vy, a.vz = 0, 0, 0
  return d, gr
end

local function main()
  NODE.persistent = true
  if params.gpu > 0 then
    perf.enable(true)
    if app.setDisplayMode then
      local ok, err = pcall(app.setDisplayMode, { width = 1920, height = 1080, fullscreen = false })
      P("display 1920x1080 %s %s", tostring(ok), tostring(err))
    end
  end
  save.slot("slot1")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 300)
  P("ready  engine %s", tostring(app.version and app.version()))
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  BF = findScript("base_facilities")
  local b = space.body(save.get("base.body"))
  F = BF.frameOf({ x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") }, save.get("base.heading") or 0,
    save.get("base.r"))
  local FN = BF.FENCE
  local cam = findScript("planet_camera")
  if params.noon > 0 then
    -- stand at the first site and warp until the sun is high (0.85) or at its highest there
    stand(space.body(b.name), FN.u0 - params.out, params.v)
    hold(2)
    -- the sun's height over the crew, from the star and the planet's centre
    local function sunUp()
      local bb, a = space.body(b.name), find("Astronaut")
      local best, bmu = nil, -1
      for _, o in ipairs(space.bodies() or {}) do
        local key = ((o.soi or 0) < 0 and 1e30 or 0) + (o.mu or 0)
        if key > bmu then best, bmu = o, key end
      end
      if not (bb and a and best) then return 0 end
      local up = vec3(a.x - bb.x, a.y - bb.y, a.z - bb.z):normalized()
      return up:dot(vec3(best.x - a.x, best.y - a.y, best.z - a.z):normalized())
    end
    local best, t0, prev, rose = -2, W(), nil, false
    space.warp(params.noon)
    while W() - t0 < 150 do
      yield()
      space.warp(params.noon) -- the game drops a warp on the ground; ask again each frame
      local s = sunUp()
      -- stop high in the sky, or at its highest where it never climbs that far
      if rose and (s >= 0.85 or (s > 0.3 and s < prev and best == prev)) then break end
      if prev and s > prev then rose = true end
      if math.floor(W() - t0) % 5 == 0 and math.floor(W() - t0) ~= (LASTLOG or -1) then LASTLOG = math.floor(W() - t0); P("WARP sun %.3f warp %s t %.0f", s, tostring(space.warp()), space.time()) end
      best = math.max(best, s); prev = s
    end
    space.warp(1)
    hold(1)
    local at = { sun_now = sunUp() }
    P("NOON sun %.2f after %.0f s of warp %d", at and at.sun_now or -1, W() - t0, params.noon)
  end
  for si, out in ipairs({ params.out, params.out2 }) do
    if out and out > 0 then
      local su, sv = FN.u0 - out, params.v
      b = space.body(b.name)
      stand(b, su, sv)
      hold(8)
      -- the pit's centre 6 m further west, along the ground
      b = space.body(b.name)
      local d = BF.dirAt(F, su - 6, sv)
      local gr = ground_r(b, d.x, d.y, d.z, F.R + 60)
      local up = vec3(d.x, d.y, d.z)
      local east = BF.dirAt(F, su - 5, sv)
      local ex = (vec3(east.x, east.y, east.z) - up)
      ex = (ex - up * ex:dot(up)):normalized()
      local north = up:cross(ex):normalized()
      -- everything below is kept in the PLANET frame (rel to the body centre)
      local c0 = up * gr
      local tag = "site" .. si
      P("%s PIT at u %.0f v %.0f, ground r %.2f, slot %s", tag, su - 6, sv, gr, tostring(terrain.slotAt(b.x + c0.x, b.y + c0.y, b.z + c0.z)))
      -- a pit (bites stepping down), then a SHALLOW scrape beside it: bites
      -- whose floor just reaches the layer under the surface, so the two
      -- materials meet across a wide, gently sloping face
      if params.gpu > 0 and si == 1 then fr_begin() end
      for k = 1, params.bites do
        fr_pull()
        b = space.body(b.name)
        local p = c0 - up * (0.6 * k)
        terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 2.4, 0.85)
        hold(0.12)
      end
      -- widen: a ring of bites round the pit's floor, so more subsoil shows
      for k = 1, params.widen do
        b = space.body(b.name)
        local a = (k / params.widen) * 2 * math.pi
        local p = c0 - up * (0.6 * params.bites - 0.4) + ex * (2.4 * math.cos(a)) + north * (2.4 * math.sin(a))
        terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 2.4, 0.85)
        hold(0.12)
      end
      -- paint: a disc of that palette slot on the ground beside the pit, a
      -- painted edge (a road, a biome seam) next to the dug one
      if params.paint > 0 then
        b = space.body(b.name)
        local p = c0 + north * 6
        local pd = p:normalized()
        local pr = ground_r(b, pd.x, pd.y, pd.z, p:length() + 4) or p:length()
        terrain.paintTexture(b.x + pd.x * pr, b.y + pd.y * pr, b.z + pd.z * pr, 2.6, params.paint)
      end
      for k = 1, params.trench do
        b = space.body(b.name)
        local p = c0 + north * (2.5 + 1.4 * k) + ex * (((k % 3) - 1) * 1.6) + up * params.scrape
        terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 2.4, 0.85)
        hold(0.12)
      end
      wait_for(function() fr_pull(); return (terrain.pending and terrain.pending() or 0) == 0 end, 20)
      local ts = W() + params.settle
      while W() < ts do fr_pull(); yield() end
      if params.gpu > 0 and si == 1 then fr_end("dig") end
      b = space.body(b.name)
      for _, axis in ipairs({ { "ex", ex, c0 }, { "scrape", ex, c0 + north * 8 } }) do
        local row = {}
        for i = -8, 8 do
          local q = (axis[3] + up * 4 + axis[2] * (i * 0.75))
          local qd = q:normalized()
          local r = ground_r(b, qd.x, qd.y, qd.z, q:length())
          if r then
            local s = terrain.slotAt(b.x + qd.x * (r - 0.2), b.y + qd.y * (r - 0.2), b.z + qd.z * (r - 0.2))
            row[#row + 1] = string.format("%+.1f:%s", i * 0.75, tostring(s))
          end
        end
        P("%s SLOTS across the %s (m:slot) %s", tag, axis[1], table.concat(row, " "))
      end
      local stands = {
        { "oblique", ex * 9 + north * 6, 6, -30, ex * -1 },
        { "top", north * 5, 11, -88, ex * -1 },
        { "close", ex * 3 + north * 9, 3.0, -45, ex * -1 },
        { "rim", ex * 3.5, 5.0, -62, ex * -1 },
      }
      for _, st in ipairs(stands) do
        b = space.body(b.name)
        cam.setFreecam(true)
        local fc = cam.freecamState()
        fc.body = b.name
        fc.rel = up * (gr + st[3]) + st[2]
        fc.ref = st[5]
        fc.pitch = math.rad(st[4])
        hold(1.5)
        shot(tag .. "_" .. st[1])
        hold(0.6)
      end
      if params.gpu > 0 and si == 1 then
        -- the painted disc's edge filling the screen from 3 m, then a low vista
        for _, st in ipairs({ { "edge", north * 3.6, 3.0, -80, ex * -1 }, { "pit", ex * 3.5, 5.0, -62, ex * -1 },
            { "vista", ex * 6, 2.5, -8, ex * -1 } }) do
          b = space.body(b.name)
          local fc = cam.freecamState()
          fc.body = b.name
          fc.rel = up * (gr + st[3]) + st[2]
          fc.ref = st[5]
          fc.pitch = math.rad(st[4])
          hold(2)
          gpu_sample(st[1], params.gpu)
        end
        if params.fly > 0 then
          -- the crew carried west over new ground at 20 m/s, the camera behind
          local a = find("Astronaut")
          fr_begin()
          local t0, dist = W(), 0
          while dist < params.fly do
            yield(); fr_pull()
            dist = (W() - t0) * 20
            b = space.body(b.name)
            local q = (c0 - ex * dist):normalized()
            local r = ground_r(b, q.x, q.y, q.z, gr + 40) or gr
            a.x, a.y, a.z = b.x + q.x * (r + 1.2), b.y + q.y * (r + 1.2), b.z + q.z * (r + 1.2)
            a.vx, a.vy, a.vz = 0, 0, 0
            local fc = cam.freecamState()
            fc.body = b.name
            fc.rel = q * (r + 4) + ex * 8
            fc.ref = ex * -1
            fc.pitch = math.rad(-12)
          end
          fr_end("fly")
        end
      end
      cam.setFreecam(false)
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
