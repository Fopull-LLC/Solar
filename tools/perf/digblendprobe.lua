-- DIGBLENDPROBE: how terrain materials meet where the ground is dug. On a
-- COPY of the player's save (tools/perf/digblend.sh): the crew is put `out` m
-- west of the base fence, a pit and a shallow scrape are cut with the laser's bites
-- (terrain.dig r 2.4, 0.85, the tool belt's numbers) until the subsoil shows,
-- then the slot at points across the rim is logged (terrain.slotAt) and the
-- pit is photographed from three stands (oblique, top-down, close). 1280x720.
--
-- params: out, out2 (m west of the fence: the two sites; 0 skips one),
--   bites (pit bites), trench (scrape bites), scrape (m the scrape's bite
--   centres sit over the ground), quit. Pictures: save/user/digblend/<n>.png in the scratch project.
defaults = { out = 120, out2 = 30, bites = 8, trench = 9, scrape = -0.3, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("DB %7.2f " .. fmt, W() - W0, ...)) end
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
  for si, out in ipairs({ params.out, params.out2 }) do
    if out and out > 0 then
      local su, sv = FN.u0 - out, 20
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
      for k = 1, params.bites do
        b = space.body(b.name)
        local p = c0 - up * (0.6 * k)
        terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 2.4, 0.85)
        hold(0.12)
      end
      for k = 1, params.trench do
        b = space.body(b.name)
        local p = c0 + north * (2.5 + 1.4 * k) + ex * (((k % 3) - 1) * 1.6) + up * params.scrape
        terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 2.4, 0.85)
        hold(0.12)
      end
      wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20)
      hold(3)
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
